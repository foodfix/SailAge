extends Control
## Set-Sail provisioning prompt — a **modal over S4** (docs/80-UI-UX.md §4.6.1),
## opened by the Set Sail button *and* by `ESC` on S4 (`80-*` §4.3, `20-*`
## §4.11.2), before the S4 → S3 transition.
##
## Why this screen exists (docs/20-* §4.10): supplies are survival, not
## commerce, so they must not compete with the market's trade rows; and leaving
## port is the moment the player knows where they are going, so it is the
## moment the number matters. The market no longer sells provisions or water —
## this prompt is the single supply purchase point, and it also jettisons
## surplus so a full hold never silently drops cargo.
##
## **Every rule lives in [SailingSim] / [TradeEngine] / [Fleet]**, never here:
##   * the days-of-supply readout is `SailingSim.supply_days()` (the locked
##     §4.10 formula; this file never re-derives it);
##   * buying goes through `TradeEngine.buy_supplies()` — the only supplies
##     price path (2g / 1g, locked, unaffected by port factors);
##   * the sailing gate is `SailingSim.supply_block_reason()` (§4.11.2), the
##     same function `PortScreen.set_sail()` refuses with, so the button state
##     and the refusal can never disagree;
##   * jettison is `Fleet.jettison_good()` / `Fleet.jettison_supplies()` after
##     the shared `confirm_dialog.tscn` (§4.7), exactly the S15 flow.
##
## The **一键补满 / Auto-fill** button (§4.6.1 amended) plans the largest
## common target with `provisions = water = T` — exact integer maths over the
## locked §4.10 prices (`SailingSimLib.PROVISIONS_PRICE` / `.WATER_PRICE`) —
## and executes it through the same two paths as the rows: `Fleet
## .remove_supplies` for the discards (confirm-first, §4.7) and
## `TradeEngine.buy_supplies` for the buys. It invents no price, no cap and
## no second engine path.
##
## Sailing does **not** reimplement the transition: the enabled button calls the
## host's `set_sail()` ([member sail_host]), so there is one S4 → S3 code path.
##
## Parent-agnostic modal, same contract as [CharacterPanel]/[FleetPanel]: a host
## calls [method attach_to] in its `_ready` and then [method open]s it. While
## open it joins `modal_overlay` and consumes input (`80-*` §6).
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.
##
## **Absolute tile layout (Phase 12 W2-A, docs/80-* §4.8.9; 10-* §4.23).** The
## node tree IS the element tree: the centered 27×21-tile panel is a plain
## Panel at its authored rect, its sections are plain Controls and every leaf
## hangs directly off its registered parent — the CenterContainer →
## PanelContainer → Margin → VBox flow chain is deleted. The two supply rows
## are FIXED statics (the §4.10 kinds, both always present) with their parts
## absolutely-placed children of the row; the cargo jettison list is the
## screen's one dynamic list block (`stacks`, row_h 1, inside the cargo
## scroll viewport). Authored rects equal the data rows, so `apply_layout`
## is idempotent once managed.

const PaletteLib := preload("res://scripts/palette.gd")
## Phase-10 sweep (§4.9): the days-of-supply readout gains the kit's
## value_bar atom (tier via the doc-pinned §4.6.1 GOOD ≥ 10 / WARN 3–9
## thresholds) and the destructive actions adopt the kit button atom's
## Danger kind; panel chrome retires to the shared theme.
const UiKitLib := preload("res://scripts/ui_kit.gd")
## Phase-11 W3-B (docs/80-UI-UX.md §4.8.9): the modal's named controls
## register under the `provisions` screen id at build time; the shipped
## `ui_layout` table is `{}`, so the apply walk is a no-op. The shared
## confirm dialog is a §4.8.9 fast-follow — not registered here.
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")

const SCENE_PATH := "res://scenes/port/provisions_dialog.tscn"
const JETTISON_KEY := "port.sail.jettison"
const JETTISON_CONFIRM_KEY := "port.sail.jettison.confirm"
## 一键补满 / Auto-fill (§4.6.1 amended): button label, the disabled reason and
## the confirm-first messages for a plan that discards.
const FILL_KEY := "port.sail.fill"
const FILL_DONE_KEY := "port.sail.fill.done"
const FILL_PART_KEY := "port.sail.fill.part"
const FILL_CONFIRM_BOTH_KEY := "port.sail.fill.confirm_both"
const FILL_CONFIRM_DISCARD_KEY := "port.sail.fill.confirm_discard"
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"

## `[- 10 +]` stepper step (docs/80-* §4.6.1: "steps of 10").
const STEP := 10
## Days-of-supply tiers (docs/80-* §4.6.1: GOOD ≥ 10, WARN 3–9, BAD ≤ 2) —
## the readout's value_bar re-tiers through `UiKit.auto_tier` with them.
const DAYS_GOOD_MIN := 10
const DAYS_WARN_MIN := 3
## The readout bar saturates at the §4.6.1 GOOD boundary: at 10+ safe days
## the bar is full (no number beyond the locked formula is invented).
const DAYS_BAR_MAX := DAYS_GOOD_MIN
## `short_warning` shows below this many days (the WARN band and worse).
const SHORT_WARNING_BELOW := DAYS_GOOD_MIN

## Fixed column widths, on the §4.8 8px grid.
const COL_KIND_W := 160
const COL_STEP_W := 40
const COL_BUY_W := 200
const COL_JETTISON_W := 160

## --- The authored tile table (parent-relative 32-px tiles; Phase 12) ---------
## One tile = `Palette.CHROME_TILE`. The dialog root is the canvas; the
## centered panel carries its own rect and its children address the panel's
## space.
const TILE := PaletteLib.CHROME_TILE
## The centered 864×672 prompt panel (27 × 21 tiles).
const PANEL_RECT := Rect2i(16, 6, 27, 21)
## The cargo jettison list block (content-node tiles): row *i* at
## `(0, i·row_h)` — a 1-tile row inside the cargo scroll viewport (the
## scroll's rect in the cargo group's space).
const STACKS_LIST := "stacks"
const STACKS_W := 23
const STACKS_ROW_H := 1
## Cargo-stack row internals (row-local tiles): the stack caption and the
## jettison verb.
const STACK_LABEL_RECT := Rect2i(0, 0, 14, 1)
const STACK_JETTISON_RECT := Rect2i(14, 0, 5, 1)

