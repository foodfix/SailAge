extends Node
## Phase-4 task M — circumnavigation & chokepoint E2E
## (docs/IMPLEMENT-Phase4.md M; docs/20-WORLD-AND-SAILING.md §4.1, §4.2, §4.4,
## §4.7; the locked constants table of `IMPLEMENT-Phase4.md`; docs/90-* §9).
##
##   godot --headless --path . tools/test_world_e2e.tscn
##
## Four scripted voyages, each **sailed for real** through the shipping
## movement path (`WorldMap.try_step()`, the call the arrow keys and the
## click-to-sail walker make): one normal move per tile with the per-step
## clock, consumption, weather and port-entry rules. The only teleports are the
## ones the task explicitly allows — placing the fleet for each separate voyage,
## one assist across the Americas in leg 4, and leg 4's mid-Pacific provisioning
## stops, which return to the exact cell they left. A teleport never stands in
## for a sailed segment, and every one is asserted.
##
##   1. Lisbon → the water off Santa Cruz de Tenerife (28.3°N 16.5°W — a
##      **coordinate** destination: the 100-port list has no Canaries port),
##      crossing the 30°N band edge into the trade winds; plus the T8 storm
##      gate (storm within 6 in-band days ≥ 0.90).
##   2. Lisbon → Istanbul through the **carved** Dardanelles + Bosphorus,
##      proved to be the override in play (fill the carved cells in and the
##      route disappears).
##   3. Lisbon → Nagasaki the long way: round the Cape of Good Hope, through
##      Malacca, never entering the polar ice (the wall that forbids the
##      north-west passage).
##   4. A westward circumnavigation back to Lisbon, crossing the x = 0 /
##      x = 2159 seam both ways.
##
## Every leg asserts the exact arrival tile, a day count inside an envelope
## derived from the distance and the hull's speed range (§4.4), no game over,
## supplies never at zero, and that no step ever landed on `#` / `^` / `I`.
##
## Exits 0 when every check passes, 1 otherwise. Prints the suite count, the
## check count and the leg summary table (task N records them).

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const SailPathLib := preload("res://scripts/world/sail_path.gd")
const TradeLib := preload("res://scripts/port/trade_engine.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")
const InnLib := preload("res://scripts/port/inn_engine.gd")
const TavernLib := preload("res://scripts/port/tavern_engine.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")

# --- Locked grid (docs/10-* §6.1, docs/IMPLEMENT-Phase4.md constants) ------

const WORLD_WIDTH := 2160
const WORLD_HEIGHT := 1080
const TILES_PER_DEGREE := 6.0

# --- Leg 1: the re-anchored demo-loop storm step (§4.7, task B) ------------

## Santa Cruz de Tenerife — the **coordinate** destination (no port exists).
const TENERIFE_LAT := 28.3
const TENERIFE_LON := -16.5
## `floor((lon+180)*6), floor((90-lat)*6)` — the tile the coordinate lands in.
## It is land (Tenerife itself), so the voyage's arrival is the §6.1 harbour
## snap of that coordinate: the nearest water tile within Chebyshev 2, tie-break
## smallest (distance, y, x), with ≥ 1 orthogonally adjacent water tile.
const TENERIFE_CELL := Vector2i(981, 370)
const TENERIFE_WATER := Vector2i(980, 369)

## docs/20-* §4.7 T8 methodology: 10,000 seeded 6-day windows in the band.
const WEATHER_SEED := 20261031
const STORM_WINDOWS := 10000
const STORM_WINDOW_DAYS := 6
## The scripted gate: "storm within 6 day ticks in-band ≥ 0.90".
const STORM_GATE := 0.90

# --- Voyage fixture (docs/40-* §4.1/§4.2, docs/20-* §4.4) -----------------

## `brigantine`: speed 12 tiles/day (the ×2 Phase-4 rescale), capacity 150,
## durability 110. Five hulls pool a 750-unit hold, so an ocean leg is sailed
## on one provisioning stop (the stops stay in the route instead of being cut).
const SHIP_ID := "brigantine"
const SHIP_COUNT := 5
const FIXTURE_GOLD := 100000000
## §4.4 speed range for this hull at seamanship 10 (factor 1.0) and full crew:
##   calm  12 × 0.80 = 9.6  → floor = 9 tiles/day   (the slowest possible)
##   storm 12 × 1.50 = 18.0 → floor = 18 tiles/day  (the fastest possible)
## so `steps` tiles take between `steps / 18` and `steps / 9` sea days. That
## is the envelope every leg asserts, plus its deliberate in-port days.
const MIN_SPEED := 9
const MAX_SPEED := 18
## Every leg is re-seeded so a rerun is byte-identical (one base + leg index).
const LEG_SEEDS: Array[int] = [WEATHER_SEED + 1, WEATHER_SEED + 2,
	WEATHER_SEED + 3, WEATHER_SEED + 4]
## Hostile spawns are combat's proof, not movement's: park both §4.11.11 spawn
## immunities far in the future — a real save field — so no random pirate/navy
## contact can replace the movement proof with a battle.
const NO_SPAWNS_UNTIL := 999999

var _failures: Array[String] = []
var _checks := 0
## Summary-table rows: `{leg, steps, days, lo, hi, start, goal, ok}`.
var _rows: Array = []
var world = null
## `{port_id: Vector2i}` derived from `lat`/`lon` through the loader.
var _ports: Dictionary = {}
## Lowest supplies observed while under way (the "never hit zero" proof).
var _min_provisions := 0
var _min_water := 0


func _ready() -> void:
	var started := Time.get_ticks_msec()
	_ensure_map()
	var map = DataLoader.map
	_check(map != null and map.width == WORLD_WIDTH and map.height == WORLD_HEIGHT,
		"the world map loads: %d×%d tiles" % [
			map.width if map != null else -1, map.height if map != null else -1])
	_index_ports()
	_build_fixture()
	await _spawn_world()
	_test_fixture_arithmetic()
	_test_storm_gate()
	_test_leg1()
	_test_leg2()
	_test_leg3()
	_test_leg4()
	_report(started)


