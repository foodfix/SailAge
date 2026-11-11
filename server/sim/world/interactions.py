"""server.sim.world.interactions — the at-sea interaction layer (M1).

Python port of ``scripts/world/interactions.gd`` (the frozen parity oracle
until the M6 cutover). Normative contract:

  * docs/60-COMBAT.md §4.11.15 — the verb surfaces, the intercept order and
    its auto-cancel, the piracy rule and the attack funnel's encounter dict
    (§4.11.11.2/§4.11.11.3: the S10 descriptor shape is unchanged);
  * docs/80-UI-UX.md §4.10 — the right-click hit rules (inside the sighting
    radius → the picker; a harbor tile → the port context; empty water or
    land → a no-op), the picker verbs (inspect / talk / attack, **a
    ``coaster``-role fleet offers no attack verb** — intimidate-only,
    60-§4.1.1) and the talk gate (Chebyshev ≤ 2);
  * docs/20-WORLD-AND-SAILING.md §4.11 — the sighting radius
    ``48 + floor(effective navigation / 12)``.

Owns the *pure* half of every §4.10 surface: targeting (which fleet holds a
tile), attribution (the verbs a fleet offers), the intercept order's
arithmetic (set shape, cancel evaluation), the encounter dict the §4.11.11.2
funnel opens, the inspect summary payload and the appointed-voyage gate
read. The world scene's side effects (the picker modal, the sail route an
intercept rides, the battle handoff, the toasts) are the web client's +
the WS intent handlers' — this module only computes and never mutates
anything.

Deterministic: pure functions of the injected run state and the loaded
data, no RNG (60-§4.11.15 pins the interaction layer as seeded-replayable
by construction; verified at port time by grep).

State convention (the M1 port rule, mirroring ``server/sim/port/palace.py``):
the run-scoped fields the GDScript statics read off the ``GameState``
singleton arrive in the injected ``run`` dict whose keys mirror the
GameState members verbatim — ``npc_fleets`` (the live fleet list),
``world`` (the §4.15 world block: ``position`` / ``wind_dir`` /
``weather``), ``known_ports`` (list), ``captain_states`` (dict). The
person reads go through :class:`~server.sim.player.PersonState` (``st``).

Cross-module seams (marked, other ownership):
  * ``server.sim.world.npc_fleets`` — not landed yet: the exact-tile
    targeting here is a direct wrap-aware scan over ``run["npc_fleets"]``
    (the semantics of the oracle's ``fleet_at`` read; the bucket index
    stays the ecology port's), and the empty-``ships`` encounter branch
    delegates to ``npc_fleets.compose_fleet_ships`` through a lazy import;
  * ``server.sim.world.sailing_sim`` — not landed yet: the sighting-radius
    and month formulas live here verbatim with their doc pins (the
    sailing-sim port owns the canonical forms);
  * ``server.sim.combat`` — not landed yet: the battle RUNS there; this
    module only builds the descriptor.
"""

from __future__ import annotations

import copy
import math
from typing import Any, Final

from server.sim.data import DataStore
from server.sim.player import PersonState, skills
from server.sim.world.raster import GRID_WIDTH, chebyshev_wrap, ocean_layers

__all__ = [
    "VERB_INSPECT",
    "VERB_TALK",
    "VERB_ATTACK",
    "HAIL_RANGE",
    "CANCEL_LEFT_SIGHTING",
    "AUTOPILOT_GATE_ID",
    "AUTOPILOT_NAV_FALLBACK",
    "ROLE_COASTER",
    "SIGHTING_RADIUS",
    "SIGHTING_NAVIGATION_DIVISOR",
    "UNKNOWN_NAME_KEY",
    "fleets_at",
    "target_at",
    "fleet_by_id",
    "in_range",
    "hail_in_range",
    "verbs_for",
    "intercept",
    "intercept_cancel_reason",
    "attack_encounter",
    "inspect_summary",
    "display_name",
    "appoint_gate",
]

# --- The §4.10.1 verbs, in row order -----------------------------------------

VERB_INSPECT: Final[str] = "inspect"
VERB_TALK: Final[str] = "talk"
VERB_ATTACK: Final[str] = "attack"

