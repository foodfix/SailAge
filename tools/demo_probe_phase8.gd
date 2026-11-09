extends Node
## Phase-8 task W7-B — the scripted acceptance probe behind
## `tools/demo_check_phase8.md` (the dated gate's evidence rows).
## NOT part of the `tools/test_*.tscn` gate family (`run_tests.py` globs
## `test_*.tscn` only); it is the reproducible record of the backlog's
## W7-B scenarios on the shipped tree:
##
##   godot --headless res://tools/demo_probe_phase8.tscn
##
## Exits 0 when every scenario holds. Numbers it prints are quoted in the
## demo-check record (branch/commit + date at the top of that file).
##
## Scenarios (docs/IMPLEMENT-Phase8.md, W7-B):
##   1. appointment & prereqs (gate gray → pilot hired → key + route, no fee)
##   2. captain commissioning (signing cost × charisma, post contribution)
##   3. capture-no-idle ⇒ loot convert; with an idle officer the hull joins
##      at the 25% durability transform
##   4. two-step creation (S2→S20 handoff, steppers' caps, spread evenly,
##      must-spend-all, confirm → the new_game block, derived preview)
##   5. advice event (cook + low morale; the seeded 3% roll fires)
##   6. retirement segment (the ending screen's RPG rows read the fixtures)
##   7. appointed voyage (gate gray, weighted vs plain, contact cancels,
##      storm does not — auto-reef + restore)
##   8. nemesis lifecycle (stance −3 ⇒ nemesis, defeat → day+60, the
##      re-spawn books a hunter fleet, tier drift clamp)
##   9. zh/en parity (the locale toggle flips sampled strings)

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const AutopilotLib := preload("res://scripts/world/autopilot.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
const AdviceLib := preload("res://scripts/world/advice.gd")
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const BattleResultLib := preload("res://scripts/combat/battle_result.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const CreationLib := preload("res://scenes/title/creation_screen.gd")
const CreationScene := preload("res://scenes/title/creation_screen.tscn")
const EndingScene := preload("res://scenes/ui_shared/ending_screen.tscn")

## Fixture officers (the test_autopilot pattern): stable ids, controlled
## skills, injected into DataLoader and removed again at the end.
const FIXTURE_PILOTS := {
	"off_pr8_pilot_35": 35,
	"off_pr8_pilot_45": 45,
	"off_pr8_pilot_50": 50,
	"off_pr8_pilot_70": 70,
}
const FIXTURE_COOK := "off_pr8_cook"

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var map = MapLoaderLib.new()
	_check(map.load_map("res://data/maps/world.png", DataLoader.map_legend),
		"map loads for the probe fixtures (%s)" % map.last_error)
	DataLoader.map = map
	var ocean = OceanLayersLib.instance()
	_check(ocean.decode_ok, "the ocean rasters decode (weighted lookups)")
	for id in FIXTURE_PILOTS:
		_install_officer(_pilot_card(id, int(FIXTURE_PILOTS[id])))

	_scenario_appointment_prereqs()
	_scenario_captain_commissioning()
	_scenario_capture_no_idle()
	await _scenario_two_step_creation()
	_scenario_advice_event()
	_scenario_retirement_segment()
	_scenario_appointed_voyage()
	_scenario_nemesis_lifecycle()
	_scenario_i18n_parity()
	_cleanup()
	_report()


# --- helpers ---------------------------------------------------------------

func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures.append(label)
		print("    FAIL %s" % label)


func _fresh_run(nation: String) -> void:
	GameState.new_game(nation, false)


## Injects a fixture officer card with the given navigation value (the only
## varying field; every consumer reads the card verbatim, §4.19).
func _pilot_card(id: String, nav: int, wage: int = 20) -> Dictionary:
	return {
		"id": id, "role": "", "main_skill": "navigation",
		"wage_daily": wage, "recruit_ports": ["lisbon"],
		"personality": ["honest"],
		"attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
			"courage": 40, "luck": 10},
		"skills": {"seamanship": 12, "navigation": nav, "swordplay": 0,
			"gunnery": 0, "appraisal": 0, "negotiation": 0, "cartography": 0,
			"rumour": 0, "medicine": 0, "carpentry": 0, "cooking": 0},
		"name": {"zh": "试·领航员%d" % nav, "en": "Probe Pilot %d" % nav},
		"bio": {"zh": "测试", "en": "Fixture"},
	}


func _install_officer(card: Dictionary) -> void:
	var id := str(card["id"])
	DataLoader.officers[id] = card
	DataLoader.officers_list.append(card)


## The real hire path (§4.5.5): Character.recruit pays the signing cost and
## seeds the officer_states entry; Skills.appoint seats the post.
func _hire_and_appoint(id: String, post: String) -> bool:
	if not CharacterLib.recruit(id):
		return false
	return SkillsLib.appoint(id, post)


func _fire_all() -> void:
	GameState.player["officers"] = []


## Seats a fixture pilot directly (the test_autopilot `_hire_pilot` seam):
## the roster swap + the seeded state block, so a pilot change needs no
## dismiss/recruit dance. Scenario 1 exercises the REAL recruit/appoint
## path instead.
func _seat_pilot(id: String) -> void:
	GameState.player["officers"] = [id]
	GameState.officer_states[id] = {"loyalty": 50, "sea_days": 0,
		"post_id": "pilot", "ship_id": "", "talk_cd_day": 0,
		"gift_cd_day": 0, "defeats": 0, "wage_mult": 1.0}


func _to_sea(port_id: String) -> void:
	GameState.current_port = null
	var berth: Vector2i = DataLoader.map.port_cell(port_id)
	if berth.x >= 0:
		GameState.set_world_tile(berth)


func _cancel_any() -> void:
	if AutopilotLib.appointed():
		AutopilotLib.cancel(AutopilotLib.REASON_MANUAL)
	GameState.world["weather"] = "fair"


func _cleanup() -> void:
	for id in FIXTURE_PILOTS:
		_drop_officer(id)
	_drop_officer(FIXTURE_COOK)
	_fire_all()
	GameState.player.erase("autopilot")
	AutopilotLib.cancel(AutopilotLib.REASON_MANUAL)
	if I18n.get_locale() != "en":
		I18n.set_locale("en")


func _drop_officer(id: String) -> void:
	DataLoader.officers.erase(id)
	for index in range(DataLoader.officers_list.size() - 1, -1, -1):
		var entry = DataLoader.officers_list[index]
		if entry is Dictionary and str(entry.get("id", "")) == id:
			DataLoader.officers_list.remove_at(index)


func _report() -> void:
	print("\n== demo_probe_phase8 summary ==")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
	else:
		print("%d of %d checks FAILED:" % [_failures.size(), _checks])
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)


