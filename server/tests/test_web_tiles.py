"""Contract pins for the §6.8 web tile pyramid (``tools/build_web_tiles.py``).

Port the guarantee, not the method (AGENTS.md test discipline). The gate for
the full pyramid is validator group 15 (``§8.10``): inventory equality plus
``build_web_tiles.py --check``'s in-memory byte comparison of all 876 tiles.
This suite pins the contract cheaply instead of re-deriving the pyramid:

  * the frozen geometry per source/level — tile counts 17x9 / 9x5 / 5x3 /
    3x2 with every file present and nothing stray;
  * cropped edge-tile dimensions (and the full 256x256 interior tiles) plus
    the exact level coverage ``[0, 4320) x [0, 2160)``;
  * one fixed pixel sample per source against the nearest-neighbour rule
    ``level (x, y) := source (x·2^z, y·2^z)``, both encoder families
    (indexed and RGB8);
  * the indexed families' palette kept byte-identical to the source, and
    ``dist_land``'s RGB8 colour type carried through;
  * ``--check`` exits 0 on the committed tree (the determinism fixture).

Deterministic; no RNG, no full-raster walks (the sources are decoded once
per module through the single-owner M1 raster layer).
"""

from __future__ import annotations

import struct
import subprocess
import sys
import zlib
from pathlib import Path

import pytest

