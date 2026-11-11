"""server.sim.port.inn — the inn facility engine (M1).

Python port of ``scripts/port/inn_engine.gd`` (the frozen parity oracle
until the M6 cutover). Normative contract:

  * docs/30-PORTS-AND-TRADE.md §4.7 — "Rest 3 days" costs ``10g × 3 = 30g``
    charged **up front** (the button's advertised price is the total); the
    clock advances by exactly ``Δ = 10/3 − clock_fraction`` days, so the run
    wakes on **day + 3 at 08:00** whatever the arrival hour, and exactly
    **three** ledger days charge (wages still paid, supplies not — a docked
    ledger day consumes nothing, ``20-*`` §4.5) with the in-port morale delta
    (+5/day, cap 80, ``20-*`` §4.8.1). The inn is open 24h (§4.1b), so rest
    is offered at any hour.
  * docs/10-DATA-SCHEMA.md §5 — the harbor-relief anti-softlock constants:
    condition ``fleet empty AND no officers AND gold < 1200`` (the cheapest
    hull, ``latin``), action ``gold += 100`` and one ledger day, repeatable
    while the condition holds — from 0g exactly 12 odd jobs reach 1,200g.
  * docs/50-CHARACTER-AND-PROGRESSION.md §4.7/§6 — the full relief flow and
    the fixed disabled-reason keys (``inn.odd_job.has_ship`` /
    ``inn.odd_job.not_broke`` / ``inn.odd_job.officers``), reason order
    fixed: no ship first, then the purse, then the officer lockout.

**The daily ledger is not duplicated here.** Every day this module advances
runs through the sailing port's ledger (``SailingSim.advance_clock`` /
``advance_port_day`` — wages, weather, the in-port morale ``+5`` up to the
port cap 80, the §4.9 fail states), so rest never touches morale itself and
an odd job's only visible ledger effect is the day counter. That seam is
the injected ``advance_clock`` / ``advance_port_day`` callables (the
sailing-sim port wires the real ledger; without one the pure clock
arithmetic below lands the pinned wake point exactly).

Purity contract (M1, mirrors ``server/sim/port/trade.py``): **pure
functions over injected state** — no GameState autoload, no module state.
The purse is the caller's :class:`~server.sim.player.PersonState`
(``st``); the fleet is an injected list; the employed-officer check reuses
:func:`server.sim.player.character.officer_count`; the run clock is the
injected ``{"day", "clock_fraction"}`` dict (the ``GameState.world`` shape).

RNG-free: the oracle file has no ``rand*`` call (verified at port time).

Entry points ported (GDScript name → this module):
  * ``REST_DAYS`` / ``REST_COST_PER_DAY`` / ``REST_COST`` /
    ``REST_WAKE_DAYS`` / ``REST_WAKE_HOUR`` / ``ODD_JOB_GOLD`` /
    ``RELIEF_GOLD_THRESHOLD`` / ``REASON_HAS_SHIP`` / ``REASON_NOT_BROKE`` /
    ``REASON_OFFICERS`` — verbatim constants.
  * ``can_rest`` / ``rest`` / ``odd_job_eligible`` / ``ineligible_reason`` /
    ``work_odd_job`` — same names (state injected; ``rest`` returns the
    settlement block instead of a bare bool).

Deferred (NOT ported here, with the GDScript entry point):
  * ``talk`` / ``can_talk`` / ``reset_visit_guards`` (the Phase-8 W5-C
    受限谈话 +1 familiarity, once per port visit) — the familiarity
    mutation is the ``scripts/world/captains.gd`` module (not yet ported);
    the captains port owns the verb, this module only owned the guard.
  * The ledger's wage/morale/weather steps — the sailing-sim port (the
    injected hooks are its seam; the inn pins only the charge-then-advance
    ordering and the exact landing point).
"""

from __future__ import annotations

from typing import Any, Callable, Final

