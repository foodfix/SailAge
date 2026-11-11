"""server.tests.test_fleet — the fleet + shipyard parity suite (M1).

Port of the guarantee, not the method (AGENTS.md test discipline): the
GDScript harnesses (``tools/test_fleet.gd`` T18, ``tools/test_shipyard.gd``
T13, and the equipment sections of ``tools/test_equipment.gd``) boot a run
and walk the autoloads; here the same pinned contracts are asserted as pure
functions over injected state on the real shipped ``data/`` tree (loaded
through :mod:`server.sim.data`).

Pinned contracts (oracles: ``scripts/fleet/fleet.gd`` +
``scripts/port/shipyard_engine.gd``; docs/40-SHIPS-AND-FLEET.md §4.1–§4.5,
§5, §6, §7; docs/60-COMBAT.md §4.11.12/§4.11.13; docs/80-UI-UX.md §4.7.12):
  * the §4.1 ship-instance schema defaults (full-durability, zero-crew,
    empty-hold buy shape; no ``equipment`` block in a Phase-1 instance);
  * the §4.2 hold maths — ``Σ cargo + provisions + water + cannons × 5``
    (both §5 worked loadouts measure exactly 120/120 on the caravel),
    fleet pooling, the flagship-first add/remove distribution with
    over-add clamped to free space and over-remove refusing past held;
  * the §4.2/§6 load-time guard — the §5 valid loadout passes untouched,
    JSON round-trips need no repair (integral floats coerce silently),
    over-capacity holds truncate goods-first-supplies-last, stranded
    escort holds move flagship-first, and the degenerate shapes (nulls,
    fractional floats, negatives, non-dict entries, unknown hulls) are
    repaired, never crashes and never silent deletions;
  * §4.4 promotion — free, port-only, order-preserving, delegated to the
    shipyard engine;
  * §4.3 repair pricing — ``ceil(base_price/400)`` for all 16 hulls (the
    doc's 3/20/55/150 worked values, the ceiling cases 8/38/100), the
    damage/gold caps, the partial-repair mutation, the Phase-8 discount
    composition (count-title ×0.8 then the carpenter factor, floored once
    — nao 1 point at carpentry 41 = 53g);
  * §4.3 sell pricing — ``floor(base × 0.5 × dur/max)`` (4000/2000/30000
    worked values), the flagship/last-ship/loaded-hold refusals with the
    §4.2 pooled-hold gate covering supplies;
  * §4.3 buy — the §4.3 defaults, FLEET_MAX 5, the per-port stock lists
    under the §4.3.1 tier gate with the three §4.7.12 row states
    (available / tier-gray / allegiance-gray), the allegiance guard
    defaults and the injectable allegiance view;
  * §4.3 refit — 100g/50g/5-unit cannon maths, caps at
    ``min(armament_slots, capacity/5)``, hold room binding;
  * the 60-§4.11.12 equipment rules — tolerant accessors, prices and
    ``floor(price × 0.5)`` sell-back, the same-action replace net cost,
    the stock/tier gates, the figurehead effective max (repairs onto it,
    removal clamps down) and the sail speed hook, the §4.11.6 duel bonus.

Deterministic — no RNG, no Monte Carlo, no engine boots. Every number is
either a GDScript pin or the closed-form value of a §4.x formula on
shipped data.

Deferred seams (asserted as the injected contract, not the autoload
reads): EventBus announcements, the gold mutation, the §4.1b facility
window + hour charges (the sailing module), the Fame title factor and the
SailingSim carpenter factor (injected multipliers), and the allegiance
view (``None`` = the authored-data guard default).
"""

from __future__ import annotations

import json
import math
from copy import deepcopy
from typing import Any

import pytest

from server.sim import fleet as fleet_lib
from server.sim.data import data
from server.sim.port import shipyard

# docs/40 §5: the starter caravel loadout for the Seville hop
# ("45+45+30=120 = ShipType.capacity").
CARGO_CAPACITY = 120
DOC_PROVISIONS = 45
DOC_WATER = 45
DOC_WINE = 30

# tools/test_shipyard.gd §4.3 pins ("latin 3g/pt, caravel 20g/pt, nao
# 55g/pt, galleon 150g/pt").
DOC_REPAIR_PRICES = {"latin": 3, "caravel": 20, "nao": 55, "galleon": 150}

# Lisbon's locked stock list (ports.json, P-authored) — the dev-3 capital.
LISBON_STOCK = ["latin", "sloop", "pinnace", "caravel", "caravela_redonda",
                "nao", "carrack", "galleon"]

# The four unallied neutral shipyard ports (correction 11's allegiance-gray
# state): nationless ports at dev floor 0.
UNALLIED_NEUTRAL_SHIPYARDS = ["quanzhou", "hirado", "sakai", "gresik"]


# --- Fixtures ---------------------------------------------------------------


def fleet_of(*ship_ids: str) -> list[dict[str, Any]]:
    """A fleet of fresh §4.3-default hulls (the ``_make_fleet`` fixture)."""
    return [fleet_lib.new_ship(ship_id, 0) for ship_id in ship_ids]


def player_block() -> dict[str, Any]:
    """A Phase-8-shaped player block with NO ``equipment`` (an old save
    shape), so the accessors' tolerance is exercised first."""
    return {"nation_id": "portugal", "xp": 0, "level": 1,
            "reputation": {"portugal": 0}}


def doc_loadout_ship() -> dict[str, Any]:
    """The §5 starter caravel (crew 15, 45 provisions, 45 water, 30 wine)."""
    ship = fleet_lib.new_ship("caravel", 15)
    ship["provisions"] = DOC_PROVISIONS
    ship["water"] = DOC_WATER
    ship["cargo"] = {"wine": DOC_WINE}
    return ship


class FixtureAllegiance:
    """A standing-in allegiance view (the §4.16 guard seam): every port
    reads dev 2 / portugal — the tools/test_shipyard.gd fixture answers."""

    def dev(self, port_id: str) -> int:
        return 2

    def effective_alignment(self, port_id: str) -> str:
        return "portugal"


def same_set(a: list[str], b: list[str]) -> bool:
    return sorted(a) == sorted(b)


# --- 1. §4.1 ship-instance schema (defaults on a hand-built ship) -----------


def test_new_ship_defaults_are_the_buy_shape() -> None:
    ship = fleet_lib.new_ship("caravel")
    assert ship == {
        "ship_type_id": "caravel",
        "durability": 90,
        "crew": 0,
        "provisions": 0,
        "water": 0,
        "cannons": 0,
        "cargo": {},
    }
    # §4.1: `equipment` is absent in a Phase-1 instance; accessors default.
    assert "equipment" not in ship
    assert fleet_lib.used_capacity(ship) == 0


def test_new_ship_crew_clamps_to_crew_max() -> None:
    assert fleet_lib.new_ship("caravel", 15)["crew"] == 15
    assert fleet_lib.new_ship("latin", 999)["crew"] == 20  # crew_max
    assert fleet_lib.new_ship("latin", -5)["crew"] == 0


def test_new_ship_unknown_type_is_empty_never_crash() -> None:
    assert fleet_lib.new_ship("ghost_ship") == {}


def test_schema_ship_hold_maths_on_a_hand_built_ship() -> None:
    """The §4.1 schema example: provisions + water + the cargo object all
    count against capacity (the cannon term adds cannons × 5)."""
    ship = {
        "ship_type_id": "caravel",
        "durability": 90,
        "crew": 15,
        "provisions": 60,
        "water": 60,
        "cannons": 0,
        "cargo": {"wine": 40, "salt": 10},
    }
    assert fleet_lib.used_capacity(ship) == 170  # 60 + 60 + 40 + 10
    assert fleet_lib.free_capacity(ship) == 120 - 170  # negative is legal
    ship["cannons"] = 2
    assert fleet_lib.used_capacity(ship) == 180  # + cannons × 5


