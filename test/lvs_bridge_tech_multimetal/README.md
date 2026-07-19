# Regression: multi-metal LEF-abstract LVS via a generated Magic bridge tech

Guards the multi-metal robustness path for Magic's LEF-abstract + routed-DEF
LVS extraction, complementing the single-metal `lvs_zero_width_route` fix.

## The scenario

A commercial / custom PDK often ships **no Magic technology file** — only LEF
(abstract cells + a routing stack) + GDS + a foundry sign-off deck. To run
Magic's `def read` + `extract` LVS on such a node, a **bridge techfile** must
declare *every* routing metal and *every* via/contact, so extraction can trace
connectivity through the full metal stack.

A bridge tech that models only `metal1` drops every higher-metal wire and every
via: a net that routes up the stack fragments into isolated per-pin nodes — the
classic "N nets collapse under LEF-abstract extraction" failure. The
`metalN metal(N+1)` **via contact** rules are the load-bearing piece — they are
what electrically bridge two metal planes.

## The generator

`gen_bridge_tech.py` emits a **complete** bridge techfile, PDK-parameterised
straight from the tech-LEF's own layer set:

- `parse_tech_lef` reads the ordered `LAYER … TYPE ROUTING` / `TYPE CUT` set
  (file order; cut *i* bridges routing *i* and *i+1* — the universal planar
  stack).
- `build_tech` writes `planes` / `types` / **`contact viaN metalN metal(N+1)`**
  / `connect *mN *mN` / `lef` name-map / the `cifoutput`/`cifinput`/`extract`
  sections Magic requires. Modelling only metal1 is structurally impossible —
  the emitter iterates *all* routing layers and *all* cuts.

## Fixture (chip/PDK-agnostic, sky130-open, NDA-clean generic layer names)

- `stack.lef` — a 3-metal routing stack (`met1`/`via1`/`met2`/`via2`/`met3`)
  with widths + default via geometry.
- `buf.lef` — an abstract macro `buf` (signal pins `A`,`Z` on met1; power
  `VPWR`/`VGND`). No devices (a black-box abstract view).
- `top.def` — three `buf` instances chained. The two **inter-cell** nets
  (`n01` = u0.Z→u1.A, `n12` = u1.Z→u2.A) route *up the stack*
  (met1→via1→met2→via2→met3→…→met1); the only electrical path between the
  cells climbs to met3 and back.
- `top_golden.spice` / `top_corrupt.spice` — the golden buf chain and a
  mis-wired copy.

## PASS criteria (`run.sh`)

1. **Generator** emits ≥3 routing metals + ≥2 via contacts (not metal1-only).
2. **Positive** — extract with the full bridge tech: the three `buf` instances
   chain through shared inter-cell nets (multi-metal connectivity retained),
   and netgen LVS vs `top_golden.spice` ⇒ **MATCH**.
3. **Non-vacuous** — netgen LVS vs `top_corrupt.spice` ⇒ **MISMATCH**.
4. **Proven-negative (tech)** — re-emit the same tech with `--drop-contacts`
   (metals still defined, via bridges removed): the cross-metal nets
   **fragment** (0 shared inter-cell nets) and netgen LVS vs the golden ⇒
   **MISMATCH**. This proves the via/contact rules are load-bearing, not
   cosmetic.

## Run

```
./run.sh [MAGIC_BIN] [NETGEN_BIN]      # defaults: magic / netgen on PATH
```

No PDK Magic techfile is used — only the *generated* bridge tech + the LEFs,
exactly the commercial/custom-PDK path.
