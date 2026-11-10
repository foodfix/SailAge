extends Node
## DataLoader — loads every data/*.json at startup into typed dictionaries
## keyed by id (docs/90-ARCHITECTURE.md §5.2).
##
## Autoload #2: it depends on nothing (no I18n, no GameState) so the data
## layer is queryable before GameState finishes initialising.
##
## On a parse/shape failure the game must not crash: the error is printed via
## push_error, appended to [member load_errors] as a readable string, and the
## rest of the files still load. [member load_ok] then reports the failure so
## the title screen can show the data-error text (docs/90-* §11).
##
## The PNG→chunked-TileMap pipeline lives in scripts/world/map_loader.gd
## (docs/90-* §9). This script holds the handoff — [member map] plus the
## delegating lookups below — and resolves the single map index (§9.1).

const DATA_DIR := "res://data"
## The locked map id (docs/90-* §5.4: `world.map_id` is always this value).
const DEFAULT_MAP_ID := "world"

## Loaded from `res://data/`: ports, goods, ship_types, nations, officers,
## equipment, discoveries, quests (all envelope files), plus the Phase-5
## npc/economy tables npc_config.json, named_pirates.json and
## market_events.json, the Phase-6 ocean tables wind_regions.json,
## ocean_currents.json and ice_regions.json, the route-builder artifact
## trade_routes_built.json, and the two non-entity tables ui_strings.json and
## map_legend.json. Phase 8 retires `npc_captains.json` (the name pools —
## the canon `captains.json` + `captain_states` replace it, docs/10-* §7.7;
## the validator asserts the file's absence, §8.6 item 1).

## True when every data file loaded and passed the light shape checks.
var load_ok: bool = false
## Human-readable failure lines, each also pushed to the console.
var load_errors: Array[String] = []

# Id-keyed entity dictionaries (docs/90-* §5.2).
var ports: Dictionary = {}
var goods: Dictionary = {}
var ship_types: Dictionary = {}
var nations: Dictionary = {}
var officers: Dictionary = {}
var equipment: Dictionary = {}
var discoveries: Dictionary = {}
var quests: Dictionary = {}
## The 4 named pirates (docs/10-* §4.12).
var named_pirates: Dictionary = {}
## Demand-event templates (docs/10-* §4.13).
var market_events: Dictionary = {}
## Phase-6 seasonal layers (docs/10-* §4.16–4.18), id-keyed like the entity
## tables. The baked lookups live in the rasters (wind_regions.png /
## currents.png, decoded by scripts/world/ocean_layers.gd from Phase 6 task F);
## these tables are the authored sources — the wind regions' month tables and
## the ice polygons' month windows.
var wind_regions: Dictionary = {}
var ocean_currents: Dictionary = {}
var ice_regions: Dictionary = {}
## The route-builder artifact (`data/trade_routes_built.json`, docs/10-* §4.14):
## per-lane tile paths, the junction graph the runtime routes over, and the
## per-port spokes. Tool output of `tools/build_routes.py` — never hand-edited
## (AGENTS.md); runtime lane routing is Phase-5 task J (`60-*` §4.1).
var trade_routes_built: Dictionary = {}
## Facility opening hours (`data/facility_hours.json`, docs/10-* §4.19,
## added 2026-11-02): `default` windows per facility id + per-port
## `overrides`. Read through `SailingSim.facility_open`, never directly.
var facility_hours: Dictionary = {}
## Phase-8 canon/data files (docs/10-* §4.11, §4.20–§4.22): the tool-built
## captain canon (read-only, `10-*` §4.11) and the three authored tables —
## creation backgrounds, the data-driven skill/stat gates, and the officer
## post table. Gates are keyed by `feature_id`, posts by `post_id`.
var captains: Dictionary = {}
var backgrounds: Dictionary = {}
var skill_gates: Dictionary = {}
var officer_posts: Dictionary = {}

