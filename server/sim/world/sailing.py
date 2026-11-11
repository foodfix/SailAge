"""server.sim.world.sailing — the sailing simulation core (M1).

Python port of ``scripts/world/sailing_sim.gd`` (the frozen parity oracle
until the M6 cutover) plus the sim-relevant movement/docking half of
``scenes/world/world_map.gd`` (``try_step`` / ``_dock_at`` / ``_enter_port`` /
the §4.2 cadence) and ``scenes/port/port_screen.gd``'s ``set_sail`` (the
§4.11.2 exit gate). Those scene files' render/camera/marker/contact halves
stay scene-side in the web era; the rules they carried live here.

Normative contract:
  * docs/20-WORLD-AND-SAILING.md §4.1–§4.19 — the grid, the two input modes,
    the continuous clock and its §4.3 day-tick order, §4.4 the speed
    pipeline, §4.5 the daily ledger ORDER (consumption before wages before
    morale, the two-part weather roll strength → direction), §4.7/§4.7.1
    weather + wind direction, §4.8 morale/mutiny/desertion, §4.9 fail
    states, §4.10 supplies, §4.11 port discovery/entry/exit, §4.12 explored
    set, §4.14–§4.18 prevailing winds / calendar / currents / trim / ice,
    §4.19 appointed voyage (seam — see below);
  * docs/40-SHIPS-AND-FLEET.md §4.4 (the slowest-hull scan with the
    captain-less ×0.8 rule, sinking relocation) / §4.5 (at-sea minor
    repair);
  * docs/90-ARCHITECTURE.md §5.4 (day-tick listener order: ledger → economy
    drift → month boundary → drift push → ``day_advanced`` → the ecology
    tick) and §0 (the server holds every state object).

State convention (the M1 port rule for autoload-coupled statics): the
GDScript statics read/mutated the ``GameState`` singleton; here the
caller owns an explicit :class:`SailingState` — the sailing projection of
GameState (``world`` dict, ``morale``, ``current_port``, ``known_ports``,
``explored_tiles``, ``control_prefs``, ``fleet``) plus every transient
ledger static (counters, per-tick flags, the dialog buffer, a pending
mutiny offer, the sticky game-over reason) and the two GodotRng streams.
``GameState.day`` / ``GameState.gold`` live on the caller's
:class:`~server.sim.player.PersonState` (the established day/gold mirror —
see ``server/sim/port/inn.py``); every function here takes the state
objects it touches and mutates them in place. Pure helpers stay pure.

RNG discipline (M5 golden traces replay these): exactly two GodotRng
streams on the state object — ``weather_rng`` (ledger step 3: the strength
roll first, then the wind-direction roll, in that pinned order, plus
nothing else) and ``mutiny_rng`` (ledger step 6 only, deliberately
separate so a seeded mutiny test is independent of the weather rolls).
``set_weather_seed`` / ``set_mutiny_seed`` are literally ``rng.seed = v``.
The per-day call order inside the ledger is contract; never reorder.

Day-tick seams (docs/90 §5.4 order, all wired by the caller):
  1. the daily ledger (this module, §4.5 order);
  2. ``economy.day_tick`` — injected :class:`EconomyState` + ``DataStore``;
  3. the allegiance month boundary — ``allegiance.month_tick`` when the day
     crossed into a new 30-day month (``day % 30 == 1`` after the
     increment), injected :class:`AllegianceState` (skipped when the caller
     passes ``None``);
  4. the drift push (Drift mode, at sea only — this module);
  5. the ``day_advanced`` hook — the caller's FleetSim/ecology tick hangs
     here. **This module never imports ``npc_fleets``** (the declared
     hook seam);
  6. per moved port the ``market_changed`` hook fires (the pure module
     never emits; docs/90 §5.1).

Declared seams (other agents' modules, NOT ported or imported here):
  * ``scripts/world/autopilot.gd`` — the appointed voyage (§4.19) is a
    separate file, so it is skipped wholesale. The two integration points
    are preserved as contract comments: any manual input cancels the
    appointment (the route dying IS the manual input — the caller hooks
    ``cancel_sail_order``/``try_step``), and docking at the destination
    completes it (the caller hooks :func:`enter_port`).
  * ``scripts/world/npc_fleets.gd`` — the ecology tick is the caller's
    ``on_day_advanced`` listener (90-§5.4 step 5); per-player-move accrual
    (the unified-movement amendment) is likewise caller-side.
  * ``scripts/world/discovery.gd`` — the Explore action's discovery MODULE.
    :func:`explore_here` accepts the discovery port's ``explore(cell)`` as
    an injected callable and hands the fleet cell off exactly as
    ``world_map.explore_here`` hands off to ``Phase3Hooks``; the §4.11
    radius formula itself is ``DiscoverySight.radius()``
    (``36 + floor(cartography / 15)``) — this module pins only the §5
    constants ``DISCOVERY_RADIUS`` / ``DISCOVERY_CARTOGRAPHY_DIVISOR``.
  * ``scripts/quests/phase3_hooks.gd`` — port-entry quest completion
    (``on_port_entered``) is caller-side; :func:`enter_port` composes the
    dialog list around it.
  * ``scripts/world/advice.gd`` — the §2.5 officer advice roll at the
    ledger's sea-day growth point; the growth seam itself
    (:func:`skills.note_sea_day` + the +2 XP award) is ported, the advice
    call site is the declared gap until the advice port lands.
  * The §8.1 v8 ``explored_tiles`` RLE codec — it lives in
    ``autoload/save_system.gd`` (NOT in sailing_sim.gd), so it is NOT
    ported here; the save port owns it verbatim. This module owns only the
    runtime container (``SailingState.explored_tiles``) and the §4.12
    reveal rules (:func:`reveal`).
  * Battle handoff — ``_tick_helm``/``_tick_hold``/``_step_along_sail_path``
    consult ``motion.battle_active`` (an injected callable); the battle
    port owns the real predicate.

Oracle files: ``scripts/world/sailing_sim.gd`` (day ledger, weather,
morale, fail states, mutiny, speed, clock, drift, supplies, facility
hours), ``scenes/world/world_map.gd`` (§4.2 cadence, docking, port entry,
sighting reveal, click-to-sail walk), ``scenes/port/port_screen.gd``
(set_sail). Test pins: ``tools/test_sailing.gd``, ``tools/test_weather.gd``,
``tools/test_morale.gd``, ``tools/test_movement.gd``,
``tools/test_port_hours.gd`` (the arrival-jump harness pins no
player-sailing contract — it audits the NPC ecology's move reports).
"""

from __future__ import annotations

import math
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Final

from server.sim.data import DataStore, data
from server.sim.fleet import fleet as fleet_lib
from server.sim.player import PersonState, character, skills
from server.sim.port.allegiance import AllegianceState, month_tick
from server.sim.port.economy import EconomyState
from server.sim.port.economy import day_tick as economy_day_tick
from server.sim.port.shipyard import (
    carpenter_discount_factor,
    repair_cost_per_point,
    ship_max_durability,
)
from server.sim.rng import GodotRng
from server.sim.world import sail_path
from server.sim.world.raster import OceanLayers, WorldRaster, chebyshev_wrap
from server.sim.world.raster import ocean_layers as _ocean_layers
from server.sim.world.raster import raster as _raster

__all__ = [
    # constants
    "CREW_WAGE_DAILY", "RATION_SIZE", "PROVISIONS_PRICE", "WATER_PRICE",
    "SIGHTING_RADIUS", "SIGHTING_NAVIGATION_DIVISOR", "DISCOVERY_RADIUS",
    "DISCOVERY_CARTOGRAPHY_DIVISOR", "TILES_PER_DEGREE", "MORALE_START",
    "MORALE_PORT_CAP", "STARVATION_LIMIT_DAYS", "SCURVY_GRACE_DIVISOR",
    "MUTINY_THRESHOLD", "MUTINY_CHANCE_PER_DAY", "MUTINY_CHARISMA_DIVISOR",
    "DESERTION_THRESHOLD", "DESERTION_FRACTION", "STORM_DAMAGE_FRACTION",
    "STORM_DAMAGE_LUCK_DIVISOR", "STORM_HEADWAY_BASE_LOSS",
    "STORM_HEADWAY_DIVISOR", "STORM_MORALE_CON_DIVISOR",
    "STORM_DAMAGE_EPSILON", "MORALE_SEA_DAILY", "MORALE_SHORTFALL",
    "MORALE_STORM", "MORALE_UNPAID_WAGES", "MORALE_PORT_DAILY",
    "MORALE_CAPTAIN_LESS", "MORALE_MIN", "MORALE_MAX",
    "STARVATION_CREW_LOSS_FRACTION", "CREW_FLOOR", "MUTINY_PAY_PER_CREW",
    "MUTINY_SUPPRESS_FRACTION", "MUTINY_PAY_MORALE",
    "MUTINY_SUPPRESS_MORALE", "MUTINY_FIZZLE_MORALE", "DIALOG_ORDER",
    "MIN_SPEED", "CREW_FACTOR_MIN", "WIND_FACTORS", "DEFAULT_WEATHER",
    "MONTH_DAYS", "YEAR_MONTHS", "COMPASS_DIRS", "COMPASS_DELTAS",
    "DIRECTION_FACTORS", "CURRENT_ALIGN_FACTOR", "CURRENT_ALIGNED_DEG",
    "CURRENT_OPPOSED_DEG", "TRIM_STATES", "DEFAULT_TRIM",
    "TRIM_SPEED_FACTORS", "TRIM_STORM_MULTIPLIERS", "WIND_JITTER",
    "DEFAULT_WIND_JITTER", "DRIFT_TILES_PER_DAY", "ICE_BLOCKED_KEY",
    "WEATHER_ZONES", "DEFAULT_WEATHER_ZONE", "WEATHER_OUTCOMES",
    "CLOCK_EPSILON", "SEAMANSHIP_SPEED_DIVISOR", "SEAMANSHIP_SPEED_CAP",
    "NIGHT_WINDOW_START_HOUR", "NIGHT_WINDOW_END_HOUR",
    "NIGHT_MOVE_COST_MULTIPLIER", "NIGHT_SAIL_NAVIGATION_THRESHOLD",
    "CAPTAIN_LESS_SPEED_FACTOR", "AT_SEA_REPAIR_POINTS",
    "AT_SEA_REPAIR_CARPENTRY_GATE", "AT_SEA_REPAIR_CARPENTRY_DIVISOR",
    "NM_PER_TILE", "HOURS_PER_DAY", "HOLD_DELAY_SECONDS",
    "HOLD_TILES_PER_SECOND", "SAIL_STEP_SECONDS", "HELM_INTERVAL_MIN",
    "HELM_INTERVAL_MAX",
    # state
    "SailingState", "SailingMotion",
    # rng
    "set_weather_seed", "set_mutiny_seed",
    # phase-8 formulas
    "captain_ship_ids", "captain_less_count", "seamanship_bonus",
    "seamanship_bonus_for", "effective_navigation", "sighting_radius",
    "sighting_radius_for", "is_night_watch", "night_slow_applies",
    "step_move_cost", "storm_headway_factor", "storm_luck_multiplier",
    "storm_morale_multiplier", "storm_morale_delta",
    "charisma_loss_multiplier", "scurvy_limit_days", "carpenter_discount",
    # speed
    "wind_factor", "direction_factor", "current_factor", "crew_factor",
    "effective_speed", "move_cost", "trim_factor", "trim_storm_multiplier",
    "sail_trim", "speed_knots", "knots_text_for",
    # weather
    "weather_zone_for", "weather_zone_for_latitude", "zone_probabilities",
    "roll_weather", "roll_wind_direction",
    # calendar / clock
    "year_for", "month_for", "time_of_day_minutes", "clock_text",
    # supplies
    "daily_need", "supply_days", "fleet_supply_days", "kind_supply_days",
    "supply_block_reason",
    # movement
    "world_tile", "set_world_tile", "is_move_legal", "ice_blocks_entry",
    "try_move", "wait_at_sea", "heading_of_delta", "heading_index",
    "angle_between_dirs",
    # clock / day tick
    "advance_clock", "advance_port_day", "advance_port_hours", "in_port",
    "docked_port_id", "facility_open", "facility_window_text",
    # drift
    "drift_mode_active",
    # ledger
    "reset_ledger_state", "is_game_over", "take_last_day_dialogs",
    "sort_dialogs", "mutiny_is_possible", "mutiny_offer",
    "resolve_mutiny_pay", "resolve_mutiny_suppress", "resolve_mutiny_fizzle",
    "apply_desertion",
    # at-sea repair
    "effective_carpentry", "at_sea_repair_gate_met", "at_sea_repair_fee",
    "at_sea_repair_available", "at_sea_repair",
    # world-scene movement (cadence, docking, port entry, reveal)
    "wrapped_delta", "step_is_legal", "try_step", "docks", "dock_at",
    "enter_port", "set_sail", "reveal", "explore_here",
    "press_direction", "release_direction", "advance_motion",
    "helm_heading", "helm_active", "helm_interval", "helm_steer",
    "helm_stop", "press_wait", "cycle_trim", "sail_to", "cancel_sail",
    "sail_active", "reset_motion",
]


# --- Ledger constants (docs/20-* §5 "sailing_constants") -------------------
#
# §5 is the single source of truth: these are Python constants because the
# §5 JSON block is illustrative for docs validators, not a runtime data file.

#: §4.5 step 2: gold per crew member per day (locked).
CREW_WAGE_DAILY: Final[int] = 2
#: §4.5 step 1 / §4.10: one unit feeds/waters this many crew for one day.
RATION_SIZE: Final[int] = 5
#: §4.10: locked supply prices, unaffected by supply/demand.
PROVISIONS_PRICE: Final[int] = 2
WATER_PRICE: Final[int] = 1
#: §4.11: base port sighting radius, Chebyshev, wrap-aware on x.
SIGHTING_RADIUS: Final[int] = 48
#: §4.11: ``48 + floor(effective_navigation / 12)`` — the sighting divisor.
SIGHTING_NAVIGATION_DIVISOR: Final[int] = 12
#: §4.11 / 70-* §4.4: the separate discovery radius base — the ENGINE
#: formula (``36 + floor(cartography / 15)``) lives in the discovery port;
#: §5 pins the constants here for completeness.
DISCOVERY_RADIUS: Final[int] = 36
DISCOVERY_CARTOGRAPHY_DIVISOR: Final[int] = 15
#: §4.1: ``lat = 90 − y / 12`` (12 tiles per degree, one tile = 5 nm).
TILES_PER_DEGREE: Final[int] = 12
#: §4.8: new-game morale and the in-port ceiling.
MORALE_START: Final[int] = 70
MORALE_PORT_CAP: Final[int] = 80
#: §4.9: fail-state counter base (starvation, and the scurvy grace base).
STARVATION_LIMIT_DAYS: Final[int] = 7
#: §4.9 scurvy grace: the ``floor(x / 10)`` divisor fed by the higher of
#: the player's constitution and the in-post surgeon's medicine.
SCURVY_GRACE_DIVISOR: Final[int] = 10
#: §4.8.3: mutiny trigger threshold and per-day chance at sea.
MUTINY_THRESHOLD: Final[int] = 20
MUTINY_CHANCE_PER_DAY: Final[float] = 0.25
#: §4.8.2/§4.8.3: the charisma factor's divisor.
MUTINY_CHARISMA_DIVISOR: Final[float] = 200.0
#: §4.8.2: desertion on port entry below this morale.
DESERTION_THRESHOLD: Final[int] = 40
DESERTION_FRACTION: Final[float] = 0.10
#: §4.7: storm damage as a fraction of max durability, mitigated by the
#: continuous luck term (Phase 8 — the ``luck ≥ 50 → ×0.75`` step is
#: deleted).
STORM_DAMAGE_FRACTION: Final[float] = 0.05
STORM_DAMAGE_LUCK_DIVISOR: Final[float] = 250.0
#: §4.7 storm headway (Phase 8): on a storm day the movement budget loses
#: ``0.5 × (1 − (COU − 10) / 400)`` of its speed (×0.500 at COU 10 →
#: ×0.6125 at COU 100). Player-ledger only.
STORM_HEADWAY_BASE_LOSS: Final[float] = 0.5
STORM_HEADWAY_DIVISOR: Final[float] = 400.0
#: §4.8.1 storm-day morale (Phase 8): the storm −5 is
#: × ``1 − (CON − 10) / 300``.
STORM_MORALE_CON_DIVISOR: Final[float] = 300.0
#: §4.7 storm damage is rounded with ``ceil``; binary float noise makes an
#: exact integer product evaluate a hair above the integer (140 × 0.05 =
#: 7.000000000000001), so the ceiling is taken on ``raw − EPSILON``. This
#: can never drop a real fractional value across an integer boundary.
STORM_DAMAGE_EPSILON: Final[float] = 1.0e-9

