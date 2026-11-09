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

## --- The authored tile table (parent-relative 32-px tiles; Phase 12) ---------
## One tile = `Palette.CHROME_TILE`. The screen root is the canvas; the two
## half-width panels carry their own rects and their children address the
## panel's space. The two dynamic sections are list blocks: the catalog
## (3-tile rows) and the fleet hulls (16-tile cards); a row's parts are
## absolutely-placed children of the row node.
const TILE := PaletteLib.CHROME_TILE
## The catalog list block (content-node tiles): row *i* at `(0, i·row_h)` —
## a 3-tile row (identity line · stats · gray-note slot).
const CATALOG_LIST := "catalog"
const CATALOG_W := 27
const CATALOG_ROW_H := 3
## The fleet list block: one 16-tile hull card per fleet index.
const FLEET_LIST := "fleet"
const FLEET_W := 27
const FLEET_ROW_H := 16
## Catalog-row internals (row-local tiles): identity (name · role · price ·
## Buy) · stats · the gray-state note slot.
const CATALOG_NAME_RECT := Rect2i(0, 0, 12, 1)
const CATALOG_ROLE_RECT := Rect2i(12, 0, 4, 1)
const CATALOG_PRICE_RECT := Rect2i(16, 0, 6, 1)
const CATALOG_BUY_RECT := Rect2i(22, 0, 5, 2)
const CATALOG_STATS_RECT := Rect2i(0, 1, 27, 1)
const CATALOG_NOTE_RECT := Rect2i(0, 2, 27, 1)
## Hull-card internals (card-local tiles): identity + promote/sell ·
## durability bar/label/crew · repair picker · cannons picker · the two
## equipment slots.
const HULL_NAME_RECT := Rect2i(0, 0, 13, 1)
const HULL_PROMOTE_RECT := Rect2i(13, 0, 6, 1)
const HULL_SELL_RECT := Rect2i(19, 0, 6, 1)
const HULL_BAR_RECT := Rect2i(0, 2, 4, 1)
const HULL_DURABILITY_RECT := Rect2i(4, 2, 5, 1)
const HULL_CREW_RECT := Rect2i(9, 2, 6, 1)
const HULL_REPAIR_LABEL_RECT := Rect2i(0, 4, 5, 1)
const HULL_POINTS_RECT := Rect2i(5, 4, 2, 1)
const HULL_POINTS_STEP_RECT := Rect2i(7, 4, 2, 1)
const HULL_POINTS_STEP10_RECT := Rect2i(9, 4, 2, 1)
const HULL_POINTS_MAX_RECT := Rect2i(11, 4, 2, 1)
const HULL_PREVIEW_RECT := Rect2i(13, 4, 7, 1)
const HULL_REPAIR_RECT := Rect2i(20, 4, 5, 1)
const HULL_CANNONS_LABEL_RECT := Rect2i(0, 6, 5, 1)
const HULL_CANNONS_RECT := Rect2i(5, 6, 2, 1)
const HULL_CANNONS_MAX_RECT := Rect2i(7, 6, 2, 1)
const HULL_REFIT_RECT := Rect2i(9, 6, 4, 1)
const HULL_REFIT_NOTE_RECT := Rect2i(13, 6, 7, 1)
const HULL_REFIT_SELLBACK_RECT := Rect2i(20, 6, 7, 1)
## Equipment sub-rows (card-local, 4 tiles each at `y = 8 + slot·4`): the
## worn line over the buy list.
const EQUIP_SLOT_H := 4
const EQUIP_SLOT_RECT := Rect2i(0, 0, 4, 2)
const EQUIP_HERO_RECT := Rect2i(4, 0, 2, 2)
const EQUIP_WORN_RECT := Rect2i(6, 0, 12, 2)
const EQUIP_UNEQUIP_RECT := Rect2i(18, 0, 4, 2)
const EQUIP_BUY_W := 6
const EQUIP_BUY_STEP := 7

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
@onready var _header: Control = $header
@onready var _title: Label = $header/Title
@onready var _gold_label: Label = $header/Gold
@onready var _back_button: Button = $header/Back
@onready var _catalog_panel: Panel = $CatalogPanel
@onready var _catalog_title: Label = $CatalogPanel/CatalogTitle
@onready var _catalog_scroll: ScrollContainer = $CatalogPanel/CatalogScroll
@onready var _catalog_rows: Control = $CatalogPanel/CatalogScroll/CatalogRows
@onready var _fleet_panel: Panel = $FleetPanel
@onready var _fleet_title: Label = $FleetPanel/FleetTitle
@onready var _player_equip: Control = $FleetPanel/PlayerEquip
@onready var _player_equip_title: Label = $FleetPanel/PlayerEquip/PlayerEquipTitle
@onready var _player_equip_rows: Control = $FleetPanel/PlayerEquip/PlayerEquipRows
@onready var _fleet_scroll: ScrollContainer = $FleetPanel/FleetScroll
@onready var _fleet_rows: Control = $FleetPanel/FleetScroll/FleetRows
@onready var _confirm: Control = $ConfirmDialog


