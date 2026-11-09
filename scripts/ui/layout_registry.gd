class_name LayoutRegistry
extends RefCounted
## The Phase-11 layout-override id registry + applier (docs/80-UI-UX.md
## §4.8.9; docs/10-* §4.23; docs/90-ARCHITECTURE.md §4 `scripts/ui/`).
##
## Every named control on a port screen registers here at build time with
## a stable hierarchical id (`market.toolbar.invest`,
## `market.rows.<good_id>.qty_field` — dynamic children use data-derived
## segments). When the screen activates (`screen_active`), the committed
## override table `data/ui_layout.json` (read through DataLoader's
## `ui_layout` table) is applied per element:
##
##   * free children (direct child of the screen root): absolute
##     `x`/`y`/`w`/`h` in chrome tiles (1 tile = `Palette.CHROME_TILE`);
##   * anchored free children (the bars): edge-dock by `anchor` — the
##     docked axis derives from the named edge (`h`/`w` span in tiles),
##     `y` is illegal with an anchor (validator group 14);
##   * container children: `min_w`/`min_h` (→ `custom_minimum_size`) and
##     `order` (sibling move; IGNORED for `data_ordered` registrations —
##     the §4.8.1 facility grid and market row order are data contracts);
##   * any skinned control (`role` ≠ plain): `sheet` — one of the 7
##     assignable nine-patch ids, installed through `UiTheme.sheet_override`
##     (all stylebox construction stays in `ui_theme.gd` — the §4.9
##     no-per-screen-styling rule and the styling-audit empty allowlist).
##
## The table ships `{}`: an absent override ⇒ the code-pinned default, so
## every existing locale layout pin keeps holding byte-identically.
##
## Live bridge path: `LayoutBridge` (the debug-gated WS autoload, §5.7)
## drives `apply_overrides` / `revert_element` / `reset_screen` /
## `tree` on the RUNNING tree — registration baselines (position/size/
## min-size/index/anchors/offsets, captured once at first activation)
## are what a revert restores. The bridge never persists anything; a
## screen re-entry re-applies the COMMITTED table only.
##
## Self-pruning: records whose control died (a rebuilt market, a freed
## scene) are dropped during the apply walk; a re-registration under the
## same id replaces the record and recaptures the baseline (new node).
## Headless-safe: everything here is plain math + Control mutation; the
## table read falls back to `{}` when DataLoader is absent (direct-boot
## suites inject fixtures through `set_table_for_tests`).

const PaletteLib := preload("res://scripts/palette.gd")
const UiThemeLib := preload("res://scripts/ui_theme.gd")

## The chrome tile — the ONLY chrome pixel number (docs/80-* §4.8).
const TILE := PaletteLib.CHROME_TILE

## The 8 pilot screen ids (docs/10-* §4.23). Registration under an
## unknown screen id is a `push_error` + ignored record.
const SCREENS: Array[String] = [
	"port", "market", "inn", "guild", "provisions", "palace",
	"tavern", "shipyard",
]

## The legal element-object keys (docs/10-* §4.23). Anything else in a
## live apply is ignored with a `push_error` (the validator group 14 is
## the hard gate for the committed file).
const OVERRIDE_KEYS: Array[String] = [
	"x", "y", "w", "h", "min_w", "min_h", "order", "anchor", "sheet",
]

## The 7 assignable nine-patch sheet ids (docs/80-* §4.8.9 — the 48×16
## value-bar band is NOT assignable).
const SHEET_IDS: Array[String] = [
	"panel", "button", "button_hover", "button_pressed", "button_focus",
	"field", "backdrop",
]

## Registration roles — what a `sheet` override may target. `plain`
## controls ignore `sheet` (no skinned stylebox to swap).
const ROLE_PANEL := "panel"
const ROLE_BUTTON := "button"
const ROLE_FIELD := "field"
const ROLE_PLAIN := "plain"

