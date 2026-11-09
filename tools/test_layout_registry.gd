extends Node
## Layout-registry guard (docs/80-UI-UX.md §4.8.9; docs/10-* §4.23/§8.9;
## IMPLEMENT-Phase11.md W1). Headless scene test:
##
##   godot --headless --path . res://tools/test_layout_registry.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## WHAT IS PINNED — the layout-override contract, asserted directly
## (constants + one boot + per-kind applier observations; the no-overkill
## discipline — no screen sweeps, no Monte Carlo):
##   1. DERIVATION — the tile is `Palette.CHROME_TILE`, the screen set is
##      exactly the 8 pilot ids, the sheet set exactly the 7 assignable
##      nine-patches.
##   2. FREE CHILD — absolute x/y/w/h tiles land as pixels on a root
##      child; the anchors stay top-left.
##   3. ANCHORED — `anchor: bottom` + h docks the bottom edge to the
##      parent's bottom (anchor 1.0, offset_bottom 0, offset_top −h·32)
##      and never reads `y` (group-14 forbids the pair).
##   4. CONTAINER CHILD — `min_w`/`min_h` merge per axis into
##      `custom_minimum_size`; `order` moves the sibling index;
##      `data_ordered` registrations IGNORE `order` (the locked-order
##      rule — the §4.8.1 grid and market row order are data contracts).
##   5. SHEET SEAM — `sheet_override` routes per role (panel→`panel`,
##      button→`normal`, field→`normal`, plain→rejected) and installs a
##      StyleBoxTexture ONLY when the sheet file exists (the flat-
##      fallback rule); `clear_sheet_override` removes exactly that box.
##   6. REVERT — the registration baseline restores position, size,
##      min-size, sibling index, anchors and offsets, and clears the
##      sheet override.
##   7. IDEMPOTENCE + PRUNING — a second apply is a no-op; a freed
##      control's record is dropped by the apply walk.
##   8. DATA SEAM — `DataLoader.ui_layout` exists and is the shipped `{}`.

const PaletteLib := preload("res://scripts/palette.gd")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const UiThemeLib := preload("res://scripts/ui_theme.gd")

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_derivation()
	await _test_free_child()
	await _test_anchored()
	await _test_container_child()
	_test_sheet_seam()
	await _test_revert()
	await _test_idempotence_pruning()
	_test_data_seam()
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
	else:
		for failure in _failures:
			print("FAILED: ", failure)
		print("%d of %d checks FAILED" % [_failures.size(), _checks])
		get_tree().quit(1)


func _loader() -> Node:
	return get_node("/root/DataLoader")


# --- 1. Derivation ----------------------------------------------------------

func _test_derivation() -> void:
	_check(RegistryLib.TILE == PaletteLib.CHROME_TILE,
			"tile == Palette.CHROME_TILE")
	var screens: Array[String] = [
		"port", "market", "inn", "guild", "provisions", "palace",
		"tavern", "shipyard",
	]
	_check(RegistryLib.SCREENS == screens,
			"screen set == the 8 pilot ids")
	var sheets: Array[String] = [
		"panel", "button", "button_hover", "button_pressed",
		"button_focus", "field", "backdrop",
	]
	_check(RegistryLib.SHEET_IDS == sheets,
			"sheet set == the 7 assignable nine-patches")
	_check(not RegistryLib.SHEET_IDS.has("bar"),
			"the value-bar band is not assignable")


# --- Shared fixture rig -------------------------------------------------------

## One fresh screen state: a 60×34-tile root (the design canvas), two
## children, the fixture table injected, records reset.
func _rig() -> Control:
	RegistryLib._reset_for_tests()
	var root := Control.new()
	root.name = "RigRoot"
	root.size = Vector2(60 * RegistryLib.TILE, 34 * RegistryLib.TILE)
	add_child(root)
	return root


func _drop_root(root: Control) -> void:
	root.queue_free()


# --- 2. Free child ----------------------------------------------------------

func _test_free_child() -> void:
	var root := _rig()
	var panel := Panel.new()
	root.add_child(panel)
	RegistryLib.register("market", panel, "toolbar",
			{"kind": "free", "role": "panel"})
	RegistryLib.screen_active("market", root)
	RegistryLib.set_table_for_tests({
		"market": {"toolbar": {"x": 2, "y": 1, "w": 8, "h": 2}},
	})
	RegistryLib.apply_screen("market")
	var tile := float(RegistryLib.TILE)
	_check(panel.position == Vector2(2 * tile, 1 * tile),
			"free child: position = tiles × 32")
	_check(panel.size == Vector2(8 * tile, 2 * tile),
			"free child: size = tiles × 32")
	_check(panel.anchor_left == 0.0 and panel.anchor_right == 0.0
			and panel.anchor_top == 0.0 and panel.anchor_bottom == 0.0,
			"free child: anchors stay top-left")
	# Absent axes keep their values (merge semantics).
	RegistryLib.set_table_for_tests({
		"market": {"toolbar": {"x": 5}},
	})
	RegistryLib.apply_screen("market")
	_check(panel.position == Vector2(5 * tile, 1 * tile)
			and panel.size == Vector2(8 * tile, 2 * tile),
			"free child: absent axes untouched")
	RegistryLib.revert_element("market", "toolbar")
	_check(panel.position == Vector2.ZERO,
			"free child: revert restores the baseline position")
	_drop_root(root)
	await get_tree().process_frame


