extends Control
## Shipyard (S6) — buy / repair / sell ships, Phase-2 armament refit and the
## equipment rows (docs/40-SHIPS-AND-FLEET.md §4.3–§4.4, §6; docs/30-* §4.7
## shipyard place in the flow; docs/80-UI-UX.md §4.7 dialogs, §4.7.2 refit +
## equipment rows, §4.8 palette/sizes; docs/90-* §7 routing).
##
## **Every rule lives in [ShipyardEngine]** — this screen only renders and
## delegates: no price, cap or eligibility formula is duplicated here. That is
## what makes the engine's headless tests (`tools/test_shipyard.gd` and
## `tools/test_equipment.gd`) meaningful proof for the UI as well.
##
## Layout (1280×720):
##   * header — title (`shipyard.title`), live gold, Esc hint, `Back`;
##   * left — the catalog: all 8 ShipTypes (docs/40 §4.3 "sold everywhere"),
##     each with price + a one-line stats string and a Buy button whose
##     disabled reason is the tooltip (`80-*` §4.7 "disabled with
##     tooltip-reason");
##   * right — the player's two equipment slots (`weapon`/`armor`, `60-*`
##     §4.11.12), then own fleet, one panel per hull: type, durability bar,
##     crew, repair picker (1 / 10 / Max + numeric, live cost preview), the
##     Phase-2 cannons picker (§4.7.2), the ship's two equipment rows
##     (`figurehead`/`sail`), Promote and Sell (with the
##     `shipyard.sell.confirm` modal);
##   * shared HUD (§4.5: S4–S8 keep the same bars, minimap hidden in port).
##
## Equipment rows show the worn item or `ui.empty`, one buy button per
## `data/equipment.json` item of that slot (price + disabled-reason tooltip)
## and an Unequip button when something is worn (`80-*` §4.7.2).
##
## Esc / Back return to the port hub (S6 → S4, `30-*` §4.7). All text is
## re-bound on `EventBus.locale_changed` (§6), and the lists re-bind on
## `gold_changed` / `fleet_changed` so a transaction repaints immediately.

const PaletteLib := preload("res://scripts/palette.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"

## Repair picker steps (`30-*` §4.4's 1 / 10 / 100-style buttons; repair points
## are small — a hull takes at most 240 — so the doc's 100 becomes "Max").
const PICKER_STEPS: Array[int] = [1, 10]
## The "Max" picker button. `shipyard.max` is requested for the next
## `ui_strings.json` merge; until it lands the shared quantity word is used, so
## the screen never prints a "<key>".
const MAX_KEY := "shipyard.max"
const MAX_FALLBACK_KEY := "market.max"
## Catalog cannons column: `shipyard.cannons_stat` is requested for the next
## merge; until then the row shows the localised "Refit" noun plus the number
## (a data label + a digit, never hardcoded prose).
const CANNONS_KEY := "shipyard.cannons_stat"
const CANNONS_FALLBACK_KEY := "shipyard.refit"
## Phase-2 refit row (§4.7.2): `shipyard.cannons` is the row's label,
## `shipyard.cannons_sellback` / `shipyard.cannons_cost` its two numbers; all
## three are requested for the next merge, with existing keys as fallbacks so
## no raw "<key>" can reach the screen.
const CANNONS_LABEL_KEY := "shipyard.cannons"
const CANNONS_LABEL_FALLBACK_KEY := "shipyard.refit"
const CANNONS_COST_KEY := "shipyard.cannons_cost"
const CANNONS_COST_FALLBACK_KEY := "shipyard.repair_cost"
const CANNONS_SELLBACK_KEY := "shipyard.cannons_sellback"
const CANNONS_SELLBACK_FALLBACK_KEY := "shipyard.repair_cost"
## Equipment rows (§4.7.2): the heading, the Unequip button and the toasts
## after a purchase/removal. New keys requested for the next merge. The
## heading and the two toasts simply stay hidden/silent while absent (the HUD
## skips a missing toast key); Unequip falls back to the shared "Sell" verb.
const EQUIP_HEADING_KEY := "shipyard.equipment"
const UNEQUIP_KEY := "shipyard.unequip"
const UNEQUIP_FALLBACK_KEY := "market.sell"
const EQUIP_BOUGHT_KEY := "shipyard.equipped"
const UNEQUIPPED_KEY := "shipyard.unequipped"
## Slot headings: `80-*` §4.7.2 names the four rows by their `10-*` §4.6 slot
## enum value, so until `shipyard.slot.<slot>` merges the heading shows that
## data token (`weapon`, `armor`, …) — a schema enum, never invented prose in
## either locale, and never a raw "<key>".
const SLOT_LABEL_FALLBACKS := {
	"weapon": "weapon",
	"armor": "armor",
	"figurehead": "figurehead",
	"sail": "sail",
}

## Durability bar geometry (docs/80-* §4.8: 8px base unit).
const BAR_W := 120.0
const BAR_H := 8.0
## Bar colour thresholds, reusing the §4.8 GOOD/WARN/BAD placeholders: a hull
## above 60% is GOOD, above 25% WARN, anything lower BAD.
const BAR_GOOD_ABOVE := 0.6
const BAR_WARN_ABOVE := 0.25
## "Nothing to repair" tooltip. New key requested for the next merge; until it
## lands the row falls back to the shared `ui.not_available`, never "<key>".
const NO_DAMAGE_KEY := "shipyard.no_damage"
const NO_DAMAGE_FALLBACK_KEY := "ui.not_available"

## Routing switch for headless tests (same convention as
## `port_screen.route_to_world`): with `false`, [method go_back] runs and emits
## [signal went_back] but does not swap the scene.
var route_to_hub: bool = true

## Emitted right before the S6 → S4 route.
signal went_back

## Buy buttons by ship type id (tests + [method _bind_catalog]).
var _buy_buttons: Dictionary = {}
## One widget dict per fleet row, in fleet order. Keys: `index`, `points`,
## `preview`, `repair`, `sell`, `promote`, `refit`, `refit_note`, `cannons`,
## `refit_sellback`, `equip` (slot → row dict).
var _fleet_widgets: Array = []
## The player's own equipment rows (`weapon`/`armor`), slot → row dict.
var _player_equip_widgets: Dictionary = {}
## Fleet index captured by the open sell-confirmation dialog (-1 = none).
var _pending_sell_index := -1
## Guards the LineEdit `text_changed` handler while it rewrites the field.
var _normalizing_points := false
## Set while [method rebuild] runs so `fleet_changed` cannot re-enter it.
var _rebuilding := false

@onready var _background: ColorRect = $Background
@onready var _hud: Control = $HUD
@onready var _title: Label = $Layout/VBox/Header/Title
@onready var _gold_label: Label = $Layout/VBox/Header/Gold
@onready var _back_button: Button = $Layout/VBox/Header/Back
@onready var _catalog_title: Label = $Layout/VBox/Body/CatalogPanel/Margin/Box/CatalogTitle
@onready var _catalog_rows: VBoxContainer = $Layout/VBox/Body/CatalogPanel/Margin/Box/CatalogScroll/CatalogRows
@onready var _fleet_title: Label = $Layout/VBox/Body/FleetPanel/Margin/Box/FleetTitle
@onready var _player_equip_title: Label = $Layout/VBox/Body/FleetPanel/Margin/Box/PlayerEquip/PlayerEquipTitle
@onready var _player_equip_rows: VBoxContainer = $Layout/VBox/Body/FleetPanel/Margin/Box/PlayerEquip/PlayerEquipRows
@onready var _fleet_rows: VBoxContainer = $Layout/VBox/Body/FleetPanel/Margin/Box/FleetScroll/FleetRows
@onready var _confirm: Control = $ConfirmDialog


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	_title.add_theme_font_size_override("font_size", 32)
	for label in [_title, _gold_label, _catalog_title, _fleet_title]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_back_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_back_button.pressed.connect(go_back)
	_catalog_title.add_theme_font_size_override("font_size", 20)
	_fleet_title.add_theme_font_size_override("font_size", 20)
	_panel_style($Layout/VBox/Body/CatalogPanel)
	_panel_style($Layout/VBox/Body/FleetPanel)

	# S6 keeps the §4.5 bars but not the sea viewport/minimap (same as S4).
	_hud.set_minimap_visible(false)
	_confirm.confirmed.connect(_on_sell_confirmed)
	_confirm.cancelled.connect(_on_sell_cancelled)

	rebuild()

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_state_changed)
	EventBus.fleet_changed.connect(_on_state_changed)