# --- Fixtures --------------------------------------------------------------

func _ensure_map() -> void:
	if DataLoader.map == null:
		var loader = MapLoaderLib.new()
		loader.load_map("res://data/maps/world.png", DataLoader.map_legend)
		DataLoader.map = loader


## Every port's harbour tile, derived from `lat`/`lon` through the loader's
## §6.1 implementation (the same rule the builder uses).
func _index_ports() -> void:
	for port_id in DataLoader.map.harbor_tiles():
		_ports[str(port_id)] = DataLoader.map.port_cell(str(port_id))


## A port's derived harbour tile (`(-1,-1)` when the id is unknown).
func _port(port_id: String) -> Vector2i:
	var value = _ports.get(port_id, null)
	return value if value is Vector2i else Vector2i(-1, -1)


## A run that can actually cross an ocean: five brigantines at full crew, an
## empty hold, default stats (luck 10 — the §4.7 gate's own luck) and the two
## spawn immunities parked. Everything else is ordinary `GameState` state.
func _build_fixture() -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10},
		"xp": 0, "level": 1, "officers": [],
		"reputation": {"portugal": 0, "spain": 0, "england": 0, "holland": 0,
			"ottoman": 0, "italy": 0},
	}
	GameState.fleet = []
	for _index in SHIP_COUNT:
		var ship_type: Dictionary = DataLoader.get_ship_type(SHIP_ID)
		var ship: Dictionary = FleetLib.new_ship(SHIP_ID,
			int(ship_type.get("crew_min", 0)))
		GameState.fleet.append(ship)
	GameState.day = 1
	GameState.gold = FIXTURE_GOLD
	GameState.morale = 70
	GameState.current_port = null
	GameState.known_ports = []
	GameState.explored_tiles = {}
	GameState.npc_fleets = []
	GameState.proximity_cooldowns = {"pirate": NO_SPAWNS_UNTIL,
		"navy": NO_SPAWNS_UNTIL}
	var start := _port("lisbon")
	GameState.world = {
		"position": {"x": start.x, "y": start.y},
		"clock_fraction": 0.0, "weather": "fair",
	}
	SailingSimLib.reset_ledger_state()


func _spawn_world() -> void:
	var host := Node2D.new()
	host.name = "VoyageHost"
	add_child(host)
	world = WorldScene.instantiate()
	# Headless suite: entering a port still runs the whole §4.11 sequence
	# (discovery, desertion, dialog queue, `current_port`) but never swaps the
	# test's scene root.
	world.route_to_port = false
	world.route_to_battle = false
	host.add_child(world)
	await get_tree().process_frame


# --- Coordinate helpers (locked addressing, docs/10-* §6.1) ----------------

func _cell_at(lat: float, lon: float) -> Vector2i:
	return Vector2i(
		posmod(int(floor((lon + 180.0) * TILES_PER_DEGREE)), WORLD_WIDTH),
		int(floor((90.0 - lat) * TILES_PER_DEGREE))
	)


func _lat_at(cell: Vector2i) -> float:
	return 90.0 - float(cell.y) / TILES_PER_DEGREE


# --- Fixture arithmetic (§4.4 speed, §4.7 bands) ---------------------------

func _test_fixture_arithmetic() -> void:
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	GameState.world["weather"] = "fair"
	_check(SailingSimLib.effective_speed() == 12,
		"five brigantines at fair weather sail 12 tiles/day (got %d)"
		% SailingSimLib.effective_speed())
	GameState.world["weather"] = "calm"
	_check(SailingSimLib.effective_speed() == MIN_SPEED,
		"calm weather floors the fleet to %d tiles/day (got %d)"
		% [MIN_SPEED, SailingSimLib.effective_speed()])
	GameState.world["weather"] = "storm"
	_check(SailingSimLib.effective_speed() == MAX_SPEED,
		"a storm pushes the fleet to %d tiles/day (got %d)"
		% [MAX_SPEED, SailingSimLib.effective_speed()])
	GameState.world["weather"] = "fair"
	_check(is_equal_approx(CharacterLib.storm_chance_multiplier(), 0.975),
		"luck 10 scales the storm chance by 1 − 10/400 = 0.975 (got %.4f)"
		% CharacterLib.storm_chance_multiplier())

	# The coordinate destination, from the same floor projection.
	_check(_cell_at(TENERIFE_LAT, TENERIFE_LON) == TENERIFE_CELL,
		"28.3°N 16.5°W projects to %s (got %s)" % [
			str(TENERIFE_CELL), str(_cell_at(TENERIFE_LAT, TENERIFE_LON))])
	_check(not DataLoader.map.is_passable(TENERIFE_CELL),
		"%s is land — Tenerife itself — so the voyage stops in its water"
		% str(TENERIFE_CELL))
	_check(DataLoader.map.snap_harbor(TENERIFE_LAT, TENERIFE_LON) == TENERIFE_WATER,
		"the §6.1 water snap of the coordinate is %s (got %s)" % [
			str(TENERIFE_WATER),
			str(DataLoader.map.snap_harbor(TENERIFE_LAT, TENERIFE_LON))])
	_check(SailingSimLib.weather_zone_for(_port("lisbon")) == "variables",
		"Lisbon (%.2f°N) sits in the variables band (got %s)" % [
			_lat_at(_port("lisbon")),
			SailingSimLib.weather_zone_for(_port("lisbon"))])
	_check(SailingSimLib.weather_zone_for(TENERIFE_WATER) == "trade_winds",
		"the Tenerife water (%.2f°N) is in the trade winds (got %s)" % [
			_lat_at(TENERIFE_WATER),
			SailingSimLib.weather_zone_for(TENERIFE_WATER)])


# --- The T8 storm gate (§4.7) ----------------------------------------------

