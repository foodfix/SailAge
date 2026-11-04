class_name UiKit
extends RefCounted
## The Phase-10 shared widget kit — static factory, six atoms plus the toast
## atom and the icon registry (docs/80-UI-UX.md §4.9; decision 3,
## IMPLEMENT-Phase10.md; timings per §4.7.17, gated by `UiMotion`).
##
## Every atom returns a concrete `Control` node; there are no scene files.
## Labels resolve through `I18n.t_key` — screens pass keys, keep their
## `locale_changed` re-render pattern, and never store per-screen state in
## the kit. Styling lives here and in `ui_theme.gd` ONLY (the §4.9
## no-per-screen-styling allowlist): the atoms below build their
## per-instance StyleBoxFlats (value-bar tiers, the toast chrome) inline —
## everything else (buttons, panels, focus states) comes from the theme's
## variations once `ui_theme.gd` (`UiTheme.build_theme()`, W2-B) is applied.
## Icon params resolve through the texture registry (W3-A populates it);
## an absent id ⇒ null — the flat fallback, callers must handle it.

# --- Doc-pinned constants (docs/80-UI-UX.md §4.7, §4.7.17, §4.9) ------------

## Toast lifetime (§4.7: transient 2.5 s, bottom-center, max 1 visible).
const TOAST_MS := 2500
## Toast fade-in / fade-out (§4.7.17 — pinned once; the HUD funnel reads the
## same two constants, no site redefines its own).
const TOAST_FADE_IN_MS := 100
const TOAST_FADE_OUT_MS := 150
## Button press flash (§4.7.17).
const PRESS_FLASH_MS := 100
## Press-flash tint: white lifted 35% toward the ACCENT (§4.8 palette).
const FLASH_LERP := 0.35
## Value-bar height inside its 32px row footprint (test_ui_kit pin).
const BAR_H := 16
## Footer button separation (W2-C kit pin).
const FOOTER_GAP := 8
## Shared flat-chrome pins (§4.9 Panel/Tooltip rows: radius 4, 2px border,
## 8px pad) — used by the value-bar chrome and the toast chrome.
const CHROME_RADIUS := 4
const CHROME_BORDER := 2
const TOAST_PAD := 8
## Host meta key holding the live toast (the max-1-visible rule, §4.7).
const TOAST_META := "_kit_toast"
## Frame body accessor convention (W2-C decision): `frame.meta["body"]` is
## the body VBoxContainer — no extra getter, data-first.
const META_BODY := "body"
const META_CELLS := "cells"

## id → Texture2D, populated by `register_textures` (W3-A builds the sheet
## and registers its ids); `icon_texture` misses ⇒ null (flat fallback).
static var _textures: Dictionary = {}

# Repo convention: class scripts are referenced through preload consts (the
# headless suites/boot never depend on Godot's global class cache).
const PaletteLib := preload("res://scripts/palette.gd")
const MotionLib := preload("res://scripts/ui_motion.gd")
const UiThemeLib := preload("res://scripts/ui_theme.gd")

# --- §4.8 skin routing: chrome bands (amended 2026-11-05) ---------------------

## Band inner-edge selectors for [method route_band]: the edge that faces the
## content (a top bar's gold line sits at its bottom edge, a bottom bar's at
## its top edge).
const BAND_EDGE_TOP := 0
const BAND_EDGE_BOTTOM := 1

## Name prefix of the generated band-chrome strips (idempotent re-routing
## replaces exactly these children).
const SKIN_STRIP_PREFIX := "SkinStrip_"

# --- Atom: chrome band routing (§4.8 Skin coverage, amended 2026-11-05) ------