func _unhandled_input(event: InputEvent) -> void:
	# §4.3 "Esc = back / close modal". A modal (the sell confirmation or a HUD
	# dialog) owns input first (§6 "modals consume all input").
	if event.is_action_pressed("back"):
		if has_modal():
			return
		get_viewport().set_input_as_handled()
		go_back()
		return


# --- Public API ------------------------------------------------------------

## True while the sell confirmation or any HUD dialog is on screen.
func has_modal() -> bool:
	if _confirm != null and _confirm.is_open():
		return true
	if _hud != null and _hud.has_method("has_modal") and _hud.has_modal():
		return true
	return false


## S6 → S4 back edge (docs/30-* §4.7 "Esc from a facility returns here").
func go_back() -> bool:
	went_back.emit()
	if route_to_hub:
		GameState.change_scene(PORT_SCENE)
	return true


## Buy button of `ship_type_id` (null when the catalog is not built yet).
func buy_button(ship_type_id: String) -> Button:
	return _buy_buttons.get(ship_type_id, null)


## Widget dict of `fleet[index]` as described on [member _fleet_widgets].
func fleet_widget(index: int) -> Dictionary:
	if index < 0 or index >= _fleet_widgets.size():
		return {}
	return _fleet_widgets[index]


## Widget dict of the player's own `slot` row (`weapon`/`armor`), or `{}`.
func player_equipment_widget(slot: String) -> Dictionary:
	var value = _player_equip_widgets.get(slot, null)
	return value if value is Dictionary else {}


## Widget dict of `fleet[ship_index]`'s `slot` row (`figurehead`/`sail`), or `{}`.
func ship_equipment_widget(index: int, slot: String) -> Dictionary:
	var equip = fleet_widget(index).get("equip", {})
	if not (equip is Dictionary):
		return {}
	var value = (equip as Dictionary).get(slot, null)
	return value if value is Dictionary else {}


## Rebuilds the gold readout and both lists from `GameState`. Deferred by the
## action handlers so a button is never freed inside its own signal.
func rebuild() -> void:
	if not is_inside_tree() or _rebuilding:
		return
	_rebuilding = true
	_bind_header()
	_bind_catalog()
	_bind_fleet()
	_rebuilding = false


