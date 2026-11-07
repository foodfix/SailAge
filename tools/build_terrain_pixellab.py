#!/usr/bin/env python3
"""Build the PixelLab coast terrain tile family (80-* §4.8, 2026-11-06).

Decodes the vendored PixelLab tileset response under
``tools/assets/pixellab_raw/`` into the shipped 64×64 RGBA canvases

    assets/ui/terrain/terrain_coast_wang_<i>.png     (i = 0..15)

plus the provenance ledger ``tools/ui_art/terrain/pixellab_coast_ledger.json``
(an auxiliary doc — no ``id`` key — so ``build_ui_art`` ignores it; group 13
reads it to waive the palette/budget checks for this family exactly like the
raw-pixellab hull precedent, and to reconcile the artifact inventory).

The tiles are the model's deliberate pixels: NO color quantization, NO
re-render — a rebuild decodes the same vendored bytes and must be
byte-identical (§8.8 double-run detector). The API is never contacted.

Tile semantics (Wang corner autotiling, PixelLab ``pattern_4x4``/``corners``):
corner ``upper`` = land, ``lower`` = water. The runtime splits the set by
owning layer: a cell's own pixel is its NW corner vertex, so water cells
(NW lower) own indices {0..7} and land cells (NW upper) own
{8..15} — 15 is the interior (wang_15 dihedrals) — the runtime maps corner combos
through `WaterLayerLib.wang_index` onto exactly these halves.
"""

from __future__ import annotations

import base64
import hashlib
import json
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = ROOT / "tools" / "assets" / "pixellab_raw"
OUT_DIR = ROOT / "assets" / "ui" / "terrain"
LEDGER_PATH = ROOT / "tools" / "assets" / "pixellab_raw" / \
    "pixellab_coast_ledger.json"

# The one vendored coastline tileset (2026-11-06 generation, user-approved
# wang_0 reference). Pinned by filename so a later re-generation cannot
# silently re-point the game at different pixels.
SOURCE_JSON = ("tileset_coastline_"
               "77f5cd00-82a1-4a85-af7e-a8133eae33a4.json")


def decode_png(data: bytes) -> tuple[int, int, str, list[int], list[bytes]]:
    """Decode a PNG the vendored tiles actually use (8-bit, colour type 2/3/6).

    Returns (width, height, colour_type_name, palette_or_None, raw_rows_rgb).
    Rows are expanded to RGB triples (palette entries resolved; alpha
    dropped — the coastline tiles are opaque).
    """
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    width = height = 0
    bitdepth = colortype = 0
    idat = b""
    palette: list[bytes] = []
    while pos < len(data):
        length = int.from_bytes(data[pos:pos + 4], "big")
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            width, height, bitdepth, colortype = struct_ihdr(chunk)
        elif ctype == b"PLTE":
            palette = [chunk[i:i + 3] for i in range(0, len(chunk), 3)]
        elif ctype == b"IDAT":
            idat += chunk
        pos += 12 + length
    if bitdepth != 8:
        raise ValueError(f"unsupported bit depth {bitdepth}")
    if colortype not in (2, 3, 6):
        raise ValueError(f"unsupported colour type {colortype}")
    raw = zlib.decompress(idat)
    bpp = {2: 3, 3: 1, 6: 4}[colortype]
    stride = width * bpp
    rows: list[bytes] = []
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        f = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        elif f != 0:
            raise ValueError(f"unsupported filter {f}")
        prev = line
        if colortype == 3:
            row = bytearray()
            for idx in line:
                row += palette[idx]
            rows.append(bytes(row))
        elif colortype == 2:
            rows.append(bytes(line))
        else:  # 6 — drop alpha (tiles are opaque; keep it simple)
            row = bytearray()
            for i in range(0, stride, 4):
                row += line[i:i + 3]
            rows.append(bytes(row))
    return width, height, {2: "RGB", 3: "PALETTE", 6: "RGBA"}[colortype], \
        palette, rows


def struct_ihdr(chunk: bytes) -> tuple[int, int, int, int]:
    width = int.from_bytes(chunk[0:4], "big")
    height = int.from_bytes(chunk[4:8], "big")
    return width, height, chunk[8], chunk[9]


