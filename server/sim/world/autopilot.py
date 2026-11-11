"""server.sim.world.autopilot — the appointed-voyage engine (M1).

Python port of ``scripts/world/autopilot.gd`` (the frozen parity oracle until
the M6 cutover). Normative contract:

  * docs/20-WORLD-AND-SAILING.md §4.19 — the appointed voyage (委任航行): entry
    gate (pilot in post with navigation ≥ 40, destination ∈ ``known_ports``),
    the route-quality split (plain §4.2 shortest-water A* at 40–69, the
    wind/current-weighted A* at ≥ 70), the interrupt matrix (hostile contact
    auto-cancels with a notice; any manual input cancels; **storms never
    cancel** — auto-reef instead), arrival at the destination berth, and the
    save-v9 ``player.autopilot = {dest_port_id}`` shape (absent when none);
  * docs/80-UI-UX.md §4.10.4 — the HUD bar (``sail.autopilot.hud.bar`` with
    ``{port}`` / ``{days}``), the contact notice
    (``sail.autopilot.cancelled_contact``) and the cancel action;
  * docs/90-ARCHITECTURE.md §5.4 — the appointment lives as a plain
    ``GameState.player`` entry, never a new field.

State convention (the M1 port rule for autoload-coupled statics): the GDScript
statics read/mutated the ``GameState`` singleton and a set of ``static var``
runtime fields. Here:

  * the **persisted** appointment is ``st.player["autopilot"]`` — the v9
    person block owned by :class:`~server.sim.player.PersonState` (present
    only while a voyage is appointed, exactly the save shape);
  * the **runtime-only** route, its weighted flag/cost and the storm
    trim save live on an explicit :class:`AutopilotRuntime` the caller
    passes (one per run — never a module singleton; the route "recomputes
    on load", §4.19);
  * the world/day/known-port reads come through the injected ``run`` dict
    (keys mirror the ``GameState`` members verbatim: ``world`` (position /
    weather / sail_trim), ``known_ports``, ``fleet``) and the day from
    ``st.day`` — the same convention as ``server/sim/world/hail_options.py``;
  * the map/ocean are the decoded raster objects
    (:class:`~server.sim.world.raster.WorldRaster` /
    :class:`~server.sim.world.raster.OceanLayers`) — the ``DataLoader.map``
    and ``OceanLayers.instance()`` equivalents.

Sailing seam (``scripts/world/sailing_sim.gd`` is another M1 wave — NOT
imported here; the two state-dependent reads arrive injected as callables,
defaulting to the documented no-module behaviour):

  * ``effective_speed(heading) -> int`` — the §4.4 day-walk speed pipeline
    (weather × direction × current × trim × crew × seamanship × storm). Only
    the closed-form ETA (:func:`eta_days`) consumes it; with no sailing view
    the §4.4 floor ``MIN_SPEED`` (1 tile/day) stands in, so the ETA reads as
    the step count.
  * ``current_factor(heading, cell, month) -> float`` — the §4.16
    alignment-band factor of the reversal-applied current at ``cell`` (the
    one lookup, identity in drift mode). Only the weighted route cost
    consumes it; with no sailing view it is identity 1.0 (the §6.5
    "no information" fallback).

The pure compass/month closed forms (the §4.4 8-dir domain,
``heading_of_delta``/``angle_between_dirs``, the §4.4 ``DIRECTION_FACTORS``
table, the §4.15 ``month_for`` lattice) are locked doc tables carried here
verbatim and re-homed to the sailing module when it lands — the same
single-source note ``interactions.py`` uses for the sighting radius.

The weighted A* core (``scripts/world/fleet_path.gd``
``find_path_weighted``) is owned by no other M1 module yet, so the pure-move
core is ported here as :func:`_find_path_weighted` (the §4.19 "shared A*
core"); it will be re-homed when the ecology/fleet-path port lands.

RNG-free: the oracle file has no ``rand*`` call (verified at port time);
every rule below is a pure function of injected state.
"""

from __future__ import annotations

import heapq
import math
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from typing import Any, Final, Protocol

from server.sim.data import DataStore
from server.sim.fleet import fleet as fleet_lib
from server.sim.player import PersonState, skills
from server.sim.world import sail_path
from server.sim.world.raster import OceanLayers, WorldRaster
from server.sim.world.sail_path import WORLD_WIDTH

__all__ = [
    "GATE_FEATURE",
    "GATE_THRESHOLD_FALLBACK",
    "WEIGHTED_NAV_THRESHOLD",
    "PILOT_POST",
    "REASON_CONTACT",
    "REASON_MANUAL",
    "REASON_ARRIVED",
    "CANCEL_REASONS",
    "CANCELLED_CONTACT_KEY",
    "HUD_BAR_KEY",
    "HUD_CANCEL_KEY",
    "WEIGHTED_CORRIDOR_RADIUS",
    "MAX_EXPANSIONS_WEIGHTED",
    "HEURISTIC_WEIGHT",
    "MIN_STEP_FACTOR_BOUND",
    "COMPASS_DIRS",
    "COMPASS_DELTAS",
    "DIRECTION_FACTORS",
    "MONTH_DAYS",
    "YEAR_MONTHS",
    "DEFAULT_WEATHER",
    "DEFAULT_TRIM",
    "MIN_SPEED",
    "EffectiveSpeed",
    "CurrentFactor",
    "AutopilotRuntime",
    "gate",
    "gate_threshold",
    "reason_text",
    "pilot",
    "pilot_navigation",
    "appointed",
    "dest_port_id",
    "appoint",
    "cancel",
    "route",
    "eta_days",
    "route_cost_days",
    "route_wind_regions",
    "tick",
    "hud_state",
    "heading_of_delta",
    "angle_between_dirs",
    "month_for",
    "world_tile",
]

