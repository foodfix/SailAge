"""server.sim.player.character — the player Person (M1).

Python port of ``scripts/player/character.gd`` (the frozen parity oracle
until the M6 cutover). Normative contract:
docs/50-CHARACTER-AND-PROGRESSION.md §4.1 (two-step creation), §4.2
(attributes & nation bonus), §4.4 (XP, levels & allocation), §4.5.5
(recruit/dismiss), §4.6 (reputation), §4.8 (the v9 save block shape);
docs/90-ARCHITECTURE.md §0/§4 (pure logic, no scene code).

The player block shape is the v9 Person block (docs/50-* §4.8):
``{nation_id, background_id, attributes{5}, skills{8}, skill_counters{8},
alloc_pending, xp, level, officers[], reputation, profit_by_nation,
profit_rep_awarded, equipment}`` — ``autopilot`` stays absent until the
sailing module writes it (§4.8: present only while an appointed voyage is
active). This module never adds transient keys to the block (the level-up
toast flag is the session-transient ``PersonState.pending_levelup``, per
the package state convention — see ``server/sim/player/__init__.py``).

State convention: the GDScript statics read/mutated the ``GameState``
singleton; here every stateful function takes the caller's
:class:`~server.sim.player.PersonState` (``st``) as its first argument and
mutates it in place. The DataLoader singleton access became an explicit
``store: DataStore`` argument (``90-*`` §0: the server holds both).
``pending_levelup``/``pending_raise`` live on the state object, not as
module globals, so the §4.8 payload keeps exactly its locked shape.

Dependency direction (mirrors character.gd's preload): this module imports
``skills`` for the KEYS table and the effective-skill reads;
skills.py never imports this module at parse time.

RNG-free: the oracle file has no ``rand*`` call (verified at port time);
every rule below is deterministic.
"""

from __future__ import annotations

import math
from typing import Any, Final

from server.sim.data import DataStore
from server.sim.player import skills
from server.sim.player import PersonState
from server.sim.player.skills import KEYS, LOYALTY_START, SKILL_MAX

__all__ = [
    "OFFICER_MAX",
    "LEVEL_CAP",
    "XP_LEVEL_UNIT",
    "BASE_ATTRIBUTE",
    "ATTR_MIN",
    "ATTR_MAX",
    "NATION_BONUS_AMOUNT",
    "BACKGROUND_ATTR_BONUS",
    "BACKGROUND_SKILL_BONUS",
    "ATTRIBUTES",
    "SKILL_KEYS",
    "ATTR_ALLOC_TOTAL",
    "SKILL_ALLOC_TOTAL",
    "ALLOC_ITEM_CAP",
    "CREATION_ATTR_MAX",
    "CREATION_SKILL_MAX",
    "ALLOC_PER_LEVEL",
    "CHA_PRICE_DIVISOR",
    "CHA_PRICE_MULT_MIN",
    "REPUTATION_MIN",
    "REPUTATION_MAX",
    "PROFIT_PER_REP",
    "PROFIT_KEY",
    "PROFIT_AWARDED_KEY",
    "SPEED_BONUS_MIN",
    "SPEED_BONUS_MAX",
    "SPEED_BONUS_DIVISOR",
    "LEGACY_STAT_MAP",
    "ROLE_STAT_BONUS",
    "attribute",
    "attributes",
    "starting_person",
    "attr_alloc_total",
    "skill_alloc_total",
    "base_stat",
    "effective_stat",
    "officer_bonus",
    "officer_bonus_excluding",
    "speed_bonus",
    "speed_bonus_for",
    "sighting_radius",
    "sighting_radius_for",
    "desertion_multiplier",
    "loss_multiplier_for",
    "mutiny_multiplier",
    "storm_damage_multiplier",
    "storm_chance_multiplier",
    "charisma_price_multiplier",
    "level_for_xp",
    "xp_for_level",
    "current_xp",
    "current_level",
    "xp_to_next_level",
    "alloc_pending",
    "award_xp",
    "consume_pending_levelup",
    "add_profit_xp",
    "allocate",
    "employed_officers",
    "officer_count",
    "is_employed",
    "recruit_cost",
    "can_recruit",
    "recruit",
    "dismiss",
    "officer_wages",
    "reputation",
    "add_reputation",
    "add_profit_reputation",
    "profit_by_nation",
]

