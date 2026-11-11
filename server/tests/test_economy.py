"""server.tests.test_economy — the flow-economy + allegiance parity suite (M1).

Port of the guarantee, not the method (AGENTS.md test discipline): the
GDScript harnesses (``tools/test_economy.gd`` — Phase-7 task K — and
``tools/test_allegiance.gd`` — task L) boot a run and walk the autoloads;
here the same pinned contracts are asserted as pure functions over injected
state on the real shipped ``data/`` tree (loaded through
:mod:`server.sim.data`).

Pinned contracts — economy (oracle: ``scripts/port/economy.gd``; docs/30
§4.2/§4.4/§4.5, docs/90 §5.4):
  * the §4.2 stock derivation — producers at capacity, consumers at 60,
    unlisted goods absent, produces-wins-over-demands, no RNG — on the
    synthetic harness fixture AND on real ports (Lisbon dev-3 staple
    capacity 200, London consumer 60, Quanzhou specialty 120);
  * the exact factor ladder ``clamp(1500 − 5×stock, 500, 2000)`` with both
    clamps, monotonicity, the set_stock hard clamp and the stock-less
    unknown port (factor 1500);
  * the flag-driven tier table (12 staples / 16 middle / 12 luxuries, rates
    5/3/2, capacities 160/140/120) with per-good ``flow`` overrides, and the
    pure dev tables (``rate × (4+dev)/4`` → 5/6/7/8, capacities +20/dev,
    ceiling 200);
  * the §4.2 flow tick as exact integers on hand-built stocks — consumer
    5→0 in one tick floored at 0, producer 118→120 clamped, the dev-2 world
    (7/day drain, capacities 180/200/160), the real-module dev-3 capital
    (8/day: London wine 60→0 in exactly 8 days), the world-wide steady
    gradient (producers at capacity, consumers drained, nothing moves), the
    recovery pacing (a 120-unit dump into Quanzhou wine recovers to factor
    ≥ 1350 in exactly 18 days) and the day_tick moved-port report;
  * the §4.5 demand-event surges — ×3 consumption on exactly the surged
    port-good (production and other ports untouched), expiry at until_day,
    the reset seam, and the ``market_events.json`` template path (war
    provisioning → timber/iron 15/day at Seville, telegraph shape, expiry at
    start+duration, the ≤1-per-nation / ≤4-world budget constants);
  * the §4.5 seeded rotation — the exact 360-day schedule captured from the
    pinned Godot 4.7.official.5b4e0cb0f toolchain (13 starts, listed as
    ``GOLDEN_EVENT_SCHEDULE``) and same-seed replay determinism;
  * the §4.4 tranche walks (delegated to :mod:`server.sim.port.trade`) —
    the Lisbon 21/22/24 ladder, the docs §5 300-unit London sale (16
    distinct prices, parked continuously at the 200 bound, exact 5,170g
    never the 9,300g flat), partial last tranches, the signed direction,
    and the identity with trade.plan_trade (the delegation seam);
  * the pinned sim_trade scenario (tools/test_economy.gd §13): Quanzhou
    porcelain/water numbers replayed through trade.price_from_units.

Pinned contracts — allegiance (oracle: ``scripts/port/allegiance.gd``;
docs/30 §4.3/§4.9/§4.10, docs/70 §4.1, docs/90 §5.4):
  * ``seed_new_game`` shape — protected ports align to their owner forever
    at the authored dev floor with no ledger; contestable sovereigns
    ``{owner: 6000}`` (allied, 7,500 effective, below dev-1); neutrals
    empty at dev 0; treasuries 5,000g ×6; all 133 contestable ports
    seeded; the dump carries exactly the five save v7 keys;
  * the ledger resolution — the 5,000g line (4,999 unaligned, 5,000
    aligned), the tie rule keeping the incumbent, the sovereign owner's
    ×5/4 home advantage (7,500 foreign ties, 7,501 flips), cumulative
    ledgers, and the dev thresholds at their boundary values (9,999/10,000,
    24,999/25,000, 50,000) over the authored floor;
  * protected immunity (the AI never touches a core port; the discount is
    the whole player effect there) and the decision-26 monthly cap +
    diplomatic gate (4 chunks → exhausted, month-tick reset, rep/bounty
    blocking, no gate while unaligned);
  * the monthly NPC counter-investment — the exact month-31 and month-61
    sequences captured from the pinned toolchain
    (``GOLDEN_AI_MONTH_31`` / ``GOLDEN_AI_MONTH_61``) with the treasury
    flow (baseline − spend, every purse books exactly), the ≤2-pick /
    ≤1,500g / sphere / never-protected / never-own-dev-3 bounds;
  * the §2.6 fame paragraph — +100 first flip (once per port per save), the
    −5 poaching rep per flip with the previous sovereign owner, no fame on
    losing a port back, +25 per dev threshold crossed at an aligned port
    with the flip-time re-baseline never retro-awarding, the one-shot
    commendation;
  * the §4.10 tariff resolution matrix — aligned 500‰ / foreign 2000‰ /
    unaligned 2000‰ / unknown port 2000‰, the alignment flip moving the
    5% with it, and the permit matrix (home charter own+aligned only,
    foreign permit player-only, void on bounty or rep < −20 with the exact
    ui_strings reasons);
  * the treasury crediting flow — player tax uncapped, NPC tax capped at
    2,000g/host/month, the per-host window, unaligned hosts and nationless
    payers crediting nothing, the month tick's credits + baseline − AI
    spend, permit sales uncapped;
  * the 30-day telegraph window (rows carried ``{nation_id, port_id, band,
    amount, day}``, visible at +29, gone at +30) and the dump/restore seam
    (five keys, ledgers/allegiances/permits/counters/treasuries survive,
    the threshold tracker re-derived so a crossing awards +25 exactly once).

Deterministic — the only RNG is economy's seeded rotation and allegiance's
seeded counter-investment, both through GodotRng (bit-exact PCG32) with the
GDScript seed formulas; every other number below is the GDScript pin or the
closed-form value of a pinned formula on shipped data.
"""

from __future__ import annotations

from typing import Any

from server.sim.data import DataStore, data
from server.sim.port import allegiance, economy, trade
from server.sim.player import PersonState, character

NATIONS = ["portugal", "spain", "england", "holland", "ottoman", "italy"]

# --- Golden schedules ---------------------------------------------------------
#
# Captured from the pinned parity toolchain (Godot v4.7.stable.official.
# 5b4e0cb0f, 2026-11-11): a standalone headless probe ran economy.gd's
# market_events_tick rotation day 1..360 and allegiance.gd's month_tick
# counter-investment at days 31 / 61 over the shipped data tree, printing
# the instance rows. These constants are the oracle; the Python asserts
# below replay them exactly (same String.hash, same PCG32 draws).

#: economy.gd rotation, days 1–360: ``{template_id}@{port_id}@{start_day}``.
GOLDEN_EVENT_SCHEDULE = [
    "evt_pilgrim_procession@jiddah@4",
    "evt_harvest_festival@bahia@7",
    "evt_war_provisioning@cochin@41",
    "evt_winter_wool@madeira@44",
    "evt_sugar_feast@venice@74",
    "evt_bumper_harvest@quebec@130",
    "evt_harvest_festival@san_juan@199",
    "evt_sugar_feast@lisbon@202",
    "evt_bumper_harvest@palembang@263",
    "evt_harvest_festival@massawa@296",
    "evt_war_provisioning@san_juan@307",
    "evt_plague_quarantine@quanzhou@329",
    "evt_summer_wine@macau@334",
]

#: allegiance.gd month tick at day 31 (month index 1):
#: ``{nation_id}@{port_id}={amount}`` in resolution order.
GOLDEN_AI_MONTH_31 = [
    "england@anotsu=1500",
    "england@bandar_abbas=1500",
    "holland@amboina=1500",
    "holland@anotsu=1500",
    "italy@alexandria=1500",
    "italy@candia=1500",
    "ottoman@bandar_abbas=1500",
    "ottoman@basra=1500",
    "portugal@bahia=1500",
    "portugal@benguela=1500",
    "spain@acapulco=1500",
    "spain@brunei=1500",
]

#: allegiance.gd month tick at day 61 (month index 2).
GOLDEN_AI_MONTH_61 = [
    "england@acapulco=1500",
    "england@accra=1500",
    "holland@accra=1500",
    "holland@anotsu=1500",
    "italy@cagliari=1500",
    "italy@corfu=1500",
    "ottoman@aden=1500",
    "ottoman@algiers=1500",
    "portugal@accra=1500",
    "portugal@amboina=1500",
    "spain@acapulco=1500",
    "spain@algiers=1500",
]


# --- Fixtures (the harness shapes, as pure state builders) ---------------------


def store() -> DataStore:
    """The loaded shipped-data tree (one process-wide singleton)."""
    return data()


def seeded_allegiance() -> allegiance.AllegianceState:
    """A fresh allegiance state seeded for a new game."""
    alg = allegiance.AllegianceState()
    allegiance.seed_new_game(store(), alg)
    return alg


