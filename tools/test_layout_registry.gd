extends Node
## Layout-registry guard (docs/80-UI-UX.md §4.8.9; docs/10-* §4.23/§8.9;
## IMPLEMENT-Phase12.md W1). Headless scene test:
##
##   godot --headless --path . res://tools/test_layout_registry.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## WHAT IS PINNED — the absolute-layout contract, asserted directly
## (constants + one rig + per-path observations; the no-overkill
## discipline):
##   1. DERIVATION — the tile is `Palette.CHROME_TILE`, the screen set is
##      exactly the 32 §4.23 ids, the sheet set exactly the 7 assignable
##      nine-patches, the edit keys exactly {x,y,w,h,sheet}, the retired
##      keys exactly {min_w,min_h,order,anchor}, the fallback (0,0,2,2).
##   2. RECT APPLY — a data row lands as pixels with point anchors; the
##      parent-bounds clamp holds (rule 1); the children-extent floor
##      holds (rule 2); an unmanaged screen is a no-op.
##   3. COVERAGE — a registered static element with no rect row on a
##      managed screen takes the authored fallback (0,0,2,2); a list
##      member is skipped (its builder owns the placement).
##   4. LIST RECT — `list_rect` = base + i·row_h in px (the closed
##      form); an absent list block ⇒ Rect2().
##   5. EDITS — apply_overrides carries {x,y,w,h,sheet} only; a retired
##      key (a v1 studio message) changes NOTHING; unknown keys
##      likewise.
##   6. REVERT — re-applies the DATA rect and clears the sheet override.
##   7. IDEMPOTENCE + PRUNING — a second apply is a no-op; a freed
##      control's record is dropped by the apply walk; the tree payload
##      keeps its fields.
##   8. SHEET SEAM — `sheet_override` routes per role and installs a
##      StyleBoxTexture ONLY when the sheet file exists; clear removes
##      exactly that box.
##   9. DATA SEAM — `DataLoader.ui_layout` exists and the file on disk
##      is v2-shaped ({version, screens}; every screen table carries
##      {elements, lists}) — the file grows per merge gate, the shape
##      pin is the constant.

const PaletteLib := preload("res://scripts/palette.gd")
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const UiThemeLib := preload("res://scripts/ui_theme.gd")

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_derivation()
	await _test_rect_apply()
	await _test_coverage_fallback()
	_test_list_rect()
	await _test_edits()
	await _test_revert()
	await _test_idempotence_pruning()
	_test_sheet_seam()
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


## One fresh screen state: a 60×34-tile root (the design canvas), the
## fixture table cleared, records reset.
func _rig() -> Control:
	RegistryLib._reset_for_tests()
	RegistryLib.set_table_for_tests({})
	var root := Control.new()
	root.name = "RigRoot"
	root.size = Vector2(60 * RegistryLib.TILE, 34 * RegistryLib.TILE)
	add_child(root)
	return root


func _drop_root(root: Control) -> void:
	root.queue_free()


# --- 1. Derivation ----------------------------------------------------------

func _test_derivation() -> void:
	_check(RegistryLib.TILE == PaletteLib.CHROME_TILE,
			"tile == Palette.CHROME_TILE")
	var screens: Array[String] = [
		"port", "market", "inn", "guild", "provisions", "palace",
		"tavern", "shipyard",
		"title", "nationality_select", "creation",
		"world", "chart", "hail", "fleet_picker", "autopilot_hud",
		"battle", "sandbox", "duel",
		"confirm", "save_slot", "settings", "intel_window", "dialog_box",
		"dossier", "character_card", "captain_view", "fleet_view",
		"officer_roster", "reputation_view", "gameover", "ending",
	]
	_check(RegistryLib.SCREENS == screens,
			"screen set == the 32 §4.23 ids")
	var sheets: Array[String] = [
		"panel", "button", "button_hover", "button_pressed",
		"button_focus", "field", "backdrop",
	]
	_check(RegistryLib.SHEET_IDS == sheets,
			"sheet set == the 7 assignable nine-patches")
	_check(not RegistryLib.SHEET_IDS.has("bar"),
			"the value-bar band is not assignable")
	var edit_keys: Array[String] = ["x", "y", "w", "h", "sheet"]
	_check(RegistryLib.EDIT_KEYS == edit_keys,
			"edit keys == {x, y, w, h, sheet} (rects + sheets only)")
	var retired: Array[String] = ["min_w", "min_h", "order", "anchor"]
	_check(RegistryLib.RETIRED_KEYS == retired,
			"the Phase-11 override keys are retired")
	_check(RegistryLib.FALLBACK_TILES == Rect2i(0, 0, 2, 2),
			"the coverage fallback is the authored (0, 0, 2, 2)")