## Emitted after a successful purchase or jettison (tests / hosts).
signal supplies_changed(kind: String, qty: int)
## Emitted right before the prompt asks the host to sail (the host owns the
## real S4 → S3 transition, `PortScreen.set_sail()`).
signal sail_requested
## Emitted when the prompt closes back to S4.
signal closed

## The node whose `set_sail()` performs the transition (set by [method attach_to]
## / [method open_on]). When null, an enabled Set Sail still closes the prompt
## and emits [signal sail_requested] — the host decides what that means.
var sail_host: Node = null

## Per supply kind: `{row, label, minus, qty, plus, buy}`, built once in
## `_ready` (the two §4.10 kinds, in `Fleet.SUPPLY_KINDS` order). `label` is the
## §4.5.1 `fleet.stat.supply` line; `qty` is the staged stepper quantity.
var _rows: Dictionary = {}
## Pending jettison: `{ship_index, kind, good_id, qty, name, ship}` (-1 = none).
## The auto-fill stages `{"kind": "fill", "plan": <fill_plan()>}` here instead,
## so the one shared confirm (§4.7) serves both destructive paths.
var _pending: Dictionary = {}

## The days readout's tier bar (built lazily in [_refresh_days], inserted
## right under the DaysRow — a suite/host seam, like [method fill_button]).
var _days_bar: ProgressBar = null

@onready var _dim: ColorRect = $Dim
@onready var _panel: Panel = $Panel
@onready var _title: Label = $Panel/Title
@onready var _header: Label = $Panel/Header
@onready var _table: Control = $Panel/Table
@onready var _crew: Label = $Panel/Table/Crew
@onready var _rows_box: Control = $Panel/Table/Rows
@onready var _hold: Label = $Panel/Table/Hold
@onready var _days_row: Control = $Panel/DaysRow
@onready var _days: Label = $Panel/DaysRow/Days
@onready var _short: Label = $Panel/DaysRow/Short
@onready var _fill_button: Button = $Panel/DaysRow/Fill
@onready var _hint: Label = $Panel/Hint
@onready var _cargo: Control = $Panel/Cargo
@onready var _scroll: ScrollContainer = $Panel/Cargo/Scroll
@onready var _cargo_box: Control = $Panel/Cargo/Scroll/Stacks
@onready var _footer: Control = $Panel/Footer
@onready var _sail_button: Button = $Panel/Footer/Sail
@onready var _gate_reason: Label = $Panel/Footer/GateReason
@onready var _stay_button: Button = $Panel/Footer/Stay
@onready var _confirm: Control = $ConfirmDialog


## Installs the prompt under `parent` (idempotent) and returns it, following the
## [FleetPanel]/[CharacterPanel] convention: a `Control` host gets it as a child;
## a non-`Control` host gets it inside a `CanvasLayer` so it neither inherits a
## camera transform nor collapses to a zero-size rect.
static func attach_to(parent: Node, host: Node = null) -> Control:
	var existing := _find_panel(parent)
	if existing != null:
		if host != null:
			existing.sail_host = host
		return existing
	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("ProvisionsDialog.attach_to: missing %s" % SCENE_PATH)
		return null
	var panel := scene.instantiate()
	panel.name = "ProvisionsDialog"
	if host != null:
		panel.sail_host = host
	if parent is Control:
		parent.add_child(panel)
	else:
		var layer := parent.get_node_or_null("ProvisionsLayer") as CanvasLayer
		if layer == null:
			layer = CanvasLayer.new()
			layer.name = "ProvisionsLayer"
			# Above the host screen's own canvas so the modal dims everything.
			layer.layer = 100
			parent.add_child(layer)
		layer.add_child(panel)
	return panel


static func _find_panel(parent: Node) -> Control:
	var direct := parent.get_node_or_null("ProvisionsDialog")
	if direct is Control:
		return direct
	var layer := parent.get_node_or_null("ProvisionsLayer")
	if layer != null:
		var nested := layer.get_node_or_null("ProvisionsDialog")
		if nested is Control:
			return nested
	return null


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.color = Color(0, 0, 0, DIM_ALPHA)
	# Phase-10 sweep: the panel renders the themed PanelContainer chrome;
	# secondary lines carry the `Dim` variation and the doc-pinned warning
	# tints the master-added `Warn`/`Bad` variations (§4.9).
	_header.theme_type_variation = "Dim"
	_hold.theme_type_variation = "Dim"
	_short.theme_type_variation = "Warn"
	_hint.theme_type_variation = "Bad"
	_gate_reason.theme_type_variation = "Bad"
	_sail_button.custom_minimum_size = Vector2(200, PaletteLib.BUTTON_H)
	_stay_button.custom_minimum_size = Vector2(200, PaletteLib.BUTTON_H)
	_fill_button.custom_minimum_size = Vector2(float(COL_BUY_W),
		float(PaletteLib.BUTTON_H))
	_sail_button.pressed.connect(_on_sail_pressed)
	_stay_button.pressed.connect(close)
	_fill_button.pressed.connect(_on_fill_pressed)
	_confirm.confirmed.connect(_on_jettison_confirmed)
	_confirm.cancelled.connect(_on_jettison_cancelled)
	# Phase 12 (§4.8.9): the authored tile rects — every static at its data
	# rect, the panel centered, before anything registers.
	_place_statics()
	# Phase-11 W3-B (docs/80-* §4.8.9): the scene-built surfaces register
	# first; the supply rows register where `_build_rows` builds them.
	_register_static_ids()
	_build_rows()

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.fleet_changed.connect(_on_fleet_changed)
	EventBus.gold_changed.connect(_on_gold_changed)

	# Phase-11 W3-B (docs/80-* §4.8.9): one activation after the full build —
	# captures the registration baselines and applies the committed override
	# table (the shipped file is `{}`, so this is a no-op walk).
	RegistryLib.screen_active("provisions", self)


