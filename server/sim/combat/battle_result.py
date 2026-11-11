"""server.sim.combat.battle_result — battle-end fleet effects (M1).

Python port of ``scripts/combat/battle_result.gd`` (the frozen parity
oracle until the M6 cutover) — docs/60-COMBAT.md §4.11.7, §4.11.9,
§4.12.3. The one module allowed to move ships between a battle's outcome
block and the player fleet.

Layering (docs/60 §4.12.4): ``BattleSim`` produced the raw outcome and
never touched run state; :func:`apply` is step 2 of the battle-end
sequence. It touches **only** the injected fleet list and reports
``game_over`` as a string — gold, XP and reputation belong to
:mod:`server.sim.combat.battle_rewards` (step 3); the gold mutation and
the ``EventBus`` announcements are the caller's (the M1 purity contract —
the GDScript ``FleetLib.notify_changed`` / ``EventBus.game_over.emit``
seams).

Duplicated rules: none. The cargo-hold maths
(:func:`server.sim.fleet.fleet.add_goods` /
``normalize_all``) lives in :mod:`server.sim.fleet.fleet`; the
25%-durability capture transform is the one number §4.11.7 pins and is
applied here (the sim deliberately reports the hull intact).

Doc-visible behaviours carried verbatim:
  * **Nothing is dropped silently.** Every hold unit that cannot be
    carried is summed into ``cargo_overflow_lost`` (§4.12.2,
    ``battle.after.overflow``).
  * **A capture is not a sinking.** A lost player hull is removed without
    touching the rest of the fleet's holds; the next ship is simply
    ``fleet[0]`` afterwards (§4.11.7 "order preserved").
  * Both player loss lists are applied: ``lost_player`` (captured hull
    instances) and ``sunk_player`` (ship_type_ids). A sunk hull leaves the
    fleet here because §4.12.4 makes this seam the only fleet mutator.
  * Phase 8 (W4-C): the idle-officer capture gate (§4.11.7/§4.11.15) — a
    prize joins only with fleet room AND ≥ 1 idle officer; otherwise the
    loot-convert fallback fires and the report names the failed gate
    (``capture_gate_failed``); plus the ``flagship_duel_lost`` report
    field, the captain ``win`` hook's input.

State convention (M1): the fleet array is an injected ``list`` (the
server's GameState port owns the live fleet exactly like
``GameState.fleet`` did); the idle-officer roster arrives as the injected
``idle_officer_ids`` list (the caller computes it through
``skills.officers_in_post(st, "")`` — the GDScript's ``SkillsLib`` read).
"""

from __future__ import annotations

import math
from typing import Any, Final, Sequence

from server.sim.fleet.fleet import FLEET_MAX, add_goods, normalize_all

__all__ = [
    "CAPTURE_DURABILITY_FRACTION",
    "GAME_OVER_CAPTURED",
    "GAME_OVER_SUNK",
    "CAPTURE_GATE_KEY",
    "CAPTURE_GATE_FLEET_FULL",
    "CAPTURE_GATE_NO_IDLE_OFFICER",
    "FLAGSHIP_DUEL_LOST_KEY",
    "apply",
]

## §4.11.7 capture transform: ``max(1, floor(current durability × 0.25))``.
CAPTURE_DURABILITY_FRACTION: Final[float] = 0.25

## §4.11.7: the two game-over reasons this module can produce (60-* §6).
GAME_OVER_CAPTURED: Final[str] = "captured"
GAME_OVER_SUNK: Final[str] = "sunk"

## --- Phase 8 capture gate (§4.11.7/§4.11.15, W4-C) --------------------------
##
## The gate needs BOTH: fleet room (§4.11.7's original clause) AND ≥ 1 idle
## officer (employed, ``post_id == ""``) to take the prize's captain post.
## A hull that fails either gate is loot-converted and scuttled; the report
## names the gate that failed (first failure wins).
CAPTURE_GATE_KEY: Final[str] = "capture_gate_failed"
CAPTURE_GATE_FLEET_FULL: Final[str] = "fleet_full"
CAPTURE_GATE_NO_IDLE_OFFICER: Final[str] = "no_idle_officer"

