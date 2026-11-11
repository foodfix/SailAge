"""server.sim.port.allegiance — port allegiance, development, treasuries,
tariffs and permits (M1).

Python port of ``scripts/port/allegiance.gd`` (the frozen parity oracle
until the M6 cutover). Normative contract:

  * docs/30-PORTS-AND-TRADE.md §4.9 — the two port classes (decision 25:
    protected = owner forever, dev = authored floor forever, investment
    discount-only; contestable = per-nation cumulative gold ledger,
    allegiance = strictly the highest **effective** ledger ≥ 5,000g with
    the sovereign owner's ×1.25 home advantage and the tie rule keeping
    the incumbent, dev derived ``max(authored floor, ledger thresholds)`` —
    10,000 / 25,000 / 50,000 — never saved), the ≤ 2,000g/month player cap
    and the diplomatic gate (decision 26), the seeded monthly NPC
    counter-investment, the nation treasuries (5,000g start, +1,000/mo
    baseline + tax + permit sales, NPC-sourced tax capped 2,000g/host/mo)
    and the 30-day investment telegraphs (decision 24);
  * docs/30-PORTS-AND-TRADE.md §4.10 — the unified tariff: 5% when the
    effective alignment == the trader's nation, 20% otherwise, 0% under a
    valid covering permit; unaligned contestable ports 20% forever; both
    permit kinds void while that nation's bounty stands or rep < −20.
    **This module owns the rate RESOLUTION** (``tariff_mille``);
    ``server.sim.port.trade`` already applies the rate to the transaction
    totals after all price math — the same seam the GDScript's
    ``AllegianceLib.tariff_mille`` call sits behind;
  * docs/30-PORTS-AND-TRADE.md §4.3 — the investment ledger effect (+500g
    to the player-nation's ledger per 500g chunk at a contestable port);
  * docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.1 — the allegiance fame
    paragraph (+100 first flip, +25 per dev threshold at an aligned port);
  * docs/90-ARCHITECTURE.md §5.4 — the month-tick ordering pin: ONE seam,
    ONE owner. The day ledger calls economy's day step first, then, when
    the day crosses a month boundary (30-day months), THIS module's
    :func:`month_tick` — which resets ``month_invested``, credits each
    nation's baseline income, resolves the seeded NPC counter-investment
    and refreshes the telegraph windows. No other module performs
    month-boundary allegiance work.

Oracle files: ``scripts/port/allegiance.gd`` (line-by-line reference),
``tools/test_allegiance.gd`` (the pinned scenarios), and the golden
month-31/61 counter-investment sequences captured from the pinned Godot
4.7 toolchain (asserted in ``server/tests/test_economy.py``).

State convention (the M1 port rule for autoload-coupled statics): the
GDScript statics are the runtime home of the ledgers, persisted
allegiances, monthly counter, treasuries, permit flags, first-flip fame
ledger and telegraph ring buffer; here the caller owns one
:class:`AllegianceState` and every stateful function takes it. The
player-linked reads (``GameState.player.nation_id``, ``GameState.day``,
fame, reputation, bounties, the negotiation skill) come from the caller's
:class:`~server.sim.player.PersonState` (``st``) and ``bounties`` dict —
exactly the GameState fields the GDScript touched; fame/reputation hooks
mutate ``st`` in place through :mod:`server.sim.player.fame` /
:mod:`server.sim.player.character`, so the caller's events (WS ``event``
frames, ``90-*`` §0.3) derive from the returned deltas.

Determinism: the monthly NPC counter-investment is a pure function of
(month index, nation ordinals, candidate ordinals, treasury state) — the
seed formula ``month_index × 1000003 + nation_ordinal × 7919 +
port_ordinal × 104729`` (docs/30 §4.9), every candidate list sorted by id,
and the per-candidate draw ``randi_range(1, 3)`` against the lane-adjacency
weight through :class:`~server.sim.rng.GodotRng` (bit-exact PCG32). The
same state always replays the same investment sequence.

Lane adjacency reads the built route artifact's spokes joined with the
lane ``nations`` of ``data/trade_routes.json`` — the Python store already
loads the authored lanes (:attr:`DataStore.trade_routes_list`), so the
GDScript's raw file re-read collapses to a store read (the sources remain
the single truth, docs/10 §4.14).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Final

from server.sim.data import DataStore
from server.sim.player import PersonState, character, fame, skills
from server.sim.rng import GodotRng

__all__ = [
    "AllegianceState",
    "EFFECTIVE_NUM",
    "EFFECTIVE_DEN",
    "ALIGNMENT_MIN_GOLD",
    "DEV_THRESHOLD_1",
    "DEV_THRESHOLD_2",
    "DEV_THRESHOLD_3",
    "SEED_OWNER_LEDGER",
    "TREASURY_START",
    "TREASURY_BASELINE",
    "NPC_TAX_MONTHLY_CAP",
    "AI_PICKS_MAX",
    "AI_SPEND_CAP",
    "AI_SEED_MONTH_MULT",
    "AI_SEED_NATION_MULT",
    "AI_SEED_PORT_MULT",
    "AI_WEIGHT_BASE",
    "AI_WEIGHT_LANE",
    "AI_WEIGHT_SIDES",
    "TELEGRAPH_WINDOW_DAYS",
    "TELEGRAPH_BUFFER_MAX",
    "TARIFF_SCALE",
    "TARIFF_ALIGNED",
    "TARIFF_FOREIGN",
    "TARIFF_EXEMPT",
    "PERMIT_HOME_PRICE",
    "PERMIT_FOREIGN_PRICE",
    "PERMIT_FOREIGN_MIN_REP",
    "PERMIT_HOME_GATE",
    "PERMIT_FOREIGN_GATE",
    "PERMIT_HOME_DISCOUNT_NUM",
    "PERMIT_FOREIGN_DISCOUNT_NUM",
    "PERMIT_VOID_REP",
    "FAME_FIRST_FLIP",
    "FAME_PER_DEV_LEVEL",
    "POACHING_REP",
    "MONTHLY_INVEST_CAP",
    "INVEST_CHUNK",
    "MONTH_DAYS",
    "is_protected",
    "effective_alignment",
    "effective_value",
    "ledger_of",
    "ledger_total",
    "port_ledger",
    "dev",
    "add_investment",
    "month_invested_gold",
    "invest_block_reason",
    "player_invest_chunk",
    "tariff_mille",
    "permit_void_reason",
    "permit_void",
    "negotiation_skill",
    "permit_price",
    "set_permit",
    "has_permit_home",
    "has_permit_foreign",
    "credit_tax",
    "credit_permit_sale",
    "treasury",
    "last_month_investments",
    "pending_commendation",
    "mark_commendation_shown",
    "seed_new_game",
    "month_tick",
    "dump_state",
    "restore_state",
]


# --- §4.9 locked constants (allegiance.gd, verbatim) --------------------------

## Home advantage (decision 26): the sovereign owner's ledger counts
## × 1.25 — integer math ``raw × 5 / 4`` (docs/30 §4.9).
EFFECTIVE_NUM: Final[int] = 5
EFFECTIVE_DEN: Final[int] = 4
## Allegiance line: strictly the highest effective ledger, ≥ 5,000g.
ALIGNMENT_MIN_GOLD: Final[int] = 5000
## Dev thresholds over the total ledger: dev 1 / 2 / 3 (docs/30 §4.9).
DEV_THRESHOLD_1: Final[int] = 10000
DEV_THRESHOLD_2: Final[int] = 25000
DEV_THRESHOLD_3: Final[int] = 50000
## A contestable sovereign begins ``{owner: 6,000}`` — allied (7,500
## effective), below dev-1's 10,000g (docs/30 §4.9).
SEED_OWNER_LEDGER: Final[int] = 6000

# --- §4.9 treasuries -----------------------------------------------------------

## Every nation starts with 5,000g (docs/30 §4.9).
TREASURY_START: Final[int] = 5000
## Monthly baseline income, credited on the month tick.
TREASURY_BASELINE: Final[int] = 1000
## NPC-sourced tax is capped at 2,000g per (host) nation per month
## (decision 19); the player's own tax is uncapped.
NPC_TAX_MONTHLY_CAP: Final[int] = 2000

# --- §4.9 monthly AI counter-investment ----------------------------------------

## Each AI nation makes 0–2 picks per month (docs/30 §4.9).
AI_PICKS_MAX: Final[int] = 2
## ``spend = min(treasury, 1500)`` per pick.
AI_SPEND_CAP: Final[int] = 1500
## The seed formula family (docs/30 §4.9, the docs/70 seed style).
AI_SEED_MONTH_MULT: Final[int] = 1000003
AI_SEED_NATION_MULT: Final[int] = 7919
AI_SEED_PORT_MULT: Final[int] = 104729
## Per-candidate draw: ``randi_range(1, 3) <= weight`` — base weight 1 picks
## a third of the time, lane-adjacent weight 2 two thirds. The docs pin the
## 0–2 range, the treasury bound and the weighting *direction*; this draw is
## the module's pinned interpretation of "weighted" (reported to the master
## for ratification — the only number here not read off a doc table).
AI_WEIGHT_BASE: Final[int] = 1
AI_WEIGHT_LANE: Final[int] = 2
AI_WEIGHT_SIDES: Final[int] = 3

# --- §4.9 telegraphs -------------------------------------------------------------

## Visible 30 days in the invested port's band (decision 24).
TELEGRAPH_WINDOW_DAYS: Final[int] = 30
## Ring-buffer cap (the window keeps a month's rows alive anyway).
TELEGRAPH_BUFFER_MAX: Final[int] = 64

# --- §4.10 tariff & permits ------------------------------------------------------

## Per-ten-thousand rates ("mille" basis points over 10,000): 5% in sphere,
## 20% foreign, 0% under a valid permit (docs/30 §4.10).
TARIFF_SCALE: Final[int] = 10000
TARIFF_ALIGNED: Final[int] = 500
TARIFF_FOREIGN: Final[int] = 2000
TARIFF_EXEMPT: Final[int] = 0
## 本国免税证: 5,000g, own palaces, no title/rep gate (docs/30 §4.10).
PERMIT_HOME_PRICE: Final[int] = 5000
## 涉外免税证: 20,000g, that nation's palaces, title ≥ Knight, rep ≥ +20.
PERMIT_FOREIGN_PRICE: Final[int] = 20000
PERMIT_FOREIGN_MIN_REP: Final[int] = 20
## Phase 8 negotiation gates (docs/30 §4.10, 2026-11-02): the home charter
## sells at ×95% (4,750g) when negotiation ≥ 40, the foreign permit at ×90%
## (18,000g) when ≥ 70; full price below the gate. Thresholds live in
## ``data/skill_gates.json`` (``permit.home_discount`` /
## ``permit.foreign_discount``) — read through :func:`permit_price`, else
## the doc numbers.
PERMIT_HOME_GATE: Final[int] = 40
PERMIT_FOREIGN_GATE: Final[int] = 70
PERMIT_HOME_DISCOUNT_NUM: Final[int] = 95
PERMIT_FOREIGN_DISCOUNT_NUM: Final[int] = 90
## Both kinds are void while that nation's bounty is held or rep < −20.
PERMIT_VOID_REP: Final[int] = -20

# --- §2.6 fame & §4.9 campaign ---------------------------------------------------

## +100 fame the first time a contestable port flips to the player's nation
## (once per port per save); +25 per dev threshold reached at an aligned
## port.
FAME_FIRST_FLIP: Final[int] = 100
FAME_PER_DEV_LEVEL: Final[int] = 25
## Poaching: the player's nation gaining a foreign sovereign port costs −5
## rep with the previous owner, one-time per flip (none on losing it back).
POACHING_REP: Final[int] = -5
## ≤ 2,000g player investment per contestable port per month (decision 26).
MONTHLY_INVEST_CAP: Final[int] = 2000
## The §4.3 fixed chunk — the locked 500g, restated exactly like the
## GDScript restates ``TradeEngine.INVEST_CHUNK`` (the trade engine is a
## separate owner; the value is locked twice by design, never imported
## across that seam).
INVEST_CHUNK: Final[int] = 500
## 30-day months (docs/20 §4.3; the sailing-sim seam tests ``day % 30 == 1``).
MONTH_DAYS: Final[int] = 30


# --- Run state (the save v7 keys' runtime home + the GDScript statics) --------


@dataclass
class AllegianceState:
    """The run-scoped allegiance state (save v7 keys + GDScript statics).

    The five save keys (docs/90 §8.2) surface through :func:`dump_state`:
    ``port_allegiance`` (rebuilt from ``ledgers`` + ``allegiances`` — dev
    is derived and never serialized, correction 8), ``month_invested``,
    ``nation_treasuries``, ``fame_commended`` and ``permits``. The rest is
    transient session state the GDScript kept in module statics.
    """

    ## ``{port_id: {nation_id: gold}}`` — cumulative, contestable only.
    ledgers: dict[str, dict[str, int]] = field(default_factory=dict)
    ## ``{port_id: nation_id | ""}`` — persisted (the tie rule keeps the
    ## incumbent, correction 8).
    allegiances: dict[str, str] = field(default_factory=dict)
    ## ``{port_id: gold}`` — the ≤ 2,000g/month player counter.
    month_invested: dict[str, int] = field(default_factory=dict)
    ## ``{nation_id: gold}`` — start 5,000, +1,000/mo + tax + permit sales.
    treasuries: dict[str, int] = field(default_factory=dict)
    ## ``{host_nation_id: gold}`` — NPC-sourced tax credited this month.
    npc_tax_month: dict[str, int] = field(default_factory=dict)
    ## Telegraph ring buffer: ``{nation_id, port_id, band, amount, day}``.
    telegraphs: list[dict[str, Any]] = field(default_factory=list)
    ## ``{port_id: True}`` — first flip to the player honored (save key
    ## ``fame_commended``).
    fame_commended: dict[str, bool] = field(default_factory=dict)
    ## Ports flipped to the player whose commendation dialog is unshown
    ## (transient — the palace surface renders it).
    pending_commendations: list[str] = field(default_factory=list)
    ## Ports whose commendation dialog was shown (transient session state).
    commendations_shown: dict[str, bool] = field(default_factory=dict)
    ## ``{port_id: dev}`` — highest dev level whose +25 fame was awarded
    ## (transient; re-derived on restore so thresholds never re-award).
    threshold_dev: dict[str, int] = field(default_factory=dict)
    ## ``{"home": bool, "foreign": {nation_id: bool}}`` (save ``permits``).
    permits: dict[str, Any] = field(
        default_factory=lambda: {"home": False, "foreign": {}})
    ## ``{nation_id: {port_id: True}}`` — lazy lane-adjacency cache.
    lane_adjacency: dict[str, dict[str, bool]] = field(default_factory=dict)
    ## Seeding/restore guards: allegiance writes stay silent (no flip hooks).
    seeding: bool = False
    restoring: bool = False


# --- Classes & alignment (docs/30 §4.9; docs/80 §4.16 contract) ----------------


def is_protected(store: DataStore, port_id: str) -> bool:
    """True when ``port_id`` is a protected core port (``ports.json
    protected: true``). An unknown port is not protected."""
    return bool(store.get_port(port_id).get("protected", False))


def effective_alignment(store: DataStore, alg: AllegianceState,
                        port_id: str) -> str:
    """The port's effective alignment: the owner at a protected port, the
    persisted allegiance at a contestable port, ``""`` unaligned
    (docs/30 §4.9/§4.10)."""
    port = store.get_port(port_id)
    if not port:
        return ""
    if bool(port.get("protected", False)):
        return str(port.get("nation_id", ""))
    return str(alg.allegiances.get(port_id, ""))


def effective_value(store: DataStore, alg: AllegianceState, port_id: str,
                    nation_id: str) -> int:
    """Effective ledger value of ``nation_id`` at ``port_id``: raw, except
    the sovereign owner's × 1.25 (``raw × 5 / 4``, docs/30 §4.9). 0 when
    unrecorded."""
    raw = ledger_of(store, alg, port_id, nation_id)
    if nation_id == str(store.get_port(port_id).get("nation_id", "")):
        return raw * EFFECTIVE_NUM // EFFECTIVE_DEN
    return raw


def ledger_of(store: DataStore, alg: AllegianceState, port_id: str,
              nation_id: str) -> int:
    """One nation's raw ledger entry (0 when unrecorded / protected /
    unknown)."""
    if is_protected(store, port_id):
        return 0
    return int(alg.ledgers.get(port_id, {}).get(nation_id, 0))


def ledger_total(alg: AllegianceState, port_id: str) -> int:
    """The port's total ledger over all nations (the dev-threshold basis)."""
    total = 0
    for value in alg.ledgers.get(port_id, {}).values():
        total += int(value)
    return total


