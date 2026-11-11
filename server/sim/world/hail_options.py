"""server.sim.world.hail_options — the at-sea hail (M1).

Python port of ``scripts/world/hail_options.gd`` (the frozen parity oracle
until the M6 cutover). Normative contract:

  * docs/60-COMBAT.md §4.11.15 "Hail (talk)" — the option matrix and the
    resolve funnel, term by term;
  * docs/80-UI-UX.md §4.10.2 — the hail modal's option rows and their
    inline terms (the web client renders; this module decides);
  * docs/50-CHARACTER-AND-PROGRESSION.md §4.2 charisma / §4.3 negotiation;
  * docs/30-PORTS-AND-TRADE.md §4.2 "at-sea supply price source".

Pure functions over injected state (the M1 port rule, mirroring
``server/sim/port/palace.py``): the run-scoped fields the GDScript statics
read off the ``GameState`` singleton arrive in the injected ``run`` dict
whose keys mirror the GameState members verbatim — ``world`` (the §4.15
world block; only ``position`` is read), ``known_ports``,
``captain_states`` and ``fleet`` (the PLAYER fleet, the supplies/loot
sink). The person reads go through
:class:`~server.sim.player.PersonState` (``st``: gold, day, fame, skills,
attributes, equipment, officer_states). The modal's Chebyshev ≤ 2 range
guarantee is defended here (out-of-range hails build NOTHING and resolve
``{ok: False}``); turning ``made_hostile`` into the §4.11.11.2 contact
battle is the caller's.

Contract (the W5-B pin, term by term per 60-* §4.11.15):

  * ``options_for(fleet)`` — one entry per talk option,
    ``{id, enabled, reason_key?}`` plus additive display payloads
    (``intel`` / ``unit_prices`` / ``max_qty`` / ``chance``), built from
    **role × stance × skills**:
      - ``ask_rumours`` — always enabled; stance ≥ +2 carries
        ``intel = True`` (one free route/market intel, payload built from
        the fleet's ``dest_port_id`` / route lanes — no RNG).
      - ``buy_supplies`` — ``trader``/``coaster`` captains ONLY (the
        §4.1.1 rows are the more specific pin; other roles get no
        supplies row at all). Port supply price ×1.5, ×1.25 at
        stance ≥ +3, minus the negotiation discount
        ``floor(negotiation / 10)``% capped at the formula's own
        −5-point reach (50-* §4.3.1 / 30-* §4.10); every price floors at
        1g. **Price base pin:** the hailed fleet's ``dest_port_id`` port
        — its destination is deterministic — falling back to the player's
        nearest known port when the fleet has none. The port resolves the
        *seam*; the numbers flow through
        :func:`server.sim.port.trade.supplies_price` (the market's own
        plumbing — supplies ignore every port factor by design).
      - ``intimidate`` — every role may be intimidated (a coaster's ONLY
        hostile verb: the picker gives coasters no attack, 60-§4.1.1).
        ``p = clamp(ours/(ours+theirs) + floor(COU/200)
        − max(0, −stance) × 0.05, 0.05, 0.95)``.
      - ``befriend`` — stance +1, once per captain per DAY (the session
        map below; the disabled reason is ``hail.befriend.used``).

  * ``resolve(option_id, fleet, qty, roll)`` — the single funnel that
    APPLIES gold/cargo/fame/stance (testable headless) and returns
    ``{ok, lines, gold_delta?, cargo_gained?, intel?, made_hostile?,
    stance_delta?, fame_delta?, chance?}`` where ``lines`` is a list of
    ``{key, values}`` ui_strings pairs for the client to format (values
    may carry nested L10nStrings — the client resolves them first).
      - intimidate SUCCESS: the target hands over HALF its cargo (floor
        per good) + pirate fame +5 + stance −1 (``STANCE_INTIMIDATE_WIN``).
      - intimidate FAILURE: ``made_hostile`` (the caller opens the
        battle) + stance −2 (``STANCE_INTIMIDATE_FAIL``). No cargo moves.

  * **Roll contract.** ``roll ∈ [0,1)`` passed by the caller is honored
    verbatim — tests pass fixed rolls, the client draws one from the
    battle's seeded stream and passes it in (:func:`roll_seed` is the
    §4.11.1 seed formula at the fleet's tile). The default ``-1.0`` draws
    from the same stream here, so a caller that forgets still stays
    seeded.

  * **Supply qty semantics.** One stepper, one ``qty``: buying supplies at
    sea purchases ``qty`` provisions **and** the same ``qty`` water (a
    matched bundle — the hailed trader stocks both). Each kind's cost is
    floored once on its own full product (30-* §4.2 floor discipline).

Strength pricing (the §4.11.5 card formulas; the combat port owns the
canonical helpers — re-homed when ``server.sim.combat`` lands):
  ours   = player duel base (effective swordplay + floor(COU/20) + the
           worn weapon/armor ``combat`` modifiers) + Σ escort captains'
           card duel ratings (the officer in the ``captain`` post for that
           escort — ship identity is ``ship_type_id``).
  theirs = the target fleet's captain card duel rating
           (``swordplay + floor(courage/20)``); 0 without a card.

Session state: the once-per-captain-per-day befriend map is the GDScript
``static var`` — a session-transient module dict here, never saved;
:func:`reset_session` clears it (a fresh sim / the suites).

RNG seams: exactly one — :func:`draw_roll` seeds
:class:`~server.sim.rng.GodotRng` (bit-exact PCG32) with the §4.11.1
closed-form seed and takes one ``randf()``; every other value is a pure
function of injected state (the oracle file's only ``rand*`` call is the
same draw).
"""

