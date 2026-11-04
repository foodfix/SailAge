extends Node
## Phase-10 W4-C acceptance tests (docs/IMPLEMENT-Phase10.md §3 + §5 "Terrain
## wiring" / "Arrow field" / "World markers"; docs/80-UI-UX.md §4.8.5–§4.8.10;
## docs/90-ARCHITECTURE.md §9.2; docs/10-DATA-SCHEMA.md §6.6).
## Headless scene test:
##
##   godot --headless res://tools/test_terrain_art.tscn
##
## Exits 0 when every check passes, 1 otherwise. Covers:
##   * the §9.2 terrain variant hash `(x·31 + y·17) % variants` (fixed cells →
##     fixed ids, seam-stable over the WRAPPED column);
##   * the terrain atlas resolves every legend kind + variant (registry empty
##     in suites ⇒ the flat palette fallback cells);
##   * the §6.6 shore overlay decode (the shipped raster, the Lisbon berth
##     `e` code, wrap-aware lookup, water-only codes on a sampled strip);
##   * the §4.7.17 water layer: flat tiles for both water kinds, the shared
##     material's pinned params (period 800 ms, darkening ×0.82) and the
##     `UiMotion` gate (off ⇒ `u_motion` 0), the S10 reuse seam;
##   * the §4.8.6 dir-id table (every bucket covered; token + vector forms);
##   * the arrow field's deterministic sampling against a fixture decode
##     (stride-4 lattice, water cells only, wind/current/VAR entries);
##   * the S3 `W`/`C` fields default OFF, the amended §4.8.10 key matrix
##     (`W` always toggles wind; `C` toggles current while either field is
##     on, shadowing the intel `C`; both-off `C` is the intel's), and the
##     month-rollover re-sample;
##   * the world markers: every discovery category resolves as an id,
##     discovered-only visibility, the wreck/treasure registry fallbacks;
##   * the PRODUCTION texture path (the 2026-11-04 grey-void regression): the
##     registry POPULATED first (as `title_screen` does at boot), then the
##     water tile set + terrain atlas + shore overlay rebuild through the
##     registry textures with real pixel content pinned (center pixel == the
##     locked §4.8 palette hex; foam/marker cells non-empty). The earlier
##     groups keep the empty-registry fallback coverage — this one runs last.
##
## Prerequisite: a fresh checkout needs the compiled import cache — run
## `godot --headless --import` once before this suite, else the texture
## `load()`s return null, the registry stays empty and the populated-registry
## section fails its first check by design.
##
## No overkill: one world boot re-fixtured across the groups; the shore
## raster's full-grid correctness is the validator's (group 13), the suite
## pins only the decode seam and named cells.

const MapLoaderLib := preload("res://scripts/world/map_loader.gd")
const WaterLayerLib := preload("res://scripts/world/water_layer.gd")
const ArrowFieldLib := preload("res://scripts/world/arrow_field.gd")
const UiKitLib := preload("res://scripts/ui_kit.gd")
const UiMotionLib := preload("res://scripts/ui_motion.gd")
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")
const PaletteLib := preload("res://scripts/palette.gd")
const TextureRegistryLib := preload("res://scripts/ui/texture_registry.gd")
const WorldScene := preload("res://scenes/world/world_map.tscn")

## Lisbon's harbor pair (the persisted §6.1 table; the W3-C shore record:
## the berth tile codes `e` — the shore sits due east of it).
const LISBON_BERTH := Vector2i(2050, 615)
## An open-Atlantic tile far from any coast (code 0) and its wrap twin.
const OPEN_SEA := Vector2i(1000, 1080)

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	UiMotionLib.enabled = false  # the direct-boot pattern (§4.7.17)
	_test_variant_hash()
	_test_terrain_atlas()
	_test_shore_overlay()
	_test_water_layer()
	_test_dir_table()
	_test_arrow_field_fixture()
	_test_arrow_field_world()
	_test_world_markers()
	_test_populated_registry()
	_test_shore_strips_and_material()
	UiKitLib.clear_textures()
	_report()


# --- Harness ----------------------------------------------------------------

func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures.append(message)
		print("FAIL  %s" % message)
	return condition


func _report() -> void:
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
	else:
		print("%d checks FAILED" % _failures.size())
		for failure in _failures:
			print("  - %s" % failure)
		get_tree().quit(1)


# --- §9.2 terrain variant hash ----------------------------------------------

func _test_variant_hash() -> void:
	_check(MapLoaderLib.terrain_variant_index(0, 0, 4) == 0,
		"variant hash at (0,0) is 0")
	_check(MapLoaderLib.terrain_variant_index(1, 0, 4) == 31 % 4,
		"variant hash is (x·31 + y·17) % n at (1,0)")
	_check(MapLoaderLib.terrain_variant_index(3, 5, 4)
		== (3 * 31 + 5 * 17) % 4, "variant hash at (3,5) matches the pin")
	_check(MapLoaderLib.terrain_variant_index(2113, 1474, 4)
		== MapLoaderLib.terrain_variant_index(2113 + 4320, 1474, 4),
		"the WRAPPED column picks the same variant across the seam")
	_check(MapLoaderLib.terrain_variant_index(-1, 2, 4)
		== MapLoaderLib.terrain_variant_index(4319, 2, 4),
		"negative chunk-side x folds onto the wrapped answer")
	_check(MapLoaderLib.terrain_variant_index(7, 11, 1) == 0,
		"a single-variant kind always picks 0")
	_check(int(MapLoaderLib.TERRAIN_VARIANTS.get("land", 0)) == 4
		and int(MapLoaderLib.TERRAIN_VARIANTS.get("reef", 0)) == 1
		and int(MapLoaderLib.TERRAIN_VARIANTS.get("polar_ice", 0)) == 2,
		"the locked A.5 variant counts are land 4 / reef 1 / polar_ice 2")


