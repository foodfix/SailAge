extends Node
## The fleet waterline VFX contract suite (80-* §4.8 2026-11-07,
## single-layer revision — ONE wake sheet per ship size, rendered UNDER
## the hull). Headless:
##
##   godot --headless res://tools/test_waterline_fx.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## Pins the contracts directly (the repo's test discipline — assert the
## constant/closed form, never re-derive):
##   1  pure lookups on a FIXTURE table through the `_table_path` seam
##      (the texture_registry `_token_dir` precedent): `has`/`geometry`/
##      `frame_at`/`atlas_region`/`sheet_offset_px`/`sheet_size_px` on the
##      v3 per-size single-sheet shape with known constants;
##   2  `frame_at` closed form: 0 at t=0, +1 per frame_ms, wraps at the
##      cycle, phase shifts land other frames, unknown size ⇒ −1;
##   3  `atlas_region` grid math: frame i sits at column i%cols, row i/cols;
##   4  sheet placement: box-local offset == (anchor_sprite + clip offset)
##      and size == frame px, NATIVE scale (no reference rescale — each
##      size's sheet is authored around that size's representative hull);
##   5  missing-size safety: every lookup degrades to its empty value;
##   6  the committed table `assets/ui/fx/fx_waterline.json`: version 3,
##      exactly the sizes {32, 48, 64}, per size 8 uniform frames, loop,
##      frame_ms > 0, anchor inside its size box, one `sheet` record — and
##      the 3 `fx_waterline_{size}` ids resolve textures through the lazy
##      raw-bytes registry (file replace + restart seam — no `.import`
##      sidecars). Green only once the v5 family has been generated +
##      ingested (the W5 gate).

const WaterlineFxLib := preload("res://scripts/world/waterline_fx.gd")
const UiKitLib := preload("res://scripts/ui_kit.gd")
const RegistryLib := preload("res://scripts/ui/texture_registry.gd")

const SIZES := [32, 48, 64]

# The fixture table (v3 per-size single-sheet shape, known constants):
# the 48 family carries frames=8, frame_ms=125, columns=4, frame 24x18,
# anchor (10,12), sheet offset (-6, -4).
const FIXTURE := {
	"version": 3,
	"sizes": {
		"48": {
			"canvas": {"w": 64, "h": 40},
			"fps": 8.0, "frame_ms": 125, "frames": 8, "loop": true,
			"anchor_sprite": {"x": 10, "y": 12, "method": "fixture"},
			"sheet": {"file": "fx_waterline_48.png",
				"frame": {"w": 24, "h": 18}, "columns": 4,
				"frames": 8, "offset": {"x": -6, "y": -4}},
		},
	},
}

var _checks := 0
var _failures: Array[String] = []


func _ready() -> void:
	_test_fixture_lookups()
	_test_frame_at()
	_test_atlas_region()
	_test_placement()
	_test_missing_size_safety()
	_test_committed_table_contract()
	_report()


# --- 1  fixture lookups (the seam) -------------------------------------------

func _test_fixture_lookups() -> void:
	var path := "user://waterline_fx_fixture.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(FIXTURE))
	f.close()
	WaterlineFxLib._reset_for_tests()
	WaterlineFxLib._table_path = path
	_check(WaterlineFxLib.has(48), "fixture: has(48)")
	_check(not WaterlineFxLib.has(64),
		"fixture: an absent size reports has == false")
	var g := WaterlineFxLib.geometry(48)
	_check(int(g.get("frame_ms", 0)) == 125, "fixture: geometry(48).frame_ms")
	_check(g.get("sheet", {}).get("columns", 0) == 4,
		"fixture: geometry(48).sheet.columns")
	_check(WaterlineFxLib.sheet_id(48) == "fx_waterline_48",
		"sheet_id is fx_waterline_{size}")
	WaterlineFxLib._reset_for_tests()


# --- 2  frame_at closed form (on the fixture) --------------------------------

func _test_frame_at() -> void:
	WaterlineFxLib._reset_for_tests()
	WaterlineFxLib._table_path = "user://waterline_fx_fixture.json"
	_check(WaterlineFxLib.frame_at(48, 0) == 0, "frame_at(48, 0) == 0")
	_check(WaterlineFxLib.frame_at(48, 124) == 0,
		"frame_at(48, frame_ms − 1) == 0")
	_check(WaterlineFxLib.frame_at(48, 125) == 1,
		"frame_at(48, frame_ms) == 1")
	_check(WaterlineFxLib.frame_at(48, 125 * 7) == 7,
		"frame_at(48, last frame start) == frames − 1")
	_check(WaterlineFxLib.frame_at(48, 125 * 8) == 0,
		"frame_at(48, cycle) wraps to 0")
	_check(WaterlineFxLib.frame_at(48, 125 * 8 * 10 + 125 * 3) == 3,
		"a phase offset of whole cycles + 3 frames lands frame 3")
	WaterlineFxLib._reset_for_tests()


