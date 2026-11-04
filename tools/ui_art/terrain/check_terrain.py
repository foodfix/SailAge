#!/usr/bin/env python3
"""check_terrain.py — local checker for the W3-C terrain class.

Stdlib-only. Verifies the rendered outputs under ``assets/ui/terrain/``
(the smoke render of ``tools/ui_art/terrain/*.json``) against the §4.8
seam rules and the class's authored pins. This is the slot-local gate;
the normative machine checks live in validator group 13 (slot A) —
the checker mirrors the same contracts so drift is caught before the
governor merge:

1. ring identity — every variant of a terrain kind shares a
   byte-identical outer 1px ring (§4.8.2 seam rule);
2. ring grammar + wrap-continuity — the ring equals the pinned phase-0
   HI lattice ``(3x + 5y) % 16 == 3`` on the kind base; both lattice
   rules are 32-periodic in x and y (96/160 ≡ 0 mod 16), so the shared
   ring is torus-continuous across tile boundaries;
3. dither density ≤ 30% per dithered tile, dither pixels only in the
   kind's {base, HI, LO} steps (one dither family, terrain block only);
4. water kinds are exact flat single-colour fills (§4.7.17 — no dither);
5. port markers: shared silhouette across the 7 owners, pixels only
   PORT_INK / owner fill / FOAM + transparent background;
6. sea_pattern: exactly 2 colours (#ffffff / #000000 mask values — the
   §4.7.17 ×0.82 darkening is render math), Q0 == Q2, Q1 == Q3, equal
   level-1 counts per quadrant, both quadrant lattices 32-periodic
   (mod 4) → torus-safe repeat;
7. shore strips: band = 1px COAST_SEA shadow (inland-most) + 2px FOAM,
   identical thickness on corner arms, transparent outside the
   land-facing band, every derived strip the pixel-exact lossless
   transform of its base (group-13 item 5 relations).

Usage
-----
    python3 tools/ui_art/terrain/check_terrain.py [--assets DIR]

``--assets`` defaults to ``<repo>/assets/ui/terrain`` (the smoke-render
target). Exit 0 = all checks green; exit 1 = named failures.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import zlib
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
ROOT = TOOL_DIR.parent.parent.parent

N = 32
PAT_N = 64

# --------------------------------------------------------------------------
# Terrain block hexes (docs/80-UI-UX.md §4.8.4 — the class's own block)
# --------------------------------------------------------------------------
KIND_PALETTES = {
    "land": {"base": "#7a5c2e", "hi": "#8f6d3a", "lo": "#5e4720"},
    "reef": {"base": "#3d3d3d", "hi": "#565656", "lo": None},
    "polar_ice": {"base": "#c9d6df", "hi": "#e4eef4", "lo": "#9fb4c4"},
}
SEA = "#16446e"
COAST_SEA = "#2f6f9e"
FOAM = "#dff0f4"
PORT_INK = "#101010"
PORT_FILLS = {
    "portugal": "#1a8c4e", "spain": "#b3191f", "england": "#274b8f",
    "holland": "#d97b1e", "ottoman": "#6a3d9a", "italy": "#c9a227",
    "neutral": "#9a9a9a",
}
MASK_HIGH = "#ffffff"  # sea_pattern level 1 (full) — shader mask values
MASK_LOW = "#000000"   # sea_pattern level 0 (×0.82 darkening is render math)

# Authored dither grammar (one terrain family; mirrored by the manifests)
def ring_hi_at(x, y):
    return (3 * x + 5 * y) % 16 == 3


def dither_hi_at(x, y, phase):
    return (3 * x + 5 * y + phase) % 16 == 3


def dither_lo_at(x, y, phase):
    return (5 * x + 3 * y + 7 + phase) % 16 == 11


DITHER_DENSITY_MAX = 0.30  # §4.8.2 pin

# Quadrant lattices of sea_pattern (mod 4 → 32-periodic → torus-safe)
def quad_a_level1(x, y):
    return (3 * x + 5 * y) % 4 == 1


def quad_b_level1(x, y):
    return (5 * x + 3 * y + 2) % 4 == 3


# Shore band: [shadow(inland-most), foam, foam]; corner cut (31-x)+y <= 1
SHORE_SHADOW, SHORE_FOAM = COAST_SEA, FOAM
CORNER_CUT_MAX = 1

# Lossless transforms (governor op table; group-13 item 5 relations)
DERIVE_OPS = {"rot_cw", "rot_180", "rot_ccw", "mirror_x", "mirror_y"}

EXPECTED_IDS = (
    [f"terrain_land_{i}" for i in range(4)]
    + ["terrain_reef_0"]
    + [f"terrain_polar_ice_{i}" for i in range(2)]
    + ["terrain_sea_0", "terrain_coastal_sea_0"]
    + [f"terrain_port_{o}" for o in PORT_FILLS]
    + ["sea_pattern"]
    + ["shore_n", "shore_ne", "shore_e", "shore_se", "shore_s", "shore_sw",
       "shore_w", "shore_nw"]
)


class CheckError(Exception):
    pass


FAILURES: list[str] = []


def fail(msg: str) -> None:
    FAILURES.append(msg)


# --------------------------------------------------------------------------
# Minimal PNG reader (stdlib only; validator reader style: zlib + unfilter)
# --------------------------------------------------------------------------
class PngFormatError(Exception):
    pass


def _unfilter(raw: bytes, width: int, height: int, bpp: int) -> bytearray:
    stride = width * bpp
    if len(raw) != (stride + 1) * height:
        raise PngFormatError(
            f"IDAT inflates to {len(raw)} bytes, expected {(stride + 1) * height}")
    out = bytearray(width * height * bpp)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if ftype == 0:
            pass
        elif ftype == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        else:
            raise PngFormatError(f"row {y}: undefined PNG filter {ftype}")
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return out


def read_png(path: Path) -> list[list[tuple[int, int, int, int]]]:
    """Decode a PNG to RGBA rows. Indexed (type 3, +tRNS) and RGBA (type 6)."""
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise PngFormatError(f"{path.name}: bad signature")
    pos = 8
    header = palette = trns = None
    idat = bytearray()
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        crc = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        if crc != (zlib.crc32(tag + payload) & 0xFFFFFFFF):
            raise PngFormatError(f"{path.name}: bad CRC in {tag!r}")
        pos += 12 + length
        if tag == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif tag == b"PLTE":
            palette = payload
        elif tag == b"tRNS":
            trns = payload
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            break
    if header is None:
        raise PngFormatError(f"{path.name}: no IHDR")
    width, height, depth, colour, comp, filt, interlace = header
    if depth != 8 or comp != 0 or filt != 0 or interlace != 0:
        raise PngFormatError(f"{path.name}: unsupported IHDR {header}")
    raw = zlib.decompress(bytes(idat))
    if colour == 3:
        if palette is None:
            raise PngFormatError(f"{path.name}: indexed without PLTE")
        bpp = 1
        idx = _unfilter(raw, width, height, bpp)
        pal = [(palette[i], palette[i + 1], palette[i + 2])
               for i in range(0, len(palette), 3)]
        alphas = [trns[i] for i in range(len(trns))] if trns else []
        rows = []
        for y in range(height):
            row = []
            for x in range(width):
                i = idx[y * width + x]
                if i >= len(pal):
                    raise PngFormatError(f"{path.name}: palette index {i} oob")
                r, g, b = pal[i]
                row.append((r, g, b, alphas[i] if i < len(alphas) else 255))
            rows.append(row)
        return rows
    if colour == 6:
        bpp = 4
        flat = _unfilter(raw, width, height, bpp)
        rows = []
        for y in range(height):
            base = y * width * 4
            rows.append([tuple(flat[base + x * 4:base + x * 4 + 4])
                         for x in range(width)])
        return rows
    raise PngFormatError(f"{path.name}: colour type {colour} not supported")


def hex_of(px: tuple[int, int, int, int]) -> str:
    return "#%02x%02x%02x" % px[:3]


# --------------------------------------------------------------------------
# Transform ops (mirror of the governor's lossless table)
# --------------------------------------------------------------------------
def transform(px: list[list], op: str) -> list[list]:
    n = len(px)
    if op == "rot_cw":
        return [[px[n - 1 - x][y] for x in range(n)] for y in range(n)]
    if op == "rot_ccw":
        return [[px[x][n - 1 - y] for x in range(n)] for y in range(n)]
    if op == "rot_180":
        return [[px[n - 1 - y][n - 1 - x] for x in range(n)] for y in range(n)]
    if op == "mirror_x":
        return [[px[y][n - 1 - x] for x in range(n)] for y in range(n)]
    if op == "mirror_y":
        return [[px[n - 1 - y][x] for x in range(n)] for y in range(n)]
    raise CheckError(f"unknown derive op {op!r}")


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------
def load_assets(assets: Path) -> dict[str, list[list]]:
    px = {}
    for manifest in sorted(TOOL_DIR.glob("*.json")):
        decl = json.loads(manifest.read_text(encoding="utf-8"))
        path = ROOT / decl["file"]
        if not path.is_file():
            fail(f"{decl['id']}: output missing: {decl['file']}")
            continue
        px[decl["id"]] = read_png(path)
    return px


def check_dithered(name: str, px: list[list], kind: str) -> None:
    pins = KIND_PALETTES[kind]
    allowed = {pins["base"], pins["hi"]}
    if pins["lo"]:
        allowed.add(pins["lo"])
    if len(px) != N or any(len(r) != N for r in px):
        fail(f"{name}: not {N}x{N}")
        return
    bad = {hex_of(p) for row in px for p in row} - allowed
    if bad:
        fail(f"{name}: off-block hexes {sorted(bad)} (terrain block only)")
    # ring identity is checked across variants by the caller; here: grammar
    ring = ([px[0][x] for x in range(N)] + [px[N - 1][x] for x in range(N)]
            + [px[y][0] for y in range(N)] + [px[y][N - 1] for y in range(N)])
    if any(p[3] != 255 for p in ring):
        fail(f"{name}: ring has transparent pixels")
    for x in range(N):
        for y in (0, N - 1):
            want = pins["hi"] if ring_hi_at(x, y) else pins["base"]
            if hex_of(px[y][x]) != want:
                fail(f"{name}: ring grammar mismatch at ({x},{y}) — want {want}")
        for y in range(N):
            for x in (0, N - 1):
                want = pins["hi"] if ring_hi_at(x, y) else pins["base"]
                if hex_of(px[y][x]) != want:
                    fail(f"{name}: ring grammar mismatch at ({x},{y}) — want {want}")
    dither = sum(1 for row in px for p in row if hex_of(p) != pins["base"])
    density = dither / (N * N)
    if density > DITHER_DENSITY_MAX:
        fail(f"{name}: dither density {density:.3f} > {DITHER_DENSITY_MAX} "
             f"({dither}/{N * N})")
    if dither == 0:
        fail(f"{name}: no dither pixels (authored grammar absent)")


def check_ring_identity(group: str, ids: list[str], px: dict) -> None:
    rings = {}
    for name in ids:
        p = px[name]
        rings[name] = (
            [p[0][x] for x in range(N)] + [p[N - 1][x] for x in range(N)]
            + [p[y][0] for y in range(N)] + [p[y][N - 1] for y in range(N)])
    first = rings[ids[0]]
    for name in ids[1:]:
        if rings[name] != first:
            fail(f"{group}: ring mismatch between {ids[0]} and {name} "
                 "(§4.8.2 seam rule)")


def check_flat(name: str, px: list[list], hexcolor: str) -> None:
    if len(px) != N or any(len(r) != N for r in px):
        fail(f"{name}: not {N}x{N}")
        return
    off = {hex_of(p) for row in px for p in row if p[3] != 0} - {hexcolor}
    if off or any(p[3] == 0 for row in px for p in row):
        fail(f"{name}: not the exact flat {hexcolor} fill "
             f"(off={sorted(off)}; water kinds carry no dither, §4.7.17)")


def check_port(name: str, px: list[list], owner: str) -> tuple | None:
    if len(px) != N or any(len(r) != N for r in px):
        fail(f"{name}: not {N}x{N}")
        return None
    fill = PORT_FILLS[owner]
    roles = []
    seen = {"ink": 0, "fill": 0, "foam": 0, "clear": 0}
    for y in range(N):
        rrow = []
        for x in range(N):
            p = px[y][x]
            if p[3] == 0:
                rrow.append("clear")
                seen["clear"] += 1
            elif hex_of(p) == PORT_INK:
                rrow.append("ink")
                seen["ink"] += 1
            elif hex_of(p) == fill:
                rrow.append("fill")
                seen["fill"] += 1
            elif hex_of(p) == FOAM:
                rrow.append("foam")
                seen["foam"] += 1
            else:
                fail(f"{name}: off-block hex {hex_of(p)} at ({x},{y})")
                return None
        roles.append(rrow)
    for role in ("ink", "fill", "foam"):
        if seen[role] == 0:
            fail(f"{name}: silhouette missing {role} pixels")
    if seen["clear"] == 0:
        fail(f"{name}: no transparent background (overlay sprite)")
    return roles


def check_sea_pattern(px: list[list]) -> None:
    if len(px) != PAT_N or any(len(r) != PAT_N for r in px):
        fail("sea_pattern: not 64x64")
        return
    colors = {hex_of(p) for row in px for p in row}
    if colors != {MASK_HIGH, MASK_LOW}:
        fail(f"sea_pattern: exactly two mask colours required, got {sorted(colors)}")
        return
    # Q0 == Q2, Q1 == Q3 (opposite quadrants identical)
    for y in range(PAT_N // 2):
        for x in range(PAT_N):
            if px[y][x] != px[(y + PAT_N // 2) % PAT_N][x]:
                fail(f"sea_pattern: Q{0 if x < 32 else 1} != Q"
                     f"{2 if x < 32 else 3} at ({x},{y})")
                return
    counts = []
    for qi, (x0, y0, rule) in enumerate((
            (0, 0, quad_a_level1), (32, 0, quad_b_level1),
            (0, 32, quad_a_level1), (32, 32, quad_b_level1))):
        level1 = 0
        for y in range(32):
            for x in range(32):
                is_high = hex_of(px[y0 + y][x0 + x]) == MASK_HIGH
                if is_high != rule(x, y):
                    fail(f"sea_pattern: Q{qi} lattice mismatch at "
                         f"({x},{y}) (torus-safety pin)")
                    return
                if is_high:
                    level1 += 1
        counts.append(level1)
    if len(set(counts)) != 1:
        fail(f"sea_pattern: level-1 counts differ across quadrants: {counts}")


def shore_expected_n() -> list[list[str | None]]:
    grid = []
    for y in range(N):
        if y == 0:
            grid.append([SHORE_SHADOW] * N)
        elif y in (1, 2):
            grid.append([SHORE_FOAM] * N)
        else:
            grid.append([None] * N)
    return grid


def shore_expected_ne() -> list[list[str | None]]:
    grid = [[None] * N for _ in range(N)]
    for y in range(N):
        if y == 0:
            grid[y] = [SHORE_SHADOW] * N
        elif y in (1, 2):
            grid[y] = [SHORE_FOAM] * N
    for y in range(3, N):
        grid[y][31] = SHORE_SHADOW
        grid[y][29] = SHORE_FOAM
        grid[y][30] = SHORE_FOAM
    for y in range(N):
        for x in range(N):
            if (N - 1 - x) + y <= CORNER_CUT_MAX:
                grid[y][x] = None
    return grid


LAND_FACING = {  # edge tests for "transparent outside the land-facing band"
    "n": lambda x, y: y <= 2,
    "s": lambda x, y: y >= N - 3,
    "w": lambda x, y: x <= 2,
    "e": lambda x, y: x >= N - 3,
    "ne": lambda x, y: y <= 2 or x >= N - 3,
    "se": lambda x, y: y >= N - 3 or x >= N - 3,
    "nw": lambda x, y: y <= 2 or x <= 2,
    "sw": lambda x, y: y >= N - 3 or x <= 2,
}


def check_shore_authored(name: str, px: list[list], expected) -> None:
    if len(px) != N or any(len(r) != N for r in px):
        fail(f"{name}: not {N}x{N}")
        return
    for y in range(N):
        for x in range(N):
            p = px[y][x]
            want = expected[y][x]
            if want is None:
                if p[3] != 0:
                    fail(f"{name}: not transparent at ({x},{y}) "
                         "(foam only on the land-facing band)")
            elif p[3] == 0 or hex_of(p) != want:
                fail(f"{name}: want {want} at ({x},{y}), got "
                     f"{hex_of(p) if p[3] else 'transparent'}")


def check_shore_band(name: str, px: list[list], code: str) -> None:
    """Foam thickness equality: 2px foam + 1px shadow on each land-facing arm."""
    band = [SHORE_SHADOW, SHORE_FOAM, SHORE_FOAM]
    opaque = lambda p: p[3] != 0

    def col_profile(x, ys):
        return [hex_of(px[y][x]) if opaque(px[y][x]) else None for y in ys]

    def row_profile(y, xs):
        return [hex_of(px[y][x]) if opaque(px[y][x]) else None for x in xs]

    arms = {
        "n": [("col", 8, range(0, 4), band + [None])],
        "s": [("col", 8, range(N - 4, N), [None] + band[::-1])],
        "w": [("row", 8, range(0, 4), band + [None])],
        "e": [("row", 8, range(N - 4, N), [None] + band[::-1])],
        "ne": [("col", 8, range(0, 4), band + [None]),
               ("row", 12, range(N - 4, N), [None] + band[::-1])],
        "nw": [("col", 8, range(0, 4), band + [None]),
               ("row", 12, range(0, 4), band + [None])],
        "se": [("col", 8, range(N - 4, N), [None] + band[::-1]),
               ("row", 12, range(N - 4, N), [None] + band[::-1])],
        "sw": [("col", 8, range(N - 4, N), [None] + band[::-1]),
               ("row", 12, range(0, 4), band + [None])],
    }
    for kind, specs in arms.items():
        if code != kind:
            continue
        for axis, at, span, want in specs:
            got = (col_profile(at, list(span)) if axis == "col"
                   else row_profile(at, list(span)))
            if got != want:
                fail(f"{name}: {kind} arm band {got} != pinned 2px FOAM + "
                     f"1px COAST_SEA shadow {want}")
    # transparent outside every land-facing band
    inside = LAND_FACING[code]
    for y in range(N):
        for x in range(N):
            if px[y][x][3] != 0 and not inside(x, y):
                fail(f"{name}: opaque pixel at ({x},{y}) outside the "
                     f"land-facing band ({code})")
                return


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--assets", metavar="DIR",
                        default=str(ROOT / "assets" / "ui" / "terrain"),
                        help="smoke-render target (default assets/ui/terrain)")
    _assets_dir = Path(parser.parse_args(argv).assets)
    # the reader resolves output paths from the manifests; --assets is the
    # expected smoke-render root, kept for explicitness

    manifests = {}
    for path in sorted(TOOL_DIR.glob("*.json")):
        decl = json.loads(path.read_text(encoding="utf-8"))
        manifests[decl["id"]] = decl
    missing = [i for i in EXPECTED_IDS if i not in manifests]
    extra = [i for i in manifests if i not in EXPECTED_IDS]
    if missing:
        fail(f"manifest inventory: missing {missing}")
    if extra:
        fail(f"manifest inventory: unexpected {extra}")

    try:
        px = load_assets(_assets_dir)
    except PngFormatError as exc:
        fail(str(exc))
        px = {}

    # dithered kinds
    for kind, ids in (("land", [f"terrain_land_{i}" for i in range(4)]),
                      ("reef", ["terrain_reef_0"]),
                      ("polar_ice", [f"terrain_polar_ice_{i}" for i in range(2)])):
        if not all(i in px for i in ids):
            continue
        for name in ids:
            check_dithered(name, px[name], kind)
        check_ring_identity(kind, ids, px)

    if "terrain_sea_0" in px:
        check_flat("terrain_sea_0", px["terrain_sea_0"], SEA)
    if "terrain_coastal_sea_0" in px:
        check_flat("terrain_coastal_sea_0", px["terrain_coastal_sea_0"],
                   COAST_SEA)

    port_roles = {}
    for owner, fill in PORT_FILLS.items():
        name = f"terrain_port_{owner}"
        if name in px:
            port_roles[name] = check_port(name, px[name], owner)
    if len(port_roles) == len(PORT_FILLS):
        first_name = next(iter(port_roles))
        first = port_roles[first_name]
        for name, roles in port_roles.items():
            if roles is not None and roles != first:
                fail(f"{name}: silhouette differs from {first_name} "
                     "(shared harbour silhouette)")

    if "sea_pattern" in px:
        check_sea_pattern(px["sea_pattern"])

    # shores: authored pins + derived transform relations
    expected = {"shore_n": shore_expected_n(), "shore_ne": shore_expected_ne()}
    for name, exp in expected.items():
        if name in px:
            check_shore_authored(name, px[name], exp)
    for name, decl in manifests.items():
        if decl.get("kind") != "shore" or "derive" not in decl:
            continue
        base_id = decl["derive"]["base"]
        op = decl["derive"]["op"]
        if op not in DERIVE_OPS:
            fail(f"{name}: unknown derive op {op!r}")
            continue
        if name not in px or base_id not in px:
            continue
        want = transform(px[base_id], op)
        if px[name] != want:
            fail(f"{name}: not the pixel-exact {op} of {base_id} "
                 "(group-13 item 5 relation)")
        check_shore_band(name, px[name], name.removeprefix("shore_"))
    for name in ("shore_n", "shore_ne"):
        if name in px:
            check_shore_band(name, px[name], name.removeprefix("shore_"))

    # colour budgets (32×32 → ≤ 20; the 64×64 mask pins exactly 2 above)
    for name, p in px.items():
        if len(p) == PAT_N:
            continue
        distinct = {(r, g, b, a) for row in p for r, g, b, a in row}
        if len(distinct) > 20:
            fail(f"{name}: {len(distinct)} distinct colours > 20 (32px cap)")

    if FAILURES:
        print(f"check_terrain: FAIL — {len(FAILURES)} problem(s)")
        for line in FAILURES:
            print(f"  - {line}")
        return 1
    n_sprites = len(px)
    print(f"check_terrain: OK — {n_sprites} sprites green "
          "(rings, dither ≤ 30%, quadrant rules, shore bands, transforms)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
