# Extract one flat cell and emit parasitics in the requested format.
#   TECHF : techfile      GEOM : geometry script to source
#   FMT   : spef | ngspice ...            OUT : output file
drc off
tech load $env(TECHF)
load cell -quiet
source $env(GEOM)
save cell
load cell
extract all
ext2spice cthresh 0
ext2spice rthresh 0
ext2spice format $env(FMT)
ext2spice -o $env(OUT)
quit -noprompt
