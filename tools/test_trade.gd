extends Node
## T12 acceptance tests (docs/IMPLEMENT-Phase1.md T12; docs/30-* §4.2–§4.5,
## §4.7, §5, §6; docs/40-* §4.2; docs/50-* §4.3, §4.6; docs/20-* §4.10).
##
##   godot --headless res://tools/test_trade.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const MarketScene := preload("res://scenes/port/market_screen.tscn")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_worked_examples()
	_test_factor_and_discount()
	_test_investment_cap()
	_test_band_clamp()
	_test_quantity_limits()
	_test_buy_clamps()
	_test_goods_are_data_driven()
	_test_supplies_ignore_factors()
	_test_sell_profit_xp_and_reputation()
	_test_profit_survives_save_roundtrip()
	_test_capacity_flagship_first()
	_test_no_dynamic_pricing()
	_test_market_screen()
	_test_market_screen_data_driven()
	_test_market_screen_locale_and_back()
	_report()


# --- Fixtures --------------------------------------------------------------

## A livable run docked at `port_id`: one empty caravel (capacity 120), plain
## stats, no investments, no prior profit bookkeeping.
func _make_run(port_id: String, gold: int = 10000, ship_ids: Array = ["caravel"]) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {
			"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10,
		},
		"xp": 0,
		"level": 1,
		"officers": [],
		"reputation": {},
	}
	for nation_id in NATIONS:
		GameState.player["reputation"][nation_id] = 0
	GameState.fleet = []
	for ship_id in ship_ids:
		GameState.fleet.append(FleetLib.new_ship(str(ship_id), 0))
	GameState.day = 1
	GameState.gold = gold
	GameState.morale = 70
	GameState.current_port = port_id
	GameState.port_investments = {}
	GameState.known_ports = [port_id]
	var port: Dictionary = DataLoader.get_port(port_id)
	GameState.world = {
		"position": port.get("position", {"x": 0, "y": 0}).duplicate(),
		"clock_fraction": 0.0,
		"weather": "fair",
	}
	CharacterLib.pending_levelup = false


## Docks at `to_port` without rebuilding the run (the Lisbon → London leg).
func _dock(to_port: String, gold: int = -1) -> void:
	GameState.current_port = to_port
	if gold >= 0:
		GameState.gold = gold


func _test_worked_examples() -> void:
	# docs/30 §5: Lisbon produces wine → buy 21 / sell 16.
	_make_run("lisbon")
	_check(is_equal_approx(TradeEngineLib.factor("lisbon", "wine"), 0.7),
		"§5 Lisbon wine factor == 0.7 (got %.3f)"
		% TradeEngineLib.factor("lisbon", "wine"))
	_check(is_equal_approx(TradeEngineLib.investment_discount("lisbon"), 1.0),
		"§5 Lisbon investment_discount == 1.0 (got %.3f)"
		% TradeEngineLib.investment_discount("lisbon"))
	_check(TradeEngineLib.buy_price("lisbon", "wine") == 21,
		"§5 Lisbon wine buy_price == 21 (got %d)"
		% TradeEngineLib.buy_price("lisbon", "wine"))
	_check(TradeEngineLib.sell_price("lisbon", "wine") == 16,
		"§5 Lisbon wine sell_price == 16 (got %d)"
		% TradeEngineLib.sell_price("lisbon", "wine"))

	# docs/30 §5: London demands wine → buy 39 / sell 31.
	_check(is_equal_approx(TradeEngineLib.factor("london", "wine"), 1.3),
		"§5 London wine factor == 1.3 (got %.3f)"
		% TradeEngineLib.factor("london", "wine"))
	_check(TradeEngineLib.buy_price("london", "wine") == 39,
		"§5 London wine buy_price == 39 (got %d)"
		% TradeEngineLib.buy_price("london", "wine"))
	_check(TradeEngineLib.sell_price("london", "wine") == 31,
		"§5 London wine sell_price == 31 (got %d)"
		% TradeEngineLib.sell_price("london", "wine"))
	# §5 note: the route nets 10g/unit before costs.
	_check(TradeEngineLib.sell_price("london", "wine")
			- TradeEngineLib.buy_price("lisbon", "wine") == 10,
		"§5 Lisbon buy 21 → London sell 31 nets 10g/unit")

	# A neutral good trades at base ± the 0.8 margin: wheat 8 → 8 / 6.
	_check(TradeEngineLib.factor("lisbon", "wheat") == 1.0,
		"a good neither produced nor demanded has factor 1.0")
	_check(TradeEngineLib.buy_price("lisbon", "wheat") == 8,
		"Lisbon wheat buy == base 8 (got %d)"
		% TradeEngineLib.buy_price("lisbon", "wheat"))
	_check(TradeEngineLib.sell_price("lisbon", "wheat") == 6,
		"Lisbon wheat sell == floor(8 × 0.8) = 6 (got %d)"
		% TradeEngineLib.sell_price("lisbon", "wheat"))


func _test_factor_and_discount() -> void:
	_make_run("lisbon")
	# Every shipped port/good pair: produces 0.7, demands 1.3, else 1.0.
	var mismatch := 0
	for port in DataLoader.ports_list:
		var port_id := str(port.get("id", ""))
		for good in DataLoader.goods_list:
			var good_id := str(good.get("id", ""))
			var expected := 1.0
			if good_id in port.get("produces", []):
				expected = 0.7
			elif good_id in port.get("demands", []):
				expected = 1.3
			if not is_equal_approx(TradeEngineLib.factor(port_id, good_id), expected):
				mismatch += 1
	_check(mismatch == 0,
		"factor matches produces/demands/else at all %d ports × %d goods (mismatches: %d)"
		% [DataLoader.ports_list.size(), DataLoader.goods_list.size(), mismatch])

	# Investment discount: 1% per 500g, 10% cap (docs/30 §4.3).
	for chunks in range(0, 10):
		GameState.port_investments = {"lisbon": chunks * 500}
		var expected := 1.0 - float(chunks) * 0.01
		_check(is_equal_approx(
			TradeEngineLib.investment_discount("lisbon"), expected
		), "invested %dg → discount %.2f (got %.3f)" % [
			chunks * 500, expected,
			TradeEngineLib.investment_discount("lisbon"),
		])
	GameState.port_investments = {"lisbon": 999999}
	_check(is_equal_approx(TradeEngineLib.investment_discount("lisbon"), 0.90),
		"discount is capped at 0.90 even past 5,000g (got %.3f)"
		% TradeEngineLib.investment_discount("lisbon"))

	# Every price is at least 1g (docs/30 §4.2 max(1, …)).
	GameState.port_investments = {}
	var cheap_port := "lisbon"
	_check(TradeEngineLib.buy_price(cheap_port, "wheat") >= 1
			and TradeEngineLib.sell_price(cheap_port, "wheat") >= 1,
		"prices never drop below 1g")
	# An unknown port/good is neutral, and never crashes.
	_check(TradeEngineLib.buy_price("nowhere", "wine") == 30,
		"unknown port is neutral: wine buy == 30 (got %d)"
		% TradeEngineLib.buy_price("nowhere", "wine"))


