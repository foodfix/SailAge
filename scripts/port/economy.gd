class_name Economy
extends RefCounted
## Flow-economy stock core (Phase 7) — docs/30-PORTS-AND-TRADE.md §4.2 (the
## flow tick, tier rates/capacities, initial stocks, market direction), §4.4
## (tranche repricing), §4.5 (demand events as consumption-rate surges);
## docs/90-ARCHITECTURE.md §5.4 (GameState `market_stocks` block, day-tick
## listener order, month-tick ordering pin).
##
## **CHANGELOG (task K, IMPLEMENT-Phase7.md correction 9):** the Phase-5
## drift-to-rest model is retired in this commit. The retired constants and
## semantics — REST_PRODUCED 160 / REST_DEMANDED 40 / REST_NEUTRAL 100, the
## ±3/±2/±1 tier drift rates derived from the `(base_price, id)` rank order,
## the `[10, 190]` rest-override clamp, and the `shifts` rest-delta event
## shape — survive NOWHERE except this comment. The live model is the
## §4.2 flow tick: tier rates 5/3/2 per day read from the `goods.json`
## `staple`/`specialty` flags, capacities 160/140/120 + 20/dev with the 200
## ceiling, producers fill toward capacity, consumers drain to a 0 floor,
## and demand events triple consumption (`rate_override`) for their
## duration.
##
## **Ownership split** (docs/30 §4.2): this module owns *stock state, the
## flow tick and the factor*; `trade_engine.gd` keeps the *price plumbing*
## (margin, discount, title, band). Nothing here computes a gold price, and
## `trade_engine.gd` keeps reading `Economy.factor_units` unchanged (L owns
## that file — this module does not touch it).
##
## **Pure** in the house sense (docs/90 §4, same as `trade_engine.gd`):
## RefCounted with static functions, no node references, headless-testable.
## The stock block lives in `GameState.market_stocks` (`{port_id:
## {good_id: stock}}`, saved — docs/90 §5.4; the Phase-7 change is
## semantics only, the format is unchanged); the consumption-surge table is
## *transient runtime state* (active event instances are saved and
## re-applied on load via `ensure_event_overrides`), with `reset_overrides()`
## as the test/new-run seam.
##
## **Exact arithmetic.** Everything is integers. The price factor is
## `clamp(1500 − 5 × stock, 500, 2000)` per thousand (docs/30 §4.2). No
## floats anywhere in this file.

## Stock band, hard-clamped per port-good (docs/30 §4.2).
const STOCK_MIN := 0
const STOCK_MAX := 200
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
## Flow-economy tier rates (docs/30 §4.2): staples 5/day, middle 3/day,
## luxuries 2/day — ONE rate serves both production and consumption unless
## the good's `flow {prod, cons, capacity}` override names a side. The tier
## is read from the `goods.json` flags (`staple: true` / `specialty: true` /
## unflagged middle), never derived from an ordering.
const FLOW_RATE_STAPLE := 5
const FLOW_RATE_MIDDLE := 3
const FLOW_RATE_LUXURY := 2
## Capacity by tier (docs/30 §4.2): 160/140/120, plus +20 per dev level,
## hard ceiling `STOCK_MAX` (200).
const FLOW_CAPACITY_STAPLE := 160
const FLOW_CAPACITY_MIDDLE := 140
const FLOW_CAPACITY_LUXURY := 120
const CAPACITY_PER_DEV := 20
## Initial stocks (new game, docs/30 §4.2): producers at capacity, consumers
## at 60 (derived, no RNG). Unlisted goods hold no stock at all.
const INITIAL_CONSUMER_STOCK := 60
## Demand events (docs/30 §4.5): an active event triples the consumption
## rate of its `rate_override` goods for `duration_days`; production,
## capacities and the price formula are untouched.
const EVENT_CONSUMPTION_MULT := 3
## Demand-event budget (docs/30 §4.5): ≤ 1 active per nation, ≤ 4 world-wide.
const EVENTS_PER_NATION_MAX := 1
const EVENTS_WORLD_MAX := 4
## The seeded schedule's formula family: one window per template per
## `cadence_days`; the window index and template index salt the Phase-2
## formula constants, so every run replays the same schedule exactly.
const EVENT_SEED_WINDOW_MULT := 1000003
const EVENT_SEED_INDEX_MULT := 7919

