class_name BattleSim
extends RefCounted
## Turn engine for grid sea battles — the Phase-9 velocity-physics model
## (docs/60-COMBAT.md §4.2–§4.7, §4.3a/§4.4a/§4.4b/§4.6a, §4.11.2–§4.11.12,
## §4.12.1/§4.12.1.1).
##
## Pure logic, no node references (docs/90-ARCHITECTURE.md §4). The engine
## **never mutates `GameState`**: it deep-copies the ship instances handed to
## [method _init] and owns every battle-local field itself (units, RNG, log,
## outcome tallies). Reading the player's Person-model values (swordplay /
## courage / charisma / effective gunnery, §4.4/§4.11.5/§4.11.6) and the worn
## equipment is the only GameState access; the §4.12.1 battle-condition lock
## (`wind_dir` / `current`) is read once at construction when the config omits
## it (defaults documented on [method _init]).
##
## Model (§4.3a): every ship carries `pos` / `vel` (Vector2i), `heading8`,
## `reload_port` / `reload_starboard`, `speed_debuff_turns` and `crew`. A turn
## is three phases — pick a legal velocity, integrate it as a Bresenham sweep
## (the first occupied cell stops the ship: enemy ⇒ ram, friend/out-of-bounds
## ⇒ stop at the prior cell), then at most one action (cannon naming the
## side / ram / board / hold). The MP-era `cell` / `mp` / `mp_debuff` triple
## and `battle_mp` are retired (§4.3 historical note).
##
## Interface: every method/signature pinned in docs/60-* §4.12.1 (plus the
## §4.12.1 additions `legal_velocities` / `apply_velocity` / `snapshot` /
## `restore`), and the seams a caller needs that the pin leaves implicit:
##   * [method units] / [method living_units] — the AI (§4.12.1.1) and S10
##     must enumerate tokens;
##   * [method combat_rating] / [method effective_max_durability] /
##     [method gunnery_of] — the §4.11.5/§4.11.12 numbers;
##   * [method seed_value] — the §4.11.1 seed actually used (tests/audit);
##   * [method retreat] / [method offer_surrender] — the two menu-only
##     outcomes of §4.11.9/§4.11.7 (they are not per-unit actions);
##   * [method log_lines] — the structured log of §4.11.4 "damage order";
##   * [method ai_shot_type] — the §4.4b deterministic AI shot rule, shared
##     by the decision executor and the W3-B T2 AI (never a second copy).
##
## One implementation of every formula lives here; `ai_fleet.gd`, the S10
## screen and the S11 modal all call into this file instead of copying
## numbers.

const CharacterLib := preload("res://scripts/player/character.gd")
## Wind/current tables and the month calendar (20-* §4.4/§4.7/§4.15). One-way
## preload — the sailing module never loads combat.
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
## The decoded contact-tile current (`currents.png`, reversal at lookup,
## §6.5) — the §4.2 battle-condition lock default.
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")

# --- Grid & deployment (docs/60-* §4.2, §4.11.2) ---------------------------

const GRID_WIDTH := 48
const GRID_HEIGHT := 30
## §4.2 bands: player ships start at x ≤ 5, enemy ships at x ≥ 42; a band
## overflow (more than 5 ships) continues the in-band scan.
const PLAYER_BAND_MAX_X := 5
const ENEMY_BAND_MIN_X := 42
## §4.11.2 concrete tiles, indexed by fleet index (0 = flagship).
const PLAYER_DEPLOYMENT: Array = [
	Vector2i(2, 15), Vector2i(2, 14), Vector2i(2, 16), Vector2i(2, 13), Vector2i(2, 17),
]
const ENEMY_DEPLOYMENT: Array = [
	Vector2i(45, 15), Vector2i(45, 14), Vector2i(45, 16), Vector2i(45, 13), Vector2i(45, 17),
]
## §4.11.2 tournament variant (single bout): pinned cells and initial
## velocities — 27 cells apart, the bout opens already under way.
const TOURNAMENT_DEPLOYMENT := "tournament"
const TOURNAMENT_PLAYER_CELL := Vector2i(10, 15)
const TOURNAMENT_ENEMY_CELL := Vector2i(37, 15)
const TOURNAMENT_PLAYER_VEL := Vector2i(1, 0)
const TOURNAMENT_ENEMY_VEL := Vector2i(-1, 0)
## "No destination cell" marker for non-move decisions / queries.
const NO_CELL := Vector2i(-1, -1)

# --- heading8 (docs/60-* §4.3a, decision 1) --------------------------------
#
# heading8 ∈ 0..7 buckets a velocity's direction at the 22.5° boundaries:
# bucket = the nearest 45° of atan2(−vy, vx) — 0 = east (+x), increasing
# counterclockwise in the mathematical frame (screen y-down: (1,−1) = NE,
# (0,−1) = N …). Derived from vel via INTEGER dot comparisons against the
# eight compass rays — never atan2 (decision 1: portable, deterministic).
# `vel = (0,0)` keeps the last heading.
const HEADING_RAYS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]
## The 8-compass token of each bucket (the `20-*` §4.4 id set) — the bridge
## to `SailingSimLib.angle_between_dirs` for the wind/current tables.
const HEADING_TOKENS: Array[String] = ["E", "NE", "N", "NW", "W", "SW", "S", "SE"]
## Player deployment faces east, enemy faces west (§4.11.2).
const HEADING_EAST := 0
const HEADING_WEST := 4

# --- Sides -----------------------------------------------------------------

const SIDE_PLAYER := "player"
const SIDE_ENEMY := "enemy"

# --- Velocity & cap (docs/60-* §4.3a; decision 2, corrections 1–3) ----------

## The broadside arcs (§4.4): relative-bearing bucket steps (×45°,
## counterclockwise from the attacker's heading8).
const ARC_PORT_STEPS: Array[int] = [1, 2, 3]      # 45° / 90° / 135°
const ARC_STARBOARD_STEPS: Array[int] = [5, 6, 7]  # 225° / 270° / 315°
const BROADSIDE_PORT := "port"
const BROADSIDE_STARBOARD := "starboard"
## §4.4 broadside split at battle start (decision 3): port = floor(n / 2).
const BROADSIDE_SPLIT_DIVISOR := 2.0

# --- Cannon (docs/60-* §4.4, §4.11.5) --------------------------------------

const CANNON_RANGE_MIN := 1
const CANNON_RANGE_MAX := 3
## range_factor at range 1 / 2 / 3 (§4.4).
const CANNON_RANGE_FACTOR := {1: 1.0, 2: 0.75, 3: 0.5}
const CANNON_BASE_MULTIPLIER := 2
## §4.2 / §4.11.5 weather damage multipliers: storm ×0.75, strong ×0.9.
const STORM_CANNON_MULTIPLIER := 0.75
const STRONG_CANNON_MULTIPLIER := 0.9
const STORM_WEATHER := "storm"
const STRONG_WEATHER := "strong"
## §4.4 rake (纵射): ×1.25 when the target's bearing bucket relative to the
## TARGET's own heading8 ∈ {0°, 180°}.
const RAKE_MULTIPLIER := 1.25

# --- Shot types & gunnery (§4.4b; the Phase-8 gates stay in data) -----------

const ROUND_SHOT := "round"
const CHAIN_SHOT := "chain"
const ARMOR_PIERCING_SHOT := "armor_piercing"
## §4.4b grape: NO gate, range 1 only — hull floor(same-range round × 0.5)
## plus the crew kill floor(same-range round × 0.5), which IS the volley's
## casualty term (§4.11.5, replaces the /20 divisor for that volley).
const GRAPE_SHOT := "grape"
const GRAPE_HALF := 0.5
const CHAIN_DAMAGE_MULTIPLIER := 0.75
const CHAIN_DEBUFF_TURNS := 2
const ARMOR_PIERCING_DAMAGE_MULTIPLIER := 1.25
## §4.4 flagship damage term: `+ floor(effective_gunnery / 25)`.
const GUNNERY_BONUS_DIVISOR := 25
## §4.11.5 captain-card `bonus`: `floor(combat_rating / 10)` (the card cannon
## rating, see [method combat_rating]).
const COMBAT_BONUS_DIVISOR := 10
## §4.4 / skill_gates thresholds. The data row
## (`data/skill_gates.json` `shot.chain` / `shot.armor_piercing`) wins; these
## stand in only while the gates file is unreadable (defensive default).
const DEFAULT_CHAIN_GATE := 25
const DEFAULT_ARMOR_PIERCING_GATE := 50

# --- Crew casualties (§4.11.5, correction 7) --------------------------------

## Standard volley `crew −= floor(damage / 20)`; rake volley `/ 10`; clamped
## at 0. A grape volley's casualty is its dedicated crew kill instead.
const CREW_CASUALTY_DIVISOR := 20
const CREW_CASUALTY_RAKE_DIVISOR := 10
## Boarding winner `crew −= floor(crew × 0.2)` (§4.6a/§4.11.6); clamped at 0.
const BOARDING_CREW_LOSS_FRACTION := 0.2

# --- Reload (docs/60-* §4.4a; decision 5) -----------------------------------

## `reload_turns = clamp(3 − floor(gunnery / 50), 1, 3) + (crew_ratio < 0.5 ? 1 : 0)`.
const RELOAD_BASE_TURNS := 3
const RELOAD_MIN_TURNS := 1
const RELOAD_GUNNERY_DIVISOR := 50
const RELOAD_LOW_CREW_RATIO := 0.5
const RELOAD_LOW_CREW_BONUS := 1

# --- Ram (docs/60-* §4.5, §4.11.5; decision 7) -----------------------------

const RAM_TARGET_FRACTION := 0.25
const RAM_ATTACKER_FRACTION := 0.10
const RAM_SPEED_STEP := 0.25
## §4.5 bow/stern approach (bearing bucket ∈ {0°, 180°} vs the TARGET's
## heading8) ×1.15.
const RAM_BOW_STERN_MULTIPLIER := 1.15
## §4.5 galley identity rule (oar/hybrid attackers, folded into mult).
const OAR_RAM_MULTIPLIER := 1.25
const OAR_SHIP_CLASSES: Array[String] = ["oar", "hybrid"]

# --- Duel (docs/60-* §4.6, §4.11.6) — unchanged ----------------------------

const DUEL_WINS_NEEDED := 3
const DUEL_MAX_ROUNDS := 5
const DUEL_ROUND_MAX_ROLL := 20
const DUEL_CREW_DIVISOR := 5
const DUEL_CREW_CAP := 20
## §4.11.5/§4.11.6 legacy stand-in (`5 + fleet tier`) for fleets without a
## captain canon card — kept byte-identical to Phase 2/8 until the fleet
## source carries per-ship canon ratings (W4-B).
const CAPTAIN_RATING_BASE := 5
## §4.6 "fleet tier": pirate tier 1, navy tier 2, Phase-3 tournament bouts
## tier 2 as well (`60-*` §4.11.7.1).
const FLEET_TIER := {"pirate": 1, "navy": 2, "tournament": 2}
## §4.11.6 Phase-8 duel terms: attacker `+ floor(courage / 20)`, the defender
## adds `+ floor(charisma / 20)`; card cannon term `+ floor(gunnery / 25)`.
const DUEL_COURAGE_DIVISOR := 20
const DEFENDER_CHARISMA_DIVISOR := 20
const CARD_CANNON_DIVISOR := 25

# --- §4.4a / §4.7 legacy fallbacks (decision 5, correction 6) ---------------
#
## A fleet without canon cards reads `10 + 10 × tier` for BOTH the gunnery
## gate source (§4.4a) and the surrender courage (§4.7) — the doc-pinned
## legacy fallback family.
const LEGACY_FALLBACK_BASE := 10
const LEGACY_FALLBACK_PER_TIER := 10

# --- AI surrender roll (§4.7; the W3 gate stays per the Phase-8 trigger) ----

## `clamp(25 − floor(courage / 10), 10, 40)` percent, drawn from the battle's
## §4.11.1 stream ([method roll_surrender]); a failed roll re-rolls on the
## ship's next turn. The Phase-9 morale model widens it by the §4.8a modifier
## ([method morale_surrender_bonus]) — the hooks are the `courage_mod` and
## `morale` parameters, W3 callers pass 0 / the default.
const SURRENDER_CHANCE_BASE := 25
const SURRENDER_CHANCE_MIN := 10
const SURRENDER_CHANCE_MAX := 40
const SURRENDER_COURAGE_DIVISOR := 10
## §4.7/§4.8a: the roll chance gains `+ floor((20 − morale) / 2)` pp on top of
## the clamped base (base ceiling 40 + 10 = 50% at morale 0).
const SURRENDER_MORALE_DIVISOR := 2

# --- Side morale (docs/60-* §4.8a; decision 9, corrections 5/6) -------------

## One morale value per side, 0–100 ([method side_morale]).
const MORALE_MIN := 0
const MORALE_MAX := 100
## §4.8a event table (both sides). The flagship-sunk −30 is TOTAL: it REPLACES
## the friendly-sunk −15 on that event (correction 5) — the side loses exactly
## 30, never 45.
const MORALE_EVENT_FRIENDLY_SUNK := -15
const MORALE_EVENT_CAPTURED := -20
const MORALE_EVENT_FLAGSHIP_SUNK := -30
const MORALE_EVENT_RAKED := -5
const MORALE_EVENT_BOARDING_WIN := 10
const MORALE_EVENT_BOARDING_LOSS := -10
## §4.8a gates: side morale ≤ 20 (with durability ≤ 25%) opens the §4.7
## surrender roll; side morale ≤ 10 strikes EVERY living AI ship at its next
## turn with NO roll (AI-side only — player ships never auto-strike).
const MORALE_SURRENDER_GATE := 20
const MORALE_INSTANT_STRIKE := 10
## §4.8a AI start: `clamp(40 + flagship-captain courage, 20, 90)` — courage
## from the enemy flagship's captain card; the legacy no-card fallback is
## `10 + 10 × tier` (correction 6, [method _ship_or_card_courage]).
const ENEMY_MORALE_COURAGE_BASE := 40
const ENEMY_MORALE_FLOOR := 20
const ENEMY_MORALE_CEILING := 90

## RETIRED Phase-8 number (§4.8 boarding-victory +5): the flat bonus is
## absorbed into the §4.8a event table (boarding win +10 / loss −10) and the
## outcome key `morale_bonus` is gone (§4.12.2 carries `morale_delta` now).
## Kept only so the §5 reference in `tools/test_battle_economy.gd` compiles
## until that suite's re-pin; no live code path reads it.
const BOARDING_MORALE_BONUS := 5

# --- Stall & cap (docs/60-* §4.11.9/§4.11.10; decision 12, correction 12) ---

