"""``server.sim.world.npc_intel`` — captain sightings, wanted posters, the
paid reveal and tavern rumor rows (M1).

Python port of the frozen Godot-era ``scripts/world/npc_intel.gd`` (the
parity oracle until the M6 cutover). Contract sources:

- ``docs/80-UI-UX.md`` §4.7.8 — THE pin: the facility surfaces (market S5 /
  tavern S7 / inn S8 / palace S13), the seeded 60/40 facility roll, the 75%
  presence roll, wanted posters within Chebyshev 40 with the paid reveal at
  20g, and the tavern rumor row sources.
- ``docs/60-COMBAT.md`` §4.11.11.4 — the sighting surfaces + the
  ``npc_port_log`` rumor source ("departures/arrivals within 3 days").
- ``docs/70-QUESTS-DISCOVERY-ENDGAME.md`` §4.9.3 — the bounty reward bands
  ``{1: 5000, 2: 10000, 3: 20000}`` (the poster reward hint).
- ``docs/30-PORTS-AND-TRADE.md`` §4.5 — demand-event telegraphs.
- ``docs/60-COMBAT.md`` §4.11.11.1 — the hunter-intel object
  (``world.last_departed_port`` / ``world.hunter_intel_cell``).

Purity: every function is a pure query over the injected
:class:`~server.sim.world.npc_fleets.FleetEcologyState` (plus the economy /
allegiance run states for the rumor sources). The module never emits, never
mutates the fleet list; the ONE intentional write is the sightings
familiarity accrual (``Captains.add_familiarity`` — the oracle does it in
the same query) and it lives in ``captain_states``. The paid reveal's gold
charge is the screen's action — :func:`reveal_position` returns data only.

Seeded rolls (IMPLEMENT-Phase5 decision 9): the facility and presence rolls
are seeded from ``(fleet_id, port_id, arrival_day)`` — stable within one
visit-day (no flicker on re-open), re-rolled on the next visit. A hunter is
palace-only and never rolls an alternate facility.

Name formatting: rows carry the captain card's raw L10nString ``name``
dict (the web stack formats by locale, ``90-*`` §0.3) unless the caller
passes an ``i18n`` view with a ``t(value) -> str`` method — the GDScript
``I18n.t`` seam.
"""

from __future__ import annotations

from typing import Any, Callable

from server.sim.data import DataStore, data
from server.sim.port import allegiance as allegiance_lib
from server.sim.port import economy as economy_lib
from server.sim.port.economy import EconomyState, godot_string_hash
from server.sim.player import PersonState
from server.sim.quests.quest_gen import BOUNTY_GOLD_BY_TIER
from server.sim.world import npc_fleets as ec
from server.sim.world.npc_fleets import (
    DWELL_DAYS,
    FleetEcologyState,
    NpcFleets,
    _CaptainsBridge,
    captain_name,
    captain_tier_of,
    chebyshev,
    position_of,
)

__all__ = [
    "FACILITY_MARKET",
    "FACILITY_TAVERN",
    "FACILITY_INN",
    "FACILITY_PALACE",
    "FACILITY_ALTERNATES",
    "FACILITY_PRIMARY_CHANCE",
    "PRESENT_CHANCE",
    "POSTER_RADIUS",
    "REVEAL_COST",
    "RUMOR_RADIUS",
    "arrival_day_of",
    "primary_facility",
    "facility_of",
    "is_present",
    "docked_fleets",
    "sightings",
    "gone_ashore",
    "wanted_posters",
    "reveal_position",
    "rumor_rows",
    "investment_rows",
    "nearest_port",
    "hunter_intel_cell",
    "hunter_intel_port",
    "hunter_intel_known",
]

#: Facility ids of the §4.7.8 surfaces.
FACILITY_MARKET = "market"
FACILITY_TAVERN = "tavern"
FACILITY_INN = "inn"
FACILITY_PALACE = "palace"
#: The uniform alternate set of the 60/40 facility roll.
FACILITY_ALTERNATES: tuple[str, ...] = (
    FACILITY_MARKET, FACILITY_TAVERN, FACILITY_INN)

FACILITY_PRIMARY_CHANCE = 0.6
PRESENT_CHANCE = 0.75
POSTER_RADIUS = 40
REVEAL_COST = 20
RUMOR_RADIUS = 40


def _store_of(store: DataStore | None) -> DataStore:
    return store if store is not None else data()


def _state_of(source: Any) -> FleetEcologyState:
    if isinstance(source, NpcFleets):
        return source.state
    return source


def _within(source: Any, cell: tuple[int, int], radius: int) -> list[dict]:
    if isinstance(source, NpcFleets):
        return source.within(cell, radius)
    return ec.fleets_within(source, cell, radius, _store_of(None))


