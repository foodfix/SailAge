"""server.tests.test_trade — the trade-engine parity suite (M1).

Port of the guarantee, not the method (AGENTS.md test discipline): the
GDScript harness (``tools/test_trade.gd``, T12 re-baselined for Phase 7)
boots a run and walks the autoloads; here the same pinned contracts are
asserted as pure functions over injected state on the real shipped
``data/`` tree (loaded through :mod:`server.sim.data`).

Pinned contracts (oracle: ``scripts/port/trade_engine.gd`` +
``scripts/port/economy.gd``'s walk half; docs/30-PORTS-AND-TRADE.md §4.2
§4.3 §4.4 §4.10, §5 worked examples):
  * the §5 worked-example prices at the reference stocks (produced 160 /
    demanded 40): Lisbon wine buy 21 / sell 16, London wine buy 39 / sell 31
    (route nets 10g/unit pre-tax), Valencia wine 39, Lisbon wheat 10 / 8;
  * the exact §4.2 plumbing — factor ``clamp(1500 − 5×stock, 500, 2000)``,
    the 1%/500g investment discount capped at 10%, the ``[0.5, 2.0]`` band
    (synthetic factors — no shipped pair reaches the floor), the 0.8 sell
    margin, the Phase-3 title bonus (knight 1.05 / baron 1.10, sell side
    only, port's own nation), ``max(1, …)``;
  * the §4.4 tranche repricing — the 300-unit London sale walking the stock
    ladder to the exact **5,170g** of the doc's table (never the 9,300g flat
    display), parked continuously at the stock-200 bound, the buy-side walk
    2,750g for 100 wine out of rest 160, and the read-only
    ``buy_cost``/``sell_gain`` sums;
  * the §4.4 quantity maths — buy_max walks the FULL tranche ladder against
    purse + tariff (1,000g → 41 wine at aligned 5%, 42 exempt, 220g → 10,
    219g → 9, capacity-limited to the free hold) and sell_max = held;
  * the §4.10 tariff composed after all price math on the totals — 500‰
    in-sphere / 2000‰ foreign × the permit flags (as the injected rate) ×
    the negotiation discount (min(5, n/10) points), the exact
    ``total × mille / 10,000`` coin;
  * the §4.4 listing rule (produces ∪ demands, sorted by base_price) and
    the §4.2 market direction (不收购 — a producer never buys its own good);
  * the §4.2 appraisal-gated arrows and the session-transient price memory
    (capacity floor(appraisal/10), LRU eviction, overwrite-to-newest,
    other-port lookup);
  * the §4.3 investment maths (chunks, caps, the can_invest gate matrix
    with the §4.9 block reason and the protected-port saturation cap
    injected) and the §4.3/§4.6 profit basis (``floor(base × 0.7)``).

Deterministic — no RNG, no Monte Carlo, no engine boots. Every number below
is either the GDScript pin or the closed-form value of the §4.2/§4.4
formulas on shipped data.
"""

from __future__ import annotations

import pytest

from server.sim.data import data
from server.sim.port import trade

# The §4.2 reference stocks: produced rest 160 (dev-0 staple capacity) /
# demanded rest 40 — the stocks the docs/30 §5 worked examples were
# computed at (the §4.2 flow economy moved the trajectory, not the prices).
PRODUCED_REST = 160
DEMANDED_REST = 40

# docs/30 §4.10 rate matrix (allegiance.gd's rule — injected here as the
# already-resolved rate): aligned 5% = 500‰, foreign/unallied 20% = 2000‰,
# a covering permit 0‰.
TARIFF_ALIGNED = 500
TARIFF_FOREIGN = 2000
TARIFF_EXEMPT = 0


# --- §5 worked-example prices on shipped data -------------------------------


def test_worked_example_prices() -> None:
    """docs/30 §5: Lisbon → London wine at the reference stocks."""
    # Lisbon produces wine (stock 160 → factor 0.7), no investment.
    assert trade.factor("lisbon", "wine", PRODUCED_REST) == pytest.approx(0.7)
    assert trade.investment_discount(0) == 1.0
    assert trade.buy_price("lisbon", "wine", PRODUCED_REST) == 21
    assert trade.sell_price("lisbon", "wine", PRODUCED_REST) == 16
    # London demands wine (stock 40 → factor 1.3).
    assert trade.factor("london", "wine", DEMANDED_REST) == pytest.approx(1.3)
    assert trade.buy_price("london", "wine", DEMANDED_REST) == 39
    assert trade.sell_price("london", "wine", DEMANDED_REST) == 31
    # §5 note: the route nets 10g/unit at the pre-tax prices.
    assert (trade.sell_price("london", "wine", DEMANDED_REST)
            - trade.buy_price("lisbon", "wine", PRODUCED_REST)) == 10
    # A demanded good trades at 1.3 (every listed good is produced or
    # demanded — the Phase-5 neutral case is retired by the listing rule):
    # Valencia demands wine and reads like London.
    assert trade.buy_price("valencia", "wine", DEMANDED_REST) == 39


