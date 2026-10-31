class_name FleetPanel
extends Control
## Fleet / cargo panel — docs/40-SHIPS-AND-FLEET.md §4.4 (flagship + promotion),
## §6 (capacity guard), §7; docs/20-WORLD-AND-SAILING.md §4.10 (provisions and
## water are cargo; jettison is per stack and frees capacity immediately);
## docs/80-UI-UX.md §4.7 (confirm dialogs) and §4.8 (palette, 32px rows).
##
## **Every rule lives in [Fleet]**: this scene only renders `GameState.fleet`
## and delegates — no cargo maths, cap or invariant is duplicated here. That is
## what makes `tools/test_fleet.gd` meaningful proof for the panel too.
##
## Parent-agnostic modal, same contract as [CharacterPanel]: a host calls
## [method attach_to] in its `_ready` and can then [method open] it. While open
## it joins the `modal_overlay` group and consumes input (§6 "modals consume
## all input"), so the host's movement/keys cannot act underneath it.
##
## Port vs sea: promotion and jettison are port actions (§4.4), so at sea the
## whole panel is **read-only** — every action button is disabled and states its
## `ui.reason` tooltip. The panel still renders the fleet, which is the point
## of showing it at sea.
##
## All text goes through `ui_strings.json` and is re-bound on
## `EventBus.locale_changed` (§6); rows also re-bind on `fleet_changed`.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
## Days of supply + effective speed (docs/20-* §4.4, §4.10). The panel renders
## the sim's numbers; it never recomputes either formula.
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")

const SCENE_PATH := "res://scenes/ui_shared/fleet_panel.tscn"
const DIM_ALPHA := 0.4
## Group every open modal joins (docs/90-* §11).
const MODAL_GROUP := "modal_overlay"

## Durability bar geometry (docs/80-* §4.8: 8px base unit).
const BAR_W := 120.0
const BAR_H := 8.0
## Bar colour thresholds, the §4.8 GOOD/WARN/BAD placeholders (same as S6).
const BAR_GOOD_ABOVE := 0.6
const BAR_WARN_ABOVE := 0.25

## Keys requested for the next `ui_strings.json` merge (the panel must never
## print a raw "<key>", so each has a composed fallback below).
const COUNT_KEY := "fleet.count"
const STACK_KEY := "fleet.stack"
const PORT_ONLY_KEY := "fleet.port_only"
const READ_ONLY_KEY := "fleet.read_only"
const JETTISON_CONFIRM_KEY := "fleet.jettison.confirm"

## Emitted after a promote/jettison actually changed the fleet.
signal fleet_mutated

## One widget dict per fleet row, in fleet order. Keys: `index`, `promote`,
## `jettison` (Array of {kind, good_id, button}).
var _rows: Array = []
## Pending jettison: `{ship_index, kind, good_id, qty, name}` (-1 = none).
var _pending: Dictionary = {}
## Guards rebuild re-entry from `fleet_changed`.
var _rebuilding := false

@onready var _dim: ColorRect = $Dim
@onready var _panel: PanelContainer = $Center/Panel
@onready var _title: Label = $Center/Panel/Margin/Body/Title
@onready var _summary: Label = $Center/Panel/Margin/Body/Summary
@onready var _mode_note: Label = $Center/Panel/Margin/Body/ModeNote
@onready var _rows_box: VBoxContainer = \
	$Center/Panel/Margin/Body/Scroll/Rows
@onready var _totals: VBoxContainer = $Center/Panel/Margin/Body/Totals
@onready var _ships_header: Label = $Center/Panel/Margin/Body/ShipsHeader
@onready var _close_button: Button = $Center/Panel/Margin/Body/Footer/Close
@onready var _hint: Label = $Center/Panel/Margin/Body/Footer/Hint
@onready var _confirm: Control = $ConfirmDialog