# --- Header ----------------------------------------------------------------

func _bind_header() -> void:
	var port := _port_data()
	if port.is_empty():
		# Opened standalone (editor / test): no port to name, keep the S6 noun.
		_title.text = I18n.t_key("port.shipyard")
	else:
		_title.text = I18n.fmt("shipyard.title", {"port": I18n.t(port.get("name", {}))})
	_gold_label.text = I18n.fmt(
		"ui.gold_amount", {"gold": HudLib.format_thousands(GameState.gold)}
	)
	_back_button.text = I18n.t_key("ui.back")


func _port_data() -> Dictionary:
	var value = GameState.current_port
	if value is String and not (value as String).is_empty():
		return DataLoader.get_port(value)
	return {}


# --- Catalog ---------------------------------------------------------------

## All 8 ShipTypes, in the locked data order (`ship_types.json`), no regional
## restrictions (§4.3).
func _bind_catalog() -> void:
	_catalog_title.text = I18n.t_key("shipyard.catalog")
	_clear(_catalog_rows)
	_buy_buttons.clear()
	for ship_type in DataLoader.ship_types_list:
		_add_catalog_row(ship_type)


func _add_catalog_row(ship_type: Dictionary) -> void:
	var ship_type_id := str(ship_type.get("id", ""))
	# §4.8: 32px table row. Two lines per entry (identity/price/action, then the
	# stats) so the long localised stat string can wrap instead of overflowing
	# the half-width catalog panel at 1280×720.
	var card := VBoxContainer.new()
	card.name = "Catalog_%s" % ship_type_id
	card.custom_minimum_size.y = float(PaletteLib.ROW_H)
	card.add_theme_constant_override("separation", 4)

	var row := HBoxContainer.new()
	row.name = "Top"
	row.add_theme_constant_override("separation", 12)

	var name_label := _label(I18n.t(ship_type.get("name", {})), PaletteLib.TEXT)
	name_label.name = "Name"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.tooltip_text = name_label.text
	row.add_child(name_label)

	var price := _label(
		I18n.fmt("shipyard.price", {"price": HudLib.format_thousands(
			ShipyardLib.buy_price(ship_type_id))}),
		PaletteLib.ACCENT
	)
	price.name = "Price"
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(price)

	var buy := _row_button(I18n.t_key("shipyard.buy"))
	buy.name = "Buy_%s" % ship_type_id
	buy.custom_minimum_size.x = 72
	var reason := ShipyardLib.buy_block_reason(ship_type_id)
	buy.disabled = not reason.is_empty()
	# §4.7: a disabled action states its reason as a tooltip; an enabled one
	# shows the price instead of a stale reason.
	buy.tooltip_text = _reason_text(reason) if not reason.is_empty() else price.text
	buy.pressed.connect(_on_buy_pressed.bind(ship_type_id))
	row.add_child(buy)

	card.add_child(row)

	var stats := _label(_catalog_stats(ship_type), PaletteLib.PANEL_LINE)
	stats.name = "Stats"
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats.tooltip_text = _catalog_stats(ship_type)
	card.add_child(stats)

	_buy_buttons[ship_type_id] = buy
	_catalog_rows.add_child(card)


## One-line stat string for a catalog row: durability · capacity · speed ·
## crew range · armament slots, each through its own `ui_strings` key.
func _catalog_stats(ship_type: Dictionary) -> String:
	var slots := int(ship_type.get("armament_slots", 0))
	# `shipyard.cannons_stat` is awaiting its `ui_strings.json` merge (see the
	# constant); until then the localised "Refit" noun plus the slot count
	# carries the same number without inventing prose in either locale.
	var cannons := I18n.fmt(CANNONS_KEY, {"slots": slots}) \
		if DataLoader.ui_strings.has(CANNONS_KEY) \
		else "%s %d" % [I18n.t_key(CANNONS_FALLBACK_KEY), slots]
	var parts: Array[String] = [
		I18n.fmt("shipyard.durability", {"durability": int(ship_type.get("durability", 0))}),
		I18n.fmt("shipyard.capacity_stat", {"capacity": int(ship_type.get("capacity", 0))}),
		I18n.fmt("shipyard.speed_stat", {"speed": int(ship_type.get("speed", 0))}),
		I18n.fmt("shipyard.crew_minmax", {
			"crew": int(ship_type.get("crew_min", 0)),
			"max": int(ship_type.get("crew_max", 0)),
		}),
		cannons,
	]
	return " · ".join(parts)


# --- Fleet -----------------------------------------------------------------

## Own fleet, one panel per hull in `fleet` order (flagship first), plus the
## player's own two equipment slots above the list (`60-*` §4.11.12).
func _bind_fleet() -> void:
	_fleet_title.text = I18n.t_key("fleet.title")
	_bind_player_equipment()
	_clear(_fleet_rows)
	_fleet_widgets.clear()
	for index in GameState.fleet.size():
		_add_fleet_row(index, GameState.fleet[index])


