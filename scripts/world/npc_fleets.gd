class_name NpcFleets
extends RefCounted
## The living NPC fleet ecology (Phase 5) — docs/60-COMBAT.md §4.1, §4.11.11
## (lanes/movement/contact), §4.11.11.5 (spatial index + perf gates), §4.12.3
## (THE API table — implemented exactly); docs/30-PORTS-AND-TRADE.md §4.4 (the
## joint profit-per-day trader decision); docs/20-WORLD-AND-SAILING.md §4.3
## (the tick runs after `day_advanced`); docs/10-DATA-SCHEMA.md §4.14 (the
## built route artifact) / §4.15 (the fleet save shape).
##
## Replaces the retired Phase-2 3-marker system (`encounters.gd`, deleted by
## task J; the rename `hostile_fleets` → `npc_fleets` with `kind` → `role` is
## part of the same sweep).
##
## **Pure** in the house sense (docs/90-* §4, mirroring `economy.gd`):
## RefCounted, no node references, headless-testable. It works on two pieces
## of `GameState` and nothing else:
##
##   * `GameState.npc_fleets` — the §4.11.11/§4.15 save block, the **only**
##     place fleets live (this module mutates that array in place);
##   * read-only: `GameState.day`, `world_tile()`, `npc_preset`,
##     `player.reputation`.
##
## NPC traders price through [class Economy]/[class TradeEngine] directly and
## move REAL stocks via `Economy.apply_trade` — they have **no gold ledger**
## (docs/30-* §4.4). Stock moves are recorded in [member moved_ports]; the
## caller (the world scene) emits `EventBus.market_changed` per port — the
## pure module never emits (docs/90-* §5.1 signal discipline).
##
## RNG discipline (§4.11.11): all randomness comes from the Phase-2 seeded
## formula family (`day × 1000003 + x × 7919 + y × 104729`) keyed by the
## fleet's own persisted [member Fleet seed][fleet "seed"] — there is **no
## global RNG state** and every draw is reproducible from saved fields alone.
## The one instance-level stream ([member _rng]) exists only as the
## [method reset_rng] test seam.
##
## **The spatial index is a review gate** (docs/60-* §4.11.11.5): EVERY
## "within N tiles" check in this module goes through the wrap-aware
## cell-bucket hash ([method _within]) — occupancy, contact-1, prey-10,
## escort-10, patrol-zone-15, risk-sample-5. Nothing scans the fleet array
## per distance check; each query visits only the buckets its radius
## touches, so a day tick is linear in fleet count.

