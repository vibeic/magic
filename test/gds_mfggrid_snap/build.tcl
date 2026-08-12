# Build a 2-level design whose child instance sits at an OFF-GRID origin, then
# stream it out.  The instance is placed directly (not via DEF import), so the
# write-side snap (#37) is exercised in isolation from the import snap (#47).
#
#   TECHNAME : tech to load          OUT_GDS  : streamout target
#   GRID_LEF : optional tech-LEF declaring MANUFACTURINGGRID (omit = no grid)
#   CHILDW   : child cell width in lambda (default 1000; 1001.5 gives an array
#              pitch of 2003 internal units, i.e. NOT a multiple of the grid)
#   ARRAY    : optional "<cols> <rows>"; when set the use is arrayed, so the
#              streamout takes the AREF path (three XY points) instead of SREF
drc off
tech load $env(TECHNAME)
puts "SCALE [cif scale output]"
# child cell with real geometry (not a LEF abstract, which streams out empty)
load child -quiet
set childw 1000
if {[info exists env(CHILDW)]} { set childw $env(CHILDW) }
box 0 0 $childw 1000
paint m1
puts "CBOX [box values]"
save child
# place it at an off-grid origin: internal 4006 (= 20.030 um), y on-grid 4000
load parent -quiet
box 2003 2000 2003 2000
getcell child
select cell child_0
puts "IBBOX [lindex [box values] 0]"
# optionally turn the single use into an array: the AREF path writes THREE XY
# points (origin, column reference, row reference), and the array's geometry is
# the DIFFERENCE between them -- so a snap that moves only the origin silently
# changes the pitch and shears the rows.
if {[info exists env(ARRAY)]} {
    eval array $env(ARRAY)
    puts "ABOX [box values]"
}
# read the manufacturing grid only AFTER the placement exists
if {[info exists env(GRID_LEF)]} { lef read $env(GRID_LEF) }
load parent
gds write $env(OUT_GDS)
quit -noprompt
