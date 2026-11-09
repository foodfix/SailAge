extends Control
## Modal confirm dialog — "message + confirm/cancel" (docs/80-UI-UX.md §4.7);
## same chrome as [DialogBox] (40% dim, 480px wide, wraps, long bodies
## scroll in the fixed body viewport), plus two buttons.
##
## * `Enter`/`Y` confirm, `N`/`Esc` cancel (docs/80-* §4.3 input table).
## * Results leave through [signal confirmed] / [signal cancelled] and the
##   shared [signal closed(accepted)] — never a callback into another scene
##   (docs/90-* §7).
## * Owns all input while open (§6 "modals consume all input").
## * Re-binds on `EventBus.locale_changed` (§6).
##
## Phase 12 (docs/80-* §4.8.9): the absolute-tile layout — the node tree IS
## the element tree. The old `Center → Panel → Margin → Body → Footer` flow
## chain is deleted; the plate is a fixed tile rect (`22,12,15,10` on the
## 60 × 33.75 canvas) and its children hang DIRECTLY off the registered
## panel at their data rects. The body ScrollContainer survives only as the
## message viewport (the §4.7 grow-to-cap scroll): the label is its content
## child, sized by its own text minimum — no flow underneath. Every
## persistent control registers its stable id; [method RegistryLib.
## screen_active] fires at each OPEN so a re-open re-applies the committed
## `data/ui_layout.json` rects.

const PaletteLib := preload("res://scripts/palette.gd")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

## This modal's layout screen id (docs/10-* §4.23 — the 32-screen set).
const SCREEN_ID := "confirm"

## Emitted for either choice; `accepted` is true for confirm.
signal closed(accepted: bool)
signal confirmed
signal cancelled

const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"

## `{key, values}` or `{text}`; rebuilt on a locale change.
var _source: Dictionary = {}
## True while the dialog is on screen and awaiting a choice; guards double
## emission if a caller closes it programmatically.
var _open := false
## The id pass runs once per instance (the records persist across closes;
## a re-open only re-activates — re-registering the same live nodes would
## breach the duplicate-id guard).
var _ids_registered := false

@onready var _dim: ColorRect = $Dim
@onready var _panel: Panel = $Panel
@onready var _body: ScrollContainer = $Panel/Body
@onready var _message: Label = $Panel/Body/Message
@onready var _confirm_button: Button = $Panel/Confirm
@onready var _cancel_button: Button = $Panel/Cancel


func _ready() -> void:
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	# §4.9 sweep (W4-B): the panel chrome is the theme's panel stylebox and
	# the message ink is the theme's TEXT.
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Wrapping needs a fixed text width: the body viewport's tile width
	# (13 tiles of the 15-tile plate, `panel.body`).
	_message.custom_minimum_size.x = float(_body.size.x)
	_confirm_button.pressed.connect(accept)
	_cancel_button.pressed.connect(cancel)
	EventBus.locale_changed.connect(_on_locale_changed)


## The id pass — every persistent control under its stable hierarchical id
## (the plate's role tags what a `sheet` edit may target). Phase 12: modals
## register AT OPEN, never at `_ready` — host scenes embed idle dialog
## instances (battle, palace, shipyard, provisions …) that must stay
## unregistered until they actually show, so two embedded instances never
## fight over the screen's records.
func _register_ids() -> void:
	RegistryLib.register(SCREEN_ID, _dim, "dim")
	RegistryLib.register(SCREEN_ID, _panel, "panel", {"role": "panel"})
	RegistryLib.register(SCREEN_ID, _body, "panel.body")
	RegistryLib.register(SCREEN_ID, _message, "panel.body.message")
	RegistryLib.register(SCREEN_ID, _confirm_button, "panel.confirm",
		{"role": "button"})
	RegistryLib.register(SCREEN_ID, _cancel_button, "panel.cancel",
		{"role": "button"})


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
	# Phase 12: modals register at their FIRST OPEN and activate at every
	# open (the apply walk re-applies the committed data rects; it is
	# idempotent).
	if not _ids_registered:
		_register_ids()
		_ids_registered = true
	RegistryLib.screen_active(SCREEN_ID, self)
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


func _on_locale_changed(_locale: String) -> void:
	if not _source.is_empty():
		_bind()
		# The rebuild path: the re-bound text changes the message's content
		# minimum — re-apply the layout (a no-op until the screen's v2 table
		# ships).
		RegistryLib.apply_layout(SCREEN_ID)
