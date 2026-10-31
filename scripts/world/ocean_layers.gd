class_name OceanLayers
extends RefCounted
## Ocean-layer lookups (Phase 6, docs/10-DATA-SCHEMA.md §6.5,
## docs/20-WORLD-AND-SAILING.md §4.14/§4.16/§4.18).
##
## The **single owner** of every ocean lookup (IMPLEMENT-Phase6 correction 15):
## the two tool-owned rasters plus the ice polygons decode here, once, and
## everything else reads through this module. Nothing else re-parses the PNGs
## or the ocean JSON geometry.
##
## Artifacts (all tool-owned, never hand-edited — AGENTS.md):
##   * `data/maps/wind_regions.png` — indexed PNG, 4320×2160, 1 px = 1 tile,
##     palette index = region id (0 = unassigned water → the `VAR` fallback);
##     indices `1..N` follow `DataLoader.wind_regions_list` file order.
##   * `data/maps/currents.png` — index 0 = no current; 1..24 =
##     `dir_index × 3 + strength` over the compass order `N NE E SE S SW W NW`
##     (dir_index 0..7) and strength 1..3. A corridor tile carries its
##     segment's dominant compass direction (per-segment bearings, the W3 pin).
##   * `data/ice_regions.json` (via DataLoader) — polygons, NOT rasterized:
##     §4.18 stays a runtime polygon check with a month-keyed tile cache.
##
## Reversal rule (pinned, §6.5): the raster stores each system's **stored
## (non-flipped)** vector — for a reversal system the non-summer regime. The
## flip happens **at lookup time** during `reversal.summer_months`: the stored
## direction is replaced by its 8-compass opposite (`N↔S`, `NE↔SW`, `E↔W`,
## `SE↔NW`), strength unchanged. To know WHICH system a tile belongs to, this
## module rebuilds, once at load, a membership index for **reversal systems
## only** (the shipped data has exactly one: `somali_current`) by recomputing
## the builder's corridor geometry — the `tools/build_ocean.py`
## `chain_between` + Chebyshev-dilation algorithm ported verbatim (the same
## 1/20-tile sampling and diagonal bridging). A membership hit flips the tile
## only when the decoded strength equals that system's strength, so a tile the
## builder's strongest-then-id-order rule gave to a *different* system is never
## flipped by mistake. Non-reversal systems need no membership map (their
## raster vector is already the year-round answer).
##
## Ice cache (§4.18): month-keyed tile sets, built **lazily and memoized** on
## the first query of each month (the choice + its cost are documented on
## [member _ice_masks] below). The fill is the builder's even-odd scanline
## sampled at tile centres (`x + 0.5, y + 0.5`), wrap-aware on x.
##
## Singleton (documented deviation from instance injection): DataLoader is not
## editable by this task, and every caller needs the same decoded state, so the
## module keeps a lazy static singleton behind [method instance]. Decode runs
## on first access (not at autoload time), so suites that never reach the
## ledger never pay for it.
##
## Ownership: Phase-6 task F. Decoded state is session-only and never saved
## (§6.5 "Session-only").

## The one grid both rasters ship at (§6.5: exactly 4320 × 2160).
const GRID_WIDTH := 4320
const GRID_HEIGHT := 2160

## Compass order of both rasters' encodings (dir_index 0..7). y grows
## southward, so `N` is (0, −1).
const COMPASS_DIRS: Array[String] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
## Unit flow vectors per compass index (tile space, diagonals normalized;
## literal constants — GDScript consts cannot call `.normalized()`).
const COMPASS_VECTORS: Array[Vector2] = [
	Vector2(0.0, -1.0), Vector2(0.7071067811865476, -0.7071067811865476),
	Vector2(1.0, 0.0), Vector2(0.7071067811865476, 0.7071067811865476),
	Vector2(0.0, 1.0), Vector2(-0.7071067811865476, 0.7071067811865476),
	Vector2(-1.0, 0.0), Vector2(-0.7071067811865476, -0.7071067811865476),
]
## The 8-compass opposite of every direction (`N↔S`, `NE↔SW`, `E↔W`, `SE↔NW`)
## — the reversal flip, one array lookup.
const COMPASS_OPPOSITE: Array[String] = ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]

