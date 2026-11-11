"""server.sim.combat.fleet_commander — the §4.9b fleet-command layer (M1).

Python port of ``scripts/combat/fleet_commander.gd`` (the frozen parity
oracle until the M6 cutover) — docs/60-COMBAT.md §4.9b (order five-tuples,
the state-machine table, hysteresis, anchor succession) and §4.12.3.

Per round, for every AI ship, the fleet commander emits an **order
five-tuple** ``{station, desired_heading8, desired_speed_band,
assigned_target, discipline}`` plus the ``phase`` consumption rider —
consumed by :func:`server.sim.combat.ai_fleet.decide`'s ``order`` parameter.

PURE and ZERO-RNG: the same ``(view, profile, state)`` triple always yields
the same orders array — assert-friendly by construction (no ``randi``, no
clock, no global writes; the only globals read are read-only data).

INTERFACE (§4.12.3 pin — names + purity):

  ``generate_orders(view, profile, state) -> list``

* ``view`` — the read-only battle view the CALLER assembles from the sim:
  ``{"units": list, "round": int, "enemy_kind": str}`` where each unit dict
  is the sim's unit shape (side / index / pos / vel / heading8 / ship /
  alive — ``BattleSim.units()`` entries verbatim, both sides). Optional key
  ``side_morale`` (int 0..100): the caller threads
  ``sim.side_morale("enemy")`` through it WHEN the W4-A seam exists —
  absent/``None`` ⇒ the §4.9b pre-fleet-layer fallback: no morale break.
  The view is never mutated.
* ``profile`` — the §4.10 row via :func:`server.sim.combat.ai_fleet.profile_for`
  (six live T2 keys + ``formation``). Never mutated.
* ``state`` — the commander's persistent per-battle state the CALLER owns
  and passes back each round, seeded once by :func:`initial_state`::

      {
        "formation": str,        # line_ahead|column|screen|swarm
        "phase": str,            # form|close|engage|wear|break|screen|swarm
        "phase_rounds": int,     # completed rounds in `phase`
        "anchor_pos": Cell,      # the formation reference cell
        "anchor_heading": int,   # the queue heading bucket 0..7
        "assignments": dict,     # ai fleet index -> player fleet index
        "flagship_down": bool,   # succession has happened
      }

  **Updated IN PLACE**: :func:`generate_orders` writes the post-round
  phase / phase_rounds / anchor / assignments back into the same dict, so
  the caller's only duty is to keep passing the same dictionary once per
  round. Determinism holds: same view + same incoming state ⇒ same orders
  AND same outgoing state.
* returns — one entry per LIVING AI ship, fleet-index order:
  ``{"index": int, "order": dict}`` with the §4.9b five-tuple
  ``{"station": Cell, "desired_heading8": int,
  "desired_speed_band": [lo, hi], "assigned_target": int,
  "discipline": bool}`` (``assigned_target`` = player fleet index, −1 =
  none) plus the consumption rider ``phase: str`` — the state-machine phase
  the order was emitted under; ``AiFleet.decide`` keys its steering modes
  on it. The five-tuple keys are the §4.9b contract; the rider is W4-B
  plumbing.

STATE MACHINE ``form → close → engage → wear → break`` (§4.9b table), per
formation: ``line_ahead`` runs all five; ``column`` = form/close/engage
(+ wear/break as forced states); ``screen`` = flagship-radius-3 screen +
free fire (no line states); ``swarm`` = target assignment only. Round
accounting: ``phase_rounds`` counts COMPLETED rounds in the phase; the exit
test runs before the round's orders are emitted, and a transition needs
``held >= 2`` (hysteresis) unless forced. Forced transitions: the ``form``
3-round bail-out, the §4.9b morale break (side morale ≤ 20 — terminal, from
any line state), ``column``'s engage→wear (hysteresis-exempt per "+wear/break
as forced states"), and ``wear``'s own lock exit (the lock IS the wear gate
— §4.9b table row; it cannot be interrupted by anything else). Geometry:
all §4.9b judgments are on CURRENT (already-landed) positions; the
landing-cell discipline of §4.11.8 pin 1 applies where velocities exist —
inside :func:`server.sim.combat.ai_fleet.decide`, which reuses
``ai_fleet._landing`` (never a second sweep preview here).
"""

from __future__ import annotations

from typing import Any, Final

