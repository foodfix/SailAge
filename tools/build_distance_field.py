#!/usr/bin/env python3
"""Build the wrap-aware land-distance raster (docs/10-DATA-SCHEMA.md §6.7).

Reads ``data/maps/world.png`` (the §6.3 indexed raster, 1 px = 1 tile,
palette index 2 = ``#`` land) and computes the exact Euclidean distance to
the nearest land tile for every tile, **wrap-aware in x** (the world is a
cylinder; the dateline is not a wall). The result is written to
``data/maps/dist_land.png`` — an RGB8 PNG of the same 4320×2160 grid:

    distance d (tiles, saturated at 16) is encoded as
        enc  = round(min(d, 16) / 16 * 65535)     (0..65535)
        R    = enc >> 8,  G = enc & 255,  B = 0
    decode: d = (R * 256 + G) / 4096           (1/4096-tile precision)

The runtime water shader (80-* §4.7.17, 2026-11-06 amendment) decodes this
texture and multiplies deep-water pixels by the pinned factor curve —
factor 1.0 at d ≤ 6 (the §6.2 coastal band), falling linearly to 0.6 at
d ≥ 10. The raster is a tool-owned artifact like ``world.png`` itself:
never hand-edited, two rebuilds must be byte-identical (§8.8).

Algorithm: Felzenszwalb & Huttenlocher's exact O(N) squared-distance
transform, computed on a 3× horizontally tiled copy of the mask so that
distances across the dateline are exact; the center copy's values are the
wrapped answer (a land copy at x±W is the same land). Pass 2 streams each
column straight into the encoder — the full squared-distance field is
never materialized.

Pure stdlib. Deterministic: fixed order, no randomness, no dict-order
dependence — two runs are byte-identical.
"""

from __future__ import annotations

import sys
import zlib
from array import array
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORLD_PNG = ROOT / "data" / "maps" / "world.png"
OUT_PNG = ROOT / "data" / "maps" / "dist_land.png"

LAND_INDEX = 2        # §6.3 palette order: 0='~' 1='.' 2='#' 3='^' 4='I'
SATURATION_TILES = 16.0


