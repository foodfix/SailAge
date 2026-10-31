extends Node2D
## The world scene (S3) — docs/80-UI-UX.md §4.1–§4.5; docs/20-* §4.1–§4.3,
## §4.11–§4.12; docs/90-ARCHITECTURE.md §7, §9.
##
## Phase 4 renders the generated world (`data/maps/world.png`, docs/90-* §9):
## the fleet marker, movement input (keys + click-to-sail, no corner cutting),
## the sighting/exploration reveal, port entry, hostiles and the shared HUD.
##
## The map is never re-parsed here: the scene asks MapLoader once and lets it
## build the TileMap (docs/90-* §9 step 7). Movement rules live in
## `scripts/world/sailing_sim.gd` (unit-testable); this scene only turns input
## into `SailingSimLib.try_move()` calls and keeps the view/UI in sync.
##
## Before a run exists (`GameState.player` empty) the scene is still usable: it
## parks the fleet on Lisbon's berth tile and the HUD renders "-" for values
## it cannot know (docs/IMPLEMENT-Phase1.md T6-D).

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const CharacterPanelLib := preload("res://scenes/ui_shared/character_panel.gd")
## T18: fleet/cargo panel (read-only at sea, docs/40 §4.4).
const FleetPanelLib := preload("res://scenes/ui_shared/fleet_panel.gd")
const GameOverScene := preload("res://scenes/ui_shared/gameover_screen.tscn")
## Phase 5 task J: the living NPC fleet ecology (docs/60-* §4.1, §4.11.11).
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
## Phase 5 task K: wreck collect fills the pooled hold flagship-first
## (docs/40-* §4.2 distribution rule — the same helper the battle loot uses).
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ConfirmScene := preload("res://scenes/ui_shared/confirm_dialog.tscn")
## Phase 3: the explore action and the day/port hooks (`70-*` §4.4/§4.9.3).
const Phase3HooksLib := preload("res://scripts/quests/phase3_hooks.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
## Task H: the click-to-sail A* module (docs/20-* §4.2).
const SailPathLib := preload("res://scripts/world/sail_path.gd")

## The single shipped map id (docs/90-* §9.1). Map switching is retired with
## the dual-map pipeline: `world.map_id` is always this value, so the scene
## never resolves an id and there is no map-change path to rescale for.
const DEFAULT_MAP_ID := "world"
## Fallback cell before a game exists: Lisbon's berth tile, re-derived from the
## data (`lat`/`lon` → §6.1 snap) once the map is loaded. `(-1,-1)` means "the
## first port the map can resolve", then the grid centre if nothing does.
const FALLBACK_CELL := Vector2i(-1, -1)

## Port hub scene (owned by T11).
const PORT_SCENE := "res://scenes/port/port_screen.tscn"
## S10 battle screen (owned by task D). Contact routes here; while the scene is
## absent (a worktree cut before D merged) the encounter is still queued and
## announced — it just does not swap the root, the same convention as
## [constant PORT_SCENE].
const BATTLE_SCENE := "res://scenes/combat/battle_screen.tscn"

## Routing seam (the `GameState.new_game(..., route)` convention): a headless
## suite sets this false so entering a port still runs the whole §4.11 sequence
## — discovery, desertion, dialog queue, `current_port` — without swapping the
## test's own scene root. Production always routes.
var route_to_port: bool = true
## Same seam for S10 (docs/60-* §4.11.11.3): with `false` a contact still emits
## `battle_started` and records `pending_encounter_id()`, but the root is never
## swapped — which is also what keeps a contact from replacing a test runner.
var route_to_battle: bool = true

## docs/80-* §4.3 / project.godot: the eight movement actions.
const MOVE_ACTIONS := {
	"move_nw": Vector2i(-1, -1),
	"move_n": Vector2i(0, -1),
	"move_ne": Vector2i(1, -1),
	"move_w": Vector2i(-1, 0),
	"move_e": Vector2i(1, 0),
	"move_sw": Vector2i(-1, 1),
	"move_s": Vector2i(0, 1),
	"move_se": Vector2i(1, 1),
}
## Base sighting radius used before a character exists (docs/20-* §4.11/§5).
const BASE_SIGHTING_RADIUS := SailingSimLib.SIGHTING_RADIUS

@onready var _camera: Camera2D = $Camera2D
@onready var _fleet_marker: Node2D = $FleetMarker
@onready var _error_layer: CanvasLayer = $Overlay
@onready var _error_label: Label = $Overlay/ErrorLabel
@onready var _hud: Control = get_node_or_null("HUDLayer/HUD")

var _loader = null
var _map_pixels := Vector2.ZERO
var _cell_pixels := 32
## The "WorldChunks" root built by the loader (docs/90-* §9 step 4); null when
## the map failed to load.
var _chunks_root: Node2D = null
## Marker cell. Mirrors `GameState.world_tile()` once a run exists, and is the
## Lisbon fallback before that.
var _fleet_cell := FALLBACK_CELL
## One-shot guard so repeated blocked clicks log once instead of spamming.
var _reject_logged := false
## Port entry waiting for the §4.7 dialog chain to finish before routing (S4).
var _pending_port_id: String = ""
## The S9 overlay (null until a game over fires).
var _gameover: Control = null
## Phase 5 task J: the NPC fleet sim (docs/60-* §4.11.11). Created in `_ready`
## over the saved `GameState.npc_fleets` — never re-rolled on scene open.
var _fleets = null
## Fleet id → the placeholder marker node drawn for it (`80-*` §4.5.2: a
## nation-coloured square with the role letter; pirate red).
var _marker_nodes: Dictionary = {}
## This scene's copy of the §4.11.11.3 handoff — `GameState.pending_encounter`
## is the contract field, but it is declared by task A/§5.4 on the merged base,
## so the scene keeps the value itself too (see [_store_pending_encounter]).
var _pending_encounter: Dictionary = {}
## Encounter that opened the battle currently in progress (S10 owns the fight
## from here; `battle_finished` closes the loop).
var _battle_encounter: Dictionary = {}
## Parent node for the marker squares (created lazily under the map).
var _marker_root: Node2D = null
## The attack confirmation currently on screen (null when none).
var _attack_confirm: Control = null
## Task K: wreck id → the × glyph node drawn for it (docs/80-* §4.5.2: an
## `ACCENT` × glyph, 2×2 tiles, at the wreck site; no battle opens on it).
var _wreck_nodes: Dictionary = {}
## Task K: true while the battle in progress was opened by the player's own
## right-click attack (the §4.11.11.2 loot row applies to those only — a
## hostile contact keeps the §4.11.10 aftermath untouched).
var _battle_player_initiated: bool = false

# --- Task H: hold-to-repeat + click-to-sail (docs/20-* §4.2) ---------------

## The direction action currently held (`""` when none). Only one direction
## repeats at a time; a new press replaces it and resets the cadence.
var _hold_action: String = ""
## True when the hold came from [method press_direction] (a host/test seam)
## rather than a real key event. A real hold is re-verified against
## `Input.is_action_pressed()` every tick, so a lost key-up can never leave the
## fleet sailing on its own.
var _hold_forced: bool = false
## Seconds spent in the current hold, and seconds since the last held step.
## Together they implement "0.25 s delay, then ~8 tiles/s".
var _hold_elapsed: float = 0.0
var _hold_since_step: float = 0.0
## Left-click route still to walk (Steps **after** the current tile). Empty
## when there is no sail order.
var _sail_path: Array[Vector2i] = []
## The clicked destination, kept so a battle interruption can recompute the
## remaining route after the battle is dismissed (`-1,-1` when no order).
var _sail_target := Vector2i(-1, -1)
## Seconds accumulated toward the next path step (same cadence as the hold).
var _sail_elapsed: float = 0.0
## The port a click-shore route is ultimately heading for (20-* §4.11.1): the
## route itself ends on the berth, and docking happens on arrival. "" when the
## current order is an ordinary sea route.
var _sail_dock_port: String = ""
## Set while a battle interruption has suspended a sail order; the order is
## resumed by `_on_battle_finished`.
var _sail_suspended: bool = false
## Seconds a held direction must be down before it starts repeating.
const HOLD_DELAY_SECONDS := 0.25
## Repeats per second once the delay has elapsed ("~8 tiles/s", §4.2).
const HOLD_TILES_PER_SECOND := 8.0
## Seconds between two click-to-sail steps. Deliberately the same as a held
## step, so a click route is "N steps = N moves" at the same pace.
const SAIL_STEP_SECONDS := 1.0 / HOLD_TILES_PER_SECOND
## The A* module instance of the last query (`sail_pathing()`), created lazily.
var _sail = null


func _ready() -> void:
	_loader = MapLoaderLib.new()
	var loaded: bool = _load_active_map()
	# Handoff for DataLoader.is_passable()/port_cell() (docs/90-* §5.2, §9).
	DataLoader.map = _loader if loaded else null

	if not loaded:
		_fleet_marker.visible = false
		_show_error(_loader.last_error)
		return

	_map_pixels = Vector2(_loader.width * _loader.tile_size_px, _loader.height * _loader.tile_size_px)
	_cell_pixels = _loader.tile_size_px
	# Chunked rendering: nothing is drawn until the camera position is known, so
	# the chunk pass runs from [_update_camera] on the first frame.
	_chunks_root = _loader.build_tilemap(self, DataLoader.ports, DataLoader.nations)
	_error_layer.visible = false
	_fleet_marker.z_index = 10

	# World state defaults so movement works even before a new game (T6-D).
	_ensure_world_state()
	_fleet_cell = _read_state_cell()
	_place_marker()

	_camera.zoom = Vector2.ONE
	_camera.make_current()
	_update_camera()
	_loader.refresh_port_overlay(DataLoader.ports, DataLoader.nations)

	# Sighting/exploration at scene ready (docs/20-* §4.11/§4.12).
	_reveal()
	_sync_hud()
	# "Refresh on open" is the one allowed full read (docs/IMPLEMENT T6-B);
	# every later update arrives through EventBus signals.
	if _hud != null:
		_hud.refresh()

	# S14 character panel: parent-agnostic modal that owns `C`/Esc (docs/80-* §4.3).
	CharacterPanelLib.attach_to(self)
	# T18 fleet/cargo panel: same modal contract, `F`; read-only at sea (§4.4).
	FleetPanelLib.attach_to(self)

	# T9 signals: day-tick dialogs (weather damage → mutiny → desertion →
	# greeting, §4.7), the mutiny choice and the S9 game-over overlay.
	EventBus.day_advanced.connect(_on_day_advanced)
	EventBus.game_over.connect(_on_game_over)
	EventBus.fleet_changed.connect(_on_fleet_changed)
	if _hud != null:
		_hud.mutiny_choice.connect(_on_mutiny_choice)
		_hud.dialogs_finished.connect(_on_dialogs_finished)
		if _hud.has_signal("explore_requested"):
			_hud.explore_requested.connect(explore_here)

	# Phase 5 task J: the NPC fleet sim (docs/60-* §4.11.11). The scene only
	# *adopts* the saved fleets here — the sim is told which day already
	# ticked so re-opening the map cannot re-tick or re-move them (§4.11.11.1
	# `last_tick_day` dedupe).
	_init_fleets()
	# `battle_finished` is declared by docs/90-* §5.1; the connect is guarded by
	# `has_signal` so this scene also runs on a base whose EventBus predates the
	# Phase-2 signals (the `ResourceLoader.load` + `has_method` convention).
	if EventBus.has_signal("battle_finished"):
		EventBus.battle_finished.connect(_on_battle_finished)


## The map this scene renders: the single index entry in
## `data/maps/maps.json` (docs/90-* §9.1). A missing index or file is a data
## error — there is no fallback ladder and no map-switch routing.
func _load_active_map() -> bool:
	var files: Dictionary = DataLoader.get_map_files(DEFAULT_MAP_ID)
	if files.is_empty():
		_loader.last_error = "no map index entry for '%s'" % DEFAULT_MAP_ID
		return false
	var path := str(files.get("file", ""))
	if not path.begins_with("res://"):
		path = "res://" + path
	var legend = files.get("legend", {})
	if not (legend is Dictionary) or (legend as Dictionary).is_empty():
		_loader.last_error = "no legend for '%s'" % DEFAULT_MAP_ID
		return false
	return _loader.load_map(path, legend)


## The active map id: always the one shipped map (docs/90-* §9.1). A
## `world.map_id` naming anything else is a logged data error, never a switch —
## the same rule `GameState.new_game` applies, so a new game and a scene opened
## over the same state can never disagree about which map they are showing.
func _active_map_id() -> String:
	var value = GameState.world.get("map_id", DEFAULT_MAP_ID)
	if value is String and not (value as String).is_empty() \
			and (value as String) != DEFAULT_MAP_ID:
		push_warning(
			"WorldMap: world.map_id '%s' is not the shipped map id; showing '%s' "
			% [value, DEFAULT_MAP_ID] + "(docs/90-* §9.1)"
		)
	return DEFAULT_MAP_ID


func _process(delta: float) -> void:
	if _loader == null or not _is_loaded():
		return
	_update_camera()
	# Hold-to-repeat / click-to-sail cadence (docs/20-* §4.2, task H).
	_tick_movement(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not _is_loaded():
		return
	# Click-to-sail / click-to-step (docs/80-* §4.3, docs/20-* §4.2). The HUD
	# is mouse-transparent, so clicks land here; a modal consumes them first.
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
			# Right-click on an adjacent hostile marker = attack (§4.1).
			if _modal_open():
				return
			var attacked := _try_attack(_cell_at(get_global_mouse_position()))
			if attacked:
				# A deliberate attack is manual input: it replaces a sail order.
				_cancel_sail_order()
				get_viewport().set_input_as_handled()
			return
		if mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
			if _modal_open():
				return
			var target := _cell_at(get_global_mouse_position())
			# Adjacent tile: the original one-tile click step (a normal move).
			# Anything else: click-to-sail (path + cadence).
			if _is_adjacent(target):
				if _try_step(target):
					_cancel_sail_order()
					get_viewport().set_input_as_handled()
				return
			if sail_to(target):
				get_viewport().set_input_as_handled()
		return

	# Phase 3: `E` explores the area for discoveries (`70-*` §4.4, `80-*` §4.3).
	if event.is_action_pressed("explore"):
		if _modal_open():
			return
		get_viewport().set_input_as_handled()
		explore_here()
		return

	for action in MOVE_ACTIONS:
		if event.is_action_released(action):
			# Hold-to-repeat ends. A release never steps.
			if _hold_action == action:
				_hold_action = ""
				_hold_forced = false
				_reset_cadence()
			continue
		if event.is_action_pressed(action):
			if _modal_open():
				return
			get_viewport().set_input_as_handled()
			# Echo events (a key auto-repeating) are not a new press: the
			# cadence owns the repeats (§4.2 "hold to repeat").
			if event is InputEventKey and (event as InputEventKey).echo:
				continue
			_press_direction(action)
			return


# --- Public API (hosts and tools/test_movement.gd) -------------------------

## Moves the fleet one tile if the move is legal. Rejected moves (land, reef,
## out of bounds, corner cut) leave position **and** clock untouched (§4.2).
## Returns true when the fleet actually stepped.
func try_step(target: Vector2i) -> bool:
	return _try_step(target)


# --- Task H: hold-to-repeat & click-to-sail (docs/20-* §4.2) ---------------

## Presses a direction action as if the key went down (the public test seam for
## `_unhandled_input`). Steps once immediately (one normal move), starts the
## 0.25 s hold delay, and cancels any click-to-sail order (manual input).
## Returns whether that first step actually happened.
func press_direction(action: String) -> bool:
	if not MOVE_ACTIONS.has(action) or not _is_loaded():
		return false
	_hold_action = action
	_hold_forced = true
	_reset_cadence()
	_cancel_sail_order()
	return _try_step(_fleet_cell + MOVE_ACTIONS[action])


## Releases a direction action (`""` releases whatever is held). Ends the
## repeat; a release never steps.
func release_direction(action: String = "") -> void:
	if action.is_empty() or action == _hold_action:
		_hold_action = ""
		_hold_forced = false
		_reset_cadence()


## Drives the cadence with `seconds` of simulated time — the deterministic
## replacement for `_process(delta)` in headless tests. `100` held steps can be
## produced exactly as `press_direction(...)` followed by
## `advance_movement(HOLD_DELAY_SECONDS + 99 * SAIL_STEP_SECONDS)`.
func advance_movement(seconds: float) -> void:
	_tick_movement(seconds)


## Live cadence state (the test seam that proves the numbers): the held action,
## seconds held, seconds since the last repeat, the delay and the rate.
func hold_state() -> Dictionary:
	return {
		"action": _hold_action,
		"elapsed": _hold_elapsed,
		"since_step": _hold_since_step,
		"delay": HOLD_DELAY_SECONDS,
		"tiles_per_second": HOLD_TILES_PER_SECOND,
		"step_seconds": SAIL_STEP_SECONDS,
	}


## Overwrites the cadence accumulators (test aid for partial-delay cases). A
## negative `since_step` leaves it alone.
func set_hold_accumulator(elapsed: float, since_step: float = -1.0) -> void:
	_hold_elapsed = maxf(0.0, elapsed)
	if since_step >= 0.0:
		_hold_since_step = since_step


## Click-to-sail: computes the §4.2 route to `target` and starts walking it.
## Returns true when a route was found and stored.
##
## The route then advances on the **same cadence as hold-to-repeat** (one
## `_try_step` per [constant SAIL_STEP_SECONDS], i.e. ~8 tiles/s), so a click
## route is N steps = N normal moves — clock, consumption, port entry and
## the fleet-contact check included. The first step happens on the first cadence tick, not
## inside this call, so a click never moves the fleet by itself.
##
## A click on land/ice/off-grid costs nothing and shows `world.move_blocked`;
## a click on water with no sea route costs nothing and shows
## `world.sail.no_path` (§4.2, `80-*` §4.3/§4.7.5).
func sail_to(target: Vector2i) -> bool:
	if _loader == null or not _is_loaded() or _modal_open():
		return false
	var cell := target
	if _loader.width > 0:
		cell.x = posmod(cell.x, _loader.width)
	if cell == _fleet_cell:
		# Clicking the tile the fleet stands on is a no-op (no toast, no order).
		return false
	# 20-* §4.11.1: a port's **shore** tile is a valid destination. The route
	# goes to the adjacent berth (the shore tile stays solid for A*), and the
	# port id is remembered so arriving docks — clicking a shore tile the fleet
	# already stands beside docks immediately, exactly like a direction press.
	var dock_port: String = _loader.shore_port_at(cell)
	if not dock_port.is_empty():
		return _sail_to_shore(cell, dock_port)
	if not _loader.is_passable(cell):
		# Land / ice / out of range: rejected, no clock cost, no order change.
		# A click gets its own toast each time (the one-shot guard of
		# [_reject_move] is for held-direction spam, not for deliberate clicks).
		if not _toast("world.move_blocked"):
			print("WorldMap: click on land/ice/off-grid rejected; no clock cost")
		return false
	var path: Array[Vector2i] = _sail_compute(cell)
	if path.is_empty():
		_reject_sail()
		return false
	# A click is manual input: it replaces a held direction and any old order.
	_hold_action = ""
	_hold_forced = false
	_reset_cadence()
	_sail_path = path
	_sail_target = cell
	_sail_dock_port = ""
	_sail_elapsed = 0.0
	_sail_suspended = false
	return true


## The shore-tile branch of [method sail_to]: route to the port's berth and dock
## on arrival. When the fleet is already orthogonally adjacent to the shore tile
## the click is a docking gesture, not a route (§4.11.1, the same path as a
## direction press).
func _sail_to_shore(shore: Vector2i, port_id: String) -> bool:
	var berth: Vector2i = _loader.port_cell(port_id)
	if berth.x < 0:
		return false
	if _is_orthogonally_adjacent(shore) or berth == _fleet_cell:
		# Already beside the shore tile (or standing on its berth): the click is
		# a docking gesture, not a route — dock now, exactly like a key press.
		return _dock_at(shore)
	var path: Array[Vector2i] = _sail_compute(berth)
	if path.is_empty():
		_reject_sail()
		return false
	_hold_action = ""
	_hold_forced = false
	_reset_cadence()
	_sail_path = path
	_sail_target = berth
	_sail_dock_port = port_id
	_sail_elapsed = 0.0
	_sail_suspended = false
	return true


## True when `cell` is exactly one **orthogonal** step from the fleet (x wraps).
func _is_orthogonally_adjacent(cell: Vector2i) -> bool:
	var delta := _wrapped_delta(cell)
	return absi(delta.x) + absi(delta.y) == 1


## Remaining click-to-sail steps (empty when no order).
func sail_path() -> Array[Vector2i]:
	return _sail_path.duplicate()


## Clicked destination of the current (or suspended) order, `(-1,-1)` when none.
func sail_target() -> Vector2i:
	return _sail_target


## True while a route is stored (walking or suspended by a battle).
func sail_active() -> bool:
	return not _sail_path.is_empty() or _sail_suspended


## Cancels the order (manual direction input, a click elsewhere, redirection,
## docking, a blocked step).
func cancel_sail() -> void:
	_cancel_sail_order()


## True while a battle interruption has suspended a sail order (it resumes on
## `battle_finished`).
func sail_suspended() -> bool:
	return _sail_suspended


## Current fleet cell (the marker source of truth).
func fleet_cell() -> Vector2i:
	return _fleet_cell


## The Phase-3 **Explore** action (`70-*` §4.4, `80-*` §4.3): finds every
## discovery within Chebyshev 3 of the fleet. Returns the ids found, so a test
## can assert the loop headlessly; the dialogs are the only side effect.
func explore_here() -> Array:
	if not _has_game():
		return []
	var found: Array = Phase3HooksLib.explore_here(_fleet_cell)
	var entries: Array = []
	for discovery_id in found:
		var discovery: Dictionary = DataLoader.get_discovery(str(discovery_id))
		entries.append({
			"kind": "discovery", "key": "discovery.found",
			"values": {"name": I18n.t(discovery.get("name", {}))},
		})
	if entries.is_empty():
		if _hud != null and _hud.has_method("toast_key"):
			_hud.toast_key("world.explore.none")
		return found
	entries.append({"kind": "discovery", "key": "discovery.found.hint",
		"values": {}})
	_show_dialog_entries(entries)
	_sync_hud()
	return found


## `true` while a discovery is within the Explore radius (the HUD hint and the
## `E` availability, `70-*` §4.4).
func something_near() -> bool:
	return _has_game() and Phase3HooksLib.something_near(_fleet_cell)


## The shared HUD (tests drive its Explore affordance through this).
func hud() -> Control:
	return _hud


## Re-reads `GameState.world.position` (returning from port, save load, tests).
func sync_from_state() -> void:
	if _loader == null or not _is_loaded():
		return
	_fleet_cell = _read_state_cell()
	_place_marker()
	_update_camera()
	_reveal()
	_sync_hud()
	# A save load replaces `npc_fleets` wholesale; redraw to it.
	_sync_marker_nodes()


## Map size in pixels, for camera tests.
func map_pixels() -> Vector2:
	return _map_pixels


## World-space rect the camera shows. Its **x is unbounded** (the world wraps
## east–west, so a fleet near the seam shows content past `width * 32` that is
## the wrapped world); its y is clamped inside the grid. Tests that need the
## "no void" property intersect x with the map width, which is the seam rule.
func visible_world_rect() -> Rect2:
	var half_view := get_viewport_rect().size * 0.5 / _camera.zoom
	var center := _camera.position
	return Rect2(center - half_view, half_view * 2.0)


# --- Movement (docs/20-* §4.1, §4.2, §6) -----------------------------------

func _try_step(target: Vector2i) -> bool:
	if _loader == null or _modal_open():
		return false
	# x wraps (§4.1): a step east from x = 2159 lands on x = 0. The move is
	# evaluated on the **short** delta (±1) and the stored cell is normalised
	# afterwards, so the seam behaves exactly like any other neighbouring tile.
	var delta := _wrapped_delta(target)
	if maxi(absi(delta.x), absi(delta.y)) != 1:
		# Clicking a non-adjacent tile is a no-op, not a rejected move: no
		# feedback, no clock (±0 tiles is not a "move" at all).
		return false
	var step_target := _fleet_cell + delta
	# Docking (20-* §4.11.1): heading into a port's **shore** tile is an
	# interaction, not a step. The shore tile is land, so this is detected
	# before the legality test — and it requires **orthogonal** adjacency,
	# which is the no-corner-cut rule in disguise: a diagonal into land stays
	# an illegal move.
	if _docks(delta, target):
		return _dock_at(target)
	if not SailingSimLib.is_move_legal(_fleet_cell, step_target, _loader):
		_reject_move(target)
		return false

	# Leaving the harbour: at sea again (docs/20-* §4.11 exit). The departed
	# port is recorded for the Phase-5 hunter intel (docs/60-* §4.11.11.1):
	# hunting nations read `world.last_departed_port`.
	GameState.world["last_departed_port"] = str(GameState.current_port)
	GameState.current_port = null

	# The cell that gets stored: the un-normalised `step_target` may be -1 or
	# `width` at the seam, which the move rule accepts but the save shape must
	# not contain (§4.1 "x taken mod 2160 everywhere").
	var landed := step_target
	if _loader.width > 0:
		landed = Vector2i(posmod(step_target.x, _loader.width), step_target.y)

	if _has_game():
		# Applies the tile + `1/effective_speed` days + day-boundary loop.
		SailingSimLib.try_move(step_target, _loader, _fleet_cell)
	# The sim stored the un-normalised cell; re-assert the wrapped one.
	GameState.set_world_tile(landed)

	_reject_logged = false
	_fleet_cell = landed
	_place_marker()
	_update_camera()
	_reveal()
	_sync_hud()

	# Task K (docs/60-* §4.11.11.2): entering the wreck tile collects it —
	# cargo up to free hold capacity plus the salvage gold, no battle.
	_collect_wrecks_at(landed)

	# docs/60-* §4.11.11.2: contact is measured after the player move — a step
	# onto a tile beside a hostile fleet opens the battle now. S10 owns the
	# screen from here, so nothing else may run on top of it.
	_tick_fleet_contacts()
	if battle_in_progress() and not _sail_path.is_empty():
		# §4.2: a battle interrupts the route. It is **not** thrown away: the
		# remaining path is kept, walking stops, and `_on_battle_finished`
		# recomputes the rest toward the same target.
		_sail_suspended = true
	return true


## True when the pending step is a docking gesture: the target is a port's
## **shore** tile and the fleet is **orthogonally** adjacent to it (20-* §4.11.1).
## A diagonal into the same land tile is never a dock — it stays an illegal move
## (the no-corner-cut rule, §4.2).
func _docks(delta: Vector2i, target: Vector2i) -> bool:
	if delta.x != 0 and delta.y != 0:
		return false
	var cell := target
	if _loader.width > 0:
		cell = Vector2i(posmod(cell.x, _loader.width), cell.y)
	return not _loader.shore_port_at(cell).is_empty()


## Charges one `move_cost()` and opens the port; the fleet does **not** move
## onto the shore tile (docking is an interaction, §4.11.1). The fleet is stored
## on the **berth** tile instead, so `world.position` is always water and the
## "Set Sail" exit has somewhere legal to leave from.
func _dock_at(target: Vector2i) -> bool:
	var cell := target
	if _loader.width > 0:
		cell = Vector2i(posmod(cell.x, _loader.width), cell.y)
	var port_id: String = _loader.shore_port_at(cell)
	if port_id.is_empty():
		return false
	var berth: Vector2i = _loader.port_cell(port_id)
	_reject_logged = false
	# §4.11.1 clock cost: exactly one move's worth of days before the screen.
	# Deliberately state-only (like `SailingSim.try_move`), then the berth is
	# re-asserted so a rejected/otherwise odd berth can never strand the fleet.
	if _has_game():
		SailingSimLib.advance_clock(SailingSimLib.move_cost())
	if berth.x >= 0:
		GameState.set_world_tile(berth)
		_fleet_cell = berth
	_place_marker()
	_update_camera()
	_reveal()
	_sync_hud()
	# Docking ends any click route and any held direction: the fleet is not at
	# sea any more.
	_cancel_sail_order()
	_hold_action = ""
	_reset_cadence()
	_sail_dock_port = ""
	_enter_port(port_id)
	return true


## The signed delta from the fleet cell to `target` on the wrapping grid: `x`
## is reduced to `[-width/2, width/2)` so the seam is just another neighbour
## (§4.1). A magnitude above 1 means "not adjacent".
func _wrapped_delta(target: Vector2i) -> Vector2i:
	var dy := target.y - _fleet_cell.y
	if _loader == null or _loader.width <= 0:
		return Vector2i(target.x - _fleet_cell.x, dy)
	return Vector2i(
		SailPathLib.short_dx(_fleet_cell.x, target.x, _loader.width), dy
	)


## True when `to` is one legal §4.2 step from `from` (seam-aware). Used by the
## click-route walk, whose tiles are absolute world cells.
func _step_is_legal(from: Vector2i, to: Vector2i) -> bool:
	var delta := to - from
	if _loader != null and _loader.width > 0:
		delta.x = SailPathLib.short_dx(from.x, to.x, _loader.width)
	if maxi(absi(delta.x), absi(delta.y)) != 1:
		return false
	return SailingSimLib.is_move_legal(from, from + delta, _loader)


## Docs/20-* §4.2/§6: a blocked move is silent and costs nothing; a brief toast
## is the only feedback (never a modal).
func _reject_move(_target: Vector2i) -> void:
	if _reject_logged:
		return
	_reject_logged = true
	if _toast("world.move_blocked"):
		return
	print("WorldMap: move rejected (land/reef/edge/corner cut); no clock cost")


## A click on water that has no sea route (§4.2): no clock cost, one toast.
func _reject_sail() -> void:
	if _toast("world.sail.no_path"):
		return
	print("WorldMap: no sea route to the clicked tile; no clock cost")


## Shows a ui_strings toast when the HUD offers one and the key exists; false
## otherwise (the caller keeps its console fallback).
func _toast(key: String) -> bool:
	return _hud != null and _hud.has_method("toast_key") and _hud.toast_key(key)


# --- Task H: cadence (docs/20-* §4.2) --------------------------------------

## A manual direction press: one immediate normal move, then the hold repeat.
func _press_direction(action: String, forced: bool = false) -> void:
	_hold_action = action
	_hold_forced = forced
	_reset_cadence()
	_cancel_sail_order()
	_try_step(_fleet_cell + MOVE_ACTIONS[action])


## The held direction drops to a single step per [constant SAIL_STEP_SECONDS]
## after [constant HOLD_DELAY_SECONDS]; the click route uses the same clock.
##
## Every repeat goes through [_try_step], so each one is a normal move (clock,
## consumption, port entry, the fleet-contact check). A blocked step costs nothing and does
## **not** reset the accumulator: its cadence slot was already consumed, so it
## simply produces no move and a held key can never bank up free moves.
func _tick_movement(delta: float) -> void:
	if delta <= 0.0:
		return
	# Nothing to advance: do not pay the modal scan every frame.
	if _hold_action.is_empty() and (_sail_path.is_empty() or _sail_suspended):
		return
	# A modal freezes the world: the cadence holds its phase but does not run.
	if _modal_open():
		return
	if not _hold_action.is_empty():
		# A real key hold is re-checked every tick: if the key went up without
		# us seeing the event (focus loss), the repeat stops rather than runs on.
		if not _hold_forced and not Input.is_action_pressed(_hold_action):
			_hold_action = ""
			_reset_cadence()
		else:
			_tick_hold(delta)
	if _sail_path.is_empty() or _sail_suspended:
		return
	_sail_elapsed += delta
	while _sail_elapsed >= SAIL_STEP_SECONDS - SailingSimLib.CLOCK_EPSILON \
			and not _sail_path.is_empty() and not _sail_suspended:
		_sail_elapsed -= SAIL_STEP_SECONDS
		_step_along_sail_path()


## One held direction's cadence: 0.25 s delay, then 1 step every 0.125 s.
func _tick_hold(delta: float) -> void:
	if _hold_elapsed < HOLD_DELAY_SECONDS:
		_hold_elapsed += delta
		if _hold_elapsed < HOLD_DELAY_SECONDS:
			return
		# Only the part of this frame that is past the delay counts toward the
		# first repeat, so the phase does not depend on the frame rate.
		_hold_since_step = _hold_elapsed - HOLD_DELAY_SECONDS
		_hold_elapsed = HOLD_DELAY_SECONDS
	else:
		_hold_since_step += delta
	while _hold_since_step >= SAIL_STEP_SECONDS - SailingSimLib.CLOCK_EPSILON:
		_hold_since_step -= SAIL_STEP_SECONDS
		if _hold_action.is_empty():
			return
		# One normal move; a blocked step is simply a move that did not happen
		# (its slot is spent, nothing is banked — §4.2 "blocked moves cost
		# nothing", not "blocked moves are saved up").
		_try_step(_fleet_cell + MOVE_ACTIONS[_hold_action])
		# Docking / a battle interruption / a game over ends the hold.
		if GameState.current_port != null or battle_in_progress() \
				or game_over_open() or _sail_suspended:
			_hold_action = ""
			_reset_cadence()
			return


## Walks one stored path step through the normal movement rules.
func _step_along_sail_path() -> void:
	if _sail_path.is_empty():
		return
	var next: Vector2i = _sail_path[0]
	# A route cancels the moment its next tile is no longer a legal step (a
	# save load, a marker push, a manual host move): never force a bad move.
	if not _step_is_legal(_fleet_cell, next):
		_cancel_sail_order()
		_reject_move(next)
		return
	_sail_path.remove_at(0)
	var moved := _try_step(next)
	if not moved:
		_cancel_sail_order()
		return
	# A battle on the way: the rest of the route waits for `battle_finished`.
	if _sail_suspended:
		return
	if battle_in_progress():
		# The battle opened on the final step, so there is nothing left to
		# resume: the order is over (and no "arrived" toast over a battle).
		_cancel_sail_order()
		return
	# Docking, a game over or the destination all end the order.
	if _sail_path.is_empty():
		# A shore-tile click (20-* §4.11.1) docks when the route reaches the
		# berth; the docking itself cancels the order. If the fleet somehow
		# stopped short of the shore tile's orthogonal ring, the order is simply
		# dropped (never a forced dock from a diagonal or a distance).
		if not _sail_dock_port.is_empty():
			var port_id := _sail_dock_port
			_sail_dock_port = ""
			var shore: Vector2i = _loader.shore_cell(port_id)
			if shore.x >= 0 and _is_orthogonally_adjacent(shore):
				_dock_at(shore)
				return
			_cancel_sail_order()
			return
		_finish_sail_order()
		return
	if GameState.current_port != null or game_over_open():
		_cancel_sail_order()


## The destination was reached: toast `world.sail.arrived` when the key exists
## (the Phase-4 inventory lists it; until it lands in `data/ui_strings.json` the
## arrival stays a console line, never invented copy).
func _finish_sail_order() -> void:
	var target := _sail_target
	_sail_path.clear()
	_sail_target = Vector2i(-1, -1)
	_sail_elapsed = 0.0
	_sail_suspended = false
	_sail_dock_port = ""
	if _fleet_cell != target:
		return
	if not _toast("world.sail.arrived"):
		print("WorldMap: arrived at %s (world.sail.arrived not in ui_strings)"
			% str(target))


func _cancel_sail_order() -> void:
	_sail_path.clear()
	_sail_target = Vector2i(-1, -1)
	_sail_elapsed = 0.0
	_sail_suspended = false
	_sail_dock_port = ""


func _reset_cadence() -> void:
	_hold_elapsed = 0.0
	_hold_since_step = 0.0


## The A* call for the current fleet cell (§4.2, `scripts/world/sail_path.gd`).
func _sail_compute(target: Vector2i) -> Array[Vector2i]:
	if _sail == null:
		_sail = SailPathLib.new()
	return _sail.find_path(_fleet_cell, target, _loader)


## The path module of the last query (diagnostics: `last_ms`, `last_stage`).
func sail_pathing():
	return _sail


## Port entry (docs/20-* §4.11, in the doc's numbered order):
##   1. the docking day's move + clock cost (already applied by [_dock_at]);
##   2. discover the port if it was unknown, then dock (`current_port`);
##   3. queue the §4.7 dialogs: desertion (§4.8.2) → arrival greeting (§4.11);
##   4. emit `port_entered`, then route to S4 once the queue has drained.
## The port screen's greeting banner shows `Port.flavor`; the greeting dialog
## carries `{port}` and `{day}` (§4.11 / `ui_strings world.arrive`).
func _enter_port(port_id: String) -> void:
	# 2. Discover-then-dock. Entering an unknown harbor discovers it (§4.11).
	if not GameState.known_ports.has(port_id):
		GameState.known_ports.append(port_id)
	GameState.current_port = port_id

	# 2b. Phase 3: complete every delivery quest due here (`70-*` §4.9.3: the
	# goods are handed over, the reward paid). The report is queued with the
	# other port-entry dialogs so the player sees it.
	var completed: Array = Phase3HooksLib.on_port_entered(port_id)
	var completed_entries: Array = []
	for quest in completed:
		completed_entries.append({
			"kind": "quest", "key": "quest.completed",
			"values": {"name": _quest_name(quest)},
		})

	# 3. §4.8.2 desertion on **every** port entry (morale < 40). The sim owns
	# the loss; this scene owns the message, queued in §4.7 order with the
	# greeting (weather/mutiny entries from the same tick are already queued
	# and sort ahead of these).
	var entries: Array = []
	entries.append_array(completed_entries)
	if _has_game():
		var lost: int = SailingSimLib.apply_desertion()
		if lost > 0:
			entries.append({
				"kind": "desertion", "key": "world.desertion",
				"values": {"count": lost},
			})
		entries.append({
			"kind": "greeting", "key": "world.arrive",
			"values": {
				"port": I18n.t(DataLoader.get_port(port_id).get("name", {})),
				"day": GameState.day,
			},
		})

	# 4. Announce (docs/90-* §5.1) and refresh the position-derived HUD bits.
	EventBus.port_entered.emit(port_id)
	_sync_hud()

	# The port screen (T11 extends the T10 shell). Without one — or when routing
	# is disabled for a headless suite, or there is no run at all (editor
	# inspection mode, docs/IMPLEMENT T6-D) — announce and stay on the map.
	if not route_to_port or not _has_game() or not ResourceLoader.exists(PORT_SCENE):
		if not ResourceLoader.exists(PORT_SCENE):
			push_warning("WorldMap: %s missing (T11); staying on the world map" % PORT_SCENE)
		_show_dialog_entries(entries)
		return
	# Route **after** the dialogs so the desertion/greeting chain is not thrown
	# away by the scene swap (§4.7 "never simultaneously", and an arrival report
	# the player never sees would hide a crew loss).
	_pending_port_id = port_id
	_show_dialog_entries(entries)
	if not (_hud != null and _hud.has_modal()):
		_route_to_pending_port()


## Shows `entries` through the HUD's single §4.7 queue, sorted by DIALOG_ORDER
## (weather damage → mutiny → desertion → arrival greeting). Entries queued
## while another dialog is up are appended, so a port entry during a day-tick
## chain still reads in order.
func _show_dialog_entries(entries: Array) -> void:
	if _hud == null or entries.is_empty():
		return
	_hud.show_dialogs(SailingSimLib.sort_dialogs(entries))


func _on_dialogs_finished() -> void:
	if not _pending_port_id.is_empty():
		_route_to_pending_port()


func _route_to_pending_port() -> void:
	var port_id := _pending_port_id
	_pending_port_id = ""
	if port_id.is_empty() or not route_to_port:
		return
	if not ResourceLoader.exists(PORT_SCENE):
		return
	# Only the scene the tree is actually showing may be replaced. A tool that
	# instanced the map as a child (the headless suites do) keeps its own root;
	# routing there would destroy the test runner instead of the map
	# (docs/90-* §7 "no scene ever frees another" — the router swaps the root).
	if not is_active_scene():
		return
	GameState.change_scene(PORT_SCENE)


## True when this node is the tree's current scene, i.e. a real S3 in
## production rather than a child instanced by a test or a tool.
func is_active_scene() -> bool:
	var tree := get_tree()
	return tree != null and tree.current_scene == self


# --- NPC fleets (docs/60-* §4.1, §4.11.11) ----------------------------------

## Creates the fleet sim and adopts the saved fleets. No tick happens here:
## the sim starts on `GameState.day`, i.e. "this day's tick already happened",
## so opening the map (or saving/loading) can never move a fleet (§4.11.11.1).
func _init_fleets() -> void:
	if _fleets == null:
		_fleets = NpcFleetsLib.new({
			"npc_config": DataLoader.npc_config,
			"preset": GameState.npc_preset,
		})
		_fleets.last_tick_day = int(GameState.day)
	_sync_marker_nodes()


## The fleet sim (public so a test can seed/observe it without a scene).
func fleet_sim():
	return _fleets


## Cells of every live fleet, `[{"id","role","nation_id","cell"}]`, sorted by
## id. The test seam for "fleets moved/died as expected".
func fleet_marker_cells() -> Array:
	var out: Array = []
	if _fleets == null:
		return out
	var entries: Array = _fleets.markers()
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("id", "")) < str(b.get("id", "")))
	for marker in entries:
		out.append({
			"id": str(marker.get("id", "")),
			"role": str(marker.get("role", "")),
			"nation_id": str(marker.get("nation_id", "")),
			"cell": marker.get("cell", NpcFleetsLib.NO_CELL),
		})
	return out


