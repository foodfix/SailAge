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
##     material's pinned params (period 800 ms, darkening ×0.70, crest mix
##     0.70 toward FOAM) and the `UiMotion` gate (off ⇒ `u_motion` 0), the
##     S10 reuse seam;
##   * the §4.7.17 r5 sea mask + MOTION SELF-SIMILARITY fixtures (the pins
##     that would have caught r1–r4: no translational period in any
##     direction; frame A/B crest maps displaced in ≥30% of 8×8 blocks;
##     Hamming ≥ 0.02 — the retired stripe lattice scored 1.0 / 0% / 0);
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
##   * the r5 coast foam language + the DEFECT C stub fix: the 16 variant
##     cells' OPEN edges are foam-free across their FULL length (corner
##     stubs respect the mask — the 1-cell waterway white-ring regression),
##     and the synthetic coastline walk (staircase / pocket / channel) pins
##     speckle coverage on every land-adjacent tile with no floating foam.
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
	_test_sea_mask_and_motion()
	_test_dir_table()
	_test_arrow_field_fixture()
	_test_arrow_field_world()
	_test_world_markers()
	_test_populated_registry()
	_test_shore_continuity()
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
			"the darkening is the pinned ×0.70 (b674492)")
		# §4.7.17 r5: the crest accent params (FOAM tint + partial mix).
		var crest_color: Vector3 = material.get_shader_parameter(
			"u_crest_color")
		_check(crest_color.x > 0.85 and crest_color.y > 0.90
			and crest_color.z > 0.90,
			"the crest tint is the FOAM family (%s)" % str(crest_color))
		_check(is_equal_approx(float(material.get_shader_parameter(
			"u_crest_mix")), WaterLayerLib.CREST_MIX),
			("the crest mix is the pinned CREST_MIX %.2f (§4.7.17 r5 band "
				+ "0.6–0.75)") % WaterLayerLib.CREST_MIX)
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
	_check(WaterLayerLib.SEA_DARKEN == 0.70
		and WaterLayerLib.SCROLL_PERIOD_MS == 800,
		"the §4.7.17 pins stay on the shared builder")


