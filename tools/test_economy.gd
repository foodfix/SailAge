extends Node
## Phase-7 Task K acceptance tests: the flow-economy stock core
## (docs/30-PORTS-AND-TRADE.md §4.2 flow tick — tier rates 5/3/2 flag-driven,
## capacities 160/140/120 + 20/dev ceiling 200, initial stocks producers at
## capacity / consumers 60, starved-consumer semantics, market direction —,
## §4.4 tranche repricing with the worked 300-unit example, §4.5 demand
## events as consumption-rate surges ×3 (`rate_override`); docs/90-
## ARCHITECTURE.md §5.4 `market_stocks` + day-tick order;
## docs/20-WORLD-AND-SAILING.md §4.3).
##
##   godot --headless res://tools/test_economy.tscn
##
## Exits 0 when every check passes, 1 otherwise.
##
## **Pinned numeric scenario** (re-asserted by tools/sim_trade.py's parity
## block — task T reads the same §4.2 numbers; reported in task K's report):
## quanzhou (dev 0) — porcelain (specialty, flow prod 2/cons 3/capacity 120,
## base 130): capacity 120, producer seed 120, day tick clamps at 120,
## factor_units 900, buy price 117. wine (staple, base 30, consumer): seed
## 60, day tick → 55, factor 1225, buy 36 / sell 29; drained to 0 after
## 12 ticks (factor 1500, buy 45, sell 36 — a starved consumer cannot sell
## what it lacks); under a ×3 surge the day tick drains 60 → 45 (factor
## 1275, buy 38); a 120-unit dump into the drained consumer recovers to
## within 10% of steady state in exactly 18 days.

