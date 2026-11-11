"""server.sim.combat.battle_rewards — battle-end economy effects (M1).

Python port of ``scripts/combat/battle_rewards.gd`` (the frozen parity
oracle until the M6 cutover) — docs/60-COMBAT.md §4.11.10, §4.12.2,
§4.12.3. Step **3** of the §4.12.4 battle-end sequence: the one place that
turns a finished battle's pre-computed outcome block into player state.

The §4.11.10 numbers live here as the canonical formulas:

  * **Salvage gold** — ``Σ floor(ShipType.base_price × 0.05)`` over the
    ships the player *sank* (:func:`salvage_for`). Captured/surrendered
    hulls pay nothing. Phase 8: the credited gold gains the haul-valuation
    multiplier.
  * **Battle XP** — ``+10`` per enemy ship neutralised + ``+5`` per round
    (:func:`xp_for`). A retreat awards nothing (§4.10) — the engine
    pre-computes ``xp = 0``.
  * **Reputation** — pirates defeated (any outcome except retreat) credit
    ``+2`` with each of the two nearest ports' nations
    (:func:`nearest_nations`). The navy ``−20`` is NOT here and never
    appears in ``rep_deltas`` — §4.11.10 charges it once at battle start.
  * **Side morale** — the §4.8a ``morale_delta`` the engine reports; the
    aftermath application below is its one consumer (§4.12.4).

State convention (M1, the package port rule): the GDScript statics read and
mutate ``GameState`` gold / ``GameState.morale`` / the Person block. Here
:func:`apply` takes the injected :class:`~server.sim.player.PersonState`
and the purse/morale values, mutates exactly what it is given (XP and
reputation through :mod:`server.sim.player.character`, mirroring the
GDScript ``Character.award_xp`` / ``add_reputation`` calls), and RETURNS
the applied deltas — the purse increment and the morale move are the
caller's (the same seam trade.py documents). ``haul_multiplier`` /
``haul_gold`` / ``battle_xp_for`` take the effective skill values and the
level as arguments (the caller's ``skills.effective_skill`` /
``character.current_level`` reads).

Idempotency: :func:`apply` marks the handed outcome dict with
``rewards_applied: True`` and returns zeroes on every later call for the
same block — a retried end-of-battle sequence must not double-pay.

Captain lifecycle (§4.11.15): :func:`apply_captain_lifecycle` calls the
world-side captains module through the guarded-import convention
(``server.sim.world.captains`` — another agent's file; a missing module
disables the hooks, never the battle).
"""

from __future__ import annotations

import math
from typing import Any, Final

from server.sim.combat.battle_sim import (
    NAVY_REP_PENALTY,
    NEAREST_PORT_COUNT,
    PIRATE_REP_GAIN,
    RESULT_RETREAT,
    RESULT_VICTORY,
    SALVAGE_FRACTION,
    XP_PER_ENEMY_NEUTRALIZED,
    XP_PER_ROUND,
    world_chebyshev,
)
from server.sim.data import data
from server.sim.player import PersonState
from server.sim.player.character import add_reputation, award_xp, current_level, reputation

__all__ = [
    "SALVAGE_FRACTION",
    "XP_PER_ENEMY_NEUTRALIZED",
    "XP_PER_ROUND",
    "PIRATE_REP_GAIN",
    "NAVY_REP_PENALTY",
    "NEAREST_PORT_COUNT",
    "RESULT_RETREAT",
    "HAUL_SKILL_DIVISOR",
    "HAUL_MULT_MIN",
    "HAUL_MULT_MAX",
    "XP_LEVEL_DIVISOR",
    "PIRACY_FAME_PENALTY",
    "CAPTAIN_ID_KEY",
    "FLAGSHIP_DUEL_LOST_KEY",
    "GOLD_KEY",
    "XP_KEY",
    "REP_DELTAS_KEY",
    "MORALE_KEY",
    "CAPTAIN_LIFECYCLE_KEY",
    "DROP_ITEM_KEY",
    "DROP_SOLD_BACK_KEY",
    "apply",
    "haul_multiplier",
    "haul_gold",
    "battle_xp_for",
    "apply_captain_lifecycle",
    "outcome_captain_id",
    "crushed_victory",
    "apply_piracy_attack",
    "apply_named_drop",
    "drop_sell_back_gold",
    "salvage_for",
    "xp_for",
    "neutralised_for",
    "nearest_nations",
]