# --- Terrain atlas: every legend kind + variant resolves --------------------

func _test_terrain_atlas() -> void:
	var loader = MapLoaderLib.new()
	_check(loader.load_map("res://data/maps/world.png", DataLoader.map_legend),
		"the world map loads (%s)" % loader.last_error)
	loader._ensure_tile_set()
	_check(loader._terrain_cells.size() == 3,
		"three terrain-art kinds resolve from the legend (land/reef/polar_ice)")
	for index in [2, 3, 4]:
		var entry: Dictionary = loader._terrain_cells.get(index, {})
		_check(not entry.is_empty(),
			"palette index %d resolves its legend kind (%s)" % [index,
			loader.kind_of_index(index)])
	_check(loader.kind_of_index(0) == "sea" and loader.kind_of_index(1) == "coastal_sea",
		"the water kinds stay data-driven off the legend")
	_check(WaterLayerLib.KIND_COLUMNS.has("sea")
		and WaterLayerLib.KIND_COLUMNS.has("coastal_sea"),
		"the water layer owns exactly the two flat water kinds")
	_check(WaterLayerLib.sprite_id("sea") == "terrain_sea_0"
		and WaterLayerLib.sprite_id("coastal_sea") == "terrain_coastal_sea_0",
		"water sprite ids are the §4.8.5 flat fills")


# --- §6.6 shore overlay ------------------------------------------------------

func _test_shore_overlay() -> void:
	var loader = MapLoaderLib.new()
	_check(loader.load_map("res://data/maps/world.png", DataLoader.map_legend),
		"the map loads for the shore decode (%s)" % loader.last_error)
	loader._ensure_shore_decode()
	_check(loader.shore_codes.size() == loader.width * loader.height,
		"the shore decode covers the whole locked grid")
	_check(loader.shore_code_at(LISBON_BERTH) == 3,
		"Lisbon's berth codes `e` (§6.6 index 3; the shore sits due east)")
	_check(loader.shore_code_at(OPEN_SEA) == 0,
		"open water carries no edge code")
	_check(loader.shore_code_at(Vector2i(-1, OPEN_SEA.y))
		== loader.shore_code_at(Vector2i(loader.width - 1, OPEN_SEA.y)),
		"shore lookups wrap on x")
	_check(loader.shore_code_at(Vector2i(5, -1)) == 0
		and loader.shore_code_at(Vector2i(5, loader.height)) == 0,
		"out-of-range y reads 0 (cosmetic, never an error)")
	for code in range(1, MapLoaderLib.SHORE_DIRS.size() + 1):
		_check(not MapLoaderLib.SHORE_DIRS[code - 1].is_empty(),
			"shore dir table covers code %d" % code)
	# The §6.6 invariant on a sampled strip: codes sit on WATER tiles only.
	var water_only := true
	for y in range(LISBON_BERTH.y - 4, LISBON_BERTH.y + 5):
		for x in range(LISBON_BERTH.x - 4, LISBON_BERTH.x + 5):
			if loader.shore_code_at(Vector2i(x, y)) > 0 \
					and not loader.is_passable_xy(x, y):
				water_only = false
	_check(water_only,
		"sampled strip: coded cells are water tiles only (§6.6)")


# --- §4.7.17 water layer ------------------------------------------------------

func _test_water_layer() -> void:
	var tile_set := WaterLayerLib.build_tile_set(32)
	_check(tile_set != null and tile_set.get_next_source_id() == 1,
		"the water TileSet carries exactly one atlas source")
	var source := tile_set.get_source(tile_set.get_source_id(0)) \
		as TileSetAtlasSource
	_check(source != null and source.get_tiles_count() == 2,
		"the water atlas carries the two flat fills (sea + coastal_sea)")
	var material := WaterLayerLib.build_material()
	_check(material != null, "the sea shader material builds")
	if material != null:
		_check(material.shader != null
			and material.shader.resource_path == WaterLayerLib.SHADER_PATH,
			"the material is the shared sea_water.gdshader")
		_check(is_equal_approx(float(material.get_shader_parameter(
			"u_period")), WaterLayerLib.SCROLL_PERIOD_MS / 1000.0),
			"the scroll period is the pinned 800 ms")
		_check(is_equal_approx(float(material.get_shader_parameter(
			"u_darken")), WaterLayerLib.SEA_DARKEN),
			"the darkening is the pinned ×0.82")
		# UiMotion is OFF in this suite (direct-boot): frozen at offset 0.
		_check(is_equal_approx(float(material.get_shader_parameter(
			"u_motion")), 0.0),
			"UiMotion off builds the layer frozen (u_motion 0)")
		UiMotionLib.enabled = true
		var running := WaterLayerLib.build_material()
		# The cache: the gate was applied at build time (motion off), so the
		# shared instance stays the frozen one until a consumer re-gates it.
		_check(running == material,
			"the material builds once per process (the S10/S3 shared seam)")
		UiMotionLib.enabled = false
	var layer := WaterLayerLib.build_layer(32)
	_check(layer != null and layer.tile_set != null,
		"build_layer returns a TileMapLayer with the water TileSet")
	_check(layer.material == material,
		"the built layer carries the shared material")
	# The kind mapping is data-driven off the loader legend.
	var loader = MapLoaderLib.new()
	loader.load_map("res://data/maps/world.png", DataLoader.map_legend)
	_check(WaterLayerLib.column_for_index(loader, 0) == 0,
		"index 0 maps to the sea column")
	_check(WaterLayerLib.column_for_index(loader, 1) == 1,
		"index 1 maps to the coastal_sea column")
	_check(WaterLayerLib.column_for_index(loader, 2) == -1,
		"land renders on the terrain layer, never on water")
	_check(WaterLayerLib.SEA_DARKEN == 0.82
		and WaterLayerLib.SCROLL_PERIOD_MS == 800,
		"the §4.7.17 pins stay on the shared builder")


