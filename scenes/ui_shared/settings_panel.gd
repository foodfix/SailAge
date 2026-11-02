extends Control
## Settings panel (S19) — docs/80-UI-UX.md §4.6.3, §4.2, §4.3, §4.7.
##
## A **modal with two mounts** (docs/80-* §4.6.3 amended 2026-10-31): the
## S1 title screen (pre-game) and the S4 hub footer (mid-run, beside
## `Save · Set Sail · Fleet · Officers`, §4.6.2's entry-point rule). One
## panel, two hosts; `host_is_port()` picks the S4-only extras.
## Houses exactly the settings that belong here (docs/IMPLEMENT-Phase5.md
## task M; docs/IMPLEMENT-Phase6.md task V; §4.6.3 "Settings screen scope
## creep" mitigation):
##   * the **sea-traffic density dial** — `GameState.npc_preset`, applying
##     mid-run through `npc_fleets.gd`'s existing seams: raising makes the
##     daily trickle (`max(4, ceil(cap / 50))`, docs/60-* §4.1.2) refill
##     toward the new budgets over the next days; lowering **never culls**
##     living fleets (the trickle only spawns on a budget deficit);
##     `deserted` = zero NPC spawns and zero contacts;
##   * the **Phase-6 control-preference rows** (§4.6.3, task V) —
##     `输入模式 Input mode` writes `GameState.control_prefs.input_mode`
##     (step | helm, docs/20-* §4.2) and `洋流模式 Current mode` writes
##     `GameState.control_prefs.current_mode` (modifier | drift, docs/20-*
##     §4.16), both live, on BOTH mounts, persisted per save (v6
##     `control_prefs`) and carried by `new_game` like `npc_preset`;
##   * the **debug-overlays toggle** (§4.6.3, correction 12) — flips ONLY the
##     static [member debug_overlays] flag, which is **session-only**: it is
##     never saved, never read from a save, and resets to off when the app
##     restarts (a static starts fresh every run);
##   * the **locale toggle** — the ONLY language control in the game since
##     the 2026-10-31 amendment (§4.6.3): a `[中文 / EN]` button on both
##     mounts; the old `L` hotkey and the top-bar/market/S2 buttons are gone.
##
## How the mid-run application reaches the ecology: sims read
## `GameState.npc_preset` when they are constructed (the world scene builds
## one per scene entry, `world_map._init_fleets`), so writing the field here
## is the application; `NpcFleets.set_preset` additionally covers any host
## that keeps a live sim across the change. The preset is part of the save
## payload (v5 `npc_preset`), so the dial survives save/load. The control
## preferences apply the same way (G/H/I read
## `GameState.control_prefs` via the guard-call convention, correction 12)
## and persist through the v6 `control_prefs` block.
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

## The two persisted control-preference enums, in §4.6.3 wireframe order
## (docs/90-* §5.4; docs/20-* §4.2, §4.16). Pinned here exactly as
## `SaveSystem.INPUT_MODES` / `SaveSystem.CURRENT_MODES` pin them for save
## validation — the owning docs fix the values, never code taste.
const INPUT_MODES: Array[String] = ["step", "helm"]
const CURRENT_MODES: Array[String] = ["modifier", "drift"]
## The ui_strings key families of the two rows (§4.7.10): the row labels are
## `settings.input.mode` / `settings.current.mode`, the buttons compose
## `settings.input.<mode>` / `settings.current.<mode>`.
const INPUT_KEY := "settings.input"
const CURRENT_KEY := "settings.current"

## **Session-only debug-chart gate** (docs/80-* §4.6 symbol contract,
## IMPLEMENT-Phase6 correction 12/C): static, default false, NEVER persisted.
## Nothing may read it from a save and nothing may write it into one —
## `SaveSystem.snapshot()` writes only the §8.1 key list, and this flag is
## not part of `GameState` at all. It resets to off on every app restart
## because a static starts fresh with the process. The S19 row (below) is
## its only writer; I's debug chart reads it guard-style.
static var debug_overlays: bool = false

