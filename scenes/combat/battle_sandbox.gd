extends Control
## S21 naval-battle sandbox (Phase 9, decision 15; docs/80-UI-UX.md §4.7.16,
## docs/60-COMBAT.md §4.12.1 `player_stats`, §4.12.4 zero-write branch,
## docs/10-DATA-SCHEMA.md §7.12 `sandbox.*` inventory).
##
## A full naval-battle editor opened from S1 (the 海战 button) and a
## **zero-write** surface: nothing here ever writes the save, `GameState`,
## `NpcFleets`, the phase-3 hooks or world routing. 开战 assembles a fixture
## encounter (`{sandbox: true, player_ships, enemy_ships, day, gold, seed,
## weather, player_stats}`) on `GameState.pending_encounter` — the SAME seam
## `world_map.gd` uses — and routes to S10; the battle's read-only after-action
## dialog returns here with the configuration kept in
## [member last_config] (a runtime-only static, never saved — that is what
## "configuration kept on return" means without touching `GameState`).
##
## **Forward-compat contract** (`80-*` §4.7.16): the export schema declares
## ALL planned fields from day one — `weather / wind_dir / current /
## deployment / morale / ai_level / archetype / formation` — but 开战 passes
## ONLY the fields the current engine consumes; the rest stay editor + export
## values until their waves land (9A wind/current, 9B morale, 9C/9D
## ai_level/archetype/formation, W3 deployment variant).
##
## **Strings** (`10-*` §7.12): every label comes from the `sandbox.*` /
## `battle.*` / `char.attr.*` / `world.weather.*` / `shipyard.slot.*`
## families through [method _t]. W2-B authors the `sandbox.*` values; until
## that merge each read falls back to the raw key or the raw value id (the
## `battle_screen._reason_text` convention) — no player-facing string is
## invented here.
##
## The whole editor is built in `_ready` from palette shapes + the default
## font (`80-*` §4.8); the `.tscn` carries the root node only. The side
## panels are plain `Panel` controls (not containers) so the editor rows keep
## their fixed 32 px-row geometry.

const PaletteLib := preload("res://scripts/palette.gd")
const BattleSimLib := preload("res://scripts/combat/battle_sim.gd")
const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")

const TITLE_SCENE := "res://scenes/title/title_screen.tscn"
const BATTLE_SCENE := "res://scenes/combat/battle_screen.tscn"

## Editor limits (docs/80-* §4.7.16 clamp rules).
const MAX_SHIPS := 5
const MIN_SHIPS := 1
const ATTR_MIN := 0
const ATTR_MAX := 100
const MORALE_MIN := 0
const MORALE_MAX := 100
const CURRENT_STRENGTH_MAX := 3
const DAY_MIN := 1
const SEED_MAX := 999999999
## Toast seconds (80-* §4.7: toasts are transient, 2.5 s).
const TOAST_SECONDS := 2.5

## The nine battle kinds (`10-*` §4.10 `ai_profiles` key set / `60-*` §4.9a):
## the 7 pass-through kinds + `navy` (hunter battles) + `tournament`.
const KINDS: Array[String] = [
	"trader", "coaster", "courier", "patrol", "privateer", "pirate",
	"treasure", "navy", "tournament",
]
const ARCHETYPES: Array[String] = ["aggressive", "balanced", "cautious"]
const FORMATIONS: Array[String] = ["line_ahead", "column", "screen", "swarm"]
## `60-*` §4.9c: 0 = T2 deterministic greedy, 1 = T3 one-ply lookahead.
const AI_LEVELS: Array = [0, 1]
const WEATHERS: Array[String] = ["calm", "fair", "strong", "storm"]
## `20-*` §4.7.1 wind-FROM tokens + the variable reading (`VAR` is an editor
## choice the engine's 9A consumer may resolve; the exported id stays a token
## of this set).
const WIND_DIRS: Array[String] = [
	"N", "NE", "E", "SE", "S", "SW", "W", "NW", "VAR",
]
const CURRENT_DIRS: Array[String] = [
	"N", "NE", "E", "SE", "S", "SW", "W", "NW",
]
const SEED_MODES: Array[String] = ["fixed", "random", "auto"]
const DEPLOYMENTS: Array[String] = ["standard", "tournament"]
## `50-*` §2.1 attribute keys (the labels reuse `char.attr.*`).
const ATTRIBUTES: Array[String] = [
	"constitution", "intellect", "charisma", "courage", "luck",
]
## The equipment slot the stats editor exposes (`10-*` §7.9 / `60-*` §4.11.12);
## the per-ship slots (figurehead / sail) are fixed in `_make_ship_row`.
const STATS_EQUIPMENT_SLOTS: Array = ["weapon", "armor"]
## The fixture carries no contact tile, so the §4.11.1 auto-seed formula
## evaluates at the origin — a deterministic, documented contract for
## `seed_mode = auto` (day + 0 + 0 + 0 + fleet.size() × 17).
const FIXTURE_CONTACT := Vector2i.ZERO

## **Doc-pinned profile fallback** (`10-*` §4.10 normative value table — the
## three editor-facing keys only). Used only while
## `DataLoader.npc_config.ai_profiles` is absent (the W2-A data merge); at
## runtime the data wins. `hunter` → the `navy` row (correction 8).
const DOC_PROFILE_FALLBACK: Dictionary = {
	"pirate": {"archetype": "aggressive", "formation": "swarm", "ai_level": 1},
	"privateer": {"archetype": "aggressive", "formation": "swarm", "ai_level": 1},
	"patrol": {"archetype": "balanced", "formation": "line_ahead", "ai_level": 1},
	"navy": {"archetype": "balanced", "formation": "line_ahead", "ai_level": 1},
	"tournament": {"archetype": "balanced", "formation": "line_ahead", "ai_level": 1},
	"treasure": {"archetype": "cautious", "formation": "screen", "ai_level": 0},
	"trader": {"archetype": "cautious", "formation": "column", "ai_level": 0},
	"coaster": {"archetype": "cautious", "formation": "column", "ai_level": 0},
	"courier": {"archetype": "cautious", "formation": "column", "ai_level": 0},
}

## The configuration carried across the S10 round-trip: written by
## [method start_battle] (开战), read in `_ready` to restore the editors.
## Runtime-only — never saved (`80-*` §4.7.16 "configuration kept on return"
## without a `GameState` write; preset persistence is out of scope, S4).
static var last_config: Dictionary = {}

## Routing seam (the `title_screen.route_to_nationality` convention): a test
## sets this false so the Esc edge records only the intent.
var route_to_title: bool = true

## The toast generation in flight, so a replaced toast does not hide its
## successor (the `market_screen` convention).
var _toast_generation := 0
## True while code is programming widgets (guards the re-entrant
## `text_changed` / `item_selected` handlers, the `shipyard_screen` pattern).
var _programming := false

# --- Widget handles (filled in `_ready`; tests read them) -------------------

