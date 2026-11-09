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
	await _test_parent_bounds_clamp()


## The parent-bounds rule (2026-11-09 user direction): an element cannot
## move or resize outside its parent — an x/y/w/h override is clamped to
## the parent panel's rect (the free child sits INSIDE a registered
## 10×2-tile parent panel here, and the override tries to escape it).
func _test_parent_bounds_clamp() -> void:
	RegistryLib._reset_for_tests()
	var root := Control.new()
	root.size = Vector2(1920, 1080)
	add_child(root)
	var host := Panel.new()
	host.size = Vector2(10 * RegistryLib.TILE, 2 * RegistryLib.TILE)
	root.add_child(host)
	RegistryLib.register("market", host, "toolbar",
			{"kind": "free", "role": "panel"})
	var child := Panel.new()
	host.add_child(child)
	RegistryLib.register("market", child, "toolbar.child",
			{"kind": "free", "role": "panel"})
	RegistryLib.screen_active("market", root)
	RegistryLib.set_table_for_tests({
		"market": {"toolbar.child":
				{"x": 20, "y": 9, "w": 40, "h": 8}},
	})
	RegistryLib.apply_screen("market")
	_check(child.size == Vector2(10 * RegistryLib.TILE,
				2 * RegistryLib.TILE),
			"parent bounds: the resize clamps to the parent's size")
	_check(child.position == Vector2.ZERO,
			"parent bounds: the move clamps to the parent's origin")
	# The children-extent floor (the parent-bounds rule's mirror): the
	# parent cannot shrink so its child ends up outside — a w=3-tile
	# override on the host clamps to the child's 10-tile extent.
	RegistryLib.set_table_for_tests({
		"market": {"toolbar": {"w": 3, "h": 2}},
	})
	RegistryLib.apply_screen("market")
	_check(host.size.x == 10 * RegistryLib.TILE,
			"children-extent floor: the parent cannot shrink below its "
			+ "child's extent (got %s)" % str(host.size))
	_drop_root(root)
	await get_tree().process_frame
	await _test_break_out_of_flow()


## Drag out of the flow (2026-11-09 user direction — drag must move
## anything, within the registered parent): an x/y move on a container
## child re-parents it to the screen root, confined to the registered
## parent's rect; the tree keeps nesting it under that parent (kind
## reports free); revert re-inserts it at its baseline slot.
func _test_break_out_of_flow() -> void:
	RegistryLib._reset_for_tests()
	var root := Control.new()
	root.size = Vector2(1920, 1080)
	add_child(root)
	var grid := Panel.new()
	grid.size = Vector2(16 * RegistryLib.TILE, 6 * RegistryLib.TILE)
	root.add_child(grid)
	RegistryLib.register("port", grid, "facility_grid",
			{"kind": "free", "role": "panel"})
	var pair := HBoxContainer.new()
	grid.add_child(pair)
	var card := Button.new()
	card.custom_minimum_size = Vector2(320, 64)
	pair.add_child(card)
	RegistryLib.register("port", card, "cards.market",
			{"role": "button", "data_ordered": true})
	# A second card in the SAME pair — the co-flow freeze keeps it at
	# its visual rect when the first card breaks out.
	var card2 := Button.new()
	card2.custom_minimum_size = Vector2(320, 64)
	pair.add_child(card2)
	RegistryLib.register("port", card2, "cards.shipyard",
			{"role": "button", "data_ordered": true})
	RegistryLib.screen_active("port", root)
	RegistryLib.set_table_for_tests({})
	RegistryLib.apply_screen("port")
	await get_tree().process_frame
	await get_tree().process_frame
	var tile := float(RegistryLib.TILE)
	# The sorted baseline: market at the first slot, shipyard beside it
	# (the HBox default separation is 4 px).
	_check(card.position == Vector2.ZERO
			and card2.position.x >= card.size.x and card2.position.y == 0.0,
			"break-out rig: the pair sorted (got %s / %s)" % [
				str(card.position), str(card2.position)])
	var shipyard_before: Vector2 = card2.global_position
	# THE LIVE DRAG: x/y move on the container child — break-out + the
	# co-flow freeze of the sibling.
	RegistryLib.set_table_for_tests({
		"port": {"cards.market": {"x": 2, "y": 3}},
	})
	RegistryLib.apply_overrides("port", "cards.market",
			{"x": 2, "y": 3})
	_check(card.get_parent() == root,
			"break-out: the card left its flow container")
	_check(card.position == Vector2(2 * tile, 3 * tile),
			"break-out: the card sits at the dragged tiles")
	# The co-flow freeze: the sibling froze at its visual rect —
	# re-parented to the root, out-of-flow, NOT shifted into the
	# vacated slot.
	_check(card2.get_parent() == root,
			"co-flow freeze: the sibling re-parented to the root")
	_check(card2.global_position == shipyard_before,
			"co-flow freeze: the sibling did not move (got %s)"
					% str(card2.global_position))
	_check(RegistryLib._screens["port"]["cards.shipyard"]
			.get("out_of_flow", false) == true,
			"co-flow freeze: the sibling is out-of-flow (individually "
			+ "draggable)")
	var rows: Array = RegistryLib.tree("port")
	var row: Dictionary = {}
	for r: Dictionary in rows:
		if r["id"] == "cards.market":
			row = r
	_check(row.get("id") == "cards.market"
			and row.get("parent") == "facility_grid"
			and row.get("kind") == "free",
			"break-out: the tree keeps nesting under facility_grid (free)")
	RegistryLib.apply_overrides("port", "cards.market", {"x": 200})
	_check(card.position.x <= 16 * tile - 10 * tile + RegistryLib.TILE,
			"break-out: the card stays confined to facility_grid's rect")
	RegistryLib.revert_element("port", "cards.market")
	_check(card.get_parent() == pair and card.get_index() == 0,
			"break-out revert: the card returns to its pair slot")
	var oof: bool = RegistryLib._screens["port"]["cards.market"] \
			.get("out_of_flow", false)
	_check(not oof,
			"break-out revert: the out-of-flow mark is cleared")
	card.free()
	_drop_root(root)
	await get_tree().process_frame
	await _test_free_resize_only_no_collapse()