## Kinds: `free` = direct child of the screen root (absolute tiles),
## `child` = inside a container (min-size + order), `anchored` = edge
## dock (the bars). `""` = auto-resolved at apply time from the parent.
const KIND_FREE := "free"
const KIND_CHILD := "child"
const KIND_ANCHORED := "anchored"

# --- State -------------------------------------------------------------------

## screen_id → {id → record}. Records: `{control: WeakRef, kind: String,
## role: String, data_ordered: bool, baseline: Dictionary, sheet: String}`.
static var _screens: Dictionary = {}
## screen_id → WeakRef of the root Control (the auto-kind reference).
static var _roots: Dictionary = {}
## The screen id of the last `screen_active` call.
static var _current: String = ""
## The suite's fixture table (bypasses the DataLoader read when non-empty).
static var _test_table: Dictionary = {}


# --- Registration ------------------------------------------------------------

## Registers one named control. `opts` keys: `kind` (""/free/child/
## anchored), `role` (panel/button/field/plain), `data_ordered` (bool).
## Re-registration under the same id REPLACES the record (a rebuilt
## dynamic row is a new node — the baseline recaptures); a duplicate id
## within one build is a `push_error` (the ids are the contract).
static func register(screen_id: String, control: Control, id: String,
		opts: Dictionary = {}) -> void:
	if not (screen_id in SCREENS):
		push_error("LayoutRegistry: unknown screen '%s'" % screen_id)
		return
	if control == null or id.is_empty():
		push_error("LayoutRegistry: %s register('%s') — null control or id"
				% [screen_id, id])
		return
	var kind: String = opts.get("kind", "")
	if kind != "" and kind != KIND_FREE and kind != KIND_CHILD \
			and kind != KIND_ANCHORED:
		push_error("LayoutRegistry: %s '%s' bad kind '%s'"
				% [screen_id, id, kind])
		return
	var role: String = opts.get("role", ROLE_PLAIN)
	if role != ROLE_PANEL and role != ROLE_BUTTON and role != ROLE_FIELD \
			and role != ROLE_PLAIN:
		push_error("LayoutRegistry: %s '%s' bad role '%s'"
				% [screen_id, id, role])
		return
	var per_screen: Dictionary = _screens.get(screen_id, {})
	if per_screen.is_empty() and not _screens.has(screen_id):
		_screens[screen_id] = per_screen
	var rec: Dictionary = {
		"control": weakref(control),
		"kind": kind,
		"role": role,
		"data_ordered": bool(opts.get("data_ordered", false)),
		"baseline": {},
		"sheet": "",
	}
	if per_screen.has(id):
		# The rebuild flow (2026-11-09 master adjudication, amended after
		# the live port-hub session): a rebuilt row re-registers while the
		# OLD nodes still exist inside their teardown window — and a
		# queued WRAPPER frees its descendants WITHOUT setting their own
		# `is_queued_for_deletion()` flag (the port hub's facility pairs:
		# the pair is queued, its `cards.<id>.status` labels are not — the
		# user-reported duplicate-id notice was exactly this). The reliable
		# doomed predicate is tree membership: a replacement always removes
		# the old node (directly, or via its queued ancestor) BEFORE the
		# new registration, so only a control STILL INSIDE the tree is a
		# genuine contract breach (the ids are the contract, §4.8.9).
		var existing := _live(per_screen[id])
		if existing != null and existing.is_inside_tree():
			push_error("LayoutRegistry: %s duplicate id '%s'"
					% [screen_id, id])
	per_screen[id] = rec


## The screen's `_ready` hook: pins the active screen + root, captures
## baselines, applies the committed table, and notifies the bridge (a
## plain has_method-guarded call — no hard autoload dependency).
static func screen_active(screen_id: String, root: Control) -> void:
	if not (screen_id in SCREENS) or root == null:
		return
	_current = screen_id
	_roots[screen_id] = weakref(root)
	for id in _screens.get(screen_id, {}):
		var rec: Dictionary = _screens[screen_id][id]
		var control := _live(rec)
		if control != null and rec["baseline"].is_empty():
			rec["baseline"] = _capture(control)
	apply_screen(screen_id)
	var bridge: Node = Engine.get_main_loop().root.get_node_or_null(
			"LayoutBridge")
	if bridge != null and bridge.has_method("on_screen_changed"):
		bridge.on_screen_changed(screen_id)


