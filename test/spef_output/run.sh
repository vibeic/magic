#!/bin/bash
#
# Regression: SPEF parasitic-exchange output (roadmap #28, P1).
#
# ext2spice could only serialise the extracted R/C network as SPICE elements.
# STA / PEX consumers ingest the IEEE-1481 SPEF interchange format instead, so
# magic's parasitics could not be handed to them at all.  The fork adds
# `ext2spice format spef`, a SPEF writer over the SAME extracted network.
#
# THE NUMBERS -- every value below is hand-computed from the tech coefficient
# and the painted area, and independently cross-checked against magic's own
# long-established SPICE emission for the identical extraction.
#
#   The extract section is generated with known round coefficients:
#       areacap met1 K        (K attofarads per square cap-unit)
#       overlap met2 met1 300 (300 aF per square cap-unit of met1/met2 overlap)
#   A painted rectangle of WX x WY box units has WX*WY square cap-units, so
#       C[aF] = K * WX * WY        and SPEF declares *C_UNIT 1 FF, i.e. /1000
#       C[fF] = K * WX * WY / 1000
#
#   1 GROUND CAP   K=100, 1000x100 -> 100 * 100000 / 1000        = 10000 fF
#   2 CROSS-CHECK  the same extraction emitted as SPICE          = 10p = 10000 fF
#   3 AREA         K=100, 2000x100 (2x the area)                 = 20000 fF
#   4 COEFFICIENT  K=200, 1000x100 (2x the coefficient)          = 20000 fF
#   5 COUPLING     met2 500x100 over met1 1000x100:
#         ground  on NET1 : 100 * 1000*100 / 1000               = 10000 fF
#         coupling NET1<->NET2 : 300 * 500*100 / 1000           = 15000 fF
#         *D_NET NET1 total = 10000 + 15000                     = 25000 fF
#         *D_NET NET2 total = its share of the coupling         = 15000 fF
#
# 3 and 4 are the proven-negatives: the value must move by the exact
# hand-computed factor when the GEOMETRY changes and again when the tech
# COEFFICIENT changes, so neither a hardcoded constant nor a value copied from
# elsewhere can satisfy the gate.  2 anchors the SPEF unit conversion against
# magic's own SPICE path.  5 proves coupling is attributed to BOTH nets (listed
# once under NET1, but counted in NET2's *D_NET total).
#
# ISOLATION: every case runs in its OWN directory.  A stale cell.ext left by a
# previous case is silently reused by magic and produces wrong-but-plausible
# numbers -- that is a real trap this gate must not fall into.
#
# SCOPE, stated honestly: this gate covers *D_NET / *CONN / *CAP (ground and
# coupling capacitance).  The writer also emits a *RES section, but it is NOT
# exercised here: on these fixtures `extresist` yields no multi-node resistor
# network, and magic's own SPICE path likewise emits no R elements for them, so
# there is nothing to compare against.  SPEF resistance output is therefore
# implemented but UNVERIFIED -- do not claim it works.
#
# chip/PDK-AGNOSTIC: synthetic tech coefficients + painted rectangles only.
#
# Usage:  ./run.sh [MAGIC_BIN]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAGIC_BIN="${1:-magic}"
PY="${PYTHON:-python3}"
GEN="$HERE/../lvs_bridge_tech_multimetal/gen_bridge_tech.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE"/extract_spef.tcl "$HERE"/geom_plate.tcl "$HERE"/geom_couple.tcl "$WORK"/
cp "$HERE"/../lvs_bridge_tech_multimetal/stack.lef "$WORK"/
cp "$GEN" "$WORK"/gen_bridge_tech.py
cd "$WORK" || exit 2

fail() { echo "FAIL: $1"; exit 1; }

"$PY" gen_bridge_tech.py --lef stack.lef --name bridge -o base.tech >/dev/null \
    || fail "bridge tech generation failed"
grep -q "^  areacap met1 0$" base.tech || fail "base tech drift: no zeroed areacap met1"

