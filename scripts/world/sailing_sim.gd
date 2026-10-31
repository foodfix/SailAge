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
##   T7: the §5 constants block, ledger step 1 (consumption) and step 2
##       (wages), plus the `advance_port_day()` port-day entry point. The day
##       increment calls the ledger *before* `day_advanced` is emitted so every
##       listener sees a finished day (§4.3).
##   T8: ledger step 3 — the §4.7 zone/luck weather roll, the storm damage
##       application and the `last_day_storm` flag T9 reads.
##   T9 (this file today): ledger steps 4–6 — the §4.8.1 morale delta and the
##       `50-*` §4.3 sea-day XP, the §4.9 fail states (sinking, starvation,
##       scurvy) with their counters and game-over emission, the §4.8.3 mutiny
##       roll with its three resolutions, and §4.8.2 desertion on port entry.
##
## `_run_daily_ledger()` is the single seam for all six steps: they run in the
## §4.5 order, synchronously, once per day tick at sea **and** on port
## day-advances.

const CharacterLib := preload("res://scripts/player/character.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
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
## §4.11: base port sighting radius, Chebyshev, wrap-aware on x.
## (`50-*` §4.2 modifies it by navigation at the caller.)
const SIGHTING_RADIUS := 24
## §4.11 / `70-*` §4.4: the separate, shorter discovery sighting radius. Kept
## here because §5 is the single constants location for both radii — the
## engine value lives in `DiscoverySight.RADIUS`, which must agree.
const DISCOVERY_RADIUS := 18
## §4.1: `lat = 90 − y / 6` (6 tiles per degree, 1 tile = 10′ of latitude).
const TILES_PER_DEGREE := 6
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
## §4.7 storm damage is rounded with `ceil`; binary float noise makes exact
## integer products evaluate a hair above the integer (140 × 0.05 =
## 7.000000000000001), so the ceiling is taken on `raw − STORM_DAMAGE_EPSILON`.
## This can never drop a real fractional value across an integer boundary.
const STORM_DAMAGE_EPSILON := 1.0e-9

# --- Morale / fail-state / mutiny constants (docs/20-* §4.8–§4.9) -----------

## §4.8.1 daily delta table, exactly as documented. The at-sea baseline is −1;
## every other at-sea row is an *additional* −5 (they stack). In port the +5
## replaces the at-sea rows entirely.
const MORALE_SEA_DAILY := -1
const MORALE_SHORTFALL := -5
const MORALE_STORM := -5
const MORALE_UNPAID_WAGES := -5
const MORALE_PORT_DAILY := 5
## Morale is a 0–100 fleet value (§4.8).
const MORALE_MIN := 0
const MORALE_MAX := 100

## §4.9: daily crew loss while starved / scurvy-ridden, `max(1, floor(×0.05))`,
## never below [constant CREW_FLOOR].
const STARVATION_CREW_LOSS_FRACTION := 0.05
## §6: "Crew = 0 impossible: all crew-loss rules floor at 1".
const CREW_FLOOR := 1

## §4.8.3 mutiny modal: pay off at `crew × 20` gold; suppress costs 30% crew.
const MUTINY_PAY_PER_CREW := 20
const MUTINY_SUPPRESS_FRACTION := 0.30
## §4.8.3 morale outcomes of the three resolutions.
const MUTINY_PAY_MORALE := 50
const MUTINY_SUPPRESS_MORALE := 40
const MUTINY_FIZZLE_MORALE := 5

## §4.7 dialog queue order: weather damage → mutiny → desertion → greeting.
## Entries are stable-sorted by `kind` through [method sort_dialogs]; the rank
## table is the single source for that order.
##
## `sinking` sits between weather and mutiny because it is ledger step 5's
## consequence of step 3's storm damage (`40-*` §4.4): a hull that went down in
## the same storm must be reported before the crew's reaction to it. The doc
## names the other four explicitly; this fifth slot only orders ship-loss
## reports, which §4.7 does not list.
const DIALOG_ORDER := {
	"weather": 0,
	"sinking": 1,
	"mutiny": 2,
	"desertion": 3,
	"greeting": 4,
}

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

## §4.7 default weather before the first ledger roll (§4.7). Read-only: the
## simulation never writes `world.weather` from the movement path (T7/T8 own it).
const DEFAULT_WEATHER := "calm"

## §4.7 latitude weather bands (`20-*` §4.7). Band id → outcome →
## probability. Keys are the four **engine** ids `calm|fair|strong|storm`
## (never the display column names clear/overcast/windy/storm — §4.7's mapping
## is locked). Every row sums to 1.00; the values are the *base* table — the
## luck term (`50-*` §4.2) only rescales the storm entry and redistributes the
## freed mass (see [method zone_probabilities]).
##
## Band selection is by `|lat|` (symmetric N/S): doldrums < 8°, trade winds
## 8–30°, variables 30–40°, westerlies 40–60°, boreal 60–70° (+ everything
## beyond, see [method weather_zone_for]).
const WEATHER_ZONES := {
	"doldrums": {"calm": 0.30, "fair": 0.45, "strong": 0.15, "storm": 0.10},
	"trade_winds": {"calm": 0.15, "fair": 0.30, "strong": 0.20, "storm": 0.35},
	"variables": {"calm": 0.30, "fair": 0.40, "strong": 0.20, "storm": 0.10},
	"westerlies": {"calm": 0.10, "fair": 0.30, "strong": 0.35, "storm": 0.25},
	"boreal": {"calm": 0.15, "fair": 0.35, "strong": 0.30, "storm": 0.20},
}

## Fallback band for an unknown zone id (the doldrums row: the mildest table,
## and never reachable through [method weather_zone_for]).
const DEFAULT_WEATHER_ZONE := "doldrums"

## Outcome order used by the single uniform draw that maps a roll to an
## outcome. Fixed so a given seed yields the same sequence forever.
const WEATHER_OUTCOMES: Array[String] = ["calm", "fair", "strong", "storm"]

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


# --- Weather (docs/20-* §4.7, docs/50-* §4.2) -------------------------------

## Seeded RNG for the weather roll, injectable for deterministic tests via
## [method set_weather_seed]. Godot's default `RandomNumberGenerator.seed` is
## random, which is exactly what a real run wants and what a test replaces.
static var rng := RandomNumberGenerator.new()

## Flag for ledger step 4 (T9): true when the most recent tick rolled a storm.
## T9's morale step applies the §4.8.1 "at sea, storm day −5" row from this and
## only this; T8 never touches `GameState.morale` itself. Not persisted (the
## same rule as `last_day_shortfalls`: saving only happens in port).
static var last_day_storm: bool = false
## Latitude weather band the most recent roll used (`doldrums` / `trade_winds`
## / `variables` / `westerlies` / `boreal`); a diagnostic for tests, not saved.
static var last_weather_zone: String = ""

## §4.7 storm damage dealt in the most recent tick, `[{ship_type_id, points}]`.
## Step 3 records it so step 4/T9's world wiring can report each damaged hull
## (`world.storm_damage`). Not persisted (same rule as `last_day_storm`).
static var last_day_storm_damage: Array = []


## Reseeds the weather RNG so a test (or a replay) gets an identical sequence.
static func set_weather_seed(seed_value: int) -> void:
	rng.seed = seed_value


# --- Morale / fail-state state (docs/20-* §4.8–§4.9) -----------------------

## §4.9 starvation counter: number of consecutive shortfall days. A day with
## provisions in stock resets it to 0. Not persisted: it lives and dies with a
## day tick (saving happens in port, where the counter is already reset by the
## next supplied day). Exposed for tests.
static var starvation_days: int = 0
## §4.9 scurvy counter: the water mirror of [member starvation_days].
static var scurvy_days: int = 0
## §4.8.1 delta applied by the most recent step 4 (diagnostic/HUD, not saved).
static var last_morale_delta: int = 0
## Dialogs produced by the most recent tick, `[{kind, key, values, ...}]`, in
## the order they were raised. [method take_last_day_dialogs] hands them to the
## world scene, which shows them through the HUD's §4.7 queue. Not persisted.
static var last_day_dialogs: Array = []
## §4.8.3 mutiny awaiting a player decision (`{}` when none). Holding the offer
## here (rather than resolving immediately) is what lets the modal be pure UI:
## the three [method resolve_mutiny_pay] / [method resolve_mutiny_suppress] /
## [method resolve_mutiny_fizzle] entry points are the only resolutions.
static var pending_mutiny: Dictionary = {}
## Reason of the game-over that ended the run (`""` while alive). Sticky for the
## rest of the run; [method reset_ledger_state] clears it for a fresh fixture.
static var game_over_reason: String = ""

## Mutiny RNG, deliberately **separate** from the weather [member rng] so a
## seeded mutiny test is independent of how many weather rolls happened first
## (and vice versa). Injectable through [method set_mutiny_seed].
static var mutiny_rng := RandomNumberGenerator.new()


## Reseeds the mutiny RNG (the T8 `set_weather_seed` pattern, own stream).
static func set_mutiny_seed(seed_value: int) -> void:
	mutiny_rng.seed = seed_value


## Clears every transient ledger static: §4.9 counters, the game-over flag, the
## per-tick dialog list, a pending mutiny offer and the step 1–3 flags. Tests call
## it from their fixture builders so one scenario cannot leak into the next; a
## real new game is detected automatically by [method _maybe_reset_for_new_run].
static func reset_ledger_state() -> void:
	starvation_days = 0
	scurvy_days = 0
	last_morale_delta = 0
	last_day_dialogs = []
	pending_mutiny = {}
	game_over_reason = ""
	last_day_shortfalls = {"provisions": false, "water": false}
	last_day_unpaid_wages = false
	last_day_wages = 0
	last_day_storm = false
	last_day_storm_damage = []
	_last_run_day = -1


## Day of the last completed ledger tick (`-1` before the first one), used only
## to notice a new run: a run starts at day 1, so `GameState.day` going
## backwards means "new game or save load".
static var _last_run_day: int = -1


## A fresh run (`GameState.new_game()` resets `day` to 1) must not inherit the
## previous run's starvation counters or its sticky game-over flag. The sim
## observes the day rather than editing `GameState.new_game()` (an autoload T9
## does not own): **any** backwards jump from the last ticked day means "new
## game or a save load", and resetting transient statics there is harmless —
## none of them are persisted by design (`last_day_shortfalls`, the counters,
## the dialog buffer).
static func _maybe_reset_for_new_run() -> void:
	if _last_run_day >= 0 and GameState.day < _last_run_day:
		reset_ledger_state()


## True once [member game_over_reason] has been set; the ledger never emits a
## second game over for the same run.
static func is_game_over() -> bool:
	return not game_over_reason.is_empty()


## Returns the tick's dialogs in §4.7 order and clears the buffer, so a scene
## can only ever show them once.
static func take_last_day_dialogs() -> Array:
	var out := sort_dialogs(last_day_dialogs)
	last_day_dialogs = []
	return out


# --- Dialog queue order (docs/80-* §4.7) -----------------------------------

## Stable sort of dialog entries by [constant DIALOG_ORDER]:
## weather damage → mutiny → desertion → arrival greeting. Godot's built-in
## `sort_custom` is not stable, so this insertion sort is used instead: two
## entries of the same kind keep the order they were raised in.
static func sort_dialogs(entries: Array) -> Array:
	var out: Array = entries.duplicate()
	for index in range(1, out.size()):
		var entry = out[index]
		var rank := _dialog_rank(entry)
		var cursor := index - 1
		while cursor >= 0 and _dialog_rank(out[cursor]) > rank:
			out[cursor + 1] = out[cursor]
			cursor -= 1
		out[cursor + 1] = entry
	return out


static func _dialog_rank(entry) -> int:
	if entry is Dictionary:
		return int(DIALOG_ORDER.get(str(entry.get("kind", "")), DIALOG_ORDER.size()))
	return DIALOG_ORDER.size()


## Appends one dialog to this tick's buffer. `extra` carries the optional
## presentation fields the HUD's queue understands (`modal`, `confirm_key`, …).
static func _queue_dialog(kind: String, key: String, values: Dictionary = {}, extra: Dictionary = {}) -> void:
	var entry := {"kind": kind, "key": key, "values": values}
	for field in extra:
		entry[field] = extra[field]
	last_day_dialogs.append(entry)


## docs/20-* §4.7: latitude band id for a tile, from `lat = 90 − y/6` (§4.1,
## the locked addressing). Locked edges: `< 8` doldrums, `8 ≤ |lat| < 30` trade
## winds, `30 ≤ |lat| < 40` variables, `40 ≤ |lat| < 60` westerlies,
## `60 ≤ |lat| < 70` boreal. The function is **total**: `|lat| ≥ 70` also
## returns `boreal` because that is the ice band (`20-*` §4.1: `I` is
## impassable, so a real fleet never rolls there); `x` is irrelevant — the bands
## are zonally uniform, so the old map-column rule is gone.
static func weather_zone_for(tile: Vector2i) -> String:
	var latitude_degrees := 90.0 - float(tile.y) / float(TILES_PER_DEGREE)
	return weather_zone_for_latitude(latitude_degrees)


## The band lookup behind [method weather_zone_for], split out so a caller that
## already has a latitude (e.g. a port's `lat` in tests) need not synthesise a
## tile. Same locked edges.
static func weather_zone_for_latitude(latitude_degrees: float) -> String:
	var absolute := absf(latitude_degrees)
	if absolute < 8.0:
		return "doldrums"
	if absolute < 30.0:
		return "trade_winds"
	if absolute < 40.0:
		return "variables"
	if absolute < 60.0:
		return "westerlies"
	# 60 ≤ |lat|, including the impassable ice latitudes beyond 70° (§4.1).
	return "boreal"


## Outcome probabilities for `zone` with the §4.2 luck term applied.
##
## **Redistribution method.** The doc scales *only* the storm chance:
## `storm' = storm × (1 − luck/400)` (`Character.storm_chance_multiplier()`).
## The mass freed by that reduction, `base_storm − storm'`, is handed back to
## the three non-storm outcomes **proportionally to their own base weights**:
##
##     scale        = (1 − storm') / (1 − base_storm)
##     calm'/fair'/strong' = base × scale
##
## so the four entries still sum to exactly 1.0. Because every non-storm entry
## is multiplied by the *same* factor, their relative shares are unchanged:
## a calm day stays 0.30/0.90 of the doldrums' non-storm days (0.30 vs 0.45 vs
## 0.15) and only the absolute calm/fair/strong/storm split shifts, which is
## precisely what "luck reduces storm chance" means. At luck 0 the multiplier is
## 1.0, the scale is 1.0 and this returns the §4.7 table untouched. No new
## numbers are introduced.
static func zone_probabilities(zone: String) -> Dictionary:
	var base: Dictionary = WEATHER_ZONES.get(zone, WEATHER_ZONES[DEFAULT_WEATHER_ZONE])
	var base_storm := float(base["storm"])
	# Stats are clamped 1–100 (docs/50-* §4.2), so the multiplier is always in
	# [0.75, 1.0]; the clamp only keeps a hand-built test state from producing a
	# negative storm probability that would break the cumulative draw.
	var storm := clampf(
		base_storm * CharacterLib.storm_chance_multiplier(), 0.0, base_storm
	)
	# (1 − storm) / (1 − base_storm); the divisor is 1 − base_storm ∈ [0.65,
	# 0.90] for every band — never 0.
	var scale := (1.0 - storm) / (1.0 - base_storm)
	var out := {"storm": storm}
	for outcome in ["calm", "fair", "strong"]:
		out[outcome] = float(base[outcome]) * scale
	return out


## Rolls one day's weather for `tile` and returns `"calm"|"fair"|"strong"|
## "storm"`. A single uniform draw over the cumulative sums of
## [method zone_probabilities] (fixed order `WEATHER_OUTCOMES`), so the seeded
## sequence is stable.
static func roll_weather(tile: Vector2i) -> String:
	var zone := weather_zone_for(tile)
	var probabilities := zone_probabilities(zone)
	var roll := rng.randf()
	var cumulative := 0.0
	var outcome := "storm"
	for candidate in WEATHER_OUTCOMES:
		cumulative += float(probabilities.get(candidate, 0.0))
		if roll < cumulative:
			outcome = candidate
			break
	last_weather_zone = zone
	return outcome


## §4.7 storm damage for one hull: `ceil(durability_max × 0.05)`, with the
## luck mitigation (`50-*` §4.2: ×0.75 when luck ≥ 50) applied **before**
## rounding. The epsilon absorbs binary float noise (140 × 0.05 evaluates to
## 7.000000000000001, which must still ceil to 7, per §4.7's worked table).
static func storm_damage_for(durability_max: int) -> int:
	if durability_max <= 0:
		return 0
	var raw := float(durability_max) * STORM_DAMAGE_FRACTION \
		* CharacterLib.storm_damage_multiplier()
	return maxi(0, int(ceil(raw - STORM_DAMAGE_EPSILON)))


## Applies one storm day to every ship and returns the total damage dealt.
## Durability clamps at 0 and never goes negative; sinking itself is T9's step 5
## (it only needs to see the 0). Emits `fleet_changed` when anything changed.
static func apply_storm_damage() -> int:
	var total := 0
	last_day_storm_damage = []
	for ship in GameState.fleet:
		var before := int(ship.get("durability", 0))
		var damage := storm_damage_for(FleetLib.ship_stat(ship, "durability"))
		var after := maxi(0, before - damage)
		if after != before:
			ship["durability"] = after
			total += before - after
			last_day_storm_damage.append({
				"ship_type_id": str(ship.get("ship_type_id", "")),
				"points": before - after,
			})
	if total > 0:
		FleetLib.notify_changed()
	return total


## True when the last tick rolled a storm (convenience for T9/the HUD).
static func was_storm_last_day() -> bool:
	return last_day_storm


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


# --- Days of supply (docs/20-* §4.10, §4.11.2) -----------------------------

## `need = ceil(crew / RATION_SIZE)` units of provisions **and** the same of
## water per day at sea (docs/20-* §4.5, §4.10). Zero crew needs 0, which is
## why the caller must consult [method supply_block_reason] before dividing
## (a crewing failure is the sailing gate's business, not the formula's).
static func daily_need(crew: int) -> int:
	if crew <= 0:
		return 0
	return int(ceil(float(crew) / float(RATION_SIZE)))


## docs/20-* §4.10, the **locked** days-of-supply readout:
##   `days = min(floor(provisions / need), floor(water / need))`
##
## Evidence for the locked expectation: a starter caravel (15 crew, 45/45)
## needs `ceil(15 / 5) = 3` units of each per day, so both stacks give
## `floor(45 / 3) = 15` days — and §4.10's own worked example (60 + 60 units
## = 20 days) agrees. The formula is the single implementation for the
## provisioning prompt (`80-*` §4.6.1) and the fleet panel (`80-*` §4.5.1);
## nothing else may recompute it.
##
## Returns 0 when `need` is 0 (no crew — see [method supply_block_reason]).
static func supply_days(provisions: int, water: int, crew: int) -> int:
	var need := daily_need(crew)
	if need <= 0:
		return 0
	return mini(
		int(floor(float(maxi(provisions, 0)) / float(need))),
		int(floor(float(maxi(water, 0)) / float(need)))
	)


## Days of supply for the **pooled** fleet (docs/20-* §4.10 totals row).
static func fleet_supply_days() -> int:
	return supply_days(
		FleetLib.supplies("provisions"), FleetLib.supplies("water"),
		FleetLib.total_crew()
	)


## `ui_strings.json` key explaining why the fleet may not leave port, or `""`
## when the sailing gate is open (docs/20-* §4.11.2, locked):
##   * `total_crew >= 1`                  → else `port.sail.no_crew`
##   * `days >= 1` (the §4.10 formula)    → else `port.sail.no_supply`
##
## The key is returned rather than text (the engine never renders), and the
## crew check comes first because `days` is meaningless with no crew. Every
## caller — `PortScreen.set_sail()` and the provisioning prompt — asks this
## one function, so the button state and the refusal can never disagree.
static func supply_block_reason() -> String:
	if FleetLib.total_crew() < 1:
		return "port.sail.no_crew"
	if fleet_supply_days() < 1:
		return "port.sail.no_supply"
	return ""


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
	# A new run / save load clears the previous run's transient fail-state
	# statics before the game-over gate below can see them.
	_maybe_reset_for_new_run()
	# §4.9: a dead run's clock is frozen (S9 is on screen; nothing may tick).
	if is_game_over():
		return 0
	var fraction := float(GameState.world.get("clock_fraction", 0.0)) + days
	var ticks := 0
	while fraction >= 1.0 - CLOCK_EPSILON:
		fraction = maxf(0.0, fraction - 1.0)
		GameState.day += 1
		ticks += 1
		_run_daily_ledger()
		# §4.3 order: the economy step (stock drift + override expiry,
		# docs/30-* §4.2/§4.5) runs after the ledger and *before*
		# `day_advanced`, so every listener observes post-drift stocks.
		# The pure module returns the moved ports; the `market_changed`
		# emission stays with the caller (docs/90-* §5.1). Sea days and
		# port day-advances share this tick path (`advance_port_day` →
		# `advance_clock`), so both run the step.
		for changed_port in EconomyLib.day_tick():
			EventBus.market_changed.emit(str(changed_port))
		EventBus.day_advanced.emit(GameState.day)
		# §4.9: a run that just died does not tick further days; the world
		# scene shows S9 from the `game_over` signal.
		if is_game_over():
			break
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
## Steps 1–2 are T7's, step 3 is T8's, steps 4–6 are T9's. The chain short-
## circuits: step 4/5 return false when the run ended, so no later step and no
## later day runs (§4.9).
static func _run_daily_ledger() -> void:
	# §4.9: a finished run never ticks again (the world scene shows S9).
	if is_game_over():
		return
	_ledger_consumption()  # T7: step 1
	_ledger_wages()        # T7: step 2
	_ledger_weather()      # T8: step 3
	if _ledger_morale():   # T9: step 4
		if _ledger_fail_states():  # T9: step 5
			_ledger_mutiny()       # T9: step 6
	# Remember which day this run has reached (see [_maybe_reset_for_new_run]).
	_last_run_day = GameState.day


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


## §4.5 step 3 — weather roll (docs/20-* §4.7). Rolls for the coming day on
## the fleet's current tile, writes `GameState.world["weather"]` and, on a
## storm, damages every hull and raises [member last_day_storm] for T9's step 4.
##
## Stops at the damage: step 4 prices the storm's morale −5 (§4.8.1) and step 5
## turns a durability of 0 into a sinking (§4.9). Runs in port too (the roll is
## a property of the zone, not of being at sea); in port the storm contributes
## no morale row (the +5 replaces the at-sea rows).
static func _ledger_weather() -> void:
	var tile: Vector2i = GameState.world_tile()
	var outcome := roll_weather(tile)
	GameState.world["weather"] = outcome
	last_day_storm = outcome == "storm"
	if last_day_storm:
		apply_storm_damage()


# --- Ledger step 4: morale (docs/20-* §4.8.1, docs/50-* §4.3) --------------

## §4.5 step 4 — morale. Builds the §4.8.1 delta and applies it, clamped to
## [0, 100]. Returns true so [method _run_daily_ledger] can chain step 5/6
## (the seam would let a future rule abort the tick).
##
## The delta, with every at-sea row stacking:
##
## | condition                       | delta |
## |---------------------------------|-------|
## | at sea, fully supplied          | −1    |
## | at sea, provisions short        | −5    |
## | at sea, water short             | −5    |
## | at sea, storm day               | −5    |
## | in port (any day advance)       | +5, up to the port cap 80 |
## | wages unpaid (gold clamped)     | −5    |
##
## **In port the +5 replaces the sea rows** (port days are not sea days), and
## the cap is a ceiling on the *gain*, never on a loss: `min(morale + 5, 80)`
## only applies when it would raise the value, so a docked fleet at 20 climbs
## 25 → … → 80 and is never capped downwards. The unpaid-wages row has no
## at-sea qualifier in the doc, so it applies in port too (a crew in harbour
## that is not paid is just as mutinous).
##
## Also here, deferred from T7 (`50-*` §4.3): **+2 XP per day tick at sea
## only**, never on a port day advance.
static func _ledger_morale() -> bool:
	var delta := MORALE_SEA_DAILY if not in_port() else MORALE_PORT_DAILY
	var before := GameState.morale
	if not in_port():
		if bool(last_day_shortfalls.get("provisions", false)):
			delta += MORALE_SHORTFALL
		if bool(last_day_shortfalls.get("water", false)):
			delta += MORALE_SHORTFALL
		if last_day_storm:
			delta += MORALE_STORM
		# docs/50-* §4.3, deferred from T7: +2 XP per day tick **at sea only**.
		# Guarded so a fleetless/playerless debug fixture (docs/50-* §4.7
		# harbor relief) still ticks without an error.
		if not GameState.player.is_empty():
			CharacterLib.award_xp(2)
	if last_day_unpaid_wages:
		delta += MORALE_UNPAID_WAGES

	last_morale_delta = delta
	var after := before + delta
	if in_port() and delta > 0:
		# §4.8.1 "up to the port cap 80": the cap bounds the *rise*; a decrease
		# is never pulled back up to it.
		after = mini(after, maxi(before, MORALE_PORT_CAP))
	GameState.morale = clampi(after, MORALE_MIN, MORALE_MAX)
	return true


# --- Ledger step 5: fail states (docs/20-* §4.9) ---------------------------

## §4.5 step 5 — fail states, in the documented order: **sinking, starvation,
## scurvy**. Returns false when the run ended, so step 6 and every later day
## are skipped (§4.9: "game over fires at 7 days regardless", no further ticks).
static func _ledger_fail_states() -> bool:
	if _resolve_sinking():
		return false
	return _advance_starvation_and_scurvy()


## Sinking (docs/20-* §4.9, docs/40-* §4.4). A hull at durability ≤ 0:
## · non-flagship → hull and cargo lost, `world.ship_lost` dialog;
## · flagship with escorts → crew/provisions/water/cargo relocate to the next
##   ship up to capacity (overflow lost), it becomes flagship, and
##   `world.flagship_lost` is raised;
## · flagship alone → `game_over("sunk")`.
## Returns true when a game over fired.
static func _resolve_sinking() -> bool:
	# An empty fleet is the harbor-relief state (`50-*` §4.7), not a sinking:
	# there is no flagship to lose, so there is nothing to check (§6 "the
	# flagship always sails while the player lives").
	if GameState.fleet.is_empty():
		return false
	# Inspect the flagship first: losing it changes which hull is `fleet[1]`.
	var flagship: Dictionary = FleetLib.flagship()
	if int(flagship.get("durability", 0)) <= 0:
		if GameState.fleet.size() <= 1:
			return _fire_game_over("sunk")
		_relocate_flagship_to_escort()
		_queue_dialog("sinking", "world.flagship_lost")
		FleetLib.notify_changed()
		return false

	var lost_escort := false
	for index in range(GameState.fleet.size() - 1, 0, -1):
		var ship: Dictionary = GameState.fleet[index]
		if int(ship.get("durability", 0)) > 0:
			continue
		GameState.fleet.remove_at(index)
		lost_escort = true
	if lost_escort:
		_queue_dialog("sinking", "world.ship_lost")
		FleetLib.notify_changed()
	return false


## docs/40-* §4.4 flagship replacement: the next ship takes the crew (capped at
## its `crew_max`), then provisions/water/goods up to its free capacity; what
## does not fit is lost with the old hull (the overflow is reported by the
## dialog, never silently — §6).
static func _relocate_flagship_to_escort() -> void:
	var old: Dictionary = GameState.fleet[0]
	var next: Dictionary = GameState.fleet[1]
	var crew := int(old.get("crew", 0))
	next["crew"] = mini(int(next.get("crew", 0)) + crew, FleetLib.ship_stat(next, "crew_max"))
	for kind in ["provisions", "water"]:
		var room := maxi(0, FleetLib.free_capacity(next))
		var moved := mini(int(old.get(kind, 0)), room)
		next[kind] = int(next.get(kind, 0)) + moved
	var old_cargo: Dictionary = old.get("cargo", {})
	var next_cargo: Dictionary = next.get("cargo", {})
	for good_id in old_cargo:
		var room := maxi(0, FleetLib.free_capacity(next))
		if room <= 0:
			break
		var moved := mini(int(old_cargo[good_id]), room)
		if moved > 0:
			next_cargo[good_id] = int(next_cargo.get(good_id, 0)) + moved
	next["cargo"] = next_cargo
	GameState.fleet.remove_at(0)


## §4.9 starvation/scurvy counters and their crew loss. Each shortfall day
## advances its counter by one and costs `max(1, floor(crew × 0.05))` crew
## (floored at 1, §6); both counters reset on the first fully-supplied day.
## The morale −5 is step 4's shortfall row — deliberately **not** re-applied
## here. Returns false when a counter reached [constant STARVATION_LIMIT_DAYS].
static func _advance_starvation_and_scurvy() -> bool:
	var provisions_short: bool = bool(last_day_shortfalls.get("provisions", false))
	var water_short: bool = bool(last_day_shortfalls.get("water", false))
	# §4.9: "counters reset to 0 on the first fully-supplied day" — both.
	if not provisions_short and not water_short:
		starvation_days = 0
		scurvy_days = 0
		return true
	if provisions_short:
		starvation_days += 1
		_apply_crew_loss(STARVATION_CREW_LOSS_FRACTION)
	if water_short:
		scurvy_days += 1
		_apply_crew_loss(STARVATION_CREW_LOSS_FRACTION)
	if starvation_days >= STARVATION_LIMIT_DAYS:
		return _fire_game_over("starvation")
	if scurvy_days >= STARVATION_LIMIT_DAYS:
		return _fire_game_over("scurvy")
	return true


## `crew -= max(1, floor(crew × fraction))`, never below [constant CREW_FLOOR]
## (§6 "all crew-loss rules floor at 1"). Returns the crew actually lost.
static func _apply_crew_loss(fraction: float) -> int:
	var ship: Dictionary = FleetLib.flagship()
	if ship.is_empty():
		return 0
	var crew := int(ship.get("crew", 0))
	if crew <= CREW_FLOOR:
		return 0
	var loss := maxi(1, int(floor(float(crew) * fraction)))
	var after := maxi(CREW_FLOOR, crew - loss)
	ship["crew"] = after
	FleetLib.notify_changed()
	return crew - after


# --- Ledger step 6: mutiny (docs/20-* §4.8.3) ------------------------------

## §4.5 step 6 — mutiny check. At sea only, below [constant MUTINY_THRESHOLD]:
## one draw of the **dedicated** [member mutiny_rng] against
## `MUTINY_CHANCE_PER_DAY × Character.mutiny_multiplier()`. A hit stores the
## offer in [member pending_mutiny] and queues the `world.mutiny.text` modal in
## the §4.7 dialog order; the player's choice is resolved by the three pure
## `resolve_mutiny_*` entry points ([method resolve_mutiny_pay],
## [method resolve_mutiny_suppress], [method resolve_mutiny_fizzle]).
##
## A second offer never stacks: while one is pending the check is skipped, so
## "modals never simultaneous" (§4.7) holds even across several days.
static func _ledger_mutiny() -> void:
	if in_port() or is_game_over():
		return
	if not pending_mutiny.is_empty():
		return
	if not mutiny_is_possible():
		return
	var chance := MUTINY_CHANCE_PER_DAY * CharacterLib.mutiny_multiplier()
	if mutiny_rng.randf() >= chance:
		return
	pending_mutiny = mutiny_offer()
	# The offer travels with the dialog entry so the HUD can render the Pay price
	# and disable the impossible buttons without reading sim state itself
	# (docs/90-* §7: the HUD never mutates or quarantines game state).
	_queue_dialog(
		"mutiny", "world.mutiny.text", {},
		{"mutiny": true, "offer": pending_mutiny.duplicate()}
	)


## True when the §4.8.3 check would roll at all: at sea and strictly below
## [constant MUTINY_THRESHOLD]. A fleet at exactly 20 is **not** mutinous
## (the doc's condition is `< 20`).
static func mutiny_is_possible() -> bool:
	return not in_port() and GameState.morale < MUTINY_THRESHOLD


## The current §4.8.3 offer as `{crew, gap, cost, can_pay, can_suppress,
## can_fizzle}`; empty when no mutiny is pending. `can_fizzle` is true exactly
## when neither other option is possible (unpaid **and** crew already at 1).
static func mutiny_offer() -> Dictionary:
	var crew := FleetLib.total_crew()
	var cost := crew * MUTINY_PAY_PER_CREW
	var can_pay := GameState.gold >= cost
	var can_suppress := crew > CREW_FLOOR
	return {
		"crew": crew,
		"gap": maxi(0, cost - GameState.gold),
		"cost": cost,
		"can_pay": can_pay,
		"can_suppress": can_suppress,
		"can_fizzle": not can_pay and not can_suppress,
	}


## §4.8.3 "Pay off": `gold -= crew × 20`, morale = 50. False (state untouched)
## when nothing is pending or the purse is short; the modal disables the button
## with `can_pay`, so false only happens on a race or a direct test call.
static func resolve_mutiny_pay() -> bool:
	if pending_mutiny.is_empty():
		return false
	var offer := mutiny_offer()
	if not bool(offer["can_pay"]):
		return false
	GameState.gold = maxi(0, GameState.gold - int(offer["cost"]))
	GameState.morale = clampi(MUTINY_PAY_MORALE, MORALE_MIN, MORALE_MAX)
	pending_mutiny = {}
	EventBus.gold_changed.emit(GameState.gold)
	return true


## §4.8.3 "Suppress": `crew -= max(1, floor(crew × 0.30))` (floored at 1),
## morale = 40. False when nothing is pending or the crew is already at 1.
static func resolve_mutiny_suppress() -> bool:
	if pending_mutiny.is_empty():
		return false
	var offer := mutiny_offer()
	if not bool(offer["can_suppress"]):
		return false
	var ship: Dictionary = FleetLib.flagship()
	var crew := int(ship.get("crew", 0))
	ship["crew"] = maxi(CREW_FLOOR, crew - maxi(1, int(floor(float(crew) * MUTINY_SUPPRESS_FRACTION))))
	GameState.morale = clampi(MUTINY_SUPPRESS_MORALE, MORALE_MIN, MORALE_MAX)
	pending_mutiny = {}
	FleetLib.notify_changed()
	return true


## §4.8.3 fizzle: neither pay nor suppress is possible, the crowd disperses and
## morale rises by 5 (clamped to [0, 100]). Always succeeds when pending.
static func resolve_mutiny_fizzle() -> void:
	if pending_mutiny.is_empty():
		return
	GameState.morale = clampi(GameState.morale + MUTINY_FIZZLE_MORALE, MORALE_MIN, MORALE_MAX)
	pending_mutiny = {}
	_queue_dialog("mutiny", "world.mutiny.fizzle")


# --- Desertion on port entry (docs/20-* §4.8.2) ----------------------------

## Every port entry with morale < [constant DESERTION_THRESHOLD] costs
## `loss = max(1, floor(crew × 0.10 × Character.desertion_multiplier()))` crew,
## floored at 1. Returns the crew lost (0 when morale is 40+ — the check is
## `< 40`, so exactly 40 is safe).
##
## Pure state, no dialog: the world scene's port-entry sequence queues the
## `world.desertion` message in §4.7 order, so a headless test can drive the
## loss without a scene.
static func apply_desertion() -> int:
	if GameState.morale >= DESERTION_THRESHOLD:
		return 0
	var ship: Dictionary = FleetLib.flagship()
	if ship.is_empty():
		return 0
	var crew := int(ship.get("crew", 0))
	if crew <= CREW_FLOOR:
		return 0
	var raw := float(crew) * DESERTION_FRACTION * CharacterLib.desertion_multiplier()
	var loss := maxi(1, int(floor(raw)))
	var after := maxi(CREW_FLOOR, crew - loss)
	ship["crew"] = after
	var lost := crew - after
	if lost > 0:
		FleetLib.notify_changed()
	return lost


# --- Game over (docs/20-* §4.9) --------------------------------------------

## Emits `EventBus.game_over(reason)` once and records it. Always true so a
## fail-state check can `return _fire_game_over(...)`. No save is written or
## deleted (§4.9); the world scene listens and shows S9.
static func _fire_game_over(reason: String) -> bool:
	if is_game_over():
		return true
	game_over_reason = reason
	EventBus.game_over.emit(reason)
	return true
