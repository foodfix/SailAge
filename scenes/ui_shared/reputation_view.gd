class_name ReputationView
extends Control
## The 声望 view — docs/80-UI-UX.md §4.5 (amended 2026-11-03: the six-nation
## table split out of the 船长 page into its own intel-window tab; it was
## buried under the player card and the gate list).
##
## One row per nation, always all six (docs/50-* §4.6 / §6 "no Nation rows
## hidden"): the name tinted ACCENT for the player's own nation, the value
## right-aligned and colored GOOD / BAD / TEXT by sign. The `+`/`-` sign is
## composed by the UI, never baked into an L10nString (docs/10-* §3.3 rule 5).
##
## Embeddable view contract: the intel window instantiates this scene and calls
## [method refresh] when its tab becomes active; the view also refreshes itself
## on the EventBus signals while visible.

const PaletteLib := preload("res://scripts/palette.gd")
const CharacterLib := preload("res://scripts/player/character.gd")

@onready var _title: Label = $Body/Title
@onready var _rows: GridContainer = $Body/Page/Sections/Rows
@onready var _hint: Label = $Body/Page/Sections/Hint


func _ready() -> void:
	# §4.9 sweep (W4-B): the title keeps its ACCENT mark via `modulate`;
	# secondary hint text uses the theme's `Dim` variation.
	_title.modulate = PaletteLib.ACCENT
	_hint.theme_type_variation = "Dim"
	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.port_entered.connect(_on_port_entered)


## True while this view is the intel window's active tab.
func is_active() -> bool:
	return is_visible_in_tree()


## Rebuilds the table from live state.
func refresh() -> void:
	_title.text = I18n.t_key("char.reputation")
	_hint.text = I18n.t_key("char.reputation.hint") \
		if DataLoader.ui_strings.has("char.reputation.hint") else ""
	_hint.visible = not _hint.text.is_empty()
	var nation_id := str(GameState.player.get("nation_id", ""))
	_rows.columns = 2
	_clear(_rows)
	for nation in DataLoader.nations_list:
		var other_id := str(nation.get("id", ""))
		var value := CharacterLib.reputation(other_id)
		var name_label := _make_label(I18n.t(nation.get("name", {})))
		name_label.name = "Rep_%s" % other_id
		# The player's own nation keeps its ACCENT mark (§4.9 sweep:
		# state tint via `modulate`).
		if other_id == nation_id:
			name_label.modulate = PaletteLib.ACCENT
		var value_label := _make_label(format_signed(value))
		value_label.name = "Value_%s" % other_id
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.custom_minimum_size.x = 96
		value_label.modulate = PaletteLib.GOOD if value > 0 \
			else (PaletteLib.BAD if value < 0 else Color.WHITE)
		_rows.add_child(name_label)
		_rows.add_child(value_label)


## True when the table is rendering (test hook: the row count check).
func row_count() -> int:
	return _rows.get_child_count()


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	# Ink is the theme's TEXT (§4.9 sweep); rows add `modulate` state tints.
	return label


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


## `+20` / `0` / `-5`: the sign is composed by the UI, not baked into an
## L10nString (docs/10-* §3.3 rule 5).
static func format_signed(value: int) -> String:
	if value > 0:
		return "+%d" % value
	return str(value)


func _on_locale_changed(_locale: String) -> void:
	if is_active():
		refresh()


func _on_port_entered(_port_id: String) -> void:
	if is_active():
		refresh()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.port_entered.is_connected(_on_port_entered):
		EventBus.port_entered.disconnect(_on_port_entered)
