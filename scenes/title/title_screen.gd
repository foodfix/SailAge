extends Control
## Title screen (S1) — docs/80-UI-UX.md §4.1, §4.2, §4.6.
##
## T1 scaffold was brand title + phase tag only. T16/T17 add the `New game` /
## `Load game` rows, the locale toggle button and the data-error line. Colors
## and grid spacing come from Palette (docs/80-UI-UX.md §4.8) so the scene
## cannot drift from the locked values.
##
## **Load** (T17, docs/80-* §4.6): the button opens `SaveSystem`'s 3-slot dialog
## in Load mode; the load itself (validate → restore → route to S4 when the save
## was taken in port, else S3) is owned by `SaveSystem`, so this screen only
## asks. `F9` (quick-load slot 1) is handled globally by `SaveSystem` too.
##
## There is **no autosave** in Phase 1 (§4.6) — this screen never writes a save.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written Godot's global-class cache.

const PaletteLib := preload("res://scripts/palette.gd")
## Phase-10 shared theme (docs/80-UI-UX.md §4.9). Preloaded like PaletteLib so
## the scene also runs before Godot's global-class cache exists.
const UiThemeLib := preload("res://scripts/ui_theme.gd")
## Phase-10 W4-D texture registry (decision 10): the one-time `assets/ui/`
## bootstrap feeding `UiKit`'s id → texture map.
const TextureRegistryLib := preload("res://scripts/ui/texture_registry.gd")

const NATIONALITY_SCENE := "res://scenes/title/nationality_select.tscn"
## Phase-9 S21 edge (decision 15, `80-*` §4.7.16): the 海战 button sits
## between New Game and Load and routes to the zero-write sandbox editor.
const SANDBOX_SCENE := "res://scenes/combat/battle_sandbox.tscn"
## Phase-5 S19 settings modal, pre-game mount (docs/80-* §4.6.3 amended:
## density lives here, not on S2).
const SettingsPanelLib := preload("res://scenes/ui_shared/settings_panel.gd")

@onready var _background: ColorRect = $Background
@onready var _stack: VBoxContainer = $Center/Stack
@onready var _title: Label = $Center/Stack/GameTitle
@onready var _subtitle: Label = $Center/Stack/Subtitle
@onready var _phase_tag: Label = $Center/Stack/PhaseTag
@onready var _buttons: VBoxContainer = $Center/Stack/Buttons
@onready var _new_game_button: Button = $Center/Stack/Buttons/NewGame
@onready var _sandbox_button: Button = $Center/Stack/Buttons/Sandbox
@onready var _load_button: Button = $Center/Stack/Buttons/Load
@onready var _settings_button: Button = $Center/Stack/Buttons/Settings
@onready var _quit_button: Button = $Center/Stack/Buttons/Quit
@onready var _data_error: Label = $Center/Stack/DataError

## Routing switch for the New-game edge (the `GameState.new_game(route)` and
## `PortScreen.route_to_world` convention): with `false` the intent is still
## captured in [member last_route] but the scene does not swap.
var route_to_nationality: bool = true
## Same convention for the S21 sandbox edge (Phase 9).
var route_to_sandbox: bool = true
## Last path this screen asked to route to (tests read it).
var last_route: String = ""


func _ready() -> void:
	# Phase-10 §4.9 (docs/80-UI-UX.md): the shared theme applies ONCE at
	# startup to the root window and cascades to every control. Guarded —
	# headless direct-boot suites have no window and apply
	# `UiTheme.build_theme()` themselves (the documented direct-boot pattern).
	if get_window() != null:
		get_window().theme = UiThemeLib.build_theme()
	# Phase-10 W4-D (decision 10 / §4.9 icon params): right after the theme
	# application point, the texture registry populates UiKit's id → texture
	# map ONCE — icons, tokens, terrain/shore, FX and portrait sheets resolve
	# from here on (headless-safe: missing dirs/files skip silently).
	TextureRegistryLib.ensure_registered()
	_background.color = PaletteLib.PANEL_BG
	# §4.9 Label row: the secondary lines read through the theme's `Dim`
	# variation (PANEL_LINE) — no per-screen color overrides remain here.
	_subtitle.theme_type_variation = "Dim"
	_phase_tag.theme_type_variation = "Dim"

	_new_game_button.pressed.connect(open_new_game)
	_sandbox_button.pressed.connect(open_sandbox)
	_load_button.pressed.connect(open_load_dialog)
	_settings_button.pressed.connect(open_settings_panel)
	_quit_button.pressed.connect(_on_quit)
	EventBus.locale_changed.connect(_on_locale_changed)
	SettingsPanelLib.attach_to(self)
	_bind()


