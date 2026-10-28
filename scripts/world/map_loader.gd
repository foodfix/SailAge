class_name MapLoader
extends RefCounted
## ASCII world map → TileMap (docs/90-ARCHITECTURE.md §9, docs/10-DATA-SCHEMA.md §6).
##
## Pure logic plus TileMap construction: no randomness, no GameState access, no
## imported assets. The only node type this script creates is the TileMap it
## renders into, so the parsing/passability half stays unit-testable headless.
##
## Pipeline (docs/90-* §9, steps 1–6):
##   1. read the map text (`load_map`)             → 96 rows × 128 chars
##   2. read the legend (`DataLoader.map_legend`)  → chars, kinds, constants
##   3. layer 0 = terrain, one programmatic 32×32 colored-square tile per char
##   4. layer 1 = ports, a 32×32 nation-colored square + English initial label
##   5. `is_passable()` consults the legend; marker cells are always passable
##   6. the scene only ever asks this object, it never re-reads the text file
##
## The tileset is built in memory from `Image`/`ImageTexture` rectangles in the
## locked palette (docs/80-* §4.8). No texture file is imported: the atlas is
## generated at startup from the same color constants the rest of the UI uses.
##
## `Palette` is preloaded instead of referenced through its global class name so
## this script also runs before Godot has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")

## Marker cells sit on sea per docs/10-* §6.2.
const MARKER_TERRAIN_KIND := "sea"

var width: int = 0
var height: int = 0
## Rendering size of one cell (docs/10-* §6.1: 32 px).
var tile_size_px: int = 32

## One string per map row, `height` entries × `width` chars (step 1).
var tiles: Array[String] = []
## Marker cell → port id (step 4).
var port_at: Dictionary = {}
## Marker char → cell; the inverse of [member port_at].
var marker_at: Dictionary = {}

## Normalised legend, kept so rendering/passability agree with one source.
var legend_tiles: Dictionary = {}

## Readable reason for the last parse/load failure; "" when loading worked.
var last_error: String = ""


# --- Loading ---------------------------------------------------------------

## Parses map text against the legend. Returns a populated MapLoader, or null
## after `push_error` on a dimension mismatch or an illegal character.
## Static + untyped return so a headless run without the editor class cache
## still resolves it (`preload(...).parse(...)`).
static func parse(text: String, legend: Dictionary):
	var loader = new()
	if not _fill(loader, text, legend):
		return null
	return loader


## Parses into an existing instance so `load_map` keeps the specific failure
## reason on [member last_error] instead of throwing it away.
static func _fill(loader, text: String, legend: Dictionary) -> bool:
	if not (legend is Dictionary) or legend.is_empty():
		loader.last_error = "map legend is empty or missing"
		push_error("MapLoader: " + loader.last_error)
		return false
	var grid = legend.get("grid", null)
	if not (grid is Dictionary):
		loader.last_error = "legend is missing the 'grid' object"
		push_error("MapLoader: " + loader.last_error)
		return false
	# JSON numbers arrive as floats; cast defensively (never assume int).
	var map_width := int(grid.get("width", 0))
	var map_height := int(grid.get("height", 0))
	if map_width <= 0 or map_height <= 0:
		loader.last_error = "legend grid.width/height must be positive ints (got %d×%d)" % [
			map_width, map_height
		]
		push_error("MapLoader: " + loader.last_error)
		return false

	var tile_defs = legend.get("tiles", null)
	if not (tile_defs is Dictionary) or tile_defs.is_empty():
		loader.last_error = "legend is missing the 'tiles' table"
		push_error("MapLoader: " + loader.last_error)
		return false
	var markers = legend.get("port_markers", null)
	if not (markers is Dictionary):
		loader.last_error = "legend is missing the 'port_markers' table"
		push_error("MapLoader: " + loader.last_error)
		return false

	loader.width = map_width
	loader.height = map_height
	loader.tile_size_px = int(legend.get("tile_size_px", 32))
	loader.legend_tiles = _normalize_tiles(tile_defs)
	loader.tiles.clear()
	loader.port_at.clear()
	loader.marker_at.clear()

	var lines := _split_lines(text)
	if lines.size() != map_height:
		loader.last_error = "map has %d lines, legend grid.height is %d" % [
			lines.size(), map_height
		]
		push_error("MapLoader: " + loader.last_error)
		return false

	for y in map_height:
		var line: String = lines[y]
		if line.length() != map_width:
			loader.last_error = "map line %d has %d chars, legend grid.width is %d" % [
				y, line.length(), map_width
			]
			push_error("MapLoader: " + loader.last_error)
			return false
		loader.tiles.append(line)
		for x in map_width:
			var ch: String = line[x]
			if loader.legend_tiles.has(ch):
				continue
			var port_id = markers.get(ch, null)
			if port_id is String and not (port_id as String).is_empty():
				var cell := Vector2i(x, y)
				if loader.marker_at.has(ch):
					loader.last_error = "port marker '%s' appears more than once (first at %s, again at %s)" % [
						ch, loader.marker_at[ch], cell
					]
					push_error("MapLoader: " + loader.last_error)
					return false
				loader.marker_at[ch] = cell
				loader.port_at[cell] = port_id
				continue
			loader.last_error = "illegal map char '%s' at (%d,%d); not in legend.tiles or legend.port_markers" % [
				ch, x, y
			]
			push_error("MapLoader: " + loader.last_error)
			return false

	loader.last_error = ""
	return true