## "Storm within 6 day ticks in-band ≥ 0.90" by the T8 methodology: the closed
## form first, then 10,000 seeded 6-day windows rolled at the arrival tile.
##
## Arithmetic: the trade-wind base storm chance is 0.35 and luck 10 scales it
## by (1 − 10/400) = 0.975, so p = 0.34125 per day and
## P(≥ 1 storm in 6 days) = 1 − (1 − 0.34125)⁶ = 0.9183, against the 0.90 gate
## (the no-luck form 1 − 0.65⁶ = 0.9246 clears it too).
func _test_storm_gate() -> void:
	var p := 0.35 * CharacterLib.storm_chance_multiplier()
	var closed := 1.0 - pow(1.0 - p, STORM_WINDOW_DAYS)
	_check(is_equal_approx(p, 0.34125),
		"p = 0.35 × 0.975 = 0.34125 per in-band day (got %.6f)" % p)
	_check(absf(closed - 0.9183) < 0.0006,
		"1 − (1 − 0.34125)^6 = 0.9183 to 4 dp (got %.6f)" % closed)
	_check(closed >= STORM_GATE,
		"the closed form clears the ≥ 0.90 / 6-day gate (%.4f)" % closed)

	var started := Time.get_ticks_msec()
	SailingSimLib.set_weather_seed(WEATHER_SEED)
	var hits := 0
	for _window in STORM_WINDOWS:
		var stormed := false
		for _day in STORM_WINDOW_DAYS:
			if SailingSimLib.roll_weather(TENERIFE_WATER) == "storm":
				stormed = true
		if stormed:
			hits += 1
	var rate := float(hits) / float(STORM_WINDOWS)
	_check(rate >= STORM_GATE,
		"empirical P(storm within %d days in-band) ≥ 0.90 (got %.4f, %d ms)"
		% [STORM_WINDOW_DAYS, rate, Time.get_ticks_msec() - started])
	_check(absf(rate - closed) <= 0.02,
		"the seeded rate tracks the closed form ±0.02 (%.4f vs %.4f)"
		% [rate, closed])
	print("NOTE  storm gate: %d seeded %d-day windows in the trade belt → %.4f (closed form %.4f)"
		% [STORM_WINDOWS, STORM_WINDOW_DAYS, rate, closed])


# --- Leg 1: Lisbon → the water off Tenerife --------------------------------

func _test_leg1() -> void:
	_begin_leg(LEG_SEEDS[0])
	_teleport(_port("lisbon"))
	var acc := _new_leg("leg1", _port("lisbon"))
	acc["port_days"] = int(acc["port_days"]) + _provision("lisbon")
	var ok := _sail(acc, TENERIFE_WATER)
	_end_leg(acc, TENERIFE_WATER)

	_check(ok, "leg 1: the fleet sailed Lisbon → the Tenerife water")
	_check(Vector2i(acc["cell"]) == TENERIFE_WATER,
		"leg 1: arrival is exactly %s (got %s)"
		% [str(TENERIFE_WATER), str(acc["cell"])])
	_check(DataLoader.map.port_id_at(Vector2i(acc["cell"])).is_empty(),
		"leg 1: arrival is open water, not a berth (no Canaries port exists)")
	_check(DataLoader.map.shore_port_at(Vector2i(acc["cell"])).is_empty(),
		"leg 1: arrival is not a port's shore tile either")

	# The band edge: variables → trade_winds, crossed exactly once.
	var zones: Array = acc["zones"]
	var transitions: Array = []
	for index in range(1, zones.size()):
		if zones[index] != zones[index - 1]:
			transitions.append([zones[index - 1], zones[index]])
	_check(transitions.size() == 1,
		"leg 1: the voyage changes weather band exactly once (got %s)"
		% str(transitions))
	if transitions.size() == 1:
		_check(transitions[0] == ["variables", "trade_winds"],
			"leg 1: that single change is variables → trade_winds (got %s)"
			% str(transitions[0]))
	_check(zones[0] == "variables" and zones[zones.size() - 1] == "trade_winds",
		"leg 1: start band variables, arrival band trade_winds (got %s → %s)" % [
			str(zones[0]), str(zones[zones.size() - 1])])
	var edge: Vector2i = acc["edge_cell"]
	_check(_lat_at(edge) <= 30.0 and _lat_at(edge) > 29.8,
		"leg 1: the edge was crossed at %.3f°N, i.e. on the locked 30°N line"
		% _lat_at(edge))
	# The arrival tile is in the trade band, and the demo gate's storm rate was
	# measured there (asserted in _test_storm_gate).
	_check(SailingSimLib.weather_zone_for(Vector2i(acc["cell"])) == "trade_winds",
		"leg 1: the arrival tile samples the trade-wind band (got %s)"
		% SailingSimLib.weather_zone_for(Vector2i(acc["cell"])))


# --- Leg 2: Lisbon → Istanbul through the carved straits -------------------

