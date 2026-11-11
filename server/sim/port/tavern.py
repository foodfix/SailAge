"""server.sim.port.tavern — the tavern facility engine (M1).

Python port of ``scripts/port/tavern_engine.gd`` (the frozen parity oracle
until the M6 cutover) plus the **hint half** of
``scripts/world/discovery.gd`` (``hints`` / ``is_hinted`` / ``buy_hint`` /
``hint_text`` — the tavern Rumors tab's machinery, ``70-*`` §4.4, which the
web migration assigns to this module's ownership).

Normative sources:
  * docs/30-PORTS-AND-TRADE.md §4.5/§4.6 — crew hire/fire: signing bonus
    ``crew_wage_daily × 10`` per head (2 × 10 = 20g), the flagship
    ``crew_max`` cap, the ``crew_min`` floor, "no severance; morale
    unchanged", the −1/−10 clamping variant, one port hour per completed
    hire/fire (§4.1b).
  * docs/50-CHARACTER-AND-PROGRESSION.md §4.4/§4.5 — the officer pool
    visibility rule (recruit_ports placement; an employed officer vanishes
    from every tavern) and the §4.3 swordplay usage growth the sparring
    bouts feed.
  * docs/80-UI-UX.md §4.11.1 (Phase-8 W5-C) — the sparring wager numbers
    (stake 100–1,000g in 100g steps, the 40-swordplay champion, win chance
    ``clamp(0.5 + (swordplay − 40)/200, 0.10, 0.90)``, a win pays pot × 2,
    each bout counts as 3 swordplay usages).
  * docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.4 — the Rumors tab: up to three
    hints per visit drawn from
    ``seed = day × 1000003 + port_ordinal × 7919`` uniformly without
    replacement (fame-ascending + id as the stable base order), 100g per
    hint, a bought hint never re-sells, hints never expire.

Purity contract (M1, mirrors ``server/sim/port/trade.py``): **pure
functions over injected state** — no GameState autoload, no module state.
The GDScript statics read/mutated the ``GameState`` singleton and the
fleet; here the purse is the caller's
:class:`~server.sim.player.PersonState` (``st``) and the fleet is an
injected list of ship dicts (the flagship is ``fleet[0]``, docs/40 §4.4).
Content lookups (ship types, officers, ports, discoveries) read
:mod:`server.sim.data` exactly where the GDScript reads ``DataLoader``.

RNG seams (the parity-critical part):
  * ``hints`` — discovery.gd:129 seeds Godot's ``RandomNumberGenerator``
    with ``day × 1000003 + port_ordinal × 7919`` and consumes
    ``randi_range(0, pool_size − 1)`` once per drawn hint; the port runs
    the identical draws through :class:`~server.sim.rng.GodotRng`
    (bit-exact PCG32), so the pinned (port, day) draw reproduces the
    oracle's hint ids exactly.
  * ``spar`` — the engine itself draws nothing: the screen passes the
    bout's ``roll`` ∈ [0, 1) from its seeded stream (80-* W5 gate). The
    port keeps that shape: the caller injects the roll, the engine stays
    pure given it.
  * No other function in the oracle file touches a ``rand*`` call (verified
    at port time by grep).

Entry points ported (GDScript name → this module):
  * ``per_head`` / ``hire_cost`` / ``crew`` / ``crew_max`` / ``crew_min`` /
    ``max_hire`` / ``fill_heads`` / ``can_hire`` / ``hire`` / ``min_fire`` /
    ``can_fire`` / ``fire`` / ``fire_clamped`` / ``_apply_fire`` /
    ``officers_at_port`` — same names (state injected).
  * ``spar_step`` / ``spar_valid_stake`` / ``spar_win_chance`` / ``spar_pot``
    / ``can_spar`` / ``spar`` — same names (purse and roll injected).
  * ``DiscoverySight.hints`` / ``is_hinted`` / ``buy_hint`` / ``hint_text``
    / ``_port_ordinal`` → ``hints`` / ``is_hinted`` / ``buy_hint`` /
    ``hint_text`` / ``port_ordinal``.

Deferred (NOT ported here, with the GDScript entry point):
  * ``befriend`` / ``can_befriend`` / ``reset_visit_guards`` and the inn's
    counterpart limited talk — the stance/familiarity mutation is the
    ``scripts/world/captains.gd`` module (not yet ported); only the guard
    bookkeeping would live here. The captains port owns it.
  * Captain sightings, the port-traffic rumor rows and the investment
    telegraph rows — ``scripts/world/npc_intel.gd``
    (``sightings`` / ``rumor_rows`` / ``investment_rows``); world-domain
    data assembly over ``NpcFleets``/``Economy``/``Allegiance`` indexes,
    owned by the npc-intel port, not the tavern engine.
  * The §4.1b port-hours charge and the ``SailingSim.facility_open``
    wall-clock query — sailing-sim state. The gate arrives here as the
    injected ``open_now`` flag (the caller queries the sailing module);
    a completed hire/fire charges the caller one port hour.
  * ``FleetLib.notify_changed`` announcements — the caller's WS event
    frame (90-* §0.3).
  * Officer signing/dismissal transactions — ``character.recruit`` /
    ``character.dismiss`` (already ported in server.sim.player.character);
    this module only decides pool *visibility*.
"""

