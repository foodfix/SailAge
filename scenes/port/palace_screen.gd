extends Control
## Palace (S13) — royal missions, titles, repair bays, bounty pay-off,
## tournament entry, retirement, and the Phase-7 permit row + commendation
## dialog
## (docs/70-* §4.3, §4.5, §4.7, §4.9.2, §4.9.4, §4.9.5, §4.9.7, §4.1;
## docs/30-* §4.2, §4.7, §4.10; docs/80-* §4.1, §4.2, §4.7.3, §4.7.13).
##
## Every rule lives in `scripts/port/palace_engine.gd`, `scripts/player/fame.gd`,
## `scripts/quests/bounty.gd` and `scripts/quests/tournament.gd`; this screen
## renders rows and forwards clicks, the same split as every other facility.
##
## With an active bounty from this nation the §4.9.6 exception applies: every
## row except `Pay bounty` and `Leave` is disabled (`port.closed_bounty`).
##
## Phase 7 (docs/80-* §4.7.13): the §4.10 permit row renders under the bays
## row — the home charter (5,000g) at the player's own nation's palaces, the
## foreign permit (20,000g, title ≥ Knight, rep ≥ +20) for the host nation
## elsewhere, with held / void (`palace.permit.void_*`) / locked
## (`palace.permit.*_locked`) states — and the first flip of a contestable
## port plays the one-time commendation dialog (`palace.commend.*`). Both
## surfaces guard-read task L's `palace_engine.gd` seam (the `engine_override`
## member is the suite's spy seam; the fallbacks are the §4.10 docs numbers
## and live `Fame`/`Character`/`Bounty` answers), so this screen works against
## today's engine AND the upgraded one.