## Installs a panel under `parent` (idempotent) and returns it, following the
## [CharacterPanel] convention: a `Control` host gets it as a child; a
## `Node2D` host (the world map) gets it inside a `CanvasLayer` so it neither
## inherits the camera transform nor collapses to a zero-size rect.
static func attach_to(parent: Node) -> Control:
	var existing := _find_panel(parent)
	if existing != null:
		return existing
	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		push_error("FleetPanel.attach_to: missing %s" % SCENE_PATH)
		return null
	var panel := scene.instantiate()
	panel.name = "FleetPanel"
	if parent is Control:
		parent.add_child(panel)
	else:
		var layer := parent.get_node_or_null("FleetPanelLayer") as CanvasLayer
		if layer == null:
			layer = CanvasLayer.new()
			layer.name = "FleetPanelLayer"
			# Above the host screen's own canvas so the modal dims everything.
			layer.layer = 100
			parent.add_child(layer)
		layer.add_child(panel)
	return panel


static func _find_panel(parent: Node) -> Control:
	var direct := parent.get_node_or_null("FleetPanel")
	if direct is Control:
		return direct
	var layer := parent.get_node_or_null("FleetPanelLayer")
	if layer != null:
		var nested := layer.get_node_or_null("FleetPanel")
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
	_summary.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_mode_note.add_theme_color_override("font_color", PaletteLib.WARN)
	_ships_header.add_theme_color_override("font_color", PaletteLib.ACCENT)
	_hint.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_close_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_close_button.pressed.connect(close)
	_confirm.confirmed.connect(_on_jettison_confirmed)
	_confirm.cancelled.connect(_on_jettison_cancelled)

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.fleet_changed.connect(_on_fleet_changed)
	EventBus.gold_changed.connect(_on_gold_changed)


func _unhandled_input(event: InputEvent) -> void:
	# `F` toggles the panel, same pattern as the character panel's `C` (the key
	# is the T18 addition to docs/80 §4.3 — see the task report).
	if event.is_action_pressed("toggle_fleet") and not _confirm.is_open():
		# A HUD dialog or another modal owns the screen first (§6 "modals
		# consume all input"): never stack this panel on top of one.
		if not visible and _other_modal_open():
			return
		get_viewport().set_input_as_handled()
		toggle()
		return
	if not visible:
		return
	if event.is_action_pressed("back") and not _confirm.is_open():
		get_viewport().set_input_as_handled()
		close()
		return
	# Modal behaviour (docs/80-* §6): swallow everything else so the host's
	# keyboard/mouse handling cannot act underneath the panel.
	get_viewport().set_input_as_handled()


## True while any *other* modal is up (a HUD dialog, the confirm, S14…).
func _other_modal_open() -> bool:
	for node in get_tree().get_nodes_in_group(MODAL_GROUP):
		if node == self or not (node is CanvasItem):
			continue
		if (node as CanvasItem).is_visible_in_tree():
			return true
	# S14 (and any panel with the same contract) is a Control modal that does
	# not join `modal_overlay`; hosts look it up by name, so do the same.
	var parent := get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling == self or not (sibling is CanvasItem):
				continue
			if sibling.has_method("is_open") and sibling.is_open():
				return true
	return false


# --- Public API ------------------------------------------------------------

func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	visible = true
	add_to_group(MODAL_GROUP)
	rebuild()
	_close_button.grab_focus()


func close() -> void:
	visible = false
	remove_from_group(MODAL_GROUP)
	_pending = {}
	# A pending jettison confirm dies with the panel: never leave a modal
	# hovering over a hidden owner (§6 "modals consume all input").
	if _confirm != null and _confirm.is_open():
		_confirm.cancel()


func is_open() -> bool:
	return visible


## True while the jettison confirmation or the panel itself is on screen.
func has_modal() -> bool:
	return visible or _confirm.is_open()


## True when the panel is only displaying (at sea): neither promotion nor
## jettison is a sea action (docs/40 §4.4, §6).
func is_read_only() -> bool:
	return not FleetLib.at_port()


