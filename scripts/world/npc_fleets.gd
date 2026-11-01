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
## **Phase-6 parity & seasons** (docs/60-* §4.11.11 amendment, task H): every
## NPC daily tile budget multiplies by the same `direction_factor` /
## `current_factor` the player's §4.4 pipeline applies — evaluated per leg
## heading (the direction of the next tile step), pure functions of day +
## position, no RNG, so replays stay exact. Lane stepping runs at the base 2
## tiles/day **before** the factors; the fractional remainder banks in a
## transient per-fleet accumulator ([member _step_carry] — runtime-only,
## never persisted, mirroring the player drift accumulator's status). Hunters
## pay the factors on lane travel and per pursuit step; raider chase/return
## steps pay them per pursuit heading. Lanes with built `variants`
## (`trade_routes_built.json`) sail the in-month variant's tile path, with
## progress remapped by fraction on a month rollover (§2.8); in-month
## seasonal ice (§4.18) refuses *entry* in [_passable] — a standing fleet is
## never trapped.
##
## **The spatial index is a review gate** (docs/60-* §4.11.11.5): EVERY
## "within N tiles" check in this module goes through the wrap-aware
## cell-bucket hash ([method _within]) — occupancy, contact-1, prey-10,
## escort-10, patrol-zone-15, risk-sample-5. Nothing scans the fleet array
## per distance check; each query visits only the buckets its radius
## touches, so a day tick is linear in fleet count.
##
## **Phase-7 ecology amendment** (docs/60-* §4.11.14 — task N): (1) trader
## docking adopts the **effective alignment** (docs/30-* §4.9) — a nation's
## traders may port-call at any port aligned to them (protected own +
## contestable aligned, sovereign non-core and neutral alike), never at a
## rival-aligned or unallied one; the old own-nation-only pin is rewritten.
## (2) Every neutral port is served by ~1 **nationless coaster** (中立灰
## livery, decision 18) hopping to the NEAREST ports regardless of
## ownership — local only, goods scope staples ∪ middle clamped at buy AND
## sell (decision 21), never-triggers-contact unchanged. (3) Traders and
## sovereign coasters credit the unified tariff (docs/30-* §4.10) of their
## port-call trades into the host treasury through the guard-read
## `Allegiance.credit_tax` — walked totals reused, nationless coasters
## exempt, the 2,000g/host/month cap lives inside the allegiance module.
## The spawn budget gains the `neutral_coasters_mult` data line (correction
## 15); the nation-line `coasters_mult_per_port` keeps its meaning.