# --- 1. appointment & prereqs (gate gray → key + route, no fee) -------------
func _scenario_appointment_prereqs() -> void:
	print("\n== 1. appointment & prereqs ==")
	_fresh_run("portugal")
	_to_sea("lisbon")
	# No pilot in post: the bare gate fails on the skill_gates reason row.
	var gate_row: Dictionary = DataLoader.get_skill_gate(
		AutopilotLib.GATE_FEATURE)
	_check(int(gate_row.get("threshold", 0)) == 40,
		"the skill_gates sail.autopilot row carries threshold 40")
	var none: Dictionary = AutopilotLib.gate()
	_check(not bool(none.get("ok", true))
		and str(none.get("reason_key", "")) == "sail.autopilot",
		"no pilot → gate not ok with the sail.autopilot reason key")
	var reason: String = AutopilotLib.reason_text(none)
	_check(not reason.is_empty() and reason.contains("40"),
		"the gray reason resolves through I18n and names the 40 (%s)" % reason)
	# A pilot under the threshold: hired through the REAL path, still gray.
	var cost_low := CharacterLib.recruit_cost("off_pr8_pilot_35")
	var gold := GameState.gold
	var hired_low := _hire_and_appoint("off_pr8_pilot_35", "pilot")
	_check(hired_low, "the nav-35 pilot recruits and takes the pilot post")
	_check(GameState.gold == gold - cost_low,
		"the signing cost is charged exactly (%d g)" % cost_low)
	var low: Dictionary = AutopilotLib.gate()
	_check(not bool(low.get("ok", true))
		and int(low.get("pilot_nav", -1)) == 35,
		"navigation 35 < 40 → the gate stays closed")
	# One under → at the threshold: dismiss + hire a nav-45 pilot.
	_check(CharacterLib.dismiss("off_pr8_pilot_35"),
		"the under-threshold pilot is dismissed (roster + state cleared)")
	_check(not GameState.officer_states.has("off_pr8_pilot_35"),
		"the dismissal cleared the officer_states entry")
	var hired_ok := _hire_and_appoint("off_pr8_pilot_45", "pilot")
	_check(hired_ok, "the nav-45 pilot recruits and takes the pilot post")
	if not ("seville" in (GameState.known_ports as Array)):
		GameState.known_ports.append("seville")
	var ok: Dictionary = AutopilotLib.gate("seville")
	_check(bool(ok.get("ok", false)) and int(ok.get("pilot_nav", -1)) == 45
		and bool(ok.get("dest_known", false)),
		"navigation 45 ≥ 40 + known destination → gate ok")
	var gold_before := GameState.gold
	var result: Dictionary = AutopilotLib.appoint("seville")
	_check(bool(result.get("ok", false)),
		"appoint(lisbon→seville) succeeds (%d steps)"
		% (result.get("route", []) as Array).size())
	var key = GameState.player.get("autopilot", null)
	_check(key is Dictionary and str(key.get("dest_port_id", "")) == "seville",
		"the save-v9 key player.autopilot = {dest_port_id} lands")
	_check(not (result.get("route", []) as Array).is_empty(),
		"a route exists (%d steps)" % (result.get("route", []) as Array).size())
	_check(GameState.gold == gold_before,
		"no gold fee (§4.19): the purse is untouched by the appointment")
	print("    signing cost (wage 20, CHA 10 → ×1.0): %d g · gate 40 · route %d steps"
		% [cost_low, (result.get("route", []) as Array).size()])
	_cancel_any()


