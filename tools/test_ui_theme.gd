extends Node
## Phase-10 W2-B acceptance tests: the shared theme — docs/80-UI-UX.md §4.9
## (pinned numbers, state matrix, variations), IMPLEMENT-Phase10.md §0
## decisions 1–2, §2 control coverage, §5 theme pins.
##
## **Direct-boot pattern** (docs/80-UI-UX.md §4.9 "Application point"): the
## theme normally applies once at startup to the root window
## (`title_screen._ready()`), but a headless run has no window — so this
## suite applies `UiTheme.build_theme()` itself on a host Control and reads
## themed values through it. Assertions are theme values only, never
## rendering.
##
## **Texture mode** (W3 layering; §4.9): a dedicated section builds
## `build_theme(true)` against the governor-assembled nine-patch sheets and
## pins the StyleBoxTexture config (48x48 region, 16px texture margins) plus
## pixel-exact sheet samples at the stylebox's corner/edge/center layout
## anchors — since the UW2 chrome reskin (§4.8 amended 2026-11-04) those are
## the wood/brass hexes: frame outline `PANEL_WOOD_LO` (+ bevel
## `PANEL_WOOD_HI`) at the corner frame and all four side centers, `PANEL_WOOD`
## center, the gold inner line `ACCENT` at its pinned inset (panel), the gold
## perimeter + `ACCENT_HI` rosette (button_focus), the `ACCENT_LO` recess lip
## (field), and transparent only at the authored outer rounding. It requires
## the committed sheets AND their import cache: run
## `godot --headless --import` once in a fresh worktree; when
## `assets/ui/chrome/ninepatch_button.png` is absent or unimported the
## section is skipped with an informational line (fresh checkouts keep the
## flat fallback).
##
##   godot --headless --path . res://tools/test_ui_theme.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const UiThemeLib := preload("res://scripts/ui_theme.gd")
const PaletteLib := preload("res://scripts/palette.gd")

var _failures: Array[String] = []
var _checks := 0
var _theme: Theme
var _host: Control


func _ready() -> void:
	# §4.9: the suite pins the flat fallback; texture variants are covered
	# by the W3 gate boot.
	_theme = UiThemeLib.build_theme(false)
	# Direct-boot: no window headless — the theme lives on a host control and
	# themed lookups run through it (§4.9 application point).
	_host = Control.new()
	_host.theme = _theme
	add_child(_host)
	_test_theme_built()
	_test_button_states()
	_test_button_variations()
	_test_scrollbars()
	_test_panels()
	_test_fields()
	_test_sliders()
	_test_tooltips()
	_test_labels()
	_test_scope_guard()
	_test_button_min_height()
	_test_texture_mode()
	_report()


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	get_tree().quit(1)


## A stylebox item set directly under `type` in the built theme (§4.9 pins).
func _stylebox(item: String, type: String) -> StyleBoxFlat:
	return _theme.get_stylebox(item, type) as StyleBoxFlat


# --- Decision 1: build_theme() is a Theme ------------------------------------

func _test_theme_built() -> void:
	_check(_theme != null and _theme is Theme,
		"build_theme() returns a Theme")


# --- §4.9 Button row + state matrix ------------------------------------------