def port_ledger(alg: AllegianceState, port_id: str) -> dict[str, int]:
    """Read-only copy of one port's raw ledger (``{nation_id: gold}``) —
    the debug port panel's per-nation rows (docs/95 §7.2). Empty at a
    protected port (no ledger exists there)."""
    return dict(alg.ledgers.get(port_id, {}))


# --- Development (derived — never saved, correction 8) --------------------------


def dev(store: DataStore, alg: AllegianceState, port_id: str) -> int:
    """``max(authored floor, ledger thresholds)`` (docs/30 §4.9): protected
    ports stay at their authored floor forever; a contestable port grows
    when its **total** ledger crosses 10,000 / 25,000 / 50,000. Unknown
    port → 0."""
    port = store.get_port(port_id)
    if not port:
        return 0
    level = max(0, int(port.get("dev", 0)))
    if bool(port.get("protected", False)):
        return level
    total = ledger_total(alg, port_id)
    if total >= DEV_THRESHOLD_3:
        return max(level, 3)
    if total >= DEV_THRESHOLD_2:
        return max(level, 2)
    if total >= DEV_THRESHOLD_1:
        return max(level, 1)
    return level


# --- Ledger writes & allegiance resolution ---------------------------------------


def add_investment(store: DataStore, alg: AllegianceState, st: PersonState,
                   port_id: str, nation_id: str, gold: int) -> None:
    """Adds ``gold`` for ``nation_id`` at a **contestable** ``port_id``,
    then re-resolves the allegiance (flip hooks included). Protected ports
    have no ledger: a call there is a no-op. This is the single ledger
    entry point — the player's market chunk and the monthly NPC
    counter-investment both go through it."""
    if gold <= 0 or not nation_id or is_protected(store, port_id):
        return
    if not store.get_port(port_id):
        return
    if port_id not in alg.ledgers:
        alg.ledgers[port_id] = {}
    ledger = alg.ledgers[port_id]
    ledger[nation_id] = int(ledger.get(nation_id, 0)) + gold
    _award_threshold_fame(store, alg, st, port_id)
    _resolve_allegiance(store, alg, st, port_id)