# --- §4.8.6 heading8 → dir table ----------------------------------------------

func _test_dir_table() -> void:
	var expected: Array[String] = ["e", "ne", "n", "nw", "w", "sw", "s", "se"]
	_check(ArrowFieldLib.DIR_IDS == expected,
		"the dir ids follow the §4.8.6 bucket order (bucket 0 = east)")
	for bucket in expected.size():
		_check(ArrowFieldLib.dir_id_of_bucket(bucket) == expected[bucket],
			"bucket %d maps to `%s`" % [bucket, expected[bucket]])
	_check(ArrowFieldLib.dir_id_of_compass("E") == "e"
		and ArrowFieldLib.dir_id_of_compass("N") == "n"
		and ArrowFieldLib.dir_id_of_compass("SE") == "se",
		"compass tokens map through the same table")
	_check(ArrowFieldLib.dir_id_of_compass("VAR") == ""
		and ArrowFieldLib.dir_id_of_heading("X") == "",
		"outside the §4.4 domain the dir id is empty")
	_check(ArrowFieldLib.bucket_of_vector(Vector2(10, 0)) == 0,
		"(+x) buckets 0 (east)")
	_check(ArrowFieldLib.bucket_of_vector(Vector2(1, -4)) == 2,
		"(0,−y) buckets 2 (north, screen y-down)")
	_check(ArrowFieldLib.bucket_of_vector(Vector2(2, -2)) == 1,
		"(+x,−y) buckets 1 (NE)")
	_check(ArrowFieldLib.bucket_of_vector(Vector2(-2, 2)) == 5,
		"(−x,+y) buckets 5 (SW)")
	_check(ArrowFieldLib.bucket_of_vector(Vector2.ZERO) == -1,
		"the zero vector has no bucket (the caller keeps the last)")


# --- Arrow field vs a fixture decode -------------------------------------------

## A minimal deterministic `OceanLayers` stand-in: region A prevails W,
## region B is VAR; one eastward current of strength 2, one zero-strength.
class FixtureOcean:
	var decode_ok := true
	var currents_decoded := true
	var currents_ok := true

	func prevailing_for(_cell: Vector2i, _month: int) -> String:
		return "W" if _cell.x < 8 else "VAR"

	func current_vector_at(cell: Vector2i, _month: int) -> Vector2:
		return Vector2(2, 0) if cell.y == 0 else Vector2.ZERO


func _test_arrow_field_fixture() -> void:
	var ocean := FixtureOcean.new()
	var is_water := func(_cell: Vector2i) -> bool: return true
	var samples := ArrowFieldLib.sample(Vector2i(8, 4), Vector2i(16, 8), 4,
		ocean, is_water, 16, 8)
	_check(not samples.is_empty(), "the fixture samples a non-empty field")
	# Determinism: the same query twice, byte-identical.
	var again := ArrowFieldLib.sample(Vector2i(8, 4), Vector2i(16, 8), 4,
		ocean, is_water, 16, 8)
	_check(samples == again, "sampling is deterministic for a fixed decode")
	# The lattice is stride-4 world-anchored.
	var stride_ok := true
	for entry in samples:
		var cell: Vector2i = entry["cell"]
		if cell.x % ArrowFieldLib.STRIDE != 0 or cell.y % ArrowFieldLib.STRIDE != 0:
			stride_ok = false
	_check(stride_ok, "every sampled cell sits on the stride-4 lattice")
	# Wind entries: W west of x 8, VAR beyond; dirs follow the table.
	var winds := samples.filter(func(e: Dictionary) -> bool:
		return e["kind"] == "wind")
	var w_west := winds.filter(func(e: Dictionary) -> bool:
		return (e["cell"] as Vector2i).x < 8)
	var w_var := winds.filter(func(e: Dictionary) -> bool:
		return (e["cell"] as Vector2i).x >= 8)
	_check(not w_west.is_empty() and w_west.all(func(e: Dictionary) -> bool:
		return e["dir_id"] == "w" and not e["variable"]),
		"a `W` region samples the `w` dir id")
	_check(not w_var.is_empty() and w_var.all(func(e: Dictionary) -> bool:
		return e["variable"] and e["dir_id"] == ""),
		"a VAR region marks `variable` with no dir id")
	# Current entries: the eastward jet on row 0 buckets 0 (east), strength
	# rows without a vector sample nothing.
	var currents := samples.filter(func(e: Dictionary) -> bool:
		return e["kind"] == "current")
	_check(not currents.is_empty() and currents.all(func(e: Dictionary) -> bool:
		return (e["cell"] as Vector2i).y == 0 and e["dir_id"] == "e"),
		"the fixture jet buckets east; zero-vector rows sample no arrow")
	# Water-only: a false predicate yields an empty field.
	var dry := ArrowFieldLib.sample(Vector2i(8, 4), Vector2i(16, 8), 4,
		ocean, func(_cell: Vector2i) -> bool: return false, 16, 8)
	_check(dry.is_empty(), "land cells sample nothing (water cells only)")
	# Degenerate grids sample nothing (never crash).
	_check(ArrowFieldLib.sample(Vector2i(0, 0), Vector2i(16, 8), 4,
		ocean, is_water, 0, 8).is_empty(),
		"a zero-width grid samples empty")
	# Sorting: (y, x, kind) order — the deterministic draw source.
	var sorted_ok := true
	var prev_key := Vector3i(-1, -1, -1)
	for entry in samples:
		var cell: Vector2i = entry["cell"]
		var kind_rank := 0 if entry["kind"] == "current" else 1
		var key := Vector3i(cell.y, cell.x, kind_rank)
		if prev_key != Vector3i(-1, -1, -1) and key < prev_key:
			sorted_ok = false
		prev_key = key
	_check(sorted_ok, "samples sort by (y, x, kind) deterministically")


