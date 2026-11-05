class_name WaterLayer
extends RefCounted
## The shared animated-sea water layer builder (docs/80-UI-UX.md §4.7.17,
## docs/90-ARCHITECTURE.md §9.2; IMPLEMENT-Phase10.md §3 — master
## adjudication: the ONE builder both S3's world water and S10's battle water
## go through, so the two views cannot drift).
##
## A water layer is a `TileMapLayer` whose cells are the two FLAT water fills
## (`terrain_sea_0` / `terrain_coastal_sea_0`, §4.8.5) carrying a
## `ShaderMaterial` built from `sea_water.gdshader`. The shader scrolls the
## dither mask on the GPU (§4.7.17: period 800 ms, darkening ×0.70, motion
## gate `u_motion` from `UiMotion`) — once the cells are stamped there is no
## per-frame CPU and no cell swapping; camera movement re-stamps cells at the
## existing chunk cadence exactly like the terrain chunks do.
##
## Consumers:
##   * `scripts/world/map_loader.gd` — one water layer per 128×128 chunk
##     (`build_layer`), cells stamped in the same pass that fills the terrain
##     layer (the fused loop shares the water-column map).
##   * S10 `battle_screen.gd` (W5-A) — `build_layer` + `fill_chunk` over the
##     battle grid, sharing `build_material`'s one cached material.
##
## Registry contract: the flat tiles resolve through the W3 texture registry
## (`UiKit.icon_texture("terrain_sea_0")` / `terrain_coastal_sea_0`); an
## absent id falls back to the locked palette fill (§4.9 "an absent id ⇒
## flat fallback, no crash"). The mask texture loads through the DATA-ARTIFACT
## pattern (raw bytes + `load_png_from_buffer`, the `world.png` contract) and
## the shader through a plain load — with either missing the layer renders
## the flat fills with NO material (exactly the pre-Phase-10 look), never an
## error.

const UiKitLib := preload("res://scripts/ui_kit.gd")
const UiMotionLib := preload("res://scripts/ui_motion.gd")
const PaletteLib := preload("res://scripts/palette.gd")

## The shader + mask this builder assembles (§4.7.17 "Scroll driver").
const SHADER_PATH := "res://scripts/world/sea_water.gdshader"
const MASK_PATH := "res://assets/ui/terrain/sea_pattern.png"

## §4.7.17 pinned numbers. The darkening is the amended ×0.70 (b674492,
## user report: ×0.82's ΔRGB ≈ 4–20 units is imperceptible in real gameplay —
## the two-level tones must read as clearly different water).
const SCROLL_PERIOD_MS := 800
const SEA_DARKEN := 0.70
## §4.7.17 r5 (2026-11-05) crest accent: the partial mix toward FOAM (the r5
## band is 0.6–0.75; 0.70 pinned here and mirrored in sea_water.gdshader's
## u_crest_mix default — the two sites must not drift). The crest color is
## PaletteLib.FOAM (terrain block) — passed to the shader as a param.
const CREST_MIX := 0.70
## §4.8.8: the mask is a 64×64 tile (the texture's own size — unchanged).
## The shader param is the mask's WORLD-space tile: 128 px since the §4.8
## 64-canvas amendment (1664ba9) — at the 64 px world tile the dither keeps
## its ~2-tile world period (each 64-texel mask texel now spans 2 world px).
const MASK_SIZE_PX := 128.0

## DEFECT C fix (r5, 2026-11-05): a strip's CORNER STUB — its content within
## this many 64-canvas px of a PERPENDICULAR tile edge — joins the composed
## variant only when that perpendicular edge is ALSO masked. The value is the
## shared foam band depth (§4.8: "the foam thickness shared with the corner
## tiles"): the stub zone is exactly the territory the perpendicular strip's
## own band would occupy, so an open edge shows no foam there and the variant
## reads genuinely open (the 1-cell waterway report: stubs used to close it
## into a 4th white line). FOAM-only trim: the COAST_SEA shallow wash keeps
## running the full edge (it IS the continuous coast read — r5 foam
## language, 59d6ec1); the white speckles/dust respect the mask.
const STUB_ZONE_PX := 12