func _test_leg2() -> void:
	_begin_leg(LEG_SEEDS[1])
	_teleport(_port("lisbon"))
	var acc := _new_leg("leg2", _port("lisbon"))
	acc["port_days"] = int(acc["port_days"]) + _provision("lisbon")
	var ok := _sail(acc, _port("istanbul"))
	_end_leg(acc, _port("istanbul"))

	_check(ok, "leg 2: the fleet sailed Lisbon → Istanbul")
	_check(Vector2i(acc["cell"]) == _port("istanbul"),
		"leg 2: arrival is Istanbul's berth tile %s (got %s)"
		% [str(_port("istanbul")), str(acc["cell"])])
	_check(GameState.current_port == "istanbul",
		"leg 2: heading into the shore tile docked at Istanbul (got %s)"
		% str(GameState.current_port))
	_check(Vector2i(world.fleet_cell()) == _port("istanbul"),
		"leg 2: docking leaves the fleet on the berth %s (got %s)"
		% [str(_port("istanbul")), str(world.fleet_cell())])

	# The carved channels, derived from `tools/map_overrides.json` with the
	# same projection and the same 1/20-tile walk the builder uses.
	var bosphorus := _channel_cells("bosphorus")
	var dardanelles := _channel_cells("dardanelles")
	_check(bosphorus.size() == 3 and dardanelles.size() == 8,
		"the bosphorus/dardanelles polylines map to 3 and 8 tiles (got %d/%d)"
		% [bosphorus.size(), dardanelles.size()])
	for name in ["bosphorus", "dardanelles"]:
		var cells: Array = _channel_cells(str(name))
		var dry := 0
		for cell in cells:
			if not DataLoader.map.is_passable(Vector2i(cell)):
				dry += 1
		_check(dry == 0,
			"every %s channel tile is water on the shipped map (%d land)"
			% [str(name), dry])
	var bos_hits := _count_hits(acc["tiles"], bosphorus)
	var dar_hits := _count_hits(acc["tiles"], dardanelles)
	_check(bos_hits == 3,
		"leg 2: the sailed path runs through all 3 Bosphorus tiles (got %d)"
		% bos_hits)
	_check(dar_hits >= 6,
		"leg 2: the sailed path runs through the Dardanelles (%d of 8 tiles)"
		% dar_hits)
	print("NOTE  leg 2: %d/3 Bosphorus and %d/8 Dardanelles tiles in the sailed path"
		% [bos_hits, dar_hits])

	# Proof it is the override in play, not a route around it: fill the carved
	# tiles in — on a **copy** of the world, never the live loader — and the
	# same query has no answer at all.
	var blocked = _map_with_land(bosphorus + dardanelles)
	var sail := SailPathLib.new()
	var detour: Array[Vector2i] = sail.find_path(
		_port("lisbon"), _port("istanbul"), blocked)
	_check(detour.is_empty(),
		"leg 2: with the carved cells filled in, Lisbon → Istanbul has no sea route (%d steps, %s)"
		% [detour.size(), sail.last_stage])
	_check(SailPathLib.new().find_path(
		_port("lisbon"), _port("istanbul"), DataLoader.map).size() > 0,
		"leg 2: …and on the shipped map the same query is routable")


# --- Leg 3: Lisbon → Nagasaki the long way ---------------------------------

func _test_leg3() -> void:
	var goal := _port("nagasaki")
	_begin_leg(LEG_SEEDS[2])
	_teleport(_port("lisbon"))
	var acc := _new_leg("leg3", _port("lisbon"))
	acc["port_days"] = int(acc["port_days"]) + _provision("lisbon")
	var ok := _sail(acc, _port("cape_town"))
	if ok:
		acc["port_days"] = int(acc["port_days"]) + _provision("cape_town")
		ok = _sail(acc, _port("malacca"))
	if ok:
		acc["port_days"] = int(acc["port_days"]) + _provision("malacca")
		ok = _sail(acc, goal)
	_end_leg(acc, goal)

	_check(ok, "leg 3: the fleet sailed Lisbon → Nagasaki the long way")
	_check(Vector2i(acc["cell"]) == goal,
		"leg 3: arrival is Nagasaki's harbour tile %s (got %s)"
		% [str(goal), str(acc["cell"])])

	# Rounding the Cape: some tile south of 30°S on the way out.
	var cape_lat := 90.0
	for cell in acc["tiles"]:
		cape_lat = minf(cape_lat, _lat_at(Vector2i(cell)))
	_check(cape_lat < -30.0,
		"leg 3: the voyage rounds the Cape of Good Hope (min lat %.2f°S)"
		% absf(cape_lat))

	# Malacca's channel cells from the override, physically sailed through. A
	# strait is a gate, not a corridor, so a handful of the 62 channel tiles is
	# the expected shape; zero would mean the fleet went round Malaysia through
	# Sunda instead.
	var malacca := _channel_cells("malacca")
	_check(malacca.size() == 62,
		"the Malacca polyline maps to 62 tiles (got %d)" % malacca.size())
	var hits := _count_hits(acc["tiles"], malacca)
	_check(hits >= 5,
		"leg 3: the sailed path passes through Malacca's channel (%d of %d tiles)"
		% [hits, malacca.size()])
	print("NOTE  leg 3: %d/%d Malacca channel tiles in the sailed path"
		% [hits, malacca.size()])

	# The ice wall: a hypothetical NW/NE passage runs above 70°N, so any ice-band
	# tile in the route would be that (impossible) shortcut. Every tile must be
	# south of 70°N and north of 60°S.
	var north := -90.0
	var south := 90.0
	var icy := 0
	for cell in acc["tiles"]:
		var lat := _lat_at(Vector2i(cell))
		north = maxf(north, lat)
		south = minf(south, lat)
		if lat >= 70.0 or lat <= -60.0:
			icy += 1
	_check(icy == 0,
		"leg 3: no tile is in the ice band, so no NW/NE passage was used (%d)"
		% icy)
	_check(north < 70.0 and south > -60.0,
		"leg 3: every tile is between −60° and 70° (sailed %.2f°S … %.2f°N)"
		% [absf(south), north])
	# The Indian Ocean is on the route: south of the equator, east of the Cape,
	# west of Malacca.
	var indian := 0
	for cell in acc["tiles"]:
		var tile := Vector2i(cell)
		var lat := _lat_at(tile)
		var lon := float(tile.x) / TILES_PER_DEGREE - 180.0
		if lat < 0.0 and lon > 40.0 and lon < 100.0:
			indian += 1
	_check(indian >= 100,
		"leg 3: the route crosses the Indian Ocean (%d tiles south of the equator, 40–100°E)"
		% indian)


# --- Leg 4: the westward circumnavigation ----------------------------------