# --- Arrow field on the real world scene (W/C state machine) -------------------

func _test_arrow_field_world() -> void:
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	var map = DataLoader.map
	_check(not world.wind_field_on() and not world.current_field_on(),
		"W/C fields default OFF (§4.8.10, session-local)")
	_check(world.arrow_field_samples().is_empty(),
		"no samples before the first toggle")
	# --- The amended §4.8.10 key matrix (2026-11-04 adjudication) -----------
	# Both fields off: `C` is NOT consumed by the world — the §4.5 intel
	# window keeps its key (existing behavior; the window itself is W4-B's).
	_check(not _feed_field_key(world, KEY_C),
		"both fields off ⇒ `C` is not consumed (the intel window answers)")
	_check(not world.wind_field_on() and not world.current_field_on(),
		"the untouched `C` left both fields off")
	# `W` always toggles the wind field: on …
	world.toggle_wind_field()
	_check(world.wind_field_on() and not world.current_field_on(),
		"`W` turns the wind field on alone")
	var wind_samples: Array = world.arrow_field_samples()
	_check(not wind_samples.is_empty(),
		"the wind field sampled the visible window (%d cells)" % wind_samples.size())
	_check(world.arrow_field_month()
		== SailingSimLib.month_for(maxi(int(GameState.day), 1)),
		"the field samples the live calendar month")
	var stride_ok := true
	var water_ok := true
	for entry in wind_samples:
		var cell: Vector2i = entry["cell"]
		if cell.x % ArrowFieldLib.STRIDE != 0 or cell.y % ArrowFieldLib.STRIDE != 0:
			stride_ok = false
		if not map.is_passable(cell):
			water_ok = false
	_check(stride_ok, "world samples sit on the stride-4 lattice")
	_check(water_ok, "world samples are passable water cells only")
	var wind_ids := true
	for entry in wind_samples:
		if entry["variable"]:
			continue
		if ArrowFieldLib.DIR_IDS.find(str(entry["dir_id"])) < 0:
			wind_ids = false
	_check(wind_ids, "wind dir ids are §4.8.6 ids (or the VAR mark)")
	# … and the amended reachability: wind-only + `C` turns the CURRENT field
	# on (shadowed — consumed, no intel). The currents decode is forced first
	# (the one expensive decode; the world scene warms it on frame 1).
	var ocean = OceanLayersLib.instance()
	_check(ocean.decode_ok, "the wind raster decoded for the suite")
	if not ocean.currents_decoded:
		ocean.current_at(map.port_cell("lisbon"),
			SailingSimLib.month_for(GameState.day))
	_check(_feed_field_key(world, KEY_C),
		"wind-only ⇒ `C` is consumed (the intel `C` is shadowed)")
	_check(world.wind_field_on() and world.current_field_on(),
		"wind-on + `C` turns the current field ON (amended reachability)")
	_check(world.arrow_field_samples().size() >= wind_samples.size(),
		"the combined field carries at least the wind entries")
	# The current layer's entries are data-dependent (the Portuguese coast
	# window may own no current tiles): whenever the decode is healthy and
	# entries exist, their dir ids must be §4.8.6 ids; absence near Lisbon
	# is a NOTE, not a failure (the real current data is test_ocean's pin).
	var currents: Array = world.arrow_field_samples().filter(func(e: Dictionary) -> bool:
		return e["kind"] == "current")
	var current_ids := true
	for entry in currents:
		if ArrowFieldLib.DIR_IDS.find(str(entry["dir_id"])) < 0:
			current_ids = false
	_check(current_ids, "current dir ids are §4.8.6 ids")
	if currents.is_empty() and ocean.currents_ok:
		print("NOTE  the Lisbon window owns no current tiles (entries data-dependent)")
	# current-on + `C` ⇒ current off (wind unaffected); `C` again re-arms it.
	_check(_feed_field_key(world, KEY_C) and not world.current_field_on()
		and world.wind_field_on(),
		"current-on + `C` turns the current field OFF (wind stays on)")
	_check(_feed_field_key(world, KEY_C) and world.current_field_on(),
		"`C` re-arms the current field while the wind field runs")
	# `W` always toggles the wind field — even with the current field on.
	_check(_feed_field_key(world, KEY_W) and not world.wind_field_on()
		and world.current_field_on(),
		"`W` toggles the wind field off and never touches the current field")
	# wind-off + current-on + `C` ⇒ current off (both off again).
	_check(_feed_field_key(world, KEY_C) and not world.current_field_on()
		and not world.wind_field_on(),
		"current-on + `C` (wind off) returns to both-off")
	# And the round trip is stable: both-off `C` is the intel's again.
	_check(not _feed_field_key(world, KEY_C),
		"back at both-off, `C` is the intel window's key again")
	# Month rollover re-samples (§4.8.10): with a field on, crossing a month
	# boundary flips the sampled month on the next sample (any phase shift
	# past 30 days is guaranteed to cross one).
	world.toggle_wind_field()
	var month_before: int = world.arrow_field_month()
	GameState.day += 40
	_check(SailingSimLib.month_for(GameState.day) != month_before,
		"the shifted fixture day really crossed a month boundary")
	_check(_feed_field_key(world, KEY_W),
		"`W` re-toggles the wind field (and re-samples)")
	var drifted: int = world.arrow_field_month()
	_check(drifted != month_before,
		"a month rollover re-samples the field (sampled month %d)" % drifted)
	# The round trip closes: the re-toggle left wind off, one more `W` turns
	# it back on, the last one off — `W` always toggles, to both ends.
	_check(_feed_field_key(world, KEY_W) and world.wind_field_on(),
		"`W` turns the wind field back on (always-toggle)")
	_check(_feed_field_key(world, KEY_W) and not world.wind_field_on(),
		"`W` toggles the wind field off (final state both-off)")
	_check(not world.wind_field_on() and not world.current_field_on(),
		"the fixture leaves both fields off")
	GameState.day -= 40
	world.queue_free()


