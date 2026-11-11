"""server.sim.port.shipyard — the shipyard engine (M1).

Python port of ``scripts/port/shipyard_engine.gd`` (the frozen parity
oracle until the M6 cutover): the docs/40-SHIPS-AND-FLEET.md §4.3 four
actions (buy / repair / sell / refit), §4.3.1 per-port stock + tier
gating with the three §4.7.12 row states, §4.4 flagship promotion, and
the Phase-2 equipment rules of docs/60-COMBAT.md §4.11.12/§4.11.13.

Normative pins carried here (docs/40 §4.3 unless noted):
  * ``FLEET_MAX = 5`` ships; buying the 6th is refused
    (``shipyard.fleet_full``).
  * A bought ship starts at full durability, zero crew, no supplies, no
    cannons, empty hold (§4.3/§4.1).
  * Repair costs ``ceil(base_price / 400)`` per durability point; partial
    repair is allowed, capped by both damage and gold. Phase 8: with an
    in-post carpenter the whole fee is ×``(1 − floor(carpentry/20)/100)``
    (40-§4.3), composed AFTER the §4.9.2 count-title ×0.8 and **floored
    once at the end of the whole transaction**.
  * Sell price is ``floor(base_price × 0.5 × durability /
    effective_max_durability)`` (§4.1: the denominator is the effective
    max, so a figurehead can never lift a sale above half base price);
    the flagship can never be sold and the last ship can never be sold;
    the pooled hold (goods + provisions + water) must be empty.
  * Refit is 100g/cannon, 50g sell-back, 5 cargo units each, capped by
    ``armament_slots`` and by hold room.
  * Equipment (60-§4.11.12): ``weapon``/``armor`` live on the player,
    ``figurehead``/``sail`` on one hull; buying into an occupied slot
    sells the old item back at ``floor(price × 0.5)`` in the same
    transaction (one net gold delta); repairs use the figurehead-raised
    effective max, and removing one clamps current durability down (the
    only place the cap can shrink).
  * Promotion (§4.4) is free and port-only; it moves the row to
    ``fleet[0]`` preserving every other ship's relative order.
  * Phase 7 (40-§4.3.1, 60-§4.11.13): rows come from the port's stock
    lists (``facilities.shipyard`` / ``facilities.equipment_stock``)
    under ``purchasable = in_stock ∧ tier ≤ effective_dev(port)``; the
    three row states are available / tier-gray 需发展度 / allegiance-gray
    同盟专营 (an unallied neutral shows its full list allegiance-locked —
    never an empty catalog); rare items are drop-only and filtered
    defensively even if a stock list ever carried one.

Purity contract (M1): **pure functions over injected state** — the fleet
array, the player block and the purse are injected (the server's
GameState port, a later wave, owns the live values exactly like
``GameState`` did). Content lookups (ship types, equipment, ports) read
:mod:`server.sim.data` exactly where the GDScript reads ``DataLoader``.
The mutating transactions mutate the injected fleet/player dicts in place
and return a :class:`TxResult` whose ``gold_delta`` the caller applies —
the GDScript's ``GameState.add_gold`` + ``EventBus`` emissions live at
the caller.

Injected seams (the GDScript reads autoloads here; later waves own them):
  * ``allegiance`` — the guard-read allegiance module (80-§4.16 C
    contract): an optional :class:`AllegianceView` answering
    ``dev(port_id)`` / ``effective_alignment(port_id)``. ``None`` mirrors
    the GDScript no-module path exactly: the authored data floor
    (``ports.json`` ``dev``) and the port's data ``nation_id``.
  * ``title_repair_discount`` — the §4.9.2 count-title factor
    (``Fame.repair_discount`` of the port's own nation: 0.8 at count or
    above, else 1.0), resolved by the caller against the titles state the
    Fame module owns.
  * ``carpenter_discount`` — the Phase-8 in-post carpenter fee factor
    (``SailingSim.carpenter_discount``); :func:`carpenter_discount_factor`
    carries the pure 40-§4.3 formula for callers (and the sailing
    module's later port).
  * Facility-hours gating (§4.1b) — ``SailingSim.facility_open`` /
    ``advance_port_hours``: the sailing module. ``buy``/``repair``/
    ``sell``/``refit`` stop at that seam; the caller checks the window
    and charges the hours (3 / 2 / 1 / 2 respectively).
  * ``EventBus.fleet_changed`` — announce after any applied transaction.

Contract note (reported, not fixed): docs/40 §4.3 names a Phase-8
"≥ 1 idle officer" Buy gate, but the oracle engine implements the officer
gate only on the capture path (``battle_result.gd``); ``buy_block_reason``
checks stock, tier, fleet cap and gold — ported verbatim.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Final, Protocol

from server.sim import fleet as fleet_lib
from server.sim.data import data

__all__ = [
    "FLEET_MAX",
    "CANNON_CARGO_UNITS",
    "CANNON_PRICE",
    "CANNON_SELLBACK_PRICE",
    "REPAIR_DIVISOR",
    "SELL_FRACTION",
    "ROW_AVAILABLE",
    "ROW_TIER_GRAY",
    "ROW_ALLEGIANCE_GRAY",
    "TIER_NEED_DEV_KEY",
    "ALLEGIANCE_LOCKED_KEY",
    "PLAYER_SLOTS",
    "SHIP_SLOTS",
    "EQUIP_SELL_FRACTION",
    "AllegianceView",
    "TxResult",
    "authored_dev",
    "effective_dev",
    "effective_alignment",
    "is_unallied_neutral",
    "item_tier",
    "is_rare_equipment",
    "row_state",
    "row_note_key",
    "shipyard_stock",
    "equipment_stock",
    "equipment_list",
    "buy_price",
    "can_buy",
    "buy_block_reason",
    "buy",
    "repair_cost_per_point",
    "max_repair_points",
    "repair_cost",
    "raw_repair_cost",
    "carpenter_discount_factor",
    "repair_block_reason",
    "can_repair",
    "repair",
    "repair_apply",
    "sell_price",
    "sell_block_reason",
    "can_sell",
    "sell",
    "refit_cost",
    "refit_sellback",
    "refit_cargo_units",
    "max_refit",
    "refit_block_reason",
    "can_refit",
    "refit",
    "equipped_player",
    "equipped_ship",
    "equip_price",
    "equip_sellback",
    "equip_block_reason",
    "equip_net_cost",
    "equip",
    "unequip",
    "can_unequip",
    "equipment_modifier",
    "player_combat_bonus",
    "ship_max_durability",
    "ship_speed_bonus",
    "can_promote",
    "promote",
]

# --- Locked constants (docs/40 §4.2–§4.4) -------------------------------------

#: §4.4: locked fleet size (also the buy cap of §4.3).
FLEET_MAX: Final[int] = fleet_lib.FLEET_MAX
#: §4.2/§4.3: one cannon occupies this many cargo units.
CANNON_CARGO_UNITS: Final[int] = fleet_lib.CANNON_CARGO_UNITS
#: §4.3 refit: 100g per cannon, 50g sell-back each.
CANNON_PRICE: Final[int] = 100
CANNON_SELLBACK_PRICE: Final[int] = 50
#: §4.3 repair: ``ceil(base_price / 400)`` per durability point.
REPAIR_DIVISOR: Final[int] = 400
#: §4.3 sell: ``floor(base_price × 0.5 × dur / max_dur)``.
SELL_FRACTION: Final[float] = 0.5

# --- Per-port stock & tier gating (Phase 7; 40-§4.3.1, 80-§4.7.12) -------------

#: The three §4.7.12 row states (strings so screens and suites can switch
#: on them without an enum registry).
ROW_AVAILABLE: Final[str] = "available"
ROW_TIER_GRAY: Final[str] = "tier_gray"
ROW_ALLEGIANCE_GRAY: Final[str] = "allegiance_gray"
#: The gray-state notes (80-§4.7.15; callers resolve them against
#: ``ui_strings.json`` — engines return keys, never text).
TIER_NEED_DEV_KEY: Final[str] = "shipyard.tier.need_dev"
ALLEGIANCE_LOCKED_KEY: Final[str] = "shipyard.tier.allegiance_locked"

# --- Equipment slots (Phase 2; 60-§4.11.12) -------------------------------------

#: ``weapon``/``armor`` are worn by the player, ``figurehead``/``sail``
#: are bound to one hull.
PLAYER_SLOTS: Final[tuple[str, ...]] = ("weapon", "armor")
SHIP_SLOTS: Final[tuple[str, ...]] = ("figurehead", "sail")
#: 40-§4.3 / 60-§4.11.12: selling an item back pays ``floor(price ×
#: 0.5)`` — the same fraction as a hull.
EQUIP_SELL_FRACTION: Final[float] = 0.5


class AllegianceView(Protocol):
    """The guard-read allegiance seam (the 80-§4.16 C contract).

    The GDScript guard-loads ``scripts/port/allegiance.gd`` and calls
    these two statics when present, falling back to the authored data
    otherwise; the Python server injects the module's later port (or
    ``None`` for the same fallback)."""

    def dev(self, port_id: str) -> int: ...

    def effective_alignment(self, port_id: str) -> str: ...


@dataclass(frozen=True)
class TxResult:
    """The outcome of a mutating shipyard transaction — the GDScript
    bool + side effects as a value. The caller applies ``gold_delta``
    to the purse (one announcement), charges the §4.1b facility hours
    and emits ``fleet_changed`` when ``ok``."""

    ok: bool = False
    gold_delta: int = 0


# --- Per-port stock & tier gating (Phase 7) -------------------------------------


def authored_dev(port_id: str) -> int:
    """The authored development floor of ``ports.json`` (docs/30 §4.9:
    capitals and protected ports 3, sovereign majors 2, the rest 1,
    neutrals 0). This IS the guard fallback for :func:`effective_dev`."""
    return int(data().get_port(port_id).get("dev", 0))


def effective_dev(port_id: str, allegiance: AllegianceView | None = None) -> int:
    """§4.9 effective development: the allegiance view's derived level
    (authored floor vs ledger thresholds) when injected, else the
    authored floor itself (the GDScript guard default)."""
    if allegiance is not None:
        return int(allegiance.dev(port_id))
    return authored_dev(port_id)


def effective_alignment(port_id: str,
                        allegiance: AllegianceView | None = None) -> str:
    """§4.9 effective alignment: the allegiance view's answer when
    injected, else the port's data ``nation_id``."""
    if allegiance is not None:
        value = allegiance.effective_alignment(port_id)
        if isinstance(value, str):
            return value
    return str(data().get_port(port_id).get("nation_id", ""))


