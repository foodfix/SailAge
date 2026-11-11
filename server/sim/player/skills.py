"""server.sim.player.skills — the skill layer (M1).

Python port of ``scripts/player/skills.gd`` (the frozen parity oracle until
the M6 cutover). Normative contract: docs/50-CHARACTER-AND-PROGRESSION.md
§4.3 (skills & growth), §4.5 (officers — posts, contribution, loyalty);
docs/90-ARCHITECTURE.md §0/§4 (pure logic, no scene code).

Owns the 11-skill space (8 player + 3 officer-only), the usage-growth
counters (§4.3.1–§4.3.3), paid training (§4.3.4), the in-post officer
contribution (§4.5.3), appointments against ``data/officer_posts.json``
(§4.5.2), the officer day tick (growth clock §4.3.2 + loyalty events
§4.5.4) and the loyalty actions.

State ownership (§4.8 / ``90-*`` §8), ported per the package state
convention (see ``server/sim/player/__init__.py``): the player's own values
live in ``PersonState.player["skills"]``/``["skill_counters"]``; every
employed officer's relation lives in ``PersonState.officer_states``; the
purse/clock are ``PersonState.gold``/``PersonState.day``. The officer CARD
(``data/officers.json`` v2, reached through the caller's ``DataStore``) is
save-independent canon and is only written by the growth rule (§4.3.2: +1
per 90 in-post sea-days) — the GDScript mutates the loaded
``DataLoader.officers`` record in place and so does this port.

Dependency note (mirrors skills.gd's header): character.py imports THIS
module (the KEYS table is single-sourced here), so this module must not
import character.py at parse time — the three Character-backed reads
(``current_level``, ``attribute``) go through a lazy import at call time
(``_character``), exactly like the GDScript ``load()`` seam. The
session raise flag that GDScript reached through
``Character.set_pending_raise`` is a ``PersonState`` field here
(``st.pending_raise``), so the day tick needs no cross-import at all.

RNG-free: the oracle file has no ``rand*`` call (verified at port time);
every rule below is deterministic.
"""

from __future__ import annotations

import math
from typing import TYPE_CHECKING, Any, Final

from server.sim.data import DataStore

if TYPE_CHECKING:  # parse-time cycle guard, mirrors skills.gd's lazy load()
    from server.sim.player import PersonState

__all__ = [
    "KEYS",
    "OFFICER_KEYS",
    "SKILL_MIN",
    "SKILL_MAX",
    "GROWTH_THRESHOLD",
    "TRAIN_BASE_FEE",
    "TRAIN_INT_DIVISOR",
    "TRAIN_CAP",
    "POST_SKILL",
    "CONTRIBUTION_DERATE",
    "SIGNATURE_BONUS",
    "LOYALTY_MIN",
    "LOYALTY_MAX",
    "LOYALTY_START",
    "LOYALTY_DERATE_BELOW",
    "LOYALTY_RESIGN_BELOW",
    "LOYALTY_SIGNATURE_AT",
    "CHA_LOYALTY_DIVISOR",
    "COOLDOWN_DAYS",
    "TALK_GAIN",
    "GIFT_COST",
    "GIFT_BASE",
    "GIFT_GREEDY",
    "GIFT_HONEST",
    "RAISE_WAGE_MULT",
    "RAISE_ACCEPT_LOYALTY",
    "RAISE_REFUSE_LOYALTY",
    "OFFICER_GROWTH_DAYS",
    "skill",
    "effective_skill",
    "officer_contribution",
    "counters",
    "note_usage",
    "growth_threshold",
    "maybe_award",
    "note_sea_day",
    "training_price",
    "can_train",
    "train",
    "officers_in_post",
    "post_holder",
    "appoint",
    "officer_day_tick",
    "loyalty",
    "adjust_loyalty",
    "cha_loyalty_multiplier",
    "talk",
    "gift",
    "accept_raise",
    "refuse_raise",
]

# --- Locked constants (docs/50-* §4.3, §4.5) ---------------------------------

