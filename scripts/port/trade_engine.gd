class_name TradeEngine
extends RefCounted
## Trade maths for the market screen — prices, investment, quantity limits and
## the gold/cargo side effects of a trade.
##
## Docs: 30-PORTS-AND-TRADE.md §4.2 (price formulas), §4.3 (investment),
## §4.4 (buy/sell quantity maths), §5 (worked examples); 40-SHIPS-AND-FLEET.md
## §4.2 (capacity); 50-CHARACTER-AND-PROGRESSION.md §4.3 (profit XP), §4.6
## (reputation); 20-WORLD-AND-SAILING.md §4.10 (provisions/water).
##
## Pure static functions, no node references (docs/90-ARCHITECTURE.md §4): they
## read `DataLoader`/`GameState` through the autoloads and mutate the state
## blocks the engines own (`gold`, `port_investments`, `fleet`, `player`), so
## every formula is unit-testable from headless GDScript.
##
## **Exact arithmetic.** The §4.2 formulas are rational: the factor is an
## integer per-thousand function of the port-good's stock (`economy.gd`:
## `clamp(1500 − 5 × stock, 500, 2000)` — 700/1300/1000 exactly at resting
## stock) and the investment discount is `1 − k/100`. Everything is
## therefore computed on a per-thousand fixed point (`combined_units`), which
## makes `floor(base × factor × discount)` exact — no float noise can turn
## `floor(30 × 0.7) = 21` into 20. Each price is floored exactly once, on the
## full product, as the §4.2 formula line specifies.
##
## **Tranche repricing (Phase 5, docs/30 §4.4).** Every trade moves the
## port-good's stock and reprices per 10-unit tranche: `buy`/`sell` walk the
## stock ladder via `Economy.apply_trade` and sum the per-tranche prices into
## one exact integer total (each tranche priced at the stock *before* it
## applies, the last tranche possibly smaller). A stock-moving trade emits
## `EventBus.market_changed(port_id)` (docs/30 §4.4).

const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
const FameLib := preload("res://scripts/player/fame.gd")
## Supply prices are owned by the sailing sim (docs/20 §4.10, §5): reuse the
## constants instead of re-declaring the locked 2g / 1g values.
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")
## Stock state, daily drift and the per-thousand factor — the docs/30 §4.2
## ownership split puts the factor in `economy.gd`, the price plumbing here.
const EconomyLib := preload("res://scripts/port/economy.gd")
## Port allegiance, the §4.10 tariff/permits and the §4.9 investment ledger
## (Phase 7, task L). Same wave, same owner — a direct load, not a guard read.
const AllegianceLib := preload("res://scripts/port/allegiance.gd")

# --- §4.2 price factors ----------------------------------------------------

## Locked 0.8 sell-side margin: arbitrage inside one port is always a loss.
## Written as an exact fraction for the integer maths in [method price_from_units].
const SELL_MARGIN_NUM := 8
const SELL_MARGIN_DEN := 10

## Price band `[0.5×, 2×]` applied to `factor × investment_discount` **before**
## the price is computed (docs/30 §4.2 last bullet).
const BAND_MIN := 0.5
const BAND_MAX := 2.0
## The same bounds in per-thousand units, for the integer paths.
const BAND_MIN_UNITS := 500
const BAND_MAX_UNITS := 2000

## Fixed-point scale: factors and discounts are stored per thousand.
const UNITS := 1000
## Every price is at least 1g (docs/30 §4.2 `max(1, …)`).
const MIN_PRICE := 1

# --- §4.3 investment -------------------------------------------------------

## One click invests this many gold (locked chunk).
const INVEST_CHUNK := 500
## The permanent cap: 10 chunks = 5,000g = −10%.
const INVEST_CAP_CHUNKS := 10
const INVEST_CAP_GOLD := INVEST_CHUNK * INVEST_CAP_CHUNKS
const DISCOUNT_CAP := 0.10
## 1% expressed in per-thousand units (the fixed-point scale used below).
const DISCOUNT_PER_MILLE := 10

