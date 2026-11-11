"""server.sim.world.advice — the officer advice-event roll (M1).

Python port of ``scripts/world/advice.gd`` (the frozen parity oracle until
the M6 cutover). Normative contract:

  * docs/IMPLEMENT-Phase8.md §2.5 — "Officer advice events": each sea-day
    tick, **3% per in-post flagship officer** fires a situational hint when
    its post threshold is met; the text is pure ``ui_strings.json``
    (``advice.<post_id>.<situation_id>``), the trigger table lives in
    ``data/officer_posts.json``'s ``advice`` field;
  * docs/50-CHARACTER-AND-PROGRESSION.md §4.5.2 — the six flagship posts
    (pilot / boatswain / gunner / surgeon / carpenter / cook), the
    post → pipeline table this module's situations narrate;
  * docs/10-DATA-SCHEMA.md §4.21 — the ``OfficerPost`` record, the six
    locked situations ("pilot = tomorrow's wind band; surgeon = water
    ≤ 5 days; boatswain = wrong sail plan in a storm; gunner = first
    contact round; carpenter = fleet durability < 50%; cook = morale
    < 40") and the rule that **the numeric trigger params (5 days, 50%,
    40) sit in this table, never in code**;
  * docs/20-WORLD-AND-SAILING.md §4.5/§4.7/§4.10 — the ledger's sea-day
    growth point (this roll shares it), the storm/reefed sail-trim pair
    and the ``RATION_SIZE = 5`` water arithmetic.

The pure decision ported here: which posts have a **holder**
(:func:`server.sim.player.skills.post_holder`), whether the post's
**situation condition** holds, and which holders win the per-sea-day
**roll**. The payload is data, never composed text: an entry names the
``ui_strings`` key plus the post and officer ids; the client renders it.

Roll (no RNG stream — the oracle is hash-seeded, not ``RandomNumberGenerator``
seeded): ``abs(hash("{day}|{officer_id}")) % 100 < FIRE_PCT``, with Godot
4.7's deterministic ``String.hash()`` (djb2) supplied by the single public
owner :func:`server.sim.port.economy.godot_string_hash`. There is **no RNG
state and no call order to preserve** — the same ``(day, officer_id)``
replays identically on every process, load and save, exactly like
``captains.speed_jitter``. ``abs`` is the oracle's spelling and an identity
here (a ``String`` hash is a uint32).

The two session-transient statics ``_pending`` / ``_fired_battles`` become
fields on :class:`AdviceState` (the M1 state convention: the caller owns the
state object, nothing is a module singleton — and neither field is ever
saved, mirroring the GDScript comment "transient, never saved").

Threshold source note (deliberate, doc-driven): the GDScript mirrors the
three numeric trigger params as literals in ``_condition_holds`` even though
``10-*`` §4.21 says "never in code". This port reads them from
``data/officer_posts.json`` (the normative owner); on the shipped table the
values are the oracle's 5 / 50 / 40, so behaviour is identical. The suite
pins those three numbers AND the resulting boundary behaviour.

Call site (declared seam, not here): ``server.sim.world.sailing``'s ledger
step 4 (sea days only) documents the advice roll as the pending port — the
module that owns the ledger calls :func:`day_tick` there; the world scene's
notice drain becomes :func:`drain` at the WS/handler layer. This module
reads the sailing state (position zone, weather, sail trim, morale, fleet)
but never runs a ledger step, imports no ledger internals and renders
nothing.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Final

from server.sim.data import DataStore
from server.sim.fleet import fleet as fleet_lib
from server.sim.player import PersonState, skills
from server.sim.port.economy import godot_string_hash
from server.sim.world import sailing as sailing_lib
from server.sim.world.sailing import SailingState

__all__ = [
    "FIRE_PCT",
    "SITUATIONS",
    "AdviceState",
    "roll_for",
    "fires",
    "condition_holds",
    "day_tick",
    "battle_start",
    "drain",
    "reset",
]

#: The locked per-officer-per-sea-day fire chance (docs/IMPLEMENT-Phase8.md
#: §2.5 "3% per in-post officer"; ``advice.gd`` ``FIRE_PCT``).
FIRE_PCT: Final[int] = 3

#: The post → situation ids, one per flagship post (the closed
#: ``ui_strings advice.*`` table, ``10-*`` §4.21). Dict order is contract:
#: :func:`day_tick` visits posts in this order, so the notice queue order is
#: deterministic (the GDScript iterates the same literal).
SITUATIONS: Final[dict[str, str]] = {
    "pilot": "wind_band",
    "boatswain": "storm_sail",
    "gunner": "first_contact",
    "surgeon": "water_low",
    "carpenter": "durability_low",
    "cook": "morale_low",
}


@dataclass
class AdviceState:
    """The run-scoped advice state (the GDScript module statics).

    Mirrors ``advice.gd``'s ``_pending`` + ``_fired_battles``: both are
    session-transient and deliberately absent from the save payload (a fresh
    run and every load start empty, exactly like ``npc_port_log``).
    """

    ## The queued entries the client drains into its notice flow, in
    ## ``day_tick`` visit order (``{key, post, officer_id}``).
    pending: list[dict[str, Any]] = field(default_factory=list)
    ## The days a gunner first-contact hint already fired on — one per day
    ## maximum (``advice.gd`` ``_fired_battles`` keyed by ``GameState.day``).
    fired_battles: set[int] = field(default_factory=set)


def roll_for(day: int, officer_id: str) -> int:
    """The per-officer-per-day roll bucket, ``0 ≤ roll < 100``.

    The oracle line: ``abs(hash("%d|%s" % [day, holder])) % 100``. Godot's
    ``String.hash()`` is the deterministic djb2 in
    :func:`~server.sim.port.economy.godot_string_hash` (uint32), so ``abs``
    is an identity and the value replays bit-exactly off-process.
    """
    return abs(godot_string_hash(f"{day}|{officer_id}")) % 100


def fires(day: int, officer_id: str) -> bool:
    """True when the holder's roll beats the §2.5 3% gate (``roll < 3``)."""
    return roll_for(day, officer_id) < FIRE_PCT


