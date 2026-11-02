class_name FleetPath
extends RefCounted
## The time-budgeted pursuit A* — the ONLY runtime pathfinding in the Phase-5
## fleet ecology (docs/60-COMBAT.md §4.11.11.1: lane traffic never pathfinds;
## the ≤ 250 ms/day budget survives for hunter/pursuit chases only, and an
## overflow loses the chase that day).
##
## Pure static helper (docs/90-* §4): an 8-direction, wrap-aware, step-cost
## A* over the passability grid, reusing the builder's walk rule
## (`tools/build_routes.py`: "8-direction straight-line raster walk, corner
## cutting forbidden, x wraps mod width"). The caller (npc_fleets.gd) owns
## the day budget around [method find_path].
##
## Shared-A* core (docs/20-WORLD-AND-SAILING.md §4.19, W5-D): this module IS
## the extracted common A* the appointed voyage builds on. The pure-move
## extraction required by the Shared-A* rule is already complete — the NPC
## pursuit's single pathfinding site (`npc_fleets.gd` `_pursue`) has routed
## through [method find_path] since this file was lifted out of it in Phase 5,
## so W5-D's "pure move" is this documented no-op (verified: the pursuit
## determinism suites `test_npc_fleets` / `test_ecology` / `test_density` are
## re-run byte-green across the W5-D changes). The §4.19 weighted cost lands
## beside the unit-cost core as [method find_path_weighted] — the same wrap /
## no-corner-cutting walk domain, additive only, with the pursuit path
## untouched.

## Hard expansion ceiling: a guard, never a code path — an unreachable goal
## must return an empty path instead of spinning (the same defensive rule as
## the retired encounters system's candidate-scan limit).
const MAX_EXPANSIONS := 40000

const NO_CELL := Vector2i(-1, -1)

## Expansion guard of the §4.19 weighted search ([method find_path_weighted]).
## Cross-ocean appointments expand far more than a pursuit chase, so the
## guard sits above the pursuit's [constant MAX_EXPANSIONS]; it is still only
## a runaway guard, never a code path (IMPLEMENT-Phase8 risk table: the
## player recomputes once per appointment, so seconds are tolerable — the
## measured budget lands in tools/test_autopilot.gd).
const MAX_EXPANSIONS_WEIGHTED := 200000

## Bounded-suboptimality inflation of the weighted heuristic (Weighted A*):
## f = g + [constant HEURISTIC_WEIGHT] × h. The pure-admissible bound
## (`1.0 / MIN_STEP_FACTOR_BOUND` ≈ 0.62 per tile) makes a cross-ocean
## search degenerate toward Dijkstra — the measured Lisbon→Goa query overruns
## any interactive budget (200k expansions in ~8 s without reaching the
## goal). Inflating by this factor focuses the search on the cheap corridor;
## the returned route is within this factor of the true cheapest under the
## model cost, which is exactly the §4.19 requirement ("avoids head-wind
## bands … rides the trades"), not a strict-optimality pin. Deterministic:
## pure float math on the same `(f, key)` order.
const HEURISTIC_WEIGHT := 2.0

## §4.4 maximum propulsion factor bound used by the weighted heuristic: the
## best §4.14 direction factor (sail downwind, 1.30) times the best §4.16
## current factor (strength 3 aligned, 1 + 0.08 × 3; padded to 1.25 so the
## float-scaled bound can never dip under the true minimum cost). The
## heuristic multiplies the wrapped Chebyshev distance by
## `1.0 / MIN_STEP_FACTOR_BOUND` — admissible for any cost_fn built from
## those §4.14/§4.16 factor tables (see autopilot.gd).
const MIN_STEP_FACTOR_BOUND := 1.30 * 1.25


