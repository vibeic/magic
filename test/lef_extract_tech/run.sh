#!/bin/bash
#
# Regression: extraction tech DERIVED FROM THE TECH-LEF when the PDK ships no
# native Magic .tech (roadmap #32, P2).
#
# A commercial / custom PDK ships LEF + GDS + a sign-off deck but no Magic
# techfile.  gen_bridge_tech.py (#45/#46) already reconstructs the layer stack
# and connectivity from the tech-LEF, but it emitted ZERO extraction
# coefficients -- so every parasitic came out 0.  That is the worst kind of
# wrong answer: silent, plausible, and it makes a design look parasitic-free.
#
# A tech-LEF that declares its layer electricals carries enough to derive real
# coefficients, and the conversion is exact:
#
#   areacap [aF/nm^2] = CPERSQDIST [pF/um^2]        (1 pF/um^2 == 1 aF/nm^2)
#   perimc  [aF/nm]   = EDGECAPACITANCE [pF/um] * 1000
#   resist  [mohm/sq] = RESISTANCE RPERSQ [ohm/sq] * 1000
#   contact [mohm]    = cut RESISTANCE [ohm] * 1000
#
# THE NUMBERS.  The point of this gate is that the expected capacitance is
# hand-computed FROM THE LEF, IN THE LEF'S OWN UNITS, without reference to any
# Magic-internal convention.  rc.lef declares for met1:
#
#     CAPACITANCE CPERSQDIST 0.00007 pF/um^2
#     EDGECAPACITANCE        0.00004 pF/um
#
#   A 10um x 10um plate: area 100 um^2, perimeter 40 um
#       area cap = 0.00007 * 100 = 0.007  pF =  7.0 fF
#       edge cap = 0.00004 *  40 = 0.0016 pF =  1.6 fF
#       total                                =  8.6 fF
#
#   A 20um x 10um plate: area 200 um^2, perimeter 60 um
#       area cap = 0.00007 * 200 = 0.014  pF = 14.0 fF
#       edge cap = 0.00004 *  60 = 0.0024 pF =  2.4 fF
#       total                                = 16.4 fF
#
# Area scales 2.0x between the two while perimeter scales only 1.5x, so the
# pair CANNOT be fitted by any single coefficient: 8.6 -> 16.4 is a ratio of
# 1.907, which is neither 2.0 (area only) nor 1.5 (perimeter only).  Both
# derived coefficients are therefore proven load-bearing.
#
# PROVEN-NEGATIVES:
#   N1 the same geometry against a tech generated from a LEF with the
#      electricals stripped extracts 0 -- this is the pre-#32 behaviour, and it
#      is what the gate is protecting against regressing to.
#   N2 that stripped LEF must be REPORTED, not silently accepted: the generator
#      names every layer it could not derive, and with --require-rc it FAILS
#      (non-zero exit) and writes NO techfile, so a caller that needs real
#      parasitics can never be handed a fabricated zero-C tech.
#
# chip/PDK-AGNOSTIC: a synthetic tech-LEF with invented round electricals.
#
# Usage:  ./run.sh [MAGIC_BIN]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAGIC_BIN="${1:-magic}"
PY="${PYTHON:-python3}"
GEN="$HERE/../lvs_bridge_tech_multimetal/gen_bridge_tech.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE"/rc.lef "$HERE"/extract_rc.tcl "$WORK"/
cp "$GEN" "$WORK"/gen_bridge_tech.py
cd "$WORK" || exit 2

fail() { echo "FAIL: $1"; exit 1; }
check() { [ "$2" = "$3" ] || fail "$1: expected $3 fF, got $2 fF"; echo "  $1 = $2 fF  (as hand-computed from the LEF)"; }

# the LEF with its electricals stripped -- the "no data" control
grep -viE '^[[:space:]]*(RESISTANCE|CAPACITANCE|EDGECAPACITANCE)' rc.lef > norc.lef

# extract one plate in its OWN directory (a stale cell.ext is silently reused
# by magic and yields wrong-but-plausible parasitics)
cap() {   # $1 tag  $2 techfile  $3 WX  $4 WY
    local d="$WORK/$1"
    rm -rf "$d"; mkdir -p "$d"
    cp extract_rc.tcl "$2" "$d"/
    ( cd "$d" && TECHF="./$(basename "$2")" WX="$3" WY="$4" OUT=out \
        "$MAGIC_BIN" -dnull -noconsole extract_rc.tcl >log 2>&1 )
    [ -f "$d/out" ] || fail "$1: ext2spice produced no SPEF (see $d/log)"
    # the *D_NET total is always emitted; a net with zero capacitance has no
    # *CAP block at all, which is exactly the N1 case below
    awk '$1=="*D_NET"{print $3; exit}' "$d/out"
}

# ---- derive the tech from the electrical-bearing LEF -----------------------
"$PY" gen_bridge_tech.py --lef rc.lef --name bridge -o rc.tech 2>derive.log \
    || fail "tech generation failed"
grep -q 'areacap met1 7e-05' rc.tech || fail "areacap not derived from CPERSQDIST"
grep -q 'perimc met1 space 0.04' rc.tech || fail "perimc not derived from EDGECAPACITANCE"
grep -q 'resist met1 125 0' rc.tech || fail "resist not derived from RESISTANCE RPERSQ"
grep -q 'contact via1 4500' rc.tech || fail "contact R not derived from cut RESISTANCE"
echo "derived: areacap 7e-05 aF/nm^2, perimc 0.04 aF/nm, resist 125 mohm/sq, contact 4500 mohm"

# ---- POSITIVE: extraction matches the hand-computed LEF numbers ------------
check "10x10um plate -> 0.00007*100 + 0.00004*40 = 7.0 + 1.6" "$(cap p1 rc.tech 10000 10000)" "8.6"
check "20x10um plate -> 0.00007*200 + 0.00004*60 = 14.0 + 2.4" "$(cap p2 rc.tech 20000 10000)" "16.4"

# ---- N1: without the LEF electricals the same geometry extracts 0 ----------
"$PY" gen_bridge_tech.py --lef norc.lef --name b0 -o norc.tech 2>norc.log \
    || fail "fallback tech generation failed"
zero="$(cap p0 norc.tech 10000 10000)"
[ "$zero" = "0" ] || fail "N1: expected 0 fF from a tech with no derived coefficients, got $zero"
echo "  N1 no-electricals LEF -> 0 fF (the pre-#32 silent-zero behaviour)"

# ---- N2: the gap must be REPORTED, and --require-rc must FAIL loudly -------
grep -qi 'no extraction electricals for' norc.log \
    || fail "N2: the missing electricals were not reported at all"
rm -f hard.tech
if "$PY" gen_bridge_tech.py --lef norc.lef --name b1 -o hard.tech --require-rc \
        >/dev/null 2>hard.log; then
    fail "N2: --require-rc accepted a LEF with no extraction electricals"
fi
[ -f hard.tech ] && fail "N2: --require-rc failed but still wrote a techfile"
grep -qi 'ERROR' hard.log || fail "N2: --require-rc failed without an ERROR message"
echo "  N2 missing electricals are named; --require-rc fails and writes no tech"

echo "PASS: extraction coefficients are derived from the tech-LEF and reproduce"
echo "      the capacitance hand-computed in the LEF's own units (8.6 / 16.4 fF,"
echo "      a 1.907x ratio that no single coefficient can fit); a LEF without"
echo "      them extracts 0 and is reported, never silently fabricated."
exit 0