def day_tick(state: AdviceState, st: PersonState, store: DataStore,
             sailing: SailingState) -> int:
    """One **sea-day** tick: roll every in-post flagship officer; a fire
    whose situation condition holds queues ``advice.{post}.{situation}``.

    Returns the queue length after the tick (the oracle's test seam). The
    loop order is :data:`SITUATIONS`' declaration order; a post with no
    holder, a failed roll or a false condition contributes nothing. Never
    called on a port day (docs/20-* §4.5 — the caller gates it at sea).
    """
    for post_id, situation in SITUATIONS.items():
        holder = skills.post_holder(st, post_id)
        if not holder:
            continue
        if not fires(st.day, holder):
            continue
        if not condition_holds(post_id, store, sailing):
            continue
        state.pending.append({
            "key": f"advice.{post_id}.{situation}",
            "post": post_id,
            "officer_id": holder,
        })
    return len(state.pending)


def condition_holds(post_id: str, store: DataStore,
                    sailing: SailingState) -> bool:
    """Whether ``post_id``'s situation condition holds right now.

    The conditions are the oracle's ``_condition_holds`` verbatim; only the
    three numeric thresholds come from ``officer_posts.json``'s ``advice``
    table (``10-*`` §4.21 "never in code"): ``surgeon.water_low.days``,
    ``carpenter.durability_low.pct``, ``cook.morale_low.threshold``.
    """
    if post_id == "pilot":
        # The wind band changes "tomorrow": the zone one heading-step band
        # ahead (one degree = §4.1's 12 tiles) differs from the current
        # zone (§4.7).
        tile = sailing_lib.world_tile(sailing)
        here = sailing_lib.weather_zone_for(tile)
        ahead = (tile[0], tile[1] - sailing_lib.TILES_PER_DEGREE)
        return sailing_lib.weather_zone_for(ahead) != here
    if post_id == "boatswain":
        # The sail plan is wrong for a storm day (§4.17: ``reefed`` is the
        # storm trim — anything else in a storm reads as wrong).
        return str(sailing.world.get("weather", "")) == "storm" \
            and str(sailing.world.get("sail_trim", "normal")) != "reefed"
    if post_id == "surgeon":
        # Fresh water ≤ ``days`` days remaining (§4.5: one unit waters
        # ``RATION_SIZE`` crew for one day); the oracle's
        # ``water_units * 5 <= crew * 5`` generalizes to the data's
        # ``days`` without changing the shipped 5.
        days = _trigger_param(store, post_id, "water_low", "days")
        crew = max(1, fleet_lib.total_crew(sailing.fleet))
        water_units = 0
        for ship in sailing.fleet:
            if isinstance(ship, dict):
                water_units += int(ship.get("water", 0))
        return water_units * sailing_lib.RATION_SIZE <= crew * days
    if post_id == "carpenter":
        # Any hull strictly below ``pct`` percent of its type's durability
        # (the oracle's ``durability * 2 < max_dur`` at pct 50).
        pct = _trigger_param(store, post_id, "durability_low", "pct")
        for ship in sailing.fleet:
            if not isinstance(ship, dict):
                continue
            ship_type = store.get_ship_type(str(ship.get("ship_type_id", "")))
            max_dur = int(ship_type.get("durability", 0))
            if max_dur > 0 and int(ship.get("durability", 0)) * 100 \
                    < max_dur * pct:
                return True
        return False
    if post_id == "cook":
        return sailing.morale < _trigger_param(
            store, post_id, "morale_low", "threshold")
    # The gunner's hint is not a day-tick situation (first contact round,
    # §2.5) — :func:`battle_start` owns it. The captain post has no advice
    # row; every unknown id is a no-op (the oracle's ``_`` fallthrough).
    return False


