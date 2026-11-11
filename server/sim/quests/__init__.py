"""server.sim.quests — the quest layer package (M1).

Port of the Godot quest trio (the frozen parity oracle until the M6
cutover, per ``docs/90-ARCHITECTURE.md`` §0):

  * :mod:`server.sim.quests.quest_gen` — ``scripts/quests/quest_gen.gd``:
    guild commission offers, acceptance/tracking, completion/failure and
    the reward payout (docs/70-QUESTS-DISCOVERY-ENDGAME.md §4.2, §4.9.3).
  * :mod:`server.sim.quests.bounty` — ``scripts/quests/bounty.gd``: the
    piracy reputation block, bounty issue/clearing and the closed-port
    rule (docs/70-* §4.5, §4.9.5, §4.9.6).
  * :mod:`server.sim.quests.phase3_hooks` —
    ``scripts/quests/phase3_hooks.gd``: the integration wiring that binds
    the quest systems to the day tick / port entry / battle end seams
    (docs/70-* §4.2–§4.7, §4.9.3–§4.9.7).

State convention (the M1 port rule for autoload-coupled statics): the
GDScript statics read and mutate ``GameState`` singleton fields; here the
quest-layer run state is an explicit :class:`QuestState` object the
caller passes alongside the :class:`~server.sim.player.PersonState` (the
person fields the quest layer also touches — gold, day, the player block
with its reputation map, fame, titles — stay on ``PersonState``, so the
v9 save shapes of both halves stay exactly their locked selves). Nothing
in this package keeps module-level singletons. EventBus announcements
(``quests_changed``, ``bounty_issued``, ``bounty_cleared``,
``gold_changed``) are the caller's WS ``event`` frames (``90-*`` §0.3)
— every function returns the applied delta instead of emitting.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol

__all__ = ["QuestState", "WorldView", "RasterWorld"]


@dataclass
class QuestState:
    """The run-scoped state the quest layer reads and mutates.

    Field names mirror the GDScript ``GameState`` autoload members
    verbatim (``90-*`` §5.4). They are top-level run fields exactly as in
    the engine (``discoveries_found``/``npc_fleets``/``titles`` are not
    inside the player block). ``pending_tournament_round`` and
    ``last_tournament_outcome`` are the S13 tournament transient fields
    (``70-*`` §4.9.7) — ``phase3_hooks`` is the quest-side consumer and
    takes/clears them like the GDScript did.
    """

    ## GameState.active_quests — stored quest instances (§4.9.3 shape).
    active_quests: list[Any] = field(default_factory=list)
    ## GameState.bounties — ``{nation_id: {"amount", "day"}}`` (§4.9.5).
    bounties: dict[str, Any] = field(default_factory=dict)
    ## GameState.npc_fleets — the ecology markers; bounty targets are
    ## members tagged with ``quest_id`` (§4.9.3).
    npc_fleets: list[Any] = field(default_factory=list)
    ## GameState.discoveries_found — found discovery ids; the exploration
    ## draw only offers unfound ones (§4.9.3).
    discoveries_found: list[Any] = field(default_factory=list)
    ## GameState.battles_won — incremented on every ``victory`` outcome
    ## (70-* §4.7 ending summary; phase3_hooks owns the counter).
    battles_won: int = 0
    ## GameState.pending_tournament_round — the bout S13 should start (§4.9.7).
    pending_tournament_round: int = 0
    ## GameState.last_tournament_outcome — the bracket block S13 reports
    ## on open; taken exactly once (§4.9.7).
    last_tournament_outcome: dict[str, Any] = field(default_factory=dict)


class WorldView(Protocol):
    """The map-position seam (``90-*`` §0: the server holds both halves).

    The GDScript quest layer reads ``DataLoader.ensure_map()`` +
    ``DataLoader.port_cell()`` and ``DiscoveryLib.map_width()`` — the
    runtime harbor table (``data/maps/harbors.json`` berth tiles) and the
    locked legend grid width. Here both arrive injected: ``port_cell``
    returns the berth tile or ``(-1, -1)`` for an unknown id; ``map_width``
    returns the legend width (4320 for the world map, ``70-*`` §4.9.3
    wrap arithmetic).
    """

    def port_cell(self, port_id: str) -> tuple[int, int]:
        """Berth tile of ``port_id``, ``(-1, -1)`` when it has none."""
        ...

    def map_width(self) -> int:
        """The world grid width in tiles (the wrap modulus)."""
        ...


class RasterWorld:
    """The :class:`WorldView` over a decoded
    :class:`~server.sim.world.raster.WorldRaster` — the adapter the
    server wires once per process (the harbor-pair contract, §9.1: the
    runtime reads ``data/maps/harbors.json`` and never re-snaps)."""

    __slots__ = ("_raster",)

    def __init__(self, raster: Any) -> None:
        self._raster = raster

    def port_cell(self, port_id: str) -> tuple[int, int]:
        return self._raster.port_cell(port_id)

    def map_width(self) -> int:
        return int(self._raster.width)
