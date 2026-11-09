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
##   * left — the catalog: the docked port's stock list (`facilities.shipyard`,
##     docs/40 §4.3.1), each row with its role label (`shipyard.role.*`), price
##     + a one-line stats string and a Buy button whose disabled reason is the
##     tooltip (`80-*` §4.7 "disabled with tooltip-reason"). Rows render the
##     three §4.7.12 states: available, tier-gray 需发展度, allegiance-gray
##     同盟专营 (unallied neutrals lock the whole list);
##   * right — the player's two equipment slots (`weapon`/`armor`, `60-*`
##     §4.11.12), then own fleet, one panel per hull: type, durability bar,
##     crew, repair picker (1 / 10 / Max + numeric, live cost preview), the
##     Phase-2 cannons picker (§4.7.2), the ship's two equipment rows
##     (`figurehead`/`sail`), Promote and Sell (with the
##     `shipyard.sell.confirm` modal);
##   * shared HUD (§4.5: S4–S8 keep the same bars, minimap hidden in port).
##
## Equipment rows show the worn item or `ui.empty`, one buy button per stock
## item of that slot (the same three §4.7.12 states; rare drop-only items are
## never listed, `60-*` §4.11.13) and an Unequip button when something is worn
## (`80-*` §4.7.2).
##
## Esc / Back return to the port hub (S6 → S4, `30-*` §4.7). All text is
## re-bound on `EventBus.locale_changed` (§6), and the lists re-bind on
## `gold_changed` / `fleet_changed` so a transaction repaints immediately.

const PaletteLib := preload("res://scripts/palette.gd")
## Phase-10 sweep (§4.9): durability bars render through the kit's value_bar
## atom (tier via the S6 thresholds below), hull cards reuse the kit frame's
## padded-panel chrome, equipment rows carry the `eq_{id}` icons through the
## kit registry (an absent id renders nothing — the flat fallback), and the
## hand-built panels/buttons retire to the shared theme.
const UiKitLib := preload("res://scripts/ui_kit.gd")
## Phase-11 W3-B (docs/80-UI-UX.md §4.8.9): the catalog/fleet/equipment rows
## register data-derived ids at build time (ship types, fleet indices, slot
## enums); the shipped `ui_layout` table is `{}`, so the apply walk is a
## no-op. Styling stays in `ui_theme.gd`.
const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const ShipyardLib := preload("res://scripts/port/shipyard_engine.gd")
const HudLib := preload("res://scenes/ui_shared/hud.gd")
const GameOverHostLib := preload("res://scenes/ui_shared/game_over_host.gd")

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
## Bar tier thresholds, reusing the §4.8 GOOD/WARN/BAD placeholders: a hull
## above 60% is GOOD, above 25% WARN, anything lower BAD (`UiKit.auto_tier`
## takes the absolute floors derived from these ratios).
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

@onready var _background: Panel = $Background
@onready var _hud: Control = $HUD
@onready var _title: Label = $Layout/VBox/Header/Title
@onready var _gold_label: Label = $Layout/VBox/Header/Gold
@onready var _back_button: Button = $Layout/VBox/Header/Back
@onready var _header_box: HBoxContainer = $Layout/VBox/Header
@onready var _catalog_panel: PanelContainer = $Layout/VBox/Body/CatalogPanel
@onready var _catalog_title: Label = $Layout/VBox/Body/CatalogPanel/Margin/Box/CatalogTitle
@onready var _catalog_scroll: ScrollContainer = \
	$Layout/VBox/Body/CatalogPanel/Margin/Box/CatalogScroll
@onready var _catalog_rows: VBoxContainer = $Layout/VBox/Body/CatalogPanel/Margin/Box/CatalogScroll/CatalogRows
@onready var _fleet_panel: PanelContainer = $Layout/VBox/Body/FleetPanel
@onready var _fleet_title: Label = $Layout/VBox/Body/FleetPanel/Margin/Box/FleetTitle
@onready var _player_equip_box: VBoxContainer = \
	$Layout/VBox/Body/FleetPanel/Margin/Box/PlayerEquip
