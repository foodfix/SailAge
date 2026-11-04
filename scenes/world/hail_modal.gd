extends Control
## Phase-8 W5-B hail modal (`scenes/world/hail_modal.tscn`, docs/80-UI-UX.md
## §4.10.2; the chrome follows the `dialog_box.tscn` modal precedent: 40% dim,
## 480px panel, owns all input while open, `docs/90-*` §7).
##
## Renders the talk options `HailOptions.options_for` builds — one row per
## option (`hail.option.*` labels, terms lines from the `hail.*` family,
## `I18n.fmt`/`t`), the supply row carrying a `[- qty +]` stepper capped at
## affordability + capacity — and shows a resolve's `lines` afterwards. The
## intimidate ROLL is drawn here from the battle's seeded stream
## (`HailOptions.draw_roll`, the §4.11.1 seed formula) and passed into
## [code resolve] — the module itself stays RNG-free for tests.
##
## The modal never mutates GameState directly except through
## `HailOptions.resolve` (the single funnel). A resolve that reports
## `made_hostile` flips the flag; when the modal closes it emits
## [signal closed] first, then [signal hostile_encounter_requested] with the
## fleet — the caller (world_map, master-wired) turns it into the
## §4.11.11.2 contact battle on a closed modal.
##
## Caller entry points (the master's 2-line hookup):
##   var modal := HailModalScene.open_for(fleet)          # or instance+setup
##   modal.hostile_encounter_requested.connect(_open_encounter)

const PaletteLib := preload("res://scripts/palette.gd")
const HailOptionsLib := preload("res://scripts/world/hail_options.gd")
## The W4-D portrait contract seam (§4.11.3 composer): the modal guard-loads
## the composer and asks it for the hailed captain's bust; the script is
## absent on bases before D merges (or answers null) ⇒ the text-only rows.
const PortraitComposerPath := "res://scripts/ui/portrait_composer.gd"
## The §4.8.8 portrait footprint (3:4 bust).
const PORTRAIT_SIZE := Vector2(72, 96)

## Emitted when the modal closes (OK button or Esc).
signal closed
## Emitted after [signal closed] when the last resolve reported
## `made_hostile`; carries the hailed fleet dict.
signal hostile_encounter_requested(fleet: Dictionary)

const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"
## §4.7/§6: the body grows to 400px, then scrolls.
const MAX_BODY_H := 400
## §4.6.1 stepper convention: steps of 10.
const STEP_SIZE := 10

## Option id → its `hail.option.*` label suffix.
const OPTION_LABEL_KEYS := {
	HailOptionsLib.OPTION_RUMOURS: "rumours",
	HailOptionsLib.OPTION_SUPPLIES: "supplies",
	HailOptionsLib.OPTION_INTIMIDATE: "intimidate",
	HailOptionsLib.OPTION_BEFRIEND: "befriend",
}

const SCENE_PATH := "res://scenes/world/hail_modal.tscn"

## The hailed fleet dict (the caller's live entry — resolve mutates through
## the funnel).
var _fleet: Dictionary = {}
## The staged supplies bundle (the stepper value, per kind).
var _staged_qty: int = 0
## The last executed resolve payload ({} while the options view shows).
var _result: Dictionary = {}
## Set when a resolve reported `made_hostile`; fired on close.
var _made_hostile := false
var _open := false

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _scroll: ScrollContainer = $Center/Panel/Margin/Body/Scroll
@onready var _content: VBoxContainer = $Center/Panel/Margin/Body/Scroll/Content
@onready var _ok_button: Button = $Center/Panel/Margin/Body/Footer/OK


func _ready() -> void:
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	# Phase-10 sweep: the panel/title chrome retired to the theme (§4.9
	# Panel + Label rows).
	_scroll.custom_minimum_size = Vector2(PaletteLib.DIALOG_W - 2 * PaletteLib.MARGIN, 0)
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_ok_button.custom_minimum_size = Vector2(120, PaletteLib.BUTTON_H)
	_ok_button.pressed.connect(close)
	EventBus.locale_changed.connect(_on_locale_changed)
	if _open:
		_refresh()


## The master's static-ish entry: instantiates the scene under `host`
## (default: the current scene), opens it on `fleet` and returns the modal so
## the caller can wire [signal hostile_encounter_requested] / [signal closed].
static func open_for(fleet: Dictionary, host: Node = null) -> Node:
	var scene: PackedScene = load(SCENE_PATH)
	var modal := scene.instantiate()
	var parent := host
	if parent == null:
		var tree := Engine.get_main_loop() as SceneTree
		parent = tree.current_scene if tree != null \
			and tree.current_scene != null else tree.root
	parent.add_child(modal)
	(modal as Node).call("setup", fleet)
	return modal


