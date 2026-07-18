#!/usr/bin/env python3
"""Emit a 1-instance DEF placing `buf` at a caller-chosen DBU coordinate."""
import argparse
p = argparse.ArgumentParser()
p.add_argument("--x", type=int, required=True)   # DEF DBU (1000/micron)
p.add_argument("--y", type=int, required=True)
p.add_argument("-o", required=True)
a = p.parse_args()
open(a.o, "w").write(f"""VERSION 5.8 ;
DIVIDERCHAR "/" ;
BUSBITCHARS "[]" ;
DESIGN top ;
UNITS DISTANCE MICRONS 1000 ;
DIEAREA ( 0 0 ) ( 30000 10000 ) ;

COMPONENTS 1 ;
- u0 buf + PLACED ( {a.x} {a.y} ) N ;
END COMPONENTS

END DESIGN
""")
