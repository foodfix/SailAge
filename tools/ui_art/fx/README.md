# tools/ui_art/fx — FX frame manifests (Phase-10 W3-D)

Battle-FX frame declarations for the presentation-only FX layer
(`docs/IMPLEMENT-Phase10.md` A.7, decision 8; sprite ids are the W1-pinned
contract in `docs/80-UI-UX.md` §4.8). The governor
(`tools/build_ui_art.py`, W3-B slot) renders these with the vendored
engine into `assets/ui/fx/<id>.png` at the wave gate — nothing under
`assets/` is committed from this slot.

## Inventory — 11 frames

| ids | size | colors | frames |
|---|---|---|---|
| `fx_cannonball` | 16×16 | `FX_BALL` + `FX_SMOKE_D` rim + `FX_SMOKE_L`/`FX_SMOKE` glint | 1 (tweened in-game; **all four shot types reuse**) |
| `fx_splash_0..3` | 32×32 | `FX_FOAM` + `FX_SPLASH_D` | 4 — burst → crown rising → crown peak → collapse |
| `fx_impact_0..2` | 32×32 | `FX_IMPACT_D` + `FX_FIRE` + `FX_SPARK` | 3 — burst → full bloom → embers over the residual scorch |
| `fx_smoke_0..2` | 16×16 | `FX_SMOKE` + `FX_SMOKE_L` + `FX_SMOKE_D` | 3 — small → full → dissipating |

Every hex used is from the `fx` block only (9 hexes, §4.8). Frames of one
family share the silhouette grammar and read as a sequence (grow, peak,
extinguish/dissipate).

## Anchoring conventions

- `fx_cannonball` is centered (tweened along the parabolic flight).
- `fx_splash_*` are bottom-anchored: waterline at y≈27 of 32 (mound base
  touches the frame bottom) — the sequencer pins the sprite to the
  impact water cell.
- `fx_impact_*` are bottom-anchored: groundline/scorch at y≈25–26 of 32.
- `fx_smoke_*` are bottom-anchored (puff rises from the muzzle/impact).

## Adjudications (ledger)

1. **String-maps with exact pixels, not engine templates.** The wave
   brief allowed `fire`-material templates "where it fits". Engine
   materials apply per-pixel hue-shift shading + ±2 noise
   (`renderSprite` pass 1), so a template-rendered frame's output hexes
   drift off the pinned `fx` block — group 13's per-sprite hexes ⊆
   class-block check could not be proven at the pixel level. All 11
   frames are therefore `mode: "string-map"` with exact pinned hexes
   (`png: "rgba"`), which satisfies block membership at BOTH the
   declaration and the decoded-pixel level. `tools/ui_art/portraits/
   compose_check.py` asserts the pixel-level purity.
2. **Binary alpha.** RGBA output with per-pixel alpha 0/255 (fully
   transparent background, opaque art pixels). Softness in-game comes
   from node `modulate` on the FX layer, not baked alpha.
3. **Instant mode renders frame 0** of each family (also noted in each
   declaration's `comment` field). Playback timings are the §4.7.17
   pins: splash 400 ms, impact 300 ms, smoke 500 ms (W5-A sequencer
   owns the loop; the declarations carry no timing).

## Editing

These declarations are the authored source (authored via an ASCII-tuned
one-off; the JSONs are the committed truth). Style fixes edit the
`rows`/palette here and rebuild — never a PNG under `assets/`.

Smoke render: `node tools/yoyopixel/render.js tools/ui_art/fx/*.json`
(run from a scratch CWD — `file` paths resolve against the process CWD).
