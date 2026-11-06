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
## The §4.5 intel window (the S14/S15/S18 modals retired into it, 2026-11-03).
const IntelWindowLib := preload("res://scenes/ui_shared/intel_window.gd")
const GameOverScene := preload("res://scenes/ui_shared/gameover_screen.tscn")
## Phase 5 task J: the living NPC fleet ecology (docs/60-* §4.1, §4.11.11).
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const ChartViewLib := preload("res://scripts/world/chart_view.gd")
const BountyLib := preload("res://scripts/quests/bounty.gd")
const BattleRewardsLib := preload("res://scripts/combat/battle_rewards.gd")
## Phase 5 task K: wreck collect fills the pooled hold flagship-first
## (docs/40-* §4.2 distribution rule — the same helper the battle loot uses).
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ConfirmScene := preload("res://scenes/ui_shared/confirm_dialog.tscn")
## The §4.7-style message dialog (the picker's inspect summary + the W5-B
## hail placeholder render through it; docs/90-* §7 modal children).
const DialogScene := preload("res://scenes/ui_shared/dialog_box.tscn")
## Phase 3: the explore action and the day/port hooks (`70-*` §4.4/§4.9.3).
const Phase3HooksLib := preload("res://scripts/quests/phase3_hooks.gd")
const QuestGenLib := preload("res://scripts/quests/quest_gen.gd")
## Task H: the click-to-sail A* module (docs/20-* §4.2).
const SailPathLib := preload("res://scripts/world/sail_path.gd")
## Phase 6: the single owner of the ocean lookups (correction 15). The scene
## only warms its decode in `_ready` and pre-checks click destinations; every
## rule lookup stays behind `SailingSim` / the HUD.
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
## Phase 8 W5-A: the interaction layer's brain (targeting, verbs, intercept
## arithmetic, the attack encounter dict — docs/60-* §4.11.15, 80-* §4.10).
## The scene owns the side effects; the module computes.
const InteractionsLib := preload("res://scripts/world/interactions.gd")
const HailModalLib := preload("res://scenes/world/hail_modal.gd")
const AutopilotLib := preload("res://scripts/world/autopilot.gd")
const AutopilotHudScene := preload("res://scenes/world/autopilot_hud.tscn")
## The right-click interaction menu (fleet picker + port context, 80-*
## §4.10.1/§4.10.3) — instanced once into a modal layer on first use.
const PickerScene := preload("res://scenes/world/fleet_picker.tscn")
## Phase 10 (§3/§4.8.9/§4.8.10): the pure arrow-field sampler, the discovery
## lookup (site cells + categories) and the W3 texture registry — the
## directional player token, the world markers and the drawn-arrow fallbacks
## all resolve through the registry with flat fallbacks.
const ArrowFieldLib := preload("res://scripts/world/arrow_field.gd")
const UiKitLib := preload("res://scripts/ui_kit.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")

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
## Screen px per world tile — the loader's render pin (64 on the world path,
## the §4.8 64-canvas amendment). The default mirrors the loader pin so the
## declaration carries no hardcoded 32.
var _cell_pixels := MapLoaderLib.WORLD_TILE_PX
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
## (Amended 2026-11-02: the instance itself moved up into the `FleetSim`
## autoload — `90-*` §5.6 — so the ecology ticks in every scene, port
## included. This scene only *reads* it, through [_fs].)
## Fleet id → the placeholder marker node drawn for it (`80-*` §4.5.2: a
## nation-coloured square with the role letter; pirate red).
var _marker_nodes: Dictionary = {}

## Render-only NPC marker path playback (stepwise-glide amendment, §2.6
## extended): `fleet_id → {points_px, played, seg_duration}` — a polyline of
## tile-centre waypoints (x unwrapped across the dateline) advanced per frame
## by [_tick_npc_glides], read by [_place_marker_square]. `played` counts
## completed segments (carrying the within-segment fraction). Never reaches
## logic; a fleet's tile position is the only simulated truth.
var _npc_glides: Dictionary = {}
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
## Task L (docs/80-* §4.5.2): the wake layer — one Control whose `draw`
## signal paints every moving marker's 5-tile dashed trail (1 px
## `PANEL_LINE` lines fading tile-by-tile; wrecks and docked markers none).
var _wake_layer: Control = null
## Task L: the markers the last [_sync_marker_nodes] pass rendered — the
## wake layer's draw source (render layers never re-simulate).
var _last_markers: Array = []
## Task K: true while the battle in progress was opened by the player's own
## right-click attack (the §4.11.11.2 loot row applies to those only — a
## hostile contact keeps the §4.11.10 aftermath untouched).
var _battle_player_initiated: bool = false

# --- Phase 8 W5-A: the right-click interaction layer (80-* §4.10) -----------

## The active intercept order (`60-*` §4.11.15): `{target_id, target_cell}`
## — `target_cell` is re-written to the target's current cell on every
## contact-check tick while the order runs. `{}` when no order is active.
## The order's *movement* is the ordinary click-to-sail route below; where
## that route dies (manual input, docking, a blocked step), this dies with it
## (see [_cancel_sail_order]).
var _intercept_order: Dictionary = {}
## The right-click menu (fleet picker / port context), instanced once into
## [_interact_layer] on first use and reused.
var _picker: Control = null
## The modal layer the menu lives on (the AttackLayer pattern, layer 3).
var _interact_layer: CanvasLayer = null
## The summary/placeholder message dialog (the inspect verb's line + the
## W5-B hail seam's placeholder) — single instance, reused.
var _message_dialog: Control = null

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

# --- NPC marker path playback (80-* §4.5.2 amendment, 2026-11-02) -----------

## A batch animates only fleets whose walked path touches the camera's
## visible rect expanded by this many tiles (wrap-aware); a path that never
## enters the frame snaps instead of animating.
const NPC_GLIDE_MARGIN_TILES := 2
## Per-fleet pending tiles above which the whole batch speeds up so playback
## never lags the tile truth noticeably.
const NPC_GLIDE_BACKLOG_TILES := 8
## The compressed batch still drains its largest pending queue within this
## many real seconds.
const NPC_GLIDE_MAX_LAG_SECONDS := 1.5
## A fleet pending more tiles than this skips animation entirely and snaps.
const NPC_GLIDE_SNAP_TILES := 24
## The §4.8 NPC role-chip side (amendment 3d2a7d21): the demoted §4.5.2
## letter square rides the hull token's corner at ~6 px — role color fill,
## role letter on top, never stretched with the token.
const NPC_ROLE_CHIP_PX := 6.0
## The A* module instance of the last query (`sail_pathing()`), created lazily.
var _sail = null

# --- Phase 6: helm mode + interpolated rendering (docs/20-* §4.2, §2.6) -----

## Helm auto-step interval clamp, seconds (§4.2: a speed-16 hull lands at
## ≈ today's hold rate on the lower bound; nothing may step slower than one
## tile per 2 s or faster than one per 0.12 s).
const HELM_INTERVAL_MIN := 0.12
const HELM_INTERVAL_MAX := 2.0
## True while the helm auto-stepper is running (§4.2 "the fleet then
## auto-steps that heading"). Latched by a direction key, cleared by `Space`
## and by the three §4.2 cancel seams (click-to-sail, battle, docking). The
## heading itself lives in `GameState.world["heading"]` and **persists**.
var _helm_stepping := false
## Seconds accumulated toward the next auto-step (re-phased on every steer).
var _helm_since_step := 0.0
## The input-mode override (the `SailingSim.drift_mode_override` pattern):
## `""` means "read `GameState.control_prefs`" — the production path V lands;
## a non-empty string forces the answer for a W5 fixture (the property does
## not exist until V merges). Never set it outside a test.
var input_mode_override: String = ""

## Interpolated rendering (§2.6, render-only): the marker lerps between the
## tile-centre pixels over each step's interval. **Every rule reads tile
## positions** — these four fields feed nothing but [_tick_marker_glide],
## which writes only `_fleet_marker.position`. Never read by the ledger,
## encounters, docking checks, saves or `fleet_cell()`.
var _glide_from := Vector2.ZERO
var _glide_to := Vector2.ZERO
var _glide_elapsed := 0.0
var _glide_duration := 0.0
## Test seam for the interpolation-purity proof: `false` snaps the marker
## instead of animating (the logic outcome must be identical either way).
var _glide_enabled := true
## Phase-6 warm-up (task F handoff): the currents decode is forced on the
## first `_process` tick, one frame after the boot frame (the wind raster
## already decodes in `_ready`).
var _ocean_warmed := false

# --- Phase 10: player token, arrow field, world markers (§4.8.9/§4.8.10/§3) --

## The S3 player fleet token (§4.8.9): the 8-dir directional sprite
## `hull_{flagship_type}_player_{dir}` when the registry resolves it, else the
## §4.5 white square fallback (`.tscn` node + code-built outline). The dir id
## follows the fleet's movement heading (`world.heading`, guard-read); at rest
## the last heading persists.
var _token_sprite: TextureRect = null
## Last dir id the token was built for (skips a registry re-probe per step).
var _token_dir := ""
## Last flagship ship type the token was built for (a refit re-resolves).
var _token_ship_type := ""

## The arrow field (§4.8.10, amended 2026-11-04): `W` always toggles the
## wind field; `C` toggles the current field whenever either field is on
## (both off ⇒ `C` is the §4.5 intel window's key). Session-local, default
## OFF; re-sampled on month rollover and whenever the camera's tile moves.
var _wind_field_on := false
var _current_field_on := false
var _arrow_layer: Control = null
var _arrow_samples: Array = []
var _arrow_month := 0
var _arrow_camera_tile := Vector2i(-2, -2)

## World zoom-out (§4.8 as amended 2026-11-04, commit 613ddbf): exactly two
## camera levels — 1.0 near (64 px tiles, 20×12 view) and 0.5 wide (32 px
## effective, the pre-upgrade 40×23 view). Integer halving keeps pixels
## crisp; no fractional zoom. Session-local, default near, persisted nowhere
## (the same convention as the wind/current field toggles).
const ZOOM_NEAR := 1.0
const ZOOM_WIDE := 0.5
var _zoom_wide := false

