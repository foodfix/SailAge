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
   {panel,button,button_hover,button_pressed,button_focus,field}.png``
   96×96 from the 32×32 PixelLab chrome tiles (the 2026-11-09 32px
   amendment): native nine-slot assembly — each sheet cell blits from
   ITS OWN as-authored wang tile (1 tl, 2 tr, 4 bl, 8 br, 3 top,
   12 bottom, 5 left, 10 right, 15 fill), NO transforms (the authored-
   era orientation math — frame_ops() — remains only for the retired
   generator fallback), margins exactly one tile (96 = 32 + 32 + 32);
   every sheet is pixel-exact self-verified at assembly (build FAIL on
   any mismatch).  Bar sheet layout (authored 16px tiles, pinned):
   ``ninepatch_bar.png`` 48×48, rows 16..31 form the horizontal midline
   band the kit's value_bar samples — left cap tile at x 0..15, line
   tile tiled x 16..31, right cap tile at x 32..47; the rest transparent.
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
9b. Model-pass icon ingestion (``--import-icons <src_dir>...`` — the §4.8
   64-canvas amendment, 2026-11-05): per snapped 64-grid icon, re-quantize
   to the 25-hex icon block (the studio ship snaps quantize to the hull
   block — never trusted for icons; the formal re-quantize is provably a
   no-op on icon-block-clean sources and a hard gate on anything else),
   then halve 64→32 (EXACT 2:1 nearest, origin-anchored: out(x, y) =
   src(2x, 2y) — the inline UI displays 32px and the halving stays crisp
   on the 64-grid), gate on the §4.8.3 32px color cap (20), and write
   ``assets/ui/icons/<id>.png`` as the PRIMARY inline art — same ids,
   same files as the generator (per-file override ladder).  The ledger
   section ``icons{}`` records per id {job, seed, source dir, snapped
   sha, acceptance date}; the 64px hero variants are DEFERRED (no display
   surface; ledger counts record the skip).  Later source dirs win per
   id — pass ``model_raw/snapped`` plus ``model_raw/studio/snapped`` to
   fold the studio re-rolls in.
9c. Model-pass terrain ingestion (``--import-terrain <gen_dir>``): the
   model ``terrain_plains_uniform`` sheet (1024×512, a 4×2 grid of
   256px seamless-by-design patches) crops to the 4 uniform 64px land
   variants (one crop per top-row patch, clean-interior offset ≥ 96px
   from every patch edge), tone-ranked onto the authored land family's
   distribution (brightest 6% → LAND_HI, darkest 6% → LAND_LO, middle →
   LAND base — nearest-hex quantization would fill the tile ~90% HI and
   turn the pinned base-dominant ring into a visible lattice grid), then
   stamped with the authored phase-0 outer ring (the byte-identical ring
   the ×2-upscale fallback ships — the §4.8.2 seam rule and the manifest
   ``ring`` note survive the swap).  Written as
   ``assets/ui/terrain/terrain_land_0..3.png`` (per-file override
   ladder); the ledger section ``terrain{}`` records per file {job,
   seed, sheet sha, patch, crop origin, acceptance date}.  The
   ``terrain_rocky_uniform`` sheet is HELD for the blob wave (it
   quantizes darker/flatter than plains at 1:1; plains is the directed
   deliverable — a non-default ``--terrain-sheet`` remains an explicit,
   ledgered override).
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
import base64
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
TOKENS_DIR = "assets/ui/hulls"
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

# ---- model-pass ingestion (--import-ships / --import-icons /
# --import-terrain; 90-* §9.2 AI-ingestion path, 80-* §4.8 ingestion
# contract + the 5-direction amendment f6c00bb + the 2026-11-05
# icons/terrain extension).  The snapped/generated sources live gitignored
# under tools/ui_art/model_raw/ (never committed); the ingest ledger is
# committed provenance. ----
INGEST_LEDGER = MANIFESTS / "ingest_ledger.json"   # committed provenance
# v2 (2026-11-05): the ledger gains the icons{} + terrain{} families
# (additive; every family's ingest preserves the other families' sections).
INGEST_VERSION = 2
# Calibration reconciliation (2026-11-05, master evidence): the snap
# radius widens 40 -> 90 channel-sum to match the audit classifier's
# tolerance ring, GUARDED by strict red-dominance (R > G and R > B) —
# verified across all 80 candidates: the only in-radius block hex is
# #b3341f (Δcs 27, already snapped at 40); wood browns sit at Δcs
# 132-147 (outside any sane radius; the guard keeps the class explicit
# so a future radius change can never snap wood/pennant-adjacent
# non-reds).  The masthead gate still requires >=3 EXACT source px —
# the snap makes them exact by construction, the flag stays honest.
PENNANT_SNAP_RADIUS = 90   # channel-sum Δ to the pennant source that snaps
MASTHEAD_MIN_PX = 3        # ≥3 source-red px in the masthead region
MASTHEAD_TOP_FRAC = 0.45   # masthead region = top 45% of the token bbox
INGEST_BASE_DIRS = ("n", "s", "w", "sw", "nw")  # the model's 5 base dirs
INGEST_DERIVED = {"e": "w", "ne": "nw", "se": "sw"}  # derived: mirror_x flip
# PixelLab raw mode (80-* §4.8 2026-11-06): all 8 native rotations
RAW_INGEST_DIRS = ("n", "ne", "e", "se", "s", "sw", "w", "nw")
INGEST_INGESTED_BUDGET = 25  # 64-canvas per-sprite cap (§4.8.3 48px tier;
# the quantized token draws from an 18-hex block, so this is belt-and-braces)
# Band-measurement reconciliation (2026-11-05): the §4.8.7 long axis is
# measured on the content bbox — opaque px EXCLUDING connected components
# below the speckle floor (isolated rembg/snap fragments; the audit
# classifier's largest-component semantics).  Observed speckles are 1-5 px
# (galleass 6, junk 1) and never extend the axis; a 4-px cluster is
# deliberate art.  A single-component sprite measures identically to the
# full bbox.
BAND_SPECKLE_FLOOR = 4

# ---- pennant auto-paint (master adjudication 2026-11-05): the model
# intermittently omits the masthead pennant — a 3-5px detail is not worth
# re-roll roulette.  When the masthead gate finds <3 source px, the
# deterministic pennant pair below (re-authored per the 80-* §4.8 note —
# the authored-map flags are 1-2px @32-grid, below the gate's own bar) is
# composited at the detected mast anchor, BEFORE quantize/snap so the flag
# lands exact-source.  WEST-ish base dirs (w/nw/sw) stream toward the
# stern (right); n streams right, s left; the derived flips (e/ne/se)
# carry the mirrored flag automatically (paint precedes derivation).
# Ledger records pennant: "auto-painted" vs "model".
PENNANT_SPRITE_RIGHT = (
    ".IIII..",
    "ISSSSI.",
    "ISSSSSI",
    "ISSSSI.",
    ".IIII..",
)  # 7x5: 1px ink outline, 13 exact-source px, hoist at col 0, taper right
PENNANT_SPRITE_LEFT = tuple(row[::-1] for row in PENNANT_SPRITE_RIGHT)
PENNANT_PAINT_DIRS_RIGHT = ("n", "w", "nw", "sw")   # s streams left


def _mast_anchor(px, w, h):
    """The masthead anchor: the top 20% band of the bbox, the tallest
    vertical run's x-center (the mast).  Returns (mast_x, bbox_top), or
    None when the band holds no mast-like structure (max run < 2 px) —
    the honest reject keeps."""
    bb = bbox_of(px, w, h)
    if bb is None:
        return None
    x0, y0, x1, y1 = bb
    band_h = max(1, int(0.20 * (y1 - y0 + 1) + 0.5))
    band_hi = min(y0 + band_h, y1 + 1)
    runs = {}
    for x in range(x0, x1 + 1):
        best = cur = 0
        for y in range(y0, band_hi):
            if px[x + y * w][3]:
                cur += 1
                if cur > best:
                    best = cur
            else:
                cur = 0
        runs[x] = best
    max_run = max(runs.values())
    if max_run < 2:
        return None
    cols = [x for x, r in runs.items() if r == max_run]
    return (min(cols) + max(cols)) // 2, y0


def _paint_pennant(px, w, h, mast_x, bbox_top, d):
    """Composite the deterministic pennant at the mast anchor: the hoist
    column lands ADJACENT to the mast (mast ±1, the mast art survives);
    the attachment row lands at bbox_top + 2 (the sprite's mid row);
    cells outside the 64 canvas are clipped (the post-paint masthead
    re-check catches pathological clips)."""
    if d in PENNANT_PAINT_DIRS_RIGHT:
        rows = PENNANT_SPRITE_RIGHT
        ax = mast_x + 1
    else:
        rows = PENNANT_SPRITE_LEFT
        ax = mast_x - len(PENNANT_SPRITE_LEFT[0])
    sh, sw = len(rows), len(rows[0])
    ay = max(0, min(bbox_top, h - sh))
    ax = max(0, min(ax, w - sw))
    for sy in range(sh):
        for sx in range(sw):
            cell = rows[sy][sx]
            if cell == ".":
                continue
            xx, yy = ax + sx, ay + sy
            if 0 <= xx < w and 0 <= yy < h:
                hexv = PENNANT_SOURCE if cell == "S" else HULL_INK
                px[xx + yy * w] = HEXES[hexv] + (255,)
    return px

# ---- model-pass icon ingestion (--import-icons; 80-* §4.8 64-canvas
# amendment: semantic icons are generated on the 64 canvas by the model
# pass, the INLINE UI displays the 32 art — the ingest re-quantizes the
# snapped 64-grid RGBA to the ICON block and halves 64→32 (exact 2:1
# nearest, origin-anchored).  The committed assets/ui/icons/<id>.png is
# the primary art; the string-map generator is the per-file fallback
# (the same override ladder as the hull tokens).  Since the 2026-11-08
# amendment the ingest ALSO emits the hero 64 asset per id (the
# deferral is retired): assets/ui/icons64/<id>.png, the quantized 64
# grid 1:1; the generator's per-file fallback is the exact ×2 nearest
# upscale of the shipped 32 (§4.8 64-canvas fallback rule). ----
ICON_INGEST_PREFIX = "icon_"
ICON_INGEST_SOURCES = ("pixellab_icons",)  # canonical cache dirs
# (precedence order; later CLI dirs win per id). "pixellab_icons" is the
# tools/pixellab_pass.py --icons cache: <dir>/<id>/snapped/icon.png per
# id (the per-id nested layout), not the flat icon_<id>.png caches.
ICON_SOURCE_DIR_KEY = "source"   # ledger record: the cache dir of the sha
ICON_ALPHA_THRESHOLD = 128       # snap alpha is binary; the threshold only
# guards a partial-alpha re-roll (below → transparent, else opaque)
ICON_INLINE = 32                 # the inline UI canvas (§4.8 render rules)
ICON_INLINE_CAP = 20             # §4.8.3 32px tier color cap
ICON_HERO_DIR = "icons64"        # assets/ui/<dir>/ — the hero 64 family
ICON_HERO_CAP = 25               # §4.8.3 48px+ tier color cap (informative:
# the quantized 64 art draws from the 22-color icon block)
# ---- glyph-pass (marker/facility) blocks (80-* §4.8 2026-11-08): the
# owning class blocks — markers quantize into the terrain block (the
# class mapping's marker row), facility tokens into the hull block.
# Pinned hex-for-hex with the validator's BLOCK_TERRAIN / BLOCK_HULL.
MARKER_BLOCK = {
    "#16446e", "#2f6f9e", "#7a5c2e", "#8f6d3a", "#5e4720", "#3d3d3d",
    "#565656", "#c9d6df", "#e4eef4", "#9fb4c4", "#dff0f4", "#101010",
    "#1a8c4e", "#b3191f", "#274b8f", "#d97b1e", "#6a3d9a", "#c9a227",
    "#9a9a9a",
}
# facility quantize target = HULL_BLOCK (the tokens family's block).
# Glyph ingest family table: id prefix -> (ledger family, shipped 32 dir
# or None, quantize block, hero dir). Since the hero-64 display rule
# (2026-11-08) BOTH families ship heroes only — the halved-32 inline
# emission is retired (assets/ui/markers/ and the facility half of
# assets/ui/tokens/ are gone; shipped 32 dir = None for both).
GLYPH_FAMILIES = {
    "marker_": ("markers", None, MARKER_BLOCK, "markers64"),
    "facility_": ("facility", None, HULL_BLOCK, "tokens64"),
}
GLYPH_INLINE_CAP = 20           # §4.8.3 32px tier color cap (both families)
# ---- arrow-family ingest policy (fix 2026-11-05): the wind_arrow_*/
# current_arrow_* families are derivation-only (§8.8 item 5) — e/s/w are
# rot_cw/rot_180/rot_ccw of the n icon and nw/se/sw mirror/rot of ne, so
# model output for those ids must NEVER reach the assets files (an
# independently generated e breaks the transform pin).  The exclusion set
# is read straight from the manifests (any icon decl carrying a derive op
# — auto-extends to future derivation-only families).  The n/ne BASES may
# ingest (the intended refresh path: the build re-derives the siblings
# from the new source) but only when they verifiably point the right way;
# a poor base skips the whole family for the round (generated art stays).
ICON_ARROW_FAMILY_PREFIXES = ("wind_arrow_", "current_arrow_")
ICON_ARROW_BASE_DIRS = ("n", "ne")

# ---- model-pass terrain ingestion (--import-terrain; 80-* §4.8 + the
# terrain blob program's uniform-fill rule: the model plains_uniform
# sheet (1024×512, a 4×2 grid of 256px seamless-by-design patches) crops
# to 4 uniform 64px land variants.  Crops quantize to the land kind's
# pinned 3-step ramp (§4.8.2 dither family — the variant stays
# plains-toned and in-block) and carry the authored phase-0 outer ring
# (the byte-identical ring the ×2-upscale fallback carries — §4.8.2 seam
# rule + the manifest `ring` note).  The rocky_uniform sheet is HELD for
# the blob wave unless it reads as a clean plains texture at 1:1. ----
LAND_BASE = "#7a5c2e"           # LAND — the kind's pinned base step
LAND_HI = "#8f6d3a"             # LAND_HI — highlight / dither light step
LAND_LO = "#5e4720"             # LAND_LO — shadow / dither dark step
LAND_RAMP = (LAND_BASE, LAND_HI, LAND_LO)  # the land kind's only steps
RING_LATTICE = (3, 5, 16, 3)    # authored phase-0 ring: HI iff
# (3x + 5y) % 16 == 3 on the 32-grid (manifest `ring` notes; 32 % 16 == 0
# keeps it torus-continuous), mapped to the 64 canvas by x//2 / y//2 —
# exactly the ring the ×2-upscale fallback ships.
LAND_TONE_HI_FRAC = 0.06   # the authored land family's measured tone
LAND_TONE_LO_FRAC = 0.06   # distribution (generator land variants: ~88%
# base / ~6% HI / ~6% LO).  The model plains crop is tone-ranked onto
# THAT distribution — brightest 6% → LAND_HI, darkest 6% → LAND_LO,
# middle → LAND base — instead of nearest-hex quantization: the raw crop
# tone (#a0742c class) sits nearest LAND_HI, so nearest quantization
# fills the tile ~90% HI and the pinned base-dominant ring reads as a
# dark lattice grid on the tiled map (measured 2026-11-05).  Ranking the
# crop onto the family's own tone stats keeps the model's spatial
# structure (debris speckles, mottling) and makes the ring statistically
# indistinguishable from the interior — the seam disappears the same way
# it does in the generator art.  Ties break by index (deterministic).

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
    # UW2 parchment-chrome appends (2026-11-08, §4.8 amended, append-only):
    # the texture-mode flat fill/highlight/shadow steps + the panel ink.
    "#e3d2a4", "#f2e6c8", "#c6b183", "#3a2a16",
    # Night revision (2026-11-08, blue-chart-panels amendment):
    # PANEL_BLUE — pale sky-blue chart paper, the texture-mode flat fill.
    "#b7cfe0",
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
# 2026-11-08: +button_hover / +button_pressed (the PixelLab chrome
# amendment's derived state sheets — the 2026-11-04 dimming-only mapping
# remains the missing-sheet fallback, §4.9).
NINEPATCH_SETS = ("panel", "button", "button_hover", "button_pressed",
                  "button_focus", "field")
BAR_PARTS = ("left", "right", "line")  # A.1 chrome ids: bar_left/bar_right/bar_line (master reconciliation)
SHEET = 48   # authored-bar sheet: 16px margins -> one 16px middle tile (§4.8.8)
TILE = 16    # (chrome sheets take T/S from the tiles themselves: 96/96,
             # the 2026-11-09 32px amendment)

