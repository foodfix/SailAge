extends Node
## The fleet waterline VFX contract suite (80-* §4.8 2026-11-07).
## Headless:
##
##   godot --headless res://tools/test_waterline_fx.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Pins the committed contract directly (the repo's test discipline — assert
## the constant/closed form, never re-derive):
##   1  the committed frame table `assets/ui/fx/fx_waterline.json`: 8 dirs,
##      per dir 8 uniform frames, loop, frame_ms > 0, anchor inside the 64
##      box, back+front layers with positive frames/columns and integer
##      offsets;
##   2  registry resolution: all 16 `fx_waterline_{back,front}_{dir}` ids
##      resolve textures through the lazy raw-bytes path (file replace +
##      restart seam — no `.import` sidecars);
##   3  `frame_at` closed form: 0 at t=0, +1 per frame_ms, wraps at the
##      cycle, phase shifts land other frames, unknown dir ⇒ −1;
##   4  `atlas_region` grid math: frame i sits at column i%cols, row i/cols;
##   5  layer placement: box-local offset == (anchor_sprite + clip offset)
##      and size == frame px at the 64 base, exact ×2 at a 128 px cell;
##   6  missing-dir safety: every lookup degrades to its empty value.

const WaterlineFxLib := preload("res://scripts/world/waterline_fx.gd")
const UiKitLib := preload("res://scripts/ui_kit.gd")
const RegistryLib := preload("res://scripts/ui/texture_registry.gd")

const DIRS := ["n", "ne", "e", "se", "s", "sw", "w", "nw"]

var _checks := 0
var _failures: Array[String] = []


func _ready() -> void:
	_test_table_contract()
	_test_registry_resolution()
	_test_frame_at()
	_test_atlas_region()
	_test_placement()
	_test_missing_dir_safety()
	_report()


# --- 1  the committed table -------------------------------------------------

func _test_table_contract() -> void:
	var table: Dictionary = WaterlineFxLib.table()
	_check(not table.is_empty(),
		"the committed fx frame table loads (assets/ui/fx/fx_waterline.json)")
	var dirs: Dictionary = table.get("dirs", {})
	_check(dirs.size() == 8, "the table carries exactly 8 dirs")
	for d: String in DIRS:
		var g := WaterlineFxLib.geometry(d)
		_check(not g.is_empty(), "dir %s is in the table" % d)
		if g.is_empty():
			continue
		_check(int(g.get("frames", 0)) == 8,
			"dir %s pins 8 frames (80-* §4.8 2026-11-07)" % d)
		_check(int(g.get("frame_ms", 0)) > 0,
			"dir %s frame_ms > 0" % d)
		_check(bool(g.get("loop", false)), "dir %s loops" % d)
		var anchor: Dictionary = g.get("anchor_sprite", {})
		_check(int(anchor.get("x", -1)) >= 0 and int(anchor.get("x", -1)) <= 64
			and int(anchor.get("y", -1)) >= 0 and int(anchor.get("y", -1)) <= 64,
			"dir %s anchor sits inside the 64 box" % d)
		for layer: String in ["back", "front"]:
			var clip: Dictionary = g.get("layers", {}).get(layer, {})
			_check(int(clip.get("frame", {}).get("w", 0)) > 0
				and int(clip.get("frame", {}).get("h", 0)) > 0,
				"dir %s %s frame px > 0" % [d, layer])
			_check(int(clip.get("columns", 0)) > 0,
				"dir %s %s columns > 0" % [d, layer])
			var off: Dictionary = clip.get("offset", {})
			_check(off.has("x") and off.has("y"),
				"dir %s %s carries the pack offset" % [d, layer])


# --- 2  registry resolution --------------------------------------------------

func _test_registry_resolution() -> void:
	RegistryLib.ensure_registered()
	for d: String in DIRS:
		for layer: String in ["back", "front"]:
			var tex := UiKitLib.icon_texture(
				WaterlineFxLib.layer_id(d, layer))
			_check(tex != null,
				"%s resolves through the lazy raw-bytes registry"
					% WaterlineFxLib.layer_id(d, layer))


# --- 3  frame_at closed form -------------------------------------------------