var _background: ColorRect
var _title: Label
var _zero_write: Label
var _back_hint: Label
var _toast: Label
var _player_panel: Panel
var _enemy_panel: Panel
var _player_header: Label
var _enemy_header: Label
var _player_rows_box: VBoxContainer
var _enemy_rows_box: VBoxContainer
var _player_rows_scroll: ScrollContainer
var _enemy_rows_scroll: ScrollContainer
var _player_add: Button
var _player_remove: Button
var _enemy_add: Button
var _enemy_remove: Button
var _attribute_spins: Dictionary = {}
var _weapon_option: OptionButton
var _armor_option: OptionButton
var _player_morale_spin: SpinBox
var _kind_option: OptionButton
var _compose_check: CheckBox
var _enemy_captain_edit: LineEdit
var _ai_level_option: OptionButton
var _archetype_option: OptionButton
var _formation_option: OptionButton
var _enemy_morale_spin: SpinBox
var _day_spin: SpinBox
var _seed_mode_option: OptionButton
var _seed_spin: SpinBox
var _weather_option: OptionButton
var _wind_option: OptionButton
var _current_dir_option: OptionButton
var _current_strength_spin: SpinBox
var _deployment_option: OptionButton
var _start_button: Button
var _random_all_button: Button
var _import_button: Button
var _export_button: Button

## Per-ship widget rows: `{root, type, cannons, crew, durability, figurehead,
## sail, captain}` — fleet-index order.
var _player_rows: Array = []
var _enemy_rows: Array = []


func _ready() -> void:
	_build_static_widgets()
	_build_panels()
	_build_conditions_row()
	# The S10 round-trip restore (§4.7.16 "configuration kept on return");
	# otherwise the doc-example defaults seeded from the live run's reads.
	var restored: Dictionary = last_config if last_config is Dictionary else {}
	if restored.is_empty():
		restored = _default_config()
	_load_config(restored)


# --- Build ------------------------------------------------------------------

func _build_static_widgets() -> void:
	_background = ColorRect.new()
	_background.name = "Background"
	_background.color = PaletteLib.PANEL_BG
	_background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_background)

	_title = Label.new()
	_title.name = "Title"
	_title.text = _t("sandbox.title")
	_title.add_theme_font_size_override("font_size", 26)
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_title.position = Vector2(16, 8)
	_title.size = Vector2(640, 32)
	add_child(_title)

	# The persistent zero-write notice (§4.7.16) — always visible.
	_zero_write = Label.new()
	_zero_write.name = "ZeroWrite"
	_zero_write.text = _t("sandbox.zero_write")
	_zero_write.add_theme_font_size_override("font_size", 14)
	_zero_write.add_theme_color_override("font_color", PaletteLib.WARN)
	_zero_write.position = Vector2(16, 42)
	_zero_write.size = Vector2(900, 20)
	add_child(_zero_write)

	# `Esc` → S1 (§4.2); the corner hint names the edge.
	_back_hint = Label.new()
	_back_hint.name = "BackHint"
	_back_hint.text = "Esc · %s" % _t("sandbox.back")
	_back_hint.add_theme_font_size_override("font_size", 14)
	_back_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_back_hint.position = Vector2(1080, 12)
	_back_hint.size = Vector2(184, 20)
	_back_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_back_hint)

	_toast = Label.new()
	_toast.name = "Toast"
	_toast.visible = false
	_toast.add_theme_font_size_override("font_size", 14)
	_toast.add_theme_color_override("font_color", PaletteLib.TEXT)
	_toast.position = Vector2(340, 696)
	_toast.size = Vector2(600, 22)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_toast)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style


func _build_panels() -> void:
	_player_panel = Panel.new()
	_player_panel.name = "PlayerPanel"
	_player_panel.position = Vector2(16, 68)
	_player_panel.size = Vector2(612, 480)
	_player_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_player_panel)
	_enemy_panel = Panel.new()
	_enemy_panel.name = "EnemyPanel"
	_enemy_panel.position = Vector2(652, 68)
	_enemy_panel.size = Vector2(612, 480)
	_enemy_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_enemy_panel)

	_player_header = _panel_header(_player_panel, "sandbox.player")
	_enemy_header = _panel_header(_enemy_panel, "sandbox.enemy")

	# Per-ship rows live in a scroll so five ship blocks always fit.
	_player_rows_scroll = ScrollContainer.new()
	_player_rows_scroll.name = "PlayerShipRows"
	_player_rows_scroll.position = Vector2(PaletteLib.MARGIN, 40)
	_player_rows_scroll.size = Vector2(612 - 2 * PaletteLib.MARGIN, 356)
	_player_rows_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_player_panel.add_child(_player_rows_scroll)
	_player_rows_box = VBoxContainer.new()
	_player_rows_box.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	_player_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_player_rows_scroll.add_child(_player_rows_box)
	_enemy_rows_scroll = ScrollContainer.new()
	_enemy_rows_scroll.name = "EnemyShipRows"
	_enemy_rows_scroll.position = Vector2(PaletteLib.MARGIN, 40)
	_enemy_rows_scroll.size = Vector2(612 - 2 * PaletteLib.MARGIN, 356)
	_enemy_rows_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_enemy_panel.add_child(_enemy_rows_scroll)
	_enemy_rows_box = VBoxContainer.new()
	_enemy_rows_box.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	_enemy_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_enemy_rows_scroll.add_child(_enemy_rows_box)

	# Fleet add/remove (`sandbox.ship.add` / `.remove`, 1..5 ships per side).
	_player_add = _row_button(_player_panel, "sandbox.ship.add",
		Vector2(PaletteLib.MARGIN, 404))
	_player_remove = _row_button(_player_panel, "sandbox.ship.remove",
		Vector2(200, 404))
	_player_add.pressed.connect(func() -> void: add_ship_row("player"))
	_player_remove.pressed.connect(func() -> void: remove_ship_row("player"))
	_enemy_add = _row_button(_enemy_panel, "sandbox.ship.add",
		Vector2(PaletteLib.MARGIN, 404))
	_enemy_remove = _row_button(_enemy_panel, "sandbox.ship.remove",
		Vector2(200, 404))
	_enemy_add.pressed.connect(func() -> void: add_ship_row("enemy"))
	_enemy_remove.pressed.connect(func() -> void: remove_ship_row("enemy"))

	_build_player_stats_block()
	_build_enemy_options()


func _panel_header(panel: Panel, key: String) -> Label:
	var label := Label.new()
	label.text = _t(key)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", PaletteLib.ACCENT)
	label.position = Vector2(PaletteLib.MARGIN, 10)
	label.size = Vector2(320, 24)
	panel.add_child(label)
	return label


func _row_button(panel: Panel, key: String, at: Vector2) -> Button:
	var button := Button.new()
	button.text = _t(key)
	button.custom_minimum_size = Vector2(160, 32)
	button.position = at
	button.size = button.custom_minimum_size
	panel.add_child(button)
	return button