## Player skills (docs/50-* §4.3): 8 keys, 0–100, start 0. Single-sourced
## here — character.gd's SKILL_KEYS IS this table.
KEYS: Final[tuple[str, ...]] = (
    "seamanship", "navigation", "swordplay", "gunnery", "appraisal",
    "negotiation", "cartography", "rumour",
)
## Officer-only skills (docs/50-* §4.3.2): carried by officer cards only.
OFFICER_KEYS: Final[tuple[str, ...]] = ("medicine", "carpentry", "cooking")

## Skill bounds.
SKILL_MIN: Final[int] = 0
SKILL_MAX: Final[int] = 100

## §4.3.1 growth thresholds: +1 per N uses (counter resets on award; counters
## stop counting at skill 100, §4.3.3).
GROWTH_THRESHOLD: Final[dict[str, int]] = {
    "seamanship": 30,
    "navigation": 30,
    "swordplay": 1,
    "gunnery": 10,
    "appraisal": 20,
    "negotiation": 15,
    "cartography": 5,
    "rumour": 10,
}

## §4.3.4 paid training: one +1 costs ``ceil(level × 60 × (1 − (INT−10)/200))``;
## a skill at ≥ 60 cannot be trained (usage growth still passes 60).
TRAIN_BASE_FEE: Final[float] = 60.0
TRAIN_INT_DIVISOR: Final[float] = 200.0
TRAIN_CAP: Final[int] = 60

## §4.5.3 contribution: the ONE in-post officer's true value, derated
## ``floor(value × 0.8)`` while loyalty < 30, plus +5 on the native signature
## skill while loyalty ≥ 80. Captain posts feed their ship, never the player.
POST_SKILL: Final[dict[str, str]] = {
    "pilot": "navigation",
    "boatswain": "seamanship",
    "gunner": "gunnery",
    "surgeon": "medicine",
    "carpenter": "carpentry",
    "cook": "cooking",
}
CONTRIBUTION_DERATE: Final[float] = 0.8
SIGNATURE_BONUS: Final[int] = 5

## §4.5.4 loyalty: 0–100, starts 50 at hire; every positive delta is
## multiplied by ``1 + floor((CHA−10)/45)``; negative deltas are flat.
LOYALTY_MIN: Final[int] = 0
LOYALTY_MAX: Final[int] = 100
LOYALTY_START: Final[int] = 50
LOYALTY_DERATE_BELOW: Final[int] = 30
LOYALTY_RESIGN_BELOW: Final[int] = 15
LOYALTY_SIGNATURE_AT: Final[int] = 80
CHA_LOYALTY_DIVISOR: Final[float] = 45.0

## Officer 4 actions (§4.5.4, 80-*): talk/gift share the 10-day cooldown;
## the raise event swaps ±10 loyalty against a permanent ×1.25 wage.
COOLDOWN_DAYS: Final[int] = 10
TALK_GAIN: Final[int] = 1
GIFT_COST: Final[int] = 200
GIFT_BASE: Final[int] = 5
GIFT_GREEDY: Final[int] = 8
GIFT_HONEST: Final[int] = 3
RAISE_WAGE_MULT: Final[float] = 1.25
RAISE_ACCEPT_LOYALTY: Final[int] = 10
RAISE_REFUSE_LOYALTY: Final[int] = -10

## §4.3.2 officer growth clock: +1 per 90 employed sea-days to the post's
## skill (idle bench → the native main skill), clamped at 100.
OFFICER_GROWTH_DAYS: Final[int] = 90


def _character():
    """``scripts/player/character.gd``, imported lazily (see the module
    docstring: character.py preloads this file, so a parse-time import back
    would mirror the GDScript cyclic-reference error)."""
    from server.sim.player import character

    return character


# --- Reads (docs/50-* §4.8: stored player values; contribution at read time) -

def skill(st: PersonState, key: str) -> int:
    """The player's own skill value for ``key`` (read-clamped 0–100; 0 when
    never written — the read-side clamp the §4.8 block relies on)."""
    values: dict[str, Any] = st.player.get("skills", {})
    return _clampi(int(values.get(key, SKILL_MIN)), SKILL_MIN, SKILL_MAX)