from server.sim.combat import ai_fleet
from server.sim.combat.battle_sim import (
    GRID_HEIGHT,
    GRID_WIDTH,
    HEADING_RAYS,
    NO_CELL,
    SIDE_ENEMY,
    SIDE_PLAYER,
    Cell,
    bucket_distance,
    heading8_of,
    to_cell,
)

__all__ = [
    "HYSTERESIS_ROUNDS",
    "FORM_BAIL_ROUNDS",
    "STATION_DEVIATION_MAX",
    "CLOSE_ENGAGE_RANGE",
    "WEAR_TOLERANCE_BUCKETS",
    "MORALE_BREAK",
    "PHASE_FORM",
    "PHASE_CLOSE",
    "PHASE_ENGAGE",
    "PHASE_WEAR",
    "PHASE_BREAK",
    "PHASE_SCREEN",
    "PHASE_SWARM",
    "FORMATION_LINE_AHEAD",
    "FORMATION_COLUMN",
    "FORMATION_SCREEN",
    "FORMATION_SWARM",
    "PERPENDICULAR_BUCKETS",
    "initial_state",
    "generate_orders",
]

# --- Pinned numbers (docs/60-COMBAT.md §4.9b — nothing invented) -------------

HYSTERESIS_ROUNDS: Final[int] = 2       # "every state holds ≥ 2 rounds"
FORM_BAIL_ROUNDS: Final[int] = 3        # form bail-out "after 3 rounds"
STATION_DEVIATION_MAX: Final[int] = 2   # form exit: station deviation ≤ 2
CLOSE_ENGAGE_RANGE: Final[int] = 5      # close exit: nearest enemy Chebyshev ≤ 5
WEAR_TOLERANCE_BUCKETS: Final[int] = 1  # wear lock: within ±1 bucket
MORALE_BREAK: Final[int] = 20           # side morale ≤ 20 ⇒ break (AiFleet pin)

# --- Phase / formation vocabulary (the state-dict's string values) -----------

PHASE_FORM: Final[str] = "form"
PHASE_CLOSE: Final[str] = "close"
PHASE_ENGAGE: Final[str] = "engage"
PHASE_WEAR: Final[str] = "wear"
PHASE_BREAK: Final[str] = "break"
PHASE_SCREEN: Final[str] = "screen"
PHASE_SWARM: Final[str] = "swarm"

FORMATION_LINE_AHEAD: Final[str] = "line_ahead"
FORMATION_COLUMN: Final[str] = "column"
FORMATION_SCREEN: Final[str] = "screen"
FORMATION_SWARM: Final[str] = "swarm"

PERPENDICULAR_BUCKETS: Final[int] = 2   # ±90° in the 8-bucket compass


# --- Construction (docs/60-* §4.9b, §4.12.3) ---------------------------------


def initial_state(formation: str, anchor_pos: Cell,
                  anchor_heading: int) -> dict[str, Any]:
    """The battle-start state the caller seeds and keeps passing back: the
    formation from the profile row, the anchor = flagship pos + heading8
    (§4.9b "anchor = flagship pos + heading8 at battle start"). The phase
    opens at ``form`` for the line formations, at the formation's own
    non-walked phase for screen/swarm. Pure.
    """
    resolved = formation
    if resolved not in (FORMATION_LINE_AHEAD, FORMATION_COLUMN,
                        FORMATION_SCREEN):
        resolved = FORMATION_SWARM  # unknown rows degrade to swarm semantics
    return {
        "formation": resolved,
        "phase": _opening_phase(resolved),
        "phase_rounds": 0,
        "anchor_pos": _wrap_in_grid(to_cell(anchor_pos)),
        "anchor_heading": anchor_heading % len(HEADING_RAYS),
        "assignments": {},
        "flagship_down": False,
    }


def _opening_phase(formation: str) -> str:
    if formation in (FORMATION_LINE_AHEAD, FORMATION_COLUMN):
        return PHASE_FORM
    if formation == FORMATION_SCREEN:
        return PHASE_SCREEN
    return PHASE_SWARM


# --- The per-round entry point (§4.12.3 pin signature) -----------------------