def dev_real(alg: allegiance.AllegianceState):
    """The GDScript guard seam wired to the REAL allegiance module: a
    ``dev_of`` callable answering ``Allegiance.dev`` per port."""
    return lambda port_id: allegiance.dev(store(), alg, port_id)


def derived_stocks(alg: allegiance.AllegianceState) -> dict[str, dict[str, int]]:
    """The §4.2 derived initial-stock table at the REAL allegiance dev."""
    s = store()
    return economy.build_initial_stocks(s.ports_list, s.goods_list,
                                        dev_of=dev_real(alg))


def economy_state(alg: allegiance.AllegianceState,
                  day: int = 1) -> economy.EconomyState:
    """A fresh economy state whose stock block is the derived table (the
    ``_make_run`` fixture shape)."""
    state = economy.EconomyState(day=day)
    state.market_stocks = derived_stocks(alg)
    economy.reset_events(state)
    return state


def flow_ticks(state: economy.EconomyState,
               alg: allegiance.AllegianceState, count: int) -> None:
    """Pure-flow tick driver: the scheduler inside ``day_tick`` may seed an
    event on the fixture day, so each pass drops instances + surges again —
    the gradient pins below exercise the PURE §4.2 flow (the GDScript
    ``_flow_ticks``)."""
    for _ in range(count):
        economy.day_tick(state, store(), dev_of=dev_real(alg))
        economy.reset_events(state)


def economy_state_dev0(day: int = 1) -> economy.EconomyState:
    """A fresh economy state in the dev-0 world (the GDScript fixture
    module pins): derived stocks at the guard default, ticks without a dev
    seam."""
    state = economy.EconomyState(day=day)
    state.market_stocks = economy.build_initial_stocks(
        store().ports_list, store().goods_list)
    economy.reset_events(state)
    return state


def flow_ticks_dev0(state: economy.EconomyState, count: int) -> None:
    """Pure-flow tick driver in the dev-0 world (instances + surges dropped
    after each pass — the GDScript ``_flow_ticks``)."""
    for _ in range(count):
        economy.day_tick(state, store())
        economy.reset_events(state)


def make_player(nation: str = "portugal", day: int = 1) -> PersonState:
    """A livable run for ``nation`` (the ``_make_run`` fixture shape):
    zero reputation everywhere, fame 0, the ledger day pinned."""
    return PersonState(
        player={
            "nation_id": nation,
            "reputation": {n: 0 for n in NATIONS},
            "skills": {},
        },
        day=day,
    )


# The synthetic harness fixture (tools/test_economy.gd `_synthetic_ports`):
# three ports covering the §4.2 listing rule, pure of any data file. The
# goods carry the tier flags explicitly — the GDScript harness leaned on its
# module tier cache already holding the real goods.json rows (wine/salt are
# staples there); the injected-list port states the same tiers in the
# fixture itself.
SYNTHETIC_PORTS = [
    {"id": "p_prod", "produces": ["wine"], "demands": ["salt"]},
    {"id": "p_both", "produces": ["wine", "salt"], "demands": ["wine"]},
    {"id": "p_flat", "produces": [], "demands": []},
]
SYNTHETIC_GOODS = [
    {"id": "wine", "base_price": 30, "staple": True},
    {"id": "salt", "base_price": 12, "staple": True},
    {"id": "silk", "base_price": 110},
]


# ============================================================================
# economy — §4.2 stock derivation
# ============================================================================


class TestStockInit:
    def test_synthetic_derivation(self) -> None:
        stocks = economy.build_initial_stocks(SYNTHETIC_PORTS,
                                              SYNTHETIC_GOODS)
        # wine/salt are staples (flag-driven base capacity 160; fixtures
        # read dev 0 — the guard default).
        assert stocks["p_prod"]["wine"] == 160
        assert stocks["p_prod"]["salt"] == 60
        assert "silk" not in stocks["p_prod"]
        # Listing rule: produces wins — wine is only produced at p_both.
        assert stocks["p_both"]["wine"] == 160
        assert stocks["p_both"]["salt"] == 160
        assert stocks["p_flat"] == {}
        assert len(stocks) == 3  # one row per port, no RNG
        assert economy.initial_stock_of(store(), "nowhere", "wine") == 0

    def test_real_ports(self) -> None:
        """Real-port spot checks vs the §4.2 formula (the GDScript
        `_test_new_game_stocks` pins)."""
        s = store()
        alg = seeded_allegiance()
        stocks = derived_stocks(alg)
        assert len(stocks) == len(s.ports_list)
        # Lisbon: protected capital, authored dev 3 → staple capacity
        # min(200, 160 + 60) == 200 — the seed IS the live capacity.
        assert allegiance.dev(store(), alg, "lisbon") == 3
        assert stocks["lisbon"]["wine"] == economy.capacity_of(
            store(), "lisbon", "wine", dev_of=dev_real(alg)) == 200
        assert economy.capacity_for(160, 3) == 200
        # London: demanded staple seeds at the consumer 60 (dev-independent).
        assert stocks["london"]["wine"] == 60
        # Quanzhou: neutral (dev 0) specialty producer, flow capacity 120.
        assert stocks["quanzhou"]["porcelain"] == 120
        assert "porcelain" not in stocks["valencia"]
        # Unlisted goods hold no row anywhere: every stored stock is listed.
        for port in s.ports_list:
            port_id = str(port.get("id", ""))
            for good_id in stocks[port_id]:
                assert economy.is_listed_in(port, good_id)

    def test_initial_stock_for_formula(self) -> None:
        """The pure per-port-good formula: producer at capacity_for(tier,
        dev), consumer at 60, unlisted 0 — at several dev levels."""
        port = {"id": "x", "produces": ["wine"], "demands": ["silk"]}
        tiers = economy.build_tiers(SYNTHETIC_GOODS + [
            {"id": "silk", "base_price": 110, "specialty": True},
        ])
        for dev in range(4):
            assert economy.initial_stock_for(port, "wine", dev, tiers) \
                == economy.capacity_for(160, dev)
            assert economy.initial_stock_for(port, "silk", dev, tiers) == 60
        assert economy.initial_stock_for(port, "salt", 0, tiers) == 0


# ============================================================================
# economy — the exact factor
# ============================================================================


class TestFactor:
    def test_reference_stocks(self) -> None:
        assert economy.factor_for_stock(160) == 700
        assert economy.factor_for_stock(60) == 1200
        assert economy.factor_for_stock(40) == 1300
        assert economy.factor_for_stock(100) == 1000

    def test_clamps_and_monotonicity(self) -> None:
        assert economy.factor_for_stock(0) == 1500
        assert economy.factor_for_stock(200) == 500
        assert economy.factor_for_stock(-1000) == 2000  # the safety net
        assert economy.factor_for_stock(1000) == 500
        previous = 2001
        for stock in range(0, 201):
            factor = economy.factor_for_stock(stock)
            assert factor <= previous
            previous = factor

    def test_reexport_identity_with_trade(self) -> None:
        """The flagged seam: economy's factor IS trade's (one definition)."""
        assert economy.factor_for_stock is trade.factor_for_stock

    def test_live_reads_and_clamped_writes(self) -> None:
        alg = seeded_allegiance()
        state = economy_state(alg)
        assert economy.factor_units(state, store(), "quanzhou",
                                    "porcelain", dev_of=dev_real(alg)) == 900
        assert economy.factor_units(state, store(), "london", "wine",
                                    dev_of=dev_real(alg)) == 1200
        economy.set_stock(state, "lisbon", "wine", 0)
        assert economy.factor_units(state, store(), "lisbon", "wine") == 1500
        economy.set_stock(state, "lisbon", "wine", 200)
        assert economy.factor_units(state, store(), "lisbon", "wine") == 500
        economy.set_stock(state, "lisbon", "wine", -5)
        assert economy.stock_of(state, store(), "lisbon", "wine") == 0
        economy.set_stock(state, "lisbon", "wine", 999)
        assert economy.stock_of(state, store(), "lisbon", "wine") == 200
        # An unknown port reads as no stock (0 → factor 1500), never a crash.
        assert economy.factor_units(state, store(), "nowhere", "wine") == 1500


# ============================================================================
# economy — the flag-driven tier table + dev/capacity tables
# ============================================================================


