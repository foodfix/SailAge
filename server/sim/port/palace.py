"""server.sim.port.palace — the palace facility engine (M1).

Python port of ``scripts/port/palace_engine.gd`` plus, per the M1
ownership assignment, the **whole** of ``scripts/quests/tournament.gd``
(the monthly 3-round bracket is the palace engine's machinery). Frozen
parity oracle until the M6 cutover. Normative contract:

  * docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.3 + §4.9.4 — royal missions:
    capitals only, reputation ≥ 30, one active mission per nation, the
    three kinds (delivery ×3 gold / patrol 2 kills / chart 2 reports), the
    pinned rewards (8000/6000 gold, +10 rep, +25 fame, expiry 60; delivery
    expiry 30 per the guild stream) and the expiry failure (−10 rep, no
    fame).
  * docs/70 §4.9.2 — the title ceremony: the ladder grant runs through
    :mod:`server.sim.player.fame` (REUSED, never duplicated); the palace
    only opens the audience.
  * docs/70 §4.7 — retirement: duke with the docked nation, the save state
    is marked.
  * docs/30-PORTS-AND-TRADE.md §4.10 — the permit sale flow: which kind the
    palace sells (home charter at the player's own palaces, foreign permit
    elsewhere), the negotiation-gated prices (home 5,000g → 4,750g at
    negotiation ≥ 40, foreign 20,000g → 18,000g at ≥ 70), the title/rep
    gates on the foreign permit (knight+, rep ≥ +20), the void rules
    (bounty stands, or rep < −20) that allow a full-price re-buy, and the
    treasury credit (decision 19). The allegiance module owns the *state*
    and the tariff resolution; the flags arrive here injected.
  * docs/70 §4.6 + §4.9.7 — the monthly tournament: 30-day cycles, the six
    capitals in the §7.4 order, entry window days 1–5, fee 1,000g, one
    entry per cycle, the brigantine → carrack → galleon hull ladder with
    ``enemy_kind = "tournament"`` (no reputation deltas), win-all-three
    10,000g + 100 fame, any loss 500g + the free repair to
    ``max(current, ceil(effective_max × 0.5))``.
  * docs/80-UI-UX.md §4.7.13 — the commendation pull model: the allegiance
    engine queues a one-time commendation when a contestable port flips to
    the player's nation; the palace at the player's own nation plays and
    dismisses it.

Purity contract (M1, mirrors ``server/sim/port/trade.py``): **pure
functions over injected state** — no GameState autoload, no module state,
no hidden singletons. The person-model reads go through
:class:`~server.sim.player.PersonState` (``st``) and the ported
``server.sim.player`` modules (``fame``, ``character``, ``skills`` — all
reused, never re-implemented); the run-scoped fields the GDScript read off
the ``GameState`` singleton arrive in the injected ``run`` dict whose keys
mirror the GameState members verbatim (``active_quests``, ``fleet``,
``discovery_hints``, ``npc_fleets``, ``bounties``, ``retired``,
``retired_at``); the allegiance-owned state arrives injected as
``permits`` (``{"home": bool, "foreign": {nation_id: bool}}``),
``treasuries`` (``{nation_id: gold}``), ``pending_commendations``
(list of port ids) and ``commendations_shown``.

RNG seams: **none** — palace_engine.gd and tournament.gd contain no
``rand*`` call (verified at port time by grep). The mission-kind rotation,
the cycle/host/window formulas and the bracket arrangement are all closed
form; the bracket's bouts come from the injected battle builder (combat
domain) and the entry-markers live in ``run["discovery_hints"]`` exactly
as the oracle stores them.

Entry points ported (GDScript name → this module):
  * ``nation_of`` / ``offers_missions`` / ``open_block_reason`` /
    ``active_mission`` / ``offered_kind`` / ``offer`` / ``_delivery_offer``
    / ``_rival_of`` / ``accept`` / ``accept_offer`` / ``_spawn_patrol`` /
    ``on_patrol_kill`` / ``on_discovery_reported`` / ``complete_mission`` /
    ``tick`` / ``attend_ceremony`` / ``can_retire`` / ``retire`` /
    ``permit_offer`` / ``_permit_owned`` / ``buy_permit`` /
    ``pending_commendation`` / ``dismiss_commendation`` — same names
    (state injected; the bounty/quest-gen/fleet/npc-fleet seams become
    injected flags and callables).
  * ``Tournament.cycle_of`` / ``day_of_cycle`` / ``capitals`` / ``host`` /
    ``in_entry_window`` / ``entered_key`` / ``already_entered`` / ``status``
    / ``enter`` / ``round_fleet`` / ``encounter`` / ``settle`` /
    ``repair_to_half`` / ``run_bracket`` — same names (state injected).
  * ``allegiance.permit_price`` / ``permit_void_reason`` /
    ``set_permit`` / ``has_permit_home`` / ``has_permit_foreign`` /
    ``credit_permit_sale`` / ``pending_commendation`` /
    ``mark_commendation_shown`` — mirrored here as functions over the
    injected allegiance state **only because** the allegiance port is not
    on master yet (the owning module's rule is copied verbatim and marked;
    when ``server.sim.port.allegiance`` lands these become thin delegations
    or move there — flagged in the M1 report).

Deferred (NOT ported here, with the GDScript entry point):
  * ``repair_cost`` / ``repair`` / ``_shipyard`` (the §4.9.2 count-grant
    repair bays) — they delegate wholesale to
    ``scripts/port/shipyard_engine.gd`` (not yet ported); the bays'
    discount factor already lives in ``fame.repair_discount``.
  * ``inform_on_pirates`` / ``can_inform`` / ``inform_cost`` (the §4.5
    500g reveal) — the reveal pipeline is
    ``scripts/world/npc_intel.gd``'s ``reveal_position`` over live
    ``NpcFleets`` indexes (world domain, other ownership).
  * ``pay_bounty`` — ``scripts/quests/bounty.gd``'s ``pay_off`` (bounty
    domain); only the audience window/hour wrapper would live here.
  * The §4.1b port-hours charge and the ``SailingSim.facility_open``
    wall-clock query — sailing-sim state; the gate arrives as the injected
    ``open_now`` flag and a completed audience charges the caller one port
    hour.
  * ``EventBus.quests_changed`` / ``tournament_finished`` / ``retired``
    announcements — the caller's WS event frames (90-* §0.3).
"""

