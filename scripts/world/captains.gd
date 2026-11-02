extends RefCounted
## ⚠️ W4-B LOCAL STUB — slot A (`phase8-canon`) owns the real module. ⚠️
##
## This worktree (phase8-npc-fleets) lacks slot A's file, so W4-B implements
## the slot-A contract here as a minimal, pure stand-in — MARKED AS THE STUB.
## The master merge resolves by taking slot A's REAL `scripts/world/captains.gd`
## at this exact path (same API), discarding this stub. Every W4-B consumer
## (`npc_fleets.gd`, `npc_intel.gd`, the W4-B suites) codes against ONLY the
## contract below (`60-*` §4.11.15, `10-*` §4.15):
##
##   captain(id) / canon_list() / state(id)         — canon + lazy state read
##   deploy(id) / release(id) / is_deployed(id)     — deployment exclusivity
##   defeat(id, day, crushed) / win(id, day)        — the battle-outcome side
##   day_tick(day)                                  — returning → active
##   is_spawnable(id, day) / is_nemesis(id)         — spawn selection filters
##   speed_jitter(id) -> float                      — the ±10% captain cap
##   add_familiarity(id)                            — sighting attribution
##
## State persists in `GameState.captain_states` (`10-*` §4.15: {status,
## return_day, tier_now, stance, familiarity, dossier_seen, defeats, wins} —
## full entries only for met captains). Deployment is a runtime-only set.

## `60-*` §4.11.15: the return queue's fixed stay — `return_day = day + 60`.
const RETURN_QUEUE_DAYS := 60
## Tier drift clamps (`60-*` §4.11.15: −1 crushing defeat, +1 player loss).
const TIER_MIN := 1
const TIER_MAX := 3
## `speed_jitter` half-width — the ±10% captain cap (W4-B pin).
const SPEED_JITTER_MAX := 0.10

## Runtime deployment exclusivity (`captain_id → true`). Never saved: a
## reloaded ecology re-deploys through the lazy backfill / draws.
static var _deployed: Dictionary = {}


## The canon card by id (`10-*` §4.11), or `{}` when unknown.
static func captain(id: String) -> Dictionary:
	return DataLoader.get_captain(str(id))


## The closed canon in file order.
static func canon_list() -> Array:
	return DataLoader.captains_list


## The captain's state entry, lazily created at the §4.15 defaults
## (`tier_now` seeds from the card's tier; unknown ids still get a state so
## the read seams never crash — the card lookup stays the truth-teller).
static func state(id: String) -> Dictionary:
	id = str(id)
	if id.is_empty():
		return {}
	var states: Dictionary = GameState.captain_states
	if not states.has(id):
		var tier := int(captain(id).get("tier", 1))
		states[id] = {
			"status": "active",
			"return_day": 0,
			"tier_now": tier,
			"stance": 0,
			"familiarity": 0,
			"dossier_seen": false,
			"defeats": 0,
			"wins": 0,
		}
	return states[id]


## Deployment exclusivity (a canon captain sails at most one fleet).
static func deploy(id: String) -> void:
	id = str(id)
	if not id.is_empty():
		_deployed[id] = true


## Clears the deployment flag (the fleet's removal side — a captain whose
## fleet despawns without a player defeat sails again; a defeated one stays
## on the return queue until `day_tick` reactivates it).
static func release(id: String) -> void:
	_deployed.erase(str(id))


static func is_deployed(id: String) -> bool:
	return _deployed.has(str(id))


## The battle-outcome side (W4-C's caller): book the return queue. `crushed`
## drifts the tier −1 (clamp 1–3); `win()` drifts it +1.
static func defeat(id: String, day: int, crushed: bool) -> void:
	var entry := state(id)
	if entry.is_empty():
		return
	entry["status"] = "returning"
	entry["return_day"] = int(day) + RETURN_QUEUE_DAYS
	entry["defeats"] = int(entry.get("defeats", 0)) + 1
	if crushed:
		entry["tier_now"] = clampi(int(entry.get("tier_now",
			int(captain(str(id)).get("tier", 1)))) - 1, TIER_MIN, TIER_MAX)


## The battle-outcome side: the captain beat the player — tier +1 (clamp).
static func win(id: String, day: int) -> void:
	var entry := state(id)
	if entry.is_empty():
		return
	entry["wins"] = int(entry.get("wins", 0)) + 1
	entry["tier_now"] = clampi(int(entry.get("tier_now",
		int(captain(str(id)).get("tier", 1)))) + 1, TIER_MIN, TIER_MAX)


## The daily pass: every `returning` captain whose `return_day` has passed
## returns `active` under its own name (names are never reused — the canon
## is closed). Idempotent per day.
static func day_tick(day: int) -> void:
	for id in (GameState.captain_states.keys() as Array).duplicate():
		var entry: Dictionary = GameState.captain_states[id]
		if str(entry.get("status", "")) != "returning":
			continue
		if int(day) < int(entry.get("return_day", 0)):
			continue
		entry["status"] = "active"


## Spawnable = `active` and not deployed elsewhere.
static func is_spawnable(id: String, _day: int) -> bool:
	id = str(id)
	if id.is_empty() or is_deployed(id):
		return false
	return str(state(id).get("status", "active")) == "active"


## `60-*` §4.11.15: a pirate/privateer at stance ≤ −3 returns as a nemesis.
static func is_nemesis(id: String) -> bool:
	var card := captain(id)
	var role := str(card.get("role", ""))
	if role != "pirate" and role != "privateer":
		return false
	return int(state(id).get("stance", 0)) <= -3


## The ±10% captain speed cap (W4-B): a stable jitter in [−0.10, +0.10],
## a pure function of the id (same value every call, every session).
static func speed_jitter(id: String) -> float:
	var h := hash(str(id) + "|speed_jitter")
	# Map the hash onto [-1, +1) deterministically, then scale.
	var unit := float(h % 20001) / 10000.0 - 1.0
	return clampf(unit * SPEED_JITTER_MAX, -SPEED_JITTER_MAX, SPEED_JITTER_MAX)


## Familiarity accrual (W4-B's sighting attribution; W5-C renders tiers).
static func add_familiarity(id: String) -> void:
	var entry := state(id)
	if entry.is_empty():
		return
	entry["familiarity"] = int(entry.get("familiarity", 0)) + 1


## Test seam: clears the runtime deployment set (a fresh sim re-deploys).
static func reset_deployments() -> void:
	_deployed = {}