const EconomyLib := preload("res://scripts/port/economy.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const AiFleetLib := preload("res://scripts/combat/ai_fleet.gd")
const BattleRewardsLib := preload("res://scripts/combat/battle_rewards.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const PaletteLib := preload("res://scripts/palette.gd")
## Pursuit A* (the only runtime pathfinding; docs/60-* §4.11.11.1).
const FleetPathLib := preload("res://scripts/world/fleet_path.gd")
## Phase-6 parity (task H): the calendar/factor tables and the ocean-layer
## lookups (prevailing wind, currents, in-month ice). No preload cycle —
## `sailing_sim.gd` never loads this module.
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
## Phase-7 allegiance guard (docs/60-* §4.11.14, docs/80-* §4.9 contracts).
## Loaded **by path, never preloaded** — the economy.gd dev-guard pattern —
## so the suites' `take_over_path` fixtures win over the real module until
## restored. Guarded defaults while absent: alignment = the data
## `nation_id`, tariff 500 (aligned) / 2000 (foreign) in the C-contract
## basis; the crediting is skipped entirely (a no-op world).
const ALLEGIANCE_PATH := "res://scripts/port/allegiance.gd"

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
## Unified-movement diagnostics (`60-*` §4.12.x, read-only): a lane fleet
## that consumes its accrual budget without forward progress this many
## ticks reports `blocked` in [method stall_reason] / [method
## stalled_fleets] — the hold counter is the observability the unified
## model needed (blocked fleets are invisible in position data alone).
const STALL_HOLD_TICKS := 3
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
## §4.1.1 patrol zone radius — the pinned 30-tile navy zone (Phase-6 sweep:
## 15 → 30, `10-*` §6.1), reused for the daily unpatrolled-zone recount and
## the escorted-trader rule.
const ZONE_RADIUS := 30
## §4.1.1: same-nation traders within Chebyshev 20 of a patrol are escorted
## (Phase-6 sweep: escort 10 → 20); pirates prefer prey within Chebyshev 10
## (prey-preference pin — unchanged by the sweep).
const PREY_RADIUS := 10
const ESCORT_RADIUS := 20
## §4.11.11.4: same-lane traders within Chebyshev 3 form a convoy, which
## auto-resolve treats as escorted (§4.11.11.2) — unchanged pin.
const CONVOY_RADIUS := 3
## §4.11.11.1: pirate/privateer anchors sit within Chebyshev 6 of chokepoint
## tiles; prey is engaged within 10 and released beyond 16 (the 10/16
## hysteresis — the chase itself is task K). Phase-6 sweep: 3/5/8 → 6/10/16.
const ANCHOR_RADIUS := 6
const CHASE_ON_RADIUS := 10
const CHASE_OFF_RADIUS := 16
## §4.11.11.1 hunter-intel rule (locked): the chase opens inside Chebyshev 30,
## is lost beyond Chebyshev 40 (the 30/40 hysteresis — Phase-6 sweep:
## 15/20 → 30/40), and the intel-port loiter lasts 10 days.
const HUNTER_CHASE_ON := 30
const HUNTER_CHASE_OFF := 40
const HUNTER_LOITER_DAYS := 10
## Hunter states (persisted, docs/60-* §4.11.11.1 hunter intel): sailing to
## the intel port, camping its approaches, chasing, or routing home.
const HUNTER_STATE_INTEL := "intel"
const HUNTER_STATE_LOITER := "loiter"
const HUNTER_STATE_CHASE := "chase"
const HUNTER_STATE_HOME := "home"
## `30-*` §4.4 trader decision: destinations are own-nation ports within
## Chebyshev 120 (wrap-aware; Phase-6 sweep: 60 → 120).
const CANDIDATE_RADIUS := 120
## `30-*` §4.4 risk discount: a hostile fleet within Chebyshev 5 of a sample
## point of the candidate lane path halves the score (unchanged pin — not in
## the Phase-6 sweep's gameplay list).
const RISK_RADIUS := 5
const RISK_MULT := 0.5
## `30-*` §4.4: specialty multiplier and the seeded noise band.
const SPEC_MULT := 1.5
const NOISE_MIN := 0.8
const NOISE_MAX := 1.25
## Port dwell: 2 days docked at route endpoints (docs/60-* §4.1.1).
const DWELL_DAYS := 2
## §4.11.11.2 (task K): a raider (pirate/privateer) beats an unescorted
## trader on this seeded chance; every other §4.11.11.2 pairing is
## deterministic (patrol / escorted trader / convoy ⇒ the raider loses).
const RAIDER_WIN_CHANCE := 0.6
## §4.11.11.2: a battle's loser despawns into a wreck that despawns after
## this many days (`despawn_day` is always `spawn_day + 5`).
const WRECK_DESPAWN_DAYS := 5
## Roles whose wreck is a warship wreck (§4.11.11.2: salvage gold via
## `BattleRewards.salvage_for` over the composed hulls); every other role is
## a merchant wreck carrying its actual cargo.
const WARSHIP_WRECK_ROLES: Array[String] = [
	PATROL, PRIVATEER, HUNTER, PIRATE,
]
## `60-*` §4.11.11.2 composition: the role→cannon-budget map that replaces
## §4.11.3 step 3's value for its kinds (+ `floor(day / 30)`, applied inside
## `AiFleet.cannon_budget`).
const COMPOSITION_BUDGETS := {
	TRADER: 6, COASTER: 2, COURIER: 0, PATROL: 30, PRIVATEER: 20, PIRATE: 20,
}

## --- Task L constants (docs/60-* §4.11.11.4) -------------------------------
##
## Treasure fleets: 1/nation/season on day `45 + 15 × nation_index` (mod 90),
## `nation_index` = `nations.json` file order (portugal 0 … italy 5) ⇒ first
## sailings on days 45/60/75/90/105/120, then every 90 days per nation.
const TREASURE_BASE_DAY := 45
const TREASURE_NATION_STEP := 15
const TREASURE_SEASON_DAYS := 90
## §4.11.11.2 composition detail: a treasure fleet rolls `3 + rng(0..2)`
## merchant hulls (the 3–5 pin, §4.11.11.4) plus **one patrol-escort hull**;
## the whole-fleet cannon budget is `30 + floor(day/30)` — exactly the patrol
## budget, so the single `AiFleet.cannon_budget("patrol", day)` answers it.
const TREASURE_MERCHANT_HULLS := 3
## Treasure loot (§4.11.11.4): cargo at ×3 the normal volume. "Normal volume"
## is one trader port call — `flow.trade_units_per_port_call` (30 units) — so
## the hold is filled with 3 × 30 = 90 units (the gold half of the pin lives
## with the player-attack loot row, docs/60-* §4.11.11.2/§4.11.11.4).
const TREASURE_CARGO_MULT := 3
## §4.11.11.4: a defeated named pirate respawns under a NEW name +30 days.
const NAMED_RESPAWN_DAYS := 30
## Wake trail length behind a moving marker (docs/80-* §4.5.2: a 5-tile dashed
## trail; wrecks and docked markers draw none).
const WAKE_LENGTH := 5
## Transient port-traffic log cap (docs/90-* §8.1 task L pin): the ecology
## keeps the last ≤ 128 arrival/departure records for the tavern rumor rows.
const PORT_LOG_MAX := 128

## Task L: named-pirate respawn bookkeeping lives in the SAVED
## `GameState.named_pirate_respawns` (`{named_id: available_day}`,
## docs/90-* §8.1) — a +30-day window now survives save/load exactly. The
## successor's NAME comes from the nationless captain pool
## (`npc_captains.json` `""`, ≥ 8 entries — "the next pool entry",
## §4.11.11.4): the 4-entry `named_pirates.json` list cannot supply a *new*
## name while the other three identities stay afloat, so famous entries
## front the ecology and successors rotate through the pool, inheriting the
## slot's bounty tier (a famous defeat keys the slot's id, so the tier is
## re-derived from `named_pirates.json` at fire time; a successor defeat
## schedules the interchangeable alias rotation under a `successor_<tier>`
## key — the map stays the documented bare `{id: day}` shape).
## The nationless-pool rotation cursor for successor names (deterministic:
## each draw takes the next free entry, wrapping) stays transient — names
## already afloat are never redrawn, so a fresh cursor cannot duplicate one.
static var _successor_cursor: int = 0

## --- Task-owned constants (the docs left these open; see the task J report).
##
## Lane-days divisor for the trader score: `lane_days = tile length / 20`.
## HISTORICAL: the retired encounters system had no per-day tile rate to stay consistent with,
## so the 20 tiles/day default named by the task is pinned here. This is a
## ranking constant only — real stepping runs the unified §4.4 pipeline
## (the `60-*` §4.11.11 amendment; [method _lane_tiles_today]).
const LANE_TILES_PER_DAY := 20
## Task-H parity pin (amended by the unified-movement model): the
## direction-factor **fallback** column. The column now follows the fleet's
## flagship class ([method _fleet_base]); every §4.11.3 hull in the
## composition pool is `sail`, so fallback and practice agree.
const NPC_SAIL_CLASS := "sail"
## Hold capacities (fleet dicts carry cargo only — no ship list). The
## coaster's ≤ 10 hold and ≤ 5-unit calls are doc-pinned (`30-*` §4.4); the
## trader capacity is task-owned headroom above the 30-unit call cap so a
## small unsellable remainder can never wedge a journey.
const TRADER_HOLD_CAPACITY := 40
const COASTER_HOLD_CAPACITY := 10
## Risk-sample count over a candidate route's tile path (`30-*` §4.4: "a
## few bucket queries", deterministic); the stride derives from the route
## length so the samples spread over the whole journey.
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
static var _width: int = 4320
static var _height: int = 2160
static var _lane_paths: Dictionary = {}
static var _lane_ids_sorted: Array = []
## Task-H: per-lane built seasonal variants (`lane_id → [{id, months, path}]`,
## file order — the built artifact's own order; the shipped data has at most
## one variant per lane). Empty when the lane sails one path year-round.
static var _lane_variants: Dictionary = {}
static var _spoke_paths: Dictionary = {}
static var _spoke_lane: Dictionary = {}
static var _tile_lanes: Dictionary = {}
## Every tile walked by any lane or spoke (task K): the "off the lane network"
## test for raider anchors — an anchored raider must camp *near* a chokepoint,
## never ON a path tile, where it would sit in the traffic lane forever
## (§4.11.11.1: within Chebyshev 3 **of** chokepoint tiles).
static var _path_tiles: Dictionary = {}
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
## Data-static caches (`ports.json` is a per-run constant — the
## `_ports_cache`/`_goods_cache` precedent): the per-nation port counts and
## the neutral-port count, read on every budget call.
var _port_counts_cache: Dictionary = {}
var _neutral_port_count: int = -1
## The per-day trickle-deficit ranking cache (the `_largest_deficit` pass):
## rebuilt on day change or any spawn/remove (`_deficit_day = -1`).
var _deficit_day: int = -1
var _deficit_list: Array = []
## The per-(nation, day) alignment-pool cache (`alignment_ports`): the
## docking pool is a pure function of the day's ledger state.
var _align_cache: Dictionary = {}

## Runtime-only hunter pursuit plans (`fleet_id → {target, path}`); never
## saved — a fresh plan from the same state reproduces the same chase.
var _hunter_paths: Dictionary = {}

## Task-H parity accumulator (docs/60-* §4.11.11 amendment; task-H pin 3):
## `fleet_id → float` — the fractional tile remainder of the daily unified
## §4.4 budget `base × wind × direction × current` (and of every per-step
## pursuit allowance). Runtime-only, keyed by fleet id, reset on `new_game`
## ([method initial_fill]) and on load (the world scene adopts a fresh sim)
## — never persisted, mirroring the player drift accumulator's status. A
## refused/blocked step never spends the bank.
var _step_carry: Dictionary = {}

## Pass-through contacts (unified-movement amendment, `60-*` §4.11.11): ids
## of fleets that stepped within Chebyshev [constant CONTACT_DISTANCE] of
## the player's tile mid-step this day tick — the engagement rule applied
## to the pass-through exactly as to an end-of-step proximity. Consumed by
## [method nearest_contact] (one engagement per pass), reset with the run.
var _pass_contacts: Array = []

## Per-day memo of [method _leg_geometry] resolutions (unified-movement
## amendment: the tick walks each leg up to hull-speed budgets, so the
## per-call dict allocation + month-variant lookup is cached for the day).
## Invalidated on day change and on any net/route-table rebuild
## ([method _refresh_net]). Callers treat results as read-only.
var _geo_cache: Dictionary = {}
var _geo_cache_day: int = -1

## Small stable ints for the geometry-memo keys, split by kind
## (`leg_id → int`, assigned on first use — [method _leg_geometry]; the
## split tables keep the hot lookup free of string concatenation).
var _lane_path_ids: Dictionary = {}
var _spoke_path_ids: Dictionary = {}

## Per-day memo of [_passable] (see the memo note there): keyed by cell,
## invalidated on day change, reset with the run.
var _passable_cache: Dictionary = {}
var _passable_day: int = -1

## The player's tile, cached for the scope of one [method tick] (the tick
## commits thousands of cells and each commit compares against it; the
## player cannot move mid-tick). Outside a tick the live lookup runs
## ([method _player_tile_now]).
var _tick_player_tile := Vector2i(-1, -1)
var _tick_scoped := false

## The world-clock mark of the last per-move accrual bookkeeping — the
## `_pending_delta` sync guard only (movement itself is tracked PER FLEET
## in [_fleet_mark]). Runtime-only.
var _last_clock := -1.0

## The Δ the last [method advance_clock] consumed: a fleet routed by the
## day tick's departures owes exactly this remainder of the day (the old
## same-pass stepping guarantee — a just-departed fleet is never observed
## in its raw pre-step state).
var _pending_delta := 0.0

## Per-fleet accrual marks (`fleet_id → world clock`): each fleet accrues
## `now − its own mark` and is marked `now` — docked time never accrues,
## a fleet routed by a departure accrues the day's remainder exactly once
## ([method _depart] marks it `now` before granting [_pending_delta]), and
## a fresh sim's missing marks mean zero catch-up (the load sentinel).
## Runtime-only, reset with the run.
var _fleet_mark: Dictionary = {}

## Diagnostics (unified-movement amendment, `60-*` §4.12.x): `fleet_id →
## int` — consecutive accrual budgets consumed without forward progress
## (a blocked fleet holds its position while its budget spends). Reset on
## any real step; runtime-only, reset with the run, never saved. The
## observability behind [method stall_reason] / [method stalled_fleets].
var _hold_ticks: Dictionary = {}

## Per-fleet accrual telemetry (`fleet_id → Dictionary`): what the LAST
## accrual pass did for the fleet — `delta` (the Δ it was granted),
## `committed` (lane tiles actually walked), `budget`/`pipe` (the day
## budget + the §4.4 rate at recording time), `moved` (the position
## changed), `skip` (why a pass granted nothing: `cooldown`,
## `stale_mark` — the mark is ahead of the clock, `docked`). Runtime-only
## observability for the chart hover's `[raw2]` line (80-* §4.6); reset
## with the run, never saved.
var _accrual_dbg: Dictionary = {}

## Per-fleet journey event ring (`fleet_id → Array[String]`, oldest
## first, capped at [constant FLEET_EVENT_MAX]): `spawn`, `dep origin→dest`
## (a route was armed), `depX origin` (`route_between` empty — idle
## retry), `drop wedge|leg|seam` (the journey was dropped mid-route: the
## heading-empty wedge / a broken leg / a broken seam head), `arr port`
## (docked at the destination). The drop/re-depart cycle detector — a
## fleet idling at sea shows a `dep→drop→dep→drop` chain here. Runtime
## only, for the hover's `[raw3]` line (80-* §4.6); reset with the run.
var _fleet_events: Dictionary = {}

## The event ring cap (80-* §4.6 [raw3]).
const FLEET_EVENT_MAX := 8

## Appends one timestamped event to the fleet's ring (runtime-only).
func _note_event(id: String, text: String) -> void:
	var ring: Array = _fleet_events.get(id, [])
	if ring.is_empty():
		_fleet_events[id] = ring
	ring.append("%s@%d" % [text, int(GameState.day)])
	while ring.size() > FLEET_EVENT_MAX:
		ring.pop_front()

## Render reporting (80-* §4.5.2 amendment): `{id, from, to}` per fleet
## that moved in the last accrual — the world scene's marker glides. Never
## saved; drained by [method take_fleet_moves] (re-accumulates until
## consumed, so both the per-move callers and the day tick report).
var moved_fleet_moves: Array = []


## Drains (and returns) the render-move report since the last take.
func take_fleet_moves() -> Array:
	var out: Array = moved_fleet_moves
	moved_fleet_moves = []
	return out

## Task-H variant state (`fleet_id → {key, walked_len}`): the lane-path
## identity whose progress the fleet's `tile_index` is currently relative
## to. When [method _leg_geometry] resolves a DIFFERENT identity (first
## resolution after spawn/load, or a month rollover that swaps base ↔
## variant), progress remaps by fraction — the §2.8 pin. Runtime-only (the
## persisted route keeps its base-relative `legs`/`tile_index` shape).
var _leg_active: Dictionary = {}

## Task L (docs/80-* §4.5.2): transient wake trails, `fleet_id →
## [Vector2i, …]` most recent first, ≤ [constant WAKE_LENGTH] entries —
## the cells a fleet has LEFT BEHIND. Never saved (a reloaded fleet simply
## has no trail until it moves again).
var _wake_trails: Dictionary = {}

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


## Density-dial seam (docs/60-* §4.1.1 "budgets multiply by the preset",
## docs/80-* §4.6.3): applies a mid-run preset change to a **live** sim.
## Sims read `GameState.npc_preset` at construction (the world scene builds one
## per scene entry), so S19 only writes the field — this seam covers a host
## that keeps its sim across the change. Raising makes the daily trickle
## refill toward the new budgets; lowering **never culls** living fleets (the
## trickle only spawns on a deficit); `deserted` stops every spawn. Returns
## the applied preset id.
func set_preset(preset: String) -> String:
	var presets: Dictionary = {}
	var npc_config: Dictionary = _config.get("npc_config", DataLoader.npc_config)
	if npc_config.get("presets", {}) is Dictionary:
		presets = npc_config["presets"]
	_preset = str(preset) if presets.has(str(preset)) else str(
		npc_config.get("default_preset", "normal"))
	_config["preset"] = _preset
	return _preset


func _port_counts() -> Dictionary:
	if not _port_counts_cache.is_empty():
		return _port_counts_cache
	var counts: Dictionary = {}
	for port in DataLoader.ports_list:
		var nation_id := str((port as Dictionary).get("nation_id", ""))
		if nation_id.is_empty():
			continue
		counts[nation_id] = int(counts.get(nation_id, 0)) + 1
	_port_counts_cache = counts
	return counts


# --- Phase-7 allegiance guard (docs/60-* §4.11.14; docs/80-* §4.9) ----------

## The allegiance module or `null`: exists-check, then a per-call `load` by
## path (Godot's resource cache answers with the path's CURRENT owner, so a
## suite fixture installed with `take_over_path` wins — the economy.gd
## dev-guard pattern). Method guards live at the call sites so a partial
## fixture only replaces what it implements.
static func _allegiance_lib() -> Script:
	if not ResourceLoader.exists(ALLEGIANCE_PATH, "Script"):
		return null
	var lib: Script = load(ALLEGIANCE_PATH)
	return lib


## The port's effective alignment (docs/30-* §4.9): the persisted allegiance
## at a contestable port, the owner at a protected one — read through the
## guard. Default while the module (or the method) is absent: the data
## `nation_id` (the C-contract default).
static func port_alignment(port_id: String) -> String:
	var lib := _allegiance_lib()
	if lib != null and lib.has_method("effective_alignment"):
		return str(lib.call("effective_alignment", port_id))
	return str(DataLoader.get_port(port_id).get("nation_id", ""))


## The unified-tariff rate for `payer_nation` trading at `port_id`
## (docs/30-* §4.10: 0 after a permit, 500 in-sphere, 2000 foreign — the
## C-contract basis points). Guard default: 500 when the port's effective
## alignment equals the payer, else 2000 (only a module-less world reads it).
static func _tariff_mille_for(port_id: String, payer_nation: String) -> int:
	var lib := _allegiance_lib()
	if lib != null and lib.has_method("tariff_mille"):
		return maxi(0, int(lib.call("tariff_mille", port_id, payer_nation)))
	return 500 if port_alignment(port_id) == payer_nation else 2000


## Credits the unified tariff of one NPC port-call trade into the host
## treasury (docs/60-* §4.11.14, decisions 19/20): the walked `units` at the
## call's standing `price`, taxed `units × price × mille / 10000` and handed
## to the guard-read `Allegiance.credit_tax` — host = the port's effective
## alignment; the 2,000g/host/month NPC cap lives INSIDE credit_tax. A
## nationless payer (`""` — the grey coasters) is exempt: no call at all.
func _credit_port_tax(port_id: String, fleet: Dictionary, units: int,
		price: int) -> void:
	var payer := str(fleet.get("nation_id", ""))
	if payer.is_empty() or units <= 0 or price <= 0:
		return
	var mille := _tariff_mille_for(port_id, payer)
	if mille <= 0:
		return
	@warning_ignore("integer_division")
	var tax := units * price * mille / 10000
	if tax <= 0:
		return
	var lib := _allegiance_lib()
	if lib != null and lib.has_method("credit_tax"):
		lib.call("credit_tax", port_id, payer, tax)


## The neutral-port count (the data `nation_id == ""` tier — 45 ports). The
## nationless-coaster budget's base (`60-*` §4.11.14: one data line covers
## the neutral ports; the nation line keeps counting nation ports only).
## Data-static per run, like `_port_counts`.
func neutral_port_count() -> int:
	if _neutral_port_count >= 0:
		return _neutral_port_count
	var count := 0
	for port in DataLoader.ports_list:
		if str((port as Dictionary).get("id", "")).is_empty():
			continue
		if str((port as Dictionary).get("nation_id", "")) == "":
			count += 1
	_neutral_port_count = count
	return count


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


## Ports whose **effective alignment** == `nation_id`, ids sorted (docs/60-*
## §4.11.14 docking pool: protected own + contestable aligned — sovereign
## non-core and neutral alike). Day-keyed cache: the docking pool is a pure
## function of the persisted ledger state, which can only change BETWEEN
## day ticks (a player flip lands in the port screen; the monthly AI lands
## on the month seam) — so one build per (nation, day) is exact; the next
## tick rebuilds. The departure decisions read this 2× per call, and a
## build scans all 145 ports through the guard — at ~340 fleets the day
## tick was paying ≈ 10 ms/day uncached.
func alignment_ports(nation_id: String) -> Array[String]:
	if nation_id.is_empty():
		return []
	var cached: Array = _align_cache.get(nation_id, [])
	if not cached.is_empty():
		var day: int = int(cached[0])
		if day == int(GameState.day):
			var out: Array[String] = []
			for index in range(1, cached.size()):
				out.append(str(cached[index]))
			return out
	var out: Array[String] = []
	for port in DataLoader.ports_list:
		var id := str((port as Dictionary).get("id", ""))
		if id.is_empty() or _port_cell(id).x < 0:
			continue
		if port_alignment(id) == nation_id:
			out.append(id)
	out.sort()
	var stored: Array = [int(GameState.day)]
	for value in out:
		stored.append(value)
	_align_cache[nation_id] = stored
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
	var npc_config: Dictionary = _config.get("npc_config", DataLoader.npc_config)
	match role:
		TRADER:
			return ceili(own * float(budgets.get("traders_mult_per_port", 1.25)) * mult)
		COASTER:
			if nation_id.is_empty():
				# The nationless tier (docs/60-* §4.11.14, correction 15):
				# one top-level data line covers the neutral ports —
				# ceil(45 × 0.75) = 34 at normal. The nation line below
				# keeps its meaning.
				return ceili(neutral_port_count()
					* float(npc_config.get("neutral_coasters_mult", 0.75))
					* mult)
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
			return 0  # not a budget role: task L's seasonal scheduler owns it
			# (1/nation/season, §4.11.11.4; lives in the global-cap slack)
	return 0


## Core cap: the sum of the persistent role budgets across all owners
## (docs/60-* §4.1.1: 272 at normal — plus the §4.11.14 nationless-coaster
## line since Phase 7: 273 + ceil(45 × 0.75) = 307).
func core_cap() -> int:
	var total := 0
	for nation_id in _port_counts():
		for role in [TRADER, COASTER, PATROL, COURIER, PRIVATEER]:
			total += budget_for(role, nation_id)
	total += budget_for(COASTER, "")
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
	_successor_cursor = 0  # per-run transient (respawns live in GameState)
	_wake_trails = {}  # per-run transient (a fresh sim starts empty anyway)
	# Task-H transients: the fractional budget accumulator and the variant
	# progress state reset with the run (never persisted, §2.8/task-H pin 3).
	_step_carry = {}
	_leg_active = {}
	_pass_contacts = []
	_last_clock = -1.0
	_pending_delta = 0.0
	_fleet_mark = {}
	_hold_ticks = {}
	_accrual_dbg = {}
	moved_fleet_moves = []
	_geo_cache = {}
	_passable_cache = {}
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
			COASTER:
				# Phase-7 (§4.11.14): the nationless grey tier fills its own
				# line first — the neutral ports' local distributors — then
				# the nation lines (unchanged meaning).
				var grey_want := budget_for(COASTER, "") / 2
				for _index in grey_want:
					if spawned >= target:
						break
					if not spawn(COASTER, "", int(day)).is_empty():
						spawned += 1
				for nation_id in _port_counts():
					if spawned >= target:
						return
					var nation_want := budget_for(role, nation_id) / 2
					for _index in nation_want:
						if spawned >= target:
							break
						if not spawn(role, nation_id, int(day)).is_empty():
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
	_age_wrecks(int(day))
	if is_deserted():
		return []
	_ensure_rng()
	_tick_scoped = true
	_tick_player_tile = GameState.world_tile()
	# State machines first (unified-movement ordering): prey picks, chase
	# opens, dwell departures — then the clock accrual moves every fleet
	# under the decisions just made, so a chase opened this tick pursues
	# this tick (the hunter-intel flow's one-tick closure pin).
	_step_fleets(int(day))
	# Movement accrual: catch up every elapsed fraction of the world clock
	# — in headless drivers and after port day-skips this is the whole day;
	# in real play the per-move callers (world scene) already accrued the
	# fractions and this call nets zero. The clock-sync guard makes both
	# orders safe.
	advance_clock()
	_recount_zones(int(day))
	_schedule_treasure(int(day))
	_named_pirate_tick(int(day))
	var out := _trickle(int(day))
	_tick_scoped = false
	return out


## Movement accrual (unified-movement amendment, `60-*` §4.11.11): NPC
## movement is a pure function of elapsed world time — every fleet accrues
## its §4.4 pipeline progress (`Δ × base × wind × direction × current`
## tiles per Δ days) and steps one tile per accrued tile, released in step
## with the player's own clock. A player helm move advances ≈ one tile on
## every fleet (player and NPC speeds are now the same pipeline), so the
## sea never jumps at a day boundary and no remainder is ever flushed.
## Idempotent on the world clock: repeated calls accrue only the
## not-yet-accrued fraction, so the per-move callers and the day tick's
## catch-up (port day-skips, headless drivers) can never double-step.
## The sync mark is runtime-only: a freshly adopted sim syncs without
## catching up — a reloaded fleet resumes accrual from the load instant.
func advance_clock() -> void:
	var now := _clock_now()
	if _last_clock < 0.0:
		_last_clock = now
		_pending_delta = 0.0
		return
	var delta := now - _last_clock
	var prev_clock := _last_clock
	_last_clock = now
	_pending_delta = delta
	if delta <= 0.0 or is_deserted() or SailingSimLib.is_game_over():
		return
	var day := int(GameState.day)
	var remove_ids: Array = []
	var wrecks: Array = []
	# The pass's engagement ledger (the day tick's `doomed` shape): a prey
	# resolved by one raider can never be re-engaged by a later one.
	var doomed: Dictionary = {}
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		# Inclusive pursuit cooldown: a battle on day D stores D+1, so the
		# fleet holds through D+1 — movement included (the day tick's
		# stepping skip carried over).
		if int(fleet.get("cooldown_until_day", 0)) >= day:
			_accrual_dbg[str(fleet.get("id", ""))] = {
				"delta": 0.0, "skip": "cooldown"}
			continue
		var id := str(fleet.get("id", ""))
		# Per-fleet accrual: `now − own mark`. A fleet without a mark (a
		# test fixture) owes the full tick delta — only [method spawn] and
		# [method _depart] pre-mark fleets.
		var mark := float(_fleet_mark.get(id, prev_clock))
		var fleet_delta := now - mark
		if fleet_delta <= 0.0:
			# Clock-rewind rebase (60-* §4.11.11): a mark AHEAD of the
			# clock — set sail resets `clock_fraction` to 0 (20-* §4.3,
			# port time is day-granular), rewinding the clock under marks
			# set inside the rewound window. Snap the mark to the clock:
			# the rewound window is forfeit (those fleets already walked
			# it), so the next pass accrues its own per-move slice.
			# Freezing until the clock re-passed the mark — then lumping
			# the owed days at the roll — was the "moves once a day"
			# day-jump bug.
			_fleet_mark[id] = now
			_accrual_dbg[id] = {"delta": fleet_delta,
				"skip": "stale_mark"}
			continue
		_fleet_mark[id] = now
		_accrual_dbg[id] = {"delta": fleet_delta}
		# Render reporting (80-* §4.5.2 amendment): from → to for the
		# marker glide; multi-tile walks report the first and last cell.
		var moved_from := position_of(fleet)
		match str(fleet.get("role", "")):
			PIRATE, PRIVATEER:
				_accrue_raider(fleet, day, fleet_delta, doomed, remove_ids,
					wrecks)
			HUNTER:
				_accrue_hunter(fleet, day, fleet_delta)
			_:
				_accrue_lane(fleet, day, fleet_delta)
		var moved_to := position_of(fleet)
		if _accrual_dbg.has(id):
			(_accrual_dbg[id] as Dictionary)["moved"] = moved_to != moved_from
		if moved_to != moved_from:
			moved_fleet_moves.append({"id": id, "from": moved_from,
				"to": moved_to})
	for id in remove_ids:
		remove(id)
	for wreck in wrecks:
		GameState.wrecks.append(wreck)


## The absolute world clock (`day + clock_fraction`) — the accrual's time
## base ([method advance_clock]).
func _clock_now() -> float:
	return float(GameState.day) + float(
		GameState.world.get("clock_fraction", 0.0))


func _accrue(delta: float) -> void:
	var day := int(GameState.day)
	var remove_ids: Array = []
	var wrecks: Array = []
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		# Inclusive pursuit cooldown: a battle on day D stores D+1, so the
		# fleet holds through D+1 — movement included (the day tick's
		# stepping skip carried over).
		if int(fleet.get("cooldown_until_day", 0)) >= day:
			continue
		match str(fleet.get("role", "")):
			PIRATE, PRIVATEER:
				_accrue_raider(fleet, day, delta, {}, remove_ids, wrecks)
			HUNTER:
				_accrue_hunter(fleet, day, delta)
			_:
				_accrue_lane(fleet, day, delta)
	for id in remove_ids:
		remove(id)
	for wreck in wrecks:
		GameState.wrecks.append(wreck)


## Lane accrual for one fleet: whole days walk exactly the day budgets
## ([method _lane_tiles_today] — the same pins headless drivers assert);
## the fractional remainder of Δ accrues at the current leg heading's
## pipeline and banks its sub-tile remainder. Arrivals mid-accrual end the
## walk (the fleet dwells; the day tick departs it).
func _accrue_lane(fleet: Dictionary, day: int, delta: float) -> void:
	var id := str(fleet.get("id", ""))
	# Docked fleets owe no movement (the day tick departs them; the fast
	# path keeps the per-move accrual O(fleets) with no geometry work).
	if ((fleet.get("route", {}) as Dictionary).get("legs", [])
			as Array).is_empty():
		_accrual_dbg[id] = {"delta": delta, "skip": "docked"}
		return
	var committed_total := 0
	for _d in int(floor(delta)):
		committed_total += _walk_lane(fleet, day, _lane_tiles_today(fleet))
	var fraction: float = delta - floor(delta)
	if fraction > 0.0 and not _lane_step_heading(fleet).is_empty():
		var raw: float = _lane_pipe(fleet) * fraction \
			+ float(_step_carry.get(id, 0.0))
		var tiles := int(floor(raw))
		_step_carry[id] = raw - float(tiles)
		committed_total += _walk_lane(fleet, day, tiles)
	# Diagnostics + escalation ([method stall_reason]): the hold streak
	# counts accruals whose walks COMMITTED ZERO tiles — a fleet banking
	# sub-tile fractions (a slow hull against wind/current) is healthy,
	# never a hold; any committed tile resets the streak. **Escalation**
	# (unified-movement amendment): at `STALL_HOLD_TICKS`+ consecutive
	# zero-commit accruals the journey is DROPPED — the day tick's docked
	# branch re-departs the fleet fresh from the nearest resolvable port,
	# so no wedge (seam, terminus, or otherwise) can stall a fleet
	# permanently. `blocked` remains visible while the holds accumulate
	# (the S3 badge / hover / scan).
	if committed_total > 0:
		_hold_ticks[id] = 0
	else:
		_hold_ticks[id] = int(_hold_ticks.get(id, 0)) + 1
	# Telemetry (80-* §4.6 hover [raw2]): what this pass granted and did.
	var telemetry: Dictionary = _accrual_dbg.get(id, {})
	if telemetry.is_empty():
		_accrual_dbg[id] = telemetry
	telemetry["delta"] = delta
	telemetry["committed"] = committed_total
	telemetry["budget"] = _lane_tiles_today(fleet)
	telemetry["pipe"] = _lane_pipe(fleet)


## The §4.4 lane pipeline for the fleet's current leg heading — tiles per
## day before banking (the [method _lane_tiles_today] budget's rate term).
func _lane_pipe(fleet: Dictionary) -> float:
	var heading := _lane_step_heading(fleet)
	if heading.is_empty():
		return 0.0
	var base: Array = _fleet_base(fleet)
	var ship_class := str(base[1])
	var month := SailingSimLib.month_for(GameState.day)
	var weather := str(GameState.world.get("weather",
		SailingSimLib.DEFAULT_WEATHER))
	var cell := position_of(fleet)
	return float(int(base[0])) \
		* SailingSimLib.wind_factor(weather, ship_class) \
		* npc_direction_factor(heading, cell, month, ship_class) \
		* npc_current_factor(heading, cell, month)


## Raider accrual: a chasing raider walks its §4.4 allowance toward the
## prey with the engagement re-checked per committed tile — a mid-day
## catch resolves now (queued into the pass's removal lists, applied by
## [method advance_clock]); an off-lane raider accrues toward its anchor
## under the unchanged return rule. Prey picking/chasing state stays with
## the day tick ([method _raider_tick]); `doomed` is the pass's ledger —
## a prey resolved by an earlier raider is never re-engaged.
func _accrue_raider(fleet: Dictionary, day: int, delta: float,
		doomed: Dictionary, remove_ids: Array, wrecks: Array) -> void:
	var target := _find(str(fleet.get("target_fleet_id", "")))
	if not target.is_empty() and (doomed.has(str(target.get("id", ""))) \
			or chebyshev(position_of(fleet),
				position_of(target)) > CHASE_OFF_RADIUS):
		fleet["target_fleet_id"] = ""  # §4.11.11.1: lost/beyond 16 — drop
		target = {}
	if target.is_empty():
		var cell := position_of(fleet)
		var anchor := _cell_field(fleet.get("anchor_cell", null))
		if anchor != NO_CELL and (chebyshev(cell, anchor) > ANCHOR_RADIUS \
				or _is_path_tile(cell)):
			for _i in _chase_budget(fleet, anchor, delta):
				_step_toward(fleet, anchor)
		return
	var prey_cell := position_of(target)
	var tiles := _chase_budget(fleet, prey_cell, delta)
	for _i in tiles:
		target = _find(str(fleet.get("target_fleet_id", "")))
		if target.is_empty():
			break  # the prey is gone (a wreck this tick): hold
		prey_cell = position_of(target)
		if chebyshev(position_of(fleet), prey_cell) <= CONTACT_DISTANCE:
			_engage(fleet, target, day, doomed, remove_ids, wrecks)
			break
		_step_toward(fleet, prey_cell)


## Hunter accrual: a chasing hunter pursues on the clock (per-step §4.4
## allowance through the cached A* plan); every other hunter walks its
## lanes exactly like a lane role. The intel state machine (chase open,
## loiter, route home) stays with the day tick ([method _hunter_tick]).
func _accrue_hunter(fleet: Dictionary, day: int, delta: float) -> void:
	if str(fleet.get("hunter_state", HUNTER_STATE_INTEL)) == HUNTER_STATE_CHASE:
		var target := GameState.world_tile()
		if chebyshev(position_of(fleet), target) <= HUNTER_CHASE_OFF:
			_pursue(fleet, target, 0.0, delta)
			return
	_accrue_lane(fleet, day, delta)


## Every live fleet dict (the §4.11.11 shape) — the save payload. Shallow
## array copy; the dicts are the stored ones, so a fixture may adjust a fleet
## in place.
func fleets() -> Array:
	return GameState.npc_fleets.duplicate()


## Render dicts for the world scene (docs/80-* §4.5.2): `{id, role,
## nation_id, cell, letter}` plus task L's aliveness fields — `sailing` and
## the ≤ 5-tile `wake` trail from the transient wake table (docked markers
## report no wake), and the convoy grouping (`convoy_count` ≥ 2 marks the
## leader of one group of same-lane traders within Chebyshev 3, §4.11.11.4;
## members carry `convoy_leader`). One entry per fleet — the render layer
## collapses convoys to one marker. Diagnostics (unified-movement
## amendment, 80-* §4.6): `holds`/`stall` feed the S3 badge + hover census,
## and `dbg`/`dbg2` are the hover's raw lines — `dbg` the live fleet
## state, `dbg2` the accrual telemetry (`now/pend/lastd/moved/skip/
## committed/budget/pipe/cd/leg0`) that discriminates per-move accrual
## from day-jump movement and stale-mark freezes. Read-only over the
## fleets; no RNG.
func markers() -> Array:
	var out: Array = []
	var convoy_leaders: Dictionary = _convoy_leaders()
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		var id := str((fleet as Dictionary).get("id", ""))
		var sailing: bool = not ((fleet as Dictionary).get("route", {}) \
			as Dictionary).get("legs", []).is_empty()
		var wake: Array = []
		if sailing:
			for cell in _wake_trails.get(id, []):
				wake.append(cell)
		var leader_id := str(convoy_leaders.get(id, ""))
		# Diagnostics (unified-movement amendment, `60-*` §4.12.x): the
		# hold streak + stall state ride the marker entry for the debug
		# surfaces (S3 badge, chart tooltip). `stall` is "" while sailing.
		var holds := int(_hold_ticks.get(id, 0))
		var stall := stall_state(fleet, holds)
		if stall == "sailing":
			stall = ""
		# Accrual telemetry (80-* §4.6 [raw2]): the clock vs this fleet's
		# mark + what the last accrual pass granted/did — the per-move vs
		# day-jump discriminator (pend<0 ⇒ frozen at a stale mark;
		# lastd≈1.0 moved=1 once per day ⇒ only the day tick accrues).
		var now := _clock_now()
		var mark := float(_fleet_mark.get(id, NAN))
		var pend := "n/a"
		if not is_nan(mark):
			pend = "%.3f" % (now - mark)
		var acc: Dictionary = _accrual_dbg.get(id, {})
		var legs_arr: Array = (fleet.get("route", {}) as Dictionary).get(
			"legs", [])
		var leg_txt := "-"
		if not legs_arr.is_empty():
			var leg0: Dictionary = legs_arr[0]
			var geo := _leg_geometry(leg0)
			leg_txt = "%s[%s..%s]R%d %d/%d" % [
				str(leg0.get("id", "?")), str(leg0.get("a", "?")),
				str(leg0.get("b", "?")),
				1 if bool(leg0.get("reverse", false)) else 0,
				int((fleet.get("route", {}) as Dictionary).get(
					"tile_index", -1)),
				int(geo.get("walked_len", -1)) if not geo.is_empty()
					else -1,
			]
		var dbg2 := "now=%.3f pend=%s" % [now, pend]
		if acc.is_empty():
			dbg2 += " last=-"
		else:
			dbg2 += " lastd=%.3f moved=%d skip=%s committed=%s budget=%s pipe=%.1f" % [
				float(acc.get("delta", 0.0)),
				1 if bool(acc.get("moved", false)) else 0,
				str(acc.get("skip", "-")),
				str(acc.get("committed", "-")),
				str(acc.get("budget", "-")),
				float(acc.get("pipe", 0.0)),
			]
		dbg2 += " cd=%d leg0=%s" % [
			int((fleet as Dictionary).get("cooldown_until_day", 0)), leg_txt]
		# Journey history (80-* §4.6 [raw3]): the event ring + the mooring
		# truth (a docked-stall fleet reports its real berth owner here; a
		# fleet off its berth shows `at=-`, which is what the fallback `@
		# port` display in the summary line is NOT).
		var events: Array = _fleet_events.get(id, [])
		var mooring_here := _port_at_cell(position_of(fleet))
		var here := position_of(fleet)
		var dest_txt := str((fleet as Dictionary).get("dest_port_id", ""))
		var dbg3 := "dest=%s mooring=%s cell=%d,%d ev=" % [
			dest_txt if not dest_txt.is_empty() else "-",
			mooring_here if not mooring_here.is_empty() else "-",
			here.x, here.y,
		]
		if events.is_empty():
			dbg3 += "-"
		else:
			dbg3 += " ".join(events)
		var entry := {
			"id": id,
			"role": str((fleet as Dictionary).get("role", "")),
			"nation_id": str((fleet as Dictionary).get("nation_id", "")),
			"cell": position_of(fleet),
			"letter": marker_letter(str((fleet as Dictionary).get("role", ""))),
			"sailing": sailing,
			"wake": wake,
			"convoy_count": int(convoy_leaders.get(id + "#count", 0)) \
				if leader_id == id else 0,
			"convoy_leader": leader_id,
			"holds": holds,
			"stall": stall,
			"heading": _lane_step_heading(fleet),
			"speed": _lane_pipe(fleet),
			"dest": str((fleet as Dictionary).get("dest_port_id", "")),
			"lanes": (fleet.get("route", {}) as Dictionary).get("lanes", []),
			"dbg": "cell=(%d,%d) dwell=%d day=%d legs=%d ti=%d holds=%d carry=%.2f mark=%.3f"
				% [
				position_of(fleet).x, position_of(fleet).y,
				int((fleet as Dictionary).get("dwell_until_day", 0)),
				int(GameState.day),
				((fleet.get("route", {}) as Dictionary).get("legs", [])
					as Array).size(),
				int((fleet.get("route", {}) as Dictionary).get(
					"tile_index", -1)),
				int(_hold_ticks.get(id, 0)),
				float(_step_carry.get(id, 0.0)),
				float(_fleet_mark.get(id, -1.0)),
			],
			"dbg2": dbg2,
			"dbg3": dbg3,
		}
		if stall == "docked":
			# The mooring port (the berth's owner) + berth consistency —
			# the docked-stall detail (a fleet docked in open water is an
			# anomaly the day tick self-heals).
			var mooring := _port_at_cell(position_of(fleet))
			entry["port"] = mooring if not mooring.is_empty() \
				else str((fleet as Dictionary).get("dest_port_id", ""))
			entry["on_berth"] = not mooring.is_empty()
			# A "docked" fleet standing OFF any berth is STRANDED, not
			# docked — the summary line must never claim `@ <port>` for a
			# fleet that is nowhere near it (the false-mooring report).
			if not entry["on_berth"]:
				entry["stall"] = "stranded"
				entry["port"] = ""
		out.append(entry)
	return out


# --- Diagnostics (unified-movement amendment, `60-*` §4.12.x) ----------------

## The one-word stall state of a fleet, evaluated in priority order:
## `docked` (dwell not expired **and no route legs** — a fleet with legs is
## under way even inside its spawn-dwell window) → `cooldown` (pursuit
## cooldown) → `camping` (a targetless raider within its anchor radius,
## off-lane — the §4.11.11.1 camping pattern) → `chasing`/`pursuing`
## (raider with a target / hunter in chase) → `blocked` (under way but
## held `STALL_HOLD_TICKS`+ accrual budgets) → `sailing`. `holds` is the
## current hold streak ([_hold_ticks]). Read-only, no RNG.
func stall_state(fleet: Dictionary, holds: int) -> String:
	var day := int(GameState.day)
	var role := str(fleet.get("role", ""))
	var legs_empty := ((fleet.get("route", {}) as Dictionary).get("legs", [])
		as Array).is_empty()
	if int(fleet.get("dwell_until_day", 0)) > day and legs_empty:
		# Berth truth (unified-movement amendment, `60-*` §4.11.11):
		# "docked" means standing ON a port's berth tile — a fleet holding
		# in open water is `stranded` (the false-mooring report), and the
		# day tick's berth-consistency heal snaps it back.
		if not _port_at_cell(position_of(fleet)).is_empty():
			return "docked"
		return "stranded"
	if int(fleet.get("cooldown_until_day", 0)) >= day:
		return "cooldown"
	if (role == PIRATE or role == PRIVATEER) \
			and str(fleet.get("target_fleet_id", "")).is_empty():
		var anchor := _cell_field(fleet.get("anchor_cell", null))
		var cell := position_of(fleet)
		if anchor != NO_CELL and chebyshev(cell, anchor) <= ANCHOR_RADIUS \
				and not _is_path_tile(cell):
			return "camping"
	if (role == PIRATE or role == PRIVATEER) \
			and not str(fleet.get("target_fleet_id", "")).is_empty():
		return "chasing"
	if role == HUNTER \
			and str(fleet.get("hunter_state", "")) == HUNTER_STATE_CHASE:
		return "pursuing"
	if holds >= STALL_HOLD_TICKS \
			and not ((fleet.get("route", {}) as Dictionary).get("legs", [])
				as Array).is_empty():
		return "blocked"
	return "sailing"


## The full stall record for one fleet: `{id, role, cell, state, holds}`
## plus the state's detail (`until` for docked/cooldown, `radius` for
## camping, `pipe` for sailing — the §4.4 tiles/day rate, so a headwind
## crawl shows its tiny rate instead of looking like a bug). Read-only.
func stall_reason(fleet: Dictionary) -> Dictionary:
	var holds := int(_hold_ticks.get(str(fleet.get("id", "")), 0))
	var state := stall_state(fleet, holds)
	var heading := _lane_step_heading(fleet)
	var pipe := _lane_pipe(fleet)
	var out := {
		"id": str(fleet.get("id", "")),
		"role": str(fleet.get("role", "")),
		"cell": position_of(fleet),
		"state": state,
		"holds": holds,
		"heading": heading,
		"speed": pipe,
		"dest": str(fleet.get("dest_port_id", "")),
	}
	if state == "docked":
		out["until"] = int(fleet.get("dwell_until_day", 0))
		var mooring := _port_at_cell(position_of(fleet))
		out["port"] = mooring if not mooring.is_empty() \
			else str(fleet.get("dest_port_id", ""))
		out["on_berth"] = not mooring.is_empty()
	elif state == "stranded":
		# Dwell holding in open water: no berth, and the destination name
		# is NOT a mooring (the false-mooring report) — the day tick's
		# berth-consistency heal snaps it to a berth next tick.
		out["until"] = int(fleet.get("dwell_until_day", 0))
		out["on_berth"] = false
		out["dest"] = str(fleet.get("dest_port_id", ""))
	elif state == "cooldown":
		out["until"] = int(fleet.get("cooldown_until_day", 0))
	elif state == "camping":
		var anchor := _cell_field(fleet.get("anchor_cell", null))
		if anchor != NO_CELL:
			out["radius"] = chebyshev(position_of(fleet), anchor)
	elif state == "sailing":
		out["pipe"] = _lane_pipe(fleet)
	return out


## Every fleet in a suspicious state — `blocked` at or above `min_hold`
## hold ticks, or `camping` (by design, but observable). Read-only; the
## debug chart row and console sweeps are its consumers.
func stalled_fleets(min_hold: int = STALL_HOLD_TICKS) -> Array:
	var out: Array = []
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		var holds := int(_hold_ticks.get(str(fleet.get("id", "")), 0))
		var state := stall_state(fleet, holds)
		if state == "blocked" and holds >= min_hold:
			out.append({
				"id": str(fleet.get("id", "")),
				"role": str(fleet.get("role", "")),
				"cell": position_of(fleet),
				"state": state,
				"holds": holds,
			})
		elif state == "camping":
			var reason := stall_reason(fleet)
			reason["holds"] = holds
			out.append(reason)
	return out


## Convoy grouping (§4.11.11.4, render side): greedy over traders in fleet-id
## order — the first ungrouped trader leads its [method convoy_members] set.
## Returns `{fleet_id → leader_id}` plus `"<id>#count"` entries for leaders.
func _convoy_leaders() -> Dictionary:
	var leaders: Dictionary = {}
	var grouped: Dictionary = {}
	var traders: Array = []
	for fleet in GameState.npc_fleets:
		if fleet is Dictionary and str((fleet as Dictionary).get("role", "")) == TRADER:
			traders.append(fleet)
	traders.sort_custom(func(a, b) -> bool:
		return str((a as Dictionary).get("id", "")) \
			< str((b as Dictionary).get("id", "")))
	for fleet in traders:
		var id := str((fleet as Dictionary).get("id", ""))
		if grouped.has(id):
			continue
		var members := convoy_members(fleet)
		for member in members:
			grouped[str((member as Dictionary).get("id", ""))] = true
		if members.size() >= 2:
			leaders[id] = id
			leaders[id + "#count"] = members.size()
			for member in members:
				if member != fleet:
					leaders[str((member as Dictionary).get("id", ""))] = id
		else:
			leaders[id] = ""
	return leaders


## §4.11.11.2 contact rule: the nearest hostile fleet (pirate / privateer /
## hunter-with-bounty) within Chebyshev 1 of `cell`, wrap-aware. A fleet on
## its pursuit cooldown raises no contact. `{}` when none.
func nearest_contact(cell: Vector2i) -> Dictionary:
	var found := contacts(cell)
	# Unified-movement amendment: consume the tick's pass-through contacts —
	# a hostile fleet that touched the player mid-step engages even though it
	# has since moved on (one engagement per pass; the fleet's own
	# cooldown/hostility rules re-checked here exactly as `contacts` does).
	var passed: Array = _pass_contacts.duplicate()
	_pass_contacts.clear()
	for id in passed:
		var fleet := _find(str(id))
		if fleet.is_empty() or not is_hostile_fleet(fleet):
			continue
		if int(fleet.get("cooldown_until_day", 0)) >= GameState.day:
			continue
		found.append(fleet)
	if found.is_empty():
		return {}
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da := chebyshev(cell, position_of(a))
		var db := chebyshev(cell, position_of(b))
		if da != db:
			return da < db
		return str(a.get("id", "")) < str(b.get("id", "")))
	return found[0]


## Every hostile fleet within Chebyshev 1 of `cell`, nearest first (ties by
## id ascending). `deserted` raises nothing (docs/80-* §4.6.3, docs/10-*
## density table: zero NPC spawns/contacts) even though living fleets stay on
## the map — lowering the dial never culls them.
func contacts(cell: Vector2i) -> Array:
	var day := GameState.day
	var out: Array = []
	if is_deserted():
		return out
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
## Task L (§4.11.11.4): defeating a **named** pirate reserves its slot — the
## famous identity retires (no trickle spawn can re-take it) and a successor
## under a new pool name is scheduled for +30 days, inheriting the tier. The
## availability day persists in `GameState.named_pirate_respawns`
## (`{named_id: available_day}`, docs/90-* §8.1), so the window survives
## save/load; tiers need no storage — a famous defeat keys its own
## `named_pirates.json` id, a successor defeat books the single
## interchangeable alias slot as `successor_<tier>`.
func remove(id: String) -> void:
	for index in range(GameState.npc_fleets.size() - 1, -1, -1):
		var fleet = GameState.npc_fleets[index]
		if fleet is Dictionary and str((fleet as Dictionary).get("id", "")) == id:
			var captain: Dictionary = (fleet as Dictionary).get("captain", {})
			var named_id := str(captain.get("named_id", ""))
			if not named_id.is_empty():
				GameState.named_pirate_respawns[named_id] = \
					int(GameState.day) + NAMED_RESPAWN_DAYS
			elif int(captain.get("named_tier", 0)) > 0:
				# A defeated successor: the alias rotation sails again.
				GameState.named_pirate_respawns[
					"successor_%d" % int(captain.get("named_tier", 1))
				] = int(GameState.day) + NAMED_RESPAWN_DAYS
			GameState.npc_fleets.remove_at(index)
			_wake_trails.erase(id)  # transient trail of a dead fleet
			_step_carry.erase(id)  # task-H: dead fleets hold no budget bank
			_leg_active.erase(id)  # task-H: dead fleets hold no variant state
			_deficit_day = -1  # counts changed: the trickle's ranking rebuilds
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
	_note_event(str(fleet.get("id", "")), "spawn")
	# The fresh fleet owes nothing yet: its accrual mark starts now (the
	# first [method advance_clock] after the spawn grants exactly the
	# elapsed fraction, never the whole day).
	_fleet_mark[str(fleet.get("id", ""))] = _clock_now()
	return fleet


## Reseeds the world stream (the pinned test seam). Also clears the
## "this day already ticked" mark so a suite can replay the same sequence.
func reset_rng(seed_value: int) -> void:
	_rng.seed = seed_value
	_rng_seeded = true
	last_tick_day = -1


## Test/new-map seam: drops the shared lane-network and route caches (the
## network is derived purely from the loaded data, so this only matters to a
## fixture that swaps `DataLoader`'s tables or map between cases). Task L:
## the successor-name cursor is per-run transient too (the respawn schedule
## lives in `GameState.named_pirate_respawns`; wake trails are per-instance
## and a fresh sim starts with none).
static func reset_caches() -> void:
	_route_cache = {}
	_net_ready = false
	_width = 4320
	_height = 2160
	_lane_paths = {}
	_lane_variants = {}
	_lane_ids_sorted = []
	_spoke_paths = {}
	_spoke_lane = {}
	_tile_lanes = {}
	_path_tiles = {}
	_node_tiles = []
	_node_index = {}
	_adjacency = {}
	_ports_cache = {}
	_goods_cache = {}
	_scope_goods = []
	_successor_cursor = 0


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
			# Task L (§4.11.11.4): the seasonal fleet sails its nation's
			# historical lane — the lane the capital's spoke attaches to in
			# the built artifact. It boards at the tile nearest the capital
			# and walks the whole lane (the §4.1.1 patrol boarding pattern),
			# carrying ×3 a normal port call of a seeded nation good.
			var treasure := _treasure_journey(nation_id, day)
			if treasure.is_empty():
				return {}
			fleet["route"] = treasure["route"]
			cell = treasure["cell"]
			fleet["cargo"] = treasure["cargo"]
			fleet["dest_port_id"] = ""
			fleet["dwell_until_day"] = 0
		_:
			# Lane-locked roles: a journey between two own-nation ports.
			var journey := _role_journey(role, nation_id, day)
			if journey.is_empty():
				return {}
			return _finish_lane_fleet(fleet, journey, nation_id, day)
	fleet["id"] = next_fleet_id(day, role)
	fleet["seed"] = _fleet_seed(day, cell)
	# Unified-movement amendment: the §4.11.3 composition rides on the fleet
	# (it now drives the §4.4 base speed — `60-*` §4.11.11), and the derived
	# speed pair is cached HERE so reads (markers/diagnostics) never mutate
	# a fleet — the snapshot-purity invariant (`80-*` §4.6 probe).
	fleet["ships"] = compose_fleet_ships(fleet, int(day))
	_fleet_base(fleet)
	set_position(fleet, cell)
	_sync_route_progress(fleet)
	_record_wake(fleet, cell)
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
	# Unified-movement amendment: the §4.11.3 composition rides on the fleet
	# (it now drives the §4.4 base speed — `60-*` §4.11.11), and the derived
	# speed pair is cached HERE so reads (markers/diagnostics) never mutate
	# a fleet — the snapshot-purity invariant (`80-*` §4.6 probe).
	fleet["ships"] = compose_fleet_ships(fleet, int(day))
	_fleet_base(fleet)
	fleet["route"] = journey["route"]
	fleet["dest_port_id"] = str(journey.get("dest", ""))
	set_position(fleet, journey["cell"])
	# The boarding cell may sit mid-leg (the tile nearest the port): sync
	# the route progress to the ACTIVE geometry now — under clock accrual
	# the first step may be a fraction away, and the fleet must stand on
	# `path[a + tile_index]` from the instant it is under way.
	_sync_route_progress(fleet)
	_record_wake(fleet, journey["cell"])
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
## (pirates: the nationless `""` pool) — docs/60-* §4.11.11.4. A pirate also
## takes the first free **named-pirate** identity (file order, famous pirates
## override — §4.11.11.4); reserved names (a pending +30-day respawn) are
## never handed out.
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
	if str(fleet.get("role", "")) == PIRATE:
		var named_id := next_named_pirate_id()
		if not named_id.is_empty():
			(fleet["captain"] as Dictionary)["named_id"] = named_id


## The captain's display name (read seam for tests/L sightings). A famous
## pirate's name (§4.11.11.4 override) wins over the pool draw.
static func captain_name(fleet: Dictionary) -> String:
	var named := named_captain_of(fleet)
	if not named.is_empty():
		return I18n.t(named.get("name", {}))
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
## [constant ANCHOR_RADIUS] jitter, passable and unoccupied. Task K: the
## anchor prefers water **off every lane/spoke tile** (§4.11.11.1 anchors sit
## *within Chebyshev 3 of* chokepoint tiles, never on them — an anchor parked
## in the traffic lane would sit in the corridor forever); a strait whose
## every tile is a path tile falls back to an on-path anchor after half the
## draws (lane traffic hops over it, §4.11.11.1 "skipping occupied tiles").
func _raider_anchor(role: String, nation_id: String, day: int) -> Vector2i:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(day) * SEED_DAY_MULT + _id_seq * SEED_X_MULT \
		+ hash(role + "|" + nation_id)
	var candidates := _anchor_tiles(role, nation_id)
	for attempt in 32:
		if candidates.is_empty():
			break
		var pick: Vector2i = candidates[rng.randi_range(0, candidates.size() - 1)]
		var off_lane := attempt < 16
		var cell := _free_tile_near(pick, rng, ANCHOR_RADIUS, off_lane)
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
## drawn from `rng` over the ring offsets in deterministic order. With
## `avoid_paths` the draw skips lane/spoke tiles (the raider-anchor rule).
func _free_tile_near(center: Vector2i, rng: RandomNumberGenerator,
		radius: int, avoid_paths: bool = false) -> Vector2i:
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
		if avoid_paths and _is_path_tile(cell):
			continue
		if not _is_occupied(cell, ""):
			return cell
	return NO_CELL


## True when `cell` is walked by any lane or spoke (the lane-network raster;
## exact-tile lookup, not a radius query).
static func _is_path_tile(cell: Vector2i) -> bool:
	return _path_tiles.has(_cell_key(cell))


## The journey for a lane-locked role at spawn.
##
## * `trader`: docked at a seeded own port (the first dwell end makes the
##   real decision); dest = the nearest own port so a route always exists.
## * `coaster`: docked at a seeded own port, dest = its adjacent port.
## * `courier`: docked at a seeded own port, dest = the capital (or the
##   reverse at the capital).
## * `patrol`: docked at its nation's most-connected port, one lane armed.
func _role_journey(role: String, nation_id: String, day: int) -> Dictionary:
	# Phase-7 (§4.11.14): the grey coaster sails its own nearest-hop journey.
	if role == COASTER and nation_id.is_empty():
		return _grey_coaster_journey(day)
	# The trader spawn pool is the EFFECTIVE-ALIGNMENT pool (protected own +
	# contestable aligned — a flip re-serves the port on the new lane at
	# once); every other lane role stays on the data-ownership pool.
	var ports: Array[String] = alignment_ports(nation_id) if role == TRADER \
		else nation_ports(nation_id)
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
		# Lane roles sail between two ports of their pool. Some port pairs
		# share no lane component (the Pacific runs alone), so the draw
		# retries up to six origins before the spawn draw fails.
		for _attempt in 6:
			origin = ports[rng.randi_range(0, ports.size() - 1)]
			match role:
				TRADER:
					dest = _nearest_aligned_port_excluding(origin, nation_id)
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
					# The coaster role idles on its own cadence (§4.11.14
					# dwell lever); traders and couriers keep the 2-day dock.
					"dwell_until_day": int(day) + (_coaster_dwell_days()
						if role == COASTER else DWELL_DAYS),
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


## The nationless coaster's journey (docs/60-* §4.11.14, decision 18): a
## seeded draw from the neutral ports, hopping to the NEAREST port of ANY
## ownership — border-crossing local trade, never the long lanes. The
## standing coaster pins ride unchanged (≤ 5-unit calls, hold 10,
## saturation, never sell into factor ≤ 1.0); the goods scope clamps at
## buy/sell ([method in_coaster_scope]).
func _grey_coaster_journey(day: int) -> Dictionary:
	var neutrals := nation_ports("")
	if neutrals.is_empty():
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = int(day) * SEED_DAY_MULT + _id_seq * SEED_X_MULT \
		+ hash("coaster|")
	var origin: String = neutrals[rng.randi_range(0, neutrals.size() - 1)]
	var dest := _nearest_port_excluding(origin)
	if dest.is_empty() or dest == origin:
		return {}
	var route_check := route_between(origin, dest)
	if route_check.is_empty():
		return {}
	return {
		"origin": origin, "dest": dest, "cell": _port_cell(origin),
		"dwell_until_day": int(day) + _coaster_dwell_days(),
		"route": (route_check["legs_save"] as Dictionary).duplicate(true),
	}


## The nearest port of ANY ownership (docs/60-* §4.11.14: the grey coasters
## hop to the nearest ports regardless of ownership). Wrap-aware Chebyshev;
## ties by port id.
func _nearest_port_excluding(port_id: String) -> String:
	var best := ""
	var best_distance := 0
	var center := _port_cell(port_id)
	if center.x < 0:
		return ""
	for port in DataLoader.ports_list:
		var other := str((port as Dictionary).get("id", ""))
		if other.is_empty() or other == port_id:
			continue
		var cell := _port_cell(other)
		if cell.x < 0:
			continue
		var distance := chebyshev(center, cell)
		if best.is_empty() or distance < best_distance \
				or (distance == best_distance and other < best):
			best = other
			best_distance = distance
	return best


## The nearest port of the trader's ALIGNMENT pool (§4.11.14 docking: the
## spawn journey lands at an aligned port). Ties by port id.
func _nearest_aligned_port_excluding(origin: String, nation_id: String) -> String:
	var best := ""
	var best_distance := 0
	var center := _port_cell(origin)
	for other in alignment_ports(nation_id):
		if other == origin:
			continue
		var distance := chebyshev(center, _port_cell(other))
		if best.is_empty() or distance < best_distance \
				or (distance == best_distance and other < best):
			best = other
			best_distance = distance
	return best


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


## The berth tile of the fleet's own nation's NEAREST port — the stranded
## fleet's self-heal target when it recorded no destination (a journey was
## dropped before any depart). A nationless fleet (the grey coaster) heals
## to the nearest port of ANY ownership (§4.11.14: it serves every coast).
## `NO_CELL` when no port resolves.
func _nearest_own_berth(fleet: Dictionary) -> Vector2i:
	var nation_id := str(fleet.get("nation_id", ""))
	var cell := position_of(fleet)
	var best := NO_CELL
	var best_distance := 0
	var ids: Array[String] = _all_port_ids() if nation_id.is_empty() \
		else nation_ports(nation_id)
	for port_id in ids:
		var berth := _port_cell(str(port_id))
		if berth == NO_CELL:
			continue
		var distance := chebyshev(cell, berth)
		if best == NO_CELL or distance < best_distance:
			best = berth
			best_distance = distance
	return best


## Every port id with a berth, sorted (the ownership-blind scans' pool).
func _all_port_ids() -> Array[String]:
	var out: Array[String] = []
	for port in DataLoader.ports_list:
		var id := str((port as Dictionary).get("id", ""))
		if id.is_empty() or _port_cell(id).x < 0:
			continue
		out.append(id)
	out.sort()
	return out


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
	_width = int(grid.get("width", 4320))
	_height = int(grid.get("height", 2160))
	for lane_id in DataLoader.route_lanes:
		var lane: Dictionary = DataLoader.route_lanes[lane_id]
		var path: Array = []
		for tile in lane.get("tile_path", []):
			path.append(Vector2i(int((tile as Array)[0]), int((tile as Array)[1])))
		_lane_paths[str(lane_id)] = path
		_lane_ids_sorted.append(str(lane_id))
		# Task-H: the built seasonal variants (`{id, months, tile_count,
		# tile_path}`), decoded once with the base path. `months` stays the
		# built int array; `path` is the walked tile list.
		var variants: Array = []
		for variant in lane.get("variants", []):
			if not (variant is Dictionary):
				continue
			var vpath: Array = []
			for tile in variant.get("tile_path", []):
				vpath.append(Vector2i(int((tile as Array)[0]), int((tile as Array)[1])))
			variants.append({
				"id": str(variant.get("id", "")),
				"months": variant.get("months", []),
				"path": vpath,
			})
		_lane_variants[str(lane_id)] = variants
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
			_path_tiles[key] = true
	for port_id in _spoke_paths:
		for tile in _spoke_paths[port_id]:
			_path_tiles[_cell_key(tile)] = true
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


# --- Raiders: chokepoint camping & auto-resolve (§4.11.11.1/.2 — task K) -----

## One pirate/privateer day (docs/60-* §4.11.11.1). The raider either camps
## its chokepoint anchor (within [constant ANCHOR_RADIUS] of a chokepoint
## tile), chases prey under the **10/16 hysteresis** — the chase opens for the
## nearest prey within [constant CHASE_ON_RADIUS] and is lost once the prey is
## beyond [constant CHASE_OFF_RADIUS] or gone — or walks back to the anchor
## after a lost chase. An engagement (Chebyshev [constant CONTACT_DISTANCE])
## resolves abstractly via [method resolve_engagement]; the loser is queued
## into `doomed`/`remove_ids` and its wreck into `wrecks` (applied by the
## caller after the pass — never mid-iteration).
func _raider_tick(fleet: Dictionary, _day: int, doomed: Dictionary,
		_remove_ids: Array, _wrecks: Array) -> void:
	var cell := position_of(fleet)
	var target := _find(str(fleet.get("target_fleet_id", "")))
	if not target.is_empty() and (doomed.has(str(target.get("id", ""))) \
			or chebyshev(cell, position_of(target)) > CHASE_OFF_RADIUS):
		# §4.11.11.1: the prey is beyond 16 (or lost) — drop the chase.
		target = {}
		fleet["target_fleet_id"] = ""
	if target.is_empty():
		# The chase opens only inside 10; the *pick* among the candidates is
		# the nearest of the §4.1.1 prey query (trader/patrol within 10,
		# coasters ignored, a privateer restricted to its sponsor's rivals).
		var prey := _nearest_prey_within(fleet, CHASE_ON_RADIUS, doomed)
		if not prey.is_empty():
			fleet["target_fleet_id"] = str(prey.get("id", ""))
	# Unified-movement amendment: the chase and the anchor-return are pure
	# clock accrual now ([method _accrue_raider]) — the day tick owns the
	# state (prey pick, chase drop, anchor rule) and no movement. The
	# engagement fires from the accrual walk the moment a committed tile
	# lands within [constant CONTACT_DISTANCE] of the prey.


## The nearest prey candidate within `radius` of the raider (ties by fleet id
## ascending — deterministic). One bucket-index query via
## [method prey_candidates]; `doomed` entries are skipped (they already lost
## an engagement this tick).
func _nearest_prey_within(fleet: Dictionary, radius: int,
		doomed: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := -1
	for candidate in prey_candidates(fleet):
		if doomed.has(str(candidate.get("id", ""))):
			continue
		var distance := chebyshev(position_of(fleet), position_of(candidate))
		if distance > radius:
			continue
		var id := str(candidate.get("id", ""))
		if best.is_empty() or distance < best_distance \
				or (distance == best_distance and id < str(best.get("id", ""))):
			best = candidate
			best_distance = distance
	return best


## One wrap-aware greedy step reducing the Chebyshev distance to `target`,
## larger axis first, never onto
## land/reef/ice or an occupied tile (the day's unified allowance decides
## how many of these fire — the callers bank it). Lane traffic never
## pathfinds and the
## raider chase is no exception (the §4.11.11.5 zero-A* gate: only the
## hunter's player-chase may A*).
func _step_toward(fleet: Dictionary, target: Vector2i) -> void:
	var cell := position_of(fleet)
	var dx := posmod(target.x - cell.x, _width)
	if dx > _width / 2:
		dx -= _width
	var dy := target.y - cell.y
	var sx := 1 if dx > 0 else -1
	var sy := 1 if dy > 0 else -1
	# Larger axis first (ties: x before y); the diagonal is the fallback.
	var offsets: Array = []
	if absi(dx) >= absi(dy):
		if dx != 0:
			offsets.append(Vector2i(sx, 0))
		if dy != 0:
			offsets.append(Vector2i(0, sy))
	else:
		if dy != 0:
			offsets.append(Vector2i(0, sy))
		if dx != 0:
			offsets.append(Vector2i(sx, 0))
	if dx != 0 and dy != 0:
		offsets.append(Vector2i(sx, sy))
	for offset: Vector2i in offsets:
		var y := cell.y + offset.y
		if y < 0 or y >= _height:
			continue
		var next := Vector2i(posmod(cell.x + offset.x, _width), y)
		if _can_enter(fleet, next):
			_commit_cell(fleet, next)
			return
	# Fully blocked: hold (deterministic retry next day).


## The §4.11.11.2 auto-resolve (locked). Same-role/navy pairings never reach
## here — the prey query only ever offers `trader`/`patrol` — so the table's
## three deterministic rows plus the seeded 60% roll are the whole rule.
## Returns true when the raider wins.
func resolve_engagement(raider: Dictionary, prey: Dictionary, day: int) -> bool:
	if str(prey.get("role", "")) == PATROL:
		return false  # raider vs patrol ⇒ raider loses
	if is_escorted(prey):
		return false  # escorted trader ⇒ raider loses
	if is_convoyed(prey):
		return false  # convoy ⇒ escorted (§4.11.11.4)
	var rng := _fleet_rng(raider, "resolve|%d|%s" % [int(day),
		str(prey.get("id", ""))])
	return rng.randf() < RAIDER_WIN_CHANCE


## Applies one engagement: the loser despawns into a wreck at its site
## (§4.11.11.2) — queued, like the removal, so the pass in flight stays valid.
func _engage(raider: Dictionary, prey: Dictionary, day: int,
		doomed: Dictionary, remove_ids: Array, wrecks: Array) -> void:
	var raider_wins := resolve_engagement(raider, prey, day)
	var loser := prey if raider_wins else raider
	var loser_id := str(loser.get("id", ""))
	doomed[loser_id] = true
	remove_ids.append(loser_id)
	wrecks.append(_make_wreck(loser, day))
	if raider_wins:
		raider["target_fleet_id"] = ""  # prey taken: back to camping


## The §4.11.11/`10-*` §4.15 wreck at the loser's site: `{id, cell, cargo,
## salvage_gold, spawn_day}`. A merchant wreck carries the fleet's actual
## cargo; a warship wreck (patrol/privateer/hunter/pirate — a pirate is a
## warship of its composed hulls) carries salvage gold from the **single**
## salvage implementation, `BattleRewards.salvage_for`.
func _make_wreck(fleet: Dictionary, day: int) -> Dictionary:
	var cell := position_of(fleet)
	var wreck := {
		"id": _wreck_id(int(day), cell),
		"cell": {"x": cell.x, "y": cell.y},
		"cargo": {},
		"salvage_gold": 0,
		"spawn_day": int(day),
	}
	if str(fleet.get("role", "")) in WARSHIP_WRECK_ROLES:
		var hull_ids: Array = []
		for ship in _fleet_ships(fleet):
			hull_ids.append(str((ship as Dictionary).get("ship_type_id", "")))
		wreck["salvage_gold"] = BattleRewardsLib.salvage_for(hull_ids)
	else:
		var cargo: Dictionary = fleet.get("cargo", {}) \
			if fleet.get("cargo", {}) is Dictionary else {}
		wreck["cargo"] = cargo.duplicate(true)
	return wreck


## The §4.11.11 `wk_<day>_<x>_<y>` id, uniqued with a `_n` suffix on a cell
## that already wrecked this run (deterministic).
func _wreck_id(day: int, cell: Vector2i) -> String:
	var id := "wk_%d_%04d_%04d" % [day, posmod(cell.x, _width), cell.y]
	var seq := 2
	var taken: Dictionary = {}
	for wreck in GameState.wrecks:
		if wreck is Dictionary:
			taken[str((wreck as Dictionary).get("id", ""))] = true
	while taken.has(id):
		id = "wk_%d_%04d_%04d_%d" % [day, posmod(cell.x, _width), cell.y, seq]
		seq += 1
	return id


## Drops wrecks whose 5 days are up (§4.11.11.2: despawn after 5 days — the
## wreck of day D is collectable on D…D+4 and gone from D+5's tick).
func _age_wrecks(day: int) -> void:
	if GameState.wrecks.is_empty():
		return
	for index in range(GameState.wrecks.size() - 1, -1, -1):
		var wreck = GameState.wrecks[index]
		if wreck is Dictionary \
				and int((wreck as Dictionary).get("spawn_day", 0)) \
				+ WRECK_DESPAWN_DAYS <= int(day):
			GameState.wrecks.remove_at(index)


## The §4.11.11.2 wreck view — the save payload (`GameState.wrecks`, never
## counted against the §4.1.1 cap).
func wrecks() -> Array:
	return GameState.wrecks.duplicate()


## The wreck at exactly `cell` ({} when none). Wrecks are not fleets and live
## outside the cell-bucket index; this is an exact-cell read of a small list,
## not a radius query.
func wreck_at(cell: Vector2i) -> Dictionary:
	for wreck in GameState.wrecks:
		if not (wreck is Dictionary):
			continue
		if position_of(wreck) == cell:
			return wreck
	return {}


## Player collect (§4.11.11.2): entering the wreck tile collects it — cargo
## up to `free_capacity` (goods id-ascending, deterministic) plus the salvage
## gold in full. The wreck is consumed either way; cargo that no longer fit
## is reported as `leftover` (the hold guard, not a partial wreck).
## Returns `{id, cargo, gold, leftover}` or {} for an unknown id.
func collect_wreck(id: String, free_capacity: int) -> Dictionary:
	for index in range(GameState.wrecks.size()):
		var wreck = GameState.wrecks[index]
		if not (wreck is Dictionary) or str((wreck as Dictionary).get("id", "")) != id:
			continue
		var cargo: Dictionary = (wreck as Dictionary).get("cargo", {}) \
			if (wreck as Dictionary).get("cargo", {}) is Dictionary else {}
		var room := maxi(int(free_capacity), 0)
		var taken: Dictionary = {}
		var leftover := 0
		var good_ids: Array = cargo.keys()
		good_ids.sort()
		for good_id in good_ids:
			var held := maxi(int(cargo[good_id]), 0)
			var qty := mini(held, room)
			if qty > 0:
				taken[str(good_id)] = qty
				room -= qty
			leftover += held - qty
		var result := {
			"id": id,
			"cargo": taken,
			"gold": maxi(int((wreck as Dictionary).get("salvage_gold", 0)), 0),
			"leftover": leftover,
		}
		GameState.wrecks.remove_at(index)
		return result
	return {}


## §4.11.11.4 convoys: same-lane traders within Chebyshev 3 of `fleet`
## (including itself); the member list is what task L's render grouping
## reuses. One bucket-index query.
func convoy_members(fleet: Dictionary) -> Array:
	var out: Array = []
	if str(fleet.get("role", "")) != TRADER:
		return out
	for other in _within(position_of(fleet), CONVOY_RADIUS):
		if str(other.get("role", "")) != TRADER:
			continue
		if not _share_lane(fleet, other):
			continue
		out.append(other)
	return out


## §4.11.11.2: a trader in a convoy (≥ 2 same-lane traders within
## Chebyshev 3, §4.11.11.4) counts as escorted.
func is_convoyed(fleet: Dictionary) -> bool:
	return convoy_members(fleet).size() >= 2


## True when two fleets' saved routes share at least one lane id.
static func _share_lane(a: Dictionary, b: Dictionary) -> bool:
	var lanes_a: Array = (a.get("route", {}) as Dictionary).get("lanes", [])
	var lanes_b: Array = (b.get("route", {}) as Dictionary).get("lanes", [])
	for lane_id in lanes_a:
		if lanes_b.has(lane_id):
			return true
	return false


# --- Phase-6 parity factors & seasonal geometry (task H, §2.8) --------------

## Per-day factor memos (unified-movement perf work): the prevailing-wind
## token and the current band per cell, cleared when the month rolls —
## the accrual evaluates these per fleet per tick over the same lanes.
## Static like the factors themselves; pure day+cell functions, so the
## memos never change replay determinism.
static var _prevailing_memo: Dictionary = {}
static var _current_memo: Dictionary = {}
static var _factor_memo_month: int = -1

## The §4.4 direction factor for an NPC step of `heading` at `cell` in
## `month` (docs/60-* §4.11.11 amendment; task-H master pin 1, amended by
## the unified-movement model). The wind-FROM direction is the region's
## **prevailing** token for the month (`OceanLayers.prevailing_for`) — the
## player's seeded daily jitter and the calm gate are player-ledger concepts
## and are NOT applied here: the NPC factor is a pure day+cell function, so
## the same seed/day/cells replay identically. A `VAR` region contributes
## 1.0 (no directional penalty or bonus). The angle between the step heading
## and the wind-FROM direction is bucketed on the 8-grid and read from
## `SailingSim.DIRECTION_FACTORS` at `ship_class` — the fleet's flagship
## class per the amendment ([method _fleet_base]; the `sail` column stays
## the fallback via [constant NPC_SAIL_CLASS]). An unknown heading (never
## produced by the movement rules) degrades to 1.0.
static func npc_direction_factor(heading: String, cell: Vector2i,
		month: int, ship_class: String = NPC_SAIL_CLASS) -> float:
	# Per-day memo of the region's prevailing token (unified-movement perf
	# work: the accrual evaluates this per fleet per tick over the same
	# lane cells). Cleared when the month rolls.
	if _factor_memo_month != month:
		_prevailing_memo = {}
		_factor_memo_month = month
	var wind_from: String = _prevailing_memo.get(cell, "")
	if wind_from.is_empty():
		wind_from = OceanLayersLib.instance().prevailing_for(cell, month)
		_prevailing_memo[cell] = wind_from
	if wind_from == "VAR":
		return 1.0
	var angle := SailingSimLib.angle_between_dirs(heading, wind_from)
	if angle < 0:
		return 1.0
	var table: Dictionary = SailingSimLib.DIRECTION_FACTORS.get(angle, {})
	return float(table.get(ship_class, table.get(NPC_SAIL_CLASS, 1.0)))


## The §4.16 current modifier for an NPC step of `heading` at `cell` in
## `month` (task-H master pin 2; the `current_factor` line of the docs/20-*
## §4.4 pipeline). Recomputed locally from the same bands as
## `SailingSim.current_factor` — that static is gated on the PLAYER's
## `current_mode: "drift"` (it returns 1.0 there), while NPC parity is
## unconditional regardless of the player's mode (§2.8), so the 6-line band
## math is duplicated rather than shared:
## within 67.5° → `1 + 0.08 × strength`; 67.5–112.5° → 1.0; ≥ 112.5° →
## `1 − 0.08 × strength`; an empty current tile (and any unknown heading) →
## 1.0. The reversal flip is `OceanLayers.current_at`'s own lookup-time rule.
static func npc_current_factor(heading: String, cell: Vector2i,
		month: int) -> float:
	# Per-day memo (see [method npc_direction_factor]): the current band
	# lookup is shared by every fleet crossing the same cell.
	if _factor_memo_month != month:
		_current_memo = {}
		_factor_memo_month = month
	var current: Dictionary
	if _current_memo.has(cell):
		current = _current_memo[cell]
	else:
		current = OceanLayersLib.instance().current_at(cell, month)
		_current_memo[cell] = current
	if current.is_empty():
		return 1.0
	var angle := SailingSimLib.angle_between_dirs(heading, str(current["dir"]))
	if angle < 0:
		return 1.0
	var strength := float(current["strength"])
	if float(angle) < SailingSimLib.CURRENT_ALIGNED_DEG:
		return 1.0 + SailingSimLib.CURRENT_ALIGN_FACTOR * strength
	if float(angle) > SailingSimLib.CURRENT_OPPOSED_DEG:
		return 1.0 - SailingSimLib.CURRENT_ALIGN_FACTOR * strength
	return 1.0


## The wrapped 8-dir heading from `from` toward `to`: the exact compass delta
## when the tiles are adjacent, else the dominant-axis bearing (the
## `_step_toward` primary-offset rule). "" only when `from == to`.
static func _heading_to(from: Vector2i, to: Vector2i) -> String:
	var dx := posmod(to.x - from.x, _width)
	if dx > _width / 2:
		dx -= _width
	var dy := to.y - from.y
	var exact := SailingSimLib.heading_of_delta(Vector2i(dx, dy))
	if not exact.is_empty():
		return exact
	var sx := 1 if dx > 0 else -1
	var sy := 1 if dy > 0 else -1
	if absi(dx) >= absi(dy):
		if dx != 0:
			return SailingSimLib.heading_of_delta(Vector2i(sx, 0))
		if dy != 0:
			return SailingSimLib.heading_of_delta(Vector2i(0, sy))
	else:
		if dy != 0:
			return SailingSimLib.heading_of_delta(Vector2i(0, sy))
		if dx != 0:
			return SailingSimLib.heading_of_delta(Vector2i(sx, 0))
	return ""


## The ACTIVE walked geometry of a saved leg (task-H item 2, §2.8 seasonal
## variants): `{path, start, end, reverse, walked_len, key, saved_walked_len}`
## — the tile path the fleet walks NOW (base or in-month variant), the
## effective walked range inside it, and the identity `key` the progress
## state is keyed on. `{}` for a broken leg (unknown id). Spoke legs have no
## variants; lane legs resolve the in-month variant
## ([method _active_lane_variant], file order on overlap — the shipped data
## has at most one per lane).
##
## The variant's walked range maps the saved base range `a..b`
## proportionally: `round(a / (base_n − 1) × (var_n − 1))` — a full-lane leg
## (`a = 0, b = base_n − 1`, the patrol/treasure/pin probe shape) maps to the
## FULL variant path, which is exactly the master-pin form
## `new_index = round(fraction × (new_len − 1))`; sub-range journey legs map
## to the same fraction of the variant, so a mid-journey fleet rides the
## variant at its proportional position instead of touring the whole lane.
## The persisted leg keeps its base-relative `a`/`b` (clean save shape).
func _leg_geometry(leg: Dictionary) -> Dictionary:
	var kind := str(leg.get("kind", ""))
	var leg_id := str(leg.get("id", ""))
	# The per-tile hot path (unified-movement: the tick walks each active
	# leg up to its hull-speed budget) — a memo hit must be allocation-free:
	# the base path resolves by direct id lookup (no "kind:" prefix build),
	# the id→int maps are split by kind, and the memo key is pure int math.
	var table: Dictionary = _lane_paths if kind == "lane" else _spoke_paths
	var base: Array = table.get(leg_id, [])
	if base.is_empty():
		return {}
	# Per-day memo: one dict allocation + the month-variant lookup per
	# DISTINCT leg per day, invalidated on day change. Callers treat the
	# shared result as READ-ONLY (the movement rules only read fields).
	if _geo_cache_day != int(GameState.day):
		_geo_cache = {}
		_geo_cache_day = int(GameState.day)
	var a := clampi(int(leg.get("a", 0)), 0, base.size() - 1)
	var b := clampi(int(leg.get("b", base.size() - 1)), 0, base.size() - 1)
	var ids: Dictionary = _lane_path_ids if kind == "lane" else _spoke_path_ids
	var pid := int(ids.get(leg_id, 0))
	if pid == 0:
		pid = ids.size() + 1
		ids[leg_id] = pid
	var cache_key := pid * 140737488355328 + a * 8388608 + b
	if _geo_cache.has(cache_key):
		return _geo_cache[cache_key]
	var out := {
		"path": base,
		"start": a,
		"end": b,
		"reverse": bool(leg.get("reverse", false)),
		"walked_len": b - a + 1,
		"key": "%s:%s|" % [kind, leg_id],
		"saved_walked_len": b - a + 1,
	}
	if kind != "lane":
		out["key"] = "%s:%s" % [kind, leg_id]
		_geo_cache[cache_key] = out
		return out
	var month := SailingSimLib.month_for(GameState.day)
	var variant := _active_lane_variant(leg_id, month)
	if variant.is_empty():
		_geo_cache[cache_key] = out
		return out
	var vpath: Array = variant["path"]
	var vn := vpath.size()
	if vn < 2 or base.size() < 2:
		# a degenerate variant cannot carry progress; sail base
		_geo_cache[cache_key] = out
		return out
	var va := roundi(float(a) / float(base.size() - 1) * float(vn - 1))
	var vb := roundi(float(b) / float(base.size() - 1) * float(vn - 1))
	va = clampi(va, 0, vn - 1)
	vb = clampi(vb, 0, vn - 1)
	if va > vb:
		var swap := va
		va = vb
		vb = swap
	out["path"] = vpath
	out["start"] = va
	out["end"] = vb
	out["walked_len"] = vb - va + 1
	out["key"] = "%s:%s|%s" % [kind, leg_id, str(variant["id"])]
	_geo_cache[cache_key] = out
	return out


## The in-month built variant of `lane_id` (`{id, months, path}`), or `{}`
## when the lane sails its base path this month.
func _active_lane_variant(lane_id: String, month: int) -> Dictionary:
	for variant in _lane_variants.get(lane_id, []):
		if month in (variant as Dictionary).get("months", []):
			return variant
	return {}


## The walked tiles of a leg's ACTIVE geometry — the runtime answer to "which
## tiles does this leg walk this month" (the suites' on-path checks; the
## base-only walked path stays [_leg_path] for route construction).
func _leg_path_active(leg: Dictionary) -> Array:
	var geo := _leg_geometry(leg)
	if geo.is_empty():
		return []
	return _walked_path(geo["path"], int(geo["start"]), int(geo["end"]),
		bool(geo["reverse"]))


## Progress bookkeeping for the active geometry (task-H pin 4): when the
## resolved identity differs from the fleet's recorded one (first resolution
## after spawn/load, or a month rollover that swaps base ↔ variant), the
## saved `tile_index` remaps **by fraction** —
## `new_index = round(fraction × (new_walked_len − 1))`, clamped — and the
## new identity is recorded. Deterministic and observable (the
## `hanseatic_north` flip probe). A seam-start index (0, or 1 after the
## occupancy hop) carries over unchanged — it is walk-start-relative on any
## geometry. Returns the effective walked index.
func _leg_progress(fleet: Dictionary, route: Dictionary, geo: Dictionary) -> int:
	var id := str(fleet.get("id", ""))
	var walked_len := int(geo["walked_len"])
	var index := int(route.get("tile_index", 0))
	var state: Dictionary = _leg_active.get(id, {}) \
		if _leg_active.has(id) else {}
	if str(state.get("key", "")) != str(geo["key"]):
		var fraction := -1.0
		var prev_len := int(state.get("walked_len", 0))
		if prev_len > 1 and index > 1:
			# Rollover (or a leg change): the index is relative to the
			# previous active walked length.
			fraction = clampf(float(index) / float(prev_len - 1), 0.0, 1.0)
		elif prev_len == 0 and index > 1:
			# First sight (spawn / load): the saved index is relative to the
			# leg's own saved walked range.
			var saved_len := int(geo["saved_walked_len"])
			if saved_len > 1:
				fraction = clampf(float(index) / float(saved_len - 1), 0.0, 1.0)
		if fraction >= 0.0:
			index = clampi(roundi(fraction * float(walked_len - 1)),
				0, walked_len - 1)
			route["tile_index"] = index
		_leg_active[id] = {"key": str(geo["key"]), "walked_len": walked_len}
	if index < 0 or index >= walked_len:
		# Off the leg (a hand edit): restart the leg deterministically.
		index = 0
		route["tile_index"] = 0
	return index


## The daily lane-travel budget (unified-movement amendment, `60-*`
## §4.11.11): the full §4.4 pipeline for the fleet's current leg heading —
## `tiles_today = floor(base × wind × direction × current + carry)`, where
## `base` is the slowest hull among the fleet's composed ships and `wind`
## is the global day weather at the flagship's class. The fractional
## remainder banks in [_step_carry]. Pure day+cell inputs — no RNG. A fleet
## with no resolvable heading banks its carry unchanged.
func _lane_tiles_today(fleet: Dictionary) -> int:
	var id := str(fleet.get("id", ""))
	var carry := float(_step_carry.get(id, 0.0))
	var heading := _lane_step_heading(fleet)
	if heading.is_empty():
		# A fleet with legs but no resolvable step is WEDGED: a broken leg,
		# or parked exactly on its span's far end with no berth to head for
		# (a patrol boarded at a lane terminus, pre-existing stall — surfaced
		# by the stall diagnostics). Drop the journey: the day tick departs
		# it fresh, which re-boards a lane and un-wedges it.
		var route: Dictionary = fleet.get("route", {})
		if not (route.get("legs", []) as Array).is_empty():
			var wedged_legs: Array = route.get("legs", [])
			_note_event(id, "drop wedge:%s ti=%d" % [
				str((wedged_legs[0] as Dictionary).get("id", "?")),
				int(route.get("tile_index", -1))])
			route["legs"] = []
		_step_carry[id] = carry
		return 0
	var raw := _lane_pipe(fleet) + carry
	var tiles := int(floor(raw))
	_step_carry[id] = raw - float(tiles)
	return tiles


## The fleet's composed ships (unified-movement amendment): the §4.11.3
## list stored at spawn; a fleet without it (an older save, or a
## hand-edited payload) composes lazily from its persisted `seed` —
## bit-identical to the spawn draw, because the hull draws key off the
## seed only (never the day; the day term of the composer only budgets
## cannons, which no speed rule reads).
func _fleet_ships(fleet: Dictionary) -> Array:
	var ships: Array = fleet.get("ships", []) \
		if fleet.get("ships", []) is Array else []
	if ships.is_empty():
		ships = compose_fleet_ships(fleet, int(GameState.day))
		fleet["ships"] = ships
	return ships


## The §4.4 base terms of a fleet (unified-movement amendment): returns
## `[base_speed, flagship_class]` — `base_speed` is the slowest
## `ShipType.speed` among the composed ships (the same "slowest hull in the
## fleet" rule the player fleet follows, `20-*` §4.4), floored at 1 so a
## composed fleet always moves (§4.4's "minimum 1 tile/day"); the
## **flagship is the first composed ship** and its class drives the
## wind/direction factor columns (all §4.11.3 pool hulls are `sail`). The
## derived pair is cached on the fleet (`speed` / `speed_class` — computed
## once at spawn or lazy backfill; the composition is seed-stable, so the
## cache can never drift) — the day tick calls this per fleet, and the
## cached read keeps that O(1).
func _fleet_base(fleet: Dictionary) -> Array:
	if fleet.has("speed") and fleet.has("speed_class"):
		return [int(fleet["speed"]), str(fleet["speed_class"])]
	var ships := _fleet_ships(fleet)
	var slowest := 0
	var flagship_class := NPC_SAIL_CLASS
	if not ships.is_empty():
		var flagship: Dictionary = DataLoader.get_ship_type(str(
			(ships[0] as Dictionary).get("ship_type_id", "")))
		var cls := str(flagship.get("class", ""))
		if not cls.is_empty():
			flagship_class = cls
	for ship in ships:
		var ship_type: Dictionary = DataLoader.get_ship_type(str(
			(ship as Dictionary).get("ship_type_id", "")))
		var speed := int(ship_type.get("speed", 0))
		if speed > 0 and (slowest == 0 or speed < slowest):
			slowest = speed
	var base := maxi(slowest, 1)
	fleet["speed"] = base
	fleet["speed_class"] = flagship_class
	return [base, flagship_class]


## The §4.4 step allowance for a bearing toward `target` (unified-movement
## amendment): `base × wind_factor × direction_factor × current_factor` for
## the fleet's bearing — the same pipeline the day's lane budget uses. 0.0
## when the bearing is unresolvable (co-located).
func _step_allowance(fleet: Dictionary, target: Vector2i) -> float:
	var cell := position_of(fleet)
	var heading := _heading_to(cell, target)
	if heading.is_empty():
		return 0.0
	var base: Array = _fleet_base(fleet)
	var ship_class := str(base[1])
	var month := SailingSimLib.month_for(GameState.day)
	var weather := str(GameState.world.get("weather",
		SailingSimLib.DEFAULT_WEATHER))
	return float(int(base[0])) \
		* SailingSimLib.wind_factor(weather, ship_class) \
		* npc_direction_factor(heading, cell, month, ship_class) \
		* npc_current_factor(heading, cell, month)


## The heading of the fleet's next lane step (the §2.8 "current leg
## heading"): the next tile on the active leg geometry, or — at a leg end —
## toward the seam commit target (the next leg's first tile, else the
## destination berth, else the current leg's far end). "" with no legs.
func _lane_step_heading(fleet: Dictionary) -> String:
	var route: Dictionary = fleet.get("route", {})
	var legs: Array = route.get("legs", [])
	if legs.is_empty():
		return ""
	var geo := _leg_geometry(legs[0])
	if geo.is_empty():
		return ""
	var cell := position_of(fleet)
	var index := int(route.get("tile_index", 0))
	var walked_len := int(geo["walked_len"])
	var reverse := bool(geo["reverse"])
	if index < walked_len - 1:
		var artifact := (int(geo["end"]) - index - 1) if reverse \
			else (int(geo["start"]) + index + 1)
		return _heading_to(cell, (geo["path"] as Array)[artifact])
	if legs.size() > 1:
		var head_geo := _leg_geometry(legs[1])
		if not head_geo.is_empty():
			var head: Vector2i = (head_geo["path"] as Array)[
				int(head_geo["end"]) if bool(head_geo["reverse"])
				else int(head_geo["start"])]
			if head != cell:
				return _heading_to(cell, head)
			# The seam IS the fleet's tile: the spoke's last tile is also
			# the trunk's boarding tile (a lane junction, not a hop). The
			# fleet is already standing on the next leg's head — head for
			# the tile AFTER it (the next leg's first real step), so the
			# read-only heading query never reports a false wedge. The
			# day tick's `_advance` boards the leg (pops it, ti=0) on the
			# same accrual.
			var next_len := int(head_geo["walked_len"])
			if next_len > 1:
				var head_dir := -1 if bool(head_geo["reverse"]) else 1
				var head_artifact := (int(head_geo["end"]) - 1) \
					if bool(head_geo["reverse"]) else (int(head_geo["start"]) + 1)
				return _heading_to(cell,
					(head_geo["path"] as Array)[head_artifact])
			return _heading_to(cell, head)
	var berth := _port_cell(str(fleet.get("dest_port_id", "")))
	if berth.x >= 0:
		return _heading_to(cell, berth)
	return _heading_to(cell, (geo["path"] as Array)[
		int(geo["end"]) if reverse else int(geo["start"])])


## One chase/return allowance paying the full §4.4 pipeline **per pursuit
## bearing** (unified-movement amendment, `60-*` §4.11.11): `delta` days of
## the allowance `base × wind × direction × current` for the bearing toward
## `target` bank in the same per-fleet accumulator, and the walk fires
## greedily for every banked tile (a blocked [_step_toward] holds inside
## itself — the day's spend is consumed either way, retrying next tick).
func _chase_step(fleet: Dictionary, target: Vector2i, delta: float = 1.0) -> void:
	for _i in _chase_budget(fleet, target, delta):
		_step_toward(fleet, target)


## Banks `delta` days of the §4.4 chase allowance toward `target` and
## returns the walkable tile count — the caller walks (and, in the chase,
## re-checks the engagement) per tile.
func _chase_budget(fleet: Dictionary, target: Vector2i, delta: float) -> int:
	var id := str(fleet.get("id", ""))
	_step_carry[id] = float(_step_carry.get(id, 0.0)) \
		+ _step_allowance(fleet, target) * delta
	var carry := float(_step_carry[id])
	var tiles := int(floor(carry))
	_step_carry[id] = carry - float(tiles)
	return tiles


# --- The daily step (docs/60-* §4.11.11.1) ----------------------------------

func _step_fleets(day: int) -> void:
	var remove_ids: Array = []
	# Task K: auto-resolve losses (and the hunter bounty clears above) are
	# deferred to the end of the pass — a fleet queued mid-loop must neither
	# step again this tick nor be selectable as prey by a later raider.
	var doomed: Dictionary = {}
	var wrecks: Array = []
	var pursuit_ms := 0.0
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		var id := str(fleet.get("id", ""))
		if doomed.has(id):
			continue  # already lost an auto-resolve this tick
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
			# inside the 30/40 hysteresis.
			pursuit_ms += _hunter_tick(fleet, day, pursuit_ms)
			continue
		if role == PIRATE or role == PRIVATEER:
			# §4.11.11.1/§4.11.11.2 (task K): chokepoint camping with the
			# 10/16 hysteresis and the abstract NPC-vs-NPC auto-resolve.
			_raider_tick(fleet, day, doomed, remove_ids, wrecks)
			continue
		var legs: Array = (fleet.get("route", {}) as Dictionary).get("legs", [])
		if legs.is_empty():
			# Berth consistency (unified-movement amendment, `60-*` §4.11.11
			# berth pin): a docked fleet stands ON a port's berth tile — the
			# mooring resolves from the tile itself (`_port_at_cell`).
			# A dwell hold in open water is `stranded`, but the heal waits
			# until the hold actually EXPIRES: mid-dwell the fleet is
			# genuinely idle (a fixture's bait, or a just-dropped journey
			# about to re-depart), and teleporting it mid-hold would move
			# prey out from under an engagement. On expiry the heal lands
			# it on a berth first, then the depart uses that berth as the
			# origin (never a port it is nowhere near).
			var mooring := _port_at_cell(position_of(fleet))
			var dwell_expired := int(fleet.get("dwell_until_day", 0)) <= day
			if mooring.is_empty() and dwell_expired:
				var dest := str(fleet.get("dest_port_id", ""))
				var berth := _port_cell(dest) if not dest.is_empty() \
					else NO_CELL
				if berth == NO_CELL:
					berth = _nearest_own_berth(fleet)
				if berth != NO_CELL:
					_commit_cell(fleet, berth)
			if dwell_expired:
				if role == TREASURE:
					# Task L: the seasonal run is over — the fleet delivered
					# and despawns (1/nation/season, §4.11.11.4).
					remove_ids.append(id)
					continue
				_depart(fleet, day)
			continue
		# Unified-movement amendment: lane stepping is clock accrual
		# ([method advance_clock] → [method _accrue_lane]) — the day tick
		# owns dwell, departures and despawns only.
	for id in remove_ids:
		remove(id)
	for wreck in wrecks:
		GameState.wrecks.append(wreck)


## One hunter day under the intel rule (docs/60-* §4.11.11.1). Returns the
## pursuit A* time spent.
func _hunter_tick(fleet: Dictionary, _day: int, _budget_used_ms: float) -> float:
	var cell := position_of(fleet)
	var target := GameState.world_tile()
	var distance := chebyshev(cell, target)
	# 30/40 hysteresis: the chase opens inside 30, is lost beyond 40.
	if str(fleet.get("hunter_state", HUNTER_STATE_INTEL)) == HUNTER_STATE_CHASE:
		if distance > HUNTER_CHASE_OFF:
			_hunter_route_to_intel(fleet)
			return 0.0
		# Unified-movement amendment: the pursuit itself is clock accrual
		# ([method _accrue_hunter] → [method _pursue]) — the day tick owns
		# only the chase-drop decision here.
		return 0.0
	if distance <= HUNTER_CHASE_ON:
		fleet["hunter_state"] = HUNTER_STATE_CHASE
		_hunter_paths.erase(str(fleet.get("id", "")))
		return 0.0
	# A new Set Sail re-targets under-way hunters at their next day tick.
	var intel_port := _intel_port()
	var state := str(fleet.get("hunter_state", HUNTER_STATE_INTEL))
	if state == HUNTER_STATE_INTEL and not intel_port.is_empty() \
			and str(fleet.get("dest_port_id", "")) != intel_port:
		_hunter_route_to_intel(fleet)
		return 0.0
	var legs: Array = (fleet.get("route", {}) as Dictionary).get("legs", [])
	if not legs.is_empty():
		# Lane travel is clock accrual now ([method _accrue_hunter] →
		# [method _accrue_lane]); the day tick owns the state below.
		return 0.0
	# Docked / arrived at a journey end.
	if int(fleet.get("dwell_until_day", 0)) > int(GameState.day):
		return 0.0
	match state:
		HUNTER_STATE_INTEL:
			# Arrived at the intel port: camp its approaches for 10 days.
			fleet["hunter_state"] = HUNTER_STATE_LOITER
			fleet["loiter_until_day"] = int(GameState.day) + HUNTER_LOITER_DAYS
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
	_sync_route_progress(fleet)


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
	_sync_route_progress(fleet)


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
## chase that day (the fleet holds). `delta` scales the accrual (unified
## amendment): each planned step banks its own heading's §4.4 allowance ×
## the elapsed fraction, walking every banked tile — the default 1.0 is a
## full day's pursuit.
func _pursue(fleet: Dictionary, target: Vector2i, budget_used_ms: float,
		delta: float = 1.0) -> float:
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
		# The passability callback is [_passable] — in-month seasonal ice
		# refuses entry for the pursuit A* exactly as for lane stepping
		# (§4.18; task-H ice-aware pursuit).
		path = FleetPathLib.find_path(position_of(fleet), target, _width,
			_height, func(cell: Vector2i) -> bool: return _passable(cell))
		var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
		_hunter_paths[id] = {"target_x": target.x, "target_y": target.y,
			"path": path}
		if elapsed > budget_left:
			return elapsed  # overflow: the chase is lost for today
		if path.size() < 2:
			return elapsed
	# Walk the plan. Unified-movement amendment (`60-*` §4.11.11): the
	# pursuit pays the full §4.4 pipeline PER pursuit step heading — each
	# step banks its own heading's allowance × the elapsed `delta` and the
	# walk fires for every banked tile; a blocked step erases the plan
	# (re-plan tomorrow) and ends the walk; the factor-gated hold keeps the
	# fresh plan for tomorrow (deterministic).
	while path.size() >= 2 and delta > 0.0:
		var next: Vector2i = path[1]
		if not _can_enter(fleet, next):
			_hunter_paths.erase(id)  # re-plan tomorrow from a clear board
			break
		var allowance := _step_allowance(fleet, next)
		var carry := float(_step_carry.get(id, 0.0)) + allowance * delta
		if carry < 1.0:
			_step_carry[id] = carry  # factor-gated hold
			break
		var tiles := int(floor(carry))
		_step_carry[id] = carry - float(tiles)
		for _i in tiles:
			if path.size() < 2:
				break
			var step_tile: Vector2i = path[1]
			if not _can_enter(fleet, step_tile):
				_hunter_paths.erase(id)  # re-plan tomorrow from a clear board
				break
			path.remove_at(0)
			_commit_cell(fleet, step_tile)
		delta = 0.0
	return 0.0


## Walks up to `budget` tiles of lane progress for one fleet — the batched
## form of the `_advance` loop (unified-movement perf work, §4.11.11.5):
## the leg geometry and progress resolve ONCE per leg, the common
## straight-line step is index arithmetic + commit, and every seam /
## leg-end / hop / blocked case delegates to [method _advance] verbatim
## (consuming one budget unit, exactly as the unbatched loop did). The
## route is re-read whenever `_advance` may have mutated it (seam or
## arrival), detected at the loop head.
func _walk_lane(fleet: Dictionary, day: int, budget: int) -> int:
	var walked := 0
	var committed := 0
	while walked < budget:
		var route: Dictionary = fleet.get("route", {})
		var legs: Array = route.get("legs", [])
		if legs.is_empty():
			return committed  # docked / arrived mid-walk
		var geo := _leg_geometry(legs[0])
		if geo.is_empty():
			# A broken leg (unknown id after a hand edit): drop the journey.
			_note_event(str(fleet.get("id", "")),
				"drop leg:%s" % str((legs[0] as Dictionary).get("id", "?")))
			route["legs"] = []
			return committed
		var path: Array = geo["path"]
		var walked_len := int(geo["walked_len"])
		var reverse := bool(geo["reverse"])
		var index := _leg_progress(fleet, route, geo)
		if index + 1 >= walked_len:
			# Leg end (seam / arrival): the full `_advance` logic owns it.
			var pre := position_of(fleet)
			_advance(fleet, day)
			walked += 1
			if position_of(fleet) != pre:
				committed += 1
			continue
		var dir := -1 if reverse else 1
		var artifact := (int(geo["end"]) - index) if reverse \
			else (int(geo["start"]) + index)
		var target: Vector2i = path[artifact + dir]
		if not _passable(target):
			# Impassable step (in-month seasonal ice on the walked span):
			# hold — the budget is spent and the accrual-level hold streak
			# records the block (fleets share tiles, so occupancy never
			# blocks a step under the unified-movement amendment).
			walked += 1
			continue
		route["tile_index"] = index + 1
		_commit_cell(fleet, target)
		committed += 1
		walked += 1
	return committed


## The docked-consistency helper (unified-movement amendment, `60-*`
## §4.11.11 berth pin): a docked fleet's berth is the berth tile it
## currently occupies — the mooring resolves from the tile itself
## (`_port_at_cell`); a fleet docked in open water (no berth under it)
## has none here, and the day-tick heal falls back to its `dest_port_id`
## berth. Diagnostics + the heal share this definition.
func _docked_berth(fleet: Dictionary) -> Vector2i:
	var mooring := _port_at_cell(position_of(fleet))
	if not mooring.is_empty():
		return _port_cell(mooring)
	var dest := str(fleet.get("dest_port_id", ""))
	if dest.is_empty():
		return NO_CELL
	return _port_cell(dest)


## One tile of progress along the current leg's ACTIVE geometry, skipping
## occupied tiles and never entering land/reef/in-month-ice (docs/60-*
## §4.11.11.1 + the Phase-6 amendment). The next tile is computed by index
## arithmetic on the resolved geometry ([method _leg_geometry] — base or
## in-month variant path) — no per-step slice allocation (the perf gate
## makes the day tick allocation-sensitive). A month rollover that swaps the
## active path remaps progress by fraction through [_leg_progress].
func _advance(fleet: Dictionary, day: int) -> void:
	var route: Dictionary = fleet.get("route", {})
	var legs: Array = route.get("legs", [])
	if legs.is_empty():
		return
	var leg: Dictionary = legs[0]
	var geo := _leg_geometry(leg)
	if geo.is_empty():
		# A broken leg (unknown id after a hand edit): drop the journey.
		_note_event(str(fleet.get("id", "")),
			"drop leg:%s" % str(leg.get("id", "?")))
		route["legs"] = []
		return
	var path: Array = geo["path"]
	var walked_len := int(geo["walked_len"])
	var reverse := bool(geo["reverse"])
	var index := _leg_progress(fleet, route, geo)
	var artifact := (int(geo["end"]) - index) if reverse \
		else (int(geo["start"]) + index)
	if index + 1 >= walked_len:
		# Leg end: board the next leg's first ACTIVE tile, and only then
		# hand the leg over — a blocked seam holds with the position still
		# on the stored leg (so route/position always agree, save/load
		# included).
		if legs.size() > 1:
			var head_geo := _leg_geometry(legs[1])
			if head_geo.is_empty():
				_note_event(str(fleet.get("id", "")),
					"drop seam:%s" % str((legs[1] as Dictionary).get(
						"id", "?")))
				route["legs"] = []
				return
			var head_path: Array = head_geo["path"]
			var head_tile: Vector2i = head_path[int(head_geo["end"]) \
				if bool(head_geo["reverse"]) else int(head_geo["start"])]
			if not _passable(head_tile):
				# In-month seasonal ice on the seam head: hold — the fleet
				# keeps its position on the stored leg (route/position
				# agree, save/load included); retry after the melt.
				return
			# Whether the fleet already STOOD on the seam tile before the
			# boarding commit — captured pre-commit (`_commit_cell` makes
			# the position equal `head_tile` either way).
			var stood_on_head := head_tile == position_of(fleet)
			legs.pop_front()
			route["leg"] = int(route.get("leg", 0)) + 1
			route["tile_index"] = 0
			_commit_cell(fleet, head_tile)
			# The seam IS the fleet's tile (the spoke's terminus is the
			# trunk's boarding tile): the hand-over above is a no-op step.
			# Consume the next leg's first real step in the SAME accrual so
			# the budget is never swallowed at a junction (the false-wedge
			# that dropped healthy journeys at ceuta).
			if stood_on_head:
				var next_len := int(head_geo["walked_len"])
				if next_len > 1:
					var nd := -1 if bool(head_geo["reverse"]) else 1
					var na := (int(head_geo["end"]) - 1) \
						if bool(head_geo["reverse"]) else (int(head_geo["start"]) + 1)
					var next_tile: Vector2i = (head_geo["path"] as Array)[na]
					if _passable(next_tile) and next_tile != position_of(fleet):
						route["tile_index"] = 1
						_commit_cell(fleet, next_tile)
			return
		# The final leg ended: dock at the destination.
		legs.pop_front()
		route["leg"] = int(route.get("leg", 0)) + 1
		route["tile_index"] = 0
		_arrive(fleet, day)
		return
	var dir := -1 if reverse else 1
	var target: Vector2i = path[artifact + dir]
	if not _passable(target):
		# Impassable step (in-month seasonal ice on the walked span): hold
		# — the budget is spent and the accrual-level hold streak records
		# the block. Lane paths never cross land, so this is ice-only;
		# fleets SHARE tiles under the unified-movement amendment, so
		# occupancy never blocks a step (the task-K hop rule is retired).
		return
	route["tile_index"] = index + 1
	_commit_cell(fleet, target)


## Movement entry (unified-movement amendment — CO-LOCATION): fleets MAY
## share tiles; entry is gated by passability only (land / reef / in-month
## seasonal ice). Interactions are governed by the contact rules
## (§4.11.11.2 — Chebyshev 1 encounter) and the abstract NPC-vs-NPC
## auto-resolve, never by tile occupancy. (Spawn/camp placement keeps its
## own spread preference via [_is_occupied] — aesthetics, not a rule.)
func _can_enter(fleet: Dictionary, cell: Vector2i) -> bool:
	return _passable(cell)


## Records `cell` at the front of the fleet's transient wake trail (the
## cells it leaves behind, most recent first, ≤ [constant WAKE_LENGTH]);
## docs/80-* §4.5.2 — called at the movement commit and at spawn (the spawn
## cell becomes the first cell left behind). Never saved.
func _record_wake(fleet: Dictionary, cell: Vector2i) -> void:
	if cell == NO_CELL:
		return
	var id := str(fleet.get("id", ""))
	if id.is_empty():
		return
	var trail: Array = _wake_trails.get(id, [])
	if not trail.is_empty() and trail[0] == cell:
		return  # holding position (a blocked step): no duplicate wake tile
	trail.push_front(cell)
	while trail.size() > WAKE_LENGTH:
		trail.pop_back()
	_wake_trails[id] = trail


func _commit_cell(fleet: Dictionary, cell: Vector2i) -> void:
	var before := position_of(fleet)
	set_position(fleet, cell)
	# Unified-movement amendment (`60-*` §4.11.11): contact is sampled per
	# tile entered — every committed tile within Chebyshev 1 of the player
	# queues the pass-through engagement (consumed by [method
	# nearest_contact] after the tick).
	_note_pass_contact(fleet, cell)
	# Task L wake trail (docs/80-* §4.5.2): the cell just left is the newest
	# tile behind the marker (render layers draw it only while moving).
	if before != NO_CELL and before != cell:
		_record_wake(fleet, before)
	if before != NO_CELL and _by_id.has(str(fleet.get("id", ""))):
		_move_bucket(str(fleet.get("id", "")), before, cell)


## The pass-through contact rule (unified-movement amendment): a fleet
## stepping within Chebyshev [constant CONTACT_DISTANCE] of the player's
## tile mid-step engages exactly as an end-of-step proximity would — the id
## queues in [_pass_contacts]; a hunting-nation fleet also records the
## at-sea intel cell on the passed tile (the §4.11.11.1 rule
## `note_contacts` applies, evaluated on the pass).
func _note_pass_contact(fleet: Dictionary, cell: Vector2i) -> void:
	if chebyshev(cell, _player_tile_now()) > CONTACT_DISTANCE:
		return
	var id := str(fleet.get("id", ""))
	if not id.is_empty() and not _pass_contacts.has(id):
		_pass_contacts.append(id)
	var nation_id := str(fleet.get("nation_id", ""))
	if nation_id.is_empty():
		return
	if CharacterLib.reputation(nation_id) > NAVY_HOSTILE_REPUTATION:
		return
	GameState.world["hunter_intel_cell"] = {"x": cell.x, "y": cell.y}


## Syncs `route.tile_index` to the fleet's actual position on the ACTIVE
## leg geometry ([method _leg_progress]'s nearest-position remap, run
## eagerly at departure/spawn — under clock accrual a fleet can be
## observed between its departure and its first accrued step, and the
## save/consistency invariants require `cell == path[a + tile_index]`
## from that instant).
func _sync_route_progress(fleet: Dictionary) -> void:
	var route: Dictionary = fleet.get("route", {})
	var legs: Array = route.get("legs", [])
	if legs.is_empty():
		return
	var geo := _leg_geometry(legs[0])
	if geo.is_empty():
		return
	route["tile_index"] = _leg_progress(fleet, route, geo)


## Leg list exhausted: dock at the destination port (docked fleets sit at the
## port's berth tile) for [constant DWELL_DAYS] days. The arrival joins the
## transient port-traffic log (§4.11.11.4 task L pin) for the rumor rows.
func _arrive(fleet: Dictionary, day: int) -> void:
	var port_id := str(fleet.get("dest_port_id", ""))
	_note_event(str(fleet.get("id", "")), "arr %s" % port_id)
	if not port_id.is_empty():
		var berth := _port_cell(port_id)
		if berth.x >= 0:
			_commit_cell(fleet, berth)
		_log_port_traffic(port_id, "arrival", fleet, day)
	# Coasters ride the dwell-day cadence lever (§4.11.14 perf fallback 1);
	# every other role keeps the standing 2-day dock.
	var dwell := _coaster_dwell_days() \
		if str(fleet.get("role", "")) == COASTER else DWELL_DAYS
	fleet["dwell_until_day"] = int(day) + dwell


## Appends one record to the transient `GameState.npc_port_log`
## (`{port_id, kind, role, nation_id, fleet_id, day}`, newest last, capped at
## [constant PORT_LOG_MAX] — docs/90-* §8.1 task L pin): the tavern rumor
## source "departures/arrivals at this port within 3 days" reads it. Pure
## bookkeeping — never saved, never emitted.
func _log_port_traffic(port_id: String, kind: String, fleet: Dictionary,
		day: int) -> void:
	if port_id.is_empty():
		return
	GameState.npc_port_log.append({
		"port_id": port_id,
		"kind": kind,
		"role": str(fleet.get("role", "")),
		"nation_id": str(fleet.get("nation_id", "")),
		"fleet_id": str(fleet.get("id", "")),
		"day": int(day),
	})
	while GameState.npc_port_log.size() > PORT_LOG_MAX:
		GameState.npc_port_log.pop_front()


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
			pass  # raiders live in [_raider_tick] (task K); hunters in
			      # [_hunter_tick]; the treasure scheduler is task L
	# Unified-movement amendment: a fleet routed by this tick owes the same
	# day-remainder the accrual just paid everyone else — walk it now, so a
	# just-departed fleet is never observed in its raw pre-step state (the
	# old same-pass stepping guarantee). The mark jumps to `now` first:
	# docked time never accrues, and the next advance grants exactly one
	# more day — never a double-count of this one.
	if not ((fleet.get("route", {}) as Dictionary).get("legs", [])
			as Array).is_empty():
		_sync_route_progress(fleet)
		_fleet_mark[str(fleet.get("id", ""))] = _clock_now()
		var moved_from := position_of(fleet)
		_accrue_lane(fleet, day, _pending_delta)
		var moved_to := position_of(fleet)
		if moved_to != moved_from:
			moved_fleet_moves.append({"id": str(fleet.get("id", "")),
				"from": moved_from, "to": moved_to})


## Sells every cargo good whose live factor is above 1.0 at `port_id` —
## never sells into a saturated market (docs/30-* §4.4 sell rule). Returns
## the units sold. A COASTER's sale is scope-clamped to staples ∪ middle
## (decision 21 — never luxury/specialty/exclusive) and credits the unified
## tariff on each walked sale; lane traders keep the standing scope.
func _sell_cargo(fleet: Dictionary, port_id: String, cap: int) -> int:
	var scope_limited := str(fleet.get("role", "")) == COASTER
	var sold := 0
	for good_id in (fleet.get("cargo", {}) as Dictionary).keys():
		var good := str(good_id)
		var held := int((fleet["cargo"] as Dictionary)[good])
		if held <= 0:
			continue
		if scope_limited and not in_coaster_scope(good):
			# Decision 21: the goods-scope clamp holds at SELL — a coaster
			# never unloads a specialty good, however hungry the market.
			continue
		if EconomyLib.factor_units(port_id, good) <= 1000:
			# factor ≤ 1.0 (stock ≥ 100, docs/30-* §4.2): keep sailing with it
			continue
		var qty := held if cap <= 0 else mini(held, cap - sold)
		if qty <= 0:
			break
		var price := TradeEngineLib.sell_price(port_id, good)
		EconomyLib.apply_trade(port_id, good, -qty)
		_credit_port_tax(port_id, fleet, qty, price)
		_note_moved(port_id)
		(fleet["cargo"] as Dictionary).erase(good)
		sold += qty
	return sold


## The coaster goods scope (decision 21, docs/60-* §4.11.14): staples ∪
## middle ONLY — never luxury/specialty/exclusive, i.e. never any
## `specialty: true` good. Clamped at buy AND sell.
static func in_coaster_scope(good_id: String) -> bool:
	return EconomyLib.tier_of(good_id) != "luxury"


## The scope-pool, id-sorted (the grey coaster's buy-scan universe; data is
## a per-run constant so the list caches — `reset_caches` clears it).
static var _scope_goods: Array = []
static func coaster_scope_goods() -> Array:
	if not _scope_goods.is_empty():
		return _scope_goods
	for good in DataLoader.goods_list:
		var id := str((good as Dictionary).get("id", ""))
		if id.is_empty() or not in_coaster_scope(id):
			continue
		_scope_goods.append(id)
	_scope_goods.sort()
	return _scope_goods


func _note_moved(port_id: String) -> void:
	if not moved_ports.has(port_id):
		moved_ports.append(port_id)


func _free_hold(fleet: Dictionary, capacity: int) -> int:
	var used := 0
	for good_id in (fleet.get("cargo", {}) as Dictionary):
		used += int((fleet["cargo"] as Dictionary)[good_id])
	return maxi(0, capacity - used)


## The trader's port call: sell the factor>1.0 part of the hold, then the
## joint (good, destination) argmax over the nation's produced goods × the
## alignment-pool ports within Chebyshev 120 (docs/30-* §4.4; §4.11.14
## docking), buy the bounded quantity, credit the tariff, and sail.
func _depart_trader(fleet: Dictionary, nation_id: String, day: int) -> void:
	# §4.11.14 docking pin (the rewritten L4679 rule): the cell-anchored
	# origin must be a port whose EFFECTIVE alignment equals the fleet's
	# nation — protected own, contestable aligned; never a rival-aligned or
	# unallied berth (fall back to the destination port, aligned by
	# construction).
	var origin := _docking_port_at_cell(fleet, position_of(fleet))
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
		var price := TradeEngineLib.buy_price(origin, good)
		EconomyLib.apply_trade(origin, good, qty)
		_credit_port_tax(origin, fleet, qty, price)
		_note_moved(origin)
		var cargo: Dictionary = fleet.get("cargo", {})
		cargo[good] = int(cargo.get(good, 0)) + qty
		fleet["cargo"] = cargo
	_set_route_to(fleet, origin, dest)


## The coaster's port call: ≤ 5 units traded, hold ≤ 10, between adjacent
## ports; never triggers contact (role rule) and is ignored by raiders (the
## prey query's rule). A sovereign coaster hops own-nation ports (standing
## rule); a nationless grey coaster hops the NEAREST ports regardless of
## ownership (§4.11.14, decision 18) and credits no tax (no host to pay —
## the payer is ""). Both scope-clamp to staples ∪ middle at buy and sell.
func _depart_coaster(fleet: Dictionary, nation_id: String, day: int) -> void:
	var nationless := nation_id.is_empty()
	var origin := ""
	if nationless:
		# The grey coaster may adopt ANY berth it stands on.
		origin = _port_at_cell(position_of(fleet))
	else:
		origin = _docking_port_at_cell(fleet, position_of(fleet))
	if origin.is_empty():
		origin = str(fleet.get("dest_port_id", ""))
	if origin.is_empty():
		fleet["dwell_until_day"] = int(day) + _coaster_dwell_days()
		return
	_sell_cargo(fleet, origin, coaster_units())
	var dest := ""
	if nationless:
		dest = _nearest_port_excluding(origin)
	else:
		dest = _nearest_own_port_excluding(origin, nation_id)
	if dest.is_empty():
		fleet["dwell_until_day"] = int(day) + _coaster_dwell_days()
		return
	# Buy ≤ the call cap of the best-margin in-scope good at origin
	# (decision 21: staples ∪ middle only — a specialty good never enters
	# the hold, whatever its margin).
	var pool: Array = coaster_scope_goods() if nationless \
		else nation_goods(nation_id)
	var best_good := ""
	var best_margin := 0
	for good_id in pool:
		var good := str(good_id)
		if not in_coaster_scope(good):
			continue
		var margin := TradeEngineLib.sell_price(dest, good) \
			- TradeEngineLib.buy_price(origin, good)
		if margin > best_margin:
			best_margin = margin
			best_good = good
	if not best_good.is_empty() and best_margin > 0:
		var saturation := _saturation_bound(dest, best_good)
		var qty := mini(coaster_units(), _free_hold(fleet, COASTER_HOLD_CAPACITY))
		qty = mini(qty, saturation)
		if qty > 0:
			var price := TradeEngineLib.buy_price(origin, best_good)
			EconomyLib.apply_trade(origin, best_good, qty)
			_credit_port_tax(origin, fleet, qty, price)
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
## save/load exactly). Task-H: the end is read on the ACTIVE geometry (the
## in-month variant replaces the tile path in its window), while the stored
## leg keeps the base-relative full-lane `a`/`b`.
func _depart_patrol(fleet: Dictionary, _day: int) -> void:
	var route: Dictionary = fleet.get("route", {})
	var lanes: Array = route.get("lanes", [])
	if lanes.is_empty():
		return
	# The patrol's dockable anchor: its home port (§4.1.1 — patrols dock at
	# a PORT berth, never in place). Setting `dest_port_id` lets `_arrive`
	# commit the home berth at the span end and gives `_lane_step_heading`'s
	# berth fallback a resolvable target (no 0-budget wedge).
	var home := _patrol_home_port(str(fleet.get("nation_id", "")))
	if not home.is_empty():
		fleet["dest_port_id"] = home
	var lane_id := str(lanes[0])
	var base: Array = _lane_paths.get(lane_id, [])
	if base.is_empty():
		return
	var geo := _leg_geometry({"kind": "lane", "id": lane_id,
		"reverse": false, "a": 0, "b": base.size() - 1})
	if geo.is_empty():
		return
	var path: Array = geo["path"]
	var far_end := int(geo["end"])
	var cell := position_of(fleet)
	# Board the lane at the NEAREST tile: a mid-lane un-wedged patrol is
	# already standing on the lane (teleport-free re-boarding — the wedge
	# drop hands `legs: []` patrols back here); a fleet genuinely off the
	# lane waits rather than teleport (hand edit).
	var nearest := 0
	var best_d := -1
	for index in path.size():
		var d := chebyshev(cell, path[index])
		if best_d < 0 or d < best_d:
			best_d = d
			nearest = index
	# The walk direction: from the nearer end toward the other.
	var reverse := chebyshev(cell, path[0]) > chebyshev(cell, path[far_end])
	var board := 0 if not reverse else far_end
	var ti := nearest
	if reverse:
		ti = far_end - nearest
	route["leg"] = 0
	route["tile_index"] = ti
	route["legs"] = [{"kind": "lane", "id": lane_id, "reverse": reverse,
		"a": 0, "b": base.size() - 1}]
	fleet["route"] = route
	fleet["dwell_until_day"] = 0


func _set_route_to(fleet: Dictionary, origin: String, dest: String) -> void:
	var route := route_between(origin, dest)
	if route.is_empty():
		# The validator makes this unreachable; idle and retry (never stall).
		# A coaster idles on its own cadence (§4.11.14 dwell lever).
		_note_event(str(fleet.get("id", "")), "depX %s->%s" % [origin, dest])
		fleet["route"] = {"lanes": [], "leg": 0, "tile_index": 0, "legs": []}
		fleet["dwell_until_day"] = int(GameState.day) \
			+ (_coaster_dwell_days() if str(fleet.get("role", "")) == COASTER
				else DWELL_DAYS)
		return
	# The cache entry is shared by every fleet on this pair — fleets mutate
	# their route (legs pop, tile_index), so each gets its own deep copy.
	fleet["route"] = (route["legs_save"] as Dictionary).duplicate(true)
	fleet["dest_port_id"] = dest
	fleet["dwell_until_day"] = 0
	_note_event(str(fleet.get("id", "")), "dep %s->%s" % [origin, dest])
	# Task L: the departure joins the transient port-traffic log (§4.11.11.4).
	_log_port_traffic(origin, "departure", fleet, int(GameState.day))


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


## Ports aligned to `nation_id` within Chebyshev 120 of `origin`, wrap-
## aware, id-sorted (docs/30-* §4.4 candidate destinations, the §4.11.14
## docking pool: the EFFECTIVE-ALIGNMENT ports — a flipped port joins the
## flipping nation's candidate set at once).
func _candidate_destinations(origin: String, nation_id: String) -> Array:
	var out: Array = []
	var center := _port_cell(origin)
	if center.x < 0:
		return out
	for port_id in alignment_ports(nation_id):
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


## The coaster port-call dwell — the §4.11.14 dwell-day cadence constant
## (the pinned perf fallback 1: "coasters call every ⌈dist/16⌉+2; stretch
## the cadence"). Shipped value: **4** — re-measured at the Phase-7 spawn
## count (task N record): the coasters' at-sea duty cycle drops from ~50%
## to ~33%, pulling the day tick under the §4.11.11.5 gate without touching
## any budget. Pinned here because the §4.10 npc_config key sets are
## exactly locked by the validator (a new flow key would fail group 7) —
## the retune stays a one-constant change reported in the record.
const COASTER_DWELL_DAYS := 4


func _coaster_dwell_days() -> int:
	return COASTER_DWELL_DAYS


func path_budget_ms() -> int:
	# Phase-6 re-measurement (task H, correction 13): at the quadrupled
	# 30/40 chase area the worst observed plan is ≈ 61 ms/day across
	# roughness-75 archipelago water (test_npc_fleets §21 probe, 40 forced
	# re-plans/day) — inside the locked 250 ms/day budget, so the shipped
	# full-region pursuit A* ships unchanged (windowing was gated on
	# measured failure and did not trigger).
	return int(_flow().get("path_budget_ms_per_day", 250))


# --- Task L schedulers: treasure fleets & named pirates (§4.11.11.4) ----------

## `nation_index` = the nation's position in `nations.json` file order
## (portugal 0 … italy 5 — §4.11.11.4).
static func nation_index(nation_id: String) -> int:
	for index in DataLoader.nations_list.size():
		if str((DataLoader.nations_list[index] as Dictionary).get("id", "")) \
				== nation_id:
			return index
	return -1


## True on `nation_id`'s treasure day: `45 + 15 × nation_index` (mod 90), from
## the first season onward (§4.11.11.4 ⇒ days 45/60/75/90/105/120, then +90).
func treasure_due(nation_id: String, day: int) -> bool:
	var index := nation_index(nation_id)
	if index < 0:
		return false
	var due := int(day) - (TREASURE_BASE_DAY + TREASURE_NATION_STEP * index)
	return due >= 0 and due % TREASURE_SEASON_DAYS == 0


## The seasonal pass (§4.11.11.4 "1/nation/season"): on each nation's due day,
## if no treasure fleet of that nation is alive, spawn one on its historical
## lane. Transient ≤ 6 at normal — they live in the global-cap slack.
func _schedule_treasure(day: int) -> void:
	for nation in DataLoader.nations_list:
		var nation_id := str((nation as Dictionary).get("id", ""))
		if nation_id.is_empty():
			continue
		if not treasure_due(nation_id, int(day)):
			continue
		if _count_role(TREASURE, nation_id) > 0:
			continue
		spawn(TREASURE, nation_id, int(day))


## The treasure fleet's journey: board the capital's historical lane (the lane
## its built spoke attaches to) at the tile nearest the capital and arm the
## full-lane leg; hold = ×3 a normal port call of a seeded nation good. `{}`
## when the nation has no usable lane (the scheduler skips that season).
func _treasure_journey(nation_id: String, day: int) -> Dictionary:
	_refresh_net()
	var capital := _capital_of(nation_id)
	var lane_id := str(_spoke_lane.get(capital, ""))
	var lane_path: Array = _lane_paths.get(lane_id, [])
	if capital.is_empty() or lane_id.is_empty() or lane_path.is_empty():
		return {}
	var harbor := _port_cell(capital)
	if harbor.x < 0:
		return {}
	# Board at the lane tile nearest the capital (the §4.1.1 patrol pattern).
	var best_index := 0
	var best_distance := -1
	for index in lane_path.size():
		var distance := chebyshev(harbor, lane_path[index])
		if best_distance < 0 or distance < best_distance:
			best_distance = distance
			best_index = index
	if _is_occupied(lane_path[best_index], ""):
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
		"cell": lane_path[best_index],
		"route": {"lanes": [lane_id], "leg": 0, "tile_index": 0,
			"legs": [{"kind": "lane", "id": lane_id, "reverse": reverse,
				"a": 0, "b": lane_path.size() - 1}]},
		"cargo": _treasure_cargo(nation_id, day),
	}


## The hold: ×3 a normal port call (`flow.trade_units_per_port_call`) of one
## seeded good of the nation (§4.11.11.4 "cargo ×3 normal volume"). The gold
## half of the loot pin is paid by the player-attack loot row (§4.11.11.2).
func _treasure_cargo(nation_id: String, day: int) -> Dictionary:
	var goods := nation_goods(nation_id)
	if goods.is_empty():
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = int(day) * SEED_DAY_MULT + nation_index(nation_id) * SEED_X_MULT \
		+ hash("treasure|" + nation_id)
	var good: String = goods[rng.randi_range(0, goods.size() - 1)]
	var units := TREASURE_CARGO_MULT * trade_units_per_call()
	return {good: units}


## §4.11.11.2 composition detail: `3 + rng(0..2)` merchant hulls plus **one
## patrol-escort hull**, whole-fleet cannon budget `30 + floor(day/30)` (the
## patrol budget — one implementation). Draws from the fleet's own stream, so
## save/load reproduces the composition.
static func compose_treasure_ships(fleet: Dictionary, day: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(fleet.get("seed", 0)) * 31 + hash("treasure_compose")
	var ships: Array = []
	var count := TREASURE_MERCHANT_HULLS + rng.randi_range(0, 2)
	for _index in count:
		var hull: String = AiFleetLib.HULL_IDS[rng.randi_range(0, 3)]
		ships.append(_treasure_hull(hull))
	ships.append(_treasure_hull(AiFleetLib.HULL_IDS[
		rng.randi_range(0, AiFleetLib.HULL_IDS.size() - 1)]))
	AiFleetLib._deal_cannons(ships, AiFleetLib.cannon_budget(PATROL, int(day)))
	return ships


## One §4.11.3 base hull (crew = crew_min, full durability, empty equipment).
static func _treasure_hull(hull_id: String) -> Dictionary:
	var ship_type: Dictionary = DataLoader.get_ship_type(hull_id)
	return {
		"ship_type_id": hull_id,
		"durability": int(ship_type.get("durability", 0)),
		"crew": int(ship_type.get("crew_min", 0)),
		"provisions": 0,
		"water": 0,
		"cannons": 0,
		"equipment": {"figurehead": "", "sail": ""},
		"cargo": {},
	}


## The named-pirate ids currently carried by a live pirate fleet.
static func _named_ids_in_use() -> Dictionary:
	var in_use: Dictionary = {}
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		var named_id := str(((fleet as Dictionary).get("captain", {}) \
			as Dictionary).get("named_id", ""))
		if not named_id.is_empty():
			in_use[named_id] = true
	return in_use


## The first `named_pirates.json` entry (file order) carried by no live fleet
## and reserved by no pending respawn. `after_id` starts the scan one entry
## past a defeated captain ("the next pool entry", §4.11.11.4) — the defeated
## identity itself is never re-drawn for its own successor.
static func next_named_pirate_id(after_id: String = "") -> String:
	var list: Array = DataLoader.named_pirates_list
	if list.is_empty():
		return ""
	var in_use := _named_ids_in_use()
	var start := 0
	if not after_id.is_empty():
		for index in list.size():
			if str((list[index] as Dictionary).get("id", "")) == after_id:
				start = (index + 1) % list.size()
				break
	for offset in list.size():
		var entry: Dictionary = list[(start + offset) % list.size()]
		var id := str(entry.get("id", ""))
		if id.is_empty() or in_use.has(id) \
				or GameState.named_pirate_respawns.has(id):
			continue
		return id
	return ""


## The famous named-pirate entry a fleet's captain carries (`{}` when the
## captain is a successor or unnamed) — the §4.11.11.4 "famous pirates
## override" identity.
static func named_captain_of(fleet: Dictionary) -> Dictionary:
	var named_id := str((fleet.get("captain", {}) as Dictionary)
		.get("named_id", ""))
	if named_id.is_empty():
		return {}
	return DataLoader.get_named_pirate(named_id)


## True when the fleet's captain is a *named* pirate (famous override or a
## respawned successor) — poster- and bounty-worthy (§4.11.11.4).
static func is_named_captain(fleet: Dictionary) -> bool:
	if not named_captain_of(fleet).is_empty():
		return true
	return int((fleet.get("captain", {}) as Dictionary)
		.get("named_tier", 0)) > 0


## The named captain's bounty tier (`70-*` §4.5 tiers 1–3; a successor
## inherits its slot's tier). 0 when the captain is not named.
static func named_tier_of(fleet: Dictionary) -> int:
	var named := named_captain_of(fleet)
	if not named.is_empty():
		return int(named.get("tier", 1))
	return int((fleet.get("captain", {}) as Dictionary)
		.get("named_tier", 0))


## The nationless-pool name indexes currently carried by live fleets —
## successor draws skip them so no name is ever shared.
static func _pool_indexes_in_use() -> Dictionary:
	var in_use: Dictionary = {}
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		var captain: Dictionary = (fleet as Dictionary).get("captain", {})
		if str(captain.get("pool_id", "")) == "":
			in_use[int(captain.get("name_index", -1))] = true
	return in_use


## The next free nationless-pool entry for a successor name (the rotation
## cursor steps forward each draw, wrapping; deterministic). −1 when every
## entry is afloat.
static func _next_successor_index() -> int:
	var pool: Dictionary = DataLoader.get_captain_pool("")
	var names: Array = pool.get("names", []) if pool.get("names", []) is Array else []
	if names.is_empty():
		return -1
	var in_use := _pool_indexes_in_use()
	for _offset in names.size():
		var index := posmod(_successor_cursor, names.size())
		_successor_cursor += 1
		if not in_use.has(index):
			return index
	return -1


## The daily respawn pass (§4.11.11.4): a slot whose +30 days have elapsed
## sails again under the next nationless-pool name, inheriting the slot's
## bounty tier. The defeated famous identity stays reserved while the entry
## is pending; a draw with no legal anchor — or an exhausted pool — retries
## the next day. Reading `GameState.named_pirate_respawns` (saved,
## `{named_id: available_day}`): the tier comes from the key — a famous id
## looks itself up in `named_pirates.json`, a `successor_<tier>` slot parses
## its suffix — so the persisted map stays the documented bare-day shape.
func _named_pirate_tick(day: int) -> void:
	for slot_id in (GameState.named_pirate_respawns.keys() as Array).duplicate():
		var available_day := int(GameState.named_pirate_respawns[slot_id])
		if int(day) < available_day:
			continue
		var tier := _respawn_slot_tier(str(slot_id))
		if tier <= 0:
			# Unknown slot key (a hand-edited save): drop it, never wedge.
			GameState.named_pirate_respawns.erase(slot_id)
			continue
		# Draw the successor name BEFORE spawning: an exhausted nationless
		# pool must leave the slot pending without leaking an unnamed
		# pirate past the §4.1.1 budget (the leak compounded daily — every
		# retry spawned another plain pirate while the slot stayed open).
		var index := _next_successor_index()
		if index < 0:
			continue
		var fleet := spawn(PIRATE, "", int(day))
		if fleet.is_empty():
			continue
		fleet["captain"] = {"pool_id": "", "name_index": index,
			"named_tier": tier}
		GameState.named_pirate_respawns.erase(slot_id)


## The bounty tier a respawn slot key carries: a famous id resolves its
## `named_pirates.json` entry; `successor_<tier>` parses the suffix; 0 for
## anything else (a hand-edited key is dropped, never wedges the pass).
static func _respawn_slot_tier(slot_id: String) -> int:
	if slot_id.begins_with("successor_"):
		return maxi(0, int(slot_id.trim_prefix("successor_")))
	return int(DataLoader.get_named_pirate(slot_id).get("tier", 0))


## The live named-pirate fleet a bounty quest prefers (§4.11.11.4): the
## first `named_pirates.json` entry with a live carrier (then lowest fleet
## id), else the lowest-id successor. `{}` when no named pirate is alive.
static func preferred_bounty_target() -> Dictionary:
	for entry in DataLoader.named_pirates_list:
		var named_id := str((entry as Dictionary).get("id", ""))
		if named_id.is_empty():
			continue
		var best: Dictionary = {}
		for fleet in GameState.npc_fleets:
			if not (fleet is Dictionary) or str((fleet as Dictionary)
					.get("role", "")) != PIRATE:
				continue
			if str((((fleet as Dictionary).get("captain", {}) as Dictionary)
					.get("named_id", ""))) != named_id:
				continue
			if best.is_empty() \
					or str((fleet as Dictionary).get("id", "")) \
					< str(best.get("id", "")):
				best = fleet
		if not best.is_empty():
			return best
	var best: Dictionary = {}
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary) or str((fleet as Dictionary)
				.get("role", "")) != PIRATE:
			continue
		if not is_named_captain(fleet):
			continue
		if best.is_empty() or str((fleet as Dictionary).get("id", "")) \
				< str(best.get("id", "")):
			best = fleet
	return best


# --- Trickle & budgets (docs/60-* §4.1.2) -----------------------------------

func _trickle(day: int) -> Array:
	var spawned: Array = []
	var budget := trickle_per_day()
	var npc_config: Dictionary = _config.get("npc_config", DataLoader.npc_config)
	var absolute := int(npc_config.get("absolute_cap", 2048))
	var cap := global_cap()
	for _attempt in budget * 4:
		if spawned.size() >= budget:
			break
		if GameState.npc_fleets.size() >= absolute:
			break
		if GameState.npc_fleets.size() >= cap:
			break
		var deficit := _largest_deficit()
		if deficit.is_empty():
			break
		var fleet := spawn(str(deficit["role"]), str(deficit["nation_id"]), day)
		if not fleet.is_empty():
			spawned.append(fleet)
			# The ranking stays valid: this owner's deficit shrinks by
			# exactly one (its entry updates in place — a decrement cannot
			# reorder other owners; ties keep the scan order, the same
			# answer a full recompute would give).
			deficit["deficit"] = int(deficit["deficit"]) - 1
			if int(deficit["deficit"]) <= 0:
				_deficit_list.pop_front()
		else:
			# The draw failed (no legal tile): skip this owner for today.
			_skip[deficit["role"] + "|" + deficit["nation_id"]] = int(day)
	return spawned


## The (role, nation) owner with the largest budget deficit, in FILL_ORDER —
## so the cap can never starve traders for pirates (role order is the
## priority order).
##
## The deficit scan is a per-DAY ranking ([method _compute_deficit_list],
## one O(fleets × owners) pass, rebuilt whenever a spawn changes the counts
## — the §4.11.11.5 linearity contract): each trickle attempt walks the
## ranking past owners already skipped today, instead of re-scanning the
## whole fleet array up to [method trickle_per_day] × 4 times a day.
## Selection order and results are identical to the per-attempt rescan it
## replaced (argmax deficit, ties by generation order).
func _largest_deficit() -> Dictionary:
	var day := last_tick_day
	if _deficit_day != day:
		_deficit_day = day
		_deficit_list = _compute_deficit_list()
	while not _deficit_list.is_empty():
		var head: Dictionary = _deficit_list[0]
		var owner := str(head["role"]) + "|" + str(head["nation_id"])
		if not (_skip.has(owner) and int(_skip[owner]) == day):
			return head
		_deficit_list.pop_front()
	return {}


## The per-day deficit ranking, best first. Each entry carries its deficit
## and its scan-order index; the sort key `(deficit desc, index asc)` is the
## rescan's argmax-with-earliest-tie semantics, made explicit so the sort's
## stability never matters. Skips are honored at WALK time (they can fire
## after the compute pass).
func _compute_deficit_list() -> Array:
	var entries: Array = []
	for role in FILL_ORDER:
		if role == PIRATE:
			var live := _count_role(role, "")
			var want := budget_for(role, "")
			if want > live:
				entries.append({"role": role, "nation_id": "",
					"deficit": want - live, "index": entries.size()})
			continue
		if role == COASTER:
			# Phase-7 (§4.11.14): the nationless tier owns its own budget
			# line — counted with an exact nation match (`_count_role` with
			# "" would count the sovereign coasters too).
			var grey_live := _count_role_nationless(role)
			var grey_want := budget_for(role, "")
			if grey_want > grey_live:
				entries.append({"role": role, "nation_id": "",
					"deficit": grey_want - grey_live, "index": entries.size()})
		if role == HUNTER:
			# Bounty-only: at most one hunter per bountied nation.
			for nation_id in bountied_nations():
				var hunter_live := _count_role(role, nation_id)
				if hunter_live == 0:
					entries.append({"role": role, "nation_id": nation_id,
						"deficit": 1, "index": entries.size()})
			continue
		for nation_id in _port_counts():
			var want := budget_for(role, nation_id)
			var live := _count_role(role, nation_id)
			if want > live:
				entries.append({"role": role, "nation_id": nation_id,
					"deficit": want - live, "index": entries.size()})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["deficit"]) != int(b["deficit"]):
			return int(a["deficit"]) > int(b["deficit"])
		return int(a["index"]) < int(b["index"]))
	return entries


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


