class_name Captains
extends RefCounted
## ⚠️ W4-C LOCAL TEST STUB — NOT the normative module.
##
## Slot A (`phase8-canon`) owns `scripts/world/captains.gd` (canon read, state
## machine, tier drift, stance/nemesis — IMPLEMENT-Phase8 W4-A). This file is
## the MINIMAL stand-in W4-C (`phase8-battle-eco`) coded against, implementing
## exactly the contract the battle-rewards hooks call, so the W4-C suites run
## headless in a worktree where slot A has not merged yet. **The master keeps
## slot A's normative module at the merge** — this stub must lose to it.
##
## Contract implemented (the W4-C calling surface only):
##   * `state(id)` — the §2.4 / save-v9 `captain_states` entry
##     `{status, return_day, tier_now, stance, familiarity, dossier_seen,
##     defeats, wins}`, created on first touch.
##   * `defeat(id, day, crushed := false)` — the §4.11.15 lifecycle step:
##     return queue at `day + RETURN_QUEUE_DAYS`, `defeats + 1`, and a crushed
##     defeat drifts `tier_now` −1 (§2.4, clamp 1–3). Returns the return day.
##   * `win(id, day)` — the captain's win against the player: `wins + 1`,
##     tier drift +1 (§2.4). Returns the new wins count.
##   * `adjust_stance(id, delta)` — stance clamped to ±10. Returns the value.
##   * `is_nemesis(id)` — stance ≤ −3 (§4.11.15 "returns as a nemesis
##     hunter").
##   * `STANCE_NEMESIS_DEFEAT := -2`, `STANCE_ATTACK_NONHOSTILE := -1`.
##
## State backs onto `GameState.captain_states` (save v9's block), exactly the
## canon/state split §2.4 pins. Pure statics, no signals (`90-*` §4).

## §4.11.15: `returning(return_day = day + 60)`.
const RETURN_QUEUE_DAYS := 60
## The W4-C hook deltas (the slot-A contract constants).
const STANCE_NEMESIS_DEFEAT := -2
const STANCE_ATTACK_NONHOSTILE := -1
## §4.11.15: stance ≤ −3 → the captain returns as a nemesis hunter.
const STANCE_NEMESIS_AT := -3
## §2.4 / decision 13: stance −10…+10.
const STANCE_MIN := -10
const STANCE_MAX := 10
## §2.4: tier drift clamp 1–3.
const TIER_MIN := 1
const TIER_MAX := 3
## §2.4 state machine: `active → defeated → returning(day+60) → active`.
const STATUS_ACTIVE := "active"
const STATUS_RETURNING := "returning"


## The captain's runtime state entry, created on first touch (§2.4 "full
## entries only for met captains" — reading is touchless for strangers, the
## lifecycle hooks create on write).
static func state(id: String) -> Dictionary:
	return _ensure(str(id))


## §4.11.15: defeated → the return queue at `day + 60`; `defeats + 1`; a
## crushed defeat (the fleet wiped) drifts the tier −1, clamp 1–3 (§2.4).
## Returns the return day.
static func defeat(id: String, day: int, crushed: bool = false) -> int:
	var entry := _ensure(str(id))
	entry["status"] = STATUS_RETURNING
	entry["return_day"] = maxi(int(day), 0) + RETURN_QUEUE_DAYS
	entry["defeats"] = int(entry.get("defeats", 0)) + 1
	if crushed:
		entry["tier_now"] = clampi(int(entry.get("tier_now", TIER_MIN)) - 1,
			TIER_MIN, TIER_MAX)
	return int(entry["return_day"])


## §2.4: a win against the player drifts the tier +1 (clamp 1–3); `wins + 1`.
## Returns the new wins count.
static func win(id: String, day: int) -> int:
	var entry := _ensure(str(id))
	entry["status"] = STATUS_ACTIVE
	entry["tier_now"] = clampi(int(entry.get("tier_now", TIER_MIN)) + 1,
		TIER_MIN, TIER_MAX)
	entry["wins"] = int(entry.get("wins", 0)) + 1
	return int(entry["wins"])


## §2.4 / decision 13: stance moves clamped to ±10. Returns the new stance.
static func adjust_stance(id: String, delta: int) -> int:
	var entry := _ensure(str(id))
	entry["stance"] = clampi(int(entry.get("stance", 0)) + int(delta),
		STANCE_MIN, STANCE_MAX)
	return int(entry["stance"])


## §4.11.15: true while the captain's stance sits at or below −3.
static func is_nemesis(id: String) -> bool:
	return int(_ensure(str(id)).get("stance", 0)) <= STANCE_NEMESIS_AT


static func _ensure(id: String) -> Dictionary:
	var states: Dictionary = GameState.captain_states
	if not states.has(id):
		states[id] = {
			"status": STATUS_ACTIVE,
			"return_day": 0,
			"tier_now": TIER_MIN,
			"stance": 0,
			"familiarity": 0,
			"dossier_seen": false,
			"defeats": 0,
			"wins": 0,
		}
		GameState.captain_states = states
	return states[id]
