class_name LayoutRegistry
extends RefCounted
## The Phase-12 absolute-tile layout registry (docs/80-UI-UX.md §4.8.9;
## docs/10-* §4.23; docs/90-ARCHITECTURE.md §4 `scripts/ui/`).
##
## THE DATA FILE IS THE LAYOUT: `data/ui_layout.json` v2 holds every
## static element's rect `{x, y, w, h}` in chrome tiles (1 tile =
## `Palette.CHROME_TILE`), parent-relative — a child's tiles address
## space is its parent's rect; top-level elements are screen tiles on
## the 60 × 33.75 canvas. There are NO code defaults underneath: a
## managed screen's table is the whole truth for its static elements.
##
## Every persistent control registers at build time with a stable
## hierarchical id (`market.header.back`,
## `market.rows.<good_id>.qty_field` — dynamic children use
## data-derived segments). When the screen activates
## (`screen_active`), `apply_layout` walks the records PARENTS-FIRST and
## places every element with a rect row:
##
##   * point anchors everywhere (nothing is ever stretched);
##   * `position = (x, y) · 32`, `size = max((w, h) · 32,
##     content-min quantized up, registered-children extent)`;
##   * clamped inside the direct parent's rect (rule 1);
##   * the size floor subsumes the children-extent floor (rule 2 — a
##     parent cannot shrink so its children end up outside).
##
## Dynamic lists (market goods rows, officer rosters …) are NOT placed
## from element rows: the screen declares a list block
## `{base, row_h, viewport}` in the data and its row builders take
## `list_rect(screen, list, i)` = `base + i·row_h` inside the
## viewport's content node (a plain Control sized to the stacked
## extent). A ScrollContainer survives ONLY as such a clipped viewport.
##
## The Phase-11 override machinery is DELETED: break-out-of-flow +
## `flow_parent`/`flow_bounds` + the co-flow freeze, the
## min-override flag pins, the child/free/anchored apply split, the
## 4-frame settle wait, the min-override dance. Edits (the bridge)
## carry `{x, y, w, h}` + `sheet` only — every element edits its rect,
## one path for all. Revert re-applies the data rect.
##
## Self-pruning: records whose control died are dropped during the
## apply walk; a re-registration under the same id replaces the record.
## Headless-safe: plain math + Control mutation; the table read falls
## back to `{}` when DataLoader is absent (direct-boot suites inject
## fixtures through `set_table_for_tests`).

const PaletteLib := preload("res://scripts/palette.gd")
const UiThemeLib := preload("res://scripts/ui_theme.gd")

## The chrome tile — the ONLY chrome pixel number (docs/80-* §4.8).
const TILE := PaletteLib.CHROME_TILE

## The full screen set (docs/10-* §4.23 — the Phase-12 32 ids).
## Registration under an unknown screen id is a `push_error` + ignored
## record.
const SCREENS: Array[String] = [
	# The Phase-11 pilot eight.
	"port", "market", "inn", "guild", "provisions", "palace",
	"tavern", "shipyard",
	# The title trio.
	"title", "nationality_select", "creation",
	# The world family.
	"world", "chart", "hail", "fleet_picker", "autopilot_hud",
	# The combat trio.
	"battle", "sandbox", "duel",
	# The shared modals.
	"confirm", "save_slot", "settings", "intel_window", "dialog_box",
	"dossier", "character_card", "captain_view", "fleet_view",
	"officer_roster", "reputation_view", "gameover", "ending",
]

## The legal edit keys — a rect + an optional sheet (docs/10-* §4.23).
## The Phase-11 `min_w`/`min_h`/`order`/`anchor` overrides are RETIRED
## (`90-*` §5.7): an edit carrying one is answered with an error and
## changes nothing.
const EDIT_KEYS: Array[String] = ["x", "y", "w", "h", "sheet"]

## The retired keys, named in the edit-error message (v1 studio
## sessions are tolerated without effect until the studio's W3 lands).
const RETIRED_KEYS: Array[String] = ["min_w", "min_h", "order", "anchor"]