# --- Morale / fail-state / mutiny constants (docs/20-* §4.8–§4.9) -----------

#: §4.8.1 daily delta table, exactly as documented. The at-sea baseline is
#: −1; every other at-sea row is an *additional* −5 (they stack). In port
#: the +5 replaces the at-sea rows entirely.
MORALE_SEA_DAILY: Final[int] = -1
MORALE_SHORTFALL: Final[int] = -5
MORALE_STORM: Final[int] = -5
MORALE_UNPAID_WAGES: Final[int] = -5
MORALE_PORT_DAILY: Final[int] = 5
#: §4.8.1 (the 40-* §4.4 captain-less rule): while any fleet ship beyond
#: the flagship has no in-post captain, the daily decay gains this
#: additional −2 (once per day, not per ship).
MORALE_CAPTAIN_LESS: Final[int] = -2
#: Morale is a 0–100 fleet value (§4.8).
MORALE_MIN: Final[int] = 0
MORALE_MAX: Final[int] = 100

#: §4.9: daily crew loss while starved / scurvy-ridden,
#: ``max(1, floor(×0.05))``, never below :data:`CREW_FLOOR`.
STARVATION_CREW_LOSS_FRACTION: Final[float] = 0.05
#: §6: "Crew = 0 impossible: all crew-loss rules floor at 1".
CREW_FLOOR: Final[int] = 1

#: §4.8.3 mutiny modal: pay off at ``crew × 20`` gold; suppress costs 30%.
MUTINY_PAY_PER_CREW: Final[int] = 20
MUTINY_SUPPRESS_FRACTION: Final[float] = 0.30
#: §4.8.3 morale outcomes of the three resolutions.
MUTINY_PAY_MORALE: Final[int] = 50
MUTINY_SUPPRESS_MORALE: Final[int] = 40
MUTINY_FIZZLE_MORALE: Final[int] = 5

#: §4.7 dialog queue order: weather damage → sinking → mutiny → desertion →
#: greeting. ``sinking`` sits between weather and mutiny because it is
#: ledger step 5's consequence of step 3's storm damage.
DIALOG_ORDER: Final[dict[str, int]] = {
    "weather": 0,
    "sinking": 1,
    "mutiny": 2,
    "desertion": 3,
    "greeting": 4,
}

#: §4.4: "minimum 1 tile/day" — speed can never be 0 (§6).
MIN_SPEED: Final[int] = 1
#: §4.6: ``crew / crew_min`` never drops below 0.25.
CREW_FACTOR_MIN: Final[float] = 0.25

#: §4.7 wind factor: weather → propulsion class → multiplier.
WIND_FACTORS: Final[dict[str, dict[str, float]]] = {
    "calm": {"sail": 0.8, "oar": 1.0, "hybrid": 1.0},
    "fair": {"sail": 1.0, "oar": 1.0, "hybrid": 1.0},
    "strong": {"sail": 1.25, "oar": 1.0, "hybrid": 1.1},
    "storm": {"sail": 1.5, "oar": 1.0, "hybrid": 1.2},
}
#: §4.7 default weather before the first ledger roll. Read-only: the
#: simulation never writes ``world.weather`` from the movement path.
DEFAULT_WEATHER: Final[str] = "calm"

# --- Phase-6 direction-aware constants (§4.4, §4.7.1, §4.15–§4.18) ----------

#: §4.15: a 360-day year of twelve 30-day months; day 1 is Month 1.
MONTH_DAYS: Final[int] = 30
YEAR_MONTHS: Final[int] = 12

#: §4.4 / §4.16: the 8 compass direction ids every heading/wind/current
#: value lives in. No rule may produce or accept anything outside this
#: domain. Tile delta of each index (y grows southward: N is (0, −1)).
COMPASS_DIRS: Final[tuple[str, ...]] = (
    "N", "NE", "E", "SE", "S", "SW", "W", "NW",
)
COMPASS_DELTAS: Final[tuple[tuple[int, int], ...]] = (
    (0, -1), (1, -1), (1, 0), (1, 1),
    (0, 1), (-1, 1), (-1, 0), (-1, -1),
)
#: §4.4 direction-factor table, ``[angle bucket][class]``. The bucket is
#: the angle between the move heading and the wind-FROM direction, bucketed
#: to the 8-compass grid. Oar rows are the locked §4.17 class rule.
DIRECTION_FACTORS: Final[dict[int, dict[str, float]]] = {
    0: {"sail": 0.50, "hybrid": 0.85, "oar": 1.00},
    45: {"sail": 0.70, "hybrid": 0.95, "oar": 1.00},
    90: {"sail": 1.00, "hybrid": 1.00, "oar": 1.00},
    135: {"sail": 1.15, "hybrid": 1.05, "oar": 1.00},
    180: {"sail": 1.30, "hybrid": 1.10, "oar": 1.00},
}
#: §4.4: ``current_factor`` = 1 ± 0.08 × strength inside the bands.
CURRENT_ALIGN_FACTOR: Final[float] = 0.08
CURRENT_ALIGNED_DEG: Final[float] = 67.5
CURRENT_OPPOSED_DEG: Final[float] = 112.5

#: §4.17 trim states, speed factors and storm-damage multipliers. The
#: class rule (locked): oar ignores trim entirely — both tables forced
#: to 1.0.
TRIM_STATES: Final[tuple[str, ...]] = ("furled", "reefed", "normal", "full")
DEFAULT_TRIM: Final[str] = "normal"
TRIM_SPEED_FACTORS: Final[dict[str, float]] = {
    "furled": 0.0, "reefed": 0.75, "normal": 1.0, "full": 1.15,
}
TRIM_STORM_MULTIPLIERS: Final[dict[str, float]] = {
    "furled": 0.5, "reefed": 0.75, "normal": 1.0, "full": 1.5,
}

#: §4.7.1 jitter tables, keyed by the day's just-rolled weather. ``keep``
#: is the probability the prevailing direction is kept; ``offsets`` are the
#: pinned deviation draws in 8-grid steps (positive = clockwise, N→NE),
#: applied as ``(prevailing_index + offset) mod 8``.
WIND_JITTER: Final[dict[str, dict[str, Any]]] = {
    "calm": {"keep": 0.60, "offsets": [1, -1, 2, -2]},
    "fair": {"keep": 0.70, "offsets": [1, -1]},
    "strong": {"keep": 0.60, "offsets": [1, -1, 2, -2]},
    "storm": {"keep": 0.0, "offsets": []},
}
#: Unknown weather reads the ``fair`` row (documented guard default).
DEFAULT_WIND_JITTER: Final[str] = "fair"

#: §4.16 drift-mode daily push distances, strength → tiles/day at 5 nm.
DRIFT_TILES_PER_DAY: Final[dict[int, float]] = {1: 0.5, 2: 2.0, 3: 4.0}
#: ui_strings key of the §4.18 ice toast, set on ``last_move_blocked_key``
#: when a move is refused for in-month seasonal ice.
ICE_BLOCKED_KEY: Final[str] = "world.ice_blocked"

#: §4.7 latitude weather bands. Keys are the four **engine** ids
#: ``calm|fair|strong|storm`` (never the display column names). Every row
#: sums to 1.00; the values are the *base* table — the luck term only
#: rescales the storm entry (:func:`zone_probabilities`).
WEATHER_ZONES: Final[dict[str, dict[str, float]]] = {
    "doldrums": {"calm": 0.30, "fair": 0.45, "strong": 0.15, "storm": 0.10},
    "trade_winds": {"calm": 0.15, "fair": 0.30, "strong": 0.20, "storm": 0.35},
    "variables": {"calm": 0.30, "fair": 0.40, "strong": 0.20, "storm": 0.10},
    "westerlies": {"calm": 0.10, "fair": 0.30, "strong": 0.35, "storm": 0.25},
    "boreal": {"calm": 0.15, "fair": 0.35, "strong": 0.30, "storm": 0.20},
}
#: Fallback band for an unknown zone id (the mildest table, never reachable
#: through :func:`weather_zone_for`).
DEFAULT_WEATHER_ZONE: Final[str] = "doldrums"
#: Outcome order used by the single uniform draw (fixed forever).
WEATHER_OUTCOMES: Final[tuple[str, ...]] = ("calm", "fair", "strong", "storm")

#: Tolerance for the day boundary (repeated float additions must still
#: tick; §4.3's ``clock_fraction >= 1.0`` is applied with this epsilon).
CLOCK_EPSILON: Final[float] = 1.0e-9

# --- Phase-8 skill/attribute formulas (docs/20-* §4.2, §4.4, §4.11) ---------

#: §4.4: ``seamanship_bonus = seamanship / 300`` clamped ``[0, +0.30]``
#: (the divisor/cap pair — the formula itself is delegated to
#: ``character.speed_bonus_for``, the single implementation).
SEAMANSHIP_SPEED_DIVISOR: Final[float] = 300.0
SEAMANSHIP_SPEED_CAP: Final[float] = 0.30
#: §4.2 night sailing: a move starting at wall-clock ≥ 22:00 or < 06:00
#: costs ``2 × move_cost`` unless effective navigation ≥ 40.
NIGHT_WINDOW_START_HOUR: Final[int] = 22
NIGHT_WINDOW_END_HOUR: Final[int] = 6
NIGHT_MOVE_COST_MULTIPLIER: Final[float] = 2.0
NIGHT_SAIL_NAVIGATION_THRESHOLD: Final[int] = 40
#: 40-* §4.4: an escort without an in-post captain contributes
#: ``ShipType.speed × 0.8`` to the slowest-hull scan.
CAPTAIN_LESS_SPEED_FACTOR: Final[float] = 0.8
#: 40-* §4.5 at-sea minor repair: +10 durability, carpentry gate 60, the
#: ``floor(carpentry / 20)``% fee discount (the formula lives in the
#: shipyard port; the skills-reading side re-owns it here).
AT_SEA_REPAIR_POINTS: Final[int] = 10
AT_SEA_REPAIR_CARPENTRY_GATE: Final[int] = 60
AT_SEA_REPAIR_CARPENTRY_DIVISOR: Final[float] = 20.0

# --- Speed display (docs/40-* §4.4, amended 2026-11-02) ----------------------

#: Nautical miles per world tile (12 tiles/degree → one tile = 5 nm).
NM_PER_TILE: Final[float] = 5.0
#: Hours per game day — the day is a calendar day (§4.3).
HOURS_PER_DAY: Final[float] = 24.0

# --- §4.2 cadence constants (scenes/world/world_map.gd, verbatim) ------------

#: Seconds a held direction must be down before it starts repeating (§4.2).
HOLD_DELAY_SECONDS: Final[float] = 0.25
#: Repeats per second once the delay has elapsed ("~8 tiles/s").
HOLD_TILES_PER_SECOND: Final[float] = 8.0
#: Seconds between two click-to-sail steps (same pace as a held step).
SAIL_STEP_SECONDS: Final[float] = 1.0 / HOLD_TILES_PER_SECOND
#: Helm auto-step interval clamp, seconds (§4.2 / §5 helm_interval_clamp_s).
HELM_INTERVAL_MIN: Final[float] = 0.12
HELM_INTERVAL_MAX: Final[float] = 2.0

#: The eight movement action ids → tile deltas (world_map MOVE_ACTIONS,
#: docs/80-* §4.3 / project.godot).
MOVE_ACTIONS: Final[dict[str, tuple[int, int]]] = {
    "move_nw": (-1, -1),
    "move_n": (0, -1),
    "move_ne": (1, -1),
    "move_w": (-1, 0),
    "move_e": (1, 0),
    "move_sw": (-1, 1),
    "move_s": (0, 1),
    "move_se": (1, 1),
}


# --- State objects -----------------------------------------------------------


@dataclass
class SailingState:
    """The run-scoped sailing state — the caller-owned mutable object.

    Mirrors exactly the ``GameState`` members sailing_sim.gd touches
    (``world``, ``morale``, ``current_port``, ``known_ports``,
    ``explored_tiles``, ``control_prefs``, ``fleet`` — field names
    verbatim) plus every transient class static of the GDScript module
    (deliberately never saved: a pending shortage/game-over never survives
    a save — saving only happens in port). ``day``/``gold`` stay on the
    caller's :class:`~server.sim.player.PersonState`.
    """

    ## The §5.4 ``GameState.world`` dict: ``position {x, y}``, ``map_id``,
    ## ``weather``, ``sail_trim``, ``heading``, ``wind_dir``,
    ## ``clock_fraction``, ``last_departed_port``.
    world: dict[str, Any] = field(default_factory=dict)
    ## ``GameState.morale`` — fleet morale 0–100 (§4.8).
    morale: int = MORALE_START
    ## ``GameState.current_port`` — the docked port id, else ``None``.
    current_port: str | None = None
    ## ``GameState.known_ports`` — discovered port ids (§4.11).
    known_ports: list[str] = field(default_factory=list)
    ## ``GameState.explored_tiles`` — the §4.12 runtime container
    ## ``{(x, y)}`` (the §8.1 v8 RLE codec is the save port's).
    explored_tiles: set[tuple[int, int]] = field(default_factory=set)
    ## ``GameState.control_prefs`` — ``{input_mode, current_mode}``,
    ## defaults pinned in 90-§5.4.
    control_prefs: dict[str, Any] = field(
        default_factory=lambda: {"input_mode": "step",
                                 "current_mode": "modifier"})
    ## ``GameState.fleet`` — ship instances (40-* §4.1); mutated in place
    ## through :mod:`server.sim.fleet.fleet` functions.
    fleet: list[Any] = field(default_factory=list)

    # --- the two seeded streams (RNG discipline, see module docstring) ---

    ## Ledger step 3's stream: the strength roll, then the wind-direction
    ## roll — nothing else ever draws here.
    weather_rng: GodotRng = field(default_factory=GodotRng)
    ## Ledger step 6's stream, deliberately separate from the weather one.
    mutiny_rng: GodotRng = field(default_factory=GodotRng)

    # --- transient ledger statics (never persisted) ---

    #: Step 3 flag: true when the most recent tick rolled a storm.
    last_day_storm: bool = False
    #: Latitude band the most recent roll used (tests/HUD diagnostic).
    last_weather_zone: str = ""
    #: §4.7 storm damage dealt in the most recent tick:
    #: ``[{"ship_type_id", "points"}]``.
    last_day_storm_damage: list[dict[str, Any]] = field(default_factory=list)
    #: Step 1's shortage record, consumed by steps 4/5.
    last_day_shortfalls: dict[str, bool] = field(
        default_factory=lambda: {"provisions": False, "water": False})
    #: Step 2: true when wages exceeded the purse and gold was clamped.
    last_day_unpaid_wages: bool = False
    #: Step 2: wages charged in the most recent tick.
    last_day_wages: int = 0
    #: §4.9 starvation counter (consecutive provisions-shortfall days).
    starvation_days: int = 0
    #: §4.9 scurvy counter (the water mirror).
    scurvy_days: int = 0
    #: §4.8.1 delta applied by the most recent step 4.
    last_morale_delta: int = 0
    #: Dialogs produced by the most recent tick (§4.7 order via
    #: :func:`sort_dialogs`; :func:`take_last_day_dialogs` drains).
    last_day_dialogs: list[dict[str, Any]] = field(default_factory=list)
    #: §4.8.3 mutiny awaiting a player decision (``{}`` when none).
    pending_mutiny: dict[str, Any] = field(default_factory=dict)
    #: Reason of the game-over that ended the run (``""`` while alive).
    #: Sticky for the rest of the run; :func:`reset_ledger_state` clears it.
    game_over_reason: str = ""
    #: The most recent ``is_move_legal`` rejection key (``""`` legal/ordinary
    #: block, :data:`ICE_BLOCKED_KEY` for §4.18 ice).
    last_move_blocked_key: str = ""
    #: §4.16 fractional drift accumulator (tiles; never persisted).
    drift_accumulator: float = 0.0
    #: Diagnostic of the most recent direction roll: the month's prevailing
    #: token the jitter was applied to (or ``"VAR"``).
    last_wind_prevailing: str = ""
    #: The fleet-day of the last successful at-sea repair (−1 = none).
    at_sea_repair_day: int = -1
    #: Day of the last completed ledger tick (−1 before the first) — the
    #: new-run/load detector (any backwards jump resets the transients).
    _last_run_day: int = -1

    # --- EventBus-mirror hooks (docs/90 §5.1: the pure module never
    # --- emits; the caller wires the WS broadcast to these) ---

    #: ``gold_changed(new_gold)`` — wages/mutiny-pay/repair charges.
    on_gold_changed: Callable[[int], None] | None = None
    #: ``fleet_changed()`` — storm damage, crew loss, mutiny suppression.
    on_fleet_changed: Callable[[], None] | None = None
    #: ``market_changed(port_id)`` — per moved port of the economy step.
    on_market_changed: Callable[[str], None] | None = None
    #: ``day_advanced(day)`` — the 90-§5.4 step-5 listener seam; the caller
    #: hangs its NPC-fleet/ecology tick here (never imported here).
    on_day_advanced: Callable[[int], None] | None = None
    #: ``clock_changed()`` — after every time-consuming advance.
    on_clock_changed: Callable[[], None] | None = None
    #: ``game_over(reason)`` — fired once per run.
    on_game_over: Callable[[str], None] | None = None
    #: ``port_entered(port_id)`` — the §4.11 docking announcement.
    on_port_entered: Callable[[str], None] | None = None