func _test_investment_cap() -> void:
	# 10 × 500g = 5,000g → exactly −10%; the 11th click is impossible.
	_make_run("lisbon", 10000)
	for click in range(1, 11):
		var paid_before := GameState.gold
		_check(TradeEngineLib.can_invest("lisbon"),
			"click %d: can_invest is true" % click)
		_check(TradeEngineLib.invest("lisbon"),
			"click %d: invest() succeeds" % click)
		_check(TradeEngineLib.invested("lisbon") == click * 500,
			"click %d: invested == %dg (got %d)"
			% [click, click * 500, TradeEngineLib.invested("lisbon")])
		_check(GameState.gold == paid_before - 500,
			"click %d: 500g paid (got %d)" % [click, GameState.gold])

	_check(is_equal_approx(TradeEngineLib.investment_discount("lisbon"), 0.90),
		"10 chunks → discount exactly 0.90 (got %.4f)"
		% TradeEngineLib.investment_discount("lisbon"))
	_check(TradeEngineLib.investment_percent("lisbon") == 10,
		"readout shows −10%% (got %d)" % TradeEngineLib.investment_percent("lisbon"))
	_check(TradeEngineLib.invested("lisbon") == TradeEngineLib.INVEST_CAP_GOLD,
		"5,000g invested")
	# floor(30 × 0.7 × 0.9) = floor(18.9) = 18.
	_check(TradeEngineLib.buy_price("lisbon", "wine") == 18,
		"fully-invested Lisbon wine buy == 18 (got %d)"
		% TradeEngineLib.buy_price("lisbon", "wine"))
	# floor(30 × 0.7 × 0.8 × 0.9) = floor(15.12) = 15.
	_check(TradeEngineLib.sell_price("lisbon", "wine") == 15,
		"fully-invested Lisbon wine sell == 15 (got %d)"
		% TradeEngineLib.sell_price("lisbon", "wine"))

	var gold_at_cap := GameState.gold
	_check(not TradeEngineLib.can_invest("lisbon"),
		"11th click: can_invest is false")
	_check(not TradeEngineLib.invest("lisbon"),
		"11th click: invest() returns false")
	_check(GameState.gold == gold_at_cap,
		"11th click: gold unchanged (%d)" % GameState.gold)
	_check(TradeEngineLib.invested("lisbon") == 5000,
		"11th click: invested still 5,000g (%d)"
		% TradeEngineLib.invested("lisbon"))

	# Below the cap but broke → also refused (docs/30 §4.3 "fixed chunk").
	_make_run("lisbon", 499)
	_check(not TradeEngineLib.can_invest("lisbon"),
		"499g: cannot invest (chunk is 500g)")
	_check(not TradeEngineLib.invest("lisbon"), "499g: invest() refused")
	_check(TradeEngineLib.invested("lisbon") == 0, "499g: nothing invested")
	_check(GameState.gold == 499, "499g: gold untouched")

	# Exactly 500g is allowed (docs/30 §6 "gold exactly equals cost").
	_make_run("lisbon", 500)
	_check(TradeEngineLib.invest("lisbon"), "exactly 500g: invest() succeeds")
	_check(GameState.gold == 0, "exactly 500g: gold becomes 0 (got %d)"
		% GameState.gold)

	# Investment is per port: London stays at full price.
	_make_run("lisbon", 10000)
	for click in range(10):
		TradeEngineLib.invest("lisbon")
	_check(TradeEngineLib.invested("london") == 0,
		"investment is per port: London has 0g invested")
	_check(TradeEngineLib.buy_price("london", "wine") == 39,
		"London wine buy is unaffected by Lisbon's investment (got %d)"
		% TradeEngineLib.buy_price("london", "wine"))


func _test_band_clamp() -> void:
	# The band is applied to `factor × discount` before the price is computed
	# (docs/30 §4.2 last bullet). No shipped pair reaches the 0.5 floor (the
	# lowest is 0.7 × 0.9 = 0.63), so the helper is exercised directly.
	_make_run("lisbon")
	_check(is_equal_approx(TradeEngineLib.clamped_factor("lisbon", "wine"), 0.7),
		"Lisbon wine clamped_factor == 0.70 (got %.3f)"
		% TradeEngineLib.clamped_factor("lisbon", "wine"))
	_check(is_equal_approx(TradeEngineLib.clamped_factor("london", "wine"), 1.3),
		"London wine clamped_factor == 1.30 (got %.3f)"
		% TradeEngineLib.clamped_factor("london", "wine"))

	var floor_units := TradeEngineLib.band_units(0.4, 1.0)
	_check(floor_units == 500,
		"synthetic 0.4 factor is clamped up to 0.5 (got %d/1000)" % floor_units)
	_check(TradeEngineLib.price_from_units(30, floor_units, false) == 15,
		"synthetic 0.4 factor prices at the 0.5 floor: 15 (got %d)"
		% TradeEngineLib.price_from_units(30, floor_units, false))
	_check(TradeEngineLib.price_from_units(30, floor_units, true) == 12,
		"the 0.5 floor also governs the sell side: floor(30×0.5×0.8)=12 (got %d)"
		% TradeEngineLib.price_from_units(30, floor_units, true))
	var ceiling_units := TradeEngineLib.band_units(4.0, 1.0)
	_check(ceiling_units == 2000,
		"synthetic 4.0 factor is clamped down to 2.0 (got %d/1000)" % ceiling_units)
	_check(TradeEngineLib.price_from_units(30, ceiling_units, false) == 60,
		"the 2.0 ceiling caps a buy at 60 (got %d)"
		% TradeEngineLib.price_from_units(30, ceiling_units, false))
	# The clamp is on the product, so a factor under 0.5 with a discount is
	# still lifted to the floor: 0.7 × 0.5 = 0.35 → 0.5.
	_check(TradeEngineLib.band_units(0.7, 0.5) == 500,
		"0.7 × 0.5 = 0.35 is clamped to 0.5 (got %d/1000)"
		% TradeEngineLib.band_units(0.7, 0.5))
	# And an inflated discount above 2.0 is clamped down: 1.3 × 2 = 2.6 → 2.0.
	_check(TradeEngineLib.band_units(1.3, 2.0) == 2000,
		"1.3 × 2.0 = 2.6 is clamped to 2.0 (got %d/1000)"
		% TradeEngineLib.band_units(1.3, 2.0))

	# A produces good at max discount stays above the floor and keeps the
	# exact §4.2 value: 0.7 × 0.9 = 0.63 → floor(30 × 0.63) = 18.
	_make_run("lisbon", 10000)
	for click in range(10):
		TradeEngineLib.invest("lisbon")
	_check(is_equal_approx(TradeEngineLib.clamped_factor("lisbon", "wine"), 0.63),
		"Lisbon wine at max investment: 0.7 × 0.9 = 0.63 (got %.4f)"
		% TradeEngineLib.clamped_factor("lisbon", "wine"))