def is_unallied_neutral(port_id: str,
                        allegiance: AllegianceView | None = None) -> bool:
    """An **unallied neutral**: ``nation_id: ""`` and no allegiance either
    (the §4.7.12 allegiance-gray condition)."""
    port = data().get_port(port_id)
    if str(port.get("nation_id", "")) != "":
        return False
    return effective_alignment(port_id, allegiance) == ""


def item_tier(item_id: str) -> int:
    """``tier: 1|2|3`` of a ship type or equipment item (1 when absent —
    never a crash on hand-edited data)."""
    ship_type = data().get_ship_type(item_id)
    if ship_type:
        return max(1, int(ship_type.get("tier", 1)))
    return max(1, int(data().get_equipment(item_id).get("tier", 1)))


def is_rare_equipment(equipment_id: str) -> bool:
    """60-§4.11.13: rare items are drop-only and never stocked."""
    return bool(data().get_equipment(equipment_id).get("rare", False))


def row_state(port_id: str, item_id: str,
              allegiance: AllegianceView | None = None) -> str:
    """The §4.7.12 state of ``item_id`` (ship or equipment) at
    ``port_id``."""
    if is_unallied_neutral(port_id, allegiance):
        return ROW_ALLEGIANCE_GRAY
    if item_tier(item_id) > effective_dev(port_id, allegiance):
        return ROW_TIER_GRAY
    return ROW_AVAILABLE


