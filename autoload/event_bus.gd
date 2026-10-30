extends Node
## EventBus — application-wide signals, no state (docs/90-ARCHITECTURE.md §5.1).
##
## Any module may emit; only view/UI code and GameState may connect.
## Cross-screen communication never uses direct node references.

signal day_advanced(new_day: int)
signal locale_changed(locale: String)
signal gold_changed(new_gold: int)
signal fleet_changed()
signal port_entered(port_id: String)
signal game_over(reason: String)
signal save_completed(slot: int)
## Phase 2 (docs/90-* §5.1, docs/60-* §4.11.11.3): the battle lifecycle. The
## S3 → S10 handoff, the after-action reporting and the S11 modal all speak
## through these three; no task may invent a fourth.
signal battle_started(encounter: Dictionary)
signal battle_finished(outcome: Dictionary)
signal duel_finished(outcome: Dictionary)

## Phase 3 (docs/90-* §5.1): fame/title/quest/discovery/bounty/tournament/
## retirement events. The owning module emits; screens connect and re-bind.
signal fame_changed(new_fame: int)
signal quests_changed()
signal title_granted(nation_id: String, rank: String)
signal discovery_found(discovery_id: String)
signal discovery_reported(discovery_id: String)
signal bounty_issued(nation_id: String)
signal bounty_cleared(nation_id: String)
signal tournament_finished(outcome: Dictionary)
signal retired()


## Audio placeholder hook; silence in Phase 1 (docs/80-UI-UX.md §4.8).
func play_sfx(_name: String) -> void:
	pass