def test_missing_and_null_fields_read_as_zero() -> None:
    ship: dict[str, Any] = {"ship_type_id": "caravel"}
    assert fleet_lib.used_capacity(ship) == 0
    ship["provisions"] = None
    ship["cargo"] = None
    assert fleet_lib.used_capacity(ship) == 0  # non-dict cargo ignored
    assert fleet_lib.free_capacity(ship) == 120


# --- 2. §4.2 hold maths: the §5 worked loadouts ------------------------------


def test_doc_valid_loadout_measures_120_of_120() -> None:
    ship = doc_loadout_ship()
    assert fleet_lib.used_capacity(ship) == CARGO_CAPACITY
    assert fleet_lib.free_capacity(ship) == 0
    # The second §5 example (crew-light storm dash, 60+60, empty hold).
    dash = fleet_lib.new_ship("caravel", 8)
    dash["provisions"] = 60
    dash["water"] = 60
    assert fleet_lib.used_capacity(dash) == CARGO_CAPACITY


def test_fleet_pooling_sums_both_hulls() -> None:
    fleet = fleet_of("caravel", "latin")
    assert fleet_lib.fleet_capacity(fleet) == 150  # 120 + 30
    assert fleet_lib.fleet_free(fleet) == 150
    fleet[0]["provisions"] = 12
    fleet[0]["water"] = 8
    fleet[0]["cargo"] = {"wine": 30}
    fleet[1]["cargo"] = {"salt": 10}
    assert fleet_lib.fleet_free(fleet) == 150 - 50 - 10
    assert fleet_lib.held(fleet, "wine") == 30
    assert fleet_lib.held(fleet, "silk") == 0
    assert fleet_lib.supplies(fleet, "provisions") == 12
    assert fleet_lib.supplies(fleet, "water") == 8


def test_total_crew_is_the_flagships_crew_only() -> None:
    fleet = fleet_of("caravel", "latin")
    fleet[0]["crew"] = 15
    fleet[1]["crew"] = 7  # Phase 1: escorts need no crew (§4.4)
    assert fleet_lib.total_crew(fleet) == 15
    assert fleet_lib.total_crew([]) == 0


def test_slowest_speed_is_the_fleet_base() -> None:
    assert fleet_lib.slowest_speed(fleet_of("caravel", "galley")) == 20
    assert fleet_lib.slowest_speed(fleet_of("galley", "latin")) == 16
    assert fleet_lib.slowest_speed(fleet_of("latin")) == 16
    assert fleet_lib.slowest_speed([]) == 0


def test_latin_real_data_fields_through_the_module() -> None:
    """Real-data observation: the latin-sloop's locked fields, computed
    through server.sim.data (docs/10 §7.3: dur 40, cap 30, spd 16,
    crew 8/20, slots 2, price 1,200g)."""
    ship = fleet_lib.new_ship("latin", 5)
    assert fleet_lib.ship_stat(ship, "durability") == 40
    assert fleet_lib.ship_stat(ship, "capacity") == 30
    assert fleet_lib.ship_stat(ship, "speed") == 16
    assert fleet_lib.ship_stat(ship, "crew_max") == 20
    assert fleet_lib.ship_stat(ship, "armament_slots") == 2
    assert ship["durability"] == 40
    ship["cargo"] = {"wine": 20}
    assert fleet_lib.used_capacity(ship) == 20
    assert fleet_lib.free_capacity(ship) == 10
    assert shipyard.buy_price("latin") == 1200
    assert shipyard.repair_cost_per_point("latin") == 3


# --- 3. add/remove clamps (flagship-first distribution) ----------------------


def test_add_goods_clamps_to_free_space() -> None:
    fleet = fleet_of("latin")
    assert fleet_lib.add_goods(fleet, "wine", 40) == 30  # over-add clamps
    assert fleet[0]["cargo"] == {"wine": 30}
    assert fleet_lib.add_goods(fleet, "wine", 5) == 0


def test_add_goods_fills_flagship_first_then_in_order() -> None:
    fleet = fleet_of("latin", "caravel")
    assert fleet_lib.add_goods(fleet, "wine", 100) == 100
    assert fleet[0]["cargo"]["wine"] == 30  # the latin fills first
    assert fleet[1]["cargo"]["wine"] == 70
    assert fleet_lib.held(fleet, "wine") == 100
    assert fleet_lib.add_goods(fleet, "wine", 50) == 50  # escort has room
    assert fleet_lib.add_goods(fleet, "wine", 1) == 0    # both full


def test_add_goods_zero_and_negative_store_nothing() -> None:
    fleet = fleet_of("latin")
    assert fleet_lib.add_goods(fleet, "wine", 0) == 0
    assert fleet_lib.add_goods(fleet, "wine", -8) == 0
    assert fleet[0]["cargo"] == {}


def test_remove_more_than_held_returns_the_held_exact_result() -> None:
    fleet = fleet_of("latin")
    fleet[0]["cargo"] = {"wine": 30}
    # The GDScript result: remove exactly what is held, erase the stack.
    assert fleet_lib.remove_goods(fleet, "wine", 99) == 30
    assert "wine" not in fleet[0]["cargo"]
    assert fleet_lib.held(fleet, "wine") == 0
    assert fleet_lib.remove_goods(fleet, "wine", 10) == 0  # nothing held


def test_remove_goods_drains_flagship_first() -> None:
    fleet = fleet_of("latin", "caravel")
    fleet[0]["cargo"] = {"wine": 30}
    fleet[1]["cargo"] = {"wine": 70}
    assert fleet_lib.remove_goods(fleet, "wine", 50) == 50
    assert "wine" not in fleet[0]["cargo"]  # flagship drained to zero
    assert fleet[1]["cargo"]["wine"] == 50  # escort paid the rest


def test_supplies_blocked_by_a_full_hold_then_freed_by_jettison() -> None:
    fleet = fleet_of("caravel")
    fleet[0]["cargo"] = {"wine": CARGO_CAPACITY}
    assert fleet_lib.add_supplies(fleet, "provisions", 10) == 0
    assert fleet_lib.jettison_good(fleet, 0, "wine") == CARGO_CAPACITY
    assert fleet_lib.add_supplies(fleet, "provisions", 10) == 10
    assert fleet[0]["provisions"] == 10


def test_supplies_distribute_and_remove_clamps() -> None:
    fleet = fleet_of("latin", "latin")
    assert fleet_lib.add_supplies(fleet, "water", 40) == 40
    assert fleet[0]["water"] == 30  # flagship first
    assert fleet[1]["water"] == 10
    assert fleet_lib.supplies(fleet, "water") == 40
    assert fleet_lib.remove_supplies(fleet, "water", 99) == 40
    assert fleet[0]["water"] == 0 and fleet[1]["water"] == 0


# --- 4. Jettison (docs/20 §4.10 pins from tools/test_fleet.gd §6) ------------


