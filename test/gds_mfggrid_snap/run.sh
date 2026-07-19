#!/bin/bash
#
# Regression: off-grid INSTANCE-ORIGIN snap to MANUFACTURINGGRID at GDS
# streamout (roadmap #37, P1) -- the write-side counterpart of #47.
#
# #47 snaps the placement point when a DEF is imported.  But an instance can
# acquire an off-grid transform without ever passing through that path (a cell
# placed interactively or by a script, a macro whose own origin sits at a
# fractional grid, a design assembled before the tech-LEF was read).  At
# streamout the off-grid SREF/AREF translation then radiates off-grid vertices
# into every child shape in the GDS.  The fork snaps the instance origin (and
# the expanded-array origins) to the retained MANUFACTURINGGRID at write.
#
# THE NUMBERS (hand-computable, verified against the GDS bytes):
#   tech             internal unit (cif scale output) = 0.005 um   [asserted]
#   GDS database unit                                 = 0.001 um (1 nm)
#   synthetic tech-LEF  MANUFACTURINGGRID             = 0.05 um
#   => grid g = 0.05 / 0.005 = 10 internal units
#
#   instance placed at internal 4006  (= 20.030 um)
#     round(4006/10)*10 = round(400.6)*10 = 401*10 = 4010 internal = 20.050 um
#     GDS is in nm, so the SREF XY must read  20050
#
#   A  WITH the grid LEF : SREF X = 20050  ->  20.050 / 0.05 = 401     ON grid
#   B  NO   grid LEF     : SREF X = 20030  ->  20.030 / 0.05 = 400.6  OFF grid
#
#   y is placed at internal 4000 = 20.000 um = 400 * 0.05 exactly, so it is
#   already on the manufacturing grid and MUST read 20000 in BOTH cases --
#   the built-in proven-negative that on-grid geometry is never moved.
#
# The SREF coordinates are read back out of the GDS by read_sref.py, a
# pure-stdlib GDSII parser that shares no code with magic's writer, so a
# self-consistent round-trip bug cannot satisfy this gate.  Case B additionally
# proves the retained MANUFACTURINGGRID is load-bearing: same design, same
# writer, grid token absent => the coordinate is NOT snapped.
#
# Uses an OPEN PDK tech (whatever `tech load` resolves) purely because the
# streamout path needs an integer internal->GDS scale; the MANUFACTURINGGRID
# under test comes from a synthetic NDA-clean LEF in this directory.
#
# Usage:  ./run.sh [MAGIC_BIN] [TECHNAME]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAGIC_BIN="${1:-magic}"
TECHNAME="${2:-ihp-sg13g2}"
PY="${PYTHON:-python3}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE"/grid50.lef "$HERE"/build.tcl "$HERE"/read_sref.py "$WORK"/
cd "$WORK" || exit 2

fail() { echo "FAIL: $1"; exit 1; }
skip() { echo "SKIP: $1"; exit 0; }

# first SREF's XY, as "<x> <y>" in GDS database units
sref_x() {
    "$PY" read_sref.py "$1" \
        | sed -n 's/^SREF .*XY=\[\(-\?[0-9]*\), *\(-\?[0-9]*\)\].*/\1 \2/p' \
        | head -1
}

# ---- A: with the MANUFACTURINGGRID tech-LEF --------------------------------
TECHNAME="$TECHNAME" GRID_LEF="$WORK/grid50.lef" OUT_GDS="$WORK/a.gds" \
    "$MAGIC_BIN" -dnull -noconsole build.tcl >a.log 2>&1
[ -f a.gds ] || skip "streamout produced no GDS (tech '$TECHNAME' unavailable?); see a.log"

upi=$(awk '/^SCALE/{print $2; exit}' a.log)
near() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d < b*1e-6)}'; }
near "$upi" 0.005 \
    || skip "internal unit is $upi um, not the 0.005 um this hand-computation assumes"
ibbox=$(awk '/^IBBOX/{print $2; exit}' a.log)
[ "$ibbox" = "4006" ] || fail "fixture drift: instance placed at internal $ibbox, expected 4006"
echo "internal unit = $upi um; instance at internal 4006; grid 0.05/0.005 = 10 internal units"

got_a="$(sref_x a.gds)"
[ "$got_a" = "20050 20000" ] || fail "A: expected SREF XY '20050 20000' nm, got '$got_a'"
echo "  A with MANUFACTURINGGRID: SREF XY = $got_a nm  -> 20.050/0.05 = 401 exactly ON grid"

# ---- B: PROVEN-NEGATIVE -- identical design, no grid token ------------------
TECHNAME="$TECHNAME" OUT_GDS="$WORK/b.gds" \
    "$MAGIC_BIN" -dnull -noconsole build.tcl >b.log 2>&1
[ -f b.gds ] || fail "B: streamout produced no GDS"
got_b="$(sref_x b.gds)"
[ "$got_b" = "20030 20000" ] || fail "B: expected SREF XY '20030 20000' nm (unsnapped), got '$got_b'"
echo "  B no MANUFACTURINGGRID  : SREF XY = $got_b nm  -> 20.030/0.05 = 400.6 OFF grid"

# ---- the y coordinate was on-grid in both cases and never moved ------------
echo "  y = 20000 nm in BOTH cases (= 400 * 0.05 um) -> on-grid origin not moved"

echo "PASS: streamout snaps the off-grid instance origin to MANUFACTURINGGRID"
echo "      (20030 -> 20050 nm, the exact nearest multiple); with the grid token"
echo "      absent the same design streams out unsnapped; on-grid y is untouched."
exit 0
