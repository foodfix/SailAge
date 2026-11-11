"""server.api.views — the eight port-screen projections (M3).

Normative contract: ``docs/90-ARCHITECTURE.md`` §0.4 — *the
no-rules-in-TS channel*: ``GET /api/view/<screen_id>`` answers
``{"ok": true, "screen", "views"}`` where ``views`` is the server-computed
projection the screen renders. Prices, tax badges, gate reasons, facility
open/closed state, recruit lists, offers, permits and tournament state are
ALL computed here from the ported sim (``server/sim/**``); the TypeScript
client performs no rule math (90-§0.1 "server-authoritative").

The shape of each projection is owned by :mod:`web/src/state/views.ts`
(the single typed contract the eight screens import). Every field is a
verbatim read of an owning sim function — this module adds no game rule;
the few UI thresholds it does carry (morale/bar tiers, the intel-stance
gate, the inform price) are ports of the frozen oracle's screen
constants, cited inline.

Projections are pure reads: the composition helpers below deliberately use
``npc_intel.docked_fleets`` / ``is_present`` / ``facility_of`` instead of
``npc_intel.sightings`` so a view refresh never accrues captain
familiarity (the oracle's ``_port_sighting_rows`` does the same).
"""

from __future__ import annotations

from typing import Any, Final

from fastapi import APIRouter, Request

from server.sim import fleet as fleet_lib
from server.sim.data import DataStore
from server.sim.player import character, fame, skills
from server.sim.port import (
    allegiance,
    economy,
    inn,
    palace,
    shipyard,
    tavern,
    trade,
)
from server.sim.quests import bounty, quest_gen
from server.sim.world import discovery as discovery_lib
from server.sim.world import npc_fleets, npc_intel, sailing

__all__ = ["SCREENS", "project", "build_views_router"]

#: The frozen screen-projection ids (90-§0.4; the M3 screen set).
SCREENS: Final[tuple[str, ...]] = (
    "port", "market", "provisions", "shipyard",
    "inn", "guild", "palace", "tavern",
)

# --- Ported UI thresholds (frozen oracle screen constants) -------------------
#
# These are presentation thresholds, not game rules; each is the value the
# Godot screen carried verbatim (the oracle is the spec until the M6
# cutover). No new numbers are introduced.

#: Morale value_bar tiers (docs/80-* §4.8; inn_screen.gd / tavern_screen.gd).
MORALE_GOOD_MIN: Final[int] = 40
MORALE_WARN_MIN: Final[int] = 20
#: Days-of-supply readout tiers (docs/80-* §4.6.1; provisions_dialog.gd).
DAYS_GOOD_MIN: Final[int] = 10
DAYS_WARN_MIN: Final[int] = 3
DAYS_BAR_MAX: Final[int] = DAYS_GOOD_MIN
#: The market captain-intel free-lane stance gate (market_screen.gd).
INTEL_FREE_STANCE: Final[int] = 2
#: The palace inform-on-pirates price (palace_engine.gd ``INFORM_COST``,
#: docs/70-* §4.5) — a fixed 500g reveal.
INFORM_COST: Final[int] = 500


# --- Localization of composed text ------------------------------------------


def _t(store: DataStore, key: str) -> dict[str, str]:
    """The ``ui_strings`` L10nString for ``key`` (``{}`` when absent — the
    client renders the key loudly, 10-* §3.3)."""
    value = store.get_ui_string(key)
    return value if isinstance(value, dict) else {}


def _render(
    store: DataStore,
    key: str,
    values: dict[str, Any],
    locale: str,
) -> str:
    """Renders one ``ui_strings`` template in ``locale`` with
    ``{name}`` substitution (the web ``fmt`` contract, 90-§0.2)."""
    table = _t(store, key)
    text = str(table.get(locale, ""))
    for name, value in values.items():
        if isinstance(value, dict):
            rendered = str(value.get(locale, ""))
        else:
            rendered = str(value)
        text = text.replace("{%s}" % name, rendered)
    return text


def _fmt(store: DataStore, key: str, values: dict[str, Any]) -> dict[str, str]:
    """A composed L10nString: the same template rendered in both locales.

    Used only where a screen row's text mixes a template with localized
    content names (the rumor/inform/poster lines) — the client renders the
    pair through ``t()`` exactly like a content name."""
    if not values:
        return _t(store, key)
    return {"zh": _render(store, key, values, "zh"),
            "en": _render(store, key, values, "en")}


def _name(entry: dict[str, Any], key: str = "name") -> dict[str, str]:
    value = entry.get(key)
    return value if isinstance(value, dict) else {}


# --- Small shared reads -----------------------------------------------------


def _dev_of(session: Any):
    """The economy dev seam (allegiance-derived, docs/30 §4.9)."""
    def dev(port_id: str) -> int:
        return allegiance.dev(session.store, session.gs, port_id)
    return dev


def _stock(session: Any, port_id: str, good_id: str) -> int:
    return economy.stock_of(session.gs, session.store, port_id, good_id,
                            dev_of=_dev_of(session))


def _tariff_mille(session: Any, port_id: str) -> int:
    gs = session.gs
    base = allegiance.tariff_mille(
        session.store, gs, gs, gs.bounties, port_id,
        str(gs.player.get("nation_id", "")))
    return trade.tax_mille(
        base, skills.effective_skill(gs, session.store, "negotiation"))


