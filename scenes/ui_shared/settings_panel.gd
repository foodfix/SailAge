extends Control
## Settings panel (S19) — docs/80-UI-UX.md §4.6.3, §4.2, §4.3, §4.7.
##
## A **modal over S4**, opened from the S4 hub's footer `Settings` row
## (beside `Save · Set Sail · Fleet · Officers`, §4.6.2's entry-point rule).
## Houses exactly two things this phase (docs/IMPLEMENT-Phase5.md task M;
## §4.6.3 "Settings screen scope creep" mitigation):
##   * the **sea-traffic density dial** — `GameState.npc_preset`, applying
##     mid-run through `npc_fleets.gd`'s existing seams: raising makes the
##     daily trickle (`max(4, ceil(cap / 50))`, docs/60-* §4.1.2) refill
##     toward the new budgets over the next days; lowering **never culls**
##     living fleets (the trickle only spawns on a budget deficit);
##     `deserted` = zero NPC spawns and zero contacts;
##   * a **locale pointer line** — the language toggle stays where it is
##     (`L` on S1/S2 + the top-bar button, §4.3); S19 shows the current
##     locale and says so, no second toggle.
##
## How the mid-run application reaches the ecology: sims read
## `GameState.npc_preset` when they are constructed (the world scene builds
## one per scene entry, `world_map._init_fleets`), so writing the field here
## is the application; `NpcFleets.set_preset` additionally covers any host
## that keeps a live sim across the change. The preset is part of the save
## payload (v5 `npc_preset`), so the dial survives save/load.
##
## Esc / `Close` returns to S4 (§4.2 edge); the panel consumes all input
## while open and dims the background 40% (modal rule, §4.7). All strings
## from the merged `settings.*` keys (§4.7.9). No textures; 32px rows,
## §4.8 palette only.
##
## Palette is preloaded rather than referenced through its global class name
## so the scene also runs before the editor has written Godot's class cache.

const PaletteLib := preload("res://scripts/palette.gd")

const SCENE_PATH := "res://scenes/ui_shared/settings_panel.tscn"
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"

## Emitted after a preset was applied through [method apply_preset]
## (tests / hosts observe the dial without polling GameState).
signal preset_changed(preset: String)
## Emitted when the panel closes back to S4.
signal closed

## The five density presets in `npc_config.json` order — deserted, low,
## normal, high, extreme (docs/10-* §4.10; data-driven, never a hardcoded
## list). Built in `_ready`.
var _preset_ids: Array[String] = []
## Preset id → its toggle Button, so selection styling refreshes cheaply.
var _preset_buttons: Dictionary = {}

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _density_label: Label = $Center/Panel/Margin/Body/Density/Label
@onready var _preset_row: HBoxContainer = $Center/Panel/Margin/Body/Density/Presets
@onready var _current: Label = $Center/Panel/Margin/Body/Density/Current
@onready var _hint: Label = $Center/Panel/Margin/Body/Density/Hint
@onready var _locale_row: Label = $Center/Panel/Margin/Body/LocaleRow
@onready var _close_button: Button = $Center/Panel/Margin/Body/Footer/Close
@onready var _esc_hint: Label = $Center/Panel/Margin/Body/Footer/Hint


## Installs a panel under `parent` (idempotent) and returns it, following the
## [OfficersPanel]/[FleetPanel]/[CharacterPanel] convention (a `Control` host
## gets it directly, a `Node2D` host gets it inside a `CanvasLayer`).
static func attach_to(parent: Node) -> Control:
	var existing := _find_panel(parent)
	if existing != null:
		return existing
	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("SettingsPanel.attach_to: missing %s" % SCENE_PATH)
		return null
	var panel := scene.instantiate()
	panel.name = "SettingsPanel"
	if parent is Control:
		parent.add_child(panel)
	else:
		var layer := parent.get_node_or_null("SettingsLayer") as CanvasLayer
		if layer == null:
			layer = CanvasLayer.new()
			layer.name = "SettingsLayer"
			layer.layer = 100
			parent.add_child(layer)
		layer.add_child(panel)
	return panel


static func _find_panel(parent: Node) -> Control:
	var direct := parent.get_node_or_null("SettingsPanel")
	if direct is Control:
		return direct
	var layer := parent.get_node_or_null("SettingsLayer")
	if layer != null:
		var nested := layer.get_node_or_null("SettingsPanel")
		if nested is Control:
			return nested
	return null


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_title.add_theme_font_size_override("font_size", 32)
	_density_label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_current.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_locale_row.add_theme_color_override("font_color", PaletteLib.TEXT)
	_esc_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_close_button.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_close_button.pressed.connect(close)
	_build_presets()
	EventBus.locale_changed.connect(_on_locale_changed)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# §4.3 "S19 | Esc | close settings, back to S4 (same edge as Close)".
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		close()
		return
	# Modal behaviour (§4.7 / §6 "modals consume all input").
	get_viewport().set_input_as_handled()