@onready var _player_equip_title: Label = $Layout/VBox/Body/FleetPanel/Margin/Box/PlayerEquip/PlayerEquipTitle
@onready var _player_equip_rows: VBoxContainer = $Layout/VBox/Body/FleetPanel/Margin/Box/PlayerEquip/PlayerEquipRows
@onready var _fleet_scroll: ScrollContainer = \
	$Layout/VBox/Body/FleetPanel/Margin/Box/FleetScroll
@onready var _fleet_rows: VBoxContainer = $Layout/VBox/Body/FleetPanel/Margin/Box/FleetScroll/FleetRows
@onready var _confirm: Control = $ConfirmDialog


func _ready() -> void:
	# Full-scene S9 (80-* §4.2 amendment, 2026-11-02): a run can die on any
	# ledger tick ashore — the game-over screen must rise over the shipyard too.
	GameOverHostLib.attach_to(self)
	# Phase-10 sweep: label colors retire to the shared theme; the catalog and
	# fleet panels render the themed PanelContainer chrome (the hand-built
	# boxes are gone; the scene file keeps the 32px title / 20px headings).
	_back_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_back_button.pressed.connect(go_back)

	# S6 keeps the §4.5 bars but not the sea viewport/minimap (same as S4).
	_hud.set_minimap_visible(false)
	_confirm.confirmed.connect(_on_sell_confirmed)
	_confirm.cancelled.connect(_on_sell_cancelled)

	# Phase-11 W3-B (docs/80-* §4.8.9): the scene-built surfaces register
	# first; the catalog/fleet/equipment rows register inside `rebuild()`.
	_register_static_ids()
	rebuild()

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_state_changed)
	EventBus.fleet_changed.connect(_on_state_changed)

	# Phase-11 W3-B (docs/80-* §4.8.9): one activation after the full build —
	# captures the registration baselines and applies the committed override
	# table (the shipped file is `{}`, so this is a no-op walk).
	RegistryLib.screen_active("shipyard", self)


## Phase-11 W3-B (docs/80-* §4.8.9): the scene-built controls under their
## stable hierarchical ids. Roles only tag what a `sheet` override may
## target (the styling itself stays in `ui_theme.gd`); kinds auto-derive
## (this screen has no edge-docked bars). The shared HUD and confirm dialog
## are §4.8.9 fast-follows — not registered here.
func _register_static_ids() -> void:
	RegistryLib.register("shipyard", _background, "background",
		{"role": "panel"})
	RegistryLib.register("shipyard", _header_box, "header")
	RegistryLib.register("shipyard", _title, "header.title")
	RegistryLib.register("shipyard", _gold_label, "header.gold")
	RegistryLib.register("shipyard", _back_button, "header.back",
		{"role": "button"})
	RegistryLib.register("shipyard", _catalog_panel, "catalog_panel",
		{"role": "panel"})
	RegistryLib.register("shipyard", _catalog_title, "catalog_title")
	RegistryLib.register("shipyard", _catalog_scroll, "catalog_scroll")
	RegistryLib.register("shipyard", _catalog_rows, "catalog_rows")
	RegistryLib.register("shipyard", _fleet_panel, "fleet_panel",
		{"role": "panel"})
	RegistryLib.register("shipyard", _fleet_title, "fleet_title")
	RegistryLib.register("shipyard", _player_equip_box, "player_equip")
	RegistryLib.register("shipyard", _player_equip_title,
		"player_equip.title")
	RegistryLib.register("shipyard", _player_equip_rows, "player_equip.rows")
	RegistryLib.register("shipyard", _fleet_scroll, "fleet_scroll")
	RegistryLib.register("shipyard", _fleet_rows, "fleet_rows")


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