# Insertion-ordered lists copied from the JSON arrays. UI iteration uses these
# (market rows sort by base_price later; the nationality screen needs the
# fixed nation order from data/nations.json).
var ports_list: Array = []
var goods_list: Array = []
var ship_types_list: Array = []
var nations_list: Array = []
var officers_list: Array = []
var equipment_list: Array = []
var discoveries_list: Array = []
var quests_list: Array = []
var named_pirates_list: Array = []
var market_events_list: Array = []
## Phase-8 lists, file order (docs/10-* §4.11, §4.20–§4.22).
var captains_list: Array = []
var backgrounds_list: Array = []
var skill_gates_list: Array = []
var officer_posts_list: Array = []
## The Phase-6 ocean tables in file order. `wind_regions_list` doubles as the
## raster's index map: palette index i of wind_regions.png is
## `wind_regions_list[i - 1]` (docs/10-* §6.5), so the runtime resolves a
## baked region id without re-deriving any order.
var wind_regions_list: Array = []
var ocean_currents_list: Array = []
var ice_regions_list: Array = []
## Lanes and spokes of the built route artifact, id-keyed for lookup
## (`lanes` by lane id, `spokes` by port id — docs/10-* §4.14).
var route_lanes: Dictionary = {}
var route_spokes: Dictionary = {}

# Raw (NOT id-keyed) tables.
var ui_strings: Dictionary = {}
## The single map legend (`data/map_legend.json`, docs/90-* §9.1): grid,
## tiles and tile size for the one world map.
var map_legend: Dictionary = {}
## The density-dial config block (`data/npc_config.json`, docs/10-* §4.10):
## presets, budgets, flow and the absolute fleet cap. Not an entity file —
## one config object, no id-keyed array.
var npc_config: Dictionary = {}

## Map index (`data/maps/maps.json`, docs/90-* §9.1): exactly one entry,
## `id: "world"`.
var map_index: Array = []

## The studio layout-override table (`data/ui_layout.json`, docs/10-* §4.23,
## docs/80-* §4.8.9): per-screen, per-element overrides in chrome tiles.
## Ships `{}` — every absent override means the code-pinned default. Light
## shape checks here; the heavy validation is group 14 (docs/10-* §8.9).
var ui_layout: Dictionary = {}
## The raw bytes of `ui_layout.json` as of the last read — the drift
## check behind `reload_ui_layout_if_changed` (the studio's commit
## lands on the next screen activation, no restart).
var _ui_layout_bytes: String = ""

## MapLoader instance over `data/maps/world.png` (docs/90-* §9). Null until the
## world scene (or [method ensure_map]) loads it.
var map = null


func _ready() -> void:
	load_all()