## Guard-read path for C's `Allegiance.dev()` symbol contract
## (IMPLEMENT-Phase7.md task K / C's §80 inventory). `allegiance.gd` lands
## in a parallel W3 worktree, so this module NEVER hard-references the
## Allegiance class: it loads the script by path, guards every access, and
## defaults to **dev 0** while the module is absent (the unallied floor,
## docs/30 §4.9). When L's module lands, `dev_level` returns the derived
## `max(authored floor, ledger thresholds)` value unchanged.
const ALLEGIANCE_PATH := "res://scripts/port/allegiance.gd"

## `{good_id: {tier: String, prod_rate: int, cons_rate: int,
## base_capacity: int}}` — the flag-driven tier table, derived lazily from
## `DataLoader.goods_list`; `refresh_tiers()` re-derives (test seam).
static var _tiers: Dictionary = {}
## `{port_id: {good_id: until_day}}` — the active consumption-rate surges
## (docs/30 §4.5). Transient: not saved; active event *instances* are saved
## in `GameState.market_events` and re-applied by `ensure_event_overrides`.
static var _cons_surges: Dictionary = {}
## Instances started by the most recent rotation pass (docs/30 §4.5):
## `{template_id, port_id, start_day}` — telegraph rows derive from the
## active list instead of a signal.
static var _last_started_events: Array = []


# --- Development guard (C's Allegiance.dev() contract) -----------------------

## The dev level that drives flow rates and capacity: guard-read from
## `allegiance.gd`'s `dev(port_id)` (see [constant ALLEGIANCE_PATH]); safe
## default **0** while that module is absent. Documented at the call site
## per the W3 guard-call convention.
static func dev_level(port_id: String) -> int:
	if not ResourceLoader.exists(ALLEGIANCE_PATH, "Script"):
		return 0
	var allegiance: Script = load(ALLEGIANCE_PATH)
	if allegiance == null or not allegiance.has_method("dev"):
		return 0
	return maxi(0, int(allegiance.call("dev", port_id)))


# --- Tier table (docs/30 §4.2, flag-driven) ----------------------------------

## Re-derives the tier table from the `goods.json` flags (load does this
## lazily; tests call it after manipulating `goods_list`).
static func refresh_tiers() -> void:
	_tiers.clear()
	for good in DataLoader.goods_list:
		var good_id := str((good as Dictionary).get("id", ""))
		if good_id.is_empty():
			continue
		_tiers[good_id] = _tier_row(good as Dictionary)


## One good's tier row: the tier comes from the flags; the rates and
## capacity come from the tier unless the optional `flow` object overrides
## them per key (`prod` / `cons` / `capacity`).
static func _tier_row(good: Dictionary) -> Dictionary:
	var tier := "middle"
	if good.get("staple", false) == true:
		tier = "staple"
	elif good.get("specialty", false) == true:
		tier = "luxury"
	var rate := FLOW_RATE_MIDDLE
	var capacity := FLOW_CAPACITY_MIDDLE
	match tier:
		"staple":
			rate = FLOW_RATE_STAPLE
			capacity = FLOW_CAPACITY_STAPLE
		"luxury":
			rate = FLOW_RATE_LUXURY
			capacity = FLOW_CAPACITY_LUXURY
	var flow: Dictionary = good.get("flow", {}) \
		if good.get("flow", {}) is Dictionary else {}
	return {
		"tier": tier,
		"prod_rate": int(flow.get("prod", rate)),
		"cons_rate": int(flow.get("cons", rate)),
		"base_capacity": int(flow.get("capacity", capacity)),
	}


## `{good_id: {tier, prod_rate, cons_rate, base_capacity}}` (derived once,
## then cached).
static func tier_table() -> Dictionary:
	if _tiers.is_empty():
		refresh_tiers()
	return _tiers