from __future__ import annotations

import copy
import math
from typing import Any, Final

from server.sim.data import DataStore
from server.sim.player import PersonState, character, fame, skills
from server.sim.port import trade
from server.sim.rng import GodotRng
from server.sim.fleet import fleet as fleet_lib
from server.sim.world import captains
from server.sim.world.raster import tile_of_latlon

__all__ = [
    "OPTION_RUMOURS",
    "OPTION_SUPPLIES",
    "OPTION_INTIMIDATE",
    "OPTION_BEFRIEND",
    "HAIL_RANGE",
    "SUPPLY_ROLES",
    "SUPPLY_MULT_UNITS",
    "SUPPLY_WARM_STANCE",
    "SUPPLY_WARM_MULT_UNITS",
    "NEGOTIATION_DIVISOR",
    "NEGOTIATION_CAP_POINTS",
    "INTIMIDATE_P_MIN",
    "INTIMIDATE_P_MAX",
    "COURAGE_DIVISOR",
    "STANCE_PENALTY_PER_POINT",
    "INTIMIDATE_CARGO_SHARE",
    "INTIMIDATE_FAME",
    "INTEL_STANCE",
    "DUEL_COURAGE_DIVISOR",
    "SEED_DAY_MULT",
    "SEED_X_MULT",
    "SEED_Y_MULT",
    "SEED_GOLD_MULT",
    "SEED_FLEET_MULT",
    "UNKNOWN_NAME_KEY",
    "captain_card_of",
    "display_name",
    "stance_of",
    "in_range",
    "price_base_port",
    "negotiation_discount_points",
    "supply_unit_price",
    "supplies_unit_prices",
    "supplies_pair_cost",
    "supplies_max_qty",
    "player_strength",
    "target_strength",
    "intimidate_chance",
    "roll_seed",
    "draw_roll",
    "options_for",
    "resolve",
    "befriended_on",
    "reset_session",
    "reset_test_doubles",
]

# --- Options -----------------------------------------------------------------

OPTION_RUMOURS: Final[str] = "ask_rumours"
OPTION_SUPPLIES: Final[str] = "buy_supplies"
OPTION_INTIMIDATE: Final[str] = "intimidate"
OPTION_BEFRIEND: Final[str] = "befriend"

# --- Locked constants (docs/60-* §4.11.15; docs/50-* §4.3.1) -----------------

#: Hail range: Chebyshev ≤ 2 (the talk verb's guarantee; defended here).
HAIL_RANGE: Final[int] = 2

#: Roles whose captains sell supplies at sea (60-* §4.11.15: trader/coaster
#: only; the §4.1.1 rows are the more specific pin).
SUPPLY_ROLES: Final[tuple[str, ...]] = ("trader", "coaster")

#: Supply price multipliers, per-thousand: ×1.5 always; ×1.25 more at
#: stance ≥ +3 (folded into one ×1.875 per-thousand product below).
SUPPLY_MULT_UNITS: Final[int] = 1500
SUPPLY_WARM_STANCE: Final[int] = 3
SUPPLY_WARM_MULT_UNITS: Final[int] = 1250

#: Negotiation discount: ``floor(skill / 10)`` points, capped at the
#: formula's own reach of −5 points (50-* §4.3.1 magnitude / 30-* §4.10).
NEGOTIATION_DIVISOR: Final[int] = 10
NEGOTIATION_CAP_POINTS: Final[int] = 5

