extends Node
## Phase-4 task G acceptance tests: the PNG → chunked-TileMap world
## (docs/IMPLEMENT-Phase4.md G; docs/90-* §9/§9.1; docs/10-* §6.1–§6.3;
## docs/20-* §4.1, §4.11–§4.12; docs/80-* §4.5, §4.8).
##
##   godot --headless --path . tools/test_world_map.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")
const PaletteLib := preload("res://scripts/palette.gd")

## docs/10-* §6.1: the locked grid and artifact.
const WORLD_WIDTH := 2160
const WORLD_HEIGHT := 1080
const TILE_SIZE_PX := 32
## docs/10-* §6.3: palette index 0–4 = `~ . # ^ I` (append-only).
const PALETTE_CHARS := "~.#^I"
const PORT_COUNT := 100
## docs/90-* §9 step 4: 128×128-tile chunks, at most 24 live.
const CHUNK_TILES := 128
const MAX_LIVE_CHUNKS := 24
const MAX_CHUNK_BYTES := 50 * 1024 * 1024
## The §9 debug assert measured on this machine: boot (scene load → first frame)
## must stay under this, headless.
const BOOT_BUDGET_MS := 3000

var _failures: Array[String] = []
var _checks := 0
## The `world_report.json` harbor tiles `{id: Vector2i}` (the builder's output).
var _report_tiles: Dictionary = {}


func _ready() -> void:
	_report_tiles = _load_report_tiles()
	_test_map_index()
	_test_legend()
	_test_png_loads()
	_test_harbor_tiles()
	_test_passability_seam()
	_test_data_driven_swap()
	_test_new_game_starts()
	await _test_world_scene_renders()
	await _test_chunked_rendering()
	await _test_port_overlays()
	await _test_explore_action()
	_report()


# --- 0. The builder's harbor tiles (the reference values) -----------------

func _load_report_tiles() -> Dictionary:
	var path := "res://data/maps/world_report.json"
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	var out: Dictionary = {}
	if not (data is Dictionary):
		return out
	for entry in (data.get("ports", []) as Array):
		if not (entry is Dictionary):
			continue
		var tile = (entry as Dictionary).get("harbor_tile", null)
		if not (tile is Dictionary):
			continue
		out[str((entry as Dictionary).get("id", ""))] = Vector2i(
			int((tile as Dictionary).get("x", -1)),
			int((tile as Dictionary).get("y", -1))
		)
	return out


# --- 1. The map index is data, with exactly one map -----------------------

func _test_map_index() -> void:
	var ids: Array = DataLoader.map_ids()
	_check(ids == ["world"],
		"maps.json indexes exactly one map, 'world' (got %s)" % str(ids))
	var entry: Dictionary = DataLoader.get_map("world")
	_check(not entry.is_empty(), "get_map('world') returns an entry")
	_check(str(entry.get("file", "")) == "data/maps/world.png",
		"the world map's artifact is data/maps/world.png (got %s)"
		% str(entry.get("file", "")))
	var files: Dictionary = DataLoader.get_map_files("world")
	_check(not files.is_empty(), "get_map_files('world') resolves")
	var path := "res://" + str(files.get("file", ""))
	_check(FileAccess.file_exists(path), "the artifact exists (%s)" % path)
	# No fallback ladder: an unknown id is a logged data error returning {}.
	var missing: Dictionary = DataLoader.get_map("nope")
	_check(missing.is_empty(),
		"an unknown map id is not resolved by a fallback ladder (got %s)"
		% str(missing))
	# No compatibility ladder: the two retired legacy ids are simply not in the
	# index (docs/90-* §8.2 "development-stage scope"), so nothing maps them.
	_check(not DataLoader.map_ids().has("p1")
		and not DataLoader.map_ids().has("p3"),
		"the retired legacy map ids are gone from the index, with no alias")


# --- 2. The legend -------------------------------------------------------

func _test_legend() -> void:
	var legend: Dictionary = DataLoader.map_legend
	_check(not legend.is_empty(), "the single map legend loads")
	var grid: Dictionary = legend.get("grid", {})
	_check(int(grid.get("width", 0)) == WORLD_WIDTH
		and int(grid.get("height", 0)) == WORLD_HEIGHT,
		"the grid is %d×%d (got %s×%s)"
		% [WORLD_WIDTH, WORLD_HEIGHT, grid.get("width"), grid.get("height")])
	_check(int(legend.get("tile_size_px", 0)) == TILE_SIZE_PX,
		"the legend's tile_size_px is %d" % TILE_SIZE_PX)
	var tiles: Dictionary = legend.get("tiles", {})
	_check(tiles.keys().size() == 5,
		"the legend has exactly five tiles (got %s)" % str(tiles.keys()))
	for index in PALETTE_CHARS.length():
		var ch: String = PALETTE_CHARS[index]
		_check(tiles.has(ch), "the legend carries tile '%s' (palette index %d)"
			% [ch, index])
	_check(not legend.has("port_markers"),
		"the legend has no port_markers table (ports are an overlay, decision 7)")
	_check(DataLoader.get_map_legend("world") == legend,
		"get_map_legend('world') is the loaded legend")
	_check(DataLoader.get_map_legend("nope").is_empty(),
		"there is no per-map legend cache any more")