func _test_button_states() -> void:
	var normal := _stylebox("normal", "Button")
	_check(normal != null, "Button normal stylebox exists")
	_check(normal.bg_color == PaletteLib.PANEL_BG,
		"Button normal bg == PANEL_BG")
	_check(normal.border_color == PaletteLib.PANEL_LINE,
		"Button normal border == PANEL_LINE")
	_check(normal.border_width_left == UiThemeLib.BORDER_W
		and normal.border_width_top == UiThemeLib.BORDER_W,
		"Button normal border width == %d (BORDER_W)" % UiThemeLib.BORDER_W)
	_check(normal.corner_radius_top_left == 0,
		"Button normal corner radius 0 (placeholder rule: square)")
	_check(normal.content_margin_left >= 8 and normal.content_margin_right >= 8,
		"Button content margins >= 8px horizontal")
	var hover := _stylebox("hover", "Button")
	_check(hover != null and hover.border_color == PaletteLib.ACCENT,
		"Button hover border == ACCENT")
	var pressed := _stylebox("pressed", "Button")
	_check(pressed != null and pressed.bg_color == PaletteLib.PANEL_LINE,
		"Button pressed bg == PANEL_LINE")
	_check(_theme.get_color("font_disabled_color", "Button")
		== PaletteLib.PANEL_LINE,
		"Button disabled font color == PANEL_LINE")
	_check(_theme.get_color("font_color", "Button") == PaletteLib.TEXT,
		"Button font color == TEXT")
	var focus := _stylebox("focus", "Button")
	_check(focus != null, "Button focus stylebox exists")
	_check(focus.border_color == PaletteLib.ACCENT,
		"Button focus ring == ACCENT")
	_check(focus.border_width_left == UiThemeLib.FOCUS_RING_W
		and focus.border_width_top == UiThemeLib.FOCUS_RING_W,
		"Button focus ring width == %d (FOCUS_RING_W)" % UiThemeLib.FOCUS_RING_W)
	_check(not focus.draw_center,
		"Button focus ring draws the border only (draw_center off)")
	_check(focus.expand_margin_left == UiThemeLib.FOCUS_RING_EXPAND
		and focus.expand_margin_top == UiThemeLib.FOCUS_RING_EXPAND,
		"Button focus ring expands %dpx (the extra ring)"
		% UiThemeLib.FOCUS_RING_EXPAND)


# --- §4.9 variations (Primary / Danger / Quiet on Button) ---------------------
#
# Variation items resolve through the base type at the CONTROL level, so the
# pins below read only items the theme sets directly under each variation.

func _test_button_variations() -> void:
	_check(_theme.get_type_variation_base("Primary") == "Button",
		"Primary is registered as a Button variation")
	_check(_theme.get_type_variation_base("Danger") == "Button",
		"Danger is registered as a Button variation")
	_check(_theme.get_type_variation_base("Quiet") == "Button",
		"Quiet is registered as a Button variation")
	var primary_hover := _stylebox("hover", "Primary")
	_check(primary_hover != null and primary_hover.border_color == PaletteLib.ACCENT,
		"Primary hover border == ACCENT (same as default)")
	var danger_normal := _stylebox("normal", "Danger")
	_check(danger_normal != null and danger_normal.border_color == PaletteLib.BAD,
		"Danger normal border == BAD")
	var danger_hover := _stylebox("hover", "Danger")
	_check(danger_hover != null and danger_hover.border_color == PaletteLib.BAD,
		"Danger hover border == BAD")
	var danger_pressed := _stylebox("pressed", "Danger")
	_check(danger_pressed != null and danger_pressed.bg_color == PaletteLib.PANEL_LINE,
		"Danger pressed bg == PANEL_LINE (matrix cell)")
	var danger_focus := _stylebox("focus", "Danger")
	_check(danger_focus != null and danger_focus.border_color == PaletteLib.BAD,
		"Danger focus ring == BAD (ring included)")
	var quiet_normal := _stylebox("normal", "Quiet")
	_check(quiet_normal != null and quiet_normal.bg_color == UiThemeLib.TRANSPARENT,
		"Quiet normal bg is transparent")
	_check(quiet_normal.border_width_left == 0,
		"Quiet normal carries no border")
	var quiet_hover := _stylebox("hover", "Quiet")
	_check(quiet_hover != null and quiet_hover.bg_color == UiThemeLib.TRANSPARENT
		and quiet_hover.border_color == PaletteLib.ACCENT,
		"Quiet hover: ACCENT border on transparent bg")


# --- §4.9 V/HScrollBar row -----------------------------------------------------