def row_note_key(port_id: str, item_id: str,
                 allegiance: AllegianceView | None = None) -> str:
    """The ``ui_strings`` note of the gray state (``""`` when available)."""
    state = row_state(port_id, item_id, allegiance)
    if state == ROW_TIER_GRAY:
        return TIER_NEED_DEV_KEY
    if state == ROW_ALLEGIANCE_GRAY:
        return ALLEGIANCE_LOCKED_KEY
    return ""


def _resolve_port(port_id: str, current_port: Any) -> str:
    """``port_id`` when given, else the docked port (``""`` at sea /
    standalone)."""
    if port_id:
        return port_id
    return current_port if isinstance(current_port, str) else ""


def _stock_ids(port_id: str, facility: str, catalog: list[Any],
               rare_gated: bool) -> list[str]:
    """The ids this port's ``facility`` stocks, in the port's data order,
    filtered to known ids (and to non-rare equipment — 60-§4.11.13 "never
    in any stock list", defensively). An empty ``port_id`` (standalone /
    at sea) returns the full catalog minus rares in data order, so a
    standalone screen never renders an empty crash state."""
    ids: list[str] = []
    known: dict[str, bool] = {}
    for entry in catalog:
        if isinstance(entry, dict):
            entry_id = str(entry.get("id", ""))
            if rare_gated and is_rare_equipment(entry_id):
                continue
            known[entry_id] = True
    if not port_id:
        # Insertion order = the catalog's data order (dict keeps it).
        return list(known)
    facilities = data().get_port(port_id).get("facilities", {})
    if not isinstance(facilities, dict):
        return ids
    payload = facilities.get(facility)
    if not isinstance(payload, list):
        return ids
    for entry in payload:
        id = str(entry)
        if id in known and not (rare_gated and is_rare_equipment(id)):
            ids.append(id)
    return ids


def shipyard_stock(port_id: str = "", current_port: Any = "") -> list[str]:
    """The hull ids stocked at ``port_id`` (``""`` = the docked port; no
    port = the full catalog fallback, 40-§4.3.1)."""
    return _stock_ids(_resolve_port(port_id, current_port), "shipyard",
                      data().ship_types_list, False)


def equipment_stock(port_id: str = "", current_port: Any = "") -> list[str]:
    """The equipment ids stocked at ``port_id`` (``""`` = the docked port;
    no port = the full non-rare catalog fallback, 60-§4.11.13)."""
    return _stock_ids(_resolve_port(port_id, current_port),
                      "equipment_stock", data().equipment_list, True)


def equipment_list(slot: str, port_id: str = "",
                   current_port: Any = "") -> list[dict[str, Any]]:
    """60-§4.11.12: every item of ``slot`` the port stocks (its
    ``equipment_stock`` order), non-rare only. With no port the fallback
    is every non-rare item of the slot in data order (standalone
    screens). Above-dev and allegiance-locked items stay in the list —
    graying them is the screen's §4.7.12 job; refusing them is
    :func:`equip_block_reason`'s."""
    items: list[dict[str, Any]] = []
    if slot not in PLAYER_SLOTS and slot not in SHIP_SLOTS:
        return items
    stock = equipment_stock(port_id, current_port)
    by_id: dict[str, dict[str, Any]] = {}
    for item in data().equipment_list:
        if isinstance(item, dict) and str(item.get("slot", "")) == slot:
            by_id[str(item.get("id", ""))] = item
    for id in stock:
        if id in by_id:
            items.append(by_id[id])
    return items


# --- Buy (§4.3) ---------------------------------------------------------------


def buy_price(ship_type_id: str) -> int:
    """§4.3: ``ShipType.base_price`` is the whole cost (0 for an unknown
    type)."""
    return int(data().get_ship_type(ship_type_id).get("base_price", 0))