def test_worked_example_modifier_spectrum() -> None:
    """Two more goods × the same ports — the demanded staple and the
    produced staple plus a demanded luxury, covering the modifier spectrum
    on shipped data."""
    # A demanded staple at Lisbon: wheat 8g base → 10 / 8.
    assert trade.buy_price("lisbon", "wheat", DEMANDED_REST) == 10
    assert trade.sell_price("lisbon", "wheat", DEMANDED_REST) == 8
    # A produced staple at Lisbon: salt 12g base → 8 / 6.
    assert trade.buy_price("lisbon", "salt", PRODUCED_REST) == 8
    assert trade.sell_price("lisbon", "salt", PRODUCED_REST) == 6
    # A demanded luxury at Lisbon: spices 150g base → 195 / 156.
    assert trade.buy_price("lisbon", "spices", DEMANDED_REST) == 195
    assert trade.sell_price("lisbon", "spices", DEMANDED_REST) == 156


def test_stock_extremes_and_unknown_port() -> None:
    """The factor band edges over the stock range (tools/test_trade.gd
    `_test_tranche_repricing` band pins) and the stock-less unknown port."""
    # Drained extreme: stock 0 → factor 1.5 — inside the band.
    assert trade.factor_for_stock(0) == 1500
    assert trade.buy_price("lisbon", "wine", 0) == 45
    assert trade.sell_price("lisbon", "wine", 0) == 36  # floor(45 × 0.8)
    # Saturated extreme: stock 200 → factor 0.5, exactly the band floor.
    assert trade.factor_for_stock(200) == 500
    assert trade.buy_price("lisbon", "wine", 200) == 15
    assert trade.sell_price("lisbon", "wine", 200) == 12
    # The pure factor ladder (docs/30 §4.2): 160 → 0.7, 40 → 1.3, 100 → 1.0.
    assert trade.factor_for_stock(160) == 700
    assert trade.factor_for_stock(40) == 1300
    assert trade.factor_for_stock(100) == 1000
    # An unknown port reads as stock-less (no derived row → stock 0 → the
    # drained extreme): wine buy == floor(30 × 1.5) = 45.
    assert trade.buy_price("nowhere", "wine", 0) == 45


# --- §4.2 plumbing: discount, band, min price -------------------------------


def test_investment_discount_units() -> None:
    """1% per 500g chunk, integer per-mille chunking, 10% cap (docs/30
    §4.3; tools/test_trade.gd `_test_factor_and_discount`)."""
    assert trade.discount_units(0) == 1000
    assert trade.discount_units(500) == 990
    assert trade.discount_units(1500) == 970  # the doc's 0.970 example
    assert trade.discount_units(4999) == 901  # 4999×10//500 = 99
    assert trade.discount_units(5000) == 900
    # Capped even far past 5,000g.
    assert trade.discount_units(999999) == 900
    assert trade.investment_discount(999999) == pytest.approx(0.90)


def test_band_clamp_synthetic_factors() -> None:
    """The band is applied to ``factor × discount`` before the price is
    computed (docs/30 §4.2 last bullet; tools/test_trade.gd
    `_test_band_clamp`). No shipped pair reaches the 0.5 floor (the lowest
    is 0.7 × 0.9 = 0.63), so the helper is exercised directly."""
    assert trade.band_units(0.4, 1.0) == 500
    assert trade.price_from_units(30, 500, sell_side=False) == 15
    assert trade.price_from_units(30, 500, sell_side=True) == 12
    assert trade.band_units(4.0, 1.0) == 2000
    assert trade.price_from_units(30, 2000, sell_side=False) == 60
    # The clamp is on the product: 0.7 × 0.5 = 0.35 → 0.5; 1.3 × 2.0 = 2.6 → 2.0.
    assert trade.band_units(0.7, 0.5) == 500
    assert trade.band_units(1.3, 2.0) == 2000
    # Real pairs stay inside the band untouched.
    assert trade.clamped_factor(PRODUCED_REST) == pytest.approx(0.7)
    assert trade.clamped_factor(DEMANDED_REST) == pytest.approx(1.3)
    # Max investment: 0.7 × 0.9 = 0.63, above the floor — the exact §4.2 value.
    assert trade.clamped_factor(PRODUCED_REST, 5000) == pytest.approx(0.63)
    assert trade.band_units(1.5, 0.9) == 1350  # 1.35 stays inside


def test_min_price_floor() -> None:
    """Every price is at least 1g (docs/30 §4.2 ``max(1, …)``)."""
    assert trade.price_from_units(0, 2000, sell_side=False) == 1
    assert trade.price_from_units(1, 500, sell_side=True) == 1


def test_max_investment_price_pins() -> None:
    """Fully-invested Lisbon (5,000g → −10%) at produced rest (docs/30 §4.3;
    tools/test_trade.gd `_test_investment_cap`): floor(30 × 0.7 × 0.9) = 18
    and floor(30 × 0.7 × 0.8 × 0.9) = 15; the drained re-clamp 1.5 × 0.9 =
    1.35 → floor(30 × 1.35) = 40."""
    assert trade.buy_price("lisbon", "wine", PRODUCED_REST, 5000) == 18
    assert trade.sell_price("lisbon", "wine", PRODUCED_REST, 5000) == 15
    assert trade.clamped_factor(0, 5000) == pytest.approx(1.35)
    assert trade.buy_price("lisbon", "wine", 0, 5000) == 40


