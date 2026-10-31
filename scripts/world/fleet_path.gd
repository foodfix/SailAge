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

## Hard expansion ceiling: a guard, never a code path — an unreachable goal
## must return an empty path instead of spinning (the same defensive rule as
## encounters' candidate-scan limit).
const MAX_EXPANSIONS := 40000

const NO_CELL := Vector2i(-1, -1)


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