## Id of the encounter queued for S10 (`""` when none).
func pending_encounter_id() -> String:
	return str(pending_encounter().get("id", ""))


## The encounter queued for S10 (`{}` when none). `GameState.pending_encounter`
## wins when the merged base declares it; otherwise the scene's copy answers.
func pending_encounter() -> Dictionary:
	var stored = _stored_pending_encounter()
	if stored is Dictionary and not (stored as Dictionary).is_empty():
		return (stored as Dictionary).duplicate()
	return _pending_encounter.duplicate()


## The fleet tick + contact check after a player step. Called after a
## successful player move (§4.11.11.1 "contact is measured after the player
## move"); the sim itself collapses repeats within one day, so this is a
## contact-only check except on the day's first call.
func _tick_fleet_contacts() -> void:
	if _fleets == null:
		return
	if not _has_game() or game_over_open() or SailingSimLib.is_game_over():
		return
	_check_fleet_contact()


## The full day tick (docs/20-* §4.3 step 4, the post-`day_advanced`
## listener): lane stepping, dwell, decisions, trickle — once per day — then
## the contact check and the marker redraw. `market_changed` for ports the
## NPC trades moved is emitted here (the pure module never emits).
func _tick_fleets_day() -> void:
	if _fleets == null:
		return
	if not _has_game() or game_over_open() or SailingSimLib.is_game_over():
		return
	var moved: Array = _fleets.moved_ports
	_fleets.tick(int(GameState.day))
	for port_id in (_fleets.moved_ports as Array):
		if not (moved as Array).has(port_id):
			EventBus.market_changed.emit(str(port_id))
	_sync_marker_nodes()
	_check_fleet_contact()


