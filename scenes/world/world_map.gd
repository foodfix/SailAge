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
const GameOverScene := preload("res://scenes/ui_shared/gameover_screen.tscn")

## Phase-1 map file (docs/10-* §6.1). Swapping maps is a path change only.
const MAP_PATH := "res://data/maps/p1_mediterranean.txt"
## Overridable copy of [constant MAP_PATH]: a different legend-conformant map
## file is a data-only swap (docs/90-* §9 last paragraph), so the path is an
## inspector property rather than a hard-coded read.
@export var map_path: String = MAP_PATH
## Fallback cell before a game exists (Lisbon's harbor tile).
const FALLBACK_CELL := Vector2i(7, 57)

## Port hub scene (owned by T11).
const PORT_SCENE := "res://scenes/port/port_screen.tscn"

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


func _ready() -> void:
	_loader = MapLoaderLib.new()
	var loaded: bool = _loader.load_map(map_path, DataLoader.map_legend)
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

	# T9 signals: day-tick dialogs (weather damage → mutiny → desertion →
	# greeting, §4.7), the mutiny choice and the S9 game-over overlay.
	EventBus.day_advanced.connect(_on_day_advanced)
	EventBus.game_over.connect(_on_game_over)
	if _hud != null:
		_hud.mutiny_choice.connect(_on_mutiny_choice)
		_hud.dialogs_finished.connect(_on_dialogs_finished)


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


## Port entry (docs/20-* §4.11): discover, remember, announce, then route.
func _enter_port(port_id: String) -> void:
	if not GameState.known_ports.has(port_id):
		GameState.known_ports.append(port_id)
	GameState.current_port = port_id
	EventBus.port_entered.emit(port_id)
	_sync_hud()

	# §4.8.2 desertion on **every** port entry (morale < 40). The sim owns the
	# loss; this scene owns the message, queued in §4.7 order with the greeting.
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
	_sync_hud()

	# TODO(T11): the port screen is owned by T11 and does not exist yet. Until
	# it does, announce and stay on the map (docs/90-* §7 world→port route).
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
	if port_id.is_empty() or not ResourceLoader.exists(PORT_SCENE):
		return
	GameState.change_scene(PORT_SCENE)


## §4.5 steps 3–6 produce their reports here, in the §4.7 fixed order. Step 3
## already ran (storm damage is applied in the ledger); this only *reports* it,
## then appends the sim's own entries (mutiny, ship lost, …) which step 6 sorted
## into `last_day_dialogs`, and finally the arrival greeting.
func _on_day_advanced(_new_day: int) -> void:
	if not _has_game():
		return
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
	# Any dialog instance anywhere in the tree joins `modal_overlay` while open.
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			return true
	# The S14 character panel is a Control, not a dialog (T16 owns it).
	var panel := get_node_or_null("CharacterPanelLayer/CharacterPanel")
	if panel != null and panel.has_method("is_open") and panel.is_open():
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
	if not GameState.world.has("position"):
		GameState.set_world_tile(FALLBACK_CELL)
	if not GameState.world.has("clock_fraction"):
		GameState.world["clock_fraction"] = 0.0
	if not GameState.world.has("weather"):
		# §4.7 weather is rolled by the daily ledger (T7/T8); "calm" until then.
		GameState.world["weather"] = SailingSimLib.DEFAULT_WEATHER


func _read_state_cell() -> Vector2i:
	if not _has_game() and GameState.world.is_empty():
		return FALLBACK_CELL
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
