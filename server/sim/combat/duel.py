"""server.sim.combat.duel — the captain duel entry points (M1).

Python port of ``scripts/combat/duel.gd`` (the frozen parity oracle until the
M6 cutover) — docs/60-COMBAT.md §4.6, §4.11.6, §4.12.1.2, §4.12.3.

**One formula, one owner:** every roll is produced by
:func:`server.sim.combat.battle_sim.resolve_duel` (the §4.12.1.2 single
implementation the battle's ``board`` action already calls). This module only
prepares the two bases (§4.11.6), supplies the seeded / handed-over stream,
and packages the presentation payload (per-round rolls, both bases, the
captain names). It never re-implements the win rule, the round cap or the
``capture`` / ``defeat`` decision.

The S11 scene half of the oracle (``presentation_host`` / ``open_modal`` /
the ``await closed`` handshake) has no server-side counterpart: the FastAPI
server is the authoritative sim and the React client renders. :func:`start`
therefore STOPS AT THE SEAM and returns :func:`resolve_duel`'s dictionary
unchanged — the exact return contract §4.12.3 pins — while :func:`preview`
carries everything the UI renders.

The §4.11.1 seed formula itself is owned by
:func:`server.sim.combat.battle_sim.battle_seed_formula`; ``duel.gd`` never
recomputes it. A caller that wants the duel on the battle's single §4.11.1
stream hands the sim's ``rng`` in through ``config["rng"]`` (after deployment
and enemy composition, §4.11.1); otherwise an explicit ``seed`` starts a
fresh :class:`server.sim.rng.GodotRng`, else seed 0 (the oracle's warning
path).
"""

from __future__ import annotations

import sys
from typing import Any, Final

from server.sim.combat.battle_sim import (
    CAPTAIN_RATING_BASE,
    DUEL_ROUND_MAX_ROLL,
    BattleSim,
    defender_charisma_bonus as _defender_charisma_bonus,
    defender_duel_base as _defender_duel_base,
    resolve_duel,
)
from server.sim.rng import GodotRng

__all__ = [
    "CAPTAIN_RATING_BASE",
    "player_base",
    "defender_base",
    "defender_charisma_bonus",
    "captain_rating",
    "preview",
    "start",
]

#: §4.11.6: ``5 + fleet tier``; the tier table itself lives in
#: :mod:`server.sim.combat.battle_sim` (``FLEET_TIER``: pirate 1, navy 2) and
#: is not copied here.
_CAPTAIN_RATING_BASE: Final[int] = CAPTAIN_RATING_BASE


# --- Bases (docs/60-* §4.11.6) ------------------------------------------------


def player_base(stats: dict[str, Any] | None = None) -> int:
    """The player's duel base (§4.11.6, Phase 8): swordplay +
    ``floor(courage / 20)`` + the ``combat`` modifiers of both worn player
    items (§4.11.12) — delegated to :meth:`BattleSim.player_duel_base`, the
    single implementation.

    ``stats`` is the Person block the caller injects (the sim's
    ``player_stats`` shape: ``{"attributes", "skills", "equipment"}``). The
    Python engine has no ``GameState`` autoload, so an absent block reads as
    the defensive 0-base (the same no-run read as
    :meth:`BattleSim.player_attribute` / ``player_effective_skill``).
    """
    return BattleSim({"player_stats": dict(stats or {})}).player_duel_base()


def defender_base(crew: int, captain_rating: int) -> int:
    """The AI captain's base: ``min(floor(crew / 5), 20) + captain_rating``
    (§4.11.6; the crew/captain terms only). Delegated to
    :func:`server.sim.combat.battle_sim.defender_duel_base` — the same
    formula the battle's boarding action uses, which adds the §4.11.6
    defender charisma bonus on top for whichever side defends.
    """
    return _defender_duel_base(crew, captain_rating)


def defender_charisma_bonus(charisma: int) -> int:
    """§4.11.6 Phase-8 defender bonus: ``floor(charisma / 20)`` for whichever
    side defends (the player's own charisma when the player defends, the
    captain card's otherwise). Delegated to the sim's single implementation.
    """
    return _defender_charisma_bonus(charisma)