## A hostile fleet in contact opens a battle (docs/60-* §4.11.11.2: only
## `pirate` / `privateer` / `hunter`-with-bounty; §4.11.11.3 the S10 handoff).
## Contact with any fleet of a hunting nation also records the at-sea intel
## cell (§4.11.11.1: one assignment on contact).
func _check_fleet_contact() -> void:
	if _fleets == null:
		return
	var tile := GameState.world_tile()
	_fleets.note_contacts(tile)
	var contact: Dictionary = _fleets.nearest_contact(tile)
	if contact.is_empty():
		return
	var encounter: Dictionary = _encounter_for(contact)
	_open_encounter(encounter)


## A fleet in contact is opened as a battle. The encounter queued on
## `GameState.pending_encounter` carries the fleet's saved fields unchanged
## plus the S10 `kind` mapping (§4.11.11.3: `hunter` battles keep
## `kind = "navy"`; every other role carries its role id) and the fleet's own
## seeded composition, so S10 fights exactly what the fleet has.
func _encounter_for(fleet: Dictionary) -> Dictionary:
	var encounter := fleet.duplicate(true)
	encounter["kind"] = NpcFleetsLib.composition_kind(
		str(fleet.get("role", "")))
	encounter["encounter_id"] = str(fleet.get("id", ""))
	if (fleet.get("ships", []) as Array).is_empty():
		# §4.11.11.2: the battle draws from the fleet's own seeded stream.
		encounter["ships"] = NpcFleetsLib.compose_fleet_ships(
			fleet, int(GameState.day))
	# else: a fleet-carried `ships` override (a fixture/K seam) is honored
	# verbatim, exactly like the retired marker block's stored composition.
	encounter["contact"] = {
		"x": GameState.world_tile().x, "y": GameState.world_tile().y,
	}
	return encounter