const EconomyLib := preload("res://scripts/port/economy.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const PaletteLib := preload("res://scripts/palette.gd")
## Pursuit A* (the only runtime pathfinding; docs/60-* §4.11.11.1).
const FleetPathLib := preload("res://scripts/world/fleet_path.gd")

# --- Locked numbers (docs/60-* §4.1, §4.11.11.1–.2) -------------------------

## §4.11.11 fleet roles.
const TRADER := "trader"
const COASTER := "coaster"
const PATROL := "patrol"
const COURIER := "courier"
const PRIVATEER := "privateer"
const PIRATE := "pirate"
const HUNTER := "hunter"
const TREASURE := "treasure"
## Spawn/trickle fill order (task-owned): economy roles first, raiders last,
## so the global cap can never starve traders for pirates.
const FILL_ORDER: Array[String] = [
	TRADER, COASTER, PATROL, COURIER, PRIVATEER, PIRATE, HUNTER,
]

## §4.11.11.1: contact is measured at Chebyshev distance 1.
const CONTACT_DISTANCE := 1
## §4.11.11.1 / `70-*` §4.5: a hunter is hostile only at or below this
## reputation (the player holds a bounty).
const NAVY_HOSTILE_REPUTATION := -50
## §4.10 pursuit cooldown (carried over, inclusive reading): a battle on day D
## stores `D + 1`; the fleet holds through D+1 and moves again on D+2; while
## on cooldown it raises no contact.
const PURSUIT_COOLDOWN_DAYS := 1
## §4.11.11.2 / `70-*` §4.5: the battle-start piracy charge owned by
## `Bounty.apply_piracy` (−20 owner / +2 its rivals). Kept here as the same
## pinned number so the funnel and the engine constant can be cross-checked.
const PIRACY_REPUTATION := -20
## §4.1.1 patrol zone radius — the pinned 15-tile navy zone, reused for the
## daily unpatrolled-zone recount and the escorted-trader rule.
const ZONE_RADIUS := 15
## §4.1.1: same-nation traders within Chebyshev 10 of a patrol are escorted;
## pirates prefer prey within Chebyshev 10.
const PREY_RADIUS := 10
const ESCORT_RADIUS := 10
## §4.11.11.1: pirate/privateer anchors sit within Chebyshev 3 of chokepoint
## tiles; prey is engaged within 5 and released beyond 8 (the 5/8 hysteresis
## — the chase itself is task K).
const ANCHOR_RADIUS := 3
const CHASE_ON_RADIUS := 5
const CHASE_OFF_RADIUS := 8
## §4.11.11.1 hunter-intel rule (locked): the chase opens inside Chebyshev 15,
## is lost beyond Chebyshev 20 (the 15/20 hysteresis), and the intel-port
## loiter lasts 10 days.
const HUNTER_CHASE_ON := 15
const HUNTER_CHASE_OFF := 20
const HUNTER_LOITER_DAYS := 10
## Hunter states (persisted, docs/60-* §4.11.11.1 hunter intel): sailing to
## the intel port, camping its approaches, chasing, or routing home.
const HUNTER_STATE_INTEL := "intel"
const HUNTER_STATE_LOITER := "loiter"
const HUNTER_STATE_CHASE := "chase"
const HUNTER_STATE_HOME := "home"
## `30-*` §4.4 trader decision: destinations are own-nation ports within
## Chebyshev 60 (wrap-aware).
const CANDIDATE_RADIUS := 60
## `30-*` §4.4 risk discount: a hostile fleet within Chebyshev 5 of a sample
## point of the candidate lane path halves the score.
const RISK_RADIUS := 5
const RISK_MULT := 0.5
## `30-*` §4.4: specialty multiplier and the seeded noise band.
const SPEC_MULT := 1.5
const NOISE_MIN := 0.8
const NOISE_MAX := 1.25
## Port dwell: 2 days docked at route endpoints (docs/60-* §4.1.1).
const DWELL_DAYS := 2
## `60-*` §4.11.11.2 composition: the role→cannon-budget map that replaces
## §4.11.3 step 3's value for its kinds (+ `floor(day / 30)`, applied inside
## `AiFleet.cannon_budget`).
const COMPOSITION_BUDGETS := {
	TRADER: 6, COASTER: 2, COURIER: 0, PATROL: 30, PRIVATEER: 20, PIRATE: 20,
}

## --- Task-owned constants (the docs left these open; see the task J report).
##
## Lane-days divisor for the trader score: `lane_days = tile length / 20`.
## The encounters system had no per-day tile rate to stay consistent with,
## so the 20 tiles/day default named by the task is pinned here. Fleet
## *stepping* stays at the §4.11.11.1 pin of 1 tile/day — this constant only
## ranks candidate journeys against each other.
const LANE_TILES_PER_DAY := 20
## Hold capacities (fleet dicts carry cargo only — no ship list). The
## coaster's ≤ 10 hold and ≤ 5-unit calls are doc-pinned (`30-*` §4.4); the
## trader capacity is task-owned headroom above the 30-unit call cap so a
## small unsellable remainder can never wedge a journey.
const TRADER_HOLD_CAPACITY := 40
const COASTER_HOLD_CAPACITY := 10
## Risk-sample stride/count over a candidate route's tile path (`30-*` §4.4:
## "a few bucket queries", deterministic).
const RISK_SAMPLE_STRIDE := 8
const RISK_SAMPLE_MAX := 8
## Global cap slack above the core budgets: 6 treasure + ≤ 6 hunters + 4
## spare at normal (docs/60-* §4.1.1: 272 core ⇒ global cap 288).
const GLOBAL_CAP_SLACK := 16
## The pirate share of the 272 core: the doc's computed ≈ 25
## (272 − 247 persistent non-pirate roles). The daily unpatrolled-zone
## recount drives the *demand* up to `8 + zones`, but the ecology is capped
## here so the core cap and the 288 global cap hold exactly at normal.
const PIRATE_CORE_CAP := 25
## Bucket size of the wrap-aware cell-bucket spatial index
## (docs/60-* §4.11.11.5). 16 keeps a radius-15 patrol-zone query at 4×4
## buckets while a radius-1 contact query touches 1.
const BUCKET_SIZE := 16
## Route-cache key separator.
const ROUTE_SEP := ">"

## §4.11.1 seed formula constants — the whole module's randomness family.
const SEED_DAY_MULT := 1000003
const SEED_X_MULT := 7919
const SEED_Y_MULT := 104729

## "No cell" sentinel for positions off the map.
const NO_CELL := Vector2i(-1, -1)

## §4.10 / `60-*`: the battle outcome that leaves the fleet in place (the
## retreat branch of the §4.12.4 aftermath).
const RETREAT := "retreat"

## Trader/coaster destination-choice cap per decision (a guard, never a code
## path: 6 nations × ≤ 20 ports keeps the candidate loop tiny).
const CANDIDATE_SCAN_LIMIT := 512


# --- Instance state ---------------------------------------------------------

## Day of the last tick that ran the day's work (docs/20-* §4.3: one NPC fleet
## tick per day). The world scene sets this to `GameState.day` when it adopts
## the sim so re-opening the map never re-ticks the day.
var last_tick_day: int = -1

## Port ids whose stock the last tick moved (docs/30 §4.4: the caller emits
## `EventBus.market_changed` per port — the module never emits).
var moved_ports: Array = []

## Config block (`{npc_config, preset}`) and the resolved preset id.
var _config: Dictionary = {}
var _preset: String = "normal"

var _rng := RandomNumberGenerator.new()
var _rng_seeded: bool = false
var _id_seq: int = 0

## Route cache: `"<a>><b>" → {"legs": […], "length": int, "path": [Vector2i]}`.
## The lane network is a per-run constant (one shipped map, one built
## artifact), so the cache is shared across instances — the world scene, a
## palace-screen bounty spawn and every test fixture route identically.
static var _route_cache: Dictionary = {}
## Lane-network caches (built lazily from the built artifact).
static var _net_ready: bool = false
static var _width: int = 2160
static var _height: int = 1080
static var _lane_paths: Dictionary = {}
static var _lane_ids_sorted: Array = []
static var _spoke_paths: Dictionary = {}
static var _spoke_lane: Dictionary = {}
static var _tile_lanes: Dictionary = {}
static var _node_tiles: Array = []
static var _node_index: Dictionary = {}
static var _adjacency: Dictionary = {}
## Daily unpatrolled-zone count (the pirate budget's demand term), plus the
## day it was computed for — recounted lazily so `budget_for(PIRATE)` and
## `core_cap()` answer correctly before the world scene's first tick.
var _unpatrolled_zones: int = 0
var _zones_day: int = -1

## Per-owner spawn-failure marks for the current day (`"role|nation" → day`),
## so a failed draw is skipped until tomorrow instead of spinning.
var _skip: Dictionary = {}

## Runtime-only hunter pursuit plans (`fleet_id → {target, path}`); never
## saved — a fresh plan from the same state reproduces the same chase.
var _hunter_paths: Dictionary = {}

## Wrap-aware cell-bucket index (docs/60-* §4.11.11.5): `bucket_key →
## [fleet_id, …]` and `fleet_id → fleet dict` (references into
## `GameState.npc_fleets`). Rebuilt lazily after any mutation — a rebuild is
## O(fleets), which keeps every query bucket-local without stale-entry bugs.
var _buckets: Dictionary = {}
var _by_id: Dictionary = {}
var _index_dirty: bool = true

## Per-nation caches of the derived port/goods lists (data is a per-run
## constant; `reset_caches()` clears them with the route tables).
static var _ports_cache: Dictionary = {}
static var _goods_cache: Dictionary = {}
## Per-(role|nation) anchor-tile cache — the tile→lanes map is a per-run
## constant, so the junction candidate list is built once per owner.
var _anchor_cache: Dictionary = {}

## Handoff from [_hunter_anchor] to [_build_fleet]: the drawn home port.
var _hunter_home: String = ""


## `config = {npc_config, preset}` (docs/60-* §4.12.3); computes the §4.1.1
## budgets × preset lazily on demand. An empty config falls back to
## `DataLoader.npc_config` + `GameState.npc_preset` (the guarded-module
## convention: `new()` must work with zero arguments).
func _init(config: Dictionary = {}) -> void:
	_config = config.duplicate(true)
	_preset = str(_config.get("preset", GameState.npc_preset))


# --- Preset & budgets (docs/60-* §4.1.1, docs/10-* §4.10) -------------------

func _budgets() -> Dictionary:
	var npc_config: Dictionary = _config.get("npc_config", DataLoader.npc_config)
	return npc_config.get("budgets", {}) if npc_config.get("budgets", {}) is Dictionary else {}


func _flow() -> Dictionary:
	var npc_config: Dictionary = _config.get("npc_config", DataLoader.npc_config)
	return npc_config.get("flow", {}) if npc_config.get("flow", {}) is Dictionary else {}


## The live preset multiplier (docs/10-* §4.10): `deserted` is 0.0 — zero NPC
## spawns and zero contacts.
func multiplier() -> float:
	var npc_config: Dictionary = _config.get("npc_config", DataLoader.npc_config)
	var presets: Dictionary = npc_config.get("presets", {}) \
		if npc_config.get("presets", {}) is Dictionary else {}
	var value = presets.get(_preset, 1.0)
	return float(value) if value is float or value is int else 1.0


## True while the density dial silences the whole ecology.
func is_deserted() -> bool:
	return multiplier() <= 0.0


func _port_counts() -> Dictionary:
	var counts: Dictionary = {}
	for port in DataLoader.ports_list:
		var nation_id := str((port as Dictionary).get("nation_id", ""))
		if nation_id.is_empty():
			continue
		counts[nation_id] = int(counts.get(nation_id, 0)) + 1
	return counts


## The nation's own ports, ids sorted (deterministic iteration everywhere).
## Cached per nation — `ports.json` is a per-run constant and this list is
## read on every departure decision and spawn.
func nation_ports(nation_id: String) -> Array[String]:
	var cached: Array = _ports_cache.get(nation_id, [])
	if not cached.is_empty():
		var out: Array[String] = []
		for value in cached:
			out.append(str(value))
		return out
	var out: Array[String] = []
	for port in DataLoader.ports_list:
		var id := str((port as Dictionary).get("id", ""))
		if id.is_empty() or str((port as Dictionary).get("nation_id", "")) != nation_id:
			continue
		if _port_cell(id).x < 0:
			continue
		out.append(id)
	out.sort()
	var stored: Array = []
	for value in out:
		stored.append(value)
	_ports_cache[nation_id] = stored
	return out


## A nation's produced goods — union of its ports' `produces`, id-sorted
## (docs/30-* §4.4: the trader candidate goods and the specialty draw).
## Cached per nation (data is a per-run constant).
func nation_goods(nation_id: String) -> Array[String]:
	var cached: Array = _goods_cache.get(nation_id, [])
	if not cached.is_empty():
		var out: Array[String] = []
		for value in cached:
			out.append(str(value))
		return out
	var seen: Dictionary = {}
	for port in DataLoader.ports_list:
		if str((port as Dictionary).get("nation_id", "")) != nation_id:
			continue
		for good_id in (port as Dictionary).get("produces", []):
			seen[str(good_id)] = true
	var out: Array[String] = []
	for good_id in seen:
		out.append(good_id)
	out.sort()
	var stored: Array = []
	for value in out:
		stored.append(value)
	_goods_cache[nation_id] = stored
	return out


## Undirected rivalry pairs, sorted (docs/10-* §7.4 `nations.json rivals`).
func rivalry_pairs() -> Array:
	var seen: Dictionary = {}
	for nation in DataLoader.nations_list:
		var id := str((nation as Dictionary).get("id", ""))
		for rival in (nation as Dictionary).get("rivals", []):
			var key := "%s|%s" % [mini_id(id, str(rival)), maxi_id(id, str(rival))]
			seen[key] = true
	var out: Array = []
	for key in seen:
		out.append(str(key))
	out.sort()
	return out


static func mini_id(a: String, b: String) -> String:
	return a if a < b else b


static func maxi_id(a: String, b: String) -> String:
	return a if a > b else b


func _pair_of(nation_id: String) -> String:
	for pair in rivalry_pairs():
		var parts := (pair as String).split("|")
		if parts[0] == nation_id or parts[1] == nation_id:
			return pair
	return ""


## Nations the player holds a bounty against (`70-*` §4.5: rep ≤ −50),
## sorted by id for a stable stream.
func bountied_nations() -> Array[String]:
	var out: Array[String] = []
	var reputation: Dictionary = GameState.player.get("reputation", {})
	for nation_id in reputation:
		if int(reputation[nation_id]) <= NAVY_HOSTILE_REPUTATION:
			out.append(str(nation_id))
	out.sort()
	return out


## Per-role budget for `nation_id` at the live preset (`ceil` per role,
## docs/60-* §4.1.1). Pirates/hunters are world-wide demands, not per nation.
func budget_for(role: String, nation_id: String) -> int:
	var mult := multiplier()
	if mult <= 0.0:
		return 0
	var budgets := _budgets()
	var ports := _port_counts()
	var own := int(ports.get(nation_id, 0))
	match role:
		TRADER:
			return ceili(own * float(budgets.get("traders_mult_per_port", 1.25)) * mult)
		COASTER:
			return ceili(own * float(budgets.get("coasters_mult_per_port", 0.75)) * mult)
		PATROL:
			var div := float(budgets.get("patrols_div_ports", 6))
			var raw := ceilf(own / div * mult) if div > 0.0 else 1.0
			return maxi(int(budgets.get("patrols_min", 1)), int(raw))
		COURIER:
			return ceili(float(budgets.get("couriers_per_nation", 2)) * mult)
		PRIVATEER:
			return ceili(float(budgets.get("privateers_per_rivalry", 2)) * mult) \
				if _pair_of(nation_id) != "" else 0
		PIRATE:
			var base := float(budgets.get("pirate_base", 8))
			var per_zone := float(budgets.get("pirates_per_unpatrolled_zone", 1))
			_recount_zones(GameState.day)
			var demand := base + float(_unpatrolled_zones) * per_zone
			return mini(PIRATE_CORE_CAP, ceili(demand * mult))
		HUNTER:
			return 1 if nation_id in bountied_nations() else 0
		TREASURE:
			return 0  # the seasonal scheduler is task L; the role is reserved
	return 0


## Core cap: the sum of the persistent role budgets across all owners
## (docs/60-* §4.1.1: 272 at normal).
func core_cap() -> int:
	var total := 0
	for nation_id in _port_counts():
		for role in [TRADER, COASTER, PATROL, COURIER, PRIVATEER]:
			total += budget_for(role, nation_id)
	total += budget_for(PIRATE, "")
	return total


## Global cap (docs/60-* §4.1.1: 288 = 272 core + slack), bounded by the
## `absolute_cap` (2048).
func global_cap() -> int:
	var npc_config: Dictionary = _config.get("npc_config", DataLoader.npc_config)
	var absolute := int(npc_config.get("absolute_cap", 2048))
	return mini(core_cap() + GLOBAL_CAP_SLACK, absolute)


## The daily trickle: `max(4, ceil(cap / 50))` fleets/day (docs/60-* §4.1.2);
## `deserted` trickles nothing.
func trickle_per_day() -> int:
	if is_deserted():
		return 0
	var base := float(_flow().get("spawns_per_day_base", 4))
	@warning_ignore("integer_division")
	var scaled := ceili(float(global_cap()) / 50.0)
	return int(maxf(base, float(scaled)))


# --- Public API (docs/60-* §4.12.3 — implemented exactly) -------------------

## The new-game fill: half the core cap immediately, seeded, distributed on
## lanes near ports (docs/60-* §4.1.2). Called by `GameState.new_game` only.
## `deserted` fills nothing.
func initial_fill(day: int) -> void:
	last_tick_day = int(day)
	if is_deserted():
		return
	if not DataLoader.ensure_map():
		push_warning("NpcFleets.initial_fill: no world map; ecology not filled")
		return
	var target := core_cap() / 2
	var spawned := 0
	# Role-major, nation-id-sorted fill so the half-cap slice is spread evenly
	# across every role and nation (deterministic).
	for role in FILL_ORDER:
		if spawned >= target:
			return
		match role:
			PIRATE:
				var want := budget_for(PIRATE, "") / 2
				for _index in want:
					if spawned >= target:
						break
					if not spawn(PIRATE, "", int(day)).is_empty():
						spawned += 1
			HUNTER:
				pass  # bounty-only: the trickle owns transient hunters
			_:
				for nation_id in _port_counts():
					if spawned >= target:
						return
					var want := budget_for(role, nation_id) / 2
					for _index in want:
						if spawned >= target:
							break
						if not spawn(role, nation_id, int(day)).is_empty():
							spawned += 1


## One daily ecology tick, in the docs/20-* §4.3 order (after `day_advanced`):
## zone recount → lane stepping + dwell + decisions → the daily trickle.
## Returns the fleets spawned this tick (the pinned test seam). A repeat call
## within one day only returns `[]` (the `last_tick_day` dedupe).
func tick(day: int) -> Array:
	if int(day) == last_tick_day:
		return []
	last_tick_day = int(day)
	moved_ports = []
	if is_deserted():
		return []
	_ensure_rng()
	_recount_zones(int(day))
	_step_fleets(int(day))
	return _trickle(int(day))


## Every live fleet dict (the §4.11.11 shape) — the save payload. Shallow
## array copy; the dicts are the stored ones, so a fixture may adjust a fleet
## in place.
func fleets() -> Array:
	return GameState.npc_fleets.duplicate()


## Render dicts for the world scene (docs/80-* §4.5.2): `{id, role,
## nation_id, cell, letter}`. Convoy grouping and wake paths arrive with
## tasks K/L.
func markers() -> Array:
	var out: Array = []
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		out.append({
			"id": str((fleet as Dictionary).get("id", "")),
			"role": str((fleet as Dictionary).get("role", "")),
			"nation_id": str((fleet as Dictionary).get("nation_id", "")),
			"cell": position_of(fleet),
			"letter": marker_letter(str((fleet as Dictionary).get("role", ""))),
		})
	return out


## §4.11.11.2 contact rule: the nearest hostile fleet (pirate / privateer /
## hunter-with-bounty) within Chebyshev 1 of `cell`, wrap-aware. A fleet on
## its pursuit cooldown raises no contact. `{}` when none.
func nearest_contact(cell: Vector2i) -> Dictionary:
	var found := contacts(cell)
	return found[0] if not found.is_empty() else {}


## Every hostile fleet within Chebyshev 1 of `cell`, nearest first (ties by
## id ascending).
func contacts(cell: Vector2i) -> Array:
	var day := GameState.day
	var out: Array = []
	for fleet in _within(cell, CONTACT_DISTANCE):
		if not is_hostile_fleet(fleet):
			continue
		if int(fleet.get("cooldown_until_day", 0)) >= day:
			continue
		out.append(fleet)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da := chebyshev(cell, position_of(a))
		var db := chebyshev(cell, position_of(b))
		if da != db:
			return da < db
		return str(a.get("id", "")) < str(b.get("id", "")))
	return out


## Any fleet whose cell matches (the right-click attack target); `{}` when
## none.
func fleet_at(cell: Vector2i) -> Dictionary:
	var found := _within(cell, 0)
	return found[0] if not found.is_empty() else {}