class TestTiers:
    def test_flag_split_and_rates(self) -> None:
        """12 staples / 16 middle / 12 luxuries, rates 5/3/2, capacities
        160/140/120, flow-composed (the validator's 12/16/12 pin)."""
        s = store()
        tiers = economy.build_tiers(s.goods_list)
        counts = {"staple": 0, "middle": 0, "luxury": 0}
        for good in s.goods_list:
            good_id = str(good.get("id", ""))
            counts[economy.tier_of(tiers, good_id)] += 1
            flow = good.get("flow", {})
            flow = flow if isinstance(flow, dict) else {}
            base_rate, base_cap = 3, 140
            tier = economy.tier_of(tiers, good_id)
            if tier == "staple":
                base_rate, base_cap = 5, 160
            elif tier == "luxury":
                base_rate, base_cap = 2, 120
            assert economy.prod_rate(tiers, good_id) \
                == int(flow.get("prod", base_rate))
            assert economy.cons_rate(tiers, good_id) \
                == int(flow.get("cons", base_rate))
            assert economy.tier_capacity(tiers, good_id) \
                == int(flow.get("capacity", base_cap))
        assert counts == {"staple": 12, "middle": 16, "luxury": 12}

    def test_flag_pins(self) -> None:
        tiers = economy.build_tiers(store().goods_list)
        assert economy.tier_of(tiers, "wine") == "staple"
        assert economy.prod_rate(tiers, "wine") == 5
        assert economy.cons_rate(tiers, "wine") == 5
        assert economy.tier_of(tiers, "spices") == "luxury"
        assert economy.prod_rate(tiers, "spices") == 2
        assert economy.cons_rate(tiers, "spices") == 3
        assert economy.tier_of(tiers, "dye_wood") == "middle"
        assert economy.prod_rate(tiers, "dye_wood") == 3
        # The 12 specialties all carry flow prod 2 / cons 3 / capacity 120.
        for good in store().goods_list:
            if good.get("specialty") is not True:
                continue
            good_id = str(good.get("id", ""))
            assert economy.prod_rate(tiers, good_id) == 2
            assert economy.cons_rate(tiers, good_id) == 3
            assert economy.tier_capacity(tiers, good_id) == 120

    def test_synthetic_flags_slot_in(self) -> None:
        """A synthetic ``staple: true`` good and a synthetic flow override
        derive from their flags (injected list — no data mutation)."""
        goods = list(store().goods_list) + [
            {"id": "test_flag_tea", "base_price": 9, "staple": True},
            {"id": "test_flow_silk", "base_price": 210, "specialty": True,
             "flow": {"prod": 1, "cons": 7, "capacity": 99}},
        ]
        tiers = economy.build_tiers(goods)
        assert economy.tier_of(tiers, "test_flag_tea") == "staple"
        assert economy.prod_rate(tiers, "test_flag_tea") == 5
        assert economy.tier_capacity(tiers, "test_flag_tea") == 160
        assert economy.tier_of(tiers, "test_flow_silk") == "luxury"
        assert economy.prod_rate(tiers, "test_flow_silk") == 1
        assert economy.cons_rate(tiers, "test_flow_silk") == 7
        assert economy.tier_capacity(tiers, "test_flow_silk") == 99

    def test_capacity_and_dev_rate_tables(self) -> None:
        """Pure capacity table (base + 20/dev, ceiling 200) and the pure
        dev-multiplier table (rate × (4+dev)/4), verbatim."""
        assert [economy.capacity_for(160, d) for d in range(4)] \
            == [160, 180, 200, 200]
        assert [economy.capacity_for(140, d) for d in range(4)] \
            == [140, 160, 180, 200]
        assert [economy.capacity_for(120, d) for d in range(4)] \
            == [120, 140, 160, 180]
        assert [economy.dev_rate(5, d) for d in range(4)] == [5, 6, 7, 8]
        assert [economy.dev_rate(3, d) for d in range(4)] == [3, 3, 4, 5]
        assert [economy.dev_rate(2, d) for d in range(4)] == [2, 2, 3, 3]

    def test_capacity_of_with_dev_fixture(self) -> None:
        """At a pinned dev 2 the capacities are 140+40 / 160+40 / 120+40."""
        dev2 = lambda port_id: 2
        assert economy.capacity_of(store(), "london", "dye_wood",
                                   dev_of=dev2) == 180
        assert economy.capacity_of(store(), "london", "wheat",
                                   dev_of=dev2) == 200
        assert economy.capacity_of(store(), "london", "porcelain",
                                   dev_of=dev2) == 160
        # The guard default (no allegiance wired): dev 0 everywhere.
        assert economy.capacity_of(store(), "lisbon", "wheat") == 160


# ============================================================================
# economy — the §4.2 flow tick
# ============================================================================


class TestFlowTick:
    def test_drain_floors_and_fill_clamps_dev0(self) -> None:
        """Hand-built stocks, exact ints, the dev-0 world (the GDScript
        fixture module pins): consumer 5→0 in one tick (staple 5/day),
        floored at 0; producer 118→120 in one tick (2/day), clamped."""
        state = economy_state_dev0(day=1)
        economy.set_stock(state, "london", "wine", 5)
        economy.day_tick(state, store())  # dev_of=None → the guard default 0
        assert economy.stock_of(state, store(), "london", "wine") == 0
        economy.day_tick(state, store())
        assert economy.stock_of(state, store(), "london", "wine") == 0
        assert economy.factor_units(state, store(), "london", "wine") == 1500
        economy.set_stock(state, "quanzhou", "porcelain", 118)
        economy.day_tick(state, store())
        assert economy.stock_of(state, store(), "quanzhou", "porcelain") \
            == 120
        economy.day_tick(state, store())
        assert economy.stock_of(state, store(), "quanzhou", "porcelain") \
            == 120

    def test_dev2_drain(self) -> None:
        """At a pinned dev 2 the staple consumer drains at 7/day
        (5 × 6/4): 5 → 0 in exactly one tick."""
        state = economy.EconomyState()
        state.market_stocks = {"london": {"wine": 5}}
        economy.day_tick(state, store(), dev_of=lambda port_id: 2)
        assert state.market_stocks["london"]["wine"] == 0

    def test_real_dev_capital_drains_in_8_days(self) -> None:
        """With the REAL allegiance module the dev-3 capital drains 60 → 0
        in exactly 8 days (8/day = 5 × 7/4, the integer ×2)."""
        alg = seeded_allegiance()
        state = economy_state(alg)
        dev_of = dev_real(alg)
        assert dev_of("lisbon") == 3 and dev_of("london") == 3 \
            and dev_of("quanzhou") == 0
        hit_zero = -1
        for tick in range(30):
            flow_ticks(state, alg, 1)
            if economy.stock_of(state, store(), "london", "wine",
                                dev_of=dev_of) == 0:
                hit_zero = tick + 1
                break
        assert hit_zero == 8

    def test_steady_gradient_worldwide(self) -> None:
        """After 30 pure ticks every producer sits at capacity and every
        consumer is drained; a steady-state world reports no moved ports;
        every stock stays inside [0, 200]."""
        alg = seeded_allegiance()
        state = economy_state(alg)
        dev_of = dev_real(alg)
        flow_ticks(state, alg, 30)
        producers = consumers = 0
        for port in store().ports_list:
            port_id = str(port.get("id", ""))
            produces = port.get("produces", [])
            for good_id, stock in state.market_stocks[port_id].items():
                assert 0 <= stock <= 200
                if good_id in produces:
                    producers += 1
                    assert stock == economy.capacity_of(
                        store(), port_id, good_id, dev_of=dev_of)
                else:
                    consumers += 1
                    assert stock == 0
        assert producers > 0 and consumers > 0
        assert economy.day_tick(state, store(), dev_of=dev_of) == []

    def test_moved_ports_report(self) -> None:
        """day_tick reports exactly the moved ports (the world is at steady
        state apart from lisbon)."""
        alg = seeded_allegiance()
        state = economy_state(alg)
        dev_of = dev_real(alg)
        flow_ticks(state, alg, 30)
        capacity = economy.capacity_of(store(), "lisbon", "wine",
                                       dev_of=dev_of)
        refill = economy.dev_rate(economy.prod_rate(
            economy.build_tiers(store().goods_list), "wine"), 3)
        economy.set_stock(state, "lisbon", "wine", capacity - 2 * refill)
        moved = economy.day_tick(state, store(), dev_of=dev_of)
        assert moved == ["lisbon"]
        assert economy.stock_of(state, store(), "lisbon", "wine",
                                dev_of=dev_of) == capacity - refill

    def test_recovery_pacing(self) -> None:
        """A max-hold sale dumps into a consumer; the stock recovers to
        within 10% of steady state (factor ≥ 1350 at quanzhou wine) in
        exactly 18 days, inside the 30-day gate."""
        alg = seeded_allegiance()
        state = economy_state(alg)
        dev_of = dev_real(alg)
        flow_ticks(state, alg, 30)
        assert economy.stock_of(state, store(), "quanzhou", "wine",
                                dev_of=dev_of) == 0
        economy.apply_trade(state, store(), "quanzhou", "wine", -120,
                            dev_of=dev_of)
        assert economy.stock_of(state, store(), "quanzhou", "wine",
                                dev_of=dev_of) == 120
        recovered = -1
        for tick in range(30):
            flow_ticks(state, alg, 1)
            if economy.factor_units(state, store(), "quanzhou", "wine",
                                    dev_of=dev_of) >= 1350:
                recovered = tick + 1
                break
        assert recovered == 18
        assert 0 < recovered <= 30

    def test_stock_determinism(self) -> None:
        """Two fresh runs of the SAME world tick identically, stock for
        stock (same seed → same ticks)."""
        runs = []
        for _ in range(2):
            alg = seeded_allegiance()
            state = economy_state(alg)
            flow_ticks(state, alg, 20)
            runs.append(
                {pid: dict(row) for pid, row in state.market_stocks.items()})
        assert runs[0] == runs[1]


