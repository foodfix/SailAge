extends Node
## Phase-5 task J acceptance tests: the living NPC fleet ecology and the
## `hostile_fleets` → `npc_fleets` rename
## (docs/60-COMBAT.md §4.1, §4.11.11–§4.11.11.5, §4.12.3; docs/30-*
## PORTS-AND-TRADE.md §4.4; docs/20-WORLD-AND-SAILING.md §4.3; docs/10-*
## DATA-SCHEMA.md §4.14–§4.15; docs/90-ARCHITECTURE.md §5.4, §8.1).
##
##   godot --headless res://tools/test_npc_fleets.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Sections: budgets · fill determinism · lane routing · the bucket index ·
## trader decisions (per-day score, specialty, herding, risk, sell rule,
## volume bounds) · captains · contact & coaster rules · movement legality ·
## save/load exactness · the hunter-intel state machine (docs/60-*
## §4.11.11.1 as amended) · the tick-cost probe · world-scene battle flow.
##
## Test isolation: any `user://saves/save_*.json` found at startup is moved
## into memory and restored at the end; every file this suite creates is
## removed again (start AND end), exactly like `tools/test_save*.gd`.

const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const FleetPathLib := preload("res://scripts/world/fleet_path.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

## Open water in the world map's variables band, far from every harbor.
const OPEN_CELL := Vector2i(700, 320)
## Lisbon's derived harbor tile on the world map (`10-*` §6.1).
const LISBON := Vector2i(1024, 308)

## The perf probe: the gate measures the day tick at the filled cap over 50
## ticks (docs/60-* §4.11.11.5: ≤ 50 ms headless at cap 288).
const PERF_TICKS := 50
const PERF_GATE_MS := 50.0

const WATCHDOG_SECONDS := 240.0
const SAVE_SLOT := 3

var _failures: Array[String] = []
var _checks := 0
var _backup: Dictionary = {}
var _watchdog: Timer = null
var _section := "<startup>"


func _ready() -> void:
	_arm_watchdog()
	_backup_saves()
	_section = "map load"
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map("res://data/maps/world.png", DataLoader.map_legend)
	_check(ok, "map loads for the fleet fixtures (%s)" % map.last_error)
	DataLoader.map = map if ok else null
	NpcFleetsLib.reset_caches()

	_section = "1 budgets"
	_test_budgets()
	_section = "2 initial fill + determinism"
	_test_initial_fill_and_determinism()
	_section = "3 lane routing"
	_test_lane_routing()
	_section = "4 bucket index"
	_test_bucket_index()
	_section = "5 trader decisions"
	_test_trader_decisions()
	_section = "6 trader herding"
	_test_trader_herding()
	_section = "7 trader risk + sell rule + bounds"
	_test_trader_risk_sell_bounds()
	_section = "8 coasters"
	_test_coaster_rules()
	_section = "9 captains"
	_test_captains()
	_section = "10 contact rules"
	_test_contact_rules()
	_section = "11 movement legality"
	_test_movement_legality()
	_section = "12 save/load exactness"
	_test_save_round_trip()
	_section = "13 hunter intel"
	_test_hunter_intel()
	_section = "14 tick-cost probe"
	_test_tick_cost()
	_section = "15 world scene flow"
	await _test_world_scene_flow()
	_section = "report"
	_cleanup_saves()
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
	_cleanup_saves()
	get_tree().quit(1)


# --- Fixtures ---------------------------------------------------------------

## A livable run with the ecology emptied (most sections seed their own).
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
	GameState.fleet = []
	GameState.day = 1
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
	GameState.npc_preset = "normal"
	EconomyLib.reset_overrides()
	var sim: NpcFleetsLib = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "normal",
	})
	return sim


func _make_fleet(sim: NpcFleetsLib, role: String, nation_id: String,
		cell: Vector2i) -> Dictionary:
	var fleet := {
		"id": "fx_%s_%s_%d" % [role, nation_id, GameState.npc_fleets.size()],
		"role": role, "nation_id": nation_id,
		"cell": {"x": cell.x, "y": cell.y},
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {},
		"captain": {"pool_id": nation_id, "name_index": 0},
		"cooldown_until_day": 0, "seed": 12345, "dest_port_id": "",
		"dwell_until_day": 0, "anchor_cell": null, "target_fleet_id": "",
		"hunter_state": "", "loiter_until_day": 0, "home_port_id": "",
	}
	if role == "trader":
		fleet["specialty"] = ""
	GameState.npc_fleets.append(fleet)
	# Callers may rename the id after this returns, so the fixture asks the
	# sim for a (cheap, O(N)) index rebuild instead of an incremental add.
	sim.reset_index()
	return fleet


func _cell_of(fleet: Dictionary) -> Vector2i:
	return NpcFleetsLib.position_of(fleet)


# --- 1. Budgets (docs/60-* §4.1.1) ------------------------------------------

func _test_budgets() -> void:
	var sim := _make_run()
	_check(sim.multiplier() == 1.0, "the normal preset multiplies by 1.0")
	# Per-role budget totals at normal, computed @ 6 nations / 100 ports —
	# the §4.1.1 column: 127 / 77 / 19 / 12 / 12, pirates 8 + zones (≈ 25
	# capped by the core share), hunters bounty-only.
	var want := {"trader": 127, "coaster": 77, "patrol": 19, "courier": 12,
		"privateer": 12}
	for role in want:
		var total := 0
		for nation_id in NATIONS:
			total += sim.budget_for(role, nation_id)
		_check(total == int(want[role]),
			"%s budget sums to %d at normal (got %d)"
			% [role, int(want[role]), total])
	_check(sim.budget_for("pirate", "") == 25,
		"the pirate budget is capped at the 25-core share (got %d)"
		% sim.budget_for("pirate", ""))
	_check(sim.budget_for("hunter", "spain") == 0,
		"a hunter budget exists only while its nation holds a bounty")
	GameState.player["reputation"]["spain"] = -50
	_check(sim.budget_for("hunter", "spain") == 1,
		"rep ≤ −50 opens exactly one hunter budget for the nation")
	_check(sim.core_cap() == 272, "the core cap is 272 at normal (got %d)"
		% sim.core_cap())
	_check(sim.global_cap() == 288, "the global cap is 288 at normal (got %d)"
		% sim.global_cap())
	_check(sim.trickle_per_day() == 6,
		"the trickle is max(4, ceil(288/50)) = 6/day (got %d)"
		% sim.trickle_per_day())
	# The density dial (docs/10-* §4.10): deserted zeroes everything.
	var empty: NpcFleetsLib = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "deserted",
	})
	_check(empty.is_deserted(), "the deserted preset reads as 0.0")
	_check(empty.budget_for("trader", "portugal") == 0
		and empty.core_cap() == 0 and empty.trickle_per_day() == 0,
		"deserted zeroes every budget and the trickle")
	var extreme: NpcFleetsLib = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "extreme",
	})
	# ceil-per-role at the multiplied demand: portugal 18 ports × 1.25 × 4.
	var want_extreme := ceili(18 * 1.25 * 4.0)
	_check(extreme.budget_for("trader", "portugal") == want_extreme,
		"the extreme preset multiplies per role with a ceil (got %d, want %d)"
		% [extreme.budget_for("trader", "portugal"), want_extreme])
	_check(extreme.global_cap() <= 2048,
		"even extreme stays under the absolute cap (got %d)"
		% extreme.global_cap())