## Routes one chrome band — a HUD/chart/battle status-bar `ColorRect` —
## through the §4.8 band vocabulary **at bar scale**: a 32/40px bar cannot
## carry the 16px-margin nine-patch, so the band paints the sheet's frame
## language with 1px anchor-tracked ColorRect strips — `PANEL_WOOD` fill,
## `PANEL_WOOD_LO` dark outer edge, `PANEL_WOOD_HI` bevel line and an
## `ACCENT` gold hairline flush with the inner (content-side) edge. Strips
## anchor to the band's edges, so a window resize moves them with it; they
## ignore the mouse (the band keeps its own click-swallowing filter).
##
## Reduced-graphics fallback: the band keeps the pinned `PANEL_BG` navy fill
## and no strips — exactly the pre-sweep look (every flat-mode pin intact).
## Idempotent: a previously routed band's strips are replaced.
##
## `gold_edge` is [constant BAND_EDGE_TOP] or [constant BAND_EDGE_BOTTOM] —
## the band's content-facing edge.
static func route_band(bar: ColorRect, gold_edge: int) -> void:
	if bar == null:
		push_error("UiKit.route_band: null band")
		return
	_clear_skin_strips(bar)
	bar.color = UiThemeLib.surface_fill()
	if not UiThemeLib.texture_mode():
		return
	var outer_edge := BAND_EDGE_BOTTOM if gold_edge == BAND_EDGE_TOP \
		else BAND_EDGE_TOP
	_skin_strip(bar, "Outer", PaletteLib.PANEL_WOOD_LO, outer_edge, 0)
	_skin_strip(bar, "Bevel", PaletteLib.PANEL_WOOD_HI, gold_edge, 1)
	_skin_strip(bar, "Gold", PaletteLib.ACCENT, gold_edge, 0)


## Removes this kit's previously generated strips from `host` (idempotence).
static func _clear_skin_strips(host: Control) -> void:
	for child in host.get_children():
		if child is Control and str(child.name).begins_with(SKIN_STRIP_PREFIX):
			(child as Control).queue_free()


## One 1px chrome strip: full-width along `host`, anchored `depth` pixels
## inside `edge`. Left/right offsets track the host's width through the
## 0/1 anchors; the strip is a plain ColorRect (mouse IGNORE).
static func _skin_strip(host: Control, suffix: String, color: Color,
		edge: int, depth: int) -> void:
	var strip := ColorRect.new()
	strip.name = "%s%s" % [SKIN_STRIP_PREFIX, suffix]
	strip.color = color
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if edge == BAND_EDGE_BOTTOM:
		strip.anchor_left = 0.0
		strip.anchor_right = 1.0
		strip.anchor_top = 1.0
		strip.anchor_bottom = 1.0
		strip.offset_left = 0
		strip.offset_right = 0
		strip.offset_top = -1 - depth
		strip.offset_bottom = -depth
	else:
		strip.anchor_left = 0.0
		strip.anchor_right = 1.0
		strip.anchor_top = 0.0
		strip.anchor_bottom = 0.0
		strip.offset_left = 0
		strip.offset_right = 0
		strip.offset_top = depth
		strip.offset_bottom = depth + 1
	host.add_child(strip)
	# Content always draws over the chrome strips.
	host.move_child(strip, 0)


# --- Atom: button -----------------------------------------------------------

## `button(text_key, kind = "default", icon_id = "")` (§4.9 atom contract).
## `kind` ∈ default/primary/danger (also quiet) → the theme variations
## "Primary"/"Danger"/"Quiet"; default carries no variation. Min height 40
## (`PaletteLib.BUTTON_H`). Text = `I18n.t_key(text_key)`. Press flash 100 ms
## (§4.7.17): modulate lifts toward an ACCENT tint on `button_down` and
## restores on `button_up`/focus-out — instant when `UiMotion` is off.
## Unknown kind logs and falls back to default; absent icon id ⇒ no icon.
static func button(text_key: String, kind: String = "default",
		icon_id: String = "") -> Button:
	var btn := Button.new()
	btn.custom_minimum_size.y = PaletteLib.BUTTON_H
	btn.text = I18n.t_key(text_key)
	match kind:
		"primary":
			btn.theme_type_variation = "Primary"
		"danger":
			btn.theme_type_variation = "Danger"
		"quiet":
			btn.theme_type_variation = "Quiet"
		"default":
			pass
		_:
			push_error("UiKit.button: unknown kind '%s'" % kind)
	if icon_id != "":
		var tex := icon_texture(icon_id)
		if tex != null:
			btn.icon = tex
	btn.button_down.connect(_flash.bind(btn, _flash_tint()))
	btn.button_up.connect(_flash.bind(btn, Color.WHITE))
	btn.focus_exited.connect(_flash.bind(btn, Color.WHITE))
	return btn