def _resolve_allegiance(store: DataStore, alg: AllegianceState,
                        st: PersonState, port_id: str) -> None:
    """Strictly the highest effective ledger ≥ 5,000g wins; ties keep the
    incumbent (docs/30 §4.9). Candidates iterate in sorted-nation order so
    the resolution is a pure function of the ledger state."""
    ledger = alg.ledgers.get(port_id, {})
    best_value = -1
    tied: list[str] = []
    for nation_id in ledger.keys():
        value = effective_value(store, alg, port_id, str(nation_id))
        if value > best_value:
            best_value = value
            tied = [str(nation_id)]
        elif value == best_value:
            tied.append(str(nation_id))
    nxt = ""
    if best_value >= ALIGNMENT_MIN_GOLD:
        tied.sort()
        incumbent = str(alg.allegiances.get(port_id, ""))
        nxt = incumbent if incumbent in tied else tied[0]
    _set_allegiance(store, alg, st, port_id, nxt)


def _set_allegiance(store: DataStore, alg: AllegianceState, st: PersonState,
                    port_id: str, nxt: str) -> None:
    """Applies a new allegiance and runs the §2.6 / §4.9 flip hooks: the
    +100 first-flip fame (+ pending commendation), the −5 poaching rep on
    taking a foreign sovereign port, and the dev-fame tracker re-baseline.
    Seeding and restoring set allegiances **silently** — the starting state
    is not an event, so no fame/poaching/commendation fires for it."""
    previous = str(alg.allegiances.get(port_id, ""))
    if nxt == previous:
        return
    alg.allegiances[port_id] = nxt
    if alg.seeding or alg.restoring:
        alg.threshold_dev[port_id] = dev(store, alg, port_id)
        return
    player = _player_nation(st)
    if nxt == player and player:
        # §2.6: +100 fame the first time this port flips to the player's
        # nation (once per port per save), plus the one-time palace
        # commendation.
        if port_id not in alg.fame_commended:
            alg.fame_commended[port_id] = True
            fame.add(st, FAME_FIRST_FLIP)
            if port_id not in alg.pending_commendations:
                alg.pending_commendations.append(port_id)
        # §4.9 poaching: the port is a foreign sovereign (owned by another
        # nation) and was aligned to a nation — −5 rep with the previous
        # owner, once per flip. Losing it back costs nothing.
        owner = str(store.get_port(port_id).get("nation_id", ""))
        if owner and owner != player and previous and previous != player:
            character.add_reputation(st, previous, POACHING_REP)
    # The threshold tracker re-baselines at the flip: thresholds reached
    # while aligned to another nation are never retro-awarded (§2.6 awards
    # the crossing, and the crossing already happened).
    alg.threshold_dev[port_id] = dev(store, alg, port_id)


