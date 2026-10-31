extends Node
## Phase-5 Task G acceptance tests: the stock economy core
## (docs/30-PORTS-AND-TRADE.md §4.2 stock/factor/tiers/drift, §4.4 tranche
## repricing with the worked 300-unit example, §4.5 demand-event rest
## overrides; docs/90-ARCHITECTURE.md §5.4 `market_stocks` + day-tick order;
## docs/20-WORLD-AND-SAILING.md §4.3).
##
##   godot --headless res://tools/test_economy.tscn
##
## Exits 0 when every check passes, 1 otherwise.

const EconomyLib := preload("res://scripts/port/economy.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_stock_init_derivation()
	_test_new_game_stocks()
	_test_factor_units()
	_test_tier_derivation()
	_test_drift_tiers()
	_test_drift_never_past_rest()
	_test_day_tick_report_and_signal()
	_test_tranche_walks()
	_test_doc_300_unit_case()
	_test_rest_overrides()
	_report()


# --- Fixtures ---------------------------------------------------------------

## A minimal livable run (the `test_trade` fixture shape) whose stock block is
## the derived resting table.
func _make_run(port_id: String) -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10},
		"xp": 0, "level": 1, "officers": [], "reputation": {},
	}
	for nation_id in NATIONS:
		GameState.player["reputation"][nation_id] = 0
	GameState.fleet = []
	GameState.day = 1
	GameState.gold = 10000
	GameState.morale = 70
	GameState.current_port = port_id
	GameState.port_investments = {}
	GameState.known_ports = [port_id]
	GameState.world = {"position": {"x": 0, "y": 0}, "clock_fraction": 0.0,
		"weather": "fair"}
	GameState.market_stocks = EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list
	)
	EconomyLib.reset_overrides()
	EconomyLib.refresh_tiers()


## Three synthetic ports covering the §4.2 precedence (produced beats
## demanded beats neutral), pure of any data file.
func _synthetic_ports() -> Array:
	return [
		{"id": "p_prod", "produces": ["wine"], "demands": ["salt"]},
		{"id": "p_both", "produces": ["wine", "salt"], "demands": ["wine"]},
		{"id": "p_flat", "produces": [], "demands": []},
	]


func _synthetic_goods() -> Array:
	return [
		{"id": "wine", "base_price": 30},
		{"id": "salt", "base_price": 12},
		{"id": "silk", "base_price": 110},
	]


# --- 1. Stock init: the 160/40/100 precedence -------------------------------

func _test_stock_init_derivation() -> void:
	var stocks := EconomyLib.build_initial_stocks(
		_synthetic_ports(), _synthetic_goods()
	)
	_check(stocks["p_prod"]["wine"] == 160,
		"produced rests at 160 (got %d)" % stocks["p_prod"]["wine"])
	_check(stocks["p_prod"]["salt"] == 40,
		"demanded rests at 40 (got %d)" % stocks["p_prod"]["salt"])
	_check(stocks["p_prod"]["silk"] == 100,
		"neutral rests at 100 (got %d)" % stocks["p_prod"]["silk"])
	# Precedence: a good both produced and demanded rests at the PRODUCED 160
	# (docs/30 §4.2 "produced → demanded" order).
	_check(stocks["p_both"]["wine"] == 160,
		"produced wins over demanded: wine rests at 160 (got %d)"
		% stocks["p_both"]["wine"])
	_check(stocks["p_both"]["salt"] == 160,
		"the second produced good rests at 160 (got %d)"
		% stocks["p_both"]["salt"])
	_check(stocks["p_flat"]["wine"] == 100
		and stocks["p_flat"]["salt"] == 100
		and stocks["p_flat"]["silk"] == 100,
		"a port with no relations rests everything at 100")
	_check(stocks.size() == 3 and stocks["p_prod"].size() == 3,
		"the table is one row per port × one column per good (no RNG)")


# --- 2. new_game builds the derived table -----------------------------------