## Queues `encounter` on `GameState.pending_encounter`, emits `battle_started`
## once and routes to S10 when this scene is the active one and routing is on.
## The pending slot is consumed at battle start, so a re-entrant contact cannot
## open two battles (§4.11.11.3).
##
## The piracy delta is charged **here**, exactly once per battle at start
## (docs/60-* §4.11.11.2: a non-pirate owner pays `Bounty.apply_piracy` —
## −20 owner, +2 its rivals — once per battle at start). Doing it in this
## single funnel — behind the same-id guard above — is what makes a double
## charge impossible by construction, whichever path opened the battle: the
## player's attack, a hunter contact, or a chained second fleet. Pirates cost
## no reputation (§4.1).
func _open_encounter(encounter: Dictionary) -> void:
	if encounter.is_empty():
		return
	if _battle_encounter_id() == str(encounter.get("id", "")) \
			and not _battle_encounter.is_empty():
		return
	_battle_encounter = encounter.duplicate(true)
	# Only the player's own right-click attack (see [_attack]) carries the
	# §4.11.11.2 loot row; every other opener — contact, chain — clears it.
	_battle_player_initiated = false
	_charge_piracy(encounter)
	_store_pending_encounter(encounter)
	if EventBus.has_signal("battle_started"):
		EventBus.battle_started.emit(encounter)
	_route_to_battle()