# --- 2. Rect apply ------------------------------------------------------------

func _test_rect_apply() -> void:
	var root := _rig()
	var panel := Panel.new()
	root.add_child(panel)
	RegistryLib.register("market", panel, "toolbar", {"role": "panel"})
	RegistryLib.screen_active("market", root)
	var tile := float(RegistryLib.TILE)
	# Unmanaged screen (no table): the apply is a no-op.
	RegistryLib.apply_layout("market")
	_check(panel.position == Vector2.ZERO and panel.size == Vector2.ZERO,
			"unmanaged screen: the apply is a no-op")
	RegistryLib.set_table_for_tests({
		"market": {"elements": {"toolbar":
				{"x": 2, "y": 1, "w": 8, "h": 2}}},
	})
	RegistryLib.apply_layout("market")
	_check(panel.position == Vector2(2 * tile, 1 * tile),
			"rect apply: position = tiles × 32")
	_check(panel.size == Vector2(8 * tile, 2 * tile),
			"rect apply: size = tiles × 32")
	_check(panel.anchor_left == 0.0 and panel.anchor_right == 0.0
			and panel.anchor_top == 0.0 and panel.anchor_bottom == 0.0,
			"rect apply: point anchors everywhere")
	RegistryLib.apply_layout("market")
	_check(panel.position == Vector2(2 * tile, 1 * tile)
			and panel.size == Vector2(8 * tile, 2 * tile),
			"rect apply: idempotent (a second apply is the same rect)")
	_drop_root(root)
	await get_tree().process_frame
	await _test_parent_bounds_clamp()


## Rule 1 (the parent-bounds clamp) + rule 2 (the children-extent
## floor), both kept from Phase 11.
func _test_parent_bounds_clamp() -> void:
	RegistryLib._reset_for_tests()
	var root := Control.new()
	root.size = Vector2(1920, 1080)
	add_child(root)
	var host := Panel.new()
	host.size = Vector2(10 * RegistryLib.TILE, 2 * RegistryLib.TILE)
	root.add_child(host)
	RegistryLib.register("market", host, "toolbar", {"role": "panel"})
	var child := Panel.new()
	host.add_child(child)
	RegistryLib.register("market", child, "toolbar.child",
			{"role": "panel"})
	RegistryLib.screen_active("market", root)
	RegistryLib.set_table_for_tests({
		"market": {"elements": {
			"toolbar": {"x": 0, "y": 0, "w": 10, "h": 2},
			"toolbar.child": {"x": 20, "y": 9, "w": 40, "h": 8}}},
	})
	RegistryLib.apply_layout("market")
	_check(child.size == Vector2(10 * RegistryLib.TILE,
				2 * RegistryLib.TILE),
			"parent bounds: the resize clamps to the parent's size")
	_check(child.position == Vector2.ZERO,
			"parent bounds: the move clamps to the parent's origin")
	# Rule 2: the parent cannot shrink so its child ends up outside — a
	# w=3-tile data row on the host clamps UP to the child's extent. The
	# floor reads the child's CURRENT rect, so a simultaneous shrink
	# converges over two passes: pass 1 sees the child's old extent
	# (10 tiles), pass 2 sees the new one — the settled state honors
	# the guarantee (the registry's apply is the activation + edit path;
	# the settled fixpoint is the contract).
	RegistryLib.set_table_for_tests({
		"market": {"elements": {"toolbar": {"x": 0, "y": 0, "w": 3, "h": 2},
			"toolbar.child": {"x": 0, "y": 0, "w": 8, "h": 2}}},
	})
	RegistryLib.apply_layout("market")
	_check(host.size.x >= 8 * RegistryLib.TILE,
			"children-extent floor: pass 1 never shrinks below ANY "
			+ "child rect (got %s)" % str(host.size))
	RegistryLib.apply_layout("market")
	_check(host.size.x == 8 * RegistryLib.TILE,
			"children-extent floor: the settled fixpoint holds (got %s)"
					% str(host.size))
	_drop_root(root)
	await get_tree().process_frame


