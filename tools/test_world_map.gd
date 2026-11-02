extends Node
## Phase-4 task G acceptance tests: the PNG → chunked-TileMap world
## (docs/IMPLEMENT-Phase4.md G; docs/90-* §9/§9.1; docs/10-* §6.1–§6.3;
## docs/20-* §4.1, §4.11–§4.12; docs/80-* §4.5, §4.8).
##
## Phase-6 task G adds the player-facing sailing surface cases (helm mode,
## Space wait semantics, trim keys, interpolated rendering purity, the
## heading-aware docking charge, the §4.18 ice toast path and the §2.9 HUD
## indicators; docs/IMPLEMENT-Phase6.md task G, §2.5/§2.6/§2.9).
##
##   godot --headless --path . tools/test_world_map.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")
const PaletteLib := preload("res://scripts/palette.gd")
## Phase 6: the sailing core whose APIs the world scene consumes.
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")

## docs/10-* §6.1: the locked grid and artifact.
const WORLD_WIDTH := 4320
const WORLD_HEIGHT := 2160
const TILE_SIZE_PX := 32
## docs/10-* §6.3: palette index 0–4 = `~ . # ^ I` (append-only).
const PALETTE_CHARS := "~.#^I"
## The 100 sovereign ports + the Phase-6 neutral tier (45) — the §7.1 roster.
const PORT_COUNT := 145
## The 13 ports whose §6.1 berth moved when the harbor-pair constraint bit at
## the Phase-6 grid (`20-*` §4.11.1) — the map's pinned regression table.
const HARBOR_PAIR_MOVED := {
	"smyrna": Vector2i(2484, 617),
	"beirut": Vector2i(2586, 672),
	"ceuta": Vector2i(2095, 649),
	"havana": Vector2i(1171, 801),
	"portobelo": Vector2i(1204, 964),
	"valparaiso": Vector2i(1300, 1475),
	"guayaquil": Vector2i(1197, 1112),
	"rio_de_janeiro": Vector2i(1640, 1353),
	"luanda": Vector2i(2318, 1184),
	"mombasa": Vector2i(2636, 1127),
	"bombay": Vector2i(3033, 851),
	"malacca": Vector2i(3386, 1052),
	"patani": Vector2i(3375, 996),
}
## docs/90-* §9 step 4: 128×128-tile chunks, at most 24 live.
const CHUNK_TILES := 128
const MAX_LIVE_CHUNKS := 24
const MAX_CHUNK_BYTES := 50 * 1024 * 1024
## The §9 debug assert measured on this machine: boot (scene load → first frame)
## must stay under this, headless.
const BOOT_BUDGET_MS := 3000

# --- Phase-6 task-G fixtures (probed data facts, not hand-authored tiles) ---

## A current tile (NE, strength 3) with ≥ 80 open-water tiles eastward on its
## row: the helm auto-step walk + the HUD current-arrow fixture.
const HELM_CELL := Vector2i(1320, 600)
## An open-water cell with no current (the interval-math fixture).
const OPEN_SEA_CELL := Vector2i(1400, 640)
## A Baltic water tile just outside the month-1 ice mask, with its icy water
## neighbour: the §4.18 entry-refusal pair (ice months 12–3, gone by month 7).
const ICE_OUTSIDE := Vector2i(2378, 380)
const ICE_CELL := Vector2i(2379, 380)
## A real diagonal approach on the shipped map whose target is a shore tile
## (Marseille's): the heading-aware docking-charge fixture (`20-*` §4.11.1).
const MARSEILLE_SHORE := Vector2i(2224, 560)
const MARSEILLE_DIAG := Vector2i(2223, 561)

var _failures: Array[String] = []
var _checks := 0
## The `world_report.json` harbor (berth) tiles `{id: Vector2i}` (the builder's
## output).
var _report_tiles: Dictionary = {}
## The `world_report.json` shore tiles `{id: Vector2i}` (20-* §4.11.1).
var _report_shores: Dictionary = {}
## The shared world-map loader, loaded once in [_test_png_loads] and reused by
## the harbor and seam sections (the loader is read-only post-load, so the
## 9.3 M-tile PNG is decoded once, not three times).
var _map = null
## The one-pass `{palette index: tile count}` fold from [_test_png_loads]; the
## seam section reads it instead of re-sweeping the array per kind.
var _index_census: Dictionary = {}


func _ready() -> void:
	_report_tiles = _load_report_tiles("harbor_tile")
	_report_shores = _load_report_tiles("shore_tile")
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
	# Phase-6 task G: the player-facing sailing surface.
	await _test_helm_mode()
	await _test_helm_cancels()
	await _test_trim_keys()
	await _test_wait_keys()
	await _test_interpolation_purity()
	await _test_npc_path_playback()
	await _test_docking_cost_pin()
	await _test_ice_surface()
	await _test_hud_indicators()
	_report()


# --- 0. The builder's harbor tiles (the reference values) -----------------