## The §4.7.17 press flash: one tween per button (guarded via meta so a
## re-press kills the pending restore). Motion off ⇒ instant set.
static func _flash(btn: Button, to: Color) -> void:
	if btn.has_meta("_kit_flash"):
		var pending: Tween = btn.get_meta("_kit_flash")
		if pending != null and pending.is_valid():
			pending.kill()
	if not MotionLib.enabled:
		btn.modulate = to
		return
	var tw := btn.create_tween()
	tw.tween_property(btn, "modulate", to, MotionLib.dur(PRESS_FLASH_MS))
	btn.set_meta("_kit_flash", tw)


static func _flash_tint() -> Color:
	return Color.WHITE.lerp(PaletteLib.ACCENT, FLASH_LERP)


# --- Atom: frame ------------------------------------------------------------

## `frame(title_key)` (§4.9): titled PanelContainer — a header Label (the
## theme's default font; no bold in the locked font set) above a
## 16px-margin (`PaletteLib.MARGIN`) MarginContainer wrapping the body
## VBoxContainer. The body is reached via `frame.meta["body"]` (see
## META_BODY) — the kit's documented accessor convention.
static func frame(title_key: String) -> PanelContainer:
	var panel := PanelContainer.new()
	var vbox := VBoxContainer.new()
	panel.add_child(vbox)
	var header := Label.new()
	header.text = I18n.t_key(title_key)
	vbox.add_child(header)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, PaletteLib.MARGIN)
	vbox.add_child(margin)
	var body := VBoxContainer.new()
	margin.add_child(body)
	panel.set_meta(META_BODY, body)
	return panel


# --- Atom: row --------------------------------------------------------------

## `row(cols, height = PaletteLib.ROW_H)` (§4.9): a horizontal row of `cols`
## expanding cells (plain `Control`s, fill flags), row height `height`.
## Cells are exposed via `row.meta["cells"]` (see META_CELLS).
static func row(cols: int, height: int = PaletteLib.ROW_H) -> HBoxContainer:
	if cols < 1:
		push_error("UiKit.row: cols must be >= 1 (got %d)" % cols)
		cols = 1
	var hbox := HBoxContainer.new()
	hbox.custom_minimum_size.y = height
	var cells: Array = []
	for _i in cols:
		var cell := Control.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.size_flags_vertical = Control.SIZE_FILL
		hbox.add_child(cell)
		cells.append(cell)
	hbox.set_meta(META_CELLS, cells)
	return hbox


# --- Atom: footer -----------------------------------------------------------

## `footer(buttons)` (§4.9): a right-aligned button row, separation 8,
## appending the given buttons in order.
static func footer(buttons: Array) -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_END
	hbox.add_theme_constant_override("separation", FOOTER_GAP)
	for btn in buttons:
		var control := btn as Control
		if control == null:
			push_error("UiKit.footer: entries must be Controls")
			continue
		hbox.add_child(control)
	return hbox


# --- Atom: value_bar --------------------------------------------------------

## `value_bar(value, max_value, tier)` (§4.9): GOOD/WARN/BAD fill by tier,
## `PANEL_BG` background with a `PANEL_LINE` border (§4.9 Panel row: 2px,
## radius 4), min 0, no percentage, 16px tall in a 32px row footprint.
## Unknown tier logs and falls back to BAD (conservative).
static func value_bar(value: int, max_value: int, tier: String) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = max_value
	bar.value = value
	bar.show_percentage = false
	bar.custom_minimum_size.y = BAR_H
	var bg := StyleBoxFlat.new()
	bg.bg_color = PaletteLib.PANEL_BG
	bg.border_color = PaletteLib.PANEL_LINE
	bg.set_border_width_all(CHROME_BORDER)
	bg.set_corner_radius_all(CHROME_RADIUS)
	bar.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = _tier_color(tier)
	fill.set_corner_radius_all(CHROME_RADIUS - CHROME_BORDER)
	bar.add_theme_stylebox_override("fill", fill)
	return bar