## Atlas column of each water kind in the built TileSet (the §6.3 index
## order: 0 = `~` sea, 1 = `.` coastal sea). Coast-foam variant cells follow
## from column 2 (see [method build_tile_set]).
const KIND_COLUMNS := {"sea": 0, "coastal_sea": 1}

## The registry id prefix of the §6.6/A.6 foam strips (`shore_{dir}`), baked
## into the coast-foam water variants at tile-set build time.
const STRIP_ID_PREFIX := "shore_"

## The coast-foam readiness of the LAST `build_tile_set` call, per tile px
## (all 8 strips present ⇒ true). The stamp side reads the flag for its OWN
## tile px — never a last-build-wins global (the S10 open-sea grid builds
## its 32 px set without dirs; a global flag would flip the world's 64 px
## foam off under it — the cache made that ordering hazard real).
static var foam_ready := false
static var _foam_ready_by_px: Dictionary = {}


## The sprite id of a water kind (`terrain_{kind}_0`, A.5 "flat fills").
static func sprite_id(kind: String) -> String:
	return "terrain_%s_0" % kind


## The flat fallback color of a water kind (the locked §4.8 terrain block).
static func fallback_color(kind: String) -> Color:
	return PaletteLib.SEA if kind == "sea" else PaletteLib.COAST_SEA


## Production-format guard for registry-sourced images (the 2026-11-04 grey-
## void fix): `UiKit.icon_texture` textures are imported CompressedTexture2Ds
## whose `get_image()` carries the SOURCE PNG's channel layout — the §4.8 art
## family ships palette-mode PNGs, which decode as FORMAT_RGB8, and other
## import presets can decode VRAM-compressed. `Image.blit_rect`/`blend_rect`
## require the destination canvas format exactly (FORMAT_RGBA8 for every
## composed atlas in S3/S10), so every registry image passes through here
## before a blit: decompress when needed, then convert. Returns `null` for
## null input or a failed decompress (the caller keeps the flat fallback,
## §4.9). Shared by `map_loader.gd`'s terrain + shore atlases through its
## existing preload of this script, so the two atlas builders cannot drift.
static func _to_rgba8(img: Image) -> Image:
	if img == null:
		return null
	if img.is_compressed() and img.decompress() != OK:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


## One flat fill for the atlas at `tile_px`: the registry texture's pixels
## when the id resolves, else the palette fill (the pre-Phase-10 look).
static func _kind_image(kind: String, tile_px: int) -> Image:
	var image := Image.create_empty(tile_px, tile_px, false, Image.FORMAT_RGBA8)
	var texture := UiKitLib.icon_texture(sprite_id(kind))
	if texture != null:
		var pixels := _to_rgba8(texture.get_image())
		if pixels != null:
			image.blit_rect(pixels, Rect2i(0, 0, tile_px, tile_px),
				Vector2i.ZERO)
			return image
	image.fill(fallback_color(kind))
	return image


