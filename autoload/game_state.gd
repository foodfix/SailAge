extends Node
## GameState — single source of truth for mutable game state
## (docs/90-ARCHITECTURE.md §5.4).
##
## T4 scope: the field declarations I18n needs plus the pins listed in the T4
## task, and two trivial helpers. T16 adds `new_game()` (docs/50-* §4.1); the
## daily ledger delegation and save/load support stay with T7/T17/T18.

# Preloaded rather than referenced by class_name so this autoload parses
# before the editor has written Godot's global-class cache.
const CharacterLib := preload("res://scripts/player/character.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
## The living-sea fleet sim (docs/60-* §4.12.3); `new_game` runs the seeded
## initial fill through it (docs/60-* §4.1.2).
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")

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
## World-map NPC fleets (docs/60-* §4.11.11, §4.15 fleet shape); owned by
## `scripts/world/npc_fleets.gd` — the Phase-5 rename of the retired Phase-2
## `hostile_fleets` 3-marker block (`kind` → `role`).
var npc_fleets: Array = []
## `{kind: day}` spawn immunity after a battle (docs/60-* §4.8, §4.11.11.1);
## present-but-empty before Phase 2 and saved as of save_version 2.
var proximity_cooldowns: Dictionary = {}
## Phase-2/3 fields: present but empty in Phase 1.
var quests: Array = []
var discoveries_found: Array = []

# --- Phase 5 saved state (docs/90-* §8.1, save_version 5) -------------------

## `{port_id: {good_id: stock}}` — every port-good's stock, 0–200
## (docs/30-* §4.2). Initialized at `new_game` from the derived resting stock
## (produced 160 / demanded 40 / neutral 100, no RNG) and owned by
## `scripts/port/economy.gd`; saved as of save_version 5.
var market_stocks: Dictionary = {}
## Lootable wreck sites (docs/60-* auto-resolve, task K); never counted
## against the fleet cap. Present-but-empty until the ecology lands.
var wrecks: Array = []
## Sea-traffic density preset id (docs/10-* §4.10): chosen on S2, changeable
## mid-run in S19 (task M). `npc_fleets.gd` (task J) budgets against it.
var npc_preset: String = "normal"
## Active demand-event instances (docs/30-* §4.5); the rotation is task L.
## The rest-override table they drive lives transiently in `economy.gd`.
var market_events: Array = []

# --- Phase 3 saved state (docs/90-* §8.1, save_version 3) -------------------

## Permanent renown (docs/70-* §4.1); never decays.
var fame: int = 0
## `{nation_id: rank}` over all six nations (docs/70-* §4.9.2); rank ids are
## `none|knight|baron|viscount|count|duke`.
var titles: Dictionary = {}
## `{nation_id: {amount, day}}` — an issued bounty (docs/70-* §4.9.5).
var bounties: Dictionary = {}
## Accepted quest instances (docs/70-* §4.9.3); the offer list is derived.
var active_quests: Array = []
## `{nation_id: int}` completed royal missions (docs/70-* §4.3).
var completed_royal_missions: Dictionary = {}
## Discovery ids already reported at a guild (docs/70-* §4.4).
var discoveries_reported: Array = []
## `{discovery_id: true}` hints bought at a tavern (docs/70-* §4.4).
var discovery_hints: Dictionary = {}
## Battles won across the run (docs/70-* §4.7 ending summary).
var battles_won: int = 0
## The win state (docs/70-* §4.7): a retired save is never playable again.
var retired: bool = false
var retired_at: int = 0
## The encounter a battle scene should open (`60-*` §4.11.11.3). Transient:
## set by S3 immediately before routing, cleared by S10 on open, never saved.
var pending_encounter = null
## The tournament bout S13 should start next (`70-*` §4.9.7). Transient: set by
## S10 when a bout is won, consumed by S13's `_ready`; never saved.
var pending_tournament_round: int = 0
## The settled bracket block S13 reports on open (`70-*` §4.9.7). Transient:
## written by `Tournament.settle()`, consumed once by S13; never saved.
var last_tournament_outcome: Dictionary = {}
## Minimap exploration set; deliberately not saved in Phase 1
## (docs/20-* §4.12 known limitation).
var explored_tiles: Dictionary = {}


## Applies a gold delta and announces it. Clamping/ledger rules live in the
## sailing/port engines (docs/20-* §4.9), not here.
func add_gold(delta: int) -> void:
	gold += delta
	EventBus.gold_changed.emit(gold)


## Starts a fresh run for `nation_id` exactly per docs/50-* §4.1.
##
## Everything comes from `data/nations.json` (nothing hardcoded here), so
## editing a nation's `start_gold`/`start_ship_type_id` is a data-only change.
## `locale` is deliberately untouched: the player's language choice survives
## the new game.
##
## `route` exists for unit tests: with the default `true` the run routes to the
## port screen (§4.1 step 4); tests pass `false` to keep the test scene alive.
## `map_id` names the map. Phase 4 ships exactly one (`DataLoader.DEFAULT_MAP_ID`
## = `"world"`, docs/90-* §9.1) and there is no compatibility ladder for the
## retired Phase-1–3 ids (`90-*` §8.2 "development-stage scope": SailAge has not
## shipped, so no save in the wild names them). The fleet starts on the nation's
## start port's **derived berth** tile (`10-*` §6.1, `20-*` §4.11.1), never
## a stored copy.
func new_game(nation_id: String, route: bool = true,
		map_id: String = "world") -> void:
	var nation: Dictionary = DataLoader.get_nation(nation_id)
	if nation.is_empty():
		push_error("GameState.new_game: unknown nation_id '%s'" % nation_id)
		return

	var start_port_id := str(nation.get("start_port_id", ""))
	var start_port: Dictionary = DataLoader.get_port(start_port_id)
	if start_port.is_empty():
		push_error("GameState.new_game: nation '%s' has unknown start_port_id '%s'"
			% [nation_id, start_port_id])
		return
	var resolved_map := _resolve_map_id(map_id)

	day = 1
	gold = int(nation.get("start_gold", 0))

	# Reputation keys cover all six nations so the panel/save shape is stable
	# (docs/50-* §4.6, §4.8); only the player's own nation starts non-zero.
	var reputation: Dictionary = {}
	for entry in DataLoader.nations_list:
		var other_id := str(entry.get("id", ""))
		reputation[other_id] = 0
	reputation[nation_id] = int(nation.get("start_reputation", 0))

	player = {
		"nation_id": nation_id,
		"stats": CharacterLib.starting_stats(nation_id),
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": reputation,
	}

	# Starter hull: §4.3 "buy ship" defaults except crew = ShipType.crew_min.
	var start_ship_type_id := str(nation.get("start_ship_type_id", ""))
	var ship_type: Dictionary = DataLoader.get_ship_type(start_ship_type_id)
	if not ship_type.is_empty():
		fleet = [FleetLib.new_ship(start_ship_type_id, int(ship_type["crew_min"]))]
	else:
		push_error("GameState.new_game: nation '%s' has unknown start_ship_type_id '%s'"
			% [nation_id, start_ship_type_id])
		fleet = []

	# The fleet sits on the start port's derived berth tile (docs/20-* §4.1,
	# `10-*` §6.1); docking happens immediately, so the clock resets to 0 (§4.3).
	# `position` is stored as `{"x","y"}` — the save-block shape (docs/90-*
	# §8.1) and the JSON tilePos shape (docs/10-* §3.1) — so T17 can serialize
	# it byte-for-byte; use `world_tile()` for the `Vector2i` the map API wants.
	world = {
		"position": _tile_dict(start_port, resolved_map),
		"clock_fraction": 0.0,
		"map_id": resolved_map,
	}
	current_port = start_port_id

	known_ports = []
	for entry in DataLoader.nations_list:
		var capital_id := str(entry.get("capital_port_id", ""))
		if capital_id.is_empty():
			capital_id = str(entry.get("start_port_id", ""))
		if not capital_id.is_empty() and not known_ports.has(capital_id):
			known_ports.append(capital_id)

	# docs/20-* §4.8: "New game: 70."
	morale = 70
	port_investments = {}
	quests = []
	discoveries_found = []
	# docs/60-* §4.11.11: the fleet ecology is per-run state; the retired
	# Phase-2 spawn-immunity map stays present-but-empty (docs/90-* §8.1).
	npc_fleets = []
	proximity_cooldowns = {}
	pending_encounter = null
	pending_tournament_round = 0
	last_tournament_outcome = {}
	explored_tiles = {}
	# docs/90-* §8.1 Phase-3 fields: a fresh run starts at zero everywhere.
	fame = 0
	titles = _nation_map("none")
	bounties = {}
	active_quests = []
	completed_royal_missions = _nation_map(0)
	discoveries_reported = []
	discovery_hints = {}
	battles_won = 0
	retired = false
	retired_at = 0
	# docs/90-* §8.1 Phase-5 fields: stocks at derived rest (docs/30-* §4.2,
	# no RNG), the ecology blocks empty until tasks J/K fill them, the density
	# dial at its documented default. The transient rest-override table is a
	# fresh-run reset too (active events are re-applied by their owner, task L).
	market_stocks = EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list
	)
	wrecks = []
	npc_preset = "normal"
	market_events = []
	EconomyLib.reset_overrides()
	# docs/60-* §4.1.2: the seeded initial fill to half the core cap runs
	# here and only here, after the stock block exists (the fill never moves
	# stocks — spawns carry empty holds), respecting the density preset
	# (`deserted` fills nothing).
	var fleets_sim = NpcFleetsLib.new({
		"npc_config": DataLoader.npc_config, "preset": npc_preset,
	})
	fleets_sim.initial_fill(day)
	CharacterLib.pending_levelup = false

	print("GameState.new_game: %s, %dg, ship %s, port %s, day 1, map %s"
		% [nation_id, gold, start_ship_type_id, start_port_id, resolved_map])

	if route:
		_route_after_new_game(start_port_id)


