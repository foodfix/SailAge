#!/usr/bin/env python3
"""build_web_tiles.py — deterministic web tile-pyramid builder (web era, M4).

Slices the four tool-owned 4320x2160 world rasters into the committed
browser tile family of docs/10-DATA-SCHEMA.md §6.8:

    data/maps/world.png        -> web/public/tiles/world/<z>/<x>_<y>.png
    data/maps/wind_regions.png -> web/public/tiles/wind/<z>/<x>_<y>.png
    data/maps/currents.png     -> web/public/tiles/currents/<z>/<x>_<y>.png
    data/maps/dist_land.png    -> web/public/tiles/dist_land/<z>/<x>_<y>.png

Spec (frozen in M0, §6.8):

* **Tiles are 256x256 px.** Zoom level *z* ∈ 0–3 holds the raster at scale
  1/2^z: z0 = 4320x2160 (17x9 tiles), z1 = 2160x1080 (9x5), z2 = 1080x540
  (5x3), z3 = 540x270 (3x2). Edge tiles are *cropped* to the raster extent,
  never padded, so a level's grid exactly covers [0, 4320) x [0, 2160).
* **Downsample:** nearest-neighbour picking — level pixel (x, y) copies
  source pixel (x·2^z, y·2^z). Deterministic, palette-preserving: an indexed
  source re-encodes with its own palette at every level, `dist_land.png`'s
  RGB8 keeps its R=high/G=low encode byte-for-byte.
* **Encoding:** the same stdlib PNG writer family as the other raster tools
  (colour type per source — 3 for world/wind/currents, 2 for dist_land; bit
  depth 8; filter 0 per scanline; one fixed zlib level). No ancillary chunks,
  no timestamps: two consecutive builds are byte-identical.

Governance — the §6.3 amendment family: `web/public/tiles/` is written only
by this tool, **never hand-edited**, and committed. Validator group 15
(§8.10) owns the inventory + `--check` + decode spot-probes; `--check` is
the fixture command. The `--report` output is a debug aid only — never part
of the artifact.

Wrap: tiles never duplicate wrap content — the x seam stays inside the
raster; the client renders it by sampling across the level edge (§6.8).

Usage
-----
    python3 tools/build_web_tiles.py            # build the tree
    python3 tools/build_web_tiles.py --check    # rebuild in memory, byte-compare
    python3 tools/build_web_tiles.py --report   # inventory summary (no writes)

Exit codes: 0 ok (or `--check` identical); 1 `--check` drift; 2 missing or
invalid input tree (a committed tile tree, a source raster, or a source PNG
that does not match its §6.x format).
"""

from __future__ import annotations

import argparse
import hashlib
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAPS = ROOT / "data" / "maps"
TILES = ROOT / "web" / "public" / "tiles"

GRID_W, GRID_H = 4320, 2160   # §6.1 / §6.3 — one texel per tile
TILE_PX = 256                 # §6.8 frozen tile size
LEVELS = 4                    # z 0-3
MAX_SHIFT = 3

# (artifact source dir, source file, PNG colour type, format note)
SOURCES = (
    ("world", "world.png", 3, "§6.3 indexed ~ . # ^ I"),
    ("wind", "wind_regions.png", 3, "§6.5 indexed region ids"),
    ("currents", "currents.png", 3, "§6.5 indexed current vectors"),
    ("dist_land", "dist_land.png", 2, "§6.7 RGB8 distance encode"),
)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
ZLIB_LEVEL = 9  # the house tools' fixed setting (build_world/build_ocean/shore)


class BuildError(Exception):
    """A loud, named build failure (exit code 2)."""


class SourceImage:
    """A decoded source raster: 8-bit samples, one or three per pixel."""

    __slots__ = ("width", "height", "colour", "palette", "pixels")

    def __init__(self, width: int, height: int, colour: int,
                 palette: bytes, pixels: bytes):
        self.width = width
        self.height = height
        self.colour = colour
        self.palette = palette
        self.pixels = pixels

    @property
    def bpp(self) -> int:
        return 3 if self.colour == 2 else 1