## Removes fleet `id` from the ecology (the §4.12.4 battle-aftermath call).
func remove(id: String) -> void:
	for index in range(GameState.npc_fleets.size() - 1, -1, -1):
		var fleet = GameState.npc_fleets[index]
		if fleet is Dictionary and str((fleet as Dictionary).get("id", "")) == id:
			GameState.npc_fleets.remove_at(index)
			# A full rebuild (O(N), battle-aftermath frequency): kills the
			# whole stale-key class — fixtures may rename ids after adding,
			# so an incremental removal can never be trusted here.
			reset_index()
			return


## §4.10 pursuit cooldown on a stored fleet (`cooldown_until_day`, the last
## day it may not move or raise contact — inclusive reading).
func set_pursuit_cooldown(id: String, until_day: int) -> void:
	var fleet := _find(id)
	if fleet.is_empty():
		return
	fleet["cooldown_until_day"] = int(until_day)


## Single seeded spawn (docs/60-* §4.12.3: the test seam and the quest seam,
## `70-*` §4.9.3). Returns the new fleet dict, or `{}` when the preset is
## `deserted`, the absolute cap is reached, or no legal tile exists.
func spawn(role: String, nation_id: String, day: int) -> Dictionary:
	if is_deserted():
		return {}
	if not (role in FILL_ORDER) and role != TREASURE:
		return {}
	var npc_config: Dictionary = _config.get("npc_config", DataLoader.npc_config)
	if GameState.npc_fleets.size() >= int(npc_config.get("absolute_cap", 2048)):
		return {}
	var fleet := _build_fleet(role, nation_id, int(day))
	if fleet.is_empty():
		return {}
	GameState.npc_fleets.append(fleet)
	_index_add(fleet)
	return fleet


## Reseeds the world stream (the pinned test seam). Also clears the
## "this day already ticked" mark so a suite can replay the same sequence.
func reset_rng(seed_value: int) -> void:
	_rng.seed = seed_value
	_rng_seeded = true
	last_tick_day = -1


## Test/new-map seam: drops the shared lane-network and route caches (the
## network is derived purely from the loaded data, so this only matters to a
## fixture that swaps `DataLoader`'s tables or map between cases).
static func reset_caches() -> void:
	_route_cache = {}
	_net_ready = false
	_width = 2160
	_height = 1080
	_lane_paths = {}
	_lane_ids_sorted = []
	_spoke_paths = {}
	_spoke_lane = {}
	_tile_lanes = {}
	_node_tiles = []
	_node_index = {}
	_adjacency = {}
	_ports_cache = {}
	_goods_cache = {}


# --- Fleet shape & ids ------------------------------------------------------

## The §4.11.11 `nf_<day>_<seq>_<role>` id — deterministic and unique per run.
func next_fleet_id(day: int, role: String) -> String:
	var id := "nf_%d_%04d_%s" % [int(day), _id_seq, role]
	while _find(id) != {} :
		_id_seq += 1
		id = "nf_%d_%04d_%s" % [int(day), _id_seq, role]
	return id


## Builds one fleet of `role` fully (placement, route, captain, specialty).
## `{}` when no legal placement exists.
func _build_fleet(role: String, nation_id: String, day: int) -> Dictionary:
	_refresh_net()
	var cell := NO_CELL
	var fleet := {
		"id": "",
		"role": role,
		"nation_id": nation_id if role != PIRATE else "",
		"cell": {"x": 0, "y": 0},
		"route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
		"cargo": {},
		"captain": {"pool_id": "", "name_index": 0},
		"cooldown_until_day": 0,
		# Task-owned extensions of the docs' "…" (reported in the task J
		# summary): the fleet's seed, its destination port, dwell state, the
		# raider anchor, and the hunter-intel state machine (docs/60-*
		# §4.11.11.1): `hunter_state`, its 10-day loiter deadline and its
		# home port.
		"seed": 0,
		"dest_port_id": "",
		"dwell_until_day": 0,
		"anchor_cell": null,
		"target_fleet_id": "",
		"hunter_state": "",
		"loiter_until_day": 0,
		"home_port_id": "",
	}
	match role:
		PIRATE, PRIVATEER:
			var anchor := _raider_anchor(role, fleet["nation_id"], day)
			if anchor == NO_CELL:
				return {}
			cell = anchor
			fleet["anchor_cell"] = {"x": cell.x, "y": cell.y}
		HUNTER:
			cell = _hunter_anchor(nation_id, day)
			if cell == NO_CELL:
				return {}
			fleet["home_port_id"] = _hunter_home
			fleet["hunter_state"] = HUNTER_STATE_INTEL
			# The intel target: the last port the player sailed from, else
			# the hunter's home port until a first Set Sail is recorded.
			var intel_port := _intel_port()
			fleet["dest_port_id"] = intel_port if not intel_port.is_empty() \
				else _hunter_home
			fleet["dwell_until_day"] = int(day) + DWELL_DAYS
		TREASURE:
			# Reserved for task L's seasonal scheduler: spawn docked at the
			# nation's capital so the role is visible but inert.
			var capital := _capital_of(nation_id)
			if capital.is_empty():
				return {}
			cell = _port_cell(capital)
			if cell.x < 0:
				return {}
			fleet["dest_port_id"] = capital
			fleet["dwell_until_day"] = int(day) + DWELL_DAYS
		_:
			# Lane-locked roles: a journey between two own-nation ports.
			var journey := _role_journey(role, nation_id, day)
			if journey.is_empty():
				return {}
			return _finish_lane_fleet(fleet, journey, nation_id, day)
	fleet["id"] = next_fleet_id(day, role)
	fleet["seed"] = _fleet_seed(day, cell)
	set_position(fleet, cell)
	_draw_captain(fleet)
	if role == TRADER:
		fleet["specialty"] = _draw_specialty(nation_id, int(fleet["seed"]))
	return fleet


## Completes a lane-role fleet whose journey was already placed: writes the
## route, the id/seed, captain and specialty.
func _finish_lane_fleet(fleet: Dictionary, journey: Dictionary,
		nation_id: String, day: int) -> Dictionary:
	var role := str(fleet["role"])
	fleet["id"] = next_fleet_id(day, role)
	fleet["seed"] = _fleet_seed(day, journey["cell"])
	fleet["route"] = journey["route"]
	fleet["dest_port_id"] = str(journey.get("dest", ""))
	set_position(fleet, journey["cell"])
	if int(journey.get("dwell_until_day", 0)) > 0:
		fleet["dwell_until_day"] = int(journey["dwell_until_day"])
	_draw_captain(fleet)
	if role == TRADER:
		fleet["specialty"] = _draw_specialty(nation_id, int(fleet["seed"]))
	return fleet


static func _fleet_seed(day: int, cell: Vector2i) -> int:
	return int(day) * SEED_DAY_MULT + cell.x * SEED_X_MULT + cell.y * SEED_Y_MULT


## A deterministic per-fleet stream from the persisted seed + a purpose tag.
func _fleet_rng(fleet: Dictionary, purpose: String) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	var tag := hash(str(fleet.get("seed", 0)) + "|" + purpose)
	rng.seed = int(fleet.get("seed", 0)) * 31 + tag
	return rng


## Draws `captain {pool_id, name_index}` from the fleet's nation pool
## (pirates: the nationless `""` pool) — docs/60-* §4.11.11.4.
func _draw_captain(fleet: Dictionary) -> void:
	var pool_id := str(fleet.get("nation_id", ""))
	var pool: Dictionary = DataLoader.get_captain_pool(pool_id)
	var names: Array = pool.get("names", []) if pool.get("names", []) is Array else []
	if names.is_empty():
		# Missing/empty nation pool: fall back to the nationless pool (the
		# validator requires it), else leave the zero index.
		pool_id = ""
		pool = DataLoader.get_captain_pool("")
		names = pool.get("names", []) if pool.get("names", []) is Array else []
		if names.is_empty():
			fleet["captain"] = {"pool_id": "", "name_index": 0}
			return
	var rng := _fleet_rng(fleet, "captain")
	fleet["captain"] = {"pool_id": pool_id,
		"name_index": rng.randi_range(0, names.size() - 1)}


## The captain's display name (read seam for tests/L sightings).
static func captain_name(fleet: Dictionary) -> String:
	var captain: Dictionary = fleet.get("captain", {})
	var pool_id := str(captain.get("pool_id", ""))
	var index := int(captain.get("name_index", 0))
	var pool: Dictionary = DataLoader.get_captain_pool(pool_id)
	var names: Array = pool.get("names", []) if pool.get("names", []) is Array else []
	if index < 0 or index >= names.size():
		return ""
	return I18n.t(names[index])


## Draws the trader specialty from the nation's produced goods (docs/30-*
## §4.4: drawn once at spawn from the fleet seed, persisted).
func _draw_specialty(nation_id: String, seed_value: int) -> String:
	var goods := nation_goods(nation_id)
	if goods.is_empty():
		return ""
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 31 + hash("specialty")
	return goods[rng.randi_range(0, goods.size() - 1)]


# --- Placement helpers ------------------------------------------------------

## A pirate/privateer anchor: a seeded junction tile (a tile shared by ≥ 2
## lanes — the network's chokepoints) of the role's lane set, with up to
## [constant ANCHOR_RADIUS] jitter, passable and unoccupied.
func _raider_anchor(role: String, nation_id: String, day: int) -> Vector2i:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(day) * SEED_DAY_MULT + _id_seq * SEED_X_MULT \
		+ hash(role + "|" + nation_id)
	var candidates := _anchor_tiles(role, nation_id)
	for _attempt in 32:
		if candidates.is_empty():
			break
		var pick: Vector2i = candidates[rng.randi_range(0, candidates.size() - 1)]
		var cell := _free_tile_near(pick, rng, ANCHOR_RADIUS)
		if cell != NO_CELL:
			return cell
	return NO_CELL


## Junction tiles of the role's lane set (all lanes for a pirate, the
## sponsor's rivals' lanes for a privateer), sorted for determinism. Cached
## per (role, nation) — the tile→lanes map is a per-run constant.
func _anchor_tiles(role: String, nation_id: String) -> Array:
	var cache_key := role + "|" + nation_id
	var cached: Array = _anchor_cache.get(cache_key, [])
	if not cached.is_empty():
		return cached
	var lane_filter: Dictionary = {}
	if role == PRIVATEER:
		for rival_id in _rivals_of(nation_id):
			for lane_id in nation_lanes(rival_id):
				lane_filter[lane_id] = true
		if lane_filter.is_empty():
			for lane_id in _lane_ids_sorted:
				lane_filter[lane_id] = true
	var out: Array = []
	for key in _tile_lanes:
		var lanes: Array = _tile_lanes[key]
		if lanes.size() < 2:
			continue
		if not lane_filter.is_empty():
			var shared := false
			for lane_id in lanes:
				if lane_filter.has(lane_id):
					shared = true
					break
			if not shared:
				continue
		out.append(_key_to_cell(key))
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	_anchor_cache[cache_key] = out
	return out


## A hunter spawns docked at a seeded own-nation port (the §4.1.1 navy
## zone's port) so its first journey always boards the lane network.
func _hunter_anchor(nation_id: String, day: int) -> Vector2i:
	var ports := nation_ports(nation_id)
	if ports.is_empty():
		return NO_CELL
	var rng := RandomNumberGenerator.new()
	rng.seed = int(day) * SEED_DAY_MULT + _id_seq * SEED_X_MULT \
		+ hash("hunter|" + nation_id)
	var port_id: String = ports[rng.randi_range(0, ports.size() - 1)]
	var center := _port_cell(port_id)
	if center.x < 0:
		return NO_CELL
	_hunter_home = port_id
	return center


## A passable, unoccupied tile within `radius` of `center` (wrap-aware),
## drawn from `rng` over the ring offsets in deterministic order.
func _free_tile_near(center: Vector2i, rng: RandomNumberGenerator,
		radius: int) -> Vector2i:
	var offsets: Array = []
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			offsets.append(Vector2i(dx, dy))
	# Seeded Fisher-Yates — no global RNG state (docs/60-* §4.11.11).
	for index in range(offsets.size() - 1, 0, -1):
		var pick := rng.randi_range(0, index)
		var swap: Vector2i = offsets[index]
		offsets[index] = offsets[pick]
		offsets[pick] = swap
	for offset in offsets:
		var step: Vector2i = offset
		var y := center.y + step.y
		if y < 0 or y >= _height:
			continue
		var cell := Vector2i(posmod(center.x + step.x, _width), y)
		if not _passable(cell):
			continue
		if not _is_occupied(cell, ""):
			return cell
	return NO_CELL


