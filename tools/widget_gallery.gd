extends Control
## Phase-10 W2-C widget gallery — a headless-bootable live rendering of the
## `UiKit` atoms (docs/80-UI-UX.md §4.9; IMPLEMENT-Phase10.md decision 3,
## task C; motion per §4.7.17). Tool-owned scene beside the harness scenes
## (mirrors `battle_ai_harness.tscn`; recorded in the master ledger).
##
## Direct-boot pattern (the §4.9 rule: headless boots apply the theme
## themselves, no window root in a bare scene tree):
##
##   godot --headless --path . res://tools/widget_gallery.tscn
##
## The theme is applied SOFT-GUARDED: `ResourceLoader.exists()` first (an
## error-free absence probe — never a bare `load` of a missing script), then
## `load(...).call("build_theme")`. Until W2-B's `scripts/ui_theme.gd`
## lands, the gallery boots against Godot defaults; the master's merge of
## W2-B activates the themed look with zero changes here. `UiMotion` stays
## at its default (on) in real boots — the gallery demonstrates the pinned
## §4.7.17 timings; suites that boot this scene set `UiMotion.enabled =
## false` first (the §4.7.17 suite rule), which makes every transition
## instant. Re-renders on `EventBus.locale_changed` (§4.9: screens keep
## their locale_changed re-render pattern).

# Repo convention: class scripts are referenced through preload consts (the
# headless boot never depends on Godot's global class cache).
const UiKitLib := preload("res://scripts/ui_kit.gd")
const PaletteLib := preload("res://scripts/palette.gd")

## Soft-guard probe path for W2-B's theme (absent in the W2 worktrees).
const THEME_PATH := "res://scripts/ui_theme.gd"


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_apply_theme_if_present()
	EventBus.locale_changed.connect(_on_locale_changed)
	_rebuild()
	# A fired toast on boot (the §4.9 atom set includes the toast; §4.7:
	# transient, bottom-center, max 1 — a press replaces it).
	UiKitLib.toast(self, I18n.t_key("ui.kit.gallery.toast_shown"))


func _on_locale_changed(_locale: String) -> void:
	_rebuild()


## The §4.9 direct-boot theme application — error-free when
## `scripts/ui_theme.gd` is absent (W2-B owns that file).
func _apply_theme_if_present() -> void:
	if not ResourceLoader.exists(THEME_PATH):
		return
	var theme_script: Script = load(THEME_PATH)
	if theme_script == null:
		return
	var built: Theme = theme_script.call("build_theme")
	if built != null:
		theme = built


## Rebuild every section (locale switch + first paint share this path).
func _rebuild() -> void:
	for child in get_children():
		child.queue_free()
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, PaletteLib.MARGIN)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var top := VBoxContainer.new()
	margin.add_child(top)
	var header := Label.new()
	header.text = I18n.t_key("ui.kit.gallery.title")
	top.add_child(header)
	var status := Label.new()
	status.theme_type_variation = "Dim"
	status.text = I18n.t_key(_status_key())
	top.add_child(status)
	var grid := GridContainer.new()
	grid.columns = 2
	top.add_child(grid)
	grid.add_child(_buttons_frame())
	grid.add_child(_rows_frame())
	grid.add_child(_footer_frame())
	grid.add_child(_bars_frame())
	grid.add_child(_field_rows_frame())
	grid.add_child(_toast_frame())


## The theme status key reflects which branch of the soft guard ran.
func _status_key() -> String:
	if theme != null:
		return "ui.kit.gallery.theme_active"
	return "ui.kit.gallery.theme_missing"


func _gallery_frame(title_key: String) -> PanelContainer:
	var frame := UiKitLib.frame(title_key)
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.custom_minimum_size.y = 200
	return frame


## Default / primary / danger / quiet buttons with the §4.7.17 press flash.
func _buttons_frame() -> PanelContainer:
	var frame := _gallery_frame("ui.kit.gallery.buttons")
	var body: VBoxContainer = frame.get_meta(UiKitLib.META_BODY)
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	body.add_child(strip)
	strip.add_child(UiKitLib.button("ui.ok"))
	strip.add_child(UiKitLib.button("ui.confirm", "primary"))
	strip.add_child(UiKitLib.button("ui.cancel", "danger"))
	strip.add_child(UiKitLib.button("ui.back", "quiet"))
	return frame


## Rows of expanding cells (§4.9 `row`).
func _rows_frame() -> PanelContainer:
	var frame := _gallery_frame("ui.kit.gallery.rows")
	var body: VBoxContainer = frame.get_meta(UiKitLib.META_BODY)
	var two := UiKitLib.row(2)
	two.get_meta(UiKitLib.META_CELLS)[0].add_child(
		UiKitLib.value_bar(70, 100, "good"))
	two.get_meta(UiKitLib.META_CELLS)[1].add_child(
		UiKitLib.button("ui.close", "default"))
	body.add_child(two)
	body.add_child(UiKitLib.row(3))
	return frame


## Right-aligned footer (§4.9 `footer`).
func _footer_frame() -> PanelContainer:
	var frame := _gallery_frame("ui.kit.gallery.footer")
	var body: VBoxContainer = frame.get_meta(UiKitLib.META_BODY)
	body.add_child(UiKitLib.row(1))
	body.add_child(UiKitLib.footer([UiKitLib.button("ui.no", "quiet"),
		UiKitLib.button("ui.yes", "primary")]))
	return frame


## good / warn / bad bars (§4.9 `value_bar`; §4.8 palette tiers).
func _bars_frame() -> PanelContainer:
	var frame := _gallery_frame("ui.kit.gallery.value_bars")
	var body: VBoxContainer = frame.get_meta(UiKitLib.META_BODY)
	for pair in [[70, "good"], [40, "warn"], [15, "bad"]]:
		var one := UiKitLib.row(1)
		one.get_meta(UiKitLib.META_CELLS)[0].add_child(
			UiKitLib.value_bar(pair[0], 100, pair[1]))
		body.add_child(one)
	return frame


## Label + control rows (§4.9 `field_row`; example labels reuse existing
## ui.* keys — sweep slots never invent keys, §4.7.18).
func _field_rows_frame() -> PanelContainer:
	var frame := _gallery_frame("ui.kit.gallery.field_rows")
	var body: VBoxContainer = frame.get_meta(UiKitLib.META_BODY)
	body.add_child(UiKitLib.field_row("ui.speed.noun",
		UiKitLib.value_bar(40, 100, "warn")))
	var intel := Label.new()
	intel.text = I18n.t_key("ui.intel")
	body.add_child(UiKitLib.field_row("ui.intel", intel))
	return frame


## The kit toast atom, fired by button (§4.9 `toast`, §4.7 conventions).
func _toast_frame() -> PanelContainer:
	var frame := _gallery_frame("ui.kit.gallery.toast")
	var body: VBoxContainer = frame.get_meta(UiKitLib.META_BODY)
	var fire := UiKitLib.button("ui.kit.gallery.fire_toast", "primary")
	fire.pressed.connect(_fire_toast)
	body.add_child(fire)
	return frame


func _fire_toast() -> void:
	UiKitLib.toast(self, I18n.t_key("ui.kit.gallery.toast_shown"))
