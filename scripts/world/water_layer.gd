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
## §4.7.17 r5 (2026-11-05) crest accent: the partial mix toward FOAM (the
## r5 band is 0.6–0.75). RETIRED 2026-11-06 (user direction, with the
## coast-foam retirement — the painted wang water carries its own ripple
## art; a FOAM-tinted crest over it read as noise). The shader block
## stays; this mix is the off switch (the shader's u_crest_mix default
## 0.70 is overridden here — the two sites must not drift).
const CREST_MIX := 0.0
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

## §4.8 2026-11-06 — the PixelLab coast family (the vendored wang tileset,
## `tools/build_terrain_pixellab.py` output). Registry id prefix of the 16
## corner tiles; the WATER layer carries its owned indices ({0..7}) as
## columns WANG_COLUMN_BASE..+7, stamped on cells with land corners
## (upper = land, lower = water; combo bits NW/NE/SW/SE = 1/2/4/8, wang
## index = NW·8 + NE·4 + SW·2 + SE·1). The painted water ALSO replaces the
## flat fills: [method _kind_image] prefers `terrain_coast_wang_0` (the
## pure-water tile) for both water kinds — sea vs coastal_sea is no longer
## two fills but the distance shader's deep/shallow factor (§4.8
## 2026-11-06 pixel-depth amendment). Missing ids ⇒ the legacy flat fills
## (§4.9 fallback chain; suites with synthetic grids keep their pins).
const WANG_ID_PREFIX := "terrain_coast_wang_"
const WANG_COLUMN_BASE := 2 + 16 * 2

## The wang indices the WATER layer owns: a water cell's own pixel is its
## NW corner vertex, so its combo never carries the NW bit — under the
## corrected numbering the NW-lower indices are exactly {0..7} (wang_0..7).
## Columns WANG_COLUMN_BASE..+7 hold them in this order. (The terrain atlas
## owns the NW-upper complement 8..15 — see `map_loader._ensure_tile_set`.)
const WANG_WATER_INDICES: Array[int] = [0, 1, 2, 3, 4, 5, 6, 7]

## The terrain atlas's land-owned complement (`map_loader._ensure_tile_set`):
## a land cell's own pixel is its NW corner vertex, so its index always
## carries bit 3 — the coast tiles {8..14} (wang_8 = NW-only through
## wang_14 = NW+NE+SW); index 15 (all-land) is the interior and stays on
## the 8-dihedral variant pool (columns 0..7; coast tiles at 8..14).
const WANG_LAND_INDICES: Array[int] = [8, 9, 10, 11, 12, 13, 14]

## §4.8 2026-11-06 pixel-depth pins (mirrored in sea_water.gdshader's
## uniform defaults — the two sites must not drift). The factor is 1.0 at
## ≤ BAND tiles from land, DEEP at ≥ FULL tiles, linear between; continuous
## per pixel (the §6.7 raster is one texel per tile, linearly filtered —
## the user direction "pixel level of darker, not tile level").
const DIST_TEXTURE_PATH := "res://data/maps/dist_land.png"
const DIST_DEEP_FACTOR := 0.6
const DIST_BAND_TILES := 6.0
const DIST_FULL_TILES := 10.0
## §6.7: the raster's tile grid (one texel per tile of `world.png`) and the
## encode: texel = round(min(d, 16) / 16 * 255) ⇒ d = texel * 16.
const DIST_MAP_TILES := Vector2(4320, 2160)
const DIST_ENCODE_MAX_TILES := 16.0

## The wang readiness of the LAST `build_tile_set` call, per tile px (the
## foam convention: the stamp side reads its OWN tile px's flag).
static var wang_ready := false
static var _wang_ready_by_px: Dictionary = {}

## The decoded §6.7 distance texture (one decode per process, cached; null
## when the artifact is absent — the shader runs with u_dist_enable = 0 and
## the water renders undarkened, never an error). Held via WeakRef: a
## strong static Resource ref aborted Godot's teardown at exit (the
## test_density exit-crash report) — a weak cache dies with the last owner
## instead.
static var _dist_texture_ref: WeakRef = null
static var _dist_attempted := false

## The registry id prefix of the §6.6/A.6 foam strips (`shore_{dir}`), baked
## into the coast-foam water variants at tile-set build time.
const STRIP_ID_PREFIX := "shore_"