# --- §4.7.17 r5 sea mask + the MOTION SELF-SIMILARITY fixtures -----------------
## The r5 acceptance core (2026-11-05). The r1–r4 diagonal-stripe mask was
## SELF-SIMILAR under translation — a perfect period-4 lattice whose every
## 8×8 block held exactly 16 field px at every phase — so the 800 ms scroll
## read as a static hatch no matter the contrast (the user saw no motion in
## four rounds while the pixel-delta metric passed 46.8%). These fixtures pin
## the HUMAN-VISIBLE properties instead:
##   * mask structure — 64×64, two levels, uniform row/column sums (the
##     builder's torus proxy, §4.8.2), organic dash clusters (max run ≤ 6),
##     NOT a uniform lattice (8×8 block occupancies vary), coverage 15–25%;
##   * NO translational period — translate-by-4 normalized correlation < 0.90
##     in ALL 8 directions (the stripe mask scored 1.0 at (0,±4));
##   * frame A/B at the REAL scroll (0.4 s = half the pinned period = a
##     32-texel shift along +x, same camera):
##       (i)  ≥ 30% of crest px change their local 8×8 block occupancy,
##       (ii) frame crest maps' Hamming distance ≥ 0.02,
##       (iii) covered by the 8-direction sweep above.
## The crest rule mirrored here is the shader's (sea_water.gdshader): a field
## texel whose 1-texel WEST neighbour is base is a crest texel.
func _test_sea_mask_and_motion() -> void:
	var material := WaterLayerLib.build_material()
	_check(material != null, "the r5 mask group builds the shared material")
	var mask_tex: Texture2D = material.get_shader_parameter("u_mask") \
		if material != null else null
	_check(mask_tex != null, "the mask group reads u_mask")
	if mask_tex == null:
		return
	var m: Image = mask_tex.get_image()
	_check(m.get_size() == Vector2i(64, 64),
		"the sea mask is the 64×64 §4.8.8 tile")
	var field: Array = []
	for y in 64:
		var row: Array = []
		for x in 64:
			row.append(1 if m.get_pixel(x, y).r >= 0.5 else 0)
		field.append(row)
	# structure: two levels, uniform sums (torus proxy), organic runs
	var colors := {}
	for y in 64:
		for x in 64:
			colors[m.get_pixel(x, y)] = true
	_check(colors.size() == 2,
		"the sea mask carries exactly the two mask levels (%d found)" % colors.size())
	var row_sums := {}
	var col_sums := {}
	var total := 0
	var max_run := 0
	for y in 64:
		var rs := 0
		var run := 0
		for x in 64:
			if field[y][x] == 1:
				rs += 1
				total += 1
				run += 1
				max_run = maxi(max_run, run)
			else:
				run = 0
			col_sums[x] = int(col_sums.get(x, 0)) + field[y][x]
		row_sums[y] = rs
	_check(row_sums.values().all(func(v: int) -> bool: return v == 13),
		"the torus proxy holds: every row carries exactly 13 field px (%s)"
		% str(row_sums.values()))
	_check(col_sums.values().all(func(v: int) -> bool: return v == 13),
		"the torus proxy holds: every column carries exactly 13 field px (%s)"
		% str(col_sums.values()))
	var coverage := total / 4096.0
	_check(coverage >= 0.15 and coverage <= 0.25,
		"the wave-crest field covers %.1f%% of the mask (r5 band 15–25%%)"
		% (coverage * 100.0))
	_check(max_run <= 6,
		("the field is organic dash clusters — longest run %d px (≤ 6; the " + "retired stripes were unbroken 64 px hatch lines)") % max_run)
	# NOT a uniform lattice: 8×8 block occupancies must VARY (the r1–r4
	# lattice held exactly 16 in every block at every phase — zero local
	# anchoring, which is why the scroll was invisible)
	var occupancies := {}
	for by in range(0, 64, 8):
		for bx in range(0, 64, 8):
			var s := 0
			for dy in 8:
				for dx in 8:
					s += field[by + dy][bx + dx]
			occupancies[s] = true
	_check(occupancies.size() >= 4,
		("8×8 block occupancies vary across the mask (%d distinct; the retired " + "lattice had exactly one — 16 everywhere)") % occupancies.size())
	# (iii) NO translational period: translate-by-4 in all 8 directions
	var dirs := [Vector2i(4, 0), Vector2i(-4, 0), Vector2i(0, 4),
		Vector2i(0, -4), Vector2i(4, 4), Vector2i(4, -4),
		Vector2i(-4, 4), Vector2i(-4, -4)]
	var max_corr := 0.0
	for d: Vector2i in dirs:
		var inter := 0
		for y in 64:
			for x in 64:
				if field[y][x] == 1 \
						and field[(y + d.y + 64) % 64][(x + d.x + 64) % 64] == 1:
					inter += 1
		max_corr = maxf(max_corr, inter / float(total))
	_check(max_corr < 0.90,
		("translate-by-4 max normalized correlation %.3f < 0.90 in all 8 " + "directions (the stripe mask scored 1.000 at (0,±4))") % max_corr)
	# --- frame A/B at the real scroll: 0.4 s = half of the pinned 800 ms
	# period = a 32-texel shift along +x (§4.7.17), same camera.
	var shift := Vector2i(32, 0)
	var field_b: Array = []
	for y in 64:
		var row: Array = []
		for x in 64:
			row.append(field[(y - shift.y + 64) % 64][(x - shift.x + 64) % 64])
		field_b.append(row)
	# the shader's crest rule, mirrored: field px with base water 1 OR 2
	# texels west (the 2px-thick leading edge — survives the zoom-out's
	# 2:1 halving at every sample phase)
	var crest_a: Array = []
	var crest_b: Array = []
	var crest_count := 0
	for y in 64:
		var ra: Array = []
		var rb: Array = []
		for x in 64:
			var w1a: int = field[y][(x - 1 + 64) % 64]
			var w2a: int = field[y][(x - 2 + 64) % 64]
			var w1b: int = field_b[y][(x - 1 + 64) % 64]
			var w2b: int = field_b[y][(x - 2 + 64) % 64]
			ra.append(field[y][x]
				if (w1a == 0 or (w1a == 1 and w2a == 0)) else 0)
			rb.append(field_b[y][x]
				if (w1b == 0 or (w1b == 1 and w2b == 0)) else 0)
			crest_count += ra[x]
		crest_a.append(ra)
		crest_b.append(rb)
	_check(crest_count >= 100,
		"the crest level is populated (%d crest px in frame A; density %.1f%%)"
		% [crest_count, 100.0 * crest_count / 4096.0])
	# (i) crest-pixel displacement: ≥ 30% change their 8×8 block occupancy
	var changed := 0
	var same := 0
	for y in 64:
		for x in 64:
			if crest_a[y][x] != 1:
				continue
			var occ_a := _block_occupancy(crest_a, x, y)
			var occ_b := _block_occupancy(crest_b, x, y)
			if occ_a != occ_b:
				changed += 1
			else:
				same += 1
	var displacement := changed / float(changed + same)
	_check(displacement >= 0.30,
		("MOTION (i): %.0f%% of crest px change 8×8 block occupancy between " + "frames (≥ 30%%; the retired lattice scored 0%%)") % (displacement * 100.0))
	# (ii) frame crest maps Hamming distance
	var hamming := 0
	for y in 64:
		for x in 64:
			if crest_a[y][x] != crest_b[y][x]:
				hamming += 1
	_check(hamming / 4096.0 >= 0.02,
		"MOTION (ii): frame crest maps Hamming %.3f ≥ 0.02 (%d px differ)"
		% [hamming / 4096.0, hamming])
	# --- WIDE-ZOOM (b804d25): the pattern must survive the §4.8 zoom-out's
	# 2:1 nearest halving. The retired stripes were 1px lines that die at the
	# wrong sample parity (measured amplitude 6.5 → 0.1, colors 260 → 2).
	# r5 constraints, pinned here against the SHIPPED mask:
	#   * every field run is 2–5 px (no 1px-only crests);
	#   * crest px exist on BOTH row parities of every 16×16 texel region —
	#     at any camera phase, some crest survives in every region;
	#   * the crest map at 0.5 keeps ≥ 20% of its 1:1 count at BOTH row
	#     phases (the geometric ceiling for a halving-proof pattern is 25%:
	#     each axis keeps 1 of 2 px of any feature that never dies — the
	#     r1–r4 stripes scored 0%);
	#   * halved crest density ≥ 2% (absolute visibility floor at wide zoom).
	var min_run := 64
	for y2 in 64:
		var segs: Array = []
		var x2 := 0
		while x2 < 64:
			if field[y2][x2] == 1:
				var rl := 0
				var x0 := x2
				while x2 < 64 and field[y2][x2] == 1:
					rl += 1
					x2 += 1
				segs.append([x0, rl])
			else:
				x2 += 1
		# torus merge: a run crossing the seam is one run
		if segs.size() > 1 and segs[0][0] == 0 \
				and segs[-1][0] + segs[-1][1] == 64:
			var last: Array = segs.pop_back()
			segs[0][1] += last[1]
		for seg: Array in segs:
			min_run = mini(min_run, seg[1])
	_check(min_run >= 2,
		("WIDE-ZOOM: no 1px field runs (shortest run %d px — 1px crests die "
			+ "at the wrong halving parity)") % min_run)
	var region_fails := 0
	for col_phase in 2:
		for row_phase in 2:
			for by in range(0, 64, 16):
				for bx in range(0, 64, 16):
					var cnt := 0
					for y in range(row_phase, 64, 2):
						if y < by or y >= by + 16:
							continue
						for x in range(col_phase, 64, 2):
							if x >= bx and x < bx + 16:
								cnt += crest_a[y][x]
					if cnt < 1:
						region_fails += 1
	_check(region_fails == 0,
		"WIDE-ZOOM: every 16×16 texel region keeps crest px at ALL 4 halving "
		+ "phases (%d empty region-phases)" % region_fails)
	var total_crest := 0
	var min_surv := 1.0
	for row_phase in 2:
		var half := 0
		for y in range(row_phase, 64, 2):
			for x in range(0, 64, 2):
				half += crest_a[y][x]
		min_surv = minf(min_surv, half / float(crest_count))
		total_crest = half
	_check(min_surv >= 0.20,
		"WIDE-ZOOM: the crest map at 0.5 keeps %.0f%% of its 1:1 count at "
		+ "BOTH row phases (≥ 20%%; ceiling 25%% — each axis keeps 1 of 2 px "
		+ "of any feature that never dies; the retired stripes scored 0%%)"
		% (min_surv * 100.0))
	_check(total_crest / 4096.0 >= 0.02,
		"WIDE-ZOOM: halved crest density %.1f%% ≥ 2%% (absolute visibility "
		+ "floor at the wide zoom)" % (100.0 * total_crest / 4096.0))
	print(("NOTE  r5 motion evidence: field coverage %.1f%%, crest density "
		+ "%.1f%%, translate-by-4 corr max %.3f, A/B crest hamming %.3f, "
		+ "A/B block displacement %.1f%%, halved crest survival %.1f%%")
		% [coverage * 100.0, 100.0 * crest_count / 4096.0, max_corr,
		hamming / 4096.0, displacement * 100.0, min_surv * 100.0])


