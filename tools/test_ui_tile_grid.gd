extends Node
## Tile-grid guard (docs/80-UI-UX.md §4.8 sizing grid + §4.8.8 consumption
## rule, the 2026-11-09 tile-measured-chrome amendment; IMPLEMENT-Phase10.md
## W7.5). Headless scene test:
##
##   godot --headless --path . res://tools/test_ui_tile_grid.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## WHAT IS PINNED — the tile-measured-chrome contract, asserted directly
## (constants + closed forms + one install observation; the no-overkill
## discipline: no scene sweeps, no Monte Carlo):
##   1. DERIVATION — every chrome sizing constant is an exact tile multiple
##      of `Palette.CHROME_TILE` (the ONLY chrome pixel number), and the
##      theme's button floor re-states it. A future tile-size change edits
##      the one constant; these checks then still hold.
##   2. SHEET AGREEMENT — the real chrome sheets stay 3×3 tiles and the
##      theme derives each stylebox margin from the loaded texture (width/3
##      == CHROME_TILE), so margins render 1:1.
##   3. CLOSED FORMS — `UiKit.snap_to_tiles`: 0 stays container-driven,
##      anything positive snaps UP to the next tile multiple with the
##      2-tile floor (idempotent by construction).
##   4. THE PASS — `apply_tile_grid` snaps sheeted controls (Button /
##      Panel / PanelContainer / LineEdit / TextEdit / SpinBox) and leaves
##      non-chrome controls untouched; `install_tile_grid` snaps chrome
##      nodes that enter the tree later (deferred, freed-node safe).
##   5. THE WIRING — S1 installs the pass at the theme application point
##      (the one-time texture-registry pattern).

const UiKitLib := preload("res://scripts/ui_kit.gd")
const UiThemeLib := preload("res://scripts/ui_theme.gd")
const PaletteLib := preload("res://scripts/palette.gd")

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_derivation()
	_test_sheet_agreement()
	_test_closed_forms()
	_test_apply_tile_grid()
	await _test_install_observation()
	_test_wiring()
	_report()


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


# --- 1. Derivation (§4.8 sizing grid) ----------------------------------------

func _test_derivation() -> void:
	var tile: int = PaletteLib.CHROME_TILE
	_check(tile == 32,
		"CHROME_TILE is the declared 32px pin (the only chrome pixel number)")
	_check(PaletteLib.BUTTON_H == 2 * tile,
		"BUTTON_H == 2 tiles (the 2x2-tile floor axis)")
	_check(PaletteLib.TOP_BAR_H == 2 * tile, "TOP_BAR_H == 2 tiles")
	_check(PaletteLib.BOTTOM_BAR_H == 2 * tile, "BOTTOM_BAR_H == 2 tiles")
	_check(PaletteLib.ROW_H == tile, "ROW_H == 1 tile")
	_check(PaletteLib.MARGIN * 2 == tile, "MARGIN == 1/2 tile")
	_check(PaletteLib.BASE_UNIT * 4 == tile, "BASE_UNIT == 1/4 tile")
	_check(PaletteLib.DIALOG_W % tile == 0,
		"DIALOG_W is a whole tile multiple (%d)" % PaletteLib.DIALOG_W)
	_check(UiThemeLib.BUTTON_MIN_H == PaletteLib.BUTTON_H,
		"BUTTON_MIN_H re-states Palette.BUTTON_H (2 tiles, doc pin)")
	_check(2 * UiThemeLib.SHEET_MARGIN <= PaletteLib.BUTTON_H,
		"2 sheet margins fit the button floor (compression unreachable)")


# --- 2. Sheet agreement (§4.8.8) ----------------------------------------------

