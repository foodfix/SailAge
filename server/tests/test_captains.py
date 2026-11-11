"""server.tests.test_captains — the named-captain lifecycle + the at-sea
interaction/hail layer (M1).

Port of the guarantee, not the method (AGENTS.md test discipline): the
GDScript harnesses (``tools/test_captains.gd`` W4-A, ``tools/
test_captain_lifecycle.gd`` W4-D sections 2–8, ``tools/test_interactions.gd``
W5-A sections 1–4 + 9, ``tools/test_hail.gd`` W5-B) boot runs and walk the
autoloads; here the same pinned contracts are asserted as pure functions
over injected state on the real shipped ``data/`` tree (loaded through
:mod:`server.sim.data`).

Pinned contracts:
  * captains module (docs/60 §4.11.15 + §4.11.11.4, docs/10 §4.11/§4.15):
    lazy §4.15 defaults (exactly the 8 save keys, reads never materialise,
    ``ensure()`` is the only creator), the return-queue boundary (defeat on
    day D → ``active`` again exactly on day D + 60, tier preserved through
    the queue, refit under the same canon card — names are never reused),
    tier drift (−1 crushed / +1 captain win, clamp 1–3, the counters keep
    counting at the clamp), the stance delta constants + the ±10 clamp, the
    stance threshold flags (intel ≥ +2 / warm supplies ≥ +3 / nemesis ≤ −3
    with the role gate), familiarity tiers 3/6/10 with the 0/99 clamps,
    deployment exclusivity (runtime-only ``deployed`` key, release erases
    it), dossier_seen persistence and the pure speed jitter (bit-exact
    Godot ``String.hash`` probes, values captured from live
    ``godot --headless`` runs of the pinned toolchain);
  * the hail (docs/60 §4.11.15, docs/80 §4.10.2): the range guard, the
    role × stance option matrix (supplies for trader/coaster ONLY, intel
    exactly at stance ≥ +2, intimidate for every role, befriend fresh),
    the price base pin (dest port → nearest known port fallback), the
    supply price matrix (×1.5 / ×1.25 folded before the negotiation term,
    floored once per kind — the pinned 45/55/54/52/42 totals), the
    supplies funnel (charge, pools, refusals, capacity/affordability
    bounds), the intimidate chance clamps with card doubles, the outcome
    funnel (half cargo floor per good, fame +5, stance −1/−2, made_hostile),
    the seeded default roll predicted through the §4.11.1 formula +
    :class:`~server.sim.rng.GodotRng`, and the befriend day gate;
  * the interaction layer (docs/80 §4.10.1, docs/60 §4.11.15): targeting
    (exact tile, multi-fleet id-sorted pick list, the dateline seam both
    ways), the coaster verb pin (inspect + talk only), the intercept order
    (set shape, rim/vanish auto-cancel at the §4.11 sighting radius), the
    inspect summary payload (canon name, level, stance/familiarity from
    ``captain_states``, the unidentified fallback), the ``sail.autopilot``
    appoint gate matrix (pilot post, navigation ≥ threshold, known port)
    and the S10 encounter descriptor shape on a hand-built fleet;
  * the seeded interaction replay: one pure scenario signature compared
    across two runs (no RNG anywhere in the layer).

Deterministic — no Monte Carlo, no engine boots; the only seeded stream is
the hail's default intimidate draw, predicted through the documented
closed form and pinned to the oracle's exact output.
"""

from __future__ import annotations

from typing import Any

import pytest

from server.sim.data import DataStore, data
from server.sim.player import PersonState, skills
from server.sim.rng import GodotRng
from server.sim.world import captains, hail_options, interactions
from server.sim.world.raster import ocean_layers

NATIONS = ["portugal", "spain", "england", "holland", "ottoman", "italy"]

#: The legend pirate the GDScript suites fixture on (tools/test_captains.gd).
PIRATE_ID = "pirate_edward_bloodhand"
#: The strongest canon navigation card (the appoint-gate pilot fixture,
#: tools/test_interactions.gd; navigation 59 ≥ the gate's 40).
PILOT_ID = "off_leg_willem_barentsz"
#: The §6.1 projections of the two known-port fixtures (the GDScript
#: price-base fixtures tile-for-tile).
LISBON_TILE = (2050, 615)
SEVILLE_TILE = (2083, 636)

#: Open water far from every harbor (the ecology suites' fixture cell).
OPEN_CELL = (1400, 640)
#: The dateline seam columns (the wrap-targeting pins, 20-* §4.1).
SEAM_EAST = (4319, 640)
SEAM_WEST = (0, 640)

#: The §4.15 save shape — a met captain's entry carries exactly these keys
#: (the module's ``deployed`` bookkeeping flag is runtime-only and must be
#: absent from an idle entry).
SAVE_SHAPE_KEYS = ("status", "return_day", "tier_now", "stance",
                   "familiarity", "dossier_seen", "defeats", "wins")

#: The hail's canon-card doubles (tools/test_hail.gd): controlled duel
#: ratings for the chance pins.
EVEN_CARD = {
    "id": "cap_double_even", "name": {"zh": "平卡", "en": "Even Card"},
    "role": "pirate", "tier": 2,
    "skills": {"swordplay": 36, "gunnery": 0},
    "attributes": {"courage": 80, "charisma": 10},
}  # duel rating 36 + floor(80/20) = 40
WEAK_CARD = {
    "id": "cap_double_weak", "name": {"zh": "弱卡", "en": "Weak Card"},
    "role": "pirate", "tier": 1,
    "skills": {"swordplay": 0, "gunnery": 0},
    "attributes": {"courage": 0, "charisma": 0},
}  # duel rating 0
#: swordplay 6, courage 19 → duel rating 6 (the escort fixture).
FIRST_OFFICER = "off_leg_duarte_silveira"


# --- Fixtures ---------------------------------------------------------------


@pytest.fixture()
def store() -> DataStore:
    return data()


def make_person(swordplay: int = 0, negotiation: int = 0,
                courage: int = 10, gold: int = 10000, day: int = 100,
                officers: list[str] | None = None) -> PersonState:
    """The bare-run Person fixture (tools/test_interactions.gd
    ``_make_run`` / tools/test_hail.gd ``_reset_world``), on PersonState."""
    st = PersonState()
    st.player = {
        "nation_id": "portugal",
        "background_id": "",
        "attributes": {"constitution": 10, "intellect": 10, "charisma": 10,
                       "courage": courage, "luck": 10},
        "skills": {key: (swordplay if key == "swordplay" else
                         negotiation if key == "negotiation" else 0)
                   for key in skills.KEYS},
        "skill_counters": {key: 0 for key in skills.KEYS},
        "alloc_pending": 0,
        "xp": 0,
        "level": 1,
        "officers": list(officers or []),
        "reputation": {nation: 0 for nation in NATIONS},
        "profit_by_nation": {},
        "profit_rep_awarded": {},
        "equipment": {"weapon": "", "armor": ""},
    }
    st.gold = gold
    st.day = day
    st.fame = 0
    return st


def make_ship(store: DataStore, ship_type_id: str) -> dict[str, Any]:
    """The §4.1 ship shape the runtime's fleet entries carry (the GDScript
    ``_ship`` fixture)."""
    ship_type = store.get_ship_type(ship_type_id)
    return {
        "ship_type_id": ship_type_id,
        "durability": int(ship_type.get("durability", 0)),
        "crew": 20,
        "provisions": 0,
        "water": 0,
        "cannons": 0,
        "cargo": {},
        "equipment": {"figurehead": "", "sail": "", "weapon": "", "armor": ""},
    }


