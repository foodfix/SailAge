"""server.sim.state — the GameState singleton, ported (M1).

Python port of ``autoload/game_state.gd`` (the frozen parity oracle until
the M6 cutover). Normative contract: ``docs/90-ARCHITECTURE.md``

  * §5.4 — the complete field list, the pinned defaults, ``new_game`` and
    the **day-tick listener order** (ledger → economy drift/events →
    allegiance month boundary on ``day % 30 == 1`` → ``day_advanced`` →
    the NPC ecology tick → the Phase-3 quest hooks → the captain return
    queue);
  * §8.1 — the save payload key set (v9 shape; the web era calls the same
    block save v1, §0.5);
  * §0 — the server owns the sim; the state object is the single
    authoritative run state and every ported engine takes it in place of
    the GDScript autoload.

Composition choice (the keystone decision)
------------------------------------------
The ported engines each declare an explicit state dataclass
(``PersonState``, ``SailingState``, ``EconomyState``, ``AllegianceState``,
``FleetEcologyState``, ``QuestState``) whose members are *the same*
``GameState`` fields under their save/§5.4 names. Rather than rebuild an
adapter in front of every call, :class:`GameState` **is** that object:

  * :class:`~server.sim.world.sailing.SailingState` is the first base
    (``world`` / ``morale`` / ``current_port`` / ``known_ports`` /
    ``explored_tiles`` / ``control_prefs`` / ``fleet`` plus the transient
    ledger statics and the two seeded RNG streams);
  * :class:`~server.sim.player.PersonState` is the second base
    (``player`` / ``officer_states`` / ``gold`` / ``day`` / ``fame`` /
    ``titles`` / ``completed_royal_missions`` / the two transient flags);
  * :class:`~server.sim.port.allegiance.AllegianceState` is the third base
    (the ledgers behind ``port_allegiance``, ``month_invested``,
    ``treasuries``/``nation_treasuries``, ``fame_commended``, ``permits``
    and their transient trackers).

The remaining §5.4 blocks are declared here. The result flows into every
ported function unchanged — ``sailing.advance_clock(gs, gs, store, gs,
allegiance_state=gs)``, ``economy.day_tick(gs, store)``,
``allegiance.month_tick(store, gs, gs)``,
``captains.day_tick(gs.captain_states, day)``,
``phase3_hooks.on_day_tick(gs, gs, day, fleet=gs.fleet)`` and
``npc_fleets.NpcFleets(state=gs, economy=gs, allegiance=gs, person=gs)``
all take the one object. ``FleetEcologyState`` is not a base (it would
duplicate ``world``/``day``/``npc_fleets``): its two non-field members are
provided here — the ``reputation`` property (``player.reputation``) and
the ``player_tile()``/``clock_now()`` helpers — so the ecology still takes
``state=gs`` with no adapter. ``QuestState`` is likewise structural: its
seven members are ordinary §5.4 fields below.

Persistence seam
----------------
:meth:`GameState.snapshot_keys` returns the §8.1 block (the •-marked
fields in the oracle's order, deep-copied) **without** the three header
keys ``save_version``/``saved_at``/``phase`` and without the superseded
``quests`` placeholder. ``explored_tiles`` is exposed as the runtime
container (the set of ``(x, y)`` tiles); the v8 RLE/base64 codec and all
file I/O stay in ``server/save.py`` (another module's ownership), exactly
as the GDScript split ``GameState`` / ``SaveSystem``. ``world`` is
normalized to its eight persisted keys (``clock_fraction`` never saved,
``20-*`` §4.3) and the runtime-only ``deployed`` captain flag is stripped
(``10-*`` §4.15: it must never persist).

RNG discipline (M5 golden traces): ``new_game`` does not seed the streams
— the oracle's ``RandomNumberGenerator.new()`` randomizes too. Tests and
replays seed through ``sailing.set_weather_seed`` / ``set_mutiny_seed``.
The ecology's own stream derives from the day + fleet tile, so a fresh
game is reproducible without seeding.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field
from typing import Any, Final

from server.sim.data import DEFAULT_MAP_ID, DataStore, data
from server.sim.fleet import fleet as fleet_lib
from server.sim.player import PersonState, character
from server.sim.port import allegiance, economy
from server.sim.quests import phase3_hooks
from server.sim.world import captains, npc_fleets, sailing
from server.sim.world.raster import RasterError, raster, tile_of_latlon
from server.sim.world.sailing import SailingState
from server.sim.port.allegiance import AllegianceState

__all__ = [
    "SAVE_VERSION",
    "PHASE",
    "DEFAULT_WEATHER",
    "DEFAULT_TRIM",
    "DEFAULT_DIR",
    "DEFAULT_CONTROL_PREFS",
    "SNAPSHOT_KEYS",
    "GameState",
]

# --- Frozen numbers (docs/90-* §0.5 / §8.1) ---------------------------------

## The web era restarts the save counter at 1; the payload's shape is the
## §8.1 v9 block (the §8.2 no-migration discipline carries over verbatim).
SAVE_VERSION: Final[int] = 1
## The saved phase stamp. The §8.1 payload's ``phase`` is display-only and
## excluded from :meth:`GameState.snapshot_keys` (the caller adds it) — the
## value is kept here so the save writer has one source.
PHASE: Final[int] = 9

## §8.1 default weather for a ``world`` block that has none (docs/20-* §4.7:
## ``calm``; a compass id is never a weather value).
DEFAULT_WEATHER: Final[str] = sailing.DEFAULT_WEATHER
## §8.1 Phase-6 defaults (docs/90-* §5.4): the trim state and the 8-dir
## heading / wind-FROM ids.
DEFAULT_TRIM: Final[str] = sailing.DEFAULT_TRIM
DEFAULT_DIR: Final[str] = "E"
## The pinned control-preference default (docs/90-* §5.4, 80-* §4.6.3).
## A fresh dict per state — dataclass default factories, never a shared const.
DEFAULT_CONTROL_PREFS: Final[dict[str, str]] = {
    "input_mode": "step",
    "current_mode": "modifier",
}

## The §8.1 save key order, minus the three header keys and the superseded
## ``quests`` placeholder (docs/90-* §8.1: "a v3+ save has no ``quests``
## key"). The oracle's ``SaveSystem.STATE_KEYS`` order is kept verbatim so a
## payload from either runtime diffs cleanly at M5/M6.
SNAPSHOT_KEYS: Final[tuple[str, ...]] = (
    "locale", "day", "gold", "player", "fleet", "morale", "world",
    "current_port", "known_ports", "explored_tiles", "port_investments",
    "discoveries_found", "npc_fleets", "officer_states", "captain_states",
    "proximity_cooldowns",
    "market_stocks", "wrecks", "npc_preset", "control_prefs",
    "market_events",
    "fame", "titles", "bounties", "active_quests",
    "completed_royal_missions", "discoveries_reported", "discovery_hints",
    "battles_won", "retired", "retired_at",
    "permits", "port_allegiance", "month_invested", "nation_treasuries",
    "fame_commended",
)

## Enum domains that reach the payload (mirrored from the owning docs at
## ``save_system.gd``; the runtime writers always keep these values, the
## sanitizer only covers a hand-mangled in-memory dict).
_INPUT_MODES: Final[tuple[str, ...]] = ("step", "helm")
_CURRENT_MODES: Final[tuple[str, ...]] = ("modifier", "drift")
_WEATHERS: Final[tuple[str, ...]] = sailing.WEATHER_OUTCOMES
_TRIMS: Final[tuple[str, ...]] = sailing.TRIM_STATES
_DIRS: Final[tuple[str, ...]] = sailing.COMPASS_DIRS


# --- Helpers ----------------------------------------------------------------


def _enum_or(value: Any, valid: tuple[str, ...], fallback: str) -> str:
    """``value`` as a payload string when it is in ``valid``, else the
    documented §8.1 fallback (``save_system.gd``'s ``_enum_or``)."""
    text = str(value)
    return text if text in valid else fallback


def _intel_cell_payload(cell: Any) -> dict[str, int] | None:
    """The §4.15/60-* hunter-intel tile as the ``{x, y}`` payload shape
    (``None`` when unset), tolerating a tuple left by movement code."""
    if cell is None:
        return None
    if isinstance(cell, dict):
        return {"x": int(cell.get("x", 0)), "y": int(cell.get("y", 0))}
    if isinstance(cell, (tuple, list)) and len(cell) == 2:
        return {"x": int(cell[0]), "y": int(cell[1])}
    return None


def _captain_states_payload(states: dict[str, Any]) -> dict[str, Any]:
    """The §4.15 ``captain_states`` save shape: every met captain's entry
    with the runtime-only ``deployed`` bookkeeping key stripped (the
    captains module's declared contract: ``deployed`` never persists)."""
    out: dict[str, Any] = {}
    for captain_id, entry in states.items():
        if isinstance(entry, dict):
            clean = copy.deepcopy(entry)
            clean.pop("deployed", None)
            out[str(captain_id)] = clean
    return out


# --- The state --------------------------------------------------------------


@dataclass
class GameState(SailingState, PersonState, AllegianceState):
    """The single authoritative run state (docs/90-* §5.4).

    The three bases supply the sailing projection, the person mirror and
    the allegiance ledgers (see the module docstring for the composition
    rationale); the fields below are the remaining •-marked §5.4 blocks and
    the declared transients.
    """

    # --- Phase-1 header / purse -------------------------------------------------

    ## UI language; locked default ``"en"`` (user toggles via the `L` key).
    ## Deliberately untouched by ``new_game`` (the language choice survives).
    locale: str = "en"
    ## ``{port_id: gold_total}`` (docs/30-* §4.3).
    port_investments: dict[str, int] = field(default_factory=dict)

    # --- Phase-5 saved ecology / economy blocks --------------------------------

    ## Every living NPC fleet (docs/60-* §4.1; save shape ``10-*`` §4.15).
    ## Owned by :mod:`server.sim.world.npc_fleets`, mutated in place.
    npc_fleets: list[dict[str, Any]] = field(default_factory=list)
    ## ``{port_id: {good_id: stock}}`` (docs/30-* §4.2; initialized at
    ## ``new_game`` from the derived resting stock at the seeded dev).
    market_stocks: dict[str, dict[str, int]] = field(default_factory=dict)
    ## Lootable wreck sites (docs/60-* auto-resolve); never cap-counted.
    wrecks: list[dict[str, Any]] = field(default_factory=list)
    ## Sea-traffic density preset id (docs/10-* §4.10, default "normal").
    ## A new-game run input: ``new_game`` preserves the pre-game choice.
    npc_preset: str = "normal"
    ## Active demand-event instances (docs/30-* §4.5; shape ``10-*`` §4.15).
    market_events: list[dict[str, Any]] = field(default_factory=list)

    # --- Phase-8 saved state blocks --------------------------------------------

    ## ``{captain_id: {status, return_day, tier_now, stance, familiarity,
    ## dossier_seen, defeats, wins}}`` — full entries only for met captains
    ## (docs/90-* §5.4 / §8.1 v9). ``new_game`` seeds it from the initial
    ## fill's deployed captains (the W4 gate amendment).
    captain_states: dict[str, dict[str, Any]] = field(default_factory=dict)
    ## ``{kind: day}`` spawn immunity after a battle (docs/60-* §4.8);
    ## present-but-empty (the Phase-2 shape survives).
    proximity_cooldowns: dict[str, int] = field(default_factory=dict)

    # --- Phase-3 saved state ---------------------------------------------------

    ## Phase-1 placeholder, permanently empty from Phase 3 (docs/90-* §8.1).
    ## Never written to a payload; restored as ``[]`` on load.
    quests: list[Any] = field(default_factory=list)
    ## Discovery ids found by Explore (docs/70-* §4.4); found ≠ reported.
    discoveries_found: list[str] = field(default_factory=list)
    ## ``{nation_id: {amount, day}}`` — an issued bounty (docs/70-* §4.9.5).
    bounties: dict[str, Any] = field(default_factory=dict)
    ## Accepted quest instances (docs/70-* §4.9.3).
    active_quests: list[dict[str, Any]] = field(default_factory=list)
    ## Discovery ids already reported at a guild (docs/70-* §4.4).
    discoveries_reported: list[str] = field(default_factory=list)
    ## ``{discovery_id: true}`` hints bought at a tavern (docs/70-* §4.4).
    discovery_hints: dict[str, bool] = field(default_factory=dict)
    ## Battles won across the run (docs/70-* §4.7 ending summary).
    battles_won: int = 0
    ## The win state (docs/70-* §4.7): a retired save is never playable again.
    retired: bool = False
    retired_at: int = 0

    # --- Declared transients (never saved) -------------------------------------

    ## Transient arrival/departure log the ecology appends for tavern rumor
    ## rows (docs/60-* §4.11.11.4), newest last, capped at 128.
    npc_port_log: list[dict[str, Any]] = field(default_factory=list)
    ## The encounter a battle scene should open (docs/60-* §4.11.11.3).
    pending_encounter: dict[str, Any] | None = None
    ## The tournament bout the palace screen should start next (70-* §4.9.7).
    pending_tournament_round: int = 0
    ## The settled bracket block the palace screen reports on open (§4.9.7).
    last_tournament_outcome: dict[str, Any] = field(default_factory=dict)
    ## ``economy.gd``'s ``_cons_surges`` — ``{port_id: {good_id: until_day}}``
    ## (transient; the saved instances live in ``market_events``).
    cons_surges: dict[str, dict[str, int]] = field(default_factory=dict)
    ## ``economy.gd``'s ``_last_started_events`` — the latest rotation's starts
    ## (transient; the tavern telegraph rows are derived from the instances).
    last_started: list[dict[str, Any]] = field(default_factory=list)
    ## The ordered step log of the most recent completed day tick (the
    ## §5.4 ordering seam; tests assert it, nothing persists it).
    last_tick_order: list[str] = field(default_factory=list)

    # --- Runtime dependency (not part of the §5.4 field contract) --------------

    ## The loaded data tree (the DataLoader replacement, 90-* §0.2). Excluded
    ## from ``repr``/equality; ``None`` falls back to the process singleton.
    store: DataStore | None = field(default=None, repr=False, compare=False)

    # --- Construction -----------------------------------------------------------

    def __post_init__(self) -> None:
        # Runtime-only ecology instance (the FleetSim autoload's equivalent):
        # created lazily on the first day tick and never part of the payload.
        self._ecology: Any = None

    # --- §5.4 aliases / helpers ------------------------------------------------

    @property
    def reputation(self) -> dict[str, int]:
        """``player.reputation`` — the map the ecology reads as
        ``FleetEcologyState.reputation`` (90-* §5.4: reputation lives inside
        the v9 Person block, not as a top-level field)."""
        reputation = self.player.get("reputation")
        if not isinstance(reputation, dict):
            reputation = {}
            self.player["reputation"] = reputation
        return reputation

    @property
    def nation_treasuries(self) -> dict[str, int]:
        """§5.4's name for the allegiance runtime's ``treasuries`` ledger
        (the save key is ``nation_treasuries``; one source of truth)."""
        return self.treasuries

    @property
    def port_allegiance(self) -> dict[str, Any]:
        """§5.4's ``port_allegiance`` in the §8.1 correction-8 shape
        ``{port_id: {ledger, allegiance}}`` — derived from the allegiance
        ledgers because ``development`` is never stored (docs/30-* §4.9)."""
        return allegiance.dump_state(self)["port_allegiance"]

    def world_tile(self) -> tuple[int, int]:
        """``world.position`` as an ``(x, y)`` tuple (``(0, 0)`` pre-run)."""
        return sailing.world_tile(self)

    def set_world_tile(self, x: int, y: int) -> None:
        """Stores the fleet tile as the ``{"x", "y"}`` save shape."""
        sailing.set_world_tile(self, x, y)

    def player_tile(self) -> tuple[int, int]:
        """The ecology state member (``FleetEcologyState.player_tile``)."""
        return self.world_tile()

    def clock_now(self) -> float:
        """The absolute world clock ``day + clock_fraction`` (the ecology's
        accrual mark)."""
        return float(self.day) + float(self.world.get("clock_fraction", 0.0))

    def store_or_default(self) -> DataStore:
        """The injected data tree, else the process singleton."""
        return self.store if self.store is not None else data()

    def add_gold(self, delta: int) -> int:
        """Applies a gold delta and announces it (clamping/ledger rules live
        in the sailing/port engines, docs/20-* §4.9)."""
        self.gold += int(delta)
        if self.on_gold_changed is not None:
            self.on_gold_changed(self.gold)
        return self.gold

    # --- New game (docs/50-* §4.1; 90-* §5.4) ----------------------------------

    def new_game(self, nation_id: str, background_id: str = "",
                 attr_alloc: dict[str, int] | None = None,
                 skill_alloc: dict[str, int] | None = None) -> "GameState":
        """Starts a fresh run exactly per docs/50-* §4.1 (the Phase-8
        two-step creation: nationality → background → free points).

        Everything comes from data: the nation's start package
        (``data/nations.json``: start port, starter hull, start gold), the
        Person block from :func:`player.character.starting_person`, the
        market's derived resting stock (``economy.build_initial_stocks`` at
        the seeded allegiance dev), the allegiance ledger through
        ``allegiance.seed_new_game``, and the ecology's seeded initial fill
        (half the core cap) through :class:`npc_fleets.NpcFleets`.

        ``locale`` is deliberately untouched. So are the two S19 pre-game
        choices ``npc_preset`` and ``control_prefs`` (docs/80-* §4.6.3):
        each is read BEFORE the reset and restored as run input
        (out-of-domain values fall back to the pinned defaults).

        Returns ``self`` so a caller can write ``gs = GameState().new_game(…)``.
        """
        store = self.store_or_default()
        nation = store.get_nation(nation_id)
        if not nation:
            raise ValueError(f"GameState.new_game: unknown nation_id {nation_id!r}")
        start_port_id = str(nation.get("start_port_id", ""))
        start_port = store.get_port(start_port_id)
        if not start_port:
            raise ValueError(
                f"GameState.new_game: nation {nation_id!r} has unknown "
                f"start_port_id {start_port_id!r}")
        ship_type_id = str(nation.get("start_ship_type_id", ""))
        ship_type = store.get_ship_type(ship_type_id)
        if not ship_type:
            raise ValueError(
                f"GameState.new_game: nation {nation_id!r} has unknown "
                f"start_ship_type_id {ship_type_id!r}")

        # -- S19 run inputs (read before the reset, restored below) ----------
        npc_config = store.npc_config if isinstance(store.npc_config, dict) else {}
        presets = npc_config.get("presets", {})
        chosen_preset = str(self.npc_preset)
        if not isinstance(presets, dict) or chosen_preset not in presets:
            chosen_preset = str(npc_config.get("default_preset", "normal"))
        chosen_input_mode = _enum_or(
            self.control_prefs.get("input_mode", "step")
            if isinstance(self.control_prefs, dict) else "step",
            _INPUT_MODES, "step")
        chosen_current_mode = _enum_or(
            self.control_prefs.get("current_mode", "modifier")
            if isinstance(self.control_prefs, dict) else "modifier",
            _CURRENT_MODES, "modifier")

        # -- Clock / purse ---------------------------------------------------
        self.day = 1
        self.gold = int(nation.get("start_gold", 0))

        # -- Person block (the §4.1 shape, 50-* §4.8) ------------------------
        self.player = character.starting_person(
            store, nation_id, background_id,
            attr_alloc or {}, skill_alloc or {})
        # Phase-8 blocks start empty on every fresh run (90-* §8.2);
        # captain_states is then filled from the initial fill's deployments.
        self.officer_states = {}
        self.captain_states = {}

        # -- Starter hull: §4.3 "buy ship" defaults except crew = crew_min ---
        self.fleet = [fleet_lib.new_ship(
            ship_type_id, int(ship_type.get("crew_min", 0)))]

        # -- World: the start port's derived berth tile (10-* §6.1, §9.1) ----
        berth_x, berth_y = self._berth_cell(start_port_id, start_port)
        self.world = {
            "position": {"x": berth_x, "y": berth_y},
            "clock_fraction": 0.0,
            "map_id": DEFAULT_MAP_ID,
            "weather": DEFAULT_WEATHER,
            "sail_trim": DEFAULT_TRIM,
            "heading": DEFAULT_DIR,
            "wind_dir": DEFAULT_DIR,
            "last_departed_port": "",
            "hunter_intel_cell": None,
        }
        self.current_port = start_port_id

        # -- Known ports: every nation's capital (the §4.1 start package) ----
        self.known_ports = []
        for entry in store.nations_list:
            capital_id = str(entry.get("capital_port_id", ""))
            if not capital_id:
                capital_id = str(entry.get("start_port_id", ""))
            if capital_id and capital_id not in self.known_ports:
                self.known_ports.append(capital_id)

        # -- Fleet / run blocks ---------------------------------------------
        self.morale = sailing.MORALE_START
        self.port_investments = {}
        self.quests = []
        self.discoveries_found = []
        self.npc_fleets = []
        self.wrecks = []
        self.proximity_cooldowns = {}
        self.npc_port_log = []
        self.pending_encounter = None
        self.pending_tournament_round = 0
        self.last_tournament_outcome = {}
        self.explored_tiles = set()
        self.fame = 0
        self.titles = self._nation_map("none")
        self.bounties = {}
        self.active_quests = []
        self.completed_royal_missions = self._nation_map(0)
        self.discoveries_reported = []
        self.discovery_hints = {}
        self.battles_won = 0
        self.retired = False
        self.retired_at = 0
        self.npc_preset = chosen_preset
        self.control_prefs = {
            "input_mode": chosen_input_mode,
            "current_mode": chosen_current_mode,
        }
        self.market_events = []
        self.last_tick_order = []
        # Transient Person flags (the GDScript Character class statics).
        self.pending_levelup = False
        self.pending_raise = False
        # Transient sailing ledger state (one run never inherits another's).
        sailing.reset_ledger_state(self)
        economy.reset_events(self)
        # A fresh run re-adopts the ecology; the previous instance's accrual
        # marks must never leak across runs (FleetSim.reset_sim()).
        self._ecology = None

        # -- Phase-7 allegiance seeding (90-* §8.2, 30-* §4.9) ---------------
        # Runs before the stock block so ``market_stocks`` derives at the
        # seeded dev (docs/30-* §4.2: producers start at capacity, which
        # scales with dev). Contestable sovereigns begin ``{owner: 6,000}``,
        # neutrals empty, every treasury 5,000g, permits/counters reset.
        allegiance.seed_new_game(store, self)

        # -- Derived resting stock at the seeded dev (no RNG) ----------------
        self.market_stocks = economy.build_initial_stocks(
            store.ports_list, store.goods_list,
            dev_of=lambda port_id: allegiance.dev(store, self, port_id))

        # -- Seeded ecology initial fill to half the core cap (60-* §4.1.2) --
        # Runs here and only here; deploy() seeds ``captain_states`` with the
        # fleets' met captains (the W4 gate amendment, 90-* §8.2).
        ecology = npc_fleets.NpcFleets(
            {"npc_config": store.npc_config, "preset": self.npc_preset},
            state=self, economy=self, allegiance=self, person=self,
            store=store)
        ecology.initial_fill(self.day)

        return self

    # --- Day tick (docs/90-* §5.4; docs/20-* §4.3) -----------------------------

    def advance_clock(self, days: float) -> int:
        """The clock-driven entry (docs/20-* §4.3): adds ``days`` to the
        fractional clock and runs the pinned listener order for every
        completed day.

        The sailing engine owns the ledger and the §4.3 pipeline (ledger →
        economy step → allegiance month boundary on ``day % 30 == 1`` →
        drift push → the ``day_advanced`` hook); this method supplies the
        one state object and chains the GameState listeners onto that hook
        in the **§5.4 order**: the NPC ecology tick → the Phase-3 quest day
        hooks → the captain return queue. A caller-supplied
        ``on_day_advanced`` still fires, after the chain.

        Returns the number of completed days (0 for a dead run / no time).
        """
        saved_hook = self.on_day_advanced

        def _chain(day: int) -> None:
            self._post_day_advanced(int(day))
            if saved_hook is not None:
                saved_hook(int(day))

        self.on_day_advanced = _chain
        try:
            return sailing.advance_clock(
                self, self, self.store_or_default(), self, days,
                allegiance_state=self)
        finally:
            self.on_day_advanced = saved_hook

    def advance_day(self) -> int:
        """Advances exactly one whole day through the same clock seam
        (docs/90-* §5.4's ``advance_day``)."""
        return self.advance_clock(1.0)

    def _post_day_advanced(self, day: int) -> None:
        """The §5.4 listener chain for one completed day.

        The three steps before this hook are already done by the sailing
        engine's pinned pipeline; they are recorded from that contract (the
        engine's own suite proves the order). The list is reset per day so
        ``last_tick_order`` describes the most recent completed day.
        """
        order = ["ledger", "economy"]
        if day % sailing.MONTH_DAYS == 1:
            order.append("month")
        order.append("day_advanced")
        self.last_tick_order = order

        if not self.player:
            return  # no run: the listeners are no-ops (FleetSim guard)

        order.append("npc_fleets")
        self._npc_day_tick(day)

        order.append("quests")
        phase3_hooks.on_day_tick(self, self, day, fleet=self.fleet)

        order.append("captains")
        captains.day_tick(self.captain_states, day)

    def _npc_day_tick(self, day: int) -> None:
        """The post-``day_advanced`` ecology tick (the FleetSim listener)."""
        if sailing.is_game_over(self):
            return  # a dead run's sea is frozen (60-* §4.9 guard)
        sim = self._ensure_ecology()
        moved_before = list(sim.moved_ports)
        sim.tick(day)
        emit = self.on_market_changed
        if emit is not None:
            for port_id in sim.moved_ports:
                if port_id not in moved_before:
                    emit(str(port_id))

    def _ensure_ecology(self) -> npc_fleets.NpcFleets:
        """The live ecology instance over ``self`` (FleetSim.ensure).

        A fresh instance starts "this day already ticked" so adoption never
        back-ticks or catches up (docs/90-* §5.6 / 60-* §4.11.11.1). The
        instance is runtime-only and never part of the payload.
        """
        sim = self._ecology
        if sim is not None and sim.state is self:
            return sim
        sim = npc_fleets.NpcFleets(
            {"npc_config": self.store_or_default().npc_config,
             "preset": self.npc_preset},
            state=self, economy=self, allegiance=self, person=self,
            store=self.store_or_default())
        sim.last_tick_day = int(self.day)
        self._ecology = sim
        return sim

    # --- Save shape (docs/90-* §8.1) -------------------------------------------

    def world_payload(self) -> dict[str, Any]:
        """The §8.1 ``world`` block: the eight persisted keys only
        (``clock_fraction`` is runtime-only, docs/20-* §4.3), enums
        sanitized so a payload this build writes always validates."""
        x, y = self.world_tile()
        return {
            "position": {"x": x, "y": y},
            "weather": _enum_or(
                self.world.get("weather", DEFAULT_WEATHER), _WEATHERS,
                DEFAULT_WEATHER),
            "map_id": _enum_or(
                self.world.get("map_id", DEFAULT_MAP_ID),
                (DEFAULT_MAP_ID,), DEFAULT_MAP_ID),
            "last_departed_port": str(
                self.world.get("last_departed_port", "")),
            "hunter_intel_cell": _intel_cell_payload(
                self.world.get("hunter_intel_cell")),
            "sail_trim": _enum_or(
                self.world.get("sail_trim", DEFAULT_TRIM), _TRIMS,
                DEFAULT_TRIM),
            "heading": _enum_or(
                self.world.get("heading", DEFAULT_DIR), _DIRS, DEFAULT_DIR),
            "wind_dir": _enum_or(
                self.world.get("wind_dir", DEFAULT_DIR), _DIRS, DEFAULT_DIR),
        }

    def control_prefs_payload(self) -> dict[str, str]:
        """The §8.1 ``control_prefs`` block: exactly the two pinned keys."""
        prefs = self.control_prefs if isinstance(self.control_prefs, dict) else {}
        return {
            "input_mode": _enum_or(
                prefs.get("input_mode", "step"), _INPUT_MODES, "step"),
            "current_mode": _enum_or(
                prefs.get("current_mode", "modifier"), _CURRENT_MODES,
                "modifier"),
        }

    def snapshot_keys(self) -> dict[str, Any]:
        """The §8.1 save block for this state (no file I/O).

        Exactly :data:`SNAPSHOT_KEYS`, in order, with every value
        deep-copied so the caller can serialize without aliasing live
        state. ``explored_tiles`` rides as the **runtime container** (a set
        of ``(x, y)`` tiles) — the v8 RLE/base64 encoding and the payload
        headers (``save_version``/``saved_at``/``phase``) belong to
        ``server/save.py``. ``quests`` is never written (permanently empty
        since Phase 3). The runtime-only ``deployed`` captain flag is
        stripped (10-* §4.15).
        """
        allegiance_state = allegiance.dump_state(self)
        payload: dict[str, Any] = {
            "locale": self.locale,
            "day": self.day,
            "gold": self.gold,
            "player": copy.deepcopy(self.player),
            "fleet": copy.deepcopy(self.fleet),
            "morale": self.morale,
            "world": self.world_payload(),
            "current_port": self.current_port,
            "known_ports": list(self.known_ports),
            "explored_tiles": set(self.explored_tiles),
            "port_investments": copy.deepcopy(self.port_investments),
            "discoveries_found": list(self.discoveries_found),
            "npc_fleets": copy.deepcopy(self.npc_fleets),
            "officer_states": copy.deepcopy(self.officer_states),
            "captain_states": _captain_states_payload(self.captain_states),
            "proximity_cooldowns": copy.deepcopy(self.proximity_cooldowns),
            "market_stocks": copy.deepcopy(self.market_stocks),
            "wrecks": copy.deepcopy(self.wrecks),
            "npc_preset": self.npc_preset,
            "control_prefs": self.control_prefs_payload(),
            "market_events": copy.deepcopy(self.market_events),
            "fame": self.fame,
            "titles": copy.deepcopy(self.titles),
            "bounties": copy.deepcopy(self.bounties),
            "active_quests": copy.deepcopy(self.active_quests),
            "completed_royal_missions":
                copy.deepcopy(self.completed_royal_missions),
            "discoveries_reported": list(self.discoveries_reported),
            "discovery_hints": copy.deepcopy(self.discovery_hints),
            "battles_won": self.battles_won,
            "retired": self.retired,
            "retired_at": self.retired_at,
            "permits": copy.deepcopy(allegiance_state["permits"]),
            "port_allegiance": copy.deepcopy(
                allegiance_state["port_allegiance"]),
            "month_invested": copy.deepcopy(allegiance_state["month_invested"]),
            "nation_treasuries": copy.deepcopy(
                allegiance_state["nation_treasuries"]),
            "fame_commended": copy.deepcopy(allegiance_state["fame_commended"]),
        }
        return payload

    # --- Private helpers --------------------------------------------------------

    def _berth_cell(self, port_id: str, port: dict[str, Any]) -> tuple[int, int]:
        """The port's **derived berth** tile (10-* §6.1 snap rule via the
        builder's ``harbors.json``). A fixture without a decoded world
        falls back to the same floor projection so the tile is never (0,0)."""
        try:
            cell = raster().port_cell(port_id)
        except RasterError:
            # The documented loader-absent fixture path (game_state.gd's
            # `DataLoader.ensure_map()` false branch).
            cell = (-1, -1)
        if cell[0] < 0:
            lat = port.get("lat")
            lon = port.get("lon")
            if isinstance(lat, (int, float)) and isinstance(lon, (int, float)):
                cell = tile_of_latlon(float(lat), float(lon))
            else:
                raise ValueError(
                    f"GameState.new_game: no berth tile for port {port_id!r}")
        return max(int(cell[0]), 0), max(int(cell[1]), 0)

    def _nation_map(self, value: Any) -> dict[str, Any]:
        """``{nation_id: value}`` over every loaded nation (the fresh
        save-block default, exactly the oracle's ``_nation_map``)."""
        out: dict[str, Any] = {}
        for entry in self.store_or_default().nations_list:
            out[str(entry.get("id", ""))] = value
        return out