# --- The gate (docs/50-* §gates; the one skill_gates row) --------------------

#: The ``skill_gates`` row that owns the gate (pilot in post ∧ navigation ≥
#: threshold, destination ∈ known_ports; docs/50-* gates, docs/10-* §4.20).
GATE_FEATURE: Final[str] = "sail.autopilot"
#: Doc fallback when the data row is missing (docs/20-* §4.19 pins 40).
GATE_THRESHOLD_FALLBACK: Final[int] = 40
#: §4.19 route-quality split: the pilot navigation at which the weighted
#: cost replaces the plain shortest-water path (locked doc number).
WEIGHTED_NAV_THRESHOLD: Final[int] = 70
#: The pilot post that must be filled (docs/50-* §4.5.2 POST_SKILL).
PILOT_POST: Final[str] = "pilot"

#: The three locked cancel reasons (§4.19 interrupts + arrival).
REASON_CONTACT: Final[str] = "contact"
REASON_MANUAL: Final[str] = "manual"
REASON_ARRIVED: Final[str] = "arrived"
CANCEL_REASONS: Final[tuple[str, ...]] = (
    REASON_CONTACT, REASON_MANUAL, REASON_ARRIVED,
)

#: The §4.10.4 notice the world shows on a hostile-contact cancel.
CANCELLED_CONTACT_KEY: Final[str] = "sail.autopilot.cancelled_contact"
#: The §4.10.4 HUD bar / cancel action keys (the client renders the strings).
HUD_BAR_KEY: Final[str] = "sail.autopilot.hud.bar"
HUD_CANCEL_KEY: Final[str] = "sail.autopilot.cancel"

#: §4.19 route-quality split. The weighted search rides a CORRIDOR: the plain
#: §4.2 route seeds a band of this many tiles (Chebyshev) around itself and
#: the weighted A* optimizes within it (``autopilot.gd``
#: ``WEIGHTED_CORRIDOR_RADIUS``).
WEIGHTED_CORRIDOR_RADIUS: Final[int] = 32

# --- The weighted A* core (fleet_path.gd ``find_path_weighted``) ------------

#: Expansion guard of the §4.19 weighted search (a runaway guard, never a
#: code path; ``fleet_path.gd`` ``MAX_EXPANSIONS_WEIGHTED``).
MAX_EXPANSIONS_WEIGHTED: Final[int] = 200000
#: Bounded-suboptimality inflation of the weighted heuristic
#: (``fleet_path.gd`` ``HEURISTIC_WEIGHT``, Weighted A*: f = g + w·h).
HEURISTIC_WEIGHT: Final[float] = 2.0
#: §4.4 max propulsion factor bound used by the weighted heuristic:
#: best §4.14 direction factor (sail downwind 1.30) × best §4.16 current
#: factor (strength 3 aligned: 1 + 0.08 × 3 = 1.24, padded to 1.25).
MIN_STEP_FACTOR_BOUND: Final[float] = 1.30 * 1.25

# --- The §4.4 compass domain + §4.15 month lattice (locked doc tables) -------

#: §4.4/§4.16: the 8 compass ids every heading value lives in.
COMPASS_DIRS: Final[tuple[str, ...]] = (
    "N", "NE", "E", "SE", "S", "SW", "W", "NW",
)
#: Tile delta of each compass index (y grows southward: ``N`` is (0, −1)).
COMPASS_DELTAS: Final[tuple[tuple[int, int], ...]] = (
    (0, -1), (1, -1), (1, 0), (1, 1),
    (0, 1), (-1, 1), (-1, 0), (-1, -1),
)
#: §4.4 direction-factor table, ``[angle bucket][class]`` — locked in the
#: §5 "sailing_constants" JSON of docs/20 and ``sailing_sim.gd``.
DIRECTION_FACTORS: Final[dict[int, dict[str, float]]] = {
    0: {"sail": 0.50, "hybrid": 0.85, "oar": 1.00},
    45: {"sail": 0.70, "hybrid": 0.95, "oar": 1.00},
    90: {"sail": 1.00, "hybrid": 1.00, "oar": 1.00},
    135: {"sail": 1.15, "hybrid": 1.05, "oar": 1.00},
    180: {"sail": 1.30, "hybrid": 1.10, "oar": 1.00},
}
#: §4.15: a 360-day year of twelve 30-day months (day 1 is Month 1).
MONTH_DAYS: Final[int] = 30
YEAR_MONTHS: Final[int] = 12
#: §4.7 default weather before the first ledger roll (``sailing_sim.gd``
#: ``DEFAULT_WEATHER``).
DEFAULT_WEATHER: Final[str] = "calm"
#: §4.17 guard-read default of ``world.sail_trim`` (``sailing_sim.gd``).
DEFAULT_TRIM: Final[str] = "normal"
#: §4.4 "minimum 1 tile/day" — the ETA divisor floor (§6).
MIN_SPEED: Final[int] = 1

#: The 8-direction neighbourhood of the weighted core, verbatim from
#: ``fleet_path.gd`` ``NEIGHBOURS`` (the push order is part of the
#: deterministic contract).
_NEIGHBOURS: Final[tuple[tuple[int, int], ...]] = (
    (-1, 0), (1, 0), (0, -1), (0, 1),
    (-1, -1), (1, -1), (-1, 1), (1, 1),
)


# --- Sailing seam types ------------------------------------------------------

class EffectiveSpeed(Protocol):
    """``SailingSim.effective_speed(heading)`` — the §4.4 day-walk speed."""

    def __call__(self, heading: str = "") -> int: ...