func load_all() -> void:
	load_ok = false
	load_errors.clear()

	ports_list = _load_list("ports", "ports.json")
	ports = _index_by_id(ports_list, "ports.json")

	goods_list = _load_list("goods", "goods.json")
	goods = _index_by_id(goods_list, "goods.json")

	ship_types_list = _load_list("ship_types", "ship_types.json")
	ship_types = _index_by_id(ship_types_list, "ship_types.json")

	nations_list = _load_list("nations", "nations.json")
	nations = _index_by_id(nations_list, "nations.json")

	officers_list = _load_list("officers", "officers.json")
	officers = _index_by_id(officers_list, "officers.json")

	equipment_list = _load_list("equipment", "equipment.json")
	equipment = _index_by_id(equipment_list, "equipment.json")

	discoveries_list = _load_list("discoveries", "discoveries.json")
	discoveries = _index_by_id(discoveries_list, "discoveries.json")

	quests_list = _load_list("quests", "quests.json")
	quests = _index_by_id(quests_list, "quests.json")

	# Phase 5 living economy (docs/10-* §4.10–4.13). Phase 8 retires
	# npc_captains.json (the name pools — docs/10-* §7.7).
	npc_config = _load_npc_config()
	named_pirates_list = _load_list("named_pirates", "named_pirates.json")
	named_pirates = _index_by_id(named_pirates_list, "named_pirates.json")
	market_events_list = _load_list("market_events", "market_events.json")
	market_events = _index_by_id(market_events_list, "market_events.json")

	# Phase 6 seasonal ocean layers (docs/10-* §4.16–4.18): plural key ==
	# basename, so the ordinary entity-file path loads them (§3.2).
	wind_regions_list = _load_list("wind_regions", "wind_regions.json")
	wind_regions = _index_by_id(wind_regions_list, "wind_regions.json")
	ocean_currents_list = _load_list("ocean_currents", "ocean_currents.json")
	ocean_currents = _index_by_id(ocean_currents_list, "ocean_currents.json")
	ice_regions_list = _load_list("ice_regions", "ice_regions.json")
	ice_regions = _index_by_id(ice_regions_list, "ice_regions.json")

	# Tool-owned route artifact (docs/10-* §4.14) — not an entity file.
	trade_routes_built = _load_trade_routes_built()
	route_lanes = _index_route_lanes(trade_routes_built)
	route_spokes = _index_route_spokes(trade_routes_built)

	# Facility opening hours (docs/10-* §4.19, added 2026-11-02) — another
	# plain object file, like npc_config.
	facility_hours = _load_facility_hours()

	# Phase-8 canon/data files (docs/10-* §4.11, §4.20–§4.22): plural key ==
	# basename, so the ordinary entity-file path loads them. Captains are the
	# tool-built canon (never hand-edited); the other three are authored.
	captains_list = _load_list("captains", "captains.json")
	captains = _index_by_id(captains_list, "captains.json")
	backgrounds_list = _load_list("backgrounds", "backgrounds.json")
	backgrounds = _index_by_id(backgrounds_list, "backgrounds.json")
	skill_gates_list = _load_list("skill_gates", "skill_gates.json")
	skill_gates = _index_by_key(skill_gates_list, "feature_id", "skill_gates.json")
	officer_posts_list = _load_list("officer_posts", "officer_posts.json")
	officer_posts = _index_by_key(officer_posts_list, "post_id", "officer_posts.json")

	ui_strings = _load_ui_strings()
	map_legend = _load_map_legend()
	ui_layout = _load_ui_layout()
	_load_map_index()

	load_ok = load_errors.is_empty()


# --- Queries ---------------------------------------------------------------

func get_port(id: String) -> Dictionary:
	return _lookup(ports, id)

func get_good(id: String) -> Dictionary:
	return _lookup(goods, id)

func get_ship_type(id: String) -> Dictionary:
	return _lookup(ship_types, id)

func get_nation(id: String) -> Dictionary:
	return _lookup(nations, id)

func get_officer(id: String) -> Dictionary:
	return _lookup(officers, id)

func get_equipment(id: String) -> Dictionary:
	return _lookup(equipment, id)

func get_discovery(id: String) -> Dictionary:
	return _lookup(discoveries, id)

func get_quest(id: String) -> Dictionary:
	return _lookup(quests, id)

## A named pirate by id (docs/10-* §4.12; each entry is a full canon card).
func get_named_pirate(id: String) -> Dictionary:
	return _lookup(named_pirates, id)

func get_market_event(id: String) -> Dictionary:
	return _lookup(market_events, id)


## A captain-canon card by id (docs/10-* §4.11; built, read-only).
func get_captain(id: String) -> Dictionary:
	return _lookup(captains, id)


## A creation background by id (docs/10-* §4.22).
func get_background(id: String) -> Dictionary:
	return _lookup(backgrounds, id)


## A data-driven skill/stat gate by `feature_id` (docs/10-* §4.20).
func get_skill_gate(feature_id: String) -> Dictionary:
	return _lookup(skill_gates, feature_id)


## An officer post by `post_id` (docs/10-* §4.21).
func get_officer_post(post_id: String) -> Dictionary:
	return _lookup(officer_posts, post_id)


## A wind region by id (docs/10-* §4.16).
func get_wind_region(id: String) -> Dictionary:
	return _lookup(wind_regions, id)


## An ocean current system by id (docs/10-* §4.17).
func get_ocean_current(id: String) -> Dictionary:
	return _lookup(ocean_currents, id)


## An ice region by id (docs/10-* §4.18).
func get_ice_region(id: String) -> Dictionary:
	return _lookup(ice_regions, id)


## A built lane's tile path etc. by lane id (docs/10-* §4.14).
func get_route_lane(id: String) -> Dictionary:
	return _lookup(route_lanes, id)


