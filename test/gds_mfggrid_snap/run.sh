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
cp "$HERE"/grid50.lef "$HERE"/build.tcl "$HERE"/read_sref.py "$HERE"/aref_geom.py "$WORK"/
cd "$WORK" || exit 2

fail() { echo "FAIL: $1"; exit 1; }
skip() { echo "SKIP: $1"; exit 0; }

# first SREF's XY, as "<x> <y>" in GDS database units
sref_x() {
    "$PY" read_sref.py "$1" \
        | sed -n 's/^SREF .*XY=\[\(-\?[0-9]*\), *\(-\?[0-9]*\)\].*/\1 \2/p' \
        | head -1
}

# first AREF's THREE XY points, as "x0,y0,xc,yc,xr,yr" in GDS database units
aref_xy() {
    "$PY" read_sref.py "$1" \
        | sed -n 's/^AREF .*XY=\[\(.*\)\].*/\1/p' \
        | head -1 | tr -d ' '
}

# Stream the fixture and hand back its AREF.  $1 = tag, $2 = "cols rows",
# $3 = child width in lambda, $4 = "grid" | "nogrid", $5 = directory to work in.
stream_array() {
    _tag="$1"; _arr="$2"; _cw="$3"; _grid="$4"; _dir="$5"
    mkdir -p "$_dir"; cp grid50.lef build.tcl read_sref.py "$_dir"/ 2>/dev/null
    ( cd "$_dir" || exit 2
      if [ "$_grid" = grid ]; then _lef="$_dir/grid50.lef"; else _lef=""; fi
      env TECHNAME="$TECHNAME" ARRAY="$_arr" CHILDW="$_cw" \
          ${_lef:+GRID_LEF="$_lef"} OUT_GDS="$_dir/$_tag.gds" \
          "$MAGIC_BIN" -dnull -noconsole build.tcl >"$_tag.log" 2>&1 )
    [ -f "$_dir/$_tag.gds" ] || fail "$_tag: streamout produced no GDS; see $_dir/$_tag.log"
    aref_xy "$_dir/$_tag.gds"
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

# ===========================================================================
# ARRAYS.  Cases A/B assert the FIRST SREF only, which is why they stayed green
# on a tree that streamed distorted arrays for a month.  An AREF carries THREE
# XY points and the array's pitch is the DIFFERENCE between them, so snapping
# the origin alone does not move an array onto the grid -- it changes the
# array's shape.  Measured on this fork before the fix:
#
#   with grid   AREF XY=[20050, 20000, 40030, 20000, 20030, 40000]
#               -> pitch 9990 nm (design 10000) and row 1 sheared -10 nm in x,
#                  3 of 4 elements still off the 50 nm grid
#   stock magic AREF XY=[20030, 20000, 40030, 20000, 20030, 40000]  (rigid)
#
# The three points must therefore ALL be rebuilt from the snapped origin.
# ===========================================================================

# ---- C: a 2x2 array whose pitch IS a multiple of the grid ------------------
# child bbox 1000 lambda = 2000 internal = 10000 nm = 200 * 50 nm, so the step
# needs no snapping and only the ORIGIN moves: 20030 -> 20050.  Every reference
# point moves with it, so the array is translated, never deformed.
got_c="$(stream_array c "2 2" 1000 grid "$WORK/even")"
got_d="$(stream_array d "2 2" 1000 nogrid "$WORK/even")"
[ -n "$got_c" ] || fail "C: no AREF in the streamed GDS (did the array survive?)"
want_c="20050,20000,40050,20000,20050,40000"
want_d="20030,20000,40030,20000,20030,40000"
[ "$got_d" = "$want_d" ] \
    || fail "D: no-grid AREF must be the untouched design '$want_d', got '$got_d'"
echo "  D no MANUFACTURINGGRID  : AREF XY = $got_d  (stock magic's bytes)"
[ "$got_c" = "$want_c" ] \
    || fail "C: expected AREF XY '$want_c' (origin snapped +20 nm and BOTH reference points carried with it), got '$got_c'"
echo "  C with MANUFACTURINGGRID: AREF XY = $got_c"
"$PY" aref_geom.py --cols 2 --rows 2 --grid 50 --ref "$got_d" --got "$got_c" \
    || fail "C: the snapped array is not a rigid, on-grid copy of the design"

# ---- E: a 2x2 array whose pitch is NOT a multiple of the grid --------------
# child bbox 1001.5 lambda = 2003 internal = 10015 nm, and 10015/50 = 200.3.
# Here the STEP has to be snapped too (10015 -> 10000 nm) or elements 1..n stay
# off-grid no matter what the origin does.  Snapping the step and rebuilding
# the reference points from it keeps the array rigid AND puts it on the grid.
got_e="$(stream_array e "2 2" 1001.5 grid "$WORK/odd")"
got_f="$(stream_array f "2 2" 1001.5 nogrid "$WORK/odd")"
want_e="20050,20000,40050,20000,20050,40000"
want_f="20030,20000,40060,20000,20030,40000"
[ "$got_f" = "$want_f" ] \
    || fail "F: no-grid AREF must be the untouched design '$want_f', got '$got_f'"
echo "  F no MANUFACTURINGGRID  : AREF XY = $got_f  (pitch 10015 nm, off-grid)"
[ "$got_e" = "$want_e" ] \
    || fail "E: expected AREF XY '$want_e' (pitch 10015 -> 10000 nm, rebuilt from the snapped origin), got '$got_e'"
echo "  E with MANUFACTURINGGRID: AREF XY = $got_e"
"$PY" aref_geom.py --cols 2 --rows 2 --grid 50 --ref "$got_f" --got "$got_e" \
    || fail "E: the snapped array is not a rigid, on-grid copy of the design"

# ---- G: the flattened form must describe the SAME geometry -----------------
# `gds arrays true` writes one SREF per element instead of an AREF.  It is the
# same array, so it must land on the same coordinates the AREF derives; a snap
# applied per-element there gives a different answer for the same design (and a
# non-uniform pitch, since each element rounds independently).
cp grid50.lef build.tcl read_sref.py "$WORK/odd"/ 2>/dev/null
( cd "$WORK/odd" || exit 2
  sed 's|^gds write|gds arrays true\ngds write|' build.tcl >flat.tcl
  env TECHNAME="$TECHNAME" ARRAY="2 2" CHILDW=1001.5 GRID_LEF="$WORK/odd/grid50.lef" \
      OUT_GDS="$WORK/odd/g.gds" "$MAGIC_BIN" -dnull -noconsole flat.tcl >g.log 2>&1 )
[ -f "$WORK/odd/g.gds" ] || fail "G: flattened streamout produced no GDS"
got_g="$("$PY" read_sref.py "$WORK/odd/g.gds" \
        | sed -n 's/^SREF .*XY=\[\(.*\)\].*/(\1)/p' | tr -d ' ' | sort | tr '\n' ' ')"
want_g="(20050,20000) (20050,30000) (30050,20000) (30050,30000) "
[ "$got_g" = "$want_g" ] \
    || fail "G: flattened array elements are '$got_g', expected '$want_g' -- the AREF and the flattened form disagree about where the same array is"
echo "  G flattened (one SREF per element): $got_g"

echo "PASS: streamout snaps the off-grid instance origin to MANUFACTURINGGRID"
echo "      (20030 -> 20050 nm, the exact nearest multiple); with the grid token"
echo "      absent the same design streams out unsnapped; on-grid y is untouched;"
echo "      and an ARRAY is snapped as a whole -- both reference points rebuilt"
echo "      from the snapped origin and the step snapped as a vector -- so it"
echo "      keeps its pitch and its shape, in both the AREF and flattened forms."
exit 0