## True while the sell confirmation, any HUD dialog, or any `modal_overlay`
## modal (the S9 game-over screen included, 80-* §4.2 full-scene amendment)
## is on screen.
func has_modal() -> bool:
	if _confirm != null and _confirm.is_open():
		return true
	if _hud != null and _hud.has_method("has_modal") and _hud.has_modal():
		return true
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
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
	# Phase-11 W3-B (docs/80-* §4.8.9): rebuild() is this screen's one
	# rebuild path (gold/fleet/locale re-render every row) — the new nodes
	# re-registered where they build; re-apply the committed override table
	# (a no-op on the shipped `{}`).
	RegistryLib.apply_screen("shipyard")


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


## The docked port id (`""` standalone — the engine's catalog fallback).
func _port_id() -> String:
	var value = GameState.current_port
	return value if value is String else ""


# --- Catalog ---------------------------------------------------------------

## The docked port's stock list (`facilities.shipyard`, 40-* §4.3.1), rendered
## with the §4.7.12 three row states. With no docked port the engine falls
## back to the full catalog so a standalone screen never renders empty.
func _bind_catalog() -> void:
	_catalog_title.text = I18n.t_key("shipyard.catalog")
	_clear(_catalog_rows)
	_buy_buttons.clear()
	for ship_type_id in ShipyardLib.shipyard_stock():
		_add_catalog_row(DataLoader.get_ship_type(ship_type_id))


func _add_catalog_row(ship_type: Dictionary) -> void:
	var ship_type_id := str(ship_type.get("id", ""))
	var port := _port_id()
	var state: String = ShipyardLib.row_state(port, ship_type_id)
	var note_text := _row_note_text(port, ship_type_id)
	# §4.8: 32px table row. Two lines per entry (identity/price/action, then the
	# stats) so the long localised stat string can wrap instead of overflowing
	# the half-width catalog panel at 1920×1080; gray rows add the note line.
	var card := VBoxContainer.new()
	card.name = "Catalog_%s" % ship_type_id
	card.custom_minimum_size.y = float(PaletteLib.ROW_H)

	var row := HBoxContainer.new()
	row.name = "Top"

	# §4.7.12 row states: available rows read the theme TEXT; gray rows the
	# `Dim` variation (the former per-screen PANEL_LINE override).
	var name_label := _label(I18n.t(ship_type.get("name", {})),
		state != ShipyardLib.ROW_AVAILABLE)
	name_label.name = "Name"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.tooltip_text = name_label.text
	row.add_child(name_label)

	# 40-* §4.3.1: every row carries its role label (战舰/商船/沿岸 via
	# `shipyard.role.*`; the raw enum until the keys merge, never "<key>").
	var role_label := _label(_role_label(ship_type), true)
	role_label.name = "Role"
	role_label.tooltip_text = role_label.text
	row.add_child(role_label)

	var price := _label(
		I18n.fmt("shipyard.price", {"price": HudLib.format_thousands(
			ShipyardLib.buy_price(ship_type_id))})
	)
	price.name = "Price"
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(price)

	var buy := UiKitLib.button("shipyard.buy", "primary")
	buy.name = "Buy_%s" % ship_type_id
	buy.custom_minimum_size.x = 72
	var reason := ShipyardLib.buy_block_reason(ship_type_id)
	buy.disabled = not reason.is_empty()
	# §4.7: a disabled action states its reason as a tooltip; an enabled one
	# shows the price instead of a stale reason. A gray state renders the
	# 需发展度/同盟专营 note (falling back to the shared reason while the
	# note keys await their merge).
	buy.tooltip_text = _gate_tooltip(reason, note_text, price.text)
	buy.pressed.connect(_on_buy_pressed.bind(ship_type_id))
	row.add_child(buy)

	card.add_child(row)

	var stats := _label(_catalog_stats(ship_type), true)
	stats.name = "Stats"
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats.tooltip_text = _catalog_stats(ship_type)
	card.add_child(stats)

	if state != ShipyardLib.ROW_AVAILABLE:
		var note := _label(note_text, true)
		note.name = "Note"
		note.visible = not note_text.is_empty()
		card.add_child(note)
		# Phase-11 W3-B (docs/80-* §4.8.9): the gray-state note line.
		RegistryLib.register("shipyard", note, "rows.%s.note" % ship_type_id)

	_buy_buttons[ship_type_id] = buy
	_catalog_rows.add_child(card)
	# Phase-11 W3-B (docs/80-* §4.8.9): one data-derived id per catalog ship
	# row (plus its named parts); the stock-list order is the §4.3.1 data
	# contract — locked like the market rows.
	RegistryLib.register("shipyard", card, "rows.%s" % ship_type_id,
		{"data_ordered": true})
	RegistryLib.register("shipyard", name_label, "rows.%s.name" % ship_type_id)
	RegistryLib.register("shipyard", role_label, "rows.%s.role" % ship_type_id)
	RegistryLib.register("shipyard", price, "rows.%s.price" % ship_type_id)
	RegistryLib.register("shipyard", buy, "rows.%s.buy" % ship_type_id,
		{"role": "button"})
	RegistryLib.register("shipyard", stats, "rows.%s.stats" % ship_type_id)