# --- Person attributes (docs/50-* §4.2) --------------------------------------

## Locked constants (docs/50-* §4.1–§4.5).
OFFICER_MAX: Final[int] = 12
LEVEL_CAP: Final[int] = 20
## ``level = floor(sqrt(xp / XP_LEVEL_UNIT)) + 1`` (docs/50-* §4.4).
XP_LEVEL_UNIT: Final[float] = 50.0
## Base value of every attribute at new game (docs/50-* §4.2).
BASE_ATTRIBUTE: Final[int] = 10
## Attribute bounds (docs/50-* §4.4: allocation clamps to [1, 100]; every
## attribute/skill write clamps everywhere, §6).
ATTR_MIN: Final[int] = 1
ATTR_MAX: Final[int] = 100
## Flat +5 nation bonus on one attribute and one signature skill
## (docs/50-* §4.2.2; the pair per nation lives in ``data/nations.json``
## ``bonus_attribute``/``bonus_skill`` — nothing hardcoded here).
NATION_BONUS_AMOUNT: Final[int] = 5
## Background bonuses (docs/50-* §4.1 step ①): one attribute +3, one skill +5,
## from ``data/backgrounds.json``.
BACKGROUND_ATTR_BONUS: Final[int] = 3
BACKGROUND_SKILL_BONUS: Final[int] = 5

## Attribute order used by the character card / save block (docs/50-* §4.2).
ATTRIBUTES: Final[tuple[str, ...]] = (
    "constitution", "intellect", "charisma", "courage", "luck",
)
## The 8 player skills, single-sourced in skills.py (docs/50-* §4.3).
SKILL_KEYS: Final[tuple[str, ...]] = KEYS

## Creation free points (docs/50-* §4.1 step ②): attributes +5 total and
## skills +3 total, single-item cap +3, must spend all before confirm.
ATTR_ALLOC_TOTAL: Final[int] = 5
SKILL_ALLOC_TOTAL: Final[int] = 3
ALLOC_ITEM_CAP: Final[int] = 3

## Creation extremes (docs/50-* §4.1 step 4, normative): the closed forms
## ``10 + 5 (nation) + 3 (background) + 3 (cap) = 21`` and
## ``0 + 5 + 5 + 3 = 13``.
CREATION_ATTR_MAX: Final[int] = 21
CREATION_SKILL_MAX: Final[int] = 13

## Level-up allocation (docs/50-* §4.4): +2 pending points per level gained,
## persisted in the player block; the toast flag is the session-transient
## ``PersonState.pending_levelup``.
ALLOC_PER_LEVEL: Final[int] = 2

## Signing cost / loyalty-gain price multiplier (docs/50-* §4.2.1 charisma row,
## §4.5.2): ``clamp(1 − (CHA−10)/200, 0.5, 1.0)`` — CHA 10 → ×1.0, 60 → ×0.75,
## 100 → ×0.55 (the straight line 1 − 90/200; the formula's own clamp bottoms
## out at ×0.5). Also applied to rumour purchases and bounty pinpoints (their
## base prices live in ``30-*``/``70-*``; this doc owns the multiplier).
CHA_PRICE_DIVISOR: Final[float] = 200.0
CHA_PRICE_MULT_MIN: Final[float] = 0.5

## Reputation is an integer −100…+100 per nation (docs/50-* §4.6).
REPUTATION_MIN: Final[int] = -100
REPUTATION_MAX: Final[int] = 100

## §4.6 "+1 per 1,000g cumulative profit sold at a nation's ports". The two
## player-block keys back the accumulator and must survive save/load (§4.8) —
## see :func:`add_profit_reputation`.
PROFIT_PER_REP: Final[int] = 1000
PROFIT_KEY: Final[str] = "profit_by_nation"
PROFIT_AWARDED_KEY: Final[str] = "profit_rep_awarded"

