extends Control
## Nationality select (S2) — docs/80-UI-UX.md §4.1, docs/50-* §4.1.
##
## The six cards are built from `DataLoader.nations_list` in file order
## (Portugal, Spain, England, Holland, Ottoman, Italy — the fixed §4.1 order is
## the data order), so every displayed value (name, description, color, start
## port/ship/gold) is data-driven. Nothing about a nation is hardcoded here.
##
## All player-facing text comes from `data/ui_strings.json` (`nation.*`,
## `ui.*`) or from an L10nString in the data files, translated with I18n.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written Godot's class cache.

const PaletteLib := preload("res://scripts/palette.gd")

const TITLE_SCENE := "res://scenes/title/title_screen.tscn"
const NATIONS_PER_ROW := 3
const CARD_SIZE := Vector2(360, 208)

@onready var _background: ColorRect = $Background
@onready var _title: Label = $Layout/Header/Title
@onready var _prompt: Label = $Layout/Header/Prompt
@onready var _grid: GridContainer = $Layout/Cards
@onready var _world_label: Label = $Layout/WorldRow/WorldLabel
@onready var _world_buttons: HBoxContainer = $Layout/WorldRow/WorldButtons
@onready var _back_button: Button = $Layout/Footer/Back
@onready var _confirm_button: Button = $Layout/Footer/Confirm
@onready var _lang_button: Button = $Layout/Footer/Lang

## Selected nation id; the first card is selected until the player picks one.
var _selected_id: String = ""
## Selected world map id (`"p1"`/`"p3"`, docs/70-* §4.9.8); defaults to the
## first indexed map that is not the Phase-1 one, i.e. the full world.
var _selected_map: String = "p3"
## map id → its radio Button, rebuilt on every bind.
var _world_cards: Dictionary = {}
## Card buttons in data order, so selection styling can be refreshed cheaply.
var _cards: Array[Button] = []


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_prompt.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_grid.columns = NATIONS_PER_ROW
	_grid.add_theme_constant_override("h_separation", PaletteLib.MARGIN)
	_grid.add_theme_constant_override("v_separation", PaletteLib.MARGIN)
	for button in [_back_button, _confirm_button, _lang_button]:
		button.custom_minimum_size.y = PaletteLib.BUTTON_H

	_back_button.pressed.connect(_on_back)
	_confirm_button.pressed.connect(confirm_selection)
	_lang_button.pressed.connect(I18n.toggle_locale)
	_world_label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	EventBus.locale_changed.connect(_on_locale_changed)

	if not DataLoader.nations_list.is_empty():
		_selected_id = str(DataLoader.nations_list[0].get("id", ""))
	_rebuild()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		_on_back()


## Rebuilds the card grid and every static label from data. Runs on ready and
## again on `locale_changed`, so both languages render identical layouts.
func _rebuild() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_cards.clear()

	_title.text = I18n.t_key("nation.select_title")
	_prompt.text = I18n.t_key("nation.select_prompt")
	_build_world_row()
	_back_button.text = I18n.t_key("ui.back")
	_confirm_button.text = I18n.t_key("nation.confirm")
	_lang_button.text = I18n.t_key("ui.language_toggle")

	for nation in DataLoader.nations_list:
		var card := _build_card(nation)
		_grid.add_child(card)
		_cards.append(card)
	_refresh_selection()


## One card: flag color block, name, description and the start package — all
## read from the Nation record plus its referenced Port/ShipType records
## (docs/50-* §4.1 item 2).
func _build_card(nation: Dictionary) -> Button:
	var nation_id := str(nation.get("id", ""))
	var card := Button.new()
	card.name = "Card_%s" % nation_id
	card.toggle_mode = true
	card.custom_minimum_size = CARD_SIZE
	card.pressed.connect(_on_card_pressed.bind(nation_id))

	var box := VBoxContainer.new()
	box.name = "Content"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = PaletteLib.MARGIN
	box.offset_top = PaletteLib.MARGIN
	box.offset_right = -PaletteLib.MARGIN
	box.offset_bottom = -PaletteLib.MARGIN
	box.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	card.add_child(box)

	# Flag color block: 24×24 token sized per docs/80-* §4.8.
	var flag := ColorRect.new()
	flag.name = "Flag"
	flag.color = PaletteLib.nation_color(str(nation.get("color", "#ffffff")))
	flag.custom_minimum_size = Vector2(24, 24)
	flag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(flag)

	var name_label := Label.new()
	name_label.name = "NationName"
	name_label.text = I18n.t(nation.get("name", {}))
	name_label.add_theme_color_override("font_color", PaletteLib.TEXT)
	name_label.add_theme_font_size_override("font_size", 24)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_label)

	var desc := Label.new()
	desc.name = "Description"
	desc.text = I18n.t(nation.get("description", {}))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(328, 56)
	desc.add_theme_color_override("font_color", PaletteLib.TEXT)
	desc.add_theme_font_size_override("font_size", 12)
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(desc)

	var package := Label.new()
	package.name = "StartPackage"
	package.text = _package_text(nation)
	package.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	package.add_theme_color_override("font_color", PaletteLib.ACCENT)
	package.add_theme_font_size_override("font_size", 12)
	package.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(package)

	return card