def captain_rating(fleet_tier: int) -> int:
    """§4.6/§4.11.6 legacy ``5 + fleet tier`` (pirate 1, navy 2) — the
    stand-in that prices fleets without a captain canon card. The tier table
    itself lives in :mod:`server.sim.combat.battle_sim` (``FLEET_TIER``) and
    is not copied here.
    """
    return _CAPTAIN_RATING_BASE + int(fleet_tier)


# --- The duel payloads --------------------------------------------------------


def preview(config: dict[str, Any]) -> dict[str, Any]:
    """Resolves one duel and returns everything the duel screen renders,
    without any presentation side effects::

        {"outcome", "rolls", "player_base", "defender_base",
         "attacker_name", "defender_name", "ship_name"}

    ``outcome`` is :func:`resolve_duel`'s return value untouched;
    ``rolls[i]`` is ``{"player", "defender"}`` — the two individual rolls of
    round ``i``, recovered by replaying the **same** RNG stream from the
    snapshot taken just before ``resolve_duel`` consumed it (the function
    draws player-then-defender, §4.11.6). Replaying roll values is
    presentation only: the round labels and the result still come from
    ``resolve_duel``.

    ``config``: ``{player_base, defender_base, seed, ship_name,
    attacker_name, defender_name}`` (§4.12.3) plus the optional extras
    ``player_stats`` (the base's Person block) and ``rng`` (continue an
    existing §4.11.1 stream — the additive seam).
    """
    if "player_base" in config:
        player_rating = int(config.get("player_base", 0))
    else:
        player_rating = player_base(config.get("player_stats"))
    defender_rating = int(config.get("defender_base", 0))
    rng = _rng_for(config)
    state_before = rng.state
    outcome = resolve_duel(player_rating, defender_rating, rng)
    return {
        "outcome": outcome,
        "rolls": _replay_rolls(
            state_before, player_rating, defender_rating,
            len(outcome.get("rounds", []))),
        "player_base": player_rating,
        "defender_base": defender_rating,
        "attacker_name": str(config.get("attacker_name", "")),
        "defender_name": str(config.get("defender_name", "")),
        "ship_name": str(config.get("ship_name", "")),
    }


def start(config: dict[str, Any]) -> dict[str, Any]:
    """Runs a duel and returns :func:`resolve_duel`'s dictionary unchanged.

    The oracle awaits the S11 modal here; the server-side port stops at that
    seam (the client renders :func:`preview`'s payload and POSTs its
    acknowledgement). Headless by construction: no presentation, no blocking.
    """
    return preview(config)["outcome"]


# --- Helpers ------------------------------------------------------------------


def _rng_for(config: dict[str, Any]) -> GodotRng:
    """The RNG for one duel: an explicitly handed stream wins (so a caller
    can continue the battle's single §4.11.1 stream), else a fresh generator
    seeded from ``seed``, else seed 0 (the oracle's warning path)."""
    shared = config.get("rng")
    if isinstance(shared, GodotRng):
        return shared
    rng = GodotRng()
    if "seed" in config:
        rng.seed = int(config.get("seed", 0))
    else:
        print("Duel: no `seed`/`rng` in config; using seed 0", file=sys.stderr)
        rng.seed = 0
    return rng


def _replay_rolls(state_before: int, player_rating: int,
                  defender_rating: int, count: int) -> list[dict[str, int]]:
    """Replays ``count`` rounds of :func:`resolve_duel`'s RNG consumption
    from a saved state to recover the individual rolls. The draw order
    (player, then defender; ``0..20`` each) and the ``+base`` are
    ``battle_sim``'s — reused from its constants; this function decides
    nothing about the outcome."""
    probe = GodotRng()
    probe.state = state_before
    rolls: list[dict[str, int]] = []
    for _index in range(max(count, 0)):
        player_roll = player_rating + probe.randi_range(0, DUEL_ROUND_MAX_ROLL)
        defender_roll = defender_rating + probe.randi_range(0, DUEL_ROUND_MAX_ROLL)
        rolls.append({"player": player_roll, "defender": defender_roll})
    return rolls
