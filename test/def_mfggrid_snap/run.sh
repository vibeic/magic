#!/bin/bash
#
# Regression: off-grid INSTANCE-PLACEMENT snap at DEF import (roadmap #47, P1).
#
# Stock magic enforces only the DEF database-unit (DBU) grid when it converts a
# COMPONENTS placement point.  A component placed at a whole number of DBU that
# is NOT a multiple of the (coarser) foundry MANUFACTURINGGRID therefore
# survives as an off-grid placement, and the off-grid instance *transform* then
# radiates off-grid vertices into every child shape (ROADMAP §2.3: 76% OFFGRID
# observed even though the routed DEF itself was on-grid).
#
# The fork (a) retains MANUFACTURINGGRID from the tech-LEF instead of
# discarding the token, and (b) snaps the placement point to it at import.
#
# THE NUMBERS (hand-computable end to end, exact to the internal unit):
#   tech-LEF   MANUFACTURINGGRID = 0.005 um
#   DEF        UNITS DISTANCE MICRONS 1000   =>  1 DBU = 0.001 um
#   bridge tech internal unit (cif scale output) = 0.0005 um  [asserted below]
#   => manufacturing grid g = 0.005 / 0.0005 = 10 internal units
#
#   A  PLACED ( 2003 2000 ) = 2.003 um = 4006 internal
#        round(4006/10)*10 = round(400.6)*10 = 401*10 = 4010   -> SNAPS UP
#   B  PLACED ( 2001 2000 ) = 2.001 um = 4002 internal
#        round(4002/10)*10 = round(400.2)*10 = 400*10 = 4000   -> SNAPS DOWN
#   C  PLACED ( 2005 2000 ) = 2.005 um = 4010 internal  (already on grid)
#        must remain EXACTLY 4010                              -> MUST NOT MOVE
#   D  same DEF as A but the tech-LEF has NO MANUFACTURINGGRID
#        must remain EXACTLY 4006 (unsnapped, stock behaviour) -> PROVEN-NEGATIVE
#
#   In every case y = 2000 DBU = 4000 internal is already a multiple of 10 and
#   must come back as exactly 4000.
#
# A and B round in OPPOSITE directions, so the gate cannot be satisfied by a
# constant offset.  C proves the snap does not silently move on-grid geometry.
# D proves the retained MANUFACTURINGGRID is load-bearing: with the identical
# DEF and the grid token removed, the coordinate is NOT snapped -- so the PASS
# is on the correct derived number, not merely on "the importer ran".
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
cp "$HERE"/stack.lef "$HERE"/buf.lef "$HERE"/probe.tcl "$HERE"/mk_def.py "$WORK"/
cp "$GEN" "$WORK"/gen_bridge_tech.py
cd "$WORK" || exit 2

fail() { echo "FAIL: $1"; exit 1; }

# ---- 0. bridge tech + the no-grid tech-LEF variant --------------------------
"$PY" gen_bridge_tech.py --lef stack.lef --name bridge -o bridge.tech >/dev/null \
    || fail "bridge tech generation failed"
grep -q "^MANUFACTURINGGRID" stack.lef || fail "fixture stack.lef lost MANUFACTURINGGRID"
grep -v "MANUFACTURINGGRID" stack.lef > nogrid.lef

# probe: report the placed lower-left of u0 in INTERNAL units
probe() {   # $1 = def file, $2 = tech-LEF
    BRIDGE_TECH="$WORK/bridge.tech" STACK_LEF="$WORK/$2" DEF_FILE="$WORK/$1" \
        "$MAGIC_BIN" -dnull -noconsole probe.tcl 2>/dev/null \
        | awk '/^PROBE_BBOX/{print $2" "$3; exit}'
}
scale() {
    BRIDGE_TECH="$WORK/bridge.tech" STACK_LEF="$WORK/stack.lef" DEF_FILE="$WORK/d_up.def" \
        "$MAGIC_BIN" -dnull -noconsole probe.tcl 2>/dev/null \
        | awk '/^PROBE_UPI/{print $2; exit}'
}

check() {   # $1 = tag, $2 = got, $3 = expected
    if [ "$2" != "$3" ]; then fail "$1: expected '$3', got '$2'"; fi
    echo "  $1: $2  (as hand-computed)"
}

"$PY" mk_def.py --x 2003 --y 2000 -o d_up.def   || fail "def gen"
"$PY" mk_def.py --x 2001 --y 2000 -o d_down.def || fail "def gen"
"$PY" mk_def.py --x 2005 --y 2000 -o d_on.def   || fail "def gen"

# ---- 1. the internal unit must be what the hand-computation assumes --------
upi="$(scale)"
case "$upi" in
    0.0005*) : ;;
    *) fail "internal unit changed ($upi != 0.0005 um); hand-computed grid g=10 no longer holds" ;;
esac
echo "internal unit = $upi um  =>  manufacturing grid = 0.005/0.0005 = 10 internal units"

# ---- 2. POSITIVE: off-grid placements snap to the EXACT expected multiple ---
check "A off-grid 4006 -> snaps UP   to 4010" "$(probe d_up.def   stack.lef)" "4010 4000"
check "B off-grid 4002 -> snaps DOWN to 4000" "$(probe d_down.def stack.lef)" "4000 4000"

# ---- 3. PROVEN-NEGATIVE (on-grid): an on-grid placement MUST NOT move -------
check "C on-grid  4010 -> unmoved    4010" "$(probe d_on.def stack.lef)" "4010 4000"

# ---- 4. PROVEN-NEGATIVE (grid load-bearing): no MANUFACTURINGGRID, no snap --
check "D no-grid  4006 -> UNSNAPPED  4006" "$(probe d_up.def nogrid.lef)" "4006 4000"

echo "PASS: DEF-import placement snaps to MANUFACTURINGGRID (up AND down to the"
echo "      exact internal unit); on-grid placement is not moved; and with the"
echo "      grid token removed the identical DEF is not snapped at all."
exit 0
