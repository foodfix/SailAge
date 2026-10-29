class_name SailingSim
extends RefCounted
## Sailing simulation core (docs/20-WORLD-AND-SAILING.md §4).
##
## Pure logic, no node references (docs/90-ARCHITECTURE.md §4): every function
## is static and reads/mutates `GameState` through the singleton, so movement,
## the clock and the speed formula are unit-testable headless.
##
## Ownership split (docs/IMPLEMENT-Phase1.md T6/T7/T8/T9):
##   T6: movement validation, applying a move, the fractional clock
##       accumulator + day boundary, `effective_speed()` and `move_cost()`.
##   T7 (this file today): the §5 constants block, ledger step 1 (consumption)
##       and step 2 (wages), plus the `advance_port_day()` port-day entry
##       point. The day increment calls the ledger *before* `day_advanced` is
##       emitted so every listener sees a finished day (§4.3).
##   T8: ledger step 3 (weather roll, §4.7).
##   T9: ledger steps 4–6 (morale, fail states, mutiny, §4.8–§4.9).
##
## `_run_daily_ledger()` is the single seam for all six steps: they run in the
## §4.5 order, synchronously, once per day tick at sea **and** on port
## day-advances.

const CharacterLib := preload("res://scripts/player/character.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")

# --- Ledger constants (docs/20-* §5 "sailing_constants") -------------------
# §5 is the single source of truth: these are GDScript constants because the
# §5 JSON block is illustrative for docs validators, not a runtime data file.

## §4.5 step 2: gold per crew member per day (locked).
const CREW_WAGE_DAILY := 2
## §4.5 step 1 / §4.10: one unit feeds/waters this many crew for one day.
const RATION_SIZE := 5
## §4.10: locked supply prices, unaffected by supply/demand (supplies are not
## trade goods and never appear in `goods.json`).
const PROVISIONS_PRICE := 2
const WATER_PRICE := 1
## §4.11: base sighting radius (`50-*` §4.2 modifies it by navigation).
const SIGHTING_RADIUS := 8
## §4.8: new-game morale and the in-port ceiling.
const MORALE_START := 70
const MORALE_PORT_CAP := 80
## §4.9: fail-state counter limit (starvation and scurvy).
const STARVATION_LIMIT_DAYS := 7
## §4.8.3: mutiny trigger threshold and per-day chance at sea.
const MUTINY_THRESHOLD := 20
const MUTINY_CHANCE_PER_DAY := 0.25
## §4.8.2: desertion on port entry below this morale.
const DESERTION_THRESHOLD := 40
const DESERTION_FRACTION := 0.10
## §4.7: storm damage as a fraction of max durability (`ceil(max × 0.05)`).
const STORM_DAMAGE_FRACTION := 0.05

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


## Port-side day advance (docs/20-* §4.3: "In port, the clock does not advance
## except by explicit actions that cost a day"; odd jobs, rest). It runs the
## **same** ledger as a sea day — crews eat and wages are paid in port too
## (§4.5 "runs once per day tick at sea and on port day-advances").
## Returns the number of days advanced (always 1 unless a caller batches).
static func advance_port_day() -> int:
	return advance_clock(1.0)


## True while docked (docs/20-* §4.3/§4.11). The ledger is shared between the
## two cases; only at-sea-only rules (morale −1, +2 XP/day, mutiny) branch on
## this.
static func in_port() -> bool:
	return GameState.current_port != null


# --- Daily ledger (docs/20-* §4.5, strict order) ----------------------------

## Results of the most recent ledger tick. Step 1 records shortages here and
## T9's steps 4–6 consume them; keeping them as class statics avoids adding
## transient keys to the §8.1 save block (same pattern as
## `Character.pending_levelup`). They are deliberately *not* persisted: a
## pending shortage never survives a save (saving only happens in port).
static var last_day_shortfalls: Dictionary = {"provisions": false, "water": false}
## Step 2: true when wages exceeded the purse and gold was clamped to 0.
## T9's morale step applies the "wages unpaid −5" row (§4.8.1).
static var last_day_unpaid_wages: bool = false
## Step 2: wages charged in the most recent tick (HUD/tests; not persisted).
static var last_day_wages: int = 0