def _alignment(session: Any, port_id: str) -> str:
    return allegiance.effective_alignment(session.store, session.gs, port_id)


def _player_nation(session: Any) -> str:
    return str(session.gs.player.get("nation_id", ""))


def _facility_open(session: Any, port_id: str, facility: str) -> bool:
    return sailing.facility_open(session.store, session.gs, port_id, facility)


def _morale_tier(morale: int) -> str:
    if morale >= MORALE_GOOD_MIN:
        return "good"
    if morale >= MORALE_WARN_MIN:
        return "warn"
    return "bad"


def _captain_row(session: Any, fleet: dict[str, Any], port_id: str,
                 facility: str) -> dict[str, Any]:
    """One captain sighting row (the oracle's ``_port_sighting_rows``
    composition, read-only)."""
    store = session.store
    captain_id = str(fleet.get("captain_id", ""))
    return {
        "id": str(fleet.get("id", "")),
        "captainId": captain_id,
        "name": npc_fleets.captain_name(fleet, None, store),
        "roleKey": "captain.role.%s" % str(fleet.get("role", "")),
        "tier": npc_fleets.captain_tier_of(fleet, store),
        "nationId": str(fleet.get("nation_id", "")),
        "lastSeenDay": npc_intel.arrival_day_of(fleet),
        "facility": facility,
    }


def _sightings(session: Any, port_id: str,
               facility: str | None) -> list[dict[str, Any]]:
    """Docked, present captain-bearing fleets (pure reads — no familiarity
    side effect, unlike ``npc_intel.sightings``)."""
    gs = session.gs
    out: list[dict[str, Any]] = []
    for fleet in npc_intel.docked_fleets(gs, port_id):
        if not npc_intel.is_present(fleet, port_id):
            continue
        if facility is not None and npc_intel.facility_of(
                fleet, port_id) != facility:
            continue
        if not str(fleet.get("captain_id", "")):
            continue
        out.append(_captain_row(session, fleet, port_id,
                                npc_intel.facility_of(fleet, port_id)))
    out.sort(key=lambda row: str(row.get("id", "")))
    return out


# --- The objective line (shared by guild + palace) --------------------------