# --- 3  atlas_region grid math (on the fixture) -------------------------------

func _test_atlas_region() -> void:
	WaterlineFxLib._table_path = "user://waterline_fx_fixture.json"
	var r0 := WaterlineFxLib.atlas_region(48, 0)
	_check(r0 == Rect2(0, 0, 24, 18), "region 0 is the first cell")
	var r5 := WaterlineFxLib.atlas_region(48, 5)
	_check(r5 == Rect2(24.0, 18.0, 24, 18),
		"region 5 sits at column 1, row 1 of the 4-col grid")
	var r7 := WaterlineFxLib.atlas_region(48, 7)
	_check(r7 == Rect2(3 * 24.0, 1 * 18.0, 24, 18),
		"region 7 of a 4-col grid sits at column 3, row 1")
	WaterlineFxLib._reset_for_tests()


# --- 4  sheet placement (native scale — the v5 pin) ---------------------------

func _test_placement() -> void:
	WaterlineFxLib._table_path = "user://waterline_fx_fixture.json"
	_check(WaterlineFxLib.sheet_offset_px(48) == Vector2(4.0, 8.0),
		"box-local sheet offset == anchor (10,12) + clip offset (−6,−4), "
		+ "native scale")
	_check(WaterlineFxLib.sheet_size_px(48) == Vector2(24, 18),
		"sheet size == frame px, native scale")
	WaterlineFxLib._reset_for_tests()


# --- 5  missing-size safety ----------------------------------------------------

func _test_missing_size_safety() -> void:
	_check(not WaterlineFxLib.has(0), "size 0: has == false")
	_check(WaterlineFxLib.geometry(0).is_empty(),
		"size 0: geometry == {}")
	_check(WaterlineFxLib.frame_at(0, 100) == -1,
		"size 0: frame_at == −1")
	_check(WaterlineFxLib.atlas_region(0, 0) == Rect2(),
		"size 0: atlas_region == Rect2()")
	_check(WaterlineFxLib.sheet_offset_px(0) == Vector2.ZERO,
		"size 0: sheet_offset == ZERO")
	_check(WaterlineFxLib.sheet_size_px(0) == Vector2.ZERO,
		"size 0: sheet_size == ZERO")


# --- 6  the committed table + registry (the W5 gate) ---------------------------

func _test_committed_table_contract() -> void:
	var table: Dictionary = WaterlineFxLib.table()
	_check(not table.is_empty(),
		"the committed fx frame table loads (assets/ui/fx/fx_waterline.json)")
	_check(int(table.get("version", 0)) == 3,
		"the committed table is the v3 single-layer shape")
	var sizes: Dictionary = table.get("sizes", {})
	_check(sizes.size() == 3,
		"the table carries exactly the 3 sizes (32/48/64)")
	for s: int in SIZES:
		var g := WaterlineFxLib.geometry(s)
		_check(not g.is_empty(), "size %d is in the table" % s)
		if g.is_empty():
			continue
		_check(int(g.get("frames", 0)) == 8,
			"size %d pins 8 frames (80-* §4.8 2026-11-07)" % s)
		_check(int(g.get("frame_ms", 0)) > 0,
			"size %d frame_ms > 0" % s)
		_check(bool(g.get("loop", false)), "size %d loops" % s)
		var anchor: Dictionary = g.get("anchor_sprite", {})
		_check(int(anchor.get("x", -1)) >= 0 and int(anchor.get("x", -1)) <= s
			and int(anchor.get("y", -1)) >= 0 and int(anchor.get("y", -1)) <= s,
			"size %d anchor sits inside its %d box" % [s, s])
		var clip: Dictionary = g.get("sheet", {})
		_check(int(clip.get("frame", {}).get("w", 0)) > 0
			and int(clip.get("frame", {}).get("h", 0)) > 0,
			"size %d sheet frame px > 0" % s)
		_check(int(clip.get("columns", 0)) > 0,
			"size %d sheet columns > 0" % s)
		var off: Dictionary = clip.get("offset", {})
		_check(off.has("x") and off.has("y"),
			"size %d sheet carries the pack offset" % s)
	RegistryLib.ensure_registered()
	for s: int in SIZES:
		var tex := UiKitLib.icon_texture(WaterlineFxLib.sheet_id(s))
		_check(tex != null,
			"%s resolves through the lazy raw-bytes registry"
				% WaterlineFxLib.sheet_id(s))


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
