# Two-level design for the hierarchical ext2spice port-promotion gate.
#
# child   one nfet; nets S and D are EXPLICIT ports; GATE_INTERNAL is a plain
#         label on the gate net and is NOT a port.  It is the ordinary way an
#         internal net gets a readable name in a custom/analog block.
# parent  instantiates child once and carries one plain label of its own,
#         TOPNET, on a piece of metal.  TOPNET is the TOP cell's unpromoted
#         label, so it is what proves "port makeall" still does its job.
#
# Everything comes from magic's own bundled `scmos` technology, so this gate
# needs no PDK and runs anywhere magic is installed.
#
#   MAKEALL : "on" | "off" | "" (omit the command entirely, as stock magic has
#             no such subcommand)
#   OUT     : output SPICE file
drc off
tech load scmos

load child -quiet
box -3 -3 3 3
paint ndiff
box -1 -6 1 6
paint poly
box -3 -1 -2 1
label S
port make 1
box 2 -1 3 1
label D
port make 2
# a plain label on the gate net: a NAME, not a port
box -1 4 1 5
label GATE_INTERNAL
save child

load parent -quiet
box 0 0 0 0
getcell child
box 20 20 30 30
paint metal1
box 22 22 24 24
label TOPNET
save parent

load parent
select cell child_0
extract all
ext2spice hierarchy on
ext2spice format ngspice
ext2spice scale off
if {[info exists env(MAKEALL)] && $env(MAKEALL) ne ""} {
    ext2spice port makeall $env(MAKEALL)
}
ext2spice -o $env(OUT)
quit -noprompt
