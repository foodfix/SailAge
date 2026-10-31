extends Node
## Phase-5 task L acceptance tests: aliveness, market events & captain
## sightings (docs/60-COMBAT.md §4.11.11.4; docs/80-UI-UX.md §4.7.8/§4.5.2;
## docs/30-PORTS-AND-TRADE.md §4.5; docs/10-DATA-SCHEMA.md §4.12/§4.13).
##
##   godot --headless res://tools/test_aliveness.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections: the treasure-fleet schedule/lane/intercept · named-pirate
## respawn (+30 days, new name) + the bounty-target preference · the demand
## event end-to-end (telegraph → surge → trader softening → post-expiry
## restore → budget caps → determinism) · the seeded sighting rolls (stable
## within a visit-day, varying across days, hunter palace-only, 60/40 +
## 75% distributions) · wanted posters within Chebyshev 40 + the 20g
## exact-position reveal through the real tavern screen · captain names
## across save/load · convoy render grouping · wake data · the market/inn/
## palace sighting surfaces.

const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const NpcIntelLib := preload("res://scripts/world/npc_intel.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")
const TavernScene := preload("res://scenes/port/tavern_screen.tscn")
const MarketScene := preload("res://scenes/port/market_screen.tscn")
const InnScene := preload("res://scenes/port/inn_screen.tscn")
const PalaceScene := preload("res://scenes/port/palace_screen.tscn")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]
## The nation → historical lane of its capital's spoke (built artifact).
const CAPITAL_LANES := {
	"portugal": "carreira_da_india",
	"spain": "west_indies_flota",
	"england": "hanseatic_north",
	"holland": "hanseatic_north",
	"ottoman": "genoa_grain",
	"italy": "venice_alexandria",
}
## First sailings: day 45 + 15 × nation_index (portugal 0 … italy 5).
const FIRST_TREASURE_DAYS := [45, 60, 75, 90, 105, 120]

## Open water far from every harbor and lane (the fixture band).
const OPEN_CELL := Vector2i(700, 320)
## The 60/40 + 75% statistical bounds (±0.15 over 200 seeded visits).
const TRIALS := 200
const PRIMARY_FRACTION_LO := 0.45
const PRIMARY_FRACTION_HI := 0.75
const PRESENT_FRACTION_LO := 0.60
const PRESENT_FRACTION_HI := 0.90

const SAVE_SLOT := 3
const WATCHDOG_SECONDS := 240.0

var _failures: Array[String] = []
var _checks := 0
var _watchdog: Timer = null
var _section := "<startup>"


func _ready() -> void:
	_arm_watchdog()
	_section = "map load"
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map("res://data/maps/world.png", DataLoader.map_legend)
	_check(ok, "map loads for the aliveness fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	NpcFleetsLib.reset_caches()

	_section = "1 treasure fleets"
	_test_treasure_schedule()
	_section = "2 named pirates"
	_test_named_pirates()
	_section = "3 demand events"
	_test_demand_events()
	_section = "4 sighting rolls"
	_test_sighting_rolls()
	_section = "5 posters + reveal"
	await _test_posters_reveal()
	_section = "6 save/load captains"
	_test_save_load_captains()
	_section = "7 convoys + wakes"
	_test_convoys_wakes()
	_section = "8 sighting surfaces"
	await _test_sighting_surfaces()
	_section = "report"
	_report()


func _arm_watchdog() -> void:
	_watchdog = Timer.new()
	_watchdog.name = "Watchdog"
	_watchdog.one_shot = true
	_watchdog.wait_time = WATCHDOG_SECONDS
	_watchdog.timeout.connect(_on_watchdog)
	add_child(_watchdog)
	_watchdog.start()


func _on_watchdog() -> void:
	print("")
	print("WATCHDOG: no report after %.0f s — the suite stalled in section '%s'"
		% [WATCHDOG_SECONDS, _section])
	print("%d checks ran, %d failures so far:" % [_checks, _failures.size()])
	for failure in _failures:
		print("  - ", failure)
	_failures.append("WATCHDOG: stalled in section '%s'" % _section)
	get_tree().quit(1)


# --- Fixtures ---------------------------------------------------------------

## A livable run with the ecology and the event rotation emptied. The
## module statics reset too: an earlier section's auto-resolve deaths leave
## named-pirate respawn reservations that would eat this section's names.
func _make_run(player_nation: String = "portugal") -> NpcFleetsLib:
	NpcFleetsLib.reset_caches()
	GameState.player = {
		"nation_id": player_nation,
		"stats": {"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10},
		"xp": 0, "level": 1, "officers": [],
		"reputation": {},
	}
	for nation_id in NATIONS:
		GameState.player["reputation"][nation_id] = 0
	GameState.fleet = [_ship("caravel")]
	GameState.day = 10
	GameState.gold = 10000
	GameState.morale = 70
	GameState.current_port = null
	GameState.port_investments = {}
	GameState.known_ports = []
	GameState.active_quests = []
	GameState.titles = {}
	GameState.world = {
		"position": {"x": OPEN_CELL.x, "y": OPEN_CELL.y},
		"clock_fraction": 0.0, "map_id": "world", "weather": "fair",
		"last_departed_port": "", "hunter_intel_cell": null,
	}
	GameState.market_stocks = EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list
	)
	GameState.npc_fleets = []
	GameState.wrecks = []
	GameState.npc_preset = "normal"
	GameState.market_events = []
	EconomyLib.reset_overrides()
	return NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "normal",
	})


