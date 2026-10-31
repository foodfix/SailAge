extends Control
## Settings panel (S19) — docs/80-UI-UX.md §4.6.3, §4.2, §4.3, §4.7.
##
## A **modal with two mounts** (docs/80-* §4.6.3 amended 2026-10-31): the
## S1 title screen (pre-game) and the S4 hub footer (mid-run, beside
## `Save · Set Sail · Fleet · Officers`, §4.6.2's entry-point rule). One
## panel, two hosts; `host_is_port()` picks the S4-only extras.
## Houses exactly two things this phase (docs/IMPLEMENT-Phase5.md task M;
## §4.6.3 "Settings screen scope creep" mitigation):
##   * the **sea-traffic density dial** — `GameState.npc_preset`, applying
##     mid-run through `npc_fleets.gd`'s existing seams: raising makes the
##     daily trickle (`max(4, ceil(cap / 50))`, docs/60-* §4.1.2) refill
##     toward the new budgets over the next days; lowering **never culls**
##     living fleets (the trickle only spawns on a budget deficit);
##     `deserted` = zero NPC spawns and zero contacts;
##   * the **locale toggle** — the ONLY language control in the game since
##     the 2026-10-31 amendment (§4.6.3): a `[中文 / EN]` button on both
##     mounts; the old `L` hotkey and the top-bar/market/S2 buttons are gone.
##
## How the mid-run application reaches the ecology: sims read
## `GameState.npc_preset` when they are constructed (the world scene builds
## one per scene entry, `world_map._init_fleets`), so writing the field here
## is the application; `NpcFleets.set_preset` additionally covers any host
## that keeps a live sim across the change. The preset is part of the save
## payload (v5 `npc_preset`), so the dial survives save/load.
##
## The **S4 mount** additionally shows a confirm-first `Return to main menu`
## action (the confirmation names the lost-unsaved-progress risk; manual
## saves only, §4.7) that routes to S1 on accept. It is hidden on the S1
## mount (no run to leave).
##
## Esc / `Close` returns to the host (§4.2 edges); the panel consumes all
## input while open and dims the background 40% (modal rule, §4.7). All
## strings from the merged `settings.*` keys (§4.7.9). No textures; 32px
## rows, §4.8 palette only.
##
## Palette is preloaded rather than referenced through its global class name
## so the scene also runs before the editor has written Godot's class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const ConfirmScene := preload("res://scenes/ui_shared/confirm_dialog.tscn")

const SCENE_PATH := "res://scenes/ui_shared/settings_panel.tscn"
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"
## S1 (the pre-game host) — the return action routes back here.
const TITLE_SCENE := "res://scenes/title/title_screen.tscn"

## Emitted after a preset was applied through [method apply_preset]
## (tests / hosts observe the dial without polling GameState).
signal preset_changed(preset: String)
## Emitted when the panel closes back to its host.
signal closed
## Emitted when the S4-hosted `Return to main menu` action is confirmed.
signal return_to_menu

## The five density presets in `npc_config.json` order — deserted, low,
## normal, high, extreme (docs/10-* §4.10; data-driven, never a hardcoded
## list). Built in `_ready`.
var _preset_ids: Array[String] = []
## Preset id → its toggle Button, so selection styling refreshes cheaply.
var _preset_buttons: Dictionary = {}

## Routing switch (the other screens' `route_*` convention): with `false` the
## confirmed return still emits [signal return_to_menu] and closes, but does
## not swap scenes — headless tests drive the flow without a scene swap.
var route_to_menu: bool = true

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _density_label: Label = $Center/Panel/Margin/Body/Density/Label
@onready var _preset_row: HBoxContainer = $Center/Panel/Margin/Body/Density/Presets
@onready var _current: Label = $Center/Panel/Margin/Body/Density/Current
@onready var _hint: Label = $Center/Panel/Margin/Body/Density/Hint
@onready var _locale_row: Label = $Center/Panel/Margin/Body/LocaleRow/LocaleLabel
@onready var _locale_button: Button = $Center/Panel/Margin/Body/LocaleRow/LocaleButton
@onready var _close_button: Button = $Center/Panel/Margin/Body/Footer/Close
@onready var _save_row: HBoxContainer = $Center/Panel/Margin/Body/SaveRow
@onready var _save_button: Button = $Center/Panel/Margin/Body/SaveRow/SaveButton
@onready var _return_row: HBoxContainer = $Center/Panel/Margin/Body/ReturnRow
@onready var _return_button: Button = $Center/Panel/Margin/Body/ReturnRow/ReturnButton