# --- Phase 8 numbers (each doc-pinned, §4.8/§4.11.10/§4.11.15) ----------------

#: Haul valuation: ``1 + (appraisal + negotiation) / 400``, clamped
#: [1.0, 1.5] (§4.11.10).
HAUL_SKILL_DIVISOR: Final[float] = 400.0
HAUL_MULT_MIN: Final[float] = 1.0
HAUL_MULT_MAX: Final[float] = 1.5
#: Battle XP ×(1 + level / 20), floored once (§4.11.10).
XP_LEVEL_DIVISOR: Final[float] = 20.0
#: §4.11.10 piracy fame extension: −20 fame, once, at battle start.
PIRACY_FAME_PENALTY: Final[int] = -20

#: The outcome keys the lifecycle hooks consume.
CAPTAIN_ID_KEY: Final[str] = "captain_id"
FLAGSHIP_DUEL_LOST_KEY: Final[str] = "flagship_duel_lost"

#: The two lists §4.12.2 uses for "neutralised" tallies.
SUNK_ENEMY_KEY: Final[str] = "sunk_enemy"
CAPTURED_ENEMY_KEY: Final[str] = "captured_enemy"

#: The return shape's keys, in wireframe order.
GOLD_KEY: Final[str] = "gold"
XP_KEY: Final[str] = "xp"
REP_DELTAS_KEY: Final[str] = "rep_deltas"
MORALE_KEY: Final[str] = "morale"
CAPTAIN_LIFECYCLE_KEY: Final[str] = "captain_lifecycle"
DROP_ITEM_KEY: Final[str] = "drop_item"
DROP_SOLD_BACK_KEY: Final[str] = "drop_sold_back"


# --- Application seam (§4.12.3) -----------------------------------------------


def apply(outcome: dict[str, Any], person: PersonState | None, *,
          appraisal: int = 0, negotiation: int = 0,
          morale_before: int | None = None, day: int = 0) -> dict[str, Any]:
    """Applies a finished battle's economy effects and returns what was
    applied: ``{gold, xp, rep_deltas, morale, captain_lifecycle}``.

    ``outcome`` is the §4.12.2 block (after ``battle_result.apply``, so the
    lifecycle hooks below can read BattleResult's report fields). Read for
    ``salvage_gold``, ``xp``, ``rep_deltas``, ``morale_delta``,
    ``captain_id`` and ``flagship_duel_lost``; the only write is the
    idempotency marker ``rewards_applied``.

    ``person`` is the injected PersonState (``None`` keeps the call
    read-only: XP and reputation report as unapplied, exactly like the
    GDScript's empty-``GameState.player`` warning path). ``appraisal`` /
    ``negotiation`` are the player's effective haul skills (§4.11.10);
    ``morale_before`` is the purse-side ``GameState.morale`` value the
    §4.8a writeback moves (``None`` skips the writeback read — the caller
    still sees the delta as 0 applied); ``day`` is the injected
    ``GameState.day`` the captain-lifecycle hooks read.

    Returns the state change actually applied:
      ``gold``        the §4.11.10 haul valuation
                      ``floor(salvage_gold × haul_multiplier)`` — the PURSE
                      increment is the caller's (the M1 gold seam)
      ``xp``          the XP awarded through ``Character.award_xp`` —
                      ``floor(outcome.xp × (1 + level/20))`` (Phase 8; the
                      outcome's ``xp`` field stays the raw engine number)
      ``rep_deltas``  per nation, the reputation points the call moved (a
                      +2 at 99 reputation reports +1 — the ±100 clamp)
      ``morale``      the morale points the outcome's ``morale_delta``
                      moved (clamped 0–100)
      ``captain_lifecycle``  :func:`apply_captain_lifecycle`'s report

    An already-applied block returns all-zeroes. A navy ``−20`` is never
    present (§4.11.10).
    """
    applied: dict[str, Any] = {
        GOLD_KEY: 0, XP_KEY: 0, REP_DELTAS_KEY: {},
        MORALE_KEY: 0, CAPTAIN_LIFECYCLE_KEY: {},
    }
    if not isinstance(outcome, dict) or not outcome:
        return applied
    # Defensive: the outcome block may arrive already settled (§4.12.3).
    if bool(outcome.get("rewards_applied", False)):
        return applied
    gold = haul_gold(max(int(outcome.get("salvage_gold", 0)), 0),
                     appraisal, negotiation)
    # Mark first: a retried call must not pay twice.
    outcome["rewards_applied"] = True
    applied[GOLD_KEY] = gold
    if person is None:
        # Awarding XP/reputation would be lost; gold is run-independent, so
        # only it is applied (the GDScript warning path).
        return applied
    deltas = _apply_reputation(person, outcome.get("rep_deltas", {}))
    # §4.8a side-morale writeback: the engine reported the player side's
    # NET event delta and never touches run state (§4.12.1) — this
    # application is its one consumer.
    morale_delta = int(outcome.get("morale_delta", 0))
    if morale_before is not None and morale_delta != 0:
        applied[MORALE_KEY] = _clampi(morale_before + morale_delta, 0, 100) - morale_before
    # §4.11.10 Phase 8: the battle XP total ×(1 + level/20), floored once,
    # on the level held BEFORE the award.
    level = current_level(person)
    xp = battle_xp_for(max(int(outcome.get("xp", 0)), 0), level)
    if xp > 0:
        award_xp(person, xp)
    applied[XP_KEY] = xp
    applied[REP_DELTAS_KEY] = deltas
    applied[CAPTAIN_LIFECYCLE_KEY] = apply_captain_lifecycle(outcome, day)
    return applied


