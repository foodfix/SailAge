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

const NATIONALITY_SCENE := "res://scenes/title/nationality_select.tscn"

@onready var _background: ColorRect = $Background
@onready var _stack: VBoxContainer = $Center/Stack
@onready var _title: Label = $Center/Stack/GameTitle
@onready var _subtitle: Label = $Center/Stack/Subtitle
@onready var _phase_tag: Label = $Center/Stack/PhaseTag
@onready var _buttons: VBoxContainer = $Center/Stack/Buttons
@onready var _new_game_button: Button = $Center/Stack/Buttons/NewGame
@onready var _load_button: Button = $Center/Stack/Buttons/Load
@onready var _quit_button: Button = $Center/Stack/Buttons/Quit
@onready var _lang_button: Button = $Center/Stack/Buttons/Language
@onready var _data_error: Label = $Center/Stack/DataError

## Routing switch for the New-game edge (the `GameState.new_game(route)` and
## `PortScreen.route_to_world` convention): with `false` the intent is still
## captured in [member last_route] but the scene does not swap.
var route_to_nationality: bool = true
## Last path this screen asked to route to (tests read it).
var last_route: String = ""


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	_stack.add_theme_constant_override("separation", PaletteLib.MARGIN)
	_buttons.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_subtitle.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_phase_tag.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_data_error.add_theme_color_override("font_color", PaletteLib.BAD)
	for button in [_new_game_button, _load_button, _quit_button, _lang_button]:
		button.custom_minimum_size = Vector2(280, PaletteLib.BUTTON_H)

	_new_game_button.pressed.connect(open_new_game)
	_load_button.pressed.connect(open_load_dialog)
	_quit_button.pressed.connect(_on_quit)
	_lang_button.pressed.connect(I18n.toggle_locale)
	EventBus.locale_changed.connect(_on_locale_changed)
	_bind()


func _unhandled_input(event: InputEvent) -> void:
	# `L` toggles the locale on S1/S2 (docs/80-* §4.3); Esc is a no-op here.
	if event.is_action_pressed("toggle_locale"):
		if has_modal():
			return
		get_viewport().set_input_as_handled()
		I18n.toggle_locale()


## Opens the New-game edge (S1 → S2, docs/80-* §4.2).
func open_new_game() -> bool:
	if not ResourceLoader.exists(NATIONALITY_SCENE):
		push_error("TitleScreen: %s is missing" % NATIONALITY_SCENE)
		return false
	last_route = NATIONALITY_SCENE
	if route_to_nationality:
		GameState.change_scene(NATIONALITY_SCENE)
	return true


## Opens the Load dialog (docs/80-* §4.6). Returns the dialog control (null when
## the scene is missing) so a test can drive it without a scene swap.
func open_load_dialog() -> Control:
	return SaveSystem.open_load_dialog(self)


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
	_load_button.text = I18n.t_key("title.load_game")
	_quit_button.text = I18n.t_key("title.quit")
	_lang_button.text = I18n.t_key("ui.language_toggle")
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
