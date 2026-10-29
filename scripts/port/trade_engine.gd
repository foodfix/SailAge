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
## **Exact arithmetic.** The §4.2 formulas are rational: the factor is 7/10,
## 13/10 or 1 and the investment discount is `1 − k/100`. Everything is
## therefore computed on a per-thousand fixed point (`combined_units`), which
## makes `floor(base × factor × discount)` exact — no float noise can turn
## `floor(30 × 0.7) = 21` into 20. Each price is floored exactly once, on the
## full product, as the §4.2 formula line specifies.
##
## **No dynamic pricing.** Ports buy and sell unlimited quantities at the
## fixed computed price (docs/30 §4.4); nothing here moves a price in response
## to a transaction.

const FleetLib := preload("res://scripts/fleet/fleet.gd")
const CharacterLib := preload("res://scripts/player/character.gd")
## Supply prices are owned by the sailing sim (docs/20 §4.10, §5): reuse the
## constants instead of re-declaring the locked 2g / 1g values.
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")

# --- §4.2 price factors ----------------------------------------------------

## A good in `port.produces` is cheap here.
const PRODUCES_FACTOR := 0.7
## A good in `port.demands` is expensive here.
const DEMANDS_FACTOR := 1.3
## Everything else trades at base price.
const NEUTRAL_FACTOR := 1.0
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

## `0.7` when the port produces the good, `1.3` when it demands it, else `1.0`.
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


## Sell price, `max(1, floor(base × factor × 0.8 × discount))`.
static func sell_price(port_id: String, good_id: String) -> int:
	return price_from_units(
		_base_price(good_id), _combined_units(port_id, good_id), true
	)


## The band clamp on an arbitrary `factor × discount` product, in per-thousand
## units. Exposed so the `[0.5, 2.0]` rule is unit-testable in isolation: the
## shipped data never produces a factor below 0.7, so the lower clamp itself is
## only reachable through a synthetic factor (e.g. 0.4 → 0.5).
static func band_units(factor_value: float, discount_value: float) -> int:
	var combined := clampf(factor_value * discount_value, BAND_MIN, BAND_MAX)
	return int(round(combined * float(UNITS)))


## One price from a base and an already-clamped `combined` value in per-thousand
## units (buy when `sell_side` is false). Floors the full product exactly once.
static func price_from_units(base_price: int, combined_units: int, sell_side: bool) -> int:
	var base := maxi(base_price, 0)
	var units := clampi(combined_units, BAND_MIN_UNITS, BAND_MAX_UNITS)
	var numerator := base * units
	var denominator := UNITS
	if sell_side:
		numerator *= SELL_MARGIN_NUM
		denominator *= SELL_MARGIN_DEN
	@warning_ignore("integer_division")
	var price := numerator / denominator
	return maxi(MIN_PRICE, price)


# --- Quantity limits (docs/30 §4.4) ----------------------------------------

## `min(floor(gold / buy_price), fleet_free)` — the UI's quantity ceiling and
## the hard limit [method buy] enforces.
static func buy_max(port_id: String, good_id: String) -> int:
	var price := buy_price(port_id, good_id)
	if price <= 0:
		return 0
	var affordable := int(floor(float(GameState.gold) / float(price)))
	return maxi(0, mini(affordable, FleetLib.fleet_free()))


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


## True when another 500g chunk is allowed: below the 5,000g cap and affordable.
static func can_invest(port_id: String) -> bool:
	if port_id.is_empty() or DataLoader.get_port(port_id).is_empty():
		return false
	if invested(port_id) >= INVEST_CAP_GOLD:
		return false
	return GameState.gold >= INVEST_CHUNK


## Invests one 500g chunk, permanently. Returns false (state untouched) at the
## cap or when the purse cannot pay — "the 11th click is impossible".
static func invest(port_id: String) -> bool:
	if not can_invest(port_id):
		return false
	GameState.port_investments[port_id] = invested(port_id) + INVEST_CHUNK
	GameState.add_gold(-INVEST_CHUNK)
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

## Buys `qty` of a good at the port.
##
## Validation is all-or-nothing: an invalid quantity, a quantity above
## [method buy_max] (gold **and** pooled fleet free capacity), or a failed stock
## insertion changes nothing at all (docs/30 §4.4 "Transaction errors … change
## nothing"). On success: gold is charged, goods are stored flagship-first
## (docs/40 §4.2) and `gold_changed` + `fleet_changed` are emitted.
static func buy(port_id: String, good_id: String, qty: int) -> bool:
	if DataLoader.get_port(port_id).is_empty():
		push_error("TradeEngine.buy: unknown port '%s'" % port_id)
		return false
	if DataLoader.get_good(good_id).is_empty():
		push_error("TradeEngine.buy: unknown good '%s'" % good_id)
		return false
	if qty <= 0:
		return false
	if qty > buy_max(port_id, good_id):
		return false
	var cost := buy_price(port_id, good_id) * qty
	if GameState.gold < cost:
		return false
	var stored := FleetLib.add_goods(good_id, qty)
	if stored != qty:
		# Should be unreachable (buy_max already checked fleet_free); restore
		# the partial insert rather than charging for a partial fill.
		if stored > 0:
			FleetLib.remove_goods(good_id, stored)
		push_error("TradeEngine.buy: stored %d of %d '%s'" % [stored, qty, good_id])
		return false
	GameState.add_gold(-cost)
	FleetLib.notify_changed()
	return true