# ---- PixelLab chrome tileset ingestion pins (80-* §4.8, 2026-11-08) ----
# Wang→nine-patch slot mapping (upper = plate material, bit
# NW·8+NE·4+SW·2+SE·1): the singles stay "TOP-LEFT corner / TOP edge"
# (the FRAME_OPS convention), so TL corner = wang_1 (material SE),
# top edge = wang_3 (material S half), fill = wang_15 (all material,
# self-tiling by Wang construction). The inverted-bevel sources for the
# pressed/field rims are the opposite ring tiles (8 = BR corner,
# 12 = bottom edge) run through rot_180 — the bevel light flips TL→BR,
# the classic sunken plate.
CHROME_WANG = {"corner": 1, "edge": 3, "fill": 15}
CHROME_WANG_INV = {"corner": 8, "edge": 12}
CHROME_GREEN_MARGIN = 32     # key: g ≥ r+32 and g ≥ b+32 → transparent
CHROME_HOVER_RIM_BAND = 2    # band px: distance to the keyed outside ≤ 2
CHROME_HOVER_RIM_LIFT = 0.35  # band: c' = c + round((255−c)×lift)
CHROME_HOVER_FACE_LIFT = 0.05  # interior: faint warmth (the same lift)
CHROME_PRESS_DARKEN = 0.80   # c' = round(c×darken), opaque px
CHROME_FIELD_RECESS = 0.62   # field interior darken (inset parchment)
CHROME_FOCUS_RING = "#d9a441"  # ACCENT — retired with the state ops
# (2026-11-09 raw-plate amendment: no clean-face flatten, no lift/press/
# ring derivations — the click families ship the raw keyed tiles).
CHROME_RAW_DIR = ROOT / "tools" / "assets" / "pixellab_raw"
# frame = ocean-chart panel plate; click = the parchment click plate.
# 2026-11-09 user direction — RAW PLATES + NATIVE NINE SLOTS: every
# family assembles from its tileset's own wang tiles AS AUTHORED — one
# slot per sheet cell (tl/tr/bl/br/top/bottom/left/right/fill), no
# mirror/rotate anywhere; only field still colors (fill recess). The
# loader snaps all ring masters to one boundary depth so the plate
# frame line is straight (§4.8 native nine-slot + ring-boundary snap).
CHROME_SLOTS = (
    ("tl", 1), ("tr", 2), ("bl", 4), ("br", 8),
    ("top", 3), ("bottom", 12), ("left", 5), ("right", 10),
    ("fill", 15),
)
CHROME_DERIVATIONS = {
    "panel": ("frame", {slot: (wang, "base")
                        for slot, wang in CHROME_SLOTS}),
    "field": ("frame", {slot: (wang, "recess" if slot == "fill" else "base")
                        for slot, wang in CHROME_SLOTS}),
    "button": ("click", {slot: (wang, "base")
                         for slot, wang in CHROME_SLOTS}),
    "button_hover": ("click", {slot: (wang, "base")
                               for slot, wang in CHROME_SLOTS}),
    "button_pressed": ("click", {slot: (wang, "base")
                                 for slot, wang in CHROME_SLOTS}),
    "button_focus": ("click", {slot: (wang, "base")
                               for slot, wang in CHROME_SLOTS}),
}
# The 2026-11-09 32px amendment: both PixelLab chrome tilesets are
# 32×32 (pro Wang corner mode); the authored bar tiles stay 16px.
CHROME_SOURCE_PX = {"frame": 32, "click": 32}


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
    if ctype not in (3, 6, 2):
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
    elif ctype == 2:
        # the model-pass gen sheets are opaque RGB — the terrain ingest's
        # crop source (alpha implied 255)
        for i in range(0, len(out), 3):
            px.append((out[i], out[i + 1], out[i + 2], 255))
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

# the icon/terrain ingest families quantize outside the hull block — their
# hex tables ride here (ICON_BLOCK / the land ramp)
_INGEST_HEXES = {h: tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))
                 for h in ICON_BLOCK | set(LAND_RAMP) | HULL_BLOCK
                 | MARKER_BLOCK}


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
    """The pennant-source snap (calibration reconciliation 2026-11-05):
    any QUANTIZED px within Δ≤90 channel-sum of the authored source hex
    AND strictly red-dominant (R > G and R > B) lands EXACTLY on it (so
    the ×9 owner remap hits; covers the model's near-miss reds incl. the
    pirate hex, Δcs 27).  The guard excludes non-red in-radius hexes —
    wood browns sit at Δcs 132-147 and fail the radius anyway, but the
    dominance check keeps the snap class red-only should the block or
    the radius ever move."""
    rgb = HEXES[hexv]
    if (rgb[0] > rgb[1] and rgb[0] > rgb[2]
            and _hex_dist(rgb, HEXES[PENNANT_SOURCE]) <= PENNANT_SNAP_RADIUS):
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