# --- The §4.11.10 formulas ------------------------------------------------------


def haul_multiplier(appraisal: int, negotiation: int) -> float:
    """The §4.11.10 haul-valuation multiplier (Phase 8):
    ``clamp(1 + (appraisal + negotiation) / 400, 1.0, 1.5)`` on the
    player's two effective skills. It prices GOLD — it never re-weights
    goods."""
    return _clampf(1.0 + (appraisal + negotiation) / HAUL_SKILL_DIVISOR,
                   HAUL_MULT_MIN, HAUL_MULT_MAX)


def haul_gold(raw_gold: int, appraisal: int, negotiation: int) -> int:
    """``floor(raw_gold × haul_multiplier)`` — the credited form of a haul
    gold line (the §4.11.11.2 loot-gold lines and the treasure-fleet loot
    gold call this too — single implementation)."""
    return int(math.floor(float(max(int(raw_gold), 0))
                          * haul_multiplier(appraisal, negotiation)))


def battle_xp_for(raw_xp: int, level: int) -> int:
    """The §4.11.10 battle-XP credit (Phase 8): ``floor(raw_xp × (1 +
    level / 20))``. The raw bases — +10 per neutralised hull, +5 per round,
    0 on retreat — stay in the engine's outcome block and :func:`xp_for`."""
    return int(math.floor(float(max(int(raw_xp), 0)) * (1.0 + level / XP_LEVEL_DIVISOR)))


def salvage_for(sunk_ship_type_ids: list[Any]) -> int:
    """``Σ floor(base_price × 0.05)`` over the ``ship_type_id``s of ships
    the player sank this battle. Unknown ids contribute 0 rather than
    crashing a battle end on a corrupted save."""
    total = 0
    if not isinstance(sunk_ship_type_ids, list):
        return total
    for value in sunk_ship_type_ids:
        ship_type = data().get_ship_type(str(value))
        total += int(math.floor(float(ship_type.get("base_price", 0)) * SALVAGE_FRACTION))
    return total