## Shortest passable path `from → to` as `[from, …, to]` (empty when none).
## `passable` is a `Callable(cell) -> bool`; x wraps mod `width`, y is
## bounded. Diagonals never cut corners: both orthogonal neighbours of the
## diagonal must be passable.
static func find_path(from: Vector2i, to: Vector2i, width: int, height: int,
		passable: Callable) -> Array:
	if width <= 0 or height <= 0:
		return []
	if from == to:
		return [from]
	var to_y := to.y
	if to_y < 0 or to_y >= height:
		return []
	var to_wrapped := Vector2i(posmod(to.x, width), to_y)
	if not passable.call(to_wrapped):
		return []
	# g/normals keyed by wrapped cell key.
	var gscore: Dictionary = {_key(from, width): 0}
	var came: Dictionary = {}
	var open: Array = [[_h(from, to_wrapped, width), _key(from, width)]]
	var closed: Dictionary = {}
	var expansions := 0
	while not open.is_empty():
		var best_index := _pop_min(open)
		var current_key: int = open[best_index][1]
		# Remove the entry as it pops (a re-push on improvement is a new
		# entry, so no stale index can be returned twice — no spin).
		open.remove_at(best_index)
		if closed.has(current_key):
			continue
		closed[current_key] = true
		var current: Vector2i = _cell(current_key, width)
		expansions += 1
		if expansions > MAX_EXPANSIONS:
			return []
		if current == to_wrapped:
			return _rebuild(came, current_key, width)
		for step in NEIGHBOURS:
			var next := Vector2i(posmod(current.x + step.x, width), current.y + step.y)
			if next.y < 0 or next.y >= height:
				continue
			if not passable.call(next):
				continue
			if step.x != 0 and step.y != 0:
				# No corner cutting (the builder's walk rule).
				if not passable.call(Vector2i(posmod(current.x + step.x, width), current.y)):
					continue
				if not passable.call(Vector2i(current.x, current.y + step.y)):
					continue
			var next_key := _key(next, width)
			if closed.has(next_key):
				continue
			var tentative := int(gscore[_key(current, width)]) + 1
			var known = gscore.get(next_key, null)
			if known != null and int(known) <= tentative:
				continue
			gscore[next_key] = tentative
			came[next_key] = _key(current, width)
			open.append([tentative + _h(next, to_wrapped, width), next_key])
	return []


const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
	Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1),
]


## Chebyshev heuristic (wrap-aware on x) — admissible for unit step costs.
static func _h(a: Vector2i, b: Vector2i, width: int) -> int:
	var dx := absi(a.x - b.x) % width
	return maxi(mini(dx, width - dx), absi(a.y - b.y))


static func _key(cell: Vector2i, width: int) -> int:
	return int(cell.y) * width + int(posmod(cell.x, width))


static func _cell(key: int, width: int) -> Vector2i:
	return Vector2i(key % width, key / width)


## Index of the best (lowest f, then lowest key) open entry.
static func _pop_min(open: Array) -> int:
	var best := 0
	for index in range(1, open.size()):
		var f: int = open[index][0]
		var best_f: int = open[best][0]
		if f < best_f or (f == best_f and int(open[index][1]) < int(open[best][1])):
			best = index
	return best


static func _rebuild(came: Dictionary, end_key: int, width: int) -> Array:
	var out: Array = []
	var key := end_key
	while true:
		out.push_front(_cell(key, width))
		var parent = came.get(key, null)
		if parent == null:
			break
		key = int(parent)
	return out


# --- §4.19 weighted search (the appointed-voyage cost lands here) -----------