## Speed bonus clamp from docs/50-* §4.3.1 / docs/20-* §4.4: ``skill/300``,
## clamp [0, +0.30] (the old ``(S−10)/100`` clamp [−0.10, +0.20] is deleted).
SPEED_BONUS_MIN: Final[float] = 0.0
SPEED_BONUS_MAX: Final[float] = 0.30
SPEED_BONUS_DIVISOR: Final[float] = 300.0

# --- Person attributes (docs/50-* §4.2) --------------------------------------

def attribute(st: PersonState, key: str) -> int:
    """The player's own attribute value for ``key``, read VERBATIM.

    No read-side clamp: 1–100 is a WRITE-side rule (allocate/starting_person
    clamp); formulas consume the stored value exactly so the §4.2 pinned
    formulas stay exact at fixture boundaries. A missing key reads the base
    10."""
    values: dict[str, Any] = st.player.get("attributes", {})
    return int(values.get(key, BASE_ATTRIBUTE))


def attributes(st: PersonState) -> dict[str, int]:
    """A copy of the player's five attributes (the §4.8 block; missing keys
    read as the base 10)."""
    return {key: attribute(st, key) for key in ATTRIBUTES}


# --- New-game Person (docs/50-* §4.1) -----------------------------------------

def starting_person(store: DataStore, nation_id: str, background_id: str,
                    attr_alloc: dict[str, int] | None = None,
                    skill_alloc: dict[str, int] | None = None) -> dict[str, Any]:
    """Builds the fresh §4.1 player block: attributes base 10 + the nation's
    ``bonus_attribute`` +5 + the background's attribute +3 + ``attr_alloc``;
    skills 0 + the nation's ``bonus_skill`` +5 + the background's skill +5 +
    ``skill_alloc``; ``skill_counters`` all 0, ``alloc_pending`` 0, xp 0 /
    level 1, no officers, the §4.6 reputation map, the two profit
    accumulators empty and the §4.8 equipment block. ``autopilot`` is
    deliberately absent (§4.8).

    Free-point allocations are capped here (§4.1 step ②: per-item +3, totals
    +5/+3) so a caller cannot break the §4.1 step-4 creation extremes
    (attribute ≤ 21, skill ≤ 13). An unknown nation/background id simply
    contributes no bonus."""
    attr_alloc = attr_alloc or {}
    skill_alloc = skill_alloc or {}
    nation: dict[str, Any] = store.get_nation(nation_id)
    background: dict[str, Any] = store.get_background(background_id)
    bonus_attribute = str(nation.get("bonus_attribute", ""))
    bonus_skill = str(nation.get("bonus_skill", ""))

    attributes_out: dict[str, int] = {}
    for key in ATTRIBUTES:
        value = BASE_ATTRIBUTE
        if key == bonus_attribute:
            value += NATION_BONUS_AMOUNT
        value += _capped_alloc(attr_alloc, key, ATTR_ALLOC_TOTAL,
                               attr_alloc_total(attr_alloc))
        attributes_out[key] = _clampi(value, ATTR_MIN, ATTR_MAX)

    skills_out: dict[str, int] = {}
    bg_skill_map: dict[str, Any] = background.get("skill_bonus", {}) or {}
    bg_skill_key = str(next(iter(bg_skill_map))) if bg_skill_map else ""
    for key in SKILL_KEYS:
        value = 0
        if key == bonus_skill:
            value += NATION_BONUS_AMOUNT
        if key == bg_skill_key:
            value += BACKGROUND_SKILL_BONUS
        value += _capped_alloc(skill_alloc, key, SKILL_ALLOC_TOTAL,
                               skill_alloc_total(skill_alloc))
        skills_out[key] = _clampi(value, 0, SKILL_MAX)
    # The background's attribute +3 lands on exactly the one key the data names.
    bg_attr_map: dict[str, Any] = background.get("attribute_bonus", {}) or {}
    bg_attr_key = str(next(iter(bg_attr_map))) if bg_attr_map else ""
    if bg_attr_key and bg_attr_key in attributes_out:
        attributes_out[bg_attr_key] = _clampi(
            int(attributes_out[bg_attr_key]) + BACKGROUND_ATTR_BONUS,
            ATTR_MIN, ATTR_MAX)

    reputation: dict[str, int] = {}
    for entry in store.nations_list:
        reputation[str(entry.get("id", ""))] = 0
    if nation:
        reputation[nation_id] = int(nation.get("start_reputation", 0))

    return {
        "nation_id": nation_id,
        "background_id": background_id,
        "attributes": attributes_out,
        "skills": skills_out,
        "skill_counters": _zero_counters(),
        "alloc_pending": 0,
        "xp": 0,
        "level": 1,
        "officers": [],
        "reputation": reputation,
        PROFIT_KEY: {},
        PROFIT_AWARDED_KEY: {},
        "equipment": {"weapon": "", "armor": ""},
    }