## The 7 assignable nine-patch sheet ids (docs/80-* §4.8.9 — the 48×16
## value-bar band is NOT assignable).
const SHEET_IDS: Array[String] = [
	"panel", "button", "button_hover", "button_pressed", "button_focus",
	"field", "backdrop",
]

## Registration roles — what a `sheet` assignment may target. `plain`
## controls ignore `sheet` (no skinned stylebox to swap).
const ROLE_PANEL := "panel"
const ROLE_BUTTON := "button"
const ROLE_FIELD := "field"
const ROLE_PLAIN := "plain"

## Tree-wording kinds (the `tree()` dump keeps reporting a kind for the
## studio inspector's resize wording; the apply paths no longer split
## on it): `free` = direct child of the screen root, `child` = nested.
const KIND_FREE := "free"
const KIND_CHILD := "child"

## The coverage fallback (docs/80-* §4.8.9): a registered STATIC element
## with no rect row on a managed screen gets this authored fallback —
## loud in the trail (the push_error), never a crash.
const FALLBACK_TILES := Rect2i(0, 0, 2, 2)

# --- State -------------------------------------------------------------------

## screen_id → {id → record}. Records: `{control: WeakRef, role: String,
## list: String, data_ordered: bool, baseline: Dictionary (trail only),
## sheet: String, applied: Dictionary (the last applied rect — the edit
## base), data_rect: Dictionary (the data row at activation — the
## revert target)}`.
static var _screens: Dictionary = {}
## screen_id → WeakRef of the root Control (the kind-wording reference).
static var _roots: Dictionary = {}
## The screen id of the last `screen_active` call.
static var _current: String = ""
## The suite's fixture table (bypasses the DataLoader read when non-empty).
static var _test_table: Dictionary = {}


# --- Registration ------------------------------------------------------------

## Registers one named control. `opts` keys: `role`
## (panel/button/field/plain), `list` (the list-block id when this
## element is a dynamic row — list rows are placed by their block, not
## by an element rect), `data_ordered` (kept for the tree dump's
## `locked` field — the studio's order-lock display). Re-registration
## under the same id REPLACES the record (a rebuilt dynamic row is a
## new node); a duplicate id within one build is a `push_error` (the
## ids are the contract).
static func register(screen_id: String, control: Control, id: String,
		opts: Dictionary = {}) -> void:
	if not (screen_id in SCREENS):
		push_error("LayoutRegistry: unknown screen '%s'" % screen_id)
		return
	if control == null or id.is_empty():
		push_error("LayoutRegistry: %s register('%s') — null control or id"
				% [screen_id, id])
		return
	var role: String = opts.get("role", ROLE_PLAIN)
	if role != ROLE_PANEL and role != ROLE_BUTTON and role != ROLE_FIELD \
			and role != ROLE_PLAIN:
		push_error("LayoutRegistry: %s '%s' bad role '%s'"
				% [screen_id, id])
		return
	var per_screen: Dictionary = _screens.get(screen_id, {})
	if per_screen.is_empty() and not _screens.has(screen_id):
		_screens[screen_id] = per_screen
	var rec: Dictionary = {
		"screen": screen_id,
		"control": weakref(control),
		"role": role,
		"list": String(opts.get("list", "")),
		"data_ordered": bool(opts.get("data_ordered", false)),
		"baseline": {},
		"sheet": "",
		"applied": {},
	}
	if per_screen.has(id):
		# The rebuild flow (2026-11-09 master adjudication, kept from
		# Phase 11): a rebuilt row re-registers while the OLD nodes still
		# exist inside their teardown window — and a queued WRAPPER frees
		# its descendants WITHOUT setting their own deletion flag. The
		# reliable doomed predicate is tree membership: a replacement
		# always removes the old node BEFORE the new registration, so
		# only a control STILL INSIDE the tree is a genuine contract
		# breach.
		var existing := _live(per_screen[id])
		if existing != null and existing.is_inside_tree():
			push_error("LayoutRegistry: %s duplicate id '%s'"
					% [screen_id, id])
	per_screen[id] = rec


