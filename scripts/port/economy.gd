class_name Economy
extends RefCounted
## Stock economy core (Phase 5) — docs/30-PORTS-AND-TRADE.md §4.2 (stock,
## factor, consumption tiers, drift), §4.4 (tranche repricing), §4.5 (demand
## events' rest-override hook); docs/90-ARCHITECTURE.md §5.4 (GameState
## `market_stocks` block, day-tick listener order).
##
## **Ownership split** (docs/30 §4.2): this module owns *stock state, drift
## and the factor*; `trade_engine.gd` keeps the *price plumbing* (margin,
## discount, title, band). Nothing here computes a gold price.
##
## **Pure** in the house sense (docs/90 §4, same as `trade_engine.gd`):
## RefCounted with static functions, no node references, headless-testable.
## The stock block lives in `GameState.market_stocks` (`{port_id:
## {good_id: stock}}`, saved — docs/90 §5.4/§8.1); the rest-override table is
## *transient runtime state* (demand events re-apply it on load — task L),
## with `reset_overrides()` as the test/new-run seam.
##
## **Exact arithmetic.** Everything is integers. The price factor is
## `clamp(1500 − 5 × stock, 500, 2000)` per thousand (docs/30 §4.2), which
## equals the retired static factors exactly at resting stock:
## produced 700 (0.7) / demanded 1300 (1.3) / neutral 1000 (1.0).
## No floats anywhere in this file.

## Stock band, hard-clamped per port-good (docs/30 §4.2).
const STOCK_MIN := 0
const STOCK_MAX := 200
## Resting stock, derived from `ports.json` with the retired factors'
## precedence: produced beats demanded beats neutral (docs/30 §4.2).
const REST_PRODUCED := 160
const REST_DEMANDED := 40
const REST_NEUTRAL := 100
## Exact per-thousand price factor: `1500 − 5 × stock`, clamped to
## `[500, 2000]` (docs/30 §4.2). The `2000` upper bound is a safety net only —
## the stock range maps the factor into `[500, 1500]`.
const FACTOR_BASE := 1500
const FACTOR_PER_STOCK := 5
const FACTOR_MIN := 500
const FACTOR_MAX := 2000
## Repricing tranche (docs/30 §4.4): every 10 units form one tranche (the
## last may be smaller); each transacts at the stock *before* it applies.
const TRANCHE_UNITS := 10
## Demand-event rest-override clamp (docs/30 §4.5): `rest += shift` lands in
## `[10, 190]`. The rotation itself is task L; this is only the hook.
const OVERRIDE_MIN := 10
const OVERRIDE_MAX := 190
## Consumption-tier drift rates (docs/30 §4.2): rank all goods by
## (`base_price` asc, `id` asc); indices 0–4 are staples (±3/day), 5–14
## middle (±2/day), 15–19 luxuries (±1/day). Derived from `goods.json` —
## zero new data; the validator asserts the 5/10/5 split.
const DRIFT_STAPLE := 3
const DRIFT_MIDDLE := 2
const DRIFT_LUXURY := 1
const STAPLE_MAX_INDEX := 4
const LUXURY_MIN_INDEX := 15

## `{port_id: {good_id: {rest: int, until_day: int}}}` — the demand-event
## hook (docs/30 §4.5). Transient: not saved; active event *instances* are
## saved in `GameState.market_events` and re-applied by their owner (task L).
static var _rest_overrides: Dictionary = {}
## `good_id → {index: int, rate: int}` consumption-tier table, derived lazily
## from `DataLoader.goods_list`; `refresh_tiers()` re-derives (test seam).
static var _tiers: Dictionary = {}


# --- Stock state (GameState.market_stocks, docs/90 §5.4) --------------------

## The derived resting-stock table for a whole run: `{port_id: {good_id:
## rest}}`, no RNG (docs/30 §4.2 "new_game initializes every port-good at its
## rest"). `ports`/`goods` are the loaded lists, so this is pure and
## fixture-friendly.
static func build_initial_stocks(ports: Array, goods: Array) -> Dictionary:
	var stocks: Dictionary = {}
	for port in ports:
		var port_id := str((port as Dictionary).get("id", ""))
		if port_id.is_empty():
			continue
		var row: Dictionary = {}
		for good in goods:
			var good_id := str((good as Dictionary).get("id", ""))
			if good_id.is_empty():
				continue
			row[good_id] = resting_stock_of(port, good_id)
		stocks[port_id] = row
	return stocks


## Resting stock of one port-good from a port dictionary — the retired
## factors' precedence: produced → demanded → neutral (docs/30 §4.2).
static func resting_stock_of(port: Dictionary, good_id: String) -> int:
	if good_id in port.get("produces", []):
		return REST_PRODUCED
	if good_id in port.get("demands", []):
		return REST_DEMANDED
	return REST_NEUTRAL