func _ready() -> void:
	# Full-scene S9 (80-* §4.2 amendment, 2026-11-02): a run can die on any
	# ledger tick ashore — the game-over screen must rise over the shipyard too.
	GameOverHostLib.attach_to(self)
	# Phase-10 sweep: label colors retire to the shared theme; the catalog and
	# fleet panels render the themed Panel chrome (the hand-built
	# boxes are gone; the scene file keeps the 32px title / 20px headings).
	_back_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_back_button.pressed.connect(go_back)

	# S6 keeps the §4.5 bars but not the sea viewport/minimap (same as S4).
	_hud.set_minimap_visible(false)
	_confirm.confirmed.connect(_on_sell_confirmed)
	_confirm.cancelled.connect(_on_sell_cancelled)

	# Phase 12 (§4.8.9): the authored tile rects — every static at its data
	# rect, the panels as plain Panels, before anything registers.
	_place_statics()
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
## stable hierarchical ids. The catalog/fleet hulls are list members —
## their ids carry the `list` flag (registered in the builders); the
## player's two equipment rows are fixed statics (registered in the
## builder). The shared HUD and confirm dialog are §4.8.9 fast-follows —
## not registered here.
func _register_static_ids() -> void:
	RegistryLib.register("shipyard", _background, "background",
		{"role": "panel"})
	RegistryLib.register("shipyard", _header, "header")
	RegistryLib.register("shipyard", _title, "header.title")
	RegistryLib.register("shipyard", _gold_label, "header.gold")
	RegistryLib.register("shipyard", _back_button, "header.back",
		{"role": "button"})
	RegistryLib.register("shipyard", _catalog_panel, "catalog_panel",
		{"role": "panel"})
	RegistryLib.register("shipyard", _catalog_title, "catalog_title")
	RegistryLib.register("shipyard", _catalog_scroll, "catalog_scroll")
	RegistryLib.register("shipyard", _fleet_panel, "fleet_panel",
		{"role": "panel"})
	RegistryLib.register("shipyard", _fleet_title, "fleet_title")
	RegistryLib.register("shipyard", _player_equip, "player_equip")
	RegistryLib.register("shipyard", _player_equip_title,
		"player_equip.title")
	RegistryLib.register("shipyard", _player_equip_rows, "player_equip.rows")
	RegistryLib.register("shipyard", _fleet_scroll, "fleet_scroll")


## Phase 12 (§4.8.9): one authored rect = one `position`/`size` write, in
## the DIRECT parent's tile space (point anchors everywhere; nothing is
## stretched).
func _place(control: Control, rect: Rect2i) -> void:
	control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	control.position = Vector2(rect.position) * float(TILE)
	control.size = Vector2(rect.size) * float(TILE)


