#!/usr/bin/env python3
"""gen_foundry_gds.py — emit a tiny FOUNDRY-numbered GDSII, no external deps.

A real PDK ships GDS whose geometry sits on the foundry's own layer/datatype
numbers (e.g. met1 = 68/20), NOT on a compact 1..N scheme. This writer builds
such a GDS entirely from the Python stdlib (pure GDSII byte records) so the
fixture is independent of Magic's own streamout (no circularity in the gate).

Design of cell TOP (pure interconnect, connectivity that LVS must anchor):

    label "IN"  on met1 --met1 wire-- via1 --met2 wire-- via2 --met3 wire--
                                                              label "OUT"

so IN (met1) and OUT (met3) are the SAME electrical net, threaded UP the metal
stack through via1/via2. If the reading tech maps the foundry layer/datatypes,
extraction captures both port labels on one connected node; if it uses compact
numbers, NOTHING on 68/20.. is read -> the routing + both labels vanish (the
"#46 compact-fallback breaks LVS" failure).

Layer/datatype numbers are taken from the layermap file so the GDS and the
Magic bridge tech stay in lock-step from ONE source of truth.
"""
from __future__ import annotations

import argparse
import struct
import sys
import time
from typing import Dict, List, Tuple


def _rec(rtype: int, dtype: int, payload: bytes = b"") -> bytes:
    n = len(payload) + 4
    return struct.pack(">HBB", n, rtype, dtype) + payload


def _i2(vals: List[int]) -> bytes:
    return b"".join(struct.pack(">h", v) for v in vals)


def _i4(vals: List[int]) -> bytes:
    return b"".join(struct.pack(">i", v) for v in vals)


def _ascii(s: str) -> bytes:
    b = s.encode("ascii")
    if len(b) % 2:
        b += b"\x00"
    return b


# GDSII record type / data-type constants used here.
HEADER = 0x0002
BGNLIB = 0x0102
LIBNAME = 0x0206
UNITS = 0x0305
BGNSTR = 0x0502
STRNAME = 0x0606
BOUNDARY = 0x0800
TEXT = 0x0C00
LAYER = 0x0D02
DATATYPE = 0x0E02
TEXTTYPE = 0x1602
XY = 0x1003
STRING = 0x1906
ENDEL = 0x1100
ENDSTR = 0x0700
ENDLIB = 0x0400


def _units() -> bytes:
    # user unit = 1e-3 (db in nm if grid is nm), db unit in meters = 1e-9
    def r8(x: float) -> bytes:
        if x == 0:
            return b"\x00" * 8
        sign = 0
        if x < 0:
            sign = 0x80
            x = -x
        exp = 64
        while x >= 1:
            x /= 16.0
            exp += 1
        while x < 1 / 16.0:
            x *= 16.0
            exp -= 1
        mant = 0
        for _ in range(56):
            x *= 2
            mant = (mant << 1) | int(x)
            x -= int(x)
        return struct.pack(">B", sign | exp) + mant.to_bytes(7, "big")

    return _rec(0x03, 0x05, r8(1e-3) + r8(1e-9))


def boundary(layer: int, dt: int, x0: int, y0: int, x1: int, y1: int) -> bytes:
    pts = [x0, y0, x1, y0, x1, y1, x0, y1, x0, y0]
    return (_rec(0x08, 0x00) + _rec(0x0D, 0x02, _i2([layer]))
            + _rec(0x0E, 0x02, _i2([dt])) + _rec(0x10, 0x03, _i4(pts))
            + _rec(0x11, 0x00))


def text(layer: int, tt: int, x: int, y: int, s: str) -> bytes:
    return (_rec(0x0C, 0x00) + _rec(0x0D, 0x02, _i2([layer]))
            + _rec(0x16, 0x02, _i2([tt])) + _rec(0x10, 0x03, _i4([x, y]))
            + _rec(0x19, 0x06, _ascii(s)) + _rec(0x11, 0x00))


def parse_layermap(path: str) -> Dict[str, Tuple[int, int]]:
    m: Dict[str, Tuple[int, int]] = {}
    for line in open(path):
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        t = s.split()
        if len(t) >= 4:
            name, purpose, num, dt = t[0], t[1], t[2], t[3]
        elif len(t) == 3:
            name, purpose, num, dt = t[0], "drawing", t[1], t[2]
        else:
            continue
        try:
            key = f"{name.lower()}:{purpose.lower()}"
            m[key] = (int(num), int(dt))
            m.setdefault(name.lower(), (int(num), int(dt)))
        except ValueError:
            continue
    return m


def ld(m: Dict[str, Tuple[int, int]], name: str) -> Tuple[int, int]:
    for k in (f"{name.lower()}:drawing", name.lower()):
        if k in m:
            return m[k]
    raise SystemExit(f"layermap has no entry for '{name}'")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--layermap", required=True)
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--cell", default="TOP")
    args = ap.parse_args(argv)
    lm = parse_layermap(args.layermap)

    m1, m1dt = ld(lm, "met1")
    m2, m2dt = ld(lm, "met2")
    m3, m3dt = ld(lm, "met3")
    v1, v1dt = ld(lm, "via1")
    v2, v2dt = ld(lm, "via2")

    body = b""
    # -- Net IN : met1 --via1--> met2 stack (x = 0..400), label IN on met1 -----
    body += boundary(m1, m1dt, 0, 0, 300, 40)
    body += text(m1, m1dt, 20, 20, "IN")
    body += boundary(v1, v1dt, 260, 10, 290, 30)     # via1 over met1 & met2
    body += boundary(m2, m2dt, 260, 0, 400, 40)
    # -- Net OUT: met2 --via2--> met3 stack (x = 500..900), label OUT on met3 ---
    #    disjoint from Net IN (gap 400..500) so the two nets stay separate; all
    #    five foundry layers (met1/2/3, via1/2) are exercised.
    body += boundary(m2, m2dt, 500, 0, 640, 40)
    body += boundary(v2, v2dt, 610, 10, 640, 30)     # via2 over met2 & met3
    body += boundary(m3, m3dt, 610, 0, 900, 40)
    body += text(m3, m3dt, 860, 20, "OUT")

    now = time.gmtime()
    tstamp = _i2([now.tm_year, now.tm_mon, now.tm_mday,
                  now.tm_hour, now.tm_min, now.tm_sec] * 2)
    out = b""
    out += _rec(0x00, 0x02, _i2([600]))            # HEADER v6
    out += _rec(0x01, 0x02, tstamp)                # BGNLIB
    out += _rec(0x02, 0x06, _ascii("FOUNDRY"))     # LIBNAME
    out += _units()
    out += _rec(0x05, 0x02, tstamp)                # BGNSTR
    out += _rec(0x06, 0x06, _ascii(args.cell))     # STRNAME
    out += body
    out += _rec(0x07, 0x00)                        # ENDSTR
    out += _rec(0x04, 0x00)                        # ENDLIB
    open(args.out, "wb").write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