def buy_block_reason(ship_type_id: str, *, current_port: Any = "",
                     fleet_size: int = 0, gold: int = 0,
                     allegiance: AllegianceView | None = None) -> str:
    """Why the Buy button of ``ship_type_id`` is disabled, as a
    ``ui_strings.json`` key (``""`` = allowed). Order matters for the §6
    message: the port gates come first (an unstocked or above-dev hull is
    unbuyable at any price or fleet size), then the fleet cap (buying at
    5 ships is impossible at any price), then affordability. The
    gray-state keys carry a ``{dev}`` placeholder in the first case — the
    screen renders the note (80-§4.7.12)."""
    if not data().get_ship_type(ship_type_id):
        return "ui.not_available"
    port = _resolve_port("", current_port)
    if port:
        if ship_type_id not in shipyard_stock(port):
            return "ui.not_available"
        note = row_note_key(port, ship_type_id, allegiance)
        if note:
            return note
    if fleet_size >= FLEET_MAX:
        return "shipyard.fleet_full"
    if gold < buy_price(ship_type_id):
        return "shipyard.no_gold"
    return ""


def can_buy(ship_type_id: str, *, current_port: Any = "",
            fleet_size: int = 0, gold: int = 0,
            allegiance: AllegianceView | None = None) -> bool:
    """§4.3: stocked at the docked port under the tier gate, purse ≥
    price and ``fleet_size < FLEET_MAX``."""
    return not buy_block_reason(ship_type_id, current_port=current_port,
                                fleet_size=fleet_size, gold=gold,
                                allegiance=allegiance)


def buy(ship_type_id: str, *, fleet: list[Any], current_port: Any = "",
        fleet_size: int = -1, gold: int = 0,
        allegiance: AllegianceView | None = None) -> TxResult:
    """§4.3 "Buy ship": appends the §4.1 instance with the §4.3 defaults
    (full durability, crew 0, supplies 0, cannons 0, empty hold) to the
    injected fleet. Returns ``ok=False`` without touching the fleet when
    :func:`can_buy` is false; on success the caller pays ``gold_delta``
    (``−base_price``), charges the §4.1b three hours, and announces
    ``fleet_changed``.

    ``fleet_size`` defaults to ``len(fleet)`` (the GDScript reads
    ``GameState.fleet.size()`` at the same instant)."""
    if fleet_size < 0:
        fleet_size = len(fleet)
    if not can_buy(ship_type_id, current_port=current_port,
                   fleet_size=fleet_size, gold=gold, allegiance=allegiance):
        return TxResult()
    # §4.1b closed rule (deferred): a build order may only start inside
    # the window — the caller checks SailingSim.facility_open first and
    # charges the three hours after.
    instance = fleet_lib.new_ship(ship_type_id, 0)
    if not instance:
        # Unknown type — can_buy already rejects it; belt and braces.
        return TxResult()
    fleet.append(instance)
    return TxResult(ok=True, gold_delta=-buy_price(ship_type_id))


# --- Repair (§4.3, Phase-8 discounts) -------------------------------------------


def repair_cost_per_point(ship_type_id: str) -> int:
    """§4.3: repair cost per durability point = ``ceil(base_price /
    400)`` (0 for an unknown type)."""
    ship_type = data().get_ship_type(ship_type_id)
    if not ship_type:
        return 0
    base_price = int(ship_type.get("base_price", 0))
    return math.ceil(float(base_price) / float(REPAIR_DIVISOR))


def ship_max_durability(fleet: list[Any], index: int) -> int:
    """40-§4.1 / 60-§4.11.12: ``ShipType.durability`` plus the worn
    figurehead's ``durability`` modifier — the effective maximum, which
    also caps repairs and current durability (0 for no such hull)."""
    ship_dict = fleet_lib.ship(fleet, index)
    if not ship_dict:
        return 0
    return (fleet_lib.ship_stat(ship_dict, "durability")
            + equipment_modifier(equipped_ship(fleet, index, "figurehead"),
                                 "durability"))


def max_repair_points(fleet: list[Any], index: int) -> int:
    """§4.3/§6: the damage a hull can still take, i.e. the repair cap.
    40-§4.1: repairs use the **effective** max durability, so a worn
    figurehead raises the cap exactly as it raises the hull's maximum."""
    ship_dict = fleet_lib.ship(fleet, index)
    if not ship_dict:
        return 0
    return max(0, ship_max_durability(fleet, index)
               - _as_int(ship_dict.get("durability", 0)))


def carpenter_discount_factor(carpentry: int) -> float:
    """The pure Phase-8 40-§4.3 fee multiplier of an in-post carpenter:
    ``1 − floor(carpentry / 20) / 100`` (a −``floor(carpentry / 20)``%
    discount; ×1.00 / ×0.99 / ×0.95 at carpentry 0 / 20 / 100). The
    GDScript keeps this in ``SailingSim.carpenter_discount`` (it reads
    the skills module) — the sailing module's later port re-owns the
    autoload-reading side; callers inject the factor here."""
    steps = math.floor(float(carpentry) / 20.0)
    return 1.0 - float(steps) / 100.0