func _test_scrollbars() -> void:
	for type_name in ["VScrollBar", "HScrollBar"]:
		var vertical: bool = type_name == "VScrollBar"
		var trough := _stylebox("scroll", type_name)
		_check(trough != null and trough.bg_color == UiThemeLib.TRANSPARENT,
			"%s trough is transparent" % type_name)
		var grabber := _stylebox("grabber", type_name)
		_check(grabber != null and grabber.bg_color == PaletteLib.PANEL_LINE,
			"%s grabber == PANEL_LINE" % type_name)
		# The bar thickness + minimum grabber length ride the grabber stylebox
		# content margins (this release derives ScrollBar minimums from them).
		var across: float = grabber.content_margin_left + grabber.content_margin_right
		var along: float = grabber.content_margin_top + grabber.content_margin_bottom
		if vertical:
			_check(across == UiThemeLib.SCROLLBAR_W,
				"V grabber width == %d (got %s)" % [UiThemeLib.SCROLLBAR_W, across])
			_check(along == UiThemeLib.GRABBER_MIN,
				"V grabber min length == %d (got %s)" % [UiThemeLib.GRABBER_MIN, along])
		else:
			_check(along == UiThemeLib.SCROLLBAR_W,
				"H grabber height == %d (got %s)" % [UiThemeLib.SCROLLBAR_W, along])
			_check(across == UiThemeLib.GRABBER_MIN,
				"H grabber min length == %d (got %s)" % [UiThemeLib.GRABBER_MIN, across])
		for state in ["grabber_highlight", "grabber_pressed"]:
			var sb := _stylebox(state, type_name)
			_check(sb != null and sb.bg_color == PaletteLib.ACCENT,
				"%s %s == ACCENT" % [type_name, state])
	# Control-level observation (values, not rendering): the themed bar is 8px
	# across with the 24px minimum grabber.
	var vbar := VScrollBar.new()
	vbar.theme = _theme
	_host.add_child(vbar)
	_check(vbar.get_combined_minimum_size()
		== Vector2(UiThemeLib.SCROLLBAR_W, UiThemeLib.GRABBER_MIN),
		"VScrollBar measures %dx%d (got %s)" % [UiThemeLib.SCROLLBAR_W,
		UiThemeLib.GRABBER_MIN, vbar.get_combined_minimum_size()])
	var hbar := HScrollBar.new()
	hbar.theme = _theme
	_host.add_child(hbar)
	_check(hbar.get_combined_minimum_size()
		== Vector2(UiThemeLib.GRABBER_MIN, UiThemeLib.SCROLLBAR_W),
		"HScrollBar measures %dx%d (got %s)" % [UiThemeLib.GRABBER_MIN,
		UiThemeLib.SCROLLBAR_W, hbar.get_combined_minimum_size()])


# --- §4.9 Panel / PanelContainer row -------------------------------------------

func _test_panels() -> void:
	for type_name in ["Panel", "PanelContainer"]:
		var panel := _stylebox("panel", type_name)
		_check(panel != null, "%s panel stylebox exists" % type_name)
		_check(panel.bg_color == PaletteLib.PANEL_BG,
			"%s panel bg == PANEL_BG" % type_name)
		_check(panel.border_color == PaletteLib.PANEL_LINE,
			"%s panel border == PANEL_LINE" % type_name)
		_check(panel.corner_radius_top_left == UiThemeLib.RADIUS,
			"%s panel radius == %d" % [type_name, UiThemeLib.RADIUS])


# --- §4.9 LineEdit / TextEdit row ----------------------------------------------

