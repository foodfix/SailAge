"""server.sim.quests.quest_gen — guild quest offers, tracking and payouts (M1).

Python port of ``scripts/quests/quest_gen.gd`` (the frozen parity oracle
until the M6 cutover). Normative contract:
docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.2 (guild quests), §4.9.3 (the
generation pins: template set, seed formula, draw order, every
completion/failure number), §4.9.2 (the viscount quest slot);
docs/90-ARCHITECTURE.md §0/§4 (pure logic, no scene code).

**Offers are derived, never saved** (§4.9.3): the 3 offers of a guild are
a pure function of ``(port id, day // 7)``, so save/load cannot
desynchronise them and a reload offers exactly what the player saw.

**One seed, one draw order** (§4.9.3) — every draw below consumes the
:class:`~server.sim.rng.GodotRng` stream in the documented order, so a
test (and the M5 golden traces) can reproduce any offer list exactly:

  1. slot 0 is always a delivery template, picked uniformly;
  2. the type of slots 1 and 2 each: ``randf() < 0.5`` → delivery,
     ``< 0.8`` → bounty, else exploration;
  3. per slot, the type's own draws (template index → quantity →
     destination band pick for a delivery; tier for a bounty; candidate
     pick for an exploration; an exploration that finds no candidates
     degenerates to a delivery *without consuming its draw* — the empty
     set is detected before the pick).

State convention: the GDScript statics read/mutate the ``GameState``
singleton — here :class:`~server.sim.quests.QuestState` carries the
quest-layer run fields (``active_quests``, ``discoveries_found``,
``npc_fleets``) and the :class:`~server.sim.player.PersonState` carries
gold/day/the player block (reputation)/fame/titles. The fleet hold is an
injected ``list`` (the fleet module's convention); map positions arrive
through the injected :class:`~server.sim.quests.WorldView`; content
lookups (ports, goods, quest templates, discoveries) read
:mod:`server.sim.data` exactly where the GDScript reads ``DataLoader``.
EventBus announcements are the caller's WS frames — every function
returns its delta instead.

Deferred seams (NOT ported here, with the GDScript entry point):
  * ``_spawn_bounty_target`` — the Phase-5 ``NpcFleets.spawn`` quest seam
    plus the §4.11.11.4 named-pirate preference (``60-*`` §4.12.3). The
    ecology module is another M1 wave; :func:`accept` takes the
    ``spawn_target(quest, day) -> fleet_id`` callable instead (the
    GDScript's ``ResourceLoader.exists`` guard becomes ``None`` → no
    target materialises, exactly the no-module path).
  * ``NpcFleets.is_named_captain``/``captain_name`` (the §4.11.11.4
    bounty-line read) fold into the one ``captain_name_of(marker) ->
    str`` callable of :func:`objective_text` — ``""`` is both "not a
    named captain" and "no resolvable name", which lands on the generic
    label either way (identical behaviour, one seam).
  * the presentation I18n autoload — :func:`objective_text` takes the
    ``i18n`` view (``t``/``t_key``/``fmt``) the caller wires to
    ``DataStore.ui_strings`` + the request locale (``90-*`` §0.3).

RNG seams (the only ``rand*`` consumers of the quest layer): the offer
seed formula and the per-slot draws above, all through the bit-exact
:class:`~server.sim.rng.GodotRng` port.
"""

from __future__ import annotations

import copy
import math
from typing import TYPE_CHECKING, Any, Callable, Final

from server.sim.data import data
from server.sim.player import character as character_lib
from server.sim.player import fame as fame_lib
from server.sim.quests import QuestState, WorldView
from server.sim.rng import GodotRng
from server.sim.world.raster import tile_of_latlon

if TYPE_CHECKING:
    from server.sim.player import PersonState