func _load_report_tiles(key: String = "harbor_tile") -> Dictionary:
	var path := "res://data/maps/world_report.json"
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	var out: Dictionary = {}
	if not (data is Dictionary):
		return out
	for entry in (data.get("ports", []) as Array):
		if not (entry is Dictionary):
			continue
		var tile = (entry as Dictionary).get(key, null)
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
	# Shared instance: the harbor and seam sections reuse this loader (read-only
	# post-load) instead of re-decoding the artifact.
	_map = loader
	_check(loader.width == WORLD_WIDTH and loader.height == WORLD_HEIGHT,
		"the loaded grid is %d×%d (got %d×%d)"
		% [WORLD_WIDTH, WORLD_HEIGHT, loader.width, loader.height])
	_check(loader.tile_size_px == TILE_SIZE_PX,
		"the loader renders at %d px per tile" % TILE_SIZE_PX)
	_check(loader.indices.size() == WORLD_WIDTH * WORLD_HEIGHT,
		"one palette index per tile (%d bytes, got %d)"
		% [WORLD_WIDTH * WORLD_HEIGHT, loader.indices.size()])
	# ONE single-pass fold over all 9,331,200 indices: `{palette index: count}`
	# and `{terrain kind: count}` built in the same walk (the kind comes from
	# the legend's tile table — the same mapping `terrain_census()` applies).
	# Every sweep below reads this fold; nothing re-walks the array.
	var index_census := {}
	var census := {}
	var legend_tiles: Dictionary = DataLoader.map_legend["tiles"]
	for value in loader.indices:
		var index := int(value)
		index_census[index] = int(index_census.get(index, 0)) + 1
		if index < PALETTE_CHARS.length():
			var kind := str(
				(legend_tiles[PALETTE_CHARS[index]] as Dictionary).get("kind", ""))
			census[kind] = int(census.get(kind, 0)) + 1
	_index_census = index_census
	# Every index is inside the locked set. Indices 0, 1, 2 and 4 must appear;
	# `^` (3, reef) is explicitly optional in Phase 4 (build_world.py's done-when:
	# "no `^` required this phase (reef layer explicitly out of scope; `^` count
	# may be 0)"), so it is only required to be *legal* where present.
	for index in [0, 1, 2, 4]:
		_check(index_census.has(index),
			"palette index %d ('%s') appears in the artifact"
				% [index, PALETTE_CHARS[index]])
	var reef_tiles := int(census.get("reef", 0))
	print("       measured: palette presence %s (reef '^' is optional, %d tiles)"
		% [str(index_census.keys()), reef_tiles])
	_check(index_census.has(3) == (reef_tiles > 0),
		"the reef index and the reef census agree (%d tiles)" % reef_tiles)
	var out_of_set := 0
	for index in index_census:
		if int(index) >= PALETTE_CHARS.length():
			out_of_set += int(index_census[index])
	_check(out_of_set == 0,
		"no tile carries a palette index outside 0–4 (%d)" % out_of_set)
	# Terrain kinds agree with the legend (the fold's own kind census).
	_check(census.has("sea") and census.has("coastal_sea")
		and census.has("land") and census.has("polar_ice"),
		"the census names every terrain kind (%s)" % str(census.keys()))
	var total := 0
	for kind in census:
		total += int(census[kind])
	_check(total == WORLD_WIDTH * WORLD_HEIGHT,
		"the census covers every tile (%d)" % total)
	_check(loader.terrain_kind(Vector2i(2050, 615)) == "coastal_sea",
		"Lisbon's harbor tile reads coastal sea (got '%s')"
		% loader.terrain_kind(Vector2i(2050, 615)))

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
	var loader = _map
	_check(loader != null, "the map loads for the harbor fixture")
	if loader == null:
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
		"port_id_at wraps on x (x + 4320 is the same tile)")
	# --- Harbor pair (20-* §4.11.1) ---------------------------------------
	var shores: Dictionary = loader.shore_tiles()
	_check(shores.size() == PORT_COUNT,
		"all %d ports have a shore tile (got %d)" % [PORT_COUNT, shores.size()])
	var shore_mismatches: Array = []
	var shore_not_land: Array = []
	var shore_not_orthogonal: Array = []
	var non_unique: Array = []
	var seen_shores := {}
	for port_id in _report_shores:
		var want: Vector2i = _report_shores[port_id]
		var got: Vector2i = loader.shore_cell(str(port_id))
		if got != want:
			shore_mismatches.append("%s %s != %s" % [port_id, str(got), str(want)])
		if got.x >= 0 and loader.char_at(got) != "#":
			shore_not_land.append("%s %s" % [port_id, loader.char_at(got)])
		if got.x >= 0:
			var berth: Vector2i = loader.port_cell(str(port_id))
			var ddx := posmod(got.x - berth.x, WORLD_WIDTH)
			if ddx > WORLD_WIDTH / 2:
				ddx -= WORLD_WIDTH
			if absi(ddx) + absi(got.y - berth.y) != 1:
				shore_not_orthogonal.append("%s %s vs berth %s"
					% [port_id, str(got), str(berth)])
		if seen_shores.has(got):
			non_unique.append("%s/%s" % [seen_shores[got], port_id])
		seen_shores[got] = port_id
	_check(shore_mismatches.is_empty(),
		"all %d shore tiles equal world_report.json's (mismatches: %s)"
		% [PORT_COUNT, str(shore_mismatches.slice(0, 6))])
	_check(shore_not_land.is_empty(),
		"every shore tile is land '#' (%s)" % str(shore_not_land.slice(0, 6)))
	_check(shore_not_orthogonal.is_empty(),
		"every shore tile is orthogonally adjacent to its berth (%s)"
		% str(shore_not_orthogonal.slice(0, 6)))
	_check(non_unique.is_empty(),
		"no two ports share a shore tile (%s)" % str(non_unique.slice(0, 6)))
	_check(loader.shore_cell("nope") == Vector2i(-1, -1),
		"an unknown port has no shore tile")
	# Both halves of the pair are memoised: the second call returns the same
	# answer without re-running the derivation.
	var lisbon_shore_first: Vector2i = loader.shore_cell("lisbon")
	var lisbon_berth_first: Vector2i = loader.port_cell("lisbon")
	var shores_again: Dictionary = loader.shore_tiles()
	_check(shores_again.size() == PORT_COUNT
		and shores_again["lisbon"] == lisbon_shore_first
		and loader.port_cell("lisbon") == lisbon_berth_first,
		"shore_tiles()/port_cell() are memoised (stable across calls)")
	# The inverse lookup covers every port and wraps on x.
	var shore_covered := 0
	for port_id in shores:
		if loader.shore_port_at(shores[port_id]) == str(port_id):
			shore_covered += 1
	_check(shore_covered == PORT_COUNT,
		"shore_port_at() reverses every shore tile (%d of %d)"
		% [shore_covered, PORT_COUNT])
	var lisbon_shore: Vector2i = _report_shores["lisbon"]
	_check(loader.shore_port_at(
			Vector2i(lisbon_shore.x + WORLD_WIDTH, lisbon_shore.y)) == "lisbon",
		"shore_port_at wraps on x (x + 4320 is the same tile)")
	# The berth and the shore tile are two different tiles of one pair.
	_check(lisbon_shore != lisbon,
		"Lisbon's shore tile %s is not its berth %s"
		% [str(lisbon_shore), str(lisbon)])
	# `port_cell` still means **berth**: nothing renamed it.
	_check(loader.port_cell("lisbon") == lisbon and loader.shore_cell("lisbon") == lisbon_shore,
		"port_cell() is the berth and shore_cell() the shore (unchanged semantics)")
	# The 14 berths the pair constraint moved, pinned: every one is exactly the
	# expected one-tile shift and is no longer the plain §6.1 snap.
	var moved_wrong: Array = []
	for port_id in HARBOR_PAIR_MOVED:
		var want: Vector2i = HARBOR_PAIR_MOVED[port_id]
		var got: Vector2i = loader.port_cell(str(port_id))
		if got != want:
			moved_wrong.append("%s %s != %s" % [port_id, str(got), str(want)])
	_check(moved_wrong.is_empty(),
		"the 13 re-snapped berths are exactly the pinned tiles (%s)"
		% str(moved_wrong.slice(0, 4)))
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


## ≥ 1 orthogonally adjacent water tile (x wraps), matching the snap rule.
func _has_orthogonal_water(loader, cell: Vector2i) -> bool:
	for delta in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if loader.is_passable(cell + delta):
			return true
	return false


# --- 5. Passability at the seam, for all five kinds ----------------------