func _field_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


## A compact 88 px field label (clipped) for the dense editor lines.
func _small_label(text: String) -> Label:
	var label := _field_label(text)
	label.custom_minimum_size = Vector2(88, 0)
	label.clip_text = true
	return label


func _spin(minimum: int, maximum: int, value: int, width := 100) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 1
	spin.value = clampi(value, minimum, maximum)
	spin.custom_minimum_size = Vector2(width, float(PaletteLib.ROW_H))
	return spin


func _option(width := 150) -> OptionButton:
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(width, float(PaletteLib.ROW_H))
	return option


## Fills `option` with `ids`, one item per id, labelled `key_prefix.<id>`
## (the raw id shows until W2-B authors the family). Selects the first.
func _fill_option(option: OptionButton, ids: Array, key_prefix: String) -> void:
	option.clear()
	for id in ids:
		option.add_item(_t_id(key_prefix, str(id)))
		option.set_item_metadata(option.item_count - 1, id)
	if not ids.is_empty():
		_select_option(option, ids[0])


func _select_option(option: OptionButton, id) -> void:
	for index in option.item_count:
		if str(option.get_item_metadata(index)) == str(id):
			option.select(index)
			return


func _option_value(option: OptionButton):
	if option.selected < 0 or option.selected >= option.item_count:
		return ""
	return option.get_item_metadata(option.selected)


## The editor's equipment options for `slot`: the empty slot first (the "—"
## marker), then the `data/equipment.json` items of that slot in file order.
func _fill_equipment_option(option: OptionButton, slot: String) -> void:
	option.clear()
	option.add_item("—")
	option.set_item_metadata(0, "")
	for id in _equipment_ids(slot):
		option.add_item(str(id))
		option.set_item_metadata(option.item_count - 1, id)
	_select_option(option, "")


func _equipment_ids(slot: String) -> Array:
	var out: Array = []
	var items = DataLoader.equipment_list
	if not (items is Array):
		return out
	for item in items:
		if item is Dictionary and str(item.get("slot", "")) == slot:
			out.append(str(item.get("id", "")))
	return out


func _hull_row(hull_id: String) -> Dictionary:
	for row in DataLoader.ship_types_list:
		if row is Dictionary and str(row.get("id", "")) == hull_id:
			return row
	return {}


## One editable ship block (§4.7.16 panel shape): hull, escort captain id,
## cannons, crew, durability, figurehead + sail — three 32 px lines.
func _make_ship_row(side: String) -> Dictionary:
	var root := VBoxContainer.new()
	root.name = "%sShip%d" % [side.capitalize(), ship_rows(side).size()]
	root.add_theme_constant_override("separation", 0)

	var line1 := HBoxContainer.new()
	line1.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	var type := _option(150)
	for hull in DataLoader.ship_types_list:
		if not (hull is Dictionary) or str(hull.get("id", "")).is_empty():
			continue
		type.add_item(str(hull["id"]))
		type.set_item_metadata(type.item_count - 1, str(hull["id"]))
	line1.add_child(_small_label(_t("sandbox.ship.type")))
	line1.add_child(type)
	var captain := LineEdit.new()
	captain.placeholder_text = ""
	captain.custom_minimum_size = Vector2(150, float(PaletteLib.ROW_H))
	line1.add_child(_small_label(_t("sandbox.ship.captain")))
	line1.add_child(captain)
	root.add_child(line1)

	var line2 := HBoxContainer.new()
	line2.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	var cannons := _spin(0, 0, 0, 80)
	var crew := _spin(0, 0, 0, 80)
	var durability := _spin(1, 1, 1, 80)
	line2.add_child(_small_label(_t("sandbox.ship.cannons")))
	line2.add_child(cannons)
	line2.add_child(_small_label(_t("sandbox.ship.crew")))
	line2.add_child(crew)
	line2.add_child(_small_label(_t("sandbox.ship.durability")))
	line2.add_child(durability)
	root.add_child(line2)

	var line3 := HBoxContainer.new()
	line3.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	var figurehead := _option(150)
	var sail := _option(150)
	_fill_equipment_option(figurehead, "figurehead")
	_fill_equipment_option(sail, "sail")
	line3.add_child(_small_label(_t("shipyard.slot.figurehead")))
	line3.add_child(figurehead)
	line3.add_child(_small_label(_t("shipyard.slot.sail")))
	line3.add_child(sail)
	root.add_child(line3)

	var row := {
		"root": root, "type": type, "cannons": cannons, "crew": crew,
		"durability": durability, "figurehead": figurehead, "sail": sail,
		"captain": captain,
	}
	type.item_selected.connect(func(_index: int) -> void:
		_clamp_row(row))
	captain.text_changed.connect(func(_text: String) -> void:
		if side == "enemy":
			_sync_enemy_captain(true))
	var box := _player_rows_box if side == "player" else _enemy_rows_box
	box.add_child(root)
	if side == "player":
		_player_rows.append(row)
	else:
		_enemy_rows.append(row)
	_clamp_row(row)
	return row


## Re-clamps one row's hull-dependent ranges (§4.7.16 clamp table): cannons
## 0..armament_slots, crew crew_min..crew_max, durability 1..base durability
## (figurehead durability deltas are W3 territory — the editor clamps to the
## hull row's own value).
func _clamp_row(row: Dictionary) -> void:
	if _programming:
		return
	_programming = true
	var hull := _hull_row(str(_option_value(row["type"])))
	var armament := int(hull.get("armament_slots", 0))
	var crew_min := int(hull.get("crew_min", 0))
	var crew_max := maxi(int(hull.get("crew_max", crew_min)), crew_min)
	var max_durability := maxi(int(hull.get("durability", 1)), 1)
	var cannons: SpinBox = row["cannons"]
	var crew: SpinBox = row["crew"]
	var durability: SpinBox = row["durability"]
	cannons.max_value = armament
	cannons.value = clampi(int(cannons.value), 0, armament)
	crew.min_value = crew_min
	crew.max_value = crew_max
	crew.value = clampi(int(crew.value), crew_min, crew_max)
	durability.min_value = 1
	durability.max_value = max_durability
	durability.value = clampi(int(durability.value), 1, max_durability)
	_programming = false