## Daily ledger, §4.5 order. Called by [method advance_clock] once per completed
## day, *before* `day_advanced` is emitted, so every listener observes a
## finished day (§4.3).
##
## T7 implements steps 1–2 only. Steps 3–6 are marked hooks below and must be
## inserted in place — do not restructure this function.
static func _run_daily_ledger() -> void:
	_ledger_consumption()  # T7: step 1
	_ledger_wages()        # T7: step 2
	# T8 HOOK: step 3 weather roll (docs/20-* §4.7) — roll for the coming day,
	#   write `GameState.world["weather"]`, apply storm damage + the storm
	#   morale flag that step 4 reads.
	# T9 HOOK: step 4 morale update (docs/20-* §4.8.1) — reads
	#   `last_day_shortfalls`, `last_day_unpaid_wages`, `in_port()` and the
	#   weather rolled in step 3; applies the in-port +5 up to MORALE_PORT_CAP
	#   and clamps to [0, 100]. The `50-*` §4.3 "+2 XP per day tick at sea"
	#   award belongs here too (at sea only, never on port day-advances).
	# T9 HOOK: step 5 fail-state checks (docs/20-* §4.9) — starvation, scurvy
	#   (counters fed by `last_day_shortfalls`), then sinking.
	# T9 HOOK: step 6 mutiny check (docs/20-* §4.8.3) — at sea only,
	#   `GameState.morale < MUTINY_THRESHOLD`, `MUTINY_CHANCE_PER_DAY`.


## §4.5 step 1 — consumption. `need = ceil(total_crew / RATION_SIZE)` units of
## provisions **and** the same of water; stock is drained flagship-first
## (`40-*` §4.2 pooling) and a shortage is recorded for step 5. The fail-state
## consequence (crew loss, counters) is T9's; this step only eats.
static func _ledger_consumption() -> void:
	var crew := FleetLib.total_crew()
	var need := 0 if crew <= 0 else int(ceil(float(crew) / float(RATION_SIZE)))
	last_day_shortfalls = {"provisions": false, "water": false}
	if need <= 0:
		return  # Crew 0: nothing to feed, no shortage (§4.9 crew floor).
	var ate := false
	for kind in ["provisions", "water"]:
		var stock := FleetLib.supplies(kind)
		if stock < need:
			last_day_shortfalls[kind] = true
		# Clamp the drain at the stock on hand: a shortage consumes to 0.
		if FleetLib.remove_supplies(kind, mini(need, stock)) > 0:
			ate = true
	if ate:
		FleetLib.notify_changed()


## §4.5 step 2 — wages. `gold -= total_crew × CREW_WAGE_DAILY + Σ
## officer.wage_daily`; a negative result clamps to 0 and raises the unpaid
## flag (§4.8.1 "wages unpaid −5"). Exactly `wages == gold` is still paid (the
## doc's condition is `< 0`, not `≤ 0`).
##
## Writes `GameState.gold` directly rather than through `GameState.add_gold()`
## because that helper does not clamp (docs/20-* §4.9) and emits the
## pre-clamp value: the HUD must never see negative gold. One `gold_changed`
## is emitted with the clamped value, and only when gold actually changed.
static func _ledger_wages() -> void:
	var wages := FleetLib.total_crew() * CREW_WAGE_DAILY \
		+ CharacterLib.officer_wages()
	last_day_wages = wages
	last_day_unpaid_wages = false
	if wages <= 0:
		return
	var before := GameState.gold
	if before - wages < 0:
		last_day_unpaid_wages = true
	GameState.gold = maxi(0, before - wages)
	if GameState.gold != before:
		EventBus.gold_changed.emit(GameState.gold)