def _award_threshold_fame(store: DataStore, alg: AllegianceState,
                          st: PersonState, port_id: str) -> None:
    """The +25 fame per dev level reached at a contestable port **aligned
    to the player's nation** (§2.6). Called on every ledger add, before
    the allegiance resolves — the alignment read is the pre-add state,
    which is exactly "the port the investment was made into"."""
    if is_protected(store, port_id):
        return
    player = _player_nation(st)
    if not player or str(alg.allegiances.get(port_id, "")) != player:
        alg.threshold_dev[port_id] = dev(store, alg, port_id)
        return
    level = dev(store, alg, port_id)
    rewarded = max(0, int(alg.threshold_dev.get(port_id, 0)))
    if level > rewarded:
        fame.add(st, FAME_PER_DEV_LEVEL * (level - rewarded))
    alg.threshold_dev[port_id] = max(rewarded, level)


# --- Player investment hooks (docs/30 §4.3, decision 26) -------------------------


def month_invested_gold(alg: AllegianceState, port_id: str) -> int:
    """The month's player-investment gold at ``port_id`` (0 when none)."""
    return max(0, int(alg.month_invested.get(port_id, 0)))


def invest_block_reason(store: DataStore, alg: AllegianceState,
                        st: PersonState, bounties: dict[str, Any],
                        port_id: str) -> str:
    """The three-state Invest gate (decision 26): ``""`` investable, else a
    ``market.invest_gate.*`` ui_strings key (the caller resolves it through
    the i18n table). Allowance first, then the diplomatic gate. Protected
    ports have no monthly allowance; every aligned port gates on rep/bounty
    vs its alignment nation; unaligned contestable ports have no gate at
    all."""
    port = store.get_port(port_id)
    if not port:
        return ""
    if not bool(port.get("protected", False)):
        if month_invested_gold(alg, port_id) + INVEST_CHUNK \
                > MONTHLY_INVEST_CAP:
            return "market.invest_gate.exhausted"
    alignment = effective_alignment(store, alg, port_id)
    if alignment:
        if character.reputation(st, alignment) < 0 \
                or _has_bounty(bounties, alignment):
            return "market.invest_gate.blocked"
    return ""


