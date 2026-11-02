class_name Captains
extends RefCounted
## Phase-8 W4-A named-captain canon layer (docs/60-COMBAT.md §4.11.15 +
## §4.11.11.4; docs/10-DATA-SCHEMA.md §4.11/§4.15; docs/90-ARCHITECTURE.md
## §5.4): pure statics over the save-independent canon cards and the
## per-run `GameState.captain_states` block, in the style of
## `scripts/player/skills.gd`.
##
## The closed canon (`data/captains.json`, built by `tools/build_captains.py`)
## never changes at runtime and is never saved; everything the run learns
## about a captain — return-queue status, drifted tier, stance, familiarity,
## dossier flag, defeat/win counters — lives in `GameState.captain_states`
## (save v9). Full entries exist **only for met captains**: reads of an
## unmet captain return the defaults without creating anything, and the
## first *touch* (a defeat, a stance shift, a deployment, …) creates the
## entry lazily through [method ensure].
##
## Lifecycle (the §4.11.15 machine): `active → defeated →
## returning(return_day = day + 60) → active`. Captains never die; a
## defeat books the return queue at the single removal funnel, and
## [method day_tick] walks every due captain back to `active` under its
## own name (names are never reused — the roster is closed). Tier drift:
## −1 on a crushing defeat, +1 on each victory against the player,
## clamped 1–3. A pirate/privateer at stance ≤ −3 comes back as a
## **nemesis hunter** ([method is_nemesis]; B spawns it under the
## hunter-intel rules, `60-*` §4.11.11.1).
##
## Deployment bookkeeping ([method deploy]/[method release]): while a
## fleet sails with captain X, X is `deployed`, so the trickle can never
## draw a second live fleet for the same person. `deployed` is a
## **runtime-only extra key** beyond the §4.15 save shape — it must never
## be persisted (SaveSystem.snapshot() serializes a fixed payload key
## list, `90-*` §8.1; the v9 `captain_states` writer is W6-C's and keeps
## the same discipline). [method release] erases the key again, so a
## captain despawned without a player defeat (budget shrink / any
## non-battle removal) is immediately spawnable.
##
## Seeded determinism: no RNG calls anywhere — [method speed_jitter] and
## every other value is a pure function of ids and day.
##
## Consumers: `scripts/world/npc_fleets.gd` (W4-B — spawn draws,
## `captain_id`, speed jitter, nemesis rerole) and
## `scripts/combat/battle_rewards.gd` (W4-C — defeat/win/stance hooks).

# --- Canon access ------------------------------------------------------------

## A canon card by id (docs/10-* §4.11; built, read-only). `{}` when unknown.
static func captain(id: String) -> Dictionary:
	return DataLoader.get_captain(id)


## The whole closed roster (the loaded `captains` list, read-only canon).
static func canon_list() -> Array:
	return DataLoader.captains_list


# --- Lifecycle constants (docs/60-* §4.11.15, locked) -------------------------

## The return queue: a defeated captain comes back `day + 60`.
const RETURN_QUEUE_DAYS := 60

## Status values (docs/10-* §4.15). The module's machine parks on
## `returning` only — `defeated` is the instantaneous pre-booking reading
## at the removal funnel, never a stored resting state.
const STATUS_ACTIVE := "active"
const STATUS_DEFEATED := "defeated"
const STATUS_RETURNING := "returning"

## Tier drift bounds (clamp 1–3; −1 crushed defeat / +1 captain win).
const TIER_MIN := 1
const TIER_MAX := 3


# --- Stance constants (docs/60-* §4.11.15; the deltas W5's hail and
# --- W4-C's battle hooks share — pin consumers to these, never literals) -----

## Stance scale (docs/50-* §4.6 NPC relations): −10 … +10, starts 0.
const STANCE_MIN := -10
const STANCE_MAX := 10

## Hail → befriend: +1 (once per captain per day, the W5 cooldown).
const STANCE_BEFRIEND := 1

## Player wins an intimidation attempt against this captain: −1.
const STANCE_INTIMIDATE_WIN := -1

## Player's intimidation failed: −2.
const STANCE_INTIMIDATE_FAIL := -2

## The PLAYER defeats a nemesis captain (stance ≤ −3): the grudge deepens
## even in death/retreat — W4-C applies this EXTRA shift on top of nothing
## else. Piracy fame/reputation funnels are W4-C/W5's; this is personal.
const STANCE_NEMESIS_DEFEAT := -2