# --- 3. Anchored --------------------------------------------------------------

func _test_anchored() -> void:
	var root := _rig()
	var bar := Panel.new()
	root.add_child(bar)
	RegistryLib.register("port", bar, "footer",
			{"kind": "anchored", "role": "panel"})
	RegistryLib.screen_active("port", root)
	RegistryLib.set_table_for_tests({
		"port": {"footer": {"anchor": "bottom", "h": 2, "w": 8, "x": 26}},
	})
	RegistryLib.apply_screen("port")
	var tile := float(RegistryLib.TILE)
	_check(bar.anchor_top == 1.0 and bar.anchor_bottom == 1.0,
			"anchored bottom: vertical anchors dock to 1.0")
	_check(bar.offset_bottom == 0.0,
			"anchored bottom: the bottom edge is flush")
	_check(bar.offset_top == -2 * tile,
			"anchored bottom: offset_top = −h·32")
	_check(bar.offset_left == 26 * tile
			and bar.offset_right == 26 * tile + 8 * tile,
			"anchored bottom: the cross axis is x/w-addressable")
	# `anchor` + `y` never applies geometry from y (group-14 owns the file;
	# the runtime ignores the illegal pair defensively).
	RegistryLib.set_table_for_tests({
		"port": {"footer": {"anchor": "bottom", "h": 2, "y": 7}},
	})
	RegistryLib.apply_screen("port")
	_check(bar.offset_top == -2 * tile,
			"anchored bottom: y is never read with an anchor")
	RegistryLib.reset_screen("port")
	_check(bar.anchor_top == 0.0 and bar.offset_top == 0.0,
			"anchored bottom: reset_screen restores the baseline")
	_drop_root(root)
	await get_tree().process_frame


# --- 4. Container child ---------------------------------------------------------

func _test_container_child() -> void:
	var root := _rig()
	var rows := VBoxContainer.new()
	root.add_child(rows)
	var a := Panel.new()
	var b := Panel.new()
	var c := Panel.new()
	rows.add_child(a)
	rows.add_child(b)
	rows.add_child(c)
	RegistryLib.register("market", b, "rows.copper",
			{"role": "plain"})
	RegistryLib.register("market", c, "rows.iron",
			{"role": "plain", "data_ordered": true})
	RegistryLib.screen_active("market", root)
	RegistryLib.set_table_for_tests({
		"market": {
			"rows.copper": {"min_w": 4, "min_h": 2, "order": 0},
			"rows.iron": {"order": 0},
		},
	})
	RegistryLib.apply_screen("market")
	var tile := float(RegistryLib.TILE)
	_check(b.custom_minimum_size == Vector2(4 * tile, 2 * tile),
			"container child: min_w/min_h → custom_minimum_size")
	_check(b.get_index() == 0,
			"container child: order moves the sibling index")
	_check(c.get_index() == 2,
			"locked control: order override IGNORED (data_ordered)")
	RegistryLib.revert_element("market", "rows.copper")
	_check(b.custom_minimum_size == Vector2.ZERO and b.get_index() == 1,
			"container child: revert restores min-size + index")
	_drop_root(root)
	await get_tree().process_frame


# --- 5. Sheet seam -----------------------------------------------------------

func _test_sheet_seam() -> void:
	var panel := Panel.new()
	var sheet_exists := ResourceLoader.exists(
			UiThemeLib.SHEET_PATHS["panel"])
	if sheet_exists:
		_check(UiThemeLib.sheet_override(panel, "panel", "panel"),
				"sheet seam: panel role installs (sheet present)")
		_check(panel.get_theme_stylebox("panel") is StyleBoxTexture,
				"sheet seam: the override is a StyleBoxTexture")
		_check(panel.get_theme_stylebox("panel").content_margin_left
				== UiThemeLib.PANEL_PAD,
				"sheet seam: the box keeps PANEL_PAD content margins")
		UiThemeLib.clear_sheet_override(panel, "panel")
		_check(not (panel.get_theme_stylebox("panel") is StyleBoxTexture),
				"sheet seam: clear removes the override box")
	else:
		_check(not UiThemeLib.sheet_override(panel, "panel", "panel"),
				"sheet seam: absent sheet file ⇒ false (flat fallback)")
	var button := Button.new()
	_check(not UiThemeLib.sheet_override(button, "panel", "panel"),
			"sheet seam: role/class mismatch ⇒ false")
	_check(not UiThemeLib.sheet_override(panel, "panel", "no_such_sheet"),
			"sheet seam: unknown sheet id ⇒ false")
	_check(not UiThemeLib.sheet_override(Control.new(), "plain", "panel"),
			"sheet seam: plain role ⇒ false")
	panel.queue_free()
	button.queue_free()