@dataclass
class SailingMotion:
    """The §4.2 transient movement/cadence state (world_map.gd's scene
    vars; never saved — a load restarts at rest).

    ``battle_active`` is the battle-handoff seam: an injected
    ``Callable[[], bool]`` the helm/hold/route walkers consult exactly
    where the GDScript scene queried ``battle_in_progress()``; ``None``
    reads as "no battle" (headless fixtures).
    """

    #: The held direction action id (``""`` = none held).
    hold_action: str = ""
    #: True while a test-driven hold (no real input device re-check).
    hold_forced: bool = False
    #: Seconds accumulated toward the hold delay / next repeat.
    hold_elapsed: float = 0.0
    #: Seconds since the last held step (re-phased past the delay).
    hold_since_step: float = 0.0
    #: True while the helm auto-stepper runs (§4.2).
    helm_stepping: bool = False
    #: Seconds accumulated toward the next auto-step.
    helm_since_step: float = 0.0
    #: Remaining click-to-sail steps (unit tiles, world frame).
    sail_path: list[tuple[int, int]] = field(default_factory=list)
    #: Clicked destination of the current (or suspended) order.
    sail_target: tuple[int, int] = (-1, -1)
    #: Seconds accumulated toward the next route step.
    sail_elapsed: float = 0.0
    #: True while a battle interruption has suspended the order.
    sail_suspended: bool = False
    #: The port a click-shore route is heading for (§4.11.1); ``""`` for an
    #: ordinary sea route.
    sail_dock_port: str = ""
    #: The battle-handoff seam (see class docstring).
    battle_active: Callable[[], bool] | None = None


def _battle_active(motion: SailingMotion) -> bool:
    """The injected battle predicate, defaulted false (see SailingMotion)."""
    if motion.battle_active is None:
        return False
    return bool(motion.battle_active())


# --- Small helpers -----------------------------------------------------------


def _clampf(value: float, low: float, high: float) -> float:
    return low if value < low else (high if value > high else value)


def _clampi(value: int, low: int, high: int) -> int:
    return low if value < low else (high if value > high else value)


def _round_half_away(value: float) -> int:
    """Godot's ``round()`` — half away from zero (Python's ``round`` is
    banker's; the storm-morale delta pins round(−3.5) = −4)."""
    return int(math.floor(value + 0.5)) if value >= 0.0 \
        else int(math.ceil(value - 0.5))


def _has_game(st: PersonState, state: SailingState) -> bool:
    """A run exists (world_map ``_has_game``): the player block or the
    fleet is non-empty."""
    return bool(st.player) or bool(state.fleet)


# --- World tile helpers (GameState.world_tile / set_world_tile) --------------


def world_tile(state: SailingState) -> tuple[int, int]:
    """The fleet tile from ``world.position`` (the ``{x, y}`` save shape);
    ``(0, 0)`` when the run has no position yet (the pre-run fixtures)."""
    position = state.world.get("position")
    if not isinstance(position, dict):
        return (0, 0)
    return (int(position.get("x", 0)), int(position.get("y", 0)))


def set_world_tile(state: SailingState, x: int, y: int) -> None:
    """Stores the fleet tile as ``world.position = {x, y}`` (§4.1: x is
    taken mod 4320 everywhere — callers pass an already-wrapped x)."""
    state.world["position"] = {"x": int(x), "y": int(y)}


def _world(world: WorldRaster | None) -> WorldRaster:
    """The injected raster or the process singleton (the DataLoader.map
    role)."""
    return world if world is not None else _raster()


def _ocean(ocean: OceanLayers | None) -> OceanLayers:
    """The injected ocean layers or the process singleton (the
    ``OceanLayers.instance()`` role)."""
    return ocean if ocean is not None else _ocean_layers()


# --- RNG discipline ----------------------------------------------------------


def set_weather_seed(state: SailingState, seed_value: int) -> None:
    """Reseeds the weather stream (GDScript ``rng.seed = seed_value``)."""
    state.weather_rng.seed = seed_value


def set_mutiny_seed(state: SailingState, seed_value: int) -> None:
    """Reseeds the mutiny stream (the separate-stream pattern)."""
    state.mutiny_rng.seed = seed_value


# --- Phase-8 skill/attribute reads (the guarded loaders → direct calls) -----


def captain_ship_ids(st: PersonState) -> list[str]:
    """Ship ids whose captain post is filled: every in-post captain's
    ``officer_states.ship_id`` (90-§8: non-empty only on a captain post).
    Ship identity is the instance's ``ship_type_id`` today (40-* §4.1)."""
    ids: list[str] = []
    for officer_id in skills.officers_in_post(st, "captain"):
        entry: dict[str, Any] = st.officer_states.get(str(officer_id), {})
        ship_id = str(entry.get("ship_id", ""))
        if ship_id and ship_id not in ids:
            ids.append(ship_id)
    return ids


def captain_less_count(state: SailingState, st: PersonState) -> int:
    """Fleet ships **beyond the flagship** with no in-post captain (40-*
    §4.4). Zero for the default one-ship fleet."""
    captained = captain_ship_ids(st)
    count = 0
    for index, ship in enumerate(state.fleet):
        if index == 0 or not isinstance(ship, dict):
            continue
        if str(ship.get("ship_type_id", "")) not in captained:
            count += 1
    return count


def seamanship_bonus(st: PersonState, store: DataStore) -> float:
    """§4.4 (Phase 8): the seamanship speed bonus on the EFFECTIVE skill
    (player + in-post boatswain) — the formula delegated to
    ``character.speed_bonus_for`` (the single implementation)."""
    return seamanship_bonus_for(skills.effective_skill(st, store, "seamanship"))


def seamanship_bonus_for(seamanship: int) -> float:
    """:func:`seamanship_bonus` for an explicit value — ``skill / 300``
    clamped ``[0, +0.30]``, never negative."""
    return character.speed_bonus_for(seamanship)


def effective_navigation(st: PersonState, store: DataStore) -> int:
    """Effective navigation: player skill + the in-post pilot's value
    (50-* §4.5.3, via ``Skills.effective_skill``)."""
    return skills.effective_skill(st, store, "navigation")


def sighting_radius(st: PersonState, store: DataStore) -> int:
    """§4.11: ``48 + floor(effective_navigation / 12)`` — base 48 ≈ 4° ≈
    240 nm plus the navigation term (Chebyshev, wrap-aware on x — the wrap
    arithmetic is the caller's). Map exploration (§4.12) uses the same
    radius. Delegates to the character port's single implementation."""
    return sighting_radius_for(effective_navigation(st, store))


def sighting_radius_for(effective_navigation_value: int) -> int:
    """:func:`sighting_radius` for an explicit value (the pure formula)."""
    return character.sighting_radius_for(effective_navigation_value)


def is_night_watch(state: SailingState) -> bool:
    """§4.2 (Phase 8): true while the wall-clock start-of-move time is
    inside the night window — ``HH:MM`` ≥ 22:00 or < 06:00."""
    minutes = time_of_day_minutes(state)
    return minutes >= NIGHT_WINDOW_START_HOUR * 60 \
        or minutes < NIGHT_WINDOW_END_HOUR * 60


def night_slow_applies(state: SailingState, st: PersonState,
                       store: DataStore) -> bool:
    """True when a move starting now pays the night slow: night window
    **and** effective navigation below 40 (the §4.2 exemption)."""
    return is_night_watch(state) \
        and effective_navigation(st, store) < NIGHT_SAIL_NAVIGATION_THRESHOLD


def step_move_cost(state: SailingState, st: PersonState, store: DataStore,
                   heading: str = "") -> float:
    """The clock cost of one fleet move (§4.2): ``move_cost(heading)``
    doubled while :func:`night_slow_applies` — every step source alike. A
    docking charge is **not** a move: it stays the plain
    :func:`move_cost` (§4.11.1)."""
    cost = move_cost(state, st, store, heading)
    if cost <= 0.0:
        return 0.0
    if night_slow_applies(state, st, store):
        return cost * NIGHT_MOVE_COST_MULTIPLIER
    return cost


def storm_headway_factor(state: SailingState, st: PersonState) -> float:
    """§4.7 (Phase 8): on a day that rolled storm the fleet runs at
    ``1 − 0.5 × (1 − (COU − 10) / 400)`` of normal speed; every other day
    1.0. Player-ledger only (NPC fleets never call this)."""
    if str(state.world.get("weather", DEFAULT_WEATHER)) != "storm":
        return 1.0
    retention = 1.0 - float(character.attribute(st, "courage") - 10) \
        / STORM_HEADWAY_DIVISOR
    return 1.0 - STORM_HEADWAY_BASE_LOSS * retention


def storm_luck_multiplier(st: PersonState) -> float:
    """§4.7 (Phase 8): the continuous luck storm-damage mitigation,
    ``1 − luck / 250`` — applied before rounding. Delegates to the
    character port's ``storm_damage_multiplier`` (single implementation)."""
    return character.storm_damage_multiplier(st)


def storm_morale_multiplier(st: PersonState) -> float:
    """§4.8.1 (Phase 8): ``1 − (CON − 10) / 300`` — constitution tempers
    the storm morale hit."""
    return 1.0 - float(character.attribute(st, "constitution") - 10) \
        / STORM_MORALE_CON_DIVISOR


def storm_morale_delta(st: PersonState) -> int:
    """The §4.8.1 storm-day morale delta: ``−5 ×`` the multiplier, rounded
    half away from zero (CON 10 → −5, CON 100 → −4)."""
    return _round_half_away(float(MORALE_STORM) * storm_morale_multiplier(st))


def charisma_loss_multiplier(st: PersonState) -> float:
    """§4.8.2/§4.8.3 (Phase 8): ``max(0, 1 − (charisma − 10) / 200)`` —
    floored at 0 like the old formula (a negative multiplier would turn a
    loss into a gain). Delegates to ``character.loss_multiplier_for``."""
    return character.loss_multiplier_for(character.attribute(st, "charisma"))


def scurvy_limit_days(st: PersonState, store: DataStore) -> int:
    """§4.9 (Phase 8): ``7 + floor(max(CON, in-post surgeon medicine) /
    10)`` — the player's constitution and the in-post surgeon's medicine
    feed the same ``floor(x / 10)`` term."""
    grace = max(character.attribute(st, "constitution"),
                skills.effective_skill(st, store, "medicine"))
    return STARVATION_LIMIT_DAYS + int(
        math.floor(float(grace) / float(SCURVY_GRACE_DIVISOR)))


def carpenter_discount(st: PersonState, store: DataStore) -> float:
    """40-* §4.3 (Phase 8): the in-post carpenter's repair-fee discount,
    ``1 − floor(carpentry / 20) / 100`` on the EFFECTIVE carpentry (player
    0 + the in-post carpenter). Composed after the port-side count-title
    ×0.8 and floored once at the end of the whole transaction (70-*
    §4.9.2)."""
    return carpenter_discount_factor(effective_carpentry(st, store))


# --- Speed (§4.4, §4.6, §4.7, §4.14–§4.17) -----------------------------------


def wind_factor(weather: str, ship_class: str) -> float:
    """§4.7: multiplier for the current weather and the flagship's class.
    Unknown weather/class combinations fall back to 1.0."""
    table = WIND_FACTORS.get(weather, {})
    return float(table.get(ship_class, 1.0))


def direction_factor(heading: str, wind_dir: str, ship_class: str,
                     weather: str) -> float:
    """§4.4: the direction factor for ``heading`` against the day's
    wind-FROM direction, bucketed to the 8-compass grid. Applied **only
    when weather ≠ calm**; an unknown heading/wind id degrades to the beam
    bucket's class-neutral 1.0."""
    if weather == "calm":
        return 1.0
    angle = angle_between_dirs(heading, wind_dir)
    if angle < 0:
        return 1.0
    table = DIRECTION_FACTORS.get(angle, {})
    return float(table.get(ship_class, 1.0))


def current_factor(state: SailingState, heading: str, cell: tuple[int, int],
                   month: int, ocean: OceanLayers | None = None) -> float:
    """§4.16 (modifier mode): alignment between the move heading and the
    current's flow direction at ``cell`` — within 67.5° → ``1 + 0.08 ×
    strength``; 67.5–112.5° → 1.0; ≥ 112.5° → ``1 − 0.08 × strength``.
    Identity 1.0 on an empty current tile, an unknown heading, and in
    ``current_mode: "drift"`` (the current then acts as the daily push)."""
    if drift_mode_active(state):
        return 1.0
    current = _ocean(ocean).current_at(cell[0], cell[1], month)
    if not current:
        return 1.0
    angle = angle_between_dirs(heading, str(current["dir"]))
    if angle < 0:
        return 1.0
    strength = int(current["strength"])
    if float(angle) < CURRENT_ALIGNED_DEG:
        return 1.0 + CURRENT_ALIGN_FACTOR * float(strength)
    if float(angle) > CURRENT_OPPOSED_DEG:
        return 1.0 - CURRENT_ALIGN_FACTOR * float(strength)
    return 1.0


def crew_factor(state: SailingState) -> float:
    """§4.6: ``crew < crew_min ? max(crew/crew_min, 0.25) : 1.0`` — crew
    and crew_min both come from the flagship (§4.4 composition rule)."""
    ship = fleet_lib.flagship(state.fleet)
    if not ship:
        return 1.0
    crew_min = fleet_lib.ship_stat(ship, "crew_min")
    crew = int(ship.get("crew", 0))
    if crew_min <= 0 or crew >= crew_min:
        return 1.0
    return max(float(crew) / float(crew_min), CREW_FACTOR_MIN)


def _fleet_base_speed(state: SailingState, st: PersonState) -> int:
    """The §4.4 slowest-hull scan, with the 40-* §4.4 Phase-8 captain-less
    rule: a ship **beyond the flagship** with no in-post captain whose
    ``ship_id`` matches contributes ``speed × 0.8``. The flagship is
    exempt; with no escorts the scan reduces to ``fleet.slowest_speed``."""
    best = 0
    captained = captain_ship_ids(st)
    for index, ship in enumerate(state.fleet):
        if not isinstance(ship, dict):
            continue
        speed = fleet_lib.ship_stat(ship, "speed")
        if speed <= 0:
            continue
        if index > 0 and str(ship.get("ship_type_id", "")) not in captained:
            speed = int(math.floor(float(speed) * CAPTAIN_LESS_SPEED_FACTOR))
        if best == 0 or speed < best:
            best = speed
    return best


def trim_factor(trim: str, ship_class: str) -> float:
    """§4.17 speed factor: the trim table with the locked class rule —
    **oar ignores trim entirely** (forced 1.0); hybrid uses the sail
    table. An unknown trim state reads ``normal``."""
    if ship_class == "oar":
        return 1.0
    return float(TRIM_SPEED_FACTORS.get(trim, TRIM_SPEED_FACTORS[DEFAULT_TRIM]))


def trim_storm_multiplier(trim: str, ship_class: str) -> float:
    """§4.17 storm-damage multiplier for one hull's class: oar forced 1.0
    (the same class rule)."""
    if ship_class == "oar":
        return 1.0
    return float(TRIM_STORM_MULTIPLIERS.get(
        trim, TRIM_STORM_MULTIPLIERS[DEFAULT_TRIM]))


def sail_trim(state: SailingState) -> str:
    """The fleet's persisted trim state (``world.sail_trim``), guard-read
    with the pinned default."""
    return str(state.world.get("sail_trim", DEFAULT_TRIM))