## 8 consecutive rounds with zero damage and zero boarding and a net
## player↔enemy Chebyshev change ≤ 2 ⇒ outcome `stall`; any damage or
## boarding resets the counter.
const STALL_ROUNDS := 8
const STALL_DISTANCE_DELTA := 2
## §4.11.10: the round cap re-pins to 40 (the `run_to_completion` default,
## correction 12).
const MAX_ROUNDS := 40

# --- Outcome (docs/60-* §4.11.9, §4.11.10) --------------------------------

const RESULT_VICTORY := "victory"
const RESULT_DEFEAT_SUNK := "defeat_sunk"
const RESULT_DEFEAT_CAPTURED := "defeat_captured"
const RESULT_RETREAT := "retreat"
const RESULT_SURRENDER := "surrender"
## §4.11.9 stall row: the mutual-disengage outcome (after-apply semantics are
## the caller's — W4/apply-side; the engine only reports).
const RESULT_STALL := "stall"
const RESULT_UNFINISHED := ""
const RESULT_VALUES: Array[String] = [
	RESULT_VICTORY, RESULT_DEFEAT_SUNK, RESULT_DEFEAT_CAPTURED,
	RESULT_RETREAT, RESULT_SURRENDER, RESULT_STALL,
]
const XP_PER_ENEMY_NEUTRALIZED := 10
const XP_PER_ROUND := 5
const PIRATE_REP_GAIN := 2
## §4.11.10: the navy piracy penalty. Pinned here with the other reward
## numbers, but **never applied by this engine**: it is charged once at battle
## start by whoever initiated the navy battle (the S3 piracy funnel,
## `world_map.gd`), so it must not appear in an outcome block (see
## [method _rep_deltas]).
const NAVY_REP_PENALTY := -20
const SALVAGE_FRACTION := 0.05
const NEAREST_PORT_COUNT := 2

# --- Battle state (§4.11.1 seed, §4.11.11 instance shape) ------------------

var enemy_kind := "pirate"
var enemy_nation := ""
var day := 0
var gold := 0
var contact := Vector2i.ZERO
var weather := "calm"
## §4.2 battle-condition lock: the 8-token wind-FROM id, locked at battle
## start (§4.12.1 config key, default = `GameState.world["wind_dir"]`).
var wind_dir := "E"
## §4.2/§4.12.1: the decoded, reversal-applied contact-tile current
## (`{dir: <flow-TO token>, strength: 0..3}`), locked for the battle
## regardless of the world's `current_mode` (correction 1). strength 0 = none.
var current := {"dir": "", "strength": 0}
## §4.11.2 deployment variant: "" (the §4.11.2 table) or "tournament".
var deployment := ""
## Optional caller-supplied id (§4.12.2 `encounter_id`), "" when not given.
var encounter_id := ""
## One stream per battle (§4.11.1); duels draw from it (§4.11.6).
var rng := RandomNumberGenerator.new()

var _seed := 0
var _player_ships: Array = []
var _enemy_ships: Array = []
var _units: Array = []
var _order: Array = []
var _round := 1
var _current := -1
var _action_taken := false
var _moved_this_turn := false
var _started := false
var _over := false
var _result := RESULT_UNFINISHED
var _flagship_index := 0
## The fleet's captain canon card (§4.11.5), resolved once from the config's
## `captain_id` / `captain` field. Empty for legacy fleets (no card — the
## `5 + tier` fallback prices their ships) and when no field was handed over.
var _fleet_captain_card: Dictionary = {}

# Stall detection state (§4.11.9).
var _stall_rounds := 0
var _last_min_distance := -1
var _round_had_damage := false
var _round_had_boarding := false

# Outcome tallies (§4.12.2).
var _sunk_enemy: Array = []
var _sunk_enemy_by_player: Array = []
var _captured_enemy: Array = []
var _surrendered_enemy := 0
var _sunk_player: Array = []
var _lost_player: Array = []
var _player_last_cause := ""
## §4.8a side morale (Phase 9): one value per side, 0–100. The starts are
## fixed once in [method _init] — the player at config `player_morale` (or
## `GameState.morale`, read defensively), the AI at config `enemy_morale` (or
## `clamp(40 + flagship-captain courage, 20, 90)`, correction 6); the running
## values move through [method _morale_event], clamped after every event.
## Both ride the snapshot (§4.12.1).
var _player_morale := 70
var _enemy_morale := 50
var _player_morale_start := 70
var _enemy_morale_start := 50
var _log: Array = []


## §4.12.1 config keys: `player_ships`, `enemy_ships`, `enemy_kind`,
## `enemy_nation`, `day`, `gold`, `contact`, `weather`, optional `seed`,
## optional `encounter_id`, optional `deployment` ("" | "tournament",
## §4.11.2), optional `wind_dir` (the 8-token wind-FROM id; default =
## `GameState.world["wind_dir"]`), optional `current`
## (`{dir: <flow-TO token>, strength: 0..3}`; default = the decoded,
## reversal-applied contact-tile current regardless of the world's
## `current_mode`, correction 1), optional `player_stats` (the S21 seam) and
## the §4.8a optional morale starts `player_morale` / `enemy_morale` (int
## 0–100; the defaults are `GameState.morale` read defensively and
## `clamp(40 + flagship-captain courage, 20, 90)` — the W4 sandbox passes
## both from its fixture). All three battle conditions LOCK here and never
## change mid-battle (§4.2).
##
## Optional `rng`: a `RandomNumberGenerator` the caller has **already used** to
## compose the enemy fleet (the §4.11.1 "duel rolls draw from the same stream,
## after deployment and enemy composition" rule). When absent the sim seeds a
## fresh stream from `seed` (or the §4.11.1 formula).
func _init(config: Dictionary) -> void:
	_player_ships = _copy_ships(config.get("player_ships", []))
	_enemy_ships = _copy_ships(config.get("enemy_ships", []))
	enemy_kind = str(config.get("enemy_kind", "pirate"))
	enemy_nation = str(config.get("enemy_nation", ""))
	day = int(config.get("day", 0))
	gold = int(config.get("gold", 0))
	contact = to_cell(config.get("contact", Vector2i.ZERO))
	weather = str(config.get("weather", "calm"))
	deployment = str(config.get("deployment", ""))
	encounter_id = str(config.get("encounter_id", ""))
	wind_dir = str(config.get("wind_dir", _default_wind_dir()))
	if SailingSimLib.heading_index(wind_dir) < 0:
		wind_dir = "E"
	var current_config = config.get("current", null)
	current = (current_config as Dictionary).duplicate(true) \
		if current_config is Dictionary else _default_current()
	current["dir"] = str(current.get("dir", ""))
	current["strength"] = clampi(int(current.get("strength", 0)), 0, 3)
	_fleet_captain_card = _resolve_fleet_captain_card(config)
	# Phase-9 S21 seam (60-* §4.12.1): the optional `player_stats` override is
	# read HERE, once per constructed sim — present → the static holder carries
	# it; absent → the holder is cleared so `player_attribute` /
	# `player_effective_skill` / `player_duel_base` read GameState exactly as
	# before (the normal battle path never passes the key and stays
	# byte-identical). **Preserved through the W3 rewrite.**
	var stats_override = config.get("player_stats", null)
	_player_stats_override = (stats_override as Dictionary).duplicate(true) \
		if stats_override is Dictionary else {}
	# §4.8a side-morale starts (Phase 9): optional config keys first (the S21
	# seam — the sandbox hands both from its fixture), else the doc defaults.
	# Starts clamp into 0..100 once, so `morale_delta` (§4.12.2) is exactly
	# `clamp(end, 0, 100) − start` and the §4.12.4 writeback
	# `GameState.morale = clamp(old + delta, 0, 100)` cannot leave the band.
	_player_morale_start = clampi(
		int(config.get("player_morale", _default_player_morale())),
		MORALE_MIN, MORALE_MAX)
	_player_morale = _player_morale_start
	_enemy_morale_start = clampi(
		int(config.get("enemy_morale", _default_enemy_morale())),
		MORALE_MIN, MORALE_MAX)
	_enemy_morale = _enemy_morale_start
	var shared = config.get("rng", null)
	if shared is RandomNumberGenerator:
		rng = shared
		_seed = int(shared.seed)
	else:
		_seed = int(config.get("seed", battle_seed_formula(day, contact, gold, _player_ships.size())))
		rng.seed = _seed


## The 8-token wind-FROM default (§4.12.1): the world's locked direction.
static func _default_wind_dir() -> String:
	var world = GameState.get("world")
	if world is Dictionary:
		var value = (world as Dictionary).get("wind_dir", "E")
		if value is String and SailingSimLib.heading_index(value) >= 0:
			return value
	return "E"


## The decoded current default (§4.12.1, correction 1): the contact tile's
## current vector from `currents.png` (the reversal is `current_at`'s own
## lookup-time rule, §6.5), read regardless of the world's `current_mode`.
## No current (or an undecoded ocean — headless tools) ⇒ strength 0.
func _default_current() -> Dictionary:
	var decoded: Dictionary = OceanLayersLib.instance().current_at(
		contact, SailingSimLib.month_for(day))
	if decoded.is_empty():
		return {"dir": "", "strength": 0}
	return {
		"dir": str(decoded.get("dir", "")),
		"strength": clampi(int(decoded.get("strength", 0)), 0, 3),
	}


# --- §4.11.1 seed ----------------------------------------------------------

## `day × 1000003 + contact.x × 7919 + contact.y × 104729 + gold × 31 +
## fleet.size() × 17`, plain integer arithmetic (no `hash()`), so the value is
## identical on every platform and every caller can audit a battle.
static func battle_seed_formula(p_day: int, p_contact: Vector2i, p_gold: int, p_fleet_size: int) -> int:
	return p_day * 1000003 + p_contact.x * 7919 + p_contact.y * 104729 \
		+ p_gold * 31 + p_fleet_size * 17


## The seed actually in use (config `seed` override wins).
func seed_value() -> int:
	return _seed


# --- Person-model accessors (preserved through the W3 rewrite) --------------
#
# The player's numbers live on the Person model (`50-*` §4.2/§4.3). Those
# functions are consumed **defensively** so this file also parses and runs in
# a tree that predates the module rework: when `scripts/player/skills.gd`
# exists (loaded lazily, never preloaded) and defines the API, the module call
# wins; otherwise the raw player-block keys (`attributes` / `skills`) are read
# with 0 defaults. The in-post officer contribution inside `effective_skill`
# is why the flagship gunnery term MUST go through it (an in-post gunner feeds
# the cannon damage, `50-*` §4.5.3).

const SKILLS_LIB_PATH := "res://scripts/player/skills.gd"

static var _skills_lib = null
static var _skills_lib_probed := false
static var _captains_file_cache = null
static var _skill_gates_file_cache = null


static func _skills_script():
	if not _skills_lib_probed:
		_skills_lib_probed = true
		if FileAccess.file_exists(SKILLS_LIB_PATH):
			_skills_lib = load(SKILLS_LIB_PATH)
	return _skills_lib


## True when the script resource `lib` declares `method_name` (statics included).
static func _script_defines(lib, method_name: String) -> bool:
	if lib == null:
		return false
	for info in lib.get_script_method_list():
		if info is Dictionary and str(info.get("name", "")) == method_name:
			return true
	return false


# --- Phase-9 S21 seam (docs/60-COMBAT.md §4.12.1, §4.12.4) ------------------
#
# Optional `config.player_stats` override — `{attributes?: {…five…},
# skills?: {…}, equipment?: {weapon?, armor?}}` — the S21 naval-battle
# sandbox's injection point (decision 15, IMPLEMENT-Phase9 W2-C). [method
# _init] copies the key into the static holder below, or CLEARS the holder
# when the key is absent, so the three player reads re-scope per constructed
# sim and a normal battle (which never passes the key) stays byte-identical.
# Every accessor falls back to the GameState path PER KEY for anything the
# override does not carry.

static var _player_stats_override: Dictionary = {}


## Slot A's `Character.attribute(key)`; the raw `player.attributes[key]` with a
## 0 default stands in while the rework is unmerged. 0 without a loaded run.
static func player_attribute(key: String) -> int:
	# Phase-9 S21 seam (§4.12.1): per-key override first, GameState fallback.
	var override = _player_stats_override.get("attributes", null)
	if override is Dictionary and (override as Dictionary).has(key):
		return int((override as Dictionary)[key])
	var char_lib: Variant = CharacterLib
	if _script_defines(char_lib, "attribute"):
		return int(char_lib.attribute(key))
	var player: Dictionary = GameState.player
	if not (player is Dictionary):
		return 0
	var attributes = player.get("attributes", null)
	if attributes is Dictionary:
		return int(attributes.get(key, 0))
	return 0


## Slot A's `Skills.effective_skill(key)` — the player's skill plus the ONE
## in-post officer's contribution (`50-*` §4.5.3). The raw `player.skills[key]`
## stands in while the module is unmerged (no officer term on that path).
static func player_effective_skill(key: String) -> int:
	# Phase-9 S21 seam (§4.12.1): per-key override first, GameState fallback.
	var override = _player_stats_override.get("skills", null)
	if override is Dictionary and (override as Dictionary).has(key):
		return int((override as Dictionary)[key])
	var lib = _skills_script()
	if _script_defines(lib, "effective_skill"):
		return int(lib.effective_skill(key))
	var player: Dictionary = GameState.player
	if not (player is Dictionary):
		return 0
	var skills = player.get("skills", null)
	if skills is Dictionary:
		return int(skills.get(key, 0))
	return 0


# --- Captain canon (docs/60-* §4.11.5; IMPLEMENT-Phase8 §2.4) — preserved ---

static var _captains_test_doubles: Dictionary = {}


## The canon card for `captain_id`, or {} when absent.
static func captain_canon_card(captain_id: String) -> Dictionary:
	if captain_id.is_empty():
		return {}
	if _captains_test_doubles.has(captain_id):
		return (_captains_test_doubles[captain_id] as Dictionary).duplicate(true)
	var indexed = DataLoader.get("captains")
	if not (indexed is Dictionary) or (indexed as Dictionary).is_empty():
		indexed = _captains_file_index()
	if not (indexed is Dictionary):
		return {}
	var card = (indexed as Dictionary).get(captain_id, null)
	return card.duplicate(true) if card is Dictionary else {}


static func _captains_file_index() -> Dictionary:
	if _captains_file_cache is Dictionary:
		return _captains_file_cache
	var out: Dictionary = {}
	var file := FileAccess.open("res://data/captains.json", FileAccess.READ)
	if file != null:
		var parsed = JSON.parse_string(file.get_as_text())
		var cards = parsed.get("captains", []) if parsed is Dictionary else []
		if cards is Array:
			for card in cards:
				if card is Dictionary and not str(card.get("id", "")).is_empty():
					out[str(card["id"])] = card
	_captains_file_cache = out
	return out


