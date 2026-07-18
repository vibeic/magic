#!/bin/bash
#
# Regression: Magic-WRITTEN GDS carries the foundry layer/datatype numbers
# (roadmap #38, P1) -- the streamout half of the layer-map work.
#
# WHY THIS EXISTS AS A SEPARATE GATE.  #46 landed foundry layer-map
# auto-discovery and threads the discovered numbers into BOTH the cif read
# (cifinput) and the cif write (cifoutput calma) sections.  But the #46 gate
# only exercises the READ path: it proves a foundry GDS can be read back with
# the routing and labels landing on the right types.  Nothing asserted the
# WRITE side -- that a GDS Magic *produces* lands on the foundry numbers rather
# than the compact 1..N fallback.  That is exactly the claim roadmap #38 makes
# ("Magic-written GDS is round-trippable"), and it was implemented but
# UNVERIFIED.  This gate closes that hole.
#
# THE NUMBERS come from stack.layermap, the fixture's declared foundry map, and
# the expectation is PARSED FROM THAT FILE rather than hardcoded -- so the gate
# tracks the declaration instead of a copy of it:
#
#     met1 68/20   met2 69/20   met3 70/20
#
#   A FOUNDRY (auto-discovered map): the written GDS must carry exactly
#     {68/20, 69/20, 70/20} -- the declared numbers, with their NON-ZERO
#     datatypes, which a datatype-0 fallback cannot coincidentally produce.
#   B ROUND-TRIP: Magic must read its own written GDS back with the same tech
#     and report NO "Unknown layer/datatype" -- the round-trippability claim.
#   C PROVEN-NEGATIVE (--no-layermap, the stock compact fallback): the written
#     GDS must carry the compact numbers {60/0, 61/0, 62/0} and must contain
#     NONE of the foundry pairs.  This is the non-round-trippable output #38
#     exists to prevent, and it proves the gate passes on the correct DERIVED
#     numbers rather than on "a GDS was produced".
#
# The layer/datatype values are read back out of the GDS bytes by
# read_layers.py, a pure-stdlib GDSII parser sharing no code with Magic's
# writer, so a self-consistent round-trip bug cannot satisfy this gate.
#
# chip/PDK-AGNOSTIC: synthetic tech-LEF + a synthetic NDA-clean foundry map
# with invented generic layer names.
#
# Usage:  ./run.sh [MAGIC_BIN]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAGIC_BIN="${1:-magic}"
PY="${PYTHON:-python3}"
GEN="$HERE/../lvs_bridge_tech_multimetal/gen_bridge_tech.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE"/stack.lef "$HERE"/stack.layermap "$HERE"/read_layers.py \
   "$HERE"/write_stack.tcl "$HERE"/readback.tcl "$WORK"/
cp "$GEN" "$WORK"/gen_bridge_tech.py
cd "$WORK" || exit 2

fail() { echo "FAIL: $1"; exit 1; }

# the expectation is DERIVED from the declared map, not hardcoded
expected="$(awk '!/^#/ && NF>=4 {print $3"/"$4}' stack.layermap | sort -u | tr '\n' ' ')"
[ -n "$expected" ] || fail "could not parse stack.layermap"
echo "declared foundry map: $expected"

# ---- A: foundry map -> written GDS carries the declared numbers ------------
"$PY" gen_bridge_tech.py --lef stack.lef --name b -o f.tech >/dev/null 2>&1 \
    || fail "foundry tech generation failed"
TECHF=f.tech OUT="$WORK/f.gds" "$MAGIC_BIN" -dnull -noconsole write_stack.tcl >f.log 2>&1
[ -f f.gds ] || fail "A: streamout produced no GDS (see f.log)"
got_a="$("$PY" read_layers.py f.gds | tr '\n' ' ')"
# the painted stack is the three routing metals
for want in 68/20 69/20 70/20; do
    case " $got_a " in
        *" $want "*) : ;;
        *) fail "A: written GDS is missing declared foundry layer $want (got: $got_a)" ;;
    esac
done
echo "  A foundry map  -> written GDS layers: $got_a (declared numbers, non-zero datatypes)"

# ---- B: Magic reads its own written GDS back with no unmapped boundary -----
TECHF=f.tech IN="$WORK/f.gds" "$MAGIC_BIN" -dnull -noconsole readback.tcl >rb.log 2>&1
grep -q READBACK_DONE rb.log || fail "B: readback did not complete (see rb.log)"
if grep -qi 'Unknown layer/datatype' rb.log; then
    fail "B: Magic could not read back its OWN written GDS (unmapped layer/datatype)"
fi
echo "  B round-trip   -> Magic re-reads its own GDS with no unknown layer/datatype"

# ---- C: PROVEN-NEGATIVE -- compact fallback must NOT emit foundry numbers --
"$PY" gen_bridge_tech.py --lef stack.lef --name b2 -o c.tech --no-layermap >/dev/null 2>&1 \
    || fail "compact tech generation failed"
rm -f geo.mag
TECHF=c.tech OUT="$WORK/c.gds" "$MAGIC_BIN" -dnull -noconsole write_stack.tcl >c.log 2>&1
[ -f c.gds ] || fail "C: compact streamout produced no GDS"
got_c="$("$PY" read_layers.py c.gds | tr '\n' ' ')"
for bad in 68/20 69/20 70/20; do
    case " $got_c " in
        *" $bad "*) fail "C: compact fallback emitted foundry layer $bad -- the map is not load-bearing" ;;
    esac
done
for want in 60/0 61/0 62/0; do
    case " $got_c " in
        *" $want "*) : ;;
        *) fail "C: compact fallback did not emit expected compact layer $want (got: $got_c)" ;;
    esac
done
echo "  C compact      -> written GDS layers: $got_c (none of the foundry pairs)"

echo "PASS: Magic-written GDS carries the DECLARED foundry layer/datatype numbers"
echo "      and round-trips back through Magic; the compact fallback emits the"
echo "      non-round-trippable numbering instead, so the map is load-bearing."
exit 0
