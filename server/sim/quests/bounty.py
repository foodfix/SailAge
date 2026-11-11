"""server.sim.quests.bounty — piracy reputation, bounties, closed ports (M1).

Python port of ``scripts/quests/bounty.gd`` (the frozen parity oracle
until the M6 cutover). Normative contract:
docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.5 (piracy & bounty), §4.9.5 (the
rival table, issue/clearing pins), §4.9.6 (closed ports); docs/60-* §4.1,
§4.11.10 (the once-per-battle piracy charge); docs/30-* §4.2 (the port
hub's closed rows); docs/90-ARCHITECTURE.md §0/§4 (pure logic, no scene
code).

Pure logic in the same shape as :mod:`server.sim.player.character`/
:mod:`server.sim.player.fame`: it owns ``QuestState.bounties`` and
mutates ``player.reputation`` **only** through
:func:`server.sim.player.character.add_reputation`, so the −100…+100
clamp is applied exactly once.

The rival table is **data** (``data/nations.json#rivals``, §4.9.5), never
a computed distance: a value left to code would be invented twice.

State convention: the GDScript statics read/mutate ``GameState.day``/
``GameState.gold``/``GameState.bounties`` and the player block — here the
:class:`~server.sim.player.PersonState` carries day/gold/the player
block and the :class:`~server.sim.quests.QuestState` carries
``bounties``. EventBus announcements (``bounty_issued``/
``bounty_cleared``/``gold_changed``) are the caller's WS ``event``
frames (``90-*`` §0.3) — every function returns its delta instead.

RNG-free: the oracle file has no ``rand*`` call (verified at port time);
every rule below is deterministic.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any, Final

from server.sim.data import data
from server.sim.player import character as character_lib

if TYPE_CHECKING:
    from server.sim.player import PersonState
    from server.sim.quests import QuestState

__all__ = [
    "BOUNTY_THRESHOLD",
    "BOUNTY_GOLD_PER_REP",
    "CLEARED_REPUTATION",
    "PIRACY_REPUTATION",
    "RIVAL_REPUTATION",
    "rivals",
    "piracy_deltas",
    "apply_piracy",
    "has_bounty",
    "record",
    "amount",
    "bountied_nations",
    "issue",
    "evaluate_all",
    "can_pay_off",
    "pay_off",
    "clear_by_surrender",
    "is_port_closed",
    "can_open_facility",
    "can_pay_here",
]

## §4.9.5: a bounty is issued at or below this reputation.
BOUNTY_THRESHOLD: Final[int] = -50
## §4.9.5: the bounty amount is ``500 × |rep|``, fixed at issue time.
BOUNTY_GOLD_PER_REP: Final[int] = 500
## §4.9.5: both clearing paths reset that nation's reputation to exactly −10.
CLEARED_REPUTATION: Final[int] = -10
## §4.9.5: `60-*` §4.11.10 charges exactly one −20 per navy battle.
PIRACY_REPUTATION: Final[int] = -20
## §4.9.5: the two rivals each gain +2 once per battle.
RIVAL_REPUTATION: Final[int] = 2


# --- Piracy (docs/70-* §4.9.5) -------------------------------------------

def rivals(nation_id: str) -> list[Any]:
    """The two rival nations of ``nation_id`` (exactly 2, from the data
    file). An unknown nation has no rivals."""
    nation = data().get_nation(nation_id)
    rivals_list = nation.get("rivals", [])
    return list(rivals_list) if isinstance(rivals_list, list) else []


def piracy_deltas(nation_id: str) -> dict[str, int]:
    """The full piracy rep-delta block for one act against ``nation_id``:
    ``{nation_id: -20, rival_a: +2, rival_b: +2}``. Charged **once per
    battle at battle start** by the same funnel that charges the −20
    (`60-*` §4.11.10), so applying it twice is impossible by
    construction."""
    out: dict[str, int] = {}
    if not nation_id:
        return out
    out[nation_id] = PIRACY_REPUTATION
    for rival_id in rivals(nation_id):
        rival = str(rival_id)
        if not rival or rival == nation_id:
            continue
        out[rival] = int(out.get(rival, 0)) + RIVAL_REPUTATION
    return out


def apply_piracy(st: PersonState, qs: QuestState, nation_id: str) \
        -> dict[str, int]:
    """Applies :func:`piracy_deltas` through
    :func:`character.add_reputation` and then re-evaluates the bounty
    threshold (a piracy act can both deepen a bounty and create a fresh
    one). Returns the applied deltas."""
    deltas = piracy_deltas(nation_id)
    for delta_id in deltas:
        character_lib.add_reputation(st, str(delta_id), int(deltas[delta_id]))
    evaluate_all(st, qs)
    return deltas


# --- Issue (docs/70-* §4.9.5) --------------------------------------------

def has_bounty(qs: QuestState, nation_id: str) -> bool:
    """``True`` while ``nation_id`` holds a bounty against the player."""
    return nation_id in qs.bounties


def record(qs: QuestState, nation_id: str) -> dict[str, Any]:
    """The bounty record ``{amount, day}`` for ``nation_id`` (``{}`` when
    none)."""
    raw = qs.bounties.get(nation_id)
    return raw if isinstance(raw, dict) else {}


def amount(qs: QuestState, nation_id: str) -> int:
    """The amount the palace charges to clear ``nation_id``'s bounty (0
    when none). Fixed at issue time (§4.9.5), not recomputed from the
    live reputation."""
    return int(record(qs, nation_id).get("amount", 0))


def bountied_nations(qs: QuestState) -> list[str]:
    """Every nation currently holding a bounty, sorted for a stable UI
    order."""
    return sorted(qs.bounties.keys())


def issue(st: PersonState, qs: QuestState, nation_id: str) \
        -> dict[str, Any]:
    """Issues a bounty for ``nation_id`` when the reputation is at or
    below −50 and none exists yet; returns the new record (``{}`` when
    nothing was issued)."""
    if not nation_id or has_bounty(qs, nation_id):
        return {}
    reputation = character_lib.reputation(st, nation_id)
    if reputation > BOUNTY_THRESHOLD:
        return {}
    entry = {
        "amount": BOUNTY_GOLD_PER_REP * abs(reputation),
        "day": int(st.day),
    }
    qs.bounties[nation_id] = entry
    # EventBus.bounty_issued — the caller's WS frame.
    return entry


def evaluate_all(st: PersonState, qs: QuestState) -> list[str]:
    """Re-evaluates every nation's bounty after any reputation change. A
    nation that climbs back above the threshold **without** clearing does
    not lose its bounty (only the two §4.9.5 paths clear it), so this
    only ever issues."""
    issued: list[str] = []
    for nation in data().nations_list:
        nation_id = str(nation.get("id", ""))
        if issue(st, qs, nation_id):
            issued.append(nation_id)
    return issued


# --- Clearing (docs/70-* §4.9.5) -----------------------------------------

def can_pay_off(qs: QuestState, st: PersonState, nation_id: str) -> bool:
    """``True`` when the player can pay ``nation_id``'s bounty right now."""
    return has_bounty(qs, nation_id) and st.gold >= amount(qs, nation_id)