## Lisbon → Cartagena → (Pacific) → Manila → Macassar → Colombo → Cape Town →
## Lisbon. Every segment is a real `try_step()` walk. The only teleports are
## the ones the task allows: one assist across the Americas (Acapulco), and two
## mid-Pacific provisioning stops that teleport to Manila and **return to the
## exact cell they left** — recorded and asserted, so a provisioning stop can
## never hide a sailed segment.
func _test_leg4() -> void:
	var lisbon := _port("lisbon")
	var day0: int = GameState.day
	_begin_leg(LEG_SEEDS[3])
	_teleport(lisbon)
	var acc := _new_leg("leg4", lisbon)
	acc["port_days"] = int(acc["port_days"]) + _provision("lisbon")
	var ok := true

	# 1. Westward across the Atlantic.
	ok = _sail(acc, _port("cartagena")) and ok
	_check(ok, "leg 4: segment 1 (Lisbon → Cartagena) sailed")
	_check(GameState.current_port == "cartagena",
		"leg 4: segment 1 docked at Cartagena (got %s)"
		% str(GameState.current_port))
	acc["port_days"] = int(acc["port_days"]) + _provision("cartagena")

	# 2. Allowed teleport-assist across the Americas: re-sailing the Atlantic and
	#    rounding Cape Horn again would only repeat leg 3's geometry.
	if ok:
		_hop(acc, "acapulco")

	# 3. Acapulco → the equatorial Pacific approach, then a real tack across the
	#    seam and back: west across x = 0 → 2159, east across x = 2159 → 0, and
	#    west again on the way to Manila. Two mid-Pacific provisioning stops are
	#    round trips that return to the exact cell they left.
	var approach := _dateline_approach()
	ok = _sail(acc, approach)
	if ok:
		_resupply(acc, "manila")
		ok = _sail(acc, Vector2i(WORLD_WIDTH - 10, approach.y))
	if ok:
		ok = _sail(acc, Vector2i(10, approach.y))
	if ok:
		_resupply(acc, "manila")
		ok = _sail(acc, _port("manila"))
	_check(ok, "leg 4: segment 2 (Acapulco → Manila) sailed across the Pacific")
	if ok:
		acc["port_days"] = int(acc["port_days"]) + _provision("manila")

	# 4. Manila → Macassar → Colombo → Cape Town → home.
	if ok:
		ok = _sail(acc, _port("macassar"))
	if ok:
		acc["port_days"] = int(acc["port_days"]) + _provision("macassar")
		ok = _sail(acc, _port("colombo"))
	if ok:
		acc["port_days"] = int(acc["port_days"]) + _provision("colombo")
		ok = _sail(acc, _port("cape_town"))
	if ok:
		acc["port_days"] = int(acc["port_days"]) + _provision("cape_town")
		ok = _sail(acc, lisbon)
	_end_leg(acc, lisbon)

	_check(ok, "leg 4: every sailed segment of the circumnavigation completed")
	_check(Vector2i(acc["cell"]) == lisbon,
		"leg 4: the final tile is the start tile %s (got %s)"
		% [str(lisbon), str(acc["cell"])])
	_check(GameState.current_port == "lisbon",
		"leg 4: the voyage ends docked at Lisbon (got %s)"
		% str(GameState.current_port))

	# Wrap, both ways: a westward crossing leaves x = 0 for x = 2159, an
	# eastward crossing leaves x = 2159 for x = 0.
	var west: Array = acc["cross_west"]
	var east: Array = acc["cross_east"]
	print("NOTE  leg 4: westward seam steps (x=0 → x=2159): %s" % str(west))
	print("NOTE  leg 4: eastward seam steps (x=2159 → x=0): %s" % str(east))
	_check(west.size() >= 1,
		"leg 4: the route crosses x = 0 → x = 2159 at least once (%d, at steps %s)"
		% [west.size(), str(west)])
	_check(east.size() >= 1,
		"leg 4: the route crosses x = 2159 → x = 0 at least once (%d, at steps %s)"
		% [east.size(), str(east)])
	_check(int(acc["net_dx"]) <= -1080,
		"leg 4: the sailed legs net %d columns westward (over half the world)"
		% int(acc["net_dx"]))

	_check(GameState.day > day0,
		"leg 4: the clock advanced over the circumnavigation (day %d → %d)"
		% [day0, GameState.day])
	_check(not SailingSimLib.is_game_over(),
		"leg 4: the fleet survived the whole trip")
	_check(_min_provisions > 0 and _min_water > 0,
		"leg 4: provisions/water never reached 0 while under way (min %d/%d)"
		% [_min_provisions, _min_water])
	# "Stayed at sea": every port the fleet touched is one the script named.
	var planned := ["lisbon", "cartagena", "manila", "macassar", "colombo",
		"cape_town"]
	var unplanned: Array = []
	for stop in acc["stops"]:
		if not planned.has(str(stop)):
			unplanned.append(str(stop))
	_check(unplanned.is_empty(),
		"leg 4: no unplanned docking (unexpected stops: %s)" % str(unplanned))
	# The provisioning stops really were round trips: each returned to the cell
	# it left. (The two between-leg assists are one-way by design and are
	# checked to land on their own harbour instead.)
	var round_trips := 0
	var bad_hops: Array = []
	for hop in acc["hops"]:
		if not bool(hop.get("round_trip", false)):
			continue
		round_trips += 1
		if Vector2i(hop["back"]) != Vector2i(hop["from"]):
			bad_hops.append(hop)
	_check(round_trips >= 2 and bad_hops.is_empty(),
		"leg 4: each mid-Pacific provisioning stop returned to the cell it left (%d stops, %d wrong)"
		% [round_trips, bad_hops.size()])


## The dateline-approach cell on the Pacific equatorial route (lat ≈ 4°N).
func _dateline_approach() -> Vector2i:
	return Vector2i(180, 516)


# --- The voyage engine -----------------------------------------------------

## Reseeds **both** ledger streams for a leg — the weather roll and the
## §4.8.3 mutiny draw, which moves morale and therefore the in-port rest days —
## so a rerun is byte-identical, however often the crew comes close to mutiny.
func _begin_leg(seed_value: int) -> void:
	SailingSimLib.set_weather_seed(seed_value)
	SailingSimLib.set_mutiny_seed(seed_value)
	SailingSimLib.reset_ledger_state()
	_min_provisions = 999999
	_min_water = 999999
	_check(not SailingSimLib.is_game_over(),
		"the run is alive before the leg starts")