def xp_for(neutralised: int, rounds: int) -> int:
    """``neutralised × 10 + rounds × 5`` (§4.11.10). A retreat is worth 0
    XP — the engine pre-computes ``xp = 0``, so callers must apply the
    block's ``xp``, not this formula, when the outcome may be a retreat."""
    return (max(neutralised, 0) * XP_PER_ENEMY_NEUTRALIZED
            + max(rounds, 0) * XP_PER_ROUND)


def neutralised_for(outcome: dict[str, Any]) -> int:
    """How many enemy ships the block counts as neutralised: sunk +
    captured (``surrendered_enemy`` is a wording sub-tally of
    ``captured_enemy``, never an addition — §4.12.2)."""
    if not isinstance(outcome, dict):
        return 0
    return _list_size(outcome.get(SUNK_ENEMY_KEY, [])) + _list_size(
        outcome.get(CAPTURED_ENEMY_KEY, []))


def _apply_reputation(person: PersonState, value: Any) -> dict[str, int]:
    """Applies every non-zero ``rep_deltas`` entry through
    ``Character.add_reputation`` and returns the deltas AS APPLIED
    (before → after, so a clamp at ±100 shows its real step). An empty
    nation id is skipped."""
    applied: dict[str, int] = {}
    if not isinstance(value, dict):
        return applied
    for nation_key, delta in value.items():
        nation_id = str(nation_key)
        delta = int(delta)
        if not nation_id or delta == 0:
            continue
        before = reputation(person, nation_id)
        after = add_reputation(person, nation_id, delta)
        if after != before:
            applied[nation_id] = after - before
    return applied


# --- Nearest ports (§4.11.10) ------------------------------------------------------


def nearest_nations(contact: tuple[int, int]) -> list[str]:
    """Nations of the two nearest ports to ``contact``, Chebyshev distance,
    ties by port id ascending, each nation credited once.

    **Two ports are selected first, then their nations are credited** — so
    a contact whose two nearest ports belong to the same nation credits
    that nation once and returns a single-entry list. This mirrors
    ``BattleSim._nearest_port_nations`` exactly — the engine uses the list
    for ``rep_deltas``."""
    ports: list[dict[str, Any]] = []
    from server.sim.world.raster import raster
    world = raster()
    store = data()
    for port in store.ports_list:
        if not isinstance(port, dict):
            continue
        # Ports carry lat/lon only; the berth tile is the builder's snap
        # (harbors.json, 90-* §9.1).
        position = world.port_cell(str(port.get("id", "")))
        if position[0] < 0:
            continue
        ports.append({
            "id": str(port.get("id", "")),
            "nation_id": str(port.get("nation_id", "")),
            "distance": world_chebyshev(contact, position),
        })
    ports.sort(key=lambda p: (int(p["distance"]), str(p["id"])))
    nations: list[str] = []
    for entry in ports[:NEAREST_PORT_COUNT]:
        nation_id = str(entry["nation_id"])
        if not nation_id or nation_id in nations:
            continue
        nations.append(nation_id)
    return nations


# --- Captain lifecycle hooks (§4.11.15) ----------------------------------------------


def _captains_lib() -> Any:
    """``scripts/world/captains.gd`` through the §4.12.3 guarded
    convention: the module when it exists AND exposes the contract, else
    ``None`` (the hooks no-op; the module's absence is a merge-order
    state)."""
    try:
        from server.sim.world import captains
    except ImportError:
        return None
    if not (hasattr(captains, "defeat") and hasattr(captains, "adjust_stance")
            and hasattr(captains, "is_nemesis")):
        return None
    return captains


def outcome_captain_id(outcome: dict[str, Any]) -> str:
    """The ``captain_id`` an outcome carries: the caller-threaded
    battle-config id, else the first captured enemy hull's own
    ``captain_id``. "" when neither is present — the legacy fleets the
    hooks must skip."""
    threaded = str(outcome.get(CAPTAIN_ID_KEY, ""))
    if threaded:
        return threaded
    captured = outcome.get("captured_enemy", [])
    if isinstance(captured, list):
        for hull in captured:
            if isinstance(hull, dict) and str(hull.get(CAPTAIN_ID_KEY, "")):
                return str(hull[CAPTAIN_ID_KEY])
    return ""


