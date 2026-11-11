"""server.sim.world.discovery — discovery sighting, reporting and Explore (M1).

Python port of the **explore/report half** of ``scripts/world/discovery.gd``
(the frozen parity oracle until the M6 cutover; the class was
``DiscoverySight``). Normative contract:

  * docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.4 — discoveries: the Explore
    action, the ``36 + floor(cartography / 15)`` radius, found ≠ reported,
    the guild report payout (``report_reward_gold`` + ``fame`` once, ever),
    and the tavern hints (100g, up to three per visit);
  * docs/20-WORLD-AND-SAILING.md §4.11 — the wrap-aware Chebyshev distance
    over the 4320×2160 grid (§4.1 x wraps mod width);
  * docs/80-UI-UX.md §4.3/§4.7.3 — the ``discovery.something_near`` hint and
    the ``E`` action availability, the Rumors tab;
  * docs/90-ARCHITECTURE.md §8.1 — the saved ``discoveries_found`` /
    ``discoveries_reported`` arrays and the ``discovery_hints`` map.

**Overlap resolution (the hint half is NOT duplicated).** ``discovery.gd``'s
``hints`` / ``is_hinted`` / ``buy_hint`` / ``hint_text`` / ``_port_ordinal``
— the tavern Rumors tab's machinery — already landed in
``server/sim/port/tavern.py`` (that module's ownership per the migration
ledger). This module re-exports them (and the hint constants) so callers can
keep the ``DiscoverySight``-shaped import surface; there is exactly one
implementation, the tavern engine's. RNG stays there too: the hint draw
(``seed = day × 1000003 + port_ordinal × 7919`` → ``randi_range``) is the
oracle file's ONLY ``rand*`` call, and this module rolls nothing (Explore,
in-range selection and report are deterministic — the oracle's
``in_range`` sorts by id).

State convention (the M1 port rule for autoload-coupled statics): the
GDScript statics read/mutated three ``GameState`` fields. Here the run state
arrives injected, matching ``tavern.hints(store, found, …)``:

  * ``found`` — the ``discoveries_found`` array (the quest layer's
    :attr:`~server.sim.quests.QuestState.discoveries_found` is the natural
    binding; ``explore`` appends to it in place so both layers stay one
    source of truth);
  * ``reported`` — the ``discoveries_reported`` array (save v3, §8.1);
  * ``hints_map`` — the ``discovery_hints`` ``{id: true}`` map (only the
    re-exported tavern helpers touch it).

Events return values: the GDScript emitted ``EventBus.discovery_found`` /
``discovery_reported``; in the web era those are the caller's WS ``event``
frames (``90-*`` §0.3), so :func:`explore` returns the found ids and
:func:`report` returns the applied payout block.
"""

from __future__ import annotations

import math
from collections.abc import Collection, MutableSequence
from typing import Any, Final

from server.sim.data import DataStore
from server.sim.player import PersonState, fame, skills
from server.sim.port.tavern import (
    HINTS_PER_VISIT,
    HINT_PRICE,
    SEED_DAY_MULT,
    SEED_PORT_MULT,
    buy_hint,
    hint_text,
    hints,
    is_hinted,
    port_ordinal,
)

__all__ = [
    "RADIUS_BASE",
    "CARTOGRAPHY_DIVISOR",
    "MAP_WIDTH_FALLBACK",
    "MAP_HEIGHT_FALLBACK",
    "HINT_PRICE",
    "HINTS_PER_VISIT",
    "SEED_DAY_MULT",
    "SEED_PORT_MULT",
    "radius",
    "in_range",
    "something_near",
    "explore",
    "unreported",
    "report",
    "hints",
    "is_hinted",
    "buy_hint",
    "hint_text",
    "port_ordinal",
    "position_of_entry",
    "position_of",
    "tile_of_latlon",
    "chebyshev_to_cell",
    "map_width",
    "map_height",
]

# --- Constants (docs/70-* §4.4; discovery.gd) --------------------------------