# --- 3. Coverage ----------------------------------------------------------------

func _test_coverage_fallback() -> void:
	var root := _rig()
	var placed := Panel.new()
	root.add_child(placed)
	RegistryLib.register("market", placed, "header", {"role": "panel"})
	# A list member: no rect row EXPECTED — its builder owns placement.
	var row := Panel.new()
	root.add_child(row)
	RegistryLib.register("market", row, "rows.copper", {"list": "rows"})
	RegistryLib.screen_active("market", root)
	RegistryLib.set_table_for_tests({
		"market": {"elements": {"header": {"x": 1, "y": 1, "w": 58, "h": 4}},
			"lists": {"rows": {"base": {"x": 1, "y": 6, "w": 58, "h": 2},
				"row_h": 2,
				"viewport": {"x": 1, "y": 6, "w": 58, "h": 24}}}},
	})
	RegistryLib.apply_layout("market")
	var tile := float(RegistryLib.TILE)
	_check(placed.position == Vector2(tile, tile)
			and placed.size == Vector2(58 * tile, 4 * tile),
			"coverage: the element with a rect row is placed")
	_check(row.position == Vector2.ZERO and row.size == Vector2.ZERO,
			"coverage: a list member is skipped (builder-owned)")
	# The fallback: a static element WITHOUT a row takes (0,0,2,2).
	var orphan := Panel.new()
	root.add_child(orphan)
	RegistryLib.register("market", orphan, "footer", {"role": "panel"})
	RegistryLib.apply_layout("market")
	_check(orphan.position == Vector2.ZERO
			and orphan.size == Vector2(2 * tile, 2 * tile),
			"coverage: a row-less static element takes the (0,0,2,2) "
			+ "fallback (the push_error is the loud trail)")
	_drop_root(root)
	await get_tree().process_frame


# --- 4. List rect -----------------------------------------------------------------

func _test_list_rect() -> void:
	RegistryLib._reset_for_tests()
	RegistryLib.set_table_for_tests({
		"market": {"elements": {},
			"lists": {"rows": {"base": {"x": 1, "y": 6, "w": 58, "h": 2},
				"row_h": 2,
				"viewport": {"x": 1, "y": 6, "w": 58, "h": 24}}}},
	})
	var tile := float(RegistryLib.TILE)
	var r0 := RegistryLib.list_rect("market", "rows", 0)
	_check(r0 == Rect2(1 * tile, 6 * tile, 58 * tile, 2 * tile),
			"list_rect(0) == base · 32")
	var r3 := RegistryLib.list_rect("market", "rows", 3)
	_check(r3 == Rect2(1 * tile, (6 + 3 * 2) * tile, 58 * tile, 2 * tile),
			"list_rect(i) == base + i·row_h (the closed form)")
	_check(RegistryLib.list_rect("market", "no_such", 0) == Rect2(),
			"list_rect: an absent list block ⇒ Rect2()")
	RegistryLib.set_table_for_tests({})


# --- 5. Edits ----------------------------------------------------------------------