## The journey for a lane-locked role at spawn.
##
## * `trader`: docked at a seeded own port (the first dwell end makes the
##   real decision); dest = the nearest own port so a route always exists.
## * `coaster`: docked at a seeded own port, dest = its adjacent port.
## * `courier`: docked at a seeded own port, dest = the capital (or the
##   reverse at the capital).
## * `patrol`: docked at its nation's most-connected port, one lane armed.
func _role_journey(role: String, nation_id: String, day: int) -> Dictionary:
	var ports := nation_ports(nation_id)
	if ports.is_empty():
		return {}
	# Per-spawn stream: the fleet's spawn sequence number salts the seed, so
	# two spawns of one (role, nation, day) draw different journeys while
	# staying fully deterministic.
	var rng := RandomNumberGenerator.new()
	rng.seed = int(day) * SEED_DAY_MULT + _id_seq * SEED_X_MULT \
		+ hash(role + "|" + nation_id)
	var origin: String = ports[rng.randi_range(0, ports.size() - 1)]
	var dest := ""
	if role == PATROL:
		origin = _patrol_home_port(nation_id)
	else:
		# Lane roles sail between two own-nation ports. Some port pairs share
		# no lane component (the Pacific runs alone), so the draw retries up
		# to six origins before the spawn draw fails.
		for _attempt in 6:
			origin = ports[rng.randi_range(0, ports.size() - 1)]
			match role:
				TRADER:
					dest = _nearest_own_port_excluding(origin, nation_id)
				COASTER:
					dest = _nearest_own_port_excluding(origin, nation_id)
				COURIER:
					dest = _capital_of(nation_id)
					if dest == origin:
						dest = _nearest_own_port_excluding(origin, nation_id)
			if dest.is_empty() or dest == origin:
				continue
			var route_check := route_between(origin, dest)
			if not route_check.is_empty():
				return {
					"origin": origin, "dest": dest, "cell": _port_cell(origin),
					"dwell_until_day": int(day) + DWELL_DAYS,
					"route": (route_check["legs_save"] as Dictionary).duplicate(true),
				}
		return {}
	if role == PATROL:
		var lanes := nation_lanes(nation_id)
		if lanes.is_empty():
			return {}
		var lane_id: String = lanes[rng.randi_range(0, lanes.size() - 1)]
		var harbor := _port_cell(origin)
		if harbor.x < 0:
			return {}
		var lane_path: Array = _lane_paths.get(lane_id, [])
		if lane_path.is_empty():
			return {}
		# Board the lane at the tile nearest the home port and sail at once
		# (the cycle's dwell happens at the lane ends, docs/60-* §4.1.1).
		var best_index := 0
		var best_distance := -1
		for index in lane_path.size():
			var distance := chebyshev(harbor, lane_path[index])
			if best_distance < 0 or distance < best_distance:
				best_distance = distance
				best_index = index
		if _is_occupied(lane_path[best_index], ""):
			# Boarding tile busy: walk the lane outward to the first free
			# tile (deterministic), else fail the draw.
			var step := -1 if best_index > lane_path.size() / 2 else 1
			var scan := best_index + step
			var free := -1
			while scan >= 0 and scan < lane_path.size():
				if not _is_occupied(lane_path[scan], ""):
					free = scan
					break
				scan += step
			if free < 0:
				return {}
			best_index = free
		var reverse := best_index > lane_path.size() / 2
		return {
			"origin": origin, "dest": "",
			"cell": lane_path[best_index],
			"dwell_until_day": 0,
			"route": {"lanes": [lane_id], "leg": 0, "tile_index": 0,
				"legs": [{"kind": "lane", "id": lane_id, "reverse": reverse,
					"a": 0, "b": lane_path.size() - 1}]},
		}
	var route := route_between(origin, dest)
	if route.is_empty():
		return {}
	return {
		"origin": origin, "dest": dest, "cell": _port_cell(origin),
		"dwell_until_day": int(day) + DWELL_DAYS,
		"route": (route["legs_save"] as Dictionary).duplicate(true),
	}


## The patrol's home port: the own-nation port whose 15-tile zone holds the
## most own-nation ports (the best coverage), ties by port id.
func _patrol_home_port(nation_id: String) -> String:
	var best := ""
	var best_count := -1
	for port_id in nation_ports(nation_id):
		var center := _port_cell(port_id)
		if center.x < 0:
			continue
		var count := 0
		for other_id in nation_ports(nation_id):
			if chebyshev(center, _port_cell(other_id)) <= ZONE_RADIUS:
				count += 1
		if count > best_count or (count == best_count and port_id < best):
			best = port_id
			best_count = count
	return best


func _nearest_own_port_excluding(port_id: String, nation_id: String) -> String:
	var best := ""
	var best_distance := 0
	var center := _port_cell(port_id)
	for other_id in nation_ports(nation_id):
		if other_id == port_id:
			continue
		var distance := chebyshev(center, _port_cell(other_id))
		if best.is_empty() or distance < best_distance \
				or (distance == best_distance and other_id < best):
			best = other_id
			best_distance = distance
	return best


func _capital_of(nation_id: String) -> String:
	var nation: Dictionary = DataLoader.get_nation(nation_id)
	return str(nation.get("capital_port_id", ""))


func _rivals_of(nation_id: String) -> Array:
	var nation: Dictionary = DataLoader.get_nation(nation_id)
	var out: Array = []
	for rival in nation.get("rivals", []):
		out.append(str(rival))
	out.sort()
	return out


## A nation's lanes: the lanes its own ports' spokes attach to, id-sorted
## (derived from the built artifact — the built lanes carry no nation list).
func nation_lanes(nation_id: String) -> Array:
	var seen: Dictionary = {}
	for port_id in nation_ports(nation_id):
		var lane_id := str(_spoke_lane.get(port_id, ""))
		if not lane_id.is_empty():
			seen[lane_id] = true
	var out: Array = []
	for lane_id in seen:
		out.append(lane_id)
	out.sort()
	return out


# --- Lane routing (docs/60-* §4.11.11.1: Dijkstra over the junction graph) --

## Rebuilds the lane-network caches from the built artifact once.
func _refresh_net() -> void:
	if _net_ready:
		return
	_net_ready = true
	var grid: Dictionary = DataLoader.map_legend.get("grid", {})
	_width = int(grid.get("width", 2160))
	_height = int(grid.get("height", 1080))
	for lane_id in DataLoader.route_lanes:
		var lane: Dictionary = DataLoader.route_lanes[lane_id]
		var path: Array = []
		for tile in lane.get("tile_path", []):
			path.append(Vector2i(int((tile as Array)[0]), int((tile as Array)[1])))
		_lane_paths[str(lane_id)] = path
		_lane_ids_sorted.append(str(lane_id))
	_lane_ids_sorted.sort()
	for port_id in DataLoader.route_spokes:
		var spoke: Dictionary = DataLoader.route_spokes[port_id]
		var path: Array = []
		for tile in spoke.get("tile_path", []):
			path.append(Vector2i(int((tile as Array)[0]), int((tile as Array)[1])))
		_spoke_paths[str(port_id)] = path
		_spoke_lane[str(port_id)] = _spoke_lane_id(spoke)
	# Tile → lanes map (wrapped x) — the anchor/chokepoint source.
	for lane_id in _lane_ids_sorted:
		for tile in _lane_paths[lane_id]:
			var key := _cell_key(tile)
			if not _tile_lanes.has(key):
				_tile_lanes[key] = []
			var lanes: Array = _tile_lanes[key]
			if not lanes.has(lane_id):
				lanes.append(lane_id)
	# The built junction graph, re-joined to per-edge tile segments.
	_build_graph()


## The spoke's attachment lane: `lane`, else `connect.lane`, else the
## capital spoke's end tile's smallest lane (all three shapes exist in the
## built artifact).
func _spoke_lane_id(spoke: Dictionary) -> String:
	var lane_id := str(spoke.get("lane", ""))
	if not lane_id.is_empty():
		return lane_id
	var connect: Dictionary = spoke.get("connect", {}) \
		if spoke.get("connect", {}) is Dictionary else {}
	lane_id = str(connect.get("lane", ""))
	if not lane_id.is_empty():
		return lane_id
	var path: Array = _spoke_paths.get(str(spoke.get("port", "")), [])
	if not path.is_empty():
		var lanes: Array = _tile_lanes.get(_cell_key(path[path.size() - 1]), [])
		if not lanes.is_empty():
			var sorted: Array = lanes.duplicate()
			sorted.sort()
			return str(sorted[0])
	return ""


## Re-derives the per-edge tile segments of the built junction graph (the
## builder's own rule: each path splits at its nodes; edges are `a < b`
## pairs weighted by tile steps). Ties keep the lane segment, then the
## smaller path key — deterministic.
func _build_graph() -> void:
	var junctions: Dictionary = DataLoader.route_junction_graph()
	_node_tiles = []
	for node in junctions.get("nodes", []):
		_node_tiles.append(Vector2i(int((node as Array)[0]), int((node as Array)[1])))
	_node_index.clear()
	for index in _node_tiles.size():
		_node_index[_cell_key(_node_tiles[index])] = index
	var edge_min: Dictionary = {}
	var edge_owner: Dictionary = {}
	var path_keys: Array = []
	for lane_id in _lane_ids_sorted:
		path_keys.append("lane:" + lane_id)
	var spoke_ids: Array = _spoke_paths.keys()
	spoke_ids.sort()
	for port_id in spoke_ids:
		path_keys.append("spoke:" + str(port_id))
	for path_key in path_keys:
		var path := _path_of(path_key)
		var marked: Array = []
		for index in path.size():
			var node = _node_index.get(_cell_key(path[index]), null)
			if node != null:
				marked.append([index, int(node)])
		for k in range(marked.size() - 1):
			var i: int = marked[k][0]
			var j: int = marked[k + 1][0]
			var a: int = marked[k][1]
			var b: int = marked[k + 1][1]
			if a == b or i == j:
				continue
			var pair_key := "%d|%d" % [mini_int(a, b), maxi_int(a, b)]
			var length := absi(j - i)
			var rank := 0 if path_key.begins_with("lane:") else 1
			var previous = edge_min.get(pair_key, null)
			var better := previous == null
			if previous is Array:
				better = length < int(previous[0]) \
					or (length == int(previous[0])
						and rank < int(previous[1]))
			if better:
				edge_min[pair_key] = [length, rank, path_key, i, j]
	for pair_key in edge_min:
		var entry: Array = edge_min[pair_key]
		var path_key := str(entry[2])
		var i := int(entry[3])
		var j := int(entry[4])
		var length := absi(j - i)
		# Orient each adjacency entry by the path: the entry in
		# `adjacency[node_of_mark_i]` walks marks i→j (and the mirror j→i),
		# so every hop's walked segment is continuous. Node order
		# ((y,x)-sorted) is unrelated to marks order — deriving the
		# direction here is what keeps the routing honest.
		var path := _path_of(path_key)
		var node_i = _node_index.get(_cell_key(path[i]), -1)
		var node_j = _node_index.get(_cell_key(path[j]), -1)
		if int(node_i) < 0 or int(node_j) < 0 or int(node_i) == int(node_j):
			continue
		if not _adjacency.has(int(node_i)):
			_adjacency[int(node_i)] = []
		(_adjacency[int(node_i)] as Array).append([int(node_j), length,
			path_key, i, j])
		if not _adjacency.has(int(node_j)):
			_adjacency[int(node_j)] = []
		(_adjacency[int(node_j)] as Array).append([int(node_i), length,
			path_key, j, i])