def player_invest_chunk(store: DataStore, alg: AllegianceState,
                        st: PersonState, port_id: str) -> None:
    """The ledger side of one 500g player chunk at a contestable port
    (docs/30 §4.3): +500g to the player-nation's ledger, +500g to the
    monthly counter, allegiance re-resolved. The gold charge and the
    discount block stay with trade.py's invest path (the standing
    arithmetic is unchanged)."""
    nation = _player_nation(st)
    if not nation:
        return
    add_investment(store, alg, st, port_id, nation, INVEST_CHUNK)
    alg.month_invested[port_id] = month_invested_gold(alg, port_id) \
        + INVEST_CHUNK


# --- Tariff (docs/30 §4.10; docs/80 §4.16 contract) -------------------------------


def tariff_mille(store: DataStore, alg: AllegianceState, st: PersonState,
                 bounties: dict[str, Any], port_id: str,
                 nation_id: str) -> int:
    """0 / 500 / 2000 basis points over 10,000: 5% when the effective
    alignment == the trader's nation, 20% otherwise, 0% under a valid
    covering permit. An unaligned contestable port is 20% forever — no
    permit can ever cover it (docs/30 §4.10). Called by trade.py's callers
    (the player's trades) and by the NPC crediting with the fleet's
    nation; the rate then rides ``trade.tax_amount`` on the transaction
    totals."""
    alignment = effective_alignment(store, alg, port_id)
    if not alignment:
        return TARIFF_FOREIGN
    if _permit_covers(alg, st, bounties, alignment, nation_id):
        return TARIFF_EXEMPT
    return TARIFF_ALIGNED if alignment == nation_id else TARIFF_FOREIGN


def _permit_covers(alg: AllegianceState, st: PersonState,
                   bounties: dict[str, Any], alignment: str,
                   trader_nation: str) -> bool:
    """True when a **valid** permit held by the trader ``nation_id`` covers
    a port aligned to ``alignment``. Only the player holds permits (the
    palace sales are player surfaces), so an NPC trader's nation never
    exempts."""
    player = _player_nation(st)
    if not player or trader_nation != player:
        return False
    if bool(alg.permits.get("home", False)) and alignment == player \
            and not permit_void(st, bounties, player):
        return True
    foreign = alg.permits.get("foreign", {})
    if bool(foreign.get(alignment, False)) and alignment != player \
            and not permit_void(st, bounties, alignment):
        return True
    return False


def permit_void_reason(st: PersonState, bounties: dict[str, Any],
                       nation_id: str) -> str:
    """``""`` valid, else the ``palace.permit.void_*`` ui_strings key: a
    held permit is void while that nation's bounty stands or rep < −20
    (docs/30 §4.10)."""
    if _has_bounty(bounties, nation_id):
        return "palace.permit.void_bounty"
    if character.reputation(st, nation_id) < PERMIT_VOID_REP:
        return "palace.permit.void_rep"
    return ""


def permit_void(st: PersonState, bounties: dict[str, Any],
                nation_id: str) -> bool:
    """True when :func:`permit_void_reason` names a reason (the GDScript's
    ``not permit_void_reason(nation_id).is_empty()``)."""
    return bool(permit_void_reason(st, bounties, nation_id))


def _has_bounty(bounties: dict[str, Any], nation_id: str) -> bool:
    """The ``Bounty.has_bounty`` read: a plain key-presence check on
    ``GameState.bounties`` (scripts/quests/bounty.gd)."""
    return nation_id in bounties


# --- Permit price gates (docs/30 §4.10, Phase 8) -----------------------------------


def negotiation_skill(st: PersonState, store: DataStore) -> int:
    """The player's **effective** negotiation — the same value the GDScript
    guard chain ends at (the ``Skills`` autoload's ``effective_skill``,
    which folds the in-post officer contribution, docs/50 §4.5.3; skills
    start at 0)."""
    return max(0, skills.effective_skill(st, store, "negotiation"))


def _gate_threshold(store: DataStore, feature_id: str,
                    doc_default: int) -> int:
    """The §4.3.5 gate threshold (``feature_id`` → threshold): the store's
    ``skill_gates`` table (keyed ``feature_id``) first, else the doc
    default."""
    row = store.skill_gates.get(feature_id)
    if isinstance(row, dict) and "threshold" in row:
        return max(0, int(row["threshold"]))
    return doc_default