const PaletteLib := preload("res://scripts/palette.gd")
## Phase-10 sweep (§4.9): the bounty-board/inform rows carry the §4.8
## `role_{role}` badges through the kit registry (an absent id renders
## nothing — the flat fallback; the registry fills at W4-D), the S13
## commendation dialog gains the `trophy` icon (correction 4), the private
## toast adopts the kit toast atom, and the hand-built row-button chrome and
## per-screen colors retire to the shared theme.
const UiKitLib := preload("res://scripts/ui_kit.gd")
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const Phase3HooksLib := preload("res://scripts/quests/phase3_hooks.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const GameOverHostLib := preload("res://scenes/ui_shared/game_over_host.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
## Task L (docs/80-* §4.7.8): the bounty board lists docked hunter captains.
const NpcIntelLib := preload("res://scripts/world/npc_intel.gd")
## Phase-8 W5-C (docs/80-* §4.11.3): the dossier flag goes through the W4-A
## module (the panel itself is W6-A's — this screen owns only the entry).
const CaptainsLib := preload("res://scripts/world/captains.gd")
## The Phase-12 absolute-tile layout registry (docs/80-* §4.8.9): the data
## file is the layout; the registration below feeds the capture fragment.
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")

## §4.1b port hours (added 2026-11-02): the bay fill action's window guard and
## two-hour charge go through the one clock seam.
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
## S16 (docs/70-* §4.7).
const ENDING_SCENE := "res://scenes/ui_shared/ending_screen.tscn"
## S10 battle screen, for tournament bouts (`70-*` §4.9.7).
const BATTLE_SCENE := "res://scenes/combat/battle_screen.tscn"
## This screen's id in the registry (LayoutRegistry.SCREENS).
const LAYOUT_SCREEN := "palace"

## --- The authored tile table (parent-relative 32-px tiles; Phase 12) ---------
## One tile = `Palette.CHROME_TILE`. The screen root is the canvas; the rows
## group carries its own rect and its row groups address the group's space.
## The board/inform sections are dynamic list blocks (non-scrolling: the
## block's viewport is the base itself); a row's parts are absolutely-placed
## children of the row node.
const TILE := PaletteLib.CHROME_TILE
## The bounty-board list block (content-node tiles): row *i* at
## `(0, i·row_h)` — a 2-tile row (the 64-px dossier button sets the pitch).
const BOARD_LIST := "board"
const BOARD_W := 58
const BOARD_ROW_H := 2
## Board-row internals (row-local tiles): the §4.8 badge slot, the sighting
## line, and the open-dossier verb at the right edge.
const BOARD_BADGE_RECT := Rect2i(0, 0, 1, 2)
const BOARD_TEXT_W := 41
const BOARD_DOSSIER_RECT := Rect2i(51, 0, 7, 2)
## The inform list block: same 2-tile pitch.
const INFORM_LIST := "inform"
const INFORM_W := 58
const INFORM_ROW_H := 2
## Inform-row internals: badge · wanted caption · the 500g inform verb · the
## dossier entry.
const INFORM_BADGE_RECT := Rect2i(0, 0, 1, 2)
const INFORM_TEXT_W := 41
const INFORM_BUTTON_RECT := Rect2i(43, 0, 7, 2)
const INFORM_DOSSIER_RECT := Rect2i(51, 0, 7, 2)

# --- Phase-7 permit + commendation constants (docs/30-* §4.10, 70-* §4.1,
# --- 80-* §4.7.13) ---------------------------------------------------------

## The two §4.10 permit kinds.
const PERMIT_HOME := "home"
const PERMIT_FOREIGN := "foreign"
## §4.10 prices — also the guard defaults when task L's engine has not landed.
const HOME_PERMIT_PRICE := 5000
const FOREIGN_PERMIT_PRICE := 20000
## §4.10 gates: the foreign permit needs title ≥ Knight and rep ≥ +20; both
## kinds void while that nation's bounty stands or rep < −20.
const FOREIGN_PERMIT_MIN_REP := 20
const PERMIT_VOID_MIN_REP := -20
## ui_strings families (C's §4.7.15 inventory — the master merges them; every
## render path below falls back silently until then, never "<key>").
const PERMIT_SECTION_KEY := "palace.permit.section"
const PERMIT_HOME_KEY := "palace.permit.home"
const PERMIT_HOME_COVERAGE_KEY := "palace.permit.home.coverage"
const PERMIT_HOME_OWNED_KEY := "palace.permit.home.owned"
const PERMIT_FOREIGN_KEY := "palace.permit.foreign"
const PERMIT_FOREIGN_COVERAGE_KEY := "palace.permit.foreign.coverage"
const PERMIT_FOREIGN_OWNED_KEY := "palace.permit.foreign.owned"
const PERMIT_TITLE_LOCKED_KEY := "palace.permit.title_locked"
const PERMIT_REP_LOCKED_KEY := "palace.permit.rep_locked"
const PERMIT_VOID_BOUNTY_KEY := "palace.permit.void_bounty"
const PERMIT_VOID_REP_KEY := "palace.permit.void_rep"
const PERMIT_BOUGHT_KEY := "palace.permit.bought"
const COMMEND_TITLE_KEY := "palace.commend.title"
const COMMEND_BODY_KEY := "palace.commend.body"
const COMMEND_CLOSE_KEY := "palace.commend.close"

## Phase-8 W5-C (docs/80-* §4.11.1): the 告发 inform section's `ui_strings`
## keys — reported for the W6-D residual merge; until then the rows render
## from this local table (the tavern-screen FALLBACK_STRINGS pattern).
const INFORM_FALLBACK_STRINGS := {
	"palace.inform.header": {
		"zh": "告发海盗",
		"en": "Inform on pirates",
	},
	"palace.inform.action": {
		"zh": "告发 — 500 金",
		"en": "Inform — 500g",
	},
}

var route_to_port: bool = true
## Test seam (the `route_to_port` convention): when set, the permit /
## commendation engine calls go to this duck-typed object instead of
## `PalaceEngineLib` statics, so a suite can drive every row state and assert
## the call-through while task L's engine is still in flight.
var engine_override: Object = null
signal back_requested
signal title_granted_here(nation_id: String, rank: String)
signal retired_here
signal tournament_started(round_number: int)

@onready var _background: Panel = $Background
@onready var _hud: Control = get_node_or_null("HUD")
@onready var _header: Control = $header
@onready var _title: Label = $header/Title
@onready var _rep: Label = $header/Rep
@onready var _fame: Label = $header/Fame
@onready var _back_button: Button = $header/Back
@onready var _rows: Control = $Rows
@onready var _title_row: Label = $Rows/TitleRow/Current
@onready var _title_next: Label = $Rows/TitleRow/Next
@onready var _ceremony: Button = $Rows/TitleRow/Ceremony
@onready var _mission_row: Control = $Rows/MissionRow
@onready var _mission_label: Label = $Rows/MissionRow/Label
@onready var _mission_button: Button = $Rows/MissionRow/Action
@onready var _repair_row: Control = $Rows/RepairRow
@onready var _repair_label: Label = $Rows/RepairRow/Label
@onready var _repair_button: Button = $Rows/RepairRow/Action
@onready var _bounty_row: Control = $Rows/BountyRow
@onready var _bounty_label: Label = $Rows/BountyRow/Label
@onready var _bounty_button: Button = $Rows/BountyRow/Action
@onready var _permit_header: Label = $Rows/PermitHeader
@onready var _permit_home_row: Control = $Rows/PermitHomeRow
@onready var _permit_foreign_row: Control = $Rows/PermitForeignRow
@onready var _tournament_row: Control = $Rows/TournamentRow
@onready var _tournament_label: Label = $Rows/TournamentRow/Label
@onready var _tournament_button: Button = $Rows/TournamentRow/Action
@onready var _retire_row: Control = $Rows/RetireRow
@onready var _retire_button: Button = $Rows/RetireRow/Retire
@onready var _confirm: Control = $ConfirmDialog
## The §4.7.13 commendation dialog (message + OK chrome, `dialog_box.tscn`).
@onready var _commend: Control = $CommendDialog
## Phase-7 permit section (§4.7.13): header + one row per applicable kind.
@onready var _permit_rows: Dictionary = {
	PERMIT_HOME: {
		"row": $Rows/PermitHomeRow,
		"label": $Rows/PermitHomeRow/Label,
		"note": $Rows/PermitHomeRow/Note,
		"buy": $Rows/PermitHomeRow/Action,
	},
	PERMIT_FOREIGN: {
		"row": $Rows/PermitForeignRow,
		"label": $Rows/PermitForeignRow/Label,
		"note": $Rows/PermitForeignRow/Note,
		"buy": $Rows/PermitForeignRow/Action,
	},
}
## Ids behind the open commendation, so a locale change recomposes the text.
var _commend_info: Dictionary = {}

var _port_id: String = ""
var _nation_id: String = ""
## The tournament bout in progress (0 when none).
var _bout: int = 0
## Set when `_ready` auto-started a bout (tests await one frame instead).
var bout_pending: bool = false
## Task L (§4.7.8): the bounty board (code-built above the footer) —
## docked hunter captains. Hunter sightings are palace-only.
var _board_header: Label = null
var _board_box: Control = null
var _hunter_rows: Array = []
## Phase-8 W5-C (docs/80-* §4.11.1): the inform-on-pirates section, built
## under the bounty board — wanted pirate/privateer rows with the fixed 500g
## reveal + the dossier entry.
var _inform_header: Label = null
var _inform_box: Control = null
var _inform_rows: Array = []
## Fleet ids already informed on this visit → their reveal text (re-rendered
## after every rebuild, the tavern's `_revealed` discipline).
var _informed: Dictionary = {}
## The ids whose dossier entry was taken (the W6-A seam's test read).
var _dossiers_opened: Array = []
## The reveal text of the most recent inform ("" before the first).
var last_inform_text: String = ""
## Phase-11 (§4.8.9): per dynamic section, true once its first build has
## registered (see [_register_dynamic] for the first-build/rebuild split).
var _layout_built: Dictionary = {}


func _ready() -> void:
	# Full-scene S9 (80-* §4.2 amendment, 2026-11-02): a run can die on any
	# ledger tick ashore — the game-over screen must rise over the palace too.
	GameOverHostLib.attach_to(self)
	# Phase-10 sweep: label colors retire to the shared theme — TEXT is the
	# theme's Label default, the rep line carries the `Dim` variation and
	# the fame readout the master-added `Accent` variation (§4.9).
	_rep.theme_type_variation = "Dim"
	_fame.theme_type_variation = "Accent"
	for button in [_back_button, _ceremony, _mission_button, _repair_button,
			_bounty_button, _tournament_button, _retire_button]:
		button.custom_minimum_size.y = PaletteLib.BUTTON_H
	# S13 keeps the §4.5 bars but not the sea viewport, exactly like S4/S6/S8
	# (docs/80-* §4.5): the chart would otherwise cover the palace rows.
	if _hud != null:
		_hud.set_minimap_visible(false)
	_back_button.pressed.connect(go_back)
	_ceremony.pressed.connect(attend_ceremony)
	_mission_button.pressed.connect(accept_mission)
	_repair_button.pressed.connect(repair_fleet)
	_bounty_button.pressed.connect(pay_bounty)
	_tournament_button.pressed.connect(enter_tournament)
	_retire_button.pressed.connect(request_retire)
	(_permit_rows[PERMIT_HOME]["buy"] as Button).pressed.connect(
		buy_permit.bind(PERMIT_HOME))
	(_permit_rows[PERMIT_FOREIGN]["buy"] as Button).pressed.connect(
		buy_permit.bind(PERMIT_FOREIGN))
	# The commendation's dismissal lives on the dialog close for the bundled
	# real engine (its pending is a PEEK — see `_on_commend_closed`); the
	# granular `take_commendation` contract consumed on take instead.
	_commend.closed.connect(_on_commend_closed)
	if _confirm.has_signal("confirmed"):
		_confirm.confirmed.connect(retire)
	_port_id = _read_current_port()
	_nation_id = PalaceEngineLib.nation_of(_port_id)
	# Phase 12 (§4.8.9): the authored tile rects — every static at its data
	# rect, the groups as plain Controls, before anything registers.
	_place_statics()
	_build_bounty_board()
	_build_inform_section()
	_register_layout()
	refresh()
	# Phase-11 (§4.8.9): the build is registered — activate the screen (pins
	# the root, captures baselines, applies the committed table; ships {}).
	# Before the tournament returns below (both early-return after reporting).
	RegistryLib.screen_active(LAYOUT_SCREEN, self)
	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.fame_changed.connect(_on_fame_changed)
	EventBus.quests_changed.connect(refresh)
	EventBus.bounty_cleared.connect(_on_bounty_cleared)
	# §4.9.7: S10 returns here after a won bout (`Phase3Hooks` set the round) or
	# after the bracket settled (the outcome block). Both are one-shot reads.
	var settled := Phase3HooksLib.take_tournament_outcome()
	if not settled.is_empty():
		_report_tournament(settled)
		return
	var next_round := Phase3HooksLib.take_pending_bout()
	if next_round > 0:
		bout_pending = true
		call_deferred("_start_bout", next_round)


## Phase 12 (§4.8.9): one authored rect = one `position`/`size` write, in
## the DIRECT parent's tile space (point anchors everywhere; nothing is
## stretched).
func _place(control: Control, rect: Rect2i) -> void:
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = Vector2(rect.position) * float(TILE)
	control.size = Vector2(rect.size) * float(TILE)


## The authored tile table — today's captured look, flattened to the grid
## (see the fragment this screen's capture emits: `data/layout_fragments/
## palace.json`).
func _place_statics() -> void:
	_place(_header, Rect2i(1, 1, 58, 2))
	_place(_title, Rect2i(0, 0, 46, 1))
	_place(_rep, Rect2i(46, 1, 5, 1))
	_place(_fame, Rect2i(52, 1, 2, 1))
	_place(_back_button, Rect2i(54, 0, 4, 2))
	_place(_rows, Rect2i(1, 3, 58, 25))
	_place($Rows/TitleRow, Rect2i(0, 0, 58, 2))
	_place(_title_row, Rect2i(0, 1, 9, 1))
	_place(_title_next, Rect2i(9, 1, 42, 1))
	_place(_ceremony, Rect2i(51, 0, 7, 2))
	_place(_mission_row, Rect2i(0, 2, 58, 2))
	_place(_mission_label, Rect2i(0, 1, 51, 1))
	_place(_mission_button, Rect2i(51, 0, 7, 2))
	_place(_repair_row, Rect2i(0, 4, 58, 2))
	_place(_repair_label, Rect2i(0, 1, 51, 1))
	_place(_repair_button, Rect2i(51, 0, 7, 2))
	_place(_bounty_row, Rect2i(0, 6, 58, 2))
	_place(_bounty_label, Rect2i(0, 1, 51, 1))
	_place(_bounty_button, Rect2i(51, 0, 7, 2))
	_place(_permit_header, Rect2i(0, 8, 58, 1))
	_place(_permit_home_row, Rect2i(0, 9, 58, 2))
	_place(_permit_rows[PERMIT_HOME]["label"] as Control,
		Rect2i(0, 0, 36, 2))
	_place(_permit_rows[PERMIT_HOME]["note"] as Control,
		Rect2i(36, 0, 15, 2))
	_place(_permit_rows[PERMIT_HOME]["buy"] as Control, Rect2i(51, 0, 7, 2))
	_place(_permit_foreign_row, Rect2i(0, 11, 58, 2))
	_place(_permit_rows[PERMIT_FOREIGN]["label"] as Control,
		Rect2i(0, 0, 36, 2))
	_place(_permit_rows[PERMIT_FOREIGN]["note"] as Control,
		Rect2i(36, 0, 15, 2))
	_place(_permit_rows[PERMIT_FOREIGN]["buy"] as Control,
		Rect2i(51, 0, 7, 2))
	_place(_tournament_row, Rect2i(0, 13, 58, 2))
	_place(_tournament_label, Rect2i(0, 1, 50, 1))
	_place(_tournament_button, Rect2i(50, 0, 8, 2))
	_place(_retire_row, Rect2i(0, 15, 58, 2))
	_place(_retire_button, Rect2i(0, 0, 7, 2))


func _unhandled_input(event: InputEvent) -> void:
	if _confirm != null and _confirm.has_method("is_open") and _confirm.is_open():
		return
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		go_back()
		return


# --- Public API ----------------------------------------------------------

func port_id() -> String:
	return _port_id


func nation_id() -> String:
	return _nation_id


## Every player-facing line this screen shows (the no-raw-key check walks it).
## Hidden rows are skipped: a line the player cannot see is not "shown".
func all_text() -> Array:
	var out: Array = [
		_title.text, _rep.text, _fame.text, _back_button.text, _title_row.text,
		_title_next.text, _ceremony.text, _mission_label.text,
		_mission_button.text, _repair_label.text, _repair_button.text,
		_bounty_label.text, _bounty_button.text, _tournament_label.text,
		_tournament_button.text,
	]
	if retire_row_visible():
		out.append(_retire_button.text)
	for kind in [PERMIT_HOME, PERMIT_FOREIGN]:
		var widgets := permit_widget(kind)
		if widgets.is_empty() or not (widgets["row"] as Control).visible:
			continue
		out.append((widgets["label"] as Label).text)
		out.append((widgets["note"] as Label).text)
		out.append((widgets["buy"] as Button).text)
	if commendation_open():
		out.append((_commend as Control).message_text())
	return out


## `true` while the §4.7 Retire row is on screen (duke only).
func retire_row_visible() -> bool:
	var row: Control = _retire_button.get_parent() as Control
	return row.visible if row != null else _retire_button.visible


## The `ui_strings` reason key of a disabled row (`""` when enabled).
func row_block(key: String) -> String:
	var button: Button = _button_for(key)
	return "" if button == null or not button.disabled else button.tooltip_text


## `true` when the palace is bounty-closed (only Pay/Leave usable, `§4.9.6`).
func is_closed() -> bool:
	return BountyLib.is_port_closed(_port_id)


# --- Actions -------------------------------------------------------------

func attend_ceremony() -> String:
	var rank := PalaceEngineLib.attend_ceremony(_port_id)
	if rank.is_empty():
		_show_toast("palace.title.max" if FameLib.next_rank(_nation_id).is_empty()
			else "ui.not_available")
		return ""
	_show_toast("palace.ceremony.done", {
		"nation": _nation_name(), "rank": I18n.t_key("rank.%s" % rank),
	})
	title_granted_here.emit(_nation_id, rank)
	refresh()
	return rank


func accept_mission() -> Dictionary:
	var instance := PalaceEngineLib.accept(_port_id, GameState.day)
	if instance.is_empty():
		_show_toast("palace.mission_active")
		return {}
	_show_toast("quest.accepted")
	refresh()
	return instance


## Repairs the whole fleet at the count-grant discount, as much as gold allows.
## Returns the points restored. §4.1b (added 2026-11-02): one fill action —
## the bay visit must start inside the palace window and charges two hours
## once, not per hull.
func repair_fleet() -> int:
	if not SailingSimLib.facility_open(_port_id, "palace"):
		return 0
	var restored := 0
	for index in GameState.fleet.size():
		var shipyard_path := "res://scripts/port/shipyard_engine.gd"
		if not ResourceLoader.exists(shipyard_path):
			break
		var shipyard = ResourceLoader.load(shipyard_path)
		var points := int(shipyard.call("max_repair_points", index))
		if points <= 0:
			continue
		var per_point := int(PalaceEngineLib.repair_cost(_port_id, index, 1))
		if per_point <= 0:
			continue
		var affordable := int(GameState.gold / per_point)
		var want := mini(points, affordable)
		if want <= 0:
			break
		restored += PalaceEngineLib.repair(_port_id, index, want)
	if restored > 0:
		SailingSimLib.advance_port_hours(2)
	_show_toast("palace.repair")
	refresh()
	return restored


func pay_bounty() -> bool:
	var paid := PalaceEngineLib.pay_bounty(_port_id)
	if not paid:
		_show_toast("bounty.no_gold")
		return false
	_show_toast("bounty.cleared", {"nation": _nation_name()})
	refresh()
	return true


func enter_tournament() -> bool:
	var status := TournamentLib.status(_port_id, GameState.day)
	if not bool(status.get("open", false)):
		_show_toast(str(status.get("blocked", "tournament.closed")))
		return false
	if not PalaceEngineLib.enter_tournament(_port_id, GameState.day):
		return false
	# The bracket runs three real battles; production routes to S10 with the
	# round-1 descriptor queued and the screen re-opens after each bout.
	_start_bout(1)
	return true


## The Retire row's click: opens the `palace.retire.confirm` modal (§4.7 pin:
## "choosing it opens a confirm, and declining changes nothing").
func request_retire() -> bool:
	if not PalaceEngineLib.can_retire(_port_id):
		_show_toast("ui.not_available")
		return false
	if _confirm == null or not _confirm.has_method("open_key"):
		return retire()
	_confirm.open_key("palace.retire.confirm", {})
	return true


## Retires the run (`70-*` §4.7): flags the save state, announces, routes to
## S16. Refused unless the docked nation's title is duke.
func retire() -> bool:
	if not PalaceEngineLib.retire(_port_id):
		_show_toast("ui.not_available")
		return false
	retired_here.emit()
	if route_to_port and ResourceLoader.exists(ENDING_SCENE):
		GameState.change_scene(ENDING_SCENE)
	return true


func go_back() -> bool:
	back_requested.emit()
	if route_to_port:
		GameState.change_scene(PORT_SCENE)
	return true


func _start_bout(round_number: int) -> void:
	_bout = round_number
	bout_pending = false
	tournament_started.emit(round_number)
	# The descriptor is game state (which bout comes next), so it is queued
	# even when routing is off; only the scene swap is gated.
	GameState.set("pending_encounter", TournamentLib.encounter(round_number,
		GameState.day))
	if not route_to_port or not ResourceLoader.exists(BATTLE_SCENE):
		return
	GameState.change_scene(BATTLE_SCENE)


## Announces a settled bracket (`70-*` §4.9.7): `tournament.won` + `prize`, or
## `tournament.lost` + `consolation`. The numbers come from the outcome block,
## never recomputed here.
func _report_tournament(outcome: Dictionary) -> void:
	_bout = 0
	refresh()
	if bool(outcome.get("won", false)):
		_show_toast("tournament.won", {})
		_tournament_label.text = I18n.fmt("tournament.prize", {
			"gold": HudLib.format_thousands(int(outcome.get("gold", 0))),
			"fame": int(outcome.get("fame", 0)),
		})
		# The outcome's §4.8 tier tint rides the theme's `Good` / `Warn`
		# variations.
		_tournament_label.theme_type_variation = "Good"
		return
	_show_toast("tournament.lost", {
		"round": int(outcome.get("round_reached", 1)),
	})
	_tournament_label.text = I18n.fmt("tournament.consolation", {
		"gold": HudLib.format_thousands(int(outcome.get("gold", 0))),
	})
	_tournament_label.theme_type_variation = "Warn"


# --- Rendering -----------------------------------------------------------

func refresh() -> void:
	_port_id = _read_current_port()
	_nation_id = PalaceEngineLib.nation_of(_port_id)
	var port: Dictionary = DataLoader.get_port(_port_id) if not _port_id.is_empty() else {}
	_title.text = I18n.fmt("palace.title", {
		"port": I18n.t(port.get("name", {})) if not port.is_empty() else "-",
		"nation": _nation_name(),
	})
	_rep.text = I18n.fmt("char.rep_value", {
		"rep": CharacterLib_reputation(),
	})
	_fame.text = I18n.fmt("ending.fame", {"fame": GameState.fame})
	_back_button.text = I18n.t_key("ui.back")
	_bind_title()
	_bind_mission()
	_bind_repair()
	_bind_permit()
	_bind_bounty()
	_bind_tournament()
	_bind_retire()
	_bind_bounty_board()
	_bind_inform_rows()
	_apply_closed_state()
	_check_commendation()


func _bind_title() -> void:
	var rank := FameLib.title(_nation_id)
	_title_row.text = I18n.fmt("palace.title.current", {
		"rank": I18n.t_key("rank.%s" % rank),
	})
	var requirements := FameLib.next_requirements(_nation_id)
	if str(requirements.get("rank", "")).is_empty():
		_title_next.text = I18n.t_key("palace.title.max")
		_set_enabled(_ceremony, false, "")
		return
	_title_next.text = I18n.fmt("palace.title.next", {
		"rank": I18n.t_key("rank.%s" % str(requirements["rank"])),
		"fame": int(requirements["fame"]),
		"missions": int(requirements["missions"]),
	})
	_ceremony.text = I18n.t_key("palace.ceremony")
	_set_enabled(_ceremony, FameLib.can_promote(_nation_id), "ui.not_available")


func _bind_mission() -> void:
	var active := PalaceEngineLib.active_mission(_nation_id)
	if not active.is_empty():
		# The composed objective line is shared with the guild/panel
		# (`QuestGen.objective_text`), so a mission reads the same everywhere.
		_mission_label.text = I18n.fmt("palace.mission.active", {
			"objective": QuestGenLib.objective_text(active),
			"days": maxi(0, int(active.get("deadline_day", 0)) - GameState.day),
		})
		_set_enabled(_mission_button, false, "palace.mission_active")
		_mission_button.text = I18n.t_key("palace.mission.accept")
		return
	if not PalaceEngineLib.offers_missions(_port_id):
		_mission_label.text = I18n.fmt("palace.rep_locked", {
			"rep": PalaceEngineLib.MISSION_REPUTATION,
		})
		_set_enabled(_mission_button, false, "palace.rep_locked")
		_mission_button.text = I18n.t_key("palace.mission.accept")
		return
	var offer := PalaceEngineLib.offer(_port_id, GameState.day)
	_mission_label.text = I18n.t_key("palace.mission.section") if offer.is_empty() \
		else QuestGenLib.objective_text(offer)
	_mission_button.text = I18n.t_key("palace.mission.accept")
	_set_enabled(_mission_button, not offer.is_empty(), "palace.mission_active")


func _bind_repair() -> void:
	_repair_button.text = I18n.t_key("palace.repair")
	var discount := FameLib.repair_discount(_nation_id)
	if discount < 1.0:
		_repair_label.text = I18n.fmt("palace.repair.discount", {
			"percent": int(round((1.0 - discount) * 100.0)),
		})
	else:
		_repair_label.text = ""
	_set_enabled(_repair_button, _nation_id != "", "ui.not_available")


func _bind_bounty() -> void:
	if BountyLib.has_bounty(_nation_id) and not _nation_id.is_empty():
		_bounty_label.text = I18n.fmt("bounty.pay", {
			"gold": HudLib.format_thousands(BountyLib.amount(_nation_id)),
		})
		_bounty_button.text = I18n.t_key("bounty.pay")
		_set_enabled(_bounty_button, BountyLib.can_pay_off(_nation_id), "bounty.no_gold")
		return
	_bounty_label.text = I18n.t_key("bounty.none")
	_bounty_button.text = I18n.t_key("bounty.pay")
	_set_enabled(_bounty_button, false, "bounty.none")


func _bind_tournament() -> void:
	var status := TournamentLib.status(_port_id, GameState.day)
	var host_id := str(status.get("host", ""))
	_tournament_label.text = I18n.fmt("tournament.status", {
		"port": I18n.t(DataLoader.get_port(host_id).get("name", {})),
		"first": int(status.get("window_first", 1)),
		"last": int(status.get("window_last", 5)),
	})
	_tournament_button.text = I18n.fmt("tournament.enter", {
		"fee": HudLib.format_thousands(int(status.get("fee", 1000))),
	})
	var blocked := str(status.get("blocked", ""))
	if blocked == "tournament.entered":
		_tournament_button.text = I18n.t_key("tournament.entered")
	_set_enabled(_tournament_button, bool(status.get("open", false)),
		blocked if not blocked.is_empty() else "tournament.closed")


func _bind_retire() -> void:
	_retire_button.text = I18n.t_key("palace.retire")
	# `70-*` §4.7 pin: "the palace shows the `Retire` row **only** while the
	# docked port's nation title is duke", so a commoner never sees the row.
	var row: Control = _retire_button.get_parent() as Control
	var eligible := PalaceEngineLib.can_retire(_port_id)
	if row != null:
		row.visible = eligible
	else:
		_retire_button.visible = eligible
	_set_enabled(_retire_button, eligible, "ui.not_available")


## §4.9.6: on a bounty-closed port only Pay bounty and Leave stay usable.
func _apply_closed_state() -> void:
	if not is_closed():
		return
	for button in [_ceremony, _mission_button, _repair_button,
			_tournament_button, _retire_button,
			_permit_rows[PERMIT_HOME]["buy"], _permit_rows[PERMIT_FOREIGN]["buy"]]:
		button.disabled = true
		button.tooltip_text = I18n.t_key("port.closed_bounty")


# --- Helpers -------------------------------------------------------------

# --- Bounty board (docs/80-* §4.7.8, task L) ---------------------------------

## The hunter-captain rows currently rendered (`{id, name, nation_id}`) —
## the headless seam.
func hunter_rows() -> Array:
	return _hunter_rows.duplicate()


## Builds the board shell once (header + rows group) under the rows group,
## at its authored rects. The rows group is the board list block's content
## node (a plain Control — nothing inside it is flow-laid).
func _build_bounty_board() -> void:
	_board_header = Label.new()
	_board_header.name = "BountyBoardHeader"
	add_child(_board_header)
	_place(_board_header, Rect2i(1, 21, 58, 1))
	_board_box = Control.new()
	_board_box.name = "BountyBoardRows"
	_board_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_board_box)
	_place(_board_box, Rect2i(1, 22, 58, 4))