def generate_orders(view: dict[str, Any], profile: dict[str, Any],
                    state: dict[str, Any]) -> list[dict[str, Any]]:
    """Emits one five-tuple per living AI ship and advances ``state`` in
    place (see the module doc). Pure, deterministic, zero RNG."""
    own = _living_fleet(view)
    if not own:
        return []
    enemies = _living_enemies(view)
    if not enemies:
        return []
    morale = _view_morale(view)

    _update_anchor(state, own)
    _advance_state_machine(state, own, enemies, morale)

    phase = str(state.get("phase", PHASE_SWARM))
    assignments: dict[int, int] = state.get("assignments", {})
    # §4.9b target assignment: recomputed live in engage (and in the swarm
    # formation, whose only business IS the assignment); wear keeps the last
    # engage distribution (the maneuver holds the line it engaged with) and
    # break keeps it too ("dissolve to swarm — assignments kept").
    if phase in (PHASE_ENGAGE, PHASE_SWARM):
        assignments = _assign_targets(profile, state, own, enemies)
        state["assignments"] = assignments

    stations = _stations(state, own)
    orders: list[dict[str, Any]] = []
    for unit in own:
        orders.append({
            "index": int(unit.get("index", -1)),
            "order": _order_for(unit, state, phase, stations, assignments),
        })
    return orders


# --- State machine (docs/60-* §4.9b table) -----------------------------------


def _advance_state_machine(state: dict[str, Any], own: list[dict[str, Any]],
                           enemies: list[dict[str, Any]], morale: int) -> None:
    """Runs the §4.9b exit tests for the current phase against the CURRENT
    view, applies hysteresis / forced-transition rules, and writes the
    resulting phase (with the entry hooks' anchor bookkeeping) into
    ``state``.
    """
    formation = str(state.get("formation", FORMATION_SWARM))
    # screen/swarm rows have no line states — their phase is their formation.
    if formation in (FORMATION_SCREEN, FORMATION_SWARM):
        return
    phase = str(state.get("phase", PHASE_FORM))
    held = max(int(state.get("phase_rounds", 0)), 0)
    anchor = to_cell(state.get("anchor_pos", (0, 0)))

    # §4.9b bullet: side morale ≤ 20 ⇒ break — forced, terminal, from any
    # line state (the seam is threaded through the view; absent ⇒ the
    # pre-fleet-layer fallback: no morale break).
    if 0 <= morale <= MORALE_BREAK and phase != PHASE_BREAK:
        _enter(state, PHASE_BREAK)
        return
    if phase == PHASE_BREAK:
        return  # terminal for the battle

    nearest = _nearest_enemy_cell(anchor, enemies)
    bearing = _bearing_to(anchor, nearest)
    if phase == PHASE_FORM:
        settled = _formation_settled(state, own)
        # Forced bail-out: "after 3 rounds" → close. Otherwise the
        # completion exit needs the hysteresis hold as well.
        if held >= FORM_BAIL_ROUNDS or (settled and held >= HYSTERESIS_ROUNDS):
            _enter_close(state, bearing)
        else:
            state["phase_rounds"] = held + 1
    elif phase == PHASE_CLOSE:
        # Column cruise: aim the queue at the enemy and step the anchor one
        # cell (clamped in-grid — the cruise never wraps; only the trailing
        # stations do). The step commits first; the exit test reads the
        # committed cell.
        ray = HEADING_RAYS[bearing % 8]
        moved = _clamp_in_grid((anchor[0] + ray[0], anchor[1] + ray[1]))
        state["anchor_pos"] = moved
        state["anchor_heading"] = bearing % len(HEADING_RAYS)
        if (_chebyshev(moved, to_cell(nearest["cell"])) <= CLOSE_ENGAGE_RANGE
                and held >= HYSTERESIS_ROUNDS):
            _enter_engage(state, bearing)
        else:
            state["phase_rounds"] = held + 1
    elif phase == PHASE_ENGAGE:
        parallel = _is_parallel(bearing, int(state.get("anchor_heading", 0)))
        # line_ahead: the bearing-parallel exit is a non-forced transition
        # (hysteresis). column: "+wear as a forced state" — hysteresis-exempt.
        may_wear = held >= HYSTERESIS_ROUNDS or formation == FORMATION_COLUMN
        if parallel and may_wear:
            _enter_wear(state, bearing)
        else:
            state["phase_rounds"] = held + 1
    elif phase == PHASE_WEAR:
        # Locked until every living ship is within ±1 bucket (the §4.9b wear
        # row IS the gate — no extra hysteresis on top; nothing else may
        # interrupt the maneuver).
        if _wear_complete(state, own):
            _enter_engage(state, bearing)
        else:
            state["phase_rounds"] = held + 1


def _enter(state: dict[str, Any], phase: str) -> None:
    state["phase"] = phase
    state["phase_rounds"] = 0