## §4.14 direction tokens: the 8 compass directions plus `VAR`.
const WIND_TOKENS: Array[String] = [
	"N", "NE", "E", "SE", "S", "SW", "W", "NW", "VAR",
]
## §6.5 palette bounds: wind index ≤ region count (the shipped cap is 25
## regions), current index ≤ 24 (8 dirs × 3 strengths).
const MAX_WIND_REGIONS := 25
const MAX_CURRENT_INDEX := 24

## PNG paths (§6.5); the artifact is data, not an imported texture (§6.3).
const WIND_PNG := "res://data/maps/wind_regions.png"
const CURRENTS_PNG := "res://data/maps/currents.png"

## The lazy static singleton (see the class docstring for the rationale).
## Deliberately untyped: a `OceanLayers` self-annotation needs the editor's
## global-class cache and breaks in a fresh checkout (the Phase-2 finding
## behind the codebase-wide preload convention).
static var _instance = null


static func instance():
	if _instance == null:
		_instance = load("res://scripts/world/ocean_layers.gd").new()
	return _instance


## Test seam: drops the singleton so a later decode can be re-measured.
static func reset_instance() -> void:
	_instance = null


# --- Decoded state ----------------------------------------------------------

## False after a loud decode failure; every lookup then returns its documented
## default (`VAR` / no current / no ice) so the game keeps sailing while the
## console carries the error (MapLoader's startup-error spirit).
var decode_ok: bool = false
## Human-readable reason of the last decode failure; "" when healthy.
var last_error: String = ""
## Wall-clock cost of the wind-raster decode (the risk-table number,
## IMPLEMENT-Phase6 "Perf" row: "PNG decode cost measured in F"). The currents
## raster decodes lazily (below) and reports into [member currents_decode_ms].
var decode_ms: int = 0
## True once the currents raster is decoded and within palette bounds. The
## currents decode is **lazy**: the per-day-tick wind roll needs only the wind
## raster, so a session that never queries a current never pays the second
## ~1 s decode (the split halves the cost for exactly those sessions).
var currents_ok: bool = false
var currents_decode_ms: int = 0
var currents_decoded: bool = false

## One wind-region id per tile, row-major (`width × height` bytes).
var _wind_indices := PackedByteArray()
## One current index per tile (0 = none, 1..24 = dir × 3 + strength).
var _current_indices := PackedByteArray()
var _width: int = 0
var _height: int = 0

## Reversal-system membership: `Vector2i(tile) → [strength, summer_months]`
## for every tile of every system that carries a `reversal` block (the months
## array is shared by reference per system). Built once at load by recomputing
## the builder's corridor geometry (see the class docstring).
var _reversal_members: Dictionary = {}
## `{system_id: summer_months Array[int]}` for the same systems (diagnostics).
var _reversal_months: Dictionary = {}

## Month-keyed ice tile sets, `month (1..12) → {Vector2i: true}`. Lazy +
## memoized (the documented choice): the shipped polygons are small (Baltic /
## Hudson / White Sea), so a month mask builds in a few milliseconds, and only
## the months a session actually sails get built. Worst case (all 12 built)
## the sets hold well under 10^5 Vector2i keys total — a few MB of Dictionary
## overhead, far below the ~9.3 MB a full-grid byte mask per month would cost
## (12 × 9.3 MB ≈ 112 MB, rejected for that reason).
var _ice_masks: Dictionary = {}


func _init() -> void:
	var started := Time.get_ticks_usec()
	_decode_wind()
	decode_ms = int(Time.get_ticks_usec() - started) / 1000