## World markers (§3): discovery id → marker node. Discovery markers render
## `GameState.discoveries_found` sites ONLY (undiscovered sites never
## render); wrecks keep their Phase-5 [_wreck_nodes] table.
var _discovery_nodes: Dictionary = {}


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
	# Phase 10 (§4.8.9): the S3 player token — the 8-dir hull sprite when the
	# registry resolves it, the white-square fallback otherwise.
	_player_token_init()

	_camera.zoom = Vector2.ONE
	_camera.make_current()
	_update_camera()
	_loader.refresh_port_overlay(DataLoader.ports, DataLoader.nations)

	# Phase 10 (§4.8.10): the arrow field's draw layer (world-anchored; the
	# samples carry the toggles' state, W/C default OFF).
	_arrow_layer_init()

	# Phase 8 (master micro-ledger): the appointed-voyage HUD bar — a lazy
	# instance under the HUD layer; it reads the appointment and renders
	# destination/ETA with its own cancel button (§4.10.4).
	if _hud != null and _hud.get_parent() != null:
		var autopilot_hud: Control = AutopilotHudScene.instantiate()
		_hud.get_parent().add_child(autopilot_hud)
		if autopilot_hud.has_method("setup"):
			autopilot_hud.call("setup")

	# Sighting/exploration at scene ready (docs/20-* §4.11/§4.12).
	_reveal()
	_sync_hud()
	# "Refresh on open" is the one allowed full read (docs/IMPLEMENT T6-B);
	# every later update arrives through EventBus signals.
	if _hud != null:
		_hud.refresh()
	# Phase-6 warm-up (task F handoff): decode the wind raster now — its
	# ~0.9 s must never land on the first day tick. The lazy currents decode
	# is forced one frame later by [_tick_ocean_warmup], keeping the boot
	# frame inside the pinned budget.
	OceanLayersLib.instance()

	# S14 船长 view + fleet view + officers roster: the §4.5 intel window
	# hosts all three (the 2026-11-03 amendment retired the standalone S14/
	# S15/S18 modals). Parent-agnostic modal; owns `C`/`O`/`F`/Esc.
	IntelWindowLib.attach_to(self)

	# T9 signals: day-tick dialogs (weather damage → mutiny → desertion →
	# greeting, §4.7), the mutiny choice and the S9 game-over overlay.
	EventBus.day_advanced.connect(_on_day_advanced)
	EventBus.game_over.connect(_on_game_over)
	EventBus.fleet_changed.connect(_on_fleet_changed)
	# Phase 10 (§3): a discovery found surfaces its site marker + the dialog's
	# category illustration slot id.
	if EventBus.has_signal("discovery_found"):
		EventBus.discovery_found.connect(_on_discovery_found)
	if _hud != null:
		_hud.mutiny_choice.connect(_on_mutiny_choice)
		_hud.dialogs_finished.connect(_on_dialogs_finished)
		if _hud.has_signal("explore_requested"):
			_hud.explore_requested.connect(explore_here)

	# Phase 5 task J, amended 2026-11-02 (docs/60-* §4.11.11, `90-*` §5.6):
	# the NPC fleet sim instance lives in the `FleetSim` autoload — the daily
	# tick runs there in every scene, port included. This scene adopts it (so
	# re-opening the map cannot re-tick or re-move fleets, §4.11.11.1
	# `last_tick_day` dedupe) and owns only the presentation + contact pass.
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
	_tick_ocean_warmup()
	_update_camera()
	# Phase 10 (§4.8.10): the arrow field follows the camera's tile window.
	_tick_arrow_field_camera()
	# Hold-to-repeat / click-to-sail / helm cadence (docs/20-* §4.2, tasks H+G).
	_tick_movement(delta)
	# Interpolated rendering (§2.6): render-only, after the logic tick.
	_tick_marker_glide(delta)
	_tick_npc_glides(delta)

## Forces the lazy ocean-currents decode on the first frame after boot
## (docs/20-* §4.16): the ~1 s raster decode + reversal index otherwise land
## on the first current query — the fleet's first step or the HUD's current
## arrow. One frame after `_ready` keeps the pinned boot budget intact while
## still finishing before any input can move the fleet.
func _tick_ocean_warmup() -> void:
	if _ocean_warmed:
		return
	_ocean_warmed = true
	OceanLayersLib.instance().current_at(
		_fleet_cell, SailingSimLib.month_for(GameState.day))
	# Phase 10 (§6.6): the shore raster decodes on the same warm-up tick —
	# the ~9.3 M-pixel pass must never land on the boot frame's budget —
	# and re-stamps the foam into the chunks the boot already built.
	_loader.warm_shore_overlay()
	# The decode just landed: repaint the HUD's current arrow, which stayed
	# hidden while the currents raster was still warming.
	_refresh_hud_indicators()


# Phase 10 (§4.8.10, amended 2026-11-04): the arrow-field keys run in
# `_input`, ABOVE every `_unhandled_input` consumer — `W` always toggles
# the wind field; `C` toggles the current field whenever EITHER field is
# on (the §4.5 intel `C` is shadowed while field mode is active — the same
# shadow convention as the chart's `C`); with both fields off `C` is
# unchanged (the intel window keeps its own handler). `O`/`F`/the intel
# button always open the window — they are never touched here.
## The `_input` stage of the arrow-field keys (§4.8.10): consuming here hides
## the event from every `_unhandled_input` handler, which IS the shadow.
## The `F10` session capture rides the same stage so it fires even while a
## modal owns input (§4.3 keybind row, capture-amendment 2026-11-05).
func _input(event: InputEvent) -> void:
	_tick_capture_input(event)
	_tick_arrow_field_input(event)


# --- Session capture (F10) — acceptance evidence (2026-11-05 round) --------

## The `F10` capture handler (§4.3 keybind row, capture amendment): saves the
## live viewport to `user://screenshots/world_<ticks>.png`. Deliberately NOT
## gated on modals or game-over — the capture is acceptance evidence and must
## work with any UI on screen. Only requires a loaded run; ignores echo.
func _tick_capture_input(event: InputEvent) -> void:
	if not _is_loaded():
		return
	if not (event is InputEventKey) or not (event as InputEventKey).pressed \
			or (event as InputEventKey).echo:
		return
	var key := event as InputEventKey
	var code := key.physical_keycode if key.physical_keycode != KEY_NONE \
		else key.keycode
	if code == KEY_F10:
		_capture_session_screenshot("world")


## Waits for the current frame to finish drawing, then dumps the viewport
## image; prints the absolute path (the acceptance-report seam).
func _capture_session_screenshot(prefix: String) -> void:
	await RenderingServer.frame_post_draw
	var dir := OS.get_user_data_dir() + "/screenshots"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/%s_%d.png" % [dir, prefix, Time.get_ticks_msec()]
	get_viewport().get_texture().get_image().save_png(path)
	print("CAPTURE saved: ", path)


func _unhandled_input(event: InputEvent) -> void:
	if not _is_loaded():
		return
	# Click-to-sail / click-to-step (docs/80-* §4.3, docs/20-* §4.2). The HUD
	# is mouse-transparent, so clicks land here; a modal consumes them first.
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
			# Phase 8 (80-* §4.10.1): right-click is the interaction surface —
			# a fleet tile inside sighting radius opens the fleet picker, a
			# port harbor tile the port context, empty water/land is a no-op.
			# Opening a menu is not movement input: a live sail order (and an
			# intercept riding it) is only replaced when a *verb* fires. The
			# old adjacent-attack funnel stays reachable as the seam
			# [_try_attack] (the suites' contact surface).
			if _modal_open():
				return
			if _open_interaction_at(_cell_at(get_global_mouse_position())):
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
					# Any click input is a §4.2 helm-cancel seam (80-* §4.3).
					helm_stop()
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

	# Phase 6 (§4.2/§4.17, correction 8): `Space` waits at sea — in helm mode
	# the first press stops the fleet, a press while stopped waits (below).
	if event.is_action_pressed("world_wait"):
		if _modal_open():
			return
		get_viewport().set_input_as_handled()
		press_wait()
		return
	# Phase 6 (§4.17): `[` / `]` cycle the sail trim, both input modes.
	if event.is_action_pressed("trim_forward"):
		if _modal_open():
			return
		get_viewport().set_input_as_handled()
		cycle_trim(true)
		return
	if event.is_action_pressed("trim_back"):
		if _modal_open():
			return
		get_viewport().set_input_as_handled()
		cycle_trim(false)
		return

	# §4.8 world zoom-out (amended 2026-11-04, commit 613ddbf): `Z` toggles
	# the two camera levels — 1.0 near / 0.5 wide (the §4.3 keybind row).
	if event.is_action_pressed("world_zoom"):
		if _modal_open():
			return
		get_viewport().set_input_as_handled()
		toggle_world_zoom()
		return

	for action in MOVE_ACTIONS:
		if event.is_action_released(action):
			# Hold-to-repeat ends. A release never steps (and never stops the
			# helm: a helm course is latched, §4.2).
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
			# Input mode is read at use-time (S19 can flip it live mid-run):
			# step = key-per-tile + hold repeat; helm = set course + auto-step.
			if input_mode() == "helm":
				helm_steer(action)
			else:
				_press_direction(action)
			return


# --- Public API (hosts and tools/test_movement.gd) -------------------------

## Moves the fleet one tile if the move is legal. Rejected moves (land, reef,
## out of bounds, corner cut) leave position **and** clock untouched (§4.2).
## Returns true when the fleet actually stepped.
func try_step(target: Vector2i) -> bool:
	return _try_step(target)


## Removes one NPC fleet by id — the test seam the world_e2e movement proof
## uses to suppress raiders along its route (`60-*` §4.11.11: the proof's
## contract pins no random contact; the ecology trickle keeps raiders alive
## and the unified-movement amendment made them mobile). Delegates to
## [method NpcFleets.remove] so the sim's cell/id indexes stay coherent.
func npc_remove(id: String) -> void:
	if _fs() != null:
		_fs().remove(id)


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


# --- Phase 6: input modes, helm, wait, trim (docs/20-* §4.2, §4.17) ---------

## The persisted control-prefs input mode, guard-read per correction 12:
## `control_prefs` is task V's key block and may not exist yet — `.get` with
## the documented default `"step"`. Read at use-time (S19 flips it live).
## [member input_mode_override] is the test seam.
func input_mode() -> String:
	if not input_mode_override.is_empty():
		return input_mode_override
	var prefs = GameState.get("control_prefs")
	if prefs is Dictionary:
		return str((prefs as Dictionary).get("input_mode", "step"))
	return "step"


## The persisted helm heading (§4.2), guard-read with the pinned default `"E"`
## (correction 12). It persists through helm stops and mode switches.
func helm_heading() -> String:
	var heading := str(GameState.world.get("heading", "E"))
	return heading if SailingSimLib.heading_index(heading) >= 0 else "E"


## True while the helm auto-stepper is running (§4.2).
func helm_active() -> bool:
	return _helm_stepping


## The current auto-step interval, recomputed on every call (§4.2:
## `clamp(1 / effective_speed(heading), 0.12, 2.0)` — trim, weather, wind and
## currents all move it; a furled fleet has no speed and reads the 2.0 cap).
func helm_interval() -> float:
	var speed: int = SailingSimLib.effective_speed(helm_heading())
	if speed <= 0:
		return HELM_INTERVAL_MAX
	return clampf(1.0 / float(speed), HELM_INTERVAL_MIN, HELM_INTERVAL_MAX)


## Sets the helm heading from a direction action and starts (or re-targets)
## the auto-stepper (§4.2): a new direction key changes the course without
## stopping. A course change is manual input, so it replaces any click route.
## Refused while docked (the fleet is not at sea) and before the map loads.
## The first auto-step happens on the first interval tick, not here.
func helm_steer(action: String) -> bool:
	if not MOVE_ACTIONS.has(action) or not _is_loaded():
		return false
	if GameState.current_port != null:
		return false
	var heading: String = SailingSimLib.heading_of_delta(MOVE_ACTIONS[action])
	if heading.is_empty():
		return false
	_cancel_sail_order()
	GameState.world["heading"] = heading
	# A course change starts a fresh interval on the new heading.
	_helm_since_step = 0.0
	_helm_stepping = true
	# The heading persists in `GameState.world["heading"]` (§4.2/§2.6); the
	# §4.8.9 token follows it immediately (at rest the fleet faces its course).
	_refresh_player_token()
	return true


## Stops the auto-stepper (§4.2 `Space`, or one of the cancel seams). The
## heading persists in `GameState.world["heading"]` (§4.2/§2.6).
func helm_stop() -> void:
	_helm_stepping = false
	_helm_since_step = 0.0


## The 8-dir action id for a compass heading ("" outside the 8-dir domain).
func _action_of_heading(heading: String) -> String:
	var index := SailingSimLib.heading_index(heading)
	if index < 0:
		return ""
	for action in MOVE_ACTIONS:
		if MOVE_ACTIONS[action] == SailingSimLib.COMPASS_DELTAS[index]:
			return action
	return ""


## The `Space` action (§4.2, §4.17, correction 8). Step mode: wait one day at
## sea. Helm mode: the first press stops the fleet, a press while stopped
## waits. Refused while docked (`SailingSim.wait_at_sea` returns false — a
## port day is `advance_port_day`'s business) with no toast surfaced.
## Returns `{stopped, waited}` so tests can tell the two helm presses apart.
func press_wait() -> Dictionary:
	var out := {"stopped": false, "waited": false}
	if not _has_game() or not _is_loaded():
		return out
	if input_mode() == "helm" and _helm_stepping:
		helm_stop()
		out["stopped"] = true
		return out
	if not SailingSimLib.wait_at_sea():
		return out
	out["waited"] = true
	_sync_hud()
	if not _toast("world.wait.done"):
		print("WorldMap: waited one day (world.wait.done not in ui_strings)")
	return out


