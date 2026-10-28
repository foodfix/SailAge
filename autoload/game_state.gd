extends Node
## GameState — single source of truth for mutable game state
## (docs/90-ARCHITECTURE.md §5.4).
##
## T4 scope: only the field declarations I18n needs plus the pins listed in
## the T4 task, and two trivial helpers. `new_game()`, the daily ledger
## delegation, save/load support and the rest of the §5.4 API are owned by
## later tasks (T16/T17/T18) and are deliberately absent here.

## UI language; locked default "en" (user toggles via the `L` key / top bar).
var locale: String = "en"
## Game clock, in days since new game (0 = no game started).
var day: int = 0
## Player purse in gold pieces.
var gold: int = 0
## Nation, stats, XP/level, officers, reputation map (shape: docs/50-* §4.8).
var player: Dictionary = {}
## Ship instances, flagship at index 0 (shape: docs/40-* §4.1).
var fleet: Array = []
## Fleet tile position, movement + weather state.
var world: Dictionary = {}
## Fleet morale 0–100 (docs/20-* §4.8).
var morale: int = 70
## Port id while docked; null at sea (routing per docs/80-* §4.6).
var current_port = null
## `{port_id: gold_total}` (docs/30-* §4.3).
var port_investments: Dictionary = {}
## Discovered port ids (docs/20-* §4.11).
var known_ports: Array = []
## Phase-2/3 fields: present but empty in Phase 1.
var quests: Array = []
var discoveries_found: Array = []
## Minimap exploration set; deliberately not saved in Phase 1
## (docs/20-* §4.12 known limitation).
var explored_tiles: Dictionary = {}


## Applies a gold delta and announces it. Clamping/ledger rules live in the
## sailing/port engines (docs/20-* §4.9), not here.
func add_gold(delta: int) -> void:
	gold += delta
	EventBus.gold_changed.emit(gold)


## Thin scene router (docs/90-* §7): swaps the root scene.
func change_scene(path: String) -> void:
	get_tree().change_scene_to_file(path)
