#!/bin/bash
#
# Regression test for the vibeic LVS-fidelity fix in lef/defRead.c:
#   "DEF route wire whose width resolves to 0 paints a zero-width (dropped)
#    wire, collapsing all top-level routed connectivity."
#
# FAIL->PASS proof, chip-AGNOSTIC on an OPEN PDK (sky130):
#   - Extract the routed abstract-cell design with NO tech-LEF (width == 0).
#   - PASS criteria (patched magic):
#       (1) the extracted top .subckt chains the 3 buf cells in->u0->u1->u2->out
#           (per-net connectivity retained), AND
#       (2) netgen LVS vs the golden schematic => MATCH, AND
#       (3) netgen LVS vs the corrupted schematic => MISMATCH (proven-negative,
#           so the MATCH is real, not vacuous).
#   Stock (unpatched) magic FAILs (1)+(2): the wires are zero-width, the buf
#   instances collapse (netgen: "buf (3->1)"), and the golden compare MISMATCHes.
#
# Usage:  ./run.sh [MAGIC_BIN] [NETGEN_BIN] [MAGICRC]
# Defaults resolve magic/netgen from PATH and the sky130A magicrc from PDK_ROOT.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAGIC_BIN="${1:-magic}"
NETGEN_BIN="${2:-netgen}"
PDK_ROOT="${PDK_ROOT:-/foss/pdks}"
MAGICRC="${3:-$PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE"/buf.lef "$HERE"/tinytop.def "$HERE"/extract.tcl \
   "$HERE"/tinytop_golden.spice "$HERE"/tinytop_corrupt.spice "$WORK"/
cd "$WORK" || exit 2

fail() { echo "FAIL: $1"; exit 1; }

# ---- 1. extract (no tech-LEF => zero-width-route condition) ----------------
"$MAGIC_BIN" -dnull -noconsole -rcfile "$MAGICRC" extract.tcl >magic.log 2>&1
[ -f tinytop_extracted.spice ] || fail "magic produced no extracted netlist"

# ---- 2. connectivity retained: the three buf instances must reference a	----
#         shared internal net between adjacent cells (chain), not isolated pins.
nshared=$(awk '/^\.subckt tinytop/{f=1} /^\.ends/{if(f)exit}
               f&&/^X/{for(i=2;i<=NF;i++) if($i!~/^buf$/ && $i!~/VPWR|VGND|VSUBS/) print $i}' \
               tinytop_extracted.spice | sort | uniq -c | awk '$1>=2{c++} END{print c+0}')
echo "internal nets shared by >=2 instances: $nshared"
[ "$nshared" -ge 2 ] || fail "signal nets collapsed (shared nets=$nshared, expected >=2)"

# ---- 3. netgen LVS vs GOLDEN => MATCH --------------------------------------
: >setup.tcl
"$NETGEN_BIN" -batch lvs "tinytop_extracted.spice tinytop" \
    "tinytop_golden.spice tinytop" setup.tcl good.rpt >netgen_good.log 2>&1
grep -qiE "Circuits match uniquely|Netlists match uniquely" good.rpt \
    || fail "golden LVS did not MATCH (expected match)"
echo "golden LVS: MATCH"

# ---- 4. PROVEN-NEGATIVE: netgen LVS vs CORRUPT => MISMATCH -----------------
"$NETGEN_BIN" -batch lvs "tinytop_extracted.spice tinytop" \
    "tinytop_corrupt.spice tinytop" setup.tcl bad.rpt >netgen_bad.log 2>&1
if grep -qiE "Circuits match uniquely|Netlists match uniquely" bad.rpt; then
    fail "corrupt LVS MATCHed (vacuous!) -- proven-negative failed"
fi
echo "corrupt LVS: MISMATCH (proven-negative OK)"

echo "PASS: zero-width-route connectivity retained; golden MATCH + corrupt MISMATCH"
exit 0
