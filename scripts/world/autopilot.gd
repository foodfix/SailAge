class_name Autopilot
extends RefCounted
## Appointed voyage (委任航行) engine — docs/20-WORLD-AND-SAILING.md §4.19,
## docs/IMPLEMENT-Phase8.md W5-D, docs/80-UI-UX.md §4.10.4.
##
## Pure static module (docs/90-* §4, the [Skills] style): no node references,
## no scene access. State ownership: the **persisted** state is exactly save
## v9's `player.autopilot` `{dest_port_id}` (absent = not appointed — the key
## is written/cleared here as a plain `GameState.player` entry, never a new
## GameState field); the precomputed ROUTE is runtime-only and recomputes on
## load, exactly as the save-shape note pins ("the route recomputes on load").
##
## Route quality (§4.19, the skill investment):
##   - pilot navigation 40–69 → the plain §4.2 wind-blind shortest-water A*
##     (`sail_path.gd`, unchanged);
##   - pilot navigation ≥ 70 → the weighted A* over the SHARED core
##     (`fleet_path.gd` [FleetPath.find_path_weighted], the pure-move
##     extraction the pursuit already routes through): cost = base ×
##     month-prevailing-wind heading factor (§4.14) × current vector factor
##     (§4.16), as a TIME multiplier `1 / (wind_f × current_f)` — a
##     head-wind step costs more days, which is what makes the route avoid
##     head-wind bands and ride the trades. The weighted passability also
##     refuses in-month seasonal ice (§4.18).
##
## Input mode, not physics: while appointed the fleet walks the route through
## the NORMAL per-step rules (clock, §4.5 ledger, §4.11 port entry, contact)
## — the world scene pulls [method route] into its click-to-sail walk and
## calls [method tick] on its movement tick. This module owns the seams:
##   - `tick()` — per movement tick: storm auto-reef (storms do NOT cancel),
##     arrival detection (the world's dock seam then calls
##     `cancel("arrived")`), and blocked-route recompute;
##   - `cancel("contact")` — the world's hostile-contact funnel calls this
##     before the battle opens (§4.10.4 notice `sail.autopilot.cancelled_contact`);
##   - `cancel("manual")` — any manual move input (step key / helm key /
##     click-to-sail) cancels (the world_map wiring is the master's
##     micro-ledger; this is the seam).
##
## Costs unchanged (§4.19): nothing here touches provisions, water or wages —
## the appointed voyage pays the full §4.5 ledger every sea day because it
## walks the same per-step rules (the day tick is never bypassed).