def effective_speed(state: SailingState, st: PersonState, store: DataStore,
                    heading: str = "", ocean: OceanLayers | None = None,
                    world: WorldRaster | None = None) -> int:
    """§4.4, exactly:
    ``floor(slowest hull × wind × [direction × current × trim] × crew ×
    (1 + seamanship) × storm headway)``, min 1.

    ``base_speed`` is the slowest ``ShipType.speed`` in the fleet (with
    the captain-less ×0.8 rule); weather class, crew, crew_min and the
    seamanship bonus come from the flagship. The heading-less form (the
    HUD average) uses the beam bucket, 1.0, for BOTH the direction and the
    current term. A furled sail/hybrid fleet has no speed at all (§4.17):
    this returns 0 — only the oar exemption keeps a furled galley rowing.
    """
    base = _fleet_base_speed(state, st)
    if base <= 0:
        # No fleet (or an unknown hull): §4.4's floor still applies.
        return MIN_SPEED
    flagship = fleet_lib.flagship(state.fleet)
    ship_class = _ship_class_of(flagship, store)
    weather = str(state.world.get("weather", DEFAULT_WEATHER))
    trim_f = trim_factor(sail_trim(state), ship_class)
    if trim_f <= 0.0:
        return 0
    headingless = heading_index(heading) < 0
    dir_f = 1.0
    current_f = 1.0
    if not headingless:
        wind_dir = str(state.world.get("wind_dir", "E"))
        dir_f = direction_factor(heading, wind_dir, ship_class, weather)
        cell = world_tile(state)
        current_f = current_factor(state, heading, cell,
                                   month_for(st.day), ocean)
    raw = float(base) \
        * wind_factor(weather, ship_class) \
        * dir_f \
        * current_f \
        * crew_factor(state) \
        * (1.0 + seamanship_bonus(st, store)) \
        * storm_headway_factor(state, st) \
        * trim_f
    return max(int(math.floor(raw)), MIN_SPEED)


def move_cost(state: SailingState, st: PersonState, store: DataStore,
              heading: str = "") -> float:
    """§4.2/§4.4: a successful tile move advances the clock by
    ``1 / effective_speed(heading)`` days. The heading-less form (the
    docking charge) is the HUD-average cost. A fleet with no speed at all
    (furled) costs nothing: callers gate the move itself on
    ``effective_speed(heading) > 0``."""
    speed = effective_speed(state, st, store, heading)
    if speed <= 0:
        return 0.0
    return 1.0 / float(speed)


def speed_knots(state: SailingState, st: PersonState,
                store: DataStore) -> float:
    """The HUD speed in knots: ``tiles/day × 5 nm ÷ 24 h``, snapped to one
    decimal. Display-only."""
    return knots_text_value(effective_speed(state, st, store))


def knots_text_value(tiles_per_day: int) -> float:
    """The knot conversion for an arbitrary tiles/day figure (one
    decimal, Godot ``snappedf`` semantics)."""
    raw = float(tiles_per_day) * NM_PER_TILE / HOURS_PER_DAY
    return _round_half_away(raw / 0.1) * 0.1


def knots_text_for(tiles_per_day: int) -> str:
    """Pre-formatted one-decimal knots text (16/20/24 → "3.3"/"4.2"/"5.0")."""
    return f"{knots_text_value(tiles_per_day):.1f}"


def _ship_class_of(ship: dict[str, Any], store: DataStore | None = None
                   ) -> str:
    """Propulsion class of one ship instance (its ShipType ``class``),
    ``""`` unknown."""
    active = store if store is not None else data()
    ship_type = active.get_ship_type(str(ship.get("ship_type_id", "")))
    return str(ship_type.get("class", ""))


# --- Storm damage (§4.7, §4.17) ----------------------------------------------


def storm_damage_for(durability_max: int, st: PersonState,
                     extra_multiplier: float = 1.0) -> int:
    """§4.7 storm damage for one hull: ``ceil(durability_max × 0.05)``,
    with the continuous luck mitigation (Phase 8: × ``1 − luck / 250``)
    applied **before** rounding, plus the §4.17 trim ``extra_multiplier``
    inside the same pre-rounding expression. The epsilon absorbs binary
    float noise (140 × 0.05 must still ceil to 7)."""
    if durability_max <= 0:
        return 0
    raw = float(durability_max) * STORM_DAMAGE_FRACTION \
        * storm_luck_multiplier(st) * extra_multiplier
    raw = math.ceil(raw - STORM_DAMAGE_EPSILON)
    return max(0, int(raw))


def apply_storm_damage(state: SailingState, st: PersonState,
                       store: DataStore | None = None) -> int:
    """Applies one storm day to every ship and returns the total damage
    dealt. Durability clamps at 0 and never goes negative; sinking itself
    is step 5's (it only needs to see the 0). Each hull's damage carries
    the §4.17 trim multiplier for its own class. Emits the fleet_changed
    hook when anything changed."""
    total = 0
    trim = sail_trim(state)
    state.last_day_storm_damage = []
    for ship in state.fleet:
        if not isinstance(ship, dict):
            continue
        before = int(ship.get("durability", 0))
        ship_class = _ship_class_of(ship, store)
        damage = storm_damage_for(
            fleet_lib.ship_stat(ship, "durability"), st,
            trim_storm_multiplier(trim, ship_class))
        after = max(0, before - damage)
        if after != before:
            ship["durability"] = after
            total += before - after
            state.last_day_storm_damage.append({
                "ship_type_id": str(ship.get("ship_type_id", "")),
                "points": before - after,
            })
    if total > 0 and state.on_fleet_changed is not None:
        state.on_fleet_changed()
    return total


# --- Weather (§4.7, 50-* §4.2) -----------------------------------------------


def weather_zone_for(tile: tuple[int, int]) -> str:
    """§4.7: latitude band id for a tile, from ``lat = 90 − y / 12``.
    Total function: ``|lat| ≥ 70`` also returns ``boreal`` (the ice band —
    a real fleet never rolls there); ``x`` is irrelevant (zonal bands)."""
    latitude_degrees = 90.0 - float(tile[1]) / float(TILES_PER_DEGREE)
    return weather_zone_for_latitude(latitude_degrees)


def weather_zone_for_latitude(latitude_degrees: float) -> str:
    """The band lookup behind :func:`weather_zone_for`. Locked edges:
    ``< 8`` doldrums, ``8 ≤ |lat| < 30`` trade winds, ``30 ≤ |lat| < 40``
    variables, ``40 ≤ |lat| < 60`` westerlies, ``60 ≤ |lat|`` boreal."""
    absolute = abs(latitude_degrees)
    if absolute < 8.0:
        return "doldrums"
    if absolute < 30.0:
        return "trade_winds"
    if absolute < 40.0:
        return "variables"
    if absolute < 60.0:
        return "westerlies"
    return "boreal"


def zone_probabilities(zone: str, st: PersonState) -> dict[str, float]:
    """Outcome probabilities for ``zone`` with the §4.2 luck term applied.

    **Redistribution method (normative).** Only the storm chance is
    scaled: ``storm' = storm × (1 − luck/400)``; the freed mass is handed
    back to the three non-storm outcomes proportionally to their base
    weights (``scale = (1 − storm') / (1 − base_storm)``), so the four
    entries still sum to 1.0 and their relative shares are unchanged. At
    luck 0 this returns the §4.7 table untouched.
    """
    base = WEATHER_ZONES.get(zone, WEATHER_ZONES[DEFAULT_WEATHER_ZONE])
    base_storm = float(base["storm"])
    storm = _clampf(
        base_storm * character.storm_chance_multiplier(st), 0.0, base_storm)
    scale = (1.0 - storm) / (1.0 - base_storm)
    out = {"storm": storm}
    for outcome in ("calm", "fair", "strong"):
        out[outcome] = float(base[outcome]) * scale
    return out


def roll_weather(state: SailingState, st: PersonState,
                 tile: tuple[int, int]) -> str:
    """Rolls one day's weather strength for ``tile`` — a single uniform
    draw over the cumulative sums of :func:`zone_probabilities` in the
    fixed :data:`WEATHER_OUTCOMES` order. Draw 1 of ledger step 3 (the
    direction roll follows on the same stream)."""
    zone = weather_zone_for(tile)
    probabilities = zone_probabilities(zone, st)
    roll = state.weather_rng.randf()
    cumulative = 0.0
    outcome = "storm"
    for candidate in WEATHER_OUTCOMES:
        cumulative += float(probabilities.get(candidate, 0.0))
        if roll < cumulative:
            outcome = candidate
            break
    state.last_weather_zone = zone
    return outcome


def roll_wind_direction(state: SailingState, tile: tuple[int, int],
                        month: int, weather: str,
                        ocean: OceanLayers | None = None) -> str:
    """The second half of ledger step 3 — **the strength roll happens
    first, then this**, both drawn from the same seeded stream in that
    pinned order (§4.5/§4.7.1).

    **Pinned draw sequence (stable contract — never reorder):**
      1. ``prevailing`` — the region's month token (no RNG; ``VAR``
         fallback on uncovered water).
      2. ``weather == "storm"`` or ``prevailing == "VAR"``: exactly one
         draw ``randi_range(0, 7)`` → uniform over all 8 (a VAR day's
         jitter table deliberately does not apply).
      3. Otherwise draw A ``randf()`` — the prevailing direction is kept
         when ``roll < keep`` (calm 0.60 / fair 0.70 / strong 0.60).
      4. On a miss, draw B ``randi_range(0, len(offsets) − 1)`` indexes the
         pinned offset table (calm/strong ``[+1, −1, +2, −2]``, fair
         ``[+1, −1]``).

    The result is persisted as ``world["wind_dir"]`` and returned.
    """
    prevailing: str = _ocean(ocean).prevailing_for(tile[0], tile[1], month)
    state.last_wind_prevailing = prevailing
    jitter = WIND_JITTER.get(weather, WIND_JITTER[DEFAULT_WIND_JITTER])
    if weather == "storm" or prevailing == "VAR":
        # Storm never keeps the prevailing direction; VAR has none to keep.
        result = COMPASS_DIRS[state.weather_rng.randi_range(0, 7)]
    else:
        if state.weather_rng.randf() < float(jitter["keep"]):
            result = prevailing
        else:
            offsets: list[Any] = jitter["offsets"]
            offset = offsets[state.weather_rng.randi_range(0, len(offsets) - 1)]
            result = COMPASS_DIRS[(heading_index(prevailing) + int(offset)) % 8]
    state.world["wind_dir"] = result
    return result


# --- Calendar (§4.15) / clock (§4.3) -----------------------------------------


def year_for(day: int) -> int:
    """§4.15: ``year(day) = floor((day − 1) / 360) + 1``. Day 1 is Year 1
    Month 1."""
    return int(math.floor(float(day - 1) / 360.0)) + 1


def month_for(day: int) -> int:
    """§4.15: ``month(day) = floor(((day − 1) mod 360) / 30) + 1`` — the
    mod keeps the 12-month lattice anchored at day 1 even for ``day ≤ 0``
    fixtures."""
    return int(math.floor(float((day - 1) % (MONTH_DAYS * YEAR_MONTHS))
                          / float(MONTH_DAYS))) + 1


def time_of_day_minutes(state: SailingState) -> int:
    """§4.3: ``floor(clock_fraction × 1440)``, clamped to ``[0, 1439]`` —
    23:59 is the last minute shown, the day rolls over at 00:00."""
    fraction = float(state.world.get("clock_fraction", 0.0))
    return _clampi(int(math.floor(fraction * 1440.0)), 0, 1439)


def clock_text(state: SailingState) -> str:
    """The ``HH:MM`` wall-clock text for the current sub-day clock."""
    minutes = time_of_day_minutes(state)
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


# --- Compass domain (§4.4) ---------------------------------------------------


def heading_of_delta(delta: tuple[int, int]) -> str:
    """The 8-dir id of a one-tile move delta, or ``""`` when the delta is
    not an 8-direction step. The single place a move delta becomes a
    heading."""
    try:
        index = COMPASS_DELTAS.index(delta)
    except ValueError:
        return ""
    return COMPASS_DIRS[index]


def heading_index(heading: str) -> int:
    """Index (0..7) of a compass id, or −1 outside the 8-dir domain."""
    try:
        return COMPASS_DIRS.index(heading)
    except ValueError:
        return -1


def angle_between_dirs(a: str, b: str) -> int:
    """Angle between two 8-dir ids in degrees — exactly one of
    0/45/90/135/180. Unknown ids return −1."""
    ia = heading_index(a)
    ib = heading_index(b)
    if ia < 0 or ib < 0:
        return -1
    diff = abs(ia - ib) % 8
    return min(diff, 8 - diff) * 45


# --- Days of supply (§4.10, §4.11.2) -----------------------------------------


def daily_need(crew: int) -> int:
    """``need = ceil(crew / RATION_SIZE)`` units of provisions **and** the
    same of water per day at sea. Zero crew needs 0 — the caller must
    consult :func:`supply_block_reason` before dividing."""
    if crew <= 0:
        return 0
    return int(math.ceil(float(crew) / float(RATION_SIZE)))


def supply_days(provisions: int, water: int, crew: int) -> int:
    """§4.10, the **locked** days-of-supply readout:
    ``days = min(floor(provisions / need), floor(water / need))``. Returns
    0 when ``need`` is 0 (no crew)."""
    need = daily_need(crew)
    if need <= 0:
        return 0
    return min(
        int(math.floor(float(max(provisions, 0)) / float(need))),
        int(math.floor(float(max(water, 0)) / float(need))),
    )


def fleet_supply_days(state: SailingState) -> int:
    """Days of supply for the **pooled** fleet (§4.10 totals row)."""
    return supply_days(
        fleet_lib.supplies(state.fleet, "provisions"),
        fleet_lib.supplies(state.fleet, "water"),
        fleet_lib.total_crew(state.fleet),
    )


def kind_supply_days(state: SailingState, kind: str) -> int:
    """Days of supply for **one kind** against the pooled crew (the
    per-kind half of the §4.10 readout). 0 when there is no crew."""
    need = daily_need(fleet_lib.total_crew(state.fleet))
    if need <= 0:
        return 0
    return int(math.floor(float(max(fleet_lib.supplies(state.fleet, kind), 0))
                          / float(need)))


def supply_block_reason(state: SailingState) -> str:
    """ui_strings key explaining why the fleet may not leave port, ``""``
    when the sailing gate is open (§4.11.2, locked): ``total_crew >= 1``
    else ``port.sail.no_crew``; ``days >= 1`` else ``port.sail.no_supply``.
    The crew check comes first because ``days`` is meaningless with no
    crew. Every caller asks this one function."""
    if fleet_lib.total_crew(state.fleet) < 1:
        return "port.sail.no_crew"
    if fleet_supply_days(state) < 1:
        return "port.sail.no_supply"
    return ""


# --- Movement (§4.1, §4.2, §4.18, §6) ----------------------------------------


def ice_blocks_entry(state: SailingState, st: PersonState,
                     cell: tuple[int, int],
                     ocean: OceanLayers | None = None) -> bool:
    """§4.18 gate: true when ``cell`` is inside an in-month seasonal-ice
    polygon. A run without a day (``day ≤ 0`` fixtures) has no calendar
    yet, so the check is skipped."""
    if st.day <= 0:
        return False
    return _ocean(ocean).ice_blocks(cell[0], cell[1], month_for(st.day))


def is_move_legal(state: SailingState, st: PersonState,
                  from_cell: tuple[int, int], to_cell: tuple[int, int],
                  world: WorldRaster | None = None,
                  ocean: OceanLayers | None = None) -> bool:
    """True when the fleet at ``from_cell`` may step onto ``to_cell``.

    * one of the 8 grid directions, never a teleport or a stay-put;
    * the target must be in bounds and passable (``~``/``.``);
    * **no corner cutting:** a diagonal is blocked when either orthogonal
      neighbour of the target corner is impassable (§4.2/§6);
    * **§4.18 seasonal ice refuses entry:** an in-month ice tile is
      impassable to *entering* (only the target is checked — a tile
      freezing under a standing fleet never traps it).

    Sets ``state.last_move_blocked_key`` (``""`` for a legal move or any
    ordinary block; :data:`ICE_BLOCKED_KEY` on the ice refusal), reset on
    every evaluation.
    """
    state.last_move_blocked_key = ""
    dx = to_cell[0] - from_cell[0]
    dy = to_cell[1] - from_cell[1]
    if dx == 0 and dy == 0:
        return False
    if abs(dx) > 1 or abs(dy) > 1:
        return False
    world_map = _world(world)
    if world_map is None:  # pragma: no cover - the singleton always builds
        return False
    if not world_map.is_passable(to_cell[0], to_cell[1]):
        return False
    if dx != 0 and dy != 0:
        if not world_map.is_passable(from_cell[0] + dx, from_cell[1]):
            return False
        if not world_map.is_passable(from_cell[0], from_cell[1] + dy):
            return False
    if ice_blocks_entry(state, st, to_cell, ocean):
        state.last_move_blocked_key = ICE_BLOCKED_KEY
        return False
    return True


