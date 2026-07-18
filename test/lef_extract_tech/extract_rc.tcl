# Paint one met1 plate of WX x WY box units (= nanometres for this tech) and
# emit its parasitics as SPEF, using a tech generated from a tech-LEF alone.
drc off
tech load $env(TECHF)
load cell -quiet
box 0 0 $env(WX) $env(WY)
paint met1
label NET1
save cell
load cell
extract all
ext2spice cthresh 0
ext2spice format spef
ext2spice -o $env(OUT)
quit -noprompt
