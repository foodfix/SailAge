extends Node
## Task M (Phase 7) screen-level market + tavern-telegraph suite
## (docs/IMPLEMENT-Phase7.md task M; docs/30-* §4.8; docs/80-* §4.7.11,
## §4.7.14, §4.7.15, §4.9). NEW suite, M-owned, so W3 shares no suite files
## (`tools/test_trade.*` is L's and is being re-baselined against the
## listing-rule behavior change — correction 7).
##
##   godot --headless res://tools/test_market_screen.tscn
##
## Covers: the listing rule (unlisted goods never render), the ★ 特产 badge +
## header, the 不收购 sell-disabled own produces, the grayed exclusive rows
## (dev ≥ 2 + alignment), the 4-state tariff badge, the per-side tax lines,
## the three-state Invest button (decision 26), and the `"investment"`
## telegraph rows (appear / expire / band-scope). Allegiance states beyond
## the §4.9 guard defaults are reached through the documented test seams
## (`market_screen.gd` / `npc_intel.gd` `allegiance_override`), so this suite
## stays green before, with, and after L's module lands.
##
## `UI_STRING_SEED` carries the §4.7.15 zh/en pairs **verbatim** and seeds
## only the keys the orchestrator has not merged yet (a no-op after the
## merge) — `data/ui_strings.json` itself is orchestrator-owned and is not
## edited here.
##
## Exits 0 when every check passes, 1 otherwise.

const EconomyLib := preload("res://scripts/port/economy.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const NpcIntelLib := preload("res://scripts/world/npc_intel.gd")
const MarketScreenLib := preload("res://scenes/port/market_screen.gd")
const MarketScene := preload("res://scenes/port/market_screen.tscn")
const TavernScene := preload("res://scenes/port/tavern_screen.tscn")
const PaletteLib := preload("res://scripts/palette.gd")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

## docs/80-* §4.7.15 — the M subset, verbatim (orchestrator-merge contract).
const UI_STRING_SEED := {
	"market.specialty.badge": {"zh": "特产", "en": "Specialty"},
	"market.specialty.header": {"zh": "特产:{names}",
		"en": "Specialties: {names}"},
	"market.specialty.more": {"zh": "另有 {count} 种", "en": "+{count} more"},
	"market.total.buy": {"zh": "买入 {qty} {name} 共 {gold} 金",
		"en": "Buy {qty} {name}: {gold}g"},
	"market.total.sell": {"zh": "卖出 {qty} {name} 得 {gold} 金",
		"en": "Sell {qty} {name}: {gold}g"},
	"market.not_bought": {"zh": "不收购", "en": "Not bought here"},
	"market.tax.badge.in_sphere": {"zh": "势力内 5%", "en": "In sphere 5%"},
	"market.tax.badge.exempt": {"zh": "免税", "en": "Tax-free"},
	"market.tax.badge.foreign": {"zh": "外国 20%", "en": "Foreign 20%"},
	"market.tax.badge.unallied": {"zh": "未同盟 20%", "en": "Unallied 20%"},
	"market.tax.buy_line": {"zh": "买入关税({rate}%):−{gold} 金",
		"en": "Buy tariff ({rate}%): −{gold} gold"},
	"market.tax.sell_line": {"zh": "卖出关税({rate}%):−{gold} 金",
		"en": "Sell tariff ({rate}%): −{gold} gold"},
	"market.exclusive.locked": {"zh": "同盟专营:同盟且发展度 ≥ 2 后开放",
		"en": "Allegiance-exclusive: opens when aligned at dev ≥ 2"},
	"market.invest_gate.allowance": {"zh": "本月已投 {invested} / {cap} 金",
		"en": "Invested {invested} / {cap}g this month"},
	"market.invest_gate.exhausted": {"zh": "本月投资上限已达",
		"en": "Monthly investment allowance used up"},
	"market.invest_gate.blocked": {"zh": "声望不足或与{nation}悬赏在身,无法投资",
		"en": "Blocked: rep below 0 or a bounty with {nation}"},
	"tavern.invest.header": {"zh": "投资动向", "en": "Investment news"},
	"tavern.invest.row": {"zh": "{nation} 在 {port} 投资 {amount} 金",
		"en": "{nation} invested {amount}g in {port}"},
}

var _failures: Array[String] = []
var _checks := 0

## Script-load gate paths (integration-bounce hardening): a screen script
## that fails to PARSE instantiates as a bare Control, every widget check
## silently no-ops on Nil errors, and the harness still prints ALL PASS with
## a handful of checks. The suite therefore loads each script explicitly and
## refuses to run the widget cases unless every one loads as a Script and
## defines the methods/properties these cases exercise.
const MARKET_SCREEN_PATH := "res://scenes/port/market_screen.gd"
const TAVERN_SCREEN_PATH := "res://scenes/port/tavern_screen.gd"
const NPC_INTEL_PATH := "res://scripts/world/npc_intel.gd"


## A stand-in for task L's allegiance module (docs/80-* §4.16 contract) —
## fed to the screens' `allegiance_override` test seams.
class FakeAllegiance extends RefCounted:
	var dev_value := 0
	var alignment_value := ""
	var tariff_value := 2000
	var block_value := ""
	var investments: Array = []

	func dev(_port_id: String) -> int:
		return dev_value

	func effective_alignment(_port_id: String) -> String:
		return alignment_value

	func tariff_mille(_port_id: String, _nation_id: String) -> int:
		return tariff_value

	func invest_block_reason(_port_id: String) -> String:
		return block_value

	func last_month_investments() -> Array:
		return investments.duplicate()


func _ready() -> void:
	_seed_ui_strings()
	if not _scripts_loaded():
		_report()  # fail fast — the widget cases cannot run without the scripts
		return
	_test_string_seeds()
	_test_listing_rule()
	_test_specialty_badge_and_header()
	_test_alignment_and_order()
	_test_not_bought_rows()
	_test_exclusive_rows()
	_test_tax_badge_states()
	_test_tax_lines()
	_test_info_strip_interactions()
	_test_invest_states()
	_test_invest_button_states_reachable()
	_test_telegraph_rows()
	_test_tavern_renders_investment()
	_test_locale_swap()
	_test_arrow_gates()
	_test_memory_arrows()
	_report()


# --- Script-load gate -------------------------------------------------------

func _scripts_loaded() -> bool:
	var ok := true
	var market: Variant = ResourceLoader.load(MARKET_SCREEN_PATH)
	ok = _script_ok(market, MARKET_SCREEN_PATH, [
		"row_goods_ids", "row", "row_qty", "type_qty", "press_qty_preset",
		"press_buy", "press_sell", "press_invest", "refresh",
		"tax_badge_key", "tax_badge_state", "tax_line_texts",
		"total_line_texts", "info_strip_text", "select_good",
		"specialty_header_text", "row_arrows",
	], ["route_to_port"]) and ok
	var tavern: Variant = ResourceLoader.load(TAVERN_SCREEN_PATH)
	ok = _script_ok(tavern, TAVERN_SCREEN_PATH, [
		"select_tab", "active_tab", "invest_rows", "rumor_texts", "refresh",
	], ["route_to_port"]) and ok
	var intel: Variant = ResourceLoader.load(NPC_INTEL_PATH)
	ok = _script_ok(intel, NPC_INTEL_PATH, [
		"rumor_rows", "investment_rows",
	], []) and ok
	return ok


## One script's load + shape: is a Script, defines every listed method and
## property. Each miss is a failed check (so a parse-arity regression shows
## as RED with the reason, never as a silently-short ALL PASS).
func _script_ok(script: Variant, path: String, methods: Array,
		properties: Array) -> bool:
	if not (script is Script):
		_check(false, "%s loads as a Script (parse error? got %s)"
			% [path.get_file(), str(script)])
		return false
	var defined: Array = []
	for info in (script as Script).get_script_method_list():
		defined.append(str(info.get("name", "")))
	for method in methods:
		_check(defined.has(str(method)),
			"%s defines %s()" % [path.get_file(), str(method)])
	var props: Array = []
	for info in (script as Script).get_script_property_list():
		props.append(str(info.get("name", "")))
	for prop in properties:
		_check(props.has(str(prop)),
			"%s defines the %s seam property" % [path.get_file(), str(prop)])
	return (script is Script)


# --- Fixtures --------------------------------------------------------------

func _seed_ui_strings() -> void:
	# Interim: seed only the keys the orchestrator has not merged yet; the
	# values are §4.7.15 verbatim, so the post-merge table answers identically.
	for key in UI_STRING_SEED:
		if not DataLoader.ui_strings.has(key):
			DataLoader.ui_strings[key] = UI_STRING_SEED[key].duplicate()


## A livable run docked at `port_id` as `nation_id` (the test_trade fixture,
## parameterized for the allegiance states).
func _make_run(port_id: String, gold: int = 10000,
		nation_id: String = "portugal") -> void:
	GameState.player = {
		"nation_id": nation_id,
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {},
	}
	for nation in NATIONS:
		GameState.player["reputation"][nation] = 0
	GameState.fleet = [FleetLib.new_ship("caravel", 0)]
	GameState.day = 1
	GameState.gold = gold
	GameState.morale = 70
	GameState.current_port = port_id
	GameState.port_investments = {}
	GameState.known_ports = [port_id]
	GameState.market_stocks = EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list
	)
	GameState.market_events = []
	GameState.npc_fleets = []
	GameState.npc_port_log = []
	EconomyLib.reset_overrides()
	var port: Dictionary = DataLoader.get_port(port_id)
	GameState.world = {
		"position": port.get("position", {"x": 0, "y": 0}).duplicate(),
		"clock_fraction": 0.5,
		"weather": "fair",
	}