## The wang index of a corner combo (§4.8 2026-11-06 placement rule): combo
## bits NW/NE/SW/SE = 1/2/4/8 (upper = land), wang index bits reordered as
## NW→bit3, NE→bit2, SW→bit1, SE→bit0 — the PixelLab set's own numbering,
## DERIVED FROM THE VENDORED TILESET'S `corners` (wang_8 = NW-only,
## wang_4 = NE-only, wang_2 = SW-only, wang_1 = SE-only; the 2026-11-06
## regression swapped NW/NE here — the placement looked mirrored on every
## east-facing coast until the ledger ground-truth pin caught it).
## Pure helper, suite-pinned against the ledger.
static func wang_index(combo: int) -> int:
	return ((combo & 1) * 8          # NW → index bit 3
		+ ((combo & 2) * 2)          # NE → index bit 2
		+ ((combo & 4) >> 1)         # SW → index bit 1
		+ ((combo & 8) >> 3))        # SE → index bit 0


## True when the combo carries any land corner (the cell straddles the
## coast and stamps a wang corner tile instead of the plain fill). Suite
## pins use it to document the water/land ownership split.
static func wang_is_coastal(combo: int) -> bool:
	return combo != 0

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


## One flat fill for the atlas at `tile_px`: the §4.8 2026-11-06 painted
## water (`terrain_coast_wang_0`, the wang set's pure-water tile) for the
## water kinds, falling back to the legacy flat fill id and then the locked
## palette color (§4.9 chain). A 64-canvas source at a smaller `tile_px`
## (the S10 battle grid's 32) takes the exact nearest downscale — the same
## convention the foam strips use — so the painted texture never crops.
static func _kind_image(kind: String, tile_px: int) -> Image:
	var image := Image.create_empty(tile_px, tile_px, false, Image.FORMAT_RGBA8)
	var texture: Texture2D = null
	if KIND_COLUMNS.has(kind):
		texture = UiKitLib.icon_texture(WANG_ID_PREFIX + "0")
	if texture == null:
		texture = UiKitLib.icon_texture(sprite_id(kind))
	if texture != null:
		var pixels := _to_rgba8(texture.get_image())
		if pixels != null:
			if pixels.get_width() != tile_px or pixels.get_height() != tile_px:
				pixels.resize(tile_px, tile_px, Image.INTERPOLATE_NEAREST)
			image.blit_rect(pixels, Rect2i(0, 0, tile_px, tile_px),
				Vector2i.ZERO)
			return image
	image.fill(fallback_color(kind))
	return image


## One wang corner tile image at `tile_px` (index 0..15), or null when the
## id does not resolve — the callers treat any miss as wang-inactive and
## fall through to the legacy fills (§4.9). A 64 canvas downscales nearest
## for smaller tile sizes (the battle-grid convention).
static func _wang_tile_image(index: int, tile_px: int) -> Image:
	var texture := UiKitLib.icon_texture(WANG_ID_PREFIX + str(index))
	if texture == null:
		return null
	var pixels := _to_rgba8(texture.get_image())
	if pixels == null:
		return null
	if pixels.get_width() != tile_px or pixels.get_height() != tile_px:
		pixels.resize(tile_px, tile_px, Image.INTERPOLATE_NEAREST)
	return pixels


## The water TileSet: ONE atlas source. Columns 0..1 the two water-kind
## fills; columns 2..33 the 16 coast-foam mask variants (baked only when
## `shore_dirs` is supplied AND all 8 `shore_{dir}` strips resolve — the
## §4.8 2026-11-06 amendment retires that bake from the WORLD path, which
## now passes no dirs; the machinery stays for the §4.9 fallback and the
## suites); columns WANG_COLUMN_BASE..+7 the wang corner tiles (baked when
## the whole water half resolves — §4.8 2026-11-06). Unresolved ranges stay
## transparent with their readiness flags false (`foam_ready` /
## `wang_ready` — the stamp side falls back to the plain fills, §4.9).
static func build_tile_set(tile_px: int, shore_dirs: Array = []) -> TileSet:
	var kinds: Array = KIND_COLUMNS.keys()
	kinds.sort_custom(func(a: String, b: String) -> bool:
		return int(KIND_COLUMNS[a]) < int(KIND_COLUMNS[b]))
	var columns := WANG_COLUMN_BASE + WANG_WATER_INDICES.size()
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
	# stub (its "west"/"north" perpendicular end), bit 1 = keep the second.
	var stub_variants: Array = []
	if all_resolved:
		for bit in 4:
			var strip_img: Image = strips[bit_strip[bit]]
			stub_variants.append(_stub_variants(strip_img, tile_px, bit))
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(tile_px, tile_px)
	var tiles_to_create: Array[Vector2i] = []
	for kind in kinds:
		tiles_to_create.append(Vector2i(int(KIND_COLUMNS[kind]), 0))
	if all_resolved:
		foam_ready = true
		_foam_ready_by_px[tile_px] = true
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
	# §4.8 2026-11-06 — the wang corner columns, baked when the whole
	# water half resolves (readiness per tile px, the foam convention: the
	# S10 battle grid builds its own set and stamps by kind, never by
	# corner).
	wang_ready = false
	_wang_ready_by_px[tile_px] = false
	var wang_columns := WANG_WATER_INDICES.size()
	var wang_ok := true
	for position in wang_columns:
		var tile_image := _wang_tile_image(WANG_WATER_INDICES[position],
			tile_px)
		if tile_image == null:
			wang_ok = false
			break
		image.blit_rect(tile_image, Rect2i(0, 0, tile_px, tile_px),
			Vector2i((WANG_COLUMN_BASE + position) * tile_px, 0))
	if wang_ok:
		wang_ready = true
		_wang_ready_by_px[tile_px] = true
		for position in wang_columns:
			tiles_to_create.append(Vector2i(WANG_COLUMN_BASE + position, 0))
	# compose-then-create: the atlas image is FULLY composed before the
	# texture exists (the r2 lesson — a create-empty + `update` round-trip
	# reads back empty through `get_image()`), and tiles register after
	# texture + region size, exactly like the terrain atlas builder.
	var source := TileSetAtlasSource.new()
	source.texture = ImageTexture.create_from_image(image)
	source.texture_region_size = Vector2i(tile_px, tile_px)
	for coords in tiles_to_create:
		source.create_tile(coords)
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