## The player's `weapon` + `armor` rows (§4.7.2 "four slot rows … `weapon`,
## `armor` on the player").
func _bind_player_equipment() -> void:
	_player_equip_title.text = I18n.t_key(EQUIP_HEADING_KEY) \
		if DataLoader.ui_strings.has(EQUIP_HEADING_KEY) else ""
	_player_equip_title.visible = not _player_equip_title.text.is_empty()
	_clear(_player_equip_rows)
	_player_equip_widgets.clear()
	for slot in ShipyardLib.PLAYER_SLOTS:
		_player_equip_widgets[slot] = \
			_add_equipment_row(_player_equip_rows, slot, -1)


func _add_fleet_row(index: int, ship: Dictionary) -> void:
	var widgets: Dictionary = {"index": index, "sell": null, "promote": null,
		"repair": null, "refit": null, "refit_note": null, "points": null,
		"preview": null, "cannons": null, "refit_sellback": null, "equip": {}}

	var panel := PanelContainer.new()
	panel.name = "Fleet_%d" % index
	_panel_style(panel)
	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 8)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	# --- line 1: identity + promote/sell -----------------------------------
	var top := HBoxContainer.new()
	top.name = "Top"
	top.add_theme_constant_override("separation", 12)

	var name_label := _label(_ship_title(index, ship), PaletteLib.TEXT)
	name_label.name = "Name"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(name_label)

	# Promote: free, port-only, non-flagship rows only (§4.4). The flagship has
	# no Promote button at all — there is nothing to promote.
	if index > 0:
		var promote := _row_button(I18n.t_key("fleet.promote"))
		promote.name = "Promote_%d" % index
		var promote_reason := "" if ShipyardLib.can_promote(index) \
			else "ui.not_available"
		promote.disabled = not promote_reason.is_empty()
		promote.tooltip_text = _reason_text(promote_reason) \
			if not promote_reason.is_empty() else promote.text
		promote.pressed.connect(_on_promote_pressed.bind(index))
		top.add_child(promote)
		widgets["promote"] = promote

	# Sell: **absent** on the flagship row, always (§4.3/§6). Elsewhere it is
	# present but disabled (with the reason) when cargo is aboard or it is the
	# last hull.
	if index > 0:
		var sell := _row_button(I18n.t_key("shipyard.sell"))
		sell.name = "Sell_%d" % index
		var sell_reason := ShipyardLib.sell_block_reason(index)
		sell.disabled = not sell_reason.is_empty()
		sell.tooltip_text = _reason_text(sell_reason) if not sell_reason.is_empty() \
			else I18n.fmt("shipyard.price", {"price": ShipyardLib.sell_price(index)})
		sell.pressed.connect(_on_sell_pressed.bind(index))
		top.add_child(sell)
		widgets["sell"] = sell

	box.add_child(top)

	# --- line 2: durability bar, durability, crew -------------------------
	var stats_row := HBoxContainer.new()
	stats_row.name = "Stats"
	stats_row.add_theme_constant_override("separation", 12)

	var max_durability: int = ShipyardLib.ship_max_durability(index)
	var durability := int(ship.get("durability", 0))
	var ratio := float(durability) / float(max_durability) if max_durability > 0 else 0.0
	stats_row.add_child(_durability_bar(ratio))

	var durability_label := _label(
		I18n.fmt("shipyard.durability", {
			"durability": "%d/%d" % [durability, max_durability],
		}),
		PaletteLib.TEXT
	)
	durability_label.name = "Durability"
	durability_label.custom_minimum_size.x = 110
	stats_row.add_child(durability_label)

	var crew_label := _label(
		I18n.fmt("shipyard.crew_stat", {
			"crew": int(ship.get("crew", 0)),
			"max": FleetLib.ship_stat(ship, "crew_max"),
		}),
		PaletteLib.PANEL_LINE
	)
	crew_label.name = "Crew"
	crew_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_row.add_child(crew_label)

	box.add_child(stats_row)

	# --- line 3: repair picker -------------------------------------------
	var bottom := HBoxContainer.new()
	bottom.name = "Actions"
	bottom.add_theme_constant_override("separation", 8)

	var repair_label := _label(I18n.t_key("shipyard.repair_points"), PaletteLib.TEXT)
	repair_label.name = "RepairLabel"
	bottom.add_child(repair_label)

	var points := LineEdit.new()
	points.name = "Points_%d" % index
	points.custom_minimum_size = Vector2(56, PaletteLib.ROW_H)
	points.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	points.max_length = 3
	points.tooltip_text = repair_label.text
	# §4.7 numeric fields: digits only, live-clamped, empty = invalid.
	points.text_changed.connect(_on_points_changed.bind(index))
	bottom.add_child(points)
	widgets["points"] = points

	for step in PICKER_STEPS:
		var step_button := _row_button(str(step))
		step_button.name = "Points%s_%d" % [step, index]
		step_button.custom_minimum_size.x = 40
		step_button.pressed.connect(_on_points_step_pressed.bind(index, step))
		bottom.add_child(step_button)

	var max_button := _row_button(_fmt_or(MAX_KEY, {}, MAX_FALLBACK_KEY))
	max_button.name = "PointsMax_%d" % index
	max_button.custom_minimum_size.x = 56
	max_button.pressed.connect(_on_points_step_pressed.bind(index, -1))
	bottom.add_child(max_button)

	var preview := _label("", PaletteLib.PANEL_LINE)
	preview.name = "Preview"
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(preview)
	widgets["preview"] = preview

	var repair := _row_button(I18n.t_key("shipyard.repair"))
	repair.name = "Repair_%d" % index
	repair.pressed.connect(_on_repair_pressed.bind(index))
	bottom.add_child(repair)
	widgets["repair"] = repair

	box.add_child(bottom)

	# --- line 4: cannons picker (Phase 2, `80-*` §4.7.2) -------------------
	# Numeric picker 0 … `max_refit` at 100g/cannon with the 50g sell-back
	# shown for the current count. Every number comes from the engine.
	var refit_row := HBoxContainer.new()
	refit_row.name = "RefitRow"
	refit_row.add_theme_constant_override("separation", 8)

	var cannons_label := _label(
		_fmt_or(CANNONS_LABEL_KEY, {}, CANNONS_LABEL_FALLBACK_KEY), PaletteLib.TEXT
	)
	cannons_label.name = "CannonsLabel"
	refit_row.add_child(cannons_label)

	var cannons_field := LineEdit.new()
	cannons_field.name = "Cannons_%d" % index
	cannons_field.custom_minimum_size = Vector2(56, PaletteLib.ROW_H)
	cannons_field.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cannons_field.max_length = 3
	cannons_field.tooltip_text = cannons_label.text
	# §4.7 numeric fields: digits only, live-clamped, empty = invalid.
	cannons_field.text_changed.connect(_on_cannons_changed.bind(index))
	refit_row.add_child(cannons_field)
	widgets["cannons"] = cannons_field

	var cannons_max := _row_button(_fmt_or(MAX_KEY, {}, MAX_FALLBACK_KEY))
	cannons_max.name = "CannonsMax_%d" % index
	cannons_max.custom_minimum_size.x = 56
	cannons_max.pressed.connect(_on_cannons_max_pressed.bind(index))
	refit_row.add_child(cannons_max)

	var refit := _row_button(I18n.t_key("shipyard.refit"))
	refit.name = "Refit_%d" % index
	refit.pressed.connect(_on_refit_pressed.bind(index))
	refit_row.add_child(refit)
	widgets["refit"] = refit

	# Two notes: live cost preview (left, expands) and the sell-back of the
	# cannons already aboard (right, fixed), as §4.7.2 asks.
	var refit_note := _label("", PaletteLib.PANEL_LINE)
	refit_note.name = "RefitNote_%d" % index
	refit_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refit_row.add_child(refit_note)
	widgets["refit_note"] = refit_note

	var sellback_note := _label("", PaletteLib.PANEL_LINE)
	sellback_note.name = "RefitSellback_%d" % index
	refit_row.add_child(sellback_note)
	widgets["refit_sellback"] = sellback_note

	box.add_child(refit_row)

	# --- lines 5+: ship equipment slots (`figurehead`, `sail`) -------------
	# `60-*` §4.11.12: the ship slots live on this hull. Each row is built by
	# the same helper as the player's `weapon`/`armor` rows, so both owners
	# render identically (§4.7.2).
	var equip_box := VBoxContainer.new()
	equip_box.name = "EquipRows"
	equip_box.add_theme_constant_override("separation", 4)
	widgets["equip"] = {}
	for slot in ShipyardLib.SHIP_SLOTS:
		(widgets["equip"] as Dictionary)[slot] = \
			_add_equipment_row(equip_box, slot, index)
	box.add_child(equip_box)

	_fleet_rows.add_child(panel)
	_fleet_widgets.append(widgets)

	# Paint the picker state for the current row (0 points = no preview, no
	# repair). The flagship is the hull most worth repairing; it just cannot be
	# sold.
	_refresh_repair(index)
	_refresh_refit(index)