## The water TileSet: one atlas source, the two flat tiles per water kind at
## columns `KIND_COLUMNS[kind]`, then — when `shore_dirs` is supplied AND all
## 8 `shore_{dir}` strips resolve in the registry — the 16 COAST-FOAM
## VARIANTS (the r3 "continuous coast" model): variant column
## `2 + mask * 2 + kind` (mask bits 0..3 = N/E/S/W foam edge) composes the
## tile's own kind fill with the union of the land-facing edge strips
## alpha-blended over it, so the foam renders as light bands CONNECTED
## across staircase steps and narrow inlets — the §6.6 single-code edge
## lines this replaces read as scattered T/L/+ fragments on jagged coasts.
## Without the dirs (the S10 open-sea grid) or without the strips (registry
## empty, §4.9) the atlas stays exactly the two flat fills.
static func build_tile_set(tile_px: int, shore_dirs: Array = []) -> TileSet:
	var kinds: Array = KIND_COLUMNS.keys()
	kinds.sort_custom(func(a: String, b: String) -> bool:
		return int(KIND_COLUMNS[a]) < int(KIND_COLUMNS[b]))
	var columns := 2 + 16 * 2
	var image := Image.create_empty(columns * tile_px, tile_px, false,
		Image.FORMAT_RGBA8)
	for kind in kinds:
		image.blit_rect(_kind_image(kind, tile_px),
			Rect2i(0, 0, tile_px, tile_px),
			Vector2i(int(KIND_COLUMNS[kind]) * tile_px, 0))
	foam_ready = false
	_foam_ready_by_px[tile_px] = false
	var strips: Array[Image] = []
	for dir_index in shore_dirs.size():
		var strip_tex := UiKitLib.icon_texture(
			STRIP_ID_PREFIX + str(shore_dirs[dir_index]))
		var strip: Image = _to_rgba8(strip_tex.get_image()) \
			if strip_tex != null else null
		if strip != null and (strip.get_width() != tile_px
				or strip.get_height() != tile_px):
			# The shipped strips are 64-canvas art (§4.8 64-canvas
			# amendment 1664ba9); a smaller per-map tile (the battle grid's
			# 32) takes the exact nearest downscale so the foam band lands
			# on the same edge fraction — never a top-left crop.
			strip.resize(tile_px, tile_px, Image.INTERPOLATE_NEAREST)
		strips.append(strip)
	# the 4 edge bits map to the §6.6 dirs n/e/s/w = strip indices 0/2/4/6
	var bit_strip := [0, 2, 4, 6]
	var all_resolved := strips.size() == 8
	for strip in strips:
		if strip == null:
			all_resolved = false
	# DEFECT C fix (r5): per-bit pruned strips. `stub_variants[strip_i]` holds
	# the 4 prune states of that strip: bit 0 = keep the strip's first end
	# stub (its "west"/"north" perpendicular end), bit 1 = keep the second
	# ("east"/"south"). Pruning clears FOAM px in the end zone unless the
	# variant masks BOTH the strip's own edge and that perpendicular edge.
	var stub_variants: Array = []
	if all_resolved:
		for bit in 4:
			var strip_img: Image = strips[bit_strip[bit]]
			stub_variants.append(_stub_variants(strip_img, tile_px, bit))
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(tile_px, tile_px)
	if all_resolved:
		foam_ready = true
		_foam_ready_by_px[tile_px] = true
		var tiles_to_create: Array[Vector2i] = []
		for kind in kinds:
			tiles_to_create.append(Vector2i(int(KIND_COLUMNS[kind]), 0))
		for mask in 16:
			for kind_index in kinds.size():
				var column := 2 + mask * 2 + kind_index
				var cell := _kind_image(str(kinds[kind_index]), tile_px)
				for bit in 4:
					if (mask & (1 << bit)) != 0:
						cell.blend_rect(
							stub_variants[bit][_stub_state(mask, bit)],
							Rect2i(0, 0, tile_px, tile_px), Vector2i.ZERO)
				image.blit_rect(cell, Rect2i(0, 0, tile_px, tile_px),
					Vector2i(column * tile_px, 0))
				tiles_to_create.append(Vector2i(column, 0))
		# compose-then-create: the atlas image is FULLY composed before the
		# texture exists (the r2 lesson — a create-empty + `update` round-trip
		# reads back empty through `get_image()`), and tiles register after
		# texture + region size, exactly like the terrain atlas builder
		var source := TileSetAtlasSource.new()
		source.texture = ImageTexture.create_from_image(image)
		source.texture_region_size = Vector2i(tile_px, tile_px)
		for coords in tiles_to_create:
			source.create_tile(coords)
		tile_set.add_source(source)
	else:
		# the fallback atlas still needs its single source (the two flat
		# fills already blitted above); `foam_ready` stays false so the
		# stamp side falls back to the plain columns
		var source := TileSetAtlasSource.new()
		source.texture = ImageTexture.create_from_image(image)
		source.texture_region_size = Vector2i(tile_px, tile_px)
		for kind in kinds:
			source.create_tile(Vector2i(int(KIND_COLUMNS[kind]), 0))
		tile_set.add_source(source)
	return tile_set