class CurrentFactor(Protocol):
    """``SailingSim.current_factor(heading, cell, month)`` — the §4.16
    alignment-band factor (identity in drift mode)."""

    def __call__(self, heading: str, cell: tuple[int, int],
                 month: int) -> float: ...


# --- Runtime-only route state (never saved; recomputes on load) -------------

@dataclass
class AutopilotRuntime:
    """The GDScript ``static var`` block of ``autopilot.gd``, made explicit.

    One instance per run (the server keeps it next to ``PersonState``); the
    fields are never persisted — a load recomputes the route from the live
    month/wind data and the storm trim save starts empty.
    """

    #: Unit steps **after** the fleet's current tile, ending on the
    #: destination's berth tile (§4.19).
    route: list[tuple[int, int]] = field(default_factory=list)
    #: True when the stored route came from the weighted search (nav ≥ 70).
    route_weighted: bool = False
    #: The §4.19 model cost of the stored route in days
    #: (Σ step_multiplier / base_speed; the suite's weighted-vs-plain metric).
    route_cost_days: float = 0.0
    #: The player's trim before a storm auto-reef took it to ``reefed``
    #: (§4.19; restored on the first non-storm tick — runtime-only).
    pre_storm_trim: str = ""

    def drop_route(self) -> None:
        """Clears the stored route + its weighted flag/cost."""
        self.route = []
        self.route_weighted = False
        self.route_cost_days = 0.0


# --- Gate (docs/50-* §gates; the one skill_gates row) ------------------------

def gate(store: DataStore, st: PersonState, run: dict[str, Any],
         dest_port_id: str = "") -> dict[str, Any]:
    """The gate verdict for appointing toward ``dest_port_id``.

    Returns ``{ok, reason_key, threshold, pilot_nav, dest_known}``:

      * ``reason_key`` is the ``skill_gates`` **feature_id**
        (``sail.autopilot``) when the pilot/nav half fails — the reason TEXT
        lives in that row's ``reason.{zh,en}`` and resolves through
        :func:`reason_text` at render time (never composed here, the i18n
        rule);
      * ``dest_known`` is False when ``dest_port_id`` was given and is
        outside ``run["known_ports"]`` (§4.19). An unknown destination has no
        ``skill_gates`` reason row, so ``reason_key`` stays "" and the caller
        just renders the action disabled.
    """
    threshold = gate_threshold(store)
    pilot_id = pilot(st)
    pilot_nav = pilot_navigation(store, st, pilot_id)
    dest_known = True
    if dest_port_id:
        dest_known = dest_port_id in list(run.get("known_ports", []))
    ok = bool(pilot_id) and pilot_nav >= threshold and dest_known
    return {
        "ok": ok,
        "reason_key": (GATE_FEATURE
                       if (not pilot_id or pilot_nav < threshold) else ""),
        "threshold": threshold,
        "pilot_nav": pilot_nav,
        "dest_known": dest_known,
    }


def gate_threshold(store: DataStore) -> int:
    """The ``sail.autopilot`` threshold from ``data/skill_gates.json``, with
    the doc fallback when the row or the threshold is missing/invalid."""
    row = store.get_skill_gate(GATE_FEATURE)
    threshold = int(row.get("threshold", 0))
    return threshold if threshold > 0 else GATE_THRESHOLD_FALLBACK


def reason_text(store: DataStore, result: dict[str, Any]) -> dict[str, Any]:
    """The reason L10nString for a :func:`gate` result: the gate row's
    ``reason`` (``{"zh": …, "en": …}``; ``{}`` when ok / nothing failed).

    The GDScript returned ``I18n.t(row.reason)`` (a rendered String); the web
    era keeps the structured L10nString so the client resolves the locale —
    the single render path every gated surface reads.
    """
    if bool(result.get("ok", False)):
        return {}
    key = str(result.get("reason_key", ""))
    if not key:
        return {}
    row = store.get_skill_gate(key)
    if not row:
        return {}
    return dict(row.get("reason", {}) or {})


def pilot(st: PersonState) -> str:
    """The id of the pilot officer in post ("" when the post is vacant)."""
    return skills.post_holder(st, PILOT_POST)


def pilot_navigation(store: DataStore, st: PersonState,
                     pilot_id: str = "") -> int:
    """The pilot's own navigation (the §4.19 "that pilot's navigation").

    The officer card's trained value, 0 when the post is vacant or the card is
    gone. The player's own navigation does NOT count — the gate is the
    officer's (the §4.5.3 contribution feeds the player's *effective* skill
    for night sailing, not this gate).
    """
    oid = pilot_id if pilot_id else pilot(st)
    if not oid:
        return 0
    officer = store.get_officer(oid)
    if not officer:
        return 0
    return int(officer.get("skills", {}).get("navigation", 0))


# --- Appoint / cancel (§4.19 entry + interrupts) -----------------------------

def appointed(st: PersonState) -> bool:
    """True while an appointment stands (``player.autopilot`` present)."""
    entry = st.player.get("autopilot")
    if not isinstance(entry, dict):
        return False
    return bool(str(entry.get("dest_port_id", "")))


def dest_port_id(st: PersonState) -> str:
    """The appointed destination port id ("" when not appointed)."""
    entry = st.player.get("autopilot")
    if not isinstance(entry, dict):
        return ""
    return str(entry.get("dest_port_id", ""))


