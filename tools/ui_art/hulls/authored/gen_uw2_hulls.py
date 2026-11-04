#!/usr/bin/env python3
"""gen_uw2_hulls.py — UW2-style hull authoring tool (sample slot 2, 80-* §4.8.6 amendment).

Emits the per-hull authoring docs consumed by the W3-B governor
(`tools/build_ui_art.py`): every pixel of every one of the EIGHT direction
maps is composed here — a side-view ship does not rotate losslessly, so the
docs carry `maps` × 8 (n, ne, e, se, s, sw, w, nw) and NO derive entries.

  tools/ui_art/hulls/authored/galleon.json   tier 3 — 3 masts, big stern castle
  tools/ui_art/hulls/authored/sloop.json     tier 1 — 1 mast, lateen rig

View convention (80-* §4.8.6, amended 2026-11-04):
  e/w  full side profile (hull side, gunports, masts, wind-bellied sails,
       1px rigging, crow's nests, pennant); the §4.8.7 band is measured on
       these; `w` mirrors `e` with the rig composed for the opposite tack.
  n    stern view sailing away — narrow transom, sails stacked fore-to-aft
       (smaller each), mizzen spanker lateen visible.
  s    bow view approaching — bowsprit pointing down-screen, jib triangle,
       sails edge-on from the front, forecastle.
  ne/nw/se/sw  3/4 views at a ~30° hull diagonal, masts staggered along the
       deck line, sails foreshortened on partial yards; nw/sw are the
       generator-level mirrors of ne/se (declared authored maps, not derives).

UW2 craft rules (80-* §4.8.2): <= 3 tones per material — wood H/W/L, sail
s/S/z, ink K (gunports, windows, rigging only); one specular arc per sail;
strong silhouette; light from NW; crisp pixels, sparse dither, no noisy
fills.  Pennant scheme (80-* §4.8 hull block, amended 2026-11-04): the
masthead pennants draw the authoring-only SOURCE hex `p` (#b3191f — the
governor remaps it to the owner's PENNANT_* hex; wood/sail/ink are
owner-invariant).  HULL_GOLD (`g`, #d9a441) trims the tier-3 hull's sheer
lines — hull top rail + castle/forecastle rails in e/w/diagonals, taffrail
in n/s (sloop, tier 1, gets no gold).  The authored maps are outline-less —
the governor applies the 1px HULL_INK silhouette outline (8-neighborhood),
so stays run at exactly 45° wherever they cross open sky (a shallower slope
smears under the outline).

Stdlib only.  Deterministic, byte-stable: `--check` regenerates into a temp
dir and byte-compares the committed docs; `--ascii <dir>` prints the authored
grid for review (debug aid, no files written).
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent

# ---- hull block (80-* §4.8.4) — the authored-neutral wood/sail/ink set ----

PALETTE = {
    "K": "#101010",  # HULL_INK — gunports, gallery windows, rigging stays
    "H": "#8f6d3a",  # WOOD_HI  — lit rails, strakes, mast tops (light NW)
    "W": "#7a5c2e",  # WOOD     — hull/plank base, masts, yards
    "L": "#5e4720",  # WOOD_LO  — plank seams, bilge, keel, shadow edges
    "s": "#f7f5ee",  # SAIL_HI  — the one specular arc per sail
    "S": "#e8e6df",  # SAIL     — sail body
    "z": "#c2beb2",  # SAIL_LO  — seams, leeches, shadow edges
    "p": "#b3191f",  # pennant SOURCE hex (authoring-only intermediate; the
                     # governor remaps it to the owner's PENNANT_* hex per
                     # the §4.8.4 amended hull block — never shipped as-is)
    "g": "#d9a441",  # HULL_GOLD — t3 trim (sheer/taffrail lines; galleon only)
}

DIR_ORDER = ["e", "ne", "n", "nw", "w", "sw", "s", "se"]  # §4.8.6 bucket order


class Grid:
    """A 32×32 char grid with the few primitives the compositions need."""

    def __init__(self, w: int = 32, h: int = 32):
        self.w = w
        self.h = h
        self.g = [["."] * w for _ in range(h)]

    def put(self, x: int, y: int, ch: str) -> None:
        if 0 <= x < self.w and 0 <= y < self.h:
            self.g[y][x] = ch

    def hline(self, x0: int, x1: int, y: int, ch: str) -> None:
        for x in range(min(x0, x1), max(x0, x1) + 1):
            self.put(x, y, ch)

    def line(self, x0: int, y0: int, x1: int, y1: int, ch: str) -> None:
        """1px Bresenham."""
        dx = abs(x1 - x0)
        dy = abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx - dy
        x, y = x0, y0
        while True:
            self.put(x, y, ch)
            if x == x1 and y == y1:
                break
            e2 = 2 * err
            if e2 > -dy:
                err -= dy
                x += sx
            if e2 < dx:
                err += dx
                y += sy

    def mirror_x(self) -> "Grid":
        out = Grid(self.w, self.h)
        for y in range(self.h):
            for x in range(self.w):
                out.g[y][self.w - 1 - x] = self.g[y][x]
        return out

    def rows(self) -> list[str]:
        return ["".join(row) for row in self.g]

    def extents(self) -> tuple[int, int, int, int]:
        pts = [(x, y) for y in range(self.h) for x in range(self.w)
               if self.g[y][x] != "."]
        if not pts:
            raise ValueError("empty composition")
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        return min(xs), min(ys), max(xs), max(ys)


# ---------------------------------------------------------------------------
# Shared hull/rig fragments (every direction composes from these)
# ---------------------------------------------------------------------------


def hull_side(g: Grid, x0: int, x1: int, deck: int, ports: tuple[int, ...] = (),
              tall: bool = True) -> None:
    """Side-profile hull, light from NW: lit rail, strakes, plank seams,
    bilge shadow, keel taper.  `tall` = the galleon's 7-row profile (gundeck
    row carries the gunports); slim = the 5-row tier-1 profile."""
    prof = ["H", "W", "L", "W", "L", "L"] if tall else ["H", "W", "L", "L"]
    port_y = deck + (3 if tall else 1)
    for i, ch in enumerate(prof):
        g.hline(x0, x1, deck + i, ch)
    for x in ports:
        g.put(x, port_y, "K")                  # gunports: HULL_INK 1px squares
    g.hline(x0 + 2, x1 - 2, deck + len(prof), "L")   # keel taper


def stern_castle(g: Grid, x0: int, x1: int, top: int,
                 windows2: tuple[int, ...], windows1: tuple[int, ...]) -> None:
    """Two-tier aft castle: upper tier, roof step, stern-gallery windows."""
    g.hline(x0, x1, top, "H")                  # tier-2 roof (lit)
    g.hline(x0, x1, top + 1, "W")
    for x in windows2:
        g.put(x, top + 1, "K")
    g.hline(x0, x1, top + 2, "W")
    g.hline(x0 - 1, x1 + 1, top + 3, "L")      # tier-1 roof overhang
    g.hline(x0 - 1, x1 + 1, top + 4, "H")      # tier-1 rail
    g.hline(x0 - 1, x1 + 1, top + 5, "W")
    for x in windows1:
        g.put(x, top + 5, "K")


def lantern(g: Grid, x: int, y: int) -> None:
    """Taffrail lantern: one lit bead on a short post."""
    g.put(x, y, "H")
    g.put(x, y + 1, "W")


def forecastle(g: Grid, x0: int, x1: int, rail: int) -> None:
    """Raised bow platform: lit rail over a wood face."""
    g.hline(x0, x1, rail, "H")
    g.hline(x0, x1, rail + 1, "W")


def mast(g: Grid, x: int, y_top: int, y_base: int) -> None:
    """1px mast column, lit cap (drawn before the sails that cross it)."""
    for y in range(y_top, y_base + 1):
        g.put(x, y, "W")
    g.put(x, y_top, "H")


def crow_nest(g: Grid, x0: int, x1: int, y: int) -> None:
    """Round-top platform across the mast."""
    g.put(x0 - 1, y, "L")
    g.hline(x0, x1, y, "W")
    g.put(x1 + 1, y, "L")


def yard(g: Grid, x0: int, x1: int, y: int) -> None:
    """1px horizontal spar, lit butt ends."""
    g.hline(x0, x1, y, "W")
    g.put(x0, y, "H")
    g.put(x1, y, "H")


def square_sail(g: Grid, x0: int, x1: int, y0: int, rows: int,
                seams: tuple[int, ...]) -> None:
    """Wind-bellied square sail: SAIL_HI top arc (the one specular), S body
    with SAIL_LO vertical seams, SAIL_LO leech + center belly bulge."""
    y1 = y0 + rows - 1
    g.hline(x0, x1, y0, "s")
    for y in range(y0 + 1, y1):
        g.hline(x0, x1, y, "S")
        for x in seams:
            g.put(x, y, "z")
    g.hline(x0, x1, y1, "z")
    mid = (x0 + x1) // 2
    g.hline(mid - 1, mid + 1, y1 + 1, "z")     # wind belly


def lateen(g: Grid, x_aft: int, y_aft: int, x_fwd: int, y_fwd: int,
           base: int) -> None:
    """Lateen sail under a slanted yard peaking toward the bow: S body with
    the one specular arc near the yard peak, z foot; widest aft of the yard
    mid, tapering to the peak.  Call after the hull/masts (sail is in front)."""
    d = x_fwd - x_aft
    mid = x_aft + d // 2
    for x in range(x_aft, x_fwd + 1):
        t = (x - x_aft) * (y_fwd - y_aft)
        y = y_aft + (t + d // 2) // d
        g.put(x, y, "W")                       # the yard itself
        if x == x_fwd:
            g.put(x, y, "H")                   # lit yard peak
        if x == x_aft:
            continue
        top = y + 1
        bot = base if x <= mid else base - (x - mid)
        bot = max(bot, top)
        g.put(x, top, "s" if x > mid else "S")  # specular near the peak only
        for yy in range(top + 1, bot):
            g.put(x, yy, "S")
        if bot > top:
            g.put(x, bot, "z")


def pennant(g: Grid, x_tip: int, y: int, length: int, sign: int) -> None:
    """Masthead pennant, drawn in the pennant SOURCE hex (`p`) — the governor
    remaps it to the owner's PENNANT_* hex (§4.8.4 amended hull block).
    Streams aft (`sign` -1 = toward stern)."""
    for i in range(length):
        g.put(x_tip + sign * i, y, "p")


def gold_trim(g: Grid, x0: int, x1: int, y: int) -> None:
    """1px HULL_GOLD trim line (tier-3 sheer/taffrail only)."""
    g.hline(x0, x1, y, "g")


def stay45(g: Grid, x: int, y: int, steps: int, sx: int, sy: int) -> None:
    """Standing rigging crossing open sky: EXACT 45° so the governor's
    silhouette outline reads it as a crisp line, not a smear."""
    for i in range(steps + 1):
        g.put(x + sx * i, y + sy * i, "K")


def stem_sprit(g: Grid, x_stem: int, y_stem: int, segs: int) -> None:
    """Rising stem post + bowsprit spar angling up-forward (side views)."""
    g.put(x_stem, y_stem, "H")                 # stem head
    g.put(x_stem, y_stem + 1, "W")
    for i in range(segs):
        g.put(x_stem + 1 + i, y_stem - 1 - i, "W")
    g.put(x_stem + segs, y_stem - segs, "H")   # lit sprit tip


# ---- stern view (n) fragments ---------------------------------------------


def transom(g: Grid, x0: int, x1: int, deck: int, windows: tuple[int, ...]) -> None:
    """Stern seen from astern: gallery rail + trim, windows, tuck taper."""
    g.hline(x0, x1, deck, "H")
    g.hline(x0, x1, deck + 1, "H")
    g.hline(x0, x1, deck + 2, "W")
    for x in windows:
        g.put(x, deck + 2, "K")
    g.hline(x0, x1, deck + 3, "W")
    g.hline(x0, x1, deck + 4, "L")
    g.hline(x0, x1, deck + 5, "L")
    g.hline(x0 + 1, x1 - 1, deck + 6, "L")
    g.hline(x0 + 3, x1 - 3, deck + 7, "L")


def spanker(g: Grid, x0: int, y0: int, x1: int, y1: int) -> None:
    """Mizzen spanker/lateen swung out to one side (nearest the viewer in the
    stern view): slanted yard + small sail hanging under it, s crown / S body
    / z foot, tapering to the yard peak."""
    d = x1 - x0
    mid = x0 + d // 2
    for x in range(x0, x1 + 1):
        t = (x - x0) * (y1 - y0)
        y = y0 + (t + d // 2) // d
        g.put(x, y, "W")
        if x == x1:
            g.put(x, y, "H")
        if x <= x0:
            continue
        g.put(x, y + 1, "s" if x > mid else "S")   # specular near the peak
        if x <= mid:
            g.put(x, y + 2, "S")
            g.put(x, y + 3, "z")
        else:
            g.put(x, y + 2, "z")


# ---- bow view (s) fragments -----------------------------------------------


def edge_on_sail(g: Grid, x0: int, x1: int, y0: int, y1: int) -> None:
    """Square sails seen edge-on from dead ahead: a narrow sliver, lit top,
    shadowed trailing edge (light NW)."""
    g.hline(x0, x1, y0, "s")
    for y in range(y0 + 1, y1):
        g.hline(x0, x1, y, "S")
        g.put(x1, y, "z")
    g.hline(x0, x1, y1, "z")


def jib(g: Grid, x_mast: int, y_top: int, x_tip: int, y_tip: int) -> None:
    """Jib triangle: HULL_INK stay as the leading edge, SAIL fill hugging it,
    SAIL_HI at the head, SAIL_LO clew.  The bowsprit spar is composed by the
    caller over the stay's lower run (wood over ink = spar in front)."""
    dx = x_tip - x_mast
    dy = y_tip - y_top
    first = True
    for i in range(dy + 1):
        y = y_top + i
        x = x_mast + (i * dx + dy // 2) // dy
        g.put(x, y, "K")                       # the stay itself
        if y > y_top and x - 1 > x_mast:
            g.put(x - 1, y, "s" if first else "S")
            first = False
    g.put(x_tip - 1, y_tip - 1, "z")           # clew


def bow_hull(g: Grid, x0: int, x1: int, deck: int) -> None:
    """Hull beam seen from dead ahead: rail, strakes, seams, tuck taper."""
    g.hline(x0, x1, deck, "H")
    g.hline(x0, x1, deck + 1, "W")
    g.hline(x0, x1, deck + 2, "W")
    g.hline(x0, x1, deck + 3, "L")
    g.hline(x0, x1, deck + 4, "L")
    g.hline(x0 + 1, x1 - 1, deck + 5, "L")
    g.hline(x0 + 3, x1 - 3, deck + 6, "L")


# ---- 3/4 view (diagonal) fragments ----------------------------------------


def diag_hull(g: Grid, x0: int, y0: int, x1: int, rise: int,
              body: int = 2) -> dict[int, int]:
    """Hull band at a ~30° diagonal: lit rail line, W strake, L keel row.
    Returns the rail y of every station (for masts/ports)."""
    span = x1 - x0
    rail_y = {}
    for x in range(x0, x1 + 1):
        t = x - x0
        y = y0 + (t * rise + (span // 2 if rise < 0 else span // 2)) // span
        rail_y[x] = y
        g.put(x, y, "H")
        g.put(x, y + 1, "W")
        if body >= 2:
            g.put(x, y + 2, "L")
    return rail_y


def diag_ports(g: Grid, rail_y: dict, xs: tuple[int, ...]) -> None:
    """Gunports dotted along the diagonal gundeck strake."""
    for x in xs:
        g.put(x, rail_y[x] + 1, "K")


def diag_sail(g: Grid, x0: int, x1: int, y0: int, rows: int,
              seams: tuple[int, ...]) -> None:
    """Foreshortened square sail on a partial yard (3/4 view)."""
    yard(g, x0, x1, y0)
    square_sail(g, x0 + 1, x1 - 1, y0 + 1, rows, seams)


# ---------------------------------------------------------------------------
# Galleon — tier 3: 3 masts, big two-tier stern castle, 26–30 side band
# ---------------------------------------------------------------------------


def galleon_e() -> Grid:
    """Side profile, bow right.  Authored x-extent 28 → outlined 30 (band 26-30)."""
    g = Grid()
    hull_side(g, 3, 26, 19, ports=(6, 10, 14, 18, 22))       # y19..25
    mast(g, 7, 7, 15)                                        # mizzen (behind castle)
    stern_castle(g, 3, 8, 13, windows2=(4, 6), windows1=(4, 6))
    lantern(g, 2, 12)
    forecastle(g, 22, 25, 17)
    mast(g, 19, 6, 18)                                       # fore
    mast(g, 13, 5, 18)                                       # main
    crow_nest(g, 11, 15, 7)
    crow_nest(g, 18, 20, 8)
    stay45(g, 20, 7, 8, 1, 1)                                # forestay → sprit
    stem_sprit(g, 26, 17, 3)
    yard(g, 8, 17, 10)
    square_sail(g, 9, 16, 11, 5, seams=(11, 14))
    yard(g, 16, 22, 12)
    square_sail(g, 17, 21, 13, 4, seams=(19,))
    lateen(g, 4, 10, 10, 7, base=12)                         # mizzen lateen
    pennant(g, 12, 4, 3, -1)
    pennant(g, 18, 5, 2, -1)
    # HULL_GOLD tier-3 trim: sheer line along the hull top rail + castle and
    # forecastle rails (the tier-2 roof keeps its lit wood edge)
    gold_trim(g, 3, 26, 19)      # hull top rail
    gold_trim(g, 2, 9, 17)       # stern-castle tier-1 rail
    gold_trim(g, 22, 25, 17)     # forecastle rail
    return g


def galleon_n() -> Grid:
    """Stern view sailing away: transom + sails stacked fore-to-aft + spanker."""
    g = Grid()
    mast(g, 15, 6, 16)
    pennant(g, 14, 5, 3, -1)
    square_sail(g, 12, 18, 7, 3, seams=(15,))                # fore, smallest, highest
    square_sail(g, 10, 20, 10, 6, seams=(12, 15, 18))        # main
    spanker(g, 8, 15, 15, 10)                                # mizzen lateen, port side
    transom(g, 9, 21, 17, windows=(12, 15, 18))
    gold_trim(g, 9, 21, 17)                                  # taffrail line
    return g


def galleon_s() -> Grid:
    """Bow view approaching: bowsprit down-screen, jib, edge-on sails."""
    g = Grid()
    mast(g, 14, 6, 15)
    pennant(g, 13, 5, 3, -1)
    edge_on_sail(g, 10, 12, 8, 14)                           # fore sails edge-on
    bow_hull(g, 10, 19, 18)
    forecastle(g, 11, 18, 16)
    g.put(12, 17, "K")
    g.put(17, 17, "K")
    gold_trim(g, 10, 19, 18)                                 # hull top rail (sheer)
    gold_trim(g, 11, 18, 16)                                 # forecastle rail
    jib(g, 14, 7, 20, 22)
    g.line(16, 16, 21, 22, "W")                              # bowsprit, down-screen
    g.put(21, 22, "H")
    return g


def galleon_ne() -> Grid:
    """3/4 view, bow up-right: diagonal hull, staggered masts, partial yards."""
    g = Grid()
    rail = diag_hull(g, 4, 19, 23, -9)
    diag_ports(g, rail, (8, 12, 16))
    mast(g, 8, 10, 16)
    g.hline(4, 6, 17, "H")                                   # castle block
    g.hline(4, 6, 18, "W")
    g.put(5, 18, "K")
    lantern(g, 3, 16)
    mast(g, 13, 6, 14)
    mast(g, 18, 5, 11)
    pennant(g, 12, 5, 3, -1)
    diag_sail(g, 11, 15, 7, 3, seams=(13,))
    diag_sail(g, 16, 20, 6, 3, seams=(18,))
    lateen(g, 6, 12, 10, 9, base=14)
    g.put(24, 9, "H")                                        # stem head
    g.line(25, 8, 27, 6, "W")                                # bowsprit
    g.put(27, 6, "H")
    stay45(g, 19, 5, 4, 1, 1)                                # forestay → stem
    for x, y in rail.items():                                # HULL_GOLD sheer line
        g.put(x, y, "g")
    gold_trim(g, 4, 6, 17)                                   # castle rail
    return g


def galleon_se() -> Grid:
    """3/4 view, bow down-right: honest down-heading, sails still hang."""
    g = Grid()
    rail = diag_hull(g, 4, 11, 23, 9)
    diag_ports(g, rail, (8, 12, 16))
    mast(g, 8, 4, 12)
    g.hline(4, 6, 9, "H")                                    # castle block
    g.hline(4, 6, 10, "W")
    g.put(5, 10, "K")
    lantern(g, 3, 8)
    mast(g, 13, 4, 14)
    mast(g, 18, 5, 17)
    pennant(g, 12, 3, 3, -1)
    diag_sail(g, 11, 15, 6, 3, seams=(13,))
    diag_sail(g, 16, 20, 7, 3, seams=(18,))
    lateen(g, 6, 8, 11, 10, base=11)
    g.put(24, 21, "H")                                       # stem head
    g.line(25, 22, 27, 24, "W")                              # bowsprit, down-right
    g.put(27, 24, "H")
    for x, y in rail.items():                                # HULL_GOLD sheer line
        g.put(x, y, "g")
    gold_trim(g, 4, 6, 9)                                    # castle rail
    return g


def galleon_maps() -> dict[str, Grid]:
    ne = galleon_ne()
    se = galleon_se()
    return {
        "e": galleon_e(),
        "w": galleon_e().mirror_x(),   # opposite tack, own authored map
        "n": galleon_n(),
        "s": galleon_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Sloop — tier 1: 1 mast, lateen rig, 14–18 side band
# ---------------------------------------------------------------------------


def sloop_e() -> Grid:
    """Side profile, bow right.  Authored x-extent 15 → outlined 17 (band 14-18)."""
    g = Grid()
    hull_side(g, 7, 18, 19, ports=(13,), tall=False)         # y19..23
    g.hline(7, 8, 17, "H")                                   # stub aft deck
    g.hline(7, 8, 18, "W")
    mast(g, 12, 6, 17)
    stay45(g, 13, 7, 8, 1, 1)                                # forestay → sprit tip
    g.put(19, 17, "H")                                       # stem head
    g.put(19, 18, "W")
    g.put(20, 16, "W")                                       # bowsprit
    g.put(21, 15, "H")
    lateen(g, 8, 12, 18, 7, base=13)
    pennant(g, 11, 5, 2, -1)
    return g


def sloop_n() -> Grid:
    """Stern view: narrow transom, the lateen seen from astern."""
    g = Grid()
    mast(g, 14, 6, 16)
    pennant(g, 13, 5, 2, -1)
    spanker(g, 11, 15, 15, 10)
    transom(g, 11, 18, 17, windows=(13, 16))
    return g


def sloop_s() -> Grid:
    """Bow view: bowsprit down-screen, jib, edge-on lateen sliver."""
    g = Grid()
    mast(g, 13, 6, 14)
    pennant(g, 12, 5, 2, -1)
    edge_on_sail(g, 9, 11, 8, 13)
    bow_hull(g, 9, 17, 17)
    g.hline(10, 16, 16, "H")                                 # foredeck rail
    g.put(11, 18, "K")
    g.put(15, 18, "K")
    jib(g, 13, 7, 17, 19)
    g.line(15, 16, 18, 19, "W")                              # bowsprit, down-screen
    g.put(18, 19, "H")
    return g


def sloop_ne() -> Grid:
    """3/4 view, bow up-right: short diagonal hull, one foreshortened lateen."""
    g = Grid()
    rail = diag_hull(g, 9, 17, 19, -5, body=1)
    diag_ports(g, rail, (14,))
    g.put(9, 15, "H")                                        # stub aft deck
    g.put(9, 16, "W")
    mast(g, 13, 8, 14)
    pennant(g, 12, 7, 2, -1)
    lateen(g, 10, 11, 16, 8, base=13)
    g.put(18, 12, "H")                                       # stem head
    g.line(19, 11, 21, 9, "W")                               # bowsprit
    g.put(21, 9, "H")
    stay45(g, 14, 9, 4, 1, 1)                                # forestay → stem
    return g


def sloop_se() -> Grid:
    """3/4 view, bow down-right, the lateen hanging from the slanted yard."""
    g = Grid()
    rail = diag_hull(g, 9, 13, 19, 5, body=1)
    diag_ports(g, rail, (14,))
    g.put(9, 11, "H")
    g.put(9, 12, "W")
    mast(g, 13, 7, 14)
    pennant(g, 12, 6, 2, -1)
    lateen(g, 10, 8, 16, 11, base=13)
    g.put(20, 19, "H")                                       # stem head
    g.line(21, 20, 22, 21, "W")                              # bowsprit
    g.put(22, 21, "H")
    return g


def sloop_maps() -> dict[str, Grid]:
    ne = sloop_ne()
    se = sloop_se()
    return {
        "e": sloop_e(),
        "w": sloop_e().mirror_x(),   # opposite tack, own authored map
        "n": sloop_n(),
        "s": sloop_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Doc emission
# ---------------------------------------------------------------------------

HULLS = {
    "galleon": {
        "tier": 3,
        "band": (26, 30),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment): "
                "e/w full side profile, n stern, s bow, diagonals 3/4 — "
                "all eight directions authored, no derive",
        "rig": "3 masts (fore/main square, mizzen lateen), two-tier stern "
               "castle, crow's nests, 5 gunports, 45° rigging stays",
        "maps_fn": galleon_maps,
    },
    "sloop": {
        "tier": 1,
        "band": (14, 18),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment): "
                "e/w full side profile, n stern, s bow, diagonals 3/4 — "
                "all eight directions authored, no derive",
        "rig": "1 mast, lateen main, stub aft deck, short bowsprit, jib (s)",
        "maps_fn": sloop_maps,
    },
}


def build_doc(ship: str, spec: dict) -> dict:
    grids = spec["maps_fn"]()
    maps = {}
    authored_px = {}
    for d in DIR_ORDER:
        g = grids[d]
        x0, y0, x1, y1 = g.extents()
        authored_px[d] = [x1 - x0 + 1, y1 - y0 + 1]
        maps[d] = {
            "id": f"hull_{ship}_auth_{d}",
            "mode": "string-map",
            "width": 32,
            "height": 32,
            "png": "indexed",
            "palette": dict(PALETTE),
            "rows": g.rows(),
        }
    lo, hi = spec["band"]
    return {
        "id": f"hull_{ship}",
        "class": "hulls",
        "ship_type": ship,
        "tier": spec["tier"],
        "view": spec["view"],
        "rig": spec["rig"],
        "footprint": {
            "authored_px": authored_px,
            "band": [lo, hi],
            "note": "outline adds 1px per side (tool-applied); the §4.8.7 "
                    "band is measured on the side view (e/w) long axis; "
                    "n/s/diagonals are beam/3/4 views and canvas-fit only",
        },
        "maps": maps,
    }


def generate(outdir: Path | None) -> dict[Path, bytes]:
    blobs: dict[Path, bytes] = {}
    for ship, spec in HULLS.items():
        doc = build_doc(ship, spec)
        path = (outdir or OUT_DIR) / f"{ship}.json"
        blobs[path] = (json.dumps(doc, indent=1, ensure_ascii=False)
                       + "\n").encode("utf-8")
    return blobs


def run_check() -> int:
    with tempfile.TemporaryDirectory(prefix="gen_uw2_hulls_") as td:
        generated = generate(Path(td))
        failures = 0
        for path, blob in sorted(generated.items()):
            committed = OUT_DIR / path.name
            if not committed.is_file():
                print(f"CHECK-FAIL missing committed doc: {committed}")
                failures += 1
            elif committed.read_bytes() != blob:
                print(f"CHECK-FAIL drift: {committed} (re-run differs; "
                      "regenerate and commit)")
                failures += 1
    # Ownership note: this tool owns exactly the docs it emits (galleon,
    # sloop — the UW2-re-authored hulls).  The other 14 authored/*.json are
    # legacy n/ne docs owned by their own passes and are none of its
    # business, so there is no stale-doc scan here.
    if failures:
        print(f"gen_uw2_hulls --check: {failures} file(s) drifted")
        return 1
    print(f"gen_uw2_hulls --check: {len(generated)} hull docs byte-identical "
          f"(maps x{len(DIR_ORDER)}, no derive)")
    return 0


def run_ascii(dir_id: str) -> int:
    if dir_id not in DIR_ORDER:
        print(f"unknown dir {dir_id!r}; pick one of {DIR_ORDER}")
        return 2
    for ship, spec in sorted(HULLS.items()):
        g = spec["maps_fn"]()[dir_id]
        print(f"--- {ship} '{dir_id}' (authored, outline-less) ---")
        for row in g.rows():
            print(row.replace(".", " "))
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="regenerate into a temp dir and byte-compare the "
                         "committed hull docs")
    ap.add_argument("--ascii", metavar="DIR",
                    help="print the authored grid of DIR (e/ne/n/nw/w/sw/s/se)")
    args = ap.parse_args(argv)
    if args.ascii:
        return run_ascii(args.ascii)
    if args.check:
        return run_check()
    for path, blob in generate(None).items():
        path.write_bytes(blob)
        print(f"wrote {path.relative_to(OUT_DIR.parents[3])} ({len(blob)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