## Exact nationless count of a role (nation_id == "" as a MATCH, not a
## wildcard): the nationless-coaster budget line's live count (§4.11.14).
func _count_role_nationless(role: String) -> int:
	var count := 0
	for fleet in GameState.npc_fleets:
		if not (fleet is Dictionary):
			continue
		if str(fleet.get("role", "")) != role:
			continue
		if str(fleet.get("nation_id", "")) != "":
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
## the role→budget map lives in `ai_fleet.gd`'s `CANNON_BUDGET`. A treasure
## fleet composes per the §4.11.11.2 detail (task L): 3–5 merchant hulls plus
## one patrol-escort hull at the patrol cannon budget.
static func compose_fleet_ships(fleet: Dictionary, day: int) -> Array:
	if str(fleet.get("role", "")) == TREASURE:
		return compose_treasure_ships(fleet, day)
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


## Reads a bare cell field (`{"x","y"}` dict, Vector2i/2) — the shape of
## `anchor_cell` and other saved cells that are NOT fleet dicts
## ([method position_of] reads a fleet's `cell` key instead).
static func _cell_field(value) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(value)
	if value is Dictionary:
		return Vector2i(int((value as Dictionary).get("x", -1)),
			int((value as Dictionary).get("y", -1)))
	return NO_CELL