# --- 2. captain commissioning (cost × charisma, post contribution) ----------
func _scenario_captain_commissioning() -> void:
	print("\n== 2. captain commissioning ==")
	_fresh_run("portugal")
	_to_sea("lisbon")
	# CHA 60 → the §4.2.1 price multiplier 0.75 (150/200), pinned in integer
	# arithmetic: ceil(wage × 10 × 150 / 200).
	GameState.player["attributes"]["charisma"] = 60
	var card := _pilot_card("off_pr8_commissioned", 36, 25)
	_install_officer(card)
	var expected_cost := (25 * 10 * (210 - 60) + 199) / 200
	var cost := CharacterLib.recruit_cost("off_pr8_commissioned")
	_check(cost == expected_cost,
		"the signing cost carries the charisma multiplier (%d = ceil(25×10×0.75))"
		% cost)
	var gold := GameState.gold
	_check(CharacterLib.recruit("off_pr8_commissioned"),
		"the officer recruits through the §4.5.5 path")
	_check(GameState.gold == gold - cost,
		"the purse drops by exactly the signing cost (%d g)" % cost)
	# The §4.8 officer_states entry is seeded: loyalty 50, idle, fresh clocks.
	var state: Dictionary = GameState.officer_states.get(
		"off_pr8_commissioned", {})
	_check(int(state.get("loyalty", -1)) == 50
		and int(state.get("sea_days", -1)) == 0
		and str(state.get("post_id", "x")) == ""
		and is_equal_approx(float(state.get("wage_mult", 0.0)), 1.0),
		"the officer_states entry seeds loyalty 50 / sea_days 0 / idle / ×1.0")
	# Appoint to the flagship pilot post (navigation 36 ≥ the 20 prereq).
	_check(SkillsLib.appoint("off_pr8_commissioned", "pilot"),
		"the appoint takes the pilot post (prereq navigation 36 ≥ 20)")
	var seated: Dictionary = GameState.officer_states.get(
		"off_pr8_commissioned", {})
	_check(str(seated.get("post_id", "")) == "pilot",
		"the state entry carries post_id pilot")
	# The §4.5.3 contribution: sighting reads effective navigation.
	var base_sighting := CharacterLib.sighting_radius_for(0)
	var effective := SkillsLib.effective_skill("navigation")
	var sighting := CharacterLib.sighting_radius()
	var player_nav := SkillsLib.skill("navigation")
	_check(effective == player_nav + 36,
		"effective navigation = the player's %d + the in-post officer's 36"
		% player_nav)
	_check(sighting == 48 + (player_nav + 36) / 12,
		"the sighting radius reads the effective value (48 + floor(%d/12) = %d)"
		% [player_nav + 36, sighting])
	_check(base_sighting == 48, "without the officer the base radius is 48")
	_check(int(CharacterLib.officer_wages()) == 25,
		"the daily ledger charges the officer's wage (25 g)")
	print("    signing %d g (CHA 60 → ×0.75) · sighting 48 → %d · wage %d g/day"
		% [cost, sighting, CharacterLib.officer_wages()])
	_fire_all()
	GameState.officer_states = {}
	GameState.player["attributes"]["charisma"] = 10


# --- 3. capture-no-idle ⇒ loot convert; idle officer ⇒ the hull joins -------
func _scenario_capture_no_idle() -> void:
	print("\n== 3. capture-no-idle ⇒ loot convert ==")
	_fresh_run("portugal")
	# A prize hull of a type the player does not sail (the flagship is a
	# caravel); durability 80 so the 25% transform is visible.
	var prize_type := ""
	var types: Array = DataLoader.ship_types.values() \
		if DataLoader.ship_types is Dictionary else []
	for ship_type in types:
		var id := str(ship_type.get("id", ""))
		if id != "" and id != "caravel":
			prize_type = id
			break
	_check(prize_type != "", "a prize ship_type exists (%s)" % prize_type)
	var free := FleetLib.free_capacity(GameState.fleet[0])

	# --- (a) zero idle officers → the gate names no_idle_officer ---------
	var seat := _pilot_card("off_pr8_gate_seat", 40)
	_install_officer(seat)
	_hire_and_appoint("off_pr8_gate_seat", "pilot")
	_check(SkillsLib.officers_in_post("").is_empty(),
		"the roster has no idle officer (the pilot holds the only post)")
	var hull_a := {
		"ship_type_id": prize_type, "durability": 80, "crew": 10,
		"cargo": {"wine": 6}, "provisions": 4, "water": 4, "equipment": {},
	}
	var outcome_a: Dictionary = BattleResultLib.apply({
		"result": "victory", "captured_enemy": [hull_a],
		"sunk_enemy": [prize_type], "lost_player": [], "sunk_player": [],
		"xp": 0, "salvage_gold": 0, "rep_deltas": {}, "morale_bonus": 0,
		"rounds": 3,
	}, [], GameState.fleet)
	_check(str(outcome_a.get("capture_gate_failed", "")) == "no_idle_officer",
		"zero idle officers → capture_gate_failed = no_idle_officer")
	_check((outcome_a.get("scuttled_ships", []) as Array) == [prize_type],
		"the prize is loot-converted and scuttled (%s)"
		% str(outcome_a.get("scuttled_ships", [])))
	_check((outcome_a.get("captured_ships", []) as Array).is_empty()
		and GameState.fleet.size() == 1,
		"no fleet growth (still %d hulls)" % GameState.fleet.size())
	var taken := mini(6, free)
	var expected_overflow := 6 - taken + 4 + 4
	_check(int(outcome_a.get("cargo_overflow_lost", -1)) == expected_overflow,
		"the loot-convert carries %d hold units (6 wine → %d taken, 8 burn)"
			% [expected_overflow, taken])
	_check(FleetLib.held("wine") == taken,
		"the scuttled cargo moved into the hold flagship-first (%d wine)"
		% taken)
	print("    gate no_idle_officer · scuttled 1 · overflow %d (free %d) · fleet stays 1"
		% [int(outcome_a.get("cargo_overflow_lost", 0)), free])

	# --- (b) with an idle officer → the hull joins at the transform -------
	var spare := _pilot_card("off_pr8_idle_spare", 30)
	_install_officer(spare)
	_check(CharacterLib.recruit("off_pr8_idle_spare"),
		"a second officer recruits and stays idle")
	_check(not SkillsLib.officers_in_post("").is_empty(),
		"the idle bench is ≥ 1 (the capture gate opens)")
	var hull_b := {
		"ship_type_id": prize_type, "durability": 80, "crew": 10,
		"cargo": {"wine": 6}, "provisions": 4, "water": 4, "equipment": {},
	}
	var outcome_b: Dictionary = BattleResultLib.apply({
		"result": "victory", "captured_enemy": [hull_b],
		"sunk_enemy": [prize_type], "lost_player": [], "sunk_player": [],
		"xp": 0, "salvage_gold": 0, "rep_deltas": {}, "morale_bonus": 0,
		"rounds": 3,
	}, [], GameState.fleet)
	_check(str(outcome_b.get("capture_gate_failed", "")) == "",
		"with an idle officer the capture gate does not fail")
	_check((outcome_b.get("captured_ships", []) as Array) == [prize_type],
		"the prize joins the fleet (%s)" % str(outcome_b.get("captured_ships", [])))
	_check(GameState.fleet.size() == 2,
		"the fleet grew 1 → %d" % GameState.fleet.size())
	var joined: Dictionary = GameState.fleet[1]
	var expected_dur: int = maxi(1, int(floor(80.0 * 0.25)))
	_check(int(joined.get("durability", -1)) == expected_dur,
		"the 25%% capture transform: 80 → %d durability" % expected_dur)
	_check(int(joined.get("crew", -1)) == 0,
		"the prize arrives with crew 0 (§4.11.7)")
	var wine_now := 0
	for ship in GameState.fleet:
		wine_now += int((ship as Dictionary).get("cargo", {}).get("wine", 0))
	print("    idle officer → joined · durability 80 → %d · fleet 1 → %d · wine %d"
		% [int(joined.get("durability", 0)), GameState.fleet.size(), wine_now])
	_fire_all()
	GameState.officer_states = {}
	GameState.fleet = []