def _enter_close(state: dict[str, Any], bearing: int) -> None:
    _enter(state, PHASE_CLOSE)
    if bearing >= 0:
        state["anchor_heading"] = bearing % len(HEADING_RAYS)


def _enter_engage(state: dict[str, Any], bearing: int) -> None:
    """Engage entry: the queue heading sticks at a perpendicular (±90°
    bucket) of the enemy bearing — the one requiring the smaller turn from
    the old queue heading, ties to +90° (§4.9b "perpendicular to the enemy
    bearing")."""
    _enter(state, PHASE_ENGAGE)
    if bearing >= 0:
        old = int(state.get("anchor_heading", 0))
        state["anchor_heading"] = _perpendicular_toward(bearing, old)


def _enter_wear(state: dict[str, Any], bearing: int) -> None:
    """Wear entry: the wear heading = the old engage heading ± 90° toward
    the new enemy bearing (both candidates are ⊥ the bearing because wear
    fires only when the bearing is parallel to the old queue); the smaller
    step toward the bearing wins, ties to +90°."""
    _enter(state, PHASE_WEAR)
    if bearing >= 0:
        old = int(state.get("anchor_heading", 0))
        state["anchor_heading"] = _wear_heading(old, bearing)


def _is_parallel(bearing: int, queue: int) -> bool:
    steps = bucket_distance(bearing, queue)
    return steps == 0 or steps == 4


def _formation_settled(state: dict[str, Any],
                       own: list[dict[str, Any]]) -> bool:
    """Every LIVING ship within station deviation ≤ 2 (Chebyshev, §4.9b
    form row)."""
    stations = _stations(state, own)
    for unit in own:
        station = stations.get(int(unit.get("index", -1)), _cell_of(unit))
        if _chebyshev(_cell_of(unit), station) > STATION_DEVIATION_MAX:
            return False
    return True


def _wear_complete(state: dict[str, Any], own: list[dict[str, Any]]) -> bool:
    """The wear lock: every LIVING ship's heading within ±1 bucket of the
    wear heading (the queue heading this phase installed)."""
    target = int(state.get("anchor_heading", 0)) % len(HEADING_RAYS)
    for unit in own:
        if bucket_distance(
                int(unit.get("heading8", 0)) % len(HEADING_RAYS),
                target) > WEAR_TOLERANCE_BUCKETS:
            return False
    return True


# --- Anchor & succession (docs/60-* §4.9b) -----------------------------------


def _update_anchor(state: dict[str, Any], own: list[dict[str, Any]]) -> None:
    """While the flagship lives the anchor is commander-driven (form/close/
    engage/wear bookkeeping below). §4.9b succession: when the flagship has
    sunk, the LOWEST living fleet index takes the anchor — its pos + heading8,
    re-read every round so a further loss hands the anchor on — and the state
    machine inherits unchanged (phase/phase_rounds/assignments untouched).
    """
    flagship_alive = any(int(unit.get("index", -1)) == 0 for unit in own)
    if flagship_alive and not bool(state.get("flagship_down", False)):
        return
    # `own` is fleet-index sorted, so [0] IS the lowest living index.
    holder = own[0]
    heading = int(holder.get("heading8", 0)) % len(HEADING_RAYS)
    holder_cell = _cell_of(holder)
    ray = HEADING_RAYS[heading]
    state["flagship_down"] = True
    state["anchor_pos"] = _wrap_in_grid((holder_cell[0] + ray[0],
                                         holder_cell[1] + ray[1]))
    state["anchor_heading"] = heading


# --- Formation geometry (docs/60-* §4.9b form row) ---------------------------


def _stations(state: dict[str, Any],
              own: list[dict[str, Any]]) -> dict[int, Cell]:
    """Stations: ship i at ``anchor − i × ray``, wrapped in-grid. line_ahead
    rays run along the RECIPROCAL of the queue heading (the line trails
    behind the anchor); column rays run along the perpendicular (lateral
    spacing)."""
    formation = str(state.get("formation", FORMATION_SWARM))
    anchor = to_cell(state.get("anchor_pos", (0, 0)))
    heading = int(state.get("anchor_heading", 0)) % len(HEADING_RAYS)
    ray = HEADING_RAYS[heading]
    if formation == FORMATION_COLUMN:
        ray = HEADING_RAYS[(heading + PERPENDICULAR_BUCKETS) % len(HEADING_RAYS)]
    out: dict[int, Cell] = {}
    for unit in own:
        index = int(unit.get("index", -1))
        out[index] = _wrap_in_grid((anchor[0] - ray[0] * index,
                                    anchor[1] - ray[1] * index))
    return out