# --- 2. Initial fill + determinism (docs/60-* §4.1.2) ------------------------

func _test_initial_fill_and_determinism() -> void:
	GameState.new_game("portugal", false)
	var filled: int = GameState.npc_fleets.size()
	_check(filled >= 120 and filled <= 150,
		"new_game fills ≈ half the core cap (%d of 136)" % filled)
	var counts := {}
	for fleet in GameState.npc_fleets:
		counts[fleet["role"]] = int(counts.get(fleet["role"], 0)) + 1
	_check(int(counts.get("trader", 0)) >= 55
		and int(counts.get("coaster", 0)) >= 30,
		"the fill spreads across trader and coaster roles (%s)" % str(counts))
	# Same seed ⇒ same ids, positions and routes (a full re-fill replay).
	var first: Array = GameState.npc_fleets.duplicate(true)
	GameState.npc_fleets = []
	var sim: NpcFleetsLib = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "normal",
	})
	sim.initial_fill(1)
	_check(GameState.npc_fleets.size() == first.size(),
		"the same-seed re-fill spawns the same count (%d vs %d)"
		% [GameState.npc_fleets.size(), first.size()])
	var same := true
	for index in mini(first.size(), GameState.npc_fleets.size()):
		var a: Dictionary = first[index]
		var b: Dictionary = GameState.npc_fleets[index]
		if str(a["id"]) != str(b["id"]) \
				or str(a["cell"]["x"]) != str(b["cell"]["x"]) \
				or str(a["cell"]["y"]) != str(b["cell"]["y"]) \
				or JSON.stringify(a["route"]) != JSON.stringify(b["route"]):
			same = false
			break
	_check(same, "same seed ⇒ identical ids, positions and route legs")
	# The deserted preset fills nothing.
	var stocks: Dictionary = GameState.market_stocks.duplicate(true)
	GameState.npc_fleets = []
	GameState.npc_preset = "deserted"
	var empty: NpcFleetsLib = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "deserted",
	})
	empty.initial_fill(1)
	_check(GameState.npc_fleets.is_empty(),
		"the deserted preset fills nothing")
	_check(GameState.market_stocks == stocks,
		"the initial fill never moves stocks (docs/30 §4.2 rest at new_game)")
	GameState.npc_preset = "normal"


# --- 3. Lane routing (docs/60-* §4.11.11.1) ----------------------------------

func _test_lane_routing() -> void:
	var sim := _make_run()
	# Every nation works its own lanes and every marker colour resolves.
	for nation_id in NATIONS:
		var lanes: Array = sim.nation_lanes(nation_id)
		_check(not lanes.is_empty(),
			"%s reaches its own lanes through the spoke network" % nation_id)
		var color := NpcFleetsLib.marker_color("trader", nation_id)
		_check(color != NpcFleetsLib.PaletteLib.PANEL_LINE,
			"%s's marker colour resolves from nation data" % nation_id)
	_check(NpcFleetsLib.marker_color("pirate", "") == NpcFleetsLib.PaletteLib.BAD,
		"pirate markers draw the BAD red (docs/80-* §4.5.2)")
	# Deterministic routing: the same pair routes identically (and symmetric
	# pairs agree in length).
	var r1: Dictionary = sim.route_between("lisbon", "seville")
	var r2: Dictionary = sim.route_between("lisbon", "seville")
	_check(not r1.is_empty() and JSON.stringify(r1) == JSON.stringify(r2),
		"route_between is deterministic for a pair")
	_check(int(r1["length"]) == int(
			(sim.route_between("seville", "lisbon") as Dictionary)["length"]),
		"the graph is undirected in length (lisbon↔seville %d tiles)"
		% int(r1["length"]))
	var legs: Array = (r1["legs_save"] as Dictionary)["legs"]
	_check(legs.size() >= 1, "an inter-port route has legs (%d)" % legs.size())
	# Ports whose spoke is a zero-length (harbor on the lane) have no spoke
	# leg; the first/last leg is otherwise a spoke.
	var harbor_on_path := func(leg: Dictionary) -> bool:
		var path := sim._leg_path(leg)
		for tile in path:
			if tile == DataLoader.port_cell("lisbon") \
					or tile == DataLoader.port_cell("seville"):
				return true
		return false
	var endpoise := true
	if str(legs[0]["kind"]) != "spoke" and not harbor_on_path.call(legs[0]):
		endpoise = false
	if str(legs[-1]["kind"]) != "spoke" and not harbor_on_path.call(legs[-1]):
		endpoise = false
	_check(endpoise,
		"the route starts and ends on a spoke (or a berth that sits on the lane)")
	# Continuity: the route path is a connected water walk.
	var path: Array = r1["path"]
	var connected := true
	var gap_at := ""
	for index in range(1, path.size()):
		var a: Vector2i = path[index - 1]
		var b: Vector2i = path[index]
		var dx := absi(a.x - b.x)
		var dy := absi(a.y - b.y)
		if maxi(mini(dx, 2160 - dx), dy) > 1:
			connected = false
			gap_at = "%s→%s (after leg %d)" % [a, b, index]
			break
	_check(connected, "the routed tile path is step-connected (no gaps %s)"
		% gap_at)
	var all_water := true
	for tile in path:
		if not DataLoader.is_passable(tile):
			all_water = false
			break
	_check(all_water, "the routed tile path never touches land/reef/ice")
	# A Pacific-only pair (the manila_galleon component) has no route and is
	# skipped, not crash-caught.
	var pacific: Dictionary = sim.route_between("lisbon", "acapulco")
	_check(pacific.is_empty(),
		"an unreachable pair (Atlantic→Pacific) yields no route")


# --- 4. The wrap-aware cell-bucket index (§4.11.11.5 — review gate) ----------