## Row *i*'s rect for a non-scrolling list block — px in the rows group's
## space: the data block when managed, the same tiles authored otherwise.
func _list_row_rect(list_id: String, index: int, w: int, row_h: int) -> Rect2:
	var rect := RegistryLib.list_rect(LAYOUT_SCREEN, list_id, index)
	if rect != Rect2():
		return rect
	return Rect2(
		Vector2(0, index * row_h) * float(TILE),
		Vector2(w, row_h) * float(TILE))


## The docked hunter captains sighted at this port (§4.7.8: the bounty board
## is a hunter's ONLY surface — the facility roll never sends one elsewhere).
## Phase 8 (§4.11.3): every bounty row gains the open-dossier action.
func _bind_bounty_board() -> void:
	if _board_box == null:
		return
	for child in _board_box.get_children():
		_board_box.remove_child(child)
		child.queue_free()
	_hunter_rows = []
	if _port_id.is_empty() or GameState.player.is_empty():
		_board_header.visible = false
		return
	_board_header.visible = true
	_board_header.text = I18n.t_key("captain.section.palace")
	for entry in NpcIntelLib.sightings(_port_id, NpcIntelLib.FACILITY_PALACE):
		_hunter_rows.append({
			"id": str(entry.get("id", "")),
			"captain_id": str(entry.get("captain_id", "")),
			"name": str(entry.get("name", "")),
			"role": str(entry.get("role", "")),
			"nation_id": str(entry.get("nation_id", "")),
		})
	var entries: Array = []
	if _hunter_rows.is_empty():
		var empty := Label.new()
		empty.name = "Empty"
		empty.text = "-"
		empty.theme_type_variation = "Dim"
		_board_box.add_child(empty)
		# The empty marker is a `board` LIST MEMBER placed at the
		# block's row 0 (builder-owned placement — the coverage check
		# exempts list members; docs/80-* §4.8.9).
		var rect := _list_row_rect(BOARD_LIST, 0, BOARD_W, BOARD_ROW_H)
		empty.set_anchors_preset(Control.PRESET_TOP_LEFT)
		empty.position = rect.position
		empty.size = rect.size
		_register_dynamic("board", [{
			"control": empty, "id": "board.rows.empty",
			"opts": {"role": RegistryLib.ROLE_PLAIN,
				"list": BOARD_LIST},
		}])
		return
	var index := 0
	for entry in _hunter_rows:
		_build_hunter_row(entry, index, entries)
		index += 1
	_register_dynamic("board", entries)