# ============================================================================
# economy — §4.5 demand-event surges
# ============================================================================


class TestSurges:
    def test_unit_effect_binds_one_port_good(self) -> None:
        """The surge pins are dev-explicit like the GDScript's: the dev-0
        world makes the ×3 multiplier exact (15/day). The surge binds one
        port-good — production and other ports keep the plain rate."""
        state = economy_state_dev0(day=1)
        economy.set_consumption_surge(state, "london", "wine", 6)
        assert economy.consumption_surged(state, "london", "wine")
        assert economy.cons_rate_effective(state, store(), "london",
                                           "wine") == 15  # 5 × 3
        assert economy.cons_rate_effective(state, store(), "lisbon",
                                           "wine") == 5
        assert economy.cons_rate_effective(state, store(), "london",
                                           "salt") == 5
        # The surged drain lands: 60 → 45 in one day.
        flow_ticks_dev0(state, 1)
        assert economy.stock_of(state, store(), "london", "wine") == 45

    def test_production_ignores_the_surge(self) -> None:
        state = economy_state_dev0(day=1)
        economy.set_consumption_surge(state, "quanzhou", "porcelain", 6)
        economy.set_stock(state, "quanzhou", "porcelain", 100)
        flow_ticks_dev0(state, 1)
        assert economy.stock_of(state, store(), "quanzhou", "porcelain") \
            == 102  # 100 → 102 at the plain 2/day
        # The drain still floors at 0 under a surge.
        economy.set_stock(state, "london", "wine", 0)
        economy.set_consumption_surge(state, "london", "wine", 6)
        flow_ticks_dev0(state, 1)
        assert economy.stock_of(state, store(), "london", "wine") == 0

    def test_expiry_and_reset(self) -> None:
        """Active strictly before until_day, expired on until_day; the
        reset seam empties the transient table."""
        state = economy_state_dev0(day=1)
        economy.set_stock(state, "london", "wine", 60)
        economy.set_consumption_surge(state, "london", "wine", 3)
        assert economy.consumption_surged(state, "london", "wine", 2)
        assert not economy.consumption_surged(state, "london", "wine", 3)
        assert economy.cons_rate_effective(state, store(), "london", "wine",
                                           3) == 5
        economy.set_consumption_surge(state, "london", "wine", 10)
        economy.reset_overrides(state)
        assert economy.cons_rate_effective(state, store(), "london",
                                           "wine") == 5

    def test_dev_composition(self) -> None:
        """The ×3 surge composes with dev (integer math): at dev 2 the
        surged staple consumes 15 × 6/4 = 22/day — 60 → 38 in one day. The
        pre-dev surged rate stays 15."""
        state = economy.EconomyState(day=1)
        state.market_stocks = {"london": {"wine": 60}}
        economy.set_consumption_surge(state, "london", "wine", 6)
        tiers = economy.build_tiers(store().goods_list)
        assert economy.cons_rate_effective(state, store(), "london",
                                           "wine", tiers=tiers) == 15
        economy.day_tick(state, store(), dev_of=lambda port_id: 2)
        assert state.market_stocks["london"]["wine"] == 38


class TestEventTemplates:
    def test_war_provisioning_path(self) -> None:
        """A real ``market_events.json`` instance re-applies its
        rate_override; the telegraph appears in the affected nation's ports
        only; expiry at start + duration drops the instance and restores
        the plain rate (the GDScript's pinned template path)."""
        alg = seeded_allegiance()
        state = economy_state(alg, day=100)
        state.market_events.append({
            "template_id": "evt_war_provisioning",
            "port_id": "seville",
            "start_day": 100,
        })
        economy.ensure_event_overrides(state, store(), 100)
        assert economy.cons_rate_effective(state, store(), "seville",
                                           "timber", 100) == 15
        assert economy.cons_rate_effective(state, store(), "seville",
                                           "iron", 100) == 15
        telegraphs = economy.event_telegraphs(state, store(), "seville", 100)
        assert len(telegraphs) == 1
        template = telegraphs[0]["template"]
        assert template.get("rate_override") == ["timber", "iron"]
        assert "shifts" not in template  # the retired Phase-5 shape is gone
        foreign = economy.event_telegraphs(state, store(), "lisbon", 100)
        assert all(row["template"].get("id") != "evt_war_provisioning"
                   for row in foreign)
        # Expiry at start + duration (100 + 60 = 160).
        state.day = 160
        economy.market_events_tick(state, store(), 160)
        assert state.market_events == []
        assert economy.cons_rate_effective(state, store(), "seville",
                                           "timber") == 5
        # Budget constants keep their meaning (docs/30 §4.5).
        assert economy.EVENTS_PER_NATION_MAX == 1
        assert economy.EVENTS_WORLD_MAX == 4

    def test_instance_shape(self) -> None:
        """Active instances are exactly ``{template_id, port_id,
        start_day}`` (docs/10 §4.15)."""
        alg = seeded_allegiance()
        state = economy_state(alg, day=100)
        state.market_events.append({
            "template_id": "evt_war_provisioning",
            "port_id": "seville",
            "start_day": 100,
        })
        economy.ensure_event_overrides(state, store(), 100)
        assert set(state.market_events[0].keys()) \
            == {"template_id", "port_id", "start_day"}


# ============================================================================
# economy — §4.5 the seeded rotation (golden schedule from Godot 4.7)
# ============================================================================


class TestEventRotation:
    def run_schedule(self) -> list[str]:
        state = economy.EconomyState()
        out = []
        for day in range(1, 361):
            for instance in economy.market_events_tick(state, store(), day):
                out.append("%s@%s@%d" % (instance["template_id"],
                                         instance["port_id"],
                                         instance["start_day"]))
        return out

    def test_golden_schedule(self) -> None:
        """The exact 360-day rotation captured from the pinned Godot
        4.7 toolchain (the String.hash + PCG32 seed formula replays
        identically)."""
        assert self.run_schedule() == GOLDEN_EVENT_SCHEDULE

    def test_replay_determinism(self) -> None:
        """The seeded schedule replays exactly: two full re-creations in
        the same process agree (the GDScript determinism pin)."""
        assert self.run_schedule() == self.run_schedule()

    def test_budget_respected(self) -> None:
        """≤ 1 active event per nation, ≤ 4 world-wide, at every day of a
        full replay."""
        state = economy.EconomyState()
        for day in range(1, 361):
            economy.market_events_tick(state, store(), day)
            active = []
            for instance in state.market_events:
                template = store().get_market_event(
                    str(instance["template_id"]))
                duration = int(template.get("duration_days", 0))
                if duration > 0 and day < instance["start_day"] + duration:
                    active.append(instance)
            assert len(active) <= economy.EVENTS_WORLD_MAX
            seen: set[str] = set()
            for instance in active:
                nation = str(store().get_port(
                    str(instance["port_id"])).get("nation_id", ""))
                assert nation not in seen
                seen.add(nation)


# ============================================================================
# economy — §4.2 market direction + §4.4 tranche walks (the trade seam)
# ============================================================================


class TestMarketDirection:
    def test_direction_pins(self) -> None:
        """A producing port never buys its own produced good (不收购); a
        demanding port buys; unlisted goods never trade."""
        s = store()
        assert economy.is_produced_at(s, "lisbon", "wine")
        assert not economy.port_buys_good(s, "lisbon", "wine")
        assert economy.port_buys_good(s, "london", "wine")
        assert not economy.is_listed(s, "valencia", "porcelain")
        assert not economy.port_buys_good(s, "valencia", "porcelain")
        assert economy.is_listed(s, "london", "wine")