## The 2026-11-09 resize report: a resize-only override (w/h, NO x/y) on
## a control whose authored anchors are NOT point-shaped (a full-rect
## background Panel) must not collapse its rect — the anchor reset
## happens with position/size captured BEFORE it, so the non-overridden
## axes keep their authored extents and the settled rect is exactly the
## dragged tile multiple.
func _test_free_resize_only_no_collapse() -> void:
	var root := _rig()
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(panel)  # 1920×1080 authored rect (60×33 tiles)
	RegistryLib.register("market", panel, "background",
			{"kind": "free", "role": "panel"})
	RegistryLib.screen_active("market", root)
	RegistryLib.set_table_for_tests({
		"market": {"background": {"w": 8, "h": 2}},
	})
	RegistryLib.apply_screen("market")
	var tile := float(RegistryLib.TILE)
	_check(panel.size == Vector2(8 * tile, 2 * tile),
			"resize-only free: the settled size is the dragged tiles")
	_check(panel.position == Vector2.ZERO,
			"resize-only free: the authored position is preserved")
	_check(panel.anchor_right == 0.0 and panel.anchor_bottom == 0.0,
			"resize-only free: the anchors are point-shaped for edits")
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
	# The min-authoritative flag pin (the drag-resize fix): a min
	# override on a container child stops the parent's stretch — the
	# control measures exactly the dragged min (the user-reported
	# "after release the box width goes to max" was the parent's FILL
	# stretch re-winning over the min).
	_check(b.size_flags_horizontal == Control.SIZE_SHRINK_BEGIN
			and b.size_flags_vertical == Control.SIZE_SHRINK_BEGIN,
			"container child: the min override pins shrink-begin flags")
	_check(b.get_index() == 0,
			"container child: order moves the sibling index")
	_check(c.get_index() == 2,
			"locked control: order override IGNORED (data_ordered)")
	var pos_before := b.position
	var size_before := b.size
	RegistryLib.revert_element("market", "rows.copper")
	_check(b.custom_minimum_size == Vector2.ZERO and b.get_index() == 1,
			"container child: revert restores min-size + index")
	_check(b.size_flags_horizontal != Control.SIZE_SHRINK_BEGIN
			or b.size_flags_vertical != Control.SIZE_SHRINK_BEGIN,
			"container child: revert un-pins the shrink flags (the "
			+ "parent's stretch is the default again)")
	# Container-owned geometry (the 2026-11-09 live-session fix): the
	# baseline captured position/size at _ready — BEFORE the parent's
	# first layout pass — so a child revert must NOT restore them (the
	# reported facility_grid 58 → 20 shrink).
	_check(b.position == pos_before and b.size == size_before,
			"container child: revert leaves the parent-owned geometry alone")
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
	var guild_rows: Array = RegistryLib.tree("guild")
	_check(guild_rows.size() == 1 and "min_tiles" in guild_rows[0],
			"tree() lists the live record with min_tiles (the drag floor)")
	await get_tree().process_frame
	await get_tree().process_frame
	await _test_vbox_chain_min_authoritative()
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
	# The rebuild: a fresh wrapper + label under the same id. The label
	# carries text — a REAL content minimum (font metrics, off-grid by
	# nature) — to pin the tile-quantized floor: a min override of 1
	# tile must land on a whole-tile custom_min that still subsumes the
	# content (the grid guarantee, 2026-11-09 user direction).
	var new_wrapper := HBoxContainer.new()
	grid.add_child(new_wrapper)
	var new_label := Label.new()
	new_label.text = "水手长 · Boatswain"
	new_wrapper.add_child(new_label)
	RegistryLib.register("port", new_label, "cards.guild.status")
	RegistryLib.set_table_for_tests({
		"port": {"cards.guild.status": {"min_h": 1}},
	})
	RegistryLib.apply_screen("port")
	var content_y: float = new_label.get_minimum_size().y
	_check(new_label.custom_minimum_size.y >= content_y,
			"quantized floor: the applied min subsumes the content")
	_check(absf(fmod(new_label.custom_minimum_size.y,
			float(RegistryLib.TILE))) < 0.01,
			"quantized floor: the applied min is an exact tile multiple")
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
	await _test_vbox_chain_min_authoritative()


