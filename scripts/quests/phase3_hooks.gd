class_name Phase3Hooks
extends RefCounted
## The Phase-3 integration seams, in one place
## (docs/70-* §4.2–§4.7, §4.9.3–§4.9.7; docs/90-* §5.1).
##
## Every Phase-3 system is a pure module (`QuestGen`, `Bounty`, `Fame`,
## `PalaceEngine`, `Tournament`, `DiscoverySight`); this class is the *wiring*
## that binds them to the Phase-1/2 signals, exactly as `BattleRewards` binds
## the combat outcome to the economy. Keeping the wiring here means the
## world/battle/port scenes each gain one call instead of re-implementing the
## order of the hooks (the Phase-2 lesson: two copies of one rule diverge).
##
## Call sites (all in existing scenes, one line each):
##   * `world_map._on_day_advanced` → [method on_day_tick]
##   * `world_map._enter_port`      → [method on_port_entered]
##   * `battle_screen._finish_battle` → [method on_battle_finished]
##   * `world_map` Explore action   → [method explore_here]
##   * `world_map` `fleet_changed`  → [method on_cargo_changed]

const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const TournamentLib := preload("res://scripts/quests/tournament.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const FameLib := preload("res://scripts/player/fame.gd")


# --- Day tick (docs/70-* §4.9.3, §4.9.4) ---------------------------------

## Runs every Phase-3 clock hook for one day: quest expiry/cargo failures, royal
## mission expiry, and the bounty re-evaluation (a reputation change elsewhere
## may have crossed the threshold). Returns
## `{failed_quests, failed_missions, bounties_issued}` so the caller can report.
static func on_day_tick(day: int) -> Dictionary:
	var failed_quests: Array = QuestGenLib.tick(day)
	var failed_missions: Array = PalaceEngineLib.tick(day)
	QuestGenLib.prune()
	var issued: Array = BountyLib.evaluate_all()
	return {
		"failed_quests": failed_quests,
		"failed_missions": failed_missions,
		"bounties_issued": issued,
	}


# --- Port entry (docs/70-* §4.2, §4.4) -----------------------------------

## Runs the port-entry hooks: complete every delivery due here. Returns the
## completed quest instances so the caller can show a report dialog.
static func on_port_entered(port_id: String) -> Array:
	if port_id.is_empty():
		return []
	var done: Array = QuestGenLib.complete_delivery_quests(port_id)
	QuestGenLib.prune()
	return done


## Runs the cargo-mutation hook (`70-*` §4.9.3: "the check runs on every cargo
## mutation … `Fleet.add_goods`/`remove_goods`/`jettison_*` funnel through
## `Quests.on_cargo_changed()`"). Called from the `fleet_changed` handler, which
## every cargo change already emits, so a delivery whose goods are sold,
## jettisoned or captured fails immediately with the §4.2 −5 rep. Returns the
## failed instances.
static func on_cargo_changed() -> Array:
	var failed: Array = []
	for quest in GameState.active_quests:
		if not (quest is Dictionary):
			continue
		if str((quest as Dictionary).get("status", "")) \
				!= QuestGenLib.STATUS_ACTIVE:
			continue
		if not QuestGenLib.delivery_cargo_lost(quest):
			continue
		if QuestGenLib.fail(quest):
			failed.append(quest)
	return failed


# --- Battle end (docs/70-* §4.5, §4.9.3, §4.9.4, §4.9.7) ----------------

## Runs the Phase-3 aftermath of a finished battle: the win counter, a bounty
## target's quest completion, a naval-patrol kill, and the hunter-surrendered
## bounty clearing. Safe to call once per battle (every step is idempotent by
## instance status / id).
##
## Returns `{won, completed_quests, cleared_bounty, patrol_completed}`.
static func on_battle_finished(outcome: Dictionary) -> Dictionary:
	var report := {
		"won": false,
		"completed_quests": [],
		"cleared_bounty": "",
		"patrol_completed": [],
	}
	if outcome.is_empty():
		return report
	var result := str(outcome.get("result", ""))
	var kind := str(outcome.get("kind", ""))
	var nation_id := str(outcome.get("nation_id", ""))
	var encounter_id := str(outcome.get("encounter_id", ""))
	var won := result == "victory"
	report["won"] = won

	if won:
		GameState.battles_won += 1

	# a. A guild bounty target: the marker carries its `quest_id` (`4.9.3`).
	if won:
		var marker: Dictionary = _marker(encounter_id)
		var quest_id := str(marker.get("quest_id", ""))
		if not quest_id.is_empty():
			var quest := QuestGenLib.find(quest_id)
			if not quest.is_empty():
				if str(quest.get("giver", "")) == "palace":
					var completed := PalaceEngineLib.on_patrol_kill(quest)
					if not completed.is_empty():
						(report["patrol_completed"] as Array).append(completed)
				else:
					var completed: Array = QuestGenLib.complete_bounty_quests(encounter_id)
					(report["completed_quests"] as Array).append_array(completed)

	# b. Surrendering the flagship to a hunter clears that nation's bounty
	#    (`60-*` §4.11.7, `70-*` §4.9.5 path 2).
	if result == "surrender" and kind == "navy" and not nation_id.is_empty():
		if BountyLib.clear_by_surrender(nation_id):
			report["cleared_bounty"] = nation_id

	QuestGenLib.prune()
	return report


# --- Explore (docs/70-* §4.4) -------------------------------------------

## The world-map Explore action: finds every in-range discovery. Returns the
## found ids (the caller shows `discovery.found` per id, or
## `world.explore.none` when empty).
static func explore_here(cell: Vector2i) -> Array:
	return DiscoveryLib.explore(cell)


## `true` while something is in range (the HUD hint / `E` availability).
static func something_near(cell: Vector2i) -> bool:
	return DiscoveryLib.something_near(cell)


# --- Tournament bouts (docs/70-* §4.9.7) --------------------------------

## `true` when `encounter_id` names a tournament bout.
static func is_tournament(encounter_id: String) -> bool:
	return encounter_id.begins_with("tournament_")


## Settles a tournament bout result: a victory advances, anything else ends the
## bracket with the consolation. Returns the `settle()` block, or `{}` when the
## bout was not a tournament one.
static func on_tournament_bout(outcome: Dictionary) -> Dictionary:
	var encounter_id := str(outcome.get("encounter_id", ""))
	if not is_tournament(encounter_id):
		return {}
	var won := str(outcome.get("result", "")) == "victory"
	var round_number := int(encounter_id.get_slice("_", 2)) if encounter_id \
		.count("_") >= 2 else 1
	if won and round_number < TournamentLib.ROUNDS:
		# Advance: S10's Continue routes back to S13, whose `_ready` starts the
		# next bout from this transient field (`70-*` §4.9.7 "3 successive
		# battles", no repairs between rounds).
		GameState.pending_tournament_round = round_number + 1
		return {"won": true, "round_reached": round_number,
			"next_round": round_number + 1}
	GameState.pending_tournament_round = 0
	var settled := TournamentLib.settle(
		won and round_number >= TournamentLib.ROUNDS, round_number)
	GameState.last_tournament_outcome = settled.duplicate(true)
	return settled


## Takes the bracket block S13 reports on open (`{}` when there is none), so a
## settlement is announced exactly once.
static func take_tournament_outcome() -> Dictionary:
	var outcome: Dictionary = GameState.last_tournament_outcome
	GameState.last_tournament_outcome = {}
	return outcome


## Takes the bout S13 should start (`0` when none) — S13 re-opens mid-bracket
## after each won bout (`70-*` §4.9.7).
static func take_pending_bout() -> int:
	var round_number := int(GameState.pending_tournament_round)
	GameState.pending_tournament_round = 0
	return round_number


# --- Small helpers -------------------------------------------------------

static func _marker(encounter_id: String) -> Dictionary:
	if encounter_id.is_empty():
		return {}
	for marker in GameState.hostile_fleets:
		if marker is Dictionary \
				and str((marker as Dictionary).get("id", "")) == encounter_id:
			return marker
	return {}
