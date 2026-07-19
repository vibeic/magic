#!/bin/bash
#
# Regression: foundry LEF/DEF layer-map AUTO-DISCOVERY + apply (roadmap #46, P0).
#
# Scenario (commercial/custom PDK, NO native Magic techfile):
#   A real PDK ships GDS whose geometry sits on the FOUNDRY layer/datatype
#   numbers (here met1=68/20, met2=69/20, met3=70/20, via1=66/44, via2=67/44),
#   NOT a compact 1..N scheme. gen_foundry_gds.py emits exactly such a GDS
#   (pure stdlib -- independent of Magic's own streamout, so no circularity).
#
#   gen_bridge_tech.py builds the Magic bridge tech. WITHOUT the layer-map it
#   falls back to COMPACT numbers (met1=60/0 ...): reading the foundry GDS then
#   maps NOTHING -> every boundary is "Unknown layer/datatype" -> the top
#   routing AND both port labels vanish -> LVS has no anchors. WITH the
#   auto-discovered foundry map it derives 68/20.. -> the routing + labels read
#   back -> both nets (IN on met1, OUT on met3) extract -> LVS pins MATCH.
#
# PASS criteria:
#   (1) FOUNDRY  (auto-discovered stack.layermap):
#         - Magic reads the GDS with NO "Unknown layer/datatype" error
#         - extracted .subckt TOP exposes BOTH ports IN and OUT
#         - netgen LVS vs golden => "Cell pin lists are equivalent"
#   (2) COMPACT  (--no-layermap, the stock fallback):
#         - Magic EMITS "Unknown layer/datatype" (foundry layers dropped)
#         - netgen LVS vs golden => pins NOT equivalent (anchor OUT lost)
#   (3) WRONG-MAP (--layermap wrong.layermap) proven-negative:
#         - a map with the WRONG numbers ALSO drops every layer, proving the
#           gate passes on the CORRECT derived numbers, not on "a map exists".
#
# chip/PDK-AGNOSTIC, OPEN sky130-class tooling; generic layer names (NDA-clean).
#
# Usage:  ./run.sh [MAGIC_BIN] [NETGEN_BIN]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAGIC_BIN="${1:-magic}"
NETGEN_BIN="${2:-netgen}"
PY="${PYTHON:-python3}"
GEN="$HERE/../lvs_bridge_tech_multimetal/gen_bridge_tech.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE"/gen_foundry_gds.py "$HERE"/stack.lef "$HERE"/stack.layermap \
   "$HERE"/wrong.layermap "$HERE"/top_golden.spice "$WORK"/
cp "$GEN" "$WORK"/gen_bridge_tech.py
cd "$WORK" || exit 2

fail() { echo "FAIL: $1"; exit 1; }
# does .subckt TOP expose this port?
has_port() { awk -v p="$2" '/^\.subckt[ \t]+TOP/{for(i=3;i<=NF;i++) if($i==p){print"Y";exit}}' "$1"; }
pins_equiv() { grep -qiE "Cell pin lists are equivalent" "$1"; }

# ---- 0. foundry GDS on the real foundry layer/datatypes ---------------------
"$PY" gen_foundry_gds.py --layermap stack.layermap -o foundry_top.gds \
    || fail "foundry GDS generation failed"

# ---- helper: read foundry GDS with a given tech in an ISOLATED dir ----------
# Each extraction runs in its OWN subdir so a stale TOP.ext can never leak
# between cases.  Populates  $tag.d/{out.spice,TOP.ext,mag.log}.
extract_with_tech() {
  local tech="$1" tag="$2"
  rm -rf "$tag.d"; mkdir "$tag.d"; cp foundry_top.gds "$tag.d"/
  cat > "$tag.d"/ex.tcl <<EOF
drc off
tech load ../$tech
cif istyle drc
gds read foundry_top.gds
load TOP
select top cell
extract no all
extract all
ext2spice lvs
ext2spice -o out.spice
quit -noprompt
EOF
  ( cd "$tag.d" && "$MAGIC_BIN" -dnull -noconsole -rcfile /dev/null ex.tcl \
        >mag.log 2>&1 )
}
# count extracted ports anchored on a real metal layer (routing capture)
metal_ports() { grep -cE '^port ".*" .* met[0-9]' "$1" 2>/dev/null || echo 0; }

# ---- 1. FOUNDRY: auto-discover stack.layermap -------------------------------
"$PY" gen_bridge_tech.py --lef stack.lef --name bridge -o bridge_foundry.tech \
    2>gen_foundry.log || fail "generator failed (foundry)"
grep -q "layers mapped to foundry GDS numbers" gen_foundry.log \
    || fail "generator did NOT auto-discover the foundry layer-map"
extract_with_tech bridge_foundry.tech foundry
if grep -qiE "Unknown layer/datatype" foundry.d/mag.log; then
    fail "FOUNDRY tech still could not read the foundry GDS layers"
fi
[ "$(metal_ports foundry.d/TOP.ext)" -ge 2 ] \
    || fail "FOUNDRY did not anchor 2 routing ports (routing lost)"
[ "$(has_port foundry.d/out.spice IN)"  = "Y" ] || fail "FOUNDRY lost port IN (met1 anchor)"
[ "$(has_port foundry.d/out.spice OUT)" = "Y" ] || fail "FOUNDRY lost port OUT (met3 anchor)"
echo "foundry: read OK, 2 routing anchors (IN@met1, OUT@met3) extracted"

: >setup.tcl
"$NETGEN_BIN" -batch lvs "foundry.d/out.spice TOP" "top_golden.spice TOP" \
    setup.tcl foundry.rpt >netgen_foundry.log 2>&1
pins_equiv foundry.rpt || fail "FOUNDRY netgen pins NOT equivalent (anchor lost)"
echo "foundry LVS: pin lists equivalent (anchors correct)"

# ---- 2. COMPACT: stock fallback, no map -> must break ----------------------
"$PY" gen_bridge_tech.py --lef stack.lef --name bridge --no-layermap \
    -o bridge_compact.tech 2>/dev/null || fail "generator failed (compact)"
extract_with_tech bridge_compact.tech compact
grep -qiE "Unknown layer/datatype" compact.d/mag.log \
    || fail "COMPACT tech unexpectedly read foundry layers (gate not exercised)"
[ "$(metal_ports compact.d/TOP.ext)" -eq 0 ] \
    || fail "COMPACT unexpectedly anchored routing (gate not exercised)"
echo "compact: foundry layers dropped (Unknown layer/datatype), 0 routing anchors -> LVS broken"

# ---- 3. WRONG-MAP proven-negative ------------------------------------------
"$PY" gen_bridge_tech.py --lef stack.lef --name bridge_w \
    --layermap wrong.layermap -o bridge_wrong.tech 2>/dev/null \
    || fail "generator failed (wrong map)"
extract_with_tech bridge_wrong.tech wrong
grep -qiE "Unknown layer/datatype" wrong.d/mag.log \
    || fail "WRONG-map tech read the foundry GDS -- numbers not load-bearing!"
[ "$(metal_ports wrong.d/TOP.ext)" -eq 0 ] \
    || fail "WRONG-map anchored routing -- numbers not load-bearing!"
echo "wrong-map: dropped foundry layers, 0 routing anchors (correct numbers are load-bearing)"

echo "PASS: foundry layer-map auto-discovery reads the foundry GDS and anchors"
echo "      LVS (IN+OUT pins equivalent); compact + wrong-map fallbacks both"
echo "      drop the layers and lose the anchors."
exit 0