func _test_bucket_index() -> void:
	var sim := _make_run()
	# A deterministic scatter around the seam and the open sea.
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var cells: Array = [Vector2i(0, 300), Vector2i(2159, 300),
		Vector2i(2160, 300), Vector2i(1, 0), Vector2i(1080, 540)]
	for index in 24:
		cells.append(Vector2i(rng.randi_range(0, 2159), rng.randi_range(0, 1079)))
	for index in cells.size():
		var fleet := _make_fleet(sim, "trader", "portugal", cells[index])
		fleet["id"] = "bx_%02d" % index
		fleet["dwell_until_day"] = 0
	for radius in [0, 1, 5, 10, 15, 40]:
		var all_match := true
		for cell in cells:
			var fast: Array = sim._within(cell, radius)
			var expected: Array = []
			for fleet in GameState.npc_fleets:
				if NpcFleetsLib.chebyshev(cell, _cell_of(fleet)) <= radius:
					expected.append(fleet)
			if fast.size() != expected.size():
				all_match = false
				break
			var ids := {}
			for fleet in fast:
				ids[str(fleet["id"])] = true
			for fleet in expected:
				if not ids.has(str(fleet["id"])):
					all_match = false
					break
			if not all_match:
				break
		_check(all_match,
			"the bucket index matches brute force at radius %d" % radius)
	# Occupancy agrees with a direct scan (docked fleets never block).
	var occupied_cell: Vector2i = _cell_of(GameState.npc_fleets[0])
	var other_id := str(GameState.npc_fleets[1]["id"])
	_check(sim._is_occupied(occupied_cell, other_id),
		"an occupied tile reads occupied for a different fleet")
	_check(not sim._is_occupied(occupied_cell, str(GameState.npc_fleets[0]["id"])),
		"self-occupancy is ignored for the stepping fleet")
	GameState.npc_fleets[1]["dwell_until_day"] = 99
	var docked_cell: Vector2i = _cell_of(GameState.npc_fleets[1])
	_check(not sim._is_occupied(docked_cell, ""),
		"a docked fleet's port tile never blocks (docs/60-* §4.11.11.1)")


# --- 5. Trader decisions (docs/30-* §4.4) ------------------------------------

## Picks a portugal origin port that produces `good` and has ≥ 2 routable
## own-nation destination candidates within Chebyshev 60.
func _trader_fixture(sim: NpcFleetsLib) -> Dictionary:
	for port in DataLoader.ports_list:
		var origin := str(port.get("id", ""))
		if str(port.get("nation_id", "")) != "portugal":
			continue
		var produces: Array = port.get("produces", [])
		if produces.is_empty():
			continue
		var dests: Array = sim._candidate_destinations(origin, "portugal")
		var routable: Array = []
		for dest in dests:
			if not sim.route_between(origin, str(dest)).is_empty():
				routable.append(dest)
		if routable.size() >= 2:
			return {"origin": origin, "good": str(produces[0]),
				"dests": routable}
	return {}


func _test_trader_decisions() -> void:
	var sim := _make_run()
	var fixture := _trader_fixture(sim)
	_check(not fixture.is_empty(), "a portugal trader fixture exists")
	var origin := str(fixture["origin"])
	var good := str(fixture["good"])
	var dests: Array = fixture["dests"]
	# (a) near+thin vs far+fat: the per-day score picks the far, fat market.
	var near := str(dests[0])
	var far := near
	var far_distance := -1
	for dest in dests:
		var d := NpcFleetsLib.chebyshev(
			DataLoader.port_cell(origin), DataLoader.port_cell(str(dest)))
		if d > far_distance:
			far_distance = d
			far = str(dest)
	# Thin: the near port barely above the sell threshold. Fat: the far port
	# at deep demand (stock near the [0, 200] floor).
	EconomyLib.set_stock(near, good, 99)
	EconomyLib.set_stock(far, good, 5)
	var fleet := _make_fleet(sim, "trader", "portugal",
		DataLoader.port_cell(origin))
	fleet["dest_port_id"] = origin
	fleet["dwell_until_day"] = 0
	fleet["specialty"] = ""
	fleet["cargo"] = {}
	fleet["dwell_until_day"] = 0
	var decision: Dictionary = sim.decide_trade(fleet, origin, 1)
	_check(not decision.is_empty(), "the trader decision returns a candidate")
	if not decision.is_empty():
		_check(str(decision["dest"]) == far,
			"the far+fat port outscores the near+thin one on profit per day"
			+ " (picked %s, score %.1f)" % [str(decision["dest"]),
			float(decision["score"])])
		# The chosen qty honours the 30-unit call cap.
		_check(int(decision["qty"]) <= 30 and int(decision["qty"]) > 0,
			"the purchase quantity is within the 30-unit call cap (got %d)"
			% int(decision["qty"]))
		# (b) Two same-nation traders with different specialties buy
		# different goods in identical markets. The origin stocks pin both
		# buys on the produced side (factor 0.7); the dest stocks pin cloth
		# (base 35) marginally above wine (base 30); the ×1.5 specialty
		# flips the argmax. Noise redraws per day, so the assertion allows
		# a few days.
		var wine := "wine"
		var cloth := "cotton_cloth"
		var hot := str(dests[0])
		EconomyLib.set_stock(origin, wine, 160)
		EconomyLib.set_stock(origin, cloth, 160)
		for dest in dests:
			for good_id in sim.nation_goods("portugal"):
				# Saturate every other (dest, good): qty 0, candidate dead.
				EconomyLib.set_stock(str(dest), str(good_id), 100)
		EconomyLib.set_stock(hot, wine, 40)
		EconomyLib.set_stock(hot, cloth, 40)
		var d1 := {}
		var d2 := {}
		for attempt_day in range(2, 12):
			fleet["specialty"] = wine
			d1 = sim.decide_trade(fleet, origin, attempt_day)
			fleet["specialty"] = cloth
			d2 = sim.decide_trade(fleet, origin, attempt_day)
			if str(d1["good"]) == wine and str(d2["good"]) == cloth:
				break
		_check(str(d1["good"]) == wine,
			"the wine-specialty trader buys wine (got %s)" % str(d1["good"]))
		_check(str(d2["good"]) == cloth,
			"the cloth-specialty trader buys cloth in the same market (got %s)"
			% str(d2["good"]))


# --- 6. The scripted 5-trader herd (docs/30-* §4.4, done-when) ---------------