## §4.9 tier→palette mapping. The DOC-pinned threshold sets live in the
## callers (supplies 10/3 per §4.6.1; morale 40/20 per §4.8) — this atom
## never hardcodes a threshold; callers compute the tier with `auto_tier`.
static func _tier_color(tier: String) -> Color:
	match tier:
		"good":
			return PaletteLib.GOOD
		"warn":
			return PaletteLib.WARN
		"bad":
			return PaletteLib.BAD
		_:
			push_error("UiKit.value_bar: unknown tier '%s'" % tier)
			return PaletteLib.BAD


## Tier thresholds (W2-C kit pin, threshold sets doc-owned by the callers):
## `value >= good_min` → "good", `>= warn_min` → "warn", else "bad".
static func auto_tier(value: int, good_min: int, warn_min: int) -> String:
	if value >= good_min:
		return "good"
	if value >= warn_min:
		return "warn"
	return "bad"


# --- Atom: field_row --------------------------------------------------------

## `field_row(label_key, control)` (§4.9): a label (`I18n.t_key`) plus the
## control (expanding) on one 32px (`PaletteLib.ROW_H`) row. Field labels read
## TEXT; secondary text uses the theme's `Dim` variation — set it on the
## control's own labels, not here.
static func field_row(label_key: String, control: Control) -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.custom_minimum_size.y = PaletteLib.ROW_H
	var label := Label.new()
	label.text = I18n.t_key(label_key)
	label.size_flags_vertical = Control.SIZE_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_FILL
	hbox.add_child(control)
	return hbox


# --- Atom: toast ------------------------------------------------------------

## `toast(host, text, duration_ms = TOAST_MS)` (§4.9/§4.7): the kit toast
## atom for private modal toasts — the HUD funnel keeps its own
## implementation and adopts these constants. Bottom-center PanelContainer
## (PANEL_BG + PANEL_LINE border, radius 4, 8px pad), Label in TEXT, at
## most ONE visible per host: a second call frees the first. Fade-in 100 ms
## on show, fade-out 150 ms before free (§4.7.17, via `UiMotion`) —
## instant when motion is off. Returns the panel.
static func toast(host: Control, text: String,
		duration_ms: int = TOAST_MS) -> Control:
	var previous: Control = null
	if host.has_meta(TOAST_META):
		previous = host.get_meta(TOAST_META) as Control
	if previous != null and is_instance_valid(previous):
		previous.free()  # max 1 visible: the new toast replaces the old now
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(CHROME_BORDER)
	style.set_corner_radius_all(CHROME_RADIUS)
	style.set_content_margin_all(TOAST_PAD)
	panel.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	panel.add_child(label)
	host.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM,
		Control.PRESET_MODE_MINSIZE, PaletteLib.MARGIN)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	host.set_meta(TOAST_META, panel)
	MotionLib.fade(panel, 0.0, 1.0, TOAST_FADE_IN_MS)
	_dismiss_toast(panel, host, duration_ms)
	return panel


## The 2.5s lifecycle (or the caller's duration): wait, fade out, free.
## Guards every access — the host or the toast may already be gone.
static func _dismiss_toast(panel: Control, host: Control,
		duration_ms: int) -> void:
	await panel.get_tree().create_timer(MotionLib.dur(duration_ms)).timeout
	if not is_instance_valid(panel) or not panel.is_inside_tree():
		return
	if is_instance_valid(host) and host.has_meta(TOAST_META) \
			and host.get_meta(TOAST_META) == panel:
		host.remove_meta(TOAST_META)
	var tw := MotionLib.fade(panel, 1.0, 0.0, TOAST_FADE_OUT_MS)
	if tw != null:
		await tw.finished
		if not is_instance_valid(panel):
			return
	panel.queue_free()


# --- Icon registry ----------------------------------------------------------

## Register id → Texture2D pairs (W3-A populates the sheet's ids).
## Re-registering an id overwrites it.
static func register_textures(map: Dictionary) -> void:
	for id in map:
		_textures[id] = map[id]


## Resolve an icon id (§4.9 icon params). Absent ⇒ null — the flat
## fallback; callers must handle null (no crash, no placeholder texture).
static func icon_texture(id: String) -> Texture2D:
	return _textures.get(id, null) as Texture2D


## Clear the registry (W3-A re-seeds wholesale; tests use it to restore).
static func clear_textures() -> void:
	_textures.clear()
