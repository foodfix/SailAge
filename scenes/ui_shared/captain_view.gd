class_name CaptainView
extends Control
## The 船长 view — docs/80-UI-UX.md §4.12 (amended 2026-11-03: the retired S14
## tabbed panel collapsed into this ONE scrollable page, embedded as the intel
## window's 船长 tab).
##
## Page order, top to bottom (the old 属性/技能 tabs showed the same card on
## both — the duplication is gone by merging the tabs):
##   * nation · day line + the level-up banner (§4.12.2);
##   * the §4.12 player card — attribute bars, level/XP, the §4.12.2 allocation
##     steppers + the effective-values split, then the skill bars with usage
##     counters (one card instance, one render);
##   * the six-nation reputation table (§50-* §4.6);
##   * every locked feature from `data/skill_gates.json` — the one `gate.*`
##     renderer: grayed row + threshold + reason, good-tinted once unlocked.
##
## Embeddable view contract: the intel window instantiates this scene and calls
## [method refresh] when its tab becomes active; the view also refreshes itself
## on the EventBus signals while visible, so a mid-view change never shows stale
## numbers. An in-progress allocation draft survives the refresh
## ([method CharacterCard.restage_draft]).

const PaletteLib := preload("res://scripts/palette.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
## The clock text in the nation line (`20-*` §4.3 amended).
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
## The §4.12 unified card (the player entry).
const CardLib := preload("res://scenes/ui/character_card.gd")

## The card's bounded viewport (docs/80-* §4.12.1 "Sizing", 2026-11-03
## amendment): the card publishes its full content height, so the view wraps it
## in a scroll instead of growing past the window.
const CARD_AREA_H := 280.0

@onready var _nation: Label = $Body/Nation
@onready var _levelup: Label = $Body/LevelUp
@onready var _card_scroll: ScrollContainer = $Body/CardScroll
@onready var _reputation_header: Label = $Body/ReputationHeader
@onready var _reputation_rows: GridContainer = $Body/ReputationRows
@onready var _gates_header: Label = $Body/GatesHeader
@onready var _gate_rows: VBoxContainer = $Body/GateScroll/GateRows

## The ONE §4.12 card instance (the player entry).
var _card: Control = null


func _ready() -> void:
	for label in [_nation, _levelup]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_levelup.add_theme_color_override("font_color", PaletteLib.ACCENT)
	for header in [_reputation_header, _gates_header]:
		header.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_levelup.visible = false

	# The ONE §4.12 card (the player entry, allocation steppers on), inside
	# the bounded scroll wrapper (docs/80-* §4.12.1 "Sizing").
	var card_scene: PackedScene = load(CardLib.SCENE_PATH)
	_card = card_scene.instantiate()
	_card.name = "PlayerCard"
	_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_scroll.add_child(_card)

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.fleet_changed.connect(_on_data_changed)
	EventBus.gold_changed.connect(_on_gold_changed)


## Rebuilds the whole page from live state. The intel window calls it when the
## tab becomes active; also safe to call directly.
func refresh() -> void:
	var player: Dictionary = GameState.player
	var nation_id := str(player.get("nation_id", ""))
	var nation: Dictionary = DataLoader.get_nation(nation_id)
	_nation.text = "%s · %s" % [
		I18n.t(nation.get("name", {})),
		I18n.fmt("char.day", {
			"day": GameState.day,
			"time": SailingSimLib.clock_text() if GameState.day > 0 else "-",
		}),
	]

	# The §4.12 player card; an in-progress allocation draft survives the
	# rebuild (§4.12.2: the draft is local to the card).
	var draft: Dictionary = _card.alloc_draft() if _card != null else {}
	if _card != null:
		_card.setup_person(CardLib.KIND_PLAYER, CardLib.card_data(
			CardLib.KIND_PLAYER, "", {"alloc": true}))
		_card.restage_draft(draft)

	_build_reputation(nation_id)
	_build_gates()

	_levelup.visible = CharacterLib.pending_levelup
	if _levelup.visible:
		_levelup.text = I18n.fmt("char.level_up", {
			"level": CharacterLib.current_level()})
		# Read-only on purpose: the toast owner (HUD, T6) consumes the flag via
		# CharacterLib.consume_pending_levelup(), so showing the banner here
		# must not swallow the HUD toast.


## True while this view is the intel window's active tab.
func is_active() -> bool:
	return is_visible_in_tree()


## The player card instance (test hook — the §4.12.2 draft pins drive it).
func player_card() -> Control:
	return _card


# --- Reputation (docs/50-* §4.6, §6 "no Nation rows hidden") ----------------

func _build_reputation(nation_id: String) -> void:
	_reputation_header.text = I18n.t_key("char.reputation")
	_reputation_rows.columns = 2
	_clear(_reputation_rows)
	for nation in DataLoader.nations_list:
		var other_id := str(nation.get("id", ""))
		var value := CharacterLib.reputation(other_id)
		var name_label := _make_label(I18n.t(nation.get("name", {})))
		name_label.name = "Rep_%s" % other_id
		if other_id == nation_id:
			name_label.add_theme_color_override("font_color", PaletteLib.ACCENT)
		var value_label := _make_label(format_signed(value))
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.custom_minimum_size.x = 96
		value_label.add_theme_color_override(
			"font_color",
			PaletteLib.GOOD if value > 0
			else (PaletteLib.BAD if value < 0 else PaletteLib.TEXT)
		)
		_reputation_rows.add_child(name_label)
		_reputation_rows.add_child(value_label)


# --- Gates (§4.12.3's locked-feature renderer) ------------------------------

## Every `data/skill_gates.json` row, grayed + reason while locked, good-tinted
## once the player's stat/skill (effective, §4.5.3) reaches the threshold.
func _build_gates() -> void:
	_gates_header.text = I18n.t_key("gate.locked")
	_clear(_gate_rows)
	for gate in DataLoader.skill_gates_list:
		_gate_rows.add_child(_build_gate_row(gate))


func _build_gate_row(gate: Dictionary) -> Control:
	var feature := str(gate.get("feature_id", ""))
	var stat := str(gate.get("stat_or_skill", ""))
	var threshold := int(gate.get("threshold", 0))
	var current := CharacterLib.attribute(stat) if stat in CharacterLib.ATTRIBUTES \
		else SkillsLib.effective_skill(stat)
	var locked := current < threshold
	var row := HBoxContainer.new()
	row.name = "Gate_%s" % feature
	row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	# §4.20 (amended 2026-11-03): each gate row carries its own bilingual
	# display `name`; the raw `feature_id` never reaches the label.
	var name_label := _make_label(I18n.t(gate.get("name", {})))
	name_label.name = "Feature"
	name_label.custom_minimum_size.x = 200.0
	name_label.add_theme_color_override("font_color",
		PaletteLib.PANEL_LINE if locked else PaletteLib.GOOD)
	row.add_child(name_label)
	var requires := _make_label(I18n.fmt("gate.requires", {
		"stat": I18n.t_key("skill.%s" % stat), "n": threshold,
	}))
	requires.name = "Requires"
	requires.custom_minimum_size.x = 180.0
	requires.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	row.add_child(requires)
	var reason := _make_label(I18n.t(gate.get("reason", {})))
	reason.name = "Reason"
	reason.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reason.add_theme_color_override("font_color",
		PaletteLib.WARN if locked else PaletteLib.PANEL_LINE)
	row.add_child(reason)
	return row


# --- Helpers ----------------------------------------------------------------

func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
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
	# Rebuild while active so a locale toggle mid-view is instant (§6).
	if is_active():
		refresh()


func _on_data_changed(_value: int = 0) -> void:
	if is_active():
		refresh()


func _on_gold_changed(_new_gold: int) -> void:
	if is_active():
		refresh()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.fleet_changed.is_connected(_on_data_changed):
		EventBus.fleet_changed.disconnect(_on_data_changed)
	if EventBus.gold_changed.is_connected(_on_gold_changed):
		EventBus.gold_changed.disconnect(_on_gold_changed)