## The §4.12.1 `player_stats` seam inputs (left panel, beside the ships):
## five attributes + weapon/armor, plus the initial morale (editor-only
## until 9B). Defaults read the live run's values — reads are zero-write.
func _build_player_stats_block() -> void:
	var block := VBoxContainer.new()
	block.name = "PlayerStats"
	block.add_theme_constant_override("separation", 0)
	var header := _field_label(_t("sandbox.player"))
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	block.add_child(header)

	var attrs_row := HBoxContainer.new()
	attrs_row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	for key in ATTRIBUTES:
		var label := _field_label(_t("char.attr.%s" % key))
		label.custom_minimum_size = Vector2(96, 0)
		label.clip_text = true
		attrs_row.add_child(label)
		var spin := _spin(ATTR_MIN, ATTR_MAX, _default_attribute(key), 72)
		_attribute_spins[key] = spin
		attrs_row.add_child(spin)
	block.add_child(attrs_row)

	var gear_row := HBoxContainer.new()
	gear_row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	_weapon_option = _option(150)
	_armor_option = _option(150)
	_fill_equipment_option(_weapon_option, "weapon")
	_fill_equipment_option(_armor_option, "armor")
	gear_row.add_child(_small_label(_t("shipyard.slot.weapon")))
	gear_row.add_child(_weapon_option)
	gear_row.add_child(_small_label(_t("shipyard.slot.armor")))
	gear_row.add_child(_armor_option)
	block.add_child(gear_row)

	var morale_row := HBoxContainer.new()
	morale_row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	morale_row.add_child(_small_label(_t("sandbox.morale.player")))
	_player_morale_spin = _spin(MORALE_MIN, MORALE_MAX, 50)
	morale_row.add_child(_player_morale_spin)
	block.add_child(morale_row)

	_player_rows_box.add_child(block)


## The enemy panel's static editors (kind / compose / captain / ai_level /
## archetype / formation / morale) — `ai_level` / `archetype` / `formation`
## ride the forward-compatible export schema and take effect as their waves
## land (9C/9D).
func _build_enemy_options() -> void:
	var block := VBoxContainer.new()
	block.name = "EnemyOptions"
	block.add_theme_constant_override("separation", 0)

	var kind_row := HBoxContainer.new()
	kind_row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	_kind_option = _option(150)
	_fill_option(_kind_option, KINDS, "sandbox.kind")
	_kind_option.item_selected.connect(func(_index: int) -> void:
		_apply_kind_profile(str(_option_value(_kind_option))))
	kind_row.add_child(_small_label(_t("sandbox.enemy.kind")))
	kind_row.add_child(_kind_option)
	var compose_label := _small_label(_t("sandbox.enemy.compose"))
	compose_label.custom_minimum_size = Vector2(130, 0)
	_compose_check = CheckBox.new()
	_compose_check.custom_minimum_size = Vector2(60, float(PaletteLib.ROW_H))
	_compose_check.toggled.connect(_on_compose_toggled)
	kind_row.add_child(compose_label)
	kind_row.add_child(_compose_check)
	block.add_child(kind_row)

	var captain_row := HBoxContainer.new()
	captain_row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	captain_row.add_child(_small_label(_t("sandbox.ship.captain")))
	_enemy_captain_edit = LineEdit.new()
	_enemy_captain_edit.custom_minimum_size = Vector2(200, float(PaletteLib.ROW_H))
	_enemy_captain_edit.text_changed.connect(func(_text: String) -> void:
		_sync_enemy_captain(false))
	captain_row.add_child(_enemy_captain_edit)
	block.add_child(captain_row)

	var ai_row := HBoxContainer.new()
	ai_row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	_ai_level_option = _option(120)
	_ai_level_option.add_item(_t_id("sandbox.ai_level", "t2"))
	_ai_level_option.set_item_metadata(0, 0)
	_ai_level_option.add_item(_t_id("sandbox.ai_level", "t3"))
	_ai_level_option.set_item_metadata(1, 1)
	_ai_level_option.select(0)
	ai_row.add_child(_small_label(_t("sandbox.ai_level")))
	ai_row.add_child(_ai_level_option)
	_archetype_option = _option(150)
	_fill_option(_archetype_option, ARCHETYPES, "sandbox.archetype")
	ai_row.add_child(_small_label(_t("sandbox.archetype")))
	ai_row.add_child(_archetype_option)
	_formation_option = _option(150)
	_fill_option(_formation_option, FORMATIONS, "battle.formation")
	ai_row.add_child(_small_label(_t("sandbox.formation")))
	ai_row.add_child(_formation_option)
	block.add_child(ai_row)

	var morale_row := HBoxContainer.new()
	morale_row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	morale_row.add_child(_small_label(_t("sandbox.morale.enemy")))
	_enemy_morale_spin = _spin(MORALE_MIN, MORALE_MAX, 50)
	morale_row.add_child(_enemy_morale_spin)
	block.add_child(morale_row)

	_enemy_rows_box.add_child(block)


## One-click `compose_enemy` generation toggle (§4.7.16): ON hides the per-ship
## rows; the enemy fleet comes from `AiFleet.compose_enemy(kind, day, rng)` at
## 开战 time.
func _on_compose_toggled(pressed: bool) -> void:
	_enemy_rows_scroll.visible = not pressed
	_enemy_add.visible = not pressed
	_enemy_remove.visible = not pressed


## The enemy panel's captain field IS enemy flagship row 0's captain id (the
## export schema has no enemy-level key — the value rides per-ship
## `captain_id`, the normative shape). Syncs the two editors either way;
## `from_row` is true when row 0's own LineEdit changed.
func _sync_enemy_captain(from_row: bool) -> void:
	if _programming or _enemy_rows.is_empty():
		return
	_programming = true
	if from_row:
		_enemy_captain_edit.text = \
			str((_enemy_rows[0] as Dictionary)["captain"].text)
	else:
		(_enemy_rows[0] as Dictionary)["captain"].text = _enemy_captain_edit.text
	_programming = false


## On a kind change the three profile selectors follow the kind's
## `ai_profiles` row (`10-*` §4.10; the doc-pinned fallback while the data
## wave is unmerged). Editor convenience only — the values stay
## export/dormant until 9C/9D.
func _apply_kind_profile(kind: String) -> void:
	var profile := _profile_default(kind)
	_select_option(_archetype_option, str(profile.get("archetype", "balanced")))
	_select_option(_formation_option, str(profile.get("formation", "column")))
	_ai_level_option.select(1 if int(profile.get("ai_level", 0)) == 1 else 0)


func _profile_default(kind: String) -> Dictionary:
	var kind_id := kind
	if kind_id == "hunter":
		# Correction-8 lookup rule: a hunter battle reads the navy row.
		kind_id = "navy"
	var profiles = DataLoader.npc_config.get("ai_profiles", {}) \
		if DataLoader.npc_config is Dictionary else {}
	if profiles is Dictionary and (profiles as Dictionary).has(kind_id):
		var row = (profiles as Dictionary)[kind_id]
		if row is Dictionary:
			return row
	return DOC_PROFILE_FALLBACK.get(kind_id, {
		"archetype": "balanced", "formation": "column", "ai_level": 0,
	})