func _test_edits() -> void:
	var root := _rig()
	var panel := Panel.new()
	root.add_child(panel)
	RegistryLib.register("market", panel, "header", {"role": "panel"})
	RegistryLib.screen_active("market", root)
	RegistryLib.set_table_for_tests({
		"market": {"elements": {"header": {"x": 1, "y": 1, "w": 58, "h": 4}}},
	})
	RegistryLib.apply_layout("market")
	var tile := float(RegistryLib.TILE)
	_check(panel.position == Vector2(tile, tile),
			"edit rig: the data rect landed")
	# A rect edit merges into the data rect (x=1 keeps the 58-tile
	# header inside the 60-tile rig root: 32 + 1856 ≤ 1920 — rule 1).
	RegistryLib.apply_overrides("market", "header", {"x": 1, "y": 2})
	_check(panel.position == Vector2(1 * tile, 2 * tile)
			and panel.size == Vector2(58 * tile, 4 * tile),
			"edit: x/y replaced, w/h kept from the data rect")
	RegistryLib.apply_overrides("market", "header", {"w": 40, "h": 3})
	_check(panel.size == Vector2(40 * tile, 3 * tile),
			"edit: w/h replaced")
	# Retired keys (a v1 studio message): NOTHING changes.
	RegistryLib.apply_overrides("market", "header", {"min_w": 4})
	_check(panel.position == Vector2(1 * tile, 2 * tile)
			and panel.size == Vector2(40 * tile, 3 * tile),
			"edit: a retired min_w changes nothing (tolerated v1) "
			+ "[got %s / %s]" % [str(panel.position), str(panel.size)])
	RegistryLib.apply_overrides("market", "header", {"order": 2})
	_check(panel.get_index() == 0,
			"edit: a retired order changes nothing")
	RegistryLib.apply_overrides("market", "header", {"anchor": "bottom"})
	_check(panel.anchor_top == 0.0 and panel.anchor_bottom == 0.0,
			"edit: a retired anchor changes nothing (point anchors)")
	RegistryLib.apply_overrides("market", "header", {"left": 5})
	_check(panel.position.x == 1 * tile,
			"edit: an unknown key changes nothing")
	_drop_root(root)
	await get_tree().process_frame


# --- 6. Revert ----------------------------------------------------------------------

func _test_revert() -> void:
	var root := _rig()
	var panel := Panel.new()
	root.add_child(panel)
	RegistryLib.register("inn", panel, "hero", {"role": "panel"})
	RegistryLib.screen_active("inn", root)
	var sheet_exists := ResourceLoader.exists(
			UiThemeLib.SHEET_PATHS["panel"])
	var table: Dictionary = {
		"inn": {"elements": {"hero": {"x": 0, "y": 0, "w": 3, "h": 3}}},
	}
	if sheet_exists:
		table["inn"]["elements"]["hero"]["sheet"] = "backdrop"
	RegistryLib.set_table_for_tests(table)
	RegistryLib.apply_layout("inn")
	var tile := float(RegistryLib.TILE)
	_check(panel.position == Vector2.ZERO and panel.size == Vector2(96, 96),
			"revert rig: the data rect landed")
	if sheet_exists:
		RegistryLib.apply_overrides("inn", "hero", {"sheet": "backdrop"})
		_check(panel.get_theme_stylebox("panel") is StyleBoxTexture,
				"revert rig: the sheet override installed")
	# THE Phase-12 revert: re-apply the DATA rect (no geometry baseline).
	RegistryLib.apply_overrides("inn", "hero", {"x": 10, "y": 10})
	_check(panel.position == Vector2(10 * tile, 10 * tile),
			"revert rig: the live edit moved the element")
	RegistryLib.revert_element("inn", "hero")
	_check(panel.position == Vector2.ZERO and panel.size == Vector2(96, 96),
			"revert: the DATA rect is restored")
	if sheet_exists:
		_check(not (panel.get_theme_stylebox("panel") is StyleBoxTexture),
				"revert: the sheet override is cleared")
	_drop_root(root)
	await get_tree().process_frame