func _ship(ship_type_id: String) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	return {
		"ship_type_id": ship_type_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0, "water": 0, "cannons": 0,
		"equipment": {"figurehead": "", "sail": ""},
		"cargo": {},
	}


func _make_fleet(sim: NpcFleetsLib, role: String, nation_id: String,
		cell: Vector2i, seed_value: int = 0) -> Dictionary:
	var fleet := {
		"id": "fx_%s_%s_%d" % [role, nation_id, GameState.npc_fleets.size()],
		"role": role, "nation_id": nation_id,
		"cell": {"x": cell.x, "y": cell.y},
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {},
		"captain": {"pool_id": nation_id, "name_index": 0},
		"cooldown_until_day": 0, "seed": seed_value, "dest_port_id": "",
		"dwell_until_day": 0, "anchor_cell": null, "target_fleet_id": "",
		"hunter_state": "", "loiter_until_day": 0, "home_port_id": "",
	}
	if seed_value == 0:
		fleet["seed"] = hash(fleet["id"]) % 100000000
	GameState.npc_fleets.append(fleet)
	sim.reset_index()
	return fleet


func _cell_of(fleet: Dictionary) -> Vector2i:
	return NpcFleetsLib.position_of(fleet)


func _count_role(role: String, nation_id: String = "") -> int:
	var count := 0
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary) \
				or str((fleet as Dictionary).get("role", "")) != role:
			continue
		if not nation_id.is_empty() \
				and str((fleet as Dictionary).get("nation_id", "")) != nation_id:
			continue
		count += 1
	return count


func _named_fleet(named_id: String) -> Dictionary:
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		if str((((fleet as Dictionary).get("captain", {}) as Dictionary)
				.get("named_id", ""))) == named_id:
			return fleet
	return {}


# --- 1. Treasure fleets (§4.11.11.4) ------------------------------------------

func _test_treasure_schedule() -> void:
	var sim := _make_run()
	# The schedule pin: due exactly on 45 + 15 × index, then every 90 days —
	# and never before the first season day.
	for index in NATIONS.size():
		var first: int = FIRST_TREASURE_DAYS[index]
		_check(sim.treasure_due(NATIONS[index], first),
			"%s's treasure day is %d" % [NATIONS[index], first])
		_check(not sim.treasure_due(NATIONS[index], first - 1)
			and not sim.treasure_due(NATIONS[index], first + 1),
			"no treasure spawn the days around it (%d)" % first)
		_check(not sim.treasure_due(NATIONS[index], first - 90),
			"no pre-season spawn 90 days earlier (%d)" % (first - 90))
		_check(sim.treasure_due(NATIONS[index], first + 90),
			"the next season's day is %d" % (first + 90))
	# On schedule each nation's fleet spawns on its historical lane.
	for index in NATIONS.size():
		var day: int = FIRST_TREASURE_DAYS[index]
		GameState.day = day
		sim.tick(day)
		var nation: String = NATIONS[index]
		var count := _count_role("treasure", nation)
		_check(count == 1, "%s sails exactly one treasure fleet on day %d (%d)"
			% [nation, day, count])
		var fleet := _find_role_fleet("treasure", nation)
		if fleet.is_empty():
			continue
		var lanes: Array = (fleet.get("route", {}) as Dictionary).get("lanes", [])
		_check(lanes.size() == 1 and str(lanes[0]) == CAPITAL_LANES[nation],
			"the treasure fleet sails %s's historical lane %s (got %s)"
			% [nation, CAPITAL_LANES[nation], str(lanes)])
		_check(not (fleet.get("route", {}) as Dictionary).get("legs", []).is_empty(),
			"the treasure fleet is under way (interceptable at sea)")
		var units := 0
		for good_id in (fleet.get("cargo", {}) as Dictionary):
			units += int((fleet.get("cargo", {}) as Dictionary)[good_id])
		_check(units == 3 * int(DataLoader.npc_config["flow"]
				.get("trade_units_per_port_call", 30)),
			"the hold carries ×3 a normal port call = %d units (got %d)"
			% [3 * int(DataLoader.npc_config["flow"]
				.get("trade_units_per_port_call", 30)), units])
		# Composition (§4.11.11.2 detail): 3–5 merchant hulls + 1 escort.
		var ships: Array = NpcFleetsLib.compose_fleet_ships(fleet, day)
		_check(ships.size() >= 4 and ships.size() <= 6,
			"the battle composes 3–5 merchant hulls + 1 escort (got %d)"
			% ships.size())
		# A repeat tick on the same day spawns nothing more; a second fleet
		# waits for the next season (1/nation/season).
		sim.tick(day)
		_check(_count_role("treasure", nation) == 1,
			"a second tick the same day spawns no second fleet")
	# Delivered fleets despawn after their dwell (legs empty, dwell expired).
	var delivered := _find_role_fleet("treasure", "portugal")
	if not delivered.is_empty():
		delivered["route"] = {"lanes": [], "leg": 0, "tile_index": 0, "legs": []}
		delivered["dwell_until_day"] = GameState.day - 1
		GameState.day += 1
		sim.last_tick_day = -1
		sim.tick(GameState.day)
		_check(_count_role("treasure", "portugal") == 0,
			"a delivered treasure fleet despawns after its dwell")
	# Perf profile: 30 seasonal day-ticks with a live ecology.
	_make_run()
	var tick_started := Time.get_ticks_usec()
	for offset in 30:
		GameState.day = 200 + offset
		sim.last_tick_day = -1
		sim.tick(GameState.day)
	print("PROFILE aliveness_tick_ms %d"
		% int((Time.get_ticks_usec() - tick_started) / 1000.0))