## BattleResult's report field for the §4.11.7 player-loses branch: true
## when a ``lost_player`` hull was the flagship (``fleet[0]``).
FLAGSHIP_DUEL_LOST_KEY: Final[str] = "flagship_duel_lost"


def apply(sim_outcome: dict[str, Any], enemy_units: list[dict[str, Any]],
          fleet: list[dict[str, Any]],
          idle_officer_ids: Sequence[str] = ()) -> dict[str, Any]:
    """Applies the fleet-only part of a finished battle and returns the
    outcome block with the report fields filled in.

    ``sim_outcome`` is ``BattleSim.outcome()`` (§4.12.2) — read, never
    mutated (the returned dict is a deep copy). ``enemy_units`` is
    ``BattleSim.units()``; it is used only to tag each capture with the
    enemy fleet index it came from (diagnostics), so an outcome replayed
    without units still applies correctly. ``fleet`` is normally the live
    fleet array; it IS mutated (captures append, losses are removed).
    ``idle_officer_ids`` is the caller's ``officers_in_post(st, "")`` read.

    Order (§4.12.3/§4.11.7): captures → hold guard → losses → game-over
    report. Returns a copy of ``sim_outcome`` plus:
      ``cargo_overflow_lost``  hold units lost for lack of space (§4.12.2)
      ``captured_ships``       ship_type_ids that joined the fleet
      ``scuttled_ships``       ship_type_ids looted and scuttled
      ``lost_ships``           ship_type_ids the player lost this battle
      ``sunk_ships``           ship_type_ids removed because they sank
      ``captured_units``       ``[{index, ship_type_id}]`` per capture
      ``capture_gate_failed``  ``""``/``"fleet_full"``/``"no_idle_officer"``
      ``flagship_duel_lost``   a lost player hull was the flagship
      ``game_over``            ``""``/``"captured"``/``"sunk"`` (what the
                               caller announces — the EventBus seam)
    """
    outcome = _deep_copy(sim_outcome)
    report: dict[str, Any] = {
        "cargo_overflow_lost": 0,
        "captured_ships": [],
        "scuttled_ships": [],
        "lost_ships": [],
        "sunk_ships": [],
        "captured_units": [],
        CAPTURE_GATE_KEY: "",
        FLAGSHIP_DUEL_LOST_KEY: False,
        "game_over": "",
    }
    # The §4.11.7 flagship is `fleet[0]` and captures only ever append, so
    # this snapshot is the flagship however the battle ends; the loss loop
    # below matches `lost_player` against it.
    flagship: dict[str, Any] = (
        fleet[0] if fleet and isinstance(fleet[0], dict) else {})

    changed = False
    joined = False

    # --- a. captures join the fleet, or are looted and scuttled ------------
    captured = outcome.get("captured_enemy", [])
    if isinstance(captured, list):
        for ship in captured:
            if not isinstance(ship, dict):
                continue
            hull: dict[str, Any] = ship
            ship_type_id = str(hull.get("ship_type_id", ""))
            enemy_index = _enemy_index(enemy_units, hull)
            if _capture_gate_open(fleet, idle_officer_ids):
                fleet.append(_capture_copy(hull))
                report["captured_ships"].append(ship_type_id)
                report["captured_units"].append(
                    {"index": enemy_index, "ship_type_id": ship_type_id})
                joined = True
                changed = True
            else:
                # §4.11.7/§4.11.15: a capture gate failed → cargo to
                # capacity flagship-first, the rest reported lost, the hull
                # scuttled — the loot-convert fallback.
                report["cargo_overflow_lost"] = (
                    int(report["cargo_overflow_lost"]) + _loot_cargo(hull, fleet))
                report["scuttled_ships"].append(ship_type_id)
                if not str(report[CAPTURE_GATE_KEY]):
                    report[CAPTURE_GATE_KEY] = _failed_capture_gate(
                        fleet, idle_officer_ids)
                changed = True

    # §4.11.7: "If the hold is then over capacity, Fleet.normalize_all()
    # truncates it and the after-action dialog reports the overflow" — the
    # guard runs once, and whatever it drops is added to the report.
    if joined:
        report["cargo_overflow_lost"] = (
            int(report["cargo_overflow_lost"]) + _normalize_reporting_drops(fleet))

    # --- b. the player's lost ships leave the fleet -----------------------
    # `lost_player` (§4.12.2) carries the captured/taken instances;
    # `sunk_player` carries ship_type_ids only, but a sunk hull must leave
    # the fleet too (§4.7 "durability 0 → the ship sinks immediately").
    lost = outcome.get("lost_player", [])
    if isinstance(lost, list):
        for ship in lost:
            if not isinstance(ship, dict):
                continue
            if _is_flagship_hull(flagship, ship):
                # §4.11.7: the boarded-from ship was the flagship — the
                # captain lifecycle's `win` input (§4.11.15).
                report[FLAGSHIP_DUEL_LOST_KEY] = True
            if _remove_first_match(fleet, ship):
                report["lost_ships"].append(str(ship.get("ship_type_id", "")))
                changed = True

    sunk = outcome.get("sunk_player", [])
    if isinstance(sunk, list):
        for ship_type_value in sunk:
            if _remove_first_of_type(fleet, str(ship_type_value)):
                report["sunk_ships"].append(str(ship_type_value))
                changed = True

    # --- c. game-over report (the fleet itself is the caller's state) ------
    if changed:
        report["game_over"] = _game_over_reason(outcome, fleet)

    outcome.update(report)
    return outcome