#: §4.11.15: the hail (the talk verb) opens at Chebyshev ≤ 2.
HAIL_RANGE: Final[int] = 2

#: The one auto-cancel reason an intercept order can carry (§4.11.15: the
#: order cancels when the target leaves the sighting radius — a target that
#: is gone from the world entirely reads the same way: nothing is left in
#: sight to chase).
CANCEL_LEFT_SIGHTING: Final[str] = "left_sighting"

#: The appointed-voyage gate row (``data/skill_gates.json`` feature_id,
#: 20-* §4.19): a pilot in post with navigation ≥ the row threshold, and the
#: destination ∈ ``known_ports``.
AUTOPILOT_GATE_ID: Final[str] = "sail.autopilot"
#: Doc-pinned threshold fallback (20-* §4.19 "navigation ≥ 40") used only if
#: the data row is missing — the JSON row is the source of truth, this
#: constant keeps a broken data file from crashing the menu.
AUTOPILOT_NAV_FALLBACK: Final[int] = 40

#: The coaster role id (``scripts/world/npc_fleets.gd`` ``COASTER``; the
#: §4.1.1 coaster row is the more specific pin: not attackable,
#: intimidate-only). The ecology port owns the canonical constant.
ROLE_COASTER: Final[str] = "coaster"

#: docs/20-* §4.11 (Phase 8): the sighting radius base and navigation
#: divisor — ``48 + floor(navigation / 12)``. The sailing-sim port owns the
#: canonical form (``SailingSim.sighting_radius``); re-homed there when it
#: lands.
SIGHTING_RADIUS: Final[int] = 48
SIGHTING_NAVIGATION_DIVISOR: Final[int] = 12

#: The unidentified-fleet fallback line (80-* §4.10.1): rendered by the
#: client when :func:`display_name` returns ``{}``.
UNKNOWN_NAME_KEY: Final[str] = "interact.unknown_name"

# --- Targeting (docs/80-* §4.10.1 hit rules) ---------------------------------

def _position_of(fleet: dict[str, Any]) -> tuple[int, int]:
    """The fleet's cell from the ``{"x","y"}`` save shape (the oracle's
    ``NpcFleets.position_of`` read, tolerant of ``[x, y]`` pairs)."""
    cell = fleet.get("cell")
    if isinstance(cell, dict):
        return int(cell.get("x", 0)), int(cell.get("y", 0))
    if isinstance(cell, (list, tuple)) and len(cell) >= 2:
        return int(cell[0]), int(cell[1])
    return -1, -1


def _on_tile(fleet: dict[str, Any], x: int, y: int) -> bool:
    """The exact-tile match, wrap-aware on x (a query at x = −1 or x = 4320·k
    offsets resolves the same column, 20-* §4.1); y matches exactly."""
    fx, fy = _position_of(fleet)
    return (fx - x) % GRID_WIDTH == 0 and fy == y


def fleets_at(run: dict[str, Any], cell: tuple[int, int]) -> list[Any]:
    """Every live fleet standing exactly on ``cell``, sorted by id ascending
    — the deterministic pick list behind a multi-fleet tile (§4.10.1 "a
    multi-fleet tile picks its target first")."""
    x, y = int(cell[0]), int(cell[1])
    out = [fleet for fleet in run.get("npc_fleets", [])
           if isinstance(fleet, dict) and _on_tile(fleet, x, y)]
    out.sort(key=lambda fleet: str(fleet.get("id", "")))
    return out


def target_at(run: dict[str, Any], cell: tuple[int, int]) -> dict[str, Any]:
    """The NPC fleet at ``cell`` — the first of :func:`fleets_at` by id
    (``{}`` when the tile holds none)."""
    fleets = fleets_at(run, cell)
    return fleets[0] if fleets else {}


def fleet_by_id(run: dict[str, Any], fleet_id: str) -> dict[str, Any]:
    """A live fleet dict by id (``{}`` when gone — removed by a battle, an
    auto-resolve or a budget shrink). Linear read of the save block; the
    intercept tick calls this once per player step."""
    for fleet in run.get("npc_fleets", []):
        if isinstance(fleet, dict) \
                and str(fleet.get("id", "")) == fleet_id:
            return fleet
    return {}