func _build_conditions_row() -> void:
	# Bottom panel: the conditions rows + the four action buttons (§4.7.16).
	var panel := PanelContainer.new()
	panel.name = "ConditionsPanel"
	panel.position = Vector2(16, 556)
	panel.size = Vector2(1248, 152)
	panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	panel.add_child(box)

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	_day_spin = _spin(DAY_MIN, 9999, 1, 90)
	row1.add_child(_small_label(_t("sandbox.day")))
	row1.add_child(_day_spin)
	_seed_mode_option = _option(110)
	_fill_option(_seed_mode_option, SEED_MODES, "sandbox.seed")
	row1.add_child(_small_label(_t("sandbox.seed")))
	row1.add_child(_seed_mode_option)
	_seed_spin = _spin(0, SEED_MAX, 1, 130)
	row1.add_child(_seed_spin)
	_seed_mode_option.item_selected.connect(func(_index: int) -> void:
		_seed_spin.visible = str(_option_value(_seed_mode_option)) == "fixed")
	_weather_option = _option(110)
	_fill_option(_weather_option, WEATHERS, "world.weather")
	row1.add_child(_small_label(_t("sandbox.weather")))
	row1.add_child(_weather_option)
	_deployment_option = _option(140)
	_fill_option(_deployment_option, DEPLOYMENTS, "sandbox.deployment")
	row1.add_child(_small_label(_t("sandbox.deployment")))
	row1.add_child(_deployment_option)
	box.add_child(row1)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	_wind_option = _option(90)
	_fill_option(_wind_option, WIND_DIRS, "sandbox.dir")
	row2.add_child(_small_label(_t("sandbox.wind_dir")))
	row2.add_child(_wind_option)
	_current_dir_option = _option(90)
	_fill_option(_current_dir_option, CURRENT_DIRS, "sandbox.dir")
	row2.add_child(_small_label(_t("sandbox.current")))
	row2.add_child(_current_dir_option)
	_current_strength_spin = _spin(0, CURRENT_STRENGTH_MAX, 0, 70)
	row2.add_child(_current_strength_spin)
	box.add_child(row2)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", PaletteLib.MARGIN)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	_start_button = Button.new()
	_start_button.text = _t("sandbox.start")
	_random_all_button = Button.new()
	_random_all_button.text = _t("sandbox.random_all")
	_import_button = Button.new()
	_import_button.text = _t("sandbox.import")
	_export_button = Button.new()
	_export_button.text = _t("sandbox.export")
	for button in [_start_button, _random_all_button, _import_button,
			_export_button]:
		button.custom_minimum_size = Vector2(140, float(PaletteLib.BUTTON_H))
		buttons.add_child(button)
	_start_button.pressed.connect(start_battle)
	_random_all_button.pressed.connect(randomize_all)
	_import_button.pressed.connect(_on_import_pressed)
	_export_button.pressed.connect(_on_export_pressed)
	box.add_child(buttons)


# --- Editors & clamps (§4.7.16: the clamp table is IMMEDIATE) ---------------

func ship_rows(side: String) -> Array:
	return _player_rows if side == "player" else _enemy_rows


## Copies of the per-ship widget rows (tests/hosts).
func player_rows() -> Array:
	return _player_rows.duplicate()


func enemy_rows() -> Array:
	return _enemy_rows.duplicate()


## Adds one ship row (a fresh default of the side's flagship hull). Refused
## beyond [constant MAX_SHIPS] (§4.7.16: 1–5 ships per side).
func add_ship_row(side: String) -> bool:
	if ship_rows(side).size() >= MAX_SHIPS:
		return false
	var hull := "sloop"
	if not ship_rows(side).is_empty():
		hull = str(_option_value((ship_rows(side)[0] as Dictionary)["type"]))
	_make_ship_row(side)
	_write_row(ship_rows(side)[ship_rows(side).size() - 1],
		_default_ship_state(hull))
	_refresh_row_headers(side)
	return true


## Removes the last ship row. Refused at [constant MIN_SHIPS].
func remove_ship_row(side: String) -> bool:
	var rows := ship_rows(side)
	if rows.size() <= MIN_SHIPS:
		return false
	var row: Dictionary = rows[rows.size() - 1]
	var root: Control = row["root"]
	root.get_parent().remove_child(root)
	root.queue_free()
	if side == "player":
		_player_rows.remove_at(_player_rows.size() - 1)
	else:
		_enemy_rows.remove_at(_enemy_rows.size() - 1)
	_refresh_row_headers(side)
	if side == "enemy" and not _enemy_rows.is_empty():
		_sync_enemy_captain(true)
	return true


func _refresh_row_headers(side: String) -> void:
	for index in ship_rows(side).size():
		var row: Dictionary = ship_rows(side)[index]
		var label: Label = (row["root"] as Control).get_child(0).get_child(0)
		label.text = _tfmt("sandbox.ship", {"index": index + 1},
			"ship {index}")


## Immediate UI-layer clamps (§4.7.16): hull-driven ranges re-apply to every
## row; the SpinBox min/max bounds clamp attrs/morale/day/strength on change.
## An invalid combination never reaches 开战 — [method build_encounter] and
## [method export_config] call this first.
func apply_clamps() -> void:
	for side in ["player", "enemy"]:
		for row in ship_rows(side):
			_clamp_row(row)
	_day_spin.value = float(maxi(int(_day_spin.value), DAY_MIN))
	_current_strength_spin.value = float(clampi(
		int(_current_strength_spin.value), 0, CURRENT_STRENGTH_MAX))
	for key in ATTRIBUTES:
		var spin: SpinBox = _attribute_spins.get(key)
		if spin != null:
			spin.value = float(clampi(int(spin.value), ATTR_MIN, ATTR_MAX))
	_player_morale_spin.value = float(clampi(int(_player_morale_spin.value),
		MORALE_MIN, MORALE_MAX))
	_enemy_morale_spin.value = float(clampi(int(_enemy_morale_spin.value),
		MORALE_MIN, MORALE_MAX))


# --- State <-> editors ------------------------------------------------------

## A default §4.7.16 ship state for `hull_id` (full cannon load, min crew,
## base durability — derived from the hull row, never invented).
func _default_ship_state(hull_id: String) -> Dictionary:
	var hull := _hull_row(hull_id)
	if hull.is_empty() and not (DataLoader.ship_types_list as Array).is_empty():
		var first = DataLoader.ship_types_list[0]
		hull = first if first is Dictionary else {}
		hull_id = str(hull.get("id", hull_id))
	return {
		"ship_type_id": hull_id,
		"cannons": int(hull.get("armament_slots", 0)),
		"crew": int(hull.get("crew_min", 0)),
		"durability": int(hull.get("durability", 1)),
		"figurehead": "",
		"sail": "",
		"captain_id": "",
	}


## The live attribute read (headless/empty player → the `50-*` base 10).
func _default_attribute(key: String) -> int:
	var char_lib: Variant = CharacterLib
	if char_lib != null and char_lib.has_method("attribute"):
		return clampi(int(char_lib.attribute(key)), ATTR_MIN, ATTR_MAX)
	return 10