func _test_fields() -> void:
	for type_name in ["LineEdit", "TextEdit"]:
		var normal := _stylebox("normal", type_name)
		_check(normal != null and normal.bg_color == PaletteLib.PANEL_BG,
			"%s normal bg == PANEL_BG" % type_name)
		_check(normal != null and normal.border_color == PaletteLib.PANEL_LINE,
			"%s normal border == PANEL_LINE" % type_name)
		var focus := _stylebox("focus", type_name)
		_check(focus != null and focus.border_color == PaletteLib.ACCENT,
			"%s focus border == ACCENT" % type_name)
		_check(_theme.get_color("font_color", type_name) == PaletteLib.TEXT,
			"%s font color == TEXT" % type_name)
		_check(_theme.get_color("caret_color", type_name) == PaletteLib.TEXT,
			"%s caret == TEXT" % type_name)


# --- §4.9 Slider row ------------------------------------------------------------

func _test_sliders() -> void:
	for type_name in ["HSlider", "VSlider"]:
		var groove := _stylebox("slider", type_name)
		_check(groove != null and groove.bg_color == PaletteLib.PANEL_LINE,
			"%s groove == PANEL_LINE" % type_name)
		var area := _stylebox("grabber_area", type_name)
		_check(area != null and area.bg_color == PaletteLib.ACCENT,
			"%s grabber_area == ACCENT" % type_name)
		var area_highlight := _stylebox("grabber_area_highlight", type_name)
		_check(area_highlight != null
			and area_highlight.bg_color == PaletteLib.ACCENT,
			"%s grabber_area_highlight == ACCENT" % type_name)


# --- §4.9 Tooltip row -----------------------------------------------------------

func _test_tooltips() -> void:
	var panel := _stylebox("panel", "TooltipPanel")
	_check(panel != null, "TooltipPanel panel stylebox exists")
	_check(panel.bg_color == PaletteLib.PANEL_BG,
		"TooltipPanel bg == PANEL_BG")
	_check(panel.corner_radius_top_left == UiThemeLib.RADIUS,
		"TooltipPanel radius == %d" % UiThemeLib.RADIUS)
	_check(panel.content_margin_left == UiThemeLib.TOOLTIP_PAD
		and panel.content_margin_top == UiThemeLib.TOOLTIP_PAD,
		"TooltipPanel content margin == %d" % UiThemeLib.TOOLTIP_PAD)
	_check(_theme.get_color("font_color", "TooltipLabel") == PaletteLib.TEXT,
		"TooltipLabel font color == TEXT")


# --- §4.9 Label row -------------------------------------------------------------

func _test_labels() -> void:
	_check(_theme.get_color("font_color", "Label") == PaletteLib.TEXT,
		"Label font color == TEXT")
	_check(_theme.get_type_variation_base("Dim") == "Label",
		"Dim is registered as a Label variation")
	_check(_theme.get_color("font_color", "Dim") == PaletteLib.PANEL_LINE,
		"Dim variation font color == PANEL_LINE")


# --- §4.9 no-over-styling guard --------------------------------------------------

func _test_scope_guard() -> void:
	# Nothing beyond §4.9's table is themed — unlisted classes keep the engine
	# defaults until the sweep needs them.
	for type_name in ["CheckBox", "ProgressBar", "TabContainer", "Tree"]:
		_check(_theme.get_stylebox_list(type_name).is_empty(),
			"%s keeps engine defaults (no theme items)" % type_name)


# --- §4.9 atom contract: button min height ---------------------------------------
#
# The 40px pin is carried by control floors (`custom_minimum_size.y`, set by
# scenes and the kit atom) — see ui_theme.gd `_button_box` for why the
# stylebox padding must not absorb the height in this Godot release.

func _test_button_min_height() -> void:
	_check(UiThemeLib.BUTTON_MIN_H == PaletteLib.BUTTON_H,
		"BUTTON_MIN_H == Palette.BUTTON_H == 40 (doc pin)")
	var button := Button.new()
	button.text = "New game"
	button.custom_minimum_size = Vector2(0, PaletteLib.BUTTON_H)
	_host.add_child(button)
	var min_size: Vector2 = button.get_combined_minimum_size()
	_check(min_size.y >= PaletteLib.BUTTON_H,
		"themed Button honors the %dpx floor (got %s)"
		% [PaletteLib.BUTTON_H, min_size.y])


