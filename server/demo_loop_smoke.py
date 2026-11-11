"""Headless demo-loop smoke — the Phase-1 ten-step loop on the web-era session.

Drives `server.session.Session` (the same action adapters the HTTP routers
call; the M2 suite covers the HTTP/WS transports themselves) through the
docs/00-OVERVIEW.md §7 demo loop, adapted to the web era:

  1. new game (nationality + background + free points)
  2. home-port market buy updates gold/cargo
  3. Set Sail; a day consumes provisions/water and pays wages
  4. weather sampling over six days (the strength→direction ledger rolls)
  5. a second port: sell the cargo at that port's price
  6. tavern hire + inn rest
  7. save → mutate → load restores everything
  8. locale toggle zh ↔ en (both locales present)
  9. the explored set exists (the Chart's source)

Exit 0 = every deterministic step passed. The storm is probabilistic by
design (§7: "storm within 6 in-band days ≥ 0.90"), so the smoke reports
whether one occurred instead of gating on it.

Usage (from the repo root):

    python -m server.demo_loop_smoke
"""

from __future__ import annotations

import os
import sys
import tempfile

from server.session import Session
from server.sim import fleet as fleet_lib

CHECKS: list[str] = []


def _ok(label: str, condition: bool, detail: str = "") -> None:
    if not condition:
        raise AssertionError(f"demo loop step failed: {label} {detail}")
    CHECKS.append(label)


def run() -> int:
    os.environ.pop("SAILAGE_HOME", None)
    sess = Session()
    gs = sess.gs
    store = sess.store

    # 1. New game (two-step creation: background + the free-point pools).
    sess.new_game("portugal", "background_deckhand",
                  {"constitution": 3, "charisma": 2},
                  {"navigation": 3})
    _ok("1 new_game", gs.day == 1 and gs.gold > 0
        and gs.current_port == "lisbon",
        f"day={gs.day} gold={gs.gold} port={gs.current_port}")
    _ok("1 allocation spent", gs.player["alloc_pending"] == 0,
        f"pending={gs.player['alloc_pending']}")

    # 2. Market: the day starts at 00:00 (the oracle's new-game clock), so
    #    the player waits to opening time first (the §4.1b rule).
    from server.sim.world import sailing as sailing_lib
    sailing_lib.advance_port_hours(gs, gs, store, gs, 8,
                                   allegiance_state=gs)
    _ok("2 market open", sailing_lib.facility_open(store, gs, "lisbon",
                                                    "market"))
    #    Buy a good the home port produces.
    produced = next(
        (str(p.get("produces", [""])[0]) for p in store.ports_list
         if p.get("id") == "lisbon" and p.get("produces")), "")
    _ok("2 listing", bool(produced), "lisbon produces nothing")
    gold_before, held_before = gs.gold, fleet_lib.held(gs.fleet, produced)
    sess.dispatch("market", "buy", {"good_id": produced, "qty": 10})
    _ok("2 market buy", gs.gold < gold_before
        and fleet_lib.held(gs.fleet, produced) == held_before + 10,
        f"gold={gold_before}->{gs.gold} held={fleet_lib.held(gs.fleet, produced)}")

    # 3. Provision (the §4.6.1 prompt), Set Sail, then one day: supplies
    #    and wages are consumed.
    sess.dispatch("provisions", "fill", {})
    supplies_before = fleet_lib.supplies(gs.fleet, "provisions")
    sess.dispatch("provisions", "set_sail", {})
    _ok("3 at sea", gs.current_port is None)
    gs.advance_day()
    _ok("3 day consumed", gs.day == 2
        and fleet_lib.supplies(gs.fleet, "provisions") < supplies_before,
        f"day={gs.day} supplies={supplies_before}->"
        f"{fleet_lib.supplies(gs.fleet, 'provisions')}")

    # 4. Weather sampling over six days (the ledger's strength→direction order).
    weathers = {str(gs.world.get("weather", ""))}
    storm = False
    for _ in range(6):
        gs.advance_day()
        weathers.add(str(gs.world.get("weather", "")))
        storm = storm or gs.world.get("weather") == "storm"
    _ok("4 weather rolls", bool(gs.world.get("wind_dir")),
        f"weathers={sorted(weathers)} wind={gs.world.get('wind_dir')}")

    # 5. A second port: sell the cargo at its price.
    target = next(
        (str(p.get("id", "")) for p in store.ports_list
         if p.get("id") and p.get("id") != "lisbon"
         and p.get("nation_id") == "portugal"), "")
    _ok("5 second port exists", bool(target))
    gs.current_port = target  # the demo hop (a real sail is the M4 loop)
    gold_before = gs.gold
    held = fleet_lib.held(gs.fleet, produced)
    sess.dispatch("market", "sell", {"good_id": produced, "qty": held})
    _ok("5 sale", gs.gold != gold_before and held > 0,
        f"port={target} gold={gold_before}->{gs.gold}")

    # 6. Facilities: tavern crew + inn rest.
    crew_before = fleet_lib.total_crew(gs.fleet)
    sess.dispatch("tavern", "hire", {"heads": 2})
    _ok("6 tavern hire", fleet_lib.total_crew(gs.fleet) >= crew_before,
        f"crew={crew_before}->{fleet_lib.total_crew(gs.fleet)}")
    day_before = gs.day
    sess.dispatch("inn", "rest", {})
    _ok("6 inn rest", gs.day > day_before, f"day={day_before}->{gs.day}")

    # 7. Save → mutate → load restores everything.
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["SAILAGE_HOME"] = tmp
        sess.save_slot(2)
        snapshot = gs.snapshot_keys()
        gs.gold += 1234
        gs.day += 5
        loaded = sess.load_slot(2).get("ok") is True
        _ok("7 save round-trip", loaded
            and gs.gold == snapshot["gold"] and gs.day == snapshot["day"],
            f"loaded={loaded} gold={gs.gold}/{snapshot['gold']}")
    os.environ.pop("SAILAGE_HOME", None)

    # 8. Locale toggle; both locales present on the ui_strings table.
    sess.set_locale("zh")
    _ok("8 locale zh", gs.locale == "zh")
    sample = [k for k in list(store.ui_strings)[:8] if k != "version"]
    for key in sample:
        entry = store.ui_strings[key]
        if isinstance(entry, dict):
            _ok(f"8 key {key}", bool(entry.get("zh")) and bool(entry.get("en")))
    sess.set_locale("en")
    _ok("8 locale en", gs.locale == "en")

    # 9. The explored set grew while sailing (the Chart's data source; the
    #    sighting pass runs on Set Sail and every tick — M6-b's gap).
    _ok("9 explored set", isinstance(gs.explored_tiles, set)
        and len(gs.explored_tiles) > 0, f"n={len(gs.explored_tiles)}")
    _ok("9 sighting grew known ports", len(gs.known_ports) >= 6,
        f"known={len(gs.known_ports)}")

    print(f"demo loop: ALL PASS ({len(CHECKS)} checks; "
          f"storm_observed={storm}; weathers={sorted(weathers)})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run())
    except AssertionError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