func _test_new_game_stocks() -> void:
	GameState.new_game("portugal", false)
	var stocks := GameState.market_stocks
	_check(stocks.size() == DataLoader.ports_list.size(),
		"new_game stocks every port (%d of %d)"
		% [stocks.size(), DataLoader.ports_list.size()])
	var mismatches := 0
	for port in DataLoader.ports_list:
		var port_id := str(port.get("id", ""))
		for good in DataLoader.goods_list:
			var good_id := str(good.get("id", ""))
			var expected := EconomyLib.resting_stock_of(port, good_id)
			if int(stocks[port_id][good_id]) != expected:
				mismatches += 1
	_check(mismatches == 0,
		"every one of the %d port-goods starts exactly at its derived rest"
		% (DataLoader.ports_list.size() * DataLoader.goods_list.size()))
	_check(int(stocks["lisbon"]["wine"]) == 160,
		"Lisbon wine (produced) starts at 160")
	_check(int(stocks["london"]["wine"]) == 40,
		"London wine (demanded) starts at 40")
	_check(int(stocks["valencia"]["wine"]) == 100,
		"Valencia wine (neutral) starts at 100")
	# The other Phase-5 blocks initialize empty/default (docs/90-* §8.1).
	_check(GameState.wrecks == [] and GameState.wrecks is Array,
		"wrecks starts []")
	_check(GameState.npc_preset == "normal",
		"npc_preset starts 'normal' (got '%s')" % GameState.npc_preset)
	_check(GameState.market_events == [] and GameState.market_events is Array,
		"market_events starts []")


# --- 3. The exact factor ----------------------------------------------------

func _test_factor_units() -> void:
	_make_run("lisbon")
	# Rest reproduces the retired statics EXACTLY (the done-when anchor).
	_check(EconomyLib.factor_units("lisbon", "wine") == 700,
		"rest 160 → factor_units 700 (0.7) (got %d)"
		% EconomyLib.factor_units("lisbon", "wine"))
	_check(EconomyLib.factor_units("london", "wine") == 1300,
		"rest 40 → factor_units 1300 (1.3) (got %d)"
		% EconomyLib.factor_units("london", "wine"))
	_check(EconomyLib.factor_units("valencia", "wine") == 1000,
		"rest 100 → factor_units 1000 (1.0) (got %d)"
		% EconomyLib.factor_units("valencia", "wine"))
	# Clamp edges over the whole stock range: 0 → 1500, 200 → 500, inside the
	# [500, 2000] band by construction; monotone decreasing in stock.
	EconomyLib.set_stock("lisbon", "wine", 0)
	_check(EconomyLib.factor_units("lisbon", "wine") == 1500,
		"stock 0 → factor_units 1500 (got %d)"
		% EconomyLib.factor_units("lisbon", "wine"))
	EconomyLib.set_stock("lisbon", "wine", 200)
	_check(EconomyLib.factor_units("lisbon", "wine") == 500,
		"stock 200 → factor_units 500 (got %d)"
		% EconomyLib.factor_units("lisbon", "wine"))
	# The pure formula clamps too (the 2000 side is the documented safety net).
	_check(EconomyLib.factor_for_stock(-1000) == 2000,
		"factor_for_stock clamps absurd (negative) stock to the 2000 net")
	_check(EconomyLib.factor_for_stock(1000) == 500,
		"factor_for_stock stays at 500 past the stock ceiling")
	var monotone := true
	var previous := 2001
	for stock in range(0, 201):
		var factor := EconomyLib.factor_for_stock(stock)
		if factor > previous:
			monotone = false
		previous = factor
	_check(monotone, "factor_units is monotonically non-increasing in stock")
	# set_stock hard-clamps to [0, 200] (docs/30 §4.2).
	EconomyLib.set_stock("lisbon", "wine", -5)
	_check(EconomyLib.stock_of("lisbon", "wine") == 0,
		"set_stock clamps −5 to 0")
	EconomyLib.set_stock("lisbon", "wine", 999)
	_check(EconomyLib.stock_of("lisbon", "wine") == 200,
		"set_stock clamps 999 to 200")
	# An unknown port/good reads as neutral rest, never a crash.
	_check(EconomyLib.factor_units("nowhere", "wine") == 1000,
		"unknown port reads as neutral rest (factor 1000)")


# --- 4. Consumption tiers: 5/10/5 derived from goods.json -------------------

