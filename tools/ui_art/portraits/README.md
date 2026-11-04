# tools/ui_art/portraits — portrait part sheets (Phase-10 W3-D)

The 25 procedural-bust part layers of A.7 (`docs/IMPLEMENT-Phase10.md`),
the composer contract for W4-D `scripts/ui/portrait_composer.gd`, and
the deterministic generator that emits them.

## Inventory — 25 sheets (72×96 RGBA, 3:4 bust, front-facing)

| family | ids | notes |
|---|---|---|
| base | `pp_base` | shared under-layer: head/neck/shoulders silhouette, 3-step skin ramp (NW light, dithered bands), `PORTRAIT_INK` outline |
| face ×4 | `pp_face_{lean,round,scarred,weathered}` | overlay features on the SAME head position; brows + nose hint common to all, cheek/jaw shading per type; scarred = `SKIN_LO` scar line + ticks; weathered = wrinkle pixels |
| eyes ×4 | `pp_eyes_{dark,grey,hazel,pale_blue}` | 3×2 clusters at anchored cells (dx ±4), bottom-center ink pupil — identical cell set for all four |
| beard ×4 | `pp_beard_{clean,forked,full,stubble}` | anchored to the shared jaw line; `clean` = fully transparent layer (shipped per A.7; composer may skip it) |
| hair ×4 | `pp_hair_{black,brown,grey_streaked,sun_bleached}` | crown cap + sideburns on the shared silhouette; grey_streaked = `HAIR_GREY` + 4 `HAIR_STREAK` strands; sun_bleached = 1px-receded variant; brown = widow's-peak variant |
| cloth ×8 | `pp_cloth_{trader,coaster,courier,patrol,privateer,pirate,hunter,player}` | coat layer per the §4.8 cloth rule (see adjudication 1) |

Palette: `portrait` block hexes only (§4.8 table); budget 48px+ ≤ 25 —
each sheet uses a small subset.

## Composer contract (W4-D)

Fixed `appearance` dict → fixed part list; stack order
**base → face → eyes → beard → hair → cloth** (later layers win; the
only designed overlaps are hair-over-face at the crown, beard-over-face
at the jaw, cloth-over-base at the torso). Override file
(`assets/ui/overrides/portrait_{id}.png`) always wins. All parts are
generated from the one shared `anchors.json` — pixel compatibility at
the anchors is by construction, and `compose_check.py` pins it.

## Adjudications (ledger)

1. **Patrol/privateer cloth (W3-D PIN).** §4.8 pins the cloth VALUES
   per role+nation, but A.7 ships 8 sheets (7 roles + player) and a
   per-role sheet cannot vary by owner. The `pp_cloth_patrol` and
   `pp_cloth_privateer` sheets render a **neutral `CLOTH_LINE` body +
   `CLOTH_ACCENT` diagonal sash**; the sheets themselves stay
   palette-block-clean, and the RUNTIME composer (W4-D) may re-tint the
   sash pixels (exactly the `#d9a441` cells) to the owner nation's
   `CLOTH_{nation}` hex via palette swap. Roles read national through
   the sash and are distinguished by the role badge (§4.8).
2. **Beard color = hair palette swap.** The 4 beard sheets render in
   `HAIR_BROWN` (`#6b4a2a`) as the swap SOURCE: the composer re-maps
   beard pixels to the captain's `hair` hex so a black-haired captain
   gets a black beard (4×4 = 16 sheets avoided). Without the swap,
   brown is the neutral default.
3. **`pp_beard_clean` is a real, fully transparent 72×96 layer** — the
   composer may skip overlaying it, but the file ships so the part id
   always resolves (A.7).
4. **Cloth shading dither.** Dark coats get a sparse (hash < 0.3)
   `SKIN_HI` rim dither on the NW top/left edge; the light player coat
   gets a `SKIN_LO` rim on the SE bottom/right edge — NW light, dither
   density well under the 30% cap. Cloth bodies are otherwise flat
   (the block pins one hex per cloth role; no cloth ramp exists).
5. **Binary alpha** per sheet (0/255), RGBA output — the composer does
   plain source-over stacking.
6. **Crop convention:** the bust is cropped at the canvas bottom edge —
   torso/coat outlines skip the y = 95 edge (`crop_bottom`), so the
   sprite reads as continuing below the frame.

## Files

- `anchors.json` — the shared coordinate anchors (head ellipse, eye
  line, hairline, beard band, neck, torso/coat trapezoids, sash line,
  skin-ramp dither bands). Inputs, not render targets.
- `gen_portraits.py` — stdlib-only deterministic generator; emits the
  25 declarations beside itself. `--check` verifies committed bytes
  (gate 2). The fixed integer hash `h()` (same structure as the
  engine's `H`) drives all speckle/dither.
- `pp_*.json` — generated declarations (string-map mode, `png: rgba`,
  width/height cross-checked). Render targets for the governor →
  `assets/ui/portraits/<id>.png`.
- `compose_check.py` — gate checker: renders FX + sheets via
  `node tools/yoyopixel/render.js` (node pinned v24.16.0), asserts
  sizes, palette-block purity at the pixel level, anchor alignment
  (eyes/beard/face/hair/cloth boxes, identical eye cell sets, clean
  beard empty), composes 4 fixed legend appearances and proves each
  layer lands; ASCII bust to the log, PNG composites to a temp dir.
  `python3 tools/ui_art/portraits/compose_check.py` — exit 0 = green.

## Regenerating

```
python3 tools/ui_art/portraits/gen_portraits.py          # rewrite in place
python3 tools/ui_art/portraits/gen_portraits.py --check  # byte-drift gate
```

`anchors.json` and the `pp_*.json` declarations are committed; nothing
under `assets/` is committed from this slot (the master renders at the
wave gate).
