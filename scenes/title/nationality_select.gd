extends Control
## Nationality select (S2) — docs/80-UI-UX.md §4.1, docs/50-* §4.1.
##
## The six cards are built from `DataLoader.nations_list` in file order
## (Portugal, Spain, England, Holland, Ottoman, Italy — the fixed §4.1 order is
## the data order), so every displayed value (name, description, color, start
## port/ship/gold) is data-driven. Nothing about a nation is hardcoded here.
##
## **Phase-12 W2-B absolute layout** (docs/80-UI-UX.md §4.8.9): the node tree
## IS the element tree — the `Layout`/`Header`/`Footer` flow containers and the
## per-card `Content`/`Head` boxes are deleted. The `Cards` group is a plain
## Control at its data rect; the six cards are absolute elements inside it,
## placed from the data order (column `i % 3`, row `i / 3` on the 32×32
## chrome-tile grid); each card's parts are absolutely placed inside the card
## rect. The S2 toggle-pressed card semantics (the `Toggle` theme variation)
## are untouched — only the layout changed.
##
## All player-facing text comes from `data/ui_strings.json` (`nation.*`,
## `ui.*`) or from an L10nString in the data files, translated with I18n.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written Godot's class cache.

const PaletteLib := preload("res://scripts/palette.gd")
## Phase-12 W2-B (docs/80-UI-UX.md §4.8.9): the absolute-tile layout registry —
## every persistent control registers under a stable hierarchical id and the
## rebuild paths re-apply the committed table after re-registering.
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const TITLE_SCENE := "res://scenes/title/title_screen.tscn"
## The Phase-8 handoff target (docs/80-* §4.2: S1 → S2 → S20 → S4). The
## script preload (not just the scene path) carries the nation through the
## [member CreationLib.pending_nation_id] static.
const CreationLib := preload("res://scenes/title/creation_screen.gd")
const CREATION_SCENE := "res://scenes/title/creation_screen.tscn"
const NATIONS_PER_ROW := 3
## One card: 11×8 chrome tiles, on a 12×8-tile pitch inside the `cards`
## block (docs/80-* §4.8.9 — 1 tile = Palette.CHROME_TILE = 32 px).
const CARD_SIZE := Vector2(352, 256)
const CARD_PITCH := Vector2(384, 256)

@onready var _background: Panel = $Background
@onready var _title: Label = $Title
@onready var _prompt: Label = $Prompt
@onready var _grid: Control = $Cards
@onready var _world_label: Label = $WorldLabel
@onready var _back_button: Button = $Back
@onready var _confirm_button: Button = $Confirm

## Selected nation id; the first card is selected until the player picks one.
var _selected_id: String = ""
## Card buttons in data order, so selection styling can be refreshed cheaply.
var _cards: Array[Button] = []

## Routing switch for headless tests (the `GameState.new_game(..., route)`
## convention): with `false`, [method confirm_selection] still runs the whole
## new-game path but does not route. With the default `true`, confirm is the
## Phase-8 §4.13 handoff — it stores the nation for the creation screen (S20)
## and routes there; S20's own confirm runs `new_game`.
var route_after_confirm: bool = true
## Headless-test seam: when valid, the §4.13 handoff passes the would-be
## scene path here instead of calling `GameState.change_scene`, so a suite
## can observe the routing without swapping its own scene out.
var route_sink: Callable = Callable()


func _ready() -> void:
	# §4.9: secondary text reads through the theme's `Dim` variation; the
	# title renders the theme's default Label (TEXT). No per-screen overrides.
	_prompt.theme_type_variation = "Dim"
	_world_label.theme_type_variation = "Dim"

	_back_button.pressed.connect(_on_back)
	_confirm_button.pressed.connect(confirm_selection)
	EventBus.locale_changed.connect(_on_locale_changed)

	if not DataLoader.nations_list.is_empty():
		_selected_id = str(DataLoader.nations_list[0].get("id", ""))
	_rebuild()
	# Phase-12 W2-B: one activation after the full build — pins the root,
	# captures the baselines and applies the committed v2 table (a no-op
	# walk until master assembles the fragments at the merge gate).
	_register_static_ids()
	RegistryLib.screen_active("nationality_select", self)


## The static chrome's element ids (docs/80-* §4.8.9). The cards and their
## parts register where they build ([method _build_card]).
func _register_static_ids() -> void:
	RegistryLib.register("nationality_select", _background, "background",
		{"role": RegistryLib.ROLE_PANEL})
	RegistryLib.register("nationality_select", _title, "title")
	RegistryLib.register("nationality_select", _prompt, "prompt")
	RegistryLib.register("nationality_select", _grid, "cards")
	RegistryLib.register("nationality_select", _world_label, "world_label")
	RegistryLib.register("nationality_select", _back_button, "back",
		{"role": RegistryLib.ROLE_BUTTON})
	RegistryLib.register("nationality_select", _confirm_button, "confirm",
		{"role": RegistryLib.ROLE_BUTTON})


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		_on_back()