def test_title_bonus_sell_side_only() -> None:
    """Phase-3 title bonus (``70-*`` §4.9.2): multiplies the **sell** side
    only, at the port's own nation — knight 1.05, baron 1.10, floored once
    with the rest of the product."""
    assert trade.title_units_from_bonus(1.0) == 1000
    assert trade.title_units_from_bonus(1.05) == 1050
    assert trade.title_units_from_bonus(1.10) == 1100
    # Buying ignores the title entirely: the same base/combined prices 39
    # with or without a title in the plumbing.
    assert trade.price_from_units(30, 1300, sell_side=False, title=1100) == 39
    assert (trade.price_from_units(30, 1300, sell_side=False, title=1100)
            == trade.price_from_units(30, 1300, sell_side=False, title=1000)
            == trade.buy_price("london", "wine", DEMANDED_REST))
    # Selling at London rest with a knighthood: floor(30×1.3×0.8×1.05) = 32.
    assert trade.sell_price("london", "wine", DEMANDED_REST, 0, 1050) == 32
    # Baron: floor(30×1.3×0.8×1.10) = 34.
    assert trade.sell_price("london", "wine", DEMANDED_REST, 0, 1100) == 34


# --- §4.4 tranche repricing ---------------------------------------------------


def test_plan_and_apply_walk_shape() -> None:
    """The §4.4 walk: ceil(q/10) tranches of 10 (the last may be smaller),
    each priced at the stock *before* it applies; buying drains, selling
    fills; the walk parks at the stock bound (docs/30 §4.4)."""
    buy_walk = trade.plan_trade(PRODUCED_REST, 30)
    assert buy_walk == [
        {"units": 10, "stock_before": 160, "factor_units": 700},
        {"units": 10, "stock_before": 150, "factor_units": 750},
        {"units": 10, "stock_before": 140, "factor_units": 800},
    ]
    assert trade.apply_trade(PRODUCED_REST, 30) == 130
    sell_walk = trade.plan_trade(DEMANDED_REST, -30)
    assert [t["factor_units"] for t in sell_walk] == [1300, 1250, 1200]
    assert trade.apply_trade(DEMANDED_REST, -30) == 70
    # A partial last tranche: 25 units → 10/10/5.
    partial = trade.plan_trade(PRODUCED_REST, 25)
    assert [t["units"] for t in partial] == [10, 10, 5]
    # Parked at the bound: a walk larger than the range transacts at the
    # bound factor continuously — no clamp jump.
    parked = trade.plan_trade(200, -10)
    assert parked == [{"units": 10, "stock_before": 200, "factor_units": 500}]
    assert trade.apply_trade(200, -10) == 200
    # Zero quantity plans nothing and books nothing.
    assert trade.plan_trade(160, 0) == []
    assert trade.apply_trade(160, 0) == 160


def test_walk_total_300_sale_doc_table() -> None:
    """docs/30 §4.4 worked example: 300 wine sold into London from stock 40
    (base 30, no investment, no title) — 16 distinct prices before the stock
    clamp, then 14 parked tranches at the 500 factor; proceeds exactly
    5,170g, not the 9,300g the flat 31g display would suggest."""
    proceeds = trade.walk_total(trade.plan_trade(40, -300), 30, 0, True)
    assert proceeds == 5170
    # And through the read-only query seam (§4.4 read-only walk sums).
    assert trade.sell_gain("london", "wine", 300, stock=40) == 5170
    # The parked marginal price is 12, reached continuously (13 → 12).
    assert trade.sell_price("london", "wine", 200) == 12
    # The next tranche still transacts at the parked factor 500.
    next_walk = trade.plan_trade(200, -10)
    assert next_walk[0]["factor_units"] == 500


def test_walk_total_buy_100_pin() -> None:
    """tools/test_trade.gd `_test_tranche_repricing`: 100 wine bought at
    Lisbon rest 160 — tranches at stocks 160…70 price 21+22+24+25+27+28+30+
    31+33+34 per 10 units = 2,750; the walk moves the marginal buy price
    21 → 36 and the sell price 16 → 28 (stock 60 → factor 1200)."""
    assert trade.buy_cost("lisbon", "wine", 100, stock=PRODUCED_REST) == 2750
    assert trade.buy_price("lisbon", "wine", 60) == 36
    assert trade.sell_price("lisbon", "wine", 60) == 28
    # Partial-quantity cost: 5 units at the rest price 21 (one partial tranche).
    assert trade.buy_cost("lisbon", "wine", 5, stock=PRODUCED_REST) == 105
    # Zero quantity costs nothing.
    assert trade.buy_cost("lisbon", "wine", 0, stock=PRODUCED_REST) == 0
    assert trade.sell_gain("lisbon", "wine", 0, stock=PRODUCED_REST) == 0


def test_walk_total_sell_100_london_pin() -> None:
    """tools/test_trade.gd `_test_tranche_repricing`: 100 sold at London
    rest 40 — 31+30+28+27+26+25+24+22+21+20 per 10 = 2,540 gross; the
    post-walk marginals are the §5 displaced-stock pins (sell 19, buy 24 at
    stock 140)."""
    assert trade.sell_gain("london", "wine", 100, stock=DEMANDED_REST) == 2540
    assert trade.sell_price("london", "wine", 140) == 19
    assert trade.buy_price("london", "wine", 140) == 24


def test_150_sale_walk_pin() -> None:
    """tools/test_trade.gd `_test_profit_survives_save_roundtrip`: 150 units
    from London rest 40 = 15 tranches summing 336 per 10 → 3,360 gross, and
    the §4.3 profit figure 3,360 − 150 × 21 = 210."""
    proceeds = trade.sell_gain("london", "wine", 150, stock=DEMANDED_REST)
    assert proceeds == 3360
    assert trade.sale_profit_total(proceeds, 30, 150) == 210
    assert trade.apply_trade(DEMANDED_REST, -150) == 190


# --- §4.4 quantity maths ------------------------------------------------------


