extends Node
## The fleet waterline VFX contract suite (80-* §4.8 2026-11-08,
## per-ship wake revision — ONE wake sheet per SHIP TYPE, rendered UNDER
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
##      v4 per-ship single-sheet shape with known constants;
##   2  `frame_at` closed form: 0 at t=0, +1 per frame_ms, wraps at the
##      cycle, phase shifts land other frames, unknown ship ⇒ −1;
##   3  `atlas_region` grid math: frame i sits at column i%cols, row i/cols;
##   4  sheet placement: box-local offset == (anchor_sprite + clip offset)
##      and size == frame px, NATIVE scale (no reference rescale — each
##      ship's sheet is authored around that ship's own hull);
##   5  missing-ship safety: every lookup degrades to its empty value;
##   6  the committed table `assets/ui/fx/fx_waterline.json`: version 4,
##      exactly the 16 data/ship_types.json ids, per ship 8 uniform
##      frames, loop, frame_ms > 0, anchor inside the ship's own token
##      box, one `sheet` record — and the 16 `fx_waterline_{ship}` ids
##      resolve textures through the lazy raw-bytes registry (file
##      replace + restart seam — no `.import` sidecars). Green only once
##      the v6 family has been generated + ingested (the W6 gate).

const WaterlineFxLib := preload("res://scripts/world/waterline_fx.gd")
const UiKitLib := preload("res://scripts/ui_kit.gd")
const RegistryLib := preload("res://scripts/ui/texture_registry.gd")

# The 16 ship type ids (data/ship_types.json — the per-ship family keys).
const SHIPS: Array[String] = [
	"latin", "sloop", "caravel", "galley", "brigantine", "nao", "carrack",
	"galleon", "galiot", "galleass", "fluyt", "junk", "dhow", "pinnace",
	"caravela_redonda", "xebec",
]