def _t(value: Any, i18n: Any) -> Any:
    """Localize an L10nString through the injected view (raw dict otherwise)."""
    if i18n is None:
        return value
    return i18n.t(value)


# --- The seeded rolls (docs/80-* §4.7.8) ------------------------------------


def _visit_seed(fleet_id: str, port_id: str, arrival_day: int) -> int:
    return godot_string_hash("%s|%s|%d" % (fleet_id, port_id, arrival_day))


def arrival_day_of(fleet: dict[str, Any]) -> int:
    """The day a docked fleet arrived (``dwell_until_day − DWELL_DAYS``)."""
    return max(0, int(fleet.get("dwell_until_day", 0)) - DWELL_DAYS)


def primary_facility(role: str) -> str:
    """The role's primary facility (§4.7.8): trader/treasure→market,
    coaster/patrol/courier/privateer/pirate→tavern, hunter→palace."""
    if role in (ec.TRADER, ec.TREASURE):
        return FACILITY_MARKET
    if role in (ec.COASTER, ec.PATROL, ec.COURIER, ec.PRIVATEER, ec.PIRATE):
        return FACILITY_TAVERN
    if role == ec.HUNTER:
        return FACILITY_PALACE
    return FACILITY_TAVERN


def facility_of(fleet: dict[str, Any], port_id: str) -> str:
    """The facility a docked fleet's captain is sighted at (60/40 roll)."""
    role = str(fleet.get("role", ""))
    if role == ec.HUNTER:
        return FACILITY_PALACE
    rng = ec.GodotRng(seed=_visit_seed(
        str(fleet.get("id", "")), port_id, arrival_day_of(fleet)) * 31
        + godot_string_hash("facility"))
    if rng.randf() < FACILITY_PRIMARY_CHANCE:
        return primary_facility(role)
    return FACILITY_ALTERNATES[rng.randi_range(
        0, len(FACILITY_ALTERNATES) - 1)]


def is_present(fleet: dict[str, Any], port_id: str) -> bool:
    """The 75% presence roll (same visit seed; else gone ashore)."""
    rng = ec.GodotRng(seed=_visit_seed(
        str(fleet.get("id", "")), port_id, arrival_day_of(fleet)) * 31
        + godot_string_hash("presence"))
    return rng.randf() < PRESENT_CHANCE


# --- Docked fleets & sightings -----------------------------------------------


def docked_fleets(source: Any, port_id: str) -> list[dict[str, Any]]:
    """Fleets docked at ``port_id`` (on its berth, dwell active), id-sorted."""
    store = _store_of(None)
    cell = _berth(store, port_id)
    if cell[0] < 0:
        return []
    state = _state_of(source)
    out = [fleet for fleet in _within(source, cell, 0)
           if int(fleet.get("dwell_until_day", 0)) > state.day]
    out.sort(key=lambda fleet: str(fleet.get("id", "")))
    return out


def _berth(store: DataStore, port_id: str) -> tuple[int, int]:
    from server.sim.world import raster as raster_module
    cell = raster_module.raster().port_cell(port_id)
    return (int(cell[0]), int(cell[1]))


def sightings(source: Any, port_id: str, facility: str,
              i18n: Any = None, store: DataStore | None = None) \
        -> list[dict[str, Any]]:
    """The captains sighted at ``port_id``'s ``facility`` (§4.7.8).

    Rows: ``{fleet, id, captain_id, name, tier, role, nation_id}`` sorted by
    fleet id. Each row accrues one familiarity on the captain (the oracle's
    ``Captains.add_familiarity``)."""
    dst = _store_of(store)
    state = _state_of(source)
    bridge = _CaptainsBridge(state.captain_states, dst)
    out: list[dict[str, Any]] = []
    for fleet in docked_fleets(source, port_id):
        if not is_present(fleet, port_id):
            continue
        if facility_of(fleet, port_id) != facility:
            continue
        captain_id = str(fleet.get("captain_id", ""))
        if captain_id:
            bridge.add_familiarity(captain_id)
        out.append({
            "fleet": fleet,
            "id": str(fleet.get("id", "")),
            "captain_id": captain_id,
            "name": captain_name(fleet, i18n, dst),
            "tier": captain_tier_of(fleet, dst),
            "role": str(fleet.get("role", "")),
            "nation_id": str(fleet.get("nation_id", "")),
        })
    return out


def gone_ashore(source: Any, port_id: str, i18n: Any = None,
                store: DataStore | None = None) -> list[dict[str, Any]]:
    """Docked captains that failed today's presence roll (``{id, name}``)."""
    dst = _store_of(store)
    out: list[dict[str, Any]] = []
    for fleet in docked_fleets(source, port_id):
        if is_present(fleet, port_id):
            continue
        out.append({"id": str(fleet.get("id", "")),
                    "name": captain_name(fleet, i18n, dst)})
    return out


