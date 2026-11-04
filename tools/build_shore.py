#!/usr/bin/env python3
"""build_shore.py — deterministic shore-edge raster builder (Phase 10, W3-C).

Builds ``data/maps/world_shore.png`` — the tool-owned lookup raster of
docs/10-DATA-SCHEMA.md §6.6 — from ``data/maps/world.png`` alone:

    data/maps/world_shore.png    palette index 0 = no edge; indices 1..8 =
                                 the edge codes n ne e se s sw w nw (the
                                 §6.5 compass order, which is also the
                                 priority order n > ne > e > se > s > sw >
                                 w > nw)

A water tile of ``world.png`` (indices 0/1 = ``~``/``.``) carries the code
of direction *d* when its 8-neighbour in direction *d* is land (``#``),
reef (``^``) or ice (``I``); x is wrap-aware (mod 4320, the §6.1 grid), a
neighbour with y out of range counts as non-land (the §6.2 locked ice band
makes that case unreachable in practice); a tile qualifying for several
directions takes the highest-priority one. Land, reef and ice tiles are
always 0 — the raster codes water only. The overlay is cosmetic only
(§6.6): passability and the sea/coastal_sea split keep following the
``world.png`` indices.

Format: indexed-colour PNG (colour type 3, bit depth 8), exactly
4320 x 2160 — 1 px = 1 tile. The palette is a debug convenience (the
runtime reads indices, colours are irrelevant): index 0 is a dark filler,
indices 1..8 one distinct hue per direction — the literals below are the
pinned palette.

Governance — the §6.3 amendment family: written only by this tool, never
hand-edited; two consecutive builds are byte-identical (validator group 13
item 9, §8.8 re-asserts it; ``--check`` is the fixture command). The ASCII
export is a debug output only — never shipped, never a data source.

Usage
-----
    python3 tools/build_shore.py              # build + write world_shore.png
    python3 tools/build_shore.py --check      # rebuild in memory, byte-compare
    python3 tools/build_shore.py --ascii      # debug export (stdout)
    python3 tools/build_shore.py --ascii --rows 600:640 [--ascii-out PATH]

Exit codes: 0 ok; 1 usage/CLI failure; 2 BuildError (a named source
problem); 3 determinism drift (``--check`` mismatch).
"""

from __future__ import annotations

import argparse
import hashlib
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
WORLD_PNG = DATA / "maps" / "world.png"
SHORE_PNG = DATA / "maps" / "world_shore.png"

GRID_W, GRID_H = 4320, 2160  # §6.3 / §6.6 — 1 px = 1 tile

# world.png palette indices (§6.3): 0..4 = ~ . # ^ I
SEA, COAST, LAND, REEF, ICE = 0, 1, 2, 3, 4
WATER_INDICES = frozenset((SEA, COAST))
BLOCKER_INDICES = frozenset((LAND, REEF, ICE))

# §6.6 codes 1..8: compass order == priority order. (dx, dy) on the tile
# grid (y down); x wraps, y clamps by dropping the candidate.
SHORE_CODES = (
    ("n", 0, -1),
    ("ne", 1, -1),
    ("e", 1, 0),
    ("se", 1, 1),
    ("s", 0, 1),
    ("sw", -1, 1),
    ("w", -1, 0),
    ("nw", -1, -1),
)
CODE_INDEX = {name: i + 1 for i, (name, _dx, _dy) in enumerate(SHORE_CODES)}

# Pinned palette (§6.6: the raster is a lookup — colours irrelevant, these
# literals are the pin; hue = dir_index * 45 deg, HLS L 0.42 S 0.80, and
# index 0 a dark filler).
SHORE_PALETTE = (
    (0x00, 0x00, 0x00),  # 0  no edge
    (0xC1, 0x15, 0x15),  # 1  n
    (0xC1, 0x96, 0x15),  # 2  ne
    (0x6B, 0xC1, 0x15),  # 3  e
    (0x15, 0xC1, 0x40),  # 4  se
    (0x15, 0xC1, 0xC1),  # 5  s
    (0x15, 0x40, 0xC1),  # 6  sw
    (0x6B, 0x15, 0xC1),  # 7  w
    (0xC1, 0x15, 0x96),  # 8  nw
)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# byte-lookup tables (build_world's translate trick)
_BLOCKER_TABLE = bytes(
    1 if i in BLOCKER_INDICES else 0 for i in range(256))