## `"staple" | "middle" | "luxury"` from the goods flags; unknown goods rank
## as middle (the unflagged default).
static func tier_of(good_id: String) -> String:
	var tiers := tier_table()
	if tiers.has(good_id):
		return str((tiers[good_id] as Dictionary)["tier"])
	return "middle"


## Daily production rate of a good: the tier rate or the `flow.prod`
## override (docs/30 §4.2).
static func prod_rate(good_id: String) -> int:
	var tiers := tier_table()
	if tiers.has(good_id):
		return maxi(0, int((tiers[good_id] as Dictionary)["prod_rate"]))
	return FLOW_RATE_MIDDLE


## Daily consumption rate of a good: the tier rate or the `flow.cons`
## override (docs/30 §4.2).
static func cons_rate(good_id: String) -> int:
	var tiers := tier_table()
	if tiers.has(good_id):
		return maxi(0, int((tiers[good_id] as Dictionary)["cons_rate"]))
	return FLOW_RATE_MIDDLE


## Tier-base capacity of a good before the dev bonus (160/140/120 or the
## `flow.capacity` override).
static func tier_capacity(good_id: String) -> int:
	var tiers := tier_table()
	if tiers.has(good_id):
		return maxi(0, int((tiers[good_id] as Dictionary)["base_capacity"]))
	return FLOW_CAPACITY_MIDDLE


## Pure dev-multiplier arithmetic (docs/30 §4.2): integer
## `rate × (4 + dev) / 4` — dev 0/1/2/3 → ×1.0/×1.25/×1.5/×1.75 (the doc's
## ×2.0 label at dev 3 approximated by the pinned integer math).
static func dev_rate(rate: int, dev: int) -> int:
	@warning_ignore("integer_division")
	return maxi(0, rate) * (4 + clampi(dev, 0, 3)) / 4


## Pure capacity arithmetic (docs/30 §4.2): tier base + 20 × dev, hard
## ceiling `STOCK_MAX`.
static func capacity_for(base_capacity: int, dev: int) -> int:
	return mini(STOCK_MAX, maxi(0, base_capacity)
		+ CAPACITY_PER_DEV * clampi(dev, 0, 3))


## The capacity of one port-good at the port's current dev level.
static func capacity_of(port_id: String, good_id: String) -> int:
	return capacity_for(tier_capacity(good_id), dev_level(port_id))


# --- Stock state (GameState.market_stocks, docs/90 §5.4) ---------------------

## The derived initial-stock table for a whole run: `{port_id: {good_id:
## stock}}` with one row per **listed** port-good (docs/30 §4.2 listing
## rule) — producers at capacity, consumers at 60, unlisted goods absent.
## No RNG. `ports`/`goods` are the loaded lists, so this is pure and
## fixture-friendly; dev comes from [method dev_level] (fixtures default 0).
static func build_initial_stocks(ports: Array, goods: Array) -> Dictionary:
	var stocks: Dictionary = {}
	for port in ports:
		var port_id := str((port as Dictionary).get("id", ""))
		if port_id.is_empty():
			continue
		var dev := dev_level(port_id)
		var row: Dictionary = {}
		for good in goods:
			var good_id := str((good as Dictionary).get("id", ""))
			if good_id.is_empty():
				continue
			if not is_listed_in(port as Dictionary, good_id):
				continue
			row[good_id] = initial_stock_for(port as Dictionary, good_id, dev)
		stocks[port_id] = row
	return stocks


## Pure initial stock of one port-good at dev `dev` (docs/30 §4.2): a
## producer starts at capacity, a consumer at 60, an unlisted good holds
## nothing (0).
static func initial_stock_for(port: Dictionary, good_id: String,
		dev: int) -> int:
	if good_id in port.get("produces", []):
		return capacity_for(tier_capacity(good_id), dev)
	if good_id in port.get("demands", []):
		return INITIAL_CONSUMER_STOCK
	return STOCK_MIN


## Derived initial stock via the loader (unknown port → no stock: 0).
static func initial_stock_of(port_id: String, good_id: String) -> int:
	var port: Dictionary = DataLoader.get_port(port_id)
	if port.is_empty():
		return STOCK_MIN
	return initial_stock_for(port, good_id, dev_level(port_id))