# --- §4.3 profit XP / §4.6 reputation --------------------------------------

## docs/50 §4.3: per-unit profit uses `floor(base_price × 0.7)` as the cost
## basis. Mirrors `Character.add_profit_xp()` exactly (same expression) so the
## XP and the reputation award always agree.
const PROFIT_BASIS_FACTOR := 0.7

## The two supply kinds (docs/20 §4.10); they are not trade goods and never
## appear in `goods.json`.
const SUPPLY_KINDS := ["provisions", "water"]


# --- Prices (docs/30 §4.2) -------------------------------------------------

## The current factor as a float (`factor_units / 1000`): 0.7 / 1.3 / 1.0 at
## resting stock, moving with the port-good's stock (docs/30 §4.2).
static func factor(port_id: String, good_id: String) -> float:
	return float(_factor_units(port_id, good_id)) / float(UNITS)


## `1 − min(0.10, invested / 500 × 0.01)`: the permanent per-port discount.
static func investment_discount(port_id: String) -> float:
	return float(_discount_units(port_id)) / float(UNITS)


## `factor × investment_discount`, clamped to the locked `[0.5, 2.0]` band
## before it is used (docs/30 §4.2).
static func clamped_factor(port_id: String, good_id: String) -> float:
	return float(_combined_units(port_id, good_id)) / float(UNITS)


## Buy price, `max(1, floor(base × factor × discount))`.
static func buy_price(port_id: String, good_id: String) -> int:
	return price_from_units(
		_base_price(good_id), _combined_units(port_id, good_id), false
	)


## Sell price, `max(1, floor(base × factor × 0.8 × discount × title_bonus))`
## (docs/30 §4.2; the Phase-3 multiplier is `70-*` §4.9.2).
static func sell_price(port_id: String, good_id: String) -> int:
	return price_from_units(
		_base_price(good_id), _combined_units(port_id, good_id), true,
		title_units(port_id)
	)


## The Phase-3 `title_bonus` of a port's **own** nation, in per-thousand units:
## `1100` at baron and above, `1050` at knight, `1000` otherwise
## (`70-*` §4.9.2). A separate multiplier after the band clamp, sell-side only.
static func title_units(port_id: String) -> int:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return UNITS
	return int(round(FameLib.title_bonus(str(port.get("nation_id", "")))
		* float(UNITS)))


## The band clamp on an arbitrary `factor × discount` product, in per-thousand
## units. Exposed so the `[0.5, 2.0]` rule is unit-testable in isolation: the
## shipped data never produces a factor below 0.7, so the lower clamp itself is
## only reachable through a synthetic factor (e.g. 0.4 → 0.5).
static func band_units(factor_value: float, discount_value: float) -> int:
	var combined := clampf(factor_value * discount_value, BAND_MIN, BAND_MAX)
	return int(round(combined * float(UNITS)))


## One price from a base and an already-clamped `combined` value in per-thousand
## units (buy when `sell_side` is false). Floors the full product exactly once.
## `title` is the Phase-3 sell-side `title_bonus` in per-thousand units and is
## ignored on the buy side (`30-*` §4.2).
static func price_from_units(base_price: int, combined_units: int,
		sell_side: bool, title: int = UNITS) -> int:
	var base := maxi(base_price, 0)
	var units := clampi(combined_units, BAND_MIN_UNITS, BAND_MAX_UNITS)
	var numerator := base * units
	var denominator := UNITS
	if sell_side:
		numerator *= SELL_MARGIN_NUM
		denominator *= SELL_MARGIN_DEN
		numerator *= maxi(title, 0)
		denominator *= UNITS
	@warning_ignore("integer_division")
	var price := numerator / denominator
	return maxi(MIN_PRICE, price)


# --- Quantity limits (docs/30 §4.4) ----------------------------------------

