#!/usr/bin/env python3
"""W3-A manifest generator: chrome tiles + the 129 semantic icons.

Emits the declarative string-map manifests consumed by the W3-B governor
(`tools/build_ui_art.py`, rendering through the vendored YoYoPixel engine
`tools/yoyopixel/render.js`):

  tools/ui_art/chrome/*.json   15 nine-patch source tiles (16x16, A.1)
  tools/ui_art/icons/*.json   129 semantic icons (32x32, A.2)

Stdlib-only, deterministic, byte-stable: no clock, no randomness, no set
iteration on the output path. A re-run must be byte-identical — `--check`
regenerates into a temp dir and compares every committed file.

Sprite contracts are pinned by the master prompt + docs:
  - 80-* section 4.8: style guide, icon-block hex tables, budgets, seam
    rules (edge tiles torus-safe along the repeating axis).
  - IMPLEMENT-Phase10.md Appendix A.1/A.2: the id inventories.
  - heading8->dir table (80-* 4.8.6): arrows author `n` + `ne`; the other
    six directions are lossless transforms declared in `derive` (and their
    rows are emitted pre-transformed, so plain `node render.js` renders
    every declaration standalone; the governor may re-derive either way).

Palette discipline (80-* 4.8.4): every non-transparent hex below is an
`icon`-block constant; the PALETTE table cites the block name at each char.
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

ICONS_DIR = Path(__file__).resolve().parent
REPO_ROOT = ICONS_DIR.parents[2]

# ---------------------------------------------------------------------------
# The icon block (80-* section 4.8.4) — every char used by any sprite below.
# ---------------------------------------------------------------------------

PALETTE = {
    ".": "transparent",
    "o": "#465468",  # PANEL_LINE  — outline / mid grey
    "O": "#5e7086",  # ICON_LINE_HI — lit-outline step
    "b": "#1c2230",  # PANEL_BG    — recess fill
    "B": "#121724",  # ICON_BG_LO  — deep shadow step
    "m": "#232c3e",  # ICON_MID    — metal/wood mid-tone base
    "t": "#e8e6df",  # TEXT        — light ink / lit surface (wind arrows)
    "h": "#f7f5ee",  # ICON_HI     — specular highlight
    "a": "#d9a441",  # ACCENT      — gold
    "A": "#f0c46a",  # ACCENT_HI   — gold highlight
    "l": "#a87a28",  # ACCENT_LO   — gold shadow
    "g": "#4e9e4e",  # GOOD        — food tint / positive
    "G": "#74c26e",  # GOOD_HI     — good highlight
    "r": "#b3341f",  # BAD         — danger / pirate
    "R": "#d4573c",  # BAD_HI      — bad highlight
    "c": "#2f6f9e",  # COAST_SEA   — current arrows / water & glass
    "n": "#9a9a9a",  # ICON_NEUTRAL — neutral flag fill
    "p": "#1a8c4e",  # FLAG_PORTUGAL
    "s": "#b3191f",  # FLAG_SPAIN
    "e": "#274b8f",  # FLAG_ENGLAND
    "d": "#d97b1e",  # FLAG_HOLLAND
    "u": "#6a3d9a",  # FLAG_OTTOMAN
    "i": "#c9a227",  # FLAG_ITALY
}

# ---------------------------------------------------------------------------
# Canvas: a char grid + the drawing primitives every sprite is built from.
# ---------------------------------------------------------------------------


class Canvas:
    def __init__(self, w: int, h: int):
        self.w = w
        self.h = h
        self.g = [["."] * w for _ in range(h)]

    def put(self, x: int, y: int, ch: str) -> None:
        if 0 <= x < self.w and 0 <= y < self.h:
            self.g[y][x] = ch

    def get(self, x: int, y: int) -> str:
        if 0 <= x < self.w and 0 <= y < self.h:
            return self.g[y][x]
        return "."

    def rect(self, x0: int, y0: int, x1: int, y1: int, ch: str) -> None:
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.put(x, y, ch)

    def frame(self, x0: int, y0: int, x1: int, y1: int, ch: str) -> None:
        self.rect(x0, y0, x1, y0, ch)
        self.rect(x0, y1, x1, y1, ch)
        self.rect(x0, y0, x0, y1, ch)
        self.rect(x1, y0, x1, y1, ch)

    def hline(self, x0: int, x1: int, y: int, ch: str) -> None:
        for x in range(min(x0, x1), max(x0, x1) + 1):
            self.put(x, y, ch)

    def vline(self, x: int, y0: int, y1: int, ch: str) -> None:
        for y in range(min(y0, y1), max(y0, y1) + 1):
            self.put(x, y, ch)

    def line(self, x0: int, y0: int, x1: int, y1: int, ch: str,
             pen: int = 1) -> None:
        """Bresenham line with a square pen (`pen` x `pen`, anchored top-left)."""
        dx = abs(x1 - x0)
        dy = abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx - dy
        x, y = x0, y0
        while True:
            for oy in range(pen):
                for ox in range(pen):
                    self.put(x + ox, y + oy, ch)
            if x == x1 and y == y1:
                break
            e2 = 2 * err
            if e2 > -dy:
                err -= dy
                x += sx
            if e2 < dx:
                err += dx
                y += sy

    def disc(self, cx: int, cy: int, r: int, ch: str) -> None:
        for y in range(cy - r - 1, cy + r + 2):
            for x in range(cx - r - 1, cx + r + 2):
                dx = x - cx
                dy = y - cy
                if dx * dx + dy * dy <= r * r + r * 0.5:
                    self.put(x, y, ch)

    def ring(self, cx: int, cy: int, r: int, t: int, ch: str) -> None:
        for y in range(cy - r - 1, cy + r + 2):
            for x in range(cx - r - 1, cx + r + 2):
                d2 = (x - cx) ** 2 + (y - cy) ** 2
                if d2 <= r * r + r * 0.5 and d2 > (r - t) ** 2 + (r - t) * 0.5:
                    self.put(x, y, ch)

    def tri(self, p0, p1, p2, ch: str) -> None:
        """Filled triangle (integer barycentric over the bounding box)."""
        (x0, y0), (x1, y1), (x2, y2) = p0, p1, p2
        minx, maxx = min(x0, x1, x2), max(x0, x1, x2)
        miny, maxy = min(y0, y1, y2), max(y0, y1, y2)
        den = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
        if den == 0:
            return
        for y in range(miny, maxy + 1):
            for x in range(minx, maxx + 1):
                w0 = ((y1 - y2) * (x - x2) + (x2 - x1) * (y - y2)) / den
                w1 = ((y2 - y0) * (x - x2) + (x0 - x2) * (y - y2)) / den
                w2 = 1 - w0 - w1
                if w0 >= -0.01 and w1 >= -0.01 and w2 >= -0.01:
                    self.put(x, y, ch)

    def erase_if(self, predicate) -> None:
        for y in range(self.h):
            for x in range(self.w):
                if self.g[y][x] != "." and predicate(x, y):
                    self.g[y][x] = "."

    def outline(self, ch: str = "o") -> None:
        """1px silhouette outline (erosion): filled pixels touching the
        transparent background become `ch` (front-facing icons, 80-* 4.8)."""
        edge = []
        for y in range(self.h):
            for x in range(self.w):
                if self.g[y][x] == ".":
                    continue
                if (self.get(x - 1, y) == "." or self.get(x + 1, y) == "."
                        or self.get(x, y - 1) == "." or self.get(x, y + 1) == "."):
                    edge.append((x, y))
        for x, y in edge:
            self.g[y][x] = ch

    def hilo(self, hi: str, lo: str) -> None:
        """NW-light pass: interior pixels with a transparent top/left
        neighbour get `hi`; transparent bottom/right get `lo` (80-* 4.8:
        light from NW, shadow bottom-right)."""
        tops, bots = [], []
        for y in range(self.h):
            for x in range(self.w):
                if self.g[y][x] == ".":
                    continue
                if self.get(x - 1, y) == "." or self.get(x, y - 1) == ".":
                    tops.append((x, y))
                if self.get(x + 1, y) == "." or self.get(x, y + 1) == ".":
                    bots.append((x, y))
        for x, y in tops:
            self.g[y][x] = hi
        for x, y in bots:
            self.g[y][x] = lo

    def rows(self) -> list[str]:
        return ["".join(row) for row in self.g]


def used_palette(canvas: Canvas) -> dict[str, str]:
    """Only the chars the sprite actually draws (clean manifest diffs)."""
    chars = sorted({ch for row in canvas.rows() for ch in row})
    return {ch: PALETTE[ch] for ch in chars}


def declaration(sprite_id: str, file: str, canvas: Canvas) -> dict:
    w = canvas.w
    return {
        "id": sprite_id,
        "file": file,
        "width": w,
        "height": canvas.h,
        "mode": "string-map",
        "png": "indexed",
        "palette": used_palette(canvas),
        "rows": canvas.rows(),
    }


def derived_declaration(sprite_id: str, file: str, base_id: str, op: str,
                        base_rows: list[str], w: int, h: int) -> dict:
    """A derived sprite: carries the pre-transformed rows (standalone
    renderable) plus the `derive` provenance the governor/validator use."""
    decl = declaration(sprite_id, file, _grid_of(base_rows, w, h, op))
    order = ["id", "file", "width", "height", "mode", "png", "derive",
             "palette", "rows"]
    decl["derive"] = {"from": base_id, "op": op}
    return {key: decl[key] for key in order}


# --- pinned lossless transforms (80-* 4.8.6 heading8 table; square grids) ---

def op_mirror_x(rows: list[str]) -> list[str]:
    return [row[::-1] for row in rows]


def op_mirror_y(rows: list[str]) -> list[str]:
    return rows[::-1]


def op_rot_180(rows: list[str]) -> list[str]:
    return [row[::-1] for row in rows[::-1]]


def op_rot_cw(rows: list[str]) -> list[str]:
    """90 deg clockwise: pixel (x, y) -> (N-1-y, x)."""
    n = len(rows)
    return ["".join(rows[n - 1 - x][y] for x in range(n)) for y in range(n)]


def op_rot_ccw(rows: list[str]) -> list[str]:
    """90 deg counter-clockwise: pixel (x, y) -> (y, N-1-x)."""
    n = len(rows)
    return ["".join(rows[x][n - 1 - y] for x in range(n)) for y in range(n)]


def op_rot180_mirror_x(rows: list[str]) -> list[str]:
    return op_mirror_x(op_rot_180(rows))


OPS = {
    "mirror_x": op_mirror_x,
    "mirror_y": op_mirror_y,
    "rot_180": op_rot_180,
    "rot_cw": op_rot_cw,
    "rot_ccw": op_rot_ccw,
    "rot180_mirror_x": op_rot180_mirror_x,
}


def _grid_of(base_rows: list[str], w: int, h: int, op: str) -> Canvas:
    c = Canvas(w, h)
    out = OPS[op](base_rows)
    for y, row in enumerate(out):
        for x, ch in enumerate(row):
            c.put(x, y, ch)
    return c


# ---------------------------------------------------------------------------
# Chrome tiles — 16x16 nine-patch sources (A.1).
# Panel/button/field frames: PANEL_BG fill + PANEL_LINE border (4.9 pins);
# button_focus border ACCENT; bar caps PANEL_LINE, bar line ICON_MID.
# ---------------------------------------------------------------------------


def _corner(border: str, border_w: int) -> Canvas:
    """Top-left corner tile: border on top+left, radius-4 outer rounding."""
    c = Canvas(16, 16)
    for y in range(16):
        for x in range(16):
            in_arc_zone = x < 4 and y < 4
            d2 = (4 - x) ** 2 + (4 - y) ** 2
            if in_arc_zone and d2 > 16:
                continue  # outside the rounded corner: transparent
            if in_arc_zone and d2 > 4:
                c.put(x, y, border)  # border follows the rounding
            elif x < border_w or y < border_w:
                c.put(x, y, border)
            else:
                c.put(x, y, "b")
    return c


def _edge(border: str, border_w: int) -> Canvas:
    """Top-edge tile: column-uniform (torus-safe along the horizontal
    repeat axis, 80-* 4.8 seam rule); rotates cleanly onto side edges."""
    c = Canvas(16, 16)
    c.rect(0, 0, 15, border_w - 1, border)
    if border_w == 2:
        c.rect(0, border_w, 15, border_w, "B")  # recess step below the border
    c.rect(0, border_w + (1 if border_w == 2 else 0), 15, 15, "b")
    return c


def _fill(ch: str = "b") -> Canvas:
    c = Canvas(16, 16)
    c.rect(0, 0, 15, 15, ch)
    return c


def chrome_declarations() -> list[dict]:
    out = []
    sets = (
        ("panel", "o", 2),
        ("button", "o", 2),
        ("button_focus", "a", 2),
        ("field", "o", 1),
    )
    for name, border, bw in sets:
        tiles = (
            ("corner", _corner(border, bw)),
            ("edge", _edge(border, bw)),
            ("fill", _fill("b")),
        )
        for tile, canvas in tiles:
            out.append(declaration(
                f"{name}_{tile}",
                f"assets/ui/chrome/{name}_{tile}.png",
                canvas,
            ))
    # bar: left/right caps (radius-4 rounded outer corners, like the panel
    # corners) + line tile.
    left = Canvas(16, 16)
    left.rect(0, 0, 15, 15, "o")
    left.erase_if(lambda x, y: (
        (x < 4 and y < 4 and (4 - x) ** 2 + (4 - y) ** 2 > 16)
        or (x < 4 and y > 11 and (4 - x) ** 2 + (y - 11) ** 2 > 16)))
    right_c = Canvas(16, 16)
    for y, row in enumerate(op_mirror_x(left.rows())):
        for x, ch in enumerate(row):
            right_c.put(x, y, ch)
    line = Canvas(16, 16)
    line.rect(0, 0, 15, 15, "m")  # bar line: ICON_MID tube, row-uniform
    out.append(declaration("bar_left", "assets/ui/chrome/bar_left.png", left))
    out.append(declaration("bar_right", "assets/ui/chrome/bar_right.png", right_c))
    out.append(declaration("bar_line", "assets/ui/chrome/bar_line.png", line))
    return out


# ---------------------------------------------------------------------------
# Icons (A.2, 32x32). One author function per sprite; sparse marks carry no
# outline, object icons get the 1px PANEL_LINE silhouette outline.
# Ornate-sample helpers (post-Phase-10 sample batch): sparkle stamps and
# checker dither fills — deterministic, palette-block-bound like everything
# above (no new hexes; helpers only rearrange the icon block).
# ---------------------------------------------------------------------------


def _sparkle(c: Canvas, cx: int, cy: int, ch: str, wide: bool = False) -> None:
    """Cross-sparkle stamp: a 3x3 plus, `wide` stretches the arms to 4px."""
    c.put(cx, cy, ch)
    c.put(cx, cy - 1, ch)
    c.put(cx, cy + 1, ch)
    c.put(cx - 1, cy, ch)
    c.put(cx + 1, cy, ch)
    if wide:
        c.put(cx - 2, cy, ch)
        c.put(cx + 2, cy, ch)


def _checker(c: Canvas, x0: int, y0: int, x1: int, y1: int, ch: str,
             phase: int = 0) -> None:
    """50% checkerboard dither fill on the (x+y+phase)-even pixels."""
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if (x + y + phase) % 2 == 0:
                c.put(x, y, ch)


def _arrow_n(ch: str) -> Canvas:
    c = Canvas(32, 32)
    c.line(9, 13, 15, 7, ch, 2)
    c.line(16, 7, 22, 13, ch, 2)
    c.rect(15, 6, 17, 10, ch)   # apex junction
    c.rect(15, 9, 16, 25, ch)
    return c


def _arrow_ne(ch: str) -> Canvas:
    c = Canvas(32, 32)
    c.line(10, 21, 21, 10, ch, 2)
    c.line(21, 10, 21, 17, ch, 2)
    c.line(21, 10, 14, 10, ch, 2)
    return c


def arrow_declarations(prefix: str, ch: str) -> list[dict]:
    """The 8-direction set: authored `n` + `ne`, six lossless derives."""
    n = _arrow_n(ch).rows()
    ne = _arrow_ne(ch).rows()
    plan = (
        ("n", None, None),
        ("ne", None, None),
        ("e", "n", "rot_cw"),
        ("s", "n", "rot_180"),
        ("w", "n", "rot_ccw"),
        ("nw", "ne", "mirror_x"),
        ("se", "ne", "mirror_y"),
        ("sw", "ne", "rot_180"),
    )
    out = []
    for dir_id, base, op in plan:
        file = f"assets/ui/icons/{prefix}_{dir_id}.png"
        if base is None:
            rows = n if dir_id == "n" else ne
            out.append(declaration(f"{prefix}_{dir_id}", file,
                                   _plain(rows, ch)))
        else:
            base_rows = n if base == "n" else ne
            out.append(derived_declaration(f"{prefix}_{dir_id}", file,
                                           f"{prefix}_{base}", op, base_rows,
                                           32, 32))
    return out


def _plain(rows: list[str], ch: str) -> Canvas:
    c = Canvas(32, 32)
    for y, row in enumerate(rows):
        for x, char in enumerate(row):
            c.put(x, y, char)
    return c


# --- HUD resources (5) -------------------------------------------------------


def icon_coin() -> Canvas:
    c = Canvas(32, 32)
    c.disc(16, 16, 11, "a")
    for y in range(32):
        for x in range(32):
            d2 = (x - 16) ** 2 + (y - 16) ** 2
            if d2 <= 121:
                if x + y - 32 < -5:
                    c.put(x, y, "A")
                elif x + y - 32 > 5:
                    c.put(x, y, "l")
    c.ring(16, 16, 6, 1, "l")
    c.rect(11, 10, 12, 11, "h")
    c.outline()
    return c


def icon_crew() -> Canvas:
    c = Canvas(32, 32)
    c.disc(16, 10, 5, "t")
    c.rect(8, 18, 23, 27, "t")
    c.rect(10, 17, 21, 19, "t")
    c.put(12, 7, "h")
    c.put(13, 6, "h")
    c.put(14, 7, "h")
    c.outline()
    return c


def icon_provisions() -> Canvas:
    c = Canvas(32, 32)
    for y in range(7, 28):
        bulge = 6 + round(2.2 * (1 - ((y - 17) / 11) ** 2))
        c.rect(16 - bulge, y, 16 + bulge, y, "m")
    c.rect(12, 7, 20, 9, "B")  # top opening
    c.frame(12, 7, 20, 9, "o")
    c.vline(12, 10, 27, "B")
    c.vline(16, 10, 27, "B")
    c.vline(20, 10, 27, "B")
    c.hline(9, 23, 12, "o")   # hoops
    c.hline(7, 25, 22, "o")
    c.vline(10, 10, 20, "O")  # NW light on the left stave
    c.outline()
    return c


def icon_morale() -> Canvas:
    c = Canvas(32, 32)
    c.vline(10, 5, 28, "o")
    c.put(10, 4, "a")
    c.tri((11, 6), (27, 12), (11, 18), "a")
    c.tri((11, 6), (19, 9), (11, 12), "A")
    c.outline()
    return c


def icon_durability() -> Canvas:
    c = Canvas(32, 32)
    c.rect(8, 6, 23, 22, "m")
    for i, (x0, x1) in enumerate(((10, 21), (12, 19), (14, 17))):
        c.rect(x0, 23 + i, x1, 23 + i, "m")
    c.hilo("O", "B")
    c.rect(11, 13, 20, 15, "t")
    c.outline()
    return c


# --- nav / weather (5) --------------------------------------------------------


def icon_compass() -> Canvas:
    """Engraved compass: solid brass bezel (ACCENT_HI edge, ACCENT_LO bore)
    with rivet dots, an 8-point rose with lit/shadow facets, a red needle
    tip and a dithered glass-glare band across the face."""
    c = Canvas(32, 32)
    c.disc(16, 16, 13, "a")                     # brass bezel body
    c.disc(16, 16, 10, "b")                     # face recess
    c.ring(16, 16, 13, 1, "A")                  # bezel outer edge
    c.ring(16, 16, 11, 1, "l")                  # bezel bore edge
    for rx, ry in ((8, 7), (24, 7), (8, 25), (24, 25)):
        c.put(rx, ry, "l")                      # rivet dots
    # 8-point rose: long cardinal points, short diagonal points
    for d in range(3, 10):
        c.put(16, 16 - d, "m"); c.put(15, 16 - d, "h")   # N (W facet lit)
        c.put(16 + d, 16, "m"); c.put(16 + d, 15, "h")   # E (N facet lit)
        c.put(16, 16 + d, "m"); c.put(15, 16 + d, "h")   # S (W facet lit)
        c.put(16 - d, 16, "m"); c.put(16 - d, 15, "h")   # W (N facet lit)
    for d in range(3, 7):
        c.put(16 + d, 16 - d, "m"); c.put(15 + d, 16 - d, "h")   # NE
        c.put(16 + d, 16 + d, "m"); c.put(15 + d, 16 + d, "h")   # SE
        c.put(16 - d, 16 + d, "m"); c.put(16 - d, 15 + d, "h")   # SW
        c.put(16 - d, 16 - d, "m"); c.put(16 - d, 15 - d, "h")   # NW
    c.rect(15, 7, 16, 8, "r")                   # red needle tip (north)
    # glass glare: 2px diagonal band at 50% dither over the face
    for y in range(32):
        for x in range(32):
            if x - y in (-8, -7) and (x + y) % 2 == 0:
                if (x - 16) ** 2 + (y - 16) ** 2 <= 100:
                    c.put(x, y, "h")
    # hub
    c.disc(16, 16, 2, "o")
    c.put(15, 15, "O"); c.put(16, 15, "O")
    c.outline()
    return c


def icon_calm() -> Canvas:
    c = Canvas(32, 32)
    for base, amp in ((12, 2), (18, 2), (24, 1)):
        for x in range(4, 28):
            c.put(x, base + round(amp * _sin(x)), "c")
    return c


def _sin(x: int) -> float:
    # deterministic coarse sine via a fixed sample table (no floats drift)
    import math
    return math.sin(x / 3.6)


def icon_fair() -> Canvas:
    c = Canvas(32, 32)
    for ax, ay in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)):
        for r in range(10, 14):
            c.put(16 + ax * r, 14 + ay * r, "A")
    c.disc(16, 14, 7, "a")
    c.put(12, 10, "h")
    c.put(13, 10, "h")
    c.put(12, 11, "h")
    return c


def icon_strong() -> Canvas:
    c = Canvas(32, 32)
    c.hline(5, 22, 10, "t")
    c.put(23, 9, "t")
    c.put(24, 8, "t")
    c.hline(4, 24, 17, "t")
    c.put(25, 18, "t")
    c.put(26, 19, "t")
    c.hline(8, 16, 24, "O")
    return c


def icon_storm() -> Canvas:
    c = Canvas(32, 32)
    c.disc(12, 12, 6, "m")
    c.disc(19, 11, 7, "m")
    c.disc(25, 14, 5, "m")
    c.rect(10, 13, 26, 17, "m")
    c.put(9, 10, "O")
    c.put(10, 9, "O")
    c.put(16, 9, "O")
    c.line(17, 16, 14, 21, "a", 2)
    c.line(14, 21, 17, 21, "a", 2)
    c.line(17, 21, 14, 27, "a", 2)
    return c


# --- battle (8) ---------------------------------------------------------------


def icon_cannon() -> Canvas:
    c = Canvas(32, 32)
    c.rect(4, 9, 21, 17, "m")
    c.disc(22, 13, 4, "m")
    c.rect(3, 11, 5, 15, "B")   # muzzle bore
    c.frame(3, 11, 5, 15, "o")
    c.hline(6, 20, 10, "O")
    c.ring(13, 23, 5, 2, "o")
    c.line(9, 23, 17, 23, "o")
    c.line(13, 19, 13, 27, "o")
    c.disc(13, 23, 2, "m")
    c.outline()
    return c


def icon_shot_round() -> Canvas:
    c = Canvas(32, 32)
    c.disc(16, 16, 9, "m")
    for y in range(32):
        for x in range(32):
            d2 = (x - 16) ** 2 + (y - 16) ** 2
            if d2 <= 81:
                if x + y - 32 < -4:
                    c.put(x, y, "O")
                elif x + y - 32 > 4:
                    c.put(x, y, "B")
    c.rect(12, 11, 13, 12, "h")
    c.outline()
    return c


def icon_shot_chain() -> Canvas:
    c = Canvas(32, 32)
    c.ring(11, 11, 6, 2, "o")
    c.ring(21, 21, 6, 2, "o")
    c.line(14, 14, 17, 17, "o", 2)
    c.put(8, 6, "O")
    c.put(9, 7, "O")
    c.put(18, 16, "O")
    c.put(19, 17, "O")
    return c


def icon_shot_armor_piercing() -> Canvas:
    c = Canvas(32, 32)
    c.tri((16, 4), (12, 14), (20, 14), "A")
    c.rect(13, 14, 18, 24, "m")
    c.vline(13, 14, 23, "O")
    c.rect(12, 24, 19, 27, "o")
    c.outline()
    return c


def icon_shot_grape() -> Canvas:
    c = Canvas(32, 32)
    for cx, cy in ((11, 13), (16, 10), (21, 13), (13, 17), (19, 17)):
        c.disc(cx, cy, 2, "m")
    c.put(10, 12, "h")
    c.put(15, 9, "h")
    for y in range(19, 27):
        grow = (y - 19) // 3
        c.rect(9 - grow, y, 22 + grow, y, "m")
    c.hline(8, 23, 19, "o")
    c.outline()
    return c


def icon_hook() -> Canvas:
    c = Canvas(32, 32)
    c.rect(15, 4, 16, 12, "o")
    c.ring(16, 14, 2, 1, "o")
    c.rect(15, 15, 16, 20, "o")
    c.hline(10, 21, 20, "o")
    for sx in (10, 21):
        c.line(sx, 20, sx - 2, 26, "o", 2)
        c.line(sx - 2, 26, sx + 1, 28, "o", 2)
    c.put(12, 27, "t")
    c.put(19, 27, "t")
    return c


def icon_ram() -> Canvas:
    c = Canvas(32, 32)
    c.tri((16, 3), (10, 22), (22, 22), "a")
    c.line(16, 3, 10, 22, "A", 2)
    c.rect(8, 22, 23, 26, "m")
    c.hline(8, 23, 22, "O")
    for x in (11, 16, 21):
        c.put(x, 24, "l")
    c.outline()
    return c


def icon_surrender_flag() -> Canvas:
    c = Canvas(32, 32)
    c.vline(9, 4, 28, "o")
    c.put(9, 3, "a")
    c.rect(10, 5, 23, 15, "t")
    c.rect(10, 5, 14, 9, "h")
    c.hline(10, 23, 15, "O")
    c.outline()
    return c


# --- economy / port (4) --------------------------------------------------------


def icon_chest() -> Canvas:
    """Gilded chest: plank rows with lit edges, riveted gold banding, an
    engraved keyhole plate and a spilled coin stack with glints."""
    c = Canvas(32, 32)
    # lid dome (y8..12) — ICON_MID with NW lit rim + SE shadow rim
    for y, (x0, x1) in enumerate(((11, 20), (9, 22), (8, 23), (7, 24), (6, 25)),
                                 start=8):
        c.hline(x0, x1, y, "m")
        c.put(x0, y, "O")
        c.put(x1, y, "B")
    c.hline(11, 20, 8, "O")                     # lit crown of the dome
    # gold band wrapping the lid base + rivets
    c.hline(5, 26, 13, "a"); c.put(5, 13, "A"); c.put(26, 13, "l")
    c.hline(5, 26, 14, "a"); c.put(5, 14, "A"); c.put(26, 14, "l")
    for rx in (7, 11, 20, 24):
        c.put(rx, 14, "A")                      # rivet dots
    # body planks: seams + lit bevels + contact shadow under the band
    c.hline(5, 26, 15, "B")
    c.hline(6, 14, 16, "O")                     # plank 1 lit bevel (NW half)
    c.hline(5, 26, 17, "m")
    c.hline(5, 26, 18, "B")                     # seam
    c.hline(6, 14, 19, "O")                     # plank 2 lit bevel
    c.hline(5, 26, 20, "m")
    c.hline(5, 26, 21, "m")
    c.hline(5, 26, 22, "B")                     # seam
    c.hline(6, 14, 23, "O")                     # plank 3 lit bevel
    c.hline(5, 26, 24, "m")
    c.hline(5, 26, 25, "m")
    c.hline(5, 26, 26, "m")
    c.hline(5, 26, 27, "B")                     # base shadow
    c.vline(5, 16, 26, "O")                     # lit rail
    c.vline(26, 16, 26, "B")                    # shadow rail
    # vertical straps over the band and body
    for sx in (9, 22):
        c.vline(sx, 13, 27, "A")
        c.vline(sx + 1, 13, 27, "a")
    # lock plate + keyhole + radiating engraving strokes
    c.rect(14, 15, 18, 21, "a")
    c.vline(14, 15, 21, "A")
    c.rect(15, 17, 17, 18, "B")                 # keyhole eye
    c.vline(16, 19, 20, "B")                    # stem
    c.put(15, 20, "B"); c.put(17, 20, "B")      # flare
    for tx, ty in ((12, 16), (12, 20), (20, 16), (20, 20), (13, 23), (19, 23)):
        c.put(tx, ty, "l")                      # engraving ticks
    # coin spill, front right: ACCENT_HI stacks + ICON_HI glints
    c.rect(21, 25, 22, 26, "A"); c.put(21, 25, "h"); c.put(22, 26, "l")
    c.rect(24, 23, 25, 24, "A"); c.put(24, 23, "h"); c.put(25, 24, "l")
    c.rect(19, 26, 20, 27, "A"); c.put(19, 26, "h"); c.put(20, 27, "l")
    c.outline()
    return c


def icon_scroll() -> Canvas:
    c = Canvas(32, 32)
    c.rect(8, 9, 23, 23, "h")
    c.rect(5, 7, 7, 25, "m")
    c.rect(24, 7, 26, 25, "m")
    c.disc(6, 7, 1, "B")
    c.disc(6, 25, 1, "B")
    c.disc(25, 7, 1, "B")
    c.disc(25, 25, 1, "B")
    for y in (12, 15, 18):
        c.hline(11, 20, y, "t")
    c.put(9, 10, "b")
    c.outline()
    return c


def icon_hammer() -> Canvas:
    c = Canvas(32, 32)
    c.rect(6, 8, 24, 16, "m")
    c.rect(6, 8, 24, 9, "O")
    c.rect(4, 10, 6, 14, "m")
    c.rect(25, 10, 27, 14, "m")
    c.rect(14, 16, 17, 28, "t")
    c.rect(15, 27, 16, 28, "o")
    c.outline()
    return c


def icon_bell() -> Canvas:
    c = Canvas(32, 32)
    c.ring(16, 5, 2, 1, "o")
    for y in range(8, 24):
        grow = round(2 + (y - 8) * 8.0 / 15)
        c.rect(16 - grow, y, 16 + grow, y, "a")
    c.rect(6, 24, 25, 26, "l")
    c.put(11, 11, "A")
    c.put(12, 10, "A")
    c.put(12, 11, "A")
    c.disc(16, 27, 2, "l")
    c.outline()
    return c


# --- meta / status (5) ----------------------------------------------------------


def icon_anchor() -> Canvas:
    c = Canvas(32, 32)
    c.ring(16, 6, 3, 2, "o")
    c.rect(15, 9, 16, 24, "o")
    c.hline(8, 23, 12, "o")
    c.put(8, 12, "O")
    c.put(23, 12, "O")
    import math
    for t in range(0, 32):
        ang = math.pi * t / 31.0  # lower half of the arc
        x = round(16 + 9 * math.cos(math.pi - ang))
        y = round(16 + 9 * math.sin(math.pi - ang))
        if y >= 16:
            c.rect(x, y, x + 1, y + 1, "o")
    c.rect(7, 17, 8, 19, "t")
    c.rect(23, 17, 24, 19, "t")
    c.put(12, 10, "O")
    return c


def icon_hourglass() -> Canvas:
    c = Canvas(32, 32)
    c.rect(6, 5, 25, 6, "o")
    c.rect(6, 26, 25, 27, "o")
    c.vline(6, 5, 27, "o")
    c.vline(25, 5, 27, "o")
    c.tri((9, 8), (22, 8), (16, 16), "b")
    c.tri((16, 16), (9, 24), (22, 24), "b")
    c.rect(12, 12, 19, 13, "a")
    c.rect(15, 14, 16, 15, "a")
    c.rect(16, 16, 16, 19, "A")
    for y in range(20, 24):
        grow = (y - 19) * 2
        c.rect(16 - grow // 2 - 1, y, 16 + grow // 2 + 1, y, "a")
    c.outline()
    return c


def icon_save() -> Canvas:
    c = Canvas(32, 32)
    c.rect(8, 18, 23, 28, "m")
    c.rect(12, 15, 19, 19, "B")
    c.frame(12, 15, 19, 19, "o")
    c.line(21, 4, 14, 16, "t", 2)
    c.line(20, 6, 16, 5, "t", 1)
    c.line(17, 9, 22, 9, "t", 1)
    c.line(15, 12, 19, 12, "t", 1)
    c.put(13, 17, "o")
    c.put(8, 20, "O")
    c.outline()
    return c


def icon_skull() -> Canvas:
    c = Canvas(32, 32)
    c.disc(16, 13, 9, "t")
    c.rect(8, 13, 23, 19, "t")
    c.rect(11, 20, 20, 26, "t")
    c.rect(11, 13, 13, 15, "m")
    c.rect(18, 13, 20, 15, "m")
    c.tri((16, 16), (15, 18), (17, 18), "m")
    for x in (13, 16, 19):
        c.vline(x, 21, 23, "m")
    c.put(10, 8, "h")
    c.put(11, 7, "h")
    c.outline()
    return c


def icon_crown() -> Canvas:
    """Ornate five-point crown, UW2 restraint (batch-1 review): five tapered
    teardrop spires (2px shaft widening to a 4px belly), a thin band (1px
    ACCENT_HI top edge / ACCENT face / ACCENT_LO base), bead dots between the
    points, and a single cross-sparkle on the center gem only."""
    c = Canvas(32, 32)

    def spire(cx: int, apex_y: int, shaft: tuple[int, int],
              belly_x0: int, belly_x1: int, belly_y: int) -> None:
        # tapered teardrop: lit tip bead, 3px shaft (1px gold core after the
        # outline erosion), 4px belly whose length scales with the height
        c.put(cx, apex_y, "A")                  # tip bead (center column)
        for y in range(apex_y + 1, belly_y):
            c.hline(shaft[0], shaft[1], y, "a")
        for y in range(belly_y, 21):
            c.hline(belly_x0, belly_x1, y, "a")

    spire(6, 13, (5, 7), 4, 7, 17)          # outer pair
    spire(25, 13, (24, 26), 24, 27, 17)
    spire(10, 10, (9, 11), 9, 12, 15)       # inner pair
    spire(21, 10, (20, 22), 19, 22, 15)
    spire(15, 7, (14, 16), 14, 17, 14)      # tall center
    # bead dots between the points, set into the band face
    for bx in (8, 13, 18, 23):
        c.put(bx, 22, "h")
    # center gem + the only cross-sparkle
    c.vline(15, 11, 13, "h")
    _sparkle(c, 15, 10, "h")
    # band: 1px ACCENT_HI top edge / ACCENT face / ACCENT_LO base
    c.hline(4, 27, 21, "A")
    c.hline(4, 27, 22, "a")
    c.hline(4, 27, 23, "l")
    c.outline()
    return c


# --- nation flags (7) — simple heraldic layouts, exact FLAG_* hexes ----------


def _flag_base() -> Canvas:
    c = Canvas(32, 32)
    c.rect(0, 0, 31, 31, "t")
    return c


def flag_portugal() -> Canvas:
    c = _flag_base()
    c.rect(0, 0, 12, 31, "p")
    c.rect(13, 0, 31, 31, "s")
    c.ring(13, 16, 4, 2, "a")
    c.put(13, 16, "A")
    c.put(12, 15, "A")
    c.put(14, 17, "l")
    c.outline()
    return c


def flag_spain() -> Canvas:
    c = _flag_base()
    c.rect(0, 0, 31, 7, "s")
    c.rect(0, 8, 31, 23, "A")
    c.rect(0, 24, 31, 31, "s")
    c.rect(9, 13, 11, 18, "s")
    c.outline()
    return c


def flag_england() -> Canvas:
    c = _flag_base()
    c.rect(14, 0, 17, 31, "s")
    c.rect(0, 14, 31, 17, "s")
    c.outline()
    return c


def flag_holland() -> Canvas:
    c = _flag_base()
    c.rect(0, 0, 31, 10, "s")
    c.rect(0, 11, 31, 21, "t")
    c.rect(0, 22, 31, 31, "e")
    c.outline()
    return c


def flag_ottoman() -> Canvas:
    c = _flag_base()
    c.rect(0, 0, 31, 31, "u")
    c.ring(13, 16, 6, 2, "t")
    c.disc(15, 15, 4, "u")
    for dx, dy in ((0, 0), (1, 0), (2, 0), (1, 1), (1, -1), (0, 1), (2, 1),
                   (0, -1), (2, -1)):
        c.put(21 + dx, 12 + dy, "h")
    c.outline()
    return c


def flag_italy() -> Canvas:
    c = _flag_base()
    c.rect(0, 0, 10, 31, "p")
    c.rect(11, 0, 21, 31, "t")
    c.rect(22, 0, 31, 31, "s")
    c.outline()
    return c


def flag_neutral() -> Canvas:
    c = _flag_base()
    c.rect(0, 0, 31, 31, "n")
    c.rect(0, 13, 31, 18, "B")
    c.outline()
    return c


# --- goods (40): category motif families + per-id silhouettes ----------------
# Category tint pins (80-* 4.8.4): food GOOD, material ACCENT_LO, textile
# COAST_SEA, luxury ACCENT — the motif's dominant tint; NW-lit, 1px outline.

FOOD = ("g", "G")
MATERIAL = ("l", "a")
TEXTILE = ("c", "O")
LUXURY = ("a", "A")


def _blob(tint, hi, cx=16, cy=17, r=9) -> Canvas:
    """Organic motif: rounded blob + NW highlight (food family)."""
    c = Canvas(32, 32)
    c.disc(cx, cy, r, tint)
    c.disc(cx - 4, cy - 4 + 2, r - 5, hi)
    return c


def good_wheat() -> Canvas:
    c = Canvas(32, 32)
    for x in (10, 16, 22):
        c.vline(x, 14, 28, "g")
        for y in range(8, 14):
            c.put(x, y, "G")
            c.put(x - 1, y, "G")
            c.put(x + 1, y, "G")
        c.put(x, 6, "G")
        c.put(x, 7, "G")
        c.put(x - 2, 7, "G")
        c.put(x + 2, 7, "G")
        c.put(x - 2, 13, "G")
        c.put(x + 2, 13, "G")
    return c


def good_olive_oil() -> Canvas:
    c = Canvas(32, 32)
    c.rect(13, 5, 18, 8, "m")
    c.rect(10, 8, 21, 25, "g")
    c.disc(16, 19, 6, "g")
    c.rect(10, 8, 21, 10, "G")
    c.put(12, 12, "G")
    c.put(12, 13, "G")
    c.outline()
    return c


def good_wine() -> Canvas:
    c = Canvas(32, 32)
    c.rect(14, 4, 17, 9, "g")
    c.tri((13, 9), (18, 9), (18, 14), "g")
    c.tri((13, 9), (13, 14), (18, 9), "g")
    c.rect(11, 14, 20, 27, "g")
    c.rect(11, 14, 20, 17, "G")
    c.rect(13, 4, 16, 5, "B")
    c.outline()
    return c


def good_sugar() -> Canvas:
    c = Canvas(32, 32)
    c.tri((16, 6), (8, 26), (24, 26), "g")
    c.line(16, 6, 8, 26, "G", 1)
    c.put(14, 12, "G")
    c.put(13, 18, "G")
    c.outline()
    return c


def good_salt() -> Canvas:
    c = Canvas(32, 32)
    c.tri((16, 10), (9, 22), (23, 22), "G")
    c.rect(8, 22, 24, 26, "g")
    c.put(14, 16, "h")
    c.put(17, 18, "h")
    c.outline()
    return c


def good_dried_fish() -> Canvas:
    c = Canvas(32, 32)
    c.disc(15, 16, 8, "g")
    c.rect(7, 14, 22, 18, "g")
    c.tri((23, 16), (28, 11), (28, 21), "G")
    c.put(10, 14, "B")
    c.put(11, 15, "B")
    c.put(10, 15, "B")
    c.line(9, 13, 18, 13, "G", 1)
    c.outline()
    return c


def good_cheese() -> Canvas:
    c = Canvas(32, 32)
    c.tri((5, 24), (26, 12), (26, 24), "g")
    c.line(5, 24, 26, 12, "G", 1)
    c.disc(20, 20, 2, "G")
    c.disc(14, 21, 1, "G")
    c.outline()
    return c


def good_rice() -> Canvas:
    c = Canvas(32, 32)
    c.rect(9, 12, 22, 26, "g")
    c.tri((9, 12), (22, 12), (16, 7), "G")
    c.vline(12, 14, 24, "G")
    c.vline(19, 14, 24, "G")
    c.hline(9, 22, 17, "l")
    c.outline()
    return c


def good_coffee() -> Canvas:
    c = Canvas(32, 32)
    for cx, cy in ((12, 14), (20, 18)):
        c.disc(cx, cy, 5, "g")
        c.line(cx - 3, cy - 2, cx + 2, cy + 3, "G", 1)
    c.disc(19, 10, 4, "g")
    c.line(17, 8, 21, 12, "G", 1)
    c.outline()
    return c


def good_tobacco() -> Canvas:
    c = Canvas(32, 32)
    c.line(8, 24, 24, 9, "g", 2)
    c.tri((10, 22), (14, 10), (18, 18), "G")
    c.tri((16, 20), (22, 12), (24, 16), "G")
    c.outline()
    return c


def good_tea() -> Canvas:
    c = Canvas(32, 32)
    c.line(10, 27, 22, 8, "g", 2)
    c.disc(11, 19, 4, "G")
    c.put(10, 17, "g")
    c.put(12, 17, "g")
    c.put(10, 21, "g")
    c.disc(20, 17, 4, "G")
    c.put(19, 15, "g")
    c.put(21, 15, "g")
    c.put(19, 19, "g")
    c.put(23, 8, "G")
    c.put(22, 7, "G")
    c.outline()
    return c


def _chunk(tint, hi, cx=16, cy=16, r=9) -> Canvas:
    """Raw motif: chunky faceted lump (material family)."""
    c = Canvas(32, 32)
    c.tri((cx, cy - r), (cx + r, cy - r // 3), (cx + r - 2, cy + r), tint)
    c.tri((cx, cy - r), (cx + r, cy - r // 3), (cx - r, cy + r // 2), tint)
    c.tri((cx, cy - r), (cx - r, cy + r // 2), (cx - r + 3, cy + r), tint)
    c.tri((cx - r + 3, cy + r), (cx + r - 2, cy + r), (cx - r, cy + r // 2), hi)
    c.line(cx, cy - r + 2, cx + r - 2, cy - r // 3, hi, 1)
    return c


def _ingot(stacked: int = 1) -> Canvas:
    c = Canvas(32, 32)
    for i in range(stacked):
        y0 = 22 - i * 6
        c.tri((6 + i, y0 + 5), (26 - i, y0 + 5), (23 - i, y0), "l")
        c.tri((6 + i, y0 + 5), (9 + i, y0), (23 - i, y0), "l")
        c.line(9 + i, y0, 23 - i, y0, "a", 1)
        c.line(6 + i, y0 + 4, 9 + i, y0, "a", 1)
    c.outline()
    return c


def good_timber() -> Canvas:
    c = Canvas(32, 32)
    for y in (10, 16, 22):
        c.rect(6, y, 25, y + 4, "l")
        c.disc(6, y + 2, 2, "a")
        c.disc(25, y + 2, 2, "a")
    c.rect(6, 10, 25, 11, "a")
    c.outline()
    return c


def good_iron() -> Canvas:
    return _ingot(2)


def good_copper() -> Canvas:
    return _chunk("l", "a")


def good_leather() -> Canvas:
    c = Canvas(32, 32)
    c.disc(16, 17, 9, "l")
    c.rect(7, 15, 24, 21, "l")
    c.tri((7, 15), (4, 8), (12, 12), "l")
    c.tri((24, 15), (27, 8), (19, 12), "l")
    c.put(11, 12, "a")
    c.put(21, 12, "a")
    c.put(12, 13, "a")
    c.put(20, 13, "a")
    c.outline()
    return c


def good_ceramics() -> Canvas:
    c = Canvas(32, 32)
    c.rect(13, 5, 18, 8, "l")
    c.tri((12, 8), (19, 8), (21, 15), "l")
    c.tri((12, 8), (10, 15), (19, 8), "l")
    c.disc(16, 20, 8, "l")
    c.rect(8, 15, 24, 20, "l")
    c.line(11, 10, 13, 16, "a", 1)
    c.put(13, 20, "a")
    c.put(18, 22, "a")
    c.outline()
    return c


def good_pitch() -> Canvas:
    c = Canvas(32, 32)
    c.rect(9, 16, 22, 26, "l")
    c.disc(15, 14, 6, "l")
    c.disc(20, 12, 4, "l")
    c.rect(9, 16, 22, 17, "a")
    c.put(13, 12, "a")
    c.outline()
    return c


def good_furs() -> Canvas:
    c = Canvas(32, 32)
    c.disc(16, 17, 9, "l")
    c.rect(8, 16, 24, 20, "l")
    for x, y in ((9, 10), (14, 8), (20, 9), (25, 12), (7, 15), (24, 16)):
        c.line(x, y, x + 1, y + 3, "a", 1)
    c.put(13, 18, "a")
    c.put(18, 17, "a")
    c.outline()
    return c


def good_dye_wood() -> Canvas:
    c = Canvas(32, 32)
    for y in (11, 19):
        c.rect(7, y, 24, y + 4, "l")
        c.line(7, y, 24, y, "r", 1)
    c.disc(7, 13, 2, "a")
    c.disc(24, 21, 2, "a")
    c.outline()
    return c


def good_indigo() -> Canvas:
    c = Canvas(32, 32)
    c.rect(7, 14, 15, 24, "c")
    c.rect(16, 10, 25, 20, "c")
    c.line(7, 14, 15, 14, "O", 1)
    c.line(16, 10, 25, 10, "O", 1)
    c.rect(7, 23, 15, 24, "B")
    c.rect(16, 19, 25, 20, "B")
    c.outline()
    return c


def good_ivory() -> Canvas:
    c = Canvas(32, 32)
    c.tri((10, 27), (14, 8), (19, 27), "h")
    c.line(14, 8, 10, 27, "t", 1)
    c.put(15, 12, "t")
    c.put(16, 18, "t")
    c.rect(8, 25, 21, 28, "l")
    c.outline()
    return c


def good_sandalwood() -> Canvas:
    c = Canvas(32, 32)
    c.rect(6, 13, 25, 18, "l")
    c.line(6, 13, 25, 13, "a", 1)
    c.ring(6, 15, 2, 1, "a")
    c.ring(25, 15, 2, 1, "a")
    c.line(12, 14, 12, 17, "r", 1)
    c.line(18, 14, 18, 17, "r", 1)
    c.outline()
    return c


def good_rhubarb() -> Canvas:
    c = Canvas(32, 32)
    c.line(15, 26, 16, 12, "l", 2)
    c.disc(11, 12, 4, "l")
    c.disc(20, 14, 4, "l")
    c.disc(15, 9, 3, "l")
    c.put(10, 10, "a")
    c.put(19, 12, "a")
    c.put(14, 8, "a")
    c.outline()
    return c


def good_silver() -> Canvas:
    c = Canvas(32, 32)
    c.tri((6, 21), (26, 21), (22, 13), "t")
    c.tri((6, 21), (10, 13), (22, 13), "t")
    c.line(10, 13, 22, 13, "h", 1)
    c.line(6, 20, 10, 13, "h", 1)
    c.outline()
    return c


def good_gold() -> Canvas:
    c = Canvas(32, 32)
    c.tri((6, 22), (26, 22), (22, 14), "a")
    c.tri((6, 22), (10, 14), (22, 14), "a")
    c.line(10, 14, 22, 14, "A", 1)
    c.line(6, 21, 10, 14, "A", 1)
    c.put(14, 17, "h")
    c.put(15, 17, "h")
    c.outline()
    return c


def _bolt(tint, hi) -> Canvas:
    """Textile motif: folded cloth bolt (roll with a fold spiral)."""
    c = Canvas(32, 32)
    c.rect(6, 12, 25, 23, tint)
    c.disc(25, 17, 5, tint)
    c.ring(25, 17, 3, 1, hi)
    c.rect(6, 12, 25, 13, hi)
    c.hline(6, 22, 18, hi)
    c.rect(6, 22, 25, 23, "B")
    c.outline()
    return c


def good_wool() -> Canvas:
    c = Canvas(32, 32)
    c.rect(8, 10, 23, 24, "c")
    c.hline(8, 23, 11, "O")
    c.hline(8, 23, 15, "t")
    c.hline(8, 23, 19, "t")
    c.rect(8, 23, 23, 24, "B")
    c.rect(8, 10, 9, 24, "O")
    c.outline()
    return c


def good_cotton_cloth() -> Canvas:
    return _bolt("c", "O")


def good_silk() -> Canvas:
    """Silk bolt, UW2 restraint (batch-1 review): a neat folded bolt — three
    clean horizontal folds (COAST_SEA body, one ICON_HI sheen line per fold,
    an ICON_BG_LO shadow line under each), a gold trim along the wrap edge
    with a small tassel, one ICON_HI sparkle on the fold crest.  No diagonal
    streaks, no roll spiral."""
    c = Canvas(32, 32)
    c.rect(5, 11, 24, 24, "c")                  # bolt body (COAST_SEA)
    # three folds: ICON_HI sheen on each crest, ICON_BG_LO shadow under each
    for crest, shadow in ((12, 15), (16, 19), (20, 23)):
        c.hline(6, 23, crest, "h")
        c.hline(6, 23, shadow, "B")
    # gold trim along the wrap edge (the bolt's left end)
    c.vline(6, 12, 23, "a")
    # one ICON_HI sparkle on the top fold's crest
    _sparkle(c, 20, 13, "h")
    # small tassel hanging off the wrap edge
    c.put(6, 25, "a")                           # cord
    c.put(6, 26, "A")                           # knot
    c.put(5, 27, "a"); c.put(6, 27, "l"); c.put(7, 27, "a")
    c.outline()
    return c


def good_carpet() -> Canvas:
    c = Canvas(32, 32)
    c.rect(7, 9, 24, 25, "c")
    c.frame(7, 9, 24, 25, "a")
    c.rect(12, 13, 19, 20, "a")
    c.frame(12, 13, 19, 20, "t")
    c.put(15, 16, "t")
    c.put(16, 16, "t")
    c.rect(7, 23, 24, 25, "B")
    c.outline()
    return c


def good_linen() -> Canvas:
    c = Canvas(32, 32)
    for i, y in enumerate((9, 13, 17, 21)):
        c.rect(7, y, 24, y + 3, "c")
        c.hline(7, 24, y, "O")
    c.rect(7, 24, 24, 25, "B")
    c.outline()
    return c


def good_raw_silk() -> Canvas:
    c = Canvas(32, 32)
    for cx, cy in ((12, 17), (20, 15)):
        c.disc(cx, cy, 5, "c")
        c.line(cx - 3, cy + 1, cx + 3, cy - 1, "O", 1)
    c.put(9, 14, "O")
    c.put(17, 12, "O")
    c.outline()
    return c


def _gem(tint, hi, lo) -> Canvas:
    """Luxury motif: faceted cut stone."""
    c = Canvas(32, 32)
    c.tri((16, 6), (26, 14), (16, 26), tint)
    c.tri((16, 6), (6, 14), (16, 26), tint)
    c.line(16, 6, 26, 14, hi, 1)
    c.line(16, 6, 6, 14, hi, 1)
    c.line(6, 14, 16, 26, lo, 1)
    c.line(26, 14, 16, 26, lo, 1)
    c.line(11, 10, 21, 10, hi, 1)
    c.put(14, 12, hi)
    c.put(17, 18, lo)
    return c


def good_spices() -> Canvas:
    c = Canvas(32, 32)
    c.rect(10, 12, 21, 25, "a")
    c.tri((10, 12), (21, 12), (16, 7), "A")
    c.rect(13, 8, 18, 10, "l")
    c.put(12, 15, "l")
    c.put(16, 17, "l")
    c.put(19, 20, "l")
    c.outline()
    return c


def good_glassware() -> Canvas:
    c = Canvas(32, 32)
    c.tri((10, 7), (21, 7), (16, 16), "c")
    c.rect(15, 16, 16, 23, "c")
    c.rect(11, 23, 20, 26, "c")
    c.hline(10, 21, 8, "O")
    c.put(12, 9, "O")
    c.put(11, 10, "O")
    c.outline()
    return c


def good_perfume() -> Canvas:
    c = Canvas(32, 32)
    c.rect(13, 4, 18, 8, "l")
    c.rect(11, 8, 20, 12, "a")
    c.disc(16, 19, 7, "a")
    c.rect(11, 12, 20, 15, "a")
    c.put(12, 13, "A")
    c.put(13, 14, "A")
    c.put(12, 14, "A")
    c.outline()
    return c


def good_amber() -> Canvas:
    c = Canvas(32, 32)
    c.disc(16, 17, 9, "a")
    c.line(10, 13, 21, 12, "A", 1)
    c.line(21, 12, 24, 19, "l", 1)
    c.line(10, 13, 12, 22, "l", 1)
    c.put(13, 14, "h")
    c.put(14, 14, "h")
    c.outline()
    return c


def good_porcelain() -> Canvas:
    c = Canvas(32, 32)
    c.rect(13, 5, 18, 8, "h")
    c.tri((12, 8), (19, 8), (23, 14), "h")
    c.tri((12, 8), (8, 14), (19, 8), "h")
    c.disc(16, 20, 8, "h")
    c.rect(8, 15, 24, 19, "h")
    c.line(10, 16, 22, 16, "a", 1)
    c.put(16, 22, "a")
    c.outline()
    return c


def good_pearls() -> Canvas:
    """Pearl strand: an arc of nine 3px pearls (NW glint, ICON_MID core,
    ICON_BG_LO bottom shade) strung on an ink thread with a tiny gold bow
    clasp at the apex.  Sparse-marks family: no silhouette outline."""
    c = Canvas(32, 32)
    import math
    pts = []
    for i in range(9):
        ang = math.radians(210 + i * 15)
        x = round(16 + 14 * math.cos(ang))
        y = round(21 + 14 * math.sin(ang))
        pts.append((x, y))
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        c.line(x0, y0, x1, y1, "o")             # the string
    # tiny ACCENT bow clasp at the apex
    c.tri((15, 4), (12, 3), (15, 6), "a")
    c.tri((17, 4), (20, 3), (17, 6), "a")
    c.put(12, 3, "l"); c.put(20, 3, "l")        # wing tips
    c.rect(15, 5, 16, 5, "A")                   # knot
    # pearls: 3x3, NW glint / ICON_MID core / ICON_BG_LO bottom shade
    bead = (("h", "h", "O"),
            ("h", "m", "B"),
            ("O", "B", "B"))
    for x, y in pts:
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                c.put(x + dx, y + dy, bead[dy + 1][dx + 1])
    return c


def good_gems() -> Canvas:
    c = _gem("a", "A", "l")
    c.put(13, 14, "h")
    c.put(14, 13, "h")
    return c


def good_musk() -> Canvas:
    c = Canvas(32, 32)
    c.rect(10, 10, 21, 24, "a")
    c.rect(10, 10, 21, 11, "A")
    c.rect(13, 6, 18, 10, "l")
    c.rect(14, 15, 17, 18, "l")
    c.outline()
    return c


def good_lacquerware() -> Canvas:
    c = Canvas(32, 32)
    c.rect(7, 12, 24, 24, "r")
    c.rect(7, 12, 24, 14, "R")
    c.rect(7, 12, 8, 24, "R")
    c.rect(14, 16, 17, 19, "a")
    c.rect(7, 22, 24, 24, "B")
    c.outline()
    return c


# --- equipment (24): ids already carry the eq_ prefix -------------------------
# Weapon steel 't'/'h', brass 'a', wood/leather 'm'; NW-lit, 1px outline.


def _blade(tip, hilt, guard_kind, curve=False, thin=False) -> Canvas:
    c = Canvas(32, 32)
    ch = "h" if thin else "t"
    if curve:
        c.line(hilt[0], hilt[1], 20, 12, ch, 2)
        c.line(20, 12, tip[0], tip[1], ch, 2)
    else:
        c.line(hilt[0], hilt[1], tip[0], tip[1], ch, 2)
    c.put(tip[0] + 1, tip[1] - 1, ch)
    gx, gy = hilt[0] + 2, hilt[1] - 2
    if guard_kind == "disc":
        c.ring(gx, gy, 3, 2, "a")
    elif guard_kind == "bell":
        c.ring(gx, gy, 4, 2, "a")
        c.put(gx + 4, gy + 1, "a")
    elif guard_kind == "cross":
        # perpendicular to the ↗ blade: run the bar ↘
        c.line(gx - 3, gy - 3, gx + 3, gy + 3, "a", 2)
    elif guard_kind == "long_cross":
        c.line(gx - 5, gy - 5, gx + 5, gy + 5, "a", 2)
    elif guard_kind == "prong":
        c.line(gx - 3, gy - 3, gx + 3, gy + 3, "a", 1)
        c.put(gx - 4, gy - 2, "a")
        c.put(gx + 4, gy + 2, "a")
    c.rect(hilt[0] - 2, hilt[1], hilt[0] + 1, hilt[1] + 3, "m")
    c.disc(hilt[0] - 2, hilt[1] + 4, 2, "a")
    c.outline()
    return c


def eq_cutlass() -> Canvas:
    return _blade((25, 6), (10, 21), "disc", curve=True)


def eq_rapier() -> Canvas:
    return _blade((26, 5), (11, 20), "bell", thin=True)


def eq_backsword() -> Canvas:
    return _blade((25, 6), (10, 21), "cross")


def eq_main_gauche() -> Canvas:
    return _blade((22, 9), (12, 19), "prong", thin=True)


def eq_zweihander() -> Canvas:
    return _blade((26, 5), (9, 22), "long_cross")


def eq_khair_scimitar() -> Canvas:
    c = Canvas(32, 32)
    c.line(11, 22, 20, 13, "t", 2)
    c.line(20, 13, 26, 11, "t", 2)
    c.line(20, 13, 24, 9, "t", 1)
    c.put(26, 10, "t")
    c.ring(11, 20, 3, 2, "a")
    c.rect(8, 21, 11, 24, "m")
    c.disc(7, 24, 2, "a")
    c.outline()
    return c


def _torso(studs=None, bands=None, pauldrons=False) -> Canvas:
    c = Canvas(32, 32)
    c.rect(6, 8, 25, 12, "m")
    c.rect(8, 12, 23, 24, "m")
    c.rect(10, 24, 21, 25, "m")
    c.rect(13, 6, 18, 9, ".")
    c.hilo("O", "B")
    c.vline(16, 12, 23, "O")
    if pauldrons:
        c.disc(7, 12, 3, "m")
        c.disc(24, 12, 3, "m")
        c.put(6, 10, "O")
        c.put(25, 10, "O")
    if studs:
        for y in range(13, 24, 3):
            for x in range(10, 23, 4):
                c.put(x, y, "a")
    if bands:
        for y in bands:
            c.hline(9, 22, y, "r")
            c.put(10, y, "R")
    c.outline()
    return c


def eq_breastplate() -> Canvas:
    return _torso()


def eq_brigandine() -> Canvas:
    return _torso(studs=True)


def eq_three_quarter_armor() -> Canvas:
    return _torso(pauldrons=True)


def eq_bloodhand_cuirass() -> Canvas:
    return _torso(bands=(14, 19))


def _figurehead(head_ch, mane_ch, wing="none", halo=False, beak=False) -> Canvas:
    c = Canvas(32, 32)
    c.line(7, 27, 14, 17, "m", 3)
    c.line(14, 17, 17, 13, "m", 3)
    c.hilo("O", "B")
    c.disc(18, 10, 3, head_ch)
    c.put(17, 8, mane_ch)
    c.put(18, 7, mane_ch)
    c.put(19, 8, mane_ch)
    if beak:
        c.put(22, 10, "a")
        c.put(21, 10, "a")
    if wing == "spread":
        c.tri((15, 12), (6, 5), (14, 16), head_ch)
        c.tri((20, 12), (28, 6), (21, 16), head_ch)
        c.line(14, 12, 8, 7, "m", 1)
        c.line(21, 12, 26, 8, "m", 1)
    elif wing == "folded":
        c.tri((15, 13), (8, 8), (14, 18), head_ch)
        c.line(14, 13, 9, 9, "m", 1)
    if halo:
        c.ring(18, 4, 2, 1, "a")
    c.outline()
    return c


def eq_mermaid_figurehead() -> Canvas:
    c = Canvas(32, 32)
    c.line(7, 27, 14, 17, "m", 3)
    c.line(14, 17, 17, 13, "m", 3)   # neck joins the head
    c.disc(17, 11, 3, "t")
    c.rect(14, 7, 20, 9, "a")        # hair
    c.put(14, 10, "a")
    c.put(20, 10, "a")
    c.line(13, 17, 9, 22, "g", 2)
    c.line(9, 22, 11, 25, "g", 2)
    c.put(16, 10, "B")
    c.outline()
    return c


def eq_eagle_figurehead() -> Canvas:
    return _figurehead("t", "h", wing="spread", beak=True)


def eq_dragon_figurehead() -> Canvas:
    return _figurehead("g", "G", wing="folded")


def eq_albatross_figurehead() -> Canvas:
    c = Canvas(32, 32)
    c.line(8, 27, 15, 17, "m", 3)
    c.line(15, 17, 17, 14, "m", 3)
    c.disc(18, 11, 3, "t")
    c.put(22, 11, "a")
    c.put(21, 11, "a")
    c.line(16, 12, 5, 8, "t", 2)
    c.line(16, 12, 7, 15, "t", 2)
    c.put(17, 9, "h")
    c.outline()
    return c


def eq_angel_figurehead() -> Canvas:
    return _figurehead("t", "h", wing="spread", halo=True)


def eq_golden_dragon_figurehead() -> Canvas:
    """Gilt dragon head: profile skull with lit snout ridge and dark mouth,
    a flowing flame mane (gold mass, oxide seams, bright spines), horns
    swept back over the mane, a scale-hatched neck and scroll volutes."""
    c = Canvas(32, 32)
    # flame mane: solid gold mass left of the skull, wavy leading edge,
    # oxide seam lines + bright spines suggest separate tongues
    edge = {4: 11, 5: 10, 6: 8, 7: 7, 8: 7, 9: 6, 10: 7, 11: 7, 12: 8,
            13: 9, 14: 10}
    for y, x0 in edge.items():
        c.hline(x0, 16, y, "a")
    for y in (5, 8, 11):
        c.hline(8, 15, y, "A")                  # bright spines
    for y in (6, 9, 12):
        _checker(c, edge[y] + 1, y, 13, y, "l")  # oxide seams (dithered)
    for y in (4, 7, 10, 13):
        c.hline(edge[y], 16, y, "a")
        _checker(c, edge[y], y, 12, y, "l")     # dither toward the tips
    # skull + snout profile
    c.rect(17, 8, 27, 14, "a")
    c.hline(18, 26, 9, "A")                     # crown ridge
    c.rect(24, 10, 29, 12, "a")
    c.hline(25, 29, 11, "A")                    # snout highlight ridge
    c.put(29, 12, "l")                          # nostril shade
    c.rect(25, 13, 28, 13, "B")                 # mouth
    c.put(26, 13, "h"); c.put(28, 13, "h")      # fangs
    # horns swept back over the mane
    c.line(17, 8, 13, 4, "A", 2)
    c.line(21, 8, 18, 4, "A", 2)
    # cross-sparkle eye
    _sparkle(c, 21, 11, "h")
    # neck post with scale hatching
    c.rect(11, 15, 17, 22, "a")
    c.vline(12, 15, 22, "A")
    for ty, xs in ((16, (13, 15)), (18, (14, 16)), (20, (13, 15)),
                   (22, (14, 16))):
        for tx in xs:
            c.put(tx, ty, "l")                  # scale ticks
    # scroll-work volutes
    c.disc(10, 25, 4, "a"); c.put(10, 25, ".")
    c.put(8, 23, "l"); c.put(12, 25, "l")       # curl shading
    c.disc(17, 28, 3, "a"); c.put(17, 28, ".")
    c.outline()
    return c


def _sail(cloth_ch, hi_ch, lo_ch, pattern="plain") -> Canvas:
    c = Canvas(32, 32)
    c.vline(9, 4, 28, "o")
    c.hline(9, 25, 8, "o")
    c.rect(10, 9, 24, 26, cloth_ch)
    for y in range(9, 27):
        c.put(10, y, hi_ch)
    for y in range(9, 27):
        c.put(24, y, lo_ch)
    if pattern == "weave":
        for y in range(11, 26, 3):
            for x in range(12, 24, 3):
                c.put(x, y, lo_ch)
    elif pattern == "reef":
        c.hline(11, 23, 14, lo_ch)
        c.hline(11, 23, 19, lo_ch)
    elif pattern == "seams":
        c.vline(15, 10, 25, hi_ch)
        c.vline(20, 10, 25, hi_ch)
    elif pattern == "brocade":
        for x, y in ((13, 12), (19, 12), (16, 16), (13, 20), (19, 20)):
            c.put(x, y, "A")
    c.line(25, 8, 25, 26, lo_ch)
    c.outline()
    return c


def eq_cotton_sails() -> Canvas:
    return _sail("t", "h", "O")


def eq_matting_sails() -> Canvas:
    return _sail("m", "O", "B", pattern="weave")


def eq_storm_sails() -> Canvas:
    return _sail("B", "m", "o", pattern="reef")


def eq_flemish_linen_sails() -> Canvas:
    return _sail("t", "h", "O", pattern="seams")


def eq_brocade_sails() -> Canvas:
    return _sail("a", "A", "l", pattern="brocade")


def eq_red_sail() -> Canvas:
    return _sail("r", "R", "B")


def eq_lucky_charm() -> Canvas:
    c = Canvas(32, 32)
    c.vline(16, 4, 8, "o")
    c.ring(16, 17, 8, 3, "a")
    c.erase_if(lambda x, y: y < 12 and 9 < x < 23)
    for x, y in ((11, 14), (11, 19), (14, 23), (18, 23), (21, 19), (21, 14)):
        c.put(x, y, "l")
    c.put(12, 12, "A")
    c.put(13, 11, "A")
    c.outline()
    return c


def eq_saint_medallion() -> Canvas:
    c = Canvas(32, 32)
    c.vline(16, 3, 8, "o")
    c.ring(16, 10, 2, 1, "a")
    c.disc(16, 20, 8, "a")
    for y in range(32):
        for x in range(32):
            d2 = (x - 16) ** 2 + (y - 20) ** 2
            if 64 < d2 <= 121:
                c.put(x, y, "l")
    c.rect(15, 16, 16, 23, "h")
    c.rect(13, 18, 18, 19, "h")
    c.put(12, 15, "A")
    c.put(13, 14, "A")
    c.outline()
    return c


# --- role badges (7): cloth-tint shields + TEXT glyphs -----------------------


def _badge(tint, hi) -> Canvas:
    c = Canvas(32, 32)
    c.rect(5, 4, 26, 22, tint)
    taper = ((8, 23), (10, 21), (12, 19), (14, 18), (15, 17))
    for i, (x0, x1) in enumerate(taper):
        c.rect(x0, 23 + i, x1, 23 + i, tint)
    for y in range(32):
        for x in range(32):
            if c.get(x, y) == tint and (c.get(x - 1, y) != tint
                                        or c.get(x, y - 1) != tint):
                if c.get(x - 1, y - 1) == ".":
                    c.put(x, y, hi)
    c.outline()
    return c


def role_trader() -> Canvas:
    c = _badge("a", "A")
    c.disc(16, 13, 4, "A")
    c.ring(16, 13, 4, 1, "l")
    c.rect(15, 12, 16, 13, "h")
    return c


def role_coaster() -> Canvas:
    c = _badge("o", "O")
    c.rect(11, 16, 20, 18, "t")
    c.put(10, 15, "t")
    c.put(21, 15, "t")
    c.tri((16, 9), (16, 14), (20, 14), "t")
    c.vline(16, 9, 15, "h")
    return c


def role_courier() -> Canvas:
    c = _badge("c", "O")
    c.line(11, 15, 16, 10, "t", 2)
    c.line(16, 10, 21, 15, "t", 2)
    c.line(11, 20, 16, 15, "t", 2)
    c.line(16, 15, 21, 20, "t", 2)
    return c


def role_patrol() -> Canvas:
    c = _badge("g", "G")
    c.rect(15, 8, 16, 17, "t")
    c.rect(11, 12, 20, 13, "t")
    c.put(13, 10, "t")
    c.put(18, 10, "t")
    c.put(13, 15, "t")
    c.put(18, 15, "t")
    c.put(15, 12, "h")
    return c


def role_privateer() -> Canvas:
    c = _badge("l", "a")
    c.line(11, 9, 21, 19, "t", 2)
    c.line(21, 9, 11, 19, "t", 2)
    c.put(10, 8, "A")
    c.put(22, 8, "A")
    return c


def role_pirate() -> Canvas:
    c = _badge("r", "R")
    c.rect(12, 9, 19, 16, "t")
    c.rect(13, 16, 18, 18, "t")
    c.rect(13, 11, 14, 13, "r")
    c.rect(17, 11, 18, 13, "r")
    c.vline(15, 16, 17, "r")
    c.vline(17, 16, 17, "r")
    c.put(13, 9, "h")
    return c


def role_hunter() -> Canvas:
    c = _badge("R", "r")
    c.ring(16, 13, 4, 1, "t")
    c.vline(16, 7, 10, "t")
    c.vline(16, 16, 19, "t")
    c.hline(9, 12, 13, "t")
    c.hline(19, 22, 13, "t")
    c.put(16, 13, "h")
    return c


# --- formations (4): sparse PANEL_LINE dots + a TEXT heading chevron ----------


def _dots(c: Canvas, pts) -> None:
    for cx, cy, r in pts:
        c.disc(cx, cy, r, "o")


def formation_line_ahead() -> Canvas:
    c = Canvas(32, 32)
    _dots(c, ((16, 13, 2), (16, 19, 2), (16, 25, 2), (16, 29, 1)))
    c.line(12, 8, 15, 5, "t", 2)
    c.line(17, 5, 20, 8, "t", 2)
    c.rect(14, 4, 16, 6, "t")
    return c


def formation_column() -> Canvas:
    c = Canvas(32, 32)
    _dots(c, ((11, 14, 2), (21, 14, 2), (11, 20, 2), (21, 20, 2),
              (11, 26, 2), (21, 26, 1)))
    c.line(12, 8, 15, 5, "t", 2)
    c.line(17, 5, 20, 8, "t", 2)
    c.rect(14, 4, 16, 6, "t")
    return c


def formation_screen() -> Canvas:
    c = Canvas(32, 32)
    _dots(c, ((6, 16, 2), (11, 12, 2), (16, 10, 2), (21, 12, 2), (26, 16, 2)))
    c.line(13, 6, 15, 4, "t", 2)
    c.line(17, 4, 19, 6, "t", 2)
    c.rect(15, 3, 16, 5, "t")
    return c


def formation_swarm() -> Canvas:
    c = Canvas(32, 32)
    _dots(c, ((8, 9, 2), (20, 7, 1), (26, 14, 2), (10, 20, 1), (18, 18, 2),
              (14, 26, 2), (24, 24, 1)))
    return c


# --- trophy + market trends (4) -------------------------------------------------


def icon_trophy() -> Canvas:
    c = Canvas(32, 32)
    for y in range(7, 18):
        grow = (y - 7) * 19 // 10
        c.rect(10 - grow // 2, y, 21 + grow // 2, y, "a")
    c.ring(5, 11, 3, 1, "l")
    c.ring(26, 11, 3, 1, "l")
    c.rect(15, 18, 16, 22, "a")
    c.rect(10, 23, 21, 25, "a")
    c.rect(8, 25, 23, 27, "l")
    c.put(15, 11, "h")
    c.put(16, 11, "h")
    c.put(15, 12, "h")
    c.outline()
    return c


def trend_up() -> Canvas:
    c = Canvas(32, 32)
    c.line(5, 23, 12, 16, "g", 2)
    c.line(12, 16, 17, 20, "g", 2)
    c.line(17, 20, 25, 10, "g", 2)
    c.line(25, 10, 19, 10, "G", 2)
    c.line(25, 10, 25, 16, "G", 2)
    return c


def trend_down() -> Canvas:
    c = Canvas(32, 32)
    c.line(5, 9, 12, 16, "r", 2)
    c.line(12, 16, 17, 12, "r", 2)
    c.line(17, 12, 25, 22, "r", 2)
    c.line(25, 22, 19, 22, "R", 2)
    c.line(25, 22, 25, 16, "R", 2)
    return c


def event_demand() -> Canvas:
    c = Canvas(32, 32)
    for y in range(32):
        for x in range(32):
            if abs(x - 16) + abs(y - 16) <= 10:
                c.put(x, y, "a")
            if abs(x - 16) + abs(y - 16) <= 4:
                c.put(x, y, "A")
    c.rect(6, 15, 7, 16, "A")
    c.rect(24, 15, 25, 16, "A")
    c.rect(15, 5, 16, 6, "A")
    c.rect(15, 25, 16, 26, "l")
    c.put(15, 15, "h")
    return c


# ---------------------------------------------------------------------------
# Inventory assembly + emission.
# ---------------------------------------------------------------------------

GOOD_DRAW = {
    "wheat": good_wheat, "olive_oil": good_olive_oil, "wine": good_wine,
    "sugar": good_sugar, "salt": good_salt, "dried_fish": good_dried_fish,
    "cheese": good_cheese, "rice": good_rice, "coffee": good_coffee,
    "tobacco": good_tobacco, "tea": good_tea,
    "timber": good_timber, "iron": good_iron, "copper": good_copper,
    "leather": good_leather, "ceramics": good_ceramics, "pitch": good_pitch,
    "furs": good_furs, "dye_wood": good_dye_wood, "indigo": good_indigo,
    "ivory": good_ivory, "sandalwood": good_sandalwood,
    "rhubarb": good_rhubarb, "silver": good_silver, "gold": good_gold,
    "wool": good_wool, "cotton_cloth": good_cotton_cloth, "silk": good_silk,
    "carpet": good_carpet, "linen": good_linen, "raw_silk": good_raw_silk,
    "spices": good_spices, "glassware": good_glassware,
    "perfume": good_perfume, "amber": good_amber, "porcelain": good_porcelain,
    "pearls": good_pearls, "gems": good_gems, "musk": good_musk,
    "lacquerware": good_lacquerware,
}
# Fallback motif per category when a goods id lacks an override above.
GOOD_CATEGORY_MOTIF = {
    "food": lambda: _blob(*FOOD),
    "material": lambda: _chunk(*MATERIAL),
    "textile": lambda: _bolt(*TEXTILE),
    "luxury": lambda: _gem(*LUXURY),
}

EQ_DRAW = {
    "eq_cutlass": eq_cutlass, "eq_rapier": eq_rapier,
    "eq_backsword": eq_backsword, "eq_main_gauche": eq_main_gauche,
    "eq_zweihander": eq_zweihander, "eq_khair_scimitar": eq_khair_scimitar,
    "eq_breastplate": eq_breastplate, "eq_brigandine": eq_brigandine,
    "eq_three_quarter_armor": eq_three_quarter_armor,
    "eq_bloodhand_cuirass": eq_bloodhand_cuirass,
    "eq_mermaid_figurehead": eq_mermaid_figurehead,
    "eq_eagle_figurehead": eq_eagle_figurehead,
    "eq_dragon_figurehead": eq_dragon_figurehead,
    "eq_albatross_figurehead": eq_albatross_figurehead,
    "eq_angel_figurehead": eq_angel_figurehead,
    "eq_golden_dragon_figurehead": eq_golden_dragon_figurehead,
    "eq_cotton_sails": eq_cotton_sails, "eq_matting_sails": eq_matting_sails,
    "eq_storm_sails": eq_storm_sails,
    "eq_flemish_linen_sails": eq_flemish_linen_sails,
    "eq_brocade_sails": eq_brocade_sails, "eq_red_sail": eq_red_sail,
    "eq_lucky_charm": eq_lucky_charm, "eq_saint_medallion": eq_saint_medallion,
}

FLAG_DRAW = {
    "portugal": flag_portugal, "spain": flag_spain, "england": flag_england,
    "holland": flag_holland, "ottoman": flag_ottoman, "italy": flag_italy,
    "neutral": flag_neutral,
}

ICON_FILES = (
    ("hud.json", [
        declaration("coin", "assets/ui/icons/coin.png", icon_coin()),
        declaration("crew", "assets/ui/icons/crew.png", icon_crew()),
        declaration("provisions", "assets/ui/icons/provisions.png",
                    icon_provisions()),
        declaration("morale", "assets/ui/icons/morale.png", icon_morale()),
        declaration("durability", "assets/ui/icons/durability.png",
                    icon_durability()),
    ]),
    ("weather.json", [
        declaration("compass", "assets/ui/icons/compass.png", icon_compass()),
        declaration("calm", "assets/ui/icons/calm.png", icon_calm()),
        declaration("fair", "assets/ui/icons/fair.png", icon_fair()),
        declaration("strong", "assets/ui/icons/strong.png", icon_strong()),
        declaration("storm", "assets/ui/icons/storm.png", icon_storm()),
    ]),
    ("arrows_wind.json", arrow_declarations("wind_arrow", "t")),
    ("arrows_current.json", arrow_declarations("current_arrow", "c")),
    ("battle.json", [
        declaration("cannon", "assets/ui/icons/cannon.png", icon_cannon()),
        declaration("shot_round", "assets/ui/icons/shot_round.png",
                    icon_shot_round()),
        declaration("shot_chain", "assets/ui/icons/shot_chain.png",
                    icon_shot_chain()),
        declaration("shot_armor_piercing", "assets/ui/icons/shot_armor_piercing.png",
                    icon_shot_armor_piercing()),
        declaration("shot_grape", "assets/ui/icons/shot_grape.png",
                    icon_shot_grape()),
        declaration("hook", "assets/ui/icons/hook.png", icon_hook()),
        declaration("ram", "assets/ui/icons/ram.png", icon_ram()),
        declaration("surrender_flag", "assets/ui/icons/surrender_flag.png",
                    icon_surrender_flag()),
    ]),
    ("economy.json", [
        declaration("chest", "assets/ui/icons/chest.png", icon_chest()),
        declaration("scroll", "assets/ui/icons/scroll.png", icon_scroll()),
        declaration("hammer", "assets/ui/icons/hammer.png", icon_hammer()),
        declaration("bell", "assets/ui/icons/bell.png", icon_bell()),
    ]),
    ("meta.json", [
        declaration("anchor", "assets/ui/icons/anchor.png", icon_anchor()),
        declaration("hourglass", "assets/ui/icons/hourglass.png",
                    icon_hourglass()),
        declaration("save", "assets/ui/icons/save.png", icon_save()),
        declaration("skull", "assets/ui/icons/skull.png", icon_skull()),
        declaration("crown", "assets/ui/icons/crown.png", icon_crown()),
    ]),
    ("trophy.json", [
        declaration("trophy", "assets/ui/icons/trophy.png", icon_trophy()),
    ]),
    ("trends.json", [
        declaration("trend_up", "assets/ui/icons/trend_up.png", trend_up()),
        declaration("trend_down", "assets/ui/icons/trend_down.png",
                    trend_down()),
        declaration("event_demand", "assets/ui/icons/event_demand.png",
                    event_demand()),
    ]),
    ("formations.json", [
        declaration("formation_line_ahead", "assets/ui/icons/formation_line_ahead.png",
                    formation_line_ahead()),
        declaration("formation_column", "assets/ui/icons/formation_column.png",
                    formation_column()),
        declaration("formation_screen", "assets/ui/icons/formation_screen.png",
                    formation_screen()),
        declaration("formation_swarm", "assets/ui/icons/formation_swarm.png",
                    formation_swarm()),
    ]),
    ("flags.json", [
        declaration(f"flag_{nid}", f"assets/ui/icons/flag_{nid}.png",
                    draw())
        for nid, draw in FLAG_DRAW.items()
    ]),
    ("roles.json", [
        declaration("role_trader", "assets/ui/icons/role_trader.png",
                    role_trader()),
        declaration("role_coaster", "assets/ui/icons/role_coaster.png",
                    role_coaster()),
        declaration("role_courier", "assets/ui/icons/role_courier.png",
                    role_courier()),
        declaration("role_patrol", "assets/ui/icons/role_patrol.png",
                    role_patrol()),
        declaration("role_privateer", "assets/ui/icons/role_privateer.png",
                    role_privateer()),
        declaration("role_pirate", "assets/ui/icons/role_pirate.png",
                    role_pirate()),
        declaration("role_hunter", "assets/ui/icons/role_hunter.png",
                    role_hunter()),
    ]),
)


def _goods_declarations() -> list[dict]:
    goods = json.loads((REPO_ROOT / "data" / "goods.json").read_text())["goods"]
    out = []
    for good in goods:
        gid = good["id"]
        motif = GOOD_DRAW.get(gid, GOOD_CATEGORY_MOTIF[good["category"]])
        out.append(declaration(f"good_{gid}", f"assets/ui/icons/good_{gid}.png",
                               motif()))
    return out


def _equipment_declarations() -> list[dict]:
    equipment = json.loads(
        (REPO_ROOT / "data" / "equipment.json").read_text())["equipment"]
    out = []
    for item in equipment:
        eid = item["id"]
        if eid not in EQ_DRAW:
            raise SystemExit(f"gen_icons: no motif for equipment id {eid!r} "
                             "(add one to EQ_DRAW — the A.2 set is explicit)")
        out.append(declaration(eid, f"assets/ui/icons/{eid}.png", EQ_DRAW[eid]()))
    return out


def all_files() -> list[tuple[Path, dict]]:
    """(absolute manifest path, JSON payload) — the full committed set."""
    files: list[tuple[Path, dict]] = []
    chrome_sprites = chrome_declarations()
    groups: dict[str, list[dict]] = {}
    for decl in chrome_sprites:
        set_name = decl["id"].rsplit("_", 1)[0]
        groups.setdefault(set_name, []).append(decl)
    for set_name, sprites in groups.items():
        payload = {"sprites": sprites}
        files.append((ICONS_DIR.parent / "chrome" / f"{set_name}.json", payload))
    for name, sprites in ICON_FILES:
        files.append((ICONS_DIR / name, {"sprites": sprites}))
    files.append((ICONS_DIR / "goods.json", {"sprites": _goods_declarations()}))
    files.append((ICONS_DIR / "equipment.json",
                  {"sprites": _equipment_declarations()}))
    return files


def _dump(path: Path, payload: dict) -> bytes:
    text = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    return text.encode("utf-8")


def generate(target_dir: Path | None) -> dict[Path, bytes]:
    """Materialize every manifest (into `target_dir` remapping the ui_art
    part of the path — used by --check; None = the committed tree)."""
    out: dict[Path, bytes] = {}
    for path, payload in all_files():
        if target_dir is None:
            out[path] = _dump(path, payload)
        else:
            rel = path.relative_to(ICONS_DIR.parents[1])  # tools/ui_art/<...>
            out[target_dir / rel] = _dump(path, payload)
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="regenerate into a temp dir and compare every "
                             "committed manifest byte-for-byte")
    args = parser.parse_args(argv)

    generated = generate(None if not args.check
                         else Path(tempfile.mkdtemp(prefix="gen_icons_")))
    if not args.check:
        for path, blob in generated.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(blob)
            print(f"wrote {path.relative_to(REPO_ROOT)} ({len(blob)} bytes)")
        total = sum(len(payload["sprites"]) for _, payload in all_files())
        print(f"gen_icons: {total} declarations "
              f"(15 chrome + 129 icons)")
        return 0

    failures = 0
    if args.check:
        temp_root = next(iter(generated)).parents[2]  # <tmp>/ui_art/...
        pairs = [(temp_root / p.relative_to(temp_root),
                  REPO_ROOT / "tools" / p.relative_to(temp_root))
                 for p in generated]
    else:
        pairs = [(p, p) for p in generated]
    for temp_path, committed_path in pairs:
        if not committed_path.is_file():
            print(f"CHECK-FAIL missing committed manifest: {committed_path}")
            failures += 1
            continue
        if committed_path.read_bytes() != generated[temp_path]:
            print(f"CHECK-FAIL drift: {committed_path} (re-run differs from "
                  "the committed file; regenerate and commit)")
            failures += 1
    committed = {p for p in ICONS_DIR.rglob("*.json")} | {
        p for p in (ICONS_DIR.parent / "chrome").rglob("*.json")}
    expected = {committed_path for _, committed_path in pairs}
    for extra in sorted(committed - expected):
        print(f"CHECK-FAIL stale committed manifest (not generated): {extra}")
        failures += 1
    if failures:
        print(f"gen_icons --check: {failures} file(s) drifted")
        return 1
    print(f"gen_icons --check: {len(generated)} manifests byte-identical")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
