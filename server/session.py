"""server.session — the live single game session (M2).

Frozen contract: ``docs/90-ARCHITECTURE.md`` §0.1 (server-authoritative: ALL
rules live in the ported sim under ``server/sim/``; this module only wires
calls), §0.3 (the one-client WS frames), §0.4 (``POST /api/<facility>/<action>``
+ the six fixed endpoints) and §0.5 (``SIM_TICK_HZ`` = 10, ``WS_BROADCAST_HZ``
= 10, ``SAVE_VERSION`` = 1).

One process = one game: :class:`Session` owns the single
:class:`~server.sim.state.GameState`, the transient :class:`SailingMotion`
cadence object, the ecology instance (``GameState._ensure_ecology``), the
autopilot runtime, the live :class:`~server.sim.combat.battle_sim.BattleSim`,
the save/load entry points (``server.save``) and the WS client registry
(≤ 1 connection, §0.3).

Two surfaces:

* :meth:`Session.dispatch` — the action-dispatch surface the HTTP routers
  call. Every action is a thin adapter over the sim: it validates the body
  shape, gates on the port/facility state through the sim's own queries, then
  calls the sim function(s) of the owning module. No game rule is evaluated
  here. A sim refusal always comes back as :class:`ApiError`
  ``{code, msg}`` (``msg`` is a ``data/ui_strings.json`` key — the client
  owns the copy, §0.1 i18n).
* :meth:`Session.tick` — the real-time loop body at ``SIM_TICK_HZ`` = 10: the
  same advance the Godot ``world_map.gd`` ``_process`` performed — one
  ``sailing.advance_motion`` cadence tick (hold/helm/click-route), the
  appointed voyage (:mod:`server.sim.world.autopilot`), the NPC ecology
  accrual and the contact funnel — then exactly ONE coalesced ``tick`` frame
  (§0.3 backpressure).

``state``/``event`` frames are never dropped; ``tick``/``battle_tick`` keep
only the newest (the :class:`ClientConnection` sender coalesces).
"""

from __future__ import annotations

import asyncio
import copy
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Final

from server import save
from server.sim import fleet as fleet_lib
from server.sim.combat import ai_fleet, battle_rewards, battle_result
from server.sim.combat.battle_sim import (
    ARMOR_PIERCING_SHOT,
    BROADSIDE_PORT,
    BROADSIDE_STARBOARD,
    CHAIN_SHOT,
    GRAPE_SHOT,
    ROUND_SHOT,
    RESULT_RETREAT,
    RESULT_VICTORY,
    SIDE_ENEMY,
    SIDE_PLAYER,
    BattleSim,
    battle_seed_formula,
    heading8_of,
    shot_unlocked,
    to_cell,
    vel_length,
)
from server.sim.data import DataStore, data
from server.sim.player import character, fame, skills
from server.sim.port import allegiance, economy, inn, palace, shipyard, tavern, trade
from server.sim.quests import bounty, phase3_hooks, quest_gen
from server.sim.rng import GodotRng
from server.sim.state import GameState
from server.sim.world import (
    autopilot,
    discovery,
    hail_options,
    interactions,
    npc_fleets,
    npc_intel,
    sailing,
)
from server.sim.world.raster import ocean_layers, raster
from server.sim.world.sailing import SailingMotion

__all__ = [
    "SIM_TICK_HZ",
    "WS_BROADCAST_HZ",
    "FACILITY_INVENTORY",
    "ApiError",
    "ClientConnection",
    "Session",
]

logger = logging.getLogger(__name__)

# --- Frozen numbers (docs/90-* §0.5) -----------------------------------------

## Server sim rate; one tick = one broadcast opportunity (§0.5).
SIM_TICK_HZ: Final[int] = 10
## One ``tick``/``battle_tick`` per sim tick (§0.3 backpressure coalesces).
WS_BROADCAST_HZ: Final[int] = 10
## Seconds of simulated time per tick.
SIM_DT: Final[float] = 1.0 / float(SIM_TICK_HZ)

# --- §4.1b facility action hours (docs/30-* §4.1b "Action hour costs") ------
#
# The ported sim modules document these as the caller's duty ("the §4.1b
# action cost is the caller's"), so the adapter supplies them here — each is
# the doc-pinned table value, never a new number.

HOURS_MARKET_TRADE: Final[int] = 1      # market buy / sell / invest
HOURS_SHIPYARD_BUY: Final[int] = 3      # shipyard: buy ship
HOURS_SHIPYARD_REPAIR: Final[int] = 2   # shipyard: repair
HOURS_SHIPYARD_SELL: Final[int] = 1     # shipyard: sell ship
HOURS_SHIPYARD_REFIT: Final[int] = 2    # shipyard: refit
HOURS_TAVERN_CREW: Final[int] = 1       # tavern: crew hire / fire / sign
HOURS_GUILD_SIGN: Final[int] = 1        # guild: quest accept / report
HOURS_PALACE_AUDIENCE: Final[int] = 1   # palace: mission / ceremony / ...
HOURS_PALACE_REPAIR: Final[int] = 2     # palace: repair bays
HOURS_PROVISIONS: Final[int] = 1        # market: buy supplies (24h prompt)

# --- The frozen facility inventory (M2 freeze, §0.4; M3 extension) -----------

## ``POST /api/<facility>/<action>`` — the exact inventory. The M3 screens
## consume this table; :func:`server.api.actions.build_router` dispatches it.
## The M3 wiring (2026-11-11) appended the screen verbs the M2 freeze had
## listed without an adapter: the Set-Sail prompt's ``fill`` / ``jettison``,
## the tavern's ``fill_crew`` / ``down_to_min`` / ``dismiss`` and the
## palace's ``repair_fleet`` / ``pay_bounty`` / ``inform`` / ``retire``
## (``guild: complete|abandon`` were already wired).
FACILITY_INVENTORY: Final[dict[str, tuple[str, ...]]] = {
    "market": ("buy", "sell", "invest"),
    "shipyard": ("buy", "repair", "sell", "refit", "equip", "unequip",
                 "promote"),
    "tavern": ("hire", "fire", "spar", "hint", "fill_crew", "down_to_min",
               "dismiss"),
    "inn": ("rest", "odd_job"),
    "guild": ("offers", "accept", "complete", "abandon", "report"),
    "palace": ("mission", "ceremony", "permit", "commend",
               "tournament_enter", "repair_fleet", "pay_bounty", "inform",
               "retire"),
    "provisions": ("set_sail", "buy_supplies", "fill", "jettison"),
    "people": ("inspect", "talk", "gift", "befriend", "attack", "hail",
               "appoint"),
    "fleet": ("jettison", "promote"),
}

#: The six facilities the port hub renders (``server.api.views._port_view``)
#: — the only rows a bounty closure can shut (§4.9.6). ``provisions/*`` and
#: ``people/*`` are not hub rows: docking, Save, Set Sail and the sea
#: interaction verbs keep working in a closed port.
BOUNTY_GATED_FACILITIES: Final[tuple[str, ...]] = (
    "market", "shipyard", "tavern", "inn", "guild", "palace")

# --- Errors ------------------------------------------------------------------


class ApiError(Exception):
    """A structured refusal: ``{"ok": false, "error": {code, msg}}`` (§0.4).

    ``msg`` is a ``data/ui_strings.json`` key whenever one exists (the client
    resolves the copy); technical faults use a stable ``error.*`` key. The
    HTTP status is chosen by the router (400 for malformed/unknown, 200 for
    an in-game refusal — see the M2 record).
    """

    def __init__(self, code: str, msg: str, status: int = 200) -> None:
        super().__init__(f"{code}: {msg}")
        self.code = code
        self.msg = msg
        self.status = status

    def payload(self) -> dict[str, Any]:
        return {"ok": False, "error": {"code": self.code, "msg": self.msg}}


# --- Body parsing helpers ----------------------------------------------------


def _body_dict(body: Any) -> dict[str, Any]:
    if body is None:
        return {}
    if not isinstance(body, dict):
        raise ApiError("bad_request", "error.bad_request", 400)
    return body


def _require_str(body: dict[str, Any], key: str) -> str:
    value = body.get(key)
    if not isinstance(value, str) or not value:
        raise ApiError("bad_request", "error.bad_request", 400)
    return value


def _optional_str(body: dict[str, Any], key: str, default: str = "") -> str:
    value = body.get(key, default)
    if value is None:
        return default
    if not isinstance(value, str):
        raise ApiError("bad_request", "error.bad_request", 400)
    return value


def _require_int(body: dict[str, Any], key: str) -> int:
    value = body.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ApiError("bad_request", "error.bad_request", 400)
    return int(value)


def _optional_int(body: dict[str, Any], key: str, default: int = 0) -> int:
    value = body.get(key, default)
    if value is None:
        return default
    if isinstance(value, bool) or not isinstance(value, int):
        raise ApiError("bad_request", "error.bad_request", 400)
    return int(value)


def _jsonable(value: Any) -> Any:
    """Tuples → lists so a state frame can never fail JSON encoding."""
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    if isinstance(value, set):
        return sorted(_jsonable(item) for item in value)
    return value


# --- Adapters over the sim's injected view protocols -------------------------


class _ShipyardAllegianceView:
    """``shipyard.AllegianceView`` over the live allegiance state (§4.9)."""

    def __init__(self, session: "Session") -> None:
        self._session = session

    def dev(self, port_id: str) -> int:
        gs = self._session.gs
        return allegiance.dev(self._session.store, gs, port_id)

    def effective_alignment(self, port_id: str) -> str:
        gs = self._session.gs
        return allegiance.effective_alignment(self._session.store, gs, port_id)


class _QuestWorldView:
    """``quest_gen.WorldView`` over the decoded world raster (§9.1)."""

    def __init__(self) -> None:
        self._raster = raster()

    def port_cell(self, port_id: str) -> tuple[int, int]:
        return self._raster.port_cell(port_id)

    def map_width(self) -> int:
        return int(self._raster.width)


class _RunView:
    """The ``run`` mapping shape the ported world modules expect.

    ``interactions`` / ``hail_options`` / ``autopilot`` / ``palace`` take the
    oracle's ``GameState`` as a dict-like ``run`` (``run.get("world")``,
    ``run["fleet"]``, ``run.setdefault("active_quests", [])``). The web-era
    state is a dataclass, so this adapter forwards mapping reads to its
    attributes — one object, no state copy, mutations land in place.
    """

    __slots__ = ("_state",)

    def __init__(self, state: GameState) -> None:
        object.__setattr__(self, "_state", state)

    def get(self, key: str, default: Any = None) -> Any:
        return getattr(self._state, key, default)

    def setdefault(self, key: str, default: Any) -> Any:
        value = getattr(self._state, key, None)
        if value is None:
            setattr(self._state, key, default)
            return default
        return value

    def __getitem__(self, key: str) -> Any:
        return getattr(self._state, key)

    def __setitem__(self, key: str, value: Any) -> None:
        setattr(self._state, key, value)

    def __contains__(self, key: str) -> bool:
        return hasattr(self._state, key)


# --- The WS client (one per session, §0.3) -----------------------------------


class ClientConnection:
    """One WS client's outbox.

    ``state``/``event``/``error`` frames go into an unbounded queue and are
    never dropped; ``tick``/``battle_tick`` keep only the newest payload
    (a slow client's stale ticks are coalesced, §0.3 backpressure). The
    sender task drains both in order on the client's own event loop.
    """

    def __init__(self, websocket: Any) -> None:
        self.websocket = websocket
        self.queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.tick_latest: dict[str, Any] | None = None
        self.wake = asyncio.Event()
        self.closed = False
        self._task: asyncio.Task[None] | None = None

    def enqueue(self, frame: dict[str, Any]) -> None:
        if self.closed:
            return
        self.queue.put_nowait(frame)
        self.wake.set()

    def enqueue_tick(self, frame: dict[str, Any]) -> None:
        if self.closed:
            return
        self.tick_latest = frame
        self.wake.set()

    def start(self) -> None:
        self._task = asyncio.create_task(self._sender())

    async def _sender(self) -> None:
        try:
            while not self.closed:
                await self.wake.wait()
                self.wake.clear()
                while not self.closed:
                    tick = self.tick_latest
                    if tick is not None:
                        self.tick_latest = None
                        await self.websocket.send_json(tick)
                        if self.closed:
                            return
                    try:
                        frame = self.queue.get_nowait()
                    except asyncio.QueueEmpty:
                        break
                    await self.websocket.send_json(frame)
        except (RuntimeError, ConnectionError, asyncio.CancelledError):
            pass
        except Exception:  # noqa: BLE001 - a dead socket never crashes the sim
            logger.debug("ws sender stopped", exc_info=True)

    async def stop(self) -> None:
        self.closed = True
        self.wake.set()
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass
            self._task = None