def attr_alloc_total(alloc: dict[str, int]) -> int:
    """The total free points in an attribute allocation draft (§4.1 step ②
    bookkeeping)."""
    return _alloc_sum(alloc)


def skill_alloc_total(alloc: dict[str, int]) -> int:
    """The total free points in a skill allocation draft."""
    return _alloc_sum(alloc)


def _alloc_sum(alloc: dict[str, int]) -> int:
    total = 0
    for value in alloc.values():
        total += max(0, int(value))
    return total


def _capped_alloc(alloc: dict[str, int], key: str, budget: int,
                  draft_total: int) -> int:
    """One item of a creation draft, capped per-item at +3 and (when the
    whole draft exceeds its total budget) trimmed proportionally to the
    budget — the creation UI enforces "spend all"; this keeps any caller
    inside §4.1."""
    requested = max(0, int(alloc.get(key, 0)))
    capped = min(requested, ALLOC_ITEM_CAP)
    if draft_total > budget:
        capped = min(capped, requested - (draft_total - budget))
    return max(0, capped)


def _zero_counters() -> dict[str, int]:
    return {key: 0 for key in SKILL_KEYS}


# --- Legacy stat shims (docs/50-* §4.2.3 migration) ---------------------------
#
# The four-stat "leadership/seamanship/combat/navigation/luck" block is
# REMOVED from the save (v9, no migration) — but un-owned consumers
# (battle_sim, duel, the S14/S18 panels) still call these names in the
# Godot era. Each shim reads the new model through one table:
#   leadership → attribute charisma; combat → skill swordplay;
#   seamanship/navigation → the same-named skills; luck → attribute luck.

## The legacy-name → new-model map (§4.2.3 migration table).
LEGACY_STAT_MAP: Final[dict[str, str]] = {
    "leadership": "charisma",
    "combat": "swordplay",
    "seamanship": "seamanship",
    "navigation": "navigation",
    "luck": "luck",
}

## The Phase-1 role table, kept only so un-owned panel code keeps parsing;
## nothing in the new model reads it (§4.5.3: flat role bonuses are deleted).
ROLE_STAT_BONUS: Final[dict[str, dict[str, int]]] = {
    "navigator": {"navigation": 10},
    "boatswain": {"seamanship": 10},
    "gunner": {"gunnery": 10},
}


def base_stat(st: PersonState, stat_name: str) -> int:
    """Legacy read: the new-model value behind an old stat name (0 for an
    unknown name). Officers add nothing here (§4.5.3 — contribution is
    per-post and lives in skills.officer_contribution)."""
    mapped = LEGACY_STAT_MAP.get(stat_name, "")
    if not mapped:
        return 0
    if mapped in ATTRIBUTES:
        return attribute(st, mapped)
    return skills.skill(st, mapped)


def effective_stat(st: PersonState, stat_name: str) -> int:
    """Legacy read: :func:`base_stat` (the officer term is gone; see the
    shim header)."""
    return base_stat(st, stat_name)