class TestTrancheWalks:
    def test_lisbon_buy_30(self) -> None:
        """docs/30 §4.4 worked example: 30 wine bought at Lisbon from
        stock 160 walks 700/750/800 → 21/22/24; apply books 160 → 130."""
        alg = seeded_allegiance()
        state = economy_state(alg)
        economy.set_stock(state, "lisbon", "wine", 160)
        walk = economy.plan_trade(state, store(), "lisbon", "wine", 30)
        assert [t["stock_before"] for t in walk] == [160, 150, 140]
        assert [t["factor_units"] for t in walk] == [700, 750, 800]
        assert [trade.price_from_units(30, t["factor_units"], False)
                for t in walk] == [21, 22, 24]
        booked = economy.apply_trade(state, store(), "lisbon", "wine", 30)
        assert economy.stock_of(state, store(), "lisbon", "wine") == 130
        assert len(booked) == 3

    def test_partial_and_signed_walks(self) -> None:
        alg = seeded_allegiance()
        state = economy_state(alg)
        economy.set_stock(state, "lisbon", "wine", 160)
        partial = economy.plan_trade(state, store(), "lisbon", "wine", 25)
        assert partial[2]["units"] == 5  # 25 = 10 + 10 + 5
        assert economy.plan_trade(state, store(), "lisbon", "wine", 0) == []
        # qty_signed direction: a negative quantity RAISES stock (sell).
        economy.set_stock(state, "lisbon", "wine", 100)
        economy.apply_trade(state, store(), "lisbon", "wine", -20)
        assert economy.stock_of(state, store(), "lisbon", "wine") == 120

    def test_delegation_identity_with_trade(self) -> None:
        """The flagged seam: economy.plan_trade reads the stock table and
        delegates the walk — the entries are trade.plan_trade's exactly."""
        alg = seeded_allegiance()
        state = economy_state(alg)
        for stock, qty in [(160, 30), (160, -30), (40, -300), (5, 10),
                           (0, 250)]:
            economy.set_stock(state, "lisbon", "wine", stock)
            assert economy.plan_trade(state, store(), "lisbon", "wine",
                                      qty) == trade.plan_trade(stock, qty)

    def test_doc_300_unit_case(self) -> None:
        """docs/30 §4.4: 300 wine sold into London at stock 40 — 30
        tranches, 16 distinct prices before the stock parks at 200,
        continuously (13 → 12, no clamp jump), exact summed proceeds
        5,170g, never the 9,300g flat."""
        alg = seeded_allegiance()
        state = economy_state(alg)
        economy.set_stock(state, "london", "wine", 40)
        walk = economy.plan_trade(state, store(), "london", "wine", -300)
        assert len(walk) == 30
        prices = [trade.price_from_units(30, t["factor_units"], True)
                  for t in walk]
        assert prices[:16] == [31, 30, 28, 27, 26, 25, 24, 22, 21, 20, 19,
                               18, 16, 15, 14, 13]
        for index in range(16, 30):
            assert walk[index]["stock_before"] == 200
            assert walk[index]["factor_units"] == 500
            assert prices[index] == 12
        assert prices[15] == 13 and prices[16] == 12
        proceeds = sum(price * t["units"]
                       for price, t in zip(prices, walk))
        assert proceeds == 5170
        economy.apply_trade(state, store(), "london", "wine", -300)
        assert economy.stock_of(state, store(), "london", "wine") == 200


class TestPinnedScenario:
    """tools/test_economy.gd §13 — the pinned quanzhou scenario (re-asserted
    by tools/sim_trade.py's parity block): porcelain (specialty, flow prod
    2 / cons 3 / capacity 120, base 130); wine (staple, base 30, consumer)."""

    def test_quanzhou_numbers(self) -> None:
        s = store()
        alg = seeded_allegiance()
        state = economy_state(alg)
        dev_of = dev_real(alg)
        assert economy.capacity_of(s, "quanzhou", "porcelain",
                                   dev_of=dev_of) == 120
        assert economy.stock_of(state, s, "quanzhou", "porcelain",
                                dev_of=dev_of) == 120
        assert economy.stock_of(state, s, "quanzhou", "wine",
                                dev_of=dev_of) == 60
        # One day tick at dev 0: producer clamps at capacity, consumer
        # drains 5.
        moved = economy.day_tick(state, s, dev_of=dev_of)
        economy.reset_events(state)
        assert "quanzhou" in moved
        assert economy.stock_of(state, s, "quanzhou", "porcelain",
                                dev_of=dev_of) == 120
        assert economy.stock_of(state, s, "quanzhou", "wine",
                                dev_of=dev_of) == 55
        assert economy.factor_units(state, s, "quanzhou", "porcelain",
                                    dev_of=dev_of) == 900
        assert trade.price_from_units(130, 900, False) == 117
        assert economy.factor_units(state, s, "quanzhou", "wine",
                                    dev_of=dev_of) == 1225
        assert trade.price_from_units(30, 1225, False) == 36
        assert trade.price_from_units(30, 1225, True) == 29
        # Drained after 12 ticks: starved-consumer pricing.
        flow_ticks(state, alg, 12)
        assert economy.stock_of(state, s, "quanzhou", "wine",
                                dev_of=dev_of) == 0
        assert economy.factor_units(state, s, "quanzhou", "wine",
                                    dev_of=dev_of) == 1500
        assert trade.price_from_units(30, 1500, False) == 45
        assert trade.price_from_units(30, 1500, True) == 36
        # Surge day: ×3 consumption drains 60 → 45 (factor 1275, buy 38).
        state = economy_state(alg)
        economy.set_consumption_surge(state, "quanzhou", "wine",
                                      state.day + 30)
        economy.day_tick(state, s, dev_of=dev_of)
        economy.reset_overrides(state)
        assert economy.stock_of(state, s, "quanzhou", "wine",
                                dev_of=dev_of) == 45
        assert economy.factor_units(state, s, "quanzhou", "wine",
                                    dev_of=dev_of) == 1275
        assert trade.price_from_units(30, 1275, False) == 38


# ============================================================================
# allegiance — §4.9 seed state
# ============================================================================


class TestSeedNewGame:
    def test_protected_ports(self) -> None:
        """Protected: alignment = owner forever, dev = authored floor
        forever, never a ledger."""
        s = store()
        alg = seeded_allegiance()
        for port_id in ["lisbon", "oporto", "london", "venice", "istanbul"]:
            port = s.get_port(port_id)
            assert allegiance.is_protected(s, port_id)
            assert allegiance.effective_alignment(s, alg, port_id) \
                == str(port.get("nation_id", ""))
            assert allegiance.dev(s, alg, port_id) \
                == int(port.get("dev", 0))
            assert allegiance.ledger_of(s, alg, port_id, "portugal") == 0
            assert allegiance.ledger_total(alg, port_id) == 0
            assert allegiance.port_ledger(alg, port_id) == {}

    def test_sovereign_and_neutral(self) -> None:
        """Contestable sovereign ``{owner: 6000}`` (allied, 7,500
        effective, below dev-1's 10,000g); neutral empty at dev floor 0."""
        s = store()
        alg = seeded_allegiance()
        assert allegiance.effective_alignment(s, alg, "madeira") == "portugal"
        assert allegiance.ledger_of(s, alg, "madeira", "portugal") == 6000
        assert allegiance.ledger_total(alg, "madeira") == 6000
        assert allegiance.effective_value(s, alg, "madeira", "portugal") \
            == 7500
        assert allegiance.dev(s, alg, "madeira") == 1
        assert allegiance.effective_alignment(s, alg, "quanzhou") == ""
        assert allegiance.ledger_total(alg, "quanzhou") == 0
        assert allegiance.dev(s, alg, "quanzhou") == 0

    def test_treasuries_and_coverage(self) -> None:
        alg = seeded_allegiance()
        for nation_id in NATIONS:
            assert allegiance.treasury(alg, nation_id) == 5000
        dump = allegiance.dump_state(alg)
        contestable = [str(p.get("id", "")) for p in store().ports_list
                       if not p.get("protected", False)]
        assert len(contestable) == 133
        for port_id in contestable:
            assert port_id in dump["port_allegiance"]
        assert set(dump.keys()) == {"port_allegiance", "month_invested",
                                    "nation_treasuries", "fame_commended",
                                    "permits"}


# ============================================================================
# allegiance — ledger & allegiance resolution
# ============================================================================


class TestLedgerResolution:
    def test_alignment_line_and_tie_rule(self) -> None:
        """Strictly the highest effective ledger ≥ 5,000g wins; ties keep
        the incumbent."""
        s = store()
        st = make_player("portugal")
        alg = seeded_allegiance()
        allegiance.add_investment(s, alg, st, "quanzhou", "portugal", 4999)
        assert allegiance.effective_alignment(s, alg, "quanzhou") == ""
        allegiance.add_investment(s, alg, st, "quanzhou", "portugal", 1)
        assert allegiance.effective_alignment(s, alg, "quanzhou") == "portugal"
        allegiance.add_investment(s, alg, st, "quanzhou", "holland", 5000)
        assert allegiance.effective_alignment(s, alg, "quanzhou") == "portugal"
        allegiance.add_investment(s, alg, st, "quanzhou", "holland", 1)
        assert allegiance.effective_alignment(s, alg, "quanzhou") == "holland"

    def test_sovereign_home_advantage(self) -> None:
        """The owner's ×1.25 (integer 5/4): 7,500 foreign does not tie the
        owner's 7,500 effective; 7,501 flips."""
        s = store()
        st = make_player("portugal")
        alg = seeded_allegiance()
        allegiance.add_investment(s, alg, st, "madeira", "ottoman", 7500)
        assert allegiance.effective_alignment(s, alg, "madeira") == "portugal"
        allegiance.add_investment(s, alg, st, "madeira", "ottoman", 1)
        assert allegiance.effective_alignment(s, alg, "madeira") == "ottoman"
        assert allegiance.effective_value(s, alg, "madeira", "portugal") \
            == 7500
        assert allegiance.effective_value(s, alg, "madeira", "ottoman") \
            == 7501

    def test_ledger_accumulates(self) -> None:
        s = store()
        st = make_player("portugal")
        alg = seeded_allegiance()
        allegiance.add_investment(s, alg, st, "malacca", "portugal", 500)
        allegiance.add_investment(s, alg, st, "malacca", "portugal", 500)
        assert allegiance.ledger_of(s, alg, "malacca", "portugal") == 7000

    def test_dev_thresholds_boundary(self) -> None:
        """Neutral floor 0: dev 1 at ≥ 10,000g total, 2 at 25,000, 3 at
        50,000 — each boundary value exact."""
        s = store()
        st = make_player("portugal")
        alg = seeded_allegiance()
        allegiance.add_investment(s, alg, st, "quanzhou", "portugal", 9999)
        assert allegiance.dev(s, alg, "quanzhou") == 0
        allegiance.add_investment(s, alg, st, "quanzhou", "portugal", 1)
        assert allegiance.dev(s, alg, "quanzhou") == 1
        allegiance.add_investment(s, alg, st, "quanzhou", "holland", 14999)
        assert allegiance.dev(s, alg, "quanzhou") == 1
        allegiance.add_investment(s, alg, st, "quanzhou", "holland", 1)
        assert allegiance.dev(s, alg, "quanzhou") == 2
        allegiance.add_investment(s, alg, st, "quanzhou", "spain", 25000)
        assert allegiance.dev(s, alg, "quanzhou") == 3

    def test_authored_floor_holds(self) -> None:
        """The total counts every nation's gold; the authored floor holds
        below the thresholds and never shrinks."""
        s = store()
        st = make_player("portugal")
        alg = seeded_allegiance()
        assert allegiance.dev(s, alg, "malacca") == 2
        allegiance.add_investment(s, alg, st, "malacca", "portugal", 4000)
        assert allegiance.dev(s, alg, "malacca") == 2  # 10,000 total
        allegiance.add_investment(s, alg, st, "malacca", "holland", 15000)
        assert allegiance.dev(s, alg, "malacca") == 2  # 25,000 total
        allegiance.add_investment(s, alg, st, "malacca", "holland", 25001)
        assert allegiance.dev(s, alg, "malacca") == 3  # 50,001 total

    def test_dump_entry_shape(self) -> None:
        """Dev is derived, never saved: the persisted port entry is exactly
        {ledger, allegiance} (correction 8)."""
        s = store()
        st = make_player("portugal")
        alg = seeded_allegiance()
        allegiance.add_investment(s, alg, st, "malacca", "portugal", 500)
        entry = allegiance.dump_state(alg)["port_allegiance"]["malacca"]
        assert set(entry.keys()) == {"ledger", "allegiance"}