# --- 7. Idempotence + pruning + the tree payload (one rig) ---------------------

func _test_idempotence_pruning() -> void:
	var root := _rig()
	var panel := Panel.new()
	root.add_child(panel)
	RegistryLib.register("guild", panel, "board", {"role": "panel"})
	RegistryLib.screen_active("guild", root)
	RegistryLib.set_table_for_tests({
		"guild": {"elements": {"board": {"x": 1, "y": 1, "w": 4, "h": 2}}},
	})
	RegistryLib.apply_layout("guild")
	var guild_rows: Array = RegistryLib.tree("guild")
	_check(guild_rows.size() == 1, "tree() lists the live record")
	var row: Dictionary = guild_rows[0]
	_check(row["id"] == "board" and row["kind"] == "free"
			and row["role"] == "panel" and row["parent"] == "",
			"tree(): id/kind/role/parent fields present")
	_check(row["rect_tiles"] == {"x": 1, "y": 1, "w": 4, "h": 2},
			"tree(): rect_tiles is the applied rect in tiles")
	_check("min_tiles" in row and "clipped" in row and "locked" in row,
			"tree(): min_tiles/clipped/locked fields present")
	_check(not row["clipped"], "tree(): a root child is not clipped")
	panel.free()  # an immediate free (not queue_free) — the pruned rec
	RegistryLib.apply_layout("guild")
	_check(RegistryLib.tree("guild").is_empty(),
			"apply_layout prunes a freed record")
	_drop_root(root)
	await get_tree().process_frame
	await _test_scroll_clipped_row()


## A row inside a ScrollContainer reports clipped=true (the containment
## guard skips clipped rows).
func _test_scroll_clipped_row() -> void:
	var root := _rig()
	var scroll := ScrollContainer.new()
	scroll.size = Vector2(58 * RegistryLib.TILE, 20 * RegistryLib.TILE)
	root.add_child(scroll)
	var content := Control.new()
	content.custom_minimum_size = Vector2(58 * RegistryLib.TILE, 60
			* RegistryLib.TILE)
	scroll.add_child(content)
	var row := Panel.new()
	content.add_child(row)
	RegistryLib.register("market", row, "rows.copper",
			{"list": "rows", "role": "panel"})
	RegistryLib.screen_active("market", root)
	var rows: Array = RegistryLib.tree("market")
	_check(rows.size() == 1 and rows[0]["clipped"] == true
			and rows[0]["parent"] == "",
			"tree(): a scroll row reports clipped (list viewport)")
	_drop_root(root)
	await get_tree().process_frame


# --- 8. Sheet seam -----------------------------------------------------------

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


# --- 9. Data seam -------------------------------------------------------------

func _test_data_seam() -> void:
	var loader := _loader()
	_check(loader != null and loader.ui_layout is Dictionary,
			"DataLoader.ui_layout exists (the §4.23 v2 table)")
	# The shipped file grows per merge gate (each converted screen's
	# table assembles in) — the seam pins the SHAPE, not emptiness:
	# every present screen carries the {elements, lists} v2 tables.
	var shaped := true
	for screen in loader.ui_layout:
		var table: Variant = loader.ui_layout[screen]
		if not (table is Dictionary) \
				or not (table.get("elements", null) is Dictionary) \
				or not (table.get("lists", null) is Dictionary):
			shaped = false
	_check(shaped and not loader.ui_layout.is_empty(),
			"the shipped ui_layout tables are v2-shaped "
			+ "(%d screens assembled)" % loader.ui_layout.size())
	var f := FileAccess.open("res://data/ui_layout.json", FileAccess.READ)
	_check(f != null, "data/ui_layout.json exists")
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		_check(parsed is Dictionary and int(parsed.get("version", 0)) == 2
				and parsed.get("screens", null) is Dictionary,
				"the shipped file is v2-shaped ({version, screens})")
		f.close()