func _new_leg(label: String, start: Vector2i) -> Dictionary:
	return {
		"label": label, "cell": start, "start": start,
		"steps": 0, "days": 0, "port_days": 0,
		"tiles": [], "zones": [], "edge_cell": start,
		"cross_west": [], "cross_east": [],
		"net_dx": 0, "stops": [], "hops": [],
	}


## Sails one segment: the A* route (§4.2 click-to-sail) then a step-by-step
## walk through `WorldMap.try_step()`, i.e. the shipping movement path. Returns
## true when the fleet stands on `goal`.
func _sail(acc: Dictionary, goal: Vector2i) -> bool:
	# The fleet cell is the source of truth: a provisioning hop above may have
	# moved it without sailing.
	var from: Vector2i = world.fleet_cell()
	acc["cell"] = from
	if from == goal:
		# Already there (a provisioning hop returned to the exact cell): still
		# apply the harbor-pair docking gesture if the goal is a port's berth.
		if GameState.current_port == null:
			_dock_if_at_berth(acc, from)
		if GameState.current_port != null:
			(acc["stops"] as Array).append(str(GameState.current_port))
		return true
	var sail := SailPathLib.new()
	var path: Array[Vector2i] = sail.find_path(from, goal, DataLoader.map)
	if path.is_empty():
		_check(false, "%s: no sea route %s → %s (%s)" % [
			str(acc["label"]), str(from), str(goal), sail.last_stage])
		return false
	var tiles: Array = acc["tiles"]
	var zones: Array = acc["zones"]
	if tiles.is_empty():
		tiles.append(from)
		zones.append(SailingSimLib.weather_zone_for(from))
	var day0: int = GameState.day
	var steps := int(acc["steps"])
	var cursor := from
	for cell in path:
		var moved: bool = world.try_step(cell)
		var guard := 0
		while not moved and guard < 6:
			if not _dismiss_modals():
				break
			moved = world.try_step(cell)
			guard += 1
		if not moved:
			_check(false, "%s: step %s → %s was rejected (supplies %d/%d, day %d)"
				% [str(acc["label"]), str(cursor), str(cell),
					FleetLib.supplies("provisions"), FleetLib.supplies("water"),
					GameState.day])
			return false
		# Legality (§4.1/§4.2): every visited tile is water and every step is a
		# legal 8-directional move with no corner cut.
		if not DataLoader.map.is_passable(cell):
			_check(false, "%s: stepped onto '%s' at %s (not water)" % [
				str(acc["label"]), DataLoader.map.char_at(cell), str(cell)])
			return false
		if not SailPathLib.is_step_legal(DataLoader.map, cursor, cell):
			_check(false, "%s: illegal step %s → %s" % [
				str(acc["label"]), str(cursor), str(cell)])
			return false
		# The seam (§4.1): record both crossing directions by their step number.
		steps += 1
		if cursor.x == 0 and cell.x == WORLD_WIDTH - 1:
			(acc["cross_west"] as Array).append(steps)
		elif cursor.x == WORLD_WIDTH - 1 and cell.x == 0:
			(acc["cross_east"] as Array).append(steps)
		acc["net_dx"] = int(acc["net_dx"]) \
			+ SailPathLib.short_dx(cursor.x, cell.x, WORLD_WIDTH)
		# Weather bands along the sailed tiles, and the tile that crossed the
		# 30°N edge (for leg 1's "exactly once" assertion).
		var zone := SailingSimLib.weather_zone_for(cell)
		if zone != zones[zones.size() - 1]:
			acc["edge_cell"] = cell
		zones.append(zone)
		tiles.append(cell)
		cursor = Vector2i(world.fleet_cell())
		acc["cell"] = cursor
		# §4.5: supplies are eaten on day ticks; they must never reach 0.
		_min_provisions = mini(_min_provisions, FleetLib.supplies("provisions"))
		_min_water = mini(_min_water, FleetLib.supplies("water"))
	acc["steps"] = steps
	# Docking (20-* §4.11.1): arriving on a port's **berth** no longer opens the
	# port; the voyage docks by heading into the shore tile, exactly like a key
	# press. The fleet stays on the berth, so `acc["cell"]` is still the goal.
	if GameState.current_port == null:
		_dock_if_at_berth(acc, cursor)
	acc["days"] = int(acc["days"]) + (GameState.day - day0)
	if GameState.current_port != null:
		(acc["stops"] as Array).append(str(GameState.current_port))
	return cursor == goal


## If the fleet stands on a port's berth, dock by stepping into that port's shore
## tile — the harbor-pair gesture (`20-*` §4.11.1). Records the docking step in
## the leg's counters so the day/wrap math stays honest.
func _dock_if_at_berth(acc: Dictionary, cell: Vector2i) -> void:
	var port_id: String = DataLoader.map.port_id_at(cell)
	if port_id.is_empty():
		return
	var shore: Vector2i = DataLoader.map.shore_cell(port_id)
	if shore.x < 0:
		return
	var moved: bool = world.try_step(shore)
	var guard := 0
	while not moved and guard < 6:
		if not _dismiss_modals():
			break
		moved = world.try_step(shore)
		guard += 1
	_check(moved, "%s: docking into %s's shore tile %s was accepted" % [
		str(acc["label"]), port_id, str(shore)])
	if not moved:
		return
	acc["steps"] = int(acc["steps"]) + 1
	if GameState.current_port != null:
		_check(Vector2i(world.fleet_cell()) == cell,
			"%s: docking leaves the fleet on the berth %s (got %s)" % [
				str(acc["label"]), str(cell), str(world.fleet_cell())])