## Rebuilds the card block and every static label from data. Runs on ready and
## again on `locale_changed`, so both languages render identical layouts.
func _rebuild() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_cards.clear()

	_title.text = I18n.t_key("nation.select_title")
	_prompt.text = I18n.t_key("nation.select_prompt")
	# The map itself is fixed (`world`, docs/90-* §9.1); this row is a plain
	# label, not the retired Phase-3 selector (`80-*` §4.7.4).
	_world_label.text = I18n.t_key("nation.world")
	_back_button.text = I18n.t_key("ui.back")
	_confirm_button.text = I18n.t_key("nation.confirm")

	var index := 0
	for nation in DataLoader.nations_list:
		var card := _build_card(nation, index)
		_grid.add_child(card)
		_cards.append(card)
		index += 1
	_refresh_selection()
	# The rebuilt cards re-registered where they built — re-apply the
	# committed table (a no-op on the interim `{}`).
	RegistryLib.apply_layout("nationality_select")


## One card: flag color block, name, description and the start package — all
## read from the Nation record plus its referenced Port/ShipType records
## (docs/50-* §4.1 item 2). The parts are absolutely placed inside the card
## rect; the column/row come from the data order via [param index].
func _build_card(nation: Dictionary, index: int) -> Button:
	var nation_id := str(nation.get("id", ""))
	var card := Button.new()
	card.name = "Card_%s" % nation_id
	card.toggle_mode = true
	# §4.9 texture-mode mapping: a toggle card's selected state rides the
	# `Toggle` variation's pressed cell (the focus sheet ×TOGGLE_MODULATE —
	# the persistent ACCENT ring), not the momentary press dimming.
	card.theme_type_variation = "Toggle"
	card.position = Vector2(
		(index % NATIONS_PER_ROW) * CARD_PITCH.x,
		floori(index / float(NATIONS_PER_ROW)) * CARD_PITCH.y)
	card.size = CARD_SIZE
	card.pressed.connect(_on_card_pressed.bind(nation_id))

	# Head row: flag token inline with the nation name (docs/80-* §4.8).
	var flag := ColorRect.new()
	flag.name = "Flag"
	flag.color = PaletteLib.nation_color(str(nation.get("color", "#ffffff")))
	flag.position = Vector2(32, 32)
	flag.size = Vector2(32, 32)
	flag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(flag)

	var name_label := Label.new()
	name_label.name = "NationName"
	name_label.text = I18n.t(nation.get("name", {}))
	name_label.position = Vector2(64, 32)
	name_label.size = Vector2(256, 32)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(name_label)

	# Two lines at the theme's default font; the content-min floor guards
	# a longer locale at apply time (docs/80-* §4.8.9).
	var desc := Label.new()
	desc.name = "Description"
	desc.text = I18n.t(nation.get("description", {}))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.position = Vector2(32, 64)
	desc.size = Vector2(288, 64)
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(desc)

	var package := Label.new()
	package.name = "StartPackage"
	package.text = _package_text(nation)
	package.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	package.position = Vector2(32, 128)
	package.size = Vector2(288, 128)
	package.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(package)

	# Phase-12 W2-B: one data-derived id per card (the §7.1 nation order is
	# the locked data contract) + its persistent parts.
	RegistryLib.register("nationality_select", card, "cards.%s" % nation_id,
		{"role": RegistryLib.ROLE_BUTTON, "data_ordered": true})
	RegistryLib.register("nationality_select", flag, "cards.%s.flag" % nation_id)
	RegistryLib.register("nationality_select", name_label,
		"cards.%s.name" % nation_id)
	RegistryLib.register("nationality_select", desc, "cards.%s.desc" % nation_id)
	RegistryLib.register("nationality_select", package,
		"cards.%s.package" % nation_id)

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
	# The §4.9 sweep: selection reads through the unified pressed state
	# (the theme styles toggle buttons' pressed bg) — no font-color overrides.
	for card in _cards:
		card.button_pressed = card.name == "Card_%s" % _selected_id


func _on_back() -> void:
	GameState.change_scene(TITLE_SCENE)


## The Phase-3 world choice is retired (docs/70-* §4.9.8, docs/80-* §4.3):
## there is exactly one map, so S2 has no selector row and the map id always
## comes from `GameState`/`DataLoader.DEFAULT_MAP_ID` (`"world"`).


## Confirm: with the Phase-8 two-step flow (docs/80-* §4.2, §4.13), the S2
## confirm hands off to the creation screen (S20) — the nation travels in
## `CreationLib.pending_nation_id`, and S20's own confirm runs
## `GameState.new_game()` with the §4.1 state block and routing. The S19
## pre-game choices (`npc_preset`, `control_prefs`) are GameState run input
## that `new_game` reads BEFORE its reset (docs/80-* §4.6.3 amended
## 2026-10-31) — they live through this screen swap untouched, so the handoff
## preserves them by construction. With `route_after_confirm == false` (the
## headless-test switch) the legacy path runs: the whole new-game build, no
## routing, no handoff.
func confirm_selection() -> void:
	if _selected_id.is_empty():
		return
	if route_after_confirm:
		CreationLib.pending_nation_id = _selected_id
		if route_sink.is_valid():
			route_sink.call(CREATION_SCENE)
		else:
			GameState.change_scene(CREATION_SCENE)
	else:
		GameState.new_game(_selected_id, false)


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