## The UI's quantity ceiling and the hard limit [method buy] enforces:
## the largest quantity whose **full tranche walk** the purse can pay and
## `fleet_free` can hold (docs/30 §4.4). Since per-tranche buy prices only
## rise as stock drains, the walk accumulates full 10-unit tranches while
## affordable and finishes with the affordable remainder of the next
## (partial) tranche.
static func buy_max(port_id: String, good_id: String) -> int:
	var capacity := FleetLib.fleet_free()
	if capacity <= 0:
		return 0
	var walk := EconomyLib.plan_trade(port_id, good_id, capacity)
	var base := _base_price(good_id)
	var discount := _discount_units(port_id)
	var purse := GameState.gold
	# The §4.10 tariff rides on the running total (after all price math), so
	# the affordability walk compares against `spent + tax`, not `spent`.
	var mille := tax_mille(port_id)
	var bought := 0
	var spent := 0
	var paid := 0
	for tranche in walk:
		var price := _tranche_price(base, discount, tranche, false, UNITS)
		spent += price * int(tranche["units"])
		var taxed := _taxed_total(spent, mille)
		if purse >= taxed:
			bought += int(tranche["units"])
			paid = taxed
		else:
			# Flat-rate remainder against the purse left after the accepted
			# tranches: n units fit iff n × price × (scale + mille)
			# ≤ remaining × scale (the tax is linear in the total).
			@warning_ignore("integer_division")
			bought += maxi(0, (purse - paid) * AllegianceLib.TARIFF_SCALE
				/ (price * (AllegianceLib.TARIFF_SCALE + mille)))
			break
	return maxi(0, bought)


## Held quantity pooled across the fleet: partial sells allowed.
static func sell_max(good_id: String) -> int:
	return FleetLib.held(good_id)


## Capacity row of the market header: used / total across the fleet.
static func hold_used() -> int:
	var used := 0
	for ship in GameState.fleet:
		used += FleetLib.used_capacity(ship)
	return used


static func hold_capacity() -> int:
	return FleetLib.fleet_capacity()


# --- Investment (docs/30 §4.3) --------------------------------------------

## Gold permanently invested at the port (0 when never invested).
static func invested(port_id: String) -> int:
	if port_id.is_empty():
		return 0
	return int(GameState.port_investments.get(port_id, 0))


## True when another 500g chunk is allowed: the purse can pay, the §4.9 gates
## pass ([method Allegiance.invest_block_reason] — monthly allowance at a
## contestable port, rep/bounty diplomacy everywhere an alignment exists), and
## at a protected port the 5,000g discount-saturation cap is not yet reached
## (contestable ports keep investing past it — the ledger is the flip
## campaign's currency, docs/30 §4.9).
static func can_invest(port_id: String) -> bool:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port_id.is_empty() or port.is_empty():
		return false
	if not AllegianceLib.invest_block_reason(port_id).is_empty():
		return false
	if bool(port.get("protected", false)) \
			and invested(port_id) >= INVEST_CAP_GOLD:
		return false
	return GameState.gold >= INVEST_CHUNK


## Invests one 500g chunk. At a **contestable** port the chunk also feeds the
## player-nation's ledger there (+500g, docs/30 §4.3) and books against the
## ≤ 2,000g monthly allowance (docs/30 §4.9); at a **protected** port the
## discount is the whole effect (no ledger, no allowance — the 5,000g
## discount-saturation cap still ends investment, as always). Returns false
## (state untouched) when blocked, capped or unaffordable.
static func invest(port_id: String) -> bool:
	if not can_invest(port_id):
		return false
	GameState.port_investments[port_id] = invested(port_id) + INVEST_CHUNK
	GameState.add_gold(-INVEST_CHUNK)
	if not AllegianceLib.is_protected(port_id):
		AllegianceLib.player_invest_chunk(port_id)
	return true