# --- 4. two-step creation (handoff, caps, spread, gate, confirm) ------------
func _scenario_two_step_creation() -> void:
	print("\n== 4. two-step creation ==")
	_fresh_run("portugal")
	# The S2 → S20 handoff: the static carries the nation, _ready consumes it.
	CreationLib.pending_nation_id = "spain"
	var screen: Control = CreationScene.instantiate()
	add_child(screen)
	await get_tree().process_frame
	_check(CreationLib.pending_nation_id == "",
		"the S2→S20 handoff carrier is consumed by the screen's _ready")
	var grid: Control = screen.get_node("StepBackground")
	_check(grid.get_child_count() == 6,
		"step ① shows the 6 background cards (%d)" % grid.get_child_count())
	# Pick 海军见习生 (index 1: courage +3 / navigation +5) → step ②.
	(grid.get_child(1) as Button).pressed.emit()
	screen.confirm_selection()
	_check(screen._step == 2, "step ① confirm advances to the free points")
	# Steppers' caps: the courage extreme is the closed form 21.
	var courage_add: Button = screen.get_node(
		"StepPoints/Row_courage/Add")
	for _i in 4:
		courage_add.pressed.emit()
	_check(int(screen._attr_alloc.get("courage", 0)) == 3,
		"the per-item cap stops the + at 3 (courage base 10+5+3 → max 21)")
	var courage_label: Label = screen.get_node(
		"StepPoints/Row_courage/StatValue")
	_check(courage_label.text == "21",
		"the attribute extreme reads 21 (10+5+3+3, got %s)" % courage_label.text)
	var sword_label: Label = screen.get_node(
		"StepPoints/Row_swordplay/StatValue")
	var sword_add: Button = screen.get_node(
		"StepPoints/Row_swordplay/Add")
	for _i in 5:
		sword_add.pressed.emit()
	_check(int(screen._skill_alloc.get("swordplay", 0)) == 3
		and sword_label.text == "8",
		"the skill stepper caps at +3 (swordplay 5+3 = 8 ≤ 13)")
	# Spread evenly replaces the draft with the exact full budget.
	screen._on_spread()
	_check(int(screen._attr_alloc.get("courage", 0)) == 1
		and screen._attr_alloc.size() == 5,
		"spread evenly spends +1 on each of the five attributes")
	_check(screen._skill_alloc == {"seamanship": 1, "navigation": 1,
		"swordplay": 1},
		"spread evenly spends +1 on the first three skills")
	_check(screen._remaining_attr() == 0 and screen._remaining_skill() == 0,
		"the +5/+3 budget is spent exactly")
	var confirm: Button = screen.get_node("Confirm")
	_check(not confirm.disabled, "spend-all arms the confirm")
	# One point back → the must-spend-all gate re-arms.
	screen._on_step("seamanship", false, -1)
	_check(confirm.disabled, "a leftover point disables the confirm (must-spend-all)")
	screen._on_step("seamanship", false, 1)
	_check(not confirm.disabled, "spend-all re-arms the confirm")
	# The derived preview equals the closed forms on the draft.
	var pv: Dictionary = screen.preview_values()
	var draft: Dictionary = CharacterLib.starting_person("spain",
		"background_navy_cadet", screen._attr_alloc, screen._skill_alloc)
	var nav_val := int(draft["skills"]["navigation"])
	var sea_val := int(draft["skills"]["seamanship"])
	_check(int(pv["sighting_value"]) == CharacterLib.sighting_radius_for(nav_val),
		"the preview sighting equals the closed form (nav %d → %d)"
		% [nav_val, int(pv["sighting_value"])])
	_check(is_equal_approx(float(pv["speed_value"]),
			CharacterLib.speed_bonus_for(sea_val)),
		"the preview speed equals skill/300 (%0.4f)" % float(pv["speed_value"]))
	var saved_player: Dictionary = GameState.player
	GameState.player = draft
	var duel_expected: int = preload("res://scripts/combat/battle_sim.gd") \
		.player_duel_base()
	GameState.player = saved_player
	_check(int(pv["duel_value"]) == duel_expected,
		"the preview duel equals the §4.11.6 base (swordplay %d + floor(courage/20))"
		% duel_expected)
	# Confirm starts the run: the block carries nation/background/allocs.
	screen.route_after_confirm = false
	screen.confirm_selection()
	var player: Dictionary = GameState.player
	_check(str(player.get("nation_id", "")) == "spain",
		"the confirm runs new_game with the carried nation (spain)")
	_check(str(player.get("background_id", "")) == "background_navy_cadet",
		"the background persists in the player block")
	_check(int(player["attributes"]["courage"]) == 10 + 5 + 3 + 1,
		"courage = 10 base + 5 nation + 3 background + 1 alloc = 19")
	_check(int(player["skills"]["navigation"]) == 5 + 1
		and int(player["skills"]["swordplay"]) == 5 + 1
		and int(player["skills"]["seamanship"]) == 1,
		"the skill allocs land (nav 6 / swordplay 6 / seamanship 1)")
	print("    caps 21/8 · spread 5+3 · preview: sighting %d, speed %0.4f, duel %d → %d"
		% [int(pv["sighting_value"]), float(pv["speed_value"]),
		int(pv["duel_base"]), int(pv["duel_value"])])
	screen.queue_free()
	await get_tree().process_frame