def _trigger_param(store: DataStore, post_id: str, situation: str,
                   key: str) -> int:
    """One numeric trigger param from the post's ``advice`` table.

    ``10-*`` §4.21 owns these numbers; a missing row/key is invalid data
    (the validator gates ``data/`` and the server refuses invalid data at
    load — 90-* §5.2), so this raises instead of inventing a default.
    """
    post = store.get_officer_post(post_id)
    advice = post.get("advice", {})
    params = advice.get(situation, {}) if isinstance(advice, dict) else {}
    if not isinstance(params, dict) or key not in params:
        raise KeyError(
            f"data/officer_posts.json: {post_id}.advice.{situation}.{key} "
            "is required (docs/10-DATA-SCHEMA.md §4.21)")
    return int(params[key])


def battle_start(state: AdviceState, st: PersonState) -> dict[str, Any]:
    """The gunner's first-contact hint (§2.5's trigger row): fired at the
    first contact round instead of a day tick, at most **once per day**.

    Returns the advice entry, or ``{}`` when the gunner post is vacant or
    this day's battle already fired it. The caller queues the entry on its
    encounter funnel.
    """
    holder = skills.post_holder(st, "gunner")
    if not holder:
        return {}
    if st.day in state.fired_battles:
        return {}
    state.fired_battles.add(st.day)
    return {
        "key": "advice.gunner.first_contact",
        "post": "gunner",
        "officer_id": holder,
    }


def drain(state: AdviceState) -> list[dict[str, Any]]:
    """Drains the queue (the client renders each entry as a notice line)."""
    out = state.pending
    state.pending = []
    return out


def reset(state: AdviceState) -> None:
    """Test/run-reset seam: clears the transient queue and battle gate."""
    state.pending = []
    state.fired_battles = set()