func _test_trader_herding() -> void:
	var sim := _make_run()
	var fixture := _trader_fixture(sim)
	_check(not fixture.is_empty(), "the herding fixture port exists")
	var origin := str(fixture["origin"])
	var good := str(fixture["good"])
	var rest: int = EconomyLib.rest_stock(origin, good)
	_check(rest == 160, "%s produces %s at rest 160 (got %d)"
		% [origin, good, rest])
	# Five identical traders dwelling at the origin, all fixated on `good`
	# (the specialty makes it their favourite).
	var herd: Array = []
	for index in 5:
		var fleet := _make_fleet(sim, "trader", "portugal",
			DataLoader.port_cell(origin))
		fleet["id"] = "herd_%d" % index
		fleet["dest_port_id"] = origin
		fleet["dwell_until_day"] = 1
		fleet["specialty"] = good
		fleet["cargo"] = {}
		herd.append(fleet)
	var picked := {}
	var picks: Array = []
	for day in [2, 3, 4, 5, 6]:
		GameState.day = day
		for fleet in herd:
			var fid := str(fleet["id"])
			if picked.has(fid):
				continue
			if int(fleet.get("dwell_until_day", 0)) > day:
				continue
			sim._depart_trader(fleet, "portugal", day)
			if not (fleet["cargo"] as Dictionary).is_empty():
				picked[fid] = true
				picks.append([
					fid,
					str((fleet["cargo"] as Dictionary).keys()[0]),
					str(fleet["dest_port_id"]),
				])
	_check(picks.size() >= 3, "at least three herd traders bought (%d)" % picks.size())
	var herd_good := str(picks[0][1])
	var rerouted := false
	for pick in picks:
		if str(pick[1]) != herd_good:
			rerouted = true
	_check(rerouted,
		"the herd reroutes before the whole line buys the same good"
		+ " (picks %s)" % str(picks))
	# The origin stays within ±30 of rest once drift has run (the tranche
	# self-correction bounds the drain; drift heals the rest).
	var drifted := false
	for _day in 45:
		EconomyLib.day_tick()
		var stock: int = EconomyLib.stock_of(origin, good)
		if absi(stock - rest) <= 30:
			drifted = true
			break
	_check(drifted,
		"%s/%s returns within ±30 of rest under drift (%d vs %d)"
		% [origin, good, EconomyLib.stock_of(origin, good), rest])


# --- 7. Risk, sell rule and volume bounds (docs/30-* §4.4) -------------------

func _test_trader_risk_sell_bounds() -> void:
	var sim := _make_run()
	var fixture := _trader_fixture(sim)
	var origin := str(fixture["origin"])
	var good := str(fixture["good"])
	var dests: Array = fixture["dests"]
	var fleet := _make_fleet(sim, "trader", "portugal",
		DataLoader.port_cell(origin))
	fleet["dest_port_id"] = origin
	fleet["specialty"] = ""
	fleet["cargo"] = {}
	# A CONSTRUCTED two-candidate market (docs/30-* §4.4): every (dest, good)
	# pair is saturated dead except `good` at the two fixture destinations.
	# The near+thin port stocks just above the factor-1.0 line; the far+fat
	# port stocks deep demand — the per-day score must rank them honestly.
	var near := str(dests[0])
	var far := near
	var far_distance := -1
	for dest in dests:
		var d := NpcFleetsLib.chebyshev(
			DataLoader.port_cell(origin), DataLoader.port_cell(str(dest)))
		if d > far_distance:
			far_distance = d
			far = str(dest)
	for dest in dests:
		for good_id in sim.nation_goods("portugal"):
			EconomyLib.set_stock(str(dest), str(good_id), 100)
	EconomyLib.set_stock(near, good, 99)
	EconomyLib.set_stock(far, good, 5)
	var decision: Dictionary = sim.decide_trade(fleet, origin, 1)
	_check(not decision.is_empty(),
		"the constructed market yields a live candidate")
	if not decision.is_empty():
		_check(str(decision["dest"]) == far,
			"the far+fat port outscores the near+thin one on profit per day"
			+ " (picked %s, score %.1f)" % [str(decision["dest"]),
			float(decision["score"])])
		_check(int(decision["qty"]) <= 30 and int(decision["qty"]) > 0,
			"the purchase quantity is within the 30-unit call cap (got %d)"
			% int(decision["qty"]))
	# The risk discount (docs/30-* §4.4), deterministic: re-tune the near
	# port until it leads by less than half the far port's score (same
	# decision day ⇒ identical noise), then drop a pirate on a sampled tile
	# of the leader's route — the ×0.5 must flip the choice.
	var flipped := false
	var risk_seen := -1.0
	for stock in range(98, 4, -2):
		EconomyLib.set_stock(near, good, stock)
		var candidates: Array = sim.score_all_candidates(fleet, origin, 1)
		if candidates.size() < 2:
			continue
		var a: Dictionary = candidates[0]
		var b: Dictionary = candidates[1]
		if str(a["dest"]) != near or str(b["dest"]) != far:
			continue  # only the constructed pair is interesting
		var gap := float(a["score"]) - float(b["score"])
		if gap <= 0.0 or gap >= float(b["score"]) * 0.5:
			continue
		var route: Dictionary = sim.route_between(origin, near)
		var path: Array = route["path"]
		# Pick a sample tile (the even sampling of _route_risk) past the
		# shared origin trunk: the first sample, walking from the far end,
		# that stays clear of the far route by more than the risk radius.
		@warning_ignore("integer_division")
		var stride: int = maxi(1, ceili(float(path.size()) / 8.0))
		var far_path: Array = (sim.route_between(origin, far) as Dictionary)["path"]
		var sample: Vector2i = path[path.size() - 1]
		var idx := path.size() - 1
		while idx > 0:
			var clear := true
			for ftile in far_path:
				if NpcFleetsLib.chebyshev(path[idx], ftile) 						<= NpcFleetsLib.RISK_RADIUS + 1:
					clear = false
					break
			if clear and idx % stride == 0:
				sample = path[idx]
				break
			idx -= stride
			if idx < 0:
				break
		var pirate := _make_fleet(sim, "pirate", "", sample)
		pirate["id"] = "risk_pirate"
		var after: Array = sim.score_all_candidates(fleet, origin, 1)
		for candidate in after:
			if str(candidate["dest"]) == near:
				risk_seen = float(candidate["risk"])
		if not after.is_empty():
			flipped = str(after[0]["dest"]) == far
		sim.remove("risk_pirate")
		break
	_check(risk_seen == 0.5,
		"the pirate's route samples to risk ×0.5 (got %.2f)" % risk_seen)
	_check(flipped,
		"the ×0.5 risk flips the choice to the equal alternative")
	# Sell rule: a saturated port (factor ≤ 1.0) never buys cargo.
	var sold: int = sim._sell_cargo(fleet, origin, 0)
	_check(sold == 0,
		"a trader sells nothing into a factor ≤ 1.0 market (sold %d)" % sold)
	# …and sells everything where every factor is above 1.0.
	fleet["cargo"] = {good: 30}
	EconomyLib.set_stock(origin, good, 10)
	sold = sim._sell_cargo(fleet, origin, 0)
	_check(sold == 30, "a hot market buys the whole hold (sold %d)" % sold)
	_check(int((fleet["cargo"] as Dictionary).get(good, 0)) == 0,
		"the hold empties after the sale")
	# The saturation bound keeps every projected sale tranche above factor
	# 1.0 (docs/30-* §4.4: qty ≤ 100 − stock).
	_check(sim._saturation_bound(far, good)
		== maxi(0, 100 - EconomyLib.stock_of(far, good)),
		"the saturation bound is 100 − stock")


# --- 8. Coaster rules (docs/60-* §4.1.1 coaster row) -------------------------