## Opens the modal on `fleet` (builds the option rows from the live state).
func setup(fleet: Dictionary) -> void:
	_fleet = fleet
	_staged_qty = 0
	_result = {}
	_made_hostile = false
	_open = true
	visible = true
	add_to_group(MODAL_GROUP)
	_refresh()


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	remove_from_group(MODAL_GROUP)
	closed.emit()
	if _made_hostile:
		hostile_encounter_requested.emit(_fleet)


func is_open() -> bool:
	return _open


## True once an executed resolve replaced the option rows with its lines.
func is_showing_results() -> bool:
	return not _result.is_empty()


## The last executed resolve payload (the suite reads this instead of scraping
## labels).
func result_payload() -> Dictionary:
	return _result


## The staged supplies bundle size.
func staged_qty() -> int:
	return _staged_qty


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	# Modal: swallow everything (§6). Esc closes; the result view also closes
	# on accept, the options view only via OK/Esc (the buttons carry actions).
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		close()
		return
	if _result_ready_for_accept() and event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		close()
		return
	get_viewport().set_input_as_handled()


func _result_ready_for_accept() -> bool:
	return not _result.is_empty()


# --- Rendering ----------------------------------------------------------------

## Re-renders the current view (options, or the last resolve's lines).
func _refresh() -> void:
	if _result.is_empty():
		_show_options()
	else:
		_show_results(_result)
	# §4.7/§6: grow to at most 400px, then the ScrollContainer scrolls.
	var body_height: float = _content.get_combined_minimum_size().y
	_scroll.custom_minimum_size.y = minf(body_height, float(MAX_BODY_H))


func _show_options() -> void:
	_title.text = I18n.fmt("hail.title", {"name": HailOptionsLib.display_name(_fleet)})
	_clear(_content)
	# §4.10.2 (Phase 10): the guarded portrait slot — the W4-D composer's
	# bust of the hailed captain when it resolves; null ⇒ text-only rows
	# (exactly today's layout).
	var portrait := _portrait_texture()
	if portrait != null:
		_content.add_child(_portrait_row(portrait))
	for option in HailOptionsLib.options_for(_fleet):
		_add_option_row(option)
	if str(_fleet.get("role", "")) == "coaster":
		_add_terms_label(I18n.t_key("hail.coaster_note"))
	_ok_button.text = I18n.t_key("ui.close")


## The W4-D contract seam: `ResourceLoader.exists` → load →
## `portrait_texture(person)`; every miss (no captain, no composer script,
## no composer method, a null/failed texture) ⇒ null — the text-only row.
func _portrait_texture() -> Texture2D:
	var captain_id := str(_fleet.get("captain_id", ""))
	if captain_id.is_empty():
		return null
	var person: Dictionary = DataLoader.get_captain(captain_id)
	if person.is_empty():
		return null
	if not ResourceLoader.exists(PortraitComposerPath):
		return null
	var composer = load(PortraitComposerPath)
	if composer == null or not (composer as Object).has_method("portrait_texture"):
		return null
	var texture = composer.call("portrait_texture", person)
	return texture if texture is Texture2D else null


## The portrait illustration row: the 72×96 bust at the top of the options.
func _portrait_row(texture: Texture2D) -> Control:
	var row := HBoxContainer.new()
	row.name = "PortraitRow"
	var rect := TextureRect.new()
	rect.name = "Portrait"
	rect.texture = texture
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.custom_minimum_size = PORTRAIT_SIZE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(rect)
	return row


func _add_option_row(option: Dictionary) -> void:
	var option_id := str(option.get("id", ""))
	var row := VBoxContainer.new()
	row.name = "Row_%s" % option_id

	var line := HBoxContainer.new()
	line.name = "Line"

	var button := Button.new()
	button.name = "Action_%s" % option_id
	button.text = I18n.t_key("hail.option.%s"
		% str(OPTION_LABEL_KEYS.get(option_id, option_id)))
	button.custom_minimum_size = Vector2(200, PaletteLib.BUTTON_H)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.disabled = not bool(option.get("enabled", false))
	button.pressed.connect(_on_option_pressed.bind(option_id))
	line.add_child(button)

	if option_id == HailOptionsLib.OPTION_SUPPLIES:
		_add_supply_stepper(line)
	row.add_child(line)

	# Terms lines, inline (80-* §4.10.2): the keys the W2-C family authored.
	match option_id:
		HailOptionsLib.OPTION_RUMOURS:
			if bool(option.get("intel", false)):
				_add_terms_label(I18n.t_key("hail.rumours.intel_terms"), row)
		HailOptionsLib.OPTION_SUPPLIES:
			_add_terms_label(I18n.t_key("hail.supplies.terms"), row)
			if HailOptionsLib.stance_of(_fleet) >= HailOptionsLib.SUPPLY_WARM_STANCE:
				_add_terms_label(I18n.t_key("hail.supplies.stance_terms"), row)
			var points := HailOptionsLib.negotiation_discount_points()
			if points > 0:
				_add_terms_label(I18n.fmt("hail.supplies.negotiation",
					{"percent": points}), row)
		HailOptionsLib.OPTION_BEFRIEND:
			_add_terms_label(I18n.t_key("hail.befriend.terms"), row)
			if not bool(option.get("enabled", false)):
				_add_terms_label(I18n.t_key(str(option.get("reason_key",
					"gate.locked"))), row)

	_content.add_child(row)