## The authored tile table — today's captured look, flattened to the grid
## (see the fragment this screen's capture emits: `data/layout_fragments/
## shipyard.json`).
func _place_statics() -> void:
	_place(_header, Rect2i(1, 2, 58, 2))
	_place(_title, Rect2i(0, 0, 51, 1))
	_place(_gold_label, Rect2i(52, 1, 2, 1))
	_place(_back_button, Rect2i(54, 0, 4, 2))
	_place(_catalog_panel, Rect2i(1, 4, 29, 28))
	_place(_catalog_title, Rect2i(1, 1, 27, 1))
	_place(_catalog_scroll, Rect2i(1, 2, 27, 26))
	_place(_fleet_panel, Rect2i(30, 4, 29, 28))
	_place(_fleet_title, Rect2i(1, 1, 27, 1))
	_place(_player_equip, Rect2i(1, 2, 27, 9))
	_place(_player_equip_title, Rect2i(0, 0, 27, 1))
	_place(_player_equip_rows, Rect2i(0, 1, 27, 8))
	_place(_fleet_scroll, Rect2i(1, 11, 27, 16))


## Row *i*'s rect for a list block — px in the section's content-node space:
## the data block when managed, the same tiles authored otherwise.
func _list_row_rect(list_id: String, index: int) -> Rect2:
	var rect := RegistryLib.list_rect("shipyard", list_id, index)
	if rect != Rect2():
		return rect
	var w := CATALOG_W
	var row_h := CATALOG_ROW_H
	if list_id == FLEET_LIST:
		w = FLEET_W
		row_h = FLEET_ROW_H
	return Rect2(
		Vector2(0, index * row_h) * float(TILE),
		Vector2(w, row_h) * float(TILE))


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
	RegistryLib.apply_layout("shipyard")


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
## back to the full catalog so a standalone screen never renders empty. The
## rows are the catalog list block's members (`catalog`): row *i* takes its
## `list_rect` position inside the scroll's plain content node.
func _bind_catalog() -> void:
	_catalog_title.text = I18n.t_key("shipyard.catalog")
	_clear(_catalog_rows)
	_buy_buttons.clear()
	var index := 0
	for ship_type_id in ShipyardLib.shipyard_stock():
		_add_catalog_row(DataLoader.get_ship_type(ship_type_id), index)
		index += 1
	# The scroll's stacked extent: the plain content Control sized to the
	# rows' total pitch (viewport math, not flow).
	_catalog_rows.custom_minimum_size = Vector2(
		CATALOG_W * float(TILE), index * CATALOG_ROW_H * float(TILE))