## The screen's `_ready` hook: pins the active screen + root, captures
## the trail baselines, applies the data layout, and notifies the
## bridge (a plain has_method-guarded call — no hard autoload
## dependency).
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
	apply_layout(screen_id)
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


## One baseline snapshot — the debug trail's BEFORE state only (the
## Phase-12 revert re-applies the DATA rect; geometry baselines are no
## longer authoritative).
static func _capture(control: Control) -> Dictionary:
	return {
		"position": control.position,
		"size": control.size,
		"min": control.custom_minimum_size,
		"index": control.get_index(),
		"parent": weakref(control.get_parent()),
	}


# --- Data reads --------------------------------------------------------------

## The committed layout file (the suite's fixture table wins when set;
## DataLoader's `ui_layout` otherwise; `{}` without either).
static func _layout_table() -> Dictionary:
	if not _test_table.is_empty():
		return _test_table
	var loader: Node = Engine.get_main_loop().root.get_node_or_null(
			"DataLoader")
	if loader != null and loader.ui_layout is Dictionary:
		return loader.ui_layout
	return {}


## The suite's fixture injection (production never calls this).
## `table` is the per-screen map `{screen: {elements, lists}}`.
static func set_table_for_tests(table: Dictionary) -> void:
	_test_table = table


## One screen's v2 table `{elements, lists}` — `{}` when the screen is
## absent (an UNMANAGED screen: an unconverted screen keeps working on
## its authored flow until its wave lands, docs/IMPLEMENT-Phase12.md §3).
## `DataLoader.ui_layout` (and the test table) is the per-screen map;
## each value is `{elements: {}, lists: {}}`.
static func _screen_data(screen_id: String) -> Dictionary:
	var data: Variant = _layout_table().get(screen_id, null)
	if data is Dictionary:
		return data
	return {}


## The public managed-check (screens/bridge-side seams): true when the
## committed layout file carries this screen's table — the registry
## owns the screen's rects then.
static func is_managed(screen_id: String) -> bool:
	return not _screen_data(screen_id).is_empty()


## The screen's list block `{base, row_h, viewport}` in tiles.
static func _list_block(screen_id: String, list_id: String) -> Dictionary:
	var lists: Variant = _screen_data(screen_id).get("lists", {})
	if lists is Dictionary and lists.has(list_id):
		var block: Variant = lists[list_id]
		if block is Dictionary:
			return block
	return {}


## Row *i*'s rect for a list block — px, in the viewport's CONTENT-node
## space: `base.position + (0, i·row_h) · 32`, size `base.size · 32`.
## Row builders place the row node with this directly; rebuilds
## re-place. `Rect2()` when the list block is absent (the caller
## decides — an unmanaged screen's builders never call this).
static func list_rect(screen_id: String, list_id: String, index: int) -> Rect2:
	var block := _list_block(screen_id, list_id)
	var base: Variant = block.get("base", null)
	var row_h: Variant = block.get("row_h", null)
	if not (base is Dictionary) or not (row_h is int) or row_h < 1:
		return Rect2()
	var bx := float(int(base.get("x", 0))) * TILE
	var by := float(int(base.get("y", 0))) * TILE
	var bw := float(int(base.get("w", 0))) * TILE
	var bh := float(int(base.get("h", 0))) * TILE
	return Rect2(bx, by + float(index * row_h) * TILE, bw, bh)


# --- Applying ----------------------------------------------------------------