def test_jettison_good_drops_the_whole_stack() -> None:
    fleet = fleet_of("caravel")
    ship = fleet[0]
    ship["provisions"] = 20
    ship["water"] = 15
    ship["cargo"] = {"wine": 40, "salt": 10}
    free_before = fleet_lib.fleet_free(fleet)
    assert free_before == CARGO_CAPACITY - 20 - 15 - 50
    assert fleet_lib.jettison_good(fleet, 0, "wine") == 40
    assert "wine" not in ship["cargo"]
    assert ship["cargo"]["salt"] == 10  # untouched by the wine jettison
    assert fleet_lib.fleet_free(fleet) == free_before + 40
    # Clamps at 0: an absent or unknown stack removes nothing.
    assert fleet_lib.jettison_good(fleet, 0, "wine") == 0
    assert fleet_lib.fleet_free(fleet) == free_before + 40
    assert fleet_lib.jettison_good(fleet, 0, "unknown_good") == 0


def test_jettison_supplies_zeroes_the_stack() -> None:
    fleet = fleet_of("caravel")
    ship = fleet[0]
    ship["provisions"] = 20
    ship["water"] = 15
    ship["cargo"] = {"salt": 10}
    assert fleet_lib.jettison_supplies(fleet, 0, "water") == 15
    assert ship["water"] == 0  # zeroed, never negative
    assert fleet_lib.jettison_supplies(fleet, 0, "provisions") == 20
    assert ship["provisions"] == 0
    assert fleet_lib.fleet_free(fleet) == CARGO_CAPACITY - 10
    assert fleet_lib.jettison_supplies(fleet, 0, "water") == 0  # no-op
    assert fleet_lib.jettison_supplies(fleet, 0, "rum") == 0  # unknown kind


def test_jettison_targets_the_requested_ship_only() -> None:
    fleet = fleet_of("caravel", "caravel")
    fleet[0]["cargo"] = {"wine": CARGO_CAPACITY}
    fleet[1]["cargo"] = {"salt": 30}
    assert fleet_lib.jettison_good(fleet, 1, "salt") == 30
    assert fleet_lib.held(fleet, "salt") == 0
    assert fleet_lib.held(fleet, "wine") == CARGO_CAPACITY


def test_jettison_degenerate_indices() -> None:
    fleet = fleet_of("caravel")
    assert fleet_lib.jettison_good(fleet, 9, "wine") == 0
    assert fleet_lib.jettison_good(fleet, -1, "wine") == 0
    assert fleet_lib.jettison_good(fleet, 0, "") == 0
    assert fleet_lib.jettison_supplies(fleet, 9, "water") == 0


# --- 5. normalize_all: the §4.2/§6 load-time guard ---------------------------


def test_valid_loadout_passes_untouched() -> None:
    fleet = [doc_loadout_ship()]
    before = deepcopy(fleet)
    assert fleet_lib.normalize_all(fleet) is False
    assert fleet == before


def test_json_round_trip_needs_no_repair() -> None:
    """A save round-trip hands us floats: `45.0` *is* `45`, so an
    otherwise healthy save must still report "already valid"."""
    raw = json.loads(json.dumps({"fleet": [doc_loadout_ship()]}))
    fleet = raw["fleet"]
    assert fleet_lib.normalize_all(fleet) is False
    assert isinstance(fleet[0]["provisions"], int)
    assert fleet[0]["provisions"] == DOC_PROVISIONS
    assert fleet_lib.used_capacity(fleet[0]) == CARGO_CAPACITY


def test_over_capacity_save_is_truncated_and_stable() -> None:
    fleet = fleet_of("caravel")
    ship = fleet[0]
    ship["provisions"] = 200  # a hand-edited save in a 120-unit hold
    assert fleet_lib.used_capacity(ship) == 200
    assert fleet_lib.normalize_all(fleet) is True
    assert fleet_lib.used_capacity(ship) <= CARGO_CAPACITY
    assert fleet_lib.free_capacity(ship) >= 0
    assert ship["provisions"] == CARGO_CAPACITY  # supplies kept, excess cut
    assert fleet_lib.normalize_all(fleet) is False  # stable afterwards


def test_truncation_drops_trade_goods_before_supplies() -> None:
    fleet = fleet_of("caravel")
    ship = fleet[0]
    ship["provisions"] = 100
    ship["water"] = 100
    ship["cargo"] = {"wine": 40}
    assert fleet_lib.normalize_all(fleet) is True
    assert ship["cargo"].get("wine", 0) == 0  # goods go first
    assert fleet_lib.used_capacity(ship) <= CARGO_CAPACITY


def test_escort_overflow_is_truncated_too() -> None:
    fleet = fleet_of("caravel", "latin")
    fleet[1]["cargo"] = {"salt": 90}  # latin capacity = 30
    assert fleet_lib.normalize_all(fleet) is True
    assert fleet_lib.used_capacity(fleet[1]) <= fleet_lib.ship_stat(
        fleet[1], "capacity")


def test_stranded_cargo_moves_flagship_first() -> None:
    fleet = fleet_of("caravel", "caravel")
    fleet[1]["cargo"] = {"wine": 20}
    assert fleet_lib.normalize_all(fleet) is True
    assert fleet[0]["cargo"].get("wine", 0) == 20
    assert fleet[1]["cargo"].get("wine", 0) == 0
    assert fleet_lib.held(fleet, "wine") == 20  # units conserved


def test_valid_distribution_needs_no_repair() -> None:
    fleet = fleet_of("caravel", "caravel")
    fleet[0]["cargo"] = {"wine": CARGO_CAPACITY}
    fleet[1]["cargo"] = {"wine": 10}
    before = deepcopy(fleet)
    assert fleet_lib.normalize_all(fleet) is False
    assert fleet == before


def test_stranded_supplies_move_flagship_first() -> None:
    fleet = fleet_of("caravel", "caravel")
    fleet[1]["provisions"] = 12
    fleet[1]["water"] = 6
    assert fleet_lib.normalize_all(fleet) is True
    assert fleet[0]["provisions"] == 12
    assert fleet[0]["water"] == 6


def test_full_flagship_may_front_a_loaded_escort() -> None:
    fleet = fleet_of("latin", "caravel")
    fleet[0]["cargo"] = {"wine": fleet_lib.ship_stat(fleet[0], "capacity")}
    fleet[1]["cargo"] = {"wine": 10}
    assert fleet_lib.normalize_all(fleet) is False


def test_degenerate_fleets_do_not_crash() -> None:
    assert fleet_lib.normalize_all([]) is False
    single = fleet_of("caravel")
    assert fleet_lib.normalize_all(single) is False
    # Non-dictionary entries are reported, never silently deleted.
    mixed: list[Any] = [fleet_lib.new_ship("caravel", 0), "not a ship", None]
    assert fleet_lib.normalize_all(mixed) is True
    assert len(mixed) == 3


def test_hostile_save_fields_are_repaired() -> None:
    fleet: list[Any] = [{
        "ship_type_id": "caravel",
        "durability": 90,
        "crew": 15,
        "provisions": None,
        "water": 45.7,
        "cargo": {"wine": 30.2, "salt": -4, "silk": 0},
    }]
    assert fleet_lib.normalize_all(fleet) is True
    ship = fleet[0]
    assert ship["provisions"] == 0            # null became 0 (repair)
    assert ship["water"] == 45                # 45.7 truncated (repair)
    assert ship["cannons"] == 0               # missing field became 0
    assert ship["cargo"].get("wine", 0) == 30  # 30.2 truncated
    assert "salt" not in ship["cargo"]        # negative dropped
    assert "silk" not in ship["cargo"]        # explicit 0 cleaned up
    assert fleet_lib.used_capacity(ship) <= CARGO_CAPACITY


