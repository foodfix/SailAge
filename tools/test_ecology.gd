extends Node
## Phase-5 task K acceptance tests: ecology & combat integration
## (docs/60-COMBAT.md §4.1.1, §4.11.11–§4.11.11.5, §4.12.3–§4.12.4;
## docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.5; docs/80-UI-UX.md §4.5.2;
## docs/10-DATA-SCHEMA.md §4.15).
##
##   godot --headless res://tools/test_ecology.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections: seeded 60% auto-resolve · the deterministic escort/patrol/convoy
## rows · wreck lifecycle (spawn, contents, 5-day expiry, cap exemption) ·
## privateer rival-only targeting · chokepoint anchoring + the 5/8 hysteresis
## · seeded depletion runs (unescorted drained, escorted lanes healthy) ·
## collect-on-entry capacity rules · the player combat surface through the
## real world scene (loot row, piracy funnel, privateer sponsor-rival bonus,
## wreck markers, chained battles).

const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const BattleRewardsLib := preload("res://scripts/combat/battle_rewards.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

## Open water in the world map's variables band, far from every harbor and
## off every lane/spoke tile (the camp fixtures live here).
const OPEN_CELL := Vector2i(700, 320)

## The 60% statistical bound: 200 seeded trials, ±0.12 around the pin
## (±3.5 σ — a deterministic stream never approaches it).
const TRIALS := 200
const WIN_FRACTION_LO := 0.48
const WIN_FRACTION_HI := 0.72

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
	_check(ok, "map loads for the ecology fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	NpcFleetsLib.reset_caches()

	_section = "1 seeded 60% auto-resolve"
	_test_seeded_resolve()
	_section = "2 escort / patrol / convoy rows"
	_test_escort_rows()
	_section = "3 wreck lifecycle"
	_test_wreck_lifecycle()
	_section = "4 privateer rival-only targeting"
	_test_privateer_targeting()
	_section = "5 chokepoint anchoring + 5/8 hysteresis"
	_test_chokepoint_hysteresis()
	_section = "6 seeded depletion runs"
	_test_depletion_runs()
	_section = "7 collect-on-entry"
	_test_collect_capacity()
	_section = "8 world-scene combat surface"
	await _test_world_scene_surface()
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

## A livable run with the ecology emptied; every section seeds its own fleets.
func _make_run(player_nation: String = "portugal") -> NpcFleetsLib:
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


## A stationary fleet (docked semantics: it holds its tile, never blocks,
## never moves — the prey the camp fixtures bait).
func _stationary(fleet: Dictionary, day: int, days: int = 60) -> Dictionary:
	fleet["dwell_until_day"] = day + days
	return fleet


func _cell_of(fleet: Dictionary) -> Vector2i:
	return NpcFleetsLib.position_of(fleet)


# --- 1. Seeded 60% (docs/60-* §4.11.11.2) ------------------------------------

func _test_seeded_resolve() -> void:
	var sim := _make_run()
	var day := 20
	var wins := 0
	for index in TRIALS:
		var raider := _make_fleet(sim, "pirate", "",
			OPEN_CELL + Vector2i(50 + index, 0), 9000 + index * 7919)
		var trader := _make_fleet(sim, "trader", "portugal",
			OPEN_CELL + Vector2i(50 + index, 1), 1)
		if sim.resolve_engagement(raider, trader, day):
			wins += 1
	var fraction := float(wins) / float(TRIALS)
	_check(fraction >= WIN_FRACTION_LO and fraction <= WIN_FRACTION_HI,
		"raider wins %.1f%% of %d unescorted engagements (pin 60%%)"
		% [fraction * 100.0, TRIALS])
	# Determinism: the same (seed, prey, day) triple resolves identically.
	var raider := _make_fleet(sim, "pirate", "", OPEN_CELL + Vector2i(3, 0), 424242)
	var trader := _make_fleet(sim, "trader", "portugal", OPEN_CELL + Vector2i(3, 1))
	var first := sim.resolve_engagement(raider, trader, day)
	var same := true
	for _repeat in 10:
		if sim.resolve_engagement(raider, trader, day) != first:
			same = false
	_check(same, "the seeded roll is reproducible from the saved fields")
	# Same-role/navy pairings never auto-resolve at all: the prey query only
	# offers trader/patrol (§4.1.1), so a pirate beside a privateer, a hunter
	# or another pirate raises no engagement.
	GameState.npc_fleets = []
	sim.reset_index()
	var pirate := _make_fleet(sim, "pirate", "", OPEN_CELL + Vector2i(1, 0))
	_make_fleet(sim, "pirate", "", OPEN_CELL + Vector2i(2, 0))
	_make_fleet(sim, "privateer", "spain", OPEN_CELL + Vector2i(1, 1))
	_make_fleet(sim, "hunter", "england", OPEN_CELL + Vector2i(0, 1))
	_make_fleet(sim, "coaster", "portugal", OPEN_CELL + Vector2i(1, 2))
	var prey: Array = sim.prey_candidates(pirate)
	_check(prey.is_empty(),
		"a raider never preys on raiders, hunters or coasters (got %d)"
		% prey.size())


# --- 2. The deterministic rows (§4.11.11.2 / §4.11.11.4) ---------------------

func _test_escort_rows() -> void:
	var sim := _make_run()
	var day := 20
	var raider := _make_fleet(sim, "pirate", "", OPEN_CELL)
	# Raider vs patrol: the raider loses, every seed.
	var patrol := _make_fleet(sim, "patrol", "portugal", OPEN_CELL + Vector2i(1, 0))
	var all_lost := true
	for index in 25:
		raider["seed"] = 500 + index * 104729
		if sim.resolve_engagement(raider, patrol, day):
			all_lost = false
	_check(all_lost, "raider vs patrol always loses (25 seeds)")
	# The escort is same-nation: a foreign patrol does not escort. Only the
	# pair under test stays on the board (the patrol sub-case's fleet sat on
	# the trader's own tile).
	GameState.npc_fleets = [raider, patrol]
	sim.reset_index()
	var trader := _make_fleet(sim, "trader", "portugal", OPEN_CELL + Vector2i(1, 0))
	var escort := _make_fleet(sim, "patrol", "portugal", OPEN_CELL + Vector2i(5, 5))
	GameState.npc_fleets = [raider, trader, escort]
	sim.reset_index()
	_check(sim.is_escorted(trader),
		"a same-nation patrol within Chebyshev 10 escorts (%d away)"
		% NpcFleetsLib.chebyshev(_cell_of(trader), _cell_of(escort)))
	all_lost = true
	for index in 25:
		raider["seed"] = 500 + index * 104729
		if sim.resolve_engagement(raider, trader, day):
			all_lost = false
	_check(all_lost, "raider vs escorted trader always loses (25 seeds)")
	# The escort is same-nation: a foreign patrol does not escort.
	escort["nation_id"] = "ottoman"
	_check(not sim.is_escorted(trader),
		"a foreign patrol within 10 is no escort")
	escort["nation_id"] = "portugal"
	escort["cell"] = {"x": OPEN_CELL.x + 12, "y": OPEN_CELL.y}
	sim.reset_index()
	_check(not sim.is_escorted(trader),
		"a patrol beyond Chebyshev 10 is no escort")
	# Convoy (§4.11.11.4): same-lane traders within Chebyshev 3 count
	# escorted — the query task L's render grouping reuses.
	escort["cell"] = {"x": OPEN_CELL.x - 20, "y": OPEN_CELL.y}
	sim.reset_index()
	var lane_trader := _make_fleet(sim, "trader", "spain", OPEN_CELL + Vector2i(3, 0))
	_lane_route(trader)
	_lane_route(lane_trader)
	var members: Array = sim.convoy_members(trader)
	_check(members.size() == 2 and members.has(trader) and members.has(lane_trader),
		"same-lane traders within Chebyshev 3 form a convoy (2 members)")
	_check(sim.is_convoyed(trader) and sim.is_convoyed(lane_trader),
		"auto-resolve treats a convoy as escorted")
	all_lost = true
	for index in 25:
		raider["seed"] = 500 + index * 104729
		if sim.resolve_engagement(raider, trader, day):
			all_lost = false
	_check(all_lost, "raider vs a convoy trader always loses (25 seeds)")
	# Not a convoy: different lanes, or same lane beyond 3.
	_lane_route(lane_trader, "venice_flanders")
	_check(not sim.is_convoyed(trader), "traders on different lanes are no convoy")
	_lane_route(lane_trader, "west_indies_flota")
	lane_trader["cell"] = {"x": OPEN_CELL.x + 5, "y": OPEN_CELL.y}
	sim.reset_index()
	_check(not sim.is_convoyed(trader),
		"same-lane traders beyond Chebyshev 3 are no convoy")


func _lane_route(fleet: Dictionary, lane_id: String = "west_indies_flota") -> void:
	fleet["route"] = {"lanes": [lane_id], "leg": 0, "tile_index": 0, "legs": []}


# --- 3. Wreck lifecycle (§4.11.11.2, §4.11.11; 10-* §4.15) -------------------

func _test_wreck_lifecycle() -> void:
	var sim := _make_run()
	var day := 20
	# A trader loss: the wreck carries the trader's ACTUAL cargo.
	var raider := _make_fleet(sim, "pirate", "", OPEN_CELL, 777)
	var trader := _make_fleet(sim, "trader", "portugal",
		OPEN_CELL + Vector2i(1, 0))
	trader["cargo"] = {"wool": 14, "wine": 8}
	var doomed: Dictionary = {}
	var remove_ids: Array = []
	var wrecks: Array = []
	sim._engage(raider, trader, day, doomed, remove_ids, wrecks)
	_check(wrecks.size() == 1 and remove_ids.has(str(trader["id"])),
		"the engagement queues exactly the loser's removal")
	if wrecks.is_empty():
		return
	var wreck: Dictionary = wrecks[0]
	_check(str(wreck.get("id", "")).begins_with("wk_"),
		"the wreck id follows the wk_<day>_<x>_<y> family (%s)"
		% str(wreck.get("id", "")))
	_check(_wreck_cell(wreck) == _cell_of(trader),
		"the wreck sits at the loser's site")
	_check((wreck.get("cargo", {}) as Dictionary).get("wool", 0) == 14
		and (wreck.get("cargo", {}) as Dictionary).get("wine", 0) == 8,
		"a trader wreck carries the actual cargo")
	_check(int(wreck.get("salvage_gold", -1)) == 0,
		"a trader wreck pays no salvage gold")
	_check(int(wreck.get("spawn_day", -1)) == day, "spawn_day is the loss day")
	# The raider's prey target clears after the kill.
	_check(str(raider.get("target_fleet_id", "x")) == "",
		"the raider re-camps after taking its prey")
	# A warship loss: salvage_gold = BattleRewards.salvage_for(composed hulls)
	# — the single salvage implementation, no parallel formula.
	var patrol := _make_fleet(sim, "patrol", "portugal",
		OPEN_CELL + Vector2i(2, 0), 31337)
	var patrol_raider := _make_fleet(sim, "pirate", "",
		OPEN_CELL + Vector2i(2, 1), 777)
	doomed = {}
	remove_ids = []
	wrecks = []
	sim._engage(patrol_raider, patrol, day, doomed, remove_ids, wrecks)
	_check(remove_ids.has(str(patrol_raider["id"]))
		and not remove_ids.has(str(patrol["id"])),
		"the patrol wins its engagement (raider vs patrol ⇒ raider loses)")
	if wrecks.is_empty():
		return
	var war_wreck: Dictionary = wrecks[0]
	var hull_ids: Array = []
	for ship in sim.compose_fleet_ships(patrol_raider, day):
		hull_ids.append(str((ship as Dictionary).get("ship_type_id", "")))
	_check(int(war_wreck.get("salvage_gold", -1))
		== BattleRewardsLib.salvage_for(hull_ids),
		"a warship wreck pays salvage_for(its composed hulls) (%d)"
		% int(war_wreck.get("salvage_gold", -1)))
	_check((war_wreck.get("cargo", {}) as Dictionary).is_empty(),
		"a warship wreck carries no cargo")
	# A pirate wreck is a warship wreck (its composed hulls).
	var pirate_loser := _make_fleet(sim, "pirate", "", OPEN_CELL + Vector2i(4, 0), 999)
	var patrol2 := _make_fleet(sim, "patrol", "spain", OPEN_CELL + Vector2i(4, 1))
	doomed = {}
	wrecks = []
	sim._engage(pirate_loser, patrol2, day, doomed, [], wrecks)
	if not wrecks.is_empty():
		var pirate_hulls: Array = []
		for ship in sim.compose_fleet_ships(pirate_loser, day):
			pirate_hulls.append(str((ship as Dictionary).get("ship_type_id", "")))
		_check(int((wrecks[0].get("salvage_gold", -1)))
			== BattleRewardsLib.salvage_for(pirate_hulls),
			"a pirate wreck is a warship wreck (composed hulls)")
	else:
		_check(false, "the pirate-vs-patrol engagement produced a wreck")
	# Wrecks never count against the fleet cap.
	var fleets_before := GameState.npc_fleets.size()
	GameState.wrecks.append(wreck.duplicate(true))
	_check(GameState.npc_fleets.size() == fleets_before
		and GameState.wrecks.size() == 1,
		"wrecks live in GameState.wrecks, never the fleet array")
	# Expiry: alive on spawn_day+4, gone from spawn_day+5's tick — checked
	# by id on an empty board (the day tick's other work must not blur it).
	var wreck_id := str(wreck.get("id", ""))
	GameState.wrecks = [wreck.duplicate(true)]
	GameState.npc_fleets = []
	sim.reset_index()
	sim.last_tick_day = -1
	GameState.day = day + 4
	sim.tick(day + 4)
	_check(_wreck_exists(wreck_id), "the wreck survives 4 days")
	sim.last_tick_day = -1
	GameState.day = day + 5
	sim.tick(day + 5)
	_check(not _wreck_exists(wreck_id),
		"the wreck despawns after exactly 5 days")


func _wreck_cell(wreck: Dictionary) -> Vector2i:
	return NpcFleetsLib.position_of(wreck)


func _wreck_exists(id: String) -> bool:
	for wreck in GameState.wrecks:
		if str((wreck as Dictionary).get("id", "")) == id:
			return true
	return false


# --- 4. Privateer rival-only targeting (§4.1.1; 70-* §4.5) ------------------

func _test_privateer_targeting() -> void:
	var sim := _make_run()
	var day := 20
	# Spain sponsors privateers; its pinned rivals are portugal and italy.
	var privateer := _make_fleet(sim, "privateer", "spain", OPEN_CELL)
	privateer["anchor_cell"] = {"x": OPEN_CELL.x, "y": OPEN_CELL.y}
	var rival_trader := _stationary(_make_fleet(sim, "trader", "portugal",
		OPEN_CELL + Vector2i(0, 4)), day)
	# An ottoman trader is nearer — but ottoman is not a sponsor rival.
	var stranger_trader := _stationary(_make_fleet(sim, "trader", "ottoman",
		OPEN_CELL + Vector2i(2, 0)), day)
	var picked: Dictionary = sim._nearest_prey_within(privateer,
		NpcFleetsLib.CHASE_ON_RADIUS, {})
	_check(str(picked.get("id", "")) == str(rival_trader["id"]),
		"the privateer hunts the rival trader, not the nearer stranger (%s)"
		% str(picked.get("id", "")))
	# A pirate in the same waters takes the nearest of any nation.
	var pirate := _make_fleet(sim, "pirate", "", OPEN_CELL + Vector2i(1, 0))
	pirate["anchor_cell"] = {"x": OPEN_CELL.x + 1, "y": OPEN_CELL.y}
	picked = sim._nearest_prey_within(pirate, NpcFleetsLib.CHASE_ON_RADIUS, {})
	_check(str(picked.get("id", "")) == str(stranger_trader["id"]),
		"a pirate takes the nearest prey of any nation")
	# With only strangers in reach the privateer holds its anchor.
	var doomed: Dictionary = {}
	var remove_ids: Array = []
	var wrecks: Array = []
	GameState.npc_fleets.erase(rival_trader)
	sim.reset_index()
	picked = sim._nearest_prey_within(privateer,
		NpcFleetsLib.CHASE_ON_RADIUS, {})
	_check(picked.is_empty(), "no rival prey in reach ⇒ no chase")
	privateer["target_fleet_id"] = ""
	sim._raider_tick(privateer, day, doomed, remove_ids, wrecks)
	_check(_cell_of(privateer) == OPEN_CELL and remove_ids.is_empty(),
		"the privateer camps its chokepoint without rival prey")


# --- 5. Chokepoint anchoring + the 5/8 hysteresis (§4.11.11.1) ---------------

func _test_chokepoint_hysteresis() -> void:
	var sim := _make_run()
	# A real spawned pirate anchors within Chebyshev 3 of a chokepoint
	# (junction) tile, on water off the lane raster.
	var pirate := sim.spawn("pirate", "", 12)
	_check(not pirate.is_empty(), "a pirate spawns for the anchor check")
	if pirate.is_empty():
		return
	var anchor := _cell_of(pirate)
	var anchor_dict: Dictionary = pirate.get("anchor_cell", {})
	var nearest := _nearest_junction_distance(sim, anchor)
	_check(nearest >= 0 and nearest <= NpcFleetsLib.ANCHOR_RADIUS,
		"the pirate anchors within Chebyshev 3 of a chokepoint tile (%d)"
		% nearest)
	_check(not sim._is_path_tile(anchor),
		"the anchor sits off the lane raster (the corridor stays clear)")
	# The chase opens inside 5… (prey at exactly Chebyshev 5)
	var day := 20
	var trader := _stationary(_make_fleet(sim, "trader", "portugal",
		anchor + Vector2i(5, 0)), day)
	var doomed: Dictionary = {}
	var remove_ids: Array = []
	var wrecks: Array = []
	sim._raider_tick(pirate, day, doomed, remove_ids, wrecks)
	_check(str(pirate.get("target_fleet_id", "")) == str(trader["id"]),
		"prey within Chebyshev 5 opens the chase")
	# …closes 1 tile/day without engaging until contact distance…
	for _walk in range(3):
		sim._raider_tick(pirate, day + 1 + _walk, doomed, remove_ids, wrecks)
	var walked_out := NpcFleetsLib.chebyshev(_cell_of(pirate), anchor)
	_check(walked_out == 4 and wrecks.is_empty(),
		"the raider closes on its prey 1 tile/day (out %d tiles, no resolve yet)"
		% walked_out)
	# …and is lost beyond 8: the raider drops the chase and walks home.
	trader["cell"] = {"x": (anchor + Vector2i(30, 0)).x, "y": anchor.y}
	sim.reset_index()
	sim._raider_tick(pirate, day + 4, doomed, remove_ids, wrecks)
	_check(str(pirate.get("target_fleet_id", "")) == "",
		"prey beyond Chebyshev 8 drops the chase")
	for _home in range(6):
		sim._raider_tick(pirate, day + 5 + _home, doomed, remove_ids, wrecks)
	_check(NpcFleetsLib.chebyshev(_cell_of(pirate), anchor)
			<= NpcFleetsLib.ANCHOR_RADIUS,
		"the lost raider returns within Chebyshev 3 of its chokepoint")
	# Anchored again: no prey ⇒ it holds within 3 of the anchor.
	for _day in range(day + 12, day + 40):
		sim._raider_tick(pirate, _day, doomed, remove_ids, wrecks)
	_check(NpcFleetsLib.chebyshev(_cell_of(pirate), anchor)
			<= NpcFleetsLib.ANCHOR_RADIUS,
		"an anchored raider stays within Chebyshev 3 of its chokepoint")
	# Sitting near a tagged chokepoint yields regular sightings; the open
	# sea stays quiet — the same query, out in the empty band.
	var quiet := _make_fleet(sim, "pirate", "", OPEN_CELL + Vector2i(200, 60))
	quiet["anchor_cell"] = {"x": (OPEN_CELL + Vector2i(200, 60)).x,
		"y": OPEN_CELL.y + 60}
	_check(sim._nearest_prey_within(quiet, NpcFleetsLib.PREY_RADIUS, {}).is_empty(),
		"open water holds no prey for a raider")


## Distance to the nearest chokepoint (junction) tile of the role's lane set;
## −1 when the network has none.
func _nearest_junction_distance(sim: NpcFleetsLib, cell: Vector2i) -> int:
	var best := -1
	for junction in sim._anchor_tiles("pirate", ""):
		var distance := NpcFleetsLib.chebyshev(cell, junction)
		if best < 0 or distance < best:
			best = distance
	return best


# --- 6. Seeded depletion runs (the done-when gate) ---------------------------

func _test_depletion_runs() -> void:
	# 16 stationary unescorted traders bait one anchored camp, one wave at a
	# time; the seeded 60% drains them. A raider that loses its roll is
	# spent (the loser despawns, §4.11.11.2) and the trickle re-occupies
	# the camp — modelled here by a fresh seeded pirate, exactly what
	# `_largest_deficit` refills the next day.
	var sim := _make_run()
	var camp := OPEN_CELL
	var pirate := _make_fleet(sim, "pirate", "", camp, 777777)
	pirate["anchor_cell"] = {"x": camp.x, "y": camp.y}
	var waves := 16
	var lost := 0
	var tick_total_ms := 0.0
	var ticks := 0
	for wave in waves:
		var day := 30 + wave * 6
		var trader := _stationary(_make_fleet(sim, "trader", "portugal",
			camp + Vector2i(4, 0)), day)
		var pirate_alive := true
		for step in range(6):
			GameState.day = day + step
			var started := Time.get_ticks_usec()
			sim._step_fleets(GameState.day)
			tick_total_ms += float(Time.get_ticks_usec() - started) / 1000.0
			ticks += 1
			pirate_alive = _fleet_exists(str(pirate["id"]))
			if not pirate_alive:
				break
		if not _fleet_exists(str(trader["id"])):
			lost += 1
		if not pirate_alive:
			# The trickle's refill: the next seeded raider takes the camp.
			pirate = _make_fleet(sim, "pirate", "", camp, 777777 + wave + 1)
			pirate["anchor_cell"] = {"x": camp.x, "y": camp.y}
	_check(lost >= 6,
		"raiders measurably deplete unescorted traders (%d of %d waves)"
		% [lost, waves])
	_check(GameState.wrecks.size() >= lost,
		"every loss left a wreck (%d wrecks for %d losses)"
		% [GameState.wrecks.size(), lost])
	var avg_ms := tick_total_ms / float(maxi(ticks, 1))
	print("  ecology probe: %d step ticks, avg %.2f ms" % [ticks, avg_ms])
	print("PROFILE ecology_tick_avg_ms %d" % int(round(avg_ms)))

	# Escorted lanes stay traffic-healthy: same camp, same waves, but a
	# same-nation patrol stands within Chebyshev 10 of every trader — the
	# raider loses its one engagement and no trader is ever taken.
	var sim2 := _make_run()
	var pirate2 := _make_fleet(sim2, "pirate", "", camp, 777777)
	pirate2["anchor_cell"] = {"x": camp.x, "y": camp.y}
	var survived := 0
	for wave in waves:
		var day := 30 + wave * 6
		var trader := _stationary(_make_fleet(sim2, "trader", "portugal",
			camp + Vector2i(4, 0)), day)
		_stationary(_make_fleet(sim2, "patrol", "portugal",
			camp + Vector2i(4, 8)), day)
		for step in range(6):
			GameState.day = day + step
			sim2._step_fleets(GameState.day)
			if not _fleet_exists(str(pirate2["id"])):
				break
		if _fleet_exists(str(trader["id"])):
			survived += 1
	_check(survived == waves,
		"escorted lanes lose no traders while the raider is spent (%d/%d)"
		% [survived, waves])
	_check(not _fleet_exists(str(pirate2["id"])),
		"the escorted engagement costs the raider its fleet")
	_check(not GameState.wrecks.is_empty()
		and int(GameState.wrecks[0].get("salvage_gold", 0)) > 0,
		"the spent raider leaves a salvage-paying warship wreck")


func _fleet_exists(id: String) -> bool:
	for fleet in GameState.npc_fleets:
		if str((fleet as Dictionary).get("id", "")) == id:
			return true
	return false


# --- 7. Collect-on-entry respects free capacity (§4.11.11.2) -----------------

func _test_collect_capacity() -> void:
	var sim := _make_run()
	var day := 20
	# A trader wreck: cargo up to free capacity, goods id-ascending.
	var wreck := {
		"id": "wk_20_0700_0320", "cell": {"x": OPEN_CELL.x, "y": OPEN_CELL.y},
		"cargo": {"wine": 10, "wool": 20}, "salvage_gold": 0,
		"spawn_day": day,
	}
	GameState.wrecks = [wreck]
	var result: Dictionary = sim.collect_wreck("wk_20_0700_0320", 15)
	_check(int(result.get("cargo", {}).get("wine", 0)) == 10
		and int(result.get("cargo", {}).get("wool", 0)) == 5,
		"collect takes cargo up to free capacity, goods id-ascending (%s)"
		% str(result.get("cargo", {})))
	_check(int(result.get("leftover", -1)) == 15,
		"the overflow reports as leftover (%d)" % int(result.get("leftover", -1)))
	_check(int(result.get("gold", -1)) == 0, "a trader wreck pays no gold")
	_check(sim.wreck_at(OPEN_CELL).is_empty() and GameState.wrecks.is_empty(),
		"collecting consumes the wreck")
	_check(sim.collect_wreck("wk_20_0700_0320", 10).is_empty(),
		"an unknown wreck id collects nothing")
	# A warship wreck: the salvage gold pays in full regardless of capacity.
	GameState.wrecks = [{
		"id": "wk_21_0700_0320", "cell": {"x": OPEN_CELL.x, "y": OPEN_CELL.y},
		"cargo": {}, "salvage_gold": 900, "spawn_day": day,
	}]
	result = sim.collect_wreck("wk_21_0700_0320", 0)
	_check(int(result.get("gold", -1)) == 900 and result.get("cargo", {}).is_empty(),
		"salvage gold pays in full with zero free hold")


# --- 8. The player combat surface through the real world scene ---------------

func _test_world_scene_surface() -> void:
	_make_run()
	GameState.day = 40
	var world: Node2D = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	await get_tree().process_frame
	# The fixtures must live in the scene's own sim: the world keeps its own
	# bucket index, so a fleet added through a second sim instance would be
	# invisible to `fleet_at`/`nearest_contact`.
	var sim: NpcFleetsLib = world.fleet_sim()
	var events: Array = []
	var handler := func(encounter: Dictionary) -> void: events.append(encounter)
	EventBus.battle_started.connect(handler)
	var tile := GameState.world_tile()

	# Right-click attack on a cargo-carrying trader: the confirm modal, the
	# piracy funnel at battle start, and the §4.11.11.2 loot row on victory.
	var trader := _make_fleet(sim, "trader", "england", tile + Vector2i(1, 0))
	trader["cargo"] = {"wool": 12}
	var gold_before := GameState.gold
	var hold_before := FleetLib.held("wool")
	_check(world._try_attack(tile + Vector2i(1, 0)),
		"the right-click attack engages the adjacent trader")
	_check(events.is_empty() and world._attack_confirm != null,
		"attacking any non-pirate fleet asks for the piracy confirm first")
	if world._attack_confirm != null:
		world._attack_confirm.confirmed.emit()
	await get_tree().process_frame
	_check(events.size() == 1, "the confirmed attack opens one battle")
	_check(int(GameState.player["reputation"]["england"]) == -20,
		"the funnel charges −20 with the owner at battle start (got %d)"
		% int(GameState.player["reputation"]["england"]))
	_check(int(GameState.player["reputation"]["holland"]) == 2
		and int(GameState.player["reputation"]["portugal"]) == 2,
		"the owner's two rivals gain +2 at battle start")
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	_check(FleetLib.held("wool") == hold_before + 12,
		"the victory loots the fleet's actual cargo flagship-first")
	_check(GameState.gold == gold_before + mini(1000, 100 + 10 * 40),
		"the victory pays min(1000, 100 + 10 × day) = %dg (got %d)"
		% [mini(1000, 100 + 10 * 40), GameState.gold - gold_before])
	_check(not _fleet_exists(str(trader["id"])), "the defeated fleet is removed")

	# A privateer defeat pays +2 with EACH of the two sponsor rivals, on top
	# of the funnel (spain −20, portugal/italy +2 each, then +2 each more).
	var privateer := _make_fleet(sim, "privateer", "spain", tile + Vector2i(0, 1))
	events.clear()
	_check(world._try_attack(tile + Vector2i(0, 1)),
		"the right-click attack engages the privateer")
	if world._attack_confirm != null:
		world._attack_confirm.confirmed.emit()
	await get_tree().process_frame
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	_check(int(GameState.player["reputation"]["spain"]) == -20,
		"attacking the privateer charges its sponsor −20")
	_check(int(GameState.player["reputation"]["portugal"]) == 6
		and int(GameState.player["reputation"]["italy"]) == 4,
		"the privateer defeat pays +2 with each sponsor rival on top of the +2 funnel (portugal %d, italy %d)"
		% [int(GameState.player["reputation"]["portugal"]),
			int(GameState.player["reputation"]["italy"])])

	# A coaster pays its §4.1.1-specific loot pin (25 + floor(day/10))g
	# instead of the general min(1000, 100 + 10 × day) row.
	var coaster := _make_fleet(sim, "coaster", "portugal", tile + Vector2i(0, 1))
	coaster["cargo"] = {"wine": 5}
	gold_before = GameState.gold
	var coaster_wine := FleetLib.held("wine")
	events.clear()
	_check(world._try_attack(tile + Vector2i(0, 1)),
		"the right-click attack engages the coaster")
	if world._attack_confirm != null:
		world._attack_confirm.confirmed.emit()
	await get_tree().process_frame
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	_check(GameState.gold == gold_before + 25 + int(40 / 10),
		"the coaster pays its own loot pin 25 + floor(day/10) = %dg (got %d)"
		% [25 + int(40 / 10), GameState.gold - gold_before])
	_check(FleetLib.held("wine") == coaster_wine + 5,
		"the coaster's actual cargo is looted too")

	# A hostile contact keeps the plain §4.11.10 aftermath (no loot row).
	var pirate := _make_fleet(sim, "pirate", "", tile + Vector2i(1, 0))
	gold_before = GameState.gold
	events.clear()
	world._check_fleet_contact()
	_check(events.size() == 1, "the pirate contact opens its battle")
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	_check(GameState.gold == gold_before,
		"a hostile contact pays no attack-loot gold (the §4.11.10 aftermath stands)")

	# Chained battles survive the new aftermath (§4.11.11.3).
	var chain_a := _make_fleet(sim, "pirate", "", tile + Vector2i(1, 0))
	var chain_b := _make_fleet(sim, "pirate", "", tile + Vector2i(0, 1))
	events.clear()
	world._check_fleet_contact()
	_check(events.size() == 1, "the first chained contact opens")
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	_check(events.size() == 2, "the second fleet in range chains after the first")
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	_check(not world.battle_in_progress(), "the chain closes after the last fleet")

	# Wreck markers render (80-* §4.5.2) and entering the tile collects.
	GameState.wrecks = [{
		"id": "wk_40_collect", "cell": {"x": (tile + Vector2i(1, 0)).x,
			"y": tile.y}, "cargo": {"wine": 6}, "salvage_gold": 300,
		"spawn_day": 40,
	}]
	world._sync_marker_nodes()
	var glyph: Label = world._wreck_nodes.get("wk_40_collect", null)
	_check(glyph != null and glyph.text == "×",
		"the wreck renders as the × glyph")
	gold_before = GameState.gold
	var wine_before := FleetLib.held("wine")
	var stepped: bool = world.try_step(tile + Vector2i(1, 0))
	await get_tree().process_frame
	_check(stepped, "the player steps onto the wreck tile")
	_check(GameState.gold == gold_before + 300
		and FleetLib.held("wine") == wine_before + 6,
		"entering the wreck tile collects cargo + salvage gold (no battle)")
	_check(world._wreck_nodes.get("wk_40_collect", null) == null,
		"the collected wreck's glyph is gone")
	_check(not world.battle_in_progress(),
		"no battle opens on a wreck tile")

	EventBus.battle_started.disconnect(handler)
	world.queue_free()
	await get_tree().process_frame


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
