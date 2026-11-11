"""server.sim.combat.battle_sim — the pure turn engine for sea battles (M1).

Python port of ``scripts/combat/battle_sim.gd`` (the frozen parity oracle
until the M6 cutover) — the Phase-9 velocity-physics battle layer
(docs/60-COMBAT.md §4.2–§4.7, §4.3a/§4.4a/§4.4b/§4.6a, §4.11.1–§4.11.12,
§4.12.1/§4.12.1.2).

Purity contract (M1, docs/90-ARCHITECTURE.md §0): the engine **never**
touches run state — it deep-copies the ship instances handed to
:meth:`BattleSim.__init__` and owns every battle-local field (units, RNG,
log, outcome tallies). The GDScript's defensive ``GameState`` reads
(player attributes/skills/equipment, ``GameState.morale``,
``GameState.world["wind_dir"]``) arrive through the §4.12.1 config keys:
``player_stats`` (the S21 seam — per-key overrides with 0 defaults where
the autoload read is absent), ``player_morale`` / ``enemy_morale`` /
``wind_dir`` / ``current``. The no-autoload defaults are exactly the
oracle's defensive fallbacks: wind ``"E"``, player morale ``0``, current
decoded from the raster (``server.sim.world.raster`` — the
``OceanLayers.instance().current_at`` seam) or strength 0.

Model (docs/60 §4.3a): every ship carries ``pos`` / ``vel`` (integer
2-vectors), ``heading8``, ``reload_port`` / ``reload_starboard``,
``speed_debuff_turns`` and ``crew``. A turn is three phases — pick a legal
velocity, integrate it as a Bresenham sweep (the first occupied cell stops
the ship: enemy ⇒ ram, friend/out-of-bounds ⇒ stop at the prior cell),
then at most one action (cannon naming the side / ram / board / hold).

Cells and velocities are plain ``(x, y)`` integer tuples — the Vector2i of
the oracle. RNG is :class:`server.sim.rng.GodotRng` (bit-exact PCG32);
the call ORDER — composition draws, then duel ``randi_range(0, 20)`` pairs
(player first), then ``randf()`` surrender rolls — is parity-critical for
the M5 golden traces and is kept verbatim.

Sailing-seam note: the oracle reads three small closed-form tables off
``scripts/world/sailing_sim.gd`` (``WIND_FACTORS`` §4.7, ``DIRECTION_FACTORS``
§4.4, the compass helpers + ``month_for`` §4.15) and the raster current
lookup. The tables are re-typed here verbatim (``sailing_sim.py`` is not
part of this module's ownership; a later wave may dedupe through it) —
the values are the doc pins of docs/20 §4.4/§4.7/§4.15.

Seams NOT ported here (with the oracle entry point):
  * the T3 one-ply lookahead consumes ``snapshot()``/``restore()`` —
    ``scripts/combat/ai_search.gd`` (another agent) ranks candidates by
    calling back into this engine;
  * ``AiFleet.decide`` (``server.sim.combat.ai_fleet``) is the §4.12.1.1
    decision layer this engine executes through :meth:`run_to_completion`;
  * ``BattleResult.apply`` / ``BattleRewards.apply`` are the §4.12.4
    steps 2/3 (``server.sim.combat.battle_result`` /
    ``battle_rewards``) — the engine only reports.
"""

from __future__ import annotations

import inspect
import math
import sys
from typing import Any, Callable, Final, Iterable

from server.sim.data import data
from server.sim.rng import GodotRng

__all__ = [
    "GRID_WIDTH",
    "GRID_HEIGHT",
    "PLAYER_BAND_MAX_X",
    "ENEMY_BAND_MIN_X",
    "PLAYER_DEPLOYMENT",
    "ENEMY_DEPLOYMENT",
    "TOURNAMENT_DEPLOYMENT",
    "NO_CELL",
    "HEADING_RAYS",
    "HEADING_TOKENS",
    "HEADING_EAST",
    "HEADING_WEST",
    "SIDE_PLAYER",
    "SIDE_ENEMY",
    "ARC_PORT_STEPS",
    "ARC_STARBOARD_STEPS",
    "BROADSIDE_PORT",
    "BROADSIDE_STARBOARD",
    "CANNON_RANGE_MIN",
    "CANNON_RANGE_MAX",
    "CANNON_RANGE_FACTOR",
    "ROUND_SHOT",
    "CHAIN_SHOT",
    "ARMOR_PIERCING_SHOT",
    "GRAPE_SHOT",
    "DEFAULT_CHAIN_GATE",
    "DEFAULT_ARMOR_PIERCING_GATE",
    "DUEL_WINS_NEEDED",
    "DUEL_MAX_ROUNDS",
    "DUEL_ROUND_MAX_ROLL",
    "FLEET_TIER",
    "MORALE_SURRENDER_GATE",
    "MORALE_INSTANT_STRIKE",
    "STALL_ROUNDS",
    "STALL_DISTANCE_DELTA",
    "MAX_ROUNDS",
    "RESULT_VALUES",
    "XP_PER_ENEMY_NEUTRALIZED",
    "XP_PER_ROUND",
    "PIRATE_REP_GAIN",
    "NAVY_REP_PENALTY",
    "SALVAGE_FRACTION",
    "NEAREST_PORT_COUNT",
    "Cell",
    "battle_seed_formula",
    "heading8_of",
    "bucket_distance",
    "vel_length",
    "in_grid",
    "to_cell",
    "resolve_duel",
    "defender_duel_base",
    "defender_charisma_bonus",
    "surrender_chance_for_courage",
    "morale_surrender_bonus",
    "card_duel_rating",
    "card_cannon_rating",
    "card_charisma",
    "card_courage",
    "chain_shot_gate",
    "armor_piercing_gate",
    "shot_unlocked",
    "BattleSim",
]


# --- Grid & deployment (docs/60 §4.2, §4.11.2) -------------------------------

GRID_WIDTH: Final[int] = 48
GRID_HEIGHT: Final[int] = 30
#: §4.2 bands (correction 15): player x ≤ 12, enemy x ≥ 35.
PLAYER_BAND_MAX_X: Final[int] = 12
ENEMY_BAND_MIN_X: Final[int] = 35
#: §4.11.2 concrete tiles (correction 15 — the closing start), by fleet index.
PLAYER_DEPLOYMENT: Final[tuple[Cell, ...]] = (
    (10, 15), (10, 14), (10, 16), (10, 13), (10, 17),
)
ENEMY_DEPLOYMENT: Final[tuple[Cell, ...]] = (
    (37, 15), (37, 14), (37, 16), (37, 13), (37, 17),
)
#: §4.11.2 deployment variant key — accepted, maps to the same start.
TOURNAMENT_DEPLOYMENT: Final[str] = "tournament"
TOURNAMENT_PLAYER_CELL: Final[Cell] = (10, 15)
TOURNAMENT_ENEMY_CELL: Final[Cell] = (37, 15)
TOURNAMENT_PLAYER_VEL: Final[Cell] = (1, 0)
TOURNAMENT_ENEMY_VEL: Final[Cell] = (-1, 0)
#: "No destination cell" marker for non-move decisions / queries.
NO_CELL: Final[Cell] = (-1, -1)

# --- heading8 (docs/60 §4.3a, decision 1) ------------------------------------
#
# heading8 ∈ 0..7 buckets a velocity's direction at the 22.5° boundaries:
# 0 = east (+x), increasing counterclockwise in the mathematical frame
# (screen y-down: (1,−1) = NE, (0,−1) = N …). Derived via integer dot
# comparisons against the eight compass rays — never atan2 (decision 1).

HEADING_RAYS: Final[tuple[Cell, ...]] = (
    (1, 0), (1, -1), (0, -1), (-1, -1),
    (-1, 0), (-1, 1), (0, 1), (1, 1),
)
#: The 8-compass token of each bucket (the 20-* §4.4 id set).
HEADING_TOKENS: Final[tuple[str, ...]] = ("E", "NE", "N", "NW", "W", "SW", "S", "SE")
HEADING_EAST: Final[int] = 0
HEADING_WEST: Final[int] = 4

# --- Sides -------------------------------------------------------------------

SIDE_PLAYER: Final[str] = "player"
SIDE_ENEMY: Final[str] = "enemy"

# --- Velocity & cap (docs/60 §4.3a; decision 2, corrections 1–3) --------------

#: §4.4 broadside arcs — SIGNED counterclockwise bucket steps (×45°) off the
#: attacker's heading8.
ARC_PORT_STEPS: Final[tuple[int, ...]] = (1, 2, 3)      # 45° / 90° / 135°
ARC_STARBOARD_STEPS: Final[tuple[int, ...]] = (5, 6, 7)  # 225° / 270° / 315°
BROADSIDE_PORT: Final[str] = "port"
BROADSIDE_STARBOARD: Final[str] = "starboard"
BROADSIDE_SPLIT_DIVISOR: Final[float] = 2.0

# --- Cannon (docs/60 §4.4, §4.11.5) -------------------------------------------

CANNON_RANGE_MIN: Final[int] = 1
CANNON_RANGE_MAX: Final[int] = 3
#: range_factor at range 1 / 2 / 3.
CANNON_RANGE_FACTOR: Final[dict[int, float]] = {1: 1.0, 2: 0.75, 3: 0.5}
CANNON_BASE_MULTIPLIER: Final[int] = 2
STORM_CANNON_MULTIPLIER: Final[float] = 0.75
STRONG_CANNON_MULTIPLIER: Final[float] = 0.9
STORM_WEATHER: Final[str] = "storm"
STRONG_WEATHER: Final[str] = "strong"
RAKE_MULTIPLIER: Final[float] = 1.25

# --- Shot types & gunnery (§4.4b) ---------------------------------------------

ROUND_SHOT: Final[str] = "round"
CHAIN_SHOT: Final[str] = "chain"
ARMOR_PIERCING_SHOT: Final[str] = "armor_piercing"
#: §4.4b grape: NO gate, range 1 only.
GRAPE_SHOT: Final[str] = "grape"
GRAPE_HALF: Final[float] = 0.5
CHAIN_DAMAGE_MULTIPLIER: Final[float] = 0.75
CHAIN_DEBUFF_TURNS: Final[int] = 2
ARMOR_PIERCING_DAMAGE_MULTIPLIER: Final[float] = 1.25
GUNNERY_BONUS_DIVISOR: Final[int] = 25
COMBAT_BONUS_DIVISOR: Final[int] = 10
#: §4.4 gate stand-ins while ``data/skill_gates.json`` is unreadable (the
#: data row wins — 25 / 50 in the shipped file).
DEFAULT_CHAIN_GATE: Final[int] = 25
DEFAULT_ARMOR_PIERCING_GATE: Final[int] = 50

# --- Crew casualties (§4.11.5, correction 7) -----------------------------------

CREW_CASUALTY_DIVISOR: Final[int] = 20
CREW_CASUALTY_RAKE_DIVISOR: Final[int] = 10
BOARDING_CREW_LOSS_FRACTION: Final[float] = 0.2

# --- Reload (docs/60 §4.4a; decision 5, correction 14) --------------------------

RELOAD_BASE_TURNS: Final[int] = 2
RELOAD_MIN_TURNS: Final[int] = 1
RELOAD_GUNNERY_DIVISOR: Final[int] = 50
RELOAD_LOW_CREW_RATIO: Final[float] = 0.5
RELOAD_LOW_CREW_BONUS: Final[int] = 1

# --- Ram (docs/60 §4.5, §4.11.5; decision 7) ------------------------------------

RAM_TARGET_FRACTION: Final[float] = 0.25
RAM_ATTACKER_FRACTION: Final[float] = 0.10
RAM_SPEED_STEP: Final[float] = 0.25
RAM_BOW_STERN_MULTIPLIER: Final[float] = 1.15
OAR_RAM_MULTIPLIER: Final[float] = 1.25
OAR_SHIP_CLASSES: Final[tuple[str, ...]] = ("oar", "hybrid")

# --- Duel (docs/60 §4.6, §4.11.6) ------------------------------------------------

DUEL_WINS_NEEDED: Final[int] = 3
DUEL_MAX_ROUNDS: Final[int] = 5
DUEL_ROUND_MAX_ROLL: Final[int] = 20
DUEL_CREW_DIVISOR: Final[int] = 5
DUEL_CREW_CAP: Final[int] = 20
#: §4.11.5/§4.11.6 legacy stand-in for fleets without a captain canon card.
CAPTAIN_RATING_BASE: Final[int] = 5
#: §4.6 "fleet tier": pirate 1, navy 2, tournament 2 (§4.11.7.1).
FLEET_TIER: Final[dict[str, int]] = {"pirate": 1, "navy": 2, "tournament": 2}
DUEL_COURAGE_DIVISOR: Final[int] = 20
DEFENDER_CHARISMA_DIVISOR: Final[int] = 20
CARD_CANNON_DIVISOR: Final[int] = 25

# --- §4.4a / §4.7 legacy fallbacks (decision 5, correction 6) ---------------------

LEGACY_FALLBACK_BASE: Final[int] = 10
LEGACY_FALLBACK_PER_TIER: Final[int] = 10

# --- AI surrender roll (§4.7) ------------------------------------------------------

SURRENDER_CHANCE_BASE: Final[int] = 25
SURRENDER_CHANCE_MIN: Final[int] = 10
SURRENDER_CHANCE_MAX: Final[int] = 40
SURRENDER_COURAGE_DIVISOR: Final[int] = 10
SURRENDER_MORALE_DIVISOR: Final[int] = 2

# --- Side morale (docs/60 §4.8a; decision 9, corrections 5/6) -----------------------