func _instantiate_market() -> Control:
	var screen: Control = MarketScene.instantiate()
	# Belt-and-braces for the script-load gate: a scene whose script failed to
	# parse instantiates as a bare Control — fail visibly, never silently.
	# (`set` is a no-op on a property the script would define, so a bare
	# Control cannot spam errors past the failed check.)
	_check(screen.has_method("row_goods_ids"),
		"the market screen instantiates with its script attached")
	screen.set("route_to_port", false)
	add_child(screen)
	return screen


func _instantiate_tavern() -> Control:
	var screen: Control = TavernScene.instantiate()
	_check(screen.has_method("invest_rows"),
		"the tavern screen instantiates with its script attached")
	screen.set("route_to_port", false)
	add_child(screen)
	return screen


## Immediate teardown so the next fixture's EventBus emissions cannot reach a
## stale screen (the test_tavern convention).
func _drop(node: Node) -> void:
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.free()


func _listed_ids(port_id: String) -> Array:
	var port: Dictionary = DataLoader.get_port(port_id)
	var out: Array = []
	for good_id in (port.get("produces", []) as Array) \
			+ (port.get("demands", []) as Array):
		if not out.has(str(good_id)):
			out.append(str(good_id))
	return out


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
		push_error("FAIL: " + message)


func _report() -> void:
	if _failures.is_empty():
		print("ALL PASS (%d checks) — test_market_screen" % _checks)
	else:
		print("%d checks FAILED:" % _failures.size())
		for failure in _failures:
			print("  - " + failure)
	get_tree().quit(0 if _failures.is_empty() else 1)


# --- Seeds ------------------------------------------------------------------

func _test_string_seeds() -> void:
	for key in UI_STRING_SEED:
		var entry: Dictionary = DataLoader.ui_strings.get(key, {})
		_check(entry.has("zh") and entry.has("en"),
			"ui_strings answers zh+en for %s" % key)


# --- §4.7.11 listing rule ---------------------------------------------------

func _test_listing_rule() -> void:
	_make_run("lisbon")
	var screen := _instantiate_market()
	var rows: Array = screen.row_goods_ids()
	var listed := _listed_ids("lisbon")
	_check(rows.size() == listed.size(),
		"lisbon renders exactly the listed set (%d rows vs %d listed)"
			% [rows.size(), listed.size()])
	for good_id in listed:
		_check(rows.has(good_id), "listed good %s has a row" % good_id)
	# Unlisted goods never render — named cases plus a data-driven sweep.
	for unlisted in ["perfume", "silver", "tea", "pearls", "carpet"]:
		_check(not rows.has(unlisted),
			"unlisted good %s never renders at lisbon" % unlisted)
	_check(screen.row("perfume").is_empty(),
		"row() for an unlisted good is empty")
	var all_goods: Array = []
	for good in DataLoader.goods_list:
		all_goods.append(str(good.get("id", "")))
	var missing := 0
	for good_id in all_goods:
		if not listed.has(good_id) and rows.has(good_id):
			missing += 1
	_check(missing == 0,
		"no unlisted good renders at lisbon (violations: %d)" % missing)
	# Display order (docs/30 §4.8, 2026-11-03): ★ produces rows first, then
	# the rest, each group by `base_price` ascending (ties by id).
	var produces: Array = DataLoader.get_port("lisbon").get("produces", [])
	var ok_order := true
	var produce_last := -1
	var rest_last := -1
	var seen_rest := false
	for good_id in rows:
		var price := int(DataLoader.get_good(str(good_id)).get("base_price", 0))
		if produces.has(str(good_id)):
			if seen_rest or price < produce_last:
				ok_order = false
			produce_last = price
		else:
			seen_rest = true
			if price < rest_last:
				ok_order = false
			rest_last = price
	_check(ok_order,
		"rows render produces-first, each group base_price ascending")
	_drop(screen)

	# A second port lists a different set (the rule is per-port data).
	_make_run("quanzhou", 10000)
	var screen2 := _instantiate_market()
	var quanzhou_rows: Array = screen2.row_goods_ids()
	var quanzhou_listed := _listed_ids("quanzhou")
	_check(quanzhou_rows.size() == quanzhou_listed.size(),
		"quanzhou renders exactly its listed set (%d rows)"
			% quanzhou_rows.size())
	_check(quanzhou_rows.has("porcelain") and quanzhou_rows.has("raw_silk"),
		"quanzhou lists its specialties")
	_check(not quanzhou_rows.has("gems"),
		"a good quanzhou does not list does not render there")
	# The §4.8 display order holds here too: the first row is a produce.
	var quanzhou_produces: Array = DataLoader.get_port("quanzhou") \
		.get("produces", [])
	_check(quanzhou_produces.has(str(quanzhou_rows.front())),
		"the first row at a specialty port is one of its produces (%s)"
			% str(quanzhou_rows.front()))
	_drop(screen2)