# ============================================================================
# allegiance — protected immunity, the monthly cap & the diplomatic gate
# ============================================================================


class TestInvestGates:
    def test_protected_immunity(self) -> None:
        """The AI never invests at a protected port (no ledger appears,
        ever); the player's protected chunk is discount-only — no ledger,
        no monthly allowance (the trade engine skips the chunk there); the
        dev floor never grows."""
        s = store()
        st = make_player("portugal", day=31)
        alg = seeded_allegiance()
        allegiance.month_tick(s, alg, st)
        for row in allegiance.last_month_investments(alg, st):
            assert not allegiance.is_protected(s, str(row["port_id"]))
        for port_id in ["lisbon", "london", "venice"]:
            assert allegiance.ledger_total(alg, port_id) == 0
        # add_investment at a protected port is a no-op (the single ledger
        # entry point refuses it).
        allegiance.add_investment(s, alg, st, "lisbon", "portugal", 5000)
        assert allegiance.ledger_total(alg, "lisbon") == 0
        assert allegiance.month_invested_gold(alg, "lisbon") == 0
        assert allegiance.dev(s, alg, "lisbon") == 3

    def test_monthly_cap(self) -> None:
        """madeira: own contestable sovereign — 4 × 500g per month, the 5th
        chunk refused with ``market.invest_gate.exhausted``; the month tick
        resets the allowance."""
        s = store()
        st = make_player("portugal")
        alg = seeded_allegiance()
        for click in range(4):
            assert allegiance.invest_block_reason(s, alg, st, {},
                                                  "madeira") == ""
            allegiance.player_invest_chunk(s, alg, st, "madeira")
        assert allegiance.month_invested_gold(alg, "madeira") == 2000
        assert allegiance.ledger_of(s, alg, "madeira", "portugal") == 8000
        assert allegiance.invest_block_reason(s, alg, st, {}, "madeira") \
            == "market.invest_gate.exhausted"
        st.day = 31
        allegiance.month_tick(s, alg, st)
        assert allegiance.month_invested_gold(alg, "madeira") == 0
        assert allegiance.invest_block_reason(s, alg, st, {}, "madeira") \
            == ""

    def test_diplomatic_gate(self) -> None:
        """Investing requires rep ≥ 0 with the alignment nation and no
        active bounty from them; an unaligned contestable port has no gate
        at all."""
        s = store()
        st = make_player("portugal")
        alg = seeded_allegiance()
        assert allegiance.invest_block_reason(s, alg, st, {}, "london") == ""
        character.add_reputation(st, "england", -1)
        assert allegiance.invest_block_reason(s, alg, st, {}, "london") \
            == "market.invest_gate.blocked"
        character.add_reputation(st, "england", 1)
        bounties: dict[str, Any] = {"england": {"amount": 5000, "day": 1}}
        assert allegiance.invest_block_reason(s, alg, st, bounties,
                                              "london") \
            == "market.invest_gate.blocked"
        assert allegiance.invest_block_reason(s, alg, st, {}, "london") == ""
        # Unaligned quanzhou: holland's opinion is irrelevant.
        character.add_reputation(st, "holland", -100)
        hostile = {"holland": {"amount": 5000, "day": 1}}
        assert allegiance.effective_alignment(s, alg, "quanzhou") == ""
        assert allegiance.invest_block_reason(s, alg, st, hostile,
                                              "quanzhou") == ""

    def test_player_chunk_reaches_the_ledger(self) -> None:
        """The §4.3 ledger effect: each 500g chunk adds +500g to the
        player-nation's ledger at a contestable port."""
        s = store()
        st = make_player("spain")
        alg = seeded_allegiance()
        allegiance.player_invest_chunk(s, alg, st, "quanzhou")
        assert allegiance.ledger_of(s, alg, "quanzhou", "spain") == 500
        assert allegiance.month_invested_gold(alg, "quanzhou") == 500


# ============================================================================
# allegiance — the monthly NPC counter-investment (golden seeds)
# ============================================================================


def ai_rows(alg: allegiance.AllegianceState, st: PersonState) -> list[str]:
    return ["%s@%s=%d" % (row["nation_id"], row["port_id"], row["amount"])
            for row in allegiance.last_month_investments(alg, st)]


class TestCounterInvestment:
    def test_golden_month_31(self) -> None:
        """The exact month-31 sequence captured from the pinned Godot 4.7
        toolchain, and the treasury flow: every treasury lands at
        5,000 + 1,000 − 2 × 1,500 = 3,000."""
        s = store()
        st = make_player("portugal", day=31)
        alg = seeded_allegiance()
        allegiance.month_tick(s, alg, st)
        assert ai_rows(alg, st) == GOLDEN_AI_MONTH_31
        for nation_id in NATIONS:
            assert allegiance.treasury(alg, nation_id) == 3000

    def test_golden_month_61(self) -> None:
        """Month 61's seed differs → a different exact sequence."""
        s = store()
        st = make_player("portugal", day=61)
        alg = seeded_allegiance()
        allegiance.month_tick(s, alg, st)
        assert ai_rows(alg, st) == GOLDEN_AI_MONTH_61

    def test_determinism(self) -> None:
        """Same state → identical month-31 sequence and identical
        post-tick treasuries (the pure seed formula)."""
        treasuries = []
        for _ in range(2):
            s = store()
            st = make_player("portugal", day=31)
            alg = seeded_allegiance()
            allegiance.month_tick(s, alg, st)
            rows = ai_rows(alg, st)
            assert rows == GOLDEN_AI_MONTH_31
            treasuries.append(dict(alg.treasuries))
        assert treasuries[0] == treasuries[1]

    def test_bounds(self) -> None:
        """≤ 2 picks per nation, each ≤ min(treasury, 1,500)g; candidates
        are sphere ports, never protected, and never the nation's own
        dev-3 holdings."""
        s = store()
        st = make_player("portugal", day=31)
        alg = seeded_allegiance()
        allegiance.month_tick(s, alg, st)
        per_nation: dict[str, int] = {}
        for row in allegiance.last_month_investments(alg, st):
            nation_id = str(row["nation_id"])
            per_nation[nation_id] = per_nation.get(nation_id, 0) + 1
            spend = int(row["amount"])
            assert 0 < spend <= 1500
            port_id = str(row["port_id"])
            assert not allegiance.is_protected(s, port_id)
            assert nation_id in s.get_port(port_id).get("sphere", [])
            holder = allegiance.effective_alignment(s, alg, port_id)
            if holder == nation_id:
                assert allegiance.dev(s, alg, port_id) < 3
        assert all(count <= 2 for count in per_nation.values())

    def test_treasury_bounded_spend(self) -> None:
        """A nation whose window opens at 0 gets the 1,000g baseline — its
        picks spend min(treasury, 1,500)g each and the purse books exactly
        its picks."""
        s = store()
        st = make_player("portugal", day=31)
        alg = seeded_allegiance()
        drained = allegiance.dump_state(alg)["nation_treasuries"]
        drained["holland"] = 0
        allegiance.restore_state(s, alg, {"nation_treasuries": drained})
        allegiance.month_tick(s, alg, st)
        holland_spent = sum(int(row["amount"])
                            for row in allegiance.last_month_investments(
                                alg, st)
                            if str(row["nation_id"]) == "holland")
        assert allegiance.treasury(alg, "holland") == 1000 - holland_spent
        assert holland_spent in (0, 1000, 2000)


