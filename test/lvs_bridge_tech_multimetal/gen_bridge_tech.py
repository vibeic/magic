#!/usr/bin/env python3
"""gen_bridge_tech.py — generate a COMPLETE multi-metal Magic bridge techfile.

A commercial / custom PDK often ships no Magic technology file, only LEF +
GDS + a foundry sign-off deck. To run Magic's LEF-abstract + routed-DEF LVS
extraction on such a node, a "bridge" techfile must declare EVERY routing
metal and EVERY via/contact so Magic can reconstruct full-stack connectivity.

A bridge tech that models only metal1 drops every higher-metal wire and every
via, so a net that routes up the stack fragments into isolated per-pin nodes
(the "N nets -> collapsed" LEF-abstract failure). This generator emits the
whole stack, PDK-parameterised from the tech-LEF's own layer set:

  * planes   : one plane per routing metal
  * types    : the metal type on its plane + each via type on its LOWER metal
  * contact  : `viaN metalN metal(N+1)` for every via  (the load-bearing rule:
               this is what electrically bridges the two metal planes)
  * connect  : `*mN *mN` per metal (the `*` auto-includes the contacts)
  * lef      : map each LEF routing / cut layer name to its Magic type
  * cifoutput/cifinput/extract : the sections Magic requires for a valid tech

chip/PDK-AGNOSTIC: `parse_tech_lef` derives the ordered (metal, cut) stack
straight from any tech-LEF (LAYER ... TYPE ROUTING / TYPE CUT, in file order;
cut i is assumed to connect routing i and i+1, the universal planar stack).
The `--drop-contacts` switch emits an otherwise-identical tech with the
`contact` bodies removed, used as the proven-negative: with the metals still
defined but the via bridges gone, a cross-metal net MUST fragment.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from typing import List


@dataclass
class Metal:
    mtype: str            # Magic type name, e.g. "met1"
    plane: str            # Magic plane name, e.g. "PL_met1"
    lef_names: List[str]  # LEF routing layer aliases
    gds_layer: int = 0    # nominal (cifio only; unused by def-read extraction)
    width: int = 2        # a nominal DRC width rule


@dataclass
class Cut:
    ctype: str            # Magic contact type, e.g. "via1"
    lef_names: List[str]  # LEF cut layer aliases
    lower: int = 0        # index into metals (lower plate)
    upper: int = 1        # index into metals (upper plate)
    gds_layer: int = 0


def _aliases(name: str) -> List[str]:
    """Distinct LEF-name spellings Magic should map to one type."""
    out: List[str] = []
    for cand in (name, name.upper(), name.lower()):
        if cand not in out:
            out.append(cand)
    return out


def parse_tech_lef(text: str) -> "tuple[List[Metal], List[Cut]]":
    """Derive the ordered routing/cut stack from a tech-LEF's layer set.

    Returns (metals, cuts) with cut i wired between routing i and i+1 — the
    universal planar via stack. GDS numbers are assigned sequentially (they
    are only referenced by cifin/out, which the def-read extraction flow does
    not exercise).
    """
    metals: List[Metal] = []
    cuts_raw: List[str] = []
    order: List[tuple] = []  # (kind, name) in LEF file order
    layer = None
    ltype = None
    for line in text.splitlines():
        s = line.strip()
        m = re.match(r"^LAYER\s+(\S+)", s)
        if m:
            layer = m.group(1)
            ltype = None
            continue
        if layer is not None:
            tm = re.match(r"^TYPE\s+(\w+)", s)
            if tm:
                ltype = tm.group(1).upper()
            if s.startswith("END") and layer in s:
                if ltype == "ROUTING":
                    order.append(("routing", layer))
                elif ltype == "CUT":
                    order.append(("cut", layer))
                layer = None
                ltype = None
    gds = 60
    metal_idx: List[int] = []  # position in `order` of each metal (unused)
    ri = 0
    for kind, name in order:
        if kind == "routing":
            metals.append(Metal(mtype=name, plane=f"PL_{name}",
                                 lef_names=_aliases(name), gds_layer=gds))
            gds += 1
            ri += 1
        else:
            cuts_raw.append(name)
    # wire cut i between routing i and i+1 (planar stack)
    cuts: List[Cut] = []
    gdsc = 100
    for i, name in enumerate(cuts_raw):
        lo = i
        hi = i + 1
        if hi >= len(metals):
            hi = len(metals) - 1
        cuts.append(Cut(ctype=name, lef_names=_aliases(name),
                        lower=lo, upper=hi, gds_layer=gdsc))
        gdsc += 1
    return metals, cuts


def build_tech(metals: List[Metal], cuts: List[Cut], name: str = "bridge",
               stackable: bool = True, drop_contacts: bool = False) -> str:
    if not metals:
        raise ValueError("bridge tech needs at least one routing metal")
    L: List[str] = []
    L.append(f"# {name}.tech — multi-metal Magic LVS/streamin bridge (generated)")
    L.append(f"# {len(metals)} routing metals, {len(cuts)} via/contact layers")
    if drop_contacts:
        L.append("# NEGATIVE VARIANT: via CONTACT rules removed on purpose "
                 "(cross-metal nets must fragment).")
    L.append("tech")
    L.append("  format 32")
    L.append(f"  {name}")
    L.append("end")
    L.append("")
    L.append("version")
    L.append("  version 1.0")
    L.append('  description "generated multi-metal LVS bridge"')
    L.append("end")
    L.append("")
    L.append("planes")
    for m in metals:
        L.append(f"  {m.plane},{m.mtype}")
    L.append("end")
    L.append("")
    L.append("types")
    for m in metals:
        L.append(f"  {m.plane} {m.mtype}")
    for c in cuts:
        L.append(f"  {metals[c.lower].plane} {c.ctype}")
    L.append("end")
    L.append("")
    L.append("contact")
    if not drop_contacts:
        for c in cuts:
            L.append(f"  {c.ctype} {metals[c.lower].mtype} "
                     f"{metals[c.upper].mtype}")
        if stackable and cuts:
            L.append("  stackable")
    L.append("end")
    L.append("")
    L.append("styles")
    L.append("end")
    L.append("")
    L.append("compose")
    L.append("end")
    L.append("")
    L.append("connect")
    for m in metals:
        L.append(f"  *{m.mtype} *{m.mtype}")
    L.append("end")
    L.append("")
    L.append("cifoutput")
    L.append("  style drc")
    L.append("  scalefactor 1 nanometers")
    for m in metals:
        L.append(f"  layer o_{m.mtype} {m.mtype}")
        L.append(f"    labels {m.mtype} port")
    for c in cuts:
        L.append(f"  layer o_{c.ctype} {c.ctype}")
    L.append("end")
    L.append("")
    L.append("cifinput")
    L.append("  style drc")
    L.append("  scalefactor 1 nanometers")
    for m in metals:
        L.append(f"  layer {m.mtype} {m.gds_layer}/0")
        L.append(f"    labels {m.gds_layer}/0")
    for c in cuts:
        L.append(f"  layer {c.ctype} {c.gds_layer}/0")
    L.append("end")
    L.append("")
    L.append("lef")
    for m in metals:
        L.append(f"  routing {m.mtype} {' '.join(m.lef_names)}")
    for c in cuts:
        L.append(f"  cut {c.ctype} {' '.join(c.lef_names)}")
    L.append("end")
    L.append("")
    L.append("extract")
    L.append("  style bridge")
    L.append("  cscale 1")
    L.append("  lambda 0.005")
    L.append("  step 100")
    L.append("  sidehalo 0")
    for m in metals:
        L.append(f"  areacap {m.mtype} 0")
        L.append(f"  resist {m.mtype} 0 0")
    for c in cuts:
        L.append(f"  contact {c.ctype} 0")
    L.append("end")
    L.append("")
    L.append("drc")
    for m in metals:
        L.append(f'  width {m.mtype} {m.width} "{m.mtype} width"')
    L.append("end")
    return "\n".join(L) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--lef", help="tech-LEF to derive the metal/cut stack from")
    ap.add_argument("--metals", help="comma list of routing layer names "
                    "(overrides --lef)")
    ap.add_argument("--cuts", help="comma list of cut/via layer names")
    ap.add_argument("--name", default="bridge")
    ap.add_argument("--drop-contacts", action="store_true",
                    help="negative variant: omit the via contact rules")
    ap.add_argument("-o", "--out", help="output tech path (default stdout)")
    args = ap.parse_args(argv)

    if args.metals:
        mets = [Metal(mtype=n, plane=f"PL_{n}", lef_names=_aliases(n),
                      gds_layer=60 + i)
                for i, n in enumerate(x.strip() for x in args.metals.split(","))]
        cutn = [x.strip() for x in (args.cuts or "").split(",") if x.strip()]
        cuts = [Cut(ctype=n, lef_names=_aliases(n), lower=i, upper=i + 1,
                    gds_layer=100 + i)
                for i, n in enumerate(cutn)]
    elif args.lef:
        mets, cuts = parse_tech_lef(open(args.lef).read())
    else:
        ap.error("need --lef or --metals")
        return 2
    tech = build_tech(mets, cuts, name=args.name,
                      drop_contacts=args.drop_contacts)
    if args.out:
        open(args.out, "w").write(tech)
    else:
        sys.stdout.write(tech)
    return 0


if __name__ == "__main__":
    sys.exit(main())