## Applies the data layout of one screen: a parents-first walk placing
## every registered element that has a rect row (list members are
## placed by their builders via `list_rect`). Records whose control
## died are pruned here (the self-pruning walk). Idempotent. A screen
## absent from the file is UNMANAGED — a no-op (unconverted screens
## keep working until their wave lands).
static func apply_layout(screen_id: String) -> void:
	var data := _screen_data(screen_id)
	if data.is_empty():
		return
	var elements: Dictionary = data.get("elements", {})
	var per_screen: Dictionary = _screens.get(screen_id, {})
	var dead: Array[String] = []
	# Parents-first: bucket the ids by registered-ancestor depth (a
	# parent's rect must be settled before its children clamp inside
	# it). Insertion order within a depth.
	var max_depth := 0
	var depth_of := {}
	for id in per_screen:
		var d := _registered_depth(screen_id, id, per_screen)
		depth_of[id] = d
		max_depth = maxi(max_depth, d)
	for depth in range(0, max_depth + 1):
		for id in per_screen:
			if int(depth_of[id]) != depth:
				continue
			var rec: Dictionary = per_screen[id]
			var control := _live(rec)
			if control == null:
				dead.append(id)
				continue
			if not String(rec.get("list", "")).is_empty():
				continue  # a dynamic row — its builder owns the placement
			var rect: Variant = elements.get(id, null)
			if rect is Dictionary and not rect.is_empty():
				_apply_rect(screen_id, id, control, rect)
				rec["applied"] = rect.duplicate()
				rec["data_rect"] = rect.duplicate()
				# A `sheet` assignment rides along (docs/10-* §4.23) —
				# the data row's nine-patch applies at apply_layout too,
				# so a committed sheet survives a restart.
				if rect.has("sheet"):
					var sheet := String(rect["sheet"])
					var role := String(rec.get("role", ROLE_PLAIN))
					if sheet in SHEET_IDS and role != ROLE_PLAIN \
							and UiThemeLib.sheet_override(control, role,
							sheet):
						rec["sheet"] = sheet
					else:
						push_error(("LayoutRegistry: %s '%s' sheet '%s'"
								+ " not applicable (role %s)")
								% [screen_id, id, sheet, role])
			else:
				# Coverage check (docs/80-* §4.8.9): a registered STATIC
				# element with no rect row on a managed screen is loud in
				# the trail and takes the authored fallback — never a
				# crash.
				push_error(("LayoutRegistry: %s '%s' has no rect row — "
						+ "applying the fallback") % [screen_id, id])
				var fb := {
					"x": FALLBACK_TILES.position.x,
					"y": FALLBACK_TILES.position.y,
					"w": FALLBACK_TILES.size.x,
					"h": FALLBACK_TILES.size.y,
				}
				_apply_rect(screen_id, id, control, fb)
				rec["applied"] = fb.duplicate()
				rec["data_rect"] = fb.duplicate()
	for id in dead:
		per_screen.erase(id)


## The Phase-11 name (the dynamic-rebuild re-apply) — the screens
## switch to `apply_layout` in their W2 waves; removed at W4.
static func apply_screen(screen_id: String) -> void:
	apply_layout(screen_id)


## The live bridge path: one element, one edit object `{x, y, w, h,
## sheet}` — every element edits its rect, one path for all. Retired
## keys (a v1 studio message) are answered with an error and change
## nothing; unknown keys likewise (never crash the running screen).
static func apply_overrides(screen_id: String, id: String,
		overrides: Dictionary) -> void:
	var rec := _record(screen_id, id)
	if rec.is_empty():
		return
	var control := _live(rec)
	if control == null:
		return
	for key in overrides:
		if key in RETIRED_KEYS:
			push_error(("LayoutRegistry: %s '%s' retired key '%s' is "
					+ "ignored (Phase 12 edits carry x/y/w/h + sheet)")
					% [screen_id, id, key])
			return
		if not (key in EDIT_KEYS):
			push_error("LayoutRegistry: %s '%s' unknown key '%s'"
					% [screen_id, id, key])
			return
	# The effective rect: the element's LAST-APPLIED rect (the data row
	# at activation, or the previous edit — so a move-then-resize edit
	# pair composes), or, when the element was never applied (a list
	# row), its current live rect quantized to tiles. The edited fields
	# replace their axes.
	var rect := _last_rect(screen_id, id, rec, control)
	for key in ["x", "y", "w", "h"]:
		if overrides.has(key):
			rect[key] = int(overrides[key])
	_apply_rect(screen_id, id, control, rect)
	rec["applied"] = rect
	# `rec["data_rect"]` (set by apply_layout) is untouched — it is the
	# revert target; a live edit must not move it.
	if overrides.has("sheet"):
		var sheet := String(overrides["sheet"])
		var role := String(rec.get("role", ROLE_PLAIN))
		if sheet in SHEET_IDS and role != ROLE_PLAIN \
				and UiThemeLib.sheet_override(control, role, sheet):
			rec["sheet"] = sheet
		else:
			push_error("LayoutRegistry: sheet override '%s' not applicable"
					% sheet + " (role %s)" % role)