## "Ship 1 · Caravel" plus the flagship tag (§4.4: the flagship is fleet[0]).
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


# --- Repair picker ---------------------------------------------------------

## Current picker value for `index` (0 when empty/invalid).
func repair_points(index: int) -> int:
	var widgets := fleet_widget(index)
	if widgets.is_empty():
		return 0
	return int((widgets["points"] as LineEdit).text.to_int())


## Live cost preview + Repair enablement for the picker's current value.
func _refresh_repair(index: int) -> void:
	var widgets := fleet_widget(index)
	if widgets.is_empty():
		return
	var points: LineEdit = widgets["points"]
	var preview: Label = widgets["preview"]
	var repair: Button = widgets["repair"]
	var requested := points.text.to_int()
	var damage: int = ShipyardLib.max_repair_points(index)

	# §6: no damage → nothing to repair; the field and the button go inert.
	if damage <= 0:
		points.editable = false
		points.text = "0"
		preview.text = I18n.fmt("shipyard.repair_cost", {"amount": 0})
		repair.disabled = true
		repair.tooltip_text = _fmt_or(
			NO_DAMAGE_KEY, {}, NO_DAMAGE_FALLBACK_KEY
		)
		return

	points.editable = true
	points.tooltip_text = I18n.t_key("shipyard.repair_points")
	var reason := ShipyardLib.repair_block_reason(index, requested)
	preview.text = I18n.fmt("shipyard.repair_cost", {
		"amount": ShipyardLib.repair_cost(index, requested),
	})
	preview.add_theme_color_override(
		"font_color",
		PaletteLib.TEXT if reason.is_empty() else PaletteLib.BAD
	)
	repair.disabled = not reason.is_empty()
	repair.tooltip_text = _reason_text(reason) if not reason.is_empty() \
		else preview.text


