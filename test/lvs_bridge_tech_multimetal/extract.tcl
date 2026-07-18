# Multi-metal LEF-abstract LVS extraction driven by a GENERATED bridge tech.
#
# The commercial/custom-PDK scenario: the node ships LEF (abstract cells +
# routing stack) + GDS + a sign-off deck, but NO Magic techfile. The bridge
# tech (gen_bridge_tech.py) declares every routing metal + every via contact
# so `extract` reconstructs full-stack connectivity from the routed DEF.
#
#   BRIDGE_TECH : path to the generated techfile (positive or no-contact)
#   OUT_SPICE   : extracted netlist output
#
# NO PDK Magic tech is used -- only the generated bridge tech + the LEFs.
drc off
tech load $env(BRIDGE_TECH)
lef read stack.lef
lef read buf.lef
def read top.def
load top
select top cell
extract no all
extract all
ext2spice lvs
ext2spice -o $env(OUT_SPICE)
quit -noprompt