# --- 3. The PNG loads, and the artifact contract is enforced -------------

func _test_png_loads() -> void:
	var loader = MapLoaderLib.new()
	var ok: bool = loader.load_map("res://data/maps/world.png", DataLoader.map_legend)
	_check(ok, "the world PNG loads (%s)" % loader.last_error)
	if not ok:
		return
	_check(loader.width == WORLD_WIDTH and loader.height == WORLD_HEIGHT,
		"the loaded grid is %d×%d (got %d×%d)"
		% [WORLD_WIDTH, WORLD_HEIGHT, loader.width, loader.height])
	_check(loader.tile_size_px == TILE_SIZE_PX,
		"the loader renders at %d px per tile" % TILE_SIZE_PX)
	_check(loader.indices.size() == WORLD_WIDTH * WORLD_HEIGHT,
		"one palette index per tile (%d bytes, got %d)"
		% [WORLD_WIDTH * WORLD_HEIGHT, loader.indices.size()])
	# Every index is inside the locked set. Indices 0, 1, 2 and 4 must appear;
	# `^` (3, reef) is explicitly optional in Phase 4 (build_world.py's done-when:
	# "no `^` required this phase (reef layer explicitly out of scope; `^` count
	# may be 0)"), so it is only required to be *legal* where present.
	var seen := {}
	for value in loader.indices:
		seen[int(value)] = true
	for index in [0, 1, 2, 4]:
		_check(seen.has(index), "palette index %d ('%s') appears in the artifact"
			% [index, PALETTE_CHARS[index]])
	var reef_tiles := int(loader.terrain_census().get("reef", 0))
	print("       measured: palette presence %s (reef '^' is optional, %d tiles)"
		% [str(seen.keys()), reef_tiles])
	_check(seen.has(3) == (reef_tiles > 0),
		"the reef index and the reef census agree (%d tiles)" % reef_tiles)
	var out_of_set := 0
	for value in loader.indices:
		if int(value) >= PALETTE_CHARS.length():
			out_of_set += 1
	_check(out_of_set == 0,
		"no tile carries a palette index outside 0–4 (%d)" % out_of_set)
	# Terrain kinds agree with the legend.
	var census: Dictionary = loader.terrain_census()
	_check(census.has("sea") and census.has("coastal_sea")
		and census.has("land") and census.has("polar_ice"),
		"the census names every terrain kind (%s)" % str(census.keys()))
	var total := 0
	for kind in census:
		total += int(census[kind])
	_check(total == WORLD_WIDTH * WORLD_HEIGHT,
		"the census covers every tile (%d)" % total)
	_check(loader.terrain_kind(Vector2i(1024, 308)) == "coastal_sea",
		"Lisbon's harbor tile reads coastal sea (got '%s')"
		% loader.terrain_kind(Vector2i(1024, 308)))

	# A missing file and a non-PNG fail cleanly and name a reason.
	var bad = MapLoaderLib.new()
	_check(not bad.load_map("res://data/maps/nope.png", DataLoader.map_legend),
		"a missing map file fails")
	_check(bad.last_error.contains("not found"),
		"the failure names the reason (%s)" % bad.last_error)
	var not_png = MapLoaderLib.new()
	_check(not not_png.load_png_buffer(PackedByteArray([1, 2, 3]),
			"test", DataLoader.map_legend),
		"a non-PNG buffer fails")
	_check(not_png.last_error.contains("not a PNG")
		or not_png.last_error.contains("IHDR"),
		"the failure names the artifact problem (%s)" % not_png.last_error)


# --- 4. Harbor tiles match the builder's report -------------------------

