extends Node
## T12 acceptance tests, re-baselined for Phase 7 (task L — correction 7):
## the listing rule, the §4.10 unified tariff on both sides, the §4.9
## investment ledger/monthly cap/diplomatic gate, permits and treasury credit
## (docs/30-* §4.2–§4.4, §4.9, §4.10, §5; docs/40-* §4.2; docs/50-* §4.3,
## §4.6; docs/20-* §4.10; docs/80-* §4.16 contracts).
##
##   godot --headless res://tools/test_trade.tscn
##
## The market-screen cases moved to task M's `tools/test_market_screen.*`
## (the W3 pins keep suite files single-owner); this suite stays engine-level.
##
## Exits 0 when every check passes, 1 otherwise.

const EconomyLib := preload("res://scripts/port/economy.gd")
const TradeEngineLib := preload("res://scripts/port/trade_engine.gd")
const AllegianceLib := preload("res://scripts/port/allegiance.gd")
const PalaceEngineLib := preload("res://scripts/port/palace_engine.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")

const NATIONS := ["portugal", "spain", "england", "holland", "ottoman", "italy"]

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_test_worked_examples()
	_test_factor_and_discount()
	_test_investment_cap()
	_test_month_cap_and_gates()
	_test_band_clamp()
	_test_quantity_limits()
	_test_buy_clamps()
	_test_tranche_repricing()
	_test_market_changed_on_trades()
	_test_listing_rule()
	_test_tariff_matrix()
	_test_tariff_on_trades()
	_test_permits_and_treasury_credit()
	_test_supplies_ignore_factors()
	_test_sell_profit_xp_and_reputation()
	_test_profit_survives_save_roundtrip()
	_test_capacity_flagship_first()
	_test_tariff_discount()
	_test_permit_prices()
	_test_price_memory()
	_report()


# --- Fixtures --------------------------------------------------------------

## A livable run docked at `port_id`: one empty caravel (capacity 120), plain
## stats, no investments, no prior profit bookkeeping. Every port-good sits at
## its derived rest (produced 160 / demanded 40), set explicitly per pair so
## the §5 pins hold whatever initial-stock scheme the flow economy ships; the
## allegiance state is freshly seeded (treasuries 5,000g, no permits).
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
	# Title/bounty/fame isolation: an earlier fixture's england knighthood
	# must never leak into this run's §4.2 sell-side title bonus.
	GameState.titles = {}
	GameState.bounties = {}
	GameState.fame = 0
	# Phase 7 flow economy (K), stocks EXPLICIT per pair so every price pin
	# below is seed-independent (the test_economy fixture pattern): producers
	# at their dev-0 capacity, consumers at the §5 rest 40 — the stock the
	# docs/30 §5 worked examples were computed at.
	GameState.market_stocks = EconomyLib.build_initial_stocks(
		DataLoader.ports_list, DataLoader.goods_list
	)
	for port in DataLoader.ports_list:
		var p := port as Dictionary
		var pid := str(p.get("id", ""))
		for good in DataLoader.goods_list:
			var gid := str((good as Dictionary).get("id", ""))
			if not EconomyLib.is_listed_in(p, gid):
				continue
			if gid in p.get("produces", []):
				EconomyLib.set_stock(pid, gid,
					EconomyLib.initial_stock_for(p, gid, 0))
			else:
				EconomyLib.set_stock(pid, gid, 40)
	EconomyLib.reset_overrides()
	AllegianceLib.seed_new_game()
	var port: Dictionary = DataLoader.get_port(port_id)
	GameState.world = {
		"position": port.get("position", {"x": 0, "y": 0}).duplicate(),
		# §4.1b port hours (added 2026-11-02): 12:00 — every facility open,
		# so the trading exercises the price plumbing, not the closed rule.
		"clock_fraction": 0.5,
		"weather": "fair",
	}
	CharacterLib.pending_levelup = false


## Docks at `to_port` without rebuilding the run (the Lisbon → London leg).
func _dock(to_port: String, gold: int = -1) -> void:
	GameState.current_port = to_port
	# §4.1b: each leg models another day — back inside every window.
	GameState.world["clock_fraction"] = 0.5
	if gold >= 0:
		GameState.gold = gold


## §4.1b port hours: moves the wall clock back to 12:00, inside every
## facility's window. The §4.1b hour charges are real, so a scenario that
## chains more actions than one opening window allows calls this between
## them (each call models "came back the next day").
func _open_market() -> void:
	GameState.world["clock_fraction"] = 0.5


# --- Phase 8 skill seam ------------------------------------------------------

## Stand-in for slot A's `Skills` module (`W3-A` pins `effective_skill(key)`
## as the API, `skill(key)` the base-only fallback).
class FakeSkills extends RefCounted:
	var values: Dictionary = {}

	func effective_skill(key: String) -> int:
		return int(values.get(key, 0))

	func skill(key: String) -> int:
		return effective_skill(key)


## Pins the player's appraisal/negotiation through both engine seams
## (`trade_engine` reads the tariff discount + memory capacity, `allegiance`
## the permit gates).
func _set_skills(appraisal: int, negotiation: int) -> void:
	var fake := FakeSkills.new()
	fake.values = {"appraisal": appraisal, "negotiation": negotiation}
	TradeEngineLib.skills_override = fake
	AllegianceLib.skills_override = fake


## Clears the seam and the session-transient price memory (test hygiene).
func _clear_skills() -> void:
	TradeEngineLib.skills_override = null
	AllegianceLib.skills_override = null
	TradeEngineLib.reset_price_memory()


func _test_worked_examples() -> void:
	# docs/30 §5: Lisbon produces wine → buy 21 / sell 16 (price plumbing —
	# the §4.10 tariff composes after it as a separate line).
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
	# §5 note: the route nets 10g/unit at the pre-tax prices.
	_check(TradeEngineLib.sell_price("london", "wine")
			- TradeEngineLib.buy_price("lisbon", "wine") == 10,
		"§5 Lisbon buy 21 → London sell 31 nets 10g/unit before tax")

	# A demanded good trades at 1.3 (the Phase-5 neutral case is retired by
	# the listing rule — every listed good is produced or demanded): Valencia
	# demands wine, so it reads like London (protected spain, foreign trader:
	# the 20% tariff is the tax line's business, not the price's).
	_check(is_equal_approx(TradeEngineLib.factor("valencia", "wine"), 1.3),
		"Valencia demands wine → factor 1.3 (got %.3f)"
		% TradeEngineLib.factor("valencia", "wine"))
	_check(TradeEngineLib.buy_price("valencia", "wine") == 39,
		"Valencia wine buy == 39 (got %d)"
		% TradeEngineLib.buy_price("valencia", "wine"))
	# A demanded staple at Lisbon: wheat 8g base → 10 / 8.
	_check(TradeEngineLib.buy_price("lisbon", "wheat") == 10,
		"Lisbon wheat (demanded, 1.3) buy == 10 (got %d)"
		% TradeEngineLib.buy_price("lisbon", "wheat"))
	_check(TradeEngineLib.sell_price("lisbon", "wheat") == 8,
		"Lisbon wheat sell == floor(8 × 1.3 × 0.8) = 8 (got %d)"
		% TradeEngineLib.sell_price("lisbon", "wheat"))


