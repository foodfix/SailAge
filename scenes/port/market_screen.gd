extends Control
## Market screen (S5) — docs/30-PORTS-AND-TRADE.md §4.2–§4.5, §4.7 (wireframe),
## §6 (edge cases); docs/80-UI-UX.md §4.5 (HUD bars), §4.7 (numeric entry,
## toasts), §4.8 (palette, 32px rows, 40px buttons, 8px grid);
## Phase 7 (task M): §4.7.11 market rows — the listing rule, the ★ 特产
## badge + header, the 不收购 sell-disabled own produces, the grayed
## 专营货 rows, the 4-state tariff badge + per-side tax lines, and the
## three-state Invest button (docs/30 §4.9/§4.10, decision 26).
## Phase 8: the §4.2 appraisal-gated arrows — the profit arrow (↓ below
## `base_price` on the buy side / ↑ above it on the sell side, gate ≥ 30)
## and the other-port memory arrow (local price vs the remembered foreign
## price, gate ≥ 60) — rendered as bare ↑/↓ glyphs in their own cell; the
## engine's [method TradeEngine.profit_arrow] / [method
## TradeEngine.memory_arrow] own the gates, this screen only renders.
## 2026-11-03 (market polish, docs/30 §4.8): the ★ 特产 rows sort first
## behind a thin PANEL_LINE divider, the badge lives in a fixed reserved
## slot so every good name aligns; the table's columns come from one
## [constant COL_SPECS] table shared by header and rows (the two lists had
## drifted — the column-misalignment bug); the selected-row info strip
## shows the walked totals via the engine's `buy_cost` / `sell_gain` plus
## the tax lines; clicking a row selects it; Enter submits the Buy side;
## a successful trade clears the quantity; locked 专营货 rows gray every
## cell and take no quantity input.
##
## Everything the screen shows comes from data:
##   * the goods table iterates [method TradeEngine.goods_rows] (L's merged,
##     listing-filtered per-port payload) and keeps the **listed** rows only —
##     a port lists a good iff it produces or demands it (docs/30 §4.2 listing
##     rule; unlisted goods never render); the screen filters against
##     `ports.json` downstream as an idempotent second gate;
##   * prices, quantity ceilings and trade side effects are the
##     `trade_engine.gd` formulas, never duplicated here;
##   * the stock / trend / marginal-price columns read `economy.gd`
##     directly (docs/80 §4.7.7) — stock 0–200, the ▲/▼ drift glyph
##     against the effective rest, and the next-tranche price.
##
## **Allegiance reads are guarded** (docs/80 §4.9 guard-call convention):
## L's `allegiance.gd` may land before or after this screen, so every read
## goes through [method _allegiance_module] (`has_method` + `call`) with the
## pinned safe defaults — dev 0, alignment = the port's data `nation_id`,
## tariff 2000, no invest block. `allegiance_override` is the headless-suite
## seam (a stand-in module); the runtime never sets it. Likewise the tax
## line amounts come from the engine row payload's `tax_buy` / `tax_sell`
## (and `tax_mille`), read defensively with defaults so this screen works
## against today's payloads and L's upgraded ones alike.
##
## **The market sells trade goods only** (docs/20-* §4.10 as amended, docs/80-*
## §4.6.1): provisions and water are survival, not commerce, and are bought at
## the Set-Sail provisioning prompt (`scenes/port/provisions_dialog.tscn`) — the
## single supply purchase point. The supplies row that used to live here was
## removed with the prompt's introduction; the stale `market.price` /
## `market.supplies` / `market.provisions` / `market.water` keys were
## dropped from `ui_strings.json` with it (2026-11-03 dead-key sweep).
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
## Phase-10 sweep (§4.9): the goods rows carry the generated `good_{id}`
## icons and the `trend_up` / `trend_down` / `event_demand` marks through the
## kit's texture registry (an absent id renders nothing — the flat fallback;
## the registry fills at W4-D), the private trade toast adopts the kit toast
## atom, and every per-screen color/chrome override retires to the theme.
const UiKitLib := preload("res://scripts/ui_kit.gd")
const UiMotionLib := preload("res://scripts/ui_motion.gd")
const EconomyLib := preload("res://scripts/port/economy.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const IntelWindowLib := preload("res://scenes/ui_shared/intel_window.gd")
## Task L (docs/80-* §4.7.8): the "merchant captains in port" rows.
const NpcIntelLib := preload("res://scripts/world/npc_intel.gd")
## Phase-8 W5-C (docs/30-* §4.8): the captain-intel rows read the captains'
## stance through the W4-A module (read-only for this screen).
const CaptainsLib := preload("res://scripts/world/captains.gd")
const GameOverHostLib := preload("res://scenes/ui_shared/game_over_host.gd")

const PORT_SCENE := "res://scenes/port/port_screen.tscn"
## Quantity presets, in the §4.4 order 1 / 10 / 100 (+ Max).
const QTY_PRESETS: Array[int] = [1, 10, 100]
## The trade table's column definitions — the **single source** for the
## header captions and the row cells alike (docs/80 §4.8 8px grid). The
## old two independently-maintained lists drifted (the ★ badge slot and
## the qty-picker's inner separations were never counted on the header) —
## the 2026-11-03 column-misalignment bug; both builders now iterate
## [constant COL_SPECS], so the child order cannot diverge again. Each
## entry: `[cell key, header ui_strings key suffix ("" = no caption),
## width px, alignment]`. Composite widths are computed from the same
## constants the row builder uses:
const CELL_SEP := 4
## The ★ 特产 badge slot (docs/80 §4.7.11): reserved on **every** row —
## blank on non-produce rows — so every good name starts at the same x.
## The good's `good_{id}` icon (§4.8) rides between the badge slot and the
## name; the Good cell's total width is unchanged (the name gives the 32px
## icon slot its room).
const COL_BADGE_W := 56
const COL_GOOD_ICON_W := 32
const COL_NAME_W := 124
const COL_STOCK_W := 56
const COL_TREND_W := 96
## Phase 8 (docs/30 §4.2): the appraisal-gated profit / other-port memory
## arrows — one narrow cell between Trend and Marginal. Bare ↑/↓ glyphs
## (locale-independent symbols; the §4.7.15 inventory pins no string keys).
const COL_ARROW_W := 40
const COL_MARGINAL_W := 160
const COL_HAVE_W := 70
const COL_QTY_W := 72
const COL_PRESET_W := 40
const COL_MAX_W := 56
const COL_BUTTON_W := 88
## The qty picker cell: the field + 1/10/100 + Max with the four inner gaps.
const COL_QTY_TOTAL_W := COL_QTY_W + 3 * COL_PRESET_W + COL_MAX_W \
	+ 4 * CELL_SEP
## The Good cell: the reserved badge slot, the gap, the good icon, the gap,
## then the name.
const COL_GOOD_TOTAL_W := COL_BADGE_W + CELL_SEP + COL_GOOD_ICON_W \
	+ CELL_SEP + COL_NAME_W
const COL_SPECS: Array = [
	["good", "good", COL_GOOD_TOTAL_W, HORIZONTAL_ALIGNMENT_LEFT],
	["stock", "stock.header", COL_STOCK_W, HORIZONTAL_ALIGNMENT_RIGHT],
	["trend", "stock.trend", COL_TREND_W, HORIZONTAL_ALIGNMENT_LEFT],
	["arrows", "", COL_ARROW_W, HORIZONTAL_ALIGNMENT_LEFT],
	["marginal", "stock.marginal", COL_MARGINAL_W, HORIZONTAL_ALIGNMENT_RIGHT],
	["you_have", "you_have", COL_HAVE_W, HORIZONTAL_ALIGNMENT_RIGHT],
	["qty", "qty", COL_QTY_TOTAL_W, HORIZONTAL_ALIGNMENT_CENTER],
	["buy", "buy", COL_BUTTON_W, HORIZONTAL_ALIGNMENT_CENTER],
	["sell", "sell", COL_BUTTON_W, HORIZONTAL_ALIGNMENT_CENTER],
]
## Task L's allegiance module (docs/80-* §4.16 contract) — loaded through the
## guard helpers, never hard-referenced (it may not exist yet).
const ALLEGIANCE_PATH := "res://scripts/port/allegiance.gd"
## The guard-default tariff when no allegiance module answers
## (docs/80-* §4.16: 未同盟 20%).
const DEFAULT_TARIFF_MILLE := 2000
## The 20% and 5% tariff rates in per-mille (docs/30-* §4.10 unified tariff).
const FOREIGN_TARIFF_MILLE := 2000
const SPHERE_TARIFF_MILLE := 500
## Player investment allowance per contestable port per month
## (decision 26 / docs/30-* §4.9). Display-only here — task L's allegiance
## module enforces the same cap; this feeds the `market.invest_gate.allowance`
## hint. Reset at the month tick (`month_tick`).
const INVEST_MONTHLY_CAP := 2000

## Phase-8 W5-C (docs/30-* §4.8): the captain-intel section's `ui_strings`
## keys — reported for the W6-D residual merge; until then the section renders
## from this local table (the tavern-screen FALLBACK_STRINGS pattern: same
## zh+en shape as the JSON so the merge is a copy-paste).
const INTEL_FALLBACK_STRINGS = {
	"market.intel.header": {
		"zh": "船长航线情报",
		"en": "Captain lane intel",
	},
	"market.intel.free": {
		"zh": "免费情报:下一程 {port}",
		"en": "Free intel: next leg {port}",
	},
}
## The free-intel qualifier (docs/30-* §4.8, docs/80-* §4.11.1: stance ≥ +2
## marks the next-lane hint free — the hail flow grants it, `60-*`).
const INTEL_FREE_STANCE := 2

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
## Gold-flash tween (created/destroyed by [_flash_gold]).
var _gold_tween: Tween = null
## Task L (§4.7.8): the "merchant captains in port" section (code-built under
## the trade table; the scene file stays untouched) — header + row labels.
var _captains_header: Label = null
var _captains_box: VBoxContainer = null
## The captain rows currently rendered (`{id, name, role, nation_id}`).
var _captain_rows: Array = []
## Phase-8 W5-C (docs/30-* §4.8): the captain-intel section — one row per
## captain-bearing fleet sighted at this port; stance ≥ +2 rows carry the
## free next-lane hint (the hail flow grants it, `60-*`).
var _intel_header: Label = null
var _intel_box: VBoxContainer = null
var _intel_rows: Array = []
## Phase 7 (task M): this port's `produces` / `demands` from `ports.json`
## (cached at open; the dock never changes while the screen is up).
var _produces: Array = []
var _demands: Array = []
## The engine's row payloads per good id (`{good_id: payload}`) — L's
## upgraded `goods_rows(port_id)` rows carry `tax_buy` / `tax_sell` /
## `tax_mille`; today's rows are the raw goods entries. Read defensively.
var _payloads: Dictionary = {}
## The good whose tax lines the strip shows (the last row whose quantity the
## player touched — docs/30 §4.8: the tax lines accompany a trade dialog).
var _selected_good: String = ""
## Phase 7 widgets built in code (the captains-section pattern): the
## `特产:` header above the table, the header tariff badge, and the
## selected-row info strip below the goods table.
var _specialty_header: Label = null
var _tax_badge: Label = null
var _info_strip: Label = null
## Per-section render caches: the captains section rebuilds only when its
## docked-fleet fingerprint moves, the intel section only when its rows'
## data moves — the seeded sighting rolls are visit-stable (docs/80 §4.7.8),
## so a rebuild on every `gold_changed` bought nothing but churn (and, on
## the captains side, re-accrued `sightings()` familiarity). A locale
## change resets both to force a re-render.
var _captains_key: String = ""
var _intel_key: String = ""


# --- Guarded Allegiance reads (docs/80-* §4.16) ------------------------------

## Headless-suite seam: a stand-in for L's allegiance module. The runtime
## never sets it; when null the real module (autoload node, then script) is
## used, else the §4.9 safe defaults.
static var allegiance_override: Variant = null


## The object answering `method` — the suite's override first, then L's
## live autoload node (`/root/Allegiance`), then the script's statics
## (the §4.12.3 `ResourceLoader.load` + `has_method` guard pattern) — or
## null, which every caller turns into its pinned default.
static func _allegiance_module(method: String) -> Variant:
	if allegiance_override != null \
			and (allegiance_override as Object).has_method(method):
		return allegiance_override
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
		var node := (tree as SceneTree).root.get_node_or_null("Allegiance")
		if node != null and node.has_method(method):
			return node
	if ResourceLoader.exists(ALLEGIANCE_PATH):
		var script: Variant = ResourceLoader.load(ALLEGIANCE_PATH)
		if script is Script and (script as Script).has_method(method):
			return script
	return null


static func _allegiance_str(method: String, port_id: String,
		fallback: String) -> String:
	if port_id.is_empty():
		return fallback
	var module: Variant = _allegiance_module(method)
	if module == null:
		return fallback
	return str(module.call(method, port_id))


static func _allegiance_int(method: String, port_id: String,
		fallback: int) -> int:
	if port_id.is_empty():
		return fallback
	var module: Variant = _allegiance_module(method)
	if module == null:
		return fallback
	return int(module.call(method, port_id))


## The tariff in per-mille for the *player's* nation at this port
## (`tariff_mille(port_id, nation_id)`; guard default 2000 — docs/80 §4.9).
func _tariff_mille() -> int:
	if _port_id.is_empty():
		return DEFAULT_TARIFF_MILLE
	var module: Variant = _allegiance_module("tariff_mille")
	if module == null:
		return DEFAULT_TARIFF_MILLE
	return int(module.call("tariff_mille", _port_id, _player_nation()))


## The port's effective alignment (guard default: the port's data
## `nation_id` — docs/80 §4.9).
func _effective_alignment() -> String:
	return _allegiance_str("effective_alignment", _port_id,
		str(DataLoader.get_port(_port_id).get("nation_id", "")))


func _player_nation() -> String:
	if GameState.player.is_empty():
		return ""
	return str(GameState.player.get("nation_id", ""))


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	# Full-scene S9 (80-* §4.2 amendment, 2026-11-02): a run can die on any
	# ledger tick ashore — the game-over screen must rise over the market too.
	GameOverHostLib.attach_to(self)
	# Phase-10 sweep: label colors retire to the shared theme (TEXT is the
	# theme's Label default; secondary status lines carry the `Dim`
	# variation) and the trade table renders the themed PanelContainer chrome.
	_invest_status.theme_type_variation = "Dim"
	_back_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_invest_button.custom_minimum_size.y = PaletteLib.BUTTON_H
	_back_button.pressed.connect(go_back)
	_invest_button.pressed.connect(_on_invest_pressed)
	_goods_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_goods_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_port_id = _read_current_port()
	_cache_port_lists()
	_build_specialty_header()
	_build_tax_badge()
	_build_info_strip()
	_build()
	_bind()
	_refresh()
	_build_captains_section()
	_refresh_captains()
	_build_intel_section()
	_refresh_intel()

	# S14 over S5, the same modal the port hub offers (docs/80 §4.3).
	IntelWindowLib.attach_to(self)

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


## The goods table's rows, in display order (docs/30 §4.8: ★ 特产 rows
## first, then the rest, each group by `base_price` ascending).
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

## Caches this port's `produces` / `demands` (the §4.2 listing rule inputs).
func _cache_port_lists() -> void:
	var port: Dictionary = DataLoader.get_port(_port_id) \
		if not _port_id.is_empty() else {}
	_produces = (port.get("produces", []) as Array).duplicate() \
		if port.has("produces") else []
	_demands = (port.get("demands", []) as Array).duplicate() \
		if port.has("demands") else []


## The §4.2 listing rule: a port lists a good iff it produces or demands it.
func _is_listed(good_id: String) -> bool:
	return good_id in _produces or good_id in _demands


## Whether the port produces `good_id` (the ★ 特产 rows + the 不收购 rule).
func _is_own_produce(good_id: String) -> bool:
	return good_id in _produces


## Whether `good_id` is a 专营货 (exclusive) — the goods.json flag.
func _is_exclusive(good_id: String) -> bool:
	return DataLoader.get_good(good_id).get("exclusive", false) == true


## The §4.9 entitlement: an exclusive row activates when the port's effective
## alignment is the player's nation **and** dev ≥ 2 (guard default dev 0, so
## the rows stay locked until the allegiance module lands).
func _exclusive_unlocked() -> bool:
	var player := _player_nation()
	if player.is_empty():
		return false
	if _allegiance_int("dev", _port_id, 0) < 2:
		return false
	return _allegiance_str("effective_alignment", _port_id,
		str(DataLoader.get_port(_port_id).get("nation_id", ""))) == player


## L's merged, pinned listing-filtered payload (docs/30 §4.4/§4.10 — the
## engine owns the listing rule and the tariff side of each transaction).
## The screen still filters against `ports.json` downstream as a cheap second
## gate (idempotent), so the visible listing rule holds regardless of which
## layer produced the rows.
static func _engine_goods_rows(port_id: String) -> Array:
	return TradeEngineLib.goods_rows(port_id)


## Builds the fixed column header and one row per **listed** good in the
## §4.8 display order — ★ 特产 rows first, then the rest, each group by
## `base_price` ascending (ties by id; the engine's `goods_rows` keeps its
## pure `base_price` order, this screen reorders for display only). A thin
## divider separates the specialty group from the remaining rows. Called
## once from `_ready`; a locale change only re-binds the labels
## ([method _bind]) because no row content changes with locale. There is
## **no** supplies row: provisions and water are bought in the Set-Sail
## prompt (docs/20-* §4.10).
func _build() -> void:
	_build_column_header()
	for child in _goods_rows.get_children():
		_goods_rows.remove_child(child)
		child.queue_free()
	_rows.clear()
	_payloads.clear()
	var listed: Array = []
	for good in _engine_goods_rows(_port_id):
		var good_id := str(good.get("id", ""))
		if good_id.is_empty() or not _is_listed(good_id):
			continue  # unlisted goods never render (docs/30 §4.2)
		listed.append(good)
	listed.sort_custom(_display_order)
	var produce_rows := 0
	var rest_rows := 0
	for good in listed:
		var good_id := str(good.get("id", ""))
		_payloads[good_id] = good
		if _is_own_produce(good_id):
			produce_rows += 1
		else:
			if produce_rows > 0 and rest_rows == 0:
				_goods_rows.add_child(_make_group_divider())
			rest_rows += 1
		_rows[good_id] = _build_good_row(good_id)


## The §4.8 display order (2026-11-03 amendment): ★ 特产 rows before the
## rest; within each group `base_price` ascending, ties by id.
func _display_order(a: Dictionary, b: Dictionary) -> bool:
	var a_id := str(a.get("id", ""))
	var b_id := str(b.get("id", ""))
	var a_produce := _is_own_produce(a_id)
	var b_produce := _is_own_produce(b_id)
	if a_produce != b_produce:
		return a_produce
	var price_a := int(a.get("base_price", 0))
	var price_b := int(b.get("base_price", 0))
	if price_a != price_b:
		return price_a < price_b
	return a_id < b_id


## The thin `PANEL_LINE` divider between the ★ 特产 group and the remaining
## rows (docs/30 §4.8). Lives inside GoodsRows, so a rebuild clears it with
## the rows; it owns no `_rows` entry and takes no clicks.
func _make_group_divider() -> ColorRect:
	var divider := ColorRect.new()
	divider.name = "SpecialtyDivider"
	divider.color = PaletteLib.PANEL_LINE
	divider.custom_minimum_size = Vector2(0, 2)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return divider


func _build_column_header() -> void:
	for child in _column_header.get_children():
		_column_header.remove_child(child)
		child.queue_free()
	# One label per [constant COL_SPECS] entry — the row cells are built
	# from the same table, so a caption and its cell cannot drift apart.
	# The Phase-8 arrows cell carries no caption (bare glyphs, no keys).
	for spec in COL_SPECS:
		var label := Label.new()
		label.name = "Col_%s" % str(spec[0])
		if not str(spec[1]).is_empty():
			label.set_meta("text_key", "market.%s" % str(spec[1]))
		label.custom_minimum_size = Vector2(float(spec[2]), float(PaletteLib.ROW_H))
		label.horizontal_alignment = int(spec[3])
		label.clip_text = true
		# Secondary caption color: the theme's `Dim` variation.
		label.theme_type_variation = "Dim"
		_column_header.add_child(label)


## One table row, built cell-for-cell in [constant COL_SPECS] order —
## Good (reserved badge slot + name) | Stock | Trend | Arrows | Marginal |
## You have | Qty picker | [Buy][Sell] (docs/30 §4.8 + docs/80 §4.7.7).
## Every widget's text is filled later by [method _refresh].
func _build_good_row(good_id: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % good_id
	row.custom_minimum_size = Vector2(0, float(PaletteLib.ROW_H))
	row.set_meta("good_id", good_id)
	# Clicking anywhere on the row selects it (docs/30 §4.8 info strip).
	# PASS, so the row's own buttons and field still get their clicks.
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.gui_input.connect(_on_row_gui_input.bind(good_id))

	var refs := {"node": row, "qty_buttons": {}}
	for spec in COL_SPECS:
		match str(spec[0]):
			"good":
				var name_cell := HBoxContainer.new()
				name_cell.name = "NameCell"
				name_cell.mouse_filter = Control.MOUSE_FILTER_PASS
				# The ★ 特产 badge (docs/80 §4.7.11): a fixed reserved slot
				# on **every** row — produce rows render the badge, the rest
				# keep the empty slot — so the good names align; text is
				# bound per locale in [method _bind].
				var badge_label := Label.new()
				badge_label.name = "Badge"
				badge_label.custom_minimum_size.x = float(COL_BADGE_W)
				badge_label.clip_text = true
				badge_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				name_cell.add_child(badge_label)
				# The good's §4.8 icon (`good_{id}`): 32px inline in the
				# 32px row while the registry carries the id; absent ⇒ the
				# slot collapses (the flat fallback, zero layout shift).
				var good_icon := TextureRect.new()
				good_icon.name = "GoodIcon"
				good_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
				good_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				good_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				var good_tex := UiKitLib.icon_texture("good_%s" % good_id)
				if good_tex != null:
					good_icon.texture = good_tex
					good_icon.custom_minimum_size = Vector2(
						float(COL_GOOD_ICON_W), float(PaletteLib.ROW_H))
				name_cell.add_child(good_icon)
				var name_label := Label.new()
				name_label.name = "Name"
				name_label.custom_minimum_size.x = float(COL_NAME_W)
				name_label.clip_text = true
				name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				name_cell.add_child(name_label)
				row.add_child(name_cell)
				refs["name_cell"] = name_cell
				refs["badge"] = badge_label
				refs["name"] = name_label
			"arrows":
				# Phase 8 (docs/30 §4.2): the appraisal-gated arrows — bare
				# ↑/↓ glyphs (the former per-screen GOOD/ACCENT tints retire
				# to the theme TEXT; flagged in the W4-A sweep report).
				var arrows_box := HBoxContainer.new()
				arrows_box.name = "Arrows"
				arrows_box.mouse_filter = Control.MOUSE_FILTER_PASS
				arrows_box.custom_minimum_size.x = float(COL_ARROW_W)
				var profit_arrow_label := Label.new()
				profit_arrow_label.name = "ProfitArrow"
				profit_arrow_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				var memory_arrow_label := Label.new()
				memory_arrow_label.name = "MemoryArrow"
				memory_arrow_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				arrows_box.add_child(profit_arrow_label)
				arrows_box.add_child(memory_arrow_label)
				row.add_child(arrows_box)
				refs["arrows"] = arrows_box
				refs["profit_arrow"] = profit_arrow_label
				refs["memory_arrow"] = memory_arrow_label
			"trend":
				# The §4.7.7 flow-trend cell: the §4.8 trend mark
				# (`trend_up` / `trend_down` /, on a demand-event surge,
				# `event_demand`) beside the localized glyph line — the mark
				# is bound per refresh in [method _refresh_stock_cells]; an
				# absent id keeps the text-only cell.
				var trend_box := HBoxContainer.new()
				trend_box.name = "TrendCell"
				trend_box.mouse_filter = Control.MOUSE_FILTER_PASS
				trend_box.custom_minimum_size.x = float(COL_TREND_W)
				var trend_icon := TextureRect.new()
				trend_icon.name = "TrendMark"
				trend_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
				trend_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				trend_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				trend_box.add_child(trend_icon)
				var trend_label := Label.new()
				trend_label.name = "Trend"
				trend_label.clip_text = true
				trend_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				trend_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				trend_box.add_child(trend_label)
				row.add_child(trend_box)
				refs["trend_icon"] = trend_icon
				refs["trend"] = trend_label
			"qty":
				# Quantity picker (docs/30 §4.4): 1 / 10 / 100 / Max buttons
				# plus direct numeric entry (digits only, live-clamped,
				# empty = invalid). Enter submits the Buy side when allowed.
				var qty_box := HBoxContainer.new()
				qty_box.name = "QtyPicker"
				qty_box.mouse_filter = Control.MOUSE_FILTER_PASS
				var qty_field := LineEdit.new()
				qty_field.name = "Qty"
				qty_field.custom_minimum_size = Vector2(float(COL_QTY_W),
					float(PaletteLib.ROW_H))
				qty_field.max_length = 6
				qty_field.placeholder_text = "0"
				qty_box.add_child(qty_field)
				for preset in QTY_PRESETS:
					var button := _make_row_button(
						"Qty%d" % preset, str(preset), COL_PRESET_W)
					button.pressed.connect(_on_qty_preset.bind(good_id, preset))
					qty_box.add_child(button)
					refs["qty_buttons"][str(preset)] = button
				var max_button := _make_row_button(
					"QtyMax", I18n.t_key("market.max"), COL_MAX_W)
				max_button.pressed.connect(_on_qty_preset.bind(good_id, -1))
				qty_box.add_child(max_button)
				refs["qty_buttons"]["max"] = max_button
				row.add_child(qty_box)
				refs["qty"] = qty_field
				qty_field.text_changed.connect(
					_on_qty_text_changed.bind(good_id))
				qty_field.text_submitted.connect(
					_on_qty_submitted.bind(good_id))
			"buy", "sell":
				var is_buy := str(spec[0]) == "buy"
				var key := "Buy" if is_buy else "Sell"
				var trade_button := _make_row_button(key, "", COL_BUTTON_W)
				var handler := _on_buy if is_buy else _on_sell
				trade_button.pressed.connect(handler.bind(good_id))
				row.add_child(trade_button)
				refs[key.to_lower()] = trade_button
			_:
				# A plain fixed-width cell (Stock / Marginal / You have):
				# the caption's width and alignment from the same spec,
				# clip_text so a wide value can never push the row's
				# remaining columns off their captions.
				var spec_key := str(spec[0])
				var cell := Label.new()
				cell.name = "Have" if spec_key == "you_have" \
					else spec_key.capitalize()
				cell.custom_minimum_size.x = float(spec[2])
				cell.horizontal_alignment = int(spec[3])
				cell.clip_text = true
				cell.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				row.add_child(cell)
				refs["have" if spec_key == "you_have" else spec_key] = cell

	_goods_rows.add_child(row)
	return refs


func _make_row_button(node_name: String, text: String, width: int) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(float(width), float(PaletteLib.ROW_H))
	button.focus_mode = Control.FOCUS_ALL
	return button


## The `特产:` header line above the table (docs/80 §4.7.11): names up to 3 of
## the port's produces. Text is bound per locale in [method _bind].
func _build_specialty_header() -> void:
	var table: VBoxContainer = $Layout/VBox/TableFrame/Margin/Table
	_specialty_header = Label.new()
	_specialty_header.name = "SpecialtyHeader"
	table.add_child(_specialty_header)
	table.move_child(_specialty_header, 0)


## The header tariff badge (docs/30 §4.8 / docs/80 §4.7.11): 势力内 5% /
## 免税 / 外国 20% / 未同盟 20%, placed before the Back button like the
## wireframe's `· 势力内 5%` slot. Text/color bound in [method
## _refresh_header].
func _build_tax_badge() -> void:
	var header: HBoxContainer = $Layout/VBox/Header
	_tax_badge = Label.new()
	_tax_badge.name = "TaxBadge"
	header.add_child(_tax_badge)
	header.move_child(_tax_badge, _back_button.get_index())


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
		# ★ 特产 badge: a fixed reserved slot on every row (docs/80 §4.7.11,
		# 2026-11-03) — produces members render the badge, the rest keep the
		# empty slot so every good name starts at the same x.
		var badge: Label = refs["badge"]
		badge.text = ("%s %s" % ["★", I18n.t_key("market.specialty.badge")]) \
			if _is_own_produce(good_id) else ""
		(refs["buy"] as Button).text = I18n.t_key("market.buy")
		(refs["sell"] as Button).text = I18n.t_key("market.sell")
		((refs["qty_buttons"] as Dictionary)["max"] as Button).text = \
			I18n.t_key("market.max")
	_refresh_specialty_header()


## The `特产: <names>` header — up to 3 of the port's produces, plus the
## `market.specialty.more` suffix when there are more (docs/30 §4.8,
## `market.specialty.header`). Hidden at a port that produces nothing and
## when no port is docked.
func _refresh_specialty_header() -> void:
	if _specialty_header == null:
		return
	var names: Array[String] = []
	for member in _produces.slice(0, 3):
		names.append(I18n.t(DataLoader.get_good(str(member)).get("name", {})))
	_specialty_header.visible = not names.is_empty()
	if names.is_empty():
		_specialty_header.text = ""
		return
	var text := I18n.fmt("market.specialty.header", {
		"names": ", ".join(names),
	})
	if _produces.size() > 3:
		text += " (%s)" % I18n.fmt("market.specialty.more",
			{"count": _produces.size() - 3})
	_specialty_header.text = text


## The specialty header's current text (the suite's seam, captains-pattern).
func specialty_header_text() -> String:
	return _specialty_header.text if _specialty_header != null else ""


# --- Refresh ---------------------------------------------------------------

func _refresh() -> void:
	# Task L: a save loaded straight into port re-applies the active demand
	# events' rest-overrides before any trend cell reads them (the table is
	# transient; the saved instances are the truth — docs/30-* §4.5).
	EconomyLib.ensure_event_overrides()
	_refresh_header()
	_refresh_rows()
	_refresh_info_strip()
	_refresh_investment()
	_refresh_captains()
	_refresh_intel()


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
	_refresh_tax_badge()


## The 4-state tariff badge (docs/80 §4.7.11): 免税 (permit, mille 0) /
## 势力内 5% (mille 500) / 外国 20% vs 未同盟 20% (mille 2000, split by
## the effective alignment — the player's nation reads 势力内, an absent
## alignment reads 未同盟, anything else 外国).
static func tax_badge_key(mille: int, alignment: String,
		player_nation: String) -> String:
	if mille == 0:
		return "market.tax.badge.exempt"
	if mille == SPHERE_TARIFF_MILLE:
		return "market.tax.badge.in_sphere"
	if not player_nation.is_empty() and alignment == player_nation:
		return "market.tax.badge.in_sphere"
	if alignment.is_empty():
		return "market.tax.badge.unallied"
	return "market.tax.badge.foreign"


func _refresh_tax_badge() -> void:
	if _tax_badge == null:
		return
	if _port_id.is_empty():
		_tax_badge.visible = false
		_tax_badge.text = ""
		return
	_tax_badge.visible = true
	var key := tax_badge_key(_tariff_mille(), _effective_alignment(),
		_player_nation())
	_tax_badge.text = I18n.t_key(key)
	# The former per-screen ACCENT/BAD tints retire to the theme TEXT
	# (flagged in the W4-A sweep report — no theme atom expresses them).


## The header badge's current key + text (the suite's seam).
func tax_badge_state() -> Dictionary:
	return {
		"key": tax_badge_key(_tariff_mille(), _effective_alignment(),
			_player_nation()),
		"text": _tax_badge.text if _tax_badge != null else "",
	}


# --- Selected-row info strip (docs/30 §4.8, docs/80 §4.7.11) -----------------

## The strip below the goods table (built once, the captains-section
## pattern): the selected row's walked totals (`market.total.buy` /
## `market.total.sell`, the §4.4 `buy_cost` / `sell_gain` queries) with the
## per-side tax lines (`market.tax.buy_line` / `market.tax.sell_line`,
## §4.10) beneath. Hidden until a row is selected and one of the lines
## applies.
func _build_info_strip() -> void:
	var table: VBoxContainer = $Layout/VBox/TableFrame/Margin/Table
	_info_strip = Label.new()
	_info_strip.name = "InfoStrip"
	_info_strip.theme_type_variation = "Dim"
	_info_strip.visible = false
	table.add_child(_info_strip)


## The two tax lines for `good_id`'s engine payload: `market.tax.buy_line` /
## `market.tax.sell_line` from `tax_buy` / `tax_sell` (rate from `tax_mille`,
## else the guarded tariff). Empty when the payload carries no tax fields —
## today's engine rows pre-date task L's tariff compose.
func tax_line_texts(good_id: String) -> Array:
	var payload: Variant = _payloads.get(good_id, {})
	if not (payload is Dictionary):
		return []
	var data: Dictionary = payload
	if not (data.has("tax_buy") or data.has("tax_sell")):
		return []
	@warning_ignore("integer_division")
	var rate := int(data.get("tax_mille", _tariff_mille())) / 100
	var out: Array = []
	if data.has("tax_buy"):
		out.append(I18n.fmt("market.tax.buy_line", {
			"rate": rate,
			"gold": format_thousands(int(data.get("tax_buy", 0))),
		}))
	if data.has("tax_sell"):
		out.append(I18n.fmt("market.tax.sell_line", {
			"rate": rate,
			"gold": format_thousands(int(data.get("tax_sell", 0))),
		}))
	return out


## The walked-total lines for the selected row (docs/30 §4.8, 2026-11-03):
## a `market.total.buy` line when the Buy side is enabled for the typed
## quantity, a `market.total.sell` line when the Sell side is — both when
## both are. The engine's read-only §4.4 walk sums (`buy_cost` /
## `sell_gain`) are the only source; the screen never recomputes prices.
func total_line_texts(good_id: String) -> Array:
	var qty := row_qty(good_id)
	if qty <= 0 or _port_id.is_empty():
		return []
	var refs: Dictionary = _rows.get(good_id, {})
	if refs.is_empty():
		return []
	var good: Dictionary = DataLoader.get_good(good_id)
	var out: Array = []
	if not (refs["buy"] as Button).disabled:
		out.append(I18n.fmt("market.total.buy", {
			"qty": qty,
			"name": I18n.t(good.get("name", {})),
			"gold": format_thousands(
				TradeEngineLib.buy_cost(_port_id, good_id, qty)),
		}))
	if not (refs["sell"] as Button).disabled:
		out.append(I18n.fmt("market.total.sell", {
			"qty": qty,
			"name": I18n.t(good.get("name", {})),
			"gold": format_thousands(
				TradeEngineLib.sell_gain(_port_id, good_id, qty)),
		}))
	return out


func _refresh_info_strip() -> void:
	if _info_strip == null:
		return
	var lines: Array = []
	if not _selected_good.is_empty():
		lines.append_array(total_line_texts(_selected_good))
		lines.append_array(tax_line_texts(_selected_good))
	_info_strip.visible = not lines.is_empty()
	_info_strip.text = "\n".join(PackedStringArray(lines))


## The info strip's current text (the suite's seam, captains-pattern).
func info_strip_text() -> String:
	return _info_strip.text if _info_strip != null else ""


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
		_refresh_arrow_cells(good_id, refs)
		(refs["have"] as Label).text = str(FleetLib.held(good_id))
		_apply_row_limits(good_id)


## The Phase-8 arrow cells (docs/30 §4.2): the profit arrow renders iff the
## effective appraisal passes its ≥ 30 gate and the row is profitable vs
## `base_price`; the other-port memory arrow iff the ≥ 60 gate passes and the
## memory holds a foreign entry for the good. Below the gates the cells stay
## empty and only the §4.8 flow-trend glyph shows (kept in
## `_refresh_stock_cells`, untouched).
func _refresh_arrow_cells(good_id: String, refs: Dictionary) -> void:
	var profit_dir := TradeEngineLib.profit_arrow(_port_id, good_id) \
		if not _port_id.is_empty() else ""
	var memory_dir := TradeEngineLib.memory_arrow(_port_id, good_id) \
		if not _port_id.is_empty() else ""
	var profit_label: Label = refs["profit_arrow"]
	var memory_label: Label = refs["memory_arrow"]
	profit_label.text = _arrow_glyph(profit_dir)
	memory_label.text = _arrow_glyph(memory_dir)


## `↑` above / `↓` below; `""` for no arrow.
static func _arrow_glyph(direction: String) -> String:
	if direction == "up":
		return "↑"
	if direction == "down":
		return "↓"
	return ""


## The Phase-8 arrow directions currently rendered on a good's row
## (`{"profit": "up"|"down"|"", "memory": ...}`) — the suite seam; the labels
## themselves carry the bare ↑/↓ glyphs.
func row_arrows(good_id: String) -> Dictionary:
	var profit_dir := TradeEngineLib.profit_arrow(_port_id, good_id) \
		if not _port_id.is_empty() else ""
	var memory_dir := TradeEngineLib.memory_arrow(_port_id, good_id) \
		if not _port_id.is_empty() else ""
	return {"profit": profit_dir, "memory": memory_dir}


## Stock cell (0–200) and the one-glyph trend against the **effective**
## rest (override-aware, docs/30 §4.5): ▲ refilling below rest, ▼ draining
## above it, blank exactly at rest (docs/80 §4.7.7 — no forecast). The §4.8
## trend mark rides beside the glyph — `event_demand` while a demand-event
## surge covers the port-good, else `trend_up` / `trend_down`; an absent id
## renders nothing (the flat fallback).
func _refresh_stock_cells(good_id: String, refs: Dictionary) -> void:
	var stock_label: Label = refs["stock"]
	var trend_label: Label = refs["trend"]
	var trend_icon: TextureRect = refs["trend_icon"]
	var mark := ""
	if _port_id.is_empty():
		stock_label.text = "-"
		trend_label.text = ""
	else:
		var stock := EconomyLib.stock_of(_port_id, good_id)
		var rest := EconomyLib.effective_rest(_port_id, good_id)
		stock_label.text = str(stock)
		if EconomyLib.consumption_surged(_port_id, good_id):
			mark = "event_demand"
			trend_label.text = I18n.t_key("market.stock.trend_up")
		elif stock < rest:
			mark = "trend_up"
			trend_label.text = I18n.t_key("market.stock.trend_up")
		elif stock > rest:
			mark = "trend_down"
			trend_label.text = I18n.t_key("market.stock.trend_down")
		else:
			trend_label.text = ""
	var texture := UiKitLib.icon_texture(mark) if not mark.is_empty() else null
	trend_icon.texture = texture
	trend_icon.visible = texture != null
	trend_icon.custom_minimum_size = Vector2(32, 32) if texture != null \
		else Vector2(0, 0)


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

	# 专营货 rows (docs/80 §4.7.11): grayed with the lock note until the
	# port is aligned to the player at dev ≥ 2 — the whole row is inert
	# (docs/30 §4.8, 2026-11-03): both buttons and the quantity picker are
	# disabled, so typing on a locked row means nothing.
	if _is_exclusive(good_id) and not _exclusive_unlocked():
		var lock_note := I18n.t_key("market.exclusive.locked")
		_set_button_state(refs["buy"] as Button, false, lock_note)
		_set_button_state(refs["sell"] as Button, false, lock_note)
		_set_row_grayed(refs, true)
		field.editable = false
		for key in refs["qty_buttons"]:
			(refs["qty_buttons"] as Dictionary)[key].disabled = true
		return
	_set_row_grayed(refs, false)
	field.editable = true

	var buy_button: Button = refs["buy"]
	var buy_reason := _buy_reason(good_id, qty, buy_max)
	_set_button_state(buy_button, buy_reason.is_empty(), buy_reason)

	var sell_button: Button = refs["sell"]
	var sell_reason := _sell_reason(good_id, qty, held)
	_set_button_state(sell_button, sell_reason.is_empty(), sell_reason)


## The exclusive lock's visual state: the whole row's text cells dim to the
## theme's `Dim` variation while the row is gated (docs/80 §4.7.11 "grayed
## exclusive rows"); restoring clears the variation (the trend mark — not
## the label — carries the flow color once art is live).
func _set_row_grayed(refs: Dictionary, grayed: bool) -> void:
	var variation := "Dim" if grayed else ""
	for key in ["name", "stock", "marginal", "have"]:
		(refs[key] as Label).theme_type_variation = variation
	(refs["trend"] as Label).theme_type_variation = variation


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


## Why a Sell would fail ("" = allowed). A producing port never buys its own
## produced goods (docs/30 §4.2 market direction), so own-produce rows are
## disabled with 不收购 before any quantity is even looked at. Sell max is the
## held quantity, so an empty row and an over-held quantity are both an
## invalid quantity.
func _sell_reason(good_id: String, qty: int, held: int) -> String:
	if _is_own_produce(good_id):
		return I18n.t_key("market.not_bought")
	if _port_id.is_empty() or held <= 0:
		return I18n.t_key("market.invalid_qty")
	if qty <= 0 or qty > held:
		return I18n.t_key("market.invalid_qty")
	return ""


func _set_button_state(button: Button, enabled: bool, reason: String) -> void:
	button.disabled = not enabled
	button.tooltip_text = reason


## The three-state Invest button (docs/80 §4.7.11, decision 26):
## (a) available — the standing engine gates (chunk affordability, the
## §4.3 discount cap) apply; (b) allowance-exhausted —
## `market.invest_gate.exhausted` plus the `market.invest_gate.allowance`
## hint (≤ 2,000g per contestable port per month, reset at the month tick);
## (c) diplomacy-blocked — `market.invest_gate.blocked` (rep ≥ 0 and no
## bounty vs the alignment nation). The state comes from the allegiance
## module's block-reason contract, guarded to "" (available) pre-L.
func _refresh_investment() -> void:
	var invested := TradeEngineLib.invested(_port_id)
	var percent := TradeEngineLib.investment_percent(_port_id)
	_invest_status.text = I18n.fmt("market.invested_here", {
		"gold": format_thousands(invested),
		"count": percent,
	})
	var reason := _invest_block_reason()
	if not reason.is_empty():
		_invest_button.disabled = true
		_invest_button.tooltip_text = _invest_gate_text(reason)
		return
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


## The guard-read block reason ("" or a ui_strings key — docs/80 §4.9).
func _invest_block_reason() -> String:
	if _port_id.is_empty():
		return ""
	var module: Variant = _allegiance_module("invest_block_reason")
	if module == null:
		return ""
	return str(module.call("invest_block_reason", _port_id))


## The disabled Invest tooltip: the blocked key plus, for the
## allowance-exhausted state, the `market.invest_gate.allowance` hint
## (month-to-date vs the 2,000g cap, decision 26). `month_invested` is read
## defensively — the key arrives with save v7 (task V); 0 before that.
func _invest_gate_text(reason: String) -> String:
	if reason == "market.invest_gate.exhausted":
		return "%s\n%s" % [
			I18n.t_key(reason),
			I18n.fmt("market.invest_gate.allowance", {
				"invested": format_thousands(_month_invested_here()),
				"cap": format_thousands(INVEST_MONTHLY_CAP),
			}),
		]
	if reason == "market.invest_gate.blocked":
		var alignment := _effective_alignment()
		var nation_name := "-" if alignment.is_empty() else I18n.t(
			DataLoader.get_nation(alignment).get("name", {}))
		return I18n.fmt(reason, {"nation": nation_name})
	return I18n.t_key(reason)


func _month_invested_here() -> int:
	var value: Variant = GameState.get("month_invested")
	if value is Dictionary:
		return int((value as Dictionary).get(_port_id, 0))
	return 0


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
	layout.add_child(_captains_header)
	_captains_box = VBoxContainer.new()
	_captains_box.name = "CaptainsRows"
	layout.add_child(_captains_box)


## Re-reads the docked traders sighted at this port's market (the seeded
## 60/40 + 75% rolls live in `npc_intel.gd`; this only renders). The rebuild
## fingerprints the docked fleet set (pure reads) and re-runs — labels and
## the one-familiarity-per-row `sightings()` accrual — only when the fleets
## or the day moved; a `gold_changed` churn does neither. A locale change
## resets [member _captains_key] to force a re-render.
func _refresh_captains() -> void:
	if _captains_box == null:
		return
	var fleet_ids := PackedStringArray()
	for fleet in NpcIntelLib.docked_fleets(_port_id):
		fleet_ids.append(str(fleet.get("id", "")))
	var key := "%s#%d#%s" % [_port_id, int(GameState.day), ",".join(fleet_ids)]
	if key == _captains_key:
		return
	_captains_key = key
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
		empty.theme_type_variation = "Dim"
		_captains_box.add_child(empty)
		return
	for entry in _captain_rows:
		var row := HBoxContainer.new()
		row.name = "Captain_%s" % str(entry["id"])
		# §4.8 role badge on the sighting row (the flat fallback renders
		# nothing until the registry fills at W4-D).
		_attach_role_badge(row, str(entry["role"]))
		var label := Label.new()
		label.text = "%s · %s" % [str(entry["name"]),
			I18n.t_key("captain.role.%s" % str(entry["role"]))]
		row.add_child(label)
		_captains_box.add_child(row)


## Prepends the §4.8 `role_{role}` badge to a sighting row (32px inline in
## the row); an absent id adds nothing (the flat fallback).
func _attach_role_badge(row: HBoxContainer, role: String) -> void:
	if role.is_empty():
		return
	var texture := UiKitLib.icon_texture("role_%s" % role)
	if texture == null:
		return
	var icon := TextureRect.new()
	icon.name = "RoleBadge"
	icon.texture = texture
	icon.custom_minimum_size = Vector2(32, 32)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	row.add_child(icon)
	row.move_child(icon, 0)


# --- Captain-intel rows (docs/30-* §4.8, Phase 8 W5-C) -----------------------

## `I18n` text for an intel key this screen also carries in
## [constant INTEL_FALLBACK_STRINGS] until W6-D merges it.
static func _intel_text(key: String) -> String:
	if DataLoader.ui_strings.has(key):
		return I18n.t_key(key)
	return I18n.t(INTEL_FALLBACK_STRINGS.get(key, {}))


## The intel rows currently rendered (`{captain_id, name, role, nation_id,
## stance, free, dest_port_id, dest_port_name}` — the headless seam; `free`
## is the stance ≥ +2 hail-intel qualifier, docs/30-* §4.8).
func intel_rows() -> Array:
	return _intel_rows.duplicate()


## Builds the intel section shell once (header + rows box) under the merchant
## captains section.
func _build_intel_section() -> void:
	var layout: VBoxContainer = $Layout/VBox
	_intel_header = Label.new()
	_intel_header.name = "IntelHeader"
	layout.add_child(_intel_header)
	_intel_box = VBoxContainer.new()
	_intel_box.name = "IntelRows"
	layout.add_child(_intel_box)


## Re-reads the captain-bearing fleets sighted at this port (docked + present
## across every facility — the same npc_intel seeded rolls the world map and
## the facility rows read, queried without `sightings()`' familiarity side
## effect so re-opening the market never double-charges). Stance ≥ +2 rows
## carry the free next-lane hint; the rows are read-only intel (viewing them
## changes no state).
## Re-renders only when the rows' **data changed**: recomputed from pure
## reads (docked fleets, presence, stance), fingerprinted into the section
## key, and the labels rebuild only when the fingerprint moves (a stance
## shift re-renders; a `gold_changed` churn does not).
func _refresh_intel() -> void:
	if _intel_box == null:
		return
	_intel_rows = []
	if not _port_id.is_empty() and not GameState.player.is_empty():
		var seen: Dictionary = {}
		for fleet in NpcIntelLib.docked_fleets(_port_id):
			if not NpcIntelLib.is_present(fleet, _port_id):
				continue
			var captain_id := str(fleet.get("captain_id", ""))
			if captain_id.is_empty() or seen.has(captain_id):
				continue
			seen[captain_id] = true
			var canon := CaptainsLib.captain(captain_id)
			var dest_port := str(fleet.get("dest_port_id", ""))
			var dest_name := I18n.t(DataLoader.get_port(dest_port).get("name", {})) \
				if not dest_port.is_empty() else "-"
			var stance := CaptainsLib.stance(captain_id)
			_intel_rows.append({
				"captain_id": captain_id,
				"name": I18n.t(canon.get("name", {})),
				"role": str(fleet.get("role", "")),
				"nation_id": str(fleet.get("nation_id", "")),
				"stance": stance,
				"free": stance >= INTEL_FREE_STANCE,
				"dest_port_id": dest_port,
				"dest_port_name": dest_name,
			})
	var key := "%s#%s" % [_port_id, str(_intel_rows)]
	if key == _intel_key:
		return
	_intel_key = key
	for child in _intel_box.get_children():
		_intel_box.remove_child(child)
		child.queue_free()
	if _intel_rows.is_empty():
		_intel_header.visible = false
		return
	_intel_header.visible = true
	_intel_header.text = _intel_text("market.intel.header")
	for row in _intel_rows:
		var line := "%s · %s" % [str(row["name"]),
			I18n.t_key("captain.role.%s" % str(row["role"]))]
		if bool(row["free"]):
			line += " · %s" % _intel_text("market.intel.free")\
				.replace("{port}", str(row["dest_port_name"]))
		var box := HBoxContainer.new()
		box.name = "Intel_%s" % str(row["captain_id"])
		_attach_role_badge(box, str(row["role"]))
		var label := Label.new()
		label.text = line
		box.add_child(label)
		_intel_box.add_child(box)


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
	_selected_good = good_id
	var field: LineEdit = refs["qty"]
	var ceiling := _qty_ceiling(TradeEngineLib.sell_max(good_id))
	_set_field_text(field, _sanitize(text, ceiling))
	_apply_row_limits(good_id)
	_refresh_info_strip()


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
	_selected_good = good_id
	var buy_max := TradeEngineLib.buy_max(_port_id, good_id) if not _port_id.is_empty() else 0
	var ceiling := maxi(buy_max, TradeEngineLib.sell_max(good_id))
	var value := ceiling if preset < 0 else mini(preset, ceiling)
	_set_field_text(refs["qty"] as LineEdit, "" if value <= 0 else str(value))
	_apply_row_limits(good_id)
	_refresh_info_strip()


## Clicking anywhere on a row selects it (docs/30 §4.8, 2026-11-03): the
## info strip's totals and tax lines follow the selection. The row's filter
## is PASS and its buttons/field consume their own clicks, so this fires
## only on the row's empty space.
func _on_row_gui_input(event: InputEvent, good_id: String) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index \
				== MOUSE_BUTTON_LEFT:
		select_good(good_id)


## Selects `good_id` as the info strip's subject (the click path and the
## suite's seam). Unknown ids are ignored.
func select_good(good_id: String) -> void:
	if not _rows.has(good_id):
		return
	_selected_good = good_id
	_refresh_info_strip()


## Enter in the quantity field submits the **Buy** side (docs/30 §4.4,
## 2026-11-03) — exactly like pressing the Buy button; a disabled Buy means
## a no-op (§6 "no dialog spam").
func _on_qty_submitted(_text: String, good_id: String) -> void:
	var refs: Dictionary = _rows.get(good_id, {})
	if refs.is_empty():
		return
	var buy: Button = refs["buy"]
	if not buy.disabled:
		_on_buy(good_id)


func _on_buy(good_id: String) -> void:
	var qty := row_qty(good_id)
	if qty <= 0 or qty > TradeEngineLib.buy_max(_port_id, good_id):
		return
	if TradeEngineLib.buy(_port_id, good_id, qty):
		var good: Dictionary = DataLoader.get_good(good_id)
		# docs/30 §4.4 (2026-11-03): the trade is booked — the field clears
		# so a repeated click can never repeat it. The engine's gold/fleet
		# emissions fired *inside* buy() (before this clear), so the row's
		# own states re-apply here; the strip drops the stale totals.
		_set_field_text(_rows[good_id]["qty"] as LineEdit, "")
		_apply_row_limits(good_id)
		_refresh_info_strip()
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
		# Same clear-after-success rule as the buy side (docs/30 §4.4).
		_set_field_text(_rows[good_id]["qty"] as LineEdit, "")
		_apply_row_limits(good_id)
		_refresh_info_strip()
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
	# The cached captain/intel sections carry localized text — drop their
	# (port, day) caches so _refresh re-renders them in the new locale.
	_captains_key = ""
	_intel_key = ""
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


## Transient bottom-center toast (docs/80 §4.7: 2.5s, max one visible)
## through the kit toast atom (§4.9) — the atom owns the lifetime, the
## §4.7.17 fades and the max-1 rule, and guards every access against a
## screen freed mid-toast.
func _show_toast(text: String) -> void:
	UiKitLib.toast(self, text)


## Successful trade feedback (docs/30 §4.7 "flashes the gold readout"): the
## label lifts toward the kit's §4.7.17 flash tint and settles back. Purely
## visual (modulate only — never layout), gated by `UiMotion` so instant
## mode sets the end state immediately.
func _flash_gold() -> void:
	if _gold == null:
		return
	var tint := Color.WHITE.lerp(PaletteLib.ACCENT, UiKitLib.FLASH_LERP)
	if _gold_tween != null and _gold_tween.is_valid():
		_gold_tween.kill()
	_gold.modulate = tint
	if not UiMotionLib.enabled:
		_gold.modulate = Color.WHITE
		return
	_gold_tween = create_tween()
	_gold_tween.tween_interval(UiMotionLib.dur(350))
	_gold_tween.tween_property(_gold, "modulate", Color.WHITE, 0.0)


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


func _exit_tree() -> void:
	if EventBus.locale_changed.is_connected(_on_locale_changed):
		EventBus.locale_changed.disconnect(_on_locale_changed)
	if EventBus.gold_changed.is_connected(_on_gold_changed):
		EventBus.gold_changed.disconnect(_on_gold_changed)
	if EventBus.fleet_changed.is_connected(_on_fleet_changed):
		EventBus.fleet_changed.disconnect(_on_fleet_changed)
	if EventBus.market_changed.is_connected(_on_market_changed):
		EventBus.market_changed.disconnect(_on_market_changed)
