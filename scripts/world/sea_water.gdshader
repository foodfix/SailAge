// Animated sea — docs/80-UI-UX.md §4.7.17 (Phase 10, W4-C).
//
// **DORMANT since 2026-11-07** (user direction "remove everything" + the
// fp16-varying report, 80-* §4.8): no water layer binds this shader anymore.
// `WaterLayer.build_layer` attaches no material; the world's deep-water
// darkening is the CPU-baked per-chunk multiply patch
// (`WaterLayer.build_depth_patch`), and the battle grid renders plain flat
// fills. The scroll/mask/crest program below is kept verbatim as dormant
// machinery (the foam-strip precedent) so the §4.7.17 pins and history stay
// reviewable.
//
// The water TileMapLayer's tiles are the two FLAT fills (`terrain_sea_0` /
// `terrain_coastal_sea_0`, §4.8.5 "water kinds are flat single-color fills —
// the animation is the shader's"). This canvas-item shader darkens the tile
// fill through a scrolling organic wave-crest mask (`sea_pattern.png`, 64×64,
// torus-safe) — render math only, never an asset color change:
//
//   * Scroll  — the mask UV advances with the built-in `TIME` (one full
//     128-px pattern wrap every `u_period` seconds, pinned 800 ms). The
//     offset lives ON THE GPU: no `_process`, no cell swapping, zero
//     per-frame CPU (§4.7.17 "Per-frame CPU: zero").
//   * Mask    — `u_mask`'s red channel is the §4.7.17 r5 (2026-11-05) organic
//     wave-crest field: level 1 darkens the base by `u_darken` (×0.70,
//     §4.7.17 amended b674492), level 0 keeps it.
//   * Gate    — `u_motion` is driven by `UiMotion.freeze_shader/run_shader`
//     (§4.7.17: motion off ⇒ frozen at scroll offset 0; the shader keeps its
//     own timebase, `UiMotion` never touches it).
//
// HISTORY (why this is dormant): the 2026-11-06 §4.8 pixel-depth amendment
// sampled `data/maps/dist_land.png` through this shader and produced the
// "dark plateaus + light rectangles" report — two independent defects, both
// measured by `tools/probe_water.gd`: (1) the FRAGMENT-stage `VERTEX` is
// screen space (camera-locked; the docs' "local space" applies to the
// VERTEX stage of plain 2D nodes), and (2) canvas varyings are stored at
// HALF precision — world-scale UVs quantize to fp16-ulp steps (~2 tiles on
// this raster) and TileMapLayer's vertex stage carries per-chunk offsets,
// so no varying-based coordinate could sample the raster at tile accuracy.
// The fix moved the sampling to the CPU (the patch); no shader coordinate
// math remains anywhere on a live water layer.
shader_type canvas_item;

// The two-level torus-safe dither mask (`assets/ui/terrain/sea_pattern.png`).
uniform sampler2D u_mask : source_color, repeat_enable, filter_nearest;

// Scroll period in seconds (§4.7.17: 800 ms per full pattern wrap).
uniform float u_period = 0.8;
// Scroll direction in layer-local pixels per period, x axis (the doc pins the
// period, not a direction; +x is the neutral default — see `water_layer.gd`).
uniform vec2 u_scroll_dir = vec2(1.0, 0.0);
// Animated-sea gate: 1.0 scrolls, 0.0 freezes at scroll offset 0 (§4.7.17).
uniform float u_motion = 1.0;
// Darkening factor applied on the mask's dark level (§4.7.17 amended
// ×0.70, b674492 — render math, not an asset color).
uniform float u_darken = 0.70;
// The mask's tile size in layer-local pixels (§4.8.8 64-canvas: 128).
uniform float u_mask_px = 128.0;
// §4.7.17 r5 crest accent: the FOAM tint (terrain block #dff0f4) and the
// partial mix (0.70 pinned here and in water_layer.gd's CREST_MIX — the
// two sites must not drift). DORMANT with the program since 2026-11-07
// (the runtime off switch is CREST_MIX == 0.0).
uniform vec3 u_crest_color = vec3(0.8745, 0.9412, 0.9569);
uniform float u_crest_mix = 0.70;

void fragment() {
	// GODOT 4 canvas_item semantics: COLOR at fragment entry ALREADY carries
	// the tile pixel (vertex color × TEXTURE). The 2026-11-04 production bug
	// re-sampled TEXTURE here and multiplied again, rendering the sea at
	// SEA² with the mask pattern crushed into it (the "uniform dark water"
	// report). Apply ONLY the mask shade: the mask's red channel picks the
	// level, the scroll lives in the UV offset, and COLOR's own rgb/a pass
	// through.
	float phase = TIME / max(u_period, 0.001);
	vec2 offset_px = u_motion * phase * u_scroll_dir * u_mask_px;
	vec2 mask_uv = (VERTEX + offset_px) / max(u_mask_px, 0.001);
	float level = texture(u_mask, mask_uv).r;
	float field = step(0.5, level);
	COLOR.rgb *= mix(1.0, u_darken, field);
}