def _wrap_in_grid(cell: Cell) -> Cell:
    """Longitude/latitude wrap into the battle grid (§4.9b "wrapped
    in-grid")."""
    return (cell[0] % GRID_WIDTH, cell[1] % GRID_HEIGHT)


def _clamp_in_grid(cell: Cell) -> Cell:
    """In-grid clamp (the close cruise stops at the map edge instead of
    wrapping)."""
    return (max(0, min(GRID_WIDTH - 1, cell[0])),
            max(0, min(GRID_HEIGHT - 1, cell[1])))


# --- Target assignment (docs/60-* §4.9b) -------------------------------------


def _assign_targets(profile: dict[str, Any], state: dict[str, Any],
                    own: list[dict[str, Any]],
                    enemies: list[dict[str, Any]]) -> dict[int, int]:
    """Round-robin over the enemy by the profile ``focus`` ordering, ships in
    fleet-index order; at ``aggression ≥ 80`` every ship gets the focus-top
    target (§4.9b focus fire). Returns ``{ai index: player index}``."""
    anchor = to_cell(state.get("anchor_pos", (0, 0)))
    ordered = _focus_ordered(profile, enemies, anchor)
    if not ordered:
        return {}
    focus_fire = int(profile.get("aggression", 0)) >= ai_fleet.FOCUS_FIRE_AGGRESSION
    out: dict[int, int] = {}
    slot = 0
    for unit in own:
        pick = ordered[0] if focus_fire else ordered[slot % len(ordered)]
        out[int(unit.get("index", -1))] = int(pick.get("index", -1))
        slot += 1
    return out


def _focus_ordered(profile: dict[str, Any], enemies: list[dict[str, Any]],
                   from_cell: Cell) -> list[dict[str, Any]]:
    """The §4.11.8 pin 2 focus ordering as a TOTAL order (every comparator
    carries the fleet-index tiebreak):
    ``weakest`` = lowest current durability; ``nearest`` = minimum Chebyshev
    from the anchor; ``flagship`` = player index 0 first with the weakest
    fallback."""
    arr = list(enemies)
    focus = str(profile.get("focus", "weakest"))
    if focus == "flagship":
        arr.sort(key=lambda unit: (
            0 if int(unit.get("index", -1)) == 0 else 1,
            int(unit.get("ship", {}).get("durability", 0)),
            int(unit.get("index", -1))))
    elif focus == "nearest":
        arr.sort(key=lambda unit: (
            _chebyshev(from_cell, _cell_of(unit)),
            int(unit.get("index", -1))))
    else:
        arr.sort(key=lambda unit: (
            int(unit.get("ship", {}).get("durability", 0)),
            int(unit.get("index", -1))))
    return arr


# --- Order emission (the §4.9b five-tuple + the phase rider) -----------------


def _order_for(unit: dict[str, Any], state: dict[str, Any], phase: str,
               stations: dict[int, Cell],
               assignments: dict[int, int]) -> dict[str, Any]:
    index = int(unit.get("index", -1))
    own_cell = _cell_of(unit)
    own_heading = int(unit.get("heading8", 0)) % len(HEADING_RAYS)
    order: dict[str, Any] = {
        "station": own_cell,
        "desired_heading8": own_heading,
        "desired_speed_band": [0, _hull_max_speed(unit)],
        "assigned_target": -1,
        "discipline": False,
        "phase": phase,
    }
    anchor_heading = int(state.get("anchor_heading", 0)) % len(HEADING_RAYS)
    if phase in (PHASE_FORM, PHASE_CLOSE):
        # Sail to the formation slot; the queue heading rides along (the
        # consumer holds headings only in engage/wear).
        order["station"] = stations.get(index, own_cell)
        order["desired_heading8"] = anchor_heading
    elif phase in (PHASE_ENGAGE, PHASE_WEAR):
        # Broadside-on: hold the queue heading, keep the line (discipline =
        # true — the §4.9b hard constraint), fire at the assigned target.
        order["station"] = stations.get(index, own_cell)
        order["desired_heading8"] = anchor_heading
        order["discipline"] = True
        order["assigned_target"] = int(assignments.get(index, -1))
    elif phase == PHASE_SCREEN:
        # Flagship-radius-3 screen: the station is the screen CENTER (the
        # anchor) — the consumer ranks candidates by the radius, never piling
        # onto the cell. Free fire, no discipline.
        order["station"] = _wrap_in_grid(
            to_cell(state.get("anchor_pos", (0, 0))))
    elif phase in (PHASE_SWARM, PHASE_BREAK):
        # Target assignment only — steering and heading free (break keeps
        # the last engage distribution).
        order["assigned_target"] = int(assignments.get(index, -1))
    return order