_WATER_TABLE = bytes(1 if i in WATER_INDICES else 0 for i in range(256))


class BuildError(Exception):
    """A loud, named build failure (exit code 2)."""


# --------------------------------------------------------------------------
# Minimal indexed-PNG reader (stdlib only, zlib + unfilter; standalone by
# design — deliberately independent of build_world.py and validate_data.py,
# the validator's own reader being the other half of the cross-check)
# --------------------------------------------------------------------------
def _unfilter_scanlines(raw: bytes, width: int, height: int) -> bytearray:
    """Reverse PNG filter types 0-4 for an 8-bit indexed image."""
    stride = width + 1
    if len(raw) != stride * height:
        raise BuildError(
            f"world.png: IDAT inflates to {len(raw)} bytes, expected "
            f"{stride * height} for {width}x{height}")
    out = bytearray(width * height)
    prev = bytearray(width)
    pos = 0
    for y in range(height):
        filter_type = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + width])
        pos += width
        if filter_type == 0:  # None
            pass
        elif filter_type == 1:  # Sub
            for i in range(1, width):
                line[i] = (line[i] + line[i - 1]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(width):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(width):
                left = line[i - 1] if i else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(width):
                left = line[i - 1] if i else 0
                up = prev[i]
                up_left = prev[i - 1] if i else 0
                p = left + up - up_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                if pa <= pb and pa <= pc:
                    predictor = left
                elif pb <= pc:
                    predictor = up
                else:
                    predictor = up_left
                line[i] = (line[i] + predictor) & 0xFF
        else:
            raise BuildError(
                f"world.png: row {y} uses undefined PNG filter type "
                f"{filter_type} (0-4 defined)")
        out[y * width:(y + 1) * width] = line
        prev = line
    return out


def decode_world_png(data: bytes) -> list[bytearray]:
    """Decode world.png (indexed 8-bit) to one ``bytearray`` per row."""
    if not data.startswith(PNG_SIGNATURE):
        raise BuildError("world.png: not a PNG (bad signature)")
    pos = len(PNG_SIGNATURE)
    header = None
    palette = None
    idat = bytearray()
    saw_iend = False
    while pos < len(data):
        if pos + 8 > len(data):
            raise BuildError("world.png: truncated chunk header")
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        if pos + 12 + length > len(data):
            raise BuildError(f"world.png: truncated {tag!r} chunk")
        payload = data[pos + 8:pos + 8 + length]
        crc = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        if crc != (zlib.crc32(tag + payload) & 0xFFFFFFFF):
            raise BuildError(f"world.png: bad CRC in chunk {tag!r}")
        pos += 12 + length
        if tag == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif tag == b"PLTE":
            palette = payload
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            saw_iend = True
            break
    if header is None:
        raise BuildError("world.png: no IHDR chunk")
    if not saw_iend:
        raise BuildError("world.png: no IEND chunk (truncated file)")
    width, height, depth, colour, compression, filt, interlace = header
    if (width, height) != (GRID_W, GRID_H):
        raise BuildError(
            f"world.png is {width}x{height}, expected {GRID_W}x{GRID_H}")
    if colour != 3 or depth != 8:
        raise BuildError(
            f"world.png: expected indexed 8-bit, got colour type {colour} "
            f"depth {depth}")
    if compression != 0 or filt != 0 or interlace != 0:
        raise BuildError(
            f"world.png: unsupported compression/filter/interlace "
            f"{compression}/{filt}/{interlace}")
    if palette is None or len(palette) < 15:
        raise BuildError(
            "world.png: palette needs at least the 5 locked entries (~ . # ^ I)")
    if not idat:
        raise BuildError("world.png: no IDAT chunk")
    try:
        raw = zlib.decompress(bytes(idat))
    except zlib.error as exc:
        raise BuildError(f"world.png: IDAT does not inflate: {exc}") from exc
    indices = _unfilter_scanlines(raw, width, height)
    rows = [bytearray(indices[y * width:(y + 1) * width]) for y in range(height)]
    highest = max(indices)
    if highest > 4:
        raise BuildError(
            f"world.png: palette index {highest} outside the locked 0-4 "
            "domain (§6.3) — build_shore classifies ~ . # ^ I only")
    return rows


# --------------------------------------------------------------------------
# Shore derivation (§6.6) — pure function of the world grid
# --------------------------------------------------------------------------
def derive_shore(world: list[bytearray]) -> list[bytearray]:
    """Return one ``bytearray`` per row of shore codes 0..8.

    Eight cheap passes (one per direction, lowest priority first — nw to
    n — each later pass overwrites the earlier ones, which implements the
    priority order without per-cell branching). Every pass is a byte-row
    rotate + big-int AND + a scan over the candidate positions only (the
    coastal band), so the cost stays at a few row translations per
    direction, not 9.3M cell visits.
    """
    height, width = len(world), len(world[0])
    water_rows = [bytes(row).translate(_WATER_TABLE) for row in world]
    blocker_rows = [bytes(row).translate(_BLOCKER_TABLE) for row in world]
    water_ints = [int.from_bytes(mask, "big") for mask in water_rows]
    shore = [bytearray(width) for _ in range(height)]

    for name, dx, dy in reversed(SHORE_CODES):  # nw (8) … n (1)
        code = CODE_INDEX[name]
        for y in range(height):
            src_y = y + dy  # the (x+dx, y+dy) neighbour's row
            if src_y < 0 or src_y >= height:
                continue  # y out of range counts as non-land (§6.6)
            nbor = blocker_rows[src_y]
            if dx:
                shift = dx % width
                nbor = nbor[shift:] + nbor[:shift]  # nbor[x] = b[(x+dx) % w]
            # nbor[x] is the blocker flag of this cell's (x+dx, y+dy) neighbour
            candidates = water_ints[y] & int.from_bytes(nbor, "big")
            if not candidates:
                continue
            cand = candidates.to_bytes(width, "big")
            pos = cand.find(1)
            while pos != -1:
                shore[y][pos] = code
                pos = cand.find(1, pos + 1)
    return shore


def code_counts(shore: list[bytearray]) -> dict[str, int]:
    counts = {name: 0 for name, *_ in SHORE_CODES}
    counts["none"] = 0
    for row in shore:
        for v in row:
            if v == 0:
                counts["none"] += 1
            else:
                counts[SHORE_CODES[v - 1][0]] += 1
    return counts


# --------------------------------------------------------------------------
# PNG encoding (build_world/build_ocean's deterministic chunk layout)
# --------------------------------------------------------------------------
def _png_chunk(tag: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def encode_raster(shore: list[bytearray]) -> bytes:
    """Indexed-colour PNG: colour type 3, bit depth 8, filter 0, zlib 9.

    Deterministic for a given raster: no tIME/text chunks, the pinned
    9-entry palette, one fixed compression setting.
    """
    height, width = len(shore), len(shore[0])
    raw = bytearray()
    for row in shore:
        raw.append(0)  # filter type 0 (None) per scanline
        raw += row
    compressed = zlib.compress(bytes(raw), 9)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)
    plte = bytes(channel for rgb in SHORE_PALETTE for channel in rgb)
    return (
        PNG_SIGNATURE
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"PLTE", plte)
        + _png_chunk(b"IDAT", compressed)
        + _png_chunk(b"IEND", b"")
    )


