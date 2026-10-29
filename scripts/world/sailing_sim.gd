class_name SailingSim
extends RefCounted
## Sailing simulation core (docs/20-WORLD-AND-SAILING.md §4).
##
## Pure logic, no node references (docs/90-ARCHITECTURE.md §4): every function
## is static and reads/mutates `GameState` through the singleton, so movement,
## the clock and the speed formula are unit-testable headless.
##
## Ownership split (docs/IMPLEMENT-Phase1.md T6/T7):
##   T6 (this file today): movement validation, applying a move, the
##       fractional clock accumulator + day boundary, `effective_speed()` and
##       `move_cost()`.
##   T7: `_run_daily_ledger()` (consumption, wages, weather, morale, fail
##       states, mutiny) plus its constants. The hook below is the seam; the
##       day increment calls it *before* `day_advanced` is emitted so every
##       listener sees a finished day (§4.3).
##
## Constants that belong to the daily ledger (RATION_SIZE, CREW_WAGE_DAILY, the
## weather zone table, …) are deliberately NOT defined here yet: §5 says all
## tunables live at the top of this file, and T7 owns that block.

const CharacterLib := preload("res://scripts/player/character.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")

## §4.4: "minimum 1 tile/day" — speed can never be 0 (§6).
const MIN_SPEED := 1

## §4.6: `crew / crew_min` never drops below 0.25.
const CREW_FACTOR_MIN := 0.25

## §4.7 wind factor: weather → propulsion class → multiplier.
const WIND_FACTORS := {
	"calm": {"sail": 0.8, "oar": 1.0, "hybrid": 1.0},
	"fair": {"sail": 1.0, "oar": 1.0, "hybrid": 1.0},
	"strong": {"sail": 1.25, "oar": 1.0, "hybrid": 1.1},
	"storm": {"sail": 1.5, "oar": 1.0, "hybrid": 1.2},
}

## §4.3 default weather before the first ledger roll (§4.7). Read-only: the
## simulation never writes `world.weather` from the movement path (T7/T8 own it).
const DEFAULT_WEATHER := "calm"

## Tolerance for the day boundary. Repeated float additions of a fractional
## cost (1/3 three times = 0.9999999999999999) must still tick the day; §4.3's
## `clock_fraction >= 1.0` is applied with this epsilon and the result clamped
## back into [0,1).
const CLOCK_EPSILON := 1.0e-9


# --- Speed (docs/20-* §4.4, §4.6, §4.7) ------------------------------------

## docs/20-* §4.7: multiplier for the current weather and the flagship's class.
## Unknown weather/class combinations fall back to 1.0 (fair/unknown water).
static func wind_factor(weather: String, ship_class: String) -> float:
	var table: Dictionary = WIND_FACTORS.get(weather, {})
	return float(table.get(ship_class, 1.0))


## docs/20-* §4.6: `crew < crew_min ? max(crew/crew_min, 0.25) : 1.0`.
## Crew and crew_min both come from the flagship (§4.4 composition rule).
static func crew_factor() -> float:
	var ship: Dictionary = FleetLib.flagship()
	if ship.is_empty():
		return 1.0
	var crew_min := FleetLib.ship_stat(ship, "crew_min")
	var crew := int(ship.get("crew", 0))
	if crew_min <= 0 or crew >= crew_min:
		return 1.0
	return maxf(float(crew) / float(crew_min), CREW_FACTOR_MIN)


## docs/20-* §4.4, exactly:
##   floor(slowest hull speed × wind × crew × (1 + seamanship bonus)), min 1.
## `base_speed` is the slowest ShipType.speed in the fleet ("Fleet-speed
## composition"); weather class, crew, crew_min and the seamanship bonus come
## from the flagship.
static func effective_speed() -> int:
	var base := FleetLib.slowest_speed()
	if base <= 0:
		# No fleet (or an unknown hull): §4.4's floor still applies.
		return MIN_SPEED
	var flagship: Dictionary = FleetLib.flagship()
	var ship_type: Dictionary = DataLoader.get_ship_type(
		str(flagship.get("ship_type_id", ""))
	)
	var ship_class := str(ship_type.get("class", "sail"))
	var weather := str(GameState.world.get("weather", DEFAULT_WEATHER))
	var raw := float(base) \
		* wind_factor(weather, ship_class) \
		* crew_factor() \
		* (1.0 + CharacterLib.speed_bonus())
	return maxi(int(floor(raw)), MIN_SPEED)