# --- 7b. The live port-hub wrapper chain (the drag-resize repro) --------------

## The live session's exact wrapper chain (2026-11-09): MarginContainer →
## VBox → Facilities (VBox, EXPAND_FILL vertical) → Rows (the registered
## element, holding an HBox pair with a 320px card). A min_w/min_h
## override with the flag pin must make the element settle at EXACTLY the
## dragged min (1344×448) — the user's live session settled at 1472 wide
## (the parent's width) instead.
func _test_vbox_chain_min_authoritative() -> void:
	RegistryLib._reset_for_tests()
	var root := Control.new()
	root.size = Vector2(1920, 1080)
	add_child(root)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top",
			"margin_bottom"]:
		margin.add_theme_constant_override(side, 32)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	margin.add_child(vbox)
	var facilities := VBoxContainer.new()
	facilities.size_flags_vertical = Control.SIZE_EXPAND_FILL
	facilities.add_theme_constant_override("separation", 8)
	vbox.add_child(facilities)
	var heading := Label.new()
	heading.text = "Facilities"
	facilities.add_child(heading)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 8)
	facilities.add_child(rows)
	var pair := HBoxContainer.new()
	pair.add_theme_constant_override("separation", 8)
	rows.add_child(pair)
	var card := Button.new()
	card.custom_minimum_size = Vector2(320, 64)
	pair.add_child(card)
	RegistryLib.register("port", rows, "facility_grid", {"role": "panel"})
	RegistryLib.screen_active("port", root)
	var tile := float(RegistryLib.TILE)
	# The live sequence: the COMMITTED override (46×12) applies and sorts
	# first; the drag then pulls the min DOWN to 42×14.
	RegistryLib.set_table_for_tests({
		"port": {"facility_grid": {"min_w": 46, "min_h": 12}},
	})
	RegistryLib.apply_screen("port")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(rows.size == Vector2(46 * tile, 12 * tile),
			"vbox chain: the committed load sorts to 46x12 (got %s)"
					% str(rows.size))
	RegistryLib.set_table_for_tests({
		"port": {"facility_grid": {"min_w": 42, "min_h": 14}},
	})
	RegistryLib.apply_overrides("port", "facility_grid",
			{"min_w": 42, "min_h": 14})
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_check(rows.size_flags_horizontal == Control.SIZE_SHRINK_BEGIN
			and rows.size_flags_vertical == Control.SIZE_SHRINK_BEGIN,
			"vbox chain: the min override pins shrink-begin flags")
	_check(rows.custom_minimum_size == Vector2(42 * tile, 14 * tile),
			"vbox chain: custom min == the dragged tiles")
	_check(rows.size == Vector2(42 * tile, 14 * tile),
			"vbox chain: the SETTLED size == the dragged min (got %s)"
					% str(rows.size))
	_drop_root(root)
	await get_tree().process_frame


# --- 8. Data seam -------------------------------------------------------------

func _test_data_seam() -> void:
	var loader := _loader()
	_check(loader != null and loader.ui_layout is Dictionary,
			"DataLoader.ui_layout exists (the §4.23 table)")
	_check(loader.ui_layout.is_empty(),
			"the shipped ui_layout table is {} (all defaults)")