def test_unknown_ship_type_keeps_its_cargo() -> None:
    """§6: the capacity guard is skipped with a warning — nothing is
    destroyed blind."""
    fleet: list[Any] = [{"ship_type_id": "ghost_ship",
                         "cargo": {"wine": 5}}]
    assert fleet_lib.normalize_all(fleet) is True
    assert fleet_lib.held(fleet, "wine") == 5


# --- 6. Promotion (§4.4) -----------------------------------------------------


def test_promote_moves_the_row_preserving_order() -> None:
    fleet = fleet_of("caravel", "latin", "sloop", "galley")
    assert fleet_lib.can_promote(fleet, 2, "lisbon") is True
    assert fleet_lib.promote(fleet, 2, "lisbon") is True
    assert [s["ship_type_id"] for s in fleet] == [
        "sloop", "caravel", "latin", "galley"]
    assert fleet_lib.promote(fleet, 2, "lisbon") is True  # repeatable
    assert fleet_lib.can_promote(fleet, 1, "lisbon") is True


def test_promote_refusals() -> None:
    fleet = fleet_of("caravel", "latin")
    assert fleet_lib.promote(fleet, 0, "lisbon") is False  # flagship
    assert fleet_lib.can_promote(fleet, 0, "lisbon") is False
    assert fleet_lib.promote(fleet, 5, "lisbon") is False  # out of range
    assert fleet_lib.can_promote(fleet, 1, None) is False  # at sea
    assert fleet_lib.can_promote(fleet, 1, "") is False    # empty = at sea
    before = [s["ship_type_id"] for s in fleet]
    assert fleet_lib.promote(fleet, 1, None) is False
    assert [s["ship_type_id"] for s in fleet] == before  # untouched


def test_promote_block_reason_keys() -> None:
    fleet = fleet_of("caravel", "latin")
    assert fleet_lib.promote_block_reason(None, 2, 1) == "fleet.port_only"
    assert fleet_lib.promote_block_reason("lisbon", 2, 0) == "ui.not_available"
    assert fleet_lib.promote_block_reason("lisbon", 2, 9) == "ui.not_available"
    assert fleet_lib.promote_block_reason("lisbon", 2, 1) == ""


def test_fleet_promotion_delegates_to_the_shipyard_engine() -> None:
    fleet = fleet_of("caravel", "latin", "sloop")
    for index in range(4):
        assert fleet_lib.can_promote(fleet, index, "lisbon") == \
            shipyard.can_promote(fleet, index, "lisbon")


# --- 7. Repair pricing (§4.3) -------------------------------------------------


def test_repair_per_point_prices_all_16_types() -> None:
    assert shipyard.REPAIR_DIVISOR == 400
    types = data().ship_types_list
    assert len(types) == 16  # docs/10 §7.3 roster
    for ship_type in types:
        ship_type_id = str(ship_type["id"])
        base_price = int(ship_type["base_price"])
        expected = math.ceil(base_price / shipyard.REPAIR_DIVISOR)
        assert shipyard.repair_cost_per_point(ship_type_id) == expected
    for ship_type_id, price in DOC_REPAIR_PRICES.items():
        assert shipyard.repair_cost_per_point(ship_type_id) == price
    # The ceiling-exercising non-worked values.
    assert shipyard.repair_cost_per_point("sloop") == 8       # 7.5 → 8
    assert shipyard.repair_cost_per_point("brigantine") == 38  # 37.5 → 38
    assert shipyard.repair_cost_per_point("carrack") == 100
    assert shipyard.repair_cost_per_point("no_such_ship") == 0


def test_roster_data_pins() -> None:
    """The Phase-7 roster shape the GDScript suite pins: tiers 4/8/4,
    every role in use, the galley's pinned war role."""
    tiers = {1: 0, 2: 0, 3: 0}
    roles = set()
    for ship_type in data().ship_types_list:
        tiers[int(ship_type["tier"])] += 1
        roles.add(str(ship_type["role"]))
    assert tiers == {1: 4, 2: 8, 3: 4}
    assert roles == {"war", "trade", "coastal"}
    assert data().get_ship_type("galley")["role"] == "war"


def test_raw_and_discounted_repair_costs() -> None:
    fleet = fleet_of("caravel")
    fleet[0]["durability"] = 50
    assert shipyard.max_repair_points(fleet, 0) == 40
    assert shipyard.raw_repair_cost(fleet, 0, 7) == 140       # 7 × 20
    assert shipyard.repair_cost(fleet, 0, 7) == 140           # no discounts
    assert shipyard.raw_repair_cost(fleet, 0, 0) == 0
    assert shipyard.raw_repair_cost(fleet, 0, -3) == 0
    assert shipyard.raw_repair_cost(fleet_of(), 0, 7) == 0     # bad index
    # 1 point costs exactly the per-point price for every type.
    for ship_type in data().ship_types_list:
        ship_type_id = str(ship_type["id"])
        one = fleet_of(ship_type_id)
        one[0]["durability"] = 1
        assert shipyard.repair_cost(one, 0, 1) == \
            shipyard.repair_cost_per_point(ship_type_id)


def test_repair_discount_composition_floors_once() -> None:
    """Phase 8 (40-§4.3): ×title ×carpenter, floored once at the end of
    the whole transaction. The title factor is the Fame 0.8 count grant;
    the carpenter factor is `1 − floor(carpentry/20)/100`."""
    fleet = fleet_of("caravel")
    fleet[0]["durability"] = 50
    assert shipyard.repair_cost(fleet, 0, 7, title_repair_discount=0.8) == 112
    assert shipyard.repair_cost(fleet, 0, 7, carpenter_discount=0.99) == 138
    assert shipyard.repair_cost(fleet, 0, 7, carpenter_discount=0.95) == 133
    # Both factors compose, then floor once: floor(140 × 0.8 × 0.99).
    assert shipyard.repair_cost(fleet, 0, 7, title_repair_discount=0.8,
                                carpenter_discount=0.99) == 110
    # The GDScript pin: nao 1 point = raw 55; carpentry 41 → −2% → 53,
    # floored once (never per factor).
    nao = fleet_of("nao")
    nao[0]["durability"] = 100
    assert shipyard.carpenter_discount_factor(41) == pytest.approx(0.98)
    assert shipyard.repair_cost(nao, 0, 1, carpenter_discount=0.98) == 53


def test_carpenter_discount_factor_table() -> None:
    # ×1.00 / ×0.99 / ×0.95 at carpentry 0 / 20 / 100 (the −skill/20% table).
    assert shipyard.carpenter_discount_factor(0) == pytest.approx(1.0)
    assert shipyard.carpenter_discount_factor(20) == pytest.approx(0.99)
    assert shipyard.carpenter_discount_factor(100) == pytest.approx(0.95)
    assert shipyard.carpenter_discount_factor(1) == pytest.approx(1.0)


# --- 8. Repair transactions ---------------------------------------------------


def test_partial_repair_mutates_exactly() -> None:
    fleet = fleet_of("caravel")
    fleet[0]["durability"] = 50
    result = shipyard.repair_apply(fleet, 0, 7)
    assert result.ok is True
    assert result.gold_delta == -140
    assert fleet[0]["durability"] == 57  # exactly +7


def test_repair_caps_at_damage() -> None:
    fleet = fleet_of("caravel")
    fleet[0]["durability"] = 50
    assert shipyard.repair_block_reason(fleet, 0, 41) == "shipyard.invalid_points"
    assert shipyard.can_repair(fleet, 0, 40, gold=100000) is True
    result = shipyard.repair(fleet, 0, 40, gold=100000)
    assert result.ok and result.gold_delta == -800
    assert fleet[0]["durability"] == 90  # lands exactly on max