func _test_passability_seam() -> void:
	var loader = _map
	_check(loader != null, "the map loads for the seam fixture")
	if loader == null:
		return
	# Find a row where each kind occurs at both x = 0 and x = 2159, so the seam
	# assertion is about the *tiles*, not one lucky row.
	var rows := {}
	for y in loader.height:
		var left: int = loader.index_xy(0, y)
		var right: int = loader.index_xy(WORLD_WIDTH - 1, y)
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
		if _index_census.has(index):
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
				for x in [0, 1, WORLD_WIDTH - 1, 1080, 2160, 3240]:
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
		"x = 0, 4319, -1 and 4320 all address sea on row %d" % wet_y)
	# y is bounded: the latitude edges are closed.
	_check(not loader.is_passable_xy(100, -1)
		and not loader.is_passable_xy(100, WORLD_HEIGHT),
		"y = -1 and y = 2160 are impassable (latitude edges, §4.1)")
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
	_check(lisbon_projection == Vector2i(2050, 615),
		"Lisbon's lat/lon projects into tile (2050,615) "
		+ "(x = floor((lon+180)*12) = floor(2050.32), §6.1; got %s)"
		% str(lisbon_projection))
	var lisbon_harbor: Vector2i = loader.port_cell("lisbon")
	_check(maxi(absi(lisbon_harbor.x - lisbon_projection.x),
			absi(lisbon_harbor.y - lisbon_projection.y)) <= 2,
		"Lisbon's harbor %s is within the 2-tile snap radius of its projection %s"
		% [str(lisbon_harbor), str(lisbon_projection)])
	_check(loader.tile_of_latlon(0.0, 180.0).x == 0,
		"lon 180 projects to x = 0 (wrapped)")
	_check(loader.chebyshev(Vector2i(4318, 500), Vector2i(2, 500)) == 4,
		"Chebyshev across the seam is 4 for x=4318 vs x=2 (got %d)"
		% loader.chebyshev(Vector2i(4318, 500), Vector2i(2, 500)))


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
	var test_shore: Vector2i = loader.shore_cell("test_port")
	_check(test_shore.x >= 0 and loader.char_at(test_shore) == "#",
		"the swapped grid derives a shore tile inside its own bounds (%s)"
		% str(test_shore))
	_check(loader.shore_port_at(test_shore) == "test_port",
		"shore_port_at() reverses the swapped grid's shore tile")
	# A berth with **no** orthogonally adjacent `#` is a data error: the pair
	# rule skips it and the loader reports no shore tile at all (§4.11.1).
	var all_water_bytes := PackedByteArray()
	all_water_bytes.resize(16 * 16)
	var all_water = MapLoaderLib.from_indices(16, 16, all_water_bytes, legend)
	_check(all_water != null, "an all-water synthetic grid builds")
	if all_water != null:
		all_water.ports_override = {"water_port": {
			"id": "water_port", "lat": 0.0, "lon": 0.0}}
		# The plain §6.1 snap still finds water; the **pair** rule rejects it, so
		# the port has no berth tile and therefore no shore tile (the validator's
		# item 2b turns this into a named failure on real data).
		_check(all_water.snap_harbor(0.0, 0.0) != Vector2i(-1, -1),
			"the plain snap finds water on the all-water grid")
		_check(all_water.snap_harbor_with_shore(0.0, 0.0) == Vector2i(-1, -1),
			"the pair-aware snap rejects a berth with no '#' neighbour")
		_check(all_water.shore_cell("water_port") == Vector2i(-1, -1),
			"a berth with no adjacent '#' has no shore tile")
		_check(all_water.shore_port_at(Vector2i(8, 8)).is_empty(),
			"…and no shore lookup answers for the all-water grid")
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
		"a click past x = 4320 maps to x = 0 (wrap)")
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
		Vector2i(2050, 615),          # Lisbon
		Vector2i(0, 615),             # the seam
		Vector2i(WORLD_WIDTH - 1, 615),  # the far side of the seam
		Vector2i(WORLD_WIDTH, 615),   # x = 4320: wrapped content, not void
		Vector2i(WORLD_WIDTH + 40, 615),
		Vector2i(-40, 615),           # x < 0: wrapped content
		Vector2i(0, 0),               # polar ice corner
		Vector2i(WORLD_WIDTH - 1, WORLD_HEIGHT - 1),
		Vector2i(2160, 1080),         # mid-Pacific
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
	# Chunks tile the grid exactly: 34 columns (4320 / 128 = 33.75) × 17 rows.
	var cols := int(ceil(float(WORLD_WIDTH) / float(CHUNK_TILES)))
	var rows := int(ceil(float(WORLD_HEIGHT) / float(CHUNK_TILES)))
	_check(cols == 34 and rows == 17,
		"the chunk grid is 34×17 with a partial last column (%d×%d)" % [cols, rows])
	world.queue_free()
	await get_tree().process_frame


# --- 10. Port overlays: 145, nation colours, seam duplicates -------------

func _test_port_overlays() -> void:
	GameState.new_game("portugal", false)
	# Every port known, so the overlay must draw all 145 (§9 step 5).
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
	var wrong_berth: Array = []
	var wrong_colour: Array = []
	var not_known: Array = []
	for port_id in DataLoader.ports:
		if not by_id.has(str(port_id)):
			not_known.append(str(port_id))
			continue
		var entry: Dictionary = by_id[str(port_id)]
		var want: Vector2i = _report_shores.get(str(port_id), Vector2i(-1, -1))
		if (entry["cell"] as Vector2i) != want:
			wrong_cell.append("%s %s != %s"
				% [port_id, str(entry["cell"]), str(want)])
		if (entry["shore_cell"] as Vector2i) != want:
			wrong_cell.append("%s shore_cell %s != %s"
				% [port_id, str(entry["shore_cell"]), str(want)])
		var want_berth: Vector2i = _report_tiles.get(str(port_id), Vector2i(-1, -1))
		if (entry["berth_cell"] as Vector2i) != want_berth:
			wrong_berth.append("%s %s != %s"
				% [port_id, str(entry["berth_cell"]), str(want_berth)])
		var port: Dictionary = DataLoader.get_port(str(port_id))
		# §2.11/§4.8: a neutral-tier port (nation_id "") draws the pinned
		# PORT_NEUTRAL grey — the §4.8 constant the overlay resolves for the
		# empty nation id (lookup misses keep the generic ACCENT fallback).
		var want_colour: Color
		if str(port.get("nation_id", "")) == "":
			want_colour = PaletteLib.PORT_NEUTRAL
		else:
			var nation: Dictionary = DataLoader.get_nation(
				str(port.get("nation_id", "")))
			want_colour = PaletteLib.nation_color(
				str(nation.get("color", "#ffffff"))
			)
		if (entry["colour"] as Color) != want_colour:
			wrong_colour.append(str(port_id))
	_check(not_known.is_empty(),
		"every port has an overlay entry (%s)" % str(not_known))
	_check(wrong_cell.is_empty(),
		"every overlay square sits on its shore tile (%s)"
		% str(wrong_cell.slice(0, 4)))
	_check(wrong_berth.is_empty(),
		"every overlay entry carries its berth tile (%s)"
		% str(wrong_berth.slice(0, 4)))
	_check(wrong_colour.is_empty(),
		"%d overlay colours are their nation's colour (%s)"
		% [PORT_COUNT, str(wrong_colour.slice(0, 4))])
	# The berth marker is drawn on the berth tile, next to the square: the pair
	# reads at a glance (20-* §4.11.1 presentation rule). The check is exact:
	# the marker's centre must be the berth tile's centre **relative to the
	# drawn shore tile**, for the world copy and every seam copy alike.
	var marker_ok := 0
	var marker_off: Array = []
	for entry in entries:
		var node = (entry as Dictionary)["node"]
		var marker = node.get_node_or_null("BerthMarker") if node != null else null
		if marker == null:
			marker_off.append("%s: no marker" % str((entry as Dictionary)["port_id"]))
			continue
		var shore: Vector2i = (entry as Dictionary)["shore_cell"]
		var berth: Vector2i = (entry as Dictionary)["berth_cell"]
		var tile := float(TILE_SIZE_PX)
		var want_centre := Vector2(berth - shore) * tile + Vector2(tile, tile) * 0.5
		var got_centre: Vector2 = marker.position + marker.size * 0.5
		if (got_centre - want_centre).length() <= 0.5:
			marker_ok += 1
		else:
			marker_off.append("%s %s != %s"
				% [str((entry as Dictionary)["port_id"]), str(got_centre),
					str(want_centre)])
	_check(marker_ok == PORT_COUNT,
		"every port draws its berth marker centred on the berth tile (%d of %d; %s)"
		% [marker_ok, PORT_COUNT, str(marker_off.slice(0, 3))])
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
		"a port at x = 0 is wrap-duplicated (shore + berth) at x + width (%s)"
		% str(seam_ok[1]))
	_check(seam_ok[2] == true,
		"a port at x = width-1 is wrap-duplicated (shore + berth) at x - width (%s)"
		% str(seam_ok[3]))
	GameState.known_ports.assign(DataLoader.ports.keys())
	world.queue_free()
	await get_tree().process_frame