def make_run(captain_states: dict[str, Any] | None = None,
             pos: tuple[int, int] = OPEN_CELL,
             known: list[str] | None = None,
             fleet: list[dict[str, Any]] | None = None,
             day: int = 100) -> dict[str, Any]:
    """The injected ``run`` dict: the GameState members the three world
    modules read (keys mirror the autoload members verbatim)."""
    return {
        "npc_fleets": [],
        "world": {"position": {"x": pos[0], "y": pos[1]},
                  "wind_dir": "NE", "weather": "fair"},
        "known_ports": list(known if known is not None
                            else ["lisbon", "seville"]),
        "captain_states": captain_states if captain_states is not None else {},
        "fleet": fleet if fleet is not None else [],
        "day": day,
    }


def make_fleet(run: dict[str, Any], role: str, nation_id: str,
               cell: tuple[int, int], fleet_id: str = "",
               captain_id: str = "", **extra: Any) -> dict[str, Any]:
    """A §4.15-shape fixture fleet appended to the run's ecology."""
    fleet: dict[str, Any] = {
        "id": fleet_id or f"fx_{role}_{len(run['npc_fleets'])}",
        "role": role,
        "nation_id": nation_id,
        "cell": {"x": cell[0], "y": cell[1]},
        "route": {"lanes": [], "leg": 0, "tile_index": 0, "legs": []},
        "cargo": {},
        "captain_id": captain_id,
        "cooldown_until_day": 0,
        "seed": 424242,
        "dest_port_id": "",
        "dwell_until_day": 0,
        "anchor_cell": None,
        "hunter_state": "",
    }
    fleet.update(extra)
    run["npc_fleets"].append(fleet)
    return fleet


def find_card(store: DataStore, role: str, tier: int) -> str:
    """The first canon card of ``role`` at exactly ``tier`` (file order —
    the data-driven fixture convention: the suites pin behavior, not ids)."""
    for card in captains.canon_list(store):
        if str(card.get("role", "")) == role \
                and int(card.get("tier", 0)) == tier:
            return str(card.get("id", ""))
    return ""