## One bounty row: a plain Control at the block's row rect; the §4.8 badge,
## the sighting line and the open-dossier verb are absolutely-placed children
## of the row (no per-row flow containers, §4.8.9). The row is a list member
## (`board`); its parts are unregistered (locked viewport blocks in the
## studio).
func _build_hunter_row(entry: Dictionary, index: int, entries: Array) -> void:
	var row := Control.new()
	row.name = "Hunter_%s" % str(entry["id"])
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board_box.add_child(row)
	var rect := _list_row_rect(BOARD_LIST, index, BOARD_W, BOARD_ROW_H)
	row.position = rect.position
	row.size = rect.size
	var row_id := "board.rows.%s" % str(entry["id"])
	entries.append({
		"control": row, "id": row_id, "opts": {
			"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": BOARD_LIST},
	})
	# §4.8 role badge on the sighting row (the flat fallback renders
	# nothing until the registry fills at W4-D).
	var badge_icon := _attach_role_badge(row, str(entry["role"]))
	var text_x := 0
	if badge_icon != null:
		_place(badge_icon, BOARD_BADGE_RECT)
		text_x = 1
	var text := Label.new()
	text.name = "Text"
	text.text = "%s · %s" % [str(entry["name"]),
		I18n.t_key("captain.role.%s" % str(entry["role"]))]
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(text)
	_place(text, Rect2i(text_x, 0, BOARD_TEXT_W - text_x, 2))
	var dossier := UiKitLib.button("dossier.open_from_bounty")
	dossier.name = "Dossier"
	dossier.pressed.connect(_open_dossier.bind(
		str(entry.get("captain_id", ""))))
	row.add_child(dossier)
	_place(dossier, BOARD_DOSSIER_RECT)