func _test_harbor_tiles() -> void:
	_check(_report_tiles.size() == PORT_COUNT,
		"world_report.json lists %d harbor tiles (got %d)"
		% [PORT_COUNT, _report_tiles.size()])
	var loader = MapLoaderLib.new()
	var ok: bool = loader.load_map("res://data/maps/world.png", DataLoader.map_legend)
	_check(ok, "the map loads for the harbor fixture")
	if not ok:
		return
	var tiles: Dictionary = loader.harbor_tiles()
	_check(tiles.size() == PORT_COUNT,
		"all %d ports snap to a harbor tile (got %d)" % [PORT_COUNT, tiles.size()])
	var mismatches: Array = []
	var not_water: Array = []
	var wrong_adjacency: Array = []
	for port_id in _report_tiles:
		var want: Vector2i = _report_tiles[port_id]
		var got: Vector2i = loader.port_cell(str(port_id))
		if got != want:
			mismatches.append("%s %s != %s" % [port_id, str(got), str(want)])
		if got.x >= 0 and not loader.is_passable(got):
			not_water.append(str(port_id))
		if got.x >= 0 and not _has_orthogonal_water(loader, got):
			wrong_adjacency.append(str(port_id))
	_check(mismatches.is_empty(),
		"all %d harbor tiles equal world_report.json's (mismatches: %s)"
		% [PORT_COUNT, str(mismatches.slice(0, 6))])
	_check(not_water.is_empty(),
		"every harbor tile is water (%s)" % str(not_water))
	_check(wrong_adjacency.is_empty(),
		"every harbor tile has ≥ 1 orthogonal water neighbour (%s)"
		% str(wrong_adjacency))
	# `port_cell` is memoised: a second call is the same answer.
	_check(loader.port_cell("lisbon") == _report_tiles["lisbon"],
		"port_cell('lisbon') is Lisbon's harbor tile %s"
		% str(_report_tiles.get("lisbon")))
	_check(loader.port_cell("nope") == Vector2i(-1, -1),
		"an unknown port has no harbor tile")
	# The reverse map covers every port, and wraps on x.
	var covered := 0
	for port_id in tiles:
		if loader.port_id_at(tiles[port_id]) == str(port_id):
			covered += 1
	_check(covered == PORT_COUNT,
		"port_id_at() reverses every harbor tile (%d of %d)" % [covered, PORT_COUNT])
	var lisbon: Vector2i = _report_tiles["lisbon"]
	_check(loader.port_id_at(Vector2i(lisbon.x + WORLD_WIDTH, lisbon.y)) == "lisbon",
		"port_id_at wraps on x (x + 2160 is the same tile)")
	# The data is the truth: every port has lat/lon and no stored tile.
	var missing_latlon: Array = []
	var stored_tile: Array = []
	for entry in DataLoader.ports_list:
		var port: Dictionary = entry
		if not (port.get("lat") is float or port.get("lat") is int) \
				or not (port.get("lon") is float or port.get("lon") is int):
			missing_latlon.append(str(port.get("id", "")))
		for key in ["position", "marker", "p3"]:
			if port.has(key):
				stored_tile.append("%s.%s" % [port.get("id", ""), key])
	_check(missing_latlon.is_empty(),
		"every port carries lat/lon (%s)" % str(missing_latlon))
	_check(stored_tile.is_empty(),
		"no port carries a stored tile/marker block (%s)" % str(stored_tile))


## How many tiles of palette `index` the artifact holds.
func _kind_count(loader, index: int) -> int:
	var count := 0
	for value in loader.indices:
		if int(value) == index:
			count += 1
	return count


## The first tile carrying palette `index` (a `(-1,-1)` sentinel when absent).
func _first_tile(loader, index: int) -> Vector2i:
	for value_index in loader.indices.size():
		if int(loader.indices[value_index]) == index:
			return Vector2i(
				value_index % loader.width, value_index / loader.width
			)
	return Vector2i(-1, -1)


## ≥ 1 orthogonally adjacent water tile (x wraps), matching the snap rule.
func _has_orthogonal_water(loader, cell: Vector2i) -> bool:
	for delta in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if loader.is_passable(cell + delta):
			return true
	return false


# --- 5. Passability at the seam, for all five kinds ----------------------