## Piracy: attacking a non-hostile fleet (the −20 rep/fame funnel is
## W4-C/W5's; this is the captain's personal grudge).
const STANCE_ATTACK_NONHOSTILE := -1

## A pirate/privateer at stance ≤ −3 returns as a nemesis hunter.
const NEMESIS_STANCE := -3

## The roles that can become nemeses (docs/60-* §4.11.15).
const NEMESIS_ROLES: Array[String] = ["pirate", "privateer"]


# --- Familiarity constants (docs/80-* dossier; docs/50-* §4.6) ---------------

const FAMILIARITY_MIN := 0
const FAMILIARITY_MAX := 99

## Career-log unlock thresholds: tier 1 at ≥ 3, tier 2 at ≥ 6, tier 3 at ≥ 10.
const FAMILIARITY_TIERS: Array[int] = [3, 6, 10]


# --- Speed jitter (docs/60-* §4.11.15: a fleet's ±10% captain speed cap) -----

## `speed_jitter(id)` ∈ [−0.10, +0.10], quantized to 1/1000 steps over an
## odd 201-bucket ladder (symmetric, ends inclusive) — a stable hash of the
## captain id so a fleet's jitter is reproducible without RNG state.
const SPEED_JITTER_MAX := 0.10
const _JITTER_STEPS := 201


# --- State (docs/10-* §4.15; docs/90-* §5.4) ---------------------------------

## The §4.15 defaults for `captain_states[id]` — exactly the 8 save keys,
## `tier_now` seeded from the canon card (1 when the card is unknown).
## A fresh dict every call: mutating the returned default of an unmet
## captain must never affect anything.
static func _default_state(canon: Dictionary) -> Dictionary:
	return {
		"status": STATUS_ACTIVE,
		"return_day": 0,
		"tier_now": clampi(int(canon.get("tier", TIER_MIN)), TIER_MIN, TIER_MAX),
		"stance": 0,
		"familiarity": 0,
		"dossier_seen": false,
		"defeats": 0,
		"wins": 0,
	}


## The captain's run state. A met captain's LIVE entry is returned (mutate
## it freely — it is the stored dict); an unmet captain's defaults are a
## throwaway copy, and nothing is created by a read (full entries exist
## only for met captains, docs/90-* §5.4).
static func state(id: String) -> Dictionary:
	var entry: Variant = GameState.captain_states.get(id, null)
	if entry is Dictionary:
		return entry
	return _default_state(DataLoader.get_captain(id))


## Creates the state entry on first touch (idempotent) and returns it.
static func ensure(id: String) -> Dictionary:
	if not (GameState.captain_states.get(id, null) is Dictionary):
		GameState.captain_states[id] = _default_state(DataLoader.get_captain(id))
	return GameState.captain_states[id]


# --- Deployment bookkeeping (runtime-only; never persisted) ------------------

## Marks the captain as sailing on exactly one live fleet (B calls this at
## the spawn draw). Creates the entry lazily — the `deployed` flag is the
## runtime-only extra key beyond the §4.15 shape (see the header note).
static func deploy(id: String) -> void:
	ensure(id)["deployed"] = true


## Clears the deployment flag (a fleet gone without a player defeat —
## budget shrink, any non-battle removal): the captain is immediately
## spawnable again. Erases the key so an idle entry matches the save
## shape exactly; an untouched captain is a no-op (no phantom entry).
static func release(id: String) -> void:
	var entry: Variant = GameState.captain_states.get(id, null)
	if entry is Dictionary:
		(entry as Dictionary).erase("deployed")


static func is_deployed(id: String) -> bool:
	return bool(state(id).get("deployed", false))


# --- Lifecycle (docs/60-* §4.11.15: the return queue + tier drift) ----------

## A defeat at the removal funnel: onto the return queue
## (`return_day = day + 60`), the defeat counter climbs, the deployment
## clears (the fleet is gone), and a crushing defeat drifts the tier −1
## (clamp 1–3). Returns the updated state.
static func defeat(id: String, day: int, crushed: bool = false) -> Dictionary:
	var st := ensure(id)
	st["status"] = STATUS_RETURNING
	st["return_day"] = int(day) + RETURN_QUEUE_DAYS
	st["defeats"] = int(st.get("defeats", 0)) + 1
	st["deployed"] = false
	if crushed:
		st["tier_now"] = clampi(int(st.get("tier_now", TIER_MIN)) - 1,
			TIER_MIN, TIER_MAX)
	return st