## Reads `path` and replaces this instance's parsed state. False (with
## [member last_error] set) on a missing file or any parse failure.
## The path is a plain argument, so swapping maps stays a zero-code-edit change.
func load_map(path: String, legend: Dictionary) -> bool:
	if not FileAccess.file_exists(path):
		last_error = "map file not found: %s" % path
		push_error("MapLoader: " + last_error)
		return false
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		last_error = "map file is empty or unreadable: %s" % path
		push_error("MapLoader: " + last_error)
		return false
	# Parses in place, so a failure keeps its specific reason for the caller.
	return _fill(self, text, legend)


# --- Queries ---------------------------------------------------------------

## Char at `cell`, or "" out of bounds.
func char_at(cell: Vector2i) -> String:
	if not _in_bounds(cell):
		return ""
	return tiles[cell.y][cell.x]


## True when a fleet may enter `cell` (docs/20-* §4.1): in bounds, port marker
## cells always passable, otherwise the legend's `passable` flag.
func is_passable(cell: Vector2i) -> bool:
	if not _in_bounds(cell):
		return false
	if port_at.has(cell):
		return true
	var def = legend_tiles.get(char_at(cell), null)
	if def is Dictionary:
		# `== true` (not truthiness) so the contract is a real bool.
		return def.get("passable", false) == true
	return false


## Port id whose marker occupies `cell`, or "" when none.
func port_id_at(cell: Vector2i) -> String:
	var value = port_at.get(cell, null)
	return value if value is String else ""


## Terrain kind at `cell`: a legend `kind` string, "sea" for a marker cell
## (markers sit on sea, docs/10-* §6.2), or "" out of bounds.
func terrain_kind(cell: Vector2i) -> String:
	if not _in_bounds(cell):
		return ""
	if port_at.has(cell):
		return MARKER_TERRAIN_KIND
	var def = legend_tiles.get(char_at(cell), null)
	if def is Dictionary:
		var kind = def.get("kind", "")
		if kind is String:
			return kind
	return ""


## Cell of `port_id`'s marker, or (-1,-1) when it does not appear on this map.
func port_cell(port_id: String) -> Vector2i:
	for cell in port_at:
		if port_at[cell] == port_id:
			return cell
	return Vector2i(-1, -1)


## `{kind: cell_count}` census over the whole grid; marker cells count as sea.
## Used by the T5 verification and handy for debugging a swapped map.
func terrain_census() -> Dictionary:
	var census: Dictionary = {}
	for y in height:
		for x in width:
			var kind := terrain_kind(Vector2i(x, y))
			census[kind] = int(census.get(kind, 0)) + 1
	return census


# --- Rendering (docs/90-* §9 steps 3–4) ------------------------------------

## Builds the world TileMap under `parent` and returns it.
##
## Layer 0 "Terrain": one cell per map char; marker cells draw the underlying
## sea tile. Layer 1 "Ports": a 32×32 square in the port's nation color plus a
## Label with the first letter of the port's English name.
##
## `ports`/`nations` are the id-keyed tables from DataLoader; passing them in
## keeps this RefCounted class free of autoload dependencies.
func build_tilemap(parent: Node2D, ports: Dictionary = {}, nations: Dictionary = {}) -> TileMap:
	var plan := _build_atlas(nations)

	var tile_map := TileMap.new()
	tile_map.name = "MapTileMap"
	tile_map.tile_set = plan["tile_set"]
	# TileMap starts with one layer (index 0); append the port layer.
	tile_map.add_layer(-1)
	tile_map.set_layer_name(0, "Terrain")
	tile_map.set_layer_name(1, "Ports")

	var source_id: int = plan["source_id"]
	var kind_index: Dictionary = plan["kind_index"]
	var cell_size := Vector2i(tile_size_px, tile_size_px)

	# Layer 0 — terrain: one cell per map char, straight 12,288-cell fill that
	# runs once at load. Batching is the TileMap's job (per-quadrant render).
	for y in height:
		for x in width:
			var kind := terrain_kind(Vector2i(x, y))
			var index := int(kind_index.get(kind, plan["fallback_index"]))
			tile_map.set_cell(0, Vector2i(x, y), source_id, Vector2i(index, 0))

	# Layer 1 — port markers, one nation-colored tile per port cell.
	var nation_index: Dictionary = plan["nation_index"]
	for cell in port_at:
		var port_id: String = port_at[cell]
		var port = ports.get(port_id, null)
		var nation_id := ""
		if port is Dictionary:
			var raw = port.get("nation_id", "")
			if raw is String:
				nation_id = raw
		var index := int(nation_index.get(nation_id, plan["fallback_port_index"]))
		tile_map.set_cell(1, cell, source_id, Vector2i(index, 0))
		tile_map.add_child(_build_port_label(cell, port, cell_size))

	parent.add_child(tile_map)
	return tile_map