def officer_bonus(_stat_name: str) -> int:
    """Legacy: the officer contribution to a legacy stat — always 0 (§4.5.3)."""
    return 0


def officer_bonus_excluding(_stat_name: str, _officer_id: str) -> int:
    """Legacy twin of :func:`officer_bonus` (the "without this officer" diff)."""
    return 0


def speed_bonus(st: PersonState, store: DataStore) -> float:
    """docs/50-* §4.3.1 / ``20-*`` §4.4: ``skill/300``, clamped [0, +0.30],
    on the EFFECTIVE seamanship value."""
    return speed_bonus_for(skills.effective_skill(st, store, "seamanship"))


def speed_bonus_for(seamanship: int) -> float:
    """:func:`speed_bonus` for an explicit effective seamanship value — the
    pure formula, so derived-effect rows can difference "with" against
    "without" one officer without a second copy of the rule."""
    raw = seamanship / SPEED_BONUS_DIVISOR
    return _clampf(raw, SPEED_BONUS_MIN, SPEED_BONUS_MAX)


def sighting_radius(st: PersonState, store: DataStore) -> int:
    """docs/50-* §4.3.1 / ``20-*`` §4.11: ``48 + floor(navigation skill / 12)``
    (the Phase-1 ``48 + floor((nav − 10)/10)`` is migrated, §4.2.3), on the
    EFFECTIVE navigation value."""
    return sighting_radius_for(skills.effective_skill(st, store, "navigation"))


def sighting_radius_for(navigation: int) -> int:
    """:func:`sighting_radius` for an explicit effective navigation value."""
    return 48 + int(math.floor(navigation / 12.0))


def desertion_multiplier(st: PersonState) -> float:
    """docs/50-* §4.2.1 charisma row: desertion × ``(1 − (CHA−10)/200)`` —
    the formula is unchanged from the leadership era; only the source moved.
    The doc gives no lower clamp; a negative multiplier would turn a loss
    into a gain, so this implementation floors it at 0 (no desertion
    possible)."""
    return loss_multiplier_for(attribute(st, "charisma"))


def loss_multiplier_for(charisma: int) -> float:
    """:func:`desertion_multiplier` for an explicit charisma value (pure
    formula)."""
    return max(0.0, 1.0 - (charisma - BASE_ATTRIBUTE) / 200.0)


def mutiny_multiplier(st: PersonState) -> float:
    """Same formula and clamp as :func:`desertion_multiplier`
    (docs/50-* §4.2.1)."""
    return loss_multiplier_for(attribute(st, "charisma"))


def storm_damage_multiplier(st: PersonState) -> float:
    """docs/50-* §4.2.1 luck row: storm damage × ``(1 − luck/250)`` —
    CONTINUOUS (the Phase-1 ``luck ≥ 50 → ×0.75`` step is deleted;
    player-only)."""
    return 1.0 - attribute(st, "luck") / 250.0


def storm_chance_multiplier(st: PersonState) -> float:
    """docs/50-* §4.2.1: storm chance ``× (1 − luck / 400)`` (unchanged)."""
    return 1.0 - attribute(st, "luck") / 400.0


def charisma_price_multiplier(st: PersonState) -> float:
    """The charisma price multiplier ``clamp(1 − (CHA−10)/200, 0.5, 1.0)``
    (§4.2.1): applied to the officer signing fee (§4.5.2), rumour purchases
    and bounty pinpoints (``70-*`` §4.5 owns those base prices)."""
    return _clampf(
        1.0 - (attribute(st, "charisma") - BASE_ATTRIBUTE) / CHA_PRICE_DIVISOR,
        CHA_PRICE_MULT_MIN, 1.0)


# --- XP, levels & allocation (docs/50-* §4.4) ---------------------------------

def level_for_xp(xp: int) -> int:
    """``floor(sqrt(xp / 50)) + 1``, capped at 20."""
    value = int(math.floor(math.sqrt(max(xp, 0) / XP_LEVEL_UNIT))) + 1
    return _clampi(value, 1, LEVEL_CAP)