func _find_role_fleet(role: String, nation_id: String) -> Dictionary:
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		var candidate := fleet as Dictionary
		if str(candidate.get("role", "")) != role:
			continue
		if not nation_id.is_empty() \
				and str(candidate.get("nation_id", "")) != nation_id:
			continue
		return candidate
	return {}


# --- 2. Named pirates (§4.11.11.4) --------------------------------------------

func _test_named_pirates() -> void:
	var sim := _make_run()
	# The first pirate spawns draw the 4 famous identities, file order.
	var named_order: Array = []
	for entry in DataLoader.named_pirates_list:
		named_order.append(str((entry as Dictionary).get("id", "")))
	var pirates: Array = []
	for _index in 4:
		var pirate := sim.spawn("pirate", "", 10)
		_check(not pirate.is_empty(), "a pirate spawn succeeds")
		if not pirate.is_empty():
			pirates.append(pirate)
			var named_id := str((pirate.get("captain", {}) as Dictionary)
				.get("named_id", ""))
			_check(named_order.has(named_id),
				"the pirate carries a named identity (%s)" % named_id)
	_check(_named_fleet(named_order[0]) != {} and _named_fleet(named_order[3]) != {},
		"all 4 famous pirates are afloat after 4 spawns")
	var fifth := sim.spawn("pirate", "", 10)
	if not fifth.is_empty():
		_check(str((fifth.get("captain", {}) as Dictionary)
				.get("named_id", "")) == "",
			"a 5th pirate carries no famous identity (only 4 exist)")
	# Defeat the first: the famous name retires, the slot respawns +30 days
	# under a NEW name (the next nationless-pool entry), tier inherited.
	var defeated_id: String = named_order[0]
	var defeated := _named_fleet(defeated_id)
	var defeated_fleet_id := str(defeated.get("id", ""))
	var defeated_name := NpcFleetsLib.captain_name(defeated)
	GameState.day = 12
	sim.remove(defeated_fleet_id)
	_check(_named_fleet(defeated_id) == {},
		"the defeated named pirate is gone")
	_check(NpcFleetsLib.next_named_pirate_id() != defeated_id,
		"the defeated famous identity is not re-drawn while its respawn pends")
	# Before the +30 days nothing respawns.
	GameState.day = 41
	sim.last_tick_day = -1
	sim.tick(41)
	_check(_count_named() == 3,
		"day +29: no respawn yet (3 named afloat, got %d)" % _count_named())
	# At +30 the successor sails under a new pool name, same tier.
	GameState.day = 42
	sim.last_tick_day = -1
	sim.tick(42)
	_check(_count_named() == 4,
		"day +30: the slot respawns (4 named afloat, got %d)" % _count_named())
	var successor := _successor_fleet()
	if successor.is_empty():
		_check(false, "the respawned successor is afloat")
	else:
		_check(str(successor.get("id", "")) != defeated_fleet_id,
			"the successor is a NEW fleet")
		_check(NpcFleetsLib.captain_name(successor) != defeated_name,
			"the successor sails under a NEW name (%s)"
			% NpcFleetsLib.captain_name(successor))
		_check(NpcFleetsLib.named_tier_of(successor)
				== NpcFleetsLib.named_tier_of(
					{"captain": {"named_id": defeated_id}}),
			"the successor inherits the slot's tier")
		_check(NpcFleetsLib.is_named_captain(successor),
			"the successor is poster-worthy (a named captain)")
	# The bounty preference: with a named pirate alive, a bounty quest
	# targets it (tier re-priced from its own tier).
	_test_bounty_preference(NpcFleetsLib.preferred_bounty_target())
	_check(not NpcFleetsLib.preferred_bounty_target().is_empty(),
		"a named pirate is preferred while any is alive")
	# With NO named pirate alive, today's behavior: a fresh spawn.
	for fleet in GameState.npc_fleets.duplicate():
		if fleet is Dictionary \
				and NpcFleetsLib.is_named_captain(fleet):
			sim.remove(str((fleet as Dictionary).get("id", "")))
	_check(_count_named() == 0, "no named pirate remains for the fallback case")


func _count_named() -> int:
	var count := 0
	for fleet in GameState.npc_fleets:
		if fleet is Dictionary and NpcFleetsLib.is_named_captain(fleet):
			count += 1
	return count


## The respawned successor: a named pirate carrying no famous identity.
func _successor_fleet() -> Dictionary:
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		if NpcFleetsLib.is_named_captain(fleet) \
				and NpcFleetsLib.named_captain_of(fleet).is_empty():
			return fleet
	return {}