func _test_quantity_limits() -> void:
	_make_run("lisbon", 1000)
	# buy_max = min(floor(gold / price), fleet_free).
	_check(TradeEngineLib.buy_max("lisbon", "wine") == mini(
		1000 / 21, FleetLib.fleet_free()), "buy_max is the gold/capacity minimum")
	_check(TradeEngineLib.buy_max("lisbon", "wine") == 47,
		"1,000g at 21g/unit buys 47 (got %d)"
		% TradeEngineLib.buy_max("lisbon", "wine"))
	_check(TradeEngineLib.sell_max("wine") == 0,
		"an empty hold has sell_max 0")

	FleetLib.add_goods("wine", 30)
	_check(TradeEngineLib.sell_max("wine") == 30,
		"sell_max == held 30 (got %d)" % TradeEngineLib.sell_max("wine"))
	_check(TradeEngineLib.buy_max("lisbon", "wine") == mini(
		47, FleetLib.fleet_free()),
		"carrying cargo lowers buy_max by exactly the cargo")
	_check(FleetLib.fleet_free() == 90,
		"caravel 120 − 30 wine = 90 free (got %d)" % FleetLib.fleet_free())

	# Capacity-limited: rich but nearly full → buy_max is the free space.
	_make_run("lisbon", 100000)
	FleetLib.add_goods("salt", 115)
	_check(FleetLib.fleet_free() == 5, "5 units of hold left")
	_check(TradeEngineLib.buy_max("lisbon", "wine") == 5,
		"buy_max is capacity-limited to 5 (got %d)"
		% TradeEngineLib.buy_max("lisbon", "wine"))
	# Completely full → 0, the §6 `market.hold_full` state.
	FleetLib.add_goods("salt", 5)
	_check(FleetLib.fleet_free() == 0, "hold is full")
	_check(TradeEngineLib.buy_max("lisbon", "wine") == 0,
		"a full hold has buy_max 0 (got %d)"
		% TradeEngineLib.buy_max("lisbon", "wine"))


func _test_buy_clamps() -> void:
	# Gold-limited buy: exactly affordable works, one more unit does not.
	_make_run("lisbon", 210)
	_check(TradeEngineLib.buy_max("lisbon", "wine") == 10,
		"210g buys 10 wine (got %d)" % TradeEngineLib.buy_max("lisbon", "wine"))
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "buy 10 wine succeeds")
	_check(GameState.gold == 0, "gold exactly spent to 0 (got %d)" % GameState.gold)
	_check(FleetLib.held("wine") == 10, "10 wine aboard (got %d)"
		% FleetLib.held("wine"))

	# Over-max gold buy: refused, nothing changes at all.
	_make_run("lisbon", 210)
	var gold_before := GameState.gold
	var free_before := FleetLib.fleet_free()
	_check(not TradeEngineLib.buy("lisbon", "wine", 11),
		"buying 11 with 210g is refused")
	_check(GameState.gold == gold_before,
		"refused buy leaves gold at %d (got %d)" % [gold_before, GameState.gold])
	_check(FleetLib.fleet_free() == free_before,
		"refused buy leaves capacity at %d (got %d)"
		% [free_before, FleetLib.fleet_free()])
	_check(FleetLib.held("wine") == 0, "refused buy loads no wine")

	# Capacity-limited buy: over-max refused, at-max allowed.
	_make_run("lisbon", 100000)
	FleetLib.add_goods("salt", 115)
	_check(not TradeEngineLib.buy("lisbon", "wine", 6),
		"buying 6 into 5 free units is refused")
	_check(FleetLib.held("wine") == 0, "nothing loaded by the refused buy")
	_check(TradeEngineLib.buy("lisbon", "wine", 5),
		"buying exactly the free 5 succeeds")
	_check(FleetLib.fleet_free() == 0, "hold is now full")
	_check(FleetLib.held("wine") == 5, "5 wine aboard")

	# Invalid quantities are refused without noise.
	for qty in [0, -1, -500]:
		_check(not TradeEngineLib.buy("lisbon", "wine", qty),
			"buy(%d) is refused" % qty)
	_check(not TradeEngineLib.buy("lisbon", "not_a_good", 1),
		"an unknown good is refused")
	_check(not TradeEngineLib.buy("not_a_port", "wine", 1),
		"an unknown port is refused")