def xp_for_level(level: int) -> int:
    """Inverse of :func:`level_for_xp`: XP required to *reach* ``level``.
    Level 1 = 0 XP; level 20 = 18050 XP (docs/50-* §5)."""
    target = _clampi(level, 1, LEVEL_CAP)
    return int(XP_LEVEL_UNIT) * (target - 1) * (target - 1)


def current_xp(st: PersonState) -> int:
    return int(st.player.get("xp", 0))


def current_level(st: PersonState) -> int:
    """Derivation wins over the stored cache (docs/50-* §4.8: "stored value
    is a cache; derivation wins on mismatch"); the card therefore can never
    show a level that disagrees with the XP it prints next to it."""
    return level_for_xp(current_xp(st))


def xp_to_next_level(st: PersonState) -> int:
    """XP still needed for the next level, or −1 at the cap (the card hides
    the row)."""
    xp = current_xp(st)
    level = level_for_xp(xp)
    if level >= LEVEL_CAP:
        return -1
    return xp_for_level(level + 1) - xp


def alloc_pending(st: PersonState) -> int:
    """The persisted free-point counter (docs/50-* §4.4/§4.8)."""
    return max(0, int(st.player.get("alloc_pending", 0)))


def award_xp(st: PersonState, amount: int) -> None:
    """Adds XP and applies the §4.4 level rule. Non-positive amounts are
    ignored (a loss-making sale awards 0 XP and must not touch the level
    cache).

    On each level gained: ``alloc_pending += 2`` (the Phase-1 auto-grant of
    +1 seamanship / +1 nation stat is deleted, §4.4). Gaining several levels
    at once applies the grant once per level, matching "on each level-up";
    past the level cap no further points are granted (the derivation
    clamps)."""
    if amount <= 0:
        return
    p: dict[str, Any] = st.player
    if not p:
        print("Character.award_xp: PersonState.player is empty")
        return
    before = level_for_xp(int(p.get("xp", 0)))
    p["xp"] = int(p.get("xp", 0)) + amount
    after = level_for_xp(int(p["xp"]))
    p["level"] = after
    gained = after - before
    if gained <= 0:
        return
    p["alloc_pending"] = alloc_pending(st) + ALLOC_PER_LEVEL * gained
    st.pending_levelup = True
    print("Character: level up to %d (xp %d, alloc_pending %d)"
          % (after, int(p["xp"]), int(p["alloc_pending"])))


def consume_pending_levelup(st: PersonState) -> bool:
    """Reads and clears the pending-level-up flag; true exactly once per
    award."""
    was_pending = st.pending_levelup
    st.pending_levelup = False
    return was_pending


def add_profit_xp(st: PersonState, sell_price: int, base_price: int, qty: int) -> None:
    """docs/50-* §4.4 locked profit-XP rule:
    per-unit profit = max(0, sell_price − floor(base_price × 0.7)),
    profit = qty × per-unit, XP = floor(profit / 100)."""
    per_unit = max(0, sell_price - int(math.floor(base_price * 0.7)))
    profit = max(qty, 0) * per_unit
    award_xp(st, int(math.floor(profit / 100.0)))


def allocate(st: PersonState, draft: dict[str, int]) -> bool:
    """The §4.4 allocation draft: ``{attribute_key: +n}``. Accepted only when
    every key is a real attribute, every amount is positive, the total fits
    the pending counter AND no attribute would pass 100 — a draft that would
    overflow any attribute is refused whole (the caller reports it; points
    are never partially spent, §4.4/§6). On success the attributes move and
    the spent points leave ``alloc_pending``."""
    if not draft:
        return False
    pending = alloc_pending(st)
    total = 0
    for key, raw in draft.items():
        if key not in ATTRIBUTES:
            return False
        amount = int(raw)
        if amount <= 0:
            return False
        total += amount
        if attribute(st, key) + amount > ATTR_MAX:
            return False
    if total > pending:
        return False
    p: dict[str, Any] = st.player
    values: dict[str, Any] = p.get("attributes", {})
    for key, raw in draft.items():
        values[key] = _clampi(int(values.get(key, BASE_ATTRIBUTE))
                              + int(raw), ATTR_MIN, ATTR_MAX)
    p["attributes"] = values
    p["alloc_pending"] = pending - total
    return True