# --- §4.7.11 ★ badge + header ----------------------------------------------

func _test_specialty_badge_and_header() -> void:
	_make_run("lisbon")
	var screen := _instantiate_market()
	var badge_text := "★ %s" % I18n.t_key("market.specialty.badge")
	for produced in ["wine", "salt"]:
		var badge: Label = screen.row(produced)["badge"]
		_check(badge.visible and badge.text == badge_text,
			"%s row carries the ★ badge (%s)" % [produced, badge.text])
	# The badge slot is **reserved on every row** (docs/80 §4.7.11,
	# 2026-11-03): a demand-only row keeps the slot with an empty text, so
	# all good names start at the same x.
	var demand_badge: Label = screen.row("wheat")["badge"]
	_check(demand_badge.visible and demand_badge.text == "",
		"a demand-only row keeps the reserved empty badge slot")
	_check(int(demand_badge.custom_minimum_size.x) == 56
		and int((screen.row("wine")["badge"] as Label).custom_minimum_size.x) == 56,
		"the badge slot is 56px on every row")
	var expected := I18n.fmt("market.specialty.header", {"names": ", ".join([
		I18n.t(DataLoader.get_good("wine").get("name", {})),
		I18n.t(DataLoader.get_good("salt").get("name", {})),
	])})
	_check(screen.specialty_header_text() == expected,
		"the header names both produces (%s)" % screen.specialty_header_text())
	_drop(screen)

	# Up to 3 names: quanzhou produces exactly 3 — all named.
	_make_run("quanzhou")
	var screen2 := _instantiate_market()
	var names: Array[String] = []
	for member in DataLoader.get_port("quanzhou").get("produces", []):
		names.append(I18n.t(DataLoader.get_good(str(member)).get("name", {})))
	_check(screen2.specialty_header_text()
		== I18n.fmt("market.specialty.header", {"names": ", ".join(names)}),
		"quanzhou's header names all 3 produces (%s)"
			% screen2.specialty_header_text())
	_drop(screen2)

	# A >3-produces port names exactly the first 3 (≤ 3 cap).
	var many_port := ""
	for port in DataLoader.ports_list:
		if (port.get("produces", []) as Array).size() > 3:
			many_port = str(port.get("id", ""))
			break
	_check(not many_port.is_empty(), "a >3-produces port exists in the data")
	if not many_port.is_empty():
		_make_run(many_port)
		var screen3 := _instantiate_market()
		var header: String = screen3.specialty_header_text()
		var named := 0
		for member in DataLoader.get_port(many_port).get("produces", []):
			if header.contains(I18n.t(
					DataLoader.get_good(str(member)).get("name", {}))):
				named += 1
		_check(named == 3,
			"the header caps at 3 produces at %s (named %d)" % [many_port, named])
		# And appends the `market.specialty.more` suffix (docs/30 §4.8,
		# 2026-11-03): `特产: A, B, C (另有 N 种)`.
		var produces: Array = DataLoader.get_port(many_port).get("produces", [])
		var names3: Array[String] = []
		for member in produces.slice(0, 3):
			names3.append(I18n.t(
				DataLoader.get_good(str(member)).get("name", {})))
		var expected_with_more := "%s (%s)" % [
			I18n.fmt("market.specialty.header", {"names": ", ".join(names3)}),
			I18n.fmt("market.specialty.more", {"count": produces.size() - 3}),
		]
		_check(header == expected_with_more,
			"the >3 header appends the +N suffix (%s)" % header)
		_drop(screen3)


# --- §4.8 column alignment + specialty group (2026-11-03) --------------------

## The single-source column contract: header captions and row cells come
## from one COL_SPECS table, so each caption spans exactly its cells — the
## two widths that once drifted are pinned in closed form — and every good
## name starts at the same x behind the reserved badge slot.
func _test_alignment_and_order() -> void:
	_make_run("lisbon")
	var screen := _instantiate_market()
	var header := screen.get_node(
		"Layout/VBox/TableFrame/Margin/Table/ColumnHeader")
	var col_good: Label = header.get_node("Col_good")
	_check(int(col_good.custom_minimum_size.x) == 56 + 4 + 160,
		"the Good caption spans the badge slot + gap + name width (220, got %d)"
			% int(col_good.custom_minimum_size.x))
	var col_qty: Label = header.get_node("Col_qty")
	_check(int(col_qty.custom_minimum_size.x) == 72 + 3 * 40 + 56 + 4 * 4,
		"the Qty caption spans the picker widgets + their gaps (264, got %d)"
			% int(col_qty.custom_minimum_size.x))
	# The thin divider between the produces group and the rest sits exactly
	# after the produce rows (lisbon produces 2: wine, salt).
	var rows_box: VBoxContainer = screen.get_node(
		"Layout/VBox/TableFrame/Margin/Table/GoodsScroll/GoodsRows")
	_check(rows_box.get_child(2).name == "SpecialtyDivider",
		"the divider sits between the specialty group and the rest (%s)"
			% str(rows_box.get_child(2).name))
	# A demand-only port row renders no divider before the first produce...
	# (lisbon HAS produces; a produce-less port shows none) — check wheat's
	# row index is past the divider, i.e. the group order is produces-first.
	var wheat_index := 3
	for index in rows_box.get_child_count():
		var child := rows_box.get_child(index)
		if child.name == "Row_wheat":
			wheat_index = index
	_check(wheat_index > 2, "wheat (a demand good) renders after the divider")
	_drop(screen)

	# Name-column alignment: after one layout frame every row's Name label
	# shares the same x (the badge slot never collapses).
	_make_run("lisbon")
	var screen2 := _instantiate_market()
	await get_tree().process_frame
	var name_x := -1.0
	var aligned := true
	for good_id in screen2.row_goods_ids():
		var label: Label = screen2.row(str(good_id))["name"]
		if name_x < 0.0:
			name_x = label.position.x
		elif absf(label.position.x - name_x) > 0.5:
			aligned = false
	_check(aligned and name_x > 0.0,
		"every good name aligns at x=%.1f behind the reserved badge slot"
			% name_x)
	_drop(screen2)


# --- §4.8 selected-row info strip + interactions (2026-11-03) ----------------