def raw_repair_cost(fleet: list[Any], index: int, points: int) -> int:
    """The undiscounted §4.3 price of ``points``
    (``points × ceil(base_price / 400)``; 0 for a non-positive/invalid
    request)."""
    ship_dict = fleet_lib.ship(fleet, index)
    if not ship_dict or points <= 0:
        return 0
    return points * repair_cost_per_point(
        str(ship_dict.get("ship_type_id", "")))


def repair_cost(fleet: list[Any], index: int, points: int, *,
                title_repair_discount: float = 1.0,
                carpenter_discount: float = 1.0) -> int:
    """Cost of ``points`` on ``fleet[index]`` (0 for a non-positive or
    invalid request). Phase 3: at a port of a nation whose title is count
    or higher the total is multiplied by ``0.8`` (70-§4.9.2 — injected as
    ``title_repair_discount``; the Fame module owns the titles state).
    Phase 8 (40-§4.3): the whole transaction is additionally multiplied
    by the in-post carpenter's discount (composed after the count-title
    factor) and **floored once at the end of the whole transaction**."""
    raw = raw_repair_cost(fleet, index, points)
    if raw <= 0:
        return 0
    discounted = (float(raw) * title_repair_discount
                  * carpenter_discount)
    return max(0, math.floor(discounted))


def repair_block_reason(fleet: list[Any], index: int, points: int, *,
                        gold: int = 0, title_repair_discount: float = 1.0,
                        carpenter_discount: float = 1.0) -> str:
    """Why a repair of ``points`` is refused, as a ``ui_strings.json`` key
    (``""`` = allowed). §6: 0 points and unaffordable repairs are
    validation failures, so the UI disables the button instead of showing
    a dialog."""
    if not fleet_lib.ship(fleet, index):
        return "shipyard.no_selection"
    if points <= 0:
        return "shipyard.invalid_points"
    if points > max_repair_points(fleet, index):
        return "shipyard.invalid_points"
    if gold < repair_cost(fleet, index, points,
                          title_repair_discount=title_repair_discount,
                          carpenter_discount=carpenter_discount):
        return "shipyard.no_gold"
    return ""


def can_repair(fleet: list[Any], index: int, points: int, *, gold: int = 0,
               title_repair_discount: float = 1.0,
               carpenter_discount: float = 1.0) -> bool:
    """§4.3: ``points > 0``, ``≤`` damage, ``gold ≥ cost``."""
    return not repair_block_reason(
        fleet, index, points, gold=gold,
        title_repair_discount=title_repair_discount,
        carpenter_discount=carpenter_discount)


def repair(fleet: list[Any], index: int, points: int, *, gold: int = 0,
           title_repair_discount: float = 1.0,
           carpenter_discount: float = 1.0) -> TxResult:
    """§4.3 "Repair ship": partial repair is the only kind — exactly
    ``points`` durability is restored and exactly the (discounted) cost
    is paid. The cap is the **effective** max (§4.1), so a worn
    figurehead can be repaired onto. The §4.1b yard window + two-hour
    charge are the caller's (deferred sailing-sim seam)."""
    if not can_repair(fleet, index, points, gold=gold,
                      title_repair_discount=title_repair_discount,
                      carpenter_discount=carpenter_discount):
        return TxResult()
    return repair_apply(fleet, index, points,
                        title_repair_discount=title_repair_discount,
                        carpenter_discount=carpenter_discount)


def repair_apply(fleet: list[Any], index: int, points: int, *,
                 title_repair_discount: float = 1.0,
                 carpenter_discount: float = 1.0) -> TxResult:
    """The §4.3 repair mutation with **no clock and no window** — the
    primitive :func:`repair` wraps (the palace bays call this; tests
    drive it directly for the pure rules). Mutates the injected hull;
    the caller pays ``gold_delta``."""
    ship_dict = fleet[index]
    durability = _as_int(ship_dict.get("durability", 0))
    ship_dict["durability"] = min(durability + points,
                                  ship_max_durability(fleet, index))
    cost = repair_cost(fleet, index, points,
                       title_repair_discount=title_repair_discount,
                       carpenter_discount=carpenter_discount)
    return TxResult(ok=True, gold_delta=-cost)


# --- Sell (§4.3) ---------------------------------------------------------------


def sell_price(fleet: list[Any], index: int) -> int:
    """§4.3: ``floor(base_price × 0.5 × durability / max_durability)``.

    ``max_durability`` is the **effective** max of §4.1: a worn
    figurehead can raise a hull above its ``ShipType.durability``, and
    since equipment leaves with the ship the ratio must stay ``≤ 1``
    (otherwise a figurehead would let a hull sell for more than half its
    base price). Without equipment this is exactly the Phase-1 formula."""
    ship_dict = fleet_lib.ship(fleet, index)
    if not ship_dict:
        return 0
    max_durability = ship_max_durability(fleet, index)
    if max_durability <= 0:
        return 0
    base_price = buy_price(str(ship_dict.get("ship_type_id", "")))
    durability = max(0, min(_as_int(ship_dict.get("durability", 0)),
                            max_durability))
    return math.floor(float(base_price) * SELL_FRACTION * float(durability)
                      / float(max_durability))