## Marker colour (docs/80-* §4.5.2): pirate = BAD red, every national fleet =
## its nation colour (hunter included), the nationless grey coaster = the
## neutral-port grey (中立灰 livery, docs/60-* §4.11.14 — the pirate
## nationless precedent's livery half). Placeholder palette only.
static func marker_color(role: String, nation_id: String) -> Color:
	if role == PIRATE:
		return PaletteLib.BAD
	if role == COASTER and nation_id.is_empty():
		return PaletteLib.PORT_NEUTRAL
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
## **Width-derived packing** (Phase-6 correction 6): the stride and wrap come
## from [member _width] (the loaded legend's `grid.width`), never a hardcoded
## constant — the old `* 4096 + posmod(cell.x, 4096)` packing broke outright
## at `x > 4095`. Keys are runtime-only (rebuilt from the artifact on every
## net refresh; nothing persisted uses this packing).
static func _cell_key(cell: Vector2i) -> int:
	return int(cell.y) * _width + int(posmod(cell.x, _width))


static func _key_to_cell(key: int) -> Vector2i:
	return Vector2i(int(key) % _width, int(key) / _width)


static func _bucket_of(cell: Vector2i) -> int:
	@warning_ignore("integer_division")
	return (cell.y / BUCKET_SIZE) * _buckets_x() \
		+ posmod(cell.x, _width) / BUCKET_SIZE