def effective_skill(st: PersonState, store: DataStore, key: str) -> int:
    """§4.5.3: ``player skill + the one in-post officer's true value``."""
    return skill(st, key) + officer_contribution(st, store, key)


def officer_contribution(st: PersonState, store: DataStore, key: str) -> int:
    """The contribution of the single officer holding the post that maps to
    ``key`` (0 when the post is vacant — one person per post, no stacking;
    ROLE_STAT_BONUS-style flat bonuses are deleted, §4.5.3)."""
    post_id = ""
    for candidate, post_key in POST_SKILL.items():
        if post_key == key:
            post_id = candidate
            break
    if not post_id:
        return 0
    holder = post_holder(st, post_id)
    if not holder:
        return 0
    officer: dict[str, Any] = store.get_officer(holder)
    if not officer:
        return 0
    value = int(officer.get("skills", {}).get(key, SKILL_MIN))
    loyal = loyalty(st, holder)
    if loyal < LOYALTY_DERATE_BELOW:
        value = int(math.floor(value * CONTRIBUTION_DERATE))
    if loyal >= LOYALTY_SIGNATURE_AT and str(officer.get("main_skill", "")) == key:
        value += SIGNATURE_BONUS
    return value


# --- Usage growth (docs/50-* §4.3.1–§4.3.3) -----------------------------------

def counters(st: PersonState) -> dict[str, Any]:
    """The player's ``skill_counters`` block (the §4.8 save shape; missing
    keys read as 0). The live dict, like the GDScript reference return."""
    return st.player.get("skill_counters", {})


def note_usage(st: PersonState, key: str, uses: int = 1) -> None:
    """Adds ``uses`` to the usage counter of ``key`` (§4.3.3). Counters stop
    counting at skill 100: a maxed skill accrues nothing and its counter
    stays 0. The award itself is :func:`maybe_award` — the two halves of the
    rule stay separable for the storm-survival bypass (immediate award,
    counter untouched, §4.3.3)."""
    if key not in KEYS or uses <= 0:
        return
    p: dict[str, Any] = st.player
    counter: dict[str, Any] = p.get("skill_counters", {})
    if skill(st, key) >= SKILL_MAX:
        counter[key] = 0
    else:
        counter[key] = int(counter.get(key, 0)) + uses
    p["skill_counters"] = counter


def growth_threshold(key: str) -> int:
    """The §4.3.1 threshold of ``key`` (+1 per N uses; 0 for an unknown key)."""
    return GROWTH_THRESHOLD.get(key, 0)


def maybe_award(st: PersonState, key: str) -> None:
    """Awards the usage growth for ``key``: when the counter reached the
    threshold and the skill is below 100, skill +1 and the counter resets
    (§4.3.3)."""
    if key not in KEYS:
        return
    p: dict[str, Any] = st.player
    counter: dict[str, Any] = p.get("skill_counters", {})
    if skill(st, key) >= SKILL_MAX:
        counter[key] = 0
        p["skill_counters"] = counter
        return
    if int(counter.get(key, 0)) >= growth_threshold(key):
        skills: dict[str, Any] = p.get("skills", {})
        skills[key] = _clampi(skill(st, key) + 1, SKILL_MIN, SKILL_MAX)
        p["skills"] = skills
        counter[key] = 0
        p["skill_counters"] = counter


def note_sea_day(st: PersonState, store: DataStore) -> None:
    """One sea ledger day (§4.3.1: seamanship and navigation grow per
    sea-day; ``20-*`` §4.5 step 1 calls this once per day at sea). Completes
    the cycle — note, then award, then run the officer day tick (§4.3.2
    growth clock and §4.5.4 loyalty events)."""
    for key in ("seamanship", "navigation"):
        note_usage(st, key)
        maybe_award(st, key)
    officer_day_tick(st, store)


# --- Paid training (docs/50-* §4.3.4) -----------------------------------------