## A port's spoke (kind, connect, tile_path) by port id (docs/10-* §4.14).
func get_route_spoke(port_id: String) -> Dictionary:
	return _lookup(route_spokes, port_id)


## The junction graph the runtime routes over: `{node_count, nodes,
## edge_count, edges}` — nodes `[x, y]` tiles, edges `[a, b, tile_length]`
## index pairs (docs/10-* §4.14; Dijkstra lives in task J).
func route_junction_graph() -> Dictionary:
	var graph = trade_routes_built.get("junctions", null)
	return graph if graph is Dictionary else {}

## L10nString for a UI key, or {} when the key is absent.
func get_ui_string(key: String) -> Dictionary:
	var value = ui_strings.get(key, null)
	return value if value is Dictionary else {}


# --- Map index (docs/90-* §9.1) -------------------------------------------

## Every selectable map id, in `maps.json` order. Phase 4 ships exactly one:
## `["world"]`. There is no fallback ladder — a missing index is a data error.
func map_ids() -> Array:
	var out: Array = []
	for entry in map_index:
		if entry is Dictionary:
			var id := str((entry as Dictionary).get("id", ""))
			if not id.is_empty():
				out.append(id)
	return out


## The index entry for `map_id` (`{id, file, legend, name}`), or `{}` when the
## id is not in the index (a logged data error, never a silent fallback).
func get_map(map_id: String) -> Dictionary:
	for entry in map_index:
		if entry is Dictionary and str((entry as Dictionary).get("id", "")) == map_id:
			return entry
	push_error("DataLoader: '%s' is not in data/maps/maps.json (docs/90-* §9.1)"
		% map_id)
	return {}


## The legend record for `map_id`. Phase 4 has one legend for one map, so this
## answers with [member map_legend] for an indexed id and `{}` for anything
## else — there is no per-map legend cache to disagree with it.
func get_map_legend(map_id: String) -> Dictionary:
	return map_legend if map_ids().has(map_id) else {}


## Resolves the map's data file and legend together (what the loader needs).
func get_map_files(map_id: String) -> Dictionary:
	var entry := get_map(map_id)
	if entry.is_empty():
		return {}
	var id := str(entry.get("id", map_id))
	return {
		"id": id,
		"file": str(entry.get("file", "")),
		"legend": get_map_legend(id),
	}


## Loads `data/maps/world.png` into [member map] when nothing has yet.
##
## Loading a save straight into port (docs/80-* §4.6 routes to S4 when the save
## was taken in port) never instantiates S3, so `map` stays null — yet port-side
## systems need passability and harbor-pair tiles: NPC fleet spawning (`60-*``
## §4.11.11), discovery range checks, quest destination draws. This builds the
## same `MapLoader` the world scene would, from the map index, and is
## idempotent.
func ensure_map(map_id: String = "") -> bool:
	if map != null:
		return true
	var resolved := map_id
	if resolved.is_empty():
		resolved = DEFAULT_MAP_ID
		var state := get_node_or_null("/root/GameState")
		if state != null:
			var value = state.get("world")
			if value is Dictionary and (value as Dictionary).has("map_id"):
				resolved = str((value as Dictionary)["map_id"])
	var files := get_map_files(resolved)
	if files.is_empty():
		return false
	var loader_script := load("res://scripts/world/map_loader.gd")
	if loader_script == null:
		return false
	var loader = loader_script.new()
	var path := _res_path(str(files.get("file", "")))
	var legend = files.get("legend", {})
	if not (legend is Dictionary) or (legend as Dictionary).is_empty():
		push_error("DataLoader: '%s' has no legend (docs/90-* §9.1)" % resolved)
		return false
	if not loader.load_map(path, legend):
		push_error("DataLoader: cannot load the world map: %s" % loader.last_error)
		return false
	map = loader
	return true


# --- Map handoff (docs/90-* §9) -------------------------------------------

## True when a fleet may enter `cell` (x wraps, y bounded).
func is_passable(cell: Vector2i) -> bool:
	if map == null:
		return false
	return bool(map.is_passable(cell))