# --- Range & verbs (docs/80-* §4.10.1, docs/60-* §4.11.15) -------------------

def sighting_radius_for(effective_navigation: int) -> int:
    """The §4.11 sighting radius for an explicit effective-navigation value
    (the pure formula; ``SailingSim.sighting_radius`` when the sailing-sim
    port lands)."""
    return SIGHTING_RADIUS + int(math.floor(
        float(effective_navigation) / float(SIGHTING_NAVIGATION_DIVISOR)))


def _effective_navigation(st: PersonState, store: DataStore) -> int:
    """``SailingSim.effective_navigation``: the player's effective skill
    (player value + the in-post pilot's contribution, 50-§4.5.3 — the
    ported ``skills.effective_skill``)."""
    return skills.effective_skill(st, store, "navigation")


def in_range(run: dict[str, Any], st: PersonState, store: DataStore,
             fleet: dict[str, Any], radius: int = -1) -> bool:
    """True when ``fleet`` stands within ``radius`` tiles of the player's
    fleet (Chebyshev, wrap-aware on x). ``radius < 0`` means the sighting
    radius ``48 + floor(effective navigation / 12)`` (20-* §4.11) — the
    §4.10.1 hit rule "right-click inside sighting radius"."""
    if not fleet:
        return False
    limit = radius
    if limit < 0:
        limit = sighting_radius_for(_effective_navigation(st, store))
    pos = run.get("world", {}).get("position", {})
    if not isinstance(pos, dict):
        return False
    fx, fy = _position_of(fleet)
    return chebyshev_wrap(int(pos.get("x", 0)), int(pos.get("y", 0)),
                          fx, fy) <= limit


def hail_in_range(run: dict[str, Any], fleet: dict[str, Any]) -> bool:
    """True when ``fleet`` is close enough to hail (§4.11.15: Chebyshev ≤ 2)
    — the talk verb's gate; beyond it the picker grays the row with
    ``interact.talk.too_far`` (80-* §4.10.1)."""
    if not fleet:
        return False
    pos = run.get("world", {}).get("position", {})
    if not isinstance(pos, dict):
        return False
    fx, fy = _position_of(fleet)
    return chebyshev_wrap(int(pos.get("x", 0)), int(pos.get("y", 0)),
                          fx, fy) <= HAIL_RANGE


def verbs_for(fleet: dict[str, Any]) -> list[str]:
    """The verbs ``fleet`` offers the picker, in row order: inspect / talk /
    attack. **A ``coaster``-role fleet offers no attack verb** (§4.1.1's
    more specific pin, restated by §4.11.15 and 80-* §4.10.1: intimidate-
    only — talk still opens the hail, where intimidate lives). The picker
    renders exactly this list, so the surface and the rule cannot drift."""
    verbs = [VERB_INSPECT, VERB_TALK]
    if str(fleet.get("role", "")) != ROLE_COASTER:
        verbs.append(VERB_ATTACK)
    return verbs


# --- Intercept order (docs/60-* §4.11.15) ------------------------------------

def intercept(fleet: dict[str, Any]) -> dict[str, Any]:
    """The intercept order against ``fleet``: the target's id and its cell
    **at set time**. The caller issues the movement through the existing
    click-to-sail path onto this cell and re-targets the order on every
    contact-check tick while the target is alive — the cell here is where
    the chase starts, never a persistent destination."""
    fx, fy = _position_of(fleet)
    return {
        "target_id": str(fleet.get("id", "")),
        "target_cell": {"x": fx, "y": fy},
    }


