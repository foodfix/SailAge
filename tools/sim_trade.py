#!/usr/bin/env python3
"""sim_trade.py — the Phase-7 balance harness (task T, `IMPLEMENT-Phase7.md` §2.9).

Headless, stdlib-only, deterministic. Loads ``goods.json`` / ``ports.json`` /
``trade_routes_built.json`` (+ ``npc_config.json``, ``wind_regions.json``),
mirrors the docs-pinned integer economy of `30-PORTS-AND-TRADE.md` §4.2/§4.4
(factor-from-stock, tranche walk, band, 0.8 margin), §4.2's Phase-7 flow tick
(tier rates 5/3/2, capacities 160/140/120 + 20/dev ceiling 200, dev multiplier
``rate × (4 + dev) / 4``, initial stocks producers-at-capacity / consumers-60),
and §4.10's unified tariff (5% in-sphere / 20% foreign, applied after all price
math on the transaction totals), then runs the ten pinned gates:

  1  home-nation staple routes (5%/5% sphere tax): profit/day > 0 per starter ship
  2  foreign unpermitted routes: profit <= 60% of the permitted run
  3  monsoon-lane specialty routes (allied 5%): >= 1.2x the best home route
  4  no route exceeds 3x its pre-tax profit under the real tariff
  5  flow pacing: a 120-unit dump into a consumer recovers to within 10% in <= 30 days
  6  coaster damping: steady-state price gap >= 50% of the coasters-disabled gap
  7  greedy-bot ceiling: <= 80,000 g over 360 days
  8  diminishing returns: a 120-unit run < 2.2x a 60-unit run
  9  staple access: nearest staple producer <= 120 tiles (+ the furthest-staple ranking)
 10  producer health (NPCs active): steady-state producer stock >= 50% capacity

Every model choice not pinned by the docs is a deterministic approximation and
is documented inline at its site (the MODELING notes). Output is byte-stable:
no timestamps, no RNG, sorted iteration everywhere — two consecutive runs diff
empty.

Usage:

    python3 tools/sim_trade.py [--data-root PATH] [--gate N]… [--csv PATH]

``--data-root`` mirrors validate_data.py's override (staged-sim protocol);
``--gate N`` (1-10, repeatable) runs a subset. Exit 0 iff every requested gate
passes.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# --- docs-pinned constants (30-* §4.2/§4.4, §4.9/§4.10, 10-* §4.4/§7.2) ------

MAP_WIDTH = 4320
TILES_PER_DEGREE = 12.0  # 10-* §6.1 (4320 x 2160 at 12 tiles/degree)

STOCK_MIN = 0
STOCK_MAX = 200
FACTOR_BASE = 1500
FACTOR_PER_STOCK = 5
FACTOR_MIN = 500
FACTOR_MAX = 2000
TRANCHE_UNITS = 10
SELL_MARGIN_NUM = 8
SELL_MARGIN_DEN = 10

FLOW_TIER_RATES = {"staple": 5, "middle": 3, "luxury": 2}       # §4.2
FLOW_TIER_CAPACITIES = {"staple": 160, "middle": 140, "luxury": 120}
INITIAL_CONSUMER_STOCK = 60                                     # §4.2

TARIFF_ALIGNED_MILLE = 500    # §4.10: 5% — Allegiance.tariff_mille basis points
TARIFF_FOREIGN_MILLE = 2000   # §4.10: 20%
TARIFF_SCALE = 10_000         # 500/10000 = 5%, 2000/10000 = 20%

STAPLE_ACCESS_NEAR_TILES = 120   # decision 21
STAPLE_ACCESS_FAR_TILES = 240

# Gate thresholds (IMPLEMENT-Phase7.md §2.9).
GATE2_RATIO_MAX = 0.6
GATE3_MARGIN = 1.2
GATE4_MULTIPLE_MAX = 3.0
GATE5_RECOVERY_DAYS = 30
GATE5_WITHIN_FRACTION = 0.10
GATE6_GAP_FRACTION = 0.5
GATE7_BOT_CEILING = 80_000
GATE7_BOT_DAYS = 360
GATE8_RUN_RATIO_MAX = 2.2
GATE8_SCALED = int(GATE8_RUN_RATIO_MAX * 10)  # 22 — integer comparison ×10
GATE10_PRODUCER_HEALTH = 0.5

# §2.9 gate-5 dump: the canonical starter cargo (decision 22's run size).
GATE5_DUMP_UNITS = 120

# §2.7 coaster pins (60-* §4.11.14): <= 5 units/call, hold 10, saturation
# `qty <= 100 - stock` (== never sell into factor <= 1.0, factor 1000 at
# stock 100), staples ∪ middle scope.
COASTER_UNITS_PER_CALL = 5
COASTER_HOLD = 10
COASTER_SATURATION_STOCK = 100
COASTER_SPEED = 16                      # tiles/day (the slow §6.1 speed class)
COASTER_DWELL_DAYS = 2
COASTER_NEIGHBORS = 2                   # nearest-port hops per coaster

# §2.7 trader pins: <= 30 units of one good per call, hold 40, 2-day dwell.
TRADER_UNITS_PER_CALL = 30
TRADER_HOLD = 40
TRADER_DWELL_DAYS = 2
TRADER_SPEED = 16

NATIONS = ("portugal", "spain", "england", "holland", "ottoman", "italy")
# 10-* §7.4: each nation's new-game start ship — the gate-1 starter fleet
# (capacity in cargo units, speed in tiles/day).
STARTER_SHIPS = {
    "portugal": ("caravel", 120, 20),
    "spain": ("nao", 300, 16),
    "england": ("sloop", 60, 20),
    "holland": ("nao", 300, 16),
    "ottoman": ("galley", 50, 24),
    "italy": ("brigantine", 150, 24),
}

# Monsoon wind regions (data/wind_regions.json ids with the "monsoon"
# prefix) classify the §2.9 gate-3 lanes: a lane is a monsoon lane when any
# authored waypoint sits inside one of those polygons.
MONSOON_REGION_PREFIX = "monsoon"


# --- geometry (mirrors validate_data.py's §6.1 helpers) ----------------------

def tile_of(lat: float, lon: float) -> tuple[int, int]:
    x = int(math.floor((lon + 180.0) * TILES_PER_DEGREE)) % MAP_WIDTH
    y = int(math.floor((90.0 - lat) * TILES_PER_DEGREE))
    return x, min(max(y, 0), 2 * 1080 - 1)


def chebyshev(dx: int, dy: int) -> int:
    dx = abs(dx) % MAP_WIDTH
    return max(min(dx, MAP_WIDTH - dx), abs(dy))


def port_distance(a: dict, b: dict) -> int:
    ax, ay = a["tile"]
    bx, by = b["tile"]
    return chebyshev(bx - ax, by - ay)


def sailing_days(dist: int, speed: int) -> int:
    return max(1, -(-dist // speed))  # ceil, minimum 1 day


# --- exact price plumbing (30-* §4.2/§4.4 — integer per-thousand) ------------

def factor_units(stock: int) -> int:
    return max(FACTOR_MIN, min(FACTOR_MAX, FACTOR_BASE - FACTOR_PER_STOCK * stock))


def buy_price(base_price: int, stock: int) -> int:
    return max(1, (base_price * factor_units(stock)) // 1000)


def sell_price(base_price: int, stock: int) -> int:
    return max(1, (base_price * factor_units(stock)
                   * SELL_MARGIN_NUM * 1000) // (1000 * SELL_MARGIN_DEN * 1000))


def walk_buy(base_price: int, stock: int, qty: int) -> tuple[int, int]:
    """The §4.4 buy walk: `ceil(q/10)` tranches priced at stock-before.

    Returns (total, stock_after). Buying drains stock, floored at STOCK_MIN
    (a walk larger than the range parks at the bound and keeps transacting
    there, per §4.4)."""
    total = 0
    remaining = qty
    while remaining > 0:
        units = min(TRANCHE_UNITS, remaining)
        total += buy_price(base_price, stock) * units
        stock = max(STOCK_MIN, stock - units)
        remaining -= units
    return total, stock


def walk_sell(base_price: int, stock: int, qty: int) -> tuple[int, int]:
    """The §4.4 sell walk (0.8 margin). Returns (total, stock_after)."""
    total = 0
    remaining = qty
    while remaining > 0:
        units = min(TRANCHE_UNITS, remaining)
        total += sell_price(base_price, stock) * units
        stock = min(STOCK_MAX, stock + units)
        remaining -= units
    return total, stock


def taxed_buy(total: int, mille: int) -> int:
    """§4.10: the tariff composes AFTER all price math, on the totals.

    ``mille`` is the C-contract basis points (tariff_mille → 0/500/2000 over
    10,000: 5% / 20%), added on top of the buy cost."""
    return total + (total * mille) // TARIFF_SCALE


def taxed_sell(total: int, mille: int) -> int:
    return total - (total * mille) // TARIFF_SCALE


def run_profit(base_price: int, stock_a: int, stock_b: int, qty: int,
               mille_a: int, mille_b: int) -> int:
    """Net gold of a buy-at-A / sell-at-B run of `qty` units (pure; the
    caller decides whether to book the stock moves)."""
    buy_total, _ = walk_buy(base_price, stock_a, qty)
    sell_total, _ = walk_sell(base_price, stock_b, qty)
    return taxed_sell(sell_total, mille_b) - taxed_buy(buy_total, mille_a)


def run_qty_candidates(capacity: int, stock_a: int) -> list[int]:
    """Candidate run sizes: every full-tranche size up to the physical
    ceiling (hold capacity and stocked units). MODELING: the gates scan these
    and keep the argmax — a rational trader never overbuys past the
    profitable quantity (buying beyond stock parks at the factor floor and
    only loses money; the engine's Max picker walks the purse, the harness
    walks profit)."""
    ceiling = min(capacity, max(stock_a, 0))
    return list(range(TRANCHE_UNITS, ceiling + 1, TRANCHE_UNITS))


# --- world state -------------------------------------------------------------

class World:
    """The flow economy: per port-good stock, the §4.2 daily tick, and the
    new-game allegiance state (protected owner / contestable owner / neutral
    unallied)."""

    def __init__(self, goods: dict, ports: dict):
        self.goods = goods
        self.ports = ports
        self.port_ids = sorted(ports)
        self.stocks: dict[str, dict[str, int]] = {}
        self.alignment: dict[str, str] = {}
        self.coaster_scope: frozenset = frozenset()
        self.all_scope: frozenset = frozenset(goods)
        for pid, port in ports.items():
            self.alignment[pid] = ("" if port["neutral"] else port["nation_id"])

    # -- tier / rate / capacity (10-* §4.2 flags + §4.2 engine numbers) ------

    def tier_of(self, good_id: str) -> str:
        return self.goods[good_id]["tier"]

    def rate(self, good_id: str, side: str) -> int:
        flow = self.goods[good_id].get("flow")
        if flow:
            return int(flow[side])
        return FLOW_TIER_RATES[self.tier_of(good_id)]

    def capacity(self, port_id: str, good_id: str) -> int:
        flow = self.goods[good_id].get("flow")
        tier_cap = int(flow["capacity"]) if flow \
            else FLOW_TIER_CAPACITIES[self.tier_of(good_id)]
        return min(STOCK_MAX, tier_cap + 20 * self.ports[port_id]["dev"])

    # -- stocks --------------------------------------------------------------

    def seed_new_game(self) -> None:
        """§4.2 initial stocks: producers at capacity, consumers at 60."""
        self.stocks = {}
        for pid in self.port_ids:
            port = self.ports[pid]
            row = {}
            for good_id in sorted(port["produces"]):
                row[good_id] = self.capacity(pid, good_id)
            for good_id in sorted(port["demands"]):
                if good_id not in row:
                    row[good_id] = INITIAL_CONSUMER_STOCK
            self.stocks[pid] = row

    def snapshot(self) -> dict[str, dict[str, int]]:
        return {pid: dict(row) for pid, row in self.stocks.items()}

    def restore(self, snap: dict[str, dict[str, int]]) -> None:
        self.stocks = {pid: dict(row) for pid, row in snap.items()}

    def day_tick(self) -> int:
        """One §4.2 flow tick over every listed port-good. Returns the sum of
        |Δstock| (0 == the steady-state fixed point)."""
        delta = 0
        for pid in self.port_ids:
            port = self.ports[pid]
            dev = port["dev"]
            row = self.stocks.get(pid, {})
            for good_id in sorted(port["produces"]):
                rate = (self.rate(good_id, "prod") * (4 + dev)) // 4
                before = row.get(good_id, 0)
                after = min(self.capacity(pid, good_id), before + rate)
                row[good_id] = after
                delta += abs(after - before)
            for good_id in sorted(port["demands"]):
                if good_id in port["produces"]:
                    continue
                rate = (self.rate(good_id, "cons") * (4 + dev)) // 4
                before = row.get(good_id, 0)
                after = max(STOCK_MIN, before - rate)
                row[good_id] = after
                delta += abs(after - before)
            self.stocks[pid] = row
        return delta

    def converge(self, max_days: int = 400) -> int:
        """Tick to the flow fixed point (producers full, consumers drained).
        Returns the days used."""
        for day in range(1, max_days + 1):
            if self.day_tick() == 0:
                return day
        return max_days

    # -- tariff (§4.10; new-game allegiance — no permits) ---------------------

    def mille(self, port_id: str, trader_nation: str) -> int:
        owner = self.alignment[port_id]
        if owner and owner == trader_nation:
            return TARIFF_ALIGNED_MILLE
        return TARIFF_FOREIGN_MILLE


# --- NPC layers (MODELING: deterministic approximations of §2.7) ---------------

class NpcLayer:
    """Deterministic coaster/trader port calls.

    MODELING (documented approximations per the task brief):
    - A coaster pair makes one round of calls every
      ``max(1, ceil(dist/16) + 2)`` days (sail at the slow 16-tile class plus
      a 2-day dwell), phase-offset by the pair's index so the daily load
      spreads deterministically.
    - Each call moves the best-margin good in staples ∪ middle from the
      producing side to the demanding side, qty =
      ``min(5 units/call, hold 10, source stock, saturation 100 - stock)``,
      and never sells into factor <= 1.0 (destination stock >= 100). NPC
      margin selection ignores tax (gold-side only — decision 19; stocks do
      not see it).
    - Sovereign traders (gate 10) do the same on lane-adjacent pairs whose
      ends share a non-empty alignment, qty capped at 30 units/call, hold 40.
      Traders trade any produced→demanded good (the §2.7 docking rule is
      alignment-based; the lane `goods` tags gate nothing there).
    - NPC trades book stock only (the walk); treasuries are gold-side and
      never feed back into the flow economy.
    """

    def __init__(self, world: World, coaster_pairs: list, trader_pairs: list):
        self.world = world
        entries = []
        for index, (a, b, dist) in enumerate(coaster_pairs):
            cycle = max(1, sailing_days(dist, COASTER_SPEED) + COASTER_DWELL_DAYS)
            entries.append((index, "coaster", a, b, cycle))
        for index, (a, b, dist) in enumerate(trader_pairs):
            cycle = max(1, sailing_days(dist, TRADER_SPEED) + TRADER_DWELL_DAYS)
            entries.append((index, "trader", a, b, cycle))
        self.entries = sorted(entries, key=lambda row: (row[0], row[1]))

    def _hop(self, src: dict, dst: dict, qty_cap: int, hold: int,
             scope: frozenset) -> int:
        """One port call src → dst; returns the units moved."""
        world = self.world
        best_good = None
        best_qty = 0
        best_delta = 0
        for good_id in sorted(src["produces"]):
            if good_id not in scope:
                continue
            if good_id not in dst["demands"] or good_id in dst["produces"]:
                continue
            stock_src = world.stocks[src["id"]].get(good_id, 0)
            stock_dst = world.stocks[dst["id"]].get(good_id, 0)
            if stock_dst >= COASTER_SATURATION_STOCK:
                continue  # never sell into factor <= 1.0
            qty = min(qty_cap, hold, stock_src,
                      COASTER_SATURATION_STOCK - stock_dst)
            if qty <= 0:
                continue
            base = world.goods[good_id]["base_price"]
            delta = run_profit(base, stock_src, stock_dst, qty, 0, 0)
            if delta > best_delta:
                best_delta = delta
                best_qty = qty
                best_good = good_id
        if best_good is None:
            return 0
        base = world.goods[best_good]["base_price"]
        stock_src = world.stocks[src["id"]].get(best_good, 0)
        stock_dst = world.stocks[dst["id"]].get(best_good, 0)
        _, stock_src = walk_buy(base, stock_src, best_qty)
        _, stock_dst = walk_sell(base, stock_dst, best_qty)
        world.stocks[src["id"]][best_good] = stock_src
        world.stocks[dst["id"]][best_good] = stock_dst
        return best_qty

    def day_tick(self, day: int) -> int:
        moved = 0
        for index, kind, a, b, cycle in self.entries:
            if (day + index) % cycle != 0:
                continue
            if kind == "coaster":
                scope = self.world.coaster_scope
                moved += self._hop(a, b, COASTER_UNITS_PER_CALL, COASTER_HOLD,
                                   scope)
                moved += self._hop(b, a, COASTER_UNITS_PER_CALL, COASTER_HOLD,
                                   scope)
            else:
                moved += self._hop(a, b, TRADER_UNITS_PER_CALL, TRADER_HOLD,
                                   self.world.all_scope)
                moved += self._hop(b, a, TRADER_UNITS_PER_CALL, TRADER_HOLD,
                                   self.world.all_scope)
        return moved

    def converge(self, max_days: int = 600) -> int:
        """Flow + NPC ticks to the joint fixed point (or the cap)."""
        for day in range(1, max_days + 1):
            flow = self.world.day_tick()
            npc = self.day_tick(day)
            if flow == 0 and npc == 0:
                return day
        return max_days


# --- loading -----------------------------------------------------------------

def load_world(data_dir: Path):
    goods_doc = json.loads((data_dir / "goods.json").read_text(encoding="utf-8"))
    ports_doc = json.loads((data_dir / "ports.json").read_text(encoding="utf-8"))
    lanes_doc = json.loads(
        (data_dir / "trade_routes.json").read_text(encoding="utf-8"))
    wind_regions = json.loads(
        (data_dir / "wind_regions.json").read_text(encoding="utf-8"))["wind_regions"]

    goods: dict[str, dict] = {}
    for good in goods_doc["goods"]:
        if good.get("staple") is True:
            tier = "staple"
        elif good.get("specialty") is True:
            tier = "luxury"
        else:
            tier = "middle"
        goods[good["id"]] = {
            "id": good["id"],
            "base_price": int(good["base_price"]),
            "tier": tier,
            "specialty": good.get("specialty") is True,
            "flow": good.get("flow"),
        }
    ports: dict[str, dict] = {}
    for port in ports_doc["ports"]:
        ports[port["id"]] = {
            "id": port["id"],
            "nation_id": port["nation_id"],
            "neutral": port["nation_id"] == "",
            "tile": tile_of(port["lat"], port["lon"]),
            "produces": frozenset(port["produces"]),
            "demands": frozenset(port["demands"]),
            "band": port["band"],
            "dev": int(port["dev"]),
        }
    world = World(goods, ports)
    staples = frozenset(g for g in goods if goods[g]["tier"] == "staple")
    world.coaster_scope = frozenset(staples | frozenset(
        g for g in goods if goods[g]["tier"] == "middle"))  # decision 21
    return world, lanes_doc["lanes"], wind_regions, staples


def lane_adjacent_pairs(world: World, lanes: list):
    """MODELING: lane-adjacent port pairs from the authored lanes.

    A port is ON a lane when any authored waypoint snaps within the §6.1
    2-tile radius of the port's derived tile (the §4.14 port-touch rule).
    Ports ordered along the lane (by nearest-waypoint index, then id) form
    consecutive pairs; pairs dedupe across lanes (lanes sorted by id). The
    stored order is (min id, max id) — ADJACENCY is symmetric and every
    route evaluator walks BOTH directions (a lane carries trade each way)."""
    seen: set[tuple[str, str]] = set()
    meta: list[tuple[dict, dict, int, str]] = []
    for lane in sorted(lanes, key=lambda lane: lane["id"]):
        touches: list[tuple[int, str]] = []
        for windex, waypoint in enumerate(lane["waypoints"]):
            wx, wy = tile_of(float(waypoint[0]), float(waypoint[1]))
            for pid in world.port_ids:
                px, py = world.ports[pid]["tile"]
                if chebyshev(wx - px, wy - py) <= 2:
                    touches.append((windex, pid))
        touches.sort()
        ordered: list[str] = []
        for _windex, pid in touches:
            if pid not in ordered:
                ordered.append(pid)
        for left, right in zip(ordered, ordered[1:]):
            key = tuple(sorted((left, right)))
            if key in seen:
                continue
            seen.add(key)
            a = world.ports[key[0]]
            b = world.ports[key[1]]
            meta.append((a, b, port_distance(a, b), lane["id"]))
    return meta


def coaster_pairs(world: World):
    """MODELING: every port's ``COASTER_NEIGHBORS`` nearest ports (§2.7
    nearest-port hops regardless of ownership); the undirected union."""
    pair_set: set[tuple[str, str]] = set()
    for pid in world.port_ids:
        port = world.ports[pid]
        others = sorted(world.port_ids,
                        key=lambda other: (port_distance(port, world.ports[other]),
                                           other))
        for other in others[1:1 + COASTER_NEIGHBORS]:
            pair_set.add(tuple(sorted((pid, other))))
    pairs = []
    for left, right in sorted(pair_set):
        a = world.ports[left]
        b = world.ports[right]
        pairs.append((a, b, port_distance(a, b)))
    return pairs


def monsoon_lane_ids(lanes: list, wind_regions: list) -> set[str]:
    polygons = [region["polygon"] for region in wind_regions
                if region["id"].startswith(MONSOON_REGION_PREFIX)]
    result: set[str] = set()
    for lane in lanes:
        for waypoint in lane["waypoints"]:
            lat = float(waypoint[0])
            lon = float(waypoint[1])
            if any(_point_in_polygon(lat, lon, poly) for poly in polygons):
                result.add(lane["id"])
                break
    return result


def _point_in_polygon(lat: float, lon: float, polygon) -> bool:
    """Even-odd ray cast on the (lat, lon) ring. The shipped wind regions
    never straddle the antimeridian (each ring stays within one hemisphere
    west→east), so no longitude wrap handling is needed."""
    inside = False
    j = len(polygon) - 1
    for i in range(len(polygon)):
        lat_i = float(polygon[i][0])
        lon_i = float(polygon[i][1])
        lat_j = float(polygon[j][0])
        lon_j = float(polygon[j][1])
        if (lat_i > lat) != (lat_j > lat):
            slope = (lon_j - lon_i) / (lat_j - lat_i)
            if lon < lon_i + slope * (lat - lat_i):
                inside = not inside
        j = i
    return inside


# --- route helpers ------------------------------------------------------------

def best_route(world: World, a: dict, b: dict, good_ids: frozenset,
               capacity: int, trader: str):
    """The best (good, qty) run A → B over `good_ids` (produced at A,
    demanded and not produced at B), taxed per the trader's alignment.

    Returns (good_id, qty, profit) or None. Ties keep the smallest good id,
    then the smallest qty (deterministic)."""
    mille_a = world.mille(a["id"], trader)
    mille_b = world.mille(b["id"], trader)
    best = None
    for good_id in sorted(good_ids):
        if good_id not in a["produces"]:
            continue
        if good_id not in b["demands"] or good_id in b["produces"]:
            continue
        base = world.goods[good_id]["base_price"]
        stock_a = world.stocks[a["id"]].get(good_id, 0)
        stock_b = world.stocks[b["id"]].get(good_id, 0)
        for qty in run_qty_candidates(capacity, stock_a):
            profit = run_profit(base, stock_a, stock_b, qty, mille_a, mille_b)
            key = (-profit, good_id, qty)
            if best is None or key < best[0]:
                best = (key, good_id, qty, profit)
    if best is None or best[3] <= 0:
        return None
    return best[1], best[2], best[3]


def route_ppd(world: World, a: dict, b: dict, good_ids: frozenset,
              capacity: int, speed: int, trader: str):
    """(profit_per_day_num, profit_per_day_den, good, qty, profit, days) of
    the best run, or None. profit/day kept as an exact (profit, days) pair —
    floats appear only at print time."""
    found = best_route(world, a, b, good_ids, capacity, trader)
    if not found:
        return None
    good_id, qty, profit = found
    days = sailing_days(port_distance(a, b), speed)
    return profit, days, good_id, qty, profit, days


def best_route_either(world: World, a: dict, b: dict, good_ids: frozenset,
                      capacity: int, trader: str):
    """The better of the two directions of a lane pair (lanes carry trade
    each way). Returns (src, dst, good_id, qty, profit) or None; ties keep
    the lexicographically smaller source id, then good, then qty."""
    best = None
    for src, dst in ((a, b), (b, a)):
        found = best_route(world, src, dst, good_ids, capacity, trader)
        if not found:
            continue
        good_id, qty, profit = found
        key = (-profit, src["id"], good_id, qty)
        if best is None or key < best[0]:
            best = (key, src, dst, good_id, qty, profit)
    if best is None:
        return None
    return best[1], best[2], best[3], best[4], best[5]


# --- report helpers ------------------------------------------------------------

def fmt(value: float) -> str:
    """Fixed-width float printing — byte-stable across runs/platforms."""
    return f"{value:.3f}"


def ppd(num: int, den: int) -> float:
    return num / den if den else 0.0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Phase-7 balance harness: the §2.9 gates 1-10.")
    parser.add_argument("--data-root", default=None,
                        help="checkout root or data/ dir to simulate "
                             "(default: this repo's data/)")
    parser.add_argument("--gate", action="append", type=int, default=[],
                        help="run only these gates (repeatable, 1-10)")
    parser.add_argument("--csv", default=None,
                        help="also write the profit/day CSV to PATH")
    args = parser.parse_args(argv)

    raw = args.data_root or os.environ.get("SAILAGE_DATA_ROOT") or ""
    if raw:
        path = Path(raw).expanduser()
        if not path.is_absolute():
            path = (Path.cwd() / path).resolve()
        data_dir = path if (path.name == "data"
                            or (path / "ports.json").is_file()) \
            else path / "data"
    else:
        data_dir = REPO_ROOT / "data"

    gates = set(args.gate) or set(range(1, 11))
    lines: list[str] = []
    out = lines.append

    world, lanes, wind_regions, staples = load_world(data_dir)
    lane_meta = lane_adjacent_pairs(world, lanes)
    lane_pairs = [(a, b, dist) for (a, b, dist, _lane) in lane_meta]
    coaster_pair_list = coaster_pairs(world)
    trader_pair_list = [(a, b, dist) for (a, b, dist, _lane) in lane_meta
                        if a["nation_id"] == b["nation_id"]
                        and not a["neutral"]]
    monsoon_ids = monsoon_lane_ids(lanes, wind_regions)
    monsoon_pairs = [(a, b, dist) for (a, b, dist, lane) in lane_meta
                     if lane in monsoon_ids]

    out("sim_trade report (task T, IMPLEMENT-Phase7 §2.9)")
    out(f"data_root: {data_dir}")
    out(f"ports: {len(world.ports)}  goods: {len(world.goods)}  "
        f"lanes: {len(lanes)}  lane_pairs: {len(lane_pairs)}  "
        f"coaster_pairs: {len(coaster_pair_list)}  "
        f"trader_pairs: {len(trader_pair_list)}")
    out("monsoon_lanes: " + (", ".join(sorted(monsoon_ids)) or "(none)"))

    # -- §4.4/§5 price-plumbing parity (double-implementation drift guard) --
    # The Phase-7 tariff composes after this plumbing, and 30-* §5 keeps the
    # worked examples' arithmetic normative: Lisbon buy at factor 700 = 21g,
    # London sell at factor 1300 = 31g, baron title = 34g.
    parity = (buy_price(30, 160) == 21
              and sell_price(30, 40) == 31
              and max(1, (30 * factor_units(40) * SELL_MARGIN_NUM * 1100)
                      // (1000 * SELL_MARGIN_DEN * 1000)) == 34
              and taxed_sell(1000, TARIFF_ALIGNED_MILLE) == 950
              and taxed_buy(1000, TARIFF_FOREIGN_MILLE) == 1200
              and taxed_sell(3490, TARIFF_FOREIGN_MILLE) == 2792)
    out(f"price-plumbing parity vs 30-* §5 worked examples: "
        f"{'PASS' if parity else 'FAIL'}")

    # -- the pure flow steady state: the canonical measurement point --------
    world.seed_new_game()
    steady_days = world.converge()
    out(f"flow steady state: converged in {steady_days} days "
        "(producers at capacity, consumers drained)")

    gate_results: list[tuple[int, bool, str]] = []
    csv_rows: list[str] = []

    # ======================================================================
    # Gate 1 — home-nation staple routes with the 5%/5% sphere tax
    # ======================================================================
    if 1 in gates:
        out("")
        out("gate 1: home staple routes, 5%/5% sphere tax — profit/day > 0 "
            "for every starter ship")
        gate_ok = True
        for nation in NATIONS:
            ship, capacity, speed = STARTER_SHIPS[nation]
            best = None
            for (a, b, _dist) in sorted(lane_pairs + home_pairs(world),
                                        key=lambda p: (p[0]["id"], p[1]["id"])):
                if world.alignment[a["id"]] != nation \
                        or world.alignment[b["id"]] != nation:
                    continue
                for src, dst in ((a, b), (b, a)):
                    found = route_ppd(world, src, dst, staples, capacity,
                                      speed, nation)
                    if found and (best is None
                                  or (found[0], found[2], found[3])
                                  > (best[0], best[2], best[3])):
                        best = found
            if best is None:
                gate_ok = False
                out(f"  {nation:9s} {ship:10s}: NO profitable home staple "
                    "route  [FAIL]")
                continue
            num, den, good_id, qty, profit, day_s = best
            ok = num > 0
            gate_ok = gate_ok and ok
            out(f"  {nation:9s} {ship:10s}: {profit}g / {day_s}d = "
                f"{fmt(ppd(num, den))} g/day ({good_id} q{qty})  "
                f"[{'ok' if ok else 'FAIL'}]")
            csv_rows.append(f"gate1,{nation},{good_id},{qty},{profit},{day_s},"
                            f"{fmt(ppd(num, den))}")
        gate_results.append((1, gate_ok, "profit/day > 0 per starter ship"))

    # ======================================================================
    # Gate 2 — foreign unpermitted routes <= 60% of the permitted run
    # ======================================================================
    if 2 in gates:
        verdict = gate_foreign_tax(world, lane_pairs, out, csv_rows,
                                   ratio_cap=GATE2_RATIO_MAX, label="gate 2")
        gate_results.append((2, verdict[0], verdict[1]))

    # ======================================================================
    # Gate 3 — monsoon specialty routes >= 1.2x the best home route
    # ======================================================================
    if 3 in gates:
        out("")
        out(f"gate 3: monsoon-lane specialty routes (allied 5%/5%) >= "
            f"{GATE3_MARGIN}x the best home route of equal distance")
        gate_ok = True
        home_best: dict[int, int] = {}
        for nation in NATIONS:
            _ship, capacity, speed = STARTER_SHIPS[nation]
            for (a, b, _dist) in sorted(lane_pairs + home_pairs(world),
                                        key=lambda p: (p[0]["id"], p[1]["id"])):
                if world.alignment[a["id"]] != nation \
                        or world.alignment[b["id"]] != nation:
                    continue
                for src, dst in ((a, b), (b, a)):
                    found = route_ppd(world, src, dst, staples, capacity,
                                      speed, nation)
                    if not found:
                        continue
                    num, den, _g, _q, _p, day_s = found
                    scaled = num * 1000 // den
                    home_best[day_s] = max(home_best.get(day_s, 0), scaled)
        global_best = max(home_best.values()) if home_best else 0
        specialty_ids = frozenset(g for g in world.goods
                                  if world.goods[g]["specialty"])
        measured = 0
        worst = None
        for (a, b, _dist) in sorted(monsoon_pairs,
                                    key=lambda p: (p[0]["id"], p[1]["id"])):
            trader = world.alignment[a["id"]]
            if not trader or world.alignment[b["id"]] != trader:
                continue  # the allied 5%/5% scenario
            _ship, capacity, speed = STARTER_SHIPS.get(
                trader, ("caravel", 120, 20))
            for src, dst in ((a, b), (b, a)):
                found = route_ppd(world, src, dst, specialty_ids, capacity,
                                  speed, trader)
                if not found:
                    continue
                num, den, good_id, qty, profit, day_s = found
                measured += 1
                baseline = home_best.get(day_s, global_best)
                mine = num * 1000 // den
                if baseline <= 0:
                    gate_ok = False
                    out(f"  VIOLATION {src['id']} -> {dst['id']} {good_id}: "
                        "no home baseline for the day bucket")
                    continue
                ratio_x1000 = mine * 1000 // baseline
                if worst is None or ratio_x1000 < worst[0]:
                    worst = (ratio_x1000, src["id"], dst["id"], good_id, qty,
                             mine, baseline)
                if ratio_x1000 < int(GATE3_MARGIN * 1000):
                    gate_ok = False
                    out(f"  VIOLATION {src['id']} -> {dst['id']} {good_id} "
                        f"q{qty}: {fmt(ppd(num, den))} g/day vs home baseline "
                        f"{fmt(ppd(baseline, 1000))} = "
                        f"{fmt(ratio_x1000 / 1000)}x")
        if worst:
            verdict = "ok" if gate_ok else "FAIL"
            out(f"  {measured} allied specialty routes on monsoon lanes; "
                f"worst ratio {fmt(worst[0] / 1000)}x at {worst[1]} -> "
                f"{worst[2]} {worst[3]} q{worst[4]} "
                f"({fmt(ppd(worst[5], 1000))} vs {fmt(ppd(worst[6], 1000))} "
                f"g/day)  [{verdict}]")
        else:
            out("  no allied specialty routes on monsoon lanes  [FAIL]")
            gate_ok = False
        gate_results.append((3, gate_ok, f">= {GATE3_MARGIN}x baseline"))

    # ======================================================================
    # Gate 4 — no route exceeds 3x its pre-tax profit
    # ======================================================================
    if 4 in gates:
        verdict = gate_foreign_tax(world, lane_pairs, out, csv_rows,
                                   ratio_cap=GATE4_MULTIPLE_MAX, label="gate 4",
                                   collect_csv=False)
        gate_results.append((4, verdict[0], verdict[1]))

    # ======================================================================
    # Gate 5 — flow pacing
    # ======================================================================
    if 5 in gates:
        out("")
        out(f"gate 5: flow pacing — a {GATE5_DUMP_UNITS}-unit dump into a "
            f"consumer recovers to within "
            f"{fmt(GATE5_WITHIN_FRACTION)} of steady state in <= "
            f"{GATE5_RECOVERY_DAYS} days")
        gate_ok = True
        worst = None
        recovery_rows: list[str] = []
        snap = world.snapshot()
        target_factor = int(FACTOR_BASE * (1.0 - GATE5_WITHIN_FRACTION))
        for pid in world.port_ids:
            port = world.ports[pid]
            for good_id in sorted(port["demands"]):
                if good_id in port["produces"]:
                    continue
                steady = world.stocks[pid].get(good_id, 0)
                steady_factor = factor_units(steady)
                world.stocks[pid][good_id] = min(
                    STOCK_MAX, steady + GATE5_DUMP_UNITS)
                recovered_day = None
                for day in range(1, 2 * GATE5_RECOVERY_DAYS):
                    world.day_tick()
                    if factor_units(world.stocks[pid].get(good_id, 0)) \
                            >= min(steady_factor, target_factor):
                        recovered_day = day
                        break
                if recovered_day is None:
                    gate_ok = False
                    out(f"  VIOLATION {pid} {good_id}: no recovery within "
                        f"{2 * GATE5_RECOVERY_DAYS - 1} days")
                    continue
                rate = world.rate(good_id, "cons")
                recovery_rows.append(
                    f"{pid},{good_id},{world.goods[good_id]['tier']},"
                    f"{rate},{recovered_day}")
                if worst is None or recovered_day > worst[0]:
                    worst = (recovered_day, pid, good_id, rate)
                if recovered_day > GATE5_RECOVERY_DAYS:
                    gate_ok = False
        world.restore(snap)
        if worst:
            verdict = "ok" if gate_ok else "FAIL"
            out(f"  {len(recovery_rows)} consumer port-goods dumped; worst "
                f"recovery {worst[0]} days ({worst[1]} {worst[2]}, rate "
                f"{worst[3]}/day)  [{verdict}]")
            for row in sorted(recovery_rows)[:20]:
                out(f"    {row}")
            out(f"    … {len(recovery_rows)} rows total (first 20 shown)")
        else:
            out("  no consumer port-goods to dump  [FAIL]")
            gate_ok = False
        gate_results.append((5, gate_ok, f"recovery <= {GATE5_RECOVERY_DAYS}d"))

    # ======================================================================
    # Gate 6 — coaster damping
    # ======================================================================
    if 6 in gates:
        out("")
        out(f"gate 6: coaster damping — steady-state price gap >= "
            f"{fmt(GATE6_GAP_FRACTION)} of the coasters-disabled gap")
        gate_ok = True
        gaps_disabled = measured_gaps(world, coaster_pair_list)
        snap = world.snapshot()
        world.seed_new_game()
        NpcLayer(world, coaster_pair_list, []).converge()
        gaps_enabled = measured_gaps(world, coaster_pair_list)
        world.restore(snap)
        worst = None
        measured = 0
        for key in sorted(gaps_disabled):
            disabled = gaps_disabled[key]
            enabled = gaps_enabled.get(key, 0)
            if disabled <= 0:
                continue
            measured += 1
            ratio_x1000 = enabled * 1000 // disabled
            if worst is None or ratio_x1000 < worst[0]:
                worst = (ratio_x1000, key, enabled, disabled)
            if ratio_x1000 < int(GATE6_GAP_FRACTION * 1000):
                gate_ok = False
                out(f"  VIOLATION {key[1]} -> {key[2]} {key[0]}: gap "
                    f"{enabled} vs disabled {disabled} = "
                    f"{fmt(ratio_x1000 / 1000)}")
        if worst:
            verdict = "ok" if gate_ok else "FAIL"
            out(f"  {measured} scoped producer→consumer gaps measured; worst "
                f"ratio {fmt(worst[0] / 1000)} at {worst[1][1]} -> "
                f"{worst[1][2]} {worst[1][0]} "
                f"({worst[2]} vs {worst[3]})  [{verdict}]")
        else:
            out("  no measurable gaps in the coaster scope  [FAIL]")
            gate_ok = False
        gate_results.append((6, gate_ok,
                             f"gap >= {fmt(GATE6_GAP_FRACTION)} of disabled"))

    # ======================================================================
    # Gate 7 — greedy-bot ceiling
    # ======================================================================
    if 7 in gates:
        out("")
        out(f"gate 7: greedy-bot ceiling — optimal-greedy <= "
            f"{GATE7_BOT_CEILING}g over {GATE7_BOT_DAYS} days")
        total, trace = greedy_bot(world, lane_pairs, GATE7_BOT_DAYS)
        gate_ok = total <= GATE7_BOT_CEILING
        verdict = "ok" if gate_ok else "FAIL"
        out(f"  bot (portugal, caravel, 5000g start): net {total}g over "
            f"{GATE7_BOT_DAYS} days, {len(trace)} runs  [{verdict}]")
        for row in trace[:10]:
            out(f"    day {row[0]:3d} {row[1]} -> {row[2]} {row[3]} "
                f"q{row[4]:3d} profit {row[5]:5d}g purse {row[6]}g")
        out(f"    … {len(trace)} runs total (first 10 shown)")
        gate_results.append((7, gate_ok, f"<= {GATE7_BOT_CEILING}g"))

    # ======================================================================
    # Gate 8 — diminishing returns
    # ======================================================================
    if 8 in gates:
        out("")
        out("gate 8: diminishing returns — a 120-unit run < "
            f"{GATE8_RUN_RATIO_MAX}x a 60-unit run")
        gate_ok = True
        measured = 0
        worst = None
        for (a, b, _dist) in sorted(lane_pairs,
                                    key=lambda p: (p[0]["id"], p[1]["id"])):
            trader = world.alignment[a["id"]] or world.alignment[b["id"]]
            if not trader:
                continue
            for src, dst in ((a, b), (b, a)):
                mille_src = world.mille(src["id"], trader)
                mille_dst = world.mille(dst["id"], trader)
                for good_id in sorted(src["produces"]):
                    if good_id not in dst["demands"] \
                            or good_id in dst["produces"]:
                        continue
                    base = world.goods[good_id]["base_price"]
                    stock_a = world.stocks[src["id"]].get(good_id, 0)
                    if stock_a < 60:
                        continue
                    stock_b = world.stocks[dst["id"]].get(good_id, 0)
                    big = run_profit(base, stock_a, stock_b, 120, mille_src,
                                     mille_dst)
                    small = run_profit(base, stock_a, stock_b, 60, mille_src,
                                       mille_dst)
                    if small <= 0:
                        continue
                    measured += 1
                    ratio_x10 = big * 10 // small
                    if worst is None or ratio_x10 > worst[0]:
                        worst = (ratio_x10, src["id"], dst["id"], good_id,
                                 big, small)
                    if ratio_x10 >= GATE8_SCALED:
                        gate_ok = False
                        out(f"  VIOLATION {src['id']} -> {dst['id']} "
                            f"{good_id}: 120-unit profit {big}g >= "
                            f"{GATE8_RUN_RATIO_MAX}x the 60-unit profit "
                            f"{small}g")
        if worst:
            verdict = "ok" if gate_ok else "FAIL"
            out(f"  {measured} routes measured; worst ratio "
                f"{fmt(worst[0] / 10)}x ({worst[1]} -> {worst[2]} {worst[3]}: "
                f"{worst[4]}g vs {worst[5]}g)  [{verdict}]")
        else:
            out("  no measurable routes  [FAIL]")
            gate_ok = False
        gate_results.append((8, gate_ok, f"< {GATE8_RUN_RATIO_MAX}x"))

    # ======================================================================
    # Gate 9 — staple access + the furthest-staple ranking
    # ======================================================================
    if 9 in gates:
        out("")
        out(f"gate 9: staple access — nearest staple producer <= "
            f"{STAPLE_ACCESS_NEAR_TILES} tiles")
        gate_ok = True
        ranking = staple_ranking(world, staples)
        for distance, pid, producer, good_id in ranking:
            if distance > STAPLE_ACCESS_NEAR_TILES:
                gate_ok = False
                out(f"  VIOLATION {pid}: nearest staple producer {producer} "
                    f"is {distance} tiles away ({good_id})")
        short = []
        for pid in world.port_ids:
            port = world.ports[pid]
            count = sum(1 for other_id in world.port_ids
                        if staples & world.ports[other_id]["produces"]
                        and port_distance(port, world.ports[other_id])
                        <= STAPLE_ACCESS_FAR_TILES)
            if count < 2:
                short.append(pid)
        if short:
            gate_ok = False
            out(f"  VIOLATION ports with < 2 staple producers within "
                f"{STAPLE_ACCESS_FAR_TILES} tiles: {', '.join(sorted(short))}")
        head = ", ".join(
            f"{pid} ({distance} tiles → {producer}/{good_id})"
            for distance, pid, producer, good_id in ranking[:10])
        out(f"  furthest staple runs (top 10 of {len(ranking)}): {head}")
        out(f"  [{'ok' if gate_ok else 'FAIL'}]")
        gate_results.append(
            (9, gate_ok, f"nearest staple <= {STAPLE_ACCESS_NEAR_TILES} tiles"))

    # ======================================================================
    # Gate 10 — producer health with NPCs active
    # ======================================================================
    if 10 in gates:
        out("")
        out("gate 10: producer health (coasters + sovereign traders active) "
            f"— steady-state producer stock >= "
            f"{fmt(GATE10_PRODUCER_HEALTH)} capacity")
        snap = world.snapshot()
        world.seed_new_game()
        used = NpcLayer(world, coaster_pair_list, trader_pair_list).converge()
        total_x1000 = 0
        count = 0
        worst = None
        for pid in world.port_ids:
            port = world.ports[pid]
            for good_id in sorted(port["produces"]):
                cap = world.capacity(pid, good_id)
                ratio_x1000 = world.stocks[pid].get(good_id, 0) * 1000 // cap
                total_x1000 += ratio_x1000
                count += 1
                if worst is None or ratio_x1000 < worst[0]:
                    worst = (ratio_x1000, pid, good_id, cap)
        world.restore(snap)
        average_x1000 = total_x1000 // count if count else 0
        gate_ok = average_x1000 >= int(GATE10_PRODUCER_HEALTH * 1000)
        verdict = "ok" if gate_ok else "FAIL"
        worst_txt = (f"{worst[1]} {worst[2]} {fmt(worst[0] / 1000)} of "
                     f"{worst[3]}") if worst else "none"
        out(f"  NPC layer converged in {used} days; {count} producer "
            f"port-goods; average stock {fmt(average_x1000 / 1000)} of "
            f"capacity (worst: {worst_txt})  [{verdict}]")
        gate_results.append((10, gate_ok,
                             "avg producer stock >= "
                             f"{fmt(GATE10_PRODUCER_HEALTH)} capacity"))

    # -- summary --------------------------------------------------------------
    out("")
    out("gate summary:")
    all_ok = True
    for number, ok, label in sorted(gate_results):
        all_ok = all_ok and ok
        out(f"  gate {number:2d}: {'PASS' if ok else 'FAIL'}  ({label})")
    out(f"overall: {'PASS' if all_ok else 'FAIL'}")

    if args.csv:
        Path(args.csv).write_text("\n".join(csv_rows) + ("\n" if csv_rows
                                                          else ""),
                                  encoding="utf-8")
    print("\n".join(lines))
    return 0 if all_ok else 1


# --- gate bodies shared by gates 2 and 4 --------------------------------------

def route_scopes(world: World):
    """The gate-2/4 route scopes: each tier swept with the starter-caravel
    class (capacity 120, speed 20 — the reference hull for route widths)."""
    staple_ids = frozenset(g for g in world.goods
                           if world.goods[g]["tier"] == "staple")
    middle_ids = frozenset(g for g in world.goods
                           if world.goods[g]["tier"] == "middle")
    special_ids = frozenset(g for g in world.goods
                            if world.goods[g]["specialty"])
    return (("staple", staple_ids), ("middle", middle_ids),
            ("specialty", special_ids))


def gate_foreign_tax(world: World, lane_pairs, out, csv_rows, ratio_cap: float,
                     label: str, collect_csv: bool = True):
    """Gates 2 and 4 share one sweep.

    MODELING (the §2.9 gate-2 shape): "foreign unpermitted" = a trader with
    NO alignment at either end — the fully-foreign run pays 20%/20%; the
    equivalent permitted run carries the 涉外免税证 for both nations and pays
    0%/0%. Mixed runs (buy home 5%, sell foreign 20%) are reported
    informationally below the gate: their taxed/permitted ratio depends only
    on the route margin (ratio <= 0.6 iff sell <= 1.714x buy), which is
    walk-structural, not authorable data — flagging them as gate failures
    would be a gate-shape decision for the master, not a data bounce."""
    out("")
    out(f"{label}: fully-foreign unpermitted (20%/20%) vs permitted (0%/0%) "
        f"— ratio <= {ratio_cap} on every profitable route")
    gate_ok = True
    measured = 0
    skipped = 0
    worst = None
    mixed_worst = None
    capacity = 120  # the starter-caravel reference hold
    for (a, b, _dist) in sorted(lane_pairs,
                                key=lambda p: (p[0]["id"], p[1]["id"])):
        aligns = {world.alignment[a["id"]], world.alignment[b["id"]]}
        trader = next((n for n in NATIONS if n not in aligns), None)
        if trader is None:
            continue  # no nation is fully foreign to both ends
        for scope_name, scope_ids in route_scopes(world):
            found = best_route_either(world, a, b, scope_ids, capacity, trader)
            if not found:
                continue
            src, dst, good_id, qty, profit_real = found
            base = world.goods[good_id]["base_price"]
            stock_src = world.stocks[src["id"]].get(good_id, 0)
            stock_dst = world.stocks[dst["id"]].get(good_id, 0)
            profit_free = run_profit(base, stock_src, stock_dst, qty, 0, 0)
            if profit_free <= 0:
                skipped += 1
                continue
            ratio_x1000 = profit_real * 1000 // profit_free
            measured += 1
            if worst is None or ratio_x1000 > worst[0]:
                worst = (ratio_x1000, src["id"], dst["id"], good_id, qty,
                         profit_real, profit_free, scope_name)
            if ratio_x1000 > int(ratio_cap * 1000):
                gate_ok = False
                out(f"  VIOLATION {src['id']} -> {dst['id']} {good_id} q{qty}: "
                    f"taxed {profit_real}g vs permitted {profit_free}g = "
                    f"{fmt(ratio_x1000 / 1000)}")
        # informational: the mixed 5%-home / 20%-foreign shape
        resident = world.alignment[a["id"]] or world.alignment[b["id"]]
        m_found = best_route_either(world, a, b, _any_scope(world), capacity,
                                    resident)
        if m_found:
            m_src, m_dst, m_good, m_qty, m_real = m_found
            base = world.goods[m_good]["base_price"]
            m_free = run_profit(base, world.stocks[m_src["id"]].get(m_good, 0),
                                world.stocks[m_dst["id"]].get(m_good, 0), m_qty,
                                0, 0)
            if m_free > 0:
                m_ratio = m_real * 1000 // m_free
                if mixed_worst is None or m_ratio > mixed_worst[0]:
                    mixed_worst = (m_ratio, m_src["id"], m_dst["id"], m_good,
                                   m_qty)
    if worst:
        verdict = "ok" if gate_ok else "FAIL"
        out(f"  {measured} profitable fully-foreign routes measured "
            f"({skipped} non-binding pre-tax losers skipped); worst ratio "
            f"{fmt(worst[0] / 1000)} at {worst[1]} -> {worst[2]} {worst[3]} "
            f"q{worst[4]} ({worst[5]}g vs {worst[6]}g, {worst[7]})  "
            f"[{verdict}]")
        if collect_csv:
            csv_rows.append(f"{label},{worst[1]}->{worst[2]},{worst[3]},"
                            f"{worst[4]},{worst[5]},{worst[6]},"
                            f"{fmt(worst[0] / 1000)}")
    else:
        out("  no profitable fully-foreign lane routes measured  [FAIL]")
        gate_ok = False
    if mixed_worst:
        out(f"  INFO mixed 5%-home/20%-foreign runs (not gated): worst ratio "
            f"{fmt(mixed_worst[0] / 1000)} at {mixed_worst[1]} -> "
            f"{mixed_worst[2]} {mixed_worst[3]} q{mixed_worst[4]} — "
            "ratio <= 0.6 iff margin <= 71.4% (walk-structural)")
    return gate_ok, f"ratio <= {ratio_cap}"


def _any_scope(world: World) -> frozenset:
    return frozenset(world.goods)


# --- remaining helpers ---------------------------------------------------------

def home_pairs(world: World) -> list[tuple[dict, dict, int]]:
    """Every aligned-port pair within a nation (the home-route universe)."""
    out = []
    by_nation: dict[str, list[str]] = {}
    for pid in world.port_ids:
        port = world.ports[pid]
        if not port["neutral"]:
            by_nation.setdefault(port["nation_id"], []).append(pid)
    for nation in sorted(by_nation):
        rows = sorted(by_nation[nation])
        for i, a in enumerate(rows):
            for b in rows[i + 1:]:
                out.append((world.ports[a], world.ports[b], 0))
    return out


def measured_gaps(world: World, coaster_pair_list) -> dict:
    """factor(dst) − factor(src) for every scoped produced→demanded relation
    on a coaster pair (the gate-6 measured gaps)."""
    gaps: dict[tuple[str, str, str], int] = {}
    for (a, b, _dist) in coaster_pair_list:
        for src, dst in ((a, b), (b, a)):
            for good_id in sorted(src["produces"]):
                if good_id not in world.coaster_scope:
                    continue
                if good_id not in dst["demands"] or good_id in dst["produces"]:
                    continue
                gap = (factor_units(world.stocks[dst["id"]].get(good_id, 0))
                       - factor_units(world.stocks[src["id"]].get(good_id, 0)))
                gaps[(good_id, src["id"], dst["id"])] = gap
    return gaps


def greedy_bot(world: World, lane_pairs, days_budget: int):
    """The decision-22 optimal-greedy bot.

    MODELING: the §4.4 trader decision — argmax profit-per-day over
    (good, destination) at live prices, deterministic (no noise, no specialty
    mult, risk 1.0). The bot plays portugal from lisbon with the starter
    caravel and the 5,000g start gold, walks lane-adjacent hops only, buys
    the profit-maximizing quantity its purse and hold afford (the §4.4
    purse walk), pays the §4.10 tariff on both ends, sells the whole hold on
    arrival, and idles a pure-flow day when no profitable hop exists. No NPC
    layer (the player-only economy is the conservative ceiling)."""
    world.seed_new_game()
    world.converge()
    nation = "portugal"
    _ship, capacity, speed = STARTER_SHIPS[nation]
    gold = 5000
    purse0 = 5000
    here = world.ports["lisbon"]
    neighbors: dict[str, list[tuple[dict, int]]] = {}
    for (a, b, dist) in lane_pairs:
        neighbors.setdefault(a["id"], []).append((b, dist))
        neighbors.setdefault(b["id"], []).append((a, dist))
    for key in neighbors:
        neighbors[key].sort(key=lambda row: (row[1], row[0]["id"]))

    trace: list[tuple] = []
    day = 0
    while day < days_budget:
        best = None
        for (b, dist) in neighbors.get(here["id"], ()):
            mille_a = world.mille(here["id"], nation)
            mille_b = world.mille(b["id"], nation)
            for good_id in sorted(here["produces"]):
                if good_id in b["produces"] or good_id not in b["demands"]:
                    continue
                base = world.goods[good_id]["base_price"]
                stock = world.stocks[here["id"]].get(good_id, 0)
                if stock <= 0 or gold < buy_price(base, stock):
                    continue
                # the §4.4 Max rule: purse- and hold-limited tranche walk
                purse = gold
                buy_total = 0
                bought = 0
                units_left = capacity
                walk_stock = stock
                while units_left > 0:
                    units = min(TRANCHE_UNITS, units_left)
                    price = buy_price(base, walk_stock)
                    if purse >= price * units:
                        purse -= price * units
                        buy_total += price * units
                        bought += units
                    else:
                        partial = purse // price
                        if partial > 0:
                            buy_total += price * partial
                            bought += partial
                            purse -= price * partial
                        break
                    walk_stock = max(STOCK_MIN, walk_stock - units)
                    units_left -= units
                if bought <= 0:
                    continue
                est_sell, _ = walk_sell(
                    base, world.stocks[b["id"]].get(good_id, 0), bought)
                est_profit = (taxed_sell(est_sell, mille_b)
                              - taxed_buy(buy_total, mille_a))
                if est_profit <= 0:
                    continue
                score_x1000 = est_profit * 1000 \
                    // (sailing_days(dist, speed) + 2)
                key = (-score_x1000, good_id, b["id"])
                if best is None or key < best[0]:
                    best = (key, good_id, bought, buy_total, b, dist,
                            est_profit)
        if best is None:
            world.day_tick()
            day += 1
            continue
        _key, good_id, bought, buy_total, b, dist, est_profit = best
        # book the buy at the current port
        stock = world.stocks[here["id"]].get(good_id, 0)
        _, stock = walk_buy(world.goods[good_id]["base_price"], stock, bought)
        world.stocks[here["id"]][good_id] = stock
        travel = sailing_days(dist, speed)
        for _ in range(travel):
            world.day_tick()
            day += 1
        sell_total, stock_b = walk_sell(world.goods[good_id]["base_price"],
                                        world.stocks[b["id"]].get(good_id, 0),
                                        bought)
        world.stocks[b["id"]][good_id] = stock_b
        net_sell = taxed_sell(sell_total, world.mille(b["id"], nation))
        gold += net_sell
        profit = net_sell - taxed_buy(buy_total,
                                      world.mille(here["id"], nation))
        trace.append((day, here["id"], b["id"], good_id, bought, profit, gold))
        here = b
    return gold - purse0, trace


def staple_ranking(world: World, staples: frozenset) -> list:
    """(distance, port, producer, good) ascending — the gate-9 furthest-
    staple ranking the report prints (P iterates on this ranking)."""
    producers = [world.ports[pid] for pid in world.port_ids
                 if staples & world.ports[pid]["produces"]]
    ranking = []
    for pid in world.port_ids:
        port = world.ports[pid]
        best = None
        for producer in producers:
            distance = port_distance(port, producer)
            if best is None or distance < best[0]:
                best = (distance, producer["id"],
                        sorted(staples & producer["produces"])[0])
        if best:
            ranking.append((best[0], pid, best[1], best[2]))
    ranking.sort(key=lambda row: (-row[0], row[1]))
    return ranking


if __name__ == "__main__":
    sys.exit(main())