# --- Officers (docs/50-* §4.5) --------------------------------------------------

def employed_officers(st: PersonState) -> list[Any]:
    return st.player.get("officers", [])


def officer_count(st: PersonState) -> int:
    return len(employed_officers(st))


def is_employed(st: PersonState, officer_id: str) -> bool:
    return officer_id in employed_officers(st)


def recruit_cost(st: PersonState, store: DataStore, officer_id: str) -> int:
    """The §4.2.1 charisma price multiplier applied to the one-time signing
    cost ``ceil(wage_daily × 10)`` (docs/50-* §4.5.2). Computed in exact
    integer arithmetic (``wage × 10 × (210 − CHA) / 200`` after the
    multiplier's clamps) so float noise can never bump a boundary fee up a
    whole gold."""
    officer: dict[str, Any] = store.get_officer(officer_id)
    if not officer:
        return 0
    # multiplier = clamp(1 − (CHA−10)/200, 0.5, 1.0) → numerator ∈ [100, 200].
    numerator = _clampi(210 - attribute(st, "charisma"), 100, 200)
    product = int(officer.get("wage_daily", 0)) * 10 * numerator
    return (product + 199) // 200  # integer ceil(product / 200)


def can_recruit(st: PersonState, store: DataStore, officer_id: str) -> bool:
    """True when the officer exists, is not already aboard, there is roster
    room (OFFICER_MAX = 12, §4.5.2) and the signing cost is affordable —
    the §6 edge rule keeps the recruit button disabled (with the price
    shown) when gold is short."""
    officer: dict[str, Any] = store.get_officer(officer_id)
    if not officer:
        return False
    if is_employed(st, officer_id):
        return False
    if officer_count(st) >= OFFICER_MAX:
        return False
    return st.gold >= recruit_cost(st, store, officer_id)


def recruit(st: PersonState, store: DataStore, officer_id: str) -> bool:
    """Adds the officer to ``player.officers`` and pays the signing cost
    (§4.5.5). Seeds the §4.8/``90-*`` §8 ``officer_states`` entry: loyalty
    50, fresh clocks, idle (``post_id = ""``), ``wage_mult`` 1.0. Returns
    False (state untouched) whenever :func:`can_recruit` is False."""
    if not can_recruit(st, store, officer_id):
        return False
    cost = recruit_cost(st, store, officer_id)
    st.gold -= cost  # GameState.add_gold(-cost)
    p: dict[str, Any] = st.player
    officers: list[Any] = p.get("officers", [])
    officers.append(officer_id)
    p["officers"] = officers
    st.officer_states[officer_id] = {
        "loyalty": LOYALTY_START,
        "sea_days": 0,
        "post_id": "",
        "ship_id": "",
        "talk_cd_day": 0,
        "gift_cd_day": 0,
        "defeats": 0,
        "wage_mult": 1.0,
    }
    print("Character: recruited %s for %dg" % (officer_id, cost))
    return True


def dismiss(st: PersonState, officer_id: str) -> bool:
    """Removes the officer; no severance (docs/50-* §4.5.5). The state entry
    is cleared with the roster row, which also frees any post the officer
    held (the post is derived from the state, §4.8) and resets a re-hire to
    50."""
    p: dict[str, Any] = st.player
    officers: list[Any] = p.get("officers", [])
    if officer_id not in officers:
        return False
    officers.remove(officer_id)
    p["officers"] = officers
    st.officer_states.pop(officer_id, None)
    print("Character: dismissed %s" % officer_id)
    return True