def permit_price(store: DataStore, st: PersonState, kind: str) -> int:
    """The §4.10 permit price for ``kind`` (``"home"`` / ``"foreign"``,
    ``""`` → 0) after the Phase-8 negotiation gate: the home charter
    5,000g → **4,750g** at negotiation ≥ 40, the foreign permit 20,000g →
    **18,000g** at ≥ 70, full price below the gate (docs/30 §4.10 — the
    discounted values are the exact products 5000 × 95 / 100 and
    20000 × 90 / 100). The palace offer answers this, so the row display
    and the ``buy_permit`` charge agree."""
    if kind == "home":
        if negotiation_skill(st, store) >= _gate_threshold(
                store, "permit.home_discount", PERMIT_HOME_GATE):
            return PERMIT_HOME_PRICE * PERMIT_HOME_DISCOUNT_NUM // 100
        return PERMIT_HOME_PRICE
    if kind == "foreign":
        if negotiation_skill(st, store) >= _gate_threshold(
                store, "permit.foreign_discount", PERMIT_FOREIGN_GATE):
            return PERMIT_FOREIGN_PRICE * PERMIT_FOREIGN_DISCOUNT_NUM // 100
        return PERMIT_FOREIGN_PRICE
    return 0


def set_permit(alg: AllegianceState, kind: str, nation_id: str) -> None:
    """Writes the permit flags (palace purchase seam — the caller applies
    the price/gate checks first). ``kind`` is ``"home"`` or ``"foreign"``."""
    if kind == "home":
        alg.permits["home"] = True
    elif kind == "foreign" and nation_id:
        foreign = alg.permits.get("foreign", {})
        foreign[nation_id] = True
        alg.permits["foreign"] = foreign


def has_permit_home(alg: AllegianceState) -> bool:
    """True when the home charter (本国免税证) is held (void state ignored —
    the void rules gate *coverage*, see :func:`permit_void_reason`)."""
    return bool(alg.permits.get("home", False))


def has_permit_foreign(alg: AllegianceState, nation_id: str) -> bool:
    """True when the foreign permit (涉外免税证) for ``nation_id`` is held."""
    return bool(alg.permits.get("foreign", {}).get(nation_id, False))


# --- Tax crediting (docs/30 §4.9/§4.10; docs/80 §4.16 contract) ---------------------


def credit_tax(store: DataStore, alg: AllegianceState, st: PersonState,
               port_id: str, payer_nation: str, gold: int) -> None:
    """Every tax coin flows to the port's effective-alignment nation
    (decision 19). ``payer_nation`` distinguishes the cap: an NPC payer's
    credit into a host is capped at 2,000g/host/month; the player's own
    tax is uncapped. Nationless payers (``""``) and unaligned hosts
    (``""``) credit nothing — no host to pay. THE NPC crediting entry
    point: call on every port-call trade with the walked total's tax and
    the fleet's nation."""
    amount = max(0, gold)
    if amount <= 0 or not payer_nation:
        return
    host = effective_alignment(store, alg, port_id)
    if not host:
        return
    player = _player_nation(st)
    if not player or payer_nation != player:
        used = max(0, int(alg.npc_tax_month.get(host, 0)))
        amount = min(amount, NPC_TAX_MONTHLY_CAP - used)
        if amount <= 0:
            return
        alg.npc_tax_month[host] = used + amount
    alg.treasuries[host] = max(0, int(alg.treasuries.get(host, 0))) + amount


def credit_permit_sale(alg: AllegianceState, nation_id: str,
                       gold: int) -> None:
    """A permit sale credits the selling nation's treasury (uncapped,
    docs/30 §4.10). Called by the palace buy path."""
    if not nation_id or gold <= 0:
        return
    alg.treasuries[nation_id] = \
        max(0, int(alg.treasuries.get(nation_id, 0))) + gold


def treasury(alg: AllegianceState, nation_id: str) -> int:
    """The nation's current treasury gold (0 when unseeded)."""
    return max(0, int(alg.treasuries.get(nation_id, 0)))


# --- Telegraphs (decision 24; docs/80 §4.16 contract) --------------------------------


def last_month_investments(alg: AllegianceState, st: PersonState) -> list[dict[str, Any]]:
    """The investment telegraph rows still inside their 30-day window,
    oldest first: ``{nation_id, port_id, band, amount, day}``. The tavern's
    rumor pipeline scopes them to the invested port's band and formats
    ``tavern.invest.row``."""
    today = int(st.day)
    out: list[dict[str, Any]] = []
    for row in alg.telegraphs:
        if not isinstance(row, dict):
            continue
        if today - int(row.get("day", 0)) >= TELEGRAPH_WINDOW_DAYS:
            continue
        out.append(dict(row))
    return out


def _refresh_telegraphs(alg: AllegianceState, today: int) -> None:
    """Drops rows whose 30-day window closed and trims the ring buffer."""
    kept: list[dict[str, Any]] = []
    for row in alg.telegraphs:
        if not isinstance(row, dict):
            continue
        if today - int(row.get("day", 0)) < TELEGRAPH_WINDOW_DAYS:
            kept.append(row)
    alg.telegraphs = kept
    while len(alg.telegraphs) > TELEGRAPH_BUFFER_MAX:
        alg.telegraphs.pop(0)


def _record_telegraph(store: DataStore, alg: AllegianceState,
                      nation_id: str, port_id: str, amount: int,
                      day: int) -> None:
    """Appends one telegraph row, then trims the ring buffer."""
    alg.telegraphs.append({
        "nation_id": nation_id,
        "port_id": port_id,
        "band": str(store.get_port(port_id).get("band", "")),
        "amount": amount,
        "day": day,
    })
    while len(alg.telegraphs) > TELEGRAPH_BUFFER_MAX:
        alg.telegraphs.pop(0)


# --- Commendations (§2.6; the palace dialog seam) -------------------------------------