# --- Capture / loot ----------------------------------------------------------


def _capture_gate_open(fleet: list[dict[str, Any]],
                       idle_officer_ids: Sequence[str]) -> bool:
    """The §4.11.7/§4.11.15 capture gate: ``true`` when the prize may join
    the fleet — fleet room AND ≥ 1 idle officer. Re-evaluated per capture.
    The roster cap never gates a capture: the idle officer is already
    employed, so manning the prize is a post appointment, not a 13th
    recruit."""
    if len(fleet) >= FLEET_MAX:
        return False
    return len(idle_officer_ids) > 0


def _failed_capture_gate(fleet: list[dict[str, Any]],
                         idle_officer_ids: Sequence[str]) -> str:
    """Which §4.11.7 gate failed, in the pin's own order (fleet size
    first): the value the after-action dialog names (§4.11.15)."""
    if len(fleet) >= FLEET_MAX:
        return CAPTURE_GATE_FLEET_FULL
    return CAPTURE_GATE_NO_IDLE_OFFICER


def _is_flagship_hull(flagship: dict[str, Any], ship: dict[str, Any]) -> bool:
    """True when ``ship`` is the flagship hull: the snapshot's deep-equal
    first (the common case — the flagship was never touched), else the same
    hull type (the instance the battle changed before it was taken)."""
    if not flagship:
        return False
    if flagship == ship:
        return True
    ship_type_id = str(flagship.get("ship_type_id", ""))
    return bool(ship_type_id) and str(ship.get("ship_type_id", "")) == ship_type_id


def _capture_copy(hull: dict[str, Any]) -> dict[str, Any]:
    """§4.11.7: ``max(1, floor(current durability × 0.25))``, ``crew = 0``,
    and the hold, cannons and equipment travel with the hull untouched."""
    ship = _deep_copy(hull)
    current = int(ship.get("durability", 0))
    ship["durability"] = max(1, int(math.floor(float(current) * CAPTURE_DURABILITY_FRACTION)))
    ship["crew"] = 0
    return ship


def _loot_cargo(hull: dict[str, Any], fleet: list[dict[str, Any]]) -> int:
    """§4.11.7 full-fleet path: move as much of the scuttled hull's trade
    goods as the fleet can hold (flagship-first), and return the number of
    hold units destroyed with her — the untaken goods plus the provisions
    and water that had no room. A capture is not a sinking, so nothing
    relocates from the player's own ships."""
    lost = 0
    cargo = hull.get("cargo", {})
    if isinstance(cargo, dict):
        for good_id, qty in cargo.items():
            qty = max(int(qty), 0)
            if qty <= 0:
                continue
            lost += qty - add_goods(fleet, str(good_id), qty)
    # Provisions and water are their own fields (§4.2), so `add_goods`
    # cannot take them; they burn with the hull. Reported, never silent.
    lost += max(int(hull.get("provisions", 0)), 0)
    lost += max(int(hull.get("water", 0)), 0)
    return lost