## Prepends the §4.8 `role_{role}` badge to a board/inform row; an absent id
## or an unknown role adds nothing (the flat fallback). Returns the badge
## icon (null when nothing was added — the row registration's read). The
## caller places the returned icon inside the row (the badge slot rect).
func _attach_role_badge(row: Control, role: String) -> Control:
	if role.is_empty():
		return null
	var texture := UiKitLib.hero_texture("role_%s" % role)
	if texture == null:
		return null
	var icon := TextureRect.new()
	icon.name = "RoleBadge"
	icon.texture = texture
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.custom_minimum_size = Vector2(32, 32)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	row.add_child(icon)
	return icon


# --- Inform on pirates + the dossier entry (§4.11.1/§4.11.3, Phase-8 W5-C) --

## `I18n` text for an inform key this screen also carries in
## [constant INFORM_FALLBACK_STRINGS] until W6-D merges it.
func _inform_text(key: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return I18n.t(INFORM_FALLBACK_STRINGS.get(key, {}))


## The inform rows currently rendered (`{id, captain_id, name, tier,
## reward_gold}` — the headless seam; the same at-sea wanted set the tavern
## posters draw, §4.7.8).
func inform_rows() -> Array:
	return _inform_rows.duplicate()


## The ids whose dossier entry this screen opened (the W6-A seam's read).
func dossiers_opened() -> Array:
	return _dossiers_opened.duplicate()


## Builds the inform section shell once (header + rows group), under the
## bounty board, at its authored rects.
func _build_inform_section() -> void:
	_inform_header = Label.new()
	_inform_header.name = "InformHeader"
	add_child(_inform_header)
	_place(_inform_header, Rect2i(1, 27, 58, 1))
	_inform_box = Control.new()
	_inform_box.name = "InformRows"
	_inform_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_inform_box)
	_place(_inform_box, Rect2i(1, 28, 58, 4))


## Binds the inform rows: every at-sea pirate/privateer within the poster
## radius (`70-*` §4.5: one wanted captain per inform), each with the fixed
## 500g reveal action and the dossier entry (§4.11.3: bounty rows link
## dossiers). Already-paid reveals re-render their text line (the §4.7.8
## reveal-text discipline: the answer stays after the rebuild).
func _bind_inform_rows() -> void:
	if _inform_box == null:
		return
	for child in _inform_box.get_children():
		_inform_box.remove_child(child)
		child.queue_free()
	_inform_rows = []
	if _port_id.is_empty() or GameState.player.is_empty():
		_inform_header.visible = false
		return
	var wanted: Array = NpcIntelLib.wanted_posters(_port_id)
	if wanted.is_empty() and _informed.is_empty():
		_inform_header.visible = false
		last_inform_text = ""
		return
	_inform_header.visible = true
	_inform_header.text = _inform_text("palace.inform.header")
	for poster in wanted:
		_inform_rows.append({
			"id": str(poster.get("id", "")),
			"captain_id": str(poster.get("captain_id", "")),
			"name": str(poster.get("name", "")),
			"tier": int(poster.get("tier", 1)),
			"reward_gold": int(poster.get("reward_gold", 0)),
		})
	var entries: Array = []
	var index := 0
	for row in _inform_rows:
		_build_inform_row(row, index, entries)
		index += 1
	for fleet_id in _informed:
		var line := Label.new()
		line.name = "InformText_%s" % str(fleet_id)
		line.text = str(_informed[fleet_id])
		_inform_box.add_child(line)
		var rect := _list_row_rect(INFORM_LIST, index, INFORM_W,
			INFORM_ROW_H)
		line.position = rect.position
		line.size = rect.size
		index += 1
		entries.append({
			"control": line,
			"id": "inform.rows.text.%s" % str(fleet_id), "opts": {
				"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
				"list": INFORM_LIST},
		})
	_register_dynamic("inform", entries)


## One inform row: the wanted caption (the §4.7.8 poster title) with the
## captain's §4.8 role badge, the fixed 500g inform action, and the dossier
## entry — absolutely-placed children of a plain Control at the block's row
## rect (a `inform` list member; parts unregistered).
func _build_inform_row(row_data: Dictionary, index: int,
		entries: Array) -> void:
	var row := Control.new()
	row.name = "Inform_%s" % str(row_data["id"])
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inform_box.add_child(row)
	var rect := _list_row_rect(INFORM_LIST, index, INFORM_W, INFORM_ROW_H)
	row.position = rect.position
	row.size = rect.size
	var badge_icon := _attach_role_badge(row, str(CaptainsLib.captain(
		str(row_data.get("captain_id", ""))).get("role", "")))
	var text_x := 0
	if badge_icon != null:
		_place(badge_icon, INFORM_BADGE_RECT)
		text_x = 1

	var text := Label.new()
	text.name = "Text"
	text.text = I18n.fmt("captain.poster.title", {
		"name": str(row_data.get("name", "")),
		"tier": int(row_data.get("tier", 1)),
	})
	# The §4.8 danger tint marks a wanted poster (the theme's `Bad`
	# variation).
	text.theme_type_variation = "Bad"
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(text)
	_place(text, Rect2i(text_x, 0, INFORM_TEXT_W - text_x, 2))

	var inform := Button.new()
	inform.name = "Inform"
	inform.text = _inform_text("palace.inform.action")
	if not PalaceEngineLib.can_inform(_port_id):
		inform.disabled = true
		inform.tooltip_text = I18n.t_key("captain.reveal.no_gold")
	else:
		inform.pressed.connect(inform_on.bind(str(row_data.get("id", ""))))
	row.add_child(inform)
	_place(inform, INFORM_BUTTON_RECT)

	var dossier := UiKitLib.button("dossier.open_from_bounty")
	dossier.name = "Dossier"
	dossier.pressed.connect(_open_dossier.bind(
		str(row_data.get("captain_id", ""))))
	row.add_child(dossier)
	_place(dossier, INFORM_DOSSIER_RECT)
	var row_id := "inform.rows.%s" % str(row_data["id"])
	entries.append({
		"control": row, "id": row_id, "opts": {
			"role": RegistryLib.ROLE_PLAIN, "data_ordered": true,
			"list": INFORM_LIST},
	})


