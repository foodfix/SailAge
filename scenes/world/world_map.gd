extends Node2D
## World map scene (S3) — docs/80-UI-UX.md §4.1–§4.5; docs/20-* §4.1–§4.3,
## §4.11–§4.12; docs/90-ARCHITECTURE.md §7, §9.
##
## T5 built the ASCII→TileMap rendering and the clamped camera; T6 adds the
## fleet marker, movement input (keys + click-to-step, no corner cutting), the
## sighting/exploration reveal, port entry and the shared HUD.
##
## The map is never re-parsed here: the scene asks MapLoader once and lets it
## build the TileMap (docs/90-* §9 step 6). Movement rules live in
## `scripts/world/sailing_sim.gd` (unit-testable); this scene only turns input
## into `SailingSimLib.try_move()` calls and keeps the view/UI in sync.
##
## Before a run exists (`GameState.player` empty) the scene is still usable: it
## parks the fleet on Lisbon's harbor tile and the HUD renders "-" for values
## it cannot know (docs/IMPLEMENT-Phase1.md T6-D).

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const CharacterPanelLib := preload("res://scenes/ui_shared/character_panel.gd")
## T18: fleet/cargo panel (read-only at sea, docs/40 §4.4).
const FleetPanelLib := preload("res://scenes/ui_shared/fleet_panel.gd")
const GameOverScene := preload("res://scenes/ui_shared/gameover_screen.tscn")
## Phase-2 F: hostile marker spawning/movement/contact (docs/60-* §4.1).
const EncountersLib := preload("res://scripts/world/encounters.gd")
const ConfirmScene := preload("res://scenes/ui_shared/confirm_dialog.tscn")

## Phase-1 map file (docs/10-* §6.1). Swapping maps is a data-only change:
## the active map is `GameState.world["map_id"]` resolved through
## `data/maps/maps.json` (docs/90-* §9.1).
const MAP_PATH := "res://data/maps/p1_mediterranean.txt"
## Overridable copy of [constant MAP_PATH]: a different legend-conformant map
## file is a data-only swap (docs/90-* §9 last paragraph), so the path is an
## inspector property rather than a hard-coded read. An empty value means
## "resolve `GameState.world.map_id` through the map index".
@export var map_path: String = ""
## Fallback cell before a game exists (Lisbon's harbor tile on the P1 map).
const FALLBACK_CELL := Vector2i(7, 57)
## `world.map_id` when neither the state nor the index names one.
const DEFAULT_MAP_ID := "p1"

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
## Base sighting radius used before a character exists (docs/20-* §4.11).
const BASE_SIGHTING_RADIUS := 8

@onready var _camera: Camera2D = $Camera2D
@onready var _fleet_marker: Node2D = $FleetMarker
@onready var _error_layer: CanvasLayer = $Overlay
@onready var _error_label: Label = $Overlay/ErrorLabel
@onready var _hud: Control = get_node_or_null("HUDLayer/HUD")

var _loader = null
var _map_pixels := Vector2.ZERO
var _cell_pixels := 32
## Marker cell. Mirrors `GameState.world_tile()` once a run exists, and is the
## Lisbon fallback before that.
var _fleet_cell := FALLBACK_CELL
## One-shot guard so repeated blocked clicks log once instead of spamming.
var _reject_logged := false
## Port entry waiting for the §4.7 dialog chain to finish before routing (S4).
var _pending_port_id: String = ""
## The S9 overlay (null until a game over fires).
var _gameover: Control = null
## Phase-2 F: hostile markers (docs/60-* §4.11.11). Created in `_ready` and
## seeded from `GameState.hostile_fleets` — never re-rolled on scene open.
var _encounters = null
## Marker id → the placeholder `ColorRect` drawn for it (`80-*` §4.8).
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


