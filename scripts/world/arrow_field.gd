class_name ArrowField
extends RefCounted
## The S3 wind/current arrow-field sampler (docs/80-UI-UX.md §4.8.10 — pure;
## IMPLEMENT-Phase10.md §3). No nodes, no GameState, no rendering: it samples
## the decoded ocean layers on a fixed lattice over a tile window and returns
## plain dicts. The world scene owns toggles, re-sample triggers and drawing.
##
## Spec (§4.8.10, locked):
##   * stride 4×4 tiles over the visible window + apron, water cells only;
##   * wind arrow = the month's `prevailing_for(cell, month)` (the Phase-6
##     wind-region raster, `10-*` §6.5) — a `VAR` cell carries
##     `variable = true` and no dir id (the chart's distinctive glyph rule);
##   * current arrow = the decoded, REVERSAL-APPLIED current vector
##     (`20-*` §4.16, `OceanLayers.current_vector_at`) bucketed to the
##     §4.8.6 dir ids;
##   * colors wind `TEXT` / current `COAST_SEA` — the sprite pins, applied by
##     the renderer (the drawn-arrow fallback), not here.
##
## Dir ids follow §4.8.6: heading8 bucket 0 = east, increasing
## counterclockwise in the mathematical frame (screen y-down: (1,−1) = NE,
## (0,−1) = N …) → `e, ne, n, nw, w, sw, s, se`. The same table maps the S3
## player token (`hull_{type}_{owner}_{dir}`, §4.8.9) — one source for both
## so a sprite id can never disagree with a sampled arrow.

## Lattice stride in tiles (§4.8.10 "stride 4×4 tiles").
const STRIDE := 4
## Tiles of apron beyond the visible window on every side (one stride band
## plus one, so a step never shows the field's edge before the re-sample).
const APRON_TILES := 8

## §4.8.6 dir ids in heading8-bucket order (bucket 0 = east first).
const DIR_IDS: Array[String] = ["e", "ne", "n", "nw", "w", "sw", "s", "se"]
## The compass token of each bucket — the `20-*` §4.4 id set in the SAME
## bucket order (`60-*` §4.3a `HEADING_TOKENS`).
const HEADING_TOKENS: Array[String] = ["E", "NE", "N", "NW", "W", "SW", "S", "SE"]

## The nearest-compass-ray dot rays, bucket order (the §4.3a integer table,
## kept for the float-vector bucketing below).
const HEADING_RAYS: Array[Vector2] = [
	Vector2(1, 0), Vector2(1, -1), Vector2(0, -1), Vector2(-1, -1),
	Vector2(-1, 0), Vector2(-1, 1), Vector2(0, 1), Vector2(1, 1),
]


## The dir id of a heading8 bucket ("", out of range).
static func dir_id_of_bucket(bucket: int) -> String:
	if bucket < 0 or bucket >= DIR_IDS.size():
		return ""
	return DIR_IDS[bucket]


## The heading8 bucket of a compass token (-1 outside the §4.4 domain).
static func bucket_of_compass(token: String) -> int:
	return HEADING_TOKENS.find(token)


## The dir id of a compass token ("" outside the domain) — the §4.8.6 row.
static func dir_id_of_compass(token: String) -> String:
	return dir_id_of_bucket(bucket_of_compass(token))


## The dir id of a persisted 8-dir heading (`world.heading` values, guard-read
## by the caller) — "" when the heading is outside the 8-dir domain.
static func dir_id_of_heading(heading: String) -> String:
	return dir_id_of_compass(heading.to_upper())


## §4.3a heading8 bucket of a tile-space vector: nearest compass ray by the
## integer rule's cos² comparison (axis rays score 2·dot² to normalize the
## ray length; a positive dot required). Deterministic, never `atan2`.
## Returns -1 for the zero vector (no heading — the caller skips the cell),
## mirroring `BattleSim.heading8_of`'s "vel = (0,0) keeps the last heading".
static func bucket_of_vector(vector: Vector2) -> int:
	if vector == Vector2.ZERO:
		return -1
	var best := -1
	var best_score := -1.0
	for bucket in HEADING_RAYS.size():
		var ray := HEADING_RAYS[bucket]
		var dot := vector.dot(ray)
		if dot <= 0.0:
			continue
		var axis := ray.x == 0.0 or ray.y == 0.0
		var score := 2.0 * dot * dot if axis else dot * dot
		if score > best_score:
			best_score = score
			best = bucket
	return best