## Sells `qty` of a held good at the port.
##
## Pays the sell price, awards the §4.3 profit XP and the §4.6 reputation
## (+1 per 1,000g cumulative profit at the port's nation). A loss-making sale
## awards 0 XP and 0 reputation and never removes either. Over-quantity sells
## fail without changing state.
static func sell(port_id: String, good_id: String, qty: int) -> bool:
	if DataLoader.get_port(port_id).is_empty():
		push_error("TradeEngine.sell: unknown port '%s'" % port_id)
		return false
	if DataLoader.get_good(good_id).is_empty():
		push_error("TradeEngine.sell: unknown good '%s'" % good_id)
		return false
	if qty <= 0 or qty > FleetLib.held(good_id):
		return false
	var price := sell_price(port_id, good_id)
	var removed := FleetLib.remove_goods(good_id, qty)
	if removed != qty:
		if removed > 0:
			FleetLib.add_goods(good_id, removed)
		push_error("TradeEngine.sell: removed %d of %d '%s'" % [removed, qty, good_id])
		return false
	var base := _base_price(good_id)
	GameState.add_gold(price * qty)
	# docs/50 §4.3 locked XP rule (owned by Character).
	CharacterLib.add_profit_xp(price, base, qty)
	# docs/50 §4.6: the same profit figure, accumulated per nation (owned by
	# Character, which keeps the cumulative counters in the player block).
	var nation_id := str(DataLoader.get_port(port_id).get("nation_id", ""))
	CharacterLib.add_profit_reputation(
		nation_id, sale_profit(price, base, qty)
	)
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

## docs/50 §4.3: `max(0, sell_price − floor(base_price × 0.7))` per unit.
static func per_unit_profit(sell_price_value: int, base_price: int) -> int:
	return maxi(
		0, sell_price_value - int(floor(float(base_price) * PROFIT_BASIS_FACTOR))
	)


## Transaction profit, `qty × per-unit` (floored at 0 — never negative).
static func sale_profit(sell_price_value: int, base_price: int, qty: int) -> int:
	return maxi(qty, 0) * per_unit_profit(sell_price_value, base_price)


## Lifetime sale profit booked against a nation (0 when never traded there).
## Owned by `Character` (§4.6) and backed by `player.profit_by_nation`.
static func profit_by_nation(nation_id: String) -> int:
	return CharacterLib.profit_by_nation(nation_id)


# --- Data-driven market rows ----------------------------------------------

## Every good in `data/goods.json`, sorted by `base_price` ascending (ties by
## id for a stable order) — docs/30 §4.7. The market screen iterates this list,
## so adding a 21st good is a data-only change.
static func goods_rows() -> Array:
	var rows: Array = DataLoader.goods_list.duplicate()
	rows.sort_custom(func(a, b) -> bool:
		var price_a := int(a.get("base_price", 0))
		var price_b := int(b.get("base_price", 0))
		if price_a == price_b:
			return str(a.get("id", "")) < str(b.get("id", ""))
		return price_a < price_b
	)
	return rows


# --- Helpers ---------------------------------------------------------------

static func _factor_units(port_id: String, good_id: String) -> int:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return UNITS
	if good_id in port.get("produces", []):
		return int(round(PRODUCES_FACTOR * float(UNITS)))
	if good_id in port.get("demands", []):
		return int(round(DEMANDS_FACTOR * float(UNITS)))
	return int(round(NEUTRAL_FACTOR * float(UNITS)))


## `1 − min(0.10, invested/500 × 0.01)` in per-thousand units. Integer maths:
## `invested × 10 / 500` is the discount in per-mille, so 1,500g → 30 → 0.970.
static func _discount_units(port_id: String) -> int:
	@warning_ignore("integer_division")
	var per_mille := invested(port_id) * DISCOUNT_PER_MILLE / INVEST_CHUNK
	return UNITS - mini(int(round(DISCOUNT_CAP * float(UNITS))), per_mille)


## `factor × discount`, band-clamped to `[0.5, 2.0]`, in per-thousand units.
static func _combined_units(port_id: String, good_id: String) -> int:
	@warning_ignore("integer_division")
	var raw := (_factor_units(port_id, good_id) * _discount_units(port_id)) / UNITS
	return clampi(raw, BAND_MIN_UNITS, BAND_MAX_UNITS)


static func _base_price(good_id: String) -> int:
	return int(DataLoader.get_good(good_id).get("base_price", 0))