## Builds a 64×32 in-memory world with one port hugging each side of its seam
## and returns `[left_dup, left_detail, right_dup, right_detail]`. Each detail
## string reports the shore tile, the berth tile and the seam offsets, so a
## failure says which half of the pair was not duplicated.
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
	# Scale = 64/360; lon −180 → x = 0; the eastern fixture projects to x = 63
	# (one step short of the seam, so its `-width` copy is the wrap).
	seam_loader.ports_override = {
		"left_port": {"id": "left_port", "lat": 0.0, "lon": -180.0},
		"right_port": {"id": "right_port", "lat": -11.25, "lon": 179.0},
	}
	var parent := Node2D.new()
	add_child(parent)
	seam_loader.build_tilemap(parent, seam_loader.ports_override, {})
	var out: Array = []
	for port_id in ["left_port", "right_port"]:
		GameState.known_ports = [str(port_id)]
		seam_loader.refresh_port_overlay(seam_loader.ports_override, {})
		var offsets: Array = []
		var both_drawn := true
		for entry in seam_loader.port_overlay_entries():
			var e: Dictionary = entry
			offsets.append(int(e["offset"]))
			var node = e["node"]
			var marker = node.get_node_or_null("BerthMarker") if node != null else null
			if marker == null:
				both_drawn = false
				continue
			# The copy's berth marker must sit on its own berth tile, i.e. one
			# step from the copy's shore tile — not on the un-offset world tile.
			var shore: Vector2i = e["shore_cell"]
			var berth: Vector2i = e["berth_cell"]
			var want_berth := Vector2(berth - shore) * float(TILE_SIZE_PX)
			if (marker.position - want_berth).length() > float(TILE_SIZE_PX):
				both_drawn = false
		offsets.sort()
		var shore: Vector2i = seam_loader.shore_cell(str(port_id))
		var berth: Vector2i = seam_loader.port_cell(str(port_id))
		out.append(offsets.size() == 2 and both_drawn)
		out.append("shore %s berth %s offsets %s marker-copy %s"
			% [str(shore), str(berth), str(offsets), str(both_drawn)])
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
	_check(radius == 36, "the discovery radius is 36 (§4.4; got %d)" % radius)
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


# --- 12. Phase 6: helm mode (docs/20-* §4.2, §2.6) ------------------------

## Builds a survivable open-sea run (the test_movement fixture shape, local
## to this suite) at `at` on `day`, with a pinned wind and weather.
func _make_sea_run(at: Vector2i, day: int = 1, wind_dir: String = "S",
		weather: String = "fair", trim: String = "normal") -> void:
	GameState.new_game("portugal", false)
	GameState.player["stats"] = {
		"leadership": 10, "seamanship": 10, "combat": 10,
		"navigation": 10, "luck": 10,
	}
	GameState.fleet[0]["provisions"] = 500
	GameState.fleet[0]["water"] = 500
	GameState.day = day
	GameState.gold = 1000
	GameState.morale = 70
	GameState.current_port = null
	GameState.known_ports = []
	GameState.world = {
		"position": {"x": at.x, "y": at.y},
		"clock_fraction": 0.0,
		"map_id": "world",
		"weather": weather,
		"wind_dir": wind_dir,
		"sail_trim": trim,
		"heading": "E",
	}
	SailingSimLib.reset_ledger_state()


## Instantiates the world scene over the current fixture (no routing) and
## waits one frame so `_ready` + the first `_process` tick complete.
func _open_world() -> Node2D:
	var world: Node2D = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	await get_tree().process_frame
	return world


## A pressed (non-echo) input action, for driving `_unhandled_input` directly.
func _action_event(action: String) -> InputEventAction:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	return ev


