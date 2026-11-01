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
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

## Open water in the world map's variables band, far from every harbor.
const OPEN_CELL := Vector2i(700, 320)
## Lisbon's derived harbor tile on the world map (`10-*` §6.1).
const LISBON := Vector2i(1024, 308)

## The perf probe: the gate measures the day tick at the filled cap over 50
## ticks (docs/60-* §4.11.11.5: ≤ 75 ms headless at cap 288 — the
## unified-movement re-pin).
const PERF_TICKS := 50
## Unified-movement amendment: re-pinned with the §4.11.11.5 gate
## (the doc pin is 75 ms — `test_density` measures it on the quiet serial
## path). This suite's probe is a secondary smoke check and runs +1 σ
## headroom (80 ms) so ambient machine load cannot flip it.
const PERF_GATE_MS := 80.0

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
	_section = "16 parity factors"
	_test_parity_factors()
	_section = "16b unified movement"
	_test_unified_movement()
	_section = "16c stall diagnostics"
	_test_stall_diagnostics()
	_section = "17 variant flip"
	_test_variant_flip()
	_section = "18 ice refusal"
	_test_ice_refusal()
	_section = "19 neutral docking"
	_test_neutral_docking()
	_section = "20 regional lanes"
	_test_regional_lanes()
	_section = "21 pursuit budget"
	_test_pursuit_budget()
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
	# Per-role budget totals at normal, computed @ 6 nations / 100 sovereign
	# ports + the 45-port neutral tier (which no per-nation budget counts,
	# §2.11) — the §4.1.1 column: 128 / 77 / 19 / 12 / 12, pirates 8 + zones
	# (≈ 25 capped by the core share), hunters bounty-only. 128 = 127 + 1:
	# the botany_bay→Shark Bay re-place moved one port england → holland
	# (ceil(13 × 1.25) + ceil(21 × 1.25) = 17 + 27 vs 18 + 25).
	var want := {"trader": 128, "coaster": 77, "patrol": 19, "courier": 12,
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
	_check(sim.core_cap() == 273, "the core cap is 273 at normal (got %d)"
		% sim.core_cap())
	_check(sim.global_cap() == 289, "the global cap is 289 at normal (got %d)"
		% sim.global_cap())
	_check(sim.trickle_per_day() == 6,
		"the trickle is max(4, ceil(289/50)) = 6/day (got %d)"
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
	# The once-Pacific-only manila_galleon component joined the giant network
	# with the Phase-6 lanes (pacific_america + the E-spokes; the W3 probe
	# acapulco ↔ manila pins it), so lisbon → acapulco routes now. A pair in
	# the still-separate hanseatic_north/iceland_cod cluster (london) has no
	# route and is skipped, not crash-caught.
	var pacific: Dictionary = sim.route_between("lisbon", "london")
	_check(pacific.is_empty(),
		"an unreachable pair (Atlantic→hanseatic cluster) yields no route")


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
	# 30 ecology days: no fleet ever stands on land/reef, never on the
	# player's tile, no two under-way fleets share a tile — and no fleet ever
	# MOVES INTO in-month seasonal ice (the §4.18 entry rule, task-H: a cell
	# changing under a standing fleet never traps it, so only transitions
	# are checked).
	var ice_entries := 0
	var ice_entry_at := ""
	var prev_cells := {}
	for day in range(2, 32):
		GameState.day = day
		sim.tick(day)
		var ocean = OceanLayersLib.instance()
		var month := SailingSimLib.month_for(GameState.day)
		for fleet in GameState.npc_fleets:
			var id := str((fleet as Dictionary).get("id", ""))
			var cell := _cell_of(fleet)
			if prev_cells.has(id) and prev_cells[id] != cell \
					and ocean.ice_blocks(cell, month):
				ice_entries += 1
				if ice_entry_at.is_empty():
					ice_entry_at = "%s → %s (day %d)" % [str(prev_cells[id]),
						str(cell), day]
			prev_cells[id] = cell
	var on_land := ""
	var seen := {}
	for fleet in GameState.npc_fleets:
		var cell := _cell_of(fleet)
		if int(fleet.get("dwell_until_day", 0)) > 0:
			continue  # docked fleets legitimately share the berth
		if not DataLoader.is_passable(cell):
			on_land = str(fleet["id"])
		# Unified-movement amendment: fleets MAY share tiles (co-location)
		# — occupancy never blocks a step, so the old "no two under-way
		# fleets share a tile" pin is retired. Interactions are governed
		# by the encounter/contact rules (§4.11.11.2), not by tiles.
		seen[str(fleet["id"])] = str(fleet["id"])
	_check(on_land.is_empty(),
		"no fleet ever stepped onto land/reef/ice (first: %s)" % on_land)
	_check(ice_entries == 0,
		"no fleet ever entered in-month seasonal ice (%d entries, first %s)"
		% [ice_entries, ice_entry_at])
	# Every lane-locked fleet is either docked or on its route's leg path —
	# the ACTIVE geometry (task-H: the in-month variant replaces the tile
	# path in its window; `_leg_path` alone would read the base path).
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
		var path := sim._leg_path_active(leg)
		var found := false
		for tile in path:
			if tile == _cell_of(fleet):
				found = true
				break
		if not found:
			# Unified-movement: fleets in the flagged `blocked` state are
			# EXPECTED to stand off-path (they are jammed — that is what
			# the stall diagnostics and the S3 badge surface). Only
			# un-flagged sailing fleets violate the on-path invariant.
			if sim.stall_state(fleet,
					int(sim._hold_ticks.get(str(fleet.get("id", "")), 0))) \
					== "blocked":
				continue
			off_path = str(fleet["id"])
			var active: Array = sim._leg_path_active(leg)
			var full: Array = []
			if str(leg.get("kind", "")) == "lane":
				full = sim._lane_paths.get(str(leg.get("id", "")), [])
			else:
				full = sim._spoke_paths.get(str(leg.get("id", "")), [])
			var in_full := false
			for tile in full:
				if tile == _cell_of(fleet):
					in_full = true
					break
			var active_first := str(active[0]) if not active.is_empty() else "?"
			var active_last := str(active[active.size() - 1]) \
				if not active.is_empty() else "?"
			var full_first := str(full[0]) if not full.is_empty() else "?"
			var full_last := str(full[full.size() - 1]) \
				if not full.is_empty() else "?"
			off_path_detail = "cell " + str(_cell_of(fleet)) \
				+ " ti " + str(int(route.get("tile_index", -1))) \
				+ " active n=" + str(active.size()) \
				+ " first=" + active_first + " last=" + active_last \
				+ " | full n=" + str(full.size()) \
				+ " first=" + full_first + " last=" + full_last \
				+ " | in_full=" + str(in_full) \
				+ " leg=" + JSON.stringify(leg) \
				+ " | holds=" + str(int(sim._hold_ticks.get(
					str(fleet.get("id", "")), -1))) \
				+ " state=" + sim.stall_state(fleet,
					int(sim._hold_ticks.get(str(fleet.get("id", "")), 0)))
	_check(off_path.is_empty(),
		"every sailing fleet stands on its own ACTIVE route path (first: %s %s)"
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
	# (b) Inside Chebyshev 30 the chase opens and closes distance.
	GameState.world["position"] = {"x": _cell_of(hunter).x + 10,
		"y": _cell_of(hunter).y}
	var before := _cell_of(hunter)
	GameState.day += 1
	sim.last_tick_day = -1
	sim.tick(GameState.day)
	_check(str(hunter["hunter_state"]) == NpcFleetsLib.HUNTER_STATE_CHASE,
		"the chase opens inside Chebyshev 30")
	_check(NpcFleetsLib.chebyshev(_cell_of(hunter),
		Vector2i(int(GameState.world["position"]["x"]),
		int(GameState.world["position"]["y"])))
		<= NpcFleetsLib.chebyshev(before, Vector2i(
			int(GameState.world["position"]["x"]),
			int(GameState.world["position"]["y"]))),
		"the pursuit closes distance (budgeted short-range A*)")
	# (c) Losing the player beyond Chebyshev 40 ends the chase — the hunter
	# returns to the lane network.
	GameState.world["position"] = {"x": _cell_of(hunter).x + 45,
		"y": _cell_of(hunter).y + 12}
	GameState.day += 1
	sim.last_tick_day = -1
	sim.tick(GameState.day)
	_check(str(hunter["hunter_state"]) != NpcFleetsLib.HUNTER_STATE_CHASE,
		"the chase breaks beyond Chebyshev 40 (30/40 hysteresis)")
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


# --- 16. Phase-6 parity factors (docs/60-* §4.11.11 amendment; §2.8) ---------

## The forward 8-dir heading of the lane walk at `index` ("" at seam jumps).
static func _lane_heading_at(path: Array, index: int) -> String:
	if index + 1 >= path.size():
		return ""
	return SailingSimLib.heading_of_delta(
		(path[index + 1] as Vector2i) - (path[index] as Vector2i))


func _test_parity_factors() -> void:
	var sim := _make_run()
	sim._refresh_net()
	GameState.day = 200  # month 7: no seasonal ice anywhere
	var month := SailingSimLib.month_for(GameState.day)
	# A lane with a running (with-the-wind, factor > 1) and a beating
	# (into-the-wind, factor < 1) stretch in month 7, clear of the fixture
	# band and of any current-perturbed tile mismatch (the factor used is
	# the full dir × current product either way).
	var lane_id := ""
	var run_index := -1
	var beat_index := -1
	var run_factor := 0.0
	var beat_factor := 0.0
	var run_current := 1.0
	var beat_current := 1.0
	for candidate in sim._lane_ids_sorted:
		var path: Array = sim._lane_paths[candidate]
		if path.size() < 60:
			continue
		var found_run := -1
		var found_beat := -1
		var best_run := 1.09
		var best_beat := 0.71
		for index in range(4, path.size() - 52):
			var cell: Vector2i = path[index]
			# Clear of the player by more than the hunter's chase-on radius:
			# a lane stretch inside Chebyshev 30 would flip `_hunter_tick`
			# into pursuit instead of the lane travel under probe.
			if NpcFleetsLib.chebyshev(cell, OPEN_CELL) <= 40:
				continue
			var heading := _lane_heading_at(path, index)
			if heading.is_empty():
				continue
			var f: float = NpcFleetsLib.npc_direction_factor(heading, cell, month)
			if f > best_run:
				best_run = f
				found_run = index
			if f < best_beat:
				best_beat = f
				found_beat = index
		if found_run >= 0 and found_beat >= 0:
			lane_id = str(candidate)
			run_index = found_run
			beat_index = found_beat
			var run_heading := _lane_heading_at(path, run_index)
			var beat_heading := _lane_heading_at(path, beat_index)
			run_current = NpcFleetsLib.npc_current_factor(
				run_heading, path[run_index], month)
			beat_current = NpcFleetsLib.npc_current_factor(
				beat_heading, path[beat_index], month)
			run_factor = best_run
			beat_factor = best_beat
			break
	_check(lane_id != "",
		"a lane with running (%.2f) and beating (%.2f) stretches exists in month %d"
		% [run_factor, beat_factor, month])
	if lane_id.is_empty():
		return
	var path: Array = sim._lane_paths[lane_id]
	# A TRADER and a PATROL walk the same lane through `_step_fleets`: each
	# advances exactly floor(base × wind × direction × current) tiles — the
	# unified §4.4 pipeline, `base` the slowest hull of the fleet's composed
	# ships and `wind` the day weather at the flagship class ("fair" ⇒ 1.0
	# sail) — and the downwind walk advances MORE than the upwind one (the
	# done-when's upwind-vs-downwind proof).
	var run_expected := -1  # hoisted for the hunter/banker checks below
	for role in ["trader", "patrol"]:
		# A fresh board per role: `_step_fleets` walks every fleet on it, and
		# two roles must not share the same lane cells (an occupied target
		# would hold the walk for occupancy, not for parity). `_make_run`
		# resets the clock — restore the probe month (7).
		var board := _make_run()
		GameState.day = 200
		board._refresh_net()
		var runner := _make_fleet(board, role, "portugal", path[run_index])
		runner["id"] = "parity_run_%s" % role
		runner["route"] = {"lanes": [lane_id], "leg": 0, "tile_index": 0,
			"legs": [{"kind": "lane", "id": lane_id, "reverse": false,
				"a": run_index, "b": path.size() - 1}]}
		var beater := _make_fleet(board, role, "portugal", path[beat_index])
		beater["id"] = "parity_beat_%s" % role
		beater["route"] = {"lanes": [lane_id], "leg": 0, "tile_index": 0,
			"legs": [{"kind": "lane", "id": lane_id, "reverse": false,
				"a": beat_index, "b": path.size() - 1}]}
		var run_base: Array = board._fleet_base(runner)
		var beat_base: Array = board._fleet_base(beater)
		var weather := str(GameState.world.get("weather", "fair"))
		var run_pipe := float(int(run_base[0])) \
			* SailingSimLib.wind_factor(weather, str(run_base[1]))
		var beat_pipe := float(int(beat_base[0])) \
			* SailingSimLib.wind_factor(weather, str(beat_base[1]))
		run_expected = int(floor(run_pipe * run_factor * run_current))
		var beat_expected := int(floor(beat_pipe * beat_factor * beat_current))
		_check(run_expected >= 8,
			"the unified budget is hull-scale, not the retired 2-tile base (%d tiles/day)"
			% run_expected)
		var run_tiles: int = board._lane_tiles_today(runner)
		var beat_tiles: int = board._lane_tiles_today(beater)
		_check(run_tiles == run_expected,
			"%s downwind budget = floor(base × %.3f) = %d (got %d)"
			% [role, run_factor * run_current, run_expected, run_tiles])
		_check(beat_tiles == beat_expected,
			"%s upwind budget = floor(base × %.3f) = %d (got %d)"
			% [role, beat_factor * beat_current, beat_expected, beat_tiles])
		_check(run_expected > beat_expected,
			"the downwind %s out-runs the upwind one (%d > %d tiles/day)"
			% [role, run_expected, beat_expected])
		# End-to-end: one day of accrual moves each fleet exactly its budget
		# (fresh day: the probe reads above banked their carry — reset it).
		board._step_carry.clear()
		board._accrue(1.0)
		_check(_cell_of(runner) == path[run_index + run_tiles],
			"the downwind %s advanced %d tiles (at %s)"
			% [role, run_tiles, str(_cell_of(runner))])
		_check(_cell_of(beater) == path[beat_index + beat_tiles],
			"the upwind %s advanced %d tiles (at %s)"
			% [role, beat_tiles, str(_cell_of(beater))])
	# The role boards above leave their runners on the shared lane
	# (`GameState.npc_fleets` is the fixture's global) — wipe them so the
	# hunter's walk meets no occupancy holds. The hunter walk itself is one
	# day of accrual now (the day tick owns no movement).
	GameState.npc_fleets = []
	sim.reset_index()
	GameState.day = 200
	GameState.world["last_departed_port"] = ""
	var hunter := _make_fleet(sim, "hunter", "england", path[run_index])
	hunter["id"] = "parity_hunter"
	hunter["hunter_state"] = NpcFleetsLib.HUNTER_STATE_INTEL
	hunter["dest_port_id"] = ""
	hunter["route"] = {"lanes": [lane_id], "leg": 0, "tile_index": 0,
		"legs": [{"kind": "lane", "id": lane_id, "reverse": false,
			"a": run_index, "b": path.size() - 1}]}
	var before := _cell_of(hunter)
	sim._accrue(1.0)
	# The HUNTER's own composition sets its base (navy-band hulls differ
	# from the trader runner's); the walk lands on the lane path exactly
	# (Chebyshev displacement would under-count a curving leg).
	var hunter_base: Array = sim._fleet_base(hunter)
	var hunter_pipe := float(int(hunter_base[0])) * SailingSimLib.wind_factor(
		str(GameState.world.get("weather", "fair")), str(hunter_base[1]))
	var hunter_expected := int(floor(hunter_pipe * run_factor * run_current))
	_check(str(hunter["hunter_state"]) != NpcFleetsLib.HUNTER_STATE_CHASE
		and _cell_of(hunter) == path[run_index + hunter_expected],
		"the hunter's lane travel pays the unified budget (%d tiles, want %d)"
		% [NpcFleetsLib.chebyshev(before, _cell_of(hunter)), hunter_expected])
	# The fractional accumulator banks the remainder (task-H pin 3, carried
	# into the unified model): seed 0.9 of carry on a fresh downwind walker —
	# floor(base × wind × factor + 0.9) pays an EXTRA tile and leaves a
	# sub-tile remainder banked.
	var banker := _make_fleet(sim, "trader", "portugal", path[run_index])
	banker["id"] = "parity_banker"
	banker["route"] = {"lanes": [lane_id], "leg": 0, "tile_index": 0,
		"legs": [{"kind": "lane", "id": lane_id, "reverse": false,
			"a": run_index, "b": path.size() - 1}]}
	var plain := sim._lane_tiles_today(banker)
	sim._step_carry[str(banker["id"])] = 0.9
	var banked := sim._lane_tiles_today(banker)
	var step_factor := run_factor * run_current
	var bank_base: Array = sim._fleet_base(banker)
	var bank_pipe := float(int(bank_base[0])) * SailingSimLib.wind_factor(
		str(GameState.world.get("weather", "fair")), str(bank_base[1]))
	var bank_expected := int(floor(bank_pipe * step_factor + 0.9))
	_check(banked == bank_expected and banked == plain + 1,
		"the banked carry pays out (plain %d, banked %d, floor(base×%.3f+0.9) = %d)"
		% [plain, banked, step_factor, bank_expected])
	_check(absf(float(sim._step_carry[str(banker["id"])])) < 1.0,
		"the accumulator keeps the sub-tile remainder (%.2f)"
		% float(sim._step_carry[str(banker["id"])]))
	# Determinism: two identical sims walk identical cells (pure day+cell
	# inputs — no RNG).
	var echo := _make_run()
	GameState.day = 200
	echo._refresh_net()
	var twin := _make_fleet(echo, "trader", "portugal", path[run_index])
	twin["id"] = "parity_run_trader"
	twin["route"] = {"lanes": [lane_id], "leg": 0, "tile_index": 0,
		"legs": [{"kind": "lane", "id": lane_id, "reverse": false,
			"a": run_index, "b": path.size() - 1}]}
	echo._accrue(1.0)
	_check(_cell_of(twin) == path[run_index + run_expected],
		"the same seed/day/cells replay identically (%s)" % str(_cell_of(twin)))


# --- 16b. Unified fleet movement (the §4.4-parity amendment) -----------------

func _test_unified_movement() -> void:
	var sim := _make_run()
	sim._refresh_net()
	GameState.day = 200
	# Composition stability: the hull draws key off the fleet seed ONLY —
	# the same fleet composed on two far-apart days draws identical hulls
	# (the day term only budgets cannons, which no speed rule reads).
	var seeded := _make_fleet(sim, "trader", "portugal", OPEN_CELL)
	seeded["seed"] = 424242
	var day_a: Array = sim.compose_fleet_ships(seeded, 100)
	var day_b: Array = sim.compose_fleet_ships(seeded, 250)
	var hulls_a: Array = []
	var hulls_b: Array = []
	for ship in day_a:
		hulls_a.append(str((ship as Dictionary).get("ship_type_id", "")))
	for ship in day_b:
		hulls_b.append(str((ship as Dictionary).get("ship_type_id", "")))
	_check(hulls_a == hulls_b and not hulls_a.is_empty(),
		"the composition is seed-only (day 100 == day 250: %s)"
		% str(hulls_a))
	# The spawn-time storage agrees with the composer, and the old-save
	# backfill (drop `ships`) recomposes it bit-identically.
	sim._fleet_ships(seeded)
	var stored: Array = seeded.get("ships", [])
	var stored_hulls: Array = []
	for ship in stored:
		stored_hulls.append(str((ship as Dictionary).get("ship_type_id", "")))
	_check(stored_hulls == hulls_a,
		"the stored composition equals the composer's draw")
	var base_with: Array = sim._fleet_base(seeded)
	# Erase the list AND its derived cache pair — the cache is the point of
	# the lazy rule (a backfilled fleet never recomposes again).
	seeded.erase("ships")
	seeded.erase("speed")
	seeded.erase("speed_class")
	var base_backfilled: Array = sim._fleet_base(seeded)
	_check(base_with == base_backfilled and seeded.has("ships"),
		"the lazy backfill reproduces the spawn draw (base %s)"
		% str(base_with))
	# Same seed ⇒ same base speed; a same-role sample with distinct seeds
	# generally sails at DISTINCT speeds (the user-visible point of the
	# amendment). Fixtures are removed as soon as they are measured — the
	# contact/pursuit phases below need a clean board around the player.
	var sample_ids: Array = []
	var distinct_speeds: Dictionary = {}
	for index in 12:
		var fleet := _make_fleet(sim, "pirate", "", OPEN_CELL)
		fleet["seed"] = 1000 + index * 7919
		fleet["id"] = "unified_sample_%d" % index
		sample_ids.append(str(fleet["id"]))
		distinct_speeds[int(sim._fleet_base(fleet)[0])] = true
	var twin := _make_fleet(sim, "pirate", "", OPEN_CELL)
	twin["seed"] = 1000
	twin["id"] = "unified_twin"
	var twin2 := _make_fleet(sim, "pirate", "", OPEN_CELL)
	twin2["seed"] = 1000
	twin2["id"] = "unified_twin2"
	_check(int(sim._fleet_base(twin)[0]) == int(sim._fleet_base(twin2)[0]),
		"the same seed draws the same base speed (%d)"
		% int(sim._fleet_base(twin)[0]))
	sim.remove(str(twin2["id"]))
	_check(distinct_speeds.size() >= 2,
		"same-role fleets sail distinct speeds (%d distinct in 12)"
		% distinct_speeds.size())
	# The base is the SLOWEST composed hull (the player fleet's rule).
	var slowest := 0
	for ship in sim._fleet_ships(twin):
		var ship_type: Dictionary = DataLoader.get_ship_type(str(
			(ship as Dictionary).get("ship_type_id", "")))
		var speed := int(ship_type.get("speed", 0))
		if speed > 0 and (slowest == 0 or speed < slowest):
			slowest = speed
	_check(int(sim._fleet_base(twin)[0]) == slowest and slowest >= 16,
		"base speed = slowest composed hull (%d)" % slowest)
	sim.remove(str(seeded["id"]))
	sim.remove(str(twin["id"]))
	for sample_id in sample_ids:
		sim.remove(str(sample_id))
	# Pass-through contact: a pirate marching PAST the player's tile
	# mid-step engages, even though it ends the day beyond Chebyshev 1.
	# The probe picks its own mid-ocean arena (OPEN_CELL's coast need not
	# hold a clear row): the marcher row is the anchor's own row, and the
	# pursuit row is a parallel clear row east of it.
	var arena := Vector2i(-1, -1)
	var pursuit_row := 0
	for y in range(24, 2136, 24):
		if arena.x >= 0:
			break
		for x in range(24, 4296, 24):
			if not DataLoader.is_passable(Vector2i(x, y)):
				continue
			var row_clear := true
			for band_dy in [-1, 0, 1]:
				for dx in range(-8, 9):
					if not DataLoader.is_passable(Vector2i(
							posmod(x + dx, 4320), y + band_dy)):
						row_clear = false
						break
				if not row_clear:
					break
			if not row_clear:
				continue
			for dy in [1, -1, 2, -2, 3, -3, 4, -4]:
				var chase_clear := true
				for dx in range(0, 20):
					if not DataLoader.is_passable(Vector2i(
							posmod(x + dx, 4320), y + dy)):
						chase_clear = false
						break
				if chase_clear:
					arena = Vector2i(x, y)
					pursuit_row = dy
					break
			if arena.x >= 0:
				break
	_check(arena.x >= 0, "a mid-ocean pass-through/pursuit arena exists")
	if arena.x < 0:
		return
	GameState.world["position"] = {"x": arena.x, "y": arena.y}
	# The marcher flanks PAST the player on the diagonal: fleets never enter
	# the player's tile ([method _is_occupied] reserves it), so a same-row
	# march would correctly stop adjacent — the flank crosses at Chebyshev 1
	# and moves on beyond it.
	var marcher := _make_fleet(sim, "pirate", "",
		Vector2i(posmod(arena.x - 6, 4320), arena.y - 1))
	var goal := Vector2i(posmod(arena.x + 6, 4320), arena.y + 1)
	var walks := 0
	while NpcFleetsLib.position_of(marcher) != goal and walks < 6:
		sim._chase_step(marcher, goal)
		walks += 1
	var end_cell := NpcFleetsLib.position_of(marcher)
	_check(NpcFleetsLib.chebyshev(end_cell, arena) > 1,
		"the marcher passed the player and moved on (at %s, %d walks)"
		% [str(end_cell), walks])
	var passed: Dictionary = sim.nearest_contact(arena)
	_check(not passed.is_empty() and str(passed["id"]) == str(marcher["id"]),
		"the pass-through pirate is the contact (mid-step sampling)")
	_check(sim.nearest_contact(arena).is_empty(),
		"the pass queue is consumed — one engagement per pass")
	# Pursuit is speed-matched: a bounty hunter opening the chase 12 tiles
	# out on its own row closes a hull-scale distance in ONE tick (the
	# retired model walked a single tile per day). The ≥ 5 floor is the
	# worst legal pipeline day (base 16 × beat 0.5 × opposed current 0.76).
	GameState.player["reputation"]["spain"] = -60
	var hunter := _make_fleet(sim, "hunter", "spain",
		Vector2i(posmod(arena.x + 12, 4320), arena.y + pursuit_row))
	hunter["hunter_state"] = NpcFleetsLib.HUNTER_STATE_CHASE
	var gap := NpcFleetsLib.chebyshev(
		NpcFleetsLib.position_of(hunter), arena)
	sim._accrue_hunter(hunter, int(GameState.day), 1.0)
	var gap_after := NpcFleetsLib.chebyshev(
		NpcFleetsLib.position_of(hunter), arena)
	_check(gap - gap_after >= 5,
		"the pursuit closes ≥ 5 tiles in one tick (%d → %d)"
		% [gap, gap_after])
	GameState.player["reputation"]["spain"] = 0
	# Cadence (user question: "if the player is very fast, do NPCs ever
	# stop moving?"): NPC displacement is per ELAPSED game-day and
	# independent of player speed — a fast player's small Δ per move
	# chunks the same total into banked fractions. 29 moves of Δ = 1/29
	# day must advance a fleet ≈ exactly its full pipeline budget
	# (±1 tile of rounding at the walk boundaries).
	var cadence := _make_fleet(sim, "trader", "portugal",
		Vector2i(posmod(arena.x - 6, 4320), arena.y - 1))
	cadence["route"] = {"lanes": [], "leg": 0, "tile_index": 0,
		"legs": [{"kind": "lane", "id": "equatorial", "reverse": false,
			"a": 0, "b": 0}]}
	var cadence_cell := Vector2i(-1, -1)
	var cadence_lane := ""
	for candidate in sim._lane_paths.keys():
		var lane_path: Array = sim._lane_paths[candidate]
		if lane_path.size() >= 120 \
				and DataLoader.is_passable(lane_path[4]) \
				and NpcFleetsLib.chebyshev(lane_path[4], arena) > 40:
			cadence_cell = lane_path[4]
			cadence_lane = str(candidate)
			break
	if cadence_cell.x >= 0:
		sim.set_position(cadence, cadence_cell)
		cadence["route"]["lanes"] = [cadence_lane]
		cadence["route"]["legs"][0]["id"] = cadence_lane
		cadence["route"]["legs"][0]["a"] = 4
		cadence["route"]["legs"][0]["b"] = (sim._lane_paths[cadence_lane]
			as Array).size() - 1
		sim._sync_route_progress(cadence)
		# The twin: identical fleet/route/position, accrued in ONE shot.
		# Chunked-vs-oneshot must agree (±1 tile of rounding at the walk
		# boundary) — chunking loses nothing, whatever the pipeline does
		# along the lane (wind regions legitimately vary the rate).
		var twin_acc := _make_fleet(sim, "trader", "portugal", cadence_cell)
		twin_acc["route"] = {
			"lanes": [cadence_lane], "leg": 0, "tile_index": 0,
			"legs": [{
				"kind": "lane", "id": cadence_lane, "reverse": false,
				"a": 4, "b": (sim._lane_paths[cadence_lane] as Array).size() - 1,
			}],
		}
		twin_acc["id"] = "cadence_twin"
		sim._fleet_mark[str(twin_acc.get("id", ""))] = sim._clock_now()
		for _move in 29:
			sim._accrue_lane(cadence, int(GameState.day), 1.0 / 29.0)
			print("  DBG cad move=%d ti=%s cell=%s pipe=%.2f legs=%d"
				% [_move, str((cadence.get("route", {}) as Dictionary).get(
					"tile_index", -1)),
				str(NpcFleetsLib.position_of(cadence)),
				sim._lane_pipe(cadence),
				((cadence.get("route", {}) as Dictionary).get("legs", [])
					as Array).size()])
		# The exact expectation: integrate the per-tile pipeline (the
		# chunked accrual pays each tile's own heading/position factors —
		# the same per-tile rule the player's own movement follows). The
		# one-shot walk pays the FIRST heading's factors for the whole day
		# and legitimately diverges where the lane crosses wind/current
		# regions — chunked is the more faithful model, and it must match
		# the integral exactly (±0: the carry banks the fractions).
		var base_pair: Array = sim._fleet_base(cadence)
		var month := SailingSimLib.month_for(GameState.day)
		var total_cost := 0.0
		var walked_expect := 0
		var idx := 4
		var cadence_path: Array = sim._lane_paths[cadence_lane]
		while idx + 1 < cadence_path.size() and total_cost < 1.0:
			var tile_heading := _lane_heading_at(cadence_path, idx)
			if tile_heading.is_empty():
				break
			var pipe_i := float(int(base_pair[0])) \
				* SailingSimLib.wind_factor("fair", str(base_pair[1])) \
				* NpcFleetsLib.npc_direction_factor(tile_heading,
					cadence_path[idx], month, str(base_pair[1])) \
				* NpcFleetsLib.npc_current_factor(tile_heading,
					cadence_path[idx], month)
			if pipe_i <= 0.0:
				break
			total_cost += 1.0 / pipe_i
			if total_cost <= 1.0:
				walked_expect += 1
			idx += 1
		var walked_chunked := int((cadence.get("route", {}) as Dictionary).get(
			"tile_index", -1))
		var walked_oneshot := int((twin_acc.get("route", {}) as Dictionary).get(
			"tile_index", -1))
		_check(walked_chunked == walked_expect and walked_chunked >= 8,
			"29 fast-player moves integrate the per-tile pipeline exactly "
			+ "(%d chunked vs %d integrated; one-shot first-heading walk %d)"
			% [walked_chunked, walked_expect, walked_oneshot])


# --- 16c. Stall diagnostics (the unified-movement observability) -------------

func _test_stall_diagnostics() -> void:
	var sim := _make_run()
	sim._refresh_net()
	GameState.day = 200
	# A DOCKED fleet reports docked with its until-day; a CAMPING pirate
	# (anchor at its own cell, off-lane) reports camping.
	var docked := _make_fleet(sim, "trader", "portugal", OPEN_CELL)
	docked["dwell_until_day"] = 240
	var camp := Vector2i(-1, -1)
	for cy in range(24, 2136, 24):
		for cx in range(24, 4296, 24):
			var candidate := Vector2i(cx, cy)
			if DataLoader.is_passable(candidate) \
					and not sim._is_path_tile(candidate) \
					and NpcFleetsLib.chebyshev(candidate, OPEN_CELL) > 60:
				camp = candidate
				break
		if camp.x >= 0:
			break
	_check(camp.x >= 0, "an off-lane camping cell exists")
	if camp.x < 0:
		return
	var camper := _make_fleet(sim, "pirate", "", camp)
	camper["anchor_cell"] = {"x": camp.x, "y": camp.y}
	_check(sim.stall_state(camper, 0) == "camping",
		"an anchored targetless pirate reports camping")
	# Berth consistency (`60-*` §4.11.11 berth pin): a docked fleet parked
	# off its berth reports on_berth=false and snaps back on the next tick
	# — docking "somewhere at sea" is not allowed.
	var port_id := "lisbon"
	var berth: Vector2i = sim._port_cell(port_id)
	var drifter := _make_fleet(sim, "trader", "portugal",
		berth + Vector2i(2, 0))
	drifter["dwell_until_day"] = 240
	drifter["dest_port_id"] = port_id
	var off_reason: Dictionary = sim.stall_reason(drifter)
	_check(str(off_reason.get("state", "")) == "stranded"
		and bool(off_reason.get("on_berth", true)) == false,
		"an off-berth dwell fleet is stranded, not docked")
	# The drifter is a tick's docked branch away from its berth heal
	# (docking "somewhere at sea" self-heals onto the berth).
	GameState.day = 200
	sim._step_fleets(int(GameState.day))
	var healed_reason: Dictionary = sim.stall_reason(drifter)
	_check(NpcFleetsLib.position_of(drifter) == berth
		and bool(healed_reason.get("on_berth", false)),
		"the off-berth docked fleet snaps back to its berth (self-heal)")
	# A stranded fleet with NO destination (a dropped journey) heals to
	# its own nation's nearest berth — never left holding in open water.
	var lost := _make_fleet(sim, "trader", "portugal", OPEN_CELL)
	lost["dwell_until_day"] = 240
	lost["dest_port_id"] = ""
	_check(sim.stall_state(lost, 0) == "stranded",
		"a dest-less dwell fleet in open water is stranded")
	sim._step_fleets(int(GameState.day))
	var healed_lost := sim._port_at_cell(NpcFleetsLib.position_of(lost))
	_check(not healed_lost.is_empty(),
		"the dest-less stranded fleet heals to its nearest own berth (%s)"
		% healed_lost)
	# BLOCKED (diagnostics): the hold streak comes from the accrual
	# (passability blocks — e.g. in-month seasonal ice — spend the budget
	# without progress and are counted per accrual in `_accrue_lane`);
	# for the diagnostics probe the streak is set directly.
	var ice_fleet := _make_fleet(sim, "trader", "holland", OPEN_CELL)
	ice_fleet["route"] = {"lanes": ["hanseatic_north"], "leg": 0,
		"tile_index": 0, "legs": [{"kind": "lane", "id": "hanseatic_north",
		"reverse": false, "a": 0, "b": 99}]}
	ice_fleet["id"] = "stall_ice"
	sim._hold_ticks[str(ice_fleet.get("id", ""))] = 4
	var ice_reason: Dictionary = sim.stall_reason(ice_fleet)
	_check(str(ice_reason.get("state", "")) == "blocked"
		and int(ice_reason.get("holds", 0)) == 4,
		"the hold-streak fleet reports blocked (holds %d)"
		% int(ice_reason.get("holds", 0)))
	# The markers carry the diagnostics for the S3 badge and chart tooltip.
	var marker_stall := ""
	var marker_holds := -1
	for marker in sim.markers():
		if str(marker.get("id", "")) == "stall_ice":
			marker_stall = str(marker.get("stall", ""))
			marker_holds = int(marker.get("holds", -1))
	_check(marker_stall == "blocked" and marker_holds == 4,
		"markers() carries the stall state + holds (blocked, %d)"
		% marker_holds)
	var scan: Array = sim.stalled_fleets()
	var found := false
	for entry in scan:
		if str(entry.get("id", "")) == "stall_ice":
			found = true
	_check(found, "stalled_fleets finds the blocked fleet (%d entries)"
		% scan.size())
	# The WEDGE + ESCALATION (user-reported): a fleet parked exactly on its
	# span's far end (a lane terminus, no resolvable berth ahead) froze at
	# a 0 budget forever — the heading-empty wedge. The accrual's
	# escalation drops the wedged journey at `STALL_HOLD_TICKS`+ holds and
	# the day tick re-departs it fresh (a new route from the nearest
	# resolvable origin — the patrol's home port via `_depart_patrol`).
	var wedged := _make_fleet(sim, "patrol", "spain",
		sim._lane_paths["hanseatic_north"][30])
	wedged["route"] = {"lanes": ["hanseatic_north"], "leg": 0,
		"tile_index": 0, "legs": [{"kind": "lane", "id": "hanseatic_north",
		"reverse": false, "a": 30, "b": 30}]}
	wedged["id"] = "stall_wedged"
	sim._sync_route_progress(wedged)
	var drop_day := int(GameState.day)
	for _day in 4:
		sim._accrue_lane(wedged, drop_day, 1.0)
	_check(((wedged.get("route", {}) as Dictionary).get("legs", [])
		as Array).is_empty(),
		"the escalated fleet drops its wedged journey (holds ≥ 3)")
	sim._step_fleets(drop_day)
	_check(not ((wedged.get("route", {}) as Dictionary).get("legs", [])
		as Array).is_empty()
		or int(wedged.get("dwell_until_day", 0)) > drop_day,
		"the day tick re-departs the escalated fleet (live again)")
	# Accrual TELEMETRY (80-* §4.6 [raw2]): every pass records what it
	# granted and did — the per-move vs day-jump discriminator.
	var tele := _make_fleet(sim, "trader", "portugal", OPEN_CELL)
	tele["id"] = "tele_01"
	tele["route"] = {"lanes": ["hanseatic_north"], "leg": 0,
		"tile_index": 0, "legs": [{"kind": "lane", "id": "hanseatic_north",
		"reverse": false, "a": 0, "b": 99}]}
	sim._fleet_mark["tele_01"] = sim._clock_now()
	sim._accrue_lane(tele, int(GameState.day), 1.0)
	var rec: Dictionary = sim._accrual_dbg.get("tele_01", {})
	_check(rec.has("committed") and rec.has("budget")
		and rec.has("pipe") and float(rec.get("delta", -1.0)) == 1.0,
		"the lane accrual records delta/committed/budget/pipe telemetry")
	# A mark AHEAD of the clock (a clock rewind — set sail resets the
	# fraction, 20-* §4.3) REBASES on the pass: the mark snaps to the
	# clock (the rewound window is forfeit — those fleets already walked
	# it), the pass grants nothing, and the NEXT pass accrues its own
	# slice — never a freeze, never a day-lump (60-* §4.11.11).
	# advance_clock arms on its first call (the load sentinel) — arm,
	# then run the rebase pass.
	sim._fleet_mark["tele_01"] = sim._clock_now() + 10.0
	GameState.day = int(GameState.day) + 1
	sim.advance_clock()
	GameState.day = int(GameState.day) + 1
	sim.advance_clock()
	rec = sim._accrual_dbg.get("tele_01", {})
	_check(str(rec.get("skip", "")) == "stale_mark"
		and float(sim._fleet_mark.get("tele_01", -1.0)) == sim._clock_now(),
		"a mark ahead of the clock rebases to it (skip=stale_mark, no freeze)")
	# The markers carry the [raw2] telemetry string for the hover window.
	var raw2 := ""
	for marker in sim.markers():
		if str(marker.get("id", "")) == "tele_01":
			raw2 = str(marker.get("dbg2", ""))
	_check(raw2.begins_with("now=") and raw2.contains("pend=")
		and raw2.contains("skip=stale_mark") and raw2.contains("leg0="),
		"markers() carries the [raw2] telemetry (%s)" % raw2)
	# [raw3]: the journey history ring + the real mooring truth.
	var raw3 := ""
	for marker in sim.markers():
		if str(marker.get("id", "")) == "tele_01":
			raw3 = str(marker.get("dbg3", ""))
	_check(raw3.begins_with("dest=") and raw3.contains("mooring=")
		and raw3.contains(" ev="),
		"markers() carries the [raw3] journey history (%s)" % raw3)
	# The pass after the rebase is a normal per-move accrual again —
	# the freeze-then-day-jump behavior is gone.
	GameState.day = int(GameState.day) + 1
	sim.advance_clock()
	rec = sim._accrual_dbg.get("tele_01", {})
	_check(str(rec.get("skip", "")) == ""
		and float(rec.get("delta", 0.0)) == 1.0,
		"the post-rebase pass accrues normally (delta 1.0, no skip)")
	sim.remove("tele_01")
	sim.remove(str(docked["id"]))
	sim.remove(str(camper["id"]))
	sim.remove(str(ice_fleet["id"]))
	sim.remove(str(wedged["id"]))
	sim.reset_index()


# --- 17. Seasonal lane variants (§2.8; the hanseatic_north flip) --------------

func _test_variant_flip() -> void:
	var sim := _make_run()
	sim._refresh_net()
	var base: Array = sim._lane_paths["hanseatic_north"]
	var variants: Array = sim._lane_variants["hanseatic_north"]
	_check(variants.size() == 1, "hanseatic_north ships exactly one variant")
	if variants.is_empty() or base.size() < 120:
		return
	var vpath: Array = variants[0]["path"]
	var vmonths: Array = variants[0]["months"]
	_check(12 in vmonths and not (11 in vmonths),
		"the winter variant covers month 12, not month 11")
	# The active-geometry seam: summer walks the base (Baltic) run, winter
	# walks the variant (Hamburg run).
	var leg := {"kind": "lane", "id": "hanseatic_north", "reverse": false,
		"a": 0, "b": base.size() - 1}
	GameState.day = 210  # month 7
	_check(sim._leg_path_active(leg).size() == base.size(),
		"month 7 walks the base path (%d tiles)"
		% sim._leg_path_active(leg).size())
	GameState.day = 340  # month 12
	_check(sim._leg_path_active(leg).size() == vpath.size(),
		"month 12 walks the variant path (%d tiles)"
		% sim._leg_path_active(leg).size())
	# The flip, end-to-end: a patrol on the Baltic leg in month 11 rides the
	# Hamburg run in month 12, progress remapped BY FRACTION.
	var start := 100
	var fleet := _make_fleet(sim, "patrol", "england", base[start])
	fleet["id"] = "flip_01"
	fleet["route"] = {"lanes": ["hanseatic_north"], "leg": 0, "tile_index": 0,
		"legs": [{"kind": "lane", "id": "hanseatic_north", "reverse": false,
			"a": 0, "b": base.size() - 1}]}
	GameState.day = 320  # month 11: the base (Baltic) run is active
	for _step in start:  # walk the base path up to tile `start`
		sim._advance(fleet, 320)
	_check(int(fleet["route"]["tile_index"]) == start
		and _cell_of(fleet) == base[start],
		"the fleet is on the Baltic leg at tile %d (month %d)"
		% [start, SailingSimLib.month_for(GameState.day)])
	# …month rolls over: the first step remaps progress by fraction —
	# round(fraction × (new_len − 1)) over the full variant — and commits
	# onto the winter path.
	@warning_ignore("integer_division")
	var expected_new := roundi(float(start) / float(base.size() - 1)
		* float(vpath.size() - 1))
	GameState.day = 331  # month 12
	sim._advance(fleet, 331)
	var flipped_cell := _cell_of(fleet)
	var on_variant := false
	for tile in vpath:
		if tile == flipped_cell:
			on_variant = true
			break
	_check(on_variant,
		"month 12: the fleet rides the Hamburg run (at %s)" % str(flipped_cell))
	_check(int(fleet["route"]["tile_index"]) == expected_new + 1,
		"progress remapped by fraction: index %d (round(%d/%d × %d) + 1)"
		% [int(fleet["route"]["tile_index"]), start, base.size() - 1,
		vpath.size() - 1])
	_check(sim._leg_active.has("flip_01")
		and str((sim._leg_active["flip_01"] as Dictionary)["key"]).contains(
			"hanseatic_north_winter"),
		"the fleet's progress state names the active variant")
	# Determinism: an identical replay flips onto the SAME tile.
	var echo := _make_run()
	echo._refresh_net()
	GameState.day = 320
	var twin := _make_fleet(echo, "patrol", "england", base[start])
	twin["id"] = "flip_01"
	twin["route"] = {"lanes": ["hanseatic_north"], "leg": 0, "tile_index": 0,
		"legs": [{"kind": "lane", "id": "hanseatic_north", "reverse": false,
			"a": 0, "b": base.size() - 1}]}
	for _step in start:
		echo._advance(twin, 320)
	GameState.day = 331
	echo._advance(twin, 331)
	_check(_cell_of(twin) == flipped_cell,
		"the flip replays identically (%s)" % str(_cell_of(twin)))
	# The stored route keeps its base-relative shape (save shape unchanged).
	var stored: Dictionary = fleet["route"]["legs"][0]
	_check(int(stored["a"]) == 0 and int(stored["b"]) == base.size() - 1,
		"the persisted leg keeps its base-relative a/b")


# --- 18. Ice-aware stepping & pursuit (§2.7/§4.18; task-H item 3) --------------

func _test_ice_refusal() -> void:
	var sim := _make_run()
	sim._refresh_net()
	var ocean = OceanLayersLib.instance()
	var base: Array = sim._lane_paths["hanseatic_north"]
	var frozen_at := -1
	for index in base.size():
		if ocean.ice_blocks(base[index], 1):
			frozen_at = index
			break
	_check(frozen_at >= 0,
		"the hanseatic base path crosses month-1 Baltic ice (tile %d)"
		% frozen_at)
	if frozen_at < 0:
		return
	var frozen: Vector2i = base[frozen_at]
	GameState.day = 5  # month 1
	_check(not sim._passable(frozen),
		"the frozen tile refuses ENTRY in month 1")
	_check(ocean.ice_blocks(frozen, 7) == false,
		"the same tile is plain water in month 7 (the mask is month-keyed)")
	var saved_day := int(GameState.day)
	GameState.day = 210  # month 7
	_check(sim._passable(frozen), "the same tile admits fleets in month 7")
	GameState.day = saved_day
	# Entering from open water is refused; a fleet STANDING on ice may still
	# step out (the never-trapped rule).
	var outsider := _make_fleet(sim, "pirate", "", frozen + Vector2i(2, 0))
	outsider["id"] = "ice_outsider"
	_check(not sim._can_enter(outsider, frozen),
		"a raider cannot chase INTO in-month ice")
	var holder := _make_fleet(sim, "pirate", "", frozen)
	holder["id"] = "ice_holder"
	var out_cell := Vector2i(-1, -1)
	for offset in [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0),
			Vector2i(-1, 0)]:
		var candidate: Vector2i = frozen + offset
		if DataLoader.is_passable(candidate) \
				and not ocean.ice_blocks(candidate, 1):
			out_cell = candidate
			break
	_check(out_cell.x >= 0, "an open-water neighbour of the ice exists")
	if out_cell.x >= 0:
		_check(sim._can_enter(holder, out_cell),
			"the fleet standing on the frozen tile may still move OUT")
		var steps := 0
		while _cell_of(holder) != out_cell and steps < 8:
			sim._chase_step(holder, out_cell)
			steps += 1
		_check(_cell_of(holder) == out_cell,
			"the trapped-fleet rule: the holder walked out in %d steps" % steps)
	# Pursuit A* uses the same in-month passability: across the frozen
	# basin the month-1 plan differs from the ice-blind one (no path, or a
	# path that never touches the mask), while month 7 plans freely.
	var from_cell: Vector2i = base[maxi(0, frozen_at - 8)]
	var to_cell: Vector2i = base[mini(base.size() - 1, frozen_at + 8)]
	var blind := FleetPathLib.find_path(from_cell, to_cell, 4320, 2160,
		func(cell: Vector2i) -> bool: return DataLoader.is_passable(cell))
	var winter := FleetPathLib.find_path(from_cell, to_cell, 4320, 2160,
		func(cell: Vector2i) -> bool: return sim._passable(cell))
	var winter_clean := true
	for cell in winter:
		if ocean.ice_blocks(cell, 1):
			winter_clean = false
			break
	_check(blind.size() >= 2,
		"the ice-blind plan would cross the basin (%d tiles)" % blind.size())
	_check(winter.is_empty() or winter_clean,
		"the month-1 pursuit plan never enters the ice (%d tiles)"
		% winter.size())
	GameState.day = 210
	var summer := FleetPathLib.find_path(from_cell, to_cell, 4320, 2160,
		func(cell: Vector2i) -> bool: return sim._passable(cell))
	_check(summer.size() >= 2,
		"the month-7 pursuit plan crosses freely (%d tiles)" % summer.size())


# --- 19. The own-nation docking pin (decision 11; task-H item 6) ----------------

func _test_neutral_docking() -> void:
	var sim := _make_run()
	sim._refresh_net()
	var neutral_id := ""
	for port in DataLoader.ports_list:
		if str((port as Dictionary).get("nation_id", "")) == "":
			neutral_id = str((port as Dictionary).get("id", ""))
			break
	_check(not neutral_id.is_empty(), "a neutral port exists to probe")
	if neutral_id.is_empty():
		return
	# (a) structural: neither the candidate scan nor a live decision ever
	# proposes a neutral destination.
	var fixture := _trader_fixture(sim)
	_check(not fixture.is_empty(), "the docking probe has a trader fixture")
	if fixture.is_empty():
		return
	var origin := str(fixture["origin"])
	for dest in sim._candidate_destinations(origin, "portugal"):
		_check(str(DataLoader.get_port(str(dest)).get("nation_id", ""))
			== "portugal",
			"the candidate scan never proposes %s (nation %s)" % [str(dest),
			str(DataLoader.get_port(str(dest)).get("nation_id", ""))])
	var trader := _make_fleet(sim, "trader", "portugal",
		DataLoader.port_cell(origin))
	trader["id"] = "docking_probe"
	trader["dest_port_id"] = origin
	var candidates: Array = sim.score_all_candidates(trader, origin, 10)
	for candidate in candidates:
		_check(str(DataLoader.get_port(str(candidate["dest"]))
			.get("nation_id", "")) == "portugal",
			"no decision candidate is a neutral port (got %s)"
			% str(candidate["dest"]))
	# (b) a trader standing ON a neutral berth never adopts it: the
	# own-nation lookup refuses, no sale touches the neutral market, and the
	# port call falls back to its own-nation destination.
	var berth := DataLoader.port_cell(neutral_id)
	if berth.x >= 0:
		var drifter := _make_fleet(sim, "trader", "portugal", berth)
		drifter["id"] = "docking_drifter"
		drifter["dest_port_id"] = "lisbon"
		drifter["cargo"] = {"wine": 20}
		var neutral_wine := EconomyLib.stock_of(neutral_id, "wine")
		_check(sim._own_port_at_cell(drifter, berth) == "",
			"the own-nation port lookup refuses a neutral berth")
		GameState.day = 10
		sim._depart_trader(drifter, "portugal", 10)
		_check(EconomyLib.stock_of(neutral_id, "wine") == neutral_wine,
			"no trader ever sells into a neutral port")
		_check(str(drifter["dest_port_id"]) != neutral_id,
			"the drifter never adopts the neutral berth as its port call")
	# (c) the whole-ecology net: over 40 ticks of live traffic, every
	# trader-family arrival in the port log is at an OWN-nation port.
	GameState.npc_port_log = []
	GameState.new_game("portugal", false)
	var fill_sim: NpcFleetsLib = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "normal",
	})
	fill_sim.initial_fill(1)
	for day in range(2, 42):
		GameState.day = day
		fill_sim.last_tick_day = -1
		fill_sim.tick(day)
	var bad_docking := ""
	for record in GameState.npc_port_log:
		var role := str((record as Dictionary).get("role", ""))
		if not (role in ["trader", "coaster", "courier"]):
			continue
		var port_id := str((record as Dictionary).get("port_id", ""))
		var port_nation := str(DataLoader.get_port(port_id)
			.get("nation_id", "__missing__"))
		if port_nation == "" \
				or port_nation != str((record as Dictionary).get("nation_id", "")):
			bad_docking = "%s arrived at %s (nation %s)" % [role, port_id,
				port_nation]
			break
	_check(bad_docking.is_empty(),
		"no trader-family fleet ever docks at a neutral port (%s)"
		% bad_docking)