def read_world_indices(path: Path) -> tuple[int, int, bytearray]:
    """Decode the indexed PNG into per-pixel palette indices (§6.3 loader)."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    width = height = 0
    bitdepth = colortype = 0
    idat = b""
    while pos < len(data):
        length = int.from_bytes(data[pos:pos + 4], "big")
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            width = int.from_bytes(chunk[0:4], "big")
            height = int.from_bytes(chunk[4:8], "big")
            bitdepth, colortype = chunk[8], chunk[9]
        elif ctype == b"IDAT":
            idat += chunk
        pos += 12 + length
    if colortype != 3 or bitdepth != 8:
        raise ValueError("world.png must be an 8-bit indexed PNG (§6.3)")
    raw = zlib.decompress(idat)
    stride = width  # 1 byte per pixel (palette index)
    indices = bytearray(width * height)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        f = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if f == 1:
            for i in range(1, stride):
                line[i] = (line[i] + line[i - 1]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - 1] if i else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - 1] if i else 0
                b = prev[i]
                c = prev[i - 1] if i else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        elif f != 0:
            raise ValueError(f"unsupported filter {f}")
        prev = line
        indices[y * stride:(y + 1) * stride] = line
    return width, height, indices


def edt_1d(f: array) -> array:
    """Felzenszwalb 1D lower envelope of squared-distance parabolas.

    ``f`` holds per-position site costs (0.0 at a site, +inf elsewhere);
    returns the squared distance to the nearest finite-cost position.
    """
    n = len(f)
    d = array("d", bytes(8 * n))
    v = array("l", bytes(8 * n))           # parabola sites in the envelope
    z = array("d", bytes(8 * (n + 1)))     # envelope boundaries
    INF = float("inf")
    z[0] = -INF
    z[1] = INF
    k = 0
    for q in range(1, n):
        if f[q] != INF:
            while True:
                s = (((f[q] + q * q) - (f[v[k]] + v[k] * v[k]))
                     / (2 * q - 2 * v[k]))
                if s <= z[k]:
                    k -= 1
                    if k < 0:
                        k = 0
                        v[0] = q
                        z[0] = -INF
                        z[1] = INF
                        break
                    continue
                k += 1
                v[k] = q
                z[k] = s
                z[k + 1] = INF
                break
    k = 0
    for q in range(n):
        while z[k + 1] < q:
            k += 1
        d[q] = (q - v[k]) ** 2 + f[v[k]]
    return d


def encode_png(width: int, height: int, rgb: bytes) -> bytes:
    def chunk(ctype: bytes, payload: bytes) -> bytes:
        out = (len(payload).to_bytes(4, "big") + ctype + payload)
        out += (zlib.crc32(ctype + payload) & 0xFFFFFFFF).to_bytes(4, "big")
        return out

    stride = width * 3
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgb[y * stride:(y + 1) * stride]
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", (width.to_bytes(4, "big")
                              + height.to_bytes(4, "big")
                              + bytes([8, 2, 0, 0, 0])))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def main() -> int:
    argv = sys.argv[1:]
    check = "--check" in argv
    width, height, indices = read_world_indices(WORLD_PNG)
    if (width, height) != (4320, 2160):
        print(f"FAIL world.png is {width}x{height}, expected 4320x2160",
              file=sys.stderr)
        return 1

    # Land mask, then 3x horizontal tiling for the wrap (module docstring).
    mask = [bytearray(width) for _ in range(height)]
    land_tiles = 0
    for y in range(height):
        row = mask[y]
        base = y * width
        for x in range(width):
            if indices[base + x] == LAND_INDEX:
                row[x] = 1
                land_tiles += 1
    print(f"land tiles: {land_tiles} ({land_tiles / (width * height):.4f})",
          flush=True)

    w3 = width * 3
    mask3 = [row + row + row for row in mask]

    # Pass 1 — per row on the tiled grid.
    print("EDT pass 1 (rows) …", flush=True)
    INF = float("inf")
    # g rows: squared distance per (y, x3); stored as array('d') flat.
    g = array("d", bytes(8 * w3 * height))
    for y in range(height):
        f = array("d", [0.0 if v else INF for v in mask3[y]])
        row = edt_1d(f)
        g[y * w3:(y + 1) * w3] = row

    # Pass 2 — per column, streamed straight into the encoder.
    print("EDT pass 2 (columns) + encode …", flush=True)
    rgb = bytearray(width * height * 3)
    sat_enc = int(round(SATURATION_TILES / 16.0 * 65535))
    column = array("d", bytes(8 * height))
    for x in range(width):
        for y in range(height):
            column[y] = g[y * w3 + width + x]   # center copy
        col = edt_1d(column)
        for y in range(height):
            d = col[y] ** 0.5
            if d >= SATURATION_TILES:
                enc = sat_enc
            else:
                enc = int(round(d / SATURATION_TILES * 65535))
                if enc > sat_enc:
                    enc = sat_enc
            base = (y * width + x) * 3
            rgb[base] = (enc >> 8) & 255
            rgb[base + 1] = enc & 255
    rebuilt = encode_png(width, height, bytes(rgb))
    if check:
        committed = OUT_PNG.read_bytes() if OUT_PNG.is_file() else b""
        if committed != rebuilt:
            print("FAIL --check: rebuild drift vs data/maps/dist_land.png "
                  "(§6.7: the raster is tool-owned, never hand-edited — "
                  "regenerate, never edit)", file=sys.stderr)
            return 1
        print("--check OK: rebuild byte-identical")
        return 0
    OUT_PNG.write_bytes(rebuilt)
    print(f"wrote {OUT_PNG.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
