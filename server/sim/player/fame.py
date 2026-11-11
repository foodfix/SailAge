"""server.sim.player.fame — fame and the nobility-title ladder (M1).

Python port of ``scripts/player/fame.gd`` (the frozen parity oracle until
the M6 cutover). Normative contract: docs/70-QUESTS-DISCOVERY-ENDGAME.md
§4.1 (fame), §4.3 + §4.9.1 (fame sources) + §4.9.2 (title ladder
mechanics); docs/90-ARCHITECTURE.md §0/§4 (pure logic, no scene code).

Owns three run-state fields — ``PersonState.fame``, ``PersonState.titles``,
``PersonState.completed_royal_missions`` — and exposes the ladder
arithmetic every other module reads:

  * ``title_bonus(nation_id)`` — the sell-price multiplier ``30-*`` §4.2 applies;
  * ``repair_discount(nation_id)`` — the count-grant 0.8 factor;
  * ``quest_slots_bonus()`` — the viscount-grant extra quest slot;
  * ``next_rank`` / ``can_promote`` / ``grant``;
  * ``is_duke`` — the retirement gate (70-* §4.7).

Port deviation (declared): the GDScript functions announced transitions on
the EventBus autoload (``fame_changed`` after :func:`add`,
``title_granted`` after :func:`grant`). In the web-stack era those are
server WS ``event`` frames owned by the caller (``90-*`` §0.3), so the
functions return the new value / granted rank and emit nothing themselves.

The ladder itself is data (``LADDER``, below), so a seventh rank is one
edit — but the *grants* are code, exactly as ``10-*`` §4.9 says enums are.

RNG-free: the oracle file has no ``rand*`` call (verified at port time).
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any, Final

if TYPE_CHECKING:
    from server.sim.player import PersonState

__all__ = [
    "RANKS",
    "RANK_NONE",
    "RANK_KNIGHT",
    "RANK_BARON",
    "RANK_VISCOUNT",
    "RANK_COUNT",
    "RANK_DUKE",
    "SELL_BONUS_KNIGHT",
    "SELL_BONUS_BARON",
    "REPAIR_DISCOUNT_COUNT",
    "QUEST_SLOT_BONUS",
    "LADDER",
    "value",
    "add",
    "title",
    "rank_index",
    "next_rank",
    "next_fame_required",
    "next_missions_required",
    "royal_missions",
    "can_promote",
    "grant",
    "add_royal_mission",
    "is_duke",
    "any_duke",
    "earned_titles",
    "title_bonus",
    "repair_discount",
    "quest_slots_bonus",
    "next_requirements",
]

## Rank ids, lowest first (docs/70-* §4.9.2). Index = ladder position.
RANKS: Final[tuple[str, ...]] = (
    "none", "knight", "baron", "viscount", "count", "duke",
)
## The four grants the §4.3 table names. Only ``none``/``knight``/``baron``
## differ on sell price; viscount adds a quest slot; count adds the repair
## discount; duke unlocks retirement.
RANK_NONE: Final[str] = "none"
RANK_KNIGHT: Final[str] = "knight"
RANK_BARON: Final[str] = "baron"
RANK_VISCOUNT: Final[str] = "viscount"
RANK_COUNT: Final[str] = "count"
RANK_DUKE: Final[str] = "duke"

## §4.9.2: sell-price multiplier by rank — ``1.05`` at knight, ``1.10`` at
## baron and above, ``1.00`` otherwise (applied to the port's **own** nation
## title).
SELL_BONUS_KNIGHT: Final[float] = 1.05
SELL_BONUS_BARON: Final[float] = 1.10
## §4.9.2: count-and-above repair cost factor at that nation's ports.
REPAIR_DISCOUNT_COUNT: Final[float] = 0.8
## §4.9.2: the viscount grant is ``+1`` slot; QuestGen owns the ``3`` base.
QUEST_SLOT_BONUS: Final[int] = 1

## The ladder: rank id → (fame required, royal missions required). ``none``
## is the starting rung and is never "granted".
LADDER: Final[dict[str, dict[str, int]]] = {
    "knight": {"fame": 100, "missions": 1},
    "baron": {"fame": 300, "missions": 2},
    "viscount": {"fame": 700, "missions": 3},
    "count": {"fame": 1500, "missions": 5},
    "duke": {"fame": 3000, "missions": 8},
}


# --- Fame (docs/70-* §4.1, §4.9.1) ---------------------------------------------

def value(st: PersonState) -> int:
    """Current fame (never negative)."""
    return max(0, int(st.fame))


def add(st: PersonState, amount: int) -> int:
    """Adds fame and returns the new value (§4.9.1: fame never decreases; a
    non-positive amount is a no-op, so a caller cannot spend fame by
    accident). The GDScript ``fame_changed`` announcement is the caller's
    WS event (see the module docstring)."""
    if amount <= 0:
        return value(st)
    st.fame = value(st) + amount
    return st.fame


# --- Titles (docs/70-* §4.9.2) ---------------------------------------------------

def title(st: PersonState, nation_id: str) -> str:
    """The rank id of ``nation_id``: its stored rank, or ``none`` when
    absent/unknown (a hand-edited save must not wedge the ladder)."""
    raw = str(st.titles.get(nation_id, RANK_NONE))
    return raw if raw in RANKS else RANK_NONE


def rank_index(rank: str) -> int:
    """The ladder position of a rank id (0 for ``none``, 5 for ``duke``; 0
    for an unknown id)."""
    try:
        return RANKS.index(rank)
    except ValueError:
        return 0


def next_rank(st: PersonState, nation_id: str) -> str:
    """The rank after ``nation_id``'s current one (``""`` at duke)."""
    index = rank_index(title(st, nation_id))
    if index + 1 >= len(RANKS):
        return ""
    return RANKS[index + 1]