## The §4.7.12 note text of a gray row: 需发展度 {dev} for tier-gray,
## 同盟专营 for allegiance-gray (`shipyard.tier.*`, C's §4.7.15 inventory).
## Empty while those keys await their merge — the screen then falls back to
## the shared `ui.not_available` reason instead of printing a raw "<key>".
func _row_note_text(port: String, item_id: String) -> String:
	var state: String = ShipyardLib.row_state(port, item_id)
	if state == ShipyardLib.ROW_TIER_GRAY:
		var need_key := ShipyardLib.TIER_NEED_DEV_KEY
		if DataLoader.ui_strings.has(need_key):
			return I18n.fmt(need_key, {"dev": ShipyardLib.effective_dev(port)})
	elif state == ShipyardLib.ROW_ALLEGIANCE_GRAY:
		var lock_key := ShipyardLib.ALLEGIANCE_LOCKED_KEY
		if DataLoader.ui_strings.has(lock_key):
			return I18n.t_key(lock_key)
	return ""


## The role label of a catalog row: `shipyard.role.<role>` once merged, else
## the `40-*` §4.3.1 role enum itself (`war`/`trade`/`coastal`) — a schema
## token, never invented prose and never a raw "<key>".
func _role_label(ship_type: Dictionary) -> String:
	var role := str(ship_type.get("role", ""))
	if role.is_empty():
		return ""
	var key := "shipyard.role.%s" % role
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return role