## The wang readiness for `tile_px` (per-px, the foam convention): true when
## that tile px's last `build_tile_set` resolved the whole wang half.
static func wang_ready_for_px(tile_px: int) -> bool:
	return bool(_wang_ready_by_px.get(tile_px, false))


## The atlas coords of a water cell's wang corner tile in the wang source
## (combo ≠ 0 and a water-owned index). Combo 0 (open water) or a
## land-owned index (never stamped on the water layer) returns the INVALID
## sentinel (-1, 0) — the caller stamps the plain fill/foam instead. Only
## meaningful when `wang_ready_for_px` holds.
static func wang_coords(combo: int) -> Vector2i:
	var position := WANG_WATER_INDICES.find(wang_index(combo))
	if combo == 0 or position < 0:
		return Vector2i(-1, 0)
	return Vector2i(WANG_COLUMN_BASE + position, 0)


## The decoded §6.7 distance texture (§4.8 2026-11-06 pixel-depth amendment)
## — the world raster's bytes through the DATA-ARTIFACT pattern (the
## `world.png` contract: raw bytes + `load_png_from_buffer`, no import
## pipeline). Cached per process; null when absent — the material then runs
## with `u_dist_enable = 0` (undarkened water, never an error).
static func load_dist_texture() -> Texture2D:
	if _dist_attempted and _dist_texture_ref != null:
		var cached = _dist_texture_ref.get_ref()
		if cached != null:
			return cached as Texture2D
	_dist_attempted = true
	if not FileAccess.file_exists(DIST_TEXTURE_PATH):
		return null
	var bytes := FileAccess.get_file_as_bytes(DIST_TEXTURE_PATH)
	if bytes.is_empty():
		return null
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		return null
	var texture := ImageTexture.create_from_image(image)
	_dist_texture_ref = weakref(texture)
	return texture


## The water material for one WORLD chunk: the shared animated-sea material
## with the §4.8 pixel-depth amendment layered on — `u_dist_enable` + the
## chunk's map-pixel origin (each chunk duplicates the cached material; the
## base cache stays shared with S10, which never enables the distance).
## `null` when the base material is unavailable (flat tiles, no animation).
static func build_chunk_material(origin_px: Vector2) -> ShaderMaterial:
	var base := build_material()
	if base == null:
		return null
	var material := base.duplicate() as ShaderMaterial
	material.set_shader_parameter("u_dist_origin_px", origin_px)
	material.set_shader_parameter("u_dist_map_px",
		DIST_MAP_TILES * 64.0)
	material.set_shader_parameter("u_dist_enable", 1.0)
	material.set_shader_parameter("u_dist_deep", DIST_DEEP_FACTOR)
	material.set_shader_parameter("u_dist_band", DIST_BAND_TILES)
	material.set_shader_parameter("u_dist_full", DIST_FULL_TILES)
	var dist_tex := load_dist_texture()
	if dist_tex != null:
		material.set_shader_parameter("u_dist_tex", dist_tex)
	else:
		material.set_shader_parameter("u_dist_enable", 0.0)
	return material


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