## Phase 12 (§4.8.9): one authored rect = one `position`/`size` write, in
## the DIRECT parent's tile space (point anchors everywhere; nothing is
## stretched).
func _place(control: Control, rect: Rect2i) -> void:
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = Vector2(rect.position) * float(TILE)
	control.size = Vector2(rect.size) * float(TILE)


## The authored tile table — the centered prompt, flattened to the grid
## (`data/ui_layout.json
## `).
func _place_statics() -> void:
	_place(_panel, PANEL_RECT)
	_place(_title, Rect2i(1, 1, 25, 1))
	_place(_header, Rect2i(1, 2, 25, 1))
	_place(_table, Rect2i(1, 4, 23, 6))
	_place(_crew, Rect2i(0, 0, 23, 1))
	_place(_rows_box, Rect2i(0, 1, 23, 4))
	_place(_hold, Rect2i(0, 5, 23, 1))
	_place(_days_row, Rect2i(1, 11, 23, 2))
	_place(_days, Rect2i(0, 0, 10, 2))
	_place(_short, Rect2i(10, 0, 5, 2))
	_place(_fill_button, Rect2i(15, 0, 7, 2))
	_place(_hint, Rect2i(1, 14, 23, 1))
	_place(_cargo, Rect2i(1, 15, 23, 4))
	_place(_scroll, Rect2i(0, 0, 23, 4))
	_place(_footer, Rect2i(1, 19, 23, 2))
	_place(_gate_reason, Rect2i(0, 0, 10, 2))
	_place(_stay_button, Rect2i(11, 0, 6, 2))
	_place(_sail_button, Rect2i(17, 0, 6, 2))


## Phase-11 W3-B (docs/80-* §4.8.9): the scene-built controls under their
## stable hierarchical ids. Roles only tag what a `sheet` override may
## target (the styling itself stays in `ui_theme.gd`); kinds auto-derive
## (a centered modal has no edge-docked bars). The shared confirm dialog
## is a §4.8.9 fast-follow — not registered here.
func _register_static_ids() -> void:
	RegistryLib.register("provisions", _dim, "dim")
	RegistryLib.register("provisions", _panel, "panel", {"role": "panel"})
	RegistryLib.register("provisions", _title, "title")
	RegistryLib.register("provisions", _header, "header")
	RegistryLib.register("provisions", _table, "table")
	RegistryLib.register("provisions", _crew, "crew")
	RegistryLib.register("provisions", _rows_box, "rows")
	RegistryLib.register("provisions", _hold, "hold")
	RegistryLib.register("provisions", _days_row, "days_row")
	RegistryLib.register("provisions", _days, "days_row.days")
	RegistryLib.register("provisions", _short, "days_row.short")
	RegistryLib.register("provisions", _fill_button, "days_row.fill",
		{"role": "button"})
	RegistryLib.register("provisions", _hint, "hint")
	RegistryLib.register("provisions", _cargo, "cargo")
	RegistryLib.register("provisions", _scroll, "cargo.scroll")
	RegistryLib.register("provisions", _footer, "footer")
	RegistryLib.register("provisions", _gate_reason, "footer.gate_reason")
	RegistryLib.register("provisions", _stay_button, "footer.stay",
		{"role": "button"})
	RegistryLib.register("provisions", _sail_button, "footer.sail",
		{"role": "button"})


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if _confirm.is_open():
		# The confirm owns its own keys (§4.3 "dialogs: Enter/Y, N/Esc").
		return
	if event.is_action_pressed("back"):
		# §4.6.1 / §4.3: Esc closes the prompt back to S4 — it does **not** sail.
		get_viewport().set_input_as_handled()
		close()
		return
	# Modal behaviour (§6 "modals consume all input"): swallow the rest so the
	# host's keyboard/mouse handling cannot act underneath.
	get_viewport().set_input_as_handled()


# --- Public API ------------------------------------------------------------

## Opens the prompt (optionally re-binding the sailing host) and rebuilds it
## from live state. No-op with no run: the prompt has nothing to provision.
func open_on(host: Node = null) -> void:
	if host != null:
		sail_host = host
	open()


func open() -> void:
	if GameState.player.is_empty() and GameState.fleet.is_empty():
		# No run in progress (editor / title screen): a provisioning prompt for a
		# fleet that does not exist would be worse than a no-op.
		return
	visible = true
	add_to_group(MODAL_GROUP)
	# A freshly opened prompt stages nothing: the stepper always starts at 0, so
	# a quantity left over from a previous visit can never be bought by accident.
	_reset_staged()
	rebuild()
	_stay_button.grab_focus()


## Clears every supply row's staged stepper quantity.
func _reset_staged() -> void:
	for kind in _rows:
		(_rows[kind]["qty"] as Label).set_meta("qty", 0)


## Closes back to S4 without sailing (§4.6.1 "Stay in port", `Esc`).
func close() -> void:
	visible = false
	remove_from_group(MODAL_GROUP)
	_pending = {}
	# A pending jettison confirm dies with the prompt: never leave a modal
	# hovering over a hidden owner (§6).
	if _confirm != null and _confirm.is_open():
		_confirm.cancel()
	closed.emit()


func is_open() -> bool:
	return visible


## True while the prompt or its jettison confirm is on screen.
func has_modal() -> bool:
	return visible or _confirm.is_open()


## `days = min(floor(provisions / need), floor(water / need))` for the **pooled**
## fleet (§4.10, locked) — delegated so the panel and this prompt can never
## disagree.
func days_of_supply() -> int:
	return SailingSimLib.fleet_supply_days()


## The gate key for the current state (`""` = may sail; §4.11.2, locked).
func gate_reason_key() -> String:
	return SailingSimLib.supply_block_reason()