from server.sim.player import character
from server.sim.player import PersonState

#: The injected run-clock shape: the ``GameState.world`` dict (its
#: ``clock_fraction`` member; ``0.0`` when absent). ``GameState.day`` itself
#: is the ``PersonState.day`` mirror, so the day bookkeeping never forks.
WorldClock = dict[str, Any]

__all__ = [
    "REST_DAYS",
    "REST_COST_PER_DAY",
    "REST_COST",
    "REST_WAKE_DAYS",
    "REST_WAKE_HOUR",
    "ODD_JOB_GOLD",
    "RELIEF_GOLD_THRESHOLD",
    "REASON_HAS_SHIP",
    "REASON_NOT_BROKE",
    "REASON_OFFICERS",
    "RestResult",
    "can_rest",
    "rest",
    "odd_job_eligible",
    "ineligible_reason",
    "work_odd_job",
]

# --- Rest (docs/30-* §4.7) --------------------------------------------------

#: "Rest 3 days" — the fixed rest length.
REST_DAYS: Final[int] = 3
#: ``10g × 3 = 30g``: the per-day lodging price the button shows.
REST_COST_PER_DAY: Final[int] = 10
#: Total price charged in one go when the rest starts (``10g × 3``) —
#: **up front**, before the first ledger day (docs/30 §4.7).
REST_COST: Final[int] = REST_DAYS * REST_COST_PER_DAY
#: The rest's landing point (docs/30 §4.1b/§4.7, amended 2026-11-02): wake
#: on day + 3 at 08:00.
REST_WAKE_DAYS: Final[int] = 3
REST_WAKE_HOUR: Final[int] = 8

# --- Harbor relief (docs/10-* §5, docs/50-* §4.7) ---------------------------

#: Payout of one odd job (``gold += 100``).
ODD_JOB_GOLD: Final[int] = 100
#: Relief condition: the purse must be strictly below this — the cheapest
#: hull price (``latin``, 1,200g). Amended from 100: gating on
#: ``gold < 100`` while paying ``+100`` closes the gate after one job and
#: makes the 1,200g hull unreachable (docs/10 §5 "Why the threshold is
#: 1,200, not 100").
RELIEF_GOLD_THRESHOLD: Final[int] = 1200

#: Disabled-reason keys (docs/50 §4.7 step 3, §6). Reason order is fixed:
#: no ship first (the defining relief state), then the purse, then the
#: officer lockout.
REASON_HAS_SHIP: Final[str] = "inn.odd_job.has_ship"
REASON_NOT_BROKE: Final[str] = "inn.odd_job.not_broke"
REASON_OFFICERS: Final[str] = "inn.odd_job.officers"


class RestResult:
    """The settlement of one rest (docs/30 §4.7): the up-front lodging
    charge, the exact clock delta handed to the ledger, and the pinned wake
    point (day + 3 at 08:00)."""

    __slots__ = ("charged", "delta_days", "wake_day", "wake_hour")

    def __init__(self, charged: int, delta_days: float, wake_day: int,
                 wake_hour: int) -> None:
        self.charged = charged
        self.delta_days = delta_days
        self.wake_day = wake_day
        self.wake_hour = wake_hour

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, RestResult):
            return NotImplemented
        return (self.charged == other.charged
                and self.delta_days == other.delta_days
                and self.wake_day == other.wake_day
                and self.wake_hour == other.wake_hour)

    def __repr__(self) -> str:
        return (f"RestResult(charged={self.charged}, "
                f"delta_days={self.delta_days!r}, wake_day={self.wake_day}, "
                f"wake_hour={self.wake_hour})")


def can_rest(st: PersonState) -> bool:
    """True when the purse covers the whole ``10g × 3`` up-front price."""
    return st.gold >= REST_COST