def test_buy_max_purse_walk() -> None:
    """tools/test_trade.gd `_test_quantity_limits`: the largest quantity
    whose FULL tranche walk the purse can pay (tariff included) and the hold
    can store. 1,000g at aligned 5%: four tranches cost 920 + 46 tax = 966;
    the fifth (27g/unit) fits exactly 1 more unit → 41."""
    kwargs = {"stock": PRODUCED_REST, "gold": 1000, "hold_free": 120}
    assert trade.buy_max("lisbon", "wine", tariff_mille=TARIFF_ALIGNED,
                         **kwargs) == 41
    # Under a home charter the 5% vanishes: the untaxed walk — four tranches
    # 920g + 2 units at 27g ≤ 1,000g → 42.
    assert trade.buy_max("lisbon", "wine", tariff_mille=TARIFF_EXEMPT,
                         **kwargs) == 42
    # 220g buys the full first tranche (210 + 10 tax); 219g buys 9 (the 10th
    # would cost 220); 210g likewise leaves 9.
    assert trade.buy_max("lisbon", "wine", tariff_mille=TARIFF_ALIGNED,
                         stock=PRODUCED_REST, gold=220,
                         hold_free=120) == 10
    assert trade.buy_max("lisbon", "wine", tariff_mille=TARIFF_ALIGNED,
                         stock=PRODUCED_REST, gold=219,
                         hold_free=120) == 9
    assert trade.buy_max("lisbon", "wine", tariff_mille=TARIFF_ALIGNED,
                         stock=PRODUCED_REST, gold=210,
                         hold_free=120) == 9


def test_buy_max_capacity_clamps() -> None:
    """buy_max never exceeds the pooled free hold (docs/30 §4.4;
    tools/test_trade.gd `_test_quantity_limits`)."""
    rich = {"stock": PRODUCED_REST, "gold": 100000}
    assert trade.buy_max("lisbon", "wine", hold_free=5,
                         tariff_mille=TARIFF_ALIGNED, **rich) == 5
    # A full hold has buy_max 0 — the §6 `market.hold_full` state.
    assert trade.buy_max("lisbon", "wine", hold_free=0,
                         tariff_mille=TARIFF_ALIGNED, **rich) == 0
    # sell_max is the held quantity, pooled across the fleet.
    assert trade.sell_max(30) == 30
    assert trade.sell_max(0) == 0


# --- Transactions: all-or-nothing validation + exact totals -------------------


def test_buy_transaction_exact_totals() -> None:
    """tools/test_trade.gd `_test_tariff_on_trades` /
    `_test_tranche_repricing`: the walked total + the §4.10 tax are exact —
    10 wine at Lisbon rest: 210 + 10 tax = 220; 100 wine: 2,750 + 137 =
    2,887; exempt buys charge exactly the gross."""
    result = trade.buy("lisbon", "wine", 10, stock=PRODUCED_REST, gold=220,
                       hold_free=120, tariff_mille=TARIFF_ALIGNED)
    assert result.ok
    assert (result.cost, result.tax, result.total) == (210, 10, 220)
    assert result.new_stock == 150
    assert result.marginal_price == 21
    result = trade.buy("lisbon", "wine", 100, stock=PRODUCED_REST,
                       gold=100000, hold_free=120,
                       tariff_mille=TARIFF_ALIGNED)
    assert result.ok
    assert (result.cost, result.tax, result.total) == (2750, 137, 2887)
    # Exempt: the zero rate charges exactly the gross walked total.
    exempt = trade.buy("lisbon", "wine", 10, stock=PRODUCED_REST, gold=1000,
                       hold_free=120, tariff_mille=TARIFF_EXEMPT)
    assert (exempt.cost, exempt.tax, exempt.total) == (210, 0, 210)


@pytest.mark.parametrize("qty", [0, -1, -500])
def test_buy_transaction_zero_quantity_refusals(qty: int) -> None:
    """Invalid quantities are refused without noise (tools/test_trade.gd
    `_test_buy_clamps`) — an all-zero result, nothing to apply."""
    result = trade.buy("lisbon", "wine", qty, stock=PRODUCED_REST, gold=1000,
                       hold_free=120, tariff_mille=TARIFF_ALIGNED)
    assert not result.ok
    assert (result.cost, result.tax, result.total, result.new_stock) == \
        (0, 0, 0, 0)


def test_buy_transaction_refusals_change_nothing() -> None:
    """Over-max (purse/capacity), unknown port/good and unlisted pairs are
    refused — docs/30 §4.4 "transaction errors … change nothing"."""
    # Over-max gold buy: buying 11 with 210g is refused.
    assert not trade.buy("lisbon", "wine", 11, stock=PRODUCED_REST, gold=210,
                         hold_free=120,
                         tariff_mille=TARIFF_ALIGNED).ok
    # Over-max capacity buy: buying 6 into 5 free units is refused; buying
    # exactly the free 5 succeeds (105 + 5 tax = 110).
    assert not trade.buy("lisbon", "wine", 6, stock=PRODUCED_REST,
                         gold=100000, hold_free=5,
                         tariff_mille=TARIFF_ALIGNED).ok
    cap = trade.buy("lisbon", "wine", 5, stock=PRODUCED_REST, gold=100000,
                    hold_free=5, tariff_mille=TARIFF_ALIGNED)
    assert cap.ok and (cap.cost, cap.tax, cap.total) == (105, 5, 110)
    assert cap.new_stock == 155
    # Unknown port / unknown good.
    assert not trade.buy("not_a_port", "wine", 1, stock=0, gold=1000,
                         hold_free=120).ok
    assert not trade.buy("lisbon", "not_a_good", 1, stock=40, gold=1000,
                         hold_free=120).ok
    # Unlisted pairs never transact (docs/30 §4.4 listing rule): silver is
    # unlisted at Lisbon.
    assert not trade.is_listed("lisbon", "silver")
    assert not trade.buy("lisbon", "silver", 1, stock=40, gold=1000,
                         hold_free=120).ok