def sha256_bytes(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def build() -> bytes:
    """Build the shore raster; return the PNG bytes."""
    if not WORLD_PNG.is_file():
        raise BuildError(
            "data/maps/world.png not found — run tools/build_world.py first")
    world = decode_world_png(WORLD_PNG.read_bytes())
    shore = derive_shore(world)
    return encode_raster(shore)


# --------------------------------------------------------------------------
# CLI commands
# --------------------------------------------------------------------------
def cmd_build() -> int:
    png = build()
    SHORE_PNG.write_bytes(png)
    world = decode_world_png(WORLD_PNG.read_bytes())
    shore = derive_shore(world)
    counts = code_counts(shore)
    coded = sum(v for k, v in counts.items() if k != "none")
    water = sum(r.count(1) for r in
                (bytes(row).translate(_WATER_TABLE) for row in world))
    print(
        f"build_shore: wrote {SHORE_PNG.relative_to(ROOT)} "
        f"({len(png)} bytes, sha256 {sha256_bytes(png)})")
    print(
        f"build_shore: coded {coded} of {water} water tiles "
        f"({water - coded} uncoded water, {counts['none']} land/reef/ice) — "
        + " ".join(f"{name}={counts[name]}" for name, *_ in SHORE_CODES))
    return 0


def cmd_check() -> int:
    """Rebuild in memory and byte-compare against the committed raster."""
    png = build()
    if SHORE_PNG.read_bytes() == png:
        print(
            f"build_shore: check OK — {SHORE_PNG.relative_to(ROOT)} rebuilds "
            f"byte-identical (sha256 {sha256_bytes(png)})")
        return 0
    print(
        f"build_shore: check FAILED — {SHORE_PNG.relative_to(ROOT)} differs "
        f"from the rebuild (want sha256 {sha256_bytes(png)}); regenerate with "
        "tools/build_shore.py — never hand-edit the raster",
        file=sys.stderr,
    )
    return 3


# ASCII debug export (never a data source; never written under data/)
ASCII_CHARS = ".12345678"


def parse_rows(spec: str, height: int) -> tuple[int, int]:
    if ":" not in spec:
        raise argparse.ArgumentTypeError("--rows wants A:B (1-based, inclusive)")
    left, right = spec.split(":", 1)
    try:
        start, end = int(left), int(right)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"--rows wants integers, got {spec!r}") from exc
    if start < 1 or end < start or end > height:
        raise argparse.ArgumentTypeError(
            f"--rows {spec!r} outside 1..{height}")
    return start, end