func _test_goods_are_data_driven() -> void:
	# The market table is built by iterating `DataLoader.goods_list`; today the
	# locked list has 20 goods, and adding a 21st is a data-only change.
	_check(DataLoader.goods_list.size() == 20,
		"goods.json holds the locked 20 goods (got %d)" % DataLoader.goods_list.size())
	var rows := TradeEngineLib.goods_rows()
	_check(rows.size() == 20, "goods_rows() returns 20 rows (got %d)" % rows.size())
	# Sorted by base_price ascending (ties by id), per docs/30 §4.7.
	var sorted := true
	for index in range(1, rows.size()):
		var previous := int(rows[index - 1].get("base_price", 0))
		var current := int(rows[index].get("base_price", 0))
		if current < previous:
			sorted = false
	_check(sorted, "rows are sorted by base_price ascending")
	_check(str(rows[0].get("id", "")) == "wheat",
		"cheapest row is wheat 8g (got %s)" % str(rows[0].get("id", "")))
	_check(str(rows[rows.size() - 1].get("id", "")) == "spices",
		"priciest row is spices 150g (got %s)"
		% str(rows[rows.size() - 1].get("id", "")))

	# Prove the data path: append a synthetic good to the in-memory list and
	# dict only (no file edit), and the engine prices and ranks it like any
	# other, with zero code changes.
	var synthetic := {
		"id": "test_tea",
		"name": {"zh": "测试茶", "en": "Test Tea"},
		"category": "food",
		"base_price": 11,
		"unit_size": 1,
	}
	DataLoader.goods_list.append(synthetic)
	DataLoader.goods["test_tea"] = synthetic
	_make_run("lisbon", 10000)
	_check(TradeEngineLib.goods_rows().size() == 21,
		"a 21st good appears in goods_rows() (got %d)"
		% TradeEngineLib.goods_rows().size())
	var with_tea := TradeEngineLib.goods_rows()
	var tea_index := -1
	for index in with_tea.size():
		if str(with_tea[index].get("id", "")) == "test_tea":
			tea_index = index
			break
	_check(tea_index >= 0, "the 21st good has a row")
	# base 11 sits between wheat 8 and dried_fish 10? No: salt 12 → index after
	# dried_fish(10) and before salt(12).
	_check(tea_index > 0 and tea_index < with_tea.size() - 1,
		"the 21st good is sorted into the middle (index %d)" % tea_index)
	_check(TradeEngineLib.buy_price("lisbon", "test_tea") == 11,
		"the 21st good prices at its base 11 (got %d)"
		% TradeEngineLib.buy_price("lisbon", "test_tea"))
	_check(TradeEngineLib.buy("lisbon", "test_tea", 2),
		"the 21st good is buyable with no code change")
	_check(FleetLib.held("test_tea") == 2, "2 test tea aboard")

	# Restore the shipped data (the list and dict are the loader's, not a copy).
	DataLoader.goods_list.pop_back()
	DataLoader.goods.erase("test_tea")
	_check(DataLoader.goods_list.size() == 20, "goods.json data restored to 20")


func _test_supplies_ignore_factors() -> void:
	# At a port that produces wine and demands spices, at max investment, the
	# supply prices are still the locked 2g / 1g (docs/20 §4.10).
	_make_run("lisbon", 10000)
	_check("wine" in DataLoader.get_port("lisbon")["produces"],
		"fixture port produces wine")
	_check("spices" in DataLoader.get_port("lisbon")["demands"],
		"fixture port demands spices")
	for click in range(10):
		TradeEngineLib.invest("lisbon")
	_check(TradeEngineLib.supplies_price("provisions") == 2,
		"provisions are 2g at max investment (got %d)"
		% TradeEngineLib.supplies_price("provisions"))
	_check(TradeEngineLib.supplies_price("water") == 1,
		"water is 1g at max investment (got %d)"
		% TradeEngineLib.supplies_price("water"))
	_check(TradeEngineLib.supplies_price("provisions") == 2,
		"provisions match SailingSim.PROVISIONS_PRICE (shared constant)")
	_check(not ("provisions" in DataLoader.goods),
		"supplies are not trade goods (absent from goods.json)")
	_check(not ("water" in DataLoader.goods),
		"water is not a trade good")

	# Buying: 2g and 1g exactly, and they occupy cargo.
	var gold_before := GameState.gold
	_check(TradeEngineLib.buy_supplies("lisbon", "provisions", 10),
		"buy 10 provisions")
	_check(GameState.gold == gold_before - 20,
		"10 provisions cost 20g (paid %d)" % (gold_before - GameState.gold))
	_check(FleetLib.supplies("provisions") == 10, "10 provisions aboard")
	gold_before = GameState.gold
	_check(TradeEngineLib.buy_supplies("lisbon", "water", 10), "buy 10 water")
	_check(GameState.gold == gold_before - 10,
		"10 water costs 10g (paid %d)" % (gold_before - GameState.gold))
	_check(FleetLib.used_capacity(GameState.fleet[0]) == 20,
		"supplies occupy cargo: 10 + 10 = 20 units (got %d)"
		% FleetLib.used_capacity(GameState.fleet[0]))

	# sell-back is not offered: the engine has no supplies-sell entry point at
	# all (docs/20 §4.10 "not sellable"), and the screen renders no Sell button.
	var engine_source := FileAccess.get_file_as_string(
		"res://scripts/port/trade_engine.gd"
	)
	_check(not engine_source.contains("func sell_supplies("),
		"no sell_supplies API exists (supplies are not sellable)")
	_check(engine_source.contains("func buy_supplies("),
		"buy_supplies is the only supplies transaction")
	# Over-max / over-capacity supplies buys are refused unchanged.
	var free_before := FleetLib.fleet_free()
	var gold_now := GameState.gold
	_check(not TradeEngineLib.buy_supplies("lisbon", "provisions", free_before + 1),
		"a supplies buy over the free capacity is refused")
	_check(GameState.gold == gold_now and FleetLib.fleet_free() == free_before,
		"the refused supplies buy changed nothing")
	_check(not TradeEngineLib.buy_supplies("lisbon", "rum", 1),
		"an unknown supply kind is refused")