def _objective(session: Any, quest: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """``(lineKey, lineValues)`` for an offer/instance (the client formats
    it; docs/80-* §4.7.4 ``quest.line.*`` frames, numbers composed by the
    UI). Mirrors ``quest_gen.objective_text`` for the wire."""
    store = session.store
    gs = session.gs
    requirements = quest.get("requirements", {})
    type_id = str(quest.get("type", ""))
    if type_id == quest_gen.TYPE_ROYAL:
        template = store.get_quest(str(quest.get("template_id", "")))
        objective = template.get("requirements", {}).get("objective", {})
        return "quest.line.royal", {"objective": _name(objective)}
    if type_id == quest_gen.TYPE_DELIVERY:
        return "quest.line.delivery", {
            "quantity": int(requirements.get("quantity", 0)),
            "good": _name(store.get_good(
                str(requirements.get("good_id", "")))),
            "port": _name(store.get_port(
                str(requirements.get("dest_port_id", "")))),
        }
    if type_id == quest_gen.TYPE_BOUNTY:
        target_id = str(requirements.get("target_fleet_id", ""))
        target: dict[str, str] = {}
        if target_id:
            for fleet in gs.npc_fleets:
                if isinstance(fleet, dict) \
                        and str(fleet.get("id", "")) == target_id:
                    target = npc_fleets.captain_name(fleet, None, store)
                    break
        if not isinstance(target, dict) or not target:
            target = _t(store, "encounter.pirate")
        return "quest.line.bounty", {
            "target": target,
            "tier": int(requirements.get("tier", 1)),
        }
    if type_id == quest_gen.TYPE_EXPLORATION:
        return "quest.line.exploration", {}
    return "ui.not_available", {}


def _reward_rep(quest: dict[str, Any]) -> int:
    rewards = quest.get("rewards", {})
    reputation = rewards.get("reputation", {})
    if not isinstance(reputation, dict):
        return 0
    return sum(int(value) for value in reputation.values()
               if isinstance(value, (int, float)) and not isinstance(value, bool))


def _commission(session: Any, offer: dict[str, Any]) -> dict[str, Any]:
    """One CommissionRow (guild offers / active quests)."""
    line_key, line_values = _objective(session, offer)
    rewards = offer.get("rewards", {})
    row: dict[str, Any] = {
        "id": str(offer.get("instance_id", "")),
        "type": str(offer.get("type", "")),
        "lineKey": line_key,
        "lineValues": line_values,
        "daysLeft": int(offer.get("expiry_days", 0)),
        "rewardGold": int(rewards.get("gold", 0)),
        "fame": int(rewards.get("fame", 0)),
        "rep": _reward_rep(offer),
        "canAccept": False,
    }
    if str(offer.get("type", "")) == quest_gen.TYPE_EXPLORATION:
        discovery_id = str(
            offer.get("requirements", {}).get("discovery_id", ""))
        if discovery_id:
            row["hintText"] = _name(
                session.store.get_discovery(discovery_id), "region_hint")
    return row


# --- Screen projections -----------------------------------------------------


def _port_view(session: Any, port_id: str) -> dict[str, Any]:
    store = session.store
    port = store.get_port(port_id)
    facilities = port.get("facilities", {})
    facilities = facilities if isinstance(facilities, dict) else {}
    rows: list[dict[str, Any]] = []
    for facility_id in ("market", "shipyard", "tavern", "inn", "guild",
                        "palace"):
        if facility_id not in facilities:
            continue
        phase = int(facilities.get(facility_id, 0) or 0) \
            if not isinstance(facilities.get(facility_id), list) else 1
        enabled = 1 <= phase <= 3
        bounty_closed = not bounty.can_open_facility(
            session.gs, port_id, facility_id)
        window = sailing.facility_window_text(store, port_id, facility_id)
        hours_open = _facility_open(session, port_id, facility_id)
        if bounty_closed:
            status = {"kind": "stub", "reasonKey": "port.closed_bounty"}
            enabled = False
        elif not enabled:
            status = {"kind": "stub", "reasonKey": "port.stub.phase3"}
        elif not window:
            # "24h" / a missing window: always open (facility_open is True).
            status = {"kind": "always"}
        elif hours_open:
            status = {"kind": "open", "open": window["open"],
                      "close": window["close"]}
        else:
            status = {"kind": "closed", "open": window["open"],
                      "close": window["close"]}
            enabled = False
        rows.append({"id": facility_id, "phase": phase,
                     "enabled": enabled, "status": status})
    return {
        "portId": port_id,
        "nationId": _alignment(session, port_id)
        or str(port.get("nation_id", "")),
        "facilities": rows,
    }


def _trend(session: Any, port_id: str, good_id: str) -> str:
    """The §4.7.7 flow-trend mark: ▲ refilling below the effective rest,
    ▼ draining above it, blank at rest (the oracle's ``effective_rest`` =
    production capacity / 0, economy.gd:635)."""
    gs = session.gs
    if economy.consumption_surged(gs, port_id, good_id):
        return "up"
    stock = _stock(session, port_id, good_id)
    if economy.is_produced_at(session.store, port_id, good_id):
        rest = economy.capacity_of(session.store, port_id, good_id,
                                   dev_of=_dev_of(session))
        return "up" if stock < rest else "down" if stock > rest else "flat"
    return "down" if stock > economy.STOCK_MIN else "flat"


def _exclusive_unlocked(session: Any, port_id: str) -> bool:
    """The 专营货 entitlement (docs/30 §4.8): dev ≥ 2 **and** the port's
    effective alignment is the player's nation."""
    player = _player_nation(session)
    if not player:
        return False
    if allegiance.dev(session.store, session.gs, port_id) < 2:
        return False
    return _alignment(session, port_id) == player


def _market_rows(session: Any, port_id: str) -> list[dict[str, Any]]:
    store = session.store
    gs = session.gs
    invested = trade.invested(gs.port_investments, port_id)
    produced = store.get_port(port_id).get("produces", [])
    exclusive_ok = _exclusive_unlocked(session, port_id)
    appraisal = skills.effective_skill(gs, store, "appraisal")
    listed: list[dict[str, Any]] = []
    for good in trade.goods_rows(port_id):
        good_id = str(good.get("id", ""))
        stock = _stock(session, port_id, good_id)
        specialty = good_id in produced
        listed.append({
            "goodId": good_id,
            "specialty": specialty,
            "notBought": not trade.port_buys_good(port_id, good_id),
            "exclusiveLocked": bool(good.get("exclusive", False))
            and not exclusive_ok,
            "_base": int(good.get("base_price", 0)),
            "_stock": stock,
            "_buy": trade.buy_price(port_id, good_id, stock,
                                    invested_gold=invested),
            "_sell": trade.sell_price(
                port_id, good_id, stock, invested_gold=invested,
                title_units=trade.title_units_from_bonus(
                    fame.title_bonus(
                        gs, str(store.get_port(port_id).get(
                            "nation_id", ""))))),
            "_trend": _trend(session, port_id, good_id),
            "_profit": trade.profit_arrow(
                port_id, good_id, stock=stock, invested_gold=invested,
                appraisal=appraisal),
        })
    # Display order (docs/80-§4.8, 2026-11-03 amendment): ★ specialty rows
    # first, then the rest; inside each group base_price ascending, ties by id.
    listed.sort(key=lambda row: (not row["specialty"], row["_base"],
                                 row["goodId"]))
    rows: list[dict[str, Any]] = []
    for row in listed:
        rows.append({
            "goodId": row["goodId"],
            "stock": row["_stock"],
            "trend": row["_trend"],
            "marginal": row["_buy"],
            "buyPrice": row["_buy"],
            "sellPrice": row["_sell"],
            "owned": fleet_lib.held(gs.fleet, row["goodId"]),
            "specialty": row["specialty"],
            "notBought": row["notBought"],
            "exclusiveLocked": row["exclusiveLocked"],
            "profitArrow": row["_profit"],
            "memoryArrow": "",
        })
    return rows


def _invest_gate(session: Any, port_id: str) -> dict[str, Any]:
    store = session.store
    gs = session.gs
    reason = allegiance.invest_block_reason(
        store, gs, gs, gs.bounties, port_id)
    if reason == "market.invest_gate.exhausted":
        return {"kind": "allowance"}
    if reason == "market.invest_gate.blocked":
        return {"kind": "blocked", "nationId": _alignment(session, port_id)}
    invested = trade.invested(gs.port_investments, port_id)
    if allegiance.is_protected(store, port_id) \
            and invested >= trade.INVEST_CAP_GOLD:
        return {"kind": "exhausted"}
    if gs.gold < trade.INVEST_CHUNK:
        return {"kind": "no_gold"}
    return {"kind": "ok"}


def _market_view(session: Any, port_id: str) -> dict[str, Any]:
    store = session.store
    gs = session.gs
    player = _player_nation(session)
    alignment = _alignment(session, port_id)
    mille = _tariff_mille(session, port_id)
    if mille == 0:
        badge = "exempt"
    elif mille == allegiance.TARIFF_ALIGNED or (
            player and alignment == player):
        badge = "in_sphere"
    elif not alignment:
        badge = "unallied"
    else:
        badge = "foreign"
    rows = _market_rows(session, port_id)
    invested = trade.invested(gs.port_investments, port_id)
    produced = [str(good) for good in store.get_port(port_id).get(
        "produces", [])]
    # Merchant captains (trader/treasure) sighted at the market — the
    # oracle's row filter, read-only.
    captains = [
        row for row in _sightings(session, port_id, npc_intel.FACILITY_MARKET)
        if row["roleKey"].endswith((".trader", ".treasure"))
    ]
    # Captain lane intel: every present captain at this port, deduped.
    intel: list[dict[str, Any]] = []
    seen: set[str] = set()
    for fleet in npc_intel.docked_fleets(gs, port_id):
        if not npc_intel.is_present(fleet, port_id):
            continue
        captain_id = str(fleet.get("captain_id", ""))
        if not captain_id or captain_id in seen:
            continue
        seen.add(captain_id)
        stance = int(gs.captain_states.get(captain_id, {}).get("stance", 0))
        dest = str(fleet.get("dest_port_id", ""))
        intel.append({
            "captainId": captain_id,
            "name": npc_fleets.captain_name(fleet, None, store),
            "roleKey": "captain.role.%s" % str(fleet.get("role", "")),
            "nationId": str(fleet.get("nation_id", "")),
            "free": stance >= INTEL_FREE_STANCE,
            "destPortId": dest,
        })
    free_port = next((row["destPortId"] for row in intel
                      if row["free"] and row["destPortId"]), None)
    fleet = gs.fleet
    hold_free = fleet_lib.fleet_free(fleet)
    hold_capacity = fleet_lib.fleet_capacity(fleet)
    return {
        "portId": port_id,
        "taxBadge": badge,
        "taxRatePct": mille // 100,
        "buyTariffGold": trade.tax_amount(
            mille, rows[0]["buyPrice"] if rows else 0),
        "sellTariffGold": trade.tax_amount(
            mille, rows[0]["sellPrice"] if rows else 0),
        "rows": rows,
        "specialtyGoodIds": produced,
        "investedGold": invested,
        "investedPct": trade.investment_percent(invested),
        "investCapPct": int(round(trade.DISCOUNT_CAP * 100.0)),
        "investAmount": int(trade.INVEST_CHUNK),
        "investGate": _invest_gate(session, port_id),
        "captains": captains,
        "holdUsed": hold_capacity - hold_free,
        "holdCapacity": hold_capacity,
        "holdFree": hold_free,
        "intel": intel,
        **({"freeIntelPortId": free_port} if free_port else {}),
    }


def _fill_plan(provisions: int, water: int, free: int,
               gold: int) -> dict[str, int]:
    """The auto-fill plan (`provisions_dialog.gd` ``fill_plan``, docs/80-*
    §4.6.1 amended) — pure integer maths, ported so the Set-Sail prompt's
    ``fillBlocked`` is server-computed (no rule math in TS)."""
    smaller = min(provisions, water)
    larger = max(provisions, water)
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


def _provisions_view(session: Any, port_id: str) -> dict[str, Any]:
    gs = session.gs
    fleet = gs.fleet
    provisions = fleet_lib.supplies(fleet, "provisions")
    water = fleet_lib.supplies(fleet, "water")
    free = fleet_lib.fleet_free(fleet)
    days = sailing.fleet_supply_days(gs)
    gate = sailing.supply_block_reason(gs)
    plan = _fill_plan(provisions, water, free, int(gs.gold))
    plan_empty = (plan["buy_provisions"] + plan["buy_water"]
                  + plan["discard_provisions"] + plan["discard_water"]) <= 0
    cargo: list[dict[str, Any]] = []
    totals: dict[str, int] = {}
    for ship in fleet:
        if not isinstance(ship, dict):
            continue
        goods = ship.get("cargo", {})
        if not isinstance(goods, dict):
            continue
        for good_id, qty in goods.items():
            amount = int(qty) if isinstance(qty, (int, float)) else 0
            if amount > 0:
                totals[str(good_id)] = totals.get(str(good_id), 0) + amount
    for good_id in sorted(totals):
        cargo.append({"goodId": good_id, "qty": totals[good_id]})
    view: dict[str, Any] = {
        "portId": port_id,
        "clock": sailing.clock_text(gs),
        "days": days,
        "daysBarMax": DAYS_BAR_MAX,
        "daysGoodMin": DAYS_GOOD_MIN,
        "daysWarnMin": DAYS_WARN_MIN,
        "provisions": {"qty": provisions,
                       "price": trade.supplies_price("provisions"),
                       "days": sailing.kind_supply_days(gs, "provisions")},
        "water": {"qty": water,
                  "price": trade.supplies_price("water"),
                  "days": sailing.kind_supply_days(gs, "water")},
        "holdUsed": fleet_lib.fleet_capacity(fleet) - free,
        "holdCapacity": fleet_lib.fleet_capacity(fleet),
        "holdFree": free,
        "cargo": cargo,
        "fillBlocked": plan_empty,
    }
    if 0 < days < DAYS_GOOD_MIN:
        view["shortWarningDays"] = days
    if gate:
        view["gateReasonKey"] = gate
    return view


def _equipment_slot(session: Any, port_id: str, slot: str,
                    ship_index: int) -> dict[str, Any]:
    """One equipment row (a slot of the player: ``ship_index`` -1, or of a
    hull): the worn item + every stocked item of that slot in this port."""
    gs = session.gs
    store = session.store
    if ship_index < 0:
        worn = shipyard.equipped_player(gs.player, slot)
        can_unequip = shipyard.can_unequip(gs.player, gs.fleet, slot, -1)
    else:
        worn = shipyard.equipped_ship(gs.fleet, ship_index, slot)
        can_unequip = shipyard.can_unequip(gs.player, gs.fleet, slot,
                                           ship_index)
    items: list[dict[str, Any]] = []
    for item in shipyard.equipment_list(slot, port_id):
        equipment_id = str(item.get("id", ""))
        reason = shipyard.equip_block_reason(
            gs.player, gs.fleet, slot, equipment_id, ship_index,
            current_port=port_id, gold=gs.gold,
            allegiance=session.allegiance_view)
        state = shipyard.row_state(port_id, equipment_id,
                                   session.allegiance_view)
        note_key = shipyard.row_note_key(port_id, equipment_id,
                                         session.allegiance_view)
        row: dict[str, Any] = {
            "equipmentId": equipment_id,
            "price": shipyard.equip_price(slot, equipment_id),
            "netCost": shipyard.equip_net_cost(
                gs.player, gs.fleet, slot, equipment_id, ship_index),
            "canBuy": not reason,
            "rowState": state,
        }
        if reason:
            row["reasonKey"] = reason
        if note_key:
            row["noteKey"] = note_key
            row["noteValues"] = {
                "dev": shipyard.effective_dev(port_id,
                                              session.allegiance_view)}
        items.append(row)
    return {
        "slot": slot,
        "shipIndex": ship_index,
        "worn": worn,
        "canUnequip": can_unequip,
        "items": items,
    }


def _shipyard_view(session: Any, port_id: str) -> dict[str, Any]:
    gs = session.gs
    store = session.store
    title_discount, carpenter = session._repair_factors(port_id)
    catalog: list[dict[str, Any]] = []
    for ship_type_id in shipyard.shipyard_stock(port_id):
        reason = shipyard.buy_block_reason(
            ship_type_id, current_port=port_id,
            fleet_size=len(gs.fleet), gold=gs.gold,
            allegiance=session.allegiance_view)
        note_key = shipyard.row_note_key(port_id, ship_type_id,
                                         session.allegiance_view)
        row: dict[str, Any] = {
            "shipTypeId": ship_type_id,
            "price": shipyard.buy_price(ship_type_id),
            "canBuy": not reason,
            "rowState": shipyard.row_state(port_id, ship_type_id,
                                           session.allegiance_view),
        }
        if reason:
            row["requirementKey"] = reason
            row["requirementValues"] = {
                "max": shipyard.FLEET_MAX,
                "dev": shipyard.effective_dev(port_id,
                                              session.allegiance_view),
            }
        if note_key:
            row["noteKey"] = note_key
            row["noteValues"] = {
                "dev": shipyard.effective_dev(port_id,
                                              session.allegiance_view)}
        catalog.append(row)
    fleet: list[dict[str, Any]] = []
    for index, ship in enumerate(gs.fleet):
        if not isinstance(ship, dict):
            continue
        ship_type_id = str(ship.get("ship_type_id", ""))
        max_durability = shipyard.ship_max_durability(gs.fleet, index)
        repair_reason = shipyard.repair_block_reason(
            gs.fleet, index, 1, gold=gs.gold,
            title_repair_discount=title_discount,
            carpenter_discount=carpenter)
        sell_reason = shipyard.sell_block_reason(gs.fleet, index)
        row = {
            "index": index,
            "shipTypeId": ship_type_id,
            "durability": int(ship.get("durability", 0)),
            "maxDurability": max_durability,
            "crew": int(ship.get("crew", 0)),
            "crewMax": fleet_lib.ship_stat(ship, "crew_max"),
            "cannons": int(ship.get("cannons", 0)),
            "slots": fleet_lib.ship_stat(ship, "armament_slots"),
            "cargoUsed": fleet_lib.used_capacity(ship),
            "cargoCapacity": fleet_lib.ship_stat(ship, "capacity"),
            "cargoFree": fleet_lib.free_capacity(ship),
            "canSell": not sell_reason,
            "sellPrice": shipyard.sell_price(gs.fleet, index),
            "canRepair": not repair_reason,
            "repairCostPerPoint": shipyard.repair_cost(
                gs.fleet, index, 1,
                title_repair_discount=title_discount,
                carpenter_discount=carpenter),
            "maxRepairPoints": shipyard.max_repair_points(gs.fleet, index),
            "maxRefit": shipyard.max_refit(gs.fleet, index),
        }
        if sell_reason:
            row["sellReasonKey"] = sell_reason
        if repair_reason:
            row["repairReasonKey"] = repair_reason
        fleet.append(row)
    equipment_slots = [
        _equipment_slot(session, port_id, slot, -1)
        for slot in shipyard.PLAYER_SLOTS
    ]
    for index in range(len(gs.fleet)):
        for slot in shipyard.SHIP_SLOTS:
            equipment_slots.append(
                _equipment_slot(session, port_id, slot, index))
    equipment = gs.player.get("equipment", {})
    equipment = equipment if isinstance(equipment, dict) else {}
    return {
        "portId": port_id,
        "catalog": catalog,
        "fleet": fleet,
        "equipment": {
            "weapon": str(equipment.get("weapon", "")),
            "armor": str(equipment.get("armor", "")),
        },
        "equipmentSlots": equipment_slots,
    }


def _officer_row(session: Any, officer_id: str) -> dict[str, Any]:
    store = session.store
    gs = session.gs
    officer = store.get_officer(officer_id)
    role = str(officer.get("role", ""))
    return {
        "officerId": officer_id,
        "roleKey": ("tavern.role.%s" % role) if role else "char.none",
        "wage": int(officer.get("wage_daily", 0)),
        "signingFee": character.recruit_cost(gs, store, officer_id),
        "skills": dict(officer.get("skills", {})),
        "canRecruit": character.can_recruit(gs, store, officer_id),
    }


def _tavern_view(session: Any, port_id: str) -> dict[str, Any]:
    gs = session.gs
    store = session.store
    fleet = gs.fleet
    open_now = _facility_open(session, port_id, "tavern")
    crew_count = tavern.crew(fleet)
    crew_max = tavern.crew_max(store, fleet)
    crew_min = tavern.crew_min(store, fleet)
    hire_cost = tavern.hire_cost(1)
    if crew_max <= 0:
        reason = ""
    elif tavern.max_hire(store, fleet) <= 0:
        reason = "tavern.crew_full"
    elif gs.gold < hire_cost:
        reason = "market.no_gold"
    else:
        reason = ""
    recruits = [_officer_row(session, officer_id)
                for officer_id in tavern.officers_at_port(store, gs, port_id)]
    roster: list[dict[str, Any]] = []
    for officer_id in character.employed_officers(gs):
        row = _officer_row(session, str(officer_id))
        row["canDismiss"] = True
        roster.append(row)
    # Rumors: discovery hints first (the purchasable rows), then the
    # npc_intel telegraph/traffic/fleet rows (informational, no purchase).
    rumor_rows: list[dict[str, Any]] = []
    for discovery_id in tavern.hints(store, gs.discoveries_found, port_id,
                                     int(gs.day)):
        rumor_rows.append({
            "id": discovery_id,
            "text": _name(store.get_discovery(discovery_id), "region_hint"),
            "known": tavern.is_hinted(gs.discovery_hints, discovery_id),
            "purchasable": True,
        })
    for row in npc_intel.rumor_rows(
            gs, port_id, economy=gs, allegiance=gs, person=gs,
            store=store):
        kind = str(row.get("kind", ""))
        if kind == "investment":
            continue  # rendered as an investment row below
        nation = _name(store.get_nation(str(row.get("nation_id", ""))))
        if kind == "event":
            text = _fmt(store, "captain.rumor.event", {
                "port": row.get("port_name", {}),
                "event": row.get("event_name", {}),
            })
        elif kind == "fleet":
            text = _fmt(store, "captain.rumor.fleet", {
                "nation": nation,
                "port": row.get("nearest_port_name", {}),
            })
        elif kind == "departed":
            text = _fmt(store, "captain.rumor.departed", {
                "nation": nation,
                "port": row.get("dest_port_name", {}),
            })
        elif kind == "arrived":
            text = _fmt(store, "captain.rumor.arrived", {"nation": nation})
        else:
            continue
        rumor_rows.append({
            "id": str(row.get("id", "")),
            "text": text,
            "known": True,
            "purchasable": False,
        })
    investments: list[dict[str, Any]] = []
    here_band = str(store.get_port(port_id).get("band", ""))
    for entry in allegiance.last_month_investments(gs, gs):
        if not isinstance(entry, dict):
            continue
        other = str(entry.get("port_id", ""))
        if str(store.get_port(other).get("band", "")) != here_band:
            continue
        investments.append({
            "nationId": str(entry.get("nation_id", "")),
            "amount": int(entry.get("amount", 0)),
            "portId": other,
        })
    spar_stake = tavern.SPAR_STAKE_MIN
    win_pct = int(round(tavern.spar_win_chance(
        skills.effective_skill(gs, store, "swordplay")) * 100.0))
    status = palace.status(store, gs, session.run_view, port_id,
                           int(gs.day),
                           bounty.is_port_closed(gs, port_id))
    tournament = _fmt(store, "tournament.status", {
        "port": _name(store.get_port(str(status.get("host", "")))),
        "first": int(status.get("window_first", 1)),
        "last": int(status.get("window_last", 5)),
    })
    return {
        "portId": port_id,
        "moraleTier": _morale_tier(int(gs.morale)),
        "moraleMax": sailing.MORALE_MAX,
        "captains": _sightings(session, port_id, npc_intel.FACILITY_TAVERN),
        "crew": {
            "count": crew_count,
            "max": crew_max,
            "min": crew_min,
            "morale": int(gs.morale),
            "perHead": tavern.per_head(),
            "hireCost": hire_cost,
            "canHire": tavern.can_hire(store, fleet, gs, 1)
            and open_now,
            "fillAvailable": tavern.fill_heads(store, fleet, int(gs.gold)) > 0
            and open_now,
            "canFire": tavern.min_fire(store, fleet) > 0 and open_now,
        },
        "recruitable": recruits,
        "roster": roster,
        "rumors": {
            "price": tavern.HINT_PRICE,
            "rows": rumor_rows,
            "tournament": tournament,
        },
        "investments": investments,
        "spar": {
            "stake": spar_stake,
            "step": tavern.SPAR_STAKE_STEP,
            "winPct": win_pct,
            "canSpar": tavern.can_spar(gs, spar_stake, open_now=open_now),
        },
    }


def _inn_view(session: Any, port_id: str) -> dict[str, Any]:
    gs = session.gs
    odd_reason = inn.ineligible_reason(gs.fleet, gs)
    return {
        "portId": port_id,
        "rest": {
            "days": inn.REST_DAYS,
            "price": inn.REST_COST,
            "canRest": inn.can_rest(gs),
        },
        "moraleTier": _morale_tier(int(gs.morale)),
        "moraleMax": sailing.MORALE_MAX,
        "oddJob": {
            "eligible": not odd_reason,
            "reasonKey": odd_reason,
        },
        "captains": _sightings(session, port_id, npc_intel.FACILITY_INN),
    }


def _guild_view(session: Any, port_id: str) -> dict[str, Any]:
    gs = session.gs
    store = session.store
    offers = quest_gen.available_offers(gs, port_id, int(gs.day),
                                        session.world_view)
    rows = []
    for offer in offers:
        row = _commission(session, offer)
        reason = quest_gen.accept_block_reason(gs, gs, offer, gs.fleet)
        row["canAccept"] = not reason
        if reason:
            row["reasonKey"] = reason
        rows.append(row)
    if rows:
        blocked_key = ""
    else:
        blocked_key = ("quest.slots_full"
                       if quest_gen.active_count(gs)
                       >= quest_gen.max_active_quests(gs) else "ui.empty")
    reports = []
    for discovery_id in discovery_lib.unreported(
            store, gs.discoveries_found, gs.discoveries_reported):
        entry = store.get_discovery(discovery_id)
        reports.append({
            "discoveryId": discovery_id,
            "rewardGold": int(entry.get("report_reward_gold", 0)),
            "fame": int(entry.get("fame", 0)),
        })
    active = []
    for quest in gs.active_quests:
        if not isinstance(quest, dict):
            continue
        row = _commission(session, quest)
        days_left = int(quest.get("deadline_day", 0)) - int(gs.day)
        row["daysLeft"] = max(0, days_left)
        row["status"] = str(quest.get("status", ""))
        active.append(row)
    status = palace.status(store, gs, session.run_view, port_id,
                           int(gs.day),
                           bounty.is_port_closed(gs, port_id))
    tournament = _fmt(store, "tournament.status", {
        "port": _name(store.get_port(str(status.get("host", "")))),
        "first": int(status.get("window_first", 1)),
        "last": int(status.get("window_last", 5)),
    })
    view: dict[str, Any] = {
        "portId": port_id,
        "offersRefreshDay": quest_gen.next_refresh_day(int(gs.day)),
        "offers": rows,
        "reports": reports,
        "active": active,
        "tournament": tournament,
        "offersBlockedKey": blocked_key,
    }
    return view


def _permit_row(session: Any, port_id: str, kind: str) -> dict[str, Any]:
    """One permit row (home / foreign) from the palace offer (docs/30
    §4.10; the oracle's ``_permit_state`` note precedence)."""
    gs = session.gs
    store = session.store
    offer = palace.permit_offer(store, gs, session.run_view, gs.permits,
                                port_id)
    if not offer or str(offer.get("kind", "")) != kind:
        # Not sold at this palace (the other kind): honest locked row.
        return {
            "price": palace.permit_price(
                store,
                skills.effective_skill(gs, store, "negotiation"), kind),
            "owned": False,
            "canBuy": False,
            "noteKey": "ui.not_available",
            "nationId": palace.nation_of(store, port_id),
        }
    owned = bool(offer.get("owned", False))
    void_key = str(offer.get("void_key", ""))
    title_locked = bool(offer.get("title_locked", False))
    rep_locked = bool(offer.get("rep_locked", False))
    price = int(offer.get("price", 0))
    can_buy = (not owned or bool(void_key)) and not title_locked \
        and not rep_locked and int(gs.gold) >= price
    if owned and not void_key:
        note_key = "palace.permit.%s.owned" % kind
    elif void_key:
        note_key = void_key
    elif title_locked:
        note_key = "palace.permit.title_locked"
    elif rep_locked:
        note_key = "palace.permit.rep_locked"
    else:
        note_key = str(offer.get("coverage_key", ""))
    return {
        "price": price,
        "owned": owned,
        "canBuy": can_buy,
        "noteKey": note_key,
        "nationId": str(offer.get("nation_id", "")),
    }


def _palace_view(session: Any, port_id: str) -> dict[str, Any]:
    gs = session.gs
    store = session.store
    nation_id = palace.nation_of(store, port_id)
    closed = bounty.is_port_closed(gs, port_id)
    can_pay_here = bounty.can_pay_here(gs, port_id)
    rank = fame.title(gs, nation_id) if nation_id else fame.RANK_NONE
    next_req = fame.next_requirements(gs, nation_id) if nation_id else {}
    view: dict[str, Any] = {
        "portId": port_id,
        "nationId": nation_id,
        "rank": rank,
        "ceremonyAvailable": bool(nation_id) and fame.can_promote(
            gs, nation_id),
        "repairAvailable": bool(nation_id),
        "permits": {
            "home": _permit_row(session, port_id, "home"),
            "foreign": _permit_row(session, port_id, "foreign"),
        },
        "board": _sightings(session, port_id, npc_intel.FACILITY_PALACE),
        "canRetire": bool(nation_id) and palace.can_retire(
            store, gs, port_id),
        "inform": [
            {
                "captainId": str(poster.get("captain_id", "")),
                "text": _fmt(store, "captain.poster.title", {
                    "name": poster.get("name", {}),
                    "tier": int(poster.get("tier", 1)),
                }),
                "cost": INFORM_COST,
                "canInform": not closed and int(gs.gold) >= INFORM_COST,
            }
            for poster in npc_intel.wanted_posters(gs, port_id, store=store)
        ],
    }
    if str(next_req.get("rank", "")):
        view["nextRank"] = {
            "rank": str(next_req.get("rank", "")),
            "fame": int(next_req.get("fame", 0)),
            "missions": int(next_req.get("missions", 0)),
        }
    discount = fame.repair_discount(gs, nation_id) if nation_id else 1.0
    if discount < 1.0:
        view["repairDiscountPct"] = int(round((1.0 - discount) * 100.0))
    active = palace.active_mission(session.run_view, store, nation_id) \
        if nation_id else {}
    if active:
        line_key, line_values = _objective(session, active)
        view["mission"] = {
            "objectiveKey": line_key,
            "objectiveValues": line_values,
            "daysLeft": max(0, int(active.get("deadline_day", 0))
                            - int(gs.day)),
            "canAccept": False,
            "active": True,
            "reasonKey": "palace.mission_active",
        }
    elif not palace.offers_missions(store, gs, port_id, closed,
                                    can_pay_here):
        if nation_id:
            view["missionRepLock"] = palace.MISSION_REPUTATION
    else:
        offer = palace.offer(
            store, gs, session.run_view, port_id, int(gs.day),
            delivery_stream=lambda p, d: quest_gen.offers(
                p, d, session.world_view, gs.discoveries_found),
            port_closed=closed, can_pay_here=can_pay_here)
        if offer:
            line_key, line_values = _objective(session, offer)
            reason = palace.open_block_reason(store, port_id, closed,
                                              can_pay_here)
            view["mission"] = {
                "objectiveKey": line_key,
                "objectiveValues": line_values,
                "daysLeft": int(offer.get("expiry_days", 0)),
                "canAccept": not reason,
                **({"reasonKey": reason} if reason else {}),
            }
    amount = bounty.amount(gs, nation_id) if nation_id else 0
    if amount > 0:
        view["bounty"] = {
            "amount": amount,
            "canPay": bounty.can_pay_off(gs, nation_id),
        }
    status = palace.status(store, gs, session.run_view, port_id,
                           int(gs.day), closed)
    entered = bool(status.get("entered", False))
    blocked = str(status.get("blocked", ""))
    tournament: dict[str, Any] = {
        "hostPortId": str(status.get("host", "")),
        "firstDay": int(status.get("window_first", 1)),
        "lastDay": int(status.get("window_last", 5)),
        "prizeGold": palace.PRIZE_GOLD,
        "fame": palace.PRIZE_FAME,
        "entered": entered,
        "canEnter": bool(status.get("open", False)) and not entered,
        "fee": int(status.get("fee", palace.ENTRY_FEE)),
    }
    if blocked and not entered:
        tournament["blockedKey"] = blocked
    view["tournament"] = tournament
    # Pending commendation (pull model; a read-only form of
    # palace.pending_commendation so a view refresh never pops the queue).
    player = _player_nation(session)
    if player and nation_id == player and gs.pending_commendations:
        flipped = str(gs.pending_commendations[0])
        if not gs.commendations_shown.get(flipped):
            view["commend"] = {"nationId": player, "portId": flipped}
    return view


def project(session: Any, screen_id: str) -> dict[str, Any]:
    """Builds the projection for ``screen_id`` (the docked port's data).

    ``session`` is the live :class:`server.session.Session`; every read is
    a sim query, never a local rule."""
    port_id = session.port_id()
    if screen_id == "port":
        return _port_view(session, port_id)
    if screen_id == "market":
        return _market_view(session, port_id)
    if screen_id == "provisions":
        return _provisions_view(session, port_id)
    if screen_id == "shipyard":
        return _shipyard_view(session, port_id)
    if screen_id == "inn":
        return _inn_view(session, port_id)
    if screen_id == "guild":
        return _guild_view(session, port_id)
    if screen_id == "palace":
        return _palace_view(session, port_id)
    if screen_id == "tavern":
        return _tavern_view(session, port_id)
    raise KeyError(screen_id)  # pragma: no cover - guarded by SCREENS


def build_views_router() -> APIRouter:
    """The screen-projection channel (90-§0.4): ``GET /api/view/<id>``."""
    router = APIRouter()

    @router.get("/view/{screen_id}")
    async def screen_view(screen_id: str, request: Request
                          ) -> dict[str, Any]:
        session = request.app.state.session  # type: ignore[no-any-return]
        return session.view(screen_id)

    return router