## The info strip's walked totals (engine `buy_cost` / `sell_gain` are the
## only source), row-click selection, Enter-submits-Buy, and the
## clear-after-success rule.
func _test_info_strip_interactions() -> void:
	# Both sides legal → both totals (a demanded good held aboard).
	_make_run("lisbon", 10000)
	var screen := _instantiate_market()
	FleetLib.add_goods("wheat", 10)
	EventBus.fleet_changed.emit()
	screen.type_qty("wheat", "10")
	var lines: PackedStringArray = screen.info_strip_text().split("\n")
	var expected_buy := I18n.fmt("market.total.buy", {
		"qty": 10, "name": I18n.t(DataLoader.get_good("wheat").get("name", {})),
		"gold": MarketScreenLib.format_thousands(
			TradeEngineLib.buy_cost("lisbon", "wheat", 10)),
	})
	var expected_sell := I18n.fmt("market.total.sell", {
		"qty": 10, "name": I18n.t(DataLoader.get_good("wheat").get("name", {})),
		"gold": MarketScreenLib.format_thousands(
			TradeEngineLib.sell_gain("lisbon", "wheat", 10)),
	})
	_check(lines.size() == 2 and str(lines[0]) == expected_buy
		and str(lines[1]) == expected_sell,
		"a two-sided row shows both walked totals (%s)"
			% screen.info_strip_text())
	# The totals are the engine's walked sums (buy_cost / sell_gain are the
	# only source — their tranche arithmetic is engine-suite territory).
	# A sell of a held good prices via sell_gain.
	_check(TradeEngineLib.sell_gain("lisbon", "wheat", 10) > 0,
		"sell_gain prices the held demanded good")
	_drop(screen)

	# Row-click selection moves the strip; a fresh row with no qty keeps it
	# hidden.
	_make_run("lisbon", 10000)
	var screen2 := _instantiate_market()
	screen2.type_qty("wine", "10")
	_check(screen2.get_node(
		"Layout/VBox/TableFrame/Margin/Table/InfoStrip").visible,
		"typing a quantity selects the row and shows the strip")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	(screen2.row("salt")["node"] as Control).gui_input.emit(click)
	_check(not screen2.get_node(
		"Layout/VBox/TableFrame/Margin/Table/InfoStrip").visible,
		"clicking another row moves the selection; its empty qty hides the strip")
	screen2.select_good("wine")
	_check(screen2.info_strip_text().contains(I18n.t(
			DataLoader.get_good("wine").get("name", {}))),
		"select_good re-arms the previous row's totals")
	# Enter submits the Buy side exactly like the button. The booking is
	# cost **plus** the §4.10 tariff (composes after all price math).
	var gold_before := GameState.gold
	screen2.type_qty("wine", "5")
	var enter_cost := TradeEngineLib.buy_cost("lisbon", "wine", 5)
	var enter_debit := enter_cost \
		+ TradeEngineLib.tax_amount("lisbon", enter_cost)
	var wine_field: LineEdit = screen2.row("wine")["qty"]
	wine_field.text_submitted.emit("5")
	_check(GameState.gold == gold_before - enter_debit,
		"Enter in the quantity field submits the Buy (−%d)" % enter_debit)
	_check(screen2.row_qty("wine") == -1,
		"the quantity field cleared after the successful buy")
	_check(not screen2.info_strip_text().contains(I18n.fmt(
			"market.total.buy", {"qty": 5,
			"name": I18n.t(DataLoader.get_good("wine").get("name", {})),
			"gold": MarketScreenLib.format_thousands(enter_cost)})),
		"the totals drop once the field cleared (strip keeps the tax context)")
	_drop(screen2)

	# The sell side clears too, and a 不收购 row never totals a sell.
	_make_run("lisbon", 10000)
	var screen3 := _instantiate_market()
	FleetLib.add_goods("wine", 10)
	EventBus.fleet_changed.emit()
	var held := FleetLib.held("wine")
	screen3.type_qty("wine", "10")
	var wine_buy_line := I18n.fmt("market.total.buy", {
		"qty": 10, "name": I18n.t(DataLoader.get_good("wine").get("name", {})),
		"gold": MarketScreenLib.format_thousands(
			TradeEngineLib.buy_cost("lisbon", "wine", 10)),
	})
	var sell_lines: PackedStringArray = screen3.info_strip_text().split("\n")
	_check(sell_lines.size() == 1 and str(sell_lines[0]) == wine_buy_line,
		"a 不收购 row totals only the buy side (%s)" % screen3.info_strip_text())
	_check(screen3.press_sell("wine") == false,
		"the 不收购 sell stays a protected no-op")
	_check(FleetLib.held("wine") == held, "nothing sold")
	# Sell path with a sellable good: wheat clears the field on success.
	FleetLib.add_goods("wheat", 10)
	EventBus.fleet_changed.emit()
	screen3.type_qty("wheat", "10")
	var wheat_held := FleetLib.held("wheat")
	_check(screen3.press_sell("wheat"), "the wheat sell goes through")
	_check(FleetLib.held("wheat") == wheat_held - 10,
		"the sell booked all 10 wheat")
	_check(screen3.row_qty("wheat") == -1,
		"the quantity field cleared after the successful sell")
	_drop(screen3)


# --- §4.7.11 不收购 rows ----------------------------------------------------

func _test_not_bought_rows() -> void:
	_make_run("lisbon", 10000)
	var screen := _instantiate_market()
	var wine_sell: Button = screen.row("wine")["sell"]
	_check(wine_sell.disabled, "lisbon (wine producer) disables Sell on wine")
	_check(wine_sell.tooltip_text == I18n.t_key("market.not_bought"),
		"the Sell reason is 不收购 (%s)" % wine_sell.tooltip_text)
	screen.type_qty("wine", "5")
	_check(not screen.press_sell("wine"),
		"press_sell on a 不收购 row is a protected no-op")
	_check(FleetLib.held("wine") == 0, "the no-op sold nothing")
	# The Buy side is unaffected by 不收购 (the port still sells to you).
	var wine_buy: Button = screen.row("wine")["buy"]
	_check(not wine_buy.disabled, "Buy stays available on a 不收购 row")
	# A demanded good sells normally once held.
	_make_run("lisbon", 10000)
	var screen2 := _instantiate_market()
	FleetLib.add_goods("wheat", 10)
	EventBus.fleet_changed.emit()
	screen2.type_qty("wheat", "10")
	var wheat_sell: Button = screen2.row("wheat")["sell"]
	_check(not wheat_sell.disabled,
		"a demanded good (wheat) is sellable at lisbon")
	_check(wheat_sell.tooltip_text.is_empty(),
		"no reason on an allowed sell")
	_drop(screen2)
	_drop(screen)


# --- §4.7.11 exclusive (专营货) rows ----------------------------------------