from __future__ import annotations

from typing import Any, Final

from server.sim.data import DataStore
from server.sim.player import character, skills
from server.sim.player import PersonState
from server.sim.rng import GodotRng

__all__ = [
    "CREW_WAGE_DAILY",
    "SIGNING_BONUS_DAYS",
    "SPAR_STAKE_MIN",
    "SPAR_STAKE_MAX",
    "SPAR_STAKE_STEP",
    "SPAR_CHAMPION_SWORDPLAY",
    "SPAR_CHANCE_BASE",
    "SPAR_CHANCE_DIVISOR",
    "SPAR_CHANCE_MIN",
    "SPAR_CHANCE_MAX",
    "SPAR_USES_PER_BOUT",
    "HINT_PRICE",
    "HINTS_PER_VISIT",
    "SEED_DAY_MULT",
    "SEED_PORT_MULT",
    "per_head",
    "hire_cost",
    "crew",
    "crew_max",
    "crew_min",
    "max_hire",
    "fill_heads",
    "can_hire",
    "hire",
    "min_fire",
    "can_fire",
    "fire",
    "fire_clamped",
    "officers_at_port",
    "spar_step",
    "spar_valid_stake",
    "spar_win_chance",
    "spar_pot",
    "can_spar",
    "spar",
    "hints",
    "is_hinted",
    "buy_hint",
    "hint_text",
    "port_ordinal",
]


# --- Crew hire/fire constants (docs/30-* §4.5/§4.6) -------------------------

#: The sailing ledger's daily crew wage (``sailing_sim.gd:52`` — the `20-*`
#: §4.5 locked `2`). Derived into the signing bonus so the number `2` stays
#: single-sourced with the ledger; when the sailing-sim port lands it is the
#: owning module and this constant re-exports its value.
CREW_WAGE_DAILY: Final[int] = 2

#: The signing bonus is ``crew_wage_daily × 10`` days of wages (docs/30 §4.5:
#: 2 × 10 = 20g/head, locked).
SIGNING_BONUS_DAYS: Final[int] = 10

# --- Phase-8 W5-C sparring wager (docs/80-* §4.11.1) ------------------------

#: 切磋 sparring bet — the locked numbers: stake 100–1,000g in 100g steps
#: (the stake IS the pot), the tavern champion's swordplay is 40, a win pays
#: ``pot × 2``, and each bout counts as 3 swordplay usages (growth counter,
#: docs/50-* §4.3).
SPAR_STAKE_MIN: Final[int] = 100
SPAR_STAKE_MAX: Final[int] = 1000
SPAR_STAKE_STEP: Final[int] = 100
SPAR_CHAMPION_SWORDPLAY: Final[int] = 40
SPAR_CHANCE_BASE: Final[float] = 0.5
SPAR_CHANCE_DIVISOR: Final[float] = 200.0
SPAR_CHANCE_MIN: Final[float] = 0.10
SPAR_CHANCE_MAX: Final[float] = 0.90
SPAR_USES_PER_BOUT: Final[int] = 3

# --- Rumors-tab hints (docs/70-* §4.4; discovery.gd constants) --------------