def _normalize_reporting_drops(fleet: list[dict[str, Any]]) -> int:
    """Runs the canonical capacity guard over the fleet and returns the
    hold units it dropped, measured before/after so the truncation rule
    itself stays in fleet.py."""
    before = _fleet_hold_units(fleet)
    normalize_all(fleet)
    return max(before - _fleet_hold_units(fleet), 0)


def _fleet_hold_units(fleet: list[dict[str, Any]]) -> int:
    """The oracle's hold-unit measure: provisions + water + trade goods
    per ship (cannons are constant across the normalize pass, so they
    cancel in the before/after difference — measured the oracle's way)."""
    total = 0
    for ship in fleet:
        if not isinstance(ship, dict):
            continue
        total += int(ship.get("provisions", 0))
        total += int(ship.get("water", 0))
        cargo = ship.get("cargo", {})
        if isinstance(cargo, dict):
            for good_id, qty in cargo.items():
                total += max(int(qty), 0)
    return total


# --- Loss / promotion -----------------------------------------------------------


def _remove_first_match(fleet: list[dict[str, Any]], ship: dict[str, Any]) -> bool:
    """Removes one fleet entry for ``ship`` and returns whether one was
    found. The outcome block carries full ship instances, not fleet indices
    (§4.12.2), so matching has two passes: ① deep equality (exact — the
    common case, because ``BattleSim`` deep-copies the instance on capture
    and an untouched hull compares equal to its fleet original); ② same
    hull type, first unconsumed occurrence — the fallback for a ship the
    battle changed before it was taken."""
    for index, entry in enumerate(fleet):
        if isinstance(entry, dict) and entry == ship:
            del fleet[index]
            return True
    ship_type_id = str(ship.get("ship_type_id", ""))
    if not ship_type_id:
        return False
    return _remove_first_of_type(fleet, ship_type_id)


def _remove_first_of_type(fleet: list[dict[str, Any]], ship_type_id: str) -> bool:
    """Removes the first fleet hull of ``ship_type_id``; returns whether one
    existed."""
    if not ship_type_id:
        return False
    for index, entry in enumerate(fleet):
        if (isinstance(entry, dict)
                and str(entry.get("ship_type_id", "")) == ship_type_id):
            del fleet[index]
            return True
    return False


def _game_over_reason(outcome: dict[str, Any], fleet: list[dict[str, Any]]) -> str:
    """§4.11.7/§4.11.9: with hulls left, ``fleet[0]`` is the flagship again
    (order already preserved by the removals) and no game-over fires. An
    empty fleet ends the run with ``captured`` for a capture-caused defeat
    and ``sunk`` for a sinking (the caller routes to the game-over screen).
    The GDScript emits ``EventBus.game_over`` + ``FleetLib.notify_changed``
    here; both announcements are the caller's seam."""
    if fleet:
        return ""
    result = str(outcome.get("result", ""))
    return GAME_OVER_SUNK if result == "defeat_sunk" else GAME_OVER_CAPTURED


def _enemy_index(enemy_units: list[dict[str, Any]], hull: dict[str, Any]) -> int:
    """Enemy fleet index of a captured hull, ``-1`` when ``enemy_units`` is
    absent or no unit matches. Diagnostic only: never affects what is
    applied."""
    for unit in enemy_units:
        if not isinstance(unit, dict):
            continue
        unit_ship = unit.get("ship")
        if isinstance(unit_ship, dict) and unit_ship == hull:
            return int(unit.get("index", -1))
    return -1


def _deep_copy(value: Any) -> Any:
    if isinstance(value, dict):
        return {k: _deep_copy(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_deep_copy(v) for v in value]
    return value