static func mini_int(a: int, b: int) -> int:
	return a if a < b else b


static func maxi_int(a: int, b: int) -> int:
	return a if a > b else b


func _path_of(path_key: String) -> Array:
	if path_key.begins_with("lane:"):
		return _lane_paths.get(path_key.trim_prefix("lane:"), [])
	return _spoke_paths.get(path_key.trim_prefix("spoke:"), [])


## The tile route between two ports (cached): Dijkstra over the built
## junction graph (edge weight = tile length; ties prefer the lane, then the
## smaller path key, then the smaller node — the pinned tie-break), expanded
## into legs. `{}` when no route exists.
func route_between(origin: String, dest: String) -> Dictionary:
	if origin.is_empty() or dest.is_empty() or origin == dest:
		return {}
	_refresh_net()
	var cache_key := origin + ROUTE_SEP + dest
	var cached = _route_cache.get(cache_key, null)
	if cached is Dictionary:
		return cached
	var start_tile := _port_cell(origin)
	var end_tile := _port_cell(dest)
	if start_tile.x < 0 or end_tile.x < 0:
		_route_cache[cache_key] = {}
		return {}
	var start = _node_index.get(_cell_key(start_tile), null)
	var end = _node_index.get(_cell_key(end_tile), null)
	if start == null or end == null:
		# A harbor tile that is not a graph node (should not happen: the
		# builder nodes every harbor) — no route, logged once.
		push_warning("NpcFleets: harbor tile of '%s'/'%s' is not a junction node"
			% [origin, dest])
		_route_cache[cache_key] = {}
		return {}
	var node_path := _dijkstra(int(start), int(end))
	if node_path.is_empty():
		_route_cache[cache_key] = {}
		return {}
	var route := _legs_from_nodes(node_path)
	_route_cache[cache_key] = route
	return route


## Dijkstra with the pinned tie-breaks, over the built junction graph.
## Binary-heap open set (a 769-node/805-edge graph is small, but the initial
## fill alone runs > 100 routes, so the linear-scan variant is not
## affordable). The heap key `(cost, rank, path_key, node)` is a total
## order — `node` is unique per entry — so the pop order is deterministic.
func _dijkstra(start: int, end: int) -> Array:
	var dist: Dictionary = {start: 0}
	var prev: Dictionary = {}
	var visited: Dictionary = {}
	var heap: Array = [[0, 0, "", start]]
	while not heap.is_empty():
		var top: Array = _heap_pop(heap)
		var current := int(top[3])
		if visited.has(current):
			continue
		visited[current] = true
		if current == end:
			break
		for edge in _adjacency.get(current, []):
			var next := int(edge[0])
			if visited.has(next):
				continue
			var cost := int(dist[current]) + int(edge[1])
			var known = dist.get(next, null)
			if known != null and int(known) <= cost:
				continue
			dist[next] = cost
			prev[next] = [current, edge]
			_heap_push(heap, [cost, _edge_rank(edge), str(edge[2]), next])
	if not visited.has(end):
		return []
	var path: Array = []
	var walk: int = end
	while walk != start:
		if not prev.has(walk):
			return []
		path.push_front(walk)
		walk = int((prev[walk] as Array)[0])
	path.push_front(start)
	return path


# --- Binary min-heap over `[cost, rank, key, node]` tuples ------------------

static func _heap_less(a: Array, b: Array) -> bool:
	if int(a[0]) != int(b[0]):
		return int(a[0]) < int(b[0])
	if int(a[1]) != int(b[1]):
		return int(a[1]) < int(b[1])
	if str(a[2]) != str(b[2]):
		return str(a[2]) < str(b[2])
	return int(a[3]) < int(b[3])


static func _heap_push(heap: Array, entry: Array) -> void:
	heap.append(entry)
	var index := heap.size() - 1
	while index > 0:
		var parent := (index - 1) / 2
		if _heap_less(heap[index], heap[parent]):
			var swap: Array = heap[parent]
			heap[parent] = heap[index]
			heap[index] = swap
			index = parent
		else:
			break


static func _heap_pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var index := 0
		var size := heap.size()
		while true:
			var left := index * 2 + 1
			var right := left + 1
			var smallest := index
			if left < size and _heap_less(heap[left], heap[smallest]):
				smallest = left
			if right < size and _heap_less(heap[right], heap[smallest]):
				smallest = right
			if smallest == index:
				break
			var swap: Array = heap[smallest]
			heap[smallest] = heap[index]
			heap[index] = swap
			index = smallest
	return top


static func _edge_rank(edge: Array) -> int:
	return 0 if str(edge[2]).begins_with("lane:") else 1


## Expands a node path into `{"legs_save", "legs", "length", "path"}`:
## consecutive same-path edges merge into one leg (same direction only).
func _legs_from_nodes(node_path: Array) -> Dictionary:
	var legs: Array = []
	for index in range(node_path.size() - 1):
		var a := int(node_path[index])
		var b := int(node_path[index + 1])
		var chosen: Array = []
		for edge in _adjacency.get(a, []):
			if int(edge[0]) == b:
				chosen.append(edge)
		if chosen.is_empty():
			return {}
		chosen.sort_custom(func(x: Array, y: Array) -> bool:
			var rx := _edge_rank(x)
			var ry := _edge_rank(y)
			if rx != ry:
				return rx < ry
			if str(x[2]) != str(y[2]):
				return str(x[2]) < str(y[2])
			return int(x[1]) < int(y[1]))
		var edge: Array = chosen[0]
		var path_key := str(edge[2])
		var i := int(edge[3])
		var j := int(edge[4])
		var kind := "lane" if path_key.begins_with("lane:") else "spoke"
		var id := path_key.trim_prefix("lane:").trim_prefix("spoke:")
		var forward := j > i
		# Walked orientation: forward walks min→max, reverse walks max→min.
		var lo := mini(i, j)
		var hi := maxi(i, j)
		var walked_start := lo if forward else hi
		var last: Dictionary = legs[legs.size() - 1] if not legs.is_empty() else {}
		# A continuation must start exactly where the previous leg's WALK
		# ended — the a bound on a reverse leg, the b bound on a forward one.
		var last_walked_end := -1
		if not last.is_empty():
			last_walked_end = int(last["a"]) if bool(last["reverse"]) \
				else int(last["b"])
		if not last.is_empty() and str(last["id"]) == id \
				and bool(last["reverse"]) == (not forward) \
				and last_walked_end == walked_start:
			# Contiguous continuation of the same leg in the same direction:
			# extend toward the new end (downward on a reverse leg).
			if forward:
				last["b"] = hi
			else:
				last["a"] = lo
			continue
		legs.append({"kind": kind, "id": id, "reverse": not forward,
			"a": lo, "b": hi})
	var legs_save: Array = []
	var full_path: Array = []
	var length := 0
	for leg in legs:
		var path := _path_of(("lane:" if leg["kind"] == "lane" else "spoke:")
			+ str(leg["id"]))
		var walked := _walked_path(path, int(leg["a"]), int(leg["b"]),
			bool(leg["reverse"]))
		if full_path.is_empty():
			full_path.append_array(walked)
		else:
			for tile in walked:
				if tile != full_path[full_path.size() - 1]:
					full_path.append(tile)
		if walked.size() > 1:
			length += walked.size() - 1
		legs_save.append({"kind": leg["kind"], "id": leg["id"],
			"reverse": leg["reverse"], "a": leg["a"], "b": leg["b"]})
	var lanes: Array = []
	for leg in legs_save:
		if leg["kind"] == "lane" and not lanes.has(leg["id"]):
			lanes.append(leg["id"])
	return {"legs_save": {"lanes": lanes, "leg": 0, "tile_index": 0,
		"legs": legs_save}, "length": length, "path": full_path}


## The walked tiles of a leg segment (inclusive), direction-aware.
static func _walked_path(path: Array, i: int, j: int, reverse: bool) -> Array:
	var out: Array = []
	if reverse:
		var k := j
		while k >= i:
			out.append(path[k])
			k -= 1
	else:
		var k := i
		while k <= j:
			out.append(path[k])
			k += 1
	return out


## The walked tile path of a saved leg (`{kind, id, reverse, a, b}`), rebuilt
## from the artifact — the seam that makes save/load byte-exact.
func _leg_path(leg: Dictionary) -> Array:
	var path := _path_of(("lane:" if str(leg.get("kind", "")) == "lane" else "spoke:")
		+ str(leg.get("id", "")))
	if path.is_empty():
		return []
	var a := clampi(int(leg.get("a", 0)), 0, path.size() - 1)
	var b := clampi(int(leg.get("b", path.size() - 1)), 0, path.size() - 1)
	return _walked_path(path, a, b, bool(leg.get("reverse", false)))


# --- The daily step (docs/60-* §4.11.11.1) ----------------------------------

func _step_fleets(day: int) -> void:
	var remove_ids: Array = []
	var pursuit_ms := 0.0
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		var id := str(fleet.get("id", ""))
		# Inclusive: a battle on day D stores D+1, so D+1 is still idle.
		if int(fleet.get("cooldown_until_day", 0)) >= day:
			continue
		var role := str(fleet.get("role", ""))
		if role == HUNTER and not (str(fleet.get("nation_id", "")) in bountied_nations()):
			remove_ids.append(id)  # bounty-only role: the bounty cleared
			_hunter_paths.erase(id)
			continue
		if role == HUNTER:
			# §4.11.11.1 hunter intel: lanes to the intel port (zero A*),
			# 10-day loiter at its approaches, short-radius pursuit only
			# inside the 15/20 hysteresis.
			pursuit_ms += _hunter_tick(fleet, day, pursuit_ms)
			continue
		var legs: Array = (fleet.get("route", {}) as Dictionary).get("legs", [])
		if legs.is_empty():
			if int(fleet.get("dwell_until_day", 0)) <= day:
				_depart(fleet, day)
			continue
		_advance(fleet, day)
	for id in remove_ids:
		remove(id)


## One hunter day under the intel rule (docs/60-* §4.11.11.1). Returns the
## pursuit A* time spent.
func _hunter_tick(fleet: Dictionary, day: int, budget_used_ms: float) -> float:
	var cell := position_of(fleet)
	var target := GameState.world_tile()
	var distance := chebyshev(cell, target)
	# 15/20 hysteresis: the chase opens inside 15, is lost beyond 20.
	if str(fleet.get("hunter_state", HUNTER_STATE_INTEL)) == HUNTER_STATE_CHASE:
		if distance > HUNTER_CHASE_OFF:
			_hunter_route_to_intel(fleet)
			return 0.0
		return _pursue(fleet, target, budget_used_ms)
	if distance <= HUNTER_CHASE_ON:
		fleet["hunter_state"] = HUNTER_STATE_CHASE
		_hunter_paths.erase(str(fleet.get("id", "")))
		return _pursue(fleet, target, budget_used_ms)
	# A new Set Sail re-targets under-way hunters at their next day tick.
	var intel_port := _intel_port()
	var state := str(fleet.get("hunter_state", HUNTER_STATE_INTEL))
	if state == HUNTER_STATE_INTEL and not intel_port.is_empty() \
			and str(fleet.get("dest_port_id", "")) != intel_port:
		_hunter_route_to_intel(fleet)
		return 0.0
	var legs: Array = (fleet.get("route", {}) as Dictionary).get("legs", [])
	if not legs.is_empty():
		_advance(fleet, day)
		return 0.0
	# Docked / arrived at a journey end.
	if int(fleet.get("dwell_until_day", 0)) > day:
		return 0.0
	match state:
		HUNTER_STATE_INTEL:
			# Arrived at the intel port: camp its approaches for 10 days.
			fleet["hunter_state"] = HUNTER_STATE_LOITER
			fleet["loiter_until_day"] = int(day) + HUNTER_LOITER_DAYS
			_camp_approaches(fleet, str(fleet.get("dest_port_id", "")))
		HUNTER_STATE_LOITER:
			# Loiter expired: route home via the sponsor's lanes (the
			# standing-bounty check above despawns one without a bounty).
			_hunter_route_home(fleet)
		HUNTER_STATE_HOME:
			# Back home with the bounty standing: sail for the intel again.
			_hunter_route_to_intel(fleet)
		_:
			_hunter_route_to_intel(fleet)
	return 0.0


