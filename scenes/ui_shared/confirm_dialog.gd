extends Control
## Modal confirm dialog — "message + confirm/cancel" (docs/80-UI-UX.md §4.7);
## same chrome as [DialogBox] (40% dim, 480px wide, wraps, max 400px then
## scrolls), plus two buttons.
##
## * `Enter`/`Y` confirm, `N`/`Esc` cancel (docs/80-* §4.3 input table).
## * Results leave through [signal confirmed] / [signal cancelled] and the
##   shared [signal closed(accepted)] — never a callback into another scene
##   (docs/90-* §7).
## * Owns all input while open (§6 "modals consume all input").
## * Re-binds on `EventBus.locale_changed` (§6).

const PaletteLib := preload("res://scripts/palette.gd")

## Emitted for either choice; `accepted` is true for confirm.
signal closed(accepted: bool)
signal confirmed
signal cancelled

const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"
const MAX_BODY_H := 400

## `{key, values}` or `{text}`; rebuilt on a locale change.
var _source: Dictionary = {}
## True while the dialog is on screen and awaiting a choice; guards double
## emission if a caller closes it programmatically.
var _open := false

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _message: Label = $Center/Panel/Margin/Body/Scroll/Message
@onready var _confirm_button: Button = $Center/Panel/Margin/Body/Footer/Confirm
@onready var _cancel_button: Button = $Center/Panel/Margin/Body/Footer/Cancel


func _ready() -> void:
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_message.add_theme_color_override("font_color", PaletteLib.TEXT)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Wrapping needs a fixed text width; the panel is 480px with 16px margins.
	_message.custom_minimum_size.x = float(PaletteLib.DIALOG_W - 2 * PaletteLib.MARGIN)
	_confirm_button.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_cancel_button.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_confirm_button.pressed.connect(accept)
	_cancel_button.pressed.connect(cancel)
	EventBus.locale_changed.connect(_on_locale_changed)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# Modal: nothing underneath may react (§6). The keys below are local to the
	# dialog, not project actions, so they cannot collide with movement.
	get_viewport().set_input_as_handled()
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		match key.physical_keycode:
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_Y:
				accept()
				return
			KEY_N, KEY_ESCAPE:
				cancel()
				return


## Shows a `ui_strings.json` message plus localised confirm/cancel labels.
## `confirm_key`/`cancel_key` may override the shared `ui.confirm`/`ui.cancel`
## (e.g. "Pay 200g" / "Suppress" for the mutiny modal).
func open_key(
	key: String,
	values: Dictionary = {},
	confirm_key: String = "ui.confirm",
	cancel_key: String = "ui.cancel"
) -> void:
	_source = {
		"key": key, "values": values,
		"confirm": confirm_key, "cancel": cancel_key,
	}
	_bind()
	_show()


## Shows already-formatted text (localised by the caller).
func open_text(
	text: String,
	confirm_key: String = "ui.confirm",
	cancel_key: String = "ui.cancel"
) -> void:
	_source = {"text": text, "confirm": confirm_key, "cancel": cancel_key}
	_bind()
	_show()


func accept() -> void:
	if not _open:
		return
	_open = false
	visible = false
	remove_from_group(MODAL_GROUP)
	closed.emit(true)
	confirmed.emit()


func cancel() -> void:
	if not _open:
		return
	_open = false
	visible = false
	remove_from_group(MODAL_GROUP)
	closed.emit(false)
	cancelled.emit()


func is_open() -> bool:
	return visible


func message_text() -> String:
	return _message.text


func _show() -> void:
	_open = true
	visible = true
	add_to_group(MODAL_GROUP)
	_confirm_button.grab_focus()


func _bind() -> void:
	if _source.has("key"):
		_message.text = I18n.fmt(
			str(_source["key"]), _source.get("values", {})
		)
	else:
		_message.text = str(_source.get("text", ""))
	_confirm_button.text = I18n.t_key(str(_source.get("confirm", "ui.confirm")))
	_cancel_button.text = I18n.t_key(str(_source.get("cancel", "ui.cancel")))
	# §4.7/§6: grow to at most 400px, then scroll.
	var scroll: ScrollContainer = _message.get_parent()
	scroll.custom_minimum_size.y = minf(
		_message.get_combined_minimum_size().y, float(MAX_BODY_H)
	)


func _on_locale_changed(_locale: String) -> void:
	if not _source.is_empty():
		_bind()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style