## Current stock of one port-good. A missing entry (a hand-edited save, a
## row a trade has not touched yet) reads as the derived initial stock, so
## prices stay on the §4.2 semantics — never a crash, never a stale value.
static func stock_of(port_id: String, good_id: String) -> int:
	var port_stocks: Dictionary = GameState.market_stocks.get(port_id, {})
	if port_stocks.has(good_id):
		return clampi(int(port_stocks[good_id]), STOCK_MIN, STOCK_MAX)
	return initial_stock_of(port_id, good_id)


## Writes one stock, hard-clamped to `[0, 200]` (docs/30 §4.2).
static func set_stock(port_id: String, good_id: String, value: int) -> void:
	if not GameState.market_stocks.has(port_id):
		GameState.market_stocks[port_id] = {}
	GameState.market_stocks[port_id][good_id] = \
		clampi(value, STOCK_MIN, STOCK_MAX)


# --- Market direction (docs/30 §4.2 listing rule) ----------------------------
#
# Listed(port, good) = good ∈ port.produces ∪ port.demands; a producing
# port NEVER buys its own produced goods (the sell side is disabled there,
# marked 不收购 — the UI is M's; this is the helper the engine/rows read).

## True when the port-good is listed (it produces or demands the good).
static func is_listed_in(port: Dictionary, good_id: String) -> bool:
	return good_id in port.get("produces", []) \
		or good_id in port.get("demands", [])


static func is_listed(port_id: String, good_id: String) -> bool:
	return is_listed_in(DataLoader.get_port(port_id), good_id)


## True when the port produces the good (★ 特产 row; sell disabled there).
static func is_produced_at(port_id: String, good_id: String) -> bool:
	return good_id in DataLoader.get_port(port_id).get("produces", [])


## True when the port BUYS the good from a trader (sell side enabled):
## listed but not produced — a producing port never buys its own produced
## goods (docs/30 §4.2 market direction).
static func port_buys_good(port_id: String, good_id: String) -> bool:
	var port: Dictionary = DataLoader.get_port(port_id)
	return is_listed_in(port, good_id) \
		and not (good_id in port.get("produces", []))


# --- Price factor (docs/30 §4.2, exact) --------------------------------------

## The pure factor formula: `clamp(1500 − 5 × stock, 500, 2000)` per thousand.
static func factor_for_stock(stock: int) -> int:
	return clampi(FACTOR_BASE - FACTOR_PER_STOCK * stock, FACTOR_MIN, FACTOR_MAX)


## THE single source `trade_engine` consumes: the factor of the port-good's
## *current* stock.
static func factor_units(port_id: String, good_id: String) -> int:
	return factor_for_stock(stock_of(port_id, good_id))


# --- Flow tick (docs/30 §4.2) ------------------------------------------------

## One economy day for every port: each listed port-good moves by its real
## daily flow — producers `stock += prod_rate × dev_mult` clamped at
## capacity, consumers `stock −= cons_rate × dev_mult` floored at 0 (unmet
## demand sits: a starved port cannot sell what it lacks). Expired event
## surges are dropped. Returns the ids of ports whose stock actually moved,
## in `ports.json` file order — the caller emits `EventBus.market_changed`
## per port (the pure module never emits; docs/90 §5.1 signal discipline).
##
## Runs once per day tick — after the daily ledger, before the world-scene
## listeners (docs/20 §4.3) — and on port day-advances alike (they share the
## same tick path).
static func day_tick() -> Array:
	# The event rotation runs at the top of the economy step — expiries
	# first, then today's seeded starts — so the flow below already carries
	# the day's effective consumption rates (docs/30-* §4.5).
	market_events_tick()
	var moved: Array = []
	for port in DataLoader.ports_list:
		var port_id := str((port as Dictionary).get("id", ""))
		var port_stocks: Dictionary = GameState.market_stocks.get(port_id, {})
		if port_stocks.is_empty():
			continue
		var dev := dev_level(port_id)
		var produces: Array = (port as Dictionary).get("produces", [])
		var port_moved := false
		for good_id in port_stocks:
			var stock := stock_of(port_id, str(good_id))
			var flowed := _flow_step(produces, port_id, str(good_id),
				stock, dev)
			if flowed != stock:
				set_stock(port_id, str(good_id), flowed)
				port_moved = true
		if port_moved:
			moved.append(port_id)
	return moved


