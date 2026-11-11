"""server.sim.player — the Person-model package (M1).

Port of the Godot person-model trio (the frozen parity oracle until the M6
cutover, per ``docs/90-ARCHITECTURE.md`` §0):

  * :mod:`server.sim.player.character` — ``scripts/player/character.gd``:
    the player Person block, XP/level/``alloc_pending``, officers and
    reputation (docs/50-CHARACTER-AND-PROGRESSION.md §4.1–§4.6, §4.8).
  * :mod:`server.sim.player.skills` — ``scripts/player/skills.gd``: the
    11-skill space, usage growth, paid training, in-post officer
    contribution, appointments, the officer day tick and loyalty (§4.3,
    §4.5).
  * :mod:`server.sim.player.fame` — ``scripts/player/fame.gd``: fame and the
    per-nation nobility-title ladder (docs/70-QUESTS-DISCOVERY-ENDGAME.md
    §4.1, §4.9.1, §4.9.2).

State convention (the M1 port rule for autoload-coupled statics): the
GDScript statics read and mutate ``GameState`` singleton fields. Here the
run-scoped state is an explicit :class:`PersonState` object the caller
passes as the first argument of every stateful function — the server holds
one in its GameState equivalent (``90-*`` §0.2/§5.4); nothing in this
package keeps module-level singletons. :class:`PersonState` mirrors exactly
the ``GameState`` fields the trio touches, plus the two session-transient
flags that GDScript kept as ``Character`` class statics (``pending_levelup``
— §4.4 "not saved", correction 12; ``pending_raise`` — the §4.5.4 raise
demand); both are deliberately absent from the §4.8 save payload and here
live on the state object instead of a module global for the same reason.

Pure functions (``level_for_xp``, ``xp_for_level``, ``growth_threshold``,
``speed_bonus_for``, …) stay pure: no ``PersonState`` argument.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

__all__ = ["PersonState"]


@dataclass
class PersonState:
    """The run-scoped state the person-model trio reads and mutates.

    Field names mirror the GDScript ``GameState`` autoload members verbatim
    (``90-*`` §5.4; the ``player`` block shape is the v9 Person block,
    docs/50-* §4.8; ``officer_states``/``titles``/``completed_royal_missions``
    are top-level run fields, not inside ``player``). The two ``pending_*``
    flags are the session-transient ``Character`` class statics — never
    saved.
    """

    ## The §4.8 player save block (v9 Person shape).
    player: dict[str, Any] = field(default_factory=dict)
    ## The ``officer_states`` block (``90-*`` §8): employed officers'
    ## ``{loyalty, sea_days, post_id, ship_id, talk_cd_day, gift_cd_day,
    ## defeats, wage_mult}`` entries.
    officer_states: dict[str, Any] = field(default_factory=dict)
    ## GameState.gold — the purse every paid verb reads.
    gold: int = 0
    ## GameState.day — the ledger day the cooldowns compare against.
    day: int = 1
    ## GameState.fame — the title-ladder currency (70-* §4.1; never negative).
    fame: int = 0
    ## GameState.titles — ``{nation_id: rank}`` over the six nations
    ## (70-* §4.9.2; rank ``none`` … ``duke``).
    titles: dict[str, str] = field(default_factory=dict)
    ## GameState.completed_royal_missions — per-nation completed count.
    completed_royal_missions: dict[str, int] = field(default_factory=dict)

    ## Session-transient (Character.pending_levelup): raised by
    ## ``character.award_xp`` when a level was gained; the caller renders the
    ## toast and consumes it via ``character.consume_pending_levelup``.
    pending_levelup: bool = False
    ## Session-transient (Character.pending_raise): raised by the officer
    ## day tick while any employed officer's loyalty sits below 30; resolved
    ## by ``skills.accept_raise``/``skills.refuse_raise``.
    pending_raise: bool = False
