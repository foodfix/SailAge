extends Control
## Modal message dialog — "message + OK" (docs/80-UI-UX.md §4.7);
## instanced as a modal child of the current screen (docs/90-* §7).
##
## * Dims the background by 40% black, a fixed 480px plate (§4.8), text
##   wraps, long bodies scroll in the fixed body viewport (§4.7, §6).
## * Fully modal: it consumes every input event while open, so `Esc` closes it
##   and nothing underneath reacts (§6 "modals consume all input").
## * Results leave through [signal closed] — never a callback into another
##   scene (docs/90-* §7).
## * Re-binds its text on `EventBus.locale_changed` (§6).
##
## Text sources: [method open_key] (a `ui_strings.json` key + `{name}` values)
## or [method open_text] (already-formatted text, e.g. a composed summary).
##
## **Optional illustration slot** (Phase-10 W4-C contract): a dialog entry may
## carry `"icon_id"` (e.g. the discovery dialog's `marker_discovery_{category}`,
## `world_map.explore_here()`); the HUD funnel forwards it as `open_key`'s
## third argument. When `UiKit.hero_texture(id)` resolves, the 64px hero
## renders 1:1 (the §4.8 hero-64 display rule) in the body's reserved 2-tile
## left cell — the same reserved-slot rule the market rows use for the ★
## badge, so the wrap width never changes with the icon's presence. An absent
## id or a registry miss ⇒ the same dialog with an empty cell.
##
## Phase 12 (docs/80-* §4.8.9): the absolute-tile layout — the node tree IS
## the element tree; the old `Center → Panel → Margin → Body → Scroll →
## IconRow/Footer` flow chain is deleted and every control registers its
## stable id (activation at each OPEN; the plate is the fixed
## `22,12,15,10` rect of `data/ui_layout.json`).

const PaletteLib := preload("res://scripts/palette.gd")
## §4.9 icon registry (W4-B/W4-C): the illustration slot resolves here; a
## miss keeps the text-only rendering (§4.9 icon params).
const UiKitLib := preload("res://scripts/ui_kit.gd")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

## This modal's layout screen id (docs/10-* §4.23 — the 32-screen set).
const SCREEN_ID := "dialog_box"

## Emitted when the dialog closes (OK button or Esc/Enter).
signal closed

const DIM_ALPHA := 0.4
## Group every open modal joins, so hosts can test "is a modal up?" without
## knowing which dialog type it is (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"
## The illustration cell: the body's reserved 2-tile left slot (§4.8 hero-64
## display rule — 64 px at 1:1).
const ICON_PX := 64

## `{key: String, values: Dictionary, icon_id: String}`, or `{text: String}`.
## Kept so a locale change can rebuild exactly the same message (and icon).
var _source: Dictionary = {}
## The id pass runs once per instance (records persist across closes).
var _ids_registered := false

@onready var _dim: ColorRect = $Dim
@onready var _panel: Panel = $Panel
@onready var _body_scroll: ScrollContainer = $Panel/Body
@onready var _content: Control = $Panel/Body/Content
@onready var _icon: TextureRect = $Panel/Body/Content/Icon
@onready var _message: Label = $Panel/Body/Content/Message
@onready var _ok_button: Button = $Panel/OK


func _ready() -> void:
	# Stay hidden until one of the open_* calls supplies content; a dialog on
	# screen with no message would be a bug, so the constructor paths are the
	# only way in.
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	# §4.9 sweep (W4-B): the panel chrome is the theme's panel stylebox and
	# the message ink is the theme's TEXT — no per-screen styling left here.
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Wrapping needs a fixed text width: the body's text column right of the
	# reserved 2-tile illustration cell (`panel.body.message`).
	_message.custom_minimum_size.x = 352.0
	_body_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_ok_button.pressed.connect(close)
	EventBus.locale_changed.connect(_on_locale_changed)


## The id pass — every persistent control under its stable hierarchical id.
## Modals register AT OPEN (host scenes embed idle dialog instances that
## must stay unregistered until they show); see confirm_dialog.gd.
func _register_ids() -> void:
	RegistryLib.register(SCREEN_ID, _dim, "dim")
	RegistryLib.register(SCREEN_ID, _panel, "panel", {"role": "panel"})
	RegistryLib.register(SCREEN_ID, _body_scroll, "panel.body")
	RegistryLib.register(SCREEN_ID, _icon, "panel.body.icon")
	RegistryLib.register(SCREEN_ID, _message, "panel.body.message")
	RegistryLib.register(SCREEN_ID, _ok_button, "panel.ok", {"role": "button"})


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
## `icon_id` is the optional §4.8 illustration slot id (the W4-C discovery
## contract) — resolved through the §4.9 registry, a miss keeping the
## text-only dialog.
func open_key(key: String, values: Dictionary = {}, icon_id: String = "") -> void:
	_source = {"key": key, "values": values, "icon_id": icon_id}
	_show()
	_bind()


## Shows already-formatted text (must itself be localised by the caller).
func open_text(text: String) -> void:
	_source = {"text": text}
	_show()
	_bind()


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
	# The layout first (activation applies the data rects), then the bind —
	# so presentation reads settled geometry (the apply-then-bind order the
	# locale path shares).
	if not _ids_registered:
		_register_ids()
		_ids_registered = true
	RegistryLib.screen_active(SCREEN_ID, self)
	_bind()
	_ok_button.grab_focus()


func _bind() -> void:
	if _source.has("key"):
		var key := str(_source["key"])
		var values: Dictionary = _source.get("values", {})
		_message.text = I18n.fmt(key, values)
	else:
		_message.text = str(_source.get("text", ""))
	_ok_button.text = I18n.t_key("ui.ok")
	# The optional illustration slot (§4.8.8, W4-C contract): a resolved id
	# shows the 64px hero in the body's reserved left cell; an absent id or
	# registry miss hides the icon — the cell stays reserved, exactly the
	# market badge-slot rule, so the wrap width never drifts.
	var icon_tex: Texture2D = UiKitLib.hero_texture(
		str(_source.get("icon_id", "")))
	_icon.visible = icon_tex != null
	if icon_tex != null:
		_icon.texture = icon_tex
	# The §4.7 grow-to-cap scroll: the viewport is fixed, the scroll extent
	# tracks the message's own text minimum through the content node (the
	# plain-Control stacked extent — the long body scrolls, a short one
	# leaves the plate untouched).
	_content.custom_minimum_size = Vector2(
		_body_scroll.size.x, _message.get_combined_minimum_size().y)


func _on_locale_changed(_locale: String) -> void:
	if not _source.is_empty():
		# The rebuild path: re-apply the layout, then re-bind (the same
		# apply-then-bind order as open).
		RegistryLib.apply_layout(SCREEN_ID)
		_bind()