func _test_helm_mode() -> void:
	_make_sea_run(HELM_CELL)
	var world: Node2D = await _open_world()
	# Guard-call default: `control_prefs` does not exist until task V lands.
	_check(world.input_mode() == "step",
		"the guard-read input mode is step without control_prefs (got %s)"
			% world.input_mode())
	# Step-mode cadence numbers are untouched (byte-identity guard).
	var hold: Dictionary = world.hold_state()
	_check(is_equal_approx(float(hold["delay"]), 0.25)
		and is_equal_approx(float(hold["tiles_per_second"]), 8.0)
		and is_equal_approx(float(hold["step_seconds"]), 0.125),
		"step-mode hold cadence keeps its W4 numbers (%s)" % str(hold))

	# Steering sets `world.heading` and latches the auto-stepper; the press
	# itself does not step (the interval cadence owns every step).
	var start: Vector2i = world.fleet_cell()
	var clock0 := float(GameState.world["clock_fraction"])
	_check(world.helm_steer("move_e"), "helm_steer accepts a direction action")
	_check(world.helm_active(), "the helm auto-stepper latches on steer")
	_check(str(GameState.world["heading"]) == "E",
		"steering E persists world.heading 'E' (got %s)"
			% str(GameState.world["heading"]))
	_check(world.fleet_cell() == start, "a steer press itself steps nothing")
	# One interval → exactly one normal step; its clock cost is the heading
	# form `move_cost("E")` (beam + the (NE,3) current under the start tile:
	# 20 × 1.24 = 24 tiles/day → 1/24).
	var interval: float = world.helm_interval()
	_check(is_equal_approx(interval, 0.12),
		"the helm interval is the 0.12 s floor at 24 tiles/day (%.4f)" % interval)
	world.advance_movement(interval)
	_check(world.fleet_cell() == start + Vector2i(1, 0),
		"one auto-step after one interval (at %s)" % str(world.fleet_cell()))
	_check(is_equal_approx(float(GameState.world["clock_fraction"]),
			clock0 + SailingSimLib.move_cost("E")),
		"the auto-step charges move_cost('E') = 1/24 (%.4f)"
			% float(GameState.world["clock_fraction"]))
	# Nine more intervals → nine more steps, still day 1 (≤ 0.5 days total).
	world.advance_movement(interval * 9.0)
	_check(world.fleet_cell() == start + Vector2i(10, 0),
		"10 intervals auto-step exactly 10 tiles (at %s)" % str(world.fleet_cell()))
	_check(GameState.day == 1, "the walk stays inside day 1 (no batching)")

	# A new direction key re-steers without stopping.
	world.helm_steer("move_w")
	_check(str(GameState.world["heading"]) == "W" and world.helm_active(),
		"a new direction key re-steers and keeps auto-stepping")
	world.advance_movement(world.helm_interval() * 3.0)
	_check(world.fleet_cell() == start + Vector2i(7, 0),
		"the re-steered helm steps west (at %s)" % str(world.fleet_cell()))

	# Stopping: `helm_stop` halts the stepper, the heading persists.
	world.helm_stop()
	_check(not world.helm_active() and str(GameState.world["heading"]) == "W",
		"helm_stop stops the stepper and the heading persists")
	world.advance_movement(world.helm_interval() * 5.0)
	_check(world.fleet_cell() == start + Vector2i(7, 0),
		"no steps while the helm is stopped")

	# Interval math from a current-free cell: trim × wind × the clamp.
	GameState.set_world_tile(OPEN_SEA_CELL)
	world.sync_from_state()
	GameState.world["sail_trim"] = "normal"
	world.helm_steer("move_s")  # into a southerly wind: 20 × 0.5 = 10 → 0.12 floor
	_check(is_equal_approx(world.helm_interval(), 0.12),
		"into-wind normal trim (10 tiles/day) clamps to 0.12 s (%.4f)"
			% world.helm_interval())
	GameState.world["sail_trim"] = "reefed"
	_check(is_equal_approx(world.helm_interval(), 1.0 / 7.0),
		"reefed into-wind (7 tiles/day) is the unclamped 1/7 s (%.4f)"
			% world.helm_interval())
	GameState.world["sail_trim"] = "furled"
	_check(is_equal_approx(world.helm_interval(), 2.0),
		"a furled fleet (no speed) reads the 2.0 s cap (%.4f)"
			% world.helm_interval())
	world.helm_stop()

	# The `world_wait` / trim actions dispatch through `_unhandled_input` is
	# covered by their own cases; here: the direction dispatch by input mode.
	world.input_mode_override = "helm"
	var before: Vector2i = world.fleet_cell()
	world._unhandled_input(_action_event("move_e"))
	_check(world.helm_active() and str(GameState.world["heading"]) == "E"
		and world.fleet_cell() == before,
		"helm mode: a direction key sets course without stepping")
	world.helm_stop()
	world.input_mode_override = "step"
	world._unhandled_input(_action_event("move_e"))
	_check(not world.helm_active()
		and world.hold_state()["action"] == "move_e"
		and world.fleet_cell() == before + Vector2i(1, 0),
		"step mode: the same key steps once and starts the hold (verbatim)")
	world.release_direction("move_e")
	world.input_mode_override = ""
	world.queue_free()
	await get_tree().process_frame


func _test_helm_cancels() -> void:
	# §4.2 cancel seams — click-to-sail, docking, a battle handoff — on ONE
	# boot: re-fixture + sync_from_state between sub-cases. The battle handoff
	# runs last because only `battle_finished` clears that scene state.
	_make_sea_run(HELM_CELL)
	var world: Node2D = await _open_world()
	world.helm_steer("move_e")
	_check(world.sail_to(HELM_CELL + Vector2i(30, 0)),
		"a click route is found from the helming fleet")
	_check(not world.helm_active(),
		"click-to-sail cancels the helm")
	world.cancel_sail()

	# Docking cancels the helm; the heading persists (§2.6).
	var berth: Vector2i = _report_tiles["lisbon"]
	var shore: Vector2i = _report_shores["lisbon"]
	_make_sea_run(berth)
	world.sync_from_state()
	world.helm_steer("move_e")  # the shore tile lies east of the berth
	_check(world.try_step(shore), "the helming fleet docks into the shore tile")
	_check(GameState.current_port == "lisbon", "the dock opened the port")
	_check(not world.helm_active(), "docking cancels the helm")
	_check(str(GameState.world["heading"]) == "E",
		"the heading persists through docking (got %s)"
			% str(GameState.world["heading"]))
	world.hud().clear_dialogs()

	# A battle handoff cancels the helm (the §4.11.11.3 funnel).
	_make_sea_run(HELM_CELL)
	world.sync_from_state()
	world.helm_steer("move_e")
	world._open_encounter({
		"id": "g_fixture_pirate", "role": "pirate", "nation_id": "",
		"ships": [],
		"contact": {"x": HELM_CELL.x + 1, "y": HELM_CELL.y},
	})
	_check(world.battle_in_progress() and not world.helm_active(),
		"a battle handoff cancels the helm (the §4.11.11.3 funnel)")

	world.queue_free()
	await get_tree().process_frame


# --- 13. Phase 6: trim keys (docs/20-* §4.17, §2.5) -----------------------

func _test_trim_keys() -> void:
	_make_sea_run(HELM_CELL)
	var world: Node2D = await _open_world()
	# Forward cycle follows `furled → reefed → normal → full`, wrapping.
	var forward := ["full", "furled", "reefed", "normal"]
	for expected in forward:
		world._unhandled_input(_action_event("trim_forward"))
		var got := str(GameState.world["sail_trim"])
		_check(got == expected,
			"trim_forward cycles normal → %s (got %s)" % [expected, got])
	# Backward walks the same ring the other way.
	world._unhandled_input(_action_event("trim_back"))
	_check(str(GameState.world["sail_trim"]) == "reefed",
		"trim_back walks the cycle backwards (normal → reefed, got %s)"
			% str(GameState.world["sail_trim"]))
	# The next step's cost picks the state up through F's §4.4 pipeline:
	# at the (NE,3) current tile, E is beam: normal 24 tiles/day, reefed 18.
	GameState.world["sail_trim"] = "normal"
	var fast: int = SailingSimLib.effective_speed("E")
	GameState.world["sail_trim"] = "reefed"
	var slow: int = SailingSimLib.effective_speed("E")
	_check(fast == 24 and slow == 18,
		"trim moves the effective speed 24 → 18 tiles/day (got %d → %d)"
			% [fast, slow])
	# The helm interval re-times from the new state without re-steering.
	GameState.set_world_tile(OPEN_SEA_CELL)
	world.sync_from_state()
	GameState.world["sail_trim"] = "normal"
	world.helm_steer("move_s")
	GameState.world["sail_trim"] = "reefed"
	_check(is_equal_approx(world.helm_interval(), 1.0 / 7.0),
		"the auto-step interval follows a mid-helm trim change (%.4f)"
			% world.helm_interval())
	world.helm_stop()
	# The chip follows the host-side cycle (world → HUD wiring).
	_check(world.hud().trim_chip_state() == "reefed"
		and world.hud().trim_chip_highlighted(),
		"the trim chip follows the cycle and highlights off-normal")
	# Toast wiring, with the §4.7.10 keys injected (report-only until the
	# master merges them): the composed chip toast fires, then the injection
	# is undone so the suite stays hermetic.
	DataLoader.ui_strings["world.trim.chip"] = {"zh": "帆位：{state}", "en": "Sails: {state}"}
	DataLoader.ui_strings["world.trim.full"] = {"zh": "满帆", "en": "full sail"}
	world._unhandled_input(_action_event("trim_forward"))  # reefed → normal
	world._unhandled_input(_action_event("trim_forward"))  # normal → full
	_check(world.hud().get_node("Toast").visible,
		"the trim cycle toasts the composed chip label with the master's keys")
	DataLoader.ui_strings.erase("world.trim.chip")
	DataLoader.ui_strings.erase("world.trim.full")
	world.queue_free()
	await get_tree().process_frame