func _test_factor_and_discount() -> void:
	_make_run("lisbon")
	# The factor is a pure function of the stock (docs/30 §4.2): 160 → 0.7,
	# 40 → 1.3, 100 → 1.0 — checked at explicit stocks so the pin is
	# independent of whichever initial stocks the flow economy ships.
	EconomyLib.set_stock("lisbon", "wine", 160)
	_check(is_equal_approx(TradeEngineLib.factor("lisbon", "wine"), 0.7),
		"stock 160 → factor 0.7")
	EconomyLib.set_stock("lisbon", "wine", 40)
	_check(is_equal_approx(TradeEngineLib.factor("lisbon", "wine"), 1.3),
		"stock 40 → factor 1.3")
	EconomyLib.set_stock("lisbon", "wine", 100)
	_check(is_equal_approx(TradeEngineLib.factor("lisbon", "wine"), 1.0),
		"stock 100 → factor 1.0")
	EconomyLib.set_stock("lisbon", "wine", 0)
	_check(is_equal_approx(TradeEngineLib.factor("lisbon", "wine"), 1.5),
		"stock 0 → factor 1.5 (drained extreme)")
	EconomyLib.set_stock("lisbon", "wine", 160)

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
	# An unknown port reads as stock-less (flow economy: no derived row →
	# stock 0 → the drained extreme 1.5), and never crashes.
	_check(TradeEngineLib.buy_price("nowhere", "wine") == 45,
		"unknown port is stock-less: wine buy == floor(30 × 1.5) = 45 (got %d)"
		% TradeEngineLib.buy_price("nowhere", "wine"))


func _test_investment_cap() -> void:
	# Protected port (lisbon): the discount is the whole effect, so the 5,000g
	# lifetime cap still ends investment — 10 × 500g → exactly −10%.
	_make_run("lisbon", 10000)
	for click in range(1, 11):
		_open_market()
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
		_check(AllegianceLib.month_invested_gold("lisbon") == 0,
			"click %d: protected ports book no monthly allowance" % click)
		_check(AllegianceLib.ledger_total("lisbon") == 0,
			"click %d: protected ports write no ledger" % click)

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
		"11th click: can_invest is false (protected cap)")
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
		_open_market()
		TradeEngineLib.invest("lisbon")
	_check(TradeEngineLib.invested("london") == 0,
		"investment is per port: London has 0g invested")
	_check(TradeEngineLib.buy_price("london", "wine") == 39,
		"London wine buy is unaffected by Lisbon's investment (got %d)"
		% TradeEngineLib.buy_price("london", "wine"))


## §4.9 flip-campaign rules (decision 26): the ≤ 2,000g monthly allowance at a
## contestable port (reset at the month tick) and the rep/bounty diplomatic
## gate, with the ledger effect asserted alongside.
func _test_month_cap_and_gates() -> void:
	# madeira: own contestable sovereign — the allowance is 4 × 500g/month and
	# every chunk also feeds the ledger.
	_make_run("madeira", 100000)
	for click in range(4):
		_open_market()
		_check(TradeEngineLib.can_invest("madeira"),
			"chunk %d investable (allowance %d/2,000)" % [click + 1,
			AllegianceLib.month_invested_gold("madeira")])
		_check(AllegianceLib.invest_block_reason("madeira") == "",
			"chunk %d: no block reason" % (click + 1))
		_check(TradeEngineLib.invest("madeira"), "chunk %d invests" % (click + 1))
	_check(AllegianceLib.month_invested_gold("madeira") == 2000,
		"the monthly counter books 2,000g (got %d)"
		% AllegianceLib.month_invested_gold("madeira"))
	_check(AllegianceLib.ledger_of("madeira", "portugal") == 8000,
		"the ledger books the same chunks: 6,000 seed + 2,000 (got %d)"
		% AllegianceLib.ledger_of("madeira", "portugal"))
	_check(TradeEngineLib.invested("madeira") == 2000,
		"the discount block books the same 2,000g (got %d)"
		% TradeEngineLib.invested("madeira"))
	_check(not TradeEngineLib.can_invest("madeira"),
		"the 5th chunk of the month is refused")
	_check(AllegianceLib.invest_block_reason("madeira")
		== "market.invest_gate.exhausted",
		"the exhausted state names market.invest_gate.exhausted (got %s)"
		% AllegianceLib.invest_block_reason("madeira"))
	_check(GameState.gold == 100000 - 2000, "exactly the 4 chunks were paid")
	# Contestable ports invest past the 5,000g discount cap — the ledger is
	# the campaign's currency; only the discount readout saturates.
	AllegianceLib.month_tick()
	_check(AllegianceLib.month_invested_gold("madeira") == 0,
		"the month tick resets the allowance")
	for click in range(4):
		_open_market()
		_check(TradeEngineLib.invest("madeira"),
			"month 2 chunk %d invests (lifetime %dg)" % [click + 1,
			TradeEngineLib.invested("madeira")])
	_check(TradeEngineLib.invested("madeira") == 4000,
		"contestable investing continues past no lifetime cap (got %d)"
		% TradeEngineLib.invested("madeira"))
	_check(TradeEngineLib.investment_percent("madeira") == 8,
		"the discount readout is still chunks, capped at 10 (got %d)"
		% TradeEngineLib.investment_percent("madeira"))

	# Diplomatic gate at a foreign aligned port: rep ≥ 0 and no bounty.
	_make_run("lisbon", 100000)
	_check(AllegianceLib.invest_block_reason("london") == "",
		"rep 0 with england: london invests")
	_check(TradeEngineLib.invest("london"), "london accepts a chunk")
	CharacterLib.add_reputation("england", -1)
	_check(AllegianceLib.invest_block_reason("london")
		== "market.invest_gate.blocked",
		"rep −1 blocks with market.invest_gate.blocked (got %s)"
		% AllegianceLib.invest_block_reason("london"))
	_check(not TradeEngineLib.can_invest("london"), "and can_invest is false")
	_check(not TradeEngineLib.invest("london"), "and invest() refuses")
	CharacterLib.add_reputation("england", 1)
	GameState.bounties["england"] = {"amount": 5000, "day": 1}
	_check(AllegianceLib.invest_block_reason("london")
		== "market.invest_gate.blocked",
		"a standing bounty blocks even at rep 0 (got %s)"
		% AllegianceLib.invest_block_reason("london"))
	GameState.bounties = {}
	_check(AllegianceLib.invest_block_reason("london") == "",
		"clearing the bounty reopens london")
	# An unaligned contestable port has no gate at all — holland's opinion is
	# irrelevant while the port has no allegiance (no investment made there).
	CharacterLib.add_reputation("holland", -100)
	GameState.bounties["holland"] = {"amount": 5000, "day": 1}
	_check(AllegianceLib.effective_alignment("quanzhou") == "",
		"fixture: quanzhou stays unaligned")
	_check(AllegianceLib.invest_block_reason("quanzhou") == "",
		"an unaligned port: no diplomacy gate whatever holland thinks")
	_check(TradeEngineLib.invest("quanzhou"),
		"the unaligned port accepts the chunk (into the ledger)")
	_check(AllegianceLib.ledger_of("quanzhou", "portugal") == 500,
		"the unaligned chunk books the ledger (got %d)"
		% AllegianceLib.ledger_of("quanzhou", "portugal"))
	CharacterLib.add_reputation("holland", 0)
	GameState.bounties = {}


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
		_open_market()
		TradeEngineLib.invest("lisbon")
	_check(is_equal_approx(TradeEngineLib.clamped_factor("lisbon", "wine"), 0.63),
		"Lisbon wine at max investment: 0.7 × 0.9 = 0.63 (got %.4f)"
		% TradeEngineLib.clamped_factor("lisbon", "wine"))