#: A tavern hint costs this much.
HINT_PRICE: Final[int] = 100
#: Up to three hints per tavern visit.
HINTS_PER_VISIT: Final[int] = 3
#: The §4.4 seed family (same as the guild offers, §4.9.3).
SEED_DAY_MULT: Final[int] = 1000003
SEED_PORT_MULT: Final[int] = 7919


# --- Crew hire/fire (docs/30-* §4.5/§4.6; tavern_engine.gd) -----------------

def per_head() -> int:
    """Locked signing bonus per head: ``crew_wage_daily × 10`` = 20g."""
    return CREW_WAGE_DAILY * SIGNING_BONUS_DAYS


def hire_cost(heads: int) -> int:
    """Signing bonus for ``heads`` crew; never negative (a bad call costs
    nothing)."""
    return max(heads, 0) * per_head()


def _flagship(fleet: list[Any]) -> dict[str, Any]:
    """The flagship is always ``fleet[0]`` (docs/40 §4.4); ``{}`` when the
    fleet is empty or its first entry is not a ship dict."""
    if not fleet or not isinstance(fleet[0], dict):
        return {}
    return fleet[0]


def crew(fleet: list[Any]) -> int:
    """Crew aboard the flagship (Phase-1 simplification, docs/40 §4.4: all
    crew lives on the flagship)."""
    return int(_flagship(fleet).get("crew", 0))


def _ship_stat(store: DataStore, fleet: list[Any], key: str) -> int:
    """A ShipType stat of the flagship's type (0 with no flagship)."""
    ship = _flagship(fleet)
    if not ship:
        return 0
    ship_type = store.get_ship_type(str(ship.get("ship_type_id", "")))
    return int(ship_type.get(key, 0))


def crew_max(store: DataStore, fleet: list[Any]) -> int:
    """The flagship's ``crew_max`` (from its ShipType, never a constant)."""
    return _ship_stat(store, fleet, "crew_max")


def crew_min(store: DataStore, fleet: list[Any]) -> int:
    """The flagship's ``crew_min``."""
    return _ship_stat(store, fleet, "crew_min")


def max_hire(store: DataStore, fleet: list[Any]) -> int:
    """How many more hands fit before ``crew_max`` (0 with no flagship — its
    crew_max reads 0)."""
    return max(crew_max(store, fleet) - crew(fleet), 0)


