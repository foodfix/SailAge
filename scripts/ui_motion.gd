class_name UiMotion
extends RefCounted
## The Phase-10 UI-motion gate (docs/80-UI-UX.md §4.7.17, §4.9).
##
## Every animation duration in the game is doc-pinned in §4.7.17 and passes
## through this static so "instant mode" is one switch: `enabled = false`
## makes `dur()` return 0.0 and every helper apply its end state immediately.
## Default is ON; headless suites set it OFF first (the direct-boot pattern).
## Motion is presentation-only — it never touches sim, logs or determinism;
## instant-mode battle logs stay byte-identical (§4.7.17).
##
## Helpers are deliberately minimal so W4 (HUD) and W5 (battle FX) reuse the
## same gate instead of re-deriving durations:
##   - `dur(ms)`        — the only way a call site reads a pinned duration.
##   - `fade(...)`      — opacity/modulate-only UI transitions (§4.7.17).
##   - freeze/run_shader — the animated-sea shader's `u_motion` flag
##     (§4.7.17: off ⇒ frozen at scroll offset 0; the shader keeps its own
##     `u_time`, untouched here).

## Master gate. `true` = durations run; `false` = instant (every duration 0).
static var enabled := true


## A pinned duration in seconds for a Tween/timer. `ms` values come from the
## §4.7.17 tables (toast fade-in 100 / fade-out 150, press flash 100,
## cannonball flight 300, ...). Off ⇒ 0.0 (instant).
static func dur(ms: int) -> float:
	if not enabled:
		return 0.0
	return ms / 1000.0


## Fade a CanvasItem's modulate:a from `from_a` to `to_a` over `ms`
## (§4.7.17 UI transitions are opacity/modulate only — never layout).
## Creates the tween on `node` (it must be inside the tree), sets the start
## alpha immediately and returns the Tween so callers may `await finished`.
## Motion off ⇒ the final alpha is set immediately and null is returned
## (callers must handle the null: there is nothing to await).
static func fade(node: CanvasItem, from_a: float, to_a: float,
		ms: int) -> Tween:
	node.modulate.a = from_a
	if not enabled:
		node.modulate.a = to_a
		return null
	var tw := node.create_tween()
	tw.tween_property(node, "modulate:a", to_a, dur(ms))
	return tw


## Animated-sea gate (§4.7.17): `u_motion` 0.0 freezes the scroll shader at
## offset 0. `u_time` stays untouched — the shader owns it.
static func freeze_shader(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("u_motion", 0.0)


## Animated-sea gate (§4.7.17): `u_motion` 1.0 lets the shader scroll.
static func run_shader(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("u_motion", 1.0)
