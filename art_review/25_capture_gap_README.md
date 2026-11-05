# 25 — capture gap: the user's real session vs the instanced-scene probe

Phase-10 acceptance round 2026-11-05. The user reported their real game's sea
looks different from the probe captures (world_map.tscn instanced directly,
1280×720 window). This round closes that gap with an in-game capture hotkey
(F10) and a controlled A/B at the exact same world cell and state.

## Artifacts

| file | what it is |
|---|---|
| `25_capture_gap_real.png` | REAL session frame: booted through the actual game flow (title → nationality → creation → port hub → provisioning auto-fill → set sail), sailed west of Lisbon to open water at cell `(2034, 615)`, captured with the new **F10** hotkey through the real input pipeline (16-frame burst) |
| `25_capture_gap_probe.png` | probe frame: `world_map.tscn` instanced directly (the master's probe path), matched to the real session's dumped state (cell, camera `(130208, 39392)`, zoom 1.0, day 2, clock, weather, heading, gold/morale/supplies), phase-burst 16 frames |
| `25_capture_gap_diff.png` | real \| probe \| \|diff\|×8 after the +19 px phase shift — black = identical |
| `25_capture_gap_battle.png` | battle evidence: the S21 sandbox → S10 battle screen, captured with the new battle **F10** through the real input pipeline (`battle_<ticks>.png`) |

## Method

Same cell/state by a state dump the real run wrote to `user://capture_state.json`
and the probe read back. The animated-sea shader (§4.7.17, `sea_water.gdshader`)
scrolls its dither mask 64 px per 800 ms of GPU `TIME`, and shader TIME is NOT
ticks-since-boot (per-process boot offset), so a single capture cannot be
phase-paired across processes — both sides captured 16-frame bursts (~2 s per
frame on this machine, sampling two phase families ~402 ms apart) and the
analysis searched the full 0–63 px period for the best alignment.

## Numbers

- **Per-tile mean RGB (8 deep-water cells around the fleet): identical,
  worst delta 0.0** — the base sea tones are bit-exact between the paths.
- **Deep-water patch residual (330,240)–(650,560), min over the 64 px period:
  real-vs-real at a different phase = 1.74 mean-abs luminance; real-vs-probe =
  1.95** — the cross-path floor is within ~12% of the same-path floor, i.e.
  no path-specific difference beyond phase quantization.
- **Raw (unaligned) A/B: 45–47% of sea pixels differ >8** — the same number a
  real-vs-real pair shows across a half-period (402 ms) phase step (45.4%).
  The animation phase alone produces "looks completely different" comparisons.
- **Screen shift at best alignment: 19 px ≈ 237 ms of the 800 ms scroll.**
- Zoom wide (§4.8 `Z`, 0.5×): the same patch collapses to scanline amplitude
  **6.5 → 0.1** and **260 → 2 unique colors** — at the wide level the sea
  visibly flattens. A probe at near vs a player at wide (or vice versa) reads
  as "different sea" by itself.
- Window 1920×1080 (stretch `canvas_items`, scale 1.5): same structure,
  resampled — 260 → ~500 unique colors in the patch, amplitude ~unchanged.
  A non-1280×720 desktop window (or HiDPI scaling) re-samples every texture.

## Root causes of the user-visible gap (ranked)

1. **Animated-sea phase (§4.7.17, by design).** Any two captures taken at
   different moments differ on up to ~45% of sea pixels (dither mask
   translated). The r5 commit made the motion visible on purpose.
2. **Probe bootstrap skipped the texture registry.**
   `TextureRegistry.ensure_registered()` is called only from
   `title_screen._ready()` (§4.9). The instanced-scene probe path never runs
   it, so `UiKit.icon_texture` misses: the player fleet token renders as the
   white fallback square instead of the 8-dir ship sprite (§4.8.9), and HUD
   icons fall back to glyphs. The probe for this round calls the same
   registration pass — its token then matches the real session's.
3. **Zoom level (`Z`, §4.8)** flattens the dither at wide 0.5 (numbers above).
4. **Window size / display scaling** — non-1280×720 windows re-sample
   everything through the `canvas_items` stretch (numbers above).
5. **Session-history sim state** (cannot be reproduced by a fresh probe):
   NPC fleet token placements (~330 px in 2–3 tile-sized clusters — the only
   >100-delta pixels after alignment), the "Destination reached" status toast,
   and the minimap fog revealed along the sailed path.

## Acceptance consequence

The user's real session is the only ground truth: use **F10 in-game**
(docs/80 §4.3 keybind rows; world `world_<ticks>.png`, battle
`battle_<ticks>.png` under `user://screenshots/`, path printed as
`CAPTURE saved: <abs path>`). Probe-side comparisons must (a) call
`TextureRegistry.ensure_registered()`, (b) match the dumped session state
including `world.heading`, and (c) compare sea regions only at the
best-fit scroll offset (0–63 px) — or accept that phase alone moves ~45% of
sea pixels.