## Widget dict of `fleet[index]` (`{}` when out of range).
func row_widget(index: int) -> Dictionary:
	if index < 0 or index >= _rows.size():
		return {}
	return _rows[index]


## Promote button of `fleet[index]` (null on the flagship / out of range).
func promote_button(index: int) -> Button:
	return row_widget(index).get("promote", null)


## Jettison buttons of `fleet[index]` in render order (`{kind, good_id, button}`).
func jettison_buttons(index: int) -> Array:
	return row_widget(index).get("jettison", [])


## The Jettison button of one stack (`kind` = "cargo" | "provisions" | "water";
## `good_id` only for cargo). Null when the row/stack is not rendered.
func jettison_button(index: int, kind: String, good_id: String = "") -> Button:
	for entry in jettison_buttons(index):
		if str(entry["kind"]) != kind:
			continue
		if kind == "cargo" and str(entry["good_id"]) != good_id:
			continue
		return entry["button"]
	return null


## Rebuilds header + rows from `GameState`. Deferred by the action handlers so
## a button is never freed inside its own signal.
func rebuild() -> void:
	if not is_inside_tree() or _rebuilding:
		return
	_rebuilding = true
	_bind_header()
	_ships_header.text = I18n.t_key("fleet.ship_header")
	_bind_rows()
	_rebuilding = false


# --- Header ----------------------------------------------------------------

func _bind_header() -> void:
	_title.text = I18n.t_key("fleet.title")
	var count := "%d/%d" % [GameState.fleet.size(), FleetLib.FLEET_MAX]
	var count_text := _fmt_or(
		COUNT_KEY, {"count": GameState.fleet.size(), "max": FleetLib.FLEET_MAX}, count
	)
	_summary.text = "%s · %s" % [
		count_text,
		I18n.fmt("fleet.free_capacity", {"capacity": FleetLib.fleet_free()}),
	]
	# §6: "Buying a 6th ship → `fleet.full`" — the same cap warning reads here.
	if GameState.fleet.size() >= FleetLib.FLEET_MAX:
		_summary.text += " · " + I18n.fmt(
			"fleet.full", {"max": FleetLib.FLEET_MAX}
		)
	# §4.5.1 header: "plus the same day / gold / morale line the HUD shows so the
	# panel is self-contained" — composed from the HUD's own three keys.
	_summary.text += " · " + _hud_line()
	_mode_note.visible = is_read_only()
	_mode_note.text = _read_only_note()
	_hint.text = I18n.t_key("ui.esc_hint")
	_close_button.text = I18n.t_key("ui.close")


## The day / gold / morale figures the HUD top bar shows (`80-*` §4.5), built
## from the same three `ui_strings` keys so the panel can never disagree.
func _hud_line() -> String:
	return " · ".join([
		I18n.fmt("world.day", {"day": GameState.day}),
		I18n.fmt("ui.gold_amount", {"gold": GameState.gold}),
		I18n.fmt("world.morale", {"amount": GameState.morale}),
	])


## At-sea banner. `fleet.read_only` is requested for the next `ui_strings.json`
## merge; until it lands the line is composed from existing keys so it can
## never print a raw "<key>" (§6).
func _read_only_note() -> String:
	if DataLoader.ui_strings.has(READ_ONLY_KEY):
		return I18n.t_key(READ_ONLY_KEY)
	if DataLoader.ui_strings.has(PORT_ONLY_KEY):
		return I18n.t_key(PORT_ONLY_KEY)
	return "%s · %s" % [
		I18n.t_key("world.open_sea"),
		I18n.fmt("ui.reason", {"reason": I18n.t_key("ui.not_available")}),
	]


# --- Rows ------------------------------------------------------------------

func _bind_rows() -> void:
	_clear(_rows_box)
	_rows.clear()
	var fleet: Array = GameState.fleet if GameState.fleet is Array else []
	for index in fleet.size():
		_add_row(index, fleet[index])
	_bind_totals()