## The inform click (§4.11.1): the fixed 500g reveal — the engine charges and
## returns the bounty-pinpoint payload; this screen formats the existing
## `captain.reveal.text` line (the §4.7.8 poster shape) and keeps it across
## rebuilds. Returns the text ("" on refusal).
func inform_on(fleet_id: String) -> String:
	var position: Dictionary = PalaceEngineLib.inform_on_pirates(
		_port_id, fleet_id)
	if position.is_empty():
		_show_toast("captain.reveal.no_gold")
		return ""
	var cell: Vector2i = position.get("cell", Vector2i.ZERO)
	last_inform_text = I18n.fmt("captain.reveal.text", {
		"name": str(position.get("name", "")),
		"x": cell.x, "y": cell.y,
		"port": str(position.get("nearest_port_name", "")),
	})
	_informed[fleet_id] = last_inform_text
	refresh()
	return last_inform_text


## The dossier entry seam (§4.11.3, W6-A's handoff): marks the captain's
## dossier seen through the shared module; the panel itself is W6-A's, so the
## placeholder plays the existing `dossier.open_from_bounty` toast line.
## Returns true when the entry was taken (a known captain id).
func _open_dossier(captain_id: String) -> bool:
	if captain_id.is_empty() or CaptainsLib.captain(captain_id).is_empty():
		return false
	CaptainsLib.mark_dossier_seen(captain_id)
	_dossiers_opened.append(captain_id)
	_show_toast("dossier.open_from_bounty")
	return true


# --- Permits (docs/30-* §4.10, 80-* §4.7.13 — Phase 7) ------------------------

## True when the engine seam answers `method` (the suite's `engine_override`
## duck-types first; task L's `palace_engine.gd` methods are guard-read so
## this screen merges green before, with, or after the engine lands).
func _seam_has(method: String) -> bool:
	return _seam_target().has_method(method)


## The permit/commendation engine target as a Variant (`engine_override` when
## the suite set it, else `palace_engine.gd` loaded by path — the same lazy
## pattern `palace_engine._shipyard()` uses for this screen's own engine,
## because a `class_name` script blocks instance-method calls at parse time).
func _seam_target() -> Variant:
	if engine_override != null:
		return engine_override
	var path := "res://scripts/port/palace_engine.gd"
	if not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path)


## Guarded engine call returning `default` when the seam or method is absent.
## The seam contract (engine-first answers; the defaults below are the docs
## fallbacks, `30-*` §4.10):
##   permit_price(port_id, kind, nation_id) -> int
##   permit_owned(port_id, kind, nation_id) -> bool
##   permit_void_reason(port_id, kind, nation_id) -> String   # "" or a key
##   permit_block_reason(port_id, kind, nation_id) -> String  # "" or a key
##   buy_permit(port_id, kind, nation_id) -> bool
##   take_commendation() -> Dictionary                        # {} or {nation_id, port_id}
func _seam_call(method: String, args: Array, default: Variant) -> Variant:
	var target = _seam_target()
	if target == null or not target.has_method(method):
		return default
	return target.callv(method, args)


## The widget dict of a permit row (`{row, label, note, buy}`) — the headless
## seam for the suites.
func permit_widget(kind: String) -> Dictionary:
	var value = _permit_rows.get(kind, null)
	return value if value is Dictionary else {}


## `true` when the §4.7.13 section header is on screen.
func permit_section_visible() -> bool:
	return _permit_header != null and _permit_header.visible


## The kind this palace sells: the home charter at the player's own nation's
## palaces, the foreign permit for the host nation elsewhere (`30-*` §4.10:
## own palaces only / that nation's palaces). `""` outside a capital.
func _applicable_permit_kind() -> String:
	if _nation_id.is_empty():
		return ""
	var player_nation := str(GameState.player.get("nation_id", ""))
	return PERMIT_HOME if _nation_id == player_nation else PERMIT_FOREIGN


## The bundled engine offer (`permit_offer(port_id)` — task L's real
## `palace_engine.gd` API), mapped onto the render state; `{}` when the seam
## does not answer it (the suite's duck-typed spy seam keeps the granular
## contract) or offers nothing here. The granular C-contract methods stay
## guard-read below, so both engine shapes drive the same row.
func _bundle_state(kind: String) -> Dictionary:
	var target = _seam_target()
	if target == null or not target.has_method("permit_offer"):
		return {}
	var offer = target.call("permit_offer", _port_id)
	if not (offer is Dictionary) or (offer as Dictionary).is_empty():
		return {}
	var offer_d: Dictionary = offer
	if str(offer_d.get("kind", "")) != kind:
		return {}
	var gate_key := ""
	if bool(offer_d.get("title_locked", false)):
		gate_key = PERMIT_TITLE_LOCKED_KEY
	elif bool(offer_d.get("rep_locked", false)):
		gate_key = PERMIT_REP_LOCKED_KEY
	return {
		"price": int(offer_d.get("price", 0)),
		"owned": bool(offer_d.get("owned", false)),
		"void_key": str(offer_d.get("void_key", "")),
		"gate_key": gate_key,
	}


## Every render fact of one permit row, engine-first with the docs fallbacks.
func _permit_state(kind: String) -> Dictionary:
	# Engine-first: the bundled real-API answer wins when the seam speaks it.
	var bundled := _bundle_state(kind)
	if not bundled.is_empty():
		return bundled
	var nation := _nation_id
	var price := int(_seam_call("permit_price", [_port_id, kind, nation],
		HOME_PERMIT_PRICE if kind == PERMIT_HOME else FOREIGN_PERMIT_PRICE))
	var owned := bool(_seam_call("permit_owned", [_port_id, kind, nation], false))
	var void_key := str(_seam_call("permit_void_reason",
		[_port_id, kind, nation], _default_void_key(nation)))
	var gate_key := str(_seam_call("permit_block_reason",
		[_port_id, kind, nation], _default_gate_key(kind)))
	return {
		"price": price, "owned": owned,
		"void_key": void_key, "gate_key": gate_key,
	}


## Void fallback (the §4.10 conditions, live from the standing modules).
func _default_void_key(nation: String) -> String:
	if nation.is_empty():
		return ""
	if BountyLib.has_bounty(nation):
		return PERMIT_VOID_BOUNTY_KEY
	if CharacterLib.reputation(nation) < PERMIT_VOID_MIN_REP:
		return PERMIT_VOID_REP_KEY
	return ""


## Gate fallback: the foreign permit needs title ≥ Knight and rep ≥ +20; the
## home charter has none (`30-*` §4.10).
func _default_gate_key(kind: String) -> String:
	if kind != PERMIT_FOREIGN or _nation_id.is_empty():
		return ""
	var ranks: Array = FameLib.RANKS
	if ranks.find(FameLib.title(_nation_id)) < ranks.find(FameLib.RANK_KNIGHT):
		return PERMIT_TITLE_LOCKED_KEY
	if CharacterLib.reputation(_nation_id) < FOREIGN_PERMIT_MIN_REP:
		return PERMIT_REP_LOCKED_KEY
	return ""