## Lanes (junction-graph Dijkstra + tile path — zero A*) to the current
## intel target.
func _hunter_route_to_intel(fleet: Dictionary) -> void:
	fleet["hunter_state"] = HUNTER_STATE_INTEL
	fleet["loiter_until_day"] = 0
	var origin := _port_at_cell(position_of(fleet))
	if origin.is_empty():
		origin = str(fleet.get("dest_port_id", ""))
	var intel_port := _intel_port()
	if intel_port.is_empty():
		intel_port = str(fleet.get("home_port_id", ""))
	if origin.is_empty() or intel_port.is_empty() or origin == intel_port:
		# Nothing to sail to: hold one dwell cycle (deterministic retry).
		fleet["route"] = {"lanes": [], "leg": 0, "tile_index": 0, "legs": []}
		fleet["dwell_until_day"] = int(GameState.day) + DWELL_DAYS
		return
	var route := route_between(origin, intel_port)
	if route.is_empty():
		fleet["route"] = {"lanes": [], "leg": 0, "tile_index": 0, "legs": []}
		fleet["dwell_until_day"] = int(GameState.day) + DWELL_DAYS
		return
	fleet["route"] = (route["legs_save"] as Dictionary).duplicate(true)
	fleet["dest_port_id"] = intel_port
	fleet["dwell_until_day"] = 0


## Lanes home via the sponsor's network.
func _hunter_route_home(fleet: Dictionary) -> void:
	fleet["hunter_state"] = HUNTER_STATE_HOME
	fleet["loiter_until_day"] = 0
	var origin := _port_at_cell(position_of(fleet))
	if origin.is_empty():
		origin = str(fleet.get("dest_port_id", ""))
	var home := str(fleet.get("home_port_id", ""))
	if origin.is_empty() or home.is_empty() or origin == home:
		# Already home (or the home port is unresolvable): re-target intel.
		_hunter_route_to_intel(fleet)
		return
	var route := route_between(origin, home)
	if route.is_empty():
		_hunter_route_to_intel(fleet)
		return
	fleet["route"] = (route["legs_save"] as Dictionary).duplicate(true)
	fleet["dest_port_id"] = home
	fleet["dwell_until_day"] = 0


## The chokepoint-camping pattern at the intel port's approaches: a free,
## passable tile within Chebyshev 1 of the berth (the immediate approach),
## else the berth itself.
func _camp_approaches(fleet: Dictionary, port_id: String) -> void:
	var berth := _port_cell(port_id)
	if berth.x < 0:
		return
	for offset: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0),
			Vector2i(0, 1), Vector2i(0, -1)]:
		var y := berth.y + offset.y
		if y < 0 or y >= _height:
			continue
		var cell := Vector2i(posmod(berth.x + offset.x, _width), y)
		if not _passable(cell):
			continue
		if _is_occupied(cell, str(fleet.get("id", ""))):
			continue
		_commit_cell(fleet, cell)
		return


## The budgeted short-radius pursuit: A* toward the player inside the chase,
## re-planning only when the cached path is stale. An overflow loses the
## chase that day (the fleet holds).
func _pursue(fleet: Dictionary, target: Vector2i, budget_used_ms: float) -> float:
	var id := str(fleet.get("id", ""))
	var plan: Dictionary = _hunter_paths.get(id, {})
	var path: Array = plan.get("path", []) if plan.get("path", []) is Array else []
	var needs_plan := path.size() < 2 \
		or chebyshev(Vector2i(int((plan as Dictionary).get("target_x", -99999)),
			int((plan as Dictionary).get("target_y", -99999))), target) > 2
	if needs_plan:
		var budget_left := float(path_budget_ms()) - budget_used_ms
		if budget_left <= 0.0:
			return 0.0  # overflow: lose the chase today
		var started := Time.get_ticks_usec()
		path = FleetPathLib.find_path(position_of(fleet), target, _width,
			_height, func(cell: Vector2i) -> bool: return _passable(cell))
		var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
		_hunter_paths[id] = {"target_x": target.x, "target_y": target.y,
			"path": path}
		if elapsed > budget_left:
			return elapsed  # overflow: the chase is lost for today
		if path.size() < 2:
			return elapsed
	# Walk one tile along the plan.
	var next: Vector2i = path[1]
	if not _can_enter(fleet, next):
		_hunter_paths.erase(id)  # re-plan tomorrow from a clear board
		return 0.0
	path.remove_at(0)
	_commit_cell(fleet, next)
	return 0.0


## One tile of progress along the current leg, skipping occupied tiles and
## never entering land/reef/ice (docs/60-* §4.11.11.1). The next tile is
## computed by index arithmetic on the artifact path — no per-step slice
## allocation (the perf gate makes the day tick allocation-sensitive).
func _advance(fleet: Dictionary, day: int) -> void:
	var route: Dictionary = fleet.get("route", {})
	var legs: Array = route.get("legs", [])
	if legs.is_empty():
		return
	var leg: Dictionary = legs[0]
	var path := _path_of(("lane:" if str(leg.get("kind", "")) == "lane" else "spoke:")
		+ str(leg.get("id", "")))
	if path.is_empty():
		# A broken leg (unknown id after a hand edit): drop the journey.
		route["legs"] = []
		return
	var a := clampi(int(leg.get("a", 0)), 0, path.size() - 1)
	var b := clampi(int(leg.get("b", path.size() - 1)), 0, path.size() - 1)
	var reverse := bool(leg.get("reverse", false))
	# Walked index i ↔ artifact index: reverse walks b−i, forward walks a+i.
	var index := int(route.get("tile_index", 0))
	var walked_len := b - a + 1
	if index < 0 or index >= walked_len:
		# Off the leg (hand edit): restart the leg deterministically.
		index = 0
		route["tile_index"] = 0
	var artifact := (b - index) if reverse else (a + index)
	if index + 1 >= walked_len:
		# Leg end: board the next leg's first tile, and only then hand the
		# leg over — a blocked seam holds with the position still on the
		# stored leg (so route/position always agree, save/load included).
		if legs.size() > 1:
			var head: Dictionary = legs[1]
			var head_path := _path_of(
				("lane:" if str(head.get("kind", "")) == "lane" else "spoke:")
				+ str(head.get("id", "")))
			if head_path.is_empty():
				route["legs"] = []
				return
			var head_a := clampi(int(head.get("a", 0)), 0, head_path.size() - 1)
			var head_b := clampi(int(head.get("b", head_path.size() - 1)), 0, head_path.size() - 1)
			var head_tile: Vector2i = head_path[head_b if bool(head.get("reverse", false)) \
				else head_a]
			if not _can_enter(fleet, head_tile):
				return  # hold at the seam; the next day retries
			legs.pop_front()
			route["leg"] = int(route.get("leg", 0)) + 1
			route["tile_index"] = 0
			_commit_cell(fleet, head_tile)
			return
		# The final leg ended: dock at the destination.
		legs.pop_front()
		route["leg"] = int(route.get("leg", 0)) + 1
		route["tile_index"] = 0
		_arrive(fleet, day)
		return
	var dir := -1 if reverse else 1
	var target: Vector2i = path[artifact + dir]
	if not _can_enter(fleet, target):
		return  # occupied/blocked: hold (deterministic retry next day)
	route["tile_index"] = index + 1
	_commit_cell(fleet, target)


func _can_enter(fleet: Dictionary, cell: Vector2i) -> bool:
	return _passable(cell) and not _is_occupied(cell, str(fleet.get("id", "")))


func _commit_cell(fleet: Dictionary, cell: Vector2i) -> void:
	var before := position_of(fleet)
	set_position(fleet, cell)
	if before != NO_CELL and _by_id.has(str(fleet.get("id", ""))):
		_move_bucket(str(fleet.get("id", "")), before, cell)


## Leg list exhausted: dock at the destination port (docked fleets sit at the
## port's berth tile) for [constant DWELL_DAYS] days.
func _arrive(fleet: Dictionary, day: int) -> void:
	var port_id := str(fleet.get("dest_port_id", ""))
	if not port_id.is_empty():
		var berth := _port_cell(port_id)
		if berth.x >= 0:
			_commit_cell(fleet, berth)
	fleet["dwell_until_day"] = int(day) + DWELL_DAYS


## Dwell ended: the role's port-call decision (docs/30-* §4.4 for traders).
func _depart(fleet: Dictionary, day: int) -> void:
	var role := str(fleet.get("role", ""))
	var nation_id := str(fleet.get("nation_id", ""))
	match role:
		TRADER:
			_depart_trader(fleet, nation_id, day)
		COASTER:
			_depart_coaster(fleet, nation_id, day)
		COURIER:
			_depart_courier(fleet, nation_id, day)
		PATROL:
			_depart_patrol(fleet, day)
		PIRATE, PRIVATEER, HUNTER, TREASURE:
			pass  # anchored / scheduled elsewhere (K / L)


## Sells every cargo good whose live factor is above 1.0 at `port_id` —
## never sells into a saturated market (docs/30-* §4.4 sell rule). Returns
## the units sold.
func _sell_cargo(fleet: Dictionary, port_id: String, cap: int) -> int:
	var sold := 0
	for good_id in (fleet.get("cargo", {}) as Dictionary).keys():
		var good := str(good_id)
		var held := int((fleet["cargo"] as Dictionary)[good])
		if held <= 0:
			continue
		if EconomyLib.factor_units(port_id, good) <= 1000:
			# factor ≤ 1.0 (stock ≥ 100, docs/30-* §4.2): keep sailing with it
			continue
		var qty := held if cap <= 0 else mini(held, cap - sold)
		if qty <= 0:
			break
		EconomyLib.apply_trade(port_id, good, -qty)
		_note_moved(port_id)
		(fleet["cargo"] as Dictionary).erase(good)
		sold += qty
	return sold


func _note_moved(port_id: String) -> void:
	if not moved_ports.has(port_id):
		moved_ports.append(port_id)


func _free_hold(fleet: Dictionary, capacity: int) -> int:
	var used := 0
	for good_id in (fleet.get("cargo", {}) as Dictionary):
		used += int((fleet["cargo"] as Dictionary)[good_id])
	return maxi(0, capacity - used)


## The trader's port call: sell the factor>1.0 part of the hold, then the
## joint (good, destination) argmax over the nation's produced goods ×
## own-nation ports within Chebyshev 60 (docs/30-* §4.4), buy the bounded
## quantity, and sail.
func _depart_trader(fleet: Dictionary, nation_id: String, day: int) -> void:
	var origin := _port_at_cell(position_of(fleet))
	if origin.is_empty():
		origin = str(fleet.get("dest_port_id", ""))
	if origin.is_empty():
		fleet["dwell_until_day"] = int(day) + DWELL_DAYS
		return
	_sell_cargo(fleet, origin, 0)
	var decision := decide_trade(fleet, origin, day)
	if decision.is_empty():
		# No live candidate at all: idle another dwell cycle.
		fleet["dwell_until_day"] = int(day) + DWELL_DAYS
		return
	var good := str(decision["good"])
	var dest := str(decision["dest"])
	var qty := int(decision["qty"])
	if qty > 0 and not good.is_empty():
		EconomyLib.apply_trade(origin, good, qty)
		_note_moved(origin)
		var cargo: Dictionary = fleet.get("cargo", {})
		cargo[good] = int(cargo.get(good, 0)) + qty
		fleet["cargo"] = cargo
	_set_route_to(fleet, origin, dest)