def sell_block_reason(fleet: list[Any], index: int) -> str:
    """Why ``fleet[index]`` cannot be sold, as a ``ui_strings.json`` key
    (``""`` = allowed). The last-ship check comes first: when the fleet
    has one hull it is by definition the flagship, and §6 names that case
    ``shipyard.no_sell_last``.

    "Cargo aboard must be 0" (§4.3) is enforced over the whole **pooled
    hold** of §4.2 — trade goods *and* provisions/water — because §4.2
    pools all three across the fleet: a sale that dropped supplies would
    silently destroy fleet resources, which §6 forbids ("never
    silently"). Cannons are P2's business (they have their own 50g
    sell-back, §4.3)."""
    ship_dict = fleet_lib.ship(fleet, index)
    if not ship_dict:
        return "shipyard.no_selection"
    if len(fleet) <= 1:
        return "shipyard.no_sell_last"
    if index == 0:
        return "shipyard.no_sell_flagship"
    if fleet_lib.hold_units(ship_dict) > 0:
        return "shipyard.cargo_not_empty"
    return ""


def can_sell(fleet: list[Any], index: int) -> bool:
    """§4.3: not the flagship, not the last ship, empty (pooled) hold."""
    return not sell_block_reason(fleet, index)


def sell(fleet: list[Any], index: int) -> TxResult:
    """§4.3 "Sell ship": removes the hull and returns the formula price
    as ``gold_delta``. Her crew is lost — the UI confirms first (§4.3,
    docs/80 §4.7) — and nothing is transferred to another ship:
    :func:`can_sell` already requires an empty pooled hold, so no goods,
    provisions or water can vanish here (§6 "never silently"). The §4.1b
    window + one-hour charge are the caller's."""
    if not can_sell(fleet, index):
        return TxResult()
    price = sell_price(fleet, index)
    fleet.pop(index)
    return TxResult(ok=True, gold_delta=price)


# --- Refit (Phase 2: the UI row is live, 80-§4.7.2) -----------------------------


def refit_cost(cannons: int) -> int:
    """§4.3: 100g per cannon."""
    return max(cannons, 0) * CANNON_PRICE


def refit_sellback(cannons: int) -> int:
    """§4.3: 50g back per cannon removed."""
    return max(cannons, 0) * CANNON_SELLBACK_PRICE


def refit_cargo_units(cannons: int) -> int:
    """§4.2/§4.3: ``cannons × 5`` cargo units consumed by an armament
    refit."""
    return max(cannons, 0) * CANNON_CARGO_UNITS


def max_refit(fleet: list[Any], index: int) -> int:
    """Spare ``armament_slots`` and cargo room on ``fleet[index]`` (§4.3
    "≤ armament_slots", §4.2 cannons share the hold). The GDScript
    divides hold room by 5 in integer arithmetic (truncating) — mirrored
    exactly."""
    ship_dict = fleet_lib.ship(fleet, index)
    if not ship_dict:
        return 0
    spare_slots = (fleet_lib.ship_stat(ship_dict, "armament_slots")
                   - _as_int(ship_dict.get("cannons", 0)))
    cargo_room = int(fleet_lib.free_capacity(ship_dict)
                     / CANNON_CARGO_UNITS)
    return max(0, min(spare_slots, cargo_room))


def refit_block_reason(fleet: list[Any], index: int, cannons: int, *,
                       gold: int = 0) -> str:
    """Why a refit of ``cannons`` is refused, as a ``ui_strings.json``
    key (``""`` = allowed). The UI disables the button and shows this as
    the tooltip (80-§4.7.2 "disabled with tooltip-reason")."""
    if not fleet_lib.ship(fleet, index):
        return "shipyard.no_selection"
    if cannons <= 0 or cannons > max_refit(fleet, index):
        return "shipyard.invalid_points"
    if gold < refit_cost(cannons):
        return "shipyard.no_gold"
    return ""


def can_refit(fleet: list[Any], index: int, cannons: int, *,
              gold: int = 0) -> bool:
    """§4.3: at least one cannon, within the slots/cargo cap,
    affordable."""
    return not refit_block_reason(fleet, index, cannons, gold=gold)


def refit(fleet: list[Any], index: int, cannons: int, *,
          gold: int = 0) -> TxResult:
    """§4.3 "Refit (armament)" — live in Phase 2 (80-§4.7.2); the battle
    effect is 60-§4.11.4. Adds ``cannons`` to the hull's count (they
    occupy ``cannons × 5`` hold units through the §4.2 maths); the caller
    pays ``gold_delta`` and charges the §4.1b two hours."""
    if not can_refit(fleet, index, cannons, gold=gold):
        return TxResult()
    ship_dict = fleet[index]
    ship_dict["cannons"] = _as_int(ship_dict.get("cannons", 0)) + cannons
    return TxResult(ok=True, gold_delta=-refit_cost(cannons))


# --- Equipment (Phase 2; 60-§4.11.12, 40-§4.3) ----------------------------------


def equipped_player(player: Any, slot: str) -> str:
    """60-§4.11.12: the item id worn in the player's ``slot`` ("" when
    empty/absent). Missing ``equipment`` blocks read as empty slots —
    never a crash."""
    if slot not in PLAYER_SLOTS:
        return ""
    return _slot_value(_player_equipment(player, False), slot)