## The discount in whole percent (`3` for 1,500g), for the market readout. The
## readout composes the `−` sign (docs/10 §3.3: no signs baked into strings).
## 1% per 500g chunk, capped at 10% (docs/30 §4.3), so percent == chunks.
static func investment_percent(port_id: String) -> int:
	return _invested_chunks(port_id)


## Whole 500g chunks at the port, capped at the 10-chunk / 5,000g maximum.
static func _invested_chunks(port_id: String) -> int:
	@warning_ignore("integer_division")
	var chunks := invested(port_id) / INVEST_CHUNK
	return mini(INVEST_CAP_CHUNKS, chunks)


# --- Transactions ----------------------------------------------------------

## Buys `qty` of a good at the port, walking the §4.4 tranche ladder.
##
## Validation is all-or-nothing: an invalid quantity, a quantity above
## [method buy_max] (the tranche-walked purse ceiling **and** pooled fleet
## free capacity), or a failed stock insertion changes nothing at all
## (docs/30 §4.4 "Transaction errors … change nothing"). On success: the
## exact per-tranche sum is charged, goods are stored flagship-first
## (docs/40 §4.2), the port-good's stock is booked down, and
## `gold_changed` + `market_changed(port_id)` + `fleet_changed` are emitted.
static func buy(port_id: String, good_id: String, qty: int) -> bool:
	if DataLoader.get_port(port_id).is_empty():
		push_error("TradeEngine.buy: unknown port '%s'" % port_id)
		return false
	if DataLoader.get_good(good_id).is_empty():
		push_error("TradeEngine.buy: unknown good '%s'" % good_id)
		return false
	# Phase 7 listing rule (docs/30 §4.4): an unlisted port-good has no stock
	# and no rows — it never transacts. A quiet refusal: the market never
	# offers the row, so this only guards direct engine callers.
	if not is_listed(port_id, good_id):
		return false
	if qty <= 0:
		return false
	if qty > buy_max(port_id, good_id):
		return false
	# The walk is planned before anything mutates, so a refused trade leaves
	# not even the stock touched (all-or-nothing, docs/30 §4.4).
	var cost := _walk_total(port_id, good_id,
		EconomyLib.plan_trade(port_id, good_id, qty), false)
	# docs/30 §4.10: the tariff composes after all price math, on the walked
	# total, and flows to the port's effective-alignment nation.
	var tax := tax_amount(port_id, cost)
	if GameState.gold < cost + tax:
		return false
	var stored := FleetLib.add_goods(good_id, qty)
	if stored != qty:
		# Should be unreachable (buy_max already checked fleet_free); restore
		# the partial insert rather than charging for a partial fill.
		if stored > 0:
			FleetLib.remove_goods(good_id, stored)
		push_error("TradeEngine.buy: stored %d of %d '%s'" % [stored, qty, good_id])
		return false
	# Books the stock walk (identical to the planned one: nothing moved in
	# between) and then fires the §4.4 market_changed contract.
	EconomyLib.apply_trade(port_id, good_id, qty)
	GameState.add_gold(-(cost + tax))
	AllegianceLib.credit_tax(port_id, _player_nation(), tax)
	EventBus.market_changed.emit(port_id)
	FleetLib.notify_changed()
	return true


## The exact §4.4 cost of buying `qty` (the walked per-tranche sum), for
## the market screen's disabled-button reason — the flat `price × qty`
## would understate any multi-tranche purchase.
static func buy_cost(port_id: String, good_id: String, qty: int) -> int:
	if qty <= 0:
		return 0
	return _walk_total(port_id, good_id,
		EconomyLib.plan_trade(port_id, good_id, qty), false)