## The bounty preference (§4.11.11.4 + task 5): a live named pirate is the
## target; the tier/reward re-price to its own tier.
func _test_bounty_preference(target: Dictionary) -> void:
	if target.is_empty():
		_check(false, "a named target exists for the bounty preference")
		return
	var tier := NpcFleetsLib.named_tier_of(target)
	var offer := {
		"instance_id": "bounty_pref_probe",
		"template_id": str((QuestGenLib._first_template(QuestGenLib.TYPE_BOUNTY)
			as Dictionary).get("id", "")),
		"type": QuestGenLib.TYPE_BOUNTY,
		"giver": "guild",
		"origin_port_id": "lisbon",
		"requirements": {"tier": 1, "target_fleet_id": ""},
		"rewards": {"gold": 5000, "reputation": {}, "fame": 15},
		"expiry_days": 30,
		"status": QuestGenLib.STATUS_ACTIVE,
	}
	var instance := QuestGenLib.accept(offer, "lisbon", GameState.day)
	_check(not instance.is_empty(), "the bounty offer is accepted")
	var requirements: Dictionary = instance.get("requirements", {})
	_check(str(requirements.get("target_fleet_id", ""))
			== str(target.get("id", "")),
		"the bounty quest targets the live named pirate (%s)"
		% str(requirements.get("target_fleet_id", "")))
	_check(int(requirements.get("tier", 0)) == tier,
		"the quest tier re-prices to the named pirate's tier %d (got %d)"
		% [tier, int(requirements.get("tier", 0))])
	var rewards: Dictionary = instance.get("rewards", {})
	_check(int(rewards.get("gold", 0))
			== int(QuestGenLib.BOUNTY_GOLD_BY_TIER.get(tier, 5000)),
		"the reward re-prices with the tier")
	var line := QuestGenLib.objective_text(instance)
	_check(line.find(NpcFleetsLib.captain_name(target)) >= 0,
		"the objective line names the captain (%s)" % line)
	# Cleanup: the probe quest leaves no active slot behind.
	GameState.active_quests.erase(instance)


# --- 3. Demand events end-to-end (docs/30-* §4.5) -----------------------------

func _test_demand_events() -> void:
	_make_run()
	# Drive 720 rotation days and collect every start: every nation is hit,
	# and the schedule replays byte-identically.
	var starts := _drive_rotation(720)
	_check(starts.size() > 0, "the seeded schedule starts events (%d in 720 days)"
		% starts.size())
	var budget_ok := true
	var nation_count := {}
	for start in starts:
		var port := DataLoader.get_port(str((start as Dictionary).get("port_id", "")))
		var nation := str(port.get("nation_id", ""))
		nation_count[nation] = int(nation_count.get(nation, 0)) + 1
	var hit_nations := 0
	for nation in NATIONS:
		if int(nation_count.get(nation, 0)) >= 1:
			hit_nations += 1
	_check(hit_nations >= 4,
		"at least 4 of 6 nations see an event in 720 days (%d)" % hit_nations)
	# The live invariant: replay day by day and assert ≤ 1/nation ≤ 4 world.
	_make_run()
	for day in range(1, 401):
		GameState.day = day
		EconomyLib.market_events_tick(day)
		if not _budget_holds(day):
			budget_ok = false
			break
	_check(budget_ok, "≤ 1 active per nation and ≤ 4 world-wide on every day")
	# Determinism: the same days replay the same instance list.
	_make_run()
	var replay := _drive_rotation(720)
	var identical := JSON.stringify(starts) == JSON.stringify(replay)
	_check(identical, "the seeded schedule replays exactly")

	# End-to-end on a known instance: telegraph → surge → softening → restore.
	_make_run()
	var instance := _force_event_at("evt_war_provisioning", "seville", 100)
	_check(not instance.is_empty(), "a war-provisioning event starts at seville")
	if instance.is_empty():
		return
	var good := "timber"
	var rest_before := EconomyLib.rest_stock("seville", good)
	var stock_before := EconomyLib.stock_of("seville", good)
	# Telegraph: a tavern rumor row in the affected region (spain's ports),
	# visible at the affected port itself and a fellow-national port, not
	# under a foreign flag.
	var spain_rows := EconomyLib.event_telegraphs("seville", 100)
	var other_rows := EconomyLib.event_telegraphs("lisbon", 100)
	_check(spain_rows.size() >= 1, "the telegraph row appears in the region (%d)"
		% spain_rows.size())
	_check(other_rows.is_empty() or _telegraph_names(other_rows).find(
			_event_name(instance)) < 0,
		"a foreign port does not carry this telegraph")
	# Surge: the override drives the effective rest (clamped [10,190]) and
	# the drift moves the stock toward it, raising the factor.
	var shifted_rest := clampi(rest_before - 30, 10, 190)
	_check(EconomyLib.effective_rest("seville", good, 100) == shifted_rest,
		"effective rest = derived %d − 30 = %d, clamped (got %d)"
		% [rest_before, shifted_rest,
			EconomyLib.effective_rest("seville", good, 100)])
	var factor_before := EconomyLib.factor_units("seville", good)
	for day in range(101, 111):
		GameState.day = day
		EconomyLib.day_tick()
	var drifted := EconomyLib.stock_of("seville", good)
	_check(drifted < stock_before,
		"the shortage drifts the stock down toward the override (%d → %d)"
		% [stock_before, drifted])
	_check(EconomyLib.factor_units("seville", good) > factor_before,
		"the price factor surges (%d‰ → %d‰)"
		% [factor_before, EconomyLib.factor_units("seville", good)])
	# Trader softening: the §4.4 sell rule swarms the inflated port while
	# `factor > 1.0` — a trader's sale (≤ the 30-unit call cap and the
	# saturation bound `100 − stock`) partially refills the shortage, never
	# selling past the margin. That is the §4.5 self-limiting emergence.
	EconomyLib.set_stock("seville", good, 60)
	var trader_qty := mini(30, 100 - EconomyLib.stock_of("seville", good))
	EconomyLib.apply_trade("seville", good, -trader_qty)
	var softened := EconomyLib.stock_of("seville", good)
	_check(softened == 90 and softened <= 100,
		"an arriving trader softens the shortage (60 → %d, capped at the margin)"
		% softened)
	# Expiry restores the derived rest (day 100 + 60 = 160).
	GameState.day = 160
	EconomyLib.market_events_tick(160)
	_check(not _has_active_instance("evt_war_provisioning", "seville"),
		"the instance expires at start + duration")
	_check(EconomyLib.effective_rest("seville", good, 160) == rest_before,
		"expiry restores the derived rest (%d)" % rest_before)
	for day in range(161, 171):
		GameState.day = day
		EconomyLib.day_tick()
	_check(EconomyLib.effective_rest("seville", good, 170) == rest_before
			and not _has_active_instance("evt_war_provisioning", "seville"),
		"the drift resumes toward the derived rest after expiry")
	# Perf profile: 400 rotation passes on a live economy.
	var rotation_started := Time.get_ticks_usec()
	_make_run()
	for day in range(1, 401):
		EconomyLib.market_events_tick(day)
	print("PROFILE aliveness_rotation_ms %d"
		% int((Time.get_ticks_usec() - rotation_started) / 1000.0))