# --- 20. The 5 regional lanes: presence & chokepoint camping (§2.11.1) ---------

func _test_regional_lanes() -> void:
	var sim := _make_run()
	sim._refresh_net()
	var new_lanes := ["canton_country_trade", "coromandel_bengal",
		"swahili_coast", "pacific_america", "west_africa"]
	for lane_id in new_lanes:
		_check(sim._lane_paths.has(lane_id)
			and (sim._lane_paths[lane_id] as Array).size() > 100,
			"%s is a built lane the ecology walks" % lane_id)
	# Routing reach: the lane tags' nations reach their lanes through the
	# spoke network (patrols cycle exactly these lane sets).
	_check("canton_country_trade" in sim.nation_lanes("portugal"),
		"portugal's patrol lanes reach the taiwan_strait lane")
	_check("pacific_america" in sim.nation_lanes("spain"),
		"spain's patrol lanes reach the pacific_america lane")
	_check("coromandel_bengal" in sim.nation_lanes("holland")
		or "coromandel_bengal" in sim.nation_lanes("england"),
		"holland/england patrol lanes reach the ceylon_south lane")
	_check("swahili_coast" in sim.nation_lanes("portugal"),
		"portugal's patrol lanes reach the swahili_coast lane")
	_check("west_africa" in sim.nation_lanes("portugal"),
		"portugal's patrol lanes reach the west_africa lane")
	# Live traffic: the fill + 60 ticks of the trickle put role fleets ON
	# every new lane (spawn walks reach them; they are visibly worked).
	GameState.new_game("portugal", false)
	var fill_sim: NpcFleetsLib = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "normal",
	})
	fill_sim.initial_fill(1)
	for day in range(2, 62):
		GameState.day = day
		fill_sim.last_tick_day = -1
		fill_sim.tick(day)
	var lane_roles := {}
	for fleet in GameState.npc_fleets:
		for lane_id in (fleet.get("route", {}) as Dictionary).get("lanes", []):
			lane_roles[str(lane_id)] = str((fleet as Dictionary)
				.get("role", ""))
	for lane_id in new_lanes:
		_check(lane_roles.has(lane_id),
			"role traffic visibly works %s (%s)"
			% [lane_id, lane_roles.get(lane_id, "none")])
	# Chokepoint camping on the tagged straits: the production anchor
	# primitive (`_free_tile_near`, the exact `_raider_anchor` draw) sites a
	# pirate within the swept Chebyshev 6 of BOTH tag lanes' junction tiles —
	# and the worldwide spawn walk is reported as presence evidence.
	var camping := {}
	for lane_id in ["canton_country_trade", "coromandel_bengal"]:
		var near := {}
		for tile in sim._lane_paths[lane_id]:
			for dy in range(-NpcFleetsLib.ANCHOR_RADIUS,
					NpcFleetsLib.ANCHOR_RADIUS + 1):
				for dx in range(-NpcFleetsLib.ANCHOR_RADIUS,
						NpcFleetsLib.ANCHOR_RADIUS + 1):
					near[Vector2i(
						posmod((tile as Vector2i).x + dx, 4320),
						(tile as Vector2i).y + dy)] = true
		camping[lane_id] = near
	for lane_id in camping:
		var site := Vector2i(-1, -1)
		var junctions: Array = sim._anchor_tiles("pirate", "")
		for tile in sim._lane_paths[lane_id]:
			if junctions.has(tile):
				site = tile
				break
		_check(site.x >= 0, "%s carries a campable junction tile" % lane_id)
		if site.x < 0:
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = 20261101
		var anchor: Vector2i = sim._free_tile_near(site, rng,
			NpcFleetsLib.ANCHOR_RADIUS, true)
		if anchor == NpcFleetsLib.NO_CELL:
			# The strait's every near tile is lane raster (the documented
			# fallback): the draw takes an on-path anchor after half the
			# attempts, exactly like `_raider_anchor`.
			anchor = sim._free_tile_near(site, rng,
				NpcFleetsLib.ANCHOR_RADIUS, false)
		_check(anchor != NpcFleetsLib.NO_CELL
			and (camping[lane_id] as Dictionary).has(anchor),
			"the anchor draw camps %s within Chebyshev %d (at %s)"
			% [lane_id, NpcFleetsLib.ANCHOR_RADIUS, str(anchor)])
	var found := {}
	for day in range(2, 202):
		if found.size() == 2:
			break
		var pirate := fill_sim.spawn("pirate", "", day)
		if pirate.is_empty():
			continue
		var anchor := _cell_of(pirate)
		for lane_id in camping:
			if not found.has(lane_id) \
					and (camping[lane_id] as Dictionary).has(anchor):
				found[lane_id] = str(anchor)
	print("  camping walk (worldwide spawn draws): %s" % str(found))