## Cycles `GameState.world["sail_trim"]` through
## `furled → reefed → normal → full` (§4.17): `forward` follows that order and
## wraps, `false` walks it backwards. Works in both input modes; the next
## step's cost picks the new state up automatically (the §4.4 pipeline).
## Returns the new state.
func cycle_trim(forward: bool) -> String:
	var states: Array = SailingSimLib.TRIM_STATES
	var index := states.find(SailingSimLib.sail_trim())
	if index < 0:
		index = states.find(SailingSimLib.DEFAULT_TRIM)
	var next: String = states[posmod(index + (1 if forward else -1), states.size())]
	GameState.world["sail_trim"] = next
	_toast_trim(next)
	_refresh_hud_indicators()
	return next


## The trim-cycle toast (§4.17 / 80-* §4.7.10: the chip label plus the state
## name — no separate toast key). Until the master merges `world.trim.*` the
## state change stays a console line, never invented copy.
func _toast_trim(state: String) -> void:
	if _hud == null or not _hud.has_method("toast_text"):
		return
	if not DataLoader.ui_strings.has("world.trim.chip") \
			or not DataLoader.ui_strings.has("world.trim.%s" % state):
		print("WorldMap: sail trim now '%s' (world.trim.* not in ui_strings)"
			% state)
		return
	_hud.toast_text("%s · %s" % [
		I18n.t_key("world.trim.chip"),
		I18n.t_key("world.trim.%s" % state),
	])


## Refreshes the HUD's Phase-6 indicators (trim chip, wind/current arrows,
## calendar) after a host-side change with no EventBus signal (a trim cycle).
func _refresh_hud_indicators() -> void:
	if _hud != null and _hud.has_method("refresh_sailing_indicators"):
		_hud.refresh_sailing_indicators()


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
	# §4.18: a click onto an in-month frozen tile is rejected like a land
	# click (the destination pre-check; mid-path tiles block on arrival via
	# the per-step gate in `is_move_legal`).
	if _click_hits_ice(cell):
		if not _toast("world.ice.blocked"):
			print("WorldMap: click on in-month sea ice rejected; no clock cost")
		return false
	var path: Array[Vector2i] = _sail_compute(cell)
	if path.is_empty():
		_reject_sail()
		return false
	# A click is manual input: it replaces a held direction, any old order,
	# and the helm (§4.2 cancel seams).
	helm_stop()
	_hold_action = ""
	_hold_forced = false
	_reset_cadence()
	_sail_path = path
	_sail_target = cell
	_sail_dock_port = ""
	_sail_elapsed = 0.0
	_sail_suspended = false
	return true


## §4.18 click pre-check: true when `cell` is water but inside an in-month
## seasonal-ice polygon (`OceanLayers.ice_blocks`, the month of `GameState.day`).
## Skipped before a run exists (no calendar yet — the same guard the sim uses).
func _click_hits_ice(cell: Vector2i) -> bool:
	if not _has_game() or GameState.day <= 0:
		return false
	return OceanLayersLib.instance().ice_blocks(
		cell, SailingSimLib.month_for(GameState.day))


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
	helm_stop()
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
			# §3 discovery-moment surfacing: the category marker icon as the
			# dialog's illustration slot (`marker_discovery_{category}` —
			# the renderer's flat fallback is the W4 contract; a host that
			# ignores the key shows the text-only row).
			"icon_id": "marker_discovery_%s" % str(discovery.get("category", "")),
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
	# A save load replaces `npc_fleets` wholesale; redraw to it. The FleetSim
	# autoload re-adopts the new store on this access (no catch-up — a loaded
	# fleet resumes accrual from the load instant, `60-*` §4.11.11).
	FleetSim.ensure()
	_sync_marker_nodes()


## Map size in pixels, for camera tests.
func map_pixels() -> Vector2:
	return _map_pixels


## World-space rect the camera shows. Its **x is unbounded** (the world wraps
## east–west, so a fleet near the seam shows content past `width * tile_px`
## that is
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
	# not contain (§4.1 "x taken mod width everywhere" — 4320 at the Phase-6
	# grid).
	var landed := step_target
	if _loader.width > 0:
		landed = Vector2i(posmod(step_target.x, _loader.width), step_target.y)

	if _has_game():
		# Applies the tile + `1/effective_speed` days + day-boundary loop.
		# The heading is the move's own 8-dir delta (F's §4.2 pin: "a step is
		# a step wherever it comes from") — in helm mode the auto-step always
		# carries `world.heading` as its delta, so the derived heading equals
		# the helm heading and step mode stays byte-identical to W4.
		SailingSimLib.try_move(step_target, _loader, _fleet_cell)
	# The sim stored the un-normalised cell; re-assert the wrapped one.
	GameState.set_world_tile(landed)

	# Unified-movement amendment: NPC movement accrues with the clock —
	# release the fraction this move just advanced, so every fleet steps
	# ≈ one tile per player move (idempotent; the day tick's catch-up call
	# nets zero when this ran). After the tile re-assert, so the accrual's
	# contact sampling measures against the landed tile. The sync between the
	# accrual and the playback re-picks the §4.8 NPC hull tokens off the
	# fleets' fresh movement headings — the day tick's tick → sync → glide
	# order, so a fleet that just turned at a lane waypoint never sails on
	# a stale facing.
	if _has_game() and _fs() != null:
		_fs().advance_clock()
		_sync_marker_nodes()
		_glide_fleet_moves()

	_reject_logged = false
	_fleet_cell = landed
	# §4.2/§4.8.9: the step's own 8-dir delta IS the movement heading — every
	# step source records it (step keys, the hold repeat, the helm auto-step,
	# click-to-sail, the appointed voyage), so the token always faces the
	# direction the fleet actually sails. Helm mode is unchanged: the
	# auto-step carries `world.heading` as its delta, so the write is the
	# identical value (F's byte-identity pin). A refused move never reaches
	# this line — a blocked step records nothing.
	var step_heading := SailingSimLib.heading_of_delta(delta)
	if not step_heading.is_empty():
		GameState.world["heading"] = step_heading
	# §2.6 interpolated rendering: animate over this step's cadence interval.
	_glide_marker_to(landed, _step_render_seconds())
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
	# Master ruling (Phase 6): the docking move charges `move_cost` with the
	# same heading the docking move carries — the helm heading in helm mode,
	# or the step-delta direction otherwise (identical here: a docking step
	# always carries its own delta). The parameterless average survives only
	# as the fallback for a target that names no 8-dir step. Deliberately
	# state-only (like `SailingSim.try_move`), then the berth is re-asserted
	# so a rejected/otherwise odd berth can never strand the fleet.
	var heading: String = SailingSimLib.heading_of_delta(_wrapped_delta(target))
	# §4.2/§4.8.9: the docking move records its heading too — the docked
	# fleet faces the shore it docked into (`_place_marker` re-picks the
	# token). Helm mode: identical to the helm heading, as with any step.
	if not heading.is_empty():
		GameState.world["heading"] = heading
	if _has_game():
		if heading.is_empty():
			SailingSimLib.advance_clock(SailingSimLib.move_cost())
		else:
			SailingSimLib.advance_clock(SailingSimLib.move_cost(heading))
		# §4.1b (added 2026-11-02): docking itself charges one more hour —
		# the harbor pilot, the mooring — before the port screen opens.
		SailingSimLib.advance_port_hours(1)
	if berth.x >= 0:
		GameState.set_world_tile(berth)
		_fleet_cell = berth
	# Unified-movement amendment: NPC movement accrues with the clock —
	# after the berth re-assert, so the accrual's contact sampling measures
	# against the docked tile (idempotent with the day tick's catch-up).
	# The sync keeps the §4.8 NPC token dirs fresh, exactly as in
	# `_try_step` (the day tick's tick → sync → glide order).
	if _has_game() and _fs() != null:
		_fs().advance_clock()
		_sync_marker_nodes()
		_glide_fleet_moves()
	_place_marker()
	_update_camera()
	_reveal()
	_sync_hud()
	# Docking ends any click route, any held direction and the helm (§4.2
	# cancel seams): the fleet is not at sea any more. The heading persists.
	helm_stop()
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
## is the only feedback (never a modal). §4.18: a move refused for in-month
## seasonal ice names its own toast — the sim records the reason key on the
## refused `is_move_legal` evaluation, and this maps it to the §4.7.10
## `world.ice.blocked` ui key (the sim's `ICE_BLOCKED_KEY` marker predates the
## key table's dotted spelling).
func _reject_move(_target: Vector2i) -> void:
	if _reject_logged:
		return
	_reject_logged = true
	if SailingSimLib.last_move_blocked_key == SailingSimLib.ICE_BLOCKED_KEY:
		if _toast("world.ice.blocked"):
			return
	if _toast("world.move_blocked"):
		return
	print("WorldMap: move rejected (land/reef/edge/corner cut/ice); no clock cost")


## A click on water that has no sea route (§4.2): no clock cost, one toast.
func _reject_sail() -> void:
	if _toast("world.sail.no_path"):
		return
	print("WorldMap: no sea route to the clicked tile; no clock cost")


## Shows a ui_strings toast when the HUD offers one and the key exists; false
## otherwise (the caller keeps its console fallback). `values` fills the
## key's `{placeholders}` (the intercept line carries the target's name).
func _toast(key: String, values: Dictionary = {}) -> bool:
	return _hud != null and _hud.has_method("toast_key") \
		and _hud.toast_key(key, values)


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
	if _hold_action.is_empty() and not _helm_stepping \
			and (_sail_path.is_empty() or _sail_suspended):
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
	# §4.2 helm mode: the auto-stepper runs beside the hold cadence with the
	# same per-step semantics (one normal `try_move`, no batching), and pauses
	# for modals exactly like the hold does (the early return above).
	if _helm_stepping:
		_tick_helm(delta)
	if _sail_path.is_empty() or _sail_suspended:
		return
	_sail_elapsed += delta
	while _sail_elapsed >= SAIL_STEP_SECONDS - SailingSimLib.CLOCK_EPSILON \
			and not _sail_path.is_empty() and not _sail_suspended:
		_sail_elapsed -= SAIL_STEP_SECONDS
		_step_along_sail_path()


## The helm auto-stepper (§4.2): one normal move along `world.heading` every
## `helm_interval()` seconds, the interval **recomputed per step** so a trim
## change, a weather roll or a current edge re-times the cadence immediately.
## A blocked step costs nothing and consumes its slot (never banked) — the
## same rule as the hold repeat. Docking, a battle handoff or a game over end
## the helm; the heading itself persists.
func _tick_helm(delta: float) -> void:
	_helm_since_step += delta
	while _helm_stepping \
			and _helm_since_step >= helm_interval() - SailingSimLib.CLOCK_EPSILON:
		_helm_since_step -= helm_interval()
		var action := _action_of_heading(helm_heading())
		if action.is_empty():
			helm_stop()
			return
		_try_step(_fleet_cell + MOVE_ACTIONS[action])
		if GameState.current_port != null or battle_in_progress() \
				or game_over_open() or _sail_suspended:
			helm_stop()
			return


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
	# Phase 8 §4.19: any manual movement input cancels the appointed voyage
	# (the arrival path cleared it as "arrived" before docking ever lands
	# here). The route dying IS the manual input for helm/step/click alike.
	if AutopilotLib.appointed():
		AutopilotLib.cancel("manual")
	# Phase 8: the intercept order's movement IS this route (§4.11.15 —
	# "intercepting IS sailing to the target"), so wherever the route dies
	# (manual input, docking, a blocked step), the order dies with it. The
	# order's own re-target ([method _set_intercept] → `sail_to`) overwrites
	# the route without cancelling, so the two never fight.
	_intercept_order = {}


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
	# Phase 8 appointed voyage: docking at the destination completes it
	# (§4.19 — the arrival clears the appointment before the port flow).
	if AutopilotLib.appointed() \
			and str(GameState.player.get("autopilot", {}).get("dest_port_id", "")) == port_id:
		AutopilotLib.cancel("arrived")
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
	FleetSim.ensure()
	_sync_marker_nodes()