## Start package lines; the numbers are composed here and the L10nStrings only
## provide the sentence frame (docs/10-* §3.3 rule 5).
func _package_text(nation: Dictionary) -> String:
	var port: Dictionary = DataLoader.get_port(str(nation.get("start_port_id", "")))
	var ship: Dictionary = DataLoader.get_ship_type(
		str(nation.get("start_ship_type_id", ""))
	)
	var lines: Array[String] = [
		I18n.t_key("nation.start_package"),
		I18n.fmt("nation.start_port", {"port": I18n.t(port.get("name", {}))}),
		I18n.fmt("nation.start_ship", {"ship": I18n.t(ship.get("name", {}))}),
		I18n.fmt("nation.start_gold", {
			"gold": format_thousands(int(nation.get("start_gold", 0))),
		}),
	]
	return "\n".join(lines)


func _on_card_pressed(nation_id: String) -> void:
	_selected_id = nation_id
	_refresh_selection()


func _refresh_selection() -> void:
	for card in _cards:
		card.button_pressed = card.name == "Card_%s" % _selected_id
		card.add_theme_color_override(
			"font_color",
			PaletteLib.ACCENT if card.button_pressed else PaletteLib.TEXT
		)


func _on_back() -> void:
	GameState.change_scene(TITLE_SCENE)


## The Phase-3 world choice (docs/70-* §4.9.8, docs/80-* §4.3): one radio row
## per `data/maps/maps.json` entry, in index order. Data-driven, so a third map
## needs no code.
func _build_world_row() -> void:
	for child in _world_buttons.get_children():
		_world_buttons.remove_child(child)
		child.queue_free()
	_world_cards.clear()
	_world_label.text = I18n.t_key("nation.world")
	var ids: Array = DataLoader.map_ids()
	if not _selected_map in ids and not ids.is_empty():
		_selected_map = str(ids[ids.size() - 1])
	for map_id in ids:
		var entry: Dictionary = DataLoader.get_map(str(map_id))
		var button := Button.new()
		button.name = "World_%s" % str(map_id)
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(320, PaletteLib.BUTTON_H)
		button.text = I18n.t(entry.get("name", {}))
		button.pressed.connect(_on_world_pressed.bind(str(map_id)))
		_world_buttons.add_child(button)
		_world_cards[str(map_id)] = button
	_refresh_world_selection()


func _on_world_pressed(map_id: String) -> void:
	_selected_map = map_id
	_refresh_world_selection()


func _refresh_world_selection() -> void:
	for map_id in _world_cards:
		var button: Button = _world_cards[map_id]
		button.button_pressed = str(map_id) == _selected_map
		button.add_theme_color_override(
			"font_color",
			PaletteLib.ACCENT if button.button_pressed else PaletteLib.TEXT
		)


## The map the confirm will start the run on (tests read this).
func selected_map() -> String:
	return _selected_map


## Picks a world map programmatically (the radio row's `pressed` path).
func select_world(map_id: String) -> void:
	if _world_cards.has(map_id):
		_on_world_pressed(map_id)


## Confirm: start the run. `GameState.new_game()` owns the §4.1 state block and
## the routing (port screen once T11 lands, world map until then); the chosen
## world becomes `world.map_id` (docs/70-* §4.9.8).
func confirm_selection() -> void:
	if _selected_id.is_empty():
		return
	GameState.new_game(_selected_id, true, _selected_map)


func _on_locale_changed(_locale: String) -> void:
	_rebuild()


## Thousands separator for composed numbers; the L10nString supplies the
## unit/suffix (`nation.start_gold`), never the digits.
static func format_thousands(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for index in range(digits.length() - 1, -1, -1):
		out = digits[index] + out
		count += 1
		if count % 3 == 0 and index > 0:
			out = "," + out
	return ("-" if value < 0 else "") + out
