"""server.sim.fleet.fleet — fleet composition and cargo-hold maths (M1).

Python port of ``scripts/fleet/fleet.gd`` (the frozen parity oracle until
the M6 cutover).

Normative sources:
  * docs/40-SHIPS-AND-FLEET.md §4.1 — the ship-instance schema (runtime +
    save shape; ``equipment`` absent in a Phase-1 save, every accessor
    defaults it to empty slots — the accessors live in
    :mod:`server.sim.port.shipyard`).
  * docs/40 §4.2 — the hold maths: ``used = Σ cargo + provisions + water +
    cannons × 5``, ``free = capacity − used``; the flagship-first
    distribution invariant ("``fleet[i]`` non-empty ⟹ ``fleet[0..i-1]``
    full") enforced by :func:`normalize_all`, which truncates any
    over-capacity hold (trade goods first in id order, then provisions,
    then water — supplies are survival resources) and then moves stranded
    units flagship-first.
  * docs/40 §4.4 — fleet composition: ``FLEET_MAX = 5``, the flagship is
    always ``fleet[0]``, all Phase-1 crew lives on the flagship, fleet
    speed uses the slowest hull.
  * docs/40 §6 — the load-time guards: integral JSON floats coerce to int
    silently (parse artifact, not a repair); fractional/negative/null
    values are repairs; unknown ``ship_type_id`` skips the capacity guard
    with a warning (never destroys a hold blind); non-dictionary fleet
    entries are reported, never silently deleted.
  * docs/20-WORLD-AND-SAILING.md §4.10 — jettison is per whole stack and
    frees capacity immediately (port-only in the UI; the rule itself is
    here).

Purity contract (M1): **pure functions over injected state** — the fleet
array is an injected ``list`` (the server's GameState port, a later wave,
owns the live fleet exactly like ``GameState.fleet`` did); every function
mutates/returns the ship dicts exactly as the GDScript statics did (same
keys, same defaults). Content lookups (ship types) read
:mod:`server.sim.data` exactly where the GDScript reads ``DataLoader``.

Deferred seams (NOT ported here, with the GDScript entry point):
  * ``notify_changed`` — ``EventBus.fleet_changed.emit()`` (docs/90 §5.1);
    callers emit after applying a mutation. The GDScript calls it inside
    ``jettison_good``/``jettison_supplies``/``normalize_all``/the
    promotion delegates; here the boolean/int return tells the caller
    whether something changed.
  * ``can_promote``/``promote`` — delegated to the shipyard engine
    (docs/40 §4.4 "the rule itself lives in
    ``ShipyardEngine.can_promote/promote``"); the Python delegates lazy-
    import :mod:`server.sim.port.shipyard` exactly like the GDScript
    lazy-loads it (a static preload cycle resolves neither side).
  * Storm durability damage and the §4.4 sink states (escort lost with
    her cargo, flagship-lost relocation, ``world.ship_lost`` /
    ``world.flagship_lost``) — SailingSim territory (docs/40 §4.5: only
    storms reduce durability at sea; repair is the only restore).
  * The §4.4 captain-less ``speed × 0.8`` scan and the §4.5 at-sea minor
    repair — the sailing module's ``effective_speed`` /
    ``at_sea_repair`` (they read the skills module and the fleet-day
    clock).
  * Jettison/prompt confirm dialogs — UI (docs/80 §4.5.1).
"""

from __future__ import annotations

import sys
from typing import Any, Final

from server.sim.data import data

__all__ = [
    "CANNON_CARGO_UNITS",
    "FLEET_MAX",
    "STAT_KEYS",
    "SUPPLY_KINDS",
    "new_ship",
    "flagship",
    "ship",
    "ship_stat",
    "used_capacity",
    "free_capacity",
    "fleet_capacity",
    "fleet_free",
    "total_crew",
    "slowest_speed",
    "held",
    "supplies",
    "add_goods",
    "remove_goods",
    "add_supplies",
    "remove_supplies",
    "at_port",
    "promote_block_reason",
    "can_promote",
    "promote",
    "jettison_good",
    "jettison_supplies",
    "hold_units",
    "normalize_all",
]