def crushed_victory(outcome: dict[str, Any]) -> bool:
    """The ``crushed`` pin for a victory outcome: the fleet was wiped — no
    hull joined the player fleet (``captured_ships``) and none surrendered
    (``surrendered_enemy``)."""
    joined = outcome.get("captured_ships", [])
    return ((isinstance(joined, list) and not joined)
            and int(outcome.get("surrendered_enemy", 0)) == 0)


def apply_captain_lifecycle(outcome: dict[str, Any], day: int) -> dict[str, Any]:
    """The §4.11.15 captain lifecycle hooks (Phase 8). Fired from
    :func:`apply` — the §4.12.4 step-3 seam, after ``battle_result.apply``
    has reported which hulls joined and whether the flagship fell. A no-op
    without a ``captain_id`` or when the captains module is absent.

      * **Defeat** — ``result == "victory"`` → ``Captains.defeat(captain_id,
        day, crushed)`` (``crushed`` = the fleet was wiped).
      * **Nemesis extra** — ``Captains.is_nemesis`` → ``adjust_stance(−2)``.
      * **Win** — ``flagship_duel_lost`` → ``Captains.win(captain_id, day)``.

    Returns the report ``{captain_id, defeat, crushed, win, nemesis_stance}``.
    The ``day`` argument is the injected ``GameState.day`` the GDScript read.
    """
    report: dict[str, Any] = {
        "captain_id": "", "defeat": False, "crushed": False,
        "win": False, "nemesis_stance": 0,
    }
    if not isinstance(outcome, dict) or not outcome:
        return report
    lib = _captains_lib()
    if lib is None:
        return report
    captain_id = outcome_captain_id(outcome)
    if not captain_id:
        return report
    report["captain_id"] = captain_id
    if str(outcome.get("result", "")) == RESULT_VICTORY:
        crushed = crushed_victory(outcome)
        lib.defeat(captain_id, int(day), crushed)
        report["defeat"] = True
        report["crushed"] = crushed
        if bool(lib.is_nemesis(captain_id)):
            stance = int(lib.adjust_stance(captain_id, int(lib.STANCE_NEMESIS_DEFEAT)))
            report["nemesis_stance"] = stance
    if bool(outcome.get(FLAGSHIP_DUEL_LOST_KEY, False)):
        lib.win(captain_id, int(day))
        report["win"] = True
    return report


def apply_piracy_attack(victim_nation_id: str, victim_captain_id: str = "",
                        person: PersonState | None = None,
                        fame_before: int | None = None) -> dict[str, Any]:
    """The §4.11.10 piracy-fame extension, exposed for the **single
    battle-start funnel** (this module never fires it at battle end and
    never per ship). The caller owns the §4.11.15 preconditions: the fleet
    was non-hostile, its role is not ``pirate``, coasters are unreachable.

    Applies, in one call:
      1. the ``Bounty.apply_piracy`` charge — rep −20 with the owner, +2
         with each of its two ``data/nations.json#rivals`` — via the
         guarded bounty-module import (another agent's file; absent ⇒ the
         funnel reports an empty rep delta);
      2. the fame −20 extension — floored at 0 (``fame_before`` injected);
      3. the victim captain's grudge — ``Captains.adjust_stance(−1)``.

    Returns ``{rep_deltas, fame, stance}`` — the deltas actually applied
    (the gold/rep/fame mutations beyond ``person``'s reputation table are
    the caller's).
    """
    applied: dict[str, Any] = {"rep_deltas": {}, "fame": 0, "stance": 0}
    if not victim_nation_id:
        return applied
    # 1. The unchanged rep funnel (the −20 owner, +2 rivals, bounty re-check).
    # The quest module is another agent's file and its signature may inject
    # the PersonState either positionally or read its own state; the arity
    # probe keeps this seam callable under both shapes.
    try:
        import inspect
        from server.sim.quests import bounty
        params = [p for p in inspect.signature(bounty.apply_piracy).parameters.values()
                  if p.kind in (inspect.Parameter.POSITIONAL_ONLY,
                                inspect.Parameter.POSITIONAL_OR_KEYWORD)]
        if len(params) >= 2:
            applied["rep_deltas"] = bounty.apply_piracy(victim_nation_id, person)
        else:
            applied["rep_deltas"] = bounty.apply_piracy(victim_nation_id)
    except (ImportError, TypeError, ValueError):
        applied["rep_deltas"] = {}
    # 2. The Phase-8 fame extension: −20 once, floored at 0.
    if fame_before is not None:
        applied["fame"] = max(0, fame_before + PIRACY_FAME_PENALTY) - fame_before
    # 3. The victim captain remembers (§4.11.15).
    if victim_captain_id:
        lib = _captains_lib()
        if lib is not None:
            applied["stance"] = int(
                lib.adjust_stance(victim_captain_id, int(lib.STANCE_ATTACK_NONHOSTILE)))
    return applied


