extends Control
## Game over (S9) — docs/80-UI-UX.md §4.1, §4.2; docs/20-* §4.9.
##
## A modal overlay shown **over S3** (the world map) when the sea kills the
## player: dimmed background, a 480px centred panel with `gameover.title`, the
## localised reason (`gameover.starvation|scurvy|sunk`) and the
## `gameover.return` hint. Any key (or a click) returns to the title screen
## (`80-*` §4.2 "S9 ──any key──► S1").
##
## * No save is written or deleted here (`20-*` §4.9) — this scene only routes.
## * Text re-binds on `EventBus.locale_changed` (§6 "toggle locale mid-dialog").
## * It also loads and runs standalone (no reason supplied): the reason row is
##   simply hidden, so the scene can be opened from the editor without a run.
##
## The world scene instantiates it as a child of a CanvasLayer above the HUD
## and calls [method open_reason]; nothing here reads `GameState.fleet` or any
## other run state beyond the router call.

const PaletteLib := preload("res://scripts/palette.gd")

const TITLE_SCENE := "res://scenes/title/title_screen.tscn"
## §4.7: modals dim the background by 40% black.
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"
## Game-over reasons this screen can render: the Phase-1 sea deaths
## (`20-*` §4.9) plus Phase-2's `captured` (`60-*` §4.6/§6 "the game-over
## reason set becomes {starvation, scurvy, sunk, captured}").
const REASONS: Array[String] = ["starvation", "scurvy", "sunk", "captured"]

## Emitted right before routing to the title (tests observe it instead of
## swapping scenes).
signal returning_to_title

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _reason: Label = $Center/Panel/Margin/Body/Reason
@onready var _hint: Button = $Center/Panel/Margin/Body/Footer/Return

## Game-over reason ("" while standalone / before [method open_reason]).
var reason: String = ""
## Routing switch for tests: the same idea as `GameState.new_game(..., route)`.
## A headless suite sets this false to assert the "any key" path without
## replacing its own scene root.
var route_to_title: bool = true
## Guards double routing (any key + button pressed together).
var _leaving := false


func _ready() -> void:
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_reason.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_title.add_theme_font_size_override("font_size", 48)
	_hint.custom_minimum_size.y = PaletteLib.BUTTON_H
	_hint.pressed.connect(func() -> void: return_to_title())
	EventBus.locale_changed.connect(_on_locale_changed)
	visible = true
	add_to_group(MODAL_GROUP)
	_bind()


func _unhandled_input(event: InputEvent) -> void:
	# "Any key" (`80-*` §4.2): the screen owns every event, so nothing
	# underneath (movement, HUD hotkeys) can act on a dead run.
	get_viewport().set_input_as_handled()
	var pressed := false
	if event is InputEventKey:
		pressed = (event as InputEventKey).pressed and not (event as InputEventKey).echo
	elif event is InputEventMouseButton:
		pressed = (event as InputEventMouseButton).pressed
	elif event is InputEventJoypadButton:
		pressed = (event as InputEventJoypadButton).pressed
	if pressed:
		return_to_title(route_to_title)


## Shows the screen for one of the §4.9 reasons. Unknown/empty reasons keep the
## reason row hidden rather than printing a `<key>` bug string.
func open_reason(game_over_reason: String) -> void:
	reason = game_over_reason
	_leaving = false
	visible = true
	add_to_group(MODAL_GROUP)
	_bind()
	_hint.grab_focus()


## Any key / the button: back to the title (S1). No save is touched.
##
## `route` exists for tests (the same convention as `GameState.new_game(...,
## route)`): with `false` the signal fires but the scene is not swapped, so a
## headless suite can assert the "any key" path without replacing itself.
func return_to_title(route: bool = true) -> void:
	if _leaving:
		return
	_leaving = true
	returning_to_title.emit()
	if route:
		GameState.change_scene(TITLE_SCENE)


func is_open() -> bool:
	return visible


## The reason text currently rendered (tests read this).
func reason_text() -> String:
	return _reason.text


func _bind() -> void:
	_title.text = I18n.t_key("gameover.title")
	_hint.text = I18n.t_key("gameover.return")
	# §6 "missing ui_strings key at runtime → renders the literal `<key>`" is
	# the bug path, so a reason whose `gameover.<reason>` string has not been
	# merged yet hides the row instead (the title and return hint still name
	# the screen). `captured` is pinned for Phase 2 (`60-*` §4.12.5) and turns
	# itself on the moment the key lands.
	_reason.visible = reason in REASONS \
		and DataLoader.ui_strings.has("gameover.%s" % reason)
	if _reason.visible:
		_reason.text = I18n.fmt(
			"gameover.reason", {"reason": I18n.t_key("gameover.%s" % reason)}
		)


func _on_locale_changed(_locale: String) -> void:
	_bind()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style