## The live ecology sim, adopted on demand from the `FleetSim` autoload
## (`90-*` §5.6): null while there is no run. Never cached — a save load or a
## fixture swap re-adopts on the next access (the autoload owns the
## lifecycle; this scene only renders and checks contacts).
func _fs():
	return FleetSim.ensure()


## The fleet sim (public so a test can seed/observe it without a scene).
func fleet_sim():
	return _fs()


## Cells of every live fleet, `[{"id","role","nation_id","cell"}]`, sorted by
## id. The test seam for "fleets moved/died as expected".
func fleet_marker_cells() -> Array:
	var out: Array = []
	if _fs() == null:
		return out
	var entries: Array = _fs().markers()
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
## Consumes the accrual's render-move report and starts the NPC marker
## **path playback** (stepwise-glide amendment, 80-* §4.5.2 — render-only,
## the report feeds nothing but marker positions). One batch per drain:
## every fleet in the batch starts on the same frame and marches in lockstep
## (one shared per-tile duration); a fleet whose walked path never touches
## the expanded viewport snaps instead of animating, and an extreme backlog
## snaps too.
func _glide_fleet_moves() -> void:
	if _fs() == null:
		return
	var moves: Array = _fs().take_fleet_moves()
	if moves.is_empty() or not _glide_enabled:
		return
	# Pass 1 — build each fleet's waypoint chain: the pre-accrual cell, then
	# every walked cell the report carries (the last one is the report's
	# `to`). A fleet already playing chains the new tiles onto its tail (the
	# previous `to` is this report's `from`).
	var animated: Array = []
	var max_pending := 0
	for move in moves:
		var id := str(move.get("id", ""))
		var square: ColorRect = _marker_nodes.get(id, null)
		if square == null:
			continue
		var waypoints: Array[Vector2i] = [
			move.get("from", Vector2i.ZERO) as Vector2i]
		for cell in (move.get("path", []) as Array):
			waypoints.append(cell as Vector2i)
		if waypoints.size() < 2:
			continue
		if not _any_tile_in_view(waypoints):
			_npc_glides.erase(id)
			continue
		var glide: Dictionary = _npc_glides.get(id, {})
		var points: PackedVector2Array = glide.get("points_px",
			PackedVector2Array())
		var played := float(glide.get("played", 0.0))
		if points.is_empty():
			points = PackedVector2Array()
			points.append(_npc_waypoint_px(waypoints[0], Vector2.INF))
		for i in range(1, waypoints.size()):
			points.append(_npc_waypoint_px(waypoints[i],
				points[points.size() - 1]))
		var pending := points.size() - 1 - int(played)
		if pending > NPC_GLIDE_SNAP_TILES:
			# An extreme backlog would lag the marker minutes behind the
			# tile truth — drop the animation, the next sync snaps it.
			_npc_glides.erase(id)
			continue
		max_pending = maxi(max_pending, pending)
		animated.append({"id": id, "points": points, "played": played})
	if animated.is_empty():
		return
	# Pass 2 — batch lockstep pacing: one shared per-tile duration. With no
	# real backlog it is the player's own step cadence; a pending queue past
	# NPC_GLIDE_BACKLOG_TILES speeds the whole batch up so the largest one
	# still drains within NPC_GLIDE_MAX_LAG_SECONDS.
	var seg := _step_render_seconds()
	if max_pending > NPC_GLIDE_BACKLOG_TILES:
		seg = minf(seg, NPC_GLIDE_MAX_LAG_SECONDS / float(max_pending))
	for entry in animated:
		_npc_glides[str(entry["id"])] = {
			"points_px": entry["points"],
			"played": entry["played"],
			"seg_duration": seg,
		}


## True when any of `cells` (each placed at its camera-nearest x across the
## dateline) touches the camera's visible rect expanded by
## [constant NPC_GLIDE_MARGIN_TILES] — the batch's animation gate.
func _any_tile_in_view(cells: Array[Vector2i]) -> bool:
	var view := visible_world_rect().grow(
		float(NPC_GLIDE_MARGIN_TILES * _cell_pixels))
	var map_px := _map_pixels.x
	if map_px <= 0.0:
		return true
	for cell in cells:
		var px := _marker_square_px(cell)
		px.x += map_px * roundf((_camera.position.x - px.x) / map_px)
		if view.has_point(px):
			return true
	return false


## The tile-centre pixel for one playback waypoint, choosing the x
## representation closest to `prev_px` across the dateline: a seam step is
## one tile wide on screen, never a sweep across the whole map (80-*
## §4.5.2 stepwise-glide amendment). `Vector2.INF` starts a fresh chain.
func _npc_waypoint_px(cell: Vector2i, prev_px: Vector2) -> Vector2:
	var px := _marker_square_px(cell)
	var map_px := _map_pixels.x
	if prev_px != Vector2.INF and map_px > 0.0:
		px.x += map_px * roundf((prev_px.x - px.x) / map_px)
	return px


func _tick_fleet_contacts() -> void:
	if _fs() == null:
		return
	if not _has_game() or game_over_open() or SailingSimLib.is_game_over():
		return
	# Phase 8: the intercept order re-evaluates + re-targets on the same
	# cadence the contact check runs at (§4.11.15 — per player step), before
	# the contact check so an arrival opens the battle on a fresh route.
	_tick_intercept()
	_check_fleet_contact()


## The day tick's **presentation pass** (docs/20-* §4.3 step 5, amended
## 2026-11-02): the ecology tick itself moved up into the `FleetSim` autoload
## (`90-*` §5.6), whose listener runs first (autoloads connect before any
## scene). This scene-side pass — still on `day_advanced` — redraws the
## markers, glides the moves the tick just reported and runs the contact
## check. `market_changed` for NPC-traded ports is emitted by the autoload.
func _tick_fleets_day() -> void:
	if _fs() == null:
		return
	if not _has_game() or game_over_open() or SailingSimLib.is_game_over():
		return
	_sync_marker_nodes()
	# Unified-movement amendment: the day tick's accrual (catch-up) also
	# reports fleet moves — glide those markers too.
	_glide_fleet_moves()
	# Phase 8: the intercept rides the day tick's contact pass too (the
	# target may have moved or left the radius without a player step).
	_tick_intercept()
	_check_fleet_contact()


## A hostile fleet in contact opens a battle (docs/60-* §4.11.11.2: only
## `pirate` / `privateer` / `hunter`-with-bounty; §4.11.11.3 the S10 handoff).
## Contact with any fleet of a hunting nation also records the at-sea intel
## cell (§4.11.11.1: one assignment on contact).
func _check_fleet_contact() -> void:
	if _fs() == null:
		return
	var tile := GameState.world_tile()
	_fs().note_contacts(tile)
	var contact: Dictionary = _fs().nearest_contact(tile)
	if contact.is_empty():
		return
	var encounter: Dictionary = _encounter_for(contact)
	_open_encounter(encounter)


## A fleet in contact is opened as a battle. The encounter queued on
## `GameState.pending_encounter` carries the fleet's saved fields unchanged
## plus the S10 `kind` mapping (§4.11.11.3: `hunter` battles keep
## `kind = "navy"`; every other role carries its role id) and the fleet's own
## seeded composition, so S10 fights exactly what the fleet has.
##
## Phase 8: the dict itself is the interaction layer's
## (`Interactions.attack_encounter`, 60-* §4.11.15) — the same shape the
## picker's attack verb opens, so contact and player attacks queue
## byte-identical encounters.
func _encounter_for(fleet: Dictionary) -> Dictionary:
	return InteractionsLib.attack_encounter(fleet)


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
	# Phase 8 §4.19: a hostile contact cancels the appointed voyage (with
	# the notice) — storms never do (the auto-reef rides the trim rule).
	if AutopilotLib.cancel("contact"):
		_toast("sail.autopilot.cancelled_contact")
	if _battle_encounter_id() == str(encounter.get("id", "")) \
			and not _battle_encounter.is_empty():
		return
	if _battle_encounter_id() == str(encounter.get("id", "")) \
			and not _battle_encounter.is_empty():
		return
	_battle_encounter = encounter.duplicate(true)
	# Phase 8: the intercept order is *delivered* when its own target is the
	# fleet this battle opened against (§4.11.15 — the contact pipeline is
	# the arrival). Cleared silently: the interception succeeded, nothing
	# was cancelled. Any other fleet's battle (a hostile walking into the
	# player mid-chase) leaves the order alive; the route resumes after the
	# battle and the next tick re-targets.
	if not _intercept_order.is_empty() \
			and str(_intercept_order.get("target_id", "")) \
				== str(encounter.get("id", "")):
		_intercept_order = {}
	# §4.2: a battle handoff cancels the helm (the single funnel every opener
	# — contact, chain, the player's own attack — goes through). The route is
	# only *suspended*; the helm is not resumed after the battle.
	helm_stop()
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
	# Phase 8 (§4.11.10 extension): the same single funnel also applies the
	# −20 fame and the victim captain's personal stance hit.
	BattleRewardsLib.apply_piracy_attack(nation_id,
		str(encounter.get("captain_id", "")))


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
## pirate red — palette only, no textures). Task L: a convoy (same-lane
## traders within Chebyshev 3, §4.11.11.4) renders as ONE shared square
## with a member-count numeral beside it (member squares hide), and every
## moving marker drags its 5-tile dashed wake (drawn by [_draw_wakes] on
## the wake layer — docked markers and wrecks draw none).
func _sync_marker_nodes() -> void:
	if _loader == null or not _is_loaded():
		return
	if _marker_root == null:
		_marker_root = Node2D.new()
		_marker_root.name = "FleetMarkers"
		_marker_root.z_index = 9
		add_child(_marker_root)
	var live: Dictionary = {}
	var entries: Array = _fs().markers() if _fs() != null else []
	_last_markers = entries
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
			# The §4.5.2 letter rides the theme (default TEXT, default size);
			# the Phase-10 sweep retired the per-node overrides.
			square.add_child(letter)
			var count := Label.new()
			count.name = "Count"
			square.add_child(count)
		var role := str(marker.get("role", ""))
		var role_color := NpcFleetsLib.marker_color(
			role, str(marker.get("nation_id", "")))
		# §4.8 NPC world-fleet tokens (amendment 3d2a7d21): a fleet whose
		# flagship/owner/movement-heading all resolve renders the 8-dir hull
		# token `hull_{type}_{owner}_{dir}` (the nation's PENNANT_* variant,
		# pirate fleets → the pirate pennant) instead of the letter square;
		# the §4.5.2 letter square is demoted to the corner role chip. The
		# bare square stands only as the fallback (unknown ship type, an
		# ownerless nation, no heading — docked fleets — or an unresolved
		# registry id): the §4.5.2 square, exactly as before.
		var dir_id := ArrowFieldLib.dir_id_of_heading(
			str(marker.get("heading", "")))
		var token_texture: Texture2D = null
		if not dir_id.is_empty():
			var owner := NpcFleetsLib.marker_owner(
				role, str(marker.get("nation_id", "")))
			var ship_type := str(marker.get("ship_type", ""))
			if not owner.is_empty() and not ship_type.is_empty():
				token_texture = UiKitLib.icon_texture(
					"hull_%s_%s_%s" % [ship_type, owner, dir_id])
		_sync_npc_token(square, token_texture, role_color,
			str(marker.get("letter", "")))
		# §3 (A.4): a treasure fleet wears the `marker_treasure` token when the
		# registry resolves it — the role letter rides on top (§4.8.5 overlay
		# rule); the §4.8 hull token (when it resolved) draws beneath it.
		_sync_marker_token(square, role)
		# Convoy grouping (§4.11.11.4): members hide behind the leader's
		# shared escort square; the leader shows the member-count numeral.
		var leader := str(marker.get("convoy_leader", ""))
		var member_of_convoy := not leader.is_empty() and leader != id
		square.visible = not member_of_convoy
		var count_node: Label = square.get_node_or_null("Count")
		var convoy_count := int(marker.get("convoy_count", 0))
		if count_node != null:
			count_node.text = "×%d" % convoy_count if convoy_count >= 2 else ""
			count_node.visible = convoy_count >= 2
			# Beside the drawn face: the square edge in fallback mode, the
			# hull token's right edge when the §4.8 token stands in.
			count_node.position = Vector2(square.size.x, 0.0)
			var hull_token: TextureRect = square.get_node_or_null("HullToken")
			if hull_token != null and hull_token.visible:
				count_node.position = Vector2(
					hull_token.position.x + hull_token.size.x, 0.0)
		# Diagnostics badge (unified-movement amendment, 80-* §4.5.2): with
		# the S19 debug row on, a fleet in a suspicious stall state wears a
		# BAD-coloured state letter (B blocked · C camping · D docked ·
		# K cooldown) — normal play (row off) never sees it.
		var stall_state_name := str(marker.get("stall", ""))
		var stall_letter := ""
		if ChartViewLib.debug_row_enabled():
			match stall_state_name:
				"blocked":
					stall_letter = "B"
				"camping":
					stall_letter = "C"
				"docked":
					# Off its berth = the anomaly badge (X); a docked fleet
					# always stands on its port's berth tile (60-* §4.11.11).
					stall_letter = "D" if bool(marker.get("on_berth", true)) \
						else "X"
				"stranded":
					# Dwell holding in OPEN WATER — always the anomaly.
					stall_letter = "X"
				"cooldown":
					stall_letter = "K"
		var stall_node: Label = square.get_node_or_null("Stall")
		if stall_node == null:
			stall_node = Label.new()
			stall_node.name = "Stall"
			# The §4.5.2 diagnostic pin: a BAD-coloured state letter — canvas
			# marker art, kept via LabelSettings (the theme has no BAD label
			# slot and the sweep keeps per-node theme overrides out).
			var stall_settings := LabelSettings.new()
			stall_settings.font_color = PaletteLib.BAD
			stall_node.label_settings = stall_settings
			stall_node.position = Vector2(0.0, 0.0)
			square.add_child(stall_node)
		stall_node.text = stall_letter
		stall_node.visible = not stall_letter.is_empty()
		# Docked fleets render at their simulated position: the port's SEA
		# berth tile (the only legal docking tile — ships never dock on the
		# land/shore tile; §4.11.1/§6.1 anchorage, per the established pin).
		_place_marker_square(square, marker.get("cell", Vector2i.ZERO), id)
	for id in _marker_nodes.keys():
		if live.has(id):
			continue
		var dead: ColorRect = _marker_nodes[id]
		_marker_nodes.erase(id)
		dead.queue_free()
	_sync_wake_layer()
	_sync_wreck_nodes()
	# Phase 10 (§3): the discovery site markers ride the same pass — the
	# discovered-only set, never a re-simulation of the hunt.
	_sync_discovery_markers()