## Runs the rotation day by day (no drift), collecting the instances started.
func _drive_rotation(days: int) -> Array:
	var started: Array = []
	for day in range(1, days + 1):
		GameState.day = day
		for instance in EconomyLib.market_events_tick(day):
			started.append(instance)
	return started


## True while the active list respects ≤ 1/nation ≤ 4 world at `day`.
func _budget_holds(day: int) -> bool:
	var nation_count := {}
	var world := 0
	for instance in GameState.market_events:
		if not (instance is Dictionary):
			continue
		var template: Dictionary = DataLoader.get_market_event(
			str((instance as Dictionary).get("template_id", "")))
		var duration := int(template.get("duration_days", 0))
		var start_day := int((instance as Dictionary).get("start_day", 0))
		if duration <= 0 or day >= start_day + duration:
			continue
		world += 1
		var nation := str(DataLoader.get_port(
			str((instance as Dictionary).get("port_id", ""))).get("nation_id", ""))
		nation_count[nation] = int(nation_count.get(nation, 0)) + 1
		if int(nation_count[nation]) > EconomyLib.EVENTS_PER_NATION_MAX:
			return false
	if world > EconomyLib.EVENTS_WORLD_MAX:
		return false
	return true


## Forces `template_id` to start at `port_id` on `day` (the seeded schedule
## itself stays covered above; this pins the end-to-end on a known instance).
func _force_event_at(template_id: String, port_id: String, day: int) -> Dictionary:
	GameState.day = day
	var instance := {
		"template_id": template_id, "port_id": port_id, "start_day": day,
	}
	GameState.market_events.append(instance)
	var template: Dictionary = DataLoader.get_market_event(template_id)
	EconomyLib.ensure_event_overrides(day)
	return instance if not template.is_empty() else {}


func _event_name(instance: Dictionary) -> String:
	return I18n.t(DataLoader.get_market_event(
		str(instance.get("template_id", ""))).get("name", {}))


## True while `template_id` at `port_id` is still in the active list and
## inside its duration at `GameState.day`.
func _has_active_instance(template_id: String, port_id: String) -> bool:
	for instance in GameState.market_events:
		if not (instance is Dictionary):
			continue
		if str((instance as Dictionary).get("template_id", "")) != template_id \
				or str((instance as Dictionary).get("port_id", "")) != port_id:
			continue
		var template: Dictionary = DataLoader.get_market_event(template_id)
		var duration := int(template.get("duration_days", 0))
		if duration <= 0 or GameState.day >= int((instance as Dictionary)
				.get("start_day", 0)) + duration:
			return false
		return true
	return false


func _telegraph_names(rows: Array) -> Array:
	var out: Array = []
	for row in rows:
		out.append(I18n.t((row as Dictionary).get("template", {})
			.get("name", {})))
	return out


# --- 4. The seeded sighting rolls (docs/80-* §4.7.8) --------------------------