def rest(st: PersonState, world: WorldClock,
         advance_clock: Callable[[float], None] | None = None,
         ) -> RestResult | None:
    """One "Rest 3 days" click (docs/30 §4.6/§4.7, §4.1b; amended
    2026-11-02):

      1. charge the 30g lodging **up front** (before any ledger day — the
         button's advertised price is the total);
      2. advance the clock by exactly ``Δ = 10/3 − clock_fraction`` days —
         whatever the arrival hour, the run wakes on **day + 3 at 08:00**
         (landing fraction 8/24), and the day-boundary crossings charge
         exactly **three** ledger days: wages ×3, in-port morale +5/day
         capped at 80, weather/fail-state steps included (the ledger is the
         sailing port's; ``advance_clock`` is its seam).

    ``world`` is the run's ``GameState.world`` mirror (read for
    ``clock_fraction``). Returns the :class:`RestResult`, or ``None``
    (state untouched: no gold, no day, no morale) when :func:`can_rest` is
    False. If the ledger ends the run mid-rest (a §4.9 game over) the
    sailing module freezes the clock on its own.
    """
    if not can_rest(st):
        return None
    st.gold -= REST_COST
    fraction = float(world.get("clock_fraction", 0.0))
    delta = REST_WAKE_DAYS + REST_WAKE_HOUR / 24.0 - fraction
    if advance_clock is not None:
        advance_clock(delta)
    else:
        # Pure-clock mirror of the pinned landing point: the §4.7 amendment
        # fixes the wake at day + 3, 08:00 from any arrival fraction (the
        # fp residue of ``f + (10/3 − f)`` is ~1e-16, absorbed by the
        # sailing module's CLOCK_EPSILON, so the third crossing is exact).
        st.day += REST_WAKE_DAYS
        world["clock_fraction"] = REST_WAKE_HOUR / 24.0
    return RestResult(
        charged=REST_COST,
        delta_days=delta,
        wake_day=st.day,
        wake_hour=REST_WAKE_HOUR,
    )


# --- Harbor relief (odd jobs; docs/10-* §5, docs/50-* §4.7) -----------------

def odd_job_eligible(fleet: list[Any], st: PersonState) -> bool:
    """docs/50 §4.7 step 1: ``fleet.is_empty() && officer_count() == 0 &&
    gold < 1200``, plus the §6 "officers employed" lockout ("odd jobs are
    disabled while officers are employed (dismiss first)"). Evaluated on
    inn open and after each job; this single implementation is what both
    call sites read, so the button and the engine can never disagree."""
    return ineligible_reason(fleet, st) == ""


def ineligible_reason(fleet: list[Any], st: PersonState) -> str:
    """``""`` when an odd job is available, else the specific
    disabled-reason key (fixed order: no ship, then the purse, then the
    officers)."""
    if fleet:
        return REASON_HAS_SHIP
    if st.gold >= RELIEF_GOLD_THRESHOLD:
        return REASON_NOT_BROKE
    if character.officer_count(st) > 0:
        return REASON_OFFICERS
    return ""


def work_odd_job(st: PersonState, fleet: list[Any],
                 advance_port_day: Callable[[], None] | None = None) -> bool:
    """One odd job (docs/10 §5, docs/50 §4.7 step 2): exactly
    ``gold += 100`` and exactly one ledger day. With no fleet there is no
    consumption, no crew and (by the lockout above) no officer wages, so
    the ledger's only visible effect is the day counter; the in-port ``+5``
    morale row still runs and is untouched here (§4.7: "morale +5 still
    applies but is moot").

    Returns False (state untouched) when :func:`odd_job_eligible` is False.
    The ledger day is the sailing port's seam (``advance_port_day``); the
    pure fallback advances the injected ``GameState.day`` mirror ``st.day``
    by exactly one."""
    if not odd_job_eligible(fleet, st):
        return False
    st.gold += ODD_JOB_GOLD
    if advance_port_day is not None:
        advance_port_day()
    else:
        st.day += 1
    return True