# --- Texture mode: the nine-patch sheets (§4.9 W3 layering) --------------------
#
# Requires the committed sheets + their import cache (`godot --headless
# --import` once in a fresh worktree); skipped with an informational line
# when `assets/ui/chrome/ninepatch_button.png` is absent or unimported.
# The sheet pixels themselves are sampled at the stylebox's nine-patch
# layout anchors — these pins are LOAD-BEARING: the 04373ef sheets were
# assembled from un-oriented chrome tiles (TL corner / top edge blitted into
# every cell) and every themed Button rendered as scattered corner-bracket
# fragments; every trap below fails on such a misaligned sheet.

const SHEET_BUTTON_PATH := "res://assets/ui/chrome/ninepatch_button.png"

# UW2 chrome-skin sheet hexes (§4.8 amended 2026-11-04, palette constants):
# frame outline PANEL_WOOD_LO, bevel PANEL_WOOD_HI, walnut fill PANEL_WOOD,
# gold trim ACCENT (rosette center ACCENT_HI, rosette base ACCENT_LO); the
# field sheet is the recess — PANEL_WOOD_LO frame, ACCENT_LO lip, ICON_BG_LO
# interior. The flat fallback above keeps the navy pins — untouched.
# Stretch-safety (§4.8 amended 2026-11-04, master adjudication): the
# styleboxes STRETCH the center and edge spans, so fill/edge interiors are
# authored flat — grain lives only in the never-stretched corner tiles; the
# pins below therefore sample frame/trim/rosette anchors and the uniform
# fill, never interior grain.


func _test_texture_mode() -> void:
	var probe := load(SHEET_BUTTON_PATH) as Texture2D
	if probe == null:
		print("INFO  texture-mode section skipped: %s absent or unimported"
			% SHEET_BUTTON_PATH
			+ " — run `godot --headless --import` once in a fresh worktree")
		return
	var ttheme := UiThemeLib.build_theme(true)
	_texture_boxes(ttheme)
	var specs := _sheet_specs()
	for sheet_id: String in UiThemeLib.SHEET_PATHS:
		var tex := load(UiThemeLib.SHEET_PATHS[sheet_id]) as Texture2D
		if tex == null:
			_check(false, "texture mode: %s sheet loads (import cache present)"
				% sheet_id)
			continue
		_texture_sheet_pixels(tex, sheet_id, specs[sheet_id])


## Per-sheet anchor spec mirroring the governor's SKIN_PINS
## (tools/build_ui_art.py §4.8 amended): `outline` is the hex the frame's
## outermost px carries on all four sides, `bevel` the px just inside it,
## `fill` the sheet center, `gold` the per-sheet trim anchors [x, y, hex,
## label].
func _sheet_specs() -> Dictionary:
	return {
		"panel": {
			"outline": PaletteLib.PANEL_WOOD_LO,
			"bevel": PaletteLib.PANEL_WOOD_HI,
			"fill": PaletteLib.PANEL_WOOD,
			"gold": [
				[24, 3, PaletteLib.ACCENT, "gold inner line (inset 3px)"],
				[3, 3, PaletteLib.ACCENT_HI, "brass rosette center"],
				[2, 2, PaletteLib.ACCENT_LO, "brass rosette base"],
			],
		},
		"button": {
			"outline": PaletteLib.PANEL_WOOD_HI,
			"bevel": PaletteLib.PANEL_WOOD,
			"fill": PaletteLib.PANEL_WOOD,
			"gold": [
				[4, 15, PaletteLib.ACCENT, "corner-only gold inner tick"],
			],
		},
		"button_focus": {
			"outline": PaletteLib.ACCENT,
			"bevel": PaletteLib.PANEL_WOOD,
			"fill": PaletteLib.PANEL_WOOD,
			"gold": [
				[3, 3, PaletteLib.ACCENT_HI, "gold rosette center"],
				[4, 15, PaletteLib.ACCENT, "corner-only gold inner tick"],
			],
		},
		"field": {
			"outline": PaletteLib.PANEL_WOOD_LO,
			"bevel": PaletteLib.ACCENT_LO,
			"fill": PaletteLib.ICON_BG_LO,
			"gold": [],
		},
	}