## Sells `qty` of a held good at the port, walking the §4.4 tranche ladder.
##
## Pays the exact per-tranche sum (docs/30 §4.4: the summed total is what
## gold, XP and reputation book — never a per-tranche recomputation),
## awards the §4.3 profit XP and the §4.6 reputation (+1 per 1,000g
## cumulative profit at the port's nation). A loss-making sale awards 0 XP
## and 0 reputation and never removes either. Over-quantity sells fail
## without changing state.
static func sell(port_id: String, good_id: String, qty: int) -> bool:
	if DataLoader.get_port(port_id).is_empty():
		push_error("TradeEngine.sell: unknown port '%s'" % port_id)
		return false
	if DataLoader.get_good(good_id).is_empty():
		push_error("TradeEngine.sell: unknown good '%s'" % good_id)
		return false
	# Phase 7 market direction + listing rule (docs/30 §4.2/§4.4): a producing
	# port never buys its own produced good (不收购) and unlisted goods have
	# no market at all. Quiet refusals — the screen disables the row.
	if not port_buys_good(port_id, good_id):
		return false
	if qty <= 0 or qty > FleetLib.held(good_id):
		return false
	var proceeds := _walk_total(port_id, good_id,
		EconomyLib.plan_trade(port_id, good_id, -qty), true)
	# docs/30 §4.10: the tariff comes off the proceeds after all price math
	# and flows to the port's effective-alignment nation. The §4.3 XP and
	# §4.6 reputation below keep booking the **gross** walked total — the tax
	# composes after that plumbing, exactly like on the buy side.
	var tax := tax_amount(port_id, proceeds)
	var removed := FleetLib.remove_goods(good_id, qty)
	if removed != qty:
		if removed > 0:
			FleetLib.add_goods(good_id, removed)
		push_error("TradeEngine.sell: removed %d of %d '%s'" % [removed, qty, good_id])
		return false
	var base := _base_price(good_id)
	EconomyLib.apply_trade(port_id, good_id, -qty)
	GameState.add_gold(proceeds - tax)
	AllegianceLib.credit_tax(port_id, _player_nation(), tax)
	# docs/50 §4.3 locked XP rule (owned by Character), booked on the summed
	# tranche total: Character computes `qty × max(0, price − basis)`; shaping
	# the call as one unit that fetched the whole cargo's proceeds against the
	# whole cargo's basis reproduces the §4.4 rule exactly:
	# proceeds − (qty−1)×basis − basis == proceeds − qty×basis.
	CharacterLib.add_profit_xp(proceeds - (qty - 1) * _profit_basis(base),
		base, 1)
	# docs/50 §4.6: the same profit figure, accumulated per nation (owned by
	# Character, which keeps the cumulative counters in the player block).
	var nation_id := str(DataLoader.get_port(port_id).get("nation_id", ""))
	CharacterLib.add_profit_reputation(
		nation_id, sale_profit_total(proceeds, base, qty)
	)
	EventBus.market_changed.emit(port_id)
	FleetLib.notify_changed()
	return true


# --- Supplies (docs/20 §4.10) ---------------------------------------------

## Fixed supply price: provisions 2g, water 1g, exempt from **all** factors
## (produces/demands/investment). 0 for an unknown kind.
static func supplies_price(kind: String) -> int:
	match kind:
		"provisions":
			return SailingSimLib.PROVISIONS_PRICE
		"water":
			return SailingSimLib.WATER_PRICE
		_:
			push_error("TradeEngine.supplies_price: unknown kind '%s'" % kind)
			return 0


## Sell-back is not offered for supplies (docs/20 §4.10), so this is a buy
## ceiling only: `min(floor(gold / price), fleet_free)`.
static func supplies_buy_max(kind: String) -> int:
	var price := supplies_price(kind)
	if price <= 0:
		return 0
	var affordable := int(floor(float(GameState.gold) / float(price)))
	return maxi(0, mini(affordable, FleetLib.fleet_free()))


