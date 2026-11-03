class_name CaptainView
extends Control
## The 船长 view — docs/80-UI-UX.md §4.12 (amended 2026-11-03: the retired S14
## tabbed panel collapsed into this ONE scrollable page, embedded as the intel
## window's 船长 tab).
##
## Page order, top to bottom (the old 属性/技能 tabs showed the same card on
## both — the duplication is gone by merging the tabs):
##   * nation · day line + the level-up banner (§4.12.2);
##   * the §4.12 player card — attribute bars and skill bars side by side, the
##     level/XP line, the §4.12.2 allocation steppers and the effective-values
##     split (one card instance, one render);
##   * every locked feature from `data/skill_gates.json` — one compact row per
##     gate (name · requirement · current/threshold) whose `reason` is a hover
##     tooltip rather than an inline paragraph (amended 2026-11-03: fourteen
##     reason paragraphs buried the list).
##
## The six-nation reputation table moved to its own 声望 tab
## ([ReputationView], §4.5) — it was the third block on this page and pushed
## the gate list off screen.
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

## Layout contract (amended 2026-11-03, the intel-window fit fix): the page is
## ONE vertical scroll (`Body/Page`) holding the card and the gate rows.
## Nested scrolls were dropped — the card publishes its full content height
## (`80-*` §4.12.1), so the page scroll owns the whole page and nothing can
## grow upward past the tab row.
@onready var _nation: Label = $Body/Nation
@onready var _levelup: Label = $Body/LevelUp
@onready var _card_host: Container = $Body/Page/Sections/CardHost
@onready var _gates_header: Label = $Body/Page/Sections/GatesHeader
@onready var _gate_rows: VBoxContainer = $Body/Page/Sections/GateRows

## The ONE §4.12 card instance (the player entry).
var _card: Control = null


func _ready() -> void:
	for label in [_nation, _levelup]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_levelup.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_gates_header.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_levelup.visible = false

	# The ONE §4.12 card (the player entry, allocation steppers on), inside
	# the single page scroll (docs/80-* §4.12.1 "Sizing").
	var card_scene: PackedScene = load(CardLib.SCENE_PATH)
	_card = card_scene.instantiate()
	_card.name = "PlayerCard"
	_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_host.add_child(_card)

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.fleet_changed.connect(_on_data_changed)
	EventBus.gold_changed.connect(_on_gold_changed)


## Rebuilds the page from live state. The intel window calls it when the tab
## becomes active; also safe to call directly.
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


# --- Gates (§4.12.3's locked-feature renderer) ------------------------------

## Every `data/skill_gates.json` row as one compact line (§4.12.3 amended
## 2026-11-03): name · requirement · current/threshold, grayed while locked and
## good-tinted once the effective stat/skill reaches the threshold. The
## `reason` is the row's hover tooltip.
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
	name_label.custom_minimum_size.x = 180.0
	name_label.add_theme_color_override("font_color",
		PaletteLib.PANEL_LINE if locked else PaletteLib.GOOD)
	row.add_child(name_label)

	var requires := _make_label(I18n.fmt("gate.requires", {
		"stat": _stat_name(stat), "n": threshold,
	}))
	requires.name = "Requires"
	requires.custom_minimum_size.x = 200.0
	requires.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	row.add_child(requires)

	# The progress cell: how close the player already is. The threshold and the
	# current value both live on the row, so the tooltip only carries the "why"
	# (§4.12.3 amended).
	var progress := _make_label("%d/%d" % [current, threshold])
	progress.name = "Progress"
	progress.custom_minimum_size.x = 80.0
	progress.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	progress.add_theme_color_override("font_color",
		PaletteLib.GOOD if not locked else PaletteLib.WARN)
	row.add_child(progress)

	# Hover text: the reason, plus the current value once unlocked.
	var tooltip := I18n.t(gate.get("reason", {}))
	if not locked:
		tooltip = "%s\n%s" % [tooltip, I18n.fmt("gate.requires", {
			"stat": _stat_name(stat), "n": threshold})]
	row.tooltip_text = tooltip
	for child in row.get_children():
		if child is Control:
			(child as Control).tooltip_text = tooltip
	return row


## The localized name of an attribute or skill id (`char.attr.*` / `skill.*`).
static func _stat_name(stat: String) -> String:
	if stat in CharacterLib.ATTRIBUTES:
		return I18n.t_key("char.attr.%s" % stat)
	return I18n.t_key("skill.%s" % stat)


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


func _on_locale_changed(_locale: String) -> void:
	# Rebuild while active so a locale toggle mid-view is instant (§6).
	if is_active():
		refresh()


func _on_data_changed(_value: int = 0) -> void:
	if is_active():
		refresh()


func _on_gold_changed(_value: int) -> void:
	if is_active():
		refresh()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.fleet_changed.is_connected(_on_data_changed):
		EventBus.fleet_changed.disconnect(_on_data_changed)
	if EventBus.gold_changed.is_connected(_on_gold_changed):
		EventBus.gold_changed.disconnect(_on_gold_changed)