# --- Battle handoff (M2 seam) -------------------------------------------------


@dataclass
class BattleSession:
    """One live battle: the ported :class:`BattleSim` plus the aftermath keys.

    M2 drives the engine one turn at a time: enemy turns are pumped with
    ``ai_fleet.decide`` (the oracle's own §4.9 priority list) whenever the
    cursor sits on an enemy ship; player ships wait for ``battle_action``
    (``orders_due: true`` on the broadcast frame). The five-tuple
    ``battle_order`` is stored and used to pick a legal velocity from the
    engine's own ``legal_velocities`` enumeration before the action resolves.
    """

    sim: BattleSim
    encounter: dict[str, Any]
    idle_officer_ids: list[str] = field(default_factory=list)
    order: dict[str, Any] = field(default_factory=dict)
    rounds: int = 0

    def kind(self) -> str:
        return str(self.encounter.get("kind", "pirate"))

    def encounter_id(self) -> str:
        return str(self.encounter.get("id", "") or
                   self.encounter.get("encounter_id", ""))


# --- The session -------------------------------------------------------------


class Session:
    """The single live game: state, sim loop, actions, save/load, WS client."""

    def __init__(self) -> None:
        self.store: DataStore = data()
        self.gs = GameState(store=self.store)
        self.motion = SailingMotion()
        self.rt = autopilot.AutopilotRuntime()
        self.rng = GodotRng()
        self.world_view = _QuestWorldView()
        self.run_view = _RunView(self.gs)
        self.allegiance_view = _ShipyardAllegianceView(self)
        self.client: ClientConnection | None = None
        self.battle: BattleSession | None = None
        self.intercept: dict[str, Any] = {}
        self._autopilot_elapsed = 0.0
        self._gold_events = 0
        self._tick_task: asyncio.Task[None] | None = None
        self._wire_hooks()

    # --- Lifecycle ---------------------------------------------------------

    def _wire_hooks(self) -> None:
        """Hooks the sim fires; each becomes an ``event`` frame (§0.3)."""
        gs = self.gs
        gs.on_gold_changed = self._on_gold_changed
        gs.on_fleet_changed = lambda: self.emit_event("fleet_changed", {})
        gs.on_market_changed = lambda port_id: self.emit_event(
            "market_changed", {"port_id": str(port_id)})
        gs.on_day_advanced = lambda day: self.emit_event(
            "day_advanced", {"day": int(day)})
        gs.on_game_over = self._on_game_over
        gs.on_port_entered = self._on_port_entered

    def reset(self) -> None:
        """Drops the run entirely (a test seam; no HTTP surface)."""
        self.gs = GameState(store=self.store)
        self.motion = SailingMotion()
        self.rt = autopilot.AutopilotRuntime()
        self.rng = GodotRng()
        self.run_view = _RunView(self.gs)
        self.allegiance_view = _ShipyardAllegianceView(self)
        self.battle = None
        self.intercept = {}
        self._autopilot_elapsed = 0.0
        self._gold_events = 0
        self._wire_hooks()

    async def start(self) -> None:
        """Starts the sim loop (the FastAPI lifespan's task)."""
        if self._tick_task is None or self._tick_task.done():
            self._tick_task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if self._tick_task is not None:
            self._tick_task.cancel()
            try:
                await self._tick_task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass
            self._tick_task = None

    async def _loop(self) -> None:
        while True:
            await asyncio.sleep(SIM_DT)
            try:
                self.tick(SIM_DT)
            except Exception:  # noqa: BLE001 - the sim loop never dies
                logger.exception("sim tick failed")

    # --- Run predicates ----------------------------------------------------

    def has_run(self) -> bool:
        return bool(self.gs.player) and int(self.gs.day) > 0

    def in_port(self) -> bool:
        return sailing.in_port(self.gs)

    def retired(self) -> bool:
        return bool(self.gs.retired)

    def game_over(self) -> bool:
        return sailing.is_game_over(self.gs)

    def port_id(self) -> str:
        return sailing.docked_port_id(self.gs)

    # --- Event / state frames ---------------------------------------------

    def _on_gold_changed(self, new_gold: int) -> None:
        self._gold_events += 1
        self.emit_event("gold_changed", {"gold": int(new_gold)})

    def _on_port_entered(self, port_id: str) -> None:
        self.emit_event("port_entered", {"port_id": str(port_id)})
        # The Phase-3 port-entry seam: delivery completion, arrival quests
        # (the oracle's Phase3Hooks.on_port_entered).
        if self.has_run():
            entries = phase3_hooks.on_port_entered(
                self.gs, self.gs, str(port_id), self.gs.fleet)
            if entries:
                self.emit_event("quests_changed", {})
        # Docking is a server transition (the sea tick ends here): the port
        # screen needs the fresh snapshot, so one goes out with the event.
        self.queue_state()

    def _on_game_over(self, reason: str) -> None:
        self.emit_event("game_over", {"reason": str(reason)})
        self.queue_state()

    def emit_event(self, name: str, args: dict[str, Any]) -> None:
        """Queues one ``event`` frame (§0.3: never dropped)."""
        if self.client is not None:
            self.client.enqueue(
                {"type": "event", "name": str(name),
                 "args": _jsonable(args)})

    def state_payload(self) -> dict[str, Any]:
        """The ``state`` frame (§0.3): the §8.1 save payload + transients.

        The save block comes from :meth:`GameState.snapshot_keys` (the one
        §8.1 owner); ``explored_tiles`` rides the v8 codec, and the three
        header keys are included exactly as ``server.save`` writes them.
        The transient keys the frozen table names (``pending_encounter``,
        ``npc_port_log``, the level-up toast state) follow, plus the live
        clock/port/battle markers the S3/S4 screens read. They are declared
        transients — never persisted.
        """
        gs = self.gs
        payload = gs.snapshot_keys()
        payload["explored_tiles"] = save.encode_explored(
            payload["explored_tiles"])
        payload["save_version"] = save.SAVE_VERSION
        payload["saved_at"] = 0
        payload["phase"] = save.PHASE
        # --- transient keys (§0.3) -------------------------------------
        payload["pending_encounter"] = copy.deepcopy(gs.pending_encounter)
        payload["npc_port_log"] = copy.deepcopy(gs.npc_port_log)
        payload["pending_levelup"] = bool(gs.pending_levelup)
        payload["pending_raise"] = bool(gs.pending_raise)
        payload["pending_mutiny"] = copy.deepcopy(gs.pending_mutiny)
        payload["pending_tournament_round"] = int(
            gs.pending_tournament_round)
        payload["last_tournament_outcome"] = copy.deepcopy(
            gs.last_tournament_outcome)
        payload["clock_fraction"] = float(
            gs.world.get("clock_fraction", 0.0))
        payload["in_port"] = self.in_port()
        payload["game_over_reason"] = str(gs.game_over_reason)
        payload["battle"] = {
            "active": self.battle is not None,
            "encounter_id": self.battle.encounter_id()
            if self.battle is not None else "",
        }
        return _jsonable(payload)

    def queue_state(self) -> None:
        """Sends the fresh snapshot to the connected client (§0.3)."""
        if self.client is not None:
            self.client.enqueue(
                {"type": "state", **self.state_payload()})

    def hello_payload(self) -> dict[str, Any]:
        """The first frame on connect (§0.3)."""
        gs = self.gs
        if not self.has_run():
            screen = "title"
        elif self.in_port():
            screen = "port"
        else:
            screen = "world"
        return {
            "type": "hello",
            "save_version": save.SAVE_VERSION,
            "tick_hz": SIM_TICK_HZ,
            "broadcast_hz": WS_BROADCAST_HZ,
            "locale": str(gs.locale),
            "has_run": self.has_run(),
            "current_screen": screen,
            "saves": save.list_saves(),
        }

    # --- Screen projections (90-* §0.4, M3) --------------------------------

    def view(self, screen_id: str) -> dict[str, Any]:
        """The ``GET /api/view/<screen_id>`` projection (90-* §0.4).

        The no-rules-in-TS channel: :mod:`server.api.views` computes every
        value the screen renders from the ported sim; this method only
        guards the request (live run, docked, known screen id) and wraps
        the projection in the frozen envelope. Always a pure read — a view
        refresh never mutates the run.
        """
        from server.api import views as views_module

        if screen_id not in views_module.SCREENS:
            raise ApiError("unknown_screen", "error.unknown_screen", 404)
        self._guard_run()
        if not self.in_port():
            raise ApiError("not_in_port", "error.not_in_port")
        return {"ok": True, "screen": screen_id,
                "views": views_module.project(self, screen_id)}

    # --- WS client registry (one, §0.3) ------------------------------------

    def attach_client(self, connection: ClientConnection) -> bool:
        if self.client is not None:
            return False
        self.client = connection
        return True

    async def detach_client(self, connection: ClientConnection) -> None:
        if self.client is connection:
            self.client = None
        await connection.stop()

    # --- Save / load -------------------------------------------------------

    def save_slot(self, slot: int) -> dict[str, Any]:
        if not self.has_run():
            raise ApiError("no_run", "error.no_run")
        try:
            save.save(self.gs, slot)
        except ValueError as error:
            raise ApiError("bad_slot", "error.bad_slot", 400) from error
        return {"ok": True, "slot": int(slot),
                "saves": save.list_saves()}

    def load_slot(self, slot: int) -> dict[str, Any]:
        try:
            ok = save.load(self.gs, slot)
        except ValueError as error:
            raise ApiError("bad_slot", "error.bad_slot", 400) from error
        if not ok:
            raise ApiError("load_failed", "error.save_load")
        # A load restarts every transient: a fresh ecology mark, no cadence,
        # no battle, no appointment, no intercept (world_map's load rule).
        self.gs._ecology = None
        self.motion = SailingMotion()
        self.rt = autopilot.AutopilotRuntime()
        self.battle = None
        self.intercept = {}
        self._autopilot_elapsed = 0.0
        self._ensure_ecology()
        return {"ok": True, "slot": int(slot),
                "saves": save.list_saves()}

    # --- New game / locale -------------------------------------------------

    def new_game(self, nation_id: str, background_id: str,
                 attr_alloc: dict[str, int] | None,
                 skill_alloc: dict[str, int] | None) -> dict[str, Any]:
        if not self.store.get_nation(nation_id):
            raise ApiError("unknown_nation", "error.unknown_nation", 400)
        if background_id and not self.store.get_background(background_id):
            raise ApiError("unknown_background", "error.unknown_background", 400)
        self.gs.new_game(nation_id, background_id,
                         attr_alloc or {}, skill_alloc or {})
        self.motion = SailingMotion()
        self.rt = autopilot.AutopilotRuntime()
        self.battle = None
        self.intercept = {}
        self._autopilot_elapsed = 0.0
        return {"ok": True, "nation_id": nation_id,
                "port_id": self.port_id()}

    def set_locale(self, locale: str) -> dict[str, Any]:
        if locale not in ("zh", "en"):
            raise ApiError("bad_locale", "error.bad_locale", 400)
        self.gs.locale = locale
        self.emit_event("locale_changed", {"locale": locale})
        return {"ok": True, "locale": locale}

    # --- Ecology / clock helpers ------------------------------------------

    def _ensure_ecology(self) -> npc_fleets.NpcFleets:
        return self.gs._ensure_ecology()

    def _accrue(self) -> None:
        """NPC movement accrual against the world clock (§4.11.11)."""
        if not self.has_run():
            return
        self._ensure_ecology().advance_clock()

    def _charge_hours(self, hours: int) -> None:
        if hours <= 0:
            return
        sailing.advance_port_hours(
            self.gs, self.gs, self.store, self.gs, int(hours),
            allegiance_state=self.gs)

    # --- Dispatch ----------------------------------------------------------

    def dispatch(self, facility: str, action: str,
                 body: Any) -> dict[str, Any]:
        """Runs ``POST /api/<facility>/<action>`` (§0.4).

        Thin adapters only: body shape → sim call(s) in the oracle's order.
        Raises :class:`ApiError` on any refusal; returns ``{"ok": true, ...}``
        on success. The router broadcasts ``state`` afterwards.
        """
        actions = FACILITY_INVENTORY.get(facility)
        if actions is None or action not in actions:
            raise ApiError("unknown_action", "error.unknown_action", 404)
        handler = getattr(self, f"_{facility}_{action}", None)
        if handler is None:  # pragma: no cover - inventory/route drift guard
            raise ApiError("unknown_action", "error.unknown_action", 404)
        data_in = _body_dict(body)
        gold_before = int(self.gs.gold)
        events_before = self._gold_events
        result = handler(data_in)
        if self.gs.gold != gold_before and self._gold_events == events_before:
            # A port module mutated the purse directly (the sim's documented
            # seam); announce the one gold change the oracle emitted.
            self._on_gold_changed(self.gs.gold)
        self._accrue()
        return result

    # --- Guards ------------------------------------------------------------

    def _guard_run(self) -> None:
        if not self.has_run():
            raise ApiError("no_run", "error.no_run")
        if self.retired():
            raise ApiError("retired", "error.retired")
        if self.game_over():
            raise ApiError("game_over", "error.game_over")

    def _guard_port(self, facility: str) -> str:
        """The docked-port facility gate: live run, a port, bounty closure,
        then the §4.1b hours window.

        Precedence mirrors the port hub projection
        (:func:`server.api.views._port_view`): a bounty-closed port renders
        every hub row disabled with ``port.closed_bounty`` *before* the
        phase/window checks, so the refusal here is the same key the hub
        shows. :func:`server.sim.quests.bounty.can_open_facility` is the
        §4.9.6 exception: a closed port still opens the palace of the
        bountied nation's capital (the pay-off row).

        Every caller is a **hub** facility (market/shipyard/tavern/inn/
        guild/palace). The ``provisions/*`` and ``people/*`` verbs never
        call this guard — §4.9.6 keeps docking, Save and Set Sail working in
        a closed port, and the provisioning prompt is the Set-Sail flow.
        """
        self._guard_run()
        port_id = self.port_id()
        if not port_id:
            raise ApiError("not_in_port", "error.not_in_port")
        if not bounty.can_open_facility(self.gs, port_id, facility) \
                and facility in BOUNTY_GATED_FACILITIES:
            raise ApiError("closed", "port.closed_bounty")
        if not sailing.facility_open(self.store, self.gs, port_id, facility):
            raise ApiError("closed", f"{facility}.closed")
        return port_id

    def _refuse(self, msg: str, code: str = "refused") -> None:
        raise ApiError(code, msg)

    # =====================================================================
    # market
    # =====================================================================

    def _player_nation(self) -> str:
        return str(self.gs.player.get("nation_id", ""))

    def _tariff_mille(self, port_id: str) -> int:
        base = allegiance.tariff_mille(
            self.store, self.gs, self.gs, self.gs.bounties, port_id,
            self._player_nation())
        negotiation = skills.effective_skill(self.gs, self.store,
                                             "negotiation")
        return trade.tax_mille(base, negotiation)

    def _dev_of(self, port_id: str) -> int:
        return allegiance.dev(self.store, self.gs, port_id)

    def _stock(self, port_id: str, good_id: str) -> int:
        return economy.stock_of(self.gs, self.store, port_id, good_id,
                                dev_of=self._dev_of)

    def _market_buy(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("market")
        good_id = _require_str(body, "good_id")
        qty = _require_int(body, "qty")
        stock = self._stock(port_id, good_id)
        result = trade.buy(
            port_id, good_id, qty, stock=stock, gold=self.gs.gold,
            hold_free=fleet_lib.fleet_free(self.gs.fleet),
            invested_gold=trade.invested(self.gs.port_investments, port_id),
            tariff_mille=self._tariff_mille(port_id))
        if not result.ok:
            self._refuse(self._market_buy_reason(port_id, good_id, qty,
                                                 stock))
        stored = fleet_lib.add_goods(self.gs.fleet, good_id, qty)
        if stored != qty:  # pragma: no cover - buy_max already proved it
            if stored > 0:
                fleet_lib.remove_goods(self.gs.fleet, good_id, stored)
            self._refuse("market.refused")
        economy.apply_trade(self.gs, self.store, port_id, good_id, qty,
                            dev_of=self._dev_of)
        self.gs.add_gold(-result.total)
        allegiance.credit_tax(self.store, self.gs, self.gs, port_id,
                              self._player_nation(), result.tax)
        self.emit_event("market_changed", {"port_id": port_id})
        self._charge_hours(HOURS_MARKET_TRADE)
        return {"ok": True, "good_id": good_id, "qty": qty,
                "cost": result.cost, "tax": result.tax,
                "total": result.total, "gold": int(self.gs.gold),
                "stock": self._stock(port_id, good_id)}

    def _market_buy_reason(self, port_id: str, good_id: str, qty: int,
                           stock: int) -> str:
        if not self.store.get_good(good_id) or not trade.is_listed(
                port_id, good_id):
            return "market.no_listing"
        if qty <= 0:
            return "market.invalid_qty"
        if qty > trade.buy_max(
                port_id, good_id, stock=stock, gold=self.gs.gold,
                hold_free=fleet_lib.fleet_free(self.gs.fleet),
                invested_gold=trade.invested(
                    self.gs.port_investments, port_id),
                tariff_mille=self._tariff_mille(port_id)):
            return "market.buy_max"
        return "market.no_gold"

    def _market_sell(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("market")
        good_id = _require_str(body, "good_id")
        qty = _require_int(body, "qty")
        held = fleet_lib.held(self.gs.fleet, good_id)
        base = int(self.store.get_good(good_id).get("base_price", 0))
        port_nation = str(self.store.get_port(port_id).get("nation_id", ""))
        title_units = trade.title_units_from_bonus(
            fame.title_bonus(self.gs, port_nation))
        result = trade.sell(
            port_id, good_id, qty, stock=self._stock(port_id, good_id),
            held=held,
            invested_gold=trade.invested(self.gs.port_investments, port_id),
            tariff_mille=self._tariff_mille(port_id),
            title_units=title_units)
        if not result.ok:
            if not trade.port_buys_good(port_id, good_id):
                self._refuse("market.not_bought")
            if qty <= 0:
                self._refuse("market.invalid_qty")
            self._refuse("market.over_qty")
        removed = fleet_lib.remove_goods(self.gs.fleet, good_id, qty)
        if removed != qty:  # pragma: no cover - sell_max already proved it
            if removed > 0:
                fleet_lib.add_goods(self.gs.fleet, good_id, removed)
            self._refuse("market.refused")
        economy.apply_trade(self.gs, self.store, port_id, good_id, -qty,
                            dev_of=self._dev_of)
        self.gs.add_gold(result.net)
        allegiance.credit_tax(self.store, self.gs, self.gs, port_id,
                              self._player_nation(), result.tax)
        # §4.3 XP / §4.6 reputation on the gross walked proceeds. The profit
        # figure is the sim's own (trade.sale_profit_total); feeding
        # add_profit_xp one unit whose realized price yields exactly that
        # per-unit profit reproduces the oracle's single booking.
        profit = int(result.profit_total)
        if qty > 0:
            basis = (int(result.proceeds) - profit) // qty
            character.add_profit_xp(self.gs, basis + profit, base, 1)
        character.add_profit_reputation(self.gs, port_nation, profit)
        self.emit_event("market_changed", {"port_id": port_id})
        self._charge_hours(HOURS_MARKET_TRADE)
        return {"ok": True, "good_id": good_id, "qty": qty,
                "proceeds": result.proceeds, "tax": result.tax,
                "net": result.net, "profit": profit,
                "gold": int(self.gs.gold),
                "stock": self._stock(port_id, good_id)}

    def _market_invest(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("market")
        chunk = int(trade.INVEST_CHUNK)
        invested = trade.invested(self.gs.port_investments, port_id)
        protected = allegiance.is_protected(self.store, port_id)
        reason = allegiance.invest_block_reason(
            self.store, self.gs, self.gs, self.gs.bounties, port_id)
        if reason:
            self._refuse(reason)
        if not trade.can_invest(gold=self.gs.gold, invested_gold=invested,
                                protected=protected,
                                invest_block_reason=reason):
            self._refuse("market.invest_gate.exhausted")
        self.gs.port_investments[port_id] = invested + chunk
        self.gs.add_gold(-chunk)
        if not protected:
            allegiance.player_invest_chunk(self.store, self.gs, self.gs,
                                           port_id)
        self._charge_hours(HOURS_MARKET_TRADE)
        return {"ok": True, "port_id": port_id,
                "invested": invested + chunk,
                "percent": trade.investment_percent(invested + chunk),
                "gold": int(self.gs.gold)}

    # =====================================================================
    # shipyard
    # =====================================================================

    def _repair_factors(self, port_id: str) -> tuple[float, float]:
        nation = str(self.store.get_port(port_id).get("nation_id", ""))
        return (fame.repair_discount(self.gs, nation),
                sailing.carpenter_discount(self.gs, self.store))

    def _shipyard_buy(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("shipyard")
        ship_type_id = _require_str(body, "ship_type_id")
        result = shipyard.buy(
            ship_type_id, fleet=self.gs.fleet, current_port=port_id,
            gold=self.gs.gold, allegiance=self.allegiance_view)
        if not result.ok:
            self._refuse(shipyard.buy_block_reason(
                ship_type_id, current_port=port_id,
                fleet_size=len(self.gs.fleet), gold=self.gs.gold,
                allegiance=self.allegiance_view))
        self.gs.add_gold(int(result.gold_delta))
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        self._charge_hours(HOURS_SHIPYARD_BUY)
        return {"ok": True, "ship_type_id": ship_type_id,
                "gold": int(self.gs.gold), "fleet_size": len(self.gs.fleet)}

    def _shipyard_repair(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("shipyard")
        index = _require_int(body, "index")
        points = _require_int(body, "points")
        title_discount, carpenter = self._repair_factors(port_id)
        reason = shipyard.repair_block_reason(
            self.gs.fleet, index, points, gold=self.gs.gold,
            title_repair_discount=title_discount,
            carpenter_discount=carpenter)
        if reason:
            if reason == "shipyard.no_selection":
                self._refuse(reason, "bad_request")
            self._refuse(reason)
        result = shipyard.repair(
            self.gs.fleet, index, points, gold=self.gs.gold,
            title_repair_discount=title_discount,
            carpenter_discount=carpenter)
        if not result.ok:  # pragma: no cover - block reason already gated
            self._refuse("shipyard.no_gold")
        self.gs.add_gold(int(result.gold_delta))
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        self._charge_hours(HOURS_SHIPYARD_REPAIR)
        return {"ok": True, "index": index, "points": points,
                "cost": -int(result.gold_delta), "gold": int(self.gs.gold)}

    def _shipyard_sell(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("shipyard")
        index = _require_int(body, "index")
        reason = shipyard.sell_block_reason(self.gs.fleet, index)
        if reason:
            self._refuse(reason)
        price = shipyard.sell_price(self.gs.fleet, index)
        result = shipyard.sell(self.gs.fleet, index)
        if not result.ok:  # pragma: no cover
            self._refuse("shipyard.no_selection")
        self.gs.add_gold(price)
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        self._charge_hours(HOURS_SHIPYARD_SELL)
        return {"ok": True, "index": index, "price": price,
                "gold": int(self.gs.gold), "fleet_size": len(self.gs.fleet)}

    def _shipyard_refit(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("shipyard")
        index = _require_int(body, "index")
        cannons = _require_int(body, "cannons")
        reason = shipyard.refit_block_reason(self.gs.fleet, index, cannons,
                                             gold=self.gs.gold)
        if reason:
            self._refuse(reason)
        result = shipyard.refit(self.gs.fleet, index, cannons,
                                gold=self.gs.gold)
        if not result.ok:  # pragma: no cover
            self._refuse("shipyard.no_gold")
        self.gs.add_gold(int(result.gold_delta))
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        self._charge_hours(HOURS_SHIPYARD_REFIT)
        return {"ok": True, "index": index, "cannons": cannons,
                "cost": -int(result.gold_delta), "gold": int(self.gs.gold)}

    def _shipyard_equip(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("shipyard")
        slot = _require_str(body, "slot")
        equipment_id = _require_str(body, "equipment_id")
        ship_index = _optional_int(body, "ship_index", 0)
        reason = shipyard.equip_block_reason(
            self.gs.player, self.gs.fleet, slot, equipment_id, ship_index,
            current_port=port_id, gold=self.gs.gold,
            allegiance=self.allegiance_view)
        if reason:
            self._refuse(reason)
        net = shipyard.equip_net_cost(self.gs.player, self.gs.fleet, slot,
                                      equipment_id, ship_index)
        result = shipyard.equip(
            self.gs.player, self.gs.fleet, slot, equipment_id, ship_index,
            current_port=port_id, gold=self.gs.gold,
            allegiance=self.allegiance_view)
        if not result.ok:  # pragma: no cover
            self._refuse("ui.not_available")
        self.gs.add_gold(int(result.gold_delta))
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        return {"ok": True, "slot": slot, "equipment_id": equipment_id,
                "ship_index": ship_index, "net": net,
                "gold": int(self.gs.gold)}

    def _shipyard_unequip(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_port("shipyard")
        slot = _require_str(body, "slot")
        ship_index = _optional_int(body, "ship_index", 0)
        if not shipyard.can_unequip(self.gs.player, self.gs.fleet, slot,
                                    ship_index):
            self._refuse("shipyard.no_selection")
        worn = (shipyard.equipped_player(self.gs.player, slot)
                if slot in shipyard.PLAYER_SLOTS
                else shipyard.equipped_ship(self.gs.fleet, ship_index, slot))
        result = shipyard.unequip(self.gs.player, self.gs.fleet, slot,
                                  ship_index)
        if not result.ok:  # pragma: no cover
            self._refuse("shipyard.no_selection")
        self.gs.add_gold(int(result.gold_delta))
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        return {"ok": True, "slot": slot, "ship_index": ship_index,
                "worn": worn, "sellback": int(result.gold_delta),
                "gold": int(self.gs.gold)}

    def _shipyard_promote(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("shipyard")
        index = _require_int(body, "index")
        if not shipyard.promote(self.gs.fleet, index, port_id):
            self._refuse("shipyard.no_selection")
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        return {"ok": True, "index": index}

    # =====================================================================
    # tavern
    # =====================================================================

    def _tavern_hire(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("tavern")
        officer_id = _optional_str(body, "officer_id")
        if officer_id:
            if not character.recruit(self.gs, self.store, officer_id):
                self._refuse("tavern.recruit_refused")
            self._charge_hours(HOURS_TAVERN_CREW)
            return {"ok": True, "officer_id": officer_id,
                    "gold": int(self.gs.gold)}
        heads = _require_int(body, "heads")
        if not tavern.hire(self.store, self.gs.fleet, self.gs, heads,
                           open_now=True):
            self._refuse("tavern.hire_refused")
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        self._charge_hours(HOURS_TAVERN_CREW)
        return {"ok": True, "heads": heads, "gold": int(self.gs.gold),
                "crew": fleet_lib.total_crew(self.gs.fleet)}

    def _tavern_fire(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_port("tavern")
        heads = _require_int(body, "heads")
        fired = tavern.fire_clamped(self.store, self.gs.fleet, heads,
                                    open_now=True)
        if fired <= 0:
            self._refuse("tavern.fire_refused")
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        self._charge_hours(HOURS_TAVERN_CREW)
        return {"ok": True, "fired": fired,
                "crew": fleet_lib.total_crew(self.gs.fleet)}

    def _tavern_spar(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_port("tavern")
        stake = _require_int(body, "stake")
        result = tavern.spar(self.gs, self.store, stake, self.rng.randf(),
                             open_now=True)
        if not result:
            self._refuse("tavern.spar_refused")
        return {"ok": True, **result, "gold": int(self.gs.gold)}

    def _tavern_hint(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("tavern")
        discovery_id = _require_str(body, "discovery_id")
        entry = tavern.buy_hint(self.store, self.gs, self.gs.discovery_hints,
                               discovery_id)
        if not entry:
            self._refuse("tavern.rumor.no_gold")
        return {"ok": True, "port_id": port_id,
                "discovery_id": discovery_id, "entry": entry,
                "gold": int(self.gs.gold)}

    def _tavern_fill_crew(self, body: dict[str, Any]) -> dict[str, Any]:
        """The crew Fill button: ``tavern.fill_heads`` → :func:`tavern.hire`
        (docs/30-* §4.5, ``tavern_engine.gd`` ``_on_fill_pressed``): as many
        hands as fit under the flagship's ``crew_max`` *and* the purse can
        pay for, then the §4.1b hour. A zero plan is refused with the same
        gate key the crew row shows (``tavern.crew_full`` / ``market.no_gold``).
        """
        self._guard_port("tavern")
        heads = tavern.fill_heads(self.store, self.gs.fleet,
                                  int(self.gs.gold))
        if heads <= 0:
            full = tavern.max_hire(self.store, self.gs.fleet) <= 0
            self._refuse("tavern.crew_full" if full else "market.no_gold")
        if not tavern.hire(self.store, self.gs.fleet, self.gs, heads,
                           open_now=True):  # pragma: no cover - filled plan
            self._refuse("tavern.hire_refused")
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        self._charge_hours(HOURS_TAVERN_CREW)
        return {"ok": True, "heads": heads, "gold": int(self.gs.gold),
                "crew": fleet_lib.total_crew(self.gs.fleet)}

    def _tavern_down_to_min(self, body: dict[str, Any]) -> dict[str, Any]:
        """The Down-to-min button: ``tavern.min_fire`` → :func:`tavern.fire_clamped`
        (docs/30-* §4.5/§6, ``tavern_engine.gd`` ``_on_down_to_min_pressed``):
        let go exactly the hands above ``crew_min``, then the §4.1b hour."""
        self._guard_port("tavern")
        heads = tavern.min_fire(self.store, self.gs.fleet)
        fired = tavern.fire_clamped(self.store, self.gs.fleet, heads,
                                    open_now=True) if heads > 0 else 0
        if fired <= 0:
            self._refuse("tavern.fire_refused")
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        self._charge_hours(HOURS_TAVERN_CREW)
        return {"ok": True, "fired": fired,
                "crew": fleet_lib.total_crew(self.gs.fleet)}

    def _tavern_dismiss(self, body: dict[str, Any]) -> dict[str, Any]:
        """Officer dismissal: :func:`character.dismiss` (docs/50-* §4.5.5,
        ``tavern_screen.gd`` ``dismiss_officer``) — no severance, the state
        entry and post free with the roster row, one §4.1b hour."""
        self._guard_port("tavern")
        officer_id = _require_str(body, "officer_id")
        if not character.dismiss(self.gs, officer_id):
            self._refuse("tavern.fire_refused")
        self._charge_hours(HOURS_TAVERN_CREW)
        return {"ok": True, "officer_id": officer_id,
                "gold": int(self.gs.gold)}

    # =====================================================================
    # inn
    # =====================================================================

    def _inn_rest(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_port("inn")
        if not inn.can_rest(self.gs):
            self._refuse("inn.no_gold")
        result = inn.rest(self.gs, self.gs.world,
                          advance_clock=self.gs.advance_clock)
        if result is None:  # pragma: no cover - can_rest already gated
            self._refuse("inn.no_gold")
        # The rest's ledger days advanced the world clock: the ecology
        # accrues the elapsed NPC movement (the day-tick catch-up).
        self._ensure_ecology().advance_clock()
        return {"ok": True, "charged": result.charged,
                "wake_day": result.wake_day, "wake_hour": result.wake_hour,
                "day": int(self.gs.day), "gold": int(self.gs.gold)}

    def _inn_odd_job(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_port("inn")
        if not inn.odd_job_eligible(self.gs.fleet, self.gs):
            self._refuse(inn.ineligible_reason(self.gs.fleet, self.gs))
        ok = inn.work_odd_job(
            self.gs, self.gs.fleet,
            advance_port_day=lambda: sailing.advance_port_day(
                self.gs, self.gs, self.store, self.gs,
                allegiance_state=self.gs))
        if not ok:  # pragma: no cover - eligibility already gated
            self._refuse("inn.odd_job.refused")
        self._ensure_ecology().advance_clock()
        return {"ok": True, "gold": int(self.gs.gold),
                "day": int(self.gs.day)}

    # =====================================================================
    # guild
    # =====================================================================

    def _quest_offers(self, port_id: str) -> list[dict[str, Any]]:
        return quest_gen.available_offers(
            self.gs, port_id, int(self.gs.day), self.world_view)

    def _guild_offers(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("guild")
        return {"ok": True, "port_id": port_id,
                "day": int(self.gs.day),
                "refresh_day": quest_gen.next_refresh_day(int(self.gs.day)),
                "offers": self._quest_offers(port_id)}

    def _pick_offer(self, port_id: str, body: dict[str, Any]) -> dict[str, Any]:
        offers = self._quest_offers(port_id)
        instance_id = _optional_str(body, "instance_id")
        if instance_id:
            for offer in offers:
                if str(offer.get("instance_id", "")) == instance_id:
                    return offer
        else:
            index = _optional_int(body, "index", -1)
            if 0 <= index < len(offers):
                return offers[index]
        self._refuse("quest.no_offer")

    def _guild_accept(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("guild")
        offer = self._pick_offer(port_id, body)
        reason = quest_gen.accept_block_reason(
            self.gs, self.gs, offer, self.gs.fleet)
        if reason:
            self._refuse(reason)
        instance = quest_gen.accept(
            offer, self.gs, self.gs, port_id, int(self.gs.day),
            fleet=self.gs.fleet, spawn_target=self._spawn_quest_target)
        if not instance:
            self._refuse("quest.no_hold")
        self.emit_event("quests_changed", {})
        self._charge_hours(HOURS_GUILD_SIGN)
        return {"ok": True, "quest": instance}

    def _spawn_quest_target(self, instance: dict[str, Any],
                            day: int) -> str:
        """The Phase-5 bounty-target seam (quest_gen.gd): a live named
        pirate wins over a fresh spawn."""
        ecology = self._ensure_ecology()
        named = npc_fleets.preferred_bounty_target(self.gs)
        if named:
            tier = npc_fleets.named_tier_of(self.gs, named)
            instance.setdefault("requirements", {})["tier"] = tier
            rewards = instance.setdefault("rewards", {})
            gold_by_tier = quest_gen.BOUNTY_GOLD_BY_TIER
            rewards["gold"] = int(gold_by_tier.get(tier, rewards.get("gold", 0)))
            return str(named.get("id", ""))
        fleet = ecology.spawn("pirate", "", int(day))
        return str(fleet.get("id", "")) if fleet else ""

    def _guild_complete(self, body: dict[str, Any]) -> dict[str, Any]:
        """Turns in one quest at the guild (docs/70-* §4.9.3):
        :func:`quest_gen.complete_delivery_quests` (which removes the carried
        goods from the hold, then pays) or
        :func:`quest_gen.complete_exploration_quests`. Bounty quests complete
        at battle end, never here. The delivery path announces the hold
        change (``Fleet.notify_changed`` in the oracle — the caller's frame).
        """
        port_id = self._guard_port("guild")
        instance_id = _require_str(body, "instance_id")
        quest = quest_gen.find(self.gs, instance_id)
        if not quest:
            self._refuse("quest.not_found")
        quest_type = str(quest.get("type", ""))
        done: list[dict[str, Any]] = []
        if quest_type == quest_gen.TYPE_DELIVERY:
            if str(quest.get("requirements", {}).get("dest_port_id", "")) \
                    != port_id:
                self._refuse("quest.not_here")
            done = quest_gen.complete_delivery_quests(
                self.gs, self.gs, port_id, self.gs.fleet)
        elif quest_type == quest_gen.TYPE_EXPLORATION:
            discovery_id = str(
                quest.get("requirements", {}).get("discovery_id", ""))
            done = quest_gen.complete_exploration_quests(
                self.gs, self.gs, discovery_id)
        else:
            self._refuse("quest.not_completable")
        if not done:
            self._refuse("quest.not_completable")
        if quest_type == quest_gen.TYPE_DELIVERY:
            self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        self.emit_event("quests_changed", {})
        return {"ok": True, "completed": done}

    def _guild_abandon(self, body: dict[str, Any]) -> dict[str, Any]:
        """Abandons one active quest (docs/70-* §4.9.3):
        :func:`quest_gen.abandon` is the same failure path (the origin
        nation's reputation −5, no fame, no gold)."""
        self._guard_port("guild")
        instance_id = _require_str(body, "instance_id")
        quest = quest_gen.find(self.gs, instance_id)
        if not quest:
            self._refuse("quest.not_found")
        if not quest_gen.abandon(self.gs, self.gs, quest):
            self._refuse("quest.not_completable")
        self.emit_event("quests_changed", {})
        return {"ok": True, "instance_id": instance_id}

    def _guild_report(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("guild")
        discovery_id = _require_str(body, "discovery_id")
        block = discovery.report(
            self.store, self.gs, self.gs.discoveries_found,
            self.gs.discoveries_reported, discovery_id)
        if not block:
            self._refuse("guild.report.refused")
        quest_gen.complete_exploration_quests(self.gs, self.gs, discovery_id)
        self.emit_event("quests_changed", {})
        self.emit_event("discovery_reported", {"discovery_id": discovery_id})
        self.emit_event("fame_changed", {"fame": int(self.gs.fame)})
        self._charge_hours(HOURS_GUILD_SIGN)
        return {"ok": True, "port_id": port_id, "report": block,
                "gold": int(self.gs.gold)}

    # =====================================================================
    # palace
    # =====================================================================

    def _palace_closed_flags(self, port_id: str) -> tuple[bool, bool]:
        return (bounty.is_port_closed(self.gs, port_id),
                bounty.can_pay_here(self.gs, port_id))

    def _guard_palace_audience(self, port_id: str) -> None:
        """§4.9.6: a bounty-closed port's palace offers **only** ``Pay
        bounty`` (and Leave). The oracle's ``palace_screen.gd``
        ``_apply_closed_state`` disables ceremony / mission / repair /
        tournament / retire / permits with ``port.closed_bounty``; the
        server enforces the same, so ``palace/pay_bounty`` is the one verb
        that survives closure (the §4.9.5 anti-lockout path)."""
        if bounty.is_port_closed(self.gs, port_id):
            self._refuse("port.closed_bounty")

    def _palace_mission(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("palace")
        self._guard_palace_audience(port_id)
        closed, can_pay = self._palace_closed_flags(port_id)
        reason = palace.open_block_reason(self.store, port_id, closed, can_pay)
        if reason:
            self._refuse(reason)
        instance = palace.accept(
            self.store, self.gs, self.run_view, port_id, int(self.gs.day),
            delivery_stream=lambda p, d: quest_gen.offers(
                p, d, self.world_view, self.gs.discoveries_found),
            open_now=True,
            port_closed=closed,
            fleet_free=lambda: fleet_lib.fleet_free(self.gs.fleet),
            add_goods=lambda good_id, qty: fleet_lib.add_goods(
                self.gs.fleet, good_id, qty),
            remove_goods=lambda good_id, qty: fleet_lib.remove_goods(
                self.gs.fleet, good_id, qty),
            spawn_fleet=lambda role, nation, day: self._ensure_ecology().spawn(
                role, nation, int(day)))
        if not instance:
            self._refuse("palace.mission_refused")
        self.emit_event("quests_changed", {})
        self._charge_hours(HOURS_PALACE_AUDIENCE)
        return {"ok": True, "port_id": port_id, "quest": instance}

    def _palace_ceremony(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("palace")
        self._guard_palace_audience(port_id)
        rank = palace.attend_ceremony(self.store, self.gs, port_id,
                                      open_now=True)
        if not rank:
            self._refuse("ui.not_available")
        nation_id = palace.nation_of(self.store, port_id)
        self.emit_event("title_granted",
                        {"nation_id": nation_id, "rank": rank})
        self.emit_event("fame_changed", {"fame": int(self.gs.fame)})
        self._charge_hours(HOURS_PALACE_AUDIENCE)
        return {"ok": True, "port_id": port_id, "rank": rank,
                "title": fame.title(self.gs, nation_id)}

    def _palace_permit(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("palace")
        self._guard_palace_audience(port_id)
        bought = palace.buy_permit(
            self.store, self.gs, self.run_view, self.gs.permits,
            self.gs.treasuries, port_id, open_now=True)
        if not bought:
            self._refuse("palace.permit.refused")
        self._charge_hours(HOURS_PALACE_AUDIENCE)
        return {"ok": True, "port_id": port_id,
                "permits": copy.deepcopy(self.gs.permits),
                "gold": int(self.gs.gold)}

    def _palace_commend(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("palace")
        self._guard_palace_audience(port_id)
        entry = palace.pending_commendation(
            self.store, self.gs, self.gs.pending_commendations,
            self.gs.commendations_shown, port_id)
        if not entry:
            self._refuse("palace.commend.none")
        palace.dismiss_commendation(self.gs.pending_commendations,
                                    self.gs.commendations_shown)
        return {"ok": True, "commendation": entry}

    def _palace_tournament_enter(self, body: dict[str, Any]) -> dict[str, Any]:
        port_id = self._guard_port("palace")
        self._guard_palace_audience(port_id)
        closed, _can_pay = self._palace_closed_flags(port_id)
        status = palace.status(self.store, self.gs, self.run_view, port_id,
                               int(self.gs.day), closed)
        if not bool(status.get("open", False)):
            self._refuse(str(status.get("blocked", "tournament.closed")))
        if not palace.enter(self.store, self.gs, self.run_view, port_id,
                            int(self.gs.day), open_now=True,
                            port_closed=closed):
            self._refuse("tournament.closed")
        self._charge_hours(HOURS_PALACE_AUDIENCE)
        encounter = palace.encounter(self.store, 1, int(self.gs.day))
        self._open_battle(encounter, explicit=True)
        return {"ok": True, "port_id": port_id,
                "encounter": encounter}

    def _palace_repair_fleet(self, body: dict[str, Any]) -> dict[str, Any]:
        """The palace repair bays (docs/70-* §4.9.2, docs/40-* §4.3).

        ``palace.repair_cost`` / ``palace.repair`` were explicitly deferred to
        the shipyard engine at port time, so this adapter walks the oracle's
        ``palace_screen.gd repair_fleet`` over the shipyard primitives:
        per hull ``max_repair_points`` → ``repair_cost`` (the count-title
        ×0.8 + carpenter factor) → ``repair_apply``, as many points as the
        purse allows, and the two-hour bay visit charged **once**, never per
        hull.
        """
        port_id = self._guard_port("palace")
        self._guard_palace_audience(port_id)
        if not palace.nation_of(self.store, port_id):
            self._refuse("palace.not_capital")
        title_discount, carpenter = self._repair_factors(port_id)
        restored = 0
        damage = 0
        for index in range(len(self.gs.fleet)):
            points = shipyard.max_repair_points(self.gs.fleet, index)
            if points <= 0:
                continue
            damage += points
            per_point = shipyard.repair_cost(
                self.gs.fleet, index, 1,
                title_repair_discount=title_discount,
                carpenter_discount=carpenter)
            if per_point <= 0:  # pragma: no cover - data fault
                continue
            want = min(points, int(self.gs.gold) // per_point)
            if want <= 0:
                break
            result = shipyard.repair_apply(
                self.gs.fleet, index, want,
                title_repair_discount=title_discount,
                carpenter_discount=carpenter)
            if not result.ok:  # pragma: no cover - cost already proved
                continue
            self.gs.add_gold(int(result.gold_delta))
            restored += want
        if restored <= 0:
            self._refuse("shipyard.no_damage" if damage <= 0
                         else "shipyard.no_gold")
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        self._charge_hours(HOURS_PALACE_REPAIR)
        return {"ok": True, "port_id": port_id, "restored": restored,
                "gold": int(self.gs.gold)}

    def _palace_pay_bounty(self, body: dict[str, Any]) -> dict[str, Any]:
        """The palace bounty pay-off (docs/70-* §4.9.5/§4.9.6):
        :func:`bounty.pay_off` charges the amount fixed at issue time and
        ``_clear`` resets that nation's reputation to exactly −10. The
        audience is one §4.1b hour; the client posts the port nation's id."""
        port_id = self._guard_port("palace")
        port_nation = palace.nation_of(self.store, port_id)
        nation_id = _optional_str(body, "nation_id") or port_nation
        if not port_nation or nation_id != port_nation:
            self._refuse("bounty.none")
        if not bounty.pay_off(self.gs, self.gs, nation_id):
            self._refuse("bounty.no_gold"
                         if bounty.has_bounty(self.gs, nation_id)
                         else "bounty.none")
        self.emit_event("bounty_cleared", {"nation_id": nation_id})
        self._charge_hours(HOURS_PALACE_AUDIENCE)
        return {"ok": True, "nation_id": nation_id,
                "gold": int(self.gs.gold),
                "reputation": character.reputation(self.gs, nation_id)}

    def _palace_inform(self, body: dict[str, Any]) -> dict[str, Any]:
        """The paid inform on pirates (docs/70-* §4.5,
        ``palace_engine.gd inform_on_pirates``): the fixed 500g buys one live
        pirate/privateer captain's exact position through
        :func:`npc_intel.reveal_position`. The client posts the poster row's
        ``captain_id``; ``fleet_id`` is accepted as the direct spelling. A
        bounty-closed port refuses with the hub key (the palace inform row's
        ``canInform`` is false while closed)."""
        port_id = self._guard_port("palace")
        self._guard_palace_audience(port_id)
        # Lazy (see :meth:`_provisions_fill`): one source for the 500g fee.
        from server.api.plans import INFORM_COST

        fleet_id = _optional_str(body, "fleet_id")
        captain_id = _optional_str(body, "captain_id")
        if fleet_id and not self._is_pirate_fleet(fleet_id):
            self._refuse("ui.not_available")
        if not fleet_id and captain_id:
            for poster in npc_intel.wanted_posters(self.gs, port_id,
                                                   store=self.store):
                if str(poster.get("captain_id", "")) == captain_id:
                    fleet_id = str(poster.get("id", ""))
                    break
        if not fleet_id:
            self._refuse("ui.not_available")
        if int(self.gs.gold) < INFORM_COST:
            self._refuse("market.no_gold")
        reveal = npc_intel.reveal_position(self.gs, fleet_id,
                                           store=self.store)
        if not reveal:
            self._refuse("ui.not_available")
        self.gs.add_gold(-INFORM_COST)
        self._charge_hours(HOURS_PALACE_AUDIENCE)
        return {"ok": True, "port_id": port_id, "reveal": reveal,
                "gold": int(self.gs.gold)}

    def _is_pirate_fleet(self, fleet_id: str) -> bool:
        """The §4.5 inform-target rule: the fleet is live and is a
        pirate/privateer (the oracle's role check, never a merchant)."""
        for fleet in self.gs.npc_fleets:
            if not isinstance(fleet, dict):
                continue
            if str(fleet.get("id", "")) == fleet_id:
                return str(fleet.get("role", "")) in (
                    npc_fleets.PIRATE, npc_fleets.PRIVATEER)
        return False

    def _palace_retire(self, body: dict[str, Any]) -> dict[str, Any]:
        """The win state (docs/70-* §4.7): :func:`palace.can_retire` (duke
        with the docked port's nation) then :func:`palace.retire` marks the
        run retired with the wall-clock stamp; the ``retired`` event routes
        the client to the ending screen."""
        port_id = self._guard_port("palace")
        self._guard_palace_audience(port_id)
        if not palace.can_retire(self.store, self.gs, port_id):
            self._refuse("ui.not_available")
        if not palace.retire(self.store, self.gs, self.run_view, port_id,
                             int(time.time())):  # pragma: no cover - gated
            self._refuse("ui.not_available")
        self.emit_event("retired", {})
        return {"ok": True, "port_id": port_id,
                "retired_at": int(self.gs.retired_at)}

    # =====================================================================
    # provisions
    # =====================================================================

    def _provisions_set_sail(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_run()
        if not self.in_port():
            self._refuse("error.not_in_port")
        reason = sailing.supply_block_reason(self.gs)
        if not sailing.set_sail(self.gs, self.gs, self.store, self.gs,
                                allegiance_state=self.gs):
            self._refuse(reason or "provisions.blocked")
        self.intercept = {}
        self.rt = autopilot.AutopilotRuntime()
        return {"ok": True, "gold": int(self.gs.gold),
                "position": {"x": self.gs.world_tile()[0],
                             "y": self.gs.world_tile()[1]}}

    def _purchase_supplies(self, kind: str, qty: int) -> dict[str, Any]:
        """One supplies lot through the single price path
        (``TradeEngine.buy_supplies``, docs/20-* §4.10): the locked 2g/1g
        price, the ``min(gold // price, hold_free)`` ceiling, the
        ``fleet.add_supplies`` distribution. No clock and no window — the
        §4.6.1 prompt is exempt from the market hours; the caller charges
        the §4.1b hour and announces the fleet change.
        """
        price = trade.supplies_price(kind)
        if price <= 0:
            self._refuse("error.bad_request", "bad_request")
        ceiling = trade.supplies_buy_max(
            kind, gold=int(self.gs.gold),
            hold_free=fleet_lib.fleet_free(self.gs.fleet))
        if qty <= 0 or qty > ceiling:
            if qty <= 0:
                self._refuse("market.invalid_qty")
            self._refuse("market.no_gold")
        cost = price * qty
        if int(self.gs.gold) < cost:  # pragma: no cover - ceiling proved it
            self._refuse("market.no_gold")
        stored = fleet_lib.add_supplies(self.gs.fleet, kind, qty)
        if stored != qty:  # pragma: no cover
            if stored > 0:
                fleet_lib.remove_supplies(self.gs.fleet, kind, stored)
            self._refuse("market.refused")
        self.gs.add_gold(-cost)
        return {"kind": kind, "qty": qty, "cost": cost,
                "held": fleet_lib.supplies(self.gs.fleet, kind)}

    def _provisions_buy_supplies(self, body: dict[str, Any]) -> dict[str, Any]:
        """The pre-sail prompt's supply purchase (TradeEngine.buy_supplies).

        Supplies are bought at the prompt, not the market counter — no
        facility window applies (30-* §4.1b exemption); a completed purchase
        still charges the §4.1b action hour.
        """
        self._guard_run()
        if not self.in_port():
            self._refuse("error.not_in_port")
        kind = _require_str(body, "kind")
        qty = _require_int(body, "qty")
        receipt = self._purchase_supplies(kind, qty)
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        self._charge_hours(HOURS_PROVISIONS)
        return {"ok": True, **receipt, "gold": int(self.gs.gold)}

    def _provisions_fill(self, body: dict[str, Any]) -> dict[str, Any]:
        """一键补满 / Auto-fill (``provisions_dialog.gd`` ``apply_fill_plan``,
        docs/80-* §4.6.1 amended): discards the surplus first
        (:func:`fleet.remove_supplies` — the only supplies-removal path,
        freeing hold), then buys each shortfall through
        :meth:`_purchase_supplies`, one §4.1b hour per completed purchase.
        The plan is :func:`server.api.plans.fill_plan` over the live pooled
        state; an all-zero plan is refused with the prompt's own
        ``port.sail.fill.done`` copy (the button's disabled reason).
        """
        self._guard_run()
        if not self.in_port():
            self._refuse("error.not_in_port")
        # Lazy: importing ``server.api`` runs the package __init__ (which
        # imports this module) — the same seam :meth:`view` uses.
        from server.api.plans import fill_plan

        fleet = self.gs.fleet
        plan = fill_plan(fleet_lib.supplies(fleet, "provisions"),
                         fleet_lib.supplies(fleet, "water"),
                         fleet_lib.fleet_free(fleet), int(self.gs.gold))
        empty = (plan["buy_provisions"] + plan["buy_water"]
                 + plan["discard_provisions"] + plan["discard_water"])
        if empty <= 0:
            self._refuse("port.sail.fill.done")
        discarded: dict[str, int] = {}
        for kind in trade.SUPPLY_KINDS:
            qty = int(plan["discard_" + kind])
            if qty <= 0:
                continue
            removed = fleet_lib.remove_supplies(fleet, kind, qty)
            if removed != qty:  # pragma: no cover - the plan is exact
                self._refuse("fleet.nothing_to_jettison")
            discarded[kind] = removed
        bought: dict[str, int] = {}
        for kind in trade.SUPPLY_KINDS:
            qty = int(plan["buy_" + kind])
            if qty <= 0:
                continue
            self._purchase_supplies(kind, qty)
            bought[kind] = qty
            self._charge_hours(HOURS_PROVISIONS)
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        return {"ok": True, "plan": plan, "discarded": discarded,
                "bought": bought, "gold": int(self.gs.gold),
                "provisions": fleet_lib.supplies(fleet, "provisions"),
                "water": fleet_lib.supplies(fleet, "water")}

    def _provisions_jettison(self, body: dict[str, Any]) -> dict[str, Any]:
        """The Set-Sail prompt's jettison (docs/20-* §4.10, §4.6.1 amended):
        a supply row stages ``{kind, qty}`` and leaves the pooled stock
        flagship-first through :func:`fleet.remove_supplies` (refunding
        nothing); the cargo list's per-stack form is
        ``{kind: "cargo", ship_index, good_id}`` through
        :func:`fleet.jettison_good` (whole stack, the prompt's confirm
        payload). Port-only — the prompt never exists at sea.
        """
        self._guard_run()
        if not self.in_port():
            self._refuse("error.not_in_port")
        kind = _require_str(body, "kind")
        if kind in trade.SUPPLY_KINDS:
            qty = _require_int(body, "qty")
            if qty <= 0:
                self._refuse("market.invalid_qty")
            removed = fleet_lib.remove_supplies(self.gs.fleet, kind, qty)
        elif kind == "cargo":
            ship_index = _require_int(body, "ship_index")
            good_id = _require_str(body, "good_id")
            removed = fleet_lib.jettison_good(self.gs.fleet, ship_index,
                                              good_id)
        else:
            self._refuse("error.bad_request", "bad_request")
        if removed <= 0:
            self._refuse("fleet.nothing_to_jettison")
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        return {"ok": True, "kind": kind, "removed": removed}

    # =====================================================================
    # people (the §4.11.15 fleet interaction surface + officer verbs)
    # =====================================================================

    def _fleet_arg(self, body: dict[str, Any]) -> dict[str, Any]:
        fleet_id = _require_str(body, "fleet_id")
        fleet = interactions.fleet_by_id(self.run_view, fleet_id)
        if not fleet:
            self._refuse("interact.no_target")
        if not interactions.in_range(self.run_view, self.gs, self.store, fleet):
            self._refuse("interact.out_of_range")
        return fleet

    def _people_inspect(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_run()
        fleet = self._fleet_arg(body)
        return {"ok": True,
                "fleet_id": str(fleet.get("id", "")),
                "summary": interactions.inspect_summary(
                    self.store, self.run_view, fleet)}

    def _people_hail(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_run()
        fleet = self._fleet_arg(body)
        return {"ok": True,
                "fleet_id": str(fleet.get("id", "")),
                "name": hail_options.display_name(self.store, fleet),
                "options": hail_options.options_for(
                    self.store, self.gs, self.run_view, fleet)}

    def _people_talk(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_run()
        officer_id = _optional_str(body, "officer_id")
        if officer_id and not _optional_str(body, "fleet_id"):
            if not skills.talk(self.gs, officer_id):
                self._refuse("tavern.talk_refused")
            return {"ok": True, "officer_id": officer_id,
                    "loyalty": skills.loyalty(self.gs, officer_id)}
        fleet = self._fleet_arg(body)
        option_id = _optional_str(body, "option_id") or \
            hail_options.OPTION_RUMOURS
        qty = _optional_int(body, "qty", 0)
        result = hail_options.resolve(self.store, self.gs, self.run_view,
                                      option_id, fleet, qty,
                                      self.rng.randf())
        if not result.get("ok", False):
            self._refuse("hail.refused")
        return {"ok": True, "fleet_id": str(fleet.get("id", "")),
                "result": result}

    def _people_gift(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_run()
        officer_id = _require_str(body, "officer_id")
        if not skills.gift(self.gs, self.store, officer_id):
            self._refuse("tavern.gift_refused")
        return {"ok": True, "officer_id": officer_id,
                "loyalty": skills.loyalty(self.gs, officer_id),
                "gold": int(self.gs.gold)}

    def _people_befriend(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_run()
        fleet = self._fleet_arg(body)
        result = hail_options.resolve(
            self.store, self.gs, self.run_view, hail_options.OPTION_BEFRIEND,
            fleet, 0, self.rng.randf())
        if not result.get("ok", False):
            self._refuse("hail.befriend.used")
        return {"ok": True, "fleet_id": str(fleet.get("id", "")),
                "result": result}

    def _people_attack(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_run()
        if self.in_port():
            self._refuse("interact.not_at_sea")
        fleet = self._fleet_arg(body)
        if interactions.VERB_ATTACK not in interactions.verbs_for(fleet):
            self._refuse("interact.no_attack")
        encounter = interactions.attack_encounter(
            self.store, self.run_view, fleet, int(self.gs.day))
        self._open_battle(encounter, explicit=True)
        return {"ok": True, "encounter_id": str(encounter.get("id", "")),
                "encounter": encounter}

    def _people_appoint(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_run()
        officer_id = _require_str(body, "officer_id")
        post_id = _require_str(body, "post_id")
        ship_id = _optional_str(body, "ship_id")
        if not skills.appoint(self.gs, self.store, officer_id, post_id,
                              ship_id):
            self._refuse("tavern.appoint_refused")
        return {"ok": True, "officer_id": officer_id, "post_id": post_id}

    # =====================================================================
    # fleet
    # =====================================================================

    def _fleet_jettison(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_run()
        ship_index = _require_int(body, "ship_index")
        kind = _optional_str(body, "kind")
        good_id = _optional_str(body, "good_id")
        if kind:
            removed = fleet_lib.jettison_supplies(self.gs.fleet, ship_index,
                                                  kind)
        elif good_id:
            removed = fleet_lib.jettison_good(self.gs.fleet, ship_index,
                                              good_id)
        else:
            self._refuse("error.bad_request", "bad_request")
        if removed <= 0:
            self._refuse("fleet.nothing_to_jettison")
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        return {"ok": True, "removed": removed}

    def _fleet_promote(self, body: dict[str, Any]) -> dict[str, Any]:
        self._guard_run()
        index = _require_int(body, "index")
        if not fleet_lib.promote(self.gs.fleet, index, self.gs.current_port):
            self._refuse("shipyard.no_selection")
        self.gs.on_fleet_changed and self.gs.on_fleet_changed()
        return {"ok": True, "index": index}

    # =====================================================================
    # Real-time intents (WS, §0.3)
    # =====================================================================

    _DIR_ACTIONS: Final[dict[str, str]] = {
        "N": "move_n", "NE": "move_ne", "E": "move_e", "SE": "move_se",
        "S": "move_s", "SW": "move_sw", "W": "move_w", "NW": "move_nw",
    }
    _TRIMS: Final[tuple[str, ...]] = sailing.TRIM_STATES
    _SHOTS: Final[tuple[str, ...]] = (
        ROUND_SHOT, CHAIN_SHOT, ARMOR_PIERCING_SHOT, GRAPE_SHOT)

    def _guard_sea(self) -> None:
        self._guard_run()
        if self.in_port():
            raise ApiError("not_at_sea", "error.not_at_sea")

    def intent(self, frame: dict[str, Any]) -> None:
        """Dispatches one client WS intent (§0.3); raises :class:`ApiError`."""
        kind = frame.get("type")
        handler = getattr(self, f"_intent_{kind}", None) if isinstance(
            kind, str) else None
        if handler is None:
            raise ApiError("unknown_intent", "error.unknown_intent", 400)
        handler(frame)

    def _intent_helm(self, frame: dict[str, Any]) -> None:
        self._guard_sea()
        direction = frame.get("dir")
        if not isinstance(direction, str):
            raise ApiError("bad_intent", "error.bad_intent", 400)
        if direction == "stop":
            sailing.helm_stop(self.motion)
            sailing.release_direction(self.motion)
            return
        action = self._DIR_ACTIONS.get(direction)
        if action is None:
            raise ApiError("bad_intent", "error.bad_intent", 400)
        self._cancel_appointment(autopilot.REASON_MANUAL)
        mode = str(self.gs.control_prefs.get("input_mode", "step"))
        if mode == "helm":
            if not sailing.helm_steer(self.gs, self.motion, action):
                raise ApiError("bad_intent", "error.bad_intent", 400)
            return
        sailing.press_direction(self.gs, self.gs, self.store, self.gs,
                                self.motion, action,
                                allegiance_state=self.gs)

    def _intent_sail_trim(self, frame: dict[str, Any]) -> None:
        self._guard_sea()
        trim = frame.get("trim")
        if not isinstance(trim, str) or trim not in self._TRIMS:
            raise ApiError("bad_intent", "error.bad_intent", 400)
        # The sim's trim domain is sailing.TRIM_STATES; an absolute set is one
        # field write (cycle_trim's own write target), never new arithmetic.
        self.gs.world["sail_trim"] = trim

    def _intent_sail_to(self, frame: dict[str, Any]) -> None:
        self._guard_sea()
        x = frame.get("x")
        y = frame.get("y")
        if isinstance(x, bool) or isinstance(y, bool) \
                or not isinstance(x, int) or not isinstance(y, int):
            raise ApiError("bad_intent", "error.bad_intent", 400)
        self._cancel_appointment(autopilot.REASON_MANUAL)
        self.intercept = {}
        if not sailing.sail_to(self.gs, self.gs, self.store, self.gs,
                               self.motion, (int(x), int(y)),
                               allegiance_state=self.gs):
            raise ApiError("no_route", "world.sail.no_path")

    def _intent_wait(self, frame: dict[str, Any]) -> None:
        self._guard_sea()
        sailing.press_wait(self.gs, self.gs, self.store, self.gs,
                           self.motion, allegiance_state=self.gs)

    def _intent_intercept(self, frame: dict[str, Any]) -> None:
        self._guard_sea()
        if frame.get("cancel"):
            self.intercept = {}
            sailing.cancel_sail(self.motion)
            return
        fleet_id = frame.get("fleet_id")
        if not isinstance(fleet_id, str) or not fleet_id:
            raise ApiError("bad_intent", "error.bad_intent", 400)
        fleet = interactions.fleet_by_id(self.run_view, fleet_id)
        if not fleet:
            raise ApiError("interact.no_target", "interact.no_target")
        if not interactions.in_range(self.run_view, self.gs, self.store, fleet):
            raise ApiError("interact.out_of_range", "interact.out_of_range")
        order = interactions.intercept(fleet)
        self.intercept = order
        cell = order.get("target_cell", {})
        self._cancel_appointment(autopilot.REASON_MANUAL)
        sailing.sail_to(self.gs, self.gs, self.store, self.gs, self.motion,
                        (int(cell.get("x", 0)), int(cell.get("y", 0))),
                        allegiance_state=self.gs)

    def _intent_autopilot(self, frame: dict[str, Any]) -> None:
        self._guard_sea()
        if frame.get("cancel"):
            self._cancel_appointment(autopilot.REASON_MANUAL)
            return
        dest = frame.get("dest_port_id")
        if not isinstance(dest, str) or not dest:
            raise ApiError("bad_intent", "error.bad_intent", 400)
        gate = autopilot.gate(self.store, self.gs, self.run_view, dest)
        if not gate.get("ok", False):
            raise ApiError("autopilot_gate",
                           str(gate.get("reason_key") or "sail.autopilot"))
        result = autopilot.appoint(self.store, self.gs, self.run_view,
                                   self._world(), ocean_layers(), self.rt,
                                   dest)
        if not result.get("ok", False):
            raise ApiError("autopilot_no_route", "world.sail.no_path")
        self.intercept = {}
        sailing.cancel_sail(self.motion)

    def _intent_battle_order(self, frame: dict[str, Any]) -> None:
        self._guard_battle()
        order = {
            "station": frame.get("station"),
            "desired_heading8": frame.get("desired_heading8"),
            "desired_speed_band": frame.get("desired_speed_band"),
            "assigned_target": frame.get("assigned_target"),
            "discipline": frame.get("discipline"),
        }
        if not isinstance(order["station"], (list, dict)) \
                or isinstance(order["desired_heading8"], bool) \
                or not isinstance(order["desired_heading8"], int) \
                or not isinstance(order["desired_speed_band"], (list, tuple)) \
                or len(order["desired_speed_band"]) != 2:
            raise ApiError("bad_intent", "error.bad_intent", 400)
        self.battle.order = order

    def _guard_battle(self) -> BattleSession:
        self._guard_run()
        if self.battle is None:
            raise ApiError("not_in_battle", "error.not_in_battle")
        return self.battle

    def _intent_battle_action(self, frame: dict[str, Any]) -> None:
        battle = self._guard_battle()
        verb = frame.get("verb")
        if verb not in ("broadside", "hook", "retreat", "surrender"):
            raise ApiError("bad_intent", "error.bad_intent", 400)
        sim = battle.sim
        if sim.is_over():
            self._finish_battle()
            raise ApiError("not_in_battle", "error.not_in_battle")
        if verb == "retreat":
            sim.retreat()
            self._finish_battle()
            return
        if verb == "surrender":
            sim.offer_surrender()
            self._finish_battle()
            return
        unit = sim.current_unit()
        if not unit or str(unit.get("side", "")) != SIDE_PLAYER:
            raise ApiError("not_your_turn", "error.not_your_turn")
        self._apply_player_movement(sim, unit, battle.order)
        target = self._battle_target(sim, unit, battle.order)
        if not target:
            sim.hold(unit)
            sim.end_turn()
            return
        if verb == "hook":
            if sim.can_board(unit, target):
                sim.board(unit, target)
            else:
                sim.hold(unit)
        else:
            side = frame.get("side")
            if side not in (BROADSIDE_PORT, BROADSIDE_STARBOARD, None, ""):
                raise ApiError("bad_intent", "error.bad_intent", 400)
            shot = frame.get("shot") or ROUND_SHOT
            if shot not in self._SHOTS:
                raise ApiError("bad_intent", "error.bad_intent", 400)
            gunnery = sim.player_effective_skill("gunnery")
            if shot != ROUND_SHOT and not shot_unlocked(str(shot), gunnery):
                raise ApiError("shot_locked", "battle.shot.locked")
            chosen_side = str(side) if side else self._cannon_side(
                sim, unit, target)
            if chosen_side and sim.can_cannon(unit, target, chosen_side):
                sim.cannon(unit, target, chosen_side, str(shot))
            else:
                sim.hold(unit)
        sim.end_turn()
        if sim.is_over():
            self._finish_battle()

    def _apply_player_movement(self, sim: BattleSim, unit: dict[str, Any],
                               order: dict[str, Any]) -> None:
        """Picks one legal velocity from the engine's own enumeration that
        matches the order's heading/speed band (§4.9b semantics)."""
        heading = order.get("desired_heading8")
        band = order.get("desired_speed_band")
        if isinstance(heading, bool) or not isinstance(heading, int):
            return
        if not isinstance(band, (list, tuple)) or len(band) != 2:
            return
        low, high = int(band[0]), int(band[1])
        for vel in sim.legal_velocities(unit):
            magnitude = vel_length(vel)
            if heading8_of(vel) == heading and low <= magnitude <= high:
                sim.apply_velocity(unit, vel)
                return

    def _battle_target(self, sim: BattleSim, unit: dict[str, Any],
                       order: dict[str, Any]) -> dict[str, Any]:
        assigned = order.get("assigned_target")
        living = sim.living_units(SIDE_ENEMY)
        if isinstance(assigned, int) and not isinstance(assigned, bool):
            for enemy in living:
                if int(enemy.get("index", -1)) == assigned:
                    return enemy
        if not living:
            return {}
        origin = sim.unit_cell(unit)
        living.sort(key=lambda enemy: (
            max(abs(sim.unit_cell(enemy)[0] - origin[0]),
                abs(sim.unit_cell(enemy)[1] - origin[1])),
            int(enemy.get("index", 0))))
        return living[0]

    @staticmethod
    def _cannon_side(sim: BattleSim, unit: dict[str, Any],
                     target: dict[str, Any]) -> str:
        for side in (BROADSIDE_PORT, BROADSIDE_STARBOARD):
            if sim.can_cannon(unit, target, side):
                return side
        return ""

    def _intent_locale(self, frame: dict[str, Any]) -> None:
        locale = frame.get("locale")
        if not isinstance(locale, str) or locale not in ("zh", "en"):
            raise ApiError("bad_locale", "error.bad_locale", 400)
        self.set_locale(locale)

    def _cancel_appointment(self, reason: str) -> None:
        if autopilot.appointed(self.gs):
            autopilot.cancel(self.gs, self.run_view, self.rt, reason)

    def _world(self) -> Any:
        return raster()

    # =====================================================================
    # Battle lifecycle
    # =====================================================================

    def _open_battle(self, encounter: dict[str, Any],
                     explicit: bool = False) -> None:
        if self.battle is not None or not encounter:
            return
        if not self.has_run() or self.retired() or self.game_over():
            return
        gs = self.gs
        contact = encounter.get("contact")
        if not isinstance(contact, dict):
            contact = {"x": gs.world_tile()[0], "y": gs.world_tile()[1]}
        cell = (int(contact.get("x", 0)), int(contact.get("y", 0)))
        kind = str(encounter.get("kind", "pirate"))
        rng = GodotRng(battle_seed_formula(
            int(gs.day), cell, int(gs.gold), len(gs.fleet)))
        enemy_ships = encounter.get("ships")
        if not isinstance(enemy_ships, list) or not enemy_ships:
            enemy_ships = ai_fleet.compose_enemy(kind, int(gs.day), rng)
        config: dict[str, Any] = {
            "player_ships": copy.deepcopy(gs.fleet),
            "enemy_ships": copy.deepcopy(enemy_ships),
            "enemy_kind": kind,
            "enemy_nation": str(encounter.get("nation_id", "")),
            "day": int(encounter.get("day", gs.day)),
            "gold": int(gs.gold),
            "contact": cell,
            "weather": str(encounter.get("weather",
                                        gs.world.get("weather", "calm"))),
            "encounter_id": str(encounter.get("id", "")),
            "rng": rng,
            "wind_dir": str(encounter.get(
                "wind_dir", gs.world.get("wind_dir", "E"))),
            "captain_id": str(encounter.get("captain_id", "")),
            "officer_states": copy.deepcopy(gs.officer_states),
        }
        current = encounter.get("current")
        if isinstance(current, dict):
            config["current"] = copy.deepcopy(current)
        sim = BattleSim(config)
        sim.start()
        self.battle = BattleSession(
            sim=sim, encounter=copy.deepcopy(encounter),
            idle_officer_ids=skills.officers_in_post(gs, ""))
        gs.pending_encounter = copy.deepcopy(encounter)
        # §4.11.11.2 / §4.11.10: the single battle-start piracy funnel.
        if str(encounter.get("role", "")) != npc_fleets.PIRATE:
            nation_id = str(encounter.get("nation_id", ""))
            if nation_id:
                applied = battle_rewards.apply_piracy_attack(
                    nation_id, str(encounter.get("captain_id", "")),
                    self.gs, fame_before=int(gs.fame))
                if int(applied.get("fame", 0)) != 0:
                    fame.add(gs, int(applied["fame"]))
        self._cancel_appointment(autopilot.REASON_CONTACT)
        sailing.reset_motion(self.motion)
        self.emit_event("battle_started",
                        {"encounter_id": self.battle.encounter_id(),
                         "kind": kind})
        self._pump_battle()

    def _pump_battle(self) -> None:
        """Runs enemy turns until a player ship acts (or the battle ends)."""
        battle = self.battle
        if battle is None:
            return
        sim = battle.sim
        guard = 0
        limit = max(len(sim.units()), 1) * 4 + 8
        while not sim.is_over():
            guard += 1
            if guard > limit:
                break
            unit = sim.current_unit()
            if not unit:
                sim.end_turn()
                continue
            if str(unit.get("side", "")) == SIDE_ENEMY:
                decision = ai_fleet.decide(sim, unit, {}, None)
                # The oracle's own decision executor (battle_screen.gd's
                # guarded `_apply_decision` seam).
                sim._apply_decision(unit, decision)  # noqa: SLF001
                if not sim.is_over():
                    sim.end_turn()
                continue
            break
        if sim.is_over():
            self._finish_battle()

    def battle_frame(self) -> dict[str, Any]:
        """The ``battle_tick`` slice (§0.3) from the live engine."""
        battle = self.battle
        if battle is None:
            return {"type": "battle_tick", "round": 0, "phase": "none",
                    "ships": [], "wind": "E", "weather": "calm",
                    "orders_due": False}
        sim = battle.sim
        acting = sim.current_unit()
        if sim.is_over():
            phase = "over"
        elif acting and str(acting.get("side", "")) == SIDE_PLAYER:
            phase = "player"
        else:
            phase = "enemy"
        ships: list[dict[str, Any]] = []
        for unit in sim.units():
            ship = unit.get("ship", {}) if isinstance(unit, dict) else {}
            side = str(unit.get("side", ""))
            position = sim.unit_cell(unit)
            velocity = to_cell(unit.get("vel", (0, 0)))
            ships.append({
                "id": f"{side}_{int(unit.get('index', 0))}",
                "side": side,
                "kind": str(ship.get("ship_type_id", "")),
                "position": {"x": int(position[0]), "y": int(position[1])},
                "velocity": {"x": int(velocity[0]), "y": int(velocity[1])},
                "heading8": int(unit.get("heading8", 0)),
                "hull": int(ship.get("durability", 0)),
                "crew": int(unit.get("crew", 0)),
                "morale": int(sim.side_morale(side)),
                "reload": {
                    "port": int(unit.get("reload_port", 0)),
                    "starboard": int(unit.get("reload_starboard", 0)),
                },
            })
        return {
            "type": "battle_tick",
            "round": int(sim.round_number()),
            "phase": phase,
            "ships": ships,
            "wind": str(sim.wind_dir),
            "weather": str(sim.weather),
            "orders_due": bool(acting) and phase == "player",
        }

    def _finish_battle(self) -> None:
        """§4.12.4's five steps over the ported modules."""
        battle = self.battle
        if battle is None:
            return
        sim = battle.sim
        if not sim.is_over():
            return
        self.battle = None
        gs = self.gs
        outcome = sim.outcome()
        outcome["captain_id"] = str(battle.encounter.get("captain_id", ""))
        # 2. fleet effects (captures/losses/game-over report).
        applied = battle_result.apply(
            outcome, sim.units(), gs.fleet, battle.idle_officer_ids)
        # 3. gold / XP / reputation / morale.
        appraisal = skills.effective_skill(gs, self.store, "appraisal")
        negotiation = skills.effective_skill(gs, self.store, "negotiation")
        rewards = battle_rewards.apply(
            applied, gs, appraisal=appraisal, negotiation=negotiation,
            morale_before=int(gs.morale), day=int(gs.day))
        gold = int(rewards.get("gold", 0))
        if gold:
            gs.add_gold(gold)
        morale_delta = int(rewards.get("morale", 0))
        if morale_delta:
            gs.morale = max(0, min(sailing.MORALE_MAX,
                                   int(gs.morale) + morale_delta))
        # 3b. rare drop for a named pirate captain.
        captain = battle.encounter.get("captain")
        named_id = str(captain.get("named_id", "")) if isinstance(
            captain, dict) else ""
        result = str(applied.get("result", ""))
        if named_id and result in (RESULT_VICTORY, "surrender"):
            battle_rewards.apply_named_drop(applied, named_id, gs, gs.fleet)
        # 4. ecology bookkeeping: remove, or cooldown after a retreat.
        encounter_id = battle.encounter_id()
        ecology = self._ensure_ecology()
        if encounter_id:
            if result == RESULT_RETREAT:
                ecology.set_pursuit_cooldown(
                    encounter_id, int(gs.day) + int(npc_fleets.PURSUIT_COOLDOWN_DAYS))
            else:
                ecology.remove(encounter_id)
        # 4b. Phase-3 hooks (win counter, bounty quests, patrol kills).
        phase3 = phase3_hooks.on_battle_finished(gs, gs, applied)
        if phase3_hooks.is_tournament(encounter_id):
            bout = phase3_hooks.on_tournament_bout(
                gs, gs, applied,
                tournament_settle=lambda won, round_reached: palace.settle(
                    self.store, gs, self.run_view, bool(won),
                    int(round_reached)),
                tournament_rounds=len(palace.ROUND_HULLS))
            applied["tournament"] = bout
            if bout:
                self.emit_event("tournament_finished", {"outcome": bout})
        gs.pending_encounter = None
        # 5. position + announcement.
        contact = applied.get("contact")
        if isinstance(contact, dict):
            gs.set_world_tile(int(contact.get("x", 0)),
                              int(contact.get("y", 0)))
        applied["phase3"] = phase3
        sailing.reset_motion(self.motion)
        gs.on_fleet_changed and gs.on_fleet_changed()
        self.emit_event("battle_finished", {
            "encounter_id": encounter_id, "result": result,
            "outcome": applied})
        self.queue_state()

    # =====================================================================
    # The sim loop
    # =====================================================================

    def tick(self, seconds: float = SIM_DT) -> None:
        """One sim tick: battle OR the sailing slice, then ONE broadcast."""
        if self.battle is not None:
            self._pump_battle()
            if self.battle is not None and self.client is not None:
                self.client.enqueue_tick(self.battle_frame())
            return
        if not self.has_run():
            return
        if self.in_port() or self.game_over() or self.retired():
            return

        before = self.gs.world_tile()
        sailing.advance_motion(
            self.gs, self.gs, self.store, self.gs, self.motion, seconds,
            allegiance_state=self.gs)
        self._tick_autopilot(seconds)
        self._accrue()
        after = self.gs.world_tile()
        if self.in_port():
            # Docking inside the cadence ends the sea slice for this tick.
            self.intercept = {}
            return
        if before != after:
            self._tick_intercept()
            self._check_contact()
        if self.battle is not None:
            if self.client is not None:
                self.client.enqueue_tick(self.battle_frame())
            return
        if self.client is not None:
            self.client.enqueue_tick(self.tick_frame())

    def _tick_autopilot(self, seconds: float) -> None:
        if not autopilot.appointed(self.gs):
            return
        result = autopilot.tick(self.store, self.gs, self.run_view, self._world(),
                                ocean_layers(), self.rt)
        if not result.get("appointed", False):
            return
        if result.get("arrived", False):
            dest = str(result.get("dest", ""))
            shore = self._world().shore_cell(dest) if dest else (-1, -1)
            if shore[0] >= 0:
                sailing.dock_at(self.gs, self.gs, self.store, self.gs,
                                self.motion, shore, allegiance_state=self.gs)
            autopilot.cancel(self.gs, self.run_view, self.rt,
                             autopilot.REASON_ARRIVED)
            self._autopilot_elapsed = 0.0
            return
        self._autopilot_elapsed += seconds
        while self._autopilot_elapsed >= sailing.SAIL_STEP_SECONDS:
            self._autopilot_elapsed -= sailing.SAIL_STEP_SECONDS
            route = result.get("route") or []
            if not route:
                break
            cell = route[0]
            if not self._step_to(cell):
                autopilot.cancel(self.gs, self.run_view, self.rt,
                                 autopilot.REASON_MANUAL)
                break
            result = autopilot.tick(self.store, self.gs, self.run_view,
                                    self._world(), ocean_layers(), self.rt)
            if result.get("arrived", False):
                dest = str(result.get("dest", ""))
                shore = self._world().shore_cell(dest) if dest else (-1, -1)
                if shore[0] >= 0:
                    sailing.dock_at(self.gs, self.gs, self.store, self.gs,
                                    self.motion, shore,
                                    allegiance_state=self.gs)
                autopilot.cancel(self.gs, self.run_view, self.rt,
                                 autopilot.REASON_ARRIVED)
                self._autopilot_elapsed = 0.0
                return

    def _step_to(self, cell: tuple[int, int]) -> bool:
        return sailing.try_step(self.gs, self.gs, self.store, self.gs,
                                self.motion, (int(cell[0]), int(cell[1])),
                                allegiance_state=self.gs)

    def _tick_intercept(self) -> None:
        if not self.intercept:
            return
        reason = interactions.intercept_cancel_reason(
            self.run_view, self.gs, self.store, self.intercept)
        if reason:
            self.intercept = {}
            sailing.cancel_sail(self.motion)
            return
        fleet = interactions.fleet_by_id(
            self.run_view, str(self.intercept.get("target_id", "")))
        if not fleet:
            return
        cell = npc_fleets.position_of(fleet)
        chased = self.intercept.get("target_cell", {})
        chased_cell = (int(chased.get("x", -1)), int(chased.get("y", -1))) \
            if isinstance(chased, dict) else (-1, -1)
        if cell == chased_cell:
            return
        self.intercept["target_cell"] = {"x": cell[0], "y": cell[1]}
        if not sailing.sail_to(self.gs, self.gs, self.store, self.gs,
                               self.motion, cell, allegiance_state=self.gs):
            self.intercept = {}
            sailing.cancel_sail(self.motion)

    def _check_contact(self) -> None:
        if self.battle is not None or self.in_port():
            return
        ecology = self._ensure_ecology()
        fleet = ecology.nearest_contact(self.gs.world_tile())
        if not fleet:
            return
        encounter = interactions.attack_encounter(
            self.store, self.run_view, fleet, int(self.gs.day))
        self._open_battle(encounter, explicit=False)

    def tick_frame(self) -> dict[str, Any]:
        """The ``tick`` slice (§0.3) — the sailing HUD's per-tick payload."""
        gs = self.gs
        x, y = gs.world_tile()
        heading = sailing.helm_heading(gs)
        hint: dict[str, Any] | None = None
        try:
            contact = self._ensure_ecology().nearest_contact((x, y))
        except Exception:  # noqa: BLE001 - the HUD hint never breaks a tick
            contact = {}
        if contact:
            hint = {"fleet_id": str(contact.get("id", "")),
                    "role": str(contact.get("role", ""))}
        return {
            "type": "tick",
            "day": int(gs.day),
            "clock_min": int(sailing.time_of_day_minutes(gs)),
            "position": {"x": int(x), "y": int(y)},
            "heading": heading,
            "sail_trim": sailing.sail_trim(gs),
            "wind_dir": str(gs.world.get("wind_dir", "E")),
            "weather": str(gs.world.get("weather", "calm")),
            "speed": float(sailing.speed_knots(gs, gs, self.store)),
            "gold": int(gs.gold),
            "morale": int(gs.morale),
            "autopilot": autopilot.hud_state(
                self.store, gs, self.run_view, self._world(), ocean_layers(),
                self.rt,
                effective_speed=lambda heading="": sailing.effective_speed(
                    gs, gs, self.store, heading)),
            "contact_hint": hint,
        }
