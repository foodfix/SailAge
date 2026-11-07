class_name WaterlineFx
extends RefCounted
## The fleet waterline & wake VFX runtime contract (80-* §4.8 2026-11-07,
## top-down VFX revision — same day): the committed frame table
## `assets/ui/fx/fx_waterline.json` — written by
## `build_ui_art --import-fx-pixellab` from the PixelLab v4 pro game packs —
## drives every fleet token's BACK/FRONT sheet sandwich on the world map.
## The family is ONE north family per ship SIZE (32/48/64, the tier canvas
## table); ships rotate at runtime, so the whole sandwich (back → hull →
## front) rotates together around the token center and only the north
## family ever exists.
## Pure lookups and closed-form arithmetic only: no scene nodes, no
## re-simulation, no I/O past the one table read (render-only; the day-tick
## budget is untouched).
##
## Layer placement (the pack README's `anchor + offset` rule with the
## anchor resolved into the size's token box at ingest): the layer's
## top-left is `token_box_top_left + (anchor_sprite + clip_offset)` —
## native scale, no reference rescale (each size's sheets are authored
## around that size's representative hull: latin 32, caravel 48, galleass
## 64). Sheet PNGs are horizontal-ish grids (`columns` per row) cut with
## `atlas_region`; ids resolve through the registry's lazy raw-bytes
## family (`fx_waterline_{layer}_{size}`).
##
## The size key is the ship's token canvas width (the tier table baked
## into the shipped files) — callers pass `texture.get_width()`; no data
## read, no schema coupling.

const TABLE_PATH := "res://assets/ui/fx/fx_waterline.json"

static var _table: Dictionary = {}
## The suite seam (the texture_registry `_token_dir` precedent): tests
## re-point it at a fixture table to prove the contract without touching
## `assets/`. Production never reassigns it.
static var _table_path := TABLE_PATH


## The committed table (one read, cached; missing file ⇒ {} — every
## consumer treats an empty table as "no fx", the flat fallback rule).
static func table() -> Dictionary:
	if _table.is_empty() and FileAccess.file_exists(_table_path):
		var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(_table_path))
		if parsed is Dictionary:
			_table = parsed
	return _table


## Test seam: drop the cached table (suites re-point nothing — the table
## is read-only data; the reset exists for isolated-parse assertions).
static func _reset_for_tests() -> void:
	_table = {}
	_table_path = TABLE_PATH


static func has(size: int) -> bool:
	return size > 0 and table().get("sizes", {}).has(str(size))


## One size's geometry: `{fps, frame_ms, frames, loop, anchor_sprite,
## layers: {back: {frame, columns, offset}, front: {...}}}` or {} when
## the size (or the table) is absent — callers hide the fx for that fleet.
static func geometry(size: int) -> Dictionary:
	var d: Variant = table().get("sizes", {}).get(str(size), {})
	return d if d is Dictionary else {}


## The closed-form frame index at `t_ms` (uniform frame_ms pinned at
## ingest — non-uniform packs fail the ingest, so integer division is
## exact). Phase offsets just shift `t_ms`.
static func frame_at(size: int, t_ms: int) -> int:
	var g := geometry(size)
	if g.is_empty():
		return -1
	var frames := int(g.get("frames", 0))
	var frame_ms := int(g.get("frame_ms", 0))
	if frames <= 0 or frame_ms <= 0:
		return -1
	return int(t_ms / float(frame_ms)) % frames


## One sheet cell: frame `i` in the `columns`-per-row grid of `layer`.
static func atlas_region(size: int, layer: String, frame: int) -> Rect2:
	var g := geometry(size)
	if g.is_empty():
		return Rect2()
	var clip: Dictionary = g.get("layers", {}).get(layer, {})
	if clip.is_empty():
		return Rect2()
	var w := float((clip.get("frame", {}) as Dictionary).get("w", 0.0))
	var h := float((clip.get("frame", {}) as Dictionary).get("h", 0.0))
	var columns := int(clip.get("columns", 1))
	if w <= 0.0 or h <= 0.0 or columns <= 0 or frame < 0:
		return Rect2()
	return Rect2(float(frame % columns) * w, float(frame / columns) * h,
		w, h)


## The registry id of one layer's sheet (`fx_waterline_{layer}_{size}`).
static func layer_id(size: int, layer: String) -> String:
	return "fx_waterline_%s_%d" % [layer, size]


## Box-local top-left of one layer (native scale — the v4 sheets are
## authored per size; no reference rescale): the vector from the size-S
## token box's top-left to the sheet frame's top-left. Add the token
## box's position to place the rect under a marker/token node.
static func layer_offset_px(size: int, layer: String) -> Vector2:
	var g := geometry(size)
	if g.is_empty():
		return Vector2.ZERO
	var clip: Dictionary = g.get("layers", {}).get(layer, {})
	var anchor: Dictionary = g.get("anchor_sprite", {})
	if clip.is_empty() or anchor.is_empty():
		return Vector2.ZERO
	return Vector2(
		float(anchor.get("x", 0.0))
			+ float((clip.get("offset", {}) as Dictionary).get("x", 0.0)),
		float(anchor.get("y", 0.0))
			+ float((clip.get("offset", {}) as Dictionary).get("y", 0.0)))


## One layer's on-screen rect size (native scale).
static func layer_size_px(size: int, layer: String) -> Vector2:
	var g := geometry(size)
	var clip: Dictionary = g.get("layers", {}).get(layer, {}) \
		if not g.is_empty() else {}
	var frame: Dictionary = clip.get("frame", {}) if not clip.is_empty() \
		else {}
	if frame.is_empty():
		return Vector2.ZERO
	return Vector2(float(frame.get("w", 0.0)), float(frame.get("h", 0.0)))