## The treasure fleet's §3 marker token: the `marker_treasure` sprite drawn
## over the marker square (covering it) when the registry resolves the id and
## the fleet's role is `treasure`; hidden otherwise (the §4.5.2 square rule).
func _sync_marker_token(square: ColorRect, role: String) -> void:
	var token: TextureRect = square.get_node_or_null("TokenSprite")
	var texture := UiKitLib.icon_texture("marker_treasure") \
		if role == NpcFleetsLib.TREASURE else null
	if texture == null:
		if token != null:
			token.visible = false
		return
	if token == null:
		token = TextureRect.new()
		token.name = "TokenSprite"
		token.stretch_mode = TextureRect.STRETCH_SCALE
		token.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		token.size = Vector2(_cell_pixels, _cell_pixels)
		token.position = (square.size - Vector2(_cell_pixels, _cell_pixels)) * 0.5
		token.mouse_filter = Control.MOUSE_FILTER_IGNORE
		square.add_child(token)
		# Beneath the letter/count overlays — the §4.8.5 rule: identification
		# letters stay badges drawn ON TOP of the token sprite.
		square.move_child(token, 0)
	token.texture = texture
	token.visible = true


## The §4.8 NPC hull token + corner role chip (amendment 3d2a7d21): when
## `texture` resolves (a fleet with a known flagship type, owner pennant and
## movement heading) the token draws 1:1 at the cell, centred on the square's
## anchor, the square fill goes transparent (the root stays visible — the
## glide pass keeps positioning it), the inline letter hides, and a ~6px
## role chip (role letter on the role color) pins to the token's top-right
## corner. `texture == null` is the §4.5.2 fallback: the coloured letter
## square exactly as before (chip + token hidden). Render-only either way.
func _sync_npc_token(square: ColorRect, texture: Texture2D,
		role_color: Color, letter_text: String) -> void:
	var token: TextureRect = square.get_node_or_null("HullToken")
	if token == null:
		token = TextureRect.new()
		token.name = "HullToken"
		token.stretch_mode = TextureRect.STRETCH_SCALE
		token.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		token.size = Vector2(_cell_pixels, _cell_pixels)
		token.mouse_filter = Control.MOUSE_FILTER_IGNORE
		square.add_child(token)
		# Beneath the letter/count/chip overlays — the §4.8.5 overlay rule:
		# identification letters stay badges drawn ON TOP of the token sprite.
		square.move_child(token, 0)
	var chip: ColorRect = square.get_node_or_null("Chip")
	if chip == null:
		chip = ColorRect.new()
		chip.name = "Chip"
		chip.size = Vector2.ONE * NPC_ROLE_CHIP_PX
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var chip_letter := Label.new()
		chip_letter.name = "ChipLetter"
		# Canvas marker art at chip scale — LabelSettings (the stall badge's
		# precedent; the theme has no chip-sized label slot).
		var chip_settings := LabelSettings.new()
		chip_settings.font_size = int(NPC_ROLE_CHIP_PX)
		chip_letter.label_settings = chip_settings
		chip_letter.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(chip_letter)
		square.add_child(chip)
	var letter_node: Label = square.get_node_or_null("Letter")
	if texture == null:
		# §4.5.2 fallback: the coloured letter square, unchanged.
		token.visible = false
		chip.visible = false
		square.color = role_color
		if letter_node != null:
			letter_node.text = letter_text
			letter_node.visible = not letter_text.is_empty()
		return
	# Token mode: the demoted square keeps only its corner chip.
	square.color = Color(role_color.r, role_color.g, role_color.b, 0.0)
	token.texture = texture
	token.position = (square.size - Vector2(_cell_pixels, _cell_pixels)) * 0.5
	token.visible = true
	chip.color = role_color
	chip.position = token.position \
		+ Vector2(_cell_pixels - NPC_ROLE_CHIP_PX, 0.0)
	var chip_letter: Label = chip.get_node("ChipLetter")
	chip_letter.text = letter_text
	chip_letter.visible = not letter_text.is_empty()
	if letter_node != null:
		letter_node.visible = false


## Ensures the wake layer exists and repaints it from the last marker pass.
func _sync_wake_layer() -> void:
	if _wake_layer == null:
		_wake_layer = Control.new()
		_wake_layer.name = "WakeLayer"
		_wake_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_wake_layer.z_index = 8
		_marker_root.add_child(_wake_layer)
		_wake_layer.draw.connect(_draw_wakes)
	_wake_layer.queue_redraw()


## Paints every moving marker's wake (docs/80-* §4.5.2): a 5-tile dashed
## trail of 1 px `PANEL_LINE` lines behind the marker, fading tile-by-tile
## (oldest faintest). Docked markers report no wake from the sim, and wrecks
## are not fleets at all.
func _draw_wakes() -> void:
	if _wake_layer == null:
		return
	var unit := float(_cell_pixels)
	for marker in _last_markers:
		if not (marker is Dictionary) or not bool((marker as Dictionary)
				.get("sailing", false)):
			continue
		var wake: Array = (marker as Dictionary).get("wake", [])
		for index in wake.size():
			if index % 2 == 1:
				continue  # dashed: every other tile paints
			var cell: Vector2i = wake[index]
			var at := Vector2(cell) * unit + Vector2(unit, unit) * 0.5
			var color := PaletteLib.PANEL_LINE
			color.a = 1.0 - 0.16 * float(index)
			_wake_layer.draw_line(at - Vector2(unit * 0.25, 0.0),
				at + Vector2(unit * 0.25, 0.0), color, 1.0)


## Redraws the wreck markers (docs/80-* §4.5.2, task K): the §3 `marker_wreck`
## sprite in the 2×2-tile box centred on the wreck tile when the registry
## resolves it, else the Phase-5 placeholder — an `ACCENT` × glyph (the pinned
## render, kept via LabelSettings as canvas art, not theme chrome). The data
## comes from `NpcFleets.wrecks()` and nothing re-simulates here.
func _sync_wreck_nodes() -> void:
	if _loader == null or not _is_loaded():
		return
	if _marker_root == null:
		return  # no fleet pass ran yet: nothing to hang the glyphs under
	var live: Dictionary = {}
	var entries: Array = _fs().wrecks() if _fs() != null else []
	for wreck in entries:
		if not (wreck is Dictionary):
			continue
		var id := str((wreck as Dictionary).get("id", ""))
		if id.is_empty():
			continue
		live[id] = true
		var glyph: Control = _wreck_nodes.get(id, null)
		if glyph == null:
			var texture := UiKitLib.icon_texture("marker_wreck")
			if texture != null:
				glyph = _world_marker_node("Wreck_%s" % id, "marker_wreck")
			else:
				glyph = Label.new()
				glyph.name = "Wreck_%s" % id
				(glyph as Label).text = "×"
				var settings := LabelSettings.new()
				settings.font_color = PaletteLib.ACCENT
				settings.font_size = int(float(_cell_pixels) * 1.2)
				(glyph as Label).label_settings = settings
				glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
				glyph.z_index = 8
				_marker_root.add_child(glyph)
			_wreck_nodes[id] = glyph
		_place_wreck_glyph(glyph, NpcFleetsLib.position_of(wreck))
	for id in _wreck_nodes.keys():
		if live.has(id):
			continue
		var gone: Control = _wreck_nodes[id]
		_wreck_nodes.erase(id)
		gone.queue_free()