## The doc-example defaults (`80-*` §4.7.16) with the player block seeded
## from the live run's reads (attributes/equipment — reads are zero-write).
func _default_config() -> Dictionary:
	var attributes: Dictionary = {}
	for key in ATTRIBUTES:
		attributes[key] = _default_attribute(key)
	var equipment = GameState.player.get("equipment", {}) \
		if GameState.player is Dictionary else {}
	var stats_gear := {"weapon": "", "armor": ""}
	if equipment is Dictionary:
		for slot in STATS_EQUIPMENT_SLOTS:
			stats_gear[slot] = str(equipment.get(slot, ""))
	var pirate := _profile_default("pirate")
	var attributes_gear: Dictionary = attributes.duplicate(true)
	for slot in STATS_EQUIPMENT_SLOTS:
		attributes_gear[slot] = stats_gear[slot]
	return {
		"version": 1,
		"kind": "sailage_sandbox",
		"player": {
			"stats": attributes_gear,
			"morale": 50,
			"ships": [_default_ship_state("brigantine")],
		},
		"enemy": {
			"kind": "pirate",
			"ai_level": int(pirate.get("ai_level", 1)),
			"archetype": str(pirate.get("archetype", "aggressive")),
			"formation": str(pirate.get("formation", "swarm")),
			"morale": 50,
			"compose": false,
			"ships": [_default_ship_state("sloop")],
		},
		"conditions": {
			"day": 1,
			"seed_mode": "fixed",
			"seed": 1,
			"weather": "fair",
			"wind_dir": "E",
			"current": {"dir": "E", "strength": 0},
			"deployment": "standard",
		},
	}


## Reads one row's editors into a ship-state dict (values already clamped by
## the widgets).
func _read_row(row: Dictionary) -> Dictionary:
	return {
		"ship_type_id": str(_option_value(row["type"])),
		"cannons": int((row["cannons"] as SpinBox).value),
		"crew": int((row["crew"] as SpinBox).value),
		"durability": int((row["durability"] as SpinBox).value),
		"figurehead": str(_option_value(row["figurehead"])),
		"sail": str(_option_value(row["sail"])),
		"captain_id": str((row["captain"] as LineEdit).text).strip_edges(),
	}


## Programs one row's editors from a ship-state dict (values clamped). The
## hull-driven ranges are WIDENED for the new hull before the values are
## written — otherwise a brigantine write into a latin-bounded row would
## clamp to the old maximum.
func _write_row(row: Dictionary, state: Dictionary) -> void:
	_programming = true
	_select_option(row["type"], str(state.get("ship_type_id", "")))
	_programming = false
	_clamp_row(row)
	_programming = true
	(row["cannons"] as SpinBox).value = float(int(state.get("cannons", 0)))
	(row["crew"] as SpinBox).value = float(int(state.get("crew", 0)))
	(row["durability"] as SpinBox).value = float(int(state.get("durability", 1)))
	_select_option(row["figurehead"], str(state.get("figurehead", "")))
	_select_option(row["sail"], str(state.get("sail", "")))
	(row["captain"] as LineEdit).text = str(state.get("captain_id", ""))
	_programming = false
	_clamp_row(row)


## Rebuilds a side's rows to `states.size()` entries (the round-trip
## contract: the same list reproduces the same rows), merging per field so a
## partial row dict falls back to the row's current editor values.
func _write_rows(side: String, states: Array) -> void:
	var rows := ship_rows(side)
	while rows.size() > maxi(states.size(), MIN_SHIPS):
		remove_ship_row(side)
	while rows.size() < states.size() and rows.size() < MAX_SHIPS:
		add_ship_row(side)
	for index in ship_rows(side).size():
		var current := _read_row(ship_rows(side)[index])
		var state: Dictionary = states[index] if index < states.size() \
			and states[index] is Dictionary else {}
		var merged := current.duplicate(true)
		for key in ["ship_type_id", "cannons", "crew", "durability",
				"figurehead", "sail", "captain_id"]:
			if state.has(key):
				merged[key] = state[key]
		_write_row(ship_rows(side)[index], merged)
	_refresh_row_headers(side)


## Loads a full §4.7.16 config: unknown keys ignored, missing keys fall back
## to the current editor values.
func _load_config(data: Dictionary) -> void:
	_programming = true
	var player: Dictionary = data.get("player", {}) \
		if data.get("player", {}) is Dictionary else {}
	var enemy: Dictionary = data.get("enemy", {}) \
		if data.get("enemy", {}) is Dictionary else {}
	var conditions: Dictionary = data.get("conditions", {}) \
		if data.get("conditions", {}) is Dictionary else {}

	var stats: Dictionary = player.get("stats", {}) \
		if player.get("stats", {}) is Dictionary else {}
	for key in ATTRIBUTES:
		var spin: SpinBox = _attribute_spins.get(key)
		if spin != null and stats.has(key):
			spin.value = float(clampi(int(stats[key]), ATTR_MIN, ATTR_MAX))
	_select_option(_weapon_option,
		str(stats.get("weapon", _option_value(_weapon_option))))
	_select_option(_armor_option,
		str(stats.get("armor", _option_value(_armor_option))))
	_player_morale_spin.value = float(clampi(
		int(player.get("morale", int(_player_morale_spin.value))),
		MORALE_MIN, MORALE_MAX))

	_select_option(_kind_option,
		str(enemy.get("kind", _option_value(_kind_option))))
	_ai_level_option.select(1 if int(enemy.get("ai_level",
		int(_option_value(_ai_level_option)))) == 1 else 0)
	_select_option(_archetype_option,
		str(enemy.get("archetype", _option_value(_archetype_option))))
	_select_option(_formation_option,
		str(enemy.get("formation", _option_value(_formation_option))))
	_enemy_morale_spin.value = float(clampi(
		int(enemy.get("morale", int(_enemy_morale_spin.value))),
		MORALE_MIN, MORALE_MAX))
	_compose_check.button_pressed = bool(enemy.get("compose",
		_compose_check.button_pressed))
	_programming = false
	if enemy.has("ships") and enemy["ships"] is Array:
		_write_rows("enemy", enemy["ships"])
	if player.has("ships") and player["ships"] is Array:
		_write_rows("player", player["ships"])
	_sync_enemy_captain(true)

	_day_spin.value = float(maxi(
		int(conditions.get("day", int(_day_spin.value))), DAY_MIN))
	_select_option(_seed_mode_option,
		str(conditions.get("seed_mode", _option_value(_seed_mode_option))))
	_seed_spin.value = float(clampi(
		int(conditions.get("seed", int(_seed_spin.value))), 0, SEED_MAX))
	_seed_spin.visible = str(_option_value(_seed_mode_option)) == "fixed"
	_select_option(_weather_option,
		str(conditions.get("weather", _option_value(_weather_option))))
	_select_option(_wind_option,
		str(conditions.get("wind_dir", _option_value(_wind_option))))
	var current: Dictionary = conditions.get("current", {}) \
		if conditions.get("current", {}) is Dictionary else {}
	_select_option(_current_dir_option,
		str(current.get("dir", _option_value(_current_dir_option))))
	_current_strength_spin.value = float(clampi(
		int(current.get("strength", int(_current_strength_spin.value))),
		0, CURRENT_STRENGTH_MAX))
	_select_option(_deployment_option,
		str(conditions.get("deployment", _option_value(_deployment_option))))
	apply_clamps()
	_on_compose_toggled(_compose_check.button_pressed)