## The crest px count in the 8×8 block centred on (x, y) (torus wrap) — the
## "local occupancy" the motion fixture (i) compares across frames.
func _block_occupancy(map: Array, x: int, y: int) -> int:
	var s := 0
	for dy in range(-4, 4):
		for dx in range(-4, 4):
			s += map[(y + dy + 64) % 64][(x + dx + 64) % 64]
	return s


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
		# The loader builds at its own render pin (64 px on the world path,
		# the §4.8 64-canvas amendment — the atlas cells carry the shipped
		# 64-canvas terrain art).
		var tile_px: int = loader.tile_size_px
		_check(tile_px == 64,
			"the terrain atlas builds at the 64 px world tile (got %d)" % tile_px)
		var terrain_atlas := (loader._tile_set.get_source(
			loader._tile_set.get_source_id(0)) as TileSetAtlasSource
			).texture.get_image()
		for variant in int(land["variants"]):
			var cell := Image.create_empty(tile_px, tile_px, false, Image.FORMAT_RGBA8)
			cell.blit_rect(terrain_atlas,
				Rect2i(variant * tile_px, land_row * tile_px, tile_px, tile_px),
				Vector2i.ZERO)
			var opaque := false
			for py in tile_px:
				for px in tile_px:
					if cell.get_pixel(px, py).a > 0.0:
						opaque = true
						break
				if opaque:
					break
			_check(opaque,
				"populated registry: the land variant %d cell is non-empty"
				% variant)
			if variant <= 2:
				_check(cell.get_pixel(tile_px / 2, tile_px / 2).is_equal_approx(PaletteLib.LAND),
					"populated registry: land variant %d center is Palette.LAND (%s)"
					% [variant, cell.get_pixel(tile_px / 2, tile_px / 2)])
			else:
				_check(cell.get_pixel(tile_px / 2, tile_px / 2).is_equal_approx(
					PaletteLib.LAND_HI),
					"populated registry: land variant 3 center is Palette.LAND_HI (%s)"
					% cell.get_pixel(tile_px / 2, tile_px / 2))
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
	# center stays the coastal fill (foam hugs the edges), the right edge's
	# band carries the r5 wash + speckles (on the COASTAL kind the wash IS
	# the fill, so the edge is pinned by its FOAM speckles), the west
	# midpoint stays fill.
	var e_cell := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	e_cell.blit_rect(foam_atlas, Rect2i(7 * 32, 0, 32, 32), Vector2i.ZERO)
	_check(e_cell.get_pixel(16, 16).is_equal_approx(PaletteLib.COAST_SEA),
		"populated registry: the coast-foam `e` cell keeps the coastal fill at center (%s)"
		% e_cell.get_pixel(16, 16))
	var e_speckles := 0
	for py in 32:
		for pxx in range(26, 32):
			if e_cell.get_pixel(pxx, py).is_equal_approx(PaletteLib.FOAM):
				e_speckles += 1
	_check(e_speckles > 0,
		("populated registry: the coast-foam `e` cell carries speckles on "
			+ "its east edge band (%d FOAM px)") % e_speckles)
	_check(e_cell.get_pixel(1, 16).is_equal_approx(PaletteLib.COAST_SEA),
		"populated registry: the coast-foam `e` cell leaves the west edge clear")
	_check(WaterLayerLib.water_coords(2, 1) == Vector2i(7, 0),
		"populated registry: water_coords(E mask, coastal) picks the foam column 7")
	_check(WaterLayerLib.water_coords(0, 0) == Vector2i(0, 0),
		"populated registry: water_coords(no edges, sea) picks the plain sea fill")
	_check(WaterLayerLib.water_coords(15, 0) == Vector2i(32, 0),
		"populated registry: water_coords(all edges, sea) picks the full-band variant")
	# (1b, sea_fix_r4 hard gate) The 16 foam variants at the SHIPPED 64
	# canvas, per-bit: each masked edge carries foam pixels in its outer
	# band, every UNMASKED edge band is foam-free, and every foam pixel
	# (opaque AND not the cell's own fill — the strips' coastal-tone band
	# reads as fill on the coastal kind, foam/tone alike sit only on masked
	# edges) lies inside the union of the masked edge bands. A misplaced
	# strip set, a bit-order shuffle or an over-wide band all go red here.
	var set64 := WaterLayerLib.build_tile_set(64, MapLoaderLib.SHORE_DIRS)
	var src64 := (set64.get_source(set64.get_source_id(0)) as TileSetAtlasSource)
	var atlas64 := src64.texture.get_image()
	var band := 16  # foam + tone live within the outer quarter-tile band
	for mask in 16:
		for kind_index in 2:
			var col := 2 + mask * 2 + kind_index
			var fill := PaletteLib.COAST_SEA if kind_index == 1 \
				else PaletteLib.SEA
			var is_foam := func(p: Color) -> bool:
				return p.a > 0.0 and not p.is_equal_approx(fill)
			# per-edge CORE band scan (the middle of each edge, corners
			# excluded): a masked edge carries foam in its core; an unmasked
			# edge's core is foam-free. Corner regions are excluded because
			# a masked edge's strip legitimately runs the full width — the
			# union scan below pins those pixels to masked bands anyway.
			var core_ranges := {
				0: [0, band, band, 64 - band],          # north core
				1: [band, 64 - band, 64 - band, 64],    # east core
				2: [64 - band, 64, band, 64 - band],    # south core
				3: [band, 64 - band, 0, band],          # west core
			}
			for edge in 4:
				var r: Array = core_ranges[edge]
				var count := 0
				for py in range(r[0], r[1]):
					for pxx in range(r[2], r[3]):
						if is_foam.call(atlas64.get_pixel(col * 64 + pxx, py)):
							count += 1
				var want := (mask & (1 << edge)) != 0
				_check((count > 0) == want,
					"64-canvas variant mask %d (kind %d, column %d): %s edge %s (%d foam px)"
					% [mask, kind_index, col,
					["north", "east", "south", "west"][edge],
					"carries the foam" if want else "is foam-free", count])
			# union scan: every foam pixel sits inside the masked bands
			var outside := false
			for py in 64:
				for pxx in 64:
					if not is_foam.call(atlas64.get_pixel(col * 64 + pxx, py)):
						continue
					var in_n := py < band and (mask & 1) != 0
					var in_s := py >= 64 - band and (mask & 4) != 0
					var in_w := pxx < band and (mask & 8) != 0
					var in_e := pxx >= 64 - band and (mask & 2) != 0
					if not (in_n or in_s or in_w or in_e):
						outside = true
						break
				if outside:
					break
			_check(not outside,
				"64-canvas variant mask %d (kind %d): all foam pixels sit in the masked edge bands"
				% [mask, kind_index])
			# (r5 DEFECT C hard gate) OPEN edges are foam-free across their
			# FULL length INCLUDING both corner cells — the r4 assertion only
			# covered the core band, and the corner stubs visually closed
			# 1-cell waterways into a 4th white line. Foam px are the
			# FOAM-colored speckles/dust; the COAST_SEA shallow wash is the
			# r5 continuous coast element and deliberately keeps running.
			for edge in 4:
				if (mask & (1 << edge)) != 0:
					continue
				var bands := [Rect2i(0, 0, 64, 12),
					Rect2i(52, 0, 12, 64),
					Rect2i(0, 52, 64, 12),
					Rect2i(0, 0, 12, 64)]
				var r: Rect2i = bands[edge]
				var stray := 0
				for py in range(r.position.y, r.end.y):
					for pxx in range(r.position.x, r.end.x):
						if atlas64.get_pixel(col * 64 + pxx, py) \
								.is_equal_approx(PaletteLib.FOAM):
							stray += 1
				_check(stray == 0,
					"64-canvas variant mask %d (kind %d): the OPEN %s edge is " + "foam-free across its full length incl. corners (%d stray)"
					% [mask, kind_index,
					["north", "east", "south", "west"][edge], stray])
			# (r5 DEFECT C, the reported case) mask 11 = land N/E/S, open W:
			# the westmost 8 px column must carry zero foam px — the channel
			# (r5 DEFECT C, the reported case) land N/E/S with an open west
			# edge is mask 7 in the §6.6 bit order (N=1, E=2, S=4, W=8; the
			# r5 brief's "mask 11" label predates the bit map — mask 11 is
			# N/E/W, open S, gated below as well): the westmost 8 px column
			# must carry zero foam px — the channel mouth stays visibly OPEN.
			if mask == 7:
				var stray_w := 0
				for py in 64:
					for pxx in 8:
						if atlas64.get_pixel(col * 64 + pxx, py) \
								.is_equal_approx(PaletteLib.FOAM):
							stray_w += 1
				_check(stray_w == 0,
					("64-canvas variant mask 7 (kind %d) — land N/E/S, open W "
						+ "(the reported 1-cell waterway): the westmost 8 px "
						+ "column carries zero foam px (%d stray — the white "
						+ "ring the user reported)") % [kind_index, stray_w])
			if mask == 11:
				var stray_s := 0
				for py in range(56, 64):
					for pxx in 64:
						if atlas64.get_pixel(col * 64 + pxx, py) \
								.is_equal_approx(PaletteLib.FOAM):
							stray_s += 1
				_check(stray_s == 0,
					("64-canvas variant mask 11 (kind %d) — land N/E/W, open "
						+ "S: the southmost 8 px row carries zero foam px "
						+ "(%d stray)") % [kind_index, stray_s])
			# the interior stays the cell's own fill (foam hugs edges only)
			_check(atlas64.get_pixel(col * 64 + 32, 32)
				.is_equal_approx(fill),
				"64-canvas variant mask %d (kind %d): the interior keeps the fill"
				% [mask, kind_index])
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