## The stub prune state of strip `bit` in variant `mask` (DEFECT C rule):
## bit 0 set = keep the strip's FIRST perpendicular end stub, bit 1 = keep
## the SECOND. First/second per strip: n,s → west/east; e,w → north/south.
## A stub is kept only when its perpendicular edge is also in the mask.
static func _stub_state(mask: int, bit: int) -> int:
	var keep_first := 0
	var keep_second := 0
	match bit:
		0, 2:  # n / s strips: end stubs reach the W and E edges
			keep_first = 1 if (mask & 8) != 0 else 0   # west edge (bit 3)
			keep_second = 2 if (mask & 2) != 0 else 0  # east edge (bit 1)
		1, 3:  # e / w strips: end stubs reach the N and S edges
			keep_first = 1 if (mask & 1) != 0 else 0   # north edge (bit 0)
			keep_second = 2 if (mask & 4) != 0 else 0  # south edge (bit 2)
	return keep_first | keep_second


## The 4 pruned copies of one strip image, indexed by `_stub_state`, for the
## strip of edge bit `bit` (0=n, 1=e, 2=s, 3=w). State 3 is the strip
## unchanged. Pruning clears FOAM pixels (the white speckles + dust — NOT
## the COAST_SEA shallow wash, which stays continuous per the r5 foam
## language) inside the strip's two perpendicular END zones when the
## adjacent orthogonal edge is unmasked: n/s strips end at W/E (x zones),
## e/w strips end at N/S (y zones). `tile_px` scales the §4.8 12 px stub
## zone (`STUB_ZONE_PX` is pinned on the 64 canvas).
static func _stub_variants(strip_img: Image, tile_px: int, bit: int) -> Array:
	var zone := int(tile_px * STUB_ZONE_PX / 64.0)
	var foam := PaletteLib.FOAM
	var variants: Array = []
	for state in 4:
		if state == 3:
			variants.append(strip_img)
			continue
		var img := Image.new()
		img.copy_from(strip_img)
		var ends: Array = []
		var first := Rect2i(0, 0, zone, tile_px) if bit in [0, 2] \
			else Rect2i(0, 0, tile_px, zone)
		var second := Rect2i(tile_px - zone, 0, zone, tile_px) if bit in [0, 2] \
			else Rect2i(0, tile_px - zone, tile_px, zone)
		if (state & 1) == 0:
			ends.append(first)
		if (state & 2) == 0:
			ends.append(second)
		for rect: Rect2i in ends:
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					if img.get_pixel(x, y).is_equal_approx(foam):
						img.set_pixel(x, y, Color(0, 0, 0, 0))
		variants.append(img)
	return variants


## The atlas coords a water tile stamps: its kind's plain fill column, or the
## coast-foam variant for `mask` (bits 0..3 = N/E/S/W foam edge — the REFINED
## mask, see `map_loader._shore_foam_mask`) when the variant set resolved.
## Plain fills fall back everywhere else — battle grids and registry-empty
## runs never see foam cells.
static func water_coords(mask: int, kind_column: int,
		tile_px: int = -1) -> Vector2i:
	var ready := foam_ready
	if tile_px >= 0 and _foam_ready_by_px.has(tile_px):
		ready = _foam_ready_by_px[tile_px]
	if mask <= 0 or not ready:
		return Vector2i(kind_column, 0)
	var kind_offset := 1 if kind_column != int(KIND_COLUMNS["sea"]) else 0
	return Vector2i(2 + mask * 2 + kind_offset, 0)


## The animated-sea `ShaderMaterial` (§4.7.17) — the params are the pinned
## constants; `u_motion` is set once from the `UiMotion` gate (headless
## suites run with motion off ⇒ the layer builds frozen at offset 0).
## `null` when the shader or the mask is missing: the caller renders the flat
## tiles bare (no animation), never an error. Built at most once per process
## and cached — the mask is immutable data and a failed attempt (a fresh
## checkout without the shader yet) must not re-spam the console per chunk.
static var _material_cache: ShaderMaterial = null
static var _material_attempted := false