# --- 14. Phase 6: wait keys (docs/20-* §4.17, correction 8) ---------------

func _test_wait_keys() -> void:
	# Both input modes on ONE boot: re-fixture + sync_from_state between them
	# (the seam under test is the input mode, not the boot).
	_make_sea_run(HELM_CELL)
	var world: Node2D = await _open_world()
	# Step mode: `Space` waits exactly one day, holding position.
	var out: Dictionary = world.press_wait()
	_check(bool(out["waited"]) and not bool(out["stopped"]),
		"step mode: Space waits one day (%s)" % str(out))
	_check(GameState.day == 2, "the wait advanced exactly 1 day (got %d)"
		% GameState.day)
	_check(world.fleet_cell() == HELM_CELL, "the wait held position")
	_check(int(GameState.fleet[0]["provisions"]) < 500 and GameState.gold < 1000,
		"the full ledger ran (provisions %d, gold %d)"
			% [int(GameState.fleet[0]["provisions"]), GameState.gold])
	# Refused while docked: nothing surfaced, no day.
	GameState.current_port = "lisbon"
	var docked_day: int = GameState.day
	out = world.press_wait()
	_check(not bool(out["waited"]) and GameState.day == docked_day,
		"the wait is refused while docked and costs nothing")
	GameState.current_port = null

	# Helm mode: the first Space stops, the second waits (correction 8).
	_make_sea_run(HELM_CELL)
	world.sync_from_state()
	world.input_mode_override = "helm"
	world.helm_steer("move_e")
	out = world.press_wait()
	_check(bool(out["stopped"]) and not bool(out["waited"]),
		"helm mode: the first Space stops the fleet (%s)" % str(out))
	_check(not world.helm_active() and GameState.day == 1,
		"the stop spent no day and ended the auto-stepper")
	out = world.press_wait()
	_check(bool(out["waited"]) and GameState.day == 2,
		"helm mode: the second Space waits one day")
	# Wait works regardless of trim (§4.17) — even furled.
	GameState.world["sail_trim"] = "furled"
	out = world.press_wait()
	_check(bool(out["waited"]) and GameState.day == 3,
		"a furled fleet can still wait (day %d)" % GameState.day)
	world.input_mode_override = ""
	world.queue_free()
	await get_tree().process_frame


# --- 15. Phase 6: interpolated rendering purity (§2.6) --------------------

## A deterministic scripted walk: 12 held steps east, then a 24-tile click
## route east. The caller seeds the weather/mutiny streams first so both
## walks replay identically.
func _scripted_walk(world: Node2D) -> Dictionary:
	var start: Vector2i = world.fleet_cell()
	world.press_direction("move_e")
	world.advance_movement(0.25 + 11 * 0.125)
	world.release_direction("move_e")
	_check(world.sail_to(start + Vector2i(24, 0)), "the click route is found")
	world.advance_movement(24 * 0.125 + 0.25)
	return {
		"cell": world.fleet_cell(),
		"tile": GameState.world_tile(),
		"day": GameState.day,
		"clock": float(GameState.world["clock_fraction"]),
		"gold": GameState.gold,
		"morale": GameState.morale,
		"provisions": int(GameState.fleet[0]["provisions"]),
		"water": int(GameState.fleet[0]["water"]),
	}


func _test_interpolation_purity() -> void:
	# Walk 1: interpolation on (the default). The marker-structure case runs on
	# the same boot afterwards: its checks are self-relative (one more held
	# step east on the same open-water row), so it needs no third boot.
	_make_sea_run(HELM_CELL)
	SailingSimLib.set_weather_seed(20261101)
	SailingSimLib.set_mutiny_seed(7)
	var world: Node2D = await _open_world()
	var with_glide: Dictionary = await _scripted_walk(world)
	# Structure: the offset lives only on the marker's draw position.
	var start: Vector2i = world.fleet_cell()
	world.press_direction("move_e")
	var landed := start + Vector2i(1, 0)
	_check(world.fleet_cell() == landed,
		"the tile truth moves on the step, not on the animation")
	_check(world.marker_gliding() and world.marker_offset() != Vector2.ZERO,
		"the marker animates between tiles after the step")
	world.advance_render(10.0)
	_check(not world.marker_gliding() and world.marker_offset() == Vector2.ZERO,
		"the glide snaps onto the destination tile centre")
	_check(world.fleet_cell() == landed,
		"advancing the render moved no logic state")
	world.queue_free()
	await get_tree().process_frame

	# Walk 2: identical fixture and seeds, interpolation off.
	_make_sea_run(HELM_CELL)
	SailingSimLib.set_weather_seed(20261101)
	SailingSimLib.set_mutiny_seed(7)
	world = await _open_world()
	world.set_marker_glide_enabled(false)
	var without_glide: Dictionary = await _scripted_walk(world)
	for field in with_glide:
		_check(with_glide[field] == without_glide[field],
			"interpolation never changes logic outcomes: %s (%s == %s)"
				% [field, str(with_glide[field]), str(without_glide[field])])
	_check((with_glide["cell"] as Vector2i).x > HELM_CELL.x + 20,
		"the scripted walk actually moved (at %s)" % str(with_glide["cell"]))
	world.queue_free()
	await get_tree().process_frame


# --- 16. Phase 6: the heading-aware docking charge (master ruling) --------

# --- NPC marker path playback (80-* §4.5.2 stepwise-glide amendment) -------