## Buckets across one wrapped world row (`ceil(width / BUCKET_SIZE)`).
static func _buckets_x() -> int:
	@warning_ignore("integer_division")
	return (_width - 1) / BUCKET_SIZE + 1


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
	var buckets_x := _buckets_x()
	@warning_ignore("integer_division")
	var max_bucket_y := (_height - 1) / BUCKET_SIZE
	# Wrap the CELL range first, then divide — truncation toward zero on a
	# negative numerator would otherwise miss the seam bucket.
	@warning_ignore("integer_division")
	var min_bx := posmod(posmod(cell.x - radius, _width), _width) / BUCKET_SIZE
	@warning_ignore("integer_division")
	var max_bx := posmod(posmod(cell.x + radius, _width), _width) / BUCKET_SIZE
	@warning_ignore("integer_division")
	var by := posmod(cell.y, _height) / BUCKET_SIZE
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
			var bucket := bucket_y * buckets_x + bx
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
## The player's tile — the tick-scoped cache inside a tick, the live
## lookup otherwise (a direct query between ticks must see a fresh move).
func _player_tile_now() -> Vector2i:
	return _tick_player_tile if _tick_scoped else GameState.world_tile()


## Spawn/aesthetic placement preference (NOT a movement rule — the
## unified-movement amendment allows fleets to share tiles): a cell is
## "taken" for spawn/camp placement when it is the player's tile or holds
## another under-way fleet (docked fleets share port tiles). Spread checks
## only; movement never consults this.
func _is_occupied(cell: Vector2i, ignore_id: String) -> bool:
	if cell == _player_tile_now():
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