## The element's edit base: the last-applied rect (`applied`) when the
## element has one; else the current live rect (relative to the direct
## parent, rounded to tiles) — a list row being edited live by the
## studio.
static func _last_rect(screen_id: String, id: String, rec: Dictionary,
		control: Control) -> Dictionary:
	var applied: Dictionary = rec.get("applied", {})
	if not applied.is_empty():
		return applied.duplicate()
	var origin := Vector2.ZERO
	var lp := control.get_parent()
	if lp is Control:
		origin = (lp as Control).global_position
	var pos: Vector2 = control.global_position - origin
	var size: Vector2 = control.size
	return {
		"x": roundi(pos.x / float(TILE)), "y": roundi(pos.y / float(TILE)),
		"w": roundi(size.x / float(TILE)), "h": roundi(size.y / float(TILE)),
	}


## THE rect applier — the only placement path (docs/80-* §4.8.9): point
## anchors, `position = (x, y)·32`, `size = max((w, h)·32,
## content-min quantized up, children extent)`, clamped inside the
## direct parent's rect. Deterministic and idempotent.
static func _apply_rect(screen_id: String, id: String, control: Control,
		rect: Dictionary) -> void:
	var px := float(int(rect.get("x", 0))) * TILE
	var py := float(int(rect.get("y", 0))) * TILE
	var pw := float(int(rect.get("w", 0))) * TILE
	var ph := float(int(rect.get("h", 0))) * TILE
	var pos := Vector2(px, py)
	var size := Vector2(pw, ph)
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = pos
	# The content floor quantized UP to whole tiles (kept from Phase 11
	# as a clamp, not a flow — content mins still guard against clipping
	# text) + the children-extent floor (rule 2: a parent cannot shrink
	# so its children end up outside).
	var content := control.get_minimum_size()
	size.x = maxf(size.x, float(ceili(content.x / float(TILE)) * TILE))
	size.y = maxf(size.y, float(ceili(content.y / float(TILE)) * TILE))
	var kids := _children_extent(screen_id, id, control)
	size.x = maxf(size.x, float(ceili(kids.x / float(TILE)) * TILE))
	size.y = maxf(size.y, float(ceili(kids.y / float(TILE)) * TILE))
	# The parent-bounds clamp (rule 1): an element cannot leave its
	# parent's rect — the clamp runs in the DIRECT parent's local space,
	# exact for this game's translation-only hierarchies. A parent with
	# no measured size yet (pre-layout) has no reliable bounds — skip
	# until it measures up (the Phase-11 zero-size guard).
	var lp := control.get_parent()
	if lp is Control:
		var psize: Vector2 = (lp as Control).size
		if psize.x > 0 and psize.y > 0:
			size.x = minf(size.x, psize.x)
			size.y = minf(size.y, psize.y)
			pos.x = clampf(pos.x, 0.0, maxf(0.0, psize.x - size.x))
			pos.y = clampf(pos.y, 0.0, maxf(0.0, psize.y - size.y))
	control.size = size
	control.position = pos


## The children-extent floor (rule 2): the right/bottom edge (px, in
## `parent`'s LOCAL space) of every registered child whose registered
## parent is `parent_id`. Dead records are skipped; the caller
## quantizes UP to whole tiles.
static func _children_extent(screen_id: String, parent_id: String,
		parent: Control) -> Vector2:
	var extent := Vector2.ZERO
	var per_screen: Dictionary = _screens.get(screen_id, {})
	var pr := Rect2(parent.global_position, parent.size)
	for id in per_screen:
		var rec: Dictionary = per_screen[id]
		var child := _live(rec)
		if child == null or child == parent:
			continue
		if _registered_ancestor(screen_id, child) != parent_id:
			continue
		var edge := (child.global_position - pr.position) + child.size
		extent.x = maxf(extent.x, edge.x)
		extent.y = maxf(extent.y, edge.y)
	return extent