func _test_quantity_limits() -> void:
	_make_run("lisbon", 1000)
	# buy_max = the largest quantity whose FULL tranche walk the purse pays
	# (tax included, §4.10) and fleet_free can hold (docs/30 §4.4). Lisbon is
	# portuguese: the aligned 5% rides on the running total. Four tranches
	# cost 920 + 46 tax = 966; the fifth (27g/unit) fits exactly 1 more unit
	# (27 + 2 = 29 ≤ 34) → 41.
	_check(TradeEngineLib.buy_max("lisbon", "wine") == 41,
		"1,000g walks 4 tranches (966g with 5%% tax) + 1 unit at 27g = 41 (got %d)"
		% TradeEngineLib.buy_max("lisbon", "wine"))
	_check(TradeEngineLib.buy_max("lisbon", "wine") <= FleetLib.fleet_free(),
		"buy_max never exceeds the pooled free capacity")
	_check(TradeEngineLib.sell_max("wine") == 0,
		"an empty hold has sell_max 0")

	FleetLib.add_goods("wine", 30)
	_check(TradeEngineLib.sell_max("wine") == 30,
		"sell_max == held 30 (got %d)" % TradeEngineLib.sell_max("wine"))
	_check(TradeEngineLib.buy_max("lisbon", "wine") == 41,
		"the purse still binds before capacity does (90 free > 41)")
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

	# Under a home charter the 5% vanishes: the pre-Phase-7 42-unit walk is
	# back (4 tranches 920g + 2 units at 27g ≤ 1,000g).
	_make_run("lisbon", 1000)
	AllegianceLib.set_permit("home", "portugal")
	_check(TradeEngineLib.tax_mille("lisbon") == 0, "the charter zeroes lisbon")
	_check(TradeEngineLib.buy_max("lisbon", "wine") == 42,
		"exempt: 1,000g walks the untaxed 4 tranches + 2 units = 42 (got %d)"
		% TradeEngineLib.buy_max("lisbon", "wine"))


func _test_buy_clamps() -> void:
	# Gold-limited buy: exactly affordable works, one more unit does not (the
	# 5% tax rides on the total). 220g buys the full first tranche; 219g buys 9.
	_make_run("lisbon", 220)
	_check(TradeEngineLib.buy_max("lisbon", "wine") == 10,
		"220g buys 10 wine (210 + 10 tax) (got %d)"
		% TradeEngineLib.buy_max("lisbon", "wine"))
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "buy 10 wine succeeds")
	_check(GameState.gold == 0, "gold exactly spent to 0 (got %d)" % GameState.gold)
	_check(FleetLib.held("wine") == 10, "10 wine aboard (got %d)"
		% FleetLib.held("wine"))

	_make_run("lisbon", 219)
	_check(TradeEngineLib.buy_max("lisbon", "wine") == 9,
		"219g buys 9 wine (the 10th would cost 220) (got %d)"
		% TradeEngineLib.buy_max("lisbon", "wine"))

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
	# Unlisted pairs never transact (docs/30 §4.4 listing rule).
	_check(not TradeEngineLib.is_listed("lisbon", "silver"),
		"silver is unlisted at lisbon")
	_check(not TradeEngineLib.buy("lisbon", "silver", 1),
		"an unlisted good cannot be bought")
	_check(not TradeEngineLib.sell("lisbon", "silver", 1),
		"an unlisted good cannot be sold")


## The §4.4 tranche walk with the §4.10 tariff composed after it: every gold
## pin below is `gross ± tax`, never a price change.
func _test_tranche_repricing() -> void:
	# --- buy walk at Lisbon (produced, rest 160) -------------------------
	_make_run("lisbon", 100000)
	var buy_rest := TradeEngineLib.buy_price("lisbon", "wine")
	_check(buy_rest == 21, "the rest price is 21 before anything moves")
	var gold_before := GameState.gold
	_check(TradeEngineLib.buy("lisbon", "wine", 100), "buy 100 wine")
	# Tranches at stock 160,150,…,70: 21+22+24+25+27+28+30+31+33+34 = 2,750;
	# the 5% tax adds 137 → 2,887 out of pocket.
	_check(GameState.gold == gold_before - 2887,
		"100 wine cost the exact tranche sum 2,750 + 137 tax (paid %d)"
		% (gold_before - GameState.gold))
	_check(EconomyLib.stock_of("lisbon", "wine") == 60,
		"the stock booked down 160 → 60 (got %d)"
		% EconomyLib.stock_of("lisbon", "wine"))
	_check(TradeEngineLib.buy_price("lisbon", "wine") == 36,
		"buying 100 wine moved the buy price 21 → 36 (got %d)"
		% TradeEngineLib.buy_price("lisbon", "wine"))
	_check(TradeEngineLib.sell_price("lisbon", "wine") == 28,
		"and the sell price 16 → 28 (got %d)"
		% TradeEngineLib.sell_price("lisbon", "wine"))

	# --- §5 displaced-stock example: sell 100 into London ----------------
	_dock("london")
	gold_before = GameState.gold
	_check(TradeEngineLib.sell("london", "wine", 100), "sell 100 at London")
	# Tranches at stock 40…130: 31+30+28+27+26+25+24+22+21+20 = 2,540 gross;
	# the 20% foreign tariff takes 508 → 2,032 net.
	_check(GameState.gold == gold_before + 2032,
		"the 100-sale nets 2,540 − 508 tax = 2,032 (got %d)"
		% (GameState.gold - gold_before))
	_check(EconomyLib.stock_of("london", "wine") == 140,
		"London's stock rose 40 → 140 (got %d)"
		% EconomyLib.stock_of("london", "wine"))
	_check(TradeEngineLib.sell_price("london", "wine") == 19,
		"the marginal sell price after the walk is 19 (§5, got %d)"
		% TradeEngineLib.sell_price("london", "wine"))
	_check(TradeEngineLib.buy_price("london", "wine") == 24,
		"and the buy price 24 (§5, got %d)"
		% TradeEngineLib.buy_price("london", "wine"))

	# --- §4.4 worked example: a 300-unit sale walks, never jumps ---------
	_make_run("london", 10, ["galleon"])
	FleetLib.add_goods("wine", 300)
	gold_before = GameState.gold
	_check(TradeEngineLib.sell("london", "wine", 300), "sell 300 at London")
	# Gross 5,170; the 20% tariff takes 1,034 → 4,136 net.
	_check(GameState.gold == gold_before + 4136,
		"the 300-sale nets 5,170 − 1,034 tax = 4,136, not 9,300 flat (got %d)"
		% (GameState.gold - gold_before))
	_check(EconomyLib.stock_of("london", "wine") == 200,
		"the stock parked at the 200 bound (got %d)"
		% EconomyLib.stock_of("london", "wine"))
	_check(TradeEngineLib.sell_price("london", "wine") == 12,
		"the parked marginal price is 12, reached continuously (got %d)"
		% TradeEngineLib.sell_price("london", "wine"))
	var walk := EconomyLib.plan_trade("london", "wine", -10)
	_check(int(walk[0]["factor_units"]) == 500,
		"the next tranche still transacts at the parked factor 500")

	# --- band edges over the stock range --------------------------------
	_make_run("lisbon", 10)
	EconomyLib.set_stock("lisbon", "wine", 0)
	_check(EconomyLib.factor_units("lisbon", "wine") == 1500,
		"a drained port (stock 0) sits at factor 1.5 inside the band")
	_check(TradeEngineLib.buy_price("lisbon", "wine") == 45,
		"stock 0 buy == 45 (got %d)" % TradeEngineLib.buy_price("lisbon", "wine"))
	_check(TradeEngineLib.sell_price("lisbon", "wine") == 36,
		"stock 0 sell == floor(45 × 0.8) = 36 (got %d)"
		% TradeEngineLib.sell_price("lisbon", "wine"))
	EconomyLib.set_stock("lisbon", "wine", 200)
	_check(EconomyLib.factor_units("lisbon", "wine") == 500,
		"a saturated port (stock 200) sits exactly at the 0.5 band floor")
	_check(TradeEngineLib.buy_price("lisbon", "wine") == 15,
		"stock 200 buy == 15 (got %d)" % TradeEngineLib.buy_price("lisbon", "wine"))
	_check(TradeEngineLib.sell_price("lisbon", "wine") == 12,
		"stock 200 sell == 12 (got %d)" % TradeEngineLib.sell_price("lisbon", "wine"))
	# The band still re-clamps factor × discount (docs/30 §4.2): 1.5 × 0.9.
	_make_run("lisbon", 10000)
	for click in range(10):
		_open_market()
		TradeEngineLib.invest("lisbon")
	EconomyLib.set_stock("lisbon", "wine", 0)
	_check(is_equal_approx(TradeEngineLib.clamped_factor("lisbon", "wine"), 1.35),
		"stock 0 at max investment: 1.5 × 0.9 = 1.35 inside the band (got %.3f)"
		% TradeEngineLib.clamped_factor("lisbon", "wine"))
	_check(TradeEngineLib.buy_price("lisbon", "wine") == 40,
		"floor(30 × 1.35) = 40 (got %d)" % TradeEngineLib.buy_price("lisbon", "wine"))