def test_repair_caps_at_gold() -> None:
    fleet = fleet_of("caravel")
    fleet[0]["durability"] = 50
    assert shipyard.repair_block_reason(fleet, 0, 7, gold=139) == \
        "shipyard.no_gold"
    refused = shipyard.repair(fleet, 0, 7, gold=139)
    assert refused.ok is False and refused.gold_delta == 0
    assert fleet[0]["durability"] == 50  # nothing mutated
    ok = shipyard.repair(fleet, 0, 7, gold=140)  # exactly affordable
    assert ok.ok and ok.gold_delta == -140


def test_repair_validation_refusals() -> None:
    fleet = fleet_of("caravel")
    fleet[0]["durability"] = 50
    assert shipyard.repair_block_reason(fleet, 0, 0) == "shipyard.invalid_points"
    assert shipyard.repair(fleet, 0, -3).ok is False
    full = fleet_of("caravel")  # 90/90: nothing to repair
    assert shipyard.max_repair_points(full, 0) == 0
    assert shipyard.can_repair(full, 0, 1) is False
    assert shipyard.repair_block_reason(full, 5, 1) == "shipyard.no_selection"


def test_repair_uses_the_effective_max_with_a_figurehead() -> None:
    """40-§4.1: repairs use the effective max, so a figurehead can be
    repaired onto (tools/test_equipment.gd §6 pins)."""
    player = player_block()
    fleet = fleet_of("caravel", "sloop")
    assert shipyard.ship_max_durability(fleet, 0) == 90  # bare hull
    assert shipyard.equip(player, fleet, "figurehead",
                          "eq_angel_figurehead", 0, current_port="venice",
                          gold=100000).ok
    assert shipyard.ship_max_durability(fleet, 0) == 115  # 90 + 25
    assert shipyard.ship_max_durability(fleet, 1) == 60   # other hull intact
    fleet[0]["durability"] = 100
    assert shipyard.max_repair_points(fleet, 0) == 15
    fleet[0]["durability"] = 60
    assert shipyard.max_repair_points(fleet, 0) == 55
    result = shipyard.repair_apply(fleet, 0, 55)
    assert result.ok and fleet[0]["durability"] == 115  # the effective max


# --- 9. Sell (§4.3) -----------------------------------------------------------


def test_sell_price_formula_pins() -> None:
    fleet = fleet_of("caravel")
    fleet[0]["durability"] = 90
    assert shipyard.sell_price(fleet, 0) == 4000
    fleet[0]["durability"] = 45
    assert shipyard.sell_price(fleet, 0) == 2000
    assert shipyard.SELL_FRACTION == 0.5
    galleon = fleet_of("galleon")
    assert shipyard.sell_price(galleon, 0) == 30000  # full 240/240
    # Every type at full durability: floor(base × 0.5).
    for ship_type in data().ship_types_list:
        ship = fleet_of(str(ship_type["id"]))
        expected = math.floor(int(ship_type["base_price"]) * 0.5)
        assert shipyard.sell_price(ship, 0) == expected
    wreck = fleet_of("latin")
    wreck[0]["durability"] = 0
    assert shipyard.sell_price(wreck, 0) == 0
    assert shipyard.sell_price([], 0) == 0


def test_sell_block_reasons() -> None:
    pair = fleet_of("caravel", "sloop")
    assert shipyard.sell_block_reason(pair, 0) == "shipyard.no_sell_flagship"
    assert shipyard.can_sell(pair, 0) is False
    single = fleet_of("caravel")
    assert shipyard.sell_block_reason(single, 0) == "shipyard.no_sell_last"
    loaded = fleet_of("caravel", "sloop")
    loaded[1]["cargo"] = {"wine": 5}
    assert shipyard.sell_block_reason(loaded, 1) == "shipyard.cargo_not_empty"
    # §4.2 pooling: provisions/water aboard block the sale too.
    loaded[1]["cargo"] = {}
    loaded[1]["provisions"] = 12
    assert shipyard.sell_block_reason(loaded, 1) == "shipyard.cargo_not_empty"
    loaded[1]["provisions"] = 0
    loaded[1]["water"] = 12
    assert shipyard.can_sell(loaded, 1) is False
    loaded[1]["water"] = 0
    assert shipyard.sell_block_reason(loaded, 1) == ""
    assert shipyard.sell_block_reason(loaded, 9) == "shipyard.no_selection"


def test_sell_transaction_pays_the_formula_price() -> None:
    fleet = fleet_of("caravel", "sloop")
    price = shipyard.sell_price(fleet, 1)  # 1500 at full durability
    assert price == 1500
    result = shipyard.sell(fleet, 1)
    assert result.ok is True and result.gold_delta == price
    assert len(fleet) == 1
    assert fleet[0]["ship_type_id"] == "caravel"
    # Refused sales change nothing.
    flagship_sale = shipyard.sell(fleet, 0)
    assert flagship_sale.ok is False and flagship_sale.gold_delta == 0
    assert len(fleet) == 1


# --- 10. Buy (§4.3 + the §4.3.1 gates) -----------------------------------------


def test_buy_defaults_are_the_doc_shape() -> None:
    fleet = fleet_of("caravel")
    result = shipyard.buy("galleon", fleet=fleet, current_port="lisbon",
                          gold=100000)
    assert result.ok and result.gold_delta == -60000  # price paid once
    ship = fleet[-1]
    assert ship["ship_type_id"] == "galleon"
    assert ship["durability"] == 240  # full durability
    assert ship["crew"] == 0
    assert ship["provisions"] == 0 and ship["water"] == 0
    assert ship["cannons"] == 0
    assert ship["cargo"] == {}
    assert fleet_lib.used_capacity(ship) == 0


def test_fleet_max_cap() -> None:
    assert shipyard.FLEET_MAX == 5
    fleet = fleet_of("caravel")
    gold = 500000
    bought = 0
    for _ in range(4):
        result = shipyard.buy("latin", fleet=fleet, current_port="lisbon",
                              gold=gold)
        assert result.ok
        gold += result.gold_delta
        bought += 1
    assert bought == 4
    assert len(fleet) == 5
    assert gold == 500000 - 4 * 1200
    assert shipyard.buy_block_reason("latin", current_port="lisbon",
                                     fleet_size=len(fleet),
                                     gold=gold) == "shipyard.fleet_full"
    sixth = shipyard.buy("latin", fleet=fleet, current_port="lisbon",
                         gold=gold)
    assert sixth.ok is False and sixth.gold_delta == 0
    assert len(fleet) == 5  # untouched


def test_buy_affordability_gate() -> None:
    fleet = fleet_of("caravel")
    assert shipyard.buy_block_reason("caravel", current_port="lisbon",
                                     fleet_size=1, gold=100) == \
        "shipyard.no_gold"
    refused = shipyard.buy("caravel", fleet=fleet, current_port="lisbon",
                           gold=100)
    assert refused.ok is False
    assert len(fleet) == 1
    # Exactly affordable (docs/30 §6: gold exactly equals cost).
    exact = shipyard.buy("latin", fleet=fleet, current_port="lisbon",
                         gold=1200)
    assert exact.ok and exact.gold_delta == -1200
    assert len(fleet) == 2