from __future__ import annotations

import math
from typing import Any, Callable, Final

from server.sim.data import DataStore
from server.sim.player import character, fame, skills
from server.sim.player import PersonState

__all__ = [
    # Royal missions (70-* §4.9.4)
    "MISSION_REPUTATION",
    "KIND_DELIVERY",
    "KIND_PATROL",
    "KIND_CHART",
    "KINDS",
    "ROYAL_DELIVERY_GOLD_FACTOR",
    "ROYAL_DELIVERY_REP",
    "ROYAL_FAME",
    "PATROL_COUNT",
    "PATROL_GOLD",
    "CHART_COUNT",
    "CHART_GOLD",
    "ROYAL_REP",
    "ROYAL_EXPIRY_DAYS",
    "FAIL_REPUTATION",
    "STATUS_ACTIVE",
    "STATUS_COMPLETED",
    "STATUS_FAILED",
    "TYPE_DELIVERY",
    "DELIVERY_EXPIRY_MAX",
    # Permits (30-* §4.10)
    "PERMIT_HOME_PRICE",
    "PERMIT_FOREIGN_PRICE",
    "PERMIT_FOREIGN_MIN_REP",
    "PERMIT_HOME_GATE",
    "PERMIT_FOREIGN_GATE",
    "PERMIT_HOME_DISCOUNT_NUM",
    "PERMIT_FOREIGN_DISCOUNT_NUM",
    "PERMIT_VOID_REP",
    # Tournament (70-* §4.9.7)
    "CYCLE_DAYS",
    "ENTRY_FEE",
    "ENTRY_WINDOW_FIRST",
    "ENTRY_WINDOW_LAST",
    "ROUNDS",
    "ROUND_HULLS",
    "PRIZE_GOLD",
    "PRIZE_FAME",
    "CONSOLATION_GOLD",
    "CONSOLATION_REPAIR_FRACTION",
    "ENEMY_KIND",
    "ENTERED_KEY",
    # Access
    "nation_of",
    "offers_missions",
    "open_block_reason",
    # Royal missions
    "active_mission",
    "offered_kind",
    "offer",
    "accept",
    "accept_offer",
    "on_patrol_kill",
    "on_discovery_reported",
    "complete_mission",
    "tick",
    "rival_of",
    # Titles / retirement
    "attend_ceremony",
    "can_retire",
    "retire",
    # Permits
    "permit_price",
    "permit_void_reason",
    "set_permit",
    "has_permit_home",
    "has_permit_foreign",
    "credit_permit_sale",
    "permit_offer",
    "buy_permit",
    # Commendation
    "pending_commendation",
    "dismiss_commendation",
    # Tournament
    "cycle_of",
    "day_of_cycle",
    "capitals",
    "host",
    "in_entry_window",
    "entered_key",
    "already_entered",
    "status",
    "enter",
    "round_fleet",
    "encounter",
    "settle",
    "repair_to_half",
    "run_bracket",
]

# --- Royal missions (docs/70-* §4.9.4; palace_engine.gd constants) ----------

#: §4.3: a nation offers royal missions only at or above this reputation.
MISSION_REPUTATION: Final[int] = 30
#: §4.9.4: the three royal mission kinds.
KIND_DELIVERY: Final[str] = "royal_delivery"
KIND_PATROL: Final[str] = "royal_patrol"
KIND_CHART: Final[str] = "royal_chart"
KINDS: Final[tuple[str, ...]] = (KIND_DELIVERY, KIND_PATROL, KIND_CHART)
#: §4.9.4 pinned rewards.
ROYAL_DELIVERY_GOLD_FACTOR: Final[int] = 3
ROYAL_DELIVERY_REP: Final[int] = 10
ROYAL_FAME: Final[int] = 25
PATROL_COUNT: Final[int] = 2
PATROL_GOLD: Final[int] = 8000
CHART_COUNT: Final[int] = 2
CHART_GOLD: Final[int] = 6000
ROYAL_REP: Final[int] = 10
ROYAL_EXPIRY_DAYS: Final[int] = 60
#: §4.9.4 failure delta.
FAIL_REPUTATION: Final[int] = -10

#: Quest statuses (``quest_gen.gd:76-78`` — that port owns the constants;
#: restated here until it lands, single strings).
STATUS_ACTIVE: Final[str] = "active"
STATUS_COMPLETED: Final[str] = "completed"
STATUS_FAILED: Final[str] = "failed"
#: The guild delivery type id and its expiry cap (``quest_gen.gd:71/51``).
TYPE_DELIVERY: Final[str] = "delivery"
DELIVERY_EXPIRY_MAX: Final[int] = 30

# --- Permits (docs/30-* §4.10; allegiance.gd constants) ---------------------

