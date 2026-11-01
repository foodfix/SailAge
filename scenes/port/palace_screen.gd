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
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const Phase3HooksLib := preload("res://scripts/quests/phase3_hooks.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
## Task L (docs/80-* §4.7.8): the bounty board lists docked hunter captains.
const NpcIntelLib := preload("res://scripts/world/npc_intel.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
## S16 (docs/70-* §4.7).
const ENDING_SCENE := "res://scenes/ui_shared/ending_screen.tscn"
## S10 battle screen, for tournament bouts (`70-*` §4.9.7).
const BATTLE_SCENE := "res://scenes/combat/battle_screen.tscn"

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

@onready var _background: ColorRect = $Background
@onready var _hud: Control = get_node_or_null("HUD")
@onready var _title: Label = $Layout/VBox/Header/Title
@onready var _rep: Label = $Layout/VBox/Header/Rep
@onready var _fame: Label = $Layout/VBox/Header/Fame
@onready var _back_button: Button = $Layout/VBox/Header/Back
@onready var _title_row: Label = $Layout/VBox/Rows/TitleRow/Current
@onready var _title_next: Label = $Layout/VBox/Rows/TitleRow/Next
@onready var _ceremony: Button = $Layout/VBox/Rows/TitleRow/Ceremony
@onready var _mission_label: Label = $Layout/VBox/Rows/MissionRow/Label
@onready var _mission_button: Button = $Layout/VBox/Rows/MissionRow/Action
@onready var _repair_label: Label = $Layout/VBox/Rows/RepairRow/Label
@onready var _repair_button: Button = $Layout/VBox/Rows/RepairRow/Action
@onready var _bounty_label: Label = $Layout/VBox/Rows/BountyRow/Label
@onready var _bounty_button: Button = $Layout/VBox/Rows/BountyRow/Action
@onready var _tournament_label: Label = $Layout/VBox/Rows/TournamentRow/Label
@onready var _tournament_button: Button = $Layout/VBox/Rows/TournamentRow/Action
@onready var _retire_button: Button = $Layout/VBox/Rows/RetireRow/Retire
@onready var _confirm: Control = $ConfirmDialog
@onready var _toast: Label = $Layout/VBox/Toast
@onready var _toast_timer: Timer = $ToastTimer
## Phase-7 permit section (§4.7.13): header + one row per applicable kind.
@onready var _permit_header: Label = $Layout/VBox/Rows/PermitHeader
@onready var _permit_rows: Dictionary = {
	PERMIT_HOME: {
		"row": $Layout/VBox/Rows/PermitHomeRow,
		"label": $Layout/VBox/Rows/PermitHomeRow/Label,
		"note": $Layout/VBox/Rows/PermitHomeRow/Note,
		"buy": $Layout/VBox/Rows/PermitHomeRow/Action,
	},
	PERMIT_FOREIGN: {
		"row": $Layout/VBox/Rows/PermitForeignRow,
		"label": $Layout/VBox/Rows/PermitForeignRow/Label,
		"note": $Layout/VBox/Rows/PermitForeignRow/Note,
		"buy": $Layout/VBox/Rows/PermitForeignRow/Action,
	},
}
## The §4.7.13 commendation dialog (message + OK chrome, `dialog_box.tscn`).
@onready var _commend: Control = $CommendDialog
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
var _board_box: VBoxContainer = null
var _hunter_rows: Array = []


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	for label in [_title, _title_row, _title_next, _mission_label, _repair_label,
			_bounty_label, _tournament_label, _toast]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	for label in [_fame, _title_next]:
		label.add_theme_color_override("font_color", PaletteLib.ACCENT)
	for label in [_rep]:
		label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_title.add_theme_font_size_override("font_size", 32)
	for button in [_back_button, _ceremony, _mission_button, _repair_button,
			_bounty_button, _tournament_button, _retire_button]:
		button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_toast.visible = false
	_toast_timer.one_shot = true
	_toast_timer.timeout.connect(func() -> void: _toast.visible = false)
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
	_build_bounty_board()
	refresh()
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
## Returns the points restored.
func repair_fleet() -> int:
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
		_tournament_label.add_theme_color_override("font_color", PaletteLib.GOOD)
		return
	_show_toast("tournament.lost", {
		"round": int(outcome.get("round_reached", 1)),
	})
	_tournament_label.text = I18n.fmt("tournament.consolation", {
		"gold": HudLib.format_thousands(int(outcome.get("gold", 0))),
	})
	_tournament_label.add_theme_color_override("font_color", PaletteLib.WARN)


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


## Builds the board shell once (header + rows box) above the footer.
func _build_bounty_board() -> void:
	var footer: Control = $Layout/VBox/Footer
	var layout: Node = footer.get_parent()
	var footer_index := footer.get_index()
	_board_header = Label.new()
	_board_header.name = "BountyBoardHeader"
	_board_header.add_theme_color_override("font_color", PaletteLib.ACCENT)
	layout.add_child(_board_header)
	_board_box = VBoxContainer.new()
	_board_box.name = "BountyBoardRows"
	_board_box.add_theme_constant_override("separation", 2)
	layout.add_child(_board_box)
	layout.move_child(_board_header, footer_index)
	layout.move_child(_board_box, footer_index + 1)


## The docked hunter captains sighted at this port (§4.7.8: the bounty board
## is a hunter's ONLY surface — the facility roll never sends one elsewhere).
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
			"name": str(entry.get("name", "")),
			"role": str(entry.get("role", "")),
			"nation_id": str(entry.get("nation_id", "")),
		})
	if _hunter_rows.is_empty():
		var empty := Label.new()
		empty.name = "Empty"
		empty.text = "-"
		empty.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
		_board_box.add_child(empty)
		return
	for entry in _hunter_rows:
		var row := Label.new()
		row.name = "Hunter_%s" % str(entry["id"])
		row.text = "%s · %s" % [str(entry["name"]),
			I18n.t_key("captain.role.%s" % str(entry["role"]))]
		row.add_theme_color_override("font_color", PaletteLib.TEXT)
		_board_box.add_child(row)


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
	_set_commend_button()


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
	var ok: Button = _commend.get_node_or_null(
		"Center/Panel/Margin/Body/Footer/OK")
	if ok != null and DataLoader.ui_strings.has(COMMEND_CLOSE_KEY):
		ok.text = I18n.t_key(COMMEND_CLOSE_KEY)


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
	_toast.text = I18n.fmt(key, values)
	_toast.add_theme_color_override("font_color", PaletteLib.GOOD)
	_toast.visible = true
	_toast_timer.start(2.5)


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