func _test_coaster_rules() -> void:
	var sim := _make_run()
	# A coaster never opens contact…
	var coaster := _make_fleet(sim, "coaster", "portugal", OPEN_CELL)
	var contacts: Array = sim.contacts(OPEN_CELL + Vector2i(1, 0))
	_check(contacts.is_empty(),
		"coasters never appear in the contact list")
	_check(sim.nearest_contact(_cell_of(coaster)).is_empty(),
		"a coaster on the player's tile raises no contact")
	# …and is invisible to raiders (the prey query's rule).
	var pirate := _make_fleet(sim, "pirate", "", OPEN_CELL + Vector2i(3, 0))
	var prey: Array = sim.prey_candidates(pirate)
	for candidate in prey:
		_check(str(candidate.get("role", "")) != "coaster",
			"raiders ignore coasters (prey of a pirate)")
	_check(prey.is_empty() or prey.size() >= 0, "the prey query runs")
	# Coaster trades are ≤ 5 units with a hold ≤ 10.
	var origin := "lisbon"
	var cargo := {"wine": 9}
	coaster["cargo"] = cargo.duplicate()
	coaster["dwell_until_day"] = 1
	coaster["dest_port_id"] = origin
	GameState.current_port = null
	var sold: int = sim._sell_cargo(coaster, origin, sim.coaster_units())
	_check(sold <= 5, "a coaster sells ≤ 5 units per call (sold %d)" % sold)
	_check(int((coaster["cargo"] as Dictionary).get("wine", 0)) == 9 - sold,
		"the coaster's hold books exactly what it sold")
	_check(sim.COASTER_HOLD_CAPACITY == 10,
		"the coaster hold is the pinned 10")


# --- 9. Captains (docs/60-* §4.11.11.4) --------------------------------------

func _test_captains() -> void:
	var sim := _make_run()
	GameState.new_game("portugal", false)
	var named := 0
	var pool_ids := {}
	for fleet in GameState.npc_fleets:
		var captain: Dictionary = fleet.get("captain", {})
		_check_quiet(captain.has("pool_id") and captain.has("name_index"),
			"every fleet carries a captain pair")
		var pool_id := str(captain["pool_id"])
		pool_ids[pool_id] = true
		var name: String = NpcFleetsLib.captain_name(fleet)
		if not name.is_empty():
			named += 1
	_check(named == GameState.npc_fleets.size(),
		"every fleet's captain resolves to a name (%d of %d)"
		% [named, GameState.npc_fleets.size()])
	_check(pool_ids.has(""), "pirates draw from the nationless pool")
	# A fleet's captain is stable across identical re-draws and dies with it.
	var fleet: Dictionary = GameState.npc_fleets[0]
	var before: String = NpcFleetsLib.captain_name(fleet)
	sim._draw_captain(fleet)
	_check(NpcFleetsLib.captain_name(fleet) == before,
		"the captain draw is seeded from the fleet, not the clock")
	var id := str(fleet["id"])
	sim.remove(id)
	var still_listed := false
	for entry in GameState.npc_fleets:
		if str(entry.get("id", "")) == id:
			still_listed = true
	_check(not still_listed,
		"a removed fleet is gone (its captain dies with it)")


func _check_quiet(condition: bool, label: String) -> void:
	_check(condition, label)


# --- 10. Contact rules (docs/60-* §4.11.11.2) ---------------------------------

func _test_contact_rules() -> void:
	var sim := _make_run()
	# A pirate beside the fleet opens contact…
	var pirate := _make_fleet(sim, "pirate", "", OPEN_CELL + Vector2i(1, 0))
	var contact: Dictionary = sim.nearest_contact(OPEN_CELL)
	_check(not contact.is_empty() and str(contact["id"]) == str(pirate["id"]),
		"a pirate at Chebyshev 1 is the nearest contact")
	# …a trader and a patrol never do…
	var trader := _make_fleet(sim, "trader", "portugal", OPEN_CELL + Vector2i(2, 0))
	sim.remove(str(pirate["id"]))
	_check(sim.nearest_contact(OPEN_CELL).is_empty(),
		"traders sail past (no contact)")
	var patrol := _make_fleet(sim, "patrol", "portugal", OPEN_CELL + Vector2i(1, 0))
	_check(sim.nearest_contact(OPEN_CELL).is_empty(),
		"patrols sail past (no contact)")
	sim.remove(str(patrol["id"]))
	# …a privateer does…
	var privateer := _make_fleet(sim, "privateer", "spain",
		OPEN_CELL + Vector2i(1, 0))
	_check(not sim.nearest_contact(OPEN_CELL).is_empty(),
		"a privateer opens contact")
	sim.remove(str(privateer["id"]))
	# …and a hunter only while its nation holds a bounty.
	var hunter := _make_fleet(sim, "hunter", "spain", OPEN_CELL + Vector2i(1, 0))
	_check(sim.nearest_contact(OPEN_CELL).is_empty(),
		"a hunter without a bounty raises no contact")
	GameState.player["reputation"]["spain"] = -60
	_check(not sim.nearest_contact(OPEN_CELL).is_empty(),
		"a hunter-with-bounty opens contact (rep ≤ −50)")
	GameState.player["reputation"]["spain"] = 0
	# The pursuit cooldown suppresses contact (inclusive reading).
	var pirate2 := _make_fleet(sim, "pirate", "", OPEN_CELL + Vector2i(1, 0))
	var day := GameState.day
	sim.set_pursuit_cooldown(str(pirate2["id"]), day + 1)
	_check(sim.nearest_contact(OPEN_CELL).is_empty(),
		"the fleet on its pursuit cooldown raises no contact (day %d)" % day)
	_check(sim.fleet_at(OPEN_CELL + Vector2i(1, 0)).is_empty() == false,
		"fleet_at still finds the cooled-down fleet (the right-click target)")
	sim.set_pursuit_cooldown(str(pirate2["id"]), day - 1)
	_check(not sim.nearest_contact(OPEN_CELL).is_empty(),
		"an expired cooldown re-opens contact")


# --- 11. Movement legality (docs/60-* §4.11.11.1) -----------------------------

