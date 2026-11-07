class_name WaterlineFx
extends RefCounted
## The fleet waterline & wake VFX runtime contract (80-* §4.8 2026-11-07):
## the committed frame table `assets/ui/fx/fx_waterline.json` — written by
## `build_ui_art --import-fx-pixellab` from the PixelLab v3 pro game packs —
## drives every fleet token's BACK/FRONT sheet sandwich on the world map.
## Pure lookups and closed-form arithmetic only: no scene nodes, no
## re-simulation, no I/O past the one table read (render-only; the day-tick
## budget is untouched).
##
## Layer placement (the pack README's `anchor + offset` rule with the
## anchor resolved into the 64 token box at ingest): the layer's top-left
## is `token_box_top_left + (anchor_sprite + clip_offset) * scale`, where
## scale = cell_px / 64 (the sheets are authored around the 64 px galleass
## reference). Sheet PNGs are horizontal-ish grids (`columns` per row) cut
## with `atlas_region`; ids resolve through the registry's lazy raw-bytes
## family (`fx_waterline_{layer}_{dir}`).

const TABLE_PATH := "res://assets/ui/fx/fx_waterline.json"
const BASE_CELL_PX := 64.0

static var _table: Dictionary = {}


## The committed table (one read, cached; missing file ⇒ {} — every
## consumer treats an empty table as "no fx", the flat fallback rule).
static func table() -> Dictionary:
	if _table.is_empty() and FileAccess.file_exists(TABLE_PATH):
		var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(TABLE_PATH))
		if parsed is Dictionary:
			_table = parsed
	return _table


## Test seam: drop the cached table (suites re-point nothing — the table
## is read-only data; the reset exists for isolated-parse assertions).
static func _reset_for_tests() -> void:
	_table = {}


static func has(dir_id: String) -> bool:
	return not dir_id.is_empty() and table().get("dirs", {}).has(dir_id)


## One dir's geometry: `{fps, frame_ms, frames, loop, anchor_sprite,
## layers: {back: {frame, columns, offset}, front: {...}}}` or {} when
## the dir (or the table) is absent — callers hide the fx for that fleet.
static func geometry(dir_id: String) -> Dictionary:
	var d: Variant = table().get("dirs", {}).get(dir_id, {})
	return d if d is Dictionary else {}


## The closed-form frame index at `t_ms` (uniform frame_ms pinned at
## ingest — non-uniform packs fail the ingest, so integer division is
## exact). Phase offsets just shift `t_ms`.
static func frame_at(dir_id: String, t_ms: int) -> int:
	var g := geometry(dir_id)
	if g.is_empty():
		return -1
	var frames := int(g.get("frames", 0))
	var frame_ms := int(g.get("frame_ms", 0))
	if frames <= 0 or frame_ms <= 0:
		return -1
	return int(t_ms / float(frame_ms)) % frames


## One sheet cell: frame `i` in the `columns`-per-row grid of `layer`.
static func atlas_region(dir_id: String, layer: String, frame: int) -> Rect2:
	var g := geometry(dir_id)
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


## The registry id of one layer's sheet (`fx_waterline_{layer}_{dir}`).
static func layer_id(dir_id: String, layer: String) -> String:
	return "fx_waterline_%s_%s" % [layer, dir_id]


## Box-local top-left of one layer, scaled for `cell_px`: the vector from
## the 64 px token box's top-left to the sheet frame's top-left. Add the
## token box's position to place the rect under a marker/token node.
static func layer_offset_px(dir_id: String, layer: String,
		cell_px: float) -> Vector2:
	var g := geometry(dir_id)
	if g.is_empty():
		return Vector2.ZERO
	var clip: Dictionary = g.get("layers", {}).get(layer, {})
	var anchor: Dictionary = g.get("anchor_sprite", {})
	if clip.is_empty() or anchor.is_empty():
		return Vector2.ZERO
	var k := cell_px / BASE_CELL_PX
	var anchor_v := Vector2(float(anchor.get("x", 0.0)),
		float(anchor.get("y", 0.0)))
	var off_v := Vector2(float((clip.get("offset", {}) as Dictionary)
		.get("x", 0.0)), float((clip.get("offset", {}) as Dictionary)
		.get("y", 0.0)))
	return (anchor_v + off_v) * k


## One layer's on-screen rect size, scaled for `cell_px`.
static func layer_size_px(dir_id: String, layer: String,
		cell_px: float) -> Vector2:
	var g := geometry(dir_id)
	var clip: Dictionary = g.get("layers", {}).get(layer, {}) \
		if not g.is_empty() else {}
	var frame: Dictionary = clip.get("frame", {}) if not clip.is_empty() \
		else {}
	if frame.is_empty():
		return Vector2.ZERO
	var k := cell_px / BASE_CELL_PX
	return Vector2(float(frame.get("w", 0.0)), float(frame.get("h", 0.0))) * k