# --- Export / import (forward-compatible §4.7.16 schema) --------------------

## The normative export dict — fixed key order, all planned fields (values
## already clamped). `JSON.stringify` of this is byte-stable, so the
## export → import → re-export round trip is byte-identical.
func export_config() -> Dictionary:
	apply_clamps()
	var stats: Dictionary = {}
	for key in ATTRIBUTES:
		stats[key] = int((_attribute_spins[key] as SpinBox).value)
	stats["weapon"] = str(_option_value(_weapon_option))
	stats["armor"] = str(_option_value(_armor_option))
	return {
		"version": 1,
		"kind": "sailage_sandbox",
		"player": {
			"stats": stats,
			"morale": int(_player_morale_spin.value),
			"ships": _export_ships("player"),
		},
		"enemy": {
			"kind": str(_option_value(_kind_option)),
			"ai_level": int(_option_value(_ai_level_option)),
			"archetype": str(_option_value(_archetype_option)),
			"formation": str(_option_value(_formation_option)),
			"morale": int(_enemy_morale_spin.value),
			"compose": bool(_compose_check.button_pressed),
			"ships": _export_ships("enemy"),
		},
		"conditions": {
			"day": int(_day_spin.value),
			"seed_mode": str(_option_value(_seed_mode_option)),
			"seed": int(_seed_spin.value),
			"weather": str(_option_value(_weather_option)),
			"wind_dir": str(_option_value(_wind_option)),
			"current": {
				"dir": str(_option_value(_current_dir_option)),
				"strength": int(_current_strength_spin.value),
			},
			"deployment": str(_option_value(_deployment_option)),
		},
	}


func _export_ships(side: String) -> Array:
	var out: Array = []
	for row in ship_rows(side):
		var state := _read_row(row)
		out.append({
			"ship_type_id": state["ship_type_id"],
			"cannons": state["cannons"],
			"crew": state["crew"],
			"durability": state["durability"],
			"equipment": {
				"figurehead": state["figurehead"],
				"sail": state["sail"],
			},
			"captain_id": state["captain_id"],
		})
	return out


## The export JSON (compact, deterministic key order).
func export_json() -> String:
	return JSON.stringify(export_config())


## Parses and applies a clipboard payload. Unknown keys are ignored; missing
## keys fall back to the current editor values; non-JSON / wrong-envelope
## payloads return false (the `sandbox.import.invalid` toast).
func import_json(text: String) -> bool:
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var data: Dictionary = parsed
	if str(data.get("kind", "")) != "sailage_sandbox" \
			or int(data.get("version", 0)) != 1:
		return false
	_load_config(data)
	return true


func _on_export_pressed() -> void:
	DisplayServer.clipboard_set(export_json())
	_show_toast(_t("sandbox.export.ok"))


func _on_import_pressed() -> void:
	if import_json(DisplayServer.clipboard_get()):
		_show_toast(_t("sandbox.import.ok"))
	else:
		_show_toast(_t("sandbox.import.invalid"))


## Transient bottom-center toast (`80-*` §4.7: 2.5 s, max one visible).
func _show_toast(text: String) -> void:
	_toast_generation += 1
	var generation := _toast_generation
	_toast.text = text
	_toast.visible = true
	await get_tree().create_timer(TOAST_SECONDS).timeout
	if not is_instance_valid(_toast) or not is_inside_tree():
		return
	if generation == _toast_generation:
		_toast.visible = false


# --- 随机全部 -----------------------------------------------------------------

## Randomizes every editor into its clamped range (the editors clamp on
## write, so an invalid combination can never reach 开战). Its own RNG — an
## editor convenience, never the battle stream.
func randomize_all() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for side in ["player", "enemy"]:
		var count := rng.randi_range(MIN_SHIPS, MAX_SHIPS)
		while ship_rows(side).size() < count:
			add_ship_row(side)
		while ship_rows(side).size() > count:
			remove_ship_row(side)
		for row in ship_rows(side):
			_write_row(row, {
				"ship_type_id": _random_hull(rng),
				"cannons": rng.randi_range(0, 64),
				"crew": rng.randi_range(1, 200),
				"durability": rng.randi_range(1, 500),
				"figurehead": _random_equipment(rng, "figurehead"),
				"sail": _random_equipment(rng, "sail"),
				"captain_id": "",
			})
	for key in ATTRIBUTES:
		var spin: SpinBox = _attribute_spins.get(key)
		if spin != null:
			spin.value = float(rng.randi_range(ATTR_MIN, ATTR_MAX))
	_select_option(_weapon_option, _random_equipment(rng, "weapon"))
	_select_option(_armor_option, _random_equipment(rng, "armor"))
	_player_morale_spin.value = float(rng.randi_range(MORALE_MIN, MORALE_MAX))
	var kind: String = KINDS[rng.randi_range(0, KINDS.size() - 1)]
	_select_option(_kind_option, kind)
	_apply_kind_profile(kind)
	_ai_level_option.select(rng.randi_range(0, 1))
	_select_option(_archetype_option,
		ARCHETYPES[rng.randi_range(0, ARCHETYPES.size() - 1)])
	_select_option(_formation_option,
		FORMATIONS[rng.randi_range(0, FORMATIONS.size() - 1)])
	_enemy_morale_spin.value = float(rng.randi_range(MORALE_MIN, MORALE_MAX))
	_compose_check.button_pressed = rng.randf() < 0.5
	_day_spin.value = float(rng.randi_range(DAY_MIN, 999))
	var seed_mode: String = SEED_MODES[rng.randi_range(0, SEED_MODES.size() - 1)]
	_select_option(_seed_mode_option, seed_mode)
	_seed_spin.value = float(rng.randi_range(0, SEED_MAX))
	_seed_spin.visible = seed_mode == "fixed"
	_select_option(_weather_option,
		WEATHERS[rng.randi_range(0, WEATHERS.size() - 1)])
	_select_option(_wind_option,
		WIND_DIRS[rng.randi_range(0, WIND_DIRS.size() - 1)])
	_select_option(_current_dir_option,
		CURRENT_DIRS[rng.randi_range(0, CURRENT_DIRS.size() - 1)])
	_current_strength_spin.value = float(
		rng.randi_range(0, CURRENT_STRENGTH_MAX))
	_select_option(_deployment_option,
		DEPLOYMENTS[rng.randi_range(0, DEPLOYMENTS.size() - 1)])
	apply_clamps()
	_on_compose_toggled(_compose_check.button_pressed)