MORALE_MIN: Final[int] = 0
MORALE_MAX: Final[int] = 100
MORALE_EVENT_FRIENDLY_SUNK: Final[int] = -15
MORALE_EVENT_CAPTURED: Final[int] = -20
#: §4.8a: the flagship-sunk −30 is TOTAL — it REPLACES the friendly-sunk −15.
MORALE_EVENT_FLAGSHIP_SUNK: Final[int] = -30
MORALE_EVENT_RAKED: Final[int] = -5
MORALE_EVENT_BOARDING_WIN: Final[int] = 10
MORALE_EVENT_BOARDING_LOSS: Final[int] = -10
MORALE_SURRENDER_GATE: Final[int] = 20
MORALE_INSTANT_STRIKE: Final[int] = 10
ENEMY_MORALE_COURAGE_BASE: Final[int] = 40
ENEMY_MORALE_FLOOR: Final[int] = 20
ENEMY_MORALE_CEILING: Final[int] = 90

# --- Stall & cap (docs/60 §4.11.9/§4.11.10; decision 12, correction 12) -------------

STALL_ROUNDS: Final[int] = 8
STALL_DISTANCE_DELTA: Final[int] = 2
MAX_ROUNDS: Final[int] = 40

# --- Outcome (docs/60 §4.11.9, §4.11.10) ----------------------------------------------

RESULT_VICTORY: Final[str] = "victory"
RESULT_DEFEAT_SUNK: Final[str] = "defeat_sunk"
RESULT_DEFEAT_CAPTURED: Final[str] = "defeat_captured"
RESULT_RETREAT: Final[str] = "retreat"
RESULT_SURRENDER: Final[str] = "surrender"
#: §4.11.9 stall row: the mutual-disengage outcome (after-apply semantics
#: are the caller's; the engine only reports).
RESULT_STALL: Final[str] = "stall"
RESULT_UNFINISHED: Final[str] = ""
RESULT_VALUES: Final[tuple[str, ...]] = (
    RESULT_VICTORY, RESULT_DEFEAT_SUNK, RESULT_DEFEAT_CAPTURED,
    RESULT_RETREAT, RESULT_SURRENDER, RESULT_STALL,
)
XP_PER_ENEMY_NEUTRALIZED: Final[int] = 10
XP_PER_ROUND: Final[int] = 5
PIRATE_REP_GAIN: Final[int] = 2
#: §4.11.10: the navy −20 is charged once at battle START by whoever
#: initiated the battle — it never appears in an outcome block.
NAVY_REP_PENALTY: Final[int] = -20
SALVAGE_FRACTION: Final[float] = 0.05
NEAREST_PORT_COUNT: Final[int] = 2

#: A grid cell / velocity — the oracle's Vector2i as an ``(x, y)`` tuple.
Cell = tuple[int, int]

# --- Sailing seams (docs/20 §4.4/§4.7/§4.15 — verbatim table ports) ----------
#
# The oracle reaches these through ``SailingSimLib`` (sailing_sim.gd); the
# Python sailing module is not this file's ownership, so the two tables and
# the compass helpers it consumes are re-typed here verbatim (the doc pins).

#: 20-* §4.7 wind factor: weather → propulsion class → multiplier.
WIND_FACTORS: Final[dict[str, dict[str, float]]] = {
    "calm": {"sail": 0.8, "oar": 1.0, "hybrid": 1.0},
    "fair": {"sail": 1.0, "oar": 1.0, "hybrid": 1.0},
    "strong": {"sail": 1.25, "oar": 1.0, "hybrid": 1.1},
    "storm": {"sail": 1.5, "oar": 1.0, "hybrid": 1.2},
}

#: 20-* §4.4 direction-factor table, ``[angle bucket][class]``. Oar rows are
#: the locked §4.17 class rule extended here.
DIRECTION_FACTORS: Final[dict[int, dict[str, float]]] = {
    0: {"sail": 0.50, "hybrid": 0.85, "oar": 1.00},
    45: {"sail": 0.70, "hybrid": 0.95, "oar": 1.00},
    90: {"sail": 1.00, "hybrid": 1.00, "oar": 1.00},
    135: {"sail": 1.15, "hybrid": 1.05, "oar": 1.00},
    180: {"sail": 1.30, "hybrid": 1.10, "oar": 1.00},
}

#: 20-* §4.4: the 8 compass direction ids every heading/wind/current id lives
#: in (the sailing-sim order — note it differs from the battle grid's
#: HEADING_TOKENS order; the buckets are bridged by token, never by index).
COMPASS_DIRS: Final[tuple[str, ...]] = ("N", "NE", "E", "SE", "S", "SW", "W", "NW")

#: 20-* §4.15 calendar: twelve 30-day months; day 1 is Month 1.
_MONTH_DAYS: Final[int] = 30
_YEAR_MONTHS: Final[int] = 12


def month_for(day: int) -> int:
    """20-* §4.15 ``month(day) = floor((day − 1) mod 360 / 30) + 1``."""
    return ((day - 1) % (_MONTH_DAYS * _YEAR_MONTHS)) // _MONTH_DAYS + 1


def heading_index(heading: str) -> int:
    """Index (0..7) of a compass id, or −1 outside the 8-dir domain."""
    try:
        return COMPASS_DIRS.index(heading)
    except ValueError:
        return -1


def angle_between_dirs(a: str, b: str) -> int:
    """Angle between two 8-dir ids bucketed to the compass grid — always one
    of 0 / 45 / 90 / 135 / 180; −1 for unknown ids."""
    ia = heading_index(a)
    ib = heading_index(b)
    if ia < 0 or ib < 0:
        return -1
    diff = abs(ia - ib) % 8
    return min(diff, 8 - diff) * 45


def wind_factor(weather: str, ship_class: str) -> float:
    """20-* §4.7: multiplier for the weather and the hull's class; unknown
    pairs fall back to 1.0."""
    table = WIND_FACTORS.get(weather, {})
    return float(table.get(ship_class, 1.0))


# --- Seed / geometry statics ---------------------------------------------------


def battle_seed_formula(day: int, contact: Cell, gold: int, fleet_size: int) -> int:
    """§4.11.1: ``day×1000003 + x×7919 + y×104729 + gold×31 + n×17`` — plain
    integer arithmetic (no hash), identical on every platform."""
    x, y = contact
    return day * 1000003 + x * 7919 + y * 104729 + gold * 31 + fleet_size * 17


def heading8_of(vel: Cell) -> int:
    """§4.3a: integer nearest-ray heading bucket — maximize
    ``cos² = dot²/|ray|²`` over the rays with a positive dot (an axis ray
    scores 2·dot², a diagonal dot²). Ties are impossible — a 22.5° boundary
    has an irrational slope. ``(0,0)`` has no heading: the static default is
    east; callers keep the last one on a zero pick."""
    if vel == (0, 0):
        return HEADING_EAST
    best = HEADING_EAST
    best_score = -1
    for bucket, ray in enumerate(HEADING_RAYS):
        dot = vel[0] * ray[0] + vel[1] * ray[1]
        if dot <= 0:
            continue
        axis = ray[0] == 0 or ray[1] == 0
        score = 2 * dot * dot if axis else dot * dot
        if score > best_score:
            best_score = score
            best = bucket
    return best


def bucket_distance(a: int, b: int) -> int:
    """The heading-bucket distance between two buckets in 45° steps (0..4)."""
    diff = abs(a % 8 - b % 8) % 8
    return min(diff, 8 - diff)


def vel_length(vel: Cell) -> float:
    """‖vel‖ as a float (§4.3a — the only float use in the model)."""
    return math.sqrt(vel[0] * vel[0] + vel[1] * vel[1])


def in_grid(cell: Cell) -> bool:
    x, y = cell
    return 0 <= x < GRID_WIDTH and 0 <= y < GRID_HEIGHT


def to_cell(value: Any) -> Cell:
    """Coerces the accepted cell shapes (tuple/list of 2, ``{"x","y"}``) to a
    ``(x, y)`` tuple; anything else is :data:`NO_CELL`."""
    if isinstance(value, tuple) and len(value) == 2:
        return (int(value[0]), int(value[1]))
    if isinstance(value, list) and len(value) >= 2:
        return (int(value[0]), int(value[1]))
    if isinstance(value, dict):
        return (int(value.get("x", -1)), int(value.get("y", -1)))
    return NO_CELL


def _chebyshev(a: Cell, b: Cell) -> int:
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]))


def _manhattan(a: Cell, b: Cell) -> int:
    return abs(a[0] - b[0]) + abs(a[1] - b[1])


def _world_width() -> int:
    grid = data().map_legend.get("grid", {})
    width = int(grid.get("width", 0)) if isinstance(grid, dict) else 0
    return width if width > 0 else 4320


def world_chebyshev(a: Cell, b: Cell) -> int:
    """Chebyshev with longitude wrap (20-* §4.1: x mod width, 4320 at the
    Phase-6 grid). The battle grid does not wrap; port distances from a
    world contact tile do."""
    width = _world_width()
    dx = abs(a[0] - b[0]) % max(width, 1)
    return max(min(dx, width - dx), abs(a[1] - b[1]))


def bresenham_cells(from_cell: Cell, to_cell: Cell) -> list[Cell]:
    """The Bresenham cells strictly after ``from_cell``, up to and including
    ``to_cell`` (the §4.3a sweep walk — the AI's landing preview calls the
    same generator, so the preview is exact)."""
    cells: list[Cell] = []
    dx = abs(to_cell[0] - from_cell[0])
    dy = -abs(to_cell[1] - from_cell[1])
    sx = 1 if to_cell[0] >= from_cell[0] else -1
    sy = 1 if to_cell[1] >= from_cell[1] else -1
    err = dx + dy
    cx, cy = from_cell
    while (cx, cy) != to_cell:
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            cx += sx
        if e2 <= dx:
            err += dx
            cy += sy
        cells.append((cx, cy))
    return cells


# --- Captain canon + skill gates (§4.11.5, §4.4b) -------------------------------


def captain_canon_card(captain_id: str) -> dict[str, Any]:
    """The canon card for ``captain_id`` from ``data/captains.json``, or
    ``{}`` when absent/empty."""
    if not captain_id:
        return {}
    card = data().get_captain(captain_id)
    return dict(card) if card else {}


def card_duel_rating(card: dict[str, Any]) -> int:
    """§4.11.5: ``swordplay + floor(courage / 20)``."""
    skills = card.get("skills", {}) if isinstance(card.get("skills", {}), dict) else {}
    attributes = card.get("attributes", {}) if isinstance(card.get("attributes", {}), dict) else {}
    return int(skills.get("swordplay", 0)) + int(
        math.floor(int(attributes.get("courage", 0)) / DUEL_COURAGE_DIVISOR))


def card_cannon_rating(card: dict[str, Any]) -> int:
    """§4.11.5: the duel rating ``+ floor(gunnery / 25)``."""
    skills = card.get("skills", {}) if isinstance(card.get("skills", {}), dict) else {}
    return card_duel_rating(card) + int(
        math.floor(int(skills.get("gunnery", 0)) / CARD_CANNON_DIVISOR))


def card_charisma(card: dict[str, Any]) -> int:
    attributes = card.get("attributes", {}) if isinstance(card.get("attributes", {}), dict) else {}
    return int(attributes.get("charisma", 0))


def card_courage(card: dict[str, Any]) -> int:
    attributes = card.get("attributes", {}) if isinstance(card.get("attributes", {}), dict) else {}
    return int(attributes.get("courage", 0))


def _gate_threshold(rows: Any, feature_id: str, fallback: int) -> int:
    if isinstance(rows, list):
        for row in rows:
            if isinstance(row, dict) and str(row.get("feature_id", "")) == feature_id:
                return int(row.get("threshold", fallback))
        return fallback
    if isinstance(rows, dict):
        table = rows
        if feature_id not in table and "skill_gates" in table:
            inner = table.get("skill_gates")
            return _gate_threshold(inner, feature_id, fallback) if isinstance(inner, list) else fallback
        row = table.get(feature_id)
        if isinstance(row, dict):
            return int(row.get("threshold", fallback))
        if isinstance(row, (int, float)) and not isinstance(row, bool):
            return int(row)
    return fallback


def skill_gate_threshold(feature_id: str, fallback: int) -> int:
    """The ``data/skill_gates.json`` threshold for ``feature_id``, or
    ``fallback`` when the gates data is unreadable (the doc-pinned value
    stands in; never invented)."""
    store = data()
    rows: Any = store.skill_gates or store.skill_gates_list
    return _gate_threshold(rows, feature_id, fallback)


def chain_shot_gate() -> int:
    """§4.4b chain-shot gate: gunnery ≥ the ``shot.chain`` threshold (25)."""
    return skill_gate_threshold("shot.chain", DEFAULT_CHAIN_GATE)


def armor_piercing_gate() -> int:
    """§4.4b armor-piercing gate: gunnery ≥ ``shot.armor_piercing`` (50)."""
    return skill_gate_threshold("shot.armor_piercing", DEFAULT_ARMOR_PIERCING_GATE)


def shot_unlocked(shot_type: str, effective_gunnery: int) -> bool:
    """§4.4b gate read against an EFFECTIVE gunnery value — the S10
    selector's disable-state read (the volley path itself gates per-unit
    through ``BattleSim.gunnery_of``). The GDScript static reads the
    player's effective gunnery skill; here the value is injected (the
    caller's skills-module read)."""
    if shot_type == CHAIN_SHOT:
        return effective_gunnery >= chain_shot_gate()
    if shot_type == ARMOR_PIERCING_SHOT:
        return effective_gunnery >= armor_piercing_gate()
    return True


# --- Duel statics (§4.11.6 / §4.12.1.2) -------------------------------------------