## The current screen id (the bridge's default screen).
static func current_screen() -> String:
	return _current


## The live control of a record (null when the node died).
static func _live(rec: Dictionary) -> Control:
	var ref: WeakRef = rec.get("control")
	if ref == null:
		return null
	var obj = ref.get_ref()
	return obj as Control


## One baseline snapshot — what `revert_element` restores.
static func _capture(control: Control) -> Dictionary:
	return {
		"position": control.position,
		"size": control.size,
		"min": control.custom_minimum_size,
		"index": control.get_index(),
		"anchors": [control.anchor_left, control.anchor_top,
			control.anchor_right, control.anchor_bottom],
		"offsets": [control.offset_left, control.offset_top,
			control.offset_right, control.offset_bottom],
	}


# --- Override reads ----------------------------------------------------------

## The committed override table (the suite's fixture table wins when
## set; DataLoader's `ui_layout` otherwise; `{}` without either).
static func _layout_table() -> Dictionary:
	if not _test_table.is_empty():
		return _test_table
	var loader: Node = Engine.get_main_loop().root.get_node_or_null(
			"DataLoader")
	if loader != null and loader.ui_layout is Dictionary:
		return loader.ui_layout
	return {}


## The suite's fixture injection (production never calls this).
static func set_table_for_tests(table: Dictionary) -> void:
	_test_table = table


# --- Applying ----------------------------------------------------------------

## Applies every committed override of one screen. Records whose control
## died are pruned here (the self-pruning walk). Idempotent.
static func apply_screen(screen_id: String) -> void:
	var per_screen: Dictionary = _screens.get(screen_id, {})
	var table: Dictionary = _layout_table().get(screen_id, {})
	var dead: Array[String] = []
	for id in per_screen:
		var rec: Dictionary = per_screen[id]
		var control := _live(rec)
		if control == null:
			dead.append(id)
			continue
		var overrides: Dictionary = table.get(id, {})
		if not overrides.is_empty():
			_apply(rec, control, overrides)
	for id in dead:
		per_screen.erase(id)


## The live bridge path: one element, one override object. Unknown keys
## are ignored with a `push_error` (never crash the running screen).
static func apply_overrides(screen_id: String, id: String,
		overrides: Dictionary) -> void:
	var rec := _record(screen_id, id)
	if rec.is_empty():
		return
	var control := _live(rec)
	if control == null:
		return
	for key in overrides:
		if not (key in OVERRIDE_KEYS):
			push_error("LayoutRegistry: %s '%s' unknown key '%s'"
					% [screen_id, id, key])
			return
	_apply(rec, control, overrides)


## The applier core. Order: `order` (container children, unlocked) →
## `min_w`/`min_h` → geometry (`x`/`y`/`w`/`h` free; `anchor` dock) →
## `sheet`. An empty override object applies nothing.
static func _apply(rec: Dictionary, control: Control,
		overrides: Dictionary) -> void:
	if overrides.is_empty():
		return
	var kind := _resolve_kind(rec, control)
	# 1. `order` — container children only, never data-ordered ones.
	if overrides.has("order"):
		if kind == KIND_CHILD and not bool(rec.get("data_ordered")):
			var parent := control.get_parent()
			if parent != null:
				parent.move_child(control,
						clampi(int(overrides["order"]), 0,
						parent.get_child_count() - 1))
		elif bool(rec.get("data_ordered")):
			push_error("LayoutRegistry: order override on a locked control"
					+ " is ignored (data_ordered)")
	# 2. `min_w` / `min_h` — merged per axis (absent axis untouched).
	var min_size := control.custom_minimum_size
	if overrides.has("min_w"):
		min_size.x = float(int(overrides["min_w"]) * TILE)
	if overrides.has("min_h"):
		min_size.y = float(int(overrides["min_h"]) * TILE)
	control.custom_minimum_size = min_size
	# 3. Geometry.
	if overrides.has("anchor"):
		_apply_anchor(control, overrides)
	elif kind == KIND_FREE:
		var pos := control.position
		if overrides.has("x"):
			pos.x = float(int(overrides["x"]) * TILE)
		if overrides.has("y"):
			pos.y = float(int(overrides["y"]) * TILE)
		control.set_anchors_preset(Control.PRESET_TOP_LEFT)
		control.position = pos
		var size := control.size
		if overrides.has("w"):
			size.x = float(int(overrides["w"]) * TILE)
		if overrides.has("h"):
			size.y = float(int(overrides["h"]) * TILE)
		control.size = size
	# 4. `sheet` — skinned roles only; `plain` ignores it by contract.
	if overrides.has("sheet"):
		var sheet := String(overrides["sheet"])
		var role := String(rec.get("role", ROLE_PLAIN))
		if sheet in SHEET_IDS and role != ROLE_PLAIN \
				and UiThemeLib.sheet_override(control, role, sheet):
			rec["sheet"] = sheet
		else:
			push_error("LayoutRegistry: sheet override '%s' not applicable"
					% sheet + " (role %s)" % role)