def intercept_cancel_reason(run: dict[str, Any], st: PersonState,
                            store: DataStore,
                            order: dict[str, Any]) -> str:
    """The cancel evaluation the caller runs on every contact-check tick
    while an order is active: ``""`` while valid —
    :data:`CANCEL_LEFT_SIGHTING` when the target's Chebyshev distance from
    the intercepting fleet's current position exceeds the sighting radius
    (auto-cancel + the ``interact.intercept.cancelled`` line, §4.11.15),
    ``""`` never otherwise. A target that no longer exists in
    ``run["npc_fleets"]`` answers :data:`CANCEL_LEFT_SIGHTING` too: nothing
    is left in sight to chase, which is the same reason with the same
    handling."""
    if not order:
        return ""
    fleet = fleet_by_id(run, str(order.get("target_id", "")))
    if not fleet:
        return CANCEL_LEFT_SIGHTING
    pos = run.get("world", {}).get("position", {})
    fx, fy = _position_of(fleet)
    if chebyshev_wrap(int(pos.get("x", 0)), int(pos.get("y", 0)),
                      fx, fy) > sighting_radius_for(
            _effective_navigation(st, store)):
        return CANCEL_LEFT_SIGHTING
    return ""


# --- The attack funnel's encounter dict (docs/60-* §4.11.11.2/§4.11.11.3) ----

def _composition_kind(role: str) -> str:
    """``NpcFleets.composition_kind`` (the §4.11.11.3 kind mapping): a
    ``hunter`` keeps the navy kind, every other role its role id. Re-homed
    to the ecology port when it lands."""
    return "navy" if role == "hunter" else role


def _compose_fleet_ships(fleet: dict[str, Any], day: int) -> list[Any]:
    """**Seam — the ecology port.** §4.11.11.2: the battle draws from the
    fleet's own seeded stream (``npc_fleets.compose_fleet_ships``). The
    module is not landed yet; this delegation documents the exact import
    path the caller code resolves against (the quests-seam convention)."""
    from server.sim.world import npc_fleets  # noqa: PLC0415 — the marked seam
    return npc_fleets.compose_fleet_ships(fleet, day)


def attack_encounter(store: DataStore, run: dict[str, Any],
                     fleet: dict[str, Any], day: int) -> dict[str, Any]:
    """The S10 encounter dict for a player attack on ``fleet`` — the exact
    shape the contact funnel queues (the piracy charge + the double-contact
    guard stay single-funnel in the caller; the dict only carries the
    data). ``day`` is the caller's ledger day (``st.day``, the GameState.day
    mirror). The fleet's saved fields ride unchanged plus: ``kind`` = the
    §4.11.11.3 mapping (a ``hunter`` keeps the navy kind, every other role
    its role id), ``encounter_id`` = the fleet id, ``ships`` = the fleet's
    own seeded composition (a fleet-carried ``ships`` override — a fixture
    seam — is honored verbatim), and ``contact`` = the player's current
    tile (where the battle returns the fleet, §4.11.11.3).

    Also carries the three locked battle conditions (§4.2 battle-condition
    lock): ``wind_dir`` (the world's wind-FROM token), ``weather`` (the
    engine id) and ``current`` (the decoded, reversal-applied contact-tile
    current, shaped ``{dir, strength}``, strength 0 when the tile has
    none). The sim config defaults read the same sources when the keys are
    absent, so the values agree for both this handoff and battle fixtures."""
    encounter = copy.deepcopy(fleet)
    encounter["kind"] = _composition_kind(str(fleet.get("role", "")))
    encounter["encounter_id"] = str(fleet.get("id", ""))
    if not list(fleet.get("ships", []) or []):
        encounter["ships"] = _compose_fleet_ships(fleet, int(day))
    pos = run.get("world", {}).get("position", {})
    x = int(pos.get("x", 0)) if isinstance(pos, dict) else 0
    y = int(pos.get("y", 0)) if isinstance(pos, dict) else 0
    encounter["contact"] = {"x": x, "y": y}
    world = run.get("world", {})
    encounter["wind_dir"] = str(world.get("wind_dir", "E"))
    encounter["weather"] = str(world.get("weather", "calm"))
    # The decoded contact-tile current (reversal applied at lookup, 10-§6.5),
    # regardless of the world's current_mode (60-* §4.2, correction 1). The
    # month comes from the §4.15 calendar (the sailing-sim port owns the
    # canonical month_for).
    decoded = ocean_layers().current_at(x, y, month_for(int(day)))
    encounter["current"] = (
        {"dir": "", "strength": 0} if decoded is None
        else {"dir": str(decoded.get("dir", "")),
              "strength": max(0, min(int(decoded.get("strength", 0)), 3))})
    return encounter