func _test_exclusive_rows() -> void:
	# Default path — no seam, so L's merged allegiance module answers: a
	# **foreign-aligned** capital is locked (dev irrelevant). This holds under
	# the §4.9 guard defaults too (alignment falls back to the port's data
	# nation), so the check is stable across merge orders.
	_make_run("london", 100000)
	var screen := _instantiate_market()
	for exclusive in ["porcelain", "spices", "lacquerware"]:
		var row: Dictionary = screen.row(exclusive)
		var buy: Button = row["buy"]
		var sell: Button = row["sell"]
		_check(buy.disabled and sell.disabled,
			"%s row is gated at a foreign-aligned port" % exclusive)
		var lock_note := I18n.t_key("market.exclusive.locked")
		_check(buy.tooltip_text == lock_note and sell.tooltip_text == lock_note,
			"%s rows show the lock note (%s)" % [exclusive, buy.tooltip_text])
		var name_color: Color = (row["name"] as Label).get_theme_color("font_color")
		_check(name_color == PaletteLib.PANEL_LINE,
			"%s row is grayed (PANEL_LINE)" % exclusive)
		# The whole row grays (docs/80 §4.7.11, 2026-11-03) and is inert:
		# the quantity field and presets take no input either.
		for cell_key in ["stock", "trend", "marginal", "have"]:
			_check((row[cell_key] as Label).get_theme_color("font_color")
				== PaletteLib.PANEL_LINE,
				"%s row's %s cell is grayed" % [exclusive, cell_key])
		var field: LineEdit = row["qty"]
		_check(not field.editable,
			"%s row takes no quantity input while locked" % exclusive)
		var presets: Dictionary = row["qty_buttons"]
		var presets_off := true
		for key in presets:
			if not (presets[key] as Button).disabled:
				presets_off = false
		_check(presets_off, "%s row's presets are disabled while locked" % exclusive)
	_check(not screen.press_buy("porcelain"),
		"press_buy on a locked exclusive row is a protected no-op")
	# A non-exclusive demanded good is not grayed.
	var wheat_row: Dictionary = screen.row("wheat")
	screen.type_qty("wheat", "10")
	_check(not (wheat_row["buy"] as Button).disabled,
		"a non-exclusive row is unaffected by the exclusive gate")
	_check((wheat_row["name"] as Label).get_theme_color("font_color")
		== PaletteLib.TEXT, "a non-exclusive row stays TEXT-colored")
	_drop(screen)

	# dev ≥ 2 + effective alignment == player nation unlocks the rows.
	_make_run("lisbon", 100000)
	var fake := FakeAllegiance.new()
	fake.dev_value = 3
	fake.alignment_value = "portugal"
	MarketScreenLib.allegiance_override = fake
	var screen2 := _instantiate_market()
	var porcelain_buy: Button = screen2.row("porcelain")["buy"]
	screen2.type_qty("porcelain", "1")
	_check(not porcelain_buy.disabled,
		"dev 3 + own alignment unlocks the exclusive Buy")
	_check((screen2.row("porcelain")["name"] as Label)
		.get_theme_color("font_color") == PaletteLib.TEXT,
		"the unlocked row is no longer grayed")
	_check((screen2.row("porcelain")["qty"] as LineEdit).editable,
		"the unlocked row's quantity field re-arms")
	_drop(screen2)

	# Foreign alignment keeps the lock even at dev 3.
	fake.alignment_value = "england"
	var screen3 := _instantiate_market()
	_check((screen3.row("porcelain")["buy"] as Button).disabled,
		"a foreign-aligned dev-3 port keeps exclusive rows locked")
	_drop(screen3)
	MarketScreenLib.allegiance_override = null

	# Precedence: an own-produce exclusive sells 不收购 (not the lock note)
	# once unlocked — macau produces porcelain.
	_make_run("macau", 10000)
	fake = FakeAllegiance.new()
	fake.dev_value = 0
	fake.alignment_value = "portugal"
	MarketScreenLib.allegiance_override = fake
	var screen4 := _instantiate_market()
	_check((screen4.row("porcelain")["sell"] as Button).tooltip_text
		== I18n.t_key("market.exclusive.locked"),
		"macau porcelain starts exclusive-locked (guard dev 0)")
	fake.dev_value = 2
	screen4.refresh()
	FleetLib.add_goods("porcelain", 5)
	EventBus.fleet_changed.emit()
	screen4.type_qty("porcelain", "5")
	_check((screen4.row("porcelain")["sell"] as Button).tooltip_text
		== I18n.t_key("market.not_bought"),
		"unlocked own-produce exclusive sells with 不收购 (not the lock note)")
	_drop(screen4)
	MarketScreenLib.allegiance_override = null


# --- §4.7.11 tax badge (4 states) ------------------------------------------

func _test_tax_badge_states() -> void:
	# The derivation matrix (docs/80 §4.7.11: 0 → 免税, 500 → 势力内,
	# 2000 → foreign vs unallied vs the own-nation display case).
	var cases := [
		[0, "portugal", "portugal", "market.tax.badge.exempt"],
		[500, "portugal", "portugal", "market.tax.badge.in_sphere"],
		[2000, "spain", "portugal", "market.tax.badge.foreign"],
		[2000, "", "portugal", "market.tax.badge.unallied"],
		[2000, "portugal", "portugal", "market.tax.badge.in_sphere"],
	]
	for case in cases:
		var key: String = MarketScreenLib.tax_badge_key(
			int(case[0]), str(case[1]), str(case[2]))
		_check(key == str(case[3]),
			"badge key (%d, %s, %s) == %s (got %s)"
				% [int(case[0]), str(case[1]), str(case[2]),
				str(case[3]), key])

	# Screen default path (no module): lisbon reads in-sphere, london foreign,
	# unallied quanzhou reads 未同盟.
	_make_run("lisbon")
	var screen := _instantiate_market()
	_check(screen.tax_badge_state()["key"] == "market.tax.badge.in_sphere",
		"lisbon's default badge is 势力内 (5%% merged, same key as the 2000+own-nation default)")
	_check(screen.tax_badge_state()["text"]
		== I18n.t_key("market.tax.badge.in_sphere"),
		"the badge text is the localized key (%s)"
			% str(screen.tax_badge_state()["text"]))
	_drop(screen)

	_make_run("london", 10000, "portugal")
	var screen2 := _instantiate_market()
	_check(screen2.tax_badge_state()["key"] == "market.tax.badge.foreign",
		"london as portugal reads 外国 20%")
	_drop(screen2)

	_make_run("quanzhou", 10000)
	var screen3 := _instantiate_market()
	_check(screen3.tax_badge_state()["key"] == "market.tax.badge.unallied",
		"unallied quanzhou reads 未同盟 20%")
	_drop(screen3)

	# Exempt and in-sphere come from the module's tariff (permit / aligned).
	_make_run("lisbon")
	var fake := FakeAllegiance.new()
	fake.tariff_value = 0
	MarketScreenLib.allegiance_override = fake
	var screen4 := _instantiate_market()
	_check(screen4.tax_badge_state()["key"] == "market.tax.badge.exempt",
		"tariff 0 (permit) reads 免税")
	_drop(screen4)
	fake.tariff_value = 500
	var screen5 := _instantiate_market()
	_check(screen5.tax_badge_state()["key"] == "market.tax.badge.in_sphere",
		"tariff 500 reads 势力内 5%")
	_drop(screen5)
	MarketScreenLib.allegiance_override = null


# --- §4.7.11 tax lines ------------------------------------------------------