## Opens the New-game edge (S1 → S2, docs/80-* §4.2).
func open_new_game() -> bool:
	if not ResourceLoader.exists(NATIONALITY_SCENE):
		push_error("TitleScreen: %s is missing" % NATIONALITY_SCENE)
		return false
	last_route = NATIONALITY_SCENE
	if route_to_nationality:
		GameState.change_scene(NATIONALITY_SCENE)
	return true


## Opens the S21 naval-battle sandbox (S1 → S21, Phase 9 decision 15,
## docs/80-* §4.7.16 — the 海战 button between New Game and Load). Same
## guard/route convention as [method open_new_game].
func open_sandbox() -> bool:
	if not ResourceLoader.exists(SANDBOX_SCENE):
		push_error("TitleScreen: %s is missing" % SANDBOX_SCENE)
		return false
	last_route = SANDBOX_SCENE
	if route_to_sandbox:
		get_tree().change_scene_to_file(SANDBOX_SCENE)
	return true


## Opens the Load dialog (docs/80-* §4.6). Returns the dialog control (null when
## the scene is missing) so a test can drive it without a scene swap.
func open_load_dialog() -> Control:
	return SaveSystem.open_load_dialog(self)


## Opens the S19 settings modal (docs/80-* §4.6.3 amended): pre-game mount,
## where the sea-traffic dial lives now that S2 has no density row. Returns
## the panel (null only if the scene is missing) so tests can drive it.
func open_settings_panel() -> Control:
	var panel := get_node_or_null("SettingsPanel")
	if panel == null:
		panel = SettingsPanelLib.attach_to(self)
	if panel != null:
		(panel as Control).call("open")
	return panel


## The attached settings panel (tests / hosts), or null.
func settings_panel() -> Control:
	return get_node_or_null("SettingsPanel")


## True while a modal (the slot dialog / a message) is up (docs/90-* §11).
func has_modal() -> bool:
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			return true
	return false


func _bind() -> void:
	# `title.*` keys (docs/80-* §4.4); the title text itself is the brand name.
	_subtitle.text = I18n.t_key("title.subtitle")
	_new_game_button.text = I18n.t_key("title.new_game")
	# Phase-9 `sandbox.title` (the `10-*` §7.12 inventory — W2-B authors the
	# value): read defensively so this screen renders before the strings wave
	# merges, the `_reason_text` convention. No invented player-facing text.
	_sandbox_button.text = I18n.t_key("sandbox.title") \
		if DataLoader.ui_strings.has("sandbox.title") else "sandbox.title"
	_load_button.text = I18n.t_key("title.load_game")
	_settings_button.text = I18n.t_key("settings.title")
	_quit_button.text = I18n.t_key("title.quit")
	# docs/90-* §5.2/§11: invalid data at startup is shown here, never a crash.
	_data_error.visible = not DataLoader.load_ok
	_data_error.text = "" if DataLoader.load_ok else I18n.fmt(
		"title.data_error", {"reason": ", ".join(DataLoader.load_errors)}
	)
	# Load stays enabled even with no save file: docs/80-* §4.6 says the title
	# offers Load "always", and an all-empty dialog explains the situation
	# better than a dead button.
	_load_button.disabled = false


func _on_locale_changed(_locale: String) -> void:
	_bind()


func _on_quit() -> void:
	get_tree().quit()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