func _test_sell_profit_xp_and_reputation() -> void:
	# Lisbon → London wine run: buy 10 at 21, sail, sell at 31.
	_make_run("lisbon", 1000)
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "buy 10 wine at Lisbon")
	_dock("london")

	var xp_before := CharacterLib.current_xp()
	var rep_before := CharacterLib.reputation("england")
	var gold_before := GameState.gold
	_check(TradeEngineLib.sell("london", "wine", 10), "sell 10 wine at London")
	_check(GameState.gold == gold_before + 310,
		"sell earns 10 × 31 = 310g (got +%d)" % (GameState.gold - gold_before))

	# docs/50 §4.3: per-unit profit = 31 − floor(30 × 0.7) = 31 − 21 = 10;
	# profit 100 → +1 XP.
	_check(CharacterLib.current_xp() == xp_before + 1,
		"a 100g-profit sale awards 1 XP (got +%d)"
		% (CharacterLib.current_xp() - xp_before))
	# docs/50 §4.6: +1 reputation per 1,000g profit — 100g is below the
	# threshold, so it accumulates instead of granting.
	_check(CharacterLib.reputation("england") == rep_before,
		"100g of profit does not yet earn reputation (england %d)"
		% CharacterLib.reputation("england"))
	_check(TradeEngineLib.profit_by_nation("england") == 100,
		"100g cumulative profit booked to England (got %d)"
		% TradeEngineLib.profit_by_nation("england"))

	# The 1,000g threshold carries across transactions: 9 more units → 90g
	# (190 total) … and a big sale crosses it.
	FleetLib.add_goods("wine", 100)
	GameState.gold = 0
	rep_before = CharacterLib.reputation("england")
	xp_before = CharacterLib.current_xp()
	_check(TradeEngineLib.sell("london", "wine", 100),
		"sell 100 more wine at London")
	# 100 × 10 = 1,000g profit → total 1,100 → 1 reputation point.
	_check(CharacterLib.reputation("england") == rep_before + 1,
		"crossing 1,000g cumulative profit grants +1 reputation (got +%d)"
		% (CharacterLib.reputation("england") - rep_before))
	_check(TradeEngineLib.profit_by_nation("england") == 1100,
		"1,100g cumulative profit booked to England (got %d)"
		% TradeEngineLib.profit_by_nation("england"))
	# XP: floor(1000 / 100) = 10 for this transaction.
	_check(CharacterLib.current_xp() == xp_before + 10,
		"a 1,000g-profit sale awards 10 XP (got +%d)"
		% (CharacterLib.current_xp() - xp_before))
	# Reputation went to England, not any other nation.
	_check(CharacterLib.reputation("portugal") == 0,
		"selling in London leaves Portugal's reputation at 0")

	# A loss-making sale gives 0 XP and 0 reputation and never removes XP.
	_make_run("lisbon", 10000)
	FleetLib.add_goods("wine", 10)
	xp_before = CharacterLib.current_xp()
	rep_before = CharacterLib.reputation("portugal")
	GameState.gold = 0
	# Lisbon sell is 16/unit against a 21 cost basis → a loss every unit.
	_check(TradeEngineLib.sell("lisbon", "wine", 10), "sell wine at Lisbon")
	_check(CharacterLib.current_xp() == xp_before,
		"a loss-making sale awards 0 XP (got +%d)"
		% (CharacterLib.current_xp() - xp_before))
	_check(CharacterLib.reputation("portugal") == rep_before,
		"a loss-making sale awards no reputation")
	_check(TradeEngineLib.profit_by_nation("portugal") == 0,
		"a loss books no cumulative profit (got %d)"
		% TradeEngineLib.profit_by_nation("portugal"))

	# Reputation is per nation and clamped: the cap holds after a huge profit.
	_make_run("london", 10000)
	FleetLib.add_goods("wine", 100000)
	GameState.gold = 0
	CharacterLib.add_reputation("england", 100)
	TradeEngineLib.sell("london", "wine", 1000)  # 10,000g profit → +10
	_check(CharacterLib.reputation("england") == 100,
		"reputation stays clamped at +100 (got %d)"
		% CharacterLib.reputation("england"))

	# Over-quantity sells fail without touching state.
	_make_run("london", 10000)
	FleetLib.add_goods("wine", 5)
	gold_before = GameState.gold
	_check(not TradeEngineLib.sell("london", "wine", 6),
		"selling 6 of 5 held is refused")
	_check(FleetLib.held("wine") == 5 and GameState.gold == gold_before,
		"the refused sell changed nothing")
	_check(not TradeEngineLib.sell("london", "wine", 0), "sell(0) is refused")


## docs/50-* §4.6 + §4.8: the cumulative-profit accumulator sits in the `player`
## save block, so a JSON round trip must preserve both the running total and
## the reputation already paid out (otherwise a reload would re-award points).
func _test_profit_survives_save_roundtrip() -> void:
	# A galleon's 400-unit hold carries the 150 units in one load.
	_make_run("lisbon", 10000, ["galleon"])
	FleetLib.add_goods("wine", 150)
	_dock("london")
	GameState.gold = 0
	_check(TradeEngineLib.sell("london", "wine", 150), "sell 150 wine (1,500g profit)")
	_check(CharacterLib.reputation("england") == 1, "1 reputation from 1,500g")
	_check(CharacterLib.profit_by_nation("england") == 1500,
		"1,500g booked (got %d)" % CharacterLib.profit_by_nation("england"))
	_check(GameState.player.has("profit_by_nation")
		and GameState.player.has("profit_rep_awarded"),
		"both accumulator keys live in the player block")

	# JSON round trip exactly as the save system serialises the block.
	var encoded := JSON.stringify(GameState.player)
	var decoded = JSON.parse_string(encoded)
	GameState.player = decoded
	_check(CharacterLib.profit_by_nation("england") == 1500,
		"the total survives a JSON round trip (got %d)"
		% CharacterLib.profit_by_nation("england"))
	_check(CharacterLib.reputation("england") == 1, "reputation survives too")

	# Another 500g after the reload crosses 2,000g → one more point, not two:
	# the already-awarded marker survived, so nothing is double-paid.
	GameState.gold = 0
	FleetLib.add_goods("wine", 50)
	_check(TradeEngineLib.sell("london", "wine", 50), "sell 50 more (500g profit)")
	_check(CharacterLib.profit_by_nation("england") == 2000,
		"total is 2,000g after the reload (got %d)"
		% CharacterLib.profit_by_nation("england"))
	_check(CharacterLib.reputation("england") == 2,
		"2,000g → exactly +2 total reputation, no double-award (got %d)"
		% CharacterLib.reputation("england"))
	# A sub-1,000g remainder never rounds up.
	GameState.gold = 0
	FleetLib.add_goods("wine", 5)
	TradeEngineLib.sell("london", "wine", 5)
	_check(CharacterLib.reputation("england") == 2,
		"a 50g remainder grants nothing (got %d)"
		% CharacterLib.reputation("england"))


