# Read a GDS back with the SAME foundry tech and report any unmapped boundary.
drc off
tech load ./$env(TECHF)
gds read $env(IN)
puts "READBACK_DONE"
quit -noprompt