func _ready() -> void:
	_loader = MapLoaderLib.new()
	var loaded: bool = _load_active_map()
	# Handoff for DataLoader.is_passable()/port_id_at() (docs/90-* §5.2, §9).
	DataLoader.map = _loader if loaded else null

	if not loaded:
		_fleet_marker.visible = false
		_show_error(_loader.last_error)
		return

	_map_pixels = Vector2(_loader.width * _loader.tile_size_px, _loader.height * _loader.tile_size_px)
	_cell_pixels = _loader.tile_size_px
	_loader.build_tilemap(self, DataLoader.ports, DataLoader.nations)
	_error_layer.visible = false
	_fleet_marker.z_index = 10

	# World state defaults so movement works even before a new game (T6-D).
	_ensure_world_state()
	_fleet_cell = _read_state_cell()
	_place_marker()

	_camera.zoom = Vector2.ONE
	_camera.make_current()
	_update_camera()

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
	if _hud != null:
		_hud.mutiny_choice.connect(_on_mutiny_choice)
		_hud.dialogs_finished.connect(_on_dialogs_finished)

	# Phase-2 F: hostile markers (docs/60-* §4.1, §4.11.11). The scene only
	# *adopts* the saved markers here — `Encounters` is told which day already
	# ticked so re-opening the map cannot re-roll or re-move them (§4.11.11.2).
	_init_encounters()
	# `battle_finished` is declared by docs/90-* §5.1; the connect is guarded by
	# `has_signal` so this scene also runs on a base whose EventBus predates the
	# Phase-2 signals (the `ResourceLoader.load` + `has_method` convention).
	if EventBus.has_signal("battle_finished"):
		EventBus.battle_finished.connect(_on_battle_finished)


## The map this scene renders: the `map_path` inspector override when set,
## else `GameState.world.map_id` resolved through the map index
## (docs/90-* §9.1). Both the text file and its legend come from the index, so
## swapping to the Phase-3 world is a data-only change.
func _load_active_map() -> bool:
	var map_id := _active_map_id()
	if not map_path.is_empty():
		return _loader.load_map(map_path, DataLoader.get_map_legend(map_id))
	var files: Dictionary = DataLoader.get_map_files(map_id)
	if files.is_empty():
		return _loader.load_map(MAP_PATH, DataLoader.map_legend)
	var path := str(files.get("file", ""))
	if not path.begins_with("res://"):
		path = "res://" + path
	var legend = files.get("legend", {})
	if not (legend is Dictionary) or (legend as Dictionary).is_empty():
		return _loader.load_map(MAP_PATH, DataLoader.map_legend)
	return _loader.load_map(path, legend)


## The active map id: `GameState.world.map_id`, else the index's first entry.
## A save written before Phase 3 has no id, which reads as `p1`.
func _active_map_id() -> String:
	var value = GameState.world.get("map_id", DEFAULT_MAP_ID)
	if value is String and not (value as String).is_empty():
		return value
	return DEFAULT_MAP_ID


func _process(_delta: float) -> void:
	if _loader == null or not _is_loaded():
		return
	_update_camera()


func _unhandled_input(event: InputEvent) -> void:
	if not _is_loaded():
		return
	# Click-to-step on an adjacent tile (docs/80-* §4.3). The HUD is
	# mouse-transparent, so clicks land here; a modal consumes them first.
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
			# Right-click on an adjacent hostile marker = attack (§4.1).
			if _modal_open():
				return
			if _try_attack(_cell_at(get_global_mouse_position())):
				get_viewport().set_input_as_handled()
			return
		if mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
			if _modal_open():
				return
			var target := _cell_at(get_global_mouse_position())
			if _is_adjacent(target) and _try_step(target):
				get_viewport().set_input_as_handled()
		return

	for action in MOVE_ACTIONS:
		if event.is_action_pressed(action):
			if _modal_open():
				return
			get_viewport().set_input_as_handled()
			_try_step(_fleet_cell + MOVE_ACTIONS[action])
			return


# --- Public API (hosts and tools/test_movement.gd) -------------------------

## Moves the fleet one tile if the move is legal. Rejected moves (land, reef,
## out of bounds, corner cut) leave position **and** clock untouched (§4.2).
## Returns true when the fleet actually stepped.
func try_step(target: Vector2i) -> bool:
	return _try_step(target)


## Current fleet cell (the marker source of truth).
func fleet_cell() -> Vector2i:
	return _fleet_cell