## Feeds one raw field key through the world's `_input`-stage handler and
## reports whether the world CONSUMED it (the consume is the intel shadow).
## The viewport's handled flag is per-pushed-event, so each feed first pushes
## a benign key (nothing on S3 listens to F13) to reset it deterministically.
func _feed_field_key(world, code: int) -> bool:
	var reset := InputEventKey.new()
	reset.physical_keycode = KEY_F13
	reset.pressed = true
	get_viewport().push_input(reset)
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	world._tick_arrow_field_input(event)
	var consumed := get_viewport().is_input_handled()
	return consumed


# --- World markers (§3) ---------------------------------------------------------

func _test_world_markers() -> void:
	var world = WorldScene.instantiate()
	world.route_to_port = false
	world.route_to_battle = false
	add_child(world)
	var map = DataLoader.map
	# The §6.6 decode rides the scene's frame-2 warm-up; the suite forces it
	# (the boot budget keeps it off the first frame — test_world_map's pin).
	world._loader.warm_shore_overlay()
	_check(map != null and map.shore_codes.size() > 0,
		"the world boot decoded the shore overlay")
	# The categories cover all 30 discoveries (§3 / A.4).
	var categories := {}
	for entry in DataLoader.discoveries_list:
		categories[str((entry as Dictionary).get("category", ""))] = true
	_check(categories.has("natural") and categories.has("ruins")
		and categories.has("relic") and categories.has("creature"),
		"the four discovery categories are all present in the data")
	# Discovered-only: none found ⇒ no marker nodes.
	GameState.new_game("portugal", false)
	GameState.discoveries_found.clear()
	world.sync_from_state()
	_check(world._discovery_nodes.is_empty(),
		"zero discovered sites ⇒ zero discovery markers")
	# One found discovery surfaces exactly one node at its tile.
	var discovery: Dictionary = DataLoader.discoveries_list[0]
	var discovery_id := str(discovery.get("id", ""))
	var category := str(discovery.get("category", ""))
	GameState.discoveries_found.append(discovery_id)
	world._sync_discovery_markers()
	_check(world._discovery_nodes.size() == 1,
		"one discovered site renders exactly one marker")
	var node: Control = world._discovery_nodes.get(discovery_id, null)
	_check(node != null, "the marker node exists for the found id")
	if node != null:
		var expected: Vector2 = Vector2(DiscoveryLib.position_of_entry(discovery)) \
			* float(map.tile_size_px)
		_check(node.position == expected,
			"the marker sits on the discovery's tile (§3 like port markers)")
		var sprite := node.get_child(0) as Control
		_check(sprite != null,
			"the marker carries its sprite (registry empty ⇒ fallback square)")
	_check(UiKitLib.icon_texture("marker_discovery_%s" % category) == null,
		"the registry is empty in suites (fallback path exercised)")
	# Undiscovered again ⇒ the marker disappears (discovered-only).
	GameState.discoveries_found.clear()
	world._sync_discovery_markers()
	_check(world._discovery_nodes.is_empty(),
		"clearing the found set removes the markers (undiscovered never renders)")
	# A second category resolves its own id form.
	for entry in DataLoader.discoveries_list:
		var cat := str((entry as Dictionary).get("category", ""))
		_check(["natural", "ruins", "relic", "creature"].has(cat)
			and not cat.is_empty(),
			"category `%s` resolves a marker_discovery_* id" % cat)
		if cat != "natural":
			break
	world.queue_free()


