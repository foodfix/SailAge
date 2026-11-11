"""server.sim.port.economy — the flow-economy stock core (M1).

Python port of ``scripts/port/economy.gd`` (the frozen parity oracle until
the M6 cutover). Normative contract:

  * docs/30-PORTS-AND-TRADE.md §4.2 — the flow economy: listed port-goods
    only (``produces ∪ demands``), tier rates 5/3/2 flag-driven from
    ``goods.json`` (one rate both sides unless the good's ``flow`` object
    overrides), capacities 160/140/120 +20/dev hard-ceiling 200, producers
    fill toward capacity / consumers drain to the 0 floor (unmet demand
    sits), initial stocks derived with no RNG (producers at capacity,
    consumers at 60), the exact per-thousand price factor
    ``clamp(1500 − 5×stock, 500, 2000)`` and the market-direction rule
    (不收购 — a producing port never buys its own produced good).
  * docs/30-PORTS-AND-TRADE.md §4.4 — tranche repricing: the 10-unit walk
    itself is **delegated** to :mod:`server.sim.port.trade` (which carries
    economy.gd's pure walk half — the seam the trade agent flagged); this
    module adds the stock-table read/write around it. Nothing here computes
    a gold price — trade.py owns the price plumbing.
  * docs/30-PORTS-AND-TRADE.md §4.5 — demand events as consumption-rate
    surges: an active instance triples its ``rate_override`` goods'
    consumption for ``duration_days``; the rotation is the seeded scheduler
    (cadence windows, ≤1 active per nation, ≤4 world-wide, a blocked start
    skipped never deferred).
  * docs/90-ARCHITECTURE.md §5.4 — the ``market_stocks`` /
    ``market_events`` GameState blocks, the day-tick listener order (the
    economy step after the daily ledger, before ``day_advanced``; port
    day-advances share the path) and the month-tick ordering pin (the day
    ledger calls this module's day step first, then allegiance.month_tick).

Oracle files: ``scripts/port/economy.gd`` (line-by-line reference) and
``tools/test_economy.gd`` (the pinned §4.2 scenario — its exact numbers are
re-asserted in ``server/tests/test_economy.py``, alongside the golden
360-day rotation schedule captured from the pinned Godot 4.7 toolchain).

State convention (the M1 port rule for autoload-coupled statics): the
GDScript statics read/mutate ``GameState.market_stocks`` (saved),
``GameState.market_events`` (saved) and ``GameState.day``, plus two module
statics — the transient consumption-surge table ``_cons_surges`` (not
saved; instances are the saved truth and are re-applied by
:func:`ensure_event_overrides`) and ``_last_started_events``. Here the
caller owns one :class:`EconomyState` holding exactly those five fields,
and every stateful function takes it and mutates it in place. Data lookups
read an explicit :class:`~server.sim.data.DataStore` where the GDScript
reads the ``DataLoader`` autoload.

The tier-table cache is dropped (declared deviation): the GDScript derives
``_tiers`` lazily from the goods flags with ``refresh_tiers()`` as the
re-derive seam; the derivation here is pure over the injected goods list
(:func:`build_tiers`), so every consumer rebuilds it per call site — same
values, one less cache to invalidate. Synthetic-goods fixtures inject
their own list, which is what the GDScript cache seam existed for.

The development seam: ``economy.gd`` guard-loads ``allegiance.gd`` by path
and answers ``dev_level(port_id)`` from ``Allegiance.dev``, defaulting to 0
while that module is absent. Here the caller injects ``dev_of`` — a
``Callable[[str], int]`` resolving the port's derived dev level (wire it to
``server.sim.port.allegiance.dev`` when the GameState port lands).
``dev_of=None`` (the default) means dev 0 everywhere — exactly the GDScript
guard default.

Events: the pure module never emits. :func:`day_tick` RETURNS the moved
port ids in ``ports.json`` file order and the caller emits
``market_changed`` per port (docs/90 §5.1 signal discipline).

RNG: the only seeded rolls are the rotation's per-template window draws,
through :class:`~server.sim.rng.GodotRng` (bit-exact PCG32) seeded with the
GDScript formula — which salts Godot's own DJB2 ``String.hash`` (see
:func:`godot_string_hash`; Python's salted ``hash`` would break replay
parity). Everything else here is derived arithmetic, no RNG.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Final

from server.sim.data import DataStore
from server.sim.port.trade import factor_for_stock  # re-export (the seam)
from server.sim.port.trade import plan_trade as _walk_plan
from server.sim.rng import GodotRng

__all__ = [
    "DevOf",
    "EconomyState",
    "STOCK_MIN",
    "STOCK_MAX",
    "FACTOR_BASE",
    "FACTOR_PER_STOCK",
    "FACTOR_MIN",
    "FACTOR_MAX",
    "TRANCHE_UNITS",
    "FLOW_RATE_STAPLE",
    "FLOW_RATE_MIDDLE",
    "FLOW_RATE_LUXURY",
    "FLOW_CAPACITY_STAPLE",
    "FLOW_CAPACITY_MIDDLE",
    "FLOW_CAPACITY_LUXURY",
    "CAPACITY_PER_DEV",
    "INITIAL_CONSUMER_STOCK",
    "EVENT_CONSUMPTION_MULT",
    "EVENTS_PER_NATION_MAX",
    "EVENTS_WORLD_MAX",
    "EVENT_SEED_WINDOW_MULT",
    "EVENT_SEED_INDEX_MULT",
    "godot_string_hash",
    "factor_for_stock",
    "build_tiers",
    "tier_of",
    "prod_rate",
    "cons_rate",
    "tier_capacity",
    "dev_rate",
    "capacity_for",
    "capacity_of",
    "build_initial_stocks",
    "initial_stock_for",
    "initial_stock_of",
    "stock_of",
    "set_stock",
    "is_listed_in",
    "is_listed",
    "is_produced_at",
    "port_buys_good",
    "factor_units",
    "day_tick",
    "plan_trade",
    "apply_trade",
    "set_consumption_surge",
    "clear_consumption_surge",
    "consumption_surged",
    "cons_rate_effective",
    "reset_overrides",
    "market_events_tick",
    "last_started_events",
    "ensure_event_overrides",
    "event_telegraphs",
    "reset_events",
]


# --- §4.2 locked constants (economy.gd, verbatim) -----------------------------

#: Stock band, hard-clamped per port-good (docs/30 §4.2).
STOCK_MIN: Final[int] = 0
STOCK_MAX: Final[int] = 200
#: Exact per-thousand price factor: ``1500 − 5 × stock``, clamped to
#: ``[500, 2000]``. The ``2000`` upper bound is a safety net only — the
#: stock range maps the factor into ``[500, 1500]``.
FACTOR_BASE: Final[int] = 1500
FACTOR_PER_STOCK: Final[int] = 5
FACTOR_MIN: Final[int] = 500
FACTOR_MAX: Final[int] = 2000
#: Repricing tranche (docs/30 §4.4): every 10 units form one tranche (the
#: last may be smaller); each transacts at the stock *before* it applies.
TRANCHE_UNITS: Final[int] = 10
#: Flow-economy tier rates (docs/30 §4.2): staples 5/day, middle 3/day,
#: luxuries 2/day — ONE rate serves both production and consumption unless
#: the good's ``flow {prod, cons, capacity}`` override names a side. The
#: tier comes from the ``goods.json`` flags (``staple`` / ``specialty`` /
#: unflagged middle), never from an ordering.
FLOW_RATE_STAPLE: Final[int] = 5
FLOW_RATE_MIDDLE: Final[int] = 3
FLOW_RATE_LUXURY: Final[int] = 2
#: Capacity by tier (docs/30 §4.2): 160/140/120, plus +20 per dev level
#: (§4.9), hard ceiling ``STOCK_MAX`` (200).
FLOW_CAPACITY_STAPLE: Final[int] = 160
FLOW_CAPACITY_MIDDLE: Final[int] = 140
FLOW_CAPACITY_LUXURY: Final[int] = 120
CAPACITY_PER_DEV: Final[int] = 20
#: Initial stocks (new game, docs/30 §4.2): producers at capacity, consumers
#: at 60 (derived, no RNG). Unlisted goods hold no stock at all.
INITIAL_CONSUMER_STOCK: Final[int] = 60
#: Demand events (docs/30 §4.5): an active event triples the consumption
#: rate of its ``rate_override`` goods for ``duration_days``; production,
#: capacities and the price formula are untouched.
EVENT_CONSUMPTION_MULT: Final[int] = 3
#: Demand-event budget (docs/30 §4.5): ≤ 1 active per nation, ≤ 4 world-wide.
EVENTS_PER_NATION_MAX: Final[int] = 1
EVENTS_WORLD_MAX: Final[int] = 4
#: The seeded schedule's formula family: one window per template per
#: ``cadence_days``; the window index and template index salt the Phase-2
#: formula constants, so every run replays the same schedule exactly.
EVENT_SEED_WINDOW_MULT: Final[int] = 1000003
EVENT_SEED_INDEX_MULT: Final[int] = 7919

#: The dev seam: a callable resolving a port id to its derived dev level
#: (``allegiance.dev`` at the GameState port; ``None`` ⇒ dev 0 everywhere,
#: the GDScript guard default while allegiance.gd is absent).
DevOf = Callable[[str], int]


# --- Run state (the GameState blocks + the GDScript module statics) ----------


@dataclass
class EconomyState:
    """The run-scoped economy state (docs/90 §5.4 + economy.gd statics).

    ``market_stocks`` (saved, ``{port_id: {good_id: stock}}``) and
    ``market_events`` (saved, ``[{template_id, port_id, start_day}]``) are
    the two GameState blocks; ``day`` mirrors ``GameState.day`` (the
    rotation's "now"); ``cons_surges`` is the transient surge table and
    ``last_started`` the instances started by the most recent rotation pass
    (both module statics in the GDScript — never saved).
    """

    ## GameState.market_stocks — ``{port_id: {good_id: stock}}`` (saved).
    market_stocks: dict[str, dict[str, int]] = field(default_factory=dict)
    ## GameState.market_events — ``[{template_id, port_id, start_day}]``
    ## (saved; docs/10 §4.15 instance shape).
    market_events: list[dict[str, Any]] = field(default_factory=list)
    ## GameState.day — the "now" the day-parameterless reads fall back to.
    day: int = 1
    ## economy.gd ``_cons_surges`` — ``{port_id: {good_id: until_day}}``
    ## (transient, not saved).
    cons_surges: dict[str, dict[str, int]] = field(default_factory=dict)
    ## economy.gd ``_last_started_events`` — the latest rotation's starts.
    last_started: list[dict[str, Any]] = field(default_factory=list)


def godot_string_hash(text: str) -> int:
    """Godot 4.7 ``String.hash()`` — simple DJB2 over the UTF-32 code points
    (core/string/ustring.cpp): ``hash = 5381; hash = hash × 33 + c`` per
    char, wrapped to uint32. Python's salted ``str`` hash is process-random
    and would break the seeded rotation's replay parity; the event ids are
    ASCII, so code points == the chars Godot iterates."""
    hashv = 5381
    for ch in text:
        hashv = ((hashv << 5) + hashv + ord(ch)) & 0xFFFFFFFF
    return hashv


# --- Tier table (docs/30 §4.2, flag-driven) -----------------------------------


def build_tiers(goods_list: list[Any]) -> dict[str, dict[str, int]]:
    """``{good_id: {tier, prod_rate, cons_rate, base_capacity}}`` derived
    from the goods flags (the GDScript ``refresh_tiers`` / ``tier_table``
    seam, as a pure function — the static cache is dropped)."""
    tiers: dict[str, dict[str, int]] = {}
    for good in goods_list:
        good_id = str(good.get("id", ""))
        if not good_id:
            continue
        tiers[good_id] = _tier_row(good)
    return tiers


def _tier_row(good: dict[str, Any]) -> dict[str, int]:
    """One good's tier row: the tier comes from the flags; the rates and
    capacity come from the tier unless the optional ``flow`` object
    overrides them per key (``prod`` / ``cons`` / ``capacity``)."""
    tier = "middle"
    if good.get("staple", False) is True:
        tier = "staple"
    elif good.get("specialty", False) is True:
        tier = "luxury"
    rate = FLOW_RATE_MIDDLE
    capacity = FLOW_CAPACITY_MIDDLE
    if tier == "staple":
        rate = FLOW_RATE_STAPLE
        capacity = FLOW_CAPACITY_STAPLE
    elif tier == "luxury":
        rate = FLOW_RATE_LUXURY
        capacity = FLOW_CAPACITY_LUXURY
    flow = good.get("flow", {})
    if not isinstance(flow, dict):
        flow = {}
    return {
        "tier": tier,
        "prod_rate": int(flow.get("prod", rate)),
        "cons_rate": int(flow.get("cons", rate)),
        "base_capacity": int(flow.get("capacity", capacity)),
    }


def tier_of(tiers: dict[str, dict[str, int]], good_id: str) -> str:
    """``"staple" | "middle" | "luxury"`` from the goods flags; unknown
    goods rank as middle (the unflagged default)."""
    row = tiers.get(good_id)
    if row is not None:
        return str(row["tier"])
    return "middle"


def prod_rate(tiers: dict[str, dict[str, int]], good_id: str) -> int:
    """Daily production rate of a good: the tier rate or the ``flow.prod``
    override (docs/30 §4.2)."""
    row = tiers.get(good_id)
    if row is not None:
        return max(0, int(row["prod_rate"]))
    return FLOW_RATE_MIDDLE


def cons_rate(tiers: dict[str, dict[str, int]], good_id: str) -> int:
    """Daily consumption rate of a good: the tier rate or the ``flow.cons``
    override (docs/30 §4.2)."""
    row = tiers.get(good_id)
    if row is not None:
        return max(0, int(row["cons_rate"]))
    return FLOW_RATE_MIDDLE


def tier_capacity(tiers: dict[str, dict[str, int]], good_id: str) -> int:
    """Tier-base capacity of a good before the dev bonus (160/140/120 or
    the ``flow.capacity`` override)."""
    row = tiers.get(good_id)
    if row is not None:
        return max(0, int(row["base_capacity"]))
    return FLOW_CAPACITY_MIDDLE


# --- Dev & capacity arithmetic (docs/30 §4.2, pure) ---------------------------


def dev_rate(rate: int, dev: int) -> int:
    """Pure dev-multiplier arithmetic (docs/30 §4.2): integer
    ``rate × (4 + dev) / 4`` — dev 0/1/2/3 → ×1.0/×1.25/×1.5/×1.75 (the
    doc's ×2.0 label at dev 3 approximated by the pinned integer math)."""
    return max(0, rate) * (4 + _clampi(dev, 0, 3)) // 4


def capacity_for(base_capacity: int, dev: int) -> int:
    """Pure capacity arithmetic (docs/30 §4.2): tier base + 20 × dev, hard
    ceiling ``STOCK_MAX``."""
    return min(STOCK_MAX, max(0, base_capacity)
               + CAPACITY_PER_DEV * _clampi(dev, 0, 3))


def capacity_of(store: DataStore, port_id: str, good_id: str,
                dev_of: DevOf | None = None) -> int:
    """The capacity of one port-good at the port's current dev level
    (GDScript ``capacity_of(port_id, good_id)``; the dev read is the
    injected seam)."""
    return capacity_for(
        tier_capacity(build_tiers(store.goods_list), good_id),
        _dev_level(dev_of, port_id))


def _dev_level(dev_of: DevOf | None, port_id: str) -> int:
    """The guard seam (economy.gd ``dev_level``): the injected allegiance
    read, else 0 — never below 0."""
    if dev_of is None:
        return 0
    return max(0, int(dev_of(port_id)))


# --- Stock state (GameState.market_stocks, docs/90 §5.4) ----------------------


def build_initial_stocks(ports: list[Any], goods: list[Any],
                         dev_of: DevOf | None = None) -> dict[str, dict[str, int]]:
    """The derived initial-stock table for a whole run: ``{port_id:
    {good_id: stock}}`` with one row per **listed** port-good (docs/30
    §4.2 listing rule) — producers at capacity, consumers at 60, unlisted
    goods absent. No RNG. ``ports``/``goods`` are the raw lists (the
    GDScript signature), so this is pure and fixture-friendly; dev comes
    from the injected seam (fixtures default 0)."""
    tiers = build_tiers(goods)
    stocks: dict[str, dict[str, int]] = {}
    for port in ports:
        port_id = str(port.get("id", ""))
        if not port_id:
            continue
        dev = _dev_level(dev_of, port_id)
        row: dict[str, int] = {}
        for good in goods:
            good_id = str(good.get("id", ""))
            if not good_id:
                continue
            if not is_listed_in(port, good_id):
                continue
            row[good_id] = initial_stock_for(port, good_id, dev, tiers)
        stocks[port_id] = row
    return stocks


def initial_stock_for(port: dict[str, Any], good_id: str, dev: int,
                      tiers: dict[str, dict[str, int]]) -> int:
    """Pure initial stock of one port-good at dev ``dev`` (docs/30 §4.2): a
    producer starts at capacity, a consumer at 60, an unlisted good holds
    nothing (0)."""
    if good_id in port.get("produces", []):
        return capacity_for(tier_capacity(tiers, good_id), dev)
    if good_id in port.get("demands", []):
        return INITIAL_CONSUMER_STOCK
    return STOCK_MIN


def initial_stock_of(store: DataStore, port_id: str, good_id: str,
                     dev_of: DevOf | None = None) -> int:
    """Derived initial stock via the store (unknown port → no stock: 0)."""
    port = store.get_port(port_id)
    if not port:
        return STOCK_MIN
    return initial_stock_for(port, good_id, _dev_level(dev_of, port_id),
                             build_tiers(store.goods_list))


def stock_of(state: EconomyState, store: DataStore, port_id: str,
             good_id: str, dev_of: DevOf | None = None) -> int:
    """Current stock of one port-good. A missing entry (a hand-edited save,
    a row a trade has not touched yet) reads as the derived initial stock,
    so prices stay on the §4.2 semantics — never a crash, never a stale
    value."""
    port_stocks = state.market_stocks.get(port_id, {})
    if good_id in port_stocks:
        return _clampi(int(port_stocks[good_id]), STOCK_MIN, STOCK_MAX)
    return initial_stock_of(store, port_id, good_id, dev_of)


def set_stock(state: EconomyState, port_id: str, good_id: str,
              value: int) -> None:
    """Writes one stock, hard-clamped to ``[0, 200]`` (docs/30 §4.2)."""
    if port_id not in state.market_stocks:
        state.market_stocks[port_id] = {}
    state.market_stocks[port_id][good_id] = \
        _clampi(value, STOCK_MIN, STOCK_MAX)


# --- Market direction (docs/30 §4.2 listing rule) -----------------------------
#
# Listed(port, good) = good ∈ port.produces ∪ port.demands; a producing
# port NEVER buys its own produced goods (the sell side is disabled there,
# marked 不收购 — the UI is the caller's; this is the helper rows read).


def is_listed_in(port: dict[str, Any], good_id: str) -> bool:
    """True when the port-good is listed (it produces or demands the good)."""
    return good_id in port.get("produces", []) \
        or good_id in port.get("demands", [])


def is_listed(store: DataStore, port_id: str, good_id: str) -> bool:
    """Store-backed form of :func:`is_listed_in`."""
    return is_listed_in(store.get_port(port_id), good_id)


def is_produced_at(store: DataStore, port_id: str, good_id: str) -> bool:
    """True when the port produces the good (★ 特产 row; sell disabled
    there)."""
    return good_id in store.get_port(port_id).get("produces", [])


def port_buys_good(store: DataStore, port_id: str, good_id: str) -> bool:
    """True when the port BUYS the good from a trader (sell side enabled):
    listed but not produced — a producing port never buys its own produced
    goods (docs/30 §4.2 market direction)."""
    port = store.get_port(port_id)
    return is_listed_in(port, good_id) \
        and good_id not in port.get("produces", [])


# --- Price factor (docs/30 §4.2, exact) ---------------------------------------
#
# ``factor_for_stock`` is re-exported from server.sim.port.trade (which
# carries economy.gd's pure walk half — see the module docstring).


def factor_units(state: EconomyState, store: DataStore, port_id: str,
                 good_id: str, dev_of: DevOf | None = None) -> int:
    """THE single source the price plumbing consumes: the factor of the
    port-good's *current* stock (per thousand)."""
    return factor_for_stock(stock_of(state, store, port_id, good_id, dev_of))


# --- Flow tick (docs/30 §4.2) --------------------------------------------------


def day_tick(state: EconomyState, store: DataStore,
             dev_of: DevOf | None = None) -> list[str]:
    """One economy day for every port: each listed port-good moves by its
    real daily flow — producers ``stock += prod_rate × dev_mult`` clamped
    at capacity, consumers ``stock −= cons_rate × dev_mult`` floored at 0
    (unmet demand sits). Expired event surges are dropped. Returns the ids
    of ports whose stock actually moved, in ``ports.json`` file order —
    the caller emits ``market_changed`` per port (the pure module never
    emits; docs/90 §5.1).

    Runs once per day tick — after the daily ledger, before the
    ``day_advanced`` listeners (docs/20 §4.3; docs/90 §5.4) — and on port
    day-advances alike (they share the same tick path). The event rotation
    runs at the top of the economy step — expiries first, then today's
    seeded starts — so the flow below already carries the day's effective
    consumption rates (docs/30 §4.5)."""
    market_events_tick(state, store)
    tiers = build_tiers(store.goods_list)
    moved: list[str] = []
    for port in store.ports_list:
        port_id = str(port.get("id", ""))
        port_stocks = state.market_stocks.get(port_id, {})
        if not port_stocks:
            continue
        dev = _dev_level(dev_of, port_id)
        produces: list[Any] = port.get("produces", [])
        port_moved = False
        for good_id in port_stocks:
            gid = str(good_id)
            stock = stock_of(state, store, port_id, gid, dev_of)
            flowed = _flow_step(tiers, produces, state, store, port_id, gid,
                                stock, dev)
            if flowed != stock:
                set_stock(state, port_id, gid, flowed)
                port_moved = True
        if port_moved:
            moved.append(port_id)
    return moved


def _flow_step(tiers: dict[str, dict[str, int]], produces: list[Any],
               state: EconomyState, store: DataStore, port_id: str,
               good_id: str, stock: int, dev: int) -> int:
    """One §4.2 flow step for one port-good: the produced side fills toward
    capacity, everything else (the demanded side — produces ∩ demands = ∅)
    drains toward the 0 floor."""
    if good_id in produces:
        rate = dev_rate(prod_rate(tiers, good_id), dev)
        return min(capacity_for(tier_capacity(tiers, good_id), dev),
                   stock + max(rate, 0))
    drain = dev_rate(cons_rate_effective(state, store, port_id, good_id,
                                         tiers=tiers), dev)
    return max(STOCK_MIN, stock - max(drain, 0))


# --- Demand-event consumption surges (docs/30 §4.5) ---------------------------
#
# An event is a temporary RATE OVERRIDE: while active, each overridden
# good's consumption rate is ×3 (``EVENT_CONSUMPTION_MULT``) — production,
# capacities and the price formula are untouched. The ROTATION (scheduling,
# budgets, telegraphs) keeps its Phase-5 shape.


def set_consumption_surge(state: EconomyState, port_id: str, good_id: str,
                          until_day: int) -> None:
    """Surges ``good_id``'s consumption at ``port_id`` until ``until_day``
    (exclusive)."""
    if port_id not in state.cons_surges:
        state.cons_surges[port_id] = {}
    state.cons_surges[port_id][good_id] = until_day


def clear_consumption_surge(state: EconomyState, port_id: str,
                            good_id: str) -> None:
    """Drops one surge entry."""
    if port_id in state.cons_surges:
        state.cons_surges[port_id].pop(good_id, None)


def consumption_surged(state: EconomyState, port_id: str, good_id: str,
                       day: int | None = None) -> bool:
    """True while the surge is active at ``day`` (``None`` means "now" —
    ``state.day``). Expired surges are dropped on read."""
    today = state.day if day is None else day
    port_surges = state.cons_surges.get(port_id, {})
    if good_id in port_surges:
        if today < int(port_surges[good_id]):
            return True
        clear_consumption_surge(state, port_id, good_id)
    return False


def cons_rate_effective(state: EconomyState, store: DataStore, port_id: str,
                        good_id: str, day: int | None = None,
                        tiers: dict[str, dict[str, int]] | None = None) -> int:
    """The consumption rate the tick actually drains at: the good's rate,
    ×3 while a demand event surge covers the port-good (docs/30 §4.5)."""
    table = tiers if tiers is not None else build_tiers(store.goods_list)
    rate = cons_rate(table, good_id)
    if consumption_surged(state, port_id, good_id, day):
        rate *= EVENT_CONSUMPTION_MULT
    return rate


def reset_overrides(state: EconomyState) -> None:
    """Test/new-run seam: drops the whole transient surge table (active
    event instances survive in ``state.market_events`` and are re-applied
    by :func:`ensure_event_overrides`)."""
    state.cons_surges = {}


# --- Demand-event rotation (docs/30 §4.5) --------------------------------------
#
# The scheduler: every template owns one seeded window per ``cadence_days``
# (window ``w`` covers days ``w × cadence + 1 … (w + 1) × cadence``). Inside
# its window a template fires on exactly one seeded day at one seeded port,
# *if* the budget (≤ 1 active per nation, ≤ 4 world-wide) still has room —
# a blocked start is skipped, never deferred. Active instances persist in
# ``state.market_events`` as exactly ``{template_id, port_id, start_day}``
# (docs/10 §4.15/§4.13), so runs replay exactly.


def market_events_tick(state: EconomyState, store: DataStore,
                       day: int | None = None) -> list[dict[str, Any]]:
    """One rotation pass at ``day`` (default "now"): drop expired
    instances, re-apply the active set's surges (covers a save/load — the
    table is transient), then start today's seeded candidates inside the
    budget. Returns the instances started today (also in
    ``state.last_started``)."""
    state.last_started = []
    today = state.day if day is None else int(day)
    _expire_events(state, store, today)
    ensure_event_overrides(state, store, today)
    templates = sorted(store.market_events_list,
                       key=lambda t: str(t.get("id", "")))
    for tindex, template in enumerate(templates):
        cadence = int(template.get("cadence_days", 0))
        if cadence <= 0 or today < 1:
            continue
        window = (today - 1) // cadence
        rng = GodotRng(seed=(window + 1) * EVENT_SEED_WINDOW_MULT
                       + tindex * EVENT_SEED_INDEX_MULT
                       + godot_string_hash(str(template.get("id", ""))))
        start_day = window * cadence + rng.randi_range(1, cadence)
        if start_day != today:
            continue
        ports = store.ports_list
        if not ports:
            continue
        port = ports[rng.randi_range(0, len(ports) - 1)]
        port_id = str(port.get("id", ""))
        if not port_id or not _event_budget_ok(state, store, port_id, today):
            continue
        instance = {
            "template_id": str(template.get("id", "")),
            "port_id": port_id,
            "start_day": today,
        }
        state.market_events.append(instance)
        _apply_instance_overrides(state, instance, template, today)
        state.last_started.append(instance)
    return state.last_started


def last_started_events(state: EconomyState) -> list[dict[str, Any]]:
    """The instances started by the most recent rotation pass (a shallow
    copy, like the GDScript ``duplicate()``)."""
    return list(state.last_started)


def _expire_events(state: EconomyState, store: DataStore, today: int) -> None:
    """Drops instances whose ``duration_days`` is over
    (``day >= start + duration``) and clears their surges — the normal flow
    rate resumes (docs/30 §4.5)."""
    for index in range(len(state.market_events) - 1, -1, -1):
        instance = state.market_events[index]
        if not isinstance(instance, dict):
            state.market_events.pop(index)
            continue
        template = store.get_market_event(
            str(instance.get("template_id", "")))
        duration = int(template.get("duration_days", 0))
        start_day = int(instance.get("start_day", 0))
        if duration <= 0 or today >= start_day + duration:
            if duration > 0:
                for good_id in _override_goods(template):
                    clear_consumption_surge(
                        state, str(instance.get("port_id", "")),
                        str(good_id))
            state.market_events.pop(index)


def _override_goods(template: dict[str, Any]) -> list[Any]:
    """The template's ``rate_override`` goods (docs/30 §4.5): a list of
    good ids whose consumption is surged while an instance is active."""
    overrides = template.get("rate_override", [])
    return overrides if isinstance(overrides, list) else []


def ensure_event_overrides(state: EconomyState, store: DataStore,
                           day: int | None = None) -> None:
    """Re-applies the surges of every active instance — the save/load seam
    (the table is transient; the instances are the saved truth)."""
    today = state.day if day is None else int(day)
    for instance in state.market_events:
        if not isinstance(instance, dict):
            continue
        template = store.get_market_event(
            str(instance.get("template_id", "")))
        if not template:
            continue
        start_day = int(instance.get("start_day", 0))
        duration = int(template.get("duration_days", 0))
        if duration <= 0 or today >= start_day + duration:
            continue
        _apply_instance_overrides(state, instance, template, start_day)


def _apply_instance_overrides(state: EconomyState, instance: dict[str, Any],
                              template: dict[str, Any],
                              start_day: int) -> None:
    """One instance → its surge entries: consumption ×3 until
    ``start_day + duration_days`` (docs/30 §4.5 effect)."""
    port_id = str(instance.get("port_id", ""))
    until = start_day + int(template.get("duration_days", 0))
    for raw_good in _override_goods(template):
        good_id = str(raw_good)
        if not good_id:
            continue
        set_consumption_surge(state, port_id, good_id, until)


def _event_budget_ok(state: EconomyState, store: DataStore, port_id: str,
                     today: int) -> bool:
    """True when a new instance at ``port_id`` fits the budget: ≤ 1 active
    per nation (its port's nation), ≤ 4 world-wide (docs/30 §4.5)."""
    nation_id = str(store.get_port(port_id).get("nation_id", ""))
    world = 0
    per_nation = 0
    for instance in state.market_events:
        if not isinstance(instance, dict):
            continue
        template = store.get_market_event(
            str(instance.get("template_id", "")))
        duration = int(template.get("duration_days", 0))
        start_day = int(instance.get("start_day", 0))
        if duration <= 0 or today >= start_day + duration:
            continue
        world += 1
        other = store.get_port(str(instance.get("port_id", "")))
        if nation_id == str(other.get("nation_id", "")):
            per_nation += 1
    return world < EVENTS_WORLD_MAX and per_nation < EVENTS_PER_NATION_MAX


def reset_events(state: EconomyState) -> None:
    """Test/new-run seam: drops the saved instance list too (a fixture
    building a fresh economy wants neither stale instances nor their
    surges)."""
    state.market_events = []
    state.last_started = []
    reset_overrides(state)


def event_telegraphs(state: EconomyState, store: DataStore, port_id: str,
                     day: int | None = None) -> list[dict[str, Any]]:
    """The event telegraphs visible from ``port_id`` (docs/30 §4.5: on
    start a tavern rumor row appears in the affected region's ports — the
    region is the affected port's nation). Returns
    ``[{instance, template}]``, template id then port id order."""
    today = state.day if day is None else int(day)
    nation_id = str(store.get_port(port_id).get("nation_id", ""))
    out: list[dict[str, Any]] = []
    for instance in state.market_events:
        if not isinstance(instance, dict):
            continue
        affected = str(instance.get("port_id", ""))
        if not nation_id or str(store.get_port(affected)
                                .get("nation_id", "")) != nation_id:
            continue
        template = store.get_market_event(
            str(instance.get("template_id", "")))
        duration = int(template.get("duration_days", 0))
        start_day = int(instance.get("start_day", 0))
        if duration <= 0 or today >= start_day + duration:
            continue
        out.append({"instance": instance, "template": template})
    out.sort(key=lambda row: "%s|%s" % (
        str(row["template"].get("id", "")),
        str(row["instance"].get("port_id", ""))))
    return out


# --- Tranche repricing (docs/30 §4.4) ------------------------------------------
#
# The walk itself is trade.py's (economy.gd's pure walk half lives there —
# the flagged seam); these two keep the GDScript Economy signatures, which
# read/write the stock table around the injected walk. ``qty_signed > 0``
# is a BUY (stock falls, price rises per tranche); ``qty_signed < 0`` is a
# SELL (stock rises, price falls). Each tranche transacts at the stock
# *before* it applies; a walk larger than the range parks at the bound and
# keeps transacting there — continuously, no clamp jump. The caller prices
# each tranche and sums the exact integer total (trade.walk_total); this
# module only walks and books stock.


def plan_trade(state: EconomyState, store: DataStore, port_id: str,
               good_id: str, qty_signed: int,
               dev_of: DevOf | None = None) -> list[dict[str, int]]:
    """The pure walk: ``[{"units", "stock_before", "factor_units"}, …]``,
    one entry per tranche, for ``qty_signed`` units at the port-good's
    current stock. Books nothing. Delegates to
    :func:`server.sim.port.trade.plan_trade`."""
    stock = stock_of(state, store, port_id, good_id, dev_of)
    return _walk_plan(stock, qty_signed)


def apply_trade(state: EconomyState, store: DataStore, port_id: str,
                good_id: str, qty_signed: int,
                dev_of: DevOf | None = None) -> list[dict[str, int]]:
    """:func:`plan_trade` plus booking: the port-good's stock lands where
    the walk leaves it. Returns the same walk. Pricing and the
    ``market_changed`` emission stay with the caller (docs/30 §4.2
    ownership, docs/90 §5.1)."""
    stock = stock_of(state, store, port_id, good_id, dev_of)
    walk = _walk_plan(stock, qty_signed)
    if not walk:
        return []
    last = walk[-1]
    direction = -1 if qty_signed > 0 else 1  # buy drains, sell fills
    final_stock = _clampi(
        int(last["stock_before"]) + direction * int(last["units"]),
        STOCK_MIN, STOCK_MAX)
    set_stock(state, port_id, good_id, final_stock)
    return walk


# --- Helpers --------------------------------------------------------------------


def _clampi(value: int, low: int, high: int) -> int:
    """GDScript ``clampi``."""
    return max(low, min(value, high))