const SailPathLib := preload("res://scripts/world/sail_path.gd")
const FleetPathLib := preload("res://scripts/world/fleet_path.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const SkillsLib := preload("res://scripts/player/skills.gd")

## The `skill_gates` row that owns the gate (pilot in post ∧ navigation ≥
## threshold, destination ∈ known_ports; docs/50-* gates, docs/10-* §4.20).
const GATE_FEATURE := "sail.autopilot"
## Doc fallback when the data row is missing (docs/20-* §4.19 pins 40).
const GATE_THRESHOLD_FALLBACK := 40
## §4.19 route-quality split: the pilot navigation at which the weighted
## cost replaces the plain shortest-water path (locked doc number).
const WEIGHTED_NAV_THRESHOLD := 70
## The pilot post that must be filled (docs/50-* §4.5.2 POST_SKILL).
const PILOT_POST := "pilot"

## The three locked cancel reasons (§4.19 interrupts + arrival).
const REASON_CONTACT := "contact"
const REASON_MANUAL := "manual"
const REASON_ARRIVED := "arrived"
const CANCEL_REASONS: Array[String] = [
	REASON_CONTACT, REASON_MANUAL, REASON_ARRIVED,
]

## The §4.10.4 notice the world shows on a hostile-contact cancel.
const CANCELLED_CONTACT_KEY := "sail.autopilot.cancelled_contact"

## --- Runtime-only route state (never saved; recomputes on load) ------------

## Unit steps **after** the fleet's current tile, ending on the destination's
## berth tile (§4.19 "the route ends at the destination's berth tile").
static var _route: Array[Vector2i] = []
## True when the stored route came from the weighted search (nav ≥ 70).
static var _route_weighted := false
## The §4.19 model cost of the stored route, in days
## (Σ step_multiplier / base_speed; the suite's weighted-vs-plain metric).
static var _route_cost_days := 0.0
## The player's trim before a storm auto-reef took it to `reefed` (§4.19;
## restored on the first non-storm tick — runtime-only, like the route).
static var _pre_storm_trim := ""


# --- Gate (docs/50-* §gates; the one skill_gates row) -----------------------

## The gate verdict for appointing toward `dest_port_id` (the argument is
## optional so `gate()` also answers the bare pilot/nav question). Returns
## `{ok, reason_key, threshold, pilot_nav, dest_known}`:
##   - `reason_key` is the `skill_gates` **feature_id** (`sail.autopilot`)
##     when the pilot/nav half fails — the reason TEXT lives in that row's
##     `reason.{zh,en}` and resolves through [method reason_text] at render
##     time (never hardcoded, the i18n rule);
##   - `dest_known` is false when `dest_port_id` was given and is outside
##     `GameState.known_ports` (§4.19). An unknown destination has no
##     skill_gates reason row, so `reason_key` stays "" and the caller just
##     renders the action disabled.
static func gate(dest_port_id: String = "") -> Dictionary:
	var threshold := gate_threshold()
	var pilot_id := pilot()
	var pilot_nav := pilot_navigation(pilot_id)
	var dest_known := true
	if not dest_port_id.is_empty():
		dest_known = dest_port_id in (GameState.known_ports as Array)
	var ok := not pilot_id.is_empty() and pilot_nav >= threshold and dest_known
	return {
		"ok": ok,
		"reason_key": GATE_FEATURE if (pilot_id.is_empty()
			or pilot_nav < threshold) else "",
		"threshold": threshold,
		"pilot_nav": pilot_nav,
		"dest_known": dest_known,
	}


## The `sail.autopilot` threshold from `data/skill_gates.json`
## ([DataLoader.get_skill_gate]), with the doc fallback when the row or the
## threshold is missing/invalid.
static func gate_threshold() -> int:
	var row: Dictionary = DataLoader.get_skill_gate(GATE_FEATURE)
	var threshold := int(row.get("threshold", 0))
	return threshold if threshold > 0 else GATE_THRESHOLD_FALLBACK


## The reason TEXT for a [method gate] result: the gate row's
## `reason.{zh,en}` through I18n ("" when ok / when nothing failed). The
## single render path, so every gated surface reads the same sentence.
static func reason_text(result: Dictionary) -> String:
	if bool(result.get("ok", false)):
		return ""
	var key := str(result.get("reason_key", ""))
	if key.is_empty():
		return ""
	var row: Dictionary = DataLoader.get_skill_gate(key)
	if row.is_empty():
		return ""
	return I18n.t(row.get("reason", {}))


## The id of the pilot officer in post ("" when the post is vacant).
static func pilot() -> String:
	return SkillsLib.post_holder(PILOT_POST)


## The pilot's own navigation (the §4.19 "that pilot's navigation"): the
## officer card's trained value, 0 when the post is vacant or the card is
## gone. The player's own navigation does NOT count — the gate is the
## officer's, the §4.5.3 contribution feeds the player's effective skill for
## night sailing, not this gate.
static func pilot_navigation(pilot_id: String = "") -> int:
	var id := pilot_id if not pilot_id.is_empty() else pilot()
	if id.is_empty():
		return 0
	var officer: Dictionary = DataLoader.get_officer(id)
	if officer.is_empty():
		return 0
	return int((officer.get("skills", {}) as Dictionary).get("navigation", 0))


# --- Appoint / cancel (§4.19 entry + interrupts) -----------------------------

## True while an appointment stands (`player.autopilot` present).
static func appointed() -> bool:
	var entry = GameState.player.get("autopilot", null)
	if not (entry is Dictionary):
		return false
	return not str((entry as Dictionary).get("dest_port_id", "")).is_empty()


## The appointed destination port id ("" when not appointed).
static func dest_port_id() -> String:
	var entry = GameState.player.get("autopilot", null)
	if not (entry is Dictionary):
		return ""
	return str((entry as Dictionary).get("dest_port_id", ""))


## Appoints the fleet to `dest_port_id`: gate → store the save-v9 key →
## compute + store the route (runtime). Returns
## `{ok, route, eta_days, cost_days, weighted}` on success, or
## `{ok: false, reason_key, threshold, dest_known}` (gate failed) /
## `{ok: false, no_route: true, …}` (no map, no berth or no sea route — the
## key is NOT stored). No gold fee (§4.19): officer wages are the cost.
static func appoint(dest_port_id: String) -> Dictionary:
	var verdict := gate(dest_port_id)
	if not bool(verdict.get("ok", false)):
		verdict["ok"] = false
		return verdict
	var built := _compute_route(dest_port_id)
	if not built:
		var out := verdict
		out["ok"] = false
		out["no_route"] = true
		return out
	GameState.player["autopilot"] = {"dest_port_id": dest_port_id}
	var steps := route()
	return {
		"ok": true,
		"route": steps.duplicate(),
		"eta_days": eta_days(steps),
		"cost_days": _route_cost_days,
		"weighted": _route_weighted,
	}


## Cancels the appointment. `reason` is one of [constant CANCEL_REASONS]:
## the contact funnel calls `cancel("contact")` (+ the
## [constant CANCELLED_CONTACT_KEY] notice, the world's toast), any manual
## move input calls `cancel("manual")`, the dock sequence calls
## `cancel("arrived")`. Returns false (and does nothing) for an unknown
## reason or when nothing is appointed — the world seam gates its notice on
## the `true` return.
static func cancel(reason: String) -> bool:
	if not (reason in CANCEL_REASONS):
		return false
	if not appointed():
		return false
	GameState.player.erase("autopilot")
	_drop_route()
	_restore_storm_trim()
	return true


# --- Route access + the closed-form ETA --------------------------------------

## The stored route (unit steps after the fleet's tile, ending on the berth).
## Recomputes on demand when empty — the load seam (the save carries only
## `dest_port_id`; the first tick after a load rebuilds the route from the
## live month/wind data, exactly the "recomputes on load" rule). Returns []
## when not appointed or no sea route exists.
static func route() -> Array[Vector2i]:
	if not appointed():
		return [] as Array[Vector2i]
	if _route.is_empty():
		_compute_route(dest_port_id())
	return _route.duplicate()


## The closed-form ETA of `route` in days: Σ per-leg `1 / effective_speed`
## (§4.2 `move_cost`) over the walk headings — the first leg is measured
## from the fleet's CURRENT tile, so the caller passes the route it got from
## [method appoint]/[method route] while standing where it stands. The §4.4
## floor keeps the divisor ≥ 1 (a furled fleet "arrives" at 1 tile/day
## rather than dividing by zero; the world never walks a furled fleet).
static func eta_days(steps: Array) -> float:
	var total := 0.0
	var prev := GameState.world_tile()
	for step_raw in steps:
		if not (step_raw is Vector2i):
			continue
		var step: Vector2i = step_raw
		var heading := _heading_between(prev, step)
		var speed := SailingSimLib.effective_speed(heading)
		total += 1.0 / float(maxi(speed, 1))
		prev = step
	return total


## The §4.19 model cost of a walk in days — the metric the suite compares
## the weighted route against the plain one with: Σ
## `step_multiplier / base_speed` where `step_multiplier =
## 1 / (wind_f × current_f)` is the SAME function the weighted A* minimizes.
## This is the month-model cost (prevailing wind + reversal-applied
## currents), not the day-walk's weather-jittered cost.
static func route_cost_days(from_cell: Vector2i, steps: Array) -> float:
	var month := _month()
	var ship_class := _ship_class()
	var base := float(maxi(FleetLib.slowest_speed(), 1))
	var total := 0.0
	var prev := from_cell
	for step_raw in steps:
		if not (step_raw is Vector2i):
			continue
		var step: Vector2i = step_raw
		var heading := _heading_between(prev, step)
		total += _step_multiplier(heading, step, month, ship_class) / base
		prev = step
	return total


## The set of wind-region ids a walk crosses (the suite's second
## weighted-vs-plain discriminator: a DIFFERENT crossing set is itself the
## locked "measurably differs" evidence). Sorted ascending; `0` entries
## (unassigned water) included as-is.
static func route_wind_regions(from_cell: Vector2i, steps: Array) -> Array[int]:
	var ocean = OceanLayersLib.instance()
	var seen := {}
	var prev := from_cell
	for step_raw in steps:
		if not (step_raw is Vector2i):
			continue
		var step: Vector2i = step_raw
		seen[int(ocean.wind_region_at(step))] = true
		prev = step
	var out: Array[int] = []
	for value in seen:
		out.append(int(value))
	out.sort()
	return out


# --- Tick (the world movement tick calls this; wiring = master micro) -------

## One movement tick of the appointed voyage. Returns
## `{appointed, dest, arrived, route}`:
##   - not appointed → `{appointed: false}` (a no-op; free to call always);
##   - fleet on the destination's berth → `arrived: true` — the world's dock
##     seam docks through the normal port-entry sequence and calls
##     `cancel("arrived")` (§4.19 "the appointment clears");
##   - otherwise `route` carries the steps to walk THIS tick; a next step the
##     month has made impassable (seasonal ice froze under the route, §4.18)
##     recomputes the route once here, so the walk never hits a frozen tile.
##
## Storms do NOT cancel (§4.19): on a storm day the appointment stands and
## the fleet AUTO-REEFS to `reefed` for that day — [method _storm_trim_tick]
## saves the player's previous trim, forces `reefed`, and restores it on the
## first non-storm tick (a trim the player changed meanwhile is left alone).
## The §4.7 storm effects apply through the normal ledger, untouched here.
## Nothing in this function reads the contact state: hostile contact
## cancels through the world's contact funnel (`cancel("contact")`), before
## the battle opens.
static func tick() -> Dictionary:
	if not appointed():
		return {"appointed": false}
	_storm_trim_tick()
	var dest := dest_port_id()
	var berth := _berth_of(dest)
	var at := GameState.world_tile()
	if berth.x >= 0 and at == berth:
		return {"appointed": true, "dest": dest, "arrived": true,
			"route": ([] as Array[Vector2i])}
	var steps := route()
	if not steps.is_empty() and _step_blocked_now(steps[0]):
		_drop_route()
		steps = route()
	return {"appointed": true, "dest": dest, "arrived": false,
		"route": steps.duplicate()}


# --- Route computation -------------------------------------------------------

## Builds + stores the route for `dest_port_id` per the pilot's navigation
## (§4.19 route-quality split). False when the map/port/sea route fails (the
## caller refuses the appointment; nothing is stored).
static func _compute_route(dest_port_id: String) -> bool:
	_drop_route()
	var map = DataLoader.map
	if map == null or int(map.width) <= 0 or int(map.height) <= 0:
		return false
	var width: int = int(map.width)
	var height: int = int(map.height)
	var berth := _berth_of(dest_port_id, map)
	if berth.x < 0:
		return false
	var from := GameState.world_tile()
	var month := _month()
	var ocean = OceanLayersLib.instance()
	var passable := func(cell: Vector2i) -> bool:
		# The weighted walk domain: the map's passability AND the month's
		# seasonal ice (§4.18 — the weighted route must avoid it; the start
		# cell is never entered, so a fleet frozen in can still sail out).
		if not map.is_passable(cell):
			return false
		return not ocean.ice_blocks(cell, month)
	if from == berth:
		# Standing on the destination berth already: the appointment is
		# legal and arrives on the next tick (empty route).
		return true
	var steps: Array[Vector2i] = []
	var sail = SailPathLib.new()
	if pilot_navigation() >= WEIGHTED_NAV_THRESHOLD:
		# §4.19 weighted A* over the shared core, corridor-constrained (see
		# [constant WEIGHTED_CORRIDOR_RADIUS]): the fast plain §4.2 route
		# seeds the band, the weighted cost picks the cheap days inside it.
		var seed: Array[Vector2i] = sail.find_path(from, berth, map)
		if seed.is_empty():
			return false
		var corridor := _corridor_mask(from, seed,
			WEIGHTED_CORRIDOR_RADIUS, width, height)
		var data: PackedByteArray = corridor["data"]
		var y0: int = corridor["y0"]
		var in_corridor := func(cell: Vector2i) -> bool:
			if cell.y < y0 or cell.y >= y0 + corridor["rows"]:
				return false
			return data[(cell.y - y0) * width + posmod(cell.x, width)] == 1
		var corridor_passable := func(cell: Vector2i) -> bool:
			if not passable.call(cell):
				return false
			return in_corridor.call(cell)
		var raw: Array = FleetPathLib.find_path_weighted(from, berth,
			width, height, corridor_passable, _make_cost_fn(month, width))
		if raw.is_empty():
			# Graceful degradation (the risk-table fallback spirit): the
			# appointment still works on the distance-optimal route.
			steps = seed
			_route_weighted = false
		else:
			for index in range(1, raw.size()):
				steps.append(raw[index])
			_route_weighted = true
	else:
		# 40–69: the plain §4.2 wind-blind shortest-water A*, verbatim.
		steps = sail.find_path(from, berth, map)
		_route_weighted = false
	if steps.is_empty():
		return false
	_route = steps
	_route_cost_days = route_cost_days(from, steps)
	return true


## The corridor band around `seed` (plus the start cell): a row-bounded
## PackedByteArray mask, `{data, y0, rows, width}` — `data[(y − y0) × width
## + posmod(x, width)] == 1` inside [constant WEIGHTED_CORRIDOR_RADIUS]
## (Chebyshev) of any seed cell. Built as per-row x-intervals (wrap-split),
## merged, then stamped once — no per-cell square walk. Memory is bounded by
## the seed's y-span (+2 × radius) rows × width bytes (~4 MB worst case).
static func _corridor_mask(from: Vector2i, seed: Array, radius: int,
		width: int, height: int) -> Dictionary:
	var y_lo := clampi(from.y - radius, 0, height - 1)
	var y_hi := clampi(from.y + radius, 0, height - 1)
	for step_raw in seed:
		if not (step_raw is Vector2i):
			continue
		var step: Vector2i = step_raw
		y_lo = mini(y_lo, maxi(step.y - radius, 0))
		y_hi = maxi(y_hi, mini(step.y + radius, height - 1))
	var rows := y_hi - y_lo + 1
	var data := PackedByteArray()
	data.resize(rows * width)
	# Per-row wrap-split intervals, then merge per row.
	var by_row: Dictionary = {}
	var cells: Array = [from]
	cells.append_array(seed)
	for cell_raw in cells:
		if not (cell_raw is Vector2i):
			continue
		var cell: Vector2i = cell_raw
		for dy in range(-radius, radius + 1):
			var row := cell.y + dy
			if row < y_lo or row > y_hi:
				continue
			var pieces: Array = _wrap_interval(cell.x - radius,
				cell.x + radius, width)
			if not by_row.has(row - y_lo):
				by_row[row - y_lo] = []
			(by_row[row - y_lo] as Array).append_array(pieces)
	for row_key in by_row:
		var merged: Array = _merge_intervals(by_row[row_key])
		var stamp_row := int(row_key) * width
		for interval: Array in merged:
			for x in range(int(interval[0]), int(interval[1]) + 1):
				data[stamp_row + x] = 1
	return {"data": data, "y0": y_lo, "rows": rows, "width": width}


## `[lo, hi]` (any integers) → non-overlapping pieces inside `[0, width)`
## (the x-wrap: a band that crosses the seam lands in both end pieces).
static func _wrap_interval(lo: int, hi: int, width: int) -> Array:
	var length := hi - lo + 1
	if length <= 0:
		return []
	if length >= width:
		return [[0, width - 1]]
	var start := posmod(lo, width)
	var out: Array = []
	var first_end := mini(width - 1, start + length - 1)
	out.append([start, first_end])
	var remaining := length - (first_end - start + 1)
	if remaining > 0:
		out.append([0, remaining - 1])
	return out


## Sorts `[x0, x1]` pairs by start and merges the overlaps/touches.
static func _merge_intervals(intervals: Array) -> Array:
	if intervals.is_empty():
		return []
	var sorted := intervals.duplicate()
	sorted.sort_custom(func(a: Array, b: Array) -> bool:
		return int(a[0]) < int(b[0]) \
			or (int(a[0]) == int(b[0]) and int(a[1]) < int(b[1])))
	var out: Array = [[sorted[0][0], sorted[0][1]]]
	for index in range(1, sorted.size()):
		var last: Array = out[out.size() - 1]
		var x0 := int(sorted[index][0])
		var x1 := int(sorted[index][1])
		if x0 <= int(last[1]) + 1:
			last[1] = maxi(int(last[1]), x1)
		else:
			out.append([x0, x1])
	return out


static func _drop_route() -> void:
	_route = []
	_route_weighted = false
	_route_cost_days = 0.0


## The §4.19 route-quality split. The weighted search rides a CORRIDOR: the
## plain §4.2 route (computed first, fast C++ AStarGrid2D) seeds a band of
## [constant WEIGHTED_CORRIDOR_RADIUS] tiles around itself, and the weighted
## A* optimizes within it. Why: a cross-ocean heuristic is structurally
## misleading on this map (Lisbon→Goa's straight line runs through Africa),
## so an unconstrained weighted A* degenerates to an ocean-wide flood — the
## measured query overran 200k expansions without reaching the goal. The
## corridor keeps the search inside the cheap-day band while still letting
## the route trade distance for wind/current days (± the radius everywhere);
## on overflow or failure it degrades gracefully to the plain route (the
## appointment still stands, just distance-optimal).
const WEIGHTED_CORRIDOR_RADIUS := 32


## The §4.19 step-cost multiplier the weighted A* minimizes:
## `1 / (wind_f × current_f)` —
##   - `wind_f`: the §4.14 month-prevailing-wind heading factor for the
##     step's heading at the DESTINATION tile of the step, through the §4.4
##     `DIRECTION_FACTORS` table for the flagship's class; `VAR` water and
##     unknown tokens factor neutral 1.0 (no information, the §6.5 fallback);
##   - `current_f`: the §4.16 alignment-band factor of the reversal-applied
##     current at the tile ([SailingSim.current_factor] — the one §4.16
##     lookup; identity in drift mode, where the current pushes instead).
## A step sailing INTO the prevailing wind (angle 0) costs up to ×2 the
## downwind (angle 180) step — exactly the "avoid head-wind bands, ride the
## trades" gradient §4.19 pins.
static func _step_multiplier(heading: String, cell: Vector2i, month: int,
		ship_class: String) -> float:
	var factor := _wind_heading_factor(heading, cell, month, ship_class) \
		* SailingSimLib.current_factor(heading, cell, month)
	return 1.0 / maxf(factor, 0.01)


## The month-prevailing-wind heading factor (§4.14 → §4.4 table).
static func _wind_heading_factor(heading: String, cell: Vector2i,
		month: int, ship_class: String) -> float:
	if heading.is_empty():
		return 1.0
	var token: String = OceanLayersLib.instance().prevailing_for(cell, month)
	if token.is_empty() or token == "VAR":
		return 1.0
	var angle := SailingSimLib.angle_between_dirs(heading, token)
	if angle < 0:
		return 1.0
	var table: Dictionary = SailingSimLib.DIRECTION_FACTORS.get(angle, {})
	return float(table.get(ship_class, 1.0))


## The cost_fn closure handed to [FleetPath.find_path_weighted]: per-step
## multiplier derived from the step heading (wrapped delta) and the step's
## destination tile.
static func _make_cost_fn(month: int, width: int) -> Callable:
	var ship_class := _ship_class()
	return func(a: Vector2i, b: Vector2i) -> float:
		var dx := b.x - a.x
		if dx > 1:
			dx -= width
		elif dx < -1:
			dx += width
		var heading := SailingSimLib.heading_of_delta(
			Vector2i(dx, b.y - a.y))
		return _step_multiplier(heading, b, month, ship_class)


# --- Storm auto-reef (§4.19; storms never cancel) ----------------------------

## The §4.19 storm rule, scoped to the appointment: on a storm day the trim
## becomes `reefed` (storm damage ×0.75, the §4.17 table), the player's
## previous trim is kept in [member _pre_storm_trim] and restored on the
## first non-storm tick — but only if the trim still reads `reefed` (a trim
## the player cycled meanwhile stays theirs). A fleet already at `reefed`
## needs no save/restore. The oar class ignores trim entirely (§4.17), so
## reefing a galley fleet is a harmless no-op.
static func _storm_trim_tick() -> void:
	var weather := str(GameState.world.get("weather",
		SailingSimLib.DEFAULT_WEATHER))
	if weather == "storm":
		if _pre_storm_trim.is_empty() \
				and SailingSimLib.sail_trim() != "reefed":
			_pre_storm_trim = SailingSimLib.sail_trim()
			GameState.world["sail_trim"] = "reefed"
		return
	if not _pre_storm_trim.is_empty():
		if SailingSimLib.sail_trim() == "reefed":
			GameState.world["sail_trim"] = _pre_storm_trim
		_pre_storm_trim = ""


static func _restore_storm_trim() -> void:
	if _pre_storm_trim.is_empty():
		return
	if SailingSimLib.sail_trim() == "reefed":
		GameState.world["sail_trim"] = _pre_storm_trim
	_pre_storm_trim = ""


# --- Small reads -------------------------------------------------------------

## The destination port's berth tile ([MapLoader.port_cell], the harbors
## table), or `(-1,-1)` without a map.
static func _berth_of(dest_port_id: String, map = null) -> Vector2i:
	var m = map if map != null else DataLoader.map
	if m == null or not m.has_method("port_cell"):
		return Vector2i(-1, -1)
	return m.port_cell(dest_port_id)


## True when `cell` cannot be ENTERED right now (map passability or the
## month's seasonal ice) — the tick's blocked-route recompute probe.
static func _step_blocked_now(cell: Vector2i) -> bool:
	var map = DataLoader.map
	if map == null or not map.is_passable(cell):
		return true
	return OceanLayersLib.instance().ice_blocks(cell, _month())


## The wrap-aware 8-dir id of a one-tile step (the §4.4 heading domain).
## The [FleetPath.short_dx] closed form inlined (the explicit-type discipline
## of this module — a preload-const static return cannot always be inferred
## at parse time).
static func _heading_between(from_cell: Vector2i, to_cell: Vector2i) -> String:
	var map = DataLoader.map
	var width := 4320
	if map != null and int(map.width) > 0:
		width = int(map.width)
	var dx := posmod(to_cell.x - from_cell.x, width)
	if dx > width / 2:
		dx -= width
	return SailingSimLib.heading_of_delta(Vector2i(dx, to_cell.y - from_cell.y))


static func _month() -> int:
	return SailingSimLib.month_for(maxi(int(GameState.day), 1))


## The flagship's propulsion class (`sail`/`oar`/`hybrid`), guard-read to
## `sail` without a fleet or hull (the §4.4 class of the wind factor table).
static func _ship_class() -> String:
	var ship: Dictionary = FleetLib.flagship()
	if ship.is_empty():
		return "sail"
	var ship_type: Dictionary = DataLoader.get_ship_type(
		str(ship.get("ship_type_id", "")))
	var cls := str(ship_type.get("class", ""))
	return cls if not cls.is_empty() else "sail"