## docs/30 §4.4: "A stock-moving trade emits EventBus.market_changed(port_id)".
func _test_market_changed_on_trades() -> void:
	_make_run("lisbon", 10000)
	var events: Array = []
	var handler := func(port_id: String) -> void: events.append(port_id)
	EventBus.market_changed.connect(handler)
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "buy 10 wine")
	_check(events == ["lisbon"], "the buy fired market_changed(lisbon) (got %s)"
		% str(events))
	_dock("london")
	events.clear()
	_check(TradeEngineLib.sell("london", "wine", 10), "sell 10 wine")
	_check(events == ["london"], "the sell fired market_changed(london) (got %s)"
		% str(events))
	# A refused trade moves no stock and emits nothing.
	events.clear()
	var gold_before := GameState.gold
	_check(not TradeEngineLib.buy("london", "wine", 100000),
		"an unaffordable buy is refused")
	_check(events.is_empty() and GameState.gold == gold_before,
		"a refused trade emits market_changed nothing")
	# Supplies and investment move no stock, so they emit nothing either.
	_check(TradeEngineLib.buy_supplies("london", "water", 5), "buy 5 water")
	_check(TradeEngineLib.invest("london"), "invest a chunk")
	_check(events.is_empty(),
		"supplies and investment emit no market_changed")
	EventBus.market_changed.disconnect(handler)


## The §4.4 listing rule (correction 7): a port lists a good iff it produces
## or demands it — unlisted goods have no row and never transact.
func _test_listing_rule() -> void:
	_make_run("lisbon")
	_check(DataLoader.goods_list.size() == 40,
		"goods.json holds the locked 40 goods (got %d)"
		% DataLoader.goods_list.size())
	var rows := TradeEngineLib.goods_rows("lisbon")
	var listed: Array = []
	for good_id in DataLoader.get_port("lisbon").get("produces", []):
		listed.append(str(good_id))
	for good_id in DataLoader.get_port("lisbon").get("demands", []):
		listed.append(str(good_id))
	_check(rows.size() == listed.size(),
		"goods_rows(lisbon) == produces ∪ demands (%d rows, %d listed; got %d)"
		% [listed.size(), listed.size(), rows.size()])
	var row_ids: Array = []
	for row in rows:
		row_ids.append(str(row.get("id", "")))
	_check(row_ids.has("wine") and row_ids.has("salt"),
		"lisbon's produces carry rows (wine, salt)")
	_check(row_ids.has("gold") and row_ids.has("spices"),
		"lisbon's demands carry rows (gold, spices)")
	_check(not row_ids.has("silver") and not row_ids.has("tea"),
		"unlisted goods never render (silver, tea absent)")
	# Sorted by base_price ascending (ties by id), per docs/30 §4.4.
	var sorted := true
	for index in range(1, rows.size()):
		var previous := int(rows[index - 1].get("base_price", 0))
		var current := int(rows[index].get("base_price", 0))
		if current < previous:
			sorted = false
	_check(sorted, "rows are sorted by base_price ascending")

	# The filter is data-driven both ways: a synthetic good is invisible until
	# the port's produces/demands name it — zero code changes either way.
	var synthetic := {
		"id": "test_tea",
		"name": {"zh": "测试茶", "en": "Test Tea"},
		"category": "food",
		"base_price": 11,
		"unit_size": 1,
	}
	DataLoader.goods_list.append(synthetic)
	DataLoader.goods["test_tea"] = synthetic
	_check(TradeEngineLib.goods_rows("lisbon").size() == rows.size(),
		"an unlisted 41st good adds no row at lisbon")
	_check(not TradeEngineLib.is_listed("lisbon", "test_tea"),
		"and is not listed")
	var lisbon: Dictionary = DataLoader.get_port("lisbon")
	(lisbon["produces"] as Array).append("test_tea")
	var with_tea := TradeEngineLib.goods_rows("lisbon")
	_check(with_tea.size() == rows.size() + 1,
		"listing the 41st good adds exactly one row (got %d)" % with_tea.size())
	var tea_index := -1
	for index in with_tea.size():
		if str(with_tea[index].get("id", "")) == "test_tea":
			tea_index = index
			break
	_check(tea_index >= 0, "the 41st good has a row once listed")
	# Stock-explicit pricing: at the §5 produced rest 160 the factor is 0.7,
	# so the listed 41st good prices floor(11 × 0.7) = 7 — no code changes.
	EconomyLib.set_stock("lisbon", "test_tea", 160)
	_check(TradeEngineLib.buy_price("lisbon", "test_tea") == 7,
		"the listed 41st good prices from data: floor(11 × 0.7) = 7 (got %d)"
		% TradeEngineLib.buy_price("lisbon", "test_tea"))
	_check(TradeEngineLib.buy("lisbon", "test_tea", 2),
		"the listed 41st good is buyable with no code change")
	_check(FleetLib.held("test_tea") == 2, "2 test tea aboard")
	# Restore the shipped data (the list, dict and port tuple are the loader's).
	(lisbon["produces"] as Array).pop_back()
	DataLoader.goods_list.pop_back()
	DataLoader.goods.erase("test_tea")
	_check(DataLoader.goods_list.size() == 40, "goods.json data restored to 40")

	# 不收购 (docs/30 §4.2 market direction): a producing port never buys its
	# own produced goods — the engine refuses the sell outright.
	_check(not TradeEngineLib.port_buys_good("lisbon", "wine"),
		"lisbon does not buy its own wine")
	_check(TradeEngineLib.port_buys_good("lisbon", "wheat"),
		"lisbon buys the wheat it demands")
	var held_before := FleetLib.held("wine")
	var gold_before := GameState.gold
	FleetLib.add_goods("wine", 5)
	_check(not TradeEngineLib.sell("lisbon", "wine", 5),
		"selling wine into its producer is refused (不收购)")
	_check(FleetLib.held("wine") == held_before + 5
		and GameState.gold == gold_before,
		"the refused sell changed nothing")
	FleetLib.remove_goods("wine", 5)


## The §4.10 rate matrix through the engine wrapper: 500 in sphere,
## 2000 foreign or unallied, 0 under a covering permit.
func _test_tariff_matrix() -> void:
	_make_run("lisbon")
	_check(TradeEngineLib.tax_mille("lisbon") == 500,
		"own protected lisbon: 5%% (got %d)" % TradeEngineLib.tax_mille("lisbon"))
	_check(TradeEngineLib.tax_mille("london") == 2000,
		"foreign protected london: 20%% (got %d)"
		% TradeEngineLib.tax_mille("london"))
	_check(TradeEngineLib.tax_mille("valencia") == 2000,
		"foreign protected valencia: 20%%")
	_check(TradeEngineLib.tax_mille("madeira") == 500,
		"own aligned contestable madeira: 5%%")
	_check(TradeEngineLib.tax_mille("quanzhou") == 2000,
		"unallied neutral quanzhou: 20%% forever (got %d)"
		% TradeEngineLib.tax_mille("quanzhou"))
	_check(TradeEngineLib.tax_amount("lisbon", 210) == 10,
		"5%% of 210 = 10 (got %d)" % TradeEngineLib.tax_amount("lisbon", 210))
	_check(TradeEngineLib.tax_amount("london", 310) == 62,
		"20%% of 310 = 62 (got %d)" % TradeEngineLib.tax_amount("london", 310))
	_check(TradeEngineLib.tax_amount("lisbon", 0) == 0,
		"an empty total carries no tax")