## Centers a 2×2-tile marker box (sprite or × glyph) on the wreck tile.
func _place_wreck_glyph(glyph: Control, cell: Vector2i) -> void:
	var box := Vector2(float(_cell_pixels) * 2.0, float(_cell_pixels) * 2.0)
	glyph.size = box
	if glyph is Label:
		(glyph as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		(glyph as Label).vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.position = Vector2(cell) * float(_cell_pixels) \
		+ (Vector2(float(_cell_pixels), float(_cell_pixels)) - box) * 0.5


## Collects every wreck on `cell` (docs/60-* §4.11.11.2, task K): the cargo
## up to the pooled free hold — `Fleet.add_goods` distributes flagship-first,
## the same §4.2 rule the battle loot uses — plus the salvage gold in full
## (already `BattleRewards.salvage_for` money at wreck-spawn time). Overflow
## units are lost with the wreck (the hold guard, not a partial wreck).
func _collect_wrecks_at(cell: Vector2i) -> void:
	if _fs() == null or not _has_game():
		return
	var collected := false
	while true:
		var wreck: Dictionary = _fs().wreck_at(cell)
		if wreck.is_empty():
			break
		var result: Dictionary = _fs().collect_wreck(
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
## Places one NPC marker square at `cell`'s tile centre — or, while a
## render-only path playback is active for `id` (the §2.6 mechanism extended
## to NPC markers; logic never runs here), at the polyline's interpolated
## position: the segment `played` is walking, lerped within the segment.
func _place_marker_square(square: ColorRect, cell: Vector2i,
		id: String = "") -> void:
	square.position = _marker_square_px(cell)
	if id.is_empty() or not _npc_glides.has(id):
		return
	var glide: Dictionary = _npc_glides[id]
	var points: PackedVector2Array = glide["points_px"]
	var last := points.size() - 1
	if last < 1:
		return
	var index := clampi(int(float(glide["played"])), 0, last - 1)
	var t := clampf(float(glide["played"]) - float(index), 0.0, 1.0)
	square.position = (points[index] as Vector2).lerp(
		points[index + 1] as Vector2, t)


## The tile-centre origin for one marker square (the snap formula's
## position term, shared by the playback waypoints).
func _marker_square_px(cell: Vector2i) -> Vector2:
	return Vector2(cell) * float(_cell_pixels) \
		+ (Vector2(_cell_pixels, _cell_pixels) - Vector2(_cell_pixels,
		_cell_pixels) * 0.7) * 0.5


## Advances every NPC marker path playback; a finished polyline snaps its
## square to the destination waypoint and drops the state. `played` counts
## completed segments (the within-segment fraction rides the decimals), so
## a mid-flight `seg_duration` change (a lockstep re-pace) keeps every
## already-walked segment exactly where it was.
func _tick_npc_glides(delta: float) -> void:
	if _npc_glides.is_empty():
		return
	for id in _npc_glides.keys():
		var glide: Dictionary = _npc_glides[id]
		var seg := float(glide["seg_duration"])
		if seg <= 0.0:
			_npc_glides.erase(id)
			continue
		glide["played"] = float(glide["played"]) + delta / seg
		var square: ColorRect = _marker_nodes.get(id, null)
		if square == null:
			continue
		var points: PackedVector2Array = glide["points_px"]
		var last := points.size() - 1
		if float(glide["played"]) >= float(last):
			square.position = points[last]
			_npc_glides.erase(id)
			continue
		var index := clampi(int(float(glide["played"])), 0, maxi(last - 1, 0))
		var t := float(glide["played"]) - float(index)
		square.position = (points[index] as Vector2).lerp(
			points[index + 1] as Vector2, clampf(t, 0.0, 1.0))


# --- Phase 10: player token (§4.8.9), arrow field (§4.8.10), markers (§3) ---

## Builds the player token's two faces under FleetMarker (once): the code-built
## square fallback (the §4.5 white square with the black outline — the old
## scene-file panel styling retired with the Phase-10 chrome sweep) and the
## directional sprite slot. Both stay until [_refresh_player_token] picks.
func _player_token_init() -> void:
	if _token_sprite != null:
		return
	var square := get_node_or_null("FleetMarker/Square") as Control
	if square != null:
		# The fallback square re-derives its rect from the cell px (the
		# §4.8 64-canvas amendment — the .tscn offsets are the retired 32-era
		# geometry): 0.75 tile, centered on the marker anchor.
		var square_side := _cell_pixels * 0.75
		square.size = Vector2(square_side, square_side)
		square.position = Vector2.ONE * square_side * -0.5
		var outline := ColorRect.new()
		outline.name = "Outline"
		outline.color = Color.BLACK
		outline.size = Vector2(_cell_pixels * 0.75, _cell_pixels * 0.75)
		outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
		square.add_child(outline)
		var fill := ColorRect.new()
		fill.name = "Fill"
		fill.color = Color.WHITE
		fill.position = Vector2.ONE * (outline.size.x - _cell_pixels * 0.625) * 0.5
		fill.size = Vector2.ONE * _cell_pixels * 0.625
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		square.add_child(fill)
	var holder := Control.new()
	holder.name = "Token"
	holder.size = Vector2(_cell_pixels, _cell_pixels)
	holder.position = Vector2.ONE * _cell_pixels * -0.5
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.visible = false
	var sprite := TextureRect.new()
	sprite.name = "Sprite"
	sprite.stretch_mode = TextureRect.STRETCH_SCALE
	sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite.size = Vector2(_cell_pixels, _cell_pixels)
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(sprite)
	_token_sprite = sprite
	get_node("FleetMarker").add_child(holder)
	_refresh_player_token()


## The §4.8.9 token pick: `hull_{flagship_ship_type}_player_{dir}` with the
## dir id of the fleet's movement heading (`world.heading`, guard-read; at
## rest the last heading persists — it IS the stored heading). A missing id,
## a run before a fleet exists or an unknown heading keeps the square.
func _refresh_player_token() -> void:
	var marker := get_node_or_null("FleetMarker")
	if marker == null or _token_sprite == null:
		return
	var ship_type := ""
	if _has_game():
		var flagship: Dictionary = FleetLib.flagship()
		ship_type = str(flagship.get("ship_type_id", ""))
	var heading := str(GameState.world.get("heading", ""))
	var dir_id := ArrowFieldLib.dir_id_of_heading(heading)
	var texture: Texture2D = null
	if not ship_type.is_empty() and not dir_id.is_empty():
		texture = UiKitLib.icon_texture(
			"hull_%s_player_%s" % [ship_type, dir_id])
	_token_ship_type = ship_type
	_token_dir = dir_id if texture != null else _token_dir
	_token_sprite.texture = texture
	_token_sprite.get_parent().visible = texture != null
	var square := marker.get_node_or_null("Square") as Control
	if square != null:
		square.visible = texture == null


## The arrow field's draw layer: a world-anchored Control under the map
## (above the chunks, below the fleet markers at z 9).
func _arrow_layer_init() -> void:
	if _arrow_layer != null:
		return
	_arrow_layer = Control.new()
	_arrow_layer.name = "ArrowField"
	_arrow_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arrow_layer.z_index = 4
	_arrow_layer.draw.connect(_draw_arrow_field)
	add_child(_arrow_layer)


## `true` while the §4.8.10 wind field is on (session-local, default OFF).
func wind_field_on() -> bool:
	return _wind_field_on


## `true` while the §4.8.10 current field is on (session-local, default OFF).
func current_field_on() -> bool:
	return _current_field_on


## The `W` toggle (§4.8.10, amended 2026-11-04): session-local wind field,
## default off; ALWAYS toggles — `W` has no other meaning on S3.
func toggle_wind_field() -> void:
	_wind_field_on = not _wind_field_on
	_resample_arrow_field()


## The `C` toggle (§4.8.10, amended 2026-11-04): session-local current field,
## default off. Whenever EITHER arrow field is on the key is consumed in
## `_input` (the §4.5 intel `C` is shadowed while field mode is active) and
## toggles the current field — including ON while only the wind field runs
## (the amended reachability). With both fields off `C` is unchanged (the
## intel window's key).
func toggle_current_field() -> void:
	_current_field_on = not _current_field_on
	_resample_arrow_field()


## The last sampled month (0 before the first sample) — the month-rollover
## re-sample read seam.
func arrow_field_month() -> int:
	return _arrow_month


## The live samples (the draw source; the suite's determinism seam).
func arrow_field_samples() -> Array:
	return _arrow_samples.duplicate()


## The `_input`-stage key handler (§4.8.10 amended 2026-11-04): `W` always
## toggles the wind field; `C` toggles the current field whenever EITHER
## field is on (wind-only ⇒ C turns the current field ON — the amended
## reachability; that consume is the intel shadow). With both fields off,
## `C` is not consumed (the §4.5 intel window answers). Both keys give way
## to modals (the chart owns `W`/`C` while it is open) and to a dead run.
func _tick_arrow_field_input(event: InputEvent) -> void:
	if not _is_loaded() or _modal_open() or game_over_open():
		return
	if not (event is InputEventKey) or not (event as InputEventKey).pressed \
			or (event as InputEventKey).echo:
		return
	var key := event as InputEventKey
	var code := key.physical_keycode if key.physical_keycode != KEY_NONE \
		else key.keycode
	if code == KEY_W:
		get_viewport().set_input_as_handled()
		toggle_wind_field()
	elif code == KEY_C and (_wind_field_on or _current_field_on):
		get_viewport().set_input_as_handled()
		toggle_current_field()


## Re-samples the field for whatever is on (§4.8.10): stride-4 lattice over
## the camera window + apron, water cells only, the live calendar month.
func _resample_arrow_field() -> void:
	if _arrow_layer == null or _loader == null or not _is_loaded():
		return
	_arrow_month = SailingSimLib.month_for(maxi(int(GameState.day), 1))
	_arrow_samples = []
	if _wind_field_on or _current_field_on:
		var ocean = OceanLayersLib.instance()
		# Zoom-aware: the lattice covers the camera's visible window (40×23
		# tiles at the wide 0.5 level, §4.8 zoom-out amendment).
		var view := get_viewport_rect().size \
			/ (_camera.zoom.x * float(_cell_pixels))
		_arrow_samples = ArrowFieldLib.sample(
			_camera_tile(), Vector2i(int(ceil(view.x)), int(ceil(view.y))),
			_arrow_month, ocean,
			func(cell: Vector2i) -> bool: return _loader.is_passable(cell),
			_loader.width, _loader.height)
	_arrow_camera_tile = _camera_tile()
	_arrow_layer.queue_redraw()


## The camera's tile — the window the field is sampled over.
func _camera_tile() -> Vector2i:
	return Vector2i(
		int(floor(_camera.position.x / float(_cell_pixels))),
		int(floor(_camera.position.y / float(_cell_pixels))))


## Camera-follow check (per frame, an integer compare): the lattice is
## world-anchored, so the sample re-runs only when the camera crosses a
## stride boundary — never per pan pixel.
func _tick_arrow_field_camera() -> void:
	if _arrow_layer == null:
		return
	var tile := _camera_tile()
	if tile == _arrow_camera_tile:
		return
	_resample_arrow_field()


## Draws the samples (§4.8.10): `wind_arrow_{dir}` / `current_arrow_{dir}`
## through the registry; the drawn-arrow fallback pins wind `TEXT` / current
## `COAST_SEA`; a `VAR` wind cell keeps the chart's hollow amber diamond.
func _draw_arrow_field() -> void:
	if _arrow_layer == null:
		return
	for entry in _arrow_samples:
		var cell: Vector2i = entry["cell"]
		var at := Vector2(cell) * float(_cell_pixels) \
			+ Vector2.ONE * float(_cell_pixels) * 0.5
		var dir_id := str(entry.get("dir_id", ""))
		var texture: Texture2D = null
		if not dir_id.is_empty():
			texture = UiKitLib.icon_texture(
				"%s_arrow_%s" % [str(entry.get("kind", "")), dir_id])
		var half := float(_cell_pixels) * 0.5
		if texture != null:
			_arrow_layer.draw_texture_rect(texture,
				Rect2(at - Vector2.ONE * half, Vector2.ONE * _cell_pixels),
				false)
			continue
		if bool(entry.get("variable", false)):
			_draw_var_diamond(at, half * 0.6)
			continue
		var color := PaletteLib.TEXT if str(entry.get("kind", "")) == "wind" \
			else PaletteLib.COAST_SEA
		var dir := _compass_vector(dir_id)
		if dir == Vector2.ZERO:
			continue
		_draw_field_arrow(at, dir, half, color)


## The chart's drawn arrow (§4.6 style): shaft along `dir`, V head at the tip.
func _draw_field_arrow(at: Vector2, dir: Vector2, length_px: float,
		color: Color) -> void:
	var tip := at + dir * (length_px * 0.5)
	var tail := at - dir * (length_px * 0.5)
	_arrow_layer.draw_line(tail, tip, color, 1.5)
	_arrow_layer.draw_line(tip, tip + dir.rotated(PI * 0.75) * (length_px * 0.3),
		color, 1.5)
	_arrow_layer.draw_line(tip,
		tip + dir.rotated(-PI * 0.75) * (length_px * 0.3), color, 1.5)


## The `VAR` glyph: a hollow amber diamond (the chart's distinctive shape).
func _draw_var_diamond(at: Vector2, r: float) -> void:
	var points := PackedVector2Array([
		at + Vector2(0, -r), at + Vector2(r, 0),
		at + Vector2(0, r), at + Vector2(-r, 0), at + Vector2(0, -r),
	])
	_arrow_layer.draw_polyline(points, PaletteLib.WARN, 1.5, false)


## Tile-space unit vector of a §4.8.6 dir id (zero outside the domain).
func _compass_vector(dir_id: String) -> Vector2:
	var bucket := ArrowFieldLib.DIR_IDS.find(dir_id)
	if bucket < 0:
		return Vector2.ZERO
	var token := ArrowFieldLib.dir_id_of_bucket(bucket)
	var index := SailingSimLib.COMPASS_DIRS.find(token)
	if index < 0:
		return Vector2.ZERO
	var delta: Vector2i = SailingSimLib.COMPASS_DELTAS[index]
	return Vector2(delta)


## Month rollover (§4.8.10): the day tick re-samples the field so a month
## boundary flips the prevailing arrows without a toggle. Reads the live
## month against the sampled one — idempotent.
func _on_day_advanced_arrow_field() -> void:
	if not (_wind_field_on or _current_field_on):
		return
	var month := SailingSimLib.month_for(maxi(int(GameState.day), 1))
	if month != _arrow_month:
		_resample_arrow_field()


## A discovery was found: its site marker surfaces (§3, discovered-only).
func _on_discovery_found(_discovery_id: String) -> void:
	_sync_discovery_markers()


## Builds the discovery site markers (§3): one node per id in
## `GameState.discoveries_found` at the discovery's tile — the
## `marker_discovery_{category}` sprite when the registry resolves it, else a
## small ACCENT square (the flat fallback). Undiscovered sites never render.
func _sync_discovery_markers() -> void:
	if _loader == null or not _is_loaded() or _marker_root == null:
		return
	var live: Dictionary = {}
	if _has_game():
		for discovery_id in GameState.discoveries_found:
			var id := str(discovery_id)
			if id.is_empty() or live.has(id):
				continue
			var discovery: Dictionary = DataLoader.get_discovery(id)
			if discovery.is_empty():
				continue
			live[id] = true
			var node: Control = _discovery_nodes.get(id, null)
			if node == null:
				node = _world_marker_node("Discovery_%s" % id,
					"marker_discovery_%s" % str(discovery.get("category", "")))
				_discovery_nodes[id] = node
			node.position = Vector2(
				DiscoveryLib.position_of_entry(discovery)) * float(_cell_pixels)
	for id in _discovery_nodes.keys():
		if live.has(id):
			continue
		var gone: Control = _discovery_nodes[id]
		_discovery_nodes.erase(id)
		gone.queue_free()


## One static world-marker node (§3 "like port markers"): the registry sprite
## at tile size when the id resolves, else a small ACCENT square. The node is
## parented under the fleet-marker root (z 8, above the map, below markers).
func _world_marker_node(node_name: String, sprite_id: String) -> Control:
	var holder := Control.new()
	holder.name = node_name
	holder.size = Vector2(_cell_pixels, _cell_pixels)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var texture := UiKitLib.icon_texture(sprite_id)
	if texture != null:
		var sprite := TextureRect.new()
		sprite.texture = texture
		sprite.stretch_mode = TextureRect.STRETCH_SCALE
		sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sprite.size = Vector2(_cell_pixels, _cell_pixels)
		sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(sprite)
	else:
		var square := ColorRect.new()
		var side := float(_cell_pixels) * 0.375
		square.color = PaletteLib.ACCENT
		square.size = Vector2(side, side)
		square.position = (Vector2(_cell_pixels, _cell_pixels)
			- Vector2(side, side)) * 0.5
		square.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(square)
	holder.z_index = 8
	_marker_root.add_child(holder)
	return holder


# --- Phase 8 W5-A: the right-click interaction layer (80-* §4.10) -----------

## Resolves a right-click at `cell` (§4.10.1 hit rules, in the doc's order):
## a fleet tile inside sighting radius opens the fleet picker, a port harbor
## tile the port context, anything else is a no-op (`false`, no toast, no
## menu). Left-click sail-to is the unchanged branch above.
func _open_interaction_at(cell: Vector2i) -> bool:
	if not _has_game() or _modal_open():
		return false
	var target: Dictionary = InteractionsLib.target_at(cell)
	if not target.is_empty() and InteractionsLib.in_range(target):
		_open_fleet_picker(cell)
		return true
	var port_id := _port_target_at(cell)
	if not port_id.is_empty():
		_open_port_context(port_id)
		return true
	return false


## The port a right-clicked harbor tile belongs to: its **shore** tile via
## the loader's inverse table, its **berth** tile by the derived harbor pair
## (a docked fleet on the berth resolves as a fleet first — the §4.10.1
## fleet rule outranks the §4.10.3 port rule). `""` when the tile is no
## port's harbor.
func _port_target_at(cell: Vector2i) -> String:
	if _loader == null or not _is_loaded():
		return ""
	if not _loader.shore_port_at(cell).is_empty():
		return _loader.shore_port_at(cell)
	var wrapped := Vector2i(posmod(cell.x, _loader.width), cell.y)
	for port_id in _loader.harbor_tiles():
		if _loader.port_cell(str(port_id)) == wrapped:
			return str(port_id)
	return ""


## The fleet picker over `cell`'s fleets (§4.10.1): the pick list is every
## fleet on the tile — a multi-fleet tile lists them all. Verb gating lives
## in the picker (`Interactions.verbs_for` + the hail range).
func _open_fleet_picker(cell: Vector2i) -> void:
	var picker := _picker_ensure()
	if picker.is_open():
		return
	picker.open_fleets(InteractionsLib.fleets_at(cell))


## The port context menu over `port_id` (§4.10.3): dock (the walk-in flow)
## and 委任航行 appoint voyage — the appoint row grays with the
## `sail.autopilot` gate reason while the gate fails.
func _open_port_context(port_id: String) -> void:
	var picker := _picker_ensure()
	if picker.is_open():
		return
	var gate: Dictionary = InteractionsLib.appoint_gate(port_id)
	picker.open_port_context(port_id, bool(gate.get("ok", false)),
		str(gate.get("reason", "")))


## The modal layer both interaction modals live on (the AttackLayer
## pattern, layer 3) — created lazily, once.
func _interact_layer_ensure() -> CanvasLayer:
	if _interact_layer == null:
		_interact_layer = CanvasLayer.new()
		_interact_layer.name = "InteractLayer"
		_interact_layer.layer = 3
		add_child(_interact_layer)
	return _interact_layer


## The menu instance, created once on a layer above the HUD (the AttackLayer
## pattern) and reused for every right-click.
func _picker_ensure() -> Control:
	_interact_layer_ensure()
	if _picker == null:
		_picker = PickerScene.instantiate()
		_picker.name = "FleetPicker"
		_interact_layer.add_child(_picker)
		_picker.verb_chosen.connect(_on_picker_verb)
		_picker.port_action.connect(_on_port_action)
	return _picker


## The right-click menu instance (null until the first right-click created
## it) — the test/inspection seam.
func interaction_picker():
	return _picker


## A verb button was pressed on a fleet row (§4.10.1): inspect → the summary
## line (the unified card is W6's); talk → the hail (the W5-B seam); attack
## → the existing §4.11.11.2 funnel (in contact) or the intercept order
## (beyond it).
func _on_picker_verb(verb: String, fleet: Dictionary) -> void:
	if fleet.is_empty():
		return
	match verb:
		InteractionsLib.VERB_INSPECT:
			_open_message(InteractionsLib.inspect_summary(fleet))
		InteractionsLib.VERB_TALK:
			_open_hail(fleet)
		InteractionsLib.VERB_ATTACK:
			_dispatch_attack(fleet)


## A port-context row was pressed (§4.10.3): dock routes through the
## existing walk-in flow (click-to-sail onto the shore tile — docking
## happens on arrival, or immediately when already adjacent); 委任航行
## appoints through the W5-D seam.
func _on_port_action(action: String, port_id: String) -> void:
	if port_id.is_empty():
		return
	if action == "dock":
		var shore: Vector2i = _loader.shore_cell(port_id)
		if shore.x >= 0:
			sail_to(shore)
	elif action == "appoint":
		_appoint_voyage(port_id)


## The attack verb's dispatch (§4.11.15): a deliberate attack is manual
## input — it replaces any live sail order and intercept. In contact range
## (Chebyshev ≤ 1) the battle opens now through the single funnel (a pirate
## straight away, any other fleet behind the piracy confirm — the old
## funnel UX); beyond it the attack becomes an intercept order onto the
## target. **A coaster is never dispatched** (§4.1.1/§4.11.15: no attack
## verb exists for one — the picker cannot even render the button; this
## guard is the last line behind it).
func _dispatch_attack(fleet: Dictionary) -> void:
	if fleet.is_empty() or _modal_open():
		return
	if str(fleet.get("role", "")) == NpcFleetsLib.COASTER:
		if not _toast("interact.attack.coaster"):
			print("WorldMap: attack refused on a coaster (§4.1.1)")
		return
	_cancel_sail_order()
	var target := NpcFleetsLib.position_of(fleet)
	if NpcFleetsLib.chebyshev(GameState.world_tile(), target) \
			<= NpcFleetsLib.CONTACT_DISTANCE:
		if str(fleet.get("role", "")) != NpcFleetsLib.PIRATE:
			_open_attack_confirm(fleet)
			return
		_attack(fleet)
		return
	_set_intercept(fleet)


## Issues the intercept order against `fleet` (§4.11.15): store
## `{target_id, target_cell at set time}` and sail to the target's current
## cell through the EXISTING click-to-sail path. Each contact-check tick
## re-evaluates [method _tick_intercept] — re-targeting the moving target,
## auto-cancelling when it leaves the sighting radius — until the contact
## pipeline fires the battle (intercepting IS sailing to the target).
## A target with no sea route takes no order (the no-path toast explains).
func _set_intercept(fleet: Dictionary) -> void:
	if fleet.is_empty():
		return
	var order := InteractionsLib.intercept(fleet)
	var cell: Vector2i = order["target_cell"]
	if not sail_to(cell):
		return  # no route: no order (the previous route is untouched)
	_intercept_order = order
	var fleet_name := InteractionsLib.display_name(fleet)
	if not _toast("interact.intercept.set", {"name": fleet_name}):
		print("WorldMap: intercept %s at %s" % [str(order["target_id"]), str(cell)])


## The intercept order's tick (§4.11.15), run on every contact-check pass:
## cancelled → the `interact.intercept.cancelled` notice and the whole
## order (route included) drops; valid → the sail order re-targets the
## moving target's CURRENT cell whenever it moved since the last tick.
## Skipped while a battle owns the world or the route is battle-suspended —
## the order re-evaluates on the first tick after the fight.
func _tick_intercept() -> void:
	if _intercept_order.is_empty():
		return
	var reason := InteractionsLib.intercept_cancel_reason(_intercept_order)
	if not reason.is_empty():
		_intercept_order = {}
		_cancel_sail_order()
		if not _toast("interact.intercept.cancelled"):
			print("WorldMap: intercept cancelled (%s)" % reason)
		return
	if battle_in_progress() or _sail_suspended:
		return
	if _modal_open():
		# A modal freezes the world (§4.7): the re-target waits for the next
		# tick — a refused `sail_to` below must only ever mean "no route",
		# never "a dialog was up".
		return
	var fleet: Dictionary = InteractionsLib.fleet_by_id(
		str(_intercept_order.get("target_id", "")))
	if fleet.is_empty():
		return  # the cancel pass above already handled a vanished target
	var cell := NpcFleetsLib.position_of(fleet)
	var chased: Vector2i = _intercept_order.get("target_cell",
		NpcFleetsLib.NO_CELL)
	if cell == chased:
		return  # the target has not moved: keep walking the current route
	_intercept_order["target_cell"] = cell
	if not sail_to(cell):
		# The target reached a tile this fleet cannot route to (a different
		# sea region): the order dies as unreachable-sight.
		_intercept_order = {}
		_cancel_sail_order()


## The active intercept order (`{}` when none) — the test/inspection seam.
func intercept_order() -> Dictionary:
	return _intercept_order.duplicate(true)


## The talk verb's seam (§4.10.2): the hail opens at Chebyshev ≤ 2 with the
## options slot B builds. **W5-B dispatch seam** — the master fills this
## with the 2-line hookup (gate the range, instance `hail_modal.tscn`, hand
## it the fleet) once slot B merges; until then the placeholder below keeps
## the seam compiling and shows the modal's own title (an existing key —
## never invented copy).
func _open_hail(fleet: Dictionary) -> void:
	if fleet.is_empty():
		return
	if not InteractionsLib.hail_in_range(fleet):
		if not _toast("interact.talk.too_far"):
			print("WorldMap: too far to hail (interact.talk.too_far missing)")
		return
	# W5-B hookup (the master's 2-line dispatch): the modal renders the
	# option rows and applies outcomes through HailOptions.resolve; a failed
	# intimidation opens the normal encounter after the modal closes.
	#
	# The host MUST be the interaction CanvasLayer (amended 2026-11-03):
	# `world_map` is a Node2D whose map canvas draws at `z_index 10`, so a
	# modal parented to the scene root rendered behind the water — visible,
	# in the tree, full-rect, and invisible on screen (the talk verb looked
	# dead). Every at-sea modal lives on this layer (the message dialog and
	# the fleet picker already do).
	var modal := HailModalLib.open_for(fleet, _interact_layer_ensure())
	if modal != null:
		modal.hostile_encounter_requested.connect(_open_encounter)


## The 委任航行 appoint seam (§4.10.3/§4.10.4): the port context's enabled
## row lands here after the `sail.autopilot` gate passed. **W5-D seam** —
## slot D's autopilot owns the appointment (`player.autopilot
## {dest_port_id}`, the HUD bar, the weighted route); until it merges the
## certified row stays a no-op placeholder (no toast, no state change).
func _appoint_voyage(port_id: String) -> void:
	if port_id.is_empty():
		return
	# W5-D hookup: the gate re-check + appointment; the HUD bar (instanced
	# in _ready) renders destination/ETA and owns the cancel action. The
	# walk itself rides the existing sail-order machinery toward the port's
	# berth — any manual input cancels (the §4.19 rule), docking completes.
	var gate: Dictionary = AutopilotLib.gate(port_id)
	if not bool(gate.get("ok", false)):
		_open_message(str(gate.get("reason", "")))
		return
	var result: Dictionary = AutopilotLib.appoint(port_id)
	if not bool(result.get("ok", true)):
		_open_message(str(result.get("reason", "")))
		return
	var berth: Vector2i = DataLoader.port_cell(port_id)
	if berth.x >= 0:
		sail_to(berth)


## The summary/placeholder message dialog (docs/90-* §7 modal child): one
## instance, reused; hidden **before** it frees-queues so `_modal_open()`
## is false again in the same frame (the `_close_attack_confirm` rule).
func _open_message(text: String) -> void:
	if text.is_empty():
		return
	_interact_layer_ensure()
	if _message_dialog == null:
		_message_dialog = DialogScene.instantiate()
		_message_dialog.name = "InteractMessage"
		_interact_layer.add_child(_message_dialog)
	_message_dialog.open_text(text)


## Closes the message dialog (kept instanced for reuse; the hide leaves
## `_modal_open()` false in the same frame).
func _close_message() -> void:
	if _message_dialog != null:
		_message_dialog.close()


## Right-click on an adjacent fleet = attack it (docs/60-* §4.11.11.2). A
## pirate opens the battle straight away; any other fleet asks for
## `encounter.attack_confirm` first because attacking it is piracy (a
## non-pirate owner pays `Bounty.apply_piracy` at battle start).
##
## Phase 8: the *mouse* no longer lands here — right-click opens the fleet
## picker (§4.10.1), whose attack verb dispatches through
## [_dispatch_attack]. This seam stays byte-compatible for the suites that
## pin the funnel itself (contact-adjacent attack → confirm → battle), and
## is deliberately NOT the coaster pin's home: the not-attackable rule is
## pinned on the offered surface ([method Interactions.verbs_for] + the
## rendered picker rows), which is the only path production input can reach.
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
	if _fs() == null:
		return {}
	return _fs().fleet_at(cell)


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
	if _fs() != null:
		if retreated:
			# The descriptor is a copy: the cooldown must land on the stored
			# fleet, so it goes through the id lookup.
			_fs().set_pursuit_cooldown(
				str(fleet.get("id", "")), day + NpcFleetsLib.PURSUIT_COOLDOWN_DAYS
			)
		else:
			_fs().remove(str(fleet.get("id", "")))
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
## `25 + floor(day / 10)`g, instead of the general gold. **Treasure fleet**
## (§4.11.11.4, task L): cargo at ×3 normal volume (booked into the hold at
## spawn) plus `min(3000, 500 + 25 × day)`g. The cargo is the fleet's own
## saved hold — not the §4.11.3 per-ship rolls — distributed flagship-first
## through the same pooled-hold rule the battle loot uses
## (`Fleet.add_goods`); overflow units are lost.
func _apply_attack_loot(fleet: Dictionary, day: int) -> void:
	var gold := mini(1000, 100 + 10 * maxi(day, 0))
	if str(fleet.get("role", "")) == "coaster":
		gold = 25 + int(floor(float(maxi(day, 0)) / 10.0))
	elif str(fleet.get("role", "")) == NpcFleetsLib.TREASURE:
		gold = mini(3000, 500 + 25 * maxi(day, 0))
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
	if _fs() == null:
		return false
	for fleet in _fs().contacts(GameState.world_tile()):
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
	# Phase 10 (§4.8.10): a month rollover re-samples the arrow field.
	_on_day_advanced_arrow_field()
	if not _has_game():
		return
	# Phase 8 §2.5: drain the officer advice queue (the sea-day rolls fired
	# inside the ledger's growth step) into the notice flow.
	var advice_lib := load("res://scripts/world/advice.gd")
	if advice_lib != null:
		for entry in advice_lib.call("drain"):
			if entry is Dictionary and not _toast(str((entry as Dictionary).get("key", ""))):
				print("Advice: %s" % str((entry as Dictionary).get("key", "")))
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
	# The §4.5 intel window is a Control modal (it joined `modal_overlay`
	# while open, so the group walk above already covers it; the name probe
	# keeps a host that attaches inside a CanvasLayer working).
	var window := get_node_or_null("IntelWindowLayer/IntelWindow")
	if window != null and window.has_method("has_modal") \
			and window.has_modal():
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
	# centered on the tile it occupies. A `place` is always a snap: teleports
	# (docking, a battle restore, a save load) never animate (§2.6).
	_glide_duration = 0.0
	_fleet_marker.position = _marker_px(_fleet_cell)
	# §4.8.9: the token faces the persisted heading after every snap too.
	_refresh_player_token()


## The on-screen pixel centre of `cell`.
func _marker_px(cell: Vector2i) -> Vector2:
	return Vector2(cell) * float(_cell_pixels) \
		+ Vector2(_cell_pixels, _cell_pixels) * 0.5


## The render duration of one step's animation: the helm auto-step interval
## under helm, otherwise the hold/click cadence (§2.6).
func _step_render_seconds() -> float:
	return helm_interval() if _helm_stepping else SAIL_STEP_SECONDS


## §2.6 interpolated rendering: the marker glides from where it is drawn now
## to `to_cell`'s tile centre over `duration` seconds. **Render-only**: the
## offset lives in [_glide_from]/[_glide_to]/[_glide_elapsed]/[_glide_duration]
## and reaches nothing but `_fleet_marker.position` (via
## [_tick_marker_glide]); `fleet_cell()`, the ledger, encounters, docking,
## the minimap and saves all keep reading tile positions. A non-positive
## duration or a disabled seam snaps instead.
func _glide_marker_to(to_cell: Vector2i, duration: float) -> void:
	# §4.8.9: the token's dir id comes from the heading the step carried —
	# a per-step re-probe is a registry dictionary lookup, never an asset load.
	_refresh_player_token()
	if not _glide_enabled or duration <= 0.0:
		_glide_duration = 0.0
		_fleet_marker.position = _marker_px(to_cell)
		return
	_glide_from = _fleet_marker.position
	_glide_to = _marker_px(to_cell)
	_glide_elapsed = 0.0
	_glide_duration = duration


## Advances the render-only glide. The one writer of the marker's animated
## position; logic never runs here.
func _tick_marker_glide(delta: float) -> void:
	if _glide_duration <= 0.0:
		return
	_glide_elapsed += delta
	var t := _glide_elapsed / _glide_duration
	if t >= 1.0 or not _glide_enabled:
		_glide_duration = 0.0
		_fleet_marker.position = _glide_to
		return
	_fleet_marker.position = _glide_from.lerp(_glide_to, t)


## True while the marker is between tiles (render-only state).
func marker_gliding() -> bool:
	return _glide_duration > 0.0


## The marker's current render offset from the destination tile centre
## (pixels). Diagnostics for the purity test; nothing in the rules reads it.
func marker_offset() -> Vector2:
	return _fleet_marker.position - _glide_to


## Test seam for the interpolation-purity proof: `false` snaps every step.
## Drops the NPC playback state too — the next sync re-places every square.
func set_marker_glide_enabled(enabled: bool) -> void:
	_glide_enabled = enabled
	if not enabled:
		_glide_duration = 0.0
		_fleet_marker.position = _marker_px(_fleet_cell)
		_npc_glides.clear()


## Deterministic replacement for `_process`'s glide tick in headless tests.
func advance_render(seconds: float) -> void:
	_tick_marker_glide(seconds)
	_tick_npc_glides(seconds)


## Centers the camera on the fleet (which wraps) and refreshes the chunk ring.
## The camera's own y is clamped to the map height; x is **not** clamped — the
## camera is always centred on the fleet and the chunk layer repeats the grid
## across the seam (docs/80-* §4.5 "wrap at dateline: no clamp, no void").
func _update_camera() -> void:
	_camera.position = _clamp_to_map(_camera_target())
	_update_chunks()


## The §4.8 world zoom-out toggle (amended 2026-11-04, commit 613ddbf):
## near 1.0 ⇄ wide 0.5. The camera scales the world (and the 64-canvas
## fleet token) naturally — no counter-scaling anywhere; the chunk spawn
## follows the effective view so the wide 40×23 window never shows void.
## Session-local: nothing is persisted.
func toggle_world_zoom() -> void:
	_zoom_wide = not _zoom_wide
	_camera.zoom = Vector2.ONE * (ZOOM_WIDE if _zoom_wide else ZOOM_NEAR)
	_update_camera()
	# The arrow lattice is world-anchored over the visible window — re-sample
	# so the wide view's doubled window stays covered (fields off ⇒ no-op).
	_resample_arrow_field()


## The active camera zoom level (1.0 near / 0.5 wide) — the suite's read seam.
func world_zoom() -> float:
	return _camera.zoom.x


## `true` while the wide (0.5) level is active.
func world_zoom_wide() -> bool:
	return _zoom_wide


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


## Spawns/frees chunks around the camera. The zoom-aware viewport size is
## converted to tiles so the loader's 24-chunk ring covers the whole visible
## view — 20×12 at the near 1.0 level, 40×23 at the wide 0.5 level (the
## §4.8 64-canvas zoom-out amendment; +2 tiles of apron both ways).
func _update_chunks() -> void:
	if _loader == null or _chunks_root == null:
		return
	var view := get_viewport_rect().size \
		/ (_camera.zoom.x * float(_cell_pixels))
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
	# Phase-6 world keys (correction 12): the same guard defaults F pinned in
	# `new_game`, so a hand-built state sails like a fresh run.
	if not GameState.world.has("sail_trim"):
		GameState.world["sail_trim"] = SailingSimLib.DEFAULT_TRIM
	if not GameState.world.has("heading"):
		GameState.world["heading"] = "E"
	if not GameState.world.has("wind_dir"):
		GameState.world["wind_dir"] = "E"


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


## Cell under a world position. x **wraps** (a click at `x = 4320` is a click
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
	# The sweep retired the per-node override: the error line reads in the
	# theme's Label color (the BAD ink was a Phase-1 placeholder choice, not
	# a §4.8 pin).
	_error_layer.visible = true