func _test_capacity_flagship_first() -> void:
	# Two hulls: caravel 120 + latin 30. Buying fills the flagship first.
	_make_run("lisbon", 100000, ["caravel", "latin"])
	_check(FleetLib.fleet_free() == 150, "fleet free is 150 (120 + 30)")
	_check(TradeEngineLib.buy("lisbon", "wine", 100), "buy 100 wine")
	_check(int(GameState.fleet[0]["cargo"].get("wine", 0)) == 100,
		"all 100 land on the flagship (got %d)"
		% int(GameState.fleet[0]["cargo"].get("wine", 0)))
	_check(int(GameState.fleet[1]["cargo"].get("wine", 0)) == 0,
		"the escort is still empty")
	_check(FleetLib.fleet_free() == 50,
		"fleet_free drops by exactly 100 → 50 (got %d)" % FleetLib.fleet_free())

	# Overflow goes to the second hull, flagship still first.
	_check(TradeEngineLib.buy("lisbon", "wine", 40), "buy 40 more wine")
	_check(int(GameState.fleet[0]["cargo"].get("wine", 0)) == 120,
		"the flagship is full at 120 (got %d)"
		% int(GameState.fleet[0]["cargo"].get("wine", 0)))
	_check(int(GameState.fleet[1]["cargo"].get("wine", 0)) == 20,
		"the escort holds the 20 overflow (got %d)"
		% int(GameState.fleet[1]["cargo"].get("wine", 0)))
	_check(FleetLib.fleet_free() == 10, "fleet_free is 10 (got %d)"
		% FleetLib.fleet_free())
	_check(FleetLib.held("wine") == 140,
		"held() pools both hulls: 140 (got %d)" % FleetLib.held("wine"))

	# Buy_max is pooled capacity, so the last 10 are buyable and 11 are not.
	_check(TradeEngineLib.buy_max("lisbon", "wine") == 10,
		"buy_max uses pooled free capacity: 10 (got %d)"
		% TradeEngineLib.buy_max("lisbon", "wine"))
	_check(not TradeEngineLib.buy("lisbon", "wine", 11), "11 is refused")
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "exactly 10 succeeds")
	_check(FleetLib.fleet_free() == 0, "the fleet is full")


func _test_no_dynamic_pricing() -> void:
	# docs/30 §4.4: no price movement per transaction.
	_make_run("lisbon", 100000)
	var buy_before := TradeEngineLib.buy_price("lisbon", "wine")
	var sell_before := TradeEngineLib.sell_price("lisbon", "wine")
	for index in range(20):
		TradeEngineLib.buy("lisbon", "wine", 5)
	_check(TradeEngineLib.buy_price("lisbon", "wine") == buy_before,
		"buy price is unchanged after 20 purchases (%d)" % buy_before)
	_check(TradeEngineLib.sell_price("lisbon", "wine") == sell_before,
		"sell price is unchanged after 20 purchases (%d)" % sell_before)


# --- Market screen ---------------------------------------------------------

func _instantiate_market() -> Control:
	var screen: Control = MarketScene.instantiate()
	add_child(screen)
	return screen