# --------------------------------------------------------------------------
# Minimal PNG reader (stdlib only, zlib + unfilter; standalone by design —
# deliberately independent of build_shore.py / build_ocean.py and of
# server/sim/world/raster.py, the validator's reader being the cross-check)
# --------------------------------------------------------------------------
def _unfilter_scanlines(raw: bytes, width: int, height: int,
                        bpp: int) -> bytes:
    """Reverse PNG filter types 0-4 for 8-bit samples (bpp = 1 or 3)."""
    stride = width * bpp
    if len(raw) != (stride + 1) * height:
        raise BuildError(
            f"IDAT inflates to {len(raw)} bytes, expected "
            f"{(stride + 1) * height} for {width}x{height} at {bpp} "
            "bytes/pixel")
    out = bytearray(stride * height)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        filter_type = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if filter_type == 0:  # None
            pass
        elif filter_type == 1:  # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                up = prev[i]
                up_left = prev[i - bpp] if i >= bpp else 0
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
                f"row {y} uses undefined PNG filter type {filter_type} "
                "(0-4 defined)")
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return bytes(out)


def decode_source(data: bytes, label: str) -> SourceImage:
    """Decode one source raster (indexed 8-bit or RGB8, non-interlaced)."""
    if not data.startswith(PNG_SIGNATURE):
        raise BuildError(f"{label}: not a PNG (bad signature)")
    pos = len(PNG_SIGNATURE)
    header = None
    palette = None
    idat = bytearray()
    saw_iend = False
    while pos < len(data):
        if pos + 8 > len(data):
            raise BuildError(f"{label}: truncated chunk header")
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        if pos + 12 + length > len(data):
            raise BuildError(f"{label}: truncated {tag!r} chunk")
        payload = data[pos + 8:pos + 8 + length]
        crc = struct.unpack(
            ">I", data[pos + 8 + length:pos + 12 + length])[0]
        if crc != (zlib.crc32(tag + payload) & 0xFFFFFFFF):
            raise BuildError(f"{label}: bad CRC in chunk {tag!r}")
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
        raise BuildError(f"{label}: no IHDR chunk")
    if not saw_iend:
        raise BuildError(f"{label}: no IEND chunk (truncated file)")
    width, height, depth, colour, compression, filt, interlace = header
    if colour not in (2, 3) or depth != 8:
        raise BuildError(
            f"{label}: expected indexed or RGB 8-bit, got colour type "
            f"{colour} depth {depth}")
    if compression != 0 or filt != 0 or interlace != 0:
        raise BuildError(
            f"{label}: unsupported compression/filter/interlace "
            f"{compression}/{filt}/{interlace}")
    if colour == 3 and (palette is None or len(palette) < 3):
        raise BuildError(f"{label}: indexed PNG without a usable PLTE chunk")
    if not idat:
        raise BuildError(f"{label}: no IDAT chunk")
    try:
        raw = zlib.decompress(bytes(idat))
    except zlib.error as exc:
        raise BuildError(f"{label}: IDAT does not inflate: {exc}") from exc
    bpp = 3 if colour == 2 else 1
    pixels = _unfilter_scanlines(raw, width, height, bpp)
    return SourceImage(width, height, colour, palette or b"", pixels)


# --------------------------------------------------------------------------
# The §6.8 pyramid — level geometry, downsample, tile split
# --------------------------------------------------------------------------
def level_dimensions(z: int) -> tuple[int, int]:
    """Level z holds the raster at 1/2^z: (4320, 2160) >> z exactly."""
    step = 1 << z
    if GRID_W % step or GRID_H % step:
        raise BuildError(
            f"level {z}: {GRID_W}x{GRID_H} is not divisible by {step} — "
            "the §6.8 levels assume exact halving")
    return GRID_W // step, GRID_H // step