## §4.11.5 card duel rating: `swordplay + floor(courage / 20)`.
static func card_duel_rating(card: Dictionary) -> int:
	var skills: Dictionary = card.get("skills", {}) if card.get("skills", {}) is Dictionary else {}
	var attributes: Dictionary = card.get("attributes", {}) if card.get("attributes", {}) is Dictionary else {}
	return int(skills.get("swordplay", 0)) \
		+ int(floor(float(int(attributes.get("courage", 0))) / DUEL_COURAGE_DIVISOR))


## §4.11.5 card cannon rating: the duel rating `+ floor(gunnery / 25)`.
static func card_cannon_rating(card: Dictionary) -> int:
	var skills: Dictionary = card.get("skills", {}) if card.get("skills", {}) is Dictionary else {}
	return card_duel_rating(card) \
		+ int(floor(float(int(skills.get("gunnery", 0))) / CARD_CANNON_DIVISOR))


## The card's charisma for the §4.11.6 defender bonus (0 without a card).
static func card_charisma(card: Dictionary) -> int:
	var attributes: Dictionary = card.get("attributes", {}) if card.get("attributes", {}) is Dictionary else {}
	return int(attributes.get("charisma", 0))


## The card's courage for the §4.7 surrender roll (0 without a card).
static func card_courage(card: Dictionary) -> int:
	var attributes: Dictionary = card.get("attributes", {}) if card.get("attributes", {}) is Dictionary else {}
	return int(attributes.get("courage", 0))


## Resolves the config's fleet-captain field into a canon card (both save
## shapes; the legacy pool shape yields {} — the fallbacks price the fleet).
static func _resolve_fleet_captain_card(config: Dictionary) -> Dictionary:
	var captain_id := str(config.get("captain_id", ""))
	if captain_id.is_empty():
		var captain = config.get("captain", null)
		if captain is String:
			captain_id = captain
		elif captain is Dictionary:
			captain_id = str(captain.get("id", ""))
	return captain_canon_card(captain_id)


## The skill_gates threshold for `feature_id`, or `fallback` when the gates
## data is unreadable (the doc-pinned value stands in; never invented).
static func skill_gate_threshold(feature_id: String, fallback: int) -> int:
	var rows = DataLoader.get("skill_gates")
	if rows == null or (rows is Dictionary and (rows as Dictionary).is_empty()):
		rows = _skill_gates_file_index()
	return _gate_threshold(rows, feature_id, fallback)


static func _gate_threshold(rows, feature_id: String, fallback: int) -> int:
	if rows is Array:
		for row in rows:
			if row is Dictionary and str(row.get("feature_id", "")) == feature_id:
				return int(row.get("threshold", fallback))
		return fallback
	if rows is Dictionary:
		var table: Dictionary = rows
		if not table.has(feature_id) and table.has("skill_gates"):
			var inner = table.get("skill_gates")
			return _gate_threshold(inner, feature_id, fallback) if inner is Array else fallback
		var row = table.get(feature_id, null)
		if row is Dictionary:
			return int(row.get("threshold", fallback))
		if row is int or row is float:
			return int(row)
	return fallback


static func _skill_gates_file_index():
	if _skill_gates_file_cache != null:
		return _skill_gates_file_cache
	var parsed = null
	var file := FileAccess.open("res://data/skill_gates.json", FileAccess.READ)
	if file != null:
		parsed = JSON.parse_string(file.get_as_text())
	_skill_gates_file_cache = parsed.get("skill_gates", []) if parsed is Dictionary else []
	return _skill_gates_file_cache


## §4.4b chain-shot gate: gunnery ≥ the `shot.chain` threshold (25 in data).
static func chain_shot_gate() -> int:
	return skill_gate_threshold("shot.chain", DEFAULT_CHAIN_GATE)


## §4.4b armor-piercing gate: gunnery ≥ the `shot.armor_piercing` threshold (50).
static func armor_piercing_gate() -> int:
	return skill_gate_threshold("shot.armor_piercing", DEFAULT_ARMOR_PIERCING_GATE)


## §4.4b gate read against the PLAYER's effective gunnery — the S10 selector's
## disable-state read. The volley path itself gates per-unit through
## [method gunnery_of] (the §4.4a gunnery source), not here.
static func shot_unlocked(shot_type: String) -> bool:
	match shot_type:
		CHAIN_SHOT:
			return player_effective_skill("gunnery") >= chain_shot_gate()
		ARMOR_PIERCING_SHOT:
			return player_effective_skill("gunnery") >= armor_piercing_gate()
		_:
			return true


# --- Lifecycle (§4.12.1) ---------------------------------------------------

func start() -> void:
	if _started:
		return
	_started = true
	_units.clear()
	var tournament := deployment == TOURNAMENT_DEPLOYMENT
	for index in _player_ships.size():
		_units.append(_make_unit(SIDE_PLAYER, index, _player_ships[index],
			_deploy_cell(SIDE_PLAYER, index), tournament))
	for index in _enemy_ships.size():
		_units.append(_make_unit(SIDE_ENEMY, index, _enemy_ships[index],
			_deploy_cell(SIDE_ENEMY, index), tournament))
	_price_captain_ratings()
	_price_broadside_split()
	_price_gunnery()
	_round = 1
	_current = -1
	_action_taken = false
	_moved_this_turn = false
	_stall_rounds = 0
	_round_had_damage = false
	_round_had_boarding = false
	_last_min_distance = _min_pair_distance()
	_flagship_index = _lowest_living_index(SIDE_PLAYER)
	_check_over()
	if _over:
		return
	_build_order()  # ONCE at battle start (§4.3/§4.11.4) — never re-sorted.
	_advance()


func round_number() -> int:
	return _round


func is_over() -> bool:
	return _over


func current_unit() -> Dictionary:
	if _over or _current < 0 or _current >= _order.size():
		return {}
	var unit = _order[_current]
	if not (unit is Dictionary) or not bool(unit.get("alive", false)):
		return {}
	return unit


## True when `unit` is the ship whose turn it is (§4.3 "each round, every
## living ship acts once in initiative order"). A not-yet-started battle has
## no cursor, so configuration-time calls are allowed and only the once-per-
## turn budgets (movement, action) are enforced.
func is_acting(unit: Dictionary) -> bool:
	if not _started:
		return true
	var acting := current_unit()
	return not acting.is_empty() and is_same(acting, unit)


## Ends the acting unit's turn; advances to the next living unit in initiative
## order, rolling into the next round (§4.11.4). Dead units skip their slot.
## The chain-shot cap debuff counts the turn that just ended (§4.3a: the
## debuff applies "while speed_debuff_turns > 0" — it must cover the fired-
## upon ship's next TWO turns for `+2`, so it decrements at turn END).
func end_turn() -> void:
	if _over:
		return
	var acting := current_unit()
	if not acting.is_empty() and int(acting.get("speed_debuff_turns", 0)) > 0:
		acting["speed_debuff_turns"] = int(acting["speed_debuff_turns"]) - 1
	_action_taken = false
	_moved_this_turn = false
	_check_over()
	if _over:
		return
	_advance()


## §4.12.2 outcome block; `{}` until [method is_over] (§4.12.1 pin).
##
## `captured_enemy` is the list the application seam (§4.12.3, task C) takes
## into the fleet. §4.11.7 resolves an AI surrender "exactly as a duel win
## (capture/loot)", so a surrendered hull appears **both** in that list and in
## the `surrendered_enemy` counter — the counter is a sub-tally for the
## after-action dialog's wording, never an addition to the list.
func outcome() -> Dictionary:
	if not _over:
		return {}
	var neutralized := _sunk_enemy.size() + _captured_enemy.size()
	var rounds_lasted := maxi(_round, 1)
	# §4.10 "Retreating forfeits nothing but costs no XP": a retreat awards
	# nothing, while everything already earned (salvage, navy rep) stands.
	var xp := 0 if _result == RESULT_RETREAT \
		else neutralized * XP_PER_ENEMY_NEUTRALIZED + rounds_lasted * XP_PER_ROUND
	return {
		"result": _result,
		"rounds": rounds_lasted,
		"kind": enemy_kind,
		"nation_id": enemy_nation,
		"encounter_id": encounter_id,
		"contact": {"x": contact.x, "y": contact.y},
		"sunk_enemy": _sunk_enemy.duplicate(),
		"captured_enemy": _captured_enemy.duplicate(true),
		"surrendered_enemy": _surrendered_enemy,
		"sunk_player": _sunk_player.duplicate(),
		"lost_player": _lost_player.duplicate(true),
		"salvage_gold": _salvage_gold(),
		"xp": xp,
		"rep_deltas": _rep_deltas(),
		"morale_delta": morale_delta_for(SIDE_PLAYER),
		"cargo_overflow_lost": 0,
	}


# --- Unit enumeration (S10 / AiFleet seam) --------------------------------

## Every unit dict, living or not (killed units keep their last state so the
## screen can animate a sinking token). Never `null` entries.
func units() -> Array:
	return _units.duplicate()


## Living units of `side`, in fleet-index order.
func living_units(side: String) -> Array:
	var out: Array = []
	for unit in _units:
		if unit.side == side and bool(unit.get("alive", false)):
			out.append(unit)
	out.sort_custom(func(a, b) -> bool: return int(a.index) < int(b.index))
	return out


# --- Grid / movement (docs/60-* §4.2, §4.3a, §4.11.4) ----------------------

func unit_cell(unit: Dictionary) -> Vector2i:
	if unit.has("pos"):
		return to_cell(unit["pos"])
	# Compat read for stale fixtures that still author `cell`.
	return to_cell(unit.get("cell", NO_CELL))


## The per-hull Phase-9 movement fields (W2 `data/ship_types.json`):
## `battle_max_speed` (the Chebyshev velocity box), `battle_accel`
## (the magnitude-delta budget), `battle_turn_rate` (the heading-bucket
## turn budget in degrees).
func battle_max_speed(unit: Dictionary) -> int:
	return maxi(1, int(_ship_type_of(unit).get("battle_max_speed", 2)))


func battle_accel(unit: Dictionary) -> int:
	return maxi(1, int(_ship_type_of(unit).get("battle_accel", 1)))


func battle_turn_rate(unit: Dictionary) -> int:
	return maxi(45, int(_ship_type_of(unit).get("battle_turn_rate", 45)))


func _ship_type_of(unit: Dictionary) -> Dictionary:
	var ship: Dictionary = unit.get("ship", {})
	if not (ship is Dictionary):
		return {}
	return DataLoader.get_ship_type(str(ship.get("ship_type_id", "")))


## The ship's class (§4.3a cap tables; `sail` as the defensive fallback).
func ship_class_of(unit: Dictionary) -> String:
	return str(_ship_type_of(unit).get("class", "sail"))


## §4.11.4 initiative key, built ONCE: descending
## `ShipType.speed + sail_speed_delta` (correction 2, §4.11.12).
func initiative_key(unit: Dictionary) -> int:
	var ship: Dictionary = unit.get("ship", {})
	if not (ship is Dictionary):
		return 0
	var ship_type: Dictionary = DataLoader.get_ship_type(str(ship.get("ship_type_id", "")))
	return int(ship_type.get("speed", 0)) + equipment_modifier(ship, "sail", "speed")


