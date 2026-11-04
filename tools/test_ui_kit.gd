extends Node
## Phase-10 W2-C acceptance tests: the `UiKit` atoms, the `UiMotion` gate,
## the icon registry and one gallery headless boot
## (docs/80-UI-UX.md §4.9 atom contracts, §4.7.17 timings, §4.7 toast
## conventions, §4.6.1/§4.8 pinned threshold sets; IMPLEMENT-Phase10.md §5).
##
## Direct-boot pattern (§4.9: headless suites apply the theme themselves —
## this suite pins atom STRUCTURE, which is theme-independent, and leaves
## the themed look to the gallery boot probe):
##
##   godot --headless --path . res://tools/test_ui_kit.tscn
##
## UiMotion is DISABLED for suites (§4.7.17: default on, headless suites
## off) — set FIRST, before any atom is built, so every transition here is
## instant and no tween ever runs. Exits 0 when every check passes, 1
## otherwise.

const UiKitLib := preload("res://scripts/ui_kit.gd")
const UiMotionLib := preload("res://scripts/ui_motion.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const GalleryScene := preload("res://tools/widget_gallery.tscn")

var _failures: Array[String] = []
var _checks := 0
var _locale_before := "en"


func _ready() -> void:
	UiMotionLib.enabled = false  # suites run instant (§4.7.17) — FIRST
	_locale_before = I18n.get_locale()
	_test_motion_gate()
	_test_button_atom()
	_test_row_atom()
	_test_frame_atom()
	_test_footer_atom()
	_test_value_bar_atom()
	_test_auto_tier_pins()
	_test_field_row_i18n()
	_test_toast_atom()
	_test_icon_registry()
	await _test_gallery_boot()
	_report()


# --- Harness ----------------------------------------------------------------

var _holder: Control


func _holder_node() -> Control:
	if _holder == null:
		_holder = Control.new()
		add_child(_holder)
	return _holder


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


# --- §4.7.17 the motion gate -------------------------------------------------

func _test_motion_gate() -> void:
	# Off (the suite state): every duration is 0 and fade applies instantly.
	_check(UiMotionLib.dur(100) == 0.0,
		"UiMotion off: dur(100) == 0.0 (instant)")
	var node := Control.new()
	_holder_node().add_child(node)
	_check(UiMotionLib.fade(node, 0.0, 1.0, 100) == null
		and node.modulate.a == 1.0,
		"UiMotion off: fade sets the final alpha and returns null")
	# The one enabled-state observation (restored to off right after).
	UiMotionLib.enabled = true
	_check(UiMotionLib.dur(100) == 0.1,
		"UiMotion on: dur(100) == 0.1 (the §4.7.17 press-flash duration)")
	var fade_tw := UiMotionLib.fade(node, 0.0, 1.0, 100)
	_check(fade_tw != null,
		"UiMotion on: fade returns a tween for the caller to await")
	if fade_tw != null:
		fade_tw.kill()
	UiMotionLib.enabled = false
	# The animated-sea flag (§4.7.17: off freezes at offset 0; u_time is the
	# shader's own and stays untouched here).
	var mat := ShaderMaterial.new()
	UiMotionLib.freeze_shader(mat)
	_check(mat.get_shader_parameter("u_motion") == 0.0,
		"freeze_shader sets u_motion == 0.0")
	UiMotionLib.run_shader(mat)
	_check(mat.get_shader_parameter("u_motion") == 1.0,
		"run_shader sets u_motion == 1.0")


# --- §4.9 atom: button --------------------------------------------------------

func _test_button_atom() -> void:
	var plain := UiKitLib.button("ui.ok")
	_holder_node().add_child(plain)
	_check(plain.custom_minimum_size.y == PaletteLib.BUTTON_H,
		"button min height 40 (PaletteLib.BUTTON_H, got %f)"
		% plain.custom_minimum_size.y)
	_check(plain.theme_type_variation == "",
		"default kind carries no variation")
	_check(plain.text == str(DataLoader.ui_strings["ui.ok"][I18n.get_locale()]),
		"button text resolves through I18n.t_key")
	var kinds := {
		"primary": "Primary", "danger": "Danger", "quiet": "Quiet",
	}
	for kind in kinds:
		var btn := UiKitLib.button("ui.ok", kind)
		_holder_node().add_child(btn)
		_check(btn.theme_type_variation == kinds[kind],
			"kind '%s' maps to variation '%s' (got '%s')" % [kind,
			kinds[kind], btn.theme_type_variation])
	# An unregistered icon id ⇒ no icon, no crash (the flat fallback).
	var no_icon := UiKitLib.button("ui.ok", "default", "kit_absent_icon")
	_holder_node().add_child(no_icon)
	_check(no_icon.icon == null,
		"an unregistered icon id leaves the button iconless")
	# The §4.7.17 press flash in instant mode: set on down, restore on up.
	var flash := UiKitLib.button("ui.ok")
	_holder_node().add_child(flash)
	flash.button_down.emit()
	var tint := Color.WHITE.lerp(PaletteLib.ACCENT, 0.35)
	_check(flash.modulate.is_equal_approx(tint),
		"press flash (instant): modulate lifts toward the ACCENT tint")
	flash.button_up.emit()
	_check(flash.modulate.is_equal_approx(Color.WHITE),
		"button_up restores the identity modulate")


# --- §4.9 atom: row -----------------------------------------------------------

func _test_row_atom() -> void:
	var r := UiKitLib.row(3)
	_holder_node().add_child(r)
	_check(r.custom_minimum_size.y == PaletteLib.ROW_H,
		"row default height 32 (PaletteLib.ROW_H, got %f)"
		% r.custom_minimum_size.y)
	var cells: Array = r.get_meta(UiKitLib.META_CELLS)
	_check(cells.size() == 3, "row(3) exposes 3 cells via meta (got %d)"
		% cells.size())
	var expanding := true
	for cell in cells:
		var control := cell as Control
		if control == null or (control.size_flags_horizontal
				& Control.SIZE_EXPAND_FILL) == 0:
			expanding = false
	_check(expanding, "every cell is an expanding plain Control")


# --- §4.9 atom: frame ---------------------------------------------------------

func _test_frame_atom() -> void:
	var frame := UiKitLib.frame("ui.kit.gallery.title")
	_holder_node().add_child(frame)
	var vbox: VBoxContainer = frame.get_child(0)
	var header: Label = vbox.get_child(0)
	_check(header.text == str(
		DataLoader.ui_strings["ui.kit.gallery.title"][I18n.get_locale()]),
		"frame header resolves the title key")
	var margin: MarginContainer = vbox.get_child(1)
	var margins_ok := true
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		if margin.get_theme_constant(side) != PaletteLib.MARGIN:
			margins_ok = false
	_check(margins_ok, "frame body margins are 16 on all four sides")
	var body: VBoxContainer = frame.get_meta(UiKitLib.META_BODY)
	_check(body != null and body == margin.get_child(0),
		"meta[\"body\"] is the MarginContainer's inner VBox")


# --- §4.9 atom: footer --------------------------------------------------------

func _test_footer_atom() -> void:
	var buttons: Array = [UiKitLib.button("ui.no"), UiKitLib.button("ui.yes")]
	var f := UiKitLib.footer(buttons)
	_holder_node().add_child(f)
	_check(f.alignment == BoxContainer.ALIGNMENT_END, "footer aligns end")
	_check(f.get_theme_constant("separation") == UiKitLib.FOOTER_GAP,
		"footer separation 8 (got %d)" % f.get_theme_constant("separation"))
	_check(f.get_child_count() == 2, "footer appends the given buttons")


# --- §4.9 atom: value_bar -----------------------------------------------------

func _test_value_bar_atom() -> void:
	var tier_colors := {"good": PaletteLib.GOOD, "warn": PaletteLib.WARN,
		"bad": PaletteLib.BAD}
	for tier in tier_colors:
		var bar := UiKitLib.value_bar(50, 100, tier)
		_holder_node().add_child(bar)
		var fill: StyleBoxFlat = bar.get_theme_stylebox("fill")
		_check(fill.bg_color == tier_colors[tier],
			"tier '%s' fills with the matching palette color" % tier)
		if tier == "good":
			var bg: StyleBoxFlat = bar.get_theme_stylebox("background")
			_check(bg.bg_color == PaletteLib.PANEL_BG
				and bg.border_color == PaletteLib.PANEL_LINE,
				"the bar background is PANEL_BG + PANEL_LINE border")
			_check(bar.min_value == 0 and bar.max_value == 100
				and bar.value == 50, "min 0, the given max and value")
			_check(not bar.show_percentage, "show_percentage is off")
			_check(bar.custom_minimum_size.y == UiKitLib.BAR_H,
				"bar height 16 in its 32px row footprint (got %f)"
				% bar.custom_minimum_size.y)


# --- §4.6.1 / §4.8 pinned threshold sets through auto_tier -------------------

func _test_auto_tier_pins() -> void:
	# Supplies (§4.6.1): GOOD ≥ 10 days, WARN 3–9, BAD ≤ 2.
	var supply := [[10, "good"], [9, "warn"], [3, "warn"], [2, "bad"]]
	for case in supply:
		_check(UiKitLib.auto_tier(case[0], 10, 3) == case[1],
			"supply threshold set 10/3: %d days → %s" % [case[0], case[1]])
	# Morale (§4.8): yellow < 40, red < 20 → GOOD ≥ 40, WARN 20–39.
	var morale := [[40, "good"], [39, "warn"], [20, "warn"], [19, "bad"]]
	for case in morale:
		_check(UiKitLib.auto_tier(case[0], 40, 20) == case[1],
			"morale threshold set 40/20: %d → %s" % [case[0], case[1]])


# --- §4.9 atom: field_row + the zh/en resolution pin --------------------------

func _test_field_row_i18n() -> void:
	var key := "ui.kit.gallery.field_rows"
	I18n.set_locale("zh")
	var zh_row := UiKitLib.field_row(key, Control.new())
	_holder_node().add_child(zh_row)
	var zh_label: Label = zh_row.get_child(0)
	_check(zh_row.custom_minimum_size.y == PaletteLib.ROW_H,
		"field_row height 32")
	_check(zh_label.text == str(DataLoader.ui_strings[key]["zh"]),
		"field_row label resolves the zh text at locale zh")
	var control := zh_row.get_child(1) as Control
	_check(control != null and (control.size_flags_horizontal
		& Control.SIZE_EXPAND_FILL) != 0,
		"field_row control expands")
	I18n.set_locale("en")
	var en_row := UiKitLib.field_row(key, Control.new())
	_holder_node().add_child(en_row)
	var en_label: Label = en_row.get_child(0)
	_check(en_label.text == str(DataLoader.ui_strings[key]["en"]),
		"field_row label resolves the en text at locale en")
	_check(en_label.text != zh_label.text,
		"the rebuilt row tracks the locale switch (zh != en)")
	I18n.set_locale(_locale_before)


# --- §4.7/§4.7.17 atom: toast -------------------------------------------------

func _test_toast_atom() -> void:
	var host := Control.new()
	_holder_node().add_child(host)
	# Two calls, motion off: max 1 visible — the second frees the first NOW.
	var first := UiKitLib.toast(host, "first", 120)
	var second := UiKitLib.toast(host, "second", 120)
	_check(host.get_child_count() == 1,
		"two toast calls leave exactly one child on the host")
	_check(not is_instance_valid(first),
		"the replaced toast is freed immediately (max-1 rule)")
	_check(second == host.get_child(0),
		"the surviving child is the second toast")
	var label: Label = second.get_child(0)
	_check(label.text == "second", "the surviving toast carries its text")
	# The lifecycle: after the (instant) duration the toast is gone.
	await get_tree().create_timer(0.5).timeout
	await get_tree().process_frame
	_check(host.get_child_count() == 0,
		"the toast is freed after its duration")
	_check(not host.has_meta(UiKitLib.TOAST_META),
		"the host's live-toast meta is cleared")
	host.queue_free()


# --- §4.9 icon registry --------------------------------------------------------

func _test_icon_registry() -> void:
	_check(UiKitLib.icon_texture("kit_absent_icon") == null,
		"an unregistered id resolves to null (flat fallback)")
	_check(UiKitLib.icon_texture("") == null, "the empty id resolves to null")
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	UiKitLib.register_textures({"kit_test_icon": tex})
	_check(UiKitLib.icon_texture("kit_test_icon") == tex,
		"a registered id resolves to its texture")
	UiKitLib.clear_textures()
	_check(UiKitLib.icon_texture("kit_test_icon") == null,
		"clear_textures empties the registry")


# --- One gallery headless boot ------------------------------------------------

func _descendants(node: Node) -> Array:
	var out: Array = [node]
	for child in node.get_children():
		out.append_array(_descendants(child))
	return out


func _test_gallery_boot() -> void:
	# UiMotion stays off: the boot is fully instant (§4.7.17 suite rule).
	var gallery: Control = (GalleryScene as PackedScene).instantiate()
	add_child(gallery)
	await get_tree().process_frame
	await get_tree().process_frame
	var frames := 0
	for node in _descendants(gallery):
		if node is PanelContainer and node.has_meta(UiKitLib.META_BODY):
			frames += 1
	_check(frames >= 5,
		"the gallery renders %d atom frames (>= 5)" % frames)
	# The soft guard: theme applied exactly when ui_theme.gd exists (W2-B).
	if ResourceLoader.exists("res://scripts/ui_theme.gd"):
		_check(gallery.theme != null,
			"ui_theme.gd present: the gallery applied UiTheme")
	else:
		_check(gallery.theme == null,
			"ui_theme.gd absent: the gallery boots on defaults, error-free")
	gallery.queue_free()
	await get_tree().process_frame
