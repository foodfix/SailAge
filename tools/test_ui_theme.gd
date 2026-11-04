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