__all__ = [
    "OFFERS_PER_GUILD",
    "OFFER_WEEK",
    "SEED_WEEK_MULT",
    "SEED_PORT_MULT",
    "MAX_ACTIVE_QUESTS",
    "VISCOUNT_EXTRA_SLOT",
    "DELIVERY_QTY_BASE",
    "DELIVERY_QTY_STEP",
    "DELIVERY_QTY_TIERS",
    "DELIVERY_DIST_MIN",
    "DELIVERY_DIST_MAX",
    "DELIVERY_DIST_MIN_WIDE",
    "DELIVERY_DIST_MAX_WIDE",
    "DELIVERY_EXPIRY_DIVISOR",
    "DELIVERY_EXPIRY_PAD",
    "DELIVERY_EXPIRY_MIN",
    "DELIVERY_EXPIRY_MAX",
    "DELIVERY_GOLD_FACTOR",
    "DELIVERY_REP",
    "DELIVERY_FAME",
    "BOUNTY_FAME",
    "EXPLORATION_REP",
    "EXPLORATION_FAME",
    "BOUNTY_EXPIRY_DAYS",
    "BOUNTY_GOLD_BY_TIER",
    "BOUNTY_TIER_MIN",
    "BOUNTY_TIER_MAX",
    "EXPLORATION_RADIUS",
    "EXPLORATION_EXPIRY_DAYS",
    "TYPE_DELIVERY_UNTIL",
    "TYPE_BOUNTY_UNTIL",
    "FAIL_REPUTATION",
    "TYPE_DELIVERY",
    "TYPE_BOUNTY",
    "TYPE_EXPLORATION",
    "TYPE_ROYAL",
    "STATUS_ACTIVE",
    "STATUS_COMPLETED",
    "STATUS_FAILED",
    "INSTANCE_PREFIX",
    "offer_seed",
    "port_ordinal",
    "week_of",
    "next_refresh_day",
    "offers",
    "available_offers",
    "max_active_quests",
    "active_count",
    "accept_block_reason",
    "accept",
    "completable_deliveries",
    "complete_delivery_quests",
    "complete_exploration_quests",
    "complete_bounty_quests",
    "fail",
    "is_expired",
    "delivery_cargo_lost",
    "tick",
    "prune",
    "active_quests",
    "abandon",
    "objective_text",
    "type_key",
    "find",
]

# A bounty-target spawner, standing in for the GDScript
# ``_spawn_bounty_target`` (the callable receives the quest instance and
# the day, may re-price the instance's tier/gold on the §4.11.11.4
# named-pirate preference, tags the marker in ``QuestState.npc_fleets``,
# and returns the fleet id or "").
SpawnTarget = Callable[[dict[str, Any], int], str]

# The presentation I18n seam (``autoload/i18n.gd``'s ``t``/``t_key``/
# ``fmt``); the concrete adapter over ``DataStore.ui_strings`` is the
# caller's — locale state belongs to the request in the web era.
I18nView = Any

# The §4.11.11.4 named-pirate captain-name read (see the module docstring).
CaptainNameOf = Callable[[dict[str, Any]], str]


# --- §4.9.3 pinned numbers ------------------------------------------------

## Offers per guild (§4.2 "lists 3 quests").
OFFERS_PER_GUILD: Final[int] = 3
## Refresh cadence: ``day // OFFER_WEEK``.
OFFER_WEEK: Final[int] = 7
## Seed formula, the same family as ``60-*`` §4.11.1 (``day`` term + ordinal).
SEED_WEEK_MULT: Final[int] = 1000003
SEED_PORT_MULT: Final[int] = 7919
## Base active-quest slots (§4.2 "max 3"), +1 at viscount (§4.9.2).
MAX_ACTIVE_QUESTS: Final[int] = 3
VISCOUNT_EXTRA_SLOT: Final[int] = 1
## Delivery draw bands (§4.9.3).
DELIVERY_QTY_BASE: Final[int] = 20
DELIVERY_QTY_STEP: Final[int] = 10
DELIVERY_QTY_TIERS: Final[int] = 4          # 20 / 30 / 40 / 50
DELIVERY_DIST_MIN: Final[int] = 6
DELIVERY_DIST_MAX: Final[int] = 30
DELIVERY_DIST_MIN_WIDE: Final[int] = 3
DELIVERY_DIST_MAX_WIDE: Final[int] = 60
DELIVERY_EXPIRY_DIVISOR: Final[int] = 4
DELIVERY_EXPIRY_PAD: Final[int] = 5
DELIVERY_EXPIRY_MIN: Final[int] = 7
DELIVERY_EXPIRY_MAX: Final[int] = 30
## Reward bands (§4.2/§4.9.3).
DELIVERY_GOLD_FACTOR: Final[int] = 2
DELIVERY_REP: Final[int] = 5
DELIVERY_FAME: Final[int] = 10
BOUNTY_FAME: Final[int] = 15
EXPLORATION_REP: Final[int] = 5
EXPLORATION_FAME: Final[int] = 10
BOUNTY_EXPIRY_DAYS: Final[int] = 30
BOUNTY_GOLD_BY_TIER: Final[dict[int, int]] = {1: 5000, 2: 10000, 3: 20000}
BOUNTY_TIER_MIN: Final[int] = 1
BOUNTY_TIER_MAX: Final[int] = 3
## §4.9.3 exploration draw radius (Phase-6 grid sweep: 40 → 80 with the
## tile grid, preserving the geographic reach).
EXPLORATION_RADIUS: Final[int] = 80
## §4.9.3 exploration expiry.
EXPLORATION_EXPIRY_DAYS: Final[int] = 30
## Offer-type roll bands for slots 1 and 2 (§4.9.3 step 2).
TYPE_DELIVERY_UNTIL: Final[float] = 0.5
TYPE_BOUNTY_UNTIL: Final[float] = 0.8
## Failure delta (§4.2 "Fail … −5 rep").
FAIL_REPUTATION: Final[int] = -5