# --- Locked constants (docs/40 §4.2, §4.4) -----------------------------------

#: One cannon occupies this many cargo units (docs/40 §4.2).
CANNON_CARGO_UNITS: Final[int] = 5

#: Locked fleet size — also the shipyard Buy cap (docs/40 §4.4).
FLEET_MAX: Final[int] = 5

#: The ShipType stat keys the fleet maths reads.
STAT_KEYS: Final[tuple[str, ...]] = (
    "durability", "capacity", "speed", "crew_max", "armament_slots",
)

#: The two cargo-hold supply kinds (docs/40 §4.1: separate fields, both
#: occupy capacity 1 unit per unit; docs/20 §4.10).
SUPPLY_KINDS: Final[tuple[str, ...]] = ("provisions", "water")


# --- Ship instance (docs/40 §4.1) --------------------------------------------


def new_ship(ship_type_id: str, crew: int = 0) -> dict[str, Any]:
    """Creates a ship instance per docs/40 §4.1 with the §4.3 "buy ship"
    defaults: full durability, zero crew, no supplies, no cannons, empty
    hold. ``{}`` for an unknown type (a logged error, never a crash) —
    exactly the GDScript ``Fleet.new_ship``.

    The ``equipment`` block is deliberately absent (§4.1: absent in a
    Phase-1 save; every accessor defaults it to empty slots).
    """
    st = data().get_ship_type(ship_type_id)
    if not st:
        print(f"Fleet.new_ship: unknown ship_type_id '{ship_type_id}'",
              file=sys.stderr)
        return {}
    return {
        "ship_type_id": ship_type_id,
        "durability": int(st.get("durability", 0)),
        "crew": max(0, min(crew, int(st.get("crew_max", 0)))),
        "provisions": 0,
        "water": 0,
        "cannons": 0,
        "cargo": {},
    }


def flagship(fleet: list[Any]) -> dict[str, Any]:
    """The flagship is always ``fleet[0]`` (docs/40 §4.4); ``{}`` for an
    empty fleet or a non-dictionary lead entry (callers never crash)."""
    if not fleet or not isinstance(fleet[0], dict):
        return {}
    return fleet[0]


def ship(fleet: list[Any], index: int) -> dict[str, Any]:
    """``fleet[index]`` as a dict, or ``{}`` for an out-of-range index or a
    non-dictionary entry (the GDScript ``_ship`` helper — public here
    because the shipyard engine shares it)."""
    if index < 0 or index >= len(fleet):
        return {}
    entry = fleet[index]
    return entry if isinstance(entry, dict) else {}


def ship_stat(ship_dict: dict[str, Any], key: str) -> int:
    """One ShipType stat of the ship's hull (0 when the type or key is
    unknown — never a crash on a hand-edited save)."""
    st = data().get_ship_type(str(ship_dict.get("ship_type_id", "")))
    return int(st.get(key, 0))


# --- Hold maths (docs/40 §4.2) ------------------------------------------------


def used_capacity(ship_dict: dict[str, Any]) -> int:
    """``Σ cargo + provisions + water + cannons × 5`` (docs/40 §4.2).
    Defensive on missing/null fields and a non-dictionary ``cargo``
    (repo gotcha 5)."""
    used = (_as_int(ship_dict.get("provisions", 0))
            + _as_int(ship_dict.get("water", 0)))
    used += _as_int(ship_dict.get("cannons", 0)) * CANNON_CARGO_UNITS
    cargo = ship_dict.get("cargo", {})
    if isinstance(cargo, dict):
        for good_id in cargo:
            used += _as_int(cargo[good_id])
    return used


def free_capacity(ship_dict: dict[str, Any]) -> int:
    """``ShipType.capacity − used_capacity`` (docs/40 §4.2) — negative when
    a corrupted hold overflows (the load guard's business)."""
    return ship_stat(ship_dict, "capacity") - used_capacity(ship_dict)