def training_price(st: PersonState, _key: str) -> int:
    """``ceil(level × 60 × (1 − (INT−10)/200))`` — the player's level and the
    player's INT, identical for the player's own skill and an officer's
    (the §5 worked example: level 1, INT 17 → ceil(57.9) = 58). Computed in
    exact integer arithmetic (``level × 3 × (210 − INT) / 10``, the closed
    form multiplied out) so float noise can never bump an integral fee up a
    gold."""
    character = _character()
    level = int(character.level_for_xp(int(st.player.get("xp", 0))))
    intellect = int(character.attribute(st, "intellect"))
    product = level * 3 * (210 - intellect)
    return (product + 9) // 10  # integer ceil(product / 10)


def can_train(st: PersonState, key: str) -> bool:
    """Training is refused at the §4.3.4 cap (skill ≥ 60) or when the purse
    is short (§6: the button shows the price instead)."""
    if skill(st, key) >= TRAIN_CAP:
        return False
    return st.gold >= training_price(st, key)


def train(st: PersonState, key: str) -> bool:
    """Pays the fee and raises ``key`` by one, capped at the training cap 60
    (usage growth can still pass 60). State untouched when refused."""
    if key not in KEYS or not can_train(st, key):
        return False
    st.gold -= training_price(st, key)
    p: dict[str, Any] = st.player
    skills: dict[str, Any] = p.get("skills", {})
    skills[key] = _clampi(skill(st, key) + 1, SKILL_MIN, TRAIN_CAP)
    p["skills"] = skills
    return True


# --- Officer post helpers (docs/50-* §4.5.2, data/officer_posts.json) ---------

def officers_in_post(st: PersonState, post_id: str) -> list[str]:
    """Employed officer ids whose ``officer_states.post_id == post_id``.
    At most one per flagship post (appoint enforces it); a captain post is
    one holder per ``ship_id``."""
    out: list[str] = []
    for officer_id in st.player.get("officers", []):
        state: dict[str, Any] = _states(st).get(str(officer_id), {})
        if str(state.get("post_id", "")) == post_id:
            out.append(str(officer_id))
    return out


def post_holder(st: PersonState, post_id: str) -> str:
    """The first holder of ``post_id``, or ``""`` when vacant."""
    holders = officers_in_post(st, post_id)
    return holders[0] if holders else ""


def appoint(st: PersonState, store: DataStore, officer_id: str,
            post_id: str, ship_id: str = "") -> bool:
    """Appoints an employed officer to ``post_id`` (``""`` = back to idle),
    checking the post's prereqs straight from ``data/officer_posts.json``
    (§4.5.2: flagship = the matching skill ≥ 20 — captain = seamanship ≥ 25 ∧
    courage ≥ 30, with ``courage`` read from the officer's attributes).
    One person per post (per ship for the captain seat). Prereqs apply only
    to taking a post — unassigning is always allowed."""
    officer: dict[str, Any] = store.get_officer(officer_id)
    if not officer or not _employed(st, officer_id):
        return False
    state = _ensure_state(st, officer_id)
    if not post_id:
        state["post_id"] = ""
        state["ship_id"] = ""
        return True
    post: dict[str, Any] = store.get_officer_post(post_id)
    if not post:
        return False
    skills_map: dict[str, Any] = officer.get("skills", {})
    attributes_map: dict[str, Any] = officer.get("attributes", {})
    for req_key, required in post.get("prereq", {}).items():
        value = int(skills_map.get(req_key, attributes_map.get(req_key, 0)))
        if value < int(required):
            return False
    # Occupancy: flagship seats are unique; the captain seat is unique per ship.
    wanted_ship = ship_id if str(post.get("slot_type", "")) == "captain" else ""
    for other_id in st.player.get("officers", []):
        if str(other_id) == officer_id:
            continue
        other: dict[str, Any] = _states(st).get(str(other_id), {})
        if str(other.get("post_id", "")) != post_id:
            continue
        if str(post.get("slot_type", "")) != "captain" \
                or str(other.get("ship_id", "")) == wanted_ship:
            return False
    state["post_id"] = post_id
    state["ship_id"] = wanted_ship
    return True