def next_fame_required(st: PersonState, nation_id: str) -> int:
    """The fame the next rank needs, or −1 at the top (``palace.title.next``)."""
    rank = next_rank(st, nation_id)
    if not rank:
        return -1
    return int(LADDER[rank]["fame"])


def next_missions_required(st: PersonState, nation_id: str) -> int:
    """The royal missions the next rank needs, or −1 at the top."""
    rank = next_rank(st, nation_id)
    if not rank:
        return -1
    return int(LADDER[rank]["missions"])


def royal_missions(st: PersonState, nation_id: str) -> int:
    """Royal missions completed for ``nation_id``."""
    return max(0, int(st.completed_royal_missions.get(nation_id, 0)))


def can_promote(st: PersonState, nation_id: str) -> bool:
    """True when **both** §4.9.2 requirements for the next rank are met."""
    rank = next_rank(st, nation_id)
    if not rank:
        return False
    need = LADDER[rank]
    return value(st) >= int(need["fame"]) \
        and royal_missions(st, nation_id) >= int(need["missions"])


def grant(st: PersonState, nation_id: str) -> str:
    """Grants the next rank at a palace ceremony. Returns the new rank id,
    ``""`` when not eligible. The GDScript ``title_granted`` announcement is
    the caller's WS event (see the module docstring)."""
    if not can_promote(st, nation_id):
        return ""
    rank = next_rank(st, nation_id)
    st.titles[nation_id] = rank
    return rank


def add_royal_mission(st: PersonState, nation_id: str) -> int:
    """Adds one completed royal mission and announces nothing (the caller
    owns the ceremony/quest report), returning the new count."""
    total = royal_missions(st, nation_id)
    st.completed_royal_missions[nation_id] = total + 1
    return total + 1


def is_duke(st: PersonState, nation_id: str) -> bool:
    """True when ``nation_id``'s title is duke (§4.7 retirement gate)."""
    return title(st, nation_id) == RANK_DUKE


def any_duke(st: PersonState) -> bool:
    """True when **any** nation's title is duke (§4.7 "Duke with any nation")."""
    for nation_id in st.titles:
        if title(st, str(nation_id)) == RANK_DUKE:
            return True
    return False


def earned_titles(st: PersonState) -> list[tuple[str, str]]:
    """The non-``none`` titles as ``(nation_id, rank)`` pairs in nation-id
    order — the S16 summary rows and the character panel's title block."""
    out: list[tuple[str, str]] = []
    for nation_id in st.titles:
        rank = title(st, str(nation_id))
        if rank != RANK_NONE:
            out.append((str(nation_id), rank))
    out.sort(key=lambda pair: pair[0])
    return out


# --- Grants (docs/70-* §4.9.2) ----------------------------------------------------

def title_bonus(st: PersonState, nation_id: str) -> float:
    """The sell-price multiplier at a port of ``nation_id`` (§4.9.2):
    ``1.05`` at knight, ``1.10`` at baron and above, ``1.00`` otherwise.
    TradeEngine applies it to the **sell** side only, after the band clamp,
    using the port's own nation."""
    index = rank_index(title(st, nation_id))
    if index >= rank_index(RANK_BARON):
        return SELL_BONUS_BARON
    if index >= rank_index(RANK_KNIGHT):
        return SELL_BONUS_KNIGHT
    return 1.0


def repair_discount(st: PersonState, nation_id: str) -> float:
    """The repair-cost factor at a port of ``nation_id`` (§4.9.2): ``0.8``
    at count or duke, ``1.0`` otherwise. ShipyardEngine floors the
    discounted total once."""
    return REPAIR_DISCOUNT_COUNT if rank_index(title(st, nation_id)) \
        >= rank_index(RANK_COUNT) else 1.0


def quest_slots_bonus(st: PersonState) -> int:
    """The extra active-quest slots from titles (§4.9.2): ``1`` when any
    nation's title is viscount or higher, else ``0`` — a ``max``, never a
    sum."""
    for nation_id in st.titles:
        if rank_index(title(st, str(nation_id))) >= rank_index(RANK_VISCOUNT):
            return QUEST_SLOT_BONUS
    return 0


def next_requirements(st: PersonState, nation_id: str) -> dict[str, Any]:
    """``{fame, missions}`` the next rank needs, for the palace header
    (``-1``s at the top of the ladder)."""
    return {
        "rank": next_rank(st, nation_id),
        "fame": next_fame_required(st, nation_id),
        "missions": next_missions_required(st, nation_id),
    }