## One §4.2 flow step for one port-good: the produced side fills toward
## capacity, everything else (the demanded side — produces ∩ demands = ∅)
## drains toward the 0 floor.
static func _flow_step(produces: Array, port_id: String, good_id: String,
		stock: int, dev: int) -> int:
	if good_id in produces:
		var rate := dev_rate(prod_rate(good_id), dev)
		return mini(capacity_for(tier_capacity(good_id), dev),
			stock + maxi(rate, 0))
	var drain := dev_rate(cons_rate_effective(port_id, good_id), dev)
	return maxi(STOCK_MIN, stock - maxi(drain, 0))


# --- Demand-event consumption surges (docs/30 §4.5) --------------------------
#
# An event is a temporary RATE OVERRIDE: while active, each overridden
# good's consumption rate is ×3 (`EVENT_CONSUMPTION_MULT`) — production,
# capacities and the price formula are untouched. The ROTATION (scheduling,
# budgets, telegraphs) keeps its Phase-5 shape; only the effect table the
# rotation plugs into changed with the `market_events.json` `shifts` →
# `rate_override` transition (atomic — correction 9).

## Surges `good_id`'s consumption at `port_id` until `until_day` (exclusive).
static func set_consumption_surge(port_id: String, good_id: String,
		until_day: int) -> void:
	if not _cons_surges.has(port_id):
		_cons_surges[port_id] = {}
	_cons_surges[port_id][good_id] = until_day


static func clear_consumption_surge(port_id: String, good_id: String) -> void:
	if _cons_surges.has(port_id):
		(_cons_surges[port_id] as Dictionary).erase(good_id)


## True while the surge is active at `day` (`day < 0` means "now" —
## `GameState.day`). Expired surges are dropped on read.
static func consumption_surged(port_id: String, good_id: String,
		day: int = -1) -> bool:
	var today := GameState.day if day < 0 else day
	var port_surges: Dictionary = _cons_surges.get(port_id, {})
	if port_surges.has(good_id):
		if today < int(port_surges[good_id]):
			return true
		clear_consumption_surge(port_id, good_id)
	return false


## The consumption rate the tick actually drains at: the good's rate, ×3
## while a demand event surge covers the port-good (docs/30 §4.5).
static func cons_rate_effective(port_id: String, good_id: String,
		day: int = -1) -> int:
	var rate := cons_rate(good_id)
	if consumption_surged(port_id, good_id, day):
		rate *= EVENT_CONSUMPTION_MULT
	return rate


## Test/new-run seam: drops the whole transient surge table (active event
## instances survive in `GameState.market_events` and are re-applied by
## `ensure_event_overrides`).
static func reset_overrides() -> void:
	_cons_surges = {}


# --- Demand-event rotation (docs/30-* §4.5) ----------------------------------
#
# The scheduler: every template owns one seeded window per `cadence_days`
# (window `w` covers days `w × cadence + 1 … (w + 1) × cadence`). Inside its
# window a template fires on exactly one seeded day at one seeded port,
# *if* the budget (≤ 1 active per nation, ≤ 4 world-wide) still has room —
# a blocked start is skipped, never deferred. Active instances persist in
# `GameState.market_events` as exactly `{template_id, port_id, start_day}`
# (docs/10-* §4.15/§4.13), so runs replay exactly.