# --- Officer day tick (docs/50-* §4.3.2 growth, §4.5.4 loyalty) ---------------

def officer_day_tick(st: PersonState, store: DataStore) -> None:
    """One sea ledger day for the whole roster (called by
    :func:`note_sea_day`): +1 ``sea_days`` per employed officer; each
    multiple of 90 days pays +1 to the post's skill (idle/captain → the
    native main skill), clamped at 100, on the officer card. Loyalty < 15
    resigns (roster + state entry cleared — the post frees with it);
    loyalty < 30 raises ``st.pending_raise`` (the §4.5.4 raise-demand event;
    the GDScript ``Character.pending_raise`` static — session-transient,
    never saved)."""
    roster = list(st.player.get("officers", []))
    for officer_id in roster:
        oid = str(officer_id)
        state = _ensure_state(st, oid)
        state["sea_days"] = int(state.get("sea_days", 0)) + 1
        if int(state.get("loyalty", LOYALTY_START)) < LOYALTY_RESIGN_BELOW:
            _resign(st, oid)
            continue
        if int(state.get("loyalty", LOYALTY_START)) < LOYALTY_DERATE_BELOW:
            st.pending_raise = True
        if int(state["sea_days"]) % OFFICER_GROWTH_DAYS == 0:
            _grow_officer_skill(store, oid, str(state.get("post_id", "")))


def _grow_officer_skill(store: DataStore, officer_id: str,
                        post_id: str) -> None:
    """The §4.3.2 growth award: the post's skill while in post (the §2.7
    post → pipeline map; a captain seat grows the native main skill —
    captains feed their ship, not the player), else the native main skill on
    the bench. The officer card is canon-with-growth: the +1 lands on the
    loaded record (save persistence of the grown value is the
    ``officer_states`` scope, ``90-*`` §8)."""
    officer: dict[str, Any] = store.get_officer(officer_id)
    if not officer:
        return
    growth_key = str(POST_SKILL.get(post_id, officer.get("main_skill", "")))
    if not growth_key:
        return
    skills: dict[str, Any] = officer.get("skills", {})
    skills[growth_key] = _clampi(int(skills.get(growth_key, 0)) + 1,
                                 SKILL_MIN, SKILL_MAX)
    officer["skills"] = skills


def _resign(st: PersonState, officer_id: str) -> None:
    """The §4.5.4 resign path: roster + state entry cleared (a re-hire
    starts fresh at 50 — the state is gone, not archived)."""
    p: dict[str, Any] = st.player
    officers: list[Any] = p.get("officers", [])
    if officer_id in officers:
        officers.remove(officer_id)
    p["officers"] = officers
    _states(st).pop(officer_id, None)


# --- Loyalty (docs/50-* §4.5.4) ------------------------------------------------

def loyalty(st: PersonState, officer_id: str) -> int:
    """The officer's loyalty (the §4.8 state block; the start value when the
    entry has not been created yet — call sites are employed officers)."""
    state: dict[str, Any] = _states(st).get(officer_id, {})
    return int(state.get("loyalty", LOYALTY_START))


def adjust_loyalty(st: PersonState, officer_id: str, delta: int) -> int:
    """Applies a delta through the §4.5.4 rules: every **positive** delta is
    multiplied by ``1 + floor((CHA−10)/45)``, negative deltas are flat; the
    result clamps to 0–100. Returns the new value (or the old one when the
    officer is not employed)."""
    if not _employed(st, officer_id):
        return loyalty(st, officer_id)
    state = _ensure_state(st, officer_id)
    if delta > 0:
        delta *= cha_loyalty_multiplier(st)
    value = _clampi(int(state.get("loyalty", LOYALTY_START)) + delta,
                    LOYALTY_MIN, LOYALTY_MAX)
    state["loyalty"] = value
    return value


