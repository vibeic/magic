#!/bin/bash
#
# Regression: DEF vias-by-rule instantiation + the NONDEFAULTRULES path
# (roadmap #48, P1).
#
# WHAT WAS ACTUALLY WRONG.  Upstream magic already parses the NONDEFAULTRULES
# section and already instantiates a by-rule via (LefGenViaGeometry), and the
# non-default WIDTH is already applied to routes.  The real defect was that the
# "generated" flag in DefReadVias is function-scope and was only ever SET, never
# cleared per via.  So once ANY via in a VIAS section was declared by rule, every
# LATER via -- including a plain RECT composite via -- also took the generated
# path at its ';' and was rebuilt from the PREVIOUS via's stale cut / spacing /
# enclosure values, silently discarding the geometry the DEF declared.  A DEF
# that mixes router-generated NDR vias with RECT vias (the OpenROAD CTS case
# this roadmap row is about) therefore imported wrong via geometry.
#
# A second defect: "inlayer" in DefReadNonDefaultRules was read before it was
# ever assigned, so the first rule in a NONDEFAULTRULES section branched on an
# indeterminate value.
#
# THE NUMBERS.  Magic builds a generated via at half resolution, which makes the
# half-extent in internal units numerically equal to the DEF-unit width:
#
#     half_extent[internal units] = CUTSIZE*COLS + CUTSPACING*(COLS-1) + 2*ENCLOSURE
#
#   A CUTSIZE 140 CUTSPACING 170 ENCLOSURE 100 ROWCOL 1 -> 140*1 +   0 + 200 = 340
#   B CUTSIZE 140 CUTSPACING 170 ENCLOSURE 200 ROWCOL 1 -> 140*1 +   0 + 400 = 540
#   C CUTSIZE 340 CUTSPACING 170 ENCLOSURE 100 ROWCOL 1 -> 340*1 +   0 + 200 = 540
#   D CUTSIZE 140 CUTSPACING 170 ENCLOSURE 100 ROWCOL 2 -> 140*2 + 170 + 200 = 650
#
# A->B sweeps ENCLOSURE, A->C sweeps CUTSIZE, A->D sweeps ROWCOL (and with it
# CUTSPACING).  Each declared parameter moves the geometry by its own exact
# predicted amount, so every one of them is proven load-bearing and no constant
# or default could reproduce all four.
#
#   E RECT via alone, RECT met1 (-100,-100)(100,100) -> half-extent 200
#   F the SAME RECT via preceded in the same VIAS section by a by-rule via
#     -> must ALSO be 200.
#
# F is the regression that the stale flag caused.  Before the fix it measured
# 1940, and that number is itself exactly predicted by the bug: DEF_VIAS_START
# reset rows/cols to 1 but not the cut/spacing/enclosure, so the RECT via was
# rebuilt as 140*1 + 170*0 + 2*900 = 1940 from the previous via's parameters.
# The gate therefore pins BOTH the correct value and the specific corruption.
#
#   G a net referencing an UNDECLARED NONDEFAULTRULE must be REPORTED as an
#     error, not silently defaulted.
#
# chip/PDK-AGNOSTIC: synthetic LEF/DEF + the generated bridge tech only.
#
# Usage:  ./run.sh [MAGIC_BIN]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAGIC_BIN="${1:-magic}"
PY="${PYTHON:-python3}"
GEN="$HERE/../lvs_bridge_tech_multimetal/gen_bridge_tech.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE"/stack.lef "$HERE"/probe_via.tcl "$HERE"/mk_via_def.py "$WORK"/
cp "$GEN" "$WORK"/gen_bridge_tech.py
cd "$WORK" || exit 2

fail() { echo "FAIL: $1"; exit 1; }

"$PY" gen_bridge_tech.py --lef stack.lef --name bridge -o bridge.tech >/dev/null \
    || fail "bridge tech generation failed"

# read a DEF; echo the painted half-extent about the route point (20000 internal)
halfext() {
    BRIDGE_TECH="$WORK/bridge.tech" STACK_LEF="$WORK/stack.lef" DEF_FILE="$WORK/$1" \
        "$MAGIC_BIN" -dnull -noconsole probe_via.tcl 2>/dev/null \
        | awk '/^GEOM_BBOX/{print $4 - 20000; exit}'
}
deflog() {
    BRIDGE_TECH="$WORK/bridge.tech" STACK_LEF="$WORK/stack.lef" DEF_FILE="$WORK/$1" \
        "$MAGIC_BIN" -dnull -noconsole probe_via.tcl 2>&1
}
check() { [ "$2" = "$3" ] || fail "$1: expected $3, got $2"; echo "  $1 = $2  (as hand-computed)"; }

# ---- A-D: by-rule via instantiation; each declared parameter is load-bearing -
"$PY" mk_via_def.py --gen 140 170 100 1 --route V_GEN -o a.def
"$PY" mk_via_def.py --gen 140 170 200 1 --route V_GEN -o b.def
"$PY" mk_via_def.py --gen 340 170 100 1 --route V_GEN -o c.def
"$PY" mk_via_def.py --gen 140 170 100 2 --route V_GEN -o d.def
check "A cut=140 space=170 enc=100 rc=1 -> 140*1+0+200"   "$(halfext a.def)" "340"
check "B enc 100->200                   -> 140*1+0+400"   "$(halfext b.def)" "540"
check "C cut 140->340                   -> 340*1+0+200"   "$(halfext c.def)" "540"
check "D rowcol 1->2                    -> 140*2+170+200" "$(halfext d.def)" "650"

# ---- E: a RECT composite via alone reads back exactly as declared -----------
"$PY" mk_via_def.py --rect 100 --route V_RECT -o e.def
check "E RECT via alone (declared +/-100 DEF units)" "$(halfext e.def)" "200"

# ---- F: REGRESSION -- the same RECT via after a by-rule via in one section --
"$PY" mk_via_def.py --gen 140 170 900 3 --rect 100 --route V_RECT -o f.def
got_f="$(halfext f.def)"
if [ "$got_f" = "1940" ]; then
    fail "F: RECT via was rebuilt from the PREVIOUS via's stale by-rule values \
(140*1+0+2*900 = 1940) -- the 'generated' flag is not being reset per via"
fi
check "F RECT via after a by-rule via (must equal E)" "$got_f" "200"

# ---- G: PROVEN-NEGATIVE -- an undeclared NDR must be reported --------------
"$PY" mk_via_def.py --bad-ndr -o g.def
deflog g.def | grep -qi 'Unknown nondefault rule' \
    || fail "G: an undeclared NONDEFAULTRULE was silently accepted, not reported"
echo "  G undeclared NDR is reported as an error (not silently defaulted)"

echo "PASS: by-rule vias instantiate at the exact declared cut/spacing/enclosure/"
echo "      rowcol geometry; a RECT via is no longer corrupted by a preceding"
echo "      by-rule via; an undeclared NONDEFAULTRULE is reported."
exit 0