## A multi-tile accrual report replays the walked path tile by tile: batch
## lockstep (one shared per-tile duration, same-frame start), intermediate
## tile centres passed through, snap on completion — and a path that never
## touches the expanded viewport animates nothing.
func _test_npc_path_playback() -> void:
	_make_sea_run(HELM_CELL)
	var world: Node2D = await _open_world()
	var sim = world.fleet_sim()
	_check(sim != null, "the sea fixture adopts a fleet sim")
	if sim == null:
		world.queue_free()
		await get_tree().process_frame
		return
	var centre_offset := Vector2(4.8, 4.8)  # the `_marker_square_px` centre term
	var near_a: Dictionary = sim.spawn("trader", "portugal", 1)
	var near_b: Dictionary = sim.spawn("trader", "spain", 1)
	var far: Dictionary = sim.spawn("trader", "portugal", 1)
	_check(not near_a.is_empty() and not near_b.is_empty()
		and not far.is_empty(), "the three fixture fleets spawn")
	if near_a.is_empty() or near_b.is_empty() or far.is_empty():
		world.queue_free()
		await get_tree().process_frame
		return
	NpcFleetsLib.set_position(near_a, HELM_CELL + Vector2i(6, 0))
	NpcFleetsLib.set_position(near_b, HELM_CELL + Vector2i(-6, 2))
	NpcFleetsLib.set_position(far, HELM_CELL + Vector2i(2500, 0))
	world._sync_marker_nodes()
	var id_a := str(near_a["id"])
	var id_b := str(near_b["id"])
	_check(world._marker_nodes.has(id_a) and world._marker_nodes.has(id_b),
		"the in-view fleets hold marker squares")
	var seg_a: Array[Vector2i] = [
		HELM_CELL + Vector2i(7, 0), HELM_CELL + Vector2i(8, 0),
		HELM_CELL + Vector2i(9, 0)]
	var seg_b: Array[Vector2i] = [
		HELM_CELL + Vector2i(-7, 2), HELM_CELL + Vector2i(-8, 2)]
	var seg_f: Array[Vector2i] = [
		HELM_CELL + Vector2i(2501, 0), HELM_CELL + Vector2i(2502, 0)]
	sim.moved_fleet_moves = [
		{"id": id_a, "from": HELM_CELL + Vector2i(6, 0),
			"path": seg_a, "to": seg_a[2]},
		{"id": id_b, "from": HELM_CELL + Vector2i(-6, 2),
			"path": seg_b, "to": seg_b[1]},
		{"id": str(far["id"]), "from": HELM_CELL + Vector2i(2500, 0),
			"path": seg_f, "to": seg_f[1]},
	]
	world._glide_fleet_moves()
	_check(world._npc_glides.has(id_a) and world._npc_glides.has(id_b),
		"the in-view fleets animate on the same drain")
	_check(not world._npc_glides.has(str(far["id"])),
		"the off-screen fleet snaps without playback state")
	var ga: Dictionary = world._npc_glides[id_a]
	var gb: Dictionary = world._npc_glides[id_b]
	_check((ga["points_px"] as PackedVector2Array).size() == 4,
		"A's polyline carries from + the 3 walked tiles")
	_check(is_equal_approx(float(ga["seg_duration"]),
			float(gb["seg_duration"])) and float(ga["seg_duration"]) > 0.0,
		"the batch marches in lockstep (one shared per-tile duration)")
	var step := float(ga["seg_duration"])
	var square_a: ColorRect = world._marker_nodes.get(id_a)
	var square_b: ColorRect = world._marker_nodes.get(id_b)
	world.advance_render(step * 0.5)
	var half := (Vector2(HELM_CELL + Vector2i(6, 0)) * 32.0 + centre_offset) \
		.lerp(Vector2(seg_a[0]) * 32.0 + centre_offset, 0.5)
	_check((square_a as ColorRect).position.distance_to(half) < 2.0,
		"the marker walks the first segment (halfway interpolates)")
	world.advance_render(step * 0.5)
	_check((square_a as ColorRect).position.distance_to(
			Vector2(seg_a[0]) * 32.0 + centre_offset) < 2.0
		and (square_b as ColorRect).position.distance_to(
			Vector2(seg_b[0]) * 32.0 + centre_offset) < 2.0,
		"one step lands each marker on its first walked tile")
	world.advance_render(step * 3.0)
	_check(not world._npc_glides.has(id_a) and not world._npc_glides.has(id_b),
		"the finished playbacks snap and drop their state")
	_check((square_a as ColorRect).position.distance_to(
			Vector2(seg_a[2]) * 32.0 + centre_offset) < 2.0
		and (square_b as ColorRect).position.distance_to(
			Vector2(seg_b[1]) * 32.0 + centre_offset) < 2.0,
		"the markers rest on their destinations' tile centres")
	world.queue_free()
	await get_tree().process_frame


func _test_docking_cost_pin() -> void:
	# Four docking-charge pins on ONE boot: re-fixture + sync_from_state
	# between sub-cases (each pin reads only its own clock arithmetic).
	var berth: Vector2i = _report_tiles["lisbon"]
	var shore: Vector2i = _report_shores["lisbon"]
	_make_sea_run(berth)
	var world: Node2D = await _open_world()

	# (a) The step-delta heading: docking east into Lisbon charges
	# `move_cost("E")` — with the pinned southerly wind that equals the beam
	# average, which is exactly why the W4 suite stays green.
	_check(world.try_step(shore), "the orthogonal docking gesture docks")
	# §4.1b: +1h of docking charge rides on the move cost.
	_check(is_equal_approx(float(GameState.world["clock_fraction"]),
			SailingSimLib.move_cost("E") + 1.0 / 24.0),
		"the docking charge carries the step-delta heading E + 1h (%.4f)"
			% float(GameState.world["clock_fraction"]))
	world.hud().clear_dialogs()

	# (b) The helm heading is the same delta under helm — the charge follows.
	_make_sea_run(berth)
	world.sync_from_state()
	world.helm_steer("move_e")
	world.try_step(shore)
	_check(is_equal_approx(float(GameState.world["clock_fraction"]),
			SailingSimLib.move_cost("E") + 1.0 / 24.0),
		"under helm the docking charge carries world.heading + 1h (%.4f)"
			% float(GameState.world["clock_fraction"]))
	world.hud().clear_dialogs()

	# (c) A docking move whose delta names a real diagonal heading charges
	# that heading: NE into Marseille's shore from the diagonal approach is
	# close-hauled against the southerly wind (0.7 × 20 = 14 → 1/14), not the
	# beam average 1/20. (A diagonal dock can never arise from try_step — the
	# no-corner-cut rule — so the seam is driven directly.)
	_make_sea_run(MARSEILLE_DIAG)
	world.sync_from_state()
	_check(DataLoader.map.shore_port_at(MARSEILLE_SHORE) == "marseille",
		"(2224,560) is Marseille's shore tile (data-derived guard)")
	_check(world._dock_at(MARSEILLE_SHORE),
		"the direct diagonal dock docks into marseille")
	_check(is_equal_approx(float(GameState.world["clock_fraction"]),
			SailingSimLib.move_cost("NE") + 1.0 / 24.0),
		"the diagonal dock charges move_cost('NE') = 1/14, plus the §4.1b hour (%.4f)"
			% float(GameState.world["clock_fraction"]))
	world.hud().clear_dialogs()

	# (d) Fallback: a target whose delta is no 8-dir step charges the
	# parameterless average (the ruling's "neither applies" branch).
	_make_sea_run(berth)
	world.sync_from_state()
	_check(world._dock_at(MARSEILLE_SHORE),
		"the fallback dock still opens a port (seam-level pin)")
	_check(is_equal_approx(float(GameState.world["clock_fraction"]),
			SailingSimLib.move_cost() + 1.0 / 24.0),
		"the fallback dock charges the parameterless move_cost + 1h (%.4f)"
			% float(GameState.world["clock_fraction"]))
	world.hud().clear_dialogs()

	world.queue_free()
	await get_tree().process_frame