# --- 5. advice event (cook + low morale; the seeded 3% roll fires) ----------
func _scenario_advice_event() -> void:
	print("\n== 5. advice event ==")
	_fresh_run("portugal")
	_to_sea("lisbon")
	# A cook seated in the cook post (prereq cooking ≥ 20), morale < 40:
	# the cook's situation holds on every scanned day.
	var cook := _pilot_card(FIXTURE_COOK, 0, 20)
	cook["main_skill"] = "cooking"
	cook["skills"]["cooking"] = 30
	cook["name"] = {"zh": "试·厨师", "en": "Probe Cook"}
	_install_officer(cook)
	_check(_hire_and_appoint(FIXTURE_COOK, "cook"),
		"the cook recruits and takes the cook post (prereq cooking 30 ≥ 20)")
	GameState.morale = 30
	_check(GameState.morale < 40, "morale sits below the cook's 40 threshold")
	# The 3% roll is deterministic per (day, officer): scan 1..200 for the
	# day the hash fires, resetting the queue each probe.
	var fired_day := 0
	var queue_len := 0
	for day in range(1, 201):
		AdviceLib.reset()
		queue_len = AdviceLib.day_tick(day)
		if queue_len >= 1:
			fired_day = day
			break
	_check(fired_day > 0,
		"a deterministic day fires the cook's advice (day %d of the 1..200 scan)"
		% fired_day)
	var drained: Array = AdviceLib.drain()
	_check(drained.size() == 1
		and str((drained[0] as Dictionary).get("key", "")) == "advice.cook.morale_low"
		and str((drained[0] as Dictionary).get("post", "")) == "cook"
		and str((drained[0] as Dictionary).get("officer_id", "")) == FIXTURE_COOK,
		"the queue holds exactly the cook's morale_low entry (%s)"
		% str(drained))
	_check(DataLoader.ui_strings.has("advice.cook.morale_low"),
		"the fired key exists in ui_strings (zh/en data)")
	_check(AdviceLib.drain().is_empty(),
		"drain empties the queue (the world renders each entry once)")
	# A day the hash does not fire queues nothing (the roll contract).
	var quiet := true
	for day in range(fired_day + 1, fired_day + 21):
		AdviceLib.reset()
		if AdviceLib.day_tick(day) > 0:
			quiet = false
			break
	_check(quiet,
		"the non-firing days after day %d queue nothing (3%% roll)"
		% fired_day)
	print("    cook seated · morale 30 · fire day %d/200 · key advice.cook.morale_low"
		% fired_day)
	_fire_all()
	GameState.officer_states = {}
	AdviceLib.reset()
	GameState.morale = 70


