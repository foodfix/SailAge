"""server.sim.quests.phase3_hooks — the quest-layer integration seams (M1).

Python port of ``scripts/quests/phase3_hooks.gd`` (the frozen parity
oracle until the M6 cutover). Normative contract:
docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.2–§4.7, §4.9.3–§4.9.7;
docs/90-ARCHITECTURE.md §0/§5.1 (the event seams).

The GDScript class is the *wiring* that binds the Phase-3 quest systems
to the Phase-1/2 signals — each world/battle/port scene gains one call
instead of re-implementing the order of the hooks (the Phase-2 lesson:
two copies of one rule diverge). This port keeps the same one-call
surface over the already-ported modules:

  * ``world_map._on_day_advanced`` → :func:`on_day_tick`
  * ``world_map._enter_port``      → :func:`on_port_entered`
  * ``battle_screen._finish_battle`` → :func:`on_battle_finished`
  * ``world_map`` Explore action   → :func:`explore_here`
  * ``world_map`` ``fleet_changed`` → :func:`on_cargo_changed`

State convention: the caller passes the
:class:`~server.sim.player.PersonState` (gold/day/the player block/fame/
titles) and the :class:`~server.sim.quests.QuestState`
(``active_quests``/``bounties``/``npc_fleets``/``battles_won``/the
tournament transient fields) plus the fleet hold; every function returns
its report dict/instances instead of emitting on the EventBus.

Deferred seams (NOT ported here, with the GDScript entry point — the
owning modules are other M1 waves; each arrives as an injected callable,
defaulting to the GDScript's no-module behaviour):
  * ``PalaceEngine.tick`` / ``PalaceEngine.on_patrol_kill`` (royal
    missions, `70-*` §4.9.4) — ``palace_tick`` / ``palace_patrol_kill``.
  * ``DiscoverySight.explore`` / ``something_near`` (§4.4) —
    ``explore`` / ``something_near``.
  * ``Tournament.settle`` + ``Tournament.ROUNDS`` (§4.9.7) —
    ``tournament_settle`` / ``tournament_rounds``.
  * ``QuestGen._spawn_bounty_target`` — battle hooks only *read* the
    ``quest_id`` tags, so no seam is needed here; spawning is
    :func:`server.sim.quests.quest_gen.accept`'s ``spawn_target``.

RNG-free: the oracle file has no ``rand*`` call (verified at port time).
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any, Callable, Final

from server.sim.quests import QuestState
from server.sim.quests import bounty as bounty_lib
from server.sim.quests import quest_gen as quest_gen_lib

if TYPE_CHECKING:
    from server.sim.player import PersonState

__all__ = [
    "TOURNAMENT_ID_PREFIX",
    "on_day_tick",
    "on_port_entered",
    "on_cargo_changed",
    "on_battle_finished",
    "explore_here",
    "something_near",
    "is_tournament",
    "on_tournament_bout",
    "take_tournament_outcome",
    "take_pending_bout",
]

# The palace/tournament/discovery seam callables (see the module
# docstring). ``PalaceTick`` mirrors ``PalaceEngine.tick(day) -> Array``;
# ``PalacePatrolKill`` mirrors ``PalaceEngine.on_patrol_kill(quest) ->
# Dictionary``; ``Discover`` mirrors ``DiscoverySight.explore(cell)``;
# ``SomethingNear`` mirrors ``DiscoverySight.something_near(cell)``;
# ``TournamentSettle`` mirrors ``Tournament.settle(won, round_reached)``.
PalaceTick = Callable[[Any, Any, int], list[Any]]
PalacePatrolKill = Callable[[dict[str, Any]], dict[str, Any]]
Discover = Callable[[tuple[int, int]], list[Any]]
SomethingNear = Callable[[tuple[int, int]], bool]
TournamentSettle = Callable[[bool, int], dict[str, Any]]

## §4.9.7: a tournament bout encounter id is ``tournament_<bracket>_<n>``.
TOURNAMENT_ID_PREFIX: Final[str] = "tournament_"

## §4.9.7 bracket length: the GDScript reads ``Tournament.ROUNDS`` — the
## constant lives with the tournament module (another M1 wave) and arrives
## injected; the pinned value is documented here for the default path.
TOURNAMENT_ROUNDS_PINNED: Final[int] = 3


# --- Day tick (docs/70-* §4.9.3, §4.9.4) ---------------------------------

def on_day_tick(st: PersonState, qs: QuestState, day: int, *, fleet: list[Any],
                palace_tick: PalaceTick | None = None) -> dict[str, Any]:
    """Runs every Phase-3 clock hook for one day: quest expiry/cargo
    failures, royal mission expiry, and the bounty re-evaluation (a
    reputation change elsewhere may have crossed the threshold). Returns
    ``{failed_quests, failed_missions, bounties_issued}`` so the caller
    can report."""
    failed_quests = quest_gen_lib.tick(qs, st, day, fleet)
    failed_missions: list[Any] = []
    if palace_tick is not None:
        failed_missions = palace_tick(st, qs, day)
    quest_gen_lib.prune(qs)
    issued = bounty_lib.evaluate_all(st, qs)
    return {
        "failed_quests": failed_quests,
        "failed_missions": failed_missions,
        "bounties_issued": issued,
    }


# --- Port entry (docs/70-* §4.2, §4.4) -----------------------------------

def on_port_entered(qs: QuestState, st: PersonState, port_id: str,
                    fleet: list[Any]) -> list[dict[str, Any]]:
    """Runs the port-entry hooks: complete every delivery due here.
    Returns the completed quest instances so the caller can show a report
    dialog."""
    if not port_id:
        return []
    done = quest_gen_lib.complete_delivery_quests(qs, st, port_id, fleet)
    quest_gen_lib.prune(qs)
    return done


def on_cargo_changed(qs: QuestState, st: PersonState,
                     fleet: list[Any]) -> list[dict[str, Any]]:
    """Runs the cargo-mutation hook (`70-*` §4.9.3: "the check runs on
    every cargo mutation … ``Fleet.add_goods``/``remove_goods``/
    ``jettison_*`` funnel through ``Quests.on_cargo_changed()``"). Called
    from the ``fleet_changed`` handler, which every cargo change already
    emits, so a delivery whose goods are sold, jettisoned or captured
    fails immediately with the §4.2 −5 rep. Returns the failed
    instances."""
    failed: list[dict[str, Any]] = []
    for quest in qs.active_quests:
        if not isinstance(quest, dict):
            continue
        if str(quest.get("status", "")) != quest_gen_lib.STATUS_ACTIVE:
            continue
        if not quest_gen_lib.delivery_cargo_lost(quest, fleet):
            continue
        if quest_gen_lib.fail(qs, st, quest):
            failed.append(quest)
    return failed


# --- Battle end (docs/70-* §4.5, §4.9.3, §4.9.4, §4.9.7) ----------------

def on_battle_finished(st: PersonState, qs: QuestState,
                       outcome: dict[str, Any], *,
                       palace_patrol_kill: PalacePatrolKill | None = None) \
        -> dict[str, Any]:
    """Runs the Phase-3 aftermath of a finished battle: the win counter, a
    bounty target's quest completion, a naval-patrol kill, and the
    hunter-surrendered bounty clearing. Safe to call once per battle
    (every step is idempotent by instance status / id).

    Returns ``{won, completed_quests, cleared_bounty, patrol_completed}``.
    """
    report: dict[str, Any] = {
        "won": False,
        "completed_quests": [],
        "cleared_bounty": "",
        "patrol_completed": [],
    }
    if not outcome:
        return report
    result = str(outcome.get("result", ""))
    kind = str(outcome.get("kind", ""))
    nation_id = str(outcome.get("nation_id", ""))
    encounter_id = str(outcome.get("encounter_id", ""))
    won = result == "victory"
    report["won"] = won

    if won:
        qs.battles_won += 1

    # a. A guild bounty target: the marker carries its `quest_id` (`4.9.3`).
    if won:
        marker = _marker(qs, encounter_id)
        quest_id = str(marker.get("quest_id", ""))
        if quest_id:
            quest = quest_gen_lib.find(qs, quest_id)
            if quest:
                if str(quest.get("giver", "")) == "palace":
                    if palace_patrol_kill is not None:
                        completed = palace_patrol_kill(quest)
                        if completed:
                            report["patrol_completed"].append(completed)
                else:
                    completed = quest_gen_lib.complete_bounty_quests(
                        qs, st, encounter_id)
                    report["completed_quests"].extend(completed)

    # b. Surrendering the flagship to a hunter clears that nation's bounty
    #    (`60-*` §4.11.7, `70-*` §4.9.5 path 2).
    if result == "surrender" and kind == "navy" and nation_id:
        if bounty_lib.clear_by_surrender(qs, st, nation_id):
            report["cleared_bounty"] = nation_id

    quest_gen_lib.prune(qs)
    return report


# --- Explore (docs/70-* §4.4) -------------------------------------------

def explore_here(cell: tuple[int, int],
                 explore: Discover | None = None) -> list[Any]:
    """The world-map Explore action: finds every in-range discovery.
    Returns the found ids (the caller shows ``discovery.found`` per id, or
    ``world.explore.none`` when empty). The DiscoverySight module (the
    §4.4 owner) is another M1 wave and arrives injected."""
    if explore is None:
        return []
    return explore(cell)


def something_near(cell: tuple[int, int],
                   something_near_fn: SomethingNear | None = None) -> bool:
    """``True`` while something is in range (the HUD hint / ``E``
    availability). Same discovery seam as :func:`explore_here`."""
    if something_near_fn is None:
        return False
    return something_near_fn(cell)


# --- Tournament bouts (docs/70-* §4.9.7) --------------------------------

def is_tournament(encounter_id: str) -> bool:
    """``True`` when ``encounter_id`` names a tournament bout."""
    return encounter_id.startswith(TOURNAMENT_ID_PREFIX)


def on_tournament_bout(st: PersonState, qs: QuestState,
                       outcome: dict[str, Any], *,
                       tournament_settle: TournamentSettle | None = None,
                       tournament_rounds: int = TOURNAMENT_ROUNDS_PINNED) \
        -> dict[str, Any]:
    """Settles a tournament bout result: a victory advances, anything else
    ends the bracket with the consolation. Returns the ``settle()`` block,
    or ``{}`` when the bout was not a tournament one. The tournament
    module (another M1 wave) owns the bracket arithmetic and arrives
    injected (``tournament_settle`` mirrors ``Tournament.settle``,
    ``tournament_rounds`` is its ``ROUNDS``)."""
    encounter_id = str(outcome.get("encounter_id", ""))
    if not is_tournament(encounter_id):
        return {}
    won = str(outcome.get("result", "")) == "victory"
    parts = encounter_id.split("_")
    # GDScript ``int(String)`` parses leading digits and is 0 for none;
    # bout ids are engine-generated ``tournament_<bracket>_<n>``.
    try:
        round_number = int(parts[2]) if len(parts) >= 3 else 1
    except ValueError:
        round_number = 0
    if won and round_number < tournament_rounds:
        # Advance: S10's Continue routes back to S13, whose `_ready` starts
        # the next bout from this transient field (`70-*` §4.9.7 "3
        # successive battles", no repairs between rounds).
        qs.pending_tournament_round = round_number + 1
        return {"won": True, "round_reached": round_number,
                "next_round": round_number + 1}
    qs.pending_tournament_round = 0
    settled: dict[str, Any] = {}
    if tournament_settle is not None:
        settled = tournament_settle(won and round_number >= tournament_rounds,
                                    round_number)
    qs.last_tournament_outcome = dict(settled)
    return settled


def take_tournament_outcome(qs: QuestState) -> dict[str, Any]:
    """Takes the bracket block S13 reports on open (``{}`` when there is
    none), so a settlement is announced exactly once."""
    outcome = qs.last_tournament_outcome
    qs.last_tournament_outcome = {}
    return outcome


def take_pending_bout(qs: QuestState) -> int:
    """Takes the bout S13 should start (``0`` when none) — S13 re-opens
    mid-bracket after each won bout (`70-*` §4.9.7)."""
    round_number = int(qs.pending_tournament_round)
    qs.pending_tournament_round = 0
    return round_number


# --- Small helpers -------------------------------------------------------

def _marker(qs: QuestState, encounter_id: str) -> dict[str, Any]:
    return quest_gen_lib.find_marker(qs, encounter_id)
