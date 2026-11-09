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
##     level/XP line and the §4.12.2 allocation steppers (one card instance,
##     one render). Skill rows show the EFFECTIVE value and their tooltips
##     carry the base / officer / total split plus each gate (§4.12.1/§4.12.3
##     amended 2026-11-03), which retired both the 生效值 block and the
##     未解锁 list this page used to carry.
##
## The six-nation reputation table moved to its own 声望 tab
## ([ReputationView], §4.5) — it was the third block on this page and pushed
## the content off screen.
##
## Embeddable view contract: the intel window instantiates this scene and calls
## [method refresh] when its tab becomes active; the view also refreshes itself
## on the EventBus signals while visible, so a mid-view change never shows stale
## numbers. An in-progress allocation draft survives the refresh
## ([method CharacterCard.restage_draft]).

const PaletteLib := preload("res://scripts/palette.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
## The §4.12 card owns the skill descriptions and the gate tooltips.
## The clock text in the nation line (`20-*` §4.3 amended).
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
## The §4.12 unified card (the player entry).
const CardLib := preload("res://scenes/ui/character_card.gd")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

## This view's layout screen id (docs/10-* §4.23 — the 32-screen set).
const SCREEN_ID := "captain_view"

## Layout contract (amended 2026-11-03, the intel-window fit fix): the page is
## ONE vertical scroll (`page`) holding the card.
## Nested scrolls were dropped — the card publishes its full content height
## (`80-*` §4.12.1), so the page scroll owns the whole page and nothing can
## grow upward past the tab row.
@onready var _nation: Label = $Nation
@onready var _levelup: Label = $LevelUp
@onready var _page: ScrollContainer = $Page
@onready var _card_host: Control = $Page/CardHost

## The ONE §4.12 card instance (the player entry).
var _card: Control = null


func _ready() -> void:
	# §4.9 sweep (W4-B): ink is the theme's TEXT; the level-up banner keeps
	# its ACCENT highlight via `modulate`.
	_levelup.modulate = PaletteLib.ACCENT
	_levelup.visible = false

	# The ONE §4.12 card (the player entry, allocation steppers on), inside
	# the single page scroll (docs/80-* §4.12.1 "Sizing").
	var card_scene: PackedScene = load(CardLib.SCENE_PATH)
	_card = card_scene.instantiate()
	_card.name = "PlayerCard"
	_card_host.add_child(_card)
	# The viewport's content node is a plain Control sized to the viewport
	# (the card's own internal scroll owns overflow, exactly the pre-Phase-12
	# sizing); the card fills it through full-rect anchors.
	_card_host.custom_minimum_size = _page.size
	_card.set_anchors_preset(Control.PRESET_FULL_RECT)

	# Phase 12 (docs/80-* §4.8.9): the absolute-tile layout — nation line,
	# level-up banner and the page viewport at their data rects in the
	# 32×12-tile view space; the card hangs directly off the viewport's
	# plain-Control content node. The view registers + activates at build.
	RegistryLib.register(SCREEN_ID, _nation, "nation")
	RegistryLib.register(SCREEN_ID, _levelup, "levelup")
	RegistryLib.register(SCREEN_ID, _page, "page")
	RegistryLib.screen_active(SCREEN_ID, self)

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


# --- Helpers ----------------------------------------------------------------

func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	# Ink is the theme's TEXT (§4.9 sweep).
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
