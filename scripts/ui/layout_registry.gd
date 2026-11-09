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
		"screen": screen_id,
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
		"parent": weakref(control.get_parent()),
		"anchors": [control.anchor_left, control.anchor_top,
			control.anchor_right, control.anchor_bottom],
		"offsets": [control.offset_left, control.offset_top,
			control.offset_right, control.offset_bottom],
		"flags": [control.size_flags_horizontal,
			control.size_flags_vertical],
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
			_apply(screen_id, id, rec, control, overrides, false)
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
	_apply(screen_id, id, rec, control, overrides, true)


## The applier core. Order: `order` (container children, unlocked) →
## `min_w`/`min_h` → geometry (`x`/`y`/`w`/`h` free; `anchor` dock) →
## `sheet`. An empty override object applies nothing.
static func _apply(screen_id: String, id: String, rec: Dictionary,
		control: Control, overrides: Dictionary,
		co_freeze: bool = false) -> void:
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
	if overrides.has("min_w") or overrides.has("min_h"):
		# The tile-quantized content floor (the 2026-11-09 grid
		# guarantee, user direction: all edited elements sit on the
		# 32×32 grid): the content minimum is font-metric (a 26 px text
		# row is 0.8 tiles), so the effective min SUBSUMES it quantized
		# UP to whole tiles — the applied size is an exact tile
		# multiple, the reply rect matches the drag, and the drawn box
		# (floored to tiles) can never disagree with the override.
		var content := control.get_minimum_size()
		var floor_x := float(ceili(content.x / float(TILE)) * TILE)
		var floor_y := float(ceili(content.y / float(TILE)) * TILE)
		# The children-extent floor (the parent-bounds rule's mirror —
		# a parent cannot shrink so its children end up outside).
		var kids := _children_extent(screen_id, id, control)
		floor_x = maxf(floor_x, float(ceili(kids.x / float(TILE)) * TILE))
		floor_y = maxf(floor_y, float(ceili(kids.y / float(TILE)) * TILE))
		if overrides.has("min_w"):
			min_size.x = max(float(int(overrides["min_w"]) * TILE),
					floor_x)
		if overrides.has("min_h"):
			min_size.y = max(float(int(overrides["min_h"]) * TILE),
					floor_y)
	control.custom_minimum_size = min_size
	# The min-authoritative flag pin (the 2026-11-09 drag-resize fix):
	# with the default FILL flags the parent's allotted size always won —
	# a min override could only ever GROW a stretched child, and the
	# studio's dragged box snapped back to max width on release. A min
	# override on a container child therefore pins BOTH size flags to
	# shrink-begin: the control measures exactly its custom min (the
	# dragged size), aligned to the flow origin. Revert restores the
	# captured flags; with no override the parent's stretch is untouched.
	if kind == KIND_CHILD and (overrides.has("min_w")
			or overrides.has("min_h")) \
			and control.get_parent() is Container:
		control.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		control.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	# 3. Geometry. A container child that receives an x/y override
	# LEAVES ITS FLOW CONTAINER (the 2026-11-09 user direction — drag
	# must move anything, within the registered parent): it is
	# re-parented to the screen root and CONFINED to the registered
	# parent's rect (facility_grid for the cards) — the tree keeps
	# reporting the registered parent, and revert re-inserts the
	# element at its baseline slot.
	var eff_kind := kind
	if kind == KIND_CHILD and (overrides.has("x") or overrides.has("y")):
		_break_out_of_flow(control, rec, co_freeze)
		eff_kind = KIND_FREE
	if overrides.has("anchor"):
		_apply_anchor(control, overrides)
	elif eff_kind == KIND_FREE:
		# Capture BEFORE the anchor reset (the 2026-11-09 resize fix):
		# `set_anchors_preset` rewrites the offsets for the new point
		# anchors, so a `size` read after it is the reset's artifact —
		# a resize-only override collapsed every non-overridden axis of
		# a non-point-anchored control (full-rect panels) to its content
		# floor (the "a bit wider or taller" report).
		var pos := control.position
		var size := control.size
		if overrides.has("x"):
			pos.x = float(int(overrides["x"]) * TILE)
		if overrides.has("y"):
			pos.y = float(int(overrides["y"]) * TILE)
		control.set_anchors_preset(Control.PRESET_TOP_LEFT)
		control.position = pos
		if overrides.has("w"):
			size.x = float(int(overrides["w"]) * TILE)
		if overrides.has("h"):
			size.y = float(int(overrides["h"]) * TILE)
		# The same grid guarantee as the min floor above: a free resize
		# subsumes the tile-quantized content floor AND the
		# children-extent floor (a parent cannot shrink so its children
		# end up outside), so the settled rect is an exact tile multiple
		# and every registered child stays inside.
		var content := control.get_minimum_size()
		var kids := _children_extent(screen_id, id, control)
		size.x = max(size.x, float(ceili(content.x / float(TILE)) * TILE),
				float(ceili(kids.x / float(TILE)) * TILE))
		size.y = max(size.y, float(ceili(content.y / float(TILE)) * TILE),
				float(ceili(kids.y / float(TILE)) * TILE))
		# The parent-bounds clamp (2026-11-09 user direction): an
		# element cannot move or resize outside its parent — the clamp
		# runs in the DIRECT parent's local space, which is exact for
		# the plain-translation hierarchies this game builds (no
		# rotations/scales). The screen root is the outermost parent.
		var lp := control.get_parent()
		var oof: bool = rec.get("out_of_flow", false)
		if oof:
			# Broken-out elements are confined to the REGISTERED parent's
			# rect captured at break-out (facility_grid for the cards) —
			# "move within its parent", even though the direct parent is
			# now the screen root.
			var fb: Array = rec.get("flow_bounds",
					[0.0, 0.0, 1920.0, 1080.0])
			size.x = minf(size.x, fb[2])
			size.y = minf(size.y, fb[3])
			control.size = size
			pos.x = clampf(pos.x, fb[0], maxf(fb[0], fb[0] + fb[2] - size.x))
			pos.y = clampf(pos.y, fb[1], maxf(fb[1], fb[1] + fb[3] - size.y))
		elif lp is Control:
			var psize: Vector2 = (lp as Control).size
			# A parent that reports no size yet (pre-layout, an unsized
			# rig) has NO reliable bounds — the clamp must not collapse
			# the element to zero. Skip until the parent measures up.
			if psize.x > 0 and psize.y > 0:
				size.x = minf(size.x, psize.x)
				size.y = minf(size.y, psize.y)
				pos.x = clampf(pos.x, 0.0, maxf(0.0, psize.x - size.x))
				pos.y = clampf(pos.y, 0.0, maxf(0.0, psize.y - size.y))
		control.position = pos
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