# --- Wanted posters & the paid reveal (docs/80-* §4.7.8) ---------------------


def wanted_posters(source: Any, port_id: str, i18n: Any = None,
                   store: DataStore | None = None) -> list[dict[str, Any]]:
    """At-sea pirate/privateer captains within Chebyshev 40 of the port.

    Rows: ``{id, captain_id, name, tier, nearest_port, nearest_port_name,
    reward_gold, cell}`` sorted by fleet id. Every pirate/privateer captain
    posts (the canon carries a full card); the reward hint uses the
    ``70-*`` §4.9.3 bands."""
    dst = _store_of(store)
    state = _state_of(source)
    cell = _berth(dst, port_id)
    if cell[0] < 0:
        return []
    out: list[dict[str, Any]] = []
    for fleet in _within(source, cell, POSTER_RADIUS):
        role = str(fleet.get("role", ""))
        if role not in (ec.PIRATE, ec.PRIVATEER):
            continue
        if int(fleet.get("dwell_until_day", 0)) > state.day:
            continue  # at-sea posters only
        near = nearest_port(position_of(fleet), dst)
        tier = captain_tier_of(fleet, dst)
        out.append({
            "id": str(fleet.get("id", "")),
            "captain_id": str(fleet.get("captain_id", "")),
            "name": captain_name(fleet, i18n, dst),
            "tier": tier,
            "nearest_port": near,
            "nearest_port_name": _port_name(near, i18n, dst),
            "reward_gold": int(BOUNTY_GOLD_BY_TIER.get(tier, 5000)),
            "cell": position_of(fleet),
        })
    out.sort(key=lambda row: str(row.get("id", "")))
    return out


def reveal_position(source: Any, fleet_id: str, i18n: Any = None,
                    store: DataStore | None = None) -> dict[str, Any]:
    """The paid reveal (§4.7.8): the poster's exact live position. ``{}``
    for an unknown/fleet-less id. Text only; the screen charges the 20g."""
    dst = _store_of(store)
    for fleet in _state_of(source).npc_fleets:
        if not isinstance(fleet, dict):
            continue
        if str(fleet.get("id", "")) != fleet_id:
            continue
        cell = position_of(fleet)
        near = nearest_port(cell, dst)
        return {
            "id": fleet_id,
            "name": captain_name(fleet, i18n, dst),
            "cell": cell,
            "nearest_port": near,
            "nearest_port_name": _port_name(near, i18n, dst),
        }
    return {}


# --- Rumor row sources (docs/80-* §4.7.8, 30-* §4.5) ------------------------


def rumor_rows(source: Any, port_id: str, i18n: Any = None,
               economy: EconomyState | None = None,
               allegiance: Any = None,
               person: PersonState | None = None,
               store: DataStore | None = None) -> list[dict[str, Any]]:
    """Tavern rumor rows in display order: demand-event telegraphs, investment
    telegraphs, port-traffic log rows within 3 days, then live fleets within
    Chebyshev 40. Row ``kind`` ∈ ``event | investment | departed | arrived |
    fleet`` — the screen formats each with its ui_strings key."""
    dst = _store_of(store)
    state = _state_of(source)
    out: list[dict[str, Any]] = []
    if economy is not None:
        for entry in economy_lib.event_telegraphs(
                economy, dst, port_id, state.day):
            instance = entry.get("instance") if isinstance(
                entry.get("instance"), dict) else {}
            template = entry.get("template") if isinstance(
                entry.get("template"), dict) else {}
            affected = str(instance.get("port_id", ""))
            out.append({
                "kind": "event",
                "port_id": affected,
                "port_name": _port_name(affected, i18n, dst),
                "event_name": _t(template.get("name", {}), i18n),
            })
    if allegiance is not None and person is not None:
        out.extend(investment_rows(port_id, allegiance, person,
                                   i18n=i18n, store=dst))
    cell = _berth(dst, port_id)
    traffic: list[dict[str, Any]] = []
    for record in state.npc_port_log:
        if not isinstance(record, dict):
            continue
        if str(record.get("port_id", "")) != port_id:
            continue
        if int(record.get("day", 0)) < state.day - 3:
            continue
        traffic.append(record)
    fleet_by_id = {str(fleet.get("id", "")): fleet
                   for fleet in state.npc_fleets if isinstance(fleet, dict)}
    for record in traffic:
        kind = str(record.get("kind", ""))
        if kind == "arrival":
            out.append({
                "kind": "arrived",
                "id": str(record.get("fleet_id", "")),
                "role": str(record.get("role", "")),
                "nation_id": str(record.get("nation_id", "")),
                "day": int(record.get("day", 0)),
            })
        elif kind == "departure":
            fleet = fleet_by_id.get(str(record.get("fleet_id", "")), {})
            dest = str(fleet.get("dest_port_id", ""))
            out.append({
                "kind": "departed",
                "id": str(record.get("fleet_id", "")),
                "role": str(record.get("role", "")),
                "nation_id": str(record.get("nation_id", "")),
                "dest_port": dest,
                "dest_port_name": _port_name(dest, i18n, dst),
                "day": int(record.get("day", 0)),
            })
    if cell[0] < 0:
        return out
    spoken_for: dict[str, bool] = {
        str(record.get("fleet_id", "")): True for record in traffic}
    for fleet in _within(source, cell, RUMOR_RADIUS):
        fleet_id = str(fleet.get("id", ""))
        if fleet_id in spoken_for:
            continue  # already reported through the traffic log
        spoken_for[fleet_id] = True
        near = nearest_port(position_of(fleet), dst)
        out.append({
            "kind": "fleet",
            "id": fleet_id,
            "role": str(fleet.get("role", "")),
            "nation_id": str(fleet.get("nation_id", "")),
            "nearest_port": near,
            "nearest_port_name": _port_name(near, i18n, dst),
        })
    return out