static func build_material() -> ShaderMaterial:
	if _material_attempted:
		return _material_cache
	_material_attempted = true
	var shader := _load_shader()
	var mask := _load_mask()
	if shader == null or mask == null:
		return null
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("u_mask", mask)
	material.set_shader_parameter("u_period", SCROLL_PERIOD_MS / 1000.0)
	material.set_shader_parameter("u_darken", SEA_DARKEN)
	material.set_shader_parameter("u_mask_px", MASK_SIZE_PX)
	# §4.7.17 r5 crest accent: FOAM tint + the pinned partial mix.
	material.set_shader_parameter("u_crest_color",
		Vector3(PaletteLib.FOAM.r, PaletteLib.FOAM.g, PaletteLib.FOAM.b))
	material.set_shader_parameter("u_crest_mix", CREST_MIX)
	# The §4.7.17 gate: off ⇒ frozen at scroll offset 0.
	if UiMotionLib.enabled:
		UiMotionLib.run_shader(material)
	else:
		UiMotionLib.freeze_shader(material)
	_material_cache = material
	return material


## The water shader — a code artifact, a plain script-style load.
static func _load_shader() -> Shader:
	if not FileAccess.file_exists(SHADER_PATH):
		return null
	return load(SHADER_PATH) as Shader


## The 64×64 dither mask, loaded through the DATA-ARTIFACT pattern (raw
## bytes + `load_png_from_buffer`, the `world.png` contract) rather than the
## texture import: the mask is tool-owned output and must render identically
## in a fresh checkout, a headless suite and an export, none of which carry
## a compiled import cache.
static func _load_mask() -> Texture2D:
	if not FileAccess.file_exists(MASK_PATH):
		return null
	var bytes := FileAccess.get_file_as_bytes(MASK_PATH)
	if bytes.is_empty():
		return null
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(image)


## The battle/world water layer: flat tiles (+ coast-foam variants when
## `shore_dirs` is supplied and the strips resolve) + the shared material
## (when the animation assets exist). The tile set is built fresh per call
## (each layer owns its tiles); the MATERIAL is built once per process and
## shared, so S3's chunk layers and S10's battle layer all carry the same
## params and a gate value that can never disagree (§4.7.17: one shader, one
## set of pins). The S10 open-sea grid passes no dirs — its atlas stays the
## two flat fills.
## The water TileSets built this process, keyed by `tile_px` — every chunk
## layer (and the S10 battle layer at its own px) shares ONE set per px, the
## same caching convention as [method build_material]'s material. The foam
## bake composes 34 cells and fetches + decompresses 8 registry strips per
## build; rebuilding it per chunk spawn paid that on every boot chunk (the
## 64-canvas boot-budget regression — TileSets are resources and share
## safely across TileMapLayers).
static var _tile_set_cache: Dictionary = {}

static func build_layer(tile_px: int, shore_dirs: Array = []) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.name = "Water"
	if not _tile_set_cache.has(tile_px):
		_tile_set_cache[tile_px] = build_tile_set(tile_px, shore_dirs)
	layer.tile_set = _tile_set_cache[tile_px]
	var material := build_material()
	if material != null:
		layer.material = material
	return layer


## The water column for the loader palette index at a tile (`KIND_COLUMNS`
## of the legend kind), or -1 when the tile is not water. Data-driven: the
## kind string comes from the loaded legend (`10-*` §6.1), never a re-typed
## table — an unknown kind renders nothing on the water layer.
static func column_for_index(loader, index: int) -> int:
	if index < 0:
		return -1
	var kind: String = loader.kind_of_index(index)
	if not KIND_COLUMNS.has(kind):
		return -1
	return int(KIND_COLUMNS[kind])


## Stamps the water cells of one chunk into `layer` (the loader's chunk pass;
## same tile addressing as the terrain layer: `chunk_origin` is the chunk's
## UNBOUNDED tile origin, `x` wraps per tile through the loader).
static func fill_chunk(layer: TileMapLayer, loader, source_id: int,
		chunk_origin: Vector2i, chunk_tiles: int) -> void:
	var size := Vector2i(loader.width, loader.height)
	if size.x <= 0 or size.y <= 0:
		return
	for j in chunk_tiles:
		var y := chunk_origin.y + j
		if y < 0 or y >= size.y:
			continue
		for i in chunk_tiles:
			var column := column_for_index(loader,
				loader.index_xy(chunk_origin.x + i, y))
			if column < 0:
				continue
			layer.set_cell(Vector2i(i, j), source_id, Vector2i(column, 0))