## Port id whose harbor (berth) tile is `cell`, or "" when none.
func port_id_at(cell: Vector2i) -> String:
	if map == null:
		return ""
	var value = map.port_id_at(cell)
	return value if value is String else ""


## Port id whose **shore** tile is `cell`, or "" when none (20-* §4.11.1).
func shore_port_at(cell: Vector2i) -> String:
	if map == null:
		return ""
	var value = map.shore_port_at(cell)
	return value if value is String else ""


## Harbor tile of `port_id`, or (-1,-1) when the map is not loaded / the port
## has no derivable tile. The one runtime source of port positions (§6.1).
func port_cell(port_id: String) -> Vector2i:
	if map == null:
		return Vector2i(-1, -1)
	var value = map.port_cell(port_id)
	return value if value is Vector2i else Vector2i(-1, -1)


## Shore tile of `port_id` (the `#` the port is drawn on and docked into), or
## (-1,-1) when the map is not loaded / the port has no shore tile.
func shore_cell(port_id: String) -> Vector2i:
	if map == null:
		return Vector2i(-1, -1)
	var value = map.shore_cell(port_id)
	return value if value is Vector2i else Vector2i(-1, -1)


# --- Loading helpers -------------------------------------------------------

func _lookup(table: Dictionary, id: String) -> Dictionary:
	var value = table.get(id, null)
	return value if value is Dictionary else {}


## `data/...` → `res://data/...`; a path already rooted at `res://` passes
## through unchanged.
static func _res_path(path: String) -> String:
	if path.begins_with("res://"):
		return path
	return "res://" + path


## JSON numbers arrive as floats; turn any value with no fractional part back
## into an int, recursively. Only used on freshly parsed data.
func _normalize_numbers(node):
	if node is float:
		var f := node as float
		if is_finite(f) and f == floor(f) and absf(f) < 9.0e15:
			return int(f)
		return f
	if node is Array:
		var out: Array = []
		out.resize(node.size())
		for index in node.size():
			out[index] = _normalize_numbers(node[index])
		return out
	if node is Dictionary:
		var out: Dictionary = {}
		for key in node:
			out[key] = _normalize_numbers(node[key])
		return out
	return node


func _record(message: String) -> void:
	load_errors.append(message)
	push_error("DataLoader: " + message)


func _read_json(file_name: String):
	var path := DATA_DIR.path_join(file_name)
	if not FileAccess.file_exists(path):
		_record("%s: file not found (%s)" % [file_name, path])
		return null
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		_record("%s: file is empty or unreadable (%s)" % [file_name, path])
		return null
	var parser := JSON.new()
	if parser.parse(text) != OK:
		_record("%s: JSON parse error at line %d: %s" % [
			file_name, parser.get_error_line(), parser.get_error_message()
		])
		return null
	# Godot's JSON parser has no integer type: every number arrives as a float.
	# Restore the schema's ints so `money`/`day`/`version` compare and format
	# correctly (e.g. "8300" and not "8300.0" in the HUD).
	return _normalize_numbers(parser.data)


func _load_list(plural: String, file_name: String) -> Array:
	var data = _read_json(file_name)
	if data == null:
		return []
	if not (data is Dictionary):
		_record("%s: top-level value must be an object" % file_name)
		return []
	var version = data.get("version", null)
	if not (version is int) or version is bool:
		_record("%s: envelope is missing an integer 'version'" % file_name)
	var list = data.get(plural, null)
	if not (list is Array):
		_record("%s: missing array '%s'" % [file_name, plural])
		return []
	return list


func _index_by_id(list: Array, file_name: String) -> Dictionary:
	return _index_by_key(list, "id", file_name)


## Indexes a list by an arbitrary string key field (`feature_id` for the
## gates, `post_id` for the posts — docs/10-* §4.20–§4.21). Same light shape
## checks as [method _index_by_id].
func _index_by_key(list: Array, key_field: String, file_name: String) -> Dictionary:
	var table: Dictionary = {}
	for index in list.size():
		var entry = list[index]
		if not (entry is Dictionary):
			_record("%s[%d]: entry must be an object" % [file_name, index])
			continue
		var id = entry.get(key_field, null)
		if not (id is String) or (id as String).is_empty():
			_record("%s[%d]: entry has no string '%s'" % [file_name, index, key_field])
			continue
		if table.has(id):
			_record("%s[%d]: duplicate id '%s'" % [file_name, index, id])
			continue
		table[id] = entry
	return table