def pending_commendation(alg: AllegianceState,
                         st: PersonState) -> dict[str, str]:
    """The oldest unshown conversion to the player's nation:
    ``{port_id, nation_id}`` or ``{}``. The palace surface reads this at
    the player's nation's palaces and calls
    :func:`mark_commendation_shown`."""
    while alg.pending_commendations:
        port_id = str(alg.pending_commendations[0])
        if port_id in alg.commendations_shown:
            alg.pending_commendations.pop(0)
            continue
        nation = _player_nation(st)
        if not nation:
            return {}
        return {"port_id": port_id, "nation_id": nation}
    return {}


def mark_commendation_shown(alg: AllegianceState) -> None:
    """Marks the oldest pending commendation shown (one-time per port per
    save within the session; the shown set is transient)."""
    if not alg.pending_commendations:
        return
    port_id = str(alg.pending_commendations.pop(0))
    alg.commendations_shown[port_id] = True


# --- Seeding & the month tick (docs/90 §5.4; docs/80 §4.16 contract) -------------------


def _player_nation(st: PersonState) -> str:
    """The player's nation id (``""`` before a run exists)."""
    return str(st.player.get("nation_id", ""))


def seed_new_game(store: DataStore, alg: AllegianceState) -> None:
    """New-game seeding (docs/30 §4.9): every contestable sovereign begins
    ``{owner: 6,000}`` (allied — 7,500 effective, below dev-1's 10,000g),
    every neutral begins empty; treasuries start at 5,000g per nation;
    permits, fame flags, counters and telegraphs reset. The caller's
    new_game runs this right after its own reset — until then a fresh
    run's first frames see unseeded (empty) allegiance state."""
    alg.ledgers = {}
    alg.allegiances = {}
    alg.month_invested = {}
    alg.treasuries = {}
    alg.npc_tax_month = {}
    alg.telegraphs = []
    alg.fame_commended = {}
    alg.pending_commendations = []
    alg.commendations_shown = {}
    alg.threshold_dev = {}
    alg.permits = {"home": False, "foreign": {}}
    alg.lane_adjacency = {}
    alg.seeding = True
    for port in store.ports_list:
        port_id = str(port.get("id", ""))
        if not port_id or bool(port.get("protected", False)):
            continue
        alg.ledgers[port_id] = {}
        owner = str(port.get("nation_id", ""))
        if owner:
            alg.ledgers[port_id][owner] = SEED_OWNER_LEDGER
    for nation in store.nations_list:
        nation_id = str(nation.get("id", ""))
        if nation_id:
            alg.treasuries[nation_id] = TREASURY_START
    for port_id in alg.ledgers.keys():
        _resolve_allegiance(store, alg, PersonState(), str(port_id))
        alg.threshold_dev[str(port_id)] = dev(store, alg, str(port_id))
    alg.seeding = False


def month_tick(store: DataStore, alg: AllegianceState,
               st: PersonState) -> None:
    """The month tick (docs/90 §5.4 — called from the sailing-sim seam when
    the day ledger ticks INTO a new month, i.e. ``day % 30 == 1`` after the
    increment; docs/30 §4.9 order): reset the monthly player allowance,
    credit each nation's baseline income, resolve the seeded NPC
    counter-investment, refresh the telegraph windows. The NPC-tax cap
    counters reset with the allowance (they are per-month by definition)."""
    alg.month_invested = {}
    alg.npc_tax_month = {}
    for nation_id in alg.treasuries.keys():
        alg.treasuries[nation_id] = int(alg.treasuries[nation_id]) \
            + TREASURY_BASELINE
    today = max(1, int(st.day))
    _npc_counter_invest(store, alg, st, today)
    _refresh_telegraphs(alg, today)


def _npc_counter_invest(store: DataStore, alg: AllegianceState,
                        st: PersonState, today: int) -> None:
    """The deterministic monthly AI (docs/30 §4.9): each nation makes 0–2
    treasury-bounded picks among its sphere's contestable ports — never
    protected ports, never ports it already holds at dev 3 — weighted
    toward its own lanes (the built artifact's spokes of lanes whose
    ``data/trade_routes.json`` ``nations`` include it)."""
    month_index = (today - 1) // MONTH_DAYS
    nations: list[str] = []
    for nation in store.nations_list:
        nation_id = str(nation.get("id", ""))
        if nation_id:
            nations.append(nation_id)
    nations.sort()
    for nindex, nation_id in enumerate(nations):
        treasury_gold = treasury(alg, nation_id)
        if treasury_gold <= 0:
            continue
        candidates = _ai_candidates(store, alg, nation_id)
        lane_ports = _lane_adjacent_ports(store, alg, nation_id)
        picks = 0
        for pindex, port_id in enumerate(candidates):
            if picks >= AI_PICKS_MAX or treasury_gold <= 0:
                break
            rng = GodotRng(seed=month_index * AI_SEED_MONTH_MULT
                           + nindex * AI_SEED_NATION_MULT
                           + pindex * AI_SEED_PORT_MULT)
            weight = AI_WEIGHT_LANE if port_id in lane_ports \
                else AI_WEIGHT_BASE
            if rng.randi_range(1, AI_WEIGHT_SIDES) > weight:
                continue
            spend = min(treasury_gold, AI_SPEND_CAP)
            treasury_gold -= spend
            alg.treasuries[nation_id] = treasury_gold
            add_investment(store, alg, st, port_id, nation_id, spend)
            _record_telegraph(store, alg, nation_id, port_id, spend, today)
            picks += 1


def _ai_candidates(store: DataStore, alg: AllegianceState,
                   nation_id: str) -> list[str]:
    """A nation's AI candidate list: the contestable (never protected)
    ports whose ``sphere`` includes the nation, excluding ports it already
    holds at dev 3 ("away from ports they already hold at dev 3", docs/30
    §4.9). Sorted by port id — the stable ``port_ordinal`` of the seed
    formula."""
    out: list[str] = []
    for port in store.ports_list:
        port_id = str(port.get("id", ""))
        if not port_id or bool(port.get("protected", False)):
            continue
        sphere = port.get("sphere", [])
        if nation_id not in sphere:
            continue
        if str(alg.allegiances.get(port_id, "")) == nation_id \
                and dev(store, alg, port_id) >= 3:
            continue
        out.append(port_id)
    out.sort()
    return out