# --- Internals -------------------------------------------------------------

## Strips an optional BOM/CRs and splits on newlines, dropping the single empty
## entry produced by a trailing newline. Blank lines inside the file are kept
## so the line-count check names them.
static func _split_lines(text: String) -> Array[String]:
	var clean := text
	if clean.begins_with("\uFEFF"):
		clean = clean.substr(1)
	clean = clean.replace("\r\n", "\n").replace("\r", "\n")
	var raw := clean.split("\n")
	if not raw.is_empty() and raw[raw.size() - 1] == "":
		raw.remove_at(raw.size() - 1)
	var out: Array[String] = []
	for line in raw:
		out.append(line)
	return out


## Copies legend tile entries into a plain `char → {kind, passable}` table with
## real bools/strings, discarding anything malformed.
static func _normalize_tiles(tile_defs: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for ch in tile_defs:
		var raw = tile_defs[ch]
		if not (raw is Dictionary):
			continue
		var kind = raw.get("kind", "")
		out[ch] = {
			"kind": kind if kind is String else "",
			"passable": raw.get("passable", false) == true,
		}
	return out


func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < width and cell.y >= 0 and cell.y < height


## Builds the in-memory TileSet atlas: one 32×32 colored square per legend
## terrain kind, then one per nation color, then a fallback marker color.
## Index 0 of the atlas is always the first terrain kind.
func _build_atlas(nations: Dictionary) -> Dictionary:
	var kinds: Array[String] = []
	for ch in legend_tiles:
		var kind: String = legend_tiles[ch]["kind"]
		if not kinds.has(kind):
			kinds.append(kind)
	if kinds.is_empty():
		kinds.append(MARKER_TERRAIN_KIND)

	var colors: Array[Color] = []
	var kind_index: Dictionary = {}
	for kind in kinds:
		kind_index[kind] = colors.size()
		colors.append(_kind_color(kind))

	# Nation slots, in the sorted nation-id order of the passed table so the
	# atlas is stable regardless of JSON key order.
	var nation_index: Dictionary = {}
	var nation_ids: Array = nations.keys()
	nation_ids.sort()
	for nation_id in nation_ids:
		var nation = nations[nation_id]
		if not (nation is Dictionary):
			continue
		var hex = nation.get("color", "")
		if not (hex is String) or not Color.html_is_valid(hex):
			continue
		nation_index[nation_id] = colors.size()
		colors.append(PaletteLib.nation_color(hex))

	var fallback_port_index := colors.size()
	colors.append(PaletteLib.ACCENT)

	var image := Image.create_empty(colors.size() * tile_size_px, tile_size_px, false, Image.FORMAT_RGBA8)
	for index in colors.size():
		image.fill_rect(
			Rect2i(index * tile_size_px, 0, tile_size_px, tile_size_px),
			colors[index]
		)
	var texture := ImageTexture.create_from_image(image)

	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(tile_size_px, tile_size_px)
	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = Vector2i(tile_size_px, tile_size_px)
	for index in colors.size():
		source.create_tile(Vector2i(index, 0))
	var source_id := tile_set.add_source(source)

	return {
		"tile_set": tile_set,
		"source_id": source_id,
		"kind_index": kind_index,
		"nation_index": nation_index,
		"fallback_index": int(kind_index.get(MARKER_TERRAIN_KIND, 0)),
		"fallback_port_index": fallback_port_index,
	}


static func _kind_color(kind: String) -> Color:
	match kind:
		"sea":
			return PaletteLib.SEA
		"coastal_sea":
			return PaletteLib.COAST_SEA
		"land":
			return PaletteLib.LAND
		"reef":
			return PaletteLib.REEF
		_:
			return PaletteLib.PANEL_LINE


## 32×32 Label centered on the marker cell with the English name's initial.
func _build_port_label(cell: Vector2i, port, cell_size: Vector2i) -> Label:
	var initial := "?"
	if port is Dictionary:
		var name = port.get("name", null)
		if name is Dictionary:
			var english = name.get("en", "")
			if english is String and not (english as String).is_empty():
				initial = (english as String).substr(0, 1)
	var label := Label.new()
	label.name = "Port_%s" % port_at.get(cell, "unknown")
	label.text = initial
	label.position = Vector2(cell.x * cell_size.x, cell.y * cell_size.y)
	label.size = Vector2(cell_size.x, cell_size.y)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	label.z_index = 1
	return label