func _test_frame_at() -> void:
	var g := WaterlineFxLib.geometry("e")
	var frame_ms := int(g.get("frame_ms", 0))
	var frames := int(g.get("frames", 0))
	_check(WaterlineFxLib.frame_at("e", 0) == 0, "frame_at(e, 0) == 0")
	_check(WaterlineFxLib.frame_at("e", frame_ms - 1) == 0,
		"frame_at(e, frame_ms − 1) == 0")
	_check(WaterlineFxLib.frame_at("e", frame_ms) == 1,
		"frame_at(e, frame_ms) == 1")
	_check(WaterlineFxLib.frame_at("e", frame_ms * (frames - 1))
		== frames - 1, "frame_at(e, last frame start) == frames − 1")
	_check(WaterlineFxLib.frame_at("e", frame_ms * frames) == 0,
		"frame_at(e, cycle) wraps to 0")
	_check(WaterlineFxLib.frame_at("e", frame_ms * frames * 10
		+ frame_ms * 3) == 3,
		"a phase offset of whole cycles + 3 frames lands frame 3")


# --- 4  atlas_region grid math ------------------------------------------------

func _test_atlas_region() -> void:
	var clip: Dictionary = WaterlineFxLib.geometry("e").get("layers",
		{}).get("back", {})
	var w := float(clip.get("frame", {}).get("w", 0.0))
	var h := float(clip.get("frame", {}).get("h", 0.0))
	var columns := int(clip.get("columns", 1))
	var r0 := WaterlineFxLib.atlas_region("e", "back", 0)
	_check(r0 == Rect2(0, 0, w, h), "region 0 is the first cell")
	var i := 5
	var r5 := WaterlineFxLib.atlas_region("e", "back", i)
	_check(r5 == Rect2(float(i % columns) * w, float(i / columns) * h, w, h),
		"region 5 sits at column %d, row %d of the %d-col grid"
			% [i % columns, i / columns, columns])


# --- 5  layer placement -------------------------------------------------------

func _test_placement() -> void:
	var g := WaterlineFxLib.geometry("e")
	var anchor: Dictionary = g.get("anchor_sprite", {})
	var off: Dictionary = g.get("layers", {}).get("back", {}).get("offset", {})
	var expected := Vector2(float(anchor.get("x", 0)) + float(off.get("x", 0)),
		float(anchor.get("y", 0)) + float(off.get("y", 0)))
	_check(WaterlineFxLib.layer_offset_px("e", "back", 64.0) == expected,
		"box-local back offset == anchor + clip offset at the 64 base")
	_check(WaterlineFxLib.layer_offset_px("e", "back", 128.0) == expected * 2.0,
		"the offset scales ×2 at a 128 px cell")
	var frame: Dictionary = g.get("layers", {}).get("front", {}).get("frame", {})
	var size := Vector2(float(frame.get("w", 0)), float(frame.get("h", 0)))
	_check(WaterlineFxLib.layer_size_px("e", "front", 64.0) == size,
		"front size == frame px at the 64 base")
	_check(WaterlineFxLib.layer_size_px("e", "front", 32.0) == size * 0.5,
		"the size scales ×0.5 at a 32 px cell")


# --- 6  missing-dir safety ------------------------------------------------------

func _test_missing_dir_safety() -> void:
	_check(not WaterlineFxLib.has("zz"), "unknown dir: has == false")
	_check(WaterlineFxLib.geometry("zz").is_empty(),
		"unknown dir: geometry == {}")
	_check(WaterlineFxLib.frame_at("zz", 100) == -1,
		"unknown dir: frame_at == −1")
	_check(WaterlineFxLib.atlas_region("zz", "back", 0) == Rect2(),
		"unknown dir: atlas_region == Rect2()")
	_check(WaterlineFxLib.layer_offset_px("zz", "back", 64.0) == Vector2.ZERO,
		"unknown dir: layer_offset == ZERO")
	_check(WaterlineFxLib.layer_size_px("zz", "front", 64.0) == Vector2.ZERO,
		"unknown dir: layer_size == ZERO")


# --- Harness ----------------------------------------------------------------

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