# build a tech with areacap met1 = $1, plus the met2/met1 overlap coefficient
mktech() {
    sed -e "s/^  areacap met1 0\$/  areacap met1 $1/" \
        -e "s/^  contact via1 0\$/  overlap met2 met1 300\n  contact via1 0/" base.tech
}

# run one case in its OWN directory (no stale cell.ext can leak between cases)
run() {   # $1 tag  $2 areacap  $3 geometry.tcl  $4 fmt  $5 WX  $6 WY
    local d="$WORK/$1"
    rm -rf "$d"; mkdir -p "$d"
    mktech "$2" > "$d/bridge.tech"
    cp extract_spef.tcl "$3" "$d"/
    ( cd "$d" && TECHF=./bridge.tech GEOM="$3" FMT="$4" OUT=out WX="${5:-0}" WY="${6:-0}" \
        "$MAGIC_BIN" -dnull -noconsole extract_spef.tcl >log 2>&1 )
    [ -f "$d/out" ] || fail "$1: ext2spice produced no output (see $d/log)"
}

# the ground-cap entry for a net: "*CAP" line "<idx> <net> <value>"
gndcap() { awk -v n="$2" '/^\*CAP/{c=1;next} c&&NF==3&&$2==n{print $3; exit}' "$1"; }
# the coupling entry "<idx> <netA> <netB> <value>"
coupcap() { awk '/^\*CAP/{c=1;next} c&&NF==4{print $4; exit}' "$1"; }
# the *D_NET total for a net
dnet() { awk -v n="$2" '$1=="*D_NET"&&$2==n{print $3; exit}' "$1"; }

check() { [ "$2" = "$3" ] || fail "$1: expected $3, got $2"; echo "  $1 = $2 fF  (as hand-computed)"; }

# ---- 1. ground capacitance --------------------------------------------------
run c1 100 geom_plate.tcl spef 1000 100
grep -q '^\*C_UNIT 1 FF' c1/out || fail "SPEF header missing '*C_UNIT 1 FF'"
check "1 ground cap  K=100 1000x100 -> 100*100000/1000" "$(gndcap c1/out NET1)" "10000"

# ---- 2. cross-check against magic's own SPICE emission ----------------------
run c2 100 geom_plate.tcl ngspice 1000 100
spice_c="$(awk '/^C0 /{print $4; exit}' c2/out)"
[ "$spice_c" = "10p" ] || fail "2 cross-check: SPICE emitted '$spice_c', expected 10p (= 10000 fF)"
echo "  2 cross-check: SPICE emits $spice_c = 10000 fF -> SPEF and SPICE agree"

# ---- 3. PROVEN-NEGATIVE: double the AREA, value must double -----------------
run c3 100 geom_plate.tcl spef 2000 100
check "3 double area  K=100 2000x100 -> 100*200000/1000" "$(gndcap c3/out NET1)" "20000"

# ---- 4. PROVEN-NEGATIVE: double the COEFFICIENT, value must double ----------
run c4 200 geom_plate.tcl spef 1000 100
check "4 double coeff K=200 1000x100 -> 200*100000/1000" "$(gndcap c4/out NET1)" "20000"

# ---- 5. coupling capacitance, attributed to both nets ----------------------
run c5 100 geom_couple.tcl spef
check "5 ground   on NET1  -> 100*1000*100/1000" "$(gndcap  c5/out NET1)" "10000"
check "5 coupling NET1-NET2 -> 300*500*100/1000" "$(coupcap c5/out)"      "15000"
check "5 *D_NET NET1 total  -> 10000 + 15000"    "$(dnet    c5/out NET1)" "25000"
check "5 *D_NET NET2 total  -> coupling share"   "$(dnet    c5/out NET2)" "15000"

echo "PASS: SPEF *D_NET/*CONN/*CAP carries the extracted ground and coupling"
echo "      capacitance at the exact hand-computed values, agrees with magic's"
echo "      own SPICE emission, and tracks both geometry and tech coefficient."
echo "NOTE: the *RES section is implemented but NOT verified by this gate."
exit 0
