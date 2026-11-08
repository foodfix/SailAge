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
##
## **Optional illustration slot** (Phase-10 W4-C contract): a dialog entry may
## carry `"icon_id"` (e.g. the discovery dialog's `marker_discovery_{category}`,
## `world_map.explore_here()`); the HUD funnel forwards it as `open_key`'s
## third argument. When `UiKit.hero_texture(id)` resolves, the 64px hero
## renders 1:1 (the §4.8 hero-64 display rule; the inline 32 stays the
## per-file fallback)
## renders beside the message (the §4.8.8 inline 1× cell; the wrap width
## yields the icon cell while it shows). An absent id or a registry miss ⇒
## exactly the text-only dialog.

const PaletteLib := preload("res://scripts/palette.gd")
## §4.9 icon registry (W4-B/W4-C): the illustration slot resolves here; a
## miss keeps the text-only rendering (§4.9 icon params).
const UiKitLib := preload("res://scripts/ui_kit.gd")

## Emitted when the dialog closes (OK button or Esc/Enter).
signal closed

const DIM_ALPHA := 0.4
## Group every open modal joins, so hosts can test "is a modal up?" without
## knowing which dialog type it is (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"
## §4.7/§6: the body grows to 400px, then scrolls.
const MAX_BODY_H := 400
## The illustration cell (§4.8.8: icons render 1× inline, 32px) and the row
## gap the wrap width yields while it shows (the engine-default container
## separation — the sweep keeps per-screen spacing overrides retired).
const ICON_PX := 64
const ICON_ROW_SEP := 4

## `{key: String, values: Dictionary, icon_id: String}`, or `{text: String}`.
## Kept so a locale change can rebuild exactly the same message (and icon).
var _source: Dictionary = {}

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _body_scroll: ScrollContainer = $Center/Panel/Margin/Body/Scroll
@onready var _icon: TextureRect = \
	$Center/Panel/Margin/Body/Scroll/IconRow/Icon
@onready var _message: Label = \
	$Center/Panel/Margin/Body/Scroll/IconRow/Message
@onready var _ok_button: Button = $Center/Panel/Margin/Body/Footer/OK


func _ready() -> void:
	# Stay hidden until one of the open_* calls supplies content; a dialog on
	# screen with no message would be a bug, so the constructor paths are the
	# only way in.
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	# §4.9 sweep (W4-B): the panel chrome is the theme's PanelContainer
	# stylebox and the message ink is the theme's TEXT — no per-screen
	# styling left here.
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.custom_minimum_size = Vector2(ICON_PX, ICON_PX)
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Wrapping needs a fixed text width; the panel is 480px with 16px margins
	# (reduced by the illustration cell while an icon shows — see [_bind]).
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
## `icon_id` is the optional §4.8 illustration slot id (the W4-C discovery
## contract) — resolved through the §4.9 registry, a miss keeping the
## text-only dialog.
func open_key(key: String, values: Dictionary = {}, icon_id: String = "") -> void:
	_source = {"key": key, "values": values, "icon_id": icon_id}
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
	# The optional illustration slot (§4.8.8, W4-C contract): a resolved id
	# shows the 32px icon beside the message and yields the wrap width by
	# that cell; an absent id or registry miss hides the icon and restores
	# the full text-only width.
	var icon_tex: Texture2D = UiKitLib.hero_texture(
		str(_source.get("icon_id", "")))
	_icon.visible = icon_tex != null
	if icon_tex != null:
		_icon.texture = icon_tex
	_message.custom_minimum_size.x = float(PaletteLib.DIALOG_W
		- 2 * PaletteLib.MARGIN
		- ((ICON_PX + ICON_ROW_SEP) if icon_tex != null else 0))
	# §4.7/§6: grow to at most 400px, then the ScrollContainer scrolls.
	var body_height: float = _message.get_combined_minimum_size().y
	_body_scroll.custom_minimum_size.y = minf(body_height, float(MAX_BODY_H))


func _on_locale_changed(_locale: String) -> void:
	if not _source.is_empty():
		_bind()