## The §4.5.1 **fleet totals row**: pooled provisions, water and their combined
## days (the lesser of the two, by the same §4.10 formula the prompt uses), plus
## the fleet's effective speed (slowest hull × wind × crew, `20-*` §4.4).
##
## This is the authoritative days number: the per-ship lines above show each
## hull's own stack, while this row pools the fleet the way consumption does
## (`40-*` §4.2 flagship-first pooling) — and it is the fleet-level figure the
## provisioning prompt (`80-*` §4.6.1) shows before you sail.
func _bind_totals() -> void:
	_clear(_totals)
	var title := _label(I18n.t_key("fleet.totals"), PaletteLib.ACCENT)
	title.name = "Title"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title_row := HBoxContainer.new()
	title_row.name = "TitleRow"
	title_row.custom_minimum_size.y = float(PaletteLib.ROW_H)
	title_row.add_theme_constant_override("separation", 12)
	title_row.add_child(title)
	var speed := _label(I18n.fmt("world.speed", {
		"speed": SailingSimLib.effective_speed(),
	}), PaletteLib.PANEL_LINE)
	speed.name = "Speed"
	speed.custom_minimum_size.x = 180
	title_row.add_child(speed)
	_totals.add_child(title_row)

	var supplies_row := HBoxContainer.new()
	supplies_row.name = "Supplies"
	supplies_row.custom_minimum_size.y = float(PaletteLib.ROW_H)
	supplies_row.add_theme_constant_override("separation", 12)
	var crew := FleetLib.total_crew()
	var days := SailingSimLib.fleet_supply_days()
	for kind in FleetLib.SUPPLY_KINDS:
		var amount := FleetLib.supplies(kind)
		var label := _label(I18n.fmt("fleet.stat.supply", {
			"kind": I18n.fmt("world.%s" % kind, {"amount": ""}).strip_edges(),
			"amount": amount,
			"days": SailingSimLib.supply_days(amount, amount, crew),
		}), PaletteLib.TEXT)
		label.name = "Total_%s" % kind
		supplies_row.add_child(label)
	var total_days := _label(I18n.fmt("fleet.total_days", {"days": days}),
		_days_color(days))
	total_days.name = "TotalDays"
	total_days.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	total_days.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	supplies_row.add_child(total_days)
	_totals.add_child(supplies_row)


## The §4.8 GOOD/WARN/BAD tier for a days-of-supply figure — the same thresholds
## the provisioning prompt colours its readout with (`80-*` §4.6.1).
static func _days_color(days: int) -> Color:
	if days >= 10:
		return PaletteLib.GOOD
	if days >= 3:
		return PaletteLib.WARN
	return PaletteLib.BAD