const EconomyLib := preload("res://scripts/port/economy.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_stock_init_derivation()
	_test_new_game_stocks()
	_test_factor_units()
	_test_tier_flags()
	_test_capacity_and_dev_multiplier()
	_test_flow_tick_gradient()
	_test_recovery_pacing()
	_test_determinism()
	_test_day_tick_report_and_signal()
	_test_tranche_walks()
	_test_doc_300_unit_case()
	_test_rate_surge_events()
	_test_market_direction()
	_test_pinned_scenario()
	_report()


# --- Fixtures ---------------------------------------------------------------

## A minimal livable run (the `test_trade` fixture shape) whose stock block is
## the derived initial table (producers at capacity, consumers at 60).
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
	EconomyLib.reset_events()
	EconomyLib.refresh_tiers()


## Pure-flow tick driver: the scheduler inside `day_tick` may seed an event
## on the fixture day, so each pass drops instances + surges again — the
## gradient tests below pin the PURE §4.2 flow, and the event semantics get
## their own suite section.
func _flow_ticks(count: int) -> void:
	for tick in count:
		EconomyLib.day_tick()
		EconomyLib.reset_events()


## Three synthetic ports covering the §4.2 listing rule (produces ∪ demands),
## pure of any data file.
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


# --- 1. Stock init: producers at capacity, consumers at 60, unlisted absent --

func _test_stock_init_derivation() -> void:
	var stocks := EconomyLib.build_initial_stocks(
		_synthetic_ports(), _synthetic_goods()
	)
	# wine/salt are staples (flag-driven base capacity 160; fixtures read
	# dev 0 through the Allegiance guard — docs/30 §4.2).
	_check(stocks["p_prod"]["wine"] == 160,
		"produced wine seeds at its capacity 160 (got %d)"
		% stocks["p_prod"]["wine"])
	_check(stocks["p_prod"]["salt"] == 60,
		"demanded salt seeds at the consumer 60 (got %d)"
		% stocks["p_prod"]["salt"])
	_check(not stocks["p_prod"].has("silk"),
		"an unlisted good holds no stock row at all (silk absent at p_prod)")
	# Listing rule: produces wins — wine is only produced at p_both.
	_check(stocks["p_both"]["wine"] == 160
		and stocks["p_both"]["salt"] == 160,
		"both produced goods seed at capacity despite the wine demand row")
	_check(stocks["p_flat"].is_empty(),
		"a port with no relations lists nothing (empty stock row)")
	_check(stocks.size() == 3,
		"the table is one row per port (no RNG)")
	# The derived seed of a single port-good (loader path): unknown port → 0.
	_check(EconomyLib.initial_stock_of("nowhere", "wine") == 0,
		"an unknown port derives no stock (0, not a rest value)")


# --- 2. new_game builds the derived table -----------------------------------

func _test_new_game_stocks() -> void:
	GameState.new_game("portugal", false)
	var stocks := GameState.market_stocks
	_check(stocks.size() == DataLoader.ports_list.size(),
		"new_game stocks every port (%d of %d)"
		% [stocks.size(), DataLoader.ports_list.size()])
	# Every listed port-good seeds exactly per §4.2; unlisted goods are
	# absent. Dev comes from the Allegiance guard, the same source the flow
	# tick reads — seed and tick can never disagree.
	var mismatches := 0
	for port in DataLoader.ports_list:
		var port_id := str(port.get("id", ""))
		var dev := EconomyLib.dev_level(port_id)
		for good in DataLoader.goods_list:
			var good_id := str(good.get("id", ""))
			var listed: bool = EconomyLib.is_listed_in(port, good_id)
			if listed:
				var expected := EconomyLib.initial_stock_for(
					port, good_id, dev)
				if not stocks[port_id].has(good_id) \
						or int(stocks[port_id][good_id]) != expected:
					mismatches += 1
			elif stocks[port_id].has(good_id):
				mismatches += 1
	_check(mismatches == 0,
		"every listed port-good starts exactly at its derived seed (%d mismatches)"
		% mismatches)
	# Producer seed == the live capacity (symbolic — dev comes from the
	# guard: 0 while allegiance.gd is absent, the authored floor after L's
	# module lands; the pin holds in both worlds).
	_check(int(stocks["lisbon"]["wine"])
		== EconomyLib.capacity_of("lisbon", "wine"),
		"Lisbon wine (produced) starts at its live capacity")
	# Consumers are dev-independent: the literal 60 (docs/30 §4.2).
	_check(int(stocks["london"]["wine"]) == 60,
		"London wine (demanded) starts at the consumer 60")
	_check(int(stocks["quanzhou"]["porcelain"]) == 120,
		"quanzhou porcelain (specialty producer, flow capacity 120) starts at 120")
	_check(not stocks["valencia"].has("porcelain"),
		"an unlisted specialty holds no row (porcelain absent at valencia)")
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
	# Seed stocks price the §4.2 gradient: a full producer is cheap, a
	# drained consumer dear.
	_check(EconomyLib.factor_units("quanzhou", "porcelain") == 900,
		"producer at capacity 120 → factor_units 900 (got %d)"
		% EconomyLib.factor_units("quanzhou", "porcelain"))
	_check(EconomyLib.factor_units("london", "wine") == 1200,
		"consumer seed 60 → factor_units 1200 (got %d)"
		% EconomyLib.factor_units("london", "wine"))
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
	# An unknown port/good reads as no stock (0 → factor 1500), never a crash.
	_check(EconomyLib.factor_units("nowhere", "wine") == 1500,
		"unknown port reads as no stock (factor 1500)")


# --- 4. Tier rates/capacities: flag-driven from goods.json ------------------

func _test_tier_flags() -> void:
	_make_run("lisbon")
	var staples := 0
	var middle := 0
	var luxuries := 0
	var rates_ok := true
	for good in DataLoader.goods_list:
		var good_row: Dictionary = good
		var good_id := str(good_row.get("id", ""))
		match EconomyLib.tier_of(good_id):
			"staple":
				staples += 1
			"middle":
				middle += 1
			"luxury":
				luxuries += 1
		# Independent re-derivation from the flags + flow object: the tier
		# picks the base rate/capacity, `flow` may override per key.
		var base_rate := 3
		var base_cap := 140
		if EconomyLib.tier_of(good_id) == "staple":
			base_rate = 5
			base_cap = 160
		elif EconomyLib.tier_of(good_id) == "luxury":
			base_rate = 2
			base_cap = 120
		var flow: Dictionary = good_row.get("flow", {}) \
			if good_row.get("flow", {}) is Dictionary else {}
		rates_ok = rates_ok \
			and EconomyLib.prod_rate(good_id) == int(flow.get("prod", base_rate)) \
			and EconomyLib.cons_rate(good_id) == int(flow.get("cons", base_rate)) \
			and EconomyLib.tier_capacity(good_id) == int(flow.get("capacity", base_cap))
	_check(staples == 12, "exactly 12 staples (got %d)" % staples)
	_check(middle == 16, "exactly 16 middle goods (got %d)" % middle)
	_check(luxuries == 12, "exactly 12 luxuries (got %d)" % luxuries)
	_check(rates_ok,
		"tier rates are flag-driven 5/3/2 with tier capacities 160/140/120, flow-composed")
	# Flag pins (the Phase-5 order-derived split is retired: wine is a
	# STAPLE flag now, not a base-price-rank middle good).
	_check(EconomyLib.tier_of("wine") == "staple" and EconomyLib.prod_rate("wine") == 5
		and EconomyLib.cons_rate("wine") == 5,
		"wine (staple: true) runs at 5/day both sides")
	_check(EconomyLib.tier_of("spices") == "luxury"
		and EconomyLib.prod_rate("spices") == 2 and EconomyLib.cons_rate("spices") == 3,
		"spices (specialty: true) runs its flow override prod 2 / cons 3")
	_check(EconomyLib.tier_of("dye_wood") == "middle" and EconomyLib.prod_rate("dye_wood") == 3,
		"dye_wood (unflagged) is middle at 3/day")
	# The 12 specialties carry flow overrides: prod 2 / cons 3 / capacity 120.
	var flow_ok := true
	for good in DataLoader.goods_list:
		var good_row: Dictionary = good
		if good_row.get("specialty", false) != true:
			continue
		var flow: Dictionary = good_row.get("flow", {})
		var good_id := str(good_row.get("id", ""))
		flow_ok = flow_ok and flow.get("prod", 0) == 2 \
			and flow.get("cons", 0) == 3 and flow.get("capacity", 0) == 120 \
			and EconomyLib.prod_rate(good_id) == 2 \
			and EconomyLib.cons_rate(good_id) == 3 \
			and EconomyLib.tier_capacity(good_id) == 120
	_check(flow_ok,
		"every specialty's flow override reads prod 2 / cons 3 / capacity 120")
	# Tiers really derive from the flags: a synthetic staple and a synthetic
	# flow override slot in; removing them heals the shipped table.
	var synthetic_staple := {"id": "test_flag_tea", "base_price": 9,
		"name": {"zh": "试茶", "en": "Test Tea"}, "category": "food",
		"unit_size": 1, "staple": true}
	DataLoader.goods_list.append(synthetic_staple)
	DataLoader.goods["test_flag_tea"] = synthetic_staple
	var synthetic_flow := {"id": "test_flow_silk", "base_price": 210,
		"name": {"zh": "试绸", "en": "Test Silk"}, "category": "textile",
		"unit_size": 1, "specialty": true,
		"flow": {"prod": 1, "cons": 7, "capacity": 99}}
	DataLoader.goods_list.append(synthetic_flow)
	DataLoader.goods["test_flow_silk"] = synthetic_flow
	EconomyLib.refresh_tiers()
	_check(EconomyLib.tier_of("test_flag_tea") == "staple"
		and EconomyLib.prod_rate("test_flag_tea") == 5
		and EconomyLib.tier_capacity("test_flag_tea") == 160,
		"a synthetic staple:true good derives 5/day at capacity 160")
	_check(EconomyLib.tier_of("test_flow_silk") == "luxury"
		and EconomyLib.prod_rate("test_flow_silk") == 1
		and EconomyLib.cons_rate("test_flow_silk") == 7
		and EconomyLib.tier_capacity("test_flow_silk") == 99,
		"a synthetic flow override reads prod 1 / cons 7 / capacity 99")
	DataLoader.goods_list.pop_back()
	DataLoader.goods_list.pop_back()
	DataLoader.goods.erase("test_flag_tea")
	DataLoader.goods.erase("test_flow_silk")
	EconomyLib.refresh_tiers()
	_check(EconomyLib.prod_rate("spices") == 2 and EconomyLib.cons_rate("silk") == 3,
		"the shipped flag-driven table restores after the synthetics leave")


# --- 5. Capacity & dev multiplier arithmetic (docs/30 §4.2 exact) -----------

func _test_capacity_and_dev_multiplier() -> void:
	_make_run("lisbon")
	# Pure capacity table: tier base + 20/dev, hard ceiling 200.
	var staple_caps := []
	var middle_caps := []
	var luxury_caps := []
	for dev in range(4):
		staple_caps.append(EconomyLib.capacity_for(160, dev))
		middle_caps.append(EconomyLib.capacity_for(140, dev))
		luxury_caps.append(EconomyLib.capacity_for(120, dev))
	_check(staple_caps == [160, 180, 200, 200],
		"staple capacities +20/dev ceiling 200 → 160/180/200/200 (got %s)"
		% str(staple_caps))
	_check(middle_caps == [140, 160, 180, 200],
		"middle capacities → 140/160/180/200 (got %s)" % str(middle_caps))
	_check(luxury_caps == [120, 140, 160, 180],
		"luxury capacities → 120/140/160/180 (got %s)" % str(luxury_caps))
	# Pure dev-multiplier table: rate × (4 + dev) / 4, integer.
	var r5 := []
	var r3 := []
	var r2 := []
	for dev in range(4):
		r5.append(EconomyLib.dev_rate(5, dev))
		r3.append(EconomyLib.dev_rate(3, dev))
		r2.append(EconomyLib.dev_rate(2, dev))
	_check(r5 == [5, 6, 7, 8], "staple rate 5 × dev → 5/6/7/8 (got %s)" % str(r5))
	_check(r3 == [3, 3, 4, 5], "middle rate 3 × dev → 3/3/4/5 (got %s)" % str(r3))
	_check(r2 == [2, 2, 3, 3], "luxury rate 2 × dev → 2/2/3/3 (got %s)" % str(r2))
	# A dev-0 port (neutral quanzhou — the authored floor is 0, so the guard
	# default and any future Allegiance.dev agree) reads through the table.
	_check(EconomyLib.capacity_of("quanzhou", "porcelain") == 120,
		"quanzhou porcelain capacity = 120 + 20×0 (got %d)"
		% EconomyLib.capacity_of("quanzhou", "porcelain"))
	_check(EconomyLib.capacity_of("quanzhou", "wheat") == 160,
		"quanzhou wheat (staple) capacity 160 (got %d)"
		% EconomyLib.capacity_of("quanzhou", "wheat"))
	_check(EconomyLib.capacity_of("quanzhou", "dye_wood") == 140,
		"quanzhou dye_wood (middle) capacity 140 (got %d)"
		% EconomyLib.capacity_of("quanzhou", "dye_wood"))
	# capacity_of composes the guard dev symbolically (holds before and after
	# allegiance.gd lands — docs/30 §4.9 dev floors).
	var guard_ok := true
	for port_id in ["lisbon", "london", "quanzhou"]:
		for good_id in ["wine", "porcelain", "dye_wood"]:
			guard_ok = guard_ok and EconomyLib.capacity_of(port_id, good_id) \
				== EconomyLib.capacity_for(EconomyLib.tier_capacity(good_id),
					EconomyLib.dev_level(port_id))
	_check(guard_ok, "capacity_of always composes capacity_for(tier, dev_level)")
	# The dev guard never returns a nonsense level.
	var dev_ok := true
	for port in DataLoader.ports_list:
		var dev := EconomyLib.dev_level(str(port.get("id", "")))
		if dev < 0 or dev > 3:
			dev_ok = false
	_check(dev_ok, "dev_level stays in the 0–3 band at every port (guard default 0)")


# --- 6. The flow tick: steady-state gradient --------------------------------

func _test_flow_tick_gradient() -> void:
	_make_run("lisbon")
	# Consumers drain at the tier rate and FLOOR at 0 — a starved port
	# cannot sell what it lacks (docs/30 §4.2).
	var wine_stock := EconomyLib.stock_of("london", "wine")
	_check(wine_stock == 60, "london wine starts at the consumer 60")
	var hit_zero := -1
	for tick in range(30):
		_flow_ticks(1)
		if EconomyLib.stock_of("london", "wine") == 0:
			hit_zero = tick + 1
			break
	_check(hit_zero == 12,
		"a staple consumer (5/day) drains 60 → 0 in exactly 12 days (got %d)"
		% hit_zero)
	for tick in range(5):
		_flow_ticks(1)
	_check(EconomyLib.stock_of("london", "wine") == 0,
		"the drain floors at 0 — unmet demand sits, no negative stock")
	_check(EconomyLib.factor_units("london", "wine") == 1500,
		"a starved consumer prices at the factor floor (1500)")

	# Producers fill toward capacity and CLAMP there — never past it.
	EconomyLib.set_stock("quanzhou", "porcelain", 0)
	var full_at := -1
	for tick in range(90):
		_flow_ticks(1)
		if EconomyLib.stock_of("quanzhou", "porcelain") == 120:
			full_at = tick + 1
			break
	_check(full_at == 60,
		"quanzhou porcelain refills 0 → 120 at 2/day in exactly 60 days (got %d)"
		% full_at)
	for tick in range(5):
		_flow_ticks(1)
	_check(EconomyLib.stock_of("quanzhou", "porcelain") == 120,
		"the refill clamps at capacity — the producer never overshoots")

	# The stable gradient, world-wide: after 30 pure ticks every consumer is
	# drained and every producer sits at capacity (docs/30 §4.2 steady state).
	_make_run("lisbon")
	_flow_ticks(30)
	var gradient_ok := true
	var producer_count := 0
	var consumer_count := 0
	for port in DataLoader.ports_list:
		var port_id := str(port.get("id", ""))
		var produces: Array = port.get("produces", [])
		for good_id in GameState.market_stocks[port_id]:
			if good_id in produces:
				producer_count += 1
				if int(GameState.market_stocks[port_id][good_id]) \
						!= EconomyLib.capacity_of(port_id, str(good_id)):
					gradient_ok = false
			else:
				consumer_count += 1
				if int(GameState.market_stocks[port_id][good_id]) != 0:
					gradient_ok = false
	_check(producer_count > 0 and consumer_count > 0,
		"the sweep covers both sides (%d producers, %d consumers)"
		% [producer_count, consumer_count])
	_check(gradient_ok,
		"steady state world-wide: producers at capacity, consumers drained")
	# A world at steady state is a quiet world: nothing moves.
	var moved := EconomyLib.day_tick()
	EconomyLib.reset_events()
	_check(moved.is_empty(), "a steady-state world reports no changed ports")
	# Stocks stay inside the hard [0, 200] band through any flow sequence.
	var in_band := true
	for port_id in GameState.market_stocks:
		for good_id in GameState.market_stocks[port_id]:
			var stock := int(GameState.market_stocks[port_id][good_id])
			if stock < 0 or stock > 200:
				in_band = false
	_check(in_band, "every stock stays inside [0, 200]")


# --- 7. Recovery pacing (docs/30 §4.2 / harness gate 5) ---------------------

func _test_recovery_pacing() -> void:
	_make_run("lisbon")
	# A max-hold sale dumps into a consumer; the stock recovers to within
	# 10% of steady state (factor ≥ 1350 at quanzhou wine) in ≤ 30 days —
	# at the REAL flow rate, no rest target.
	_flow_ticks(30)
	_check(EconomyLib.stock_of("quanzhou", "wine") == 0,
		"the recovery fixture starts from the drained steady state")
	EconomyLib.apply_trade("quanzhou", "wine", -120)
	_check(EconomyLib.stock_of("quanzhou", "wine") == 120,
		"the 120-unit dump lands (stock 120, factor 900)")
	var recovered := -1
	for tick in range(30):
		_flow_ticks(1)
		if EconomyLib.factor_units("quanzhou", "wine") >= 1350:
			recovered = tick + 1
			break
	_check(recovered == 18,
		"the dump recovers to within 10% of steady state in exactly 18 days (got %d)"
		% recovered)
	_check(recovered > 0 and recovered <= 30,
		"recovery pacing stays within the 30-day gate")


# --- 8. Determinism: same seed → same ticks ---------------------------------

func _test_determinism() -> void:
	# Two fresh runs of the SAME world tick identically, stock for stock.
	var runs := []
	for run in range(2):
		_make_run("lisbon")
		_flow_ticks(20)
		runs.append(JSON.stringify(GameState.market_stocks))
	_check(runs[0] == runs[1],
		"same seed → same ticks: 20 flow days replay byte-identical stocks")
	# The seeded event schedule replays exactly, too (same formula family,
	# no RNG): 720 rotation passes, twice.
	var starts := []
	for pass_index in range(2):
		_make_run("lisbon")
		var replay: Array = []
		for day in range(1, 721):
			for instance in EconomyLib.market_events_tick(day):
				replay.append("%s@%s@%d" % [instance["template_id"],
					instance["port_id"], instance["start_day"]])
		starts.append(JSON.stringify(replay))
	_check(starts[0] == starts[1],
		"the seeded event schedule replays exactly over 720 days")


# --- 9. day_tick reporting + the GameState signal path ----------------------

func _test_day_tick_report_and_signal() -> void:
	_make_run("lisbon")
	# Drive the world to the steady gradient first: under the flow economy
	# every undrained consumer moves on every tick, so an isolated "one
	# moved port" pin needs a world at rest.
	_flow_ticks(30)
	var capacity := EconomyLib.capacity_of("lisbon", "wine")
	var refill := EconomyLib.dev_rate(EconomyLib.prod_rate("wine"),
		EconomyLib.dev_level("lisbon"))
	EconomyLib.set_stock("lisbon", "wine", capacity - 2 * refill)
	var moved := EconomyLib.day_tick()
	EconomyLib.reset_events()
	_check(moved == ["lisbon"],
		"day_tick reports exactly the moved ports (got %s)" % str(moved))

	# The wired path (docs/20-* §4.3 order, ratified at the W3 merge): the
	# economy step runs inside the day tick — after the ledger, BEFORE
	# `day_advanced` is emitted (`sailing_sim.gd#advance_clock`) — and fans
	# out `market_changed` per moved port. Drive the real clock, not a bare
	# signal emit: the step precedes the emit, so a listener connected to
	# `market_changed` observes the flow, and `day_advanced` listeners see
	# post-tick stocks. The world is at steady state apart from lisbon, so
	# lisbon is the only port that can report.
	var events: Array = []
	var handler := func(port_id: String) -> void: events.append(port_id)
	EventBus.market_changed.connect(handler)
	EconomyLib.set_stock("lisbon", "wine", capacity - refill)
	var stock_before := EconomyLib.stock_of("lisbon", "wine")
	var saw_day_at_emit := {"stock": -1}
	var day_handler := func(_day: int) -> void:
		saw_day_at_emit["stock"] = EconomyLib.stock_of("lisbon", "wine")
	EventBus.day_advanced.connect(day_handler)
	preload("res://scripts/world/sailing_sim.gd").advance_clock(1.0)
	EventBus.day_advanced.disconnect(day_handler)
	_check(EconomyLib.stock_of("lisbon", "wine") == stock_before + refill,
		"the day tick runs the economy step (producer refill +%d)" % refill)
	_check(int(saw_day_at_emit["stock"]) == stock_before + refill,
		"day_advanced listeners observe post-flow stock")
	_check(events == ["lisbon"],
		"market_changed(lisbon) fired once for the moved port (got %s)"
		% str(events))
	EventBus.market_changed.disconnect(handler)


# --- 10. Tranche walks (docs/30 §4.4, unchanged plumbing) -------------------

func _test_tranche_walks() -> void:
	_make_run("lisbon")
	# docs/30 §4.4 worked example scenario stock: 30 wine bought at Lisbon
	# from stock 160 walks 700/750/800 → 21/22/24. The factor plumbing is
	# UNTOUCHED by the flow economy — only the stock trajectory changed.
	EconomyLib.set_stock("lisbon", "wine", 160)
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
	# docs/30 §4.4 worked example: 300 wine sold into London at stock 40
	# (the example's scenario stock; base_price 30, no investment, no
	# title). 16 distinct prices before the stock parks at 200, reached
	# continuously — 13 → 12, no clamp jump.
	GameState.fleet = []
	GameState.fleet.append(preload(
		"res://scripts/fleet/fleet.gd").new_ship("galleon", 0))
	EconomyLib.set_stock("london", "wine", 40)
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


# --- 11. Demand-event consumption surges (docs/30 §4.5) ---------------------

func _test_rate_surge_events() -> void:
	_make_run("lisbon")
	# The unit effect: a surge triples the CONSUMPTION rate of its good at
	# its port — and touches nothing else (production, other ports).
	EconomyLib.set_consumption_surge("london", "wine", GameState.day + 5)
	_check(EconomyLib.consumption_surged("london", "wine"),
		"the surge is active before its expiry day")
	_check(EconomyLib.cons_rate_effective("london", "wine") == 15,
		"a surged staple consumes at 5 × 3 = 15/day (got %d)"
		% EconomyLib.cons_rate_effective("london", "wine"))
	_check(EconomyLib.cons_rate_effective("lisbon", "wine") == 5,
		"the surge binds one port — lisbon keeps the plain 5/day")
	_check(EconomyLib.cons_rate_effective("london", "salt") == 5,
		"the surge binds one good — london salt keeps the plain 5/day")
	# The surged drain lands: 60 → 45 in one day (×3 → 15/day).
	_flow_ticks(1)
	_check(EconomyLib.stock_of("london", "wine") == 45,
		"the surged consumer drains 60 → 45 in one day (got %d)"
		% EconomyLib.stock_of("london", "wine"))
	# Production is untouched by a consumption surge — even when the surged
	# port produces the good (the surge would only bite a demand side, and
	# produces ∩ demands = ∅; the producer refill must stay at its rate).
	EconomyLib.set_consumption_surge("quanzhou", "porcelain",
		GameState.day + 5)
	EconomyLib.set_stock("quanzhou", "porcelain", 100)
	_flow_ticks(1)
	_check(EconomyLib.stock_of("quanzhou", "porcelain") == 102,
		"the producer refill ignores the surge (100 → 102 at 2/day, got %d)"
		% EconomyLib.stock_of("quanzhou", "porcelain"))
	EconomyLib.clear_consumption_surge("quanzhou", "porcelain")
	# The drain still floors at 0 under a surge.
	EconomyLib.set_stock("london", "wine", 0)
	_flow_ticks(1)
	_check(EconomyLib.stock_of("london", "wine") == 0,
		"a surged starved consumer stays floored at 0")
	# Expiry: active strictly before until_day, dropped from then on.
	EconomyLib.set_stock("london", "wine", 60)
	EconomyLib.set_consumption_surge("london", "wine", GameState.day + 2)
	_check(EconomyLib.consumption_surged("london", "wine",
		GameState.day + 1), "still active on until_day − 1")
	_check(not EconomyLib.consumption_surged("london", "wine",
		GameState.day + 2), "expired on until_day: the plain rate resumes")
	_check(EconomyLib.cons_rate_effective("london", "wine",
		GameState.day + 2) == 5, "expiry restores the 5/day rate")
	# reset_overrides empties the transient table.
	EconomyLib.set_consumption_surge("london", "wine", GameState.day + 9)
	EconomyLib.reset_overrides()
	_check(EconomyLib.cons_rate_effective("london", "wine") == 5,
		"reset_overrides empties the surge table")

	# The TEMPLATE path (docs/30 §4.5): a real `market_events.json`
	# instance re-applies its rate_override; expiry clears it.
	_make_run("seville")
	GameState.market_events.append({
		"template_id": "evt_war_provisioning",
		"port_id": "seville",
		"start_day": 100,
	})
	EconomyLib.ensure_event_overrides(100)
	_check(EconomyLib.cons_rate_effective("seville", "timber", 100) == 15,
		"war provisioning surges timber to 15/day (got %d)"
		% EconomyLib.cons_rate_effective("seville", "timber", 100))
	_check(EconomyLib.cons_rate_effective("seville", "iron", 100) == 15,
		"war provisioning surges iron to 15/day (got %d)"
		% EconomyLib.cons_rate_effective("seville", "iron", 100))
	# Telegraphs keep their shape (docs/30 §4.5): the affected nation's ports
	# see `{instance, template}` rows; the template carries rate_override.
	var telegraphs := EconomyLib.event_telegraphs("seville", 100)
	_check(telegraphs.size() == 1,
		"the telegraph row appears in the affected region (%d)"
		% telegraphs.size())
	if telegraphs.size() == 1:
		var template: Dictionary = telegraphs[0]["template"]
		_check(template.get("rate_override", []) == ["timber", "iron"]
			and not template.has("shifts"),
			"the template carries the rate_override list, not the retired shifts")
	var foreign := EconomyLib.event_telegraphs("lisbon", 100)
	var foreign_has := false
	for row in foreign:
		if str((row as Dictionary)["template"].get("id", "")) \
				== "evt_war_provisioning":
			foreign_has = true
	_check(not foreign_has, "a foreign port does not carry this telegraph")
	# Expiry at start + duration (100 + 60 = 160): instance dropped, surge
	# cleared, the plain rate resumes.
	GameState.day = 160
	EconomyLib.market_events_tick(160)
	_check(GameState.market_events.is_empty(),
		"the instance expires at start + duration")
	_check(EconomyLib.cons_rate_effective("seville", "timber") == 5,
		"expiry restores the plain consumption rate (5/day)")
	# Budget constants keep their meaning (docs/30 §4.5).
	_check(EconomyLib.EVENTS_PER_NATION_MAX == 1
		and EconomyLib.EVENTS_WORLD_MAX == 4,
		"the budget stays ≤ 1 per nation, ≤ 4 world-wide")


# --- 12. Market direction (docs/30 §4.2) ------------------------------------

func _test_market_direction() -> void:
	_make_run("lisbon")
	# A producing port never buys its own produced goods — the sell side is
	# disabled there (不收购; the UI rendering is M's, this is the helper).
	_check(EconomyLib.is_produced_at("lisbon", "wine"),
		"lisbon produces wine")
	_check(not EconomyLib.port_buys_good("lisbon", "wine"),
		"a producing port never buys its own produced good (sell disabled)")
	_check(EconomyLib.port_buys_good("london", "wine"),
		"a demanding port buys (sell side enabled)")
	_check(not EconomyLib.is_listed("valencia", "porcelain"),
		"an unlisted port-good (valencia porcelain) is not listed")
	_check(not EconomyLib.port_buys_good("valencia", "porcelain"),
		"an unlisted good never trades (no buy side)")
	_check(EconomyLib.is_listed("london", "wine"),
		"the listing rule: produced ∪ demanded (london wine is listed)")


# --- 13. The pinned scenario (tools/sim_trade.py parity block) --------------

func _test_pinned_scenario() -> void:
	_make_run("lisbon")
	# quanzhou (dev 0): porcelain is a specialty producer (flow prod 2 /
	# cons 3 / capacity 120, base 130); wine a staple consumer (base 30).
	_check(EconomyLib.capacity_of("quanzhou", "porcelain") == 120,
		"PINNED capacity(quanzhou, porcelain) == 120 (got %d)"
		% EconomyLib.capacity_of("quanzhou", "porcelain"))
	_check(EconomyLib.stock_of("quanzhou", "porcelain") == 120,
		"PINNED producer seed stock == 120")
	_check(EconomyLib.stock_of("quanzhou", "wine") == 60,
		"PINNED consumer seed stock == 60")
	# One day tick at dev 0: producer clamps at capacity, consumer drains 5.
	var moved := EconomyLib.day_tick()
	EconomyLib.reset_events()
	_check(moved.has("quanzhou"), "PINNED the tick moves quanzhou")
	_check(EconomyLib.stock_of("quanzhou", "porcelain") == 120,
		"PINNED porcelain after tick == 120 (clamped at capacity)")
	_check(EconomyLib.stock_of("quanzhou", "wine") == 55,
		"PINNED wine after tick == 55 (60 − 5)")
	_check(EconomyLib.factor_units("quanzhou", "porcelain") == 900,
		"PINNED factor_units(porcelain@120) == 900")
	_check(TradeEngineLib.price_from_units(130, 900, false) == 117,
		"PINNED buy price(porcelain) == 117")
	_check(EconomyLib.factor_units("quanzhou", "wine") == 1225,
		"PINNED factor_units(wine@55) == 1225")
	_check(TradeEngineLib.price_from_units(30, 1225, false) == 36,
		"PINNED buy price(wine@55) == 36")
	_check(TradeEngineLib.price_from_units(30, 1225, true) == 29,
		"PINNED sell price(wine@55) == 29")
	# Drained after 12 ticks: starved-consumer pricing.
	_flow_ticks(12)
	_check(EconomyLib.stock_of("quanzhou", "wine") == 0,
		"PINNED wine drains 60 → 0 in 12 ticks")
	_check(EconomyLib.factor_units("quanzhou", "wine") == 1500,
		"PINNED factor_units(wine@0) == 1500")
	_check(TradeEngineLib.price_from_units(30, 1500, false) == 45,
		"PINNED buy price(wine@0) == 45")
	_check(TradeEngineLib.price_from_units(30, 1500, true) == 36,
		"PINNED sell price(wine@0) == 36")
	# Surge day: ×3 consumption drains 60 → 45 (factor 1275, buy 38).
	_make_run("lisbon")
	EconomyLib.set_consumption_surge("quanzhou", "wine", GameState.day + 30)
	EconomyLib.day_tick()
	EconomyLib.reset_overrides()
	_check(EconomyLib.stock_of("quanzhou", "wine") == 45,
		"PINNED surged tick: wine 60 → 45 (15/day)")
	_check(EconomyLib.factor_units("quanzhou", "wine") == 1275,
		"PINNED factor_units(wine@45) == 1275")
	_check(TradeEngineLib.price_from_units(30, 1275, false) == 38,
		"PINNED buy price(wine@45) == 38")


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