def _hull_max_speed(unit: dict[str, Any]) -> int:
    """The §4.9b close-row speed band "full (0..battle_max_speed)" — per
    hull, mirroring ``BattleSim.battle_max_speed``'s defaults from the W2
    data."""
    from server.sim.data import data
    ship: dict[str, Any] = unit.get("ship", {})
    ship_type = data().get_ship_type(str(ship.get("ship_type_id", "")))
    return max(1, int(ship_type.get("battle_max_speed", 2)))


# --- View / geometry helpers -------------------------------------------------


def _living_fleet(view: dict[str, Any]) -> list[dict[str, Any]]:
    """Living AI-side units, fleet-index order (fresh arrays — the view is
    never mutated, never sorted in place)."""
    return _living_side(view, SIDE_ENEMY)


def _living_enemies(view: dict[str, Any]) -> list[dict[str, Any]]:
    return _living_side(view, SIDE_PLAYER)


def _living_side(view: dict[str, Any], side: str) -> list[dict[str, Any]]:
    out = [unit for unit in view.get("units", [])
           if isinstance(unit, dict) and str(unit.get("side", "")) == side
           and bool(unit.get("alive", False))]
    out.sort(key=lambda unit: int(unit.get("index", -1)))
    return out


def _view_morale(view: dict[str, Any]) -> int:
    """The defensive W4-A morale thread: the CALLER copies
    ``sim.side_morale`` into the view when the seam exists (§4.9b bullet);
    absent or non-numeric ⇒ −1 = "no reading" ⇒ the pre-fleet-layer
    fallback (no morale break)."""
    reading = view.get("side_morale", None)
    if isinstance(reading, bool):
        return -1
    if isinstance(reading, (int, float)):
        return int(reading)
    return -1


def _nearest_enemy_cell(from_cell: Cell,
                        enemies: list[dict[str, Any]]) -> dict[str, Any]:
    """Nearest living enemy cell from ``from_cell``: minimum Chebyshev, ties
    to the lower fleet index (``enemies`` arrives index-sorted and only a
    strict win replaces the holder)."""
    best: dict[str, Any] = {}
    for unit in enemies:
        cell = _cell_of(unit)
        distance = _chebyshev(from_cell, cell)
        if not best or distance < int(best["distance"]):
            best = {"cell": cell, "distance": distance}
    return best


def _bearing_to(from_cell: Cell, nearest: dict[str, Any]) -> int:
    """The bearing bucket from ``from_cell`` toward the nearest enemy cell
    (−1 when there is none — callers guard). Degenerate same-cell reads
    resolve east via ``heading8_of``, deterministically."""
    if not nearest:
        return -1
    cell = to_cell(nearest["cell"])
    return heading8_of((cell[0] - from_cell[0], cell[1] - from_cell[1]))


def _perpendicular_toward(bearing: int, from_heading: int) -> int:
    clockwise = (bearing + PERPENDICULAR_BUCKETS) % len(HEADING_RAYS)
    counter = (bearing - PERPENDICULAR_BUCKETS) % len(HEADING_RAYS)
    if bucket_distance(from_heading, counter) < bucket_distance(
            from_heading, clockwise):
        return counter
    return clockwise


def _wear_heading(old: int, bearing: int) -> int:
    clockwise = (old + PERPENDICULAR_BUCKETS) % len(HEADING_RAYS)
    counter = (old - PERPENDICULAR_BUCKETS) % len(HEADING_RAYS)
    if bucket_distance(counter, bearing) < bucket_distance(clockwise, bearing):
        return counter
    return clockwise


def _chebyshev(a: Cell, b: Cell) -> int:
    """Delegated to the T2 module — one Chebyshev implementation in the
    combat AI (the reuse rule; never a second copy)."""
    return ai_fleet._chebyshev(a, b)


def _cell_of(unit: dict[str, Any]) -> Cell:
    return to_cell(unit.get("pos", unit.get("cell", NO_CELL)))