def month_for(day: int) -> int:
    """The §4.15 calendar month of ``day``:
    ``floor(posmod(day − 1, 30 × 12) / 30) + 1`` — the ``%`` keeps the
    12-month lattice anchored at day 1 even for ``day ≤ 0`` fixtures (the
    Godot ``posmod`` semantics). The sailing-sim port owns the canonical
    form; duplicated verbatim here (with its doc pin) because the module is
    not landed yet."""
    return ((int(day) - 1) % (30 * 12)) // 30 + 1


# --- Inspect (docs/80-* §4.10.1; the unified card is M3's) -------------------

def _captain_card_of(store: DataStore, fleet: dict[str, Any]) -> dict[str, Any]:
    """The fleet captain's canon card (10-§4.11), ``{}`` without one (the
    oracle's ``NpcFleets.captain_card_of`` → ``Captains.captain`` read)."""
    return store.get_captain(str(fleet.get("captain_id", "")))


def display_name(store: DataStore, fleet: dict[str, Any]) -> dict[str, Any]:
    """The row/summary name for ``fleet`` as an L10nString — the canon
    captain's ``{zh, en}`` name (every Phase-8 captain carries a canon card,
    80-* §4.10.1), or ``{}`` when unidentified (the client renders the
    :data:`UNKNOWN_NAME_KEY` line). A copy: the canon is never handed out."""
    card = _captain_card_of(store, fleet)
    name = card.get("name")
    return dict(name) if isinstance(name, dict) and name else {}


def inspect_summary(store: DataStore, run: dict[str, Any],
                    fleet: dict[str, Any]) -> dict[str, Any]:
    """The inspect verb's summary payload until the unified character card
    lands (80-* §4.12.1; the M3 screen renders it). Structured, not
    pre-formatted: ``name`` (L10nString or ``{}`` → the unidentified
    fallback), ``role_key`` (the ``captain.role.*`` ui_strings key),
    ``tier`` (0 = omit the tier line), ``level`` (``None`` = omit the level
    line) and the relation block ``stance`` / ``familiarity`` (``None``
    when the fleet carries no captain id — the client omits both lines).
    Deterministic: the same fleet always yields the same payload (the §2.6
    acceptance pin's W5 half)."""
    card = _captain_card_of(store, fleet)
    name = display_name(store, fleet)
    captain_id = str(fleet.get("captain_id", ""))
    stance: int | None = None
    familiarity: int | None = None
    if captain_id:
        entry = run.get("captain_states", {}).get(captain_id)
        entry = entry if isinstance(entry, dict) else {}
        stance = int(entry.get("stance", 0))
        familiarity = int(entry.get("familiarity", 0))
    return {
        "name": name,
        "role_key": "captain.role.%s" % str(fleet.get("role", "")),
        "tier": int(card.get("tier", 0)),
        "level": int(card.get("level", 1)) if card else None,
        "stance": stance,
        "familiarity": familiarity,
    }


# --- The appointed-voyage gate (docs/20-* §4.19, docs/80-* §4.10.3) ----------

def appoint_gate(store: DataStore, st: PersonState, run: dict[str, Any],
                 port_id: str) -> dict[str, Any]:
    """The ``sail.autopilot`` gate for appointing a voyage to ``port_id``:
    ``{ok: bool, reason}`` — ok when a pilot officer is in post with
    navigation ≥ the data row's threshold **and** the destination is a
    known port. ``reason`` is the row's own localized ``reason`` L10nString
    (50-§4.3.5: the reasons live in the JSON), ``{}`` when ok. The actual
    appointment is the autopilot module's; this read is what grays the
    port-context row."""
    gate = store.get_skill_gate(AUTOPILOT_GATE_ID)
    threshold = int(gate.get("threshold", AUTOPILOT_NAV_FALLBACK))
    pilot_id = skills.post_holder(st, "pilot")
    navigation = 0
    if pilot_id:
        navigation = int(store.get_officer(pilot_id)
                         .get("skills", {}).get("navigation", 0))
    known = port_id in list(run.get("known_ports", []))
    if not pilot_id or navigation < threshold or not known:
        return {"ok": False, "reason": gate.get("reason", {})}
    return {"ok": True, "reason": {}}