## The wind/current-weighted A* of the appointed voyage (docs/20-*
## §4.19): the SAME search domain as [method find_path] — 8-direction,
## x wraps mod `width`, y bounded, diagonals never cut corners — but each
## step costs `cost_fn(step_from, step_to) -> float` (must be > 0) instead
## of 1, so a route can trade distance for cheaper sailing days.
##
## `cost_fn` receives WRAPPED cells (the same frame as `passable`). The
## caller builds it from the §4.19 factors: cost = base × month-prevailing
## wind heading factor × current vector factor, expressed as a time
## multiplier (`1 / (wind_f × current_f)` — a head-wind step costs MORE
## days, which is what makes the route avoid head-wind bands and ride the
## trades; §4.19's "avoid head-wind … ride the trades" pins the direction).
##
## `opts`:
##   - `min_step_cost` (float, default `1.0 / MIN_STEP_FACTOR_BOUND`): the
##     admissibility bound of the heuristic. It must be ≤ the smallest
##     cost_fn value; a larger bound breaks optimality, a smaller one only
##     widens the search.
##   - `h_weight` (float, default [constant HEURISTIC_WEIGHT]): the
##     bounded-suboptimality inflation (Weighted A*, f = g + w·h). `1.0`
##     restores the pure-admissible search.
##   - `max_expansions` (int, default [constant MAX_EXPANSIONS_WEIGHTED]):
##     the runaway guard; overflow returns `[]`.
##
## Returns `[from, …, to]` like [method find_path] (empty when none):
## unreachable goal, guard overflow, or an impassable endpoint. Float g/f
## scores compare exactly (no rounding), and the open list is a binary heap
## ordered by the SAME deterministic `(f, then key)` tuple as the unit core's
## [method _pop_min] — keys are unique per cell, so equal-f ties resolve
## identically on every run and machine. (The unit core keeps its linear
## `_pop_min` byte-for-byte; its pursuit frontier is small and its 61 ms
## worst case is pinned — a cross-ocean appointment needs the heap.)
static func find_path_weighted(from: Vector2i, to: Vector2i, width: int,
		height: int, passable: Callable, cost_fn: Callable,
		opts: Dictionary = {}) -> Array:
	if width <= 0 or height <= 0:
		return []
	if from == to:
		return [from]
	var to_y := to.y
	if to_y < 0 or to_y >= height:
		return []
	var to_wrapped := Vector2i(posmod(to.x, width), to_y)
	if not passable.call(to_wrapped):
		return []
	var min_step: float = float(opts.get("min_step_cost",
		1.0 / MIN_STEP_FACTOR_BOUND))
	var h_weight: float = float(opts.get("h_weight", HEURISTIC_WEIGHT))
	var max_expansions: int = int(opts.get("max_expansions",
		MAX_EXPANSIONS_WEIGHTED))
	var from_wrapped := Vector2i(posmod(from.x, width), from.y)
	var gscore: Dictionary = {_key(from_wrapped, width): 0.0}
	var came: Dictionary = {}
	var open := HeapPopMin.new()
	open.push(_h_float(from_wrapped, to_wrapped, width) * min_step * h_weight,
		_key(from_wrapped, width))
	var closed: Dictionary = {}
	var expansions := 0
	while not open.is_empty():
		var best: Array = open.pop()
		var current_key: int = best[1]
		if closed.has(current_key):
			continue
		closed[current_key] = true
		var current: Vector2i = _cell(current_key, width)
		expansions += 1
		if expansions > max_expansions:
			return []
		if current == to_wrapped:
			return _rebuild(came, current_key, width)
		var g_current: float = gscore[current_key]
		for step in NEIGHBOURS:
			var next := Vector2i(posmod(current.x + step.x, width),
				current.y + step.y)
			if next.y < 0 or next.y >= height:
				continue
			if not passable.call(next):
				continue
			if step.x != 0 and step.y != 0:
				# No corner cutting (the shared walk rule).
				if not passable.call(Vector2i(
						posmod(current.x + step.x, width), current.y)):
					continue
				if not passable.call(Vector2i(current.x,
						current.y + step.y)):
					continue
			var next_key := _key(next, width)
			if closed.has(next_key):
				continue
			var tentative: float = g_current + float(
				cost_fn.call(current, next))
			var known = gscore.get(next_key, null)
			if known != null and float(known) <= tentative:
				continue
			gscore[next_key] = tentative
			came[next_key] = current_key
			open.push(tentative + _h_float(next, to_wrapped, width)
				* min_step * h_weight, next_key)
	return []


## A minimal binary min-heap of `(f: float, key: int)` entries — the
## deterministic open list of [method find_path_weighted]. Pop order is
## strictly by `(f, key)`: keys are unique per cell, so no two entries ever
## compare equal and the order is machine-independent.
class HeapPopMin:
	var _data: Array = []

	func is_empty() -> bool:
		return _data.is_empty()

	func push(f: float, key: int) -> void:
		_data.append([f, key])
		var child := _data.size() - 1
		while child > 0:
			var parent := (child - 1) / 2
			if _before(_data[child], _data[parent]):
				var tmp: Array = _data[parent]
				_data[parent] = _data[child]
				_data[child] = tmp
				child = parent
			else:
				break

	## Pops the smallest `(f, key)` entry as `[f, key]`.
	func pop() -> Array:
		var top: Array = _data[0]
		var last: Array = _data[_data.size() - 1]
		_data.remove_at(_data.size() - 1)
		if not _data.is_empty():
			_data[0] = last
			var parent := 0
			while true:
				var left := parent * 2 + 1
				var right := left + 1
				var best := parent
				if left < _data.size() and _before(_data[left], _data[best]):
					best = left
				if right < _data.size() and _before(_data[right], _data[best]):
					best = right
				if best == parent:
					break
				var tmp: Array = _data[parent]
				_data[parent] = _data[best]
				_data[best] = tmp
				parent = best
		return top

	## The strict total order: lower f first, then the lower cell key.
	static func _before(a: Array, b: Array) -> bool:
		var fa: float = a[0]
		var fb: float = b[0]
		if fa != fb:
			return fa < fb
		return int(a[1]) < int(b[1])


## Wrapped Chebyshev distance as a float (the [method _h] domain, kept
## separate so the unit-cost core stays byte-identical).
static func _h_float(a: Vector2i, b: Vector2i, width: int) -> float:
	var dx := absi(a.x - b.x) % width
	return float(maxi(mini(dx, width - dx), absi(a.y - b.y)))