func _test_tax_lines() -> void:
	_make_run("lisbon")
	var screen := _instantiate_market()
	# Today's payloads carry no tax fields → no tax lines, but the info
	# strip still shows the walked-total line (docs/30 §4.8, 2026-11-03).
	screen.type_qty("wine", "10")
	_check(screen.tax_line_texts("wine").is_empty(),
		"no tax lines without payload tax fields (pre-L)")
	var strip: Label = screen.get_node(
		"Layout/VBox/TableFrame/Margin/Table/InfoStrip")
	_check(strip.visible and screen.info_strip_text()
		== I18n.fmt("market.total.buy", {
			"qty": 10,
			"name": I18n.t(DataLoader.get_good("wine").get("name", {})),
			"gold": MarketScreenLib.format_thousands(
				TradeEngineLib.buy_cost("lisbon", "wine", 10)),
		}),
		"pre-L the strip shows exactly the walked buy total (%s)"
			% screen.info_strip_text())
	_drop(screen)

	# L's payload shape: tax_buy / tax_sell (+ tax_mille) render both lines
	# beneath the totals.
	_make_run("lisbon")
	var screen2 := _instantiate_market()
	screen2._payloads["wine"] = {
		"id": "wine", "tax_buy": 30, "tax_sell": 24, "tax_mille": 500,
	}
	var texts: Array = screen2.tax_line_texts("wine")
	_check(texts.size() == 2, "a taxed payload yields both lines")
	_check(texts[0] == I18n.fmt("market.tax.buy_line",
		{"rate": 5, "gold": "30"}), "buy line (%s)" % str(texts[0]))
	_check(texts[1] == I18n.fmt("market.tax.sell_line",
		{"rate": 5, "gold": "24"}), "sell line (%s)" % str(texts[1]))
	screen2.type_qty("wine", "10")
	_check(screen2.get_node(
		"Layout/VBox/TableFrame/Margin/Table/InfoStrip").visible,
		"the strip shows once a taxed row is selected")
	_check(screen2.info_strip_text().contains(str(texts[0])),
		"the tax lines render beneath the totals (%s)"
			% screen2.info_strip_text())
	# Without tax_mille the rate falls back to the guarded tariff; pin it to
	# 2000 through the seam (with L merged, lisbon's real tariff is 500).
	var fake := FakeAllegiance.new()
	fake.tariff_value = 2000
	MarketScreenLib.allegiance_override = fake
	screen2._payloads["salt"] = {"id": "salt", "tax_buy": 2, "tax_sell": 1}
	var fallback: Array = screen2.tax_line_texts("salt")
	_check(fallback[0].contains("20"),
		"the rate falls back to the guarded tariff 20%% (%s)" % str(fallback[0]))
	_drop(screen2)
	MarketScreenLib.allegiance_override = null


# --- §4.7.11 three-state Invest button (decision 26) ------------------------

func _test_invest_states() -> void:
	# (a) available — the guard default block reason is "".
	_make_run("lisbon", 6000)
	var screen := _instantiate_market()
	var button: Button = screen.get_node("Layout/VBox/Footer/Invest")
	_check(not button.disabled,
		"Invest is available (merged module answers \"\" at the protected capital)")
	_check(screen.press_invest(), "press_invest works in the available state")
	_check(TradeEngineLib.invested("lisbon") == 500,
		"the press invested one 500g chunk")
	_drop(screen)

	# Still available-state: the standing engine gates — broke, then capped.
	_make_run("lisbon", 499)
	var screen2 := _instantiate_market()
	var button2: Button = screen2.get_node("Layout/VBox/Footer/Invest")
	_check(button2.disabled and screen2.press_invest() == false,
		"499g cannot invest (chunk afford gate)")
	_drop(screen2)
	_make_run("lisbon", 10000)
	for click in range(10):
		# §4.1b: one hour per chunk — re-open the window between clicks.
		GameState.world["clock_fraction"] = 0.5
		TradeEngineLib.invest("lisbon")
	var screen3 := _instantiate_market()
	var button3: Button = screen3.get_node("Layout/VBox/Footer/Invest")
	_check(button3.disabled, "the §4.3 discount cap still disables Invest")
	_check(button3.tooltip_text == I18n.fmt("market.invest_cap", {"max": 10}),
		"the cap tooltip is unchanged (%s)" % button3.tooltip_text)
	_drop(screen3)

	# (b) allowance-exhausted — the block key plus the allowance hint.
	_make_run("lisbon", 10000)
	var fake := FakeAllegiance.new()
	fake.block_value = "market.invest_gate.exhausted"
	MarketScreenLib.allegiance_override = fake
	var screen4 := _instantiate_market()
	var button4: Button = screen4.get_node("Layout/VBox/Footer/Invest")
	_check(button4.disabled and not screen4.press_invest(),
		"the exhausted state disables Invest")
	var hint := I18n.fmt("market.invest_gate.allowance",
		{"invested": "0", "cap": "2,000"})
	_check(button4.tooltip_text == I18n.t_key("market.invest_gate.exhausted")
		+ "\n" + hint,
		"the exhausted tooltip carries the allowance hint (%s)"
			% button4.tooltip_text)
	_drop(screen4)

	# (c) diplomacy-blocked — the block key with the alignment nation named.
	fake.block_value = "market.invest_gate.blocked"
	fake.alignment_value = "england"
	var screen5 := _instantiate_market()
	var button5: Button = screen5.get_node("Layout/VBox/Footer/Invest")
	_check(button5.disabled and not screen5.press_invest(),
		"the blocked state disables Invest")
	_check(button5.tooltip_text == I18n.fmt("market.invest_gate.blocked",
		{"nation": "England"}),
		"the blocked tooltip names the alignment nation (%s)"
			% button5.tooltip_text)
	_drop(screen5)
	# Any other block key renders through its ui_strings key (defensive).
	fake.block_value = "market.no_gold"
	var screen6 := _instantiate_market()
	_check((screen6.get_node("Layout/VBox/Footer/Invest") as Button).tooltip_text
		== I18n.t_key("market.no_gold"),
		"an unknown block key renders as its ui_strings key")
	_drop(screen6)
	MarketScreenLib.allegiance_override = null


## The three Invest states are reachable through the public press seam even
## without digging node paths.
func _test_invest_button_states_reachable() -> void:
	_make_run("lisbon", 6000)
	var screen := _instantiate_market()
	_check(screen.press_invest(), "available: press_invest true")
	_drop(screen)
	var fake := FakeAllegiance.new()
	fake.block_value = "market.invest_gate.blocked"
	MarketScreenLib.allegiance_override = fake
	_make_run("lisbon", 6000)
	var screen2 := _instantiate_market()
	_check(not screen2.press_invest(), "blocked: press_invest false")
	_drop(screen2)
	MarketScreenLib.allegiance_override = null


# --- §4.7.14 telegraph rows (npc_intel) -------------------------------------