def fill_heads(store: DataStore, fleet: list[Any], gold: int) -> int:
    """The "Fill" button amount: as many as fit *and* as the purse can pay
    for. At the cap (or below one head's fee) this is 0."""
    cost = per_head()
    if cost <= 0:
        return 0
    return min(max_hire(store, fleet), max(gold, 0) // cost)


def can_hire(store: DataStore, fleet: list[Any], st: PersonState,
             heads: int) -> bool:
    """docs/30 §4.5 + §6: positive heads, within ``crew_max``, affordable."""
    if heads <= 0:
        return False
    if heads > max_hire(store, fleet):
        return False
    return st.gold >= hire_cost(heads)


def hire(store: DataStore, fleet: list[Any], st: PersonState, heads: int,
         open_now: bool = True) -> bool:
    """Pays the signing bonus and adds the crew to the flagship.

    Returns False (state untouched) whenever :func:`can_hire` is False or
    the tavern is closed at the current time (``30-*`` §4.1b closed rule —
    an action may only *start* inside the window; the gate is the caller's
    ``SailingSim.facility_open`` query, injected as ``open_now``). A
    completed hire charges the caller one port hour (§4.1b).
    """
    if not can_hire(store, fleet, st, heads):
        return False
    if not open_now:
        return False
    ship = _flagship(fleet)
    st.gold -= hire_cost(heads)
    ship["crew"] = int(ship.get("crew", 0)) + heads
    return True


def min_fire(store: DataStore, fleet: list[Any]) -> int:
    """How many hands can be let go before ``crew_min`` (0 at the floor)."""
    return max(crew(fleet) - crew_min(store, fleet), 0)


def can_fire(store: DataStore, fleet: list[Any], heads: int) -> bool:
    """docs/30 §4.5: cannot go below ``crew_min``; no severance, morale
    untouched. Strict: the request must fire exactly what it asks for."""
    if heads <= 0:
        return False
    if heads > crew(fleet):
        return False
    return crew(fleet) - heads >= crew_min(store, fleet)


def fire(store: DataStore, fleet: list[Any], heads: int,
         open_now: bool = True) -> bool:
    """Lets ``heads`` crew go. Gold and morale are deliberately untouched:
    the doc locks "fired crew leaves with no severance; morale unchanged".

    Strict transaction: refuses (False, nothing fired) when the request
    would cross the floor or the tavern is closed (§4.1b). A completed fire
    charges the caller one port hour.
    """
    if not can_fire(store, fleet, heads):
        return False
    if not open_now:
        return False
    ship = _flagship(fleet)
    ship["crew"] = int(ship.get("crew", 0)) - heads
    return True


def fire_clamped(store: DataStore, fleet: list[Any], heads: int,
                 open_now: bool = True) -> int:
    """Clamping variant used by the −1 / −10 buttons (docs/30 §6 "−1/−10
    clamp likewise", §4.5 "cannot go below crew_min"): fires as many as the
    floor allows and returns the number actually let go (0 at the floor or
    behind a closed door). Same one-hour cost as :func:`fire` on a nonzero
    result."""
    actual = min(max(heads, 0), min_fire(store, fleet))
    if actual <= 0:
        return 0
    if not open_now:
        return 0
    ship = _flagship(fleet)
    ship["crew"] = int(ship.get("crew", 0)) - actual
    return actual


def officers_at_port(store: DataStore, st: PersonState,
                     port_id: str) -> list[str]:
    """Officer ids seeking a berth at ``port_id``, in ``officers.json``
    order (docs/50 §4.4): the port must be in the officer's
    ``recruit_ports`` and the officer must not be employed. An employed
    officer therefore vanishes from *every* tavern and reappears in the
    pool on dismissal. (Employment reads the shared
    :func:`server.sim.player.character.is_employed` — never duplicated.)"""
    result: list[str] = []
    if not port_id or not store.get_port(port_id):
        return result
    for officer in store.officers_list:
        officer_id = str(officer.get("id", ""))
        if not officer_id:
            continue
        ports = officer.get("recruit_ports", [])
        if port_id not in ports:
            continue
        if character.is_employed(st, officer_id):
            continue
        result.append(officer_id)
    return result


# --- Sparring wager (docs/80-* §4.11.1; Phase-8 W5-C) -----------------------

def spar_step(stake: int, direction: int) -> int:
    """The stake the stepper offers after ``stake`` (clamped to the
    100–1,000 band, always on a 100g step)."""
    return max(SPAR_STAKE_MIN,
               min(stake + direction * SPAR_STAKE_STEP, SPAR_STAKE_MAX))


def spar_valid_stake(stake: int) -> bool:
    """100–1,000g in 100g steps (§4.11.1)."""
    if stake < SPAR_STAKE_MIN or stake > SPAR_STAKE_MAX:
        return False
    return stake % SPAR_STAKE_STEP == 0


def spar_win_chance(effective_swordplay: int) -> float:
    """``p = clamp(0.5 + (effective_swordplay − 40) / 200, 0.10, 0.90)`` —
    the locked win chance against the 40-swordplay tavern champion."""
    value = (SPAR_CHANCE_BASE
             + (float(effective_swordplay) - float(SPAR_CHAMPION_SWORDPLAY))
             / SPAR_CHANCE_DIVISOR)
    return max(SPAR_CHANCE_MIN, min(value, SPAR_CHANCE_MAX))


def spar_pot(stake: int) -> int:
    """A win pays ``pot × 2`` (the stake is the pot; §4.11.1)."""
    return stake * 2


def can_spar(st: PersonState, stake: int, open_now: bool = True) -> bool:
    """True when a bout may start: a valid stake, the purse covers it, and
    the tavern is open at the current time (§4.1b closed rule — the same
    guard every other timed tavern action runs; injected)."""
    if not spar_valid_stake(stake):
        return False
    if st.gold < stake:
        return False
    return open_now


def spar(st: PersonState, store: DataStore, stake: int, roll: float,
         open_now: bool = True) -> dict[str, Any]:
    """One bout (§4.11.1). ``roll`` ∈ [0, 1) — the screen draws it from its
    seeded stream (80-* W5 gate: interactions seeded-replayable); the engine
    stays pure given the roll. Wins pay :func:`spar_pot`, losses forfeit the
    stake; **every** bout notes 3 swordplay usages and runs the growth award
    (``skills.note_usage`` / ``skills.maybe_award`` — the shared §4.3 rule,
    reused not duplicated).

    Returns ``{won, stake, chance, uses}``; ``{}`` (state untouched) when
    :func:`can_spar` refuses. The duel/battle *resolution* beyond this roll
    is combat-domain and stays there."""
    if not can_spar(st, stake, open_now):
        return {}
    st.gold -= stake
    chance = spar_win_chance(skills.effective_skill(st, store, "swordplay"))
    won = roll < chance
    if won:
        st.gold += spar_pot(stake)
    skills.note_usage(st, "swordplay", SPAR_USES_PER_BOUT)
    skills.maybe_award(st, "swordplay")
    return {
        "won": won,
        "stake": stake,
        "chance": chance,
        "uses": SPAR_USES_PER_BOUT,
    }


# --- Rumors tab: discovery hints (docs/70-* §4.4; discovery.gd) -------------

def port_ordinal(store: DataStore, port_id: str) -> int:
    """The 0-based index of ``port_id`` in the port ids **sorted ascending**
    (§4.4: map-independent, so the same port always seeds the same list)."""
    ids = sorted(store.ports.keys())
    try:
        return ids.index(port_id)
    except ValueError:
        return -1


def hints(store: DataStore, found: list[str] | set[str], port_id: str,
          day: int) -> list[str]:
    """The up-to-three hints a tavern at ``port_id`` offers on ``day``, as
    discovery ids: unfound discoveries drawn from
    ``seed = day × 1000003 + port_ordinal × 7919``, uniformly without
    replacement, ``fame``-ascending as the stable tie-break (cheapest
    first).

    **The RNG seam** (discovery.gd:129-150, verbatim): one Godot
    ``RandomNumberGenerator`` seeded as above, one ``randi_range(0,
    pool_size − 1)`` draw per picked hint — reproduced here through
    :class:`~server.sim.rng.GodotRng` (bit-exact PCG32), so the draw
    sequence and therefore the pinned hint ids match the oracle exactly."""
    rng = GodotRng(seed=day * SEED_DAY_MULT + port_ordinal(store, port_id)
                   * SEED_PORT_MULT)
    found_set = set(found)
    pool: list[dict[str, Any]] = []
    for entry in store.discoveries_list:
        discovery_id = str(entry.get("id", ""))
        if discovery_id in found_set:
            continue
        pool.append({
            "id": discovery_id,
            "fame": int(entry.get("fame", 0)),
        })
    # Deterministic base order: fame ascending, then id — so the draw below
    # is reproducible regardless of the data file's order.
    pool.sort(key=lambda row: (int(row["fame"]), str(row["id"])))
    out: list[str] = []
    while len(out) < HINTS_PER_VISIT and pool:
        index = rng.randi_range(0, len(pool) - 1)
        out.append(str(pool[index]["id"]))
        pool.pop(index)
    return out


def is_hinted(hints_map: dict[str, Any], discovery_id: str) -> bool:
    """True when ``discovery_id``'s hint was already bought (the saved
    ``GameState.discovery_hints`` map, injected)."""
    return discovery_id in hints_map


def buy_hint(store: DataStore, st: PersonState, hints_map: dict[str, Any],
             discovery_id: str) -> dict[str, Any]:
    """Buys ``discovery_id``'s hint for 100g. Returns the discovery entry
    (the screen shows ``region_hint`` and reveals ``name``) or ``{}`` when
    refused (already hinted, no gold, unknown id — state untouched)."""
    if is_hinted(hints_map, discovery_id) or st.gold < HINT_PRICE:
        return {}
    entry = store.get_discovery(discovery_id)
    if not entry:
        return {}
    st.gold -= HINT_PRICE
    hints_map[discovery_id] = True
    return entry


def hint_text(store: DataStore, discovery_id: str) -> dict[str, Any]:
    """The L10nString shown for a hint row: the real text (Phase 3 shows the
    rumour and sells the *location*, ``80-*`` §4.7.3) — ``{}`` when the
    entry has none."""
    return store.get_discovery(discovery_id).get("region_hint", {}) or {}