## The port-call berth at `cell` — the REWRITTEN Phase-6 docking pin
## (docs/60-* §4.11.14; the Phase-6 task-H "own nation only" rule is
## amended by the effective-alignment rule, docs/30-* §4.9):
##   * a TRADER of nation N adopts any port whose effective alignment == N
##     (protected own + contestable aligned — sovereign non-core and
##     neutral alike); a rival-aligned or unallied berth returns "";
##   * a sovereign COASTER stays own-nation (its hops are ownership-
##     restricted — the standing rule);
##   * a NATIONLESS coaster adopts ANY berth (it serves every coast);
##   * other nationless roles (pirates) have no port calls at all.
## A trader walking a lane can pass over a foreign port's spoke berth
## mid-leg; the departure decisions must not adopt that berth.
func _docking_port_at_cell(fleet: Dictionary, cell: Vector2i) -> String:
	var port_id := _port_at_cell(cell)
	if port_id.is_empty():
		return ""
	var role := str(fleet.get("role", ""))
	var nation_id := str(fleet.get("nation_id", ""))
	if role == COASTER and nation_id.is_empty():
		return port_id
	if nation_id.is_empty():
		return ""
	if role == TRADER:
		return port_id if port_alignment(port_id) == nation_id else ""
	if str(DataLoader.get_port(port_id).get("nation_id", "")) != nation_id:
		return ""
	return port_id