# --- 6/7. Revert + idempotence/pruning (one rig) ------------------------------

func _test_revert() -> void:
	var root := _rig()
	var panel := Panel.new()
	root.add_child(panel)
	panel.position = Vector2(64, 32)
	panel.size = Vector2(256, 64)
	RegistryLib.register("inn", panel, "hero",
			{"kind": "free", "role": "panel"})
	RegistryLib.screen_active("inn", root)
	var sheet_exists := ResourceLoader.exists(
			UiThemeLib.SHEET_PATHS["panel"])
	var table: Dictionary = {
		"inn": {"hero": {"x": 0, "y": 0, "w": 3, "h": 3}},
	}
	if sheet_exists:
		table["inn"]["hero"]["sheet"] = "backdrop"
		UiThemeLib.sheet_override(panel, "panel", "panel")
	RegistryLib.set_table_for_tests(table)
	RegistryLib.apply_screen("inn")
	_check(panel.position == Vector2.ZERO and panel.size == Vector2(96, 96),
			"revert rig: the override landed")
	RegistryLib.revert_element("inn", "hero")
	_check(panel.position == Vector2(64, 32)
			and panel.size == Vector2(256, 64),
			"revert: position + size restored")
	if sheet_exists:
		_check(not (panel.get_theme_stylebox("panel") is StyleBoxTexture),
				"revert: the sheet override is cleared")
	_drop_root(root)
	await get_tree().process_frame


func _test_idempotence_pruning() -> void:
	var root := _rig()
	var panel := Panel.new()
	root.add_child(panel)
	RegistryLib.register("guild", panel, "board", {"kind": "free"})
	RegistryLib.screen_active("guild", root)
	RegistryLib.set_table_for_tests({
		"guild": {"board": {"x": 1, "y": 1}},
	})
	RegistryLib.apply_screen("guild")
	var after_first := panel.position
	RegistryLib.apply_screen("guild")
	_check(panel.position == after_first,
			"apply_screen is idempotent")
	_check(RegistryLib.tree("guild").size() == 1,
			"tree() lists the live record")
	panel.free()  # an immediate free (not queue_free) — the pruned rec
	RegistryLib.apply_screen("guild")
	_check(RegistryLib.tree("guild").is_empty(),
			"apply_screen prunes a freed record")
	_drop_root(root)
	await get_tree().process_frame
	await _test_wrapper_queued_rebuild()


## The live port-hub session's report (2026-11-09): a rebuilt pair is
## `remove_child` + `queue_free`d as a WRAPPER — its descendants (the
## `cards.<id>.status` labels) die with it WITHOUT their own
## `is_queued_for_deletion()` flag. The re-register over such a doomed
## record is the DESIGNED rebuild flow (the guard's tree-membership
## predicate owns the silence); the replacement must land cleanly and
## the tree must list only the new node.
func _test_wrapper_queued_rebuild() -> void:
	var root := _rig()
	var grid := VBoxContainer.new()
	root.add_child(grid)
	var wrapper := HBoxContainer.new()
	grid.add_child(wrapper)
	var old_label := Label.new()
	wrapper.add_child(old_label)
	RegistryLib.register("port", old_label, "cards.guild.status")
	RegistryLib.screen_active("port", root)
	# The teardown: remove + queue the WRAPPER (the descendants keep
	# is_queued_for_deletion() == false until the frame ends).
	grid.remove_child(wrapper)
	wrapper.queue_free()
	# The rebuild: a fresh wrapper + label under the same id.
	var new_wrapper := HBoxContainer.new()
	grid.add_child(new_wrapper)
	var new_label := Label.new()
	new_wrapper.add_child(new_label)
	RegistryLib.register("port", new_label, "cards.guild.status")
	RegistryLib.apply_screen("port")
	var rows := RegistryLib.tree("port")
	_check(rows.size() == 1 and rows[0]["id"] == "cards.guild.status",
			"wrapper-queued rebuild: the record is replaced, tree clean")
	_check(RegistryLib._live(
			RegistryLib._screens["port"]["cards.guild.status"])
			== new_label,
			"wrapper-queued rebuild: the record points at the NEW node")
	# The doomed old label is out of the tree — tree membership, not its
	# own deletion flag, is what silenced the duplicate (the new label is
	# the live one inside the tree).
	_check(not old_label.is_inside_tree() and new_label.is_inside_tree(),
			"wrapper-queued rebuild: old node out, new node in")
	old_label.free()
	new_label.free()
	_drop_root(root)
	await get_tree().process_frame


# --- 8. Data seam -------------------------------------------------------------

func _test_data_seam() -> void:
	var loader := _loader()
	_check(loader != null and loader.ui_layout is Dictionary,
			"DataLoader.ui_layout exists (the §4.23 table)")
	_check(loader.ui_layout.is_empty(),
			"the shipped ui_layout table is {} (all defaults)")