func _add_row(index: int, ship) -> void:
	var widgets: Dictionary = {"index": index, "promote": null, "jettison": []}
	var box := VBoxContainer.new()
	box.name = "Ship_%d" % index
	box.add_theme_constant_override("separation", 2)

	var data: Dictionary = ship if ship is Dictionary else {}

	# --- line 1: identity, flagship tag, Promote -------------------------
	var top := HBoxContainer.new()
	top.name = "Top"
	top.custom_minimum_size.y = float(PaletteLib.ROW_H)
	top.add_theme_constant_override("separation", 12)
	var name_label := _label(_ship_title(index, data), PaletteLib.TEXT)
	name_label.name = "Name"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(name_label)

	# Promote: non-flagship rows only (§4.4); disabled with a reason at sea.
	if index > 0:
		var promote := _row_button(I18n.t_key("fleet.promote"))
		promote.name = "Promote_%d" % index
		var reason := FleetLib.promote_block_reason(index)
		promote.disabled = not reason.is_empty()
		promote.tooltip_text = _reason_text(reason) if not reason.is_empty() \
			else promote.text
		promote.pressed.connect(_on_promote_pressed.bind(index))
		top.add_child(promote)
		widgets["promote"] = promote
	box.add_child(top)

	# --- lines 1–3 of the §4.5.1 stat block ------------------------------
	# `Stats` stays the block's node name (the pre-existing test hook), now a
	# VBox of three named 32px lines: `DurabilityLine`, `CrewLine`, `SpeedLine`.
	var stats := VBoxContainer.new()
	stats.name = "Stats"
	stats.add_theme_constant_override("separation", 0)
	var durability_line := HBoxContainer.new()
	durability_line.name = "DurabilityLine"
	durability_line.custom_minimum_size.y = float(PaletteLib.ROW_H)
	durability_line.add_theme_constant_override("separation", 12)
	var max_durability := FleetLib.ship_stat(data, "durability")
	var durability := int(data.get("durability", 0))
	var ratio := float(durability) / float(max_durability) if max_durability > 0 else 0.0
	durability_line.add_child(_durability_bar(ratio))
	var durability_label := _label(
		I18n.fmt("fleet.stat.durability", {
			"current": durability, "max": max_durability,
		}),
		PaletteLib.TEXT
	)
	durability_label.name = "Durability"
	durability_label.custom_minimum_size.x = 190
	durability_line.add_child(durability_label)
	var capacity := FleetLib.ship_stat(data, "capacity")
	var used := FleetLib.used_capacity(data)
	var free := FleetLib.free_capacity(data)
	var cargo_label := _label(
		I18n.fmt("fleet.stat.cargo", {
			"used": used, "capacity": capacity, "free": free,
		}),
		PaletteLib.PANEL_LINE
	)
	cargo_label.name = "Cargo"
	cargo_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cargo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	durability_line.add_child(cargo_label)
	# The pre-existing `Free` label (a test hook from T18) keeps its name and
	# meaning: the same `free` figure the cargo cell carries.
	var free_label := _label(
		I18n.fmt("fleet.free_capacity", {"capacity": free}),
		PaletteLib.PANEL_LINE
	)
	free_label.name = "Free"
	free_label.visible = false
	durability_line.add_child(free_label)
	stats.add_child(durability_line)

	# --- line 3: crew + guns (§4.5.1 line 2) -----------------------------
	var crew_line := HBoxContainer.new()
	crew_line.name = "CrewLine"
	crew_line.custom_minimum_size.y = float(PaletteLib.ROW_H)
	crew_line.add_theme_constant_override("separation", 12)
	var crew := _label(
		I18n.fmt("fleet.stat.crew", {
			"crew": int(data.get("crew", 0)),
			"max": FleetLib.ship_stat(data, "crew_max"),
		}),
		PaletteLib.TEXT
	)
	crew.name = "Crew"
	crew.custom_minimum_size.x = 190
	crew_line.add_child(crew)
	var guns := _label(
		I18n.fmt("fleet.stat.guns", {
			"cannons": int(data.get("cannons", 0)),
			"slots": FleetLib.ship_stat(data, "armament_slots"),
		}),
		PaletteLib.PANEL_LINE
	)
	guns.name = "Guns"
	guns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	crew_line.add_child(guns)
	stats.add_child(crew_line)

	# --- line 4: current speed vs hull max, with the wind (§4.5.1 line 3) -
	var speed_line := HBoxContainer.new()
	speed_line.name = "SpeedLine"
	speed_line.custom_minimum_size.y = float(PaletteLib.ROW_H)
	var speed := _label(
		I18n.fmt("fleet.stat.speed", {
			"speed": _row_speed(index),
			"max": FleetLib.ship_stat(data, "speed"),
			"wind": _wind_name(),
		}),
		PaletteLib.TEXT
	)
	speed.name = "Speed"
	speed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed_line.add_child(speed)
	stats.add_child(speed_line)
	box.add_child(stats)

	# --- line 5: supplies, each with its **own** days (§4.5.1 line 4) ----
	var supplies_row := HBoxContainer.new()
	supplies_row.name = "Supplies"
	supplies_row.custom_minimum_size.y = float(PaletteLib.ROW_H)
	supplies_row.add_theme_constant_override("separation", 12)
	for kind in FleetLib.SUPPLY_KINDS:
		_add_stack(supplies_row, widgets, index, kind, str(kind), "", int(data.get(kind, 0)))
	box.add_child(supplies_row)

	# --- then one row per trade-good stack, each with its own Jettison ---
	var cargo: Dictionary = data.get("cargo", {}) \
		if data.get("cargo", {}) is Dictionary else {}
	var good_ids: Array = cargo.keys()
	good_ids.sort_custom(func(a, b) -> bool: return str(a) < str(b))
	if good_ids.is_empty():
		var empty := _label(I18n.t_key("fleet.cargo_empty"), PaletteLib.PANEL_LINE)
		empty.name = "CargoEmpty"
		var cargo_row := HBoxContainer.new()
		cargo_row.name = "Cargo"
		cargo_row.custom_minimum_size.y = float(PaletteLib.ROW_H)
		cargo_row.add_child(empty)
		box.add_child(cargo_row)
	else:
		for good_id in good_ids:
			var qty := int(cargo.get(good_id, 0))
			if qty <= 0:
				continue
			var cargo_row := HBoxContainer.new()
			cargo_row.name = "Cargo_%s" % str(good_id)
			cargo_row.custom_minimum_size.y = float(PaletteLib.ROW_H)
			cargo_row.add_theme_constant_override("separation", 12)
			var good: Dictionary = DataLoader.get_good(str(good_id))
			var good_name := I18n.t(good.get("name", {})) if not good.is_empty() \
				else str(good_id)
			_add_stack(cargo_row, widgets, index, "cargo", str(good_id), good_name, qty)
			box.add_child(cargo_row)

	# §4.8: 32px table row; the row group itself is at least that tall.
	box.custom_minimum_size.y = float(PaletteLib.ROW_H)
	_rows_box.add_child(box)
	_rows.append(widgets)