func _test_tier_derivation() -> void:
	_make_run("lisbon")
	var staples := 0
	var middle := 0
	var luxuries := 0
	for good in DataLoader.goods_list:
		match EconomyLib.tier_rate(str(good.get("id", ""))):
			EconomyLib.DRIFT_STAPLE: staples += 1
			EconomyLib.DRIFT_MIDDLE: middle += 1
			EconomyLib.DRIFT_LUXURY: luxuries += 1
	_check(staples == 5, "exactly 5 staples at ±3/day (got %d)" % staples)
	_check(middle == 10, "exactly 10 middle goods at ±2/day (got %d)" % middle)
	_check(luxuries == 5, "exactly 5 luxuries at ±1/day (got %d)" % luxuries)
	# The ranking rule (base_price asc, id asc): cheapest is the first staple,
	# priciest the last luxury, wine (base 30) sits mid-table.
	_check(EconomyLib.tier_index("wheat") == 0,
		"wheat (8g) ranks first (got %d)" % EconomyLib.tier_index("wheat"))
	_check(EconomyLib.tier_rate("wheat") == EconomyLib.DRIFT_STAPLE,
		"wheat is a staple")
	_check(EconomyLib.tier_rate("spices") == EconomyLib.DRIFT_LUXURY,
		"spices (150g) is a luxury")
	_check(EconomyLib.tier_index("spices") == 19,
		"spices rank last (got %d)" % EconomyLib.tier_index("spices"))
	_check(EconomyLib.tier_rate("wine") == EconomyLib.DRIFT_MIDDLE,
		"wine (30g) is a middle good (idx %d)" % EconomyLib.tier_index("wine"))
	# Tiers really derive from goods.json: a synthetic 9g good slots into the
	# staples; remove it and the table heals back.
	var synthetic := {"id": "test_tier_tea", "base_price": 9,
		"name": {"zh": "试茶", "en": "Test Tea"}, "category": "food",
		"unit_size": 1}
	DataLoader.goods_list.append(synthetic)
	DataLoader.goods["test_tier_tea"] = synthetic
	EconomyLib.refresh_tiers()
	_check(EconomyLib.tier_rate("test_tier_tea") == EconomyLib.DRIFT_STAPLE,
		"a synthetic 9g good derives as a staple (cheaper than salt 12g)")
	_check(EconomyLib.tier_index("test_tier_tea") == 1,
		"the 9g good slots between wheat 8g and dried_fish 10g (idx %d)"
		% EconomyLib.tier_index("test_tier_tea"))
	_check(EconomyLib.tier_index("salt") == 3,
		"salt (12g) is pushed down one rank (idx %d)"
		% EconomyLib.tier_index("salt"))
	DataLoader.goods_list.pop_back()
	DataLoader.goods.erase("test_tier_tea")
	EconomyLib.refresh_tiers()
	_check(EconomyLib.tier_rate("spices") == EconomyLib.DRIFT_LUXURY,
		"the shipped 5/10/5 table restores after the synthetic good leaves")


# --- 5. Drift heals a 30-unit nudge at the tier rate ------------------------

func _test_drift_tiers() -> void:
	_make_run("lisbon")
	# The done-when pair: a staple heals 30 units in 10 days, a luxury in 30.
	var wheat_rest := EconomyLib.rest_stock("lisbon", "wheat")
	EconomyLib.set_stock("lisbon", "wheat", wheat_rest - 30)
	var healed := 0
	for tick in range(30):
		EconomyLib.day_tick()
		if EconomyLib.stock_of("lisbon", "wheat") == wheat_rest:
			healed = tick + 1
			break
	_check(healed == 10,
		"a staple heals a 30-unit nudge in exactly 10 days (got %d)" % healed)
	_check(EconomyLib.stock_of("lisbon", "wheat") == wheat_rest,
		"the staple sits back at rest")

	var spices_rest := EconomyLib.rest_stock("lisbon", "spices")
	EconomyLib.set_stock("lisbon", "spices", spices_rest - 30)
	var luxury_progress := -1
	for tick in range(30):
		EconomyLib.day_tick()
		luxury_progress = EconomyLib.stock_of("lisbon", "spices")
		if luxury_progress == spices_rest:
			break
	_check(luxury_progress == spices_rest,
		"a luxury heals a 30-unit nudge in exactly 30 days (landed on day %d)"
		% (30 - (spices_rest - luxury_progress)))
	_check(EconomyLib.stock_of("lisbon", "spices") == spices_rest,
		"the luxury sits back at rest after 30 ticks")

	# The tiers demonstrably differ: wine (middle, ±2) takes 15 for the same
	# nudge — between the staple's 10 and the luxury's 30.
	var wine_rest := EconomyLib.rest_stock("lisbon", "wine")
	EconomyLib.set_stock("lisbon", "wine", wine_rest - 30)
	var wine_days := 0
	for tick in range(30):
		wine_days = tick + 1
		EconomyLib.day_tick()
		if EconomyLib.stock_of("lisbon", "wine") == wine_rest:
			break
	_check(wine_days == 15, "a middle good heals 30 units in 15 days (got %d)"
		% wine_days)