func _port_cell(port_id: String) -> Vector2i:
	var cell: Vector2i = DataLoader.port_cell(port_id)
	return cell if cell.x >= 0 else NO_CELL


func _passable(cell: Vector2i) -> bool:
	# Per-day memo (unified-movement amendment): the tick evaluates entry on
	# thousands of tiles over the same lanes — one bitmask + ice-mask sample
	# per DISTINCT cell per day instead of per step.
	if _passable_day != int(GameState.day):
		_passable_cache = {}
		_passable_day = int(GameState.day)
	if _passable_cache.has(cell):
		return _passable_cache[cell]
	var out := false
	if DataLoader.is_passable(cell):
		# Phase-6 §4.18 (task-H item 3): in-month seasonal ice refuses
		# ENTRY — this one rule serves lane stepping, raider chase/return
		# steps, spawn placement, approach camping and the pursuit A*
		# callback alike. A tile freezing under a standing fleet never
		# traps it: only the ENTERED cell is ever checked here, so a fleet
		# standing on a frozen tile may still move out. The month comes
		# from the sim clock (`GameState.day`).
		out = not OceanLayersLib.instance().ice_blocks(
			cell, SailingSimLib.month_for(GameState.day))
	_passable_cache[cell] = out
	return out


## Wrap-aware Chebyshev distance (`20-*` §4.1): `min(|dx|, width − |dx|)`.
static var _cheb_width: int = 0
static func chebyshev(a: Vector2i, b: Vector2i) -> int:
	if _cheb_width <= 0:
		var grid: Dictionary = DataLoader.map_legend.get("grid", {})
		_cheb_width = int(grid.get("width", 0))
		if _cheb_width <= 0:
			_cheb_width = 4320
	var width := _cheb_width
	var dx := absi(a.x - b.x) % width
	return maxi(mini(dx, width - dx), absi(a.y - b.y))


func _ensure_rng() -> void:
	if _rng_seeded:
		return
	var tile := GameState.world_tile()
	_rng.seed = GameState.day * SEED_DAY_MULT + tile.x * SEED_X_MULT \
		+ tile.y * SEED_Y_MULT
	_rng_seeded = true