## The speed this row shows (docs/80-* §4.5.1 line 3):
##   * the **flagship** (fleet[0]) shows the fleet's **current effective** speed,
##     `SailingSim.effective_speed()` — slowest hull × wind × crew × seamanship
##     (`20-*` §4.4), which is the number the HUD bottom bar shows;
##   * every other hull shows its own base `ShipType.speed`, because the fleet
##     moves at the slowest hull and a per-ship "effective" figure would have to
##     invent a crew/wind split the sim does not have.
func _row_speed(index: int) -> int:
	if index == 0:
		return SailingSimLib.effective_speed()
	return FleetLib.ship_stat(_row_ship(index), "speed")


## The crew whose rations come out of `fleet[ship_index]`'s stack (§4.10).
##
## Phase 1 keeps every crew member on the flagship (`40-*` §4.4), and consumption
## is **pooled** and drained flagship-first (`40-*` §4.2) — a stack stowed on an
## escort still feeds the fleet. So a hull with crew aboard feeds that crew, and
## a crewless hull feeds the fleet's crew; either way the number is the §4.10
## formula's, never a per-ship invention. The pooled fleet figure in the totals
## row (and the header) is the authoritative one; this is the per-ship view.
func _crew_sharing(ship_index: int) -> int:
	var own := int(_row_ship(ship_index).get("crew", 0))
	return own if own > 0 else FleetLib.total_crew()


## `GameState.fleet[index]` as a dictionary (`{}` out of range / non-dict).
func _row_ship(index: int) -> Dictionary:
	var fleet: Array = GameState.fleet if GameState.fleet is Array else []
	if index < 0 or index >= fleet.size():
		return {}
	var ship = fleet[index]
	if not (ship is Dictionary):
		return {}
	return ship