#: §4.4 pin: this is **not** the port sighting radius (48 + navigation,
#: ``20-*`` §4.11 / ``SailingSim.SIGHTING_RADIUS``); the two formulas must not
#: be conflated. Chebyshev over tiles on the world grid, wrap-aware on x
#: (``20-*`` §4.1). Phase-6 grid sweep: 18 → 36 tiles (≈ 3°, nm preserved at
#: 5 nm tiles). **Phase 8:** the radius is owned by the cartography skill
#: (``50-*`` §4.3): ``36 + floor(cartography / 15)`` with the effective
#: (officer-contributed) skill, so the base term below is the cartography-0
#: floor.
RADIUS_BASE: Final[int] = 36
CARTOGRAPHY_DIVISOR: Final[int] = 15
#: §4.1: the world grid width in tiles (4320 at 12 tiles/degree, Phase 6).
#: Read from the loaded legend when there is one, so a test map does not have
#: to be 4320 wide.
MAP_WIDTH_FALLBACK: Final[int] = 4320
#: §6.1: the grid height (2160 at 12 tiles/degree from 90°N to 90°S).
MAP_HEIGHT_FALLBACK: Final[int] = 2160


# --- Explore (docs/70-* §4.4) ------------------------------------------------

def radius(st: PersonState, store: DataStore) -> int:
    """The Phase-8 discovery radius: ``36 + floor(effective cartography / 15)``
    (``50-*`` §4.3; ``skills.effective_skill`` includes the in-post officer
    contribution)."""
    return RADIUS_BASE + int(math.floor(
        skills.effective_skill(st, store, "cartography")
        / float(CARTOGRAPHY_DIVISOR)))


def in_range(st: PersonState, store: DataStore,
             found: Collection[str],
             cell: tuple[int, int]) -> list[str]:
    """Every discovery within Chebyshev radius of ``cell`` that has not been
    found yet, sorted by id (stable dialog order)."""
    found_set = set(found)
    limit = radius(st, store)
    out: list[str] = []
    for entry in store.discoveries_list:
        discovery_id = str(entry.get("id", ""))
        if discovery_id in found_set:
            continue
        if _distance(store, entry, cell) <= limit:
            out.append(discovery_id)
    out.sort()
    return out


def something_near(st: PersonState, store: DataStore,
                   found: Collection[str],
                   cell: tuple[int, int]) -> bool:
    """``True`` while a discovery sits in range — what the HUD's
    ``discovery.something_near`` hint and the ``E`` action availability
    read."""
    return bool(in_range(st, store, found, cell))


def explore(st: PersonState, store: DataStore,
            found: MutableSequence[str],
            cell: tuple[int, int]) -> list[str]:
    """The Explore action: marks every in-range discovery found and returns
    the ids found (empty when nothing was in range — the caller shows
    ``world.explore.none``). No day cost, no cooldown (§4.4).

    ``found`` is the ``discoveries_found`` array — mutated in place (one id
    appended per find, the first discovery only counts); the caller emits one
    ``discovery_found`` event per returned id.
    """
    results = in_range(st, store, found, cell)
    for discovery_id in results:
        found.append(discovery_id)
    return results


# --- Report (docs/70-* §4.4) -------------------------------------------------

def unreported(store: DataStore, found: Collection[str],
               reported: Collection[str]) -> list[str]:
    """The found-but-unreported ids, sorted (the guild's report list)."""
    found_set = set(found)
    reported_set = set(reported)
    out: list[str] = []
    for entry in store.discoveries_list:
        discovery_id = str(entry.get("id", ""))
        if discovery_id in found_set and discovery_id not in reported_set:
            out.append(discovery_id)
    out.sort()
    return out