# --- Public API ------------------------------------------------------------

func open() -> void:
	visible = true
	add_to_group(MODAL_GROUP)
	rebuild()
	_close_button.grab_focus()


func close() -> void:
	visible = false
	remove_from_group(MODAL_GROUP)
	closed.emit()


func is_open() -> bool:
	return visible


func has_modal() -> bool:
	return visible


## The preset ids on screen, in `npc_config.json` order (tests / hosts).
func preset_ids() -> Array[String]:
	return _preset_ids.duplicate()


## The preset Button for `preset` (null when not rendered).
func preset_button(preset: String) -> Button:
	return _preset_buttons.get(preset, null) as Button


## True when `preset` is one of `npc_config.json`'s presets — the only values
## [method apply_preset] accepts, so a stray id can never wedge the dial.
func is_known_preset(preset: String) -> bool:
	var presets = DataLoader.npc_config.get("presets", {})
	return presets is Dictionary and (presets as Dictionary).has(preset)


## Applies the density dial mid-run (§4.6.3, locked): writes
## `GameState.npc_preset` — the field sims read at construction and the save
## persists — and refreshes the panel. Unknown ids are refused (the current
## preset stands). Returns true when applied.
func apply_preset(preset: String) -> bool:
	if not is_known_preset(preset):
		push_warning("SettingsPanel.apply_preset: unknown preset '%s'" % preset)
		return false
	GameState.npc_preset = preset
	preset_changed.emit(preset)
	rebuild()
	return true


## Rebuilds every label from the merged `settings.*` keys (§4.7.9) and the
## preset row's selection state. Called on open and on `locale_changed`.
func rebuild() -> void:
	_title.text = I18n.t_key("settings.title")
	_density_label.text = I18n.t_key("settings.density")
	_current.text = I18n.fmt("settings.density.current", {
		"preset": _preset_name(GameState.npc_preset),
	})
	_hint.text = I18n.t_key("settings.density.hint")
	_locale_row.text = "%s · %s" % [
		_locale_name(I18n.get_locale()),
		I18n.t_key("settings.locale"),
	]
	_close_button.text = I18n.t_key("settings.close")
	_esc_hint.text = I18n.t_key("ui.esc_hint")
	for preset in _preset_buttons:
		var button: Button = _preset_buttons[preset]
		button.text = _preset_name(str(preset))
		button.button_pressed = str(preset) == GameState.npc_preset


## The preset row, data-driven from `npc_config.json` (`presets` preserves
## the JSON order: deserted, low, normal, high, extreme — the §4.6.3
## wireframe order). Falls back to the locked five should the data ever lack
## the block, so the panel can never render empty.
func _build_presets() -> void:
	_preset_ids = []
	var presets = DataLoader.npc_config.get("presets", {})
	if presets is Dictionary and not (presets as Dictionary).is_empty():
		for preset in presets:
			_preset_ids.append(str(preset))
	else:
		for preset in ["deserted", "low", "normal", "high", "extreme"]:
			_preset_ids.append(preset)
	for preset in _preset_ids:
		var button := Button.new()
		button.name = "Preset_%s" % preset
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(128, PaletteLib.BUTTON_H)
		button.pressed.connect(_on_preset_pressed.bind(str(preset)))
		_preset_row.add_child(button)
		_preset_buttons[str(preset)] = button


func _on_preset_pressed(preset: String) -> void:
	apply_preset(preset)


## Localised preset name (`settings.density.<preset>`; a missing key renders
## `<key>` per §6 rather than a raw id).
static func _preset_name(preset: String) -> String:
	return I18n.t_key("settings.density.%s" % preset)


## The locale's own name for the pointer row, split from the shared
## `ui.language_toggle` button text ("中文 / EN") — both locales carry the
## same string, so the split is stable and no new key is minted for it.
static func _locale_name(locale: String) -> String:
	var parts := I18n.t_key("ui.language_toggle").split(" / ")
	var index := 0 if locale == "zh" else mini(1, parts.size() - 1)
	return parts[index] if index < parts.size() else locale


func _on_locale_changed(_locale: String) -> void:
	if visible:
		rebuild()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)


# --- Helpers ----------------------------------------------------------------

func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style