def options_by_id(store: DataStore, st: PersonState, run: dict[str, Any],
                  fleet: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {str(option["id"]): option
            for option in hail_options.options_for(store, st, run, fleet)}


# ===========================================================================
# captains — canon access, lazy state, lifecycle, stance, familiarity
# ===========================================================================


class TestCaptainsCanon:
    def test_canon_access(self, store: DataStore) -> None:
        assert len(captains.canon_list(store)) > 0
        pirate = captains.captain(store, PIRATE_ID)
        assert pirate.get("role") == "pirate" and pirate.get("tier") == 1
        assert captains.captain(store, "cap_nobody") == {}
        # Fixture existence (the data-driven fixtures below depend on it).
        assert find_card(store, "privateer", 3)
        assert find_card(store, "trader", 2)

    def test_speed_jitter_is_the_pinned_godot_hash(
            self, store: DataStore) -> None:
        # Values captured from live `godot --headless` probes of the pinned
        # toolchain (Godot v4.7.stable.official.5b4e0cb0f) — the port's
        # djb2 String.hash must reproduce them exactly.
        assert captains.speed_jitter(PIRATE_ID) == pytest.approx(-0.098)
        assert captains.speed_jitter("") == pytest.approx(0.055)
        assert captains.speed_jitter("cap_pirate_0001") == pytest.approx(-0.073)
        assert captains.speed_jitter("cap_trader_0001") == pytest.approx(0.012)
        assert captains.speed_jitter("a") == pytest.approx(0.087)
        assert captains.speed_jitter("航海者") == pytest.approx(-0.087)
        # Stable across calls, in range, quantized to 1/1000 steps.
        for id_ in (PIRATE_ID, "cap_pirate_0001", "cap_trader_0001",
                    "cap_leg_trader_05", "", "cap_nobody"):
            first = captains.speed_jitter(id_)
            assert captains.speed_jitter(id_) == first
            assert -captains.SPEED_JITTER_MAX <= first \
                <= captains.SPEED_JITTER_MAX
            assert first * 1000 == pytest.approx(round(first * 1000))


class TestCaptainsState:
    def test_lazy_defaults_and_save_shape(self, store: DataStore) -> None:
        captain_states: dict[str, Any] = {}
        entry = captains.state(captain_states, store, PIRATE_ID)
        # Reading an unmet captain creates NO state entry …
        assert PIRATE_ID not in captain_states
        # … and reads the §4.15 defaults (tier_now = canon tier).
        assert set(entry.keys()) == set(SAVE_SHAPE_KEYS)
        assert entry == {
            "status": "active", "return_day": 0, "tier_now": 1, "stance": 0,
            "familiarity": 0, "dossier_seen": False, "defeats": 0, "wins": 0,
        }
        # The defaults are a THROWAWAY copy — mutating them corrupts nothing.
        entry["stance"] = 99
        assert captains.state(captain_states, store, PIRATE_ID)["stance"] == 0
        # ensure() creates the entry on first touch, idempotently.
        captains.ensure(captain_states, store, PIRATE_ID)
        assert PIRATE_ID in captain_states
        captains.ensure(captain_states, store, PIRATE_ID)["wins"] = 2
        assert captains.ensure(
            captain_states, store, PIRATE_ID)["wins"] == 2
        # An unknown id still reads safe defaults (tier_now floor 1).
        assert captains.state(
            captain_states, store, "cap_nobody")["tier_now"] == 1


class TestCaptainsLifecycle:
    def test_return_queue_boundary(self, store: DataStore) -> None:
        captain_states: dict[str, Any] = {}
        captains.deploy(captain_states, store, PIRATE_ID)
        entry = captains.defeat(captain_states, store, PIRATE_ID, 100)
        assert entry["status"] == "returning"
        assert entry["return_day"] == 160  # day + 60, locked
        assert entry["defeats"] == 1
        assert not captains.is_deployed(captain_states, PIRATE_ID)
        assert not captains.is_spawnable(captain_states, store,
                                         PIRATE_ID, 120)
        captains.day_tick(captain_states, 159)
        assert captains.state(
            captain_states, store, PIRATE_ID)["status"] == "returning"
        captains.day_tick(captain_states, 160)
        entry = captains.state(captain_states, store, PIRATE_ID)
        assert entry["status"] == "active"
        assert entry["return_day"] == 0
        assert captains.is_spawnable(captain_states, store, PIRATE_ID, 160)
        # A second defeat on another day books the same +60 offset.
        captains.defeat(captain_states, store, PIRATE_ID, 10)
        assert captains.state(
            captain_states, store, PIRATE_ID)["return_day"] == 70

    def test_return_refit_keeps_tier_and_card(self, store: DataStore) -> None:
        """The refit behavior: the captain returns under its OWN canon card
        (names are never reused — the roster is closed), tier_now carried
        through the queue untouched."""
        captain_states: dict[str, Any] = {}
        card = captains.captain(store, PIRATE_ID)
        captains.defeat(captain_states, store, PIRATE_ID, 100, crushed=False)
        captains.day_tick(captain_states, 160)
        entry = captains.state(captain_states, store, PIRATE_ID)
        assert entry["status"] == "active"
        assert entry["tier_now"] == int(card["tier"])
        # The canon card itself is save-independent and untouched.
        assert captains.captain(store, PIRATE_ID) == card

    def test_tier_drift(self, store: DataStore) -> None:
        captain_states: dict[str, Any] = {}
        tier2 = find_card(store, "privateer", 2)
        tier3 = find_card(store, "privateer", 3)
        # The tier-1 pirate card: a crushed defeat clamps at the floor.
        captains.defeat(captain_states, store, PIRATE_ID, 10, crushed=True)
        assert captains.state(
            captain_states, store, PIRATE_ID)["tier_now"] == 1
        # Wins climb one tier each and clamp at 3; the counter keeps counting.
        captains.win(captain_states, store, tier2, 10)
        assert captains.state(captain_states, store, tier2)["tier_now"] == 3
        assert captains.state(captain_states, store, tier2)["wins"] == 1
        captains.win(captain_states, store, tier2, 11)
        assert captains.state(captain_states, store, tier2)["tier_now"] == 3
        # A non-crushed defeat drifts nothing; the drifted tier survives
        # the queue.
        captains.defeat(captain_states, store, tier3, 10, crushed=False)
        assert captains.state(captain_states, store, tier3)["tier_now"] == 3
        captains.day_tick(captain_states, 70)
        assert captains.state(captain_states, store, tier3)["tier_now"] == 3

    def test_crushed_defeat_drops_one_tier(self, store: DataStore) -> None:
        captain_states: dict[str, Any] = {}
        tier2 = find_card(store, "pirate", 2)
        captains.defeat(captain_states, store, tier2, 20, crushed=True)
        assert captains.state(captain_states, store, tier2)["tier_now"] == 1


class TestCaptainsStance:
    def test_shared_delta_constants(self) -> None:
        assert captains.STANCE_BEFRIEND == 1
        assert captains.STANCE_INTIMIDATE_WIN == -1
        assert captains.STANCE_INTIMIDATE_FAIL == -2
        assert captains.STANCE_NEMESIS_DEFEAT == -2
        assert captains.STANCE_ATTACK_NONHOSTILE == -1

    def test_adjust_clamps(self, store: DataStore) -> None:
        captain_states: dict[str, Any] = {}
        assert captains.stance(captain_states, PIRATE_ID) == 0
        assert captains.adjust_stance(
            captain_states, store, PIRATE_ID, captains.STANCE_BEFRIEND) == 1
        assert captains.adjust_stance(
            captain_states, store, PIRATE_ID,
            captains.STANCE_NEMESIS_DEFEAT) == -1
        assert captains.adjust_stance(captain_states, store, PIRATE_ID,
                                      -100) == -10
        assert captains.adjust_stance(captain_states, store, PIRATE_ID,
                                      100) == 10
        assert captains.adjust_stance(
            captain_states, store, PIRATE_ID,
            captains.STANCE_ATTACK_NONHOSTILE) == 9

    def test_threshold_flags_nemesis(self, store: DataStore) -> None:
        assert captains.NEMESIS_STANCE == -3
        assert captains.NEMESIS_ROLES == ("pirate", "privateer")
        captain_states: dict[str, Any] = {}
        assert not captains.is_nemesis(captain_states, store, PIRATE_ID)
        captains.adjust_stance(captain_states, store, PIRATE_ID, -3)
        assert captains.is_nemesis(captain_states, store, PIRATE_ID)
        captains.adjust_stance(captain_states, store, PIRATE_ID, -7)
        assert captains.is_nemesis(captain_states, store, PIRATE_ID)
        captains.adjust_stance(captain_states, store, PIRATE_ID, 8)
        assert not captains.is_nemesis(captain_states, store, PIRATE_ID)
        privateer = find_card(store, "privateer", 2)
        captains.adjust_stance(captain_states, store, privateer, -4)
        assert captains.is_nemesis(captain_states, store, privateer)
        trader = find_card(store, "trader", 1)
        captains.adjust_stance(captain_states, store, trader, -10)
        assert not captains.is_nemesis(captain_states, store, trader)
        hunter = find_card(store, "hunter", 2)
        captains.adjust_stance(captain_states, store, hunter, -10)
        assert not captains.is_nemesis(captain_states, store, hunter)
        assert not captains.is_nemesis(captain_states, store, "cap_nobody")


class TestCaptainsFamiliarity:
    def test_tiers_3_6_10(self, store: DataStore) -> None:
        captain_states: dict[str, Any] = {}
        assert captains.familiarity_tier(captain_states, PIRATE_ID) == 0
        expected = {2: 0, 3: 1, 5: 1, 6: 2, 9: 2, 10: 3, 11: 3}
        for value, tier in expected.items():
            probe = f"probe_{value}"
            captains.ensure(captain_states, store, probe)["familiarity"] = value
            assert captains.familiarity_tier(captain_states, probe) == tier

    def test_add_clamps(self, store: DataStore) -> None:
        captain_states: dict[str, Any] = {}
        trader = find_card(store, "trader", 1)
        captains.add_familiarity(captain_states, store, trader)
        assert captains.familiarity(captain_states, trader) == 1
        captains.add_familiarity(captain_states, store, trader, 200)
        assert captains.familiarity(captain_states, trader) \
            == captains.FAMILIARITY_MAX == 99
        assert captains.add_familiarity(
            captain_states, store, trader, -500) == 0

    def test_dossier_flag_persists(self, store: DataStore) -> None:
        captain_states: dict[str, Any] = {}
        assert not captains.dossier_seen(captain_states, PIRATE_ID)
        captains.mark_dossier_seen(captain_states, store, PIRATE_ID)
        assert captains.dossier_seen(captain_states, PIRATE_ID)
        assert captains.state(
            captain_states, store, PIRATE_ID)["dossier_seen"] is True


class TestCaptainsDeployment:
    def test_exclusivity(self, store: DataStore) -> None:
        captain_states: dict[str, Any] = {}
        trader = find_card(store, "trader", 1)
        assert captains.is_spawnable(captain_states, store, trader, 5)
        captains.deploy(captain_states, store, trader)
        assert trader in captain_states  # deploy touches the entry lazily
        assert captains.is_deployed(captain_states, trader)
        assert not captains.is_spawnable(captain_states, store, trader, 5)
        captains.release(captain_states, trader)
        assert not captains.is_deployed(captain_states, trader)
        assert captains.is_spawnable(captain_states, store, trader, 5)
        # release erases the runtime key — an idle entry matches the save
        # shape exactly.
        assert "deployed" not in captain_states[trader]
        assert set(captain_states[trader].keys()) == set(SAVE_SHAPE_KEYS)
        # Defeat keeps the captain out even though the deployment cleared.
        captains.defeat(captain_states, store, trader, 5, crushed=False)
        captains.release(captain_states, trader)
        assert not captains.is_spawnable(captain_states, store, trader, 5)

    def test_release_of_unmet_is_a_noop(self, store: DataStore) -> None:
        captain_states: dict[str, Any] = {}
        captains.release(captain_states, "cap_nobody")
        assert "cap_nobody" not in captain_states
        assert not captains.is_spawnable(captain_states, store,
                                         "cap_nobody", 5)

    def test_reset_deployments_keeps_lifecycle_state(
            self, store: DataStore) -> None:
        captain_states: dict[str, Any] = {}
        trader = find_card(store, "trader", 1)
        captains.deploy(captain_states, store, trader)
        captains.adjust_stance(captain_states, store, trader, 2)
        captains.reset_deployments(captain_states)
        assert not captains.is_deployed(captain_states, trader)
        assert captains.stance(captain_states, trader) == 2


# ===========================================================================
# hail_options — the at-sea hail
# ===========================================================================


@pytest.fixture()
def hail_world(store: DataStore) -> tuple[DataStore, PersonState,
                                          dict[str, Any], str, str]:
    """The tools/test_hail.gd fixture family: a bare run at tile (100, 100)
    with lisbon + seville known, day 100, a sloop flagship, empty ecology."""
    hail_options.reset_session()
    hail_options.reset_test_doubles()
    st = make_person()
    fleet = [make_ship(store, "sloop")]
    run = make_run(pos=(100, 100))
    run["fleet"] = fleet
    trader_id = find_card(store, "trader", 1)
    coaster_id = find_card(store, "coaster", 1)
    return store, st, run, trader_id, coaster_id


def hail_fleet(run: dict[str, Any], role: str, captain_id: str,
               x: int = 100, y: int = 100, dest: str = "",
               cargo: dict[str, int] | None = None) -> dict[str, Any]:
    """A §4.15-shaped target fleet at the player tile (in hail range)."""
    return {
        "id": "nf_hail_fixture",
        "role": role,
        "nation_id": "",
        "cell": {"x": x, "y": y},
        "route": {"lanes": ["lane_a"], "leg": 0, "tile_index": 0, "legs": []},
        "cargo": dict(cargo or {}),
        "captain_id": captain_id,
        "dest_port_id": dest,
        "cooldown_until_day": 0,
        "seed": 0,
        "dwell_until_day": 0,
        "anchor_cell": None,
    }


class TestHailRangeGuard:
    def test_in_range_defends_the_talk_gate(self, hail_world) -> None:
        store, st, run, trader_id, _ = hail_world
        near = hail_fleet(run, "trader", trader_id)
        assert len(hail_options.options_for(store, st, run, near)) == 4
        at_two = hail_fleet(run, "trader", trader_id, x=102)
        assert hail_options.in_range(run["world"]["position"], at_two)
        assert hail_options.options_for(store, st, run, at_two)
        far = hail_fleet(run, "trader", trader_id, x=103)
        assert not hail_options.in_range(run["world"]["position"], far)
        assert hail_options.options_for(store, st, run, far) == []
        payload = hail_options.resolve(store, st, run,
                                       hail_options.OPTION_RUMOURS, far)
        assert payload["ok"] is False

    def test_unknown_captain_displays_the_fallback(
            self, hail_world) -> None:
        store, _st, run, _trader_id, _coaster_id = hail_world
        unknown = hail_fleet(run, "pirate", "")
        assert hail_options.display_name(store, unknown) == {}
        assert hail_options.UNKNOWN_NAME_KEY == "interact.unknown_name"


class TestHailRoleStanceMatrix:
    def test_all_16_cells(self, hail_world) -> None:
        store, st, run, trader_id, coaster_id = hail_world
        bare = {"pirate": find_card(store, "pirate", 1),
                "hunter": find_card(store, "hunter", 2)}
        for stance in (-5, 0, 2, 3):
            for role, captain_id in (("trader", trader_id),
                                     ("coaster", coaster_id)):
                hail_options.reset_session()
                captains.ensure(run["captain_states"], store,
                                captain_id)["stance"] = stance
                by_id = options_by_id(store, st, run,
                                      hail_fleet(run, role, captain_id))
                assert hail_options.OPTION_SUPPLIES in by_id
                assert by_id[hail_options.OPTION_RUMOURS]["enabled"] is True
                assert by_id[hail_options.OPTION_RUMOURS]["intel"] \
                    == (stance >= 2)
                assert by_id[hail_options.OPTION_INTIMIDATE]["enabled"] is True
                assert by_id[hail_options.OPTION_BEFRIEND]["enabled"] is True
            for role, captain_id in bare.items():
                hail_options.reset_session()
                captains.ensure(run["captain_states"], store,
                                captain_id)["stance"] = stance
                by_id = options_by_id(store, st, run,
                                      hail_fleet(run, role, captain_id))
                assert hail_options.OPTION_SUPPLIES not in by_id
                assert by_id[hail_options.OPTION_RUMOURS]["enabled"] is True
                assert by_id[hail_options.OPTION_RUMOURS]["intel"] \
                    == (stance >= 2)
                assert by_id[hail_options.OPTION_INTIMIDATE]["enabled"] is True
                assert by_id[hail_options.OPTION_BEFRIEND]["enabled"] is True

    def test_rows_carry_their_payloads(self, hail_world) -> None:
        store, st, run, trader_id, _ = hail_world
        by_id = options_by_id(store, st, run,
                              hail_fleet(run, "trader", trader_id))
        chance = by_id[hail_options.OPTION_INTIMIDATE]["chance"]
        assert hail_options.INTIMIDATE_P_MIN <= chance \
            <= hail_options.INTIMIDATE_P_MAX
        prices = by_id[hail_options.OPTION_SUPPLIES]["unit_prices"]
        assert prices == {"provisions": 3, "water": 1}  # the ×1.5 units


class TestHailPriceBase:
    def test_dest_then_nearest_known(self, store: DataStore) -> None:
        # The GDScript fixture tiles: seville's and lisbon's projections.
        run_seville = make_run(pos=SEVILLE_TILE)
        dest_fleet = hail_fleet(run_seville, "trader", "cap_leg_trader_05",
                                dest="seville")
        assert hail_options.price_base_port(
            store, run_seville["world"]["position"],
            run_seville["known_ports"], dest_fleet) == "seville"
        no_dest = hail_fleet(run_seville, "trader", "cap_leg_trader_05")
        assert hail_options.price_base_port(
            store, run_seville["world"]["position"],
            run_seville["known_ports"], no_dest) == "seville"
        run_lisbon = make_run(pos=LISBON_TILE)
        assert hail_options.price_base_port(
            store, run_lisbon["world"]["position"],
            run_lisbon["known_ports"], no_dest) == "lisbon"
        run_nowhere = make_run(pos=LISBON_TILE, known=[])
        assert hail_options.price_base_port(
            store, run_nowhere["world"]["position"],
            run_nowhere["known_ports"], no_dest) == ""
        bad_dest = hail_fleet(run_seville, "trader", "cap_leg_trader_05",
                              dest="atlantis")
        assert hail_options.price_base_port(
            store, run_seville["world"]["position"],
            run_seville["known_ports"], bad_dest) == "seville"


class TestHailPriceMatrix:
    def test_negotiation_points(self, hail_world) -> None:
        store, st, run, trader_id, _ = hail_world
        assert hail_options.negotiation_discount_points(st, store) == 0
        st.player["skills"]["negotiation"] = 40
        assert hail_options.negotiation_discount_points(st, store) == 4
        st.player["skills"]["negotiation"] = 100
        assert hail_options.negotiation_discount_points(st, store) == 5
        st.player["skills"]["negotiation"] = 0

    def test_pinned_totals(self, hail_world) -> None:
        """The closed form: units = 1500 × (1250 if stance ≥ +3) ×
        (1000 − 10·points), floored once per kind on the full product
        (incl. qty) — the GDScript matrix case-for-case."""
        store, st, run, trader_id, _ = hail_world
        fleet = hail_fleet(run, "trader", trader_id, dest="seville")
        matrix = {
            # (stance, negotiation, qty, expected total, expected prov unit)
            "base": (0, 0, 10, 45, 3),
            "warm": (3, 0, 10, 55, 3),
            "warm_neg40": (3, 40, 10, 54, 3),
            "warm_neg100": (3, 100, 10, 52, 3),
            "neg40": (0, 40, 10, 42, 2),
        }
        for name, (stance, negotiation, qty, total, prov_unit) in \
                matrix.items():
            hail_options.reset_session()
            fresh_states: dict[str, Any] = {}
            run["captain_states"] = fresh_states
            captains.ensure(fresh_states, store, trader_id)["stance"] = stance
            st.player["skills"]["negotiation"] = negotiation
            assert hail_options.supplies_pair_cost(
                store, st, fresh_states, run["world"]["position"],
                run["known_ports"], fleet, qty) == total, name
            assert hail_options.supply_unit_price(
                store, st, fresh_states, run["world"]["position"],
                run["known_ports"], fleet, "provisions") == prov_unit, name

    def test_deepest_discount_stays_above_the_base(
            self, hail_world) -> None:
        store, st, run, trader_id, _ = hail_world
        fleet = hail_fleet(run, "trader", trader_id, dest="seville")
        captains.ensure(run["captain_states"], store, trader_id)["stance"] = 3
        st.player["skills"]["negotiation"] = 100
        assert hail_options.supply_unit_price(
            store, st, run["captain_states"], run["world"]["position"],
            run["known_ports"], fleet, "water") >= 1
        assert hail_options.supplies_pair_cost(
            store, st, run["captain_states"], run["world"]["position"],
            run["known_ports"], fleet, 10) == 52


class TestHailSuppliesResolve:
    def test_accept_applies_exactly_once(self, hail_world) -> None:
        store, st, run, trader_id, _ = hail_world
        fleet = hail_fleet(run, "trader", trader_id, dest="seville")
        payload = hail_options.resolve(store, st, run,
                                       hail_options.OPTION_SUPPLIES,
                                       fleet, 10)
        assert payload["ok"] is True
        assert payload["gold_delta"] == -45
        assert payload["cargo_gained"] == {"provisions": 10, "water": 10}
        assert st.gold == 10000 - 45
        player_fleet = run["fleet"]
        from server.sim.fleet import fleet as fleet_lib
        assert fleet_lib.supplies(player_fleet, "provisions") == 10
        assert fleet_lib.supplies(player_fleet, "water") == 10
        assert payload["lines"][0]["key"] == "hail.supplies.result"
        # Buying supplies touches no stance and no fame.
        assert run["captain_states"] == {}
        assert st.fame == 0

    def test_refusals_touch_nothing(self, hail_world) -> None:
        store, st, run, trader_id, _ = hail_world
        fleet = hail_fleet(run, "trader", trader_id, dest="seville")
        assert hail_options.resolve(store, st, run,
                                    hail_options.OPTION_SUPPLIES,
                                    fleet, 0)["ok"] is False
        st.gold = 44
        assert hail_options.resolve(store, st, run,
                                    hail_options.OPTION_SUPPLIES,
                                    fleet, 10)["ok"] is False
        assert st.gold == 44
        from server.sim.fleet import fleet as fleet_lib
        assert fleet_lib.supplies(run["fleet"], "provisions") == 0

    def test_max_qty_bounds(self, hail_world) -> None:
        store, st, run, trader_id, _ = hail_world
        fleet = hail_fleet(run, "trader", trader_id, dest="seville")
        # The sloop holds 60 → 60 free / 2 units per bundle = 30.
        assert hail_options.supplies_max_qty(
            store, st, run["captain_states"], run["world"]["position"],
            run["known_ports"], fleet, run["fleet"]) == 30
        st.gold = 11
        assert hail_options.supplies_max_qty(
            store, st, run["captain_states"], run["world"]["position"],
            run["known_ports"], fleet, run["fleet"]) == 2

    def test_full_hold_refuses(self, hail_world) -> None:
        store, st, run, trader_id, _ = hail_world
        fleet = hail_fleet(run, "trader", trader_id, dest="seville")
        from server.sim.fleet import fleet as fleet_lib
        fleet_lib.add_goods(run["fleet"], "cloth", 60)
        assert fleet_lib.fleet_free(run["fleet"]) == 0
        assert hail_options.resolve(store, st, run,
                                    hail_options.OPTION_SUPPLIES,
                                    fleet, 10)["ok"] is False


class TestHailIntimidate:
    def test_chance_pins_with_card_doubles(self, hail_world) -> None:
        store, st, run, _trader_id, _coaster_id = hail_world
        hail_options.reset_test_doubles()
        hail_options._CAPTAINS_TEST_DOUBLES["cap_double_even"] = EVEN_CARD
        hail_options._CAPTAINS_TEST_DOUBLES["cap_double_weak"] = WEAK_CARD
        try:
            fleet = hail_fleet(run, "pirate", "cap_double_even")  # theirs 40
            # share 0.5, courage 10 → term 0 → p exactly 0.5.
            st.player["skills"]["swordplay"] = 40
            assert hail_options.intimidate_chance(
                store, st, run["captain_states"], run["fleet"], fleet) \
                == pytest.approx(0.5)
            # Stance −5 penalty: 0.5 − 5 × 0.05 = 0.25.
            captains.ensure(run["captain_states"], store,
                            "cap_double_even")["stance"] = -5
            assert hail_options.intimidate_chance(
                store, st, run["captain_states"], run["fleet"], fleet) \
                == pytest.approx(0.25)
            # floor(COU/200) is 0 across the whole attribute band: courage
            # 100 feeds the DUEL base (+floor(COU/20)), so swordplay steps
            # down to hold `ours` at exactly 40.
            hail_options.reset_session()
            run["captain_states"] = {}
            st.player["skills"]["swordplay"] = 35  # 35 + floor(100/20) = 40
            st.player["attributes"]["courage"] = 100
            captains.ensure(run["captain_states"], store,
                            "cap_double_even")["stance"] = -5
            assert hail_options.intimidate_chance(
                store, st, run["captain_states"], run["fleet"], fleet) \
                == pytest.approx(0.25)
            # Upper clamp: ours 100 vs theirs 0 → 1.0 → 0.95 (both courages).
            hail_options.reset_session()
            run["captain_states"] = {}
            st.player["skills"]["swordplay"] = 100
            st.player["attributes"]["courage"] = 10
            weak = hail_fleet(run, "pirate", "cap_double_weak")
            assert hail_options.intimidate_chance(
                store, st, run["captain_states"], run["fleet"], weak) \
                == pytest.approx(0.95)
            st.player["attributes"]["courage"] = 100
            assert hail_options.intimidate_chance(
                store, st, run["captain_states"], run["fleet"], weak) \
                == pytest.approx(0.95)
            # Lower clamp: ours 0 vs theirs 40 at stance −5 → 0.05.
            hail_options.reset_session()
            run["captain_states"] = {}
            st.player["skills"]["swordplay"] = 0
            st.player["attributes"]["courage"] = 10
            captains.ensure(run["captain_states"], store,
                            "cap_double_even")["stance"] = -5
            assert hail_options.intimidate_chance(
                store, st, run["captain_states"], run["fleet"], fleet) \
                == pytest.approx(0.05)
        finally:
            hail_options.reset_test_doubles()

    def test_player_strength_sums_escort_captains(
            self, store: DataStore) -> None:
        st = make_person(swordplay=40)
        st.player["officers"] = [FIRST_OFFICER]
        st.officer_states[FIRST_OFFICER] = {
            "loyalty": 50, "sea_days": 0, "post_id": "captain",
            "ship_id": "sloop", "talk_cd_day": 0, "gift_cd_day": 0,
            "defeats": 0, "wage_mult": 1.0,
        }
        fleet = [make_ship(store, "sloop"), make_ship(store, "sloop"),
                 make_ship(store, "latin")]
        officer = store.get_officer(FIRST_OFFICER)
        rating = hail_options.card_duel_rating(officer)
        assert rating == 6  # swordplay 6 + floor(19/20)
        # ours = flagship base 40 + the captained sloop escort's rating 6
        # (the captain-less latin escort adds 0 — a different type stays
        # captain-less).
        assert hail_options.player_strength(store, st, fleet) == 46

    def test_success_half_cargo_fame_and_stance(self, hail_world) -> None:
        store, st, run, _trader_id, _coaster_id = hail_world
        st.player["skills"]["swordplay"] = 100
        pirate_id = find_card(store, "pirate", 1)
        fleet = hail_fleet(run, "pirate", pirate_id,
                           cargo={"cloth": 10, "spices": 7})
        payload = hail_options.resolve(store, st, run,
                                       hail_options.OPTION_INTIMIDATE,
                                       fleet, 0, 0.0)
        assert payload["ok"] is True and "made_hostile" not in payload
        # Half the cargo handed over, FLOORED per good (5 + 3).
        assert payload["cargo_gained"] == {"cloth": 5, "spices": 3}
        # The target's own hold keeps the other half (5 + 4).
        assert fleet["cargo"]["cloth"] == 5 and fleet["cargo"]["spices"] == 4
        from server.sim.fleet import fleet as fleet_lib
        assert fleet_lib.held(run["fleet"], "cloth") == 5
        assert fleet_lib.held(run["fleet"], "spices") == 3
        assert payload["fame_delta"] == 5 and st.fame == 5
        assert payload["stance_delta"] == captains.STANCE_INTIMIDATE_WIN
        assert captains.stance(run["captain_states"], pirate_id) == -1
        assert payload["lines"][0]["key"] == "hail.intimidate.win"

    def test_supplies_keys_route_through_the_pools(self, hail_world) -> None:
        store, st, run, trader_id, _ = hail_world
        st.player["skills"]["swordplay"] = 100
        mixed = hail_fleet(run, "trader", trader_id,
                           cargo={"provisions": 4, "cloth": 6})
        payload = hail_options.resolve(store, st, run,
                                       hail_options.OPTION_INTIMIDATE,
                                       mixed, 0, 0.0)
        from server.sim.fleet import fleet as fleet_lib
        assert payload["cargo_gained"]["provisions"] == 2
        assert fleet_lib.supplies(run["fleet"], "provisions") == 2
        assert payload["cargo_gained"]["cloth"] == 3

    def test_failure_makes_hostile_and_moves_nothing(
            self, hail_world) -> None:
        store, st, run, _trader_id, _coaster_id = hail_world
        st.player["skills"]["swordplay"] = 0
        pirate_id = find_card(store, "pirate", 1)
        hostile = hail_fleet(run, "pirate", pirate_id, cargo={"cloth": 10})
        payload = hail_options.resolve(store, st, run,
                                       hail_options.OPTION_INTIMIDATE,
                                       hostile, 0, 0.99)
        assert payload["ok"] is True and payload["made_hostile"] is True
        assert payload["stance_delta"] == captains.STANCE_INTIMIDATE_FAIL
        assert captains.stance(run["captain_states"], pirate_id) == -2
        assert st.fame == 0
        from server.sim.fleet import fleet as fleet_lib
        assert fleet_lib.held(run["fleet"], "cloth") == 0
        assert hostile["cargo"]["cloth"] == 10
        assert payload["lines"][0]["key"] == "hail.intimidate.lose"

    def test_seeded_default_roll_predicts_and_replays(
            self, hail_world) -> None:
        store, st, run, _trader_id, _coaster_id = hail_world
        st.player["skills"]["swordplay"] = 0
        pirate_id = find_card(store, "pirate", 1)
        seed_fleet = hail_fleet(run, "pirate", pirate_id,
                                cargo={"cloth": 10})
        seed = hail_options.roll_seed(st.day, st.gold, len(run["fleet"]),
                                      seed_fleet)
        rng = GodotRng(seed=seed)
        predicted_hostile = rng.randf() >= hail_options.intimidate_chance(
            store, st, run["captain_states"], run["fleet"], seed_fleet)
        first = hail_options.resolve(store, st, run,
                                     hail_options.OPTION_INTIMIDATE,
                                     seed_fleet, 0)
        assert first["made_hostile"] is predicted_hostile
        # An identical reset replays the identical seeded outcome.
        hail_options.reset_session()
        st2 = make_person(swordplay=0)
        run2 = make_run(pos=(100, 100))
        run2["fleet"] = [make_ship(store, "sloop")]
        seed_fleet_2 = hail_fleet(run2, "pirate", pirate_id,
                                  cargo={"cloth": 10})
        second = hail_options.resolve(store, st2, run2,
                                      hail_options.OPTION_INTIMIDATE,
                                      seed_fleet_2, 0)
        assert second["made_hostile"] is predicted_hostile

    def test_empty_target_still_pays_fame(self, hail_world) -> None:
        store, st, run, _trader_id, _coaster_id = hail_world
        st.player["skills"]["swordplay"] = 100
        pirate_id = find_card(store, "pirate", 1)
        payload = hail_options.resolve(
            store, st, run, hail_options.OPTION_INTIMIDATE,
            hail_fleet(run, "pirate", pirate_id), 0, 0.0)
        assert payload["ok"] is True and payload["fame_delta"] == 5
        assert payload["cargo_gained"] == {}


class TestHailBefriend:
    def test_once_per_captain_per_day(self, hail_world) -> None:
        store, st, run, trader_id, _ = hail_world
        fleet = hail_fleet(run, "trader", trader_id)
        payload = hail_options.resolve(store, st, run,
                                       hail_options.OPTION_BEFRIEND, fleet)
        assert payload["ok"] is True
        assert payload["stance_delta"] == captains.STANCE_BEFRIEND
        assert captains.stance(run["captain_states"], trader_id) == 1
        assert payload["lines"][0]["key"] == "hail.befriend.result"
        # A same-day repeat refuses with the used reason, no stance shift.
        again = hail_options.resolve(store, st, run,
                                     hail_options.OPTION_BEFRIEND, fleet)
        assert again["ok"] is False
        assert again["lines"][0]["key"] == "hail.befriend.used"
        assert captains.stance(run["captain_states"], trader_id) == 1
        # The used row grays out with its reason key.
        by_id = options_by_id(store, st, run, fleet)
        assert by_id[hail_options.OPTION_BEFRIEND]["enabled"] is False
        assert by_id[hail_options.OPTION_BEFRIEND]["reason_key"] \
            == "hail.befriend.used"
        # The next day it re-enables and applies again (stance 2).
        st.day = 101
        assert options_by_id(store, st, run,
                             fleet)[hail_options.OPTION_BEFRIEND][
            "enabled"] is True
        payload2 = hail_options.resolve(store, st, run,
                                        hail_options.OPTION_BEFRIEND, fleet)
        assert payload2["ok"] is True
        assert captains.stance(run["captain_states"], trader_id) == 2
        # reset_session clears the day map (the fresh-sim path).
        hail_options.reset_session()
        payload3 = hail_options.resolve(store, st, run,
                                        hail_options.OPTION_BEFRIEND, fleet)
        assert payload3["ok"] is True
        assert captains.stance(run["captain_states"], trader_id) == 3

    def test_per_captain_not_per_fleet(self, hail_world) -> None:
        store, st, run, trader_id, _coaster_id = hail_world
        st.day = 200
        hail_options.reset_session()
        first = hail_options.resolve(
            store, st, run, hail_options.OPTION_BEFRIEND,
            hail_fleet(run, "trader", trader_id))
        pirate_id = find_card(store, "pirate", 1)
        second = hail_options.resolve(
            store, st, run, hail_options.OPTION_BEFRIEND,
            hail_fleet(run, "pirate", pirate_id))
        assert first["ok"] is True and second["ok"] is True


class TestHailAskRumours:
    def test_intel_exactly_at_stance_plus_2(self, hail_world) -> None:
        store, st, run, trader_id, _ = hail_world
        fleet = hail_fleet(run, "trader", trader_id, dest="seville")
        plain = hail_options.resolve(store, st, run,
                                     hail_options.OPTION_RUMOURS, fleet)
        assert plain["ok"] is True and "intel" not in plain
        assert len(plain["lines"]) == 1
        assert st.gold == 10000  # asking rumours is free
        captains.ensure(run["captain_states"], store, trader_id)["stance"] = 1
        assert "intel" not in hail_options.resolve(
            store, st, run, hail_options.OPTION_RUMOURS, fleet)
        captains.ensure(run["captain_states"], store, trader_id)["stance"] = 2
        payload = hail_options.resolve(store, st, run,
                                       hail_options.OPTION_RUMOURS, fleet)
        intel = payload["intel"]
        assert intel["dest_port_id"] == "seville"
        assert intel["lanes"] == ["lane_a"]
        assert len(payload["lines"]) == 2
        assert payload["lines"][1]["key"] == "hail.rumours.result_intel"
        assert st.gold == 10000
        assert captains.stance(run["captain_states"], trader_id) == 2


# ===========================================================================
# interactions — targeting, verbs, intercept, inspect, appoint, encounter
# ===========================================================================


@pytest.fixture()
def interaction_world(store: DataStore) -> tuple[DataStore, PersonState,
                                                 dict[str, Any]]:
    """The tools/test_interactions.gd fixture family: navigation 0 keeps the
    sighting radius at the pinned base 48 + floor(0/12) = 48 (20-* §4.11)."""
    st = make_person()
    st.player["skills"]["navigation"] = 0
    run = make_run(pos=OPEN_CELL, known=[])
    return store, st, run


class TestTargeting:
    def test_exact_tile_and_sorted_pick_list(
            self, interaction_world) -> None:
        store, st, run = interaction_world
        trader = make_fleet(run, "trader", "portugal", OPEN_CELL,
                            "fx_target_trader", "cap_trader_0001")
        assert interactions.target_at(run, OPEN_CELL)["id"] == trader["id"]
        assert len(interactions.fleets_at(run, OPEN_CELL)) == 1
        make_fleet(run, "pirate", "", OPEN_CELL, "fx_a_pirate", PIRATE_ID)
        listed = interactions.fleets_at(run, OPEN_CELL)
        assert [str(entry["id"]) for entry in listed] \
            == ["fx_a_pirate", "fx_target_trader"]
        assert interactions.target_at(run, (OPEN_CELL[0] + 3, OPEN_CELL[1])) \
            == {}

    def test_dateline_seam_wraps_both_ways(self, interaction_world) -> None:
        store, _st, run = interaction_world
        make_fleet(run, "courier", "spain", SEAM_EAST, "fx_seam_courier")
        assert interactions.target_at(run, SEAM_EAST)["id"] == "fx_seam_courier"
        assert interactions.target_at(run, (-1, SEAM_EAST[1]))["id"] \
            == "fx_seam_courier"
        assert interactions.target_at(run, (8639, SEAM_EAST[1]))["id"] \
            == "fx_seam_courier"
        # x = 4319 and x = 0 are different tiles (Chebyshev 1 apart).
        assert interactions.target_at(run, SEAM_WEST) == {}

    def test_in_range_wraps_across_the_seam(self, store: DataStore) -> None:
        st = make_person()
        run = make_run(pos=SEAM_EAST, known=[])
        west = make_fleet(run, "trader", "england", SEAM_WEST,
                          "fx_west_trader")
        assert interactions.in_range(run, st, store, west)
        assert not interactions.in_range(run, st, store, west, radius=0)


class TestVerbs:
    def test_coaster_has_no_attack_verb(self, interaction_world) -> None:
        _store, _st, run = interaction_world
        coaster = make_fleet(run, "coaster", "portugal", OPEN_CELL,
                             "fx_verbs_coaster")
        assert interactions.verbs_for(coaster) == ["inspect", "talk"]

    @pytest.mark.parametrize("role", ["trader", "pirate", "privateer",
                                      "patrol", "courier", "hunter",
                                      "treasure"])
    def test_every_other_role_offers_three_verbs_in_row_order(
            self, interaction_world, role: str) -> None:
        _store, _st, run = interaction_world
        fleet = make_fleet(run, role, "portugal",
                           (OPEN_CELL[0] + 2, OPEN_CELL[1]))
        assert interactions.verbs_for(fleet) \
            == ["inspect", "talk", "attack"]

    def test_hail_gate_at_chebyshev_two(self, interaction_world) -> None:
        _store, _st, run = interaction_world
        coaster = make_fleet(run, "coaster", "portugal", OPEN_CELL,
                             "fx_gate_coaster")
        assert interactions.hail_in_range(run, coaster)
        run["world"]["position"] = {"x": OPEN_CELL[0] + 2, "y": OPEN_CELL[1]}
        assert interactions.hail_in_range(run, coaster)
        run["world"]["position"] = {"x": OPEN_CELL[0] + 3, "y": OPEN_CELL[1]}
        assert not interactions.hail_in_range(run, coaster)


class TestInspectSummary:
    def test_canon_card_reads_and_is_deterministic(
            self, interaction_world) -> None:
        store, st, run = interaction_world
        pirate = make_fleet(run, "pirate", "", OPEN_CELL, "fx_inspect_pirate",
                            PIRATE_ID)
        card = captains.captain(store, PIRATE_ID)
        summary = interactions.inspect_summary(store, run, pirate)
        assert summary["name"] == dict(card["name"])
        assert summary["role_key"] == "captain.role.pirate"
        assert summary["level"] == int(card["level"])
        assert summary["tier"] == int(card["tier"])
        assert summary == interactions.inspect_summary(store, run, pirate)
        captains.adjust_stance(run["captain_states"], store, PIRATE_ID, 2)
        captains.add_familiarity(run["captain_states"], store, PIRATE_ID, 4)
        summary = interactions.inspect_summary(store, run, pirate)
        assert summary["stance"] == 2 and summary["familiarity"] == 4

    def test_unidentified_fleet_falls_back(self, interaction_world) -> None:
        store, _st, run = interaction_world
        bare = make_fleet(run, "coaster", "portugal",
                          (OPEN_CELL[0] + 1, OPEN_CELL[1]), "fx_inspect_bare")
        summary = interactions.inspect_summary(store, run, bare)
        assert summary["name"] == {}
        assert summary["stance"] is None and summary["familiarity"] is None
        assert interactions.display_name(store, bare) == {}


class TestInterceptArithmetic:
    def test_order_shape_and_cancel(self, interaction_world) -> None:
        store, st, run = interaction_world
        pirate = make_fleet(run, "pirate", "",
                            (OPEN_CELL[0] + 20, OPEN_CELL[1]),
                            "fx_ic_pirate", PIRATE_ID)
        order = interactions.intercept(pirate)
        assert order == {"target_id": "fx_ic_pirate",
                         "target_cell": {"x": OPEN_CELL[0] + 20,
                                         "y": OPEN_CELL[1]}}
        assert interactions.intercept_cancel_reason(run, st, store, order) \
            == ""
        assert interactions.intercept_cancel_reason(run, st, store, {}) == ""
        # One tile past the rim (radius 48) auto-cancels.
        pirate["cell"] = {"x": OPEN_CELL[0] + 49, "y": OPEN_CELL[1]}
        assert interactions.intercept_cancel_reason(run, st, store, order) \
            == interactions.CANCEL_LEFT_SIGHTING == "left_sighting"
        # Exactly on the rim stays chased (≤ 48).
        pirate["cell"] = {"x": OPEN_CELL[0] + 48, "y": OPEN_CELL[1]}
        assert interactions.intercept_cancel_reason(run, st, store, order) \
            == ""
        # A target gone from the world entirely answers left_sighting too.
        run["npc_fleets"].remove(pirate)
        assert interactions.intercept_cancel_reason(run, st, store, order) \
            == "left_sighting"

    def test_sighting_radius_formula(self) -> None:
        assert interactions.sighting_radius_for(0) == 48
        assert interactions.sighting_radius_for(12) == 49
        assert interactions.sighting_radius_for(576) == 96


class TestAppointGate:
    def test_gate_matrix(self, store: DataStore) -> None:
        st = make_person()
        run = make_run(pos=OPEN_CELL, known=[])
        gate = interactions.appoint_gate(store, st, run, "lisbon")
        assert gate["ok"] is False and gate["reason"]  # the data row's reason
        # A pilot below the threshold keeps the gate shut.
        low_id = ""
        for officer in store.officers_list:
            if int(officer.get("skills", {}).get("navigation", 0)) < 40:
                low_id = str(officer["id"])
                break
        assert low_id
        st.player["officers"] = [low_id]
        st.officer_states[low_id] = {
            "loyalty": 50, "sea_days": 0, "post_id": "pilot", "ship_id": "",
            "talk_cd_day": 0, "gift_cd_day": 0, "defeats": 0, "wage_mult": 1.0,
        }
        assert interactions.appoint_gate(store, st, run, "lisbon")["ok"] \
            is False
        # Pilot ≥ 40 + a known port opens the gate.
        st.player["officers"] = [PILOT_ID]
        st.officer_states = {PILOT_ID: dict(st.officer_states[low_id])}
        run["known_ports"] = ["lisbon"]
        gate = interactions.appoint_gate(store, st, run, "lisbon")
        assert gate == {"ok": True, "reason": {}}
        # An unknown destination keeps it shut even with a pilot.
        run["known_ports"] = []
        assert interactions.appoint_gate(store, st, run, "lisbon")["ok"] \
            is False


class TestEncounterDescriptor:
    #: A tile with a decoded current (scanned once, pinned here) so the
    #: populated-current branch of the descriptor is exercised next to the
    #: empty one.
    CURRENT_TILE = (1320, 600)

    def test_shape_on_a_hand_built_fleet(self, store: DataStore) -> None:
        run = make_run(pos=(30, 40), known=[])
        run["day"] = 12
        ships = [{"ship_type_id": "sloop", "durability": 30},
                 {"ship_type_id": "brigantine", "durability": 50}]
        pirate = make_fleet(run, "pirate", "", (30, 40), "fx_enc_pirate",
                            PIRATE_ID, ships=ships, seed=424242)
        encounter = interactions.attack_encounter(store, run, pirate, 12)
        # The fleet's saved fields ride unchanged (a deep copy — mutating
        # the encounter never bleeds into the fleet).
        assert encounter["id"] == "fx_enc_pirate"
        assert encounter["role"] == "pirate"
        assert encounter["seed"] == 424242
        # kind = the §4.11.11.3 mapping; encounter_id = the fleet id.
        assert encounter["kind"] == "pirate"
        assert encounter["encounter_id"] == "fx_enc_pirate"
        # The fleet-carried ships override is honored verbatim.
        assert encounter["ships"] == ships
        # contact = the player's current tile.
        assert encounter["contact"] == {"x": 30, "y": 40}
        # The locked battle conditions ride on the dict.
        assert encounter["wind_dir"] == "NE"
        assert encounter["weather"] == "fair"
        current = encounter["current"]
        assert set(current.keys()) == {"dir", "strength"}
        decoded = ocean_layers().current_at(
            30, 40, interactions.month_for(12))
        if decoded is None:
            assert current == {"dir": "", "strength": 0}
        else:
            assert current == dict(decoded)
            assert 0 <= int(current["strength"]) <= 3

    def test_decoded_current_rides_the_dict(self, store: DataStore) -> None:
        run = make_run(pos=self.CURRENT_TILE, known=[])
        fleet = make_fleet(run, "pirate", "", self.CURRENT_TILE,
                           "fx_enc_current", PIRATE_ID,
                           ships=[{"ship_type_id": "sloop"}])
        encounter = interactions.attack_encounter(store, run, fleet, 100)
        decoded = ocean_layers().current_at(
            self.CURRENT_TILE[0], self.CURRENT_TILE[1],
            interactions.month_for(100))
        assert decoded is not None  # the pinned tile holds a current
        assert encounter["current"] == dict(decoded)
        assert encounter["current"]["strength"] \
            == int(decoded["strength"])  # type: ignore[index]

    @pytest.mark.parametrize("role,kind", [
        ("pirate", "pirate"), ("privateer", "privateer"),
        ("patrol", "patrol"), ("hunter", "navy"),
    ])
    def test_kind_mapping(self, store: DataStore, role: str,
                          kind: str) -> None:
        run = make_run(pos=OPEN_CELL, known=[])
        fleet = make_fleet(run, role, "", OPEN_CELL, f"fx_kind_{role}",
                           ships=[{"ship_type_id": "sloop"}])
        encounter = interactions.attack_encounter(store, run, fleet, 100)
        assert encounter["kind"] == kind

    def test_compose_seam_is_marked(self, store: DataStore) -> None:
        """A fleet without ships draws its composition from the ecology
        port's seeded stream — the module is not landed yet, so the seam
        must raise a LOUD marked error, never a silent wrong composition."""
        run = make_run(pos=OPEN_CELL, known=[])
        fleet = make_fleet(run, "pirate", "", OPEN_CELL, "fx_no_ships",
                           PIRATE_ID)
        with pytest.raises(Exception, match="npc_fleets"):
            interactions.attack_encounter(store, run, fleet, 100)


class TestSeededReplay:
    """The tools/test_interactions.gd §9 replay: a pure scenario signature
    compared across two runs (no RNG anywhere in the layer)."""

    SIGNATURE_FLEET_A = (OPEN_CELL[0] + 12, OPEN_CELL[1])

    def _scenario_signature(self, store: DataStore) -> dict[str, Any]:
        st = make_person()
        run = make_run(pos=OPEN_CELL, known=[])
        make_fleet(run, "coaster", "portugal", self.SIGNATURE_FLEET_A,
                   "fx_rp_a_coaster")
        pirate = make_fleet(run, "pirate", "", self.SIGNATURE_FLEET_A,
                            "fx_rp_b_pirate", PIRATE_ID)
        signature: dict[str, Any] = {}
        # 1. The multi-fleet pick: verb keys per row (coaster first by id).
        rows = [[verb for verb in ("inspect", "talk", "attack")
                 if verb in interactions.verbs_for(fleet)]
                for fleet in interactions.fleets_at(run,
                                                    self.SIGNATURE_FLEET_A)]
        signature["rows"] = rows
        # 2. The intercept sets onto the shared tile.
        order = interactions.intercept(pirate)
        signature["intercept"] = order["target_cell"]
        # 3. Two chase legs (the target flees east), then past the rim.
        for step, offset in ((1, 14), (2, 15)):
            pirate["cell"] = {"x": OPEN_CELL[0] + offset, "y": OPEN_CELL[1]}
            signature[f"retarget_{step}"] = \
                interactions.intercept(pirate)["target_cell"]
        pirate["cell"] = {"x": OPEN_CELL[0] + 61, "y": OPEN_CELL[1]}
        signature["order_after_rim"] = \
            interactions.intercept_cancel_reason(run, st, store, order) \
            == "left_sighting"
        return signature

    def test_same_fixture_same_signature(self, store: DataStore) -> None:
        first = self._scenario_signature(store)
        assert first["rows"] == [["inspect", "talk"],
                                 ["inspect", "talk", "attack"]]
        assert first["intercept"] == {"x": self.SIGNATURE_FLEET_A[0],
                                      "y": self.SIGNATURE_FLEET_A[1]}
        assert first["retarget_1"] == {"x": OPEN_CELL[0] + 14,
                                       "y": OPEN_CELL[1]}
        assert first["retarget_2"] == {"x": OPEN_CELL[0] + 15,
                                       "y": OPEN_CELL[1]}
        assert first["order_after_rim"] is True
        assert first == self._scenario_signature(store)