#: Intimidate: ``p = clamp(share + floor(COU/200) − max(0,−stance)×0.05,
#: 0.05, 0.95)`` (60-* §4.11.15).
INTIMIDATE_P_MIN: Final[float] = 0.05
INTIMIDATE_P_MAX: Final[float] = 0.95
COURAGE_DIVISOR: Final[float] = 200.0
STANCE_PENALTY_PER_POINT: Final[float] = 0.05

#: Intimidate SUCCESS: half the target's cargo (floor per good) + pirate
#: fame +5 (60-* §4.11.15). The stance deltas are the captains module's
#: shared constants.
INTIMIDATE_CARGO_SHARE: Final[int] = 2
INTIMIDATE_FAME: Final[int] = 5

#: Free intel gate: stance ≥ +2 (60-* §4.11.15).
INTEL_STANCE: Final[int] = 2

#: §4.11.5 card duel rating's courage divisor (the combat port owns the
#: canonical constant; re-homed when it lands).
DUEL_COURAGE_DIVISOR: Final[int] = 20

# --- The roll (docs/60-* §4.11.1 seed formula, reused at the fleet's tile) ---

#: ``day × 1000003 + contact.x × 7919 + contact.y × 104729 + gold × 31 +
#: fleet.size() × 17`` — plain integer arithmetic, identical on every
#: platform. The battle-sim port owns the canonical battle seed; the hail
#: reuses the same formula at the fleet's tile (60-* §4.11.15 roll
#: contract), constants pinned here in the meantime.
SEED_DAY_MULT: Final[int] = 1000003
SEED_X_MULT: Final[int] = 7919
SEED_Y_MULT: Final[int] = 104729
SEED_GOLD_MULT: Final[int] = 31
SEED_FLEET_MULT: Final[int] = 17

#: The unidentified-fleet fallback line (rendered by the client when
#: :func:`display_name` returns ``{}``).
UNKNOWN_NAME_KEY: Final[str] = "interact.unknown_name"

# --- Session state -----------------------------------------------------------

#: Befriend once per captain per day — session-transient
#: (``{captain_id: day}``), never saved (the GDScript ``static var``).
#: :func:`reset_session` clears it (a fresh sim / the suites).
_BEFRIENDED_TODAY: dict[str, int] = {}

#: The canon-card test doubles (the oracle's
#: ``BattleSim._captains_test_doubles`` seam — the combat port is not
#: landed yet, so the seam lives here until it does; keyed by captain id,
#: honored before the canon).
_CAPTAINS_TEST_DOUBLES: dict[str, dict[str, Any]] = {}


def reset_session() -> None:
    """Clears the session befriend map (the fresh-sim / suite seam)."""
    global _BEFRIENDED_TODAY
    _BEFRIENDED_TODAY = {}


def reset_test_doubles() -> None:
    """Clears the canon-card test doubles (the suite seam)."""
    global _CAPTAINS_TEST_DOUBLES
    _CAPTAINS_TEST_DOUBLES = {}


def befriended_on(captain_id: str, day: int) -> bool:
    """True when ``captain_id`` was befriended on game-day ``day`` (the map
    stores the last befriend day)."""
    return int(_BEFRIENDED_TODAY.get(captain_id, -1)) == int(day)


# --- Reading the fleet -------------------------------------------------------

def captain_card_of(store: DataStore, fleet: dict[str, Any]) -> dict[str, Any]:
    """The fleet's canon captain card (``{}`` without one) — the test
    doubles first, then the canon index (the §4.11.5 canon seam; the
    combat port's ``captain_canon_card`` when it lands)."""
    captain_id = str(fleet.get("captain_id", ""))
    if not captain_id:
        return {}
    double = _CAPTAINS_TEST_DOUBLES.get(captain_id)
    if isinstance(double, dict):
        return copy.deepcopy(double)
    return store.get_captain(captain_id)


def display_name(store: DataStore, fleet: dict[str, Any]) -> dict[str, Any]:
    """The captain's identified display name as an L10nString; ``{}`` when
    the card does not resolve (the client renders
    :data:`UNKNOWN_NAME_KEY`)."""
    card = captain_card_of(store, fleet)
    name = card.get("name")
    return dict(name) if isinstance(name, dict) and name else {}


def stance_of(captain_states: dict[str, Any], fleet: dict[str, Any]) -> int:
    """The fleet's stance (0 for an unmet captain)."""
    return captains.stance(captain_states, str(fleet.get("captain_id", "")))


def _cell_of(fleet: dict[str, Any]) -> dict[str, Any]:
    cell = fleet.get("cell")
    return cell if isinstance(cell, dict) else {}