## The captain's WIN against the player (an AI victory at the funnel):
## the win counter climbs and the tier drifts +1 (clamp 1–3).
static func win(id: String, _day: int) -> Dictionary:
	var st := ensure(id)
	st["wins"] = int(st.get("wins", 0)) + 1
	st["tier_now"] = clampi(int(st.get("tier_now", TIER_MIN)) + 1,
		TIER_MIN, TIER_MAX)
	return st


## The daily walk over the return queue: every `returning` captain whose
## day has come returns to `active` under its own name (the drifted tier
## keeps its drifted value). Pure bookkeeping — spawning stays B's.
static func day_tick(day: int) -> void:
	for id in GameState.captain_states:
		var st: Variant = GameState.captain_states[id]
		if not (st is Dictionary):
			continue
		if str((st as Dictionary).get("status", "")) == STATUS_RETURNING \
				and int(day) >= int((st as Dictionary).get("return_day", 0)):
			(st as Dictionary)["status"] = STATUS_ACTIVE
			(st as Dictionary)["return_day"] = 0


## Spawn eligibility (B's draw gate): the canon card exists, the captain
## is not mid-return-queue and not already sailing on a live fleet.
static func is_spawnable(id: String, _day: int) -> bool:
	if DataLoader.get_captain(id).is_empty():
		return false
	if is_deployed(id):
		return false
	return str(state(id).get("status", STATUS_ACTIVE)) == STATUS_ACTIVE


# --- Nemesis (docs/60-* §4.11.15) ---------------------------------------------

## True when this captain returns as a nemesis hunter: a pirate/privateer
## whose stance sank to ≤ −3 (the role gate is the canon card's; an
## unknown id is never a nemesis).
static func is_nemesis(id: String) -> bool:
	if int(state(id).get("stance", 0)) > NEMESIS_STANCE:
		return false
	return str(DataLoader.get_captain(id).get("role", "")) in NEMESIS_ROLES


# --- Stance (docs/50-* §4.6; the deltas above are the shared constants) ------

static func stance(id: String) -> int:
	return int(state(id).get("stance", 0))


## Applies a clamped stance delta (one of the STANCE_* constants at every
## call site) and returns the new value.
static func adjust_stance(id: String, delta: int) -> int:
	var st := ensure(id)
	st["stance"] = clampi(int(st.get("stance", 0)) + delta,
		STANCE_MIN, STANCE_MAX)
	return int(st["stance"])


# --- Familiarity (docs/80-* dossier; docs/50-* §4.6) --------------------------

static func familiarity(id: String) -> int:
	return int(state(id).get("familiarity", 0))


## Adds a clamped familiarity amount (default +1: one sighting/interaction).
static func add_familiarity(id: String, amount: int = 1) -> int:
	var st := ensure(id)
	st["familiarity"] = clampi(int(st.get("familiarity", 0)) + amount,
		FAMILIARITY_MIN, FAMILIARITY_MAX)
	return int(st["familiarity"])


## The dossier career-log tier: 0 (< 3) / 1 (≥ 3) / 2 (≥ 6) / 3 (≥ 10).
static func familiarity_tier(id: String) -> int:
	var value := familiarity(id)
	var tier := 0
	for threshold in FAMILIARITY_TIERS:
		if value >= int(threshold):
			tier += 1
	return tier


# --- Dossier flag -------------------------------------------------------------

static func dossier_seen(id: String) -> bool:
	return bool(state(id).get("dossier_seen", false))


static func mark_dossier_seen(id: String) -> void:
	ensure(id)["dossier_seen"] = true


# --- Speed jitter (docs/60-* §4.11.15) ----------------------------------------

## A stable per-captain speed factor ∈ [−0.10, +0.10]: a pure hash of the
## captain id (no RNG, no state), quantized to 1/1000 — the same fleet
## always jitters the same way, on every reload, without seeding anything.
static func speed_jitter(id: String) -> float:
	var bucket := posmod(id.hash(), _JITTER_STEPS)  # 0 … 200
	var half := _JITTER_STEPS / 2  # 100
	return (float(bucket - half) / float(half)) * SPEED_JITTER_MAX