PERMIT_HOME_PRICE: Final[int] = 5000
PERMIT_FOREIGN_PRICE: Final[int] = 20000
PERMIT_FOREIGN_MIN_REP: Final[int] = 20
#: The negotiation-gated discounts: home ×95% at negotiation ≥ 40, foreign
#: ×90% at ≥ 70 (``data/skill_gates.json`` ``permit.home_discount`` /
#: ``permit.foreign_discount`` — read through :func:`permit_price`).
PERMIT_HOME_GATE: Final[int] = 40
PERMIT_FOREIGN_GATE: Final[int] = 70
PERMIT_HOME_DISCOUNT_NUM: Final[int] = 95
PERMIT_FOREIGN_DISCOUNT_NUM: Final[int] = 90
#: A held permit is void while that nation's reputation sits below −20.
PERMIT_VOID_REP: Final[int] = -20

# --- Tournament (docs/70-* §4.9.7; tournament.gd constants) -----------------

#: One cycle is 30 days; the host rotates through the six capitals.
CYCLE_DAYS: Final[int] = 30
ENTRY_FEE: Final[int] = 1000
ENTRY_WINDOW_FIRST: Final[int] = 1
ENTRY_WINDOW_LAST: Final[int] = 5
ROUNDS: Final[int] = 3
#: §4.9.7: the escalating hull per round, in order.
ROUND_HULLS: Final[tuple[str, ...]] = ("brigantine", "carrack", "galleon")
#: §4.9.7: win all three → 10,000g + 100 fame.
PRIZE_GOLD: Final[int] = 10000
PRIZE_FAME: Final[int] = 100
#: §4.9.7: lose any round → 500g and a free repair to 50% of effective max.
CONSOLATION_GOLD: Final[int] = 500
CONSOLATION_REPAIR_FRACTION: Final[float] = 0.5
#: §4.9.7: the battle kind that carries no reputation delta (60-* §4.11.7.1).
ENEMY_KIND: Final[str] = "tournament"
#: The saved marker of "this cycle is already entered".
ENTERED_KEY: Final[str] = "tournament_entered_cycle"

#: A fight provider for :func:`run_bracket` — the combat seam. It receives
#: one :func:`encounter` block and returns either ``None`` (no battle screen
#: could be built) or an object answering ``run_to_completion() -> dict``
#: with a ``"result"`` key (``"victory"`` … per the §4.11.9 result strings).
BattleBuilder = Callable[[dict[str, Any]], Any]


# --- Access (docs/70-* §4.3) --------------------------------------------------

def nation_of(store: DataStore, port_id: str) -> str:
    """The nation whose palace this is (``""`` when ``port_id`` is not a
    capital)."""
    port = store.get_port(port_id)
    if not port:
        return ""
    nation_id = str(port.get("nation_id", ""))
    nation = store.get_nation(nation_id)
    if str(nation.get("capital_port_id", "")) == port_id:
        return nation_id
    return ""


def offers_missions(store: DataStore, st: PersonState, port_id: str,
                    port_closed: bool = False,
                    can_pay_here: bool = False) -> bool:
    """True when the palace at ``port_id`` offers royal missions: it is a
    capital, the player's reputation with that nation is ≥ 30, and no
    bounty shuts it (the bounty flags are the bounty module's, injected)."""
    nation_id = nation_of(store, port_id)
    if not nation_id:
        return False
    if port_closed and not can_pay_here:
        return False
    return character.reputation(st, nation_id) >= MISSION_REPUTATION


def open_block_reason(store: DataStore, port_id: str,
                      port_closed: bool = False,
                      can_pay_here: bool = False) -> str:
    """``""`` when ``port_id``'s palace may open at all, else the reason
    key."""
    if not nation_of(store, port_id):
        return "palace.not_capital"
    if port_closed and not can_pay_here:
        return "port.closed_bounty"
    return ""


# --- Royal missions (docs/70-* §4.9.4) ----------------------------------------

def active_mission(run: dict[str, Any], store: DataStore,
                   nation_id: str) -> dict[str, Any]:
    """The active royal mission of ``nation_id`` (``{}`` when none) — §4.3
    "one at a time per nation"."""
    for quest in run.get("active_quests", []):
        if not isinstance(quest, dict):
            continue
        if str(quest.get("giver", "")) != "palace":
            continue
        if str(quest.get("status", "")) != STATUS_ACTIVE:
            continue
        origin = store.get_port(str(quest.get("origin_port_id", "")))
        if str(origin.get("nation_id", "")) == nation_id:
            return quest
    return {}


def offered_kind(store: DataStore, port_id: str, day: int) -> str:
    """The mission kind ``port_id``'s palace offers this week:
    ``cycle(kind count)`` rotated by ``day // 30``, so all three kinds
    appear in a long run, and the offer is deterministic per
    (nation, month) like the guild's."""
    nation_id = nation_of(store, port_id)
    if not nation_id:
        return ""
    ids = sorted(store.nations.keys())
    ordinal = max(0, ids.index(nation_id) if nation_id in ids else -1)
    month = day // 30  # GDScript int/int division (truncating; day ≥ 0)
    return KINDS[(month + ordinal) % len(KINDS)]


