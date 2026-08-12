# Same extraction as extract_spef.tcl, but the output format is selected with
# the "-f <fmt>" FLAG of the run subcommand instead of the "format <fmt>"
# subcommand.  ext2spice parses those two through two independent registries
# (cmdExtToSpcFormat[] in CmdExtToSpice vs the strcasecmp chain in
# spcParseArgs), and a format present in only one of them made this command a
# no-op that still reported success.
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
ext2spice -f $env(FMT) -o $env(OUT)
quit -noprompt