def test_sell_transaction_exact_totals() -> None:
    """tools/test_trade.gd `_test_tranche_repricing` /
    `_test_sell_profit_xp_and_reputation`: the gross walked proceeds, the
    20% foreign tariff off them, and the gross-based §4.3 profit figure."""
    result = trade.sell("london", "wine", 100, stock=DEMANDED_REST, held=100,
                        tariff_mille=TARIFF_FOREIGN)
    assert result.ok
    assert (result.proceeds, result.tax, result.net) == (2540, 508, 2032)
    assert result.new_stock == 140
    assert result.marginal_price == 31
    assert result.profit_total == 2540 - 100 * 21
    # The 300-unit §4.4 worked sale: 5,170 gross − 1,034 tax = 4,136 net,
    # stock parked at 200.
    big = trade.sell("london", "wine", 300, stock=DEMANDED_REST, held=300,
                     tariff_mille=TARIFF_FOREIGN)
    assert big.ok
    assert (big.proceeds, big.tax, big.net) == (5170, 1034, 4136)
    assert big.new_stock == 200
    # The 150-unit roundtrip pin: 3,360 − 672 = 2,688.
    mid = trade.sell("london", "wine", 150, stock=DEMANDED_REST, held=150,
                     tariff_mille=TARIFF_FOREIGN)
    assert (mid.proceeds, mid.tax, mid.net) == (3360, 672, 2688)


def test_sell_transaction_loss_and_title() -> None:
    """Loss-making sales book 0 profit (docs/50 §4.3 — 0 XP, 0 reputation
    land on the caller); a title applies sell-side (tools/test_trade.gd
    `_test_sell_profit_xp_and_reputation`)."""
    # Parked London sells at 12/unit against a 21 basis — a loss every unit:
    # 120 gross − 24 tax = 96 net, profit figure 0.
    loss = trade.sell("london", "wine", 10, stock=200, held=10,
                      tariff_mille=TARIFF_FOREIGN)
    assert loss.ok
    assert (loss.proceeds, loss.tax, loss.net) == (120, 24, 96)
    assert loss.profit_total == 0
    # A knighthood at London: 32 × 10 = 320 gross − 64 tax = 256 net.
    titled = trade.sell("london", "wine", 10, stock=DEMANDED_REST, held=10,
                        tariff_mille=TARIFF_FOREIGN, title_units=1050)
    assert (titled.proceeds, titled.tax, titled.net) == (320, 64, 256)


def test_sell_transaction_refusals() -> None:
    """不收购 (a producer never buys its own produced good), over-quantity
    and zero-quantity sells fail without changing anything
    (tools/test_trade.gd `_test_listing_rule` /
    `_test_sell_profit_xp_and_reputation`)."""
    assert not trade.port_buys_good("lisbon", "wine")
    assert trade.port_buys_good("lisbon", "wheat")
    assert not trade.sell("lisbon", "wine", 5, stock=PRODUCED_REST,
                          held=5).ok
    # Selling 6 of 5 held is refused; sell(0) is refused.
    assert not trade.sell("london", "wine", 6, stock=DEMANDED_REST,
                          held=5).ok
    assert not trade.sell("london", "wine", 0, stock=DEMANDED_REST,
                          held=5).ok
    # Unknown port/good and unlisted pairs.
    assert not trade.sell("not_a_port", "wine", 1, stock=40, held=1).ok
    assert not trade.sell("lisbon", "silver", 1, stock=40, held=1).ok


def test_negotiation_discount_on_transactions() -> None:
    """The §4.10 negotiation discount lands on real totals, both directions
    (negotiation 20 → 2 points: aligned 3%, foreign 18%;
    tools/test_trade.gd `_test_tariff_discount`)."""
    aligned = trade.tax_mille(TARIFF_ALIGNED, negotiation=20)
    foreign = trade.tax_mille(TARIFF_FOREIGN, negotiation=20)
    assert (aligned, foreign) == (300, 1800)
    buy = trade.buy("lisbon", "wine", 10, stock=PRODUCED_REST, gold=1000,
                    hold_free=120, tariff_mille=aligned)
    # 210 gross + 210 × 300/10000 = 6 tax → 216 out of pocket.
    assert (buy.cost, buy.tax, buy.total) == (210, 6, 216)
    sell = trade.sell("london", "wine", 10, stock=DEMANDED_REST, held=10,
                      tariff_mille=foreign)
    # 310 gross − 310 × 1800/10000 = 55 tax → 255 net.
    assert (sell.proceeds, sell.tax, sell.net) == (310, 55, 255)
    # The floor is 0: negotiation ≥ 50 zeroes the aligned 5%, and the
    # zero-rate buy charges exactly the gross 210.
    assert trade.tax_mille(TARIFF_ALIGNED, negotiation=100) == 0
    free = trade.buy("lisbon", "wine", 10, stock=PRODUCED_REST, gold=1000,
                     hold_free=120,
                     tariff_mille=trade.tax_mille(TARIFF_ALIGNED, 100))
    assert free.total == 210