# --- Production texture path (populated registry) -------------------------------
## The production sea/terrain path. `title_screen` populates the W3 texture
## registry at boot, so every atlas blit resolves a registry texture — an
## imported CompressedTexture2D whose `get_image()` carries the SOURCE PNG's
## channel layout (the §4.8 art family ships palette-mode PNGs, which decode
## as FORMAT_RGB8, and other import presets can decode VRAM-compressed).
## `Image.blit_rect`/`blend_rect` need the canvas format exactly, so every
## registry image must pass through `WaterLayerLib._to_rgba8` (decompress when
## needed, then convert to RGBA8) before a blit — without it the blit errors
## per chunk spawn and the world renders as a grey void (the 2026-11-04
## production report). The earlier groups run with an EMPTY registry (the flat
## fallback), so this section re-builds the three atlases + the port marker
## decode with the registry POPULATED and pins real pixel content. Zero blit
## errors is implied by completion; the pixel pins are the pre-fix
## discriminator (a failed blit leaves the cells fully transparent).
##
## The suite reaches the shared guard through a late-bound shim (below), not a
## direct static reference: static calls are compile-checked, and a tree
## without the helper must still PARSE so the pre-fix red run fails on the
## pixel pins + the production blit errors, not on a missing-symbol parse
## error.
## The late-bound shim: an instance call resolves the script's static helper
## and, on a tree without it, fails at RUNTIME (null + a console error)
## instead of blocking the parse.
func _rgba8(img: Image) -> Image:
	var shim: RefCounted = WaterLayerLib.new()
	return shim.call("_to_rgba8", img)


func _test_populated_registry() -> void:
	TextureRegistryLib.ensure_registered()
	_check(TextureRegistryLib.registered_count > 0,
		"the texture registry populated (%d ids; 0 ⇒ run `godot --headless --import` first)"
		% TextureRegistryLib.registered_count)
	if TextureRegistryLib.registered_count == 0:
		return
	# The shared guard's contract: null passes through; an RGB8 image and a
	# compressed image both come out RGBA8.
	_check(_rgba8(null) == null,
		"the RGBA8 guard passes null through as null")
	var rgb := Image.create_empty(2, 2, false, Image.FORMAT_RGB8)
	_check(_rgba8(rgb) != null
		and rgb.get_format() == Image.FORMAT_RGBA8,
		"the RGBA8 guard converts an RGB8 image to RGBA8")
	var packed := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	if packed.compress(Image.COMPRESS_S3TC) == OK:
		_check(packed.is_compressed(),
			"the probe image compressed (the guard's decompress branch)")
		_check(_rgba8(packed) != null
			and not packed.is_compressed()
			and packed.get_format() == Image.FORMAT_RGBA8,
			"the RGBA8 guard decompresses a compressed image to RGBA8")
	else:
		print("NOTE  S3TC compression unavailable headless — the guard's decompress branch is covered only by the imported-texture path")
	# The reported production stack (build_layer → build_tile_set →
	# _kind_image): both water cells resolve registry art whose center pixel
	# is the locked §4.8.5 flat fill.
	var tile_set := WaterLayerLib.build_tile_set(32)
	var source := tile_set.get_source(tile_set.get_source_id(0)) \
		as TileSetAtlasSource
	var atlas := source.texture.get_image()
	_check(atlas.get_pixel(16, 16).is_equal_approx(PaletteLib.SEA),
		"populated registry: the sea cell's center pixel is Palette.SEA (%s)"
		% atlas.get_pixel(16, 16))
	_check(atlas.get_pixel(32 + 16, 16).is_equal_approx(PaletteLib.COAST_SEA),
		"populated registry: the coastal_sea cell's center pixel is Palette.COAST_SEA (%s)"
		% atlas.get_pixel(32 + 16, 16))
	# The terrain atlas (`_ensure_tile_set` → `_terrain_kind_image`): all four
	# land variants carry real terrain art — variants 0–2 the LAND fill,
	# variant 3 the LAND_HI highlight (§4.8 generated-terrain family).
	var loader = MapLoaderLib.new()
	_check(loader.load_map("res://data/maps/world.png", DataLoader.map_legend),
		"the world map loads for the populated atlas (%s)" % loader.last_error)
	loader._ensure_tile_set()
	var land: Dictionary = loader._terrain_cells.get(2, {})
	_check(not land.is_empty(), "the populated atlas resolves the land row")
	if not land.is_empty():
		var land_row := int(land["row"])
		var terrain_atlas := (loader._tile_set.get_source(
			loader._tile_set.get_source_id(0)) as TileSetAtlasSource
			).texture.get_image()
		for variant in int(land["variants"]):
			var cell := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
			cell.blit_rect(terrain_atlas,
				Rect2i(variant * 32, land_row * 32, 32, 32),
				Vector2i.ZERO)
			var opaque := false
			for py in 32:
				for px in 32:
					if cell.get_pixel(px, py).a > 0.0:
						opaque = true
						break
				if opaque:
					break
			_check(opaque,
				"populated registry: the land variant %d cell is non-empty"
				% variant)
			if variant <= 2:
				_check(cell.get_pixel(16, 16).is_equal_approx(PaletteLib.LAND),
					"populated registry: land variant %d center is Palette.LAND (%s)"
					% [variant, cell.get_pixel(16, 16)])
			else:
				_check(cell.get_pixel(16, 16).is_equal_approx(
					PaletteLib.LAND_HI),
					"populated registry: land variant 3 center is Palette.LAND_HI (%s)"
					% cell.get_pixel(16, 16))
	# The coast-foam water variants (the r3 continuous-coast model): with the
	# registry populated and the §6.6 dirs supplied, `build_tile_set` composes
	# the `shore_{dir}` strips INTO the water atlas (2 flat fills + 16
	# mask-variant cells = 34 columns), and `water_coords` picks them.
	var foam_set := WaterLayerLib.build_tile_set(32, MapLoaderLib.SHORE_DIRS)
	var foam_source := (foam_set.get_source(foam_set.get_source_id(0))
		as TileSetAtlasSource)
	_check(foam_source.get_tiles_count() == 2 + 16 * 2,
		"populated registry: the water atlas gains the 16 mask-variant cells (%d tiles)"
		% foam_source.get_tiles_count())
	var foam_atlas := foam_source.texture.get_image()
	# cell for the E-edge mask (2) on the coastal fill = column 2+2*2+1 = 7:
	# center stays the coastal fill (foam hugs the edges), the RIGHT edge
	# midpoint carries foam, the west midpoint stays fill.
	var e_cell := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	e_cell.blit_rect(foam_atlas, Rect2i(7 * 32, 0, 32, 32), Vector2i.ZERO)
	_check(e_cell.get_pixel(16, 16).is_equal_approx(PaletteLib.COAST_SEA),
		"populated registry: the coast-foam `e` cell keeps the coastal fill at center (%s)"
		% e_cell.get_pixel(16, 16))
	_check(not e_cell.get_pixel(30, 16).is_equal_approx(PaletteLib.COAST_SEA),
		"populated registry: the coast-foam `e` cell carries foam on its east edge")
	_check(e_cell.get_pixel(1, 16).is_equal_approx(PaletteLib.COAST_SEA),
		"populated registry: the coast-foam `e` cell leaves the west edge clear")
	_check(WaterLayerLib.water_coords(2, 1) == Vector2i(7, 0),
		"populated registry: water_coords(E mask, coastal) picks the foam column 7")
	_check(WaterLayerLib.water_coords(0, 0) == Vector2i(0, 0),
		"populated registry: water_coords(no edges, sea) picks the plain sea fill")
	_check(WaterLayerLib.water_coords(15, 0) == Vector2i(32, 0),
		"populated registry: water_coords(all edges, sea) picks the full-band variant")
	# The port marker: the overlay renders the registry texture DIRECTLY (a
	# TextureRect, no atlas blit) — pin that the marker texture decodes
	# non-empty through the same RGBA8 guard.
	var marker_texture := UiKitLib.icon_texture("terrain_port_neutral")
	_check(marker_texture != null,
		"populated registry: the neutral port marker id resolves")
	if marker_texture != null:
		var marker := _rgba8(marker_texture.get_image())
		var marks := false
		if marker != null:
			for py in marker.get_height():
				for px in marker.get_width():
					if marker.get_pixel(px, py).a > 0.0:
						marks = true
						break
				if marks:
					break
		_check(marks,
			"populated registry: the port marker texture decodes non-empty through the RGBA8 guard")