## `rep −20` with the fleet's nation plus `+2` with its two rivals, once, at
## battle start, for any non-pirate fleet (`60-*` §4.11.11.2, `70-*` §4.5).
## The deltas come from `Bounty.piracy_deltas` (the pinned data rival table),
## and the bounty threshold is re-evaluated right after, so a raid can issue
## a bounty at battle start.
func _charge_piracy(encounter: Dictionary) -> void:
	if str(encounter.get("role", "")) == NpcFleetsLib.PIRATE:
		return
	var nation_id := str(encounter.get("nation_id", ""))
	if nation_id.is_empty():
		return
	BountyLib.apply_piracy(nation_id)


## True while a battle this scene opened is unresolved.
func battle_in_progress() -> bool:
	return not _battle_encounter.is_empty()


## S10 route target ("" when none is pending) — the `port_route_target()` seam.
func battle_route_target() -> String:
	if pending_encounter_id().is_empty() and not battle_in_progress():
		return ""
	if not ResourceLoader.exists(BATTLE_SCENE):
		return ""
	return BATTLE_SCENE


func _route_to_battle() -> void:
	if not route_to_battle:
		return
	if not is_active_scene():
		return
	if not ResourceLoader.exists(BATTLE_SCENE):
		# Task D owns S10; a contact on a base without it is still announced
		# (the encounter is queued) and the map stays usable — never a crash.
		return
	GameState.change_scene(BATTLE_SCENE)


## Redraws the fleet marker squares to match the sim's fleets (docs/80-*
## §4.5.2 placeholder art: a nation-coloured square with the role letter,
## pirate red — palette only, no textures).
func _sync_marker_nodes() -> void:
	if _loader == null or not _is_loaded():
		return
	if _marker_root == null:
		_marker_root = Node2D.new()
		_marker_root.name = "FleetMarkers"
		_marker_root.z_index = 9
		add_child(_marker_root)
	var live: Dictionary = {}
	var entries: Array = _fleets.markers() if _fleets != null else []
	for marker in entries:
		if not (marker is Dictionary):
			continue
		var id := str(marker.get("id", ""))
		if id.is_empty():
			continue
		live[id] = true
		var square: ColorRect = _marker_nodes.get(id, null)
		if square == null:
			square = ColorRect.new()
			square.name = "Marker_%s" % id
			square.size = Vector2(_cell_pixels, _cell_pixels) * 0.7
			square.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_marker_root.add_child(square)
			_marker_nodes[id] = square
			var letter := Label.new()
			letter.name = "Letter"
			letter.add_theme_font_size_override("font_size",
				int(_cell_pixels * 0.5))
			letter.add_theme_color_override("font_color",
				PaletteLib.TEXT)
			square.add_child(letter)
		var role := str(marker.get("role", ""))
		square.color = NpcFleetsLib.marker_color(
			role, str(marker.get("nation_id", "")))
		var letter_node: Label = square.get_node_or_null("Letter")
		var text := str(marker.get("letter", ""))
		if letter_node != null:
			letter_node.text = text
			letter_node.visible = not text.is_empty()
		_place_marker_square(square, marker.get("cell", Vector2i.ZERO))
	for id in _marker_nodes.keys():
		if live.has(id):
			continue
		var dead: ColorRect = _marker_nodes[id]
		_marker_nodes.erase(id)
		dead.queue_free()
	_sync_wreck_nodes()