func _bind_permit() -> void:
	var applicable := _applicable_permit_kind()
	# The whole section stays hidden until its keys merge (and outside a
	# capital) — labels never print a raw "<key>".
	var keys_ready := DataLoader.ui_strings.has(PERMIT_SECTION_KEY) \
		and DataLoader.ui_strings.has(PERMIT_HOME_KEY) \
		and DataLoader.ui_strings.has(PERMIT_FOREIGN_KEY)
	_permit_header.visible = keys_ready and not applicable.is_empty()
	if _permit_header.visible:
		_permit_header.text = I18n.t_key(PERMIT_SECTION_KEY)
	for kind: String in [PERMIT_HOME, PERMIT_FOREIGN]:
		var widgets: Dictionary = _permit_rows[kind]
		var row: Control = widgets["row"]
		var show: bool = keys_ready and kind == applicable
		row.visible = show
		if not show:
			continue
		var state := _permit_state(kind)
		var is_home: bool = kind == PERMIT_HOME
		var label: Label = widgets["label"]
		label.text = I18n.t_key(PERMIT_HOME_KEY) if is_home \
			else I18n.fmt(PERMIT_FOREIGN_KEY, {"nation": _nation_name()})
		var note: Label = widgets["note"]
		var buy: Button = widgets["buy"]
		buy.text = I18n.t_key("market.buy")
		buy.tooltip_text = ""
		var note_key := ""
		if bool(state["owned"]):
			note_key = PERMIT_HOME_OWNED_KEY if is_home \
				else PERMIT_FOREIGN_OWNED_KEY
			buy.disabled = true
		elif not str(state["void_key"]).is_empty():
			note_key = str(state["void_key"])
			buy.disabled = true
		elif not str(state["gate_key"]).is_empty():
			note_key = str(state["gate_key"])
			buy.disabled = true
		else:
			note_key = PERMIT_HOME_COVERAGE_KEY if is_home \
				else PERMIT_FOREIGN_COVERAGE_KEY
			# The purchase only exists once the engine seam does; before that
			# the row renders honestly locked (`ui.not_available`).
			buy.disabled = not _seam_has("buy_permit")
			buy.tooltip_text = I18n.t_key("ui.not_available") if buy.disabled \
				else ""
		# The note localises with the nation for the foreign row's owned key;
		# all other note keys are plain.
		if DataLoader.ui_strings.has(note_key):
			note.text = I18n.fmt(note_key, {"nation": _nation_name()}) \
				if (not is_home and note_key == PERMIT_FOREIGN_OWNED_KEY) \
				else I18n.t_key(note_key)
			if buy.disabled and note_key in [PERMIT_TITLE_LOCKED_KEY,
					PERMIT_REP_LOCKED_KEY, PERMIT_VOID_BOUNTY_KEY,
					PERMIT_VOID_REP_KEY]:
				buy.tooltip_text = note.text
		else:
			note.text = ""


## The permit row's click: one call through the engine seam (`30-*` §4.10 —
## pricing, gates, `GameState.permits` and the treasury credit are all the
## engine's). Returns false when the seam refuses (or has not landed).
func buy_permit(kind: String) -> bool:
	if not _seam_has("buy_permit"):
		return false
	# Bundle-style engines (the real `palace_engine.gd`) take the port alone;
	# duck-typed seams keep the granular contract arguments.
	var bought := false
	var target = _seam_target()
	if target != null and target.has_method("permit_offer"):
		bought = bool(target.call("buy_permit", _port_id))
	else:
		bought = bool(_seam_call("buy_permit",
			[_port_id, kind, _nation_id], false))
	if not bought:
		return false
	_show_toast(PERMIT_BOUGHT_KEY)
	refresh()
	return true


# --- Commendation (docs/70-* §4.1, 80-* §4.7.13) -------------------------------

## The commendation dialog is open (suite seam).
func commendation_open() -> bool:
	return _commend != null and _commend.is_open()


## The one-time per-converted-port dialog, taken through the engine seam.
## The take only happens once all three `palace.commend.*` keys have merged —
## an unrenderable commendation is never consumed.
func _check_commendation() -> void:
	if _commend == null or commendation_open():
		return
	if not (DataLoader.ui_strings.has(COMMEND_TITLE_KEY)
			and DataLoader.ui_strings.has(COMMEND_BODY_KEY)
			and DataLoader.ui_strings.has(COMMEND_CLOSE_KEY)):
		return
	var info = _commendation_take()
	if not (info is Dictionary) or (info as Dictionary).is_empty():
		return
	_commend_info = info
	_commend.open_text(_commend_message())
	_attach_commend_trophy()
	_set_commend_button()


## The S13 commendation's §4.8 `trophy` icon (correction 4): a 32px mark
## beside the title block, inserted into the shared dialog's body above the
## message (the same reach-in pattern `_set_commend_button` uses — the
## dialog scene itself is W4-B's). An absent registry id adds nothing
## (the flat fallback).
func _attach_commend_trophy() -> void:
	# Phase 12: the shared dialog's flow chain is deleted — the body is
	# the plate's scroll content (a plain Control,
	# `data/layout_fragments/dialog_box.json`).
	var body := _commend.get_node_or_null("Panel/Body/Content")
	if body == null or body.get_node_or_null("CommendTrophy") != null:
		return
	# The §4.8 hero-64 display rule: the commendation trophy renders its
	# 64 hero 1:1 (an absent id adds nothing — the flat fallback).
	var texture := UiKitLib.hero_texture("trophy")
	if texture == null:
		return
	var icon := TextureRect.new()
	icon.name = "CommendTrophy"
	icon.texture = texture
	icon.custom_minimum_size = Vector2(64, 64)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	body.add_child(icon)
	body.move_child(icon, 0)


## The pending commendation through the seam, engine shape first: task L's
## real pair answers `pending_commendation(port_id)` — a PEEK, dismissed on
## the dialog close (see `_on_commend_closed`) — else the granular
## `take_commendation()` contract, which consumes on take. `{}` when neither
## seam exists or nothing is pending.
func _commendation_take() -> Dictionary:
	if _seam_has("pending_commendation"):
		var info = _seam_call("pending_commendation", [_port_id], {})
		return info if info is Dictionary else {}
	if _seam_has("take_commendation"):
		var taken = _seam_call("take_commendation", [], {})
		return taken if taken is Dictionary else {}
	return {}


## The commend dialog closed: under the bundled real engine the pending is a
## peek, so the played commendation is dismissed here (`dismiss_commendation()`
## — one-time per converted port, `70-*` §4.1). The granular
## `take_commendation` contract already consumed on take — nothing to do.
## `dialog_box.gd` emits `closed` with no argument.
func _on_commend_closed() -> void:
	if _seam_has("dismiss_commendation"):
		_seam_call("dismiss_commendation", [], null)


## `title` over `body` (the §4.7 message+OK chrome has no title row).
func _commend_message() -> String:
	return "%s\n%s" % [I18n.t_key(COMMEND_TITLE_KEY),
		I18n.fmt(COMMEND_BODY_KEY, {
			"nation": _commend_nation_name(),
			"port": _commend_port_name(),
		})]


func _commend_nation_name() -> String:
	var nation_id := str(_commend_info.get("nation_id", ""))
	return I18n.t(DataLoader.get_nation(nation_id).get("name", {}))


func _commend_port_name() -> String:
	var port_id := str(_commend_info.get("port_id", ""))
	return I18n.t(DataLoader.get_port(port_id).get("name", {}))


## The pinned close label (`palace.commend.close`) on the dialog's OK button.
func _set_commend_button() -> void:
	# Phase 12: the OK button hangs off the plate (`Panel/OK`).
	var ok: Button = _commend.get_node_or_null("Panel/OK")
	if ok != null and DataLoader.ui_strings.has(COMMEND_CLOSE_KEY):
		ok.text = I18n.t_key(COMMEND_CLOSE_KEY)


# --- Layout id registry (docs/80-UI-UX.md §4.8.9, Phase-11 W4-C) -------------