## §4.7 numeric entry: digits only, live-clamped to `[0, damage]`; 0/empty
## leaves the Repair button disabled.
func _on_points_changed(_text: String, index: int) -> void:
	if _normalizing_points or index < 0 or index >= GameState.fleet.size():
		return
	var widgets := fleet_widget(index)
	if widgets.is_empty():
		return
	var points: LineEdit = widgets["points"]
	var digits := ""
	for character in points.text:
		if character >= "0" and character <= "9":
			digits += character
	var clamped := mini(digits.to_int(), ShipyardLib.max_repair_points(index))
	var normalized := str(clamped) if not digits.is_empty() else ""
	if normalized != points.text:
		_normalizing_points = true
		points.text = normalized
		points.caret_column = normalized.length()
		_normalizing_points = false
	_refresh_repair(index)


func _on_points_step_pressed(index: int, step: int) -> void:
	var widgets := fleet_widget(index)
	if widgets.is_empty():
		return
	var damage: int = ShipyardLib.max_repair_points(index)
	var points: LineEdit = widgets["points"]
	var target: int = damage if step < 0 else mini(step, damage)
	points.text = str(maxi(target, 0))
	points.caret_column = points.text.length()
	_refresh_repair(index)


# --- Cannons picker (Phase 2, `80-*` §4.7.2) -------------------------------

## Current picker value for `index` (0 when empty/invalid).
func refit_cannons(index: int) -> int:
	var widgets := fleet_widget(index)
	if widgets.is_empty():
		return 0
	return int((widgets["cannons"] as LineEdit).text.to_int())


## Live cost preview + Refit enablement for the picker's current value, plus
## the sell-back note for the cannons already aboard (§4.7.2).
func _refresh_refit(index: int) -> void:
	var widgets := fleet_widget(index)
	if widgets.is_empty():
		return
	var field: LineEdit = widgets["cannons"]
	var note: Label = widgets["refit_note"]
	var sellback_note: Label = widgets["refit_sellback"]
	var refit: Button = widgets["refit"]
	var ship: Dictionary = GameState.fleet[index]
	var aboard := int(ship.get("cannons", 0))
	var requested := field.text.to_int()

	# The 50g/cannon sell-back of what is already mounted is always shown, so
	# the player can price a refit against it at a glance.
	sellback_note.text = _fmt_or(CANNONS_SELLBACK_KEY, {
		"amount": ShipyardLib.refit_sellback(aboard),
	}, CANNONS_SELLBACK_FALLBACK_KEY)

	var cap: int = ShipyardLib.max_refit(index)
	field.tooltip_text = I18n.t_key("shipyard.refit")
	note.text = _fmt_or(CANNONS_COST_KEY, {
		"amount": ShipyardLib.refit_cost(requested),
	}, CANNONS_COST_FALLBACK_KEY)
	note.add_theme_color_override(
		"font_color",
		PaletteLib.TEXT if requested > 0 and requested <= cap else PaletteLib.PANEL_LINE
	)
	var reason: String = ShipyardLib.refit_block_reason(index, requested)
	refit.disabled = not reason.is_empty()
	refit.tooltip_text = _reason_text(reason) if not reason.is_empty() else note.text
	# A hull with no spare slots/cargo has nothing to pick: the field and the
	# Max button go inert, exactly like the repair picker at 0 damage (§6).
	field.editable = cap > 0
	if cap <= 0:
		field.text = "0"


## §4.7 numeric entry: digits only, live-clamped to `[0, max_refit]`.
func _on_cannons_changed(_text: String, index: int) -> void:
	if _normalizing_points or index < 0 or index >= GameState.fleet.size():
		return
	var widgets := fleet_widget(index)
	if widgets.is_empty():
		return
	var field: LineEdit = widgets["cannons"]
	var digits := ""
	for character in field.text:
		if character >= "0" and character <= "9":
			digits += character
	var clamped := mini(digits.to_int(), ShipyardLib.max_refit(index))
	var normalized := str(clamped) if not digits.is_empty() else ""
	if normalized != field.text:
		_normalizing_points = true
		field.text = normalized
		field.caret_column = normalized.length()
		_normalizing_points = false
	_refresh_refit(index)


func _on_cannons_max_pressed(index: int) -> void:
	var widgets := fleet_widget(index)
	if widgets.is_empty():
		return
	var field: LineEdit = widgets["cannons"]
	field.text = str(maxi(ShipyardLib.max_refit(index), 0))
	field.caret_column = field.text.length()
	_refresh_refit(index)


# --- Equipment rows (`80-*` §4.7.2, `60-*` §4.11.12) ----------------------