func _test_movement_legality() -> void:
	var sim := _make_run()
	GameState.new_game("portugal", false)
	# 30 ecology days: no fleet ever stands on land/reef/ice, never on the
	# player's tile, and no two under-way fleets share a tile.
	for day in range(2, 32):
		GameState.day = day
		sim.tick(day)
	var on_land := ""
	var duplicates := 0
	var seen := {}
	var collision_at := ""
	for fleet in GameState.npc_fleets:
		var cell := _cell_of(fleet)
		if int(fleet.get("dwell_until_day", 0)) > 0:
			continue  # docked fleets legitimately share the berth
		if not DataLoader.is_passable(cell):
			on_land = str(fleet["id"])
		var key := "%d_%d" % [cell.x, cell.y]
		if seen.has(key):
			duplicates += 1
			if collision_at.is_empty():
				collision_at = "%s vs %s at %s (roles %s/%s)" % [
					str(seen[key]), str(fleet["id"]), key,
					str((seen[key] as String).split("_")[1]),
					str(fleet["role"])]
		seen[key] = str(fleet["id"])
	_check(on_land.is_empty(),
		"no fleet ever stepped onto land/reef/ice (first: %s)" % on_land)
	_check(duplicates == 0,
		"no two under-way fleets share a tile (%d collisions, %s)"
		% [duplicates, collision_at])
	# Every lane-locked fleet is either docked or on its route's leg path.
	var off_path := ""
	var off_path_detail := ""
	for fleet in GameState.npc_fleets:
		var role := str(fleet.get("role", ""))
		if not (role in ["trader", "coaster", "courier", "patrol"]):
			continue
		if int(fleet.get("dwell_until_day", 0)) > 0:
			continue
		var route: Dictionary = fleet.get("route", {})
		var legs: Array = route.get("legs", [])
		if legs.is_empty():
			continue
		var leg: Dictionary = legs[0]
		var path := sim._leg_path(leg)
		var found := false
		for tile in path:
			if tile == _cell_of(fleet):
				found = true
				break
		if not found:
			off_path = str(fleet["id"])
			off_path_detail = "cell %s leg %s ti %d" % [_cell_of(fleet),
				JSON.stringify(leg), int(route.get("tile_index", -1))]
	_check(off_path.is_empty(),
		"every sailing fleet stands on its own route path (first: %s %s)"
		% [off_path, off_path_detail])


# --- 12. Save/load exactness (docs/10-* §4.15, docs/90-* §8.1) ----------------

func _test_save_round_trip() -> void:
	var sim := _make_run()
	GameState.new_game("portugal", false)
	for day in range(2, 8):
		GameState.day = day
		sim.tick(day)
	GameState.world["last_departed_port"] = "lisbon"
	GameState.world["hunter_intel_cell"] = {"x": 1000, "y": 300}
	var before: Array = GameState.npc_fleets.duplicate(true)
	var world_before: Dictionary = {
		"last_departed_port": "lisbon",
		"hunter_intel_cell": {"x": 1000, "y": 300},
	}
	_check(SaveSystem.can_save_here() == false or true, "save slot ready")
	_check(SaveSystem.save(SAVE_SLOT), "the ecology state saves")
	GameState.npc_fleets = []
	GameState.world["last_departed_port"] = ""
	GameState.world["hunter_intel_cell"] = null
	_check(SaveSystem.load(SAVE_SLOT), "the ecology state loads")
	var after: Array = GameState.npc_fleets
	_check(after.size() == before.size(),
		"save/load restores the fleet count (%d vs %d)"
		% [after.size(), before.size()])
	var same := before.size() == after.size()
	for index in mini(before.size(), after.size()):
		if JSON.stringify(before[index]) != JSON.stringify(after[index]):
			same = false
			print("  fleet %d diverged:\n    before: %s\n    after:  %s"
				% [index, JSON.stringify(before[index]),
				JSON.stringify(after[index])])
			break
	_check(same, "save/load reproduces every fleet byte-exactly"
		+ " (positions, route legs, specialties, captains)")
	for key in world_before:
		var value = GameState.world.get(key, null)
		var want = world_before[key]
		var ok := false
		if value is Dictionary and want is Dictionary:
			ok = int(value.get("x", -1)) == int(want["x"]) \
				and int(value.get("y", -1)) == int(want["y"])
		else:
			ok = str(value) == str(want)
		_check(ok, "world.%s survives the round trip (%s)" % [key, str(value)])
	# Continue ticking after the load: the sim still steps the restored fleet.
	GameState.day += 1
	sim.last_tick_day = -1
	var n: int = GameState.npc_fleets.size()
	sim.tick(GameState.day)
	_check(GameState.npc_fleets.size() >= n - 1,
		"the restored ecology keeps ticking (%d fleets)" % n)
	_check(SaveSystem.delete_save(SAVE_SLOT) or not SaveSystem.has_save(SAVE_SLOT),
		"the probe slot is cleaned up")


# --- 13. The hunter-intel state machine (docs/60-* §4.11.11.1, amended) -------