## The localised gate reason, or `""` when the gate is open.
func gate_reason_text() -> String:
	var key := gate_reason_key()
	return "" if key.is_empty() else I18n.t_key(key)


## Widget bundle of one supply row (`{}` when unknown).
func supply_row(kind: String) -> Dictionary:
	return _rows.get(kind, {})


## The Buy button of `kind` (null when unknown).
func buy_button(kind: String) -> Button:
	return _rows.get(kind, {}).get("buy", null)


## The `抛弃` button of `kind` (null when unknown).
func jettison_supply_button(kind: String) -> Button:
	return _rows.get(kind, {}).get("jettison", null)


## The `[-]` / `[+]` stepper buttons of `kind`.
func minus_button(kind: String) -> Button:
	return _rows.get(kind, {}).get("minus", null)


func plus_button(kind: String) -> Button:
	return _rows.get(kind, {}).get("plus", null)


## The 一键补满 button (§4.6.1 amended; tests / hosts).
func fill_button() -> Button:
	return _fill_button


## Quantity currently staged in `kind`'s stepper (0 when unknown).
func pending_qty(kind: String) -> int:
	var refs: Dictionary = _rows.get(kind, {})
	if refs.is_empty():
		return 0
	var field: Label = refs["qty"]
	return int(field.get_meta("qty", 0))


## Steps one supply row's staged quantity by `STEP` (clamped to what is
## physically possible: the free hold, and never below 1 unit).
func step(kind: String, direction: int) -> void:
	var refs: Dictionary = _rows.get(kind, {})
	if refs.is_empty():
		return
	# The ceiling covers BOTH staged actions: a buy needs free hold, a
	# discard needs carried stock (§4.6.1 amended) — so a discard can be
	# staged even with a full hold.
	var ceiling := maxi(FleetLib.fleet_free(), FleetLib.supplies(kind))
	var next := pending_qty(kind) + STEP * signi(direction)
	if direction < 0:
		next = maxi(0, next)
	else:
		next = mini(next, ceiling)
	(refs["qty"] as Label).set_meta("qty", next)
	_refresh_row(kind)


## Buys the staged quantity of `kind` through [TradeEngine.buy_supplies] (the
## only supplies price path). Returns whether the purchase went through.
func buy(kind: String) -> bool:
	var refs: Dictionary = _rows.get(kind, {})
	if refs.is_empty():
		return false
	var button: Button = refs["buy"]
	if button.disabled:
		return false
	var qty := pending_qty(kind)
	if qty <= 0:
		return false
	if not TradeEngineLib.buy_supplies(_port_id(), kind, qty):
		return false
	(refs["qty"] as Label).set_meta("qty", 0)
	# Never leave a stale staged quantity behind for the next kind either.
	supplies_changed.emit(kind, qty)
	rebuild()
	return true


# --- Auto-fill (§4.6.1 amended) ---------------------------------------------

## The largest common target `T` with `provisions = water = T` reachable from
## the four pooled inputs, by buying the shortfalls at the locked §4.10 prices
## (provisions 2g / water 1g, no tax) and discarding the surplus above `T`
## where the plan requires it. Pure integer maths — unit-testable without a
## run, and the only place the plan exists (execution goes through the same
## engine paths as the rows).
##
## Caps, over the pooled state `P, W, free, gold`:
##   * hold: `buy_p + buy_w ≤ free + discarded`, which collapses to
##     `T ≤ ⌊(free + P + W) / 2⌋` in every buy/discard mix;
##   * purse: `2·buy_p + 1·buy_w ≤ gold` — the cost is piecewise linear in
##     `T` with breakpoints at `min(P, W)` (cost 0) and `max(P, W)` (cost
##     `smaller_kind_price × (max − min)`), slope `2 + 1` beyond.
## `T = min(hold cap, gold cap)`; `T ≥ min(P, W)` always, so at most one kind
## is ever discarded (the larger one, and only when a cap sits below its
## stack). Returns `{target, buy_provisions, buy_water, discard_provisions,
## discard_water, cost}` — an all-zero plan means nothing to do.
static func fill_plan(provisions: int, water: int, free: int, gold: int) -> Dictionary:
	var smaller := mini(provisions, water)
	var larger := maxi(provisions, water)
	# The kind a below-`larger` target must buy is the currently smaller one.
	var small_price := SailingSimLib.WATER_PRICE if provisions >= water \
		else SailingSimLib.PROVISIONS_PRICE
	var cost_at_larger := small_price * (larger - smaller)
	var gold_cap := 0
	if gold >= cost_at_larger:
		@warning_ignore("integer_division")
		gold_cap = larger + (gold - cost_at_larger) \
			/ (SailingSimLib.PROVISIONS_PRICE + SailingSimLib.WATER_PRICE)
	else:
		@warning_ignore("integer_division")
		gold_cap = smaller + gold / small_price
	@warning_ignore("integer_division")
	var space_cap := (free + provisions + water) / 2
	var target := mini(gold_cap, space_cap)
	var plan := {
		"target": target,
		"buy_provisions": maxi(0, target - provisions),
		"buy_water": maxi(0, target - water),
		"discard_provisions": maxi(0, provisions - target),
		"discard_water": maxi(0, water - target),
	}
	plan["cost"] = SailingSimLib.PROVISIONS_PRICE * int(plan["buy_provisions"]) \
		+ SailingSimLib.WATER_PRICE * int(plan["buy_water"])
	return plan


## True when a plan buys and discards nothing (the button is a no-op).
static func _plan_is_empty(plan: Dictionary) -> bool:
	return int(plan.get("buy_provisions", 0)) \
		+ int(plan.get("buy_water", 0)) \
		+ int(plan.get("discard_provisions", 0)) \
		+ int(plan.get("discard_water", 0)) <= 0


## [method fill_plan] over the live pooled fleet, hold and purse.
func current_fill_plan() -> Dictionary:
	return fill_plan(
		FleetLib.supplies("provisions"), FleetLib.supplies("water"),
		FleetLib.fleet_free(), GameState.gold
	)