## The coaster's port call: ≤ 5 units traded, hold ≤ 10, between adjacent
## (nearest own-nation) ports; never triggers contact (role rule) and is
## ignored by raiders (the prey query's rule).
func _depart_coaster(fleet: Dictionary, nation_id: String, day: int) -> void:
	var origin := _port_at_cell(position_of(fleet))
	if origin.is_empty():
		origin = str(fleet.get("dest_port_id", ""))
	if origin.is_empty():
		fleet["dwell_until_day"] = int(day) + DWELL_DAYS
		return
	_sell_cargo(fleet, origin, coaster_units())
	var dest := _nearest_own_port_excluding(origin, nation_id)
	if dest.is_empty():
		fleet["dwell_until_day"] = int(day) + DWELL_DAYS
		return
	# Buy ≤ the call cap of the best-margin produced good at origin.
	var best_good := ""
	var best_margin := 0
	for good_id in nation_goods(nation_id):
		var margin := TradeEngineLib.sell_price(dest, good_id) \
			- TradeEngineLib.buy_price(origin, good_id)
		if margin > best_margin:
			best_margin = margin
			best_good = good_id
	if not best_good.is_empty() and best_margin > 0:
		var saturation := _saturation_bound(dest, best_good)
		var qty := mini(coaster_units(), _free_hold(fleet, COASTER_HOLD_CAPACITY))
		qty = mini(qty, saturation)
		if qty > 0:
			EconomyLib.apply_trade(origin, best_good, qty)
			_note_moved(origin)
			var cargo: Dictionary = fleet.get("cargo", {})
			cargo[best_good] = int(cargo.get(best_good, 0)) + qty
			fleet["cargo"] = cargo
	_set_route_to(fleet, origin, dest)


## The courier's port call: capital ↔ own-ports dispatch runs.
func _depart_courier(fleet: Dictionary, nation_id: String, day: int) -> void:
	var origin := str(fleet.get("dest_port_id", ""))
	var capital := _capital_of(nation_id)
	var dest := capital
	if origin == capital or origin.is_empty():
		var rng := _fleet_rng(fleet, "courier|%d" % day)
		var ports := nation_ports(nation_id)
		if ports.is_empty():
			fleet["dwell_until_day"] = int(day) + DWELL_DAYS
			return
		dest = ports[rng.randi_range(0, ports.size() - 1)]
	_set_route_to(fleet, origin if not origin.is_empty() else capital, dest)


## The patrol's cycle: walk the lane to its end, dwell 2 days, walk it back
## (docs/60-* §4.1.1 "cycles its nation's lanes, docking en route" — the
## direction is derived from the end the patrol sits at, so it survives
## save/load exactly).
func _depart_patrol(fleet: Dictionary, _day: int) -> void:
	var route: Dictionary = fleet.get("route", {})
	var lanes: Array = route.get("lanes", [])
	if lanes.is_empty():
		return
	var lane_id := str(lanes[0])
	var path: Array = _lane_paths.get(lane_id, [])
	if path.is_empty():
		return
	var cell := position_of(fleet)
	# At the lane's end (or never boarded): walk the short way back.
	var reverse := chebyshev(cell, path[0]) > chebyshev(cell, path[path.size() - 1])
	var board := 0 if not reverse else path.size() - 1
	if cell != path[board]:
		return  # off the lane (hand edit): wait rather than teleport
	route["leg"] = 0
	route["tile_index"] = 0
	route["legs"] = [{"kind": "lane", "id": lane_id, "reverse": reverse,
		"a": 0, "b": path.size() - 1}]
	fleet["route"] = route
	fleet["dwell_until_day"] = 0


func _set_route_to(fleet: Dictionary, origin: String, dest: String) -> void:
	var route := route_between(origin, dest)
	if route.is_empty():
		# The validator makes this unreachable; idle and retry (never stall).
		fleet["route"] = {"lanes": [], "leg": 0, "tile_index": 0, "legs": []}
		fleet["dwell_until_day"] = int(GameState.day) + DWELL_DAYS
		return
	# The cache entry is shared by every fleet on this pair — fleets mutate
	# their route (legs pop, tile_index), so each gets its own deep copy.
	fleet["route"] = (route["legs_save"] as Dictionary).duplicate(true)
	fleet["dest_port_id"] = dest
	fleet["dwell_until_day"] = 0


## The trader decision (docs/30-* §4.4), exposed as the test seam. Returns
## `{good, dest, qty, score, lane_days, risk}` — the argmax candidate — or
## `{}` when no live candidate exists.
## The trader decision (docs/30-* §4.4), exposed as the test seam. Returns
## `{good, dest, qty, score, lane_days, risk}` — the argmax candidate — or
## `{}` when no live candidate exists.
func decide_trade(fleet: Dictionary, origin: String, day: int) -> Dictionary:
	var candidates := score_all_candidates(fleet, origin, day)
	return candidates[0] if not candidates.is_empty() else {}


## Every live (good, destination) candidate with its §4.4 score, best first
## (the argmax input of [method decide_trade]; the test seam the risk/score
## cases build on). Ties keep the first-generated candidate (dest id, then
## good id order).
func score_all_candidates(fleet: Dictionary, origin: String,
		day: int) -> Array:
	var nation_id := str(fleet.get("nation_id", ""))
	var goods := nation_goods(nation_id)
	if goods.is_empty() or origin.is_empty():
		return []
	var specialty := str(fleet.get("specialty", ""))
	if specialty.is_empty():
		# A fleet predating the field draws lazily from its own seed
		# (docs/30-* §4.4; no data migration).
		specialty = _draw_specialty(nation_id, int(fleet.get("seed", 0)))
		fleet["specialty"] = specialty
	var rng := _fleet_rng(fleet, "decision|%d" % day)
	var free := _free_hold(fleet, TRADER_HOLD_CAPACITY)
	var out: Array = []
	var draws := 0
	var dests := _candidate_destinations(origin, nation_id)
	# The buy side does not depend on the destination: price it once per good.
	var buy_prices: Dictionary = {}
	for good in goods:
		buy_prices[good] = TradeEngineLib.buy_price(origin, str(good))
	for dest in dests:
		var route := route_between(origin, str(dest))
		if route.is_empty():
			continue
		var lane_days := float(int(route["length"])) / float(LANE_TILES_PER_DAY)
		var risk := _route_risk(route, nation_id)
		for good in goods:
			draws += 1
			if draws > CANDIDATE_SCAN_LIMIT:
				break
			var qty := mini(trade_units_per_call(), free)
			qty = mini(qty, _saturation_bound(str(dest), str(good)))
			if qty <= 0:
				continue
			var est_sell := TradeEngineLib.sell_price(str(dest), str(good))
			var buy := int(buy_prices[good])
			var spec := SPEC_MULT if str(good) == specialty else 1.0
			var noise := NOISE_MIN + (NOISE_MAX - NOISE_MIN) * rng.randf()
			var margin := float(est_sell - buy)
			var score := margin * float(qty) * spec * noise * risk \
				/ (lane_days + 2.0)
			out.append({"good": str(good), "dest": str(dest), "qty": qty,
				"score": score, "lane_days": lane_days, "risk": risk,
				"est_sell": est_sell, "buy": buy})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["score"]) > float(b["score"]))
	return out


## Own-nation ports within Chebyshev 60 of `origin`, wrap-aware, id-sorted
## (docs/30-* §4.4 candidate destinations).
func _candidate_destinations(origin: String, nation_id: String) -> Array:
	var out: Array = []
	var center := _port_cell(origin)
	if center.x < 0:
		return out
	for port_id in nation_ports(nation_id):
		if port_id == origin:
			continue
		if chebyshev(center, _port_cell(port_id)) <= CANDIDATE_RADIUS:
			out.append(port_id)
	return out


## The saturation bound (docs/30-* §4.4): the quantity whose projected sale
## at `dest` keeps every tranche above factor 1.0 — `qty ≤ 100 − stock`.
func _saturation_bound(dest: String, good: String) -> int:
	return maxi(0, 100 - EconomyLib.stock_of(dest, good))


## The risk discount: ×0.5 when any hostile fleet lies within Chebyshev 5 of
## a sample point of the route path — one bucket query per sample
## (docs/30-* §4.4, deterministic). The ≤ 8 samples spread EVENLY over the
## whole journey (stride = ⌈len / 8⌉), so a raid on any stretch of the lane
## is felt, not just the shared trunk at the origin.
func _route_risk(route: Dictionary, _nation_id: String) -> float:
	var path: Array = route.get("path", [])
	if path.size() < 2:
		return 1.0
	@warning_ignore("integer_division")
	var stride := maxi(1, ceili(float(path.size()) / float(RISK_SAMPLE_MAX)))
	var index := 0
	while index < RISK_SAMPLE_MAX:
		var at := mini(path.size() - 1, index * stride)
		var tile: Vector2i = path[at]
		for fleet in _within(tile, RISK_RADIUS):
			var role := str(fleet.get("role", ""))
			if role == PIRATE or role == PRIVATEER:
				return RISK_MULT
		index += 1
		if at == path.size() - 1:
			break
	return 1.0


func trade_units_per_call() -> int:
	return int(_flow().get("trade_units_per_port_call", 30))


func coaster_units() -> int:
	return int(_flow().get("coaster_trade_units", 5))


func path_budget_ms() -> int:
	return int(_flow().get("path_budget_ms_per_day", 250))


# --- Trickle & budgets (docs/60-* §4.1.2) -----------------------------------

func _trickle(day: int) -> Array:
	var spawned: Array = []
	var budget := trickle_per_day()
	var npc_config: Dictionary = _config.get("npc_config", DataLoader.npc_config)
	for _attempt in budget * 4:
		if spawned.size() >= budget:
			break
		if GameState.npc_fleets.size() >= int(npc_config.get("absolute_cap", 2048)):
			break
		if GameState.npc_fleets.size() >= global_cap():
			break
		var deficit := _largest_deficit()
		if deficit.is_empty():
			break
		var fleet := spawn(str(deficit["role"]), str(deficit["nation_id"]), day)
		if not fleet.is_empty():
			spawned.append(fleet)
		else:
			# The draw failed (no legal tile): skip this owner for today.
			_skip[deficit["role"] + "|" + deficit["nation_id"]] = int(day)
	return spawned


## The (role, nation) owner with the largest budget deficit, in FILL_ORDER —
## so the cap can never starve traders for pirates (role order is the
## priority order).
func _largest_deficit() -> Dictionary:
	var best: Dictionary = {}
	var best_count := 0
	var day := last_tick_day
	var skipped := func(owner: String) -> bool:
		return _skip.has(owner) and int(_skip[owner]) == day
	for role in FILL_ORDER:
		if role == PIRATE:
			var live := _count_role(role, "")
			var want := budget_for(role, "")
			if want > live and best_count < want - live \
					and not skipped.call(role + "|"):
				best = {"role": role, "nation_id": ""}
				best_count = want - live
			continue
		if role == HUNTER:
			# Bounty-only: at most one hunter per bountied nation.
			for nation_id in bountied_nations():
				var hunter_live := _count_role(role, nation_id)
				if hunter_live == 0 and best_count < 1 \
						and not skipped.call(role + "|" + nation_id):
					best = {"role": role, "nation_id": nation_id}
					best_count = 1
			continue
		for nation_id in _port_counts():
			var want := budget_for(role, nation_id)
			var live := _count_role(role, nation_id)
			if want > live and want - live > best_count \
					and not skipped.call(role + "|" + nation_id):
				best = {"role": role, "nation_id": nation_id}
				best_count = want - live
	return best


func _count_role(role: String, nation_id: String) -> int:
	var count := 0
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		if str(fleet.get("role", "")) != role:
			continue
		if not nation_id.is_empty() \
				and str(fleet.get("nation_id", "")) != nation_id:
			continue
		count += 1
	return count


## The daily unpatrolled-zone recount (docs/60-* §4.1.1): a nation's port
## whose 15-tile zone lacks a same-nation patrol. One bucket query per port.
func _recount_zones(day: int) -> void:
	if _zones_day == int(day) and _unpatrolled_zones >= 0:
		return
	_zones_day = int(day)
	var unpatrolled := 0
	for port in DataLoader.ports_list:
		var port_id := str((port as Dictionary).get("id", ""))
		var nation_id := str((port as Dictionary).get("nation_id", ""))
		if port_id.is_empty() or nation_id.is_empty():
			continue
		var cell := _port_cell(port_id)
		if cell.x < 0:
			continue
		if not _zone_has_patrol(cell, nation_id):
			unpatrolled += 1
	_unpatrolled_zones = unpatrolled


