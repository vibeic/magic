# Regression recipe for the zero-width-route / LEF-abstract net-collapse fix.
#
# Reads ONLY the abstract cell LEF (buf.lef) and the routed DEF -- NO tech-LEF.
# The routing layer therefore has no resolvable WIDTH (no LEF WIDTH and, with
# `drc off`, no DRC width rule), so every regular-net route wire would be built
# ZERO-WIDTH.  Stock magic paints nothing -> the three `buf` instances lose all
# signal connectivity (they collapse to one equivalence class under LVS).  The
# vibeic defNonzeroRouteWidth() guard in lef/defRead.c widens such wires to a
# minimal non-zero width so per-net connectivity is retained.
#
# Chip/PDK-AGNOSTIC: the only PDK dependency is the layer name `met1` and the
# `unithd` site, resolved by whatever -rcfile is supplied on the command line.
drc off
lef read buf.lef
def read tinytop.def
load tinytop
extract no all
extract all
ext2spice lvs
ext2spice -o tinytop_extracted.spice
quit -noprompt
