# Regression: zero-width DEF route → LEF-abstract net-collapse

Guards the vibeic LVS-fidelity fix in `lef/defRead.c`
(`defNonzeroRouteWidth()`).

## The bug

Magic paints a DEF regular/special-net route wire using the routing layer's
width. When that width resolves to **zero** — which happens whenever the
routing layer carries no LEF `WIDTH` (e.g. the design's tech-LEF was never
read, so the layer is known only from the techfile `lef` section and
`info.route.width` stayed 0) and no DRC `width` rule is loaded — the wire is
built as a **zero-width, i.e. empty, rectangle** and silently dropped.

The top-level extraction then loses *all* routed connectivity. In a
LEF-abstract top-level flow (std cells / macros present only as abstract LEF
views) the abstract-cell ports still register correctly (they carry their LEF
pin paint + port labels) — they simply have nothing to connect to, so every
signal net fragments into isolated per-pin nodes, or collapses. Power survives
only because it is name-anchored. A subsequent LVS necessarily MISMATCHES.

This was the "magic's LEF-abstract top-level extraction collapses the design's
N nets into 1 node" residual. Root cause: the zero-width route wire, **not** an
unlocated abstract port.

## The fix

`defNonzeroRouteWidth()` floors any resolved route width at a minimal non-zero
value (the same `DEFAULT_WIDTH` fallback the reader already uses for a fully
unknown layer) and warns once, so the wire paints real geometry and per-net
connectivity is retained. A minimal centerline width connects the pins the
router routed between without bridging neighbours (no false shorts). It is a
no-op whenever the width is already non-zero, so normal (tech-LEF-read) flows
are unchanged.

## Fixture (chip/PDK-agnostic, sky130-open)

- `buf.lef` — an abstract macro `buf` (CORE): signal pins `A`,`Z` on `met1`,
  power pins `VPWR`/`VGND`. No devices (a black-box abstract view).
- `tinytop.def` — three `buf` instances chained by four met1 signal nets
  (`in→u0.A`, `u0.Z→u1.A`, `u1.Z→u2.A`, `u2.Z→out`) + VPWR/VGND straps.
- `extract.tcl` — reads the abstract LEF + DEF with **no tech-LEF** (so the
  route width is 0), extracts, writes `tinytop_extracted.spice`.
- `tinytop_golden.spice` — the intended connectivity (black-box `buf` chain).
- `tinytop_corrupt.spice` — one net miswired (for the proven-negative).

## Run

```sh
./run.sh [MAGIC_BIN] [NETGEN_BIN] [MAGICRC]
# defaults: magic/netgen from PATH, sky130A magicrc from $PDK_ROOT
```

Asserts (patched magic → exit 0):
1. the extracted top `.subckt` shares ≥2 internal nets across instances
   (connectivity retained, not collapsed);
2. netgen LVS vs `tinytop_golden.spice` → **MATCH**;
3. netgen LVS vs `tinytop_corrupt.spice` → **MISMATCH** (proven-negative).

Stock (unpatched) magic FAILs step 1 (0 shared nets — the wires are zero-width
and the three `buf` instances collapse; netgen reports `buf (3->1)` and
"Top level cell failed pin matching").

### Observed (sky130)

| build            | shared nets | golden LVS | corrupt LVS |
|------------------|-------------|------------|-------------|
| stock 8.3.x      | 0 (collapse)| MISMATCH   | MISMATCH    |
| vibeic (patched) | 2           | **MATCH**  | MISMATCH    |

Realistic-scale confirmation (sky130 `mdio`, 2977 cells / 404 nets, same
no-tech-LEF recipe): nets connecting ≥2 pins went from **2** (power only,
stock) to **377** (patched).