## The S4-mounted return confirmation (`confirm_dialog.tscn`); created on
## first use and reused (the §4.7 destructive-action rule).
var _return_confirm: Control = null


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
	_close_button.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_close_button.pressed.connect(close)
	_locale_button.pressed.connect(I18n.toggle_locale)
	_return_button.pressed.connect(_on_return_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_return_row.visible = host_is_port()
	_save_row.visible = host_is_port()
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


## True when this panel is mounted on a port hub (S4) rather than the title
## screen (S1): the S4 mount is the only one with a run to leave, so it is
## the only one that shows `Return to main menu` (§4.6.3 amended).
func host_is_port() -> bool:
	var host := _resolve_host()
	if host == null:
		return false
	# The S1 host is the title screen (a Control whose scene path names it);
	# every other mount in the game hangs off S4 (port_screen / its layer).
	var scene_path := str(host.scene_file_path)
	return not scene_path.ends_with("title_screen.tscn")


## The locale toggle button (tests / hosts) — the only language control.
func locale_button() -> Button:
	return _locale_button


## The S4-mounted Save action button (tests / hosts), or null.
func save_button() -> Button:
	return _save_button


## Pressed `Save` (S4 mount): close the panel and open the 3-slot save dialog
## on the host — the exact flow the retired footer row drove (§4.7).
func _on_save_pressed() -> void:
	var host := _resolve_host()
	close()
	if host != null:
		SaveSystem.open_save_dialog(host)


## The node [method attach_to] mounted this panel under (the S1/S4 screen).
func _resolve_host() -> Node:
	var host := get_parent()
	while host != null and (host.name == "SettingsLayer"
			or host.name == "SettingsPanel"):
		host = host.get_parent()
	return host


## The S4-mounted return action button (tests / hosts), or null.
func return_button() -> Button:
	return _return_button


## Opens the confirm dialog for `Return to main menu` (created on first use).
## Returns the dialog so tests can drive `accept()` without a real click.
func open_return_confirm() -> Control:
	if _return_confirm == null:
		_return_confirm = ConfirmScene.instantiate()
		_return_confirm.name = "ReturnConfirm"
		add_child(_return_confirm)
		(_return_confirm as Control).connect("confirmed",
			_confirm_return_to_menu)
	var dialog := _return_confirm as Control
	dialog.call("open_text",
		I18n.t_key("settings.return_menu.confirm"),
		"settings.return_menu", "ui.cancel")
	return dialog


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
	_locale_row.text = I18n.t_key("settings.locale")
	_locale_button.text = I18n.t_key("ui.language_toggle")
	_close_button.text = I18n.t_key("settings.close")
	_return_button.text = I18n.t_key("settings.return_menu")
	_save_button.text = I18n.t_key("port.save")
	# docs/80-* §4.7: saving is offered only while docked — the panel shows
	# the action on the S4 mount and disables it when the precondition is off.
	_return_row.visible = host_is_port()
	_save_row.visible = host_is_port()
	_save_button.disabled = not SaveSystem.can_save_here()
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


func _on_locale_changed(_locale: String) -> void:
	if visible:
		rebuild()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)


# --- Return to main menu (S4 mount) -----------------------------------------

func _on_return_pressed() -> void:
	open_return_confirm()


## Confirmed → leave the run: close the panel, announce, route to S1. The
## game has manual saves only, so the confirmation already named the risk;
## nothing is written here (saving is the S4 Save row's job, §4.7).
func _confirm_return_to_menu() -> void:
	close()
	return_to_menu.emit()
	if route_to_menu:
		GameState.change_scene(TITLE_SCENE)


# --- Helpers ----------------------------------------------------------------

func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style