# --- 6. retirement segment (the RPG rows read the fixtures) -----------------
func _scenario_retirement_segment() -> void:
	print("\n== 6. retirement segment ==")
	_fresh_run("portugal")
	# Real canon ids so every name resolves (the test_retirement pattern).
	var captains: Array = DataLoader.captains_list
	var officers: Array = DataLoader.officers_list
	_check(captains.size() >= 4, "the canon roster is populated (%d)"
		% captains.size())
	var top := str(captains[0]["id"])    # 5 wins — the nemesis leader
	var duo_a := str(captains[1]["id"])  # 2 wins
	var duo_b := str(captains[2]["id"])  # 2 wins
	var grudge := str(captains[3]["id"]) # 0 wins, stance −9
	# The 2-win tie displays in captain-id order — order the fixture so.
	var tie: Array = [duo_a, duo_b]
	tie.sort()
	duo_a = str(tie[0])
	duo_b = str(tie[1])
	var veteran := str(officers[0]["id"])      # loyalty 88 over 120 days
	var short_timer := str(officers[1]["id"])  # loyalty 95 over 89 days only
	GameState.captain_states = {
		top: {"status": "returning", "return_day": 460, "tier_now": 1,
			"stance": 0, "familiarity": 4, "dossier_seen": true,
			"defeats": 1, "wins": 5},
		duo_a: {"status": "active", "return_day": 0, "tier_now": 3,
			"stance": -5, "familiarity": 2, "dossier_seen": true,
			"defeats": 0, "wins": 2},
		duo_b: {"status": "active", "return_day": 0, "tier_now": 2,
			"stance": -5, "familiarity": 2, "dossier_seen": true,
			"defeats": 0, "wins": 2},
		grudge: {"status": "active", "return_day": 0, "tier_now": 1,
			"stance": -9, "familiarity": 1, "dossier_seen": false,
			"defeats": 0, "wins": 0},
	}
	GameState.player["officers"] = [veteran, short_timer]
	GameState.officer_states = {
		veteran: {"loyalty": 88, "sea_days": 120, "post_id": "pilot",
			"ship_id": "", "talk_cd_day": 0, "gift_cd_day": 0,
			"defeats": 0, "wage_mult": 1.0},
		short_timer: {"loyalty": 95, "sea_days": 89, "post_id": "",
			"ship_id": "", "talk_cd_day": 0, "gift_cd_day": 0,
			"defeats": 0, "wage_mult": 1.0},
	}
	GameState.player["background_id"] = "background_deckhand"
	SaveSystem.last_loaded_retired = false
	SaveSystem.last_retired_summary = {}
	var screen: Control = EndingScene.instantiate()
	add_child(screen)
	await get_tree().process_frame
	var rpg: VBoxContainer = screen.get_node("Center/Panel/Margin/Body/RpgRows")
	_check(rpg.has_node("Row_rpg_nemesis_0"), "the nemesis ranking renders")
	var leader_text: String = (rpg.get_node("Row_rpg_nemesis_0") as Label).text
	_check(leader_text == I18n.fmt("ending.rpg.nemesis_row", {
			"name": I18n.t(DataLoader.get_captain(top).get("name", {})),
			"tier": 1, "stance": 0}),
		"the nemesis leader is the 5-win captain (%s)" % leader_text)
	var tie_text: String = (rpg.get_node("Row_rpg_nemesis_1") as Label).text
	_check(tie_text == I18n.fmt("ending.rpg.nemesis_row", {
			"name": I18n.t(DataLoader.get_captain(duo_a).get("name", {})),
			"tier": 3, "stance": -5}),
		"the 2-2 tie orders by captain id (first %s)" % duo_a)
	var grudge_text: String = (rpg.get_node("Row_rpg_grudge") as Label).text
	_check(grudge_text == I18n.fmt("ending.rpg.grudge", {
			"name": I18n.t(DataLoader.get_captain(grudge).get("name", {}))}),
		"the deepest grudge is the lowest negative stance (−9, 0 wins)")
	var veteran_text: String = (rpg.get_node("Row_rpg_veteran") as Label).text
	_check(veteran_text == I18n.fmt("ending.rpg.veteran", {
			"name": I18n.t(DataLoader.get_officer(veteran).get("name", {})),
			"days": 120}),
		"the veteran is the ≥90-day highest loyalty (88 over 120; 95 over 89 "
		+ "is ineligible) (%s)" % veteran_text)
	var bio_text: String = (rpg.get_node("Row_rpg_bio") as Label).text
	_check(bio_text.contains(I18n.t(
			DataLoader.get_background("background_deckhand")["bio"])),
		"the bio row recalls the background's data bio")
	_check(rpg.get_child_count() == 7,
		"header + 3 nemesis rows + grudge + veteran + bio (%d rows)"
		% rpg.get_child_count())
	print("    nemesis leader wins 5 · grudge stance −9 · veteran 120 sea-days "
		+ "· %d RPG rows" % rpg.get_child_count())
	screen.queue_free()
	await get_tree().process_frame
	GameState.captain_states = {}
	GameState.officer_states = {}
	GameState.player["officers"] = []