## Redraws the wreck × glyphs (docs/80-* §4.5.2, task K): an `ACCENT` × in a
## 2×2-tile box centred on the wreck tile. Placeholder palette art only; the
## data comes from `NpcFleets.wrecks()` and nothing re-simulates here.
func _sync_wreck_nodes() -> void:
	if _loader == null or not _is_loaded():
		return
	if _marker_root == null:
		return  # no fleet pass ran yet: nothing to hang the glyphs under
	var live: Dictionary = {}
	var entries: Array = _fleets.wrecks() if _fleets != null else []
	for wreck in entries:
		if not (wreck is Dictionary):
			continue
		var id := str((wreck as Dictionary).get("id", ""))
		if id.is_empty():
			continue
		live[id] = true
		var glyph: Label = _wreck_nodes.get(id, null)
		if glyph == null:
			glyph = Label.new()
			glyph.name = "Wreck_%s" % id
			glyph.text = "×"
			glyph.add_theme_color_override("font_color", PaletteLib.ACCENT)
			glyph.add_theme_font_size_override("font_size",
				int(float(_cell_pixels) * 1.2))
			glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
			glyph.z_index = 8
			_marker_root.add_child(glyph)
			_wreck_nodes[id] = glyph
		_place_wreck_glyph(glyph, NpcFleetsLib.position_of(wreck))
	for id in _wreck_nodes.keys():
		if live.has(id):
			continue
		var gone: Label = _wreck_nodes[id]
		_wreck_nodes.erase(id)
		gone.queue_free()


## Centers a 2×2-tile × glyph box on the wreck tile.
func _place_wreck_glyph(glyph: Label, cell: Vector2i) -> void:
	var box := Vector2(float(_cell_pixels) * 2.0, float(_cell_pixels) * 2.0)
	glyph.size = box
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.position = Vector2(cell) * float(_cell_pixels) \
		+ (Vector2(float(_cell_pixels), float(_cell_pixels)) - box) * 0.5


## Collects every wreck on `cell` (docs/60-* §4.11.11.2, task K): the cargo
## up to the pooled free hold — `Fleet.add_goods` distributes flagship-first,
## the same §4.2 rule the battle loot uses — plus the salvage gold in full
## (already `BattleRewards.salvage_for` money at wreck-spawn time). Overflow
## units are lost with the wreck (the hold guard, not a partial wreck).
func _collect_wrecks_at(cell: Vector2i) -> void:
	if _fleets == null or not _has_game():
		return
	var collected := false
	while true:
		var wreck: Dictionary = _fleets.wreck_at(cell)
		if wreck.is_empty():
			break
		var result: Dictionary = _fleets.collect_wreck(
			str(wreck.get("id", "")), FleetLib.fleet_free())
		if result.is_empty():
			break
		var gold := int(result.get("gold", 0))
		if gold > 0:
			GameState.add_gold(gold)
		var moved := 0
		var cargo: Dictionary = result.get("cargo", {})
		for good_id in cargo:
			moved += FleetLib.add_goods(str(good_id), int(cargo[good_id]))
		if gold > 0 or moved > 0:
			collected = true
			# The pure module never emits (docs/90-* §5.1); the host does —
			# the same convention as the battle-aftermath fleet changes.
			EventBus.fleet_changed.emit()
		# No new player-facing copy without a ui_strings key (task rule): the
		# console line mirrors the `world.sail.arrived` convention; the
		# needed key (`world.wreck.collected`, zh 捞起沉船残骸 / en Wreck
		# salvage collected) is listed in the task K report.
		print("WorldMap: wreck %s collected at %s (%d cargo units, %dg)"
			% [str(result.get("id", "")), str(cell), moved, gold])
	if collected:
		_sync_hud()
		_sync_marker_nodes()


## Centers a marker square on its tile.
func _place_marker_square(square: ColorRect, cell: Vector2i) -> void:
	square.position = Vector2(cell) * float(_cell_pixels) \
		+ (Vector2(_cell_pixels, _cell_pixels) - square.size) * 0.5


## Right-click on an adjacent fleet = attack it (docs/60-* §4.11.11.2). A
## pirate opens the battle straight away; any other fleet asks for
## `encounter.attack_confirm` first because attacking it is piracy (a
## non-pirate owner pays `Bounty.apply_piracy` at battle start).
func _try_attack(cell: Vector2i) -> bool:
	if _modal_open() or not _has_game():
		return false
	if not _is_adjacent(cell):
		return false
	var fleet: Dictionary = _fleet_at_cell(cell)
	if fleet.is_empty():
		return false
	if str(fleet.get("role", "")) != NpcFleetsLib.PIRATE:
		_open_attack_confirm(fleet)
		return true
	_attack(fleet)
	return true


## The fleet occupying `cell` ({} when none).
func _fleet_at_cell(cell: Vector2i) -> Dictionary:
	if _fleets == null:
		return {}
	return _fleets.fleet_at(cell)


## The attack confirmation (S12-style modal, `encounter.attack_confirm`):
## attacking a non-pirate fleet is piracy.
func _open_attack_confirm(fleet: Dictionary) -> void:
	if _attack_confirm != null:
		return
	var layer := get_node_or_null("AttackLayer") as CanvasLayer
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "AttackLayer"
		layer.layer = 3
		add_child(layer)
	var dialog: Control = ConfirmScene.instantiate()
	dialog.name = "AttackDialog"
	layer.add_child(dialog)
	_attack_confirm = dialog
	var nation_id := str(fleet.get("nation_id", ""))
	var nation := I18n.t(DataLoader.get_nation(nation_id).get("name", {}))
	if DataLoader.ui_strings.has("encounter.attack_confirm"):
		dialog.open_key("encounter.attack_confirm", {"nation": nation})
	else:
		# Task G owns the `encounter.*` inventory (§4.12.5); until it lands the
		# modal must still warn (piracy is a permanent −20), so it composes the
		# nation name and the existing confirm label rather than printing a
		# raw "<encounter.attack_confirm>".
		dialog.open_text(
			"%s · %s" % [nation, I18n.t_key("ui.confirm_title")],
			"ui.confirm", "ui.cancel"
		)
	dialog.confirmed.connect(func() -> void:
		_close_attack_confirm()
		_attack(fleet))
	dialog.cancelled.connect(_close_attack_confirm)


func _close_attack_confirm() -> void:
	if _attack_confirm == null:
		return
	var dialog := _attack_confirm
	_attack_confirm = null
	# Hide first: `queue_free()` is deferred, so a dialog left visible would
	# keep `_modal_open()` true for the rest of the frame (and eat the next
	# click) — a real double-input bug, not just a test artefact.
	dialog.visible = false
	dialog.remove_from_group("modal_overlay")
	dialog.queue_free()


## Attacking a national fleet is piracy: the charge itself happens in
## [_open_encounter] (once per battle at start, §4.11.11.2), so a player
## attack, a hunter contact and a chained fleet all go through one place and
## can never be charged twice. Pirates cost no reputation.
## Task K: a player-opened battle also marks [_battle_player_initiated] — the
## §4.11.11.2 loot row (actual cargo + `min(1000, 100 + 10 × day)`g) applies
## to a victory over a fleet the player attacked, never to a hostile contact.
func _attack(fleet: Dictionary) -> void:
	if fleet.is_empty():
		return
	_open_encounter(_encounter_for(fleet))
	# True only when the attack actually opened this battle (the same-id
	# guard above leaves a contact battle untouched).
	_battle_player_initiated = battle_in_progress()


## `battle_finished` handler (§4.11.11.2 + §4.10 retreat): remove the fleet,
## put the fleet back on the contact tile, and — if a second hostile fleet is
## still in contact — chain straight into that battle (§6 "battles chain").
##
## A `retreat` outcome is the exception: the enemy is not defeated, so its
## fleet stays and takes the §4.10 **+1 day pursuit cooldown** instead of
## being despawned (§4.11.11.1 inclusive reading). Spawn immunity is retired
## with the marker system (§4.11.11.1); the trickle refills the ecology.
func _on_battle_finished(outcome: Dictionary) -> void:
	if _battle_encounter.is_empty():
		return
	var fleet: Dictionary = _battle_encounter
	_battle_encounter = {}
	var day := int(GameState.day)
	var retreated := str(outcome.get("result", "")) == NpcFleetsLib.RETREAT
	var victory := str(outcome.get("result", "")) == "victory"
	# Task K (§4.11.11.2): the player-attack loot row and the privateer
	# sponsor-rival bonus apply to a *resolved victory* only — the §4.11.10
	# aftermath (salvage/XP/rep) was already applied by S10's §4.12.4 steps.
	var initiated := _battle_player_initiated
	_battle_player_initiated = false
	if _fleets != null:
		if retreated:
			# The descriptor is a copy: the cooldown must land on the stored
			# fleet, so it goes through the id lookup.
			_fleets.set_pursuit_cooldown(
				str(fleet.get("id", "")), day + NpcFleetsLib.PURSUIT_COOLDOWN_DAYS
			)
		else:
			_fleets.remove(str(fleet.get("id", "")))
	if victory:
		if initiated:
			_apply_attack_loot(fleet, day)
		if str(fleet.get("role", "")) == NpcFleetsLib.PRIVATEER:
			_apply_privateer_rival_bonus(fleet)
	# §4.10: the fleet is placed on the contact tile, which is where it
	# already stood when contact opened — re-assert it so a S10 that moved
	# the state cannot leave the fleet behind off-tile.
	_restore_fleet_tile(fleet)
	_clear_stored_pending_encounter()
	_sync_marker_nodes()

	# §6 chaining: a *different* hostile fleet still in contact opens next.
	# The fleet this battle just fought can never re-open — a retreat would
	# otherwise loop straight back into the battle the player just left.
	if GameState.current_port == null:
		var chained := _open_chained_battle(str(fleet.get("id", "")))
		if chained:
			# A chained battle is another interruption: the route stays
			# suspended and resumes when that one finishes too.
			return
	# §4.2 (task H): the battle interrupted a click route — recompute the rest
	# of it toward the original target from wherever the fleet stands now and
	# keep walking. Disabled routing never reaches here mid-route, and a route
	# whose target became unreachable is simply dropped.
	_resume_sail_order()


