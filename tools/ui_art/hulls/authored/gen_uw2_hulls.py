#!/usr/bin/env python3
"""gen_uw2_hulls.py — UW2-style hull authoring tool (revision round, 80-* §4.8.2/6).

Emits the per-hull authoring docs consumed by the W3-B governor
(`tools/build_ui_art.py`): every pixel of every one of the EIGHT direction
maps is composed here — a side-view ship does not rotate losslessly, so the
docs carry `maps` × 8 (n, ne, e, se, s, sw, w, nw) and NO derive entries.

  tier 1 (14–18): latin, sloop, galiot, pinnace
  tier 2 (20–26): caravel, galley, brigantine, fluyt, junk, dhow,
                  caravela_redonda, xebec
  tier 3 (26–30): nao, carrack, galleon, galleass (HULL_GOLD full sheer)

View convention (80-* §4.8.6, amended 2026-11-04 — with the perspective
cheats the user pinned after the first 8-dir strip):
  e/w  full side profile (hull side, gunports, masts, wind-bellied sails,
       1px rigging, crow's nests, pennant); the §4.8.7 band is measured on
       these; `w` mirrors `e` with the rig composed for the opposite tack.
  n    stern view — mast/sail HEIGHT identical to the side view (turning
       never shrinks masts), hull at beam width (~40–60 % of the side
       length), sails stacked from astern, largest nearest.
  s    bow view — bowsprit down-screen, jib, edge-on sail slivers at FULL
       rig height, beam-width hull.
  ne/nw/se/sw  3/4 views with the standard cheat: THICK hull band (5–6 px,
       deck + gunwale readable) at a ~30° run, sails at ~70–80 % of the
       side view's sail size, presence comparable to e/w; nw/sw are the
       generator-level mirrors of ne/se (declared authored maps).

UW2 silhouette richness (80-* §4.8.2, amended 2026-11-04 — every hull,
every direction): (1) sails dominate — masthead near the canvas top edge,
hull near the bottom edge; (2) course + topsail stacked per square-rig
mast (lateen rigs keep their single big triangle, scaled up); (3) 2–3
SAIL_LO fold/band lines per sail + one SAIL_HI specular arc; national
emblems drawn in the pennant SOURCE hex `p` so the owner remap colorizes
them (cross = war hulls, roundel = trade hulls, on the largest sail of
e/w + diagonals); (4) hull stripes in pass-through pennant values
(`q` #1a8c4e, `u` #c9a227 — ≤ 2 stripes, 1px) and dense gunport rows
(≈ 1 port per 4 px of hull length); (5) HULL_GOLD runs the full sheer on
tier 3.  Pennant scheme (§4.8.4): the masthead pennants and emblems draw
the authoring-only SOURCE hex `p` (#b3191f) — the governor remaps it to
the owner's PENNANT_* hex; wood/sail/ink are owner-invariant; the stripe
values pass the remap through untouched.  The authored maps are
outline-less — the governor applies the 1px HULL_INK silhouette outline
(8-neighborhood), so stays run at exactly 45° wherever they cross open
sky (a shallower slope smears under the outline).

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
    "K": "#101010",  # HULL_INK — gunports, gallery windows, rigging stays,
                     # oar marks
    "H": "#8f6d3a",  # WOOD_HI  — lit rails, strakes, mast tops (light NW)
    "W": "#7a5c2e",  # WOOD     — hull/plank base, masts, yards
    "L": "#5e4720",  # WOOD_LO  — plank seams, bilge, keel, shadow edges
    "s": "#f7f5ee",  # SAIL_HI  — the one specular arc per sail
    "S": "#e8e6df",  # SAIL     — sail body
    "z": "#c2beb2",  # SAIL_LO  — seams, folds/leeches, shadow edges
    "p": "#b3191f",  # pennant SOURCE hex (authoring-only intermediate; the
                     # governor remaps it to the owner's PENNANT_* hex per
                     # the §4.8.4 amended hull block — never shipped as-is;
                     # masthead pennants AND sail emblems draw it)
    "g": "#d9a441",  # HULL_GOLD — t3 full sheer trim
    "q": "#1a8c4e",  # stripe green = PENNANT_PORTUGAL — a pass-through
                     # pennant value (§4.8.2 item 4): the remap leaves it
                     # untouched, so every owner keeps the same stripes
    "u": "#c9a227",  # stripe gold = PENNANT_ITALY — pass-through, as `q`
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
    bilge shadow, keel taper.  `tall` = the 7-row gundeck profile (the
    gundeck row carries the gunports); slim = the 5-row small-ship profile."""
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
                seams: tuple[int, ...] = (), folds: tuple[int, ...] = ()) -> None:
    """Wind-bellied square sail: SAIL_HI top arc (the one specular), S body,
    SAIL_LO vertical seams + SAIL_LO horizontal fold/band lines (§4.8.2 item
    3), SAIL_LO leech + center belly bulge."""
    y1 = y0 + rows - 1
    g.hline(x0, x1, y0, "s")
    for y in range(y0 + 1, y1):
        g.hline(x0, x1, y, "z" if y in folds else "S")
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


def stripe(g: Grid, x0: int, x1: int, y: int, ch: str) -> None:
    """1px sheer/gunwale stripe in a pass-through pennant value (§4.8.2
    item 4): 'q' green / 'u' gold; every owner wears the same stripes."""
    g.hline(x0, x1, y, ch)


def emblem_cross(g: Grid, cx: int, cy: int) -> None:
    """National emblem, WAR hulls: a 5px cross in the pennant SOURCE hex —
    the owner remap colorizes it (§4.8.2 item 3)."""
    g.put(cx, cy - 1, "p")
    g.put(cx - 1, cy, "p")
    g.put(cx, cy, "p")
    g.put(cx + 1, cy, "p")
    g.put(cx, cy + 1, "p")


def emblem_roundel(g: Grid, cx: int, cy: int) -> None:
    """National emblem, TRADE hulls: a 5px roundel (quincunx) in the pennant
    SOURCE hex."""
    g.put(cx, cy, "p")
    g.put(cx - 1, cy - 1, "p")
    g.put(cx + 1, cy - 1, "p")
    g.put(cx - 1, cy + 1, "p")
    g.put(cx + 1, cy + 1, "p")


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


def oar_bank(g: Grid, xs, y: int) -> None:
    """Oar bank (galiot/pinnace/galley/galleass): 1px HULL_INK marks along
    the waterline — one dot per rowing station (80-* §4.8.2 ink budget:
    rigging-class pixels)."""
    for x in xs:
        g.put(x, y, "K")


def fat_hull(g: Grid, x0: int, x1: int, deck: int,
             ports: tuple[int, ...] = ()) -> None:
    """Fluyt side profile: deep rounded belly (7 rows + keel), blunt vertical
    stern post, two plank seam rows (hulls >= 20px carry seams, §4.8.2)."""
    for i, ch in enumerate(("H", "W", "L", "W", "L", "W", "L")):
        g.hline(x0, x1, deck + i, ch)
    for y in range(deck + 1, deck + 6):
        g.put(x0, y, "L")                      # blunt stern post
    for x in ports:
        g.put(x, deck + 3, "K")                # gundeck row
    g.hline(x0 + 2, x1 - 2, deck + 7, "L")     # rounded belly keel


def batten_sail(g: Grid, x0: int, x1: int, y0: int, rows: int,
                battens: tuple[int, ...] = (), seams: tuple[int, ...] = ()) -> None:
    """Junk full-batten sail: a segmented rectangle — SAIL panels divided by
    full-width SAIL_LO batten lines, SAIL_HI top edge (the one specular),
    optional SAIL_LO seam columns."""
    y1 = y0 + rows - 1
    g.hline(x0, x1, y0, "s")
    for y in range(y0 + 1, y1):
        g.hline(x0, x1, y, "z" if y in battens else "S")
        for x in seams:
            g.put(x, y, "z")
    g.hline(x0, x1, y1, "z")


def gaff_sail(g: Grid, x_mast: int, x_peak: int, y_mast: int, y_peak: int,
              y_boom: int) -> None:
    """Fore-and-aft spanker (side views): gaff spar rising aft-up to a lit
    peak, horizontal boom, sail sheeted between — s crown on the peak half,
    S body, z foot.  `x_peak` < `x_mast` (bow right)."""
    g.line(x_mast, y_mast, x_peak, y_peak, "W")    # the gaff spar
    g.put(x_peak, y_peak, "H")                     # lit peak
    g.hline(x_peak, x_mast, y_boom, "W")           # boom
    mid = (x_peak + x_mast) // 2
    for x in range(x_peak, x_mast + 1):
        top = y_peak + (x - x_peak) * (y_mast - y_peak) // (x_mast - x_peak)
        g.put(x, top + 1, "s" if x <= mid else "S")
        for yy in range(top + 2, y_boom):
            g.put(x, yy, "S")
        if y_boom - 1 > top + 1:
            g.put(x, y_boom - 1, "z")


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


def edge_on_sail(g: Grid, x0: int, x1: int, y0: int, y1: int,
                 folds: tuple[int, ...] = ()) -> None:
    """Square sails seen edge-on from dead ahead: a narrow sliver at FULL rig
    height, lit top, SAIL_LO fold bands + shadowed trailing edge (light NW)."""
    g.hline(x0, x1, y0, "s")
    for y in range(y0 + 1, y1):
        g.hline(x0, x1, y, "z" if y in folds else "S")
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


# ---- 3/4 view (diagonal) fragments — §4.8.6 perspective cheat --------------