func _test_drift_never_past_rest() -> void:
	_make_run("lisbon")
	# A small nudge lands exactly on rest — never past it (docs/30 §4.2).
	var rest := EconomyLib.rest_stock("lisbon", "wine")
	EconomyLib.set_stock("lisbon", "wine", rest - 5)
	var never_past := true
	for tick in range(5):
		EconomyLib.day_tick()
		if EconomyLib.stock_of("lisbon", "wine") > rest:
			never_past = false
	_check(never_past and EconomyLib.stock_of("lisbon", "wine") == rest,
		"an undershooting nudge heals to exactly rest, never past it (%d)"
		% EconomyLib.stock_of("lisbon", "wine"))
	EconomyLib.set_stock("lisbon", "wine", rest + 7)
	var never_under := true
	for tick in range(5):
		EconomyLib.day_tick()
		if EconomyLib.stock_of("lisbon", "wine") < rest:
			never_under = false
	_check(never_under and EconomyLib.stock_of("lisbon", "wine") == rest,
		"an overshooting stock drains to exactly rest, never past it (%d)"
		% EconomyLib.stock_of("lisbon", "wine"))
	EconomyLib.set_stock("lisbon", "wine", rest)
	# A world at rest is a quiet world: no stock moves, nothing to report.
	var before := GameState.market_stocks.duplicate(true)
	var moved := EconomyLib.day_tick()
	_check(moved.is_empty(), "a resting world reports no changed ports")
	_check(GameState.market_stocks == before, "a resting world stock is stable")
	# Stocks stay inside the hard [0, 200] band through any drift sequence.
	var in_band := true
	for port_id in GameState.market_stocks:
		for good_id in GameState.market_stocks[port_id]:
			var stock := int(GameState.market_stocks[port_id][good_id])
			if stock < 0 or stock > 200:
				in_band = false
	_check(in_band, "every stock stays inside [0, 200]")


# --- 6. day_tick reporting + the GameState signal path ----------------------

func _test_day_tick_report_and_signal() -> void:
	_make_run("lisbon")
	EconomyLib.set_stock("lisbon", "wine",
		EconomyLib.rest_stock("lisbon", "wine") - 4)
	var moved := EconomyLib.day_tick()
	_check(moved == ["lisbon"],
		"day_tick reports exactly the moved ports (got %s)" % str(moved))

	# The wired path: GameState listens on `day_advanced` (docs/20 §4.3 order)
	# and fans out `market_changed` per moved port.
	var events: Array = []
	var handler := func(port_id: String) -> void: events.append(port_id)
	EventBus.market_changed.connect(handler)
	EconomyLib.set_stock("lisbon", "wine",
		EconomyLib.rest_stock("lisbon", "wine") - 2)
	var stock_before := EconomyLib.stock_of("lisbon", "wine")
	EventBus.day_advanced.emit(GameState.day)
	_check(EconomyLib.stock_of("lisbon", "wine") == stock_before + 2,
		"the day_advanced listener runs the economy step (drift +2)")
	_check(events == ["lisbon"],
		"market_changed(lisbon) fired once for the moved port (got %s)"
		% str(events))
	EventBus.market_changed.disconnect(handler)


# --- 7. Tranche walks (docs/30 §4.4) ----------------------------------------