def test_buy_stock_and_tier_gates_at_a_dev_1_port() -> None:
    fleet = fleet_of("latin")
    port = dict(current_port="bordeaux", fleet_size=1, gold=100000)
    assert shipyard.buy_block_reason("latin", **port) == "ui.not_available"
    assert shipyard.buy_block_reason("pinnace", **port) == ""
    assert shipyard.buy_block_reason("caravel", **port) == \
        "shipyard.tier.need_dev"
    assert shipyard.buy_block_reason("nao", **port) == "shipyard.tier.need_dev"
    assert shipyard.buy_block_reason("junk", **port) == "ui.not_available"
    assert shipyard.buy("pinnace", fleet=fleet, **port).ok
    assert len(fleet) == 2
    assert shipyard.buy("caravel", fleet=fleet, **port).ok is False
    assert shipyard.buy("nao", fleet=fleet, **port).ok is False


def test_buy_tier_3_at_the_dev_3_capital() -> None:
    fleet = fleet_of("latin")
    result = shipyard.buy("galleon", fleet=fleet, current_port="lisbon",
                          fleet_size=1, gold=60000)
    assert result.ok and result.gold_delta == -60000
    assert len(fleet) == 2


def test_buy_refused_at_an_unallied_neutral() -> None:
    fleet = fleet_of("latin")
    assert shipyard.buy_block_reason("latin", current_port="quanzhou",
                                     fleet_size=1, gold=1000000) == \
        "shipyard.tier.allegiance_locked"
    assert shipyard.buy("latin", fleet=fleet, current_port="quanzhou",
                        fleet_size=1, gold=1000000).ok is False
    assert len(fleet) == 1


def test_buy_standalone_falls_back_to_the_full_catalog() -> None:
    """No docked port: the port gates are skipped (standalone screens)."""
    fleet = fleet_of("latin")
    assert shipyard.can_buy("junk", current_port="", fleet_size=1,
                            gold=16000) is True
    assert shipyard.buy("junk", fleet=fleet, current_port="", fleet_size=1,
                        gold=16000).ok is True


def test_shipyard_stock_lists() -> None:
    lisbon = shipyard.shipyard_stock("lisbon")
    assert len(lisbon) == len(LISBON_STOCK) and same_set(lisbon, LISBON_STOCK)
    assert same_set(shipyard.shipyard_stock(current_port="lisbon"), lisbon)
    assert "junk" not in shipyard.shipyard_stock("lisbon")
    assert "junk" in shipyard.shipyard_stock("quanzhou")  # regional flavor
    standalone = shipyard.shipyard_stock(current_port="")
    assert len(standalone) == 16  # the full catalog fallback


def test_dev_and_alignment_guard_defaults() -> None:
    assert shipyard.authored_dev("lisbon") == 3
    assert shipyard.effective_dev("lisbon") == 3
    assert shipyard.effective_dev("bordeaux") == 1
    assert shipyard.effective_dev("quanzhou") == 0
    assert shipyard.effective_alignment("lisbon") == "portugal"
    assert shipyard.effective_alignment("quanzhou") == ""
    assert not shipyard.is_unallied_neutral("lisbon")
    assert not shipyard.is_unallied_neutral("bordeaux")
    for neutral in UNALLIED_NEUTRAL_SHIPYARDS:
        assert shipyard.is_unallied_neutral(neutral)


def test_allegiance_view_overrides_the_guard_defaults() -> None:
    """The injected allegiance seam wins over the authored floor (the
    tools/test_shipyard.gd §12 fixture: dev 2 / portugal everywhere)."""
    view = FixtureAllegiance()
    assert shipyard.effective_dev("lisbon", view) == 2
    assert shipyard.effective_alignment("quanzhou", view) == "portugal"
    assert not shipyard.is_unallied_neutral("quanzhou", view)
    assert shipyard.row_state("lisbon", "caravel", view) == \
        shipyard.ROW_AVAILABLE
    assert shipyard.row_state("lisbon", "nao", view) == shipyard.ROW_TIER_GRAY
    # The aligned dev-2 neutral unlocks her regional hulls (the flip path).
    fleet = fleet_of("latin")
    reason = shipyard.buy_block_reason("junk", current_port="quanzhou",
                                       fleet_size=1, gold=100000,
                                       allegiance=view)
    assert reason == ""
    assert shipyard.buy("junk", fleet=fleet, current_port="quanzhou",
                        fleet_size=1, gold=100000, allegiance=view).ok


def test_three_row_states() -> None:
    # (1) available at a dev-3 capital, tier-3 and tier-1 alike.
    assert shipyard.row_state("lisbon", "galleon") == shipyard.ROW_AVAILABLE
    assert shipyard.row_state("lisbon", "latin") == shipyard.ROW_AVAILABLE
    assert shipyard.row_note_key("lisbon", "galleon") == ""
    # (2) tier-gray at a dev-1 port.
    assert shipyard.row_state("bordeaux", "pinnace") == shipyard.ROW_AVAILABLE
    assert shipyard.row_state("bordeaux", "sloop") == shipyard.ROW_AVAILABLE
    for above_tier in ("caravel", "caravela_redonda", "nao", "carrack"):
        assert shipyard.row_state("bordeaux", above_tier) == \
            shipyard.ROW_TIER_GRAY
    assert shipyard.row_note_key("bordeaux", "caravel") == \
        "shipyard.tier.need_dev"
    # (3) allegiance-gray: the unallied neutral's whole list is locked.
    for hull_id in shipyard.shipyard_stock("quanzhou"):
        assert shipyard.row_state("quanzhou", hull_id) == \
            shipyard.ROW_ALLEGIANCE_GRAY
    assert shipyard.row_note_key("quanzhou", "junk") == \
        "shipyard.tier.allegiance_locked"


# --- 11. Refit (§4.3) ----------------------------------------------------------


def test_refit_constants_and_flat_maths() -> None:
    assert shipyard.CANNON_PRICE == 100
    assert shipyard.CANNON_SELLBACK_PRICE == 50
    assert shipyard.CANNON_CARGO_UNITS == 5
    assert shipyard.refit_cost(6) == 600
    assert shipyard.refit_sellback(6) == 300
    assert shipyard.refit_cargo_units(6) == 30
    assert shipyard.refit_cost(0) == 0
    assert shipyard.refit_cost(-2) == 0


def test_refit_slot_cap_binds_on_a_caravel() -> None:
    fleet = fleet_of("caravel")
    assert shipyard.max_refit(fleet, 0) == 6  # armament_slots 6 < room
    assert shipyard.can_refit(fleet, 0, 6, gold=100000)
    assert not shipyard.can_refit(fleet, 0, 7, gold=100000)
    result = shipyard.refit(fleet, 0, 6, gold=100000)
    assert result.ok and result.gold_delta == -600
    assert fleet[0]["cannons"] == 6
    assert fleet_lib.used_capacity(fleet[0]) == 30  # 6 × 5 hold units
    assert shipyard.max_refit(fleet, 0) == 0
    assert not shipyard.can_refit(fleet, 0, 1, gold=100000)