## The registered-ancestor depth of one record ("" parent = depth 0).
## Missing ancestors (a dead record mid-walk) count 0 — the parents-
## first bucket still applies them before their children.
static func _registered_depth(screen_id: String, id: String,
		per_screen: Dictionary) -> int:
	var depth := 0
	var current: String = id
	while true:
		var rec: Dictionary = per_screen.get(current, {})
		var control := _live(rec)
		if control == null:
			break
		var parent_id := _registered_ancestor(screen_id, control)
		if parent_id.is_empty():
			break
		depth += 1
		current = parent_id
		if depth > 32:
			break  # a cycle guard; the ids are authored acyclic
	return depth


## The nearest registered ancestor's id ("" = the screen root).
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


# --- Live revert -------------------------------------------------------------

## Re-applies one element's DATA rect (the Phase-12 revert — geometry
## baselines are no longer authoritative) and removes its sheet
## override. An element never applied (an unmanaged screen) is a no-op.
## The bridge's `revert` message lands here.
static func revert_element(screen_id: String, id: String) -> void:
	var rec := _record(screen_id, id)
	if rec.is_empty():
		return
	var control := _live(rec)
	if control == null:
		return
	if not String(rec.get("sheet", "")).is_empty():
		UiThemeLib.clear_sheet_override(control, String(rec["role"]))
		rec["sheet"] = ""
	# The revert target is the DATA rect (captured at apply_layout) —
	# an element never applied by the layout walk (a list row on an
	# unmanaged screen) has no target and stays where its builder put it.
	var data_rect: Dictionary = rec.get("data_rect", {})
	if data_rect.is_empty():
		return
	_apply_rect(screen_id, id, control, data_rect)
	rec["applied"] = data_rect.duplicate()


## Reverts every element of one screen (the bridge's `reset_screen`).
static func reset_screen(screen_id: String) -> void:
	for id in _screens.get(screen_id, {}):
		revert_element(screen_id, id)


# --- Bridge tree dump ----------------------------------------------------------

## The per-screen element dump for the bridge's `tree` message: one row
## per live record — `{id, kind, role, list, rect_tiles, sheet, locked,
## parent, clipped, min_tiles, kids_tiles?}` — in registration order.
## `rect_tiles` is the control's rect relative to the screen root,
## floored/rounded to tiles; `parent` is the nearest registered
## ancestor's id (`""` when none); `kind` is tree WORDING only (free =
## direct child of the root); `clipped` is true when a ScrollContainer
## ancestor owns the control's visibility (the containment guard skips
## clipped rows).
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
		if root != null:
			rel = control.global_position - root.global_position
		var size_tiles := Vector2i(
			roundi(control.size.x / float(TILE)),
			roundi(control.size.y / float(TILE)))
		var row: Dictionary = {
			"id": id,
			"kind": (KIND_FREE
					if (root != null and control.get_parent() == root)
					else KIND_CHILD),
			"role": String(rec.get("role", ROLE_PLAIN)),
			# The list-block membership (docs/10-* §4.23) — the studio
			# renders list members as a locked viewport block, not
			# draggable rows.
			"list": String(rec.get("list", "")),
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
			"min_tiles": _content_min_tiles(control),
		}
		# The children-extent drag floor — only present when the element
		# has registered children (otherwise the key is omitted and the
		# studio falls back to min_tiles alone).
		var kids := _children_extent(screen_id, id, control)
		if kids.x > 0 or kids.y > 0:
			row["kids_tiles"] = {
				"w": ceili(kids.x / float(TILE)),
				"h": ceili(kids.y / float(TILE)),
			}
		rows.append(row)
	return rows