## Builds one equipment row into `parent` and returns its widget dict:
## "{Slot} · <worn item or ui.empty>" plus every item of that slot as a buy
## button (price on the label, disabled reason as the tooltip) and Unequip when
## something is worn (`80-*` §4.7.2).
##
## `ship_index < 0` means the player's own slots (`weapon`/`armor`).
## The dict is `{slot, row, heading, worn, buy (id → Button), unequip}`.
func _add_equipment_row(parent: Node, slot: String, ship_index: int) -> Dictionary:
	# Two lines per row (§4.8: 32px rows, half-width panel): line 1 is the
	# slot noun, the worn item and Unequip; line 2 is the buy list, because
	# "<name> <price>" buttons for two items never fit beside those labels at
	# 1280×720.
	var card := VBoxContainer.new()
	card.name = "Equip_%s_%s" % [slot, "player" if ship_index < 0 else str(ship_index)]
	card.add_theme_constant_override("separation", 2)

	var row := HBoxContainer.new()
	row.name = "Worn"
	row.add_theme_constant_override("separation", 8)

	var worn_id := _worn_equipment(slot, ship_index)
	var heading := _label(_slot_label(slot), PaletteLib.TEXT)
	heading.name = "Slot"
	heading.custom_minimum_size.x = 90
	row.add_child(heading)

	var worn := _label(
		_equipment_name(worn_id) if not worn_id.is_empty() else I18n.t_key("ui.empty"),
		PaletteLib.ACCENT if not worn_id.is_empty() else PaletteLib.PANEL_LINE
	)
	worn.name = "ItemName"
	worn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	worn.tooltip_text = worn.text
	row.add_child(worn)

	var unequip := _row_button(_fmt_or(UNEQUIP_KEY, {}, UNEQUIP_FALLBACK_KEY))
	unequip.name = "Unequip_%s_%s" % [slot,
		"player" if ship_index < 0 else str(ship_index)]
	unequip.disabled = worn_id.is_empty()
	unequip.tooltip_text = _reason_text("ui.not_available") \
		if worn_id.is_empty() else unequip.text
	unequip.pressed.connect(_on_unequip_pressed.bind(slot, ship_index))
	row.add_child(unequip)

	card.add_child(row)

	var buy_row := HBoxContainer.new()
	buy_row.name = "Buy"
	buy_row.add_theme_constant_override("separation", 8)
	var buttons: Dictionary = {}
	for item in ShipyardLib.equipment_list(slot):
		var equipment_id := str(item.get("id", ""))
		var price := ShipyardLib.equip_price(slot, equipment_id)
		var buy := _row_button("%s · %s" % [
			_equipment_name(equipment_id),
			I18n.fmt("shipyard.price", {"price": HudLib.format_thousands(price)}),
		])
		buy.name = "Buy_%s_%s" % [equipment_id,
			"player" if ship_index < 0 else str(ship_index)]
		buy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var reason := ShipyardLib.equip_block_reason(slot, equipment_id, ship_index)
		buy.disabled = not reason.is_empty()
		buy.tooltip_text = _reason_text(reason) if not reason.is_empty() \
			else _equipment_tooltip(slot, equipment_id)
		buy.pressed.connect(_on_equip_pressed.bind(slot, equipment_id, ship_index))
		buy_row.add_child(buy)
		buttons[equipment_id] = buy
	card.add_child(buy_row)

	parent.add_child(card)
	return {
		"slot": slot, "row": card, "heading": heading, "worn": worn,
		"buy": buttons, "unequip": unequip,
	}


## The id worn in `slot` on the player (`ship_index < 0`) or on a hull.
func _worn_equipment(slot: String, ship_index: int) -> String:
	if ship_index < 0:
		return ShipyardLib.equipped_player(slot)
	return ShipyardLib.equipped_ship(ship_index, slot)


## Localised item name (the id itself for an unknown id, never a "<key>").
func _equipment_name(equipment_id: String) -> String:
	if equipment_id.is_empty():
		return ""
	var item: Dictionary = DataLoader.get_equipment(equipment_id)
	if item.is_empty():
		return equipment_id
	return I18n.t(item.get("name", {}))


## Row heading: `shipyard.slot.<slot>` once merged, else the `10-*` §4.6 slot
## enum itself (`weapon`, `armor`, `figurehead`, `sail`) — a data token, never
## invented prose and never a raw "<key>". The L10n keys are requested for the
## next `ui_strings.json` merge (see the report).
func _slot_label(slot: String) -> String:
	var key := "shipyard.slot.%s" % slot
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return str(SLOT_LABEL_FALLBACKS.get(slot, slot))


## Tooltip for an enabled buy button: the item's modifiers, rendered as
## "<stat> +N" pairs with each stat's existing `char.*` noun.
func _equipment_tooltip(slot: String, equipment_id: String) -> String:
	var item: Dictionary = DataLoader.get_equipment(equipment_id)
	var modifiers = item.get("modifiers", {})
	var parts: Array[String] = []
	if modifiers is Dictionary:
		for stat in (modifiers as Dictionary):
			var delta := int((modifiers as Dictionary)[stat])
			var stat_key := "char.%s" % str(stat)
			var stat_name := I18n.t_key(stat_key) \
				if DataLoader.ui_strings.has(stat_key) else str(stat)
			parts.append("%s %+d" % [stat_name, delta])
	if parts.is_empty():
		return _equipment_name(equipment_id)
	return "%s: %s" % [_equipment_name(equipment_id), " · ".join(parts)]


# --- Actions ---------------------------------------------------------------

func _on_buy_pressed(ship_type_id: String) -> void:
	if not ShipyardLib.buy(ship_type_id):
		return
	_toast("shipyard.bought", {"ship": _ship_type_name(ship_type_id)})
	# `fleet_changed`/`gold_changed` arrive from the engine; rebuild deferred so
	# this button is not freed inside its own `pressed` handler.
	_rebuild_deferred()


func _on_refit_pressed(index: int) -> void:
	var cannons := refit_cannons(index)
	if not ShipyardLib.refit(index, cannons):
		return
	# `shipyard.refitted` is requested for the next merge; the HUD skips a
	# missing key silently, so no "<key>" can be shown in the meantime.
	_toast("shipyard.refitted", {"cannons": cannons,
		"amount": ShipyardLib.refit_cost(cannons)})
	_rebuild_deferred()


