#!/usr/bin/env python3
"""Emit a DEF whose VIAS section holds a by-rule via, a RECT via, or both.

  --gen CUTSIZE CUTSPACING ENCLOSURE ROWCOL : declare by-rule via V_GEN
  --rect HALF                               : declare RECT via V_RECT (+/-HALF)
  --route V_GEN|V_RECT                      : which via the single route uses
  --bad-ndr                                 : reference an undeclared NDR
"""
import argparse

p = argparse.ArgumentParser()
p.add_argument("--gen", nargs=4, type=int, metavar=("CUT", "SPACE", "ENC", "RC"))
p.add_argument("--rect", type=int)
p.add_argument("--route", default=None)
p.add_argument("--bad-ndr", action="store_true")
p.add_argument("-o", required=True)
a = p.parse_args()

vias = []
if a.gen:
    cut, space, enc, rc = a.gen
    vias.append(
        f"- V_GEN + VIARULE vr1 + CUTSIZE {cut} {cut} + LAYERS met1 via1 met2"
        f" + CUTSPACING {space} {space}"
        f" + ENCLOSURE {enc} {enc} {enc} {enc} + ROWCOL {rc} {rc} ;"
    )
if a.rect is not None:
    h = a.rect
    vias.append(
        f"- V_RECT + RECT met1 ( -{h} -{h} ) ( {h} {h} )"
        f" + RECT via1 ( -{h//2} -{h//2} ) ( {h//2} {h//2} )"
        f" + RECT met2 ( -{h} -{h} ) ( {h} {h} ) ;"
    )

body = ""
if vias:
    body += f"VIAS {len(vias)} ;\n" + "\n".join(vias) + "\nEND VIAS\n\n"

ndr = " + NONDEFAULTRULE NO_SUCH_RULE" if a.bad_ndr else ""
route = f" ( 10000 10000 ) {a.route}" if a.route else " ( 10000 10000 ) ( 20000 10000 )"
body += f"NETS 1 ;\n- n1 ( PIN p1 ){ndr} + ROUTED met1{route} ;\nEND NETS\n"

open(a.o, "w").write(f"""VERSION 5.8 ;
DIVIDERCHAR "/" ;
BUSBITCHARS "[]" ;
DESIGN top ;
UNITS DISTANCE MICRONS 1000 ;
DIEAREA ( 0 0 ) ( 40000 20000 ) ;

{body}
END DESIGN
""")