## Re-reads `GameState.world.position` (returning from port, save load, tests).
func sync_from_state() -> void:
	if _loader == null or not _is_loaded():
		return
	_fleet_cell = _read_state_cell()
	_place_marker()
	_update_camera()
	_reveal()
	_sync_hud()
	# A save load replaces `hostile_fleets` wholesale; redraw to it.
	_sync_marker_nodes()


## Map size in pixels, for camera tests.
func map_pixels() -> Vector2:
	return _map_pixels


## World-space rect currently visible through the clamped camera.
func visible_world_rect() -> Rect2:
	var half_view := get_viewport_rect().size * 0.5 / _camera.zoom
	var center := _camera.position
	return Rect2(center - half_view, half_view * 2.0)


# --- Movement (docs/20-* §4.1, §4.2, §6) -----------------------------------

func _try_step(target: Vector2i) -> bool:
	if _loader == null or _modal_open():
		return false
	if not _is_adjacent(target):
		# Clicking a non-adjacent tile is a no-op, not a rejected move: no
		# feedback, no clock (±0 tiles is not a "move" at all).
		return false
	if not SailingSimLib.is_move_legal(_fleet_cell, target, _loader):
		_reject_move(target)
		return false

	# Leaving a harbor tile: at sea again (docs/20-* §4.11 exit).
	GameState.current_port = null

	if _has_game():
		# Applies the tile + `1/effective_speed` days + day-boundary loop.
		SailingSimLib.try_move(target, _loader, _fleet_cell)
	else:
		# No run yet: step for inspection, but no game clock exists to advance.
		GameState.set_world_tile(target)

	_reject_logged = false
	_fleet_cell = target
	_place_marker()
	_update_camera()
	_reveal()
	_sync_hud()

	var port_id: String = _loader.port_id_at(target)
	if not port_id.is_empty():
		_enter_port(port_id)
		return true
	# docs/60-* §4.11.11.1: contact is measured after the player move — a step
	# onto a tile beside a hostile marker opens the battle now. S10 owns the
	# screen from here, so nothing else may run on top of it.
	_tick_encounters()
	return true


## Docs/20-* §4.2/§6: a blocked move is silent and costs nothing; a brief toast
## is the only feedback (never a modal).
func _reject_move(_target: Vector2i) -> void:
	if _reject_logged:
		return
	_reject_logged = true
	# `world.move_blocked` is proposed in the T6 report; until the orchestrator
	# merges it into data/ui_strings.json toast_key() returns false and the
	# rejection stays console-only (logged once per scene, never a modal).
	if _hud != null and _hud.toast_key("world.move_blocked"):
		return
	print("WorldMap: move rejected (land/reef/edge/corner cut); no clock cost")


## Port entry (docs/20-* §4.11, in the doc's numbered order):
##   1. the harbor tile's move + clock cost (already applied by [_try_step]);
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

	# 3. §4.8.2 desertion on **every** port entry (morale < 40). The sim owns
	# the loss; this scene owns the message, queued in §4.7 order with the
	# greeting (weather/mutiny entries from the same tick are already queued
	# and sort ahead of these).
	var entries: Array = []
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


# --- Hostile markers (docs/60-* §4.1, §4.8, §4.11.11) ----------------------

## Creates the marker module and adopts the saved markers. No roll and no
## movement happens here: `Encounters` starts on `GameState.day`, i.e. "this
## day's tick already happened", so opening the map (or saving/loading) can
## never spawn or herd a fleet (§4.11.11.2 "at each day tick").
func _init_encounters() -> void:
	if _encounters == null:
		_encounters = EncountersLib.new(GameState.day)
	_sync_marker_nodes()


## The marker module (public so a test can seed/observe it without a scene).
func encounters():
	return _encounters


