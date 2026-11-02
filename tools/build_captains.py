#!/usr/bin/env python3
"""build_captains.py — deterministic captain-canon & officer-roster builder
(Phase 8, W2 slot A).

One tool, three products (docs/10-DATA-SCHEMA.md §4.11 / §4.5 / §4.12):

    data/captains.json        the closed named-captain canon (built artifact)
    data/officers.json        the 96-officer roster v2 (built artifact)
    data/named_pirates.json   the 4 bounty-facing pirate cards (v2 full cards)

Sources: ``data/captain_name_parts.json`` (names, personality pools,
appearance vocabulary, officer bio templates) + the quota derivation below +
``tools/captain_overrides.json`` (24 legend captains: the 4 named pirates
with their Phase-7 ``drop`` fields + 20 hand-authored legend captains) +
``tools/officer_overrides.json`` (24 legend officers) + ``data/ports.json``
/ ``data/nations.json`` / ``data/npc_config.json`` / ``data/equipment.json``.
Mirror of ``build_routes.py`` governance: pure stdlib, no timestamps, one
seeded RNG consumed in a fixed order, stable sort everywhere — two
consecutive builds are **byte-identical** (§8.6 item 2).

Quota derivation (no magic numbers — mirrors ``budget_for()`` in
``scripts/world/npc_fleets.gd`` exactly at the EXTREME preset, multiplier
``presets.extreme = 4.0`` from ``data/npc_config.json``, ``ceil`` per row,
multiply-then-ceil like the GDScript ``ceili(own * mult * preset)``):

    trader            ceil(own_ports × traders_mult_per_port × 4) per nation
                      → 100+105+65+110+90+55 = 525; tiers 1/2 split 50/50
                      (tier1 = floor, tier2 = remainder)
    coaster           ceil(own_ports × coasters_mult_per_port × 4) per nation
                      → 315, tier 1 only
    coaster (""),     ceil(45 neutral ports × neutral_coasters_mult × 4)
    nationless          = 135, tier 1 only — pirates AND nationless coasters
                      draw the "" name set
    patrol            max(1, ceil(own_ports / patrols_div_ports × 4)) per
                      nation → 14+14+9+15+12+8 = 72, tier 2 only
    courier           ceil(couriers_per_nation × 4) = 8 per nation → 48;
                      tiers 1/2 split 50/50
    privateer         ceil(privateers_per_rivalry × 4) = 8 per UNDIRECTED
                      rivalry pair (7 pairs in nations.json `rivals`) → 56;
                      each pair's cards split evenly between its two nations
                      (the W2-A attribution choice, recorded here: both ends
                      of a rivalry license privateers, 4/4), tiers 2/3
                      split 50/50. This ≥ the per-nation runtime count
                      (budget_for counts each belligerent nation once = 48),
                      so coverage holds under either reading.
    pirate            ceil(25 × 4) = 100 — 25 = pirate_base (8, from
                      npc_config) + 17 unpatrolled zones, the Phase-7
                      measured normal composition (docs/60-COMBAT.md §4.1.1
                      "≈ 25", tools/demo_check_phase7.md: pirates 25); tiers
                      40/35/25 across 1/2/3. Note: the runtime caps live
                      pirates at PIRATE_CORE_CAP = 25 even at extreme; the
                      canon covers the *uncapped* extreme demand per the
                      W1-locked §7.7 rule ("×4 at the extreme preset").
    hunter            6 bountied nations (worst case, §4.1.1 transient row)
                      × 4 = 24; tiers 2/3 split 50/50 per nation
    treasure          6 nations × 4 = 24 — tier-2 trader-role cards of their
                      nation; covered BY the trader tier-2 cells (W1 gate
                      pin 2026-11-02), recorded as its own quota_table row
                      with "covered_by": "trader.tier2" (the trader tier-2
                      total ≈ 262 ≥ 24 is asserted below).

Grand total ≈ 1,275 cards (the ≈1,276 figure in the W2-A brief used the
Phase-7 normal core 307 × 4 + transients as its estimate; the per-formula
extreme derivation above is the authoritative number and is what
quota_table records).

Tier ranges (§4.11, locked): coaster 1; trader/courier 1–2; patrol 2;
privateer/hunter 2–3; pirate 1–3.

Card generation (non-legend; §4.11 formulas, re-asserted term-by-term):

    level       1 + tier×4, +2 for pirate/hunter
    attributes  base 10; main +3×tier, secondary +2×tier, others +1×tier;
                each final value jitters seeded ±3 (clamped 1–100)
    skills      signature 8×tier + seeded(0..6); secondary skill 4×tier;
                every other skill 0 — the coaster names NO skills (all 0)
                and its luck sits at the others step
    personality 1–2 tags from the role pool
    appearance  one value per axis (face/beard/eyes/hair)

Coaster template (W2-A choices, recorded): main attribute constitution,
secondary attribute COURAGE (the §4.11 coaster row leaves the secondary
cell "any" — courage is chosen deterministically and is the only fixed
choice; luck stays at the others step, intellect/charisma at others too).

Names (§4.11.1): drawn WITHOUT replacement per nation set from
``given_names × surnames`` (zh assembled ``given·surname``, en
``given surname``). Every hand-authored name (4 pirates, 20 legend
captains, 24 legend officers, 6 starters) is registered FIRST; a draw that
collides with any registered name (zh or en) is consumed and skipped, so
no two people ever share a name — the builder hard-errors if a set runs
dry.

Officers (§4.5, §7.5; 96 = 24 legend + 72 regular):

    legends    hand-authored in tools/officer_overrides.json — main skill
               45–60, wage 40–60 g/day, hand recruit_ports ⊆ the nation's
               ports, nations spread over all 6, native roles covering all
               7. Roster order: the override file order = roster indices
               0–23.
    regulars   generated: main skill 25–45, wage 20–35 g/day, attributes
               10 + seeded(0..12) per axis (seamanship-signature officers
               get courage 30 + seeded(0..10) so the captain post is
               reachable), 2 secondary skills at 20–24 from a fixed
               rotation, remaining skills seeded 0–10, recruit_ports = a
               rotating window of 2–3 of the nation's sorted ports.
               Roster order: generated regulars = indices 24–89, then the
               6 Phase-1 starters verbatim = indices 90–95.

    native roles (7; pool id = role id; signature = main_skill):
        pilot→navigation, boatswain→seamanship, gunner→gunnery,
        surgeon→medicine, carpenter→carpentry, cook→cooking,
        captain→seamanship with a swordplay-main variant for ~1/3 of
        captains. Generated split (recorded): pilot 8, boatswain 9,
        gunner 9, surgeon 8, carpenter 8, cook 8, captain 16 (11
        seamanship-main + 5 swordplay-main) — with the 4 legend captains
        (3 seam + 2 sword) the roster holds 14 seam/7 sword captains.
        The 6 starters keep their v1 names/bios/recruit_ports/wages
        verbatim (locked identity §7.5) and convert to v2 shape as
        hand-authored regulars (STARTERS_V2 below).

    secondary rotation (the fixed plan; drives the §8.7 specialty quota
    "each of the 11 skills carried at ≥20 by ≥10 officers"): roster
    indices 0–9 appraisal, 10–19 negotiation, 20–29 cartography,
    30–39 rumour, 40–42 swordplay (3 extra carriers on top of the 7
    swordplay-main captains); every officer's second pair slot comes from
    a per-native-role fixed pair (PILOT_PAIR … CAPTAIN_PAIR below).
    Captain-qualified quota: every seamanship-signature officer (14
    boatswains + 14 seamanship-captains) carries courage ≥ 30, far above
    the ≥ 12 pin.

    Personality pools: seamanship-main officers draw from the boatswain
    pool ONLY (the native-role → pool map is ambiguous between boatswain
    and captain for a seamanship main; boatswain-pool tags keep both
    readings green). Swordplay-main captains draw from the captain pool.

Usage
-----
    python3 tools/build_captains.py           # build + write all three files
    python3 tools/build_captains.py --check   # rebuild in memory, byte-compare
    python3 tools/build_captains.py --report  # build + print the quota table

Exit codes: 0 ok; 2 a named build/assertion failure; 3 determinism drift
(--check mismatch).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
TOOLS = ROOT / "tools"
PARTS_PATH = DATA / "captain_name_parts.json"
CONFIG_PATH = DATA / "npc_config.json"
PORTS_PATH = DATA / "ports.json"
NATIONS_PATH = DATA / "nations.json"
EQUIPMENT_PATH = DATA / "equipment.json"
CAPTAIN_OVERRIDES_PATH = TOOLS / "captain_overrides.json"
OFFICER_OVERRIDES_PATH = TOOLS / "officer_overrides.json"
CAPTAINS_PATH = DATA / "captains.json"
OFFICERS_PATH = DATA / "officers.json"
NAMED_PIRATES_PATH = DATA / "named_pirates.json"

# --------------------------------------------------------------------------
# Locked constants (docs/10-DATA-SCHEMA.md §4.11, §4.5, §7.5, §7.7, §8.6–8.7)
# --------------------------------------------------------------------------
SEED = "sailage-canon-v1"
COVERAGE_PRESET = "extreme"

ATTRS = ("constitution", "intellect", "charisma", "courage", "luck")
CAPTAIN_SKILLS = ("seamanship", "navigation", "swordplay", "gunnery",
                  "appraisal", "negotiation", "cartography", "rumour")
OFFICER_SKILLS = CAPTAIN_SKILLS + ("medicine", "carpentry", "cooking")

ROLE_ORDER = ("trader", "coaster", "patrol", "courier", "privateer",
              "pirate", "hunter")
ROLE_TIERS = {"trader": (1, 2), "coaster": (1, 1), "patrol": (2, 2),
              "courier": (1, 2), "privateer": (2, 3), "pirate": (1, 3),
              "hunter": (2, 3)}
PIRATE_HUNTER = ("pirate", "hunter")

# (main attribute, secondary attribute, signature skill, secondary skill)
ROLE_TEMPLATES = {
    "trader": ("charisma", "luck", "negotiation", "appraisal"),
    # coaster: luck stays at the OTHERS step (the -low pin); the secondary
    # attribute cell is "any" per §4.11 — W2-A pins COURAGE here; no skills.
    "coaster": ("constitution", "courage", None, None),
    "patrol": ("courage", "charisma", "gunnery", "seamanship"),
    "courier": ("constitution", "intellect", "navigation", "seamanship"),
    "privateer": ("courage", "luck", "swordplay", "gunnery"),
    "pirate": ("courage", "charisma", "swordplay", "gunnery"),
    "hunter": ("courage", "intellect", "swordplay", "navigation"),
}

# Pirate quota derivation (W2-A brief + docs/60-COMBAT.md §4.1.1 +
# tools/demo_check_phase7.md): the Phase-7 measured normal composition is
# 25 pirates = pirate_base (8, data-driven below) + 17 unpatrolled zones.
UNPATROLLED_ZONES_PHASE7 = 17
PIRATE_TIER_SPLIT = (0.40, 0.35)  # tier 1 / tier 2; tier 3 takes the rest
# Transient worst-case rows (§7.7): all 6 nations bountied / treasure in
# season everywhere, each ×4 at the extreme preset.
TRANSIENT_NATIONS = 6

NAMED_PIRATE_IDS = ("pirate_redbeard_khair", "pirate_murad_red_sail",
                    "pirate_limahong_thousand_sails",
                    "pirate_edward_bloodhand")
PIRATE_QUOTA_NOTE = (
    "8 pirate_base + 17 unpatrolled zones = 25 (Phase-7 measured normal "
    "composition, docs/60-COMBAT.md section 4.1.1, tools/"
    "demo_check_phase7.md) x extreme preset 4.0 = 100")

# Officer roster plan (§4.5/§7.5; recorded per the W2-A brief).
LEGEND_COUNT = 24
REGULAR_COUNT = 72
OFFICER_TOTAL = LEGEND_COUNT + REGULAR_COUNT  # 96
SPECIALTY_MIN_CARRIERS = 10  # each skill carried at ≥20 by ≥10 officers
SPECIALTY_THRESHOLD = 20
CAPTAIN_QUALIFIED_MIN = 12
LEGEND_MAIN_BAND = (45, 60)
REGULAR_MAIN_BAND = (25, 45)
LEGEND_WAGE_BAND = (40, 60)
REGULAR_WAGE_BAND = (20, 35)
# Generated regulars by native role (group, count); the 6 starters are
# hand-authored (pilot ×2, boatswain ×2, gunner ×2) and 24 legends are
# overrides — together they complete 96 = 24 + 72 with 14 pilots,
# 14 boatswains, 14 gunners, 11 surgeons, 11 carpenters, 11 cooks and
# 21 captains (14 seamanship-main + 7 swordplay-main).
GEN_PLAN = (("pilot", 8, "navigation"), ("boatswain", 9, "seamanship"),
            ("gunner", 9, "gunnery"), ("surgeon", 8, "medicine"),
            ("carpenter", 8, "carpentry"), ("cook", 8, "cooking"),
            ("captain_seam", 11, "seamanship"),
            ("captain_sword", 5, "swordplay"))
# Native role → personality pool id. Seamanship mains use the boatswain
# pool (the boatswain/captain ambiguity is resolved conservatively).
NATIVE_POOL = {"pilot": "pilot", "boatswain": "boatswain", "gunner": "gunner",
               "surgeon": "surgeon", "carpenter": "carpenter", "cook": "cook",
               "captain_seam": "boatswain", "captain_sword": "captain"}
# Native role → the fixed second-pair rotation (2 secondary skills; the
# soft-rotation slot may replace the pair's first member).
ROLE_PAIR = {"pilot": ("cartography", "seamanship"),
             "boatswain": ("navigation", "carpentry"),
             "gunner": ("seamanship", "carpentry"),
             "surgeon": ("cooking", "cartography"),
             "carpenter": ("cooking", "seamanship"),
             "cook": ("carpentry", "seamanship"),
             "captain_seam": ("navigation", "gunnery"),
             "captain_sword": ("gunnery", "navigation")}
# Roster index → the soft secondary skill (see the header note).
SOFT_ROTATION = {**{r: "appraisal" for r in range(0, 10)},
                 **{r: "negotiation" for r in range(10, 20)},
                 **{r: "cartography" for r in range(20, 30)},
                 **{r: "rumour" for r in range(30, 40)},
                 **{r: "swordplay" for r in range(40, 43)}}

# The 6 Phase-1 starters — the locked §7.5 identity, verbatim from the v1
# file (names, nations, recruit_ports, wages, bios). The builder must not
# read data/officers.json (it IS the builder's own v2 output), so the locked
# identity is carried here exactly as shipped in v1; their v2 stat
# conversion lives in starters_v2() below.
STARTERS_V1 = {
    "off_mateus_alvares": {
        "name": {"zh": "马特乌斯·阿尔瓦雷斯", "en": "Mateus Álvares"},
        "nation_id": "portugal",
        "wage_daily": 30,
        "recruit_ports": ["lisbon", "madeira"],
        "bio": {"zh": "一位在老领航员手下学艺的青年,星象与海图无一不精。",
                "en": "A young pilot schooled by old navigators; at home with stars and charts alike."},
    },
    "off_diego_fernandez": {
        "name": {"zh": "迭戈·费尔南德斯", "en": "Diego Fernández"},
        "nation_id": "spain",
        "wage_daily": 28,
        "recruit_ports": ["seville", "ceuta"],
        "bio": {"zh": "在塞维利亚船坞里长大的老水手长,一声令下缆索便各归其位。",
                "en": "A boatswain raised in the Seville yards, whose whistle sends every rope to its place."},
    },
    "off_thomas_reed": {
        "name": {"zh": "托马斯·里德", "en": "Thomas Reed"},
        "nation_id": "england",
        "wage_daily": 32,
        "recruit_ports": ["london"],
        "bio": {"zh": "曾在英吉利海峡追捕私掠者的炮手,最看重火药干燥与否。",
                "en": "A gunner who once chased privateers in the Channel, and cares above all that the powder stays dry."},
    },
    "off_jan_de_vries": {
        "name": {"zh": "扬·德弗里斯", "en": "Jan de Vries"},
        "nation_id": "holland",
        "wage_daily": 28,
        "recruit_ports": ["amsterdam", "antwerp"],
        "bio": {"zh": "弗里斯兰出身的水手长,能在暴风里把甲板收拾得井井有条。",
                "en": "A Frisian boatswain who can keep a deck in order even through a gale."},
    },
    "off_kemal_agha": {
        "name": {"zh": "凯末尔阿迦", "en": "Kemal Agha"},
        "nation_id": "ottoman",
        "wage_daily": 30,
        "recruit_ports": ["istanbul", "smyrna"],
        "bio": {"zh": "在金角湾炮台服役多年的老炮长,开火前总要亲手校一遍炮位。",
                "en": "A veteran gun captain from the Golden Horn batteries, who sights each gun himself before firing."},
    },
    "off_marco_bellini": {
        "name": {"zh": "马尔科·贝里尼", "en": "Marco Bellini"},
        "nation_id": "italy",
        "wage_daily": 30,
        "recruit_ports": ["venice", "genoa"],
        "bio": {"zh": "为威尼斯商船绘制海图的领航员,对亚得里亚海的每一处暗礁都了然于心。",
                "en": "A chart-maker for Venetian merchantmen, who knows every reef in the Adriatic by heart."},
    },
}

OFFICER_CARD_KEYS = ("id", "name", "nation_id", "legend", "main_skill",
                     "attributes", "skills", "personality", "appearance",
                     "wage_daily", "recruit_ports", "bio")
CAPTAIN_CARD_KEYS = ("id", "name", "nation_id", "role", "tier", "level",
                     "attributes", "skills", "personality", "appearance",
                     "drop", "legend", "home_port")


class BuildError(Exception):
    """A named build failure (exit 2)."""


# --------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------
def load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def seed_rng() -> random.Random:
    digest = hashlib.sha256(SEED.encode("utf-8")).digest()
    return random.Random(int.from_bytes(digest[:8], "big"))


# --------------------------------------------------------------------------
# Quota derivation — mirrors npc_fleets.gd budget_for() at the extreme preset
# --------------------------------------------------------------------------
def split_halves(total: int) -> tuple[int, int]:
    """50/50 tier split; tier 1 takes the floor, tier 2 the remainder."""
    low = total // 2
    return low, total - low


def derive_quotas(config: dict, ports: list, nations: list) -> dict:
    """(role, tier, nation_id) → card count, at the extreme preset."""
    extreme = float(config["presets"][COVERAGE_PRESET])
    if extreme <= 0.0:
        raise BuildError("npc_config presets.extreme must be > 0")
    budgets = config["budgets"]
    own = {n: 0 for n in (nation["id"] for nation in nations)}
    neutral = 0
    for port in ports:
        nation_id = port["nation_id"]
        if nation_id == "":
            neutral += 1
        elif nation_id in own:
            own[nation_id] += 1
    cells: dict[tuple[str, int, str], int] = {}
    sovereign = sorted(own)

    def add(role: str, tier: int, nation_id: str, count: int) -> None:
        if count > 0:
            cells[(role, tier, nation_id)] = count

    for nation_id in sovereign:
        n = own[nation_id]
        # trader: ceili(own * traders_mult_per_port * mult)
        t1, t2 = split_halves(math.ceil(n * budgets["traders_mult_per_port"]
                                        * extreme))
        add("trader", 1, nation_id, t1)
        add("trader", 2, nation_id, t2)
        # coaster: ceili(own * coasters_mult_per_port * mult)
        add("coaster", 1, nation_id,
            math.ceil(n * budgets["coasters_mult_per_port"] * extreme))
        # patrol: max(patrols_min, ceil(own / div * mult))
        raw = math.ceil(n / float(budgets["patrols_div_ports"]) * extreme)
        add("patrol", 2, nation_id,
            max(int(budgets["patrols_min"]), raw))
        # courier: ceili(couriers_per_nation * mult)
        c1, c2 = split_halves(math.ceil(budgets["couriers_per_nation"]
                                        * extreme))
        add("courier", 1, nation_id, c1)
        add("courier", 2, nation_id, c2)

    # nationless coasters: ceili(neutral * neutral_coasters_mult * mult)
    add("coaster", 1, "", math.ceil(neutral
                                    * config["neutral_coasters_mult"]
                                    * extreme))

    # privateers: per UNDIRECTED rivalry pair, split 4/4 between the pair's
    # two nations (W2-A attribution; ≥ the per-nation runtime count).
    pairs: set[tuple[str, str]] = set()
    for nation in nations:
        nid = nation["id"]
        for rival in nation.get("rivals", []):
            pairs.add(tuple(sorted((nid, str(rival)))))
    per_pair = math.ceil(budgets["privateers_per_rivalry"] * extreme)
    per_side = per_pair // 2  # 4 of the pair's 8 cards per nation
    priv_totals: dict[str, int] = {}
    for side_a, side_b in sorted(pairs):
        for nation_id in (side_a, side_b):
            priv_totals[nation_id] = priv_totals.get(nation_id, 0) + per_side
    for nation_id in sorted(priv_totals):
        t2, t3 = split_halves(priv_totals[nation_id])
        add("privateer", 2, nation_id, t2)
        add("privateer", 3, nation_id, t3)

    # pirates: pirate_base + 17 unpatrolled zones (Phase-7 measured) × 4.
    normal_pirates = budgets["pirate_base"] + UNPATROLLED_ZONES_PHASE7
    total = math.ceil(normal_pirates * extreme)
    p1 = math.floor(total * PIRATE_TIER_SPLIT[0])
    p2 = math.floor(total * PIRATE_TIER_SPLIT[1])
    add("pirate", 1, "", p1)
    add("pirate", 2, "", p2)
    add("pirate", 3, "", total - p1 - p2)

    # hunters: the transient row — worst case all 6 nations bountied, ×4.
    per_nation = TRANSIENT_NATIONS and math.ceil(TRANSIENT_NATIONS * extreme) \
        // TRANSIENT_NATIONS
    for nation_id in sovereign:
        h2, h3 = split_halves(per_nation)
        add("hunter", 2, nation_id, h2)
        add("hunter", 3, nation_id, h3)

    # treasure: recorded-only row, covered by trader tier-2 cells.
    treasure_total = TRANSIENT_NATIONS * math.ceil(TRANSIENT_NATIONS
                                                   * extreme) \
        // TRANSIENT_NATIONS
    trader_t2 = sum(v for (r, t, _n), v in cells.items()
                    if r == "trader" and t == 2)
    if trader_t2 < treasure_total:
        raise BuildError(
            f"trader tier-2 cells ({trader_t2}) cannot cover the treasure "
            f"row ({treasure_total}) — quota derivation broken")
    return {"cells": cells, "treasure_total": treasure_total,
            "own": own, "neutral": neutral, "extreme": extreme}


def build_quota_table(quotas: dict) -> dict:
    """The captains.json quota_table: role → tier(str) → nation → count."""
    table: dict[str, dict] = {}
    for role in ROLE_ORDER:
        row: dict[str, object] = {}
        lo, hi = ROLE_TIERS[role]
        for tier in range(lo, hi + 1):
            cell = {nation: count
                    for (r, t, nation), count in sorted(quotas["cells"].items())
                    if r == role and t == tier}
            if cell:
                row[str(tier)] = cell
        if role == "pirate":
            row["note"] = PIRATE_QUOTA_NOTE
        table[role] = row
    table["treasure"] = {
        "covered_by": "trader.tier2",
        "2": {nation: quotas["treasure_total"] // TRANSIENT_NATIONS
              for nation in sorted(quotas["own"])},
    }
    return table


# --------------------------------------------------------------------------
# Name draws (§4.11.1) — permutation per nation set, global collision skip
# --------------------------------------------------------------------------
class NameBank:
    def __init__(self, parts: dict, rng: random.Random,
                 used: set[tuple[str, str]]):
        self._sets: dict[str, list[tuple[str, str, str, str]]] = {}
        self._used = used
        for nation_id in sorted(parts["surnames"]):
            surnames = parts["surnames"][nation_id]
            givens = parts["given_names"][nation_id]
            combos = [(g["zh"], s["zh"], g["en"], s["en"])
                      for g in givens for s in surnames]
            rng.shuffle(combos)
            self._sets[nation_id] = combos

    def draw(self, nation_id: str) -> dict:
        combos = self._sets.get(nation_id)
        if combos is None:
            raise BuildError(f"no name-part set for nation_id {nation_id!r}")
        while combos:
            g_zh, s_zh, g_en, s_en = combos.pop()
            name = {"zh": f"{g_zh}·{s_zh}", "en": f"{g_en} {s_en}"}
            key = (name["zh"], name["en"])
            if key in self._used:
                continue  # consumed; never reused
            self._used.add(key)
            return name
        raise BuildError(
            f"name-part set {nation_id!r} exhausted — all remaining draws "
            "collide with registered people")


# --------------------------------------------------------------------------
# Captain generation (§4.11)
# --------------------------------------------------------------------------
def jitter(rng: random.Random, base: int) -> int:
    return max(1, min(100, base + rng.randint(-3, 3)))


def generate_captain(card_id: str, name: dict, role: str, tier: int,
                     nation_id: str, parts: dict,
                     rng: random.Random) -> dict:
    main_attr, sec_attr, sig_skill, sec_skill = ROLE_TEMPLATES[role]
    level = 1 + tier * 4 + (2 if role in PIRATE_HUNTER else 0)
    attributes = {}
    for attr in ATTRS:
        if attr == main_attr:
            base = 10 + 3 * tier
        elif attr == sec_attr:
            base = 10 + 2 * tier
        else:
            base = 10 + tier
        attributes[attr] = jitter(rng, base)
    skills = {skill: 0 for skill in CAPTAIN_SKILLS}
    if role != "coaster":  # the coaster names no skills (all 0)
        skills[sig_skill] = 8 * tier + rng.randint(0, 6)
        skills[sec_skill] = 4 * tier
    pool = parts["personalities"]["roles"][role]
    k = 2 if rng.random() < 0.5 else 1
    personality = sorted(rng.sample(sorted(pool), k))
    appearance = {axis: rng.choice(parts["appearance"][axis])
                  for axis in ("face", "beard", "eyes", "hair")}
    return {"id": card_id, "name": name, "nation_id": nation_id,
            "role": role, "tier": tier, "level": level,
            "attributes": attributes, "skills": skills,
            "personality": personality, "appearance": appearance,
            "legend": False}


def canon_legend(entry: dict) -> dict:
    """Normalize an override card into the canonical field order/shape."""
    unknown = set(entry) - set(CAPTAIN_CARD_KEYS)
    if unknown:
        raise BuildError(
            f"captain override {entry.get('id', '?')}: unknown keys "
            f"{', '.join(sorted(unknown))}")
    missing = {"id", "name", "nation_id", "role", "tier", "level",
               "attributes", "skills", "personality", "appearance",
               "legend"} - set(entry)
    if missing:
        raise BuildError(
            f"captain override {entry.get('id', '?')}: missing keys "
            f"{', '.join(sorted(missing))}")
    card = {key: entry[key] for key in CAPTAIN_CARD_KEYS if key in entry}
    return card


# --------------------------------------------------------------------------
# Officer generation (§4.5)
# --------------------------------------------------------------------------
def canon_officer(entry: dict) -> dict:
    unknown = set(entry) - set(OFFICER_CARD_KEYS)
    if unknown:
        raise BuildError(
            f"officer override {entry.get('id', '?')}: unknown keys "
            f"{', '.join(sorted(unknown))}")
    missing = set(OFFICER_CARD_KEYS) - set(entry)
    if missing:
        raise BuildError(
            f"officer override {entry.get('id', '?')}: missing keys "
            f"{', '.join(sorted(missing))}")
    return {key: entry[key] for key in OFFICER_CARD_KEYS}


def generate_officer(officer_id: str, name: dict, nation_id: str,
                     group: str, main_skill: str, roster_index: int,
                     group_index: int, nation_ports: list,
                     nation_names: dict, parts: dict,
                     rng: random.Random) -> dict:
    main = rng.randint(*REGULAR_MAIN_BAND)
    attributes = {attr: 10 + rng.randint(0, 12) for attr in ATTRS}
    if main_skill in ("seamanship", "swordplay"):
        # the captain post prereq (§4.5): seamanship ≥ 25 ∧ courage ≥ 30 —
        # every captain-native officer is bold; seamanship mains are the
        # ones that also clear the seamanship ≥ 25 leg.
        attributes["courage"] = 30 + rng.randint(0, 10)
    skills = {skill: 0 for skill in OFFICER_SKILLS}
    skills[main_skill] = main
    secondaries: list[str] = []
    soft = SOFT_ROTATION.get(roster_index)
    if soft is not None:
        secondaries.append(soft)
    for skill in ROLE_PAIR[group]:
        if skill not in secondaries and len(secondaries) < 2:
            secondaries.append(skill)
    for skill in secondaries:
        skills[skill] = 20 + rng.randint(0, 4)
    for skill in OFFICER_SKILLS:
        if skills[skill] == 0:
            skills[skill] = rng.randint(0, 10)
    pool = parts["personalities"]["roles"][NATIVE_POOL[group]]
    k = 2 if rng.random() < 0.5 else 1
    personality = sorted(rng.sample(sorted(pool), k))
    appearance = {axis: rng.choice(parts["appearance"][axis])
                  for axis in ("face", "beard", "eyes", "hair")}
    wage = rng.randint(*REGULAR_WAGE_BAND)
    window = 2 if group_index % 2 == 0 else 3
    start = (group_index * window) % len(nation_ports)
    recruit = [nation_ports[(start + i) % len(nation_ports)]
               for i in range(window)]
    bios = parts["officer_bios"]["captain" if group == "captain_sword"
                                 or group == "captain_seam" else group]
    template = bios[rng.randrange(len(bios))]
    bio = {"zh": template["zh"].replace("{n}", nation_names["zh"]),
           "en": template["en"].replace("{n}", nation_names["en"])}
    return {"id": officer_id, "name": name, "nation_id": nation_id,
            "legend": False, "main_skill": main_skill,
            "attributes": attributes, "skills": skills,
            "personality": personality, "appearance": appearance,
            "wage_daily": wage, "recruit_ports": recruit, "bio": bio}


def starters_v2(starters_v1_by_id: dict) -> list[dict]:
    """The 6 Phase-1 starters as v2 regulars.

    Names, bios, recruit_ports and wage_daily are the locked §7.5 identity,
    copied verbatim from the v1 file; the v2 attributes/skills/personality/
    appearance and native-role main skills are the W2-A conversion (inside
    the regular bands; off_mateus_alvares follows the §4.5 example card).
    Starters sit at roster indices 90–95, outside the soft-rotation window,
    so their hand conversions are final.
    """
    conversions = {
        "off_mateus_alvares": {
            "main_skill": "navigation",
            "attributes": {"constitution": 11, "intellect": 14,
                           "charisma": 12, "courage": 13, "luck": 10},
            "skills": {"seamanship": 18, "navigation": 30, "swordplay": 8,
                       "gunnery": 6, "appraisal": 10, "negotiation": 12,
                       "cartography": 16, "rumour": 10, "medicine": 0,
                       "carpentry": 0, "cooking": 8},
            "personality": ["bookish", "patient"],
            "appearance": {"face": "lean", "beard": "clean", "eyes": "hazel",
                           "hair": "brown"},
        },
        "off_diego_fernandez": {
            "main_skill": "seamanship",
            "attributes": {"constitution": 16, "intellect": 11,
                           "charisma": 13, "courage": 33, "luck": 10},
            "skills": {"seamanship": 32, "navigation": 18, "swordplay": 12,
                       "gunnery": 10, "appraisal": 4, "negotiation": 6,
                       "cartography": 3, "rumour": 5, "medicine": 0,
                       "carpentry": 14, "cooking": 8},
            "personality": ["stoic", "loyal"],
            "appearance": {"face": "weathered", "beard": "full",
                           "eyes": "dark", "hair": "black"},
        },
        "off_thomas_reed": {
            "main_skill": "gunnery",
            "attributes": {"constitution": 13, "intellect": 12,
                           "charisma": 10, "courage": 30, "luck": 11},
            "skills": {"seamanship": 16, "navigation": 12, "swordplay": 18,
                       "gunnery": 33, "appraisal": 5, "negotiation": 4,
                       "cartography": 4, "rumour": 8, "medicine": 0,
                       "carpentry": 15, "cooking": 6},
            "personality": ["ferocious", "pious"],
            "appearance": {"face": "scarred", "beard": "stubble",
                           "eyes": "grey", "hair": "brown"},
        },
        "off_jan_de_vries": {
            "main_skill": "seamanship",
            "attributes": {"constitution": 15, "intellect": 12,
                           "charisma": 12, "courage": 31, "luck": 13},
            "skills": {"seamanship": 34, "navigation": 16, "swordplay": 10,
                       "gunnery": 9, "appraisal": 7, "negotiation": 9,
                       "cartography": 6, "rumour": 5, "medicine": 0,
                       "carpentry": 17, "cooking": 11},
            "personality": ["stoic"],
            "appearance": {"face": "round", "beard": "stubble",
                           "eyes": "pale_blue", "hair": "sun_bleached"},
        },
        "off_kemal_agha": {
            "main_skill": "gunnery",
            "attributes": {"constitution": 14, "intellect": 11,
                           "charisma": 12, "courage": 32, "luck": 10},
            "skills": {"seamanship": 14, "navigation": 10, "swordplay": 20,
                       "gunnery": 35, "appraisal": 5, "negotiation": 6,
                       "cartography": 3, "rumour": 9, "medicine": 0,
                       "carpentry": 12, "cooking": 7},
            "personality": ["pious", "stoic"],
            "appearance": {"face": "lean", "beard": "full", "eyes": "dark",
                           "hair": "black"},
        },
        "off_marco_bellini": {
            "main_skill": "navigation",
            "attributes": {"constitution": 12, "intellect": 15,
                           "charisma": 13, "courage": 14, "luck": 12},
            "skills": {"seamanship": 17, "navigation": 31, "swordplay": 6,
                       "gunnery": 5, "appraisal": 12, "negotiation": 10,
                       "cartography": 19, "rumour": 9, "medicine": 0,
                       "carpentry": 0, "cooking": 7},
            "personality": ["bookish", "patient"],
            "appearance": {"face": "lean", "beard": "clean", "eyes": "hazel",
                           "hair": "brown"},
        },
    }
    out: list[dict] = []
    for officer_id, v1 in starters_v1_by_id.items():
        conv = conversions[officer_id]
        out.append({
            "id": officer_id,
            "name": v1["name"],
            "nation_id": v1["nation_id"],
            "legend": False,
            "main_skill": conv["main_skill"],
            "attributes": conv["attributes"],
            "skills": conv["skills"],
            "personality": conv["personality"],
            "appearance": conv["appearance"],
            "wage_daily": v1["wage_daily"],
            "recruit_ports": list(v1["recruit_ports"]),
            "bio": v1["bio"],
        })
    return out


# --------------------------------------------------------------------------
# Post-build assertions (§8.6 / §8.7 pins the builder owns)
# --------------------------------------------------------------------------
def assert_captains(captains: list, quota_table: dict, quotas: dict,
                    parts: dict, officer_names: set, rare_ids: set,
                    port_ids: set) -> None:
    by_id: dict[str, dict] = {}
    names: dict[str, str] = {}
    for card in captains:
        cid = card["id"]
        if cid in by_id:
            raise BuildError(f"captain id repeated: {cid}")
        by_id[cid] = card
        for locale in ("zh", "en"):
            key = card["name"][locale]
            if key in names or key in officer_names:
                raise BuildError(
                    f"name reused across people ({locale}): {key!r}")
            names[key] = cid
        if cid in NAMED_PIRATE_IDS and not card.get("drop"):
            raise BuildError(f"named pirate {cid} lost its drop")
        if card.get("drop") and cid not in NAMED_PIRATE_IDS:
            raise BuildError(f"drop on non-named-pirate card {cid}")
        if card.get("drop") and card["drop"] not in rare_ids:
            raise BuildError(f"{cid}: drop {card['drop']} is not rare "
                             "equipment")
        if card.get("home_port") and card["home_port"] not in port_ids:
            raise BuildError(f"{cid}: home_port {card['home_port']} not in "
                             "ports")
        if card["role"] not in ROLE_ORDER:
            raise BuildError(f"{cid}: unknown role {card['role']}")
        lo, hi = ROLE_TIERS[card["role"]]
        if not lo <= card["tier"] <= hi:
            raise BuildError(f"{cid}: tier {card['tier']} outside the "
                             f"{card['role']} range {lo}–{hi}")
        if card["nation_id"] == "" and card["role"] not in ("pirate",
                                                            "coaster"):
            raise BuildError(f"{cid}: nationless card must be pirate or "
                             "coaster")
        if card["nation_id"] != "" and card["role"] == "pirate":
            raise BuildError(f"{cid}: pirates keep nation_id ''")
        pool = parts["personalities"]["roles"][card["role"]]
        if not 1 <= len(card["personality"]) <= 2 \
                or not set(card["personality"]) <= set(pool):
            raise BuildError(f"{cid}: personality {card['personality']} not "
                             f"within the {card['role']} pool")
        for axis in ("face", "beard", "eyes", "hair"):
            if card["appearance"].get(axis) not in parts["appearance"][axis]:
                raise BuildError(f"{cid}: bad appearance axis {axis}")
        for attr, value in card["attributes"].items():
            if not 1 <= value <= 100:
                raise BuildError(f"{cid}: attribute {attr} = {value} "
                                 "outside 1–100")
        for skill, value in card["skills"].items():
            if not 0 <= value <= 100:
                raise BuildError(f"{cid}: skill {skill} = {value} "
                                 "outside 0–100")
        if not card["legend"]:
            # §8.6 item 7, term by term
            tier = card["tier"]
            expected_level = 1 + tier * 4 + (2 if card["role"]
                                             in PIRATE_HUNTER else 0)
            if card["level"] != expected_level:
                raise BuildError(f"{cid}: level {card['level']} != "
                                 f"{expected_level}")
            main_attr, sec_attr, sig_skill, sec_skill = \
                ROLE_TEMPLATES[card["role"]]
            bands = {main_attr: (10 + 3 * tier - 3, 10 + 3 * tier + 3),
                     sec_attr: (10 + 2 * tier - 3, 10 + 2 * tier + 3)}
            for attr in ATTRS:
                lo_b, hi_b = bands.get(attr, (10 + tier - 3, 10 + tier + 3))
                v = card["attributes"][attr]
                if not lo_b <= v <= hi_b:
                    raise BuildError(f"{cid}: {attr} {v} outside the "
                                     f"generated band [{lo_b}, {hi_b}]")
            if card["role"] == "coaster":
                if any(card["skills"].values()):
                    raise BuildError(f"{cid}: coaster must carry no skills")
            else:
                if not 8 * tier <= card["skills"][sig_skill] <= 8 * tier + 6:
                    raise BuildError(f"{cid}: signature skill outside "
                                     f"[{8 * tier}, {8 * tier + 6}]")
                if card["skills"][sec_skill] != 4 * tier:
                    raise BuildError(f"{cid}: secondary skill != {4 * tier}")
                for skill, v in card["skills"].items():
                    if skill not in (sig_skill, sec_skill) and v != 0:
                        raise BuildError(f"{cid}: {skill} must be 0")

    # quota_table == actual cells; per-role totals ≥ the derived rows
    actual: dict[tuple[str, int, str], int] = {}
    for card in captains:
        key = (card["role"], card["tier"], card["nation_id"])
        actual[key] = actual.get(key, 0) + 1
    for (role, tier, nation), count in quotas["cells"].items():
        if actual.get((role, tier, nation), 0) != count:
            raise BuildError(
                f"quota cell {role}/t{tier}/{nation or '""'}: table says "
                f"{count}, roster holds "
                f"{actual.get((role, tier, nation), 0)}")
    for role in ROLE_ORDER:
        got = sum(v for (r, _t, _n), v in actual.items() if r == role)
        want = sum(v for (r, _t, _n), v in quotas["cells"].items()
                   if r == role)
        if got < want:
            raise BuildError(f"role {role}: {got} cards < derived {want}")
    # quota_table echoes the cells it records
    for role, row in quota_table.items():
        if role == "treasure":
            continue
        for key, cell in row.items():
            if not key.isdigit():
                continue
            for nation, count in cell.items():
                if actual.get((role, int(key), nation), 0) != count:
                    raise BuildError(
                        f"quota_table[{role}][{key}][{nation}] {count} != "
                        f"roster {actual.get((role, int(key), nation), 0)}")


def assert_officers(officers: list, parts: dict, captain_names: set,
                    ports_by_nation: dict, port_ids: set,
                    starter_ids: tuple) -> None:
    if len(officers) != OFFICER_TOTAL:
        raise BuildError(f"officer roster: {len(officers)} != "
                         f"{OFFICER_TOTAL}")
    legends = [o for o in officers if o["legend"]]
    if len(legends) != LEGEND_COUNT:
        raise BuildError(f"legends: {len(legends)} != {LEGEND_COUNT}")
    names = dict(captain_names)
    specialty: dict[str, int] = {s: 0 for s in OFFICER_SKILLS}
    captain_qualified = 0
    native_roles = set()
    for officer in officers:
        oid = officer["id"]
        for locale in ("zh", "en"):
            key = officer["name"][locale]
            if key in names:
                raise BuildError(f"name reused across people ({locale}): "
                                 f"{key!r}")
            names[key] = oid
        if set(officer["attributes"]) != set(ATTRS):
            raise BuildError(f"{oid}: attributes must carry exactly the 5 "
                             "keys")
        if set(officer["skills"]) != set(OFFICER_SKILLS):
            raise BuildError(f"{oid}: skills must carry exactly the 11 keys")
        for attr, v in officer["attributes"].items():
            if not 1 <= v <= 100:
                raise BuildError(f"{oid}: attribute {attr} = {v} outside "
                                 "1–100")
        for skill, v in officer["skills"].items():
            if not 0 <= v <= 100:
                raise BuildError(f"{oid}: skill {skill} = {v} outside "
                                 "0–100")
        main = officer["main_skill"]
        band = LEGEND_MAIN_BAND if officer["legend"] else REGULAR_MAIN_BAND
        if not band[0] <= officer["skills"][main] <= band[1]:
            raise BuildError(f"{oid}: main skill {officer['skills'][main]} "
                             f"outside the {band} band")
        others = [v for s, v in officer["skills"].items() if s != main]
        if others and max(others) >= officer["skills"][main]:
            raise BuildError(f"{oid}: main_skill is not the strict maximum")
        wage = officer["wage_daily"]
        wband = LEGEND_WAGE_BAND if officer["legend"] else REGULAR_WAGE_BAND
        if not wband[0] <= wage <= wband[1]:
            raise BuildError(f"{oid}: wage {wage} outside the {wband} band")
        for axis in ("face", "beard", "eyes", "hair"):
            if officer["appearance"].get(axis) not in parts["appearance"][axis]:
                raise BuildError(f"{oid}: bad appearance axis {axis}")
        for locale in ("zh", "en"):
            if not officer["bio"][locale].strip():
                raise BuildError(f"{oid}: bio.{locale} empty")
        if not officer["recruit_ports"]:
            raise BuildError(f"{oid}: recruit_ports empty")
        for pid in officer["recruit_ports"]:
            if pid not in port_ids:
                raise BuildError(f"{oid}: recruit port {pid} not in ports")
        # native role from the signature map (§4.5/§2.7); the seamanship
        # mains are checked against the boatswain ∪ captain pools.
        sig = officer["skills"][main]
        native_roles.add(main)
        if main == "navigation":
            pool_ids = ("pilot",)
        elif main == "seamanship":
            pool_ids = ("boatswain", "captain")
        elif main == "gunnery":
            pool_ids = ("gunner",)
        elif main == "medicine":
            pool_ids = ("surgeon",)
        elif main == "carpentry":
            pool_ids = ("carpenter",)
        elif main == "cooking":
            pool_ids = ("cook",)
        elif main == "swordplay":
            pool_ids = ("captain",)
        else:
            raise BuildError(f"{oid}: {main} maps to no native role")
        pool = set().union(*(parts["personalities"]["roles"][p]
                             for p in pool_ids))
        if not 1 <= len(officer["personality"]) <= 2 \
                or not set(officer["personality"]) <= pool:
            raise BuildError(f"{oid}: personality {officer['personality']} "
                             f"not within the {pool_ids} pool(s)")
        if officer["legend"]:
            if main == "seamanship" \
                    and not set(officer["personality"]) <= \
                    set(parts["personalities"]["roles"]["boatswain"]):
                raise BuildError(f"{oid}: seamanship-main legend must draw "
                                 "the boatswain pool (boatswain/captain "
                                 "ambiguity)")
            nation = officer["nation_id"]
            if not set(officer["recruit_ports"]) <= \
                    set(ports_by_nation.get(nation, [])):
                raise BuildError(f"{oid}: legend recruit_ports not a subset "
                                 f"of {nation}'s ports")
        elif oid not in starter_ids:
            nation = officer["nation_id"]
            if not set(officer["recruit_ports"]) <= \
                    set(ports_by_nation.get(nation, [])):
                raise BuildError(f"{oid}: regular recruit_ports not a subset "
                                 f"of {nation}'s ports")
        for skill, v in officer["skills"].items():
            if v >= SPECIALTY_THRESHOLD:
                specialty[skill] += 1
        if officer["skills"]["seamanship"] >= 25 \
                and officer["attributes"]["courage"] >= 30:
            captain_qualified += 1
    missing_roles = {"navigation", "seamanship", "gunnery", "medicine",
                     "carpentry", "cooking", "swordplay"} - native_roles
    if missing_roles:
        raise BuildError(f"native roles missing from the roster: "
                         f"{sorted(missing_roles)} (main_skill ids)")
    for skill, carriers in specialty.items():
        if carriers < SPECIALTY_MIN_CARRIERS:
            raise BuildError(f"specialty {skill}: {carriers} carriers at "
                             f"≥{SPECIALTY_THRESHOLD} < "
                             f"{SPECIALTY_MIN_CARRIERS}")
    if captain_qualified < CAPTAIN_QUALIFIED_MIN:
        raise BuildError(f"captain-qualified officers: {captain_qualified} "
                         f"< {CAPTAIN_QUALIFIED_MIN}")
    if len(legends) != len({o["id"] for o in legends}):
        raise BuildError("legend ids repeated")


# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------
def build() -> tuple[dict, dict, dict, dict]:
    parts = load_json(PARTS_PATH)
    config = load_json(CONFIG_PATH)
    ports = load_json(PORTS_PATH)["ports"]
    nations = load_json(NATIONS_PATH)["nations"]
    equipment = load_json(EQUIPMENT_PATH)["equipment"]
    captain_overrides = load_json(CAPTAIN_OVERRIDES_PATH)
    officer_overrides = load_json(OFFICER_OVERRIDES_PATH)

    rare_ids = {e["id"] for e in equipment if e.get("rare")}
    port_ids = {p["id"] for p in ports}
    ports_by_nation: dict[str, list[str]] = {}
    for port in ports:
        ports_by_nation.setdefault(port["nation_id"], []).append(port["id"])
    for nation_id in ports_by_nation:
        ports_by_nation[nation_id].sort()
    nation_names = {n["id"]: n["name"] for n in nations}

    rng = seed_rng()
    used: set[tuple[str, str]] = set()

    legend_cards = [canon_legend(c) for c
                    in captain_overrides["legend_captains"]]
    legend_officers = [canon_officer(o) for o
                       in officer_overrides["legend_officers"]]
    if len(legend_cards) != 24:
        raise BuildError(f"captain overrides: {len(legend_cards)} != 24")
    if len(legend_officers) != LEGEND_COUNT:
        raise BuildError(f"officer overrides: {len(legend_officers)} != "
                         f"{LEGEND_COUNT}")
    pirates = [c for c in legend_cards if c["id"] in NAMED_PIRATE_IDS]
    if len(pirates) != len(NAMED_PIRATE_IDS):
        raise BuildError("the 4 named-pirate overrides are required")
    for card in legend_cards:
        if card["id"] in NAMED_PIRATE_IDS:
            if card.get("drop") not in rare_ids:
                raise BuildError(f"{card['id']}: drop must reference rare "
                                 "equipment")
            if card["nation_id"] != "" or card["role"] != "pirate":
                raise BuildError(f"{card['id']}: nationless pirate shape")
    seen_ids = set()
    for card in legend_cards:
        if card["id"] in seen_ids:
            raise BuildError(f"captain override id repeated: {card['id']}")
        seen_ids.add(card["id"])
    seen_ids = set()
    for officer in legend_officers:
        if officer["id"] in seen_ids:
            raise BuildError(f"officer override id repeated: "
                             f"{officer['id']}")
        seen_ids.add(officer["id"])
    if len({o["nation_id"] for o in legend_officers}) != 6:
        raise BuildError("legend officers must spread over all 6 nations")

    # Register every hand-authored name BEFORE any draw (§4.11.1).
    for card in legend_cards:
        used.add((card["name"]["zh"], card["name"]["en"]))
    for officer in legend_officers:
        used.add((officer["name"]["zh"], officer["name"]["en"]))
    starters_v1 = STARTERS_V1
    for officer in starters_v1.values():
        used.add((officer["name"]["zh"], officer["name"]["en"]))

    quotas = derive_quotas(config, ports, nations)
    quota_table = build_quota_table(quotas)
    bank = NameBank(parts, rng, used)

    # --- captains: legend cards first in their cell, generation fills ----
    captains: list[dict] = []
    counters: dict[str, int] = {}
    for role in ROLE_ORDER:
        idx = 1
        lo, hi = ROLE_TIERS[role]
        cell_nations = sorted({n for (r, _t, n) in quotas["cells"]
                               if r == role}) if role != "hunter" \
            else sorted(nation_names)
        for tier in range(lo, hi + 1):
            for nation_id in cell_nations:
                cell_count = quotas["cells"].get((role, tier, nation_id), 0)
                in_cell = [c for c in legend_cards
                           if c["role"] == role and c["tier"] == tier
                           and c["nation_id"] == nation_id]
                captains.extend(in_cell)
                for _ in range(cell_count - len(in_cell)):
                    if idx > 9999:
                        raise BuildError(f"role {role}: id space exhausted")
                    name = bank.draw(nation_id)
                    captains.append(generate_captain(
                        f"cap_{role}_{idx:04d}", name, role, tier, nation_id,
                        parts, rng))
                    idx += 1
        counters[role] = idx - 1
    assert_captains(captains, quota_table, quotas, parts,
                    {(o["name"]["zh"], o["name"]["en"])
                     for o in legend_officers}
                    | {(o["name"]["zh"], o["name"]["en"])
                       for o in starters_v1.values()},
                    rare_ids, port_ids)

    # --- officers: legends (overrides) → generated regulars → starters ---
    officers: list[dict] = list(legend_officers)
    roster_index = LEGEND_COUNT
    id_counters: dict[str, int] = {}
    for group, count, main_skill in GEN_PLAN:
        pool_nations = sorted(nation_names)
        prefix = group.split("_")[0]
        for j in range(count):
            nation_id = pool_nations[j % len(pool_nations)]
            id_counters[prefix] = id_counters.get(prefix, 0) + 1
            officer_id = f"off_reg_{prefix}_{id_counters[prefix]:02d}"
            name = bank.draw(nation_id)
            officers.append(generate_officer(
                officer_id, name, nation_id, group, main_skill, roster_index,
                j, ports_by_nation[nation_id], nation_names[nation_id],
                parts, rng))
            roster_index += 1
    officers.extend(starters_v2(starters_v1))
    if len(officers) != OFFICER_TOTAL:
        raise BuildError(f"officer roster built to {len(officers)}, "
                         f"expected {OFFICER_TOTAL}")
    seen_ids: set[str] = set()
    for officer in officers:
        if officer["id"] in seen_ids:
            raise BuildError(f"officer id repeated: {officer['id']}")
        seen_ids.add(officer["id"])
    starter_ids = tuple(starters_v1)
    captain_names = {(c["name"]["zh"], c["name"]["en"]) for c in captains}
    assert_officers(officers, parts, captain_names, ports_by_nation,
                    port_ids, starter_ids)

    # --- named_pirates.json v2: the bounty-facing copies (§4.12) ---------
    by_id = {c["id"]: c for c in captains}
    pirate_cards = [by_id[pid] for pid in NAMED_PIRATE_IDS]
    named_pirates = {"version": 2, "named_pirates": pirate_cards}

    captains_doc = {
        "version": 1,
        "generated_by": "tools/build_captains.py",
        "artifact": "data/captains.json",
        "build": {
            "seed": SEED,
            "sources": [
                "data/captain_name_parts.json",
                "data/npc_config.json",
                "data/ports.json",
                "data/nations.json",
                "data/equipment.json",
                "tools/captain_overrides.json",
                "tools/officer_overrides.json",
            ],
            "parts": "data/captain_name_parts.json",
            "overrides": ["tools/captain_overrides.json",
                          "tools/officer_overrides.json"],
            "coverage_preset": COVERAGE_PRESET,
        },
        "quota_table": quota_table,
        "captains": captains,
    }
    officers_doc = {"version": 2, "officers": officers}
    report = {
        "captains": len(captains),
        "per_role": {role: counters[role] + len([c for c in legend_cards
                                                 if c["role"] == role])
                     for role in ROLE_ORDER},
        "officers": len(officers),
        "legends": LEGEND_COUNT,
        "captain_qualified": sum(
            1 for o in officers if o["skills"]["seamanship"] >= 25
            and o["attributes"]["courage"] >= 30),
        "specialty_carriers": {
            skill: sum(1 for o in officers if o["skills"][skill] >= 20)
            for skill in OFFICER_SKILLS},
    }
    return captains_doc, officers_doc, named_pirates, report


# --------------------------------------------------------------------------
# Serialization + --check differ (build_routes.py pattern)
# --------------------------------------------------------------------------
def serialize(doc: dict) -> bytes:
    return (json.dumps(doc, indent=2, ensure_ascii=False) + "\n").encode(
        "utf-8")


def diff_json_path(a, b, path: str = "$"):
    if type(a) is not type(b):
        return path
    if isinstance(a, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                return f"{path}.{key}"
            hit = diff_json_path(a[key], b[key], f"{path}.{key}")
            if hit:
                return hit
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return f"{path} (length {len(a)} vs {len(b)})"
        for i, (xa, xb) in enumerate(zip(a, b)):
            hit = diff_json_path(xa, xb, f"{path}[{i}]")
            if hit:
                return hit
        return None
    return None if a != b else None


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Build data/captains.json, data/officers.json (v2) and "
                    "data/named_pirates.json (v2) from the name parts, the "
                    "quota derivation and the legend overrides "
                    "(deterministic; two builds are byte-identical).",
    )
    parser.add_argument(
        "--check", action="store_true",
        help="rebuild in memory and byte-compare against the committed "
             "artifacts; exit 3 naming the first differing JSON path on "
             "drift",
    )
    parser.add_argument(
        "--report", action="store_true",
        help="print the JSON build report to stdout after the build",
    )
    args = parser.parse_args(argv)

    try:
        captains_doc, officers_doc, named_pirates, report = build()
    except BuildError as exc:
        print(f"build_captains: FAIL: {exc}", file=sys.stderr)
        return 2

    products = (
        (CAPTAINS_PATH, captains_doc),
        (OFFICERS_PATH, officers_doc),
        (NAMED_PIRATES_PATH, named_pirates),
    )
    if args.check:
        for path, doc in products:
            committed = path.read_bytes() if path.exists() else b""
            fresh = serialize(doc)
            if committed != fresh:
                hit = None
                if committed:
                    try:
                        hit = diff_json_path(json.loads(committed),
                                             json.loads(fresh))
                    except json.JSONDecodeError:
                        hit = "(unparseable committed file)"
                print(f"build_captains: DRIFT: {path.relative_to(ROOT)}"
                      f"{(' at ' + hit) if hit else ''}",
                      file=sys.stderr)
                return 3
        print("build_captains: --check ok (3 files byte-identical)",
              file=sys.stderr)
        return 0

    for path, doc in products:
        blob = serialize(doc)
        path.write_bytes(blob)
        print(f"build_captains: wrote {path.relative_to(ROOT)} ({len(blob)} "
              f"bytes, sha256 {hashlib.sha256(blob).hexdigest()})",
              file=sys.stderr)
    per_role = report["per_role"]
    total = sum(per_role.values())
    print(
        "build_captains: "
        + " / ".join(f"{role} {per_role[role]}" for role in ROLE_ORDER)
        + f" | total {total} cards | officers {report['officers']} "
        f"({report['legends']} legend) | captain-qualified "
        f"{report['captain_qualified']}",
        file=sys.stderr,
    )
    if args.report:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
