#!/usr/bin/env python3
"""Vuelca la estructura MOBI/PalmDB de un archivo .mobi para inspeccionarla.

Uso: python3 dump_mobi.py archivo.mobi
"""
import struct
import sys


def u16(b, o):
    return struct.unpack_from(">H", b, o)[0]


def u32(b, o):
    return struct.unpack_from(">I", b, o)[0]


def ascii_(b, o, n):
    return b[o:o + n].decode("ascii", errors="replace")


def main():
    path = sys.argv[1]
    data = open(path, "rb").read()
    print(f"=== {path} ({len(data)} bytes) ===")

    # ---- Palm database header (78 bytes) ----
    print("\n[PalmDB header]")
    print(f"  name (0-31):      {ascii_(data, 0, 32)!r}")
    print(f"  attributes:       {u16(data, 32)}")
    print(f"  version:          {u16(data, 34)}")
    print(f"  type (60-63):     {ascii_(data, 60, 4)!r}")
    print(f"  creator (64-67):  {ascii_(data, 64, 4)!r}")
    num_records = u16(data, 76)
    print(f"  num records:      {num_records}")

    # ---- record offsets ----
    offsets = []
    for i in range(num_records):
        offsets.append(u32(data, 78 + i * 8))
    print(f"  record offsets:   {offsets}")

    r0 = data[offsets[0]:offsets[1] if num_records > 1 else len(data)]
    print(f"  record 0 len:     {len(r0)}")

    # ---- PalmDOC header (16 bytes) ----
    print("\n[PalmDOC header (record 0)]")
    print(f"  compression:      {u16(r0, 0)}")
    print(f"  text length:      {u32(r0, 4)}")
    print(f"  text records:     {u16(r0, 8)}")
    print(f"  record size:      {u16(r0, 10)}")
    print(f"  encryption:       {u16(r0, 12)}")

    # ---- MOBI header ----
    print("\n[MOBI header]")
    print(f"  magic:            {ascii_(r0, 0x10, 4)!r}")
    print(f"  header len (0x14): {u32(r0, 0x14)}")
    print(f"  type (0x18):      {u32(r0, 0x18)}")
    print(f"  encoding (0x1c):  {u32(r0, 0x1c)}")
    print(f"  uid (0x20):       {u32(r0, 0x20)}")
    print(f"  version (0x24):   {u32(r0, 0x24)}")
    print(f"  first non-book rec (0x50): {u32(r0, 0x50)}")
    full_off = u32(r0, 0x54)
    full_len = u32(r0, 0x58)
    print(f"  full name off (0x54): {full_off}  len (0x58): {full_len}")
    print(f"    -> title: {r0[full_off:full_off + full_len]!r}")
    print(f"  language (0x5c):  {hex(u32(r0, 0x5c))}")
    print(f"  min version (0x68): {u32(r0, 0x68)}")
    print(f"  first image rec (0x6c): {u32(r0, 0x6c)}")
    print(f"  huff off/cnt (0x70/0x74): {u32(r0, 0x70)}/{u32(r0, 0x74)}")
    print(f"  huff tbl (0x78/0x7c): {u32(r0, 0x78)}/{u32(r0, 0x7c)}")
    print(f"  EXTH flags (0x80): {hex(u32(r0, 0x80))}")
    print(f"  DRM off/cnt (0xa4/0xa8): {hex(u32(r0, 0xa4))}/{hex(u32(r0, 0xa8))}")
    print(f"  first content rec (0xc0): {u16(r0, 0xc0)}")
    print(f"  last content rec (0xc2): {u16(r0, 0xc2)}")
    print(f"  FCIS rec (0xc8):  {u32(r0, 0xc8)}")
    print(f"  FLIS rec (0xd0):  {u32(r0, 0xd0)}")
    print(f"  SRCS off/cnt (0xe0/0xe4): {hex(u32(r0, 0xe0))}/{u32(r0, 0xe4)}")
    print(f"  extra data flags (0xf0): {hex(u32(r0, 0xf0))}")
    print(f"  primary index/NCX (0xf4): {hex(u32(r0, 0xf4))}")

    # ---- EXTH ----
    print("\n[EXTH]")
    exth_off = 16 + u32(r0, 0x14)
    if ascii_(r0, exth_off, 4) == "EXTH":
        total = u32(r0, exth_off + 4)
        count = u32(r0, exth_off + 8)
        print(f"  off={exth_off} total_len={total} count={count}")
        pos = exth_off + 12
        for i in range(count):
            t = u32(r0, pos)
            ln = u32(r0, pos + 4)
            val = r0[pos + 8:pos + ln]
            print(f"  [{i}] type {t} len {ln}: {val!r}")
            pos += ln
    else:
        print("  (no EXTH)")

    # ---- trailing records ----
    print("\n[Trailing records]")
    for i, off in enumerate(offsets):
        end = offsets[i + 1] if i + 1 < num_records else len(data)
        rec = data[off:end]
        head = rec[:8]
        print(f"  rec {i}: off={off} len={len(rec)} head={head!r}")


if __name__ == "__main__":
    main()