func _add_catalog_row(ship_type: Dictionary, index: int) -> void:
	var ship_type_id := str(ship_type.get("id", ""))
	var port := _port_id()
	var state: String = ShipyardLib.row_state(port, ship_type_id)
	var note_text := _row_note_text(port, ship_type_id)
	# The row is a plain Control at the block's row rect; its parts are
	# absolutely-placed children (no per-row flow containers, §4.8.9).
	# §4.8: 32px table rows. Three tiles per entry (identity/price/action,
	# then the stats line, then the gray-state note slot) so the long
	# localised stat string can wrap instead of overflowing the half-width
	# catalog panel at 1920×1080.
	var card := Control.new()
	card.name = "Catalog_%s" % ship_type_id
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_catalog_rows.add_child(card)
	var rect := _list_row_rect(CATALOG_LIST, index)
	card.position = rect.position
	card.size = rect.size

	# §4.7.12 row states: available rows read the theme TEXT; gray rows the
	# `Dim` variation (the former per-screen PANEL_LINE override).
	var name_label := _label(I18n.t(ship_type.get("name", {})),
		state != ShipyardLib.ROW_AVAILABLE)
	name_label.name = "Name"
	name_label.tooltip_text = name_label.text
	card.add_child(name_label)
	_place(name_label, CATALOG_NAME_RECT)

	# 40-* §4.3.1: every row carries its role label (战舰/商船/沿岸 via
	# `shipyard.role.*`; the raw enum until the keys merge, never "<key>").
	var role_label := _label(_role_label(ship_type), true)
	role_label.name = "Role"
	role_label.tooltip_text = role_label.text
	card.add_child(role_label)
	_place(role_label, CATALOG_ROLE_RECT)

	var price := _label(
		I18n.fmt("shipyard.price", {"price": HudLib.format_thousands(
			ShipyardLib.buy_price(ship_type_id))})
	)
	price.name = "Price"
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	card.add_child(price)
	_place(price, CATALOG_PRICE_RECT)

	var buy := UiKitLib.button("shipyard.buy", "primary")
	buy.name = "Buy_%s" % ship_type_id
	var reason := ShipyardLib.buy_block_reason(ship_type_id)
	buy.disabled = not reason.is_empty()
	# §4.7: a disabled action states its reason as a tooltip; an enabled one
	# shows the price instead of a stale reason. A gray state renders the
	# 需发展度/同盟专营 note (falling back to the shared reason while the
	# note keys await their merge).
	buy.tooltip_text = _gate_tooltip(reason, note_text, price.text)
	buy.pressed.connect(_on_buy_pressed.bind(ship_type_id))
	card.add_child(buy)
	_place(buy, CATALOG_BUY_RECT)

	var stats := _label(_catalog_stats(ship_type), true)
	stats.name = "Stats"
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats.tooltip_text = _catalog_stats(ship_type)
	card.add_child(stats)
	_place(stats, CATALOG_STATS_RECT)

	if state != ShipyardLib.ROW_AVAILABLE and not note_text.is_empty():
		var note := _label(note_text, true)
		note.name = "Note"
		card.add_child(note)
		_place(note, CATALOG_NOTE_RECT)

	_buy_buttons[ship_type_id] = buy
	# Phase 12 (§4.8.9): one data-derived id per catalog ship row (a `catalog`
	# list member; the parts are unregistered — locked viewport blocks). The
	# stock-list order is the §4.3.1 data contract — locked like the market
	# rows.
	RegistryLib.register("shipyard", card, "rows.%s" % ship_type_id,
		{"data_ordered": true, "list": CATALOG_LIST})


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

## Own fleet, one hull card per fleet index in `fleet` order (flagship
## first), plus the player's own two equipment slots above the list
## (`60-*` §4.11.12). The hulls are the fleet list block's members (`fleet`):
## card *i* takes its `list_rect` position inside the scroll's plain content
## node.
func _bind_fleet() -> void:
	_fleet_title.text = I18n.t_key("fleet.title")
	_bind_player_equipment()
	_clear(_fleet_rows)
	_fleet_widgets.clear()
	var index := 0
	for ship in GameState.fleet:
		_add_fleet_row(index, ship)
		index += 1
	# The scroll's stacked extent: the plain content Control sized to the
	# cards' total pitch (viewport math, not flow).
	_fleet_rows.custom_minimum_size = Vector2(
		FLEET_W * float(TILE), index * FLEET_ROW_H * float(TILE))


## The player's `weapon` + `armor` rows (§4.7.2 "four slot rows … `weapon`,
## `armor` on the player").
func _bind_player_equipment() -> void:
	_player_equip_title.text = I18n.t_key(EQUIP_HEADING_KEY) \
		if DataLoader.ui_strings.has(EQUIP_HEADING_KEY) else ""
	_player_equip_title.visible = not _player_equip_title.text.is_empty()
	_clear(_player_equip_rows)
	_player_equip_widgets.clear()
	var slot_index := 0
	for slot in ShipyardLib.PLAYER_SLOTS:
		_player_equip_widgets[slot] = \
			_add_equipment_row(_player_equip_rows, slot, -1, slot_index)
		slot_index += 1