# --- §4.10 tariff parameters ---------------------------------------------------


@pytest.mark.parametrize(
    ("negotiation", "points", "aligned", "foreign"),
    [(0, 0, 500, 2000), (20, 2, 300, 1800), (40, 4, 100, 1600),
     (50, 5, 0, 1500), (100, 5, 0, 1500)],
)
def test_tariff_discount_matrix(negotiation: int, points: int,
                                aligned: int, foreign: int) -> None:
    """tools/test_trade.gd `_test_tariff_discount` pinned levels:
    ``min(5, floor(negotiation/10))`` points off the §4.10 rate, floored at
    0 — an aligned 5% reaches 0% at negotiation ≥ 50, a foreign 20% becomes
    15%."""
    assert trade.tariff_discount_points(negotiation) == points
    assert trade.tax_mille(TARIFF_ALIGNED, negotiation) == aligned
    assert trade.tax_mille(TARIFF_FOREIGN, negotiation) == foreign
    # NPC parity lives in the allegiance rule (the injected base rate never
    # moves): the rate itself is what the caller passes — 500/2000 here.


def test_tariff_discount_floor_of_division() -> None:
    """floor(negotiation/10): 49 → 4 points, 50 → 5."""
    assert trade.tariff_discount_points(49) == 4
    assert trade.tariff_discount_points(50) == 5


def test_tax_amount_pins() -> None:
    """tools/test_trade.gd `_test_tariff_matrix`: ``total × mille / 10,000``
    integer division; an empty total carries no tax."""
    assert trade.tax_amount(TARIFF_ALIGNED, 210) == 10
    assert trade.tax_amount(TARIFF_FOREIGN, 310) == 62
    assert trade.tax_amount(TARIFF_ALIGNED, 0) == 0
    assert trade.tax_amount(0, 210) == 0
    # The negotiation-discounted rates from the transaction pins.
    assert trade.tax_amount(300, 210) == 6
    assert trade.tax_amount(1800, 310) == 55
    # The taxed gross the buy_max walk affordability compares against.
    assert trade.taxed_total(210, TARIFF_ALIGNED) == 220
    assert trade.taxed_total(920, TARIFF_ALIGNED) == 966
    assert trade.taxed_total(920, TARIFF_EXEMPT) == 920


def test_unallied_port_tariff_on_buy() -> None:
    """tools/test_trade.gd `_test_tariff_on_trades`: an unallied neutral
    port taxes 20% forever — 10 wine at quanzhou (demanded, stock 40) costs
    390 + 78 tax = 468."""
    result = trade.buy("quanzhou", "wine", 10, stock=DEMANDED_REST,
                       gold=1000, hold_free=120,
                       tariff_mille=TARIFF_FOREIGN)
    assert result.ok
    assert (result.cost, result.tax, result.total) == (390, 78, 468)


# --- §4.3 investment -----------------------------------------------------------


def test_investment_percent_chunks() -> None:
    """1% per 500g chunk, capped at 10 (docs/30 §4.3): percent == chunks."""
    assert trade.investment_percent(0) == 0
    assert trade.investment_percent(499) == 0
    assert trade.investment_percent(500) == 1
    assert trade.investment_percent(1500) == 3
    assert trade.investment_percent(5000) == 10
    assert trade.investment_percent(6000) == 10  # the readout saturates


def test_can_invest_gate_matrix() -> None:
    """The §4.3/§4.9 gates: the purse, the §4.9 block reason (injected — the
    allegiance module lands separately), and the protected-port 5,000g
    discount-saturation cap (contestable ports keep investing past it — the
    ledger is the flip campaign's currency)."""
    assert trade.can_invest(gold=500, invested_gold=0, protected=True)
    assert trade.can_invest(gold=100000, invested_gold=0, protected=False)
    # docs/30 §6 "gold exactly equals cost": 499g cannot, 500g can.
    assert not trade.can_invest(gold=499, invested_gold=0, protected=True)
    # The 11th click at a protected port: the cap ends investment.
    assert not trade.can_invest(gold=100000, invested_gold=5000,
                                protected=True)
    # A contestable port at the same lifetime total keeps investing.
    assert trade.can_invest(gold=100000, invested_gold=5000, protected=False)
    # The diplomacy gate: any block reason vetoes (rep < 0 or a standing
    # bounty — the allegiance module's resolution).
    assert not trade.can_invest(gold=100000, invested_gold=0, protected=True,
                                invest_block_reason="market.invest_gate.blocked")
    assert not trade.can_invest(gold=100000, invested_gold=0, protected=False,
                                invest_block_reason="market.invest_gate.exhausted")
    # An empty purse never invests.
    assert not trade.can_invest(gold=0, invested_gold=0, protected=False)


def test_invested_read() -> None:
    """``invested`` reads the injected ``port_investments`` block; per port,
    never shared."""
    investments = {"lisbon": 1500}
    assert trade.invested(investments, "lisbon") == 1500
    assert trade.invested(investments, "london") == 0
    assert trade.invested(investments, "") == 0
    assert trade.invested({}, "lisbon") == 0


# --- §4.2 supplies (docs/20 §4.10) ---------------------------------------------