def officer_wages(st: PersonState, store: DataStore) -> int:
    """Σ ``wage_daily × wage_mult`` for the daily ledger (docs/50-* §4.5.2;
    the ×1.25 raise event lives in the §4.5.4 ``wage_mult``). Officer
    skills, loyalty and posts live in skills.py."""
    total = 0
    for officer_id in employed_officers(st):
        officer: dict[str, Any] = store.get_officer(str(officer_id))
        mult = 1.0
        state: dict[str, Any] = st.officer_states.get(str(officer_id), {})
        if state:
            mult = float(state.get("wage_mult", 1.0))
        total += _round_half_away(int(officer.get("wage_daily", 0)) * mult)
    return total


# --- Reputation (docs/50-* §4.6) -------------------------------------------------

def reputation(st: PersonState, nation_id: str) -> int:
    rep: dict[str, Any] = st.player.get("reputation", {})
    return int(rep.get(nation_id, 0))


def add_reputation(st: PersonState, nation_id: str, delta: int) -> int:
    """Applies a delta, clamped to −100…+100, and returns the new value."""
    p: dict[str, Any] = st.player
    if not p:
        print("Character.add_reputation: PersonState.player is empty")
        return 0
    rep: dict[str, Any] = p.get("reputation", {})
    value = _clampi(int(rep.get(nation_id, 0)) + delta,
                    REPUTATION_MIN, REPUTATION_MAX)
    rep[nation_id] = value
    p["reputation"] = rep
    return value


def add_profit_reputation(st: PersonState, nation_id: str, profit: int) -> int:
    """docs/50-* §4.6 Phase-1 source: +1 per 1,000g of **cumulative** sale
    profit at that nation's ports, clamped by :func:`add_reputation`.

    Two ``player``-block keys track it — ``profit_by_nation`` (lifetime
    profit) and ``profit_rep_awarded`` (points already paid out) — so the
    threshold carries across transactions (600g then 400g grants the point
    neither earns alone), the rule survives save/load, and it can never
    double-award. Reputation from other sources is left untouched.

    Returns the reputation points granted (0 for a loss or a sub-threshold
    gain)."""
    if not nation_id or profit <= 0:
        return 0
    p: dict[str, Any] = st.player
    if not p:
        print("Character.add_profit_reputation: PersonState.player is empty")
        return 0
    totals: dict[str, Any] = p.get(PROFIT_KEY, {})
    total = int(totals.get(nation_id, 0)) + profit
    totals[nation_id] = total
    p[PROFIT_KEY] = totals

    awarded: dict[str, Any] = p.get(PROFIT_AWARDED_KEY, {})
    earned = int(math.floor(total / float(PROFIT_PER_REP)))
    already = int(awarded.get(nation_id, 0))
    if earned <= already:
        awarded[nation_id] = already
        p[PROFIT_AWARDED_KEY] = awarded
        return 0
    awarded[nation_id] = earned
    p[PROFIT_AWARDED_KEY] = awarded
    add_reputation(st, nation_id, earned - already)
    return earned - already


def profit_by_nation(st: PersonState, nation_id: str) -> int:
    """Lifetime sale profit booked against a nation (§4.6; 0 when never
    traded there). Backed by ``player.profit_by_nation``."""
    totals: dict[str, Any] = st.player.get(PROFIT_KEY, {})
    return int(totals.get(nation_id, 0))


# --- Helpers ----------------------------------------------------------------------

def _clampi(value: int, low: int, high: int) -> int:
    """GDScript ``clampi``."""
    return max(low, min(value, high))


def _clampf(value: float, low: float, high: float) -> float:
    """GDScript ``clampf``."""
    return max(low, min(value, high))


def _round_half_away(value: float) -> int:
    """GDScript ``int(round(x))`` — halfway cases round AWAY from zero.
    Python's ``round`` is banker's rounding, which would differ at x.5
    boundaries (e.g. the ×1.25 wage bill at wage 30 → 37.5 → GDScript 38);
    wages are non-negative, so floor(x + 0.5) is the exact mirror."""
    return int(math.floor(value + 0.5))