# --- Investment telegraphs (Phase 7, docs/80-* §4.7.14) ----------------------


def _item_str(item: dict[str, Any], keys: list[str]) -> str:
    for key in keys:
        value = item.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def _item_int(item: dict[str, Any], keys: list[str], fallback: int) -> int:
    for key in keys:
        value = item.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return int(value)
    return fallback


def investment_rows(here_port_id: str, allegiance: Any,
                    person: PersonState, i18n: Any = None,
                    store: DataStore | None = None) -> list[dict[str, Any]]:
    """Investment telegraph rows visible in ``here_port_id``'s tavern: one per
    investment in the SAME ``band`` still inside its window (``days_left``
    > 0; a row with no day count stays visible — the module owns the window).
    Rows: ``{kind: "investment", port_id, port_name, nation_id, nation_name,
    amount, days_left}``."""
    dst = _store_of(store)
    out: list[dict[str, Any]] = []
    if not here_port_id:
        return out
    here_band = str(dst.get_port(here_port_id).get("band", ""))
    for item in allegiance_lib.last_month_investments(allegiance, person):
        if not isinstance(item, dict):
            continue
        port_id = _item_str(item, ["port_id", "port"])
        if not port_id:
            continue
        if str(dst.get_port(port_id).get("band", "")) != here_band:
            continue
        days_left = _item_int(item, ["days_left", "days", "days_remaining"], -1)
        if days_left != -1 and days_left <= 0:
            continue  # the 30-day window has closed
        nation_id = _item_str(item, ["nation_id", "nation"])
        out.append({
            "kind": "investment",
            "port_id": port_id,
            "port_name": _port_name(port_id, i18n, dst),
            "nation_id": nation_id,
            "nation_name": "-" if not nation_id
            else _t(dst.get_nation(nation_id).get("name", {}), i18n),
            "amount": _item_int(item, ["amount", "gold"], 0),
            "days_left": days_left,
        })
    return out


# --- Hunter-intel cell queries (docs/60-* §4.11.11.1) ------------------------


def hunter_intel_cell(state: FleetEcologyState) -> tuple[int, int] | None:
    """The persisted at-sea intel cell (``world.hunter_intel_cell``), or
    ``None`` when no hunting-nation contact has been recorded."""
    value = state.world.get("hunter_intel_cell")
    cell = ec.cell_field(value)
    return None if cell == ec.NO_CELL else cell


def hunter_intel_port(state: FleetEcologyState) -> str:
    """The hunter-intel object: the port the player last sailed from
    (``world.last_departed_port``)."""
    return str(state.world.get("last_departed_port", ""))


def hunter_intel_known(state: FleetEcologyState) -> bool:
    """True when either hunter-intel field is set."""
    return bool(hunter_intel_port(state) or hunter_intel_cell(state))


# --- Helpers -----------------------------------------------------------------


def nearest_port(cell: tuple[int, int],
                 store: DataStore | None = None) -> str:
    """The port whose berth tile is nearest ``cell`` (ties by port id)."""
    dst = _store_of(store)
    best = ""
    best_distance = -1
    for port in dst.ports_list:
        port_id = str(port.get("id", ""))
        if not port_id:
            continue
        berth = _berth(dst, port_id)
        if berth[0] < 0:
            continue
        distance = chebyshev(cell, berth)
        if best_distance < 0 or distance < best_distance \
                or (distance == best_distance and port_id < best):
            best = port_id
            best_distance = distance
    return best


def _port_name(port_id: str, i18n: Any, store: DataStore) -> Any:
    if not port_id:
        return "-"
    return _t(store.get_port(port_id).get("name", {}), i18n)