func _load_ui_strings() -> Dictionary:
	var raw = _read_json("ui_strings.json")
	var table: Dictionary = {}
	if raw == null:
		return table
	if not (raw is Dictionary):
		_record("ui_strings.json: top-level value must be an object")
		return table
	for key in raw:
		if key == "version":
			# Envelope metadata, not an L10nString; keep the table type-pure.
			continue
		var value = raw[key]
		if not (value is Dictionary):
			_record("ui_strings.json: '%s' must be an L10nString object" % key)
			continue
		for locale in ["zh", "en"]:
			var text = value.get(locale, null)
			if not (text is String) or (text as String).strip_edges().is_empty():
				_record("ui_strings.json: '%s.%s' is missing or empty" % [key, locale])
		table[key] = value
	return table


## Reads `data/ui_layout.json` — the absolute layout file, v2
## (docs/10-* §4.23, docs/80-* §4.8.9). Envelope `{version, screens}`;
## per screen `elements` (rects + optional sheet) and/or `lists`
## (computed-stacking blocks). Light shape checks only — key
## whitelist, types and screen-id membership; the heavy validation
## (canvas bounds, sheet enum, id regex, serialization bytes) is group
## 14 (docs/10-* §8.9). Returns the per-screen map
## `{screen: {elements: {}, lists: {}}}` — the registry's read shape.
## Absent file ⇒ `{}` (a missing file is NOT an error — every screen
## runs unmanaged/flow-free authored until the capture populates its
## table, unlike the entity tables). A file that is not v2 records an
## error and yields `{}` (no migration — the capture regenerates it).
func _load_ui_layout() -> Dictionary:
	if not FileAccess.file_exists(DATA_DIR.path_join("ui_layout.json")):
		return {}
	var text := FileAccess.get_file_as_string(
			DATA_DIR.path_join("ui_layout.json"))
	_ui_layout_bytes = text
	return _parse_ui_layout(text)


## Re-reads `ui_layout.json` when its bytes changed on disk (docs/80-*
## §4.8.9): the studio's commit lands on the next screen activation —
## no restart. A byte-identical file is a no-op, so a suite injecting
## `ui_layout` directly is never clobbered. The registry's
## `screen_active` calls this before applying.
func reload_ui_layout_if_changed() -> void:
	var path := DATA_DIR.path_join("ui_layout.json")
	if not FileAccess.file_exists(path):
		return
	var text := FileAccess.get_file_as_string(path)
	if text == _ui_layout_bytes:
		return
	_ui_layout_bytes = text
	ui_layout = _parse_ui_layout(text)