# --- r5 coast foam language: continuity walk + strip structure ------------------
## The r5 foam language (59d6ec1, 2026-11-05) replaced the uniform white
## outline line (failed user acceptance x3) with a COAST_SEA shallow wash +
## hand-authored FOAM speckle clusters. Pinned here:
##   * the wash is the CONTINUOUS element: every orthogonal strip keeps a
##     solid COAST_SEA core hugging the land edge, 12 px deep (64 canvas,
##     the shared §4.8 thickness), running the strip's FULL length;
##   * speckles are clusters, not a line: FOAM < 50% of each strip's opaque
##     px, and the retired line scored ~100% of its band;
##   * SYNTHETIC COASTLINE WALK (staircase / pocket / 1-cell channel): every
##     land-adjacent water tile's masked-edge band carries speckle coverage
##     in the SHIPPED atlas (no consecutive uncovered tiles — the coast path
##     never goes dark), the channel mouth stays open (mask 11/5 west ends
##     foam-free), and water tiles off the coast stamp no foam at all.
func _test_shore_continuity() -> void:
	TextureRegistryLib.ensure_registered()
	# --- strip structure (the wash language, not a line) --------------------
	var strips := {}
	for dir_id in ["n", "e", "s", "w"]:
		var tex := UiKitLib.icon_texture("shore_%s" % dir_id)
		_check(tex != null, "the r5 shore strip `%s` resolves" % dir_id)
		if tex == null:
			return
		strips[dir_id] = _rgba8(tex.get_image())
	var depths := {}
	for dir_id in strips:
		var img: Image = strips[dir_id]
		var opaque := 0
		var foam := 0
		var wash := 0
		var min_v := 64
		var max_v := -1
		for y in 64:
			for x in 64:
				var p := img.get_pixel(x, y)
				if p.a <= 0.0:
					continue
				opaque += 1
				var depth := y if dir_id == "n" else (
					63 - y if dir_id == "s" else (63 - x if dir_id == "e" else x))
				min_v = mini(min_v, depth)
				max_v = maxi(max_v, depth)
				if p.is_equal_approx(PaletteLib.FOAM):
					foam += 1
				elif p.is_equal_approx(PaletteLib.COAST_SEA):
					wash += 1
		depths[dir_id] = max_v - min_v + 1
		_check(opaque > 0, "the `%s` strip carries art" % dir_id)
		_check(depths[dir_id] == 12,
			"the `%s` wash band is the shared 12 px depth (got %d)"
			% [dir_id, depths[dir_id]])
		_check(wash > foam and foam / float(opaque) < 0.5,
			"the `%s` strip reads wash + speckles, not a line (%d wash px vs " + "%d foam px — the retired line was foam-dominant)"
			% [dir_id, wash, foam])
	_check(depths.values().all(func(v: int) -> bool: return v == 12),
		"all four orthogonal strips share the 12 px band depth (§4.8)")
	# the wash CORE hugs the land edge: the depth 4..9 slice is wash-dominant
	# (solid shallow water, speckles only accented on top)
	for dir_id in strips:
		var img: Image = strips[dir_id]
		var slice_opaque := 0
		var slice_wash := 0
		for y in 64:
			for x in 64:
				if x < 8 or x >= 56:
					continue
				var p := img.get_pixel(x, y)
				if p.a <= 0.0:
					continue
				var depth := y if dir_id == "n" else (
					63 - y if dir_id == "s" else (63 - x if dir_id == "e" else x))
				if depth < 4 or depth >= 10:
					continue
				slice_opaque += 1
				if p.is_equal_approx(PaletteLib.COAST_SEA):
					slice_wash += 1
		_check(slice_opaque > 0
			and slice_wash / float(slice_opaque) >= 0.6,
			("the `%s` wash core hugs the land edge (COAST_SEA %d/%d px in the " + "depth 4..9 slice)") % [dir_id, slice_wash, slice_opaque])
	# --- the synthetic coastline walk ---------------------------------------
	var atlas64 := WaterLayerLib.build_tile_set(64, MapLoaderLib.SHORE_DIRS)
	var src64 := (atlas64.get_source(atlas64.get_source_id(0))
		as TileSetAtlasSource)
	var coast := src64.texture.get_image()
	# cell pixel probe: FOAM px count of one edge band of a variant cell.
	# The band is the 12 px stub zone (STUB_ZONE_PX) — exactly the strip
	# art's territory; a wider sweep would count the NEIGHBOURING masked
	# edge's legitimate clusters as mouth foam.
	var band_foam := func(mask: int, edge: int) -> int:
		var kind_col := 0  # the sea kind (kind_index 0)
		var column := 2 + mask * 2 + kind_col
		var bands := [Rect2i(0, 0, 64, 12), Rect2i(52, 0, 12, 64),
			Rect2i(0, 52, 64, 12), Rect2i(0, 0, 12, 64)]
		var r: Rect2i = bands[edge]
		var count := 0
		for py in range(r.position.y, r.end.y):
			for pxx in range(r.position.x, r.end.x):
				if coast.get_pixel(column * 64 + pxx, py) \
						.is_equal_approx(PaletteLib.FOAM):
					count += 1
		return count
	# staircase: land tiles step down eastward; the water tiles along the
	# path must each carry speckles on EVERY masked edge (no dark tiles).
	var fixture = MapLoaderLib.new()
	fixture.width = 8
	fixture.height = 6
	fixture.legend_tiles = {
		"~": {"kind": "sea"}, ".": {"kind": "coastal_sea"},
		"#": {"kind": "land"}, "^": {"kind": "reef"},
		"I": {"kind": "polar_ice"},
	}
	var stairs := [Vector2i(2, 1), Vector2i(3, 1), Vector2i(3, 2),
		Vector2i(4, 2), Vector2i(4, 3), Vector2i(5, 3)]
	var indices := PackedByteArray()
	indices.resize(8 * 6)
	for y in 6:
		for x in 8:
			indices[y * 8 + x] = 2 if Vector2i(x, y) in stairs else 0
	fixture.indices = indices
	var walk := [Vector2i(2, 2), Vector2i(3, 3), Vector2i(4, 4), Vector2i(5, 4),
		Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 1)]  # S/N/W-adjacent path
	var covered := 0
	for cell: Vector2i in walk:
		var mask := fixture._shore_foam_mask(cell)
		_check(mask != 0,
			"staircase walk: the land-adjacent tile %s resolves its foam mask"
			% str(cell))
		if mask == 0:
			continue
		var all_edges_lit := true
		for edge in 4:
			if (mask & (1 << edge)) == 0:
				continue
			if band_foam.call(mask, edge) == 0:
				all_edges_lit = false
		if all_edges_lit:
			covered += 1
	_check(covered == walk.size(),
		"continuity: every walked coast tile carries speckles on each masked " + "edge (%d/%d — no consecutive uncovered tiles, no floating segments)"
		% [covered, walk.size()])
	# off-coast water stamps NO foam: a tile with land 2 cells away resolves
	# mask 0 and the plain fill column.
	_check(fixture._shore_foam_mask(Vector2i(2, 4)) == 0,
		"off-coast water resolves mask 0 (foam never floats off the coast)")
	# pocket + 1-cell-channel variants, probed straight on the shipped atlas
	# (the per-bit group gates all 16 exhaustively; these pin the reported
	# user cases by edge — §6.6 bits: N=1, E=2, S=4, W=8): mask 7 = land
	# N/E/S, open W — the open west mouth stays foam-free, the three land
	# edges keep speckles (the brief's "mask 11" label = land N/E/W, open
	# S — asserted too). Mask 5 = land N+S (a 1-cell channel), open ends
	# E/W — both mouths foam-free, both banks speckled.
	_check(band_foam.call(7, 3) == 0,
		"the mask-7 pocket (land N/E/S) keeps its open WEST mouth foam-free")
	_check(band_foam.call(7, 0) > 0 and band_foam.call(7, 1) > 0
		and band_foam.call(7, 2) > 0,
		"the mask-7 pocket keeps speckles on all three land edges")
	_check(band_foam.call(11, 2) == 0,
		"the mask-11 pocket (land N/E/W) keeps its open SOUTH mouth foam-free")
	_check(band_foam.call(5, 1) == 0 and band_foam.call(5, 3) == 0,
		"the mask-5 channel (land N+S) keeps BOTH mouths foam-free")
	_check(band_foam.call(5, 0) > 0 and band_foam.call(5, 2) > 0,
		"the mask-5 channel carries speckles on both banks")


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
## `u_darken` == 0.70 (b674492), `u_motion` == 1.0 with UiMotion enabled / 0.0 frozen,
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
			# unset-edge midpoints equal it (the fill is opaque everywhere).
			# r5 foam language: the masked edge carries the COAST_SEA wash
			# + FOAM speckles. On the SEA kind the wash differs from the
			# fill, so the midpoint read holds for both tones; on the
			# COASTAL kind the wash IS the fill, so the masked edge is
			# pinned by its speckle coverage instead (FOAM px in the edge's
			# half band).
			var fill := PaletteLib.COAST_SEA if kind_index == 1 \
				else PaletteLib.SEA
			for edge in ["t", "b", "l", "r"]:
				var pos: Vector2i = midpoints[edge]
				var pixel := atlas.get_pixel(column * 32 + pos.x, pos.y)
				var should := ((1 << ["t", "r", "b", "l"].find(edge))
					& mask) != 0
				if kind_index == 0:
					var is_foam := not pixel.is_equal_approx(fill)
					_check(is_foam == should,
						"coast-foam cell mask %d (kind %d, column %d): edge `%s` %s" % [
							mask, kind_index, column, edge,
							"carries the foam" if should else "is the fill"])
				else:
					# the edge's 6 px band (32 scale — the stub zone)
					var half := Rect2i(0, 0, 32, 6) if edge == "t" \
						else (Rect2i(0, 26, 32, 6) if edge == "b" \
						else (Rect2i(26, 0, 6, 32) if edge == "r" \
						else Rect2i(0, 0, 6, 32)))
					var marks := 0
					for py in range(half.position.y, half.end.y):
						for pxx in range(half.position.x, half.end.x):
							if atlas.get_pixel(column * 32 + pxx, py) \
									.is_equal_approx(PaletteLib.FOAM):
								marks += 1
					if should:
						_check(marks > 0,
							("coast-foam cell mask %d (kind %d, column %d): edge `%s` " + "carries speckle clusters (%d FOAM px)") % [
								mask, kind_index, column, edge, marks])
					else:
						_check(marks == 0 and pixel.is_equal_approx(fill),
							("coast-foam cell mask %d (kind %d, column %d): edge `%s` " + "is the fill, speckles respect the mask") % [
								mask, kind_index, column, edge])
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
	# (sea_fix_r4 hard gate) The bay-mouth geometry from the user report: a
	# water cell with land N/E/W, open sea S, land on BOTH mouth diagonals
	# (SW+SE) — the sea-facing south edge must stay foam-FREE (the old
	# bridge closed the waterway into a white line), while the three true
	# land edges foam.
	var bay = MapLoaderLib.new()
	bay.width = 5
	bay.height = 5
	bay.legend_tiles = fixture.legend_tiles
	var bay_indices := PackedByteArray()
	bay_indices.resize(5 * 5)
	for y in 5:
		for x in 5:
			bay_indices[y * 5 + x] = 0
	# land ring: the immediate N/E/W neighbours + both mouth diagonals
	# (SW/SE) below the cell — open waterway south.
	for land in [Vector2i(2, 1), Vector2i(3, 2), Vector2i(1, 2),
			Vector2i(1, 3), Vector2i(3, 3)]:
		bay_indices[land.y * 5 + land.x] = 2
	bay.indices = bay_indices
	# the bay cell (2,2): land N/E/W, SW+SE land, open S.
	var bay_mask := bay._shore_foam_mask(Vector2i(2, 2))
	_check(bay_mask == 11,
		"foam mask: the 3-land-side bay (N/E/W land, open S, land mouth "
		+ "diagonals) foams exactly the three land edges (got %d, want 11)"
		% bay_mask)
	_check((bay_mask & 4) == 0,
		"foam mask: the bay mouth's sea-facing edge stays foam-free (the "
		+ "narrowed bridge never lights an edge whose perpendicular flank is land)")
	# the pure corner connector still bridges: land only at two diagonals of
	# one edge, all four orthogonals water — the r3 connector case survives.
	var channel = MapLoaderLib.new()
	channel.width = 4
	channel.height = 4
	channel.legend_tiles = fixture.legend_tiles
	var ch_indices := PackedByteArray()
	ch_indices.resize(4 * 4)
	for y in 4:
		for x in 4:
			ch_indices[y * 4 + x] = 0
	ch_indices[0 * 4 + 1] = 2  # NW of cell (2,1)
	ch_indices[0 * 4 + 3] = 2  # NE of cell (2,1)
	channel.indices = ch_indices
	_check(channel._shore_foam_mask(Vector2i(2, 1)) == 1,
		"foam mask: the NW+NE connector across all-water flanks still bridges the north edge")
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
	_check(running.get_shader_parameter("u_darken") == 0.70,
		"u_darken is the pinned ×0.70 (b674492)")
	# §4.8 64-canvas amendment (1664ba9): the mask param is the WORLD-space
	# tile — 128 px at the 64 px world tile, keeping the ~2-tile dither
	# period (the 64×64 texture itself is unchanged, §4.8.8).
	_check(is_equal_approx(float(running.get_shader_parameter("u_mask_px")),
		WaterLayerLib.MASK_SIZE_PX) and WaterLayerLib.MASK_SIZE_PX == 128.0,
		"u_mask_px is the 128 px world-space tile (64-canvas amendment)")
	var shader_code: String = running.shader.code if running != null else ""
	_check(not shader_code.contains("texture(TEXTURE"),
		"the sea shader never re-samples TEXTURE (COLOR already carries the tile pixel — a re-sample rendered the sea at SEA²)")
	_check(shader_code.contains("COLOR.rgb *= "),
		"the sea shader applies the two-level shade straight onto COLOR.rgb")
	_check(shader_code.contains("u_crest_mix"),
		"the sea shader carries the r5 crest level (mix toward FOAM on the cluster's leading edge)")
	WaterLayerLib._material_attempted = false
	WaterLayerLib._material_cache = null
	UiMotionLib.enabled = false
	var frozen := WaterLayerLib.build_material()
	_check(frozen != null
		and float(frozen.get_shader_parameter("u_motion")) == 0.0,
		"UiMotion off freezes the rebuilt shader at u_motion == 0.0")