def appoint(store: DataStore, st: PersonState, run: dict[str, Any],
            raster: WorldRaster, ocean: OceanLayers | None,
            rt: AutopilotRuntime, dest: str, *,
            effective_speed: EffectiveSpeed | None = None,
            current_factor: CurrentFactor | None = None) -> dict[str, Any]:
    """Appoints the fleet to ``dest``: gate → store the save-v9 key → compute
    + store the route (runtime).

    Returns ``{ok, route, eta_days, cost_days, weighted}`` on success, or
    ``{ok: False, reason_key, threshold, dest_known}`` (gate failed) /
    ``{ok: False, no_route: True, …}`` (no map, no berth or no sea route —
    the key is NOT stored). No gold fee (§4.19): officer wages are the cost.
    """
    verdict = gate(store, st, run, dest)
    if not bool(verdict.get("ok", False)):
        return verdict
    if not _compute_route(store, st, run, raster, ocean, rt, dest,
                          current_factor):
        out = dict(verdict)
        out["ok"] = False
        out["no_route"] = True
        return out
    st.player["autopilot"] = {"dest_port_id": dest}
    steps = route(store, st, run, raster, ocean, rt,
                  effective_speed=effective_speed,
                  current_factor=current_factor)
    width = int(raster.width) if raster is not None else WORLD_WIDTH
    return {
        "ok": True,
        "route": steps,
        "eta_days": eta_days(steps, world_tile(run),
                             effective_speed=effective_speed, width=width),
        "cost_days": rt.route_cost_days,
        "weighted": rt.route_weighted,
    }


def cancel(st: PersonState, run: dict[str, Any], rt: AutopilotRuntime,
           reason: str) -> bool:
    """Cancels the appointment.

    ``reason`` is one of :data:`CANCEL_REASONS`: the contact funnel calls
    ``cancel("contact")`` (+ the :data:`CANCELLED_CONTACT_KEY` notice, the
    world's toast), any manual move input calls ``cancel("manual")``, the dock
    sequence calls ``cancel("arrived")``. Returns False (and does nothing) for
    an unknown reason or when nothing is appointed — the world seam gates its
    notice on the ``True`` return.
    """
    if reason not in CANCEL_REASONS:
        return False
    if not appointed(st):
        return False
    st.player.pop("autopilot", None)
    rt.drop_route()
    _restore_storm_trim(run, rt)
    return True


# --- Route access + the closed-form ETA --------------------------------------

def route(store: DataStore, st: PersonState, run: dict[str, Any],
          raster: WorldRaster, ocean: OceanLayers | None,
          rt: AutopilotRuntime, *,
          effective_speed: EffectiveSpeed | None = None,
          current_factor: CurrentFactor | None = None
          ) -> list[tuple[int, int]]:
    """The stored route (unit steps after the fleet's tile, ending on the
    berth), as a fresh list.

    Recomputes on demand when empty — the load seam (the save carries only
    ``dest_port_id``; the first call after a load rebuilds the route from the
    live month/wind data, exactly the "recomputes on load" rule). Returns []
    when not appointed or no sea route exists.
    """
    if not appointed(st):
        return []
    if not rt.route:
        _compute_route(store, st, run, raster, ocean, rt, dest_port_id(st),
                       current_factor)
    return list(rt.route)


def eta_days(steps: Sequence[tuple[int, int]],
             from_cell: tuple[int, int], *,
             effective_speed: EffectiveSpeed | None = None,
             width: int = WORLD_WIDTH) -> float:
    """The closed-form ETA of ``steps`` in days: Σ per-leg ``1 /
    effective_speed`` (§4.2 ``move_cost``) over the walk headings.

    The first leg is measured from ``from_cell`` — the caller passes the route
    it got from :func:`appoint`/:func:`route` while standing where it stands.
    The §4.4 floor keeps the divisor ≥ 1 (a furled fleet "arrives" at 1
    tile/day rather than dividing by zero; the world never walks a furled
    fleet). With no sailing view the floor stands in for every leg.
    """
    total = 0.0
    prev = from_cell
    for step in steps:
        heading = _heading_between(prev, step, width)
        speed = int(effective_speed(heading)) if effective_speed is not None \
            else MIN_SPEED
        total += 1.0 / float(max(speed, MIN_SPEED))
        prev = step
    return total


def route_cost_days(st: PersonState, run: dict[str, Any],
                    steps: Sequence[tuple[int, int]],
                    from_cell: tuple[int, int], ocean: OceanLayers | None,
                    store: DataStore, *,
                    current_factor: CurrentFactor | None = None,
                    width: int = WORLD_WIDTH) -> float:
    """The §4.19 model cost of a walk in days — the metric the suite compares
    the weighted route against the plain one with: Σ ``step_multiplier /
    base_speed`` where ``step_multiplier = 1 / (wind_f × current_f)`` is the
    SAME function the weighted A* minimizes.

    This is the month-model cost (prevailing wind + reversal-applied
    currents), not the day-walk's weather-jittered cost.
    """
    month = _month(st)
    ship_class = _ship_class(store, run)
    base = float(max(fleet_lib.slowest_speed(list(run.get("fleet", []))),
                     MIN_SPEED))
    total = 0.0
    prev = from_cell
    for step in steps:
        heading = _heading_between(prev, step, width)
        total += _step_multiplier(heading, step, month, ship_class, ocean,
                                  current_factor) / base
        prev = step
    return total


def route_wind_regions(ocean: OceanLayers,
                       steps: Sequence[tuple[int, int]]) -> list[int]:
    """The set of wind-region ids a walk crosses (sorted ascending); ``0``
    entries (unassigned water) included as-is — the suite's second
    weighted-vs-plain discriminator."""
    seen: set[int] = set()
    for step in steps:
        seen.add(int(ocean.wind_region_at(step[0], step[1])))
    return sorted(seen)