func _on_equip_pressed(slot: String, equipment_id: String,
		ship_index: int) -> void:
	var old_id := _worn_equipment(slot, ship_index)
	if not ShipyardLib.equip(slot, equipment_id, ship_index):
		return
	var values := {
		"name": _equipment_name(equipment_id),
		"old": _equipment_name(old_id),
		"amount": -ShipyardLib.equip_net_cost(slot, equipment_id, ship_index),
	}
	# `shipyard.equipped` is requested for the next merge; the HUD skips a
	# missing key silently (`Hud.toast_key`), so no "<key>" can be shown.
	_toast(EQUIP_BOUGHT_KEY, values)
	_rebuild_deferred()


func _on_unequip_pressed(slot: String, ship_index: int) -> void:
	var worn := _worn_equipment(slot, ship_index)
	if not ShipyardLib.unequip(slot, ship_index):
		return
	_toast(UNEQUIPPED_KEY, {
		"name": _equipment_name(worn),
		"amount": ShipyardLib.equip_sellback(slot, worn),
	})
	_rebuild_deferred()


func _on_repair_pressed(index: int) -> void:
	var points := repair_points(index)
	var cost := ShipyardLib.repair_cost(index, points)
	if not ShipyardLib.repair(index, points):
		return
	_toast("shipyard.repaired", {"points": points, "amount": cost})
	_rebuild_deferred()


func _on_sell_pressed(index: int) -> void:
	if index < 0 or index >= GameState.fleet.size():
		return
	# §4.3: selling loses the crew, so it always goes through a warning confirm
	# (`shipyard.sell.confirm`) — never a silent click.
	_pending_sell_index = index
	_confirm.open_key("shipyard.sell.confirm", {
		"ship": _ship_title(index, GameState.fleet[index]),
	})


func _on_sell_confirmed() -> void:
	var index := _pending_sell_index
	_pending_sell_index = -1
	if index < 0 or index >= GameState.fleet.size():
		return
	var ship_name := _ship_title(index, GameState.fleet[index])
	var price := ShipyardLib.sell_price(index)
	# Re-validated at confirm time: nothing may have changed, but the engine —
	# not this screen — decides (§6 "Sell button absent on the flagship").
	if not ShipyardLib.sell(index):
		return
	_toast("shipyard.sold", {"ship": ship_name, "amount": price})
	_rebuild_deferred()


func _on_sell_cancelled() -> void:
	# §4.7: cancel leaves the fleet untouched; just forget the pending row.
	_pending_sell_index = -1


func _on_promote_pressed(index: int) -> void:
	# Free and port-only; the order of every other hull is preserved (§4.4).
	if ShipyardLib.promote(index):
		_rebuild_deferred()


func _rebuild_deferred() -> void:
	call_deferred("rebuild")


# --- Binding helpers -------------------------------------------------------

func _on_locale_changed(_locale: String) -> void:
	rebuild()


func _on_state_changed(_value = null) -> void:
	# Reached from `gold_changed(int)` and `fleet_changed()`, hence `_value`.
	_rebuild_deferred()


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.gold_changed.is_connected(_on_state_changed):
		EventBus.gold_changed.disconnect(_on_state_changed)
	if EventBus.fleet_changed.is_connected(_on_state_changed):
		EventBus.fleet_changed.disconnect(_on_state_changed)


func _toast(key: String, values: Dictionary) -> void:
	# Feedback is transient (§4.7); the HUD owns the single toast slot.
	if _hud != null and _hud.has_method("toast_key"):
		_hud.toast_key(key, values)


func _ship_type_name(ship_type_id: String) -> String:
	var ship_type: Dictionary = DataLoader.get_ship_type(ship_type_id)
	return I18n.t(ship_type.get("name", {})) if not ship_type.is_empty() \
		else ship_type_id


## Localised disabled-reason text, prefixed by the shared `ui.reason` label.
func _reason_text(key: String) -> String:
	if key.is_empty():
		return ""
	return I18n.fmt("ui.reason", {"reason": I18n.t_key(key)})


## `key` when `ui_strings.json` has it, else `fallback_key` (see MAX_KEY /
## CANNONS_KEY: awaiting the next `ui_strings.json` merge, and the screen must
## never print a raw "<key>").
func _fmt_or(key: String, values: Dictionary, fallback_key: String) -> String:
	if DataLoader.ui_strings.has(key):
		if values.is_empty():
			return I18n.t_key(key)
		return I18n.fmt(key, values)
	if values.is_empty():
		return I18n.t_key(fallback_key)
	return I18n.fmt(fallback_key, values)


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


## Durability bar placeholder (§4.8: ColorRect only, no textures): a full-width
## background with a fractional-anchored fill, tier-coloured from the palette.
func _durability_bar(ratio: float) -> Control:
	var bar := Control.new()
	bar.custom_minimum_size = Vector2(BAR_W, BAR_H)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var background := ColorRect.new()
	background.color = PaletteLib.PANEL_LINE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bar.add_child(background)

	var fill := ColorRect.new()
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


func _panel_style(panel: PanelContainer) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", style)


## Removes and frees every child immediately so a rebuild never shows a mix of
## old and new rows for a frame.
func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
