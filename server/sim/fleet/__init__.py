"""server.sim.fleet — the fleet-domain systems (M1).

Lands with M1, one module per Godot engine module under ``scripts/fleet/``
(docs/90-ARCHITECTURE.md §0.2):

    fleet.py   fleet composition + cargo-hold maths (fleet.gd) — the
               §4.1 ship-instance shape, the §4.2 hold maths and
               flagship-first distribution invariant, jettison and the
               load-time normalization guard.

The module's public surface is re-exported here, so ``server.sim.fleet``
answers exactly like the GDScript global ``Fleet`` class.
"""

from server.sim.fleet.fleet import (
    CANNON_CARGO_UNITS,
    FLEET_MAX,
    STAT_KEYS,
    SUPPLY_KINDS,
    add_goods,
    add_supplies,
    at_port,
    can_promote,
    flagship,
    fleet_capacity,
    fleet_free,
    free_capacity,
    held,
    hold_units,
    jettison_good,
    jettison_supplies,
    new_ship,
    normalize_all,
    promote,
    promote_block_reason,
    remove_goods,
    remove_supplies,
    ship,
    ship_stat,
    slowest_speed,
    supplies,
    total_crew,
    used_capacity,
)

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
    "hold_units",
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
    "normalize_all",
]
