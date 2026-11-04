# render.js — the vendored YoYoPixel engine core as a node CLI

`tools/yoyopixel/render.js` renders JSON sprite declarations to PNG files.
Section 1 of the file is the pixel-math script extracted verbatim from the
upstream `engine-v3.html` (`PB`, `blit`/`blitA`, `H`, `hx`, `nz`, `pk`,
`inE`/`inRR`, `shade`/`dk`/`lt`, `adaptiveOutlineColor`, `MAT_SHADERS`,
`renderSprite`); the PNG encoder, declaration renderer, and CLI are
first-party. See `VENDORED.md` and `LICENSE` (MIT, © 2026 SbName) for
provenance.

## Environment pins

- **Node v24.16.0** (docs/IMPLEMENT-Phase10.md decision 5 / correction 10).
  `fixture_check.py` refuses any other version; rebuilds are only
  byte-identical under the pinned runtime.
- **Zero npm dependencies.** `render.js` requires only node builtins
  (`zlib`, `fs`, `path`). No `package.json`, no install step, no network
  access at runtime.

## CLI usage

```
node tools/yoyopixel/render.js <declaration.json> [<declaration2.json> ...]
```

- Each JSON file holds **one** sprite declaration object, an **array** of
  them, or `{"sprites": [...]}`.
- Output paths (`file`) resolve against the **process current directory**;
  parent directories are created automatically.
- Exit 0 on success, exit 2 with a one-line `render.js: <file>: <message>`
  diagnostic on any bad input (unreadable file, invalid JSON, schema
  violation, >256 colors in indexed mode).

## Declaration format

Shared keys (both styles):

| key | meaning |
|-----|---------|
| `id` | sprite id (required, non-empty string) |
| `file` | output PNG path, relative to the CWD (required) |
| `mode` | `"string-map"` or `"template"`; optional — inferred from `rows` / `grid` when absent |
| `width`, `height` | optional cross-check against the rendered size (error on mismatch) |
| `png` | `"indexed"` (PNG color type 3) or `"rgba"` (color type 6); default: indexed for string-map, rgba for template |
| `background` | optional `"#rrggbb"`; fills fully-transparent pixels after rendering (equivalent of the upstream demos' canvas pre-fill) |

### Style A — string-array maps (`"mode": "string-map"`)

Flat pixel rows + palette dict, for chrome, arrows, semantic marks. No
engine shading — exact flat colors (the skill's grid format).

```json
{
  "id": "wind_arrow_ne",
  "file": "out/wind_arrow_ne.png",
  "mode": "string-map",
  "width": 7, "height": 7,
  "png": "indexed",
  "palette": { "a": "#e8e0d0", ".": "transparent" },
  "rows": [
    "...a...",
    "..aaa..",
    ".aaaaa.",
    "aaaaaaa",
    "...a...",
    "...a...",
    "...a..."
  ]
}
```

- `rows`: non-empty array of equal-length strings; size = width of row 0 ×
  row count.
- `palette`: required dict, char → `"#rrggbb"` or the keyword
  `"transparent"` (case-sensitive). `"."` defaults to transparent when
  absent; any other rendered char missing from the palette is an error.

### Style B — engine templates / region+material (`"mode": "template"`)

The extracted engine's own template language, ported as-is: `{grid,
materials}` plus a color map and scale, rendered by the vendored
`renderSprite` (per-material hue-shift shading, specular pass, adaptive
outline).

```json
{
  "id": "potion_blue",
  "file": "out/potion_blue.png",
  "mode": "template",
  "scale": 2,
  "png": "rgba",
  "grid": [
    "..cc..",
    "..kk..",
    ".GGGG.",
    "GLLLLG",
    "GLLLLG",
    "GLLLLG",
    "GLLLLG",
    ".GGGG."
  ],
  "materials": {
    "c": "cork",
    "k": "cork",
    "G": { "type": "glass", "alpha": 200 },
    "L": "liquid"
  },
  "colors": {
    "c": "#907050",
    "k": "#907050",
    "G": "#6888a0",
    "L": "#2848a0"
  }
}
```

- `grid`: non-empty array of equal-length strings (`.` = empty).
- `materials`: required dict, char → material **name** (one of the 15
  shader names: `wood wood_dark glass liquid metal gold cloth leather
  ceramic gem paper flat cork plant fire`) or `{ "type": "...",
  "alpha": 0-255 }`. Exactly as upstream, an unknown material name falls
  back to `flat`, and `alpha` falls back to the shader's own alpha
  (glass: 200) then 255.
- `colors`: optional dict, char → `"#rrggbb"`; a char with no color uses
  the engine default `[128,128,128]`.
- `scale`: optional integer 1–64 (default 1); output size =
  grid width × scale, grid height × scale.

## PNG output modes

- **indexed** (color type 3, bit depth 8): palette = distinct RGBA tuples
  in first-appearance scan order; per-entry alpha rides in a `tRNS` chunk
  (omitted when every pixel is opaque). More than 256 distinct colors is
  an error — switch to `rgba`.
- **rgba** (color type 6, bit depth 8): full alpha per pixel.

Encoder: PNG signature + IHDR + [PLTE + tRNS] + IDAT
(`zlib.deflateSync`, filter type 0 per scanline) + IEND, CRC32 per chunk
(Adler-32 lives inside the zlib stream). No timestamps anywhere.

## Determinism

Same declaration bytes → same PNG bytes, always: no clock, no randomness
(the engine's `H` hash is a pure integer hash), and object iteration that
affects output is sorted (see deviations). zlib output is deterministic
for a given node build — pinned by the node version below.

## Deviations from the upstream engine (`engine-v3.html`)

1. The browser-only canvas writer `render()` is replaced by the PNG
   encoder (Section 2).
2. `renderSprite` pass 2 (specular highlights) iterates material keys in
   **sorted** order; upstream iterates object insertion order. Only
   observable when two specular zones overlap; required so output bytes
   never depend on JSON key order. Marked `[SailAge]` in the code.
3. Upstream demo content — the demo `SPRITES` templates, demo palette
   `C`, demo scene builders, and the V2 comparison helpers — is not engine
   math and is not vendored; declarations carry their own grids/colors.
4. `background` fills fully-transparent pixels **after** the render; the
   upstream demos pre-fill the canvas before blitting (same visible
   result for a single sprite).
5. The string-map mode renders flat exact colors — the engine shading
   math applies to template mode only (string maps are chrome/arrows/
   marks, which want exact pinned hexes).

## Fixture checker

```
python3 tools/yoyopixel/fixture_check.py            # check (CI / gate)
python3 tools/yoyopixel/fixture_check.py --regen    # rewrite the fixtures
```

The checker renders the committed declarations under `fixtures/decls/`
**twice** into fresh temp directories with the pinned node, then verifies
(1) run 1 == run 2 byte-for-byte, (2) run 1 == the committed
`fixtures/expected/*.png` byte-for-byte, and (3) each output is a
structurally valid PNG (chunk walk, CRC32, IHDR fields, filter-0
scanlines, IDAT inflates exactly, ≤ 64×64). Exit 0 only when everything
matches. `--regen` re-renders the committed expected PNGs in place (run
the checker after regenerating). Any node/zlib/engine drift goes red.

The five committed fixtures cover the full matrix: string-map → indexed
(with explicit `"." : "transparent"` and width/height cross-check),
string-map → rgba (`.` default-transparent), template → rgba (glass
alpha 200 + specular + liquid/cork shaders), template → indexed
(metal/gold/gem/wood_dark shaders + `background`), template → indexed
with `tRNS` (glass alpha in indexed mode).
