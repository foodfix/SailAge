"""server.api.plans — pure screen-plan helpers shared by views and actions.

Two rules the oracle kept in the *screen* rather than an engine are ported
here, in one place, because both the M3 projection and the action adapter
consume them (a single source keeps the button state and the refusal from
disagreeing):

* :func:`fill_plan` — the Set-Sail prompt's **一键补满 / Auto-fill** plan
  (``scenes/port/provisions_dialog.gd`` static ``fill_plan``,
  ``docs/80-UI-UX.md`` §4.6.1 amended). Pure integer maths over the pooled
  supplies/hold/purse: the largest common target ``provisions = water = T``
  reachable by buying the shortfalls at the locked §4.10 prices and
  discarding the surplus above ``T``. The sim has no fill engine — the
  *execution* is the action adapter's, through the same two sim paths the
  row buttons use (``fleet.remove_supplies`` then ``trade.supplies_price``
  + ``fleet.add_supplies``).
* :data:`INFORM_COST` — the palace's fixed inform-on-pirates fee
  (``scripts/port/palace_engine.gd`` ``INFORM_COST``; ``docs/70-*`` §4.5,
  ``docs/80-*`` §4.11.1: the one ``500`` in the codebase, no rumour or
  charisma discount applies).
"""

from __future__ import annotations

from typing import Final

from server.sim.port import trade

__all__ = ["INFORM_COST", "fill_plan"]

#: The palace inform reveal price (palace_engine.gd ``INFORM_COST``).
INFORM_COST: Final[int] = 500


def fill_plan(provisions: int, water: int, free: int,
              gold: int) -> dict[str, int]:
    """The auto-fill plan (``provisions_dialog.gd`` ``fill_plan``, 80-*
    §4.6.1 amended) — pure integer maths, no state.

    Caps, over the pooled state ``P, W, free, gold``:

    * hold: ``buy_p + buy_w ≤ free + discarded`` collapses to
      ``T ≤ ⌊(free + P + W) / 2⌋`` in every buy/discard mix;
    * purse: ``2·buy_p + 1·buy_w ≤ gold`` — piecewise linear in ``T`` with
      breakpoints at ``min(P, W)`` (cost 0) and ``max(P, W)`` (cost
      ``smaller_kind_price × (max − min)``), slope ``2 + 1`` beyond.

    ``T = min(hold cap, gold cap)``; ``T ≥ min(P, W)`` always, so at most
    one kind is ever discarded (the larger one, and only when a cap sits
    below its stack). Returns ``{target, buy_provisions, buy_water,
    discard_provisions, discard_water, cost}`` — an all-zero plan means
    nothing to do.
    """
    smaller = min(provisions, water)
    larger = max(provisions, water)
    # The kind a below-`larger` target must buy is the currently smaller one.
    small_price = (trade.WATER_PRICE if provisions >= water
                   else trade.PROVISIONS_PRICE)
    p_price = trade.PROVISIONS_PRICE
    w_price = trade.WATER_PRICE
    cost_at_larger = small_price * (larger - smaller)
    if small_price <= 0 or p_price + w_price <= 0:
        return {"target": 0, "buy_provisions": 0, "buy_water": 0,
                "discard_provisions": 0, "discard_water": 0, "cost": 0}
    if gold >= cost_at_larger:
        gold_cap = larger + (gold - cost_at_larger) // (p_price + w_price)
    else:
        gold_cap = smaller + gold // small_price
    space_cap = (free + provisions + water) // 2
    target = min(gold_cap, space_cap)
    return {
        "target": target,
        "buy_provisions": max(0, target - provisions),
        "buy_water": max(0, target - water),
        "discard_provisions": max(0, provisions - target),
        "discard_water": max(0, water - target),
        "cost": p_price * max(0, target - provisions)
        + w_price * max(0, target - water),
    }
