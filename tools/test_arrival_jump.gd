extends Node
## Regression gate for the arrival/seam teleport bug (bug report
## 2026-11-02): an NPC fleet visibly ~7.8 tiles from its destination port
## jumped straight into the port. Root causes fixed in
## `scripts/world/npc_fleets.gd`:
##   * the `_leg_geometry` per-day memo key packed {pid, a, b} only — legs
##     with equal ranges but opposite directions (and lane/spoke ids alike
##     across the per-kind id maps) collided and the loser sailed the
##     winner's geometry;
##   * lane variants resolved by fraction-of-path proportion, landing
##     sub-range legs of a structurally different variant on unrelated
##     water (every journey seam on the lane opened a teleport);
##   * patrol/treasure spawn routes shipped `tile_index = 0` while boarding
##     mid-lane — the first accrual step left the lane's far END;
##   * the patrol cycle docked the home berth at the span end, teleporting
##     home and back;
##   * `_depart`'s same-pass walk shipped a path-less move report, which
##     the render snaps.
##
## The probe sails the REAL ecology through real days and audits every
## rendered move report: consecutive waypoints must step ≤ 1 tile (8-dir) —
## a wider gap means the glide draws a straight dash across the gap. The
## doc-pinned berth heal (§4.11.11) is a counted design class.
##
##   godot --headless res://tools/test_arrival_jump.tscn
##
## Exits 0 (prints ALL PASS) when no unexplained jump is found, 1 otherwise.

const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")

## ~1 month past the day-31 rollover: covers spawn-day boarding, month
## rollover, departures and arrivals for the filled ecology.
const DAYS := 32
## Per-move accrual slices per day (the world scene accrues per player step).
const SLICES_PER_DAY := 4
## Chebyshev gap above this between consecutive waypoints is a jump.
const GAP_LIMIT := 1
## Examples kept per class before dedup.
const EXAMPLES_PER_CLASS := 3
const WATCHDOG_SECONDS := 150.0

var sim: NpcFleetsLib = null
var _counts: Dictionary = {}
var _examples: Dictionary = {}
var _audited := 0


func _ready() -> void:
	var watchdog := Timer.new()
	watchdog.wait_time = WATCHDOG_SECONDS
	watchdog.one_shot = true
	watchdog.timeout.connect(func() -> void:
		print("%d checks FAILED (watchdog: the probe exceeded %ds)"
			% [int(_counts.values().reduce(
				func(a: int, b: int) -> int: return a + b, 0)),
			WATCHDOG_SECONDS])
		get_tree().quit(1))
	add_child(watchdog)
	watchdog.start()
	var map = MapLoaderLib.new()
	var ok: bool = map.load_map("res://data/maps/world.png",
		DataLoader.map_legend)
	if not ok:
		print("FATAL: map load failed: %s" % map.last_error)
		get_tree().quit(1)
		return
	DataLoader.map = map
	NpcFleetsLib.reset_caches()

	GameState.player = {
		"nation_id": "portugal",
		"stats": {"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10},
		"xp": 0, "level": 1, "officers": [], "reputation": {},
	}
	GameState.fleet = []
	GameState.day = 1
	GameState.gold = 10000
	GameState.morale = 70
	GameState.current_port = null
	GameState.port_investments = {}
	GameState.known_ports = []
	GameState.world = {
		"position": {"x": 700, "y": 320}, "clock_fraction": 0.0,
		"map_id": "world", "weather": "fair", "last_departed_port": "",
		"hunter_intel_cell": null,
	}
	GameState.market_stocks = EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list)
	GameState.npc_fleets = []
	GameState.wrecks = []
	GameState.npc_preset = "normal"
	GameState.market_events = []
	GameState.npc_port_log = []

	sim = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": "normal",
	})
	sim.initial_fill(1)
	print("filled fleets: %d" % GameState.npc_fleets.size())

	var prev_cell: Dictionary = {}
	for fleet in GameState.npc_fleets:
		prev_cell[str(fleet.get("id", ""))] = NpcFleetsLib.position_of(fleet)

	for day in range(1, DAYS + 1):
		GameState.day = day
		var explained: Dictionary = {}
		for slice in range(SLICES_PER_DAY):
			GameState.world["clock_fraction"] = float(slice) \
				/ float(SLICES_PER_DAY)
			sim.advance_clock()
			_audit_moves("move", day, slice, prev_cell, explained)
		GameState.world["clock_fraction"] = 0.0
		sim.tick(day)
		GameState.day = day + 1
		sim.advance_clock()
		_audit_moves("tick-catchup", day + 1, -1, prev_cell, explained)
		_audit_day_changes(day, prev_cell, explained)

	_summary()