## §4.1 step 4 routes to the port screen for the start port.
## TODO(T11): `port_screen.tscn` is owned by T11 and does not exist yet; until
## then fall back to the world map (T5/T6) and finally stay on the current
## screen so a missing scene can never crash the new-game flow.
func _route_after_new_game(_start_port_id: String) -> void:
	const PORT_SCENE := "res://scenes/port/port_screen.tscn"
	const WORLD_SCENE := "res://scenes/world/world_map.tscn"
	if ResourceLoader.exists(PORT_SCENE):
		change_scene(PORT_SCENE)
	elif ResourceLoader.exists(WORLD_SCENE):
		push_warning("GameState.new_game: %s missing (T11); routing to world map"
			% PORT_SCENE)
		change_scene(WORLD_SCENE)
	else:
		push_warning("GameState.new_game: neither port nor world scene exists yet")


## A port's tile as the §8.1 `{x, y}` save shape. Ports carry `lat`/`lon` only
## (docs/10-* §4.4), so the tile is the **derived berth** tile (`10-*` §6.1
## snap rule via `DataLoader.port_cell`). `map_id` is kept for signature
## compatibility; there is one world map now (docs/90-* §9.1).
func _tile_dict(port: Dictionary, _map_id: String = "world") -> Dictionary:
	var port_id := str(port.get("id", ""))
	var cell := Vector2i(-1, -1)
	if DataLoader.ensure_map():
		cell = DataLoader.port_cell(port_id)
	if cell.x < 0 and (port.get("lat") is float or port.get("lat") is int):
		# No loader (a pure unit fixture): run the same floor projection so the
		# tile is never silently (0,0).
		cell = DiscoveryLib.tile_of_latlon(
			float(port.get("lat", 0.0)), float(port.get("lon", 0.0))
		)
	return {"x": maxi(cell.x, 0), "y": maxi(cell.y, 0)}


