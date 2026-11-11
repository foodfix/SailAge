"""server.sim.port.trade — the trade engine (M1).

Python port of ``scripts/port/trade_engine.gd`` (the frozen parity oracle
until the M6 cutover) plus the *pure walk half* of ``scripts/port/economy.gd``
(``factor_for_stock`` / ``plan_trade`` / ``apply_trade`` — the tranche
repricing is this module's §4.4 contract; the stock table, the flow tick and
the demand-event rotation stay with the economy module).

Normative sources:
  * docs/30-PORTS-AND-TRADE.md §4.2 — stock economy & price formulas (the
    exact per-thousand fixed point: factor ``clamp(1500 − 5×stock, 500,
    2000)``, the ``[0.5, 2.0]`` band on ``factor × discount``, the ``8/10``
    sell margin, the Phase-3 title bonus, ``max(1, …)``, every price floored
    exactly once on the full product; integer division throughout).
  * docs/30-PORTS-AND-TRADE.md §4.4 — tranche repricing (10-unit tranches at
    the stock *before* each tranche, the exact ``Σ price_t × units_t`` walk
    total, read-only ``buy_cost``/``sell_gain`` sums) and the player quantity
    maths (buy max = the full tranche walk the purse can pay — tariff
    included — and the hold can store; sell max = held).
  * docs/30-PORTS-AND-TRADE.md §4.3 — investment (500g chunk, 1%/chunk,
    10% cap; the §4.9 gates stay with the allegiance module).
  * docs/30-PORTS-AND-TRADE.md §4.10 — the tariff composes AFTER all price
    math on the transaction totals; the player-only negotiation discount
    ``min(5, floor(negotiation/10))`` percentage points.
  * docs/50-CHARACTER-AND-PROGRESSION.md §4.3 — ``floor(base_price × 0.7)``
    profit basis; docs/30 §4.2 — the appraisal-gated market arrows and the
    session-transient price memory.

Purity contract (M1): **pure functions over injected data/state** — no
GameState, no module state, no RNG (price math is deterministic). Content
lookups (ports, goods, skill gates) read :mod:`server.sim.data` exactly where
the GDScript reads ``DataLoader``; every mutable run value the GDScript read
off autoloads (stock, invested gold, purse, hold space, held quantity,
tariff rate, skills, the price-memory dict) is an injected parameter. The
tariff *rate* and permit resolution are allegiance-module territory and
arrive here as the already-resolved ``tariff_mille`` rate (0 / 500 / 2000
after permits, docs/30 §4.10) — the same seam the GDScript's
``AllegianceLib.tariff_mille`` call sits behind.

Entry points ported (GDScript name → this module; signatures reshaped to
inject the state the autoloads held):
  * ``factor`` / ``Economy.factor_for_stock`` → ``factor`` / ``factor_for_stock``
  * ``investment_discount`` / ``_discount_units`` → ``investment_discount`` /
    ``discount_units``
  * ``clamped_factor`` / ``_combined_units`` → ``clamped_factor`` /
    ``combined_units``
  * ``buy_price`` / ``sell_price`` / ``title_units`` → same names
    (``title_units`` becomes ``title_units_from_bonus``; the Fame read is the
    caller's) / ``band_units`` / ``price_from_units`` verbatim
  * ``Economy.plan_trade`` / ``apply_trade`` → ``plan_trade`` / ``apply_trade``
  * ``buy_max`` / ``sell_max`` → ``buy_max`` (purse/capacity injected) /
    ``sell_max`` (held injected)
  * ``buy_cost`` / ``sell_gain`` (the §4.4 read-only walk sums)
  * ``buy`` / ``sell`` → the all-or-nothing validation + exact §4.4/§4.10
    totals as pure :class:`BuyResult` / :class:`SellResult` values
  * ``invested`` / ``can_invest`` / ``investment_percent`` / ``_invested_chunks``
  * ``supplies_price`` / ``supplies_buy_max``
  * ``_tranche_price`` / ``_walk_total`` / ``_taxed_total`` / ``_base_price``
  * ``_profit_basis`` / ``per_unit_profit`` / ``sale_profit`` /
    ``sale_profit_total``
  * ``goods_rows`` / ``is_listed`` / ``port_buys_good``
  * ``tax_mille`` / ``tariff_discount_points`` / ``tax_amount``
  * ``_gate_threshold`` / ``profit_arrows_unlocked`` / ``memory_arrows_unlocked``
  * ``memory_capacity`` / ``_memory_record`` / ``price_memory_entry`` /
    ``price_memory`` / ``memory_other_port_entry`` (the statics become an
    injected ``{memory, order}`` pair — no module state)
  * ``profit_arrow`` / ``memory_arrow``

Deferred (NOT ported here, with the GDScript entry point):
  * ``invest`` / ``buy_supplies`` — GameState/ledger/fleet mutations plus the
    §4.1b port-hours charge; the caller applies ``can_invest`` /
    ``supplies_buy_max`` outcomes.
  * The state application of ``buy`` / ``sell``: fleet insert/removal
    (``FleetLib.add_goods`` / ``remove_goods``), the gold mutation, the tax
    crediting (``AllegianceLib.credit_tax``), the §4.3 XP + §4.6 reputation
    booking (``CharacterLib.add_profit_xp`` / ``add_profit_reputation``),
    ``EventBus.market_changed(port_id)`` and the §4.1b hour charge — the
    caller applies the returned result's deltas.
  * ``SailingSimLib.facility_open`` gates (§4.1b closed rule) — sailing-sim
    wall-clock state.
  * ``hold_used`` / ``hold_capacity`` / ``FleetLib.held`` reads — fleet module.
  * ``profit_by_nation`` — the Character-owned §4.6 accumulator.
  * ``skill_value``'s autoload guard chain — the Skills module seam; callers
    inject the effective skill values.
  * The economy module proper: the flow tick (``Economy.day_tick``), stock
    state, dev rates, and the demand-event rotation (``market_events_tick``).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Final

from server.sim.data import data

# --- §4.2 price factors (docs/30 §4.2; trade_engine.gd) ---------------------

#: Locked ``0.8`` sell-side margin: arbitrage inside one port is always a
#: loss. Exact fraction for the integer maths in :func:`price_from_units`.
SELL_MARGIN_NUM: Final[int] = 8
SELL_MARGIN_DEN: Final[int] = 10

#: Price band ``[0.5×, 2×]`` applied to ``factor × investment_discount``
#: **before** the price is computed (docs/30 §4.2 last bullet).
BAND_MIN: Final[float] = 0.5
BAND_MAX: Final[float] = 2.0
#: The same bounds in per-thousand units, for the integer paths.
BAND_MIN_UNITS: Final[int] = 500
BAND_MAX_UNITS: Final[int] = 2000

#: Fixed-point scale: factors and discounts are stored per thousand.
UNITS: Final[int] = 1000
#: Every price is at least 1g (docs/30 §4.2 ``max(1, …)``).
MIN_PRICE: Final[int] = 1

# --- Stock band + tranche walk (economy.gd's pure half, carried here) -------

#: Stock band, hard-clamped per port-good (docs/30 §4.2).
STOCK_MIN: Final[int] = 0
STOCK_MAX: Final[int] = 200
#: Exact per-thousand price factor: ``1500 − 5 × stock``, clamped to
#: ``[500, 2000]``. The ``2000`` upper bound is a safety net only — the stock
#: range maps the factor into ``[500, 1500]``.
FACTOR_BASE: Final[int] = 1500
FACTOR_PER_STOCK: Final[int] = 5
FACTOR_MIN: Final[int] = 500
FACTOR_MAX: Final[int] = 2000
#: Repricing tranche (docs/30 §4.4): every 10 units form one tranche (the
#: last may be smaller); each transacts at the stock *before* it applies.
TRANCHE_UNITS: Final[int] = 10

# --- §4.3 investment ---------------------------------------------------------

#: One click invests this many gold (locked chunk).
INVEST_CHUNK: Final[int] = 500
#: The permanent cap: 10 chunks = 5,000g = −10%.
INVEST_CAP_CHUNKS: Final[int] = 10
INVEST_CAP_GOLD: Final[int] = INVEST_CHUNK * INVEST_CAP_CHUNKS
DISCOUNT_CAP: Final[float] = 0.10
#: 1% expressed in per-thousand units (the fixed-point scale used below).
DISCOUNT_PER_MILLE: Final[int] = 10

# --- §4.3 profit XP / §4.6 reputation (docs/50 §4.3) -------------------------

#: Per-unit profit uses ``floor(base_price × 0.7)`` as the cost basis — the
#: same expression ``Character.add_profit_xp()`` carries, so the XP and the
#: reputation award always agree.
PROFIT_BASIS_FACTOR: Final[float] = 0.7

#: The two supply kinds (docs/20 §4.10); they are not trade goods and never
#: appear in ``goods.json``.
SUPPLY_KINDS: Final[tuple[str, ...]] = ("provisions", "water")
#: Fixed supply prices (docs/20 §4.10) — owned by the sailing sim in the
#: Godot tree (``SailingSimLib.PROVISIONS_PRICE`` / ``WATER_PRICE``); the
#: locked 2g / 1g values, exempt from **all** factors.
PROVISIONS_PRICE: Final[int] = 2
WATER_PRICE: Final[int] = 1

# --- Phase 8 player skills (docs/30 §4.2, §4.10; docs/50 §4.3.1) -------------

#: §4.3.5 gate fallbacks when ``data/skill_gates.json`` lacks the row
#: (``market.profit_arrows`` / ``market.other_port_memory``; docs/50 §4.3.1).
APPRAISAL_ARROW_GATE: Final[int] = 30
APPRAISAL_MEMORY_GATE: Final[int] = 60

# --- §4.10 negotiation tariff discount (Phase 8, player-only) ----------------

#: The locked −5-point cap: ``min(5, floor(negotiation / 10))`` percentage
#: points (docs/30 §4.10).
TARIFF_DISCOUNT_MAX_POINTS: Final[int] = 5
#: One percentage point in the :data:`TARIFF_SCALE` basis (100 of 10,000).
TARIFF_POINT_MILLE: Final[int] = 100
#: The C-contract tariff basis: the rate rides as ``total × mille / 10,000``
#: (docs/30 §4.10; ``allegiance.gd`` owns the same constant — the rate rule
#: 0 / 500 / 2000 after permits lands with the allegiance module).
TARIFF_SCALE: Final[int] = 10000


# --- The §4.2 price plumbing -------------------------------------------------


def factor_for_stock(stock: int) -> int:
    """The pure §4.2 factor formula, per thousand:
    ``clamp(1500 − 5 × stock, 500, 2000)`` (700 / 1300 / 1000 exactly at the
    160 / 40 / 100 reference stocks). Carried from ``economy.gd``."""
    value = FACTOR_BASE - FACTOR_PER_STOCK * stock
    if value < FACTOR_MIN:
        return FACTOR_MIN
    if value > FACTOR_MAX:
        return FACTOR_MAX
    return value


def factor(port_id: str, good_id: str, stock: int) -> float:
    """The current factor as a float (``factor_units / 1000``): 0.7 / 1.3 /
    1.0 at the 160 / 40 / 100 stocks (docs/30 §4.2). ``stock`` is injected —
    an unknown port-good reads as stock-less (0 → the drained extreme 1.5),
    exactly the GDScript flow-economy semantic."""
    return factor_for_stock(stock) / UNITS


def discount_units(invested_gold: int) -> int:
    """``1 − min(0.10, invested / 500 × 0.01)`` in per-thousand units.
    Integer maths: ``invested × 10 / 500`` is the discount in per-mille, so
    1,500g → 30 → 0.970."""
    per_mille = max(0, invested_gold) * DISCOUNT_PER_MILLE // INVEST_CHUNK
    return UNITS - min(int(round(DISCOUNT_CAP * UNITS)), per_mille)


def investment_discount(invested_gold: int) -> float:
    """The permanent per-port discount as a float (``discount_units /
    1000``) — 1.0 uninvested, 0.90 at the 5,000g cap (docs/30 §4.3)."""
    return discount_units(invested_gold) / UNITS


def combined_units(stock: int, invested_gold: int) -> int:
    """``factor × discount``, band-clamped to ``[0.5, 2.0]``, in per-thousand
    units (docs/30 §4.2)."""
    raw = (factor_for_stock(stock) * discount_units(invested_gold)) // UNITS
    return max(BAND_MIN_UNITS, min(BAND_MAX_UNITS, raw))


def clamped_factor(stock: int, invested_gold: int = 0) -> float:
    """``factor × investment_discount`` as a float, clamped to the locked
    ``[0.5, 2.0]`` band before it is used (docs/30 §4.2)."""
    return combined_units(stock, invested_gold) / UNITS


def title_units_from_bonus(bonus: float) -> int:
    """The Phase-3 sell-side ``title_bonus`` in per-thousand units: ``1100``
    at baron and above, ``1050`` at knight, ``1000`` otherwise (``70-*``
    §4.9.2). ``bonus`` is the Fame read (1.0 / 1.05 / 1.10) — the caller
    resolves the player's title at the **port's own nation**; a separate
    multiplier after the band clamp, sell-side only."""
    return int(round(bonus * UNITS))


def band_units(factor_value: float, discount_value: float) -> int:
    """The band clamp on an arbitrary ``factor × discount`` product, in
    per-thousand units. Exposed so the ``[0.5, 2.0]`` rule is testable in
    isolation: the shipped data never produces a factor below 0.7, so the
    lower clamp is only reachable through a synthetic factor (0.4 → 0.5)."""
    combined = max(BAND_MIN, min(BAND_MAX, factor_value * discount_value))
    return int(round(combined * UNITS))


def price_from_units(base_price: int, combined_units: int, sell_side: bool,
                     title: int = UNITS) -> int:
    """One price from a base and an already-clamped ``combined`` value in
    per-thousand units (buy when ``sell_side`` is false). Floors the full
    product exactly once (docs/30 §4.2): buy
    ``max(1, (base × combined) / 1000)``, sell
    ``max(1, (base × combined × 8 × title) / (1000 × 10 × 1000))``.
    ``title`` is the Phase-3 sell-side ``title_bonus`` in per-thousand units
    and is ignored on the buy side."""
    base = max(base_price, 0)
    units = max(BAND_MIN_UNITS, min(BAND_MAX_UNITS, combined_units))
    numerator = base * units
    denominator = UNITS
    if sell_side:
        numerator *= SELL_MARGIN_NUM
        denominator *= SELL_MARGIN_DEN
        numerator *= max(title, 0)
        denominator *= UNITS
    return max(MIN_PRICE, numerator // denominator)


def _base_price(good_id: str) -> int:
    return int(data().get_good(good_id).get("base_price", 0))


def buy_price(port_id: str, good_id: str, stock: int,
              invested_gold: int = 0) -> int:
    """Buy price, ``max(1, floor(base × factor × discount))`` (docs/30
    §4.2). ``stock`` is the port-good's current stock (0 for an unknown
    port — stock-less reads the drained extreme, 1.5)."""
    return price_from_units(
        _base_price(good_id), combined_units(stock, invested_gold), False)


def sell_price(port_id: str, good_id: str, stock: int,
               invested_gold: int = 0, title_units: int = UNITS) -> int:
    """Sell price, ``max(1, floor(base × factor × 0.8 × discount ×
    title_units))`` (docs/30 §4.2; the Phase-3 multiplier is ``70-*``
    §4.9.2)."""
    return price_from_units(
        _base_price(good_id), combined_units(stock, invested_gold), True,
        title_units)


# --- Tranche repricing (docs/30 §4.4; economy.gd walk half) ------------------


def plan_trade(stock: int, qty_signed: int) -> list[dict[str, int]]:
    """The pure §4.4 walk: ``[{"units", "stock_before", "factor_units"}, …]``,
    one entry per 10-unit tranche (the last may be smaller), for
    ``qty_signed`` units from ``stock``. ``qty_signed > 0`` is a BUY (stock
    falls, price rises per tranche); ``< 0`` is a SELL (stock rises, price
    falls). Each tranche transacts at the stock *before* it applies; a walk
    larger than the band parks at the bound and keeps transacting there —
    continuously, no clamp jump. Books nothing."""
    quantity = abs(qty_signed)
    if quantity <= 0:
        return []
    direction = -1 if qty_signed > 0 else 1  # buy drains, sell fills
    walk: list[dict[str, int]] = []
    current = max(STOCK_MIN, min(STOCK_MAX, stock))
    remaining = quantity
    while remaining > 0:
        units = min(TRANCHE_UNITS, remaining)
        walk.append({
            "units": units,
            "stock_before": current,
            "factor_units": factor_for_stock(current),
        })
        current = max(STOCK_MIN, min(STOCK_MAX, current + direction * units))
        remaining -= units
    return walk


def apply_trade(stock: int, qty_signed: int) -> int:
    """:func:`plan_trade` plus booking (pure form): returns the port-good's
    stock after the walk — where the caller's stock write lands. Pricing and
    the ``market_changed`` emission stay with the caller (docs/30 §4.2
    ownership, docs/90 §5.1)."""
    walk = plan_trade(stock, qty_signed)
    if not walk:
        return max(STOCK_MIN, min(STOCK_MAX, stock))
    last = walk[-1]
    direction = -1 if qty_signed > 0 else 1
    return max(STOCK_MIN, min(
        STOCK_MAX, last["stock_before"] + direction * last["units"]))


def tranche_price(base_price: int, discount_units: int,
                  tranche: dict[str, int], sell_side: bool,
                  title: int) -> int:
    """One tranche's price: the §4.2 price plumbing applied at the tranche's
    stock-before ``factor_units`` (band + discount + title, floored once on
    the full product). Integer only — the §4.4 summed total is exact."""
    combined = max(BAND_MIN_UNITS, min(
        BAND_MAX_UNITS, (tranche["factor_units"] * discount_units) // UNITS))
    return price_from_units(base_price, combined, sell_side, title)


def walk_total(walk: list[dict[str, int]], base_price: int,
               invested_gold: int, sell_side: bool,
               title_units: int = UNITS) -> int:
    """The exact §4.4 transaction total: ``Σ price_t × units_t`` over the
    walk, each tranche floored once on its full product. That summed total is
    what gold, the daily ledger, XP and reputation book (docs/30 §4.4) —
    never a per-tranche recomputation."""
    discount = discount_units(invested_gold)
    total = 0
    for tranche in walk:
        price = tranche_price(base_price, discount, tranche, sell_side,
                              title_units)
        total += price * tranche["units"]
    return total


def buy_cost(port_id: str, good_id: str, qty: int, *, stock: int,
             invested_gold: int = 0) -> int:
    """The exact §4.4 cost of buying ``qty`` (the walked per-tranche sum),
    for the market screen's disabled-button reason — the flat ``price × qty``
    would understate any multi-tranche purchase (docs/30 §4.4 read-only walk
    sums). A pure query."""
    if qty <= 0:
        return 0
    return walk_total(plan_trade(stock, qty), _base_price(good_id),
                      invested_gold, False)


def sell_gain(port_id: str, good_id: str, qty: int, *, stock: int,
              invested_gold: int = 0, title_units: int = UNITS) -> int:
    """The sell-side mirror of :func:`buy_cost` (docs/30 §4.4): the exact
    **gross** walked proceeds of selling ``qty`` — what a sale books before
    the §4.10 tariff comes off. A pure query (no listing/direction/hold
    gates: the screen applies those itself before showing the total), so an
    unpurchasable row still prices."""
    if qty <= 0:
        return 0
    return walk_total(plan_trade(stock, -qty), _base_price(good_id),
                      invested_gold, True, title_units)


# --- Quantity limits (docs/30 §4.4) ------------------------------------------


def taxed_total(total: int, mille: int) -> int:
    """A gross total plus its §4.10 tariff:
    ``total + total × mille / 10,000`` (integer division — the exact
    composition ``tools/sim_trade.py`` mirrors)."""
    return total + total * mille // TARIFF_SCALE


def buy_max(port_id: str, good_id: str, *, stock: int, gold: int,
            hold_free: int, invested_gold: int = 0,
            tariff_mille: int = 0) -> int:
    """The UI's quantity ceiling and the hard limit :func:`buy` enforces: the
    largest quantity whose **full tranche walk** the purse can pay and
    ``hold_free`` can store (docs/30 §4.4). Since per-tranche buy prices only
    rise as stock drains, the walk accumulates full 10-unit tranches while
    affordable and finishes with the affordable remainder of the next
    (partial) tranche.

    The §4.10 tariff rides on the running total (after all price math), so
    the affordability walk compares against ``spent + tax``, not ``spent``;
    the flat-rate remainder solves ``n × price × (scale + mille) ≤
    remaining × scale`` (the tax is linear in the total)."""
    if hold_free <= 0:
        return 0
    walk = plan_trade(stock, hold_free)
    base = _base_price(good_id)
    discount = discount_units(invested_gold)
    mille = max(0, tariff_mille)
    bought = 0
    spent = 0
    paid = 0
    for tranche in walk:
        price = tranche_price(base, discount, tranche, False, UNITS)
        spent += price * tranche["units"]
        taxed = taxed_total(spent, mille)
        if gold >= taxed:
            bought += tranche["units"]
            paid = taxed
        else:
            # Flat-rate remainder against the purse left after the accepted
            # tranches (all non-negative, so // is exact GDScript division).
            bought += max(
                0, (gold - paid) * TARIFF_SCALE
                // (price * (TARIFF_SCALE + mille)))
            break
    return max(0, bought)


def sell_max(held: int) -> int:
    """Held quantity pooled across the fleet — partial sells allowed
    (docs/30 §4.4 sell max = held quantity). ``held`` is the fleet read the
    caller injects."""
    return max(0, held)


# --- Investment (docs/30 §4.3) -----------------------------------------------


def invested(port_investments: dict[str, int], port_id: str) -> int:
    """Gold permanently invested at the port (0 when never invested) — read
    off the injected ``{port_id: gold_total}`` block (save key
    ``port_investments``, docs/90 §5.4)."""
    if not port_id:
        return 0
    return int(port_investments.get(port_id, 0))


def can_invest(*, gold: int, invested_gold: int, protected: bool,
               invest_block_reason: str = "") -> bool:
    """True when another 500g chunk is allowed: the purse can pay, the §4.9
    gates pass (``Allegiance.invest_block_reason`` — injected as the already
    resolved reason; the allegiance module lands separately), and at a
    **protected** port the 5,000g discount-saturation cap is not yet reached
    (contestable ports keep investing past it — the ledger is the flip
    campaign's currency, docs/30 §4.3/§4.9)."""
    if invest_block_reason:
        return False
    if protected and invested_gold >= INVEST_CAP_GOLD:
        return False
    return gold >= INVEST_CHUNK


def _invested_chunks(invested_gold: int) -> int:
    """Whole 500g chunks at the port, capped at the 10-chunk / 5,000g max."""
    return min(INVEST_CAP_CHUNKS, max(0, invested_gold) // INVEST_CHUNK)


def investment_percent(invested_gold: int) -> int:
    """The discount in whole percent (``3`` for 1,500g), for the market
    readout — the readout composes the ``−`` sign (docs/10 §3.3: no signs
    baked into strings). 1% per 500g chunk, capped at 10% (docs/30 §4.3), so
    percent == chunks."""
    return _invested_chunks(invested_gold)


# --- Transactions (the all-or-nothing validation + exact totals) -------------


@dataclass(frozen=True)
class BuyResult:
    """The outcome of :func:`buy` — the GDScript all-or-nothing contract as
    a value: every field is 0/false unless ``ok`` (docs/30 §4.4 "transaction
    errors … change nothing"). The caller applies the deltas: charge
    ``total``, store ``qty`` units, write ``new_stock`` into the stock table,
    record ``marginal_price`` into the price memory, emit
    ``market_changed(port_id)``, advance one hour."""

    ok: bool = False
    qty: int = 0
    cost: int = 0        # the exact §4.4 walked gross
    tax: int = 0         # the §4.10 tariff on the walked total
    total: int = 0       # cost + tax — the out-of-pocket charge
    new_stock: int = 0   # the stock-table write after the walk
    marginal_price: int = 0  # the first tranche's realized buy price


@dataclass(frozen=True)
class SellResult:
    """The outcome of :func:`sell` — the sell-side mirror: the caller pays
    ``net``, removes ``qty`` units, writes ``new_stock``, books the §4.3 XP
    and §4.6 reputation on the **gross** ``proceeds`` (the tax composes
    after that plumbing, docs/30 §4.10), and emits
    ``market_changed(port_id)``."""

    ok: bool = False
    qty: int = 0
    proceeds: int = 0    # the exact §4.4 walked gross
    tax: int = 0         # the §4.10 tariff off the proceeds
    net: int = 0         # proceeds − tax — what gold books
    profit_total: int = 0  # the §4.3/§4.6 profit figure (gross-based)
    new_stock: int = 0   # the stock-table write after the walk
    marginal_price: int = 0  # the first tranche's realized sell price


def buy(port_id: str, good_id: str, qty: int, *, stock: int, gold: int,
        hold_free: int, invested_gold: int = 0,
        tariff_mille: int = 0) -> BuyResult:
    """Buys ``qty`` of a good at the port — the validation gate sequence of
    the GDScript ``TradeEngine.buy``, as a pure query: unknown port/good,
    the §4.4 listing rule, non-positive quantity, the :func:`buy_max`
    ceiling (the tranche-walked purse ceiling **and** pooled hold free
    space), then the purse check against the taxed walked total. An invalid
    quantity, a quantity above :func:`buy_max`, or an unaffordable total
    changes nothing at all (docs/30 §4.4) — a refused trade returns
    ``ok=False`` with every delta zeroed.

    Deferred at this layer: the §4.1b facility-window gate, the fleet
    insert, the gold charge, the price-memory write, the tax crediting,
    ``market_changed`` and the hour advance (see the module docstring)."""
    if not data().get_port(port_id):
        return BuyResult()
    if not data().get_good(good_id):
        return BuyResult()
    # Phase 7 listing rule (docs/30 §4.4): an unlisted port-good has no
    # stock and no rows — it never transacts.
    if not is_listed(port_id, good_id):
        return BuyResult()
    if qty <= 0:
        return BuyResult()
    if qty > buy_max(port_id, good_id, stock=stock, gold=gold,
                     hold_free=hold_free, invested_gold=invested_gold,
                     tariff_mille=tariff_mille):
        return BuyResult()
    # The walk is planned before anything mutates, so a refused trade leaves
    # not even the stock touched (all-or-nothing, docs/30 §4.4).
    walk = plan_trade(stock, qty)
    cost = walk_total(walk, _base_price(good_id), invested_gold, False)
    # docs/30 §4.10: the tariff composes after all price math, on the
    # walked total.
    tax = tax_amount(tariff_mille, cost)
    total = cost + tax
    if gold < total:
        return BuyResult()
    marginal = tranche_price(
        _base_price(good_id), discount_units(invested_gold), walk[0],
        False, UNITS) if walk else 0
    return BuyResult(ok=True, qty=qty, cost=cost, tax=tax, total=total,
                     new_stock=apply_trade(stock, qty),
                     marginal_price=marginal)


def sell(port_id: str, good_id: str, qty: int, *, stock: int, held: int,
         invested_gold: int = 0, tariff_mille: int = 0,
         title_units: int = UNITS) -> SellResult:
    """Sells ``qty`` of a held good at the port — the GDScript
    ``TradeEngine.sell`` validation sequence, pure: unknown port/good, the
    market-direction rule (a producing port never buys its own produced
    good — 不收购, docs/30 §4.2), non-positive or over-held quantity, then
    the exact walked totals. Over-quantity sells fail without changing
    anything.

    The §4.3 XP and §4.6 reputation book the **gross** ``proceeds`` —
    ``profit_total`` carries the exact figure (``max(0, proceeds − qty ×
    basis)``) for the caller's ``Character`` booking; the §4.10 tax composes
    after that plumbing, exactly like on the buy side."""
    if not data().get_port(port_id):
        return SellResult()
    if not data().get_good(good_id):
        return SellResult()
    # Phase 7 market direction + listing rule (docs/30 §4.2/§4.4): a
    # producing port never buys its own produced good (不收购) and unlisted
    # goods have no market at all.
    if not port_buys_good(port_id, good_id):
        return SellResult()
    if qty <= 0 or qty > sell_max(held):
        return SellResult()
    walk = plan_trade(stock, -qty)
    proceeds = walk_total(walk, _base_price(good_id), invested_gold, True,
                          title_units)
    tax = tax_amount(tariff_mille, proceeds)
    marginal = tranche_price(
        _base_price(good_id), discount_units(invested_gold), walk[0],
        True, title_units) if walk else 0
    return SellResult(
        ok=True, qty=qty, proceeds=proceeds, tax=tax, net=proceeds - tax,
        profit_total=sale_profit_total(proceeds, _base_price(good_id), qty),
        new_stock=apply_trade(stock, -qty), marginal_price=marginal)


# --- Supplies (docs/20 §4.10) -----------------------------------------------


def supplies_price(kind: str) -> int:
    """Fixed supply price: provisions 2g, water 1g, exempt from **all**
    factors (produces/demands/investment). 0 for an unknown kind."""
    if kind == "provisions":
        return PROVISIONS_PRICE
    if kind == "water":
        return WATER_PRICE
    return 0


def supplies_buy_max(kind: str, *, gold: int, hold_free: int) -> int:
    """Sell-back is not offered for supplies (docs/20 §4.10), so this is a
    buy ceiling only: ``min(floor(gold / price), hold_free)``."""
    price = supplies_price(kind)
    if price <= 0:
        return 0
    return max(0, min(gold // price, hold_free))


# --- Sale profit & reputation (docs/50 §4.3, §4.6) ---------------------------


def _profit_basis(base_price: int) -> int:
    """The locked §4.3 cost basis in gold: ``floor(base_price × 0.7)`` — a
    metagame approximation, unchanged by dynamic prices."""
    return int(base_price * PROFIT_BASIS_FACTOR)


def per_unit_profit(sell_price_value: int, base_price: int) -> int:
    """docs/50 §4.3: ``max(0, sell_price − floor(base_price × 0.7))`` per
    unit."""
    return max(0, sell_price_value - _profit_basis(base_price))


def sale_profit(sell_price_value: int, base_price: int, qty: int) -> int:
    """Transaction profit at a flat per-unit price, ``qty × per-unit``
    (floored at 0 — never negative). Kept for single-price callers."""
    return max(qty, 0) * per_unit_profit(sell_price_value, base_price)


def sale_profit_total(proceeds: int, base_price: int, qty: int) -> int:
    """Transaction profit of a walked sale, booked on the exact §4.4 summed
    total: ``max(0, proceeds − qty × basis)`` — the same figure the XP award
    and the per-nation reputation book consume (docs/30 §4.4)."""
    return max(0, proceeds - max(qty, 0) * _profit_basis(base_price))


# --- Data-driven market rows (docs/30 §4.4 listing rule, §4.10 tax) ----------


def goods_rows(port_id: str) -> list[dict[str, Any]]:
    """The port's **listed** goods, sorted by ``base_price`` ascending (ties
    by id for a stable order). Phase 7 listing rule (docs/30 §4.4,
    correction 7): a port lists a good iff it produces or demands it —
    unlisted goods have no stock, no rows, and never transact."""
    port = data().get_port(port_id)
    produces = port.get("produces", [])
    demands = port.get("demands", [])
    rows: list[dict[str, Any]] = []
    for good in data().goods_list:
        good_id = str(good.get("id", ""))
        if good_id in produces or good_id in demands:
            rows.append(good)
    rows.sort(key=lambda row: (int(row.get("base_price", 0)),
                               str(row.get("id", ""))))
    return rows


def is_listed(port_id: str, good_id: str) -> bool:
    """True when ``good_id`` is listed at ``port_id`` (``produces ∪
    demands``, docs/30 §4.4): the gate every player buy/sell walks through.
    Unknown pairs no."""
    port = data().get_port(port_id)
    if not port:
        return False
    return good_id in port.get("produces", []) \
        or good_id in port.get("demands", [])


def port_buys_good(port_id: str, good_id: str) -> bool:
    """True when the port would **buy** ``good_id`` from the player: listed
    and not one of its own produces — a producing port never buys its own
    produced goods (docs/30 §4.2 market direction; the screen renders
    不收购)."""
    if not is_listed(port_id, good_id):
        return False
    return good_id not in data().get_port(port_id).get("produces", [])


# --- Tariff (docs/30 §4.10 — composes after all price math) ------------------


def tariff_discount_points(negotiation: int) -> int:
    """The negotiation discount in percentage points,
    ``min(5, floor(negotiation / 10))`` — the −5 cap makes negotiation ≥ 50
    the maximum (docs/30 §4.10)."""
    return min(TARIFF_DISCOUNT_MAX_POINTS, max(0, negotiation) // 10)


def tax_mille(base_tariff_mille: int, negotiation: int = 0) -> int:
    """The player's tariff in the C-contract basis points: the allegiance
    rule's rate (0 / 500 / 2000 after permits — injected; the allegiance
    module lands separately) **minus** the Phase-8 negotiation discount,
    ``min(5, floor(negotiation / 10))`` percentage points, floored at 0
    (docs/30 §4.10 — an aligned 5% reaches 0% at negotiation ≥ 50, a foreign
    20% becomes 15%). **Player-only**: NPC trades use the allegiance rate
    directly and always pay the full rate."""
    base = base_tariff_mille
    if base <= 0:
        return base
    return max(0, base - tariff_discount_points(negotiation)
               * TARIFF_POINT_MILLE)


def tax_amount(mille: int, total: int) -> int:
    """The tax coin on a walked transaction total (``total × mille / 10,000``,
    integer division — the same composition ``tools/sim_trade.py``
    mirrors)."""
    if total <= 0:
        return 0
    return total * mille // TARIFF_SCALE


# --- Player-skill gates (docs/50 §4.3.5; docs/30 §4.2) -----------------------


def _gate_threshold(feature_id: str, doc_default: int) -> int:
    """The §4.3.5 gate threshold for ``feature_id``: the loader's
    ``skill_gates`` table (keyed ``feature_id``) first, else the locked doc
    number."""
    row = data().skill_gates.get(feature_id)
    if isinstance(row, dict) and "threshold" in row:
        return max(0, int(row["threshold"]))
    return doc_default


def profit_arrows_unlocked(appraisal: int) -> bool:
    """§4.2 profit arrows: unlocked at effective appraisal ≥ the
    ``market.profit_arrows`` gate (30)."""
    return appraisal >= _gate_threshold("market.profit_arrows",
                                        APPRAISAL_ARROW_GATE)


def memory_arrows_unlocked(appraisal: int) -> bool:
    """§4.2 other-port memory arrows: unlocked at effective appraisal ≥ the
    ``market.other_port_memory`` gate (60)."""
    return appraisal >= _gate_threshold("market.other_port_memory",
                                        APPRAISAL_MEMORY_GATE)


# --- Price memory (docs/30 §4.2 — session-transient, never saved) ------------
#
# The GDScript module kept the memory in statics; here the caller owns the
# pair (``memory`` keyed ``"port|good"`` → ``{"price", "day"}``, ``order``
# least-recently-recorded first) and this module owns the rules.


def memory_capacity(appraisal: int) -> int:
    """``floor(effective_appraisal / 10)`` entries — appraisal 30 → 3,
    100 → 10 (docs/30 §4.2); below 10 appraisal nothing records at all."""
    return max(0, appraisal) // 10


def _memory_key(port_id: str, good_id: str) -> str:
    return f"{port_id}|{good_id}"


def price_memory_entry(memory: dict[str, dict[str, int]], port_id: str,
                       good_id: str) -> dict[str, int]:
    """The memory entry for a port-good — ``{price, day}``, or ``{}`` when
    unrecorded."""
    entry = memory.get(_memory_key(port_id, good_id))
    return dict(entry) if isinstance(entry, dict) else {}


def price_memory(memory: dict[str, dict[str, int]],
                 order: list[str]) -> dict[str, dict[str, int]]:
    """Read-only copy of the whole memory, least-recently-recorded first —
    the debug/inspection seam."""
    return {key: dict(memory[key]) for key in order if key in memory}


def memory_record(memory: dict[str, dict[str, int]], order: list[str],
                  port_id: str, good_id: str, price: int, day: int,
                  capacity: int) -> None:
    """Records a completed buy's marginal price (docs/30 §4.2): one entry
    per (port, good); a re-buy overwrites and moves the key to newest ("last
    seen"); past :func:`memory_capacity` the oldest entry is evicted first.
    Capacity 0 records nothing. Writes only the injected pair — never a
    save-relevant block."""
    if capacity <= 0:
        return
    key = _memory_key(port_id, good_id)
    if key in memory:
        order.remove(key)
    memory[key] = {"price": max(0, price), "day": max(0, day)}
    order.append(key)
    while len(order) > capacity:
        evicted = order.pop(0)
        memory.pop(evicted, None)


def memory_other_port_entry(memory: dict[str, dict[str, int]],
                            order: list[str], port_id: str,
                            good_id: str) -> dict[str, int]:
    """The most-recent memory entry for ``good_id`` recorded at a port
    **other** than ``port_id`` (``{}`` when none) — the §4.2 other-port
    memory arrow's comparator ("the memory's last-seen price for that good
    at other ports")."""
    for key in reversed(order):
        parts = key.split("|", 1)
        if len(parts) != 2 or parts[0] == port_id:
            continue
        if parts[1] != good_id:
            continue
        entry = memory.get(key)
        return dict(entry) if isinstance(entry, dict) else {}
    return {}


# --- Market arrows (docs/30 §4.2 — appraisal-gated) --------------------------


def profit_arrow(port_id: str, good_id: str, *, stock: int,
                 invested_gold: int = 0, appraisal: int = 0) -> str:
    """The profit arrow of a market row: ``"down"`` when the marginal buy
    price sits below ``base_price`` (cheap producer row — profitable to
    buy), ``"up"`` when the marginal sell price sits above it (dear consumer
    row — profitable to sell), ``""`` otherwise. Below the appraisal ≥ 30
    gate the arrow never renders (``""``, docs/30 §4.2)."""
    if not profit_arrows_unlocked(appraisal):
        return ""
    base = _base_price(good_id)
    if buy_price(port_id, good_id, stock, invested_gold) < base:
        return "down"
    if sell_price(port_id, good_id, stock, invested_gold) > base:
        return "up"
    return ""


def memory_arrow(port_id: str, good_id: str, *, stock: int,
                 invested_gold: int = 0, appraisal: int = 0,
                 memory: dict[str, dict[str, int]] | None = None,
                 order: list[str] | None = None) -> str:
    """The other-port memory arrow of a market row: ``"up"`` when the local
    marginal buy price is above the most-recent remembered price for that
    good at other ports, ``"down"`` when below, ``""`` when the memory holds
    no foreign entry. Below the appraisal ≥ 60 gate only the §4.8 flow-trend
    arrows render (``""``, docs/30 §4.2)."""
    if not memory_arrows_unlocked(appraisal):
        return ""
    entry = memory_other_port_entry(memory or {}, order or [], port_id,
                                    good_id)
    if not entry:
        return ""
    local = buy_price(port_id, good_id, stock, invested_gold)
    remembered = max(0, int(entry.get("price", 0)))
    if local > remembered:
        return "up"
    if local < remembered:
        return "down"
    return ""