## The tariff lands on real transactions: out-of-pocket buys, net sells, and
## the credit flowing to the alignment nation (decision 19).
func _test_tariff_on_trades() -> void:
	_make_run("lisbon", 1000)
	var portugal_before := AllegianceLib.treasury("portugal")
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "buy 10 wine at lisbon")
	_check(GameState.gold == 1000 - 220,
		"the buy charges 210 + 10 tax = 220 (got %d)" % GameState.gold)
	_check(AllegianceLib.treasury("portugal") == portugal_before + 10,
		"the 10g tax flows to portugal's treasury (got %d)"
		% (AllegianceLib.treasury("portugal") - portugal_before))
	# An unallied host collects nothing (no host to pay).
	_make_run("lisbon", 1000)
	_check(TradeEngineLib.buy("quanzhou", "wine", 10),
		"buy 10 wine at unallied quanzhou (demands wine, stock 40)")
	# 40 → 30: prices 39,43 → 39×10 + 43×0? 10 units = one tranche: 39 × 10
	# = 390 + 78 tax (20%) = 468.
	_check(GameState.gold == 1000 - 468,
		"the quanzhou buy charges 390 + 78 tax = 468 (got %d)" % GameState.gold)
	_check(AllegianceLib.treasury("portugal") == 5000,
		"the unallied 78g taxes collect into nothing (portugal untouched)")
	# A foreign sale: 20% comes off the proceeds into england's treasury.
	_make_run("london", 10000)
	var england_before := AllegianceLib.treasury("england")
	FleetLib.add_goods("wine", 10)
	_check(TradeEngineLib.sell("london", "wine", 10), "sell 10 wine at london")
	_check(GameState.gold == 10000 + 248,
		"the sale pays 310 − 62 tax = 248 net (got %d)" % GameState.gold)
	_check(AllegianceLib.treasury("england") == england_before + 62,
		"the 62g tax flows to england's treasury (got %d)"
		% (AllegianceLib.treasury("england") - england_before))


## Permit resolution through the palace sales (docs/30 §4.10): home 5,000g
## zeroes own+aligned ports; foreign 20,000g (knight, rep +20) zeroes that
## nation's ports; the sale price credits the selling nation's treasury.
func _test_permits_and_treasury_credit() -> void:
	_make_run("lisbon", 100000)
	# No permit yet: 5% at lisbon.
	_check(TradeEngineLib.tax_mille("lisbon") == 500, "no permit: 5% at lisbon")
	# Home charter at the player's own palace.
	var gold_before := GameState.gold
	var portugal_before := AllegianceLib.treasury("portugal")
	_check(AllegianceLib.has_permit_home() == false, "no home charter held")
	_check(PalaceEngineLib.buy_permit("lisbon"), "the home charter buys")
	_check(GameState.gold == gold_before - 5000,
		"the charter costs 5,000g (got %d)" % GameState.gold)
	_check(AllegianceLib.has_permit_home(), "the charter is held")
	_check(AllegianceLib.treasury("portugal") == portugal_before + 5000,
		"the 5,000g permit sale credits portugal's treasury (got %d)"
		% (AllegianceLib.treasury("portugal") - portugal_before))
	_check(TradeEngineLib.tax_mille("lisbon") == 0,
		"lisbon: 5% → 0%")
	_check(TradeEngineLib.tax_mille("madeira") == 0,
		"aligned contestable madeira: 5% → 0%")
	_check(TradeEngineLib.tax_mille("london") == 2000,
		"the charter never covers foreign london")
	_check(not PalaceEngineLib.buy_permit("lisbon"),
		"re-buying a held (non-void) charter is refused")
	# The exempt buy books no tax line.
	var mid_gold := GameState.gold
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "exempt buy 10 wine")
	_check(GameState.gold == mid_gold - 210,
		"the exempt buy charges exactly 210 (got %d)" % GameState.gold)
	# Foreign permit: gates then coverage.
	_check(AllegianceLib.has_permit_foreign("england") == false,
		"no england permit held")
	_check(not PalaceEngineLib.buy_permit("london"),
		"a knight-less player cannot buy the england permit")
	CharacterLib.add_reputation("england", 20)
	_check(not PalaceEngineLib.buy_permit("london"),
		"rep +20 alone is not enough without the title")
	GameState.titles = {"england": "knight"}
	var england_before := AllegianceLib.treasury("england")
	gold_before = GameState.gold
	_check(PalaceEngineLib.buy_permit("london"),
		"knight + rep +20: the england permit buys")
	_check(GameState.gold == gold_before - 20000,
		"the foreign permit costs 20,000g (got %d)" % GameState.gold)
	_check(AllegianceLib.treasury("england") == england_before + 20000,
		"the 20,000g sale credits england's treasury (got %d)"
		% (AllegianceLib.treasury("england") - england_before))
	_check(TradeEngineLib.tax_mille("london") == 0,
		"london: 20% → 0% under the england permit")
	_check(TradeEngineLib.tax_mille("valencia") == 2000,
		"the england permit does not cover spain's valencia")
	# Void while the covered nation's bounty stands.
	GameState.bounties["england"] = {"amount": 5000, "day": 1}
	_check(TradeEngineLib.tax_mille("london") == 2000,
		"the void permit falls back to 20%")
	_check(AllegianceLib.permit_void_reason("england")
		== "palace.permit.void_bounty",
		"the void state names palace.permit.void_bounty")
	_check(PalaceEngineLib.buy_permit("london"),
		"a void permit can be re-bought at full price")
	_check(GameState.gold == gold_before - 40000,
		"the re-buy charged the full 20,000g again (got %d)" % GameState.gold)
	GameState.bounties = {}


func _test_supplies_ignore_factors() -> void:
	# At a port that produces wine and demands spices, at max investment, the
	# supply prices are still the locked 2g / 1g — and supplies carry no tax.
	_make_run("lisbon", 10000)
	_check("wine" in DataLoader.get_port("lisbon")["produces"],
		"fixture port produces wine")
	_check("spices" in DataLoader.get_port("lisbon")["demands"],
		"fixture port demands spices")
	for click in range(10):
		_open_market()
		TradeEngineLib.invest("lisbon")
	_check(TradeEngineLib.supplies_price("provisions") == 2,
		"provisions are 2g at max investment (got %d)"
		% TradeEngineLib.supplies_price("provisions"))
	_check(TradeEngineLib.supplies_price("water") == 1,
		"water is 1g at max investment (got %d)"
		% TradeEngineLib.supplies_price("water"))
	_check(not ("provisions" in DataLoader.goods),
		"supplies are not trade goods (absent from goods.json)")
	_check(not ("water" in DataLoader.goods),
		"water is not a trade good")

	# Buying: 2g and 1g exactly — no tariff on either (§4.10 exemption).
	var gold_before := GameState.gold
	_check(TradeEngineLib.buy_supplies("lisbon", "provisions", 10),
		"buy 10 provisions")
	_check(GameState.gold == gold_before - 20,
		"10 provisions cost 20g, untaxed (paid %d)" % (gold_before - GameState.gold))
	_check(FleetLib.supplies("provisions") == 10, "10 provisions aboard")
	gold_before = GameState.gold
	_check(TradeEngineLib.buy_supplies("lisbon", "water", 10), "buy 10 water")
	_check(GameState.gold == gold_before - 10,
		"10 water costs 10g, untaxed (paid %d)" % (gold_before - GameState.gold))
	_check(FleetLib.used_capacity(GameState.fleet[0]) == 20,
		"supplies occupy cargo: 10 + 10 = 20 units (got %d)"
		% FleetLib.used_capacity(GameState.fleet[0]))

	# sell-back is not offered for supplies (docs/20 §4.10), so this is a buy
	# ceiling only: `min(floor(gold / price), fleet_free)`.
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