def offer(store: DataStore, st: PersonState, run: dict[str, Any],
          port_id: str, day: int,
          delivery_stream: Callable[[str, int], list[dict[str, Any]]]
          | None = None,
          port_closed: bool = False, can_pay_here: bool = False,
          ) -> dict[str, Any]:
    """The royal offer at ``port_id`` on ``day`` (``{}`` when missions are
    unavailable or one is already running). The instance is the same shape
    as a guild quest, with ``giver: "palace"`` and ``requirements.kind``.

    ``delivery_stream`` is the quest-gen seam (``QuestGenLib.offers(port_id,
    day)`` — the guild port owns the deterministic draw); ``None`` answers
    no delivery template, exactly like an empty stream, so a delivery
    month without the guild port offers nothing."""
    if not offers_missions(store, st, port_id, port_closed, can_pay_here) \
            or active_mission(run, store, nation_of(store, port_id)):
        return {}
    nation_id = nation_of(store, port_id)
    kind = offered_kind(store, port_id, day)
    instance_id = f"q_royal_{nation_id}_{day // 30}"
    if kind == KIND_PATROL:
        return {
            "instance_id": instance_id,
            "template_id": "qt_royal_patrol",
            "type": "royal",
            "giver": "palace",
            "origin_port_id": port_id,
            "requirements": {"kind": KIND_PATROL,
                             "nation_id": rival_of(store, nation_id),
                             "count": PATROL_COUNT},
            "rewards": {"gold": PATROL_GOLD,
                        "reputation": {nation_id: ROYAL_REP},
                        "fame": ROYAL_FAME},
            "expiry_days": ROYAL_EXPIRY_DAYS,
            "status": STATUS_ACTIVE,
        }
    if kind == KIND_CHART:
        return {
            "instance_id": instance_id,
            "template_id": "qt_royal_chart",
            "type": "royal",
            "giver": "palace",
            "origin_port_id": port_id,
            "requirements": {"kind": KIND_CHART, "count": CHART_COUNT},
            "rewards": {"gold": CHART_GOLD,
                        "reputation": {nation_id: ROYAL_REP},
                        "fame": ROYAL_FAME},
            "expiry_days": ROYAL_EXPIRY_DAYS,
            "status": STATUS_ACTIVE,
        }
    return _delivery_offer(store, instance_id, port_id, nation_id, day,
                           delivery_stream)


def _delivery_offer(store: DataStore, instance_id: str, port_id: str,
                    nation_id: str, day: int,
                    delivery_stream: Callable[[str, int],
                                              list[dict[str, Any]]]
                    | None) -> dict[str, Any]:
    """The royal delivery is a guild delivery with the §4.9.4 multipliers,
    drawn from the same deterministic per-(port, day//7) stream."""
    if delivery_stream is None:
        return {}
    deliveries = delivery_stream(port_id, day)
    template: dict[str, Any] = {}
    for candidate in deliveries:
        if str(candidate.get("type", "")) == TYPE_DELIVERY:
            template = candidate
            break
    if not template:
        return {}
    requirements = dict(template.get("requirements", {}))
    rewards = {
        "gold": int(template.get("rewards", {}).get("gold", 0))
        * ROYAL_DELIVERY_GOLD_FACTOR,
        "reputation": {nation_id: ROYAL_DELIVERY_REP},
        "fame": ROYAL_FAME,
    }
    return {
        "instance_id": instance_id,
        "template_id": str(template.get("template_id", "")),
        "type": "royal",
        "giver": "palace",
        "origin_port_id": port_id,
        "requirements": {
            "kind": KIND_DELIVERY,
            "good_id": str(requirements.get("good_id", "")),
            "quantity": int(requirements.get("quantity", 0)),
            "dest_port_id": str(requirements.get("dest_port_id", "")),
        },
        "rewards": rewards,
        "expiry_days": DELIVERY_EXPIRY_MAX,
        "status": STATUS_ACTIVE,
    }


def rival_of(store: DataStore, nation_id: str) -> str:
    """The rival nation a patrol targets: the giver's first ``rivals``
    entry (``70-*`` §4.9.5 data table), falling back to any other nation."""
    nation = store.get_nation(nation_id)
    rivals = nation.get("rivals", [])
    if rivals:
        return str(rivals[0])
    for entry in store.nations_list:
        other = str(entry.get("id", ""))
        if other != nation_id:
            return other
    return ""


def accept(store: DataStore, st: PersonState, run: dict[str, Any],
           port_id: str, day: int,
           delivery_stream: Callable[[str, int], list[dict[str, Any]]]
           | None = None,
           open_now: bool = True, port_closed: bool = False,
           fleet_free: Callable[[], int] | None = None,
           add_goods: Callable[[str, int], int] | None = None,
           remove_goods: Callable[[str, int], int] | None = None,
           spawn_fleet: Callable[[str, str, int], dict[str, Any]] | None = None,
           ) -> dict[str, Any]:
    """Accepts the palace's offer, spawning what its kind needs (a patrol's
    navy markers, a royal delivery's cargo). Returns the stored instance or
    ``{}``."""
    candidate = offer(store, st, run, port_id, day, delivery_stream,
                      port_closed, True)
    return accept_offer(store, st, run, port_id, day, candidate,
                        open_now=open_now, fleet_free=fleet_free,
                        add_goods=add_goods, remove_goods=remove_goods,
                        spawn_fleet=spawn_fleet)


def accept_offer(store: DataStore, st: PersonState, run: dict[str, Any],
                 port_id: str, day: int, candidate: dict[str, Any],
                 open_now: bool = True,
                 fleet_free: Callable[[], int] | None = None,
                 add_goods: Callable[[str, int], int] | None = None,
                 remove_goods: Callable[[str, int], int] | None = None,
                 spawn_fleet: Callable[[str, str, int], dict[str, Any]]
                 | None = None,
                 ) -> dict[str, Any]:
    """:func:`accept` for an already-built ``candidate`` (the same offer the
    screen displayed, so a screen click and a test accept the identical
    instance). §4.1b: the audience must start inside the palace's window
    (injected ``open_now``) and charges one hour on success (all-or-nothing:
    a closed-door call returns ``{}`` untouched).

    The delivery's cargo seam is the fleet module (``FleetLib.fleet_free``
    / ``add_goods`` / ``remove_goods``, not yet ported): the hooks are
    injected; a delivery accept without them is refused (``{}``) rather
    than spawning cargo nobody stores. The patrol's spawn seam is
    ``NpcFleets.spawn(role, nation_id, day)`` (world domain): without the
    hook the mission is accepted but spawns no markers (the headless
    default of the oracle's guarded loader)."""
    if not candidate:
        return {}
    if not open_now:
        return {}
    instance = _deep_copy(candidate)
    instance["accepted_day"] = day
    instance["deadline_day"] = day + int(instance.get("expiry_days",
                                                      ROYAL_EXPIRY_DAYS))
    kind = str(instance.get("requirements", {}).get("kind", ""))
    if kind == KIND_DELIVERY:
        requirements = instance["requirements"]
        quantity = int(requirements.get("quantity", 0))
        if fleet_free is None or add_goods is None or remove_goods is None:
            return {}
        if fleet_free() < quantity:
            return {}
        stored = add_goods(str(requirements.get("good_id", "")), quantity)
        if stored != quantity:
            if stored > 0:
                remove_goods(str(requirements.get("good_id", "")), stored)
            return {}
    elif kind == KIND_PATROL:
        _spawn_patrol(run, instance, day, spawn_fleet)
    run.setdefault("active_quests", []).append(instance)
    # §4.1b action cost: the caller charges one hour for the audience.
    return instance