def hold_units(ship_dict: dict[str, Any]) -> int:
    """Everything occupying a ship's hold — the §4.2 used capacity without
    the cannon term, i.e. trade goods + provisions + water. The sell rule
    consumes this so no pooled resource is ever dropped silently (docs/40
    §4.3/§6). Both ``fleet.gd`` and ``shipyard_engine.gd`` carry this as a
    private duplicate; the Python port keeps one implementation."""
    total = (_as_int(ship_dict.get("provisions", 0))
             + _as_int(ship_dict.get("water", 0)))
    cargo = ship_dict.get("cargo", {})
    if isinstance(cargo, dict):
        for good_id in cargo:
            total += max(0, _as_int(cargo[good_id]))
    return total


def fleet_capacity(fleet: list[Any]) -> int:
    """``Σ ShipType.capacity`` over the fleet (docs/40 §4.2 pooling)."""
    total = 0
    for entry in fleet:
        if isinstance(entry, dict):
            total += ship_stat(entry, "capacity")
    return total


def fleet_free(fleet: list[Any]) -> int:
    """``Σ free_capacity`` over the fleet — the market/capacity-check read
    (docs/40 §4.2, docs/30 §4.4)."""
    total = 0
    for entry in fleet:
        if isinstance(entry, dict):
            total += free_capacity(entry)
    return total


def total_crew(fleet: list[Any]) -> int:
    """Phase-1: all crew lives on the flagship (docs/40 §4.4) — the
    flagship's ``crew`` only (0 with no flagship)."""
    lead = flagship(fleet)
    return _as_int(lead.get("crew", 0)) if lead else 0


def slowest_speed(fleet: list[Any]) -> int:
    """The slowest hull's ``ShipType.speed`` (docs/40 §4.4 "Fleet speed =
    min(effective stats)"; the sailing sim composes its factors around
    this base). 0 for an empty/unknown fleet."""
    best = 0
    for entry in fleet:
        if not isinstance(entry, dict):
            continue
        speed = ship_stat(entry, "speed")
        if best == 0 or (speed > 0 and speed < best):
            best = speed
    return best


# --- Pooled holdings ---------------------------------------------------------


def held(fleet: list[Any], good_id: str) -> int:
    """Pooled holdings of one trade good across the fleet."""
    total = 0
    for entry in fleet:
        if not isinstance(entry, dict):
            continue
        cargo = entry.get("cargo", {})
        if isinstance(cargo, dict):
            total += _as_int(cargo.get(good_id, 0))
    return total


def supplies(fleet: list[Any], kind: str) -> int:
    """Pooled provisions or water (``kind`` ∈ :data:`SUPPLY_KINDS`)."""
    total = 0
    for entry in fleet:
        if isinstance(entry, dict):
            total += _as_int(entry.get(kind, 0))
    return total


# --- Cargo mutations (flagship-first distribution, docs/40 §4.2) --------------
#
# The GDScript statics index ``ship["cargo"]`` directly (trusting the
# §4.1 shape :func:`new_ship` builds; :func:`normalize_all` is the repair
# point for anything else). Mirrored verbatim.


def add_goods(fleet: list[Any], good_id: str, qty: int) -> int:
    """Adds goods flagship-first, then in fleet order, up to free capacity.
    Returns the quantity actually stored (docs/40 §4.2 distribution rule)
    — an over-add clamps to the pooled free space."""
    remaining = max(qty, 0)
    for entry in fleet:
        if remaining <= 0:
            break
        room = min(remaining, free_capacity(entry))
        if room <= 0:
            continue
        cargo = entry["cargo"]
        cargo[good_id] = _as_int(cargo.get(good_id, 0)) + room
        remaining -= room
    return max(qty, 0) - remaining


def remove_goods(fleet: list[Any], good_id: str, qty: int) -> int:
    """Removes goods flagship-first, then in fleet order. Returns the
    quantity actually removed — removing more than held removes exactly
    the held amount (never negative), erasing emptied stacks."""
    remaining = max(qty, 0)
    for entry in fleet:
        if remaining <= 0:
            break
        cargo = entry["cargo"]
        have = _as_int(cargo.get(good_id, 0))
        if have <= 0:
            continue
        take = min(remaining, have)
        if have - take == 0:
            del cargo[good_id]
        else:
            cargo[good_id] = have - take
        remaining -= take
    return max(qty, 0) - remaining


