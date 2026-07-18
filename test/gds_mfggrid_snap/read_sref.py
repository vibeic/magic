#!/usr/bin/env python3
"""Pure-stdlib GDSII reader: print UNITS and every SREF/AREF (name, XY).

Independent of Magic's own GDS code, so the gate cannot be satisfied by a
self-consistent round-trip bug.
"""
import struct, sys

RECS = {0x0003: "UNITS", 0x0A00: "SREF", 0x0B00: "AREF",
        0x1206: "SNAME", 0x1003: "XY", 0x1100: "ENDEL",
        0x0502: "BGNSTR", 0x0606: "STRNAME"}

def main(path):
    data = open(path, "rb").read()
    off, cur, sname = 0, None, None
    while off < len(data):
        (rlen, rtyp) = struct.unpack(">HH", data[off:off+4])
        if rlen < 4: break
        body = data[off+4:off+rlen]
        name = RECS.get(rtyp)
        if name == "UNITS":
            uu, meters = struct.unpack(">dd", _r8(body[:8]) + _r8(body[8:16]))
            print(f"UNITS user_units_per_db={uu:.12g} meters_per_db={meters:.12g}")
        elif name in ("SREF", "AREF"):
            cur = name; sname = None
        elif name == "SNAME" and cur:
            sname = body.split(b"\0")[0].decode()
        elif name == "XY" and cur:
            n = len(body) // 4
            xy = struct.unpack(">" + "i"*n, body)
            print(f"{cur} {sname} XY={list(xy)}")
        elif name == "ENDEL":
            cur = None
        off += rlen

def _r8(b):
    """GDS 8-byte real -> IEEE double bytes."""
    import struct as s
    sign = -1 if b[0] & 0x80 else 1
    exp = (b[0] & 0x7F) - 64
    mant = int.from_bytes(b[1:], "big") / float(1 << 56)
    return s.pack(">d", sign * mant * (16.0 ** exp))

if __name__ == "__main__":
    main(sys.argv[1])