## The control's CONTENT minimum (the studio drag floor):
## `get_minimum_size()` excludes `custom_minimum_size`. Ceiled to tiles
## (a 33 px text row demands 2 whole tiles).
static func _content_min_tiles(control: Control) -> Dictionary:
	var content := control.get_minimum_size()
	return {
		"w": ceili(content.x / float(TILE)),
		"h": ceili(content.y / float(TILE)),
	}


## True when a ScrollContainer ancestor owns the control's visibility.
static func _inside_scroll(control: Control) -> bool:
	var node := control.get_parent()
	while node is Control:
		if node is ScrollContainer:
			return true
		node = node.get_parent()
	return false


# --- Capture dump (tools/layout_capture.gd) ------------------------------------

## Exact-px rows for the layout capture: one per live record —
## `{id, list, data_ordered, role, parent_id, parent_global, global_pos,
## size, content_parent_global, scroll_global, scroll_size,
## scroll_parent_global}` — everything the capture needs to emit
## parent-relative tile rects and list blocks without re-deriving the
## registered chains. Read-only; the capture tool is the only consumer.
static func capture_rows(screen_id: String) -> Array:
	var per_screen: Dictionary = _screens.get(screen_id, {})
	var root_ref: WeakRef = _roots.get(screen_id)
	var root = root_ref.get_ref() if root_ref != null else null
	var rows: Array = []
	for id in per_screen:
		var rec: Dictionary = per_screen[id]
		var control := _live(rec)
		if control == null:
			continue
		var parent_id := _registered_ancestor(screen_id, control)
		var parent_global := Vector2.ZERO
		if root != null:
			parent_global = root.global_position
		if not parent_id.is_empty():
			var p := _live(per_screen.get(parent_id, {}))
			if p != null:
				parent_global = p.global_position
		var row: Dictionary = {
			"id": id,
			"list": String(rec.get("list", "")),
			"data_ordered": bool(rec.get("data_ordered")),
			"role": String(rec.get("role", ROLE_PLAIN)),
			"parent_id": parent_id,
			"parent_global": parent_global,
			"global_pos": control.global_position,
			"size": control.size,
		}
		# The direct parent's origin — for a list member this is the
		# viewport's content node (its builder places rows in that
		# space).
		var lp := control.get_parent()
		row["content_parent_global"] = (lp as Control).global_position \
				if lp is Control else Vector2.ZERO
		# The nearest ScrollContainer ancestor — the list viewport (its
		# rect in ITS parent space is the block's viewport).
		var node := control.get_parent()
		var found := false
		while node is Control:
			if node is ScrollContainer:
				row["scroll_global"] = (node as Control).global_position
				row["scroll_size"] = (node as Control).size
				var sp := (node as Control).get_parent()
				row["scroll_parent_global"] = (sp as Control).global_position \
						if sp is Control else Vector2.ZERO
				found = true
				break
			node = node.get_parent()
		if not found:
			row["scroll_global"] = Vector2.ZERO
			row["scroll_size"] = Vector2.ZERO
			row["scroll_parent_global"] = Vector2.ZERO
		rows.append(row)
	return rows


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


## One compact state record for the bridge's debug log (the trail):
## `{baseline, rect_px, position_px, custom_min_px, content_min_px,
## flags}` — `{}` when the element is unknown. Read-only; production
## logging only. (The size flags are reported for trail continuity;
## the Phase-12 apply path never edits them.)
static func debug_state(screen_id: String, id: String) -> Dictionary:
	var rec := _record(screen_id, id)
	if rec.is_empty():
		return {}
	var control := _live(rec)
	if control == null:
		return {}
	var content := control.get_minimum_size()
	return {
		"baseline": rec.get("baseline", {}),
		"rect_px": control.size,
		"position_px": control.position,
		"custom_min_px": control.custom_minimum_size,
		"content_min_px": content,
		"flags": [control.size_flags_horizontal, control.size_flags_vertical],
	}


## Test seam: forget every screen's records, roots and fixture table
## (production never calls this).
static func _reset_for_tests() -> void:
	_screens = {}
	_roots = {}
	_current = ""
	_test_table = {}