## docs/50 §4.3/§4.6: the XP and reputation rules are unchanged by the tariff —
## both book the **gross** walked proceeds; the tax composes after (§4.10).
func _test_sell_profit_xp_and_reputation() -> void:
	# Lisbon → London wine run: buy 10 at 21 (+10 tax), sell at 31 (−62 tax).
	_make_run("lisbon", 1000)
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "buy 10 wine at Lisbon")
	_check(GameState.gold == 1000 - 220, "the 10-buy costs 220 with tax (one tranche)")
	_dock("london")

	# The profitable walk out of rest only ever earns 450g more (prices fall
	# to the 21 basis within 8 tranches), so seed the accumulator to 550g —
	# the walked sales then cross 1,000g exactly.
	GameState.player["profit_by_nation"] = {"england": 550}
	GameState.player["profit_rep_awarded"] = {"england": 0}
	var xp_before := CharacterLib.current_xp()
	var rep_before := CharacterLib.reputation("england")
	var gold_before := GameState.gold
	_check(TradeEngineLib.sell("london", "wine", 10), "sell 10 wine at London")
	_check(GameState.gold == gold_before + 248,
		"sell earns 310 gross − 62 tax = 248 (got +%d)"
		% (GameState.gold - gold_before))

	# docs/50 §4.3: per-unit profit = 31 − floor(30 × 0.7) = 10; profit 100 →
	# +1 XP — booked on the GROSS proceeds, the tax never touches XP.
	_check(CharacterLib.current_xp() == xp_before + 1,
		"a 100g-profit sale awards 1 XP (got +%d)"
		% (CharacterLib.current_xp() - xp_before))
	# docs/50 §4.6: +1 reputation per 1,000g profit — 100g is below the
	# threshold, so it accumulates instead of granting.
	_check(CharacterLib.reputation("england") == rep_before,
		"100g of profit does not yet earn reputation (england %d)"
		% CharacterLib.reputation("england"))
	_check(TradeEngineLib.profit_by_nation("england") == 650,
		"the 550g seed + 100g booked to England (got %d)"
		% TradeEngineLib.profit_by_nation("england"))

	# The 1,000g threshold carries across transactions, walked tranche by
	# tranche. The tranche-formula oracle is SAMPLED at three points — the
	# first sale, one mid tranche, and the chunk that crosses the threshold
	# — while every tranche still sells through the engine so the
	# accumulator really carries (docs/30 §4.4 + §4.10).
	var stock := 50  # 40 at rest + the first sale's 10
	var profit_total := 650  # the 550g seed + the first sale's 100g
	var sale := 0
	for chunk in range(12):
		var sampled := chunk == 0 or chunk == 4
		FleetLib.add_goods("wine", 10)
		_open_market()
		gold_before = GameState.gold
		xp_before = CharacterLib.current_xp()
		# Oracle: one tranche of 10 at the current stock's sell price, taxed 20%.
		var factor := 1500 - 5 * stock
		var price := maxi(1, (30 * factor * 8) / 10000)
		var gross := 10 * price
		@warning_ignore("integer_division")
		var net := gross - gross * 2000 / 10000
		var profit := maxi(0, gross - 10 * 21)
		var sold: bool = TradeEngineLib.sell("london", "wine", 10)
		if sampled or profit_total + profit >= 1000:
			_check(sold, "oracle sale %d: sell 10 more wine at London" % chunk)
			_check(GameState.gold == gold_before + net,
				"oracle sale %d (stock %d): %d gross − tax = %d net (got +%d)"
				% [chunk, stock, gross, net, GameState.gold - gold_before])
		if sampled:
			_check(CharacterLib.current_xp() == xp_before + profit / 100,
				"oracle sale %d awards floor(%d / 100) XP"
				% [chunk, profit])
		profit_total += profit
		sale += 1
		stock += 10
		if profit_total >= 1000:
			break
	_check(profit_total >= 1000,
		"the threshold was crossed after %d walked sales (%dg)"
		% [sale, profit_total])
	_check(CharacterLib.reputation("england") == 1,
		"crossing 1,000g cumulative profit grants exactly +1 reputation (got %d)"
		% CharacterLib.reputation("england"))
	_check(TradeEngineLib.profit_by_nation("england") == profit_total,
		"the accumulator books the exact walked total %d (got %d)"
		% [profit_total, TradeEngineLib.profit_by_nation("england")])
	# Reputation went to England, not any other nation.
	_check(CharacterLib.reputation("portugal") == 0,
		"selling in London leaves Portugal's reputation at 0")

	# 不收购 + loss-making sales: a producer refuses its own good outright, and
	# a sale below the basis gives 0 XP and 0 reputation.
	_make_run("lisbon", 10000)
	FleetLib.add_goods("wine", 10)
	xp_before = CharacterLib.current_xp()
	_check(not TradeEngineLib.sell("lisbon", "wine", 10),
		"lisbon refuses its own wine outright (不收购)")
	_make_run("london", 10000)
	EconomyLib.set_stock("london", "wine", 200)  # parked: sell price 12
	FleetLib.add_goods("wine", 10)
	xp_before = CharacterLib.current_xp()
	rep_before = CharacterLib.reputation("england")
	GameState.gold = 0
	# London sell is 12/unit gross against a 21 cost basis → a loss every unit.
	_check(TradeEngineLib.sell("london", "wine", 10), "sell wine at parked london")
	@warning_ignore("integer_division")
	var loss_net := 120 - 120 * 2000 / 10000
	_check(GameState.gold == loss_net,
		"the loss sale pays 120 gross − 24 tax = 96 (got %d)" % GameState.gold)
	_check(CharacterLib.current_xp() == xp_before,
		"a loss-making sale awards 0 XP (got +%d)"
		% (CharacterLib.current_xp() - xp_before))
	_check(CharacterLib.reputation("england") == rep_before,
		"a loss-making sale awards no reputation")
	_check(TradeEngineLib.profit_by_nation("england") == 0,
		"a loss books no cumulative profit (got %d)"
		% TradeEngineLib.profit_by_nation("england"))
	# A walked sale that dips under the basis part-way books only the total's
	# profit (docs/30 §4.4: the summed total, not per-tranche profit).
	_make_run("london", 10000)
	FleetLib.add_goods("wine", 20)
	# 40→60: 31×10 + 30×10 = 610 gross; basis 420 → profit 190 → 1 XP.
	xp_before = CharacterLib.current_xp()
	_check(TradeEngineLib.sell("london", "wine", 20), "a two-tranche sale")
	_check(GameState.gold == 10000 + 488, "the walked total nets 610 − 122 = 488")
	_check(CharacterLib.current_xp() == xp_before + 1,
		"the two-tranche profit (190g) books exactly 1 XP")

	# Reputation is per nation and clamped: the cap holds after a profit.
	# The accumulator is seeded to 950g so the walked sale (40 units →
	# 1,160g gross, +320g profit) crosses 1,000g and awards — into the cap.
	_make_run("london", 10000)
	FleetLib.add_goods("wine", 40)
	CharacterLib.add_reputation("england", 100)
	GameState.player["profit_by_nation"] = {"england": 950}
	GameState.player["profit_rep_awarded"] = {"england": 0}
	TradeEngineLib.sell("london", "wine", 40)
	_check(TradeEngineLib.profit_by_nation("england") == 1270,
		"the crossed accumulator books 950 + 320 (got %d)"
		% TradeEngineLib.profit_by_nation("england"))
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
	_make_run("lisbon", 10000, ["galleon"])
	_check(TradeEngineLib.buy("lisbon", "wine", 150), "buy 150 wine")
	_dock("london")
	GameState.gold = 0
	# The walked proceeds of 150 units from rest 40 (docs/30 §4.4 walk):
	# 15 tranches × 10 units summing 336 per 10 → 3,360 gross; the 20%
	# tariff takes 672.
	_check(TradeEngineLib.sell("london", "wine", 150), "sell 150 wine")
	_check(GameState.gold == 2688,
		"the walked proceeds net 3,360 − 672 tax = 2,688 (%d)"
		% GameState.gold)
	_check(TradeEngineLib.profit_by_nation("england") == 210,
		"the walked profit books 3,360 − 150 × 21 = 210, gross (got %d)"
		% TradeEngineLib.profit_by_nation("england"))
	_check(GameState.player.has("profit_by_nation")
		and GameState.player.has("profit_rep_awarded"),
		"both accumulator keys live in the player block")

	# JSON round trip exactly as the save system serialises the block.
	var encoded := JSON.stringify(GameState.player)
	var decoded = JSON.parse_string(encoded)
	GameState.player = decoded
	_check(CharacterLib.profit_by_nation("england") == 210,
		"the total survives a JSON round trip (got %d)"
		% CharacterLib.profit_by_nation("england"))
	_check(CharacterLib.reputation("england") == 0, "no reputation paid yet")

	# Seed the accumulator to 1,900g/1 awarded, round-trip again, then one
	# more 100g profit crosses 2,000g → exactly +2 total, no double-award.
	GameState.player["profit_by_nation"]["england"] = 1900
	GameState.player["profit_rep_awarded"]["england"] = 1
	CharacterLib.add_reputation("england", 1)
	encoded = JSON.stringify(GameState.player)
	GameState.player = JSON.parse_string(encoded)
	FleetLib.add_goods("wine", 10)
	# London is drained to stock 190 by the 150-sale; restock it so the next
	# 10 transact at the §5 rest price 31 again (a pure state seed).
	EconomyLib.set_stock("london", "wine", 40)
	var topup_before := GameState.gold
	_check(TradeEngineLib.sell("london", "wine", 10), "sell 10 more (100g profit)")
	_check(GameState.gold == topup_before + 248,
		"the top-up sale nets 310 − 62 = 248 (got +%d)"
		% (GameState.gold - topup_before))
	_check(CharacterLib.profit_by_nation("england") == 2000,
		"total is 2,000g after the reload (got %d)"
		% CharacterLib.profit_by_nation("england"))
	_check(CharacterLib.reputation("england") == 2,
		"2,000g → exactly +2 total reputation, no double-award (got %d)"
		% CharacterLib.reputation("england"))
	# A sub-1,000g remainder never rounds up.
	FleetLib.add_goods("wine", 5)
	TradeEngineLib.sell("london", "wine", 5)
	_check(CharacterLib.reputation("england") == 2,
		"a remainder grants nothing extra (got %d)"
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


# --- Phase 8 (W3-D): the player skill factors (docs/30 §4.2, §4.10) ---------

## §4.10 negotiation tariff discount: `min(5, floor(effective_negotiation/10))`
## percentage points off the §4.10 rate, both directions, floored at 0;
## **player-only** — the NPC-parity allegiance rule never moves. The pinned
## levels: negotiation 0 → full 5%/20%, 20 → 3%/18%, 40 → 1%/16% (floor(40/10)
## = 4 points), 50 and 100 → the −5 cap → 0%/15%.
func _test_tariff_discount() -> void:
	var cases := [
		[0, 0, 500, 2000], [20, 2, 300, 1800], [40, 4, 100, 1600],
		[50, 5, 0, 1500], [100, 5, 0, 1500],
	]
	for case in cases:
		var negotiation := int(case[0])
		_make_run("lisbon")
		_set_skills(0, negotiation)
		_check(TradeEngineLib.tariff_discount_points() == int(case[1]),
			"negotiation %d → %d discount points (got %d)"
			% [negotiation, case[1], TradeEngineLib.tariff_discount_points()])
		_check(TradeEngineLib.tax_mille("lisbon") == int(case[2]),
			"negotiation %d: aligned lisbon %d‰ = 5%% − %d pts (got %d‰)"
			% [negotiation, case[2], case[1], TradeEngineLib.tax_mille("lisbon")])
		_check(TradeEngineLib.tax_mille("london") == int(case[3]),
			"negotiation %d: foreign london %d‰ = 20%% − %d pts (got %d‰)"
			% [negotiation, case[3], case[1], TradeEngineLib.tax_mille("london")])
		# NPC parity: the allegiance rule answers the full §4.10 rate whatever
		# the player's negotiation (docs/30 §4.10 "NPC trades pay full rate").
		_check(AllegianceLib.tariff_mille("lisbon", "portugal") == 500,
			"negotiation %d: the NPC aligned rate stays 5%%" % negotiation)
		_check(AllegianceLib.tariff_mille("london", "england") == 500,
			"negotiation %d: the NPC england trader stays 5%%" % negotiation)
		_check(AllegianceLib.tariff_mille("london", "portugal") == 2000,
			"negotiation %d: the NPC foreign rate stays 20%%" % negotiation)
	_clear_skills()

	# The discount lands on real transactions, both directions (negotiation
	# 20 → 2 points: aligned 3%, foreign 18%).
	_make_run("lisbon", 1000)
	_set_skills(0, 20)
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "buy 10 wine at lisbon")
	# 210 gross + 210 × 300/10000 = 6 tax → 216 out of pocket.
	_check(GameState.gold == 1000 - 216,
		"the discounted buy charges 210 + 6 tax = 216 (got %d)" % GameState.gold)
	_dock("london")
	FleetLib.add_goods("wine", 10)
	var gold_before := GameState.gold
	_check(TradeEngineLib.sell("london", "wine", 10), "sell 10 wine at london")
	# 310 gross − 310 × 1800/10000 = 55 tax → 255 net.
	_check(GameState.gold == gold_before + 255,
		"the discounted sale nets 310 − 55 tax = 255 (got +%d)"
		% (GameState.gold - gold_before))
	_clear_skills()

	# The floor is 0: the aligned 5% at the −5 cap taxes nothing, and the
	# zero rate buys at exactly the gross walked total.
	_make_run("lisbon", 1000)
	_set_skills(0, 100)
	_check(TradeEngineLib.tax_mille("lisbon") == 0,
		"negotiation 100: the aligned 5%% floors at 0%% (got %d‰)"
		% TradeEngineLib.tax_mille("lisbon"))
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "the zero-rate buy succeeds")
	_check(GameState.gold == 790,
		"the zero-rate buy charges exactly the gross 210 (got %d)" % GameState.gold)
	_clear_skills()