# ============================================================================
# allegiance — §2.6 fame, poaching, commendation
# ============================================================================


class TestFamePoaching:
    def test_first_flip_and_poaching(self) -> None:
        """Spain poaches a Portuguese sovereign port: the tie keeps
        portugal (no flip, no fame); 7,501 foreign gold flips → +100 fame
        (once per port per save), −5 rep with the previous owner, the
        commendation pending."""
        s = store()
        st = make_player("spain")
        alg = seeded_allegiance()
        assert st.fame == 0
        allegiance.add_investment(s, alg, st, "madeira", "spain", 7500)
        assert allegiance.effective_alignment(s, alg, "madeira") == "portugal"
        assert st.fame == 0
        allegiance.add_investment(s, alg, st, "madeira", "spain", 1)
        assert allegiance.effective_alignment(s, alg, "madeira") == "spain"
        assert st.fame == 100
        assert allegiance.dump_state(alg)["fame_commended"].get("madeira") \
            is True
        assert character.reputation(st, "portugal") == -5
        pending = allegiance.pending_commendation(alg, st)
        assert pending == {"port_id": "madeira", "nation_id": "spain"}

    def test_losing_back_costs_nothing_re_flip_poaches_again(self) -> None:
        """Losing the port back costs nothing; re-taking it poaches again
        (−5 per flip) but never re-awards the +100. The owner's ×1.25
        grows with its ledger: portugal 6,500 raw → 8,125 effective, so
        spain needs > 8,125."""
        s = store()
        st = make_player("spain")
        alg = seeded_allegiance()
        allegiance.add_investment(s, alg, st, "madeira", "spain", 7501)
        allegiance.mark_commendation_shown(alg)
        allegiance.add_investment(s, alg, st, "madeira", "portugal", 500)
        assert allegiance.effective_alignment(s, alg, "madeira") == "portugal"
        assert st.fame == 100
        allegiance.add_investment(s, alg, st, "madeira", "spain", 700)
        assert allegiance.effective_alignment(s, alg, "madeira") == "spain"
        assert character.reputation(st, "portugal") == -10
        assert st.fame == 100

    def test_neutral_flip_no_poaching(self) -> None:
        """A neutral port: no sovereign owner, no poaching rep — but the
        first flip still commends (shown once, then gone)."""
        s = store()
        st = make_player("spain")
        alg = seeded_allegiance()
        allegiance.add_investment(s, alg, st, "quanzhou", "spain", 6000)
        assert st.fame == 100
        assert character.reputation(st, "portugal") == 0
        assert allegiance.pending_commendation(alg, st) != {}
        allegiance.mark_commendation_shown(alg)
        assert allegiance.pending_commendation(alg, st) == {}

    def test_dev_threshold_fame(self) -> None:
        """+25 per level reached at a port aligned to the player's nation,
        tracked per port, never retro-awarded: the flip's +100 is the only
        fame when dev 1 is crossed mid-flip."""
        s = store()
        st = make_player("spain")
        alg = seeded_allegiance()
        allegiance.add_investment(s, alg, st, "quanzhou", "holland", 6000)
        assert allegiance.effective_alignment(s, alg, "quanzhou") == "holland"
        assert st.fame == 0
        allegiance.add_investment(s, alg, st, "quanzhou", "spain", 6500)
        assert allegiance.effective_alignment(s, alg, "quanzhou") == "spain"
        fame_before = st.fame
        assert fame_before == 100
        assert allegiance.dev(s, alg, "quanzhou") == 1
        allegiance.add_investment(s, alg, st, "quanzhou", "spain", 7499)
        assert st.fame == fame_before
        assert allegiance.dev(s, alg, "quanzhou") == 1
        allegiance.add_investment(s, alg, st, "quanzhou", "spain", 5001)
        assert st.fame == fame_before + 25
        assert allegiance.dev(s, alg, "quanzhou") == 2
        allegiance.add_investment(s, alg, st, "quanzhou", "spain", 25000)
        assert st.fame == fame_before + 50
        assert allegiance.dev(s, alg, "quanzhou") == 3


# ============================================================================
# allegiance — §4.10 tariff matrix & permits
# ============================================================================


class TestTariffMatrix:
    def test_rate_matrix(self) -> None:
        """In sphere (alignment == trader): 500. Foreign: 2000. Unaligned:
        2000. Unknown port: 2000 (never exempt)."""
        s = store()
        st = make_player("portugal")
        bounties: dict[str, Any] = {}
        alg = seeded_allegiance()
        assert allegiance.tariff_mille(s, alg, st, bounties, "lisbon",
                                       "portugal") == 500
        assert allegiance.tariff_mille(s, alg, st, bounties, "london",
                                       "england") == 500
        assert allegiance.tariff_mille(s, alg, st, bounties, "london",
                                       "portugal") == 2000
        assert allegiance.tariff_mille(s, alg, st, bounties, "madeira",
                                       "portugal") == 500
        assert allegiance.tariff_mille(s, alg, st, bounties, "madeira",
                                       "holland") == 2000
        assert allegiance.tariff_mille(s, alg, st, bounties, "quanzhou",
                                       "portugal") == 2000
        assert allegiance.tariff_mille(s, alg, st, bounties, "nowhere",
                                       "portugal") == 2000

    def test_flip_moves_the_rate(self) -> None:
        """The flipped alignment moves the 5% with it."""
        s = store()
        st = make_player("portugal")
        bounties: dict[str, Any] = {}
        alg = seeded_allegiance()
        allegiance.add_investment(s, alg, st, "quanzhou", "holland", 6000)
        assert allegiance.tariff_mille(s, alg, st, bounties, "quanzhou",
                                       "holland") == 500
        allegiance.add_investment(s, alg, st, "quanzhou", "spain", 6001)
        assert allegiance.tariff_mille(s, alg, st, bounties, "quanzhou",
                                       "spain") == 500
        assert allegiance.tariff_mille(s, alg, st, bounties, "quanzhou",
                                       "holland") == 2000


class TestPermits:
    def test_home_charter(self) -> None:
        """The home charter zeroes own + aligned ports for the player,
        never a foreign or foreign-aligned port."""
        s = store()
        st = make_player("portugal")
        bounties: dict[str, Any] = {}
        alg = seeded_allegiance()
        allegiance.set_permit(alg, "home", "portugal")
        assert allegiance.has_permit_home(alg)
        assert allegiance.tariff_mille(s, alg, st, bounties, "lisbon",
                                       "portugal") == 0
        assert allegiance.tariff_mille(s, alg, st, bounties, "madeira",
                                       "portugal") == 0
        assert allegiance.tariff_mille(s, alg, st, bounties, "london",
                                       "portugal") == 2000
        allegiance.add_investment(s, alg, st, "quanzhou", "holland", 6000)
        assert allegiance.tariff_mille(s, alg, st, bounties, "quanzhou",
                                       "portugal") == 2000

    def test_home_charter_void_rules(self) -> None:
        """Void while the holder's bounty stands or rep < −20 — the exact
        ui_strings reasons, and the tariff falls back to 5%."""
        s = store()
        st = make_player("portugal")
        bounties: dict[str, Any] = {}
        alg = seeded_allegiance()
        allegiance.set_permit(alg, "home", "portugal")
        bounties["portugal"] = {"amount": 5000, "day": 1}
        assert allegiance.permit_void_reason(st, bounties, "portugal") \
            == "palace.permit.void_bounty"
        assert allegiance.permit_void(st, bounties, "portugal")
        assert allegiance.tariff_mille(s, alg, st, bounties, "lisbon",
                                       "portugal") == 500
        bounties = {}
        character.add_reputation(st, "portugal", -21)
        assert allegiance.permit_void_reason(st, bounties, "portugal") \
            == "palace.permit.void_rep"
        assert allegiance.tariff_mille(s, alg, st, bounties, "lisbon",
                                       "portugal") == 500
        character.add_reputation(st, "portugal", 21)
        assert allegiance.tariff_mille(s, alg, st, bounties, "lisbon",
                                       "portugal") == 0

    def test_foreign_permit(self) -> None:
        """The foreign permit zeroes that nation's ports for the player
        only; an NPC trader of the same nation still pays 5%; it voids on
        that nation's bounty and recovers when the bounty clears."""
        s = store()
        st = make_player("portugal")
        bounties: dict[str, Any] = {}
        alg = seeded_allegiance()
        allegiance.set_permit(alg, "foreign", "england")
        assert allegiance.has_permit_foreign(alg, "england")
        assert allegiance.tariff_mille(s, alg, st, bounties, "london",
                                       "portugal") == 0
        assert allegiance.tariff_mille(s, alg, st, bounties, "london",
                                       "england") == 500
        bounties["england"] = {"amount": 5000, "day": 1}
        assert allegiance.tariff_mille(s, alg, st, bounties, "london",
                                       "portugal") == 2000
        bounties = {}
        assert allegiance.tariff_mille(s, alg, st, bounties, "london",
                                       "portugal") == 0

    def test_permit_prices(self) -> None:
        """The Phase-8 negotiation gates: 5,000g / 20,000g below the gates,
        4,750g (negotiation ≥ 40) / 18,000g (≥ 70) above — the exact
        products, read through the store's skill_gates thresholds."""
        s = store()
        below = make_player("portugal")
        assert allegiance.negotiation_skill(below, s) == 0
        assert allegiance.permit_price(s, below, "home") == 5000
        assert allegiance.permit_price(s, below, "foreign") == 20000
        assert allegiance.permit_price(s, below, "") == 0
        at_home_gate = make_player("portugal")
        at_home_gate.player["skills"] = {"negotiation": 40}
        assert allegiance.permit_price(s, at_home_gate, "home") == 4750
        assert allegiance.permit_price(s, at_home_gate, "foreign") == 20000
        at_foreign_gate = make_player("portugal")
        at_foreign_gate.player["skills"] = {"negotiation": 70}
        assert allegiance.permit_price(s, at_foreign_gate, "foreign") \
            == 18000