func _add_fleet_row(index: int, ship: Dictionary) -> void:
	var widgets: Dictionary = {"index": index, "sell": null, "promote": null,
		"repair": null, "refit": null, "refit_note": null, "points": null,
		"preview": null, "cannons": null, "refit_sellback": null, "equip": {}}

	# Phase 12 (§4.8.9): the hull card is a plain Control at the fleet
	# block's row rect (the kit frame's PanelContainer+VBox is gone); every
	# widget is an absolutely-placed child.
	var panel := Control.new()
	panel.name = "Fleet_%d" % index
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fleet_rows.add_child(panel)
	var card_rect := _list_row_rect(FLEET_LIST, index)
	panel.position = card_rect.position
	panel.size = card_rect.size
	# Phase-11 W3-B (docs/80-* §4.8.9): one id per hull card (a `fleet` list
	# member; the parts below are unregistered — locked viewport blocks).
	# The fleet order (flagship first, §4.4) is a game-state contract —
	# locked.
	RegistryLib.register("shipyard", panel, "fleet.%d" % index,
		{"role": "panel", "data_ordered": true, "list": FLEET_LIST})

	# --- line 1: identity + promote/sell -----------------------------------
	var name_label := _label(_ship_title(index, ship))
	name_label.name = "Name"
	panel.add_child(name_label)
	_place(name_label, HULL_NAME_RECT)

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
		panel.add_child(promote)
		_place(promote, HULL_PROMOTE_RECT)
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
		panel.add_child(sell)
		_place(sell, HULL_SELL_RECT)
		widgets["sell"] = sell

	# --- line 2: durability bar, durability, crew -------------------------
	var max_durability: int = ShipyardLib.ship_max_durability(index)
	var durability := int(ship.get("durability", 0))
	var bar := _durability_bar(durability, max_durability)
	panel.add_child(bar)
	_place(bar, HULL_BAR_RECT)

	var durability_label := _label(
		I18n.fmt("shipyard.durability", {
			"durability": "%d/%d" % [durability, max_durability],
		})
	)
	durability_label.name = "Durability"
	panel.add_child(durability_label)
	_place(durability_label, HULL_DURABILITY_RECT)

	var crew_label := _label(
		I18n.fmt("shipyard.crew_stat", {
			"crew": int(ship.get("crew", 0)),
			"max": FleetLib.ship_stat(ship, "crew_max"),
		}), true
	)
	crew_label.name = "Crew"
	panel.add_child(crew_label)
	_place(crew_label, HULL_CREW_RECT)

	# --- line 3: repair picker -------------------------------------------
	var repair_label := _label(I18n.t_key("shipyard.repair_points"))
	repair_label.name = "RepairLabel"
	panel.add_child(repair_label)
	_place(repair_label, HULL_REPAIR_LABEL_RECT)

	var points := LineEdit.new()
	points.name = "Points_%d" % index
	points.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	points.max_length = 3
	points.tooltip_text = repair_label.text
	# §4.7 numeric fields: digits only, live-clamped, empty = invalid.
	points.text_changed.connect(_on_points_changed.bind(index))
	panel.add_child(points)
	_place(points, HULL_POINTS_RECT)
	widgets["points"] = points

	var step_x := HULL_POINTS_STEP_RECT.position.x
	for step in PICKER_STEPS:
		var step_button := _row_button(str(step))
		step_button.name = "Points%s_%d" % [step, index]
		step_button.pressed.connect(_on_points_step_pressed.bind(index, step))
		panel.add_child(step_button)
		_place(step_button, Rect2i(step_x, HULL_POINTS_STEP_RECT.position.y,
			HULL_POINTS_STEP_RECT.size.x, HULL_POINTS_STEP_RECT.size.y))
		step_x += HULL_POINTS_STEP_RECT.size.x

	var max_button := _row_button(_fmt_or(MAX_KEY, {}, MAX_FALLBACK_KEY))
	max_button.name = "PointsMax_%d" % index
	max_button.pressed.connect(_on_points_step_pressed.bind(index, -1))
	panel.add_child(max_button)
	_place(max_button, HULL_POINTS_MAX_RECT)

	var preview := _label("", true)
	preview.name = "Preview"
	panel.add_child(preview)
	_place(preview, HULL_PREVIEW_RECT)
	widgets["preview"] = preview

	var repair := _row_button(I18n.t_key("shipyard.repair"))
	repair.name = "Repair_%d" % index
	repair.pressed.connect(_on_repair_pressed.bind(index))
	panel.add_child(repair)
	_place(repair, HULL_REPAIR_RECT)
	widgets["repair"] = repair

	# --- line 4: cannons picker (Phase 2, `80-*` §4.7.2) -------------------
	# Numeric picker 0 … `max_refit` at 100g/cannon with the 50g sell-back
	# shown for the current count. Every number comes from the engine.
	var cannons_label := _label(
		_fmt_or(CANNONS_LABEL_KEY, {}, CANNONS_LABEL_FALLBACK_KEY)
	)
	cannons_label.name = "CannonsLabel"
	panel.add_child(cannons_label)
	_place(cannons_label, HULL_CANNONS_LABEL_RECT)

	var cannons_field := LineEdit.new()
	cannons_field.name = "Cannons_%d" % index
	cannons_field.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cannons_field.max_length = 3
	cannons_field.tooltip_text = cannons_label.text
	# §4.7 numeric fields: digits only, live-clamped, empty = invalid.
	cannons_field.text_changed.connect(_on_cannons_changed.bind(index))
	panel.add_child(cannons_field)
	_place(cannons_field, HULL_CANNONS_RECT)
	widgets["cannons"] = cannons_field

	var cannons_max := _row_button(_fmt_or(MAX_KEY, {}, MAX_FALLBACK_KEY))
	cannons_max.name = "CannonsMax_%d" % index
	cannons_max.pressed.connect(_on_cannons_max_pressed.bind(index))
	panel.add_child(cannons_max)
	_place(cannons_max, HULL_CANNONS_MAX_RECT)

	var refit := _row_button(I18n.t_key("shipyard.refit"))
	refit.name = "Refit_%d" % index
	refit.pressed.connect(_on_refit_pressed.bind(index))
	panel.add_child(refit)
	_place(refit, HULL_REFIT_RECT)
	widgets["refit"] = refit

	# Two notes: live cost preview (left) and the sell-back of the
	# cannons already aboard (right), as §4.7.2 asks.
	var refit_note := _label("", true)
	refit_note.name = "RefitNote_%d" % index
	panel.add_child(refit_note)
	_place(refit_note, HULL_REFIT_NOTE_RECT)
	widgets["refit_note"] = refit_note

	var sellback_note := _label("", true)
	sellback_note.name = "RefitSellback_%d" % index
	panel.add_child(sellback_note)
	_place(sellback_note, HULL_REFIT_SELLBACK_RECT)
	widgets["refit_sellback"] = sellback_note

	# --- lines 5+: ship equipment slots (`figurehead`, `sail`) -------------
	# `60-*` §4.11.12: the ship slots live on this hull. Each row is built by
	# the same helper as the player's `weapon`/`armor` rows, so both owners
	# render identically (§4.7.2).
	widgets["equip"] = {}
	var slot_index := 0
	for slot in ShipyardLib.SHIP_SLOTS:
		(widgets["equip"] as Dictionary)[slot] = \
			_add_equipment_row(panel, slot, index, slot_index)
		slot_index += 1

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

