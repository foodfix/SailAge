class_name MapLoader
extends RefCounted
## Terra Vera world map: indexed PNG → wrap-aware grid + on-demand chunk TileMaps
## (docs/90-ARCHITECTURE.md §9/§9.1, docs/10-DATA-SCHEMA.md §6.1–§6.3,
## docs/20-WORLD-AND-SAILING.md §4.1/§4.11, docs/80-UI-UX.md §4.5/§4.8).
##
## Pure logic plus rendering nodes: no randomness, no GameState writes, no
## imported assets. The only nodes this script creates are the chunk TileMapLayer
## and port-overlay nodes it renders, so the load/passability/harbor half stays
## unit-testable headless.
##
## Pipeline (§9 steps 1–7):
##   1. read the PNG bytes (`FileAccess`) and decode them (`Image.load_png_from_buffer`);
##      the artifact is **data, not an imported texture** (§6.3).
##   2. verify the IHDR: indexed colour (type 3), 8-bit, non-interlaced, and a
##      2160×1080 grid (the legend's `grid` is the expected size, so a swapped
##      map needs no code edit). Decode the PLTE palette and map every pixel
##      colour back to its palette index; an index outside the locked 0–4 set
##      is a load error naming the index and a sample tile.
##   3. passability = one byte per tile (`indices`, ~2.3 MB), `is_passable` is
##      wrap-aware on x and closed at the latitude edges.
##   4. the harbor **pair** is derived from `Port.lat/lon`: the berth tile with
##      the locked §6.1 snap rule and the shore tile as the nearest orthogonally
##      adjacent `#` (20-* §4.11.1) — cached; `harbor_tiles()` for all 100.
##   5. rendering = 128×128-tile chunk layers generated on demand around the
##      camera, at most 24 live, freed beyond a one-chunk margin.
##   6. ports = an overlay layer (nation square + label) on the **shore** tile
##      plus a berth marker on the sea tile, wrap-duplicated at the seam.
##   7. the world scene only ever queries this object; it never re-reads the PNG.
##
## `Palette` is preloaded instead of referenced through its global class name so
## this script also runs before Godot has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")

# --- Locked constants (docs/10-* §6.1–§6.3) --------------------------------

## §6.3: palette index 0–4 = `~ . # ^ I`, in that locked order (append-only).
const PALETTE_CHARS := "~.#^I"
## §6.2: only `~` (index 0) and `.` (index 1) are passable.
const PASSABLE_INDICES: Array[int] = [0, 1]
## §6.1: harbor (berth) tile within Chebyshev 2 of the port's lat/lon.
const HARBOR_SNAP_TILES := 2
## §6.2: palette index 2 = `#`, the only tile a port's shore tile may be.
const LAND_INDEX := 2
## The four orthogonal neighbours; docking and the shore-tile derivation are
## orthogonal-only (20-* §4.11.1 "never diagonal").
const ORTHOGONAL_STEPS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

# --- Rendering (docs/90-* §9 step 4) --------------------------------------

## §9 step 4: 128×128-tile chunk TileMaps, at most 24 live.
const CHUNK_TILES := 128
const MAX_LIVE_CHUNKS := 24
## One chunk ring beyond the viewport, so a camera nudge never shows void.
const CHUNK_MARGIN := 1
## 1280×720 at `TILE_SIZE_PX` = 32 → 40×23 tiles. The scene passes its own
## value; this default keeps [method update_chunks] usable stand-alone.
const DEFAULT_VIEW_TILES := Vector2i(40, 23)
## Rough per-cell footprint of a TileMapLayer cell (quadrant + cell data); only
## used by [method live_chunk_bytes_estimate] for the < 50 MB debug assert.
const MEMORY_PER_CELL_BYTES := 16
## A port this close to the seam is also drawn on the other side of it
## (§9 step 5: `x = 0` also shows at `x = 2160` and vice versa).
const SEAM_MARGIN := 8

## The one PNG the loader ships with (docs/90-* §9.1); `load_map` takes the
## path as an argument so swapping it is a data-only change.
const WORLD_PNG := "res://data/maps/world.png"

var width: int = 0
var height: int = 0
## Rendering size of one cell (docs/10-* §6.1: 32 px).
var tile_size_px: int = 32

## One palette index per tile, row-major (`width * height` bytes, §9 step 3).
var indices := PackedByteArray()

## Normalised legend tiles, `char → {kind, passable}` (one source for rendering
## and passability).
var legend_tiles: Dictionary = {}
## `char → palette index`, the locked §6.3 order. Built from the constant rather
## than re-typed so a synthetic [method from_indices] map uses the same indices
## the shipped artifact does.
var palette_chars: Dictionary = _default_palette()


static func _default_palette() -> Dictionary:
	var table: Dictionary = {}
	for index in PALETTE_CHARS.length():
		table[PALETTE_CHARS[index]] = index
	return table

## Readable reason for the last load failure; "" when loading worked.
var last_error: String = ""

# --- Caches (lazy, invalidated by a load) ----------------------------------