# --- 17. Phase 6: the §4.18 ice toast path --------------------------------

func _test_ice_surface() -> void:
	# All three ice cases on ONE boot: month cases flip GameState.day (the
	# §4.18 lookups read the calendar at call time) and re-fixture +
	# sync_from_state between them.
	# Month 1 (day 1): the Baltic fixture tile is frozen.
	_make_sea_run(ICE_OUTSIDE, 1)
	var world: Node2D = await _open_world()
	var clock0 := float(GameState.world["clock_fraction"])
	_check(not world.try_step(ICE_CELL),
		"a step onto in-month sea ice is refused")
	_check(world.fleet_cell() == ICE_OUTSIDE
		and float(GameState.world["clock_fraction"]) == clock0,
		"the refused ice step moves nothing and costs no clock")
	_check(SailingSimLib.last_move_blocked_key == SailingSimLib.ICE_BLOCKED_KEY,
		"the refusal records the sim's ice marker (last_move_blocked_key)")
	# The toast surfaces through the standard flow once the master merges the
	# key (injected here, then undone — the suite stays hermetic).
	DataLoader.ui_strings["world.ice.blocked"] = {
		"zh": "海冰封冻，无法进入。", "en": "Sea ice blocks the way.",
	}
	world.try_step(ICE_CELL)
	_check(world.hud().get_node("Toast").visible,
		"the refused ice step surfaces the world.ice.blocked toast")
	DataLoader.ui_strings.erase("world.ice.blocked")
	# A helm auto-step into the ice is refused too — and does not cancel the
	# helm (a blocked step is a spent slot, not a course change).
	world.helm_steer("move_e")
	world.advance_movement(world.helm_interval())
	_check(world.fleet_cell() == ICE_OUTSIDE and world.helm_active(),
		"the helm auto-step onto ice is refused and the helm keeps running")
	world.helm_stop()
	# A click onto the frozen tile pre-checks like a land click.
	DataLoader.ui_strings["world.ice.blocked"] = {
		"zh": "海冰封冻，无法进入。", "en": "Sea ice blocks the way.",
	}
	_check(not world.sail_to(ICE_CELL) and not world.sail_active(),
		"a click onto in-month ice is rejected with no route")
	_check(world.hud().get_node("Toast").visible,
		"the ice click surfaces the same toast")
	DataLoader.ui_strings.erase("world.ice.blocked")

	# §4.18 "a tile freezing under a standing fleet does not trap it": the
	# fleet starts ON the frozen tile and sails out west.
	_make_sea_run(ICE_CELL, 1)
	world.sync_from_state()
	world.helm_steer("move_w")
	world.advance_movement(world.helm_interval())
	_check(world.fleet_cell() == ICE_OUTSIDE,
		"a fleet standing on frozen water can still move out (at %s)"
			% str(world.fleet_cell()))
	world.helm_stop()

	# Month 7 (day 200): the same tile is open water and the step succeeds.
	_make_sea_run(ICE_OUTSIDE, 200)
	world.sync_from_state()
	_check(world.try_step(ICE_CELL),
		"out of the ice window the same step is an ordinary move")

	world.queue_free()
	await get_tree().process_frame


# --- 18. Phase 6: HUD §2.9 indicators (structure, no label text) ----------

func _test_hud_indicators() -> void:
	_make_sea_run(HELM_CELL, 1)
	var world: Node2D = await _open_world()
	var hud = world.hud()
	# The warm-up ran: both ocean decodes finished before gameplay.
	var ocean = OceanLayersLib.instance()
	_check(ocean.decode_ok and ocean.currents_decoded,
		"the world scene warmed the ocean decodes at load (wind %s, currents %s)"
			% [str(ocean.decode_ok), str(ocean.currents_decoded)])
	_check(hud.get_node_or_null("TopRow/Calendar") != null
		and hud.get_node_or_null("BottomRow/TrimChip") != null
		and hud.get_node_or_null("WindLabel") != null
		and hud.get_node_or_null("CurrentLabel") != null,
		"the §2.9 indicator nodes exist (calendar, trim chip, wind, current)")
	# Wind arrow: rotates to `world.wind_dir`, always visible at sea.
	for case in [["N", 0.0], ["NE", 45.0], ["E", 90.0], ["SW", 225.0], ["NW", 315.0]]:
		GameState.world["wind_dir"] = case[0]
		hud.refresh_sailing_indicators()
		_check(is_equal_approx(hud.wind_arrow_angle(), float(case[1])),
			"the wind arrow rotates to %s = %s° (%.1f)"
				% [case[0], str(case[1]), hud.wind_arrow_angle()])
	_check(hud.wind_arrow_visible(), "the wind indicator is visible at sea")
	# Current arrow: shown on a current tile with the decoded direction,
	# hidden on a plain-water tile.
	GameState.set_world_tile(HELM_CELL)
	world.sync_from_state()
	_check(hud.current_arrow_visible()
		and is_equal_approx(hud.current_arrow_angle(), 45.0),
		"the current arrow shows on a current tile at the decoded NE bearing")
	GameState.set_world_tile(OPEN_SEA_CELL)
	world.sync_from_state()
	_check(not hud.current_arrow_visible(),
		"the current arrow hides on a no-current tile")
	# Trim chip: mirrors `world.sail_trim`, highlighted off-normal.
	GameState.world["sail_trim"] = "normal"
	hud.refresh_sailing_indicators()
	_check(hud.trim_chip_state() == "normal" and not hud.trim_chip_highlighted(),
		"the trim chip reads normal unhighlighted")
	GameState.world["sail_trim"] = "reefed"
	hud.refresh_sailing_indicators()
	_check(hud.trim_chip_state() == "reefed" and hud.trim_chip_highlighted(),
		"the trim chip highlights while the trim is off-normal")
	# Calendar: the §4.15 year/month math, composed numerically (§4.7.10).
	for case in [[1, 1, 1], [31, 1, 2], [361, 2, 1]]:
		GameState.day = case[0]
		hud.refresh_sailing_indicators()
		var cal: Dictionary = hud.calendar_displayed()
		_check(int(cal["year"]) == case[1] and int(cal["month"]) == case[2],
			"day %d displays as year %d month %d (got %s)"
				% [case[0], case[1], case[2], str(cal)])
	# Read-only: an indicator refresh mutates nothing.
	GameState.day = 5
	GameState.world["wind_dir"] = "NE"
	GameState.world["sail_trim"] = "full"
	var world_snapshot: Dictionary = GameState.world.duplicate()
	hud.refresh_sailing_indicators()
	_check(GameState.world.duplicate() == world_snapshot and GameState.day == 5,
		"refresh_sailing_indicators never mutates GameState")
	# Host wiring: a world-side trim cycle reaches the chip without a signal.
	var cycled: String = world.cycle_trim(true)  # full → wraps to furled
	_check(cycled == "furled" and hud.trim_chip_state() == "furled"
		and hud.trim_chip_highlighted(),
		"cycle_trim repaints the chip through the world→HUD seam")
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