## Tooltip of a disabled buy button: the gray-state note when there is one,
## else the engine reason through `ui.reason` — or the shared
## `ui.not_available` when the reason is a note key that has not merged yet.
func _gate_tooltip(reason: String, note_text: String,
		enabled_text: String = "") -> String:
	if not note_text.is_empty():
		return I18n.fmt("ui.reason", {"reason": note_text})
	if reason.is_empty():
		return enabled_text
	if DataLoader.ui_strings.has(reason):
		return _reason_text(reason)
	return _reason_text("ui.not_available")


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

	# Phase-10 sweep: the hull card reuses the kit frame's padded-panel
	# chrome (titled panel + margin body); the per-card header line stays
	# hidden — the identity line below is the card's real first row.
	var panel := UiKitLib.frame("fleet.title")
	panel.name = "Fleet_%d" % index
	# Phase-11 W3-B (docs/80-* §4.8.9): one id per hull card; the fleet order
	# (flagship first, §4.4) is a game-state contract — locked.
	RegistryLib.register("shipyard", panel, "fleet.%d" % index,
		{"role": "panel", "data_ordered": true})
	var frame_box := panel.get_child(0) as VBoxContainer
	var frame_header := frame_box.get_child(0) as Control
	frame_header.visible = false
	var box: VBoxContainer = panel.get_meta(UiKitLib.META_BODY)
	box.name = "Box"

	# --- line 1: identity + promote/sell -----------------------------------
	var top := HBoxContainer.new()
	top.name = "Top"

	var name_label := _label(_ship_title(index, ship))
	name_label.name = "Name"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(name_label)
	RegistryLib.register("shipyard", name_label, "fleet.%d.name" % index)

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
		RegistryLib.register("shipyard", promote,
			"fleet.%d.promote" % index, {"role": "button"})

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
		RegistryLib.register("shipyard", sell,
			"fleet.%d.sell" % index, {"role": "button"})

	box.add_child(top)

	# --- line 2: durability bar, durability, crew -------------------------
	var stats_row := HBoxContainer.new()
	stats_row.name = "Stats"

	var max_durability: int = ShipyardLib.ship_max_durability(index)
	var durability := int(ship.get("durability", 0))
	var bar := _durability_bar(durability, max_durability)
	stats_row.add_child(bar)
	RegistryLib.register("shipyard", bar, "fleet.%d.durability_bar" % index)

	var durability_label := _label(
		I18n.fmt("shipyard.durability", {
			"durability": "%d/%d" % [durability, max_durability],
		})
	)
	durability_label.name = "Durability"
	durability_label.custom_minimum_size.x = 110
	stats_row.add_child(durability_label)
	RegistryLib.register("shipyard", durability_label,
		"fleet.%d.durability" % index)

	var crew_label := _label(
		I18n.fmt("shipyard.crew_stat", {
			"crew": int(ship.get("crew", 0)),
			"max": FleetLib.ship_stat(ship, "crew_max"),
		}), true
	)
	crew_label.name = "Crew"
	crew_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_row.add_child(crew_label)
	RegistryLib.register("shipyard", crew_label, "fleet.%d.crew" % index)

	box.add_child(stats_row)

	# --- line 3: repair picker -------------------------------------------
	var bottom := HBoxContainer.new()
	bottom.name = "Actions"

	var repair_label := _label(I18n.t_key("shipyard.repair_points"))
	repair_label.name = "RepairLabel"
	bottom.add_child(repair_label)
	RegistryLib.register("shipyard", repair_label,
		"fleet.%d.repair_label" % index)

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
	# Phase-11 W3-B (docs/80-* §4.8.9): the repair picker (field role).
	RegistryLib.register("shipyard", points, "fleet.%d.points" % index,
		{"role": "field"})

	for step in PICKER_STEPS:
		var step_button := _row_button(str(step))
		step_button.name = "Points%s_%d" % [step, index]
		step_button.custom_minimum_size.x = 40
		step_button.pressed.connect(_on_points_step_pressed.bind(index, step))
		bottom.add_child(step_button)
		RegistryLib.register("shipyard", step_button,
			"fleet.%d.points_%d" % [index, step], {"role": "button"})

	var max_button := _row_button(_fmt_or(MAX_KEY, {}, MAX_FALLBACK_KEY))
	max_button.name = "PointsMax_%d" % index
	max_button.custom_minimum_size.x = 56
	max_button.pressed.connect(_on_points_step_pressed.bind(index, -1))
	bottom.add_child(max_button)
	RegistryLib.register("shipyard", max_button,
		"fleet.%d.points_max" % index, {"role": "button"})

	var preview := _label("", true)
	preview.name = "Preview"
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(preview)
	widgets["preview"] = preview
	RegistryLib.register("shipyard", preview, "fleet.%d.preview" % index)

	var repair := _row_button(I18n.t_key("shipyard.repair"))
	repair.name = "Repair_%d" % index
	repair.pressed.connect(_on_repair_pressed.bind(index))
	bottom.add_child(repair)
	widgets["repair"] = repair
	RegistryLib.register("shipyard", repair,
		"fleet.%d.repair" % index, {"role": "button"})

	box.add_child(bottom)

	# --- line 4: cannons picker (Phase 2, `80-*` §4.7.2) -------------------
	# Numeric picker 0 … `max_refit` at 100g/cannon with the 50g sell-back
	# shown for the current count. Every number comes from the engine.
	var refit_row := HBoxContainer.new()
	refit_row.name = "RefitRow"

	var cannons_label := _label(
		_fmt_or(CANNONS_LABEL_KEY, {}, CANNONS_LABEL_FALLBACK_KEY)
	)
	cannons_label.name = "CannonsLabel"
	refit_row.add_child(cannons_label)
	RegistryLib.register("shipyard", cannons_label,
		"fleet.%d.cannons_label" % index)

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
	# Phase-11 W3-B (docs/80-* §4.8.9): the cannons picker (field role).
	RegistryLib.register("shipyard", cannons_field,
		"fleet.%d.cannons" % index, {"role": "field"})

	var cannons_max := _row_button(_fmt_or(MAX_KEY, {}, MAX_FALLBACK_KEY))
	cannons_max.name = "CannonsMax_%d" % index
	cannons_max.custom_minimum_size.x = 56
	cannons_max.pressed.connect(_on_cannons_max_pressed.bind(index))
	refit_row.add_child(cannons_max)
	RegistryLib.register("shipyard", cannons_max,
		"fleet.%d.cannons_max" % index, {"role": "button"})

	var refit := _row_button(I18n.t_key("shipyard.refit"))
	refit.name = "Refit_%d" % index
	refit.pressed.connect(_on_refit_pressed.bind(index))
	refit_row.add_child(refit)
	widgets["refit"] = refit
	RegistryLib.register("shipyard", refit,
		"fleet.%d.refit" % index, {"role": "button"})

	# Two notes: live cost preview (left, expands) and the sell-back of the
	# cannons already aboard (right, fixed), as §4.7.2 asks.
	var refit_note := _label("", true)
	refit_note.name = "RefitNote_%d" % index
	refit_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refit_row.add_child(refit_note)
	widgets["refit_note"] = refit_note
	RegistryLib.register("shipyard", refit_note,
		"fleet.%d.refit_note" % index)

	var sellback_note := _label("", true)
	sellback_note.name = "RefitSellback_%d" % index
	refit_row.add_child(sellback_note)
	widgets["refit_sellback"] = sellback_note
	RegistryLib.register("shipyard", sellback_note,
		"fleet.%d.refit_sellback" % index)

	box.add_child(refit_row)

	# --- lines 5+: ship equipment slots (`figurehead`, `sail`) -------------
	# `60-*` §4.11.12: the ship slots live on this hull. Each row is built by
	# the same helper as the player's `weapon`/`armor` rows, so both owners
	# render identically (§4.7.2).
	var equip_box := VBoxContainer.new()
	equip_box.name = "EquipRows"
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
	# The former per-screen TEXT/BAD tints retire to the theme: a legal
	# request reads TEXT, a refused one the `Dim` variation (the disabled
	# button and its tooltip carry the reason itself).
	preview.theme_type_variation = "" if reason.is_empty() else "Dim"
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
	note.theme_type_variation = \
		"" if requested > 0 and requested <= cap else "Dim"
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
	# Phase-11 W3-B (docs/80-* §4.8.9): the §4.7.2 slot enum derives the id
	# prefix — the player's own `weapon`/`armor` rows vs a hull's
	# `figurehead`/`sail` rows (both data contracts, locked).
	var id_prefix := "equip.player" if ship_index < 0 \
		else "fleet.%d.equip" % ship_index
	# Two lines per row (§4.8: 32px rows, half-width panel): line 1 is the
	# slot noun, the worn item and Unequip; line 2 is the buy list, because
	# "<name> <price>" buttons for two items never fit beside those labels at
	# 1920×1080.
	var card := VBoxContainer.new()
	card.name = "Equip_%s_%s" % [slot, "player" if ship_index < 0 else str(ship_index)]
	RegistryLib.register("shipyard", card, "%s.%s" % [id_prefix, slot],
		{"data_ordered": true})

	var row := HBoxContainer.new()
	row.name = "Worn"

	var worn_id := _worn_equipment(slot, ship_index)
	var heading := _label(_slot_label(slot))
	heading.name = "Slot"
	heading.custom_minimum_size.x = 90
	row.add_child(heading)

	# The §4.8 hero-64 host (2026-11-08): the worn item at 1:1 64 through
	# the `icon64_eq_` lazy id — an absent id hides the slot (the flat
	# fallback); the 32px buy buttons below stay untouched.
	var hero := TextureRect.new()
	hero.name = "WornHero"
	hero.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hero.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hero.custom_minimum_size = Vector2(64, 64)
	if not worn_id.is_empty():
		hero.texture = UiKitLib.icon_texture("icon64_eq_%s" % worn_id)
	hero.visible = hero.texture != null
	hero.tooltip_text = _equipment_name(worn_id)
	row.add_child(hero)

	var worn := _label(
		_equipment_name(worn_id) if not worn_id.is_empty() else I18n.t_key("ui.empty"),
		worn_id.is_empty()
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
	# Phase-11 W3-B (docs/80-* §4.8.9): the worn line's named parts.
	RegistryLib.register("shipyard", heading, "%s.%s.slot" % [id_prefix, slot])
	RegistryLib.register("shipyard", hero,
		"%s.%s.worn_hero" % [id_prefix, slot])
	RegistryLib.register("shipyard", worn,
		"%s.%s.worn" % [id_prefix, slot])
	RegistryLib.register("shipyard", unequip,
		"%s.%s.unequip" % [id_prefix, slot], {"role": "button"})

	card.add_child(row)

	var buy_row := HBoxContainer.new()
	buy_row.name = "Buy"
	var buttons: Dictionary = {}
	var port := _port_id()
	for item in ShipyardLib.equipment_list(slot):
		var equipment_id := str(item.get("id", ""))
		var price := ShipyardLib.equip_price(slot, equipment_id)
		var buy := _row_button("%s · %s" % [
			_equipment_name(equipment_id),
			I18n.fmt("shipyard.price", {"price": HudLib.format_thousands(price)}),
		])
		# §4.8 equipment icons (`eq_{id}`) through the kit registry — the
		# hero-64 rule resolves the 64 hero (the button grows to it); an
		# absent id leaves the text-only button (the flat fallback).
		var icon := UiKitLib.hero_texture("eq_%s" % equipment_id)
		if icon != null:
			buy.icon = icon
		buy.name = "Buy_%s_%s" % [equipment_id,
			"player" if ship_index < 0 else str(ship_index)]
		buy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Phase 7 (80-* §4.7.12): the same three row states as the hull rows —
		# the gray-state note as the tooltip, the engine reason otherwise.
		var note_text := _row_note_text(port, equipment_id)
		var reason := ShipyardLib.equip_block_reason(slot, equipment_id, ship_index)
		buy.disabled = not reason.is_empty()
		buy.tooltip_text = _gate_tooltip(reason, note_text,
			_equipment_tooltip(slot, equipment_id))
		buy.pressed.connect(_on_equip_pressed.bind(slot, equipment_id, ship_index))
		buy_row.add_child(buy)
		buttons[equipment_id] = buy
		# Phase-11 W3-B (docs/80-* §4.8.9): the buy list order is the
		# equipment data order — locked like the market rows.
		RegistryLib.register("shipyard", buy,
			"%s.%s.buy.%s" % [id_prefix, slot, equipment_id],
			{"role": "button", "data_ordered": true})
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


## A row label. `dim = true` carries the theme's `Dim` variation (the
## secondary-line color); plain labels read the theme TEXT default.
func _label(text: String, dim: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	if dim:
		label.theme_type_variation = "Dim"
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _row_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = float(PaletteLib.ROW_H)
	return button


## Durability through the kit's value_bar atom (§4.9): GOOD above 60%,
## WARN above 25%, BAD below — the S6 thresholds expressed as absolute
## `UiKit.auto_tier` floors (strictly-above semantics preserved).
func _durability_bar(durability: int, max_durability: int) -> Control:
	var good_floor := int(max_durability * BAR_GOOD_ABOVE) + 1
	var warn_floor := int(max_durability * BAR_WARN_ABOVE) + 1
	var tier := UiKitLib.auto_tier(durability, good_floor, warn_floor)
	var bar := UiKitLib.value_bar(durability, maxi(max_durability, 1), tier)
	bar.custom_minimum_size = Vector2(BAR_W, 0.0)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return bar


## Removes and frees every child immediately so a rebuild never shows a mix of
## old and new rows for a frame.
func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