def _lane_adjacent_ports(store: DataStore, alg: AllegianceState,
                         nation_id: str) -> dict[str, bool]:
    """``{port_id: True}`` — the ports on/adjacent to ``nation_id``'s
    lanes: the built artifact's spokes joined with the lane ``nations`` of
    ``data/trade_routes.json`` (the built lanes carry no nations; the
    sources remain the single truth, docs/10 §4.14). Cached per nation on
    the state."""
    if nation_id in alg.lane_adjacency:
        return alg.lane_adjacency[nation_id]
    lane_nations = _lane_nations(store)
    out: dict[str, bool] = {}
    for spoke in store.route_spokes.values():
        lane_id = str(spoke.get("lane", ""))
        if nation_id not in lane_nations.get(lane_id, []):
            continue
        port_id = str(spoke.get("port", ""))
        if port_id:
            out[port_id] = True
    alg.lane_adjacency[nation_id] = out
    return out


def _lane_nations(store: DataStore) -> dict[str, list[str]]:
    """``{lane_id: [nation_id, …]}`` read from the store's authored lanes
    (the GDScript re-read ``data/trade_routes.json`` raw because its loader
    did not index the source file's nations; the Python store loads the
    lanes with their ``nations`` — same truth, one read)."""
    out: dict[str, list[str]] = {}
    for lane in store.trade_routes_list:
        if not isinstance(lane, dict):
            continue
        ids = [str(nation_id) for nation_id in lane.get("nations", [])]
        out[str(lane.get("id", ""))] = ids
    return out


# --- Persistence seam (correction 8 shape; docs/90 §8.2) --------------------------------
#
# The save/load owner wires:
#   save:   payload[<key>] = dump_state(alg)[<key>] for the five keys below
#           (all contestable ports serialize, docs/90 §8.2);
#   load:   restore_state(store, alg, payload) right after the GameState
#           blocks are applied (it re-derives the transient trackers, so a
#           save/load mid-month replays the month identically);
#   new_game: seed_new_game(store, alg) right after the GameState reset.


def dump_state(alg: AllegianceState) -> dict[str, Any]:
    """The five save v7 keys under their docs/90 §8.2 names, plus nothing
    else: ``port_allegiance`` (``{port_id: {ledger, allegiance}}``,
    correction 8 shape — dev is derived and never serialized),
    ``month_invested``, ``nation_treasuries``, ``fame_commended``,
    ``permits``."""
    port_allegiance: dict[str, Any] = {}
    for port_id in alg.ledgers.keys():
        port_allegiance[str(port_id)] = {
            "ledger": dict(alg.ledgers[str(port_id)]),
            "allegiance": str(alg.allegiances.get(str(port_id), "")),
        }
    return {
        "port_allegiance": port_allegiance,
        "month_invested": dict(alg.month_invested),
        "nation_treasuries": dict(alg.treasuries),
        "fame_commended": dict(alg.fame_commended),
        "permits": {
            "home": bool(alg.permits.get("home", False)),
            "foreign": dict(alg.permits.get("foreign", {})),
        },
    }


def restore_state(store: DataStore, alg: AllegianceState,
                  payload: Any) -> None:
    """Restores the five keys (missing keys keep their seeded defaults),
    then re-derives the transient trackers: the threshold-fame baseline
    per port and the unshown commendation queue (every honored flip
    re-surfaces once per session — the dialog is informational and
    one-time per save in spirit)."""
    if not isinstance(payload, dict):
        seed_new_game(store, alg)
        return
    seed_new_game(store, alg)
    alg.restoring = True
    port_allegiance = payload.get("port_allegiance", {})
    if isinstance(port_allegiance, dict):
        for port_id in port_allegiance.keys():
            pid = str(port_id)
            entry = port_allegiance[pid]
            if not isinstance(entry, dict) or pid not in alg.ledgers:
                continue
            ledger = entry.get("ledger", {})
            clean: dict[str, int] = {}
            if isinstance(ledger, dict):
                for nation_id in ledger.keys():
                    clean[str(nation_id)] = max(0, int(ledger[nation_id]))
            alg.ledgers[pid] = clean
            alg.allegiances[pid] = str(entry.get("allegiance", ""))
    month_invested = payload.get("month_invested", {})
    if isinstance(month_invested, dict):
        for port_id in month_invested.keys():
            alg.month_invested[str(port_id)] = \
                max(0, int(month_invested[port_id]))
    treasuries = payload.get("nation_treasuries", {})
    if isinstance(treasuries, dict):
        for nation_id in treasuries.keys():
            alg.treasuries[str(nation_id)] = \
                max(0, int(treasuries[nation_id]))
    fame_commended = payload.get("fame_commended", {})
    if isinstance(fame_commended, dict):
        for port_id in fame_commended.keys():
            alg.fame_commended[str(port_id)] = True
            if str(port_id) not in alg.pending_commendations:
                alg.pending_commendations.append(str(port_id))
    permits = payload.get("permits", {})
    if isinstance(permits, dict):
        foreign = permits.get("foreign", {})
        alg.permits = {
            "home": bool(permits.get("home", False)),
            "foreign": dict(foreign) if isinstance(foreign, dict) else {},
        }
    # Re-derive the transient trackers from the restored ledgers.
    alg.threshold_dev = {}
    for port_id in alg.ledgers.keys():
        alg.threshold_dev[str(port_id)] = dev(store, alg, str(port_id))
    alg.restoring = False