def try_move(state: SailingState, st: PersonState, store: DataStore,
             economy_state: EconomyState, to_cell: tuple[int, int],
             from_cell: tuple[int, int] | None = None,
             world: WorldRaster | None = None,
             ocean: OceanLayers | None = None,
             allegiance_state: AllegianceState | None = None) -> bool:
    """Applies one fleet move to ``to_cell``.

    A rejected move changes nothing at all — position **and** clock stay
    bit-identical (§4.2 "Blocked moves cost nothing"). Returns true only
    when the fleet actually moved and the clock advanced. Deliberately
    state-only (§4.11 port entry is :func:`try_step`/:func:`dock_at`'s
    job): never touches ``known_ports``/``current_port``.

    Phase 6: the clock cost is the heading-aware ``move_cost(heading)``;
    Phase 8: the night slow doubles it (the move's START time keys the
    cost); a furled sail/hybrid fleet (§4.17) cannot move — the refusal
    costs nothing, like any blocked move.
    """
    origin = world_tile(state) if from_cell is None else from_cell
    if not is_move_legal(state, st, origin, to_cell, world, ocean):
        return False
    heading = heading_of_delta((to_cell[0] - origin[0],
                                to_cell[1] - origin[1]))
    if effective_speed(state, st, store, heading, ocean, world) <= 0:
        # Furled (§4.17): sails in, no way on. No clock cost, no move.
        return False
    set_world_tile(state, to_cell[0], to_cell[1])
    advance_clock(state, st, store, economy_state,
                  step_move_cost(state, st, store, heading),
                  world=world, ocean=ocean,
                  allegiance_state=allegiance_state)
    return True


def wait_at_sea(state: SailingState, st: PersonState, store: DataStore,
                economy_state: EconomyState,
                allegiance_state: AllegianceState | None = None,
                world: WorldRaster | None = None,
                ocean: OceanLayers | None = None) -> bool:
    """The §4.17 wait: hold position and advance exactly 1 day via
    ``advance_clock(1.0)`` — the full ledger runs. Works in both input
    modes **regardless of trim** (a furled fleet can still wait). Refused
    while docked (a port day is :func:`advance_port_day`'s business)."""
    if in_port(state):
        return False
    advance_clock(state, st, store, economy_state, 1.0,
                  allegiance_state=allegiance_state, world=world, ocean=ocean)
    return True


# --- Clock (§4.3) ------------------------------------------------------------


def advance_clock(state: SailingState, st: PersonState, store: DataStore,
                  economy_state: EconomyState, days: float,
                  allegiance_state: AllegianceState | None = None,
                  world: WorldRaster | None = None,
                  ocean: OceanLayers | None = None) -> int:
    """Adds ``days`` to the fractional clock and ticks every completed day
    (§4.3, the locked listener order).

    Each tick: subtract 1 from the accumulator, ``day += 1``, then run
    strictly in order — the daily ledger (§4.5), the economy step (whose
    moved ports fire the ``market_changed`` hook), the allegiance month
    boundary on ``day % 30 == 1``, the drift push (Drift mode, at sea
    only), the ``day_advanced`` hook (the caller's ecology-tick seam), and
    a break on game over. The running remainder is written back **before**
    the ledger runs, so every listener observes the post-advance fraction.
    Returns the number of days advanced. ``clock_changed`` fires once per
    consuming call, sub-day advances included.
    """
    if days <= 0.0:
        return 0
    # A new run / save load clears the previous run's transients before the
    # game-over gate below can see them.
    _maybe_reset_for_new_run(state, st)
    # §4.9: a dead run's clock is frozen (S9 is on screen; nothing may tick).
    if is_game_over(state):
        return 0
    fraction = float(state.world.get("clock_fraction", 0.0)) + days
    ticks = 0
    while fraction >= 1.0 - CLOCK_EPSILON:
        fraction = max(0.0, fraction - 1.0)
        st.day += 1
        ticks += 1
        state.world["clock_fraction"] = _clampf(fraction, 0.0, 0.999999999)
        _run_daily_ledger(state, st, store, economy_state, allegiance_state,
                          world, ocean)
        # §4.3 order: the economy step runs after the ledger and before the
        # day_advanced listeners (docs/90 §5.4). Sea days and port
        # day-advances share this tick path.
        for changed_port in economy_day_tick(economy_state, store):
            if state.on_market_changed is not None:
                state.on_market_changed(str(changed_port))
        # Phase 7 month boundary (docs/90 §5.4 — one seam, one owner): the
        # day that just ticked INTO a new month runs the allegiance month
        # tick. Skipped when the caller runs no allegiance state.
        if st.day % MONTH_DAYS == 1 and allegiance_state is not None:
            month_tick(store, allegiance_state, st)
        # §4.3 drift-push position (locked, Phase 6): after the economy step
        # and immediately before day_advanced — deterministic and pure.
        _apply_drift_push(state, st, world, ocean)
        if state.on_day_advanced is not None:
            state.on_day_advanced(st.day)
        # §4.9: a run that just died does not tick further days.
        if is_game_over(state):
            break
    # §4.3: the accumulator invariant is [0, 1); the clamp also absorbs the
    # tiny negative produced by the epsilon.
    state.world["clock_fraction"] = _clampf(fraction, 0.0, 0.999999999)
    # Port-hours amendment (§4.3): every time-consuming call refreshes the
    # HH:MM surfaces exactly once.
    if state.on_clock_changed is not None:
        state.on_clock_changed()
    return ticks


def advance_port_day(state: SailingState, st: PersonState, store: DataStore,
                     economy_state: EconomyState,
                     allegiance_state: AllegianceState | None = None,
                     world: WorldRaster | None = None,
                     ocean: OceanLayers | None = None) -> int:
    """Port-side day advance (§4.3): it runs the **same** ledger as a sea
    day — wages are paid in port too, while the consumption step is
    sea-only (§4.5 port-day amendment). Returns the days advanced."""
    return advance_clock(state, st, store, economy_state, 1.0,
                         allegiance_state=allegiance_state, world=world,
                         ocean=ocean)


def advance_port_hours(state: SailingState, st: PersonState, store: DataStore,
                       economy_state: EconomyState, hours: int,
                       allegiance_state: AllegianceState | None = None,
                       world: WorldRaster | None = None,
                       ocean: OceanLayers | None = None) -> int:
    """Hour-scale port time (§4.3, §4.1b): ``h`` hours through the one
    clock seam. A sub-day advance runs no ledger; crossing midnight runs
    the full day-tick sequence exactly like a sea day. Refused (0) while
    the run is dead."""
    if hours <= 0:
        return 0
    return advance_clock(state, st, store, economy_state,
                         float(hours) / 24.0,
                         allegiance_state=allegiance_state, world=world,
                         ocean=ocean)


def in_port(state: SailingState) -> bool:
    """True while docked (§4.3/§4.11). The ledger is shared; only the
    at-sea-only rules branch on this."""
    return state.current_port is not None


def docked_port_id(state: SailingState) -> str:
    """The docked port id, else ``""``."""
    value = state.current_port
    return value if isinstance(value, str) else ""


# --- Facility hours (§4.1b, 30-*; amended 2026-11-02) ------------------------


def _window_minutes(text: str) -> int:
    """``"HH:MM"`` → minutes. Out-of-range text reads as midnight so a
    malformed window can never lock a door."""
    parts = text.split(":")
    if len(parts) != 2:
        return 0
    try:
        return int(parts[0]) * 60 + int(parts[1])
    except ValueError:
        return 0


def _facility_window(store: DataStore, port_id: str,
                     facility_id: str) -> Any:
    """The facility's window entry (default table, then the port
    override); ``None`` when unlisted."""
    table: dict[str, Any] = store.facility_hours
    window = table.get("default", {}).get(facility_id)
    overrides: dict[str, Any] = table.get("overrides", {})
    override = overrides.get(port_id)
    if isinstance(override, dict) and facility_id in override:
        window = override[facility_id]
    return window


def facility_open(store: DataStore, state: SailingState, port_id: str,
                  facility_id: str) -> bool:
    """True when ``facility_id`` at ``port_id`` is open at the **current**
    time of day (§4.1b closed rule). A missing table, port or facility
    falls back to **always open** — a bad data file can never seal every
    port shut. The window check is ``[open, close)`` on minutes; ``"24h"``
    is always true."""
    table: dict[str, Any] = store.facility_hours
    if not table:
        return True
    window = _facility_window(store, port_id, facility_id)
    if window is None:
        return True
    if not isinstance(window, list) or len(window) != 2:
        # "24h" (the inn) and any malformed entry read as always open.
        return True
    now = time_of_day_minutes(state)
    return _window_minutes(str(window[0])) <= now \
        and now < _window_minutes(str(window[1]))


def facility_window_text(store: DataStore, port_id: str,
                         facility_id: str) -> dict[str, str]:
    """The facility's window as ``{"open", "close"}`` display strings
    (``{}`` when always open or unknown) — the hub card's status line
    values."""
    window = _facility_window(store, port_id, facility_id)
    if isinstance(window, list) and len(window) == 2:
        return {"open": str(window[0]), "close": str(window[1])}
    return {}


# --- Drift push (§4.3 step 3 / §4.16, Drift mode only) -----------------------


def drift_mode_active(state: SailingState) -> bool:
    """The current-mode selection, guard-read with the documented default
    ``"modifier"``. Only ``"drift"`` swaps the current factor for the
    daily push."""
    prefs = state.control_prefs
    if isinstance(prefs, dict):
        return str(prefs.get("current_mode", "modifier")) == "drift"
    return False


def _apply_drift_push(state: SailingState, st: PersonState,
                      world: WorldRaster | None = None,
                      ocean: OceanLayers | None = None) -> None:
    """§4.3 step 3 (locked position): after the economy step, immediately
    before ``day_advanced``. Drift mode only, at sea only: the fleet is
    pushed along the decoded (reversal-applied) current vector —
    :data:`DRIFT_TILES_PER_DAY` tiles per day by strength, whole tiles
    only; the strength-1 remainder accrues in ``state.drift_accumulator``.
    Wrap-aware on x; the push **stops before impassable tiles** (land,
    reef, permanent ``I``, in-month seasonal ice) — it never lands the
    fleet on one and deals no damage; the unspent remainder is absorbed.
    Suppressed while docked (the accumulator resets there)."""
    if in_port(state):
        state.drift_accumulator = 0.0
        return
    if is_game_over(state) or not drift_mode_active(state):
        return
    ocean = _ocean(ocean)
    world_map = _world(world)
    cell = world_tile(state)
    current = ocean.current_at(cell[0], cell[1], month_for(st.day))
    if not current:
        return
    dir_index = heading_index(str(current["dir"]))
    if dir_index < 0:
        return
    state.drift_accumulator += float(DRIFT_TILES_PER_DAY.get(
        int(current["strength"]), 0.0))
    month = month_for(st.day)
    while state.drift_accumulator >= 1.0 - CLOCK_EPSILON:
        dx, dy = COMPASS_DELTAS[dir_index]
        candidate = (cell[0] + dx, cell[1] + dy)
        blocked = True
        if world_map.is_passable(candidate[0], candidate[1]) \
                and not ocean.ice_blocks(candidate[0], candidate[1], month):
            blocked = False
        if blocked:
            # Stop at the last passable tile; the remainder is absorbed.
            state.drift_accumulator = 0.0
            return
        set_world_tile(state, candidate[0], candidate[1])
        cell = candidate
        state.drift_accumulator -= 1.0


# --- Daily ledger (§4.5, strict order) ---------------------------------------


def _run_daily_ledger(state: SailingState, st: PersonState, store: DataStore,
                      economy_state: EconomyState,
                      allegiance_state: AllegianceState | None,
                      world: WorldRaster | None,
                      ocean: OceanLayers | None) -> None:
    """Daily ledger, §4.5 order. Called by :func:`advance_clock` once per
    completed day, *before* ``day_advanced`` fires, so every listener
    observes a finished day (§4.3).

    Steps 1–6 in the pinned order: consumption → wages → weather (the
    two-part roll strength → direction) → morale → fail states → mutiny.
    The chain short-circuits: step 4/5 return false when the run ended, so
    no later step and no later day runs (§4.9).
    """
    if is_game_over(state):
        return
    _ledger_consumption(state)                                   # step 1
    _ledger_wages(state, st, store)                              # step 2
    _ledger_weather(state, st, store, ocean)                     # step 3
    if _ledger_morale(state, st, store):                         # step 4
        if _ledger_fail_states(state, st, store):                # step 5
            _ledger_mutiny(state, st)                            # step 6
    state._last_run_day = st.day


def _ledger_consumption(state: SailingState) -> None:
    """§4.5 step 1 — consumption. ``need = ceil(total_crew / RATION_SIZE)``
    units of provisions **and** the same of water; the stock is drained
    flagship-first (40-* §4.2 pooling) and a shortage is recorded for step
    5. **Sea ledger days only** (port-day amendment): a docked ledger day
    consumes nothing — supplies are bought ashore — and records the
    all-false shortfall shape, which is what resets the §4.9 counters.
    Wages (step 2) still run on port days."""
    crew = fleet_lib.total_crew(state.fleet)
    state.last_day_shortfalls = {"provisions": False, "water": False}
    if in_port(state):
        return
    need = 0 if crew <= 0 else int(math.ceil(float(crew) / float(RATION_SIZE)))
    if need <= 0:
        return  # Crew 0: nothing to feed, no shortage (§4.9 crew floor).
    ate = False
    for kind in ("provisions", "water"):
        stock = fleet_lib.supplies(state.fleet, kind)
        if stock < need:
            state.last_day_shortfalls[kind] = True
        # Clamp the drain at the stock on hand: a shortage consumes to 0.
        if fleet_lib.remove_supplies(state.fleet, kind, min(need, stock)) > 0:
            ate = True
    if ate and state.on_fleet_changed is not None:
        state.on_fleet_changed()


def _ledger_wages(state: SailingState, st: PersonState,
                  store: DataStore) -> None:
    """§4.5 step 2 — wages. ``gold -= total_crew × CREW_WAGE_DAILY + Σ
    officer.wage_daily``; a negative result clamps to 0 and raises the
    unpaid flag (§4.8.1 "wages unpaid −5"). Exactly ``wages == gold`` is
    still paid (the doc's condition is ``< 0``, not ``≤ 0``). The HUD must
    never see negative gold: one ``gold_changed`` fires with the clamped
    value, only when gold actually changed."""
    wages = fleet_lib.total_crew(state.fleet) * CREW_WAGE_DAILY \
        + character.officer_wages(st, store)
    state.last_day_wages = wages
    state.last_day_unpaid_wages = False
    if wages <= 0:
        return
    before = st.gold
    if before - wages < 0:
        state.last_day_unpaid_wages = True
    st.gold = max(0, before - wages)
    if st.gold != before and state.on_gold_changed is not None:
        state.on_gold_changed(st.gold)


def _ledger_weather(state: SailingState, st: PersonState, store: DataStore,
                    ocean: OceanLayers | None) -> None:
    """§4.5 step 3 — the **two-part weather roll** (§4.7 + §4.7.1): the
    strength roll draws first, then the wind-direction roll, one seeded
    stream, pinned order strength → direction. Writes ``world["weather"]``
    and ``world["wind_dir"]`` and, on a storm, damages every hull and
    raises ``last_day_storm`` for step 4. Runs in port too (the roll is a
    property of the zone); in port the storm contributes no morale row."""
    tile = world_tile(state)
    outcome = roll_weather(state, st, tile)
    roll_wind_direction(state, tile, month_for(st.day), outcome, ocean)
    state.world["weather"] = outcome
    state.last_day_storm = outcome == "storm"
    if state.last_day_storm:
        apply_storm_damage(state, st, store)


def _ledger_morale(state: SailingState, st: PersonState,
                   store: DataStore) -> bool:
    """§4.5 step 4 — morale. Builds the §4.8.1 delta and applies it,
    clamped to [0, 100]. Returns true so the chain can reach step 5/6.

    In port the +5 replaces the sea rows, and the cap is a ceiling on the
    *gain*, never on a loss. The unpaid-wages row applies on any day the
    clamp fired, in port included. At sea the step also carries the 50-*
    §4.3 growth seam: ``Skills.note_sea_day()`` (skill usage + the officer
    day tick) and the +2 XP award — never on a port day advance. (The
    §2.5 officer advice roll shares the GDScript call site — the advice
    port is a declared seam.)
    """
    delta = MORALE_SEA_DAILY if not in_port(state) else MORALE_PORT_DAILY
    before = state.morale
    if not in_port(state):
        if state.last_day_shortfalls.get("provisions", False):
            delta += MORALE_SHORTFALL
        if state.last_day_shortfalls.get("water", False):
            delta += MORALE_SHORTFALL
        if state.last_day_storm:
            delta += storm_morale_delta(st)
        # 40-* §4.4 captain-less rule (Phase 8): −2 additional while any
        # escort lacks its in-post captain (once per day, not per ship).
        if captain_less_count(state, st) > 0:
            delta += MORALE_CAPTAIN_LESS
        # docs/50-* §4.3: +2 XP per day tick at sea only, with the
        # Phase-8 growth seam (skill usage + officer sea-days).
        if st.player:
            skills.note_sea_day(st, store)
            character.award_xp(st, 2)
    if state.last_day_unpaid_wages:
        delta += MORALE_UNPAID_WAGES

    state.last_morale_delta = delta
    after = before + delta
    if in_port(state) and delta > 0:
        # §4.8.1 "up to the port cap 80": the cap bounds the *rise*; a
        # decrease is never pulled back up to it.
        after = min(after, max(before, MORALE_PORT_CAP))
    state.morale = _clampi(after, MORALE_MIN, MORALE_MAX)
    return True