## Registers every persistent control with its stable hierarchical id. The
## statics carry the authored rects above (the capture emits them as the
## screen's fragment); the board/inform rows are list members — their ids
## carry the `list` flag and take `list_rect` positions. The shared dialogs
## register as whole surfaces only (their internals are the ui_shared
## fast-follow, §4.8.9 scope note).
func _register_layout() -> void:
	_reg(_background, "background", RegistryLib.ROLE_PANEL)
	_reg(_header, "header", RegistryLib.ROLE_PLAIN)
	_reg(_title, "header.title", RegistryLib.ROLE_PLAIN)
	_reg(_rep, "header.rep", RegistryLib.ROLE_PLAIN)
	_reg(_fame, "header.fame", RegistryLib.ROLE_PLAIN)
	_reg(_back_button, "header.back", RegistryLib.ROLE_BUTTON)
	_reg(_rows, "rows", RegistryLib.ROLE_PLAIN)
	_reg($Rows/TitleRow, "rows.title", RegistryLib.ROLE_PLAIN)
	_reg(_title_row, "rows.title.current", RegistryLib.ROLE_PLAIN)
	_reg(_title_next, "rows.title.next", RegistryLib.ROLE_PLAIN)
	_reg(_ceremony, "rows.title.ceremony", RegistryLib.ROLE_BUTTON)
	_reg(_mission_row, "rows.mission", RegistryLib.ROLE_PLAIN)
	_reg(_mission_label, "rows.mission.label", RegistryLib.ROLE_PLAIN)
	_reg(_mission_button, "rows.mission.action", RegistryLib.ROLE_BUTTON)
	_reg(_repair_row, "rows.repair", RegistryLib.ROLE_PLAIN)
	_reg(_repair_label, "rows.repair.label", RegistryLib.ROLE_PLAIN)
	_reg(_repair_button, "rows.repair.action", RegistryLib.ROLE_BUTTON)
	_reg(_bounty_row, "rows.bounty", RegistryLib.ROLE_PLAIN)
	_reg(_bounty_label, "rows.bounty.label", RegistryLib.ROLE_PLAIN)
	_reg(_bounty_button, "rows.bounty.action", RegistryLib.ROLE_BUTTON)
	_reg(_permit_header, "rows.permit_header", RegistryLib.ROLE_PLAIN)
	_reg(_permit_home_row, "rows.permit_home", RegistryLib.ROLE_PLAIN)
	_reg(_permit_rows[PERMIT_HOME]["label"] as Control,
		"rows.permit_home.label", RegistryLib.ROLE_PLAIN)
	_reg(_permit_rows[PERMIT_HOME]["note"] as Control,
		"rows.permit_home.note", RegistryLib.ROLE_PLAIN)
	_reg(_permit_rows[PERMIT_HOME]["buy"] as Control,
		"rows.permit_home.buy", RegistryLib.ROLE_BUTTON)
	_reg(_permit_foreign_row, "rows.permit_foreign", RegistryLib.ROLE_PLAIN)
	_reg(_permit_rows[PERMIT_FOREIGN]["label"] as Control,
		"rows.permit_foreign.label", RegistryLib.ROLE_PLAIN)
	_reg(_permit_rows[PERMIT_FOREIGN]["note"] as Control,
		"rows.permit_foreign.note", RegistryLib.ROLE_PLAIN)
	_reg(_permit_rows[PERMIT_FOREIGN]["buy"] as Control,
		"rows.permit_foreign.buy", RegistryLib.ROLE_BUTTON)
	_reg(_tournament_row, "rows.tournament", RegistryLib.ROLE_PLAIN)
	_reg(_tournament_label, "rows.tournament.label", RegistryLib.ROLE_PLAIN)
	_reg(_tournament_button, "rows.tournament.action",
		RegistryLib.ROLE_BUTTON)
	_reg(_retire_row, "rows.retire", RegistryLib.ROLE_PLAIN)
	_reg(_retire_button, "rows.retire.button", RegistryLib.ROLE_BUTTON)
	_reg(_board_header, "board.header", RegistryLib.ROLE_PLAIN)
	_reg(_board_box, "board.rows", RegistryLib.ROLE_PLAIN)
	_reg(_inform_header, "inform.header", RegistryLib.ROLE_PLAIN)
	_reg(_inform_box, "inform.rows", RegistryLib.ROLE_PLAIN)
	_reg($ConfirmDialog, "confirm_dialog", RegistryLib.ROLE_PLAIN)
	_reg($CommendDialog, "commend_dialog", RegistryLib.ROLE_PLAIN)


## One static registration — kind omitted (auto-derives from the parent).
func _reg(control: Control, id: String, role: String) -> void:
	RegistryLib.register(LAYOUT_SCREEN, control, id, {"role": role})


## Registers one rebuilt dynamic row set (the bounty-board and inform rows,
## the paid inform reveal lines). `entries` = [{control, id, opts}]. A
## section's FIRST build registers synchronously — inside `_ready`, ahead of
## `screen_active`, so the activation walk captures the rows' baselines. A
## REbuild defers one frame: the cleared rows are queue_freed but still live
## within this frame, and a same-frame re-register would read as a duplicate
## id — after the frame's delete flush the same-id replacement is silent. A
## pass whose screen died meanwhile has only dead nodes to visit: the
## instance-bound one-shot dies with it (nothing left to register).
func _register_dynamic(section: String, entries: Array) -> void:
	if not _layout_built.has(section):
		_layout_built[section] = true
		for entry in entries:
			RegistryLib.register(LAYOUT_SCREEN, entry["control"],
				entry["id"], entry["opts"])
		return
	var apply := func() -> void:
		for entry in entries:
			var candidate: Variant = entry["control"]
			# The Variant guard comes first: a freed node fails
			# `is_instance_valid` safely, while a typed assignment of it
			# would be a runtime error.
			if not is_instance_valid(candidate) or not (candidate is Control):
				continue
			RegistryLib.register(LAYOUT_SCREEN, candidate, entry["id"],
				entry["opts"])
		RegistryLib.apply_layout(LAYOUT_SCREEN)
	get_tree().process_frame.connect(apply, CONNECT_ONE_SHOT)


# --- Helpers -------------------------------------------------------------

func _read_current_port() -> String:
	var value = GameState.current_port
	if value is String and not (value as String).is_empty():
		return value
	return ""


func CharacterLib_reputation() -> int:
	var player: Dictionary = GameState.player
	var reputation: Dictionary = player.get("reputation", {})
	return int(reputation.get(_nation_id, 0))


func _nation_name() -> String:
	return I18n.t(_nation_name_l10n())


func _nation_name_l10n() -> Dictionary:
	return DataLoader.get_nation(_nation_id).get("name", {})


func _button_for(key: String) -> Button:
	match key:
		"ceremony":
			return _ceremony
		"mission":
			return _mission_button
		"repair":
			return _repair_button
		"bounty":
			return _bounty_button
		"tournament":
			return _tournament_button
		"retire":
			return _retire_button
		"permit_home":
			return _permit_rows[PERMIT_HOME]["buy"]
		"permit_foreign":
			return _permit_rows[PERMIT_FOREIGN]["buy"]
	return null


func _set_enabled(button: Button, enabled: bool, reason_key: String) -> void:
	button.disabled = not enabled
	button.tooltip_text = "" if enabled or reason_key.is_empty() \
		else I18n.t_key(reason_key)


func _show_toast(key: String, values: Dictionary = {}) -> void:
	if not DataLoader.ui_strings.has(key):
		return
	UiKitLib.toast(self, I18n.fmt(key, values))


func _on_locale_changed(_locale: String) -> void:
	refresh()
	# An open commendation recomposes from its ids so the title/body follow
	# the toggle (§6: every visible string re-binds).
	if commendation_open() and not _commend_info.is_empty():
		_commend.open_text(_commend_message())
		_set_commend_button()


func _on_gold_changed(_new_gold: int) -> void:
	refresh()


func _on_fame_changed(_new_fame: int) -> void:
	refresh()


func _on_bounty_cleared(_nation_id: String) -> void:
	refresh()


func _exit_tree() -> void:
	if _commend.closed.is_connected(_on_commend_closed):
		_commend.closed.disconnect(_on_commend_closed)
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.gold_changed.is_connected(_on_gold_changed):
		EventBus.gold_changed.disconnect(_on_gold_changed)
	if EventBus.fame_changed.is_connected(_on_fame_changed):
		EventBus.fame_changed.disconnect(_on_fame_changed)
	if EventBus.quests_changed.is_connected(refresh):
		EventBus.quests_changed.disconnect(refresh)
	if EventBus.bounty_cleared.is_connected(_on_bounty_cleared):
		EventBus.bounty_cleared.disconnect(_on_bounty_cleared)