## The §4.11.11.2 player-attack loot row (task K): actual cargo +
## `min(1000, 100 + 10 × day)`g. **Coaster exception** (§4.1.1's more
## specific row): a coaster's tiny hold (≤ 10) pays its own pin,
## `25 + floor(day / 10)`g, instead of the general gold. The cargo is the
## fleet's own saved hold — not the §4.11.3 per-ship rolls — distributed
## flagship-first through the same pooled-hold rule the battle loot uses
## (`Fleet.add_goods`); overflow units are lost.
func _apply_attack_loot(fleet: Dictionary, day: int) -> void:
	var gold := mini(1000, 100 + 10 * maxi(day, 0))
	if str(fleet.get("role", "")) == "coaster":
		gold = 25 + int(floor(float(maxi(day, 0)) / 10.0))
	if gold > 0:
		GameState.add_gold(gold)
	var cargo = fleet.get("cargo", {})
	var moved := 0
	if cargo is Dictionary:
		for good_id in (cargo as Dictionary):
			moved += FleetLib.add_goods(str(good_id),
				maxi(int((cargo as Dictionary)[good_id]), 0))
	if gold > 0 or moved > 0:
		EventBus.fleet_changed.emit()


## §4.1.1/`70-*` §4.5 (task K): defeating a privateer pays `+2` reputation
## with **each of the two sponsor rivals** — the nations whose shipping it
## was preying on — on top of the normal battle rep rules. The +2 is
## `Bounty.RIVAL_REPUTATION` (the pinned funnel delta), applied through the
## clamped `Character.add_reputation`.
func _apply_privateer_rival_bonus(fleet: Dictionary) -> void:
	var sponsor := str(fleet.get("nation_id", ""))
	if sponsor.is_empty():
		return
	for rival in BountyLib.rivals(sponsor):
		var rival_id := str(rival)
		if rival_id.is_empty():
			continue
		CharacterLib.add_reputation(rival_id, BountyLib.RIVAL_REPUTATION)


## Recomputes a battle-suspended route toward its original target and resumes
## the cadence (§4.2 "re-computes remaining path after dismissal"). Any manual
## input in between cancelled the order, in which case there is nothing to do.
func _resume_sail_order() -> void:
	if not _sail_suspended:
		return
	_sail_suspended = false
	var target := _sail_target
	if target == Vector2i(-1, -1) or _loader == null:
		_cancel_sail_order()
		return
	var remaining: Array[Vector2i] = _sail_compute(target)
	if remaining.is_empty():
		_cancel_sail_order()
		return
	_sail_path = remaining
	_sail_elapsed = 0.0


## Restores the fleet to the battle's contact tile.
func _restore_fleet_tile(marker: Dictionary) -> void:
	var contact = marker.get("contact", null)
	var tile := GameState.world_tile()
	if contact is Dictionary:
		tile = Vector2i(int(contact.get("x", tile.x)), int(contact.get("y", tile.y)))
	GameState.set_world_tile(tile)
	_fleet_cell = tile
	_place_marker()
	_update_camera()


## Opens the next hostile fleet in range after a battle ends (§6 chaining),
## skipping `exclude_id` — the fleet whose battle just finished. Returns true
## when a battle was opened (the caller keeps a sail route suspended).
func _open_chained_battle(exclude_id: String = "") -> bool:
	if _fleets == null:
		return false
	for fleet in _fleets.contacts(GameState.world_tile()):
		if str(fleet.get("id", "")) == exclude_id:
			continue
		_open_encounter(_encounter_for(fleet))
		return true
	return false


# --- `GameState.pending_encounter` (docs/60-* §4.11.11.3) ------------------

## `GameState.pending_encounter` is the §4.11.11.3 handoff field. It is declared
## by docs/90-* §5.4 with the rest of the Phase-2 state, so access goes through
## `set`/`get` and the scene keeps a mirror until the field exists: a missing
## property on this base must not break contact handling.
func _stored_pending_encounter():
	var value = GameState.get("pending_encounter")
	return value if value is Dictionary else null


func _store_pending_encounter(encounter: Dictionary) -> void:
	_pending_encounter = encounter.duplicate(true)
	GameState.set("pending_encounter", encounter.duplicate(true))


func _clear_stored_pending_encounter() -> void:
	# §4.11.11.3: the handoff is consumed at battle start; from the world side
	# that is when the battle *finishes* (or a chained battle replaces it).
	_pending_encounter = {}
	GameState.set("pending_encounter", null)


## The id of the battle currently in progress ("" when none).
func _battle_encounter_id() -> String:
	return str(_battle_encounter.get("id", ""))


## The scene this entry would route to (`""` when none is pending). Tests read
## this instead of letting the router swap their own scene root.
func port_route_target() -> String:
	if _pending_port_id.is_empty():
		return ""
	if not ResourceLoader.exists(PORT_SCENE):
		return ""
	return PORT_SCENE


## §4.5 steps 3–6 produce their reports here, in the §4.7 fixed order. Step 3
## already ran (storm damage is applied in the ledger); this only *reports* it,
## then appends the sim's own entries (mutiny, ship lost, …) which step 6 sorted
## into `last_day_dialogs`, and finally the arrival greeting.
func _on_day_advanced(_new_day: int) -> void:
	if not _has_game():
		return
	# Phase 5 task J (docs/20-* §4.3 step 4): the NPC fleet tick runs once per
	# day as this post-`day_advanced` listener (after the ledger and the
	# economy step, which precede the emit); the sim's `last_tick_day` dedupe
	# keeps it idempotent. It needs a living player and no game-over overlay —
	# `_tick_fleets_day()` re-checks both conditions itself.
	_tick_fleets_day()
	# Phase 3: quest expiry / cargo failures, royal-mission expiry and the
	# bounty re-evaluation (`70-*` §4.9.3–§4.9.5).
	var phase3: Dictionary = Phase3HooksLib.on_day_tick(int(GameState.day))
	# A fatal tick emits `game_over` *inside* the ledger, i.e. before this
	# signal: S9 already owns the screen, so the dead day's reports must not be
	# queued underneath it (§4.7 "never simultaneously").
	if SailingSimLib.is_game_over() or game_over_open():
		SailingSimLib.take_last_day_dialogs()
		return
	var entries: Array = []
	# 1. Weather damage (§4.7 first in the queue).
	if SailingSimLib.was_storm_last_day() and not SailingSimLib.last_day_storm_damage.is_empty():
		entries.append({
			"kind": "weather", "key": "world.storm_notice",
			"values": {"weather": I18n.t_key("world.weather.storm")},
		})
		for hit in SailingSimLib.last_day_storm_damage:
			var ship_type: Dictionary = DataLoader.get_ship_type(
				str(hit.get("ship_type_id", ""))
			)
			entries.append({
				"kind": "weather", "key": "world.storm_damage",
				"values": {
					"name": I18n.t(ship_type.get("name", {})),
					"points": int(hit.get("points", 0)),
				},
			})
	# Phase-3 quest failures (`70-*` §4.9.3: −5 rep, no fame).
	for quest in (phase3.get("failed_quests", []) as Array):
		entries.append({
			"kind": "quest", "key": "quest.failed",
			"values": {"name": _quest_name(quest)},
		})
	# 2. / 3. Mutiny and any other sim-raised entry (already ordered); the
	# desertion entry belongs to port entry (§4.8.2) and the greeting to the
	# port-entry sequence, so neither is produced here.
	entries.append_array(SailingSimLib.take_last_day_dialogs())
	_show_dialog_entries(entries)


## §4.8.3 mutiny resolution: the HUD reports which button was pressed; the sim
## owns every state change, so the scene stays a thin adapter. A resolution can
## raise its own report (the fizzle message), which is flushed right away.
func _on_mutiny_choice(choice: String) -> void:
	match choice:
		"pay":
			SailingSimLib.resolve_mutiny_pay()
		"suppress":
			SailingSimLib.resolve_mutiny_suppress()
		_:
			SailingSimLib.resolve_mutiny_fizzle()
	_sync_hud()
	# A resolution changes morale without a matching EventBus signal (there is
	# no `morale_changed` in docs/90-* §5.1), so the host performs the one
	# explicit refresh the HUD contract allows (docs/80-* §7).
	if _hud != null and _hud.has_method("refresh"):
		_hud.refresh()
	_show_dialog_entries(SailingSimLib.take_last_day_dialogs())


## §4.9 sea death: show S9 over the map (docs/80-* §4.1/§4.2). No save is
## written or deleted; S9 routes back to the title on any key.
## Phase 3 (`70-*` §4.9.3): every cargo mutation emits `fleet_changed`, so this
## is the "immediate failure" check for a delivery whose goods were sold,
## jettisoned or captured. The day tick still re-checks as a safety net.
func _on_fleet_changed() -> void:
	if not _has_game():
		return
	var failed: Array = Phase3HooksLib.on_cargo_changed()
	if failed.is_empty():
		return
	var entries: Array = []
	for quest in failed:
		entries.append({
			"kind": "quest", "key": "quest.failed",
			"values": {"name": _quest_name(quest)},
		})
	_show_dialog_entries(entries)


func _on_game_over(reason: String) -> void:
	if _gameover != null:
		return
	# A dead run's pending reports (storm damage, mutiny, desertion) must not
	# sit under S9 — the screen is terminal (§4.7 "never simultaneously").
	_pending_port_id = ""
	if _hud != null and _hud.has_method("clear_dialogs"):
		_hud.clear_dialogs()
	var layer := get_node_or_null("GameOverLayer") as CanvasLayer
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "GameOverLayer"
		# Above the HUD (layer 1) and the error overlay (layer 2): S9 is the
		# topmost thing on a dead run.
		layer.layer = 3
		add_child(layer)
	_gameover = GameOverScene.instantiate()
	_gameover.name = "GameOverScreen"
	layer.add_child(_gameover)
	_gameover.open_reason(reason)