## Derived resting stock via the loader (unknown port/good → neutral).
static func rest_stock(port_id: String, good_id: String) -> int:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return REST_NEUTRAL
	return resting_stock_of(port, good_id)


## Current stock of one port-good. A missing entry (a run started before the
## block existed, a hand-edited save) reads as the derived rest, so every
## price is the §4.2 resting price — never a crash, never a stale 0.
static func stock_of(port_id: String, good_id: String) -> int:
	var port_stocks: Dictionary = GameState.market_stocks.get(port_id, {})
	if port_stocks.has(good_id):
		return maxi(STOCK_MIN, int(port_stocks[good_id]))
	return rest_stock(port_id, good_id)


## Writes one stock, hard-clamped to `[0, 200]` (docs/30 §4.2).
static func set_stock(port_id: String, good_id: String, value: int) -> void:
	if not GameState.market_stocks.has(port_id):
		GameState.market_stocks[port_id] = {}
	GameState.market_stocks[port_id][good_id] = \
		clampi(value, STOCK_MIN, STOCK_MAX)


# --- Price factor (docs/30 §4.2, exact) -------------------------------------

## The pure factor formula: `clamp(1500 − 5 × stock, 500, 2000)` per thousand.
static func factor_for_stock(stock: int) -> int:
	return clampi(FACTOR_BASE - FACTOR_PER_STOCK * stock, FACTOR_MIN, FACTOR_MAX)


## THE single source `trade_engine` consumes: the factor of the port-good's
## *current* stock. Equals 700/1300/1000 exactly at resting stock.
static func factor_units(port_id: String, good_id: String) -> int:
	return factor_for_stock(stock_of(port_id, good_id))


# --- Consumption tiers (docs/30 §4.2) ---------------------------------------

## Re-derives the tier table from `goods.json` (load does this lazily; tests
## call it after manipulating `goods_list`).
static func refresh_tiers() -> void:
	_tiers.clear()
	var ranked: Array = DataLoader.goods_list.duplicate()
	ranked.sort_custom(func(a, b) -> bool:
		var price_a := int((a as Dictionary).get("base_price", 0))
		var price_b := int((b as Dictionary).get("base_price", 0))
		if price_a == price_b:
			return str((a as Dictionary).get("id", "")) \
				< str((b as Dictionary).get("id", ""))
		return price_a < price_b
	)
	for index in ranked.size():
		var good_id := str((ranked[index] as Dictionary).get("id", ""))
		if good_id.is_empty():
			continue
		_tiers[good_id] = {
			"index": index,
			"rate": _rate_for_index(index),
		}


static func _rate_for_index(index: int) -> int:
	if index <= STAPLE_MAX_INDEX:
		return DRIFT_STAPLE
	if index >= LUXURY_MIN_INDEX:
		return DRIFT_LUXURY
	return DRIFT_MIDDLE


## `{good_id: {index, rate}}` — the tier table (derived once, then cached).
static func tier_table() -> Dictionary:
	if _tiers.is_empty():
		refresh_tiers()
	return _tiers


## 0-based consumption-tier index of a good, `(base_price asc, id asc)` rank.
## Unknown goods rank last (luxury drift: they are the least staple-like).
static func tier_index(good_id: String) -> int:
	var tiers := tier_table()
	if tiers.has(good_id):
		return int((tiers[good_id] as Dictionary)["index"])
	return DataLoader.goods_list.size()


## Daily drift magnitude of a good: ±3 staples / ±2 middle / ±1 luxuries.
static func tier_rate(good_id: String) -> int:
	var tiers := tier_table()
	if tiers.has(good_id):
		return int((tiers[good_id] as Dictionary)["rate"])
	return DRIFT_LUXURY


# --- Drift (docs/30 §4.2) ---------------------------------------------------

## One economy day for every port: each stock moves one tier step toward its
## *effective* rest, never past it (the hard `[0, 200]` clamp holds by
## construction — rests live inside it). Expired rest-overrides are dropped.
## Returns the ids of ports whose stock actually moved, in `ports.json` file
## order — the caller emits `EventBus.market_changed` per port (the pure
## module never emits; docs/90 §5.1 signal discipline).
##
## Runs once per day tick — after the daily ledger, before the world-scene
## listeners (docs/20 §4.3) — and on port day-advances alike (they share the
## same tick path).
static func day_tick() -> Array:
	var moved: Array = []
	for port in DataLoader.ports_list:
		var port_id := str((port as Dictionary).get("id", ""))
		var port_stocks: Dictionary = GameState.market_stocks.get(port_id, {})
		if port_stocks.is_empty():
			continue
		var port_moved := false
		for good_id in port_stocks:
			var stock := stock_of(port_id, str(good_id))
			var drifted := _drift_step(
				stock, effective_rest(port_id, str(good_id)),
				tier_rate(str(good_id))
			)
			if drifted != stock:
				set_stock(port_id, str(good_id), drifted)
				port_moved = true
		if port_moved:
			moved.append(port_id)
	_drop_expired_overrides(GameState.day)
	return moved