def in_range(pos: dict[str, Any], fleet: dict[str, Any]) -> bool:
    """Chebyshev ≤ :data:`HAIL_RANGE` between the player tile (the run's
    ``world.position``) and the fleet cell — the oracle's defensive guard,
    plain absolute deltas (the picker's wrap-aware talk gate lives in
    :mod:`server.sim.world.interactions`)."""
    if not isinstance(pos, dict) or not pos:
        return False
    cell = _cell_of(fleet)
    if not cell:
        return False
    dx = int(pos.get("x", 0)) - int(cell.get("x", 0))
    dy = int(pos.get("y", 0)) - int(cell.get("y", 0))
    return max(abs(dx), abs(dy)) <= HAIL_RANGE


# --- Supply pricing (docs/30-* §4.2 "at-sea supply price source") ------------

def _port_tile(port: dict[str, Any]) -> tuple[int, int]:
    """The §6.1 projection (12 tiles/degree), the canonical
    :func:`server.sim.world.raster.tile_of_latlon`."""
    return tile_of_latlon(float(port.get("lat", 0.0)),
                          float(port.get("lon", 0.0)))


def price_base_port(store: DataStore, pos: dict[str, Any],
                    known_ports: list[Any], fleet: dict[str, Any]) -> str:
    """**The price base pin.** The hailed fleet's ``dest_port_id`` port (its
    destination — deterministic); the player's nearest known port
    (tile-space Chebyshev from the player tile, port id ascending on ties)
    when the fleet has none; ``""`` when no port resolves at all."""
    dest = str(fleet.get("dest_port_id", ""))
    if dest and store.get_port(dest):
        return dest
    if not isinstance(pos, dict) or not pos:
        return ""
    here_x = int(pos.get("x", 0))
    here_y = int(pos.get("y", 0))
    ids = sorted(str(value) for value in (known_ports or []))
    best_id = ""
    best_dist = -1
    for port_id in ids:
        port = store.get_port(port_id)
        if not port:
            continue
        px, py = _port_tile(port)
        dist = max(abs(here_x - px), abs(here_y - py))
        if best_dist < 0 or dist < best_dist:
            # ids pre-sorted → ties keep the lower id
            best_dist = dist
            best_id = port_id
    return best_id