func _test_telegraph_rows() -> void:
	# Default: no allegiance module → no rows.
	_make_run("lisbon")
	_check(NpcIntelLib.allegiance_override == null,
		"the telegraph seam starts unset")
	var bare := false
	for row in NpcIntelLib.rumor_rows("lisbon"):
		if str(row.get("kind", "")) == "investment":
			bare = true
	_check(not bare, "no investment rows without an allegiance module")

	# An in-band investment appears; the 30-day window and band scope hold.
	var fake := FakeAllegiance.new()
	fake.investments = [{
		"port_id": "lisbon", "nation_id": "spain",
		"amount": 1500, "days_left": 30,
	}]
	NpcIntelLib.allegiance_override = fake
	var rows: Array = NpcIntelLib.rumor_rows("lisbon")
	var found := {}
	for row in rows:
		if str(row.get("kind", "")) == "investment":
			found = row
	_check(not found.is_empty(), "the lisbon investment telegraphs at lisbon")
	_check(int(found.get("amount", 0)) == 1500
		and str(found.get("nation_id", "")) == "spain",
		"the row carries nation + amount (%s)" % str(found))
	_check(str(found.get("port_name", "")) == "Lisbon",
		"the row carries the localized port name (%s)"
			% str(found.get("port_name", "")))
	_check(not NpcIntelLib.rumor_rows("oporto").is_empty()
		and _has_investment(NpcIntelLib.rumor_rows("oporto")),
		"same band (europe_atlantic): oporto's tavern sees it too")
	_check(not _has_investment(NpcIntelLib.rumor_rows("quanzhou")),
		"band scope: china_coast taverns do not see it")

	# Expiry: days_left 0 is outside the window.
	fake.investments = [{
		"port_id": "lisbon", "nation_id": "spain",
		"amount": 1500, "days_left": 0,
	}]
	_check(not _has_investment(NpcIntelLib.rumor_rows("lisbon")),
		"days_left 0 is expired — the row is gone")
	# A module that reports no day count still shows (window is the module's).
	fake.investments = [{"port_id": "lisbon", "nation_id": "spain", "amount": 1}]
	_check(_has_investment(NpcIntelLib.rumor_rows("lisbon")),
		"a row without days_left stays visible (module owns the window)")
	# Junk rows are skipped, not crashed on.
	fake.investments = ["junk", {"nation_id": "spain", "amount": 5},
		{"port_id": "nowhere", "nation_id": "spain", "amount": 5}]
	_check(not _has_investment(NpcIntelLib.rumor_rows("lisbon")),
		"non-dict, port-less and unknown-port items never render")
	NpcIntelLib.allegiance_override = null


func _has_investment(rows: Array) -> bool:
	for row in rows:
		if str(row.get("kind", "")) == "investment":
			return true
	return false


func _test_tavern_renders_investment() -> void:
	# Band-scoped rendering through the existing rumor row machinery.
	_make_run("lisbon", 1000)
	GameState.day = 12
	GameState.discoveries_found = []
	GameState.discovery_hints = {}
	var fake := FakeAllegiance.new()
	fake.investments = [{
		"port_id": "lisbon", "nation_id": "spain",
		"amount": 1500, "days_left": 30,
	}]
	NpcIntelLib.allegiance_override = fake
	var screen := _instantiate_tavern()
	screen.select_tab("rumors")
	var rows: Array = screen.invest_rows()
	_check(rows.size() == 1, "the tavern renders one investment row (%d)"
		% rows.size())
	var expected := I18n.fmt("tavern.invest.row", {
		"nation": "Spain", "port": "Lisbon", "amount": 1500,
	})
	_check(screen.rumor_texts().has(expected),
		"the row text is tavern.invest.row (%s)" % expected)
	_check(screen.get_node("Layout/VBox/Body/RumorsPanel/Scroll/Rows")
		.get_node_or_null("InvestHeader") != null,
		"the tavern.invest.header section header renders")
	_drop(screen)

	# Out-of-band taverns show nothing (and no header).
	_make_run("quanzhou", 1000)
	GameState.day = 12
	GameState.discoveries_found = []
	GameState.discovery_hints = {}
	var screen2 := _instantiate_tavern()
	screen2.select_tab("rumors")
	_check(screen2.invest_rows().is_empty(),
		"an out-of-band tavern renders no investment rows")
	_check(screen2.get_node("Layout/VBox/Body/RumorsPanel/Scroll/Rows")
		.get_node_or_null("InvestHeader") == null,
		"no section header without rows")
	_drop(screen2)

	# Expired rows do not render.
	_make_run("lisbon", 1000)
	GameState.day = 12
	GameState.discoveries_found = []
	GameState.discovery_hints = {}
	fake.investments = [{
		"port_id": "lisbon", "nation_id": "spain",
		"amount": 1500, "days_left": 0,
	}]
	var screen3 := _instantiate_tavern()
	screen3.select_tab("rumors")
	_check(screen3.invest_rows().is_empty(),
		"expired telegraphs render no rows")
	_drop(screen3)

	# Default (no module): no rows, no header, zero <key> fallbacks.
	NpcIntelLib.allegiance_override = null
	_make_run("lisbon", 1000)
	GameState.day = 12
	GameState.discoveries_found = []
	GameState.discovery_hints = {}
	var screen4 := _instantiate_tavern()
	screen4.select_tab("rumors")
	_check(screen4.invest_rows().is_empty(),
		"no telegraphs without an allegiance module")
	_check(not screen4.rumor_texts().any(
		func(text: String) -> bool: return text.begins_with("<")),
		"zero <key> fallbacks among the rumor texts")
	_drop(screen4)


# --- locale -----------------------------------------------------------------

func _test_locale_swap() -> void:
	_make_run("lisbon", 10000)
	var screen := _instantiate_market()
	var was := I18n.get_locale()
	I18n.set_locale("zh")
	_check(screen.specialty_header_text()
		== I18n.fmt("market.specialty.header", {"names": "葡萄酒, 盐"}),
		"zh: the header re-renders (%s)" % screen.specialty_header_text())
	_check((screen.row("wine")["badge"] as Label).text == "★ 特产",
		"zh: the badge re-renders")
	_check(str(screen.tax_badge_state()["text"]) == "势力内 5%",
		"zh: the tariff badge re-renders (%s)"
			% str(screen.tax_badge_state()["text"]))
	var wine_sell: Button = screen.row("wine")["sell"]
	_check(wine_sell.tooltip_text == "不收购", "zh: the 不收购 reason re-renders")
	I18n.set_locale("en")
	_check(screen.specialty_header_text()
		== I18n.fmt("market.specialty.header", {"names": "Wine, Salt"}),
		"en: the header re-renders (%s)" % screen.specialty_header_text())
	_check((screen.row("wine")["badge"] as Label).text == "★ Specialty",
		"en: the badge re-renders")
	_check(wine_sell.tooltip_text == "Not bought here",
		"en: the 不收购 reason re-renders")
	I18n.set_locale(was)
	_drop(screen)


# --- Phase 8 §4.2 arrows (appraisal-gated) ----------------------------------