# --- Shore strip mapping + the animated-sea material (populated registry) -------
## The 2026-11-04 production defects, pinned: (1) the coast-foam variant
## mapping — with the registry populated and the §6.6 dirs supplied, the
## WATER atlas gains the foam variants (a strip baked into each kind fill)
## and `water_coords(code, kind_column)` picks variant column
## `2 + (code-1)*2 + kind` — an index shuffle stamps the WRONG strip — and
## every foam cell carries its strip's foam on the LAND-FACING edge
## (pixel-sampled: foam at the edge midpoint, clear at the opposite midpoint
## — the corner stubs at the ±0..2 rows/cols are deliberately not sampled);
## and `_shore_stamp_code`'s refinement — a diagonal raster code (2/4/6/8)
## yields to the first ORTHOGONAL direction whose neighbour is a blocker in
## the loader's own decode (a cape-step tile with land at ne AND e must
## stamp `e`, not the `ne` variant whose top band faces open water), while
## orthogonal codes, zero codes, pure-diagonal cells and the x wrap pass
## through unchanged. (2) the animated-sea material: `u_mask` bound to a
## valid ImageTexture (the 64×64 §4.8.8 pattern), `u_period` == 0.8,
## `u_darken` == 0.82, `u_motion` == 1.0 with UiMotion enabled / 0.0 frozen,
## and the shader source never re-samples TEXTURE (Godot 4's COLOR arrives
## already carrying the tile pixel — a re-sample multiplied the sea to SEA²,
## the "uniform dark water" production report).
func _test_shore_strips_and_material() -> void:
	TextureRegistryLib.ensure_registered()
	var loader = MapLoaderLib.new()
	_check(loader.load_map("res://data/maps/world.png", DataLoader.map_legend),
		"the world map loads for the shore-strip group (%s)" % loader.last_error)
	var tile_set := WaterLayerLib.build_tile_set(32, MapLoaderLib.SHORE_DIRS)
	var source := (tile_set.get_source(tile_set.get_source_id(0))
		as TileSetAtlasSource)
	# (1a) The mask→variant geometry: mask m on kind k lives at column
	# 2 + m*2 + k (no shuffle), and every foam cell carries foam exactly on
	# its set-edge midpoints (t = (16,1), b = (16,30), l = (1,16),
	# r = (30,16)); corner stubs (±0..2 rows/cols) are unsampled.
	var foam_edges := {
		1: ["t"], 2: ["r"], 4: ["b"], 8: ["l"],
		3: ["t", "r"], 6: ["b", "l"], 12: ["b", "r"], 15: ["t", "b", "l", "r"],
	}
	var midpoints := {"t": Vector2i(16, 1), "b": Vector2i(16, 30),
		"l": Vector2i(1, 16), "r": Vector2i(30, 16)}
	var atlas := source.texture.get_image()
	for mask: int in foam_edges:
		var want: Array = foam_edges[mask]
		for kind_index in 2:
			var column := 2 + mask * 2 + kind_index
			var coords := WaterLayerLib.water_coords(mask, kind_index)
			_check(coords == Vector2i(column, 0),
				"coast-foam mapping: water_coords(mask %d, kind %d) = column %d"
				% [mask, kind_index, column])
			# the cell's own kind fill — foam midpoints differ from it,
			# unset-edge midpoints equal it (the fill is opaque everywhere)
			var fill := PaletteLib.COAST_SEA if kind_index == 1 \
				else PaletteLib.SEA
			for edge in ["t", "b", "l", "r"]:
				var pos: Vector2i = midpoints[edge]
				var pixel := atlas.get_pixel(column * 32 + pos.x, pos.y)
				var is_foam := not pixel.is_equal_approx(fill)
				var should := ((1 << ["t", "r", "b", "l"].find(edge))
					& mask) != 0
				_check(is_foam == should,
					"coast-foam cell mask %d (kind %d, column %d): edge `%s` %s" % [
						mask, kind_index, column, edge,
						"carries the foam" if should else "is the fill"])
	# (1c) The foam-mask fixture: a synthetic legend decode, land at chosen
	# cells, every rule of `_shore_foam_mask` pinned directly.
	# Land (index 2 = `#`) at (1,2), (3,1), (5,3) and (3,3) in a 6×4 grid.
	var fixture = MapLoaderLib.new()
	fixture.width = 6
	fixture.height = 4
	fixture.legend_tiles = {
		"~": {"kind": "sea"}, ".": {"kind": "coastal_sea"},
		"#": {"kind": "land"}, "^": {"kind": "reef"},
		"I": {"kind": "polar_ice"},
	}
	var indices := PackedByteArray()
	indices.resize(6 * 4)
	for y in 4:
		for x in 6:
			indices[y * 6 + x] = 2 if Vector2i(x, y) in [
				Vector2i(1, 2), Vector2i(3, 1), Vector2i(5, 3),
				Vector2i(3, 3)] else 0
	fixture.indices = indices
	_check(fixture._shore_foam_mask(Vector2i(2, 1)) == 2,
		"foam mask: land EAST lights the east edge (bit 1)")
	_check(fixture._shore_foam_mask(Vector2i(1, 1)) == 4,
		"foam mask: land SOUTH lights the south edge (bit 2)")
	_check(fixture._shore_foam_mask(Vector2i(0, 3)) == 8,
		"foam mask: x wraps — land at x 5 blocks from the west (bit 3)")
	_check(fixture._shore_foam_mask(Vector2i(3, 2)) == 5,
		"foam mask: land north AND south light both edges (bits 0+2)")
	_check(fixture._shore_foam_mask(Vector2i(4, 2)) == 12,
		"foam mask: the SW+SE bridge lights the south edge AND NW+SW the west (bits 2+3)")
	_check(fixture._shore_foam_mask(Vector2i(2, 2)) == 10,
		"foam mask: the NE+SE inlet bridge lights the east edge (bit 1) + west land (bit 3)")
	_check(fixture._shore_foam_mask(Vector2i(4, 0)) == 0,
		"foam mask: the y-out-of-range probe counts as non-blocker (§6.6)")
	_check(fixture._shore_foam_mask(Vector2i(4, 3)) == 10,
		"foam mask: east and west land light both side edges (bits 1+3)")
	# (2) The animated-sea material: params + the motion gate both ways + the
	# shader-source tripwire for the SEA² double-multiply regression.
	WaterLayerLib._material_attempted = false
	WaterLayerLib._material_cache = null
	UiMotionLib.enabled = true
	var running := WaterLayerLib.build_material()
	_check(running != null, "the animated-sea material builds (motion on)")
	if running != null:
		_check(float(running.get_shader_parameter("u_motion")) == 1.0,
			"UiMotion on builds the shader with u_motion == 1.0")
	var mask: Texture2D = running.get_shader_parameter("u_mask") \
		if running != null else null
	_check(mask != null, "the material binds u_mask (a valid ImageTexture)")
	if mask != null:
		var mask_image := mask.get_image()
		_check(mask_image.get_size() == Vector2i(64, 64),
			"u_mask is the 64×64 §4.8.8 dither pattern")
	_check(running.get_shader_parameter("u_period") == 0.8,
		"u_period is the pinned 0.8 s")
	_check(running.get_shader_parameter("u_darken") == 0.82,
		"u_darken is the pinned ×0.82")
	var shader_code: String = running.shader.code if running != null else ""
	_check(not shader_code.contains("texture(TEXTURE"),
		"the sea shader never re-samples TEXTURE (COLOR already carries the tile pixel — a re-sample rendered the sea at SEA²)")
	_check(shader_code.contains("COLOR.rgb *= "),
		"the sea shader applies the two-level shade straight onto COLOR.rgb")
	WaterLayerLib._material_attempted = false
	WaterLayerLib._material_cache = null
	UiMotionLib.enabled = false
	var frozen := WaterLayerLib.build_material()
	_check(frozen != null
		and float(frozen.get_shader_parameter("u_motion")) == 0.0,
		"UiMotion off freezes the rebuilt shader at u_motion == 0.0")