## Offer/quest type ids (`10-*` §4.8).
TYPE_DELIVERY: Final[str] = "delivery"
TYPE_BOUNTY: Final[str] = "bounty"
TYPE_EXPLORATION: Final[str] = "exploration"
TYPE_ROYAL: Final[str] = "royal"
## Lifecycle statuses on a stored instance.
STATUS_ACTIVE: Final[str] = "active"
STATUS_COMPLETED: Final[str] = "completed"
STATUS_FAILED: Final[str] = "failed"

## Quest instance id prefix: ``q_<origin port>_<week>_<slot>``.
INSTANCE_PREFIX: Final[str] = "q_"

## The destination draw bands, in §4.9.3 order: the pinned
## different-nation band, then the nation filter dropped, then the band
## widened.
_DESTINATION_BANDS: Final[tuple[tuple[int, int, bool], ...]] = (
    (DELIVERY_DIST_MIN, DELIVERY_DIST_MAX, True),
    (DELIVERY_DIST_MIN, DELIVERY_DIST_MAX, False),
    (DELIVERY_DIST_MIN_WIDE, DELIVERY_DIST_MAX_WIDE, False),
)


# --- Offers (docs/70-* §4.9.3) -------------------------------------------

def offer_seed(port_id: str, day: int) -> int:
    """The deterministic seed of a guild's offer list: ``(day // 7) ×
    1000003 + port_ordinal × 7919``, ``port_ordinal`` being the 0-based
    index of the port id in the **ascending id order** (map-independent,
    so the same port always seeds the same list)."""
    return (day // OFFER_WEEK) * SEED_WEEK_MULT \
        + port_ordinal(port_id) * SEED_PORT_MULT


def port_ordinal(port_id: str) -> int:
    """The 0-based position of ``port_id`` among all sorted port ids (−1
    when unknown — the GDScript ``Array.find`` result)."""
    ids = sorted(data().ports.keys())
    try:
        return ids.index(port_id)
    except ValueError:
        return -1


def week_of(day: int) -> int:
    """The week number a day falls in (``day // 7``)."""
    return day // OFFER_WEEK


def next_refresh_day(day: int) -> int:
    """The first day of the **next** offer refresh after ``day`` (§4.2
    "refreshes every 7 in-game days"), for the guild header line."""
    return (week_of(day) + 1) * OFFER_WEEK


def offers(port_id: str, day: int, world: WorldView,
           found: list[Any] | tuple[Any, ...] | set[str] = ()) \
        -> list[dict[str, Any]]:
    """The 3 offers at ``port_id`` on ``day``, as quest **instances** (not
    yet accepted): ``{instance_id, template_id, type, giver,
    origin_port_id, requirements, rewards, expiry_days, status}``.
    Deterministic per ``(port, day // 7)`` — see :func:`offer_seed`.

    ``found`` is the run's found-discovery ids (the GDScript reads
    ``GameState.discoveries_found`` here; the caller passes
    ``qs.discoveries_found``). It only ever sways exploration slots, so a
    caller that has not started discovering may omit it."""
    store = data()
    port = store.get_port(port_id)
    if not port:
        return []
    rng = GodotRng(seed=offer_seed(port_id, day))
    week = week_of(day)
    found_ids = {str(entry) for entry in found}
    out: list[dict[str, Any]] = []
    for slot in range(OFFERS_PER_GUILD):
        type_id = TYPE_DELIVERY
        if slot > 0:
            roll = rng.randf()
            if roll < TYPE_DELIVERY_UNTIL:
                type_id = TYPE_DELIVERY
            elif roll < TYPE_BOUNTY_UNTIL:
                type_id = TYPE_BOUNTY
            else:
                type_id = TYPE_EXPLORATION
        offer = _make_offer(store, port_id, type_id, slot, week, day, rng,
                            world, found_ids)
        if offer:
            out.append(offer)
    return out


def available_offers(qs: QuestState, port_id: str, day: int,
                     world: WorldView) -> list[dict[str, Any]]:
    """The offers that are not already accepted: the guild screen's list,
    with accepted instances filtered out so an offer cannot be taken
    twice (the instance id is derived, not random)."""
    taken = {str(quest.get("instance_id", ""))
             for quest in qs.active_quests if isinstance(quest, dict)}
    out: list[dict[str, Any]] = []
    for offer in offers(port_id, day, world, qs.discoveries_found):
        if str(offer.get("instance_id", "")) in taken:
            continue
        out.append(offer)
    return out


def _make_offer(store: Any, port_id: str, type_id: str, slot: int,
                week: int, day: int, rng: GodotRng, world: WorldView,
                found_ids: set[str]) -> dict[str, Any]:
    """One offer, by type. Draws the type's own numbers from ``rng`` in
    the §4.9.3 order; ``{}`` only when the type cannot be offered at all
    (an exploration with no unfound discovery in range degenerates to a
    delivery, never to ``{}`)."""
    instance_id = f"{INSTANCE_PREFIX}{port_id}_{week}_{slot}"
    if type_id == TYPE_BOUNTY:
        return _bounty_offer(instance_id, port_id, rng)
    if type_id == TYPE_EXPLORATION:
        exploration = _exploration_offer(instance_id, port_id, rng, world,
                                         found_ids)
        if exploration:
            return exploration
        # §4.9.3: an impossible exploration degenerates to a delivery.
        return _delivery_offer(instance_id, port_id, rng, world)
    return _delivery_offer(instance_id, port_id, rng, world)


def _delivery_offer(instance_id: str, port_id: str, rng: GodotRng,
                    world: WorldView) -> dict[str, Any]:
    store = data()
    templates = _templates_of_type(store, TYPE_DELIVERY)
    if not templates:
        return {}
    template = templates[rng.randi_range(0, len(templates) - 1)]
    good_id = str(template.get("requirements", {}).get("good_id", ""))
    quantity = DELIVERY_QTY_BASE \
        + DELIVERY_QTY_STEP * rng.randi_range(0, DELIVERY_QTY_TIERS - 1)
    dest = _pick_destination(port_id, rng, world)
    if not dest:
        return {}
    dest_port = store.get_port(str(dest["id"]))
    nation_id = str(dest_port.get("nation_id", ""))
    base_price = int(store.get_good(good_id).get("base_price", 0))
    return {
        "instance_id": instance_id,
        "template_id": str(template.get("id", "")),
        "type": TYPE_DELIVERY,
        "giver": "guild",
        "origin_port_id": port_id,
        "requirements": {
            "good_id": good_id,
            "quantity": quantity,
            "dest_port_id": str(dest["id"]),
        },
        "rewards": {
            "gold": DELIVERY_GOLD_FACTOR * base_price * quantity,
            "reputation": {nation_id: DELIVERY_REP},
            "fame": DELIVERY_FAME,
        },
        "expiry_days": int(dest["expiry"]),
        "status": STATUS_ACTIVE,
    }


def _bounty_offer(instance_id: str, port_id: str, rng: GodotRng) \
        -> dict[str, Any]:
    store = data()
    template = _first_template(store, TYPE_BOUNTY)
    if not template:
        return {}
    tier = rng.randi_range(BOUNTY_TIER_MIN, BOUNTY_TIER_MAX)
    return {
        "instance_id": instance_id,
        "template_id": str(template.get("id", "")),
        "type": TYPE_BOUNTY,
        "giver": "guild",
        "origin_port_id": port_id,
        "requirements": {
            # The fleet is spawned on acceptance, so the id is only known
            # then; the offer carries the tier it will be built from.
            "tier": tier,
            "target_fleet_id": "",
        },
        "rewards": {
            "gold": int(BOUNTY_GOLD_BY_TIER.get(tier, 5000)),
            "reputation": {},
            "fame": BOUNTY_FAME,
        },
        "expiry_days": BOUNTY_EXPIRY_DAYS,
        "status": STATUS_ACTIVE,
    }


def _exploration_offer(instance_id: str, port_id: str, rng: GodotRng,
                       world: WorldView, found_ids: set[str]) \
        -> dict[str, Any]:
    store = data()
    template = _first_template(store, TYPE_EXPLORATION)
    if not template:
        return {}
    # §4.9.3 draw band, Phase-6 grid sweep: gameplay radius doubles with
    # the tile grid (40 → 80) so the geographic reach is unchanged.
    candidates = _hint_candidates(store, found_ids, port_id,
                                  EXPLORATION_RADIUS, world)
    if not candidates:
        return {}
    discovery_id = str(candidates[rng.randi_range(0, len(candidates) - 1)])
    port = store.get_port(port_id)
    nation_id = str(port.get("nation_id", ""))
    return {
        "instance_id": instance_id,
        "template_id": str(template.get("id", "")),
        "type": TYPE_EXPLORATION,
        "giver": "guild",
        "origin_port_id": port_id,
        "requirements": {"discovery_id": discovery_id},
        "rewards": {
            "gold": 0,
            "reputation": {nation_id: EXPLORATION_REP},
            "fame": EXPLORATION_FAME,
        },
        "expiry_days": EXPLORATION_EXPIRY_DAYS,
        "status": STATUS_ACTIVE,
    }


def _hint_candidates(store: Any, found_ids: set[str], port_id: str,
                     radius: int, world: WorldView) -> list[str]:
    """Discovery ids that are unfound and within Chebyshev ``radius`` of
    ``port_id``'s harbour, sorted ascending (§4.9.3 exploration draw)."""
    port = store.get_port(port_id)
    if not port:
        return []
    origin = _port_cell(port_id, world)
    out: list[str] = []
    for entry in store.discoveries_list:
        discovery_id = str(entry.get("id", ""))
        if discovery_id in found_ids:
            continue
        # A discovery's map cell is derived from its lat/lon with the same
        # floor projection as the grid (10-* §6.1) — the locked world grid
        # (4320×2160) is the only map the legend can name, so the pure
        # helper equals the oracle's legend read.
        cell = tile_of_latlon(float(entry.get("lat", 0.0)),
                              float(entry.get("lon", 0.0)))
        if _chebyshev(origin, cell, world) > radius:
            continue
        out.append(discovery_id)
    out.sort()
    return out


def _templates_of_type(store: Any, type_id: str) -> list[dict[str, Any]]:
    return [entry for entry in store.quests_list
            if entry.get("type") == type_id]


def _first_template(store: Any, type_id: str) -> dict[str, Any]:
    templates = _templates_of_type(store, type_id)
    return templates[0] if templates else {}


def _port_cell(port_id: str, world: WorldView) -> tuple[int, int]:
    """A port's derived berth tile (`10-*` §6.1 snap output, read from
    ``data/maps/harbors.json``), or ``(-1, -1)`` when the map cannot
    answer. Ports carry ``lat``/``lon``, never a stored tile, so this is
    the one runtime source of port positions."""
    return world.port_cell(port_id)


def _chebyshev(a: tuple[int, int], b: tuple[int, int],
               world: WorldView) -> int:
    """Chebyshev distance with longitude wrap (`20-*` §4.1: x taken mod
    the grid width), the same measure the delivery bands were defined in."""
    width = max(int(world.map_width()), 1)
    dx = abs(a[0] - b[0]) % width
    return max(min(dx, width - dx), abs(a[1] - b[1]))


def _pick_destination(port_id: str, rng: GodotRng,
                      world: WorldView) -> dict[str, Any]:
    """A destination draw (§4.9.3): a port on the active map with a
    different nation and a Chebyshev distance in ``[6, 30]``, sorted by
    id; if that set is empty the nation filter is dropped, then the band
    widens to ``[3, 60]``."""
    store = data()
    origin = store.get_port(port_id)
    origin_cell = _port_cell(port_id, world)
    origin_nation = str(origin.get("nation_id", ""))
    for dist_min, dist_max, distinct_nation in _DESTINATION_BANDS:
        candidates = _destination_candidates(store, port_id, origin_cell,
                                             origin_nation, dist_min,
                                             dist_max, distinct_nation,
                                             world)
        if not candidates:
            continue
        return candidates[rng.randi_range(0, len(candidates) - 1)]
    return {}


def _destination_candidates(store: Any, port_id: str,
                            origin_cell: tuple[int, int],
                            origin_nation: str, distance_min: int,
                            distance_max: int, distinct_nation: bool,
                            world: WorldView) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for entry in store.ports_list:
        other_id = str(entry.get("id", ""))
        if other_id == port_id:
            continue
        if distinct_nation \
                and str(entry.get("nation_id", "")) == origin_nation:
            continue
        cell = _port_cell(other_id, world)
        if cell[0] < 0:
            continue
        distance = _chebyshev(origin_cell, cell, world)
        if distance < distance_min or distance > distance_max:
            continue
        out.append({
            "id": other_id,
            "distance": distance,
            "expiry": _clampi(int(math.ceil(float(distance)
                                            / DELIVERY_EXPIRY_DIVISOR))
                              + DELIVERY_EXPIRY_PAD,
                              DELIVERY_EXPIRY_MIN, DELIVERY_EXPIRY_MAX),
        })
    out.sort(key=lambda candidate: str(candidate["id"]))
    return out


# --- Acceptance (docs/70-* §4.9.3) ---------------------------------------

def max_active_quests(st: PersonState) -> int:
    """Max active quests: 3, or 4 while **any** nation's title is viscount
    or higher (`70-*` §4.9.2 — max over nations, not a sum). The extra
    slot is fame.py's ``quest_slots_bonus`` (the ladder's grant table)."""
    return MAX_ACTIVE_QUESTS + fame_lib.quest_slots_bonus(st)


def active_count(qs: QuestState) -> int:
    """Number of quests currently active."""
    count = 0
    for quest in qs.active_quests:
        if isinstance(quest, dict) \
                and str(quest.get("status", STATUS_ACTIVE)) == STATUS_ACTIVE:
            count += 1
    return count


def accept_block_reason(qs: QuestState, st: PersonState,
                        offer: dict[str, Any], fleet: list[Any]) -> str:
    """``""`` when ``offer`` may be accepted, else the ``ui_strings``
    reason key (``quest.slots_full``, ``quest.no_hold``)."""
    from server.sim import fleet as fleet_lib

    if active_count(qs) >= max_active_quests(st):
        return "quest.slots_full"
    if str(offer.get("type", "")) == TYPE_DELIVERY:
        requirements = offer.get("requirements", {})
        if fleet_lib.fleet_free(fleet) < int(requirements.get("quantity", 0)):
            return "quest.no_hold"
    return ""


def accept(offer: dict[str, Any], qs: QuestState, st: PersonState,
           port_id: str, day: int, *, fleet: list[Any],
           spawn_target: SpawnTarget | None = None) -> dict[str, Any]:
    """Accepts ``offer`` at ``port_id`` on ``day``: stores the instance in
    ``active_quests``, moves the delivery goods into the hold free, and
    spawns a bounty target through the injected Phase-5 seam. Returns the
    stored instance (``{}`` on any refusal, state untouched)."""
    from server.sim import fleet as fleet_lib

    if not offer or accept_block_reason(qs, st, offer, fleet):
        return {}
    instance = copy.deepcopy(offer)  # offer.duplicate(true)
    instance["origin_port_id"] = port_id
    instance["accepted_day"] = day
    instance["deadline_day"] = day + int(instance.get("expiry_days", 30))
    instance["status"] = STATUS_ACTIVE
    if str(instance.get("type", "")) == TYPE_DELIVERY:
        requirements = instance["requirements"]
        quantity = int(requirements.get("quantity", 0))
        stored = fleet_lib.add_goods(fleet,
                                     str(requirements.get("good_id", "")),
                                     quantity)
        if stored != quantity:
            if stored > 0:
                fleet_lib.remove_goods(fleet,
                                       str(requirements.get("good_id", "")),
                                       stored)
            return {}
        # EventBus.fleet_changed — the caller's WS frame.
    elif str(instance.get("type", "")) == TYPE_BOUNTY:
        target_id = ""
        if spawn_target is not None:
            target_id = spawn_target(instance, day)
        if target_id:
            instance["requirements"]["target_fleet_id"] = target_id
            # Tag the fleet with its quest so the battle-end hook can match
            # it, and set the tier the reward was priced from (the GDScript
            # `_spawn_bounty_target` tail — the ecology half of that helper
            # is the injected seam).
            lookup = find_marker(qs, target_id)
            if lookup:
                lookup["quest_id"] = str(instance.get("instance_id", ""))
                lookup["tier"] = int(instance.get("requirements", {})
                                     .get("tier", 1))
    qs.active_quests.append(instance)
    # EventBus.quests_changed — the caller's WS frame.
    return instance


# --- Completion & failure (docs/70-* §4.9.3) -----------------------------

def completable_deliveries(qs: QuestState, dest_port_id: str,
                           fleet: list[Any]) -> list[dict[str, Any]]:
    """The quests a delivery at ``dest_port_id`` would complete right now
    (called on port entry). Pure read: :func:`complete_delivery_quests`
    applies them."""
    from server.sim import fleet as fleet_lib

    out: list[dict[str, Any]] = []
    for quest in qs.active_quests:
        if not isinstance(quest, dict):
            continue
        if str(quest.get("status", "")) != STATUS_ACTIVE:
            continue
        if str(quest.get("type", "")) != TYPE_DELIVERY:
            continue
        requirements = quest.get("requirements", {})
        if str(requirements.get("dest_port_id", "")) != dest_port_id:
            continue
        good_id = str(requirements.get("good_id", ""))
        if fleet_lib.held(fleet, good_id) < int(requirements.get("quantity", 0)):
            continue
        out.append(quest)
    return out


def complete_delivery_quests(qs: QuestState, st: PersonState,
                             dest_port_id: str, fleet: list[Any]) \
        -> list[dict[str, Any]]:
    """Completes every delivery quest due at ``dest_port_id``; returns the
    list of completed instances. The goods are removed, then the reward
    is paid."""
    from server.sim import fleet as fleet_lib

    done: list[dict[str, Any]] = []
    for quest in completable_deliveries(qs, dest_port_id, fleet):
        requirements = quest["requirements"]
        quantity = int(requirements.get("quantity", 0))
        removed = fleet_lib.remove_goods(fleet,
                                         str(requirements.get("good_id", "")),
                                         quantity)
        if removed != quantity:
            continue
        _complete(st, quest)
        done.append(quest)
    # EventBus.fleet_changed — the caller's WS frame.
    return done


def complete_exploration_quests(qs: QuestState, st: PersonState,
                                discovery_id: str) -> list[dict[str, Any]]:
    """Completes the exploration quest for ``discovery_id`` (called by the
    guild report), on top of the report's own reward (§4.4)."""
    done: list[dict[str, Any]] = []
    for quest in qs.active_quests:
        if not isinstance(quest, dict) \
                or str(quest.get("type", "")) != TYPE_EXPLORATION:
            continue
        if str(quest.get("status", "")) != STATUS_ACTIVE:
            continue
        if str(quest.get("requirements", {}).get("discovery_id", "")) \
                != discovery_id:
            continue
        _complete(st, quest)
        done.append(quest)
    return done


def complete_bounty_quests(qs: QuestState, st: PersonState,
                           target_fleet_id: str) -> list[dict[str, Any]]:
    """Completes the bounty quest whose ``target_fleet_id`` just lost a
    battle (`70-*` §4.9.3: a ``victory`` against the target fleet)."""
    done: list[dict[str, Any]] = []
    if not target_fleet_id:
        return done
    for quest in qs.active_quests:
        if not isinstance(quest, dict) \
                or str(quest.get("type", "")) != TYPE_BOUNTY:
            continue
        if str(quest.get("status", "")) != STATUS_ACTIVE:
            continue
        if str(quest.get("requirements", {}).get("target_fleet_id", "")) \
                != target_fleet_id:
            continue
        _complete(st, quest)
        done.append(quest)
    return done


def _complete(st: PersonState, quest: dict[str, Any]) -> None:
    """Pays one quest's rewards and marks it completed. The single place a
    quest awards gold/reputation/fame, so every completion path is
    identical."""
    rewards = quest.get("rewards", {})
    gold = int(rewards.get("gold", 0))
    if gold > 0:
        st.gold += gold  # GameState.add_gold
    reputation = rewards.get("reputation", {})
    for nation_id in reputation:
        character_lib.add_reputation(st, str(nation_id),
                                     int(reputation[nation_id]))
    fame = int(rewards.get("fame", 0))
    if fame > 0:
        fame_lib.add(st, fame)
    quest["status"] = STATUS_COMPLETED
    quest["completed_day"] = int(st.day)
    # EventBus.quests_changed — the caller's WS frame.


def fail(qs: QuestState, st: PersonState, quest: dict[str, Any]) -> bool:
    """Fails ``quest`` with the §4.2 delta (−5 rep with the origin port's
    nation, no fame, no gold; delivery goods are *not* reclaimed)."""
    if str(quest.get("status", "")) != STATUS_ACTIVE:
        return False
    origin = data().get_port(str(quest.get("origin_port_id", "")))
    character_lib.add_reputation(st, str(origin.get("nation_id", "")),
                                 FAIL_REPUTATION)
    quest["status"] = STATUS_FAILED
    quest["failed_day"] = int(st.day)
    # EventBus.quests_changed — the caller's WS frame.
    return True


def is_expired(quest: dict[str, Any], day: int) -> bool:
    """``True`` when ``quest`` has expired on ``day`` (§4.9.3 ``day >
    deadline_day``)."""
    deadline = int(quest.get("deadline_day", 0))
    if deadline <= 0:
        return False
    return day > deadline


def delivery_cargo_lost(quest: dict[str, Any], fleet: list[Any]) -> bool:
    """``True`` when a delivery's goods are no longer held in the pooled
    hold — the "cargo sold/jettisoned" failure path (§4.2, §6)."""
    from server.sim import fleet as fleet_lib

    if str(quest.get("type", "")) != TYPE_DELIVERY:
        return False
    requirements = quest.get("requirements", {})
    return fleet_lib.held(fleet, str(requirements.get("good_id", ""))) \
        < int(requirements.get("quantity", 0))


def tick(qs: QuestState, st: PersonState, day: int,
         fleet: list[Any]) -> list[dict[str, Any]]:
    """The day-tick pass: expires every overdue quest and fails every
    delivery whose cargo is gone. Returns the list of failed instances
    (for the report). Bounty quests are **not** failed here while their
    battle is running: the caller invokes this at the day tick, and a
    battle in progress blocks the tick, so the §6 "expired bounty while in
    battle" rule is satisfied by the ordering
    (:func:`complete_bounty_quests` runs at battle end, before the next
    tick)."""
    failed: list[dict[str, Any]] = []
    for quest in qs.active_quests:
        if not isinstance(quest, dict) \
                or str(quest.get("status", "")) != STATUS_ACTIVE:
            continue
        if is_expired(quest, day) or delivery_cargo_lost(quest, fleet):
            if fail(qs, st, quest):
                failed.append(quest)
    return failed


def prune(qs: QuestState) -> int:
    """Drops completed/failed instances from ``active_quests`` (the panel
    and the slot count only ever see live quests). Returns how many were
    dropped."""
    kept: list[Any] = []
    dropped = 0
    for quest in qs.active_quests:
        if isinstance(quest, dict) \
                and str(quest.get("status", STATUS_ACTIVE)) == STATUS_ACTIVE:
            kept.append(quest)
        else:
            dropped += 1
    qs.active_quests = kept
    return dropped


def active_quests(qs: QuestState) -> list[dict[str, Any]]:
    """The active quests for the character panel, in accepted order."""
    return [quest for quest in qs.active_quests
            if isinstance(quest, dict)
            and str(quest.get("status", STATUS_ACTIVE)) == STATUS_ACTIVE]


def abandon(qs: QuestState, st: PersonState, quest: dict[str, Any]) -> bool:
    """Abandons ``quest`` (the panel's ``quest.abandon``): the same
    failure path."""
    return fail(qs, st, quest)


def find(qs: QuestState, instance_id: str) -> dict[str, Any]:
    """The instance with ``instance_id``, or ``{}``."""
    for quest in qs.active_quests:
        if isinstance(quest, dict) \
                and str(quest.get("instance_id", "")) == instance_id:
            return quest
    return {}


def find_marker(qs: QuestState, fleet_id: str) -> dict[str, Any]:
    """The fleet marker with ``id`` in ``QuestState.npc_fleets``, or
    ``{}`` (the GDScript ``_find_marker`` over ``GameState.npc_fleets``)."""
    if not fleet_id:
        return {}
    for fleet in qs.npc_fleets:
        if isinstance(fleet, dict) and str(fleet.get("id", "")) == fleet_id:
            return fleet
    return {}


# --- Presentation (docs/80-* §4.7.3, §4.7.4) -----------------------------

def objective_text(quest: dict[str, Any], qs: QuestState, i18n: I18nView,
                   captain_name_of: CaptainNameOf | None = None) -> str:
    """The composed objective line of an offer or stored instance
    (``quest.line.*`` frames from `80-*` §4.7.4; numbers composed by the
    UI, `10-*` §3.3). Shared by the guild screen and the character panel
    so a quest reads the same wherever it is listed."""
    store = data()
    requirements = quest.get("requirements", {})
    type_id = str(quest.get("type", ""))
    if type_id == TYPE_ROYAL:
        # Royal missions name their objective in the template
        # (``data/quests.json`` ``requirements.objective``, `70-*` §4.9.4)
        # and wrap it in the §4.7.4 ``quest.line.royal`` frame.
        template = store.get_quest(str(quest.get("template_id", "")))
        objective = template.get("requirements", {}).get("objective", {})
        if objective:
            return i18n.fmt("quest.line.royal",
                            {"objective": i18n.t(objective)})
        return i18n.t_key("quest.type.royal")
    if type_id == TYPE_DELIVERY:
        return _delivery_line(requirements, i18n)
    if type_id == TYPE_BOUNTY:
        return i18n.fmt("quest.line.bounty", {
            # Task L (§4.11.11.4): a quest whose target fleet is a live
            # named pirate names the captain; the generic label stays for
            # an unnamed (about-to-spawn) target.
            "target": _bounty_target_name(requirements, qs, i18n,
                                          captain_name_of),
            "tier": int(requirements.get("tier", 1)),
        })
    if type_id == TYPE_EXPLORATION:
        return i18n.t_key("quest.line.exploration")
    return i18n.t_key("ui.not_available")


def _delivery_line(requirements: dict[str, Any], i18n: I18nView) -> str:
    store = data()
    return i18n.fmt("quest.line.delivery", {
        "quantity": int(requirements.get("quantity", 0)),
        "good": i18n.t(store.get_good(str(requirements.get("good_id", "")))
                       .get("name", {})),
        "port": _port_name(str(requirements.get("dest_port_id", "")), i18n),
    })


def _bounty_target_name(requirements: dict[str, Any], qs: QuestState,
                        i18n: I18nView,
                        captain_name_of: CaptainNameOf | None) -> str:
    """The bounty line's target label: the live target fleet's
    **named-pirate** captain (§4.11.11.4 preference) when it resolves,
    else the generic pirate label — an unnamed target keeps today's
    wording."""
    target_id = str(requirements.get("target_fleet_id", ""))
    if target_id and captain_name_of is not None:
        fleet = find_marker(qs, target_id)
        if fleet:
            name = captain_name_of(fleet)
            if name:
                return name
    return i18n.t_key("encounter.pirate")


def _port_name(port_id: str, i18n: I18nView) -> str:
    if not port_id:
        return "-"
    return i18n.t(data().get_port(port_id).get("name", {}))


def type_key(quest: dict[str, Any]) -> str:
    """The type tag key of a quest (``quest.type.*``, `80-*` §4.7.4)."""
    return "quest.type.%s" % str(quest.get("type", ""))


# --- Helpers --------------------------------------------------------------

def _clampi(value: int, low: int, high: int) -> int:
    """GDScript ``clampi``."""
    return max(low, min(value, high))