func _test_passability_seam() -> void:
	var loader = MapLoaderLib.new()
	var ok: bool = loader.load_map("res://data/maps/world.png", DataLoader.map_legend)
	_check(ok, "the map loads for the seam fixture")
	if not ok:
		return
	# Find a row where each kind occurs at both x = 0 and x = 2159, so the seam
	# assertion is about the *tiles*, not one lucky row.
	var rows := {}
	for y in loader.height:
		var left := loader.index_xy(0, y)
		var right := loader.index_xy(WORLD_WIDTH - 1, y)
		for value in [left, right]:
			if value >= 0 and not rows.has(value):
				rows[value] = y
		if rows.size() == 5:
			break
	# Every kind **present in the artifact** gets a seam-table row. `^` (reef) is
	# legitimately absent in Phase 4 (C's done-when: "no `^` required this
	# phase"); its wrap behaviour is covered by the in-memory 64×32 test map in
	# [_test_data_driven_swap], which carries all five kinds.
	var present: Array = []
	for index in PALETTE_CHARS.length():
		if _kind_count(loader, index) > 0:
			present.append(index)
	_check(present.size() >= 4,
		"the artifact carries at least four tile kinds (%s)" % str(present))
	for index in present:
		var ch: String = PALETTE_CHARS[index]
		var sample := Vector2i(-1, -1)
		if rows.has(index):
			sample = Vector2i(0, int(rows[index]))
		else:
			for y in range(0, loader.height, 7):
				for x in [0, 1, WORLD_WIDTH - 1, 540, 1080, 1620]:
					if loader.index_xy(x, y) == index:
						sample = Vector2i(x, y)
						break
				if sample.x >= 0:
					break
		_check(sample.x >= 0, "a '%s' tile exists for the seam table" % ch)
		if sample.x < 0:
			continue
		var passable: bool = index <= 1
		_check(loader.index_xy(sample.x, sample.y) == index,
			"'%s' reads its own index (%d)" % [ch, index])
		_check(loader.is_passable_xy(sample.x, sample.y) == passable,
			"'%s' passability at %s is %s (§6.2)"
			% [ch, str(sample), str(passable)])
		# The same tile addressed from the other side of the seam.
		var wrapped_x := sample.x - WORLD_WIDTH if sample.x >= 0 else sample.x + WORLD_WIDTH
		_check(loader.index_xy(wrapped_x, sample.y) == index,
			"'%s' at x %d wraps to the same index (x %d)"
			% [ch, sample.x, wrapped_x])
		_check(loader.is_passable_xy(wrapped_x, sample.y) == passable,
			"'%s' keeps its passability across the seam (%s)"
			% [ch, str(passable)])
		_check(loader.char_at(Vector2i(wrapped_x, sample.y)) == ch,
			"'%s' keeps its tile character across the seam" % ch)
	# (0, y) and (2159, y) are legal grid columns, not out of bounds.
	var wet_y := int(rows.get(0, 0))
	_check(loader.is_passable_xy(0, wet_y) and loader.is_passable_xy(WORLD_WIDTH, wet_y)
		and loader.is_passable_xy(-1, wet_y) and loader.is_passable_xy(WORLD_WIDTH - 1, wet_y),
		"x = 0, 2159, -1 and 2160 all address sea on row %d" % wet_y)
	# y is bounded: the latitude edges are closed.
	_check(not loader.is_passable_xy(100, -1)
		and not loader.is_passable_xy(100, WORLD_HEIGHT),
		"y = -1 and y = 1080 are impassable (latitude edges, §4.1)")
	var polar := 0
	var bad_polar := 0
	for x in range(0, WORLD_WIDTH, 37):
		if loader.index_xy(x, 0) != 4:
			bad_polar += 1
		polar += 1
	_check(bad_polar == 0,
		"row 0 is polar ice across the whole width (70°N, §6.2; %d/%d)"
		% [polar - bad_polar, polar])
	# Spot checks with the doc's own numbers.
	var lisbon_projection: Vector2i = loader.tile_of_latlon(38.72, -9.14)
	_check(lisbon_projection == Vector2i(1025, 307),
		"Lisbon's lat/lon projects into tile (1025,307) "
		+ "(x = floor((lon+180)*6) = floor(1025.16), §6.1; got %s)"
		% str(lisbon_projection))
	var lisbon_harbor: Vector2i = loader.port_cell("lisbon")
	_check(maxi(absi(lisbon_harbor.x - lisbon_projection.x),
			absi(lisbon_harbor.y - lisbon_projection.y)) <= 2,
		"Lisbon's harbor %s is within the 2-tile snap radius of its projection %s"
		% [str(lisbon_harbor), str(lisbon_projection)])
	_check(loader.tile_of_latlon(0.0, 180.0).x == 0,
		"lon 180 projects to x = 0 (wrapped)")
	_check(loader.chebyshev(Vector2i(2158, 500), Vector2i(2, 500)) == 4,
		"Chebyshev across the seam is 4 for x=2158 vs x=2 (got %d)"
		% loader.chebyshev(Vector2i(2158, 500), Vector2i(2, 500)))


# --- 6. Swapping the artifact is data-only --------------------------------