# --- Decoding ---------------------------------------------------------------

func _fail(reason: String) -> void:
	decode_ok = false
	last_error = reason
	push_error("OceanLayers: " + reason)


## Decodes `wind_regions.png` (eager: the ledger's direction roll reads it
## every day). Returns false (with [method _fail] called) on any artifact
## violation.
func _decode_wind() -> bool:
	decode_ok = false
	last_error = ""
	var wind_bytes := _read_file(WIND_PNG)
	if wind_bytes.is_empty():
		return false
	var wind := _decode_indexed(wind_bytes, WIND_PNG, MAX_WIND_REGIONS)
	if wind.is_empty():
		return false
	if int(wind["width"]) != GRID_WIDTH or int(wind["height"]) != GRID_HEIGHT:
		_fail("%s is %d×%d, the locked grid is %d×%d (§6.5)" % [
			WIND_PNG, int(wind["width"]), int(wind["height"]),
			GRID_WIDTH, GRID_HEIGHT,
		])
		return false
	_wind_indices = wind["indices"]
	_width = GRID_WIDTH
	_height = GRID_HEIGHT
	decode_ok = true
	return true


## Decodes `currents.png` + builds the reversal membership index, once, on
## the first current query. Safe to call repeatedly.
func _ensure_currents() -> bool:
	if currents_decoded:
		return currents_ok
	currents_decoded = true
	currents_ok = false
	if not decode_ok:
		return false  # the wind decode already named the failure
	var current_bytes := _read_file(CURRENTS_PNG)
	if current_bytes.is_empty():
		return false
	var currents := _decode_indexed(current_bytes, CURRENTS_PNG, MAX_CURRENT_INDEX)
	if currents.is_empty():
		return false
	if int(currents["width"]) != GRID_WIDTH or int(currents["height"]) != GRID_HEIGHT:
		_fail("%s is %d×%d, the locked grid is %d×%d (§6.5)" % [
			CURRENTS_PNG, int(currents["width"]), int(currents["height"]),
			GRID_WIDTH, GRID_HEIGHT,
		])
		return false
	var started := Time.get_ticks_usec()
	_current_indices = currents["indices"]
	_build_reversal_index()
	currents_decode_ms = int(Time.get_ticks_usec() - started) / 1000
	currents_ok = true
	return true