## docs/20-* §4.2: a successful tile move advances the clock by
## `1 / effective_speed` days.
static func move_cost() -> float:
	return 1.0 / float(effective_speed())


# --- Movement (docs/20-* §4.1, §4.2, §6) ------------------------------------

## True when the fleet at `from` may step onto `to`.
##
## * one of the 8 grid directions, never a teleport or a stay-put;
## * the target must be in bounds and passable (sea/coastal sea/port marker);
## * **no corner cutting:** a diagonal is blocked when either orthogonal
##   neighbour of the target corner is impassable (§4.2, §6 "blocked diagonal
##   between two land tiles"). This is the same rule the data validator's
##   BFS enforces, so the whole shipped map stays reachable.
##
## `map` defaults to `DataLoader.map` (handed over by the world scene,
## docs/90-* §9); tests pass a `MapLoader` instance directly.
static func is_move_legal(from: Vector2i, to: Vector2i, map = null) -> bool:
	var delta := to - from
	if delta == Vector2i.ZERO:
		return false
	if absi(delta.x) > 1 or absi(delta.y) > 1:
		return false
	var world_map = map if map != null else DataLoader.map
	if world_map == null:
		return false
	if not world_map.is_passable(to):
		return false
	if delta.x != 0 and delta.y != 0:
		if not world_map.is_passable(Vector2i(from.x + delta.x, from.y)):
			return false
		if not world_map.is_passable(Vector2i(from.x, from.y + delta.y)):
			return false
	return true


## Applies one fleet move to `to`.
##
## `from` defaults to `GameState.world_tile()`; the world scene passes its
## fallback tile explicitly before a run exists (docs/IMPLEMENT-Phase1.md T6-D).
## A rejected move changes nothing at all — position **and** clock stay
## bit-identical (§4.2 "Blocked moves cost nothing"; §6 "no clock cost").
## Returns true only when the fleet actually moved and the clock advanced.
##
## Deliberately state-only (§4.11 port entry is the caller's job): this never
## emits `port_entered`, never touches `known_ports`/`current_port` and never
## routes. The world scene does those after a successful step; T7's port-day
## actions can reuse this without triggering a docking sequence.
static func try_move(to: Vector2i, map = null, from = null) -> bool:
	var origin: Vector2i = GameState.world_tile() if from == null else Vector2i(from)
	if not is_move_legal(origin, to, map):
		return false
	GameState.set_world_tile(to)
	advance_clock(move_cost())
	return true


# --- Clock (docs/20-* §4.3) -------------------------------------------------

## Adds `days` to the fractional clock and ticks every completed day.
##
## Each tick: subtract 1 from the accumulator, `day += 1`, run the daily
## ledger, then emit `EventBus.day_advanced(day)` (§4.3 order). A single high-
## speed batch may complete several days, hence the `while`.
## Returns the number of days advanced (T6 tests count ticks; T7's port-day
## actions can reuse it).
static func advance_clock(days: float) -> int:
	if days <= 0.0:
		return 0
	var fraction := float(GameState.world.get("clock_fraction", 0.0)) + days
	var ticks := 0
	while fraction >= 1.0 - CLOCK_EPSILON:
		fraction = maxf(0.0, fraction - 1.0)
		GameState.day += 1
		ticks += 1
		_run_daily_ledger()
		EventBus.day_advanced.emit(GameState.day)
	# §4.3: the accumulator invariant is [0,1); the clamp above also absorbs
	# the tiny negative produced by the epsilon.
	GameState.world["clock_fraction"] = clampf(fraction, 0.0, 0.999999999)
	return ticks


# T7 HOOK: daily ledger steps 1-6 (docs/20-* §4.5) run here, in order,
# synchronously, before day_advanced is emitted.
static func _run_daily_ledger() -> void:
	pass  # T7 implements