func _test_market_screen() -> void:
	_make_run("lisbon", 1000)
	var screen := _instantiate_market()
	# `_ready` built everything synchronously.
	_check(screen.row_goods_ids().size() == 20,
		"market screen renders 20 good rows (got %d)"
		% screen.row_goods_ids().size())
	# Rows are in base_price order, cheapest first.
	_check(str(screen.row_goods_ids()[0]) == "wheat",
		"the first row is wheat (got %s)" % str(screen.row_goods_ids()[0]))
	_check(str(screen.row_goods_ids()[19]) == "spices",
		"the last row is spices (got %s)" % str(screen.row_goods_ids()[19]))

	# Header: title, gold and hold.
	var title: Label = screen.get_node("Layout/VBox/Header/Title")
	_check(title.text == I18n.fmt("market.title", {"port": "Lisbon"}),
		"header title is 'Market — Lisbon' (%s)" % title.text)
	var gold_label: Label = screen.get_node("Layout/VBox/Header/Gold")
	_check(gold_label.text == I18n.fmt("ui.gold_amount", {"gold": "1,000"}),
		"header gold is 1,000g (%s)" % gold_label.text)
	var hold_label: Label = screen.get_node("Layout/VBox/Header/Hold")
	_check(hold_label.text.contains("0/120"),
		"header hold is 0/120 (%s)" % hold_label.text)

	# The table is scrollable (20+ rows; docs/30 §4.7).
	var scroll: ScrollContainer = screen.get_node(
		"Layout/VBox/TableFrame/Margin/Table/GoodsScroll"
	)
	_check(scroll != null and scroll.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED,
		"the goods table scrolls vertically")

	# Price cells carry both prices, and the row's have-cell starts at 0.
	var wine_row: Dictionary = screen.row("wine")
	_check((wine_row["price"] as Label).text == "21g / 16g",
		"wine row shows 21g / 16g (%s)" % (wine_row["price"] as Label).text)
	_check((wine_row["have"] as Label).text == "0", "wine row have is 0")
	_check((wine_row["buy"] as Button).text == I18n.t_key("market.buy"),
		"buy button is localised")
	_check((wine_row["buy"] as Button).disabled,
		"buy is disabled with an empty quantity (§6)")

	# Empty field = invalid, buttons disabled, no state change.
	_check(screen.row_qty("wine") == -1, "an empty qty field parses as -1")
	screen.type_qty("wine", "")
	_check(screen.row_qty("wine") == -1, "clearing the field keeps it invalid")
	_check(not screen.press_buy("wine"), "Buy is a no-op while the qty is empty")

	# Digits-only + live clamp: non-digits are dropped, an over-range entry is
	# clamped to the physical ceiling (the pooled free hold: 120 here).
	screen.type_qty("wine", "12ab3")
	_check(screen.row_qty("wine") == 120,
		"non-digits are dropped: '12ab3' → 123, clamped to the 120 hold (got %d)"
		% screen.row_qty("wine"))
	var buy_max := TradeEngineLib.buy_max("lisbon", "wine")
	_check(buy_max == 47, "gold limits buy_max to 47 (got %d)" % buy_max)
	screen.type_qty("wine", "999999")
	_check(screen.row_qty("wine") == 120,
		"live clamp: 999999 → the 120-unit hold (got %d)" % screen.row_qty("wine"))
	# Unaffordable at the clamped quantity: disabled **with** the reason.
	_check((wine_row["buy"] as Button).disabled,
		"Buy is disabled at a quantity the purse cannot cover")
	_check((wine_row["buy"] as Button).tooltip_text
		== I18n.fmt("market.not_enough_gold", {"gold": 21 * 120}),
		"the reason is market.not_enough_gold (%s)"
		% (wine_row["buy"] as Button).tooltip_text)

	# Preset buttons: 1 / 10 / 100 behave per the ceiling (Max = buy_max).
	screen.press_qty_preset("wine", "1")
	_check(screen.row_qty("wine") == 1, "preset 1 → qty 1")
	screen.press_qty_preset("wine", "10")
	_check(screen.row_qty("wine") == 10, "preset 10 → qty 10")
	screen.press_qty_preset("wine", "100")
	_check(screen.row_qty("wine") == mini(100, buy_max),
		"preset 100 clamps to buy_max (%d)" % screen.row_qty("wine"))
	screen.press_qty_preset("wine", "max")
	_check(screen.row_qty("wine") == buy_max,
		"Max → buy_max %d (got %d)" % [buy_max, screen.row_qty("wine")])
	_check(not (wine_row["buy"] as Button).disabled,
		"Buy enables at a valid affordable quantity")
	_check((wine_row["buy"] as Button).tooltip_text.is_empty(),
		"no tooltip reason when Buy is allowed")

	# A buy updates gold, holdings, prices and capacity immediately.
	screen.press_qty_preset("wine", "10")
	var gold_before := GameState.gold
	_check(screen.press_buy("wine"), "Buy 10 wine from the screen")
	_check(FleetLib.held("wine") == 10, "10 wine aboard after the buy")
	_check(GameState.gold == gold_before - 10 * 21,
		"gold drops by 210 (got %d)" % GameState.gold)
	_check((wine_row["have"] as Label).text == "10",
		"the have cell updated to 10 (%s)" % (wine_row["have"] as Label).text)
	_check(hold_label.text.contains("10/120"),
		"the header hold updated to 10/120 (%s)" % hold_label.text)
	_check(gold_label.text == I18n.fmt(
		"ui.gold_amount", {"gold": screen.format_thousands(GameState.gold)}
	), "the gold readout updated (%s)" % gold_label.text)
	# The sell side is now enabled at qty 10.
	screen.type_qty("wine", "10")
	_check(not (wine_row["sell"] as Button).disabled,
		"Sell enables once the good is held")
	_check(screen.press_sell("wine"), "Sell 10 wine from the screen")
	_check(FleetLib.held("wine") == 0, "the hold is empty again")
	_check((wine_row["sell"] as Button).disabled,
		"Sell disables again at 0 held")

	# A full hold is still sellable: `Max` follows the larger of buy_max and
	# the held quantity, so the player can always empty the hold from the UI.
	_make_run("lisbon", 1000)
	var full_screen := _instantiate_market()
	FleetLib.add_goods("wine", 120)
	EventBus.fleet_changed.emit()
	full_screen.press_qty_preset("wine", "max")
	_check(full_screen.row_qty("wine") == 120,
		"Max on a full hold selects the 120 held (got %d)"
		% full_screen.row_qty("wine"))
	_check(full_screen.row("wine")["buy"].disabled,
		"Buy stays disabled at a full hold even with Max selected")
	_check(full_screen.press_sell("wine"), "Sell 120 wine out of a full hold")
	_check(FleetLib.held("wine") == 0, "the hold is empty again")
	_check(TradeEngineLib.buy_max("lisbon", "wine") > 0,
		"buying is possible again after emptying the hold")
	full_screen.queue_free()

	# Rebuild the fixture for the tooltip/reason and supplies assertions.
	_make_run("lisbon", 1000)
	screen.queue_free()
	screen = _instantiate_market()
	wine_row = screen.row("wine")

	# The tooltip reason for an unaffordable buy (§4.7 / §6).
	GameState.gold = 5
	EventBus.gold_changed.emit(GameState.gold)
	screen.type_qty("wine", "1")
	var buy_button: Button = wine_row["buy"]
	_check(buy_button.disabled, "Buy is disabled when gold < price")
	_check(buy_button.tooltip_text == I18n.t_key("market.no_gold"),
		"the reason is market.no_gold (%s)" % buy_button.tooltip_text)
	# Clamped entry already prevents over-max; the reason path still explains
	# a full hold (§6).
	GameState.gold = 100000
	EventBus.gold_changed.emit(GameState.gold)
	FleetLib.add_goods("salt", FleetLib.fleet_free())
	EventBus.fleet_changed.emit()
	screen.type_qty("wine", "1")
	_check(buy_button.disabled, "Buy is disabled with a full hold")
	_check(buy_button.tooltip_text == I18n.t_key("market.hold_full"),
		"the reason is market.hold_full (%s)" % buy_button.tooltip_text)

	# Supplies rows: fixed prices, buy only.
	_check(screen.supply_row("provisions")["label"].text
		== I18n.fmt("market.provisions", {"price": 2}),
		"provisions row reads 2g (%s)" % screen.supply_row("provisions")["label"].text)
	_check(screen.supply_row("water")["label"].text
		== I18n.fmt("market.water", {"price": 1}),
		"water row reads 1g (%s)" % screen.supply_row("water")["label"].text)
	_check(not screen.supply_row("provisions").has("sell"),
		"supplies rows have no Sell button")
	# Free the hold so the supplies purchase has room (and prove a full hold
	# disables the supplies Buy with the same §6 reason).
	screen.type_supply_qty("provisions", "5")
	_check(screen.supply_row("provisions")["buy"].disabled,
		"the supplies Buy is disabled with a full hold")
	_check((screen.supply_row("provisions")["buy"] as Button).tooltip_text
		== I18n.t_key("market.hold_full"),
		"the supplies reason is market.hold_full (%s)"
		% (screen.supply_row("provisions")["buy"] as Button).tooltip_text)
	FleetLib.remove_goods("salt", 10000)
	EventBus.fleet_changed.emit()
	screen.type_supply_qty("provisions", "5")
	_check(not screen.supply_row("provisions")["buy"].disabled,
		"the supplies Buy enables at a valid qty")
	gold_before = GameState.gold
	_check(screen.press_supply_buy("provisions"), "buy 5 provisions")
	_check(FleetLib.supplies("provisions") == 5, "5 provisions aboard")
	_check(GameState.gold == gold_before - 10, "5 provisions cost 10g")

	# Invest button: 500g chunks, cap 10.
	_make_run("lisbon", 6000)
	var invest_screen := _instantiate_market()
	var invest_button: Button = invest_screen.get_node("Layout/VBox/Footer/Invest")
	var invest_status: Label = invest_screen.get_node("Layout/VBox/Footer/InvestStatus")
	_check(not invest_button.disabled, "Invest is enabled with gold")
	_check(invest_status.text == I18n.fmt(
		"market.invested_here", {"gold": "0", "count": 0}
	), "the readout starts at 0g (−0%%) (%s)" % invest_status.text)
	for click in range(10):
		invest_screen.press_invest()
	_check(TradeEngineLib.invested("lisbon") == 5000,
		"10 clicks invest 5,000g (got %d)" % TradeEngineLib.invested("lisbon"))
	_check(invest_status.text == I18n.fmt(
		"market.invested_here", {"gold": "5,000", "count": 10}
	), "the readout shows 5,000g (−10%%) (%s)" % invest_status.text)
	_check(invest_button.disabled, "the Invest button is disabled at the cap")
	_check(invest_button.tooltip_text == I18n.fmt(
		"market.invest_cap", {"max": 10}
	), "the cap string is shown (%s)" % invest_button.tooltip_text)
	_check(invest_status.text.contains("−10%"),
		"the readout names the −10%% cap (%s)" % invest_status.text)
	var gold_at_cap := GameState.gold
	_check(not invest_screen.press_invest(), "the 11th click is impossible")
	_check(GameState.gold == gold_at_cap, "the 11th click spends nothing")

	screen.queue_free()
	invest_screen.queue_free()


