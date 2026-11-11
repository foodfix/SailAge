"""M1 day-tick budget probe — the 318-fleet scenario (docs/IMPLEMENT-WebMigration.md M1).

Measures the full server day tick (the docs/90 §5.4 chain: sailing ledger →
economy drift → month boundary → day_advanced → ecology tick → quests →
captains) at the Phase-8 measured fleet count (318 fleets, the settled
``normal`` preset population). The M1 acceptance record takes its number
from this probe and amends the measured value into docs/90-ARCHITECTURE.md
§0.5 (the concrete-numbers rule).

Deterministic: fixed weather/mutiny seeds, a seeded ecology fill, and the
same real data tree. Supplies/wages are topped up each day so the run
cannot die mid-measurement (the ledger's fail states are not the subject).

Usage (from the repo root, with ``server/requirements.txt`` installed):

    python3 server/perf_day_tick.py [--days 40] [--warm 25] [--fleet 318]
"""

from __future__ import annotations

import argparse
import statistics
import time

from server.sim.data import data
from server.sim.state import GameState

ROLES = ("trader", "coaster", "patrol", "courier", "privateer", "pirate")


def _top_up(gs: GameState) -> None:
    """Keeps the run alive across the measurement window (not a rule)."""
    gs.gold = 1_000_000
    gs.morale = 100
    for ship in gs.fleet:
        ship["provisions"] = 999
        ship["water"] = 999
        ship["durability"] = max(int(ship.get("durability", 0)), 1)
    gs.player["autopilot"] = None


def _fill_to(gs: GameState, target: int) -> None:
    """Grows the ecology to the target count through its seeded spawn seam."""
    store = data()
    nations = [str(n.get("id", "")) for n in store.nations_list]
    eco = gs._ensure_ecology()
    index = 0
    while len(gs.npc_fleets) < target:
        role = ROLES[index % len(ROLES)]
        nation = "" if role in ("pirate", "coaster") else nations[index % len(nations)]
        eco.spawn(role, nation, int(gs.day))
        index += 1
        if index > target * 4:
            break  # no legal placement left; report the achieved count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=40)
    parser.add_argument("--warm", type=int, default=25)
    parser.add_argument("--fleet", type=int, default=318)
    args = parser.parse_args()

    gs = GameState().new_game("portugal", "background_deckhand",
                              {"constitution": 1}, {"navigation": 1})
    gs.weather_rng.seed = 12345
    gs.mutiny_rng.seed = 54321
    _fill_to(gs, args.fleet)

    for _ in range(args.warm):  # settle lanes/routes before timing
        _top_up(gs)
        gs.advance_day()

    samples: list[float] = []
    for _ in range(args.days):
        _top_up(gs)
        started = time.perf_counter()
        gs.advance_day()
        samples.append((time.perf_counter() - started) * 1000.0)

    samples.sort()
    p95 = samples[min(len(samples) - 1, int(len(samples) * 0.95))]
    print(f"fleets={len(gs.npc_fleets)} day={gs.day} days={args.days}")
    print(f"day_tick_ms mean={statistics.fmean(samples):.2f} "
          f"median={statistics.median(samples):.2f} "
          f"p95={p95:.2f} max={samples[-1]:.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