def encode_rgba_png(width: int, height: int, rgba: bytes) -> bytes:
    """Minimal deterministic RGBA PNG writer (filter 0 rows, level 9)."""

    def chunk(ctype: bytes, payload: bytes) -> bytes:
        out = (len(payload).to_bytes(4, "big") + ctype + payload)
        out += (zlib.crc32(ctype + payload) & 0xFFFFFFFF).to_bytes(4, "big")
        return out

    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", (width.to_bytes(4, "big")
                              + height.to_bytes(4, "big")
                              + bytes([8, 6, 0, 0, 0])))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def main() -> int:
    source = RAW_DIR / SOURCE_JSON
    if not source.is_file():
        print(f"FAIL vendored tileset missing: {source}", file=sys.stderr)
        return 1
    doc = json.loads(source.read_text())
    tileset = doc.get("tileset") or doc
    tiles = tileset.get("tiles") or []
    if len(tiles) != 16:
        print(f"FAIL expected 16 tiles, got {len(tiles)}", file=sys.stderr)
        return 1

    by_index: dict[int, dict] = {}
    for tile in tiles:
        name = str(tile.get("name", ""))
        if not name.startswith("wang_"):
            print(f"FAIL unexpected tile name {name!r}", file=sys.stderr)
            return 1
        by_index[int(name.split("_", 1)[1])] = tile

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    ledger_tiles: dict[str, dict] = {}
    written: dict[str, bytes] = {}
    for i in range(16):
        tile = by_index[i]
        png_b64 = (tile.get("image") or {}).get("base64")
        if not png_b64:
            print(f"FAIL wang_{i}: no image.base64", file=sys.stderr)
            return 1
        png = base64.b64decode(png_b64)
        width, height, ctype, _pal, rows = decode_png(png)
        if (width, height) != (64, 64):
            print(f"FAIL wang_{i}: {width}x{height}, expected 64x64",
                  file=sys.stderr)
            return 1
        rgba = bytearray()
        for row in rows:
            # Per-PIXEL RGBA — the 2026-11-06 regression (appending one
            # alpha byte per row) read back as channel-rotated stripes with
            # an opaque white tail, the user-reported broken tiles.
            for x in range(width):
                rgba += row[x * 3:x * 3 + 3]
                rgba.append(255)
        out_bytes = encode_rgba_png(64, 64, bytes(rgba))
        sprite_id = f"terrain_coast_wang_{i}"
        out_path = OUT_DIR / f"{sprite_id}.png"
        out_path.write_bytes(out_bytes)
        written[sprite_id] = out_bytes
        corners = tile.get("corners") or {}
        ledger_tiles[sprite_id] = {
            "wang_index": i,
            "nw": corners.get("NW", ""),
            "ne": corners.get("NE", ""),
            "sw": corners.get("SW", ""),
            "se": corners.get("SE", ""),
            "pixel_id": str(tile.get("id", "")),
            "sha256": hashlib.sha256(out_bytes).hexdigest(),
        }

    submit = RAW_DIR / ("tileset_coastline_"
                        "77f5cd00-82a1-4a85-af7e-a8133eae33a4_submit.json")
    submit_doc = json.loads(submit.read_text()) if submit.is_file() else {}
    ledger = {
        "generated_by": "tools/build_terrain_pixellab.py",
        "source": f"tools/assets/pixellab_raw/{SOURCE_JSON}",
        "pixellab": {
            "tileset_id": submit_doc.get("tileset_id", ""),
            "background_job_id": submit_doc.get("background_job_id", ""),
            "seed": 20261106,
            "mode": "pro",
            "tile_size": 64,
        },
        "note": ("80-* §4.8 2026-11-06 terrain family — the model's "
                 "deliberate pixels ship as drawn (palette/budget waived "
                 "in group 13 via this ledger, the raw-pixellab hull "
                 "precedent). Placement (2026-11-06 evening contract): "
                 "WATER cells always stamp plain wang_0 (never corner "
                 "art); LAND cells stamp the water-flanking index — a "
                 "corner is flanked when any of its three adjacent map "
                 "neighbours is water, upper corners = non-flanked, "
                 "index = NW·8 + NE·4 + SW·2 + SE·1 over {1..14}, baked "
                 "at atlas columns 8..21; 15 = interior (the 8-dihedral "
                 "pool); 0 (all corners flanked) = impossible on the "
                 "built map (§6.2 cleanup), legacy-variant fallback."),
        "tiles": ledger_tiles,
    }
    LEDGER_PATH.write_text(json.dumps(ledger, indent=2, sort_keys=True)
                           + "\n")

    for sprite_id, out_bytes in sorted(written.items()):
        print(f"{sprite_id}: 64x64 RGBA, {len(out_bytes)} B, "
              f"sha {ledger_tiles[sprite_id]['sha256'][:12]}")
    print(f"ledger: {LEDGER_PATH.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
