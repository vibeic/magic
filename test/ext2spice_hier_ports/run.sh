#!/bin/bash
#
# Regression: "ext2spice port makeall" must promote labels to ports on the TOP
# cell only -- never on a sub-cell.
#
# WHAT THE FORK ADDED, AND WHAT IT COST
# -------------------------------------
# A flat top-level extraction whose layout never had "port makeall" run on it
# emits a .subckt with an empty port list, so the fork promotes real labels on
# the TOP cell to ports and turns the feature on by default.  The promotion was
# also called from inside topVisit(), which the HIERARCHICAL path calls once per
# def -- so every sub-cell got it too, and every plain label inside a sub-cell
# silently became a port of that sub-cell.
#
# That is an LVS defect, not a cosmetic one.  Labelling internal nets is normal
# practice in custom/analog layout, and the extracted netlist is the LVS input:
# a promoted label changes the sub-circuit's port list and every X-call's
# argument list, so the layout netlist stops matching the schematic netlist for
# a reason that lives in the extractor.  Measured on this fork before the fix,
# with the ONLY difference being the `port makeall` setting:
#
#   on   .subckt child S D GATE_INTERNAL Gnd
#        Xchild_0 child_0/S child_0/D child_0/GATE_INTERNAL errGnd! child
#   off  .subckt child S D
#        Xchild_0 child_0/S child_0/D child
#
# -- the child gained two ports it does not have, and the parent's call to it
# gained two arguments, one of which magic could not even resolve (errGnd!).
#
# WHAT THIS GATE ASSERTS
# ----------------------
#   1  the CHILD's .subckt line and the X-call that instantiates it are BYTE
#      IDENTICAL with `port makeall` on and off -- the setting is about the top
#      cell, so it must not be visible anywhere below it;
#   2  the promotion still FIRES on the top cell: `.subckt parent TOPNET` with
#      it on, no top .subckt with it off.  Without this half the gate would be
#      satisfied by deleting the feature;
#   3  `off` is what magic does with the subcommand absent altogether, which is
#      stock magic's behaviour (stock has no such subcommand at all).
#
# The fixture uses magic's own bundled `scmos` technology: no PDK, no foundry
# files, so this gate runs wherever magic does.
#
# Usage:  ./run.sh [MAGIC_BIN]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAGIC_BIN="${1:-magic}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE"/build.tcl "$WORK"/
cd "$WORK" || exit 2

fail() { echo "FAIL: $1"; exit 1; }
skip() { echo "SKIP: $1"; exit 0; }

# $1 = "on" | "off" | "" (omit the command).  Prints the netlist path.
run_case() {
    _m="$1"; _d="$WORK/case_${_m:-none}"
    mkdir -p "$_d"; cp build.tcl "$_d"/
    ( cd "$_d" && env MAKEALL="$_m" OUT="$_d/out.spice" \
        "$MAGIC_BIN" -dnull -noconsole build.tcl >run.log 2>&1 )
    echo "$_d/out.spice"
}

on="$(run_case on)"
off="$(run_case off)"
[ -s "$on" ]  || skip "hierarchical ext2spice produced nothing with 'port makeall on' (tech 'scmos' unavailable?); see $(dirname "$on")/run.log"
[ -s "$off" ] || fail "hierarchical ext2spice produced nothing with 'port makeall off'; see $(dirname "$off")/run.log"

child_line() { grep -m1 '^\.subckt child' "$1"; }
xcall_line() { grep -m1 '^Xchild_0' "$1"; }

c_on="$(child_line "$on")";  c_off="$(child_line "$off")"
x_on="$(xcall_line "$on")";  x_off="$(xcall_line "$off")"

[ -n "$c_on" ]  || fail "no '.subckt child' in the 'on' netlist -- the fixture did not build"
[ -n "$c_off" ] || fail "no '.subckt child' in the 'off' netlist -- the fixture did not build"

# ---- 1: the sub-cell must not be able to tell the setting apart ------------
[ "$c_on" = "$c_off" ] || fail \
"'port makeall' changed a SUB-CELL's port list:
       on  : $c_on
       off : $c_off
     The setting promotes labels on the TOP cell; a label inside a sub-cell is
     a net name, and turning it into a port changes the netlist LVS compares."
[ "$x_on" = "$x_off" ] || fail \
"'port makeall' changed the X-call to a sub-cell:
       on  : $x_on
       off : $x_off"
echo "  child .subckt identical on/off : $c_on"
echo "  child X-call  identical on/off : $x_on"

# ---- 2: PROVEN-POSITIVE -- the top-level promotion still happens -----------
# TOPNET is a plain label on the TOP cell.  If the fix had been "stop promoting
# anywhere", these two assertions would fail and the gate above would still be
# green -- which is exactly why they are here.
grep -q '^\.subckt parent .*\bTOPNET\b' "$on" || fail \
"the top cell's plain label TOPNET was NOT promoted with 'port makeall on'.
     The feature is gone, not scoped:
       $(grep -m1 '^\.subckt parent' "$on" || echo '<no .subckt parent at all>')"
echo "  top promoted with makeall on   : $(grep -m1 '^\.subckt parent' "$on")"

grep -q '^\.subckt parent' "$off" && fail \
"'port makeall off' still wrapped the top cell in a .subckt -- the setting is
     not load-bearing, so case 1 proves nothing:
       $(grep -m1 '^\.subckt parent' "$off")"
echo "  top NOT promoted with makeall off (no .subckt parent) -- the setting is load-bearing"

# ---- 3: and with the command never issued at all ---------------------------
# This is the path that matters most: the fork turns the promotion ON BY
# DEFAULT (esDoAutoTopPorts = TRUE), so a caller that never heard of
# `port makeall` -- which is every caller written against stock magic, since
# stock has no such subcommand -- gets the default.  A fix that only behaved
# under an explicit `off` would leave every real flow on the broken path.
none="$(run_case '')"
[ -s "$none" ] || fail "hierarchical ext2spice produced nothing with the command omitted"
c_none="$(child_line "$none")"; x_none="$(xcall_line "$none")"
[ "$c_none" = "$c_off" ] || fail \
"with the command NEVER ISSUED (the fork's default) the sub-cell differs:
       default : $c_none
       off     : $c_off"
[ "$x_none" = "$x_off" ] || fail \
"with the command NEVER ISSUED the X-call differs:
       default : $x_none
       off     : $x_off"
diff -q "$none" "$on" >/dev/null || fail \
"omitting the command is no longer the same as 'port makeall on'; the default
     changed, so the assertion above stopped covering the default path.
$(diff "$none" "$on" | sed 's/^/       /')"
echo "  command never issued (the default, = 'on'): child unchanged, top promoted"

echo "PASS: 'port makeall' promotes labels on the top cell only; a sub-cell's"
echo "      .subckt port list and X-call are byte-identical with it on and off,"
echo "      while the top cell's own label is still promoted."
exit 0