from server.sim.world.raster import (
    GRID_HEIGHT,
    GRID_WIDTH,
    decode_indexed_png,
    decode_rgb8_png,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOL = REPO_ROOT / "tools" / "build_web_tiles.py"
TILES = REPO_ROOT / "web" / "public" / "tiles"

TILE_PX = 256
# §6.8: (source dir, source raster, colour type, type-2 uses RGB triples).
SOURCES = (
    ("world", "world.png", 3),
    ("wind", "wind_regions.png", 3),
    ("currents", "currents.png", 3),
    ("dist_land", "dist_land.png", 2),
)
LEVEL_GRIDS = ((17, 9), (9, 5), (5, 3), (3, 2))


def _level_dims(z: int) -> tuple[int, int]:
    return GRID_WIDTH >> z, GRID_HEIGHT >> z


def _tilename(tx: int, ty: int) -> str:
    return f"{tx}_{ty}.png"


# --- tiny PNG header/PLTE readers (geometry, colour type, palette) ---------

def _png_meta(data: bytes) -> tuple[int, int, int, int, bytes | None]:
    """(width, height, bit depth, colour type, PLTE payload) of a PNG."""
    assert data.startswith(b"\x89PNG\r\n\x1a\n"), "not a PNG"
    pos = 8
    header = None
    palette = None
    saw_iend = False
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        crc = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        assert crc == (zlib.crc32(tag + payload) & 0xFFFFFFFF), tag
        pos += 12 + length
        if tag == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif tag == b"PLTE":
            palette = payload
        elif tag == b"IEND":
            saw_iend = True
            break
    assert header is not None and saw_iend, "IHDR/IEND missing"
    width, height, depth, colour, compression, filt, interlace = header
    assert (compression, filt, interlace) == (0, 0, 0)
    return width, height, depth, colour, palette


# --- module-scope source rasters (decoded once) ---------------------------

@pytest.fixture(scope="module")
def sources() -> dict[str, dict]:
    decoded = {}
    for name, filename, colour in SOURCES:
        path = REPO_ROOT / "data" / "maps" / filename
        if not path.is_file():  # staged checkout: group 15 owns the failure
            pytest.skip(f"source raster {path.name} not present")
        data = path.read_bytes()
        width, height, _depth, got_colour, palette = _png_meta(data)
        if colour == 3:
            w, h, pixels = decode_indexed_png(data, filename)
        else:
            w, h, pixels = decode_rgb8_png(data, filename)
        assert (w, h) == (GRID_WIDTH, GRID_HEIGHT) == (width, height)
        assert got_colour == colour
        decoded[name] = {"pixels": pixels, "palette": palette,
                         "bpp": 3 if colour == 2 else 1, "colour": colour}
    return decoded


# --- the §6.8 grid itself -------------------------------------------------

def test_inventory_is_exactly_the_frozen_grid():
    """Four sources x four levels, 17x9/9x5/5x3/3x2 tiles, nothing else."""
    committed = {p.relative_to(TILES).as_posix()
                 for p in TILES.rglob("*") if p.is_file()}
    expected = set()
    for name, _filename, _colour in SOURCES:
        for z, (gx, gy) in enumerate(LEVEL_GRIDS):
            for ty in range(gy):
                for tx in range(gx):
                    expected.add(f"{name}/{z}/{_tilename(tx, ty)}")
    assert committed == expected
    assert len(committed) == sum(4 * gx * gy for gx, gy in LEVEL_GRIDS) == 876


@pytest.mark.parametrize("source,filename,colour", SOURCES)
def test_edge_tiles_are_cropped_and_levels_cover_the_raster(
        source, filename, colour):
    """256x256 interior tiles, cropped last column/row, exact extent cover."""
    for z, (gx, gy) in enumerate(LEVEL_GRIDS):
        lw, lh = _level_dims(z)
        widths = set()
        heights = set()
        for ty in range(gy):
            for tx in range(gx):
                data = (TILES / source / str(z) / _tilename(tx, ty)).read_bytes()
                width, height, depth, got_colour, _palette = _png_meta(data)
                assert (width, height) == (
                    min(TILE_PX, lw - tx * TILE_PX),
                    min(TILE_PX, lh - ty * TILE_PX),
                ), f"{source} z{z} tile ({tx}, {ty})"
                assert depth == 8 and got_colour == colour
                widths.add(width)
                heights.add(height)
        # the grid's extent is the level itself — no padding, no gap
        assert (gx - 1) * TILE_PX + min(widths) == lw
        assert (gy - 1) * TILE_PX + min(heights) == lh
        assert max(widths) == max(heights) == TILE_PX  # interior is full size
        assert min(widths) == lw - (gx - 1) * TILE_PX
        assert min(heights) == lh - (gy - 1) * TILE_PX


@pytest.mark.parametrize("source,filename,colour", SOURCES)
def test_pixel_spot_equals_the_nearest_neighbour_rule(source, filename, colour,
                                                      sources):
    """Fixed pixel sample: tile (x, y) := source (x·2^z, y·2^z)."""
    src = sources[source]
    bpp = src["bpp"]
    src_px = src["pixels"]
    for z, tx, ty in ((0, 3, 2), (1, 7, 4), (2, 1, 1), (3, 2, 1)):
        data = (TILES / source / str(z) / _tilename(tx, ty)).read_bytes()
        width, height, _depth, got_colour, palette = _png_meta(data)
        assert got_colour == colour
        assert palette == src["palette"]
        if colour == 3:
            _w, _h, pixels = decode_indexed_png(data, f"{source}/{z}")
        else:
            _w, _h, pixels = decode_rgb8_png(data, f"{source}/{z}")
            assert palette is None  # RGB8 carries no palette
        step = 1 << z
        for px, py in ((0, 0), (width - 1, height - 1), (width // 2, height // 2),
                       (min(5, width - 1), min(9, height - 1))):
            sx = (tx * TILE_PX + px) * step
            sy = (ty * TILE_PX + py) * step
            got = pixels[(py * width + px) * bpp:
                         (py * width + px) * bpp + bpp]
            want = src_px[(sy * GRID_WIDTH + sx) * bpp:
                          (sy * GRID_WIDTH + sx) * bpp + bpp]
            assert got == want, f"{source} z{z} ({tx},{ty}) pixel ({px},{py})"


@pytest.mark.parametrize("source,filename,colour", SOURCES)
def test_palette_survives_every_level(source, filename, colour, sources):
    """§6.8: an indexed source keeps its own palette at every level."""
    src_palette = sources[source]["palette"]
    for z in range(4):
        data = (TILES / source / str(z) / "0_0.png").read_bytes()
        _w, _h, _depth, got_colour, palette = _png_meta(data)
        assert got_colour == colour
        assert palette == src_palette


def test_check_flag_rebuilds_byte_identical():
    """The determinism fixture: ``--check`` exits 0 on the committed tree."""
    result = subprocess.run(
        [sys.executable, str(TOOL), "--check"],
        capture_output=True, text=True, cwd=str(REPO_ROOT), timeout=900)
    assert result.returncode == 0, result.stderr
    assert "rebuild byte-identical" in result.stdout