## Auto-kind: `free` when the control's parent is the registered screen
## root, `child` otherwise (an explicit kind wins).
static func _resolve_kind(rec: Dictionary, control: Control) -> String:
	var kind := String(rec.get("kind", ""))
	if kind != "":
		return kind
	var root_ref: WeakRef = _roots.get(_current)
	var root = root_ref.get_ref() if root_ref != null else null
	return KIND_FREE if control.get_parent() == root else KIND_CHILD


## The `anchor` dock (docs/80-* §4.8.9): the docked axis derives from the
## named edge; the cross axis of a top/bottom bar stays x/w-addressable;
## left/right anchors leave the vertical axis code-owned. `y` is illegal
## with an anchor (group 14) and is never read here.
static func _apply_anchor(control: Control, overrides: Dictionary) -> void:
	var anchor := String(overrides["anchor"])
	var x_px := float(int(overrides.get("x", 0)) * TILE)
	var w_px := float(int(overrides.get("w", 0)) * TILE)
	var h_px := float(int(overrides.get("h", 0)) * TILE)
	match anchor:
		"bottom":
			control.anchor_top = 1.0
			control.anchor_bottom = 1.0
			control.offset_bottom = 0.0
			if overrides.has("h"):
				control.offset_top = -h_px
			if overrides.has("x"):
				control.offset_left = x_px
			if overrides.has("w"):
				control.offset_right = control.offset_left + w_px
		"top":
			control.anchor_top = 0.0
			control.anchor_bottom = 0.0
			control.offset_top = 0.0
			if overrides.has("h"):
				control.offset_bottom = h_px
			if overrides.has("x"):
				control.offset_left = x_px
			if overrides.has("w"):
				control.offset_right = control.offset_left + w_px
		"left":
			control.anchor_left = 0.0
			control.anchor_right = 0.0
			control.offset_left = 0.0
			if overrides.has("w"):
				control.offset_right = w_px
		"right":
			control.anchor_left = 1.0
			control.anchor_right = 1.0
			control.offset_right = 0.0
			if overrides.has("w"):
				control.offset_left = -w_px
		_:
			push_error("LayoutRegistry: bad anchor '%s'" % anchor)


# --- Live revert -------------------------------------------------------------