def equipped_ship(fleet: list[Any], index: int, slot: str) -> str:
    """The item id worn in ``fleet[index]``'s ``slot`` ("" when
    empty/absent)."""
    if slot not in SHIP_SLOTS:
        return ""
    ship_dict = fleet_lib.ship(fleet, index)
    if not ship_dict:
        return ""
    return _slot_value(_ship_equipment(ship_dict, False), slot)


def equip_price(slot: str, equipment_id: str) -> int:
    """§4.3: the item's ``price`` (0 for an unknown item)."""
    return int(data().get_equipment(equipment_id).get("price", 0))


def equip_sellback(slot: str, equipment_id: str) -> int:
    """§4.3: ``floor(price × 0.5)`` when selling the item back."""
    return math.floor(float(equip_price(slot, equipment_id))
                      * EQUIP_SELL_FRACTION)


def equip_block_reason(player: Any, fleet: list[Any], slot: str,
                       equipment_id: str, ship_index: int = 0, *,
                       current_port: Any = "", gold: int = 0,
                       allegiance: AllegianceView | None = None) -> str:
    """Why buying ``equipment_id`` into ``slot`` is refused, as a
    ``ui_strings.json`` key (``""`` = allowed): an unknown item or a slot
    mismatch is ``ui.not_available``; a missing hull for a ship slot
    likewise; Phase 7 adds the stock gates — a rare item, an item not on
    this port's ``equipment_stock``, or a gray-state row
    (``ui.not_available`` / ``shipyard.tier.*`` note keys) — and finally
    an unaffordable net cost is ``shipyard.no_gold``.

    The net cost is ``−new_price + old_sellback`` (§4.3: the replaced
    item sells back "in the same action"), so replacing a 400g cutlass
    with a 1200g rapier only needs 1000g in the purse."""
    item = data().get_equipment(equipment_id)
    if not item or str(item.get("slot", "")) != slot:
        return "ui.not_available"
    if slot in SHIP_SLOTS and not fleet_lib.ship(fleet, ship_index):
        return "ui.not_available"
    port = _resolve_port("", current_port)
    if port:
        # Rare items are drop-only (60-§4.11.13) and never stocked; the
        # rare flag is checked first so a corrupt stock list cannot leak
        # one.
        if is_rare_equipment(equipment_id) \
                or equipment_id not in equipment_stock(port):
            return "ui.not_available"
        note = row_note_key(port, equipment_id, allegiance)
        if note:
            return note
    # The purse must survive the **net** delta, which is negative for a
    # normal buy and may even be positive when the replaced item is worth
    # more.
    if gold + equip_net_cost(player, fleet, slot, equipment_id,
                             ship_index) < 0:
        return "shipyard.no_gold"
    return ""


def equip_net_cost(player: Any, fleet: list[Any], slot: str,
                   equipment_id: str, ship_index: int = 0) -> int:
    """The gold change of :func:`equip`'s whole transaction:
    ``−new_price + old_sellback`` (§4.3, "in the same action")."""
    old_id = _worn_id(player, fleet, slot, ship_index)
    sellback = equip_sellback(slot, old_id) if old_id else 0
    return -equip_price(slot, equipment_id) + sellback


def equip(player: Any, fleet: list[Any], slot: str, equipment_id: str,
          ship_index: int = 0, *, current_port: Any = "", gold: int = 0,
          allegiance: AllegianceView | None = None) -> TxResult:
    """§4.3 "Buy equipment": buys ``equipment_id`` into ``slot``, selling
    whatever the slot held back at half price **in the same transaction**
    (one net ``gold_delta``, so the HUD sees one gold announcement).

    ``weapon``/``armor`` write ``player["equipment"]``;
    ``figurehead``/``sail`` write ``fleet[ship_index]["equipment"]``. The
    blocks are created when absent (60-§4.11.12: old saves default to
    empty slots). Returns ``ok=False`` without touching gold/state when
    blocked."""
    if equip_block_reason(player, fleet, slot, equipment_id, ship_index,
                          current_port=current_port, gold=gold,
                          allegiance=allegiance):
        return TxResult()
    block = _equipment_block(player, fleet, slot, ship_index, True)
    if not block:
        return TxResult()
    net = equip_net_cost(player, fleet, slot, equipment_id, ship_index)
    block[slot] = equipment_id
    _clamp_durability(slot, fleet, ship_index)
    return TxResult(ok=True, gold_delta=net)


def unequip(player: Any, fleet: list[Any], slot: str,
            ship_index: int = 0) -> TxResult:
    """Clears ``slot`` and pays the half-price sell-back (§4.3). Returns
    ``ok=False`` when the slot is already empty (nothing to do, nothing
    to pay). Unequipping never re-checks the local stock — the worn
    state, not where it was bought, is what sells back."""
    worn = _worn_id(player, fleet, slot, ship_index)
    if not worn:
        return TxResult()
    block = _equipment_block(player, fleet, slot, ship_index, False)
    if not block:
        return TxResult()
    block[slot] = ""
    _clamp_durability(slot, fleet, ship_index)
    return TxResult(ok=True, gold_delta=equip_sellback(slot, worn))


def can_unequip(player: Any, fleet: list[Any], slot: str,
                ship_index: int = 0) -> bool:
    """True when ``slot`` holds nothing (:func:`unequip` would be a
    no-op)."""
    return bool(_worn_id(player, fleet, slot, ship_index))