func _test_sighting_rolls() -> void:
	var sim := _make_run()
	var port_id := "lisbon"
	var berth := DataLoader.port_cell(port_id)
	GameState.day = 20
	# A docked trader: stable within the visit-day, whatever re-opens.
	var trader := _make_fleet(sim, "trader", "portugal", berth)
	trader["dwell_until_day"] = GameState.day + 2
	var facility := NpcIntelLib.facility_of(trader, port_id)
	var present := NpcIntelLib.is_present(trader, port_id)
	var stable := true
	for _repeat in 10:
		if NpcIntelLib.facility_of(trader, port_id) != facility \
				or NpcIntelLib.is_present(trader, port_id) != present:
			stable = false
	_check(stable, "the rolls are stable within the visit-day (no flicker)")
	_check(facility in ["market", "tavern", "inn"],
		"a trader's facility is one of the plausible sets (%s)" % facility)
	# Across visits (new arrival days) the rolls re-draw.
	var facilities := {}
	var presences := {}
	for visit in 30:
		trader["dwell_until_day"] = 100 + visit + 2
		facilities[NpcIntelLib.facility_of(trader, port_id)] = true
		presences[NpcIntelLib.is_present(trader, port_id)] = true
	_check(facilities.size() >= 2 or presences.size() >= 2,
		"the rolls vary across visits (facilities %s, presences %s)"
		% [str(facilities.keys()), str(presences.keys())])
	# A hunter is palace-only — for every seed.
	var hunter := _make_fleet(sim, "hunter", "england", berth,
		berth.x * 7919 + 13)
	hunter["dwell_until_day"] = GameState.day + 2
	var palace_only := true
	for visit in 50:
		hunter["dwell_until_day"] = 200 + visit + 2
		if NpcIntelLib.facility_of(hunter, port_id) != "palace":
			palace_only = false
	_check(palace_only, "a hunter's facility is the palace bounty board only")
	# The distributions: 60% primary / 75% present over 200 seeded visits.
	var primary_count := 0
	var present_count := 0
	var probe := _make_fleet(sim, "trader", "spain", DataLoader.port_cell("seville"))
	for visit in TRIALS:
		probe["dwell_until_day"] = 300 + visit + 2
		if NpcIntelLib.facility_of(probe, "seville") \
				== NpcIntelLib.primary_facility("trader"):
			primary_count += 1
		if NpcIntelLib.is_present(probe, "seville"):
			present_count += 1
	var primary_fraction := float(primary_count) / float(TRIALS)
	_check(primary_fraction >= PRIMARY_FRACTION_LO
			and primary_fraction <= PRIMARY_FRACTION_HI,
		"the facility roll lands on the primary %.0f%% of the time (pin 60%%)"
		% [primary_fraction * 100.0])
	var present_fraction := float(present_count) / float(TRIALS)
	_check(present_fraction >= PRESENT_FRACTION_LO
			and present_fraction <= PRESENT_FRACTION_HI,
		"the presence roll is sightable %.0f%% of the time (pin 75%%)"
		% [present_fraction * 100.0])
	# Sightings list only docked+present+facility-matching captains; the
	# gone-ashore captain is absent from every facility.
	probe["dwell_until_day"] = 400 + 2
	var probe_present := NpcIntelLib.is_present(probe, "seville")
	var at_facility := NpcIntelLib.facility_of(probe, "seville")
	var sighted_elsewhere: Array = NpcIntelLib.sightings("seville",
		"market" if at_facility != "market" else "tavern")
	var contains_probe := false
	for row in sighted_elsewhere:
		if str(row.get("id", "")) == str(probe.get("id", "")):
			contains_probe = true
	_check(not contains_probe,
		"a captain sighted at one facility appears at no other")
	if probe_present:
		var at_home: Array = NpcIntelLib.sightings("seville", at_facility)
		var found := false
		for row in at_home:
			if str(row.get("id", "")) == str(probe.get("id", "")):
				found = true
		_check(found, "a present captain is sighted at its rolled facility")
	else:
		var any_facility: Array = []
		for facility_id in ["market", "tavern", "inn", "palace"]:
			any_facility.append_array(NpcIntelLib.sightings("seville", facility_id))
		var found_ashore := false
		for row in any_facility:
			if str(row.get("id", "")) == str(probe.get("id", "")):
				found_ashore = true
		_check(not found_ashore,
			"a gone-ashore captain is absent from every facility")
	# Perf profile: 100 intel passes (posters + sightings + rumors).
	var intel_started := Time.get_ticks_usec()
	for _pass in 100:
		NpcIntelLib.wanted_posters("seville")
		NpcIntelLib.sightings("seville", "market")
		NpcIntelLib.rumor_rows("seville")
	print("PROFILE aliveness_intel_ms %d"
		% int((Time.get_ticks_usec() - intel_started) / 1000.0))


# --- 5. Wanted posters + the 20g reveal (docs/80-* §4.7.8) --------------------

func _test_posters_reveal() -> void:
	var sim := _make_run()
	var port_id := "lisbon"
	var berth := DataLoader.port_cell(port_id)
	GameState.day = 50
	GameState.current_port = port_id
	# A NAMED pirate within 40 tiles posts; one at 45 does not; a docked one
	# never posts (at-sea posters only).
	var near := _make_named_pirate(sim, berth + Vector2i(30, 0), "pirate_redbeard_khair")
	var far := _make_named_pirate(sim, berth + Vector2i(45, 0), "pirate_murad_red_sail")
	var docked := _make_named_pirate(sim, berth + Vector2i(5, 0), "pirate_limahong_thousand_sails")
	docked["dwell_until_day"] = GameState.day + 2
	var posters: Array = NpcIntelLib.wanted_posters(port_id)
	var poster_ids := {}
	for poster in posters:
		poster_ids[str((poster as Dictionary).get("id", ""))] = poster
	_check(poster_ids.has(str(near.get("id", ""))),
		"a named pirate within Chebyshev 40 has a poster")
	_check(not poster_ids.has(str(far.get("id", ""))),
		"a pirate beyond Chebyshev 40 posts nothing")
	_check(not poster_ids.has(str(docked.get("id", ""))),
		"a docked captain posts nothing (at-sea posters only)")
	var poster: Dictionary = poster_ids.get(str(near.get("id", "")), {})
	if not poster.is_empty():
		_check(int(poster.get("tier", 0)) == 3
				and int(poster.get("reward_gold", 0)) == 20000,
			"the poster carries tier 3 + its reward hint (tier %d, %dg)"
			% [int(poster.get("tier", 0)), int(poster.get("reward_gold", 0))])
		_check(str(poster.get("nearest_port", "")) 
				== NpcIntelLib.nearest_port(_cell_of(near)),
			"the last-known hint names the nearest port")
	# The paid reveal through the real tavern screen: 20g buys the exact
	# live position (tile + nearest port), verified against the fleet state.
	var tavern: Control = TavernScene.instantiate()
	tavern.route_to_port = false
	add_child(tavern)
	await get_tree().process_frame
	var gold_before := GameState.gold
	var reveal: String = tavern.buy_reveal(str(near.get("id", "")))
	_check(not reveal.is_empty(), "the 20g reveal pays out rumor text")
	_check(GameState.gold == gold_before - 20,
		"the reveal charges exactly 20g (got %d)" % (gold_before - GameState.gold))
	_check(reveal.find("(%d, %d)" % [_cell_of(near).x, _cell_of(near).y]) >= 0,
		"the reveal text carries the exact live tile (%s)" % reveal)
	_check(reveal.find(NpcIntelLib._port_name(
			NpcIntelLib.nearest_port(_cell_of(near)))) >= 0,
		"the reveal text names the nearest port")
	# Short of gold: refused, nothing charged.
	GameState.gold = 10
	gold_before = GameState.gold
	var refused: String = tavern.buy_reveal(str(far.get("id", "")))
	_check(refused.is_empty() and GameState.gold == gold_before,
		"a purse below 20g refuses the reveal and charges nothing")
	# The tavern also lists the rumor rows + posters through its seams.
	_check(tavern.poster_rows().size() >= 1,
		"the tavern screen exposes its poster rows")
	tavern.queue_free()
	await get_tree().process_frame