# --- Tick (the world movement tick calls this) -------------------------------

def tick(store: DataStore, st: PersonState, run: dict[str, Any],
         raster: WorldRaster, ocean: OceanLayers | None,
         rt: AutopilotRuntime, *,
         effective_speed: EffectiveSpeed | None = None,
         current_factor: CurrentFactor | None = None) -> dict[str, Any]:
    """One movement tick of the appointed voyage.

    Returns ``{appointed, dest, arrived, route}``:

      * not appointed → ``{appointed: False}`` (a no-op; free to call always);
      * fleet on the destination's berth → ``arrived: True`` — the world's
        dock seam docks through the normal port-entry sequence and calls
        :func:`cancel` with :data:`REASON_ARRIVED` (§4.19 "the appointment
        clears");
      * otherwise ``route`` carries the steps to walk THIS tick; a next step
        the month has made impassable (seasonal ice froze under the route,
        §4.18) recomputes the route once here, so the walk never hits a
        frozen tile.

    Storms do NOT cancel (§4.19): on a storm day the appointment stands and
    the fleet AUTO-REEFS to ``reefed`` for that day — :func:`_storm_trim_tick`
    saves the player's previous trim, forces ``reefed``, and restores it on
    the first non-storm tick (a trim the player changed meanwhile is left
    alone). The §4.7 storm effects apply through the normal ledger, untouched
    here. Nothing in this function reads the contact state: hostile contact
    cancels through the world's contact funnel (:func:`cancel` with
    :data:`REASON_CONTACT`), before the battle opens.
    """
    if not appointed(st):
        return {"appointed": False}
    _storm_trim_tick(run, rt)
    dest = dest_port_id(st)
    berth = _berth_of(raster, dest)
    at = world_tile(run)
    if berth[0] >= 0 and at == berth:
        return {"appointed": True, "dest": dest, "arrived": True,
                "route": []}
    steps = route(store, st, run, raster, ocean, rt,
                  effective_speed=effective_speed,
                  current_factor=current_factor)
    if steps and _step_blocked_now(steps[0], raster, ocean, _month(st)):
        rt.drop_route()
        steps = route(store, st, run, raster, ocean, rt,
                      effective_speed=effective_speed,
                      current_factor=current_factor)
    return {"appointed": True, "dest": dest, "arrived": False,
            "route": steps}


# --- HUD state (docs/80-* §4.10.4) -------------------------------------------

def hud_state(store: DataStore, st: PersonState, run: dict[str, Any],
              raster: WorldRaster, ocean: OceanLayers | None,
              rt: AutopilotRuntime, *,
              effective_speed: EffectiveSpeed | None = None,
              current_factor: CurrentFactor | None = None) -> dict[str, Any]:
    """The appointed-voyage HUD bar payload (structured, i18n-key descriptors
    — never composed strings).

    ``{visible: False}`` when nothing is appointed; otherwise
    ``{visible, dest_port_id, bar_key, values: {port: <port name L10nString>,
    days: int}, cancel_key, eta_days}`` — the client formats
    ``sail.autopilot.hud.bar`` with the resolved port name and the ceiling of
    the closed-form ETA (the GDScript HUD's ``ceili(eta_days(route()))``).
    """
    if not appointed(st):
        return {"visible": False}
    dest = dest_port_id(st)
    steps = route(store, st, run, raster, ocean, rt,
                  effective_speed=effective_speed,
                  current_factor=current_factor)
    width = int(raster.width) if raster is not None else WORLD_WIDTH
    eta = eta_days(steps, world_tile(run), effective_speed=effective_speed,
                   width=width)
    port = store.get_port(dest)
    return {
        "visible": True,
        "dest_port_id": dest,
        "bar_key": HUD_BAR_KEY,
        "values": {
            "port": dict(port.get("name", {}) or {}),
            "days": int(math.ceil(eta)),
        },
        "cancel_key": HUD_CANCEL_KEY,
        "eta_days": eta,
    }


# --- Route computation -------------------------------------------------------

def _compute_route(store: DataStore, st: PersonState, run: dict[str, Any],
                   raster: WorldRaster, ocean: OceanLayers | None,
                   rt: AutopilotRuntime, dest: str,
                   current_factor: CurrentFactor | None) -> bool:
    """Builds + stores the route for ``dest`` per the pilot's navigation
    (§4.19 route-quality split). False when the map/port/sea route fails
    (the caller refuses the appointment; nothing is stored)."""
    rt.drop_route()
    if raster is None or int(raster.width) <= 0 or int(raster.height) <= 0:
        return False
    width = int(raster.width)
    height = int(raster.height)
    berth = _berth_of(raster, dest)
    if berth[0] < 0:
        return False
    from_cell = world_tile(run)
    month = _month(st)

    def passable(cell: tuple[int, int]) -> bool:
        # The weighted walk domain: the map's passability AND the month's
        # seasonal ice (§4.18 — the weighted route must avoid it; the start
        # cell is never entered, so a fleet frozen in can still sail out).
        x, y = cell
        if not raster.is_passable(x, y):
            return False
        return not (ocean is not None and ocean.ice_blocks(x, y, month))

    if from_cell == berth:
        # Standing on the destination berth already: the appointment is legal
        # and arrives on the next tick (empty route).
        return True
    steps: list[tuple[int, int]] = []
    if pilot_navigation(store, st) >= WEIGHTED_NAV_THRESHOLD:
        # §4.19 weighted A* over the shared core, corridor-constrained: the
        # fast plain §4.2 route seeds the band, the weighted cost picks the
        # cheap days inside it.
        seed = sail_path.find_path(raster.is_passable, width, height,
                                   from_cell, berth)
        if not seed:
            return False
        corridor = _corridor_mask(from_cell, seed, WEIGHTED_CORRIDOR_RADIUS,
                                  width, height)
        data: bytearray = corridor["data"]
        y0: int = corridor["y0"]
        rows: int = corridor["rows"]

        def in_corridor(cell: tuple[int, int]) -> bool:
            if cell[1] < y0 or cell[1] >= y0 + rows:
                return False
            return data[(cell[1] - y0) * width + (cell[0] % width)] == 1

        def corridor_passable(cell: tuple[int, int]) -> bool:
            return passable(cell) and in_corridor(cell)

        cost_fn = _make_cost_fn(month, width, _ship_class(store, run), ocean,
                                current_factor)
        raw = _find_path_weighted(from_cell, berth, width, height,
                                  corridor_passable, cost_fn)
        if not raw:
            # Graceful degradation (the risk-table fallback spirit): the
            # appointment still works on the distance-optimal route.
            steps = list(seed)
            rt.route_weighted = False
        else:
            steps = list(raw[1:])
            rt.route_weighted = True
    else:
        # 40–69: the plain §4.2 wind-blind shortest-water A*, verbatim.
        steps = sail_path.find_path(raster.is_passable, width, height,
                                    from_cell, berth)
        rt.route_weighted = False
    if not steps:
        return False
    rt.route = steps
    rt.route_cost_days = route_cost_days(st, run, steps, from_cell, ocean,
                                         store, current_factor=current_factor,
                                         width=width)
    return True