## The `[- qty + ]` stepper + total-cost caption of the supply row (the
## §4.6.1 convention, steps of 10; staged value starts at 0).
func _add_supply_stepper(line: HBoxContainer) -> void:
	var minus := Button.new()
	minus.name = "StepMinus"
	minus.text = "-"
	minus.custom_minimum_size = Vector2(40, PaletteLib.BUTTON_H)
	minus.pressed.connect(_on_step.bind(-STEP_SIZE))
	line.add_child(minus)

	var qty := Label.new()
	qty.name = "Qty"
	qty.custom_minimum_size = Vector2(56, PaletteLib.ROW_H)
	qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.add_child(qty)

	var plus := Button.new()
	plus.name = "StepPlus"
	plus.text = "+"
	plus.custom_minimum_size = Vector2(40, PaletteLib.BUTTON_H)
	plus.pressed.connect(_on_step.bind(STEP_SIZE))
	line.add_child(plus)

	var cost := Label.new()
	cost.name = "Cost"
	cost.custom_minimum_size = Vector2(96, PaletteLib.ROW_H)
	cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_child(cost)
	_refresh_supply_row()


func _on_step(delta: int) -> void:
	var max_qty := 0
	for option in HailOptionsLib.options_for(_fleet):
		if str(option.get("id", "")) == HailOptionsLib.OPTION_SUPPLIES:
			max_qty = int(option.get("max_qty", 0))
	_staged_qty = clampi(_staged_qty + delta, 0, max_qty)
	_refresh_supply_row()


func _refresh_supply_row() -> void:
	var row := _content.get_node_or_null(
		"Row_%s" % HailOptionsLib.OPTION_SUPPLIES)
	if row == null:
		return
	var qty_label: Label = row.get_node("Line/Qty")
	var cost_label: Label = row.get_node("Line/Cost")
	qty_label.text = str(_staged_qty)
	var cost := 0
	if _staged_qty > 0:
		cost = HailOptionsLib.supplies_pair_cost(_fleet, _staged_qty)
	cost_label.text = I18n.fmt("ui.gold_amount", {"gold": cost}) \
		if cost > 0 else "-"


func _show_results(payload: Dictionary) -> void:
	_clear(_content)
	for entry in payload.get("lines", []):
		if not (entry is Dictionary):
			continue
		var label := Label.new()
		label.text = I18n.fmt(str(entry.get("key", "")),
			entry.get("values", {}) if entry.get("values", {}) is Dictionary
			else {})
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.custom_minimum_size.x = float(
			PaletteLib.DIALOG_W - 2 * PaletteLib.MARGIN)
		_content.add_child(label)
	_ok_button.text = I18n.t_key("ui.ok")


func _add_terms_label(text: String, row: Container = null) -> void:
	var label := Label.new()
	label.name = "Terms"
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Secondary terms text carries the theme's Dim variation (§4.9).
	label.theme_type_variation = "Dim"
	label.custom_minimum_size.x = float(PaletteLib.DIALOG_W - 2 * PaletteLib.MARGIN)
	if row == null:
		_content.add_child(label)
	else:
		row.add_child(label)


# --- Actions ------------------------------------------------------------------

## One option press. The intimidate roll is drawn HERE from the battle's
## seeded stream and passed into the funnel (the module stays RNG-free).
func _on_option_pressed(option_id: String) -> void:
	if not _open or not _result.is_empty():
		return
	var payload: Dictionary
	if option_id == HailOptionsLib.OPTION_SUPPLIES:
		payload = HailOptionsLib.resolve(option_id, _fleet, _staged_qty)
	elif option_id == HailOptionsLib.OPTION_INTIMIDATE:
		payload = HailOptionsLib.resolve(option_id, _fleet, 0,
			HailOptionsLib.draw_roll(_fleet))
	else:
		payload = HailOptionsLib.resolve(option_id, _fleet)
	if bool(payload.get("ok", false)):
		_result = payload
		if bool(payload.get("made_hostile", false)):
			_made_hostile = true
		_show_results(payload)
	else:
		# Refused (e.g. befriend already used today): re-render so the gated
		# row grays out with its reason.
		_refresh()


# --- Chrome -------------------------------------------------------------------

func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


func _on_locale_changed(_locale: String) -> void:
	if _open:
		_refresh()