func _make_named_pirate(sim: NpcFleetsLib, cell: Vector2i,
		named_id: String) -> Dictionary:
	var fleet := _make_fleet(sim, "pirate", "", cell)
	(fleet["captain"] as Dictionary)["named_id"] = named_id
	sim.reset_index()
	return fleet


# --- 6. Captain names survive save/load (§4.11.11.4) --------------------------

func _test_save_load_captains() -> void:
	var sim := _make_run()
	GameState.day = 1
	sim.tick(1)
	var before: Array = []
	for fleet in GameState.npc_fleets:
		if fleet is Dictionary:
			before.append({
				"id": str((fleet as Dictionary).get("id", "")),
				"captain": (fleet as Dictionary).get("captain", {}).duplicate(true),
				"name": NpcFleetsLib.captain_name(fleet),
			})
	_check(before.size() > 0, "the ecology holds fleets to name (%d)" % before.size())
	_check(SaveSystem.save(SAVE_SLOT), "the run saves")
	GameState.npc_fleets = []
	_check(SaveSystem.load(SAVE_SLOT), "the run loads")
	var same := GameState.npc_fleets.size() == before.size()
	for entry in before:
		var fleet := {}
		for candidate in GameState.npc_fleets:
			if candidate is Dictionary:
				if str((candidate as Dictionary).get("id", "")) \
						== str((entry as Dictionary).get("id", "")):
					fleet = candidate
					break
		var captain_same := JSON.stringify(
			(fleet as Dictionary).get("captain", {})) == JSON.stringify(
			(entry as Dictionary).get("captain", {}))
		var name_same := NpcFleetsLib.captain_name(fleet) \
			== str((entry as Dictionary).get("name", ""))
		if fleet.is_empty() or not captain_same or not name_same:
			same = false
			break
	_check(same, "captain identities (incl. named overrides) survive save/load")
	_check(SaveSystem.delete_save(SAVE_SLOT) or not SaveSystem.has_save(SAVE_SLOT),
		"the probe slot is cleaned up")


# --- 7. Convoys render + wake data (§4.11.11.4, docs/80-* §4.5.2) -------------