def _deep_copy(value: Any) -> Any:
    """A ``duplicate(true)`` stand-in: fresh nested dicts/lists, leaves
    shared. (The quest instances are plain JSON-shaped data.)"""
    if isinstance(value, dict):
        return {key: _deep_copy(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_deep_copy(item) for item in value]
    return value


def _spawn_patrol(run: dict[str, Any], instance: dict[str, Any], day: int,
                  spawn_fleet: Callable[[str, str, int], dict[str, Any]]
                  | None) -> None:
    """Spawns the patrol's target fleets through the fleet seam, each tagged
    with the mission id. The ``privateer`` role is the always-contact-
    hostile warship role (``60-*``` §4.11.11.2), so the mission plays exactly
    like the retired Phase-2 navy markers. Without the hook (headless
    default — the oracle's guarded loader returns no module) nothing
    spawns."""
    if spawn_fleet is None:
        return
    nation_id = str(instance.get("requirements", {}).get("nation_id", ""))
    for _index in range(PATROL_COUNT):
        marker = spawn_fleet("privateer", nation_id, day)
        if not marker:
            continue
        marker["quest_id"] = str(instance.get("instance_id", ""))
        marker["royal_mission"] = True
        requirements = instance["requirements"]
        requirements["killed"] = int(requirements.get("killed", 0))


def on_patrol_kill(store: DataStore, st: PersonState, quest: dict[str, Any],
                   day: int) -> dict[str, Any]:
    """Called at battle end for a ``victory``: credits a patrol kill and
    completes the mission when its count is reached. Returns the completed
    instance (``{}`` otherwise)."""
    requirements = quest.get("requirements", {})
    requirements["killed"] = int(requirements.get("killed", 0)) + 1
    if int(requirements["killed"]) < int(requirements.get("count",
                                                          PATROL_COUNT)):
        return {}
    return complete_mission(store, st, quest, day)


def on_discovery_reported(store: DataStore, st: PersonState,
                          quest: dict[str, Any], day: int) -> dict[str, Any]:
    """Called when a discovery is reported: credits ``royal_chart``
    progress. Returns the completed instance (``{}`` otherwise)."""
    requirements = quest.get("requirements", {})
    requirements["reported"] = int(requirements.get("reported", 0)) + 1
    if int(requirements["reported"]) < int(requirements.get("count",
                                                            CHART_COUNT)):
        return {}
    return complete_mission(store, st, quest, day)


def complete_mission(store: DataStore, st: PersonState, quest: dict[str, Any],
                     day: int) -> dict[str, Any]:
    """Pays a royal mission: gold/reputation/fame, one more completed
    mission for the giver nation, then the §4.9.2 ladder is re-evaluated
    (the *player* still has to attend the ceremony, so nothing is granted
    here — the grant itself is ``fame.grant``)."""
    if str(quest.get("status", "")) != STATUS_ACTIVE:
        return {}
    rewards = quest.get("rewards", {})
    gold = int(rewards.get("gold", 0))
    if gold > 0:
        st.gold += gold
    reputation = rewards.get("reputation", {})
    for nation_id in reputation:
        character.add_reputation(st, str(nation_id),
                                 int(reputation[nation_id]))
    fame.add(st, int(rewards.get("fame", 0)))
    quest["status"] = STATUS_COMPLETED
    quest["completed_day"] = int(day)
    nation_id = nation_of(store, str(quest.get("origin_port_id", "")))
    if not nation_id:
        origin = store.get_port(str(quest.get("origin_port_id", "")))
        nation_id = str(origin.get("nation_id", ""))
    fame.add_royal_mission(st, nation_id)
    return quest


def tick(store: DataStore, st: PersonState, run: dict[str, Any],
         day: int) -> list[dict[str, Any]]:
    """The royal missions a day tick fails (expiry, §4.9.4: −10 rep, no
    fame). Returns the failed quests."""
    failed: list[dict[str, Any]] = []
    for quest in run.get("active_quests", []):
        if not isinstance(quest, dict) or str(quest.get("giver", "")) != "palace":
            continue
        if str(quest.get("status", "")) != STATUS_ACTIVE:
            continue
        if int(quest.get("deadline_day", 0)) > 0 \
                and day > int(quest.get("deadline_day", 0)):
            origin = store.get_port(str(quest.get("origin_port_id", "")))
            character.add_reputation(st, str(origin.get("nation_id", "")),
                                     FAIL_REPUTATION)
            quest["status"] = STATUS_FAILED
            quest["failed_day"] = day
            failed.append(quest)
    return failed


# --- Titles (docs/70-* §4.9.2) -------------------------------------------------

def attend_ceremony(store: DataStore, st: PersonState, port_id: str,
                    open_now: bool = True) -> str:
    """Runs the ceremony: grants the next rank when both requirements are
    met (the ladder arithmetic is ``fame.grant`` — reused, never
    duplicated). §4.1b: the audience must start inside the palace window
    (injected) and a successful grant charges the caller one hour."""
    nation_id = nation_of(store, port_id)
    if not nation_id:
        return ""
    if not open_now:
        return ""
    return fame.grant(st, nation_id)


# --- Retirement (docs/70-* §4.7) -----------------------------------------------

def can_retire(store: DataStore, st: PersonState, port_id: str) -> bool:
    """True when the retire row exists (§4.7: duke with this nation)."""
    nation_id = nation_of(store, port_id)
    if not nation_id:
        return False
    return fame.is_duke(st, nation_id)


def retire(store: DataStore, st: PersonState, run: dict[str, Any],
           port_id: str, now: int) -> bool:
    """Retires the run: marks the save state (§4.7). The caller routes to
    the ending screen and announces the event. ``now`` is the wall-clock
    stamp the GDScript read off ``Time.get_unix_time_from_system()`` —
    injected so tests stay deterministic."""
    if not can_retire(store, st, port_id):
        return False
    run["retired"] = True
    run["retired_at"] = int(now)
    return True


# --- Tax permits (docs/30-* §4.10; the allegiance-owned state injected) ------
#
# The state (flags, coverage, void rules, treasuries) is allegiance
# territory; until ``server.sim.port.allegiance`` lands, its five accessor
# rules are mirrored here verbatim over the injected ``permits`` /
# ``treasuries`` maps (each function cites its allegiance.gd source line).
# The tariff *resolution* is NOT mirrored — trade injects the resolved rate.

def _gate_threshold(store: DataStore, feature_id: str,
                    doc_default: int) -> int:
    """The §4.3.5 gate threshold (``feature_id`` → threshold): the loader's
    ``skill_gates`` row first, else the doc default (allegiance.gd:473)."""
    row = store.skill_gates.get(feature_id)
    if isinstance(row, dict) and "threshold" in row:
        return max(0, int(row["threshold"]))
    return doc_default


def permit_price(store: DataStore, negotiation: int, kind: str) -> int:
    """The §4.10 permit price for ``kind`` (``"home"`` / ``"foreign"``,
    ``""`` → 0) after the Phase-8 negotiation gate: home 5,000g → **4,750g**
    at negotiation ≥ 40, foreign 20,000g → **18,000g** at ≥ 70, full price
    below the gate (the discounted values are the exact products 5000 × 95
    / 100 and 20000 × 90 / 100). ``permit_offer`` answers this, so the row
    display and the :func:`buy_permit` charge agree (allegiance.gd:488)."""
    if kind == "home":
        if negotiation >= _gate_threshold(store, "permit.home_discount",
                                          PERMIT_HOME_GATE):
            return PERMIT_HOME_PRICE * PERMIT_HOME_DISCOUNT_NUM // 100
        return PERMIT_HOME_PRICE
    if kind == "foreign":
        if negotiation >= _gate_threshold(store, "permit.foreign_discount",
                                          PERMIT_FOREIGN_GATE):
            return PERMIT_FOREIGN_PRICE * PERMIT_FOREIGN_DISCOUNT_NUM // 100
        return PERMIT_FOREIGN_PRICE
    return 0


def permit_void_reason(st: PersonState, run: dict[str, Any],
                       nation_id: str) -> str:
    """Empty string when the permit is valid, else the
    ``palace.permit.void_*`` ui_strings key: a held
    permit is void while that nation's bounty stands or rep < −20
    (allegiance.gd:419; the bounty map is the injected ``run["bounties"]``)."""
    if run.get("bounties", {}).get(nation_id):
        return "palace.permit.void_bounty"
    if character.reputation(st, nation_id) < PERMIT_VOID_REP:
        return "palace.permit.void_rep"
    return ""


def set_permit(permits: dict[str, Any], kind: str, nation_id: str) -> None:
    """Writes the permit flags (the purchase seam; allegiance.gd:506).
    ``kind`` is ``"home"`` or ``"foreign"``."""
    if kind == "home":
        permits["home"] = True
    elif kind == "foreign" and nation_id:
        foreign = permits.setdefault("foreign", {})
        foreign[nation_id] = True


def has_permit_home(permits: dict[str, Any]) -> bool:
    """True when the home charter is held (void state ignored — the void
    rules gate *coverage*; allegiance.gd:517)."""
    return bool(permits.get("home", False))


def has_permit_foreign(permits: dict[str, Any], nation_id: str) -> bool:
    """True when the foreign permit for ``nation_id`` is held
    (allegiance.gd:522)."""
    return bool(permits.get("foreign", {}).get(nation_id, False))


def credit_permit_sale(treasuries: dict[str, Any], nation_id: str,
                       gold: int) -> None:
    """Every permit coin flows to the selling nation's treasury (decision
    19; allegiance.gd:553)."""
    if not nation_id or gold <= 0:
        return
    treasuries[nation_id] = max(0, int(treasuries.get(nation_id, 0))) + gold


def _player_nation(st: PersonState) -> str:
    """The player's nation id (``""`` before a run exists)."""
    return str(st.player.get("nation_id", ""))


def permit_offer(store: DataStore, st: PersonState, run: dict[str, Any],
                 permits: dict[str, Any], port_id: str) -> dict[str, Any]:
    """The permit row at ``port_id``'s palace (``{}`` when the port has no
    palace). Shape: ``{kind, nation_id, price, owned, void_key,
    title_locked, rep_locked, coverage_key}`` — all screen-side strings are
    ui_strings keys from the ``palace.permit.*`` family."""
    nation_id = nation_of(store, port_id)
    if not nation_id:
        return {}
    player = _player_nation(st)
    kind = "home" if nation_id == player else "foreign"
    negotiation = skills.effective_skill(st, store, "negotiation")
    price = permit_price(store, negotiation, kind)
    if kind == "home":
        owned = has_permit_home(permits)
    else:
        owned = has_permit_foreign(permits, nation_id)
    return {
        "kind": kind,
        "nation_id": nation_id,
        "price": price,
        "owned": owned,
        "void_key": permit_void_reason(st, run, nation_id),
        "title_locked": kind == "foreign"
        and fame.rank_index(fame.title(st, nation_id))
        < fame.rank_index(fame.RANK_KNIGHT),
        "rep_locked": kind == "foreign"
        and character.reputation(st, nation_id) < PERMIT_FOREIGN_MIN_REP,
        "coverage_key": "palace.permit.home.coverage" if kind == "home"
        else "palace.permit.foreign.coverage",
    }


def buy_permit(store: DataStore, st: PersonState, run: dict[str, Any],
               permits: dict[str, Any], treasuries: dict[str, Any],
               port_id: str, open_now: bool = True) -> bool:
    """Buys the permit this palace sells (home charter at the player's own
    nation's palaces, foreign permit for that nation elsewhere). Refused
    when there is no palace, the permit is already held (non-void), a
    §4.10 gate locks it, or the purse cannot pay. While **void** a re-buy
    costs the full price. On success the price flows to the selling
    nation's treasury (decision 19) and the caller charges the §4.1b
    audience hour."""
    row = permit_offer(store, st, run, permits, port_id)
    if not row:
        return False
    if not open_now:
        return False
    if bool(row["owned"]) and not str(row["void_key"]):
        return False
    if bool(row["title_locked"]) or bool(row["rep_locked"]):
        return False
    price = int(row["price"])
    if st.gold < price:
        return False
    st.gold -= price
    set_permit(permits, str(row["kind"]), str(row["nation_id"]))
    credit_permit_sale(treasuries, str(row["nation_id"]), price)
    return True


# --- Commendation hook (docs/70-* §4.1; the allegiance-owned queue injected)
#
# The first time a contestable port flips to the player's nation, the
# allegiance engine queues a one-time commendation; the palace at the
# player's nation plays the ``palace.commend.*`` dialog and dismisses it
# here. Pull model — no event surface.

def pending_commendation(store: DataStore, st: PersonState,
                         pending: list[str], shown: dict[str, Any],
                         port_id: str) -> dict[str, Any]:
    """The unshown commendation this palace should play (``{}``, or
    ``{port_id, nation_id}`` — both i18n names are the screen's to
    resolve). Only the player's own nation's palaces play one
    (palace_engine.gd:591)."""
    player = _player_nation(st)
    if not player or nation_of(store, port_id) != player:
        return {}
    while pending:
        flipped_port = str(pending[0])
        if shown.get(flipped_port):
            pending.pop(0)
            continue
        return {"port_id": flipped_port, "nation_id": player}
    return {}


def dismiss_commendation(pending: list[str], shown: dict[str, Any]) -> None:
    """Dismisses the pending commendation after the dialog played
    (allegiance.gd:628)."""
    if not pending:
        return
    port_id = str(pending.pop(0))
    shown[port_id] = True


# --- Tournament (docs/70-* §4.6 + §4.9.7; tournament.gd ported verbatim) ----

def cycle_of(day: int) -> int:
    """The 30-day cycle index of ``day`` (``(day - 1) // 30``)."""
    return max(day - 1, 0) // CYCLE_DAYS


def day_of_cycle(day: int) -> int:
    """Day within the cycle, 1-based."""
    return (max(day - 1, 0) % CYCLE_DAYS) + 1


def capitals(store: DataStore) -> list[str]:
    """The six capitals in the locked §7.4 order (``10-*`` §7.4) — the
    ``capital_port_id`` of every nation in ``nations.json`` order."""
    out: list[str] = []
    for entry in store.nations_list:
        capital = str(entry.get("capital_port_id", ""))
        if capital:
            out.append(capital)
    return out


def host(store: DataStore, day: int) -> str:
    """The host capital of ``day``'s cycle: the §7.4 order rotated by
    ``cycle % 6``."""
    hosts = capitals(store)
    if not hosts:
        return ""
    return hosts[cycle_of(day) % len(hosts)]


def in_entry_window(day: int) -> bool:
    """True when ``day`` is inside the entry window (cycle days 1–5)."""
    index = day_of_cycle(day)
    return ENTRY_WINDOW_FIRST <= index <= ENTRY_WINDOW_LAST


def entered_key(day: int) -> str:
    """The cycle marker key used to remember that this cycle is entered."""
    return f"{ENTERED_KEY}_{cycle_of(day)}"


def already_entered(run: dict[str, Any], day: int) -> bool:
    """True when the run already entered this cycle's tournament (the
    marker lives in ``GameState.discovery_hints``, as the oracle stores
    it)."""
    return bool(run.get("discovery_hints", {}).get(entered_key(day), False))


def status(store: DataStore, st: PersonState, run: dict[str, Any],
           port_id: str, day: int, port_closed: bool = False) -> dict[str, Any]:
    """``{host, open, window_first, window_last, entered, blocked, fee,
    round_hulls}`` for the palace row. ``blocked`` is the ui_strings reason
    key ("" = available)."""
    host_id = host(store, day)
    first = cycle_of(day) * CYCLE_DAYS + ENTRY_WINDOW_FIRST
    last = cycle_of(day) * CYCLE_DAYS + ENTRY_WINDOW_LAST
    blocked = ""
    if port_id != host_id:
        blocked = "tournament.not_host"
    elif not in_entry_window(day):
        blocked = "tournament.closed"
    elif port_closed:
        blocked = "tournament.blocked_bounty"
    elif already_entered(run, day):
        blocked = "tournament.entered"
    elif st.gold < ENTRY_FEE:
        blocked = "market.no_gold"
    return {
        "host": host_id,
        "open": not blocked,
        "window_first": first,
        "window_last": last,
        "entered": already_entered(run, day),
        "blocked": blocked,
        "fee": ENTRY_FEE,
        "round_hulls": list(ROUND_HULLS),
    }


def enter(store: DataStore, st: PersonState, run: dict[str, Any],
          port_id: str, day: int, open_now: bool = True,
          port_closed: bool = False) -> bool:
    """Pays the fee and records the entry. Returns True on success (the
    §4.1b palace-window guard is injected; a completed entry charges the
    caller one hour)."""
    if not open_now:
        return False
    row = status(store, st, run, port_id, day, port_closed)
    if not bool(row.get("open", False)):
        return False
    st.gold -= ENTRY_FEE
    run.setdefault("discovery_hints", {})[entered_key(day)] = True
    return True


def round_fleet(store: DataStore, round_number: int) -> list[dict[str, Any]]:
    """The enemy fleet of ``round`` (1-based): one hull of ``ROUND_HULLS``,
    at full durability, ``crew_min`` crew and ``armament_slots`` cannons
    (§4.9.7)."""
    index = max(0, min(round_number - 1, len(ROUND_HULLS) - 1))
    ship_type_id = ROUND_HULLS[index]
    ship_type = store.get_ship_type(ship_type_id)
    if not ship_type:
        return []
    return [{
        "ship_type_id": ship_type_id,
        "durability": int(ship_type.get("durability", 1)),
        "crew": int(ship_type.get("crew_min", 1)),
        "provisions": 0,
        "water": 0,
        "cannons": int(ship_type.get("armament_slots", 0)),
        "cargo": {},
        "equipment": {"figurehead": "", "sail": ""},
    }]


def encounter(store: DataStore, round_number: int, day: int) -> dict[str, Any]:
    """The ``60-*``` encounter descriptor for one bout; ``enemy_kind`` is
    ``"tournament"`` so no reputation is charged."""
    return {
        "id": f"tournament_{cycle_of(day)}_{round_number}",
        "kind": ENEMY_KIND,
        "nation_id": "",
        "position": {"x": 0, "y": 0},
        "ships": round_fleet(store, round_number),
        "day": day,
    }


def settle(store: DataStore, st: PersonState, run: dict[str, Any],
           won: bool, round_reached: int) -> dict[str, Any]:
    """Settles a finished bracket. ``round_reached`` = the bout the run
    **lost** (0 = the run won all three). Returns the outcome block the
    palace screen reports; the ``tournament_finished`` announcement is the
    caller's WS event."""
    outcome: dict[str, Any] = {
        "won": won,
        "round_reached": round_reached,
        "gold": PRIZE_GOLD if won else CONSOLATION_GOLD,
        "fame": PRIZE_FAME if won else 0,
        "repaired": 0,
    }
    st.gold += int(outcome["gold"])
    if won:
        fame.add(st, PRIZE_FAME)
    else:
        outcome["repaired"] = repair_to_half(store, run.get("fleet", []))
    return outcome


def repair_to_half(store: DataStore, fleet: list[Any]) -> int:
    """§4.9.7 consolation: every surviving hull is repaired to
    ``max(current, ceil(effective_max × 0.5))`` for free. Returns the
    points restored in total. ``effective_max`` = the ShipType durability
    plus the figurehead's durability modifier (the §4.12.4 effective-max
    rule)."""
    restored = 0
    for ship in fleet:
        if not isinstance(ship, dict):
            continue
        ship_type = store.get_ship_type(str(ship.get("ship_type_id", "")))
        equipment = ship.get("equipment", {})
        figurehead = store.get_equipment(
            str((equipment or {}).get("figurehead", "")))
        max_durability = int(ship_type.get("durability", 0)) \
            + int((figurehead.get("modifiers", {}) or {}).get("durability", 0))
        floor_value = int(math.ceil(float(max_durability)
                                    * CONSOLATION_REPAIR_FRACTION))
        current = int(ship.get("durability", 0))
        if floor_value > current:
            restored += floor_value - current
            ship["durability"] = floor_value
    return restored


def run_bracket(store: DataStore, st: PersonState, run: dict[str, Any],
                battle_builder: BattleBuilder, day: int) -> dict[str, Any]:
    """Runs the whole bracket headlessly through ``battle_builder``, one
    bout at a time, carrying durability between bouts (the builder's
    battle writes the survivors back — the §4.12.4 seam the combat port
    owns) and settling the payout. This is the acceptance driver; the
    palace screen runs the same three bouts interactively and calls
    :func:`settle` itself.

    Returns the :func:`settle` outcome plus ``results`` (each bout's
    §4.11.9 result string)."""
    results: list[str] = []
    round_number = 1
    while round_number <= ROUNDS:
        screen = battle_builder(encounter(store, round_number, day))
        if screen is None:
            settled = settle(store, st, run, False, round_number)
            settled["results"] = results
            return settled
        outcome = screen.run_to_completion()
        result = str(outcome.get("result", ""))
        results.append(result)
        # Durability and crew carry: the screen fought with fleet copies
        # and the battle result wrote the survivors back into run["fleet"].
        if result != "victory":
            settled = settle(store, st, run, False, round_number)
            settled["results"] = results
            return settled
        round_number += 1
    won = settle(store, st, run, True, 0)
    won["results"] = results
    return won
