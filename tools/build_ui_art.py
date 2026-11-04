#!/usr/bin/env python3
"""build_ui_art.py — the Phase-10 UI-art pipeline governor (sole writer: W3-B).

Walks the declarative sprite manifests under ``tools/ui_art/<class>/`` (sorted),
renders them through the vendored YoYoPixel engine (``tools/yoyopixel/render.js``,
node pinned v24.16.0, zero npm deps), then applies the Python post-passes:

1. 8-direction lossless derivations   — declarations carrying
   ``"derive": {"from": <sprite id>, "op": rot_cw|rot_ccw|rot_180|mirror_x|
   mirror_y|mirror_xy}`` are produced from their base sprite's rendered PNG
   (rot_cw = 90° clockwise on screen: new(x, y) = old(y, H-1-x), index math
   self-verified against a fixture on every run).
2. Owner remap (hulls, §4.8.4 amended 2026-11-04 — the shared-hull pennant
   scheme) — every owner draws the SAME authored map; the owner is encoded
   ONLY by the masthead pennant: the authored maps carry the authoring-only
   source hex ``#b3191f`` and the governor substitutes it with the owner's
   ``PENNANT_*`` hex (player gold ``#d9a441`` = HULL_GOLD, nations = their
   colors, neutral grey, pirate red; spain is the legal identity remap).
   Wood/sail/ink and the t3 HULL_GOLD trim are owner-invariant.
3. Auto-outline (tokens) — 1 px #101010 outline around the silhouette of
   hull + facility tokens (8-neighborhood); authored maps are outline-less.
4. Seam-ring verification (terrain class) — variants of a terrain kind must
   share a byte-identical outer 1 px ring; ``sea_pattern.png`` must be
   torus-safe (80-* §4.8.2 seam rules).  Verify only, never alters.
5. Nine-patch assembly (chrome class) — ``assets/ui/chrome/ninepatch_
   {panel,button,button_focus,field,bar}.png`` (48×48) from the 16×16 chrome
   tiles: the tiles are authored as the TOP-LEFT corner / TOP edge, so every
   frame cell carries the orientation-matched lossless transform of them
   (mirror_x/mirror_y/mirror_xy corners, rot_ccw/rot_cw left/right,
   mirror_y bottom — blitting raw tiles everywhere misaligned the sheet and
   broke every themed Button), fill in the 16×16 center (48 = 16 + 16 + 16,
   so margins are exactly one tile); every sheet is pixel-exact
   self-verified at assembly (build FAIL on any mismatch).  Bar sheet layout
   (pinned): rows 16..31 form the horizontal midline band the kit's
   value_bar samples — left cap tile at x 0..15, line tile tiled x 16..31,
   right cap tile at x 32..47; the rest transparent.
6. Hull footprint check — per hull, the §4.8.7 band is measured on the side
   view (e/w long axis, the profile that shows the ship's length; final
   outlined file): t1 28–36, t2 40–52, t3 52–60 px on the 64 canvas
   (amendment 1664ba9 — ×2 of the retired 32-canvas values).  The stern/bow
   views (n/s) show the beam and the diagonals are 3/4 views — both unbanded,
   canvas-fit only (bbox + outline ≤ 64).
7. Hull color audit — every final token's hexes ⊆ the hull palette block and
   ≤ the authored-grid color budget (20, §4.8.3).
9. Model-pass ship ingestion (``--import-ships <snapped_dir>`` — the §4.8
   ingestion contract, ACTIVE; the 90-* §9.2 AI-ingestion path): the
   snap-downsampled model outputs (64-grid RGBA, gitignored under
   ``tools/ui_art/model_raw/snapped/``) are formally ingested — per 64-grid
   BASE token (n, s, w, sw, nw — the 5-direction generation amendment
   f6c00bb; the model only ever generates those five): quantize every
   opaque px to the 18-hex hull block (nearest, deterministic tie-break),
   snap any px within Δ≤40 channel-sum of the pennant source ``#b3191f``
   to exactly ``#b3191f`` (so the ×9 remap hits), require ≥3 source-red px
   in the top 45% of the bbox (masthead), and band-gate the ``w`` base
   (the side profile) on the §4.8.7 tier band.  ``e``/``ne``/``se`` are
   derived at ingestion as exact ``mirror_x`` flips of ``w``/``nw``/``sw``
   BEFORE the pennant remap (the remap is color-level, mirror-invariant);
   a missing/rejected base falls its whole mirror group back to the
   generator (no mixing inside a pair).  Accepted tokens replace the
   ×2-upscale generator art as the PRIMARY shipped token (override ladder:
   ingested preferred, fallback only for gaps, per-file presence); the
   provenance ledger ``tools/ui_art/ingest_ledger.json`` is committed
   (per base token: job, seed, snapped sha, acceptance date; per derived
   file: base reference + flip).  Out-of-band / masthead-less tokens are
   REJECTED (reported, never committed) — a later re-roll lands via a
   simple re-run.
10. 64-canvas fallback (§4.8 64-canvas amendment 1664ba9) — hull tokens and
   the terrain class (terrain tiles + shore strips + port markers) ship as
   64×64 canvases: the exact ×2 nearest upscale of the authored 32-grid
   renders (never hand-drawn at 64); transparency preserved; ids/filenames
   unchanged. A source already authored at 64 (`sea_pattern.png`) passes
   through at 1:1.

CLI:
    python3 tools/build_ui_art.py                 # full build into assets/ui/
    python3 tools/build_ui_art.py --check         # rebuild into a temp dir and
                                                  # byte-compare vs assets/ui/
                                                  # (§8.8 double-run/hand-edit
                                                  # detector, group 13 item 2)
    python3 tools/build_ui_art.py --contact-sheet # emit tools/contact_sheet.png
                                                  # (labeled montage + seam
                                                  # montage; decision 9.4)

Manifest contract (per class dir, ``*.json`` sorted):
* renderable declaration: ``{"id", "file", "rows"+"palette"}`` (string-map) or
  ``{"id", "file", "grid"+"materials"}`` (template); a file may also hold an
  array of them or ``{"sprites": [...]}`` — passed to render.js as-is;
  optional ``"outline": true`` opts the sprite into the token outline pass.
* derive-only declaration: ``{"id", "file", "derive": {"from", "op"}}`` —
  post-pass transform of the referenced base sprite (resolved by id across
  classes; chains allowed, cycles rejected).
* hull authoring doc (hulls class): ``{"id": "hull_<ship_type>", "tier",
  "maps": {...}}`` — registry-driven pipeline; the amended UW2 shape
  (80-* §4.8.6, 2026-11-04) authors ALL EIGHT direction maps (a side-view
  ship does not rotate losslessly) and carries no derive entries; legacy
  docs with ``maps: {n, ne}`` + the pinned six-op derive table keep the
  derivation path until re-authored.  ``"file"``-less, rendered into a
  transient staging dir because the wood-colored authored map is a pipeline
  intermediate, never a shipped file (§4.8.4: every owner variant incl.
  neutral is a remap target).
* auxiliary docs (no ``id``): ``rig.json`` (style library) and
  ``hulls.json`` (registry) in the hulls class; ignored elsewhere.

Missing classes are fine (staged activation): a class dir that does not exist
or holds no manifests is reported skipped.  Deterministic: sorted walks, no
dict-order dependence — two runs are byte-identical (gated by ``--check``);
the ingested tokens enter that contract through the ladder (the committed
ingested PNGs are the expected bytes; the ledger sha pins their source).
Stdlib only.

Pinned references: docs/80-UI-UX.md §4.8 (style guide, palette blocks,
heading8→dir table §4.8.6, footprint bands §4.8.7, ingestion contract +
5-direction amendment f6c00bb); docs/10-DATA-SCHEMA.md §8.8 (group-13
normative spec); docs/90-ARCHITECTURE.md §9.2 (AI-ingestion path);
docs/IMPLEMENT-Phase10.md decisions 5/9.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENGINE = ROOT / "tools" / "yoyopixel" / "render.js"
MANIFESTS = ROOT / "tools" / "ui_art"
SHIP_TYPES = ROOT / "data" / "ship_types.json"
NODE_PIN = "v24.16.0"  # docs/IMPLEMENT-Phase10.md correction 10 (§8.8: >= pin; we refuse drift like fixture_check.py)
CLASS_DIRS = ["chrome", "fx", "hulls", "icons", "markers", "portraits",
              "terrain"]  # sorted walk order (§4.8.1; markers = A.4 follow-up)
TOKENS_DIR = "assets/ui/tokens"
STAGING = "build/ui_art_staging"  # transient, removed after every run

# ---- hull palette block (80-* §4.8.4, amended 2026-11-04: the shared-hull
# pennant scheme; scripts/palette.gd hull-block constants) ----

HULL_INK = "#101010"          # HULL_INK — token outline, tool-applied
WOOD_HI = "#8f6d3a"           # WOOD_HI — shared wood highlight (owner-invariant)
WOOD = "#7a5c2e"              # WOOD — shared wood base (owner-invariant)
WOOD_LO = "#5e4720"           # WOOD_LO — shared wood shadow (owner-invariant)
SAIL_HI = "#f7f5ee"           # SAIL_HI
SAIL = "#e8e6df"              # SAIL (= TEXT)
SAIL_LO = "#c2beb2"           # SAIL_LO
SAIL_SH = "#a8a496"           # SAIL_SH — the billow's dark flank (craft bar)
DECK = "#9a6a3a"              # DECK — oblique deck-plank tone (craft bar)
HULL_GOLD = "#d9a441"         # HULL_GOLD — t3 trim line; player pennant value
# pennant remap (§4.8.4 amended): the authored maps carry the authoring-only
# SOURCE hex at every masthead pennant; the governor substitutes it with the
# owner's PENNANT_* hex — the ONLY owner-variant pixel.  Wood/sail/ink (and
# the t3 gold) are owner-invariant.  Spain is an identity remap (its pennant
# value equals the source hex).
PENNANT_SOURCE = "#b3191f"
PENNANTS = {
    "player":   "#d9a441",   # PENNANT_PLAYER (= HULL_GOLD)
    "portugal": "#1a8c4e",   # PENNANT_PORTUGAL
    "spain":    "#b3191f",   # PENNANT_SPAIN (identity remap of the source)
    "england":  "#274b8f",   # PENNANT_ENGLAND
    "holland":  "#d97b1e",   # PENNANT_HOLLAND
    "ottoman":  "#6a3d9a",   # PENNANT_OTTOMAN
    "italy":    "#c9a227",   # PENNANT_ITALY
    "neutral":  "#9a9a9a",   # PENNANT_NEUTRAL
    "pirate":   "#b3341f",   # PENNANT_PIRATE
}
OWNER_ORDER = ["player", "portugal", "spain", "england", "holland",
               "ottoman", "italy", "neutral", "pirate"]
HEXES = {h: tuple(int(h[i:i + 2], 16) for i in (1, 3, 5)) for h in
         {HULL_INK, WOOD_HI, WOOD, WOOD_LO, SAIL_HI, SAIL, SAIL_LO, SAIL_SH,
          DECK, HULL_GOLD, PENNANT_SOURCE}
         | set(PENNANTS.values())}
# shipped-pixel membership audit set — the amended hull block exactly (18
# distinct values: ink, wood ×3, sail ×4, deck, gold, 9 pennants; the
# retired owner-ramp hexes are no longer allowed in shipped hull pixels,
# §4.8.4 + the §4.8.2 craft bar)
HULL_BLOCK = {HULL_INK, WOOD_HI, WOOD, WOOD_LO, SAIL_HI, SAIL, SAIL_LO,
              SAIL_SH, DECK, HULL_GOLD} | set(PENNANTS.values())

# footprint bands (80-* §4.8.7 final values, ship_types.tier partition 4/8/4;
# the §4.8 64-canvas amendment 1664ba9 — ×2 of the retired 32-canvas bands,
# measured on the final outlined 64×64 token canvas)
FOOTPRINT_BANDS = {1: (28, 36), 2: (40, 52), 3: (52, 60)}
COLOR_BUDGET_32 = 20  # §4.8.3: authored-grid (32×32) -> 12-20 cap; the 64
# canvas ships the same pixels ×2, so the authored-grid budget stays the
# binding cap (the validator's 64-canvas tier cap of 25 is looser)
CANVAS = 64  # the shipped token canvas (§4.8 64-canvas amendment)
AUTHORED_GRID = 32  # the authored string-map grid the 64 canvas upscales
TERRAIN_OUT_PREFIX = "assets/ui/terrain/"  # terrain class output dir

# ---- model-pass ship ingestion (--import-ships; 90-* §9.2 AI-ingestion
# path, 80-* §4.8 ingestion contract + the 5-direction amendment f6c00bb).
# The snapped sources live gitignored in tools/ui_art/model_raw/snapped/
# (never committed); the ingest ledger is committed provenance. ----
INGEST_LEDGER = MANIFESTS / "ingest_ledger.json"   # committed provenance
INGEST_VERSION = 1
PENNANT_SNAP_RADIUS = 40   # channel-sum Δ to the pennant source that snaps
MASTHEAD_MIN_PX = 3        # ≥3 source-red px in the masthead region
MASTHEAD_TOP_FRAC = 0.45   # masthead region = top 45% of the token bbox
INGEST_BASE_DIRS = ("n", "s", "w", "sw", "nw")  # the model's 5 base dirs
INGEST_DERIVED = {"e": "w", "ne": "nw", "se": "sw"}  # derived: mirror_x flip
INGEST_INGESTED_BUDGET = 25  # 64-canvas per-sprite cap (§4.8.3 48px tier;
# the quantized token draws from an 18-hex block, so this is belt-and-braces)

DERIVE_OPS = ("rot_cw", "rot_ccw", "rot_180", "mirror_x", "mirror_y", "mirror_xy")

# ---- icon palette block (80-* §4.8: chrome tiles + A.2 semantic icons) ----
# The three UW2 chrome-skin wood hexes appended 2026-11-04 (§4.8 amended,
# user direction — full option B, ledgered; mirrored in scripts/palette.gd
# and tools/validate_data.py BLOCK_ICON).
PANEL_WOOD = "#2e2014"        # PANEL_WOOD    — walnut fill
PANEL_WOOD_HI = "#6a4e28"     # PANEL_WOOD_HI — bevel light (TL) / trim base
PANEL_WOOD_LO = "#14100a"     # PANEL_WOOD_LO — bevel shadow (BR) / dark line
ICON_BG_LO = "#121724"        # ICON_BG_LO    — field recess interior
ACCENT = "#d9a441"            # ACCENT        — gold inner line / perimeter
ACCENT_HI = "#f0c46a"         # ACCENT_HI     — rosette center
ACCENT_LO = "#a87a28"         # ACCENT_LO     — rosette base / field lip
ICON_BLOCK = {
    "#1c2230", "#121724", "#465468", "#2e2014", "#6a4e28", "#14100a",
    "#5e7086", "#232c3e", "#e8e6df", "#f7f5ee", "#d9a441", "#f0c46a",
    "#a87a28", "#4e9e4e", "#74c26e", "#b3341f", "#d4573c", "#2f6f9e",
    "#9a9a9a", "#1a8c4e", "#b3191f", "#274b8f", "#d97b1e", "#6a3d9a",
    "#c9a227",
}
CHROME_COLOR_CAP = 8  # per-tile distinct-color discipline (§4.8.3 16px tier)
# Stretch-safety (80-* §4.8 UW2 chrome-skin note, amended 2026-11-04, master
# adjudication): the runtime StyleBoxTexture STRETCHes the nine-patch center
# and every edge span, so fill tiles and edge-tile interiors must stay FLAT
# (any interior texel smears into a large block at panel scale; the
# mirror-only FRAME_OPS make one edge tile serve all four sides, so edge
# interiors must be flat in both axes). Grain lives ONLY in the corner
# tiles — they never stretch.


def derive_base_of(spec: dict) -> str | None:
    """The derive source id — "from" (hulls/arrows scheme) or "base"
    (terrain/shore scheme); master reconciliation 2026-11-04, ledgered."""
    v = spec.get("from")
    if v is None:
        v = spec.get("base")
    return v
# pinned heading8->dir derivation table (80-* §4.8.6; also pinned in
# tools/ui_art/hulls/hulls.json + every authored/*.json — drift is a FAIL)
PINNED_DERIVE = {
    "e":  ("n", "rot_cw"),
    "s":  ("n", "rot_180"),
    "w":  ("n", "rot_ccw"),
    "nw": ("ne", "mirror_x"),
    "se": ("ne", "mirror_y"),
    "sw": ("ne", "rot_180"),
}
DIR_ORDER = ["e", "ne", "n", "nw", "w", "sw", "s", "se"]  # §4.8.6 bucket order

# nine-patch assembly spec (A.1 of IMPLEMENT-Phase10.md; step 5 above)
NINEPATCH_SETS = ("panel", "button", "button_focus", "field")
BAR_PARTS = ("left", "right", "line")  # A.1 chrome ids: bar_left/bar_right/bar_line (master reconciliation)
SHEET = 48   # 16px margins -> exactly one 16px middle tile (§4.8.8)
TILE = 16


def fail(msg: str) -> None:
    print(f"build_ui_art: FAIL: {msg}", file=sys.stderr)
    sys.exit(2)


# ======================================================================
# minimal PNG codec (stdlib) — decode indexed (type 3) + RGBA (type 6),
# encode indexed with scan-order palette + tRNS (mirrors render.js)
# ======================================================================

_PNG_SIG = b"\x89PNG\r\n\x1a\n"
_CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)


def decode_png(data: bytes):
    """-> (w, h, pixels) with pixels = list of (r, g, b, a) row-major."""
    if data[:8] != _PNG_SIG:
        fail("PNG decode: bad signature")
    pos, idat, plte, trns, header = 8, [], None, None, None
    while pos + 8 <= len(data):
        (length,), ctype = struct.unpack(">I", data[pos:pos + 4]), data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            header = chunk
        elif ctype == b"PLTE":
            plte = chunk
        elif ctype == b"tRNS":
            trns = chunk
        elif ctype == b"IDAT":
            idat.append(chunk)
        elif ctype == b"IEND":
            break
    if header is None or len(header) != 13:
        fail("PNG decode: missing IHDR")
    w, h, depth, ctype, comp, filt, inter = struct.unpack(">IIBBBBB", header)
    if depth != 8 or comp != 0 or filt != 0 or inter != 0:
        fail(f"PNG decode: unsupported IHDR (depth={depth} interlace={inter})")
    if ctype not in (3, 6):
        fail(f"PNG decode: unsupported color type {ctype}")
    raw = zlib.decompress(b"".join(idat))
    bpp = _CHANNELS[ctype]
    stride = w * bpp
    if len(raw) != (stride + 1) * h:
        fail("PNG decode: IDAT size mismatch")
    out = bytearray(stride * h)
    prev = bytearray(stride)
    for r in range(h):
        off = r * (stride + 1)
        ftype, line = raw[off], bytearray(raw[off + 1:off + 1 + stride])
        if ftype == 1:
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
                left = line[i - bpp] if i >= bpp else 0
                ul = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(left, prev[i], ul)) & 0xFF
        elif ftype != 0:
            fail(f"PNG decode: unknown filter {ftype}")
        out[r * stride:(r + 1) * stride] = line
        prev = line
    px = []
    if ctype == 6:
        for i in range(0, len(out), 4):
            px.append((out[i], out[i + 1], out[i + 2], out[i + 3]))
    else:
        if plte is None:
            fail("PNG decode: indexed PNG without PLTE")
        for idx in out:
            r, g, b = plte[idx * 3:idx * 3 + 3]
            a = trns[idx] if (trns is not None and idx < len(trns)) else 255
            px.append((r, g, b, a))
    return w, h, px


def encode_png_indexed(w: int, h: int, px) -> bytes:
    """Indexed PNG (color type 3, filter 0), scan-order palette + per-entry
    tRNS alpha — the same layout render.js emits; >256 colors -> RGBA."""
    pal, idx = {}, bytearray()
    for p in px:
        if p not in pal:
            if len(pal) > 255:
                return _encode_png_rgba(w, h, px)
            pal[p] = len(pal)
        idx.append(pal[p])
    raw = bytearray()
    for r in range(h):
        raw.append(0)
        raw += idx[r * w:(r + 1) * w]
    plte = b"".join(bytes(c[:3]) for c in pal)
    trns = bytes(c[3] for c in pal)
    has_alpha = any(c[3] != 255 for c in pal)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 3, 0, 0, 0)

    def chunk(ctype: bytes, body: bytes) -> bytes:
        return (struct.pack(">I", len(body)) + ctype + body
                + struct.pack(">I", zlib.crc32(ctype + body) & 0xFFFFFFFF))

    out = [_PNG_SIG, chunk(b"IHDR", ihdr), chunk(b"PLTE", plte)]
    if has_alpha:
        out.append(chunk(b"tRNS", trns))
    out.append(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
    out.append(chunk(b"IEND", b""))
    return b"".join(out)


def _encode_png_rgba(w: int, h: int, px) -> bytes:
    raw = bytearray()
    for r in range(h):
        raw.append(0)
        for p in px[r * w:(r + 1) * w]:
            raw += bytes(p)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)

    def chunk(ctype: bytes, body: bytes) -> bytes:
        return (struct.pack(">I", len(body)) + ctype + body
                + struct.pack(">I", zlib.crc32(ctype + body) & 0xFFFFFFFF))

    return b"".join([_PNG_SIG, chunk(b"IHDR", ihdr),
                     chunk(b"IDAT", zlib.compress(bytes(raw), 9)),
                     chunk(b"IEND", b"")])


# ======================================================================
# lossless pixel transforms + outline + remap
# ======================================================================

def _transform(w, h, px, op):
    # All ops are image ops on screen (y-down, x/y = col/row in the NEW image).
    # rot_cw: 90° clockwise — new(x, y) = old(y, H-1-x) (prompt-pinned formula,
    # verified against a fixture by _verify_transforms on every run).
    if op == "rot_cw":
        nw, nh = h, w
        return nw, nh, [px[(h - 1 - x) * w + y] for y in range(nh) for x in range(nw)]
    if op == "rot_ccw":
        nw, nh = h, w
        return nw, nh, [px[x * w + (w - 1 - y)] for y in range(nh) for x in range(nw)]
    if op == "rot_180":
        return w, h, [px[(w - 1 - x) + (h - 1 - y) * w] for y in range(h) for x in range(w)]
    if op == "mirror_x":
        return w, h, [px[(w - 1 - x) + y * w] for y in range(h) for x in range(w)]
    if op == "mirror_y":
        return w, h, [px[x + (h - 1 - y) * w] for y in range(h) for x in range(w)]
    if op == "mirror_xy":
        return w, h, [px[(w - 1 - x) + (h - 1 - y) * w] for y in range(h) for x in range(w)]
    fail(f"unknown derive op {op!r}")


def _verify_transforms() -> None:
    """Self-test the index math on a 3x2 fixture (runs every invocation)."""
    w, h = 3, 2
    px = [((x + 1) * 10, (y + 1) * 10, 0, 255) for y in range(h) for x in range(w)]
    cw = _transform(w, h, px, "rot_cw")
    assert cw[0] == 2 and cw[1] == 3, "rot_cw dims"
    assert cw[2][0] == px[3] and cw[2][2] == px[4] and cw[2][5] == px[2], \
        "rot_cw: old top-left must land at new top-right (bow east on screen)"
    ccw = _transform(w, h, px, "rot_ccw")
    assert ccw[2][0] == px[2] and ccw[2][5] == px[3], "rot_ccw"
    r180 = _transform(w, h, px, "rot_180")
    assert r180[2][5] == px[0] and r180[2][0] == px[5], "rot_180"
    mx = _transform(w, h, px, "mirror_x")
    assert mx[2][0] == px[2] and mx[2][2] == px[0], "mirror_x"
    my = _transform(w, h, px, "mirror_y")
    assert my[2][0] == px[3] and my[2][3] == px[0], "mirror_y"
    assert _transform(w, h, px, "mirror_xy")[2] == r180[2], "mirror_xy==rot_180"


def apply_outline(w, h, px, ink_rgba):
    """1px silhouette outline (8-neighborhood): transparent pixels adjacent to
    opaque ones take the ink; canvas border clamps.  80-* §4.8.2."""
    opaque = [p[3] != 0 for p in px]
    out = list(px)
    for y in range(h):
        for x in range(w):
            i = x + y * w
            if opaque[i]:
                continue
            touch = False
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    xx, yy = x + dx, y + dy
                    if 0 <= xx < w and 0 <= yy < h and opaque[xx + yy * w]:
                        touch = True
                        break
                if touch:
                    break
            if touch:
                out[i] = ink_rgba
    return out


def apply_remap(w, h, px, table, watch=frozenset()):
    """Exact hex substitution (sources -> targets).  A source whose target is
    a DIFFERENT hex must never survive the substitution (identity remaps are
    legal — e.g. the pennant source for spain) — such survivors are reported
    in `leftovers`."""
    out, leftovers = [], set()
    for p in px:
        hexv = "#%02x%02x%02x" % p[:3]
        q = (table[hexv] + (p[3],)) if hexv in table else p
        out.append(q)
        qh = "#%02x%02x%02x" % q[:3]
        if qh in watch:
            leftovers.add(qh)
    return out, leftovers


def bbox_of(px, w, h):
    xs, ys = [], []
    for y in range(h):
        for x in range(w):
            if px[x + y * w][3] != 0:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return min(xs), min(ys), max(xs), max(ys)


def upscale_nearest(w, h, px, factor):
    """Exact ×factor nearest upscale (§4.8 64-canvas fallback, amendment
    1664ba9): every source pixel becomes a factor×factor block; alpha and
    hexes pass through untouched — the deterministic fallback art, never
    hand-drawn at 64."""
    if factor <= 1:
        return w, h, px
    out = [None] * (w * h * factor * factor)
    i = 0
    for y in range(h):
        row = px[y * w:(y + 1) * w]
        block = []
        for p in row:
            block.extend([p] * factor)
        for _ in range(factor):
            out[i:i + len(block)] = block
            i += len(block)
    return w * factor, h * factor, out


# ======================================================================
# model-pass ship ingestion (--import-ships) — the §4.8 ingestion contract
# ======================================================================

_QUANT_ORDER = sorted(HULL_BLOCK)  # deterministic nearest-color tie-break


def _hex_dist(rgb_a, rgb_b):
    """Channel-sum distance (the §4.8 ingestion metric: Δ per channel,
    summed)."""
    return (abs(rgb_a[0] - rgb_b[0]) + abs(rgb_a[1] - rgb_b[1])
            + abs(rgb_a[2] - rgb_b[2]))


def _quantize_hull_hex(rgb):
    """Nearest 18-hex hull block hex (first-min over the sorted block —
    deterministic)."""
    best_hex, best_d = None, None
    for hx in _QUANT_ORDER:
        d = _hex_dist(rgb, HEXES[hx])
        if best_d is None or d < best_d:
            best_hex, best_d = hx, d
    return best_hex


def _pennant_snap(hexv):
    """The pennant-source snap: any px within Δ≤40 channel-sum of the
    authored source hex lands EXACTLY on it (so the ×9 owner remap hits;
    covers the model's near-miss reds incl. the pirate hex, Δ=27)."""
    if _hex_dist(HEXES[hexv], HEXES[PENNANT_SOURCE]) <= PENNANT_SNAP_RADIUS:
        return PENNANT_SOURCE
    return hexv


def _quantize_token(w, h, px):
    """Formal quantize: every opaque px to the hull block (+ pennant snap);
    transparent px pass through as fully transparent."""
    out = []
    for p in px:
        if p[3] == 0:
            out.append((0, 0, 0, 0))
        else:
            qh = _pennant_snap(_quantize_hull_hex(p[:3]))
            out.append(HEXES[qh] + (255,))
    return out


def _masthead_count(px, w, h):
    """Opaque bbox + the count of pennant-source px in the masthead region
    (top MASTHEAD_TOP_FRAC of the bbox — the sail/masthead zone; the hull
    sits near the canvas bottom, so a bottom-hull red blob is not a
    pennant)."""
    bb = bbox_of(px, w, h)
    if bb is None:
        return None, 0
    x0, y0, x1, y1 = bb
    cut = y0 + int(MASTHEAD_TOP_FRAC * (y1 - y0 + 1) + 0.5)  # exclusive row
    n = 0
    for y in range(y0, min(cut, y1 + 1)):
        for x in range(x0, x1 + 1):
            if "#%02x%02x%02x" % px[x + y * w][:3] == PENNANT_SOURCE:
                n += 1
    return bb, n


def _parse_token_id(tid):
    """``hull_{ship}_{dir}`` → (ship, dir); ship ids may carry underscores
    (caravela_redonda), the dir is the last segment."""
    if not tid.startswith("hull_") or tid.count("_") < 2:
        fail(f"ingest ledger: bad token id {tid!r}")
    ship, d = tid[len("hull_"):].rsplit("_", 1)
    return ship, d


def _parse_file_id(fid):
    """``hull_{ship}_{owner}_{dir}.png`` → (ship, owner, dir)."""
    if not fid.startswith("hull_") or not fid.endswith(".png"):
        fail(f"ingest ledger: bad shipped-file id {fid!r}")
    ship, owner, d = fid[len("hull_"):-len(".png")].rsplit("_", 2)
    return ship, owner, d


def resolve_ingest_overrides(root: Path = ROOT):
    """The override ladder (80-* §4.8: the ingested tokens are the PRIMARY
    art, the ×2-upscale generator is the fallback): a ledger entry whose
    committed token file exists serves that shipped file from the
    committed ingested artifact; every other id falls through to the
    generator.  Returns {(ship, owner, dir): committed path}."""
    if not INGEST_LEDGER.is_file():
        return {}
    try:
        doc = json.loads(INGEST_LEDGER.read_text())
    except ValueError as exc:
        fail(f"{INGEST_LEDGER}: not valid JSON ({exc}) — fix or delete it")
    if int(doc.get("version", 0)) != INGEST_VERSION:
        fail(f"{INGEST_LEDGER}: version {doc.get('version')!r} != "
             f"{INGEST_VERSION}")
    out = {}

    def add(ship, owner, d):
        p = root / TOKENS_DIR / f"hull_{ship}_{owner}_{d}.png"
        if p.is_file():
            out[(ship, owner, d)] = p

    for tid in (doc.get("tokens") or {}):
        ship, d = _parse_token_id(tid)
        for owner in OWNER_ORDER:
            add(ship, owner, d)
    for fid in (doc.get("derived") or {}):
        ship, owner, d = _parse_file_id(fid)
        add(ship, owner, d)
    return out


def run_ship_ingest(snapped_dir: Path, outroot: Path, report: dict) -> dict:
    """The formal model-pass ingestion (90-* §9.2, 80-* §4.8 + f6c00bb).

    Per snapped 64-grid BASE token (n/s/w/sw/nw): decode → formal quantize
    (block nearest + pennant snap) → masthead presence (≥3 source px in
    the top 45% of the bbox) → band gate on the ``w`` base → accept.
    Derived dirs (e/ne/se) are exact mirror_x flips of their accepted
    base, taken BEFORE the pennant remap.  Accepted tokens are remapped
    ×9 and written as the primary shipped token files; a rejected or
    missing base silently falls its whole mirror group back to the
    generator (the build's ladder fills the gaps).  Writes the committed
    provenance ledger; revokes (deletes) previously ingested files whose
    entry did not survive this run so assets and ledger stay exactly
    coherent.  Returns the report fragment."""
    ship_types = json.loads(SHIP_TYPES.read_text())
    roster = ship_types.get("ship_types", ship_types if isinstance(ship_types, list) else [])
    tiers = {s["id"]: int(s["tier"]) for s in roster}
    tokens_dir = outroot / TOKENS_DIR

    prev_tokens, prev_derived = {}, {}
    if INGEST_LEDGER.is_file():
        try:
            prev = json.loads(INGEST_LEDGER.read_text())
        except ValueError as exc:
            fail(f"{INGEST_LEDGER}: not valid JSON ({exc}) — fix or delete it")
        if int(prev.get("version", 0)) != INGEST_VERSION:
            fail(f"{INGEST_LEDGER}: version {prev.get('version')!r} != "
                 f"{INGEST_VERSION}")
        prev_tokens = prev.get("tokens") or {}
        prev_derived = prev.get("derived") or {}

    prog = {}
    pj = snapped_dir.parent / "progress.json"
    if pj.is_file():
        try:
            prog = json.loads(pj.read_text()).get("jobs") or {}
        except ValueError:
            prog = {}  # provenance seed stays null; ingestion proceeds

    today = time.strftime("%Y-%m-%d", time.gmtime())
    candidates = []      # base jobs actually present in the snapped dir
    accepted = {}        # token id -> (w, h, px) in source form (post-snap)
    led_tokens = {}      # token id -> provenance record
    rejected = []
    for ship in sorted(tiers):
        for d in INGEST_BASE_DIRS:
            job = f"hull_{ship}_{d}"
            sp = snapped_dir / f"{job}.png"
            if not sp.is_file():
                continue  # not generated (yet) — a gap, not a rejection
            candidates.append(job)
            raw = sp.read_bytes()
            try:
                w, h, px = decode_png(raw)
            except Exception as exc:  # a concurrent re-roll may be mid-write;
                # reject-and-report, the next re-run picks the file up
                rejected.append({"job": job, "reason": "decode",
                                 "detail": f"snapped PNG does not decode: {exc}"})
                continue
            if (w, h) != (CANVAS, CANVAS):
                rejected.append({"job": job, "reason": "canvas",
                                 "detail": f"{w}x{h} != {CANVAS}x{CANVAS}"})
                continue
            px = _quantize_token(w, h, px)
            bb, n = _masthead_count(px, w, h)
            if n < MASTHEAD_MIN_PX:
                rejected.append({"job": job, "reason": "masthead",
                                 "detail": f"{n} pennant-source px in the "
                                           f"masthead region < {MASTHEAD_MIN_PX}"})
                continue
            if d == "w":  # the banded side profile; mirrors inherit (f6c00bb)
                lo, hi = FOOTPRINT_BANDS[tiers[ship]]
                ext = bb[2] - bb[0] + 1
                if not lo <= ext <= hi:
                    rejected.append({
                        "job": job, "reason": "band",
                        "detail": f"long axis {ext}px outside the "
                                  f"tier-{tiers[ship]} band {lo}-{hi} (§4.8.7)"})
                    continue
            sha = hashlib.sha256(raw).hexdigest()
            prev_rec = prev_tokens.get(job) or {}
            accepted_at = (prev_rec.get("accepted_at")
                           if prev_rec.get("snapped_sha") == sha else None)
            led_tokens[job] = {"job": job,
                               "seed": (prog.get(job) or {}).get("seed"),
                               "snapped_sha": sha,
                               "accepted_at": accepted_at or today}
            accepted[job] = (w, h, px)

    # Derived dirs (f6c00bb): exact mirror_x flips of the accepted base,
    # taken BEFORE the pennant remap (the remap is color-level, so the
    # order is contract, not necessity — the flip must not re-quantize).
    derived_ids = {}     # derived token id -> base token id
    for ship in sorted(tiers):
        for dd, base_d in sorted(INGEST_DERIVED.items()):
            base_job = f"hull_{ship}_{base_d}"
            if base_job not in accepted:
                continue  # whole mirror group falls back (no mixing)
            bw, bh, bpx = accepted[base_job]
            derived_ids[f"hull_{ship}_{dd}"] = base_job
            accepted[f"hull_{ship}_{dd}"] = _transform(bw, bh, bpx, "mirror_x")

    # Write the accepted tokens: the pennant ×9 remap, exactly as on the
    # fallback tokens (the ONLY owner-variant pixel; spain is the legal
    # identity remap).
    written = 0
    for job in sorted(accepted):
        ship, d = _parse_token_id(job)
        w, h, px = accepted[job]
        for owner in OWNER_ORDER:
            table = {PENNANT_SOURCE: HEXES[PENNANTS[owner]]}
            watch = frozenset(s for s, t in table.items()
                              if "#%02x%02x%02x" % t[:3] != s)
            out, leftovers = apply_remap(w, h, px, table, watch)
            if leftovers:
                fail(f"ingest {job}/{owner}: the pennant source survived "
                     f"the remap: {sorted(leftovers)}")
            colors = {("#%02x%02x%02x" % p[:3]) for p in out if p[3]}
            if PENNANTS[owner] not in colors:
                fail(f"ingest {job}/{owner}: the owner pennant hex "
                     f"{PENNANTS[owner]} is missing after the remap")
            off = sorted(c for c in colors if c not in HULL_BLOCK)
            if off:
                fail(f"ingest {job}/{owner}: hexes outside the hull block: {off}")
            if len(colors) > INGEST_INGESTED_BUDGET:
                fail(f"ingest {job}/{owner}: {len(colors)} colors > budget "
                     f"{INGEST_INGESTED_BUDGET} (§4.8.3)")
            write_png(tokens_dir / f"hull_{ship}_{owner}_{d}.png", w, h, out)
            written += 1

    # Provenance revocation: committed ingested files whose entry did not
    # survive this run (source rejected / changed beyond the gates) are
    # removed so the ladder falls those ids back to the generator THIS run
    # (assets == generator ∪ ingested(ledger), exactly).
    def revoke(ship, d):
        for owner in OWNER_ORDER:
            (tokens_dir / f"hull_{ship}_{owner}_{d}.png").unlink(missing_ok=True)

    live_ids = set(accepted)
    stale_ids = set()
    for tid in sorted(prev_tokens):
        if tid not in live_ids:
            stale_ids.add(tid)
    for fid in sorted(prev_derived):
        ship, _owner, d = _parse_file_id(fid)
        tid = f"hull_{ship}_{d}"
        if tid not in live_ids:
            stale_ids.add(tid)
    for tid in sorted(stale_ids):
        ship, d = _parse_token_id(tid)
        revoke(ship, d)
    revoked = len(stale_ids)

    # Derived provenance records (per shipped file, keyed by file name).
    led_derived = {}
    for tid, base_job in sorted(derived_ids.items()):
        ds_ship, dd = _parse_token_id(tid)
        base_ship, base_d = _parse_token_id(base_job)
        for owner in OWNER_ORDER:
            led_derived[f"hull_{ds_ship}_{owner}_{dd}.png"] = {
                "job": tid,
                "derived_from": f"hull_{base_ship}_{owner}_{base_d}.png",
                "flip": "h",
            }

    doc = {
        "version": INGEST_VERSION,
        "generated_by": "tools/build_ui_art.py --import-ships",
        "contract": "docs/80-UI-UX.md §4.8 ingestion contract + the "
                    "5-direction amendment f6c00bb; docs/90-ARCHITECTURE.md "
                    "§9.2",
        "counts": {
            "candidates": len(candidates),
            "accepted_base": len(led_tokens),
            "accepted_derived": len(derived_ids),
            "rejected": len(rejected),
            "revoked_stale": revoked,
            "shipped_files": written,
            "fallback_files": len(tiers) * len(OWNER_ORDER) * len(DIR_ORDER)
                              - written,
        },
        "rejected": rejected,
        "tokens": led_tokens,
        "derived": led_derived,
    }
    INGEST_LEDGER.parent.mkdir(parents=True, exist_ok=True)
    INGEST_LEDGER.write_text(json.dumps(doc, indent=2, ensure_ascii=False,
                                        sort_keys=True) + "\n")

    report["ingest"] = {
        "candidates": len(candidates),
        "accepted_base": len(led_tokens),
        "accepted_derived": len(derived_ids),
        "rejected": rejected,
        "revoked": revoked,
        "files": written,
    }
    return report["ingest"]


# ======================================================================
# manifest loading
# ======================================================================

class Manifests:
    def __init__(self):
        self.classes = {}   # class -> list of parsed files: (path, kind, payload)
        self.renders = {}   # id -> decl (renderable, any class)
        self.derives = []   # derive-only decls
        self.outlines = set()  # ids opted into the outline pass
        self.hull_docs = {}    # ship_type -> authoring doc
        self.aux = {}          # (class, stem) -> dict
        self.render_files = []  # manifest json paths to hand to render.js

    def load(self):
        for cls in CLASS_DIRS:
            cdir = MANIFESTS / cls
            if not cdir.is_dir():
                self.classes[cls] = None
                continue
            files = sorted(cdir.rglob("*.json"))
            if not files:
                self.classes[cls] = None
                continue
            entries = []
            for path in files:
                doc = json.loads(path.read_text())
                kind = self._absorb(cls, path, doc)
                entries.append((path, kind))
            self.classes[cls] = entries

    def _absorb(self, cls, path, doc):
        if isinstance(doc, list):
            items = doc
        elif isinstance(doc, dict) and isinstance(doc.get("sprites"), list):
            items = doc["sprites"]
        else:
            items = [doc]
        for decl in items:
            if not isinstance(decl, dict):
                fail(f"{path}: entry is not an object")
            sid = decl.get("id")
            if "maps" in decl:  # hull authoring doc (registry-driven)
                if cls != "hulls":
                    fail(f"{path}: 'maps' docs are hulls-class only")
                if not sid:
                    fail(f"{path}: hull doc missing 'id'")
                self.hull_docs[decl.get("ship_type", sid)] = (path, decl)
                return "hull-doc"
            has_render = "rows" in decl or "grid" in decl
            d = decl.get("derive")
            is_derive = (isinstance(d, dict) and d.get("op") in DERIVE_OPS
                         and isinstance(derive_base_of(d), str) and "file" in decl)
            if has_render and is_derive:
                fail(f"{path}: {sid!r} cannot carry both render content and 'derive'")
            if has_render:
                if not sid or "file" not in decl:
                    fail(f"{path}: renderable {sid!r} needs 'id' and 'file'")
                if sid in self.renders:
                    fail(f"{path}: duplicate sprite id {sid!r}")
                self.renders[sid] = decl
                if decl.get("outline"):
                    self.outlines.add(sid)
                if path not in self.render_files:
                    self.render_files.append(path)
                return "render" if len(items) == 1 else "multi"
            if is_derive:
                if not sid:
                    fail(f"{path}: derive decl missing 'id'")
                if sid in self.renders:
                    fail(f"{path}: duplicate sprite id {sid!r}")
                self.renders[sid] = decl
                self.derives.append(sid)
                if decl.get("outline"):
                    self.outlines.add(sid)
                # derive-only declarations are PRODUCED by the transform
                # pass from their base artifact — never handed to render.js
                # (master reconciliation 2026-11-04, ledgered: render.js
                # rejects rows-less declarations).
                return "derive" if len(items) == 1 else "multi"
            if len(items) == 1 and not isinstance(doc, list):
                # auxiliary doc (rig.json style library, hulls.json registry,
                # future class-level notes) — no render semantics
                self.aux[(cls, path.stem)] = decl
                return "aux"
            fail(f"{path}: entry {sid!r} has neither rows/grid nor a valid derive")
        return "multi"


# ======================================================================
# pipeline stages
# ======================================================================

def run_node(manifest_files, outroot: Path):
    if not manifest_files:
        return 0
    if shutil.which("node") is None:
        fail("node not found on PATH (pinned v24.16.0)")
    ver = subprocess.run(["node", "--version"], capture_output=True, text=True)
    if ver.returncode != 0:
        fail(f"node --version failed: {ver.stderr.strip()}")
    if ver.stdout.strip() != NODE_PIN:
        fail(f"node {ver.stdout.strip()} != pinned {NODE_PIN} "
             "(byte-identity holds only under the pinned runtime)")
    args = ["node", str(ENGINE)] + [str(p) for p in manifest_files]
    r = subprocess.run(args, cwd=outroot, capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"render.js failed (exit {r.returncode}):\n{r.stderr.strip()}")
    return len(manifest_files)


def write_png(path: Path, w, h, px) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(encode_png_indexed(w, h, px))


def read_png(path: Path):
    if not path.is_file():
        fail(f"expected sprite missing: {path}")
    return decode_png(path.read_bytes())


def parse_hex(h):
    if (not isinstance(h, str) or len(h) != 7 or h[0] != "#"
            or any(c not in "0123456789abcdefABCDEF" for c in h[1:])):
        fail(f"bad hex {h!r}")
    return HEXES[h.lower()]


def run_hull_pipeline(m: Manifests, outroot: Path, staging: Path, report: dict,
                      ingest_files: dict | None = None):
    reg = m.aux.get(("hulls", "hulls"))
    rig = m.aux.get(("hulls", "rig"))
    if reg is None:
        fail("tools/ui_art/hulls/hulls.json registry missing")
    if reg.get("path_template") != f"{TOKENS_DIR}/hull_{{ship_type}}_{{owner}}_{{dir}}.png":
        fail("hulls.json: unexpected path_template (governor contract drift)")
    if list(reg.get("owners", [])) != OWNER_ORDER:
        fail("hulls.json: owners != pinned 9-owner set (§4.8.4)")
    if list(reg.get("authored_dirs", [])) != DIR_ORDER:
        fail(f"hulls.json: authored_dirs != the pinned §4.8.6 dir set {DIR_ORDER} "
             "(UW2 amendment: all eight hull directions are authored maps)")
    if "derive" in reg:
        fail("hulls.json: carries a derive table — the §4.8.6 amendment "
             "removes hull derivation (all eight dirs authored per hull)")
    bands = {int(k): tuple(v) for k, v in
             reg.get("footprint", {}).get("bands", {}).items()}
    if bands != FOOTPRINT_BANDS:
        fail(f"hulls.json: footprint bands {bands} != pinned §4.8.7 {FOOTPRINT_BANDS}")
    if rig is not None:
        pennants = rig.get("pennants", {})
        if pennants.get("source") != PENNANT_SOURCE:
            fail("rig.json: pennant source drifts from the pinned authored "
                 "source hex (§4.8.4 amended)")
        if pennants.get("targets") != PENNANTS:
            fail("rig.json: pennant targets drift from the §4.8.4 amended "
                 "owner table")

    ship_types = json.loads(SHIP_TYPES.read_text())
    roster = ship_types.get("ship_types", ship_types if isinstance(ship_types, list) else [])
    tiers = {s["id"]: int(s["tier"]) for s in roster}

    decl_paths = []
    staging.mkdir(parents=True, exist_ok=True)
    shapes = {}
    for ship, (path, doc) in sorted(m.hull_docs.items()):
        if ship not in tiers:
            fail(f"{path}: ship_type {ship!r} not in data/ship_types.json")
        if doc.get("tier") != tiers[ship]:
            fail(f"{path}: tier {doc.get('tier')} != ship_types.tier {tiers[ship]} for {ship}")
        maps = doc.get("maps", {})
        dirs = {d for d, md in maps.items()
                if isinstance(md, dict) and "rows" in md}
        if dirs == set(DIR_ORDER):
            # Amended UW2 shape: every direction is an authored map.
            if doc.get("derive") is not None:
                fail(f"{path}: 8-map hull doc must not carry derive entries "
                     "(§4.8.6 amendment)")
            shapes[ship] = "uw2"
        elif dirs == {"n", "ne"}:
            # Legacy shape: two authored maps + the pinned six-op derive.
            deriv = doc.get("derive")
            got = {e.get("dir"): (derive_base_of(e), e.get("op"))
                   for e in (deriv or [])}
            if got != PINNED_DERIVE:
                fail(f"{path}: derive table {got} != pinned §4.8.6 table")
            shapes[ship] = "legacy"
        else:
            fail(f"{path}: hull doc maps {sorted(dirs)} are neither the amended "
                 f"8-dir set {sorted(DIR_ORDER)} nor the legacy n/ne set")
        for d in sorted(dirs):
            md = maps[d]
            decl = dict(md)
            decl["file"] = f"{STAGING}/{ship}.{d}.png"
            dp = staging / "decls" / f"{ship}.{d}.json"
            dp.parent.mkdir(parents=True, exist_ok=True)
            dp.write_text(json.dumps(decl))
            decl_paths.append(dp)

    run_node(decl_paths, outroot)

    ink = HEXES[HULL_INK] + (255,)
    counts = {"rendered": 0, "derived": 0, "outlined": 0, "tokens": 0,
              "tokens_ingested": 0}
    for ship, (path, doc) in sorted(m.hull_docs.items()):
        tier = int(doc["tier"])
        lo, hi = FOOTPRINT_BANDS[tier]
        shape = shapes[ship]
        raw = {}  # unoutlined pixels per dir — legacy derivations must source
        # RAW pixels, never the outlined staging files (master reconciliation
        # 2026-11-04, ledgered: outline-before-derive broke §8.8 item 5
        # relations because outline(staging) was re-read as a derive base
        # depending on DIR_ORDER).
        authored = sorted(d for d in doc.get("maps", {})
                          if isinstance(doc["maps"][d], dict)
                          and "rows" in doc["maps"][d])
        for d in authored:
            w, h, px = read_png(staging / f"{ship}.{d}.png")
            raw[d] = (w, h, px)
        staged = {}
        for d in DIR_ORDER:
            if d in raw:
                w, h, px = raw[d]
            else:
                src_d, op = PINNED_DERIVE[d]
                w, h, bpx = raw[src_d]
                w, h, px = _transform(w, h, bpx, op)
                raw[d] = (w, h, px)
                counts["derived"] += 1
            px = apply_outline(w, h, px, ink)
            write_png(staging / f"{ship}.{d}.png", w, h, px)
            counts["outlined"] += 1
            staged[d] = (w, h, px)
        counts["rendered"] += len(authored)

        # The §4.8 64-canvas fallback (amendment 1664ba9): the shipped token
        # canvas is the exact ×2 nearest upscale of the outlined authored
        # 32-grid render — ids/filenames unchanged, transparency preserved.
        staged64 = {}
        for d in DIR_ORDER:
            wd, hd, pd = staged[d]
            staged64[d] = upscale_nearest(wd, hd, pd, CANVAS // AUTHORED_GRID)

        # footprint (§4.8.7 amendment + the 64-canvas upgrade): the band is
        # measured on the side view (e/w long axis — the profile that shows
        # the ship's length) of the final 64×64 canvas; n/s (beam views) and
        # the diagonals are canvas-fit only.
        side = []
        for d in ("e", "w"):
            wd, hd, pd = staged64[d]
            bb = bbox_of(pd, wd, hd)
            ext = bb[2] - bb[0] + 1
            side.append(ext)
            if not (lo <= ext <= hi):
                fail(f"hull {ship}: {d} long axis {ext}px outside tier-{tier} "
                     f"band {lo}-{hi} on the {CANVAS}px canvas (§4.8.7)")
            if ext + 2 > CANVAS:
                fail(f"hull {ship}: {d} footprint {ext}px + outline exceeds "
                     f"{CANVAS}px canvas")
        for d in ("n", "s", "ne", "nw", "se", "sw"):
            wd, hd, pd = staged64[d]
            bb = bbox_of(pd, wd, hd)
            fit = max(bb[2] - bb[0] + 1, bb[3] - bb[1] + 1)
            if fit + 2 > CANVAS:
                fail(f"hull {ship}: {d} footprint {fit}px + outline exceeds "
                     f"{CANVAS}px canvas")
        report.setdefault("footprints", []).append(
            (ship, tier, side[0], side[1], (lo, hi)))

        for owner in OWNER_ORDER:
            # Pennant remap (§4.8.4 amended): the ONLY owner-variant pixel —
            # wood/sail/ink/gold pass through untouched; spain's remap is the
            # legal identity (its pennant value equals the source hex). The
            # remap runs on the authored grid; the ×2 upscale commutes with
            # the per-hex substitution, so the shipped 64 canvas carries it.
            table = {PENNANT_SOURCE: HEXES[PENNANTS[owner]]}
            watch = frozenset(s for s, t in table.items()
                              if "#%02x%02x%02x" % t[:3] != s)
            for d in DIR_ORDER:
                w, h, px = staged[d]
                out, leftovers = apply_remap(w, h, px, table, watch)
                if leftovers:
                    fail(f"hull {ship}/{owner}/{d}: the pennant source hex "
                         f"survived the remap: {sorted(leftovers)}")
                colors = {("#%02x%02x%02x" % p[:3]) for p in out if p[3]}
                if shape == "uw2" and PENNANTS[owner] not in colors:
                    fail(f"hull {ship}/{owner}/{d}: the owner pennant hex "
                         f"{PENNANTS[owner]} is missing — every variant of "
                         "an amended-shape hull must carry its remapped "
                         "masthead pennant (§8.8 item 6, pennant remap "
                         "coverage; legacy-shape docs are exempt pending "
                         "re-authoring)")
                off = sorted(c for c in colors if c not in HULL_BLOCK)
                if off:
                    fail(f"hull {ship}/{owner}/{d}: hexes outside the hull block (§4.8.4): {off}")
                if len(colors) > COLOR_BUDGET_32:
                    fail(f"hull {ship}/{owner}/{d}: {len(colors)} colors > budget {COLOR_BUDGET_32} (§4.8.3)")
                # The shipped 64×64 canvas: ×2 of the remapped authored grid.
                # Override ladder (§4.8 ingestion contract): an ingested
                # token (ledger entry + committed file) is the PRIMARY art —
                # the generator's file is written ONLY for the gaps
                # (per-file presence; a rejected/missing model token
                # silently falls back).  The fallback render + gates above
                # still run so generator art stays validated either way.
                dest = outroot / TOKENS_DIR / f"hull_{ship}_{owner}_{d}.png"
                override = (ingest_files or {}).get((ship, owner, d))
                if override is not None and override.is_file():
                    if override != dest:
                        shutil.copyfile(override, dest)
                    counts["tokens_ingested"] += 1
                    continue
                write_png(dest, *upscale_nearest(w, h, out,
                                                 CANVAS // AUTHORED_GRID))
                counts["tokens"] += 1
    return counts


def run_generic_passes(m: Manifests, outroot: Path, report: dict):
    counts = {"rendered": 0, "derived": 0, "outlined": 0}
    counts["rendered"] = run_node(m.render_files, outroot)
    memo = {}

    def pixels_of(sid, seen=()):
        if sid in memo:
            return memo[sid]
        if sid in seen:
            fail(f"derive cycle at {sid!r}")
        decl = m.renders[sid]
        d = decl.get("derive")
        if d is None:
            w, h, px = read_png(outroot / decl["file"])
        else:
            if derive_base_of(d) not in m.renders:
                fail(f"derive {sid!r}: base id {d['from']!r} not found in any manifest")
            w, h, bpx = pixels_of(derive_base_of(d), seen + (sid,))
            w, h, px = _transform(w, h, bpx, d["op"])
            write_png(outroot / decl["file"], w, h, px)
            counts["derived"] += 1
        memo[sid] = (w, h, px)
        return w, h, px

    for sid in sorted(m.renders):
        pixels_of(sid)
    for sid in sorted(m.outlines):
        w, h, px = pixels_of(sid)
        px = apply_outline(w, h, px, HEXES[HULL_INK] + (255,))
        write_png(outroot / m.renders[sid]["file"], w, h, px)
        counts["outlined"] += 1
    # §4.8 64-canvas fallback (amendment 1664ba9): the terrain class ships
    # 64×64 canvases — the exact ×2 nearest upscale of the authored 32-grid
    # render (terrain tiles, shore strips, port markers; a source already
    # authored at 64 — sea_pattern — passes through at 1:1). Same ids and
    # filenames; runs before the seam-ring verify so the ring reads the
    # shipped canvases.
    for sid in sorted(m.renders):
        decl = m.renders[sid]
        if not str(decl.get("file", "")).startswith(TERRAIN_OUT_PREFIX):
            continue
        w, h, px = read_png(outroot / decl["file"])
        side = max(w, h)
        if side >= CANVAS:
            continue
        if CANVAS % side != 0:
            fail(f"{decl['file']}: authored grid {w}x{h} cannot reach the "
                 f"{CANVAS}px canvas by an integer nearest factor (§4.8 "
                 "64-canvas amendment)")
        write_png(outroot / decl["file"],
                  *upscale_nearest(w, h, px, CANVAS // side))
    return counts


def run_seam_ring(m: Manifests, outroot: Path, report: dict):
    """Verify (never alter): variants of a terrain kind share a byte-identical
    outer 1px ring; sea_pattern is torus-safe (80-* §4.8.2)."""
    adir = outroot / "assets/ui"
    if not adir.is_dir():
        return
    groups = {}
    for p in sorted(adir.rglob("*.png")):
        mo = re.fullmatch(r"terrain_([a-z_]+)_(\d+)\.png", p.name)
        if mo:
            groups.setdefault(mo.group(1), []).append(p)
        elif p.name == "sea_pattern.png":
            report["sea_pattern"] = p
    for kind, files in sorted(groups.items()):
        if len(files) < 2:
            continue
        rings = []
        for p in files:
            w, h, px = read_png(p)
            ring = tuple(px[:w]) + tuple(px[(h - 1) * w:h * w]) \
                + tuple(px[y * w] for y in range(h)) + tuple(px[y * w + w - 1] for y in range(h))
            rings.append((p, ring))
        base_p, base = rings[0]
        for p, ring in rings[1:]:
            if ring != base:
                fail(f"seam ring mismatch for terrain kind '{kind}': {p.name} vs {base_p.name} (§4.8.2)")
        report.setdefault("seam_kinds", []).append((kind, len(files)))
    pat = report.get("sea_pattern")
    if pat is not None:
        w, h, px = read_png(pat)
        # Torus-safety machine proxy (master reconciliation 2026-11-04,
        # ledgered): the mask repeats as an exact tile — any array wraps
        # continuously — so the visible-seam risk is structural banding.
        # Require exactly two levels and UNIFORM level-1 density on every
        # row and every column (C's 4-periodic lattices satisfy this).
        levels = sorted({p for p in px})
        if len(levels) != 2:
            fail(f"{pat.name}: two-level mask expected, got {len(levels)} "
                 "levels (§4.8.2)")
        hi = levels[1]
        row_counts = [sum(1 for p in px[y * w:(y + 1) * w] if p == hi)
                      for y in range(h)]
        col_counts = [sum(1 for y in range(h) if px[y * w + x] == hi)
                      for x in range(w)]
        if len(set(row_counts)) != 1 or len(set(col_counts)) != 1:
            fail(f"{pat.name}: level-1 density is not uniform per row/column "
                 "— the repeating tile would band at the wrap (§4.8.2 torus "
                 "rule)")
        report["seam_kinds"] = report.get("seam_kinds", []) + [("sea_pattern", 1)]


def find_tile(adir: Path, name: str) -> Path | None:
    for prefix in ("", "tile_"):
        p = adir / f"{prefix}{name}.png"
        if p.is_file():
            return p
    return None


def _oriented_px(px, op):
    """Independent orientation math for the nine-patch self-verify: new(x, y)
    for a square TILExTILE tile.  Deliberately a re-derivation, NOT a
    ``_transform`` call — a regression there must not be able to confirm its
    own output (``_verify_transforms`` pins ``_transform`` separately)."""
    if op is None:
        return list(px)
    if op == "mirror_x":
        f = lambda x, y: px[(TILE - 1 - x) + y * TILE]
    elif op == "mirror_y":
        f = lambda x, y: px[x + (TILE - 1 - y) * TILE]
    elif op == "mirror_xy":
        f = lambda x, y: px[(TILE - 1 - x) + (TILE - 1 - y) * TILE]
    elif op == "rot_ccw":
        f = lambda x, y: px[(TILE - 1 - y) + x * TILE]
    elif op == "rot_cw":
        f = lambda x, y: px[y + (TILE - 1 - x) * TILE]
    else:
        fail(f"ninepatch self-verify: unknown orientation {op!r}")
    return [f(x, y) for y in range(TILE) for x in range(TILE)]


# per-position cell -> (source part, orientation op).  The chrome tiles are
# authored as the TOP-LEFT corner / TOP edge only; every other frame cell is
# a lossless orientation of those (2026-11-04 chrome fix: blitting the raw
# TL tiles into all nine cells put TL-shaped corners and horizontal border
# lines into the TR/BL/BR and left/right/bottom cells — the assembled sheet
# sampled broken regions and every themed Button rendered as scattered
# corner-bracket fragments).
FRAME_OPS = {
    (0, 0): ("corner", None),                              # TL — as authored
    (SHEET - TILE, 0): ("corner", "mirror_x"),             # TR
    (0, SHEET - TILE): ("corner", "mirror_y"),             # BL
    (SHEET - TILE, SHEET - TILE): ("corner", "mirror_xy"),  # BR
    (TILE, 0): ("edge", None),                             # top — as authored
    (TILE, SHEET - TILE): ("edge", "mirror_y"),            # bottom
    (0, TILE): ("edge", "rot_ccw"),                        # left — border col 0
    (SHEET - TILE, TILE): ("edge", "rot_cw"),              # right — border col 15
    (TILE, TILE): ("fill", None),                          # center
}


def _cell_pixels(sheet, dx, dy):
    """A 16x16 cell of `sheet` at tile offset (dx, dy), row-major."""
    return [sheet[(dx + x) + (dy + y) * SHEET]
            for y in range(TILE) for x in range(TILE)]


def _hex_px(h: str):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5)) + (255,)


# Gold-pixel map (rule 5 below; the title-screen bracket regression,
# 2026-11-04): under margin-16 nine-patch slicing a corner tile's INNER 1px
# is the band boundary mid-edge of every control — the button corner tiles
# used to carry a 14px gold "tick" there and every menu button rendered
# crisp ⊢-brackets at ~1/3 and ~2/3 of its height. Gold may exist only
# where the design pins it: NOWHERE on `button`; perimeter + corner
# rosettes on `button_focus`; the inset trim + rosettes on `panel`; the
# lip inset on `field`.
GOLD_FAMILY = {ACCENT, ACCENT_HI, ACCENT_LO}


def _in_rosette(x, y):
    return ((2 <= x <= 4) or (43 <= x <= 45)) \
        and ((2 <= y <= 4) or (43 <= y <= 45))


def _gold_allowed(name, x, y):
    if name == "button":
        return False
    if name == "field":
        return x in (1, 46) or y in (1, 46)
    if name == "panel":
        return x in (3, 44) or y in (3, 44) or _in_rosette(x, y)
    return x in (0, 47) or y in (0, 47) or _in_rosette(x, y)  # button_focus


def _verify_gold_map(name, sheet) -> None:
    gold = [(x, y) for y in range(SHEET) for x in range(SHEET)
            if sheet[x + y * SHEET][3]
            and ("#%02x%02x%02x" % sheet[x + y * SHEET][:3]) in GOLD_FAMILY]
    bad = [(x, y) for x, y in gold if not _gold_allowed(name, x, y)]
    if bad:
        fail(f"ninepatch {name}: self-verify — gold pixel(s) outside the "
             f"pinned gold map (mid-edge bracket class): {bad[:8]}")
    if name != "button" and not gold:
        fail(f"ninepatch {name}: self-verify — the sheet lost its gold "
             "trim/rosette/lip pixels entirely (gold map)")
    if name == "button" and gold:
        fail(f"ninepatch {name}: self-verify — the plain button sheet must "
             f"carry no gold at all, found {len(gold)} px (gold map)")


# UW2 chrome-skin semantic pins (80-* §4.8 amended 2026-11-04, ledgered):
# per sheet, the explicit anchor hexes the assembled 48x48 must carry. Rule 3
# below pins frame POSITIONS tile-derivatively; these pin the SKIN's colors —
# a re-author that loses the gold inner line, the bevel line or a rosette
# fails the build. Anchors sit in the top-left cell / top edge cell (their
# mirrors cover the rest of the sheet by rule 1).
SKIN_PINS = {
    "panel": [
        (24, 0, PANEL_WOOD_LO, "frame dark outline"),
        (24, 1, PANEL_WOOD_HI, "bevel light line"),
        (24, 3, ACCENT, "gold inner line (inset 3px)"),
        (3, 3, ACCENT_HI, "brass rosette center"),
        (2, 2, ACCENT_LO, "brass rosette base"),
    ],
    "button": [
        (24, 0, PANEL_WOOD_HI, "raised-block bevel light (top)"),
        (24, 1, PANEL_WOOD, "walnut fill under the bevel"),
    ],
    "button_focus": [
        (24, 0, ACCENT, "full gold perimeter (selected/hover ring)"),
        (24, 1, PANEL_WOOD, "walnut fill under the ring"),
        (3, 3, ACCENT_HI, "gold rosette center"),
    ],
    "field": [
        (24, 0, PANEL_WOOD_LO, "recess frame"),
        (24, 1, ACCENT_LO, "recess inner lip"),
    ],
}


def _audit_chrome_tile(label: str, w, h, px) -> None:
    """Chrome tile color audit (§4.8.4 membership + the per-tile color
    discipline; parity with the hull color audit, step 7)."""
    colors = {("#%02x%02x%02x" % p[:3]) for p in px if p[3]}
    off = sorted(c for c in colors if c not in ICON_BLOCK)
    if off:
        fail(f"ninepatch: chrome tile {label} hexes outside the icon block "
             f"(§4.8.4): {off}")
    if len(colors) > CHROME_COLOR_CAP:
        fail(f"ninepatch: chrome tile {label} carries {len(colors)} distinct "
             f"colors > the {CHROME_COLOR_CAP} per-tile cap")


def _verify_ninepatch_sheet(name, tiles, sheet) -> None:
    """Pixel-exact self-verification of one assembled sheet — any mismatch
    is a build FAIL (§4.8.8; makes the misaligned-sheet class of bug
    impossible to ship: the committed 04373ef sheets failed rules 1, 3)."""
    # 1. every 16x16 cell byte-equals the oriented source tile.
    for (dx, dy), (part, op) in FRAME_OPS.items():
        want = _oriented_px(tiles[part][2], op)
        got = _cell_pixels(sheet, dx, dy)
        for i, (g, w) in enumerate(zip(got, want)):
            if g != w:
                x, y = i % TILE, i // TILE
                fail(f"ninepatch {name}: self-verify — cell ({dx},{dy}) pixel "
                     f"({dx + x},{dy + y}) = {g} != oriented {part}"
                     f"{' ' + op if op else ''} {w}")
    # 2. content areas (edge + fill cells) fully opaque — transparent pixels
    #    live ONLY in the corner cells, exactly where the corner tiles carry
    #    the authored outer rounding.
    for (dx, dy), (part, _) in FRAME_OPS.items():
        if part == "corner":
            continue
        for y in range(TILE):
            for x in range(TILE):
                if sheet[(dx + x) + (dy + y) * SHEET][3] != 255:
                    fail(f"ninepatch {name}: self-verify — transparent pixel "
                         f"in the {part} cell at ({dx + x},{dy + y}) "
                         "(content areas must be opaque)")
    # 3. semantic frame pins, tile-derived (orientation traps — a sheet
    #    assembled from un-oriented tiles fails every one of these):
    #    border hex on all four side centers + the corner frame anchors,
    #    fill hex at the sheet center, transparent outer rounding at the
    #    far corners.
    border = tiles["edge"][2][0]      # top edge tile (0,0)
    fill = tiles["fill"][2][0]        # fill tile (0,0)
    for x, y, want, what in [
            (TILE + 8, 0, border, "top side center"),
            (0, TILE + 8, border, "left side center (border column)"),
            (SHEET - 1, TILE + 8, border, "right side center (border column)"),
            (TILE + 8, SHEET - 1, border, "bottom side center"),
            (4, 0, border, "TL frame (past the authored rounding)"),
            (0, 4, border, "TL frame (past the authored rounding)"),
            (TILE + 8, TILE + 8, fill, "sheet center"),
            (SHEET - 1, 0, None, "TR outer rounding"),
            (0, SHEET - 1, None, "BL outer rounding"),
            (SHEET - 1, SHEET - 1, None, "BR outer rounding"),
    ]:
        got = sheet[x + y * SHEET]
        if want is None:
            if got[3] != 0:
                fail(f"ninepatch {name}: self-verify — ({x},{y}) must be the "
                     "transparent outer rounding (authored corner design)")
        elif got != want:
            fail(f"ninepatch {name}: self-verify — {what} ({x},{y}) = {got} "
                 f"!= {want}")
    # 4. UW2 chrome-skin semantic pins (§4.8 amended 2026-11-04, ledgered):
    #    the skin's own colors at their pinned anchors.
    for x, y, hexs, what in SKIN_PINS.get(name, []):
        got = sheet[x + y * SHEET]
        if got != _hex_px(hexs):
            fail(f"ninepatch {name}: self-verify — {what} ({x},{y}) = {got} "
                 f"!= {_hex_px(hexs)}")
    # 5. gold-pixel map (see GOLD_FAMILY above).
    _verify_gold_map(name, sheet)


def _verify_bar_sheet(caps, sheet) -> None:
    """Pixel-exact self-verification of the bar sheet: caps byte-exact at
    x 0 / x 32 of the rows 16..31 band, the line tile between, everything
    outside the band transparent (the committed 04373ef bar sheet failed
    the cap rules — `blit` never drew them)."""
    for dx, part in ((0, "left"), (SHEET - TILE, "right")):
        if _cell_pixels(sheet, dx, TILE) != list(caps[part][2]):
            fail(f"ninepatch bar: self-verify — {part} cap cell at ({dx},"
                 f"{TILE}) is not the byte-exact bar_{part} tile")
    if _cell_pixels(sheet, TILE, TILE) != list(caps["line"][2]):
        fail("ninepatch bar: self-verify — the line band at (16,16) is not "
             "the byte-exact bar_line tile")
    for y in range(SHEET):
        if TILE <= y < 2 * TILE:
            continue
        for x in range(SHEET):
            if sheet[x + y * SHEET][3] != 0:
                fail(f"ninepatch bar: self-verify — non-transparent pixel "
                     f"({x},{y}) outside the rows {TILE}..{2 * TILE - 1} band")


def run_ninepatch(m: Manifests, outroot: Path, report: dict):
    """Assemble the 48x48 sheets from A's 16x16 chrome tiles (step 5) and
    self-verify every sheet pixel-exactly (build FAIL on any mismatch)."""
    adir = outroot / "assets/ui/chrome"
    if not adir.is_dir():
        return "skipped (no chrome output)"
    made = 0
    for s in NINEPATCH_SETS:
        tiles = {}
        for part in ("corner", "edge", "fill"):
            p = find_tile(adir, f"{s}_{part}")
            if p is None:
                tiles = None
                break
            tiles[part] = read_png(p)
        if tiles is None:
            report.setdefault("ninepatch_notes", []).append(
                f"{s}: tiles missing (expected chrome_{s}_{{corner,edge,fill}}.png)")
            continue
        for img in tiles.values():
            if img[0] != TILE or img[1] != TILE:
                fail(f"ninepatch {s}: chrome tiles must be {TILE}x{TILE} (§4.8.8)")
        for part, img in tiles.items():
            _audit_chrome_tile(f"{s}_{part}", img[0], img[1], img[2])
        sheet = [(0, 0, 0, 0)] * (SHEET * SHEET)
        for (dx, dy), (part, op) in FRAME_OPS.items():
            _, _, px = tiles[part]
            if op is not None:
                _, _, px = _transform(TILE, TILE, px, op)
            for r in range(TILE):
                for c in range(TILE):
                    sheet[(dx + c) + (dy + r) * SHEET] = px[c + r * TILE]
        _verify_ninepatch_sheet(s, tiles, sheet)
        write_png(outroot / f"assets/ui/chrome/ninepatch_{s}.png", SHEET, SHEET, sheet)
        made += 1
    caps = {}
    for part in BAR_PARTS:
        p = find_tile(adir, f"bar_{part}")
        if p is None:
            caps = None
            break
        caps[part] = read_png(p)
    if caps is not None:
        for part, img in caps.items():
            _audit_chrome_tile(f"bar_{part}", img[0], img[1], img[2])
        sheet = [(0, 0, 0, 0)] * (SHEET * SHEET)

        def blit(img, dx, dy, repeat_to=0):
            # repeat_to = total px width to fill (0 = single blit).  The old
            # `while x < repeat_to` loop treated the single-shot default as
            # "draw nothing" and silently dropped both bar caps.
            _, _, px = img
            w = img[0]
            x = 0
            while True:
                for r in range(img[1]):
                    for c in range(w):
                        sheet[(dx + x + c) + (dy + r) * SHEET] = px[c + r * w]
                if repeat_to == 0 or x + w >= repeat_to:
                    break
                x += w
        # bar sheet: caps at the far ends of the horizontal midline band
        # (rows 16..31), line tile tiled between — the kit's value_bar
        # samples this 48x16 band (step 5 comment in the docstring).
        blit(caps["left"], 0, TILE)
        blit(caps["line"], TILE, TILE, repeat_to=SHEET - 2 * TILE)
        blit(caps["right"], SHEET - TILE, TILE)
        _verify_bar_sheet(caps, sheet)
        write_png(outroot / "assets/ui/chrome/ninepatch_bar.png", SHEET, SHEET, sheet)
        made += 1
    elif NINEPATCH_SETS and made:
        report.setdefault("ninepatch_notes", []).append(
            "bar: tiles missing (expected chrome bar_{left,right,line}.png)")
    return f"{made} sheets (self-verified pixel-exact)"


# ======================================================================
# contact sheet (decision 9.4) — stdlib compose + 3x5 bitmap font
# ======================================================================

FONT = {
    "A": [2, 5, 7, 5, 5], "B": [6, 5, 6, 5, 6], "C": [3, 4, 4, 4, 3],
    "D": [6, 5, 5, 5, 6], "E": [7, 4, 6, 4, 7], "F": [7, 4, 6, 4, 4],
    "G": [3, 4, 5, 5, 3], "H": [5, 5, 7, 5, 5], "I": [7, 2, 2, 2, 7],
    "J": [1, 1, 1, 5, 2], "K": [5, 5, 6, 5, 5], "L": [4, 4, 4, 4, 7],
    "M": [5, 7, 5, 5, 5], "N": [6, 5, 5, 5, 5], "O": [2, 5, 5, 5, 2],
    "P": [6, 5, 6, 4, 4], "Q": [2, 5, 5, 6, 3], "R": [6, 5, 6, 5, 5],
    "S": [3, 4, 2, 1, 6], "T": [7, 2, 2, 2, 2], "U": [5, 5, 5, 5, 7],
    "V": [5, 5, 5, 5, 2], "W": [5, 5, 5, 7, 5], "X": [5, 5, 2, 5, 5],
    "Y": [5, 5, 2, 2, 2], "Z": [7, 1, 2, 4, 7],
    "0": [7, 5, 5, 5, 7], "1": [2, 6, 2, 2, 7], "2": [6, 1, 2, 4, 7],
    "3": [6, 1, 2, 1, 6], "4": [5, 5, 7, 1, 1], "5": [7, 4, 6, 1, 6],
    "6": [3, 4, 7, 5, 7], "7": [7, 1, 2, 2, 2], "8": [7, 5, 7, 5, 7],
    "9": [7, 5, 7, 1, 6],
    "-": [0, 0, 7, 0, 0], ".": [0, 0, 0, 0, 2], "_": [0, 0, 0, 0, 7],
    ":": [0, 2, 0, 2, 0], "/": [1, 1, 2, 4, 4], "(": [1, 2, 2, 2, 1],
    ")": [4, 2, 2, 2, 4], " ": [0, 0, 0, 0, 0],
}
BG = (0x1C, 0x22, 0x30, 255)     # PANEL_BG
FG = (0xE8, 0xE6, 0xDF, 255)     # TEXT
GRID = (0x46, 0x54, 0x68, 255)   # PANEL_LINE
ACC = (0xD9, 0xA4, 0x41, 255)    # ACCENT


class Sheet:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [BG] * (w * h)

    def blit(self, w, h, px, dx, dy):
        for r in range(h):
            if not (0 <= dy + r < self.h):
                continue
            for c in range(w):
                if 0 <= dx + c < self.w:
                    p = px[c + r * w]
                    if p[3]:
                        self.px[(dx + c) + (dy + r) * self.w] = p[:3] + (255,)

    def text(self, s, dx, dy, color=FG, scale=1):
        for i, ch in enumerate(s):
            glyph = FONT.get(ch.upper(), FONT[" "])
            for gr in range(5):
                bits = glyph[gr]
                for gc in range(3):
                    if bits & (4 >> gc):
                        for sr in range(scale):
                            for sc in range(scale):
                                self.blit(1, 1, [color], dx + (i * 4 + gc) * scale + sc,
                                          dy + gr * scale + sr)

    def hline(self, dy, color=GRID):
        for c in range(self.w):
            self.px[c + dy * self.w] = color


def build_contact_sheet(outroot: Path, m: Manifests) -> Path:
    adir = outroot / "assets/ui"

    def img(rel):
        p = adir / rel
        return read_png(p) if p.is_file() else None

    sections = []  # (title, list_of_(w,h,px,dx offsets handled inline))
    # hulls grid: 16 hulls x 9 owners, canonical dir 'n'
    reg = m.aux.get(("hulls", "hulls.json"), {})
    ships = list(reg.get("hulls", sorted(m.hull_docs)))
    owners = OWNER_ORDER
    cw, ch = CANVAS + 2, CANVAS + 2
    grid_w = 8 * 3 * 2 + 8 + len(ships) * cw
    rows_h = 8 + len(ships) * ch
    hull_grid = Sheet(grid_w, rows_h)
    hull_grid.text("HULLS X OWNERS (DIR N)", 0, 0, ACC)
    for j, o in enumerate(owners):
        hull_grid.text(o.upper()[:3], (16 * 3) + 8 + j * cw + 8, 10, GRID)
    for i, s in enumerate(ships):
        hull_grid.text(s.upper(), 0, 24 + i * ch + 10)
        for j, o in enumerate(owners):
            im = img(f"tokens/hull_{s}_{o}_n.png")
            if im:
                hull_grid.blit(im[0], im[1], im[2], 8 * 3 * 2 + 8 + j * cw, 24 + i * ch)
            hull_grid.px[(8 * 3 * 2 + 4 + j * cw) + (24 + i * ch) * grid_w] = GRID
    sections.append(("HULL TOKENS - 16 SHIPS X 9 OWNERS (CANONICAL N)", [hull_grid]))

    dirs_strip = Sheet(8 * (CANVAS + 4) + 24 * 4, CANVAS + 22)
    dirs_strip.text("8-DIR FAMILY (GALLEON, NEUTRAL)", 0, 0, ACC)
    for k, d in enumerate(DIR_ORDER):
        dirs_strip.text(d.upper(), k * (CANVAS + 4) + 8, 10, GRID)
        im = img(f"tokens/hull_galleon_neutral_{d}.png")
        if im:
            dirs_strip.blit(im[0], im[1], im[2], k * (CANVAS + 4) + 8, 18)
    sections.append(("HEADING8 FAMILY (DERIVED LOSSLESSLY - §4.8.6)", [dirs_strip]))

    facs = Sheet(6 * (CANVAS + 6) + 40 * 4, CANVAS + 22)
    facs.text("FACILITY TOKENS", 0, 0, ACC)
    for k, name in enumerate(["market", "shipyard", "tavern", "inn", "guild", "palace"]):
        facs.text(name.upper(), k * (CANVAS + 6) + 8, 10, GRID)
        im = img(f"tokens/facility_{name}.png")
        if im:
            facs.blit(im[0], im[1], im[2], k * (CANVAS + 6) + 8, 18)
    sections.append(("FACILITY TOKENS (TOKEN CLASS - OUTLINED)", [facs]))

    for cls, label in (("chrome", "CHROME TILES + NINE-PATCH SHEETS"),
                       ("icons", "SEMANTIC ICONS"),
                       ("markers", "WORLD MARKERS (A.4)"),
                       ("terrain", "TERRAIN + SHORE"),
                       ("fx", "FX FRAMES"),
                       ("portraits", "PORTRAIT SHEETS")):
        files = sorted((adir / cls).rglob("*.png")) if (adir / cls).is_dir() else []
        if not files:
            sections.append((label + " - (ABSENT: STAGED)", []))
            continue
        if cls == "chrome":
            sheets = [f for f in files if f.name.startswith("ninepatch_")]
            tiles = [f for f in files if f not in sheets]
            row = Sheet(min(len(tiles), 30) * 34 + 6 * 52 + 8, 54)
            x = 4
            for t in tiles[:30]:
                im = read_png(t)
                for sy in range(2):
                    for sx in range(2):
                        row.blit(im[0], im[1], im[2], x + sx * im[0], 10 + sy * im[1])
                x += im[0] * 2 + 2
            x += 8
            for t in sheets[:6]:
                im = read_png(t)
                row.blit(im[0], im[1], im[2], x, 3)
                x += im[0] + 4
            sections.append((label, [row]))
        else:
            per = 20 if cls == "icons" else 10
            chunks = [files[i:i + per] for i in range(0, len(files), per)]
            out_rows = []
            for chunk in chunks:
                row = Sheet(min(len(chunk), per) * 36 + 8, 42)
                for k, t in enumerate(chunk[:per]):
                    im = read_png(t)
                    row.blit(im[0], im[1], im[2], k * 36 + 4, 5)
                out_rows.append(row)
            sections.append((label + f" ({len(files)} FILES, FIRST {min(len(files), per * 5)})", out_rows))

    seam_rows = []
    terrain_files = sorted((adir / "terrain").rglob("terrain_*_*.png")) if (adir / "terrain").is_dir() else []
    kinds = {}
    for t in terrain_files:
        parts = t.stem.split("_")
        kinds.setdefault("_".join(parts[1:-1]), []).append(t)
    for kind, fs in sorted(kinds.items()):
        for f in fs[:4]:
            im = read_png(f)
            tile = Sheet(CANVAS * 3, CANVAS * 3)
            for ty in range(3):
                for tx in range(3):
                    tile.blit(im[0], im[1], im[2], tx * CANVAS, ty * CANVAS)
            seam_rows.append(tile)
        break  # one kind sampled keeps the sheet bounded
    pat = adir / "terrain" / "sea_pattern.png"
    if pat.is_file():
        im = read_png(pat)
        p2 = Sheet(im[0] * 2, im[1] * 2)
        for ty in range(2):
            for tx in range(2):
                p2.blit(im[0], im[1], im[2], tx * im[0], ty * im[1])
        seam_rows.append(p2)
    sea = adir / "terrain" / "terrain_sea_0.png"
    land = None
    for f in terrain_files:
        if "land" in f.name:
            land = f
            break
    if land is not None and sea.is_file():
        mock = Sheet(CANVAS * 3, CANVAS * 3)
        sim = read_png(sea)
        lim = read_png(land)
        for ty in range(3):
            for tx in range(3):
                mock.blit(sim[0], sim[1], sim[2], tx * CANVAS, ty * CANVAS)
        dirs = ["nw", "n", "ne", "w", "e", "sw", "s", "se"]
        pos = [(0, 0), (1, 0), (2, 0), (0, 1), (2, 1), (0, 2), (1, 2), (2, 2)]
        for d, (tx, ty) in zip(dirs, pos):
            sp = adir / "terrain" / f"shore_{d}.png"
            if sp.is_file():
                sim2 = read_png(sp)
                mock.blit(sim2[0], sim2[1], sim2[2], tx * CANVAS, ty * CANVAS)
            elif (tx, ty) != (1, 1):
                mock.blit(lim[0], lim[1], lim[2], tx * CANVAS, ty * CANVAS)
        mock.blit(lim[0], lim[1], lim[2], CANVAS, CANVAS)
        seam_rows.append(mock)
    if seam_rows:
        sections.append(("SEAM MONTAGE - 3X3 TILE, SEA PATTERN 2X2, SHORE CORNER MOCK", seam_rows))
    else:
        sections.append(("SEAM MONTAGE - (ABSENT: STAGED)", []))

    width = 900
    total_h = 30 + sum(18 + sum(s.h + 6 for s in rows) for _, rows in sections) + 10
    sheet = Sheet(width, total_h)
    sheet.text("SAILAGE UI ART KIT - GENERATED BY TOOLS/BUILD_UI_ART.PH (W3-B)", 8, 8, ACC, 2)
    y = 30
    for title, rows in sections:
        sheet.text(title, 8, y, FG)
        y += 14
        for srow in rows:
            sheet.hline(y, GRID)
            sheet.blit(srow.w, srow.h, srow.px, 4, y + 2)
            y += srow.h + 6
    return ROOT / "tools" / "contact_sheet.png", sheet


# ======================================================================
# build / check / main
# ======================================================================

def build_into(outroot: Path, ingest_files: dict | None = None) -> tuple[Manifests, dict]:
    _verify_transforms()
    m = Manifests()
    m.load()
    report = {}
    (outroot / STAGING).mkdir(parents=True, exist_ok=True)
    try:
        if m.classes.get("hulls") is not None:
            if not m.hull_docs:
                fail("tools/ui_art/hulls/ has manifests but no hull authoring docs")
            report["hulls"] = run_hull_pipeline(m, outroot, outroot / STAGING,
                                                report, ingest_files)
        counts = run_generic_passes(m, outroot, report)
        report["generic"] = counts
        if m.classes.get("terrain") is not None:
            run_seam_ring(m, outroot, report)
        if m.classes.get("chrome") is not None:
            report["ninepatch"] = run_ninepatch(m, outroot, report)
    finally:
        shutil.rmtree(outroot / STAGING, ignore_errors=True)
    return m, report


def summary(m: Manifests, report: dict, outroot: Path) -> None:
    print(f"build_ui_art: output root {outroot}")
    for cls in CLASS_DIRS:
        entries = m.classes.get(cls)
        state = "skipped (no manifests)" if entries is None else f"{len(entries)} manifest file(s)"
        print(f"  class {cls:10s} {state}")
    h = report.get("hulls", {})
    g = report.get("generic", {})
    ing = report.get("ingest")
    if ing is not None:
        print(f"  ingest: candidates {ing['candidates']}, accepted base "
              f"{ing['accepted_base']} + derived {ing['accepted_derived']}, "
              f"rejected {len(ing['rejected'])}, revoked stale {ing['revoked']}, "
              f"{ing['files']} shipped file(s) written from the model pass")
        for r in ing["rejected"]:
            print(f"    REJECT {r['job']}: {r['reason']} — {r['detail']}")
    print(f"  rendered(render.js): hull maps {h.get('rendered', 0)}, "
          f"generic {g.get('rendered', 0)}; derived {h.get('derived', 0) + g.get('derived', 0)}; "
          f"outlined {h.get('outlined', 0) + g.get('outlined', 0)}; "
          f"hull tokens written {h.get('tokens', 0)} generator + "
          f"{h.get('tokens_ingested', 0)} ingested "
          f"(16 x 9 x 8 = 1152 expected)")
    for ship, tier, e_ext, w_ext, band in report.get("footprints", []):
        print(f"  footprint {ship:18s} t{tier}  e {e_ext}px  w {w_ext}px  "
              f"band {band[0]}-{band[1]}  OK (64 canvas)")
    print(f"  footprint bands (64 canvas, §4.8.7 amendment 1664ba9): "
          f"t1 {FOOTPRINT_BANDS[1][0]}-{FOOTPRINT_BANDS[1][1]}, "
          f"t2 {FOOTPRINT_BANDS[2][0]}-{FOOTPRINT_BANDS[2][1]}, "
          f"t3 {FOOTPRINT_BANDS[3][0]}-{FOOTPRINT_BANDS[3][1]} — "
          f"{len(report.get('footprints', []))} hulls in band")
    for kind, n in report.get("seam_kinds", []):
        print(f"  seam ring '{kind}': {n} variant(s) byte-identical outer ring")
    for note in report.get("ninepatch_notes", []):
        print(f"  ninepatch note: {note}")
    print(f"  ninepatch sheets: {report.get('ninepatch', 'skipped (no chrome output)')}")


def run_check() -> None:
    committed = ROOT / "assets/ui"
    if not committed.is_dir():
        fail("--check: assets/ui/ does not exist in the committed tree; run a full build first")
    # The override ladder participates in the byte-compare: committed
    # ingested tokens are the expected bytes (the ledger pins their source
    # sha; the group-13 audit re-derives the provenance), generator art is
    # rebuilt and compared as before.
    with tempfile.TemporaryDirectory(prefix="ui_art_check.") as td:
        m, _ = build_into(Path(td), resolve_ingest_overrides())
        # The pipeline owns PNGs; Godot's .import sidecars are committed by
        # the master --import pass and carry no rebuild semantics (master
        # reconciliation 2026-11-04, ledgered).
        got = sorted(p for p in (Path(td) / "assets/ui").rglob("*")
                     if p.is_file() and p.suffix == ".png")
        want = sorted(p for p in committed.rglob("*")
                      if p.is_file() and p.suffix == ".png")
        got_rel = {str(p.relative_to(Path(td) / "assets/ui")): p for p in got}
        want_rel = {str(p.relative_to(committed)): p for p in want}
        diffs = []
        for rel in sorted(set(got_rel) - set(want_rel)):
            diffs.append(f"EXTRA in rebuild: {rel}")
        for rel in sorted(set(want_rel) - set(got_rel)):
            diffs.append(f"MISSING from rebuild: {rel}")
        for rel in sorted(set(got_rel) & set(want_rel)):
            if got_rel[rel].read_bytes() != want_rel[rel].read_bytes():
                diffs.append(f"BYTE DIFF: {rel}")
        if diffs:
            print(f"build_ui_art: --check FAILED ({len(diffs)} diffs, first 20):", file=sys.stderr)
            for d in diffs[:20]:
                print(f"  {d}", file=sys.stderr)
            sys.exit(1)
        print(f"build_ui_art: --check OK — {len(got_rel)} files byte-identical double run "
              "(§8.8 group-13 item 2)")


def run_contact_sheet() -> None:
    with tempfile.TemporaryDirectory(prefix="ui_art_sheet.") as td:
        m, _ = build_into(Path(td), resolve_ingest_overrides())
        result = build_contact_sheet(Path(td), m)
        dest, sheet = result
        dest.write_bytes(encode_png_indexed(sheet.w, sheet.h, sheet.px))
        print(f"build_ui_art: contact sheet -> {dest} ({sheet.w}x{sheet.h})")


def run_import_mode(snapped_dir: Path) -> None:
    """--import-ships: ingest whatever the model pass has accepted NOW,
    then run the full build so the ladder falls the remaining ids back to
    the generator (re-runs pick up late re-rolls with the same command)."""
    if not snapped_dir.is_dir():
        fail(f"--import-ships: snapped dir not found: {snapped_dir}")
    report = {}
    ingest = run_ship_ingest(snapped_dir, ROOT, report)
    m, report = build_into(ROOT, resolve_ingest_overrides())
    report["ingest"] = ingest
    summary(m, report, ROOT)
    counts = report.get("hulls", {})
    total = counts.get("tokens", 0) + counts.get("tokens_ingested", 0)
    if m.classes.get("hulls") is not None and total != 16 * 9 * 8:
        fail(f"hull token count {total} (generator {counts.get('tokens', 0)} "
             f"+ ingested {counts.get('tokens_ingested', 0)}) != 1152")
    print(f"build_ui_art: ledger -> {INGEST_LEDGER.relative_to(ROOT)}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Phase-10 UI art governor (docs/IMPLEMENT-Phase10.md decision 5/9, 80-* §4.8)")
    ap.add_argument("--check", action="store_true",
                    help="rebuild into a temp dir and byte-compare against assets/ui/ (§8.8)")
    ap.add_argument("--contact-sheet", action="store_true",
                    help="emit tools/contact_sheet.png (decision 9.4 review gate)")
    ap.add_argument("--import-ships", metavar="SNAPPED_DIR",
                    help="ingest the model-pass snapped ship tokens (64-grid "
                         "RGBA) from SNAPPED_DIR — formal quantize, pennant "
                         "snap, masthead + band gates, mirror-derived e/ne/se "
                         "(f6c00bb), committed provenance ledger; accepted "
                         "tokens are the primary art, the generator fills "
                         "the gaps (§4.8 ingestion contract)")
    args = ap.parse_args()
    if args.check and args.import_ships:
        fail("--check and --import-ships are mutually exclusive modes")
    if args.check:
        run_check()
        return
    if args.contact_sheet:
        run_contact_sheet()
        return
    if args.import_ships:
        run_import_mode(Path(args.import_ships))
        return
    m, report = build_into(ROOT, resolve_ingest_overrides())
    summary(m, report, ROOT)
    counts = report.get("hulls", {})
    total = counts.get("tokens", 0) + counts.get("tokens_ingested", 0)
    if m.classes.get("hulls") is not None and total != 16 * 9 * 8:
        fail(f"hull token count {total} (generator {counts.get('tokens', 0)} "
             f"+ ingested {counts.get('tokens_ingested', 0)}) != 1152")


if __name__ == "__main__":
    main()