## One step toward `rest` at `rate`, never past it (docs/30 §4.2).
static func _drift_step(stock: int, rest: int, rate: int) -> int:
	if stock < rest:
		return mini(rest, stock + maxi(rate, 0))
	if stock > rest:
		return maxi(rest, stock - maxi(rate, 0))
	return stock


# --- Demand-event hook (docs/30 §4.5) ---------------------------------------
#
# The ROTATION (scheduling, budgets, telegraphs) is task L. This is only the
# override table it plugs into: a temporary per-good rest target with an
# expiry day, clamped to `[10, 190]`.

## Overrides a port-good's rest target until `until_day` (exclusive). The
## value is clamped to the §4.5 effect band `[10, 190]`.
static func set_rest_override(port_id: String, good_id: String,
		rest_value: int, until_day: int) -> void:
	if not _rest_overrides.has(port_id):
		_rest_overrides[port_id] = {}
	_rest_overrides[port_id][good_id] = {
		"rest": clampi(rest_value, OVERRIDE_MIN, OVERRIDE_MAX),
		"until_day": until_day,
	}


static func clear_rest_override(port_id: String, good_id: String) -> void:
	if _rest_overrides.has(port_id):
		(_rest_overrides[port_id] as Dictionary).erase(good_id)


## Test/new-run seam: drops the whole transient override table (active event
## instances survive in `GameState.market_events` and are re-applied by L).
static func reset_overrides() -> void:
	_rest_overrides = {}


## The rest target drift actually heals toward: the derived rest, or the
## active override (`rest += shift`, clamped `[10, 190]`, docs/30 §4.5) while
## `day < until_day`. `day < 0` means "now" (`GameState.day`). Expired
## overrides are dropped on read.
static func effective_rest(port_id: String, good_id: String, day: int = -1) -> int:
	var today := GameState.day if day < 0 else day
	var port_overrides: Dictionary = _rest_overrides.get(port_id, {})
	if port_overrides.has(good_id):
		var override: Dictionary = port_overrides[good_id]
		if today < int(override["until_day"]):
			return clampi(int(override["rest"]), OVERRIDE_MIN, OVERRIDE_MAX)
		clear_rest_override(port_id, good_id)
	return rest_stock(port_id, good_id)


static func _drop_expired_overrides(today: int) -> void:
	for port_id in _rest_overrides.keys():
		var port_overrides: Dictionary = _rest_overrides[port_id]
		for good_id in (port_overrides.keys() as Array).duplicate():
			if today >= int((port_overrides[good_id] as Dictionary)["until_day"]):
				port_overrides.erase(good_id)
		if port_overrides.is_empty():
			_rest_overrides.erase(port_id)


# --- Tranche repricing (docs/30 §4.4) ---------------------------------------
#
# A quantity q splits into ceil(q/10) tranches of 10 units (the last may be
# smaller). `qty_signed > 0` is a BUY (stock falls, price rises per tranche);
# `qty_signed < 0` is a SELL (stock rises, price falls). Each tranche
# transacts at the stock *before* it applies; a walk larger than the range
# parks at the bound and keeps transacting there — continuously, no clamp
# jump. The caller (trade_engine) prices each tranche and sums the exact
# integer total; this module only walks and books stock.

## The pure walk: `[{"units", "stock_before", "factor_units"}, …]`, one entry
## per tranche, for `qty_signed` units at the port-good's current stock.
## Books nothing.
static func plan_trade(port_id: String, good_id: String, qty_signed: int) -> Array:
	var quantity := absi(qty_signed)
	if quantity <= 0:
		return []
	var direction := -1 if qty_signed > 0 else 1  # buy drains, sell fills
	var walk: Array = []
	var stock := stock_of(port_id, good_id)
	var remaining := quantity
	while remaining > 0:
		var units := mini(TRANCHE_UNITS, remaining)
		walk.append({
			"units": units,
			"stock_before": stock,
			"factor_units": factor_for_stock(stock),
		})
		stock = clampi(stock + direction * units, STOCK_MIN, STOCK_MAX)
		remaining -= units
	return walk


## [method plan_trade] plus booking: the port-good's stock lands where the
## walk leaves it. Returns the same walk. Pricing and `market_changed`
## emission stay with the caller (docs/30 §4.2 ownership, docs/90 §5.1).
static func apply_trade(port_id: String, good_id: String, qty_signed: int) -> Array:
	var walk := plan_trade(port_id, good_id, qty_signed)
	if walk.is_empty():
		return []
	var last: Dictionary = walk[walk.size() - 1]
	var direction := -1 if qty_signed > 0 else 1
	var final_stock := clampi(
		int(last["stock_before"]) + direction * int(last["units"]),
		STOCK_MIN, STOCK_MAX
	)
	set_stock(port_id, good_id, final_stock)
	return walk