# --- Rare drops (§4.11.13) ---------------------------------------------------------


def apply_named_drop(outcome: dict[str, Any], captain_named_id: str,
                     person: PersonState | None = None,
                     fleet: list[dict[str, Any]] | None = None) -> str:
    """The Phase-7 rare-drop flow (§4.11.13, keyed by the sunk/captured
    captain id): match ``captain_named_id`` against
    ``data/named_pirates.json``, credit the match's ``drop`` item, and
    equip it through the standing replace rule (§4.11.12) —
    ``weapon``/``armor`` fit the player's equipment,
    ``figurehead``/``sail`` fit the flagship (``fleet[0]``); an occupied
    slot sells the displaced item back at ``floor(price × 0.5)`` (the
    caller credits :func:`drop_sell_back_gold` — the M1 purse seam). Writes
    ``drop_item`` (+ ``drop_sold_back`` when a displaced item sold) into
    ``outcome`` and returns the granted item id ("" when nothing matched or
    the run/flagship cannot carry it). Rare items are never tier-gated."""
    if not isinstance(outcome, dict) or not outcome:
        return ""
    named_id = str(captain_named_id)
    if not named_id:
        return ""
    store = data()
    pirate = store.get_named_pirate(named_id)
    item_id = str(pirate.get("drop", "")) if pirate else ""
    if not item_id:
        return ""
    item = store.get_equipment(item_id)
    if not item:
        print(f"BattleRewards.apply_named_drop: unknown drop item {item_id}")
        return ""
    slot = str(item.get("slot", ""))
    occupied = ""
    if slot in ("weapon", "armor"):
        if person is None:
            return ""
        equipment = person.player.get("equipment", {})
        if not isinstance(equipment, dict):
            equipment = {}
        occupied = str(equipment.get(slot, ""))
        equipment[slot] = item_id
        person.player["equipment"] = equipment
    else:
        # `figurehead`/`sail` fit the flagship (fleet index 0, §4.11.2).
        if not fleet or not isinstance(fleet[0], dict):
            return ""
        flagship: dict[str, Any] = fleet[0]
        ship_equipment = flagship.get("equipment", {})
        if not isinstance(ship_equipment, dict):
            ship_equipment = {}
        occupied = str(ship_equipment.get(slot, ""))
        ship_equipment[slot] = item_id
        flagship["equipment"] = ship_equipment
    sold_back = ""
    if occupied and occupied != item_id:
        displaced = store.get_equipment(occupied)
        if displaced:
            sold_back = occupied
    outcome[DROP_ITEM_KEY] = item_id
    outcome[DROP_SOLD_BACK_KEY] = sold_back
    return item_id


def drop_sell_back_gold(displaced_id: str) -> int:
    """``floor(price × 0.5)`` for a displaced rare-drop item — the
    sell-back credit the caller adds to the purse (§4.11.12/§4.11.13)."""
    item = data().get_equipment(str(displaced_id))
    if not item:
        return 0
    return int(math.floor(float(int(item.get("price", 0))) * 0.5))


# --- Helpers ------------------------------------------------------------------------


def _list_size(value: Any) -> int:
    return len(value) if isinstance(value, list) else 0


def _clampi(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


def _clampf(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))