# ============================================================================
# allegiance — the treasury crediting flow
# ============================================================================


class TestTaxCrediting:
    def test_player_uncapped_npc_capped(self) -> None:
        """Player-sourced tax flows to the alignment nation uncapped; an
        NPC payer's credit into a host is capped at 2,000g/host/month."""
        s = store()
        st = make_player("portugal")
        alg = seeded_allegiance()
        before = allegiance.treasury(alg, "portugal")
        assert before == 5000
        allegiance.credit_tax(s, alg, st, "lisbon", "portugal", 300)
        assert allegiance.treasury(alg, "portugal") == before + 300
        allegiance.credit_tax(s, alg, st, "lisbon", "england", 2500)
        assert allegiance.treasury(alg, "portugal") == before + 2300
        allegiance.credit_tax(s, alg, st, "lisbon", "holland", 1000)
        assert allegiance.treasury(alg, "portugal") == before + 2300

    def test_per_host_window_and_no_host_cases(self) -> None:
        """The cap is per host; unaligned hosts and nationless payers
        credit nothing."""
        s = store()
        st = make_player("portugal")
        alg = seeded_allegiance()
        england_before = allegiance.treasury(alg, "england")
        allegiance.credit_tax(s, alg, st, "london", "spain", 700)
        assert allegiance.treasury(alg, "england") == england_before + 700
        assert allegiance.effective_alignment(s, alg, "quanzhou") == ""
        portugal_before = allegiance.treasury(alg, "portugal")
        allegiance.credit_tax(s, alg, st, "quanzhou", "portugal", 500)
        assert allegiance.treasury(alg, "portugal") == portugal_before
        allegiance.credit_tax(s, alg, st, "lisbon", "", 500)
        assert allegiance.treasury(alg, "portugal") == portugal_before

    def test_month_tick_flow(self) -> None:
        """The month tick credits the baseline and spends through the AI:
        treasury == credits + 1,000 − AI spend, and the reopened NPC-tax
        window takes the next credit."""
        s = store()
        st = make_player("portugal", day=1)
        alg = seeded_allegiance()
        allegiance.credit_tax(s, alg, st, "lisbon", "portugal", 300)
        allegiance.credit_tax(s, alg, st, "lisbon", "england", 2500)
        window_credits = allegiance.treasury(alg, "portugal")
        st.day = 31
        allegiance.month_tick(s, alg, st)
        ai_spend = sum(int(row["amount"])
                       for row in allegiance.last_month_investments(alg, st)
                       if str(row["nation_id"]) == "portugal")
        assert allegiance.treasury(alg, "portugal") \
            == window_credits + 1000 - ai_spend
        allegiance.credit_tax(s, alg, st, "lisbon", "england", 500)
        assert allegiance.treasury(alg, "portugal") \
            == window_credits + 1000 - ai_spend + 500

    def test_permit_sale_credits(self) -> None:
        """A permit sale credits the selling nation, uncapped."""
        alg = seeded_allegiance()
        italy_before = allegiance.treasury(alg, "italy")
        allegiance.credit_permit_sale(alg, "italy", 20000)
        assert allegiance.treasury(alg, "italy") == italy_before + 20000


# ============================================================================
# allegiance — telegraphs (decision 24)
# ============================================================================


class TestTelegraphs:
    def test_row_shape_and_window(self) -> None:
        """Each row carries {nation_id, port_id, band, amount, day},
        stamped with the tick day; visible at +29 days, gone at +30."""
        s = store()
        st = make_player("portugal", day=31)
        alg = seeded_allegiance()
        allegiance.month_tick(s, alg, st)
        rows = allegiance.last_month_investments(alg, st)
        assert rows
        for row in rows:
            assert {"nation_id", "port_id", "band", "amount", "day"} \
                <= set(row.keys())
            assert int(row["day"]) == 31
            port = s.get_port(str(row["port_id"]))
            assert str(row["band"]) == str(port.get("band", ""))
        st.day = 60
        assert len(allegiance.last_month_investments(alg, st)) == len(rows)
        st.day = 61
        assert allegiance.last_month_investments(alg, st) == []


# ============================================================================
# allegiance — the persistence seam
# ============================================================================


class TestStateSeam:
    def test_dump_restore_round_trip(self) -> None:
        """Build a distinctive state (a flip, a crossed threshold, permits,
        tax credits, the monthly counter), dump, restore over a fresh seed:
        every derived answer must agree."""
        s = store()
        st = make_player("spain")
        alg = seeded_allegiance()
        allegiance.add_investment(s, alg, st, "quanzhou", "spain", 6000)
        allegiance.add_investment(s, alg, st, "quanzhou", "spain", 4000)
        assert st.fame == 125  # the flip's +100 and dev-1's +25
        allegiance.add_investment(s, alg, st, "malacca", "holland", 10000)
        allegiance.set_permit(alg, "home", "spain")
        allegiance.set_permit(alg, "foreign", "england")
        allegiance.credit_tax(s, alg, st, "lisbon", "england", 400)
        allegiance.player_invest_chunk(s, alg, st, "malacca")
        dump = allegiance.dump_state(alg)
        assert len(dump) == 5
        # Restore over a fresh seed.
        st2 = make_player("spain")
        alg2 = seeded_allegiance()
        assert st2.fame == 0  # fame is the caller's payload key, not ours
        allegiance.restore_state(s, alg2, dump)
        bounties: dict[str, Any] = {}
        assert allegiance.effective_alignment(s, alg2, "quanzhou") == "spain"
        assert allegiance.effective_alignment(s, alg2, "malacca") == "holland"
        assert allegiance.ledger_of(s, alg2, "malacca", "holland") == 10000
        assert allegiance.ledger_of(s, alg2, "malacca", "spain") == 500
        assert allegiance.ledger_total(alg2, "malacca") == 16500
        assert allegiance.dev(s, alg2, "malacca") == 2
        assert allegiance.tariff_mille(s, alg2, st2, bounties, "seville",
                                       "spain") == 0
        assert allegiance.tariff_mille(s, alg2, st2, bounties, "london",
                                       "spain") == 0
        assert allegiance.tariff_mille(s, alg2, st2, bounties, "lisbon",
                                       "spain") == 2000
        assert allegiance.month_invested_gold(alg2, "malacca") == 500
        assert allegiance.treasury(alg2, "portugal") == 5400
        assert allegiance.dump_state(alg2)["fame_commended"].get("quanzhou") \
            is True

    def test_threshold_tracker_rederived(self) -> None:
        """The threshold tracker re-derives on restore: quanzhou sits at
        10,000g (dev 1 already rewarded pre-dump), so crossing 25,000g
        awards +25 — exactly once; a stale tracker would award two levels'
        worth."""
        s = store()
        st = make_player("spain")
        alg = seeded_allegiance()
        allegiance.add_investment(s, alg, st, "quanzhou", "spain", 6000)
        allegiance.add_investment(s, alg, st, "quanzhou", "spain", 4000)
        dump = allegiance.dump_state(alg)
        st2 = make_player("spain")
        alg2 = seeded_allegiance()
        allegiance.restore_state(s, alg2, dump)
        assert allegiance.dev(s, alg2, "quanzhou") == 1
        allegiance.add_investment(s, alg2, st2, "quanzhou", "spain", 15000)
        assert allegiance.dev(s, alg2, "quanzhou") == 2
        assert st2.fame == 25
        allegiance.add_investment(s, alg2, st2, "quanzhou", "spain", 1)
        assert st2.fame == 25

    def test_restore_missing_payload_seeds(self) -> None:
        """A non-dict payload falls back to the seeded defaults."""
        s = store()
        alg = allegiance.AllegianceState()
        allegiance.restore_state(s, alg, None)
        assert allegiance.treasury(alg, "portugal") == 5000
        assert allegiance.effective_alignment(s, alg, "madeira") == "portugal"