## The localised weather name that produced the speed (`world.weather.*`), for
## the `(wind: {wind})` cell of §4.5.1. `fair` is the sim's default before the
## first weather roll, so a freshly loaded run names a real factor.
static func _wind_name() -> String:
	return I18n.t_key("world.weather.%s" % str(
		GameState.world.get("weather", SailingSimLib.DEFAULT_WEATHER)
	))


## One "name qty [Jettison]" stack row. `kind` is "cargo", "provisions" or
## "water"; `good_id` is the trade good id for cargo, else ""; `qty` is the
## stack size already read by the caller.
func _add_stack(parent: HBoxContainer, widgets: Dictionary, ship_index: int,
		kind: String, good_id: String, good_name: String, qty: int) -> void:
	var text := ""
	if kind == "cargo":
		# `fleet.stack` is requested for the next `ui_strings.json` merge; until
		# then the neutral "name × qty" form is used (a symbol + two data
		# values, no untranslated prose).
		text = _fmt_or(STACK_KEY, {"name": good_name, "qty": qty},
			"%s × %d" % [good_name, qty])
	else:
		# `fleet.stat.supply` = "{kind} {amount} ({days} days)": the §4.5.1 line,
		# with **this ship's** days from the locked §4.10 formula on its own
		# stack and the crew that eats from it.
		var ship := _row_ship(ship_index)
		var stack := int(ship.get(kind, 0))
		text = I18n.fmt("fleet.stat.supply", {
			"kind": I18n.fmt("world.%s" % kind, {"amount": ""}).strip_edges(),
			"amount": stack,
			"days": SailingSimLib.supply_days(
				stack, stack, _crew_sharing(ship_index)
			),
		})
	var label := _label(text, PaletteLib.TEXT)
	label.name = "Stack_%s" % (good_id if kind == "cargo" else kind)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(label)

	var button := _row_button(I18n.t_key("fleet.jettison"))
	button.name = "Jettison_%s_%d" % [good_id if kind == "cargo" else kind, ship_index]
	var reason := _jettison_block_reason()
	button.disabled = not reason.is_empty() or qty <= 0
	if not reason.is_empty():
		button.tooltip_text = reason
	elif qty <= 0:
		button.tooltip_text = I18n.t_key("fleet.cargo_empty")
	else:
		button.tooltip_text = text
	button.pressed.connect(_on_jettison_pressed.bind(ship_index, kind, good_id, qty))
	parent.add_child(button)
	widgets["jettison"].append({
		"kind": kind, "good_id": good_id, "button": button, "qty": qty,
	})


## §4.4/§6: jettison is a port action — at sea every stack button is inert and
## its tooltip is the localised read-only explanation (no new key needed).
## Returns the tooltip text, or "" when jettison is allowed.
func _jettison_block_reason() -> String:
	return "" if FleetLib.at_port() else _read_only_note()


func _ship_title(index: int, ship: Dictionary) -> String:
	var ship_type: Dictionary = DataLoader.get_ship_type(
		str(ship.get("ship_type_id", ""))
	)
	var title := I18n.fmt("fleet.ship_n", {"amount": index + 1})
	if not ship_type.is_empty():
		title += " · " + I18n.t(ship_type.get("name", {}))
	if index == 0:
		title += " [%s]" % I18n.t_key("fleet.flagship")
	return title


# --- Actions ---------------------------------------------------------------

func _on_promote_pressed(index: int) -> void:
	# Free and port-only; the order of every other hull is preserved (§4.4).
	if FleetLib.promote(index):
		fleet_mutated.emit()
		_rebuild_deferred()


