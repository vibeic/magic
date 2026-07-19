#!/usr/bin/env python3
"""Pure-stdlib GDSII reader: print every distinct (layer, datatype) that carries
geometry, as "L/D", sorted.

Shares no code with Magic's writer, so a self-consistent round-trip bug in
Magic cannot satisfy a gate built on this.
"""
import struct
import sys

LAYER, DATATYPE, BOUNDARY, BOX, PATH, ENDEL = 0x0D02, 0x0E02, 0x0800, 0x2D00, 0x0900, 0x1100


def main(path):
    data = open(path, "rb").read()
    off, cur_l, cur_d, seen = 0, None, None, set()
    while off < len(data):
        rlen, rtyp = struct.unpack(">HH", data[off:off + 4])
        if rlen < 4:
            break
        body = data[off + 4:off + rlen]
        if rtyp in (BOUNDARY, BOX, PATH):
            cur_l = cur_d = None
        elif rtyp == LAYER:
            cur_l = struct.unpack(">h", body[:2])[0]
        elif rtyp == DATATYPE:
            cur_d = struct.unpack(">h", body[:2])[0]
        elif rtyp == ENDEL:
            if cur_l is not None and cur_d is not None:
                seen.add((cur_l, cur_d))
            cur_l = cur_d = None
        off += rlen
    for l, d in sorted(seen):
        print(f"{l}/{d}")


if __name__ == "__main__":
    main(sys.argv[1])