def test_supplies_ignore_factors() -> None:
    """Provisions 2g / water 1g, exempt from **all** factors — locked
    constants, not trade goods (absent from goods.json)."""
    assert trade.supplies_price("provisions") == 2
    assert trade.supplies_price("water") == 1
    assert trade.supplies_price("rum") == 0
    store = data()
    assert "provisions" not in store.goods
    assert "water" not in store.goods
    # The locked prices hold at any stock/investment — supplies ignore the
    # plumbing entirely (tools/test_trade.gd `_test_supplies_ignore_factors`
    # pins them at max investment).
    assert trade.supplies_price("provisions") == trade.PROVISIONS_PRICE == 2
    assert trade.supplies_price("water") == trade.WATER_PRICE == 1


def test_supplies_buy_max() -> None:
    """Buy ceiling only — sell-back is not offered (docs/20 §4.10):
    ``min(floor(gold / price), hold_free)``."""
    assert trade.supplies_buy_max("provisions", gold=5, hold_free=10) == 2
    assert trade.supplies_buy_max("water", gold=5, hold_free=10) == 5
    # Capacity binds before the purse does.
    assert trade.supplies_buy_max("provisions", gold=100, hold_free=3) == 3
    assert trade.supplies_buy_max("water", gold=0, hold_free=10) == 0
    assert trade.supplies_buy_max("rum", gold=100, hold_free=10) == 0


# --- §4.4 listing rule ---------------------------------------------------------


def test_listing_rule_rows() -> None:
    """A port lists a good iff it produces or demands it (docs/30 §4.4,
    correction 7); rows sorted by base_price ascending, ties by id
    (tools/test_trade.gd `_test_listing_rule`)."""
    store = data()
    assert len(store.goods_list) == 40  # the locked 40 goods
    port = store.get_port("lisbon")
    listed = set(port.get("produces", [])) | set(port.get("demands", []))
    rows = trade.goods_rows("lisbon")
    assert len(rows) == len(listed)
    row_ids = [str(row.get("id", "")) for row in rows]
    assert set(row_ids) == listed
    # lisbon's produces carry rows (wine, salt) and its demands too (gold,
    # spices); unlisted goods never render (silver, tea absent).
    assert "wine" in row_ids and "salt" in row_ids
    assert "gold" in row_ids and "spices" in row_ids
    assert "silver" not in row_ids and "tea" not in row_ids
    # Sorted by (base_price, id).
    keys = [(int(row.get("base_price", 0)), str(row.get("id", "")))
            for row in rows]
    assert keys == sorted(keys)


def test_listing_rule_gates() -> None:
    """``is_listed`` / ``port_buys_good``: unknown pairs no; produces are
    buy-only-into (不收购), demands buy the player's cargo."""
    assert trade.is_listed("lisbon", "wine")
    assert trade.is_listed("lisbon", "wheat")
    assert not trade.is_listed("lisbon", "silver")
    assert not trade.is_listed("lisbon", "tea")
    assert not trade.is_listed("nowhere", "wine")
    # Market direction: lisbon does not buy its own wine; it buys the wheat
    # it demands.
    assert not trade.port_buys_good("lisbon", "wine")
    assert trade.port_buys_good("lisbon", "wheat")
    assert trade.port_buys_good("london", "wine")


# --- §4.2 price memory (session-transient) -------------------------------------


def test_memory_capacity() -> None:
    """``floor(appraisal / 10)`` entries — 30 → 3, 100 → 10; below 10
    appraisal nothing records at all (docs/30 §4.2)."""
    assert trade.memory_capacity(0) == 0
    assert trade.memory_capacity(9) == 0
    assert trade.memory_capacity(30) == 3
    assert trade.memory_capacity(100) == 10


def test_memory_lru_sequence() -> None:
    """tools/test_trade.gd `_test_price_memory` at capacity 3: one entry per
    (port, good); a re-buy overwrites and moves the pair to newest ("last
    seen"); the 4th pair evicts the LEAST-RECENTLY-RECORDED entry — the
    overwritten lisbon wine survives."""
    memory: dict[str, dict[str, int]] = {}
    order: list[str] = []
    cap = trade.memory_capacity(30)
    trade.memory_record(memory, order, "lisbon", "wine", 21, 1, cap)
    assert trade.price_memory_entry(memory, "lisbon", "wine") == \
        {"price": 21, "day": 1}
    trade.memory_record(memory, order, "lisbon", "salt", 9, 1, cap)
    trade.memory_record(memory, order, "london", "wine", 39, 1, cap)
    assert len(memory) == 3
    # Re-buy lisbon wine at its moved stock: the overwrite carries the new
    # marginal 22 and moves the pair to newest.
    trade.memory_record(memory, order, "lisbon", "wine", 22, 2, cap)
    assert trade.price_memory_entry(memory, "lisbon", "wine") == \
        {"price": 22, "day": 2}
    assert len(memory) == 3
    # The 4th pair evicts lisbon|salt (least-recently-recorded).
    trade.memory_record(memory, order, "lisbon", "wheat", 10, 2, cap)
    snapshot = trade.price_memory(memory, order)
    assert len(snapshot) == 3
    assert "lisbon|salt" not in snapshot
    assert set(snapshot) == {"lisbon|wine", "london|wine", "lisbon|wheat"}
    # The snapshot is LRU-ordered (london|wine is oldest now).
    assert list(snapshot) == ["london|wine", "lisbon|wine", "lisbon|wheat"]