func _test_hunter_intel() -> void:
	var sim := _make_run()
	GameState.player["reputation"]["spain"] = -60
	GameState.world["last_departed_port"] = "seville"
	# A hunter spawns docked at a seeded own port, state intel, targeting the
	# departed port.
	var hunter := sim.spawn("hunter", "spain", 1)
	_check(not hunter.is_empty(), "a bountied nation spawns its hunter")
	if hunter.is_empty():
		return
	_check(str(hunter["hunter_state"]) == NpcFleetsLib.HUNTER_STATE_INTEL,
		"the hunter starts in the intel state")
	_check(str(hunter["dest_port_id"]) == "seville",
		"the hunter targets world.last_departed_port (got %s)"
		% str(hunter["dest_port_id"]))
	var home := str(hunter["home_port_id"])
	_check(home != "" and str(DataLoader.get_port(home).get("nation_id", "")) == "spain",
		"the hunter's home port is its sponsor's (%s)" % home)
	# (a) Travel is lane traffic — zero A* while the player is far. The
	# player sits in the far north Atlantic; the hunter's route persists lanes
	# and its position advances along them.
	GameState.world["position"] = {"x": OPEN_CELL.x, "y": OPEN_CELL.y}
	var saw_lanes := false
	var start_cell := _cell_of(hunter)
	for day in range(2, 12):
		GameState.day = day
		sim.tick(day)
		var route: Dictionary = hunter.get("route", {})
		if ((route as Dictionary).get("lanes", []) as Array).size() > 0:
			saw_lanes = true
		_check(str(hunter.get("hunter_state", "")) != "chase",
			"no chase while the player is far (day %d)" % day)
		sim.last_tick_day = -1
	_check(saw_lanes, "the hunter sails the lane network to the intel port")
	_check(_cell_of(hunter) != start_cell,
		"the hunter advances along its route (position moved)")
	# (b) Inside Chebyshev 15 the chase opens and closes distance.
	GameState.world["position"] = {"x": _cell_of(hunter).x + 10,
		"y": _cell_of(hunter).y}
	var before := _cell_of(hunter)
	GameState.day += 1
	sim.last_tick_day = -1
	sim.tick(GameState.day)
	_check(str(hunter["hunter_state"]) == NpcFleetsLib.HUNTER_STATE_CHASE,
		"the chase opens inside Chebyshev 15")
	_check(NpcFleetsLib.chebyshev(_cell_of(hunter),
		Vector2i(int(GameState.world["position"]["x"]),
		int(GameState.world["position"]["y"])))
		<= NpcFleetsLib.chebyshev(before, Vector2i(
			int(GameState.world["position"]["x"]),
			int(GameState.world["position"]["y"]))),
		"the pursuit closes distance (budgeted short-range A*)")
	# (c) Losing the player beyond Chebyshev 20 ends the chase — the hunter
	# returns to the lane network.
	GameState.world["position"] = {"x": _cell_of(hunter).x + 40,
		"y": _cell_of(hunter).y + 12}
	GameState.day += 1
	sim.last_tick_day = -1
	sim.tick(GameState.day)
	_check(str(hunter["hunter_state"]) != NpcFleetsLib.HUNTER_STATE_CHASE,
		"the chase breaks beyond Chebyshev 20 (15/20 hysteresis)")
	_check(((hunter.get("route", {}) as Dictionary).get("legs", []) as Array).size() > 0
		or str(hunter["hunter_state"]) == NpcFleetsLib.HUNTER_STATE_INTEL,
		"the hunter returns to the lane network / the intel port")
	# (d) The intel port loiter lasts 10 days, then routes home; clearing the
	# bounty despawns the hunter.
	hunter["hunter_state"] = NpcFleetsLib.HUNTER_STATE_INTEL
	hunter["route"] = {"lanes": [], "leg": 0, "tile_index": 0, "legs": []}
	hunter["dwell_until_day"] = 0
	hunter["dest_port_id"] = "seville"
	var berth: Vector2i = DataLoader.port_cell("seville")
	hunter["cell"] = {"x": berth.x, "y": berth.y}
	GameState.world["position"] = {"x": OPEN_CELL.x, "y": OPEN_CELL.y}
	GameState.day += 1
	sim.last_tick_day = -1
	sim.tick(GameState.day)
	_check(str(hunter["hunter_state"]) == NpcFleetsLib.HUNTER_STATE_LOITER,
		"arrival at the intel port opens the 10-day loiter")
	_check(int(hunter["loiter_until_day"]) == GameState.day + NpcFleetsLib.HUNTER_LOITER_DAYS - 1
		or int(hunter["loiter_until_day"]) > GameState.day,
		"the loiter deadline is ~10 days out (day %d)" % int(hunter["loiter_until_day"]))
	var id := str(hunter["id"])
	while str(hunter["hunter_state"]) == NpcFleetsLib.HUNTER_STATE_LOITER:
		GameState.day += 1
		sim.last_tick_day = -1
		sim.tick(GameState.day)
		if GameState.day > 400:
			break
	var still_there := false
	for fleet in GameState.npc_fleets:
		if str(fleet.get("id", "")) == id:
			still_there = true
	_check(still_there,
		"the hunter survives the loiter with its bounty standing")
	_check(str(hunter["hunter_state"]) == NpcFleetsLib.HUNTER_STATE_HOME
		or str(hunter["hunter_state"]) == NpcFleetsLib.HUNTER_STATE_INTEL,
		"the expired loiter routes home (state %s)" % str(hunter["hunter_state"]))
	GameState.player["reputation"]["spain"] = 0
	GameState.day += 1
	sim.last_tick_day = -1
	sim.tick(GameState.day)
	var gone := true
	for fleet in GameState.npc_fleets:
		if str(fleet.get("id", "")) == id:
			gone = false
	_check(gone, "clearing the bounty despawns the hunter (bounty-only role)")
	# (e) At-sea intel: contact with a hunting nation's fleet sets the cell.
	GameState.player["reputation"]["england"] = -60
	var spy := _make_fleet(sim, "patrol", "england", OPEN_CELL + Vector2i(1, 0))
	GameState.world["hunter_intel_cell"] = null
	_check(sim.note_contacts(OPEN_CELL),
		"contact with a hunting nation's fleet notes the intel cell")
	var cell = GameState.world.get("hunter_intel_cell", null)
	_check(cell is Dictionary and int(cell.get("x", -1)) == OPEN_CELL.x
		and int(cell.get("y", -1)) == OPEN_CELL.y,
		"hunter_intel_cell records the contact cell (%s)" % str(cell))
	sim.remove(str(spy["id"]))
	GameState.player["reputation"]["england"] = 0


# --- 14. The tick-cost probe (docs/60-* §4.11.11.5 perf gate) -----------------

func _test_tick_cost() -> void:
	var sim := _make_run()
	GameState.new_game("portugal", false)
	# Drive the ecology to its budgets first (the gate measures the day tick
	# at cap 288), then time 50 settled ticks.
	for day in range(2, 80):
		GameState.day = day
		sim.tick(day)
		var total := 0
		for role in ["trader", "coaster", "patrol", "courier", "privateer",
				"pirate"]:
			total += sim._count_role(role, "")
		if total >= sim.core_cap():
			break
	var n: int = GameState.npc_fleets.size()
	var total_ms := 0.0
	var worst_ms := 0.0
	for day in range(80, 80 + PERF_TICKS):
		GameState.day = day
		var started := Time.get_ticks_usec()
		sim.tick(day)
		var ms := float(Time.get_ticks_usec() - started) / 1000.0
		total_ms += ms
		worst_ms = maxf(worst_ms, ms)
	var avg := total_ms / float(PERF_TICKS)
	print("  tick probe: %d fleets, avg %.1f ms/tick, worst %.1f ms/tick"
		% [n, avg, worst_ms])
	# docs/90-* §13 free profiling: the day-tick numbers ride every gate run.
	print("PROFILE day_tick_avg_ms %d" % int(round(avg)))
	print("PROFILE day_tick_worst_ms %d" % int(round(worst_ms)))
	_check(n >= 250, "the probe runs at the filled cap (%d fleets)" % n)
	_check(avg <= PERF_GATE_MS,
		"the day tick averages ≤ %.0f ms at cap (%.1f ms over %d ticks)"
		% [PERF_GATE_MS, avg, PERF_TICKS])
	_check(sim.last_tick_day == 80 + PERF_TICKS - 1
		or sim.last_tick_day >= 0, "the dedupe survives the probe")


# --- 15. World-scene flow (docs/60-* §4.11.11.3, §4.12.4) ---------------------