func _zone_has_patrol(cell: Vector2i, nation_id: String) -> bool:
	for fleet in _within(cell, ZONE_RADIUS):
		if str(fleet.get("role", "")) != PATROL:
			continue
		if str(fleet.get("nation_id", "")) == nation_id:
			return true
	return false


## Same-nation escorts within Chebyshev 10 (docs/60-* §4.1.1 patrol row; the
## auto-resolve escorted rule is task K's consumer).
func is_escorted(fleet: Dictionary) -> bool:
	for other in _within(position_of(fleet), ESCORT_RADIUS):
		if other == fleet:
			continue
		if str(other.get("role", "")) != PATROL:
			continue
		if str(other.get("nation_id", "")) == str(fleet.get("nation_id", "")):
			return true
	return false


## The hunter-intel object: the port the player last sailed from
## (`world.last_departed_port`, docs/60-* §4.11.11.1).
func _intel_port() -> String:
	return str(GameState.world.get("last_departed_port", ""))


## Records the at-sea intel: contact with any fleet of a hunting nation
## (rep ≤ −50) updates `world.hunter_intel_cell` to the contact cell — one
## assignment per contact. Returns true when the cell was set.
func note_contacts(cell: Vector2i) -> bool:
	for fleet in _within(cell, CONTACT_DISTANCE):
		var nation_id := str(fleet.get("nation_id", ""))
		if nation_id.is_empty():
			continue
		if CharacterLib.reputation(nation_id) > NAVY_HOSTILE_REPUTATION:
			continue
		GameState.world["hunter_intel_cell"] = {"x": cell.x, "y": cell.y}
		return true
	return false


## A pirate/privateer's prey candidates within Chebyshev 10: traders and
## patrols, never coasters (docs/60-* §4.1.1: "raiders ignore" coasters).
## The chase itself is task K; this is the query the chase consumes.
func prey_candidates(fleet: Dictionary) -> Array:
	var out: Array = []
	for other in _within(position_of(fleet), PREY_RADIUS):
		if other == fleet:
			continue
		var role := str(other.get("role", ""))
		if role != TRADER and role != PATROL:
			continue
		if str(fleet.get("role", "")) == PRIVATEER \
				and not (str(other.get("nation_id", "")) in _rivals_of(
					str(fleet.get("nation_id", "")))):
			continue  # a privateer hunts only its sponsor's rivals
		out.append(other)
	return out


# --- Hostility, composition & markers ---------------------------------------

## §4.11.11.1 hostility: pirates and privateers always; a hunter only while
## the player holds its nation's bounty (rep ≤ −50).
static func is_hostile_fleet(fleet: Dictionary) -> bool:
	var role := str(fleet.get("role", ""))
	if role == PIRATE or role == PRIVATEER:
		return true
	if role != HUNTER:
		return false
	return CharacterLib.reputation(str(fleet.get("nation_id", ""))) \
		<= NAVY_HOSTILE_REPUTATION


## The S10 `kind` of a fleet battle (docs/60-* §4.11.11.3): hunters keep the
## navy kind; every other role carries its role id (the §4.11.11.2 map keys).
static func composition_kind(role: String) -> String:
	return "navy" if role == HUNTER else role


## §4.11.11.2: each battle draws from the fleet's own seeded stream, so
## save/load reproduces compositions. `AiFleet.compose_enemy` is unchanged —
## the role→budget map lives in `ai_fleet.gd`'s `CANNON_BUDGET`.
static func compose_fleet_ships(fleet: Dictionary, day: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(fleet.get("seed", 0))
	return AiFleetLib.compose_enemy(
		composition_kind(str(fleet.get("role", PIRATE))), int(day), rng)


## The fleet's cell from the `{"x","y"}` save shape (tolerates Vector2i/2).
static func position_of(fleet: Dictionary) -> Vector2i:
	var pos = fleet.get("cell", null)
	if pos is Vector2i:
		return pos
	if pos is Vector2:
		return Vector2i(pos)
	if pos is Dictionary:
		return Vector2i(int(pos.get("x", 0)), int(pos.get("y", 0)))
	return NO_CELL


## Writes the fleet cell back in the §4.11.11 `{"x","y"}` save shape.
static func set_position(fleet: Dictionary, cell: Vector2i) -> void:
	fleet["cell"] = {"x": cell.x, "y": cell.y}


## Marker colour (docs/80-* §4.5.2): pirate = BAD red, every national fleet =
## its nation colour (hunter included). Placeholder palette only.
static func marker_color(role: String, nation_id: String) -> Color:
	if role == PIRATE:
		return PaletteLib.BAD
	var nation: Dictionary = DataLoader.get_nation(nation_id)
	var hex := str(nation.get("color", ""))
	if not Color.html_is_valid(hex):
		return PaletteLib.PANEL_LINE
	return PaletteLib.nation_color(hex)


## The role letter drawn inside the marker square (docs/80-* §4.5.2 "a
## letter for the role"; placeholder set — pirates draw no letter).
static func marker_letter(role: String) -> String:
	match role:
		TRADER: return "T"
		COASTER: return "c"
		COURIER: return "k"
		PATROL: return "P"
		PRIVATEER: return "p"
		HUNTER: return "N"
		TREASURE: return "X"
	return ""


# --- The wrap-aware cell-bucket spatial index (§4.11.11.5 — review gate) ----

## Bucket key of a cell (y-major; buckets do not wrap — the query does).
static func _cell_key(cell: Vector2i) -> int:
	return int(cell.y) * 4096 + int(posmod(cell.x, 4096))


static func _key_to_cell(key: int) -> Vector2i:
	return Vector2i(int(key) % 4096, int(key) / 4096)


static func _bucket_of(cell: Vector2i) -> int:
	@warning_ignore("integer_division")
	return (cell.y / BUCKET_SIZE) * 4096 + posmod(cell.x, 2160) / BUCKET_SIZE


## Rebuilds the whole index. Everyday movement updates buckets incrementally
## ([method _move_bucket]) and spawns/removes maintain them ([method
## _index_add] / [method _index_remove]), so this only runs once per sim
## instance (or after an external `GameState.npc_fleets` swap — a save load;
## the world scene adopts a fresh sim, tests call [method reset_index]).
func _refresh_index() -> void:
	if not _index_dirty:
		return
	_index_dirty = false
	_buckets.clear()
	_by_id.clear()
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		_index_add(fleet)


## Adds one fleet to the index (O(1)).
func _index_add(fleet: Dictionary) -> void:
	var id := str(fleet.get("id", ""))
	if id.is_empty():
		return
	_by_id[id] = fleet
	var bucket := _bucket_of(position_of(fleet))
	if not _buckets.has(bucket):
		_buckets[bucket] = []
	(_buckets[bucket] as Array).append(id)


## Drops one fleet from the index (O(1); the bucket entry is left for the
## next rebuild — queries skip ids missing from `_by_id`).
func _index_remove(id: String) -> void:
	_by_id.erase(id)


## Public seam for a fixture that replaced `GameState.npc_fleets` wholesale
## (a save load into an existing sim): the next query rebuilds the index.
func reset_index() -> void:
	_index_dirty = true


## Moves one fleet's bucket entry in place (the incremental update that
## keeps the index maintenance O(1) per fleet-step).
func _move_bucket(id: String, from_cell: Vector2i, to_cell: Vector2i) -> void:
	var from_bucket := _bucket_of(from_cell)
	var to_bucket := _bucket_of(to_cell)
	if from_bucket == to_bucket:
		return
	var entries: Array = _buckets.get(from_bucket, [])
	entries.erase(id)
	if entries.is_empty():
		_buckets.erase(from_bucket)
	if not _buckets.has(to_bucket):
		_buckets[to_bucket] = []
	(_buckets[to_bucket] as Array).append(id)


## EVERY "within N tiles" check in this module goes through here
## (docs/60-* §4.11.11.5 review gate): wrap-aware Chebyshev radius query
## over the cell-bucket hash.
func _within(cell: Vector2i, radius: int) -> Array:
	_refresh_index()
	var out: Array = []
	var seen: Dictionary = {}
	@warning_ignore("integer_division")
	var buckets_x := 2160 / BUCKET_SIZE
	@warning_ignore("integer_division")
	var max_bucket_y := (1080 - 1) / BUCKET_SIZE
	# Wrap the CELL range first, then divide — truncation toward zero on a
	# negative numerator would otherwise miss the seam bucket.
	@warning_ignore("integer_division")
	var min_bx := posmod(posmod(cell.x - radius, 2160), 2160) / BUCKET_SIZE
	@warning_ignore("integer_division")
	var max_bx := posmod(posmod(cell.x + radius, 2160), 2160) / BUCKET_SIZE
	@warning_ignore("integer_division")
	var by := posmod(cell.y, 1080) / BUCKET_SIZE
	# A radius can straddle the next bucket row: round the span up.
	@warning_ignore("integer_division")
	var span_y := (radius + BUCKET_SIZE - 1) / BUCKET_SIZE
	var min_by := maxi(0, by - span_y)
	@warning_ignore("integer_division")
	var max_by := mini(max_bucket_y, by + span_y)
	var bx := min_bx
	while true:
		var bucket_y := min_by
		while bucket_y <= max_by:
			var bucket := bucket_y * 4096 + bx
			for id in _buckets.get(bucket, []):
				if seen.has(id):
					continue
				seen[id] = true
				var fleet: Dictionary = _by_id.get(id, {})
				if fleet.is_empty():
					continue
				if chebyshev(cell, position_of(fleet)) <= radius:
					out.append(fleet)
			bucket_y += 1
		if bx == max_bx:
			break
		bx = posmod(bx + 1, buckets_x)
	return out


## True when `cell` holds another fleet, a docked fleet's port tile is shared
## (docked fleets never block), or the player's fleet stands there
## (docs/60-* §4.11.11.1 "skipping occupied tiles"). `ignore_id` skips the
## stepping fleet's own current cell. Radius 0 reads the exact bucket
## directly — no query allocation on the per-fleet step path.
func _is_occupied(cell: Vector2i, ignore_id: String) -> bool:
	if cell == GameState.world_tile():
		return true
	_refresh_index()
	for id in _buckets.get(_bucket_of(cell), []):
		if str(id) == ignore_id:
			continue
		var fleet: Dictionary = _by_id.get(id, {})
		if fleet.is_empty():
			continue
		if int(fleet.get("dwell_until_day", 0)) > 0:
			continue  # docked fleets share port tiles
		if position_of(fleet) == cell:
			return true
	return false


# --- Small helpers ---------------------------------------------------------

func _find(id: String) -> Dictionary:
	for fleet in GameState.npc_fleets:
		if fleet is Dictionary and str((fleet as Dictionary).get("id", "")) == id:
			return fleet
	return {}


## The port whose berth tile is `cell` ("" when none).
func _port_at_cell(cell: Vector2i) -> String:
	return DataLoader.port_id_at(cell)


func _port_cell(port_id: String) -> Vector2i:
	var cell: Vector2i = DataLoader.port_cell(port_id)
	return cell if cell.x >= 0 else NO_CELL


func _passable(cell: Vector2i) -> bool:
	return DataLoader.is_passable(cell)


## Wrap-aware Chebyshev distance (`20-*` §4.1): `min(|dx|, width − |dx|)`.
static func chebyshev(a: Vector2i, b: Vector2i) -> int:
	var grid: Dictionary = DataLoader.map_legend.get("grid", {})
	var width := int(grid.get("width", 0))
	if width <= 0:
		width = 2160
	var dx := absi(a.x - b.x) % width
	return maxi(mini(dx, width - dx), absi(a.y - b.y))


func _ensure_rng() -> void:
	if _rng_seeded:
		return
	var tile := GameState.world_tile()
	_rng.seed = GameState.day * SEED_DAY_MULT + tile.x * SEED_X_MULT \
		+ tile.y * SEED_Y_MULT
	_rng_seeded = true