## Restores one element's registration baseline (position/size/min-size/
## sibling index/anchors/offsets) and removes its sheet override. The
## bridge's `revert` message lands here.
static func revert_element(screen_id: String, id: String) -> void:
	var rec := _record(screen_id, id)
	if rec.is_empty():
		return
	var control := _live(rec)
	if control == null:
		return
	var baseline: Dictionary = rec.get("baseline", {})
	if baseline.is_empty():
		return
	control.position = baseline["position"]
	control.size = baseline["size"]
	control.custom_minimum_size = baseline["min"]
	var parent := control.get_parent()
	if parent != null:
		parent.move_child(control,
				clampi(int(baseline["index"]), 0,
				parent.get_child_count() - 1))
	var anchors: Array = baseline["anchors"]
	control.anchor_left = anchors[0]
	control.anchor_top = anchors[1]
	control.anchor_right = anchors[2]
	control.anchor_bottom = anchors[3]
	var offsets: Array = baseline["offsets"]
	control.offset_left = offsets[0]
	control.offset_top = offsets[1]
	control.offset_right = offsets[2]
	control.offset_bottom = offsets[3]
	if not String(rec.get("sheet", "")).is_empty():
		UiThemeLib.clear_sheet_override(control, String(rec["role"]))
		rec["sheet"] = ""


## Reverts every element of one screen (the bridge's `reset_screen`).
static func reset_screen(screen_id: String) -> void:
	for id in _screens.get(screen_id, {}):
		revert_element(screen_id, id)


# --- Bridge tree dump ----------------------------------------------------------

## The per-screen element dump for the bridge's `tree` message: one row
## per live record — `{id, kind, role, rect_tiles, sheet, locked,
## parent, clipped}` — in registration order. `rect_tiles` is the
## control's rect relative to the screen root, floored to tiles;
## `parent` is the nearest registered ancestor's id (`""` when none);
## `clipped` is true when a ScrollContainer ancestor owns the control's
## visibility (its content rect may legitimately exceed the canvas —
## the containment guard skips clipped rows).
static func tree(screen_id: String) -> Array:
	var per_screen: Dictionary = _screens.get(screen_id, {})
	var root_ref: WeakRef = _roots.get(screen_id)
	var root = root_ref.get_ref() if root_ref != null else null
	var rows: Array = []
	for id in per_screen:
		var rec: Dictionary = per_screen[id]
		var control := _live(rec)
		if control == null:
			continue
		var rel := Vector2.ZERO
		var size_tiles := Vector2i.ZERO
		if root != null:
			rel = control.global_position - root.global_position
		size_tiles = Vector2i(
			roundi(control.size.x / float(TILE)),
			roundi(control.size.y / float(TILE)))
		rows.append({
			"id": id,
			"kind": _resolve_kind(rec, control),
			"role": String(rec.get("role", ROLE_PLAIN)),
			"rect_tiles": {
				"x": floori(rel.x / float(TILE)),
				"y": floori(rel.y / float(TILE)),
				"w": size_tiles.x,
				"h": size_tiles.y,
			},
			"sheet": String(rec.get("sheet", "")),
			"locked": bool(rec.get("data_ordered")),
			"parent": _registered_ancestor(screen_id, control),
			"clipped": _inside_scroll(control),
		})
	return rows


## True when a ScrollContainer ancestor owns the control's visibility.
static func _inside_scroll(control: Control) -> bool:
	var node := control.get_parent()
	while node is Control:
		if node is ScrollContainer:
			return true
		node = node.get_parent()
	return false


## The nearest registered ancestor's id (the bridge draws the nesting).
static func _registered_ancestor(screen_id: String, control: Control) -> String:
	var per_screen: Dictionary = _screens.get(screen_id, {})
	var node := control.get_parent()
	while node is Control:
		for id in per_screen:
			var other := _live(per_screen[id])
			if other == node:
				return id
		node = node.get_parent()
	return ""


# --- Internals -----------------------------------------------------------------

## One record lookup with validation (empty dict = miss).
static func _record(screen_id: String, id: String) -> Dictionary:
	if not (screen_id in SCREENS):
		push_error("LayoutRegistry: unknown screen '%s'" % screen_id)
		return {}
	var rec: Dictionary = _screens.get(screen_id, {}).get(id, {})
	if rec.is_empty():
		push_error("LayoutRegistry: %s has no '%s'" % [screen_id, id])
	return rec


## Test seam: forget every screen's records, roots and fixture table
## (production never calls this).
static func _reset_for_tests() -> void:
	_screens = {}
	_roots = {}
	_current = ""
	_test_table = {}
