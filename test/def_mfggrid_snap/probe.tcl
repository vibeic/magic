# Report the placed lower-left of instance u0, in LAMBDA/internal units and microns.
drc off
tech load $env(BRIDGE_TECH)
lef read $env(STACK_LEF)
lef read buf.lef
def read $env(DEF_FILE)
load top
# internal units per lambda and microns per internal unit
set upi [cif scale output]
box values
select cell u0
set bb [box values]
puts "PROBE_BBOX $bb"
puts "PROBE_UPI $upi"
quit -noprompt