def _content_bbox(px, w, h):
    """The band-measurement basis (calibration reconciliation 2026-11-05):
    the bbox over opaque px EXCLUDING connected components below
    BAND_SPECKLE_FLOOR (4-connected; isolated rembg/snap fragments — the
    audit classifier's largest-component semantics).  Returns None for a
    fully transparent token."""
    seen = [False] * (w * h)
    xs, ys = [], []
    for start in range(w * h):
        if seen[start] or px[start][3] == 0:
            continue
        stack = [start]
        seen[start] = True
        comp = []
        while stack:
            i = stack.pop()
            comp.append(i)
            x, y = i % w, i // w
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                xx, yy = x + dx, y + dy
                if 0 <= xx < w and 0 <= yy < h:
                    j = xx + yy * w
                    if not seen[j] and px[j][3]:
                        seen[j] = True
                        stack.append(j)
        if len(comp) < BAND_SPECKLE_FLOOR:
            continue
        xs.extend(i % w for i in comp)
        ys.extend(i // w for i in comp)
    if not xs:
        return None
    return min(xs), min(ys), max(xs), max(ys)


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


def _ingest_raw_dedupe() -> bool:
    """True when the committed ledger's last ship ingestion was the
    PixelLab raw mode (80-* §4.8 2026-11-06): the shipped hull grid is
    ONE owner-less file per ship × dir (`hull_{ship}_{dir}.png`) and the
    runtime resolves every owner id onto it (texture_registry owner
    fallback). False ⇒ the classic 9-owner ×9-remap grid."""
    if not INGEST_LEDGER.is_file():
        return False
    try:
        doc = json.loads(INGEST_LEDGER.read_text())
    except ValueError:
        return False
    return "pixellab" in str(doc.get("generated_by", ""))


def _ingest_north() -> bool:
    """True when the committed ledger's last ship ingestion was the
    top-down north mode (80-* §4.8 2026-11-07): the shipped hull family
    is ONE owner-less north file per ship (`hull_{ship}.png`), tier-sized
    (32/48/64), rotated at runtime — no dir tokens exist at all."""
    if not INGEST_LEDGER.is_file():
        return False
    try:
        doc = json.loads(INGEST_LEDGER.read_text())
    except ValueError:
        return False
    return "import-ships-north" in str(doc.get("generated_by", ""))


def resolve_ingest_overrides(root: Path = ROOT):
    """The override ladder (80-* §4.8: the ingested tokens are the PRIMARY
    art, the ×2-upscale generator is the fallback): a ledger entry whose
    committed token file exists serves that shipped file from the
    committed ingested artifact; every other id falls through to the
    generator.  Returns {(ship, owner, dir): committed path}; the raw
    dedupe mode keys the shared owner-less file as (ship, "", dir)."""
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
        name = (f"hull_{ship}_{d}.png" if owner == ""
                else f"hull_{ship}_{owner}_{d}.png")
        p = root / TOKENS_DIR / name
        if p.is_file():
            out[(ship, owner, d)] = p

    if _ingest_north():
        # North mode (80-* §4.8 2026-11-07): tokens are keyed by the
        # shipped file stem `hull_{ship}`; the override key is
        # (ship, "", "north") and serves the shared hull_{ship}.png.
        for tid in (doc.get("tokens") or {}):
            ship = tid[len("hull_"):] if tid.startswith("hull_") else tid
            p = root / TOKENS_DIR / f"hull_{ship}.png"
            if p.is_file():
                out[(ship, "", "north")] = p
        return out
    if _ingest_raw_dedupe():
        for tid in (doc.get("tokens") or {}):
            ship, d = _parse_token_id(tid)
            add(ship, "", d)
        return out
    for tid in (doc.get("tokens") or {}):
        ship, d = _parse_token_id(tid)
        for owner in OWNER_ORDER:
            add(ship, owner, d)
    for fid in (doc.get("derived") or {}):
        ship, owner, d = _parse_file_id(fid)
        add(ship, owner, d)
    return out


def resolve_artifact_overrides(root: Path = ROOT):
    """The override ladder for the icon/glyph/terrain families (80-* §4.8:
    the ingested art is the PRIMARY shipped artifact, the generator is the
    per-file fallback): a ledger entry whose committed artifact file
    exists serves that shipped file from the committed ingested artifact.
    The icon family resolves BOTH display surfaces per id — the 32 inline
    asset and the hero 64 asset (2026-11-08; the generator's hero
    fallback is the ×2 upscale of the 32).  The glyph families resolve
    one 32 asset per id (no heroes — pinned).  Returns {"icons": {id:
    path}, "icons64": {id: path}, "markers": {id: path}, "facility": {id:
    path}, "terrain": {file name: path}}."""
    out = {"icons": {}, "icons64": {}, "markers": {}, "markers64": {},
           "facility": {}, "facility64": {}, "terrain": {}, "chrome": {}}
    doc = _read_ledger("resolve_artifact_overrides")
    for iid in (doc.get("icons") or {}):
        p = root / "assets" / "ui" / "icons" / f"{iid}.png"
        if p.is_file():
            out["icons"][iid] = p
        ph = root / "assets" / "ui" / ICON_HERO_DIR / f"{iid}.png"
        if ph.is_file():
            out["icons64"][iid] = ph
    # the glyph 32 inline families retired with the hero-64 display rule
    # (2026-11-08) — heroes only, under the BARE id (the registry strips
    # facility64_/marker64_ before probing)
    for family, bare_dir, fam_pfx in (("facility", "tokens64", "facility_"),
                                      ("markers", "markers64", "marker_")):
        for iid in (doc.get(family) or {}):
            ph = root / "assets" / "ui" / bare_dir / (
                f"{iid[len(fam_pfx):]}.png")
            if ph.is_file():
                out[f"{family}64"][iid] = ph
    for fname in (doc.get("terrain") or {}):
        p = root / "assets" / "ui" / "terrain" / fname
        if p.is_file():
            out["terrain"][fname] = p
    # chrome (2026-11-08): the ledger-owned singles serve their committed
    # ingested bytes — the generator's string-map art is the fallback.
    for sid in (_chrome_ledger().get("tiles") or {}):
        p = root / "assets" / "ui" / "chrome" / f"{sid}.png"
        if p.is_file():
            out["chrome"][sid] = p
    return out


NORTH_TIER_SIZE = {1: 32, 2: 48, 3: 64}


def run_ship_ingest_north(raw_root: Path, outroot: Path,
                          report: dict) -> dict:
    """--import-ships-north: the top-down hull ingestion (80-* §4.8
    2026-11-07). ONE owner-less north file per ship
    (`assets/ui/tokens/hull_{ship}.png`), canvas = tier size
    (t1 32 / t2 48 / t3 64), shipped RAW 1:1 (ship-as-drawn: no quantize,
    no pennant remap — the model's pixels are the shipped pixels, the
    same token for every owner). Gates: decode + canvas fit (exact tier
    S×S). Provenance: the pixellab_topdown manifest (job id, seed,
    description sha). Any stale file from the retired grids
    (`hull_{ship}_{dir}.png` / `hull_{ship}_{owner}_{dir}.png`) is
    pruned with its .import sidecar; committed ingested tokens whose
    entry did not survive this run are revoked. `facility_*` tokens are
    untouched."""
    ship_types = json.loads(SHIP_TYPES.read_text())
    roster = ship_types.get("ship_types",
                            ship_types if isinstance(ship_types, list)
                            else [])
    tiers = {s["id"]: int(s["tier"]) for s in roster}
    tokens_dir = outroot / TOKENS_DIR

    prev = _read_ledger("--import-ships-north")
    prev_tokens = prev.get("tokens") or {}

    manifest = {}
    pm = raw_root / "pixellab_topdown.json"
    if pm.is_file():
        try:
            manifest = json.loads(pm.read_text())
        except ValueError:
            manifest = {}

    today = time.strftime("%Y-%m-%d", time.gmtime())
    candidates, accepted = [], {}       # accepted: ship id -> (w, h, px)
    led_tokens, rejected = {}, []
    for ship in sorted(tiers):
        sp = raw_root / ship / "snapped" / "north.png"
        if not sp.is_file():
            continue  # not generated (yet) — a gap, not a rejection
        candidates.append(ship)
        raw_bytes = sp.read_bytes()
        try:
            w, h, px = decode_png(raw_bytes)
        except Exception as exc:
            rejected.append({"job": f"hull_{ship}", "reason": "decode",
                             "detail": f"snapped PNG does not decode: {exc}"})
            continue
        want = NORTH_TIER_SIZE[tiers[ship]]
        if (w, h) != (want, want):
            rejected.append({"job": f"hull_{ship}", "reason": "canvas",
                             "detail": f"{w}x{h} != tier-{tiers[ship]} "
                                       f"{want}x{want}"})
            continue
        sha = hashlib.sha256(raw_bytes).hexdigest()
        rec = manifest.get(ship) or {}
        desc = rec.get("description") or ""
        prev_rec = prev_tokens.get(ship) or {}
        accepted_at = (prev_rec.get("accepted_at")
                       if prev_rec.get("snapped_sha") == sha else None)
        led_tokens[f"hull_{ship}"] = {
            "job": f"hull_{ship}",
            "seed": rec.get("seed"),
            "snapped_sha": sha,
            "accepted_at": accepted_at or today,
            "size": want,
            "pennant": "raw",
            "pixellab": {"job_id": rec.get("job_id"),
                         "seed": rec.get("seed"),
                         "description_sha": hashlib.sha256(
                             desc.encode()).hexdigest()[:16]},
        }
        accepted[ship] = (w, h, px)

    written = 0
    for ship in sorted(accepted):
        w, h, px = accepted[ship]
        write_png(tokens_dir / f"hull_{ship}.png", w, h, px)
        written += 1

    # Retired-grid hygiene: the north family owns the owner-LESS dir-less
    # names, so every dir-suffixed file left by the retired 8-dir grids
    # (raw dedupe `hull_{ship}_{dir}` and classic `hull_{ship}_{owner}_{dir}`)
    # is stale. facility_* files never match the patterns.
    pattern = re.compile(
        r"hull_.+_(%s)\.png$|hull_.+_(%s)_(%s)\.png$"
        % ("|".join(DIR_ORDER), "|".join(OWNER_ORDER),
           "|".join(DIR_ORDER)))
    pruned = 0
    for f in sorted(tokens_dir.glob("hull_*.png")):
        if pattern.match(f.name):
            f.unlink()
            f.with_name(f.name + ".import").unlink(missing_ok=True)
            pruned += 1
    if pruned:
        print(f"  ingest: pruned {pruned} retired dir-suffixed token "
              "file(s) — the north family is one file per ship")

    # Provenance revocation: committed ingested north tokens whose entry
    # did not survive this run are removed so the ladder falls those ids
    # back to the generator THIS run.
    live = set(accepted)
    stale = [tid for tid in sorted(prev_tokens)
             if tid not in {f"hull_{s}" for s in live}]
    for tid in stale:
        (tokens_dir / f"{tid}.png").unlink(missing_ok=True)
        (tokens_dir / f"{tid}.png.import").unlink(missing_ok=True)
    revoked = len(stale)

    doc = {
        "counts": {
            "candidates": len(candidates),
            "accepted_base": len(led_tokens),
            "accepted_derived": 0,
            "rejected": len(rejected),
            "revoked_stale": revoked,
            "shipped_files": written,
            "pruned_retired_grid": pruned,
        },
        "generated_by":
            "tools/build_ui_art.py --import-ships-north",
        "rejected": rejected,
        "tokens": led_tokens,
        "derived": {},
    }
    _write_ledger(prev, "ships", doc)

    report["ingest"] = {
        "candidates": len(candidates),
        "accepted_base": len(led_tokens),
        "accepted_derived": 0,
        "rejected": rejected,
        "revoked": revoked,
        "pruned": pruned,
        "files": written,
    }
    return report["ingest"]


# ======================================================================
# model-pass icon + terrain ingestion (--import-icons / --import-terrain)
# ======================================================================

INGEST_CONTRACT = ("docs/80-UI-UX.md §4.8 ingestion contract + the "
                   "5-direction amendment f6c00bb; docs/90-ARCHITECTURE.md "
                   "§9.2; icons: 64-grid re-quantize to the icon block + "
                   "exact 2:1 nearest halving to the 32px inline art; "
                   "terrain: plains_uniform 64px interior crops on the "
                   "land ramp with the authored phase-0 ring")

# the ledger sections each family owns (everything else is preserved
# verbatim across a family's re-run — the studio accept→ingest flow
# re-runs --import-ships and must never revoke the icon/terrain families)
_SHIP_SECTIONS = ("generated_by", "rejected", "tokens", "derived")
_ICON_SECTIONS = ("icons_generated_by", "icons_rejected", "icons_skipped",
                  "icons")
_GLYPH_FAMILY_SECTIONS = {
    "markers": ("markers_generated_by", "markers_rejected",
                "markers_skipped", "markers"),
    "facility": ("facility_generated_by", "facility_rejected",
                 "facility_skipped", "facility"),
}
_GLYPH_SECTIONS = _GLYPH_FAMILY_SECTIONS["markers"] \
    + _GLYPH_FAMILY_SECTIONS["facility"]
_TERRAIN_SECTIONS = ("terrain_generated_by", "terrain_rejected", "terrain",
                     "terrain_note")
_CHROME_SECTIONS = ("chrome_generated_by", "chrome_rejected", "chrome")


def _read_ledger(where: str) -> dict:
    """The committed ledger, version-gated (shared by the three families)."""
    if not INGEST_LEDGER.is_file():
        return {}
    try:
        doc = json.loads(INGEST_LEDGER.read_text())
    except ValueError as exc:
        fail(f"{INGEST_LEDGER}: not valid JSON ({exc}) — fix or delete it")
    if int(doc.get("version", 0)) != INGEST_VERSION:
        fail(f"{INGEST_LEDGER}: version {doc.get('version')!r} != "
             f"{INGEST_VERSION}")
    return doc


def _write_ledger(prev: dict, family: str, sections: dict) -> None:
    """Read-modify-write: the family's sections replace their previous
    values; every other family's sections pass through untouched; counts
    merge per family sub-object."""
    owned = {"ships": _SHIP_SECTIONS, "icons": _ICON_SECTIONS,
             "terrain": _TERRAIN_SECTIONS, "glyphs": _GLYPH_SECTIONS,
             "chrome": _CHROME_SECTIONS}[family]
    counts = dict(prev.get("counts") or {})
    counts.update(sections.get("counts", {}))
    doc = {"version": INGEST_VERSION, "contract": INGEST_CONTRACT,
           "counts": counts}
    for key, val in prev.items():
        if key in ("version", "contract", "counts"):
            continue
        if any(key in own for own in
               (_SHIP_SECTIONS, _ICON_SECTIONS, _TERRAIN_SECTIONS,
                _CHROME_SECTIONS,
                *_GLYPH_FAMILY_SECTIONS.values())) \
                and key not in owned:
            doc[key] = val  # another family's section — preserve verbatim
    for key, val in sections.items():
        if key == "counts":
            continue
        doc[key] = val
    INGEST_LEDGER.parent.mkdir(parents=True, exist_ok=True)
    INGEST_LEDGER.write_text(json.dumps(doc, indent=2, ensure_ascii=False,
                                        sort_keys=True) + "\n")


def _seed_lookup(snapped_dir: Path, job: str, iid: str | None = None):
    """The provenance seed for a job: the source dir's own state/progress
    file first (the studio re-roll state), then the model_raw root
    progress; the pixellab manifest last (tools/pixellab_pass.py records
    the pinned seed per id — the icons manifest keyed `pixellab_icons.json`,
    the glyph manifest `pixellab_glyphs.json`); null when nothing records
    it (provenance rides the sha)."""
    for cand in (snapped_dir.parent / "state.json",
                 snapped_dir.parent / "progress.json"):
        if not cand.is_file():
            continue
        try:
            jobs = json.loads(cand.read_text()).get("jobs") or {}
        except ValueError:
            continue
        if job in jobs:
            return (jobs[job] or {}).get("seed")
    iid = iid if iid is not None else job[len(ICON_INGEST_PREFIX):]
    for mf_name in ("pixellab_icons.json", "pixellab_glyphs.json"):
        mf = snapped_dir.parent.parent / mf_name
        if mf.is_file():
            try:
                doc = json.loads(mf.read_text())
                seed = (doc.get(iid) or {}).get("seed")
                if isinstance(seed, int):
                    return seed
            except ValueError:
                pass
    return None


def _quantize_icon_hex(rgb):
    """Nearest icon-block hex (first-min over the sorted block — the same
    deterministic metric as the hull quantize)."""
    best_hex, best_d = None, None
    for hx in sorted(ICON_BLOCK):
        d = _hex_dist(rgb, _INGEST_HEXES[hx])
        if best_d is None or d < best_d:
            best_hex, best_d = hx, d
    return best_hex


def _quantize_icon(w, h, px):
    """Formal icon quantize: opaque px to the icon block; px below the
    alpha threshold pass through as fully transparent (the snap alpha is
    binary — the threshold only guards a partial-alpha re-roll)."""
    out = []
    for p in px:
        if p[3] < ICON_ALPHA_THRESHOLD:
            out.append((0, 0, 0, 0))
        else:
            out.append(_INGEST_HEXES[_quantize_icon_hex(p[:3])] + (255,))
    return out


def _halve64(w, h, px):
    """Exact 2:1 nearest halving, origin-anchored (pinned): out(x, y) =
    src(2x, 2y) — crisp on the 64-grid, no mixing; alpha rides the sampled
    pixel.  The validator mirrors this formula for the halving assert."""
    if w % 2 or h % 2:
        fail(f"icon halving: {w}x{h} is not an even 64-grid canvas")
    ow, oh = w // 2, h // 2
    return ow, oh, [px[(2 * y) * w + (2 * x)] for y in range(oh)
                    for x in range(ow)]


def _icon_source_key(d: Path) -> str:
    """The pinned cache-dir key for an icon source dir: the dir must sit
    at any checkout's ``ui_art/model_raw/<pinned>`` — the ledger `source`
    the validator re-resolves against ITS tree's gitignored cache."""
    rp = d.resolve().parts
    for pinned in ICON_INGEST_SOURCES:
        want = (Path("ui_art") / "model_raw" / pinned).parts
        if len(rp) >= len(want) and rp[-len(want):] == want:
            return pinned
    fail(f"--import-icons: source dir {d} is not a model_raw icon cache "
         f"dir ({ICON_INGEST_SOURCES} under ui_art/model_raw)")
    return ""  # unreachable — fail() exits


def _derive_only_icon_ids() -> set:
    """The derivation-only icon ids, read straight from the manifests
    (§8.8 item 5): any icon declaration carrying a derive op is
    build-derived — model output never writes those assets files.  Today
    that is the wind/current arrow families' 6 derived dirs each; the
    manifest scan auto-extends to any future derivation-only family."""
    out = set()
    icon_dir = MANIFESTS / "icons"
    if not icon_dir.is_dir():
        return out
    for mf in sorted(icon_dir.glob("*.json")):
        try:
            doc = json.loads(mf.read_text())
        except (OSError, ValueError):
            continue
        items = doc if isinstance(doc, list) else doc.get("sprites", [doc])
        for d in items:
            if isinstance(d, dict) and d.get("derive") and d.get("id"):
                out.add(d["id"])
    return out


def _declared_icon_ids() -> set:
    """The icon ids the manifests still declare (the id authority): any
    candidate outside this set is a retired id — skipped with a ledger
    note and its files revoked (the runtime-rotation amendment removed
    the wind arrows' seven sibling ids this way)."""
    out = set()
    icon_dir = MANIFESTS / "icons"
    if not icon_dir.is_dir():
        return out
    for mf in sorted(icon_dir.glob("*.json")):
        try:
            doc = json.loads(mf.read_text())
        except (OSError, ValueError):
            continue
        items = doc if isinstance(doc, list) else doc.get("sprites", [doc])
        for d in items:
            if isinstance(d, dict) and d.get("id"):
                out.add(str(d["id"]))
    return out


def _arrow_base_dir(iid):
    """(family prefix, dir) when the id is an arrow-family BASE candidate
    (n/ne — the derivable source icons); None for everything else."""
    for prefix in ICON_ARROW_FAMILY_PREFIXES:
        if iid.startswith(prefix):
            d = iid[len(prefix):]
            if d in ICON_ARROW_BASE_DIRS:
                return prefix, d
    return None


def _arrow_points_north(px, w, h):
    """True when the 64-grid arrow reads as a NORTH arrow: taller than
    wide, and the head (the widest band) at the top — the derivation
    family's n base must point north or every rotated sibling (e/s/w) is
    mislabeled."""
    bb = bbox_of(px, w, h)
    if bb is None:
        return False
    x0, y0, x1, y1 = bb
    bw, bh = x1 - x0 + 1, y1 - y0 + 1
    if bh <= bw:
        return False

    def band_width(y_lo, y_hi):
        pts = [x for y in range(max(0, y_lo), min(h, y_hi))
               for x in range(w) if px[x + y * w][3]]
        return (max(pts) - min(pts) + 1) if pts else 0

    third = max(1, bh // 3)
    return band_width(y0, y0 + third) > band_width(y1 + 1 - third, y1 + 1)


def _arrow_points_northeast(px, w, h):
    """True when the arrow reads as a NORTH-EAST arrow: the tip touches
    the top-right corner region (the topmost opaque row's center-x sits
    in the right half of the bbox and the rightmost opaque column's
    center-y in the top half)."""
    bb = bbox_of(px, w, h)
    if bb is None:
        return False
    x0, y0, x1, y1 = bb
    top = [x for x in range(w) if px[x + y0 * w][3]]
    right = [y for y in range(h) if px[x1 + y * w][3]]
    if not top or not right:
        return False
    return ((min(top) + max(top)) / 2 > (x0 + x1) / 2
            and (min(right) + max(right)) / 2 < (y0 + y1) / 2)


def _arrow_base_quality(sp: Path, iid: str):
    """Admission check for an arrow-family BASE (n/ne): decodes to the
    64 canvas and verifiably points the declared way.  Returns
    (ok, skip reason)."""
    try:
        w, h, px = decode_png(sp.read_bytes())
    except Exception as exc:
        return False, f"the {iid} base does not decode: {exc}"
    if (w, h) != (CANVAS, CANVAS):
        return False, (f"the {iid} base is {w}x{h}, not the "
                       f"{CANVAS}px canvas")
    d = iid.rsplit("_", 1)[1]
    ok = (_arrow_points_north(px, w, h) if d == "n"
          else _arrow_points_northeast(px, w, h))
    if not ok:
        return False, (f"the model's {d.upper()} base does not read as a "
                       f"{d.upper()}-pointing arrow — the whole family "
                       "keeps its generated art this round")
    return True, ""


def run_icon_ingest(source_dirs, report: dict) -> dict:
    """The formal model-pass icon ingestion (80-* §4.8 64-canvas
    amendment): per snapped 64-grid icon, re-quantize to the icon block
    (the studio ship snaps quantize to the hull block — never trusted for
    icons), halve 64→32 (exact 2:1 nearest), gate on the §4.8.3 32px
    color cap, and write assets/ui/icons/<id>.png as the PRIMARY inline
    art plus the hero 64 asset assets/ui/icons64/<id>.png (the
    2026-11-08 amendment — the quantized 64 grid 1:1; per-file override
    ladder: the string-map generator / ×2 upscale fills any gap).
    Derivation-only ids (manifest derive ops — the wind/current
    arrow families' e/s/w/nw/se/sw) are NEVER ingested: the build derives
    them from their n/ne sources, and an independently generated sibling
    breaks the §8.8 item 5 transform pin — skipped with a ledger note.
    The arrow n/ne BASES may ingest (the refresh path: the build
    re-derives the siblings from the new source) but only when they
    verifiably point the declared way; a poor base skips the whole family
    for the round (generated art stays).  Ledger section `icons{}` per id
    {job, seed, source, snapped_sha, accepted_at} + `icons_skipped{}`;
    accepted ids absent from the source dirs keep their previous entries
    (multi-dir runs merge; a later dir wins per id).  Returns the report
    fragment."""
    candidates: dict[str, tuple[Path, str]] = {}
    for d in source_dirs:
        src_rel = _icon_source_key(d)
        if src_rel == "pixellab_icons":
            # the pixellab pass cache: <dir>/<id>/snapped/icon.png per id
            # (80-* §4.8 2026-11-08); the id is the subdir name
            for sub in sorted(p for p in d.iterdir() if p.is_dir()):
                sp = sub / "snapped" / "icon.png"
                if sp.is_file():
                    candidates[sub.name] = (sp, src_rel)
            continue
        for p in sorted(d.glob(f"{ICON_INGEST_PREFIX}*.png")):
            iid = p.stem[len(ICON_INGEST_PREFIX):]
            if iid:
                candidates[iid] = (p, src_rel)
    prev = _read_ledger("--import-icons")
    prev_icons = prev.get("icons") or {}
    today = time.strftime("%Y-%m-%d", time.gmtime())
    led, rejected, skipped, written = {}, [], [], 0
    derive_only = _derive_only_icon_ids()
    declared = _declared_icon_ids()
    # Arrow-family admission: the n/ne bases must verifiably point the
    # declared way before ANY member of the family may ingest; a poor
    # base skips the whole family for the round (generated art stays).
    arrow_family_skip: dict[str, str] = {}
    for prefix in ICON_ARROW_FAMILY_PREFIXES:
        bases = sorted(iid for iid in candidates
                       if iid.startswith(prefix)
                       and iid[len(prefix):] in ICON_ARROW_BASE_DIRS
                       and iid not in derive_only)
        for iid in bases:
            ok, why = _arrow_base_quality(candidates[iid][0], iid)
            if not ok:
                arrow_family_skip[prefix] = why
                break
    for iid in sorted(candidates):
        sp, src_rel = candidates[iid]
        job = f"{ICON_INGEST_PREFIX}{iid}"
        if iid not in declared:
            skipped.append({"job": job,
                            "reason": "id retired from the manifests",
                            "detail": f"{iid} is no longer a declared icon "
                                      "id — its shipped files revoke"})
            print(f"  icon {iid}: SKIPPED — retired id (files revoke)")
            continue
        if iid in derive_only:
            skipped.append({"job": job,
                            "reason": "derivation-only family",
                            "detail": f"{iid} is build-derived from its "
                                      "n/ne source (§8.8 item 5 manifest "
                                      "derive op) — never ingested"})
            print(f"  icon {iid}: SKIPPED — derivation-only family "
                  "(the build derives it)")
            continue
        fam = _arrow_base_dir(iid)
        if fam is not None and fam[0] in arrow_family_skip:
            skipped.append({"job": job,
                            "reason": "arrow family kept generated",
                            "detail": arrow_family_skip[fam[0]]})
            print(f"  icon {iid}: SKIPPED — {arrow_family_skip[fam[0]]}")
            continue
        raw = sp.read_bytes()
        if raw[:8] != _PNG_SIG:
            rejected.append({"job": job, "reason": "decode",
                             "detail": "source is not a PNG (bad magic bytes)"})
            continue
        try:
            w, h, px = decode_png(raw)
        except Exception as exc:
            rejected.append({"job": job, "reason": "decode",
                             "detail": f"source does not decode: {exc}"})
            continue
        if (w, h) != (CANVAS, CANVAS):
            rejected.append({"job": job, "reason": "canvas",
                             "detail": f"{w}x{h} != {CANVAS}x{CANVAS}"})
            continue
        q = _quantize_icon(w, h, px)
        colors = {("#%02x%02x%02x" % p[:3]) for p in q if p[3]}
        # The hero 64 asset IS the shipped art (the hero-64 display
        # rule — the halved-32 inline family retired): the quantized 64
        # grid 1:1, same binary alpha; the color budget is the block
        # itself (22 colors).
        write_png(ROOT / "assets" / "ui" / ICON_HERO_DIR / f"{iid}.png",
                  w, h, q)
        written += 1
        sha = hashlib.sha256(raw).hexdigest()
        prev_rec = prev_icons.get(iid) or {}
        accepted_at = (prev_rec.get("accepted_at")
                       if prev_rec.get("snapped_sha") == sha else None)
        led[iid] = {"job": job,
                    "seed": _seed_lookup(sp.parent, job),
                    "source": src_rel,
                    "snapped_sha": sha,
                    "accepted_at": accepted_at or today}
        print(f"  icon {iid}: {w}x{h} -> hero 64, {len(colors)} colors, "
              f"sha {sha[:12]}… OK")
    revoked = 0
    for iid in sorted(prev_icons):
        if iid not in led:
            (ROOT / "assets" / "ui" / ICON_HERO_DIR
             / f"{iid}.png").unlink(missing_ok=True)
            revoked += 1
    counts = {"icons": {"candidates": len(candidates),
                        "accepted": len(led), "rejected": len(rejected),
                        "skipped": len(skipped),
                        "files": len(led), "hero_64": len(led)}}
    _write_ledger(prev, "icons", {
        "counts": counts,
        "icons_generated_by": "tools/build_ui_art.py --import-icons",
        "icons_rejected": rejected,
        "icons_skipped": skipped,
        "icons": led,
    })
    report["icons_ingest"] = {
        "candidates": len(candidates), "accepted": len(led),
        "rejected": rejected, "skipped": skipped, "files": written,
        "revoked": revoked, "hero_64": len(led),
    }
    return report["icons_ingest"]


def _quantize_glyph(w, h, px, block):
    """Formal glyph quantize: nearest hex over the OWNING block (markers
    → terrain block, facility → hull block — 80-* §4.8 2026-11-08);
    px below the alpha threshold pass through as fully transparent."""
    out = []
    for p in px:
        if p[3] < ICON_ALPHA_THRESHOLD:
            out.append((0, 0, 0, 0))
        else:
            best_hex, best_d = None, None
            for hx in sorted(block):
                d = _hex_dist(p[:3], _INGEST_HEXES[hx])
                if best_d is None or d < best_d:
                    best_hex, best_d = hx, d
            out.append(_INGEST_HEXES[best_hex] + (255,))
    return out


def run_glyph_ingest(source_dirs, report: dict) -> dict:
    """The formal glyph ingestion (80-* §4.8 2026-11-08 marker/facility
    amendment): per snapped 64-grid glyph, class resolved by id prefix
    (marker_* → the markers dir / terrain block; facility_* → the tokens
    dir / hull block), re-quantize to the OWNING block, halve 64→32
    (exact 2:1 nearest), gate on the §4.8.3 32px cap, write the shipped
    32 (assets/ui/markers/<id>.png / assets/ui/tokens/<id>.png) — no
    hero variants (pinned: no 64px surface for either family).  Ledger
    sections `markers{}` / `facility{}` per id {job, seed, source,
    snapped_sha, accepted_at}; the generator string maps remain the
    per-file fallback.  Returns the report fragment."""
    candidates: dict[str, tuple[Path, str]] = {}
    for d in source_dirs:
        rp = d.resolve().parts
        want = (Path("ui_art") / "model_raw" / "pixellab_glyphs").parts
        if not (len(rp) >= len(want) and rp[-len(want):] == want):
            fail(f"--import-glyphs: source dir {d} is not the "
                 f"model_raw/pixellab_glyphs cache")
        for sub in sorted(p for p in d.iterdir() if p.is_dir()):
            sp = sub / "snapped" / "icon.png"
            if sp.is_file():
                candidates[sub.name] = (sp, "pixellab_glyphs")
    today = time.strftime("%Y-%m-%d", time.gmtime())
    prev = _read_ledger("--import-glyphs")
    led = {"markers": {}, "facility": {}}
    rejected = {"markers": [], "facility": []}
    counts = {"markers": {}, "facility": {}}
    for fam in ("markers", "facility"):
        prev_fam = prev.get(fam) or {}
        written = 0
        for iid in sorted(candidates):
            fam_of_id = next((f for pfx, f in
                              ((k, v[0]) for k, v in GLYPH_FAMILIES.items())
                              if iid.startswith(pfx)), None)
            if fam_of_id != fam:
                continue
            sp, src_rel = candidates[iid]
            job = iid
            raw = sp.read_bytes()
            if raw[:8] != _PNG_SIG:
                rejected[fam].append({"job": job, "reason": "decode",
                                      "detail": "source is not a PNG"})
                continue
            try:
                w, h, px = decode_png(raw)
            except Exception as exc:
                rejected[fam].append({"job": job, "reason": "decode",
                                      "detail": f"does not decode: {exc}"})
                continue
            if (w, h) != (CANVAS, CANVAS):
                rejected[fam].append({"job": job, "reason": "canvas",
                                      "detail": f"{w}x{h} != 64x64"})
                continue
            block = next(v[2] for k, v in GLYPH_FAMILIES.items()
                         if iid.startswith(k))
            q = _quantize_glyph(w, h, px, block)
            colors = {("#%02x%02x%02x" % p[:3]) for p in q if p[3]}
            if len(colors) > GLYPH_INLINE_CAP:
                rejected[fam].append({"job": job, "reason": "budget",
                                      "detail": f"{len(colors)} colors > the "
                                                f"64px cap {GLYPH_INLINE_CAP}"})
                continue
            hero_dir, fam_pfx = next((v[3], k) for k, v in
                                     GLYPH_FAMILIES.items()
                                     if iid.startswith(k))
            if hero_dir:
                # the hero 64 asset (the icons64 pattern): the quantized
                # 64 grid 1:1, same binary alpha — under the BARE id (the
                # registry's facility64_/marker64_ probe strips the 64
                # prefix, so the hero file must not double the family
                # prefix; the 2026-11-08 hero-render regression)
                bare = iid[len(fam_pfx):]
                write_png(ROOT / "assets" / "ui" / hero_dir / f"{bare}.png",
                          w, h, q)
            written += 1
            sha = hashlib.sha256(raw).hexdigest()
            prev_rec = prev_fam.get(iid) or {}
            accepted_at = (prev_rec.get("accepted_at")
                           if prev_rec.get("snapped_sha") == sha else None)
            led[fam][iid] = {"job": job,
                             "seed": _seed_lookup(sp.parent, job, iid=iid),
                             "source": src_rel,
                             "snapped_sha": sha,
                             "accepted_at": accepted_at or today}
            print(f"  glyph {iid}: {w}x{h} -> hero 64, {len(colors)} "
                  f"colors, sha {sha[:12]}… OK")
        revoked = 0
        for iid in sorted(prev_fam):
            if iid not in led[fam]:
                hero_dir, fam_pfx = next((v[3], k) for k, v in
                                         GLYPH_FAMILIES.items()
                                         if iid.startswith(k))
                bare = iid[len(fam_pfx):]
                (ROOT / "assets" / "ui" / hero_dir
                 / f"{bare}.png").unlink(missing_ok=True)
                revoked += 1
        candidates_n = sum(1 for iid in candidates
                           if next((f for pfx, f in
                                    ((k, v[0]) for k, v in
                                     GLYPH_FAMILIES.items())
                                    if iid.startswith(pfx)), None) == fam)
        hero_n = sum(1 for iid in led[fam]
                     if next((v[3] for k, v in GLYPH_FAMILIES.items()
                              if iid.startswith(k)), None))
        counts[fam] = {"candidates": candidates_n,
                       "accepted": len(led[fam]),
                       "rejected": len(rejected[fam]),
                       "skipped": 0, "files": written,
                       "hero_64": hero_n, "revoked": revoked}
    _write_ledger(prev, "glyphs", {
        "counts": counts,
        "markers_generated_by": "tools/build_ui_art.py --import-glyphs",
        "markers_rejected": rejected["markers"],
        "markers_skipped": [],
        "markers": led["markers"],
        "facility_generated_by": "tools/build_ui_art.py --import-glyphs",
        "facility_rejected": rejected["facility"],
        "facility_skipped": [],
        "facility": led["facility"],
    })
    report["glyph_ingest"] = counts
    return report["glyph_ingest"]


def _ring_hi_at64(x, y):
    """The authored phase-0 ring lattice, mapped to the 64 canvas."""
    a, b, m, r = RING_LATTICE
    return (a * (x // 2) + b * (y // 2)) % m == r


def _stamp_land_ring(w, h, px):
    """Stamp the authored phase-0 outer ring (the byte-identical ring the
    ×2-upscale fallback carries): LAND_HI at the lattice positions, LAND
    base elsewhere — §4.8.2 (variants share the identical ring; 32 % 16
    == 0 keeps it torus-continuous)."""
    if (w, h) != (CANVAS, CANVAS):
        fail(f"ring stamp: {w}x{h} is not the {CANVAS}px canvas")
    out = list(px)
    for y in range(h):
        edge = y in (0, h - 1)
        for x in range(w):
            if not (edge or x in (0, w - 1)):
                continue
            hexv = LAND_HI if _ring_hi_at64(x, y) else LAND_BASE
            out[x + y * w] = _INGEST_HEXES[hexv] + (255,)
    return out


def _tone_rank_land_quantize(crop):
    """Tone-rank the crop onto the authored land family's distribution
    (LAND_TONE_HI_FRAC / LAND_TONE_LO_FRAC): rank px by channel-sum
    luminance (ties by index — deterministic), darkest LAND_TONE_LO_FRAC
    → LAND_LO, brightest LAND_TONE_HI_FRAC → LAND_HI, the middle → LAND
    base.  See the constant notes above for why nearest-hex quantization
    is wrong for these crops."""
    n = len(crop)
    order = sorted(range(n), key=lambda i: (sum(crop[i][:3]), i))
    n_lo = round(n * LAND_TONE_LO_FRAC)
    n_hi = round(n * LAND_TONE_HI_FRAC)
    out = [None] * n
    for rank, i in enumerate(order):
        hx = (LAND_LO if rank < n_lo
              else (LAND_HI if rank >= n - n_hi else LAND_BASE))
        out[i] = _INGEST_HEXES[hx] + (255,)
    return out


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
            if len(items) > 1 or isinstance(doc, list):
                # Inventory-only declaration in a multi-sprite manifest
                # (the hero-64 display rule, 2026-11-08): id (+ optional
                # derive relation) with no render output — the arrow
                # refresh and the inventories read these directly from
                # the manifest; the shipped art is the icons64 hero.
                continue
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
    if _ingest_north():
        # North mode (80-* §4.8 2026-11-07): the registry's grid metadata
        # (path_template / owners / authored_dirs / bands) pins the
        # RETIRED 8-dir grids; the string-map renderer still consumes the
        # per-dir docs (the generated north fallback is the outlined ×2
        # 'n' map), so the docs render as usual but the grid checks are
        # legacy metadata here.
        print("  hulls: north mode — registry grid checks are legacy "
              "metadata, skipped (80-* §4.8 2026-11-07)")
    else:
        want_tmpl = (f"{TOKENS_DIR}/hull_{{ship_type}}_{{dir}}.png"
                     if _ingest_raw_dedupe() else
                     f"{TOKENS_DIR}/hull_{{ship_type}}_{{owner}}_{{dir}}.png")
        if reg.get("path_template") != want_tmpl:
            fail(f"hulls.json: path_template {reg.get('path_template')!r} != "
                 f"the pinned {want_tmpl!r} (governor contract drift)")
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

        if _ingest_north():
            # North mode (80-* §4.8 2026-11-07): ONE owner-less north
            # file per ship — the generated fallback is the outlined ×2
            # 'n' map on the 64 canvas; the ladder override serves the
            # committed ingested token byte-identical (ship-as-drawn).
            w, h, px = staged["n"]
            dest = outroot / TOKENS_DIR / f"hull_{ship}.png"
            override = (ingest_files or {}).get((ship, "", "north"))
            if override is not None and override.is_file():
                if override != dest:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(override, dest)
                counts["tokens_ingested"] += 1
                continue
            colors = {("#%02x%02x%02x" % p[:3]) for p in px if p[3]}
            off = sorted(c for c in colors if c not in HULL_BLOCK)
            if off:
                fail(f"hull {ship}/n: hexes outside the hull block "
                     f"(§4.8.4): {off}")
            if len(colors) > COLOR_BUDGET_32:
                fail(f"hull {ship}/n: {len(colors)} colors > budget "
                     f"{COLOR_BUDGET_32} (§4.8.3)")
            write_png(dest, *upscale_nearest(w, h, px,
                                             CANVAS // AUTHORED_GRID))
            counts["tokens"] += 1
            continue

        if _ingest_raw_dedupe():
            # Raw dedupe (80-* §4.8 2026-11-06): ONE owner-less file per
            # ship × dir — no pennant remap, the runtime falls every owner
            # id onto it. The ladder override keys the shared file as
            # (ship, "", dir).
            for d in DIR_ORDER:
                w, h, px = staged[d]
                dest = outroot / TOKENS_DIR / f"hull_{ship}_{d}.png"
                override = (ingest_files or {}).get((ship, "", d))
                if override is not None and override.is_file():
                    if override != dest:
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(override, dest)
                    counts["tokens_ingested"] += 1
                    continue
                colors = {("#%02x%02x%02x" % p[:3])
                          for p in px if p[3]}
                off = sorted(c for c in colors if c not in HULL_BLOCK)
                if off:
                    fail(f"hull {ship}/{d}: hexes outside the hull block "
                         f"(§4.8.4): {off}")
                if len(colors) > COLOR_BUDGET_32:
                    fail(f"hull {ship}/{d}: {len(colors)} colors > budget "
                         f"{COLOR_BUDGET_32} (§4.8.3)")
                write_png(dest, *upscale_nearest(w, h, px,
                                                 CANVAS // AUTHORED_GRID))
                counts["tokens"] += 1
            continue

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
                        # mkdir FIRST: in a temp rebuild (--check /
                        # --contact-sheet) the tokens dir may not exist yet —
                        # if the first iterated file (brigantine/player/e) is
                        # an ingested override, the copy must not depend on a
                        # write_png having run before it (the green-round
                        # FileNotFoundError, 2026-11-05).
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(override, dest)
                    counts["tokens_ingested"] += 1
                    continue
                write_png(dest, *upscale_nearest(w, h, out,
                                                 CANVAS // AUTHORED_GRID))
                counts["tokens"] += 1
    return counts


def run_generic_passes(m: Manifests, outroot: Path, report: dict,
                       artifacts: dict | None = None):
    """Render + derive + outline + the terrain 64-canvas upscale + the
    icon hero-64 fallback (the ×2 upscale of the shipped 32), then the
    §4.8 override ladder for the icon/icons64/terrain families: a ledger
    entry with a committed ingested artifact replaces the generator's file
    (per-file presence — the generator still runs and stays validated;
    the ingested art is the PRIMARY shipped bytes).  Applied before the
    seam-ring verify so the ring reads the shipped canvases."""
    counts = {"rendered": 0, "derived": 0, "outlined": 0,
              "icons_ingested": 0, "icons64_ingested": 0,
              "markers64_ingested": 0, "facility64_ingested": 0,
              "terrain_ingested": 0, "chrome_ingested": 0}
    # The full build writes into the same tree the committed ingested
    # artifacts live in (override == dest) — the render passes below would
    # clobber them.  Stash the ingested bytes first; the ladder restores
    # them after the passes (a temp rebuild copies instead — the override
    # points at the committed tree, the dest at the temp dir).
    stash: dict[Path, bytes] = {}
    for family, dirname, keyed in (("icons", "icons", True),
                                   ("icons64", ICON_HERO_DIR, True),
                                   ("markers64", "markers64", True),
                                   ("facility64", "tokens64", True),
                                   ("terrain", "terrain", False),
                                   ("chrome", "chrome", True)):
        for key, override in sorted(((artifacts or {}).get(family) or {}).items()):
            fname = key if not keyed else f"{key}.png"
            if family in ("markers64", "facility64"):
                # the hero dirs hold BARE ids (the registry strips the 64
                # prefix, which itself sits on the family prefix)
                var_pfx = "marker_" if family == "markers64" else "facility_"
                fname = key[len(var_pfx):] + ".png"
            dest = outroot / "assets" / "ui" / dirname / fname
            if override == dest and dest.is_file():
                stash[dest] = dest.read_bytes()
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
    # The override ladder (§4.8 ingestion contract; the hero-64 display
    # rule, 2026-11-08): the committed ingested artifacts are the primary
    # bytes.  The icons 32 inline ladder is retired — the icons64 heroes
    # ARE the shipped icon art; the markers64/facility64 ladders serve
    # their heroes; the terrain ladder is unchanged.
    heroes = (artifacts or {}).get("icons64") or {}
    for iid in sorted(heroes):
        override = heroes[iid]
        dest = outroot / "assets" / "ui" / ICON_HERO_DIR / f"{iid}.png"
        if override.is_file() and override != dest:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(override, dest)
        elif dest in stash:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(stash[dest])
        counts["icons64_ingested"] += 1
    # §8.8 item 5 refresh path (the 2026-11-08 icon amendment: "the build
    # re-derives the siblings from the new source"): a ledger-ingested
    # arrow BASE re-derives its family siblings at 64 from the SHIPPED
    # base hero — the manifest's authored derive chain operated on the
    # retired 32 grid (the derive decls are gone from the icon
    # manifests), so the refresh keeps the derived hero set coherent.
    # Runs after the icons64 ladder (the shipped base is the ingested
    # bytes) and before the facility64/markers64 ladders.
    arrow_refreshed = 0
    arrow_prefixes = ("wind_arrow_", "current_arrow_")
    for mf in sorted((MANIFESTS / "icons").glob("*.json")):
        try:
            doc = json.loads(mf.read_text())
        except (OSError, ValueError):
            continue
        items = doc if isinstance(doc, list) else doc.get("sprites", [doc])
        for decl in items:
            if not isinstance(decl, dict):
                continue
            d = decl.get("derive")
            if not (isinstance(d, dict) and d.get("op") in DERIVE_OPS):
                continue
            sid = decl.get("id")
            base_id = derive_base_of(d)
            if not sid or not str(base_id).startswith(arrow_prefixes):
                continue
            if base_id not in heroes:  # the ledger-ingested id set
                continue
            base_file = (outroot / "assets" / "ui" / ICON_HERO_DIR
                         / f"{base_id}.png")
            if not base_file.is_file():
                continue
            w, h, px = read_png(base_file)
            w, h, px = _transform(w, h, px, d["op"])
            write_png(outroot / "assets" / "ui" / ICON_HERO_DIR
                      / f"{sid}.png", w, h, px)
            arrow_refreshed += 1
    counts["icons_arrow_refreshed"] = arrow_refreshed
    for family, dirname in (("facility64", "tokens64"),
                            ("markers64", "markers64")):
        # the hero dirs hold BARE ids (the registry strips the 64 prefix,
        # which itself sits on the family prefix)
        fam_pfx = "facility_" if family == "facility64" else "marker_"
        fam64 = (artifacts or {}).get(family) or {}
        for iid in sorted(fam64):
            override = fam64[iid]
            dest = (outroot / "assets" / "ui" / dirname
                    / f"{iid[len(fam_pfx):]}.png")
            if override.is_file() and override != dest:
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(override, dest)
            elif dest in stash:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(stash[dest])
            counts[f"{family}_ingested"] += 1
    terr = (artifacts or {}).get("terrain") or {}
    for fname in sorted(terr):
        override = terr[fname]
        dest = outroot / TERRAIN_OUT_PREFIX / fname
        if override.is_file() and override != dest:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(override, dest)
        elif dest in stash:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(stash[dest])
        counts["terrain_ingested"] += 1
    # chrome ladder (2026-11-08): the ledger-owned singles — the string-map
    # generator still runs for the authored fallback, then the ingested
    # bytes win per id. Runs before run_ninepatch, which assembles the
    # sheets from exactly these singles. The 2026-11-09 native nine-slot
    # amendment: render.js still renders the retired three-part plate
    # singles (corner/edge/fill per family) from the authored manifests;
    # the slot set replaces them wholesale — remove them so the assembly
    # reads only the slots (the manifests stay the generator fallback).
    chrom = (artifacts or {}).get("chrome") or {}
    for sid in sorted(chrom):
        override = chrom[sid]
        dest = outroot / "assets" / "ui" / "chrome" / f"{sid}.png"
        if override.is_file() and override != dest:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(override, dest)
        elif dest in stash:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(stash[dest])
        counts["chrome_ingested"] += 1
    if chrom:
        for fam in CHROME_DERIVATIONS:
            for part in ("corner", "edge"):
                stale = outroot / "assets" / "ui" / "chrome" / f"{fam}_{part}.png"
                if stale.is_file():
                    stale.unlink()
                    counts["chrome_retired"] = counts.get("chrome_retired", 0) + 1
    return counts


def run_seam_ring(m: Manifests, outroot: Path, report: dict):
    """Verify (never alter): variants of a terrain kind share a byte-identical
    outer 1px ring; sea_pattern is torus-safe (80-* §4.8.2). Corner-
    vocabulary kinds are exempt: their per-tile rings intentionally differ
    (each tile carries land in a different corner — the 2026-11-06 PixelLab
    terrain amendment's 16-tile coast_wang Wang corner set; its water-
    flanking edges are the tileset acceptance's contract, not the variant
    gate's)."""
    adir = outroot / "assets/ui"
    if not adir.is_dir():
        return
    groups = {}
    for p in sorted(adir.rglob("*.png")):
        mo = re.fullmatch(r"terrain_([a-z_]+)_(\d+)\.png", p.name)
        if mo:
            if mo.group(1) in SEAM_RING_EXEMPT_KINDS:
                continue  # corner vocabulary — see the docstring
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


def _oriented_px(px, op, T=TILE):
    """Independent orientation math for the nine-patch self-verify: new(x, y)
    for a square TILExTILE tile.  Deliberately a re-derivation, NOT a
    ``_transform`` call — a regression there must not be able to confirm its
    own output (``_verify_transforms`` pins ``_transform`` separately)."""
    if op is None:
        return list(px)
    if op == "mirror_x":
        f = lambda x, y: px[(T - 1 - x) + y * T]
    elif op == "mirror_y":
        f = lambda x, y: px[x + (T - 1 - y) * T]
    elif op == "mirror_xy":
        f = lambda x, y: px[(T - 1 - x) + (T - 1 - y) * T]
    elif op == "rot_ccw":
        f = lambda x, y: px[(T - 1 - y) + x * T]
    elif op == "rot_cw":
        f = lambda x, y: px[y + (T - 1 - x) * T]
    else:
        fail(f"ninepatch self-verify: unknown orientation {op!r}")
    return [f(x, y) for y in range(T) for x in range(T)]


def frame_ops(T):
    """Per-position cell -> (source part, orientation op), computed for a
    T-px tile on a 3T x 3T sheet. The chrome tiles are authored as the
    TOP-LEFT corner / TOP edge only; every other frame cell is a lossless
    orientation of those (2026-11-04 chrome fix: blitting the raw TL tiles
    into all nine cells put TL-shaped corners and horizontal border lines
    into the TR/BL/BR and left/right/bottom cells — the assembled sheet
    sampled broken regions and every themed Button rendered as scattered
    corner-bracket fragments). The 2026-11-09 32px amendment: T comes from
    the tiles themselves (32 for both PixelLab chrome tilesets, 16 for the
    authored bar)."""
    return {
        (0, 0): ("corner", None),                      # TL — as authored
        (2 * T, 0): ("corner", "mirror_x"),            # TR
        (0, 2 * T): ("corner", "mirror_y"),            # BL
        (2 * T, 2 * T): ("corner", "mirror_xy"),       # BR
        (T, 0): ("edge", None),                        # top — as authored
        (T, 2 * T): ("edge", "mirror_y"),              # bottom
        (0, T): ("edge", "rot_ccw"),                   # left — border col 0
        (2 * T, T): ("edge", "rot_cw"),                # right — border col 15
        (T, T): ("fill", None),                        # center
    }


def _cell_pixels(sheet, dx, dy, T=TILE, S=SHEET):
    """A TxT cell of `sheet` at tile offset (dx, dy), row-major."""
    return [sheet[(dx + x) + (dy + y) * S]
            for y in range(T) for x in range(T)]


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
    discipline; parity with the hull color audit, step 7). The PixelLab
    chrome families (2026-11-08) are ship-as-drawn — the ledger-owned
    ids are waived here (group 13 audits their provenance instead), the
    authored bar tiles stay audited."""
    if label in _chrome_ledger_tile_ids():
        return
    colors = {("#%02x%02x%02x" % p[:3]) for p in px if p[3]}
    off = sorted(c for c in colors if c not in ICON_BLOCK)
    if off:
        fail(f"ninepatch: chrome tile {label} hexes outside the icon block "
             f"(§4.8.4): {off}")
    if len(colors) > CHROME_COLOR_CAP:
        fail(f"ninepatch: chrome tile {label} carries {len(colors)} distinct "
             f"colors > the {CHROME_COLOR_CAP} per-tile cap")


def _verify_ninepatch_sheet(name, tiles, sheet, T=TILE, S=SHEET, ops=None,
                            pixellab: bool = False) -> None:
    """Pixel-exact self-verification of one assembled sheet — any mismatch
    is a build FAIL (§4.8.8; makes the misaligned-sheet class of bug
    impossible to ship: the committed 04373ef sheets failed rules 1, 3).
    `ops` maps cell position -> (tile key, orientation op): the native
    nine-slot mapping (each slot at its own position, op None) for the
    ledger-owned PixelLab families, frame_ops(T) for the retired
    authored fallback. pixellab=True (the 2026-11-08 chrome amendment):
    rule 1 stays (every cell byte-equals its source tile — the
    anti-misalignment guarantee), and the authored flat-art pins
    (rules 2–5: opaque content areas, the border/fill hex anchors, the
    SKIN_PINS, the gold map) are replaced by the keyed-plate alpha
    geometry — the fill cell fully opaque, the ring cells carrying
    their keyed transparent outside, and the sheet's far corners
    transparent (the plate silhouette). The 2026-11-09 32px amendment:
    T/S come from the tiles (96/96 chrome)."""
    if ops is None:
        ops = frame_ops(T)
    # 1. every T×T cell byte-equals its oriented source tile.
    for (dx, dy), (part, op) in ops.items():
        want = _oriented_px(tiles[part][2], op, T)
        got = _cell_pixels(sheet, dx, dy, T, S)
        for i, (g, w) in enumerate(zip(got, want)):
            if g != w:
                x, y = i % T, i // T
                fail(f"ninepatch {name}: self-verify — cell ({dx},{dy}) pixel "
                     f"({dx + x},{dy + y}) = {g} != oriented {part}"
                     f"{' ' + op if op else ''} {w}")
    if pixellab:
        _, _, fill_px = tiles["fill"]
        if any(p[3] != 255 for p in fill_px):
            fail(f"ninepatch {name}: self-verify — the fill tile carries "
                 "transparent pixels (the keyed plate interior must be "
                 "fully opaque)")
        for (dx, dy), (part, _) in ops.items():
            cell = _cell_pixels(sheet, dx, dy, T, S)
            if part != "fill" and all(p[3] == 255 for p in cell):
                fail(f"ninepatch {name}: self-verify — the {part} cell at "
                     f"({dx},{dy}) carries no keyed transparent pixels "
                     "(a ring tile without the plate silhouette outside)")
        for (dx, dy) in ((0, 0), (S - 1, 0),
                         (0, S - 1), (S - 1, S - 1)):
            if sheet[dx + dy * S][3] != 0:
                fail(f"ninepatch {name}: self-verify — the sheet corner "
                     f"({dx},{dy}) is not transparent (the plate "
                     "silhouette must stay outside the control corners)")
        return
    # 2. content areas (edge + fill cells) fully opaque — transparent pixels
    #    live ONLY in the corner cells, exactly where the corner tiles carry
    #    the authored outer rounding.
    for (dx, dy), (part, _) in ops.items():
        if part == "corner":
            continue
        for y in range(T):
            for x in range(T):
                if sheet[(dx + x) + (dy + y) * S][3] != 255:
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
            (T + T // 2, 0, border, "top side center"),
            (0, T + T // 2, border, "left side center (border column)"),
            (S - 1, T + T // 2, border, "right side center (border column)"),
            (T + T // 2, S - 1, border, "bottom side center"),
            (4, 0, border, "TL frame (past the authored rounding)"),
            (0, 4, border, "TL frame (past the authored rounding)"),
            (T + T // 2, T + T // 2, fill, "sheet center"),
            (S - 1, 0, None, "TR outer rounding"),
            (0, S - 1, None, "BL outer rounding"),
            (S - 1, S - 1, None, "BR outer rounding"),
    ]:
        got = sheet[x + y * S]
        if want is None:
            if got[3] != 0:
                fail(f"ninepatch {name}: self-verify — ({x},{y}) must be the "
                     "transparent outer rounding (authored corner design)")
        elif got != want:
            fail(f"ninepatch {name}: self-verify — {what} ({x},{y}) = {got} "
                 f"!= {want}")
    # 4. UW2 chrome-skin semantic pins (§4.8 amended 2026-11-04, ledgered):
    #    the skin's own colors at their pinned anchors (48-sheet authored
    #    coordinates — this path only runs for the retired authored
    #    generator chrome, never the ledger-owned PixelLab families).
    for x, y, hexs, what in SKIN_PINS.get(name, []):
        got = sheet[x + y * S]
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
    """Assemble the chrome nine-patch sheets from the chrome tiles
    (step 5) and self-verify every sheet pixel-exactly (build FAIL on
    any mismatch). The 2026-11-09 32px + native nine-slot amendment:
    ledger-owned families assemble from their NINE slot singles, each
    cell = its own as-authored wang tile — no transforms; the tile size
    comes from the tiles themselves (96×96 sheets). The retired authored
    generator path (3 tiles + frame_ops transforms, 48×48) remains the
    fallback; the authored 16px bar band keeps its own 48×48 sheet."""
    adir = outroot / "assets/ui/chrome"
    if not adir.is_dir():
        return "skipped (no chrome output)"
    made = 0
    ledger_tiles = _chrome_ledger_tile_ids()
    for s in NINEPATCH_SETS:
        pixellab_family = all(f"{s}_{slot}" in ledger_tiles
                              for slot, _ in CHROME_SLOTS)
        tiles = {}
        if pixellab_family:
            for slot, _ in CHROME_SLOTS:
                p = find_tile(adir, f"{s}_{slot}")
                if p is None:
                    tiles = None
                    break
                tiles[slot] = read_png(p)
        else:
            for part in ("corner", "edge", "fill"):
                p = find_tile(adir, f"{s}_{part}")
                if p is None:
                    tiles = None
                    break
                tiles[part] = read_png(p)
        if tiles is None:
            report.setdefault("ninepatch_notes", []).append(
                f"{s}: tiles missing (expected chrome_{s}_"
                + ("{tl,tr,bl,br,top,bottom,left,right,fill}.png)"
                   if pixellab_family else
                   "{corner,edge,fill}.png)"))
            continue
        key0 = "tl" if pixellab_family else "corner"
        t = tiles[key0][0]
        if any(img[0] != t or img[1] != t for img in tiles.values()):
            fail(f"ninepatch {s}: chrome tiles must be square and "
                 f"uniform ({t}x{t} expected, §4.8.8)")
        s_size = 3 * t
        for part, img in tiles.items():
            _audit_chrome_tile(f"{s}_{part}", img[0], img[1], img[2])
        sheet = [(0, 0, 0, 0)] * (s_size * s_size)
        if pixellab_family:
            # native nine-slot: each cell blits its own tile as authored
            slot_pos = {"tl": (0, 0), "tr": (2 * t, 0),
                        "bl": (0, 2 * t), "br": (2 * t, 2 * t),
                        "top": (t, 0), "bottom": (t, 2 * t),
                        "left": (0, t), "right": (2 * t, t),
                        "fill": (t, t)}
            ops = {}
            for slot, (dx, dy) in slot_pos.items():
                _, _, px = tiles[slot]
                ops[(dx, dy)] = (slot, None)
                for r in range(t):
                    for c in range(t):
                        sheet[(dx + c) + (dy + r) * s_size] = px[c + r * t]
        else:
            ops = frame_ops(t)
            for (dx, dy), (part, op) in ops.items():
                _, _, px = tiles[part]
                if op is not None:
                    _, _, px = _transform(t, t, px, op)
                for r in range(t):
                    for c in range(t):
                        sheet[(dx + c) + (dy + r) * s_size] = px[c + r * t]
        _verify_ninepatch_sheet(s, tiles, sheet, t, s_size, ops,
                                pixellab=pixellab_family)
        write_png(outroot / f"assets/ui/chrome/ninepatch_{s}.png",
                  s_size, s_size, sheet)
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

def build_into(outroot: Path, ingest_files: dict | None = None,
               artifacts: dict | None = None) -> tuple[Manifests, dict]:
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
        counts = run_generic_passes(m, outroot, report, artifacts)
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
              f"{ing['files']} shipped file(s) written from the model pass, "
              f"{ing.get('painted', 0)} pennant auto-painted")
        for r in ing["rejected"]:
            print(f"    REJECT {r['job']}: {r['reason']} — {r['detail']}")
    for fam, key in (("icon", "icons_ingest"), ("terrain", "terrain_ingest")):
        fi = report.get(key)
        if fi is not None:
            print(f"  {fam} ingest: accepted {fi.get('accepted', 0)}, "
                  f"rejected {len(fi.get('rejected', []))}, "
                  f"{fi.get('files', 0)} file(s) written from the model pass")
            if fam == "icon":
                print(f"    hero 64: {fi.get('hero_64')}")
    g = report.get("generic", {})
    if g.get("icons_ingested") or g.get("terrain_ingested"):
        print(f"  ladder: {g.get('icons_ingested', 0)} icon(s) + "
              f"{g.get('terrain_ingested', 0)} terrain variant(s) served "
              "from the committed ingested artifacts (the generator fills "
              "the gaps)")
    grid_note = ("(16 x 8 shared, owner fallback = 128 expected)"
                 if _ingest_raw_dedupe() else
                 "(16 x 9 x 8 = 1152 expected)")
    print(f"  rendered(render.js): hull maps {h.get('rendered', 0)}, "
          f"generic {g.get('rendered', 0)}; derived {h.get('derived', 0) + g.get('derived', 0)}; "
          f"outlined {h.get('outlined', 0) + g.get('outlined', 0)}; "
          f"hull tokens written {h.get('tokens', 0)} generator + "
          f"{h.get('tokens_ingested', 0)} ingested {grid_note}")
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
    # §4.8 2026-11-06 — the PixelLab coast family joins the same contract
    # through ITS OWN ledger (tools/assets/pixellab_raw/
    # pixellab_coast_ledger.json, the tools/build_terrain_pixellab.py
    # output): the committed tiles are copied into the temp rebuild before
    # the compare, exactly like the ingested tokens the override ladder
    # serves. The family is ledger-governed, never generator-produced
    # (the builder never contacts the API; a rebuild decodes the vendored
    # bytes byte-identically).
    coast_tiles = sorted(
        (ROOT / "tools" / "assets" / "pixellab_raw"
         / "pixellab_coast_ledger.json").is_file()
        and json.loads((ROOT / "tools" / "assets" / "pixellab_raw"
                        / "pixellab_coast_ledger.json").read_text())
        .get("tiles", {}).keys() or [])
    with tempfile.TemporaryDirectory(prefix="ui_art_check.") as td:
        m, _ = build_into(Path(td), resolve_ingest_overrides(),
                          resolve_artifact_overrides())
        for sid in coast_tiles:
            src = committed / "terrain" / f"{sid}.png"
            if not src.is_file():
                fail(f"--check: the coast ledger names {sid} but "
                     "assets/ui/terrain does not ship it; run "
                     "tools/build_terrain_pixellab.py")
            dst_dir = Path(td) / "assets" / "ui" / "terrain"
            dst_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst_dir / f"{sid}.png")
        # §4.8 2026-11-07 — the waterline VFX family joins the same
        # ledger-governed contract: the committed sheets are copied into
        # the temp rebuild before the compare (never regenerated, never
        # re-downloaded). v4 (the per-ship revision): the ledger keys
        # SHIPS, one north sheet per ship type; v3 (superseded): per size.
        fx_ledger = (ROOT / "tools" / "assets" / "pixellab_raw"
                     / "pixellab_vfx_ledger.json")
        if fx_ledger.is_file():
            fx_doc = json.loads(fx_ledger.read_text())
            fx_version = int(fx_doc.get("version", 1))
            fx_keys = list(fx_doc.get("ships", {}).keys()) \
                if fx_version >= 4 \
                else list(fx_doc.get("sizes", {}).keys()) \
                if fx_version >= 2 \
                else list(fx_doc.get("dirs", {}).keys())
            for k in fx_keys:
                single = fx_version >= 3
                name = f"fx_waterline_{k}.png" if single \
                    else f"fx_waterline_back_{k}.png"
                src = committed / "fx" / name
                if not src.is_file():
                    fail(f"--check: the fx ledger names {k}/{name} "
                         "but assets/ui/fx does not ship it; run "
                         "build_ui_art --import-fx-pixellab")
                dst_dir = Path(td) / "assets" / "ui" / "fx"
                dst_dir.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst_dir / name)
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
        m, _ = build_into(Path(td), resolve_ingest_overrides(),
                          resolve_artifact_overrides())
        result = build_contact_sheet(Path(td), m)
        dest, sheet = result
        dest.write_bytes(encode_png_indexed(sheet.w, sheet.h, sheet.px))
        print(f"build_ui_art: contact sheet -> {dest} ({sheet.w}x{sheet.h})")


def run_import_north_mode(raw_root: Path) -> None:
    """--import-ships-north: the top-down hull ingestion (80-* §4.8
    2026-11-07) + the full build. RAW_ROOT is the pixellab_topdown tree
    (default tools/ui_art/model_raw/pixellab_topdown) carrying
    <ship>/snapped/north.png + the manifest. Gate: 16 north files (one
    per ship; gaps fall back to the generated north token)."""
    if not raw_root.is_dir():
        fail(f"import: raw root not found: {raw_root}")
    report = {}
    ingest = run_ship_ingest_north(raw_root, ROOT, report)
    m, report = build_into(ROOT, resolve_ingest_overrides(),
                           resolve_artifact_overrides())
    report["ingest"] = ingest
    summary(m, report, ROOT)
    counts = report.get("hulls", {})
    total = counts.get("tokens", 0) + counts.get("tokens_ingested", 0)
    if m.classes.get("hulls") is not None and total != 16:
        fail(f"hull token count {total} (generator {counts.get('tokens', 0)} "
             f"+ ingested {counts.get('tokens_ingested', 0)}) != 16 "
             "(north: one file per ship)")
    print(f"build_ui_art: ledger -> {INGEST_LEDGER.relative_to(ROOT)}")


def run_import_icons_mode(source_dirs: list[Path]) -> None:
    """--import-icons: the formal icon ingestion (re-quantize to the icon
    block, exact 2:1 nearest halving to the 32px inline art), then the
    full build so the ladder lands the committed artifacts.  Later dirs
    win per id — pass model_raw/snapped plus model_raw/studio/snapped to
    fold the studio re-rolls in."""
    for d in source_dirs:
        if not d.is_dir():
            fail(f"--import-icons: source dir not found: {d}")
    report = {}
    icons = run_icon_ingest(source_dirs, report)
    m, report = build_into(ROOT, resolve_ingest_overrides(),
                           resolve_artifact_overrides())
    report["icons_ingest"] = icons
    summary(m, report, ROOT)
    print(f"build_ui_art: ledger -> {INGEST_LEDGER.relative_to(ROOT)}")


def run_import_glyphs_mode(source_dirs: list[Path]) -> None:
    """--import-glyphs: the formal marker/facility ingestion (re-quantize
    to the owning class block, exact 2:1 nearest halving to the 32px
    asset), then the full build so the ladder lands the committed
    artifacts."""
    for d in source_dirs:
        if not d.is_dir():
            fail(f"--import-glyphs: source dir not found: {d}")
    report = {}
    glyphs = run_glyph_ingest(source_dirs, report)
    m, report = build_into(ROOT, resolve_ingest_overrides(),
                           resolve_artifact_overrides())
    report["glyph_ingest"] = glyphs
    summary(m, report, ROOT)
    print(f"build_ui_art: ledger -> {INGEST_LEDGER.relative_to(ROOT)}")


# ---- PixelLab waterline VFX ingestion (--import-fx-pixellab; 80-* §4.8
# 2026-11-07) ----------------------------------------------------------

FX_LEDGER = (ROOT / "tools" / "assets" / "pixellab_raw"
             / "pixellab_vfx_ledger.json")
FX_DIRS = ("n", "ne", "e", "se", "s", "sw", "w", "nw")
FX_SIZES = (32, 48, 64)
FX_V6_RAW = ROOT / "tools" / "ui_art" / "model_raw" / "pixellab_vfx" / "v6"


def _fx_ships() -> list[str]:
    """The 16 ship type ids (data/ship_types.json) — the single source of
    truth for the v6 per-ship family's key set (80-* §4.8 2026-11-08)."""
    doc = json.loads((ROOT / "data" / "ship_types.json").read_text(
        encoding="utf-8"))
    return sorted(s["id"] for s in doc["ship_types"])

# Terrain kinds exempt from the variant-seam ring gate (corner
# vocabularies — per-tile rings intentionally differ; see run_seam_ring).
SEAM_RING_EXEMPT_KINDS = {"coast_wang"}


def run_import_fx_v6_mode(raw_root: Path) -> None:
    """--import-fx-pixellab (v6, the shipping mode): ingest the top-down
    north wake family VERBATIM — ONE sheet per SHIP TYPE (all 16
    data/ship_types.json ids) out of each raw dir's game pack behind clip
    (the per-ship wake revision, 80-* §4.8 2026-11-08: each wake is
    authored around that ship's own hull silhouette; still the
    single-layer rule — the whole effect renders UNDER the ship, no front
    layer), the committed frame table assets/ui/fx/fx_waterline.json
    **version 4** keyed per ship id and the provenance ledger. The
    builder never contacts the API and never regenerates. Sheet placement
    lives in the frame table: sheet top-left = token box top-left +
    (anchor_sprite + clip offset) (the pack README's `anchor + offset`
    rule with the anchor resolved into the ship's OWN token box by
    tools/pixellab_vfx_pass.py's template match). The runtime rotates the
    sheet together with the hull around the token center."""
    import zipfile  # noqa: PLC0415
    ships = _fx_ships()
    out_fx = ROOT / "assets" / "ui" / "fx"
    out_fx.mkdir(parents=True, exist_ok=True)
    table: dict = {"version": 4,
                   "generated_by":
                       "tools/build_ui_art.py --import-fx-pixellab",
                   "ships": {}}
    ledger: dict = {"version": 4,
                    "generated_by":
                        "tools/build_ui_art.py --import-fx-pixellab",
                    "ships": {}}
    pass_manifest_path = raw_root / "pixellab_vfx.json"
    pass_manifest = (json.loads(pass_manifest_path.read_text())
                     if pass_manifest_path.is_file() else {})
    for ship in ships:
        sdir = raw_root / ship
        if not sdir.is_dir():
            fail(f"--import-fx-pixellab: raw dir missing: {sdir}")
        packs = sorted(sdir.rglob("*-game.zip"))
        if len(packs) != 1:
            fail(f"--import-fx-pixellab: expected exactly 1 game pack under "
                 f"{sdir}, found {len(packs)}")
        pack = packs[0]
        with zipfile.ZipFile(pack) as zf:
            manifest = json.loads(zf.read("manifest.json"))
            clips = {c["name"]: c for c in manifest["clips"]}
            clip = clips["behind"]  # the single layer: everything under
            sheet_file = clip["sheets"][0]["file"]
            data = zf.read(sheet_file)
            out = out_fx / f"fx_waterline_{ship}.png"
            out.write_bytes(data)
            layers = {
                "file": out.name,
                "frame": {"w": clip["frame"]["w"],
                          "h": clip["frame"]["h"]},
                "columns": clip["sheets"][0]["columns"],
                "frames": clip["frames"],
                "offset": {"x": clip["offset"]["x"],
                           "y": clip["offset"]["y"]},
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        # Uniform frame timing gate: the runtime's frame_at is closed-form
        # on frame_ms; a non-uniform pack must fail the ingest loudly.
        frame_json = next(sdir.glob(f"{pack.name[:-9]}.json"), None)
        if frame_json is None:
            fail(f"--import-fx-pixellab: frame json missing for ship "
                 f"{ship} (expected {pack.name[:-9]}.json)")
        frames_meta = json.loads(frame_json.read_text()).get("frames", [])
        durations = sorted({int(f.get("duration", 0))
                            for f in frames_meta})
        frame_ms = int(manifest["frame_ms"])
        if durations != [frame_ms]:
            fail(f"--import-fx-pixellab: ship {ship}: non-uniform durations "
                 f"{durations} != frame_ms {frame_ms}")
        rec = pass_manifest.get(ship, {})
        anchor = rec.get("anchor_sprite")
        if not anchor or anchor.get("method") == "bbox-fallback":
            fail(f"--import-fx-pixellab: ship {ship}: anchor_sprite missing "
                 "or bbox-fallback — re-run tools/pixellab_vfx_pass.py "
                 "v6-run")
        table["ships"][ship] = {
            "sprite": rec.get("sprite"),
            "canvas": manifest["canvas"],
            "fps": manifest["fps"],
            "frame_ms": frame_ms,
            "frames": manifest["frames"],
            "loop": bool(manifest["loop"]),
            "anchor_sprite": {"x": anchor["x"], "y": anchor["y"],
                              "method": anchor["method"],
                              "match_rate": anchor["match_rate"]},
            "sheet": layers,
        }
        ledger["ships"][ship] = {
            "effect_id": rec.get("effect_id"),
            "artist": rec.get("artist", "pro"),
            "name": rec.get("name"),
            "sprite": rec.get("sprite"),
            "quoted_generations": rec.get("quoted_generations"),
            "description_sha256": rec.get("description_sha256"),
            "background_job_id": rec.get("background_job_id"),
            "sheet_sha256": layers["sha256"],
        }
        print(f"  fx {ship}: sheet {layers['frame']['w']}x"
              f"{layers['frame']['h']} @ {frame_ms} ms "
              f"anchor ({anchor['x']},{anchor['y']})", flush=True)
    json_path = out_fx / "fx_waterline.json"
    json_path.write_text(json.dumps(table, indent=1, sort_keys=True) + "\n",
                         encoding="utf-8")
    ledger["table_sha256"] = hashlib.sha256(
        json_path.read_bytes()).hexdigest()
    FX_LEDGER.parent.mkdir(parents=True, exist_ok=True)
    FX_LEDGER.write_text(json.dumps(ledger, indent=1, sort_keys=True) + "\n",
                         encoding="utf-8")
    # Retired-grid hygiene: the per-size single-layer family and the
    # layered families never coexist with the per-ship family.
    pruned = 0
    for f in sorted(out_fx.glob("fx_waterline_*.png")):
        if re.match(r"fx_waterline_(back|front)_.+\.png$", f.name) \
                or re.match(r"fx_waterline_(back|front)_[a-z]+\.png$", f.name) \
                or re.match(r"fx_waterline_(32|48|64)\.png$", f.name):
            f.unlink()
            f.with_name(f.name + ".import").unlink(missing_ok=True)
            pruned += 1
    if pruned:
        print(f"build_ui_art: pruned {pruned} retired waterline sheet(s)")
    print(f"build_ui_art: fx family -> {out_fx.relative_to(ROOT)} "
          f"({len(ships)} sheets + fx_waterline.json)")
    print(f"build_ui_art: fx ledger -> {FX_LEDGER.relative_to(ROOT)}")


def run_import_fx_v5_mode(raw_root: Path) -> None:
    """--import-fx-pixellab (v5, SUPERSEDED by the v6 per-ship mode —
    kept for history/re-ingest): ingest the top-down north wake family
    VERBATIM — ONE sheet per ship SIZE (32/48/64) out
    of each raw dir's game pack behind clip (the single-layer revision:
    the whole effect renders UNDER the ship; no front layer), the
    committed frame table assets/ui/fx/fx_waterline.json **version 3**
    keyed per size and the provenance ledger. The builder never contacts
    the API and never regenerates. Sheet placement lives in the frame
    table: sheet top-left = token box top-left + (anchor_sprite + clip
    offset) (the pack README's `anchor + offset` rule with the anchor
    resolved into the size's token box by tools/pixellab_vfx_pass.py's
    template match). The runtime rotates the sheet together with the
    hull around the token center."""
    import zipfile  # noqa: PLC0415
    out_fx = ROOT / "assets" / "ui" / "fx"
    out_fx.mkdir(parents=True, exist_ok=True)
    table: dict = {"version": 3,
                   "generated_by":
                       "tools/build_ui_art.py --import-fx-pixellab",
                   "sizes": {}}
    ledger: dict = {"version": 3,
                    "generated_by":
                        "tools/build_ui_art.py --import-fx-pixellab",
                    "sizes": {}}
    pass_manifest_path = raw_root / "pixellab_vfx.json"
    pass_manifest = (json.loads(pass_manifest_path.read_text())
                     if pass_manifest_path.is_file() else {})
    for size in FX_SIZES:
        key = str(size)
        sdir = raw_root / key
        if not sdir.is_dir():
            fail(f"--import-fx-pixellab: raw dir missing: {sdir}")
        packs = sorted(sdir.rglob("*-game.zip"))
        if len(packs) != 1:
            fail(f"--import-fx-pixellab: expected exactly 1 game pack under "
                 f"{sdir}, found {len(packs)}")
        pack = packs[0]
        with zipfile.ZipFile(pack) as zf:
            manifest = json.loads(zf.read("manifest.json"))
            clips = {c["name"]: c for c in manifest["clips"]}
            clip = clips["behind"]  # the single layer: everything under
            sheet_file = clip["sheets"][0]["file"]
            data = zf.read(sheet_file)
            out = out_fx / f"fx_waterline_{size}.png"
            out.write_bytes(data)
            layers = {
                "file": out.name,
                "frame": {"w": clip["frame"]["w"],
                          "h": clip["frame"]["h"]},
                "columns": clip["sheets"][0]["columns"],
                "frames": clip["frames"],
                "offset": {"x": clip["offset"]["x"],
                           "y": clip["offset"]["y"]},
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        # Uniform frame timing gate: the runtime's frame_at is closed-form
        # on frame_ms; a non-uniform pack must fail the ingest loudly.
        frame_json = next(sdir.glob(f"{pack.name[:-9]}.json"), None)
        if frame_json is None:
            fail(f"--import-fx-pixellab: frame json missing for size "
                 f"{size} (expected {pack.name[:-9]}.json)")
        frames_meta = json.loads(frame_json.read_text()).get("frames", [])
        durations = sorted({int(f.get("duration", 0))
                            for f in frames_meta})
        frame_ms = int(manifest["frame_ms"])
        if durations != [frame_ms]:
            fail(f"--import-fx-pixellab: size {size}: non-uniform durations "
                 f"{durations} != frame_ms {frame_ms}")
        rec = pass_manifest.get(key, {})
        anchor = rec.get("anchor_sprite")
        if not anchor or anchor.get("method") == "bbox-fallback":
            fail(f"--import-fx-pixellab: size {size}: anchor_sprite missing "
                 "or bbox-fallback — re-run tools/pixellab_vfx_pass.py "
                 "v5-run")
        table["sizes"][key] = {
            "sprite": rec.get("sprite"),
            "canvas": manifest["canvas"],
            "fps": manifest["fps"],
            "frame_ms": frame_ms,
            "frames": manifest["frames"],
            "loop": bool(manifest["loop"]),
            "anchor_sprite": {"x": anchor["x"], "y": anchor["y"],
                              "method": anchor["method"],
                              "match_rate": anchor["match_rate"]},
            "sheet": layers,
        }
        ledger["sizes"][key] = {
            "effect_id": rec.get("effect_id"),
            "artist": rec.get("artist", "pro"),
            "name": rec.get("name"),
            "sprite": rec.get("sprite"),
            "quoted_generations": rec.get("quoted_generations"),
            "description_sha256": rec.get("description_sha256"),
            "background_job_id": rec.get("background_job_id"),
            "sheet_sha256": layers["sha256"],
        }
        print(f"  fx {size}: sheet {layers['frame']['w']}x"
              f"{layers['frame']['h']} @ {frame_ms} ms "
              f"anchor ({anchor['x']},{anchor['y']})", flush=True)
    json_path = out_fx / "fx_waterline.json"
    json_path.write_text(json.dumps(table, indent=1, sort_keys=True) + "\n",
                         encoding="utf-8")
    ledger["table_sha256"] = hashlib.sha256(
        json_path.read_bytes()).hexdigest()
    FX_LEDGER.parent.mkdir(parents=True, exist_ok=True)
    FX_LEDGER.write_text(json.dumps(ledger, indent=1, sort_keys=True) + "\n",
                         encoding="utf-8")
    # Retired-grid hygiene: the two-layer per-size family and the per-dir
    # family never coexist with the single-layer family.
    pruned = 0
    for f in sorted(out_fx.glob("fx_waterline_*.png")):
        if re.match(r"fx_waterline_(back|front)_.+\.png$", f.name) \
                or re.match(r"fx_waterline_(back|front)_[a-z]+\.png$", f.name):
            f.unlink()
            f.with_name(f.name + ".import").unlink(missing_ok=True)
            pruned += 1
    if pruned:
        print(f"build_ui_art: pruned {pruned} retired layered waterline "
              "sheet(s)")
    print(f"build_ui_art: fx family -> {out_fx.relative_to(ROOT)} "
          f"({len(FX_SIZES)} sheets + fx_waterline.json)")
    print(f"build_ui_art: fx ledger -> {FX_LEDGER.relative_to(ROOT)}")


def run_import_fx_mode(raw_root: Path) -> None:
    """--import-fx-pixellab: ingest the PixelLab waterline family
    VERBATIM — behind/front sheets per direction out of each raw dir's
    game pack, the committed frame table assets/ui/fx/fx_waterline.json
    and the provenance ledger. The builder never contacts the API and
    never regenerates; the raw dirs carry effect ids + conversations for
    discounted change-calls. Layer placement lives in the frame table:
    layer top-left = token box top-left + (anchor_sprite + clip offset)
    (the pack README's `anchor + offset` rule with the anchor resolved
    into the 64 token box by tools/pixellab_vfx_pass.py's template
    match)."""
    import zipfile  # noqa: PLC0415
    out_fx = ROOT / "assets" / "ui" / "fx"
    out_fx.mkdir(parents=True, exist_ok=True)
    table: dict = {"version": 1,
                   "generated_by":
                       "tools/build_ui_art.py --import-fx-pixellab",
                   "dirs": {}}
    ledger: dict = {"version": 1,
                    "generated_by":
                        "tools/build_ui_art.py --import-fx-pixellab",
                    "dirs": {}}
    for d in FX_DIRS:
        ddir = raw_root / f"{d}_pro"
        if not ddir.is_dir():
            fail(f"--import-fx-pixellab: raw dir missing: {ddir}")
        # the pass tool nests the dir id under its --raw root
        # (v3/<d>_pro/<d>/), so search recursively for the one game pack.
        packs = sorted(ddir.rglob("*-game.zip"))
        if len(packs) != 1:
            fail(f"--import-fx-pixellab: expected exactly 1 game pack under "
                 f"{ddir}, found {len(packs)}")
        pack = packs[0]
        ddir = pack.parent
        with zipfile.ZipFile(pack) as zf:
            manifest = json.loads(zf.read("manifest.json"))
            clips = {c["name"]: c for c in manifest["clips"]}
            layers = {}
            for layer, clip_name in (("back", "behind"), ("front", "front")):
                clip = clips[clip_name]
                sheet_file = clip["sheets"][0]["file"]
                data = zf.read(sheet_file)
                out = out_fx / f"fx_waterline_{layer}_{d}.png"
                out.write_bytes(data)
                layers[layer] = {
                    "file": out.name,
                    "frame": {"w": clip["frame"]["w"],
                              "h": clip["frame"]["h"]},
                    "columns": clip["sheets"][0]["columns"],
                    "frames": clip["frames"],
                    "offset": {"x": clip["offset"]["x"],
                               "y": clip["offset"]["y"]},
                    "sha256": hashlib.sha256(data).hexdigest(),
                }
        # Uniform frame timing gate: the runtime's frame_at is closed-form
        # on frame_ms; a non-uniform pack must fail the ingest loudly.
        frame_json = next(ddir.glob(f"{pack.name[:-9]}.json"), None)
        if frame_json is None:
            fail(f"--import-fx-pixellab: frame json missing for {d} "
                 f"(expected {pack.name[:-9]}.json)")
        frames_meta = json.loads(frame_json.read_text()).get("frames", [])
        durations = sorted({int(f.get("duration", 0))
                            for f in frames_meta})
        frame_ms = int(manifest["frame_ms"])
        if durations != [frame_ms]:
            fail(f"--import-fx-pixellab: {d}: non-uniform durations "
                 f"{durations} != frame_ms {frame_ms}")
        pass_manifest_path = raw_root / f"{d}_pro" / "pixellab_vfx.json"
        pass_manifest = (json.loads(pass_manifest_path.read_text())
                         if pass_manifest_path.is_file() else {})
        rec = pass_manifest.get(d, {})
        anchor = rec.get("anchor_sprite")
        if not anchor or anchor.get("method") == "bbox-fallback":
            fail(f"--import-fx-pixellab: {d}: anchor_sprite missing or "
                 "bbox-fallback — re-run tools/pixellab_vfx_pass.py")
        table["dirs"][d] = {
            "canvas": manifest["canvas"],
            "fps": manifest["fps"],
            "frame_ms": frame_ms,
            "frames": manifest["frames"],
            "loop": bool(manifest["loop"]),
            "anchor_sprite": {"x": anchor["x"], "y": anchor["y"],
                              "method": anchor["method"],
                              "match_rate": anchor["match_rate"]},
            "layers": layers,
        }
        ledger["dirs"][d] = {
            "effect_id": rec.get("effect_id"),
            "artist": rec.get("artist", "pro"),
            "name": rec.get("name"),
            "quoted_generations": rec.get("quoted_generations"),
            "description_sha256": rec.get("description_sha256"),
            "background_job_id": rec.get("background_job_id"),
            "sheets": {k: v["sha256"] for k, v in layers.items()},
        }
        print(f"  fx {d}: back {layers['back']['frame']['w']}x"
              f"{layers['back']['frame']['h']} + front "
              f"{layers['front']['frame']['w']}x"
              f"{layers['front']['frame']['h']} @ {frame_ms} ms "
              f"anchor ({anchor['x']},{anchor['y']})", flush=True)
    json_path = out_fx / "fx_waterline.json"
    json_path.write_text(json.dumps(table, indent=1, sort_keys=True) + "\n",
                         encoding="utf-8")
    ledger["table_sha256"] = hashlib.sha256(
        json_path.read_bytes()).hexdigest()
    FX_LEDGER.parent.mkdir(parents=True, exist_ok=True)
    FX_LEDGER.write_text(json.dumps(ledger, indent=1, sort_keys=True) + "\n",
                         encoding="utf-8")
    print(f"build_ui_art: fx family -> {out_fx.relative_to(ROOT)} "
          f"(8 dirs x 2 sheets + fx_waterline.json)")
    print(f"build_ui_art: fx ledger -> {FX_LEDGER.relative_to(ROOT)}")


# ---- PixelLab chrome tileset ingestion (--import-chrome-pixellab;
# ---- 80-* §4.8, 2026-11-08 parchment amendment) -------------------------

def _chrome_ledger() -> dict:
    """The chrome{} ledger section (empty when the chrome families are
    generator-authored — the fallback)."""
    doc = _read_ledger("_chrome_ledger")
    return doc.get("chrome") or {}


def _chrome_ledger_tile_ids() -> set:
    """The ledger-owned chrome single ids (ship-as-drawn; the authored
    chrome audits are waived for exactly these)."""
    return set(_chrome_ledger().get("tiles") or {})


def _chrome_find_tileset(family: str) -> Path:
    """The vendored tileset trio for a chrome family — exactly ONE
    tileset_chrome_<family>_<id>.json may exist (the filename is the
    pointer; a re-generation stages the new trio and deletes the old,
    the coast convention)."""
    matches = sorted(p for p in CHROME_RAW_DIR.glob(
        f"tileset_chrome_{family}_*.json")
        if not p.name.endswith(("_request.json", "_submit.json")))
    if len(matches) != 1:
        fail(f"--import-chrome-pixellab: expected exactly one vendored "
             f"tileset_chrome_{family}_*.json under {CHROME_RAW_DIR}, "
             f"found {len(matches)}")
    return matches[0]


def _chrome_green_key(px: list) -> list:
    """The authoring-only green chroma key → alpha: a pixel goes
    transparent iff g ≥ r+MARGIN and g ≥ b+MARGIN (GREEN_KEY_MARGIN).
    Wood / parchment / brass are warm (r-dominant) and never
    false-positive; the rule is deterministic on the vendored bytes.
    Surviving pixels are forced opaque (the model ships no partial
    alpha; crisp sheets only)."""
    m = CHROME_GREEN_MARGIN
    out = []
    for p in px:
        r, g, b = p[0], p[1], p[2]
        if g >= r + m and g >= b + m:
            out.append((0, 0, 0, 0))
        else:
            out.append((r, g, b, 255))
    return out


def _chrome_fill_nearest(px: list, T: int, holes: list[int]) -> None:
    """Fill the hole pixel indices with the nearest clean opaque pixel's
    color (4-conn multi-source BFS over the clean opaque set; first-seen
    ties are deterministic in scan order). Shared by the ring degreen
    pass."""
    import collections  # noqa: PLC0415
    if not holes:
        return
    clean = [i for i, p in enumerate(px) if p[3] and i not in set(holes)]
    dist = [None] * (T * T)
    queue = collections.deque()
    for i in clean:
        dist[i] = 0
        queue.append(i)
    while queue:
        i = queue.popleft()
        x, y = i % T, i // T
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < T and 0 <= ny < T:
                j = nx + ny * T
                if dist[j] is None:
                    dist[j] = dist[i] + 1
                    queue.append(j)
    for i in holes:
        x, y = i % T, i // T
        best, bd = None, None
        for j, dd in enumerate(dist):
            if px[j][3] and (bd is None or dd < bd):
                best, bd = px[j][:3], dd
        if best is not None:
            px[i] = (best[0], best[1], best[2], 255)


def _chrome_degreen_rings(keyed: dict, T: int) -> None:
    """The ring degreen pass (§4.8, 2026-11-09 — non-green lower terrain
    survives the key): the chroma key only catches the promised bright
    green; the model's lower material also survives as dark olive
    (93,113,19 — g−r below the key margin) and dark teal (3,41,43)
    hugging the plate edge inside the ring tiles. Each ring master
    replaces every contaminated opaque pixel with the nearest clean
    opaque pixel (BFS via _chrome_fill_nearest): contaminated =
    green-dominant (g > r and g > b), plus — in WARM families (the
    wang_15 modal face has r > b, the parchment click plate) —
    cool-cast (b >= r). The frame family (cool ocean) only degreens
    green-dominant pixels. The fill master passes through untouched —
    the frame's wave texture is intended detail."""
    fill = keyed.get(CHROME_WANG["fill"])
    if fill is None:
        return
    counts: dict[tuple, int] = {}
    for p in fill:
        if p[3]:
            counts[p[:3]] = counts.get(p[:3], 0) + 1
    if not counts:
        return
    modal = max(counts, key=counts.get)  # stable on ties
    warm = modal[0] > modal[2]

    def contaminated(p) -> bool:
        r, g, b = p[0], p[1], p[2]
        if g > r and g > b:
            return True
        return bool(warm and b >= r)

    for idx in (1, 2, 3, 4, 5, 8, 10, 12):
        px = keyed.get(idx)
        if px is None:
            continue
        holes = [i for i, p in enumerate(px)
                 if p[3] and contaminated(p)]
        _chrome_fill_nearest(px, T, holes)


def _chrome_clip_junk(keyed: dict, T: int) -> None:
    """The junk clip (§4.8, 2026-11-09, user direction — junk patterns
    outside the frame): opaque pixels lying BEYOND a ring tile's own
    median silhouette boundary are lower-material spill the chroma key
    could not catch (brass/brown/olive terrain bits). For each
    silhouette side — the keyed-outside side, i.e. the side NOT reached
    by the tile's material bits — the median of the per-column/row
    first-opaque profile fences the plate: every opaque pixel between
    the tile edge and that fence goes transparent. Pure removal:
    nothing inside the fence is touched, nothing is filled, nothing
    shifts. Runs after degreen; the silhouette-line erosion follows on
    the clipped tiles. The fill master passes through."""
    for idx, bits in ((1, 1), (2, 2), (4, 4), (8, 8),
                      (3, 3), (12, 12), (5, 5), (10, 10)):
        px = keyed.get(idx)
        if px is None:
            continue

        def med(vals) -> int | None:
            s = sorted(v for v in vals if v is not None)
            return s[(len(s) - 1) // 2] if s else None

        fences = []
        if not bits & 12:  # keyed outside at N — top profile fence
            m = med([next((y for y in range(T) if px[x + y * T][3]), None)
                     for x in range(T)])
            if m is not None:
                fences.append(("y<", m))
        if not bits & 3:   # keyed outside at S — bottom profile fence
            m = med([T - 1 - y for x in range(T) for y in (
                next((y for y in range(T - 1, -1, -1)
                      if px[x + y * T][3]), None),) if y is not None])
            if m is not None:
                fences.append(("y>", T - 1 - m))
        if not bits & 10:  # keyed outside at W — left profile fence
            m = med([next((x for x in range(T) if px[x + y * T][3]), None)
                     for y in range(T)])
            if m is not None:
                fences.append(("x<", m))
        if not bits & 5:   # keyed outside at E — right profile fence
            m = med([T - 1 - x for y in range(T) for x in (
                next((x for x in range(T - 1, -1, -1)
                      if px[x + y * T][3]), None),) if x is not None])
            if m is not None:
                fences.append(("x>", T - 1 - m))
        for kind, m in fences:
            for y in range(T):
                for x in range(T):
                    i = x + y * T
                    if not px[i][3]:
                        continue
                    if (kind == "y<" and y < m) \
                            or (kind == "y>" and y > m) \
                            or (kind == "x<" and x < m) \
                            or (kind == "x>" and x > m):
                        px[i] = (0, 0, 0, 0)


def _chrome_erode_silhouette(keyed: dict, T: int) -> None:
    """The silhouette erosion (§4.8, 2026-11-09, user direction — remove
    the leftover 1px outer line): after degreen, erase the outermost
    opaque line on each ring tile's silhouette side — the side where
    the keyed outside sits, i.e. the side NOT reached by the tile's
    material bits. Replace-to-transparent IN PLACE: no re-measuring,
    no shifting, nothing filled back. Direction map (corrected
    2026-11-09 — the keyed outside is on the side the material does
    NOT reach): no N reach (bits&12 unset) erases the TOPMOST opaque
    row; no S reach (bits&3) the BOTTOMMOST opaque row; no W reach
    (bits&10) the LEFTMOST opaque column; no E reach (bits&5) the
    RIGHTMOST opaque column. The whole extreme line goes transparent
    (the line is organic across the span). Band tiles (wang_3/12/5/10)
    have one silhouette side; corner tiles (wang_1/2/4/8) two. Runs
    AFTER degreen and is the LAST chrome pass. The fill master passes
    through."""
    for idx, bits in ((1, 1), (2, 2), (4, 4), (8, 8),
                      (3, 3), (12, 12), (5, 5), (10, 10)):
        px = keyed.get(idx)
        if px is None:
            continue
        if not bits & 12:  # keyed outside at N — erase the topmost line
            top = next((y for y in range(T)
                        if any(px[x + y * T][3] for x in range(T))), None)
            if top is not None:
                for x in range(T):
                    px[x + top * T] = (0, 0, 0, 0)
        if not bits & 3:   # keyed outside at S — erase the bottommost line
            bot = next((y for y in range(T - 1, -1, -1)
                        if any(px[x + y * T][3] for x in range(T))), None)
            if bot is not None:
                for x in range(T):
                    px[x + bot * T] = (0, 0, 0, 0)
        if not bits & 10:  # keyed outside at W — erase the leftmost line
            left = next((x for x in range(T)
                         if any(px[x + y * T][3] for y in range(T))), None)
            if left is not None:
                for y in range(T):
                    px[left + y * T] = (0, 0, 0, 0)
        if not bits & 5:   # keyed outside at E — erase the rightmost line
            right = next((x for x in range(T - 1, -1, -1)
                          if any(px[x + y * T][3] for y in range(T))), None)
            if right is not None:
                for y in range(T):
                    px[right + y * T] = (0, 0, 0, 0)


def _chrome_load_masters(family: str, T: int = 32) -> tuple[dict, dict]:
    """Decode one vendored chrome tileset → ({wang_index: keyed px},
    {wang_index: pixel_id}), verifying the name↔corners bit consistency
    (bit = NW·8+NE·4+SW·2+SE·1, upper = 1), the T×T canvas, and the
    green-key sanity (every ring tile carries keyed-out pixels; the
    fill source wang_15 is fully opaque — the plate interior must never
    leak the key). The 2026-11-09 32px amendment: both PixelLab chrome
    tilesets are T=32 (the authored bar tiles stay 16, outside this
    loader); ring tiles take the ring degreen pass and the silhouette
    erosion (§4.8)."""
    path = _chrome_find_tileset(family)
    doc = json.loads(path.read_text())
    tiles = (doc.get("tileset") or doc).get("tiles") or []
    if len(tiles) != 16:
        fail(f"{path.name}: expected 16 wang tiles, got {len(tiles)}")
    masters: dict[int, list] = {}
    pixel_ids: dict[int, str] = {}
    keyed: dict[int, list] = {}
    for tile in tiles:
        name = str(tile.get("name", ""))
        if not name.startswith("wang_"):
            fail(f"{path.name}: unexpected tile name {name!r}")
        i = int(name.split("_", 1)[1])
        corners = tile.get("corners") or {}
        bits = 0
        for shift, ck in ((8, "NW"), (4, "NE"), (2, "SW"), (1, "SE")):
            if str(corners.get(ck, "")).lower() == "upper":
                bits |= shift
        if bits != i:
            fail(f"{path.name}: {name} corners {corners} != bit value "
                 f"{i} (upper = plate material)")
        png = base64.b64decode((tile.get("image") or {}).get("base64") or "")
        w, h, px = decode_png(png)
        if (w, h) != (T, T):
            fail(f"{path.name}: {name} is {w}x{h}, expected "
                 f"{T}x{T} (the chrome envelope pins {T}px tiles)")
        keyed[i] = _chrome_green_key(px)
        pixel_ids[i] = str(tile.get("id", ""))
    _chrome_degreen_rings(keyed, T)
    _chrome_clip_junk(keyed, T)
    _chrome_erode_silhouette(keyed, T)
    for i, px in keyed.items():
        opaque = sum(1 for p in px if p[3])
        if i == CHROME_WANG["fill"]:
            if opaque != T * T:
                fail(f"{path.name}: wang_15 (the fill source) is not "
                     f"fully opaque after the green key ({opaque}/"
                     f"{T * T}) — the lower material leaked into "
                     "the plate interior")
        elif i in (1, 2, 3, 4, 5, 8, 10, 12):
            if opaque == T * T:
                fail(f"{path.name}: wang_{i} has no green-keyed pixels — "
                     "the lower material never appears on a ring tile; "
                     "is this the chrome tileset?")
        masters[i] = px
    return masters, pixel_ids


def _chrome_band_mask_px(px: list, radius: int, T: int = TILE) -> list[bool]:
    """BFS distance-to-outside over the keyed TxT tile: True for opaque
    pixels within `radius` of a transparent pixel (the keyed outside
    wraps the silhouette). A tile with NO keyed pixels (the fill source,
    wang_15) has no outside — all-False, so ring/clean ops treat it as
    pure face."""
    import collections  # noqa: PLC0415
    band = [False] * (T * T)
    if not any(p[3] == 0 for p in px):
        return band
    queue = collections.deque()
    for y in range(T):
        for x in range(T):
            i = x + y * T
            if px[i][3] == 0:
                continue
            near_outside = False
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if not (0 <= nx < T and 0 <= ny < T) \
                        or px[nx + ny * T][3] == 0:
                    near_outside = True
            if near_outside:
                band[i] = True
                queue.append((x, y, 0))
    while queue:
        x, y, d = queue.popleft()
        if d >= radius:
            continue
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < T and 0 <= ny < T:
                i = nx + ny * T
                if px[i][3] and not band[i]:
                    band[i] = True
                    queue.append((nx, ny, d + 1))
    return band


def _chrome_band_mask(px: list, T: int = TILE) -> list[bool]:
    """The hover band: BFS distance-to-outside ≤ CHROME_HOVER_RIM_BAND
    (the brass band flares on hover — §4.8 2026-11-08 night). Delegates
    to the radius-parameterized mask."""
    return _chrome_band_mask_px(px, CHROME_HOVER_RIM_BAND, T)


def _chrome_derive(px: list, op: str, T: int = TILE) -> list:
    """One derivation op (80-* §4.8 2026-11-08): base = as keyed;
    invert = rot_180 (the bevel light flips TL→BR — the sunken rim);
    press = invert + every opaque pixel ×PRESS_DARKEN; recess =
    every opaque pixel ×FIELD_RECESS (no rotate — the inset-paper
    interior); lift = the rim-weighted hover glow (the brass band
    within HOVER_RIM_BAND of the keyed outside flares at 0.35, the
    face warms at 0.05); ring = the 1px ACCENT
    silhouette ring (opaque pixels 4-adjacent to transparent)."""
    if op == "base":
        return list(px)
    if op == "invert":
        return _transform(T, T, px, "rot_180")[2]
    if op == "press":
        rot = _transform(T, T, px, "rot_180")[2]
        f = CHROME_PRESS_DARKEN
        return [((round(p[0] * f), round(p[1] * f), round(p[2] * f), 255)
                 if p[3] else p) for p in rot]
    if op == "recess":
        f = CHROME_FIELD_RECESS
        return [((round(p[0] * f), round(p[1] * f), round(p[2] * f), 255)
                 if p[3] else p) for p in px]
    if op == "lift":
        # Rim-weighted hover (§4.8, 2026-11-08 night): the brass band
        # flares, the face warms faintly. Band membership = BFS distance
        # to the keyed transparent outside ≤ HOVER_RIM_BAND (the band IS
        # the silhouette-adjacent zone — no palette knowledge needed,
        # ship-as-drawn stays honest).
        band = _chrome_band_mask_px(px, CHROME_HOVER_RIM_BAND, T)
        out = []
        for i, p in enumerate(px):
            if not p[3]:
                out.append(p)
                continue
            lift = (CHROME_HOVER_RIM_LIFT if band[i]
                    else CHROME_HOVER_FACE_LIFT)
            out.append((round(p[0] + (255 - p[0]) * lift),
                        round(p[1] + (255 - p[1]) * lift),
                        round(p[2] + (255 - p[2]) * lift), 255))
        return out
    if op == "ring":
        ring = _hex_px(CHROME_FOCUS_RING)
        out = []
        for y in range(T):
            for x in range(T):
                p = px[x + y * T]
                if p[3] and any(
                        not (0 <= x + dx < T and 0 <= y + dy < T)
                        or px[(x + dx) + (y + dy) * T][3] == 0
                        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                    out.append(ring)
                else:
                    out.append(p)
        return out
    fail(f"chrome derivation: unknown op {op!r}")


def run_import_chrome_mode(raw_root: Path | None = None) -> None:
    """--import-chrome-pixellab (80-* §4.8, 2026-11-08): decode the two
    vendored chrome tilesets (frame + button), green-key the lower
    material to alpha, derive the six chrome families' singles
    (panel/field from the frame plate; button/hover/pressed/focus from
    the button plate), write them to assets/ui/chrome/, and record the
    committed chrome{} ledger section (tileset ids + per-tile pixel ids
    + derivations + output sha). Ship-as-drawn: no quantize, no color
    cap — group 13 waives the authored-chrome audits for these ids via
    this ledger. Rebuilds are byte-identical from the vendored bytes;
    the API is never contacted."""
    del raw_root  # the vendored trios live at CHROME_RAW_DIR (the pointer)
    masters_by_source: dict[str, tuple[dict, dict]] = {}
    tileset_ids: dict[str, str] = {}
    tiles_doc: dict[str, dict] = {}
    written = 0
    out_dir = ROOT / "assets" / "ui" / "chrome"
    out_dir.mkdir(parents=True, exist_ok=True)
    for family, (source, parts) in CHROME_DERIVATIONS.items():
        if source not in masters_by_source:
            masters_by_source[source] = _chrome_load_masters(
                source, CHROME_SOURCE_PX[source])
            tid_path = _chrome_find_tileset(source)
            submit_p = tid_path.with_name(tid_path.stem + "_submit.json")
            tileset_ids[source] = \
                json.loads(submit_p.read_text()).get("tileset_id", "?") \
                if submit_p.is_file() else tid_path.stem.rsplit("_", 1)[-1]
        masters, pixel_ids = masters_by_source[source]
        t_px = CHROME_SOURCE_PX[source]
        for slot, (wang, op) in parts.items():
            sid = f"{family}_{slot}"
            px = masters[wang]
            px = _chrome_derive(px, op, t_px)
            out = out_dir / f"{sid}.png"
            write_png(out, t_px, t_px, px)
            tiles_doc[sid] = {
                "family": family, "part": slot, "from": source,
                "wang": wang, "derivation": op,
                "size": t_px,
                "pixel_id": pixel_ids[wang],
                "sha256": hashlib.sha256(out.read_bytes()).hexdigest(),
            }
            written += 1
        # the retired corner/edge singles must not linger — the nine-slot
        # set replaces them wholesale (fill is a REAL slot: never touched)
        for part in ("corner", "edge"):
            stale = out_dir / f"{family}_{part}.png"
            if stale.is_file():
                stale.unlink()
    prev = _read_ledger("--import-chrome-pixellab")
    _write_ledger(prev, "chrome", {
        "chrome_generated_by": "build_ui_art --import-chrome-pixellab",
        "chrome_rejected": [],
        "chrome": {
            "tilesets": {s: {"tileset_id": t}
                         for s, t in sorted(tileset_ids.items())},
            "tiles": tiles_doc,
        },
        "counts": {"chrome_ingested": written},
    })
    print(f"chrome ingest: {written} singles written to assets/ui/chrome "
          f"({', '.join(f'{s}={t[:8]}…' for s, t in sorted(tileset_ids.items()))}); "
          "ledger chrome{} updated")


def main() -> None:
    ap = argparse.ArgumentParser(description="Phase-10 UI art governor (docs/IMPLEMENT-Phase10.md decision 5/9, 80-* §4.8)")
    ap.add_argument("--check", action="store_true",
                    help="rebuild into a temp dir and byte-compare against assets/ui/ (§8.8)")
    ap.add_argument("--contact-sheet", action="store_true",
                    help="emit tools/contact_sheet.png (decision 9.4 review gate)")
    ap.add_argument("--import-ships-north", nargs="?", const="auto",
                    metavar="RAW_ROOT",
                    help="ingest the top-down north hull tokens (80-* §4.8 "
                         "2026-11-07): one owner-less tier-sized north file "
                         "per ship, raw 1:1, no quantize, committed "
                         "provenance ledger; RAW_ROOT is the "
                         "pixellab_topdown tree (default "
                         "tools/ui_art/model_raw/pixellab_topdown)")
    ap.add_argument("--import-icons", metavar="SRC_DIR", nargs="+",
                    help="ingest the model-pass snapped icons (64-grid "
                         "RGBA) from one or more SRC_DIRs (later dirs win "
                         "per id) — re-quantize to the icon block, exact "
                         "2:1 nearest halving to the 32px inline art PLUS "
                         "the hero 64 asset (assets/ui/icons64/<id>.png, "
                         "2026-11-08), committed provenance ledger; the "
                         "string-map generator / ×2 upscale is the "
                         "per-file fallback; SRC_DIRs are the flat "
                         "icon_<id>.png caches (model_raw/snapped, "
                         "model_raw/studio/snapped) or the pixellab "
                         "per-id tree (tools/pixellab_pass.py --icons: "
                         "model_raw/pixellab_icons)")
    ap.add_argument("--import-glyphs", nargs="?", const="auto",
                    metavar="SRC_DIR",
                    help="ingest the PixelLab marker/facility glyphs (80-* "
                         "§4.8 2026-11-08): per id re-quantize to the "
                         "owning class block (markers → terrain, facility "
                         "→ hull), exact 2:1 halving to the 32px asset, "
                         "committed provenance ledger; SRC_DIR is the "
                         "pixellab_glyphs tree (default "
                         "tools/ui_art/model_raw/pixellab_glyphs); the "
                         "string-map generator is the per-file fallback; "
                         "no hero variants (pinned)")
    ap.add_argument("--import-fx-pixellab", nargs="?", const="auto",
                    metavar="RAW_ROOT",
                    help="ingest the PixelLab waterline VFX family verbatim "
                         "(80-* §4.8): v6 = the per-ship north family (ONE "
                         "sheet per ship type + the v4 fx_waterline.json + "
                         "provenance ledger; RAW_ROOT default "
                         "tools/ui_art/model_raw/pixellab_vfx/v6); with "
                         "--fx-legacy the retired per-dir v3 family "
                         "(RAW_ROOT default .../v3)")
    ap.add_argument("--fx-legacy", action="store_true",
                    help="with --import-fx-pixellab: ingest the RETIRED "
                         "per-dir v3 waterline family instead of v5")
    ap.add_argument("--import-chrome-pixellab", nargs="?", const="auto",
                    metavar="RAW_ROOT",
                    help="ingest the PixelLab chrome tilesets (80-* §4.8 "
                         "2026-11-08): decode the vendored frame+button "
                         "Wang sets, green-key the lower material to "
                         "alpha, derive the six chrome families' singles "
                         "(panel/field/button/hover/pressed/focus), "
                         "write assets/ui/chrome/ + the committed chrome{} "
                         "ledger; ship-as-drawn, byte-identical rebuilds "
                         "(the vendored trios live at "
                         "tools/assets/pixellab_raw/ — the pointer is the "
                         "filename)")
    args = ap.parse_args()
    modes = [args.check, args.contact_sheet,
             args.import_icons, args.import_ships_north,
             args.import_fx_pixellab, args.import_glyphs,
             args.import_chrome_pixellab]
    if sum(1 for m in modes if m) > 1:
        fail("--check, --contact-sheet, --import-icons, "
             "--import-ships-north, --import-fx-pixellab, "
             "--import-glyphs and --import-chrome-pixellab are mutually "
             "exclusive modes")
    if args.check:
        run_check()
        return
    if args.contact_sheet:
        run_contact_sheet()
        return
    if args.import_ships_north:
        root = (ROOT / "tools" / "ui_art" / "model_raw" / "pixellab_topdown")
        if args.import_ships_north != "auto":
            root = Path(args.import_ships_north)
        run_import_north_mode(root)
        return
    if args.import_fx_pixellab:
        if args.fx_legacy:
            root = (ROOT / "tools" / "ui_art" / "model_raw" / "pixellab_vfx"
                    / "v3")
            if args.import_fx_pixellab != "auto":
                root = Path(args.import_fx_pixellab)
            run_import_fx_mode(root)
            return
        root = FX_V6_RAW
        if args.import_fx_pixellab != "auto":
            root = Path(args.import_fx_pixellab)
        run_import_fx_v6_mode(root)
        return
    if args.import_icons:
        run_import_icons_mode([Path(p) for p in args.import_icons])
        return
    if args.import_glyphs:
        root = ROOT / "tools" / "ui_art" / "model_raw" / "pixellab_glyphs"
        if args.import_glyphs != "auto":
            root = Path(args.import_glyphs)
        run_import_glyphs_mode([root])
        return
    if args.import_chrome_pixellab:
        run_import_chrome_mode(
            None if args.import_chrome_pixellab == "auto"
            else Path(args.import_chrome_pixellab))
        return
    m, report = build_into(ROOT, resolve_ingest_overrides(),
                           resolve_artifact_overrides())
    summary(m, report, ROOT)
    counts = report.get("hulls", {})
    total = counts.get("tokens", 0) + counts.get("tokens_ingested", 0)
    if m.classes.get("hulls") is not None and total != 16 * 9 * 8:
        fail(f"hull token count {total} (generator {counts.get('tokens', 0)} "
             f"+ ingested {counts.get('tokens_ingested', 0)}) != 1152")


if __name__ == "__main__":
    main()