## §4.3a: every integer velocity in the Chebyshev box `|vx|, |vy| ≤
## battle_max_speed` satisfying, in the §4.11.4 order: bucket angle to the old
## velocity ≤ `battle_turn_rate` (skipped from standstill — any direction is
## legal, magnitude ≤ accel), magnitude delta ≤ `battle_accel`, `‖vel‖ ≤
## cap_eff`. `vel = (0,0)` (hold position) reads only the magnitude-delta
## constraint. Enumerated in **(y, x) lexicographic order** — the enumeration
## order is the deterministic tie-break everywhere (§4.11.8, decision 13).
func legal_velocities(unit: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not (unit is Dictionary) or not bool(unit.get("alive", false)):
		return out
	var max_speed := battle_max_speed(unit)
	var accel := float(battle_accel(unit))
	var cap := float(cap_eff(unit))
	var old_vel: Vector2i = unit.get("vel", Vector2i.ZERO)
	var old_heading := int(unit.get("heading8", HEADING_EAST))
	var old_mag := vel_length(old_vel)
	for vy in range(-max_speed, max_speed + 1):
		for vx in range(-max_speed, max_speed + 1):
			var vel := Vector2i(vx, vy)
			var mag := vel_length(Vector2i(vx, vy))
			# Hold position: only the magnitude-delta constraint reads.
			if vel == Vector2i.ZERO:
				if absf(mag - old_mag) <= accel:
					out.append(vel)
				continue
			# Heading-bucket angle (skipped from standstill, §4.3a).
			if old_vel != Vector2i.ZERO:
				var steps := bucket_distance(heading8_of(vel), old_heading)
				if steps * 45 > battle_turn_rate(unit):
					continue
			if absf(mag - old_mag) > accel:
				continue
			if mag > cap:
				continue
			out.append(vel)
	return out


## §4.12.1 `apply_velocity`: validate (the §4.11.4 order — angle, magnitude
## delta; the CAP leg clamps instead of rejecting) → clamp the magnitude
## overshoot along the chosen direction (component floor) → integrate as the
## Bresenham sweep (§4.3a: the first occupied cell stops the ship —
## enemy-occupied ⇒ the §4.5 sweep ram, friend/out-of-bounds ⇒ stop at the
## PRIOR cell, zero damage). `vel = (0,0)` keeps the last heading. Returns
## false (state untouched) on any illegal pick or once the turn's movement is
## spent — movement happens exactly once per turn (§4.3).
func apply_velocity(unit: Dictionary, vel: Vector2i) -> bool:
	if _over or _moved_this_turn:
		return false
	if not (unit is Dictionary) or not bool(unit.get("alive", false)):
		return false
	if not is_acting(unit):
		return false
	if absi(vel.x) > battle_max_speed(unit) or absi(vel.y) > battle_max_speed(unit):
		return false
	var old_vel: Vector2i = unit.get("vel", Vector2i.ZERO)
	var old_mag := vel_length(old_vel)
	# ① heading-bucket angle (skipped from standstill and for a (0,0) pick).
	if vel != Vector2i.ZERO and old_vel != Vector2i.ZERO:
		var steps := bucket_distance(heading8_of(vel), int(unit.get("heading8", HEADING_EAST)))
		if steps * 45 > battle_turn_rate(unit):
			return false
	# ② magnitude delta.
	var mag := vel_length(vel)
	if absf(mag - old_mag) > float(battle_accel(unit)):
		return false
	# ③ cap — the overshoot clamps along the chosen direction (component
	#    floor, §4.3a).
	var applied := vel
	if mag > float(cap_eff(unit)) and mag > 0.0:
		var scale := float(cap_eff(unit)) / mag
		applied = Vector2i(int(floor(float(vel.x) * scale)),
			int(floor(float(vel.y) * scale)))
	_moved_this_turn = true
	if applied != Vector2i.ZERO:
		_sweep(unit, applied)
		# The committed velocity sets the heading (§4.3a).
		unit["heading8"] = heading8_of(applied)
	# The new velocity IS the unit's state (§4.3a) — a (0,0) pick keeps the
	# last heading and holds position.
	unit["vel"] = applied
	return true


## §4.3a `cap_eff` (decision 2, corrections 1–3):
## `clamp(floor(battle_max_speed × wind_factor(weather, class) ×
## direction_factor(heading8, wind_dir, class)) ± current_mod − debuff,
## 0, battle_max_speed) + sail_speed_delta` — the current modifier rides
## inside the clamp, the chain-shot debuff floors at 1 (`max(1, base − 1)`),
## and the sail delta applies after the clamp, unclamped back
## (§4.11.12, correction 2). `heading8` is the ship's CURRENT heading.
func cap_eff(unit: Dictionary) -> int:
	var max_speed := battle_max_speed(unit)
	var ship_class := ship_class_of(unit)
	var wind := SailingSimLib.wind_factor(weather, ship_class)
	var direction := _direction_factor(unit)
	var mod := _current_mod(unit)
	var cap := clampi(int(floor(float(max_speed) * wind * direction)) + mod,
		0, max_speed)
	if int(unit.get("speed_debuff_turns", 0)) > 0:
		cap = maxi(1, cap - 1)
	var ship: Dictionary = unit.get("ship", {})
	var sail_delta := 0
	if ship is Dictionary:
		sail_delta = equipment_modifier(ship, "sail", "speed")
	return cap + sail_delta


## §4.3a direction_factor: identity 1.0 in calm weather (the world rule,
## `20-*` §4.7.1); otherwise the `20-*` §4.4 table read at the bucket angle
## between the ship's heading8 and the locked wind-FROM direction, the
## ship's own class column, `sail` as the fallback for an unknown class.
func _direction_factor(unit: Dictionary) -> float:
	if weather == "calm":
		return 1.0
	var bucket := _heading_wind_bucket(unit)
	if bucket < 0:
		return 1.0
	var table: Dictionary = SailingSimLib.DIRECTION_FACTORS.get(bucket, {})
	var ship_class := ship_class_of(unit)
	return float(table.get(ship_class, table.get("sail", 1.0)))


## The bucket angle (degrees) between `unit`'s heading8 and the wind-FROM
## direction; −1 when either id is unknown.
func _heading_wind_bucket(unit: Dictionary) -> int:
	var token := _heading_token(int(unit.get("heading8", HEADING_EAST)))
	return SailingSimLib.angle_between_dirs(token, wind_dir)


## The bucket angle (degrees) between `unit`'s heading8 and the locked
## current's flow-TO direction; −1 when the token is unknown/absent.
func _heading_current_bucket(unit: Dictionary) -> int:
	var flow := str(current.get("dir", ""))
	if flow.is_empty() or SailingSimLib.heading_index(flow) < 0:
		return -1
	var token := _heading_token(int(unit.get("heading8", HEADING_EAST)))
	return SailingSimLib.angle_between_dirs(token, flow)


## §4.3a current modifier (correction 1): relative bucket between the ship's
## heading8 and the current's flow direction — bucket ∈ {0°, 45°} with
## strength ≥ 2 → +1; bucket ∈ {135°, 180°} with strength = 3 → −1; strength
## 0 (no current) never modifies.
func _current_mod(unit: Dictionary) -> int:
	var strength := int(current.get("strength", 0))
	if strength <= 0:
		return 0
	var bucket := _heading_current_bucket(unit)
	if bucket < 0:
		return 0
	if bucket in [0, 45] and strength >= 2:
		return 1
	if bucket in [135, 180] and strength == 3:
		return -1
	return 0


static func _heading_token(heading8: int) -> String:
	var index := posmod(heading8, HEADING_TOKENS.size())
	return HEADING_TOKENS[index]


## §4.3a: `heading8` derives from `vel` via integer dot comparisons against
## the eight compass rays (decision 1 — never `atan2`). Integer nearest-ray:
## maximize cos² = dot²/|ray|² over the rays with a positive dot; an axis ray
## scores 2·dot², a diagonal dot² (|diag|² = 2). Ties are impossible — a
## 22.5° boundary has an irrational slope, so no nonzero integer vector
## equidistances two rays. (0,0) has no heading: callers keep the last one.
static func heading8_of(vel: Vector2i) -> int:
	if vel == Vector2i.ZERO:
		return HEADING_EAST
	var best := HEADING_EAST
	var best_score := -1
	for bucket in HEADING_RAYS.size():
		var ray := HEADING_RAYS[bucket]
		var dot := vel.x * ray.x + vel.y * ray.y
		if dot <= 0:
			continue
		var axis := ray.x == 0 or ray.y == 0
		var score := 2 * dot * dot if axis else dot * dot
		if score > best_score:
			best_score = score
			best = bucket
	return best


## The heading-bucket distance between two buckets in 45° steps (0..4).
static func bucket_distance(a: int, b: int) -> int:
	var diff := absi(posmod(a, 8) - posmod(b, 8)) % 8
	return mini(diff, 8 - diff)


## §4.3a sweep integration: the Bresenham walk cell by cell along `applied`;
## the FIRST occupied cell stops the ship — enemy-occupied ⇒ the §4.5 sweep
## ram, friend-occupied or out-of-bounds ⇒ stop at the PRIOR cell (zero
## damage, no partial entry; §4.11.4 "a ship may never enter or pass through
## an occupied cell").
func _sweep(unit: Dictionary, applied: Vector2i) -> void:
	var target: Vector2i = unit_cell(unit) + applied
	var prior := unit_cell(unit)
	for cell in _bresenham_cells(prior, target):
		if not in_grid(cell):
			unit["pos"] = prior
			return
		var occupant := _living_unit_at(cell, unit)
		if not occupant.is_empty():
			unit["pos"] = prior
			if str(occupant.get("side", "")) != str(unit.get("side", "")):
				# Sweep ram (§4.5): the impact speed is the APPLIED velocity.
				_resolve_ram(unit, occupant, vel_length(applied))
			return
		unit["pos"] = cell
		prior = cell


## The Bresenham cells strictly after `from`, up to and including `to`.
static func _bresenham_cells(from: Vector2i, to: Vector2i) -> Array:
	var cells: Array = []
	var dx := absi(to.x - from.x)
	var dy := -absi(to.y - from.y)
	var sx := 1 if to.x >= from.x else -1
	var sy := 1 if to.y >= from.y else -1
	var err := dx + dy
	var cursor := from
	while cursor != to:
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			cursor.x += sx
		if e2 <= dx:
			err += dx
			cursor.y += sy
		cells.append(Vector2i(cursor.x, cursor.y))
	return cells


## The living unit on `cell` other than `exclude` ({} when free).
func _living_unit_at(cell: Vector2i, exclude) -> Dictionary:
	for other in _units:
		if is_same(other, exclude) or not bool(other.get("alive", false)):
			continue
		if unit_cell(other) == cell:
			return other
	return {}


# --- Cannon (docs/60-* §4.4, §4.4a, §4.4b, §4.11.5) ------------------------

## The per-unit gunnery source (§4.4a/§4.11.5, priced once at battle start —
## [method _price_gunnery]): the player flagship's `effective_gunnery` (the
## §4.4 term, through `player_effective_skill` so an in-post gunner feeds it),
## a captain-card ship's card `skills.gunnery`, a legacy fleet's
## `10 + 10 × tier` fallback.
func gunnery_of(unit: Dictionary) -> int:
	return int(unit.get("gunnery", 0))


## The side's cannon count (`cannons_port` / `cannons_starboard`, priced once
## at battle start — §4.4 broadside split, decision 3).
func side_cannons(unit: Dictionary, side: String) -> int:
	var key := "cannons_port" if side == BROADSIDE_PORT else "cannons_starboard"
	return maxi(0, int(unit.get(key, 0)))


## §4.4: true when the NAMED side (`"port"` / `"starboard"`) can fire at
## `target`: the side's arc contains the target (bearing bucket relative to
## the ATTACKER's heading8 ∈ {45°,90°,135°} port / {225°,270°,315°}
## starboard — a dead-ahead/dead-astern target sits in neither arc), Chebyshev
## range 1..3, the side loaded (`round ≥ reload_side`) and the side has ≥ 1
## cannon. `side == ""` (compat read) asks whether EITHER side can.
func can_cannon(unit, target, side: String = "") -> bool:
	if not (unit is Dictionary) or not (target is Dictionary):
		return false
	if not bool(unit.get("alive", false)) or not bool(target.get("alive", false)):
		return false
	if unit.side == target.side:
		return false
	var distance := _chebyshev(unit_cell(unit), unit_cell(target))
	if distance < CANNON_RANGE_MIN or distance > CANNON_RANGE_MAX:
		return false
	if side == BROADSIDE_PORT or side == BROADSIDE_STARBOARD:
		return _side_can_fire(unit, target, side, distance)
	return _side_can_fire(unit, target, BROADSIDE_PORT, distance) \
		or _side_can_fire(unit, target, BROADSIDE_STARBOARD, distance)


func _side_can_fire(unit: Dictionary, target: Dictionary, side: String,
		distance: int) -> bool:
	if _round < int(unit.get(_reload_key(side), 1)):
		return false
	if side_cannons(unit, side) < 1:
		return false
	var bearing := heading8_of(unit_cell(target) - unit_cell(unit))
	# §4.4 arcs are SIGNED counterclockwise steps off the attacker's heading8
	# (port {1,2,3} = 45°/90°/135°, starboard {5,6,7} = 225°/270°/315°) — the
	# unsigned `bucket_distance` (0..4) can never reach the starboard set and
	# answers non-axial bearings with the wrong side (W3-D bounce-back fix).
	var steps := (bearing - int(unit.get("heading8", HEADING_EAST)) + 8) % 8
	var arc := ARC_PORT_STEPS if side == BROADSIDE_PORT else ARC_STARBOARD_STEPS
	return steps in arc


func _reload_key(side: String) -> String:
	return "reload_port" if side == BROADSIDE_PORT else "reload_starboard"


## §4.4 flagship gunnery term alone: `floor(effective_gunnery / 25)` — the
## static form (UI previews, tests) of the flagship branch of
## [method cannon_bonus]. Goes through `player_effective_skill`, so an
## in-post gunner officer feeds the damage (`50-*` §4.5.3).
static func cannon_bonus_flagship() -> int:
	return int(floor(float(player_effective_skill("gunnery")) / GUNNERY_BONUS_DIVISOR))


## §4.11.5 `bonus`: `floor(effective_gunnery / 25)` for the player flagship
## and `floor(combat_rating / 10)` for every captain-card ship.
func cannon_bonus(unit: Dictionary) -> int:
	if unit.side == SIDE_PLAYER and int(unit.index) == _flagship_index:
		return cannon_bonus_flagship()
	return int(floor(float(combat_rating(unit)) / COMBAT_BONUS_DIVISOR))


## §4.11.5 combat rating (Phase 8): the ship's captain-card **cannon rating**,
## priced once at battle start and stored on the unit. The player flagship is
## not a captain-card ship — its §4.11.5 bonus is the §4.4 gunnery term.
func combat_rating(unit: Dictionary) -> int:
	if not (unit is Dictionary):
		return 0
	if unit.side == SIDE_PLAYER and int(unit.index) == _flagship_index:
		return 0
	return int(unit.get("cannon_rating", 0))


## §4.4a reload turns: `clamp(3 − floor(gunnery / 50), 1, 3) +
## (crew_ratio < 0.5 ? 1 : 0)`, `crew_ratio = crew / crew_min`.
func reload_turns_of(unit: Dictionary) -> int:
	var turns := clampi(RELOAD_BASE_TURNS
		- int(floor(float(gunnery_of(unit)) / float(RELOAD_GUNNERY_DIVISOR))),
		RELOAD_MIN_TURNS, RELOAD_BASE_TURNS)
	var ship: Dictionary = unit.get("ship", {})
	var crew_min := int(DataLoader.get_ship_type(str(ship.get("ship_type_id", "")))
		.get("crew_min", 0)) if ship is Dictionary else 0
	var ratio := float(unit.get("crew", 0)) / float(maxi(crew_min, 1))
	if ratio < RELOAD_LOW_CREW_RATIO:
		turns += RELOAD_LOW_CREW_BONUS
	return turns


## §4.4 damage preview for a named side (the stack WITHOUT the shot term —
## round shot). Static-only inputs, so it answers for unstarted sims too.
func cannon_damage(unit: Dictionary, target: Dictionary, side: String) -> int:
	var distance := _chebyshev(unit_cell(unit), unit_cell(target))
	var factor := float(CANNON_RANGE_FACTOR.get(distance, 0.0))
	var base := float(side_cannons(unit, side)) * CANNON_BASE_MULTIPLIER * factor
	base += float(cannon_bonus(unit))
	var product := base * _weather_damage_mult() * 1.0
	if _is_rake_on(target, unit):
		product *= RAKE_MULTIPLIER
	return int(floor(product))


## The §4.2 weather damage multiplier: storm ×0.75, strong ×0.9, else ×1.0.
func _weather_damage_mult() -> float:
	if weather == STORM_WEATHER:
		return STORM_CANNON_MULTIPLIER
	if weather == STRONG_WEATHER:
		return STRONG_CANNON_MULTIPLIER
	return 1.0


## §4.4 rake: true when the bearing bucket from TARGET to ATTACKER, relative
## to the TARGET's own heading8, ∈ {0°, 180°} — the shot runs the target's
## deck line.
func _is_rake_on(target: Dictionary, attacker: Dictionary) -> bool:
	var bearing := heading8_of(unit_cell(attacker) - unit_cell(target))
	var steps := bucket_distance(bearing, int(target.get("heading8", HEADING_EAST)))
	return steps == 0 or steps == 4


## §4.4b deterministic AI shot rule (T2/T3 shared; evaluated in order; always
## OUTSIDE any T3 enumeration — decisions 4/13):
##   1. target `floor(‖vel‖) ≥ 2` AND its current velocity strictly increases
##      its Chebyshev distance to the attacker → chain (gunnery ≥ 25);
##   2. (orthogonally adjacent or Chebyshev ≤ 2) AND own crew + duel rating >
##      target crew + target duel rating → grape — which is range 1 only, so
##      beyond range 1 the rule falls through (grape could not resolve);
##   3. the target is a player-side ship whose `equipment.armor` slot is
##      non-empty → armor-piercing (gunnery ≥ 50);
##   4. otherwise → round.
func ai_shot_type(attacker: Dictionary, target: Dictionary) -> String:
	var distance := _chebyshev(unit_cell(attacker), unit_cell(target))
	# 1. chain on a fleeing fast target.
	if _vel_floor(target) >= 2:
		var projected: Vector2i = unit_cell(target) + (target.get("vel", Vector2i.ZERO) as Vector2i)
		var current_distance := _chebyshev(unit_cell(attacker), unit_cell(target))
		if _chebyshev(unit_cell(attacker), projected) > current_distance \
				and gunnery_of(attacker) >= chain_shot_gate():
			return CHAIN_SHOT
	# 2. grape in the close-quarters window.
	var own_rating := int(attacker.get("crew", 0)) + int(attacker.get("captain_rating", 0))
	var target_rating := int(target.get("crew", 0)) + int(target.get("captain_rating", 0))
	if distance <= 2 and own_rating > target_rating:
		if distance == CANNON_RANGE_MIN:
			return GRAPE_SHOT
		# Grape is range 1 only (§4.4b) — beyond it the volley could not
		# resolve, so the rule continues down the list.
	# 3. armor-piercing into a plated player ship.
	if str(target.get("side", "")) == SIDE_PLAYER:
		var ship: Dictionary = target.get("ship", {})
		var equipment = ship.get("equipment", {}) if ship is Dictionary else {}
		if equipment is Dictionary and not str(equipment.get("armor", "")).is_empty() \
				and gunnery_of(attacker) >= armor_piercing_gate():
			return ARMOR_PIERCING_SHOT
	return ROUND_SHOT


## §4.4 broadside volley: `side` ∈ "port"/"starboard" — `""` = round shot from
## the §4.11.8 pick (a rake volley beats a non-rake, then the side with more
## cannons, tie → port) — and `shot_type` per §4.4b (default round). The
## multipliers multiply and exactly ONE
## floor lands at the end, after the weather term: damage =
## `floor((side_cannons × 2 × range_factor + bonus) × weather × shot × rake)`.
## After the volley the side reloads: `reload_side = round + reload_turns`
## (§4.4a). Grape swaps the hull damage for its §4.4b halved pair and the
## crew kill IS the volley's casualty term (§4.11.5).
func cannon(unit: Dictionary, target: Dictionary, side: String = "",
		shot_type: String = ROUND_SHOT) -> Dictionary:
	var result := {"ok": false, "damage": 0, "sunk": false, "log": {}}
	if _over or _action_taken or not is_acting(unit):
		return result
	if not (target is Dictionary) or target.is_empty() or not can_cannon(unit, target, side):
		return result
	var distance := _chebyshev(unit_cell(unit), unit_cell(target))
	if shot_type == GRAPE_SHOT and distance != CANNON_RANGE_MIN:
		# §4.4b: grape is range 1 ONLY — not a lock, a range gate.
		result["range"] = distance
		result["shot"] = GRAPE_SHOT
		return result
	if (shot_type == CHAIN_SHOT or shot_type == ARMOR_PIERCING_SHOT) \
			and gunnery_of(unit) < (chain_shot_gate() if shot_type == CHAIN_SHOT
				else armor_piercing_gate()):
		result["locked"] = true
		result["gate"] = chain_shot_gate() if shot_type == CHAIN_SHOT \
			else armor_piercing_gate()
		result["shot"] = shot_type
		return result
	var resolved_side := side
	if resolved_side != BROADSIDE_PORT and resolved_side != BROADSIDE_STARBOARD:
		resolved_side = _pick_broadside_side(unit, target)
		if resolved_side.is_empty():
			return result
	_action_taken = true
	result["ok"] = true
	# The §4.4 stack — one floor at the end, after the weather term.
	var factor := float(CANNON_RANGE_FACTOR.get(distance, 0.0))
	var base := float(side_cannons(unit, resolved_side)) * CANNON_BASE_MULTIPLIER * factor
	base += float(cannon_bonus(unit))
	var weather_mult := _weather_damage_mult()
	var rake := RAKE_MULTIPLIER if _is_rake_on(target, unit) else 1.0
	var round_damage := int(floor(base * weather_mult * rake))
	var damage := round_damage
	var crew_kill := 0
	match shot_type:
		CHAIN_SHOT:
			damage = int(floor(base * weather_mult * CHAIN_DAMAGE_MULTIPLIER * rake))
		ARMOR_PIERCING_SHOT:
			damage = int(floor(base * weather_mult * ARMOR_PIERCING_DAMAGE_MULTIPLIER * rake))
		GRAPE_SHOT:
			damage = int(floor(float(round_damage) * GRAPE_HALF))
			# §4.4b/§4.11.5: the grape kill IS the volley's casualty term —
			# it replaces the /20 (and /10 rake) divisor rule for that volley.
			crew_kill = int(floor(float(round_damage) * GRAPE_HALF))
		_:
			shot_type = ROUND_SHOT
	# §4.11.5 crew casualties: rake /10, standard /20. Clamped at 0.
	if shot_type != GRAPE_SHOT:
		crew_kill = damage / (CREW_CASUALTY_RAKE_DIVISOR if rake > 1.0
			else CREW_CASUALTY_DIVISOR)
	crew_kill = maxi(crew_kill, 0)
	# The named side reloads (§4.4a).
	unit[_reload_key(resolved_side)] = _round + reload_turns_of(unit)
	result["side"] = resolved_side
	result["shot"] = shot_type
	result["rake"] = rake > 1.0
	result["crew_kill"] = crew_kill
	result["damage"] = damage
	var ship: Dictionary = target["ship"]
	ship["durability"] = int(ship.get("durability", 0)) - damage
	var crew := maxi(int(target.get("crew", 0)) - crew_kill, 0)
	target["crew"] = crew
	var sunk := int(ship["durability"]) <= 0
	if sunk:
		_sink(target, str(unit.get("side", "")), "cannon")
	elif shot_type == CHAIN_SHOT:
		# §4.4b: chain also slows — +2 cap-debuff turns (§4.3a).
		target["speed_debuff_turns"] = int(target.get("speed_debuff_turns", 0)) + CHAIN_DEBUFF_TURNS
	if rake > 1.0:
		# §4.8a event: the side suffering a rake volley −5 (both sides; the
		# rake flag is the §4.4 ×1.25 bearing test, any shot type).
		_morale_event(str(target.get("side", "")), MORALE_EVENT_RAKED)
	result["sunk"] = sunk
	if damage > 0 or crew_kill > 0:
		_round_had_damage = true
	result["log"] = _make_log("cannon", unit, target, {
		"damage": damage, "sunk": sunk, "range": distance,
		"shot": shot_type, "side": resolved_side, "rake": rake > 1.0,
		"crew_kill": crew_kill,
	})
	_check_over()
	return result


## §4.11.8 rule 2's side pick among the fireable sides: a rake-position volley
## beats a non-rake, then the loaded side with more cannons, tie → port.
func _pick_broadside_side(unit: Dictionary, target: Dictionary) -> String:
	var distance := _chebyshev(unit_cell(unit), unit_cell(target))
	var best := ""
	var best_rake := false
	var best_cannons := -1
	for side in [BROADSIDE_PORT, BROADSIDE_STARBOARD]:
		if not _side_can_fire(unit, target, side, distance):
			continue
		var rake := _is_rake_on(target, unit)
		var cannons := side_cannons(unit, side)
		if best.is_empty() or (rake and not best_rake) \
				or (rake == best_rake and cannons > best_cannons):
			best = side
			best_rake = rake
			best_cannons = cannons
	return best


# --- Ram (docs/60-* §4.5, §4.11.5) ----------------------------------------

## True for an orthogonally adjacent living enemy (the §4.5 action ram; the
## sweep ram is triggered by [method _sweep] instead).
func can_ram(unit, target) -> bool:
	if not (unit is Dictionary) or not (target is Dictionary):
		return false
	if not bool(unit.get("alive", false)) or not bool(target.get("alive", false)):
		return false
	if unit.side == target.side:
		return false
	return _manhattan(unit_cell(unit), unit_cell(target)) == 1


## §4.5 action ram against an orthogonally adjacent enemy: both take damage;
## the attacker resolves last (§4.11.5). The impact speed is the attacker's
## CURRENT velocity (§4.5 mult).
func ram(unit: Dictionary, target: Dictionary) -> Dictionary:
	var result := {
		"ok": false, "damage": 0, "attacker_damage": 0,
		"sunk": false, "attacker_sunk": false, "log": {},
	}
	if _over or _action_taken or not is_acting(unit) or not can_ram(unit, target):
		return result
	_action_taken = true
	result["ok"] = true
	var speed := vel_length(unit.get("vel", Vector2i.ZERO))
	var applied := _resolve_ram(unit, target, speed)
	result["damage"] = applied["damage"]
	result["attacker_damage"] = applied["attacker_damage"]
	result["sunk"] = applied["sunk"]
	result["attacker_sunk"] = applied["attacker_sunk"]
	result["log"] = applied["log"]
	return result


## The §4.5 ram resolution shared by the action ram and the sweep entry:
## `mult = (1 + 0.25 × (floor(‖vel‖) − 1)) × (bow/stern approach ? 1.15 : 1)`
## with an oar/hybrid attacker's ×1.25 folded in before the floors;
## target `floor(att_max_dur × 0.25 × mult)`, self `floor(att_max_dur × 0.10 ×
## mult)` (the attacker's EFFECTIVE max durability, §4.11.12). Target first,
## attacker last.
func _resolve_ram(attacker: Dictionary, target: Dictionary, speed: float) -> Dictionary:
	var att_max := effective_max_durability(attacker["ship"])
	var mult: float = 1.0 + RAM_SPEED_STEP * (floor(maxf(speed, 0.0)) - 1.0)
	# Bow/stern approach: the bearing attacker→target along the TARGET's
	# heading axis (bucket distance 0° or 180°).
	var bearing := heading8_of(unit_cell(target) - unit_cell(attacker))
	if bucket_distance(bearing, int(target.get("heading8", HEADING_EAST))) in [0, 4]:
		mult *= RAM_BOW_STERN_MULTIPLIER
	if ship_class_of(attacker) in OAR_SHIP_CLASSES:
		mult *= OAR_RAM_MULTIPLIER
	var target_damage := int(floor(float(att_max) * RAM_TARGET_FRACTION * mult))
	var attacker_damage := int(floor(float(att_max) * RAM_ATTACKER_FRACTION * mult))
	# Target first, then the attacker (§4.11.5 "attacker resolves last").
	var target_ship: Dictionary = target["ship"]
	target_ship["durability"] = int(target_ship.get("durability", 0)) - target_damage
	var target_sunk := int(target_ship["durability"]) <= 0
	if target_sunk:
		_sink(target, str(attacker.get("side", "")), "ram")
	var attacker_ship: Dictionary = attacker["ship"]
	attacker_ship["durability"] = int(attacker_ship.get("durability", 0)) - attacker_damage
	var attacker_sunk := int(attacker_ship["durability"]) <= 0
	if attacker_sunk:
		_sink(attacker, str(target.get("side", "")), "ram")
	if target_damage > 0 or attacker_damage > 0:
		_round_had_damage = true
	return {
		"damage": target_damage, "attacker_damage": attacker_damage,
		"sunk": target_sunk, "attacker_sunk": attacker_sunk,
		"log": _make_log("ram", attacker, target, {
			"damage": target_damage, "attacker_damage": attacker_damage,
			"sunk": target_sunk, "attacker_sunk": attacker_sunk,
		}),
	}


# --- Boarding & duel (docs/60-* §4.6, §4.6a, §4.11.6) ----------------------

## §4.6a hook condition (decision 8): orthogonal adjacency + BOTH ships at
## `floor(‖vel‖) ≤ 1` + weather ≠ storm (storm forbids hooking outright,
## §4.2).
func can_board(unit, target) -> bool:
	if not can_ram(unit, target):
		return false
	if weather == STORM_WEATHER:
		return false
	return _vel_floor(unit) <= 1 and _vel_floor(target) <= 1


static func _vel_floor(unit: Dictionary) -> int:
	return int(floor(vel_length(unit.get("vel", Vector2i.ZERO))))


## ‖vel‖ as a float (the §4.3a magnitude — the only float use in the model).
static func vel_length(vel: Vector2i) -> float:
	return float(Vector2(vel.x, vel.y).length())


## Resolves a boarding attempt: the hook sets BOTH ships' `vel = 0`
## (correction 7), the duel runs through [method resolve_duel] — the single
## duel implementation (§4.12.1.2) — and the loser is captured: a player win
## removes the enemy ship (`captured_enemy`), a player loss removes the
## player's ship (`lost_player`, §4.11.7). The winning side's crew pays the
## §4.11.5 boarding casualty `floor(crew × 0.2)`, clamped at 0 (crew 0 still
## sails, §4.6a). The §4.8a boarding events book afterwards: the WINNER's
## side +10, the loser −10 (the Phase-8 flat +5 `morale_bonus` is absorbed
## into the event table and retired).
func board(unit: Dictionary, target: Dictionary) -> Dictionary:
	var result := {"ok": false, "duel": {}, "captured": {}, "lost": {}, "log": {}}
	if _over or _action_taken or not is_acting(unit) or not can_board(unit, target):
		return result
	_action_taken = true
	# §4.6a: the hook succeeds — both ships' velocity zeroes.
	unit["vel"] = Vector2i.ZERO
	target["vel"] = Vector2i.ZERO
	_round_had_boarding = true
	var enemy_unit: Dictionary = target if target.side == SIDE_ENEMY else unit
	var player_unit: Dictionary = target if target.side == SIDE_PLAYER else unit
	# §4.11.6 bases: the player rolls swordplay + courage + equipment; the
	# captain-card side rolls min(floor(crew/5), 20) + its duel rating. The
	# defending side — the boarded ship — adds `+ floor(charisma / 20)`: the
	# player's own charisma when the player defends, the captain card's
	# otherwise.
	var player_defends: bool = str(target.get("side", "")) == SIDE_PLAYER
	var player_base := player_duel_base()
	var defender_base := defender_duel_base(
		int(enemy_unit.get("crew", 0)),
		int(enemy_unit.get("captain_rating", CAPTAIN_RATING_BASE)))
	if player_defends:
		player_base += defender_charisma_bonus(player_attribute("charisma"))
	else:
		defender_base += defender_charisma_bonus(captain_charisma(enemy_unit))
	var duel := resolve_duel(player_base, defender_base, rng)
	result["duel"] = duel
	var player_won := str(duel.get("result", "")) == "capture"
	var winner := player_unit if player_won else enemy_unit
	# §4.11.5 boarding casualty on the winner, clamped at 0 (§4.6a).
	winner["crew"] = maxi(int(winner.get("crew", 0))
		- int(floor(float(winner.get("crew", 0)) * BOARDING_CREW_LOSS_FRACTION)), 0)
	if player_won:
		_capture(enemy_unit)
		result["captured"] = enemy_unit["ship"].duplicate(true)
		# §4.8a events: the boarding WINNER's side +10, the loser −10 (both
		# sides; the capture itself books the separate −20 event in
		# [method _capture]). The engine never touches `GameState` — the
		# §4.12.4 consumer applies the net `morale_delta` once.
		_morale_event(SIDE_PLAYER, MORALE_EVENT_BOARDING_WIN)
		_morale_event(SIDE_ENEMY, MORALE_EVENT_BOARDING_LOSS)
	else:
		_capture(player_unit)
		result["lost"] = player_unit["ship"].duplicate(true)
		_morale_event(SIDE_ENEMY, MORALE_EVENT_BOARDING_WIN)
		_morale_event(SIDE_PLAYER, MORALE_EVENT_BOARDING_LOSS)
	result["ok"] = true
	result["log"] = _make_log("board", unit, target, {
		"won": player_won, "player_wins": int(duel.get("player_wins", 0)),
		"defender_wins": int(duel.get("defender_wins", 0)),
	})
	_check_over()
	return result


## §4.12.1.2 / §4.11.6 — the **only** duel formula. `player_base` is the
## player captain's rating, `defender_base` the AI captain's. Both sides roll
## `base + rng.randi_range(0, 20)` per round (player roll first); the higher
## wins the round, equal rolls score for neither. First to 3 wins; after 5
## rounds the higher win count takes it, and equal counts are held by the
## defender (`result: "defeat"`).
static func resolve_duel(player_base: int, defender_base: int, rng: RandomNumberGenerator) -> Dictionary:
	var rounds: Array = []
	var player_wins := 0
	var defender_wins := 0
	for _index in range(DUEL_MAX_ROUNDS):
		if player_wins >= DUEL_WINS_NEEDED or defender_wins >= DUEL_WINS_NEEDED:
			break
		var player_roll := player_base + rng.randi_range(0, DUEL_ROUND_MAX_ROLL)
		var defender_roll := defender_base + rng.randi_range(0, DUEL_ROUND_MAX_ROLL)
		if player_roll > defender_roll:
			player_wins += 1
			rounds.append("win")
		elif defender_roll > player_roll:
			defender_wins += 1
			rounds.append("loss")
		else:
			rounds.append("tie")
	# §4.11.6: undecided after 5 rounds → more wins takes it; equal counts are
	# held by the defender, so the boarding attempt fails. Both cases are
	# expressed by the same comparison (a tie is a `defeat`).
	return {
		"result": "capture" if player_wins > defender_wins else "defeat",
		"rounds": rounds,
		"player_wins": player_wins,
		"defender_wins": defender_wins,
	}


## §4.11.6 defender base: `min(floor(crew / 5), 20) + captain rating` (the
## crew/captain terms only — the §4.11.6 defender charisma bonus is applied by
## the boarding path to whichever side defends).
static func defender_duel_base(crew: int, captain_rating: int) -> int:
	return mini(int(floor(float(maxi(crew, 0)) / DUEL_CREW_DIVISOR)), DUEL_CREW_CAP) + captain_rating


## §4.11.6 Phase-8 defender bonus: the defending side adds
## `+ floor(charisma / 20)` — the player's own charisma when the player
## defends, the captain card's otherwise (0 for a card-less legacy fleet).
static func defender_charisma_bonus(charisma: int) -> int:
	return int(floor(float(maxi(charisma, 0)) / DEFENDER_CHARISMA_DIVISOR))


## §4.11.6 player base: swordplay + floor(courage / 20) + the sum of `combat`
## modifiers on worn weapon/armor equipment (§4.11.12).
static func player_duel_base() -> int:
	var base := player_effective_skill("swordplay") \
		+ int(floor(float(player_attribute("courage")) / DUEL_COURAGE_DIVISOR))
	# Phase-9 S21 seam (§4.12.1): the override's `equipment` wins when present,
	# else the worn GameState equipment. Preserved through the W3 rewrite.
	var equipment = _player_stats_override.get("equipment", null)
	if not (equipment is Dictionary):
		var player: Dictionary = GameState.player
		equipment = player.get("equipment", {}) if player is Dictionary else {}
	if equipment is Dictionary:
		for slot in ["weapon", "armor"]:
			base += equipment_item_modifier(str(equipment.get(slot, "")), "combat")
	return base


## The charisma the captain behind `unit` brings to the defender bonus
## (§4.11.6): the fleet's canon card for AI ships, 0 without a card. Player
## units defend with their own charisma (read at the boarding site).
func captain_charisma(unit: Dictionary) -> int:
	if not (unit is Dictionary) or unit.side != SIDE_ENEMY:
		return 0
	var ship: Dictionary = unit.get("ship", {})
	if ship is Dictionary and ship.has("captain_charisma"):
		return int(ship["captain_charisma"])
	return card_charisma(_fleet_captain_card)


## §4.7: the captain courage behind `unit` — the fleet's canon card, or, for a
## legacy fleet without a card, the doc-pinned `10 + 10 × tier` fallback
## (correction 6). The W4-B courage_mod (the §4.9a profile) adds on the roll
## site, never here.
func captain_courage(unit: Dictionary) -> int:
	if not (unit is Dictionary) or unit.side != SIDE_ENEMY:
		return 0
	return _ship_or_card_courage(unit.get("ship", {}))


## The §4.7 courage behind an ENEMY ship instance: the ship-carried
## `captain_courage` key (the W4-B compose seam) wins, else the fleet's canon
## card, else the doc-pinned `10 + 10 × tier` legacy fallback (correction 6).
## One implementation shared by [method captain_courage] and the §4.8a AI
## morale start ([method _default_enemy_morale] reads the enemy flagship).
func _ship_or_card_courage(ship: Dictionary) -> int:
	if ship is Dictionary and ship.has("captain_courage"):
		return int(ship["captain_courage"])
	if not _fleet_captain_card.is_empty():
		return card_courage(_fleet_captain_card)
	return LEGACY_FALLBACK_BASE + LEGACY_FALLBACK_PER_TIER * int(FLEET_TIER.get(enemy_kind, 1))


## §4.7 surrender chance in percent for an EFFECTIVE courage:
## `clamp(25 − floor(courage / 10), 10, 40)`. `courage_mod` is the W3-B
## profile hook (§4.9a) — W3 callers pass 0.
static func surrender_chance_for_courage(courage: int) -> int:
	return clampi(
		SURRENDER_CHANCE_BASE - int(floor(float(maxi(courage, 0)) / SURRENDER_COURAGE_DIVISOR)),
		SURRENDER_CHANCE_MIN, SURRENDER_CHANCE_MAX)


## §4.7/§4.8a surrender-roll widening: `+ floor((20 − morale) / 2)` percentage
## points on TOP of the clamped base (the base keeps its clamp — the effective
## ceiling is 50% at morale 0). A negative `morale` (the compat default)
## adds nothing, so a W3 caller stays byte-identical.
static func morale_surrender_bonus(morale: int) -> int:
	if morale < 0:
		return 0
	return int(floor(float(maxi(MORALE_SURRENDER_GATE - morale, 0))
		/ float(SURRENDER_MORALE_DIVISOR)))


## [method surrender_chance_for_courage] for the captain behind `unit`, with
## the profile's `courage_mod` folded into the effective courage (§4.7) and —
## when the caller passes the side morale (the T2 surrender site, §4.9a) — the
## §4.8a morale modifier added on top.
func surrender_chance(unit: Dictionary, courage_mod: int = 0, morale: int = -1) -> int:
	return surrender_chance_for_courage(captain_courage(unit) + courage_mod) \
		+ morale_surrender_bonus(morale)


## Draws the §4.7 surrender roll from the battle's single §4.11.1 stream
## (deterministic per seed). A failed roll re-rolls on the ship's next turn.
## `morale` is the side morale (§4.8a); the default keeps W3 callers intact.
func roll_surrender(unit: Dictionary, courage_mod: int = 0, morale: int = -1) -> bool:
	return rng.randf() * 100.0 < float(surrender_chance(unit, courage_mod, morale))


# --- Side morale (docs/60-* §4.8a; decision 9, corrections 5/6) -------------

## The §4.8a side morale for `side` (`"player"` / `"enemy"`), 0–100. THE seam
## the fleet layer (§4.9a/§4.9b morale readings), the S10 HUD (the player
## warning — player ships never auto-strike) and the tests read.
func side_morale(side: String) -> int:
	return clampi(_enemy_morale if side == SIDE_ENEMY else _player_morale,
		MORALE_MIN, MORALE_MAX)


## The §4.8a writeback delta for `side` (end − start); the outcome block's
## `morale_delta` (§4.12.2) is this value for the player side. Starts were
## clamped in [method _init] and every event clamps, so this is exactly
## `clamp(end, 0, 100) − start`.
func morale_delta_for(side: String) -> int:
	var start := _enemy_morale_start if side == SIDE_ENEMY else _player_morale_start
	return side_morale(side) - start


## §4.8a player start default: `GameState.morale`, read defensively (0 when
## the autoload property is absent), clamped 0–100.
static func _default_player_morale() -> int:
	var value: Variant = GameState.get("morale")
	if value is int or value is float:
		return clampi(int(value), MORALE_MIN, MORALE_MAX)
	return MORALE_MIN


## §4.8a AI start default: `clamp(40 + flagship-captain courage, 20, 90)` —
## courage from the enemy flagship's captain card; the legacy no-card fleet
## falls back to `10 + 10 × tier` (correction 6).
func _default_enemy_morale() -> int:
	var flagship: Dictionary = _enemy_ships[0] \
		if not _enemy_ships.is_empty() and _enemy_ships[0] is Dictionary else {}
	return clampi(ENEMY_MORALE_COURAGE_BASE + _ship_or_card_courage(flagship),
		ENEMY_MORALE_FLOOR, ENEMY_MORALE_CEILING)


## Applies one §4.8a event-table delta to `side` and clamps to 0..100 after
## it (§4.8a: both morales clamp after every event). Unknown sides are
## ignored (defensive).
func _morale_event(side: String, delta: int) -> void:
	if side == SIDE_PLAYER:
		_player_morale = clampi(_player_morale + delta, MORALE_MIN, MORALE_MAX)
	elif side == SIDE_ENEMY:
		_enemy_morale = clampi(_enemy_morale + delta, MORALE_MIN, MORALE_MAX)


## True when `unit` is the flagship of its side for the §4.8a flagship-sunk
## event, judged at the moment of sinking (callers evaluate BEFORE the
## removal). The player flagship is the game-rule fleet[0] — [method
## _flagship_index], which §4.6/§4.11.7 succession keeps on the next living
## ship. The enemy flagship is the deployed fleet index 0: its §4.9b successor
## takes the battle ANCHOR only ("takes the anchor AND inherits the state
## machine"), never the flagship identity — the −30 event fires once per
## enemy flagship lost, the §4.8a friendly-sunk −15 prices every other hull.
func _is_side_flagship(unit: Dictionary) -> bool:
	var index := int(unit.get("index", -1))
	if str(unit.get("side", "")) == SIDE_PLAYER:
		return index == _flagship_index
	return index == 0


# --- Hold / menu seams -----------------------------------------------------

## Spends the turn's action doing nothing (§4.3 phase ③ "hold").
func hold(unit: Dictionary) -> Dictionary:
	var result := {"ok": false, "log": {}}
	if _over or _action_taken or not is_acting(unit):
		return result
	_action_taken = true
	result["ok"] = true
	result["log"] = _make_log("hold", unit, {}, {})
	return result


## §4.10 `battle.retreat`: ends the battle, result `retreat`.
func retreat() -> Dictionary:
	if _over:
		return outcome()
	_result = RESULT_RETREAT
	_over = true
	_log.append({"kind": "retreat", "key": "battle.log.retreat", "values": {}})
	return outcome()


## §4.11.7 player-offered surrender. Pirates take the flagship's hold (the
## fleet is retained — the application seam clears the hold); a navy with a
## bounty takes the flagship hull itself, and an empty fleet is
## `defeat_captured`. Returns the outcome block.
func offer_surrender() -> Dictionary:
	if _over:
		return outcome()
	_result = RESULT_SURRENDER
	var flagship := _flagship_unit()
	if enemy_kind == "navy" and not flagship.is_empty():
		_lost_player.append(flagship["ship"].duplicate(true))
		flagship["alive"] = false
		_player_last_cause = "captured"
		_promote_player_flagship()
		if living_units(SIDE_PLAYER).is_empty():
			_result = RESULT_DEFEAT_CAPTURED
	_over = true
	_log.append({"kind": "surrender", "key": "battle.log.surrender", "values": {}})
	return outcome()


## The structured log of every resolved action (§4.11.4 "damage order"). Each
## entry is `{kind, key, values}`: `key` is the `ui_strings.json` key the HUD
## renders, `values` carries the numbers — never player-facing text.
func log_lines() -> Array:
	return _log.duplicate(true)


# --- Headless driver (§4.11.3 handoff / tests) ----------------------------

## Applies `policy(sim)` (or `policy(sim, unit)`) then [method end_turn] until
## [method is_over] or the round cap — **40** in Phase 9 (§4.12.1, correction
## 12; the §4.11.10 XP per-round term is bounded by it). Returns the outcome
## block when the battle finished, else `{result: "", rounds: <current>,
## "over": false}`.
func run_to_completion(policy: Callable, max_rounds: int = MAX_ROUNDS) -> Dictionary:
	if not _started:
		start()
	if not policy.is_valid():
		push_error("BattleSim.run_to_completion: invalid policy Callable")
		return {} if _over else {"result": RESULT_UNFINISHED, "rounds": _round, "over": false}
	var guard := 0
	var guard_limit := maxi(max_rounds, 1) * maxi(_units.size(), 1) * 2 + 10
	while not _over and _round <= max_rounds:
		guard += 1
		if guard > guard_limit:
			push_warning("BattleSim.run_to_completion: step guard tripped at round %d" % _round)
			break
		var unit := current_unit()
		if unit.is_empty():
			# No living unit at the cursor (the battle ended between calls):
			# end_turn() re-checks and advances.
			end_turn()
			continue
		_apply_decision(unit, _call_policy(policy, unit))
		if not _over:
			end_turn()
	if _over:
		return outcome()
	return {"result": RESULT_UNFINISHED, "rounds": _round, "over": false}


func _call_policy(policy: Callable, unit: Dictionary):
	var arguments := 0
	if policy.is_valid():
		arguments = policy.get_argument_count()
	if arguments <= 1:
		return policy.call(self)
	return policy.call(self, unit)


## §4.12.1.1 decision dict: `{action, target, cell(derived, informational),
## vel}` — `action` ∈ cannon|ram|board|move|hold|surrender. The three-phase
## turn (§4.3): the decision's `vel` (when carried) moves the ship FIRST —
## movement happens exactly once — then the action resolves. `cell` is
## derived (`pos + vel`), never authored. The cannon `side` / `shot` are NOT
## in the pinned dict shape: the executor derives them (side by the §4.11.8
## rule 2 pick, shot by §4.4b for an enemy actor, round for a player actor
## unless the S10 selector passed them as the optional extra keys).
func _apply_decision(unit: Dictionary, decision) -> void:
	# §4.7 side collapse (§4.8a, correction 5): the ENGINE owns the ≤ 10
	# strike — at side morale ≤ 10 every living AI ship strikes colours at
	# its next turn with NO roll, resolved exactly as the §4.7 surrender
	# ([method _ai_surrender], the capture gate included). It fires ahead of
	# whatever decision the policy produced, so it holds regardless of the AI
	# level/policy. PLAYER ships NEVER auto-strike — low player morale is a
	# HUD warning only ([method side_morale] is the screen's read, §4.8a).
	if str(unit.get("side", "")) == SIDE_ENEMY \
			and bool(unit.get("alive", false)) \
			and side_morale(SIDE_ENEMY) <= MORALE_INSTANT_STRIKE:
		_ai_surrender(unit)
		return
	var action := "hold"
	var target = {}
	if decision is Dictionary:
		action = str(decision.get("action", "hold"))
		target = decision.get("target", {})
		if not (target is Dictionary):
			target = {}
		var vel = decision.get("vel", null)
		if vel is Vector2i:
			apply_velocity(unit, vel)
		elif vel is Vector2:
			apply_velocity(unit, Vector2i(int(vel.x), int(vel.y)))
	match action:
		"cannon":
			var side := str(decision.get("side", ""))
			var shot := str(decision.get("shot", ""))
			if shot.is_empty():
				shot = ai_shot_type(unit, target) \
					if str(unit.get("side", "")) == SIDE_ENEMY else ROUND_SHOT
			cannon(unit, target, side, shot)
		"ram":
			ram(unit, target if target is Dictionary else {})
		"board":
			board(unit, target if target is Dictionary else {})
		"move":
			# The velocity above WAS the move; a decision without a usable
			# vel degenerates to a hold (the authored `cell` is retired).
			if not _moved_this_turn:
				hold(unit)
		"surrender":
			# `surrender` is the AI's own §4.7 capitulation; a *player*-side
			# policy asking for it is the §4.11.7 menu action instead.
			if unit.side == SIDE_ENEMY:
				_ai_surrender(unit)
			else:
				offer_surrender()
		_:
			hold(unit)


## §4.7 AI surrender: resolved exactly as a duel win (capture), no duel.
func _ai_surrender(unit: Dictionary) -> void:
	if _over or _action_taken or unit.side != SIDE_ENEMY or not is_acting(unit):
		hold(unit)
		return
	_action_taken = true
	_surrendered_enemy += 1
	unit["ship"]["crew"] = int(unit.get("crew", 0))
	_captured_enemy.append(unit["ship"].duplicate(true))
	unit["alive"] = false
	_log.append(_make_log("surrender_enemy", unit, {}, {}))
	_check_over()


# --- Snapshot / restore (§4.12.1; the T3 search + tests consume it) --------
#
# A flat `Array[int]` of ALL mutable state, EXACTLY invertible, APPEND-ONLY
# (new fields only ever join at the end so older fixtures keep their layout):
#   [0]                unit count n
#   per unit (13):     pos.x, pos.y, vel.x, vel.y, heading8, durability, crew,
#                      reload_port, reload_starboard, speed_debuff_turns,
#                      alive, captain_rating, cannon_rating
#   scalars (23):      round, cursor, action_taken, moved_this_turn,
#                      round_had_damage, round_had_boarding, stall_rounds,
#                      last_min_distance, flagship_index, over, result_idx,
#                      cause_idx, [retired morale_bonus slot — always 0],
#                      surrendered_enemy, log count, sunk_enemy count,
#                      sunk_by_player count, captured count, sunk_player
#                      count, lost_player count, rng.state,
#                      player_morale, enemy_morale (§4.8a — W4-A appended)

const _SNAPSHOT_UNIT_FIELDS := 13
const _SNAPSHOT_SCALARS := 23


func snapshot() -> Array[int]:
	var out: Array[int] = []
	out.append(_units.size())
	for unit in _units:
		var ship: Dictionary = unit.get("ship", {})
		out.append(int(unit_cell(unit).x))
		out.append(int(unit_cell(unit).y))
		var vel: Vector2i = unit.get("vel", Vector2i.ZERO)
		out.append(vel.x)
		out.append(vel.y)
		out.append(int(unit.get("heading8", HEADING_EAST)))
		out.append(int(ship.get("durability", 0)) if ship is Dictionary else 0)
		out.append(int(unit.get("crew", 0)))
		out.append(int(unit.get("reload_port", 1)))
		out.append(int(unit.get("reload_starboard", 1)))
		out.append(int(unit.get("speed_debuff_turns", 0)))
		out.append(1 if bool(unit.get("alive", false)) else 0)
		out.append(int(unit.get("captain_rating", 0)))
		out.append(int(unit.get("cannon_rating", 0)))
	out.append(_round)
	out.append(_current)
	out.append(1 if _action_taken else 0)
	out.append(1 if _moved_this_turn else 0)
	out.append(1 if _round_had_damage else 0)
	out.append(1 if _round_had_boarding else 0)
	out.append(_stall_rounds)
	out.append(_last_min_distance)
	out.append(_flagship_index)
	out.append(1 if _over else 0)
	out.append(RESULT_VALUES.find(_result))
	out.append(_cause_index())
	# Retired §4.8 slot: `morale_bonus` left the outcome block in W4-A (§4.8a
	# absorbed it); the position is kept as a 0 placeholder so the layout
	# stays append-only for W3-era consumers.
	out.append(0)
	out.append(_surrendered_enemy)
	out.append(_log.size())
	out.append(_sunk_enemy.size())
	out.append(_sunk_enemy_by_player.size())
	out.append(_captured_enemy.size())
	out.append(_sunk_player.size())
	out.append(_lost_player.size())
	out.append(rng.state)
	# §4.8a side morales (appended in W4-A; §4.12.1 "both side morales").
	out.append(_player_morale)
	out.append(_enemy_morale)
	return out


## The exact inverse of [method snapshot]: byte-exact state restoration.
## A size mismatch is rejected with an error and leaves the state untouched.
func restore(arr: Array[int]) -> void:
	if arr.size() < 1:
		push_error("BattleSim.restore: empty snapshot")
		return
	var n := int(arr[0])
	if arr.size() != 1 + n * _SNAPSHOT_UNIT_FIELDS + _SNAPSHOT_SCALARS:
		push_error("BattleSim.restore: size mismatch (%d units ⇒ expected %d ints, got %d)"
			% [n, 1 + n * _SNAPSHOT_UNIT_FIELDS + _SNAPSHOT_SCALARS, arr.size()])
		return
	if n != _units.size():
		push_error("BattleSim.restore: unit count changed since the snapshot")
		return
	var i := 1
	for unit in _units:
		var ship: Dictionary = unit.get("ship", {})
		unit["pos"] = Vector2i(int(arr[i]), int(arr[i + 1]))
		unit["vel"] = Vector2i(int(arr[i + 2]), int(arr[i + 3]))
		unit["heading8"] = int(arr[i + 4])
		if ship is Dictionary:
			ship["durability"] = int(arr[i + 5])
		unit["crew"] = int(arr[i + 6])
		unit["reload_port"] = int(arr[i + 7])
		unit["reload_starboard"] = int(arr[i + 8])
		unit["speed_debuff_turns"] = int(arr[i + 9])
		unit["alive"] = int(arr[i + 10]) == 1
		unit["captain_rating"] = int(arr[i + 11])
		unit["cannon_rating"] = int(arr[i + 12])
		i += _SNAPSHOT_UNIT_FIELDS
	_round = int(arr[i])
	_current = int(arr[i + 1])
	_action_taken = int(arr[i + 2]) == 1
	_moved_this_turn = int(arr[i + 3]) == 1
	_round_had_damage = int(arr[i + 4]) == 1
	_round_had_boarding = int(arr[i + 5]) == 1
	_stall_rounds = int(arr[i + 6])
	_last_min_distance = int(arr[i + 7])
	_flagship_index = int(arr[i + 8])
	_over = int(arr[i + 9]) == 1
	var result_idx := int(arr[i + 10])
	_result = RESULT_VALUES[result_idx] if result_idx >= 0 \
		and result_idx < RESULT_VALUES.size() else RESULT_UNFINISHED
	_player_last_cause = ["", "sunk", "captured"][clampi(int(arr[i + 11]), 0, 2)]
	# i + 12: the retired `morale_bonus` placeholder — written 0, not read.
	_surrendered_enemy = int(arr[i + 13])
	_log.resize(int(arr[i + 14]))
	_sunk_enemy.resize(int(arr[i + 15]))
	_sunk_enemy_by_player.resize(int(arr[i + 16]))
	_captured_enemy.resize(int(arr[i + 17]))
	_sunk_player.resize(int(arr[i + 18]))
	_lost_player.resize(int(arr[i + 19]))
	rng.state = int(arr[i + 20])
	# §4.8a side morales — the exact inverse of the snapshot append.
	_player_morale = int(arr[i + 21])
	_enemy_morale = int(arr[i + 22])


func _cause_index() -> int:
	if _player_last_cause == "sunk":
		return 1
	if _player_last_cause == "captured":
		return 2
	return 0


# --- Equipment helpers (docs/60-* §4.11.12) -------------------------------

## A `combat`/`speed`/`durability` modifier of the item worn in `slot`, 0 for
## an empty/unknown slot (§4.11.12 "missing keys read as empty slots").
static func equipment_modifier(ship: Dictionary, slot: String, stat: String) -> int:
	if not (ship is Dictionary):
		return 0
	var equipment = ship.get("equipment", {})
	if not (equipment is Dictionary):
		return 0
	return equipment_item_modifier(str(equipment.get(slot, "")), stat)


## Modifier of one equipment id, 0 when the id is empty/unknown.
static func equipment_item_modifier(equipment_id: String, stat: String) -> int:
	if equipment_id.is_empty():
		return 0
	var item: Dictionary = DataLoader.get_equipment(equipment_id)
	if item.is_empty():
		return 0
	var modifiers = item.get("modifiers", {})
	if not (modifiers is Dictionary):
		return 0
	return int(modifiers.get(stat, 0))


## §4.11.12: base durability + figurehead durability delta. Used for ram
## damage (§4.11.5) and as the current-durability cap.
func effective_max_durability(ship: Dictionary) -> int:
	var ship_type: Dictionary = DataLoader.get_ship_type(str(ship.get("ship_type_id", "")))
	return int(ship_type.get("durability", 0)) + equipment_modifier(ship, "figurehead", "durability")


# --- Grid helpers ----------------------------------------------------------

static func in_grid(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < GRID_WIDTH and cell.y < GRID_HEIGHT


static func to_cell(value) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Dictionary:
		return Vector2i(int(value.get("x", -1)), int(value.get("y", -1)))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return NO_CELL


static func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## Chebyshev distance with longitude wrap (`20-*` §4.1: x taken mod width —
## 4320 at the Phase-6 grid). The battle grid itself does not wrap, but port
## distances from a world contact tile do — a contact at x = 4318 is 2 tiles
## from a port at x = 0.
static func _world_chebyshev(a: Vector2i, b: Vector2i) -> int:
	var width := _world_width()
	var dx := absi(a.x - b.x) % maxi(width, 1)
	return maxi(mini(dx, width - dx), absi(a.y - b.y))


## The world grid width for world-space distance math (the loaded legend, else
## the locked 4320).
static func _world_width() -> int:
	var grid: Dictionary = DataLoader.map_legend.get("grid", {})
	var width := int(grid.get("width", 0))
	return width if width > 0 else 4320


static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


# --- Turn / initiative internals (§4.11.4) --------------------------------

func _make_unit(side: String, index: int, ship: Dictionary, cell: Vector2i,
		tournament: bool) -> Dictionary:
	var initial_vel := Vector2i.ZERO
	var heading := HEADING_EAST if side == SIDE_PLAYER else HEADING_WEST
	if tournament:
		# §4.11.2 tournament variant: pinned initial velocities — the player
		# bout ship already sails east, the enemy west (single bout; extras,
		# should a fixture carry them, deploy through the band scan at rest).
		if index == 0:
			initial_vel = TOURNAMENT_PLAYER_VEL if side == SIDE_PLAYER \
				else TOURNAMENT_ENEMY_VEL
	var unit := {
		"side": side,
		"index": index,
		"ship": ship,
		"pos": cell,
		"vel": initial_vel,
		"heading8": heading,
		"reload_port": 1,
		"reload_starboard": 1,
		"speed_debuff_turns": 0,
		"crew": maxi(int(ship.get("crew", 0)), 0),
		"alive": true,
		"captain_rating": 0,
		"cannon_rating": 0,
		"gunnery": 0,
		"cannons_port": 0,
		"cannons_starboard": 0,
	}
	if initial_vel != Vector2i.ZERO:
		# §4.11.2 tournament: the pinned velocity sets the heading.
		unit["heading8"] = heading8_of(initial_vel)
	return unit


func _deploy_cell(side: String, index: int) -> Vector2i:
	var table := PLAYER_DEPLOYMENT if side == SIDE_PLAYER else ENEMY_DEPLOYMENT
	if deployment == TOURNAMENT_DEPLOYMENT:
		if index == 0:
			return TOURNAMENT_PLAYER_CELL if side == SIDE_PLAYER \
				else TOURNAMENT_ENEMY_CELL
	if index < table.size():
		return table[index]
	# §4.2 band overflow (more than 5 ships): continue the in-band scan.
	var band: Array = []
	if side == SIDE_PLAYER:
		for x in PLAYER_BAND_MAX_X + 1:
			for y in GRID_HEIGHT:
				band.append(Vector2i(x, y))
	else:
		for x in range(ENEMY_BAND_MIN_X, GRID_WIDTH):
			for y in GRID_HEIGHT:
				band.append(Vector2i(x, y))
	for scan_cell in band:
		var used := false
		for unit in _units:
			if unit_cell(unit) == scan_cell:
				used = true
				break
		if not used:
			return scan_cell
	return NO_CELL


## §4.4 broadside split (decision 3): `port = floor(n / 2)`, starboard the
## rest — derived from the ship's TOTAL cannons at battle start and stored on
## the unit; the total stays on the ship instance for the outcome/rewards
## blocks (decision 14). A ship-carried `cannons_port`/`cannons_starboard`
## pair (the W3-B compose seam) wins when it sums to the total.
func _price_broadside_split() -> void:
	for unit in _units:
		var ship: Dictionary = unit["ship"]
		var total := maxi(int(ship.get("cannons", 0)), 0)
		var port := int(floor(float(total) / BROADSIDE_SPLIT_DIVISOR))
		var starboard := total - port
		if ship.has("cannons_port") and ship.has("cannons_starboard") \
				and int(ship["cannons_port"]) + int(ship["cannons_starboard"]) == total:
			port = int(ship["cannons_port"])
			starboard = int(ship["cannons_starboard"])
		unit["cannons_port"] = port
		unit["cannons_starboard"] = starboard


## §4.4a gunnery source, priced once at battle start: the player flagship's
## effective gunnery, a captain-card ship's card `skills.gunnery`, the legacy
## `10 + 10 × tier` fallback for a card-less enemy fleet (correction 6's
## fallback family), 0 for a captain-less player escort.
func _price_gunnery() -> void:
	for unit in _units:
		unit["gunnery"] = _gunnery_source(unit)


func _gunnery_source(unit: Dictionary) -> int:
	if unit.side == SIDE_PLAYER:
		if int(unit.index) == _flagship_index:
			return player_effective_skill("gunnery")
		var officer: Dictionary = _escort_captain_officer(unit)
		if not officer.is_empty():
			var skills = officer.get("skills", {})
			return int(skills.get("gunnery", 0)) if skills is Dictionary else 0
		return 0
	var ship: Dictionary = unit["ship"]
	if ship.has("gunnery"):
		return int(ship["gunnery"])
	if not _fleet_captain_card.is_empty():
		var card_skills = _fleet_captain_card.get("skills", {})
		return int(card_skills.get("gunnery", 0)) if card_skills is Dictionary else 0
	return LEGACY_FALLBACK_BASE \
		+ LEGACY_FALLBACK_PER_TIER * int(FLEET_TIER.get(enemy_kind, 1))


## §4.11.5 / §4.11.11.2: each ship's captain-card ratings are priced **once**
## at battle start and stored on the unit (`captain_rating` = the duel rating,
## `cannon_rating` = the §4.11.5 combat rating) — never re-rolled mid-battle.
##
## Priority per side:
##   * values already stored on the ship instance (`duel_rating` /
##     `cannon_rating`, what the fleet source will persist per §4.11.11.2)
##     win;
##   * AI ships otherwise price from the fleet's canon card (config
##     `captain_id` / `captain: {id}`);
##   * player escorts price from their appointed captain officer's officers.json
##     v2 card (§4.11.5 escort branch), a captain-less escort staying 0/0;
##   * a fleet with **no card** (the legacy `captain: {pool_id, name_index}`
##     shape) keeps the retired `5 + tier` stand-in on both ratings —
##     byte-identical to Phase 2/7 until W4-B flips the fleet source.
func _price_captain_ratings() -> void:
	var legacy_rating := CAPTAIN_RATING_BASE + int(FLEET_TIER.get(enemy_kind, 1))
	for unit in _units:
		if unit.side == SIDE_ENEMY:
			var ship: Dictionary = unit["ship"]
			if ship.has("duel_rating") and ship.has("cannon_rating"):
				unit["captain_rating"] = int(ship["duel_rating"])
				unit["cannon_rating"] = int(ship["cannon_rating"])
			elif not _fleet_captain_card.is_empty():
				unit["captain_rating"] = card_duel_rating(_fleet_captain_card)
				unit["cannon_rating"] = card_cannon_rating(_fleet_captain_card)
			else:
				unit["captain_rating"] = legacy_rating
				unit["cannon_rating"] = legacy_rating
		elif int(unit.index) != _flagship_index:
			# Player escort (§4.11.5): the appointed captain officer's card,
			# else the captain-less rule (duel 0, cannon rating 0).
			var escort_ship: Dictionary = unit["ship"]
			if escort_ship.has("duel_rating") and escort_ship.has("cannon_rating"):
				unit["captain_rating"] = int(escort_ship["duel_rating"])
				unit["cannon_rating"] = int(escort_ship["cannon_rating"])
				continue
			var officer: Dictionary = _escort_captain_officer(unit)
			if officer.is_empty():
				unit["captain_rating"] = 0
				unit["cannon_rating"] = 0
			else:
				unit["captain_rating"] = card_duel_rating(officer)
				unit["cannon_rating"] = card_cannon_rating(officer)


## The appointed captain officer of a player escort ship (§4.11.5 escort
## branch), as an officers.json v2 record, or {} when the ship is captain-less.
static func _escort_captain_officer(unit: Dictionary) -> Dictionary:
	var ship: Dictionary = unit.get("ship", {})
	if not (ship is Dictionary):
		return {}
	var officer_id := str(ship.get("captain_officer_id", ""))
	if officer_id.is_empty():
		officer_id = _officer_state_captain_for(str(ship.get("id", "")))
	if officer_id.is_empty():
		return {}
	return DataLoader.get_officer(officer_id)


## The officer id posted as this ship's captain in the (defensive)
## `GameState.officer_states` scan; "" when the block or the match is absent.
static func _officer_state_captain_for(ship_id: String) -> String:
	if ship_id.is_empty():
		return ""
	var states = GameState.get("officer_states")
	if not (states is Dictionary):
		return ""
	for officer_id in states:
		var state = states[officer_id]
		if state is Dictionary and str(state.get("post_id", "")) == "captain" \
				and str(state.get("ship_id", "")) == ship_id:
			return str(officer_id)
	return ""


## §4.11.4: the initiative order is built ONCE at battle start — descending
## `ShipType.speed + sail_speed_delta` (correction 2), ties player-before-
## enemy, then ascending fleet index. A unit destroyed before its slot is
## skipped and never acts; the list is never re-sorted mid-battle (§4.3).
func _build_order() -> void:
	_order = []
	for unit in _units:
		if bool(unit.get("alive", false)):
			_order.append(unit)
	_order.sort_custom(func(a, b) -> bool: return _initiative_before(a, b))


func _initiative_before(a: Dictionary, b: Dictionary) -> bool:
	var key_a := initiative_key(a)
	var key_b := initiative_key(b)
	if key_a != key_b:
		return key_a > key_b
	if a.side != b.side:
		return a.side == SIDE_PLAYER
	return int(a.index) < int(b.index)


## Advances to the next living unit; at the wrap the completed round is
## evaluated for stall (§4.11.9) and the round counter steps. No re-sort —
## the order is the once-built initiative list.
func _advance() -> void:
	var guard := 0
	var limit := _order.size() + 2
	while guard <= limit:
		guard += 1
		_current += 1
		if _current >= _order.size():
			_evaluate_stall()
			if _over:
				return
			_round += 1
			_current = -1
			_round_had_damage = false
			_round_had_boarding = false
			continue
		var unit = _order[_current] if _current < _order.size() else null
		if unit is Dictionary and bool(unit.get("alive", false)):
			_action_taken = false
			_moved_this_turn = false
			return


## §4.11.9 stall detection (decision 12): 8 consecutive rounds with zero
## damage AND zero boarding AND a net player↔enemy Chebyshev change ≤ 2 ⇒
## outcome `stall`. The three conjuncts scope the whole 8-round window (§4.11.9
## wording), so "net" is the CUMULATIVE change across the zero-activity
## streak: the anchor is the minimum-pair Chebyshev at the streak's start, and
## a net drift past ±2 breaks the streak the same way damage does. Any damage
## or boarding resets the counter (and re-anchors). The distance is the
## minimum Chebyshev across living player↔enemy pairs at round end.
func _evaluate_stall() -> void:
	var distance := _min_pair_distance()
	if distance < 0:
		return
	if _round_had_damage or _round_had_boarding:
		_stall_rounds = 0
		_last_min_distance = distance
		return
	_stall_rounds += 1
	if _stall_rounds == 1:
		# Fresh streak: this round's distance anchors the window.
		_last_min_distance = distance
	elif _last_min_distance >= 0 \
			and absi(_last_min_distance - distance) > STALL_DISTANCE_DELTA:
		# The window's net change breached the ≤ 2 pin — the streak fails and
		# restarts from here (the anchor moves with it).
		_stall_rounds = 0
		_last_min_distance = distance
	if _stall_rounds >= STALL_ROUNDS:
		_result = RESULT_STALL
		_over = true


## The minimum Chebyshev distance across living player↔enemy pairs (−1 when
## either side has no living ship).
func _min_pair_distance() -> int:
	var players := living_units(SIDE_PLAYER)
	var enemies := living_units(SIDE_ENEMY)
	if players.is_empty() or enemies.is_empty():
		return -1
	var best := 1 << 30
	for player in players:
		for enemy in enemies:
			best = mini(best, _chebyshev(unit_cell(player), unit_cell(enemy)))
	return best


# --- Damage / removal internals (§4.11.5, §4.11.7) ------------------------

## Removes a sunk ship immediately; cargo is lost (§4.7). The §4.8a events
## book here: friendly ship sunk −15, or −30 TOTAL when the hull was the
## side's flagship (evaluated BEFORE the removal — the flagship is who it was
## at the moment of sinking; the −30 replaces, never adds to, the −15,
## correction 5).
func _sink(unit: Dictionary, by_side: String, _cause: String) -> void:
	if not bool(unit.get("alive", false)):
		return
	var flagship_sunk := _is_side_flagship(unit)
	var side := str(unit.get("side", ""))
	unit["alive"] = false
	unit["ship"]["durability"] = 0
	var ship_type_id := str(unit["ship"].get("ship_type_id", ""))
	if unit.side == SIDE_ENEMY:
		_sunk_enemy.append(ship_type_id)
		if by_side == SIDE_PLAYER:
			_sunk_enemy_by_player.append(ship_type_id)
	else:
		_sunk_player.append(ship_type_id)
		_player_last_cause = "sunk"
		_promote_player_flagship()
	_morale_event(side, MORALE_EVENT_FLAGSHIP_SUNK if flagship_sunk
		else MORALE_EVENT_FRIENDLY_SUNK)


## Removes a captured ship (duel win/loss, AI surrender). The instance is
## reported intact — battle-worn crew and durability — and the §4.11.7
## 25%-durability/crew-0 transform is the application seam's (task C). The
## §4.8a captured event books here: ship captured −20, the captured hull's
## own side (both sides).
func _capture(unit: Dictionary) -> void:
	if not bool(unit.get("alive", false)):
		return
	unit["alive"] = false
	unit["ship"]["crew"] = int(unit.get("crew", 0))
	if unit.side == SIDE_ENEMY:
		_captured_enemy.append(unit["ship"].duplicate(true))
	else:
		_lost_player.append(unit["ship"].duplicate(true))
		_player_last_cause = "captured"
		_promote_player_flagship()
	_morale_event(str(unit.get("side", "")), MORALE_EVENT_CAPTURED)


## The player flagship's fleet index (`fleet[0]`, §4.6/§4.11.7). Advanced to
## the next living ship when the flagship is captured or sunk.
func flagship_index() -> int:
	return _flagship_index


## The living player flagship unit, `{}` when the fleet is gone.
func flagship_unit() -> Dictionary:
	return _flagship_unit()


## §4.6: the next ship becomes the flagship, order preserved (`fleet[0]`).
func _promote_player_flagship() -> void:
	_flagship_index = _lowest_living_index(SIDE_PLAYER)


func _lowest_living_index(side: String) -> int:
	var best := -1
	for unit in _units:
		if unit.side != side or not bool(unit.get("alive", false)):
			continue
		if best < 0 or int(unit.index) < best:
			best = int(unit.index)
	return best


func _flagship_unit() -> Dictionary:
	for unit in _units:
		if unit.side == SIDE_PLAYER and bool(unit.get("alive", false)) \
				and int(unit.index) == _flagship_index:
			return unit
	return {}


func _check_over() -> void:
	if _over:
		return
	if living_units(SIDE_PLAYER).is_empty():
		_result = RESULT_DEFEAT_CAPTURED if _player_last_cause == "captured" else RESULT_DEFEAT_SUNK
		_over = true
		return
	if living_units(SIDE_ENEMY).is_empty():
		_result = RESULT_VICTORY
		_over = true


# --- Outcome internals (§4.11.10) -----------------------------------------

func _salvage_gold() -> int:
	var total := 0
	for ship_type_id in _sunk_enemy_by_player:
		var ship_type: Dictionary = DataLoader.get_ship_type(str(ship_type_id))
		total += int(floor(float(ship_type.get("base_price", 0)) * SALVAGE_FRACTION))
	return total


func _rep_deltas() -> Dictionary:
	var deltas := {}
	# §4.11.10/§4.12.2: `rep_deltas` carries **only** the pirate `+2` entries.
	# The navy `−20` is charged exactly once per navy battle at battle *start*
	# by whoever initiated it (the S3 funnel, `world_map.gd`), never per ship
	# and never here — so applying this block twice can never double-charge it.
	if enemy_kind == "pirate":
		# §4.11.10 "Pirates defeated (any outcome except retreat)".
		if _result != RESULT_RETREAT:
			for nation_id in _nearest_port_nations():
				deltas[nation_id] = int(deltas.get(nation_id, 0)) + PIRATE_REP_GAIN
	return deltas


## Nations of the two nearest ports (Chebyshev from the contact tile; ties by
## port id ascending; a nation credited once). §4.11.10 picks **two ports**
## first and credits their nations, then drops a duplicate.
func _nearest_port_nations() -> Array:
	var ports: Array = []
	DataLoader.ensure_map()
	for port in DataLoader.ports_list:
		if not (port is Dictionary):
			continue
		# Ports carry lat/lon only; the berth tile is derived (§10-* §6.1).
		var position: Vector2i = DataLoader.port_cell(str(port.get("id", "")))
		if position.x < 0:
			continue
		ports.append({
			"id": str(port.get("id", "")),
			"nation_id": str(port.get("nation_id", "")),
			"distance": _world_chebyshev(contact, position),
		})
	ports.sort_custom(func(a, b) -> bool:
		if int(a["distance"]) != int(b["distance"]):
			return int(a["distance"]) < int(b["distance"])
		return str(a["id"]) < str(b["id"]))
	var nations: Array = []
	for index in mini(ports.size(), NEAREST_PORT_COUNT):
		var nation_id := str((ports[index] as Dictionary)["nation_id"])
		if nation_id.is_empty() or nation_id in nations:
			continue
		nations.append(nation_id)
	return nations


func _make_log(kind: String, unit: Dictionary, target: Dictionary, values: Dictionary) -> Dictionary:
	var payload := values.duplicate(true)
	payload["side"] = str(unit.get("side", ""))
	payload["unit"] = int(unit.get("index", -1))
	if target is Dictionary and not target.is_empty():
		payload["target_side"] = str(target.get("side", ""))
		payload["target"] = int(target.get("index", -1))
	var entry := {"kind": kind, "key": "battle.log." + kind, "values": payload}
	_log.append(entry)
	return entry


static func _copy_ships(ships) -> Array:
	var out: Array = []
	if not (ships is Array):
		return out
	for ship in ships:
		if ship is Dictionary:
			out.append(ship.duplicate(true))
	return out