## Emitted after a preset was applied through [method apply_preset]
## (tests / hosts observe the dial without polling GameState).
signal preset_changed(preset: String)
## Emitted after [method apply_input_mode] / [method apply_current_mode]
## wrote a control preference: `(key, value)` with `key` ∈
## {`"input_mode"`, `"current_mode"`}.
signal control_prefs_changed(key: String, value: String)
## Emitted after [method apply_debug_overlays] flipped the session-only
## static (observers: tests; the debug chart polls the static directly).
signal debug_overlays_changed(on: bool)
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
## Control-preference id → its toggle Button (`input_mode` and
## `current_mode` ids in one map; the ids never collide across the rows).
var _mode_buttons: Dictionary = {}

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
@onready var _input_label: Label = $Center/Panel/Margin/Body/InputRow/InputLabel
@onready var _input_buttons: HBoxContainer = $Center/Panel/Margin/Body/InputRow/Buttons
@onready var _input_current: Label = $Center/Panel/Margin/Body/InputRow/InputCurrent
@onready var _current_mode_label: Label = $Center/Panel/Margin/Body/CurrentModeRow/CurrentModeLabel
@onready var _current_mode_buttons: HBoxContainer = $Center/Panel/Margin/Body/CurrentModeRow/Buttons
@onready var _current_mode_current: Label = $Center/Panel/Margin/Body/CurrentModeRow/CurrentModeCurrent
@onready var _debug_label: Label = $Center/Panel/Margin/Body/DebugRow/DebugLabel
@onready var _debug_button: Button = $Center/Panel/Margin/Body/DebugRow/DebugButton
@onready var _debug_hint: Label = $Center/Panel/Margin/Body/DebugRow/DebugHint
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
	_input_label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_input_current.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_current_mode_label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_current_mode_current.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_debug_label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_debug_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_locale_row.add_theme_color_override("font_color", PaletteLib.TEXT)
	_close_button.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_close_button.pressed.connect(close)
	_locale_button.pressed.connect(I18n.toggle_locale)
	_return_button.pressed.connect(_on_return_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_debug_button.toggle_mode = true
	_debug_button.pressed.connect(_on_debug_pressed)
	_return_row.visible = host_is_port()
	_save_row.visible = host_is_port()
	_build_presets()
	_build_mode_row(_input_buttons, INPUT_MODES, _on_input_mode_pressed)
	_build_mode_row(_current_mode_buttons, CURRENT_MODES,
		_on_current_mode_pressed)
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
	# §5.6 (added 2026-11-02): a live ecology sim (the FleetSim autoload)
	# re-budgets immediately; a sim built later reads the field anyway.
	FleetSim.apply_preset(preset)
	preset_changed.emit(preset)
	rebuild()
	return true


## True when `mode` is one of the pinned input-mode ids (`INPUT_MODES`).
func is_known_input_mode(mode: String) -> bool:
	return mode in INPUT_MODES


## True when `mode` is one of the pinned current-mode ids (`CURRENT_MODES`).
func is_known_current_mode(mode: String) -> bool:
	return mode in CURRENT_MODES


## The input-mode Button for `mode` (null when not rendered).
func input_mode_button(mode: String) -> Button:
	return _mode_buttons.get(INPUT_KEY + "." + mode, null) as Button


## The current-mode Button for `mode` (null when not rendered).
func current_mode_button(mode: String) -> Button:
	return _mode_buttons.get(CURRENT_KEY + "." + mode, null) as Button


## The debug-overlays toggle Button (§4.6.3).
func debug_overlays_button() -> Button:
	return _debug_button


## Applies the input-mode row (§4.6.3, task V): writes
## `GameState.control_prefs.input_mode` live — the field the world scene
## reads (guard-call convention, correction 12) and the v6 save persists —
## and refreshes the panel. Unknown ids are refused (the current mode
## stands). Returns true when applied. On the S1 mount this is the pre-game
## write that `new_game` carries into the run (like `npc_preset`).
func apply_input_mode(mode: String) -> bool:
	if not is_known_input_mode(mode):
		push_warning("SettingsPanel.apply_input_mode: unknown mode '%s'" % mode)
		return false
	GameState.control_prefs["input_mode"] = mode
	control_prefs_changed.emit("input_mode", mode)
	rebuild()
	return true


## Applies the current-mode row (§4.6.3, task V): writes
## `GameState.control_prefs.current_mode` live (modifier | drift,
## docs/20-* §4.16) and refreshes the panel. Unknown ids are refused.
## Returns true when applied.
func apply_current_mode(mode: String) -> bool:
	if not is_known_current_mode(mode):
		push_warning("SettingsPanel.apply_current_mode: unknown mode '%s'" % mode)
		return false
	GameState.control_prefs["current_mode"] = mode
	control_prefs_changed.emit("current_mode", mode)
	rebuild()
	return true


## Applies the debug-overlays row (§4.6.3, correction 12): flips ONLY the
## static [member debug_overlays] — session-only, never persisted, so there
## is deliberately no GameState write and no save-block counterpart.
func apply_debug_overlays(on: bool) -> void:
	debug_overlays = on
	debug_overlays_changed.emit(on)
	rebuild()


## Rebuilds every label from the merged `settings.*` keys (§4.7.9, §4.7.10)
## and the rows' selection state. Called on open and on `locale_changed`.
## Until the orchestrator merges the Phase-6 keys the new labels render as
## the literal `<key>` placeholders (§6) — tests must not assert their text.
func rebuild() -> void:
	_title.text = I18n.t_key("settings.title")
	_density_label.text = I18n.t_key("settings.density")
	_current.text = I18n.fmt("settings.density.current", {
		"preset": _preset_name(GameState.npc_preset),
	})
	_hint.text = I18n.t_key("settings.density.hint")
	_input_label.text = I18n.t_key(INPUT_KEY + ".mode")
	_current_mode_label.text = I18n.t_key(CURRENT_KEY + ".mode")
	_input_current.text = I18n.fmt(INPUT_KEY + ".current", {
		"mode": _mode_name(INPUT_KEY,
			str(GameState.control_prefs.get("input_mode", "step"))),
	})
	_current_mode_current.text = I18n.fmt(CURRENT_KEY + ".current", {
		"mode": _mode_name(CURRENT_KEY,
			str(GameState.control_prefs.get("current_mode", "modifier"))),
	})
	_debug_label.text = I18n.t_key("settings.debug.overlays")
	_debug_hint.text = I18n.t_key("settings.debug.session_hint")
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
	for mode_key in _mode_buttons:
		var mode_button: Button = _mode_buttons[mode_key]
		var key_text := str(mode_key)
		var family := key_text.get_slice(".", 0) + "." + key_text.get_slice(".", 1)
		var mode_id := key_text.get_slice(".", 2)
		mode_button.text = _mode_name(family, mode_id)
	mode_buttons_refresh_selection()
	_debug_button.text = I18n.t_key(
		"settings.debug.on" if debug_overlays else "settings.debug.off")
	_debug_button.button_pressed = debug_overlays


## Refreshes the two control-preference rows' pressed state from
## `GameState.control_prefs` (guard-read with the pinned defaults,
## correction 12).
func mode_buttons_refresh_selection() -> void:
	var input_mode := str(GameState.control_prefs.get("input_mode", "step"))
	var current_mode := str(GameState.control_prefs.get("current_mode",
		"modifier"))
	for mode in INPUT_MODES:
		var button := input_mode_button(mode)
		if button != null:
			button.button_pressed = mode == input_mode
	for mode in CURRENT_MODES:
		var button := current_mode_button(mode)
		if button != null:
			button.button_pressed = mode == current_mode


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


## The two control-preference rows, built in §4.6.3 wireframe order from the
## pinned id lists (`INPUT_MODES` / `CURRENT_MODES`) — the same toggle style
## as the preset row (128×40, selection refreshed by [method rebuild]).
func _build_mode_row(row: HBoxContainer, modes: Array[String],
		handler: Callable) -> void:
	var family := INPUT_KEY if row == _input_buttons else CURRENT_KEY
	for mode in modes:
		var button := Button.new()
		button.name = "Mode_%s_%s" % [family.get_slice(".", 1), mode]
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(128, PaletteLib.BUTTON_H)
		button.pressed.connect(handler.bind(str(mode)))
		row.add_child(button)
		_mode_buttons[family + "." + str(mode)] = button


func _on_input_mode_pressed(mode: String) -> void:
	apply_input_mode(mode)


func _on_current_mode_pressed(mode: String) -> void:
	apply_current_mode(mode)


## The debug row's only writer: the session-only static, nothing else
## (docs/80-* §4.6.3 "never persisted").
func _on_debug_pressed() -> void:
	apply_debug_overlays(not debug_overlays)


## Localised preset name (`settings.density.<preset>`; a missing key renders
## `<key>` per §6 rather than a raw id).
static func _preset_name(preset: String) -> String:
	return I18n.t_key("settings.density.%s" % preset)


## Localised mode name (`settings.input.<mode>` / `settings.current.<mode>`)
## for the rows' `当前 Current:` lines and buttons.
static func _mode_name(family: String, mode: String) -> String:
	return I18n.t_key("%s.%s" % [family, mode])


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