def add_supplies(fleet: list[Any], kind: str, qty: int) -> int:
    """Adds provisions or water flagship-first. Returns the quantity
    actually stored."""
    remaining = max(qty, 0)
    for entry in fleet:
        if remaining <= 0:
            break
        room = min(remaining, free_capacity(entry))
        if room <= 0:
            continue
        entry[kind] = _as_int(entry.get(kind, 0)) + room
        remaining -= room
    return max(qty, 0) - remaining


def remove_supplies(fleet: list[Any], kind: str, qty: int) -> int:
    """Removes provisions or water flagship-first. Returns the quantity
    removed."""
    remaining = max(qty, 0)
    for entry in fleet:
        if remaining <= 0:
            break
        have = _as_int(entry.get(kind, 0))
        if have <= 0:
            continue
        take = min(remaining, have)
        entry[kind] = have - take
        remaining -= take
    return max(qty, 0) - remaining


# --- Fleet panel actions (docs/40 §4.4, §6; docs/20 §4.10) --------------------


def at_port(current_port: Any) -> bool:
    """True while docked (docs/40 §4.4: promotion is a port action;
    ``current_port`` is null/empty at sea, docs/90 §5.4)."""
    return isinstance(current_port, str) and bool(current_port)


def promote_block_reason(current_port: Any, fleet_size: int,
                         index: int) -> str:
    """Why promoting ``fleet[index]`` is refused, as a ``ui_strings.json``
    key (``""`` = allowed). Promotion is free and port-only, and the
    flagship is already ``fleet[0]`` (docs/40 §4.4). Like every engine
    here it returns the **key**, not text (docs/80 §6)."""
    if not at_port(current_port):
        return "fleet.port_only"
    if index <= 0 or index >= fleet_size:
        return "ui.not_available"
    return ""


def can_promote(fleet: list[Any], index: int, current_port: Any) -> bool:
    """§4.4: free, port-only, non-flagship row. Delegates to the shipyard
    engine so the rule exists once (shipyard screen + fleet panel share
    it) — the lazy import mirrors the GDScript lazy ``load()`` that breaks
    the ``shipyard_engine.gd`` ⇄ ``fleet.gd`` preload cycle."""
    from server.sim.port import shipyard

    return shipyard.can_promote(fleet, index, current_port)


def promote(fleet: list[Any], index: int, current_port: Any) -> bool:
    """§4.4 "Promote": ``fleet[index]`` becomes the flagship for free;
    every other ship keeps its relative order. Delegates to the shipyard
    engine (see :func:`can_promote`)."""
    from server.sim.port import shipyard

    return shipyard.promote(fleet, index, current_port)


def jettison_good(fleet: list[Any], ship_index: int, good_id: str) -> int:
    """Drops the **whole** trade-good stack ``good_id`` from
    ``fleet[ship_index]`` (docs/20 §4.10: jettison is per stack, freeing
    capacity immediately). Returns the units removed (0 for an unknown
    ship/good, never negative); the caller announces the change when the
    return is > 0 (the deferred ``fleet_changed`` seam)."""
    entry = ship(fleet, ship_index)
    if not entry or not good_id:
        return 0
    cargo = _cargo(entry)
    have = _as_int(cargo.get(good_id, 0))
    if good_id in cargo:
        del cargo[good_id]
    return have if have > 0 else 0


def jettison_supplies(fleet: list[Any], ship_index: int, kind: str) -> int:
    """Drops the whole provisions or water stack of ``fleet[ship_index]``
    (``kind`` ∈ :data:`SUPPLY_KINDS`, docs/20 §4.10). Returns the units
    removed (0 for an unknown kind — refused, never a crash)."""
    if kind not in SUPPLY_KINDS:
        print(f"Fleet.jettison_supplies: unknown kind '{kind}'",
              file=sys.stderr)
        return 0
    entry = ship(fleet, ship_index)
    if not entry:
        return 0
    have = _as_int(entry.get(kind, 0))
    entry[kind] = 0
    return have if have > 0 else 0


