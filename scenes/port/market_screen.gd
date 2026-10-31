extends Control
## Market screen (S5) — docs/30-PORTS-AND-TRADE.md §4.2–§4.5, §4.7 (wireframe),
## §6 (edge cases); docs/80-UI-UX.md §4.5 (HUD bars), §4.7 (numeric entry,
## toasts), §4.8 (palette, 32px rows, 40px buttons, 8px grid).
##
## Everything the screen shows comes from data:
##   * the goods table iterates [method TradeEngine.goods_rows] (every entry of
##     `data/goods.json`, sorted by `base_price`), so a 21st good is a
##     data-only change — there is no per-good code anywhere in this file;
##   * prices, quantity ceilings and trade side effects are the
##     `trade_engine.gd` formulas, never duplicated here;
##   * the stock / trend / marginal-price columns read `economy.gd`
##     directly (docs/80 §4.7.7) — stock 0–200, the ▲/▼ drift glyph
##     against the effective rest, and the next-tranche price.
##
## **The market sells trade goods only** (docs/20-* §4.10 as amended, docs/80-*
## §4.6.1): provisions and water are survival, not commerce, and are bought at
## the Set-Sail provisioning prompt (`scenes/port/provisions_dialog.tscn`) — the
## single supply purchase point. The supplies row that used to live here was
## removed with the prompt's introduction; `market.provisions` / `market.water`
## / `market.supplies` are no longer reachable from this screen (see the task
## report for the key inventory).
##
## The screen holds no state of its own beyond the per-row quantity field: on
## every `gold_changed` / `fleet_changed` the rows are re-read, so a trade
## updates prices, "You have", the quantity ceiling and the button states
## immediately (the HUD-bar signal contract applies to the HUD, not to this
## screen's own table).
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterPanelLib := preload("res://scenes/ui_shared/character_panel.gd")
## Task L (docs/80-* §4.7.8): the "merchant captains in port" rows.
const NpcIntelLib := preload("res://scripts/world/npc_intel.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
## docs/80 §4.7: toasts are transient (2.5s).
const TOAST_SECONDS := 2.5
## Quantity presets, in the §4.4 order 1 / 10 / 100 (+ Max).
const QTY_PRESETS: Array[int] = [1, 10, 100]
## Widths of the table's fixed columns (docs/80 §4.8 8px grid). The quantity
## picker is the numeric field plus the four preset buttons. Phase 5 adds
## the stock / trend / marginal-price columns (docs/80 §4.7.7): the old
## buy/sell price cell **is** the marginal (next-tranche) price now that
## every trade reprices per 10-unit tranche (docs/30 §4.4), so the price
## column shows it under the `market.stock.marginal` caption.
const COL_NAME_W := 160
const COL_STOCK_W := 56
const COL_TREND_W := 96
const COL_MARGINAL_W := 132
const COL_HAVE_W := 70
const COL_QTY_W := 72
const COL_PRESET_W := 40
const COL_MAX_W := 56
const COL_BUTTON_W := 88
const COL_QTY_TOTAL_W := COL_QTY_W + 3 * COL_PRESET_W + COL_MAX_W

## Emitted right before the S5 → S4 route (tests observe it instead of swapping
## their own scene root, the `port_screen.gd` convention).
signal went_back
## Emitted after a successful trade: `"buy"` / `"sell"` / `"invest"`, with the
## good id ("" for investment) and the quantity. The `"supplies"` kind is gone
## with the supplies row (docs/20-* §4.10: supplies are not a market good).
signal traded(kind: String, good_id: String, qty: int)

@onready var _background: ColorRect = $Background
@onready var _title: Label = $Layout/VBox/Header/Title
@onready var _gold: Label = $Layout/VBox/Header/Gold
@onready var _hold: Label = $Layout/VBox/Header/Hold
@onready var _back_button: Button = $Layout/VBox/Header/Back
@onready var _table_frame: PanelContainer = $Layout/VBox/TableFrame
@onready var _column_header: HBoxContainer = \
	$Layout/VBox/TableFrame/Margin/Table/ColumnHeader
@onready var _goods_scroll: ScrollContainer = \
	$Layout/VBox/TableFrame/Margin/Table/GoodsScroll
@onready var _goods_rows: VBoxContainer = \
	$Layout/VBox/TableFrame/Margin/Table/GoodsScroll/GoodsRows
@onready var _invest_button: Button = $Layout/VBox/Footer/Invest
@onready var _invest_status: Label = $Layout/VBox/Footer/InvestStatus
@onready var _toast: Label = $Toast

## Routing switch for headless tests (the `GameState.new_game(..., route)`
## convention): with `false`, [method go_back] runs the whole transition and
## emits [signal went_back] but does not replace the scene.
var route_to_port: bool = true

## Port currently docked at ("" when the scene is opened standalone).
var _port_id: String = ""
## Per-good widget references, `{good_id: {name, price, have, qty, qty_buttons,
## buy, sell}}`, in the table's display order.
var _rows: Dictionary = {}
## True while a `text_changed` handler rewrites its own LineEdit, so the
## rewrite does not re-enter the sanitiser.
var _sanitizing := false
## Toast generation so a replaced toast does not hide its successor.
var _toast_generation := 0
## Gold-flash tween (created/destroyed by [_flash_gold]).
var _gold_tween: Tween = null
## Task L (§4.7.8): the "merchant captains in port" section (code-built under
## the trade table; the scene file stays untouched) — header + row labels.
var _captains_header: Label = null
var _captains_box: VBoxContainer = null
## The captain rows currently rendered (`{id, name, role, nation_id}`).
var _captain_rows: Array = []


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	for label in [_title, _gold, _hold, _invest_status, _toast]:
		label.add_theme_color_override("font_color", PaletteLib.TEXT)
	_title.add_theme_font_size_override("font_size", 32)
	_invest_status.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
	_table_frame.add_theme_stylebox_override("panel", _panel_style())
	_back_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_invest_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_back_button.pressed.connect(go_back)
	_invest_button.pressed.connect(_on_invest_pressed)
	_toast.visible = false
	_goods_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_goods_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_port_id = _read_current_port()
	_build()
	_bind()
	_refresh()
	_build_captains_section()
	_refresh_captains()

	# S14 over S5, the same modal the port hub offers (docs/80 §4.3).
	CharacterPanelLib.attach_to(self)

	EventBus.locale_changed.connect(_on_locale_changed)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.fleet_changed.connect(_on_fleet_changed)
	# docs/30 §4.4: a stock-moving trade (or the daily economy step at this
	# port) moves the stock/trend/marginal cells immediately.
	EventBus.market_changed.connect(_on_market_changed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		if has_modal():
			return
		get_viewport().set_input_as_handled()
		go_back()
		return


## True while a modal is up (the S14 panel, or a dialog another screen left in
## the `modal_overlay` group): Back/Esc must not route underneath it
## (docs/80 §6 "modals consume all input").
func has_modal() -> bool:
	for node in get_tree().get_nodes_in_group("modal_overlay"):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			return true
	var panel := get_node_or_null("CharacterPanel")
	return panel != null and panel.has_method("is_open") and panel.is_open()


# --- Public API (tests + the port hub) -------------------------------------

func port_id() -> String:
	return _port_id


## The goods table's rows, in display order (docs/30 §4.7: `base_price` asc).
func row_goods_ids() -> Array:
	return _rows.keys()


## Widget bundle for one good (`{}` when it has no row).
func row(good_id: String) -> Dictionary:
	return _rows.get(good_id, {})


## Quantity currently typed in a good's row, or -1 when the field is empty
## (docs/80 §4.7: "empty = invalid").
func row_qty(good_id: String) -> int:
	var row_refs: Dictionary = _rows.get(good_id, {})
	if row_refs.is_empty():
		return -1
	return _parse_qty((row_refs["qty"] as LineEdit).text)


## Types a raw string into a good's quantity field through the same handler a
## user's keystroke runs (digits-only filter + live clamp).
func type_qty(good_id: String, text: String) -> void:
	var row_refs: Dictionary = _rows.get(good_id, {})
	if row_refs.is_empty():
		return
	var field: LineEdit = row_refs["qty"]
	# Programmatic assignment does not emit `text_changed`; running the handler
	# directly is what a keystroke does, and it rewrites the field to the
	# sanitised/clamped value.
	field.text = text
	_on_qty_changed(good_id, text)


## Presses one of the row's preset buttons (`1`, `10`, `100`, `max`).
func press_qty_preset(good_id: String, preset: String) -> void:
	var row_refs: Dictionary = _rows.get(good_id, {})
	if row_refs.is_empty():
		return
	var buttons: Dictionary = row_refs["qty_buttons"]
	var button: Button = buttons.get(preset, null)
	if button != null and not button.disabled:
		button.pressed.emit()


## Clicks a row's Buy / Sell button (no-op when it is disabled, exactly like a
## real click — the tests use this to prove the disabled state is protective).
func press_buy(good_id: String) -> bool:
	var row_refs: Dictionary = _rows.get(good_id, {})
	if row_refs.is_empty():
		return false
	var button: Button = row_refs["buy"]
	if button.disabled:
		return false
	button.pressed.emit()
	return true


func press_sell(good_id: String) -> bool:
	var row_refs: Dictionary = _rows.get(good_id, {})
	if row_refs.is_empty():
		return false
	var button: Button = row_refs["sell"]
	if button.disabled:
		return false
	button.pressed.emit()
	return true


func press_invest() -> bool:
	if _invest_button.disabled:
		return false
	_invest_button.pressed.emit()
	return true


## Re-reads prices, holdings, ceilings and button states. Called on open and
## from `gold_changed` / `fleet_changed`; never rebuilds the rows, so a typed
## quantity and the field's focus survive a refresh.
func refresh() -> void:
	_refresh()


## Back / Esc (docs/80 §4.2 "S4 ← S5"): route to the port hub, which re-reads
## `GameState.current_port` on its own.
func go_back() -> void:
	went_back.emit()
	if route_to_port:
		GameState.change_scene(PORT_SCENE)


# --- Construction ----------------------------------------------------------

## Builds the fixed column header and one row per good in `goods.json`. Called
## once from `_ready`; a locale change only re-binds the labels ([method _bind])
## because no row content changes with locale. There is **no** supplies row:
## provisions and water are bought in the Set-Sail prompt (docs/20-* §4.10).
func _build() -> void:
	_build_column_header()
	for child in _goods_rows.get_children():
		_goods_rows.remove_child(child)
		child.queue_free()
	_rows.clear()
	for good in TradeEngineLib.goods_rows():
		var good_id := str(good.get("id", ""))
		if good_id.is_empty():
			continue
		_rows[good_id] = _build_good_row(good_id)


func _build_column_header() -> void:
	for child in _column_header.get_children():
		_column_header.remove_child(child)
		child.queue_free()
	# [node-name suffix, ui_strings key, width, alignment] — the keys are the
	# §4.7.9 captions (`market.` + key); node names stay dot-free.
	for spec in [
		["good", "good", COL_NAME_W, HORIZONTAL_ALIGNMENT_LEFT],
		["stock", "stock.header", COL_STOCK_W, HORIZONTAL_ALIGNMENT_RIGHT],
		["trend", "stock.trend", COL_TREND_W, HORIZONTAL_ALIGNMENT_LEFT],
		["marginal", "stock.marginal", COL_MARGINAL_W,
				HORIZONTAL_ALIGNMENT_RIGHT],
		["you_have", "you_have", COL_HAVE_W, HORIZONTAL_ALIGNMENT_RIGHT],
		["qty", "qty", COL_QTY_TOTAL_W, HORIZONTAL_ALIGNMENT_CENTER],
	]:
		var label := Label.new()
		label.name = "Col_%s" % str(spec[0])
		label.set_meta("text_key", "market.%s" % str(spec[1]))
		label.custom_minimum_size = Vector2(float(spec[2]), float(PaletteLib.ROW_H))
		label.horizontal_alignment = int(spec[3])
		label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
		_column_header.add_child(label)
	# Buy + Sell column caption, split over the two button widths.
	for key in ["buy", "sell"]:
		var label := Label.new()
		label.name = "Col_%s" % key
		label.set_meta("text_key", "market.%s" % key)
		label.custom_minimum_size = Vector2(float(COL_BUTTON_W), float(PaletteLib.ROW_H))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
		_column_header.add_child(label)


## One table row: Good | Stock | Trend | Marginal | You have | Qty picker |
## [Buy][Sell] (docs/30 §4.8 + docs/80 §4.7.7). Every widget's text is
## filled later by [method _refresh].
func _build_good_row(good_id: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % good_id
	row.custom_minimum_size = Vector2(0, float(PaletteLib.ROW_H))
	row.add_theme_constant_override("separation", PaletteLib.BASE_UNIT)
	row.set_meta("good_id", good_id)

	var name_label := Label.new()
	name_label.name = "Name"
	name_label.custom_minimum_size.x = float(COL_NAME_W)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_color_override("font_color", PaletteLib.TEXT)

	var stock_label := Label.new()
	stock_label.name = "Stock"
	stock_label.custom_minimum_size.x = float(COL_STOCK_W)
	stock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stock_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	stock_label.add_theme_color_override("font_color", PaletteLib.TEXT)

	# §4.7.7: one drift glyph — ▲ refilling (stock under rest, GOOD) or
	# ▼ draining (stock over rest, BAD); blank at rest. No forecast shown.
	var trend_label := Label.new()
	trend_label.name = "Trend"
	trend_label.custom_minimum_size.x = float(COL_TREND_W)
	trend_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	var marginal_label := Label.new()
	marginal_label.name = "Marginal"
	marginal_label.custom_minimum_size.x = float(COL_MARGINAL_W)
	marginal_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	marginal_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	marginal_label.add_theme_color_override("font_color", PaletteLib.TEXT)

	var have_label := Label.new()
	have_label.name = "Have"
	have_label.custom_minimum_size.x = float(COL_HAVE_W)
	have_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	have_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	have_label.add_theme_color_override("font_color", PaletteLib.TEXT)

	# Quantity picker (docs/30 §4.4): 1 / 10 / 100 / Max buttons plus direct
	# numeric entry (digits only, live-clamped, empty = invalid).
	var qty_box := HBoxContainer.new()
	qty_box.name = "QtyPicker"
	qty_box.add_theme_constant_override("separation", 4)
	var qty_field := LineEdit.new()
	qty_field.name = "Qty"
	qty_field.custom_minimum_size = Vector2(float(COL_QTY_W), float(PaletteLib.ROW_H))
	qty_field.max_length = 6
	qty_field.placeholder_text = "0"
	qty_box.add_child(qty_field)
	var qty_buttons: Dictionary = {}
	for preset in QTY_PRESETS:
		var button := _make_row_button("Qty%d" % preset, str(preset), COL_PRESET_W)
		button.pressed.connect(_on_qty_preset.bind(good_id, preset))
		qty_box.add_child(button)
		qty_buttons[str(preset)] = button
	var max_button := _make_row_button("QtyMax", I18n.t_key("market.max"), COL_MAX_W)
	max_button.pressed.connect(_on_qty_preset.bind(good_id, -1))
	qty_box.add_child(max_button)
	qty_buttons["max"] = max_button

	var buy_button := _make_row_button("Buy", "", COL_BUTTON_W)
	buy_button.pressed.connect(_on_buy.bind(good_id))
	var sell_button := _make_row_button("Sell", "", COL_BUTTON_W)
	sell_button.pressed.connect(_on_sell.bind(good_id))

	row.add_child(name_label)
	row.add_child(stock_label)
	row.add_child(trend_label)
	row.add_child(marginal_label)
	row.add_child(have_label)
	row.add_child(qty_box)
	row.add_child(buy_button)
	row.add_child(sell_button)
	_goods_rows.add_child(row)

	qty_field.text_changed.connect(_on_qty_text_changed.bind(good_id))
	return {
		"node": row,
		"name": name_label,
		"stock": stock_label,
		"trend": trend_label,
		"marginal": marginal_label,
		"have": have_label,
		"qty": qty_field,
		"qty_buttons": qty_buttons,
		"buy": buy_button,
		"sell": sell_button,
	}


func _make_row_button(node_name: String, text: String, width: int) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(float(width), float(PaletteLib.ROW_H))
	button.focus_mode = Control.FOCUS_ALL
	return button


# --- Binding ---------------------------------------------------------------

func _read_current_port() -> String:
	var value = GameState.current_port
	if value is String and not (value as String).is_empty():
		return value
	return ""


## Localised, state-independent labels: the header, the column captions, the
## buttons and every good/supply name. Cheap enough to re-run on a locale
## change (20 goods rows).
func _bind() -> void:
	var port: Dictionary = DataLoader.get_port(_port_id)
	var port_name := I18n.t(port.get("name", {})) if not port.is_empty() else "-"
	_title.text = I18n.fmt("market.title", {"port": port_name})
	_back_button.text = I18n.t_key("ui.back")
	_invest_button.text = I18n.fmt(
		"market.invest", {"amount": TradeEngineLib.INVEST_CHUNK}
	)
	for child in _column_header.get_children():
		if child.has_meta("text_key"):
			(child as Label).text = I18n.t_key(str(child.get_meta("text_key")))
	for good_id in _rows:
		var refs: Dictionary = _rows[good_id]
		var good: Dictionary = DataLoader.get_good(good_id)
		(refs["name"] as Label).text = I18n.t(good.get("name", {}))
		(refs["buy"] as Button).text = I18n.t_key("market.buy")
		(refs["sell"] as Button).text = I18n.t_key("market.sell")
		((refs["qty_buttons"] as Dictionary)["max"] as Button).text = \
			I18n.t_key("market.max")


# --- Refresh ---------------------------------------------------------------

func _refresh() -> void:
	# Task L: a save loaded straight into port re-applies the active demand
	# events' rest-overrides before any trend cell reads them (the table is
	# transient; the saved instances are the truth — docs/30-* §4.5).
	EconomyLib.ensure_event_overrides()
	_refresh_header()
	_refresh_rows()
	_refresh_investment()
	_refresh_captains()


func _refresh_header() -> void:
	_gold.text = I18n.fmt(
		"ui.gold_amount", {"gold": format_thousands(GameState.gold)}
	)
	# "Hold 34/120" is the same figure the HUD bottom bar shows, from the same
	# key (`world.cargo`), so the two can never disagree.
	_hold.text = I18n.fmt("world.cargo", {
		"amount": TradeEngineLib.hold_used(),
		"capacity": TradeEngineLib.hold_capacity(),
	})


func _refresh_rows() -> void:
	for good_id in _rows:
		var refs: Dictionary = _rows[good_id]
		# The marginal (next-tranche) price: what the *next* 10 units would
		# cost or fetch at the current stock — the first tranche's realized
		# price, never an average (docs/30 §4.4, docs/80 §4.7.7).
		var buy := TradeEngineLib.buy_price(_port_id, good_id)
		var sell := TradeEngineLib.sell_price(_port_id, good_id)
		(refs["marginal"] as Label).text = "%s / %s" % [
			I18n.fmt("ui.gold_amount", {"gold": format_thousands(buy)}),
			I18n.fmt("ui.gold_amount", {"gold": format_thousands(sell)}),
		]
		_refresh_stock_cells(good_id, refs)
		(refs["have"] as Label).text = str(FleetLib.held(good_id))
		_apply_row_limits(good_id)


## Stock cell (0–200) and the one-glyph trend against the **effective**
## rest (override-aware, docs/30 §4.5): ▲ refilling below rest, ▼ draining
## above it, blank exactly at rest (docs/80 §4.7.7 — no forecast).
func _refresh_stock_cells(good_id: String, refs: Dictionary) -> void:
	var stock_label: Label = refs["stock"]
	var trend_label: Label = refs["trend"]
	if _port_id.is_empty():
		stock_label.text = "-"
		trend_label.text = ""
		return
	var stock := EconomyLib.stock_of(_port_id, good_id)
	var rest := EconomyLib.effective_rest(_port_id, good_id)
	stock_label.text = str(stock)
	if stock < rest:
		trend_label.text = I18n.t_key("market.stock.trend_up")
		trend_label.add_theme_color_override("font_color", PaletteLib.GOOD)
	elif stock > rest:
		trend_label.text = I18n.t_key("market.stock.trend_down")
		trend_label.add_theme_color_override("font_color", PaletteLib.BAD)
	else:
		trend_label.text = ""


## Re-applies the quantity ceiling and the §4.7/§6 disabled-with-reason rules
## without touching a still-valid typed quantity.
##
## **Clamp vs reason.** The typed field is live-clamped to the *physical* range
## (the pooled hold, or the held quantity when the hold is full), not to the
## purse: gold is reported as a disabled-button reason (`market.no_gold` /
## `market.not_enough_gold`) rather than silently rewriting what the player
## typed. Clamping to `buy_max` would make the "unaffordable" reason
## unreachable — every entry would collapse to 0 first. The presets use the
## same range, and each button then validates against its own maximum
## (docs/30 §4.4).
func _apply_row_limits(good_id: String) -> void:
	var refs: Dictionary = _rows[good_id]
	var buy_max := TradeEngineLib.buy_max(_port_id, good_id) if not _port_id.is_empty() else 0
	var held := TradeEngineLib.sell_max(good_id)
	var field: LineEdit = refs["qty"]
	# One picker serves both buttons (docs/30 §4.4), so its ceiling is the
	# larger of what can be bought and what is held: a full hold must still be
	# sellable, and an empty row must cap at `buy_max`.
	var ceiling := maxi(_qty_ceiling(held), buy_max)
	for key in refs["qty_buttons"]:
		var preset_button: Button = (refs["qty_buttons"] as Dictionary)[key]
		preset_button.disabled = ceiling <= 0
	_clamp_field(field, ceiling)
	var qty := _parse_qty(field.text)

	var buy_button: Button = refs["buy"]
	var buy_reason := _buy_reason(good_id, qty, buy_max)
	_set_button_state(buy_button, buy_reason.is_empty(), buy_reason)

	var sell_button: Button = refs["sell"]
	var sell_reason := _sell_reason(good_id, qty, held)
	_set_button_state(sell_button, sell_reason.is_empty(), sell_reason)


## Physical ceiling of a goods row's quantity field: the pooled free hold plus
## whatever of the good is already aboard (so a full hold can still be sold).
func _qty_ceiling(held: int) -> int:
	if _port_id.is_empty():
		return 0
	return maxi(FleetLib.fleet_free(), held)


## Why a Buy would fail, as a localised reason ("" = allowed). The order makes
## every §6 reason reachable: a full hold first, then the empty quantity, then
## the purse, then the capacity (a quantity larger than `fleet_free`).
func _buy_reason(good_id: String, qty: int, buy_max: int) -> String:
	if _port_id.is_empty():
		return I18n.t_key("market.invalid_qty")
	if FleetLib.fleet_free() <= 0:
		return I18n.t_key("market.hold_full")
	if qty <= 0:
		return I18n.t_key("market.invalid_qty")
	var price := TradeEngineLib.buy_price(_port_id, good_id)
	# The §4.4 walked total, not price × qty: a multi-tranche purchase
	# costs more than the marginal price suggests, and the reason must say
	# what the full walk would actually cost.
	var cost := TradeEngineLib.buy_cost(_port_id, good_id, qty)
	if GameState.gold < cost:
		if GameState.gold < price:
			return I18n.t_key("market.no_gold")
		return I18n.fmt("market.not_enough_gold", {"gold": cost})
	if qty > buy_max:
		# Gold is not the limit here, so capacity is (docs/30 §4.4).
		return I18n.t_key("market.hold_full")
	return ""


## Why a Sell would fail ("" = allowed). Sell max is the held quantity, so an
## empty row and an over-held quantity are both an invalid quantity.
func _sell_reason(_good_id: String, qty: int, held: int) -> String:
	if _port_id.is_empty() or held <= 0:
		return I18n.t_key("market.invalid_qty")
	if qty <= 0 or qty > held:
		return I18n.t_key("market.invalid_qty")
	return ""


func _set_button_state(button: Button, enabled: bool, reason: String) -> void:
	button.disabled = not enabled
	button.tooltip_text = reason


func _refresh_investment() -> void:
	var invested := TradeEngineLib.invested(_port_id)
	var percent := TradeEngineLib.investment_percent(_port_id)
	_invest_status.text = I18n.fmt("market.invested_here", {
		"gold": format_thousands(invested),
		"count": percent,
	})
	var at_cap := invested >= TradeEngineLib.INVEST_CAP_GOLD
	var can := TradeEngineLib.can_invest(_port_id)
	_invest_button.disabled = not can
	if at_cap:
		_invest_button.tooltip_text = I18n.fmt("market.invest_cap", {
			"max": int(round(TradeEngineLib.DISCOUNT_CAP * 100.0)),
		})
	elif not can:
		_invest_button.tooltip_text = I18n.t_key("market.no_gold")
	else:
		_invest_button.tooltip_text = ""


# --- Merchant captains in port (docs/80-* §4.7.8, task L) -------------------

## The captain rows currently rendered (`{id, name, role, nation_id}`, the
## test seam — no widget reach-in needed).
func captain_rows() -> Array:
	return _captain_rows.duplicate()


## Builds the section shell once (header + rows box) under the trade table.
func _build_captains_section() -> void:
	var layout: VBoxContainer = $Layout/VBox
	_captains_header = Label.new()
	_captains_header.name = "CaptainsHeader"
	_captains_header.add_theme_color_override("font_color", PaletteLib.ACCENT)
	layout.add_child(_captains_header)
	_captains_box = VBoxContainer.new()
	_captains_box.name = "CaptainsRows"
	_captains_box.add_theme_constant_override("separation", 2)
	layout.add_child(_captains_box)


## Re-reads the docked traders sighted at this port's market (the seeded
## 60/40 + 75% rolls live in `npc_intel.gd`; this only renders).
func _refresh_captains() -> void:
	if _captains_box == null:
		return
	for child in _captains_box.get_children():
		_captains_box.remove_child(child)
		child.queue_free()
	_captain_rows = []
	if _port_id.is_empty() or GameState.player.is_empty():
		_captains_header.visible = false
		return
	_captains_header.visible = true
	_captains_header.text = I18n.t_key("captain.section.market")
	for entry in NpcIntelLib.sightings(_port_id, NpcIntelLib.FACILITY_MARKET):
		var role := str(entry.get("role", ""))
		if role != "trader" and role != "treasure":
			continue
		_captain_rows.append({
			"id": str(entry.get("id", "")),
			"name": str(entry.get("name", "")),
			"role": role,
			"nation_id": str(entry.get("nation_id", "")),
		})
	if _captain_rows.is_empty():
		var empty := Label.new()
		empty.name = "Empty"
		empty.text = "-"
		empty.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
		_captains_box.add_child(empty)
		return
	for entry in _captain_rows:
		var row := Label.new()
		row.name = "Captain_%s" % str(entry["id"])
		row.text = "%s · %s" % [str(entry["name"]),
			I18n.t_key("captain.role.%s" % str(entry["role"]))]
		row.add_theme_color_override("font_color", PaletteLib.TEXT)
		_captains_box.add_child(row)


# --- Interaction -----------------------------------------------------------

## Direct numeric entry (docs/80 §4.7): digits only, live-clamped to the row's
## ceiling, empty = invalid (the dependent buttons are disabled, no dialog).
func _on_qty_text_changed(_text: String, good_id: String) -> void:
	_on_qty_changed(good_id, (_rows[good_id]["qty"] as LineEdit).text)


func _on_qty_changed(good_id: String, text: String) -> void:
	if _sanitizing:
		return
	var refs: Dictionary = _rows.get(good_id, {})
	if refs.is_empty():
		return
	var field: LineEdit = refs["qty"]
	var ceiling := _qty_ceiling(TradeEngineLib.sell_max(good_id))
	_set_field_text(field, _sanitize(text, ceiling))
	_apply_row_limits(good_id)


## `1 / 10 / 100 / Max` presets. The single picker serves both Buy and Sell, so
## "Max" is the larger of the two documented maxima — `buy_max` (gold + hold)
## and `sell_max` (held) — otherwise a full hold could never be emptied from
## the UI (docs/30 §4.4 "one picker" clarification). Each button then validates
## against **its own** maximum. A zero result clears the field rather than
## typing "0": empty and 0 are both invalid, and empty reads as "nothing
## picked yet" (docs/80 §4.7).
func _on_qty_preset(good_id: String, preset: int) -> void:
	var refs: Dictionary = _rows.get(good_id, {})
	if refs.is_empty():
		return
	var buy_max := TradeEngineLib.buy_max(_port_id, good_id) if not _port_id.is_empty() else 0
	var ceiling := maxi(buy_max, TradeEngineLib.sell_max(good_id))
	var value := ceiling if preset < 0 else mini(preset, ceiling)
	_set_field_text(refs["qty"] as LineEdit, "" if value <= 0 else str(value))
	_apply_row_limits(good_id)


func _on_buy(good_id: String) -> void:
	var qty := row_qty(good_id)
	if qty <= 0 or qty > TradeEngineLib.buy_max(_port_id, good_id):
		return
	if TradeEngineLib.buy(_port_id, good_id, qty):
		var good: Dictionary = DataLoader.get_good(good_id)
		_show_toast(I18n.fmt("market.traded", {
			"qty": qty, "name": I18n.t(good.get("name", {})),
		}))
		traded.emit("buy", good_id, qty)


func _on_sell(good_id: String) -> void:
	var qty := row_qty(good_id)
	if qty <= 0:
		return
	if TradeEngineLib.sell(_port_id, good_id, qty):
		var good: Dictionary = DataLoader.get_good(good_id)
		_show_toast(I18n.fmt("market.traded", {
			"qty": qty, "name": I18n.t(good.get("name", {})),
		}))
		traded.emit("sell", good_id, qty)


func _on_invest_pressed() -> void:
	if TradeEngineLib.invest(_port_id):
		_flash_gold()
		traded.emit("invest", "", TradeEngineLib.INVEST_CHUNK)


# --- Signals ---------------------------------------------------------------

func _on_gold_changed(_new_gold: int) -> void:
	_refresh()
	_flash_gold()


func _on_fleet_changed() -> void:
	_refresh()


## Only this port's stock changes re-read the table; another port's drift
## is irrelevant to what is on screen.
func _on_market_changed(port_id: String) -> void:
	if port_id == _port_id:
		_refresh()


func _on_locale_changed(_locale: String) -> void:
	_bind()
	_refresh()


# --- Helpers ---------------------------------------------------------------

## Digits-only filter + live clamp (docs/80 §4.7). An empty field stays empty so
## "empty = invalid" can be observed by the disabled buttons.
static func _sanitize(text: String, cap: int) -> String:
	var digits := ""
	for index in text.length():
		var character := text[index]
		if character >= "0" and character <= "9":
			digits += character
	if digits.is_empty():
		return ""
	var value := mini(int(digits), maxi(cap, 0))
	return str(value)


## Re-clamps an existing field after the ceiling moved (a trade, a locale
## change). An empty field is left alone (still invalid, not silently filled).
func _clamp_field(field: LineEdit, cap: int) -> void:
	if field.text.is_empty():
		return
	_set_field_text(field, _sanitize(field.text, cap))


func _set_field_text(field: LineEdit, text: String) -> void:
	if field.text == text:
		return
	_sanitizing = true
	field.text = text
	field.caret_column = text.length()
	_sanitizing = false


## Typed quantity, or -1 for an empty/invalid field.
static func _parse_qty(text: String) -> int:
	if text.strip_edges().is_empty():
		return -1
	return int(text)


## Transient bottom-center toast (docs/80 §4.7: 2.5s, max one visible).
## The coroutine may outlive the screen (Back/Esc frees it), so the resume path
## checks instance validity before touching the label.
func _show_toast(text: String) -> void:
	_toast_generation += 1
	var generation := _toast_generation
	_toast.text = text
	_toast.visible = true
	await get_tree().create_timer(TOAST_SECONDS).timeout
	if not is_instance_valid(_toast) or not is_inside_tree():
		return
	if generation == _toast_generation:
		_toast.visible = false


## Successful trade feedback (docs/30 §4.7 "flashes the gold readout"): the
## label brightens to ACCENT and fades back. Purely visual — no state read.
func _flash_gold() -> void:
	if _gold == null:
		return
	_gold.add_theme_color_override("font_color", PaletteLib.ACCENT)
	if _gold_tween != null and _gold_tween.is_valid():
		_gold_tween.kill()
	_gold_tween = create_tween()
	_gold_tween.tween_interval(0.35)
	_gold_tween.tween_callback(func() -> void:
		if is_instance_valid(_gold):
			_gold.add_theme_color_override("font_color", PaletteLib.TEXT)
	)


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


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PaletteLib.PANEL_BG
	style.border_color = PaletteLib.PANEL_LINE
	style.set_border_width_all(2)
	return style


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.gold_changed.is_connected(_on_gold_changed):
		EventBus.gold_changed.disconnect(_on_gold_changed)
	if EventBus.fleet_changed.is_connected(_on_fleet_changed):
		EventBus.fleet_changed.disconnect(_on_fleet_changed)
	if EventBus.market_changed.is_connected(_on_market_changed):
		EventBus.market_changed.disconnect(_on_market_changed)