def tile_grid(z: int) -> tuple[int, int]:
    """Tiles across/down at level z (§6.8: 17x9 / 9x5 / 5x3 / 3x2)."""
    lw, lh = level_dimensions(z)
    return ((lw + TILE_PX - 1) // TILE_PX,
            (lh + TILE_PX - 1) // TILE_PX)


def downsample_rows(img: SourceImage, z: int) -> list[bytes]:
    """Nearest-neighbour rows at level z: pixel (x,y) := source (x·2^z, y·2^z).

    Row picking is a C-level slice per channel (the source dimensions divide
    evenly by every step), so the whole 4-level pyramid costs a few
    translations, not a per-pixel Python loop.
    """
    step = 1 << z
    lw, lh = level_dimensions(z)
    bpp = img.bpp
    stride = img.width * bpp
    rows: list[bytes] = []
    if bpp == 1:
        for y in range(lh):
            base = (y * step) * stride
            rows.append(img.pixels[base:base + stride][0::step])
        return rows
    for y in range(lh):
        base = (y * step) * stride
        row = img.pixels[base:base + stride]
        picked = bytearray(lw * 3)
        for channel in range(3):
            picked[channel::3] = row[channel::3 * step]
        rows.append(bytes(picked))
    return rows


def _png_chunk(tag: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def encode_tile(rows: list[bytes], x0: int, y0: int, width: int, height: int,
                colour: int, palette: bytes, bpp: int) -> bytes:
    """One cropped tile as a deterministic PNG (filter 0, fixed zlib level).

    Indexed sources keep their own palette (PLTE copied verbatim); RGB8
    sources carry colour type 2. The chunk order is the house tools':
    IHDR, [PLTE], IDAT, IEND — no ancillary chunks, so the bytes depend only
    on the pixel content and this file.
    """
    raw = bytearray()
    for row in rows[y0:y0 + height]:
        raw.append(0)  # filter type 0 (None) per scanline
        raw += row[x0 * bpp:(x0 + width) * bpp]
    ihdr = struct.pack(">IIBBBBB", width, height, 8, colour, 0, 0, 0)
    chunks = [PNG_SIGNATURE, _png_chunk(b"IHDR", ihdr)]
    if colour == 3:
        chunks.append(_png_chunk(b"PLTE", palette))
    chunks.append(_png_chunk(b"IDAT", zlib.compress(bytes(raw), ZLIB_LEVEL)))
    chunks.append(_png_chunk(b"IEND", b""))
    return b"".join(chunks)


class SourcePyramid:
    """The generated tiles of one source, keyed by repo-relative path."""

    __slots__ = ("name", "tiles", "per_level")

    def __init__(self, name: str):
        self.name = name
        self.tiles: dict[Path, bytes] = {}
        self.per_level: list[int] = []


def build_pyramid(source: str, filename: str, colour: int,
                  note: str) -> SourcePyramid:
    path = MAPS / filename
    if not path.is_file():
        raise BuildError(
            f"data/maps/{filename} not found — the {note} source raster is "
            "required by §6.8; generate it with the family tool first")
    img = decode_source(path.read_bytes(), f"data/maps/{filename}")
    if (img.width, img.height) != (GRID_W, GRID_H):
        raise BuildError(
            f"data/maps/{filename} is {img.width}x{img.height}, expected "
            f"{GRID_W}x{GRID_H} (§6.3 grid)")
    if img.colour != colour:
        raise BuildError(
            f"data/maps/{filename}: colour type {img.colour}, expected "
            f"{colour} ({note})")

    pyramid = SourcePyramid(source)
    for z in range(LEVELS):
        rows = downsample_rows(img, z)
        lw, lh = level_dimensions(z)
        gx, gy = tile_grid(z)
        count = 0
        for ty in range(gy):
            y0 = ty * TILE_PX
            height = min(TILE_PX, lh - y0)  # cropped edge tile (§6.8)
            for tx in range(gx):
                x0 = tx * TILE_PX
                width = min(TILE_PX, lw - x0)
                blob = encode_tile(
                    rows, x0, y0, width, height, img.colour, img.palette,
                    img.bpp)
                pyramid.tiles[
                    TILES / source / str(z) / f"{tx}_{ty}.png"] = blob
                count += 1
        pyramid.per_level.append(count)
    return pyramid


def build_tree() -> list[SourcePyramid]:
    return [build_pyramid(name, filename, colour, note)
            for name, filename, colour, note in SOURCES]


def tree_digest(pyramids: list[SourcePyramid]) -> str:
    """sha256 over the sorted (relpath, bytes) manifest — one tree fingerprint."""
    digest = hashlib.sha256()
    entries = []
    for pyramid in pyramids:
        for path, blob in pyramid.tiles.items():
            entries.append((path.relative_to(TILES).as_posix(), blob))
    for relpath, blob in sorted(entries):
        digest.update(relpath.encode("utf-8") + b"\x00")
        digest.update(hashlib.sha256(blob).digest())
    return digest.hexdigest()


# --------------------------------------------------------------------------
# CLI commands
# --------------------------------------------------------------------------
def _report_lines(pyramids: list[SourcePyramid]) -> list[str]:
    lines = []
    total_files = 0
    total_bytes = 0
    for pyramid in pyramids:
        files = len(pyramid.tiles)
        blob_bytes = sum(len(blob) for blob in pyramid.tiles.values())
        total_files += files
        total_bytes += blob_bytes
        per_level = " ".join(
            f"z{z}={count}" for z, count in enumerate(pyramid.per_level))
        lines.append(
            f"  {pyramid.name:<9} {files:>3} tiles ({per_level}) "
            f"{blob_bytes} bytes")
    lines.append(
        f"  {'total':<9} {total_files:>3} tiles {total_bytes} bytes "
        f"tree sha256 {tree_digest(pyramids)}")
    return lines


def cmd_build() -> int:
    pyramids = build_tree()
    expected: dict[Path, bytes] = {}
    for pyramid in pyramids:
        expected.update(pyramid.tiles)

    written = 0
    for path, blob in expected.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_file() and path.read_bytes() == blob:
            continue  # idempotent: leave an identical file untouched
        path.write_bytes(blob)
        written += 1

    # The tree is tool-owned: anything that is not part of the pyramid is a
    # stray (validator group 15 item 1 fails it), so the build prunes it.
    pruned = 0
    keep_dirs = {TILES}
    for path in expected:
        keep_dirs.add(path.parent)
        keep_dirs.add(path.parent.parent)
    if TILES.is_dir():
        for entry in sorted(TILES.rglob("*"), reverse=True):
            if entry.is_file():
                if entry not in expected:
                    entry.unlink()
                    pruned += 1
            elif entry.is_dir() and entry not in keep_dirs:
                try:
                    entry.rmdir()  # only if empty
                except OSError:
                    pass

    print(f"build_web_tiles: wrote {TILES.relative_to(ROOT)} "
          f"({len(expected)} tiles, {written} changed, {pruned} strays pruned)")
    for line in _report_lines(pyramids):
        print(line)
    return 0


def cmd_check() -> int:
    """Rebuild the whole pyramid in memory and byte-compare the committed tree.

    Exit 0 identical, 1 the first differing byte / missing or extra file, 2
    the committed tree is absent entirely (nothing to compare against).
    """
    if not TILES.is_dir():
        print(
            "build_web_tiles: check FAILED — web/public/tiles/ is missing "
            "(§6.8: the committed tile tree is tool-owned; run "
            "tools/build_web_tiles.py)",
            file=sys.stderr,
        )
        return 2
    pyramids = build_tree()
    expected: dict[Path, bytes] = {}
    for pyramid in pyramids:
        expected.update(pyramid.tiles)

    for path in sorted(expected):
        relpath = path.relative_to(ROOT)
        if not path.is_file():
            print(
                f"build_web_tiles: check FAILED — {relpath} is missing from "
                f"the committed tree (§6.8 grid: {len(expected)} tiles); "
                "regenerate with tools/build_web_tiles.py",
                file=sys.stderr,
            )
            return 1
        committed = path.read_bytes()
        if committed == expected[path]:
            continue
        offset = next(
            (i for i, (a, b) in enumerate(zip(committed, expected[path]))
             if a != b),
            min(len(committed), len(expected[path])),
        )
        print(
            f"build_web_tiles: check FAILED — {relpath} differs at byte "
            f"{offset} (committed {len(committed)} bytes sha256 "
            f"{hashlib.sha256(committed).hexdigest()[:16]}, rebuild "
            f"{len(expected[path])} bytes sha256 "
            f"{hashlib.sha256(expected[path]).hexdigest()[:16]}); the "
            "pyramids are tool-owned — regenerate, never hand-edit (§6.8)",
            file=sys.stderr,
        )
        return 1

    extras = sorted(
        entry for entry in TILES.rglob("*")
        if entry.is_file() and entry not in expected)
    if extras:
        relpath = extras[0].relative_to(ROOT)
        print(
            f"build_web_tiles: check FAILED — stray file {relpath} (not part "
            f"of the §6.8 grid; {len(extras)} stray file(s)); regenerate "
            "with tools/build_web_tiles.py",
            file=sys.stderr,
        )
        return 1

    print(
        f"build_web_tiles: check OK — {len(expected)} tiles rebuild "
        f"byte-identical (tree sha256 {tree_digest(pyramids)})")
    return 0


def cmd_report() -> int:
    pyramids = build_tree()
    print("build_web_tiles: §6.8 inventory (no files written)")
    for line in _report_lines(pyramids):
        print(line)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Build web/public/tiles/ from the four §6 world rasters "
                    "(§6.8; deterministic — two builds are byte-identical).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--check", action="store_true",
        help="rebuild in memory and byte-compare against the committed tree; "
             "exit 1 on drift, 2 when the tree is missing (§8.10 item 2)")
    parser.add_argument(
        "--report", action="store_true",
        help="print the per-source/level inventory (debug aid, no writes)")
    args = parser.parse_args(argv)

    try:
        if args.check:
            return cmd_check()
        if args.report:
            return cmd_report()
        return cmd_build()
    except BuildError as exc:
        print(f"build_web_tiles: FAIL: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