## §4.10 permit price gates: home 5,000g → 4,750g at negotiation ≥ 40
## (`permit.home_discount`), foreign 20,000g → 18,000g at ≥ 70
## (`permit.foreign_discount`); full price below the gate, the paid price
## credits the selling nation. `PalaceEngine.permit_offer`/`buy_permit`
## answer the same gated price.
func _test_permit_prices() -> void:
	# Below the home gate (39): full price everywhere.
	_make_run("lisbon", 100000)
	_set_skills(0, 39)
	_check(AllegianceLib.permit_price("home") == 5000,
		"negotiation 39: the home charter is full price (got %d)"
		% AllegianceLib.permit_price("home"))
	_check(PalaceEngineLib.permit_offer("lisbon")["price"] == 5000,
		"the palace offer answers the full 5,000g")
	var gold_before := GameState.gold
	var portugal_before := AllegianceLib.treasury("portugal")
	_check(PalaceEngineLib.buy_permit("lisbon"), "the full-price charter buys")
	_check(GameState.gold == gold_before - 5000, "5,000g charged")
	_check(AllegianceLib.treasury("portugal") == portugal_before + 5000,
		"the full 5,000g credits portugal's treasury")

	# At the gate (40): 4,750g.
	_make_run("lisbon", 100000)
	_set_skills(0, 40)
	_check(AllegianceLib.permit_price("home") == 4750,
		"negotiation 40: the home charter sells at 4,750g (got %d)"
		% AllegianceLib.permit_price("home"))
	_check(PalaceEngineLib.permit_offer("lisbon")["price"] == 4750,
		"the palace offer answers the gated 4,750g")
	gold_before = GameState.gold
	portugal_before = AllegianceLib.treasury("portugal")
	_check(PalaceEngineLib.buy_permit("lisbon"), "the gated charter buys")
	_check(GameState.gold == gold_before - 4750,
		"exactly 4,750g charged (paid %d)" % (gold_before - GameState.gold))
	_check(AllegianceLib.treasury("portugal") == portugal_before + 4750,
		"the paid 4,750g credits portugal's treasury (got %d)"
		% (AllegianceLib.treasury("portugal") - portugal_before))
	_clear_skills()

	# The foreign gates (69/70), with the title ≥ knight + rep ≥ +20 fixture.
	_make_run("london", 100000)
	CharacterLib.add_reputation("england", 20)
	GameState.titles = {"england": "knight"}
	_set_skills(0, 69)
	_check(AllegianceLib.permit_price("foreign") == 20000,
		"negotiation 69: the foreign permit is full price (got %d)"
		% AllegianceLib.permit_price("foreign"))
	_set_skills(0, 70)
	_check(AllegianceLib.permit_price("foreign") == 18000,
		"negotiation 70: the foreign permit sells at 18,000g (got %d)"
		% AllegianceLib.permit_price("foreign"))
	var england_before := AllegianceLib.treasury("england")
	gold_before = GameState.gold
	_check(PalaceEngineLib.buy_permit("london"), "the gated foreign permit buys")
	_check(GameState.gold == gold_before - 18000,
		"exactly 18,000g charged (paid %d)" % (gold_before - GameState.gold))
	_check(AllegianceLib.treasury("england") == england_before + 18000,
		"the paid 18,000g credits england's treasury (got %d)"
		% (AllegianceLib.treasury("england") - england_before))
	_clear_skills()