## The v2 shape walk shared by the boot load and the drift reload.
func _parse_ui_layout(text: String) -> Dictionary:
	var table: Dictionary = {}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		_record("ui_layout.json: invalid JSON (%s)"
				% parser.get_error_message())
		return table
	var raw: Variant = parser.data
	if not (raw is Dictionary):
		_record("ui_layout.json: top-level value must be an object")
		return table
	if raw.get("version", null) != 2:
		_record("ui_layout.json: 'version' must be 2 (10-* §4.23)")
		return table
	const SCREENS := ["port", "market", "inn", "guild", "provisions",
		"palace", "tavern", "shipyard",
		"title", "nationality_select", "creation",
		"world", "chart", "hail", "fleet_picker", "autopilot_hud",
		"battle", "sandbox", "duel",
		"confirm", "save_slot", "settings", "intel_window",
		"dialog_box", "dossier", "character_card", "captain_view",
		"fleet_view", "officer_roster", "reputation_view", "gameover",
		"ending"]
	const ELEMENT_KEYS := ["x", "y", "w", "h", "sheet"]
	var screens = raw.get("screens", null)
	if not (screens is Dictionary):
		_record("ui_layout.json: 'screens' must be an object")
		return table
	for screen in screens:
		if not (screen in SCREENS):
			_record("ui_layout.json: unknown screen '%s'" % screen)
			continue
		var data = screens[screen]
		if not (data is Dictionary):
			_record("ui_layout.json: screens.%s must be an object" % screen)
			continue
		var screen_table: Dictionary = {"elements": {}, "lists": {}}
		var elements = data.get("elements", {})
		if elements is Dictionary:
			for element in elements:
				var rect = elements[element]
				if not (rect is Dictionary):
					_record("ui_layout.json: screens.%s.%s must be an "
							+ "object" % [screen, element])
					continue
				for key in rect:
					if not (key in ELEMENT_KEYS):
						_record("ui_layout.json: screens.%s.%s: unknown "
								+ "key '%s'" % [screen, element, key])
				screen_table["elements"][element] = rect
		else:
			_record("ui_layout.json: screens.%s.elements must be an object"
					% screen)
		var lists = data.get("lists", {})
		if lists is Dictionary:
			screen_table["lists"] = lists
		elif data.has("lists"):
			_record("ui_layout.json: screens.%s.lists must be an object"
					% screen)
		table[screen] = screen_table
	return table


## Reads `data/trade_routes_built.json` — the route-builder artifact
## (docs/10-* §4.14). A tool output, not an entity file: the envelope is
## `{version, generated_by, artifact, build, lanes, spokes, junctions}`.
## Runtime consumption (Dijkstra over the graph, tile-path walking) is task J;
## this phase only loads and shape-checks it.
func _load_trade_routes_built() -> Dictionary:
	var data = _read_json("trade_routes_built.json")
	if data == null:
		return {}
	if not (data is Dictionary):
		_record("trade_routes_built.json: top-level value must be an object")
		return {}
	if not (data.get("version", null) is int):
		_record("trade_routes_built.json: missing integer 'version'")
	for key in ["generated_by", "artifact", "build", "lanes", "spokes",
			"junctions"]:
		if not data.has(key):
			_record("trade_routes_built.json: missing '%s' (docs/10-* §4.14)"
					% key)
	var junctions = data.get("junctions", null)
	if junctions is Dictionary:
		if not (junctions.get("nodes", null) is Array):
			_record("trade_routes_built.json: junctions.nodes must be an array")
		if not (junctions.get("edges", null) is Array):
			_record("trade_routes_built.json: junctions.edges must be an array")
	return data


## Indexes the built lanes by their `id` (light shape check only; the deep
## structural checks live in validator group 8, §8.3).
func _index_route_lanes(built: Dictionary) -> Dictionary:
	var lanes = built.get("lanes", null)
	if not (lanes is Array):
		return {}
	var table: Dictionary = {}
	for index in lanes.size():
		var lane = lanes[index]
		if not (lane is Dictionary) or not (lane.get("id", null) is String):
			_record("trade_routes_built.json: lanes[%d] has no string 'id'"
					% index)
			continue
		if not (lane.get("tile_path", null) is Array):
			_record("trade_routes_built.json: lane '%s' has no tile_path"
					% (lane["id"] as String))
			continue
		table[lane["id"] as String] = lane
	return table


## Indexes the built spokes by their `port` (docs/10-* §4.14).
func _index_route_spokes(built: Dictionary) -> Dictionary:
	var spokes = built.get("spokes", null)
	if not (spokes is Array):
		return {}
	var table: Dictionary = {}
	for index in spokes.size():
		var spoke = spokes[index]
		if not (spoke is Dictionary) or not (spoke.get("port", null) is String):
			_record("trade_routes_built.json: spokes[%d] has no string 'port'"
					% index)
			continue
		if not (spoke.get("tile_path", null) is Array):
			_record("trade_routes_built.json: spoke '%s' has no tile_path"
					% (spoke["port"] as String))
			continue
		table[spoke["port"] as String] = spoke
	return table