## Executes a plan as one unit: discards first (freeing hold — the only way a
## space-starved plan fits), then the buys through [TradeEngine.buy_supplies],
## the only supplies price path. Emits `supplies_changed` per touched kind,
## clears the staged steppers (the world they referenced is gone) and rebuilds.
func apply_fill_plan(plan: Dictionary) -> bool:
	if _plan_is_empty(plan):
		return false
	for kind in TradeEngineLib.SUPPLY_KINDS:
		var removed := FleetLib.remove_supplies(
			kind, int(plan["discard_%s" % kind])
		)
		if removed > 0:
			FleetLib.notify_changed()
			supplies_changed.emit(kind, -removed)
	for kind in TradeEngineLib.SUPPLY_KINDS:
		var qty := int(plan["buy_%s" % kind])
		# Unreachable while the modal blocks interleaving state changes (the
		# plan was exact); reported as failed rather than half-claimed.
		if qty > 0 and not TradeEngineLib.buy_supplies(_port_id(), kind, qty):
			return false
		if qty > 0:
			supplies_changed.emit(kind, qty)
	_reset_staged()
	rebuild()
	return true


## The localised `Provisions × 75, Water × 20` fragment of a confirm message
## for one plan half (`"buy"` / `"discard"`); `""` when that half is empty.
func _fill_parts(plan: Dictionary, prefix: String) -> String:
	var parts: Array[String] = []
	for kind in TradeEngineLib.SUPPLY_KINDS:
		var qty := int(plan["%s_%s" % [prefix, kind]])
		if qty > 0:
			parts.append(I18n.fmt(FILL_PART_KEY, {
				"kind": _kind_name(kind), "qty": qty,
			}))
	return ", ".join(parts)


## 一键补满 pressed (§4.6.1 amended): a buy-only plan executes immediately —
## the row Buy buttons confirm nothing either; a plan that discards is
## destructive and confirms first (§4.7), naming the discard and buy parts.
func _on_fill_pressed() -> void:
	var plan := current_fill_plan()
	if _plan_is_empty(plan):
		return
	var discards := _fill_parts(plan, "discard")
	if discards.is_empty():
		apply_fill_plan(plan)
		return
	var buys := _fill_parts(plan, "buy")
	_pending = {"kind": "fill", "plan": plan}
	_confirm.open_key(
		FILL_CONFIRM_BOTH_KEY if not buys.is_empty()
		else FILL_CONFIRM_DISCARD_KEY,
		{
			"discard": discards, "buy": buys,
			"target": int(plan["target"]), "gold": int(plan["cost"]),
		}
	)


## The fill button state: enabled exactly when a plan exists — the plan's caps
## already guarantee it is affordable and fits the hold — and disabled with a
## stated reason when the amounts are equal and no cap allows raising them.
func _refresh_fill() -> void:
	var blocked := _port_id().is_empty() \
		or _plan_is_empty(current_fill_plan())
	_fill_button.disabled = blocked
	_fill_button.tooltip_text = I18n.t_key(FILL_DONE_KEY) if blocked else ""


## Discard supplies (§4.6.1 amended): the staged quantity of `kind` leaves
## the pooled stock through `Fleet.remove_supplies` — the single
## supplies-removal path — confirm-first over the shared `_confirm`.


## The supply discard action: stages the request through the shared confirm
## (the same dialog the cargo jettison uses). Returns the confirm dialog so
## tests can drive `accept()` directly, or null when nothing is staged.
func open_jettison_confirm(kind: String) -> Control:
	var staged := pending_qty(kind)
	if staged <= 0 or FleetLib.supplies(kind) <= 0:
		return null
	_pending = {"kind": kind, "qty": staged}
	_confirm.open_key(JETTISON_CONFIRM_KEY, {
		"kind": _kind_name(kind), "qty": staged,
	})
	return _confirm


func _on_supply_jettison_pressed(kind: String) -> void:
	open_jettison_confirm(kind)


## Jettison buttons rendered in the prompt, in display order: one per trade-good
## stack (`{ship_index, kind, good_id, qty, button}`), so a full hold can be
## cleared without leaving the dialog (§4.6.1).
func jettison_buttons() -> Array:
	var out: Array = []
	for child in _cargo_box.get_children():
		if child.has_meta("jettison_entry"):
			out.append(child.get_meta("jettison_entry"))
	return out


## The Jettison button of one stack (null when not rendered).
func jettison_button(ship_index: int, good_id: String) -> Button:
	for entry in jettison_buttons():
		if int(entry["ship_index"]) == ship_index \
				and str(entry["good_id"]) == good_id:
			return entry["button"]
	return null


## Rebuilds the whole prompt from live state: header, both supply rows, the
## jettison list, the days readout and the gate. Called on open and after any
## change this prompt caused.
func rebuild() -> void:
	_bind_static()
	_refresh_all()
	# Phase-11 W3-B (docs/80-* §4.8.9): the days bar and the cargo jettison
	# rows are this dialog's rebuild paths — their new nodes re-registered
	# where they build; re-apply the committed table.
	RegistryLib.apply_layout("provisions")


# --- Construction ----------------------------------------------------------

func _build_rows() -> void:
	for child in _rows_box.get_children():
		_rows_box.remove_child(child)
		child.queue_free()
	_rows.clear()
	_crew.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# The §4.10 kinds' authored row slots inside the rows group (fixed
	# statics — both kinds always render).
	var kind_index := 0
	for kind in TradeEngineLib.SUPPLY_KINDS:
		_rows[kind] = _build_row(kind, kind_index)
		kind_index += 1