def test_refit_cap_is_min_slots_and_hold_room_for_every_type() -> None:
    for ship_type in data().ship_types_list:
        fleet = fleet_of(str(ship_type["id"]))
        slots = int(ship_type["armament_slots"])
        expected = min(slots, int(ship_type["capacity"]) // 5)
        assert shipyard.max_refit(fleet, 0) == expected
        assert not shipyard.can_refit(fleet, 0, expected + 1, gold=1000000)


def test_refit_hold_room_binds() -> None:
    fleet = fleet_of("caravel")
    fleet_lib.add_goods(fleet, "wine", 120)  # full hold
    assert shipyard.max_refit(fleet, 0) == 0
    assert not shipyard.can_refit(fleet, 0, 1, gold=100000)


def test_refit_affordability_and_reasons() -> None:
    fleet = fleet_of("latin")
    assert shipyard.max_refit(fleet, 0) == 2
    assert shipyard.refit_block_reason(fleet, 0, 1, gold=99) == \
        "shipyard.no_gold"
    assert not shipyard.can_refit(fleet, 0, 1, gold=99)
    assert shipyard.refit_block_reason(fleet, 9, 1, gold=100000) == \
        "shipyard.no_selection"
    assert shipyard.refit_block_reason(fleet, 0, 0, gold=100000) == \
        "shipyard.invalid_points"
    assert shipyard.refit_block_reason(fleet, 0, 3, gold=100000) == \
        "shipyard.invalid_points"
    assert shipyard.refit(fleet, 0, 1, gold=99).ok is False


# --- 12. Equipment accessors & prices (60-§4.11.12) -----------------------------


def test_equipment_accessors_are_tolerant() -> None:
    player = player_block()
    fleet = fleet_of("caravel")
    assert shipyard.equipped_player(player, "weapon") == ""
    assert "equipment" not in player  # reads never create blocks
    assert shipyard.equipped_ship(fleet, 0, "figurehead") == ""
    assert shipyard.equipped_ship(fleet, 9, "sail") == ""
    assert shipyard.equipped_player(player, "figurehead") == ""  # ship slot
    assert shipyard.equipped_ship(fleet, 0, "weapon") == ""      # player slot
    # A hostile block: null and non-string values read as empty.
    player["equipment"] = {"weapon": "eq_cutlass", "armor": None}
    assert shipyard.equipped_player(player, "weapon") == "eq_cutlass"
    assert shipyard.equipped_player(player, "armor") == ""
    fleet[0]["equipment"] = {"figurehead": "", "sail": 7}
    assert shipyard.equipped_ship(fleet, 0, "sail") == ""
    assert shipyard.equipped_ship(fleet, 0, "figurehead") == ""


def test_equipment_modifiers() -> None:
    assert shipyard.equipment_modifier("eq_cutlass", "combat") == 3
    assert shipyard.equipment_modifier("eq_cutlass", "luck") == 0
    assert shipyard.equipment_modifier("eq_nope", "combat") == 0
    assert shipyard.equipment_modifier("", "combat") == 0
    assert shipyard.equipment_modifier("eq_storm_sails", "durability") == 5


def test_equipment_prices_and_sell_back() -> None:
    assert shipyard.EQUIP_SELL_FRACTION == 0.5
    assert shipyard.equip_price("weapon", "eq_cutlass") == 400
    assert shipyard.equip_price("weapon", "eq_rapier") == 1200
    assert shipyard.equip_sellback("weapon", "eq_cutlass") == 200
    assert shipyard.equip_sellback("weapon", "eq_rapier") == 600
    assert shipyard.equip_sellback("armor", "eq_lucky_charm") == 450
    assert shipyard.equip_price("weapon", "eq_nope") == 0
    assert shipyard.equip_sellback("weapon", "eq_nope") == 0


def test_equipment_slot_lists_follow_the_port_stock() -> None:
    def ids(items: list[dict[str, Any]]) -> list[str]:
        return [str(item["id"]) for item in items]

    # venice (dev 3) stocks one item per slot in her equipment_stock order.
    assert ids(shipyard.equipment_list("weapon", "venice")) == ["eq_rapier"]
    assert ids(shipyard.equipment_list("sail", "venice")) == ["eq_storm_sails"]
    assert ids(shipyard.equipment_list("figurehead", "venice")) == [
        "eq_angel_figurehead", "eq_mermaid_figurehead"]
    assert ids(shipyard.equipment_list("armor", "venice")) == ["eq_breastplate"]
    assert shipyard.equipment_list("nonsense", "venice") == []
    # Standalone fallback: every non-rare item of the slot in data order.
    assert ids(shipyard.equipment_list("weapon")) == [
        "eq_cutlass", "eq_rapier", "eq_backsword", "eq_main_gauche",
        "eq_zweihander"]
    # lisbon's weapon pair in her stock order; no rare ever leaks.
    assert ids(shipyard.equipment_list("weapon", "lisbon")) == [
        "eq_zweihander", "eq_cutlass"]
    for slot in shipyard.PLAYER_SLOTS + shipyard.SHIP_SLOTS:
        for item in shipyard.equipment_list(slot, "lisbon"):
            assert not shipyard.is_rare_equipment(str(item["id"]))


# --- 13. Buying player equipment (§4.3, 60-§4.11.12/§4.11.13) --------------------


def test_buy_player_equipment_creates_the_block() -> None:
    player = player_block()
    fleet = fleet_of("caravel")
    result = shipyard.equip(player, fleet, "weapon", "eq_rapier",
                            current_port="venice", gold=5000)
    assert result.ok and result.gold_delta == -1200
    assert player["equipment"]["weapon"] == "eq_rapier"
    assert player["equipment"]["armor"] == ""  # created, not filled


def test_replace_sells_back_in_the_same_transaction() -> None:
    player = player_block()
    fleet = fleet_of("caravel")
    player["equipment"] = {"weapon": "eq_cutlass", "armor": ""}
    assert shipyard.equip_net_cost(player, fleet, "weapon", "eq_rapier") == \
        -1000  # −1200 + 200
    result = shipyard.equip(player, fleet, "weapon", "eq_rapier",
                            current_port="venice", gold=1000)
    assert result.ok and result.gold_delta == -1000
    assert player["equipment"]["weapon"] == "eq_rapier"


def test_net_cost_gates_affordability() -> None:
    player = player_block()
    fleet = fleet_of("caravel")
    player["equipment"] = {"weapon": "eq_cutlass", "armor": ""}
    # 1000g suffices for the −1000g net upgrade…
    assert shipyard.equip_block_reason(player, fleet, "weapon", "eq_rapier",
                                       current_port="venice", gold=1000) == ""
    result = shipyard.equip(player, fleet, "weapon", "eq_rapier",
                            current_port="venice", gold=1000)
    assert result.ok and result.gold_delta == -1000
    # …while 999g cannot buy the 1200g rapier into an empty slot.
    player["equipment"]["weapon"] = ""
    assert shipyard.equip_block_reason(player, fleet, "weapon", "eq_rapier",
                                       current_port="venice", gold=999) == \
        "shipyard.no_gold"
    refused = shipyard.equip(player, fleet, "weapon", "eq_rapier",
                             current_port="venice", gold=999)
    assert refused.ok is False and refused.gold_delta == 0
    assert player["equipment"]["weapon"] == ""


def test_player_equipment_stock_gates() -> None:
    player = player_block()
    fleet = fleet_of("caravel")
    at_venice = dict(current_port="venice", gold=100000)
    assert shipyard.equip_block_reason(player, fleet, "weapon", "eq_cutlass",
                                       **at_venice) == "ui.not_available"
    # The rare scimitar is drop-only, refused even where a stock list
    # might name it (60-§4.11.13, defensive).
    assert shipyard.equip_block_reason(player, fleet, "weapon",
                                       "eq_khair_scimitar",
                                       **at_venice) == "ui.not_available"
    assert shipyard.equip_block_reason(player, fleet, "weapon", "eq_rapier",
                                       current_port="lisbon",
                                       gold=100000) == "ui.not_available"
    # Unknown item / slot mismatch.
    assert shipyard.equip_block_reason(player, fleet, "weapon", "eq_nope",
                                       **at_venice) == "ui.not_available"
    assert shipyard.equip_block_reason(player, fleet, "weapon",
                                       "eq_cotton_sails",
                                       **at_venice) == "ui.not_available"
    assert shipyard.equip_block_reason(player, fleet, "figurehead",
                                       "eq_cutlass",
                                       **at_venice) == "ui.not_available"
    assert shipyard.equip(player, fleet, "weapon", "eq_nope",
                          **at_venice).ok is False


def test_tier_gray_and_allegiance_gray_equipment() -> None:
    player = player_block()
    fleet = fleet_of("latin")
    # dev-1 valetta stocks a tier-2 medallion → gray, refused.
    assert shipyard.equip_block_reason(player, fleet, "armor",
                                       "eq_saint_medallion",
                                       current_port="valetta",
                                       gold=5000) == "shipyard.tier.need_dev"
    assert shipyard.equip(player, fleet, "armor", "eq_saint_medallion",
                          current_port="valetta", gold=5000).ok is False
    # …while her tier-1 armor buys (−700g).
    assert shipyard.equip_block_reason(player, fleet, "armor",
                                       "eq_breastplate",
                                       current_port="valetta",
                                       gold=5000) == ""
    assert shipyard.equip(player, fleet, "armor", "eq_breastplate",
                          current_port="valetta", gold=5000).gold_delta == -700
    # The neutral's stocked cutlass is allegiance-locked too.
    assert shipyard.equip_block_reason(player, fleet, "weapon", "eq_cutlass",
                                       current_port="quanzhou",
                                       gold=5000) == \
        "shipyard.tier.allegiance_locked"
    assert shipyard.equip(player, fleet, "weapon", "eq_cutlass",
                          current_port="quanzhou", gold=5000).ok is False


def test_unequip_pays_half_price() -> None:
    player = player_block()
    fleet = fleet_of("caravel")
    assert not shipyard.can_unequip(player, fleet, "weapon")
    assert shipyard.unequip(player, fleet, "weapon").ok is False  # no-op
    shipyard.equip(player, fleet, "weapon", "eq_rapier",
                   current_port="venice", gold=100000)
    assert shipyard.can_unequip(player, fleet, "weapon")
    result = shipyard.unequip(player, fleet, "weapon")
    assert result.ok and result.gold_delta == 600
    assert shipyard.equipped_player(player, "weapon") == ""
    assert shipyard.unequip(player, fleet, "weapon").ok is False
    # A drop-worn cutlass (not stocked at venice) still sells back 200g —
    # unequipping never re-checks the local stock.
    player["equipment"] = {"weapon": "eq_cutlass", "armor": ""}
    assert shipyard.unequip(player, fleet, "weapon").gold_delta == 200


def test_player_combat_bonus_duel_hook() -> None:
    """60-§4.11.6: the duel roll adds Σ combat across the worn player
    items — the worn state, not where it was bought."""
    player = player_block()
    fleet = fleet_of("caravel")
    assert shipyard.player_combat_bonus(player) == 0
    player["equipment"] = {"weapon": "eq_cutlass", "armor": ""}
    assert shipyard.player_combat_bonus(player) == 3
    shipyard.equip(player, fleet, "armor", "eq_breastplate",
                   current_port="venice", gold=100000)
    assert shipyard.player_combat_bonus(player) == 5
    shipyard.unequip(player, fleet, "weapon")
    assert shipyard.player_combat_bonus(player) == 2
    shipyard.equip(player, fleet, "weapon", "eq_rapier",
                   current_port="venice", gold=100000)
    assert shipyard.player_combat_bonus(player) == 7
    shipyard.unequip(player, fleet, "weapon")
    shipyard.unequip(player, fleet, "armor")
    assert shipyard.player_combat_bonus(player) == 0


# --- 14. Ship equipment: figurehead durability, sail speed ----------------------


def test_ship_equipment_transactions() -> None:
    player = player_block()
    fleet = fleet_of("caravel", "sloop")
    assert shipyard.ship_speed_bonus(fleet, 0) == 0
    # The mermaid raises the cap by 10 → 100, without healing.
    mermaid = shipyard.equip(player, fleet, "figurehead",
                             "eq_mermaid_figurehead", 0,
                             current_port="venice", gold=10000)
    assert mermaid.ok and mermaid.gold_delta == -1500
    assert shipyard.ship_max_durability(fleet, 0) == 100
    assert fleet[0]["durability"] == 90  # not healed
    # Replace with the tier-3 angel: mermaid sells back 750 in the same
    # transaction (net −4,800 + 750 = −4,050).
    angel = shipyard.equip(player, fleet, "figurehead",
                           "eq_angel_figurehead", 0,
                           current_port="venice", gold=10000)
    assert angel.ok and angel.gold_delta == -4050
    assert shipyard.ship_max_durability(fleet, 0) == 115
    # Storm sails bind to their own hull only.
    sails = shipyard.equip(player, fleet, "sail", "eq_storm_sails", 1,
                           current_port="venice", gold=10000)
    assert sails.ok and sails.gold_delta == -2600
    assert shipyard.ship_speed_bonus(fleet, 1) == 1
    assert shipyard.ship_speed_bonus(fleet, 0) == 0
    assert fleet[1]["equipment"]["sail"] == "eq_storm_sails"
    # Ship slots write the hull's own block, never the player's.
    assert "equipment" not in player
    # Equipping onto a missing hull reports ui.not_available.
    assert shipyard.equip_block_reason(player, fleet, "sail",
                                       "eq_storm_sails", 9,
                                       current_port="venice",
                                       gold=10000) == "ui.not_available"


def test_removing_a_figurehead_clamps_durability_down() -> None:
    """40-§4.1: current durability is clamped to the effective max, so
    removing a figurehead lowers the hull with its cap (the only place
    the cap can shrink); equipping never heals."""
    player = player_block()
    fleet = fleet_of("caravel")
    shipyard.equip(player, fleet, "figurehead", "eq_angel_figurehead", 0,
                   current_port="venice", gold=100000)
    fleet[0]["durability"] = 115  # repaired to the raised cap
    result = shipyard.unequip(player, fleet, "figurehead", 0)
    assert result.ok
    assert shipyard.ship_max_durability(fleet, 0) == 90
    assert fleet[0]["durability"] == 90  # 115 clamped down to the new cap


# --- 15. Shipped-data observations (the §4.3.1 data-shape pins) -----------------


def test_shipyard_stock_data_shape() -> None:
    """Every shipyard facility is the Phase-7 id-list form, ≥2 ≤8 valid
    ids; 109 shipyard ports; equipment_stock ≥2 known non-rare items."""
    stock_ports = 0
    equipment_ports = 0
    for port in data().ports_list:
        facilities = port.get("facilities", {})
        shipyard_list = facilities.get("shipyard")
        if isinstance(shipyard_list, list):
            stock_ports += 1
            assert 2 <= len(shipyard_list) <= 8
            for ship_type_id in shipyard_list:
                assert data().get_ship_type(str(ship_type_id))
        equipment_list = facilities.get("equipment_stock")
        if isinstance(equipment_list, list):
            equipment_ports += 1
            assert len(equipment_list) >= 2
            for item_id in equipment_list:
                assert data().get_equipment(str(item_id))
                assert not shipyard.is_rare_equipment(str(item_id))
    assert stock_ports == 109
    assert equipment_ports == 109


def test_rare_items_are_drop_only() -> None:
    """60-§4.11.13: exactly four rare items; every named pirate's drop
    references one of them (correction 10)."""
    rare_ids = {str(item["id"]) for item in data().equipment_list
                if bool(item.get("rare", False))}
    assert len(rare_ids) == 4
    assert len(data().named_pirates_list) == 4
    for pirate in data().named_pirates_list:
        assert str(pirate.get("drop", "")) in rare_ids