## Classify + record. `detail` is the per-class example payload.
func _flag(cls: String, detail: String) -> void:
	_counts[cls] = int(_counts.get(cls, 0)) + 1
	var seen: Array = _examples.get(cls, [])
	if seen.size() < EXAMPLES_PER_CLASS:
		seen.append(detail)
		_examples[cls] = seen


## Every rendered waypoint transition must step ≤ 1 tile (8-dir). A wider gap
## between consecutive waypoints (or from → path[0], path[-1] → to) is the
## straight-dash jump the glide would draw. Fleet ids whose walk validated
## clean are recorded in `explained` — the day-tick audit skips their cell
## delta (a depart walk inside the tick moves the cell across several
## reported unit steps).
func _audit_moves(kind: String, day: int, slice: int,
		prev_cell: Dictionary, explained: Dictionary) -> void:
	for move in sim.take_fleet_moves():
		var id := str(move.get("id", ""))
		var waypoints: Array[Vector2i] = [
			move.get("from", Vector2i.ZERO) as Vector2i]
		for cell in (move.get("path", []) as Array):
			waypoints.append(cell as Vector2i)
		var to: Vector2i = move.get("to", Vector2i.ZERO)
		if waypoints.size() < 2 or (waypoints[waypoints.size() - 1] as \
				Vector2i) != to:
			waypoints.append(to)
		var has_path: bool = not (move.get("path", []) as Array).is_empty()
		var clean := true
		_audited += waypoints.size() - 1
		for i in range(1, waypoints.size()):
			var gap: int = NpcFleetsLib.chebyshev(waypoints[i - 1],
				waypoints[i])
			if gap <= GAP_LIMIT:
				continue
			clean = false
			var fleet := sim._find(id)
			var cls := ""
			if not has_path:
				cls = "pathless-record"
			elif i == 1:
				cls = "from-to-first-step"
			elif i == waypoints.size() - 1:
				cls = "last-step-to"
			else:
				cls = "mid-path"
			_flag(cls, (("%s day %d/%d fleet %s(%s) wp %d/%d jump %s→%s " \
				+ "gap %d ev=[%s]%s") % [kind, day, slice, id,
				str(fleet.get("role", "?")) if not fleet.is_empty() else "?",
				i, waypoints.size() - 1, waypoints[i - 1], waypoints[i],
				gap, _events_tail(fleet),
				"" if fleet.is_empty() else "\n      " + _route_dump(fleet)]))
		if clean and waypoints.size() >= 2:
			explained[id] = true
		prev_cell[id] = to