func _test_sheet_agreement() -> void:
	var tile: int = PaletteLib.CHROME_TILE
	var sheet: Texture2D = load(
		"res://assets/ui/chrome/ninepatch_button.png") as Texture2D
	if sheet == null:
		_check(false, "ninepatch_button.png loads")
		return
	_check(sheet.get_width() == 3 * tile and sheet.get_height() == 3 * tile,
		"the button sheet is 3x3 chrome tiles (%dx%d)" %
		[sheet.get_width(), sheet.get_height()])
	var theme := UiThemeLib.build_theme(true)
	var box := theme.get_stylebox("normal", "Button") as StyleBoxTexture
	_check(box != null and box.texture_margin_left == tile,
		"the themed button box derives its margin from the sheet (%d)" %
		(box.texture_margin_left if box != null else -1))


# --- 3. Closed forms (UiKit.snap_to_tiles) ------------------------------------

func _test_closed_forms() -> void:
	var cases := {
		0: 0,      # container-driven axis stays 0
		1: 64,     # the 2-tile floor
		31: 64, 32: 64, 33: 64,   # snap UP to 2 tiles (floor), never down
		40: 64,    # the retired 40px button height lands on 2 tiles
		56: 64, 64: 64, 65: 96,
		96: 96,    # already clean stays clean (idempotence)
		280: 288, 440: 448, 584: 608,
	}
	for px in cases:
		_check(UiKitLib.snap_to_tiles(px) == cases[px],
			"snap_to_tiles(%d) == %d" % [px, cases[px]])
	_check(UiKitLib.snap_to_tiles(-5) == 0, "snap_to_tiles(negative) == 0")


# --- 4. The pass (apply_tile_grid + install) ----------------------------------

func _test_apply_tile_grid() -> void:
	var holder := Control.new()
	add_child(holder)
	var button := Button.new()
	button.custom_minimum_size = Vector2(280, 40)
	holder.add_child(button)
	var edge_button := Button.new()
	edge_button.custom_minimum_size = Vector2(0, 40)
	holder.add_child(edge_button)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(584, 0)
	holder.add_child(panel)
	var field := LineEdit.new()
	field.custom_minimum_size = Vector2(200, 32)
	holder.add_child(field)
	var label := Label.new()
	label.custom_minimum_size = Vector2(328, 40)
	holder.add_child(label)
	UiKitLib.apply_tile_grid(holder)
	_check(button.custom_minimum_size == Vector2(288, 64),
		"apply_tile_grid snaps a Button (280,40 -> 288,64)")
	_check(edge_button.custom_minimum_size == Vector2(0, 64),
		"apply_tile_grid keeps a 0 axis container-driven (0,40 -> 0,64)")
	_check(panel.custom_minimum_size == Vector2(608, 0),
		"apply_tile_grid snaps a PanelContainer (584,0 -> 608,0)")
	_check(field.custom_minimum_size == Vector2(224, 64),
		"apply_tile_grid snaps a LineEdit (200,32 -> 224,64)")
	_check(label.custom_minimum_size == Vector2(328, 40),
		"apply_tile_grid leaves non-chrome controls untouched (Label)")
	# Idempotence: a second pass is a no-op.
	UiKitLib.apply_tile_grid(holder)
	_check(button.custom_minimum_size == Vector2(288, 64),
		"apply_tile_grid is idempotent")
	holder.queue_free()


## The deferred `node_added` path: a chrome node entering AFTER the install
## lands snapped one frame later; a freed node is silently skipped.
func _test_install_observation() -> void:
	UiKitLib.install_tile_grid(get_tree())
	_check(UiKitLib._tile_grid_installed, "install_tile_grid runs once")
	var late := Button.new()
	late.custom_minimum_size = Vector2(100, 10)
	add_child(late)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(late.custom_minimum_size == Vector2(128, 64),
		"the installed pass snaps a late-entering button (100,10 -> 128,64)")
	late.queue_free()
	await get_tree().process_frame


# --- 5. The wiring (S1 installs at the theme point) ----------------------------

func _test_wiring() -> void:
	var source := FileAccess.open("res://scenes/title/title_screen.gd",
		FileAccess.READ)
	var text := source.get_as_text() if source != null else ""
	_check(text.contains("install_tile_grid"),
		"title_screen.gd installs the tile grid pass at the theme point")