def _corridor_mask(from_cell: tuple[int, int],
                   seed: Sequence[tuple[int, int]], radius: int,
                   width: int, height: int) -> dict[str, Any]:
    """The corridor band around ``seed`` (plus the start cell): a row-bounded
    bytearray mask, ``{data, y0, rows, width}`` — ``data[(y − y0) × width +
    x % width] == 1`` inside ``radius`` (Chebyshev) of any seed cell.

    Built as per-row x-intervals (wrap-split), merged, then stamped once — no
    per-cell square walk (``autopilot.gd`` ``_corridor_mask``).
    """
    y_lo = _clamp(from_cell[1] - radius, 0, height - 1)
    y_hi = _clamp(from_cell[1] + radius, 0, height - 1)
    for step in seed:
        y_lo = min(y_lo, max(step[1] - radius, 0))
        y_hi = max(y_hi, min(step[1] + radius, height - 1))
    rows = y_hi - y_lo + 1
    data = bytearray(rows * width)
    by_row: dict[int, list[list[int]]] = {}
    cells: list[tuple[int, int]] = [from_cell, *seed]
    for cell in cells:
        for dy in range(-radius, radius + 1):
            row = cell[1] + dy
            if row < y_lo or row > y_hi:
                continue
            pieces = _wrap_interval(cell[0] - radius, cell[0] + radius, width)
            by_row.setdefault(row - y_lo, []).extend(pieces)
    for row_key, intervals in by_row.items():
        merged = _merge_intervals(intervals)
        stamp_row = row_key * width
        for x0, x1 in merged:
            for x in range(x0, x1 + 1):
                data[stamp_row + x] = 1
    return {"data": data, "y0": y_lo, "rows": rows, "width": width}


def _wrap_interval(lo: int, hi: int, width: int) -> list[list[int]]:
    """``[lo, hi]`` → non-overlapping pieces inside ``[0, width)`` (the x-wrap:
    a band that crosses the seam lands in both end pieces)."""
    length = hi - lo + 1
    if length <= 0:
        return []
    if length >= width:
        return [[0, width - 1]]
    start = lo % width
    out: list[list[int]] = []
    first_end = min(width - 1, start + length - 1)
    out.append([start, first_end])
    remaining = length - (first_end - start + 1)
    if remaining > 0:
        out.append([0, remaining - 1])
    return out


def _merge_intervals(intervals: Sequence[Sequence[int]]) -> list[list[int]]:
    """Sorts ``[x0, x1]`` pairs by start and merges the overlaps/touches."""
    if not intervals:
        return []
    ordered = sorted(([int(pair[0]), int(pair[1])] for pair in intervals),
                     key=lambda pair: (pair[0], pair[1]))
    out: list[list[int]] = [ordered[0]]
    for x0, x1 in ordered[1:]:
        last = out[-1]
        if x0 <= last[1] + 1:
            last[1] = max(last[1], x1)
        else:
            out.append([x0, x1])
    return out


def _step_multiplier(heading: str, cell: tuple[int, int], month: int,
                     ship_class: str, ocean: OceanLayers | None,
                     current_factor: CurrentFactor | None) -> float:
    """The §4.19 step-cost multiplier the weighted A* minimizes:
    ``1 / (wind_f × current_f)``.

    ``wind_f`` is the §4.14 month-prevailing-wind heading factor for the
    step's heading at the step's DESTINATION tile (``VAR`` / unknown → neutral
    1.0); ``current_f`` is the §4.16 factor (injected; identity without a
    sailing view). A step sailing INTO the prevailing wind (angle 0) costs up
    to ×2 the downwind step.
    """
    factor = (_wind_heading_factor(heading, cell, month, ship_class, ocean)
              * _current_factor(heading, cell, month, current_factor))
    return 1.0 / max(factor, 0.01)