def report(store: DataStore, st: PersonState, found: Collection[str],
           reported: MutableSequence[str],
           discovery_id: str) -> dict[str, Any]:
    """Reports ``discovery_id`` at a guild: pays ``report_reward_gold`` and
    adds ``fame`` **once, ever**; returns the report block (``{}`` when not
    reportable — unknown id, not found, or already reported).

    ``reported`` is the ``discoveries_reported`` save array — appended in
    place on a successful payout (found ≠ reported; a reload cannot re-pay).
    Completed exploration/royal missions are the caller's concern
    (``QuestGen``/``PalaceEngine``) so this stays pure report bookkeeping.
    """
    if discovery_id not in set(found):
        return {}
    if discovery_id in set(reported):
        return {}
    entry = store.get_discovery(discovery_id)
    if not entry:
        return {}
    gold = int(entry.get("report_reward_gold", 0))
    fame_amount = int(entry.get("fame", 0))
    if gold > 0:
        st.gold += gold
    fame.add(st, fame_amount)
    reported.append(discovery_id)
    return {"id": discovery_id, "gold": gold, "fame": fame_amount}


# --- Position arithmetic (docs/70-* §4.4; discovery.gd helpers) --------------

def _distance(store: DataStore, entry: dict[str, Any],
              cell: tuple[int, int]) -> int:
    return chebyshev_to_cell(store, position_of_entry(store, entry), cell)


def chebyshev_to_cell(store: DataStore, other: tuple[int, int],
                      cell: tuple[int, int]) -> int:
    """Chebyshev distance between two tiles, **wrap-aware on x** (``20-*``
    §4.1: ``x`` is taken mod the grid width everywhere).

    The grid width comes from the loaded legend when available
    (``store.map_legend.grid.width``), else the locked 4320. A short ``dx`` is
    preferred: ``min(|dx|, width − |dx|)``.
    """
    dx = abs(int(other[0]) - int(cell[0]))
    width = map_width(store)
    if width > 0:
        # Normalise first so an out-of-range coordinate cannot produce a
        # negative short way; then take the short way around the seam.
        dx = dx % width
        dx = min(dx, width - dx)
    return max(dx, abs(int(other[1]) - int(cell[1])))


def map_width(store: DataStore) -> int:
    """World grid width in tiles for the wrap arithmetic: the active legend's
    ``grid.width`` (4320 for the world map), falling back to
    :data:`MAP_WIDTH_FALLBACK` when no legend is loaded yet."""
    grid = store.map_legend.get("grid", {})
    width = int(grid.get("width", 0))
    return width if width > 0 else MAP_WIDTH_FALLBACK


def map_height(store: DataStore) -> int:
    """World grid height in tiles (from the legend, else the locked 2160)."""
    grid = store.map_legend.get("grid", {})
    height = int(grid.get("height", 0))
    return height if height > 0 else MAP_HEIGHT_FALLBACK


def position_of_entry(store: DataStore,
                      entry: dict[str, Any]) -> tuple[int, int]:
    """A discovery's map cell, derived from its ``lat``/``lon`` with the
    **same floor projection as the grid** (``10-*`` §6.1:
    ``x = floor((lon + 180) × 12) mod width``, ``y = floor((90 − lat) × 12)``),
    because discovery entries carry no stored tile. ``(0, 0)`` when the entry
    has no coordinates."""
    return tile_of_latlon(store, float(entry.get("lat", 0.0)),
                          float(entry.get("lon", 0.0)))


def tile_of_latlon(store: DataStore, lat: float,
                   lon: float) -> tuple[int, int]:
    """``10-*`` §6.1 addressing for a WGS84 point. ``y`` is clamped into the
    grid (only an exact pole reaches an edge); ``x`` wraps."""
    width = map_width(store)
    scale = float(width) / 360.0
    x = int(math.floor((lon + 180.0) * scale)) % max(width, 1)
    y = int(math.floor((90.0 - lat) * scale))
    height = map_height(store)
    if height > 0:
        y = max(0, min(y, height - 1))
    return (x, y)


def position_of(store: DataStore, discovery_id: str) -> tuple[int, int]:
    """The discovery's map cell (``(0, 0)`` for an unknown id)."""
    return position_of_entry(store, store.get_discovery(discovery_id))