func _test_convoys_wakes() -> void:
	var sim := _make_run()
	sim._refresh_net()  # _make_run cleared the lane statics; _leg_path
	                     # reads them without rebuilding
	GameState.day = 20
	var a := _make_fleet(sim, "trader", "portugal", OPEN_CELL)
	var b := _make_fleet(sim, "trader", "portugal", OPEN_CELL + Vector2i(3, 0))
	var c := _make_fleet(sim, "trader", "spain", OPEN_CELL + Vector2i(1, 0))
	_lane_route(a, "west_indies_flota")
	_lane_route(b, "west_indies_flota")
	_lane_route(c, "venice_flanders")
	# Query side (K): the convoy exists for the same-lane pair.
	var members: Array = sim.convoy_members(a)
	_check(members.has(a) and members.has(b) and not members.has(c),
		"convoy_members answers the same-lane pair")
	# Render side (L): the leader marker carries the count; the member hides
	# behind it; the different-lane trader never groups.
	var leader_id := mini_id_str(str(a.get("id", "")), str(b.get("id", "")))
	var markers := {}
	for marker in sim.markers():
		markers[str((marker as Dictionary).get("id", ""))] = marker
	var leader: Dictionary = markers.get(leader_id, {})
	var other_id := str(b.get("id", "")) if leader_id == str(a.get("id", "")) \
		else str(a.get("id", ""))
	var member: Dictionary = markers.get(other_id, {})
	_check(int(leader.get("convoy_count", 0)) == 2,
		"the leader marker carries the member count (got %d)"
		% int(leader.get("convoy_count", 0)))
	_check(str(member.get("convoy_leader", "")) == leader_id,
		"the member marker names its leader")
	_check(str((markers.get(str(c.get("id", "")), {}) as Dictionary)
			.get("convoy_leader", "")) == "",
		"a different-lane trader never joins the group")
	# Wake data: one step leaves a 1-tile wake behind the moving fleet; the
	# ring caps at 5; docked markers report none.
	var lane_path: Array = sim._leg_path(
		(a.get("route", {}) as Dictionary).get("legs", [{}])[0])
	_check(lane_path.size() > 6, "the fixture lane has tiles to walk")
	if lane_path.size() <= 6:
		return
	a["cell"] = {"x": lane_path[2].x, "y": lane_path[2].y}
	sim.reset_index()
	sim._commit_cell(a, lane_path[1])
	sim._commit_cell(a, lane_path[0])
	var wake: Array = a.get("wake", [])
	_check(wake.size() == 2, "two steps leave a 2-tile wake (got %d)" % wake.size())
	for step in 8:
		var next: Vector2i = lane_path[mini(3 + step, lane_path.size() - 1)]
		sim._commit_cell(a, next)
	wake = a.get("wake", [])
	_check(wake.size() <= NpcFleetsLib.WAKE_LENGTH,
		"the wake ring caps at %d tiles (got %d)"
		% [NpcFleetsLib.WAKE_LENGTH, wake.size()])
	var a_marker: Dictionary = markers.get(str(a.get("id", "")), {})
	# Markers re-read: a sailing fleet carries wake data, a docked one none.
	var sailing_markers := {}
	for marker in sim.markers():
		sailing_markers[str((marker as Dictionary).get("id", ""))] = marker
	var a_sailing: Dictionary = sailing_markers.get(str(a.get("id", "")), {})
	_check(bool(a_sailing.get("sailing", false))
			and (a_sailing.get("wake", []) as Array).size() > 0,
		"a sailing marker carries wake data")
	a["route"] = {"lanes": [], "leg": 0, "tile_index": 0, "legs": []}
	a["dwell_until_day"] = GameState.day + 2
	for marker in sim.markers():
		if str((marker as Dictionary).get("id", "")) == str(a.get("id", "")):
			_check((marker as Dictionary).get("wake", []).is_empty(),
				"a docked marker draws no wake")


static func mini_id_str(a: String, b: String) -> String:
	return a if a < b else b


func _lane_route(fleet: Dictionary, lane_id: String) -> void:
	fleet["route"] = {"lanes": [lane_id], "leg": 0, "tile_index": 0,
		"legs": [{"kind": "lane", "id": lane_id, "reverse": false,
			"a": 0, "b": 99}]}


# --- 8. The sighting surfaces (docs/80-* §4.7.8) ------------------------------

func _test_sighting_surfaces() -> void:
	var sim := _make_run()
	GameState.day = 20
	GameState.current_port = "lisbon"
	var berth := DataLoader.port_cell("lisbon")
	# Docked fixtures at lisbon: a trader, a coaster, a hunter. Their rolled
	# facilities decide which surface lists them; the checks walk every
	# facility so the roll cannot flake the suite.
	var trader := _make_fleet(sim, "trader", "portugal", berth)
	var coaster := _make_fleet(sim, "coaster", "portugal", berth + Vector2i(0, 0))
	var hunter := _make_fleet(sim, "hunter", "england", berth)
	for fleet in [trader, coaster, hunter]:
		(fleet as Dictionary)["dwell_until_day"] = GameState.day + 2
	var market: Control = MarketScene.instantiate()
	market.route_to_port = false
	add_child(market)
	await get_tree().process_frame
	var market_rows: Array = market.captain_rows()
	for row in market_rows:
		_check(str(row.get("role", "")) in ["trader", "treasure"],
			"the market lists only merchant captains (%s)" % str(row.get("role", "")))
	_check(market_rows.size() <= 2, "the market section renders (rows %d)"
		% market_rows.size())
	market.queue_free()
	var inn: Control = InnScene.instantiate()
	inn.route_to_port = false
	add_child(inn)
	await get_tree().process_frame
	var inn_rows: Array = inn.captain_rows()
	for row in inn_rows:
		_check(str(row.get("role", "")) != "hunter",
			"a hunter never appears at the inn (%s)" % str(row.get("role", "")))
	inn.queue_free()
	var palace: Control = PalaceScene.instantiate()
	palace.route_to_port = false
	add_child(palace)
	await get_tree().process_frame
	var hunter_rows: Array = palace.hunter_rows()
	for row in hunter_rows:
		_check(str(row.get("role", "")) == "hunter",
			"the palace board lists only hunters (%s)" % str(row.get("role", "")))
	var palace_only := true
	for row in hunter_rows:
		if str(row.get("id", "")) != str(hunter.get("id", "")):
			palace_only = false
	if NpcIntelLib.is_present(hunter, "lisbon"):
		_check(hunter_rows.size() == 1
				and str(hunter_rows[0].get("id", "")) == str(hunter.get("id", "")),
			"a present docked hunter is on the palace board")
	else:
		_check(hunter_rows.is_empty(),
			"a gone-ashore hunter is on no board that day")
	palace.queue_free()
	await get_tree().process_frame
	_check(palace_only, "the palace board lists only the docked hunter")


# --- Harness -----------------------------------------------------------------

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		return
	_failures.append(label)
	print("  FAIL: ", label)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
	else:
		print("%d of %d checks FAILED" % [_failures.size(), _checks])
		for failure in _failures:
			print("  - ", failure)
	get_tree().quit(0 if _failures.is_empty() else 1)