def _wind_heading_factor(heading: str, cell: tuple[int, int], month: int,
                         ship_class: str,
                         ocean: OceanLayers | None) -> float:
    """The month-prevailing-wind heading factor (§4.14 → §4.4 table)."""
    if not heading or ocean is None:
        return 1.0
    token = ocean.prevailing_for(cell[0], cell[1], month)
    if not token or token == "VAR":
        return 1.0
    angle = angle_between_dirs(heading, token)
    if angle < 0:
        return 1.0
    return float(DIRECTION_FACTORS.get(angle, {}).get(ship_class, 1.0))


def _current_factor(heading: str, cell: tuple[int, int], month: int,
                    current_factor: CurrentFactor | None) -> float:
    """The §4.16 current factor through the injected sailing seam (identity
    without one — the §6.5 "no information" fallback)."""
    if current_factor is None:
        return 1.0
    return float(current_factor(heading, cell, month))


def _make_cost_fn(month: int, width: int, ship_class: str,
                  ocean: OceanLayers | None,
                  current_factor: CurrentFactor | None
                  ) -> Callable[[tuple[int, int], tuple[int, int]], float]:
    """The cost_fn handed to :func:`_find_path_weighted`: per-step multiplier
    derived from the step heading (wrapped delta) and the step's destination
    tile."""
    def cost(a: tuple[int, int], b: tuple[int, int]) -> float:
        dx = b[0] - a[0]
        if dx > 1:
            dx -= width
        elif dx < -1:
            dx += width
        heading = heading_of_delta((dx, b[1] - a[1]))
        return _step_multiplier(heading, b, month, ship_class, ocean,
                                current_factor)

    return cost


# --- The weighted A* core (fleet_path.gd ``find_path_weighted``) ------------

def _find_path_weighted(from_cell: tuple[int, int],
                        to_cell: tuple[int, int], width: int, height: int,
                        passable: Callable[[tuple[int, int]], bool],
                        cost_fn: Callable[[tuple[int, int], tuple[int, int]],
                                          float],
                        *,
                        min_step_cost: float =
                        1.0 / MIN_STEP_FACTOR_BOUND,
                        h_weight: float = HEURISTIC_WEIGHT,
                        max_expansions: int = MAX_EXPANSIONS_WEIGHTED
                        ) -> list[tuple[int, int]]:
    """The §4.19 wind/current-weighted A* — the shared walk domain.

    Same 8-direction, x-wrapping, no-corner-cutting domain as
    ``sail_path.find_path`` but each step costs ``cost_fn(from, to)`` (float,
    > 0) instead of 1.0, so a route can trade distance for cheaper sailing
    days. ``passable``/``cost_fn`` receive WRAPPED ``(x, y)`` tuples.

    Returns ``[from, …, to]`` (empty when none: unreachable goal, guard
    overflow, impassable endpoint). Float g/f scores compare exactly (no
    rounding), and the heap is ordered by the same deterministic ``(f, then
    key)`` tuple as ``fleet_path.gd`` — keys are unique per cell, so equal-f
    ties resolve identically on every run. The heuristic is Weighted-A*
    inflated by ``h_weight`` (bounded suboptimality, §4.19 not strict
    optimality).
    """
    if width <= 0 or height <= 0:
        return []
    if from_cell == to_cell:
        return [from_cell]
    if to_cell[1] < 0 or to_cell[1] >= height:
        return []
    to_wrapped = (to_cell[0] % width, to_cell[1])
    if not passable(to_wrapped):
        return []
    from_wrapped = (from_cell[0] % width, from_cell[1])
    start_key = _key(from_wrapped, width)
    gscore: dict[int, float] = {start_key: 0.0}
    came: dict[int, int] = {}
    open_heap: list[tuple[float, int]] = [
        (_h_float(from_wrapped, to_wrapped, width) * min_step_cost * h_weight,
         start_key)
    ]
    closed: set[int] = set()
    expansions = 0
    while open_heap:
        _f, current_key = heapq.heappop(open_heap)
        if current_key in closed:
            continue
        closed.add(current_key)
        current = _cell(current_key, width)
        expansions += 1
        if expansions > max_expansions:
            return []
        if current == to_wrapped:
            return _rebuild(came, current_key, width)
        g_current = gscore[current_key]
        for step_x, step_y in _NEIGHBOURS:
            nxt = ((current[0] + step_x) % width, current[1] + step_y)
            if nxt[1] < 0 or nxt[1] >= height:
                continue
            if not passable(nxt):
                continue
            if step_x != 0 and step_y != 0:
                # No corner cutting (the shared walk rule).
                if not passable(((current[0] + step_x) % width, current[1])):
                    continue
                if not passable((current[0], current[1] + step_y)):
                    continue
            next_key = _key(nxt, width)
            if next_key in closed:
                continue
            tentative = g_current + float(cost_fn(current, nxt))
            known = gscore.get(next_key)
            if known is not None and known <= tentative:
                continue
            gscore[next_key] = tentative
            came[next_key] = current_key
            heapq.heappush(open_heap, (
                tentative
                + _h_float(nxt, to_wrapped, width) * min_step_cost * h_weight,
                next_key))
    return []


def _h_float(a: tuple[int, int], b: tuple[int, int], width: int) -> float:
    """Wrapped Chebyshev distance as a float (the heuristic domain)."""
    dx = abs(a[0] - b[0]) % width
    return float(max(min(dx, width - dx), abs(a[1] - b[1])))


def _key(cell: tuple[int, int], width: int) -> int:
    return int(cell[1]) * width + int(cell[0] % width)