# --- Ledger step 5: fail states (§4.9) ---------------------------------------


def _ledger_fail_states(state: SailingState, st: PersonState,
                        store: DataStore) -> bool:
    """§4.5 step 5 — fail states, in the documented order: **sinking,
    starvation, scurvy**. Returns false when the run ended, so step 6 and
    every later day are skipped."""
    if _resolve_sinking(state):
        return False
    return _advance_starvation_and_scurvy(state, st, store)


def _resolve_sinking(state: SailingState) -> bool:
    """Sinking (§4.9, 40-* §4.4). A hull at durability ≤ 0:
    non-flagship → hull and cargo lost, ``world.ship_lost`` dialog;
    flagship with escorts → crew/provisions/water/cargo relocate to the
    next ship up to capacity (overflow lost), it becomes flagship, and
    ``world.flagship_lost`` is raised; flagship alone →
    ``game_over("sunk")``. Returns true when a game over fired. An empty
    fleet is the harbor-relief state (50-* §4.7), not a sinking."""
    if not state.fleet:
        return False
    flagship = fleet_lib.flagship(state.fleet)
    if int(flagship.get("durability", 0)) <= 0:
        if len(state.fleet) <= 1:
            return _fire_game_over(state, "sunk")
        _relocate_flagship_to_escort(state)
        _queue_dialog(state, "sinking", "world.flagship_lost")
        if state.on_fleet_changed is not None:
            state.on_fleet_changed()
        return False

    lost_escort = False
    for index in range(len(state.fleet) - 1, 0, -1):
        ship = state.fleet[index]
        if not isinstance(ship, dict):
            continue
        if int(ship.get("durability", 0)) > 0:
            continue
        del state.fleet[index]
        lost_escort = True
    if lost_escort:
        _queue_dialog(state, "sinking", "world.ship_lost")
        if state.on_fleet_changed is not None:
            state.on_fleet_changed()
    return False


def _relocate_flagship_to_escort(state: SailingState) -> None:
    """40-* §4.4 flagship replacement: the next ship takes the crew (capped
    at its ``crew_max``), then provisions/water/goods up to its free
    capacity; what does not fit is lost with the old hull (the overflow is
    reported by the dialog, never silently — §6)."""
    old: dict[str, Any] = state.fleet[0]
    nxt: dict[str, Any] = state.fleet[1]
    crew = int(old.get("crew", 0))
    nxt["crew"] = min(int(nxt.get("crew", 0)) + crew,
                      fleet_lib.ship_stat(nxt, "crew_max"))
    for kind in ("provisions", "water"):
        room = max(0, fleet_lib.free_capacity(nxt))
        moved = min(int(old.get(kind, 0)), room)
        nxt[kind] = int(nxt.get(kind, 0)) + moved
    old_cargo: dict[str, Any] = old.get("cargo", {})
    next_cargo: dict[str, Any] = nxt.get("cargo", {})
    for good_id in old_cargo:
        room = max(0, fleet_lib.free_capacity(nxt))
        if room <= 0:
            break
        moved = min(int(old_cargo[good_id]), room)
        if moved > 0:
            next_cargo[good_id] = int(next_cargo.get(good_id, 0)) + moved
    nxt["cargo"] = next_cargo
    del state.fleet[0]


def _advance_starvation_and_scurvy(state: SailingState, st: PersonState,
                                   store: DataStore) -> bool:
    """§4.9 starvation/scurvy counters and their crew loss. Each shortfall
    day advances its counter by one and costs ``max(1, floor(crew ×
    0.05))`` crew (floored at 1, §6); both counters reset on the first
    fully-supplied day. The morale −5 is step 4's shortfall row —
    deliberately **not** re-applied here. Returns false when a counter
    reached its game-over threshold (starvation's 7; scurvy's
    grace-extended one)."""
    provisions_short = state.last_day_shortfalls.get("provisions", False)
    water_short = state.last_day_shortfalls.get("water", False)
    # §4.9: "counters reset to 0 on the first fully-supplied day" — both.
    if not provisions_short and not water_short:
        state.starvation_days = 0
        state.scurvy_days = 0
        return True
    if provisions_short:
        state.starvation_days += 1
        _apply_crew_loss(state, STARVATION_CREW_LOSS_FRACTION)
    if water_short:
        state.scurvy_days += 1
        _apply_crew_loss(state, STARVATION_CREW_LOSS_FRACTION)
    if state.starvation_days >= STARVATION_LIMIT_DAYS:
        return _fire_game_over(state, "starvation")
    if state.scurvy_days >= scurvy_limit_days(st, store):
        return _fire_game_over(state, "scurvy")
    return True


def _apply_crew_loss(state: SailingState, fraction: float) -> int:
    """``crew -= max(1, floor(crew × fraction))``, never below
    :data:`CREW_FLOOR` (§6). Returns the crew actually lost."""
    ship = fleet_lib.flagship(state.fleet)
    if not ship:
        return 0
    crew = int(ship.get("crew", 0))
    if crew <= CREW_FLOOR:
        return 0
    loss = max(1, int(math.floor(float(crew) * fraction)))
    after = max(CREW_FLOOR, crew - loss)
    ship["crew"] = after
    if state.on_fleet_changed is not None:
        state.on_fleet_changed()
    return crew - after


# --- Ledger step 6: mutiny (§4.8.3) ------------------------------------------


def _ledger_mutiny(state: SailingState, st: PersonState) -> None:
    """§4.5 step 6 — mutiny check. At sea only, below
    :data:`MUTINY_THRESHOLD`: one draw of the **dedicated** mutiny stream
    against ``MUTINY_CHANCE_PER_DAY × charisma_loss_multiplier``. A hit
    stores the offer in ``pending_mutiny`` and queues the
    ``world.mutiny.text`` modal in the §4.7 dialog order (the offer travels
    with the dialog entry so the HUD can render the Pay price without
    reading sim state). A second offer never stacks: while one is pending
    the check is skipped."""
    if in_port(state) or is_game_over(state):
        return
    if state.pending_mutiny:
        return
    if not mutiny_is_possible(state):
        return
    chance = MUTINY_CHANCE_PER_DAY * charisma_loss_multiplier(st)
    if state.mutiny_rng.randf() >= chance:
        return
    state.pending_mutiny = mutiny_offer(state, st)
    _queue_dialog(state, "mutiny", "world.mutiny.text", {},
                  {"mutiny": True, "offer": dict(state.pending_mutiny)})


def mutiny_is_possible(state: SailingState) -> bool:
    """True when the §4.8.3 check would roll at all: at sea and strictly
    below :data:`MUTINY_THRESHOLD` (a fleet at exactly 20 is **not**
    mutinous)."""
    return not in_port(state) and state.morale < MUTINY_THRESHOLD


def mutiny_offer(state: SailingState, st: PersonState) -> dict[str, Any]:
    """The current §4.8.3 offer as ``{crew, gap, cost, can_pay,
    can_suppress, can_fizzle}``; ``can_fizzle`` is true exactly when
    neither other option is possible (unpaid **and** crew already at 1)."""
    crew = fleet_lib.total_crew(state.fleet)
    cost = crew * MUTINY_PAY_PER_CREW
    can_pay = st.gold >= cost
    can_suppress = crew > CREW_FLOOR
    return {
        "crew": crew,
        "gap": max(0, cost - st.gold),
        "cost": cost,
        "can_pay": can_pay,
        "can_suppress": can_suppress,
        "can_fizzle": not can_pay and not can_suppress,
    }


def resolve_mutiny_pay(state: SailingState, st: PersonState) -> bool:
    """§4.8.3 "Pay off": ``gold -= crew × 20``, morale = 50. False (state
    untouched) when nothing is pending or the purse is short."""
    if not state.pending_mutiny:
        return False
    offer = mutiny_offer(state, st)
    if not offer["can_pay"]:
        return False
    st.gold = max(0, st.gold - int(offer["cost"]))
    state.morale = _clampi(MUTINY_PAY_MORALE, MORALE_MIN, MORALE_MAX)
    state.pending_mutiny = {}
    if state.on_gold_changed is not None:
        state.on_gold_changed(st.gold)
    return True


def resolve_mutiny_suppress(state: SailingState, st: PersonState) -> bool:
    """§4.8.3 "Suppress": ``crew -= max(1, floor(crew × 0.30))`` (floored
    at 1), morale = 40. False when nothing is pending or the crew is
    already at 1."""
    if not state.pending_mutiny:
        return False
    offer = mutiny_offer(state, st)
    if not offer["can_suppress"]:
        return False
    ship = fleet_lib.flagship(state.fleet)
    crew = int(ship.get("crew", 0))
    ship["crew"] = max(CREW_FLOOR,
                       crew - max(1, int(math.floor(
                           float(crew) * MUTINY_SUPPRESS_FRACTION))))
    state.morale = _clampi(MUTINY_SUPPRESS_MORALE, MORALE_MIN, MORALE_MAX)
    state.pending_mutiny = {}
    if state.on_fleet_changed is not None:
        state.on_fleet_changed()
    return True


def resolve_mutiny_fizzle(state: SailingState, st: PersonState) -> None:
    """§4.8.3 fizzle: neither pay nor suppress is possible, the crowd
    disperses and morale rises by 5 (clamped to [0, 100]). Always succeeds
    when pending."""
    if not state.pending_mutiny:
        return
    state.morale = _clampi(state.morale + MUTINY_FIZZLE_MORALE,
                           MORALE_MIN, MORALE_MAX)
    state.pending_mutiny = {}
    _queue_dialog(state, "mutiny", "world.mutiny.fizzle")


# --- Desertion on port entry (§4.8.2) ----------------------------------------


def apply_desertion(state: SailingState, st: PersonState) -> int:
    """Every port entry with morale < :data:`DESERTION_THRESHOLD` costs
    ``max(1, floor(crew × 0.10 × charisma_loss_multiplier))`` crew,
    floored at 1 (Phase 8: charisma scales the loss). Returns the crew
    lost (0 when morale is 40+ — the check is ``< 40``, so exactly 40 is
    safe). Pure state, no dialog: the caller's port-entry sequence queues
    ``world.desertion`` in §4.7 order."""
    if state.morale >= DESERTION_THRESHOLD:
        return 0
    ship = fleet_lib.flagship(state.fleet)
    if not ship:
        return 0
    crew = int(ship.get("crew", 0))
    if crew <= CREW_FLOOR:
        return 0
    raw = float(crew) * DESERTION_FRACTION * charisma_loss_multiplier(st)
    loss = max(1, int(math.floor(raw)))
    after = max(CREW_FLOOR, crew - loss)
    ship["crew"] = after
    lost = crew - after
    if lost > 0 and state.on_fleet_changed is not None:
        state.on_fleet_changed()
    return lost


# --- Dialog queue order (80-* §4.7) ------------------------------------------