# --- 7. appointed voyage (gate gray, weights, contact vs storm) -------------
func _scenario_appointed_voyage() -> void:
	print("\n== 7. appointed voyage ==")
	_fresh_run("portugal")
	_to_sea("lisbon")
	# (a) The gate gray: no pilot → not ok, the reason text renders.
	var gray: Dictionary = AutopilotLib.gate()
	_check(not bool(gray.get("ok", true))
		and not AutopilotLib.reason_text(gray).is_empty(),
		"the gate is gray without a pilot (reason text renders)")
	# (b) Contact cancels: a cheap plain OD (lisbon→seville).
	_seat_pilot("off_pr8_pilot_45")
	if not ("seville" in (GameState.known_ports as Array)):
		GameState.known_ports.append("seville")
	_check(bool(AutopilotLib.appoint("seville").get("ok", false)),
		"the seville appointment stands (plain pilot)")
	_check(AutopilotLib.cancel(AutopilotLib.REASON_CONTACT)
		and GameState.player.get("autopilot", null) == null,
		"cancel(\"contact\") returns true and clears the key")
	_check(not AutopilotLib.cancel(AutopilotLib.REASON_CONTACT),
		"a second contact cancel is a no-op (nothing appointed)")
	# (c) A storm does NOT cancel: auto-reef fires, then restores.
	_check(bool(AutopilotLib.appoint("seville").get("ok", false)),
		"the seville appointment stands again")
	GameState.world["weather"] = "storm"
	GameState.world["sail_trim"] = "full"
	var storm_tick: Dictionary = AutopilotLib.tick()
	_check(bool(storm_tick.get("appointed", false)),
		"a storm day does NOT cancel the appointment")
	_check(GameState.player.get("autopilot", null) != null
		and SailingSimLib.sail_trim() == "reefed",
		"the key survives and the trim auto-reefs (storm damage ×0.75)")
	GameState.world["weather"] = "fair"
	AutopilotLib.tick()
	_check(SailingSimLib.sail_trim() == "full"
		and AutopilotLib.appointed(),
		"the first fair tick restores the trim and keeps the appointment")
	_cancel_any()
	# (d) The weights: lisbon → malacca in month 1, nav 70 vs nav 50.
	GameState.day = 1
	if not ("malacca" in (GameState.known_ports as Array)):
		GameState.known_ports.append("malacca")
	var from_cell: Vector2i = DataLoader.map.port_cell("lisbon")
	_seat_pilot("off_pr8_pilot_70")
	var weighted: Dictionary = AutopilotLib.appoint("malacca")
	_check(bool(weighted.get("ok", false))
		and bool(weighted.get("weighted", false)),
		"the nav-70 pilot gets the weighted A* (§4.19 route quality)")
	var w_route: Array = weighted.get("route", [])
	_check(not w_route.is_empty()
		and w_route.back() == DataLoader.map.port_cell("malacca"),
		"the weighted route ends on malacca's berth (%d steps)" % w_route.size())
	_seat_pilot("off_pr8_pilot_50")
	var plain: Dictionary = AutopilotLib.appoint("malacca")
	_check(bool(plain.get("ok", false))
		and not bool(plain.get("weighted", true)),
		"the nav-50 pilot gets the plain shortest-water A*")
	var p_route: Array = plain.get("route", [])
	_check(not p_route.is_empty(), "the plain route exists (%d steps)"
		% p_route.size())
	var w_cost: float = AutopilotLib.route_cost_days(from_cell, w_route)
	var p_cost: float = AutopilotLib.route_cost_days(from_cell, p_route)
	var w_regions: Array = AutopilotLib.route_wind_regions(from_cell, w_route)
	var p_regions: Array = AutopilotLib.route_wind_regions(from_cell, p_route)
	var cheaper := w_cost <= p_cost * 0.85
	_check(cheaper or w_regions != p_regions,
		"weighted measurably differs from plain (≥15%% cheaper: %s · regions differ: %s)"
			% [str(cheaper), str(w_regions != p_regions)])
	print("    weighted: %d steps, %.1f cost-days · plain: %d steps, %.1f cost-days · ratio %.3f · regions differ: %s"
		% [w_route.size(), w_cost, p_route.size(), p_cost, w_cost / p_cost,
		str(w_regions != p_regions)])
	_cancel_any()