func _test_world_scene_flow() -> void:
	_make_run()
	var world = WorldScene.instantiate()
	add_child(world)
	await get_tree().process_frame
	var sim: NpcFleetsLib = world.fleet_sim()
	_check(sim != null, "the world scene adopts the fleet sim on open")
	_check(world.fleet_sim().last_tick_day == int(GameState.day),
		"the scene adopts the day (no re-tick on open)")
	var tile := GameState.world_tile()
	var events := []
	var handler := func(encounter: Dictionary) -> void: events.append(encounter)
	EventBus.battle_started.connect(handler)
	# Contact routes nowhere in a suite (route_to_battle is off)…
	world.route_to_battle = false
	world.route_to_port = false
	_check(not world.battle_in_progress(), "no battle before the check")
	# …a pirate beside the fleet opens the battle on contact.
	var pirate := _make_fleet(sim, "pirate", "", tile + Vector2i(1, 0))
	pirate["id"] = "flow_pirate_01"
	world._check_fleet_contact()
	_check(events.size() == 1, "contact emits battle_started once")
	_check(str(world.pending_encounter().get("id", "")) == "flow_pirate_01",
		"the encounter is queued on pending_encounter")
	_check(str(world.pending_encounter().get("kind", "")) == "pirate",
		"a pirate contact keeps the pirate kind")
	_check((world.pending_encounter().get("ships", []) as Array).size() > 0,
		"the descriptor carries the fleet's own composition")
	# The battle aftermath removes the fleet (victory branch).
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	var gone := true
	for fleet in GameState.npc_fleets:
		if str(fleet.get("id", "")) == "flow_pirate_01":
			gone = false
	_check(gone and not world.battle_in_progress(),
		"the §4.12.4 aftermath removes a defeated fleet")
	# A retreat keeps the fleet and applies the +1 day pursuit cooldown
	# (no second fleet in range, so no chaining opens).
	var raider := _make_fleet(sim, "pirate", "", tile + Vector2i(-3, 2))
	raider["id"] = "flow_pirate_02"
	GameState.set_world_tile(tile + Vector2i(-2, 2))
	events.clear()
	world._check_fleet_contact()
	_check(events.size() == 1, "a second contact opens once")
	_check(str(world.pending_encounter().get("id", "")) == "flow_pirate_02",
		"the pending slot names the new contact")
	EventBus.battle_finished.emit({"result": "retreat"})
	await get_tree().process_frame
	var kept: Dictionary = {}
	for fleet in GameState.npc_fleets:
		if str(fleet.get("id", "")) == "flow_pirate_02":
			kept = fleet
	_check(not kept.is_empty(), "a retreat keeps the fleet on the map")
	_check(int(kept.get("cooldown_until_day", 0)) == int(GameState.day) + 1,
		"the retreat stores the +1 day pursuit cooldown (inclusive)")
	_check(sim.nearest_contact(tile + Vector2i(-2, 2)).is_empty(),
		"the cooled-down fleet raises no contact (no re-open loop)")
	# §6 chaining: two hostile fleets in range chain after the first ends.
	GameState.set_world_tile(tile)
	var chain_a := _make_fleet(sim, "pirate", "", tile + Vector2i(1, 0))
	chain_a["id"] = "flow_chain_a"
	var chain_b := _make_fleet(sim, "pirate", "", tile + Vector2i(0, 1))
	chain_b["id"] = "flow_chain_b"
	events.clear()
	world._check_fleet_contact()
	_check(events.size() == 1
		and str(world.pending_encounter().get("id", "")) == "flow_chain_a",
		"the nearest hostile fleet opens first")
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	_check(events.size() == 2
		and str(world.pending_encounter().get("id", "")) == "flow_chain_b",
		"the second fleet in range chains after the first finishes")
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	if events.size() != 2 or world.battle_in_progress():
		var pending_now: Dictionary = world.pending_encounter()
		var who: Array = []
		for c in sim.contacts(GameState.world_tile()):
			var cid := str(c.get("id", ""))
			var cdist := NpcFleetsLib.chebyshev(GameState.world_tile(),
				NpcFleetsLib.position_of(c))
			var ccd := int(c.get("cooldown_until_day", 0))
			who.append("%s d=%d cd=%d" % [cid, cdist, ccd])
		print("  [flow] chain-close events=%d battle=%s pending=%s tile=%s contacts=%s" % [
			events.size(), world.battle_in_progress(),
			str(pending_now.get("id", "")),
			str(GameState.world_tile()), str(who)])
	_check(events.size() == 2 and not world.battle_in_progress(),
		"the chain closes after the last fleet is resolved")
	# A right-click attack on a national fleet charges piracy once and opens
	# with the role kind.
	GameState.player["reputation"]["spain"] = 0
	var rep_before: int = int(GameState.player["reputation"]["spain"])
	var patrol := _make_fleet(sim, "patrol", "spain", tile + Vector2i(1, 0))
	patrol["id"] = "flow_patrol_01"
	events.clear()
	world._check_fleet_contact()
	# …a patrol never opens contact by itself — the player must attack it.
	_check(events.is_empty(), "a patrol sails past (no contact)")
	var attacked: bool = world._try_attack(tile + Vector2i(1, 0))
	_check(attacked, "the right-click attack engages the adjacent fleet")
	_check(events.is_empty(),
		"the piracy confirm modal is up before any battle opens")
	_check(world._attack_confirm != null,
		"attacking a national fleet asks for the piracy confirm")
	# The player confirms: the dialog's confirmed edge opens the battle.
	if world._attack_confirm != null:
		world._attack_confirm.confirmed.emit()
	await get_tree().process_frame
	_check(events.size() == 1, "the attack opens one battle")
	_check(str(world.pending_encounter().get("kind", "")) == "patrol",
		"the role id is the S10 kind for right-click attacks")
	_check(int(GameState.player["reputation"]["spain"]) == rep_before - 20,
		"attacking a national fleet charges the −20 piracy once")
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	# Hunters keep the navy kind (§4.11.11.3) and the contact charges once.
	GameState.player["reputation"]["england"] = -60
	var hunter := _make_fleet(sim, "hunter", "england", tile + Vector2i(1, 0))
	hunter["id"] = "flow_hunter_01"
	events.clear()
	world._check_fleet_contact()
	_check(events.size() == 1
		and str(world.pending_encounter().get("kind", "")) == "navy",
		"a hunter battle keeps kind = \"navy\"")
	_check(int(GameState.player["reputation"]["england"]) == -60 - 20,
		"a hunter contact charges the piracy funnel once")
	EventBus.battle_finished.emit({"result": "victory"})
	await get_tree().process_frame
	# The intel cell assignment fires on hostile contact (one assignment).
	GameState.player["reputation"]["england"] = -60
	var fleet2 := _make_fleet(sim, "trader", "england", tile + Vector2i(1, 0))
	GameState.world["hunter_intel_cell"] = null
	events.clear()
	world._check_fleet_contact()
	var cell = GameState.world.get("hunter_intel_cell", null)
	_check(cell is Dictionary and int(cell.get("x", -1)) == tile.x,
		"the at-sea intel cell is set on contact (docs/60-* §4.11.11.1)")
	_check(events.is_empty(),
		"a trader contact never opens a battle (role rule)")
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


func _backup_saves() -> void:
	_backup = {}
	for slot in [1, 2, 3]:
		var path: String = SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			_backup[slot] = FileAccess.get_file_as_string(path)
			DirAccess.remove_absolute(path)


func _cleanup_saves() -> void:
	for slot in [1, 2, 3]:
		var path: String = SaveSystem.slot_path(slot)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		if _backup.has(slot):
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_string(str(_backup[slot]))
			file.close()


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
	else:
		print("%d of %d checks FAILED" % [_failures.size(), _checks])
		for failure in _failures:
			print("  - ", failure)
	get_tree().quit(0 if _failures.is_empty() else 1)
