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
## The ASCII→TileMap pipeline itself lives in scripts/world/map_loader.gd
## (T5). This script only holds the handoff: [member map] plus the two
## delegating lookups below.

const DATA_DIR := "res://data"

## Loaded from `res://data/`: ports, goods, ship_types, nations, officers,
## equipment, discoveries, quests (all envelope files), plus the two
## non-entity tables ui_strings.json and map_legend.json.

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

# Raw (NOT id-keyed) tables.
var ui_strings: Dictionary = {}
var map_legend: Dictionary = {}

## Map index (`data/maps/maps.json`, docs/90-* §9.1): the selectable maps, in
## file order. Its first entry is the fallback for an unknown id.
var map_index: Array = []
## `{map_id: legend}` so two legend files (`map_legend.json`,
## `map_legend_p3.json`) never overwrite one another.
var map_legends: Dictionary = {}
## `{map_id: MapLegend}` for the legacy default map, kept as the P1 legend so
## every Phase-1 caller (`DataLoader.map_legend`) keeps working unchanged.
var map_legends_loaded: Dictionary = {}

## MapLoader instance, assigned by T5 (docs/90-* §9). Null until then.
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

	ui_strings = _load_ui_strings()
	# map_legend.json is authored by T3; a missing file is recorded as an error
	# but must not abort the rest of the load (docs/90-* §5.2).
	map_legend = _load_map_legend()
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

## L10nString for a UI key, or {} when the key is absent.
func get_ui_string(key: String) -> Dictionary:
	var value = ui_strings.get(key, null)
	return value if value is Dictionary else {}


# --- Map index (docs/90-* §9.1) -------------------------------------------

## Every selectable map id, in `maps.json` order (["p1", "p3"]). Falls back to
## `["p1"]` when the index is missing so the P1 game still starts.
func map_ids() -> Array:
	var out: Array = []
	for entry in map_index:
		if entry is Dictionary:
			out.append(str((entry as Dictionary).get("id", "")))
	if out.is_empty():
		out.append("p1")
	return out


## The index entry for `map_id` (`{id, file, legend, name}`), or the first
## entry when the id is unknown, or `{}` when the index is unavailable.
func get_map(map_id: String) -> Dictionary:
	for entry in map_index:
		if entry is Dictionary and str((entry as Dictionary).get("id", "")) == map_id:
			return entry
	if map_index.is_empty():
		# Pre-index fallback: the locked Phase-1 map, so a data folder that has
		# not gained maps.json yet still loads (docs/90-* §9.1).
		return {
			"id": "p1", "file": "data/maps/p1_mediterranean.txt",
			"legend": "data/map_legend.json",
			"name": {"zh": "地中海与西欧", "en": "Mediterranean & Western Europe"},
		}
	var first = map_index[0]
	return first if first is Dictionary else {}


## The MapLegend record for `map_id`, loaded from that entry's `legend` path.
## A missing or malformed legend file records a load error and returns `{}`.
func get_map_legend(map_id: String) -> Dictionary:
	if map_legends.has(map_id):
		var cached = map_legends[map_id]
		return cached if cached is Dictionary else {}
	return {}


## Resolves the map's data file and legend together (what a map loader needs).
func get_map_files(map_id: String) -> Dictionary:
	var entry := get_map(map_id)
	if entry.is_empty():
		return {}
	return {
		"id": str(entry.get("id", map_id)),
		"file": str(entry.get("file", "")),
		"legend": get_map_legend(str(entry.get("id", map_id))),
	}


# --- Map handoff (docs/90-* §9) -------------------------------------------

func is_passable(cell: Vector2i) -> bool:
	if map == null:
		return false
	if map.has_method("is_passable"):
		return bool(map.is_passable(cell))
	return false


func port_id_at(cell: Vector2i) -> String:
	if map == null:
		return ""
	if map.has_method("port_id_at"):
		var value = map.port_id_at(cell)
		if value is String:
			return value
	return ""


# --- Loading helpers -------------------------------------------------------

func _lookup(table: Dictionary, id: String) -> Dictionary:
	var value = table.get(id, null)
	return value if value is Dictionary else {}


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
	var table: Dictionary = {}
	for index in list.size():
		var entry = list[index]
		if not (entry is Dictionary):
			_record("%s[%d]: entry must be an object" % [file_name, index])
			continue
		var id = entry.get("id", null)
		if not (id is String) or (id as String).is_empty():
			_record("%s[%d]: entry has no string 'id'" % [file_name, index])
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


## Reads `data/maps/maps.json` and every legend it names (docs/90-* §9.1).
## A missing index is not an error in Phase 1/2 data: [method get_map] then
## synthesises the single P1 entry, and `map_legends["p1"]` is the P1 legend
## that [method _load_map_legend] already read.
func _load_map_index() -> void:
	map_index = []
	map_legends = {}
	map_legends_loaded = {}
	var data = _read_json("maps/maps.json")
	if data is Dictionary and data.get("maps") is Array:
		map_index = (data["maps"] as Array).duplicate(true)
	if map_index.is_empty():
		map_index = [{
			"id": "p1", "file": "data/maps/p1_mediterranean.txt",
			"legend": "data/map_legend.json",
			"name": {"zh": "地中海与西欧", "en": "Mediterranean & Western Europe"},
		}]
	# The P1 legend is already loaded as `map_legend`; reuse it rather than
	# re-reading the file so both accessors can never disagree.
	map_legends["p1"] = map_legend
	for entry in map_index:
		if not (entry is Dictionary):
			_record("maps/maps.json: every entry must be an object")
			continue
		var id := str((entry as Dictionary).get("id", ""))
		var path := str((entry as Dictionary).get("legend", ""))
		if id.is_empty():
			_record("maps/maps.json: an entry has no 'id'")
			continue
		if map_legends.has(id) and not (map_legends[id] as Dictionary).is_empty():
			continue
		if path.is_empty():
			_record("maps/maps.json: '%s' has no 'legend' path" % id)
			continue
		var legend = _read_json(path.trim_prefix("data/"))
		if not (legend is Dictionary):
			_record("maps/maps.json: legend '%s' is missing or invalid" % path)
			continue
		if not (legend as Dictionary).has("grid") \
				or not (legend as Dictionary).has("tiles"):
			_record("maps/maps.json: legend '%s' lacks grid/tiles" % path)
			continue
		map_legends[id] = legend
		map_legends_loaded[id] = true