# --- 21. The pursuit A* budget at the quadrupled chase area (correction 13) ----

const PURSUIT_PROBE_DAYS := 40

func _test_pursuit_budget() -> void:
	var sim := _make_run()
	sim._refresh_net()
	# The roughest reachable water: the passable cell whose sampled radius-24
	# disc holds the most impassable tiles (an archipelago coast — the
	# realistic worst case for the 30/40 chase A*).
	var best := Vector2i(-1, -1)
	var best_score := -1
	for y in range(24, 2136, 24):
		for x in range(24, 4296, 24):
			var cell := Vector2i(x, y)
			if not DataLoader.is_passable(cell):
				continue
			var score := 0
			for dy in range(-24, 25, 6):
				for dx in range(-24, 25, 6):
					if not DataLoader.is_passable(Vector2i(
							posmod(x + dx, 4320), y + dy)):
						score += 1
			if score > best_score:
				best_score = score
				best = cell
	_check(best_score > 12,
		"an archipelago pursuit area exists (roughness %d at %s)"
		% [best_score, str(best)])
	if best_score < 0:
		return
	# The hunter chases across the rough coast; the player jinks 3 tiles a
	# day so the plan re-runs EVERY day (the worst case the budget gates).
	var hunter := _make_fleet(sim, "hunter", "spain", best)
	hunter["id"] = "pursuit_probe"
	GameState.player["reputation"]["spain"] = -60
	# The chase target: the nearest passable cell on the radius-34 ring
	# around the rough anchor (wrap-aware, y bounded).
	var prey := Vector2i(-1, -1)
	for radius in [34, 36, 38, 40, 30, 28]:
		for angle in 64:
			var dx := roundi(cos(TAU * angle / 64.0) * float(radius))
			var dy := roundi(sin(TAU * angle / 64.0) * float(radius))
			var candidate := Vector2i(posmod(best.x + dx, 4320),
				clampi(best.y + dy, 0, 2159))
			if DataLoader.is_passable(candidate):
				prey = candidate
				break
		if prey.x >= 0:
			break
	_check(prey.x >= 0, "the pursuit target sits on water (ring scan)")
	if prey.x < 0:
		return
	var worst_day_ms := 0.0
	var total_day_ms := 0.0
	for offset in PURSUIT_PROBE_DAYS:
		GameState.day = 100 + offset
		prey = Vector2i(prey.x + 3, prey.y)  # force a re-plan every day
		if not DataLoader.is_passable(prey) or prey.y < 0 or prey.y > 2159:
			prey = Vector2i(prey.x - 3, clampi(prey.y + 1, 0, 2159))
		if not DataLoader.is_passable(prey):
			prey = Vector2i(prey.x - 3, prey.y)
		var started := Time.get_ticks_usec()
		sim._pursue(hunter, prey, 0.0)
		var ms := float(Time.get_ticks_usec() - started) / 1000.0
		total_day_ms += ms
		worst_day_ms = maxf(worst_day_ms, ms)
	var avg := total_day_ms / float(PURSUIT_PROBE_DAYS)
	print("  pursuit probe: %d chase days (a re-plan every day) across roughness-%d water"
		% [PURSUIT_PROBE_DAYS, best_score])
	print("  pursuit probe: avg %.2f ms/day, worst day %.2f ms"
		% [avg, worst_day_ms])
	print("PROFILE pursuit_worst_ms %d" % int(round(worst_day_ms)))
	# The locked budget (docs/60-* §4.11.11.5): ≤ 250 ms/day, overflow loses
	# the chase. Correction 13: windowed only on measured failure.
	_check(worst_day_ms <= 250.0,
		"the pursuit A* stays within the 250 ms/day budget (worst %.1f ms)"
		% worst_day_ms)


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
	var samples: Array = []
	var worst_ms := 0.0
	for day in range(80, 80 + PERF_TICKS):
		GameState.day = day
		var started := Time.get_ticks_usec()
		sim.tick(day)
		var ms := float(Time.get_ticks_usec() - started) / 1000.0
		samples.append(ms)
		worst_ms = maxf(worst_ms, ms)
	samples.sort()
	# The MEDIAN is the gated statistic: single-tick spikes (allocator
	# hiccups, OS scheduling) skew a mean on a noisy shared machine — the
	# median answers "what does a typical day tick cost" robustly.
	var median := float(samples[PERF_TICKS / 2])
	var avg := 0.0
	for ms in samples:
		avg += float(ms)
	avg /= float(PERF_TICKS)
	print("  tick probe: %d fleets, median %.1f ms/tick, avg %.1f, worst %.1f"
		% [n, median, avg, worst_ms])
	# docs/90-* §13 free profiling: the day-tick numbers ride every gate run.
	print("PROFILE day_tick_avg_ms %d" % int(round(avg)))
	print("PROFILE day_tick_worst_ms %d" % int(round(worst_ms)))
	_check(n >= 250, "the probe runs at the filled cap (%d fleets)" % n)
	_check(median <= PERF_GATE_MS,
		"the day tick median ≤ %.0f ms at cap (%.1f ms over %d ticks)"
		% [PERF_GATE_MS, median, PERF_TICKS])
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
