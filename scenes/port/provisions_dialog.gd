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
## Sailing does **not** reimplement the transition: the enabled button calls the
## host's `set_sail()` ([member sail_host]), so there is one S4 → S3 code path.
##
## Parent-agnostic modal, same contract as [CharacterPanel]/[FleetPanel]: a host
## calls [method attach_to] in its `_ready` and then [method open]s it. While
## open it joins `modal_overlay` and consumes input (`80-*` §6).
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")

const SCENE_PATH := "res://scenes/port/provisions_dialog.tscn"
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"

## `[- 10 +]` stepper step (docs/80-* §4.6.1: "steps of 10").
const STEP := 10
## Days-of-supply tiers (docs/80-* §4.6.1: GOOD ≥ 10, WARN 3–9, BAD ≤ 2).
const DAYS_GOOD_MIN := 10
const DAYS_WARN_MIN := 3
## `short_warning` shows below this many days (the WARN band and worse).
const SHORT_WARNING_BELOW := DAYS_GOOD_MIN

## Fixed column widths, on the §4.8 8px grid.
const COL_KIND_W := 160
const COL_STEP_W := 40
const COL_BUY_W := 200
const COL_JETTISON_W := 160

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
var _pending: Dictionary = {}

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _header: Label = $Center/Panel/Margin/Body/Header
@onready var _crew: Label = $Center/Panel/Margin/Body/Table/Crew
@onready var _rows_box: VBoxContainer = $Center/Panel/Margin/Body/Table/Rows
@onready var _hold: Label = $Center/Panel/Margin/Body/Table/Hold
@onready var _days: Label = $Center/Panel/Margin/Body/DaysRow/Days
@onready var _short: Label = $Center/Panel/Margin/Body/DaysRow/Short
@onready var _hint: Label = $Center/Panel/Margin/Body/Hint
@onready var _cargo_box: VBoxContainer = \
	$Center/Panel/Margin/Body/Cargo/Scroll/Stacks
@onready var _sail_button: Button = $Center/Panel/Margin/Body/Footer/Sail
@onready var _gate_reason: Label = $Center/Panel/Margin/Body/Footer/GateReason
@onready var _stay_button: Button = $Center/Panel/Margin/Body/Footer/Stay
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
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_title.add_theme_font_size_override("font_size", 32)
	_header.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_crew.add_theme_color_override("font_color", PaletteLib.TEXT)
	_hold.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_short.add_theme_color_override("font_color", PaletteLib.WARN)
	_hint.add_theme_color_override("font_color", PaletteLib.BAD)
	_gate_reason.add_theme_color_override("font_color", PaletteLib.BAD)
	_sail_button.custom_minimum_size = Vector2(200, PaletteLib.BUTTON_H)
	_stay_button.custom_minimum_size = Vector2(200, PaletteLib.BUTTON_H)
	_sail_button.pressed.connect(_on_sail_pressed)
	_stay_button.pressed.connect(close)
	_confirm.confirmed.connect(_on_jettison_confirmed)
	_confirm.cancelled.connect(_on_jettison_cancelled)
	_build_rows()

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.fleet_changed.connect(_on_fleet_changed)
	EventBus.gold_changed.connect(_on_gold_changed)


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


## The `[-]` / `[+]` stepper buttons of `kind`.
func minus_button(kind: String) -> Button:
	return _rows.get(kind, {}).get("minus", null)


func plus_button(kind: String) -> Button:
	return _rows.get(kind, {}).get("plus", null)


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
	var ceiling := maxi(FleetLib.fleet_free(), 1)
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


# --- Construction ----------------------------------------------------------

func _build_rows() -> void:
	for child in _rows_box.get_children():
		_rows_box.remove_child(child)
		child.queue_free()
	_rows.clear()
	_crew.name = "Crew"
	_crew.custom_minimum_size = Vector2(0, float(PaletteLib.ROW_H))
	_crew.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	for kind in TradeEngineLib.SUPPLY_KINDS:
		_rows[kind] = _build_row(kind)