func _random_hull(rng: RandomNumberGenerator) -> String:
	var hulls: Array = DataLoader.ship_types_list
	if hulls.is_empty():
		return "sloop"
	var row = hulls[rng.randi_range(0, hulls.size() - 1)]
	return str(row.get("id", "sloop")) if row is Dictionary else "sloop"


func _random_equipment(rng: RandomNumberGenerator, slot: String) -> String:
	var items := _equipment_ids(slot)
	if items.is_empty() or rng.randf() < 0.5:
		return ""
	return str(items[rng.randi_range(0, items.size() - 1)])


# --- 开战 (the fixture encounter → S10) ---------------------------------------

## The §4.7.16 fixture encounter. Ship instances in the §4.11.11 shape;
## `gold` 0; the resolved seed — `fixed` → the editor number, `random` → a
## fresh `randi()`, `auto` → the key is OMITTED and the §4.11.1 formula
## applies (contact = the origin tile). ONLY the fields the current engine
## consumes ride the encounter; wind/current/morale/ai_level/archetype/
## formation/deployment stay editor + export values until their waves land.
func build_encounter() -> Dictionary:
	apply_clamps()
	var player_ships: Array = []
	for row in _player_rows:
		player_ships.append(_ship_instance(_read_row(row)))
	var kind := str(_option_value(_kind_option))
	var day := int(_day_spin.value)
	var enemy_ships: Array = []
	if not _compose_check.button_pressed:
		for row in _enemy_rows:
			enemy_ships.append(_ship_instance(_read_row(row)))
	# §4.7.16 seed resolution. With `compose` ON the composition consumes a
	# stream seeded from the same resolved seed (or, for `auto`, the §4.11.1
	# formula — the value the sim itself will re-derive), so a given
	# (config, seed) pair always composes the same fleet: the byte-identity
	# audit pair stays exact.
	var seed_mode := str(_option_value(_seed_mode_option))
	var resolved_seed := -1
	match seed_mode:
		"fixed":
			resolved_seed = int(_seed_spin.value)
		"random":
			resolved_seed = randi()
	if _compose_check.button_pressed:
		var rng := RandomNumberGenerator.new()
		rng.seed = resolved_seed if resolved_seed >= 0 \
			else BattleSimLib.battle_seed_formula(
				day, FIXTURE_CONTACT, 0, player_ships.size())
		enemy_ships = AiFleetLib.compose_enemy(kind, day, rng)
	var encounter := {
		"sandbox": true,
		"id": "sandbox",
		"kind": kind,
		"player_ships": player_ships,
		"enemy_ships": enemy_ships,
		"day": day,
		"gold": 0,
		"weather": str(_option_value(_weather_option)),
	}
	if resolved_seed >= 0:
		encounter["seed"] = resolved_seed
	encounter["player_stats"] = {
		"attributes": _player_attributes(),
		"equipment": {
			"weapon": str(_option_value(_weapon_option)),
			"armor": str(_option_value(_armor_option)),
		},
	}
	return encounter


func _player_attributes() -> Dictionary:
	var out: Dictionary = {}
	for key in ATTRIBUTES:
		out[key] = int((_attribute_spins[key] as SpinBox).value)
	return out


## The §4.11.11 instance shape 开战 passes (per-ship captain ids stay editor
## + export values until W4 consumes escort captains).
func _ship_instance(state: Dictionary) -> Dictionary:
	return {
		"ship_type_id": str(state.get("ship_type_id", "")),
		"durability": int(state.get("durability", 1)),
		"crew": int(state.get("crew", 0)),
		"cannons": int(state.get("cannons", 0)),
		"equipment": {
			"figurehead": str(state.get("figurehead", "")),
			"sail": str(state.get("sail", "")),
		},
		"cargo": {},
	}


## 开战: clamp → keep the configuration → queue the fixture on the SAME seam
## `world_map.gd` uses (`GameState.pending_encounter`, the existing routing
## contract) → S10. The zero-write audit defines what may not CHANGE; the
## transient pending descriptor is consumed (cleared) by S10's open_battle.
func start_battle() -> void:
	apply_clamps()
	last_config = export_config()
	GameState.pending_encounter = build_encounter()
	GameState.change_scene(BATTLE_SCENE)


# --- Input ------------------------------------------------------------------

## `Esc` → S1 (§4.2). The configuration stays in [member last_config], so a
## later 海战 re-entry restores it.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		if route_to_title and ResourceLoader.exists(TITLE_SCENE):
			GameState.change_scene(TITLE_SCENE)


# --- Accessors (tests / hosts) ----------------------------------------------

func kind_option() -> OptionButton:
	return _kind_option


func compose_check() -> CheckBox:
	return _compose_check


func ai_level_option() -> OptionButton:
	return _ai_level_option


func archetype_option() -> OptionButton:
	return _archetype_option


func formation_option() -> OptionButton:
	return _formation_option


func enemy_morale_spin() -> SpinBox:
	return _enemy_morale_spin


func player_morale_spin() -> SpinBox:
	return _player_morale_spin


func attribute_spin(key: String) -> SpinBox:
	return _attribute_spins.get(key)


func weapon_option() -> OptionButton:
	return _weapon_option


func armor_option() -> OptionButton:
	return _armor_option


func day_spin() -> SpinBox:
	return _day_spin


func seed_mode_option() -> OptionButton:
	return _seed_mode_option


func seed_spin() -> SpinBox:
	return _seed_spin


func weather_option() -> OptionButton:
	return _weather_option


func wind_option() -> OptionButton:
	return _wind_option


func current_dir_option() -> OptionButton:
	return _current_dir_option


func current_strength_spin() -> SpinBox:
	return _current_strength_spin


func deployment_option() -> OptionButton:
	return _deployment_option


func start_button() -> Button:
	return _start_button


func random_all_button() -> Button:
	return _random_all_button


func import_button() -> Button:
	return _import_button


func export_button() -> Button:
	return _export_button


func zero_write_label() -> Label:
	return _zero_write


func toast_label() -> Label:
	return _toast


# --- Localisation helpers ---------------------------------------------------

## Every label is a `ui_strings.json` key (`10-*` §7.12). W2-B authors the
## `sandbox.*` values; until that merge the read degrades to the raw key
## (the `battle_screen._reason_text` convention) instead of spamming the
## missing-key error or inventing a player-facing string.
func _t(key: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return key


## A per-value label (`sandbox.kind.pirate`, `battle.formation.line_ahead`,
## `sandbox.dir.N`, …): the authored key wins, else the raw value id shows.
func _t_id(key_prefix: String, id: String) -> String:
	var key := key_prefix if id.is_empty() else "%s.%s" % [key_prefix, id]
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return id


## `I18n.fmt` with the same degrade-to-fallback for a `{placeholder}` key not
## yet authored.
func _tfmt(key: String, values: Dictionary, fallback: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.fmt(key, values)
	var out := fallback
	for name in values:
		out = out.replace("{%s}" % name, str(values[name]))
	return out