## True once S9 is on screen (a fatal tick raises it before `day_advanced`).
func game_over_open() -> bool:
	return _gameover != null and _gameover.is_open()


## Chebyshev 1, **wrap-aware on x** (§4.1): x = 2159 and x = 0 are neighbours.
func _is_adjacent(target: Vector2i) -> bool:
	var dx := absi(target.x - _fleet_cell.x)
	if _loader != null and _loader.width > 0:
		dx = mini(dx % _loader.width, _loader.width - (dx % _loader.width))
	return maxi(dx, absi(target.y - _fleet_cell.y)) == 1


## Input is ignored while any modal is open (docs/90-* §11 "port entered while
## a dialog is open cannot occur": dialogs are modal, movement is disabled).
func _modal_open() -> bool:
	# HUD-hosted queued dialogs.
	if _hud != null and _hud.has_method("has_modal") and _hud.has_modal():
		return true
	# The enlarged chart (`M`, docs/80-* §4.3) is a modal overlay: the fleet
	# must not step behind it, and `M`/Esc close it before movement resumes.
	if _hud != null and _hud.has_method("is_minimap_enlarged") \
			and _hud.is_minimap_enlarged():
		return true
	# Any dialog instance anywhere in the tree joins `modal_overlay` while open.
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			return true
	# The S14 character panel is a Control, not a dialog (T16 owns it).
	var panel := get_node_or_null("CharacterPanelLayer/CharacterPanel")
	if panel != null and panel.has_method("is_open") and panel.is_open():
		return true
	# The T18 fleet panel is the same kind of Control modal (read-only at sea).
	var fleet_panel := get_node_or_null("FleetPanelLayer/FleetPanel")
	if fleet_panel != null and fleet_panel.has_method("has_modal") \
			and fleet_panel.has_modal():
		return true
	return false


# --- Sighting & exploration (docs/20-* §4.11, §4.12) -----------------------

## Reveals every port within the sighting radius (Chebyshev, **wrap-aware on
## x**, docs/20-* §4.11) and marks the square explored for the minimap (§4.12).
## Both loops wrap: a fleet at `x = 2159` sees `x = 0` and the explored square
## continues across the seam instead of clipping.
func _reveal() -> void:
	if _loader == null:
		return
	var radius := CharacterLib.sighting_radius() if _has_game() else BASE_SIGHTING_RADIUS
	var known_before := GameState.known_ports.size()
	for port_id in _loader.harbor_tiles():
		var port_cell: Vector2i = _loader.port_cell(str(port_id))
		if port_cell.x < 0:
			continue
		if _loader.chebyshev(port_cell, _fleet_cell) > radius:
			continue
		if not GameState.known_ports.has(str(port_id)):
			GameState.known_ports.append(str(port_id))

	for dy in range(-radius, radius + 1):
		var y := _fleet_cell.y + dy
		if y < 0 or y >= _loader.height:
			continue
		for dx in range(-radius, radius + 1):
			var x := posmod(_fleet_cell.x + dx, _loader.width)
			GameState.explored_tiles[Vector2i(x, y)] = true
	# A sighting pass is the only thing that adds known ports, so the overlay is
	# refreshed exactly when its inputs changed (docs/90-* §9 step 5).
	if GameState.known_ports.size() != known_before:
		_loader.refresh_port_overlay(DataLoader.ports, DataLoader.nations)


# --- Marker & camera -------------------------------------------------------

func _place_marker() -> void:
	# 24×24 white square, black outline (docs/80-* §4.8): the marker node is
	# centered on the tile it occupies.
	_fleet_marker.position = Vector2(_fleet_cell) * float(_cell_pixels) \
		+ Vector2(_cell_pixels, _cell_pixels) * 0.5


## Centers the camera on the fleet (which wraps) and refreshes the chunk ring.
## The camera's own y is clamped to the map height; x is **not** clamped — the
## camera is always centred on the fleet and the chunk layer repeats the grid
## across the seam (docs/80-* §4.5 "wrap at dateline: no clamp, no void").
func _update_camera() -> void:
	_camera.position = _clamp_to_map(_camera_target())
	_update_chunks()


## The camera centre for the fleet's tile.
func _camera_target() -> Vector2:
	# Cell coordinates name a tile; the camera aims at that tile's center.
	return Vector2(_fleet_cell.x * _cell_pixels, _fleet_cell.y * _cell_pixels) \
		+ Vector2(_cell_pixels, _cell_pixels) * 0.5


## Clamps **y only** and leaves x at whatever the target says (the world wraps
## east–west). Public for `tools/test_movement.gd`'s corner checks.
func _clamp_to_map(target: Vector2) -> Vector2:
	var half_view := get_viewport_rect().size * 0.5 / _camera.zoom
	var out := target
	if _map_pixels.y <= half_view.y * 2.0:
		out.y = _map_pixels.y * 0.5
	else:
		out.y = clampf(target.y, half_view.y, _map_pixels.y - half_view.y)
	return out


## Spawns/frees chunks around the camera. The viewport size is converted to
## tiles so the loader's 24-chunk ring covers the whole 1280×720 view.
func _update_chunks() -> void:
	if _loader == null or _chunks_root == null:
		return
	var view := get_viewport_rect().size / float(_cell_pixels)
	var view_tiles := Vector2i(int(ceil(view.x)) + 2, int(ceil(view.y)) + 2)
	var center := _camera.position / float(_cell_pixels)
	_loader.update_chunks(
		Vector2i(int(floor(center.x)), int(floor(center.y))), view_tiles
	)


# --- State helpers ---------------------------------------------------------

func _has_game() -> bool:
	return not GameState.player.is_empty()


## Initialises the movement keys of `GameState.world` when they are absent
## (fresh scene, or a hand-built state in a test). Never overwrites a value.
func _ensure_world_state() -> void:
	if not GameState.world.has("map_id"):
		GameState.world["map_id"] = _active_map_id()
	if not GameState.world.has("position"):
		GameState.set_world_tile(_fallback_cell())
	if not GameState.world.has("clock_fraction"):
		GameState.world["clock_fraction"] = 0.0
	if not GameState.world.has("weather"):
		# §4.7 weather is rolled by the daily ledger (T7/T8); "calm" until then.
		GameState.world["weather"] = SailingSimLib.DEFAULT_WEATHER


## The pre-run parking cell: Lisbon's derived berth tile, else any harbour the
## map resolves, else the grid centre. Editor inspection only; a real run always
## has a `world.position`.
func _fallback_cell() -> Vector2i:
	if _loader != null and _loader.width > 0:
		var lisbon: Vector2i = _loader.port_cell("lisbon")
		if lisbon != Vector2i(-1, -1):
			return lisbon
		for port_id in _loader.harbor_tiles():
			return _loader.port_cell(str(port_id))
		return Vector2i(_loader.width / 2, _loader.height / 2)
	return FALLBACK_CELL


func _read_state_cell() -> Vector2i:
	if not _has_game() and GameState.world.is_empty():
		return _fallback_cell()
	return GameState.world_tile()


## Cell under a world position. x **wraps** (a click at `x = 2160` is a click
## on `x = 0`, docs/20-* §4.1) and y is left unbounded for the caller to reject.
func _cell_at(world_position: Vector2) -> Vector2i:
	var x := int(floor(world_position.x / float(_cell_pixels)))
	var y := int(floor(world_position.y / float(_cell_pixels)))
	if _loader != null and _loader.width > 0:
		x = posmod(x, _loader.width)
	return Vector2i(x, y)


## A quest's display name: the stored instance has no L10nString (it is
## generated), so the objective line is composed from its type
## (`quest.line.*`, `70-*` §4.9.3 / `80-*` §4.7.4).
## The composed quest line for a dialog. Delegates to the shared composer so a
## quest reads identically on the world map, in the guild and in the panel
## (`QuestGen.objective_text`, `80-*` §4.7.4); an exploration quest also shows
## its hint, which is what the player needs at sea.
func _quest_name(quest) -> String:
	if not (quest is Dictionary):
		return ""
	var q: Dictionary = quest
	var text := QuestGenLib.objective_text(q)
	if str(q.get("type", "")) == "exploration":
		var discovery_id := str((q.get("requirements", {}) as Dictionary)
			.get("discovery_id", ""))
		if not discovery_id.is_empty():
			text = "%s — %s" % [text, I18n.t(
				DataLoader.get_discovery(discovery_id).get("region_hint", {}))]
	return text


## Position-derived HUD bits only (area label + minimap dot). The bars are
## signal-driven and are never refreshed from the movement path, so a move
## cannot poll (`docs/80-*` §7 acceptance).
func _sync_hud() -> void:
	if _hud == null:
		return
	if _hud.has_method("set_fleet_cell"):
		_hud.set_fleet_cell(_fleet_cell)
	if _hud.has_method("set_explore_available"):
		_hud.set_explore_available(something_near())


func _is_loaded() -> bool:
	return _loader != null and not _map_pixels.is_zero_approx()


## Data error path (docs/90-* §11): print the reason and show it centered
## instead of crashing; the rest of the app stays usable.
func _show_error(reason: String) -> void:
	var detail := reason
	if detail.is_empty():
		detail = " / ".join(DataLoader.load_errors)
	if detail.is_empty():
		detail = str(DataLoader.get_map(DEFAULT_MAP_ID).get("file", ""))
	push_error("WorldMap: cannot load the world map: " + detail)
	var text := "Data error: %s" % detail
	# Autoloads are lookup-by-name so this also survives a partial autoload set
	# (the same defensive pattern I18n uses for GameState).
	var i18n := get_node_or_null("/root/I18n")
	if i18n != null and i18n.has_method("fmt"):
		text = i18n.fmt("title.data_error", {"reason": detail})
	_error_label.text = text
	_error_label.add_theme_color_override("font_color", PaletteLib.BAD)
	_error_layer.visible = true