# --- 8. nemesis lifecycle (stance, return queue, hunter re-spawn, clamps) ---
func _scenario_nemesis_lifecycle() -> void:
	print("\n== 8. nemesis lifecycle ==")
	_fresh_run("portugal")
	# A pirate canon card at stance −3 is a nemesis; a trader never is.
	var pirate := {}
	var trader := {}
	for card in DataLoader.captains_list:
		if pirate.is_empty() and str(card.get("role", "")) == "pirate":
			pirate = card
		if trader.is_empty() and str(card.get("role", "")) == "trader":
			trader = card
		if not pirate.is_empty() and not trader.is_empty():
			break
	_check(not pirate.is_empty(), "a pirate canon card exists (%s)"
		% str(pirate.get("id", "")))
	var pirate_id := str(pirate.get("id", ""))
	_check(CaptainsLib.adjust_stance(pirate_id, -3) == -3,
		"the pirate's stance sinks to −3")
	_check(CaptainsLib.is_nemesis(pirate_id),
		"stance ≤ −3 + pirate role ⇒ is_nemesis")
	if not trader.is_empty():
		var trader_id := str(trader.get("id", ""))
		CaptainsLib.adjust_stance(trader_id, -3)
		_check(not CaptainsLib.is_nemesis(trader_id),
			"a trader at −3 is never a nemesis (the role gate)")
	# The defeat books the return queue at day + 60.
	var st: Dictionary = CaptainsLib.defeat(pirate_id, 5, false)
	_check(str(st.get("status", "")) == "returning"
		and int(st.get("return_day", 0)) == 65,
		"the defeat books returning @ day+60 (65)")
	# Tier drift clamps at 1 and 3 (a second pirate card keeps the fixture
	# independent of the lifecycle drive below).
	var clamp_pirate := {}
	for card in DataLoader.captains_list:
		if str(card.get("role", "")) == "pirate" \
				and str(card.get("id", "")) != pirate_id:
			clamp_pirate = card
			break
	var clamp_id := str(clamp_pirate.get("id", ""))
	CaptainsLib.ensure(clamp_id)["tier_now"] = 1
	for _i in 5:
		CaptainsLib.win(clamp_id, 10)
	_check(int(CaptainsLib.state(clamp_id).get("tier_now", 0)) == 3,
		"win drift +1 clamps at tier 3 (5 wins from tier 1)")
	CaptainsLib.ensure(clamp_id)["tier_now"] = 1
	CaptainsLib.defeat(clamp_id, 10, true)
	_check(int(CaptainsLib.state(clamp_id).get("tier_now", 0)) == 1,
		"crushed-defeat drift −1 clamps at tier 1")
	# The re-spawn path: a spawned pirate fleet, defeated at stance −3,
	# returns on its return_day AS a nationless hunter (the §9c seam).
	var sim: NpcFleetsLib = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "normal",
	})
	var spawned := sim.spawn("pirate", "", 5)
	_check(not spawned.is_empty(), "the fixture spawns a pirate fleet")
	var nemesis_id := str(spawned.get("captain_id", ""))
	_check(not nemesis_id.is_empty(), "the fleet carries a canon captain")
	CaptainsLib.defeat(nemesis_id, 5, false)
	CaptainsLib.state(nemesis_id)["stance"] = -3
	sim.remove(str(spawned.get("id", "")))
	sim.reset_rng(20261103)
	var return_day := 0
	for day in range(6, 66):
		GameState.day = day
		sim.tick(day)
		if return_day == 0:
			for fleet in GameState.npc_fleets:
				if str(fleet.get("captain_id", "")) == nemesis_id:
					return_day = day
					break
	var hunter := {}
	for fleet in GameState.npc_fleets:
		if str(fleet.get("captain_id", "")) == nemesis_id:
			hunter = fleet
			break
	_check(not hunter.is_empty(),
		"the nemesis returns on its return_day carrying its own card (day %d)"
		% return_day)
	if not hunter.is_empty():
		_check(str(hunter.get("role", "")) == "hunter",
			"the nemesis books a hunter-role fleet (%s)"
			% str(hunter.get("role", "")))
		_check(str(hunter.get("nation_id", "")) == "",
			"the nemesis hunter is nationless (lightweight)")
	print("    nemesis %s · return_day 65 · tier clamps 1/3 · hunter spawned day %d"
		% [pirate_id, return_day])
	GameState.npc_fleets = []
	GameState.captain_states = {}
	GameState.day = 1


# --- 9. zh/en parity ---------------------------------------------------------
func _scenario_i18n_parity() -> void:
	print("\n== 9. zh/en parity ==")
	var sampled := {
		"advice.cook.morale_low": "advice family",
		"creation.spread": "creation family",
		"sail.autopilot.cancelled_contact": "gate family",
	}
	var zh := I18n.get_locale()
	var complete := 0
	for key in sampled:
		var entry: Dictionary = DataLoader.ui_strings.get(key, {})
		var zh_text := str(entry.get("zh", ""))
		var en_text := str(entry.get("en", ""))
		_check(not zh_text.is_empty() and not en_text.is_empty()
			and zh_text != en_text,
			"%s carries distinct zh/en strings (%s)" % [key, sampled[key]])
		complete += 1 if not zh_text.is_empty() and not en_text.is_empty() else 0
	# A canon card name flips too (the zh/en rule covers data cards).
	var card: Dictionary = DataLoader.get_captain("khair_ad_din")
	if card.is_empty() and not DataLoader.captains_list.is_empty():
		card = DataLoader.captains_list[0]
	_check(not I18n.t(card.get("name", {})).is_empty(),
		"a canon captain's name resolves in the active locale (%s)"
		% str(card.get("id", "")))
	# The runtime toggle flips a sampled string both ways.
	I18n.set_locale("zh")
	_check(I18n.t_key("creation.spread")
		== str((DataLoader.ui_strings.get("creation.spread", {})
		as Dictionary).get("zh", "")),
		"locale zh renders the zh string (均匀分配)")
	I18n.set_locale("en")
	_check(I18n.t_key("creation.spread")
		== str((DataLoader.ui_strings.get("creation.spread", {})
		as Dictionary).get("en", "")),
		"locale en renders the en string (Spread evenly)")
	# The full table: zh/en complete on every key.
	var missing := 0
	for key in DataLoader.ui_strings:
		var entry: Dictionary = DataLoader.ui_strings.get(key, {})
		if str(entry.get("zh", "")).is_empty() \
				or str(entry.get("en", "")).is_empty():
			missing += 1
	_check(missing == 0, "every ui_strings key carries zh AND en (%d missing)"
		% missing)
	print("    sampled %d/%d families flip · ui_strings %d keys zh/en complete"
		% [complete, sampled.size(), DataLoader.ui_strings.size()])
	I18n.set_locale(zh if not zh.is_empty() else "en")