def sort_dialogs(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Stable sort of dialog entries by :data:`DIALOG_ORDER`:
    weather damage → sinking → mutiny → desertion → arrival greeting. Two
    entries of the same kind keep the order they were raised in (an
    insertion sort, mirroring the GDScript's explicit stability)."""
    out = list(entries)
    for index in range(1, len(out)):
        entry = out[index]
        rank = _dialog_rank(entry)
        cursor = index - 1
        while cursor >= 0 and _dialog_rank(out[cursor]) > rank:
            out[cursor + 1] = out[cursor]
            cursor -= 1
        out[cursor + 1] = entry
    return out


def _dialog_rank(entry: Any) -> int:
    if isinstance(entry, dict):
        return int(DIALOG_ORDER.get(str(entry.get("kind", "")),
                                    len(DIALOG_ORDER)))
    return len(DIALOG_ORDER)


def _queue_dialog(state: SailingState, kind: str, key: str,
                  values: dict[str, Any] | None = None,
                  extra: dict[str, Any] | None = None) -> None:
    """Appends one dialog to this tick's buffer. ``extra`` carries the
    optional presentation fields the HUD queue understands."""
    entry: dict[str, Any] = {"kind": kind, "key": key,
                             "values": values or {}}
    if extra:
        entry.update(extra)
    state.last_day_dialogs.append(entry)


def take_last_day_dialogs(state: SailingState) -> list[dict[str, Any]]:
    """Returns the tick's dialogs in §4.7 order and clears the buffer, so
    a scene can only ever show them once."""
    out = sort_dialogs(state.last_day_dialogs)
    state.last_day_dialogs = []
    return out


# --- Transient lifecycle ------------------------------------------------------


def reset_ledger_state(state: SailingState) -> None:
    """Clears every transient ledger field: §4.9 counters, the game-over
    flag, the per-tick dialog list, a pending mutiny offer, the step 1–3
    flags, the drift accumulator and the new-run detector. Fixtures call
    it so one scenario cannot leak into the next; a real new game is
    detected automatically by :func:`_maybe_reset_for_new_run`."""
    state.starvation_days = 0
    state.scurvy_days = 0
    state.last_morale_delta = 0
    state.last_day_dialogs = []
    state.pending_mutiny = {}
    state.game_over_reason = ""
    state.last_day_shortfalls = {"provisions": False, "water": False}
    state.last_day_unpaid_wages = False
    state.last_day_wages = 0
    state.last_day_storm = False
    state.last_day_storm_damage = []
    state.last_move_blocked_key = ""
    state.drift_accumulator = 0.0
    state.last_wind_prevailing = ""
    state.at_sea_repair_day = -1
    state._last_run_day = -1


def _maybe_reset_for_new_run(state: SailingState, st: PersonState) -> None:
    """A fresh run (``day`` reset to 1) must not inherit the previous
    run's counters or its sticky game-over flag: **any** backwards jump
    from the last ticked day means "new game or a save load", and resetting
    the non-persisted transients there is harmless."""
    if state._last_run_day >= 0 and st.day < state._last_run_day:
        reset_ledger_state(state)


def is_game_over(state: SailingState) -> bool:
    """True once ``game_over_reason`` has been set; the ledger never emits
    a second game over for the same run."""
    return state.game_over_reason != ""


def _fire_game_over(state: SailingState, reason: str) -> bool:
    """Fires the ``game_over`` hook once and records the reason. No save is
    written or deleted (§4.9). Always true so a fail-state check can
    ``return _fire_game_over(...)``."""
    if is_game_over(state):
        return True
    state.game_over_reason = reason
    if state.on_game_over is not None:
        state.on_game_over(reason)
    return True


# --- At-sea minor repair (40-* §4.5, Phase 8) --------------------------------


def _ship_at(state: SailingState, ship_index: int) -> dict[str, Any]:
    """``fleet[ship_index]`` as a non-empty dict, else ``{}``."""
    if ship_index < 0 or ship_index >= len(state.fleet):
        return {}
    ship = state.fleet[ship_index]
    return ship if isinstance(ship, dict) else {}


def effective_carpentry(st: PersonState, store: DataStore) -> int:
    """The in-post carpentry value behind the §4.5 gate — effective
    carpentry = player 0 + the in-post carpenter's value."""
    return skills.effective_skill(st, store, "carpentry")


def at_sea_repair_gate_met(st: PersonState, store: DataStore) -> bool:
    """True when the §4.5 carpenter gate is met (in-post carpentry ≥ 60)."""
    return effective_carpentry(st, store) >= AT_SEA_REPAIR_CARPENTRY_GATE


def at_sea_repair_fee(state: SailingState, st: PersonState, store: DataStore,
                      ship_index: int = 0) -> int:
    """The §4.5 fee of one at-sea minor repair on ``fleet[ship_index]``:
    ``10 × ceil(ShipType.base_price / 400)`` points at the §4.3 rate, under
    the carpenter discount, **floored once** — and without the §4.9.2
    count-title ×0.8, which is port-scoped. 0 for an unknown hull."""
    ship = _ship_at(state, ship_index)
    if not ship:
        return 0
    raw = AT_SEA_REPAIR_POINTS * int(repair_cost_per_point(
        str(ship.get("ship_type_id", ""))))
    return max(0, int(math.floor(float(raw) * carpenter_discount(st, store))))


def at_sea_repair_available(state: SailingState, st: PersonState,
                            store: DataStore, ship_index: int = 0) -> bool:
    """True when :func:`at_sea_repair` would succeed right now: at sea,
    run alive, gate met, a damaged target hull, the once-per-fleet-day
    guard open and the purse covering the fee."""
    if in_port(state) or is_game_over(state):
        return False
    if not at_sea_repair_gate_met(st, store):
        return False
    ship = _ship_at(state, ship_index)
    if not ship:
        return False
    maximum = int(ship_max_durability(state.fleet, ship_index))
    if maximum <= 0 or int(ship.get("durability", 0)) >= maximum:
        return False  # nothing to repair
    if state.at_sea_repair_day == st.day:
        return False
    return st.gold >= at_sea_repair_fee(state, st, store, ship_index)


def at_sea_repair(state: SailingState, st: PersonState, store: DataStore,
                  ship_index: int = 0) -> bool:
    """§4.5 "At-sea minor repair" (Phase 8): restores
    :data:`AT_SEA_REPAIR_POINTS` durability to ``fleet[ship_index]`` for
    the :func:`at_sea_repair_fee` gold — once per fleet-day, **no clock
    cost**, at sea only. False (state untouched) when any guard fails; the
    guards and their order are :func:`at_sea_repair_available`'s."""
    if not at_sea_repair_available(state, st, store, ship_index):
        return False
    ship = _ship_at(state, ship_index)
    maximum = int(ship_max_durability(state.fleet, ship_index))
    fee = at_sea_repair_fee(state, st, store, ship_index)
    ship["durability"] = min(
        int(ship.get("durability", 0)) + AT_SEA_REPAIR_POINTS, maximum)
    state.at_sea_repair_day = st.day
    st.gold = max(0, st.gold - fee)
    if state.on_gold_changed is not None:
        state.on_gold_changed(st.gold)
    if state.on_fleet_changed is not None:
        state.on_fleet_changed()
    return True


# --- §4.2 cadence + docking + port entry (world_map.gd's sim half) -----------
#
# The scene's render/marker/camera/contact halves stay scene-side; the
# RULES they carried live here. ``motion`` is the caller-owned cadence
# state (:class:`SailingMotion`).


def wrapped_delta(from_cell: tuple[int, int], target: tuple[int, int],
                  width: int) -> tuple[int, int]:
    """The signed delta from ``from_cell`` to ``target`` on the wrapping
    grid: ``x`` is reduced to ``[-width/2, width/2)`` via
    ``sail_path.short_dx`` so the seam is just another neighbour (§4.1)."""
    dy = target[1] - from_cell[1]
    return (sail_path.short_dx(from_cell[0], target[0], width), dy)


def step_is_legal(state: SailingState, st: PersonState,
                  from_cell: tuple[int, int], to_cell: tuple[int, int],
                  world: WorldRaster | None = None,
                  ocean: OceanLayers | None = None) -> bool:
    """True when ``to_cell`` is one legal §4.2 step from ``from_cell``
    (seam-aware). Used by the click-route walk, whose tiles are absolute
    world cells."""
    dx = to_cell[0] - from_cell[0]
    dy = to_cell[1] - from_cell[1]
    world_map = _world(world)
    dx = sail_path.short_dx(from_cell[0], to_cell[0], world_map.width)
    if max(abs(dx), abs(dy)) != 1:
        return False
    return is_move_legal(state, st, from_cell,
                         (from_cell[0] + dx, from_cell[1] + dy),
                         world, ocean)


def _port_or_empty(current_port: str | None) -> str:
    """``current_port`` as the ``last_departed_port`` string (``None`` →
    ``""`` — the save shape's default; the GDScript ``str(null)`` of an
    unset port)."""
    return current_port if current_port else ""


def try_step(state: SailingState, st: PersonState, store: DataStore,
             economy_state: EconomyState, motion: SailingMotion,
             target: tuple[int, int],
             world: WorldRaster | None = None,
             ocean: OceanLayers | None = None,
             allegiance_state: AllegianceState | None = None) -> bool:
    """Moves the fleet one tile if the move is legal (the §4.2 shared step
    path — step keys, the hold repeat, helm auto-steps and click-to-sail
    legs all funnel through here; "a step is a step wherever it comes
    from").

    x wraps (§4.1): the move is evaluated on the **short** delta (±1) and
    the stored cell is normalised afterwards. Docking (§4.11.1): heading
    into a port's **shore** tile is an interaction, not a step — detected
    before the legality test, and it requires **orthogonal** adjacency
    (the no-corner-cut rule in disguise). A rejected move leaves position
    **and** clock untouched. Returns true when the fleet actually stepped.

    Scene-side seams not ported: the NPC accrual/glides, the wreck
    collection, the fleet-contact check and the battle suspension of a
    route (the caller runs them after a successful step; the appointment
    cancel of §4.19 hooks the caller's manual-input path).
    """
    world_map = _world(world)
    fleet_cell = world_tile(state)
    delta = wrapped_delta(fleet_cell, target, world_map.width)
    if max(abs(delta[0]), abs(delta[1])) != 1:
        # Clicking a non-adjacent tile is a no-op, not a rejected move.
        return False
    step_target = (fleet_cell[0] + delta[0], fleet_cell[1] + delta[1])
    if docks(state, st, fleet_cell, target, world, ocean):
        return dock_at(state, st, store, economy_state, motion, target,
                       world, ocean, allegiance_state)
    if not is_move_legal(state, st, fleet_cell, step_target, world, ocean):
        return False

    # §4.17 anchor rule: a furled sail/hybrid fleet cannot move (§6). The
    # gate sits here so the refusal leaves position AND clock untouched
    # (the oracle's scene re-asserted the tile unconditionally after the
    # sim call — the doc-pinned "cannot move" rule wins; see the module
    # report's ambiguity note).
    heading = heading_of_delta(delta)
    if effective_speed(state, st, store, heading, ocean, world_map) <= 0:
        return False

    # Leaving the harbour (§4.11 exit): the departed port is recorded for
    # the Phase-5 hunter intel (60-* §4.11.11.1).
    state.world["last_departed_port"] = _port_or_empty(state.current_port)
    state.current_port = None

    # The stored cell: the un-normalised step target may be −1 or width at
    # the seam, which the move rule accepts but the save shape must not
    # contain (§4.1 "x taken mod width everywhere").
    landed = (step_target[0] % world_map.width, step_target[1])
    try_move(state, st, store, economy_state, step_target,
             from_cell=fleet_cell, world=world_map, ocean=ocean,
             allegiance_state=allegiance_state)
    # The sim stored the un-normalised cell; re-assert the wrapped one.
    set_world_tile(state, landed[0], landed[1])

    # §4.2 movement heading (amended 2026-11-06): the step's own 8-dir
    # delta IS the movement heading — every step source records it. A
    # refused move never reaches this line.
    if heading:
        state.world["heading"] = heading
    return True


def docks(state: SailingState, st: PersonState, from_cell: tuple[int, int],
          target: tuple[int, int], world: WorldRaster | None = None,
          ocean: OceanLayers | None = None) -> bool:
    """True when the pending step is a docking gesture: the target is a
    port's **shore** tile and the step is **orthogonal** (§4.11.1). A
    diagonal into the same land tile is never a dock — it stays an illegal
    move (the no-corner-cut rule)."""
    world_map = _world(world)
    dx = sail_path.short_dx(from_cell[0], target[0], world_map.width)
    dy = target[1] - from_cell[1]
    if dx != 0 and dy != 0:
        return False
    cell = (target[0] % world_map.width, target[1])
    return world_map.shore_port_at(cell[0], cell[1]) != ""


def dock_at(state: SailingState, st: PersonState, store: DataStore,
            economy_state: EconomyState, motion: SailingMotion,
            target: tuple[int, int], world: WorldRaster | None = None,
            ocean: OceanLayers | None = None,
            allegiance_state: AllegianceState | None = None) -> bool:
    """§4.11.1 docking: charges one ``move_cost(heading)`` (the docking
    move's own heading) plus exactly one §4.1b hour, then opens the port —
    the fleet does **not** move onto the shore tile (docking is an
    interaction); it is stored on the **berth** tile instead, so
    ``world.position`` is always water and Set Sail has somewhere legal to
    leave from. Docking ends any click route, any held direction and the
    helm (§4.2 cancel seams); the heading persists. Returns true when a
    port was entered."""
    world_map = _world(world)
    cell = (target[0] % world_map.width, target[1])
    port_id = world_map.shore_port_at(cell[0], cell[1])
    if not port_id:
        return False
    berth = world_map.port_cell(port_id)
    fleet_cell = world_tile(state)
    heading = heading_of_delta(wrapped_delta(fleet_cell, target,
                                             world_map.width))
    # §4.2/§4.8.9: the docking move records its heading too — the docked
    # fleet faces the shore it docked into.
    if heading:
        state.world["heading"] = heading
    if heading:
        advance_clock(state, st, store, economy_state,
                      move_cost(state, st, store, heading),
                      world=world_map, ocean=ocean,
                      allegiance_state=allegiance_state)
    else:
        advance_clock(state, st, store, economy_state,
                      move_cost(state, st, store),
                      world=world_map, ocean=ocean,
                      allegiance_state=allegiance_state)
    # §4.1b: docking itself charges one more hour (the harbor pilot, the
    # mooring) before the port screen opens.
    advance_port_hours(state, st, store, economy_state, 1,
                       allegiance_state=allegiance_state, world=world_map,
                       ocean=ocean)
    if berth[0] >= 0:
        set_world_tile(state, berth[0], berth[1])
    # Sight again from the berth (the scene's _reveal before _enter_port).
    reveal(state, st, store, world_map, ocean)
    # Docking ends the route/hold/helm; the heading persists.
    reset_motion(motion)
    enter_port(state, st, store, port_id)
    return True


def enter_port(state: SailingState, st: PersonState, store: DataStore,
               port_id: str) -> list[dict[str, Any]]:
    """Port entry (§4.11, in the doc's numbered order):

      1. the docking day's move + clock cost (already applied by
         :func:`dock_at`);
      2. discover the port if it was unknown, then dock
         (``current_port``);
      3. queue the §4.7 dialogs: desertion (§4.8.2) → arrival greeting
         (§4.11);
      4. fire the ``port_entered`` hook, queue the entries in the §4.7
         dialog buffer and return them (the caller renders/routes them;
         entries from the same tick sort together in §4.7 order).

    The greeting entry carries the port's RAW ``{"zh","en"}`` name dict
    plus ``day`` (90-§0.5: the server ships data, the client renders).
    Declared seams: the §4.19 arrival cancel and the Phase-3 quest
    completion (``Phase3Hooks.on_port_entered``) are caller-side — their
    dialog entries would prepend to the returned list.
    """
    # 2. Discover-then-dock. Entering an unknown harbor discovers it.
    if port_id not in state.known_ports:
        state.known_ports.append(port_id)
    state.current_port = port_id

    # 3. §4.8.2 desertion on EVERY port entry (morale < 40).
    entries: list[dict[str, Any]] = []
    if _has_game(st, state):
        lost = apply_desertion(state, st)
        if lost > 0:
            entries.append({
                "kind": "desertion", "key": "world.desertion",
                "values": {"count": lost},
            })
        port = store.get_port(port_id)
        entries.append({
            "kind": "greeting", "key": "world.arrive",
            "values": {
                "port": port.get("name", {}) if port else {},
                "day": st.day,
            },
        })

    # 4. Announce (docs/90 §5.1) and queue in the §4.7 order.
    if state.on_port_entered is not None:
        state.on_port_entered(port_id)
    entries = sort_dialogs(entries)
    state.last_day_dialogs.extend(entries)
    return entries


def set_sail(state: SailingState, st: PersonState, store: DataStore,
             economy_state: EconomyState,
             allegiance_state: AllegianceState | None = None,
             world: WorldRaster | None = None,
             ocean: OceanLayers | None = None) -> bool:
    """Set Sail (§4.11 exit; port_screen.gd ``set_sail``): charges one
    §4.1b hour, clears ``current_port``, keeps the fleet on the **berth**
    tile. The clock fraction is **continuous** — the hour is charged
    before the docked flag drops so a midnight crossing ticks in port.
    **Gated** by §4.11.2 (locked): a fleet with no crew or less than one
    day of supply never reaches open water. Returns false with **state
    untouched**."""
    if not st.player and not state.fleet:
        # No run at all: nothing to leave.
        return False
    if not docked_port_id(state):
        return False
    if supply_block_reason(state):
        # §4.11.2 hard gate (the prompt states the reason).
        return False
    # §4.11 exit order: record the departed port first (hunter intel), then
    # the sail-out hour, then drop the docked flag.
    state.world["last_departed_port"] = _port_or_empty(state.current_port)
    advance_port_hours(state, st, store, economy_state, 1,
                       allegiance_state=allegiance_state, world=world,
                       ocean=ocean)
    state.current_port = None
    return True


def reveal(state: SailingState, st: PersonState, store: DataStore,
           world: WorldRaster | None = None,
           ocean: OceanLayers | None = None) -> list[str]:
    """§4.11/§4.12 sighting pass (world_map ``_reveal``): reveals every
    port within the sighting radius (Chebyshev, **wrap-aware on x**,
    measured to its berth tile) and marks the sighting square explored for
    the minimap. Both loops wrap on x and clip only at the latitude edges.
    Returns the newly sighted port ids (the caller refreshes its overlay
    when the list is non-empty — the sighting pass is the only thing that
    adds known ports)."""
    world_map = _world(world)
    radius = sighting_radius(st, store) if _has_game(st, state) \
        else SIGHTING_RADIUS
    fleet_cell = world_tile(state)
    newly: list[str] = []
    for port_id, (bx, by) in world_map.harbor_tiles().items():
        if chebyshev_wrap(bx, by, fleet_cell[0], fleet_cell[1]) > radius:
            continue
        if port_id not in state.known_ports:
            state.known_ports.append(port_id)
            newly.append(port_id)
    for dy in range(-radius, radius + 1):
        y = fleet_cell[1] + dy
        if y < 0 or y >= world_map.height:
            continue
        for dx in range(-radius, radius + 1):
            state.explored_tiles.add(
                ((fleet_cell[0] + dx) % world_map.width, y))
    return newly


def explore_here(state: SailingState, st: PersonState, store: DataStore,
                 explore: Callable[[tuple[int, int]], list[str]] | None = None
                 ) -> list[str]:
    """The Explore action (§4.11 discovery sighting, 70-* §4.4): hands the
    fleet cell to the discovery port's ``explore(cell)`` (injected — the
    discovery MODULE is another agent's; ``None`` finds nothing) and
    returns the ids found, in the discovery port's stable order. The
    radius contract is the §4.11 formula
    ``36 + floor(cartography / 15)`` — pinned here as
    :data:`DISCOVERY_RADIUS` + :data:`DISCOVERY_CARTOGRAPHY_DIVISOR`, owned
    by the discovery port's ``radius()``. No day cost, no cooldown."""
    if not _has_game(st, state) or explore is None:
        return []
    return list(explore(world_tile(state)))


# --- §4.2 input modes: hold-to-repeat, helm, wait, trim, click-to-sail -------


def reset_motion(motion: SailingMotion) -> None:
    """Ends every cadence at once (docking/§4.2 cancel seams): the held
    direction, the click route and the helm all stop; the heading itself
    persists in ``world["heading"]`` (nothing to clear here)."""
    motion.hold_action = ""
    motion.hold_forced = False
    motion.hold_elapsed = 0.0
    motion.hold_since_step = 0.0
    motion.helm_stepping = False
    motion.helm_since_step = 0.0
    motion.sail_path = []
    motion.sail_target = (-1, -1)
    motion.sail_elapsed = 0.0
    motion.sail_suspended = False
    motion.sail_dock_port = ""


def press_direction(state: SailingState, st: PersonState, store: DataStore,
                    economy_state: EconomyState, motion: SailingMotion,
                    action: str, world: WorldRaster | None = None,
                    ocean: OceanLayers | None = None,
                    allegiance_state: AllegianceState | None = None) -> bool:
    """A direction action as if the key went down (§4.2 step mode): steps
    once immediately (one normal move), starts the 0.25 s hold delay, and
    cancels any click-to-sail order (manual input). Returns whether that
    first step actually happened."""
    if action not in MOVE_ACTIONS:
        return False
    motion.hold_action = action
    motion.hold_forced = True
    motion.hold_elapsed = 0.0
    motion.hold_since_step = 0.0
    cancel_sail(motion)
    fleet_cell = world_tile(state)
    dx, dy = MOVE_ACTIONS[action]
    return try_step(state, st, store, economy_state, motion,
                    (fleet_cell[0] + dx, fleet_cell[1] + dy),
                    world, ocean, allegiance_state)


def release_direction(motion: SailingMotion, action: str = "") -> None:
    """Releases a direction action (``""`` releases whatever is held).
    Ends the repeat; a release never steps."""
    if not action or action == motion.hold_action:
        motion.hold_action = ""
        motion.hold_forced = False
        motion.hold_elapsed = 0.0
        motion.hold_since_step = 0.0


def advance_motion(state: SailingState, st: PersonState, store: DataStore,
                   economy_state: EconomyState, motion: SailingMotion,
                   seconds: float, world: WorldRaster | None = None,
                   ocean: OceanLayers | None = None,
                   allegiance_state: AllegianceState | None = None) -> None:
    """Drives the §4.2 cadence with ``seconds`` of simulated time — the
    deterministic replacement for the frame tick in headless tests.
    ``100`` held steps are produced exactly as ``press_direction(...)``
    followed by ``advance_motion(HOLD_DELAY_SECONDS + 99 *
    SAIL_STEP_SECONDS)``.

    The held direction drops to a single step per
    :data:`SAIL_STEP_SECONDS` after :data:`HOLD_DELAY_SECONDS`; the helm
    auto-stepper runs beside it with the same per-step semantics; the
    click route walks on the same clock. A blocked step costs nothing and
    does **not** reset the accumulator: its cadence slot was already
    consumed, so a held key can never bank up free moves. Docking, a
    battle handoff or a game over end the hold/helm/route."""
    if seconds <= 0.0:
        return
    if not motion.hold_action and not motion.helm_stepping \
            and (not motion.sail_path or motion.sail_suspended):
        return
    if motion.hold_action:
        _tick_hold(state, st, store, economy_state, motion, seconds,
                   world, ocean, allegiance_state)
    if motion.helm_stepping:
        _tick_helm(state, st, store, economy_state, motion, seconds,
                   world, ocean, allegiance_state)
    if not motion.sail_path or motion.sail_suspended:
        return
    motion.sail_elapsed += seconds
    while motion.sail_elapsed >= SAIL_STEP_SECONDS - CLOCK_EPSILON \
            and motion.sail_path and not motion.sail_suspended:
        motion.sail_elapsed -= SAIL_STEP_SECONDS
        _step_along_sail_path(state, st, store, economy_state, motion,
                              world, ocean, allegiance_state)


def _tick_hold(state: SailingState, st: PersonState, store: DataStore,
               economy_state: EconomyState, motion: SailingMotion,
               seconds: float, world: WorldRaster | None,
               ocean: OceanLayers | None,
               allegiance_state: AllegianceState | None) -> None:
    """One held direction's cadence: 0.25 s delay, then 1 step every
    0.125 s. Only the part of this frame past the delay counts toward the
    first repeat, so the phase does not depend on the frame rate."""
    if motion.hold_elapsed < HOLD_DELAY_SECONDS:
        motion.hold_elapsed += seconds
        if motion.hold_elapsed < HOLD_DELAY_SECONDS:
            return
        motion.hold_since_step = motion.hold_elapsed - HOLD_DELAY_SECONDS
        motion.hold_elapsed = HOLD_DELAY_SECONDS
    else:
        motion.hold_since_step += seconds
    while motion.hold_since_step >= SAIL_STEP_SECONDS - CLOCK_EPSILON:
        motion.hold_since_step -= SAIL_STEP_SECONDS
        if not motion.hold_action:
            return
        fleet_cell = world_tile(state)
        dx, dy = MOVE_ACTIONS[motion.hold_action]
        try_step(state, st, store, economy_state, motion,
                 (fleet_cell[0] + dx, fleet_cell[1] + dy),
                 world, ocean, allegiance_state)
        # Docking / a battle interruption / a game over end the hold.
        if state.current_port is not None or _battle_active(motion) \
                or is_game_over(state) or motion.sail_suspended:
            motion.hold_action = ""
            motion.hold_elapsed = 0.0
            motion.hold_since_step = 0.0
            return


def _action_of_heading(heading: str) -> str:
    """The 8-dir action id for a compass heading (``""`` outside the
    8-dir domain)."""
    index = heading_index(heading)
    if index < 0:
        return ""
    dx, dy = COMPASS_DELTAS[index]
    for action, (ax, ay) in MOVE_ACTIONS.items():
        if (ax, ay) == (dx, dy):
            return action
    return ""


def helm_heading(state: SailingState) -> str:
    """The persisted helm heading (§4.2), guard-read with the pinned
    default ``"E"``. It persists through helm stops and mode switches."""
    heading = str(state.world.get("heading", "E"))
    return heading if heading_index(heading) >= 0 else "E"


def helm_active(motion: SailingMotion) -> bool:
    """True while the helm auto-stepper is running (§4.2)."""
    return motion.helm_stepping


def helm_interval(state: SailingState, st: PersonState, store: DataStore,
                  world: WorldRaster | None = None,
                  ocean: OceanLayers | None = None) -> float:
    """The current auto-step interval, recomputed on every call (§4.2:
    ``clamp(1 / effective_speed(heading), 0.12, 2.0)`` — trim, weather,
    wind and currents all move it; a furled fleet has no speed and reads
    the 2.0 cap)."""
    speed = effective_speed(state, st, store, helm_heading(state), ocean,
                            world)
    if speed <= 0:
        return HELM_INTERVAL_MAX
    return _clampf(1.0 / float(speed), HELM_INTERVAL_MIN, HELM_INTERVAL_MAX)


def helm_steer(state: SailingState, motion: SailingMotion, action: str) -> bool:
    """Sets the helm heading from a direction action and starts (or
    re-targets) the auto-stepper (§4.2): a new direction key changes the
    course without stopping. A course change is manual input, so it
    replaces any click route (the appointment cancel is the caller's
    §4.19 seam). Refused while docked. The first auto-step happens on the
    first interval tick, not here."""
    if action not in MOVE_ACTIONS:
        return False
    if state.current_port is not None:
        return False
    heading = heading_of_delta(MOVE_ACTIONS[action])
    if not heading:
        return False
    cancel_sail(motion)
    state.world["heading"] = heading
    # A course change starts a fresh interval on the new heading.
    motion.helm_since_step = 0.0
    motion.helm_stepping = True
    return True


def helm_stop(motion: SailingMotion) -> None:
    """Stops the auto-stepper (§4.2 ``Space``, or a cancel seam). The
    heading persists in ``world["heading"]``."""
    motion.helm_stepping = False
    motion.helm_since_step = 0.0


def _tick_helm(state: SailingState, st: PersonState, store: DataStore,
               economy_state: EconomyState, motion: SailingMotion,
               seconds: float, world: WorldRaster | None,
               ocean: OceanLayers | None,
               allegiance_state: AllegianceState | None) -> None:
    """The helm auto-stepper (§4.2): one normal move along
    ``world.heading`` every :func:`helm_interval` seconds, the interval
    **recomputed per step** so a trim change, a weather roll or a current
    edge re-times the cadence immediately. A blocked step costs nothing
    and consumes its slot (never banked). Docking, a battle handoff or a
    game over end the helm; the heading itself persists."""
    motion.helm_since_step += seconds
    while motion.helm_stepping \
            and motion.helm_since_step \
            >= helm_interval(state, st, store, world, ocean) - CLOCK_EPSILON:
        motion.helm_since_step -= helm_interval(state, st, store, world,
                                                ocean)
        action = _action_of_heading(helm_heading(state))
        if not action:
            helm_stop(motion)
            return
        fleet_cell = world_tile(state)
        dx, dy = MOVE_ACTIONS[action]
        try_step(state, st, store, economy_state, motion,
                 (fleet_cell[0] + dx, fleet_cell[1] + dy),
                 world, ocean, allegiance_state)
        if state.current_port is not None or _battle_active(motion) \
                or is_game_over(state) or motion.sail_suspended:
            helm_stop(motion)
            return


def press_wait(state: SailingState, st: PersonState, store: DataStore,
               economy_state: EconomyState, motion: SailingMotion,
               allegiance_state: AllegianceState | None = None,
               world: WorldRaster | None = None,
               ocean: OceanLayers | None = None) -> dict[str, bool]:
    """The ``Space`` action (§4.2/§4.17). Step mode: wait one day at sea.
    Helm mode: the first press stops the fleet, a press while stopped
    waits. Refused while docked (:func:`wait_at_sea` returns false — a
    port day is :func:`advance_port_day`'s business). Returns
    ``{"stopped", "waited"}`` so callers can tell the two helm presses
    apart."""
    out = {"stopped": False, "waited": False}
    if state.control_prefs.get("input_mode", "step") == "helm" \
            and motion.helm_stepping:
        helm_stop(motion)
        out["stopped"] = True
        return out
    if not wait_at_sea(state, st, store, economy_state, allegiance_state,
                       world, ocean):
        return out
    out["waited"] = True
    return out


def cycle_trim(state: SailingState, forward: bool) -> str:
    """Cycles ``world["sail_trim"]`` through ``furled → reefed → normal →
    full`` (§4.17): ``forward`` follows that order and wraps, ``False``
    walks it backwards. Works in both input modes; the next step's cost
    picks the new state up automatically. Returns the new state."""
    states = TRIM_STATES
    try:
        index = states.index(sail_trim(state))
    except ValueError:
        index = states.index(DEFAULT_TRIM)
    step = 1 if forward else -1
    nxt = states[(index + step) % len(states)]
    state.world["sail_trim"] = nxt
    return nxt


# --- Click-to-sail (§4.2, task H) --------------------------------------------


def sail_to(state: SailingState, st: PersonState, store: DataStore,
            economy_state: EconomyState, motion: SailingMotion,
            target: tuple[int, int], world: WorldRaster | None = None,
            ocean: OceanLayers | None = None,
            allegiance_state: AllegianceState | None = None,
            find_path: Callable[..., list[tuple[int, int]]] | None = None,
            ) -> bool:
    """Click-to-sail: computes the §4.2 route to ``target`` (delegating to
    :mod:`server.sim.world.sail_path`'s A*) and stores it; the route then
    advances on the same cadence as hold-to-repeat (one
    :func:`try_step` per :data:`SAIL_STEP_SECONDS`), so a click route is N
    steps = N normal moves — clock, consumption, port entry included. The
    first step happens on the first cadence tick, not inside this call.

    A click on land/ice/off-grid costs nothing and is refused; a click on
    water with no sea route is refused (``world.sail.no_path``). A click
    on a port's **shore** tile routes to the adjacent berth and docks on
    arrival (§4.11.1); a click beside a shore tile already in the
    orthogonal ring docks immediately, exactly like a direction press.
    Returns true when a route was found and stored."""
    world_map = _world(world)
    cell = (target[0] % world_map.width, target[1])
    fleet_cell = world_tile(state)
    if cell == (fleet_cell[0] % world_map.width, fleet_cell[1]):
        # Clicking the tile the fleet stands on is a no-op.
        return False
    # §4.11.1: a port's shore tile is a valid destination — the route goes
    # to the adjacent berth (the shore tile stays solid for A*).
    dock_port = world_map.shore_port_at(cell[0], cell[1])
    if dock_port:
        return _sail_to_shore(state, st, store, economy_state, motion,
                              cell, dock_port, world_map, ocean,
                              allegiance_state, find_path)
    if not world_map.is_passable(cell[0], cell[1]):
        # Land / ice / out of range: rejected, no clock cost, no order
        # change.
        return False
    # §4.18: a click onto an in-month frozen tile is rejected like a land
    # click (the destination pre-check; mid-path tiles block on arrival via
    # the per-step gate in is_move_legal).
    if st.day > 0 and _ocean(ocean).ice_blocks(
            cell[0], cell[1], month_for(st.day)):
        return False
    path = _sail_compute(state, fleet_cell, cell, world_map, find_path)
    if not path:
        return False
    # A click is manual input: it replaces a held direction, any old order,
    # and the helm (§4.2 cancel seams).
    helm_stop(motion)
    motion.hold_action = ""
    motion.hold_forced = False
    motion.hold_elapsed = 0.0
    motion.hold_since_step = 0.0
    motion.sail_path = path
    motion.sail_target = cell
    motion.sail_dock_port = ""
    motion.sail_elapsed = 0.0
    motion.sail_suspended = False
    return True


def _sail_to_shore(state: SailingState, st: PersonState, store: DataStore,
                   economy_state: EconomyState, motion: SailingMotion,
                   shore: tuple[int, int], port_id: str,
                   world: WorldRaster, ocean: OceanLayers | None,
                   allegiance_state: AllegianceState | None,
                   find_path: Callable[..., list[tuple[int, int]]] | None,
                   ) -> bool:
    """The shore-tile branch of :func:`sail_to`: route to the port's berth
    and dock on arrival. When the fleet is already orthogonally adjacent
    to the shore tile (or standing on its berth) the click is a docking
    gesture, not a route — dock now, exactly like a key press."""
    berth = world.port_cell(port_id)
    if berth[0] < 0:
        return False
    fleet_cell = world_tile(state)
    delta = wrapped_delta(fleet_cell, shore, world.width)
    if abs(delta[0]) + abs(delta[1]) == 1 \
            or (berth[0] % world.width, berth[1]) \
            == (fleet_cell[0] % world.width, fleet_cell[1]):
        return dock_at(state, st, store, economy_state, motion, shore,
                       world, ocean, allegiance_state)
    path = _sail_compute(state, fleet_cell, berth, world, find_path)
    if not path:
        return False
    helm_stop(motion)
    motion.hold_action = ""
    motion.hold_forced = False
    motion.hold_elapsed = 0.0
    motion.hold_since_step = 0.0
    motion.sail_path = path
    motion.sail_target = berth
    motion.sail_dock_port = port_id
    motion.sail_elapsed = 0.0
    motion.sail_suspended = False
    return True


def _sail_compute(state: SailingState, fleet_cell: tuple[int, int],
                  target: tuple[int, int], world: WorldRaster,
                  find_path: Callable[..., list[tuple[int, int]]] | None,
                  ) -> list[tuple[int, int]]:
    """The A* call for the current fleet cell (§4.2, the sail_path port).
    ``find_path`` is injectable for tests; the default is the module's
    :func:`sail_path.find_path` over the real raster (the §4.2 passability,
    terrain only — the destination ice pre-check and the per-step gate
    carry the §4.18 rule)."""
    if find_path is None:
        find_path = sail_path.find_path
    return find_path(lambda x, y: world.is_passable(x, y),
                     world.width, world.height, fleet_cell, target)


def sail_active(motion: SailingMotion) -> bool:
    """True while a route is stored (walking or suspended by a battle)."""
    return bool(motion.sail_path) or motion.sail_suspended


def cancel_sail(motion: SailingMotion) -> None:
    """Cancels the order (manual direction input, a click elsewhere,
    redirection, docking, a blocked step).

    §4.19 seam (declared, not ported): the GDScript also cancelled the
    appointed voyage here (``AutopilotLib.cancel("manual")`` — the route
    dying IS the manual input) and cleared the intercept order; the
    caller hooks its autopilot port to this call. The intercept order
    state is battle-side and lives with the caller too.
    """
    motion.sail_path = []
    motion.sail_target = (-1, -1)
    motion.sail_elapsed = 0.0
    motion.sail_suspended = False
    motion.sail_dock_port = ""


def _step_along_sail_path(state: SailingState, st: PersonState,
                          store: DataStore, economy_state: EconomyState,
                          motion: SailingMotion, world: WorldRaster | None,
                          ocean: OceanLayers | None,
                          allegiance_state: AllegianceState | None) -> None:
    """Walks one stored path step through the normal movement rules. A
    route cancels the moment its next tile is no longer a legal step: never
    force a bad move. A battle on the way suspends the route (the
    ``battle_active`` seam); docking, a game over or the destination all
    end the order. A shore-tile click (§4.11.1) docks when the route
    reaches the berth; if the fleet somehow stopped short of the shore
    tile's orthogonal ring, the order is simply dropped (never a forced
    dock from a diagonal or a distance)."""
    if not motion.sail_path:
        return
    nxt = motion.sail_path[0]
    world_map = _world(world)
    fleet_cell = world_tile(state)
    if not step_is_legal(state, st, fleet_cell, nxt, world_map, ocean):
        cancel_sail(motion)
        return
    del motion.sail_path[0]
    moved = try_step(state, st, store, economy_state, motion, nxt,
                     world_map, ocean, allegiance_state)
    if not moved:
        cancel_sail(motion)
        return
    if motion.sail_suspended:
        # The caller's battle seam suspended the route.
        return
    if _battle_active(motion):
        # The battle opened on the final step: the order is over.
        cancel_sail(motion)
        return
    if not motion.sail_path:
        if motion.sail_dock_port:
            port_id = motion.sail_dock_port
            motion.sail_dock_port = ""
            shore = world_map.shore_cell(port_id)
            delta = wrapped_delta(world_tile(state), shore, world_map.width)
            if shore[0] >= 0 and abs(delta[0]) + abs(delta[1]) == 1:
                dock_at(state, st, store, economy_state, motion, shore,
                        world_map, ocean, allegiance_state)
                return
            cancel_sail(motion)
            return
        # Destination reached: the order ends (the arrival toast is the
        # caller's presentation).
        motion.sail_path = []
        motion.sail_target = (-1, -1)
        motion.sail_elapsed = 0.0
        motion.sail_suspended = False
        motion.sail_dock_port = ""
        return
    if state.current_port is not None or is_game_over(state):
        cancel_sail(motion)