## Stand-in for slot A's `Skills` module (`W3-A` pins `effective_skill(key)`).
class FakeSkills extends RefCounted:
	var values: Dictionary = {}

	func effective_skill(key: String) -> int:
		return int(values.get(key, 0))

	func skill(key: String) -> int:
		return effective_skill(key)


## Pins the player's appraisal through the trade engine's seam (the arrows'
## gates and the memory capacity both read it).
func _set_appraisal(value: int) -> void:
	var fake := FakeSkills.new()
	fake.values = {"appraisal": value, "negotiation": 0}
	TradeEngineLib.skills_override = fake


func _clear_seams() -> void:
	TradeEngineLib.skills_override = null
	TradeEngineLib.reset_price_memory()


## The profit arrow renders iff effective appraisal ≥ 30 AND the row is
## profitable vs `base_price` (buy < base → "down", sell > base → "up");
## below the gate no arrow renders and the §4.8 flow-trend glyph is untouched.
func _test_arrow_gates() -> void:
	# Below the ≥ 30 gate: no arrows, the flow-trend logic intact.
	_make_run("lisbon")
	TradeEngineLib.reset_price_memory()
	_set_appraisal(10)
	var screen := _instantiate_market()
	var arrows: Dictionary = screen.row_arrows("wine")
	_check(str(arrows["profit"]) == "" and str(arrows["memory"]) == "",
		"appraisal 10: no arrows render (got %s)" % str(arrows))
	_check((screen.row("wine")["profit_arrow"] as Label).text == ""
		and (screen.row("wine")["memory_arrow"] as Label).text == "",
		"the arrow glyphs stay empty below the gates")
	# The flow-trend logic (§4.8) is intact: drain lisbon wine under its
	# rest 160 and the ▲ glyph renders as before.
	EconomyLib.set_stock("lisbon", "wine", 100)
	screen.refresh()
	_check((screen.row("wine")["trend"] as Label).text
		== I18n.t_key("market.stock.trend_up"),
		"below the gates only the flow-trend glyph renders (%s)"
			% str((screen.row("wine")["trend"] as Label).text))
	_drop(screen)

	# One below the gate, one at it: the gate is the locked ≥ 30.
	_set_appraisal(29)
	var screen2 := _instantiate_market()
	_check(str(screen2.row_arrows("wine")["profit"]) == "",
		"appraisal 29 stays below the profit-arrow gate")
	_drop(screen2)
	# Back to the §5 rest (the flow-trend block drained it to 100).
	EconomyLib.set_stock("lisbon", "wine", 160)
	_set_appraisal(30)
	var screen3 := _instantiate_market()
	arrows = screen3.row_arrows("wine")
	_check(str(arrows["profit"]) == "down",
		"appraisal 30: lisbon wine buys 21 < base 30 → down (got %s)"
			% str(arrows))
	_check((screen3.row("wine")["profit_arrow"] as Label).text == "↓",
		"the buy-cheap arrow renders the ↓ glyph")
	_check(str(arrows["memory"]) == "",
		"appraisal 30 < 60: the memory arrow never renders")
	# A row profitable neither way shows nothing: lisbon wheat buys 10 > base
	# 8 and sells 8 (not > base) — no arrow.
	_check(str(screen3.row_arrows("wheat")["profit"]) == "",
		"a row profitable neither way shows no arrow")
	_drop(screen3)

	# The dear-consumer direction: london wine at the §5 rest 40 sells
	# 31 > base 30 → "up" (its 39 buy is above base, so no buy arrow).
	_make_run("london")
	EconomyLib.set_stock("london", "wine", 40)
	_set_appraisal(30)
	var screen4 := _instantiate_market()
	arrows = screen4.row_arrows("wine")
	_check(str(arrows["profit"]) == "up",
		"london wine sells 31 > base 30 → up (got %s)" % str(arrows))
	_check((screen4.row("wine")["profit_arrow"] as Label).text == "↑",
		"the sell-dear arrow renders the ↑ glyph")
	_drop(screen4)
	_clear_seams()


## The other-port memory arrow renders iff effective appraisal ≥ 60 and the
## memory holds a foreign entry; the comparator is the MOST-RECENT foreign
## entry for the good.
func _test_memory_arrows() -> void:
	# Below the ≥ 60 gate a seeded foreign entry changes nothing.
	_make_run("lisbon", 10000)
	TradeEngineLib.reset_price_memory()
	_set_appraisal(50)
	_check(TradeEngineLib.buy("lisbon", "wine", 10),
		"seed: buy wine at lisbon (memory 21)")
	_make_run("london", 10000)
	EconomyLib.set_stock("london", "wine", 40)  # the §5 rest: buy 39 / sell 31
	_set_appraisal(50)
	var screen := _instantiate_market()
	_check(str(screen.row_arrows("wine")["memory"]) == "",
		"appraisal 50 with a foreign entry: no memory arrow yet")
	_drop(screen)

	# At the gate: london wine buys 39 > remembered lisbon 21 → "up", next
	# to the still-rendering profit arrow.
	_set_appraisal(60)
	var screen2 := _instantiate_market()
	var arrows: Dictionary = screen2.row_arrows("wine")
	_check(str(arrows["memory"]) == "up",
		"appraisal 60: london 39 > remembered lisbon 21 → up (got %s)"
			% str(arrows))
	_check(str(arrows["profit"]) == "up",
		"the profit arrow renders alongside the memory arrow")
	_check((screen2.row("wine")["memory_arrow"] as Label).text == "↑",
		"the memory arrow renders the ↑ glyph")
	_drop(screen2)

	# The reverse leg: remembered london 39, local lisbon 21 → "down".
	_make_run("london", 100000)
	_set_appraisal(60)
	_check(TradeEngineLib.buy("london", "wine", 10),
		"seed: buy wine at london (memory 39)")
	_make_run("lisbon", 100000)
	_set_appraisal(60)
	var screen3 := _instantiate_market()
	_check(str(screen3.row_arrows("wine")["memory"]) == "down",
		"lisbon 21 < remembered london 39 → down (got %s)"
			% str(screen3.row_arrows("wine")))
	_drop(screen3)

	# The comparator is the MOST-RECENT foreign entry: lisbon 21 then
	# valencia 39 (last-seen) — london's own 39 equals it → no arrow.
	_make_run("lisbon", 100000)
	EconomyLib.set_stock("valencia", "wine", 40)
	TradeEngineLib.reset_price_memory()
	_set_appraisal(60)
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "seed lisbon wine @21")
	_check(TradeEngineLib.buy("valencia", "wine", 10), "seed valencia wine @39")
	_check(int(TradeEngineLib.memory_other_port_entry("london", "wine")
		.get("price", 0)) == 39,
		"the valencia entry is the most-recent foreign memory for wine")
	_make_run("london", 100000)
	EconomyLib.set_stock("london", "wine", 40)
	_set_appraisal(60)
	var screen4 := _instantiate_market()
	_check(str(screen4.row_arrows("wine")["memory"]) == "",
		"london 39 equals the last-seen foreign price → no arrow (got %s)"
			% str(screen4.row_arrows("wine")))
	_drop(screen4)
	_clear_seams()
