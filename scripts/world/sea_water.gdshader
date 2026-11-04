// Animated sea — docs/80-UI-UX.md §4.7.17 (Phase 10, W4-C; ledgered as the
// master adjudication of the shared water shader both S3 and S10 reuse).
//
// The water TileMapLayer's tiles are the two FLAT fills (`terrain_sea_0` /
// `terrain_coastal_sea_0`, §4.8.5 "water kinds are flat single-color fills —
// the animation is the shader's"). This canvas-item shader darkens the tile
// fill through a scrolling two-level dither mask (`sea_pattern.png`, 64×64,
// torus-safe) — render math only, never an asset color change:
//
//   * Scroll  — the mask UV advances with the built-in `TIME` (one full
//     64-px pattern wrap every `u_period` seconds, pinned 800 ms). The offset
//     lives ON THE GPU: no `_process`, no cell swapping, zero per-frame CPU
//     (§4.7.17 "Per-frame CPU: zero").
//   * Mask    — `u_mask`'s red channel is the two-level dither: level 1
//     darkens the base by `u_darken` (×0.70, §4.7.17 amended b674492),
//     level 0 keeps it.
//   * Gate    — `u_motion` is driven by `UiMotion.freeze_shader/run_shader`
//     (§4.7.17: motion off ⇒ frozen at scroll offset 0; the shader keeps its
//     own timebase, `UiMotion` never touches it).
//
// Coordinates: `VERTEX` is the fragment's position in the water layer's LOCAL
// space — tile pixels for a TileMapLayer whose cells sit at integer tile
// offsets. Chunks are 128 tiles = 4096 px = a whole multiple of the 64-px
// pattern, so the mask is seam-continuous across chunk borders and across the
// dateline (every chunk origin is a pattern multiple). The same property holds
// for the S10 battle water layer (its grid is 1536×960 px, also 64-aligned),
// which is why S10 can reuse this exact shader through `WaterLayer`.
shader_type canvas_item;

// The two-level torus-safe dither mask (`assets/ui/terrain/sea_pattern.png`).
uniform sampler2D u_mask : source_color, repeat_enable, filter_nearest;

// Scroll period in seconds (§4.7.17: 800 ms per full 64-px pattern wrap).
uniform float u_period = 0.8;
// Scroll direction in layer-local pixels per period, x axis (the doc pins the
// period, not a direction; +x is the neutral default — see `water_layer.gd`).
uniform vec2 u_scroll_dir = vec2(1.0, 0.0);
// Animated-sea gate: 1.0 scrolls, 0.0 freezes at scroll offset 0 (§4.7.17).
uniform float u_motion = 1.0;
// Darkening factor applied on the mask's dark level (§4.7.17 amended
// ×0.70, b674492 — render math, not an asset color).
uniform float u_darken = 0.70;
// The mask's tile size in layer-local pixels (the 64×64 pattern, §4.8.8).
uniform float u_mask_px = 64.0;

void fragment() {
	// GODOT 4 canvas_item semantics: COLOR at fragment entry ALREADY carries
	// the tile pixel (vertex color × TEXTURE) — verified by suite pin. The
	// 2026-11-04 production bug re-sampled TEXTURE here and multiplied again,
	// rendering the sea at SEA² with the mask pattern crushed into it (the
	// "uniform dark water" report). Apply ONLY the §4.7.17 two-level shade:
	// the mask's red channel picks the level, the scroll lives in the UV
	// offset, and COLOR's own rgb/a pass through.
	// TIME-based scroll, advanced entirely on the GPU: one full mask wrap
	// every u_period seconds along u_scroll_dir, frozen when u_motion is 0.
	float phase = TIME / max(u_period, 0.001);
	vec2 offset_px = u_motion * phase * u_scroll_dir * u_mask_px;
	vec2 mask_uv = (VERTEX + offset_px) / max(u_mask_px, 0.001);
	float level = texture(u_mask, mask_uv).r;
	COLOR.rgb *= mix(1.0, u_darken, step(0.5, level));
}