## The children-extent floor (the 2026-11-09 user direction — a parent
## cannot shrink so its children end up outside): the right/bottom edge
## (px, in `parent`'s LOCAL space) of every registered child whose
## registered parent is `parent_id`. Dead records are skipped; the
## caller quantizes UP to whole tiles.
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
		var row_parent := String(rec.get("flow_parent",
				_registered_ancestor(screen_id, child)))
		if row_parent != parent_id:
			continue
		var edge := (child.global_position - pr.position) + child.size
		extent.x = maxf(extent.x, edge.x)
		extent.y = maxf(extent.y, edge.y)
	return extent


## THE CO-FLOW FREEZE — LIVE DRAGS ONLY (`co_freeze`; boot-time applies
## via `apply_screen` pass false and break out just the overridden
## element, deterministically at its committed position): when a child
## leaves a flow container, the container RE-FLOWS and every remaining
## sibling shifts into the vacated slot. So a live break-out freezes ALL
## in-flow registered siblings of the same registered parent too — each
## at its CURRENT (settled, post-layout) visual rect, re-parented to the
## screen root and confined to the same registered parent's rect.
## Nothing on screen moves except what the user drags; the siblings
## become individually draggable.
static func _break_out_of_flow(control: Control, rec: Dictionary,
		co_freeze: bool) -> void:
	var root_ref: WeakRef = _roots.get(_current)
	var root = root_ref.get_ref() if root_ref != null else null
	var parent := control.get_parent()
	if root == null or parent == null or parent == root:
		return
	var anc_id := _registered_ancestor(_current, control)
	var bounds := Rect2(0.0, 0.0, 1920.0, 1080.0)
	if anc_id != "":
		var anc := _live(_screens.get(_current, {}).get(anc_id, {}))
		if anc != null:
			bounds = Rect2(anc.global_position, anc.size)
	# The co-flow freeze — LIVE DRAGS ONLY: at boot (apply_screen) the
	# siblings have not settled yet (pre-layout positions), so freezing
	# there would pile them at the origin; the committed layout applies
	# deterministically without a freeze. During a live drag the screen
	# is long-settled and the freeze preserves the visual state.
	var to_break: Array = []
	if co_freeze:
		for id in _screens.get(_current, {}):
			var other_rec: Dictionary = _screens[_current][id]
			if other_rec == rec:
				continue
			var other := _live(other_rec)
			if other == null or other_rec.get("out_of_flow", false):
				continue
			var other_parent := String(other_rec.get("flow_parent",
					_registered_ancestor(_current, other)))
			if other_parent == anc_id:
				to_break.append([other, other_rec])
	for entry in to_break:
		var other: Control = entry[0]
		var other_rec: Dictionary = entry[1]
		var gpos := other.global_position
		var other_parent: Node = other.get_parent()
		other_rec["flow_parent"] = anc_id
		other_rec["flow_bounds"] = [bounds.position.x, bounds.position.y,
			bounds.size.x, bounds.size.y]
		other_parent.remove_child(other)
		root.add_child(other)
		other.global_position = gpos
		other_rec["out_of_flow"] = true
	rec["flow_parent"] = anc_id
	rec["flow_bounds"] = [bounds.position.x, bounds.position.y,
		bounds.size.x, bounds.size.y]
	parent.remove_child(control)
	root.add_child(control)
	rec["out_of_flow"] = true