## `port_id → Vector2i` derived from lat/lon (§6.1), computed once. This is the
## **berth** tile: the sea tile the fleet stands on.
var _harbor_tiles: Dictionary = {}
var _harbor_ready := false
## `Vector2i(x mod width, y) → port_id`, the inverse of [member _harbor_tiles].
var _port_at: Dictionary = {}
var _port_at_ready := false
## `port_id → Vector2i` shore tile (20-* §4.11.1), computed once: the `#` tile
## orthogonally adjacent to the berth nearest the port's lat/lon projection.
var _shore_tiles: Dictionary = {}
var _shore_ready := false
## `Vector2i(x mod width, y) → port_id`, the inverse of [member _shore_tiles].
var _shore_at: Dictionary = {}
var _shore_at_ready := false

# --- Rendering state -------------------------------------------------------

var _tile_set: TileSet = null
var _atlas_source_id := -1
var _chunks_root: Node2D = null
var _chunks: Dictionary = {}
var _port_overlay: Node2D = null
var _port_nodes: Dictionary = {}
var _last_center := Vector2i(-1, -1)
var _last_view := Vector2i(-1, -1)
## Known-port ids the overlay was last built for (skips a rebuild per step).
var _overlay_known: Array = []


# --- Loading ---------------------------------------------------------------

## Reads `path` and replaces this instance's loaded state. False (with
## [member last_error] set) on a missing file or any artifact failure.
## `legend` supplies the expected grid and the tile table (§6.1/§6.3).
func load_map(path: String, legend: Dictionary) -> bool:
	if not FileAccess.file_exists(path):
		last_error = "map file not found: %s" % path
		push_error("MapLoader: " + last_error)
		return false
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		last_error = "map file is empty or unreadable: %s" % path
		push_error("MapLoader: " + last_error)
		return false
	return load_png_buffer(bytes, path, legend)


## Decodes an in-memory artifact. Split out so a test can prove the loader is
## data-driven from an `Image`-built buffer without writing a file.
func load_png_buffer(bytes: PackedByteArray, label: String, legend: Dictionary) -> bool:
	if not (legend is Dictionary) or legend.is_empty():
		return _fail("map legend is empty or missing")
	var grid = legend.get("grid", null)
	if not (grid is Dictionary):
		return _fail("legend is missing the 'grid' object")
	var expected_width := int((grid as Dictionary).get("width", 0))
	var expected_height := int((grid as Dictionary).get("height", 0))
	if expected_width <= 0 or expected_height <= 0:
		return _fail("legend grid.width/height must be positive ints (got %d×%d)" % [
			expected_width, expected_height
		])
	var tile_defs = legend.get("tiles", null)
	if not (tile_defs is Dictionary) or (tile_defs as Dictionary).is_empty():
		return _fail("legend is missing the 'tiles' table")
	var tiles := _normalize_tiles(tile_defs)
	for index in PALETTE_CHARS.length():
		var ch: String = PALETTE_CHARS[index]
		if not tiles.has(ch):
			return _fail("legend.tiles has no '%s' entry (palette index %d, §6.3)"
				% [ch, index])

	# The artifact is contracted as indexed colour (§6.3), so the PNG header is
	# checked before decoding: a truecolour PNG is a data error, not a guess.
	var header := _read_png_header(bytes)
	if header.is_empty():
		return _fail("%s: not a PNG or the IHDR chunk is truncated" % label)
	var png_width := int(header.get("width", 0))
	var png_height := int(header.get("height", 0))
	if png_width != expected_width or png_height != expected_height:
		return _fail("%s: artifact is %d×%d pixels, the locked grid is %d×%d" % [
			label, png_width, png_height, expected_width, expected_height
		])
	if int(header.get("colour_type", -1)) != 3:
		return _fail(
			"%s: not an indexed-colour PNG (IHDR colour type %d, expected 3, §6.3)"
			% [label, int(header.get("colour_type", -1))]
		)
	if int(header.get("bit_depth", -1)) != 8:
		return _fail("%s: indexed bit depth is %d, expected 8" % [
			label, int(header.get("bit_depth", -1))
		])
	if int(header.get("interlace", 0)) != 0:
		return _fail("%s: interlaced PNGs are not supported" % label)
	var palette: PackedByteArray = header.get("palette", PackedByteArray())
	if palette.size() < 3:
		return _fail("%s: no PLTE chunk (an indexed PNG needs a palette)" % label)

	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		return _fail("%s: Image.load_png_from_buffer rejected the artifact" % label)
	if image.get_width() != expected_width or image.get_height() != expected_height:
		return _fail("%s: decoded image is %d×%d, expected %d×%d" % [
			label, image.get_width(), image.get_height(), expected_width, expected_height
		])

	# Godot's PNG decoder hands back RGBA8 even for an indexed image, so the
	# PLTE is the authoritative index↔colour table: every pixel colour is
	# matched back to its palette index here (5 entries, one pass, ~150 ms).
	var colour_to_index := {}
	for index in palette.size() / 3:
		var key := (palette[index * 3] << 16) | (palette[index * 3 + 1] << 8) \
			| palette[index * 3 + 2]
		if not colour_to_index.has(key):
			colour_to_index[key] = index
	var data := image.get_data()
	var bpp := 3 if image.get_format() == Image.FORMAT_RGB8 else 4
	var count := expected_width * expected_height
	var out := PackedByteArray()
	out.resize(count)
	var max_index := PALETTE_CHARS.length() - 1
	for pixel in count:
		var offset := pixel * bpp
		var key := (data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2]
		if not colour_to_index.has(key):
			return _fail(
				"%s: pixel (%d,%d) colour #%06x is not in the PLTE palette" % [
					label, pixel % expected_width, pixel / expected_width, key
				]
			)
		var value: int = colour_to_index[key]
		if value > max_index:
			return _fail(
				"%s: palette index %d at tile (%d,%d) is outside the locked 0-4 set (~ . # ^ I, §6.3)" % [
					label, value, pixel % expected_width, pixel / expected_width
				]
			)
		out[pixel] = value

	width = expected_width
	height = expected_height
	tile_size_px = int(legend.get("tile_size_px", 32))
	legend_tiles = tiles
	indices = out
	last_error = ""
	_reset_caches()
	return true


