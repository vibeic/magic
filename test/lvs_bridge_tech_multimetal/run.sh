#!/bin/bash
#
# Regression: multi-metal LEF-abstract LVS via a GENERATED Magic bridge tech.
#
# Scenario (commercial/custom PDK with NO native Magic techfile):
#   gen_bridge_tech.py reads the tech-LEF's layer set (stack.lef: met1..met3,
#   via1/via2) and emits a COMPLETE bridge techfile -- every routing metal +
#   every via CONTACT rule -- so Magic's def-read extraction reconstructs
#   full-stack connectivity. The two inter-cell nets (n01, n12) route UP the
#   stack (met1->via1->met2->via2->met3->...->met1), so they are preserved
#   ONLY if the higher metals and via contacts are modeled.
#
# PASS criteria:
#   (1) POSITIVE: extract with the full bridge tech -> the 3 buf cells chain
#       through shared inter-cell nets (multi-metal connectivity retained),
#       AND netgen LVS vs the golden schematic => MATCH.
#   (2) NON-VACUOUS: netgen LVS vs the CORRUPTED schematic => MISMATCH.
#   (3) PROVEN-NEGATIVE (tech): re-emit the SAME tech with `--drop-contacts`
#       (metals still defined, via bridges removed) -> the cross-metal nets
#       FRAGMENT -> netgen LVS vs the golden schematic => MISMATCH. This proves
#       the via/contact connect rules are load-bearing, not cosmetic.
#
# chip/PDK-AGNOSTIC, OPEN sky130 tooling; generic layer names only (NDA-clean).
#
# Usage:  ./run.sh [MAGIC_BIN] [NETGEN_BIN]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAGIC_BIN="${1:-magic}"
NETGEN_BIN="${2:-netgen}"
PY="${PYTHON:-python3}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE"/gen_bridge_tech.py "$HERE"/stack.lef "$HERE"/buf.lef \
   "$HERE"/top.def "$HERE"/extract.tcl \
   "$HERE"/top_golden.spice "$HERE"/top_corrupt.spice "$WORK"/
cd "$WORK" || exit 2

fail() { echo "FAIL: $1"; exit 1; }

# count internal nets referenced by >=2 buf instances (the chain)
shared_nets() {
  awk '/^\.subckt top/{f=1} /^\.ends/{if(f)exit}
       f&&/^X/{for(i=2;i<=NF;i++) if($i!~/^buf$/ && $i!~/VPWR|VGND|VSUBS/) print $i}' "$1" \
    | sort | uniq -c | awk '$1>=2{c++} END{print c+0}'
}
matched() { grep -qiE "Circuits match uniquely|Netlists match uniquely" "$1"; }

# ---- 0. generate the COMPLETE bridge tech from the tech-LEF's layer set -----
"$PY" gen_bridge_tech.py --lef stack.lef --name bridge -o bridge.tech \
    || fail "generator failed (full)"
# sanity: the generator must emit ALL metals + ALL via contacts (not metal1-only)
nmet=$(grep -cE "^  routing " bridge.tech)
ncon=$(awk '/^contact/{f=1;next} /^end/{f=0} f&&/^  via/{c++} END{print c+0}' bridge.tech)
echo "bridge tech: routing metals=$nmet  via contacts=$ncon"
[ "$nmet" -ge 3 ] || fail "bridge tech modeled <3 metals (metal1-only regression)"
[ "$ncon" -ge 2 ] || fail "bridge tech emitted <2 via contacts"

# ---- 1. POSITIVE extract ----------------------------------------------------
BRIDGE_TECH="$WORK/bridge.tech" OUT_SPICE="$WORK/top_extracted.spice" \
    "$MAGIC_BIN" -dnull -noconsole extract.tcl >magic_pos.log 2>&1
[ -f top_extracted.spice ] || fail "magic produced no extracted netlist (positive)"
nshared=$(shared_nets top_extracted.spice)
echo "positive: inter-cell nets shared by >=2 buf instances: $nshared"
[ "$nshared" -ge 2 ] || fail "multi-metal nets collapsed/fragmented (shared=$nshared, expected>=2)"

# ---- 2. netgen LVS vs GOLDEN => MATCH --------------------------------------
: >setup.tcl
"$NETGEN_BIN" -batch lvs "top_extracted.spice top" \
    "top_golden.spice top" setup.tcl good.rpt >netgen_good.log 2>&1
matched good.rpt || fail "golden LVS did not MATCH"
echo "golden LVS: MATCH"

# ---- 3. NON-VACUOUS: netgen LVS vs CORRUPT => MISMATCH ---------------------
"$NETGEN_BIN" -batch lvs "top_extracted.spice top" \
    "top_corrupt.spice top" setup.tcl bad.rpt >netgen_bad.log 2>&1
if matched bad.rpt; then fail "corrupt LVS MATCHed (vacuous!)"; fi
echo "corrupt LVS: MISMATCH (non-vacuous OK)"

# ---- 4. PROVEN-NEGATIVE (tech): drop via contacts -> fragmentation ---------
"$PY" gen_bridge_tech.py --lef stack.lef --name bridge_nc --drop-contacts \
    -o bridge_nc.tech || fail "generator failed (no-contact)"
BRIDGE_TECH="$WORK/bridge_nc.tech" OUT_SPICE="$WORK/top_nc.spice" \
    "$MAGIC_BIN" -dnull -noconsole extract.tcl >magic_nc.log 2>&1
[ -f top_nc.spice ] || fail "magic produced no extracted netlist (no-contact)"
nshared_nc=$(shared_nets top_nc.spice)
echo "no-contact: inter-cell nets shared by >=2 buf instances: $nshared_nc"
"$NETGEN_BIN" -batch lvs "top_nc.spice top" \
    "top_golden.spice top" setup.tcl nc.rpt >netgen_nc.log 2>&1
if matched nc.rpt; then
    fail "no-contact tech still MATCHed golden -- via contacts not load-bearing"
fi
echo "no-contact LVS: MISMATCH (via/contact rules proven load-bearing)"

echo "PASS: multi-metal bridge tech reconstructs full-stack connectivity;"
echo "      golden MATCH + corrupt MISMATCH + no-contact fragmentation MISMATCH"
exit 0