## docs/90-* §9: the loader takes the bytes/legend as arguments, so a different
## indexed PNG needs **zero** code edits. A 64×32 test PNG is built in memory
## (an `Image`-built buffer, no file) and loaded through the same entry point.
func _test_data_driven_swap() -> void:
	var test_width := 64
	var test_height := 32
	var chars := ["~", ".", "#", "^", "I"]
	var legend := {
		"grid": {"width": test_width, "height": test_height},
		"tile_size_px": TILE_SIZE_PX,
		"tiles": {
			"~": {"kind": "sea", "passable": true},
			".": {"kind": "coastal_sea", "passable": true},
			"#": {"kind": "land", "passable": false},
			"^": {"kind": "reef", "passable": false},
			"I": {"kind": "polar_ice", "passable": false},
		},
	}
	var bytes := _build_indexed_png(test_width, test_height, chars)
	_check(not bytes.is_empty(), "the test PNG builds in memory (%d bytes)" % bytes.size())
	if bytes.is_empty():
		return
	var loader = MapLoaderLib.new()
	var ok: bool = loader.load_png_buffer(bytes, "test://memory.png", legend)
	_check(ok, "the loader accepts an in-memory PNG with a 64×32 legend (%s)"
		% loader.last_error)
	if not ok:
		return
	_check(loader.width == test_width and loader.height == test_height,
		"the swapped grid is 64×32 (got %dx%d)" % [loader.width, loader.height])
	# Row y holds a repeating 5-kind band; column 0 is `~`, so the seam check is
	# on the test map's own width (64), not the shipped 2160.
	_check(loader.char_at(Vector2i(0, 0)) == "~",
		"the swapped map reads the buffer's first tile (got '%s')"
		% loader.char_at(Vector2i(0, 0)))
	_check(loader.char_at(Vector2i(64, 0)) == loader.char_at(Vector2i(0, 0)),
		"the swapped map wraps at its own width (64, not a hard-coded 2160)")
	# **All five kinds** at the seam. The shipped artifact carries no `^` this
	# phase (build_world.py's done-when), so the reef row is proven on this
	# in-memory map, which holds all five in a repeating band: row y's tile x is
	# palette slot `(x + y) % 5`.
	var seam_table: Array = []
	for index in PALETTE_CHARS.length():
		var ch: String = PALETTE_CHARS[index]
		# Row `index` places `ch` at x = 0 (`(0 + index) % 5 == index`).
		var cell_y := index
		var passable: bool = index <= 1
		_check(loader.char_at(Vector2i(0, cell_y)) == ch,
			"in-memory seam: '%s' is at x = 0 on row %d" % [ch, cell_y])
		_check(loader.is_passable(Vector2i(0, cell_y)) == passable,
			"in-memory seam: '%s' at (0,%d) is %s" % [ch, cell_y, str(passable)])
		_check(loader.is_passable(Vector2i(test_width, cell_y)) == passable,
			"in-memory seam: '%s' at (width,%d) is %s"
			% [ch, cell_y, str(passable)])
		_check(loader.is_passable(Vector2i(-test_width, cell_y)) == passable,
			"in-memory seam: '%s' at (-width,%d) is %s"
			% [ch, cell_y, str(passable)])
		_check(loader.char_at(Vector2i(test_width - 1, cell_y))
			== loader.char_at(Vector2i(-1, cell_y)),
			"in-memory seam: x = -1 and x = width-1 are the same '%s' tile" % ch)
		seam_table.append("%s=%s" % [ch, str(passable)])
	print("       measured: seam passability for all 5 kinds -> %s"
		% ", ".join(seam_table))
	# Harbor derivation is data-driven too: a port on the test grid snaps inside
	# 64×32, and no shipped-port assumption leaks in.
	loader.ports_override = {"test_port": {"id": "test_port", "lat": 0.0, "lon": 0.0}}
	var cell: Vector2i = loader.port_cell("test_port")
	_check(cell.x >= 0 and cell.x < test_width and cell.y >= 0 and cell.y < test_height,
		"a port snaps inside the swapped grid's bounds (%s)" % str(cell))
	# A wrong grid size is rejected by the legend, not silently accepted.
	var wrong_legend: Dictionary = legend.duplicate(true)
	(wrong_legend["grid"] as Dictionary)["width"] = 128
	var bad = MapLoaderLib.new()
	_check(not bad.load_png_buffer(bytes, "test://memory.png", wrong_legend),
		"a PNG whose size disagrees with the legend is rejected")
	_check(bad.last_error.contains("128"),
		"the rejection names the expected size (%s)" % bad.last_error)
	# A palette index outside 0–4 is rejected with the index and the tile.
	var too_many := _build_indexed_png(test_width, test_height, chars, 6, 6)
	_check(not too_many.is_empty(),
		"a 6-index test PNG builds (%d bytes)" % too_many.size())
	if not too_many.is_empty():
		var high = MapLoaderLib.new()
		var high_ok: bool = high.load_png_buffer(too_many, "test://high.png", legend)
		_check(not high_ok, "palette index 5 is rejected (§6.3 append-only set)")
		_check(high.last_error.contains("index 5")
			and high.last_error.contains("tile ("),
			"the rejection names the index and a sample tile (%s)" % high.last_error)