## Buys provisions or water at the fixed price. Same all-or-nothing rules as
## [method buy]; the port id is only validated, never priced (supplies ignore
## every port factor by design).
static func buy_supplies(port_id: String, kind: String, qty: int) -> bool:
	if not (kind in SUPPLY_KINDS):
		push_error("TradeEngine.buy_supplies: unknown kind '%s'" % kind)
		return false
	if not port_id.is_empty() and DataLoader.get_port(port_id).is_empty():
		push_error("TradeEngine.buy_supplies: unknown port '%s'" % port_id)
		return false
	if qty <= 0 or qty > supplies_buy_max(kind):
		return false
	var cost := supplies_price(kind) * qty
	if GameState.gold < cost:
		return false
	var stored := FleetLib.add_supplies(kind, qty)
	if stored != qty:
		if stored > 0:
			FleetLib.remove_supplies(kind, stored)
		push_error("TradeEngine.buy_supplies: stored %d of %d %s"
			% [stored, qty, kind])
		return false
	GameState.add_gold(-cost)
	FleetLib.notify_changed()
	return true


# --- Sale profit & reputation (docs/50 §4.3, §4.6) -------------------------

## The locked §4.3 cost basis in gold: `floor(base_price × 0.7)` — a metagame
## approximation, unchanged by dynamic prices (docs/50 §4.3 as amended).
static func _profit_basis(base_price: int) -> int:
	return int(floor(float(base_price) * PROFIT_BASIS_FACTOR))


## docs/50 §4.3: `max(0, sell_price − floor(base_price × 0.7))` per unit.
static func per_unit_profit(sell_price_value: int, base_price: int) -> int:
	return maxi(0, sell_price_value - _profit_basis(base_price))


## Transaction profit at a flat per-unit price, `qty × per-unit` (floored at
## 0 — never negative). Kept for single-price callers and tests.
static func sale_profit(sell_price_value: int, base_price: int, qty: int) -> int:
	return maxi(qty, 0) * per_unit_profit(sell_price_value, base_price)


## Transaction profit of a walked sale, booked on the exact §4.4 summed
## total: `max(0, proceeds − qty × basis)` — the same figure the XP award
## and the per-nation reputation book consume (docs/30 §4.4).
static func sale_profit_total(proceeds: int, base_price: int, qty: int) -> int:
	return maxi(0, proceeds - maxi(qty, 0) * _profit_basis(base_price))


## Lifetime sale profit booked against a nation (0 when never traded there).
## Owned by `Character` (§4.6) and backed by `player.profit_by_nation`.
static func profit_by_nation(nation_id: String) -> int:
	return CharacterLib.profit_by_nation(nation_id)


# --- Data-driven market rows (docs/30 §4.4 listing rule, §4.10 tax) ---------

## The port's **listed** goods, sorted by `base_price` ascending (ties by id
## for a stable order). Phase 7 listing rule (docs/30 §4.4, correction 7): a
## port lists a good iff it produces or demands it — unlisted goods have no
## stock, no rows, and never transact. The market screen iterates this list,
## so reshaping a port's `produces`/`demands` stays a data-only change; the
## tariff side of every row composes after the price math per docs/30 §4.10
## (see [method tax_mille] / [method tax_amount]).
static func goods_rows(port_id: String) -> Array:
	var port: Dictionary = DataLoader.get_port(port_id)
	var produces: Array = port.get("produces", [])
	var demands: Array = port.get("demands", [])
	var rows: Array = []
	for good in DataLoader.goods_list:
		var good_id := str((good as Dictionary).get("id", ""))
		if good_id in produces or good_id in demands:
			rows.append(good)
	rows.sort_custom(func(a, b) -> bool:
		var price_a := int(a.get("base_price", 0))
		var price_b := int(b.get("base_price", 0))
		if price_a == price_b:
			return str(a.get("id", "")) < str(b.get("id", ""))
		return price_a < price_b
	)
	return rows


## True when `good_id` is listed at `port_id` (`produces ∪ demands`, docs/30
## §4.4): the gate every player buy/sell walks through. Unknown pairs no.
static func is_listed(port_id: String, good_id: String) -> bool:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return false
	return good_id in port.get("produces", []) \
		or good_id in port.get("demands", [])