## §4.2 price memory: one entry per (port, good) per completed buy holding the
## marginal (first-tranche) price + day; capacity `floor(appraisal/10)` with
## least-recently-recorded-first eviction; a re-buy overwrites (and moves the
## entry to newest — "last seen"); session-transient, never saved.
func _test_price_memory() -> void:
	TradeEngineLib.reset_price_memory()

	# Capacity 0 (appraisal < 10): completed buys record nothing.
	_make_run("lisbon", 10000)
	_set_skills(0, 0)
	_check(TradeEngineLib.memory_capacity() == 0, "appraisal 0 → capacity 0")
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "buy 10 wine (no capacity)")
	_check(TradeEngineLib.price_memory().is_empty(),
		"capacity 0 records nothing")
	_clear_skills()

	# Capacity 3 (appraisal 30): the marginal buy price records per pair.
	_make_run("lisbon", 100000)
	TradeEngineLib.reset_price_memory()
	_set_skills(30, 0)
	_check(TradeEngineLib.memory_capacity() == 3, "appraisal 30 → capacity 3")
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "buy 10 wine at lisbon")
	_check(TradeEngineLib.price_memory_entry("lisbon", "wine")
		== {"price": 21, "day": 1},
		"the entry is the marginal buy 21 at day 1 (got %s)"
		% str(TradeEngineLib.price_memory_entry("lisbon", "wine")))
	# Fill to capacity, then re-buy the oldest pair at its moved stock: the
	# overwrite updates the marginal (22 at stock 150), stays one entry, and
	# moves the pair to newest — "last seen".
	_check(TradeEngineLib.buy("lisbon", "salt", 10), "buy salt (2nd entry)")
	_dock("london")
	_check(TradeEngineLib.buy("london", "wine", 10), "buy wine at london (3rd)")
	_check(TradeEngineLib.price_memory().size() == 3,
		"three entries at capacity 3")
	_dock("lisbon")
	_open_market()
	_check(TradeEngineLib.buy("lisbon", "wine", 10), "re-buy wine (overwrite)")
	_check(TradeEngineLib.price_memory_entry("lisbon", "wine")["price"] == 22,
		"the re-buy overwrites with the new marginal 22 (got %d)"
		% int(TradeEngineLib.price_memory_entry("lisbon", "wine")["price"]))
	_check(TradeEngineLib.price_memory().size() == 3,
		"a re-buy keeps exactly one entry per (port, good)")
	# The 4th pair evicts the LEAST-RECENTLY-RECORDED entry — lisbon|salt,
	# because the wine re-buy moved lisbon|wine to newest.
	_check(TradeEngineLib.buy("lisbon", "wheat", 10), "buy wheat (4th entry)")
	var memory := TradeEngineLib.price_memory()
	_check(memory.size() == 3, "the eviction kept exactly 3 entries")
	_check(not memory.has("lisbon|salt"),
		"the least-recently-recorded entry (lisbon salt) evicted first")
	_check(memory.has("lisbon|wine") and memory.has("london|wine")
		and memory.has("lisbon|wheat"),
		"the overwritten lisbon wine survives the eviction (last-seen order)")
	_clear_skills()

	# Capacity 10 (appraisal 100): eleven distinct pairs fill and evict the
	# first pair, not the eleventh.
	_make_run("lisbon", 1000000)
	TradeEngineLib.reset_price_memory()
	_set_skills(100, 0)
	_check(TradeEngineLib.memory_capacity() == 10, "appraisal 100 → capacity 10")
	var bought := 0
	var first_pair := ""
	for port_id in ["lisbon", "london"]:
		for row in TradeEngineLib.goods_rows(port_id):
			var good_id := str(row.get("id", ""))
			_dock(port_id)
			_open_market()
			_check(TradeEngineLib.buy(port_id, good_id, 1),
				"fill buy %d: %s at %s" % [bought + 1, good_id, port_id])
			if first_pair.is_empty():
				first_pair = "%s|%s" % [port_id, good_id]
			bought += 1
			if bought >= 11:
				break
		if bought >= 11:
			break
	_check(bought == 11, "eleven distinct pairs bought (got %d)" % bought)
	var memory11 := TradeEngineLib.price_memory()
	_check(memory11.size() == 10,
		"capacity 10 keeps exactly 10 entries (got %d)" % memory11.size())
	_check(not memory11.has(first_pair),
		"the 11th buy evicted the oldest entry (%s)" % first_pair)
	_clear_skills()

	# Session-transient: the reset helper models a new session, and nothing
	# ever lands in the save-relevant player block.
	TradeEngineLib.reset_price_memory()
	_check(TradeEngineLib.price_memory().is_empty(),
		"the reset helper empties the memory (a new session)")
	_make_run("lisbon", 10000)
	_set_skills(30, 0)
	_check(TradeEngineLib.buy("lisbon", "wine", 1), "one more completed buy")
	_check(TradeEngineLib.price_memory().size() == 1,
		"the fresh session records again")
	_check(not GameState.player.has("price_memory")
		and not GameState.player.has("price_memory_order"),
		"the memory never writes the GameState player block")
	_clear_skills()


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