## One supply row: `Provisions 45 (15 days) | [- 10 +] | [Buy 10 (20g)]` — the
## kind/amount/days cell is exactly the §4.5.1 `fleet.stat.supply` line, so the
## prompt and the fleet panel word the same number the same way. The row is a
## plain Control at its authored slot in the rows group and every widget is an
## absolutely-placed child of the row (no per-row flow containers); every
## widget is filled by [_refresh_row].
func _build_row(kind: String, index: int) -> Dictionary:
	var row := Control.new()
	row.name = "Supply_%s" % kind
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows_box.add_child(row)
	_place(row, Rect2i(0, index * 2, 23, 2))
	RegistryLib.register("provisions", row, "rows.%s" % kind)

	var label := _label("")
	label.name = "Stat"
	row.add_child(label)
	_place(label, Rect2i(0, 0, 6, 2))

	var minus := _step_button("Minus", "-")
	minus.pressed.connect(step.bind(kind, -1))
	row.add_child(minus)
	_place(minus, Rect2i(6, 0, 2, 1))

	var qty := _label("")
	qty.name = "Qty"
	qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qty.set_meta("qty", 0)
	row.add_child(qty)
	_place(qty, Rect2i(8, 0, 2, 1))

	var plus := _step_button("Plus", "+")
	plus.pressed.connect(step.bind(kind, 1))
	row.add_child(plus)
	_place(plus, Rect2i(10, 0, 2, 1))

	var buy := Button.new()
	buy.name = "Buy_%s" % kind
	buy.custom_minimum_size = Vector2(float(COL_BUY_W), float(PaletteLib.BUTTON_H))
	buy.pressed.connect(_on_buy_pressed.bind(kind))
	row.add_child(buy)
	_place(buy, Rect2i(12, 0, 7, 2))

	var jettison := UiKitLib.button(JETTISON_KEY, "danger")
	jettison.name = "Jettison_%s" % kind
	jettison.custom_minimum_size = Vector2(float(COL_STEP_W) * 2,
		float(PaletteLib.BUTTON_H))
	jettison.pressed.connect(_on_supply_jettison_pressed.bind(kind))
	row.add_child(jettison)
	_place(jettison, Rect2i(19, 0, 3, 2))

	# Phase 12 (§4.8.9): the row's named parts under the kind-derived id
	# (the stepper `qty` is a Label, not a field — the staged number lives
	# in a meta, so it is `plain`).
	RegistryLib.register("provisions", label, "rows.%s.label" % kind)
	RegistryLib.register("provisions", minus, "rows.%s.minus" % kind,
		{"role": "button"})
	RegistryLib.register("provisions", qty, "rows.%s.qty" % kind)
	RegistryLib.register("provisions", plus, "rows.%s.plus" % kind,
		{"role": "button"})
	RegistryLib.register("provisions", buy, "rows.%s.buy" % kind,
		{"role": "button"})
	RegistryLib.register("provisions", jettison, "rows.%s.jettison" % kind,
		{"role": "button"})
	return {
		"node": row, "label": label, "minus": minus, "qty": qty,
		"plus": plus, "buy": buy, "jettison": jettison,
	}