func _test_tranche_walks() -> void:
	_make_run("lisbon")
	# Buying 30 wine at Lisbon walks 700/750/800 → 21/22/24 (docs/30 §4.4).
	var walk := EconomyLib.plan_trade("lisbon", "wine", 30)
	var stocks_before: Array = []
	var factors: Array = []
	for tranche in walk:
		stocks_before.append(int(tranche["stock_before"]))
		factors.append(int(tranche["factor_units"]))
	_check(stocks_before == [160, 150, 140],
		"the buy walk transacts at stock-before each tranche (got %s)"
		% str(stocks_before))
	_check(factors == [700, 750, 800],
		"the buy walk factors are 700/750/800 (got %s)" % str(factors))
	var prices: Array = []
	for tranche in walk:
		prices.append(TradeEngineLib.price_from_units(30,
			int(tranche["factor_units"]), false))
	_check(prices == [21, 22, 24],
		"the tranche prices are exactly 21/22/24 (got %s)" % str(prices))
	# apply_trade books the stock where the walk leaves it: 160 → 130.
	var booked := EconomyLib.apply_trade("lisbon", "wine", 30)
	_check(EconomyLib.stock_of("lisbon", "wine") == 130,
		"apply_trade books the walked stock (160 → 130, got %d)"
		% EconomyLib.stock_of("lisbon", "wine"))
	_check(booked.size() == 3, "apply_trade returns the walk it booked")
	# A partial last tranche: 25 units = 10 + 10 + 5.
	EconomyLib.set_stock("lisbon", "wine", 160)
	var partial := EconomyLib.plan_trade("lisbon", "wine", 25)
	_check(int(partial[2]["units"]) == 5,
		"the last tranche carries the remainder (5 units, got %d)"
		% int(partial[2]["units"]))
	_check(EconomyLib.plan_trade("lisbon", "wine", 0).is_empty(),
		"a zero-quantity trade plans no tranches")
	# qty_signed direction: a negative quantity RAISES stock (sell).
	EconomyLib.set_stock("lisbon", "wine", 100)
	EconomyLib.apply_trade("lisbon", "wine", -20)
	_check(EconomyLib.stock_of("lisbon", "wine") == 120,
		"a signed-negative walk books the stock up (100 → 120)")


func _test_doc_300_unit_case() -> void:
	_make_run("london")
	# docs/30 §4.4 worked example: 300 wine sold into London (rest 40,
	# base_price 30, no investment, no title). 16 distinct prices before the
	# stock parks at 200, reached continuously — 13 → 12, no clamp jump.
	GameState.fleet = []
	GameState.fleet.append(preload(
		"res://scripts/fleet/fleet.gd").new_ship("galleon", 0))
	var walk := EconomyLib.plan_trade("london", "wine", -300)
	_check(walk.size() == 30, "300 units split into 30 tranches (got %d)"
		% walk.size())
	var prices: Array = []
	for tranche in walk:
		prices.append(TradeEngineLib.price_from_units(30,
			int(tranche["factor_units"]), true))
	_check(prices.slice(0, 16) == [
			31, 30, 28, 27, 26, 25, 24, 22, 21, 20, 19, 18, 16, 15, 14, 13],
		"the first 16 tranche prices match the doc table (got %s)"
		% str(prices.slice(0, 16)))
	var parked := true
	for index in range(16, 30):
		if int(walk[index]["stock_before"]) != 200 \
				or int(walk[index]["factor_units"]) != 500 \
				or prices[index] != 12:
			parked = false
	_check(parked, "tranches 17–30 park at stock 200 / factor 500 / price 12")
	_check(prices[15] == 13 and prices[16] == 12,
		"the walk lands on the bound continuously (13 → 12, no clamp jump)")
	var proceeds := 0
	for index in walk.size():
		proceeds += prices[index] * int(walk[index]["units"])
	_check(proceeds == 5170,
		"the exact summed proceeds are 5,170g, not 9,300g flat (got %d)"
		% proceeds)
	EconomyLib.apply_trade("london", "wine", -300)
	_check(EconomyLib.stock_of("london", "wine") == 200,
		"the booked stock parks at the 200 bound (got %d)"
		% EconomyLib.stock_of("london", "wine"))