def equipment_modifier(equipment_id: str, stat_name: str) -> int:
    """A single modifier of one item (``0`` for an unknown item or
    stat)."""
    item = data().get_equipment(equipment_id)
    if not item:
        return 0
    modifiers = item.get("modifiers", {})
    if not isinstance(modifiers, dict):
        return 0
    return int(modifiers.get(stat_name, 0))


def player_combat_bonus(player: Any) -> int:
    """60-§4.11.6: the player's duel roll adds Σ ``combat`` across the
    two worn player items (``weapon`` + ``armor``). This is the duel-roll
    hook ``battle_sim`` reads."""
    total = 0
    for slot in PLAYER_SLOTS:
        total += equipment_modifier(equipped_player(player, slot), "combat")
    return total


def ship_speed_bonus(fleet: list[Any], index: int) -> int:
    """60-§4.11.12: the sail ``speed`` modifier (MP + initiative in
    60-§4.11.4)."""
    return equipment_modifier(equipped_ship(fleet, index, "sail"), "speed")


# --- Flagship promotion (§4.4) ---------------------------------------------------


def can_promote(fleet: list[Any], index: int, current_port: Any) -> bool:
    """§4.4: free, port-only, and only meaningful for a non-flagship
    row."""
    if not fleet_lib.at_port(current_port):
        return False
    return 0 < index < len(fleet)


def promote(fleet: list[Any], index: int, current_port: Any) -> bool:
    """§4.4 "Promote": moves ``fleet[index]`` to ``fleet[0]`` for free,
    preserving the relative order of every other ship. Returns False
    (fleet untouched) when :func:`can_promote` is false; the caller
    announces ``fleet_changed`` on True."""
    if not can_promote(fleet, index, current_port):
        return False
    ship_dict = fleet.pop(index)
    fleet.insert(0, ship_dict)
    return True


# --- Helpers ---------------------------------------------------------------


def _worn_id(player: Any, fleet: list[Any], slot: str,
             ship_index: int) -> str:
    """The id worn in ``slot`` on the player (weapon/armor) or on
    ``ship_index`` (figurehead/sail); "" for an unknown slot or
    empty/missing block."""
    if slot in PLAYER_SLOTS:
        return equipped_player(player, slot)
    if slot in SHIP_SLOTS:
        return equipped_ship(fleet, ship_index, slot)
    return ""


def _equipment_block(player: Any, fleet: list[Any], slot: str,
                     ship_index: int, create: bool) -> dict[str, Any]:
    """Reads the ``equipment`` block for ``slot``'s owner without
    creating anything (``create=False``)."""
    if slot in PLAYER_SLOTS:
        return _player_equipment(player, create)
    if slot in SHIP_SLOTS:
        ship_dict = fleet_lib.ship(fleet, ship_index)
        if not ship_dict:
            return {}
        return _ship_equipment(ship_dict, create)
    return {}


def _player_equipment(player: Any, create: bool) -> dict[str, Any]:
    """``player["equipment"]``, read-only unless ``create`` (then written
    in place when absent/invalid — 60-§4.11.12 "the accessors
    default")."""
    if not isinstance(player, dict):
        return {}
    block = player.get("equipment")
    if isinstance(block, dict):
        return block
    if not create:
        return {}
    fresh: dict[str, Any] = {"weapon": "", "armor": ""}
    player["equipment"] = fresh
    return fresh


def _ship_equipment(ship_dict: dict[str, Any],
                    create: bool) -> dict[str, Any]:
    """``ship.equipment``, same contract as :func:`_player_equipment`."""
    block = ship_dict.get("equipment")
    if isinstance(block, dict):
        return block
    if not create:
        return {}
    fresh: dict[str, Any] = {"figurehead": "", "sail": ""}
    ship_dict["equipment"] = fresh
    return fresh


def _slot_value(block: dict[str, Any], slot: str) -> str:
    """Tolerant slot read: a missing key, a null or a non-string all read
    as empty."""
    value = block.get(slot, "")
    return value if isinstance(value, str) else ""


def _clamp_durability(slot: str, fleet: list[Any], ship_index: int) -> None:
    """40-§4.1: "`durability` is clamped to" the effective max. Swapping
    or removing a figurehead can lower that cap, so the hull is clamped
    here — the only place equipment can shrink it. Equipping never
    *heals*: current durability is left where it was when the cap
    rises."""
    if slot not in SHIP_SLOTS or slot == "sail":
        return
    ship_dict = fleet_lib.ship(fleet, ship_index)
    if not ship_dict:
        return
    current = _as_int(ship_dict.get("durability", 0))
    maximum = ship_max_durability(fleet, ship_index)
    if current > maximum:
        ship_dict["durability"] = maximum


def _as_int(value: Any) -> int:
    """Tolerant numeric read (JSON floats, ints; anything else 0) — the
    same coercion contract as ``fleet.gd``'s ``_as_int`` (each oracle
    file carries its own helper; so does this port). Strings parse their
    leading integer literal, else 0 (GDScript ``String.to_int``)."""
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        digits = ""
        for position, char in enumerate(value):
            if char.isdigit() or (position == 0 and char in "+-"):
                digits += char
            else:
                break
        try:
            return int(digits)
        except ValueError:
            return 0
    return 0