def resolve_duel(player_base: int, defender_base: int,
                 rng: GodotRng) -> dict[str, Any]:
    """§4.12.1.2 / §4.11.6 — the **only** duel formula. Both sides roll
    ``base + randi_range(0, 20)`` per round (the player roll first); higher
    wins the round, equal rolls score for neither. First to 3 wins; after 5
    rounds the higher count takes it and equal counts are held by the
    defender (``result: "defeat"``)."""
    rounds: list[str] = []
    player_wins = 0
    defender_wins = 0
    for _index in range(DUEL_MAX_ROUNDS):
        if player_wins >= DUEL_WINS_NEEDED or defender_wins >= DUEL_WINS_NEEDED:
            break
        player_roll = player_base + rng.randi_range(0, DUEL_ROUND_MAX_ROLL)
        defender_roll = defender_base + rng.randi_range(0, DUEL_ROUND_MAX_ROLL)
        if player_roll > defender_roll:
            player_wins += 1
            rounds.append("win")
        elif defender_roll > player_roll:
            defender_wins += 1
            rounds.append("loss")
        else:
            rounds.append("tie")
    return {
        "result": "capture" if player_wins > defender_wins else "defeat",
        "rounds": rounds,
        "player_wins": player_wins,
        "defender_wins": defender_wins,
    }


def defender_duel_base(crew: int, captain_rating: int) -> int:
    """§4.11.6 defender base: ``min(floor(crew / 5), 20) + captain rating``
    (the crew/captain terms only — the defender charisma bonus is applied by
    the boarding path to whichever side defends)."""
    return min(int(math.floor(max(crew, 0) / DUEL_CREW_DIVISOR)), DUEL_CREW_CAP) + captain_rating


def defender_charisma_bonus(charisma: int) -> int:
    """§4.11.6 Phase-8 defender bonus: ``floor(charisma / 20)``."""
    return int(math.floor(max(charisma, 0) / DEFENDER_CHARISMA_DIVISOR))


def surrender_chance_for_courage(courage: int) -> int:
    """§4.7: ``clamp(25 − floor(courage / 10), 10, 40)`` percent."""
    return _clampi(
        SURRENDER_CHANCE_BASE - int(math.floor(max(courage, 0) / SURRENDER_COURAGE_DIVISOR)),
        SURRENDER_CHANCE_MIN, SURRENDER_CHANCE_MAX)


def morale_surrender_bonus(morale: int) -> int:
    """§4.7/§4.8a widening: ``+ floor((20 − morale) / 2)`` pp on top of the
    clamped base (ceiling 50% at morale 0). A negative ``morale`` (the
    compat default) adds nothing."""
    if morale < 0:
        return 0
    return int(math.floor(max(MORALE_SURRENDER_GATE - morale, 0) / SURRENDER_MORALE_DIVISOR))


def equipment_item_modifier(equipment_id: str, stat: str) -> int:
    """Modifier of one equipment id, 0 when the id is empty/unknown
    (§4.11.12 "missing keys read as empty slots")."""
    if not equipment_id:
        return 0
    item = data().get_equipment(equipment_id)
    if not item:
        return 0
    modifiers = item.get("modifiers", {})
    if not isinstance(modifiers, dict):
        return 0
    return int(modifiers.get(stat, 0))


def equipment_modifier(ship: dict[str, Any], slot: str, stat: str) -> int:
    """A ``combat``/``speed``/``durability`` modifier of the item worn in
    ``slot``; 0 for an empty/unknown slot or a non-dict ship."""
    if not isinstance(ship, dict):
        return 0
    equipment = ship.get("equipment", {})
    if not isinstance(equipment, dict):
        return 0
    return equipment_item_modifier(str(equipment.get(slot, "")), stat)