## Samples the field over the window centred on `center_cell` (`view_tiles`
## is the viewport size in tiles). Entries are `{cell, kind, dir_id, variable}`
## with `kind` ∈ `"wind"` / `"current"`, `cell` wrapped into
## `[0, grid_width) × [0, grid_height)`, sorted by `(y, x)` then kind —
## deterministic for a fixed decode. `ocean` is the decoded `OceanLayers`
## instance (its lookups answer their documented defaults on any failure);
## `is_water` is the water predicate (the loader's passability, injected to
## keep this module pure); `month` outside 1..12 samples the lookups' `VAR`
## fallbacks (the caller passes the real calendar month).
static func sample(center_cell: Vector2i, view_tiles: Vector2i, month: int,
		ocean, is_water: Callable, grid_width: int, grid_height: int) -> Array:
	if grid_width <= 0 or grid_height <= 0:
		return []
	var half_x := int(ceil(float(view_tiles.x) * 0.5)) + APRON_TILES
	var half_y := int(ceil(float(view_tiles.y) * 0.5)) + APRON_TILES
	# Anchor the lattice at multiples of the stride so the sampled cells are
	# world-anchored (the same tiles re-sample wherever the camera sits).
	var first_x := floor_div(center_cell.x - half_x, STRIDE) * STRIDE
	var first_y := maxi(floor_div(center_cell.y - half_y, STRIDE) * STRIDE, 0)
	var last_x := center_cell.x + half_x
	var last_y := mini(center_cell.y + half_y, grid_height - 1)
	var out: Array = []
	var y := first_y
	while y <= last_y:
		var x := first_x
		while x <= last_x:
			var cell := Vector2i(posmod(x, grid_width), y)
			if is_water.is_valid() and bool(is_water.call(cell)):
				_wind_entry(out, cell, month, ocean)
				_current_entry(out, cell, month, ocean)
			x += STRIDE
		y += STRIDE
	out.sort_custom(_entry_less)
	return out


static func _wind_entry(out: Array, cell: Vector2i, month: int, ocean) -> void:
	if ocean == null or not ocean.decode_ok:
		return
	var token := str(ocean.prevailing_for(cell, month))
	if token == "VAR":
		out.append({"cell": cell, "kind": "wind", "dir_id": "",
			"variable": true})
		return
	var dir_id := dir_id_of_compass(token)
	if dir_id.is_empty():
		return
	out.append({"cell": cell, "kind": "wind", "dir_id": dir_id,
		"variable": false})


static func _current_entry(out: Array, cell: Vector2i, month: int, ocean) -> void:
	if ocean == null or not ocean.currents_decoded or not ocean.currents_ok:
		return
	var vector: Vector2 = ocean.current_vector_at(cell, month)
	var bucket := bucket_of_vector(vector)
	if bucket < 0:
		return
	var dir_id := dir_id_of_bucket(bucket)
	if dir_id.is_empty():
		return
	out.append({"cell": cell, "kind": "current", "dir_id": dir_id,
		"variable": false})


static func _entry_less(a: Dictionary, b: Dictionary) -> bool:
	var ca: Vector2i = a["cell"]
	var cb: Vector2i = b["cell"]
	if ca.y != cb.y:
		return ca.y < cb.y
	if ca.x != cb.x:
		return ca.x < cb.x
	return str(a.get("kind", "")) < str(b.get("kind", ""))


static func floor_div(value: int, divisor: int) -> int:
	var quotient := value / divisor
	if (value % divisor) != 0 and ((value < 0) != (divisor < 0)):
		quotient -= 1
	return quotient