def diag_hull_thick(g: Grid, x0: int, x1: int, y0: int,
                    rise: int) -> dict[int, int]:
    """THICK hull band at a ~30° diagonal (the §4.8.6 cheat — the run reads
    the heading, the band keeps the ship present): lit rail, W gunwale, L
    seam, W strake, L bilge — 5px deep, deck + gunwale readable.  Returns
    the rail y of every station."""
    span = x1 - x0
    rail_y = {}
    for x in range(x0, x1 + 1):
        t = x - x0
        y = y0 + (t * rise + span // 2) // span
        rail_y[x] = y
        g.put(x, y, "H")
        g.put(x, y + 1, "W")
        g.put(x, y + 2, "L")
        g.put(x, y + 3, "W")
        g.put(x, y + 4, "L")
    return rail_y


def diag_ports_y(g: Grid, rail: dict, xs, off: int = 2) -> None:
    """Gunports dotted along the diagonal gundeck row (thick band)."""
    for x in xs:
        g.put(x, rail[x] + off, "K")


def diag_stripe(g: Grid, rail: dict, off: int, ch: str) -> None:
    """1px hull stripe running the diagonal gunwale (§4.8.2 item 4)."""
    for x in rail:
        g.put(x, rail[x] + off, ch)


def diag_stack(g: Grid, x0: int, y0: int, x1: int, y1: int, rows: int,
               seams: tuple[int, ...] = (), folds: tuple[int, ...] = ()) -> None:
    """Stacked square sail on a ~30° slanted yard (3/4 view): the yard runs
    parallel to the hull diagonal; the sail hangs as a slanted mass at
    ~70-80 % of the side view's sail size — s arc on the peak half of row 1,
    S body, z fold bands parallel to the yard, z seam columns, z foot."""
    span = x1 - x0
    g.line(x0, y0, x1, y1, "W")                # the slanted yard
    g.put(x0, y0, "H")                         # lit butt
    g.put(x1, y1, "H")                         # lit peak (up-hill end)
    mid = (x0 + x1) // 2
    for x in range(x0, x1 + 1):
        yt = y0 + ((x - x0) * (y1 - y0) + span // 2) // span
        for r in range(1, rows + 1):
            if r == rows:
                ch = "z"                       # foot
            elif r in folds:
                ch = "z"                       # fold band, parallel to yard
            elif r == 1:
                ch = "s" if x > mid else "S"   # specular near the peak half
            else:
                ch = "S"
            if x in seams and 1 < r < rows:
                ch = "z"
            g.put(x, yt + r, ch)


# ---------------------------------------------------------------------------
# Galleon — tier 3: 3 masts, big two-tier stern castle, 26–30 side band
# ---------------------------------------------------------------------------


def galleon_e() -> Grid:
    """Side profile, bow right.  Authored x-extent 28 → outlined 30 (band 26-30)."""
    g = Grid()
    hull_side(g, 3, 26, 19, ports=(5, 9, 13, 17, 21, 24))    # y19..25, dense ports
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
    square_sail(g, 9, 16, 11, 5, seams=(11, 14), folds=(13,))
    yard(g, 16, 22, 12)
    square_sail(g, 17, 21, 13, 4, seams=(19,), folds=(15,))
    lateen(g, 4, 10, 10, 7, base=12)                         # mizzen lateen
    pennant(g, 12, 4, 3, -1)
    pennant(g, 18, 5, 2, -1)
    emblem_cross(g, 12, 13)                                  # war hull, main course
    # HULL_GOLD tier-3 FULL sheer: hull top rail + castle and
    # forecastle rails (the tier-2 roof keeps its lit wood edge)
    gold_trim(g, 3, 26, 19)      # hull top rail
    gold_trim(g, 2, 9, 17)       # stern-castle tier-1 rail
    gold_trim(g, 22, 25, 17)     # forecastle rail
    return g


def galleon_n() -> Grid:
    """Stern view sailing away — FULL rig height, beam-width transom:
    sails stacked fore-to-aft, largest nearest, spanker swung out."""
    g = Grid()
    mast(g, 15, 5, 18)                                       # mainmast, e height
    pennant(g, 14, 4, 3, -1)
    square_sail(g, 11, 19, 6, 3, seams=(15,), folds=(7,))    # fore topsail
    square_sail(g, 9, 21, 9, 4, seams=(13, 17), folds=(11,))  # fore course
    square_sail(g, 10, 20, 13, 3, seams=(15,), folds=(14,))  # main topsail
    square_sail(g, 8, 22, 16, 3, seams=(11, 19), folds=(17,))  # main course
    spanker(g, 8, 17, 15, 9)                                 # mizzen, tall
    transom(g, 9, 22, 19, windows=(11, 14, 17, 20))          # beam ~14 (50 %)
    gold_trim(g, 9, 22, 19)                                  # taffrail line
    return g


def galleon_s() -> Grid:
    """Bow view approaching — bowsprit down-screen, jib, FULL-height
    edge-on sails, beam-width hull + forecastle."""
    g = Grid()
    mast(g, 15, 5, 18)                                       # mainmast, e height
    pennant(g, 14, 4, 3, -1)
    edge_on_sail(g, 10, 12, 6, 17, folds=(9, 12, 15))        # fore sails, full height
    edge_on_sail(g, 18, 20, 7, 16, folds=(10, 13))           # main sails, full height
    bow_hull(g, 9, 20, 19)                                   # beam ~12 (43 %)
    forecastle(g, 10, 19, 17)
    g.put(12, 20, "K")
    g.put(18, 20, "K")
    gold_trim(g, 9, 20, 19)                                  # hull top rail
    gold_trim(g, 10, 19, 17)                                 # forecastle rail
    jib(g, 15, 6, 21, 21)
    g.line(17, 18, 22, 23, "W")                              # bowsprit, down-screen
    g.put(22, 23, "H")
    return g


def galleon_ne() -> Grid:
    """3/4 view, bow up-right — THICK hull band at ~30°, staggered masts,
    sails at ~75 % of the side view's, emblem + gold sheer."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 19, -9)
    diag_ports_y(g, rail, (8, 12, 16, 20), 2)
    mast(g, 8, 9, 18)                                        # mizzen
    g.hline(4, 6, 17, "H")                                   # castle block
    g.hline(4, 6, 18, "W")
    g.put(5, 18, "K")
    lantern(g, 3, 16)
    lateen(g, 5, 14, 11, 10, base=16)                        # mizzen lateen
    pennant(g, 7, 8, 2, -1)
    mast(g, 13, 5, 16)                                       # main
    diag_stack(g, 10, 6, 16, 5, 3, seams=(13,))              # main topsail
    diag_stack(g, 9, 10, 17, 8, 4, seams=(12, 14), folds=(2,))  # main course
    pennant(g, 12, 4, 3, -1)
    mast(g, 18, 4, 14)                                       # fore
    diag_stack(g, 15, 6, 21, 5, 3, seams=(18,))              # fore topsail
    diag_stack(g, 14, 10, 20, 8, 4, seams=(16, 18), folds=(2,))  # fore course
    pennant(g, 17, 3, 2, -1)
    emblem_cross(g, 13, 11)                                  # largest sail
    g.put(24, 9, "H")                                        # stem head
    g.line(25, 8, 27, 6, "W")                                # bowsprit
    g.put(27, 6, "H")
    stay45(g, 19, 5, 4, 1, 1)                                # forestay → stem
    for x, y in rail.items():                                # HULL_GOLD sheer line
        g.put(x, y, "g")
    gold_trim(g, 4, 6, 17)                                   # castle rail
    return g


def galleon_se() -> Grid:
    """3/4 view, bow down-right — honest down-heading, sails still hang."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 11, 9)
    diag_ports_y(g, rail, (8, 12, 16, 20), 2)
    mast(g, 8, 5, 14)                                        # mizzen
    g.hline(4, 6, 9, "H")                                    # castle block
    g.hline(4, 6, 10, "W")
    g.put(5, 10, "K")
    lantern(g, 3, 8)
    lateen(g, 5, 10, 11, 14, base=16)                        # mizzen lateen
    pennant(g, 7, 4, 2, -1)
    mast(g, 13, 4, 16)                                       # main
    diag_stack(g, 10, 5, 16, 7, 3, seams=(13,))              # main topsail
    diag_stack(g, 9, 9, 17, 11, 4, seams=(12, 14), folds=(2,))  # main course
    pennant(g, 12, 3, 3, -1)
    mast(g, 18, 5, 19)                                       # fore
    diag_stack(g, 15, 6, 21, 8, 3, seams=(18,))              # fore topsail
    diag_stack(g, 14, 10, 20, 12, 4, seams=(16, 18), folds=(2,))  # fore course
    pennant(g, 17, 4, 2, -1)
    emblem_cross(g, 13, 11)                                  # largest sail
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
    hull_side(g, 7, 18, 20, tall=False)                      # y20..24
    g.hline(7, 8, 18, "H")                                   # stub aft deck
    g.hline(7, 8, 19, "W")
    mast(g, 12, 4, 18)                                       # masthead near the top
    stay45(g, 13, 5, 8, 1, 1)                                # forestay → sprit tip
    g.put(19, 18, "H")                                       # stem head
    g.put(19, 19, "W")
    g.put(20, 17, "W")                                       # bowsprit
    g.put(21, 16, "H")
    lateen(g, 7, 14, 19, 5, base=18)                         # BIG lateen (rule 1)
    pennant(g, 11, 3, 2, -1)
    emblem_roundel(g, 12, 13)                                # trade hull
    return g


def sloop_n() -> Grid:
    """Stern view — full-height lateen triangle, beam-width transom."""
    g = Grid()
    mast(g, 14, 4, 19)                                       # e height
    pennant(g, 13, 3, 2, -1)
    spanker(g, 9, 13, 17, 5)                                 # tall lateen
    transom(g, 11, 18, 20, windows=(13, 16))                 # beam ~8 (53 %)
    return g


def sloop_s() -> Grid:
    """Bow view — bowsprit down-screen, the lateen sliver at FULL height."""
    g = Grid()
    mast(g, 13, 4, 18)
    pennant(g, 12, 3, 2, -1)
    edge_on_sail(g, 9, 12, 6, 17, folds=(9, 12, 15))         # full-height sliver
    bow_hull(g, 9, 17, 20)
    g.hline(10, 16, 19, "H")                                 # foredeck rail
    g.put(11, 21, "K")
    g.put(15, 21, "K")
    jib(g, 13, 5, 17, 19)
    g.line(15, 19, 18, 22, "W")                              # bowsprit, down-screen
    g.put(18, 22, "H")
    return g


def sloop_ne() -> Grid:
    """3/4 view, bow up-right — thick band, the lateen at ~75 %."""
    g = Grid()
    rail = diag_hull_thick(g, 9, 17, 20, -4)
    g.put(9, 18, "H")                                        # stub aft deck
    g.put(9, 19, "W")
    mast(g, 13, 6, 21)
    pennant(g, 12, 5, 2, -1)
    lateen(g, 10, 12, 16, 8, base=15)
    emblem_roundel(g, 13, 12)
    g.put(18, 15, "H")                                       # stem head
    g.line(19, 14, 21, 12, "W")                              # bowsprit
    g.put(21, 12, "H")
    stay45(g, 14, 7, 4, 1, 1)                                # forestay → stem
    return g


def sloop_se() -> Grid:
    """3/4 view, bow down-right — the lateen hanging off the slanted yard."""
    g = Grid()
    rail = diag_hull_thick(g, 9, 17, 18, 4)
    g.put(9, 16, "H")                                        # stub aft deck
    g.put(9, 17, "W")
    mast(g, 13, 6, 19)
    pennant(g, 12, 5, 2, -1)
    lateen(g, 10, 8, 16, 12, base=15)
    emblem_roundel(g, 13, 11)
    g.put(18, 23, "H")                                       # stem head
    g.line(19, 24, 20, 25, "W")                              # bowsprit
    g.put(20, 25, "H")
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
# Latin — tier 1: 1 mast, BIG lateen (the triangle dominates), 14–18 band
# ---------------------------------------------------------------------------


def latin_e() -> Grid:
    """Side profile, bow right.  Authored x-extent 15 -> outlined 17."""
    g = Grid()
    hull_side(g, 7, 18, 20, tall=False)                      # y20..24
    mast(g, 12, 4, 18)                                       # masthead near the top
    stay45(g, 13, 5, 8, 1, 1)                                # forestay -> sprit tip
    g.put(19, 18, "H")                                       # stem head
    g.put(19, 19, "W")
    g.put(20, 17, "W")                                       # bowsprit
    g.put(21, 16, "H")
    lateen(g, 7, 15, 19, 4, base=18)                         # the big triangle
    pennant(g, 11, 3, 2, -1)
    emblem_roundel(g, 12, 13)                                # trade hull
    return g


def latin_n() -> Grid:
    """Stern view — full-height lateen triangle, beam-width transom."""
    g = Grid()
    mast(g, 14, 4, 19)
    pennant(g, 13, 3, 2, -1)
    spanker(g, 9, 14, 17, 5)                                 # tall lateen
    transom(g, 11, 18, 20, windows=(13, 16))                 # beam ~8 (53 %)
    return g


def latin_s() -> Grid:
    """Bow view — bowsprit down-screen, the lateen sliver at FULL height."""
    g = Grid()
    mast(g, 13, 4, 18)
    pennant(g, 12, 3, 2, -1)
    edge_on_sail(g, 9, 12, 6, 17, folds=(9, 12, 15))         # wide full-height sliver
    bow_hull(g, 10, 17, 20)
    g.hline(11, 16, 19, "H")                                 # foredeck rail
    g.put(11, 21, "K")
    g.put(15, 21, "K")
    g.line(15, 19, 18, 22, "W")                              # bowsprit, down-screen
    g.put(18, 22, "H")
    return g


def latin_ne() -> Grid:
    """3/4 view, bow up-right — the lateen dominates the thick band."""
    g = Grid()
    rail = diag_hull_thick(g, 9, 17, 20, -4)
    mast(g, 13, 6, 21)
    pennant(g, 12, 5, 2, -1)
    lateen(g, 10, 12, 16, 7, base=15)
    emblem_roundel(g, 13, 12)
    g.put(18, 15, "H")                                       # stem head
    g.line(19, 14, 21, 12, "W")                              # bowsprit
    g.put(21, 12, "H")
    stay45(g, 14, 7, 4, 1, 1)                                # forestay -> stem
    return g


def latin_se() -> Grid:
    """3/4 view, bow down-right — the lateen hanging off the slanted yard."""
    g = Grid()
    rail = diag_hull_thick(g, 9, 17, 18, 4)
    mast(g, 13, 6, 19)
    pennant(g, 12, 5, 2, -1)
    lateen(g, 10, 8, 16, 12, base=15)
    emblem_roundel(g, 13, 11)
    g.put(18, 23, "H")                                       # stem head
    g.line(19, 24, 20, 25, "W")                              # bowsprit
    g.put(20, 25, "H")
    return g


def latin_maps() -> dict[str, Grid]:
    ne = latin_ne()
    se = latin_se()
    return {
        "e": latin_e(),
        "w": latin_e().mirror_x(),   # opposite tack, own authored map
        "n": latin_n(),
        "s": latin_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Galiot — tier 1: compact hull, small lateen, 4-station oar bank
# ---------------------------------------------------------------------------


def galiot_e() -> Grid:
    """Side profile, bow right.  Authored x-extent 14 -> outlined 16."""
    g = Grid()
    hull_side(g, 8, 19, 20, tall=False)                      # y20..24
    oar_bank(g, (9, 12, 15, 18), 22)                         # waterline dots
    stripe(g, 8, 19, 21, "q")                                # gunwale stripe
    mast(g, 13, 5, 18)
    g.put(20, 18, "H")                                       # stem head
    g.put(20, 19, "W")
    g.put(21, 17, "H")                                       # short bowsprit
    lateen(g, 10, 13, 17, 5, base=16)                        # small lateen, scaled up
    pennant(g, 12, 4, 2, -1)
    emblem_roundel(g, 13, 12)                                # trade hull
    return g


def galiot_n() -> Grid:
    """Stern view — full-height lateen, oar blades showing either side."""
    g = Grid()
    mast(g, 15, 5, 19)
    pennant(g, 14, 4, 2, -1)
    spanker(g, 11, 12, 17, 6)                                # small lateen, tall
    oar_bank(g, (10, 21), 22)                                # blades out
    oar_bank(g, (10, 21), 23)
    transom(g, 12, 19, 20, windows=(14, 17))                 # beam ~8
    return g


def galiot_s() -> Grid:
    """Bow view — stub mast, full-height sliver, oar tips flanking."""
    g = Grid()
    mast(g, 13, 5, 18)
    pennant(g, 12, 4, 2, -1)
    edge_on_sail(g, 10, 12, 7, 16, folds=(10, 13))           # full-height sliver
    bow_hull(g, 10, 17, 20)
    g.hline(11, 16, 19, "H")                                 # foredeck rail
    oar_bank(g, (7, 19), 21)                                 # tips out
    oar_bank(g, (7, 19), 23)
    return g


def galiot_ne() -> Grid:
    """3/4 view, bow up-right — oar dots on the thick band."""
    g = Grid()
    rail = diag_hull_thick(g, 9, 16, 20, -4)
    for x in (11, 14):                                       # oar dots
        g.put(x, rail[x] + 3, "K")
    mast(g, 13, 6, 21)
    pennant(g, 12, 5, 2, -1)
    lateen(g, 10, 12, 15, 8, base=14)
    emblem_roundel(g, 12, 12)
    g.put(17, 15, "H")                                       # stem head
    g.line(18, 14, 19, 13, "W")                              # bowsprit
    g.put(19, 13, "H")
    return g


def galiot_se() -> Grid:
    """3/4 view, bow down-right — small lateen on the slanted yard."""
    g = Grid()
    rail = diag_hull_thick(g, 9, 16, 18, 4)
    for x in (11, 14):                                       # oar dots
        g.put(x, rail[x] + 3, "K")
    mast(g, 13, 6, 19)
    pennant(g, 12, 5, 2, -1)
    lateen(g, 10, 8, 15, 12, base=14)
    emblem_roundel(g, 12, 11)
    g.put(17, 23, "H")                                       # stem head
    g.line(18, 24, 19, 25, "W")                              # bowsprit
    g.put(19, 25, "H")
    return g


def galiot_maps() -> dict[str, Grid]:
    ne = galiot_ne()
    se = galiot_se()
    return {
        "e": galiot_e(),
        "w": galiot_e().mirror_x(),  # opposite tack, own authored map
        "n": galiot_n(),
        "s": galiot_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Pinnace — tier 1: oars ONLY, no sail; two banks; mast stub w/ pennant
# ---------------------------------------------------------------------------


def pinnace_e() -> Grid:
    """Side profile, bow right.  Authored x-extent 13 -> outlined 15."""
    g = Grid()
    hull_side(g, 8, 19, 20, tall=False)                      # y20..24
    stripe(g, 8, 19, 21, "u")                                # gunwale stripe
    oar_bank(g, (9, 12, 15, 18), 22)                         # upper bank
    oar_bank(g, (11, 14, 17), 23)                            # lower bank, staggered
    mast(g, 13, 9, 18)                                       # stub, no sail
    pennant(g, 12, 8, 2, -1)
    g.put(20, 18, "H")                                       # stem head
    g.put(20, 19, "W")
    return g


def pinnace_n() -> Grid:
    """Stern view — naked hull, oar blades out on both sides."""
    g = Grid()
    mast(g, 15, 9, 19)                                       # stub
    pennant(g, 14, 8, 2, -1)
    oar_bank(g, (10, 21), 21)                                # upper bank tips
    oar_bank(g, (10, 21), 23)                                # lower bank tips
    transom(g, 12, 19, 20, windows=(14, 17))                 # beam ~8
    return g


def pinnace_s() -> Grid:
    """Bow view — no canvas at all: hull, stub mast, oar tips flanking."""
    g = Grid()
    mast(g, 14, 9, 17)                                       # stub
    pennant(g, 13, 8, 2, -1)
    bow_hull(g, 11, 18, 20)
    g.hline(12, 17, 19, "H")                                 # foredeck rail
    oar_bank(g, (8, 21), 21)                                 # upper bank tips
    oar_bank(g, (8, 21), 23)                                 # lower bank tips
    return g


def pinnace_ne() -> Grid:
    """3/4 view, bow up-right — two oar-dot banks on the thick band."""
    g = Grid()
    rail = diag_hull_thick(g, 10, 16, 20, -3)
    for x in (11, 13, 15):                                   # oar dots
        g.put(x, rail[x] + 3, "K")
    mast(g, 13, 10, 21)                                      # stub
    pennant(g, 12, 9, 2, -1)
    g.put(18, 16, "H")                                       # stem head
    g.line(19, 15, 20, 14, "W")                              # bowsprit
    g.put(20, 14, "H")
    return g


def pinnace_se() -> Grid:
    """3/4 view, bow down-right — stub mast, oar dots, no canvas."""
    g = Grid()
    rail = diag_hull_thick(g, 10, 16, 19, 3)
    for x in (11, 13, 15):                                   # oar dots
        g.put(x, rail[x] + 3, "K")
    mast(g, 13, 10, 20)                                      # stub
    pennant(g, 12, 9, 2, -1)
    g.put(18, 23, "H")                                       # stem head
    g.line(19, 24, 20, 25, "W")                              # bowsprit
    g.put(20, 25, "H")
    return g


def pinnace_maps() -> dict[str, Grid]:
    ne = pinnace_ne()
    se = pinnace_se()
    return {
        "e": pinnace_e(),
        "w": pinnace_e().mirror_x(),  # opposite tack, own authored map
        "n": pinnace_n(),
        "s": pinnace_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Caravel — tier 2: 2 lateens (scaled up), rounded high-prow hull, 20–26 band
# ---------------------------------------------------------------------------


def caravel_e() -> Grid:
    """Side profile, bow right.  Authored x-extent 23 -> outlined 25."""
    g = Grid()
    hull_side(g, 4, 23, 19, ports=(6, 10, 14, 18, 22), tall=True)   # y19..25
    g.put(24, 16, "H")                                       # high rounded prow
    g.put(24, 17, "W")
    g.put(24, 18, "W")
    g.put(25, 15, "W")                                       # bowsprit
    g.put(26, 14, "H")
    stripe(g, 4, 23, 20, "q")                                # gunwale stripe
    mast(g, 9, 5, 17)                                        # aft
    mast(g, 17, 4, 17)                                       # fwd
    lateen(g, 5, 14, 13, 5, base=17)                         # aft lateen, scaled up
    lateen(g, 13, 12, 22, 4, base=16)                        # fwd lateen, scaled up
    pennant(g, 8, 4, 2, -1)
    pennant(g, 16, 3, 2, -1)
    emblem_roundel(g, 17, 10)                                # trade hull, fwd lateen
    return g


def caravel_n() -> Grid:
    """Stern view — full-height lateens stacked from astern, largest nearest."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 2, -1)
    spanker(g, 10, 8, 18, 4)                                 # fwd lateen, high
    spanker(g, 8, 13, 18, 6)                                 # aft lateen, big + near
    transom(g, 10, 21, 19, windows=(12, 15, 18))             # beam ~12 (52 %)
    return g


def caravel_s() -> Grid:
    """Bow view — high prow, FULL-height lateen slivers, bowsprit down."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 2, -1)
    edge_on_sail(g, 10, 12, 6, 17, folds=(9, 12, 15))        # aft lateen sliver
    edge_on_sail(g, 17, 19, 7, 16, folds=(10, 13))           # fwd lateen sliver
    bow_hull(g, 10, 21, 19)
    g.hline(11, 20, 18, "H")                                 # foredeck rail
    g.put(15, 16, "W")                                       # rising stem post
    g.put(15, 15, "H")
    g.line(17, 18, 21, 22, "W")                              # bowsprit, down-screen
    g.put(21, 22, "H")
    return g


def caravel_ne() -> Grid:
    """3/4 view, bow up-right — thick band, two scaled lateens."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 17, -7)
    diag_ports_y(g, rail, (8, 12, 16, 20), 2)
    diag_stripe(g, rail, 1, "q")                             # gunwale stripe
    g.hline(4, 5, 15, "H")                                   # raised aft deck
    g.hline(4, 5, 16, "W")
    mast(g, 9, 6, 18)
    mast(g, 17, 5, 18)
    pennant(g, 8, 5, 2, -1)
    pennant(g, 16, 4, 2, -1)
    lateen(g, 6, 13, 12, 9, base=16)                         # aft lateen
    lateen(g, 14, 11, 21, 7, base=15)                        # fwd lateen
    emblem_roundel(g, 17, 11)                                # largest sail
    g.put(24, 9, "H")                                        # high stem head
    g.line(25, 8, 26, 7, "W")                                # bowsprit
    g.put(26, 7, "H")
    return g


def caravel_se() -> Grid:
    """3/4 view, bow down-right — the lateens hanging from slanted yards."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 13, 7)
    diag_ports_y(g, rail, (8, 12, 16, 20), 2)
    diag_stripe(g, rail, 1, "q")                             # gunwale stripe
    g.hline(4, 5, 11, "H")                                   # raised aft deck
    g.hline(4, 5, 12, "W")
    mast(g, 9, 6, 15)
    mast(g, 17, 5, 16)
    pennant(g, 8, 5, 2, -1)
    pennant(g, 16, 4, 2, -1)
    lateen(g, 6, 9, 12, 13, base=16)                         # aft lateen
    lateen(g, 14, 8, 21, 12, base=15)                        # fwd lateen
    emblem_roundel(g, 17, 11)                                # largest sail
    g.put(24, 21, "H")                                       # high stem head
    g.line(25, 22, 26, 23, "W")                              # bowsprit
    g.put(26, 23, "H")
    return g


def caravel_maps() -> dict[str, Grid]:
    ne = caravel_ne()
    se = caravel_se()
    return {
        "e": caravel_e(),
        "w": caravel_e().mirror_x(),  # opposite tack, own authored map
        "n": caravel_n(),
        "s": caravel_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Galley — tier 2: LONG low hull, 7 oar stations, big lateen + square topsail
# ---------------------------------------------------------------------------


def galley_e() -> Grid:
    """Side profile, bow right — the longest tier-2 hull.  Authored x-extent
    24 -> outlined 26 (band top)."""
    g = Grid()
    hull_side(g, 3, 25, 19, tall=False)                      # y19..23, LOW
    oar_bank(g, (5, 8, 11, 14, 17, 20, 23), 22)              # 7 stations
    stripe(g, 3, 25, 20, "u")                                # gunwale stripe
    mast(g, 16, 4, 17)
    yard(g, 12, 20, 6)                                       # topsail yard
    square_sail(g, 13, 19, 7, 3, seams=(16,), folds=(8,))    # square topsail
    lateen(g, 8, 15, 23, 5, base=17)                         # the BIG lateen
    pennant(g, 15, 3, 3, -1)
    emblem_cross(g, 15, 12)                                  # war hull, on the lateen
    g.put(26, 18, "H")                                       # stem head
    g.put(26, 19, "W")
    return g


def galley_n() -> Grid:
    """Stern view — full-height lateen + topsail, oar blades out, long beam."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 3, -1)
    square_sail(g, 12, 19, 6, 3, seams=(16,), folds=(7,))    # square topsail
    spanker(g, 9, 13, 19, 5)                                 # the big lateen
    oar_bank(g, (9, 22), 22)                                 # blades out
    oar_bank(g, (9, 22), 23)
    transom(g, 11, 20, 19, windows=(13, 16, 18))             # beam ~10
    return g


def galley_s() -> Grid:
    """Bow view — wide low hull, one FULL-height lateen sliver, oar tips."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 3, -1)
    edge_on_sail(g, 12, 18, 6, 17, folds=(9, 12, 15))        # wide sliver, full height
    bow_hull(g, 10, 21, 19)
    g.hline(11, 20, 18, "H")                                 # foredeck rail
    oar_bank(g, (8, 23), 20)                                 # tips out
    oar_bank(g, (8, 23), 22)
    g.line(17, 18, 21, 22, "W")                              # bowsprit, down-screen
    g.put(21, 22, "H")
    return g


def galley_ne() -> Grid:
    """3/4 view, bow up-right — the long thick diagonal, oar dots, lateen."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 24, 18, -6)
    for x in (7, 10, 13, 16, 19, 22):                        # oar dots
        g.put(x, rail[x] + 3, "K")
    diag_stripe(g, rail, 1, "u")                             # gunwale stripe
    mast(g, 14, 5, 16)
    diag_stack(g, 12, 6, 17, 7, 2, seams=(15,))              # square topsail
    pennant(g, 13, 4, 3, -1)
    lateen(g, 9, 11, 21, 7, base=15)                         # the BIG lateen
    emblem_cross(g, 14, 11)                                  # war hull
    g.put(25, 11, "H")                                       # stem head
    g.line(26, 10, 27, 9, "W")                               # bowsprit
    g.put(27, 9, "H")
    stay45(g, 15, 6, 4, 1, 1)                                # forestay -> stem
    return g


def galley_se() -> Grid:
    """3/4 view, bow down-right — lateen + topsail hanging, oar dots."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 24, 12, 6)
    for x in (7, 10, 13, 16, 19, 22):                        # oar dots
        g.put(x, rail[x] + 3, "K")
    diag_stripe(g, rail, 1, "u")                             # gunwale stripe
    mast(g, 14, 6, 18)
    diag_stack(g, 12, 7, 17, 9, 2, seams=(15,))              # square topsail
    pennant(g, 13, 5, 3, -1)
    lateen(g, 9, 8, 21, 13, base=15)                         # the BIG lateen
    emblem_cross(g, 14, 12)                                  # war hull
    g.put(25, 19, "H")                                       # stem head
    g.line(26, 20, 27, 21, "W")                              # bowsprit
    g.put(27, 21, "H")
    return g


def galley_maps() -> dict[str, Grid]:
    ne = galley_ne()
    se = galley_se()
    return {
        "e": galley_e(),
        "w": galley_e().mirror_x(),  # opposite tack, own authored map
        "n": galley_n(),
        "s": galley_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Brigantine — tier 2: course+topsail (fore) + fore-and-aft spanker (main)
# ---------------------------------------------------------------------------


def brigantine_e() -> Grid:
    """Side profile, bow right.  Authored x-extent 23 -> outlined 25."""
    g = Grid()
    hull_side(g, 4, 23, 19, ports=(6, 10, 14, 18, 22), tall=True)   # y19..25
    stripe(g, 4, 23, 20, "q")                                # gunwale stripe
    mast(g, 9, 5, 17)                                        # fore: course+topsail
    yard(g, 6, 12, 7)
    square_sail(g, 7, 11, 8, 3, seams=(9,), folds=(9,))
    yard(g, 6, 12, 11)
    square_sail(g, 7, 11, 12, 5, seams=(9,), folds=(14,))
    mast(g, 16, 4, 17)                                       # main: spanker
    gaff_sail(g, 16, 12, 8, 6, 15)
    pennant(g, 8, 4, 2, -1)
    pennant(g, 15, 3, 2, -1)
    emblem_cross(g, 9, 14)                                   # war hull, fore course
    g.put(24, 18, "H")                                       # stem head
    g.put(24, 19, "W")
    g.put(25, 17, "W")                                       # bowsprit
    g.put(26, 16, "H")
    return g


def brigantine_n() -> Grid:
    """Stern view — fore course+topsail stacked high, spanker swung out."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 2, -1)
    square_sail(g, 12, 18, 6, 2, seams=(15,))                # fore topsail
    square_sail(g, 10, 20, 8, 3, seams=(15,), folds=(9,))    # fore course
    spanker(g, 7, 14, 16, 6)                                 # main spanker, tall
    transom(g, 10, 21, 19, windows=(12, 15, 18))             # beam ~12 (52 %)
    return g


def brigantine_s() -> Grid:
    """Bow view — FULL-height edge-on squares, jib, bowsprit down-screen."""
    g = Grid()
    mast(g, 14, 4, 18)
    pennant(g, 13, 3, 2, -1)
    edge_on_sail(g, 11, 13, 6, 17, folds=(9, 12, 15))        # fore sliver
    edge_on_sail(g, 16, 18, 7, 16, folds=(10, 13))           # main sliver
    bow_hull(g, 10, 21, 19)
    g.hline(11, 20, 18, "H")                                 # foredeck rail
    g.put(12, 20, "K")
    g.put(17, 20, "K")
    jib(g, 14, 6, 19, 20)
    g.line(16, 18, 20, 22, "W")                              # bowsprit, down-screen
    g.put(20, 22, "H")
    return g


def brigantine_ne() -> Grid:
    """3/4 view, bow up-right — fore sails foreshortened, spanker aback."""
    g = Grid()
    rail = diag_hull_thick(g, 5, 22, 18, -6)
    diag_ports_y(g, rail, (9, 13, 17), 2)
    diag_stripe(g, rail, 1, "q")                             # gunwale stripe
    mast(g, 9, 8, 17)                                        # fore
    diag_stack(g, 6, 9, 11, 10, 3, seams=(8,))               # fore topsail
    diag_stack(g, 5, 13, 11, 15, 4, seams=(7, 9), folds=(2,))  # fore course
    mast(g, 15, 6, 16)                                       # main
    gaff_sail(g, 15, 11, 10, 8, 14)                          # spanker
    pennant(g, 8, 7, 2, -1)
    pennant(g, 14, 5, 2, -1)
    emblem_cross(g, 8, 14)                                   # war hull
    g.put(23, 11, "H")                                       # stem head
    g.line(24, 10, 25, 9, "W")                               # bowsprit
    g.put(25, 9, "H")
    stay45(g, 16, 7, 4, 1, 1)                                # forestay -> stem
    return g


def brigantine_se() -> Grid:
    """3/4 view, bow down-right — sails still hang on the down-heading."""
    g = Grid()
    rail = diag_hull_thick(g, 5, 22, 12, 6)
    diag_ports_y(g, rail, (9, 13, 17), 2)
    diag_stripe(g, rail, 1, "q")                             # gunwale stripe
    mast(g, 9, 8, 15)                                        # fore
    diag_stack(g, 6, 10, 11, 12, 3, seams=(8,))              # fore topsail
    diag_stack(g, 5, 14, 11, 16, 4, seams=(7, 9), folds=(2,))  # fore course
    mast(g, 15, 6, 18)                                       # main
    gaff_sail(g, 15, 11, 11, 9, 15)                          # spanker
    pennant(g, 8, 7, 2, -1)
    pennant(g, 14, 5, 2, -1)
    emblem_cross(g, 8, 15)                                   # war hull
    g.put(23, 19, "H")                                       # stem head
    g.line(24, 20, 25, 21, "W")                              # bowsprit
    g.put(25, 21, "H")
    return g


def brigantine_maps() -> dict[str, Grid]:
    ne = brigantine_ne()
    se = brigantine_se()
    return {
        "e": brigantine_e(),
        "w": brigantine_e().mirror_x(),  # opposite tack, own authored map
        "n": brigantine_n(),
        "s": brigantine_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Fluyt — tier 2: FAT beam, 3 masts x (course+topsail), blunt stern
# ---------------------------------------------------------------------------


def fluyt_e() -> Grid:
    """Side profile, bow right — the fat belly is the signature; six sail
    masses.  Authored x-extent 23 -> outlined 25."""
    g = Grid()
    fat_hull(g, 5, 24, 19, ports=(8, 13, 18, 23))            # y19..26, FAT
    g.hline(5, 8, 17, "H")                                   # high round stern
    g.hline(5, 8, 18, "W")
    stripe(g, 5, 24, 20, "u")                                # gunwale stripe
    mast(g, 9, 5, 17)                                        # aft
    mast(g, 15, 4, 17)                                       # main
    mast(g, 21, 5, 16)                                       # fwd
    yard(g, 7, 11, 7)
    square_sail(g, 8, 10, 8, 3, seams=(9,), folds=(9,))      # aft topsail
    yard(g, 7, 11, 11)
    square_sail(g, 8, 10, 12, 5, seams=(9,), folds=(14,))    # aft course
    yard(g, 11, 19, 6)
    square_sail(g, 12, 18, 7, 3, seams=(15,), folds=(8,))    # main topsail
    yard(g, 11, 19, 10)
    square_sail(g, 12, 18, 11, 6, seams=(14, 17), folds=(13, 15))  # main course
    yard(g, 18, 24, 7)
    square_sail(g, 19, 23, 8, 3, seams=(21,), folds=(9,))    # fwd topsail
    yard(g, 18, 24, 11)
    square_sail(g, 19, 23, 12, 5, seams=(21,), folds=(14,))  # fwd course
    stay45(g, 22, 5, 5, 1, 1)                                # forestay -> sprit
    g.put(25, 18, "H")                                       # stem head
    g.put(25, 19, "W")
    g.put(26, 17, "W")                                       # bowsprit
    g.put(27, 16, "H")
    pennant(g, 8, 4, 2, -1)
    pennant(g, 14, 3, 3, -1)
    pennant(g, 20, 4, 2, -1)
    emblem_roundel(g, 15, 14)                                # trade hull, main course
    return g


def fluyt_n() -> Grid:
    """Stern view — the FAT beam (widest transom) + the six-sail tower."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 3, -1)
    square_sail(g, 12, 18, 6, 2, seams=(15,))                # fore topsail
    square_sail(g, 10, 20, 8, 3, seams=(15,), folds=(9,))    # fore course
    square_sail(g, 11, 19, 10, 3, seams=(15,), folds=(11,))  # main topsail
    square_sail(g, 8, 22, 12, 5, seams=(11, 15, 19), folds=(14, 16))  # main course
    square_sail(g, 10, 20, 15, 2, seams=(15,))               # fwd topsail
    square_sail(g, 9, 21, 16, 2, seams=(15,))                # fwd course
    transom(g, 9, 22, 19, windows=(11, 14, 17, 20))          # FAT 14px beam
    return g


def fluyt_s() -> Grid:
    """Bow view — widest bow hull, FULL-height slivers, jib, bowsprit down."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 2, -1)
    edge_on_sail(g, 10, 12, 6, 17, folds=(9, 12, 15))        # aft sliver
    edge_on_sail(g, 18, 20, 7, 16, folds=(10, 13))           # fwd sliver
    bow_hull(g, 9, 22, 19)                                   # FAT 14px beam
    g.hline(10, 21, 18, "H")                                 # foredeck rail
    g.put(12, 20, "K")
    g.put(19, 20, "K")
    jib(g, 15, 6, 20, 20)
    g.line(17, 18, 21, 22, "W")                              # bowsprit, down-screen
    g.put(21, 22, "H")
    return g


def fluyt_ne() -> Grid:
    """3/4 view, bow up-right — deep diagonal belly, six slanted sails."""
    g = Grid()
    rail = diag_hull_thick(g, 6, 23, 18, -6)
    for x in range(7, 23):                                   # belly row
        g.put(x, rail[x] + 5, "L")
    diag_stripe(g, rail, 1, "u")                             # gunwale stripe
    diag_ports_y(g, rail, (10, 14, 19), 2)
    g.hline(6, 8, 16, "H")                                   # high round stern
    g.hline(6, 8, 17, "W")
    mast(g, 10, 7, 18)                                       # aft
    diag_stack(g, 8, 8, 12, 9, 3, seams=(10,))               # aft topsail
    diag_stack(g, 7, 12, 13, 14, 4, seams=(9, 11), folds=(2,))  # aft course
    mast(g, 15, 5, 16)                                       # main
    diag_stack(g, 12, 6, 18, 7, 3, seams=(15,))              # main topsail
    diag_stack(g, 11, 10, 19, 12, 5, seams=(13, 17), folds=(2,))  # main course
    mast(g, 20, 7, 15)                                       # fwd
    diag_stack(g, 17, 8, 23, 9, 3, seams=(20,))              # fwd topsail
    diag_stack(g, 16, 12, 22, 14, 4, seams=(18, 20), folds=(2,))  # fwd course
    pennant(g, 9, 6, 2, -1)
    pennant(g, 14, 4, 3, -1)
    pennant(g, 19, 6, 2, -1)
    emblem_roundel(g, 15, 13)                                # largest sail
    g.put(24, 11, "H")                                       # stem head
    g.line(25, 10, 26, 9, "W")                               # bowsprit
    g.put(26, 9, "H")
    stay45(g, 21, 6, 4, 1, 1)                                # forestay -> stem
    return g


def fluyt_se() -> Grid:
    """3/4 view, bow down-right — belly hangs honest, sails stacked."""
    g = Grid()
    rail = diag_hull_thick(g, 6, 23, 12, 6)
    for x in range(7, 23):                                   # belly row
        g.put(x, rail[x] + 5, "L")
    diag_stripe(g, rail, 1, "u")                             # gunwale stripe
    diag_ports_y(g, rail, (10, 14, 19), 2)
    g.hline(6, 8, 10, "H")                                   # high round stern
    g.hline(6, 8, 11, "W")
    mast(g, 10, 7, 15)                                       # aft
    diag_stack(g, 8, 9, 12, 11, 3, seams=(10,))              # aft topsail
    diag_stack(g, 7, 13, 13, 15, 4, seams=(9, 11), folds=(2,))  # aft course
    mast(g, 15, 5, 17)                                       # main
    diag_stack(g, 12, 7, 18, 9, 3, seams=(15,))              # main topsail
    diag_stack(g, 11, 11, 19, 15, 5, seams=(13, 17), folds=(2,))  # main course
    mast(g, 20, 7, 18)                                       # fwd
    diag_stack(g, 17, 9, 23, 11, 3, seams=(20,))             # fwd topsail
    diag_stack(g, 16, 13, 22, 17, 4, seams=(18, 20), folds=(2,))  # fwd course
    pennant(g, 9, 6, 2, -1)
    pennant(g, 14, 4, 3, -1)
    pennant(g, 19, 6, 2, -1)
    emblem_roundel(g, 15, 15)                                # largest sail
    g.put(24, 19, "H")                                       # stem head
    g.line(25, 20, 26, 21, "W")                              # bowsprit
    g.put(26, 21, "H")
    return g


def fluyt_maps() -> dict[str, Grid]:
    ne = fluyt_ne()
    se = fluyt_se()
    return {
        "e": fluyt_e(),
        "w": fluyt_e().mirror_x(),   # opposite tack, own authored map
        "n": fluyt_n(),
        "s": fluyt_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Junk — tier 2: 3 masts x 2 full-batten sails (6 masses), fan-tail stern
# ---------------------------------------------------------------------------


def junk_e() -> Grid:
    """Side profile, bow right — battens segment every sail, stern fans up.
    Authored x-extent 23 -> outlined 25."""
    g = Grid()
    hull_side(g, 6, 23, 19, tall=True)                       # y19..25
    g.put(4, 16, "H")                                        # fan-tail peak
    g.hline(4, 5, 17, "H")
    g.hline(4, 6, 18, "W")
    stripe(g, 6, 23, 20, "u")                                # gunwale stripe
    mast(g, 10, 5, 17)                                       # aft
    mast(g, 15, 4, 17)                                       # main
    mast(g, 20, 5, 17)                                       # fwd
    batten_sail(g, 8, 12, 7, 3)                              # aft topsail
    batten_sail(g, 8, 12, 11, 5, battens=(13,), seams=(9, 11))   # aft course
    batten_sail(g, 13, 17, 6, 3)                             # main topsail
    batten_sail(g, 13, 17, 10, 6, battens=(12, 14), seams=(15,))  # main course
    batten_sail(g, 18, 22, 7, 3)                             # fwd topsail
    batten_sail(g, 18, 22, 11, 5, battens=(13,), seams=(19, 21))  # fwd course
    pennant(g, 9, 4, 2, -1)
    pennant(g, 14, 3, 3, -1)
    pennant(g, 19, 4, 2, -1)
    emblem_roundel(g, 15, 13)                                # trade hull, main course
    g.put(24, 18, "H")                                       # stem head
    g.put(24, 19, "W")
    g.put(25, 17, "W")                                       # bowsprit
    g.put(26, 16, "H")
    return g


def junk_n() -> Grid:
    """Stern view — fan-tail flare, the battened sail tower stacked."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 3, -1)
    batten_sail(g, 12, 18, 6, 2)                             # fwd topsail
    batten_sail(g, 10, 20, 8, 4, battens=(9, 11))            # fwd course
    batten_sail(g, 11, 19, 11, 2)                            # main topsail
    batten_sail(g, 8, 22, 12, 4, battens=(13, 15))           # main course
    batten_sail(g, 10, 20, 15, 2)                            # aft topsail
    g.hline(8, 23, 18, "H")                                  # fan-tail flare
    transom(g, 9, 22, 19, windows=(11, 15, 19))              # beam ~14
    return g


def junk_s() -> Grid:
    """Bow view — FULL-height battened slivers, bowsprit down, no jib."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 2, -1)
    edge_on_sail(g, 10, 12, 6, 17, folds=(9, 12, 15))        # aft sliver
    edge_on_sail(g, 18, 20, 7, 16, folds=(10, 13))           # fwd sliver
    bow_hull(g, 10, 21, 19)
    g.hline(11, 20, 18, "H")                                 # foredeck rail
    g.line(17, 18, 21, 22, "W")                              # bowsprit, down-screen
    g.put(21, 22, "H")
    return g


def junk_ne() -> Grid:
    """3/4 view, bow up-right — battens on the slanted yards, fan stern."""
    g = Grid()
    rail = diag_hull_thick(g, 5, 22, 18, -6)
    diag_stripe(g, rail, 1, "u")                             # gunwale stripe
    g.put(5, 15, "H")                                        # fan-tail peak
    g.hline(5, 6, 16, "H")
    g.hline(5, 7, 17, "W")
    mast(g, 10, 6, 18)                                       # aft
    diag_stack(g, 8, 7, 12, 8, 3)                            # aft topsail
    diag_stack(g, 7, 11, 13, 13, 4, seams=(9, 11), folds=(2,))  # aft course
    mast(g, 15, 4, 16)                                       # main
    diag_stack(g, 12, 5, 18, 6, 3)                           # main topsail
    diag_stack(g, 11, 9, 19, 11, 5, seams=(13, 17), folds=(2,))  # main course
    mast(g, 20, 6, 15)                                       # fwd
    diag_stack(g, 17, 7, 23, 8, 3)                           # fwd topsail
    diag_stack(g, 16, 11, 22, 13, 4, seams=(18, 20), folds=(2,))  # fwd course
    pennant(g, 9, 5, 2, -1)
    pennant(g, 14, 3, 3, -1)
    pennant(g, 19, 5, 2, -1)
    emblem_roundel(g, 15, 13)                                # largest sail
    g.put(23, 11, "H")                                       # stem head
    g.line(24, 10, 25, 9, "W")                               # bowsprit
    g.put(25, 9, "H")
    return g


def junk_se() -> Grid:
    """3/4 view, bow down-right — battened sails on the down-heading."""
    g = Grid()
    rail = diag_hull_thick(g, 5, 22, 12, 6)
    diag_stripe(g, rail, 1, "u")                             # gunwale stripe
    g.put(5, 10, "H")                                        # fan-tail peak
    g.hline(5, 6, 11, "H")
    mast(g, 10, 6, 15)                                       # aft
    diag_stack(g, 8, 8, 12, 10, 3)                           # aft topsail
    diag_stack(g, 7, 11, 13, 15, 4, seams=(9, 11), folds=(2,))  # aft course
    mast(g, 15, 5, 17)                                       # main
    diag_stack(g, 12, 6, 18, 8, 3)                           # main topsail
    diag_stack(g, 11, 10, 19, 14, 5, seams=(13, 17), folds=(2,))  # main course
    mast(g, 20, 6, 18)                                       # fwd
    diag_stack(g, 17, 8, 23, 10, 3)                          # fwd topsail
    diag_stack(g, 16, 12, 22, 16, 4, seams=(18, 20), folds=(2,))  # fwd course
    pennant(g, 9, 5, 2, -1)
    pennant(g, 14, 4, 3, -1)
    pennant(g, 19, 5, 2, -1)
    emblem_roundel(g, 15, 14)                                # largest sail
    g.put(23, 19, "H")                                       # stem head
    g.line(24, 20, 25, 21, "W")                              # bowsprit
    g.put(25, 21, "H")
    return g


def junk_maps() -> dict[str, Grid]:
    ne = junk_ne()
    se = junk_se()
    return {
        "e": junk_e(),
        "w": junk_e().mirror_x(),    # opposite tack, own authored map
        "n": junk_n(),
        "s": junk_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Dhow — tier 2: slim, 1 BIG lateen, sharp prow
# ---------------------------------------------------------------------------


def dhow_e() -> Grid:
    """Side profile, bow right — sharp rising prow.  Authored x-extent
    21 -> outlined 23."""
    g = Grid()
    hull_side(g, 5, 22, 19, tall=False)                      # y19..23, slim
    g.put(23, 16, "H")                                       # sharp prow
    g.put(23, 17, "W")
    g.put(23, 18, "W")
    g.put(24, 15, "W")                                       # bowsprit
    g.put(25, 14, "H")
    stripe(g, 5, 22, 20, "q")                                # gunwale stripe
    mast(g, 13, 4, 17)
    lateen(g, 6, 15, 22, 4, base=17)                         # THE big lateen
    pennant(g, 12, 3, 2, -1)
    emblem_roundel(g, 13, 12)                                # trade hull
    return g


def dhow_n() -> Grid:
    """Stern view — narrow transom, the big lateen at FULL height."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 2, -1)
    spanker(g, 8, 14, 19, 4)                                 # big lateen, tall
    transom(g, 11, 20, 19, windows=(13, 16))                 # beam ~10
    return g


def dhow_s() -> Grid:
    """Bow view — one wide FULL-height lateen sliver, sharp prow, sprit."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 2, -1)
    edge_on_sail(g, 12, 18, 6, 17, folds=(9, 12, 15))        # one wide sliver
    bow_hull(g, 11, 20, 19)
    g.hline(12, 19, 18, "H")                                 # foredeck rail
    g.put(15, 17, "H")                                       # prow point
    g.line(17, 18, 20, 21, "W")                              # bowsprit, down-screen
    g.put(20, 21, "H")
    return g


def dhow_ne() -> Grid:
    """3/4 view, bow up-right — the big lateen over the thick slim band."""
    g = Grid()
    rail = diag_hull_thick(g, 8, 17, 17, -5)
    diag_ports_y(g, rail, (13,), 2)
    diag_stripe(g, rail, 1, "q")                             # gunwale stripe
    mast(g, 13, 5, 18)
    pennant(g, 12, 4, 2, -1)
    lateen(g, 9, 11, 17, 6, base=15)
    emblem_roundel(g, 13, 11)                                # largest sail
    g.put(18, 11, "H")                                       # sharp stem head
    g.line(19, 10, 21, 8, "W")                               # bowsprit
    g.put(21, 8, "H")
    stay45(g, 14, 6, 4, 1, 1)                                # forestay -> stem
    return g


def dhow_se() -> Grid:
    """3/4 view, bow down-right — the lateen hangs off the slanted yard."""
    g = Grid()
    rail = diag_hull_thick(g, 8, 17, 13, 5)
    diag_ports_y(g, rail, (13,), 2)
    diag_stripe(g, rail, 1, "q")                             # gunwale stripe
    mast(g, 13, 5, 18)
    pennant(g, 12, 4, 2, -1)
    lateen(g, 9, 6, 17, 12, base=15)
    emblem_roundel(g, 13, 11)                                # largest sail
    g.put(18, 19, "H")                                       # sharp stem head
    g.line(19, 20, 21, 22, "W")                              # bowsprit
    g.put(21, 22, "H")
    return g


def dhow_maps() -> dict[str, Grid]:
    ne = dhow_ne()
    se = dhow_se()
    return {
        "e": dhow_e(),
        "w": dhow_e().mirror_x(),    # opposite tack, own authored map
        "n": dhow_n(),
        "s": dhow_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Caravela redonda — tier 2: 2 square stacks + 1 lateen (3 masts)
# ---------------------------------------------------------------------------


def caravela_redonda_e() -> Grid:
    """Side profile, bow right.  Authored x-extent 23 -> outlined 25."""
    g = Grid()
    hull_side(g, 4, 23, 19, ports=(6, 10, 14, 18, 22), tall=True)   # y19..25
    g.hline(4, 5, 17, "H")                                   # raised aft deck
    g.hline(4, 5, 18, "W")
    stripe(g, 4, 23, 20, "u")                                # gunwale stripe
    mast(g, 8, 5, 17)                                        # fore square
    mast(g, 14, 4, 17)                                       # main square
    mast(g, 19, 5, 17)                                       # mizzen lateen
    yard(g, 5, 11, 7)
    square_sail(g, 6, 10, 8, 3, seams=(8,), folds=(9,))      # fore topsail
    yard(g, 5, 11, 11)
    square_sail(g, 6, 10, 12, 5, seams=(8,), folds=(14,))    # fore course
    yard(g, 11, 17, 6)
    square_sail(g, 12, 16, 7, 3, seams=(14,), folds=(8,))    # main topsail
    yard(g, 11, 17, 10)
    square_sail(g, 12, 16, 11, 6, seams=(13, 15), folds=(12, 14))  # main course
    lateen(g, 16, 12, 23, 5, base=16)                        # mizzen lateen
    pennant(g, 7, 4, 2, -1)
    pennant(g, 13, 3, 2, -1)
    pennant(g, 18, 4, 2, -1)
    emblem_roundel(g, 14, 13)                                # trade hull, main course
    forecastle(g, 21, 23, 16)
    g.put(24, 18, "H")                                       # stem head
    g.put(24, 19, "W")
    g.put(25, 17, "W")                                       # bowsprit
    g.put(26, 16, "H")
    return g


def caravela_redonda_n() -> Grid:
    """Stern view — square stacks high, mizzen lateen swung out below."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 2, -1)
    square_sail(g, 12, 18, 6, 2, seams=(15,))                # fore topsail
    square_sail(g, 10, 20, 8, 3, seams=(15,), folds=(9,))    # fore course
    square_sail(g, 11, 19, 10, 3, seams=(15,), folds=(11,))  # main topsail
    square_sail(g, 9, 21, 12, 4, seams=(13, 18), folds=(13,))  # main course
    spanker(g, 7, 14, 14, 7)                                 # mizzen lateen
    transom(g, 10, 21, 19, windows=(12, 15, 18))             # beam ~12 (52 %)
    return g


def caravela_redonda_s() -> Grid:
    """Bow view — FULL-height square slivers + lateen, jib, bowsprit down."""
    g = Grid()
    mast(g, 14, 4, 18)
    pennant(g, 13, 3, 2, -1)
    edge_on_sail(g, 10, 12, 6, 17, folds=(9, 12, 15))        # fore sliver
    edge_on_sail(g, 16, 18, 7, 16, folds=(10, 13))           # main sliver
    bow_hull(g, 10, 21, 19)
    g.hline(11, 20, 18, "H")                                 # foredeck rail
    jib(g, 14, 6, 19, 20)
    g.line(16, 18, 20, 22, "W")                              # bowsprit, down-screen
    g.put(20, 22, "H")
    return g


def caravela_redonda_ne() -> Grid:
    """3/4 view, bow up-right — 2 foreshortened stacks + lateen mizzen."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 17, -7)
    diag_ports_y(g, rail, (8, 12, 16, 20), 2)
    diag_stripe(g, rail, 1, "u")                             # gunwale stripe
    g.hline(4, 5, 15, "H")                                   # raised aft deck
    g.hline(4, 5, 16, "W")
    mast(g, 9, 7, 17)                                        # fore
    diag_stack(g, 6, 8, 12, 9, 3, seams=(9,))                # fore topsail
    diag_stack(g, 5, 12, 11, 14, 4, seams=(7, 10), folds=(2,))  # fore course
    mast(g, 14, 5, 15)                                       # main
    diag_stack(g, 11, 6, 17, 7, 3, seams=(14,))              # main topsail
    diag_stack(g, 10, 10, 16, 12, 4, seams=(12, 14), folds=(2,))  # main course
    mast(g, 19, 6, 13)                                       # mizzen
    lateen(g, 16, 13, 22, 9, base=16)                        # mizzen lateen
    pennant(g, 8, 6, 2, -1)
    pennant(g, 13, 4, 2, -1)
    pennant(g, 18, 5, 2, -1)
    emblem_roundel(g, 13, 12)                                # largest sail
    g.put(24, 9, "H")                                        # stem head
    g.line(25, 8, 26, 7, "W")                                # bowsprit
    g.put(26, 7, "H")
    return g


def caravela_redonda_se() -> Grid:
    """3/4 view, bow down-right — stacks + lateen hanging honest."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 13, 7)
    diag_ports_y(g, rail, (8, 12, 16, 20), 2)
    diag_stripe(g, rail, 1, "u")                             # gunwale stripe
    g.hline(4, 5, 11, "H")                                   # raised aft deck
    g.hline(4, 5, 12, "W")
    mast(g, 9, 7, 14)                                        # fore
    diag_stack(g, 6, 8, 12, 10, 3, seams=(9,))               # fore topsail
    diag_stack(g, 5, 12, 11, 14, 4, seams=(7, 10), folds=(2,))  # fore course
    mast(g, 14, 5, 16)                                       # main
    diag_stack(g, 11, 6, 17, 8, 3, seams=(14,))              # main topsail
    diag_stack(g, 10, 10, 16, 12, 4, seams=(12, 14), folds=(2,))  # main course
    mast(g, 19, 6, 17)                                       # mizzen
    lateen(g, 16, 9, 22, 13, base=16)                        # mizzen lateen
    pennant(g, 8, 6, 2, -1)
    pennant(g, 13, 4, 2, -1)
    pennant(g, 18, 5, 2, -1)
    emblem_roundel(g, 13, 11)                                # largest sail
    g.put(24, 21, "H")                                       # stem head
    g.line(25, 22, 26, 23, "W")                              # bowsprit
    g.put(26, 23, "H")
    return g


def caravela_redonda_maps() -> dict[str, Grid]:
    ne = caravela_redonda_ne()
    se = caravela_redonda_se()
    return {
        "e": caravela_redonda_e(),
        "w": caravela_redonda_e().mirror_x(),  # opposite tack, authored map
        "n": caravela_redonda_n(),
        "s": caravela_redonda_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Xebec — tier 2: narrow, 3 BIG lateens on 3 masts (the signature overlap)
# ---------------------------------------------------------------------------


def xebec_e() -> Grid:
    """Side profile, bow right — three overlapping lateen yards.
    Authored x-extent 22 -> outlined 24."""
    g = Grid()
    hull_side(g, 4, 23, 19, tall=False)                      # y19..23, narrow
    stripe(g, 4, 23, 20, "q")                                # gunwale stripe
    mast(g, 8, 5, 17)                                        # aft
    mast(g, 13, 4, 17)                                       # mid
    mast(g, 18, 5, 17)                                       # fwd
    lateen(g, 5, 15, 12, 4, base=17)                         # aft lateen, scaled up
    lateen(g, 10, 14, 17, 4, base=17)                        # mid lateen, scaled up
    lateen(g, 15, 13, 22, 4, base=16)                        # fwd lateen, scaled up
    pennant(g, 7, 4, 2, -1)
    pennant(g, 12, 3, 2, -1)
    pennant(g, 17, 4, 2, -1)
    emblem_roundel(g, 13, 12)                                # trade hull, mid lateen
    g.put(24, 18, "H")                                       # stem head
    g.put(24, 19, "W")
    g.put(25, 17, "H")                                       # short bowsprit
    return g


def xebec_n() -> Grid:
    """Stern view — narrow transom, the three lateens stacked FULL height."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 3, -1)
    spanker(g, 11, 8, 18, 4)                                 # fwd lateen, high
    spanker(g, 9, 11, 17, 6)                                 # mid lateen
    spanker(g, 7, 14, 16, 9)                                 # aft lateen
    transom(g, 11, 20, 19, windows=(13, 16))                 # beam ~10
    return g


def xebec_s() -> Grid:
    """Bow view — three FULL-height lateen slivers across the beam."""
    g = Grid()
    edge_on_sail(g, 9, 11, 6, 16, folds=(9, 12))             # aft sliver
    edge_on_sail(g, 13, 15, 6, 17, folds=(9, 12, 15))        # mid sliver
    edge_on_sail(g, 17, 19, 7, 16, folds=(10, 13))           # fwd sliver
    mast(g, 14, 4, 18)
    pennant(g, 13, 3, 3, -1)
    bow_hull(g, 11, 20, 19)
    g.hline(12, 19, 18, "H")                                 # foredeck rail
    g.line(16, 18, 20, 22, "W")                              # bowsprit, down-screen
    g.put(20, 22, "H")
    return g


def xebec_ne() -> Grid:
    """3/4 view, bow up-right — the three lateen yards staggering uphill."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 17, -6)
    diag_stripe(g, rail, 1, "q")                             # gunwale stripe
    mast(g, 8, 7, 18)                                        # aft
    mast(g, 13, 5, 18)                                       # mid
    mast(g, 18, 6, 16)                                       # fwd
    lateen(g, 5, 14, 11, 9, base=16)                         # aft lateen
    lateen(g, 10, 13, 17, 8, base=16)                        # mid lateen
    lateen(g, 15, 12, 21, 8, base=15)                        # fwd lateen
    pennant(g, 7, 6, 2, -1)
    pennant(g, 12, 4, 2, -1)
    pennant(g, 17, 5, 2, -1)
    emblem_roundel(g, 13, 13)                                # largest sail
    g.put(24, 10, "H")                                       # stem head
    g.line(25, 9, 26, 8, "W")                                # bowsprit
    g.put(26, 8, "H")
    return g


def xebec_se() -> Grid:
    """3/4 view, bow down-right — the three yards slanting downhill."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 11, 6)
    diag_stripe(g, rail, 1, "q")                             # gunwale stripe
    mast(g, 8, 7, 15)                                        # aft
    mast(g, 13, 6, 17)                                       # mid
    mast(g, 18, 7, 19)                                       # fwd
    lateen(g, 5, 9, 11, 14, base=16)                         # aft lateen
    lateen(g, 10, 8, 17, 13, base=16)                        # mid lateen
    lateen(g, 15, 9, 21, 13, base=15)                        # fwd lateen
    pennant(g, 7, 6, 2, -1)
    pennant(g, 12, 5, 2, -1)
    pennant(g, 17, 6, 2, -1)
    emblem_roundel(g, 13, 12)                                # largest sail
    g.put(24, 18, "H")                                       # stem head
    g.line(25, 19, 26, 20, "W")                              # bowsprit
    g.put(26, 20, "H")
    return g


def xebec_maps() -> dict[str, Grid]:
    ne = xebec_ne()
    se = xebec_se()
    return {
        "e": xebec_e(),
        "w": xebec_e().mirror_x(),   # opposite tack, own authored map
        "n": xebec_n(),
        "s": xebec_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Nao — tier 3: 3 masts x (course+topsail), big fore/aft castles, gold sheer
# ---------------------------------------------------------------------------


def nao_e() -> Grid:
    """Side profile, bow right.  Authored x-extent 28 -> outlined 30."""
    g = Grid()
    hull_side(g, 2, 24, 19, ports=(4, 8, 12, 16, 20, 23), tall=True)  # y19..25
    mast(g, 8, 6, 15)                                        # mizzen (behind castle)
    square_sail(g, 6, 10, 14, 3, seams=(8,))                 # mizzen course (castle covers)
    stern_castle(g, 2, 7, 13, windows2=(3, 5), windows1=(3, 5))
    lantern(g, 1, 12)
    yard(g, 5, 11, 8)                                        # mizzen topsail yard
    square_sail(g, 6, 10, 9, 3, seams=(8,), folds=(10,))     # mizzen topsail
    forecastle(g, 20, 24, 16)                                # big fore castle
    mast(g, 19, 5, 18)                                       # fore
    mast(g, 13, 4, 18)                                       # main
    crow_nest(g, 11, 15, 6)
    crow_nest(g, 18, 20, 6)
    stay45(g, 20, 6, 7, 1, 1)                                # forestay -> sprit
    stem_sprit(g, 25, 17, 3)
    yard(g, 8, 18, 7)
    square_sail(g, 9, 17, 8, 3, seams=(13, 15), folds=(9,))  # main topsail
    yard(g, 8, 18, 11)
    square_sail(g, 9, 17, 12, 6, seams=(11, 15), folds=(14, 16))  # main course
    yard(g, 15, 23, 8)
    square_sail(g, 16, 22, 9, 3, seams=(18,), folds=(10,))   # fore topsail
    yard(g, 15, 23, 12)
    square_sail(g, 16, 22, 13, 5, seams=(18, 21), folds=(15, 17))  # fore course
    pennant(g, 7, 5, 2, -1)
    pennant(g, 12, 3, 3, -1)
    pennant(g, 18, 4, 2, -1)
    emblem_cross(g, 13, 14)                                  # war hull, main course
    # HULL_GOLD tier-3 FULL sheer: hull top rail + castle/forecastle rails
    gold_trim(g, 2, 24, 19)
    gold_trim(g, 1, 8, 17)
    gold_trim(g, 20, 24, 16)
    return g


def nao_n() -> Grid:
    """Stern view sailing away — the big aft castle IS the transom; the
    six-sail tower keeps full rig height."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 3, -1)
    square_sail(g, 12, 18, 6, 2, seams=(15,))                # fore topsail
    square_sail(g, 10, 20, 8, 3, seams=(15,), folds=(9,))    # fore course
    square_sail(g, 11, 19, 10, 3, seams=(15,), folds=(11,))  # main topsail
    square_sail(g, 8, 22, 12, 5, seams=(11, 15, 19), folds=(14, 16))  # main course
    transom(g, 8, 23, 19, windows=(10, 13, 16, 19, 22))      # wide castle face
    gold_trim(g, 8, 23, 19)                                  # taffrail line
    return g


def nao_s() -> Grid:
    """Bow view approaching — big fore castle, jib, FULL-height slivers."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 3, -1)
    edge_on_sail(g, 10, 12, 6, 17, folds=(9, 12, 15))        # aft sliver
    edge_on_sail(g, 17, 19, 7, 16, folds=(10, 13))           # fore sliver
    bow_hull(g, 9, 22, 19)
    g.hline(10, 21, 17, "H")                                 # fore castle, 2 rows
    g.hline(10, 21, 18, "W")
    g.put(12, 20, "K")
    g.put(19, 20, "K")
    gold_trim(g, 10, 21, 17)                                 # castle rail
    gold_trim(g, 9, 22, 19)                                  # hull top rail
    jib(g, 15, 5, 21, 21)
    g.line(17, 18, 22, 23, "W")                              # bowsprit, down-screen
    g.put(22, 23, "H")
    return g


def nao_ne() -> Grid:
    """3/4 view, bow up-right — castles fore/aft, three slanted stacks."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 19, -9)
    diag_ports_y(g, rail, (8, 12, 16, 20), 2)
    mast(g, 8, 9, 18)                                        # mizzen
    diag_stack(g, 5, 10, 10, 11, 3, seams=(7,))              # mizzen topsail
    diag_stack(g, 4, 14, 9, 16, 3, seams=(6,))               # mizzen course
    g.hline(4, 6, 17, "H")                                   # aft castle block
    g.hline(4, 6, 18, "W")
    g.put(5, 18, "K")
    lantern(g, 3, 16)
    mast(g, 13, 5, 16)                                       # main
    diag_stack(g, 10, 6, 16, 7, 3, seams=(13,))              # main topsail
    diag_stack(g, 9, 10, 17, 12, 5, seams=(13,), folds=(2, 3))  # main course
    mast(g, 18, 4, 14)                                       # fore
    diag_stack(g, 14, 5, 20, 6, 3, seams=(17,))              # fore topsail
    diag_stack(g, 13, 9, 19, 11, 4, seams=(15, 17), folds=(2,))  # fore course
    g.hline(21, 23, 9, "H")                                  # fore castle block
    g.hline(21, 23, 10, "W")
    pennant(g, 7, 8, 2, -1)
    pennant(g, 12, 4, 3, -1)
    pennant(g, 17, 3, 2, -1)
    emblem_cross(g, 13, 14)                                  # largest sail
    g.put(24, 9, "H")                                        # stem head
    g.line(25, 8, 27, 6, "W")                                # bowsprit
    g.put(27, 6, "H")
    stay45(g, 19, 5, 4, 1, 1)                                # forestay -> stem
    for x, y in rail.items():                                # HULL_GOLD sheer line
        g.put(x, y, "g")
    gold_trim(g, 4, 6, 17)                                   # aft castle rail
    gold_trim(g, 21, 23, 9)                                  # fore castle rail
    return g


def nao_se() -> Grid:
    """3/4 view, bow down-right — honest down-heading, sails still hang."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 11, 9)
    diag_ports_y(g, rail, (8, 12, 16, 20), 2)
    mast(g, 8, 5, 14)                                        # mizzen
    diag_stack(g, 5, 6, 10, 8, 3, seams=(7,))                # mizzen topsail
    diag_stack(g, 4, 10, 9, 12, 3, seams=(6,))               # mizzen course
    g.hline(4, 6, 9, "H")                                    # aft castle block
    g.hline(4, 6, 10, "W")
    g.put(5, 10, "K")
    lantern(g, 3, 8)
    mast(g, 13, 4, 16)                                       # main
    diag_stack(g, 10, 5, 16, 7, 3, seams=(13,))              # main topsail
    diag_stack(g, 9, 9, 17, 13, 5, seams=(13,), folds=(2, 3))  # main course
    mast(g, 18, 5, 19)                                       # fore
    diag_stack(g, 14, 6, 20, 8, 3, seams=(17,))              # fore topsail
    diag_stack(g, 13, 10, 19, 12, 4, seams=(15, 17), folds=(2,))  # fore course
    g.hline(21, 23, 17, "H")                                 # fore castle block
    g.hline(21, 23, 18, "W")
    pennant(g, 7, 4, 2, -1)
    pennant(g, 12, 3, 3, -1)
    pennant(g, 17, 4, 2, -1)
    emblem_cross(g, 13, 11)                                  # largest sail
    g.put(24, 21, "H")                                       # stem head
    g.line(25, 22, 27, 24, "W")                              # bowsprit, down-right
    g.put(27, 24, "H")
    for x, y in rail.items():                                # HULL_GOLD sheer line
        g.put(x, y, "g")
    gold_trim(g, 4, 6, 9)                                    # aft castle rail
    gold_trim(g, 21, 23, 17)                                 # fore castle rail
    return g


def nao_maps() -> dict[str, Grid]:
    ne = nao_ne()
    se = nao_se()
    return {
        "e": nao_e(),
        "w": nao_e().mirror_x(),     # opposite tack, own authored map
        "n": nao_n(),
        "s": nao_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Carrack — tier 3: 2 square stacks + lateen, HIGH stern castle, gold sheer
# ---------------------------------------------------------------------------


def carrack_e() -> Grid:
    """Side profile, bow right.  Authored x-extent 28 -> outlined 30."""
    g = Grid()
    hull_side(g, 2, 25, 19, ports=(4, 8, 12, 16, 20, 24), tall=True)  # y19..25
    mast(g, 9, 7, 13)                                        # mizzen (behind castle)
    g.hline(2, 8, 11, "H")                                   # HIGH castle roof
    g.hline(2, 8, 12, "W")
    for x in (3, 5, 7):
        g.put(x, 12, "K")
    g.hline(2, 8, 13, "W")
    g.hline(1, 9, 14, "L")                                   # roof overhang
    g.hline(1, 9, 15, "H")                                   # tier rail
    g.hline(1, 9, 16, "W")
    for x in (2, 4, 6, 8):
        g.put(x, 16, "K")
    g.hline(1, 9, 17, "W")
    g.hline(1, 9, 18, "L")
    lantern(g, 1, 10)
    mast(g, 14, 4, 18)                                       # main
    mast(g, 20, 5, 18)                                       # fore
    crow_nest(g, 12, 16, 6)
    stay45(g, 21, 6, 5, 1, 1)                                # forestay -> sprit
    stem_sprit(g, 26, 17, 2)
    yard(g, 10, 18, 7)
    square_sail(g, 11, 17, 8, 3, seams=(13, 15), folds=(9,))  # main topsail
    yard(g, 10, 18, 11)
    square_sail(g, 11, 17, 12, 6, seams=(13, 15), folds=(14, 16))  # main course
    yard(g, 16, 24, 8)
    square_sail(g, 17, 23, 9, 3, seams=(19,), folds=(10,))   # fore topsail
    yard(g, 16, 24, 12)
    square_sail(g, 17, 23, 13, 5, seams=(19, 22), folds=(15, 17))  # fore course
    lateen(g, 4, 11, 11, 7, base=14)                         # mizzen lateen
    pennant(g, 8, 6, 2, -1)
    pennant(g, 13, 3, 3, -1)
    pennant(g, 19, 4, 2, -1)
    emblem_cross(g, 14, 14)                                  # war hull, main course
    forecastle(g, 22, 25, 17)
    # HULL_GOLD tier-3 FULL sheer: hull rail + castle tier rail + fore rail
    gold_trim(g, 2, 25, 19)
    gold_trim(g, 1, 9, 15)
    gold_trim(g, 22, 25, 17)
    return g


def carrack_n() -> Grid:
    """Stern view sailing away — the HIGH castle roofline above the transom."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 3, -1)
    square_sail(g, 11, 17, 6, 2, seams=(14,))                # fore topsail
    square_sail(g, 9, 19, 8, 3, seams=(12, 16), folds=(9,))  # fore course
    square_sail(g, 10, 18, 10, 3, seams=(15,), folds=(11,))  # main topsail
    square_sail(g, 8, 20, 12, 4, seams=(11, 17), folds=(13, 15))  # main course
    spanker(g, 6, 15, 13, 8)                                 # mizzen lateen, tall
    g.hline(9, 22, 16, "H")                                  # castle roof
    transom(g, 9, 22, 17, windows=(11, 15, 19))              # tall castle face
    gold_trim(g, 9, 22, 17)                                  # taffrail line
    return g


def carrack_s() -> Grid:
    """Bow view approaching — jib, FULL-height slivers, gold rails."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 3, -1)
    edge_on_sail(g, 10, 12, 6, 17, folds=(9, 12, 15))        # aft sliver
    edge_on_sail(g, 17, 19, 7, 16, folds=(10, 13))           # fore sliver
    bow_hull(g, 9, 22, 19)
    g.hline(10, 21, 18, "H")                                 # foredeck rail
    g.put(12, 20, "K")
    g.put(19, 20, "K")
    gold_trim(g, 10, 21, 18)                                 # foredeck rail
    gold_trim(g, 9, 22, 19)                                  # hull top rail
    jib(g, 15, 5, 20, 20)
    g.line(17, 18, 21, 22, "W")                              # bowsprit, down-screen
    g.put(21, 22, "H")
    return g


def carrack_ne() -> Grid:
    """3/4 view, bow up-right — the HIGH castle block, stacked squares."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 19, -9)
    diag_ports_y(g, rail, (8, 12, 16, 20), 2)
    mast(g, 8, 10, 18)                                       # mizzen
    g.hline(4, 6, 15, "H")                                   # HIGH castle block
    g.hline(4, 6, 16, "W")
    g.hline(4, 6, 17, "W")
    g.put(5, 17, "K")
    lantern(g, 3, 14)
    lateen(g, 5, 14, 11, 10, base=16)                        # mizzen lateen
    pennant(g, 7, 9, 2, -1)
    mast(g, 13, 5, 16)                                       # main
    diag_stack(g, 10, 6, 16, 7, 3, seams=(13,))              # main topsail
    diag_stack(g, 9, 10, 17, 12, 5, seams=(13,), folds=(2, 3))  # main course
    pennant(g, 12, 4, 3, -1)
    mast(g, 18, 5, 14)                                       # fore
    diag_stack(g, 14, 6, 20, 7, 3, seams=(17,))              # fore topsail
    diag_stack(g, 13, 10, 19, 12, 4, seams=(15, 17), folds=(2,))  # fore course
    pennant(g, 17, 4, 2, -1)
    emblem_cross(g, 13, 14)                                  # largest sail
    g.put(24, 9, "H")                                        # stem head
    g.line(25, 8, 27, 6, "W")                                # bowsprit
    g.put(27, 6, "H")
    for x, y in rail.items():                                # HULL_GOLD sheer line
        g.put(x, y, "g")
    gold_trim(g, 4, 6, 15)                                   # castle rail
    return g


def carrack_se() -> Grid:
    """3/4 view, bow down-right — high castle, sails hang on the slope."""
    g = Grid()
    rail = diag_hull_thick(g, 4, 23, 11, 9)
    diag_ports_y(g, rail, (8, 12, 16, 20), 2)
    mast(g, 8, 6, 14)                                        # mizzen
    g.hline(4, 6, 8, "H")                                    # HIGH castle block
    g.hline(4, 6, 9, "W")
    g.hline(4, 6, 10, "W")
    g.put(5, 10, "K")
    lantern(g, 3, 7)
    lateen(g, 5, 10, 11, 13, base=15)                        # mizzen lateen
    pennant(g, 7, 5, 2, -1)
    mast(g, 13, 4, 16)                                       # main
    diag_stack(g, 10, 5, 16, 7, 3, seams=(13,))              # main topsail
    diag_stack(g, 9, 8, 17, 12, 5, seams=(13,), folds=(2, 3))  # main course
    mast(g, 18, 5, 19)                                       # fore
    diag_stack(g, 14, 6, 20, 8, 3, seams=(17,))              # fore topsail
    diag_stack(g, 13, 9, 19, 13, 4, seams=(15, 17), folds=(2,))  # fore course
    pennant(g, 12, 3, 3, -1)
    pennant(g, 17, 4, 2, -1)
    emblem_cross(g, 13, 10)                                  # largest sail
    g.put(24, 21, "H")                                       # stem head
    g.line(25, 22, 27, 24, "W")                              # bowsprit, down-right
    g.put(27, 24, "H")
    for x, y in rail.items():                                # HULL_GOLD sheer line
        g.put(x, y, "g")
    gold_trim(g, 4, 6, 8)                                    # castle rail
    return g


def carrack_maps() -> dict[str, Grid]:
    ne = carrack_ne()
    se = carrack_se()
    return {
        "e": carrack_e(),
        "w": carrack_e().mirror_x(),  # opposite tack, own authored map
        "n": carrack_n(),
        "s": carrack_s(),
        "ne": ne,
        "nw": ne.mirror_x(),
        "se": se,
        "sw": se.mirror_x(),
    }


# ---------------------------------------------------------------------------
# Galleass — tier 3: 9 oar stations + 3 BIG lateens, the LONGEST hull
# ---------------------------------------------------------------------------


def galleass_e() -> Grid:
    """Side profile, bow right — hull 25px, the longest in the game.
    Authored x-extent 28 -> outlined 30 (band top)."""
    g = Grid()
    hull_side(g, 2, 26, 19, tall=True)                       # y19..25
    oar_bank(g, (4, 6, 9, 11, 14, 16, 19, 21, 24), 24)       # 9 stations
    stern_castle(g, 2, 6, 13, windows2=(3, 5), windows1=(3, 5))
    mast(g, 8, 6, 15)                                        # aft lateen mast
    mast(g, 14, 4, 17)                                       # main lateen mast
    mast(g, 20, 5, 17)                                       # fwd lateen mast
    lateen(g, 4, 13, 12, 4, base=16)                         # aft lateen, scaled up
    lateen(g, 10, 12, 17, 4, base=16)                        # main lateen, scaled up
    lateen(g, 16, 11, 23, 4, base=15)                        # fwd lateen, scaled up
    forecastle(g, 22, 26, 17)
    stem_sprit(g, 27, 17, 1)
    pennant(g, 7, 5, 2, -1)
    pennant(g, 13, 3, 3, -1)
    pennant(g, 19, 4, 2, -1)
    emblem_cross(g, 13, 12)                                  # war hull, main lateen
    # HULL_GOLD tier-3 FULL sheer: hull top rail + castle/forecastle rails
    gold_trim(g, 2, 26, 19)
    gold_trim(g, 1, 7, 17)
    gold_trim(g, 22, 26, 17)
    return g


def galleass_n() -> Grid:
    """Stern view sailing away — three tall lateens stacked, oar blades out."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 3, -1)
    spanker(g, 11, 8, 18, 4)                                 # fwd lateen, high
    spanker(g, 9, 11, 18, 7)                                 # main lateen
    spanker(g, 7, 14, 17, 10)                                # aft lateen
    oar_bank(g, (7, 24), 22)                                 # blades out
    oar_bank(g, (7, 24), 23)
    transom(g, 9, 22, 19, windows=(11, 14, 17, 20))          # beam ~14
    gold_trim(g, 9, 22, 19)                                  # taffrail line
    return g


def galleass_s() -> Grid:
    """Bow view approaching — lateen slivers, oar tips flanking the bow."""
    g = Grid()
    mast(g, 15, 4, 18)
    pennant(g, 14, 3, 3, -1)
    edge_on_sail(g, 10, 12, 6, 17, folds=(9, 12, 15))        # aft sliver
    edge_on_sail(g, 17, 19, 7, 16, folds=(10, 13))           # fwd sliver
    bow_hull(g, 9, 22, 19)
    g.hline(10, 21, 18, "H")                                 # foredeck rail
    gold_trim(g, 10, 21, 18)                                 # foredeck rail
    gold_trim(g, 9, 22, 19)                                  # hull top rail
    oar_bank(g, (6, 25), 20)                                 # tips out
    oar_bank(g, (6, 25), 22)
    g.line(17, 18, 21, 22, "W")                              # bowsprit, down-screen
    g.put(21, 22, "H")
    return g


def galleass_ne() -> Grid:
    """3/4 view, bow up-right — oar dots down the diagonal, 3 big lateens."""
    g = Grid()
    rail = diag_hull_thick(g, 3, 22, 19, -8)
    for x in (6, 9, 12, 15, 18, 21):                         # oar dots
        g.put(x, rail[x] + 3, "K")
    mast(g, 8, 8, 19)                                        # aft lateen mast
    g.hline(3, 5, 16, "H")                                   # aft castle block
    g.hline(3, 5, 17, "W")
    g.put(4, 17, "K")
    mast(g, 14, 5, 16)                                       # main lateen mast
    mast(g, 19, 6, 14)                                       # fwd lateen mast
    lateen(g, 5, 14, 11, 10, base=16)                        # aft lateen
    lateen(g, 10, 12, 17, 8, base=16)                        # main lateen
    lateen(g, 15, 11, 21, 7, base=15)                        # fwd lateen
    pennant(g, 7, 7, 2, -1)
    pennant(g, 13, 4, 3, -1)
    pennant(g, 18, 5, 2, -1)
    emblem_cross(g, 13, 13)                                  # largest sail
    g.put(23, 10, "H")                                       # stem head
    g.line(24, 9, 25, 8, "W")                                # bowsprit
    g.put(25, 8, "H")
    for x, y in rail.items():                                # HULL_GOLD sheer line
        g.put(x, y, "g")
    gold_trim(g, 3, 5, 16)                                   # castle rail
    return g


def galleass_se() -> Grid:
    """3/4 view, bow down-right — lateens hang, oar dots ride the slope."""
    g = Grid()
    rail = diag_hull_thick(g, 3, 22, 12, 8)
    for x in (6, 9, 12, 15, 18, 21):                         # oar dots
        g.put(x, rail[x] + 3, "K")
    mast(g, 8, 7, 15)                                        # aft lateen mast
    g.hline(3, 5, 9, "H")                                    # aft castle block
    g.hline(3, 5, 10, "W")
    g.put(4, 10, "K")
    mast(g, 14, 5, 18)                                       # main lateen mast
    mast(g, 19, 6, 20)                                       # fwd lateen mast
    lateen(g, 5, 10, 11, 14, base=16)                        # aft lateen
    lateen(g, 10, 8, 17, 13, base=16)                        # main lateen
    lateen(g, 15, 8, 21, 12, base=15)                        # fwd lateen
    pennant(g, 7, 6, 2, -1)
    pennant(g, 13, 4, 3, -1)
    pennant(g, 18, 5, 2, -1)
    emblem_cross(g, 13, 11)                                  # largest sail
    g.put(23, 21, "H")                                       # stem head
    g.line(24, 22, 25, 23, "W")                              # bowsprit, down-right
    g.put(25, 23, "H")
    for x, y in rail.items():                                # HULL_GOLD sheer line
        g.put(x, y, "g")
    gold_trim(g, 3, 5, 9)                                    # castle rail
    return g


def galleass_maps() -> dict[str, Grid]:
    ne = galleass_ne()
    se = galleass_se()
    return {
        "e": galleass_e(),
        "w": galleass_e().mirror_x(),  # opposite tack, own authored map
        "n": galleass_n(),
        "s": galleass_s(),
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
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "3 masts, big stern castle, crow's nests, dense gunports, "
               "owner-colored cross emblem on the main course (HULL_GOLD "
               "full sheer)",
        "maps_fn": galleon_maps,
    },
    "sloop": {
        "tier": 1,
        "band": (14, 18),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "1 mast, BIG lateen (sail-dominant), stub aft deck, short "
               "bowsprit, jib (s), roundel emblem, green stripe",
        "maps_fn": sloop_maps,
    },
    "latin": {
        "tier": 1,
        "band": (14, 18),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "1 mast, the BIG lateen triangle dominates (masthead y4, sail "
               "to the deck); roundel emblem",
        "maps_fn": latin_maps,
    },
    "galiot": {
        "tier": 1,
        "band": (14, 18),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "compact hull, scaled-up lateen, 4-station oar bank (1px ink "
               "dots), roundel emblem, green stripe",
        "maps_fn": galiot_maps,
    },
    "pinnace": {
        "tier": 1,
        "band": (14, 18),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "oars ONLY — two staggered 1px ink banks, no sail; mast stub "
               "carries the pennant; gold stripe",
        "maps_fn": pinnace_maps,
    },
    "caravel": {
        "tier": 2,
        "band": (20, 26),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "2 masts, 2 scaled-up lateens, rounded high-prow hull, dense "
               "gunports, roundel emblem, green stripe",
        "maps_fn": caravel_maps,
    },
    "galley": {
        "tier": 2,
        "band": (20, 26),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "LONG low hull, 7 oar stations, 1 big lateen + square topsail, "
               "cross emblem, gold stripe",
        "maps_fn": galley_maps,
    },
    "brigantine": {
        "tier": 2,
        "band": (20, 26),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "fore mast course+topsail stack, main mast fore-and-aft "
               "spanker (gaff + boom), cross emblem, green stripe",
        "maps_fn": brigantine_maps,
    },
    "fluyt": {
        "tier": 2,
        "band": (20, 26),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "FAT belly hull, blunt stern, 3 masts x course+topsail (six "
               "sail masses), roundel emblem, gold stripe",
        "maps_fn": fluyt_maps,
    },
    "junk": {
        "tier": 2,
        "band": (20, 26),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "3 masts x 2 full-batten sails (six battened masses), fan-tail "
               "stern, roundel emblem, gold stripe",
        "maps_fn": junk_maps,
    },
    "dhow": {
        "tier": 2,
        "band": (20, 26),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "slim hull, sharp prow, 1 big lateen (masthead y4), roundel "
               "emblem, green stripe",
        "maps_fn": dhow_maps,
    },
    "caravela_redonda": {
        "tier": 2,
        "band": (20, 26),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "roundish hull, 3 masts: fore+main course+topsail stacks + "
               "mizzen lateen, roundel emblem, gold stripe",
        "maps_fn": caravela_redonda_maps,
    },
    "xebec": {
        "tier": 2,
        "band": (20, 26),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "narrow hull, 3 scaled-up lateens on 3 masts (overlapping "
               "yards), roundel emblem, green stripe",
        "maps_fn": xebec_maps,
    },
    "nao": {
        "tier": 3,
        "band": (26, 30),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "3 masts x course+topsail (six sail masses), big fore AND aft "
               "castles, crow's nests, dense gunports, cross emblem "
               "(HULL_GOLD full sheer)",
        "maps_fn": nao_maps,
    },
    "carrack": {
        "tier": 3,
        "band": (26, 30),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "main+fore course+topsail stacks + mizzen lateen, HIGH stern "
               "castle (taller than the galleon's), cross emblem (HULL_GOLD "
               "full sheer)",
        "maps_fn": carrack_maps,
    },
    "galleass": {
        "tier": 3,
        "band": (26, 30),
        "view": "UW2 side/3-quarter sailing views (80-* §4.8.6 amendment + "
                "perspective cheats): e/w full side profile, n/s full-height "
                "stern/bow, diagonals thick-band 3/4 — all eight directions "
                "authored, no derive",
        "rig": "hybrid: 9 oar stations (1px ink dots) + 3 scaled-up lateens, "
               "the longest hull, cross emblem (HULL_GOLD full sheer)",
        "maps_fn": galleass_maps,
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
    # Ownership note: this tool owns exactly the docs it emits — all SIXTEEN
    # hull docs, re-authored UW2 style ×8 dirs (the revision round).  No
    # other files under authored/ are its business, so there is no
    # stale-doc scan here.
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