func _fail(reason: String) -> bool:
	last_error = reason
	push_error("MapLoader: " + reason)
	return false


## Builds a loader over an explicit index grid — the seam for a *synthetic*
## map in a unit test (reef/edge fixtures need a tile the shipped world does not
## carry). This is the same internal state [method load_png_buffer] produces, so
## every query below behaves identically; it parses no text and touches no file.
static func from_indices(grid_width: int, grid_height: int,
		values: PackedByteArray, legend: Dictionary, tile_px: int = 32):
	if grid_width <= 0 or grid_height <= 0:
		return null
	if values.size() != grid_width * grid_height:
		push_error("MapLoader.from_indices: %d values for a %d×%d grid" % [
			values.size(), grid_width, grid_height
		])
		return null
	var tile_defs = legend.get("tiles", null)
	if not (tile_defs is Dictionary):
		push_error("MapLoader.from_indices: legend is missing the 'tiles' table")
		return null
	var loader = new()
	loader.width = grid_width
	loader.height = grid_height
	loader.tile_size_px = tile_px
	loader.legend_tiles = _normalize_tiles(tile_defs)
	loader.indices = values
	loader._reset_caches()
	return loader


## Reads IHDR (+ PLTE) out of the raw bytes. A tiny PNG chunk walker: it only
## needs the fixed IHDR layout and the palette payload, so it is not a second
## decoder — `Image.load_png_from_buffer` still does the pixels.
static func _read_png_header(bytes: PackedByteArray) -> Dictionary:
	const SIGNATURE := [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
	if bytes.size() < 33:
		return {}
	for i in SIGNATURE.size():
		if bytes[i] != SIGNATURE[i]:
			return {}
	var out := {}
	var palette := PackedByteArray()
	var pos := 8
	while pos + 12 <= bytes.size():
		var length := _be32(bytes, pos)
		var tag := bytes.slice(pos + 4, pos + 8).get_string_from_ascii()
		if length < 0 or pos + 12 + length > bytes.size():
			return out
		var payload := bytes.slice(pos + 8, pos + 8 + length)
		if tag == "IHDR" and payload.size() >= 13:
			out["width"] = _be32(payload, 0)
			out["height"] = _be32(payload, 4)
			out["bit_depth"] = payload[8]
			out["colour_type"] = payload[9]
			out["interlace"] = payload[12]
		elif tag == "PLTE":
			palette = payload
		elif tag == "IEND":
			break
		pos += 12 + length
	if not out.is_empty():
		out["palette"] = palette
	return out


static func _be32(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 24) | (bytes[offset + 1] << 16) \
		| (bytes[offset + 2] << 8) | bytes[offset + 3]


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


func _reset_caches() -> void:
	_harbor_tiles = {}
	_harbor_ready = false
	_port_at = {}
	_port_at_ready = false
	_shore_tiles = {}
	_shore_ready = false
	_shore_at = {}
	_shore_at_ready = false
	_tile_set = null
	_atlas_source_id = -1
	_chunks_root = null
	_chunks = {}
	_port_overlay = null
	_port_nodes = {}
	_last_center = Vector2i(-1, -1)
	_last_view = Vector2i(-1, -1)
	_overlay_known = []


# --- Grid queries (docs/20-* §4.1, docs/90-* §9 step 3) --------------------

## Palette index at `cell` (x wraps, y bounded), or -1 out of bounds.
func index_at(cell: Vector2i) -> int:
	return index_xy(cell.x, cell.y)


func index_xy(x: int, y: int) -> int:
	if y < 0 or y >= height or width <= 0:
		return -1
	return int(indices[y * width + posmod(x, width)])


## Legend character at `cell` (`"~"`, `"."`, …), or "" out of bounds.
func char_at(cell: Vector2i) -> String:
	var value := index_at(cell)
	if value < 0:
		return ""
	for ch in palette_chars:
		if int(palette_chars[ch]) == value:
			return str(ch)
	return ""


## True when a fleet may enter `cell` (§4.1): x wraps, y must be on the grid,
## and the palette index must be `~` or `.`.
func is_passable(cell: Vector2i) -> bool:
	return is_passable_xy(cell.x, cell.y)


## Int form of [method is_passable] for the hot loops (movement, BFS, candidate
## generation): x is taken mod `width`, y is bounded.
func is_passable_xy(x: int, y: int) -> bool:
	var value := index_xy(x, y)
	return value >= 0 and value <= 1


## Terrain kind at `cell` (a legend `kind` string), or "" out of bounds.
func terrain_kind(cell: Vector2i) -> String:
	var ch := char_at(cell)
	if ch.is_empty():
		return ""
	var def = legend_tiles.get(ch, null)
	if def is Dictionary:
		var kind = (def as Dictionary).get("kind", "")
		if kind is String:
			return kind
	return ""


## `{kind: tile_count}` census over the whole grid (debug/tests only: it walks
## 2.3 M tiles). Counts palette indices directly, so it stays O(n).
func terrain_census() -> Dictionary:
	var by_index := {}
	for value in indices:
		by_index[value] = int(by_index.get(value, 0)) + 1
	var out: Dictionary = {}
	for value in by_index:
		var ch := ""
		for candidate in palette_chars:
			if int(palette_chars[candidate]) == int(value):
				ch = str(candidate)
				break
		var def = legend_tiles.get(ch, null)
		var kind := ch
		if def is Dictionary and (def as Dictionary).get("kind", "") is String:
			kind = str((def as Dictionary)["kind"])
		out[kind] = int(out.get(kind, 0)) + int(by_index[value])
	return out


## Chebyshev distance with longitude wrap (§6.1): `min(|dx|, width − |dx|)`.
func chebyshev(a: Vector2i, b: Vector2i) -> int:
	return chebyshev_xy(a.x, a.y, b.x, b.y)


func chebyshev_xy(ax: int, ay: int, bx: int, by: int) -> int:
	var dx := absi(ax - bx) % maxi(width, 1)
	return maxi(mini(dx, width - dx), absi(ay - by))


## The short-way signed `dx` between two columns (`|result| ≤ width / 2`), used
## to place a berth marker next to the shore tile that a seam copy drew.
func _short_dx(from_x: int, to_x: int) -> int:
	var w := maxi(width, 1)
	var dx := posmod(to_x - from_x, w)
	if dx > w / 2:
		dx -= w
	return dx


# --- Harbor tiles (docs/10-* §6.1, docs/90-* §9.1) ------------------------

## Grid cell containing a WGS84 point: `x = floor((lon+180)*scale) mod width`,
## `y = floor((90-lat)*scale)` clamped into the grid — the same projection as
## `tools/build_world.py` / validator group 6.
func tile_of_latlon(lat: float, lon: float) -> Vector2i:
	var scale := float(width) / 360.0
	var x := int(floor((lon + 180.0) * scale)) % maxi(width, 1)
	var y := clampi(int(floor((90.0 - lat) * scale)), 0, maxi(height - 1, 0))
	return Vector2i(x, y)


## Locked §6.1 snap rule, mirroring the validator exactly: candidates inside
## Chebyshev `radius`, on water with ≥ 1 orthogonally adjacent water tile,
## tie-breaking to the smallest `(distance, y, x)`. `(-1,-1)` when none.
##
## This is the **berth** tile only. The shipped data must also satisfy the
## harbor-pair rule (20-* §4.11.1), so the builder and validator use
## [method snap_harbor_with_shore]; this method stays as the plain §6.1 rule the
## loader and tools/test_world_e2e probe directly.
func snap_harbor(lat: float, lon: float, radius: int = HARBOR_SNAP_TILES) -> Vector2i:
	for candidate in _snap_candidates(tile_of_latlon(lat, lon), radius):
		var y: int = candidate[1]
		var x: int = candidate[2]
		if not is_passable_xy(x, y):
			continue
		if not _has_orthogonal_water(x, y):
			continue
		return Vector2i(x, y)
	return Vector2i(-1, -1)


## The **harbor pair** snap (20-* §4.11.1): the §6.1 berth rule with the added
## requirement that the berth has an orthogonally adjacent `#` to serve as the
## port's shore tile. Candidates keep the locked `(distance, y, x)` order, so a
## port whose plain §6.1 berth already has a shore tile keeps exactly that tile.
## `(-1,-1)` when nothing inside the radius qualifies (the builder fails loudly).
func snap_harbor_with_shore(lat: float, lon: float,
		radius: int = HARBOR_SNAP_TILES) -> Vector2i:
	var origin := tile_of_latlon(lat, lon)
	for candidate in _snap_candidates(origin, radius):
		var y: int = candidate[1]
		var x: int = candidate[2]
		if not is_passable_xy(x, y):
			continue
		if not _has_orthogonal_water(x, y):
			continue
		if shore_of_berth(Vector2i(x, y), origin).x < 0:
			continue
		return Vector2i(x, y)
	return Vector2i(-1, -1)


## The `[distance, y, x]` candidates inside Chebyshev `radius` of `origin`,
## sorted in the locked §6.1 order (distance, then smallest y, then smallest x).
func _snap_candidates(origin: Vector2i, radius: int) -> Array:
	var candidates: Array = []
	for dy in range(-radius, radius + 1):
		var y := origin.y + dy
		if y < 0 or y >= height:
			continue
		for dx in range(-radius, radius + 1):
			var x := posmod(origin.x + dx, maxi(width, 1))
			candidates.append([chebyshev_xy(dx, dy, 0, 0), y, x])
	candidates.sort_custom(_harbor_less)
	return candidates


## The shore tile of `berth` for a port whose derived lat/lon tile is `origin`
## (20-* §4.11.1): the `#` tile orthogonally adjacent to the berth nearest
## `origin` (wrap-aware Chebyshev), tie-break smallest `(y, x)`. `(-1,-1)` when
## the berth has no orthogonally adjacent land — the pair rule's data error.
func shore_of_berth(berth: Vector2i, origin: Vector2i) -> Vector2i:
	if width <= 0 or height <= 0:
		return Vector2i(-1, -1)
	var candidates: Array = []
	for delta in ORTHOGONAL_STEPS:
		var y := berth.y + delta.y
		if y < 0 or y >= height:
			continue
		var x := posmod(berth.x + delta.x, width)
		if index_xy(x, y) != LAND_INDEX:
			continue
		candidates.append([chebyshev_xy(x, y, origin.x, origin.y), y, x])
	candidates.sort_custom(_harbor_less)
	if candidates.is_empty():
		return Vector2i(-1, -1)
	return Vector2i(int(candidates[0][2]), int(candidates[0][1]))


static func _harbor_less(a: Array, b: Array) -> bool:
	if int(a[0]) != int(b[0]):
		return int(a[0]) < int(b[0])
	if int(a[1]) != int(b[1]):
		return int(a[1]) < int(b[1])
	return int(a[2]) < int(b[2])


## ≥ 1 orthogonally adjacent water tile, x wrapping (§6.1).
func _has_orthogonal_water(x: int, y: int) -> bool:
	if is_passable_xy(x - 1, y) or is_passable_xy(x + 1, y):
		return true
	if y > 0 and is_passable_xy(x, y - 1):
		return true
	if y < height - 1 and is_passable_xy(x, y + 1):
		return true
	return false


## `{port_id: Vector2i}` **berth** tiles for every port in `data/ports.json`
## (§9 step 5). Computed once; a port whose lat/lon cannot snap is omitted (the
## validator makes that impossible for shipped data). The berth is derived with
## the harbor-pair rule, so `shore_tiles()` is complete for exactly the same ids.
func harbor_tiles() -> Dictionary:
	if _harbor_ready:
		return _harbor_tiles
	_harbor_ready = true
	_harbor_tiles = {}
	var ports: Dictionary = _ports_table()
	for port_id in ports:
		var port = ports[port_id]
		if not (port is Dictionary):
			continue
		var lat = (port as Dictionary).get("lat", null)
		var lon = (port as Dictionary).get("lon", null)
		if not (lat is float or lat is int) or not (lon is float or lon is int):
			continue
		var cell := snap_harbor_with_shore(float(lat), float(lon))
		if cell.x >= 0:
			_harbor_tiles[str(port_id)] = cell
	return _harbor_tiles


## `{port_id: Vector2i}` **shore** tiles (20-* §4.11.1) — the land tile each
## port is drawn on and docked into. Computed once from the berth tiles; a berth
## with no orthogonally adjacent `#` is omitted (the validator's item 2b).
func shore_tiles() -> Dictionary:
	if _shore_ready:
		return _shore_tiles
	_shore_ready = true
	_shore_tiles = {}
	var ports: Dictionary = _ports_table()
	for port_id in harbor_tiles():
		var port = ports.get(port_id, null)
		if not (port is Dictionary):
			continue
		var lat = (port as Dictionary).get("lat", null)
		var lon = (port as Dictionary).get("lon", null)
		var origin: Vector2i
		if (lat is float or lat is int) and (lon is float or lon is int):
			origin = tile_of_latlon(float(lat), float(lon))
		else:
			origin = harbor_tiles()[port_id]
		var cell := shore_of_berth(harbor_tiles()[port_id], origin)
		if cell.x >= 0:
			_shore_tiles[str(port_id)] = cell
	return _shore_tiles


## Berth tile of `port_id` (the fleet's water tile), or `(-1,-1)` when the id
## has no derivable tile. **Unchanged meaning:** `port_cell` is the berth.
func port_cell(port_id: String) -> Vector2i:
	if port_id.is_empty():
		return Vector2i(-1, -1)
	var tiles := harbor_tiles()
	var value = tiles.get(port_id, null)
	return value if value is Vector2i else Vector2i(-1, -1)


## Shore tile of `port_id` (the `#` the port is drawn on and docked into), or
## `(-1,-1)` when the id has none (20-* §4.11.1).
func shore_cell(port_id: String) -> Vector2i:
	if port_id.is_empty():
		return Vector2i(-1, -1)
	var tiles := shore_tiles()
	var value = tiles.get(port_id, null)
	return value if value is Vector2i else Vector2i(-1, -1)


## Port id whose **berth** tile is `cell` (x wraps), or "" when none.
func port_id_at(cell: Vector2i) -> String:
	return _port_id_at(cell, true)


## Port id whose **shore** tile is `cell` (x wraps), or "" when none — the
## docking lookup of 20-* §4.11.1.
func shore_port_at(cell: Vector2i) -> String:
	return _port_id_at(cell, false)


## Shared inverse lookup over the berth (`shore == false`) or shore table. Both
## are memoised once and keyed by the wrapped cell.
func _port_id_at(cell: Vector2i, berth: bool) -> String:
	if cell.y < 0 or cell.y >= height or width <= 0:
		return ""
	var key := Vector2i(posmod(cell.x, maxi(width, 1)), cell.y)
	if berth:
		if not _port_at_ready:
			_port_at_ready = true
			_port_at = _tile_index(harbor_tiles())
		var port_id = _port_at.get(key, null)
		return port_id if port_id is String else ""
	if not _shore_at_ready:
		_shore_at_ready = true
		_shore_at = _tile_index(shore_tiles())
	var value = _shore_at.get(key, null)
	return value if value is String else ""


## `{Vector2i: port_id}` from a `{port_id: Vector2i}` table, first id winning a
## duplicate cell (the builder and validator report duplicates long before).
func _tile_index(tiles: Dictionary) -> Dictionary:
	var index: Dictionary = {}
	for port_id in tiles:
		var tile = tiles[port_id]
		if tile is Vector2i and not index.has(tile):
			index[tile] = str(port_id)
	return index


## The port table the harbor snap reads. `DataLoader.ports` in production; a
## test may install `ports_override` (data-driven swap, zero code edits).
var ports_override: Dictionary = {}


func _ports_table() -> Dictionary:
	if not ports_override.is_empty():
		return ports_override
	var node = _autoload("DataLoader")
	if node != null:
		var table = node.get("ports")
		if table is Dictionary:
			return table
	return {}


static func _autoload(node_name: String):
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return null
	return (loop as SceneTree).root.get_node_or_null(node_name)


# --- Rendering (docs/90-* §9 steps 4–6) -----------------------------------

## Builds the chunked world under `parent` and returns the "WorldChunks" root.
##
## No 2.3 M cells are created here: [method update_chunks] spawns 128×128 chunk
## layers around the camera on demand. The port overlay is a separate Node2D.
## `ports`/`nations` are the id-keyed tables from DataLoader; passing them keeps
## this RefCounted class free of autoload dependencies.
func build_tilemap(parent: Node2D, ports: Dictionary = {}, nations: Dictionary = {}) -> Node2D:
	_ensure_tile_set()
	_chunks_root = Node2D.new()
	_chunks_root.name = "WorldChunks"
	_chunks_root.z_index = 0
	parent.add_child(_chunks_root)
	_chunks = {}
	_port_overlay = Node2D.new()
	_port_overlay.name = "PortOverlay"
	_port_overlay.z_index = 2
	parent.add_child(_port_overlay)
	refresh_port_overlay(ports, nations)
	return _chunks_root


## One in-memory atlas shared by every chunk: five 32×32 palette squares
## (§6.3 order, colors from `80-*` §4.8 via `scripts/palette.gd`).
func _ensure_tile_set() -> void:
	if _tile_set != null:
		return
	var colors: Array[Color] = [
		PaletteLib.SEA, PaletteLib.COAST_SEA, PaletteLib.LAND,
		PaletteLib.REEF, PaletteLib.ICE,
	]
	var image := Image.create_empty(colors.size() * tile_size_px, tile_size_px,
		false, Image.FORMAT_RGBA8)
	for index in colors.size():
		image.fill_rect(
			Rect2i(index * tile_size_px, 0, tile_size_px, tile_size_px), colors[index]
		)
	var texture := ImageTexture.create_from_image(image)
	_tile_set = TileSet.new()
	_tile_set.tile_size = Vector2i(tile_size_px, tile_size_px)
	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = Vector2i(tile_size_px, tile_size_px)
	for index in colors.size():
		source.create_tile(Vector2i(index, 0))
	_atlas_source_id = _tile_set.add_source(source)


## Spawns the chunks around `center_cell` and frees everything beyond the one
## chunk ring. `center_cell` is in **unbounded** world cells: sampling wraps per
## tile (`x mod width`), so `x = 2160` shows `x = 0` and no seam can show void.
## `view_tiles` is the viewport size in tiles (1280×720 → 40×23 by default).
func update_chunks(center_cell: Vector2i, view_tiles: Vector2i = DEFAULT_VIEW_TILES) -> void:
	if _chunks_root == null or width <= 0 or height <= 0:
		return
	if center_cell == _last_center and view_tiles == _last_view:
		return
	_last_view = view_tiles
	var half_x := int(ceil(float(view_tiles.x) * 0.5))
	var half_y := int(ceil(float(view_tiles.y) * 0.5))
	var cols := _chunk_span(center_cell.x, half_x, CHUNK_MARGIN)
	var rows := _chunk_span(center_cell.y, half_y, CHUNK_MARGIN)
	# The 24-chunk bound is a hard cap: drop the ring margin first, then (for an
	# absurdly large viewport) trim the rows/columns furthest from the centre.
	if cols.size() * rows.size() > MAX_LIVE_CHUNKS:
		cols = _chunk_span(center_cell.x, half_x, 0)
		rows = _chunk_span(center_cell.y, half_y, 0)
	while cols.size() * rows.size() > MAX_LIVE_CHUNKS and rows.size() > 1:
		rows.pop_back()
	while cols.size() * rows.size() > MAX_LIVE_CHUNKS and cols.size() > 1:
		cols.pop_back()
	var wanted := {}
	for chunk_y in rows:
		if chunk_y < 0 or chunk_y * CHUNK_TILES >= height:
			continue
		for chunk_x in cols:
			wanted[Vector2i(chunk_x, chunk_y)] = true
	for key in _chunks.keys():
		if wanted.has(key):
			continue
		var stale: Node = _chunks[key]
		_chunks.erase(key)
		if is_instance_valid(stale):
			stale.queue_free()
	for key in wanted:
		if not _chunks.has(key):
			_chunks[key] = _spawn_chunk(key)
	_last_center = center_cell


## Chunk coordinates covering `center ± half` with `margin` extra chunks each
## side. Chunk x is **unbounded** (negative values wrap when sampled); chunk y is
## kept on the grid later by [method update_chunks].
static func _chunk_span(center: int, half: int, margin: int) -> Array:
	var first := _floor_div(center - half, CHUNK_TILES) - margin
	var last := _floor_div(center + half, CHUNK_TILES) + margin
	var out: Array = []
	for value in range(first, last + 1):
		out.append(value)
	return out


static func _floor_div(value: int, divisor: int) -> int:
	var quotient := value / divisor
	if (value % divisor) != 0 and ((value < 0) != (divisor < 0)):
		quotient -= 1
	return quotient


func _spawn_chunk(key: Vector2i) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.name = "Chunk_%d_%d" % [key.x, key.y]
	layer.tile_set = _tile_set
	layer.position = Vector2(
		key.x * CHUNK_TILES * tile_size_px, key.y * CHUNK_TILES * tile_size_px
	)
	var base_x := key.x * CHUNK_TILES
	var base_y := key.y * CHUNK_TILES
	for j in CHUNK_TILES:
		var y := base_y + j
		if y < 0 or y >= height:
			continue
		for i in CHUNK_TILES:
			var x := base_x + i
			var value := int(indices[y * width + posmod(x, width)])
			layer.set_cell(Vector2i(i, j), _atlas_source_id, Vector2i(value, 0))
	_chunks_root.add_child(layer)
	return layer


## Live chunk count (the §9 debug assert: ≤ 24).
func live_chunk_count() -> int:
	return _chunks.size()


## Rough memory of the live chunk cell data (< 50 MB per §9).
func live_chunk_bytes_estimate() -> int:
	return _chunks.size() * CHUNK_TILES * CHUNK_TILES * MEMORY_PER_CELL_BYTES


## True when the live chunks cover every tile under `rect` (world pixels). The
## camera-pan test uses it to prove "zero void frames" across the dateline:
## `rect` may extend past `width * tile_size_px`, which is legitimate because
## the chunk layer repeats the wrapped grid.
func covers_rect_world(rect: Rect2) -> bool:
	if _chunks.is_empty() or _chunks_root == null:
		return false
	var first := Vector2i(
		int(floor(rect.position.x / float(tile_size_px))),
		int(floor(rect.position.y / float(tile_size_px)))
	)
	var last := Vector2i(
		int(ceil(rect.end.x / float(tile_size_px))) - 1,
		int(ceil(rect.end.y / float(tile_size_px))) - 1
	)
	for y in range(first.y, last.y + 1):
		if y < 0 or y >= height:
			return false
		for x in range(first.x, last.x + 1):
			# Only the chunk key matters: the sampled tile always wraps.
			var key := Vector2i(_floor_div(x, CHUNK_TILES), _floor_div(y, CHUNK_TILES))
			if not _chunks.has(key):
				return false
	if _port_overlay == null:
		return false
	return true


# --- Port overlay (§9 step 5) ---------------------------------------------

## Redraws the port overlay (20-* §4.11.1, §9 step 5): the nation-coloured
## square plus the name's initial on the port's **shore** tile — the tile the
## player reads as "the port" — and a small berth marker on the adjacent sea
## tile so the pair reads at a glance. Both are wrap-duplicated at the seam.
## Idempotent; call after `known_ports` changes.
func refresh_port_overlay(ports: Dictionary = {}, nations: Dictionary = {}) -> void:
	if _port_overlay == null:
		return
	# The overlay only changes when the known-port set does (a scene calls this
	# after every sighting pass); rebuilding ~100 Control nodes per step would
	# be wasted work.
	var current: Array = _known_ports().duplicate()
	current.sort()
	var previous: Array = _overlay_known.duplicate()
	previous.sort()
	if current == previous and not _port_nodes.is_empty():
		return
	for child in _port_overlay.get_children():
		_port_overlay.remove_child(child)
		child.queue_free()
	_port_nodes = {}
	var table: Dictionary = ports if not ports.is_empty() else _ports_table()
	var nation_table: Dictionary = nations
	if nation_table.is_empty():
		var node = _autoload("DataLoader")
		if node != null and node.get("nations") is Dictionary:
			nation_table = node.get("nations")
	var known: Array = _known_ports()
	_overlay_known = known.duplicate()
	for raw_id in table.keys():
		var port_id := str(raw_id)
		if not (port_id in known):
			continue
		var port = table[raw_id]
		if not (port is Dictionary):
			continue
		var shore := shore_cell(port_id)
		var berth := port_cell(port_id)
		if shore.x < 0:
			continue
		var colour := _nation_colour(str((port as Dictionary).get("nation_id", "")),
			nation_table)
		# Both tiles of the pair get the same seam offsets: a port at x = 0 also
		# shows at x = 2160, and its berth moves with it.
		for offset in _seam_offsets_pair(shore.x, berth.x):
			var draw_shore := Vector2i(shore.x + offset, shore.y)
			# The berth is drawn relative to the copied shore tile, so a pair
			# straddling x = 0 keeps its adjacency on both copies.
			var draw_berth := draw_shore \
				+ Vector2i(_short_dx(shore.x, berth.x), berth.y - shore.y)
			var key := "%s@%d" % [port_id, offset]
			_port_nodes[key] = _build_port_node(
				key, draw_shore, draw_berth, port, colour
			)


## Overlay entries `[{port_id, cell, shore_cell, berth_cell, offset, colour,
## node}]`, sorted by `port_id` then `offset` — the test hook for "all 100
## render on their shore tile with the right nation colour, wrap-duplicated at
## the seam". `cell` is the drawn square's cell, i.e. the **shore** tile.
func port_overlay_entries() -> Array:
	var out: Array = []
	var keys: Array = _port_nodes.keys()
	keys.sort()
	for key in keys:
		var node = _port_nodes[key]
		out.append({
			"port_id": str(key).get_slice("@", 0),
			"cell": node.get_meta("cell", Vector2i.ZERO),
			"shore_cell": node.get_meta("shore_cell", Vector2i.ZERO),
			"berth_cell": node.get_meta("berth_cell", Vector2i.ZERO),
			"offset": int(node.get_meta("offset", 0)),
			"colour": node.get_meta("colour", Color.BLACK),
			"node": node,
		})
	return out


func _known_ports() -> Array:
	var node = _autoload("GameState")
	if node != null:
		var value = node.get("known_ports")
		if value is Array:
			return value
	return []


## Seam offsets covering **both** tiles of the pair: the union of each tile's
## own offset set, so a port hugs the seam when either its shore tile or its
## berth is within [constant SEAM_MARGIN] of an edge.
func _seam_offsets_pair(shore_x: int, berth_x: int) -> Array:
	var out: Array = [0]
	if _seam_offsets(shore_x).has(width) or _seam_offsets(berth_x).has(width):
		out.append(width)
	if _seam_offsets(shore_x).has(-width) or _seam_offsets(berth_x).has(-width):
		out.append(-width)
	return out


## Seam offsets for a single tile: always `0`, plus the wrap copy when the tile
## is within [constant SEAM_MARGIN] of an edge (§9 step 5).
func _seam_offsets(x: int) -> Array:
	var out: Array = [0]
	if x < SEAM_MARGIN:
		out.append(width)
	if x >= width - SEAM_MARGIN:
		out.append(-width)
	return out


func _nation_colour(nation_id: String, nations: Dictionary) -> Color:
	var nation = nations.get(nation_id, null)
	if nation is Dictionary:
		var hex = (nation as Dictionary).get("color", "")
		if hex is String and Color.html_is_valid(hex):
			return PaletteLib.nation_color(hex)
	return PaletteLib.ACCENT


## The port's map node, anchored on its **shore** tile: a 0.6-tile nation square
## plus the English name's initial, and a small berth marker on the adjacent sea
## tile so the pair reads at a glance (placeholder art, `80-*` §4.8: plain shapes
## + the default font, no textures). The holder sits at the shore tile's origin;
## the berth marker is positioned relative to it, so a seam offset carries both.
func _build_port_node(key: String, shore: Vector2i, berth: Vector2i,
		port: Dictionary, colour: Color) -> Control:
	var origin := Vector2(shore) * float(tile_size_px)
	var holder := Control.new()
	holder.name = "Port_%s" % key.replace("@", "_")
	holder.position = origin
	holder.size = Vector2(tile_size_px, tile_size_px)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.set_meta("cell", shore)
	holder.set_meta("shore_cell", shore)
	holder.set_meta("berth_cell", berth)
	holder.set_meta("colour", colour)
	var offset := int(str(key).get_slice("@", 1))
	holder.set_meta("offset", offset)
	var square := ColorRect.new()
	square.name = "Square"
	var side := int(round(tile_size_px * 0.6))
	square.size = Vector2(side, side)
	square.position = (Vector2(tile_size_px, tile_size_px) - square.size) * 0.5
	square.color = colour
	square.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(square)
	# The berth marker: a small filled dot on the sea tile next to the square
	# (the fleet's own tile), deliberately smaller than the port square. The
	# offset is the **short way** round the seam, so a pair straddling x = 0
	# draws the berth on the correct side of the shore tile.
	var marker := ColorRect.new()
	marker.name = "BerthMarker"
	var marker_side := maxi(int(round(tile_size_px * 0.25)), 3)
	marker.size = Vector2(marker_side, marker_side)
	marker.position = Vector2(_short_dx(shore.x, berth.x), berth.y - shore.y) \
		* float(tile_size_px) \
		+ (Vector2(tile_size_px, tile_size_px) - marker.size) * 0.5
	marker.color = colour
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(marker)
	var label := Label.new()
	label.name = "Initial"
	label.text = _initial(port)
	label.position = Vector2.ZERO
	label.size = Vector2(tile_size_px, tile_size_px)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", PaletteLib.TEXT)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(label)
	_port_overlay.add_child(holder)
	return holder


static func _initial(port: Dictionary) -> String:
	var name = port.get("name", null)
	if name is Dictionary:
		var english = (name as Dictionary).get("en", "")
		if english is String and not (english as String).is_empty():
			return (english as String).substr(0, 1)
	return "?"