## One rotation pass at `day` (default "now"): drop expired instances,
## re-apply the active set's surges (covers a save/load — the table is
## transient), then start today's seeded candidates inside the budget.
## Returns the instances started today (also in `last_started_events`).
static func market_events_tick(day: int = -1) -> Array:
	_last_started_events = []
	var today := GameState.day if day < 0 else int(day)
	_expire_events(today)
	ensure_event_overrides(today)
	var templates: Array = DataLoader.market_events_list.duplicate()
	templates.sort_custom(func(a, b) -> bool:
		return str((a as Dictionary).get("id", "")) \
			< str((b as Dictionary).get("id", "")))
	for tindex in templates.size():
		var template: Dictionary = templates[tindex]
		var cadence := int(template.get("cadence_days", 0))
		if cadence <= 0 or today < 1:
			continue
		@warning_ignore("integer_division")
		var window := (today - 1) / cadence
		var rng := RandomNumberGenerator.new()
		rng.seed = (window + 1) * EVENT_SEED_WINDOW_MULT \
			+ tindex * EVENT_SEED_INDEX_MULT \
			+ hash(str(template.get("id", "")))
		var start_day := window * cadence + rng.randi_range(1, cadence)
		if start_day != today:
			continue
		var ports: Array = DataLoader.ports_list
		if ports.is_empty():
			continue
		var port: Dictionary = ports[rng.randi_range(0, ports.size() - 1)]
		var port_id := str(port.get("id", ""))
		if port_id.is_empty() or not _event_budget_ok(port_id, today):
			continue
		var instance := {
			"template_id": str(template.get("id", "")),
			"port_id": port_id,
			"start_day": today,
		}
		GameState.market_events.append(instance)
		_apply_instance_overrides(instance, template, today)
		_last_started_events.append(instance)
	return _last_started_events


## The instances started by the most recent rotation pass.
static func last_started_events() -> Array:
	return _last_started_events.duplicate()


## Drops instances whose `duration_days` is over (`day >= start + duration`)
## and clears their surges — the normal flow rate resumes (docs/30-* §4.5).
static func _expire_events(today: int) -> void:
	for index in range(GameState.market_events.size() - 1, -1, -1):
		var instance = GameState.market_events[index]
		if not (instance is Dictionary):
			GameState.market_events.remove_at(index)
			continue
		var template: Dictionary = DataLoader.get_market_event(
			str((instance as Dictionary).get("template_id", "")))
		var duration := int(template.get("duration_days", 0))
		var start_day := int((instance as Dictionary).get("start_day", 0))
		if duration <= 0 or today >= start_day + duration:
			if duration > 0:
				for good_id in _override_goods(template):
					clear_consumption_surge(
						str((instance as Dictionary).get("port_id", "")),
						str(good_id))
			GameState.market_events.remove_at(index)


## The template's `rate_override` goods (docs/30 §4.5): a list of good ids
## whose consumption is surged while an instance is active.
static func _override_goods(template: Dictionary) -> Array:
	var overrides: Array = template.get("rate_override", []) \
		if template.get("rate_override", []) is Array else []
	return overrides


## Re-applies the surges of every active instance — the save/load seam (the
## table is transient; the instances are the saved truth).
static func ensure_event_overrides(day: int = -1) -> void:
	var today := GameState.day if day < 0 else int(day)
	for instance in GameState.market_events:
		if not (instance is Dictionary):
			continue
		var template: Dictionary = DataLoader.get_market_event(
			str((instance as Dictionary).get("template_id", "")))
		if template.is_empty():
			continue
		var start_day := int((instance as Dictionary).get("start_day", 0))
		var duration := int(template.get("duration_days", 0))
		if duration <= 0 or today >= start_day + duration:
			continue
		_apply_instance_overrides(instance as Dictionary, template, start_day)


## One instance → its surge entries: consumption ×3 until
## `start_day + duration_days` (docs/30-* §4.5 effect).
static func _apply_instance_overrides(instance: Dictionary,
		template: Dictionary, start_day: int) -> void:
	var port_id := str(instance.get("port_id", ""))
	var until := start_day + int(template.get("duration_days", 0))
	for raw_good in _override_goods(template):
		var good_id := str(raw_good)
		if good_id.is_empty():
			continue
		set_consumption_surge(port_id, good_id, until)