## StyleBoxTexture config pins on the texture-mode theme.
func _texture_boxes(ttheme: Theme) -> void:
	var normal := ttheme.get_stylebox("normal", "Button") as StyleBoxTexture
	_check(normal != null, "texture mode: Button normal is a StyleBoxTexture")
	if normal == null:
		return
	var tex := normal.texture as Texture2D
	_check(tex != null and tex.get_width() == 48 and tex.get_height() == 48,
		"texture mode: Button sheet texture region is 48x48 (got %s)"
		% (tex.get_size() if tex != null else Vector2.ZERO))
	_check(normal.region_rect == Rect2(),
		"texture mode: Button region_rect default (full texture)")
	_check(normal.texture_margin_left == UiThemeLib.SHEET_MARGIN
		and normal.texture_margin_top == UiThemeLib.SHEET_MARGIN
		and normal.texture_margin_right == UiThemeLib.SHEET_MARGIN
		and normal.texture_margin_bottom == UiThemeLib.SHEET_MARGIN,
		"texture mode: Button texture margins == %d on all sides"
		% UiThemeLib.SHEET_MARGIN)
	_check(normal.content_margin_left == UiThemeLib.CONTENT_PAD,
		"texture mode: Button content margin == CONTENT_PAD (flat parity)")
	# §4.9 texture-mode state mapping (amended 2026-11-04): hover/pressed/
	# disabled resolve per sheet + modulate factor — see `_texture_states`.
	_texture_states(ttheme)
	var focus := ttheme.get_stylebox("focus", "Button") as StyleBoxTexture
	_check(focus != null and focus.texture != null,
		"texture mode: Button focus is the button_focus sheet box")
	var panel := ttheme.get_stylebox("panel", "Panel") as StyleBoxTexture
	_check(panel != null and panel.texture != null,
		"texture mode: Panel panel is a StyleBoxTexture")
	var panel_c := ttheme.get_stylebox("panel", "PanelContainer") as StyleBoxTexture
	_check(panel_c != null and panel_c == panel,
		"texture mode: PanelContainer shares the Panel sheet box")
	var field := ttheme.get_stylebox("normal", "LineEdit") as StyleBoxTexture
	_check(field != null and field.texture != null,
		"texture mode: LineEdit normal is the field sheet box")
	var field_te := ttheme.get_stylebox("normal", "TextEdit") as StyleBoxTexture
	_check(field_te != null and field_te.texture == field.texture,
		"texture mode: TextEdit samples the same field sheet")