## Resolves the map choice against `data/maps/maps.json` (docs/90-* §9.1).
## An id that is not in the index falls back to the one documented default with
## a warning — a hand-edited value can never wedge a new game, and there is no
## per-phase id table to maintain.
func _resolve_map_id(map_id: String) -> String:
	var known: Array = DataLoader.map_ids()
	if map_id in known:
		return map_id
	push_warning("GameState.new_game: unknown map_id '%s'; using '%s'"
		% [map_id, DataLoader.DEFAULT_MAP_ID])
	return DataLoader.DEFAULT_MAP_ID


## `{nation_id: value}` over every nation (a fresh save-block default).
func _nation_map(value) -> Dictionary:
	var out: Dictionary = {}
	for entry in DataLoader.nations_list:
		out[str(entry.get("id", ""))] = value
	return out


## `world.position` as a `Vector2i` for the map/passability API
## (docs/90-* §9 takes `Vector2i`). Tolerates the dict save shape and an
## already-converted `Vector2i`/`Vector2` (e.g. after T6 movement code ran).
func world_tile() -> Vector2i:
	var pos = world.get("position", null)
	if pos is Vector2i:
		return pos
	if pos is Vector2:
		return Vector2i(pos)
	if pos is Dictionary:
		return Vector2i(int(pos.get("x", 0)), int(pos.get("y", 0)))
	return Vector2i.ZERO


## Writes the fleet position from a `Vector2i` back into the dict save shape.
func set_world_tile(tile: Vector2i) -> void:
	world["position"] = {"x": tile.x, "y": tile.y}


## `true` in an editor/headless run (the debug-hook gate). Centralised so the
## one debug-only hook has a single, export-safe implementation.
func is_debug_build() -> bool:
	return OS.has_feature("debug") or OS.has_feature("editor")


## Thin scene router (docs/90-* §7): swaps the root scene.
func change_scene(path: String) -> void:
	get_tree().change_scene_to_file(path)


## **Debug/editor-build only** — empties `fleet` so the harbor-relief state
## (`gold < 1200 && fleet.is_empty()` per docs/10-* §5, docs/50-* §4.7) can be
## exercised: there is no legitimate in-game path to a shipless player in
## Phase 1 (docs/40-* §6 forbids selling the last ship, and sinking the
## flagship ends the run), so T15 tests reach the fallback through this hook.
##
## Never reachable from any UI: nothing in `scenes/` calls it, and in a release
## build it is a no-op (returns false, changes nothing). It deliberately does
## **not** touch `gold`, `day`, `morale`, `player` or `world`, so the caller
## sets up its own fixture.
##
## `is_debug_build()` rather than `OS.is_debug_build()`: `OS.is_debug_build()`
## is not available in every export template / script context, and a
## missing method would make this hook *throw* instead of returning false.
func debug_strip_fleet() -> bool:
	if not is_debug_build():
		push_warning("GameState.debug_strip_fleet: debug builds only; ignoring")
		return false
	fleet = []
	EventBus.fleet_changed.emit()
	return true