func _read_file(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		_fail("ocean raster not found: %s" % path)
		return PackedByteArray()
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		_fail("ocean raster is empty or unreadable: %s" % path)
	return bytes


## Decodes one indexed PNG into per-tile palette indices, checking the IHDR
## (colour type 3, 8-bit, non-interlaced), the exact locked grid, and the
## palette bounds (`max_index`). Same pattern as `map_loader.gd` (Godot hands
## back RGBA8 even for palette PNGs, so every pixel colour is matched back
## through the PLTE). Returns {} (with [method _fail] already called) on any
## violation; otherwise `{width, height, indices}`.
func _decode_indexed(bytes: PackedByteArray, label: String, max_index: int) -> Dictionary:
	var header := _read_png_header(bytes)
	if header.is_empty():
		_fail("%s: not a PNG or the IHDR chunk is truncated" % label)
		return {}
	var png_width := int(header.get("width", 0))
	var png_height := int(header.get("height", 0))
	if int(header.get("colour_type", -1)) != 3:
		_fail("%s: not an indexed-colour PNG (colour type %d, expected 3, §6.5)" % [
			label, int(header.get("colour_type", -1)),
		])
		return {}
	if int(header.get("bit_depth", -1)) != 8:
		_fail("%s: indexed bit depth is %d, expected 8" % [
			label, int(header.get("bit_depth", -1)),
		])
		return {}
	if int(header.get("interlace", 0)) != 0:
		_fail("%s: interlaced PNGs are not supported" % label)
		return {}
	var palette: PackedByteArray = header.get("palette", PackedByteArray())
	if palette.size() < 3:
		_fail("%s: no PLTE chunk (an indexed PNG needs a palette)" % label)
		return {}

	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		_fail("%s: Image.load_png_from_buffer rejected the artifact" % label)
		return {}
	if image.get_width() != png_width or image.get_height() != png_height:
		_fail("%s: decoded image is %d×%d, IHDR says %d×%d" % [
			label, image.get_width(), image.get_height(), png_width, png_height,
		])
		return {}

	var colour_to_index := {}
	for index in palette.size() / 3:
		var key := (palette[index * 3] << 16) | (palette[index * 3 + 1] << 8) \
			| palette[index * 3 + 2]
		if not colour_to_index.has(key):
			colour_to_index[key] = index
	var data := image.get_data()
	var bpp := 3 if image.get_format() == Image.FORMAT_RGB8 else 4
	var count := png_width * png_height
	var out := PackedByteArray()
	out.resize(count)
	for pixel in count:
		var offset := pixel * bpp
		# Single dictionary probe per pixel (`get` with the -1 sentinel);
		# this loop is the whole decode cost, measured in [member decode_ms].
		var value: int = colour_to_index.get(
			(data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2], -1)
		if value < 0:
			_fail("%s: pixel (%d,%d) colour #%06x is not in the PLTE palette" % [
				label, pixel % png_width, pixel / png_width,
				(data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2],
			])
			return {}
		if value > max_index:
			_fail("%s: palette index %d at tile (%d,%d) is above the §6.5 bound %d" % [
				label, value, pixel % png_width, pixel / png_width, max_index,
			])
			return {}
		out[pixel] = value
	return {"width": png_width, "height": png_height, "indices": out}


## Minimal PNG chunk walker (IHDR + PLTE) — the `map_loader.gd` pattern, kept
## local so this module stays the single owner of the ocean decoders.
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


# --- Lookups (O(1) after the one-time decode) -------------------------------

func _tile_index(cell: Vector2i) -> int:
	if not decode_ok or _width <= 0:
		return -1
	if cell.y < 0 or cell.y >= _height:
		return -1
	return int(_wind_indices[cell.y * _width + posmod(cell.x, _width)])


## Wind-region id at `cell` (1..N, following `DataLoader.wind_regions_list`
## file order), or 0 for unassigned water / any failed lookup (§6.5: index 0
## is the `VAR` fallback).
func wind_region_at(cell: Vector2i) -> int:
	return _tile_index(cell)


## The prevailing wind-FROM token for `cell` in `month` (1..12), per the
## region's month table. Index 0 / uncovered water → `"VAR"`; an unknown or
## out-of-range month or a token outside §4.14's set → `"VAR"` (the documented
## fallback: `VAR` draws uniformly over the 8 compass directions).
func prevailing_for(cell: Vector2i, month: int) -> String:
	var region_id := _tile_index(cell)
	if region_id <= 0:
		return "VAR"
	var regions: Array = DataLoader.wind_regions_list
	if region_id > regions.size():
		return "VAR"
	var region: Dictionary = regions[region_id - 1]
	if not (region is Dictionary):
		return "VAR"
	if month < 1 or month > 12:
		return "VAR"
	var token = (region as Dictionary).get("months", {}).get(str(month), "")
	if token is String and token in WIND_TOKENS:
		return token
	return "VAR"


## Decoded current at `cell`: `{"dir": "N".."NW", "strength": 1..3}` keyed by
## the §6.5 encoding, or `{}` on no current / a failed lookup. The **reversal
## flip is applied here** when `month` falls in the owning system's
## `reversal.summer_months` (§6.5 "Reversal at lookup"); pass `month <= 0` to
## read the raw stored (non-flipped) vector — only debug tooling should want
## that; gameplay always passes the real month.
func current_at(cell: Vector2i, month: int = -1) -> Dictionary:
	if not decode_ok or not _ensure_currents() or _width <= 0:
		return {}
	if cell.y < 0 or cell.y >= _height:
		return {}
	var index := int(_current_indices[cell.y * _width + posmod(cell.x, _width)])
	if index <= 0 or index > MAX_CURRENT_INDEX:
		return {}
	var dir_index := (index - 1) / 3
	var strength := (index - 1) % 3 + 1
	var dir_name := COMPASS_DIRS[dir_index]
	var member_key := Vector2i(posmod(cell.x, _width), cell.y)
	if month >= 1 and month <= 12 and _reversal_members.has(member_key):
		var member: Array = _reversal_members[member_key]
		# Flip only when the tile really resolves to the reversal system (same
		# strength — a stronger system may legally own the tile in the raster,
		# §6.5 overlap rules) AND the month is inside that system's
		# `reversal.summer_months` (§6.5 "Reversal at lookup").
		if int(member[0]) == strength and month in (member[1] as Array):
			dir_name = COMPASS_OPPOSITE[dir_index]
	return {"dir": dir_name, "strength": strength}


## Flow of the current at `cell` as a float vector: the unit compass vector
## scaled by the strength (magnitude 1..3, pointing downstream, reversal
## applied). Zero vector on a no-current tile. Convenience for drift/movement
## consumers; the per-strength daily drift *distance* table lives in
## `sailing_sim.gd` (`DRIFT_TILES_PER_DAY`, §4.16).
func current_vector_at(cell: Vector2i, month: int = -1) -> Vector2:
	var current := current_at(cell, month)
	if current.is_empty():
		return Vector2.ZERO
	var dir_index := COMPASS_DIRS.find(str(current["dir"]))
	if dir_index < 0:
		return Vector2.ZERO
	return COMPASS_VECTORS[dir_index] * float(current["strength"])


# --- Seasonal sea ice (§4.18) ------------------------------------------------

## True when at least one ice region is active in `month` (1..12). Months
## outside 1..12 are never icy.
func ice_active(month: int) -> bool:
	return not ice_active_regions(month).is_empty()


## Ids of the ice regions whose `months` window contains `month`.
func ice_active_regions(month: int) -> Array[String]:
	var out: Array[String] = []
	if month < 1 or month > 12:
		return out
	for region_raw in DataLoader.ice_regions_list:
		var region: Dictionary = region_raw if region_raw is Dictionary else {}
		var months: Array = (region as Dictionary).get("months", [])
		if month in months:
			out.append(str((region as Dictionary).get("id", "")))
	return out


## True when `cell` is water inside an ice polygon whose window contains
## `month` (§4.18: impassable to *entering* fleets in that month). The mask
## for the month is built on first query and memoized (see [_ice_masks]).
## Wrap-aware on x; y is bounded. A failed/empty data state is never icy.
func ice_blocks(cell: Vector2i, month: int) -> bool:
	if cell.y < 0 or cell.y >= GRID_HEIGHT:
		return false
	var mask := ice_mask_for(month)
	if mask.is_empty():
		return false
	return mask.has(Vector2i(posmod(cell.x, GRID_WIDTH), cell.y))


## The memoized month mask: `{Vector2i: true}` over the polygon interiors.
func ice_mask_for(month: int) -> Dictionary:
	if month < 1 or month > 12:
		return {}
	if _ice_masks.has(month):
		return _ice_masks[month]
	var mask := {}
	for region_raw in DataLoader.ice_regions_list:
		var region: Dictionary = region_raw if region_raw is Dictionary else {}
		var months: Array = (region as Dictionary).get("months", [])
		if not (month in months):
			continue
		var polygon: Array = (region as Dictionary).get("polygon", [])
		for span in _ring_spans(polygon):
			var y := int(span["y"])
			if y < 0 or y >= GRID_HEIGHT:
				continue
			var x := int(span["x0"])
			for _i in int(span["width"]):
				mask[Vector2i(posmod(x, GRID_WIDTH), y)] = true
				x += 1
	_ice_masks[month] = mask
	return mask


## Even-odd scanline fill sampled at tile centres (the `build_world.py` /
## `build_ocean.py` algorithm ported exactly): `ring` is a closed
## `[[lat, lon], …]` polygon (first pair repeated last), longitudes unwrapped
## across the antimeridian, spans wrapped modulo the grid width by the caller.
## Returns `[{y, x0, width}]` in unwrapped tile coordinates.
static func _ring_spans(ring: Array) -> Array:
	var out: Array = []
	var n := ring.size()
	if n < 3:
		return out
	var lons := _unwrap_ring(ring)
	var tpd := float(GRID_WIDTH) / 360.0
	var xs: Array[float] = []
	var ys: Array[float] = []
	for i in n:
		var pair: Array = ring[i]
		xs.append((lons[i] + 180.0) * tpd)
		ys.append((90.0 - float(pair[0])) * tpd)
	var y_lo: float = maxf(0.0, ys.min())
	var y_hi: float = minf(float(GRID_HEIGHT), ys.max())
	if y_hi <= y_lo:
		return out
	var row_lo := maxi(0, int(ceil(y_lo - 0.5)))
	var row_hi := mini(GRID_HEIGHT - 1, int(ceil(y_hi - 0.5)) - 1)

	var edges: Array = []  # [x_at_top, y_top, dx/dy], normalized top → bottom
	var buckets: Dictionary = {}
	for i in n:
		var j := (i + 1) % n
		var x0: float = xs[i]
		var y0: float = ys[i]
		var x1: float = xs[j]
		var y1: float = ys[j]
		if y0 == y1:
			continue
		if y0 < y1:
			var xa := x0
			var ya := y0
			var xb := x1
			var yb := y1
			_push_edge(edges, buckets, xa, ya, xb, yb, row_lo, row_hi)
		else:
			_push_edge(edges, buckets, x1, y1, x0, y0, row_lo, row_hi)

	for r in buckets.keys():
		var py := float(r) + 0.5
		var crossings: Array[float] = []
		for edge_index in buckets[r]:
			var edge: Array = edges[edge_index]
			crossings.append(float(edge[0]) + (py - float(edge[1])) * float(edge[2]))
		crossings.sort()
		var k := 0
		while k + 1 < crossings.size():
			var c0 := int(ceil(crossings[k] - 0.5))
			var c1 := int(ceil(crossings[k + 1] - 0.5)) - 1
			if c1 >= c0:
				out.append({"y": r, "x0": c0, "width": c1 - c0 + 1})
			k += 2
	return out


static func _push_edge(edges: Array, buckets: Dictionary, xa: float, ya: float,
		xb: float, yb: float, row_lo: int, row_hi: int) -> void:
	var r_start := maxi(row_lo, int(ceil(ya - 0.5)))
	var r_end := mini(row_hi, int(ceil(yb - 0.5)) - 1)
	if r_start > r_end:
		return
	var index := edges.size()
	edges.append([xa, ya, (xb - xa) / (yb - ya)])
	for r in range(r_start, r_end + 1):
		if not buckets.has(r):
			buckets[r] = []
		buckets[r].append(index)


## Longitudes of a ring, made continuous across the antimeridian (the
## `build_world.unwrap_ring` port): each vertex takes the nearest continuation
## of the previous one, so a dateline-crossing ring rasterizes in one frame.
static func _unwrap_ring(ring: Array) -> Array[float]:
	var lons: Array[float] = []
	var prev := 0.0
	var offset := 0.0
	var first := true
	for pair in ring:
		var value := float(pair[1]) + offset
		if not first:
			while value - prev > 180.0:
				value -= 360.0
				offset -= 360.0
			while value - prev < -180.0:
				value += 360.0
				offset += 360.0
		lons.append(value)
		prev = value
		first = false
	return lons


# --- Reversal membership (built once at load) --------------------------------

## Rebuilds the corridor geometry of every reversal system so a lookup can
## tell which raster tile belongs to one (see the class docstring). This is
## the `tools/build_ocean.py` `chain_between` + Chebyshev-dilation port — the
## same 1/20-tile sampling, diagonal bridging and wrap handling, minus the
## water test (membership on a land tile is harmless: the raster index there
## is 0 and `current_at` returns empty before the flip is ever consulted).
func _build_reversal_index() -> void:
	_reversal_members = {}
	_reversal_months = {}
	for system_raw in DataLoader.ocean_currents_list:
		var system: Dictionary = system_raw if system_raw is Dictionary else {}
		var reversal: Dictionary = (system as Dictionary).get("reversal", {})
		if reversal.is_empty():
			continue
		var summer: Array = (reversal as Dictionary).get("summer_months", [])
		if summer.is_empty():
			continue
		var system_id := str((system as Dictionary).get("id", ""))
		var strength := int((system as Dictionary).get("strength", 0))
		var path: Array = (system as Dictionary).get("path", [])
		var width_tiles := int((system as Dictionary).get("width_tiles", 1))
		var radius := maxi(0, (width_tiles - 1) / 2)
		var chain := _corridor_chain(path)
		for tile in chain:
			for dy in range(-radius, radius + 1):
				var y: int = tile.y + dy
				if y < 0 or y >= GRID_HEIGHT:
					continue
				for dx in range(-radius, radius + 1):
					_reversal_members[Vector2i(
						posmod(tile.x + dx, GRID_WIDTH), y)] = [strength, summer]
		_reversal_months[system_id] = summer


## The builder's `corridor_tiles` chain: every path segment stepped tile by
## tile (1/20-tile sampling, diagonal moves bridged orthogonally), x wrapping.
static func _corridor_chain(path: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if path.size() < 1:
		return out
	var prev := _tile_of_latlon(path[0][0], path[0][1])
	out.append(prev)
	for i in range(path.size() - 1):
		var a := _tile_of_latlon(path[i][0], path[i][1])
		var b := _tile_of_latlon(path[i + 1][0], path[i + 1][1])
		# `b`'s x shifted to the nearest continuation of `a` (|dx| ≤ w/2).
		var ux := float(b.x)
		while ux - a.x > GRID_WIDTH / 2.0:
			ux -= GRID_WIDTH
		while ux - a.x < -GRID_WIDTH / 2.0:
			ux += GRID_WIDTH
		var steps := maxi(1, int(ceil(maxf(absf(ux - a.x), absf(b.y - a.y)) * 20.0)))
		for step in range(1, steps + 1):
			var t := float(step) / float(steps)
			var cx := a.x + (ux - a.x) * t
			var cy := float(a.y) + float(b.y - a.y) * t
			var tile := Vector2i(
				int(floor(cx)) % GRID_WIDTH,
				clampi(int(floor(cy)), 0, GRID_HEIGHT - 1)
			)
			if tile == prev:
				continue
			if tile.x != prev.x and tile.y != prev.y:
				var bridge := Vector2i(tile.x, prev.y)
				if out.is_empty() or out[out.size() - 1] != bridge:
					out.append(bridge)
			if out.is_empty() or out[out.size() - 1] != tile:
				out.append(tile)
			prev = tile
	return out


## Grid cell containing a WGS84 point — the shared §6.1 projection.
static func _tile_of_latlon(lat: float, lon: float) -> Vector2i:
	var tpd := float(GRID_WIDTH) / 360.0
	var x := int(floor((lon + 180.0) * tpd)) % GRID_WIDTH
	var y := clampi(int(floor((90.0 - lat) * tpd)), 0, GRID_HEIGHT - 1)
	return Vector2i(x, y)
