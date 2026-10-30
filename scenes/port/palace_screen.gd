extends Control
## Palace (S13) — royal missions, titles, repair bays, bounty pay-off,
## tournament entry and retirement
## (docs/70-* §4.3, §4.5, §4.7, §4.9.2, §4.9.4, §4.9.5, §4.9.7;
## docs/30-* §4.2, §4.7; docs/80-* §4.1, §4.2, §4.7.3).
##
## Every rule lives in `scripts/port/palace_engine.gd`, `scripts/player/fame.gd`,
## `scripts/quests/bounty.gd` and `scripts/quests/tournament.gd`; this screen
## renders rows and forwards clicks, the same split as every other facility.
##
## With an active bounty from this nation the §4.9.6 exception applies: every
## row except `Pay bounty` and `Leave` is disabled (`port.closed_bounty`).

const PaletteLib := preload("res://scripts/palette.gd")
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const FameLib := preload("res://scripts/player/fame.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
## S16 (docs/70-* §4.7).
const ENDING_SCENE := "res://scenes/ui_shared/ending_screen.tscn"
## S10 battle screen, for tournament bouts (`70-*` §4.9.7).
const BATTLE_SCENE := "res://scenes/combat/battle_screen.tscn"

var route_to_port: bool = true
signal back_requested
signal title_granted_here(nation_id: String, rank: String)
signal retired_here
signal tournament_started(round_number: int)

@onready var _background: ColorRect = $Background
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
@onready var _esc_hint: Label = $Layout/VBox/Footer/EscHint
@onready var _toast: Label = $Layout/VBox/Toast
@onready var _toast_timer: Timer = $ToastTimer

var _port_id: String = ""
var _nation_id: String = ""
## The tournament bout in progress (0 when none).
var _bout: int = 0


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	for label in [_title, _title_row, _title_next, _mission_label, _repair_label,
			_bounty_label, _tournament_label, _esc_hint, _toast]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	for label in [_fame, _title_next]:
		label.add_theme_color_override("font_color", PaletteLib.ACCENT)
	for label in [_rep, _esc_hint]:
		label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_title.add_theme_font_size_override("font_size", 32)
	for button in [_back_button, _ceremony, _mission_button, _repair_button,
			_bounty_button, _tournament_button, _retire_button]:
		button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_toast.visible = false
	_toast_timer.one_shot = true
	_toast_timer.timeout.connect(func() -> void: _toast.visible = false)
	_back_button.pressed.connect(go_back)
	_ceremony.pressed.connect(attend_ceremony)
	_mission_button.pressed.connect(accept_mission)
	_repair_button.pressed.connect(repair_fleet)
	_bounty_button.pressed.connect(pay_bounty)
	_tournament_button.pressed.connect(enter_tournament)
	_retire_button.pressed.connect(retire)
	_port_id = _read_current_port()
	_nation_id = PalaceEngineLib.nation_of(_port_id)
	refresh()
	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.fame_changed.connect(_on_fame_changed)
	EventBus.quests_changed.connect(refresh)
	EventBus.bounty_cleared.connect(_on_bounty_cleared)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		get_viewport().set_input_as_handled()
		go_back()
		return
	if event.is_action_pressed("toggle_locale"):
		get_viewport().set_input_as_handled()
		I18n.toggle_locale()


# --- Public API ----------------------------------------------------------

func port_id() -> String:
	return _port_id


func nation_id() -> String:
	return _nation_id


## Every player-facing line this screen shows (the no-raw-key check walks it).
func all_text() -> Array:
	return [
		_title.text, _rep.text, _fame.text, _back_button.text, _title_row.text,
		_title_next.text, _ceremony.text, _mission_label.text,
		_mission_button.text, _repair_label.text, _repair_button.text,
		_bounty_label.text, _bounty_button.text, _tournament_label.text,
		_tournament_button.text, _retire_button.text, _esc_hint.text,
	]


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
	tournament_started.emit(round_number)
	if not route_to_port or not ResourceLoader.exists(BATTLE_SCENE):
		return
	GameState.set("pending_encounter", TournamentLib.encounter(round_number,
		GameState.day))
	GameState.change_scene(BATTLE_SCENE)


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
	_esc_hint.text = I18n.t_key("ui.esc_hint")
	_bind_title()
	_bind_mission()
	_bind_repair()
	_bind_bounty()
	_bind_tournament()
	_bind_retire()
	_apply_closed_state()


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
		var requirements: Dictionary = active.get("requirements", {})
		var objective: Dictionary = requirements.get("objective", {})
		var text := I18n.t(objective) if not objective.is_empty() \
			else I18n.t_key("quest.type.royal")
		_mission_label.text = I18n.fmt("palace.mission.active", {
			"objective": text,
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
		else _mission_text(offer)
	_mission_button.text = I18n.t_key("palace.mission.accept")
	_set_enabled(_mission_button, not offer.is_empty(), "palace.mission_active")


func _mission_text(offer: Dictionary) -> String:
	var requirements: Dictionary = offer.get("requirements", {})
	match str(requirements.get("kind", "")):
		PalaceEngineLib.KIND_PATROL:
			return I18n.fmt("quest.line.bounty", {
				"target": I18n.t(_nation_name_l10n()), "tier": 2,
			})
		PalaceEngineLib.KIND_CHART:
			return I18n.t_key("quest.line.exploration")
		_:
			return I18n.fmt("quest.line.delivery", {
				"quantity": int(requirements.get("quantity", 0)),
				"good": I18n.t(DataLoader.get_good(
					str(requirements.get("good_id", ""))).get("name", {})),
				"port": I18n.t(DataLoader.get_port(
					str(requirements.get("dest_port_id", ""))).get("name", {})),
			})


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
	if bool(status.get("entered", false)):
		_tournament_button.text = I18n.t_key("tournament.entered")
		_set_enabled(_tournament_button, false, "tournament.entered")
		return
	_tournament_button.text = I18n.fmt("tournament.enter", {
		"fee": HudLib.format_thousands(int(status.get("fee", 1000))),
	})
	var blocked := str(status.get("blocked", ""))
	_set_enabled(_tournament_button, bool(status.get("open", false)),
		blocked if not blocked.is_empty() else "tournament.closed")


func _bind_retire() -> void:
	_retire_button.text = I18n.t_key("palace.retire")
	_set_enabled(_retire_button, PalaceEngineLib.can_retire(_port_id), "ui.not_available")


## §4.9.6: on a bounty-closed port only Pay bounty and Leave stay usable.
func _apply_closed_state() -> void:
	if not is_closed():
		return
	for button in [_ceremony, _mission_button, _repair_button,
			_tournament_button, _retire_button]:
		button.disabled = true
		button.tooltip_text = I18n.t_key("port.closed_bounty")


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


func _on_gold_changed(_new_gold: int) -> void:
	refresh()


func _on_fame_changed(_new_fame: int) -> void:
	refresh()


func _on_bounty_cleared(_nation_id: String) -> void:
	refresh()


func _exit_tree() -> void:
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