# --- Load-time guard (docs/40 §4.2, §6) ---------------------------------------


def normalize_all(fleet: Any) -> bool:
    """Repairs the fleet to the §4.2 distribution invariant and truncates
    any over-capacity hold, as ``SaveSystem`` does after deserialization
    (docs/40 §6 "Capacity invariant violation found at load → logs and
    truncates cargo to fit").

    Invariants enforced, in this order:
      1. every numeric hold field is a non-negative int, every ``cargo``
         a dict (JSON may hand us floats, nulls or missing keys — repo
         gotchas 1/5);
      2. ``used_capacity(ship) <= ShipType.capacity`` — excess is dropped
         and **logged** (trade goods first, in id order, then supplies),
         so the player keeps the survival resources as long as possible;
      3. flagship-first distribution: ``fleet[i]`` may only be non-empty
         while every earlier hull is full; stranded units move
         flagship-first.

    Returns ``True`` when anything was truncated or repaired (the caller
    logs/announces it), ``False`` when the fleet was already valid. Safe
    on an empty fleet, a single ship, unknown ship types and
    non-dictionary entries (logged, never a crash, never a silent
    deletion). The GDScript also emits ``fleet_changed`` when it repaired
    something — deferred here to the caller (EventBus seam).
    """
    if not isinstance(fleet, list):
        print("Fleet.normalize_all: fleet is not an Array; "
              "nothing to normalise", file=sys.stderr)
        return False
    repaired = False
    for index in range(len(fleet)):
        if not isinstance(fleet[index], dict):
            print(f"Fleet.normalize_all: fleet[{index}] is not a ship "
                  "instance; skipped", file=sys.stderr)
            repaired = True
            continue
        ship_dict: dict[str, Any] = fleet[index]
        if _normalize_fields(ship_dict, index):
            repaired = True
        if _truncate_to_capacity(ship_dict, index):
            repaired = True
    if _normalize_distribution(fleet):
        repaired = True
    return repaired


def _normalize_fields(ship_dict: dict[str, Any], index: int) -> bool:
    """Coerces the hold fields of ``ship`` (``fleet[index]``) to
    non-negative ints and ``cargo`` to a dict. Returns True when a value
    had to be **repaired** (truncated, clamped, dropped or replaced).

    JSON numbers arrive as floats, and ``45.0`` is exactly what a save
    holds for ``45``: converting an integral float to int is a silent
    shape fix, *not* a repair — otherwise every healthy loaded save would
    report "normalised". A fractional value (``45.7``) *is* a repair."""
    repaired = False
    for key in ("provisions", "water", "cannons"):
        if key not in ship_dict:
            # Missing field = 0 (gotcha 5). The schema says it must exist,
            # so this is a repair worth reporting, but it changes no
            # numbers.
            ship_dict[key] = 0
            print(f"Fleet.normalize_all: fleet[{index}] had no '{key}'; "
                  "set to 0", file=sys.stderr)
            repaired = True
            continue
        raw = ship_dict[key]
        value = _as_int(raw)
        if not _is_number(raw):
            ship_dict[key] = value
            print(f"Fleet.normalize_all: fleet[{index}].{key} was {raw!r}; "
                  f"coerced to {value}", file=sys.stderr)
            repaired = True
        elif value < 0:
            ship_dict[key] = 0
            print(f"Fleet.normalize_all: fleet[{index}].{key} was {value}; "
                  "clamped to 0", file=sys.stderr)
            repaired = True
        elif float(value) != float(raw):
            ship_dict[key] = value
            print(f"Fleet.normalize_all: fleet[{index}].{key} was {raw!r}; "
                  f"truncated to {value}", file=sys.stderr)
            repaired = True
        elif isinstance(raw, float):
            ship_dict[key] = value  # 45.0 -> 45, silently (JSON parse artifact)

    if "cargo" in ship_dict and not isinstance(ship_dict["cargo"], dict):
        print(f"Fleet.normalize_all: fleet[{index}].cargo was "
              f"{ship_dict['cargo']!r}; replaced with {{}}", file=sys.stderr)
        ship_dict["cargo"] = {}
        repaired = True
    elif "cargo" not in ship_dict:
        ship_dict["cargo"] = {}
        print(f"Fleet.normalize_all: fleet[{index}] had no 'cargo'; "
              "set to {}", file=sys.stderr)
        repaired = True

    cargo: dict[str, Any] = ship_dict["cargo"]
    for good_id in list(cargo.keys()):
        raw_qty = cargo[good_id]
        qty = _as_int(raw_qty)
        if qty == 0 and (isinstance(raw_qty, int)
                         or (isinstance(raw_qty, float) and raw_qty == 0.0)):
            # An explicit 0 carries no units: drop it silently (gotcha 5).
            # It is a shape cleanup, not a repair — a valid save may
            # contain one.
            del cargo[good_id]
            continue
        if qty <= 0:
            del cargo[good_id]
            print(f"Fleet.normalize_all: fleet[{index}] carried "
                  f"{raw_qty!r} of '{good_id}'; dropped", file=sys.stderr)
            repaired = True
            continue
        if not _is_number(raw_qty):
            cargo[good_id] = qty
            print(f"Fleet.normalize_all: fleet[{index}].cargo['{good_id}'] "
                  f"was {raw_qty!r}; coerced to {qty}", file=sys.stderr)
            repaired = True
        elif float(qty) != float(raw_qty):
            cargo[good_id] = qty
            print(f"Fleet.normalize_all: fleet[{index}].cargo['{good_id}'] "
                  f"was {raw_qty!r}; truncated to {qty}", file=sys.stderr)
            repaired = True
        elif isinstance(raw_qty, float):
            cargo[good_id] = qty  # 30.0 -> 30, silently (JSON parse artifact)
    return repaired


