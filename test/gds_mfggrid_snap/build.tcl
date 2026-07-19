# Build a 2-level design whose child instance sits at an OFF-GRID origin, then
# stream it out.  The instance is placed directly (not via DEF import), so the
# write-side snap (#37) is exercised in isolation from the import snap (#47).
#
#   TECHNAME : tech to load          OUT_GDS  : streamout target
#   GRID_LEF : optional tech-LEF declaring MANUFACTURINGGRID (omit = no grid)
drc off
tech load $env(TECHNAME)
puts "SCALE [cif scale output]"
# child cell with real geometry (not a LEF abstract, which streams out empty)
load child -quiet
box 0 0 1000 1000
paint m1
save child
# place it at an off-grid origin: internal 4006 (= 20.030 um), y on-grid 4000
load parent -quiet
box 2003 2000 2003 2000
getcell child
select cell child_0
puts "IBBOX [lindex [box values] 0]"
# read the manufacturing grid only AFTER the placement exists
if {[info exists env(GRID_LEF)]} { lef read $env(GRID_LEF) }
load parent
gds write $env(OUT_GDS)
quit -noprompt