## §4.9 texture-mode state mapping (amended 2026-11-04, user feedback: the
## first texture theme reused one sheet for normal/hover/pressed, leaving
## hover and toggle-selection invisible): normal = button sheet unmodulated;
## hover = focus sheet (ACCENT ring) ×1.0; momentary pressed = button sheet
## ×PRESS_MODULATE; disabled = button sheet ×DISABLED_MODULATE; keyboard
## focus = focus sheet; toggle-pressed (held/selected card) = focus sheet
## ×TOGGLE_MODULATE via the `Toggle` variation. Every state box carries the
## CONTENT_PAD margins so a state flip can never change measured sizes.
func _texture_states(ttheme: Theme) -> void:
	_check(UiThemeLib.PRESS_MODULATE == 0.82
		and UiThemeLib.TOGGLE_MODULATE == 0.88
		and UiThemeLib.DISABLED_MODULATE == 0.45,
		"texture mode: state modulate factors are the named constants "
		+ "(0.82 / 0.88 / 0.45)")
	var normal := ttheme.get_stylebox("normal", "Button") as StyleBoxTexture
	var hover := ttheme.get_stylebox("hover", "Button") as StyleBoxTexture
	var pressed := ttheme.get_stylebox("pressed", "Button") as StyleBoxTexture
	var disabled := ttheme.get_stylebox("disabled", "Button") as StyleBoxTexture
	var focus := ttheme.get_stylebox("focus", "Button") as StyleBoxTexture
	_check(normal != null and normal.modulate_color == Color(1, 1, 1, 1),
		"texture mode: Button normal stays unmodulated on the button sheet")
	_check(hover != null and hover.texture == focus.texture
		and hover.modulate_color == Color(1, 1, 1, 1),
		"texture mode: Button hover is the focus sheet (ACCENT ring) at ×1.0")
	_check(pressed != null and pressed.texture == normal.texture
		and pressed.modulate_color == Color(UiThemeLib.PRESS_MODULATE,
			UiThemeLib.PRESS_MODULATE, UiThemeLib.PRESS_MODULATE, 1.0),
		"texture mode: Button pressed is the button sheet ×PRESS_MODULATE")
	_check(disabled != null and disabled.texture == normal.texture
		and disabled.modulate_color == Color(UiThemeLib.DISABLED_MODULATE,
			UiThemeLib.DISABLED_MODULATE, UiThemeLib.DISABLED_MODULATE, 1.0),
		"texture mode: Button disabled is the button sheet ×DISABLED_MODULATE")
	_check(focus != null and focus.texture == hover.texture,
		"texture mode: Button keyboard focus is the focus sheet (as hover)")
	# Flat parity on every state box: a state flip must not change measured
	# margins (the pixel-stable steppers contract, test_creation).
	var margins_ok := true
	for state_box: StyleBoxTexture in [hover, pressed, disabled]:
		if state_box.content_margin_left != UiThemeLib.CONTENT_PAD \
				or state_box.content_margin_top != UiThemeLib.CONTENT_PAD:
			margins_ok = false
	_check(margins_ok,
		"texture mode: hover/pressed/disabled boxes keep the CONTENT_PAD "
		+ "margins (state flips are size-neutral)")
	# The `Toggle` variation (held/selected cards): pressed + hover_pressed =
	# focus sheet ×TOGGLE_MODULATE; everything else resolves through Button.
	_check(ttheme.get_type_variation_base("Toggle") == "Button",
		"texture mode: Toggle is registered as a Button variation")
	var t_pressed := ttheme.get_stylebox("pressed", "Toggle") as StyleBoxTexture
	var t_hover_pressed := ttheme.get_stylebox(
		"hover_pressed", "Toggle") as StyleBoxTexture
	_check(t_pressed != null and t_pressed.texture == focus.texture
		and t_pressed.modulate_color == Color(UiThemeLib.TOGGLE_MODULATE,
			UiThemeLib.TOGGLE_MODULATE, UiThemeLib.TOGGLE_MODULATE, 1.0),
		"texture mode: Toggle pressed is the focus sheet ×TOGGLE_MODULATE "
		+ "(distinct from hover ×1.0 and press ×0.82)")
	_check(t_hover_pressed != null
		and t_hover_pressed.modulate_color == t_pressed.modulate_color,
		"texture mode: a selected card under the mouse keeps the toggle dim")
	# Control-level resolution (the direct-boot pattern): real buttons report
	# the state boxes the theme would draw — a plain Button the momentary
	# press, a toggle card the selected ring, and the shared slots through
	# the variation base.
	var plain := Button.new()
	plain.text = "plain"
	plain.theme = ttheme
	_host.add_child(plain)
	var card := Button.new()
	card.text = "card"
	card.toggle_mode = true
	card.theme_type_variation = "Toggle"
	card.theme = ttheme
	_host.add_child(card)
	_check(plain.get_theme_stylebox("pressed") == pressed,
		"texture mode: a plain Button resolves the momentary press box")
	_check(card.get_theme_stylebox("pressed") == t_pressed,
		"texture mode: a toggle card resolves the selected-card ring box")
	_check(card.get_theme_stylebox("normal") == normal
		and card.get_theme_stylebox("disabled") == disabled
		and card.get_theme_stylebox("hover") == hover,
		"texture mode: Toggle resolves normal/hover/disabled through Button")
	# Minimum size is state-independent (disabled box margins == normal's).
	var plain_min: Vector2 = plain.get_combined_minimum_size()
	plain.disabled = true
	_check(plain.get_combined_minimum_size() == plain_min,
		"texture mode: a Button's minimum size is state-independent "
		+ "(%s under disable)" % str(plain_min))