def _cell(key: int, width: int) -> tuple[int, int]:
    return (key % width, key // width)


def _rebuild(came: dict[int, int], end_key: int,
             width: int) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    key = end_key
    while True:
        out.append(_cell(key, width))
        parent = came.get(key)
        if parent is None:
            break
        key = parent
    out.reverse()
    return out


# --- Storm auto-reef (§4.19; storms never cancel) ----------------------------

def _storm_trim_tick(run: dict[str, Any], rt: AutopilotRuntime) -> None:
    """The §4.19 storm rule, scoped to the appointment: on a storm day the
    trim becomes ``reefed`` (storm damage ×0.75, the §4.17 table), the
    player's previous trim is kept in :attr:`AutopilotRuntime.pre_storm_trim`
    and restored on the first non-storm tick — but only if the trim still
    reads ``reefed`` (a trim the player cycled meanwhile stays theirs). A
    fleet already at ``reefed`` needs no save/restore. The oar class ignores
    trim entirely (§4.17), so reefing a galley fleet is a harmless no-op.
    """
    world = run.setdefault("world", {})
    weather = str(world.get("weather", DEFAULT_WEATHER))
    if weather == "storm":
        if not rt.pre_storm_trim and _sail_trim(run) != "reefed":
            rt.pre_storm_trim = _sail_trim(run)
            world["sail_trim"] = "reefed"
        return
    if rt.pre_storm_trim:
        if _sail_trim(run) == "reefed":
            world["sail_trim"] = rt.pre_storm_trim
        rt.pre_storm_trim = ""


def _restore_storm_trim(run: dict[str, Any], rt: AutopilotRuntime) -> None:
    if not rt.pre_storm_trim:
        return
    if _sail_trim(run) == "reefed":
        run.setdefault("world", {})["sail_trim"] = rt.pre_storm_trim
    rt.pre_storm_trim = ""


def _sail_trim(run: dict[str, Any]) -> str:
    """``world.sail_trim`` with the §4.17 pinned default."""
    return str(run.get("world", {}).get("sail_trim", DEFAULT_TRIM))


# --- Small reads -------------------------------------------------------------

def _berth_of(raster: WorldRaster | None,
              dest_port_id: str) -> tuple[int, int]:
    """The destination port's berth tile (the harbors table), or
    ``(-1, -1)`` without a map."""
    if raster is None or not hasattr(raster, "port_cell"):
        return (-1, -1)
    cell = raster.port_cell(dest_port_id)
    return (int(cell[0]), int(cell[1]))


def _step_blocked_now(cell: tuple[int, int], raster: WorldRaster | None,
                      ocean: OceanLayers | None, month: int) -> bool:
    """True when ``cell`` cannot be ENTERED right now (map passability or the
    month's seasonal ice) — the tick's blocked-route recompute probe."""
    if raster is None or not raster.is_passable(cell[0], cell[1]):
        return True
    return bool(ocean is not None and ocean.ice_blocks(cell[0], cell[1],
                                                      month))


def _heading_between(from_cell: tuple[int, int], to_cell: tuple[int, int],
                     width: int = WORLD_WIDTH) -> str:
    """The wrap-aware 8-dir id of a one-tile step (the §4.4 heading domain)."""
    dx = (to_cell[0] - from_cell[0]) % width
    if dx > width / 2:
        dx -= width
    return heading_of_delta((dx, to_cell[1] - from_cell[1]))


def _ship_class(store: DataStore, run: dict[str, Any]) -> str:
    """The flagship's propulsion class (``sail``/``oar``/``hybrid``),
    guard-read to ``sail`` without a fleet or hull (the §4.4 wind table)."""
    ship = fleet_lib.flagship(list(run.get("fleet", [])))
    if not ship:
        return "sail"
    ship_type = store.get_ship_type(str(ship.get("ship_type_id", "")))
    cls = str(ship_type.get("class", ""))
    return cls if cls else "sail"


def world_tile(run: dict[str, Any]) -> tuple[int, int]:
    """The fleet's world tile from ``run["world"]["position"]`` (the
    ``GameState.world_tile()`` read; ``(0, 0)`` without a position)."""
    pos = run.get("world", {}).get("position")
    if isinstance(pos, dict):
        return (int(pos.get("x", 0)), int(pos.get("y", 0)))
    if isinstance(pos, (tuple, list)) and len(pos) >= 2:
        return (int(pos[0]), int(pos[1]))
    return (0, 0)


def heading_of_delta(delta: tuple[int, int]) -> str:
    """The 8-dir id of a one-tile move delta, or "" when the delta is not an
    8-direction step (zero, or longer than one tile)."""
    try:
        index = COMPASS_DELTAS.index((int(delta[0]), int(delta[1])))
    except ValueError:
        return ""
    return COMPASS_DIRS[index] if index >= 0 else ""


def angle_between_dirs(a: str, b: str) -> int:
    """Angle between two 8-dir ids in degrees, bucketed to the 8-compass grid
    — always exactly one of 0 / 45 / 90 / 135 / 180. Unknown ids return −1."""
    try:
        ia = COMPASS_DIRS.index(a)
        ib = COMPASS_DIRS.index(b)
    except ValueError:
        return -1
    diff = abs(ia - ib) % 8
    return min(diff, 8 - diff) * 45


def month_for(day: int) -> int:
    """§4.15: ``floor(((day − 1) mod 360) / 30) + 1`` — the 12-month lattice
    anchored at day 1 (``posmod`` so day ≤ 0 fixtures stay in band)."""
    return int(math.floor(((day - 1) % (MONTH_DAYS * YEAR_MONTHS))
                          / float(MONTH_DAYS))) + 1


def _month(st: PersonState) -> int:
    """The §4.19 month of the run: ``month_for(max(day, 1))`` (the oracle's
    ``_month()`` clamp)."""
    return month_for(max(int(st.day), 1))


def _clamp(value: int, lo: int, hi: int) -> int:
    return max(lo, min(value, hi))