def _truncate_to_capacity(ship_dict: dict[str, Any], index: int) -> bool:
    """§4.2/§6 truncation guard: drops hold units until
    ``used_capacity(ship) <= ShipType.capacity``. Trade goods go first
    (in id order), then provisions, then water — supplies are survival
    resources, so they are the last thing a corrupt save loses. Every
    drop is logged with the ship index. Returns True when anything was
    dropped (verbatim: whenever the hold measured over capacity — the
    cannon term is *reported* but not truncated; cannons are refit-gated,
    never hold-truncated, exactly like the oracle)."""
    ship_type_id = str(ship_dict.get("ship_type_id", ""))
    capacity = ship_stat(ship_dict, "capacity")
    if capacity <= 0:
        # An unknown/missing hull has no known capacity: dropping the
        # whole hold to fit 0 would destroy resources the player may
        # still recover from an otherwise readable save. Log loudly and
        # leave it alone (§6 guard).
        if not data().get_ship_type(ship_type_id):
            print(f"Fleet.normalize_all: fleet[{index}] has unknown "
                  f"ship_type_id '{ship_type_id}'; capacity guard skipped",
                  file=sys.stderr)
        return False
    over = used_capacity(ship_dict) - capacity
    if over <= 0:
        return False
    print(f"Fleet.normalize_all: fleet[{index}] ({ship_type_id}) holds "
          f"{used_capacity(ship_dict)} units in a {capacity}-unit hold; "
          f"truncating {over}", file=sys.stderr)

    cargo = _cargo(ship_dict)
    for good_id in _sorted_keys(cargo):
        if over <= 0:
            break
        have = _as_int(cargo.get(good_id, 0))
        if have <= 0:
            continue
        take = min(have, over)
        if have - take <= 0:
            del cargo[good_id]
        else:
            cargo[good_id] = have - take
        over -= take
        print(f"Fleet.normalize_all: fleet[{index}] dropped {take} "
              f"'{good_id}' (over capacity)", file=sys.stderr)

    for kind in SUPPLY_KINDS:
        if over <= 0:
            break
        have = _as_int(ship_dict.get(kind, 0))
        if have <= 0:
            continue
        take = min(have, over)
        ship_dict[kind] = have - take
        over -= take
        print(f"Fleet.normalize_all: fleet[{index}] dropped {take} "
              f"'{kind}' (over capacity)", file=sys.stderr)
    return True