def negotiation_discount_points(st: PersonState, store: DataStore) -> int:
    """``min(floor(effective_negotiation / 10), 5)`` — the cap is the
    negotiation formula's own reach (50-* §4.3.1)."""
    value = skills.effective_skill(st, store, "negotiation")
    return min(value // NEGOTIATION_DIVISOR, NEGOTIATION_CAP_POINTS)


def _supply_price_units(stance: int) -> int:
    """The folded per-thousand price units for a hail purchase at
    ``stance``: ×1.5 (1500), ×1.875 (1875) at stance ≥ +3 — the stance
    term folded before the negotiation term so the whole product floors
    exactly once."""
    units = SUPPLY_MULT_UNITS
    if stance >= SUPPLY_WARM_STANCE:
        units = units * SUPPLY_WARM_MULT_UNITS // 1000
    return units


def supply_unit_price(store: DataStore, st: PersonState,
                      captain_states: dict[str, Any], pos: dict[str, Any],
                      known_ports: list[Any], fleet: dict[str, Any],
                      kind: str) -> int:
    """Per-unit supply price of ``kind`` ("provisions" | "water") at the
    hail's price base port, floored once and floored at 1g (30-* §4.2)."""
    base = _supply_base_price(
        price_base_port(store, pos, known_ports, fleet), kind)
    units = _supply_price_units(stance_of(captain_states, fleet)) \
        * (1000 - negotiation_discount_points(st, store) * 10)
    return max(trade.MIN_PRICE, base * units // 1000000)


def supplies_unit_prices(store: DataStore, st: PersonState,
                         captain_states: dict[str, Any], pos: dict[str, Any],
                         known_ports: list[Any],
                         fleet: dict[str, Any]) -> dict[str, int]:
    """Both unit prices, ``{provisions: n, water: m}``."""
    return {
        "provisions": supply_unit_price(store, st, captain_states, pos,
                                        known_ports, fleet, "provisions"),
        "water": supply_unit_price(store, st, captain_states, pos,
                                   known_ports, fleet, "water"),
    }


def supplies_pair_cost(store: DataStore, st: PersonState,
                       captain_states: dict[str, Any], pos: dict[str, Any],
                       known_ports: list[Any], fleet: dict[str, Any],
                       qty: int) -> int:
    """The full charge for a ``qty`` bundle (``qty`` provisions + ``qty``
    water): each kind's total is floored once on its own full product,
    never per unit (30-* §4.2 floor discipline — the ×1.25 stance term is
    observable in the totals even where the unit floor hides it)."""
    units = _supply_price_units(stance_of(captain_states, fleet)) \
        * (1000 - negotiation_discount_points(st, store) * 10)
    total = 0
    for kind in ("provisions", "water"):
        base = _supply_base_price(
            price_base_port(store, pos, known_ports, fleet), kind)
        total += max(trade.MIN_PRICE, int(qty) * base * units // 1000000)
    return total


def _supply_base_price(port_id: str, kind: str) -> int:
    """The supply BASE price — :func:`trade.supplies_price`, the same
    plumbing the market uses. The port is validated, never priced:
    supplies ignore every port factor by design (30-* §4.2), so the
    resolved base port pins the seam (and keeps the nearest-known
    fallback deterministic) rather than moving the number. (The oracle
    pushes an error for an unresolvable port id; here the resolution
    guarantee lives in :func:`price_base_port`, which never returns an
    id the store cannot resolve.)"""
    return trade.supplies_price(kind)


def supplies_max_qty(store: DataStore, st: PersonState,
                     captain_states: dict[str, Any], pos: dict[str, Any],
                     known_ports: list[Any], fleet: dict[str, Any],
                     player_fleet: list[Any]) -> int:
    """The stepper ceiling: the largest bundle the purse can pay **and**
    the hold can carry (2 × qty cargo units — provisions and water each
    occupy 1 unit, 20-* §4.10)."""
    one = supplies_pair_cost(store, st, captain_states, pos, known_ports,
                             fleet, 1)
    if one <= 0:
        return 0
    affordable = int(st.gold) // one
    free = fleet_lib.fleet_free(player_fleet)
    return max(0, min(affordable, free // 2))


# --- Strength pricing (docs/60-* §4.11.5 card formulas) ----------------------

def equipment_item_modifier(store: DataStore, equipment_id: str,
                            stat: str) -> int:
    """A ``combat``/``speed``/``durability`` modifier of one equipment id,
    0 for an empty/unknown id (60-* §4.11.12 "missing keys read as empty
    slots"). The combat port owns the canonical helper; duplicated
    verbatim (with its doc pin) until it lands."""
    if not equipment_id:
        return 0
    item = store.get_equipment(equipment_id)
    if not item:
        return 0
    modifiers = item.get("modifiers", {})
    if not isinstance(modifiers, dict):
        return 0
    return int(modifiers.get(stat, 0))


def player_duel_base(store: DataStore, st: PersonState) -> int:
    """§4.11.6 player base: effective swordplay + ``floor(courage / 20)`` +
    the sum of ``combat`` modifiers on the worn weapon/armor equipment
    (60-* §4.11.12). The combat port owns the canonical form."""
    base = skills.effective_skill(st, store, "swordplay") \
        + int(math.floor(float(character.attribute(st, "courage"))
                         / float(DUEL_COURAGE_DIVISOR)))
    equipment = st.player.get("equipment", {})
    if isinstance(equipment, dict):
        for slot in ("weapon", "armor"):
            base += equipment_item_modifier(
                store, str(equipment.get(slot, "")), "combat")
    return base


def card_duel_rating(card: dict[str, Any]) -> int:
    """§4.11.5 card duel rating: ``swordplay + floor(courage / 20)``. The
    combat port owns the canonical form."""
    card_skills = card.get("skills", {})
    attributes = card.get("attributes", {})
    card_skills = card_skills if isinstance(card_skills, dict) else {}
    attributes = attributes if isinstance(attributes, dict) else {}
    return int(card_skills.get("swordplay", 0)) + int(math.floor(
        float(int(attributes.get("courage", 0)))
        / float(DUEL_COURAGE_DIVISOR)))


def player_strength(store: DataStore, st: PersonState,
                    player_fleet: list[Any]) -> int:
    """The player's priced strength: flagship duel base + Σ escort
    captains' card duel ratings. Escort captain = the officer in the
    ``captain`` post whose ``ship_id`` matches the escort's
    ``ship_type_id`` (ship identity, 20-* §4.4). Captain-less escorts add
    0 (the §4.11.5 escort branch)."""
    ours = player_duel_base(store, st)
    captained: dict[str, int] = {}
    for officer_id, officer_state in st.officer_states.items():
        if not isinstance(officer_state, dict):
            continue
        if str(officer_state.get("post_id", "")) != "captain":
            continue
        ship_id = str(officer_state.get("ship_id", ""))
        if not ship_id:
            continue
        officer = store.get_officer(str(officer_id))
        if not officer:
            continue
        captained[ship_id] = card_duel_rating(officer)
    for ship in list(player_fleet)[1:]:
        if not isinstance(ship, dict):
            continue
        ship_id = str(ship.get("ship_type_id", ""))
        ours += int(captained.get(ship_id, 0))
    return ours


def target_strength(store: DataStore, fleet: dict[str, Any]) -> int:
    """The target fleet's priced strength: its captain card duel rating
    (``swordplay + floor(courage/20)``, §4.11.5); 0 without a card."""
    return card_duel_rating(captain_card_of(store, fleet))


def _clampf(value: float, low: float, high: float) -> float:
    return low if value < low else high if value > high else value


def intimidate_chance(store: DataStore, st: PersonState,
                      captain_states: dict[str, Any],
                      player_fleet: list[Any],
                      fleet: dict[str, Any]) -> float:
    """The intimidate success chance (60-* §4.11.15):
    ``clamp(ours/(ours+theirs) + floor(COU/200) − max(0,−stance)×0.05,
    .05, .95)``."""
    ours = float(player_strength(store, st, player_fleet))
    theirs = float(target_strength(store, fleet))
    total = ours + theirs
    share = ours / total if total > 0.0 else 0.0
    courage_term = math.floor(
        float(character.attribute(st, "courage")) / COURAGE_DIVISOR)
    stance = stance_of(captain_states, fleet)
    penalty = max(0.0, float(-stance)) * STANCE_PENALTY_PER_POINT
    return _clampf(share + courage_term - penalty,
                   INTIMIDATE_P_MIN, INTIMIDATE_P_MAX)


# --- The roll (docs/60-* §4.11.1 seed formula, reused at the fleet's tile) ---

def roll_seed(day: int, gold: int, fleet_size: int,
              fleet: dict[str, Any]) -> int:
    """The hail roll's seed: the §4.11.1 battle seed formula over (day, the
    fleet's tile, gold, fleet size) — a closed form, so the client's draw
    is reproducible and the tests can predict it without touching RNG
    state."""
    cell = _cell_of(fleet)
    x = int(cell.get("x", 0))
    y = int(cell.get("y", 0))
    return (int(day) * SEED_DAY_MULT + x * SEED_X_MULT + y * SEED_Y_MULT
            + int(gold) * SEED_GOLD_MULT + int(fleet_size) * SEED_FLEET_MULT)


def draw_roll(day: int, gold: int, fleet_size: int,
              fleet: dict[str, Any]) -> float:
    """One draw from the seeded stream above, ∈ [0, 1) — the bit-exact
    Godot stream (:class:`~server.sim.rng.GodotRng`)."""
    rng = GodotRng(seed=roll_seed(day, gold, fleet_size, fleet))
    return rng.randf()


# --- Option builder ----------------------------------------------------------

def _run_pos(run: dict[str, Any]) -> dict[str, Any]:
    world = run.get("world", {})
    world = world if isinstance(world, dict) else {}
    pos = world.get("position", {})
    return pos if isinstance(pos, dict) else {}


def options_for(store: DataStore, st: PersonState, run: dict[str, Any],
                fleet: dict[str, Any]) -> list[dict[str, Any]]:
    """The talk options for ``fleet``, in render order: rumours, supplies
    (trader/coaster only), intimidate, befriend. Out-of-range hails build
    NOTHING (the talk verb guarantees Chebyshev ≤ 2 — defended here)."""
    out: list[dict[str, Any]] = []
    pos = _run_pos(run)
    if not in_range(pos, fleet):
        return out
    captain_states = run.get("captain_states", {})
    known_ports = list(run.get("known_ports", []))
    player_fleet = list(run.get("fleet", []))
    stance = stance_of(captain_states, fleet)

    # Ask rumours — always enabled; stance ≥ +2 grants one free intel.
    out.append({
        "id": OPTION_RUMOURS,
        "enabled": True,
        "intel": stance >= INTEL_STANCE,
    })

    # Buy supplies — trader/coaster captains only.
    role = str(fleet.get("role", ""))
    if role in SUPPLY_ROLES:
        prices = supplies_unit_prices(store, st, captain_states, pos,
                                      known_ports, fleet)
        out.append({
            "id": OPTION_SUPPLIES,
            "enabled": True,
            "unit_prices": prices,
            "max_qty": supplies_max_qty(store, st, captain_states, pos,
                                        known_ports, fleet, player_fleet),
        })

    # Intimidate — every role (a coaster's ONLY hostile verb).
    out.append({
        "id": OPTION_INTIMIDATE,
        "enabled": True,
        "chance": intimidate_chance(store, st, captain_states,
                                    player_fleet, fleet),
    })

    # Befriend — once per captain per day.
    captain_id = str(fleet.get("captain_id", ""))
    befriended = befriended_on(captain_id, int(st.day))
    befriend: dict[str, Any] = {
        "id": OPTION_BEFRIEND,
        "enabled": not befriended,
    }
    if befriended:
        befriend["reason_key"] = "hail.befriend.used"
    out.append(befriend)
    return out


# --- The resolve funnel ------------------------------------------------------

def resolve(store: DataStore, st: PersonState, run: dict[str, Any],
            option_id: str, fleet: dict[str, Any], qty: int = 0,
            roll: float = -1.0) -> dict[str, Any]:
    """Applies one hail option and returns the render/apply payload (see
    the module docstring for the shape). ``qty`` is the supplies bundle
    size; ``roll ∈ [0,1)`` decides an intimidate attempt verbatim (the
    default ``-1.0`` draws from the seeded stream). Unknown options and
    out-of-range hails resolve ``{ok: False}`` with empty lines — nothing
    is applied."""
    if not in_range(_run_pos(run), fleet):
        return {"ok": False, "lines": []}
    captain_states = run.get("captain_states", {})
    if option_id == OPTION_RUMOURS:
        return _resolve_rumours(store, captain_states, fleet)
    if option_id == OPTION_SUPPLIES:
        return _resolve_supplies(store, st, run, fleet, qty)
    if option_id == OPTION_INTIMIDATE:
        return _resolve_intimidate(store, st, run, fleet, roll)
    if option_id == OPTION_BEFRIEND:
        return _resolve_befriend(store, st, captain_states, fleet)
    return {"ok": False, "lines": []}


def _resolve_rumours(store: DataStore, captain_states: dict[str, Any],
                     fleet: dict[str, Any]) -> dict[str, Any]:
    """Ask rumours — free. Stance ≥ +2 appends one free route/market intel:
    the fleet's current lane/dest hint, built from ``dest_port_id`` /
    route lanes (no RNG)."""
    name = display_name(store, fleet)
    lines: list[dict[str, Any]] = [
        {"key": "hail.rumours.result", "values": {"name": name}}]
    out: dict[str, Any] = {"ok": True, "lines": lines}
    if stance_of(captain_states, fleet) >= INTEL_STANCE:
        lines.append({
            "key": "hail.rumours.result_intel",
            "values": {"name": name},
        })
        out["intel"] = _intel_payload(fleet)
    return out


def _intel_payload(fleet: dict[str, Any]) -> dict[str, Any]:
    """The intel payload: the fleet's destination port and its current
    route lanes (read-only seam — what the captain's table points at)."""
    route = fleet.get("route", {})
    route = route if isinstance(route, dict) else {}
    raw_lanes = route.get("lanes", [])
    raw_lanes = raw_lanes if isinstance(raw_lanes, list) else []
    return {
        "dest_port_id": str(fleet.get("dest_port_id", "")),
        "lanes": [str(lane) for lane in raw_lanes],
    }


def _resolve_supplies(store: DataStore, st: PersonState, run: dict[str, Any],
                      fleet: dict[str, Any], qty: int) -> dict[str, Any]:
    """Buy supplies — ``qty`` provisions + ``qty`` water at the hail
    prices. Refused (nothing applied) for a non-positive bundle, a short
    purse or a full hold; the client caps the stepper at
    :func:`supplies_max_qty` up front."""
    if qty <= 0:
        return {"ok": False, "lines": []}
    captain_states = run.get("captain_states", {})
    pos = _run_pos(run)
    known_ports = list(run.get("known_ports", []))
    player_fleet = list(run.get("fleet", []))
    cost = supplies_pair_cost(store, st, captain_states, pos, known_ports,
                              fleet, qty)
    if cost > st.gold or 2 * qty > fleet_lib.fleet_free(player_fleet):
        return {"ok": False, "lines": []}
    st.gold -= cost
    gained = {
        "provisions": fleet_lib.add_supplies(player_fleet, "provisions", qty),
        "water": fleet_lib.add_supplies(player_fleet, "water", qty),
    }
    # (the oracle's FleetLib.notify_changed — the caller's WS event frame)
    return {
        "ok": True,
        "lines": [{
            "key": "hail.supplies.result",
            "values": {"qty": qty},
        }],
        "gold_delta": -cost,
        "cargo_gained": gained,
    }


def _resolve_intimidate(store: DataStore, st: PersonState,
                        run: dict[str, Any], fleet: dict[str, Any],
                        roll: float) -> dict[str, Any]:
    """Intimidate. ``roll ∈ [0,1)`` decides verbatim (the default ``-1.0``
    draws from the seeded stream, :func:`draw_roll`). SUCCESS: the target
    hands over half its cargo (floor per good) — routed goods through the
    fleet hold, supplies keys through the supplies pools — pirate fame +5,
    stance −1. FAILURE: ``made_hostile`` (the caller opens the §4.11.11.2
    battle) and stance −2; nothing moves."""
    captain_states = run.get("captain_states", {})
    player_fleet = list(run.get("fleet", []))
    chance = intimidate_chance(store, st, captain_states, player_fleet, fleet)
    draw = roll if (roll >= 0.0 and roll < 1.0) else \
        draw_roll(int(st.day), int(st.gold), len(player_fleet), fleet)
    if draw >= chance:
        # An executed outcome, not a refusal — `ok` stays true and
        # `made_hostile` tells the caller to open the battle.
        stance = _apply_stance(captain_states, store, fleet,
                               captains.STANCE_INTIMIDATE_FAIL)
        return {
            "ok": True,
            "lines": [{
                "key": "hail.intimidate.lose",
                "values": {"name": display_name(store, fleet)},
            }],
            "made_hostile": True,
            "stance_delta": stance,
            "chance": chance,
        }
    gained = _take_half_cargo(fleet, player_fleet)
    fame_before = fame.value(st)
    fame.add(st, INTIMIDATE_FAME)
    fame_delta = fame.value(st) - fame_before
    stance = _apply_stance(captain_states, store, fleet,
                           captains.STANCE_INTIMIDATE_WIN)
    return {
        "ok": True,
        "lines": [{
            "key": "hail.intimidate.win",
            "values": {"name": display_name(store, fleet)},
        }],
        "cargo_gained": gained,
        "fame_delta": fame_delta,
        "stance_delta": stance,
        "chance": chance,
    }


def _take_half_cargo(fleet: dict[str, Any],
                     player_fleet: list[Any]) -> dict[str, Any]:
    """Half the target's cargo, floor per good (60-* §4.11.15). The
    handed-over goods leave the target dict and enter the player's fleet
    up to free capacity; the return reports what actually moved.
    Provisions/water keys route through the supplies pools (they are not
    trade goods)."""
    cargo = fleet.get("cargo", {})
    cargo = cargo if isinstance(cargo, dict) else {}
    gained: dict[str, Any] = {}
    for good_id in list(cargo.keys()):
        good_id = str(good_id)
        held = int(cargo[good_id])
        if held <= 0:
            continue
        half = held // INTIMIDATE_CARGO_SHARE  # floor per good
        if half <= 0:
            continue
        if good_id in fleet_lib.SUPPLY_KINDS:
            stored = fleet_lib.add_supplies(player_fleet, good_id, half)
        else:
            stored = fleet_lib.add_goods(player_fleet, good_id, half)
        if stored <= 0:
            continue
        cargo[good_id] = held - stored
        gained[good_id] = stored
    # (the oracle's FleetLib.notify_changed — the caller's WS event frame)
    return gained


def _resolve_befriend(store: DataStore, st: PersonState,
                      captain_states: dict[str, Any],
                      fleet: dict[str, Any]) -> dict[str, Any]:
    """Befriend — stance +1, once per captain per day (the session map). A
    repeat on the same day resolves ``{ok: False}`` with the used reason
    and applies nothing."""
    captain_id = str(fleet.get("captain_id", ""))
    day = int(st.day)
    if befriended_on(captain_id, day):
        return {
            "ok": False,
            "lines": [{"key": "hail.befriend.used", "values": {}}],
        }
    _BEFRIENDED_TODAY[captain_id] = day
    stance = _apply_stance(captain_states, store, fleet,
                           captains.STANCE_BEFRIEND)
    return {
        "ok": True,
        "lines": [{
            "key": "hail.befriend.result",
            "values": {"name": display_name(store, fleet)},
        }],
        "stance_delta": stance,
    }


def _apply_stance(captain_states: dict[str, Any], store: DataStore,
                  fleet: dict[str, Any], delta: int) -> int:
    """Applies a stance delta through ``captains.adjust_stance`` (the
    shared constants' funnel) when the fleet carries a captain id; an
    id-less fixture skips the state write and reports the raw delta."""
    captain_id = str(fleet.get("captain_id", ""))
    if not captain_id:
        return delta
    return captains.adjust_stance(captain_states, store, captain_id, delta)