# --- 8. Demand-event rest overrides (docs/30 §4.5) --------------------------

func _test_rest_overrides() -> void:
	_make_run("lisbon")
	var derived := EconomyLib.rest_stock("lisbon", "wine")
	# An active override replaces the drift target.
	EconomyLib.set_rest_override("lisbon", "wine", 40, GameState.day + 5)
	_check(EconomyLib.effective_rest("lisbon", "wine") == 40,
		"the override replaces the derived rest (got %d)"
		% EconomyLib.effective_rest("lisbon", "wine"))
	_check(EconomyLib.effective_rest("valencia", "wine") == 100,
		"an override at one port leaves other ports' derived rest alone")
	# The effect clamp: rest += shift lands in [10, 190] (docs/30 §4.5).
	EconomyLib.set_rest_override("lisbon", "wine", 5, GameState.day + 5)
	_check(EconomyLib.effective_rest("lisbon", "wine") == 10,
		"an override under 10 clamps up to 10 (got %d)"
		% EconomyLib.effective_rest("lisbon", "wine"))
	EconomyLib.set_rest_override("lisbon", "wine", 250, GameState.day + 5)
	_check(EconomyLib.effective_rest("lisbon", "wine") == 190,
		"an override over 190 clamps down to 190 (got %d)"
		% EconomyLib.effective_rest("lisbon", "wine"))
	# Drift heals toward the OVERRIDDEN rest (wine is a middle good: ±2/day).
	EconomyLib.set_stock("lisbon", "wine", 160)
	EconomyLib.set_rest_override("lisbon", "wine", 190, GameState.day + 5)
	EconomyLib.day_tick()
	_check(EconomyLib.stock_of("lisbon", "wine") == 162,
		"drift refills toward the overridden 190 rest (160 → 162, got %d)"
		% EconomyLib.stock_of("lisbon", "wine"))
	EconomyLib.set_rest_override("lisbon", "wine", 40, GameState.day + 5)
	EconomyLib.day_tick()
	_check(EconomyLib.stock_of("lisbon", "wine") == 160,
		"drift drains toward the overridden 40 rest (162 → 160, got %d)"
		% EconomyLib.stock_of("lisbon", "wine"))
	# Expiry: active strictly before until_day, dropped from then on.
	EconomyLib.set_rest_override("lisbon", "wine", 40, GameState.day + 2)
	_check(EconomyLib.effective_rest("lisbon", "wine") == 40,
		"the override is active the day before its expiry")
	_check(EconomyLib.effective_rest("lisbon", "wine",
		GameState.day + 1) == 40, "still active on until_day − 1")
	_check(EconomyLib.effective_rest("lisbon", "wine",
		GameState.day + 2) == derived,
		"expired on until_day: the derived rest resumes")
	_check(EconomyLib.effective_rest("lisbon", "wine") == derived,
		"an expired override is dropped on read")
	# …and the tick sweeps expired overrides too. day_tick itself does not
	# move the clock — the day tick order advances `GameState.day` first
	# (docs/20 §4.3) — so the test advances the day like the sim does.
	EconomyLib.set_rest_override("lisbon", "wine", 40, GameState.day + 1)
	_check(EconomyLib.effective_rest("lisbon", "wine") == 40,
		"the override governs every tick before its expiry day")
	GameState.day += 1
	EconomyLib.day_tick()
	_check(EconomyLib.effective_rest("lisbon", "wine") == derived,
		"day_tick drops the override once expired (derived rest resumes)")
	GameState.day -= 1
	# clear/reset seams.
	EconomyLib.set_rest_override("lisbon", "wine", 40, GameState.day + 9)
	EconomyLib.clear_rest_override("lisbon", "wine")
	_check(EconomyLib.effective_rest("lisbon", "wine") == derived,
		"clear_rest_override restores the derived rest immediately")
	EconomyLib.set_rest_override("lisbon", "wine", 40, GameState.day + 9)
	EconomyLib.reset_overrides()
	_check(EconomyLib.effective_rest("lisbon", "wine") == derived,
		"reset_overrides empties the transient table")


# --- Harness ----------------------------------------------------------------

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