def _normalize_distribution(fleet: list[Any]) -> bool:
    """§4.2 distribution invariant: ``fleet[i]`` non-empty ⟹
    ``fleet[0..i-1]`` full. Walks the fleet flagship-first and moves
    stranded units into earlier free room (goods first, then
    provisions/water), leaving whatever the earlier hulls cannot take
    where it is — after which every earlier hull is full, so the
    invariant holds. Returns True when anything moved."""
    repaired = False
    for index in range(1, len(fleet)):
        if not isinstance(fleet[index], dict):
            continue
        ship_dict: dict[str, Any] = fleet[index]
        held_units = hold_units(ship_dict)
        if held_units <= 0:
            continue
        moved = 0
        for target_index in range(index):
            if not isinstance(fleet[target_index], dict):
                continue
            moved += _move_hold(fleet[target_index], ship_dict,
                                free_capacity(fleet[target_index]))
            if hold_units(ship_dict) <= 0:
                break
        if moved <= 0:
            continue
        repaired = True
        print(f"Fleet.normalize_all: fleet[{index}] held {held_units} units "
              f"while earlier hulls had room; moved {moved} flagship-first, "
              f"{hold_units(ship_dict)} left", file=sys.stderr)
    return repaired


def _move_hold(target: dict[str, Any], source: dict[str, Any],
               room: int) -> int:
    """Moves up to ``room`` units of ``source``'s hold into ``target``
    (goods first, then provisions/water). Returns the units moved."""
    moved = 0
    if room <= 0:
        return 0
    source_cargo = _cargo(source)
    target_cargo = _cargo(target)
    for good_id in _sorted_keys(source_cargo):
        if room <= 0:
            break
        have = _as_int(source_cargo.get(good_id, 0))
        if have <= 0:
            continue
        take = min(have, room)
        if have - take <= 0:
            del source_cargo[good_id]
        else:
            source_cargo[good_id] = have - take
        target_cargo[good_id] = _as_int(target_cargo.get(good_id, 0)) + take
        room -= take
        moved += take
    for kind in SUPPLY_KINDS:
        if room <= 0:
            break
        have = _as_int(source.get(kind, 0))
        if have <= 0:
            continue
        take = min(have, room)
        source[kind] = have - take
        target[kind] = _as_int(target.get(kind, 0)) + take
        room -= take
        moved += take
    return moved


# --- Helpers ---------------------------------------------------------------


def _cargo(ship_dict: dict[str, Any]) -> dict[str, Any]:
    """The ship's ``cargo`` dict, created in place when missing/invalid."""
    cargo = ship_dict.get("cargo", {})
    if not isinstance(cargo, dict):
        cargo = {}
        ship_dict["cargo"] = cargo
    return cargo


def _sorted_keys(mapping: dict[str, Any]) -> list[str]:
    """Deterministic id order for truncation/transfer decisions."""
    return sorted(mapping.keys(), key=str)


def _is_number(value: Any) -> bool:
    """JSON-number check (bool is an int subtype in Python but a distinct
    type in GDScript — the oracle routes ``TYPE_BOOL`` down the repair
    path, so it must not count as a number here)."""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _as_int(value: Any) -> int:
    """Safe numeric coercion, mirroring the GDScript ``_as_int``: JSON
    floats/ints and numeric strings only; anything else (null, bool,
    dict…) becomes 0 so no comparison ever crashes (repo gotcha 1).
    ``int()`` truncates toward zero in both languages."""
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        return _str_to_int(value)
    return 0


def _str_to_int(text: str) -> int:
    """GDScript ``String.to_int`` semantics: the leading integer literal,
    else 0 (``"12x"`` → 12, ``"abc"`` → 0)."""
    digits = ""
    for position, char in enumerate(text):
        if char.isdigit() or (position == 0 and char in "+-"):
            digits += char
        else:
            break
    try:
        return int(digits)
    except ValueError:
        return 0