## Closes a leg: the shared assertions every voyage owes (arrival, envelope,
## survival, supplies) plus the summary-table row.
func _end_leg(acc: Dictionary, goal: Vector2i) -> void:
	var label := str(acc["label"])
	var steps := int(acc["steps"])
	var days := int(acc["days"])
	var port_days := int(acc["port_days"])
	# Envelope: `steps` tiles at the fleet's fastest possible speed is the
	# fewest days the voyage can take (`steps / 18`); at its slowest it is
	# `steps / 9`; provisioning days are explicit additions, not slack.
	var lo := float(steps) / float(MAX_SPEED)
	var hi := float(steps) / float(MIN_SPEED) + float(port_days)
	print("NOTE  %s: %d steps → %d days, envelope %.1f..%.1f (+%d port days)" % [
		label, steps, days, lo, hi, port_days])
	_check(days > 0, "%s: the clock advanced (%d days)" % [label, days])
	_check(float(days) >= lo - 0.001,
		"%s: %d days is not faster than %d tiles at %d tiles/day (min %.1f)"
		% [label, days, steps, MAX_SPEED, lo])
	_check(float(days) <= hi + 0.001,
		"%s: %d days is inside the slow envelope %.1f (+%d port days)"
		% [label, days, hi, port_days])
	_check(not SailingSimLib.is_game_over(),
		"%s: no game over (reason '%s')" % [label,
			SailingSimLib.game_over_reason])
	_check(_min_provisions > 0 and _min_water > 0,
		"%s: provisions/water never hit 0 while under way (min %d/%d)"
		% [label, _min_provisions, _min_water])
	_check(FleetLib.total_crew() > 0,
		"%s: crew aboard at the end (%d)" % [label, FleetLib.total_crew()])
	_rows.append({
		"leg": label, "steps": steps, "days": days,
		"lo": lo, "hi": hi, "port_days": port_days,
		"start": str(acc["start"]), "goal": str(goal),
		"ok": Vector2i(acc["cell"]) == goal
			and not SailingSimLib.is_game_over(),
	})


# --- Ports: provisioning (a deliberate stop) -------------------------------

## Repairs every hull, re-hires to `crew_min`, rests the crew back to a healthy
## morale and fills the hold — the real shipyard/tavern/inn/market actions a
## voyage needs. Returns the days spent in port (the ledger's in-port days,
## which the envelope counts explicitly).
func _provision(port_id: String) -> int:
	if port_id.is_empty() or DataLoader.get_port(port_id).is_empty():
		return 0
	var day0: int = GameState.day
	GameState.current_port = port_id
	_dismiss_modals()
	for index in GameState.fleet.size():
		var points: int = ShipyardLib.max_repair_points(index)
		if points > 0:
			ShipyardLib.repair(index, points, port_id)
	var crew_min: int = FleetLib.ship_stat(FleetLib.flagship(), "crew_min")
	var heads: int = crew_min - FleetLib.total_crew()
	if heads > 0:
		TavernLib.hire(mini(heads, TavernLib.max_hire()))
	# §4.8.1: an in-port day is morale +5 (cap 80); rest in 3-day blocks.
	var rests := 0
	while GameState.morale < 75 and rests < 4 and InnLib.can_rest():
		InnLib.rest()
		rests += 1
		_dismiss_modals()
	# Supplies: an even split, because provisions and water are consumed 1:1.
	var half: int = FleetLib.fleet_free() / 2
	for kind in ["water", "provisions"]:
		TradeLib.buy_supplies(port_id, kind, mini(
			TradeLib.supplies_buy_max(kind), maxi(0, half)))
	half = FleetLib.fleet_free() / 2
	for kind in ["provisions", "water"]:
		TradeLib.buy_supplies(port_id, kind, mini(
			TradeLib.supplies_buy_max(kind), maxi(0, half)))
	GameState.current_port = null
	_dismiss_modals()
	return GameState.day - day0


## The task's sanctioned teleport-assist **between legs**: place the fleet at
## `port_id`'s harbour and provision there. Recorded in the leg (with where it
## came from), and never counted as sailed columns, so a hop cannot hide a
## segment.
func _hop(acc: Dictionary, port_id: String) -> void:
	var here: Vector2i = world.fleet_cell()
	_teleport(_port(port_id))
	var spent := _provision(port_id)
	(acc["hops"] as Array).append({
		"port": port_id, "from": here, "back": world.fleet_cell(),
		"round_trip": false,
	})
	acc["port_days"] = int(acc["port_days"]) + spent
	_check(Vector2i(world.fleet_cell()) == _port(port_id),
		"leg 4: the %s teleport-assist lands on its harbour %s (got %s)"
		% [port_id, str(_port(port_id)), str(world.fleet_cell())])


## A provisioning stop that teleports to `port_id`, provisions, and returns to
## the **exact cell** the fleet left — a supply stop, never a movement
## shortcut. Leg 4 asserts every one of these round trips.
func _resupply(acc: Dictionary, port_id: String) -> void:
	var here: Vector2i = world.fleet_cell()
	_teleport(_port(port_id))
	var spent := _provision(port_id)
	_teleport(here)
	(acc["hops"] as Array).append({
		"port": port_id, "from": here, "back": world.fleet_cell(),
		"round_trip": true,
	})
	acc["port_days"] = int(acc["port_days"]) + spent
	_check(Vector2i(world.fleet_cell()) == here,
		"leg 4: the %s provisioning stop returned to %s (got %s)"
		% [port_id, str(here), str(world.fleet_cell())])


# --- Helpers ---------------------------------------------------------------

## Places the fleet without sailing (the sanctioned teleport-assist — used only
## between the four separate voyages and for leg 4's provisioning hops).
func _teleport(cell: Vector2i) -> void:
	GameState.set_world_tile(cell)
	GameState.world["clock_fraction"] = 0.0
	world.sync_from_state()