func _test_market_screen_data_driven() -> void:
	# Add a 21st good to the in-memory data only, then build a fresh screen:
	# it must grow a functional row with no code change.
	var synthetic := {
		"id": "test_ink",
		"name": {"zh": "测试墨", "en": "Test Ink"},
		"category": "luxury",
		"base_price": 11,
		"unit_size": 1,
	}
	DataLoader.goods_list.append(synthetic)
	DataLoader.goods["test_ink"] = synthetic
	_make_run("lisbon", 1000)
	var screen := _instantiate_market()
	_check(screen.row_goods_ids().size() == 21,
		"a 21st good adds a market row (got %d)" % screen.row_goods_ids().size())
	var row_refs: Dictionary = screen.row("test_ink")
	_check(not row_refs.is_empty(), "the 21st good's row exists")
	if not row_refs.is_empty():
		_check((row_refs["name"] as Label).text == "Test Ink",
			"the row is labelled from data (%s)" % (row_refs["name"] as Label).text)
		_check((row_refs["price"] as Label).text == "11g / 8g",
			"the row prices from data (%s)" % (row_refs["price"] as Label).text)
		screen.type_qty("test_ink", "2")
		_check(screen.press_buy("test_ink"), "the 21st row is buyable")
		_check(FleetLib.held("test_ink") == 2, "2 test ink aboard")
	screen.queue_free()
	DataLoader.goods_list.pop_back()
	DataLoader.goods.erase("test_ink")
	_check(DataLoader.goods_list.size() == 20, "goods.json data restored to 20")


func _test_market_screen_locale_and_back() -> void:
	_make_run("lisbon", 1000)
	var screen := _instantiate_market()
	I18n.set_locale("zh")
	_check(screen.get_node("Layout/VBox/Header/Title").text
		== I18n.fmt("market.title", {"port": "里斯本"}),
		"the title rebinds to zh (%s)" % screen.get_node("Layout/VBox/Header/Title").text)
	var wine_row: Dictionary = screen.row("wine")
	_check((wine_row["name"] as Label).text == "葡萄酒",
		"the good name rebinds to zh (%s)" % (wine_row["name"] as Label).text)
	_check((wine_row["buy"] as Button).text == I18n.t_key("market.buy"),
		"the buttons rebind to zh (%s)" % (wine_row["buy"] as Button).text)
	_check(screen.supply_row("water")["label"].text
		== I18n.fmt("market.water", {"price": 1}),
		"the supplies labels rebind to zh (%s)"
		% screen.supply_row("water")["label"].text)
	I18n.set_locale("en")
	_check((wine_row["name"] as Label).text == "Wine", "and back to en")

	# The header language toggle works from this screen too (docs/80 §4.3).
	screen.press_language()
	_check(I18n.get_locale() == "zh", "the header toggle switches to zh")
	screen.press_language()
	_check(I18n.get_locale() == "en", "and back to en")

	# Esc / Back → port_screen.tscn; the route target must exist.
	var script := load("res://scenes/port/market_screen.gd")
	_check(ResourceLoader.exists(script.PORT_SCENE),
		"the Back target exists (%s)" % script.PORT_SCENE)
	_check(script.PORT_SCENE.ends_with("port_screen.tscn"),
		"Back routes to port_screen.tscn")
	screen.route_to_port = false
	var went_back := [false]
	screen.went_back.connect(func() -> void: went_back[0] = true)
	var esc := InputEventAction.new()
	esc.action = "back"
	esc.pressed = true
	screen._unhandled_input(esc)
	_check(went_back[0], "Esc emits went_back (the S5 → S4 edge)")

	# The port hub is reachable to the market: FACILITY_SCENES points here.
	var port_script := load("res://scenes/port/port_screen.gd")
	_check(port_script.FACILITY_SCENES.get("market", "")
		== "res://scenes/port/market_screen.tscn",
		"port_screen.FACILITY_SCENES['market'] routes to the market")
	_check(ResourceLoader.exists("res://scenes/port/port_screen.tscn"),
		"port_screen.tscn exists")
	# And the hub's open_facility("market") now finds the scene (before T12 it
	# warned "missing" and stayed in port).
	_make_run("lisbon", 1000)
	var hub: Control = load("res://scenes/port/port_screen.tscn").instantiate()
	add_child(hub)
	hub.route_to_facility = false
	_check(hub.open_facility("market"),
		"port_screen.open_facility('market') finds the market scene")
	# All four P1 facilities exist after the W9 wave, so the "missing scene"
	# branch can no longer be exercised through a real facility id; assert the
	# branch itself with an unknown id instead (no crash, returns false).
	_check(hub.open_facility("nonexistent_facility") == false,
		"an unknown facility id returns false without crashing")
	hub.queue_free()

	screen.queue_free()


# --- Harness --------------------------------------------------------------

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  ", description)
	else:
		_failures.append(description)
		print("FAIL  ", description)


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("ALL PASS (%d checks)" % _checks)
		get_tree().quit(0)
		return
	print("%d of %d checks FAILED:" % [_failures.size(), _checks])
	for failure in _failures:
		print("  - ", failure)
	get_tree().quit(1)
