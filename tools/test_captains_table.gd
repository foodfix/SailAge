extends Node
## Phase-8 W5-C acceptance tests (docs/80-UI-UX.md §4.11 — the in-port verb
## matrices, the captains' table; docs/30-PORTS-AND-TRADE.md §4.8 captain-intel
## rows; docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.5 inform-on-pirates).
##
##   godot --headless res://tools/test_captains_table.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections
##   0 sparring math (§4.11.1): the locked constants, the p closed form at
##     swordplay 0/40/100 → 0.10/0.50/0.90, pot ×2 on a win, the 3-usage
##     award, stake validation (100–1,000 by 100s) and the refusal paths;
##   1 befriend (§4.11.1): stance +1, once per captain per port-visit day;
##   2 the captains' table (§4.11.2): this port's sightings with name/role/
##     tier/last-seen/facility, +1 familiarity per viewed row (real screen);
##   3 inn limited talk (§4.11.1): +1 extra familiarity, once per port visit;
##   4 inform-on-pirates (70-* §4.5): the fixed 500g reveal through the
##     bounty-pinpoint pipeline + the bounty-row dossier entries (§4.11.3);
##   5 market captain-intel rows (30-* §4.8): the free marker only at
##     stance ≥ +2, with the next-lane hint.

const TavernEngineLib := preload("res://scripts/port/tavern_engine.gd")
const InnEngineLib := preload("res://scripts/port/inn_engine.gd")
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const CaptainsLib := preload("res://scripts/world/captains.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")
const NpcIntelLib := preload("res://scripts/world/npc_intel.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const TavernScene := preload("res://scenes/port/tavern_screen.tscn")
const MarketScene := preload("res://scenes/port/market_screen.tscn")
const PalaceScene := preload("res://scenes/port/palace_screen.tscn")

## Canon fixtures (data/captains.json — read-only canon).
const TRADER_ID := "cap_trader_0001"
const TRADER2_ID := "cap_trader_0002"
const PIRATE_ID := "pirate_edward_bloodhand"
const HUNTER_ID := "cap_hunter_0001"

## The §4.11.1 locked sparring numbers.
const SPAR_CHAMPION := 40
const STANCE_INTEL := 2

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_spar_math()
	_test_befriend_guard()
	await _test_captains_table()
	_test_inn_talk()
	await _test_inform_and_dossier()
	await _test_market_intel()
	_report()


# --- Fixtures ---------------------------------------------------------------

## A docked run at Lisbon, 12:00 (tavern 10:00–24:00 and palace 09:00–17:00
## both open), a deep purse, zero swordplay so the award pins read cleanly.
## The seeded initial fill is cleared: the fixture fleets are the ONLY traffic.
func _make_run(gold: int = 100000) -> void:
	GameState.new_game("portugal", false, "world")
	GameState.day = 10
	GameState.world["clock_fraction"] = 0.5
	GameState.gold = gold
	GameState.npc_fleets = []
	GameState.npc_port_log = []
	GameState.captain_states = {}
	GameState.market_events = []
	CaptainsLib.reset_deployments()
	TavernEngineLib.reset_visit_guards()
	InnEngineLib.reset_visit_guards()
	var skills: Dictionary = GameState.player.get("skills", {})
	skills["swordplay"] = 0
	GameState.player["skills"] = skills
	var counters: Dictionary = GameState.player.get("skill_counters", {})
	counters["swordplay"] = 0
	GameState.player["skill_counters"] = counters


## A docked fixture fleet at Lisbon with `captain_id` aboard. The seeded
## presence roll (§4.7.8) is 75/25, so candidate fleet ids are scanned until
## the roll says PRESENT (deterministic per id+day; the scan is a fixture
## search, not a Monte-Carlo re-derivation). `{}` when 50 draws all fail.
func _present_fleet(prefix: String, captain_id: String, role: String) -> Dictionary:
	var berth := DataLoader.port_cell("lisbon")
	for attempt in 50:
		var fleet := {
			"id": "%s_%d" % [prefix, attempt],
			"role": role, "nation_id": "england",
			"cell": {"x": berth.x, "y": berth.y},
			"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
			"cargo": {},
			"captain_id": captain_id,
			"cooldown_until_day": 0, "seed": 424242,
			"dest_port_id": "seville",
			"dwell_until_day": GameState.day + 2, "anchor_cell": null,
			"target_fleet_id": "", "hunter_state": "", "loiter_until_day": 0,
			"home_port_id": "",
		}
		if NpcIntelLib.is_present(fleet, "lisbon"):
			GameState.npc_fleets.append(fleet)
			return fleet
	return {}


## The docked twin of [method _present_fleet]: scans until the roll says GONE
## ASHORE (the §4.7.8 25% arm).
func _ashore_fleet(prefix: String, captain_id: String, role: String) -> Dictionary:
	var berth := DataLoader.port_cell("lisbon")
	for attempt in 50:
		var fleet := {
			"id": "%s_%d" % [prefix, attempt],
			"role": role, "nation_id": "england",
			"cell": {"x": berth.x, "y": berth.y},
			"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
			"cargo": {},
			"captain_id": captain_id,
			"cooldown_until_day": 0, "seed": 424242,
			"dest_port_id": "",
			"dwell_until_day": GameState.day + 2, "anchor_cell": null,
			"target_fleet_id": "", "hunter_state": "", "loiter_until_day": 0,
			"home_port_id": "",
		}
		if not NpcIntelLib.is_present(fleet, "lisbon"):
			GameState.npc_fleets.append(fleet)
			return fleet
	return {}


## A tavern-facility fixture (§4.7.8: the seeded 60/40 roll landed on the
## tavern) so the interactive sighting row renders.
func _tavern_fleet(captain_id: String, role: String) -> Dictionary:
	var berth := DataLoader.port_cell("lisbon")
	for attempt in 80:
		var fleet := {
			"id": "fx_tav_%s_%d" % [captain_id, attempt],
			"role": role, "nation_id": "england",
			"cell": {"x": berth.x, "y": berth.y},
			"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
			"cargo": {},
			"captain_id": captain_id,
			"cooldown_until_day": 0, "seed": 424242,
			"dest_port_id": "",
			"dwell_until_day": GameState.day + 2, "anchor_cell": null,
			"target_fleet_id": "", "hunter_state": "", "loiter_until_day": 0,
			"home_port_id": "",
		}
		if NpcIntelLib.is_present(fleet, "lisbon") \
				and NpcIntelLib.facility_of(fleet, "lisbon") == "tavern":
			GameState.npc_fleets.append(fleet)
			return fleet
	return {}


## An at-sea pirate/privateer near Lisbon (Chebyshev 3 of the berth) — the
## wanted-poster / inform target (§4.7.8: at-sea only, no presence roll).
func _at_sea_pirate() -> Dictionary:
	var berth := DataLoader.port_cell("lisbon")
	var fleet := {
		"id": "fx_pirate_sea",
		"role": "pirate", "nation_id": "",
		"cell": {"x": berth.x + 3, "y": berth.y},
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {},
		"captain_id": PIRATE_ID,
		"cooldown_until_day": 0, "seed": 424242,
		"dest_port_id": "",
		"dwell_until_day": 0, "anchor_cell": null,
		"target_fleet_id": "", "hunter_state": "", "loiter_until_day": 0,
		"home_port_id": "",
	}
	GameState.npc_fleets.append(fleet)
	return fleet


func _drop(node: Node) -> void:
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.free()


# --- 0. Sparring math (docs/80-* §4.11.1) ------------------------------------

func _test_spar_math() -> void:
	_make_run()
	# The locked numbers, pinned as constants.
	_check(TavernEngineLib.SPAR_STAKE_MIN == 100, "stake band starts at 100g")
	_check(TavernEngineLib.SPAR_STAKE_MAX == 1000, "stake band ends at 1,000g")
	_check(TavernEngineLib.SPAR_STAKE_STEP == 100, "stake step is 100g")
	_check(TavernEngineLib.SPAR_CHAMPION_SWORDPLAY == SPAR_CHAMPION,
		"the tavern champion's swordplay is 40")
	_check(TavernEngineLib.SPAR_USES_PER_BOUT == 3,
		"each bout counts as 3 swordplay usages")

	# The p closed form `clamp(0.5 + (es − 40)/200, 0.10, 0.90)`: at the
	# playable band 0..100 it reads 0.30 / 0.50 / 0.80 (the champion's 40 is
	# the 0.50 point); the 0.10 / 0.90 clamps engage outside it and are pinned
	# through the same pure function.
	_check(is_equal_approx(TavernEngineLib.spar_win_chance(0), 0.30),
		"p(swordplay 0) is 0.30 (%f)" % TavernEngineLib.spar_win_chance(0))
	_check(is_equal_approx(TavernEngineLib.spar_win_chance(40), 0.50),
		"p(swordplay 40) is exactly 0.50 (even with the champion)")
	_check(is_equal_approx(TavernEngineLib.spar_win_chance(100), 0.80),
		"p(swordplay 100) is 0.80 (%f)" % TavernEngineLib.spar_win_chance(100))
	_check(is_equal_approx(TavernEngineLib.spar_win_chance(-160), 0.10),
		"the p floor clamps at 0.10 (%f)" % TavernEngineLib.spar_win_chance(-160))
	_check(is_equal_approx(TavernEngineLib.spar_win_chance(140), 0.90),
		"the p ceiling clamps at 0.90 (%f)" % TavernEngineLib.spar_win_chance(140))
	_check(is_equal_approx(TavernEngineLib.spar_win_chance(60), 0.60),
		"p(swordplay 60) is 0.60 (+20/200 over the base)")

	# Stake validation: 100–1,000 by 100s, nothing else.
	for good in [100, 200, 500, 900, 1000]:
		_check(TavernEngineLib.spar_valid_stake(good),
			"stake %d is valid" % good)
	for bad in [0, 50, 99, 150, 1001, 1100, 2000, -100]:
		_check(not TavernEngineLib.spar_valid_stake(bad),
			"stake %d is invalid" % bad)
	_check(TavernEngineLib.spar_step(100, -1) == 100,
		"the stepper clamps at the 100g floor")
	_check(TavernEngineLib.spar_step(1000, 1) == 1000,
		"the stepper clamps at the 1,000g ceiling")
	_check(TavernEngineLib.spar_step(300, 1) == 400
		and TavernEngineLib.spar_step(300, -1) == 200,
		"the stepper moves in 100g steps")

	# The pot: a win pays pot × 2 (net +stake), a loss forfeits the stake.
	_check(TavernEngineLib.spar_pot(100) == 200, "a win pays pot × 2 (200)")

	# One winning bout at p = 0.50: swordplay 40 vs the champion, roll 0.0.
	GameState.player["skills"]["swordplay"] = 40
	var before_gold := GameState.gold
	var result: Dictionary = TavernEngineLib.spar(100, 0.0)
	_check(not result.is_empty(), "spar(100, 0.0) runs")
	_check(bool(result.get("won", false)), "roll 0.0 wins at p 0.50")
	_check(is_equal_approx(float(result.get("chance", 0.0)), 0.50),
		"the result carries the p 0.50 chance")
	_check(GameState.gold == before_gold - 100 + 200,
		"a win returns pot × 2 (net +100; got %d)" % GameState.gold)

	# The 3-usage award: swordplay's threshold is 1 use, so a bout's 3 usages
	# fire exactly one +1 growth award and reset the counter (0 → 1 → 0).
	_check(SkillsLib.growth_threshold("swordplay") == 1,
		"swordplay grows per 1 use (the §4.3.1 table)")
	GameState.player["skills"]["swordplay"] = 0
	GameState.player["skill_counters"]["swordplay"] = 0
	TavernEngineLib.spar(100, 0.0)
	_check(int(GameState.player["skills"]["swordplay"]) == 1,
		"a bout notes its usages and awards the growth (+1)")
	_check(int(GameState.player["skill_counters"]["swordplay"]) == 0,
		"the counter resets after the award")

	# One losing bout: roll 0.9 ≥ p 0.50 forfeits the 100g stake.
	GameState.player["skills"]["swordplay"] = 40
	before_gold = GameState.gold
	result = TavernEngineLib.spar(300, 0.9)
	_check(not result.is_empty(), "spar(300, 0.9) runs")
	_check(not bool(result.get("won", true)), "roll 0.9 loses at p 0.50")
	_check(GameState.gold == before_gold - 300,
		"a loss forfeits the stake (net −300; got %d)" % GameState.gold)

	# Refusals leave everything untouched: bad stake, short purse, closed door.
	before_gold = GameState.gold
	_check(TavernEngineLib.spar(150, 0.0).is_empty(),
		"an off-step stake is refused")
	_check(GameState.gold == before_gold, "a refused bout charges nothing")
	_make_run(99)
	_check(TavernEngineLib.spar(100, 0.0).is_empty(),
		"a short purse is refused (99g < 100g stake)")
	_check(GameState.gold == 99, "the purse is untouched on refusal")
	_make_run()
	GameState.world["clock_fraction"] = 0.0  # 00:00 — the tavern is closed
	_check(not TavernEngineLib.can_spar(100),
		"the §4.1b closed rule refuses a bout at 00:00")
	_check(TavernEngineLib.spar(100, 0.0).is_empty(),
		"no bout starts behind a closed tavern door")


# --- 1. Befriend (docs/80-* §4.11.1 — the hail rule) -------------------------

func _test_befriend_guard() -> void:
	_make_run()
	_check(CaptainsLib.STANCE_BEFRIEND == 1, "befriend is the shared +1 delta")
	_check(CaptainsLib.stance(TRADER_ID) == 0, "a fresh captain stands at 0")
	_check(TavernEngineLib.can_befriend(TRADER_ID, "lisbon"),
		"the first befriend of the visit is available")
	var stance := TavernEngineLib.befriend(TRADER_ID, "lisbon")
	_check(stance == 1, "befriend applies stance +1 (got %d)" % stance)
	_check(CaptainsLib.stance(TRADER_ID) == 1, "the stance state reads 1")
	_check(not TavernEngineLib.can_befriend(TRADER_ID, "lisbon"),
		"the guard consumed this visit's befriend")
	_check(TavernEngineLib.befriend(TRADER_ID, "lisbon") == 1,
		"a refused befriend leaves the stance at 1")
	# Another captain is unaffected by the guard...
	_check(TavernEngineLib.can_befriend(TRADER2_ID, "lisbon"),
		"the guard is per captain")
	# ...and the same captain is available again on the NEXT visit-day.
	GameState.day = 11
	_check(TavernEngineLib.can_befriend(TRADER_ID, "lisbon"),
		"the next visit-day re-arms the guard")
	# Another port's visit has its own (unused) guard.
	_check(TavernEngineLib.can_befriend(TRADER_ID, "seville"),
		"another port's visit has its own guard")
	# An empty id is never befriended.
	_check(not TavernEngineLib.can_befriend("", "lisbon"),
		"an empty captain id is refused")
	TavernEngineLib.reset_visit_guards()
	_check(TavernEngineLib.can_befriend(TRADER_ID, "lisbon"),
		"reset_visit_guards() re-arms everything (suite seam)")


# --- 2. The captains' table (docs/80-* §4.11.2) ------------------------------

func _test_captains_table() -> void:
	_make_run()
	var trader := _present_fleet("fx_tr", TRADER_ID, "trader")
	var ashore := _ashore_fleet("fx_as", TRADER2_ID, "trader")
	_check(not trader.is_empty(), "a present docked fixture exists")
	_check(not ashore.is_empty(), "a gone-ashore fixture exists")

	var screen = TavernScene.instantiate()
	screen.route_to_port = false
	add_child(screen)
	await get_tree().process_frame
	screen.select_tab("rumors")

	# The table lists THIS port's present sightings — the ashore captain is
	# absent from it (§4.7.8: absent from every facility that day).
	var rows: Array = screen.table_rows()
	_check(rows.size() == 1, "the table lists exactly the present sighting (%d)"
		% rows.size())
	var row: Dictionary = rows[0] if not rows.is_empty() else {}
	_check(str(row.get("captain_id", "")) == TRADER_ID,
		"the row carries the canon captain id")
	_check(str(row.get("name", "")) == I18n.t(
			CaptainsLib.captain(TRADER_ID).get("name", {})),
		"the row carries the canon name (%s)" % str(row.get("name", "")))
	_check(str(row.get("role", "")) == "trader", "the row carries the role")
	_check(int(row.get("tier", 0)) == int(CaptainsLib.captain(TRADER_ID)
		.get("tier", 0)), "the row carries the canon tier")
	_check(int(row.get("last_seen_day", -1)) == NpcIntelLib.arrival_day_of(trader),
		"the row carries the last-seen day (the arrival day)")
	var facility := NpcIntelLib.facility_of(trader, "lisbon")
	_check(str(row.get("facility", "")) == facility,
		"the row carries the rolled facility pointer (%s)" % facility)

	# Viewing adds familiarity +1 (each row viewed).
	var before := CaptainsLib.familiarity(TRADER_ID)
	var box: Control = screen.get_node(
		"body/RumorsPanel/CaptainsTable")
	var row_node: Control = box.get_node("TableRow_%s" % TRADER_ID)
	var inspect: Button = row_node.get_node("Inspect")
	_check(inspect.text == I18n.t_key("interact.verb.inspect"),
		"the inspect verb is labeled from interact.verb.inspect")
	inspect.pressed.emit()
	_check(CaptainsLib.familiarity(TRADER_ID) == before + 1,
		"viewing a row adds familiarity +1")
	_check(not str(screen.last_inspect_text).is_empty(),
		"the inspect placeholder renders a summary line (%s)"
		% str(screen.last_inspect_text))
	# And viewing again adds again (each view counts).
	inspect.pressed.emit()
	_check(CaptainsLib.familiarity(TRADER_ID) == before + 2,
		"a second view adds familiarity again")

	# The sparring row is on the same tab, with its stake stepper.
	var spar_box: Control = screen.get_node(
		"body/RumorsPanel/SparRow")
	var down: Button = spar_box.get_node("StakeDown")
	var up: Button = spar_box.get_node("StakeUp")
	_check(screen.spar_stake_value() == 100, "the stake starts at 100g")
	up.pressed.emit()
	_check(screen.spar_stake_value() == 200, "the + stepper adds 100g")
	down.pressed.emit()
	_check(screen.spar_stake_value() == 100, "the − stepper subtracts 100g")
	# One seeded bout through the row: the purse feels exactly one bet and
	# the result line stays after the bout's `gold_changed` rebuild.
	GameState.player["skills"]["swordplay"] = 40
	var gold := GameState.gold
	screen.place_spar_bet()
	_check(not screen.last_spar.is_empty(), "the row's bet runs (seeded roll)")
	_check(absi(GameState.gold - gold) == 100,
		"one bout moves the purse by exactly ±stake (got %d)"
		% absi(GameState.gold - gold))
	_check(spar_box.get_node_or_null("SparResult") != null,
		"the bout's result line renders and survives the rebuild")

	# The sighting row's befriend verb through the real row: +1 stance once,
	# then the row grays with the used term (the hail rule).
	TavernEngineLib.reset_visit_guards()
	var tav := _tavern_fleet(TRADER_ID, "coaster")
	_check(not tav.is_empty(), "a tavern-facility fixture exists")
	screen.refresh()
	var rumor_rows: Control = screen.get_node(
		"body/RumorsPanel/Scroll/Rows")
	var captain_node: Control = rumor_rows.get_node("Captain_%s"
		% str(tav["id"]))
	var befriend: Button = captain_node.get_node("Befriend")
	_check(befriend.text == I18n.t_key("hail.option.befriend"),
		"the sighting row carries the befriend verb")
	_check(not befriend.disabled, "the verb is armed before the first befriend")
	var stance_before := CaptainsLib.stance(TRADER_ID)
	befriend.pressed.emit()
	_check(CaptainsLib.stance(TRADER_ID) == stance_before + 1,
		"pressing the row's befriend applies stance +1")
	var befriend_after: Button = rumor_rows.get_node(
		"Captain_%s/Befriend" % str(tav["id"]))
	_check(befriend_after.disabled,
		"the row grays after this visit's befriend")
	_check(befriend_after.tooltip_text == I18n.t_key("hail.befriend.used"),
		"the grayed verb carries its hail.befriend.used term")

	_drop(screen)
	_make_run()


# --- 3. Inn limited talk (docs/80-* §4.11.1) ---------------------------------

func _test_inn_talk() -> void:
	_make_run()
	_check(InnEngineLib.TALK_FAMILIARITY == 1, "the talk bonus is +1")
	_check(InnEngineLib.can_talk("lisbon"), "the visit's talk is available")
	var before := CaptainsLib.familiarity(TRADER_ID)
	_check(InnEngineLib.talk(TRADER_ID, "lisbon"),
		"the limited talk applies for one sighted captain")
	_check(CaptainsLib.familiarity(TRADER_ID) == before + 1,
		"the talk adds +1 familiarity")
	_check(not InnEngineLib.can_talk("lisbon"),
		"the visit guard consumed the one talk")
	_check(not InnEngineLib.talk(TRADER2_ID, "lisbon"),
		"a second talk this visit is refused — even another captain")
	_check(CaptainsLib.familiarity(TRADER2_ID) == 0,
		"the refused talk changed nothing")
	# A new visit-day re-arms; the guard is per port too.
	GameState.day = 11
	_check(InnEngineLib.can_talk("lisbon"), "the next visit re-arms the talk")
	_check(InnEngineLib.can_talk("seville"),
		"another port's visit has its own guard")
	InnEngineLib.reset_visit_guards()
	_check(InnEngineLib.can_talk("lisbon"),
		"reset_visit_guards() re-arms the talk (suite seam)")


# --- 4. Inform on pirates (docs/70-* §4.5) + dossier entries (§4.11.3) -------

func _test_inform_and_dossier() -> void:
	_make_run()
	_check(PalaceEngineLib.INFORM_COST == 500,
		"the inform price is the fixed 500g")
	_check(PalaceEngineLib.inform_cost() == 500, "inform_cost() reads 500")

	var pirate := _at_sea_pirate()
	# The pipeline reuse: the payload is exactly the tavern reveal's.
	var expected: Dictionary = NpcIntelLib.reveal_position(str(pirate["id"]))
	_check(not expected.is_empty(),
		"the bounty-pinpoint pipeline answers the fixture")
	var before_gold := GameState.gold
	var payload: Dictionary = PalaceEngineLib.inform_on_pirates(
		"lisbon", str(pirate["id"]))
	_check(not payload.is_empty(), "the inform reveal runs")
	_check(int(payload.get("cell", Vector2i.ZERO).x) == int(expected["cell"].x)
		 and int(payload.get("cell", Vector2i.ZERO).y) == int(expected["cell"].y),
		"the payload is the same exact live position the tavern reveal gives")
	_check(GameState.gold == before_gold - 500,
		"the inform charges exactly 500g — no discounts (got %d)"
		% (before_gold - GameState.gold))

	# Refusals: a non-pirate target, an unknown id, a short purse.
	before_gold = GameState.gold
	var trader := _present_fleet("fx_if_tr", TRADER_ID, "trader")
	_check(PalaceEngineLib.inform_on_pirates("lisbon",
		str(trader.get("id", "x"))).is_empty(),
		"a non-pirate target is refused")
	_check(PalaceEngineLib.inform_on_pirates("lisbon", "no_such_fleet").is_empty(),
		"an unknown fleet id is refused")
	_check(GameState.gold == before_gold, "refused informs charge nothing")
	_make_run(499)
	_check(not PalaceEngineLib.can_inform("lisbon"),
		"499g cannot pay the fixed fee")
	_check(PalaceEngineLib.inform_on_pirates("lisbon",
		str(pirate["id"])).is_empty(), "the short purse is refused")
	# The §4.1b audience rule: a closed palace refuses.
	_make_run()
	GameState.world["clock_fraction"] = 0.95  # ~22:48 — palace closed
	_check(not PalaceEngineLib.can_inform("lisbon"),
		"the §4.1b closed rule refuses the inform")

	# The screen: bounty rows link dossiers (§4.11.3) and the inform row seam.
	# One mount covers the hunter's dossier, the inform row's dossier and the
	# row's fixed-500g inform — the fixtures stay live across all three.
	_make_run()
	var hunter := _present_fleet("fx_hu", HUNTER_ID, "hunter")
	var wanted := _at_sea_pirate()
	_check(not hunter.is_empty() and not wanted.is_empty(),
		"the bounty-board and inform fixtures exist")
	var palace = PalaceScene.instantiate()
	palace.route_to_port = false
	add_child(palace)
	await get_tree().process_frame
	_check(palace.inform_rows().size() == 1,
		"the inform section lists the at-sea wanted captain (%d)"
		% palace.inform_rows().size())
	_check(str(palace.inform_rows()[0].get("captain_id", "")) == PIRATE_ID,
		"the inform row carries the wanted captain's canon id")
	var hunters: Array = palace.hunter_rows()
	var hunter_row: Dictionary = {}
	for entry in hunters:
		if str((entry as Dictionary).get("captain_id", "")) == HUNTER_ID:
			hunter_row = entry
	_check(not hunter_row.is_empty(),
		"the bounty board row carries its captain id")
	_check(not CaptainsLib.dossier_seen(HUNTER_ID),
		"the dossier flag starts unseen")
	var board_box: Control = palace.get_node(
		"BountyBoardRows")
	var dossier: Button = board_box.get_node(
		"Hunter_%s/Dossier" % str(hunter_row.get("id", "")))
	dossier.pressed.emit()
	_check(CaptainsLib.dossier_seen(HUNTER_ID),
		"opening a bounty row's dossier marks it seen")
	_check(palace.dossiers_opened() == [HUNTER_ID],
		"the seam records the opened dossier id")
	# The revealed captain's row links to the same seam.
	var inform_box: Control = palace.get_node("InformRows")
	var inform_dossier: Button = inform_box.get_node(
		"Inform_%s/Dossier" % str(wanted["id"]))
	inform_dossier.pressed.emit()
	_check(CaptainsLib.dossier_seen(PIRATE_ID),
		"the inform row links to the dossier seam too")
	# And the fixed-500g inform through the real row.
	before_gold = GameState.gold
	var text: String = palace.inform_on(str(wanted["id"]))
	_check(not text.is_empty(), "the row's inform runs")
	_check(GameState.gold == before_gold - 500,
		"the row's inform charges the fixed 500g")
	_check(palace.last_inform_text == text, "the reveal text is recorded")
	_drop(palace)


# --- 5. Market captain-intel rows (docs/30-* §4.8) ---------------------------

func _test_market_intel() -> void:
	_make_run()
	var low := _present_fleet("fx_low", TRADER_ID, "trader")
	var high := _present_fleet("fx_high", TRADER2_ID, "trader")
	_check(not low.is_empty() and not high.is_empty(),
		"two present captain fixtures exist")
	CaptainsLib.adjust_stance(TRADER2_ID, STANCE_INTEL)

	var market = MarketScene.instantiate()
	market.route_to_port = false
	add_child(market)
	await get_tree().process_frame

	var rows: Array = market.intel_rows()
	_check(rows.size() == 2,
		"the intel section lists the port's captain sightings (%d)" % rows.size())
	var low_row: Dictionary = {}
	var high_row: Dictionary = {}
	for entry in rows:
		var row: Dictionary = entry
		if str(row.get("captain_id", "")) == TRADER_ID:
			low_row = row
		if str(row.get("captain_id", "")) == TRADER2_ID:
			high_row = row
	_check(not low_row.is_empty() and not high_row.is_empty(),
		"both captains are listed")
	_check(not bool(low_row.get("free", true)),
		"stance 0 carries no free-intel marker")
	_check(bool(high_row.get("free", false)),
		"stance ≥ +2 carries the free-intel marker")
	_check(int(high_row.get("stance", 0)) == STANCE_INTEL,
		"the row reports the stance")
	_check(str(high_row.get("dest_port_id", "")) == "seville",
		"the row carries the fleet's next-lane destination id")
	_check(str(high_row.get("dest_port_name", "")) == I18n.t(
			DataLoader.get_port("seville").get("name", {})),
		"the hint names the destination port (%s)"
		% str(high_row.get("dest_port_name", "")))
	# The boundary: stance +1 is NOT enough (the ≥ +2 pin).
	CaptainsLib.adjust_stance(TRADER_ID, 1)
	market.refresh()
	for entry in market.intel_rows():
		var row: Dictionary = entry
		if str(row.get("captain_id", "")) == TRADER_ID:
			_check(not bool(row.get("free", true)),
				"stance +1 still carries no free marker")
	# And the free row's rendered line names the destination.
	var intel_box: Control = market.get_node("IntelRows")
	var intel_row: Control = intel_box.get_node("Intel_%s" % TRADER2_ID)
	var line: Label = intel_row.get_node("Text")
	_check(str(line.text).contains(str(high_row.get("dest_port_name", ""))),
		"the free row renders the next-lane hint (%s)" % str(line.text))
	# The intel query itself is read-only (the §4.8 "the rows are read-only
	# intel" pin — scoped to this section's own refresh, which never touches
	# the sightings store's familiarity accrual).
	var stance_before := CaptainsLib.stance(TRADER2_ID)
	var fam_before := CaptainsLib.familiarity(TRADER2_ID)
	market._refresh_intel()
	_check(CaptainsLib.stance(TRADER2_ID) == stance_before
		and CaptainsLib.familiarity(TRADER2_ID) == fam_before,
		"the intel refresh changes no state")
	_drop(market)


# --- Harness -----------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	get_tree().quit(1)