## Closes every open modal. A `DialogBox` (weather damage, arrival greeting) is
## dismissed; a mutiny offer is resolved the way a player would — pay the crew
## off (§4.8.3). Returns true when something was closed.
func _dismiss_modals() -> bool:
	var closed := false
	for _pass_index in 8:
		var visible: Array = []
		for node in get_tree().get_nodes_in_group("modal_overlay"):
			if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
				visible.append(node)
		if visible.is_empty():
			break
		for node in visible:
			if node.name == "MutinyDialog" and node.has_method("accept"):
				node.accept()
			elif node.has_method("close"):
				node.close()
			elif node.has_method("cancel"):
				node.cancel()
			closed = true
	var hud = world.get_node_or_null("HUDLayer/HUD")
	if hud != null and hud.has_method("has_modal"):
		var guard := 0
		while hud.has_modal() and guard < 8:
			guard += 1
			var dialog = hud.current_dialog()
			if dialog == null:
				break
			if dialog.name == "MutinyDialog" and dialog.has_method("accept"):
				dialog.accept()
			elif dialog.has_method("close"):
				dialog.close()
			elif dialog.has_method("cancel"):
				dialog.cancel()
			else:
				break
			closed = true
	return closed


## The cells of an override polyline, derived from `tools/map_overrides.json`
## exactly as `tools/build_world.py` does: project each point with the locked
## `(lon + 180) × 6`, `(90 − lat) × 6`, walk it at 1/20-tile resolution, and
## bridge a diagonal tile change with an orthogonal step so the chain is
## 4-connected. `min_width_tiles` is 1 for every entry used here, so the
## channel is the chain itself.
func _channel_cells(name: String) -> Array:
	var out: Array = []
	var raw = JSON.parse_string(
		FileAccess.get_file_as_string("res://tools/map_overrides.json"))
	if not (raw is Dictionary):
		return out
	for entry in (raw as Dictionary).get("overrides", []):
		if not (entry is Dictionary) or str(entry.get("name", "")) != name:
			continue
		var points: Array = (entry as Dictionary).get("path", [])
		var xy: Array = []
		for point in points:
			if not (point is Array) or (point as Array).size() < 2:
				continue
			xy.append(Vector2(
				(float(point[1]) + 180.0) * TILES_PER_DEGREE,
				(90.0 - float(point[0])) * TILES_PER_DEGREE
			))
		if xy.is_empty():
			return out
		var chain: Array = []
		var previous := Vector2i(int(floor(xy[0].x)), int(floor(xy[0].y)))
		_add_channel_cell(chain, previous)
		for index in range(1, xy.size()):
			var a: Vector2 = xy[index - 1]
			var b: Vector2 = xy[index]
			var steps := maxi(1, int(ceil(maxf(absf(b.x - a.x),
				absf(b.y - a.y)) * 20.0)))
			for step in range(1, steps + 1):
				var t := float(step) / float(steps)
				var tile := Vector2i(
					int(floor(a.x + (b.x - a.x) * t)),
					int(floor(a.y + (b.y - a.y) * t)))
				if tile == previous:
					continue
				if tile.x != previous.x and tile.y != previous.y:
					_add_channel_cell(chain, Vector2i(tile.x, previous.y))
				_add_channel_cell(chain, tile)
				previous = tile
		return chain
	return out


static func _add_channel_cell(chain: Array, cell: Vector2i) -> void:
	var wrapped := Vector2i(posmod(cell.x, WORLD_WIDTH),
		clampi(cell.y, 0, WORLD_HEIGHT - 1))
	if chain.is_empty() or chain[chain.size() - 1] != wrapped:
		chain.append(wrapped)


## How many of `cells` appear in `tiles` (the sailed tile sequence).
func _count_hits(tiles: Array, cells: Array) -> int:
	var wanted: Dictionary = {}
	for cell in cells:
		wanted[Vector2i(cell)] = true
	var hits := 0
	for cell in tiles:
		if wanted.has(Vector2i(cell)):
			hits += 1
	return hits


## A copy of the shipped world with `cells` turned into land — the "what if the
## carve were not there" map for leg 2's proof. The live loader is untouched.
func _map_with_land(cells: Array):
	var indices: PackedByteArray = DataLoader.map.indices.duplicate()
	for cell in cells:
		var tile := Vector2i(cell)
		indices[tile.y * WORLD_WIDTH + posmod(tile.x, WORLD_WIDTH)] = 2
	return MapLoaderLib.from_indices(WORLD_WIDTH, WORLD_HEIGHT, indices,
		DataLoader.map_legend)


# --- Reporting -------------------------------------------------------------

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS  " + label)
	else:
		_failures.append(label)
		print("FAIL  " + label)


## How many `tools/test_*.tscn` suites exist (the phase-wide count task N
## records; this suite is one of them).
func _suite_count() -> int:
	var directory := DirAccess.open("res://tools")
	if directory == null:
		return -1
	var count := 0
	for file in directory.get_files():
		if file.begins_with("test_") and file.ends_with(".tscn"):
			count += 1
	return count


func _report(started_ms: int) -> void:
	var elapsed := Time.get_ticks_msec() - started_ms
	print("")
	print("LEG     STEPS  DAYS  ENVELOPE (days)   START        GOAL         OK")
	for row in _rows:
		print("%-7s %5d %5d  %5.1f .. %5.1f   %-12s %-12s %s" % [
			str(row["leg"]), int(row["steps"]), int(row["days"]),
			float(row["lo"]), float(row["hi"]), str(row["start"]),
			str(row["goal"]), "yes" if bool(row["ok"]) else "NO",
		])
	var total_steps := 0
	var total_days := 0
	for row in _rows:
		total_steps += int(row["steps"])
		total_days += int(row["days"])
	print("TOTAL   %5d %5d  (%d sailed voyages, %d ms wall clock)" % [
		total_steps, total_days, _rows.size(), elapsed])
	print("")
	print("SUITES %d  CHECKS %d" % [_suite_count(), _checks])
	if _failures.is_empty():
		print("ALL PASS (%d checks, %d suites) — %d voyages" % [
			_checks, _suite_count(), _rows.size()])
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - " + failure)
	get_tree().quit(1)