# The fixture table (v4 per-ship single-sheet shape, known constants):
# the caravel family carries frames=8, frame_ms=125, columns=4, frame
# 24x18, anchor (10,12), sheet offset (-6, -4).
const FIXTURE := {
	"version": 4,
	"ships": {
		"caravel": {
			"canvas": {"w": 64, "h": 40},
			"fps": 8.0, "frame_ms": 125, "frames": 8, "loop": true,
			"anchor_sprite": {"x": 10, "y": 12, "method": "fixture"},
			"sheet": {"file": "fx_waterline_caravel.png",
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
	_test_missing_ship_safety()
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
	_check(WaterlineFxLib.has("caravel"), "fixture: has(caravel)")
	_check(not WaterlineFxLib.has("galleon"),
		"fixture: an absent ship reports has == false")
	var g := WaterlineFxLib.geometry("caravel")
	_check(int(g.get("frame_ms", 0)) == 125, "fixture: geometry(caravel).frame_ms")
	_check(g.get("sheet", {}).get("columns", 0) == 4,
		"fixture: geometry(caravel).sheet.columns")
	_check(WaterlineFxLib.sheet_id("caravel") == "fx_waterline_caravel",
		"sheet_id is fx_waterline_{ship}")
	WaterlineFxLib._reset_for_tests()


# --- 2  frame_at closed form (on the fixture) --------------------------------

func _test_frame_at() -> void:
	WaterlineFxLib._reset_for_tests()
	WaterlineFxLib._table_path = "user://waterline_fx_fixture.json"
	_check(WaterlineFxLib.frame_at("caravel", 0) == 0, "frame_at(caravel, 0) == 0")
	_check(WaterlineFxLib.frame_at("caravel", 124) == 0,
		"frame_at(caravel, frame_ms − 1) == 0")
	_check(WaterlineFxLib.frame_at("caravel", 125) == 1,
		"frame_at(caravel, frame_ms) == 1")
	_check(WaterlineFxLib.frame_at("caravel", 125 * 7) == 7,
		"frame_at(caravel, last frame start) == frames − 1")
	_check(WaterlineFxLib.frame_at("caravel", 125 * 8) == 0,
		"frame_at(caravel, cycle) wraps to 0")
	_check(WaterlineFxLib.frame_at("caravel", 125 * 8 * 10 + 125 * 3) == 3,
		"a phase offset of whole cycles + 3 frames lands frame 3")
	WaterlineFxLib._reset_for_tests()


# --- 3  atlas_region grid math (on the fixture) -------------------------------

func _test_atlas_region() -> void:
	WaterlineFxLib._table_path = "user://waterline_fx_fixture.json"
	var r0 := WaterlineFxLib.atlas_region("caravel", 0)
	_check(r0 == Rect2(0, 0, 24, 18), "region 0 is the first cell")
	var r5 := WaterlineFxLib.atlas_region("caravel", 5)
	_check(r5 == Rect2(24.0, 18.0, 24, 18),
		"region 5 sits at column 1, row 1 of the 4-col grid")
	var r7 := WaterlineFxLib.atlas_region("caravel", 7)
	_check(r7 == Rect2(3 * 24.0, 1 * 18.0, 24, 18),
		"region 7 of a 4-col grid sits at column 3, row 1")
	WaterlineFxLib._reset_for_tests()


# --- 4  sheet placement (native scale — the v6 pin) ---------------------------

func _test_placement() -> void:
	WaterlineFxLib._table_path = "user://waterline_fx_fixture.json"
	_check(WaterlineFxLib.sheet_offset_px("caravel") == Vector2(4.0, 8.0),
		"box-local sheet offset == anchor (10,12) + clip offset (−6,−4), "
		+ "native scale")
	_check(WaterlineFxLib.sheet_size_px("caravel") == Vector2(24, 18),
		"sheet size == frame px, native scale")
	WaterlineFxLib._reset_for_tests()


# --- 5  missing-ship safety ----------------------------------------------------

func _test_missing_ship_safety() -> void:
	# Runs on the production path (the reset above restores TABLE_PATH) —
	# the ids below can never be table keys ("" and a non-ship id).
	_check(not WaterlineFxLib.has(""), "empty ship id: has == false")
	_check(not WaterlineFxLib.has("__absent__"),
		"absent ship id: has == false")
	_check(WaterlineFxLib.geometry("__absent__").is_empty(),
		"absent ship id: geometry == {}")
	_check(WaterlineFxLib.frame_at("__absent__", 100) == -1,
		"absent ship id: frame_at == −1")
	_check(WaterlineFxLib.atlas_region("__absent__", 0) == Rect2(),
		"absent ship id: atlas_region == Rect2()")
	_check(WaterlineFxLib.sheet_offset_px("__absent__") == Vector2.ZERO,
		"absent ship id: sheet_offset == ZERO")
	_check(WaterlineFxLib.sheet_size_px("__absent__") == Vector2.ZERO,
		"absent ship id: sheet_size == ZERO")


# --- 6  the committed table + registry (the W6 gate) ---------------------------

func _test_committed_table_contract() -> void:
	RegistryLib.ensure_registered()
	var table: Dictionary = WaterlineFxLib.table()
	_check(not table.is_empty(),
		"the committed fx frame table loads (assets/ui/fx/fx_waterline.json)")
	_check(int(table.get("version", 0)) == 4,
		"the committed table is the v4 per-ship shape")
	var ships: Dictionary = table.get("ships", {})
	_check(ships.size() == SHIPS.size(),
		"the table carries exactly the %d ship types" % SHIPS.size())
	for ship: String in SHIPS:
		var g := WaterlineFxLib.geometry(ship)
		_check(not g.is_empty(), "%s is in the table" % ship)
		if g.is_empty():
			continue
		_check(int(g.get("frames", 0)) == 8,
			"%s pins 8 frames (80-* §4.8 2026-11-07)" % ship)
		_check(int(g.get("frame_ms", 0)) > 0,
			"%s frame_ms > 0" % ship)
		_check(bool(g.get("loop", false)), "%s loops" % ship)
		_check(str(g.get("sprite", "")) == "hull_%s" % ship,
			"%s is authored around its own hull token" % ship)
		# The anchor box is the ship's OWN token canvas (the tier table).
		var token := UiKitLib.icon_texture("hull_%s" % ship)
		var box := int(token.get_width()) if token != null else 0
		var anchor: Dictionary = g.get("anchor_sprite", {})
		_check(box > 0 and int(anchor.get("x", -1)) >= 0
			and int(anchor.get("x", -1)) <= box
			and int(anchor.get("y", -1)) >= 0 and int(anchor.get("y", -1)) <= box,
			"%s anchor sits inside its %dpx token box" % [ship, box])
		var clip: Dictionary = g.get("sheet", {})
		_check(int(clip.get("frame", {}).get("w", 0)) > 0
			and int(clip.get("frame", {}).get("h", 0)) > 0,
			"%s sheet frame px > 0" % ship)
		_check(int(clip.get("columns", 0)) > 0,
			"%s sheet columns > 0" % ship)
		var off: Dictionary = clip.get("offset", {})
		_check(off.has("x") and off.has("y"),
			"%s sheet carries the pack offset" % ship)
	for ship: String in SHIPS:
		var tex := UiKitLib.icon_texture(WaterlineFxLib.sheet_id(ship))
		_check(tex != null,
			"%s resolves through the lazy raw-bytes registry"
				% WaterlineFxLib.sheet_id(ship))


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
	print("FAILURES (%d of %d):" % [_failures.size(), _checks])
	for msg in _failures:
		print("  - ", msg)
	get_tree().quit(1)