def cha_loyalty_multiplier(st: PersonState) -> int:
    """The charisma gain multiplier ``1 + floor((CHA−10)/45)`` (§4.5.4):
    CHA 10 → ×1, CHA 100 → ×3."""
    character = _character()
    charisma = int(character.attribute(st, "charisma"))
    return 1 + int(math.floor((charisma - 10) / CHA_LOYALTY_DIVISOR))


def talk(st: PersonState, officer_id: str) -> bool:
    """Talk: loyalty +1 (charisma-multiplied), 10-day cooldown via
    ``talk_cd_day``. False on cooldown or when not employed."""
    if not _employed(st, officer_id):
        return False
    state = _ensure_state(st, officer_id)
    if st.day < int(state.get("talk_cd_day", 0)):
        return False
    adjust_loyalty(st, officer_id, TALK_GAIN)
    state["talk_cd_day"] = st.day + COOLDOWN_DAYS
    return True


def gift(st: PersonState, store: DataStore, officer_id: str) -> bool:
    """Gift (200g): +5, greedy 贪婪 +8, honest 诚实 / loyal 忠诚 +3 (§4.5.4),
    10-day cooldown via ``gift_cd_day``. False when not employed, on
    cooldown or with a short purse — nothing is paid in those cases."""
    if not _employed(st, officer_id):
        return False
    state = _ensure_state(st, officer_id)
    if st.day < int(state.get("gift_cd_day", 0)):
        return False
    if st.gold < GIFT_COST:
        return False
    st.gold -= GIFT_COST
    personality: list[Any] = store.get_officer(officer_id).get(
        "personality", [])
    amount = GIFT_BASE
    if "greedy" in personality:
        amount = GIFT_GREEDY
    elif "honest" in personality or "loyal" in personality:
        amount = GIFT_HONEST
    adjust_loyalty(st, officer_id, amount)
    state["gift_cd_day"] = st.day + COOLDOWN_DAYS
    return True


def accept_raise(st: PersonState, officer_id: str) -> bool:
    """The raise event, accepted: ``wage_mult`` × 1.25 permanent,
    loyalty +10."""
    if not _employed(st, officer_id):
        return False
    state = _ensure_state(st, officer_id)
    state["wage_mult"] = float(state.get("wage_mult", 1.0)) * RAISE_WAGE_MULT
    adjust_loyalty(st, officer_id, RAISE_ACCEPT_LOYALTY)
    st.pending_raise = False
    return True


def refuse_raise(st: PersonState, officer_id: str) -> bool:
    """The raise event, refused: loyalty −10 (flat — negative deltas skip
    the charisma multiplier, §4.5.4)."""
    if not _employed(st, officer_id):
        return False
    adjust_loyalty(st, officer_id, RAISE_REFUSE_LOYALTY)
    st.pending_raise = False
    return True


# --- State helpers --------------------------------------------------------------

def _states(st: PersonState) -> dict[str, Any]:
    """The ``officer_states`` block (``90-*`` §8: a top-level run block;
    entries ``{loyalty, sea_days, post_id, ship_id, talk_cd_day,
    gift_cd_day, defeats, wage_mult}``)."""
    return st.officer_states


def _ensure_state(st: PersonState, officer_id: str) -> dict[str, Any]:
    """Creates the seeded state entry for an employed officer when missing
    (loyalty 50, idle, fresh cooldowns and clocks). Never creates one for an
    un-employed id — the callers guard on employment first."""
    states = _states(st)
    if officer_id not in states:
        states[officer_id] = {
            "loyalty": LOYALTY_START,
            "sea_days": 0,
            "post_id": "",
            "ship_id": "",
            "talk_cd_day": 0,
            "gift_cd_day": 0,
            "defeats": 0,
            "wage_mult": 1.0,
        }
    return states[officer_id]


def _employed(st: PersonState, officer_id: str) -> bool:
    """Employment check without a parse-time Character import (see the
    module docstring): the roster is ``player.officers``, the §4.8 id list."""
    return officer_id in st.player.get("officers", [])


def _clampi(value: int, low: int, high: int) -> int:
    """GDScript ``clampi``."""
    return max(low, min(value, high))