## Reads `data/npc_config.json` — the density-dial config block
## (docs/10-* §4.10). A config object, not an entity envelope: presets,
## budgets, flow and the absolute fleet cap, with no plural array.
func _load_npc_config() -> Dictionary:
	var data = _read_json("npc_config.json")
	if data == null:
		return {}
	if not (data is Dictionary):
		_record("npc_config.json: top-level value must be an object")
		return {}
	for key in ["version", "presets", "default_preset", "budgets", "flow",
			"absolute_cap"]:
		if not data.has(key):
			_record("npc_config.json: missing '%s' (docs/10-* §4.10)" % key)
	return data


## Reads `data/facility_hours.json` — the facility opening-hour table
## (docs/10-* §4.19, `30-*` §4.1b). A plain object file: `default` windows
## per facility id plus optional per-port `overrides`. Shape errors are
## recorded but never fatal here — the validator owns the full check; the
## runtime reads windows through `SailingSim.facility_open`, which falls back
## to "always open" on a missing entry so a bad file cannot close every port.
func _load_facility_hours() -> Dictionary:
	var data = _read_json("facility_hours.json")
	if data == null:
		return {}
	if not (data is Dictionary):
		_record("facility_hours.json: top-level value must be an object")
		return {}
	for key in ["version", "default", "overrides"]:
		if not data.has(key):
			_record("facility_hours.json: missing '%s' (docs/10-* §4.19)" % key)
	if not (data.get("default", {}) is Dictionary):
		_record("facility_hours.json: 'default' must be an object")
	if not (data.get("overrides", {}) is Dictionary):
		_record("facility_hours.json: 'overrides' must be an object")
	return data


## Reads `data/map_legend.json` — the single legend (docs/90-* §9.1). No
## per-tile port-marker table exists any more: ports are an overlay from lat/lon
## (`10-*` §6.2, decision 7).
func _load_map_legend() -> Dictionary:
	var data = _read_json("map_legend.json")
	if data == null:
		return {}
	if not (data is Dictionary):
		_record("map_legend.json: top-level value must be an object")
		return {}
	if not data.has("grid") or not data.has("tiles"):
		_record("map_legend.json: missing 'grid' or 'tiles'")
	return data


## Reads `data/maps/maps.json` (exactly one entry, docs/90-* §9.1) and binds
## its legend. A missing or empty index is a data error: there is no P1/P3
## fallback ladder any more.
func _load_map_index() -> void:
	map_index = []
	var data = _read_json("maps/maps.json")
	if not (data is Dictionary) or not (data.get("maps") is Array):
		_record("maps/maps.json: missing 'maps' array (docs/90-* §9.1)")
		return
	map_index = (data["maps"] as Array).duplicate(true)
	if map_index.is_empty():
		_record("maps/maps.json: the index has no entries (docs/90-* §9.1)")
	for entry in map_index:
		if not (entry is Dictionary):
			_record("maps/maps.json: every entry must be an object")
			continue
		var id := str((entry as Dictionary).get("id", ""))
		if id.is_empty():
			_record("maps/maps.json: an entry has no 'id'")
			continue
		var legend_path := str((entry as Dictionary).get("legend", ""))
		var file_path := str((entry as Dictionary).get("file", ""))
		if file_path.is_empty():
			_record("maps/maps.json: '%s' has no 'file' path" % id)
		else:
			for path in [file_path, legend_path]:
				if not (path.is_empty() or FileAccess.file_exists(_res_path(path))):
					_record("maps/maps.json: '%s' names a missing file %s" % [id, path])
		# The legend file is the same table already loaded as `map_legend`; the
		# index is authoritative about *which* file, so re-read it by that path
		# (a swapped legend file is a data-only change).
		if legend_path.is_empty():
			_record("maps/maps.json: '%s' has no 'legend' path" % id)
			continue
		var legend = _read_json(legend_path.trim_prefix("data/"))
		if not (legend is Dictionary):
			_record("maps/maps.json: legend '%s' is missing or invalid" % legend_path)
			continue
		if not (legend as Dictionary).has("grid") \
				or not (legend as Dictionary).has("tiles"):
			_record("maps/maps.json: legend '%s' lacks grid/tiles" % legend_path)
			continue
		if id == DEFAULT_MAP_ID:
			map_legend = legend