## Builds one equipment row under `parent` (the player-equip group for the
## player's own slots, the hull card for a hull's slots) and returns its
## widget dict: "{Slot} · <worn item or ui.empty>" plus every item of that
## slot as a buy button (price on the label, disabled reason as the tooltip)
## and Unequip when something is worn (`80-*` §4.7.2).
##
## `ship_index < 0` means the player's own slots (`weapon`/`armor`).
## `slot_index` places the row inside its owner (the authored equip slot
## band). The dict is `{slot, row, heading, worn, buy (id → Button),
## unequip}`.
func _add_equipment_row(parent: Node, slot: String, ship_index: int,
		slot_index: int) -> Dictionary:
	var id_prefix := "equip.player" if ship_index < 0 \
		else "fleet.%d.equip" % ship_index
	# The row is a plain Control at its authored band inside the owner (two
	# lines: the worn line over the buy list — §4.8 32px rows, half-width
	# panel: "<name> <price>" buttons for the slot's items never fit beside
	# those labels at 1920×1080).
	var card := Control.new()
	card.name = "Equip_%s_%s" % [slot, "player" if ship_index < 0 else str(ship_index)]
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(card)
	var band := Rect2i(0, slot_index * EQUIP_SLOT_H, EQUIP_SLOT_H * 7,
		EQUIP_SLOT_H)
	if ship_index < 0:
		# The player's two rows sit in the player-equip group (registered
		# statics, fixed slot ids).
		band = Rect2i(0, slot_index * EQUIP_SLOT_H, 27, EQUIP_SLOT_H)
		RegistryLib.register("shipyard", card, "%s.%s" % [id_prefix, slot],
			{"data_ordered": true})
	card.position = Vector2(band.position) * float(TILE)
	card.size = Vector2(band.size) * float(TILE)

	var worn_id := _worn_equipment(slot, ship_index)
	var heading := _label(_slot_label(slot))
	heading.name = "Slot"
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	card.add_child(heading)
	_place(heading, EQUIP_SLOT_RECT)

	# The §4.8 hero-64 host (2026-11-08): the worn item at 1:1 64 through
	# the `icon64_eq_` lazy id — an absent id hides the slot (the flat
	# fallback); the 32px buy buttons below stay untouched.
	var hero := TextureRect.new()
	hero.name = "WornHero"
	hero.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hero.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	if not worn_id.is_empty():
		hero.texture = UiKitLib.icon_texture("icon64_eq_%s" % worn_id)
	hero.visible = hero.texture != null
	hero.tooltip_text = _equipment_name(worn_id)
	card.add_child(hero)
	_place(hero, EQUIP_HERO_RECT)

	var worn := _label(
		_equipment_name(worn_id) if not worn_id.is_empty() else I18n.t_key("ui.empty"),
		worn_id.is_empty()
	)
	worn.name = "ItemName"
	worn.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	worn.tooltip_text = worn.text
	card.add_child(worn)
	_place(worn, EQUIP_WORN_RECT)

	var unequip := _row_button(_fmt_or(UNEQUIP_KEY, {}, UNEQUIP_FALLBACK_KEY))
	unequip.name = "Unequip_%s_%s" % [slot,
		"player" if ship_index < 0 else str(ship_index)]
	unequip.disabled = worn_id.is_empty()
	unequip.tooltip_text = _reason_text("ui.not_available") \
		if worn_id.is_empty() else unequip.text
	unequip.pressed.connect(_on_unequip_pressed.bind(slot, ship_index))
	card.add_child(unequip)
	_place(unequip, EQUIP_UNEQUIP_RECT)

	var buttons: Dictionary = {}
	var port := _port_id()
	var buy_index := 0
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
		# Phase 7 (80-* §4.7.12): the same three row states as the hull rows —
		# the gray-state note as the tooltip, the engine reason otherwise.
		var note_text := _row_note_text(port, equipment_id)
		var reason := ShipyardLib.equip_block_reason(slot, equipment_id, ship_index)
		buy.disabled = not reason.is_empty()
		buy.tooltip_text = _gate_tooltip(reason, note_text,
			_equipment_tooltip(slot, equipment_id))
		buy.pressed.connect(_on_equip_pressed.bind(slot, equipment_id, ship_index))
		card.add_child(buy)
		_place(buy, Rect2i(buy_index * EQUIP_BUY_STEP, EQUIP_SLOT_H - 2,
			EQUIP_BUY_W, 2))
		buy_index += 1
		buttons[equipment_id] = buy
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