def _clampi(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


# --- Snapshot layout (§4.12.1) -----------------------------------------------------
#
# A flat list of ints of ALL mutable state, EXACTLY invertible, APPEND-ONLY
# (the layout is the oracle's byte-for-byte so M5 golden traces line up):
#   [0]                unit count n
#   per unit (13):     pos.x, pos.y, vel.x, vel.y, heading8, durability, crew,
#                      reload_port, reload_starboard, speed_debuff_turns,
#                      alive, captain_rating, cannon_rating
#   scalars (23):      round, cursor, action_taken, moved_this_turn,
#                      round_had_damage, round_had_boarding, stall_rounds,
#                      last_min_distance, flagship_index, over, result_idx,
#                      cause_idx, [retired morale_bonus slot — always 0],
#                      surrendered_enemy, log count, sunk_enemy count,
#                      sunk_by_player count, captured count, sunk_player
#                      count, lost_player count, rng.state,
#                      player_morale, enemy_morale

_SNAPSHOT_UNIT_FIELDS: Final[int] = 13
_SNAPSHOT_SCALARS: Final[int] = 23
_CAUSE_NAMES: Final[tuple[str, ...]] = ("", "sunk", "captured")

#: The per-turn policy signature: ``policy(sim)`` or ``policy(sim, unit)``,
#: returning the §4.12.1.1 decision dict.
Policy = Callable[..., dict[str, Any]]


class BattleSim:
    """The pure Phase-9 turn engine (docs/60 §4.12.1).

    Config keys (all required unless marked — §4.12.1): ``player_ships``,
    ``enemy_ships``, ``enemy_kind``, ``enemy_nation``, ``day``, ``gold``,
    ``contact``, ``weather``; optional ``seed`` (overrides the §4.11.1
    formula), ``rng`` (a caller-shared :class:`GodotRng` — the §4.11.1 "the
    duel draws from the same stream, after deployment and enemy
    composition" rule), ``deployment`` (``""`` | ``"tournament"``),
    ``encounter_id``, ``wind_dir``, ``current``, ``player_stats`` (the S21
    seam), ``player_morale`` / ``enemy_morale``, ``captain_id`` /
    ``captain`` (the fleet captain canon card) and ``officer_states`` (the
    defensive escort-captain scan input, ``{}`` when absent).
    """

    __slots__ = (
        "enemy_kind", "enemy_nation", "day", "gold", "contact", "weather",
        "wind_dir", "current", "deployment", "encounter_id", "rng",
        "_seed", "_player_ships", "_enemy_ships", "_units", "_order",
        "_round", "_current", "_action_taken", "_moved_this_turn",
        "_started", "_over", "_result", "_flagship_index",
        "_fleet_captain_card", "_player_stats_override", "_officer_states",
        "_stall_rounds", "_last_min_distance", "_round_had_damage",
        "_round_had_boarding", "_sunk_enemy", "_sunk_enemy_by_player",
        "_captured_enemy", "_surrendered_enemy", "_sunk_player",
        "_lost_player", "_player_last_cause", "_player_morale",
        "_enemy_morale", "_player_morale_start", "_enemy_morale_start",
        "_log",
    )

    def __init__(self, config: dict[str, Any]) -> None:
        self._player_ships = self._copy_ships(config.get("player_ships", []))
        self._enemy_ships = self._copy_ships(config.get("enemy_ships", []))
        self.enemy_kind = str(config.get("enemy_kind", "pirate"))
        self.enemy_nation = str(config.get("enemy_nation", ""))
        self.day = int(config.get("day", 0))
        self.gold = int(config.get("gold", 0))
        self.contact = to_cell(config.get("contact", (0, 0)))
        self.weather = str(config.get("weather", "calm"))
        self.deployment = str(config.get("deployment", ""))
        self.encounter_id = str(config.get("encounter_id", ""))
        self.wind_dir = str(config.get("wind_dir", "E"))
        if heading_index(self.wind_dir) < 0:
            self.wind_dir = "E"
        current_config = config.get("current")
        if isinstance(current_config, dict):
            self.current = _deep_copy(current_config)
        else:
            self.current = self._default_current()
        self.current["dir"] = str(self.current.get("dir", ""))
        self.current["strength"] = _clampi(int(self.current.get("strength", 0)), 0, 3)
        self._fleet_captain_card = self._resolve_fleet_captain_card(config)
        stats_override = config.get("player_stats")
        self._player_stats_override: dict[str, Any] = (
            _deep_copy(stats_override) if isinstance(stats_override, dict) else {})
        officer_states = config.get("officer_states")
        self._officer_states: dict[str, Any] = (
            _deep_copy(officer_states) if isinstance(officer_states, dict) else {})
        # §4.8a side-morale starts: optional config keys first (the S21
        # seam), else the doc defaults — the player at the defensive
        # no-run read (0), the AI at clamp(40 + flagship-captain courage,
        # 20, 90). Starts clamp once, so `morale_delta` is exactly
        # clamp(end, 0, 100) − start.
        self._player_morale_start = _clampi(
            int(config.get("player_morale", MORALE_MIN)), MORALE_MIN, MORALE_MAX)
        self._player_morale = self._player_morale_start
        self._enemy_morale_start = _clampi(
            int(config.get("enemy_morale", self._default_enemy_morale())),
            MORALE_MIN, MORALE_MAX)
        self._enemy_morale = self._enemy_morale_start
        shared = config.get("rng")
        if isinstance(shared, GodotRng):
            self.rng = shared
            self._seed = int(shared.seed)
        else:
            self._seed = int(config.get(
                "seed",
                battle_seed_formula(self.day, self.contact, self.gold,
                                    len(self._player_ships))))
            self.rng = GodotRng(self._seed)
        self._units: list[dict[str, Any]] = []
        self._order: list[dict[str, Any]] = []
        self._round = 1
        self._current = -1
        self._action_taken = False
        self._moved_this_turn = False
        self._started = False
        self._over = False
        self._result = RESULT_UNFINISHED
        self._flagship_index = 0
        self._stall_rounds = 0
        self._last_min_distance = -1
        self._round_had_damage = False
        self._round_had_boarding = False
        self._sunk_enemy: list[str] = []
        self._sunk_enemy_by_player: list[str] = []
        self._captured_enemy: list[dict[str, Any]] = []
        self._surrendered_enemy = 0
        self._sunk_player: list[str] = []
        self._lost_player: list[dict[str, Any]] = []
        self._player_last_cause = ""
        self._log: list[dict[str, Any]] = []

    # --- §4.12.1 config defaults --------------------------------------------

    def _default_current(self) -> dict[str, Any]:
        """The decoded contact-tile current (§4.12.1 correction 1): the
        raster's reversal-applied lookup, regardless of any world
        ``current_mode``. Undecoded ocean (headless/off-grid) ⇒ strength 0.
        Raster decode failures degrade to strength 0 — the battle field is
        self-contained."""
        try:
            from server.sim.world.raster import ocean_layers
            decoded = ocean_layers().current_at(
                self.contact[0], self.contact[1], month_for(self.day))
        except Exception:  # noqa: BLE001 — the defensive default stands
            return {"dir": "", "strength": 0}
        if not decoded:
            return {"dir": "", "strength": 0}
        return {
            "dir": str(decoded.get("dir", "")),
            "strength": _clampi(int(decoded.get("strength", 0)), 0, 3),
        }

    @staticmethod
    def _resolve_fleet_captain_card(config: dict[str, Any]) -> dict[str, Any]:
        captain_id = str(config.get("captain_id", ""))
        if not captain_id:
            captain = config.get("captain")
            if isinstance(captain, str):
                captain_id = captain
            elif isinstance(captain, dict):
                captain_id = str(captain.get("id", ""))
        return captain_canon_card(captain_id)

    # --- Lifecycle (§4.12.1) --------------------------------------------------

    def start(self) -> None:
        if self._started:
            return
        self._started = True
        self._units = []
        tournament = self.deployment == TOURNAMENT_DEPLOYMENT
        for index, ship in enumerate(self._player_ships):
            self._units.append(self._make_unit(
                SIDE_PLAYER, index, ship,
                self._deploy_cell(SIDE_PLAYER, index), tournament))
        for index, ship in enumerate(self._enemy_ships):
            self._units.append(self._make_unit(
                SIDE_ENEMY, index, ship,
                self._deploy_cell(SIDE_ENEMY, index), tournament))
        self._price_captain_ratings()
        self._price_broadside_split()
        self._price_gunnery()
        self._round = 1
        self._current = -1
        self._action_taken = False
        self._moved_this_turn = False
        self._stall_rounds = 0
        self._round_had_damage = False
        self._round_had_boarding = False
        self._last_min_distance = self._min_pair_distance()
        self._flagship_index = self._lowest_living_index(SIDE_PLAYER)
        self._check_over()
        if self._over:
            return
        self._build_order()  # ONCE at battle start (§4.3/§4.11.4).
        self._advance()

    def round_number(self) -> int:
        return self._round

    def seed_value(self) -> int:
        """The §4.11.1 seed actually in use (a config ``seed`` override
        wins; the shared-``rng`` form reports the stream's own seed)."""
        return self._seed

    def is_over(self) -> bool:
        return self._over

    def current_unit(self) -> dict[str, Any]:
        if self._over or self._current < 0 or self._current >= len(self._order):
            return {}
        unit = self._order[self._current]
        if not isinstance(unit, dict) or not bool(unit.get("alive", False)):
            return {}
        return unit

    def is_acting(self, unit: dict[str, Any]) -> bool:
        """True when ``unit`` is the ship whose turn it is. A not-yet-started
        battle has no cursor, so configuration-time calls are allowed."""
        if not self._started:
            return True
        acting = self.current_unit()
        return bool(acting) and acting is unit

    def end_turn(self) -> None:
        """Ends the acting unit's turn; advances to the next living unit in
        initiative order, rolling into the next round (§4.11.4). The
        chain-shot cap debuff counts the turn that just ended (§4.3a — it
        must cover the fired-upon ship's next TWO turns for ``+2``, so it
        decrements at turn END)."""
        if self._over:
            return
        acting = self.current_unit()
        if acting and int(acting.get("speed_debuff_turns", 0)) > 0:
            acting["speed_debuff_turns"] = int(acting["speed_debuff_turns"]) - 1
        self._action_taken = False
        self._moved_this_turn = False
        self._check_over()
        if self._over:
            return
        self._advance()

    def outcome(self) -> dict[str, Any]:
        """The §4.12.2 outcome block; ``{}`` until :meth:`is_over`."""
        if not self._over:
            return {}
        neutralized = len(self._sunk_enemy) + len(self._captured_enemy)
        rounds_lasted = max(self._round, 1)
        # §4.10 "Retreating forfeits nothing but costs no XP": a retreat
        # awards nothing, while everything already earned stands.
        xp = 0 if self._result == RESULT_RETREAT else (
            neutralized * XP_PER_ENEMY_NEUTRALIZED + rounds_lasted * XP_PER_ROUND)
        contact_x, contact_y = self.contact
        return {
            "result": self._result,
            "rounds": rounds_lasted,
            "kind": self.enemy_kind,
            "nation_id": self.enemy_nation,
            "encounter_id": self.encounter_id,
            "contact": {"x": contact_x, "y": contact_y},
            "sunk_enemy": list(self._sunk_enemy),
            "captured_enemy": [_deep_copy(ship) for ship in self._captured_enemy],
            "surrendered_enemy": self._surrendered_enemy,
            "sunk_player": list(self._sunk_player),
            "lost_player": [_deep_copy(ship) for ship in self._lost_player],
            "salvage_gold": self._salvage_gold(),
            "xp": xp,
            "rep_deltas": self._rep_deltas(),
            "morale_delta": self.morale_delta_for(SIDE_PLAYER),
            "cargo_overflow_lost": 0,
        }

    # --- Unit enumeration (S10 / AiFleet seam) ---------------------------------

    def units(self) -> list[dict[str, Any]]:
        """Every unit dict, living or not (killed units keep their last
        state). The dicts are the engine's handles — not copies."""
        return list(self._units)

    def living_units(self, side: str) -> list[dict[str, Any]]:
        out = [u for u in self._units
               if u.get("side") == side and bool(u.get("alive", False))]
        out.sort(key=lambda u: int(u["index"]))
        return out

    def flagship_unit(self) -> dict[str, Any]:
        return self._flagship_unit()

    def flagship_index(self) -> int:
        return self._flagship_index

    # --- Grid / movement (docs/60 §4.2, §4.3a, §4.11.4) -------------------------

    def unit_cell(self, unit: dict[str, Any]) -> Cell:
        if "pos" in unit:
            return to_cell(unit["pos"])
        # Compat read for stale fixtures that still author `cell`.
        return to_cell(unit.get("cell", NO_CELL))

    def battle_max_speed(self, unit: dict[str, Any]) -> int:
        return max(1, int(self._ship_type_of(unit).get("battle_max_speed", 2)))

    def battle_accel(self, unit: dict[str, Any]) -> int:
        return max(1, int(self._ship_type_of(unit).get("battle_accel", 1)))

    def battle_turn_rate(self, unit: dict[str, Any]) -> int:
        return max(45, int(self._ship_type_of(unit).get("battle_turn_rate", 45)))

    def _ship_type_of(self, unit: dict[str, Any]) -> dict[str, Any]:
        ship = unit.get("ship", {})
        if not isinstance(ship, dict):
            return {}
        return data().get_ship_type(str(ship.get("ship_type_id", "")))

    def ship_class_of(self, unit: dict[str, Any]) -> str:
        return str(self._ship_type_of(unit).get("class", "sail"))

    def initiative_key(self, unit: dict[str, Any]) -> int:
        """§4.11.4 initiative key: ``ShipType.speed + sail_speed_delta``
        (correction 2, §4.11.12)."""
        ship = unit.get("ship", {})
        if not isinstance(ship, dict):
            return 0
        ship_type = data().get_ship_type(str(ship.get("ship_type_id", "")))
        return int(ship_type.get("speed", 0)) + equipment_modifier(ship, "sail", "speed")

    def legal_velocities(self, unit: dict[str, Any]) -> list[Cell]:
        """§4.3a: every integer velocity in the Chebyshev box
        ``|vx|, |vy| ≤ battle_max_speed`` satisfying, in the §4.11.4 order:
        bucket angle to the old velocity ≤ ``battle_turn_rate`` (skipped
        from standstill), magnitude delta ≤ ``battle_accel``, ``‖vel‖ ≤
        cap_eff``. ``vel = (0,0)`` reads only the magnitude-delta
        constraint. Enumerated in **(y, x) lexicographic order** — the
        enumeration order is the deterministic tie-break everywhere
        (§4.11.8, decision 13)."""
        out: list[Cell] = []
        if not isinstance(unit, dict) or not bool(unit.get("alive", False)):
            return out
        max_speed = self.battle_max_speed(unit)
        accel = float(self.battle_accel(unit))
        cap = float(self.cap_eff(unit))
        old_vel = to_cell(unit.get("vel", (0, 0)))
        old_heading = int(unit.get("heading8", HEADING_EAST))
        old_mag = vel_length(old_vel)
        turn_rate = self.battle_turn_rate(unit)
        for vy in range(-max_speed, max_speed + 1):
            for vx in range(-max_speed, max_speed + 1):
                vel = (vx, vy)
                mag = vel_length(vel)
                if vel == (0, 0):
                    if abs(mag - old_mag) <= accel:
                        out.append(vel)
                    continue
                if old_vel != (0, 0):
                    steps = bucket_distance(heading8_of(vel), old_heading)
                    if steps * 45 > turn_rate:
                        continue
                if abs(mag - old_mag) > accel:
                    continue
                if mag > cap:
                    continue
                out.append(vel)
        return out

    def apply_velocity(self, unit: dict[str, Any], vel: Cell) -> bool:
        """§4.12.1 ``apply_velocity``: validate (the §4.11.4 order — angle,
        magnitude delta; the CAP leg clamps instead of rejecting) → clamp
        the magnitude overshoot along the chosen direction (component
        floor) → integrate as the Bresenham sweep. ``vel = (0,0)`` keeps
        the last heading. Returns False (state untouched) on any illegal
        pick or once the turn's movement is spent — movement happens
        exactly once per turn (§4.3)."""
        if self._over or self._moved_this_turn:
            return False
        if not isinstance(unit, dict) or not bool(unit.get("alive", False)):
            return False
        if not self.is_acting(unit):
            return False
        vel = to_cell(vel)
        if abs(vel[0]) > self.battle_max_speed(unit) or abs(vel[1]) > self.battle_max_speed(unit):
            return False
        old_vel = to_cell(unit.get("vel", (0, 0)))
        old_mag = vel_length(old_vel)
        # ① heading-bucket angle (skipped from standstill and for a (0,0) pick).
        if vel != (0, 0) and old_vel != (0, 0):
            steps = bucket_distance(heading8_of(vel), int(unit.get("heading8", HEADING_EAST)))
            if steps * 45 > self.battle_turn_rate(unit):
                return False
        # ② magnitude delta.
        mag = vel_length(vel)
        if abs(mag - old_mag) > float(self.battle_accel(unit)):
            return False
        # ③ cap — the overshoot clamps along the chosen direction.
        applied = vel
        cap = float(self.cap_eff(unit))
        if mag > cap and mag > 0.0:
            scale = cap / mag
            applied = (int(math.floor(vel[0] * scale)), int(math.floor(vel[1] * scale)))
        self._moved_this_turn = True
        if applied != (0, 0):
            self._sweep(unit, applied)
            # The committed velocity sets the heading (§4.3a).
            unit["heading8"] = heading8_of(applied)
        # The new velocity IS the unit's state — a (0,0) pick keeps the
        # last heading and holds position.
        unit["vel"] = applied
        return True

    def cap_eff(self, unit: dict[str, Any]) -> int:
        """§4.3a ``cap_eff`` (decision 2, corrections 1–3):
        ``clamp(floor(battle_max_speed × wind_factor × direction_factor)
        ± current_mod − debuff, 0, battle_max_speed) + sail_speed_delta`` —
        the current modifier rides inside the clamp, the chain-shot debuff
        floors at 1, and the sail delta applies after the clamp, unclamped
        back (§4.11.12, correction 2)."""
        max_speed = self.battle_max_speed(unit)
        ship_class = self.ship_class_of(unit)
        wind = wind_factor(self.weather, ship_class)
        direction = self._direction_factor(unit)
        mod = self._current_mod(unit)
        cap = _clampi(
            int(math.floor(max_speed * wind * direction)) + mod, 0, max_speed)
        if int(unit.get("speed_debuff_turns", 0)) > 0:
            cap = max(1, cap - 1)
        ship = unit.get("ship", {})
        sail_delta = 0
        if isinstance(ship, dict):
            sail_delta = equipment_modifier(ship, "sail", "speed")
        return cap + sail_delta

    def _direction_factor(self, unit: dict[str, Any]) -> float:
        """§4.3a direction_factor: identity 1.0 in calm weather (the world
        rule, 20-* §4.7.1); otherwise the §4.4 table read at the bucket
        angle between the ship's heading8 and the locked wind-FROM
        direction, at the ship's own class column (``sail`` fallback)."""
        if self.weather == "calm":
            return 1.0
        bucket = self._heading_wind_bucket(unit)
        if bucket < 0:
            return 1.0
        table = DIRECTION_FACTORS.get(bucket, {})
        ship_class = self.ship_class_of(unit)
        return float(table.get(ship_class, table.get("sail", 1.0)))

    def _heading_wind_bucket(self, unit: dict[str, Any]) -> int:
        token = self._heading_token(int(unit.get("heading8", HEADING_EAST)))
        return angle_between_dirs(token, self.wind_dir)

    def _heading_current_bucket(self, unit: dict[str, Any]) -> int:
        flow = str(self.current.get("dir", ""))
        if not flow or heading_index(flow) < 0:
            return -1
        token = self._heading_token(int(unit.get("heading8", HEADING_EAST)))
        return angle_between_dirs(token, flow)

    def _current_mod(self, unit: dict[str, Any]) -> int:
        """§4.3a current modifier (correction 1): bucket ∈ {0°, 45°} with
        strength ≥ 2 → +1; bucket ∈ {135°, 180°} with strength = 3 → −1;
        strength 0 never modifies."""
        strength = int(self.current.get("strength", 0))
        if strength <= 0:
            return 0
        bucket = self._heading_current_bucket(unit)
        if bucket < 0:
            return 0
        if bucket in (0, 45) and strength >= 2:
            return 1
        if bucket in (135, 180) and strength == 3:
            return -1
        return 0

    @staticmethod
    def _heading_token(heading8: int) -> str:
        return HEADING_TOKENS[heading8 % len(HEADING_TOKENS)]

    def _sweep(self, unit: dict[str, Any], applied: Cell) -> None:
        """§4.3a sweep integration: the Bresenham walk cell by cell; the
        FIRST occupied cell stops the ship — enemy-occupied ⇒ the §4.5
        sweep ram, friend-occupied or out-of-bounds ⇒ stop at the PRIOR
        cell (zero damage, no partial entry)."""
        target = (self.unit_cell(unit)[0] + applied[0], self.unit_cell(unit)[1] + applied[1])
        prior = self.unit_cell(unit)
        for cell in bresenham_cells(prior, target):
            if not in_grid(cell):
                unit["pos"] = prior
                return
            occupant = self._living_unit_at(cell, unit)
            if occupant:
                unit["pos"] = prior
                if str(occupant.get("side", "")) != str(unit.get("side", "")):
                    # Sweep ram (§4.5): the impact speed is the APPLIED velocity.
                    self._resolve_ram(unit, occupant, vel_length(applied))
                return
            unit["pos"] = cell
            prior = cell

    def _living_unit_at(self, cell: Cell, exclude: Any) -> dict[str, Any]:
        for other in self._units:
            if other is exclude or not bool(other.get("alive", False)):
                continue
            if self.unit_cell(other) == cell:
                return other
        return {}

    # --- Cannon (docs/60 §4.4, §4.4a, §4.4b, §4.11.5) ----------------------------

    def gunnery_of(self, unit: dict[str, Any]) -> int:
        """The per-unit gunnery source (§4.4a/§4.11.5, priced once at
        battle start by :meth:`_price_gunnery`)."""
        return int(unit.get("gunnery", 0))

    def side_cannons(self, unit: dict[str, Any], side: str) -> int:
        key = "cannons_port" if side == BROADSIDE_PORT else "cannons_starboard"
        return max(0, int(unit.get(key, 0)))

    def can_cannon(self, unit: Any, target: Any, side: str = "") -> bool:
        """§4.4: true when the NAMED side can fire at ``target`` — the
        side's arc contains the target (a dead-ahead/dead-astern target
        sits in neither arc), Chebyshev range 1..3, the side loaded and
        carrying ≥ 1 cannon. ``side == ""`` asks whether EITHER side can."""
        if not isinstance(unit, dict) or not isinstance(target, dict):
            return False
        if not bool(unit.get("alive", False)) or not bool(target.get("alive", False)):
            return False
        if unit.get("side") == target.get("side"):
            return False
        distance = _chebyshev(self.unit_cell(unit), self.unit_cell(target))
        if distance < CANNON_RANGE_MIN or distance > CANNON_RANGE_MAX:
            return False
        if side in (BROADSIDE_PORT, BROADSIDE_STARBOARD):
            return self._side_can_fire(unit, target, side, distance)
        return (self._side_can_fire(unit, target, BROADSIDE_PORT, distance)
                or self._side_can_fire(unit, target, BROADSIDE_STARBOARD, distance))

    def _side_can_fire(self, unit: dict[str, Any], target: dict[str, Any],
                       side: str, distance: int) -> bool:
        if self._round < int(unit.get(self._reload_key(side), 1)):
            return False
        if self.side_cannons(unit, side) < 1:
            return False
        bearing = heading8_of((self.unit_cell(target)[0] - self.unit_cell(unit)[0],
                               self.unit_cell(target)[1] - self.unit_cell(unit)[1]))
        # §4.4 arcs are SIGNED counterclockwise steps off the attacker's
        # heading8 — the unsigned bucket_distance can never reach the
        # starboard set (W3-D bounce-back fix).
        steps = (bearing - int(unit.get("heading8", HEADING_EAST)) + 8) % 8
        arc = ARC_PORT_STEPS if side == BROADSIDE_PORT else ARC_STARBOARD_STEPS
        return steps in arc

    @staticmethod
    def _reload_key(side: str) -> str:
        return "reload_port" if side == BROADSIDE_PORT else "reload_starboard"

    def cannon_bonus(self, unit: dict[str, Any]) -> int:
        """§4.11.5 ``bonus``: ``floor(effective_gunnery / 25)`` for the
        player flagship and ``floor(combat_rating / 10)`` for every
        captain-card ship."""
        if unit.get("side") == SIDE_PLAYER and int(unit["index"]) == self._flagship_index:
            return self.cannon_bonus_flagship()
        return int(math.floor(float(self.combat_rating(unit)) / COMBAT_BONUS_DIVISOR))

    def cannon_bonus_flagship(self) -> int:
        """§4.4 flagship gunnery term alone (goes through the S21 override,
        so an in-post gunner officer feeds the damage on the caller side)."""
        return int(math.floor(
            float(self.player_effective_skill("gunnery")) / GUNNERY_BONUS_DIVISOR))

    def combat_rating(self, unit: dict[str, Any]) -> int:
        """§4.11.5: the ship's captain-card cannon rating, priced once at
        battle start. The player flagship is not a captain-card ship (0)."""
        if not isinstance(unit, dict):
            return 0
        if unit.get("side") == SIDE_PLAYER and int(unit["index"]) == self._flagship_index:
            return 0
        return int(unit.get("cannon_rating", 0))

    def reload_turns_of(self, unit: dict[str, Any]) -> int:
        """§4.4a (correction 14): ``clamp(2 − floor(gunnery / 50), 1, 2) +
        (crew_ratio < 0.5 ? 1 : 0)``, ``crew_ratio = crew / crew_min``."""
        turns = _clampi(
            RELOAD_BASE_TURNS
            - int(math.floor(self.gunnery_of(unit) / RELOAD_GUNNERY_DIVISOR)),
            RELOAD_MIN_TURNS, RELOAD_BASE_TURNS)
        ship = unit.get("ship", {})
        crew_min = int(data().get_ship_type(
            str(ship.get("ship_type_id", ""))).get("crew_min", 0)) if isinstance(ship, dict) else 0
        ratio = float(unit.get("crew", 0)) / float(max(crew_min, 1))
        if ratio < RELOAD_LOW_CREW_RATIO:
            turns += RELOAD_LOW_CREW_BONUS
        return turns

    def cannon_damage(self, unit: dict[str, Any], target: dict[str, Any],
                      side: str) -> int:
        """§4.4 damage preview for a named side (the stack WITHOUT the shot
        term — round shot). Static-only inputs."""
        distance = _chebyshev(self.unit_cell(unit), self.unit_cell(target))
        factor = float(CANNON_RANGE_FACTOR.get(distance, 0.0))
        base = float(self.side_cannons(unit, side)) * CANNON_BASE_MULTIPLIER * factor
        base += float(self.cannon_bonus(unit))
        product = base * self._weather_damage_mult() * 1.0
        if self._is_rake_on(target, unit):
            product *= RAKE_MULTIPLIER
        return int(math.floor(product))

    def _weather_damage_mult(self) -> float:
        if self.weather == STORM_WEATHER:
            return STORM_CANNON_MULTIPLIER
        if self.weather == STRONG_WEATHER:
            return STRONG_CANNON_MULTIPLIER
        return 1.0

    def _is_rake_on(self, target: dict[str, Any], attacker: dict[str, Any]) -> bool:
        """§4.4 rake: the bearing bucket from TARGET to ATTACKER relative to
        the TARGET's own heading8 ∈ {0°, 180°}."""
        tx, ty = self.unit_cell(target)
        ax, ay = self.unit_cell(attacker)
        bearing = heading8_of((ax - tx, ay - ty))
        steps = bucket_distance(bearing, int(target.get("heading8", HEADING_EAST)))
        return steps == 0 or steps == 4

    def ai_shot_type(self, attacker: dict[str, Any], target: dict[str, Any]) -> str:
        """§4.4b deterministic AI shot rule (T2/T3 shared; evaluated in
        order; always OUTSIDE any T3 enumeration — decisions 4/13):
        1. chain on a fleeing fast target (gunnery ≥ 25);
        2. grape in the close-quarters window (range 1 only — beyond it the
           rule falls through);
        3. armor-piercing into a plated player ship (gunnery ≥ 50);
        4. otherwise round."""
        distance = _chebyshev(self.unit_cell(attacker), self.unit_cell(target))
        # 1. chain on a fleeing fast target.
        if self._vel_floor(target) >= 2:
            tvel = to_cell(target.get("vel", (0, 0)))
            projected = (self.unit_cell(target)[0] + tvel[0],
                         self.unit_cell(target)[1] + tvel[1])
            current_distance = distance
            if (_chebyshev(self.unit_cell(attacker), projected) > current_distance
                    and self.gunnery_of(attacker) >= chain_shot_gate()):
                return CHAIN_SHOT
        # 2. grape in the close-quarters window.
        own_rating = int(attacker.get("crew", 0)) + int(attacker.get("captain_rating", 0))
        target_rating = int(target.get("crew", 0)) + int(target.get("captain_rating", 0))
        if distance <= 2 and own_rating > target_rating:
            if distance == CANNON_RANGE_MIN:
                return GRAPE_SHOT
        # 3. armor-piercing into a plated player ship.
        if str(target.get("side", "")) == SIDE_PLAYER:
            ship = target.get("ship", {})
            equipment = ship.get("equipment", {}) if isinstance(ship, dict) else {}
            if (isinstance(equipment, dict)
                    and str(equipment.get("armor", ""))
                    and self.gunnery_of(attacker) >= armor_piercing_gate()):
                return ARMOR_PIERCING_SHOT
        return ROUND_SHOT

    def cannon(self, unit: dict[str, Any], target: dict[str, Any],
               side: str = "", shot_type: str = ROUND_SHOT) -> dict[str, Any]:
        """§4.4 broadside volley: ``side`` ∈ port/starboard — ``""`` = the
        §4.11.8 pick (rake beats non-rake, then more cannons, tie → port) —
        and ``shot_type`` per §4.4b (default round). The multipliers
        multiply and exactly ONE floor lands at the end, after the weather
        term. After the volley the side reloads (§4.4a). Grape swaps the
        hull damage for its §4.4b halved pair and the crew kill IS the
        volley's casualty term (§4.11.5)."""
        result: dict[str, Any] = {"ok": False, "damage": 0, "sunk": False, "log": {}}
        if self._over or self._action_taken or not self.is_acting(unit):
            return result
        if not isinstance(target, dict) or not target or not self.can_cannon(unit, target, side):
            return result
        distance = _chebyshev(self.unit_cell(unit), self.unit_cell(target))
        if shot_type == GRAPE_SHOT and distance != CANNON_RANGE_MIN:
            # §4.4b: grape is range 1 ONLY — not a lock, a range gate.
            result["range"] = distance
            result["shot"] = GRAPE_SHOT
            return result
        if shot_type in (CHAIN_SHOT, ARMOR_PIERCING_SHOT):
            gate = chain_shot_gate() if shot_type == CHAIN_SHOT else armor_piercing_gate()
            if self.gunnery_of(unit) < gate:
                result["locked"] = True
                result["gate"] = gate
                result["shot"] = shot_type
                return result
        resolved_side = side
        if resolved_side not in (BROADSIDE_PORT, BROADSIDE_STARBOARD):
            resolved_side = self._pick_broadside_side(unit, target)
            if not resolved_side:
                return result
        self._action_taken = True
        result["ok"] = True
        # The §4.4 stack — one floor at the end, after the weather term.
        factor = float(CANNON_RANGE_FACTOR.get(distance, 0.0))
        base = float(self.side_cannons(unit, resolved_side)) * CANNON_BASE_MULTIPLIER * factor
        base += float(self.cannon_bonus(unit))
        weather_mult = self._weather_damage_mult()
        rake = RAKE_MULTIPLIER if self._is_rake_on(target, unit) else 1.0
        round_damage = int(math.floor(base * weather_mult * rake))
        damage = round_damage
        crew_kill = 0
        if shot_type == CHAIN_SHOT:
            damage = int(math.floor(base * weather_mult * CHAIN_DAMAGE_MULTIPLIER * rake))
        elif shot_type == ARMOR_PIERCING_SHOT:
            damage = int(math.floor(
                base * weather_mult * ARMOR_PIERCING_DAMAGE_MULTIPLIER * rake))
        elif shot_type == GRAPE_SHOT:
            damage = int(math.floor(float(round_damage) * GRAPE_HALF))
            # §4.4b/§4.11.5: the grape kill IS the volley's casualty term —
            # it replaces the /20 (and /10 rake) divisor rule for that volley.
            crew_kill = int(math.floor(float(round_damage) * GRAPE_HALF))
        else:
            shot_type = ROUND_SHOT
        # §4.11.5 crew casualties: rake /10, standard /20. Clamped at 0.
        if shot_type != GRAPE_SHOT:
            crew_kill = damage // (CREW_CASUALTY_RAKE_DIVISOR if rake > 1.0
                                   else CREW_CASUALTY_DIVISOR)
        crew_kill = max(crew_kill, 0)
        # The named side reloads (§4.4a).
        unit[self._reload_key(resolved_side)] = self._round + self.reload_turns_of(unit)
        result["side"] = resolved_side
        result["shot"] = shot_type
        result["rake"] = rake > 1.0
        result["crew_kill"] = crew_kill
        result["damage"] = damage
        ship = target["ship"]
        ship["durability"] = int(ship.get("durability", 0)) - damage
        target["crew"] = max(int(target.get("crew", 0)) - crew_kill, 0)
        sunk = int(ship["durability"]) <= 0
        if sunk:
            self._sink(target, str(unit.get("side", "")), "cannon")
        elif shot_type == CHAIN_SHOT:
            # §4.4b: chain also slows — +2 cap-debuff turns (§4.3a).
            target["speed_debuff_turns"] = (
                int(target.get("speed_debuff_turns", 0)) + CHAIN_DEBUFF_TURNS)
        if rake > 1.0:
            # §4.8a event: the side suffering a rake volley −5 (any shot type).
            self._morale_event(str(target.get("side", "")), MORALE_EVENT_RAKED)
        result["sunk"] = sunk
        if damage > 0 or crew_kill > 0:
            self._round_had_damage = True
        result["log"] = self._make_log("cannon", unit, target, {
            "damage": damage, "sunk": sunk, "range": distance,
            "shot": shot_type, "side": resolved_side, "rake": rake > 1.0,
            "crew_kill": crew_kill,
        })
        self._check_over()
        return result

    def _pick_broadside_side(self, unit: dict[str, Any],
                             target: dict[str, Any]) -> str:
        """§4.11.8 rule 2's side pick among the fireable sides: a
        rake-position volley beats a non-rake, then the loaded side with
        more cannons, tie → port."""
        distance = _chebyshev(self.unit_cell(unit), self.unit_cell(target))
        best = ""
        best_rake = False
        best_cannons = -1
        for side in (BROADSIDE_PORT, BROADSIDE_STARBOARD):
            if not self._side_can_fire(unit, target, side, distance):
                continue
            rake = self._is_rake_on(target, unit)
            cannons = self.side_cannons(unit, side)
            if (not best or (rake and not best_rake)
                    or (rake == best_rake and cannons > best_cannons)):
                best = side
                best_rake = rake
                best_cannons = cannons
        return best

    # --- Ram (docs/60 §4.5, §4.11.5) ----------------------------------------------

    def can_ram(self, unit: Any, target: Any) -> bool:
        """True for an orthogonally adjacent living enemy (the §4.5 action
        ram; the sweep ram is triggered by :meth:`_sweep` instead)."""
        if not isinstance(unit, dict) or not isinstance(target, dict):
            return False
        if not bool(unit.get("alive", False)) or not bool(target.get("alive", False)):
            return False
        if unit.get("side") == target.get("side"):
            return False
        return _manhattan(self.unit_cell(unit), self.unit_cell(target)) == 1

    def ram(self, unit: dict[str, Any], target: dict[str, Any]) -> dict[str, Any]:
        """§4.5 action ram against an orthogonally adjacent enemy: both take
        damage; the attacker resolves last (§4.11.5). The impact speed is
        the attacker's CURRENT velocity."""
        result: dict[str, Any] = {
            "ok": False, "damage": 0, "attacker_damage": 0,
            "sunk": False, "attacker_sunk": False, "log": {},
        }
        if self._over or self._action_taken or not self.is_acting(unit) or not self.can_ram(unit, target):
            return result
        self._action_taken = True
        result["ok"] = True
        speed = vel_length(to_cell(unit.get("vel", (0, 0))))
        applied = self._resolve_ram(unit, target, speed)
        result.update({k: applied[k] for k in
                       ("damage", "attacker_damage", "sunk", "attacker_sunk", "log")})
        return result

    def _resolve_ram(self, attacker: dict[str, Any], target: dict[str, Any],
                     speed: float) -> dict[str, Any]:
        """The §4.5 ram resolution shared by the action ram and the sweep
        entry: ``mult = (1 + 0.25 × (floor(‖vel‖) − 1)) × (bow/stern ?
        1.15 : 1)`` with an oar/hybrid attacker's ×1.25 folded in before
        the floors; target ``floor(att_max_dur × 0.25 × mult)``, self
        ``floor(att_max_dur × 0.10 × mult)`` — the attacker's EFFECTIVE max
        durability (§4.11.12). Target first, attacker last."""
        att_max = self.effective_max_durability(attacker["ship"])
        mult = 1.0 + RAM_SPEED_STEP * (math.floor(max(speed, 0.0)) - 1.0)
        tx, ty = self.unit_cell(target)
        ax, ay = self.unit_cell(attacker)
        bearing = heading8_of((tx - ax, ty - ay))
        if bucket_distance(bearing, int(target.get("heading8", HEADING_EAST))) in (0, 4):
            mult *= RAM_BOW_STERN_MULTIPLIER
        if self.ship_class_of(attacker) in OAR_SHIP_CLASSES:
            mult *= OAR_RAM_MULTIPLIER
        target_damage = int(math.floor(float(att_max) * RAM_TARGET_FRACTION * mult))
        attacker_damage = int(math.floor(float(att_max) * RAM_ATTACKER_FRACTION * mult))
        # Target first, then the attacker (§4.11.5 "attacker resolves last").
        target_ship = target["ship"]
        target_ship["durability"] = int(target_ship.get("durability", 0)) - target_damage
        target_sunk = int(target_ship["durability"]) <= 0
        if target_sunk:
            self._sink(target, str(attacker.get("side", "")), "ram")
        attacker_ship = attacker["ship"]
        attacker_ship["durability"] = int(attacker_ship.get("durability", 0)) - attacker_damage
        attacker_sunk = int(attacker_ship["durability"]) <= 0
        if attacker_sunk:
            self._sink(attacker, str(target.get("side", "")), "ram")
        if target_damage > 0 or attacker_damage > 0:
            self._round_had_damage = True
        return {
            "damage": target_damage, "attacker_damage": attacker_damage,
            "sunk": target_sunk, "attacker_sunk": attacker_sunk,
            "log": self._make_log("ram", attacker, target, {
                "damage": target_damage, "attacker_damage": attacker_damage,
                "sunk": target_sunk, "attacker_sunk": attacker_sunk,
            }),
        }

    # --- Boarding & duel (docs/60 §4.6, §4.6a, §4.11.6) -----------------------------

    def can_board(self, unit: Any, target: Any) -> bool:
        """§4.6a hook condition (decision 8): orthogonal adjacency + BOTH
        ships at ``floor(‖vel‖) ≤ 1`` + weather ≠ storm."""
        if not self.can_ram(unit, target):
            return False
        if self.weather == STORM_WEATHER:
            return False
        return self._vel_floor(unit) <= 1 and self._vel_floor(target) <= 1

    @staticmethod
    def _vel_floor(unit: dict[str, Any]) -> int:
        return int(math.floor(vel_length(to_cell(unit.get("vel", (0, 0))))))

    def board(self, unit: dict[str, Any], target: dict[str, Any]) -> dict[str, Any]:
        """Resolves a boarding attempt: the hook sets BOTH ships'
        ``vel = (0,0)`` (correction 7), the duel runs through
        :func:`resolve_duel` (the single implementation, §4.12.1.2), and
        the loser is captured. The winning side's crew pays the §4.11.5
        boarding casualty ``floor(crew × 0.2)``. The §4.8a boarding events
        book afterwards: the WINNER's side +10, the loser −10."""
        result: dict[str, Any] = {"ok": False, "duel": {}, "captured": {}, "lost": {}, "log": {}}
        if self._over or self._action_taken or not self.is_acting(unit) or not self.can_board(unit, target):
            return result
        self._action_taken = True
        # §4.6a: the hook succeeds — both ships' velocity zeroes.
        unit["vel"] = (0, 0)
        target["vel"] = (0, 0)
        self._round_had_boarding = True
        enemy_unit = target if target.get("side") == SIDE_ENEMY else unit
        player_unit = target if target.get("side") == SIDE_PLAYER else unit
        # §4.11.6 bases. The defending side — the boarded ship — adds
        # ``floor(charisma / 20)``: the player's own charisma when the
        # player defends, the captain card's otherwise.
        player_defends = str(target.get("side", "")) == SIDE_PLAYER
        player_base = self.player_duel_base()
        defender_base = defender_duel_base(
            int(enemy_unit.get("crew", 0)),
            int(enemy_unit.get("captain_rating", CAPTAIN_RATING_BASE)))
        if player_defends:
            player_base += defender_charisma_bonus(self.player_attribute("charisma"))
        else:
            defender_base += defender_charisma_bonus(self.captain_charisma(enemy_unit))
        duel = resolve_duel(player_base, defender_base, self.rng)
        result["duel"] = duel
        player_won = str(duel.get("result", "")) == "capture"
        winner = player_unit if player_won else enemy_unit
        # §4.11.5 boarding casualty on the winner, clamped at 0 (§4.6a).
        winner["crew"] = max(
            int(winner.get("crew", 0))
            - int(math.floor(float(winner.get("crew", 0)) * BOARDING_CREW_LOSS_FRACTION)),
            0)
        if player_won:
            self._capture(enemy_unit)
            result["captured"] = _deep_copy(enemy_unit["ship"])
            self._morale_event(SIDE_PLAYER, MORALE_EVENT_BOARDING_WIN)
            self._morale_event(SIDE_ENEMY, MORALE_EVENT_BOARDING_LOSS)
        else:
            self._capture(player_unit)
            result["lost"] = _deep_copy(player_unit["ship"])
            self._morale_event(SIDE_ENEMY, MORALE_EVENT_BOARDING_WIN)
            self._morale_event(SIDE_PLAYER, MORALE_EVENT_BOARDING_LOSS)
        result["ok"] = True
        result["log"] = self._make_log("board", unit, target, {
            "won": player_won, "player_wins": int(duel.get("player_wins", 0)),
            "defender_wins": int(duel.get("defender_wins", 0)),
        })
        self._check_over()
        return result

    # --- Person-model accessors (the S21 seam; §4.12.1) ------------------------------

    def player_attribute(self, key: str) -> int:
        """Slot A's ``Character.attribute(key)``: the per-key
        ``player_stats`` override first, else 0 (the defensive no-run read
        — the Python engine has no autoload to fall back to; the caller
        injects the run's Person block through ``player_stats``)."""
        override = self._player_stats_override.get("attributes")
        if isinstance(override, dict) and key in override:
            return int(override[key])
        return 0

    def player_effective_skill(self, key: str) -> int:
        """Slot A's ``Skills.effective_skill(key)``: the per-key override
        first, else 0 (see :meth:`player_attribute`)."""
        override = self._player_stats_override.get("skills")
        if isinstance(override, dict) and key in override:
            return int(override[key])
        return 0

    def player_duel_base(self) -> int:
        """§4.11.6 player base: swordplay + ``floor(courage / 20)`` + the
        sum of ``combat`` modifiers on worn weapon/armor equipment
        (§4.11.12). The override's ``equipment`` wins when present."""
        base = (self.player_effective_skill("swordplay")
                + int(math.floor(self.player_attribute("courage") / DUEL_COURAGE_DIVISOR)))
        equipment = self._player_stats_override.get("equipment")
        if not isinstance(equipment, dict):
            equipment = {}
        for slot in ("weapon", "armor"):
            base += equipment_item_modifier(str(equipment.get(slot, "")), "combat")
        return base

    def captain_charisma(self, unit: dict[str, Any]) -> int:
        """§4.11.6: the charisma the captain behind ``unit`` brings to the
        defender bonus — the ship-carried ``captain_charisma`` key, else the
        fleet's canon card; 0 for anything else."""
        if not isinstance(unit, dict) or unit.get("side") != SIDE_ENEMY:
            return 0
        ship = unit.get("ship", {})
        if isinstance(ship, dict) and "captain_charisma" in ship:
            return int(ship["captain_charisma"])
        return card_charisma(self._fleet_captain_card)

    def captain_courage(self, unit: dict[str, Any]) -> int:
        """§4.7: the captain courage behind ``unit`` — the fleet's canon
        card, or the doc-pinned ``10 + 10 × tier`` legacy fallback."""
        if not isinstance(unit, dict) or unit.get("side") != SIDE_ENEMY:
            return 0
        return self._ship_or_card_courage(unit.get("ship", {}))

    def _ship_or_card_courage(self, ship: Any) -> int:
        """The §4.7 courage behind an ENEMY ship instance: the ship-carried
        ``captain_courage`` key wins, else the fleet's canon card, else the
        legacy fallback (correction 6). Shared with the §4.8a AI morale
        start."""
        if isinstance(ship, dict) and "captain_courage" in ship:
            return int(ship["captain_courage"])
        if self._fleet_captain_card:
            return card_courage(self._fleet_captain_card)
        return (LEGACY_FALLBACK_BASE
                + LEGACY_FALLBACK_PER_TIER * int(FLEET_TIER.get(self.enemy_kind, 1)))

    def surrender_chance(self, unit: dict[str, Any], courage_mod: int = 0,
                         morale: int = -1) -> int:
        """§4.7 surrender chance for the captain behind ``unit``, with the
        profile's ``courage_mod`` folded into the effective courage and —
        when the caller passes the side morale — the §4.8a modifier on top."""
        return (surrender_chance_for_courage(self.captain_courage(unit) + courage_mod)
                + morale_surrender_bonus(morale))

    def roll_surrender(self, unit: dict[str, Any], courage_mod: int = 0,
                       morale: int = -1) -> bool:
        """Draws the §4.7 surrender roll from the battle's single §4.11.1
        stream. A failed roll re-rolls on the ship's next turn."""
        return self.rng.randf() * 100.0 < float(
            self.surrender_chance(unit, courage_mod, morale))

    # --- Side morale (docs/60 §4.8a) -------------------------------------------------

    def side_morale(self, side: str) -> int:
        """The §4.8a side morale for ``side``, 0–100 — the seam the fleet
        layer (§4.9a/§4.9b), the HUD warning and the tests read."""
        value = self._enemy_morale if side == SIDE_ENEMY else self._player_morale
        return _clampi(value, MORALE_MIN, MORALE_MAX)

    def morale_delta_for(self, side: str) -> int:
        """The §4.8a writeback delta (end − start); the outcome block's
        ``morale_delta`` is this value for the player side."""
        start = self._enemy_morale_start if side == SIDE_ENEMY else self._player_morale_start
        return self.side_morale(side) - start

    def _default_enemy_morale(self) -> int:
        """§4.8a AI start default: ``clamp(40 + flagship-captain courage,
        20, 90)``; the legacy no-card fleet falls back to ``10 + 10 × tier``."""
        flagship = (self._enemy_ships[0]
                    if self._enemy_ships and isinstance(self._enemy_ships[0], dict) else {})
        return _clampi(
            ENEMY_MORALE_COURAGE_BASE + self._ship_or_card_courage(flagship),
            ENEMY_MORALE_FLOOR, ENEMY_MORALE_CEILING)

    def _morale_event(self, side: str, delta: int) -> None:
        """Applies one §4.8a event-table delta and clamps to 0..100 after
        it. Unknown sides are ignored (defensive)."""
        if side == SIDE_PLAYER:
            self._player_morale = _clampi(self._player_morale + delta, MORALE_MIN, MORALE_MAX)
        elif side == SIDE_ENEMY:
            self._enemy_morale = _clampi(self._enemy_morale + delta, MORALE_MIN, MORALE_MAX)

    def _is_side_flagship(self, unit: dict[str, Any]) -> bool:
        """True when ``unit`` is the flagship of its side for the §4.8a
        flagship-sunk event, judged at the moment of sinking. The player
        flagship is the game-rule ``fleet[0]`` (§4.6 succession keeps it on
        the next living ship); the enemy flagship is deployed index 0
        (its §4.9b successor takes the battle ANCHOR only, never the
        flagship identity)."""
        index = int(unit.get("index", -1))
        if str(unit.get("side", "")) == SIDE_PLAYER:
            return index == self._flagship_index
        return index == 0

    # --- Hold / menu seams ----------------------------------------------------------

    def hold(self, unit: dict[str, Any]) -> dict[str, Any]:
        """Spends the turn's action doing nothing (§4.3 phase ③ "hold")."""
        result: dict[str, Any] = {"ok": False, "log": {}}
        if self._over or self._action_taken or not self.is_acting(unit):
            return result
        self._action_taken = True
        result["ok"] = True
        result["log"] = self._make_log("hold", unit, {}, {})
        return result

    def retreat(self) -> dict[str, Any]:
        """§4.10 ``battle.retreat``: ends the battle, result ``retreat``."""
        if self._over:
            return self.outcome()
        self._result = RESULT_RETREAT
        self._over = True
        self._log.append({"kind": "retreat", "key": "battle.log.retreat", "values": {}})
        return self.outcome()

    def offer_surrender(self) -> dict[str, Any]:
        """§4.11.7 player-offered surrender. Pirates take the flagship's
        hold (the fleet is retained); a navy with a bounty takes the
        flagship hull itself, and an empty fleet is ``defeat_captured``."""
        if self._over:
            return self.outcome()
        self._result = RESULT_SURRENDER
        flagship = self._flagship_unit()
        if self.enemy_kind == "navy" and flagship:
            self._lost_player.append(_deep_copy(flagship["ship"]))
            flagship["alive"] = False
            self._player_last_cause = "captured"
            self._promote_player_flagship()
            if not self.living_units(SIDE_PLAYER):
                self._result = RESULT_DEFEAT_CAPTURED
        self._over = True
        self._log.append({"kind": "surrender", "key": "battle.log.surrender", "values": {}})
        return self.outcome()

    def log_lines(self) -> list[dict[str, Any]]:
        """The structured log of every resolved action (§4.11.4). Each entry
        is ``{kind, key, values}`` — never player-facing text."""
        return [dict(entry) for entry in self._log]

    # --- Headless driver (§4.11.3 handoff / tests) ------------------------------------

    def run_to_completion(self, policy: Policy,
                          max_rounds: int = MAX_ROUNDS) -> dict[str, Any]:
        """Applies ``policy(sim[, unit])`` then :meth:`end_turn` until
        :meth:`is_over` or the round cap — **40** in Phase 9 (correction
        12). Returns the outcome block when the battle finished, else
        ``{result: "", rounds: <current>, "over": False}``."""
        if not self._started:
            self.start()
        if not callable(policy):
            print("BattleSim.run_to_completion: invalid policy callable",
                  file=sys.stderr)
            return {} if self._over else {
                "result": RESULT_UNFINISHED, "rounds": self._round, "over": False}
        guard = 0
        guard_limit = max(max_rounds, 1) * max(len(self._units), 1) * 2 + 10
        while not self._over and self._round <= max_rounds:
            guard += 1
            if guard > guard_limit:
                print(f"BattleSim.run_to_completion: step guard tripped at "
                      f"round {self._round}", file=sys.stderr)
                break
            unit = self.current_unit()
            if not unit:
                # No living unit at the cursor (the battle ended between
                # calls): end_turn() re-checks and advances.
                self.end_turn()
                continue
            self._apply_decision(unit, self._call_policy(policy, unit))
            if not self._over:
                self.end_turn()
        if self._over:
            return self.outcome()
        return {"result": RESULT_UNFINISHED, "rounds": self._round, "over": False}

    def _call_policy(self, policy: Policy, unit: dict[str, Any]) -> dict[str, Any]:
        """Calls ``policy(sim)`` or ``policy(sim, unit)`` — the arity the
        oracle detects via ``Callable.get_argument_count()``; here the
        signature is introspected, falling back to the one-argument form
        for callables that hide it (functools.partial, builtins)."""
        if _callable_argument_count(policy) >= 2:
            return policy(self, unit)
        return policy(self)

    def _apply_decision(self, unit: dict[str, Any], decision: Any) -> None:
        """§4.12.1.1 decision dict: ``{action, target, cell (derived),
        vel}`` — ``action`` ∈ cannon|ram|board|move|hold|surrender. The
        decision's ``vel`` (when carried) moves the ship FIRST — movement
        happens exactly once — then the action resolves. The cannon
        ``side`` / ``shot`` are NOT in the pinned dict shape: the executor
        derives them (side by the §4.11.8 rule 2 pick, shot by §4.4b for an
        enemy actor, round for a player actor)."""
        # §4.7 side collapse (§4.8a, correction 5): at side morale ≤ 10
        # every living AI ship strikes colours at its next turn with NO
        # roll. PLAYER ships NEVER auto-strike.
        if (str(unit.get("side", "")) == SIDE_ENEMY
                and bool(unit.get("alive", False))
                and self.side_morale(SIDE_ENEMY) <= MORALE_INSTANT_STRIKE):
            self._ai_surrender(unit)
            return
        action = "hold"
        target: dict[str, Any] = {}
        if isinstance(decision, dict):
            action = str(decision.get("action", "hold"))
            maybe_target = decision.get("target", {})
            target = maybe_target if isinstance(maybe_target, dict) else {}
            vel = decision.get("vel")
            if isinstance(vel, tuple):
                self.apply_velocity(unit, (int(vel[0]), int(vel[1])))
            elif isinstance(vel, list) and len(vel) >= 2:
                self.apply_velocity(unit, (int(vel[0]), int(vel[1])))
        if action == "cannon":
            side = str(decision.get("side", "")) if isinstance(decision, dict) else ""
            shot = str(decision.get("shot", "")) if isinstance(decision, dict) else ""
            if not shot:
                shot = (self.ai_shot_type(unit, target)
                        if str(unit.get("side", "")) == SIDE_ENEMY else ROUND_SHOT)
            self.cannon(unit, target, side, shot)
        elif action == "ram":
            self.ram(unit, target if isinstance(target, dict) else {})
        elif action == "board":
            self.board(unit, target if isinstance(target, dict) else {})
        elif action == "move":
            # The velocity above WAS the move; a decision without a usable
            # vel degenerates to a hold.
            if not self._moved_this_turn:
                self.hold(unit)
        elif action == "surrender":
            # `surrender` is the AI's own §4.7 capitulation; a player-side
            # policy asking for it is the §4.11.7 menu action instead.
            if unit.get("side") == SIDE_ENEMY:
                self._ai_surrender(unit)
            else:
                self.offer_surrender()
        else:
            self.hold(unit)

    def _ai_surrender(self, unit: dict[str, Any]) -> None:
        """§4.7 AI surrender: resolved exactly as a duel win (capture), no
        duel. The §4.8a captured −20 event books through :meth:`_capture`."""
        if (self._over or self._action_taken
                or unit.get("side") != SIDE_ENEMY or not self.is_acting(unit)):
            self.hold(unit)
            return
        self._action_taken = True
        self._surrendered_enemy += 1
        unit["ship"]["crew"] = int(unit.get("crew", 0))
        self._capture(unit)
        self._log.append(self._make_log("surrender_enemy", unit, {}, {}))
        self._check_over()

    # --- Snapshot / restore (§4.12.1; the T3 search + tests consume it) ---------------

    def snapshot(self) -> list[int]:
        """The flat mutable-state array — see the module layout comment.
        APPEND-ONLY: new fields only ever join at the end."""
        out: list[int] = []
        out.append(len(self._units))
        for unit in self._units:
            ship = unit.get("ship", {})
            cell = self.unit_cell(unit)
            out.append(int(cell[0]))
            out.append(int(cell[1]))
            vel = to_cell(unit.get("vel", (0, 0)))
            out.append(vel[0])
            out.append(vel[1])
            out.append(int(unit.get("heading8", HEADING_EAST)))
            out.append(int(ship.get("durability", 0)) if isinstance(ship, dict) else 0)
            out.append(int(unit.get("crew", 0)))
            out.append(int(unit.get("reload_port", 1)))
            out.append(int(unit.get("reload_starboard", 1)))
            out.append(int(unit.get("speed_debuff_turns", 0)))
            out.append(1 if bool(unit.get("alive", False)) else 0)
            out.append(int(unit.get("captain_rating", 0)))
            out.append(int(unit.get("cannon_rating", 0)))
        out.append(self._round)
        out.append(self._current)
        out.append(1 if self._action_taken else 0)
        out.append(1 if self._moved_this_turn else 0)
        out.append(1 if self._round_had_damage else 0)
        out.append(1 if self._round_had_boarding else 0)
        out.append(self._stall_rounds)
        out.append(self._last_min_distance)
        out.append(self._flagship_index)
        out.append(1 if self._over else 0)
        result_idx = (RESULT_VALUES.index(self._result)
                      if self._result in RESULT_VALUES else -1)
        out.append(result_idx)
        out.append(self._cause_index())
        # Retired §4.8 slot: `morale_bonus` left the outcome block in W4-A;
        # the position is kept as a 0 placeholder so the layout stays
        # append-only for W3-era consumers.
        out.append(0)
        out.append(self._surrendered_enemy)
        out.append(len(self._log))
        out.append(len(self._sunk_enemy))
        out.append(len(self._sunk_enemy_by_player))
        out.append(len(self._captured_enemy))
        out.append(len(self._sunk_player))
        out.append(len(self._lost_player))
        out.append(self.rng.state)
        # §4.8a side morales.
        out.append(self._player_morale)
        out.append(self._enemy_morale)
        return out

    def restore(self, arr: Iterable[int]) -> None:
        """The exact inverse of :meth:`snapshot`. A size mismatch is
        rejected and leaves the state untouched."""
        values = list(arr)
        if not values:
            print("BattleSim.restore: empty snapshot", file=sys.stderr)
            return
        n = int(values[0])
        expected = 1 + n * _SNAPSHOT_UNIT_FIELDS + _SNAPSHOT_SCALARS
        if len(values) != expected:
            print(f"BattleSim.restore: size mismatch ({n} units ⇒ expected "
                  f"{expected} ints, got {len(values)})", file=sys.stderr)
            return
        if n != len(self._units):
            print("BattleSim.restore: unit count changed since the snapshot",
                  file=sys.stderr)
            return
        i = 1
        for unit in self._units:
            ship = unit.get("ship", {})
            unit["pos"] = (int(values[i]), int(values[i + 1]))
            unit["vel"] = (int(values[i + 2]), int(values[i + 3]))
            unit["heading8"] = int(values[i + 4])
            if isinstance(ship, dict):
                ship["durability"] = int(values[i + 5])
            unit["crew"] = int(values[i + 6])
            unit["reload_port"] = int(values[i + 7])
            unit["reload_starboard"] = int(values[i + 8])
            unit["speed_debuff_turns"] = int(values[i + 9])
            unit["alive"] = int(values[i + 10]) == 1
            unit["captain_rating"] = int(values[i + 11])
            unit["cannon_rating"] = int(values[i + 12])
            i += _SNAPSHOT_UNIT_FIELDS
        self._round = int(values[i])
        self._current = int(values[i + 1])
        self._action_taken = int(values[i + 2]) == 1
        self._moved_this_turn = int(values[i + 3]) == 1
        self._round_had_damage = int(values[i + 4]) == 1
        self._round_had_boarding = int(values[i + 5]) == 1
        self._stall_rounds = int(values[i + 6])
        self._last_min_distance = int(values[i + 7])
        self._flagship_index = int(values[i + 8])
        self._over = int(values[i + 9]) == 1
        result_idx = int(values[i + 10])
        self._result = (RESULT_VALUES[result_idx]
                        if 0 <= result_idx < len(RESULT_VALUES) else RESULT_UNFINISHED)
        self._player_last_cause = _CAUSE_NAMES[_clampi(int(values[i + 11]), 0, 2)]
        # i + 12: the retired `morale_bonus` placeholder — written 0, not read.
        self._surrendered_enemy = int(values[i + 13])
        del self._log[int(values[i + 14]):]
        del self._sunk_enemy[int(values[i + 15]):]
        del self._sunk_enemy_by_player[int(values[i + 16]):]
        del self._captured_enemy[int(values[i + 17]):]
        del self._sunk_player[int(values[i + 18]):]
        del self._lost_player[int(values[i + 19]):]
        self.rng.state = int(values[i + 20])
        self._player_morale = int(values[i + 21])
        self._enemy_morale = int(values[i + 22])

    def _cause_index(self) -> int:
        if self._player_last_cause == "sunk":
            return 1
        if self._player_last_cause == "captured":
            return 2
        return 0

    # --- Equipment helpers (docs/60 §4.11.12) -------------------------------------------

    def effective_max_durability(self, ship: dict[str, Any]) -> int:
        """§4.11.12: base durability + figurehead durability delta. The base
        for ram damage (§4.11.5) and the current-durability cap."""
        ship_type = data().get_ship_type(str(ship.get("ship_type_id", "")))
        return (int(ship_type.get("durability", 0))
                + equipment_modifier(ship, "figurehead", "durability"))

    # --- Turn / initiative internals (§4.11.4) --------------------------------------------

    def _make_unit(self, side: str, index: int, ship: dict[str, Any],
                   cell: Cell, tournament: bool) -> dict[str, Any]:
        # §4.11.2 correction 15: EVERY battle opens with the closing start —
        # the flagship already sails toward the enemy (vel (±1, 0)), extras
        # deploy at rest through the band scan. The `tournament` key maps to
        # the same start (schema forward-compat).
        initial_vel: Cell = (0, 0)
        heading = HEADING_EAST if side == SIDE_PLAYER else HEADING_WEST
        if index == 0:
            initial_vel = (TOURNAMENT_PLAYER_VEL if side == SIDE_PLAYER
                           else TOURNAMENT_ENEMY_VEL)
        unit: dict[str, Any] = {
            "side": side,
            "index": index,
            "ship": ship,
            "pos": cell,
            "vel": initial_vel,
            "heading8": heading,
            "reload_port": 1,
            "reload_starboard": 1,
            "speed_debuff_turns": 0,
            "crew": max(int(ship.get("crew", 0)), 0),
            "alive": True,
            "captain_rating": 0,
            "cannon_rating": 0,
            "gunnery": 0,
            "cannons_port": 0,
            "cannons_starboard": 0,
        }
        if initial_vel != (0, 0):
            # §4.11.2: the pinned velocity sets the heading.
            unit["heading8"] = heading8_of(initial_vel)
        return unit

    def _deploy_cell(self, side: str, index: int) -> Cell:
        table = PLAYER_DEPLOYMENT if side == SIDE_PLAYER else ENEMY_DEPLOYMENT
        if self.deployment == TOURNAMENT_DEPLOYMENT and index == 0:
            return (TOURNAMENT_PLAYER_CELL if side == SIDE_PLAYER
                    else TOURNAMENT_ENEMY_CELL)
        if index < len(table):
            return table[index]
        # §4.2 band overflow (more than 5 ships): continue the in-band scan.
        band: list[Cell] = []
        if side == SIDE_PLAYER:
            for x in range(PLAYER_BAND_MAX_X + 1):
                for y in range(GRID_HEIGHT):
                    band.append((x, y))
        else:
            for x in range(ENEMY_BAND_MIN_X, GRID_WIDTH):
                for y in range(GRID_HEIGHT):
                    band.append((x, y))
        for scan_cell in band:
            if all(self.unit_cell(u) != scan_cell for u in self._units):
                return scan_cell
        return NO_CELL

    def _price_broadside_split(self) -> None:
        """§4.4 broadside split (decision 3): ``port = floor(n / 2)``,
        starboard the rest — derived from the ship's TOTAL cannons at
        battle start. A ship-carried pair that sums to the total wins (the
        compose seam)."""
        for unit in self._units:
            ship = unit["ship"]
            total = max(int(ship.get("cannons", 0)), 0)
            port = int(math.floor(float(total) / BROADSIDE_SPLIT_DIVISOR))
            starboard = total - port
            if ("cannons_port" in ship and "cannons_starboard" in ship
                    and int(ship["cannons_port"]) + int(ship["cannons_starboard"]) == total):
                port = int(ship["cannons_port"])
                starboard = int(ship["cannons_starboard"])
            unit["cannons_port"] = port
            unit["cannons_starboard"] = starboard

    def _price_gunnery(self) -> None:
        """§4.4a gunnery source, priced once at battle start: the player
        flagship's effective gunnery, a captain-card ship's card gunnery,
        the legacy ``10 + 10 × tier`` fallback for a card-less enemy fleet,
        0 for a captain-less player escort."""
        for unit in self._units:
            unit["gunnery"] = self._gunnery_source(unit)

    def _gunnery_source(self, unit: dict[str, Any]) -> int:
        if unit.get("side") == SIDE_PLAYER:
            if int(unit["index"]) == self._flagship_index:
                return self.player_effective_skill("gunnery")
            officer = self._escort_captain_officer(unit)
            if officer:
                skills = officer.get("skills", {})
                return int(skills.get("gunnery", 0)) if isinstance(skills, dict) else 0
            return 0
        ship = unit["ship"]
        if "gunnery" in ship:
            return int(ship["gunnery"])
        if self._fleet_captain_card:
            card_skills = self._fleet_captain_card.get("skills", {})
            return int(card_skills.get("gunnery", 0)) if isinstance(card_skills, dict) else 0
        return (LEGACY_FALLBACK_BASE
                + LEGACY_FALLBACK_PER_TIER * int(FLEET_TIER.get(self.enemy_kind, 1)))

    def _price_captain_ratings(self) -> None:
        """§4.11.5 / §4.11.11.2: each ship's captain-card ratings are priced
        ONCE at battle start and stored on the unit — never re-rolled
        mid-battle. Ship-carried ``duel_rating``/``cannon_rating`` win; AI
        ships price from the fleet's canon card; player escorts from their
        appointed captain officer's card; a fleet with no card keeps the
        retired ``5 + tier`` stand-in on both ratings."""
        legacy_rating = CAPTAIN_RATING_BASE + int(FLEET_TIER.get(self.enemy_kind, 1))
        for unit in self._units:
            if unit.get("side") == SIDE_ENEMY:
                ship = unit["ship"]
                if "duel_rating" in ship and "cannon_rating" in ship:
                    unit["captain_rating"] = int(ship["duel_rating"])
                    unit["cannon_rating"] = int(ship["cannon_rating"])
                elif self._fleet_captain_card:
                    unit["captain_rating"] = card_duel_rating(self._fleet_captain_card)
                    unit["cannon_rating"] = card_cannon_rating(self._fleet_captain_card)
                else:
                    unit["captain_rating"] = legacy_rating
                    unit["cannon_rating"] = legacy_rating
            elif int(unit["index"]) != self._flagship_index:
                # Player escort (§4.11.5): the appointed captain officer's
                # card, else the captain-less rule (0/0).
                escort_ship = unit["ship"]
                if "duel_rating" in escort_ship and "cannon_rating" in escort_ship:
                    unit["captain_rating"] = int(escort_ship["duel_rating"])
                    unit["cannon_rating"] = int(escort_ship["cannon_rating"])
                    continue
                officer = self._escort_captain_officer(unit)
                if not officer:
                    unit["captain_rating"] = 0
                    unit["cannon_rating"] = 0
                else:
                    unit["captain_rating"] = card_duel_rating(officer)
                    unit["cannon_rating"] = card_cannon_rating(officer)

    def _escort_captain_officer(self, unit: dict[str, Any]) -> dict[str, Any]:
        """The appointed captain officer of a player escort ship, as an
        officers.json v2 record, or ``{}`` when the ship is captain-less.
        The ship-carried ``captain_officer_id`` key wins; else the
        defensive ``officer_states`` scan (injected via the config)."""
        ship = unit.get("ship", {})
        if not isinstance(ship, dict):
            return {}
        officer_id = str(ship.get("captain_officer_id", ""))
        if not officer_id:
            officer_id = self._officer_state_captain_for(str(ship.get("id", "")))
        if not officer_id:
            return {}
        return data().get_officer(officer_id)

    def _officer_state_captain_for(self, ship_id: str) -> str:
        """The officer id posted as this ship's captain in the defensive
        ``officer_states`` scan; "" when absent."""
        if not ship_id:
            return ""
        for officer_id, state in self._officer_states.items():
            if (isinstance(state, dict)
                    and str(state.get("post_id", "")) == "captain"
                    and str(state.get("ship_id", "")) == ship_id):
                return str(officer_id)
        return ""

    def _build_order(self) -> None:
        """§4.11.4: the initiative order is built ONCE at battle start —
        descending ``speed + sail delta``, ties player-before-enemy, then
        ascending fleet index. Never re-sorted mid-battle (§4.3)."""
        self._order = [u for u in self._units if bool(u.get("alive", False))]
        # Python's sort is stable; the key encodes the full tie-break.
        self._order.sort(key=lambda u: (
            -self.initiative_key(u),
            0 if u.get("side") == SIDE_PLAYER else 1,
            int(u["index"]),
        ))

    def _advance(self) -> None:
        """Advances to the next living unit; at the wrap the completed round
        is evaluated for stall (§4.11.9) and the round counter steps."""
        guard = 0
        limit = len(self._order) + 2
        while guard <= limit:
            guard += 1
            self._current += 1
            if self._current >= len(self._order):
                self._evaluate_stall()
                if self._over:
                    return
                self._round += 1
                self._current = -1
                self._round_had_damage = False
                self._round_had_boarding = False
                continue
            if self._current < len(self._order):
                unit = self._order[self._current]
                if isinstance(unit, dict) and bool(unit.get("alive", False)):
                    self._action_taken = False
                    self._moved_this_turn = False
                    return

    def _evaluate_stall(self) -> None:
        """§4.11.9 stall detection (decision 12): 8 consecutive rounds with
        zero damage AND zero boarding AND a net player↔enemy Chebyshev
        change ≤ 2 ⇒ outcome ``stall``. "Net" is the CUMULATIVE change
        across the zero-activity streak: the anchor is the minimum-pair
        Chebyshev at the streak's start; a net drift past ±2 breaks the
        streak the same way damage does. Any damage or boarding resets the
        counter (and re-anchors)."""
        distance = self._min_pair_distance()
        if distance < 0:
            return
        if self._round_had_damage or self._round_had_boarding:
            self._stall_rounds = 0
            self._last_min_distance = distance
            return
        self._stall_rounds += 1
        if self._stall_rounds == 1:
            # Fresh streak: this round's distance anchors the window.
            self._last_min_distance = distance
        elif (self._last_min_distance >= 0
              and abs(self._last_min_distance - distance) > STALL_DISTANCE_DELTA):
            # The window's net change breached the ≤ 2 pin — the streak
            # fails and restarts from here (the anchor moves with it).
            self._stall_rounds = 0
            self._last_min_distance = distance
        if self._stall_rounds >= STALL_ROUNDS:
            self._result = RESULT_STALL
            self._over = True

    def _min_pair_distance(self) -> int:
        """The minimum Chebyshev across living player↔enemy pairs (−1 when
        either side has no living ship)."""
        players = self.living_units(SIDE_PLAYER)
        enemies = self.living_units(SIDE_ENEMY)
        if not players or not enemies:
            return -1
        best = 1 << 30
        for player in players:
            for enemy in enemies:
                best = min(best, _chebyshev(self.unit_cell(player), self.unit_cell(enemy)))
        return best

    # --- Damage / removal internals (§4.11.5, §4.11.7) --------------------------------------

    def _sink(self, unit: dict[str, Any], by_side: str, _cause: str) -> None:
        """Removes a sunk ship immediately; cargo is lost (§4.7). The §4.8a
        events book here: friendly ship sunk −15, or −30 TOTAL when the
        hull was the side's flagship (the −30 REPLACES the −15, correction
        5)."""
        if not bool(unit.get("alive", False)):
            return
        flagship_sunk = self._is_side_flagship(unit)
        side = str(unit.get("side", ""))
        unit["alive"] = False
        unit["ship"]["durability"] = 0
        ship_type_id = str(unit["ship"].get("ship_type_id", ""))
        if side == SIDE_ENEMY:
            self._sunk_enemy.append(ship_type_id)
            if by_side == SIDE_PLAYER:
                self._sunk_enemy_by_player.append(ship_type_id)
        else:
            self._sunk_player.append(ship_type_id)
            self._player_last_cause = "sunk"
            self._promote_player_flagship()
        self._morale_event(
            side,
            MORALE_EVENT_FLAGSHIP_SUNK if flagship_sunk else MORALE_EVENT_FRIENDLY_SUNK)

    def _capture(self, unit: dict[str, Any]) -> None:
        """Removes a captured ship (duel win/loss, AI surrender). The
        instance is reported intact — battle-worn crew and durability; the
        §4.11.7 25%-durability/crew-0 transform is the application seam's
        (:mod:`server.sim.combat.battle_result`). The §4.8a captured event
        books here: ship captured −20, the captured hull's own side."""
        if not bool(unit.get("alive", False)):
            return
        unit["alive"] = False
        unit["ship"]["crew"] = int(unit.get("crew", 0))
        if unit.get("side") == SIDE_ENEMY:
            self._captured_enemy.append(_deep_copy(unit["ship"]))
        else:
            self._lost_player.append(_deep_copy(unit["ship"]))
            self._player_last_cause = "captured"
            self._promote_player_flagship()
        self._morale_event(str(unit.get("side", "")), MORALE_EVENT_CAPTURED)

    def _promote_player_flagship(self) -> None:
        """§4.6: the next ship becomes the flagship, order preserved."""
        self._flagship_index = self._lowest_living_index(SIDE_PLAYER)

    def _lowest_living_index(self, side: str) -> int:
        best = -1
        for unit in self._units:
            if unit.get("side") != side or not bool(unit.get("alive", False)):
                continue
            if best < 0 or int(unit["index"]) < best:
                best = int(unit["index"])
        return best

    def _flagship_unit(self) -> dict[str, Any]:
        for unit in self._units:
            if (unit.get("side") == SIDE_PLAYER and bool(unit.get("alive", False))
                    and int(unit["index"]) == self._flagship_index):
                return unit
        return {}

    def _check_over(self) -> None:
        if self._over:
            return
        if not self.living_units(SIDE_PLAYER):
            self._result = (RESULT_DEFEAT_CAPTURED if self._player_last_cause == "captured"
                            else RESULT_DEFEAT_SUNK)
            self._over = True
            return
        if not self.living_units(SIDE_ENEMY):
            self._result = RESULT_VICTORY
            self._over = True

    # --- Outcome internals (§4.11.10) --------------------------------------------------------

    def _salvage_gold(self) -> int:
        """``Σ floor(base_price × 0.05)`` over the ships the PLAYER sank
        (captured/surrendered hulls pay no salvage)."""
        total = 0
        for ship_type_id in self._sunk_enemy_by_player:
            ship_type = data().get_ship_type(str(ship_type_id))
            total += int(math.floor(float(ship_type.get("base_price", 0)) * SALVAGE_FRACTION))
        return total

    def _rep_deltas(self) -> dict[str, int]:
        """§4.11.10/§4.12.2: ``rep_deltas`` carries ONLY the pirate ``+2``
        entries (any outcome except retreat). The navy ``−20`` is charged
        exactly once per navy battle at battle start by whoever initiated
        it, never per ship and never here."""
        deltas: dict[str, int] = {}
        if self.enemy_kind == "pirate" and self._result != RESULT_RETREAT:
            for nation_id in self._nearest_port_nations():
                deltas[nation_id] = deltas.get(nation_id, 0) + PIRATE_REP_GAIN
        return deltas

    def _nearest_port_nations(self) -> list[str]:
        """Nations of the two nearest ports (Chebyshev from the contact
        tile; ties by port id ascending; a nation credited once). §4.11.10
        picks TWO PORTS first and credits their nations, then drops a
        duplicate."""
        ports: list[dict[str, Any]] = []
        from server.sim.world.raster import raster
        world = raster()
        store = data()
        for port in store.ports_list:
            if not isinstance(port, dict):
                continue
            position = world.port_cell(str(port.get("id", "")))
            if position[0] < 0:
                continue
            ports.append({
                "id": str(port.get("id", "")),
                "nation_id": str(port.get("nation_id", "")),
                "distance": world_chebyshev(self.contact, position),
            })
        ports.sort(key=lambda p: (int(p["distance"]), str(p["id"])))
        nations: list[str] = []
        for entry in ports[:NEAREST_PORT_COUNT]:
            nation_id = str(entry["nation_id"])
            if not nation_id or nation_id in nations:
                continue
            nations.append(nation_id)
        return nations

    def _make_log(self, kind: str, unit: dict[str, Any], target: dict[str, Any],
                  values: dict[str, Any]) -> dict[str, Any]:
        payload = dict(values)
        payload["side"] = str(unit.get("side", ""))
        payload["unit"] = int(unit.get("index", -1))
        if isinstance(target, dict) and target:
            payload["target_side"] = str(target.get("side", ""))
            payload["target"] = int(target.get("index", -1))
        entry = {"kind": kind, "key": "battle.log." + kind, "values": payload}
        self._log.append(entry)
        return entry

    @staticmethod
    def _copy_ships(ships: Any) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        if not isinstance(ships, list):
            return out
        for ship in ships:
            if isinstance(ship, dict):
                out.append(_deep_copy(ship))
        return out


def _deep_copy(value: Any) -> Any:
    """A JSON-shaped deep copy (the ``duplicate(true)`` of the oracle)."""
    if isinstance(value, dict):
        return {k: _deep_copy(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_deep_copy(v) for v in value]
    return value


def _callable_argument_count(policy: Callable[..., Any]) -> int:
    """The declared parameter count of ``policy`` (the
    ``Callable.get_argument_count()`` of the oracle). ``*args`` signatures
    report 1 — the one-argument form — which is the documented default."""
    try:
        parameters = list(inspect.signature(policy).parameters.values())
    except (TypeError, ValueError):
        return 1
    positional = [p for p in parameters if p.kind in (
        inspect.Parameter.POSITIONAL_ONLY, inspect.Parameter.POSITIONAL_OR_KEYWORD)]
    if any(p.kind == inspect.Parameter.VAR_POSITIONAL for p in parameters):
        return 1
    return len(positional)