## An 8-bit indexed PNG built in memory (colour type 3, filter 0 rows). The
## pixel of tile `(x, y)` is palette slot `(x + y) % slot_count`; `slot_count`
## (default = the charset length) sizes both the PLTE and the pixel range, so
## `slot_count = 6` exercises the "index outside 0–4" rejection.
func _build_indexed_png(width: int, height: int, chars: Array,
		slot_count: int = 0, palette_slots: int = 0) -> PackedByteArray:
	if slot_count <= 0:
		slot_count = chars.size()
	if palette_slots <= 0:
		palette_slots = maxi(slot_count, chars.size())
	var palette := PackedByteArray()
	# Distinct, non-grey colours so the RGBA→index match is unambiguous.
	for index in palette_slots:
		palette.append(17 + index * 31)
		palette.append(29 + index * 17)
		palette.append(43 + index * 11)
	var raw := PackedByteArray()
	for y in height:
		raw.append(0)
		for x in width:
			raw.append((x + y) % slot_count)
	var png := PackedByteArray()
	png.append_array(PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
	var ihdr := PackedByteArray()
	ihdr.append_array(_be32(width))
	ihdr.append_array(_be32(height))
	ihdr.append(8)   # bit depth
	ihdr.append(3)   # indexed colour
	ihdr.append(0)   # compression
	ihdr.append(0)   # filter
	ihdr.append(0)   # interlace
	_append_chunk(png, "IHDR", ihdr)
	_append_chunk(png, "PLTE", palette)
	_append_chunk(png, "IDAT", raw.compress(FileAccess.COMPRESSION_DEFLATE))
	_append_chunk(png, "IEND", PackedByteArray())
	return png


static func _be32(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.append((value >> 24) & 0xFF)
	out.append((value >> 16) & 0xFF)
	out.append((value >> 8) & 0xFF)
	out.append(value & 0xFF)
	return out


static func _append_chunk(png: PackedByteArray, tag: String, payload: PackedByteArray) -> void:
	png.append_array(_be32(payload.size()))
	var body := tag.to_ascii_buffer()
	body.append_array(payload)
	png.append_array(body)
	png.append_array(_be32(_crc32(body)))


## CRC-32 (the PNG polynomial), needed only for the in-memory test artifact.
static func _crc32(data: PackedByteArray) -> int:
	var crc := 0xFFFFFFFF
	for byte in data:
		crc ^= int(byte)
		for _bit in 8:
			if crc & 1:
				crc = (crc >> 1) ^ 0xEDB88320
			else:
				crc >>= 1
	return crc ^ 0xFFFFFFFF


# --- 7. A new game starts on the derived harbor tile ---------------------

func _test_new_game_starts() -> void:
	# `new_game()` defaults to the one world map, and the fleet stands on the
	# port's derived harbor tile — not a stored copy (there is none).
	for nation_id in ["portugal", "spain", "england", "holland", "ottoman", "italy"]:
		GameState.new_game(str(nation_id), false)
		_check(str(GameState.world.get("map_id", "")) == "world",
			"%s: new_game() stores map_id 'world' (got %s)"
			% [nation_id, str(GameState.world.get("map_id"))])
		var nation: Dictionary = DataLoader.get_nation(str(nation_id))
		var port_id := str(nation.get("start_port_id", ""))
		_check(GameState.world_tile() == _report_tiles.get(port_id, Vector2i(-1, -1)),
			"%s: the fleet starts on %s's harbor tile %s (got %s)"
			% [nation_id, port_id, str(_report_tiles.get(port_id)),
				str(GameState.world_tile())])
		_check(DataLoader.is_passable(GameState.world_tile()),
			"%s: the start tile is water" % nation_id)
	# An unknown map id never wedges a new game (it falls back to the one
	# documented default with a warning), and no retired id is special-cased.
	GameState.new_game("portugal", false, "p9")
	_check(str(GameState.world.get("map_id")) == "world",
		"an unknown map id falls back to 'world' (got %s)"
		% str(GameState.world.get("map_id")))
	_check(GameState.world_tile() == _report_tiles.get("lisbon", Vector2i(-1, -1)),
		"…and the run still starts on Lisbon's world harbor tile")
	# The map id survives a save/load round trip (SaveSystem validates it).
	var snapshot: Dictionary = SaveSystem.snapshot()
	_check(str((snapshot["world"] as Dictionary).get("map_id", "")) == "world",
		"snapshot() writes world.map_id 'world'")


# --- 8. The world scene boots and moves ----------------------------------

func _test_world_scene_renders() -> void:
	GameState.new_game("portugal", false)
	var started := Time.get_ticks_msec()
	var world: Node2D = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	await get_tree().process_frame
	var boot_ms := Time.get_ticks_msec() - started
	_check(boot_ms < BOOT_BUDGET_MS,
		"scene load → first frame is under %d ms (%d ms)" % [BOOT_BUDGET_MS, boot_ms])
	print("       measured: world_map.tscn boot (headless) = %d ms" % boot_ms)
	var pixels: Vector2 = world.map_pixels()
	_check(pixels == Vector2(WORLD_WIDTH * TILE_SIZE_PX, WORLD_HEIGHT * TILE_SIZE_PX),
		"the scene's map is %d×%d px (got %s)"
		% [WORLD_WIDTH * TILE_SIZE_PX, WORLD_HEIGHT * TILE_SIZE_PX, str(pixels)])
	_check(world.fleet_cell() == GameState.world_tile(),
		"the fleet marker sits on the stored world tile")
	# The scene never re-reads the PNG: DataLoader.map is the same instance.
	_check(DataLoader.map != null and DataLoader.map.width == WORLD_WIDTH,
		"DataLoader.map is the loaded world loader (§5.2 handoff)")
	# Step off the harbor onto world sea.
	var cell: Vector2i = world.fleet_cell()
	var stepped := false
	for delta in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
		if world.try_step(cell + delta):
			stepped = true
			break
	_check(stepped, "the fleet can sail away from Lisbon on the world map")
	# `_cell_at` wraps x, like every other cell lookup (§4.1).
	var map_width_px := float(WORLD_WIDTH * TILE_SIZE_PX)
	_check(world._cell_at(Vector2(map_width_px + 16.5, 16.5)).x == 0,
		"a click past x = 2160 maps to x = 0 (wrap)")
	_check(world._cell_at(Vector2(-16.5, 16.5)).x == WORLD_WIDTH - 1,
		"a click at x < 0 maps to the last column (wrap)")
	world.queue_free()
	await get_tree().process_frame


# --- 9. Chunked rendering: ≤ 24 chunks, no void across the dateline -----

func _test_chunked_rendering() -> void:
	GameState.new_game("portugal", false)
	var world: Node2D = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	var loader = DataLoader.map
	var root := world.get_node_or_null("WorldChunks")
	_check(root != null, "the scene builds a 'WorldChunks' root (§9 step 4)")
	_check(loader.live_chunk_count() > 0,
		"chunks are spawned around the camera (%d)" % loader.live_chunk_count())
	_check(loader.live_chunk_count() <= MAX_LIVE_CHUNKS,
		"live chunks ≤ %d (got %d)" % [MAX_LIVE_CHUNKS, loader.live_chunk_count()])
	_check(loader.live_chunk_bytes_estimate() < MAX_CHUNK_BYTES,
		"live chunk memory estimate < 50 MB (got %d bytes)"
		% loader.live_chunk_bytes_estimate())
	var widest := 0
	var widest_bytes := 0
	# Pan the camera across the dateline (and to both latitude edges), sampling
	# the live chunk count, the memory estimate and the "no void" property.
	var centres := [
		Vector2i(1024, 308),          # Lisbon
		Vector2i(0, 308),             # the seam
		Vector2i(WORLD_WIDTH - 1, 308),  # the far side of the seam
		Vector2i(WORLD_WIDTH, 308),   # x = 2160: wrapped content, not void
		Vector2i(WORLD_WIDTH + 40, 308),
		Vector2i(-40, 308),           # x < 0: wrapped content
		Vector2i(0, 0),               # polar ice corner
		Vector2i(WORLD_WIDTH - 1, WORLD_HEIGHT - 1),
		Vector2i(1080, 540),          # mid-Pacific
	]
	var void_frames := 0
	for centre in centres:
		GameState.set_world_tile(Vector2i(
			posmod(centre.x, WORLD_WIDTH), clampi(centre.y, 0, WORLD_HEIGHT - 1)
		))
		world.sync_from_state()
		await get_tree().process_frame
		widest = maxi(widest, loader.live_chunk_count())
		widest_bytes = maxi(widest_bytes, loader.live_chunk_bytes_estimate())
		# The camera-centred view, in world pixels, may run past the map width;
		# the chunk layer must still cover every tile of it (wrapped sampling).
		if not loader.covers_rect_world(world.visible_world_rect()):
			void_frames += 1
			print("       void at centre %s (visible %s)"
				% [str(centre), str(world.visible_world_rect())])
	_check(void_frames == 0,
		"every pan position across the dateline shows zero void (%d void frames)"
		% void_frames)
	_check(widest <= MAX_LIVE_CHUNKS,
		"the widest pan keeps ≤ %d live chunks (got %d)" % [MAX_LIVE_CHUNKS, widest])
	_check(widest_bytes < MAX_CHUNK_BYTES,
		"the widest pan keeps < 50 MB (%d bytes)" % widest_bytes)
	print("       measured: live chunks ≤ %d, estimate ≤ %d bytes (%d MB)"
		% [widest, widest_bytes, widest_bytes / (1024 * 1024)])
	# Chunks tile the grid exactly: 17 columns (2160 / 128 = 16.875) × 9 rows.
	var cols := int(ceil(float(WORLD_WIDTH) / float(CHUNK_TILES)))
	var rows := int(ceil(float(WORLD_HEIGHT) / float(CHUNK_TILES)))
	_check(cols == 17 and rows == 9,
		"the chunk grid is 17×9 with a partial last column (%d×%d)" % [cols, rows])
	world.queue_free()
	await get_tree().process_frame


# --- 10. Port overlays: 100, nation colours, seam duplicates -------------

func _test_port_overlays() -> void:
	GameState.new_game("portugal", false)
	# Every port known, so the overlay must draw all 100 (§9 step 5).
	GameState.known_ports.assign(DataLoader.ports.keys())
	var world: Node2D = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	await get_tree().process_frame
	var loader = DataLoader.map
	var overlay := world.get_node_or_null("PortOverlay")
	_check(overlay != null, "the scene builds a separate 'PortOverlay' layer")
	var entries: Array = loader.port_overlay_entries()
	_check(entries.size() == PORT_COUNT,
		"all %d ports render one overlay entry (got %d)"
		% [PORT_COUNT, entries.size()])
	var by_id := {}
	for entry in entries:
		var port_id := str((entry as Dictionary)["port_id"])
		by_id[port_id] = entry
	_check(by_id.size() == PORT_COUNT,
		"the overlay covers %d distinct ports (got %d)" % [PORT_COUNT, by_id.size()])
	var wrong_cell: Array = []
	var wrong_colour: Array = []
	var not_known: Array = []
	for port_id in DataLoader.ports:
		if not by_id.has(str(port_id)):
			not_known.append(str(port_id))
			continue
		var entry: Dictionary = by_id[str(port_id)]
		var want: Vector2i = _report_tiles.get(str(port_id), Vector2i(-1, -1))
		if (entry["cell"] as Vector2i) != want:
			wrong_cell.append("%s %s != %s"
				% [port_id, str(entry["cell"]), str(want)])
		var port: Dictionary = DataLoader.get_port(str(port_id))
		var nation: Dictionary = DataLoader.get_nation(str(port.get("nation_id", "")))
		var want_colour: Color = PaletteLib.nation_color(
			str(nation.get("color", "#ffffff"))
		)
		if (entry["colour"] as Color) != want_colour:
			wrong_colour.append(str(port_id))
	_check(not_known.is_empty(),
		"every port has an overlay entry (%s)" % str(not_known))
	_check(wrong_cell.is_empty(),
		"every overlay square sits on its harbor tile (%s)" % str(wrong_cell.slice(0, 4)))
	_check(wrong_colour.is_empty(),
		"%d overlay colours are their nation's colour (%s)"
		% [PORT_COUNT, str(wrong_colour.slice(0, 4))])
	# The overlay is only for known ports.
	GameState.known_ports = ["lisbon"]
	loader.refresh_port_overlay(DataLoader.ports, DataLoader.nations)
	_check(loader.port_overlay_entries().size() == 1,
		"an unknown port gets no overlay entry (got %d)"
		% loader.port_overlay_entries().size())
	# Seam duplication (§9 step 5): a port within 8 tiles of x = 0 also draws at
	# x + width, and one within 8 of x = width − 1 also at x − width. No shipped
	# port hugs the seam, so the fixture places one on each side of a 64-wide
	# in-memory grid — the same code path, no special case.
	var seam_ok: Array = _test_seam_duplication()
	_check(seam_ok[0] == true,
		"a harbor at x = 0 is wrap-duplicated at x + width (%s)" % str(seam_ok[1]))
	_check(seam_ok[2] == true,
		"a harbor at x = width-1 is wrap-duplicated at x - width (%s)" % str(seam_ok[3]))
	GameState.known_ports.assign(DataLoader.ports.keys())
	world.queue_free()
	await get_tree().process_frame


## Builds a 64×32 in-memory world with one port hugging each side of its seam
## and returns `[left_dup, left_offsets, right_dup, right_offsets]`.
func _test_seam_duplication() -> Array:
	var legend := {
		"grid": {"width": 64, "height": 32},
		"tile_size_px": TILE_SIZE_PX,
		"tiles": {
			"~": {"kind": "sea", "passable": true},
			".": {"kind": "coastal_sea", "passable": true},
			"#": {"kind": "land", "passable": false},
			"^": {"kind": "reef", "passable": false},
			"I": {"kind": "polar_ice", "passable": false},
		},
	}
	var bytes := _build_indexed_png(64, 32, ["~", ".", "#", "^", "I"])
	var seam_loader = MapLoaderLib.new()
	if not seam_loader.load_png_buffer(bytes, "test://seam.png", legend):
		return [false, "load failed: %s" % seam_loader.last_error, false, ""]
	# Scale = 64/360; lon −180 → x = 0, lon +179 → x = 63.
	seam_loader.ports_override = {
		"left_port": {"id": "left_port", "lat": 0.0, "lon": -180.0},
		"right_port": {"id": "right_port", "lat": 0.0, "lon": 179.0},
	}
	var parent := Node2D.new()
	add_child(parent)
	seam_loader.build_tilemap(parent, seam_loader.ports_override, {})
	var out: Array = []
	for port_id in ["left_port", "right_port"]:
		GameState.known_ports = [str(port_id)]
		seam_loader.refresh_port_overlay(seam_loader.ports_override, {})
		var offsets: Array = []
		for entry in seam_loader.port_overlay_entries():
			offsets.append(int((entry as Dictionary)["offset"]))
		offsets.sort()
		var cell: Vector2i = seam_loader.port_cell(str(port_id))
		var duplicated := offsets.size() == 2
		out.append(duplicated)
		out.append("cell %s offsets %s" % [str(cell), str(offsets)])
	parent.queue_free()
	return out


# --- 11. The Explore action on the world map ----------------------------

func _test_explore_action() -> void:
	GameState.new_game("portugal", false)
	GameState.day = 20
	var discovery: Dictionary = DataLoader.get_discovery("disc_atlas_cedars")
	var target: Vector2i = DiscoveryLib.position_of("disc_atlas_cedars")
	# Park the fleet three tiles away: inside the radius, not on the spot.
	GameState.set_world_tile(target + Vector2i(3, 0))
	GameState.discoveries_found = []
	var world: Node2D = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	await get_tree().process_frame
	var radius: int = DiscoveryLib.RADIUS
	_check(radius == 18, "the discovery radius is 18 (§4.4; got %d)" % radius)
	_check(world.something_near(), "something_near() is true within radius 18")
	var found: Array = world.explore_here()
	_check(found.has("disc_atlas_cedars"),
		"Explore finds the discovery at Chebyshev 3 (got %s)" % str(found))
	_check(not world.something_near(), "the found discovery is no longer in range")
	_check(world.explore_here().is_empty(), "exploring again finds nothing")
	# Out of range → nothing, and the HUD hint is silent.
	GameState.set_world_tile(target + Vector2i(radius + 1, 0))
	_check(not world.something_near(), "Chebyshev radius+1 is outside the Explore range")
	world._sync_hud()
	_check(not world.hud().explore_available(),
		"the HUD Explore affordance hides out of range")
	# Back in range: the HUD shows both the hint and the button, and the button
	# is wired to the same action as `E` (docs/80-* §4.3).
	GameState.set_world_tile(target + Vector2i(2, 0))
	GameState.discoveries_found = []
	world._sync_hud()
	_check(world.hud().explore_available(),
		"the HUD Explore affordance shows in range")
	_check(world.hud().explore_button_text() == I18n.t_key("discovery.explore"),
		"the button reads discovery.explore (%s)"
		% world.hud().explore_button_text())
	world.hud().press_explore()
	await get_tree().process_frame
	_check(GameState.discoveries_found.has("disc_atlas_cedars"),
		"the HUD Explore button runs the same action as E")
	world.queue_free()
	await get_tree().process_frame


# --- Helpers -------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	get_tree().quit(1)