## Auto-kind: `free` when the control's parent is the registered screen
## root, `child` otherwise (an explicit kind wins). An element that left
## its flow container (break-out) edits as FREE — its geometry is
## root-owned and confined to the registered parent's rect.
static func _resolve_kind(rec: Dictionary, control: Control) -> String:
	if rec.get("out_of_flow", false):
		return KIND_FREE
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
	# A broken-out element first returns to its FLOW slot: the original
	# parent (from the baseline) at the baseline sibling index — then the
	# kind-based restore below re-establishes the container-owned state.
	if rec.get("out_of_flow", false):
		var pref: WeakRef = baseline.get("parent")
		var orig = pref.get_ref() if pref != null else null
		if orig != null and control.get_parent() != orig:
			control.get_parent().remove_child(control)
			orig.add_child(control)
		rec["out_of_flow"] = false
	var kind := _resolve_kind(rec, control)
	if kind == KIND_CHILD:
		# Container-owned geometry (the 2026-11-09 live-session fix): a
		# container child's position/size belong to its parent's layout —
		# the baseline captured them at `_ready`, BEFORE the first layout
		# pass, so restoring them slammed a stale pre-layout size onto the
		# control (the reported facility_grid 58 → 20 shrink). A child
		# revert restores only what the code owns: the min-size floor,
		# the sibling slot, the sheet, and the size flags (the min-
		# override flag pin — a stretched child with a min override runs
		# shrink-begin, and reverting the override must un-pin it).
		control.custom_minimum_size = baseline["min"]
		var flags: Array = baseline.get("flags", [])
		if flags.size() == 2:
			control.size_flags_horizontal = flags[0]
			control.size_flags_vertical = flags[1]
		var parent := control.get_parent()
		if parent != null:
			parent.move_child(control,
					clampi(int(baseline["index"]), 0,
					parent.get_child_count() - 1))
	else:
		control.position = baseline["position"]
		control.size = baseline["size"]
		control.custom_minimum_size = baseline["min"]
		var free_parent := control.get_parent()
		if free_parent != null:
			free_parent.move_child(control,
					clampi(int(baseline["index"]), 0,
					free_parent.get_child_count() - 1))
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
		var row: Dictionary = {
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
			# A broken-out element keeps nesting under its REGISTERED
			# parent (facility_grid for the cards) even though its live
			# parent is now the screen root — the studio's hierarchy,
			# drag clamp and inspector all follow the registered chain.
			"parent": String(rec.get("flow_parent",
					_registered_ancestor(screen_id, control))),
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


## The control's CONTENT minimum (docs/80-* §4.8.9 drag floor):
## `get_minimum_size()` excludes `custom_minimum_size` — the override's
## own floor is the studio's to manage, so the drag floor must not
## include it (a min-driven child could otherwise never shrink). Ceiled
## to tiles (a 33 px text row demands 2 whole tiles).
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


## The live edit-state of one element for the bridge's debug log (the
## 2026-11-09 resize-repro instrumentation): `{baseline, rect_px,
## position_px, custom_min_px, content_min_px, flags}` — `{}` when the
## element is unknown. Read-only; production logging only.
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