## One supply row: `Provisions 45 (15 days) | [- 10 +] | [Buy 10 (20g)]` — the
## kind/amount/days cell is exactly the §4.5.1 `fleet.stat.supply` line, so the
## prompt and the fleet panel word the same number the same way. Every widget is
## filled by [_refresh_row].
func _build_row(kind: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.name = "Supply_%s" % kind
	row.custom_minimum_size = Vector2(0, float(PaletteLib.ROW_H))
	row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)

	var label := _label("", PaletteLib.TEXT)
	label.name = "Stat"
	label.custom_minimum_size.x = float(COL_KIND_W)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	var minus := _step_button("Minus", "-")
	minus.pressed.connect(step.bind(kind, -1))
	row.add_child(minus)

	var qty := _label("", PaletteLib.ACCENT)
	qty.name = "Qty"
	qty.custom_minimum_size = Vector2(float(COL_STEP_W), float(PaletteLib.ROW_H))
	qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qty.set_meta("qty", 0)
	row.add_child(qty)

	var plus := _step_button("Plus", "+")
	plus.pressed.connect(step.bind(kind, 1))
	row.add_child(plus)

	var buy := Button.new()
	buy.name = "Buy_%s" % kind
	buy.custom_minimum_size = Vector2(float(COL_BUY_W), float(PaletteLib.BUTTON_H))
	buy.pressed.connect(_on_buy_pressed.bind(kind))
	row.add_child(buy)

	_rows_box.add_child(row)
	return {
		"node": row, "label": label, "minus": minus, "qty": qty,
		"plus": plus, "buy": buy,
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
		I18n.fmt("world.day", {"day": GameState.day}),
		I18n.fmt("ui.gold_amount", {"gold": format_thousands(GameState.gold)}),
	]
	for kind in _rows:
		(_rows[kind]["label"] as Label).text = _kind_name(kind)
	_sail_button.text = I18n.t_key("port.set_sail")
	_stay_button.text = I18n.t_key("port.sail.stay")
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
	var need := SailingSimLib.daily_need(FleetLib.total_crew())
	var days := 0 if need <= 0 else int(floor(float(amount) / float(need)))
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
	(refs["minus"] as Button).disabled = qty <= 0
	(refs["plus"] as Button).disabled = FleetLib.fleet_free() <= 0 \
		or qty >= FleetLib.fleet_free()


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


## The locked §4.10 readout, shown large and tier-coloured
## (GOOD ≥ 10 / WARN 3–9 / BAD ≤ 2, `80-*` §4.8).
func _refresh_days() -> void:
	var days := days_of_supply()
	if days <= 0:
		_days.text = I18n.t_key("port.sail.days_zero")
	else:
		_days.text = I18n.fmt("port.sail.days", {"days": days})
	_days.add_theme_color_override("font_color", _days_color(days))
	_short.visible = days > 0 and days < SHORT_WARNING_BELOW
	if _short.visible:
		_short.text = I18n.fmt("port.sail.short_warning", {"days": days})


static func _days_color(days: int) -> Color:
	if days >= DAYS_GOOD_MIN:
		return PaletteLib.GOOD
	if days >= DAYS_WARN_MIN:
		return PaletteLib.WARN
	return PaletteLib.BAD


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
func _refresh_cargo() -> void:
	for child in _cargo_box.get_children():
		_cargo_box.remove_child(child)
		child.queue_free()
	var any := false
	var fleet: Array = GameState.fleet if GameState.fleet is Array else []
	for index in fleet.size():
		var ship = fleet[index]
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
			_cargo_box.add_child(_build_cargo_row(index, str(good_id), qty))
	_cargo_box.visible = any


func _build_cargo_row(ship_index: int, good_id: String, qty: int) -> Control:
	var row := HBoxContainer.new()
	row.name = "Cargo_%s_%d" % [good_id, ship_index]
	row.custom_minimum_size = Vector2(0, float(PaletteLib.ROW_H))
	row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	var good: Dictionary = DataLoader.get_good(good_id)
	var good_name := I18n.t(good.get("name", {})) if not good.is_empty() else good_id
	var label := _label(I18n.fmt("fleet.stack", {"name": good_name, "qty": qty}),
		PaletteLib.TEXT)
	label.name = "Stack"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var button := Button.new()
	button.name = "Jettison_%s_%d" % [good_id, ship_index]
	button.text = I18n.t_key("fleet.jettison")
	button.custom_minimum_size = Vector2(float(COL_JETTISON_W), float(PaletteLib.ROW_H))
	var reason := "" if FleetLib.at_port() else I18n.t_key("fleet.port_only")
	button.disabled = not reason.is_empty()
	button.tooltip_text = reason if not reason.is_empty() else label.text
	button.pressed.connect(_on_jettison_pressed.bind(ship_index, good_id, qty))
	row.add_child(button)
	row.set_meta("jettison_entry", {
		"ship_index": ship_index, "kind": "cargo", "good_id": good_id,
		"qty": qty, "button": button,
	})
	return row


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


func _label(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style


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