func _on_jettison_pressed(ship_index: int, kind: String, good_id: String,
		qty: int) -> void:
	if qty <= 0 or not FleetLib.at_port():
		return
	var ship = GameState.fleet[ship_index] if ship_index < GameState.fleet.size() else {}
	var data: Dictionary = ship if ship is Dictionary else {}
	var name := ""
	if kind == "cargo":
		var good: Dictionary = DataLoader.get_good(good_id)
		name = I18n.t(good.get("name", {})) if not good.is_empty() else good_id
	else:
		name = I18n.t_key("world.%s" % kind)
	_pending = {
		"ship_index": ship_index, "kind": kind, "good_id": good_id,
		"qty": qty, "name": name, "ship": _ship_title(ship_index, data),
	}
	# Destructive: always confirm (§4.7 "one action per dialog").
	if DataLoader.ui_strings.has(JETTISON_CONFIRM_KEY):
		_confirm.open_key(JETTISON_CONFIRM_KEY, {
			"ship": _pending["ship"], "good": name, "qty": qty,
		})
	else:
		_confirm.open_text("%s — %s × %d" % [
			I18n.t_key("fleet.jettison"), name, qty,
		])


func _on_jettison_confirmed() -> void:
	var pending := _pending
	_pending = {}
	if pending.is_empty():
		return
	var ship_index := int(pending["ship_index"])
	var kind := str(pending["kind"])
	var good_id := str(pending["good_id"])
	var removed := 0
	if kind == "cargo":
		removed = FleetLib.jettison_good(ship_index, good_id)
	else:
		removed = FleetLib.jettison_supplies(ship_index, kind)
	if removed > 0:
		fleet_mutated.emit()
		_rebuild_deferred()


func _on_jettison_cancelled() -> void:
	_pending = {}


func _rebuild_deferred() -> void:
	call_deferred("rebuild")


# --- Binding helpers -------------------------------------------------------

func _on_locale_changed(_locale: String) -> void:
	if visible:
		rebuild()


func _on_fleet_changed() -> void:
	if visible:
		_rebuild_deferred()


func _on_gold_changed(_value: int) -> void:
	# Gold does not affect this panel, but a load (gold + fleet + port) may:
	# refresh so the read-only state follows `current_port` (§4.6).
	if visible:
		_rebuild_deferred()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.fleet_changed.is_connected(_on_fleet_changed):
		EventBus.fleet_changed.disconnect(_on_fleet_changed)
	if EventBus.gold_changed.is_connected(_on_gold_changed):
		EventBus.gold_changed.disconnect(_on_gold_changed)


# --- Rendering helpers -----------------------------------------------------

## `key` when `ui_strings.json` has it, else `fallback` (a localised or numeric
## string) — the panel must never print a raw "<key>" (§6).
func _fmt_or(key: String, values: Dictionary, fallback: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.fmt(key, values)
	return fallback


## Localised disabled-reason text, prefixed by the shared `ui.reason` label.
## A key awaiting the next `ui_strings.json` merge (`fleet.port_only`) falls
## back to `ui.not_available`, so a tooltip never prints a raw "<key>" (§6).
func _reason_text(key: String) -> String:
	if key.is_empty():
		return ""
	if not DataLoader.ui_strings.has(key):
		key = "ui.not_available"
	return I18n.fmt("ui.reason", {"reason": I18n.t_key(key)})


func _label(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _row_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = float(PaletteLib.ROW_H)
	return button


## Durability bar placeholder (§4.8: ColorRect only, no textures).
func _durability_bar(ratio: float) -> Control:
	var bar := Control.new()
	bar.name = "DurabilityBar"
	bar.custom_minimum_size = Vector2(BAR_W, BAR_H)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var background := ColorRect.new()
	background.name = "BarBg"
	background.color = PaletteLib.PANEL_LINE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(background)

	var fill := ColorRect.new()
	fill.name = "BarFill"
	fill.color = _bar_color(ratio)
	fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fill.anchor_right = clampf(ratio, 0.0, 1.0)
	fill.offset_right = 0.0
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(fill)
	return bar


func _bar_color(ratio: float) -> Color:
	if ratio > BAR_GOOD_ABOVE:
		return PaletteLib.GOOD
	if ratio > BAR_WARN_ABOVE:
		return PaletteLib.WARN
	return PaletteLib.BAD


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style


## Removes and frees every child immediately so a rebuild never shows a mix of
## old and new rows for a frame.
func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