def test_memory_capacity_zero_records_nothing() -> None:
    """Capacity 0 (appraisal < 10): completed buys record nothing
    (tools/test_trade.gd `_test_price_memory`)."""
    memory: dict[str, dict[str, int]] = {}
    order: list[str] = []
    trade.memory_record(memory, order, "lisbon", "wine", 21, 1, 0)
    assert memory == {} and order == []


def test_memory_other_port_lookup() -> None:
    """The §4.2 other-port comparator: the most-recent entry for the good at
    a port **other** than the query port; none → {}."""
    memory: dict[str, dict[str, int]] = {}
    order: list[str] = []
    cap = 10
    trade.memory_record(memory, order, "lisbon", "wine", 21, 1, cap)
    # lisbon's own entry is not "other".
    assert trade.memory_other_port_entry(memory, order, "lisbon", "wine") == {}
    trade.memory_record(memory, order, "valencia", "wine", 39, 2, cap)
    trade.memory_record(memory, order, "london", "wine", 39, 3, cap)
    # The most-recent foreign entry wins (london, day 3).
    assert trade.memory_other_port_entry(memory, order, "lisbon", "wine") == \
        {"price": 39, "day": 3}
    assert trade.memory_other_port_entry(memory, order, "london", "wine") == \
        {"price": 39, "day": 2}  # valencia is london's "other"


def test_memory_capacity_ten_eviction() -> None:
    """At capacity 10 the 11th buy evicts the FIRST pair, not the eleventh
    (tools/test_trade.gd `_test_price_memory`)."""
    memory: dict[str, dict[str, int]] = {}
    order: list[str] = []
    cap = trade.memory_capacity(100)
    for i in range(11):
        trade.memory_record(memory, order, "port_a", f"g{i}", 10 + i, i + 1,
                            cap)
    assert len(memory) == 10
    assert "port_a|g0" not in memory
    assert "port_a|g10" in memory


# --- §4.2 market arrows (appraisal-gated) ---------------------------------------


def test_gate_thresholds_read_data() -> None:
    """The §4.3.5 gates load from data/skill_gates.json (30 / 60) — the
    loader keys them by feature_id (docs/50 §4.3.5)."""
    assert data().get_skill_gate("market.profit_arrows")["threshold"] == 30
    assert data().get_skill_gate("market.other_port_memory")["threshold"] == 60
    assert trade.profit_arrows_unlocked(29) is False
    assert trade.profit_arrows_unlocked(30) is True
    assert trade.memory_arrows_unlocked(59) is False
    assert trade.memory_arrows_unlocked(60) is True


def test_profit_arrow_directions() -> None:
    """tools/test_trade.gd Phase-8 arrows: below the gate the arrow never
    renders; a cheap producer row points down (buy 21 < base 30), a dear
    consumer row points up (sell 31 > base 30); a row pricing exactly at
    base shows neither (stock 100 → factor 1.0)."""
    assert trade.profit_arrow("lisbon", "wine", stock=PRODUCED_REST,
                              appraisal=0) == ""
    assert trade.profit_arrow("lisbon", "wine", stock=PRODUCED_REST,
                              appraisal=30) == "down"
    assert trade.profit_arrow("london", "wine", stock=DEMANDED_REST,
                              appraisal=30) == "up"
    assert trade.profit_arrow("lisbon", "wine", stock=100,
                              appraisal=30) == ""
    # The gate is data-driven: 29 is below the shipped threshold.
    assert trade.profit_arrow("lisbon", "wine", stock=PRODUCED_REST,
                              appraisal=29) == ""


def test_memory_arrow_directions() -> None:
    """tools/test_trade.gd Phase-8 arrows: below the appraisal ≥ 60 gate
    only "" renders; the local marginal buy price compares against the
    most-recent other-port memory entry — up when dearer, down when
    cheaper, "" with no foreign entry."""
    memory: dict[str, dict[str, int]] = {}
    order: list[str] = []
    assert trade.memory_arrow("lisbon", "wine", stock=PRODUCED_REST,
                              appraisal=60, memory=memory,
                              order=order) == ""
    trade.memory_record(memory, order, "london", "wine", 25, 1, 10)
    # Local 21 < remembered 25 → down.
    assert trade.memory_arrow("lisbon", "wine", stock=PRODUCED_REST,
                              appraisal=60, memory=memory,
                              order=order) == "down"
    # Local 21 > remembered 20 → up.
    trade.memory_record(memory, order, "london", "wine", 20, 2, 10)
    assert trade.memory_arrow("lisbon", "wine", stock=PRODUCED_REST,
                              appraisal=60, memory=memory,
                              order=order) == "up"
    # Below the gate: "" whatever the memory holds.
    assert trade.memory_arrow("lisbon", "wine", stock=PRODUCED_REST,
                              appraisal=59, memory=memory,
                              order=order) == ""


# --- §4.3 profit basis (docs/50 §4.3) -------------------------------------------


def test_profit_basis_helpers() -> None:
    """``floor(base_price × 0.7)`` basis; per-unit and walked totals floored
    at 0 — a loss-making sale never books negative profit."""
    assert trade.per_unit_profit(31, 30) == 10   # 31 − floor(30 × 0.7)
    assert trade.per_unit_profit(12, 30) == 0    # below the basis
    assert trade.sale_profit(31, 30, 10) == 100
    assert trade.sale_profit(12, 30, 10) == 0
    assert trade.sale_profit_total(2540, 30, 100) == 440
    assert trade.sale_profit_total(120, 30, 10) == 0   # the parked loss
    assert trade.sale_profit_total(5170, 30, 300) == 0  # 5,170 < 300 × 21