## True when a new instance at `port_id` fits the budget: ≤ 1 active per
## nation (its port's nation), ≤ 4 world-wide (docs/30-* §4.5).
static func _event_budget_ok(port_id: String, today: int) -> bool:
	var nation_id := str(DataLoader.get_port(port_id).get("nation_id", ""))
	var world := 0
	var per_nation := 0
	for instance in GameState.market_events:
		if not (instance is Dictionary):
			continue
		var template: Dictionary = DataLoader.get_market_event(
			str((instance as Dictionary).get("template_id", "")))
		var duration := int(template.get("duration_days", 0))
		var start_day := int((instance as Dictionary).get("start_day", 0))
		if duration <= 0 or today >= start_day + duration:
			continue
		world += 1
		if nation_id == str(DataLoader.get_port(
				str((instance as Dictionary).get("port_id", "")))
			.get("nation_id", "")):
			per_nation += 1
	return world < EVENTS_WORLD_MAX and per_nation < EVENTS_PER_NATION_MAX


## Test/new-run seam: drops the saved instance list too (a fixture building a
## fresh economy wants neither stale instances nor their surges).
static func reset_events() -> void:
	GameState.market_events = []
	_last_started_events = []
	reset_overrides()


## The event telegraphs visible from `port_id` (docs/30-* §4.5: on start a
## tavern rumor row appears in the affected region's ports — the region is
## the affected port's nation). Returns `[{instance, template}]`, template
## order then port id. Shape unchanged by the rate-surge transition.
static func event_telegraphs(port_id: String, day: int = -1) -> Array:
	var today := GameState.day if day < 0 else int(day)
	var nation_id := str(DataLoader.get_port(port_id).get("nation_id", ""))
	var out: Array = []
	for instance in GameState.market_events:
		if not (instance is Dictionary):
			continue
		var affected := str((instance as Dictionary).get("port_id", ""))
		if nation_id.is_empty() or str(DataLoader.get_port(affected)
				.get("nation_id", "")) != nation_id:
			continue
		var template: Dictionary = DataLoader.get_market_event(
			str((instance as Dictionary).get("template_id", "")))
		var duration := int(template.get("duration_days", 0))
		var start_day := int((instance as Dictionary).get("start_day", 0))
		if duration <= 0 or today >= start_day + duration:
			continue
		out.append({"instance": instance, "template": template})
	out.sort_custom(func(a, b) -> bool:
		var ta: Dictionary = (a as Dictionary)["template"]
		var tb: Dictionary = (b as Dictionary)["template"]
		var key_a := "%s|%s" % [str(ta.get("id", "")),
			str(((a as Dictionary)["instance"] as Dictionary).get("port_id", ""))]
		var key_b := "%s|%s" % [str(tb.get("id", "")),
			str(((b as Dictionary)["instance"] as Dictionary).get("port_id", ""))]
		return key_a < key_b
	)
	return out


# --- Phase-5 compatibility shims (deleted at their owners' reworks) ----------
#
# The drift-to-rest names below are retired by the flow economy; they stay
# ONLY so parallel W3/W4 files that still call them keep compiling:
# `effective_rest` is read by the market screen's trend arrow (M reworks the
# screen in W3; docs/80-* re-pins the arrow to the flow direction), and
# `rest_stock` by the NPC-fleet suites (N reworks them in W4). Each returns
# the flow-economy steady-state equivalent of the old read.

## DEPRECATED (Phase-5 name): the flow steady-state target of a port-good —
## capacity for a produced good, 0 for a consumer (docs/30 §4.2 steady
## state). M's market-screen rework replaces this read with the flow
## direction (`market.stock.trend_*`); do not build new logic on it.
static func effective_rest(port_id: String, good_id: String,
		day: int = -1) -> int:
	if is_produced_at(port_id, good_id):
		return capacity_of(port_id, good_id)
	return STOCK_MIN


## DEPRECATED (Phase-5 name): the derived initial stock of a port-good
## (producer at capacity, consumer at 60, unlisted 0 — docs/30 §4.2). N's
## W4 suite rework replaces the drift-era reads; new code wants
## [method initial_stock_of].
static func rest_stock(port_id: String, good_id: String) -> int:
	return initial_stock_of(port_id, good_id)


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
