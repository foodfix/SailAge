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


## Audio placeholder hook; silence in Phase 1 (docs/80-UI-UX.md §4.8).
func play_sfx(_name: String) -> void:
	pass