## True when the port would **buy** `good_id` from the player: listed and not
## one of its own produces — a producing port never buys its own produced
## goods (docs/30 §4.2 market direction; the screen renders 不收购).
static func port_buys_good(port_id: String, good_id: String) -> bool:
	if not is_listed(port_id, good_id):
		return false
	return not (good_id in DataLoader.get_port(port_id).get("produces", []))


# --- Tariff (docs/30 §4.10 — composes after all price math) -----------------

## The player's tariff at `port_id` in the C-contract basis points
## (0 / 500 / 2000 after permits; `Allegiance.tariff_mille` is the rule).
static func tax_mille(port_id: String) -> int:
	return AllegianceLib.tariff_mille(port_id, _player_nation())


## The tax coin on a walked transaction total (`total × mille / 10,000`,
## integer division — the same composition `tools/sim_trade.py` mirrors).
static func tax_amount(port_id: String, total: int) -> int:
	if total <= 0:
		return 0
	@warning_ignore("integer_division")
	return total * tax_mille(port_id) / AllegianceLib.TARIFF_SCALE


## The player's nation id (`""` before a run exists).
static func _player_nation() -> String:
	return str(GameState.player.get("nation_id", ""))


# --- Helpers ---------------------------------------------------------------

## The stock factor in per-thousand units — `Economy.factor_units` is the
## single source (docs/30 §4.2); an unknown port/good reads as neutral rest.
static func _factor_units(port_id: String, good_id: String) -> int:
	return EconomyLib.factor_units(port_id, good_id)


## `1 − min(0.10, invested/500 × 0.01)` in per-thousand units. Integer maths:
## `invested × 10 / 500` is the discount in per-mille, so 1,500g → 30 → 0.970.
static func _discount_units(port_id: String) -> int:
	@warning_ignore("integer_division")
	var per_mille := invested(port_id) * DISCOUNT_PER_MILLE / INVEST_CHUNK
	return UNITS - mini(int(round(DISCOUNT_CAP * float(UNITS))), per_mille)


## One tranche's price: the §4.2 price plumbing applied at the tranche's
## stock-before `factor_units` (band + discount + title, floored once on
## the full product). Integer only — the §4.4 summed total is exact.
static func _tranche_price(base_price: int, discount_units: int,
		tranche: Dictionary, sell_side: bool, title: int) -> int:
	@warning_ignore("integer_division")
	var combined := clampi(
		(int(tranche["factor_units"]) * discount_units) / UNITS,
		BAND_MIN_UNITS, BAND_MAX_UNITS
	)
	return price_from_units(base_price, combined, sell_side, title)


## The exact §4.4 transaction total: `Σ price_t × units_t` over the walk,
## each tranche floored once on its full product.
static func _walk_total(port_id: String, good_id: String, walk: Array,
		sell_side: bool) -> int:
	var base := _base_price(good_id)
	var discount := _discount_units(port_id)
	var title := title_units(port_id) if sell_side else UNITS
	var total := 0
	for tranche in walk:
		var price := _tranche_price(base, discount, tranche, sell_side, title)
		total += price * int(tranche["units"])
	return total


## `factor × discount`, band-clamped to `[0.5, 2.0]`, in per-thousand units.
static func _combined_units(port_id: String, good_id: String) -> int:
	@warning_ignore("integer_division")
	var raw := (_factor_units(port_id, good_id) * _discount_units(port_id)) / UNITS
	return clampi(raw, BAND_MIN_UNITS, BAND_MAX_UNITS)


## A gross total plus its §4.10 tariff: `total + total × mille / 10,000`
## (integer division — the exact composition `tools/sim_trade.py` mirrors).
static func _taxed_total(total: int, mille: int) -> int:
	@warning_ignore("integer_division")
	return total + total * mille / AllegianceLib.TARIFF_SCALE


static func _base_price(good_id: String) -> int:
	return int(DataLoader.get_good(good_id).get("base_price", 0))
