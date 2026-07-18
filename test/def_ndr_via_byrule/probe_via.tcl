# Read a DEF and report the bounding box of everything it painted, in magic
# internal units.  The routes in these fixtures place exactly one via at a
# known point, so the bbox half-extent IS the via's extent.
drc off
tech load $env(BRIDGE_TECH)
lef read $env(STACK_LEF)
def read $env(DEF_FILE)
load top
select cell
puts "GEOM_BBOX [box values]"
quit -noprompt
