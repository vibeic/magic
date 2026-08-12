#!/usr/bin/env python3
"""Judge a GDS AREF against the array it was streamed from.

An AREF does not store element positions.  It stores THREE points -- an origin,
a column reference and a row reference -- and every reader derives

    element(i,j) = origin + i*(colref - origin)/cols + j*(rowref - origin)/rows

so the array's PITCH and SHAPE live in the DIFFERENCES between those points, not
in any one of them.  That is what makes a snap that moves only the origin a
silent geometry change: the origin shifts, the reference points do not, and the
step vectors every reader derives are therefore shorter (or longer) than the
design's by the snap delta divided by cols/rows.  A 2x2 array of a use snapped
by +20 nm loses 10 nm of pitch and gains a 10 nm shear on its second row --
measured on this fork before the fix:

    with grid     AREF XY=[20050, 20000, 40030, 20000, 20030, 40000]
    -> elements   (20050,20000) (30040,20000) (20040,30000) (30030,30000)
    -> pitch 9990 nm (design 10000), row-1 sheared -10 nm, 3 of 4 off-grid.

This script takes the streamed AREF (--got) and the SAME design streamed with no
manufacturing grid (--ref, which is stock magic's output, byte for byte), and
checks the two properties a snap owes the design:

  RIGID     every step vector of --got is the corresponding --ref step vector
            snapped to the grid -- so the array keeps its shape, and cannot
            acquire a shear or a per-row drift;
  ON-GRID   every derived element origin is an exact multiple of the grid --
            which is the whole point of snapping, and is what the origin-only
            snap fails to deliver for elements 1..n.

A step that would snap to ZERO is required to be left ALONE instead: collapsing
every element of an array onto its origin is a worse answer than an off-grid
pitch, so "unsnappable" is a legal, checked outcome rather than a silent one.

usage:
  aref_geom.py --cols C --rows R --grid NM --ref x0,y0,xc,yc,xr,yr
                                            --got x0,y0,xc,yc,xr,yr
Exit 0 and print the element table if both properties hold, else exit 1.
"""
import argparse
import sys


def snap(v, g):
    """Nearest multiple of g, round-half-away-from-zero; 0 <=> no grid."""
    if g <= 0:
        return v
    if v >= 0:
        return ((v + g // 2) // g) * g
    return -((((-v) + g // 2) // g) * g)


def snap_step(v, g):
    """As snap(), but a non-zero step is never allowed to vanish."""
    s = snap(v, g)
    return v if (s == 0 and v != 0) else s


def steps(xy, cols, rows):
    x0, y0, xc, yc, xr, yr = xy
    return ((xc - x0, yc - y0), (xr - x0, yr - y0), (x0, y0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cols", type=int, required=True)
    ap.add_argument("--rows", type=int, required=True)
    ap.add_argument("--grid", type=int, required=True, help="grid in GDS db units")
    ap.add_argument("--ref", required=True, help="AREF XY of the SAME design, no grid")
    ap.add_argument("--got", required=True, help="AREF XY under test")
    a = ap.parse_args()

    ref = [int(v) for v in a.ref.split(",")]
    got = [int(v) for v in a.got.split(",")]
    if len(ref) != 6 or len(got) != 6:
        print("FAIL: an AREF must carry exactly three XY points")
        return 1

    (rcol, rrow, _) = steps(ref, a.cols, a.rows)
    (gcol, grow, gorg) = steps(got, a.cols, a.rows)

    bad = []

    # ---- RIGID ------------------------------------------------------------
    # Per-element steps, as every GDS reader derives them.  The reference array
    # is rigid by construction (stock magic writes exact multiples), so the
    # reference per-element step is exact and the snapped one must be the
    # grid-snap of it.
    for label, rv, gv, n in (("column", rcol, gcol, a.cols),
                             ("row", rrow, grow, a.rows)):
        for axis, i in (("x", 0), ("y", 1)):
            if rv[i] % n or gv[i] % n:
                bad.append(f"{label} {axis} step {gv[i]}/{n} is not a whole number "
                           f"of db units (ref {rv[i]}/{n}): the array does not "
                           f"land on a lattice at all")
                continue
            want = snap_step(rv[i] // n, a.grid)
            have = gv[i] // n
            if have != want:
                bad.append(f"{label} {axis} step is {have} nm, expected {want} nm "
                           f"(design {rv[i] // n} nm snapped to {a.grid} nm): the "
                           f"array changed shape")

    # ---- ON-GRID ----------------------------------------------------------
    print(f"  derived elements (cols={a.cols} rows={a.rows}, grid {a.grid} nm):")
    for j in range(a.rows):
        for i in range(a.cols):
            ex = gorg[0] + i * gcol[0] // a.cols + j * grow[0] // a.rows
            ey = gorg[1] + i * gcol[1] // a.cols + j * grow[1] // a.rows
            on = (ex % a.grid == 0) and (ey % a.grid == 0)
            print(f"    [{i},{j}] = ({ex}, {ey}) {'on-grid' if on else 'OFF-GRID'}")
            if not on:
                bad.append(f"element [{i},{j}] at ({ex}, {ey}) is not on the "
                           f"{a.grid} nm manufacturing grid")

    if bad:
        for b in bad:
            print(f"FAIL: {b}")
        return 1
    print("  RIGID: every step vector is the design's, snapped; ON-GRID: "
          "every element origin is a multiple of the grid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