func _step_button(node_name: String, text: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(float(COL_STEP_W), float(PaletteLib.ROW_H))
	return button


# --- Binding ---------------------------------------------------------------

func _port_id() -> String:
	var value = GameState.current_port
	if value is String and not (value as String).is_empty():
		return value
	return ""


## Port / day / gold header and the fixed button labels (locale-dependent only).
func _bind_static() -> void:
	_title.text = I18n.t_key("port.sail.prepare")
	var port: Dictionary = DataLoader.get_port(_port_id())
	var port_name := I18n.t(port.get("name", {})) if not port.is_empty() else "-"
	_header.text = "%s · %s · %s" % [
		port_name,
		I18n.fmt("world.day_time", {
			"day": GameState.day, "time": SailingSimLib.clock_text(),
		}),
		I18n.fmt("ui.gold_amount", {"gold": format_thousands(GameState.gold)}),
	]
	for kind in _rows:
		(_rows[kind]["label"] as Label).text = _kind_name(kind)
	_sail_button.text = I18n.t_key("port.set_sail")
	_stay_button.text = I18n.t_key("port.sail.stay")
	_fill_button.text = I18n.t_key(FILL_KEY)
	_hint.text = I18n.t_key("port.sail.jettison_hint")


## Re-reads every live number. Split from [_bind_static] so a gold/fleet signal
## only touches the figures, not the port header.
func _refresh_all() -> void:
	_crew.text = I18n.fmt("fleet.stat.crew", {
		"crew": FleetLib.total_crew(),
		"max": _fleet_crew_max(),
	})
	_hold.text = I18n.fmt("fleet.stat.cargo", {
		"used": TradeEngineLib.hold_used(),
		"capacity": TradeEngineLib.hold_capacity(),
		"free": FleetLib.fleet_free(),
	})
	for kind in _rows:
		_refresh_row(kind)
	_refresh_days()
	_refresh_cargo()
	_refresh_gate()
	_refresh_fill()
	# §4.6.1: the prompt *says* the hold is full rather than silently dropping
	# cargo — so the jettison hint appears exactly when it applies.
	_hint.visible = FleetLib.fleet_free() <= 0


## One supply row: the §4.5.1 `fleet.stat.supply` line (kind, amount and this
## kind's **own** days-of-supply, computed by the same §4.10 formula on the
## pooled stack), and the Buy state.
##
## The Buy button is disabled with a stated reason: full hold
## (`market.hold_full`, plus the prompt's own jettison path — never a silent
## cargo drop) or short gold (`market.no_gold`).
func _refresh_row(kind: String) -> void:
	var refs: Dictionary = _rows[kind]
	var amount := FleetLib.supplies(kind)
	var days := SailingSimLib.kind_supply_days(kind)
	(refs["label"] as Label).text = I18n.fmt("fleet.stat.supply", {
		"kind": _kind_name(kind), "amount": amount, "days": days,
	})

	var qty := pending_qty(kind)
	(refs["qty"] as Label).text = str(qty) if qty > 0 else "-"
	var price := TradeEngineLib.supplies_price(kind)
	var buy: Button = refs["buy"]
	var reason := _buy_block_reason(kind, qty)
	buy.text = I18n.fmt("port.sail.buy", {"qty": qty, "gold": price * qty})
	buy.disabled = not reason.is_empty()
	buy.tooltip_text = reason
	var stock := FleetLib.supplies(kind)
	var jettison: Button = refs["jettison"]
	jettison.text = I18n.t_key(JETTISON_KEY)
	jettison.disabled = qty <= 0 or stock <= 0
	jettison.tooltip_text = "" if not jettison.disabled else (
		I18n.t_key("market.invalid_qty") if qty <= 0
		else I18n.t_key("port.sail.days_zero"))
	(refs["minus"] as Button).disabled = qty <= 0
	(refs["plus"] as Button).disabled = qty >= maxi(FleetLib.fleet_free(),
		stock)


## Why a supply purchase is refused, as localised text (`""` = allowed). Order
## follows §4.6.1: a full hold first (the prompt's own jettison path is the way
## out), then the staged quantity, then the purse.
func _buy_block_reason(kind: String, qty: int) -> String:
	if _port_id().is_empty():
		return I18n.t_key("market.invalid_qty")
	if FleetLib.fleet_free() <= 0:
		return I18n.t_key("market.hold_full")
	if qty <= 0:
		return I18n.t_key("market.invalid_qty")
	var cost := TradeEngineLib.supplies_price(kind) * qty
	if GameState.gold < cost:
		return I18n.t_key("market.no_gold")
	if qty > FleetLib.fleet_free():
		return I18n.t_key("market.hold_full")
	return ""


## The locked §4.10 readout, shown large with its tier bar
## (GOOD ≥ 10 / WARN 3–9 / BAD ≤ 2, `80-*` §4.8 — the bar re-tiers through
## `UiKit.auto_tier` and saturates at the §4.6.1 GOOD boundary).
func _refresh_days() -> void:
	var days := days_of_supply()
	if days <= 0:
		_days.text = I18n.t_key("port.sail.days_zero")
	else:
		_days.text = I18n.fmt("port.sail.days", {"days": days})
	_refresh_days_bar(days)
	_short.visible = days > 0 and days < SHORT_WARNING_BELOW
	if _short.visible:
		_short.text = I18n.fmt("port.sail.short_warning", {"days": days})


## The kit atom bakes the tier into its fill at build time, so a changed
## readout rebuilds the bar (the same discipline the inn's morale bar uses).
## The bar is a registered static (`days_bar`) at its authored slot under
## the days row — the rebuild re-places it there.
func _refresh_days_bar(days: int) -> void:
	if _days_bar != null and is_instance_valid(_days_bar):
		_panel.remove_child(_days_bar)
		_days_bar.queue_free()
	var tier := UiKitLib.auto_tier(days, DAYS_GOOD_MIN, DAYS_WARN_MIN)
	_days_bar = UiKitLib.value_bar(mini(days, DAYS_BAR_MAX), DAYS_BAR_MAX, tier)
	_panel.add_child(_days_bar)
	_place(_days_bar, Rect2i(1, 13, 23, 1))
	# Phase-11 W3-B (docs/80-* §4.8.9): the atom bakes the tier at build time,
	# so every refresh rebuilds the bar — re-register (replaces the record).
	RegistryLib.register("provisions", _days_bar, "days_bar")


## The readout's tier bar (tests / hosts).
func days_bar() -> ProgressBar:
	return _days_bar


## The gate (§4.11.2, locked): the Set Sail button carries the reason inline so
## the player never has to hover to learn why they cannot leave.
func _refresh_gate() -> void:
	var reason := gate_reason_text()
	_sail_button.disabled = not reason.is_empty()
	_sail_button.tooltip_text = reason
	_gate_reason.visible = not reason.is_empty()
	_gate_reason.text = reason


## One Jettison row per trade-good stack (provisions/water are bought, not
## dropped, from this prompt — §4.6.1 offers jettison "per trade-good stack").
## The rows are the cargo list block's members (`stacks`): row *i* takes its
## `list_rect` position inside the scroll's plain content node.
func _refresh_cargo() -> void:
	for child in _cargo_box.get_children():
		_cargo_box.remove_child(child)
		child.queue_free()
	var any := false
	var index := 0
	var fleet: Array = GameState.fleet if GameState.fleet is Array else []
	for ship in fleet:
		if not (ship is Dictionary):
			continue
		var cargo = (ship as Dictionary).get("cargo", {})
		if not (cargo is Dictionary):
			continue
		var good_ids: Array = (cargo as Dictionary).keys()
		good_ids.sort_custom(func(a, b) -> bool: return str(a) < str(b))
		for good_id in good_ids:
			var qty := int((cargo as Dictionary).get(good_id, 0))
			if qty <= 0:
				continue
			any = true
			_build_cargo_row(index, ship_index_of(fleet, ship),
				str(good_id), qty)
			index += 1
	_cargo_box.visible = any
	# The scroll's stacked extent: the plain content Control sized to the
	# rows' total pitch (viewport math, not flow).
	_cargo_box.custom_minimum_size = Vector2(
		STACKS_W * float(TILE), index * STACKS_ROW_H * float(TILE))


## The fleet index of `ship` (the jettison path's second key).
func ship_index_of(fleet: Array, ship: Dictionary) -> int:
	return fleet.find(ship)


## Row *i*'s rect for the cargo list block — px in the content node's space:
## the data block when managed, the same tiles authored otherwise.
func _stack_row_rect(index: int) -> Rect2:
	var rect := RegistryLib.list_rect("provisions", STACKS_LIST, index)
	if rect != Rect2():
		return rect
	return Rect2(
		Vector2(0, index * STACKS_ROW_H) * float(TILE),
		Vector2(STACKS_W, STACKS_ROW_H) * float(TILE))


func _build_cargo_row(row_index: int, ship_index: int, good_id: String,
		qty: int) -> void:
	var row := Control.new()
	row.name = "Cargo_%s_%d" % [good_id, ship_index]
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cargo_box.add_child(row)
	var rect := _stack_row_rect(row_index)
	row.position = rect.position
	row.size = rect.size
	var good: Dictionary = DataLoader.get_good(good_id)
	var good_name := I18n.t(good.get("name", {})) if not good.is_empty() else good_id
	var label := _label(I18n.fmt("fleet.stack", {"name": good_name, "qty": qty}))
	label.name = "Stack"
	row.add_child(label)
	_place(label, STACK_LABEL_RECT)
	var button := UiKitLib.button("fleet.jettison", "danger")
	button.name = "Jettison_%s_%d" % [good_id, ship_index]
	button.custom_minimum_size = Vector2(float(COL_JETTISON_W), float(PaletteLib.ROW_H))
	var reason := "" if FleetLib.at_port() else I18n.t_key("fleet.port_only")
	button.disabled = not reason.is_empty()
	button.tooltip_text = reason if not reason.is_empty() else label.text
	button.pressed.connect(_on_jettison_pressed.bind(ship_index, good_id, qty))
	row.add_child(button)
	_place(button, STACK_JETTISON_RECT)
	row.set_meta("jettison_entry", {
		"ship_index": ship_index, "kind": "cargo", "good_id": good_id,
		"qty": qty, "button": button,
	})
	# Phase 12 (§4.8.9): the jettison list is data-derived (fleet order, then
	# sorted good ids) — locked like the market rows. The row is a list
	# member; its parts are unregistered (locked viewport blocks in the
	# studio).
	RegistryLib.register("provisions", row,
		"stacks.%s.%d" % [good_id, ship_index],
		{"data_ordered": true, "list": STACKS_LIST})


# --- Actions ---------------------------------------------------------------

func _on_buy_pressed(kind: String) -> void:
	buy(kind)


func _on_sail_pressed() -> void:
	# The gate is the button's `disabled` state; this is the second line of
	# defence (a programmatic `pressed.emit()` must not leak past it either).
	if not gate_reason_key().is_empty():
		return
	sail_requested.emit()
	visible = false
	remove_from_group(MODAL_GROUP)
	if sail_host != null and sail_host.has_method("set_sail"):
		# The existing S4 → S3 path — never a reimplementation.
		sail_host.set_sail()
	else:
		close()


func _on_jettison_pressed(ship_index: int, good_id: String, qty: int) -> void:
	if qty <= 0 or not FleetLib.at_port():
		return
	var ship = GameState.fleet[ship_index] if ship_index < GameState.fleet.size() else {}
	var good: Dictionary = DataLoader.get_good(good_id)
	var name := I18n.t(good.get("name", {})) if not good.is_empty() else good_id
	_pending = {
		"ship_index": ship_index, "kind": "cargo", "good_id": good_id,
		"qty": qty, "name": name,
	}
	# Destructive: always confirm (§4.7 "one action per dialog"), with the same
	# shared dialog and message key S15 uses — no duplicated confirm logic.
	_confirm.open_key("fleet.jettison.confirm", {
		"ship": _ship_title(ship_index),
		"good": name,
		"qty": qty,
	})


func _on_jettison_confirmed() -> void:
	var pending := _pending
	_pending = {}
	if pending.is_empty():
		return
	# Auto-fill (§4.6.1 amended): the staged plan executes as one unit —
	# discards first (freeing hold), then the buys through the one supplies
	# price path.
	if str(pending.get("kind", "")) == "fill":
		apply_fill_plan(pending.get("plan", {}))
		return
	# Supply discard (§4.6.1 amended): the staged quantity leaves the pooled
	# stock flagship-first, freeing hold immediately, refunding nothing.
	if str(pending.get("kind", "")) in FleetLib.SUPPLY_KINDS:
		var kind := str(pending["kind"])
		var removed := FleetLib.remove_supplies(kind, int(pending["qty"]))
		if removed > 0:
			FleetLib.notify_changed()
			supplies_changed.emit(kind, -removed)
			var refs: Dictionary = _rows.get(kind, {})
			if not refs.is_empty():
				(refs["qty"] as Label).set_meta("qty", 0)
			rebuild()
		return
	var removed := FleetLib.jettison_good(
		int(pending["ship_index"]), str(pending["good_id"])
	)
	if removed > 0:
		supplies_changed.emit("cargo", removed)
		rebuild()


func _on_jettison_cancelled() -> void:
	_pending = {}


func _ship_title(index: int) -> String:
	var title := I18n.fmt("fleet.ship_n", {"amount": index + 1})
	var ship = GameState.fleet[index] if index < GameState.fleet.size() else null
	if ship is Dictionary:
		var ship_type: Dictionary = DataLoader.get_ship_type(
			str((ship as Dictionary).get("ship_type_id", ""))
		)
		if not ship_type.is_empty():
			title += " · " + I18n.t(ship_type.get("name", {}))
	return title


# --- Signals ---------------------------------------------------------------

func _on_locale_changed(_locale: String) -> void:
	if visible:
		rebuild()


func _on_fleet_changed() -> void:
	if visible:
		rebuild()


func _on_gold_changed(_value: int) -> void:
	if visible:
		rebuild()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.fleet_changed.is_connected(_on_fleet_changed):
		EventBus.fleet_changed.disconnect(_on_fleet_changed)
	if EventBus.gold_changed.is_connected(_on_gold_changed):
		EventBus.gold_changed.disconnect(_on_gold_changed)


# --- Helpers ---------------------------------------------------------------

## Localised noun for a supply kind. `world.provisions` / `world.water` are the
## only noun keys that exist ("Provisions {amount}"), so the noun is read from
## them with an empty amount rather than introducing a second wording.
static func _kind_name(kind: String) -> String:
	return I18n.fmt("world.%s" % kind, {"amount": ""}).strip_edges()


func _fleet_crew_max() -> int:
	var total := 0
	for ship in GameState.fleet:
		if ship is Dictionary:
			total += FleetLib.ship_stat(ship, "crew_max")
	return total


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


## `1,234` — grouping for gold amounts (the L10nString supplies the unit).
static func format_thousands(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for index in range(digits.length() - 1, -1, -1):
		out = digits[index] + out
		count += 1
		if count % 3 == 0 and index > 0:
			out = "," + out
	return ("-" if value < 0 else "") + out