def pay_off(qs: QuestState, st: PersonState, nation_id: str) -> bool:
    """Palace path: charges the fixed amount and clears the bounty."""
    if not can_pay_off(qs, st, nation_id):
        return False
    st.gold -= amount(qs, nation_id)  # GameState.add_gold(-amount)
    _clear(qs, st, nation_id)
    return True


def clear_by_surrender(qs: QuestState, st: PersonState,
                       nation_id: str) -> bool:
    """Surrender path (`60-*` §4.11.7): the flagship was taken by a hunter
    of ``nation_id``; the bounty clears as well."""
    if not has_bounty(qs, nation_id):
        return False
    _clear(qs, st, nation_id)
    return True


def _clear(qs: QuestState, st: PersonState, nation_id: str) -> None:
    """The shared clearing body: rep → exactly −10, bounty removed,
    announced."""
    current = character_lib.reputation(st, nation_id)
    # ``add_reputation`` clamps, so the delta that lands exactly on −10 is
    # computed from the live value (a direct write would bypass the clamp
    # and the ``player.reputation`` shape rule).
    character_lib.add_reputation(st, nation_id, CLEARED_REPUTATION - current)
    qs.bounties.pop(nation_id, None)
    # EventBus.bounty_cleared — the caller's WS frame.


# --- Closed ports (docs/70-* §4.9.6, 30-* §4.2) -------------------------

def is_port_closed(qs: QuestState, port_id: str) -> bool:
    """``True`` when every facility of ``port_id`` is closed: the player
    holds a bounty from the port's nation."""
    port = data().get_port(port_id)
    if not port:
        return False
    return has_bounty(qs, str(port.get("nation_id", "")))


def can_open_facility(qs: QuestState, port_id: str,
                      facility_id: str) -> bool:
    """``True`` when ``facility_id`` may open at ``port_id``: normally
    every facility of an open port; for a closed port **only** the palace
    of the bountied nation's capital (the §4.9.5 pay-off path — the
    anti-lockout exception)."""
    if not is_port_closed(qs, port_id):
        return True
    if facility_id != "palace":
        return False
    port = data().get_port(port_id)
    nation_id = str(port.get("nation_id", ""))
    return str(data().get_nation(nation_id).get("capital_port_id", "")) \
        == port_id


def can_pay_here(qs: QuestState, port_id: str) -> bool:
    """``True`` when a closed port's palace offers the pay-off row."""
    return is_port_closed(qs, port_id) \
        and can_open_facility(qs, port_id, "palace")
