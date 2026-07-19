# lvs_layermap_autodiscover — foundry LEF/DEF layer-map auto-discovery (#46, P0)

Regression for **roadmap #46 / #38**: derive a no-native-tech PDK's *foundry*
GDS layer/datatype numbers from its layer-map instead of the compact 1..N
fallback, so Magic can read a real foundry GDS (routing + pin labels land on
the right types) and write foundry-canonical GDS — the prerequisite for LVS
to keep every top-level anchor.

## Why it matters

A commercial / custom PDK ships **LEF + GDS + a sign-off deck but no Magic
`.tech`**. `gen_bridge_tech.py` (#45) synthesises a bridge tech from the
tech-LEF's layer set. Without the foundry map it can only assign a **compact**
numbering (`met1=60/0, met2=61/0, …`). But the foundry GDS sits on the
foundry's own numbers (`met1=68/20, …`), so:

* reading the foundry GDS with a compact tech maps **nothing** — every boundary
  is `Unknown layer/datatype`, the top routing **and** the pin labels vanish,
  and LVS has no anchors;
* GDS *written* by Magic carries the compact numbers, so it is not
  round-trippable against the foundry map.

`gen_bridge_tech.py` now **auto-discovers** a `*.layermap` / `*.map` next to the
tech-LEF (or takes `--layermap`), and threads the real foundry layer/datatype
into both the cif **read** (`cifinput`) and cif **write** (`cifoutput calma`)
sections. `--no-layermap` forces the old compact fallback for comparison.

## Files (all NDA-clean, generic layer names)

| file | role |
|------|------|
| `stack.lef` | tech-LEF: routing met1/met2/met3 + cut via1/via2 |
| `stack.layermap` | foundry map — non-compact, non-zero datatypes (`met1 68 20`, …) |
| `wrong.layermap` | deliberately wrong numbers — the proven-negative |
| `gen_foundry_gds.py` | pure-stdlib GDSII writer → a foundry-numbered GDS (independent of Magic streamout, so no circularity) |
| `top_golden.spice` | golden top with the two anchored nets IN / OUT |
| `run.sh` | the gate |

## The gate (`./run.sh [MAGIC_BIN] [NETGEN_BIN]`)

The foundry GDS holds two disjoint metal stacks — net **IN** (met1→via1→met2,
label IN) and net **OUT** (met2→via2→met3, label OUT) — exercising all five
foundry layers.

1. **FOUNDRY** (auto-discovered `stack.layermap`): Magic reads the GDS with
   **no** `Unknown layer/datatype`, extracts both routing anchors, and netgen
   LVS vs golden reports **"Cell pin lists are equivalent"**. → PASS
2. **COMPACT** (`--no-layermap`, the stock fallback): every foundry boundary is
   `Unknown layer/datatype`; **0** routing ports are anchored → LVS broken.
3. **WRONG-MAP** (`--layermap wrong.layermap`): a map with the wrong numbers
   *also* drops every layer — proving the gate passes on the **correct derived
   numbers**, not merely because "a map exists".

chip/PDK-AGNOSTIC, OPEN sky130-class tooling only.