## The day tick's own commits (berth heal, `_arrive` snaps) never join a move
## report: compare each fleet's cell across the tick. Fleets whose walk this
## tick already validated as unit steps (`explained`) are skipped. A still
## unexplained delta is classed: the doc-pinned berth heal (legs dropped, the
## §4.11.11 design snaps it to a resolvable berth) is counted as a design
## class; anything else is a failure.
func _audit_day_changes(day: int, prev_cell: Dictionary,
		explained: Dictionary) -> void:
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		var id := str(fleet.get("id", ""))
		var cell := NpcFleetsLib.position_of(fleet)
		var before: Vector2i = prev_cell.get(id, cell)
		var gap := NpcFleetsLib.chebyshev(before, cell)
		if gap <= GAP_LIMIT or explained.has(id):
			prev_cell[id] = cell
			continue
		var mooring: String = sim._port_at_cell(cell)
		var legs_empty: bool = ((fleet.get("route", {}) as Dictionary) \
			.get("legs", []) as Array).is_empty()
		var cls := ""
		if legs_empty:
			cls = "design-berth-heal"
		else:
			cls = "day-other-jump"
		_flag(cls, (("day-tick day %d fleet %s(%s) jump %s→%s gap %d " \
			+ "mooring=%s dest=%s ev=[%s]%s") % [day, id,
			str(fleet.get("role", "?")), before, cell, gap, mooring,
			str(fleet.get("dest_port_id", "")), _events_tail(fleet),
			"\n      " + _route_dump(fleet)]))
		prev_cell[id] = cell


## One-line route/geometry state for a flagged fleet: where the route thinks
## the fleet stands on its active geometry vs where the cell actually is.
func _route_dump(fleet: Dictionary) -> String:
	var route: Dictionary = fleet.get("route", {})
	var legs: Array = route.get("legs", [])
	if legs.is_empty():
		return "route: legs=[]"
	var leg: Dictionary = legs[0]
	var geo := sim._leg_geometry(leg)
	if geo.is_empty():
		return "route: legs[0]=%s:%s geo=BROKEN" % [
			str(leg.get("kind", "?")), str(leg.get("id", "?"))]
	var path: Array = geo["path"]
	var index := int(route.get("tile_index", 0))
	var cursor: int = (int(geo["end"]) - index) if bool(geo["reverse"]) \
		else (int(geo["start"]) + index)
	cursor = clampi(cursor, 0, path.size() - 1)
	var base: Array = sim._path_of("%s:%s" % [str(leg.get("kind", "")),
		str(leg.get("id", ""))])
	var cell := NpcFleetsLib.position_of(fleet)
	return (("route: leg=%s:%s a=%d b=%d rev=%s ti=%d | geo key=%s " \
		+ "start=%d end=%d walked=%d n=%d | cell=%s geoTile@ti=%s(%d) " \
		+ "cellInActive=%d cellInBase=%d | legs-left=%d") % [
		str(leg.get("kind", "?")), str(leg.get("id", "?")),
		int(leg.get("a", -1)), int(leg.get("b", -1)),
		str(leg.get("reverse", false)), index,
		str(geo["key"]), int(geo["start"]), int(geo["end"]),
		int(geo["walked_len"]), path.size(),
		cell, path[cursor], NpcFleetsLib.chebyshev(cell, path[cursor]),
		path.find(cell), base.find(cell), legs.size() - 1])


func _events_tail(fleet: Dictionary) -> String:
	var id := str(fleet.get("id", ""))
	var events: Array = sim._fleet_events.get(id, [])
	var tail: Array = []
	for i in range(maxi(events.size() - 4, 0), events.size()):
		tail.append(str(events[i]))
	return " ".join(tail)


func _summary() -> void:
	var total := 0
	for cls in _counts.keys():
		total += int(_counts[cls])
	# The doc-pinned berth heal (§4.11.11: a fleet whose journey dropped
	# mid-route snaps to a resolvable berth at dwell expiry) is a counted
	# design class — every other class fails the gate.
	var design := int(_counts.get("design-berth-heal", 0))
	print("----")
	print("jump classes (total %d):" % total)
	for cls in _counts.keys():
		print("  %-22s %d" % [cls, _counts[cls]])
		for ex in (_examples[cls] as Array):
			print("      · %s" % ex)
	if total - design == 0:
		print("ALL PASS (%d waypoints audited, %d design-class heal snaps)"
			% [_audited, design])
		get_tree().quit(0)
		return
	print("%d checks FAILED (%d unexplained jumps of %d audited)"
		% [total - design, total - design, _audited])
	get_tree().quit(1)