## Cells of every live hostile marker, `[{"id","kind","nation_id","cell"}]`,
## sorted by id. The test seam for "markers moved/died as expected".
func hostile_marker_cells() -> Array:
	var out: Array = []
	if _encounters == null:
		return out
	var entries: Array = _encounters.markers()
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("id", "")) < str(b.get("id", "")))
	for marker in entries:
		out.append({
			"id": str(marker.get("id", "")),
			"kind": str(marker.get("kind", "")),
			"nation_id": str(marker.get("nation_id", "")),
			"cell": EncountersLib.position_of(marker),
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


## One day tick for the markers. Called after a successful player step and from
## `day_advanced`, in that order (§4.11.11.1 "after both the player move and the
## marker step"); `Encounters` itself collapses repeats within one day.
func _tick_encounters() -> void:
	if _encounters == null:
		return
	if not _has_game() or game_over_open() or SailingSimLib.is_game_over():
		return
	_tick_encounters_at(GameState.current_port == null)


## The tick with an explicit at-sea flag (a test can drive either branch).
func _tick_encounters_at(is_at_sea: bool) -> void:
	if _encounters == null:
		return
	var contacted: Array = _encounters.tick(is_at_sea)
	_sync_marker_nodes()
	if contacted.is_empty():
		return
	var encounter: Dictionary = _encounter_for(contacted[0])
	_open_encounter(encounter)


## A marker in contact is opened as a battle (docs/60-* §4.1, §4.11.11.3).
## The encounter queued on `GameState.pending_encounter` carries the marker's
## saved fields unchanged — including its §4.11.3 `ships`, so S10 fights
## exactly the composition the marker had.
func _encounter_for(marker: Dictionary) -> Dictionary:
	var encounter := marker.duplicate(true)
	encounter["contact"] = {
		"x": GameState.world_tile().x, "y": GameState.world_tile().y,
	}
	return encounter


## Queues `encounter` on `GameState.pending_encounter`, emits `battle_started`
## once and routes to S10 when this scene is the active one and routing is on.
## The pending slot is consumed at battle start, so a re-entrant contact cannot
## open two battles (§4.11.11.3).
##
## The navy piracy delta is charged **here**, exactly once per navy battle
## (`60-*` §4.11.10: "exactly one −20 per navy battle … at battle start … or on
## contact with a hunter"; never per ship, never again at battle end). Doing it
## in this single funnel — behind the same-id guard above — is what makes a
## double charge impossible by construction, whichever path opened the battle:
## the player's attack, a hunter making contact, or a chained second marker.
func _open_encounter(encounter: Dictionary) -> void:
	if encounter.is_empty():
		return
	if _battle_encounter_id() == str(encounter.get("id", "")) \
			and not _battle_encounter.is_empty():
		return
	_battle_encounter = encounter.duplicate(true)
	_charge_navy_piracy(encounter)
	_store_pending_encounter(encounter)
	if EventBus.has_signal("battle_started"):
		EventBus.battle_started.emit(encounter)
	_route_to_battle()


## `rep −20` with the navy's nation, once, for a navy battle (`60-*` §4.11.10,
## `70-*` §4.5). Pirates cost no reputation (§4.1).
func _charge_navy_piracy(encounter: Dictionary) -> void:
	if str(encounter.get("kind", "")) != EncountersLib.NAVY:
		return
	var nation_id := str(encounter.get("nation_id", ""))
	if nation_id.is_empty():
		return
	CharacterLib.add_reputation(nation_id, EncountersLib.PIRACY_REPUTATION)


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


## Redraws the marker squares to match `GameState.hostile_fleets` (docs/80-*
## §4.8 placeholder art: a flat ColorRect per marker, no textures).
func _sync_marker_nodes() -> void:
	if _loader == null or not _is_loaded():
		return
	if _marker_root == null:
		_marker_root = Node2D.new()
		_marker_root.name = "HostileMarkers"
		_marker_root.z_index = 9
		add_child(_marker_root)
	var live: Dictionary = {}
	var entries: Array = _encounters.markers() if _encounters != null else []
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
		square.color = EncountersLib.marker_color(
			str(marker.get("kind", "")), str(marker.get("nation_id", ""))
		)
		_place_marker_square(square, EncountersLib.position_of(marker))
	for id in _marker_nodes.keys():
		if live.has(id):
			continue
		var dead: ColorRect = _marker_nodes[id]
		_marker_nodes.erase(id)
		dead.queue_free()


## Centers a marker square on its tile.
func _place_marker_square(square: ColorRect, cell: Vector2i) -> void:
	square.position = Vector2(cell) * float(_cell_pixels) \
		+ (Vector2(_cell_pixels, _cell_pixels) - square.size) * 0.5


## Right-click on an adjacent hostile marker = attack it (docs/60-* §4.1). A
## pirate opens the battle straight away; a navy asks for
## `encounter.attack_confirm` first because attacking it is piracy (§4.11.10).
func _try_attack(cell: Vector2i) -> bool:
	if _modal_open() or not _has_game():
		return false
	if not _is_adjacent(cell):
		return false
	var marker: Dictionary = _marker_at(cell)
	if marker.is_empty():
		return false
	if str(marker.get("kind", "")) == EncountersLib.NAVY:
		_open_attack_confirm(marker)
		return true
	_attack(marker)
	return true


## The marker occupying `cell` ({} when none).
func _marker_at(cell: Vector2i) -> Dictionary:
	if _encounters == null:
		return {}
	for marker in _encounters.markers():
		if marker is Dictionary and EncountersLib.position_of(marker) == cell:
			return marker
	return {}


## The navy attack confirmation (S12-style modal, `encounter.attack_confirm`).
func _open_attack_confirm(marker: Dictionary) -> void:
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
	var nation_id := str(marker.get("nation_id", ""))
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
		_attack(marker))
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


## Attacking a navy marker is piracy: `rep −20` with that nation
## (§4.11.10, `70-*` §4.5, `encounter.attack_confirm` copy). The charge itself
## happens in [_open_encounter], so a player attack, a hunter contact and a
## chained marker all go through one place and can never be charged twice.
## Pirates cost no reputation.
func _attack(marker: Dictionary) -> void:
	if marker.is_empty():
		return
	_open_encounter(_encounter_for(marker))


## `battle_finished` handler (§4.11.10 "Return" + §4.10 retreat): remove the
## marker, set the kind's 3-day spawn immunity, put the fleet back on the
## contact tile, and — if a second marker is still in contact — chain straight
## into that battle (§6 "battles chain").
##
## A `retreat` outcome is the exception: the enemy is not defeated, so its
## marker stays on the map and takes the §4.10 **+1 day pursuit cooldown**
## instead of despawning (§4.11.10's "marker is removed" belongs to the
## aftermath of a resolved battle).
func _on_battle_finished(outcome: Dictionary) -> void:
	if _battle_encounter.is_empty():
		return
	var marker: Dictionary = _battle_encounter
	_battle_encounter = {}
	var kind := str(marker.get("kind", ""))
	var day := int(GameState.day)
	var retreated := str(outcome.get("result", "")) == EncountersLib.RETREAT
	if _encounters != null:
		if not kind.is_empty():
			_encounters.set_cooldown(kind, day + EncountersLib.SPAWN_IMMUNITY_DAYS)
		if retreated:
			# The descriptor is a copy: the cooldown must land on the stored
			# marker, so it goes through the id lookup.
			_encounters.set_pursuit_cooldown(
				str(marker.get("id", "")), day + EncountersLib.PURSUIT_COOLDOWN_DAYS
			)
		else:
			_encounters.remove(str(marker.get("id", "")))
	# §4.10/§4.11.10: the fleet is placed on the contact tile, which is where
	# it already stood when contact opened — re-assert it so a S10 that moved
	# the state cannot leave the marker behind off-tile.
	_restore_fleet_tile(marker)
	_clear_stored_pending_encounter()
	_sync_marker_nodes()

	# §6 chaining: a *different* hostile marker still in contact opens next. The
	# marker this battle just fought can never re-open — a retreat would
	# otherwise loop straight back into the battle the player just left.
	if GameState.current_port == null:
		_open_chained_battle(str(marker.get("id", "")))


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


## Opens the next marker in range after a battle ends (§6 chaining), skipping
## `exclude_id` — the marker whose battle just finished.
func _open_chained_battle(exclude_id: String = "") -> void:
	if _encounters == null:
		return
	for marker in _encounters.contacts(GameState.world_tile()):
		if str(marker.get("id", "")) == exclude_id:
			continue
		_open_encounter(_encounter_for(marker))
		return


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
	# Phase-2 F: one marker tick per day, at sea only (docs/60-* §4.11.11.2).
	# The spawn rolls need a living player and no game-over overlay, so the
	# tick runs before the dead-run early return below only when the run is
	# still alive — `_tick_encounters()` re-checks both conditions itself.
	_tick_encounters()
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


func _is_adjacent(target: Vector2i) -> bool:
	return maxi(absi(target.x - _fleet_cell.x), absi(target.y - _fleet_cell.y)) == 1


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

## Reveals every port within the sighting radius (Chebyshev) and marks the
## tiles in that square explored for the minimap.
func _reveal() -> void:
	if _loader == null:
		return
	var radius := CharacterLib.sighting_radius() if _has_game() else BASE_SIGHTING_RADIUS
	for cell in _loader.port_at:
		var port_cell: Vector2i = cell
		if maxi(absi(port_cell.x - _fleet_cell.x), absi(port_cell.y - _fleet_cell.y)) > radius:
			continue
		var port_id: String = _loader.port_at[cell]
		if not GameState.known_ports.has(port_id):
			GameState.known_ports.append(port_id)

	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var cell := _fleet_cell + Vector2i(dx, dy)
			if cell.x < 0 or cell.y < 0 or cell.x >= _loader.width or cell.y >= _loader.height:
				continue
			GameState.explored_tiles[cell] = true


# --- Marker & camera -------------------------------------------------------

func _place_marker() -> void:
	# 24×24 white square, black outline (docs/80-* §4.8): the marker node is
	# centered on the tile it occupies.
	_fleet_marker.position = Vector2(_fleet_cell) * float(_cell_pixels) \
		+ Vector2(_cell_pixels, _cell_pixels) * 0.5


func _update_camera() -> void:
	_camera.position = _clamp_to_map(_camera_target())


func _camera_target() -> Vector2:
	# Cell coordinates name a tile; the camera aims at that tile's center.
	return Vector2(_fleet_cell.x * _cell_pixels, _fleet_cell.y * _cell_pixels) \
		+ Vector2(_cell_pixels, _cell_pixels) * 0.5


## Clamps a world-space camera center so the 1280×720 view stays inside the
## map: no void past the 128×96 grid is ever shown (docs/80-* §4.5).
## Public so tools/test_movement.gd can check all four corners.
func _clamp_to_map(target: Vector2) -> Vector2:
	var half_view := get_viewport_rect().size * 0.5 / _camera.zoom
	var out := target
	if _map_pixels.x <= half_view.x * 2.0:
		out.x = _map_pixels.x * 0.5
	else:
		out.x = clampf(target.x, half_view.x, _map_pixels.x - half_view.x)
	if _map_pixels.y <= half_view.y * 2.0:
		out.y = _map_pixels.y * 0.5
	else:
		out.y = clampf(target.y, half_view.y, _map_pixels.y - half_view.y)
	return out


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


## The pre-run parking cell: Lisbon's P1 harbour tile, or — on a bigger map —
## the first port marker that exists on the loaded grid. Editor inspection
## only; a real run always has a `world.position`.
func _fallback_cell() -> Vector2i:
	if _loader != null and _loader.width > 0:
		var lisbon: Vector2i = _loader.port_cell("lisbon")
		if lisbon != Vector2i(-1, -1):
			return lisbon
		for cell in _loader.port_at:
			return cell
	return FALLBACK_CELL


func _read_state_cell() -> Vector2i:
	if not _has_game() and GameState.world.is_empty():
		return _fallback_cell()
	return GameState.world_tile()


func _cell_at(world_position: Vector2) -> Vector2i:
	return Vector2i(
		int(floor(world_position.x / float(_cell_pixels))),
		int(floor(world_position.y / float(_cell_pixels)))
	)


## Position-derived HUD bits only (area label + minimap dot). The bars are
## signal-driven and are never refreshed from the movement path, so a move
## cannot poll (`docs/80-*` §7 acceptance).
func _sync_hud() -> void:
	if _hud == null:
		return
	if _hud.has_method("set_fleet_cell"):
		_hud.set_fleet_cell(_fleet_cell)


func _is_loaded() -> bool:
	return _loader != null and not _map_pixels.is_zero_approx()


## Data error path (docs/90-* §11): print the reason and show it centered
## instead of crashing; the rest of the app stays usable.
func _show_error(reason: String) -> void:
	var detail := reason
	if detail.is_empty():
		detail = " / ".join(DataLoader.load_errors)
	if detail.is_empty():
		detail = map_path
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