def cmd_ascii(args) -> int:
    world = decode_world_png(WORLD_PNG.read_bytes())
    shore = derive_shore(world)
    height = len(shore)
    start, end = (parse_rows(args.rows, height) if args.rows
                  else (1, height))
    table = bytes((ord(ASCII_CHARS[i]) if i < len(ASCII_CHARS) else ord("?"))
                  for i in range(256))
    lines = [bytes(row).translate(table).decode("ascii") for row in shore]
    header = (f"# world_shore (rows {start}-{end}, chars: '{ASCII_CHARS[0]}' "
              "none, 1..8 = n ne e se s sw w nw)")
    text = header + "\n" + "\n".join(lines[start - 1:end]) + "\n"
    if args.ascii_out:
        out = Path(args.ascii_out)
        if DATA.resolve() in out.resolve().parents:
            print(
                "build_shore: refusing to write the ASCII debug export under "
                f"data/ ({out}); use a temp path", file=sys.stderr)
            return 2
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8", newline="\n")
        print(f"build_shore: wrote {end - start + 1} ASCII rows to {out}",
              file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Build data/maps/world_shore.png from world.png "
                    "(§6.6; deterministic — two builds are byte-identical).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--check", action="store_true",
        help="rebuild in memory and byte-compare against the committed "
             "raster; exit 3 on drift (the §8.8 fixture command)")
    parser.add_argument(
        "--ascii", action="store_true",
        help="debug export: the raster as one character per tile (stdout "
             "unless --ascii-out is given; never under data/)")
    parser.add_argument(
        "--rows", metavar="A:B",
        help="1-based inclusive row range for --ascii (default: all rows)")
    parser.add_argument(
        "--ascii-out", metavar="PATH", help="write the ASCII export to PATH")
    args = parser.parse_args(argv)

    try:
        if args.ascii:
            return cmd_ascii(args)
        if args.check:
            return cmd_check()
        return cmd_build()
    except BuildError as exc:
        print(f"build_shore: FAIL: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