## Pixel-exact sheet samples at the nine-patch layout anchors. `spec` carries
## the sheet family's UW2 chrome-skin hexes (§4.8 amended 2026-11-04): the
## frame outline the outermost px carries on all four sides, the bevel/lip
## line just inside it, the center fill, and the per-sheet gold trim anchors.
func _texture_sheet_pixels(tex: Texture2D, sheet_id: String,
		spec: Dictionary) -> void:
	var img := tex.get_image()
	_check(img != null and img.get_width() == 48 and img.get_height() == 48,
		"texture mode: %s sheet image is 48x48" % sheet_id)
	if img == null:
		return
	var outline: Color = spec["outline"]
	var bevel: Color = spec["bevel"]
	var fill: Color = spec["fill"]
	_check(_px_is(img, 4, 0, outline) and _px_is(img, 0, 4, outline),
		"texture mode: %s corner frame == outline hex (past the authored outer rounding)"
		% sheet_id)
	_check(_px_is(img, 24, 24, fill),
		"texture mode: %s sheet center == fill" % sheet_id)
	# Side orientations — the load-bearing traps: every side must carry the
	# frame on its OUTER px (a sheet blitted from un-oriented tiles puts
	# fill there and the frame mid-strip instead).
	_check(_px_is(img, 24, 0, outline) and _px_is(img, 0, 24, outline)
		and _px_is(img, 47, 24, outline) and _px_is(img, 24, 47, outline),
		"texture mode: %s all four side centers == outline on the outer px (oriented)"
		% sheet_id)
	# The px just inside the frame: the bevel/lip line on all four sides (the
	# mirrored assembly keeps it symmetric around the sheet).
	_check(_px_is(img, 24, 1, bevel) and _px_is(img, 1, 24, bevel)
		and _px_is(img, 46, 24, bevel) and _px_is(img, 24, 46, bevel),
		"texture mode: %s px inside the frame == the bevel/lip line (authored design)"
		% sheet_id)
	# Per-sheet UW2 trim anchors: the gold inner line at its pinned inset,
	# the corner rosettes, the button corner ticks.
	for anchor: Array in spec["gold"]:
		_check(_px_is(img, anchor[0], anchor[1], anchor[2]),
			"texture mode: %s %s == gold trim anchor" % [sheet_id, anchor[3]])
	# Transparency ONLY at the authored outer corner rounding (the source
	# corner tiles' own transparent pixels) — content areas opaque.
	_check(img.get_pixel(0, 0).a < 0.01 and img.get_pixel(47, 0).a < 0.01
		and img.get_pixel(0, 47).a < 0.01 and img.get_pixel(47, 47).a < 0.01,
		"texture mode: %s transparent only at the authored outer rounding"
		% sheet_id)
	_check(_px_is(img, 8, 24, fill)
		and _px_is(img, 24, 8, fill),
		"texture mode: %s content areas opaque fill (no frame bleed)"
		% sheet_id)


## Exact 8-bit pixel compare (the sheets import lossless: compress/mode=0).
func _px_is(img: Image, x: int, y: int, want: Color) -> bool:
	return img.get_pixel(x, y).is_equal_approx(want)
