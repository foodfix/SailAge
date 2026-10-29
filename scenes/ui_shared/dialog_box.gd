extends Control
## Modal message dialog — "message + OK" (docs/80-UI-UX.md §4.7);
## instanced as a modal child of the current screen (docs/90-* §7).
##
## * Dims the background by 40% black, centered, 480px wide (§4.8), text wraps,
##   grows to max 400px tall then scrolls (§4.7, §6).
## * Fully modal: it consumes every input event while open, so `Esc` closes it
##   and nothing underneath reacts (§6 "modals consume all input").
## * Results leave through [signal closed] — never a callback into another
##   scene (docs/90-* §7).
## * Re-binds its text on `EventBus.locale_changed` (§6).
##
## Text sources: [method open_key] (a `ui_strings.json` key + `{name}` values)
## or [method open_text] (already-formatted text, e.g. a composed summary).

const PaletteLib := preload("res://scripts/palette.gd")

## Emitted when the dialog closes (OK button or Esc/Enter).
signal closed

const DIM_ALPHA := 0.4
## Group every open modal joins, so hosts can test "is a modal up?" without
## knowing which dialog type it is (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"
## §4.7/§6: the body grows to 400px, then scrolls.
const MAX_BODY_H := 400

## `{key: String, values: Dictionary}`, or `{text: String}`. Kept so a locale
## change can rebuild exactly the same message.
var _source: Dictionary = {}

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _body_scroll: ScrollContainer = $Center/Panel/Margin/Body/Scroll
@onready var _message: Label = $Center/Panel/Margin/Body/Scroll/Message
@onready var _ok_button: Button = $Center/Panel/Margin/Body/Footer/OK


func _ready() -> void:
	# Stay hidden until one of the open_* calls supplies content; a dialog on
	# screen with no message would be a bug, so the constructor paths are the
	# only way in.
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_message.add_theme_color_override("font_color", PaletteLib.TEXT)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Wrapping needs a fixed text width; the panel is 480px with 16px margins.
	_message.custom_minimum_size.x = float(PaletteLib.DIALOG_W - 2 * PaletteLib.MARGIN)
	_body_scroll.custom_minimum_size = Vector2(PaletteLib.DIALOG_W - 2 * PaletteLib.MARGIN, 0)
	_body_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_ok_button.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_ok_button.pressed.connect(close)
	EventBus.locale_changed.connect(_on_locale_changed)
	if _source.is_empty() and visible:
		push_warning("DialogBox: shown without content; call open_key()/open_text()")


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# Modal: swallow everything. Enter/Space/Esc/OK all dismiss a message.
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		close()
		return
	get_viewport().set_input_as_handled()


## Shows a `ui_strings.json` message. `values` fills `{name}` placeholders.
func open_key(key: String, values: Dictionary = {}) -> void:
	_source = {"key": key, "values": values}
	_bind()
	_show()


## Shows already-formatted text (must itself be localised by the caller).
func open_text(text: String) -> void:
	_source = {"text": text}
	_bind()
	_show()


func close() -> void:
	if not visible:
		return
	visible = false
	remove_from_group(MODAL_GROUP)
	closed.emit()


func is_open() -> bool:
	return visible


## Text currently displayed (tests read this).
func message_text() -> String:
	return _message.text


func _show() -> void:
	visible = true
	add_to_group(MODAL_GROUP)
	_ok_button.grab_focus()


func _bind() -> void:
	if _source.has("key"):
		var key := str(_source["key"])
		var values: Dictionary = _source.get("values", {})
		_message.text = I18n.fmt(key, values)
	else:
		_message.text = str(_source.get("text", ""))
	_ok_button.text = I18n.t_key("ui.ok")
	# §4.7/§6: grow to at most 400px, then the ScrollContainer scrolls.
	var body_height: float = _message.get_combined_minimum_size().y
	_body_scroll.custom_minimum_size.y = minf(body_height, float(MAX_BODY_H))


func _on_locale_changed(_locale: String) -> void:
	if not _source.is_empty():
		_bind()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style
