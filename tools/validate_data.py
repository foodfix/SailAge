#!/usr/bin/env python3
"""SailAge data validator.

Implements check groups 1-13 of docs/10-DATA-SCHEMA.md section 8. Group 6 is
the generated world-map artifact check (section 8.1): it decodes
``data/maps/world.png`` with a stdlib PNG reader, recomputes every harbor tile
independently from ``lat``/``lon`` and compares it with
``data/maps/world_report.json``, then proves every harbor and discovery is
reachable from Lisbon by a wrap-aware 8-directional BFS that forbids corner
cutting (docs/20-WORLD-AND-SAILING.md section 4.2). Group 7 is the Phase-5
npc & economy data check (section 8.2): the density-dial config bounds, the
v2 named-pirate cards (full captain cards, field-for-field equal to their
canon copies, with the rare ``drop`` pairing), the demand-event templates
with their rest-band shift bounds, the consumption-tier split, and the
§4.19 facility-hours sub-block. Group 8 is the
trade-route check (section 8.3): the locked 21-lane id set, waypoint snap and
segment passability (shared with ``tools/build_routes.py``), the §4.14
walk-aware spoke rule for every port, the named junction-graph probes, and
the byte-exact rebuild equality of the tool-owned
``data/trade_routes_built.json``. Group 9 is the Phase-6 ocean-raster check
(section 8.4): both rasters decode as 4320x2160 indexed PNGs, palette bounds
per the §6.5 encodings, water coverage against ``world.png``, and the
byte-exact ``tools/build_ocean.py`` rebuild. Group 10 is the Phase-6 ice &
lane-variant check (section 8.5): ``ice_regions.json`` structure, lane
variant month coverage, and per-month-window passability under the in-month
ice mask. Group 11 is the Phase-8 captain-canon check (section 8.6): the
built ``data/captains.json`` envelope, every card's §4.11 shape and the
generated cards' formulas re-asserted term-by-term, the extreme-preset quota
coverage re-derived independently from ``npc_config`` × ``ports`` ×
``nations``, the artifact ``quota_table`` vs the roster cells, the
``tools/build_captains.py --check`` byte-identical rebuild, and name
uniqueness across the canon and the officer roster. Group 12 is the Phase-8
RPG-data check (section 8.7): the officers v2 roster quotas (bands, specialty
coverage, captain-qualified, recruit ports, native-role personality pools),
the §4.20 skill gates, the §4.21 officer posts with their locked prereqs and
advice strings, the §4.22 backgrounds, and the §7.11 ui_strings Phase-8
family presence. Group 13 is the Phase-10 generated-art check (section
8.8): the ``tools/ui_art/<class>/`` manifests vs the ``assets/ui/``
artifacts (inventory equality, shape/size, palette-block membership, color
budgets, 8-direction transform relations, chrome seam torus rules, terrain
rings, hull remap grid + tier footprint bands, shore-strip foam bands), the
``data/maps/world_shore.png`` §6.6 integrity, the ``art_prompts.json``
coverage, and the byte-identical ``build_ui_art.py`` / ``build_shore.py``
rebuilds. The class checks are staged: a contract class with no manifests is
skipped with an informational note; artifacts are checked only where they
exist. Group 13 ends with its six negative probes (off-palette pixel,
corrupted artifact, broken transform relation, out-of-band footprint,
invalid shore code, seam violation) proven red against temp fixtures.

Usage (from the repo root):

    python3 tools/validate_data.py
    python3 tools/validate_data.py --verbose
    python3 tools/validate_data.py --self-test-g6      # negative harness
    python3 tools/validate_data.py --self-test-g9      # negative harness
    python3 tools/validate_data.py --self-test-g10     # negative harness

Exit codes:

    0   all checks pass
    1   parse & envelope failure
    2   i18n failure
    3   schema failure
    4   referential integrity failure
    5   locked-list failure
    6   world map failure (data/maps/world.png / world_report.json)
    7   npc & economy data failure (npc_config / named_pirates /
        market_events / facility_hours)
    8   trade-route failure (trade_routes / trade_routes_built /
        route_overrides)
    9   ocean-raster failure (wind_regions.png / currents.png)
    10  ice & lane-variant failure (ice_regions / trade_routes variants)
    11  captain-canon failure (captains.json / officers.json rebuild /
        quota coverage / name uniqueness)
    12  RPG-data failure (officers v2 quotas / skill_gates / officer_posts /
        backgrounds / ui_strings Phase-8 families)
    13  generated-art failure (assets/ui manifests+artifacts / world_shore.png
        / art_prompts.json / group-13 probe harness)

On the first failure a single line is printed to stdout:

    FAIL <check-id> <file> <details>

and the process exits with that check group's code.

``--self-test-g6`` (or ``SAILAGE_G6_SELFTEST=1``), ``--self-test-g9`` and
``--self-test-g10`` run the mutation harnesses instead of the normal checks:
each mutates in-memory copies (g9's one-byte case restores the committed
raster inside a try/finally) and asserts that the group goes red, naming the
expected entity. They never leave real data changed and exit 0 only when
every negative case fails as required.

Phase 7 (task T): ``--data-root PATH`` (or the ``SAILAGE_DATA_ROOT`` env)
checks a different checkout's ``data/`` tree — the staged-sim protocol (W2)
validates the G/S/P content branches through this flag before anything
merges. PATH is either the checkout root or its ``data/`` directory. Without
the flag every path derives from ``Path(__file__).parent.parent / "data"``
exactly as before and the default behavior is unchanged. When the override
points into another checkout that carries its own ``tools/build_routes.py``,
group 8's rebuild-determinism check runs THAT builder over THAT tree (the
merged sources must rebuild byte-identically where they live).
"""

from __future__ import annotations

import copy
import hashlib
import json
import math
import os
import re
import struct
import sys
import tempfile
import zlib
from collections import deque
from pathlib import Path
import hashlib

REPO_ROOT = Path(__file__).resolve().parent.parent


def _default_data_dir() -> Path:
    return REPO_ROOT / "data"


def _resolve_data_dir(raw: str | None) -> Path:
    """Resolve the data directory from an override value.

    Accepts either the checkout root (a directory containing ``data/``) or the
    ``data/`` directory itself. Empty/None keeps the locked default
    ``Path(__file__).parent.parent / "data"`` — byte-identical behavior.
    """
    default = _default_data_dir()
    if not raw:
        return default
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = (Path.cwd() / path).resolve()
    else:
        path = path.resolve()
    if path.name == "data" or (path / "ports.json").is_file():
        return path
    return path / "data"


# The env override is read at import so every module-level path constant below
# (WORLD_PNG, WIND_PNG, …) picks it up; the --data-root flag re-execs with the
# env set (one resolution point, one code path).
DATA_DIR = _resolve_data_dir(os.environ.get("SAILAGE_DATA_ROOT"))

# Group 8 shares the lane builder's geometry (docs/10-* §8.3 preamble: same
# PNG decoder; sharing build_world.py's reader is allowed). Using
# tools/build_routes.py's own snap/walk helpers here means the validator and
# the builder can never disagree about the locked waypoint rule, the segment
# walk or the spoke pathfinding; the world-grid decode is the same stdlib
# reader group 6 uses for its own grid.
sys.path.insert(0, str(REPO_ROOT / "tools"))
import build_routes as route_builder  # noqa: E402

if DATA_DIR != _default_data_dir():
    # Staged-sim protocol (task T, W2): point the imported builder's path
    # constants at the overridden tree so group 8's snap/spoke/rebuild checks
    # read the staged data and its route_overrides.json. The rebuild
    # determinism check (_check_trade_determinism) prefers the overridden
    # checkout's own builder, so the merged sources rebuild where they live.
    _override_tree = DATA_DIR.parent
    route_builder.ROOT = _override_tree
    route_builder.DATA = DATA_DIR
    route_builder.TOOLS = _override_tree / "tools"
    route_builder.LANES_PATH = DATA_DIR / "trade_routes.json"
    route_builder.PORTS_PATH = DATA_DIR / "ports.json"
    route_builder.NATIONS_PATH = DATA_DIR / "nations.json"
    route_builder.ICE_PATH = DATA_DIR / "ice_regions.json"
    route_builder.OVERRIDES_PATH = route_builder.TOOLS / "route_overrides.json"
    route_builder.WORLD_PNG = DATA_DIR / "maps" / "world.png"
    route_builder.BUILT_PATH = DATA_DIR / "trade_routes_built.json"
    route_builder.INPUT_SOURCES = tuple(
        (name, path)
        for name, path in (
            ("trade_routes", route_builder.LANES_PATH),
            ("ports", route_builder.PORTS_PATH),
            ("nations", route_builder.NATIONS_PATH),
            ("ice_regions", route_builder.ICE_PATH),
            ("route_overrides", route_builder.OVERRIDES_PATH),
            ("world_png", route_builder.WORLD_PNG),
        )
    )

# ---------------------------------------------------------------------------
# Contract tables (docs/10-DATA-SCHEMA.md sections 3, 6, 7)
# ---------------------------------------------------------------------------

ID_RE = re.compile(r"^[a-z][a-z0-9_]*$")
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
MARKER_RE = re.compile(r"^[0-9a-t]$")
PLACEHOLDER_RE = re.compile(r"\{([A-Za-z0-9_]+)\}")

MAP_WIDTH = 4320
MAP_HEIGHT = 2160

# docs/10-DATA-SCHEMA.md section 6.2 -- char -> (kind, passable)
LOCKED_TILE_KINDS = {
    "~": ("sea", True),
    ".": ("coastal_sea", True),
    "#": ("land", False),
    "^": ("reef", False),
    "I": ("polar_ice", False),
}

GOOD_CATEGORIES = ("food", "textile", "luxury", "material")
SHIP_CLASSES = ("sail", "oar", "hybrid")
# Phase 7 (10-* §4.3): hull vocation enum, locked wording (task A pins).
SHIP_ROLES = ("war", "trade", "coastal")
# §6.1 locked ship-speed set (tiles/day) — every hull's final value lies in it.
LOCKED_SHIP_SPEEDS = frozenset({16, 20, 24})
EQUIPMENT_SLOTS = ("weapon", "armor", "figurehead", "sail")
DISCOVERY_CATEGORIES = ("natural", "ruins", "relic", "creature")
QUEST_TYPES = ("delivery", "bounty", "exploration", "royal")
QUEST_GIVERS = ("guild", "palace")

# docs/50-CHARACTER-AND-PROGRESSION.md section 4.2 (player) and
# docs/40-SHIPS-AND-FLEET.md (ship instance stats), for equipment modifiers.
# (The v1 OFFICER_ROLES / OFFICER_STAT_NAMES retired with the v1 officer
# schema — Phase 8's person card uses PERSON_ATTRIBUTES / OFFICER_SKILL_NAMES.)
PLAYER_STAT_NAMES = ("leadership", "seamanship", "combat", "navigation", "luck")
SHIP_STAT_NAMES = ("durability", "capacity", "speed", "crew_max", "armament_slots")
EQUIPMENT_STAT_NAMES = frozenset(PLAYER_STAT_NAMES + SHIP_STAT_NAMES)
# Phase 7 (10-* §4.6 / 60-* §4.11.12): the two sideways modifier keys join the
# equipment modifier vocabulary — `storm_damage_pct` (−%, multiplies
# `storm_damage_for`) and `scurvy_delay_days`.
EQUIPMENT_SIDEWAYS_KEYS = frozenset({"storm_damage_pct", "scurvy_delay_days"})

# Facility activation phases (docs/10-DATA-SCHEMA.md section 4.4).
FACILITY_PHASES = {
    "market": 1,
    "shipyard": 1,
    "tavern": 1,
    "inn": 1,
    "guild": 3,
    "palace": 3,
}
# Every sovereign Phase-1 port has these; `palace` only for the 6 capitals.
# Phase 7: `shipyard` holds an id ARRAY (2–8 hulls, §4.4 — the int form is
# retired) and `equipment_stock` holds an id array (≥ 2) at shipyard ports;
# both live outside FACILITY_PHASES' int-locked values.
PORT_FACILITIES_REQUIRED = ("market", "shipyard", "tavern", "inn", "guild")
# Array-valued facility keys (Phase 7, §4.4).
FACILITY_ARRAY_KEYS = frozenset({"shipyard", "equipment_stock"})
SHIPYARD_STOCK_MIN = 2
SHIPYARD_STOCK_MAX = 8
EQUIPMENT_STOCK_MIN = 2
# Phase-6 neutral tier (§7.1): `nation_id: ""`, frontier markets — facilities
# are data-driven per port over the phase-1 keys only; `guild`/`palace` are
# sovereign institutions the tier never carries. Phase 7 adds the two array
# keys where a neutral port authors a shipyard.
NEUTRAL_FACILITY_KEYS = frozenset(
    {"market", "shipyard", "tavern", "inn", "equipment_stock"})
NEUTRAL_PORT_NATION_ID = ""

# Entity file -> the single plural key of its envelope.
ENTITY_FILES = {
    "nations.json": "nations",
    "goods.json": "goods",
    "ship_types.json": "ship_types",
    "ports.json": "ports",
    "officers.json": "officers",
    "equipment.json": "equipment",
    "discoveries.json": "discoveries",
    "quests.json": "quests",
    # Phase 5: named_pirates.json / market_events.json match their filenames,
    # trade_routes.json's plural key is `lanes` (§4.14). Phase 8 retired
    # npc_captains.json from this table — the name pools are gone (§7.7; W4-B
    # deleted the file and group 11 asserts its absence, §8.6 item 1).
    "named_pirates.json": "named_pirates",
    "market_events.json": "market_events",
    "trade_routes.json": "lanes",
    # Phase 8 (W2-B files, §4.20–4.22): plural == basename, no exception.
    "skill_gates.json": "skill_gates",
    "officer_posts.json": "officer_posts",
    "backgrounds.json": "backgrounds",
}

# Phase 8 (§4.11): captains.json is a *tool output* (§8 group-1 exception —
# key `captains` plus the builder's envelope block), never hand-edited; its
# shape is owned by group 11. The allowed extras are the §4.11 envelope keys.
TOOL_OUTPUT_FILES = {
    "captains.json": {
        "plural": "captains",
        "allowed_extra": {"generated_by", "artifact", "build", "quota_table"},
    },
}

# Files with a bespoke envelope / no plural entity key (section 3.2, 4.9).
SPECIAL_FILES = {
    "map_legend.json", "ui_strings.json", "maps.json",
}
# Envelope exemption for a file that is *generated* rather than authored: its
# shape is pinned by the owning doc (docs/10-* §4.14 / §6.3) and has no plural
# array. Both are tool outputs (tools/build_world.py, tools/build_routes.py)
# and are never hand-edited; determinism of trade_routes_built.json is group
# 8's rebuild check.
GENERATED_FILES = {"world_report.json", "trade_routes_built.json",
    "harbors.json"}
SPECIAL_FILES |= GENERATED_FILES
# Of those, only the legends require `version` in their section 4.9 schema.
# ui_strings.json (owned by T4) may omit it; section 8 group 2 treats `version`
# as the one key that is not an L10nString rather than a required field.
SPECIAL_REQUIRE_VERSION = {"map_legend.json"}
# Phase 5 (section 8, group 1): npc_config.json is a config block (§4.10), not
# an entity file — its shape is owned by group 7.
SPECIAL_FILES.add("npc_config.json")
SPECIAL_REQUIRE_VERSION.add("npc_config.json")
# Port hours (added 2026-11-02): facility_hours.json is a config block
# (§4.19), not an entity file — its shape is a group-7 sub-block.
SPECIAL_FILES.add("facility_hours.json")
SPECIAL_REQUIRE_VERSION.add("facility_hours.json")
# Phase 8 (§4.11.1): captain_name_parts.json is the builder's authored
# multi-block source (names/personality/appearance/officer_bios) — a plain
# object file like npc_config.json, group-1 exception; group 11 owns its
# vocabularies.
SPECIAL_FILES.add("captain_name_parts.json")
SPECIAL_REQUIRE_VERSION.add("captain_name_parts.json")

# L10nString field names per entity file (docs/10 section 4). The i18n check
# walks each entity recursively and validates every value under one of these
# keys, which also covers quests.requirements.objective.
L10N_FIELDS = {
    "nations": ("name", "description"),
    "goods": ("name",),
    "ship_types": ("name",),
    "ports": ("name", "flavor"),
    "officers": ("name", "bio"),
    "equipment": ("name",),
    "discoveries": ("name", "region_hint"),
    "quests": ("name", "description", "objective"),
    # Phase 5: pirates/events carry their display string in `name`.
    "named_pirates": ("name",),
    "market_events": ("name",),
    # §4.14: lanes carry no display strings (ids, numeric waypoints, id lists);
    # the walker's locale-key heuristic still guards any stray zh/en object.
    "lanes": (),
    # Phase 8 (§4.20–4.22): the gate display name + "why locked" line, the
    # post description and the background card strings.
    "skill_gates": ("name", "reason"),
    "officer_posts": ("desc",),
    "backgrounds": ("name", "bio"),
}

# --- Locked content tables (docs/10-DATA-SCHEMA.md section 7) --------------
# Phase 7 (task T, 10-* §8 group 5 lock model): goods lock to the exact 40-id
# §7.2 set, authored-to-final (no sim loop over this table). The original 20
# keep their locked zh/en/category/base_price ("prices locked" — §7.2); the 20
# Phase-7 rows are task-owned by G and finalized from the staged branch
# (correction 14): id: (zh, en, category, base_price)
LOCKED_GOODS = {
    "wheat": ("小麦", "Wheat", "food", 8),
    "olive_oil": ("橄榄油", "Olive Oil", "food", 22),
    "wine": ("葡萄酒", "Wine", "food", 30),
    "wool": ("羊毛", "Wool", "textile", 18),
    "cotton_cloth": ("棉布", "Cotton Cloth", "textile", 45),
    "silk": ("丝绸", "Silk", "textile", 120),
    "spices": ("香料", "Spices", "luxury", 150),
    "sugar": ("糖", "Sugar", "food", 40),
    "salt": ("盐", "Salt", "food", 12),
    "dried_fish": ("鱼干", "Dried Fish", "food", 10),
    "timber": ("木材", "Timber", "material", 15),
    "iron": ("铁", "Iron", "material", 35),
    "copper": ("铜", "Copper", "material", 50),
    "glassware": ("玻璃器皿", "Glassware", "luxury", 60),
    "leather": ("皮革", "Leather", "material", 28),
    "ceramics": ("陶瓷", "Ceramics", "material", 25),
    "perfume": ("香水", "Perfume", "luxury", 90),
    "carpet": ("地毯", "Carpet", "textile", 80),
    "amber": ("琥珀", "Amber", "luxury", 110),
    "cheese": ("奶酪", "Cheese", "food", 16),
    # -- Phase-7 rows (task G, staged 2026-11-02; §7.2 skeleton ids) ----------
    "rice": ("稻米", "Rice", "food", 8),
    "pitch": ("沥青", "Pitch", "material", 12),
    "linen": ("亚麻布", "Linen", "textile", 35),
    "furs": ("毛皮", "Furs", "material", 60),
    "dye_wood": ("苏木", "Sappanwood", "material", 55),
    "indigo": ("靛蓝", "Indigo", "material", 70),
    "ivory": ("象牙", "Ivory", "material", 85),
    "sandalwood": ("檀香", "Sandalwood", "material", 75),
    "coffee": ("咖啡", "Coffee", "food", 65),
    "tobacco": ("烟草", "Tobacco", "food", 50),
    "tea": ("茶", "Tea", "food", 55),
    "rhubarb": ("大黄", "Rhubarb", "material", 85),
    "raw_silk": ("生丝", "Raw Silk", "textile", 95),
    "porcelain": ("瓷器", "Porcelain", "luxury", 130),
    "pearls": ("珍珠", "Pearls", "luxury", 140),
    "gems": ("宝石", "Gems", "luxury", 180),
    "musk": ("麝香", "Musk", "luxury", 170),
    "lacquerware": ("漆器", "Lacquerware", "luxury", 110),
    "silver": ("白银", "Silver", "material", 105),
    "gold": ("黄金", "Gold", "material", 200),
}

# id: (zh, en, class, role, tier, base_price, durability, capacity, speed,
#      crew_min, crew_max, armament_slots)  -- section 7.3
# Phase-6 speed re-pin: {16, 20, 24} tiles/day on 5 nm tiles = 80–120 nm/day
# (`10-*` §6.1). Phase 7 (task S, staged 2026-11-02): the exact 16-hull roster
# with `role` (enum war|trade|coastal) and `tier` (§2.2 first-pass finalized);
# the original 8 keep every locked stat.
LOCKED_SHIP_TYPES = {
    "latin": ("拉丁帆船", "Latin", "sail", "coastal", 1, 1200, 40, 30, 16, 8, 20, 2),
    "sloop": ("单桅纵帆船", "Sloop", "sail", "coastal", 1, 3000, 60, 60, 20, 10, 30, 4),
    "caravel": ("卡拉维尔帆船", "Caravel", "sail", "trade", 2, 8000, 90, 120, 20, 15, 45, 6),
    "galley": ("桨帆船", "Galley", "oar", "war", 2, 10000, 70, 50, 24, 40, 120, 4),
    "brigantine": ("双桅帆船", "Brigantine", "sail", "war", 2, 15000, 110, 150, 24, 20, 60, 10),
    "nao": ("瑙船", "Nao", "sail", "trade", 3, 22000, 140, 300, 16, 25, 80, 10),
    "carrack": ("卡拉克帆船", "Carrack", "sail", "trade", 3, 40000, 180, 450, 16, 30, 100, 16),
    "galleon": ("盖伦帆船", "Galleon", "hybrid", "war", 3, 60000, 240, 400, 20, 40, 150, 24),
    "galiot": ("小型桨帆船", "Galiot", "oar", "war", 1, 2400, 35, 25, 16, 15, 40, 2),
    "galleass": ("加莱赛战船", "Galleass", "oar", "war", 3, 22000, 110, 70, 16, 60, 160, 6),
    "fluyt": ("弗鲁特商船", "Fluyt", "sail", "trade", 2, 14000, 70, 180, 16, 12, 30, 2),
    "junk": ("福船", "Junk", "sail", "trade", 2, 16000, 90, 140, 16, 20, 60, 3),
    "dhow": ("单桅三角帆船", "Dhow", "sail", "trade", 2, 9000, 60, 90, 20, 10, 30, 2),
    "pinnace": ("平底船", "Pinnace", "sail", "coastal", 1, 2200, 40, 45, 16, 8, 20, 2),
    "caravela_redonda": ("卡拉维拉方形帆船", "Caravela Redonda", "sail", "trade", 2,
                          11000, 70, 100, 20, 15, 40, 3),
    "xebec": ("小型三桅船", "Xebec", "hybrid", "war", 2, 15000, 60, 60, 24, 25, 80, 4),
}

# Phase 9 (10-* §4.3 / §8 group 3): the battle turn-rate two-tier hull
# partition — the 16 locked hulls appear in exactly one tier each.
# 90° nimble tier: latin, sloop, galiot, pinnace, dhow, xebec, galley;
# 45° tier: the other nine.
BATTLE_TURN_RATE_90_IDS = (
    "latin", "sloop", "galiot", "pinnace", "dhow", "xebec", "galley",
)
BATTLE_TURN_RATE_45_IDS = (
    "caravel", "brigantine", "nao", "carrack", "galleon", "galleass",
    "fluyt", "junk", "caravela_redonda",
)
# Phase 9 (10-* §4.3, correction 3): `battle_max_speed` derives from the
# §6.1 speed tier by this exact mapping (validator bound 2..4).
BATTLE_MAX_SPEED_BY_SPEED = {16: 3, 20: 4, 24: 5}  # correction 15 (2026-11-04)

# id: (zh, en, color, start_port_id, start_ship_type_id, start_gold,
#      start_reputation, capital_port_id)  -- section 7.4
LOCKED_NATIONS = {
    "portugal": ("葡萄牙", "Portugal", "#1a8c4e", "lisbon", "caravel", 5000, 20, "lisbon"),
    "spain": ("西班牙", "Spain", "#b3191f", "seville", "nao", 6000, 15, "seville"),
    "england": ("英格兰", "England", "#274b8f", "london", "sloop", 4500, 10, "london"),
    "holland": ("荷兰", "Holland", "#d97b1e", "amsterdam", "nao", 7000, 10, "amsterdam"),
    "ottoman": ("奥斯曼", "Ottoman", "#6a3d9a", "istanbul", "galley", 6000, 12, "istanbul"),
    "italy": ("意大利", "Italy", "#c9a227", "venice", "brigantine", 5500, 10, "venice"),
}

# id: (zh, en, nation_id, lat, lon)  -- section 7.1
# Phase 4: 100 ports keyed by real WGS84 coordinates; the grid tile is derived
# by section 6.1's harbor-snap rule, never stored. Transcribed from section 7.1
# and cross-checked against data/ports.json (group 5 asserts both directions).
# Phase 7 lock model (task T, 10-* §8 group 5): IDENTITY locks only —
# id/zh/en/nation/lat/lon exact. produces/demands are demoted to the
# structural §8.2 group-7 economy-graph checks so the graph can be authored.
LOCKED_PORTS = {
    "lisbon": ("里斯本", "Lisbon", "portugal", 38.72, -9.14),
    "seville": ("塞维利亚", "Seville", "spain", 37.0, -6.35),
    "valencia": ("瓦伦西亚", "Valencia", "spain", 39.45, -0.33),
    "barcelona": ("巴塞罗那", "Barcelona", "spain", 41.35, 2.17),
    "marseille": ("马赛", "Marseille", "spain", 43.3, 5.37),
    "bordeaux": ("波尔多", "Bordeaux", "spain", 45.55, -1.15),
    "london": ("伦敦", "London", "england", 51.47, 0.75),
    "amsterdam": ("阿姆斯特丹", "Amsterdam", "holland", 52.46, 4.6),
    "antwerp": ("安特卫普", "Antwerp", "holland", 51.44, 3.6),
    "hamburg": ("汉堡", "Hamburg", "holland", 53.87, 8.7),
    "genoa": ("热那亚", "Genoa", "italy", 44.41, 8.93),
    "naples": ("那不勒斯", "Naples", "italy", 40.84, 14.25),
    "palermo": ("巴勒莫", "Palermo", "italy", 38.12, 13.36),
    "syracuse": ("锡拉库萨", "Syracuse", "italy", 37.07, 15.29),
    "cagliari": ("卡利亚里", "Cagliari", "italy", 39.22, 9.11),
    "valetta": ("瓦莱塔", "Valetta", "italy", 35.9, 14.51),
    "venice": ("威尼斯", "Venice", "italy", 45.44, 12.33),
    "ragusa": ("拉古萨", "Ragusa", "italy", 42.65, 18.09),
    "athens": ("雅典", "Athens", "ottoman", 37.94, 23.64),
    "candia": ("干地亚", "Candia", "ottoman", 35.34, 25.13),
    "cyprus": ("塞浦路斯", "Cyprus", "ottoman", 34.67, 33.04),
    "smyrna": ("士麦那", "Smyrna", "ottoman", 38.42, 27.14),
    "istanbul": ("伊斯坦布尔", "Istanbul", "ottoman", 41.01, 28.97),
    "beirut": ("贝鲁特", "Beirut", "ottoman", 33.9, 35.5),
    "alexandria": ("亚历山大", "Alexandria", "ottoman", 31.2, 29.92),
    "tripoli": ("的黎波里", "Tripoli", "ottoman", 32.9, 13.18),
    "tunis": ("突尼斯", "Tunis", "ottoman", 36.82, 10.3),
    "algiers": ("阿尔及尔", "Algiers", "ottoman", 36.77, 3.06),
    "ceuta": ("休达", "Ceuta", "portugal", 35.89, -5.32),
    "madeira": ("马德拉", "Madeira", "portugal", 32.65, -16.91),
    "havana": ("哈瓦那", "Havana", "spain", 23.13, -82.38),
    "vera_cruz": ("韦拉克鲁斯", "Veracruz", "spain", 19.2, -96.13),
    "cartagena": ("卡塔赫纳", "Cartagena", "spain", 10.39, -75.53),
    "portobelo": ("波托贝洛", "Portobelo", "spain", 9.55, -79.65),
    "lima": ("利马", "Lima", "spain", -12.06, -77.15),
    "buenos_aires": ("布宜诺斯艾利斯", "Buenos Aires", "spain", -34.6, -58.37),
    "san_juan": ("圣胡安", "San Juan", "spain", 18.47, -66.11),
    "santo_domingo": ("圣多明各", "Santo Domingo", "spain", 18.47, -69.88),
    "acapulco": ("阿卡普尔科", "Acapulco", "spain", 16.85, -99.9),
    "panama": ("巴拿马", "Panama", "spain", 8.98, -79.52),
    "valparaiso": ("瓦尔帕莱索", "Valparaiso", "spain", -33.03, -71.63),
    "guayaquil": ("瓜亚基尔", "Guayaquil", "spain", -2.6, -80.3),
    "bahia": ("巴伊亚", "Bahia", "portugal", -12.97, -38.5),
    "rio_de_janeiro": ("里约热内卢", "Rio de Janeiro", "portugal", -22.9, -43.18),
    "recife": ("累西腓", "Recife", "portugal", -8.06, -34.87),
    "belem": ("贝伦", "Belem", "portugal", -1.35, -48.48),
    "boston": ("波士顿", "Boston", "england", 42.36, -71.05),
    "new_york": ("纽约", "New York", "england", 40.7, -74.02),
    "jamestown": ("詹姆斯敦", "Jamestown", "england", 37.0, -76.3),
    "charleston": ("查尔斯顿", "Charleston", "england", 32.78, -79.93),
    "new_foundland": ("纽芬兰", "Newfoundland", "england", 47.56, -52.71),
    "quebec": ("魁北克", "Quebec", "england", 47.0, -70.5),
    "curacao": ("库拉索", "Curacao", "holland", 12.11, -68.93),
    "suriname": ("苏里南", "Suriname", "holland", 5.9, -55.15),
    "elmina": ("埃尔米纳", "Elmina", "portugal", 5.08, -1.35),
    "luanda": ("罗安达", "Luanda", "portugal", -8.78, 13.23),
    "mozambique": ("莫桑比克", "Mozambique", "portugal", -15.03, 40.73),
    "mombasa": ("蒙巴萨", "Mombasa", "ottoman", -4.06, 39.68),
    "cape_town": ("开普敦", "Cape Town", "holland", -33.92, 18.42),
    "safi": ("萨菲", "Safi", "portugal", 32.3, -9.24),
    "saint_louis": ("圣路易", "Saint-Louis", "holland", 16.0, -16.51),
    "accra": ("阿克拉", "Accra", "england", 5.53, -0.2),
    "goa": ("果阿", "Goa", "portugal", 15.5, 73.83),
    "calicut": ("卡利卡特", "Calicut", "portugal", 11.25, 75.77),
    "cochin": ("科钦", "Cochin", "holland", 9.97, 76.27),
    "bombay": ("孟买", "Bombay", "england", 18.92, 72.83),
    "surat": ("苏拉特", "Surat", "england", 21.1, 72.7),
    "colombo": ("科伦坡", "Colombo", "holland", 6.93, 79.85),
    "pondicherry": ("本地治里", "Pondicherry", "england", 11.93, 79.83),
    "muscat": ("马斯喀特", "Muscat", "ottoman", 23.62, 58.59),
    "basra": ("巴士拉", "Basra", "ottoman", 30.0, 48.5),
    "bandar_abbas": ("阿巴斯港", "Bandar Abbas", "ottoman", 27.18, 56.28),
    "aden": ("亚丁", "Aden", "ottoman", 12.79, 45.03),
    "jiddah": ("吉达", "Jiddah", "ottoman", 21.48, 39.18),
    "suakin": ("苏阿金", "Suakin", "ottoman", 19.1, 37.33),
    "mogadishu": ("摩加迪沙", "Mogadishu", "ottoman", 2.03, 45.34),
    "malacca": ("马六甲", "Malacca", "portugal", 2.19, 102.25),
    "batavia": ("巴达维亚", "Batavia", "holland", -6.13, 106.81),
    "macassar": ("望加锡", "Macassar", "holland", -5.13, 119.41),
    "amboina": ("安汶", "Amboina", "holland", -3.69, 128.18),
    "manila": ("马尼拉", "Manila", "spain", 14.58, 120.97),
    "macau": ("澳门", "Macao", "portugal", 22.19, 113.54),
    "canton": ("广州", "Canton", "england", 22.75, 113.65),
    "nagasaki": ("长崎", "Nagasaki", "holland", 32.75, 129.88),
    "osaka": ("大阪", "Osaka", "holland", 34.65, 135.43),
    "zeelandia": ("热兰遮", "Zeelandia", "holland", 22.99, 120.16),
    "patani": ("北大年", "Patani", "holland", 6.87, 101.25),
    "brunei": ("文莱", "Brunei", "spain", 5.0, 115.05),
    "ternate": ("特尔纳特", "Ternate", "holland", 0.79, 127.38),
    "timor": ("帝汶", "Timor", "portugal", -10.17, 123.6),
    "botany_bay": ("鲨鱼湾", "Shark Bay", "holland", -25.5, 113.5),
    "siam": ("暹罗", "Siam", "portugal", 13.5, 100.58),
    "cadiz": ("加的斯", "Cadiz", "spain", 36.53, -6.29),
    "oporto": ("波尔图", "Oporto", "portugal", 41.14, -8.68),
    "plymouth": ("普利茅斯", "Plymouth", "england", 50.37, -4.14),
    "bergen": ("卑尔根", "Bergen", "holland", 60.39, 5.32),
    "danzig": ("但泽", "Danzig", "holland", 54.4, 18.68),
    "stockholm": ("斯德哥尔摩", "Stockholm", "holland", 59.32, 18.1),
    "trieste": ("的里雅斯特", "Trieste", "italy", 45.65, 13.77),
    "corfu": ("科孚", "Corfu", "italy", 39.62, 19.92),
    # 2026-11-02 route-network amendment (§7.1): five ports recorded there —
    # the flota's Canary victualling stop, the Iceland cod terminus, the
    # Brazil-run muster point, the Angola-leg station and the Genoese
    # Black-sea grain hub.
    "santa_cruz": ("圣克鲁斯", "Santa Cruz de Tenerife", "spain", 28.47, -16.25),
    "reykjavik": ("雷克雅未克", "Reykjavik", "holland", 64.15, -21.94),
    "praia": ("普拉亚", "Praia", "portugal", 14.92, -23.51),
    "benguela": ("本格拉", "Benguela", "portugal", -12.58, 13.41),
    "caffa": ("卡法", "Caffa", "italy", 45.03, 35.38),
}

# id: (zh, en, lat, lon)  -- section 7.1 Phase-6 neutral tier (45 rows)
# Phase 7 lock model (task T): the neutral tier joins the identity locks —
# the tier's count band (40–60) is retired by the §8 group-5 amendment; the
# set is exactly these 45 ids, zh/en/lat/lon exact (nation is always `""`).
LOCKED_NEUTRAL_PORTS = {
    "quanzhou": ("泉州", "Quanzhou (Zayton)", 24.85, 118.72),
    "ningbo": ("宁波", "Ningbo", 29.95, 121.7),
    "yuegang": ("月港", "Yuegang (Zhangzhou)", 24.42, 117.98),
    "shuangyu": ("双屿", "Shuangyu", 29.74, 122.22),
    "nanao": ("南澳", "Nan'ao", 23.4, 117.2),
    "xiamen": ("厦门", "Xiamen (Amoy)", 24.44, 118.13),
    "fuzhou": ("福州", "Fuzhou", 26.02, 119.65),
    "wenzhou": ("温州", "Wenzhou", 27.97, 120.68),
    "zhelin": ("柘林", "Zhelin (Chaozhou)", 23.62, 117.13),
    "qiongzhou": ("琼州", "Qiongzhou (Hainan)", 20.03, 110.33),
    "beihai": ("北海", "Beihai (Hepu)", 21.48, 109.12),
    "dinghai": ("定海", "Dinghai (Zhoushan)", 30.01, 122.11),
    "liujiagang": ("刘家港", "Liujiagang (Taicang)", 31.5, 121.55),
    "hirado": ("平户", "Hirado", 33.25, 129.56),
    "sakai": ("堺", "Sakai", 34.5, 135.42),
    "yamagawa": ("山川", "Yamagawa (Satsuma)", 31.1, 130.58),
    "hakata": ("博多", "Hakata", 33.59, 130.39),
    "funai": ("丰后府内", "Bungo-Funai (Ōita)", 33.24, 131.61),
    "urado": ("浦户", "Urado (Tosa)", 33.5, 133.55),
    "anotsu": ("安浓津", "Anotsu (Ise)", 34.6, 136.7),
    "busan": ("釜山", "Busan (Pusan)", 35.1, 129.04),
    "yeompo": ("盐浦", "Yeompo", 35.5, 129.43),
    "hoi_an": ("会安", "Hoi An (Faifo)", 15.9, 108.34),
    "banten": ("万丹", "Banten", -5.85, 105.95),
    "jambi": ("占碑", "Jambi", -1.12, 103.8),
    "palembang": ("巨港", "Palembang", -2.25, 104.85),
    "gresik": ("革儿昔", "Gresik (Surabaya)", -7.05, 113.35),
    "sulu": ("苏禄", "Sulu (Jolo)", 5.98, 120.98),
    "kedah": ("吉打", "Kedah", 6.1, 100.32),
    "nagapattinam": ("内加帕塔姆", "Nagapattinam", 10.76, 79.85),
    "masulipatnam": ("马苏利帕特南", "Masulipatnam", 16.1, 81.12),
    "hughli": ("胡格利", "Hughli (Bengal)", 21.65, 88.05),
    "syriam": ("沙廉", "Syriam (Pegu)", 16.6, 96.28),
    "dianga": ("迪昂", "Dianga (Arakan)", 18.4, 94.3),
    "khambhat": ("坎贝", "Cambay (Khambhat)", 21.7, 72.55),
    "diu": ("第乌", "Diu", 20.69, 70.97),
    "mocha": ("摩卡", "Mocha", 13.3, 43.22),
    "qalhat": ("哈尔哈特", "Qalhat", 22.68, 59.8),
    "hormuz": ("霍尔木兹", "Hormuz", 26.62, 56.43),
    "zanzibar": ("桑给巴尔", "Zanzibar", -6.05, 38.92),
    "kilwa": ("基尔瓦", "Kilwa", -8.96, 39.5),
    "sofala": ("索法拉", "Sofala", -19.6, 35.25),
    "lamu": ("拉穆", "Lamu", -2.3, 40.6),
    "massawa": ("马萨瓦", "Massawa", 15.6, 39.45),
    "zeila": ("泽拉", "Zeila", 11.35, 43.47),
}

NEUTRAL_PORT_COUNT = 45  # §7.1: the exact neutral-tier count (lock model Phase 7)

# §7.1 (decision 25): the locked protected set — ≤ 4 per nation, ⊇ the 6
# capitals, permanent alignment, no ledger. Group 7 asserts the exact set.
LOCKED_PROTECTED_PORTS = frozenset({
    "lisbon", "oporto",                       # portugal
    "seville", "cadiz", "valencia", "barcelona",  # spain
    "london", "plymouth",                     # england
    "amsterdam", "antwerp",                   # holland
    "istanbul", "athens", "smyrna",           # ottoman
    "venice", "genoa", "naples", "palermo",   # italy
})

# §7.1 "Port region bands (Phase 7)": the locked band-id container — the
# 15 ids below are task P's recorded set (staged 2026-11-02; partitions all
# 150 ports, contains the six §7.1 skeleton ids). Group 5/§8.2 item 13 check
# membership + no-unused-id against this tuple.
LOCKED_BANDS: tuple[str, ...] = (
    "africa_atlantic",
    "africa_levant",
    "americas_brazil",
    "americas_caribbean",
    "americas_north",
    "americas_pacific",
    "china_coast",
    "europe_atlantic",
    "europe_med",
    "india_persia_arabia",
    "indian_ocean_south",
    "japan",
    "korea",
    "southeast_asia",
    "swahili_red_sea",
)

# §7.5 (Phase 8): the 6 Phase-1 starters' LOCKED IDENTITY — id, zh/en name,
# nation and recruit ports stay verbatim from the v1 roster (§7.5 table); the
# v1 `role`/`stats` columns are retired (the v2 person-card conversion is the
# builder's, §4.5). Their bios are likewise verbatim (the builder carries
# them in STARTERS_V1; group 5 pins the whole identity block). Note
# off_diego_fernandez recruits at `ceuta`, a portugal port — the §7.5
# identity is exempt from the group-12 own-nation subset rule.
STARTER_IDENTITY = {
    "off_mateus_alvares": {
        "zh": "马特乌斯·阿尔瓦雷斯", "en": "Mateus Álvares",
        "nation_id": "portugal", "recruit_ports": ("lisbon", "madeira"),
        "bio_zh": "一位在老领航员手下学艺的青年,星象与海图无一不精。",
        "bio_en": "A young pilot schooled by old navigators; at home with stars and charts alike.",
    },
    "off_diego_fernandez": {
        "zh": "迭戈·费尔南德斯", "en": "Diego Fernández",
        "nation_id": "spain", "recruit_ports": ("seville", "ceuta"),
        "bio_zh": "在塞维利亚船坞里长大的老水手长,一声令下缆索便各归其位。",
        "bio_en": "A boatswain raised in the Seville yards, whose whistle sends every rope to its place.",
    },
    "off_thomas_reed": {
        "zh": "托马斯·里德", "en": "Thomas Reed",
        "nation_id": "england", "recruit_ports": ("london",),
        "bio_zh": "曾在英吉利海峡追捕私掠者的炮手,最看重火药干燥与否。",
        "bio_en": "A gunner who once chased privateers in the Channel, and cares above all that the powder stays dry.",
    },
    "off_jan_de_vries": {
        "zh": "扬·德弗里斯", "en": "Jan de Vries",
        "nation_id": "holland", "recruit_ports": ("amsterdam", "antwerp"),
        "bio_zh": "弗里斯兰出身的水手长,能在暴风里把甲板收拾得井井有条。",
        "bio_en": "A Frisian boatswain who can keep a deck in order even through a gale.",
    },
    "off_kemal_agha": {
        "zh": "凯末尔阿迦", "en": "Kemal Agha",
        "nation_id": "ottoman", "recruit_ports": ("istanbul", "smyrna"),
        "bio_zh": "在金角湾炮台服役多年的老炮长,开火前总要亲手校一遍炮位。",
        "bio_en": "A veteran gun captain from the Golden Horn batteries, who sights each gun himself before firing.",
    },
    "off_marco_bellini": {
        "zh": "马尔科·贝里尼", "en": "Marco Bellini",
        "nation_id": "italy", "recruit_ports": ("venice", "genoa"),
        "bio_zh": "为威尼斯商船绘制海图的领航员,对亚得里亚海的每一处暗礁都了然于心。",
        "bio_en": "A chart-maker for Venetian merchantmen, who knows every reef in the Adriatic by heart.",
    },
}
STARTER_IDS = tuple(STARTER_IDENTITY)

# --- Phase 8 person model (docs/10-DATA-SCHEMA.md §4.5/§4.11/§4.20-4.22) ----

# §4.11/§4.5: the 5 attribute keys of the shared person card.
PERSON_ATTRIBUTES = ("constitution", "intellect", "charisma", "courage", "luck")
# §4.11/50-* §2.2: the 8 player skills (captain-card key set).
PLAYER_SKILLS = ("seamanship", "navigation", "swordplay", "gunnery",
                 "appraisal", "negotiation", "cartography", "rumour")
# §4.5: the officer card adds the three ship-service skills (11 total).
OFFICER_SKILL_NAMES = PLAYER_SKILLS + ("medicine", "carpentry", "cooking")
# §8.7 gate vocabulary: the 5 attributes + the 11 skills.
GATE_STAT_SKILLS = PERSON_ATTRIBUTES + OFFICER_SKILL_NAMES

# §4.11: the 7 locked captain roles, their tier ranges and the role
# templates (main/secondary attribute — signature/secondary skill). The
# coaster names NO skills and its luck sits at the others step (the -low
# pin); its "any" secondary-attribute cell is pinned to courage by the
# builder (W2-A choice, recorded in tools/build_captains.py).
CAPTAIN_ROLES = ("trader", "coaster", "patrol", "courier", "privateer",
                 "pirate", "hunter")
CAPTAIN_ROLE_TIERS = {"trader": (1, 2), "coaster": (1, 1), "patrol": (2, 2),
                      "courier": (1, 2), "privateer": (2, 3), "pirate": (1, 3),
                      "hunter": (2, 3)}
CAPTAIN_ROLE_TEMPLATES = {
    "trader": ("charisma", "luck", "negotiation", "appraisal"),
    "coaster": ("constitution", "courage", None, None),
    "patrol": ("courage", "charisma", "gunnery", "seamanship"),
    "courier": ("constitution", "intellect", "navigation", "seamanship"),
    "privateer": ("courage", "luck", "swordplay", "gunnery"),
    "pirate": ("courage", "charisma", "swordplay", "gunnery"),
    "hunter": ("courage", "intellect", "swordplay", "navigation"),
}
# §4.11: pirates/hunters get level +2 (1 + tier×4 otherwise).
CAPTAIN_LEVEL_BONUS_ROLES = ("pirate", "hunter")
# §7.8: the 4 locked named-pirate ids (the shipped Phase-5/7 pairings).
LOCKED_NAMED_PIRATE_IDS = (
    "pirate_redbeard_khair",
    "pirate_murad_red_sail",
    "pirate_limahong_thousand_sails",
    "pirate_edward_bloodhand",
)
# §7.7/§8.6 item 3: the extreme-preset pirate row is the Phase-7 measured
# normal composition (8 pirate_base from npc_config + 17 unpatrolled zones,
# docs/60-* §4.1.1, tools/demo_check_phase7.md) × the extreme multiplier.
UNPATROLLED_ZONES_PHASE7 = 17
EXTREME_PRESET = "extreme"

# §4.5/§7.5/§8.7: the officers v2 roster pins.
OFFICER_TOTAL = 96           # 24 legends + 72 regulars
OFFICER_LEGEND_COUNT = 24
OFFICER_REGULAR_COUNT = 72
LEGEND_MAIN_BAND = (45, 60)
REGULAR_MAIN_BAND = (25, 45)
LEGEND_WAGE_BAND = (40, 60)
REGULAR_WAGE_BAND = (20, 35)
SPECIALTY_MIN_CARRIERS = 10  # each skill at ≥ 20 on ≥ 10 officers
SPECIALTY_THRESHOLD = 20
CAPTAIN_QUALIFIED_MIN = 12   # seamanship ≥ 25 ∧ courage ≥ 30
# §8.7 item 1: main_skill → the officer native-role personality pool(s) of
# §4.11.1. The seamanship main is ambiguous between boatswain and captain —
# the union is the pool; seamanship-main LEGENDS draw the boatswain pool
# only (the builder's recorded pin, tools/build_captains.py).
OFFICER_MAIN_ROLE_POOLS = {
    "navigation": ("pilot",),
    "seamanship": ("boatswain", "captain"),
    "gunnery": ("gunner",),
    "medicine": ("surgeon",),
    "carpentry": ("carpenter",),
    "cooking": ("cook",),
    "swordplay": ("captain",),
}

# §4.20/§8.7 item 6: feature ids are `<system>.<feature>` — dots legal.
FEATURE_ID_RE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$")
# The locked gate inventory (50-* §2.2 Gates column + sail.autopilot):
# every row below must be present (the file may grow).
LOCKED_GATE_FEATURES = (
    "sail.autopilot",
    "sail.night",
    "repair.foul_weather",
    "repair.at_sea",
    "shot.chain",
    "shot.armor_piercing",
    "duel.ladder.rank2",
    "duel.ladder.rank3",
    "market.profit_arrows",
    "market.other_port_memory",
    "permit.home_discount",
    "permit.foreign_discount",
    "chart.reef_annotations",
    "bounty.pinpoint",
)
# §4.21/§8.7 item 7: the 7 locked posts and their prereqs.
LOCKED_POST_IDS = ("pilot", "boatswain", "gunner", "surgeon", "carpenter",
                   "cook", "captain")
FLAGSHIP_POST_PREREQ = {
    "pilot": {"navigation": 20},
    "boatswain": {"seamanship": 20},
    "gunner": {"gunnery": 20},
    "surgeon": {"medicine": 20},
    "carpenter": {"carpentry": 20},
    "cook": {"cooking": 20},
}
CAPTAIN_POST_PREREQ = {"seamanship": 25, "courage": 30}
# §4.21: the 6 locked advice situations and their numeric trigger params
# (the numbers sit in this table, never in code).
ADVICE_SITUATIONS = ("wind_band", "storm_sail", "first_contact", "water_low",
                     "durability_low", "morale_low")
ADVICE_PARAMS = {
    "water_low": {"days": 5},
    "durability_low": {"pct": 50},
    "morale_low": {"threshold": 40},
}

# §7.10: the locked 6-background set — id → (zh, en, attribute, skill).
LOCKED_BACKGROUNDS = {
    "background_deckhand": ("甲板水手", "Deckhand", "constitution", "seamanship"),
    "background_navy_cadet": ("海军见习生", "Naval Cadet", "courage", "navigation"),
    "background_merchant_apprentice": ("商行学徒", "Merchant Apprentice",
                                        "charisma", "negotiation"),
    "background_cartographer_apprentice": ("制图学徒",
                                            "Cartographer's Apprentice",
                                            "intellect", "cartography"),
    "background_tavern_errand": ("酒馆跑腿", "Tavern Runner", "luck", "rumour"),
    "background_fencing_student": ("剑馆弟子", "Fencing Student", "courage",
                                    "swordplay"),
}

# id: (zh, en, slot, modifiers, price, tier, rare)  -- docs/60-COMBAT.md
# section 4.11.13 (reachable from docs/10-DATA-SCHEMA.md section 4.6).
# Phase 7 (task S, staged 2026-11-02): the exact 24-item set — 6 per slot,
# 2/2/2 tiers per slot, exactly 4 `rare: true` drop-only items (§7.9). The
# original 8 keep every locked value and gain their authored tier.
LOCKED_EQUIPMENT = {
    "eq_cutlass": ("水手弯刀", "Sailor's Cutlass", "weapon", {"combat": 3}, 400, 1, False),
    "eq_rapier": ("贵族细剑", "Noble's Rapier", "weapon", {"combat": 5}, 1200, 1, False),
    "eq_backsword": ("单刃剑", "Backsword", "weapon", {"combat": 6}, 2200, 2, False),
    "eq_main_gauche": ("左手格挡匕首", "Main-Gauche", "weapon",
                       {"combat": 4, "luck": 2}, 1900, 2, False),
    "eq_zweihander": ("双手巨剑", "Zweihänder", "weapon", {"combat": 9}, 4800, 3, False),
    "eq_khair_scimitar": ("「红胡子」弯刀", "Redbeard's Scimitar", "weapon",
                           {"combat": 10}, 6000, 3, True),
    "eq_breastplate": ("胸甲", "Breastplate", "armor", {"combat": 2}, 700, 1, False),
    "eq_lucky_charm": ("幸运护符", "Lucky Charm", "armor",
                       {"combat": 1, "luck": 5}, 900, 1, False),
    "eq_brigandine": ("铆钉皮甲", "Brigandine", "armor", {"combat": 4}, 2400, 2, False),
    "eq_saint_medallion": ("圣徒徽章", "Saint's Medallion", "armor",
                            {"luck": 3, "scurvy_delay_days": 2}, 2800, 2, False),
    "eq_three_quarter_armor": ("四分之三甲", "Three-Quarter Armour", "armor",
                                {"combat": 6}, 5200, 3, False),
    "eq_bloodhand_cuirass": ("「血手」胸甲", "Bloodhand's Cuirass", "armor",
                              {"combat": 5, "luck": 3}, 4200, 3, True),
    "eq_mermaid_figurehead": ("美人鱼船首像", "Mermaid Figurehead",
                               "figurehead", {"durability": 10}, 1500, 1, False),
    "eq_eagle_figurehead": ("雄鹰船首像", "Eagle Figurehead",
                             "figurehead", {"durability": 8}, 700, 1, False),
    "eq_dragon_figurehead": ("龙首船像", "Dragon Figurehead",
                              "figurehead", {"durability": 20}, 3200, 2, False),
    "eq_albatross_figurehead": ("信天翁船首像", "Albatross Figurehead", "figurehead",
                                 {"durability": 12, "storm_damage_pct": -10}, 2600, 2, False),
    "eq_angel_figurehead": ("天使船首像", "Angel Figurehead", "figurehead",
                             {"durability": 25, "scurvy_delay_days": 3}, 4800, 3, False),
    "eq_golden_dragon_figurehead": ("鎏金龙首像", "Gilded Dragon Figurehead", "figurehead",
                                     {"durability": 30, "scurvy_delay_days": 5}, 6000, 3, True),
    "eq_cotton_sails": ("棉帆", "Cotton Sails", "sail", {"speed": 1}, 1000, 1, False),
    "eq_matting_sails": ("棕席帆", "Woven Mat Sails", "sail", {"speed": 1}, 400, 1, False),
    "eq_storm_sails": ("风暴帆", "Storm Sails", "sail",
                       {"speed": 1, "durability": 5}, 2600, 2, False),
    "eq_flemish_linen_sails": ("佛兰芒亚麻帆", "Flemish Linen Sails", "sail",
                                {"speed": 2}, 3400, 2, False),
    "eq_brocade_sails": ("织金锦帆", "Brocade Sails", "sail",
                          {"speed": 1, "durability": 10, "storm_damage_pct": -15}, 5000, 3, False),
    "eq_red_sail": ("「红帆」", "The Red Sail", "sail",
                    {"speed": 2, "durability": 8, "storm_damage_pct": -20}, 6000, 3, True),
}

# docs/60-COMBAT.md section 4.11.12: `figurehead`/`sail` are ship-bound, so
# they may only touch ship-instance stats; `weapon`/`armor` are player-worn,
# so they may only touch player stats. Group 4 enforces the split.
SHIP_EQUIPMENT_SLOTS = ("figurehead", "sail")
PLAYER_EQUIPMENT_SLOTS = ("weapon", "armor")

CAPITAL_PORT_IDS = tuple(
    row[7] for row in LOCKED_NATIONS.values()
)  # lisbon, seville, london, amsterdam, istanbul, venice

LOCKED_COUNTS = {
    "nations": 6,
    "goods": 40,
    "ship_types": 16,
    "ports": 105,  # amended 2026-11-02 (§7.1): the five new sovereign ports
    "officers": 96,  # §7.5 (Phase 8): 24 legends + 72 regulars
    "equipment": 24,
    "backgrounds": 6,  # §7.10 (Phase 8)
}

# §7.1 Phase-6 neutral tier: Phase 7 joins the tier to the identity locks —
# the 40–60 count band is retired; the set is exactly LOCKED_NEUTRAL_PORTS
# (45 rows) and the total port count exactly 150 (§8 group 5).

# §8.2 item 5 (`30-*` §4.2): the Phase-7 flag-driven consumption-tier split —
# exactly 12 `staple: true` / 16 unflagged (middle) / 12 `specialty: true`
# (luxury tier). The Phase-5 derived base-price-rank split is retired.
CONSUMPTION_TIER_SPLIT = (12, 16, 12)

# §2.1 flow economy (30-* §4.2): tier flow rates and capacities the harness
# and (from W3) economy.gd read; the validator pins the split, not these
# engine numbers — recorded here only as the group-7 fixture constants.
FLOW_TIER_RATES = {"staple": 5, "middle": 3, "luxury": 2}
FLOW_TIER_CAPACITIES = {"staple": 160, "middle": 140, "luxury": 120}

# --- Phase 5 npc & economy data (docs/10-DATA-SCHEMA.md sections 4.10-4.13,
# normative validator spec section 8.2) --------------------------------------

# npc_config.json: the locked §4.10 key sets. The values are bounds-checked
# (§8.2 item 1); the key sets themselves are exact. Phase 9 (correction 11):
# `ai_profiles` joins the envelope as a REQUIRED key from the W2 validator on
# (§4.10 — the block lands with the W2 data wave, no per-stage key growth).
NPC_PRESET_KEYS = ("deserted", "low", "normal", "high", "extreme")
NPC_BUDGET_KEYS = (
    "traders_mult_per_port",
    "coasters_mult_per_port",
    "patrols_div_ports",
    "patrols_min",
    "couriers_per_nation",
    "privateers_per_rivalry",
    "pirate_base",
    "pirates_per_unpatrolled_zone",
)
NPC_FLOW_KEYS = (
    "spawns_per_day_base",
    "path_budget_ms_per_day",
    "trade_units_per_port_call",
    "coaster_trade_units",
)
NPC_CONFIG_KEYS = ("version", "presets", "default_preset", "budgets", "flow",
                   "absolute_cap", "ai_profiles")
# Phase 7 (correction 15): task N (W4) adds the explicit data line
# `neutral_coasters_mult` (§2.7 pins := 0.75). The key is allowed (and
# > 0-bounded) from the W2 validator on; it is NOT yet required — W2's
# staged/merged data carries no npc_config edit (N owns that file in W4),
# and the §8.2 negative list pins no missing-key failure.
NPC_CONFIG_OPTIONAL_KEYS = ("neutral_coasters_mult",)
# Phase 9 (§4.10 `ai_profiles` / §8.2 item 14; corrections 8+11): the
# per-kind battle-behavior block. Exactly the 9 kind rows × exactly 9 keys
# per row, from day one (correction 11 — all nine keys land with the W2
# data wave even though runtime consumers arrive per stage). `hunter` is
# NEVER a row: hunter battles enter as kind "navy" (the §4.10 lookup
# fallback, correction 8); `coaster` is forward-compat + sandbox-only
# (coasters are intimidate-only, never battle — 60-* §4.1.1) but is
# shape-checked like every other row.
NPC_AI_PROFILE_KINDS = ("pirate", "privateer", "patrol", "navy",
                        "tournament", "treasure", "trader", "coaster",
                        "courier")
NPC_AI_PROFILE_KEYS = ("kind", "archetype", "aggression", "preferred_range",
                       "flee_below_hp_pct", "focus", "courage_mod",
                       "formation", "ai_level")
NPC_AI_ARCHETYPES = ("aggressive", "balanced", "cautious")
NPC_AI_FOCUS = ("weakest", "nearest", "flagship")
NPC_AI_FORMATIONS = ("line_ahead", "column", "screen", "swarm")
# §4.10 normative value table (all 9 rows, locked):
# kind: (archetype, aggression, preferred_range, flee_below_hp_pct, focus,
#        courage_mod, formation, ai_level)
LOCKED_AI_PROFILES = {
    "pirate": ("aggressive", 90, 2, 0, "weakest", 5, "swarm", 1),
    "privateer": ("aggressive", 80, 2, 10, "weakest", 5, "swarm", 1),
    "patrol": ("balanced", 70, 3, 15, "nearest", 0, "line_ahead", 1),
    "navy": ("balanced", 60, 3, 15, "flagship", 0, "line_ahead", 1),
    "tournament": ("balanced", 60, 3, 0, "weakest", 0, "line_ahead", 1),
    "treasure": ("cautious", 10, 3, 40, "nearest", -5, "screen", 0),
    "trader": ("cautious", 5, 3, 50, "nearest", -5, "column", 0),
    "coaster": ("cautious", 5, 3, 50, "nearest", -5, "column", 0),
    "courier": ("cautious", 5, 3, 60, "nearest", -5, "column", 0),
}
# §4.10: exactly one preset multiplier is 1.0 and `default_preset` names it.
NEUTRAL_PRESET = "normal"
# §4.10: hard upper bound on live NPC fleets (group 7 enforces the locked cap).
ABSOLUTE_CAP_MAX = 2048

# named_pirates.json: §7.8 locks the count and the tier band (tier semantics:
# 70-* §4.5 bounty bands 5000/10000/20000 for tiers 1/2/3); since Phase 8 the
# rows are v2 full captain cards (§4.12) — the full-card checks are group 7's.
NAMED_PIRATE_COUNT = 4
NAMED_PIRATE_TIER_MIN = 1
NAMED_PIRATE_TIER_MAX = 3

# market_events.json demand events (30-* section 4.5, Phase-7 re-pin):
# every template names its surged goods as a `rate_override` list — while an
# instance is active each listed good's consumption rate is ×3 for
# `duration_days` (`Economy.EVENT_CONSUMPTION_MULT`); production, capacities
# and the price formula are untouched. The Phase-5 `shifts` rest-delta shape
# and its rest-band bound are retired with the drift-to-rest model
# (IMPLEMENT-Phase7.md correction 9 — task K owns the atomic transition).

# §8.2 item 5: CONSUMPTION_TIER_SPLIT moved up to the locked-constants block
# (Phase-7 flag-driven 12/16/12); the Phase-5 base-price-rank split is retired.

# Files whose structure/counts/bounds group 7 owns outright (§8.2 preamble);
# group 3's generic id loop skips them. Phase 8: npc_captains.json is retired
# (§7.7; W4-B deleted the file) — group 7 no longer reads it.
GROUP7_ENTITY_FILES = frozenset({
    "named_pirates.json", "market_events.json",
})

# Phase 8 (§4.20/§4.21): rows keyed by feature_id/post_id, not `id` — the
# group-3 generic id loop skips them; their schema functions own uniqueness.
GROUP12_SCHEMA_FILES = frozenset({
    "skill_gates.json", "officer_posts.json",
})

# §4.14: trade_routes.json's structure (locked 12-id set, waypoints,
# chokepoints) is group 8's (§8.3), so groups 2/3 skip the file; group 8
# owns its full structure since the lane builder landed (IMPLEMENT-Phase5.md
# task F). The built artifact trade_routes_built.json is a generated tool
# output (§4.14) — group 1 exempts its envelope and group 8 owns it.
GROUP8_ENTITY_FILES = frozenset({
    "trade_routes.json",
})


# ---------------------------------------------------------------------------
# Failure plumbing
# ---------------------------------------------------------------------------


class CheckFailure(Exception):
    def __init__(self, check_id: str, filename: str, details: str, code: int):
        super().__init__(details)
        self.check_id = check_id
        self.filename = filename
        self.details = details
        self.code = code


def fail(check_id: str, filename: str, details: str, code: int) -> None:
    raise CheckFailure(check_id, filename, details, code)


def is_int(value) -> bool:
    """True for JSON integers only (bool is not an int for schema purposes)."""
    return isinstance(value, int) and not isinstance(value, bool)


# ---------------------------------------------------------------------------
# Check group 1 — Parse & envelope
# ---------------------------------------------------------------------------


def check_group1(docs: dict[str, object], verbose: bool) -> None:
    """Every data/*.json parses; envelope shape per section 3.2."""
    if not DATA_DIR.is_dir():
        fail("parse", "data/", "data directory not found", 1)

    files = sorted(p for p in DATA_DIR.glob("*.json"))
    # `data/maps/maps.json` is the map index (docs/90-* section 9.1); it is a
    # nested data file, so it is collected explicitly.
    files += sorted(DATA_DIR.glob("maps/*.json"))
    if not files:
        fail("parse", "data/", "no JSON files found", 1)

    seen = set()
    for path in files:
        name = path.name
        seen.add(name)
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail("parse", name, f"cannot read as UTF-8: {exc}", 1)
        try:
            docs[name] = json.loads(text)
        except json.JSONDecodeError as exc:
            fail("parse", name, f"invalid JSON: {exc}", 1)

        obj = docs[name]
        if not isinstance(obj, dict):
            fail("envelope", name, "top-level value must be an object", 1)

        if name in SPECIAL_FILES:
            # Bespoke envelopes (section 4.9 / 80-UI-UX section 4.4): no plural
            # entity key. map_legend.json requires `version`; ui_strings.json
            # may omit it (T4 owns that file) but it must be an int if present.
            if name in SPECIAL_REQUIRE_VERSION and "version" not in obj:
                fail("envelope", name, "missing required key 'version'", 1)
            if "version" in obj and not is_int(obj["version"]):
                fail("envelope", name, "envelope key 'version' must be an integer", 1)
            continue

        if name in TOOL_OUTPUT_FILES:
            # Phase 8 (§4.11): captains.json is a builder output (§8 group-1
            # exception — the plural `captains` array plus the builder's
            # envelope block). Shape ownership is group 11's; here only the
            # version/plural/extras contract applies.
            plural = TOOL_OUTPUT_FILES[name]["plural"]
            allowed_extra = TOOL_OUTPUT_FILES[name]["allowed_extra"]
            if not is_int(obj.get("version",)):
                fail("envelope", name, "envelope key 'version' must be an integer", 1)
            extra = set(obj) - {"version", plural} - allowed_extra
            if extra:
                fail(
                    "envelope",
                    name,
                    f"unexpected envelope keys: {', '.join(sorted(extra))}",
                    1,
                )
            if not isinstance(obj.get(plural), list):
                fail("envelope", name, f"missing required array key '{plural}'", 1)
            continue

        plural = ENTITY_FILES.get(name)
        if plural is None:
            # Unknown .json under data/: still must be a well-formed envelope.
            plural = name[:-5]
            if plural not in obj:
                fail(
                    "envelope",
                    name,
                    f"unrecognised data file; expected plural key '{plural}'",
                    1,
                )

        if not is_int(obj.get("version",)):
            fail("envelope", name, "envelope key 'version' must be an integer", 1)

        extra = set(obj) - {"version", plural}
        if extra:
            fail(
                "envelope",
                name,
                f"unexpected envelope keys: {', '.join(sorted(extra))}",
                1,
            )
        if plural not in obj:
            fail("envelope", name, f"missing required array key '{plural}'", 1)
        if not isinstance(obj[plural], list):
            fail("envelope", name, f"'{plural}' must be an array", 1)

    missing = sorted(set(ENTITY_FILES) - seen)
    if missing:
        fail("missing-file", missing[0], "required entity file is absent", 1)

    if verbose:
        print(f"PASS group 1 parse & envelope ({len(files)} files)")


# ---------------------------------------------------------------------------
# Check group 2 — i18n
# ---------------------------------------------------------------------------


def _check_l10n(value, path: str, filename: str) -> None:
    if not isinstance(value, dict):
        fail("i18n", filename, f"{path} must be an L10nString object", 2)
    keys = set(value)
    if keys != {"zh", "en"}:
        fail(
            "i18n",
            filename,
            f"{path} must have exactly keys zh,en (found: {', '.join(sorted(keys)) or 'none'})",
            2,
        )
    for locale in ("zh", "en"):
        text = value[locale]
        if not isinstance(text, str):
            fail("i18n", filename, f"{path}.{locale} must be a string", 2)
        if not text.strip():
            fail("i18n", filename, f"{path}.{locale} is empty", 2)


def _walk_l10n(node, fields: tuple[str, ...], path: str, filename: str) -> None:
    if isinstance(node, dict):
        # Any object that even looks like a display string (carries a locale
        # key) must be a well-formed L10nString -- catches misspelled fields.
        if "zh" in node or "en" in node:
            _check_l10n(node, path, filename)
            return
        for key, value in node.items():
            child = f"{path}.{key}"
            if key in fields:
                _check_l10n(value, child, filename)
            else:
                _walk_l10n(value, fields, child, filename)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            _walk_l10n(value, fields, f"{path}[{index}]", filename)


def check_group2(docs: dict[str, object], verbose: bool) -> None:
    """All L10nStrings have exactly zh/en, both non-empty (section 3.3)."""
    for filename, plural in ENTITY_FILES.items():
        fields = L10N_FIELDS[plural]
        for index, entity in enumerate(docs[filename][plural]):
            _walk_l10n(entity, fields, f"{plural}[{index}]", filename)

    # Phase 8 (§4.11/§4.11.1): the canon cards and the builder's authored
    # name-part blocks join the recursion — any object that even looks like a
    # display string must be a well-formed L10nString.
    captains_doc = docs.get("captains.json")
    if isinstance(captains_doc, dict):
        for index, captain in enumerate(captains_doc.get("captains", [])):
            _walk_l10n(captain, ("name",), f"captains[{index}]",
                       "captains.json")
    parts = docs.get("captain_name_parts.json")
    if parts is not None:
        _walk_l10n(parts, (), "captain_name_parts", "captain_name_parts.json")

    ui_strings = docs.get("ui_strings.json")
    if ui_strings is not None:
        for key, value in ui_strings.items():
            if key == "version":
                continue
            _check_l10n(value, key, "ui_strings.json")
            zh_tokens = set(PLACEHOLDER_RE.findall(value["zh"]))
            en_tokens = set(PLACEHOLDER_RE.findall(value["en"]))
            if zh_tokens != en_tokens:
                fail(
                    "i18n",
                    "ui_strings.json",
                    f"{key}: placeholder sets differ "
                    f"(zh={sorted(zh_tokens)}, en={sorted(en_tokens)})",
                    2,
                )

    if verbose:
        print("PASS group 2 i18n (all display strings are zh+en)")


# ---------------------------------------------------------------------------
# Check group 3 — Schema
# ---------------------------------------------------------------------------


def _require_keys(entity: dict, required: tuple[str, ...], path: str, filename: str) -> None:
    for key in required:
        if key not in entity:
            fail("schema", filename, f"{path}: missing required field '{key}'", 3)


def _require_id(value, path: str, filename: str) -> None:
    if not isinstance(value, str) or not ID_RE.match(value):
        fail("schema", filename, f"{path} is not a valid id: {value!r}", 3)


def _require_id_list(value, path: str, filename: str, allow_empty: bool = True) -> None:
    if not isinstance(value, list):
        fail("schema", filename, f"{path} must be an array of ids", 3)
    if not allow_empty and not value:
        fail("schema", filename, f"{path} must not be empty", 3)
    for index, item in enumerate(value):
        _require_id(item, f"{path}[{index}]", filename)


def _require_int(value, path: str, filename: str, minimum=None, maximum=None) -> None:
    if not is_int(value):
        fail("schema", filename, f"{path} must be an integer (got {type(value).__name__})", 3)
    if minimum is not None and value < minimum:
        fail("schema", filename, f"{path} must be >= {minimum} (got {value})", 3)
    if maximum is not None and value > maximum:
        fail("schema", filename, f"{path} must be <= {maximum} (got {value})", 3)


def _require_tile_pos(value, path: str, filename: str,
                      width: int = MAP_WIDTH, height: int = MAP_HEIGHT) -> None:
    if not isinstance(value, dict) or set(value) != {"x", "y"}:
        fail("schema", filename, f"{path} must be an object with exactly keys x,y", 3)
    _require_int(value["x"], f"{path}.x", filename, 0, width - 1)
    _require_int(value["y"], f"{path}.y", filename, 0, height - 1)


def _require_number(value, path: str, filename: str,
                    minimum: float, maximum: float) -> None:
    """A finite JSON number in [minimum, maximum] (docs/10-* section 3.1 lat/lon)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail("schema", filename, f"{path} must be a number (got {value!r})", 3)
    number = float(value)
    if not (minimum <= number <= maximum):
        fail(
            "schema",
            filename,
            f"{path} must be in [{minimum}, {maximum}] (got {number})",
            3,
        )


def _require_enum(value, allowed: tuple[str, ...], path: str, filename: str) -> None:
    if value not in allowed:
        fail(
            "schema",
            filename,
            f"{path} must be one of {'|'.join(allowed)} (got {value!r})",
            3,
        )


def _check_unique_ids(items: list, plural: str, filename: str) -> None:
    seen = set()
    for index, entity in enumerate(items):
        if not isinstance(entity, dict):
            fail(
                "schema",
                filename,
                f"{plural}[{index}] must be an object (got {type(entity).__name__})",
                3,
            )
        entity_id = entity.get("id",)
        _require_id(entity_id, f"{plural}[{index}].id", filename)
        if entity_id in seen:
            fail("schema", filename, f"duplicate id {entity_id!r}", 3)
        seen.add(entity_id)


def _schema_nations(items: list) -> None:
    for index, entity in enumerate(items):
        path = f"nations[{index}]"
        _require_keys(
            entity,
            (
                "id",
                "name",
                "color",
                "capital_port_id",
                "start_port_id",
                "start_ship_type_id",
                "start_gold",
                "start_reputation",
                "bonus_attribute",
                "bonus_skill",
                "description",
            ),
            path,
            "nations.json",
        )
        if not isinstance(entity.get("color",), str) or not COLOR_RE.match(entity["color"]):
            fail("schema", "nations.json", f"{path}.color must be hex #rrggbb", 3)
        _require_id(entity["capital_port_id"], f"{path}.capital_port_id", "nations.json")
        _require_id(entity["start_port_id"], f"{path}.start_port_id", "nations.json")
        _require_id(entity["start_ship_type_id"], f"{path}.start_ship_type_id", "nations.json")
        _require_int(entity["start_gold"], f"{path}.start_gold", "nations.json", 0)
        _require_int(
            entity["start_reputation"],
            f"{path}.start_reputation",
            "nations.json",
            -100,
            100,
        )
        # Phase 8 (§4.1): the new-game +5 pair — one attribute id and one of
        # the 8 player skill ids (50-* §4.2).
        _require_enum(entity["bonus_attribute"], PERSON_ATTRIBUTES,
                      f"{path}.bonus_attribute", "nations.json")
        _require_enum(entity["bonus_skill"], PLAYER_SKILLS,
                      f"{path}.bonus_skill", "nations.json")


def _schema_goods(items: list) -> None:
    for index, entity in enumerate(items):
        path = f"goods[{index}]"
        _require_keys(
            entity, ("id", "name", "category", "base_price", "unit_size"), path, "goods.json"
        )
        _require_enum(entity["category"], GOOD_CATEGORIES, f"{path}.category", "goods.json")
        _require_int(entity["base_price"], f"{path}.base_price", "goods.json", 0)
        _require_int(entity["unit_size"], f"{path}.unit_size", "goods.json", 1)
        if entity["unit_size"] != 1:
            fail("schema", "goods.json", f"{path}.unit_size is locked at 1", 3)
        # Phase 7 (10-* §4.2): tier flags + optional flow overrides. The tier
        # split counts are group 7's (§8.2 item 5); the flags are bools here.
        for flag in ("staple", "specialty", "exclusive"):
            if flag in entity and not isinstance(entity[flag], bool):
                fail("schema", "goods.json",
                     f"{path}.{flag} must be a bool (got {entity[flag]!r})", 3)
        if entity.get("exclusive") and not entity.get("specialty"):
            fail("schema", "goods.json",
                 f"{path} ({entity['id']}): exclusive ⇒ specialty (§4.2 — "
                 "专营货 is the alignment-gated subset of specialties)", 3)
        if "flow" in entity:
            flow = entity["flow"]
            if not isinstance(flow, dict):
                fail("schema", "goods.json", f"{path}.flow must be an object", 3)
            keys = set(flow)
            if keys != {"prod", "cons", "capacity"}:
                fail("schema", "goods.json",
                     f"{path}.flow must have exactly keys prod,cons,capacity "
                     "— all three together or none (§4.2)", 3)
            for key in ("prod", "cons", "capacity"):
                _require_int(flow[key], f"{path}.flow.{key}", "goods.json", 1)
            if flow["capacity"] > 200:
                fail("schema", "goods.json",
                     f"{path}.flow.capacity ({flow['capacity']}) is above the "
                     "hard ceiling 200 (§4.2 STOCK_MAX)", 3)


def _schema_ship_types(items: list) -> None:
    # §4.3 partition is static: the two hardcoded tiers must stay disjoint,
    # cover the 16 locked hulls and name nothing outside the locked set.
    overlap = sorted(set(BATTLE_TURN_RATE_90_IDS) & set(BATTLE_TURN_RATE_45_IDS))
    if overlap:
        fail(
            "schema",
            "ship_types.json",
            f"§4.3 turn-rate tiers overlap: {', '.join(overlap)}",
            3,
        )
    uncovered = sorted(
        set(LOCKED_SHIP_TYPES) - set(BATTLE_TURN_RATE_90_IDS)
        - set(BATTLE_TURN_RATE_45_IDS)
    )
    if uncovered:
        fail(
            "schema",
            "ship_types.json",
            f"§4.3 turn-rate tiers leave hulls uncovered: {', '.join(uncovered)}",
            3,
        )
    stray = sorted(
        (set(BATTLE_TURN_RATE_90_IDS) | set(BATTLE_TURN_RATE_45_IDS))
        - set(LOCKED_SHIP_TYPES)
    )
    if stray:
        fail(
            "schema",
            "ship_types.json",
            f"§4.3 turn-rate tiers name non-hull ids: {', '.join(stray)}",
            3,
        )
    for index, entity in enumerate(items):
        path = f"ship_types[{index}]"
        _require_keys(
            entity,
            (
                "id",
                "name",
                "class",
                "base_price",
                "durability",
                "capacity",
                "speed",
                "crew_min",
                "crew_max",
                "armament_slots",
                "battle_max_speed",
                "battle_accel",
                "battle_turn_rate",
            ),
            path,
            "ship_types.json",
        )
        _require_enum(entity["class"], SHIP_CLASSES, f"{path}.class", "ship_types.json")
        # Phase 7 (10-* §4.3): `role` enum and `tier` gate on every hull.
        _require_enum(entity.get("role"), SHIP_ROLES, f"{path}.role", "ship_types.json")
        _require_int(entity.get("tier"), f"{path}.tier", "ship_types.json", 1, 3)
        _require_int(entity["base_price"], f"{path}.base_price", "ship_types.json", 0)
        _require_int(entity["durability"], f"{path}.durability", "ship_types.json", 1)
        _require_int(entity["capacity"], f"{path}.capacity", "ship_types.json", 1)
        _require_int(entity["speed"], f"{path}.speed", "ship_types.json", 1)
        _require_int(entity["crew_min"], f"{path}.crew_min", "ship_types.json", 1)
        _require_int(entity["crew_max"], f"{path}.crew_max", "ship_types.json", 1)
        _require_int(entity["armament_slots"], f"{path}.armament_slots", "ship_types.json", 0)
        if entity["crew_max"] < entity["crew_min"]:
            fail(
                "schema",
                "ship_types.json",
                f"{path}.crew_max ({entity['crew_max']}) must be >= crew_min "
                f"({entity['crew_min']})",
                3,
            )
        # §6.1 locked speed set: every hull's FINAL speed lies in {16, 20, 24}
        # (§4.3 — task S snapped the two 18s first-pass values into the set).
        if entity["speed"] not in LOCKED_SHIP_SPEEDS:
            fail(
                "schema",
                "ship_types.json",
                f"{path}.speed ({entity['speed']}) is outside the §6.1 locked "
                "set {16, 20, 24}",
                3,
            )
        # Phase 9 (10-* §4.3 / §8 group 3): the three battle fields.
        # battle_max_speed: int 2..4 via the exact per-speed mapping
        # 16→2 / 20→3 / 24→4 (correction 3); consumed by the battle cap_eff
        # clamp (60-* §4.3a).
        _require_int(entity["battle_max_speed"], f"{path}.battle_max_speed",
                     "ship_types.json", 3, 5)
        expected_battle_speed = BATTLE_MAX_SPEED_BY_SPEED[entity["speed"]]
        if entity["battle_max_speed"] != expected_battle_speed:
            fail(
                "schema",
                "ship_types.json",
                f"{path}.battle_max_speed ({entity['battle_max_speed']}) must "
                f"follow the §4.3 per-speed mapping "
                f"({entity['speed']}→{expected_battle_speed})",
                3,
            )
        # battle_accel: oar hulls 2, sail/hybrid 1 (§4.3).
        _require_int(entity["battle_accel"], f"{path}.battle_accel",
                     "ship_types.json", 1, 2)
        expected_accel = 2 if entity["class"] == "oar" else 1
        if entity["battle_accel"] != expected_accel:
            fail(
                "schema",
                "ship_types.json",
                f"{path}.battle_accel ({entity['battle_accel']}) must be "
                f"{expected_accel} for class {entity['class']!r} — oar 2, "
                "sail/hybrid 1 (§4.3)",
                3,
            )
        # battle_turn_rate: the two-tier hull partition (§4.3) — every hull
        # id appears in exactly one tier (tier disjointness/coverage is
        # pinned by the const guards at function entry; a hull in BOTH
        # tiers is that overlap failure).
        _require_int(entity["battle_turn_rate"], f"{path}.battle_turn_rate",
                     "ship_types.json", 45, 90)
        in_90 = entity["id"] in BATTLE_TURN_RATE_90_IDS
        in_45 = entity["id"] in BATTLE_TURN_RATE_45_IDS
        if not in_90 and not in_45:
            fail(
                "schema",
                "ship_types.json",
                f"{path}.id ({entity['id']!r}) is in NEITHER §4.3 turn-rate "
                "tier",
                3,
            )
        expected_turn = 90 if in_90 else 45
        if entity["battle_turn_rate"] != expected_turn:
            fail(
                "schema",
                "ship_types.json",
                f"{path}.battle_turn_rate ({entity['battle_turn_rate']}) must "
                f"be {expected_turn} for hull {entity['id']!r} — the §4.3 "
                "two-tier partition",
                3,
            )


def _schema_ports(items: list, filename: str = "ports.json") -> None:
    """Port schema (docs/10-* section 4.4, Phase 4; Phase 7 amendment).
    `lat`/`lon` are the geographic truth and the grid tile is derived by
    section 6.1's harbor-snap rule. The retired dual-map keys (`marker`,
    `position`, `p3`, `phase`) are rejected outright so a stale edit cannot
    smuggle one back in; Phase 7 retires `market_goods` (the market rows
    derive from produces ∪ demands, §4.2) and the int form of
    `facilities.shipyard`, and adds band/protected/dev/sphere plus the two
    stock-list facilities."""
    RETIRED = ("marker", "position", "p3", "phase", "market_goods")
    for index, entity in enumerate(items):
        path = f"{filename}[{index}]"
        _require_keys(
            entity,
            ("id", "name", "nation_id", "lat", "lon", "produces", "demands",
             "band", "dev", "sphere", "facilities", "flavor"),
            path,
            filename,
        )
        for key in RETIRED:
            if key in entity:
                fail(
                    "schema",
                    filename,
                    f"{path}.{key} is retired"
                    + (" in Phase 4 (lat/lon are the only coordinates, 10-* 4.4)"
                       if key in ("marker", "position", "p3", "phase") else
                       " in Phase 7 (market rows derive from produces ∪ "
                       "demands, 10-* 4.2)")
                    ,
                    3,
                )
        if entity["nation_id"] == NEUTRAL_PORT_NATION_ID:
            # Phase-6 neutral tier (§7.1): "" is the tier's nation id, not an
            # id regex violation. Facilities are data-driven over the four
            # phase-1 keys only — guild/palace are sovereign institutions.
            pass
        else:
            _require_id(entity["nation_id"], f"{path}.nation_id", filename)
        _require_number(entity["lat"], f"{path}.lat", filename, -90.0, 90.0)
        _require_number(entity["lon"], f"{path}.lon", filename, -180.0, 180.0)
        _require_id_list(entity["produces"], f"{path}.produces", filename)
        _require_id_list(entity["demands"], f"{path}.demands", filename)
        # -- Phase 7 (§4.4): band / protected / dev / sphere ------------------
        _require_id(entity.get("band"), f"{path}.band", filename)
        if "protected" in entity and not isinstance(entity["protected"], bool):
            fail("schema", filename,
                 f"{path}.protected must be a bool (got {entity['protected']!r})", 3)
        _require_int(entity.get("dev"), f"{path}.dev", filename, 0, 3)
        _require_id_list(entity.get("sphere"), f"{path}.sphere", filename)
        facilities = entity["facilities"]
        if not isinstance(facilities, dict):
            fail("schema", filename, f"{path}.facilities must be an object", 3)
        for key, value in facilities.items():
            if key in FACILITY_ARRAY_KEYS:
                continue  # shape-checked right below
            if key not in FACILITY_PHASES:
                fail(
                    "schema",
                    filename,
                    f"{path}.facilities has unknown facility {key!r}",
                    3,
                )
            _require_int(value, f"{path}.facilities.{key}", filename, 1)
            if value != FACILITY_PHASES[key]:
                fail(
                    "schema",
                    filename,
                    f"{path}.facilities.{key} is locked at {FACILITY_PHASES[key]}",
                    3,
                )
        # `shipyard` (Phase 7 shape): an id array of 2–8 hulls; the retired
        # int form is rejected outright (§4.4).
        if "shipyard" in facilities:
            shipyard = facilities["shipyard"]
            if isinstance(shipyard, int):
                fail(
                    "schema",
                    filename,
                    f"{path}.facilities.shipyard is the retired Phase-6 int "
                    "form — Phase 7 stocks an id array (§4.4)",
                    3,
                )
            _require_id_list(
                shipyard, f"{path}.facilities.shipyard", filename,
                allow_empty=False)
            if not (SHIPYARD_STOCK_MIN <= len(shipyard) <= SHIPYARD_STOCK_MAX):
                fail(
                    "schema",
                    filename,
                    f"{path}.facilities.shipyard must hold "
                    f"{SHIPYARD_STOCK_MIN}–{SHIPYARD_STOCK_MAX} hull ids "
                    f"(got {len(shipyard)})",
                    3,
                )
        # `equipment_stock` (Phase 7): ≥ 2 ids, required at every shipyard
        # port; an equipment stock without a shipyard is a shape error.
        if "equipment_stock" in facilities:
            stock = facilities["equipment_stock"]
            _require_id_list(
                stock, f"{path}.facilities.equipment_stock", filename,
                allow_empty=False)
            if len(stock) < EQUIPMENT_STOCK_MIN:
                fail(
                    "schema",
                    filename,
                    f"{path}.facilities.equipment_stock must hold at least "
                    f"{EQUIPMENT_STOCK_MIN} ids (got {len(stock)})",
                    3,
                )
            if "shipyard" not in facilities:
                fail(
                    "schema",
                    filename,
                    f"{path} ({entity['id']}) carries equipment_stock without "
                    "a shipyard (§4.4 — the stock list exists at shipyard "
                    "ports)",
                    3,
                )
        elif "shipyard" in facilities:
            fail(
                "schema",
                filename,
                f"{path} ({entity['id']}) has a shipyard but no "
                "facilities.equipment_stock (§4.4 — required at every "
                "shipyard port)",
                3,
            )
        if entity["nation_id"] == NEUTRAL_PORT_NATION_ID:
            for key in facilities:
                if key not in NEUTRAL_FACILITY_KEYS:
                    fail(
                        "schema",
                        filename,
                        f"{path} ({entity['id']}) is a neutral-tier port: "
                        f"facility {key!r} is not one of "
                        f"{sorted(NEUTRAL_FACILITY_KEYS)} (§7.1)",
                        3,
                    )
        else:
            for key in PORT_FACILITIES_REQUIRED:
                if key not in facilities:
                    fail(
                        "schema",
                        filename,
                        f"{path}.facilities missing required facility {key!r}",
                        3,
                    )
        if "palace" in facilities and entity["id"] not in CAPITAL_PORT_IDS:
            fail(
                "schema", filename,
                f"{path}: only the six capitals may host a palace (10-* 7.4)",
                3,
            )


OFFICER_CARD_FIELDS = (
    "id", "name", "nation_id", "legend", "main_skill", "attributes",
    "skills", "personality", "appearance", "wage_daily", "recruit_ports",
    "bio",
)
APPEARANCE_AXES = ("face", "beard", "eyes", "hair")


def _check_person_attributes(entity: dict, path: str, filename: str) -> None:
    """The 5-key attribute block with ints 1–100 (§4.5/§4.11)."""
    attributes = entity["attributes"]
    if not isinstance(attributes, dict) or set(attributes) != set(PERSON_ATTRIBUTES):
        fail(
            "schema",
            filename,
            f"{path}.attributes must have exactly keys "
            f"{','.join(PERSON_ATTRIBUTES)}",
            3,
        )
    for attr in PERSON_ATTRIBUTES:
        _require_int(attributes[attr], f"{path}.attributes.{attr}", filename, 1, 100)


def _check_appearance(entity: dict, path: str, filename: str) -> None:
    """Exactly the 4 appearance axes, one value each (§4.11)."""
    appearance = entity["appearance"]
    if not isinstance(appearance, dict) or set(appearance) != set(APPEARANCE_AXES):
        fail(
            "schema",
            filename,
            f"{path}.appearance must have exactly keys "
            f"{','.join(APPEARANCE_AXES)}",
            3,
        )
    for axis in APPEARANCE_AXES:
        if not isinstance(appearance[axis], str) or not appearance[axis]:
            fail(
                "schema",
                filename,
                f"{path}.appearance.{axis} must be a value id (got "
                f"{appearance[axis]!r})",
                3,
            )


def _schema_officers(items: list) -> None:
    """Officer card v2 (docs/10-* section 4.5, Phase 8 — built artifact):
    the shared person-card shape plus the three officer-only skills. The
    bands, quotas, pools and recruit rules are group 12's (§8.7); the
    vocabulary memberships live there too (they read the name parts)."""
    for index, entity in enumerate(items):
        path = f"officers[{index}]"
        if set(entity) != set(OFFICER_CARD_FIELDS):
            missing = sorted(set(OFFICER_CARD_FIELDS) - set(entity))
            extra = sorted(set(entity) - set(OFFICER_CARD_FIELDS))
            details = []
            if missing:
                details.append(f"missing {', '.join(missing)}")
            if extra:
                details.append(f"unexpected {', '.join(extra)}")
            fail(
                "schema",
                "officers.json",
                f"{path}: officer v2 field set must be exactly the §4.5 "
                f"card: {'; '.join(details)}",
                3,
            )
        _require_id(entity["nation_id"], f"{path}.nation_id", "officers.json")
        if not isinstance(entity["legend"], bool):
            fail("schema", "officers.json",
                 f"{path}.legend must be a bool (got {entity['legend']!r})", 3)
        if entity["main_skill"] not in OFFICER_SKILL_NAMES:
            fail(
                "schema",
                "officers.json",
                f"{path}.main_skill {entity['main_skill']!r} is not one of "
                f"the 11 skills",
                3,
            )
        _check_person_attributes(entity, path, "officers.json")
        skills = entity["skills"]
        if not isinstance(skills, dict) or set(skills) != set(OFFICER_SKILL_NAMES):
            fail(
                "schema",
                "officers.json",
                f"{path}.skills must have exactly the 11 keys "
                f"(8 player + medicine/carpentry/cooking)",
                3,
            )
        for skill in OFFICER_SKILL_NAMES:
            _require_int(skills[skill], f"{path}.skills.{skill}",
                         "officers.json", 0, 100)
        # §4.5: main_skill is the strict maximum of skills.
        main_value = skills[entity["main_skill"]]
        for skill, value in skills.items():
            if skill != entity["main_skill"] and value >= main_value:
                fail(
                    "schema",
                    "officers.json",
                    f"{path} ({entity['id']}): main_skill "
                    f"{entity['main_skill']} ({main_value}) is not the "
                    f"strict maximum ({skill} = {value})",
                    3,
                )
        personality = entity["personality"]
        if not isinstance(personality, list) or not (
                1 <= len(personality) <= 2):
            fail(
                "schema",
                "officers.json",
                f"{path}.personality must be 1–2 tag ids",
                3,
            )
        for tag_index, tag in enumerate(personality):
            _require_id(tag, f"{path}.personality[{tag_index}]", "officers.json")
        _check_appearance(entity, path, "officers.json")
        _require_int(entity["wage_daily"], f"{path}.wage_daily",
                     "officers.json", 0)
        _require_id_list(
            entity["recruit_ports"], f"{path}.recruit_ports", "officers.json",
            allow_empty=False
        )


def _schema_skill_gates(items: list) -> None:
    """SkillGate rows (docs/10-* section 4.20, Phase 8). Field shapes only —
    the locked inventory and the sail.autopilot pin are group 12's (§8.7
    item 6); the stat_or_skill vocabulary is group 4's (referential)."""
    label = "skill_gates.json"
    seen: set[str] = set()
    for index, entity in enumerate(items):
        path = f"skill_gates[{index}]"
        if set(entity) != {"feature_id", "name", "stat_or_skill",
                           "threshold", "reason"}:
            fail(
                "schema",
                label,
                f"{path} must be an object with exactly keys "
                "feature_id,name,stat_or_skill,threshold,reason "
                "(section 4.20)",
                3,
            )
        feature_id = entity["feature_id"]
        if not isinstance(feature_id, str) or not FEATURE_ID_RE.match(feature_id):
            fail(
                "schema",
                label,
                f"{path}.feature_id {feature_id!r} is not a "
                "`<system>.<feature>` id",
                3,
            )
        if feature_id in seen:
            fail("schema", label, f"duplicate feature_id {feature_id!r}", 3)
        seen.add(feature_id)
        _require_int(entity["threshold"], f"{path}.threshold", label, 1, 99)


def _schema_officer_posts(items: list) -> None:
    """OfficerPost rows (docs/10-* section 4.21, Phase 8). Shapes only — the
    locked prereq values, advice params and the ui_strings closure are
    group 12's (§8.7 item 7)."""
    label = "officer_posts.json"
    seen: set[str] = set()
    for index, entity in enumerate(items):
        path = f"officer_posts[{index}]"
        if not isinstance(entity, dict) or \
                not {"post_id", "slot_type", "prereq", "desc"} <= set(entity):
            fail(
                "schema",
                label,
                f"{path} must be an object with keys "
                "post_id,slot_type,prereq,desc[,advice] (section 4.21)",
                3,
            )
        post_id = entity["post_id"]
        if post_id not in LOCKED_POST_IDS:
            fail(
                "schema",
                label,
                f"{path}.post_id {post_id!r} must be one of "
                f"{'|'.join(LOCKED_POST_IDS)}",
                3,
            )
        if post_id in seen:
            fail("schema", label, f"duplicate post_id {post_id!r}", 3)
        seen.add(post_id)
        _require_enum(entity["slot_type"], ("flagship", "captain"),
                      f"{path}.slot_type", label)
        prereq = entity["prereq"]
        if not isinstance(prereq, dict) or not prereq:
            fail("schema", label, f"{path}.prereq must be a non-empty object "
                 "of stat/skill id → minimum", 3)
        for stat, minimum in prereq.items():
            if stat not in GATE_STAT_SKILLS:
                fail(
                    "schema",
                    label,
                    f"{path}.prereq key {stat!r} is not an attribute or "
                    "skill id",
                    3,
                )
            _require_int(minimum, f"{path}.prereq.{stat}", label, 1, 99)
        if "advice" in entity:
            advice = entity["advice"]
            if not isinstance(advice, dict):
                fail("schema", label, f"{path}.advice must be an object of "
                     "situation id → trigger params", 3)
            for situation, params in advice.items():
                if situation not in ADVICE_SITUATIONS:
                    fail(
                        "schema",
                        label,
                        f"{path}.advice situation {situation!r} is outside "
                        f"the 6 locked situations "
                        f"({'|'.join(ADVICE_SITUATIONS)})",
                        3,
                    )
                if not isinstance(params, dict):
                    fail("schema", label,
                         f"{path}.advice.{situation} must be an object", 3)


def _check_background_rules(items: list) -> None:
    """§4.22/§8.7 item 8: exactly one attribute key = 3 and exactly one
    skill key = 5 per background. Shared by groups 3 and 12 (the §8.7
    negative list owns the failures: a two-attribute background, a +4 skill
    bonus, a 7th background)."""
    label = "backgrounds.json"
    for index, entity in enumerate(items):
        path = f"backgrounds[{index}]"
        for field, vocabulary, value in (
                ("attribute_bonus", PERSON_ATTRIBUTES, 3),
                ("skill_bonus", OFFICER_SKILL_NAMES, 5)):
            bonus = entity.get(field)
            if not isinstance(bonus, dict) or len(bonus) != 1:
                fail(
                    "schema",
                    label,
                    f"{path}.{field} must be an object with exactly one key "
                    f"(got {bonus!r})",
                    3,
                )
            key = next(iter(bonus))
            if key not in vocabulary:
                fail(
                    "schema",
                    label,
                    f"{path}.{field} key {key!r} is not a known id",
                    3,
                )
            if bonus[key] != value:
                fail(
                    "schema",
                    label,
                    f"{path}.{field}.{key} must be {value} (got {bonus[key]!r})",
                    3,
                )


def _schema_backgrounds(items: list) -> None:
    """Background rows (docs/10-* section 4.22, Phase 8). The exact 6-id
    §7.10 set and the zh/en names are group 5's identity lock."""
    label = "backgrounds.json"
    for index, entity in enumerate(items):
        path = f"backgrounds[{index}]"
        if set(entity) != {"id", "name", "attribute_bonus", "skill_bonus", "bio"}:
            fail(
                "schema",
                label,
                f"{path} must be an object with exactly keys "
                "id,name,attribute_bonus,skill_bonus,bio (section 4.22)",
                3,
            )
    _check_background_rules(items)


def _schema_equipment(items: list) -> None:
    for index, entity in enumerate(items):
        path = f"equipment[{index}]"
        _require_keys(
            entity, ("id", "name", "slot", "modifiers", "price", "tier", "phase"),
            path, "equipment.json"
        )
        _require_enum(entity["slot"], EQUIPMENT_SLOTS, f"{path}.slot", "equipment.json")
        # Phase 7 (10-* §4.6): `tier` gate on every item; `rare` marks the 4
        # drop-only items (exactly-4 count and never-stocked are group 7's).
        _require_int(entity.get("tier"), f"{path}.tier", "equipment.json", 1, 3)
        if "rare" in entity and not isinstance(entity["rare"], bool):
            fail("schema", "equipment.json",
                 f"{path}.rare must be a bool (got {entity['rare']!r})", 3)
        modifiers = entity["modifiers"]
        if not isinstance(modifiers, dict):
            fail("schema", "equipment.json", f"{path}.modifiers must be an object", 3)
        if not modifiers:
            # docs/10-* section 4.6: an item with no modifiers would be a
            # pure decoration costing money and changing nothing.
            fail("schema", "equipment.json", f"{path}.modifiers must not be empty", 3)
        for stat, delta in modifiers.items():
            _require_int(delta, f"{path}.modifiers.{stat}", "equipment.json")
            # Negative modifiers are legal (a cursed item, section 4.11.13 has
            # none yet), but a 0 delta is a no-op typo, not content.
            if delta == 0:
                fail(
                    "schema",
                    "equipment.json",
                    f"{path}.modifiers.{stat} must have |delta| >= 1 (got 0)",
                    3,
                )
        # §4.6 field rule: the whole set sits inside the 300–6,000 g band
        # (§7.9; the per-tier guideline stays an authoring guideline).
        _require_int(entity["price"], f"{path}.price", "equipment.json", 300, 6000)
        _require_int(entity["phase"], f"{path}.phase", "equipment.json", 2, 2)


def _schema_discoveries(items: list, filename: str = "discoveries.json") -> None:
    """Discovery schema (docs/10-* section 4.7, Phase 4): `lat`/`lon` replace
    the old tile `position`, and the dead `phase` key is rejected."""
    for index, entity in enumerate(items):
        path = f"discoveries[{index}]"
        _require_keys(
            entity,
            (
                "id", "name", "category", "lat", "lon", "fame",
                "report_reward_gold", "region_hint",
            ),
            path,
            "discoveries.json",
        )
        for key in ("position", "phase"):
            if key in entity:
                fail(
                    "schema", "discoveries.json",
                    f"{path}.{key} is retired in Phase 4 (lat/lon only)",
                    3,
                )
        _require_enum(
            entity["category"], DISCOVERY_CATEGORIES, f"{path}.category", "discoveries.json"
        )
        _require_number(entity["lat"], f"{path}.lat", "discoveries.json", -90.0, 90.0)
        _require_number(entity["lon"], f"{path}.lon", "discoveries.json", -180.0, 180.0)
        _require_int(entity["fame"], f"{path}.fame", "discoveries.json", 1)
        _require_int(
            entity["report_reward_gold"], f"{path}.report_reward_gold", "discoveries.json", 0
        )


def _schema_quests(items: list) -> None:
    for index, entity in enumerate(items):
        path = f"quests[{index}]"
        _require_keys(
            entity,
            (
                "id",
                "type",
                "giver",
                "name",
                "description",
                "requirements",
                "rewards",
                "expiry_days",
                "phase",
            ),
            path,
            "quests.json",
        )
        _require_enum(entity["type"], QUEST_TYPES, f"{path}.type", "quests.json")
        _require_enum(entity["giver"], QUEST_GIVERS, f"{path}.giver", "quests.json")
        requirements = entity["requirements"]
        if not isinstance(requirements, dict):
            fail("schema", "quests.json", f"{path}.requirements must be an object", 3)
        if entity["type"] == "delivery":
            _require_keys(
                requirements,
                ("good_id", "quantity", "dest_port_id"),
                f"{path}.requirements",
                "quests.json",
            )
            _require_id(requirements["good_id"], f"{path}.requirements.good_id", "quests.json")
            _require_int(
                requirements["quantity"], f"{path}.requirements.quantity", "quests.json", 1
            )
            _require_id(
                requirements["dest_port_id"], f"{path}.requirements.dest_port_id", "quests.json"
            )
        elif entity["type"] == "bounty":
            # A bounty **template** leaves the target empty: the fleet is
            # spawned when an offer is accepted (docs/70-* section 4.9.3), so
            # only a filled-in value has to be an id.
            _require_keys(
                requirements, ("target_fleet_id",), f"{path}.requirements", "quests.json"
            )
            if requirements["target_fleet_id"] != "":
                _require_id(
                    requirements["target_fleet_id"],
                    f"{path}.requirements.target_fleet_id",
                    "quests.json",
                )
        elif entity["type"] == "exploration":
            _require_keys(
                requirements, ("discovery_id",), f"{path}.requirements", "quests.json"
            )
            if requirements["discovery_id"] != "":
                _require_id(
                    requirements["discovery_id"],
                    f"{path}.requirements.discovery_id",
                    "quests.json",
                )
        else:  # royal
            _require_keys(
                requirements, ("objective", "dest_port_id"), f"{path}.requirements", "quests.json"
            )
            _require_id(
                requirements["dest_port_id"], f"{path}.requirements.dest_port_id", "quests.json"
            )
        rewards = entity["rewards"]
        if not isinstance(rewards, dict):
            fail("schema", "quests.json", f"{path}.rewards must be an object", 3)
        _require_keys(rewards, ("gold", "reputation", "fame"), f"{path}.rewards", "quests.json")
        _require_int(rewards["gold"], f"{path}.rewards.gold", "quests.json", 0)
        _require_int(rewards["fame"], f"{path}.rewards.fame", "quests.json", 0)
        reputation = rewards["reputation"]
        if not isinstance(reputation, dict):
            fail("schema", "quests.json", f"{path}.rewards.reputation must be an object", 3)
        for nation_id, delta in reputation.items():
            _require_id(nation_id, f"{path}.rewards.reputation key", "quests.json")
            _require_int(delta, f"{path}.rewards.reputation.{nation_id}", "quests.json")
        _require_int(entity["expiry_days"], f"{path}.expiry_days", "quests.json", 1)
        _require_int(entity["phase"], f"{path}.phase", "quests.json", 3, 3)


def _schema_map_legend(legend: dict) -> None:
    """Structural checks for map_legend.json (owned by T3; type-level only)."""
    _require_int(legend.get("tile_size_px",), "tile_size_px", "map_legend.json", 1)
    if legend["tile_size_px"] != 32:
        fail("schema", "map_legend.json", "tile_size_px is locked at 32", 3)
    grid = legend.get("grid",)
    if not isinstance(grid, dict) or set(grid) != {"width", "height"}:
        fail(
            "schema",
            "map_legend.json",
            "grid must be an object with exactly keys width,height",
            3,
        )
    _require_int(grid["width"], "grid.width", "map_legend.json", 1)
    _require_int(grid["height"], "grid.height", "map_legend.json", 1)
    if grid["width"] != MAP_WIDTH or grid["height"] != MAP_HEIGHT:
        fail(
            "schema",
            "map_legend.json",
            f"grid is locked at {MAP_WIDTH}x{MAP_HEIGHT}",
            3,
        )
    tiles = legend.get("tiles",)
    if not isinstance(tiles, dict):
        fail("schema", "map_legend.json", "tiles must be an object", 3)
    if set(tiles) != set(LOCKED_TILE_KINDS):
        fail(
            "schema",
            "map_legend.json",
            f"tiles keys are locked at {' '.join(sorted(LOCKED_TILE_KINDS))}",
            3,
        )
    for char, tile in tiles.items():
        if not isinstance(tile, dict):
            fail("schema", "map_legend.json", f"tiles[{char!r}] must be an object", 3)
        if not isinstance(tile.get("kind",), str) or not tile["kind"]:
            fail("schema", "map_legend.json", f"tiles[{char!r}].kind must be a string", 3)
        if not isinstance(tile.get("passable",), bool):
            fail("schema", "map_legend.json", f"tiles[{char!r}].passable must be a boolean", 3)
        expected_kind, expected_passable = LOCKED_TILE_KINDS[char]
        if tile["kind"] != expected_kind or tile["passable"] != expected_passable:
            fail(
                "schema",
                "map_legend.json",
                f"tiles[{char!r}] is locked at kind={expected_kind!r} "
                f"passable={expected_passable}",
                3,
            )
    # Phase 4: markers left the map (10-* section 6.2 "ports are not terrain").
    if "port_markers" in legend:
        fail(
            "schema",
            "map_legend.json",
            "port_markers is retired in Phase 4 (ports are an overlay from "
            "ports.json lat/lon)",
            3,
        )


def check_group3(docs: dict[str, object], verbose: bool) -> None:
    """Per-entity fields, types, enums and ranges (section 4)."""
    # Phase 4: one port file. The old dual-file merge is gone, so every entity
    # file maps to exactly one plural and group 5's locked list is the same set.
    items = {
        plural: docs[filename][plural]
        for filename, plural in ENTITY_FILES.items()
    }

    for filename, plural in ENTITY_FILES.items():
        if filename in GROUP7_ENTITY_FILES or filename in GROUP8_ENTITY_FILES \
                or filename in GROUP12_SCHEMA_FILES:
            # Group 7 owns these files' structure, counts and bounds outright
            # (docs/10-* section 8.2 preamble), including event id uniqueness.
            # Group 8 likewise owns trade_routes.json (§4.14). The Phase-8
            # gate/post rows are keyed by feature_id/post_id, not `id` —
            # their schema functions own uniqueness (groups 3/12).
            continue
        _check_unique_ids(items[plural], plural, filename)

    _schema_nations(items["nations"])
    _schema_goods(items["goods"])
    _schema_ship_types(items["ship_types"])
    _schema_ports(items["ports"])
    _schema_officers(items["officers"])
    _schema_equipment(items["equipment"])
    _schema_discoveries(items["discoveries"])
    _schema_quests(items["quests"])
    # Phase 8 (§4.20–4.22): the W2-B file shapes.
    _schema_skill_gates(items["skill_gates"])
    _schema_officer_posts(items["officer_posts"])
    _schema_backgrounds(items["backgrounds"])

    if "map_legend.json" in docs:
        _schema_map_legend(docs["map_legend.json"])

    if verbose:
        total = sum(len(v) for v in items.values())
        print(f"PASS group 3 schema ({total} entities)")


# ---------------------------------------------------------------------------
# Check group 4 — Referential integrity
# ---------------------------------------------------------------------------


def check_group4(docs: dict[str, object], verbose: bool) -> None:
    """Every relation listed in section 8, group 4."""
    nations = docs["nations.json"]["nations"]
    ports = docs["ports.json"]["ports"]
    goods = docs["goods.json"]["goods"]
    ship_types = docs["ship_types.json"]["ship_types"]
    officers = docs["officers.json"]["officers"]
    equipment = docs["equipment.json"]["equipment"]
    discoveries = docs["discoveries.json"]["discoveries"]
    quests = docs["quests.json"]["quests"]

    nation_ids = {n["id"] for n in nations}
    port_ids = {p["id"] for p in ports}
    good_ids = {g["id"] for g in goods}
    ship_type_ids = {s["id"] for s in ship_types}
    discovery_ids = {d["id"] for d in discoveries}
    capital_ids = set(CAPITAL_PORT_IDS)
    # Phase 7 (§8 group 4): rare equipment ids, for the equipment_stock rule.
    rare_equipment_ids = {e["id"] for e in equipment if e.get("rare") is True}

    for index, port in enumerate(ports):
        path = f"ports[{index}]"
        if port["nation_id"] == NEUTRAL_PORT_NATION_ID:
            # Phase-6 neutral tier (§7.1): exempt from `nation_id ∈ nations`
            # — the tier's whole point. produces/demands and the palace
            # checks below apply unchanged.
            pass
        elif port["nation_id"] not in nation_ids:
            fail(
                "ref",
                "ports.json",
                f"{path} ({port['id']}) nation_id {port['nation_id']!r} is not a known nation",
                4,
            )
        for field in ("produces", "demands"):
            if field not in port:
                continue
            for good_id in port[field]:
                if good_id not in good_ids:
                    fail(
                        "ref",
                        "ports.json",
                        f"{path} ({port['id']}) {field} references unknown good {good_id!r}",
                        4,
                    )
        # Phase 7 (§8 group 4): band ∈ the §7.1 recorded set; sphere ⊆
        # nations; the shipyard hull list and the equipment stock resolve;
        # rare drop-only items never sit in a stock list.
        if port.get("band") not in LOCKED_BANDS:
            fail(
                "ref",
                "ports.json",
                f"{path} ({port['id']}) band {port.get('band')!r} is outside "
                "the §7.1 recorded band id set",
                4,
            )
        for nation_id in port.get("sphere", ()):
            if nation_id not in nation_ids:
                fail(
                    "ref",
                    "ports.json",
                    f"{path} ({port['id']}) sphere references unknown nation "
                    f"{nation_id!r}",
                    4,
                )
        facilities = port["facilities"]
        for hull_id in facilities.get("shipyard", ()):
            if hull_id not in ship_type_ids:
                fail(
                    "ref",
                    "ports.json",
                    f"{path} ({port['id']}) facilities.shipyard references "
                    f"unknown ship type {hull_id!r}",
                    4,
                )
        for item_id in facilities.get("equipment_stock", ()):
            if item_id not in {e["id"] for e in equipment}:
                fail(
                    "ref",
                    "ports.json",
                    f"{path} ({port['id']}) facilities.equipment_stock "
                    f"references unknown equipment {item_id!r}",
                    4,
                )
            # The never-stocked rule itself (§8.2 item 11 wording, exit 7)
            # lives in group 7; the referential half is here.
            if item_id in rare_equipment_ids:
                fail(
                    "ref",
                    "ports.json",
                    f"{path} ({port['id']}) facilities.equipment_stock lists "
                    f"rare drop-only item {item_id!r} — rare items are never "
                    "stocked (§4.6/§7.9)",
                    4,
                )
        has_palace = "palace" in port["facilities"]
        is_capital = port["id"] in capital_ids
        if has_palace and not is_capital:
            fail(
                "ref",
                "ports.json",
                f"{path} ({port['id']}) has palace but is not a capital port",
                4,
            )
        if is_capital and not has_palace:
            fail(
                "ref",
                "ports.json",
                f"{path} ({port['id']}) is a capital port but has no palace facility",
                4,
            )
        # produces ∩ demands ≠ ∅ moved to a group-7 hard failure (§8.2 item 6,
        # correction 3 — the Phase-4 warning is retired with it).

    for index, nation in enumerate(nations):
        path = f"nations[{index}] ({nation['id']})"
        if nation["start_port_id"] not in port_ids:
            fail(
                "ref",
                "nations.json",
                f"{path} start_port_id {nation['start_port_id']!r} is not a known port",
                4,
            )
        if nation["capital_port_id"] not in port_ids:
            fail(
                "ref",
                "nations.json",
                f"{path} capital_port_id {nation['capital_port_id']!r} is not a known port",
                4,
            )
        if nation["start_ship_type_id"] not in ship_type_ids:
            fail(
                "ref",
                "nations.json",
                f"{path} start_ship_type_id "
                f"{nation['start_ship_type_id']!r} is not a known ship type",
                4,
            )

    for index, officer in enumerate(officers):
        path = f"officers[{index}] ({officer['id']})"
        if officer["nation_id"] not in nation_ids:
            fail(
                "ref",
                "officers.json",
                f"{path} nation_id {officer['nation_id']!r} is not a known nation",
                4,
            )
        for port_id in officer["recruit_ports"]:
            if port_id not in port_ids:
                fail(
                    "ref",
                    "officers.json",
                    f"{path} recruit_ports references unknown port {port_id!r}",
                    4,
                )

    # Phase 8 (§8 group 4): every gate's stat_or_skill is one of the 5
    # attributes + 11 skills; the background bonus keys are known
    # attribute/skill ids (the one-key/=3//=5 rules are group 3's).
    for index, gate in enumerate(docs["skill_gates.json"]["skill_gates"]):
        stat = gate.get("stat_or_skill")
        if stat not in GATE_STAT_SKILLS:
            fail(
                "ref",
                "skill_gates.json",
                f"skill_gates[{index}] ({gate.get('feature_id')}) "
                f"stat_or_skill {stat!r} is outside the 5 attributes + "
                "11 skills",
                4,
            )

    for index, item in enumerate(equipment):
        slot = item.get("slot",)
        modifiers = item.get("modifiers",)
        if not isinstance(modifiers, dict):
            continue  # schema group already reported this
        for stat in modifiers:
            # §4.6 (Phase 7): the known-stat set gains the two sideways keys —
            # `storm_damage_pct` and `scurvy_delay_days` (60-* §4.11.12).
            if stat not in EQUIPMENT_STAT_NAMES and stat not in \
                    EQUIPMENT_SIDEWAYS_KEYS:
                fail(
                    "ref",
                    "equipment.json",
                    f"equipment[{index}] ({item['id']}) modifiers has unknown stat {stat!r}",
                    4,
                )
            # docs/60-* section 4.11.12 slot/stat split: player-worn items
            # (`weapon`/`armor`) affect player stats only, ship-bound items
            # (`figurehead`/`sail`) affect ship-instance stats only. Mixing
            # them would make an engine accessor silently ignore a modifier.
            # The sideways keys are ship-system stats and legal on either
            # slot family (§4.11.12 wording).
            if slot in PLAYER_EQUIPMENT_SLOTS and stat in SHIP_STAT_NAMES:
                fail(
                    "ref",
                    "equipment.json",
                    f"equipment[{index}] ({item['id']}) is a {slot} item and may "
                    f"only modify player stats "
                    f"({'|'.join(PLAYER_STAT_NAMES)}), not ship stat {stat!r}",
                    4,
                )
            if slot in SHIP_EQUIPMENT_SLOTS and stat in PLAYER_STAT_NAMES:
                fail(
                    "ref",
                    "equipment.json",
                    f"equipment[{index}] ({item['id']}) is a {slot} item and may "
                    f"only modify ship stats "
                    f"({'|'.join(SHIP_STAT_NAMES)}), not player stat {stat!r}",
                    4,
                )

    # Phase 7 (§8 group 4): every named-pirate `drop` references a
    # `rare: true` equipment item. (The distinctness/1:1 pairing is
    # group 7 item 12.)
    pirates = docs["named_pirates.json"].get("named_pirates", [])
    equipment_by_id = {e["id"]: e for e in equipment}
    for index, pirate in enumerate(pirates):
        drop = pirate.get("drop")
        if drop is None:
            continue  # group 7 owns the required-key shape
        if drop not in equipment_by_id:
            fail(
                "ref",
                "named_pirates.json",
                f"named_pirates[{index}] ({pirate.get('id')}) drop "
                f"{drop!r} is not a known equipment id",
                4,
            )
        if equipment_by_id[drop].get("rare") is not True:
            fail(
                "ref",
                "named_pirates.json",
                f"named_pirates[{index}] ({pirate.get('id')}) drop {drop!r} "
                "does not reference a rare: true item (§4.12 — drops come "
                "from the four rare items of §7.9)",
                4,
            )

    for index, quest in enumerate(quests):
        path = f"quests[{index}] ({quest['id']})"
        requirements = quest["requirements"]
        if quest["type"] == "delivery":
            if requirements["good_id"] not in good_ids:
                fail(
                    "ref",
                    "quests.json",
                    f"{path} good_id {requirements['good_id']!r} is not a known good",
                    4,
                )
        if quest["type"] == "exploration" and requirements.get("discovery_id",):
            # Empty on a template (the draw fills it, docs/70-* section 4.9.3).
            if requirements["discovery_id"] not in discovery_ids:
                fail(
                    "ref",
                    "quests.json",
                    f"{path} discovery_id "
                    f"{requirements['discovery_id']!r} is not a known discovery",
                    4,
                )
        if "dest_port_id" in requirements and requirements["dest_port_id"] not in port_ids:
            fail(
                "ref",
                "quests.json",
                f"{path} dest_port_id {requirements['dest_port_id']!r} is not a known port",
                4,
            )
        for nation_id in quest["rewards"]["reputation"]:
            if nation_id not in nation_ids:
                fail(
                    "ref",
                    "quests.json",
                    f"{path} rewards.reputation references unknown nation {nation_id!r}",
                    4,
                )

    if verbose:
        print("PASS group 4 referential integrity")


# ---------------------------------------------------------------------------
# Check group 5 — Locked lists
# ---------------------------------------------------------------------------


def _locked_id_sets(items: list, locked: dict, plural: str, filename: str) -> None:
    expected = set(locked)
    actual = [item["id"] for item in items]
    if len(actual) != len(expected) or set(actual) != expected:
        missing = sorted(expected - set(actual))
        extra = sorted(set(actual) - expected)
        details = []
        if missing:
            details.append(f"missing {', '.join(missing)}")
        if extra:
            details.append(f"unexpected {', '.join(extra)}")
        if not details:
            details.append(f"count {len(actual)} != {len(expected)} or duplicate ids")
        fail("locked-list", filename, f"{plural}: {'; '.join(details)}", 5)


def _check_l10n_text(
    entity: dict, field_key: str, zh: str, en: str, path: str, filename: str
) -> None:
    value = entity.get(field_key)
    if not isinstance(value, dict):
        return  # schema group already reported this; keep group 5 focused
    if value.get("zh",) != zh or value.get("en",) != en:
        fail(
            "locked-content",
            filename,
            f"{path}.{field_key} must be zh={zh!r} en={en!r} per section 7",
            5,
        )


def _lock_officers_v2(officers: list) -> None:
    """§7.5 (Phase 8): the roster holds exactly 96 officers — 24 legends +
    72 regulars (the count/quota detail is §8.7's); the 6 Phase-1 starter
    ids are locked, and each starter keeps its v1 identity verbatim: zh/en
    name, nation, recruit ports and bio (the §7.5 table; bios as shipped in
    v1). The other 90 members are builder-generated and checked by groups
    11–12 instead."""
    if len(officers) != LOCKED_COUNTS["officers"]:
        fail(
            "locked-count",
            "officers.json",
            f"officers: count {len(officers)} != the locked "
            f"{LOCKED_COUNTS['officers']} (24 legends + 72 regulars, §7.5)",
            5,
        )
    legends = [o for o in officers if o.get("legend") is True]
    if len(legends) != OFFICER_LEGEND_COUNT:
        fail(
            "locked-list",
            "officers.json",
            f"exactly {OFFICER_LEGEND_COUNT} legend officers are locked "
            f"(§7.5), got {len(legends)}",
            5,
        )
    by_id = {o.get("id"): o for o in officers}
    missing = [sid for sid in STARTER_IDS if sid not in by_id]
    if missing:
        fail(
            "locked-list",
            "officers.json",
            f"missing the §7.5 starter id(s) {', '.join(missing)}",
            5,
        )
    for starter_id in STARTER_IDS:
        officer = by_id[starter_id]
        identity = STARTER_IDENTITY[starter_id]
        path = f"officers[{starter_id}]"
        _check_l10n_text(officer, "name", identity["zh"], identity["en"],
                         path, "officers.json")
        expected = {
            "nation_id": identity["nation_id"],
            "recruit_ports": list(identity["recruit_ports"]),
        }
        for field, value in expected.items():
            if officer.get(field) != value:
                fail(
                    "locked-content",
                    "officers.json",
                    f"{path} {field} must be {value} (§7.5 identity lock)",
                    5,
                )
        bio = officer.get("bio")
        if not isinstance(bio, dict) or bio.get("zh") != identity["bio_zh"] \
                or bio.get("en") != identity["bio_en"]:
            fail(
                "locked-content",
                "officers.json",
                f"{path} bio must stay verbatim from the v1 roster (§7.5 "
                "identity lock)",
                5,
            )


def check_group5(docs: dict[str, object], verbose: bool) -> None:
    """The §7.1 lock model: the sovereign-100 exact set + the neutral tier,
    then the other section 7 tables."""
    ports_all = docs["ports.json"]["ports"]
    goods = docs["goods.json"]["goods"]
    ship_types = docs["ship_types.json"]["ship_types"]
    nations = docs["nations.json"]["nations"]
    officers = docs["officers.json"]["officers"]
    equipment = docs["equipment.json"]["equipment"]
    backgrounds = docs["backgrounds.json"]["backgrounds"]

    # -- §7.1 lock model (Phase 6): sovereign exact set + neutral tier --------
    sovereign = [port for port in ports_all
                 if port.get("nation_id") != NEUTRAL_PORT_NATION_ID]
    neutral = [port for port in ports_all
               if port.get("nation_id") == NEUTRAL_PORT_NATION_ID]
    _locked_id_sets(sovereign, LOCKED_PORTS, "sovereign ports", "ports.json")
    _locked_id_sets(
        [entry for entry in goods], LOCKED_GOODS, "goods", "goods.json")
    _locked_id_sets(ship_types, LOCKED_SHIP_TYPES, "ship_types", "ship_types.json")
    _locked_id_sets(nations, LOCKED_NATIONS, "nations", "nations.json")
    _lock_officers_v2(officers)
    _locked_id_sets(equipment, LOCKED_EQUIPMENT, "equipment", "equipment.json")
    _locked_id_sets(backgrounds, LOCKED_BACKGROUNDS, "backgrounds",
                    "backgrounds.json")
    # -- §7.1 lock model (Phase 7): the neutral tier joins the identity locks
    # (id/zh/en/lat/lon exact vs the §7.1 table; produces/demands are
    # structural, §8.2 group 7). The duplicated pre-Phase-8 lock block above
    # is collapsed; the neutral lock lives here since the Phase-7 amendment.
    _locked_id_sets(neutral, LOCKED_NEUTRAL_PORTS, "neutral ports", "ports.json")

    # The neutral tier (§7.1): identity-locked 45 rows (Phase 7 joins the
    # tier to the lock model — the Phase-6 40–60 count band is retired),
    # complete i18n over name/flavor, facilities per the tier rule.
    for index, port in enumerate(neutral):
        port_id = port.get("id")
        path = f"ports.json neutral tier [{index}]"
        if port_id in LOCKED_PORTS:
            fail(
                "locked-list",
                "ports.json",
                f"{path}: neutral id {port_id!r} collides with the "
                "sovereign §7.1 set",
                5,
            )
        zh, en, lat, lon = LOCKED_NEUTRAL_PORTS[port_id]
        _check_l10n_text(port, "name", zh, en, path, "ports.json")
        if port.get("lat") != lat or port.get("lon") != lon:
            fail(
                "locked-content",
                "ports.json",
                f"{path} ({port_id}) lat/lon must be {lat}/{lon} per the "
                "§7.1 neutral-tier table",
                5,
            )
        # complete i18n over the tier's display strings (§2.11: flavor)
        value = port.get("flavor")
        if isinstance(value, dict):
            if set(value) != {"zh", "en"} or not all(
                    isinstance(value.get(locale), str)
                    and value.get(locale, "").strip()
                    for locale in ("zh", "en")):
                fail(
                    "locked-content",
                    "ports.json",
                    f"{path} ({port_id}) flavor must be a complete "
                    "zh/en L10nString (§7.1 neutral tier)",
                    5,
                )
        else:
            fail(
                "locked-content",
                "ports.json",
                f"{path} ({port_id}) flavor must be an L10nString "
                "(§7.1 neutral tier)",
                5,
            )
        facilities = port.get("facilities")
        if not isinstance(facilities, dict) or not facilities:
            fail(
                "locked-content",
                "ports.json",
                f"{path} ({port_id}) facilities must be a non-empty object "
                "per the tier rule (§7.1)",
                5,
            )
        for key in facilities:
            if key not in NEUTRAL_FACILITY_KEYS:
                fail(
                    "locked-content",
                    "ports.json",
                    f"{path} ({port_id}) facility {key!r} is not one of "
                    f"{sorted(NEUTRAL_FACILITY_KEYS)} — a neutral port "
                    "carries no guild/palace (§7.1)",
                    5,
                )
        # int-valued facilities stay locked at their activation phase; the
        # array-valued Phase-7 facilities are group 3's (§4.4 shapes).
        for key in ("market", "tavern", "inn"):
            if key in facilities and facilities[key] != 1:
                fail(
                    "locked-content",
                    "ports.json",
                    f"{path} ({port_id}) facility {key!r} must be phase 1",
                    5,
                )

    for plural, expected_count in LOCKED_COUNTS.items():
        items = docs[f"{plural}.json"][plural]
        expected_total = expected_count
        if plural == "ports":
            # §7.1 (lock model, amended 2026-11-02): exactly 105 sovereign (exact set
            # above) + exactly the 45 recorded neutral rows.
            expected_total = expected_count + NEUTRAL_PORT_COUNT
            if len(items) != expected_total:
                fail(
                    "locked-count",
                    f"{plural}.json",
                    f"ports: count {len(items)} != {expected_total} "
                    f"({expected_count} sovereign + {NEUTRAL_PORT_COUNT} "
                    "neutral, §8 group 5 exact 150-set)",
                    5,
                )
            continue
        if len(items) != expected_count:
            fail(
                "locked-count",
                f"{plural}.json",
                f"{plural}: count {len(items)} != {expected_count}",
                5,
            )

    for index, good in enumerate(goods):
        zh, en, category, base_price = LOCKED_GOODS[good["id"]]
        path = f"goods[{index}]"
        _check_l10n_text(good, "name", zh, en, path, "goods.json")
        if good["category"] != category:
            fail(
                "locked-content",
                "goods.json",
                f"{path} ({good['id']}) category must be {category!r}",
                5,
            )
        if good["base_price"] != base_price:
            fail(
                "locked-content",
                "goods.json",
                f"{path} ({good['id']}) base_price must be {base_price}",
                5,
            )

    for index, ship in enumerate(ship_types):
        (
            zh,
            en,
            ship_class,
            role,
            tier,
            price,
            durability,
            capacity,
            speed,
            crew_min,
            crew_max,
            armament_slots,
        ) = LOCKED_SHIP_TYPES[ship["id"]]
        path = f"ship_types[{index}]"
        _check_l10n_text(ship, "name", zh, en, path, "ship_types.json")
        expected = {
            "class": ship_class,
            "role": role,
            "tier": tier,
            "base_price": price,
            "durability": durability,
            "capacity": capacity,
            "speed": speed,
            "crew_min": crew_min,
            "crew_max": crew_max,
            "armament_slots": armament_slots,
        }
        for field, value in expected.items():
            if ship[field] != value:
                fail(
                    "locked-content",
                    "ship_types.json",
                    f"{path} ({ship['id']}) {field} must be {value}",
                    5,
                )

    for index, nation in enumerate(nations):
        (
            zh,
            en,
            color,
            start_port_id,
            start_ship_type_id,
            start_gold,
            start_reputation,
            capital_port_id,
        ) = LOCKED_NATIONS[nation["id"]]
        path = f"nations[{index}]"
        _check_l10n_text(nation, "name", zh, en, path, "nations.json")
        expected = {
            "color": color,
            "start_port_id": start_port_id,
            "start_ship_type_id": start_ship_type_id,
            "start_gold": start_gold,
            "start_reputation": start_reputation,
            "capital_port_id": capital_port_id,
        }
        for field, value in expected.items():
            if nation[field] != value:
                fail(
                    "locked-content",
                    "nations.json",
                    f"{path} ({nation['id']}) {field} must be {value}",
                    5,
                )

    for index, port in enumerate(sovereign):
        zh, en, nation_id, lat, lon = LOCKED_PORTS[port["id"]]
        path = f"ports[{index}]"
        _check_l10n_text(port, "name", zh, en, path, "ports.json")
        expected = {
            "nation_id": nation_id,
            "lat": lat,
            "lon": lon,
        }
        for field, value in expected.items():
            if port[field] != value:
                fail(
                    "locked-content",
                    "ports.json",
                    f"{path} ({port['id']}) {field} must be {value} (§7.1 "
                    "identity lock — produces/demands are structural, "
                    "group 7)",
                    5,
                )

    # §7.10: the 6 backgrounds are authored-to-final — zh/en names and the
    # attribute/skill pairing lock exactly (the one-key/=3//=5 rules are
    # group 3's §4.22 shape check).
    for index, background in enumerate(backgrounds):
        zh, en, attribute, skill = LOCKED_BACKGROUNDS[background["id"]]
        path = f"backgrounds[{index}]"
        _check_l10n_text(background, "name", zh, en, path, "backgrounds.json")
        if background.get("attribute_bonus") != {attribute: 3}:
            fail(
                "locked-content",
                "backgrounds.json",
                f"{path} ({background['id']}) attribute_bonus must be "
                f"{{{attribute}: 3}} (§7.10)",
                5,
            )
        if background.get("skill_bonus") != {skill: 5}:
            fail(
                "locked-content",
                "backgrounds.json",
                f"{path} ({background['id']}) skill_bonus must be "
                f"{{{skill}: 5}} (§7.10)",
                5,
            )

    # docs/60-COMBAT.md section 4.11.13: the locked 24-item content set
    # (Phase 7 — authored-to-final by task S). Mirrors the doc tables field by
    # field, so a data-only edit (a price tweak, a stat swap, a renamed item,
    # a tier flip, a rare-flag change) fails loudly instead of drifting.
    for index, item in enumerate(equipment):
        zh, en, slot, modifiers, price, tier, rare = \
            LOCKED_EQUIPMENT[item["id"]]
        path = f"equipment[{index}]"
        _check_l10n_text(item, "name", zh, en, path, "equipment.json")
        # `rare` is an optional flag (only the 4 drop-only items carry it);
        # the lock compares the flag's truth, not the key's presence.
        if (item.get("rare") is True) != rare:
            fail(
                "locked-content",
                "equipment.json",
                f"{path} ({item['id']}) rare must be {rare}",
                5,
            )
        expected = {
            "slot": slot,
            "modifiers": dict(modifiers),
            "price": price,
            "tier": tier,
            "phase": 2,
        }
        for field, value in expected.items():
            if item.get(field) != value:
                fail(
                    "locked-content",
                    "equipment.json",
                    f"{path} ({item['id']}) {field} must be {value}",
                    5,
                )

    if verbose:
        print(
            "PASS group 5 locked lists "
            f"({len(sovereign)} sovereign ports + {len(neutral)} neutral "
            f"= {len(sovereign) + len(neutral)} (exact 150-set), "
            f"{LOCKED_COUNTS['goods']} goods, "
            f"{LOCKED_COUNTS['ship_types']} ship types, "
            f"6 nations, {LOCKED_COUNTS['officers']} officers "
            f"(6 §7.5 starters + 24 legends), {LOCKED_COUNTS['equipment']} "
            f"equipment items, {LOCKED_COUNTS['backgrounds']} backgrounds "
            "— identity locks, produces/demands structural)"
        )


# ---------------------------------------------------------------------------
# Check group 6 — World map
# ---------------------------------------------------------------------------

WORLD_PNG = DATA_DIR / "maps" / "world.png"
WORLD_REPORT = DATA_DIR / "maps" / "world_report.json"
WORLD_PNG_LABEL = "data/maps/world.png"
WORLD_REPORT_LABEL = "data/maps/world_report.json"
HARBOR_SNAP_TILES = 2

# Palette index order is locked (section 6.3, append-only): 0-4 = ~ . # ^ I.
WORLD_PALETTE_CHARS = "~.#^I"
PASSABLE_INDICES = (0, 1)  # ~ and . ; # , ^ and I block movement (section 6.2)
LAND_INDEX = 2  # `#`: the only tile a port's shore tile may be (20-* section 4.11.1)

# The probe ports of section 8.1 item 4: each failure names the strait the
# port proves. No `copenhagen` exists in the 100-port list, so Oresund/Great
# Belt is proven by its Baltic exits instead.
PROBE_PORTS = {
    "istanbul": "Bosphorus",
    "danzig": "Oresund/Great Belt (Baltic exit)",
    "stockholm": "Oresund/Great Belt (Baltic exit)",
    "aden": "Bab-el-Mandeb",
    "nagasaki": "Malacca/Sunda (Indian Ocean passage)",
    "venice": "Adriatic",
    "london": "Thames/English Channel",
    "hamburg": "Elbe",
}

# Informational disconnected-component threshold (section 8.1 item 5).
COMPONENT_REPORT_TILES = 2000

_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# index -> 1 when passable, 0 otherwise; builds the BFS bitmap with one
# C-level translate() call instead of a 2.3 M-iteration Python loop.
_PASSABLE_TABLE = bytes(
    1 if value in PASSABLE_INDICES else 0 for value in range(256)
)


class PngFormatError(Exception):
    """A structural problem with an indexed PNG (never escapes as a crash)."""


class WorldGrid:
    """Decoded world map: palette indices plus a passability bitmap."""

    __slots__ = ("width", "height", "indices", "passable")

    def __init__(self, width: int, height: int, indices: bytearray):
        self.width = width
        self.height = height
        self.indices = indices
        self.passable = indices.translate(_PASSABLE_TABLE)

    def char_at(self, index: int) -> str:
        value = self.indices[index]
        return WORLD_PALETTE_CHARS[value] if value < len(WORLD_PALETTE_CHARS) else "?"


def _unfilter_scanlines(raw: bytes, width: int, height: int) -> bytearray:
    """Reverse PNG filter types 0-4 for an 8-bit indexed image.

    The builder writes filter 0, but a hand-rebuilt PNG may use any of the five
    defined filters, so all of them are supported defensively (and a length
    check makes a truncated IDAT stream fail loudly rather than silently).
    """
    stride = width + 1
    if len(raw) != stride * height:
        raise PngFormatError(
            f"IDAT inflates to {len(raw)} bytes, expected {stride * height} "
            f"for {width}x{height} (one filter byte + {width} index bytes per row)"
        )
    out = bytearray(width * height)
    prev = bytearray(width)
    pos = 0
    for y in range(height):
        filter_type = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + width])
        pos += width
        if filter_type == 0:  # None
            pass
        elif filter_type == 1:  # Sub
            for i in range(1, width):
                line[i] = (line[i] + line[i - 1]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(width):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(width):
                left = line[i - 1] if i else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(width):
                left = line[i - 1] if i else 0
                up = prev[i]
                up_left = prev[i - 1] if i else 0
                p = left + up - up_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                if pa <= pb and pa <= pc:
                    predictor = left
                elif pb <= pc:
                    predictor = up
                else:
                    predictor = up_left
                line[i] = (line[i] + predictor) & 0xFF
        else:
            raise PngFormatError(
                f"row {y} uses undefined PNG filter type {filter_type} (0-4 defined)"
            )
        out[y * width:(y + 1) * width] = line
        prev = line
    return out


def decode_indexed_png(data: bytes) -> tuple[int, int, bytearray]:
    """Decode an 8-bit indexed PNG with zlib + struct; return (w, h, indices).

    Deliberately independent of `tools/build_world.py`: this is the validator's
    half of the cross-implementation check. Raises `PngFormatError` for every
    structural problem (signature, chunk framing/CRC, IHDR, palette, IDAT).
    """
    if not data.startswith(_PNG_SIGNATURE):
        raise PngFormatError("not a PNG (bad signature)")

    total = len(data)
    pos = len(_PNG_SIGNATURE)
    header = None
    palette = None
    idat = bytearray()
    saw_iend = False
    while pos < total:
        if pos + 8 > total:
            raise PngFormatError("truncated chunk header")
        chunk_length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        if pos + 12 + chunk_length > total:
            raise PngFormatError(f"truncated {tag!r} chunk")
        payload = data[pos + 8:pos + 8 + chunk_length]
        crc = struct.unpack(">I", data[pos + 8 + chunk_length:pos + 12 + chunk_length])[0]
        if crc != (zlib.crc32(tag + payload) & 0xFFFFFFFF):
            raise PngFormatError(f"bad CRC in chunk {tag!r}")
        pos += 12 + chunk_length
        if tag == b"IHDR":
            if chunk_length != 13:
                raise PngFormatError(f"IHDR chunk is {chunk_length} bytes, expected 13")
            header = struct.unpack(">IIBBBBB", payload)
        elif tag == b"PLTE":
            palette = payload
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            saw_iend = True
            break

    if header is None:
        raise PngFormatError("no IHDR chunk")
    if not saw_iend:
        raise PngFormatError("no IEND chunk (truncated file)")
    width, height, depth, colour, compression, filter_method, interlace = header
    if colour != 3:
        raise PngFormatError(
            f"not an indexed-colour PNG (IHDR colour type {colour}, expected 3)"
        )
    if depth != 8:
        raise PngFormatError(
            f"indexed PNG bit depth is {depth}, expected 8 (1 index byte per pixel)"
        )
    if compression != 0 or filter_method != 0:
        raise PngFormatError(
            f"unsupported PNG compression/filter method {compression}/{filter_method}"
        )
    if interlace != 0:
        raise PngFormatError(f"interlaced PNG not supported (IHDR interlace {interlace})")
    if palette is None:
        raise PngFormatError("no PLTE chunk (an indexed PNG needs a palette)")
    if width == 0 or height == 0:
        raise PngFormatError(f"zero image dimension {width}x{height}")
    if not idat:
        raise PngFormatError("no IDAT chunk (image data is empty)")

    try:
        raw = zlib.decompress(bytes(idat))
    except zlib.error as exc:
        raise PngFormatError(f"IDAT stream does not inflate: {exc}") from exc

    indices = _unfilter_scanlines(raw, width, height)

    palette_entries = len(palette) // 3
    highest = max(indices)
    if highest >= palette_entries:
        raise PngFormatError(
            f"palette index {highest} is used but PLTE holds only "
            f"{palette_entries} entries"
        )
    return width, height, indices


def _load_world_grid(path: Path, label: str) -> WorldGrid:
    """Artifact check (section 8.1 item 1): exists, indexed, size, indices."""
    if not path.is_file():
        fail(
            "map",
            label,
            "artifact is missing (section 6.3: data/maps/world.png, indexed PNG, "
            f"{MAP_WIDTH}x{MAP_HEIGHT}, 1 px = 1 tile)",
            6,
        )
    try:
        data = path.read_bytes()
    except OSError as exc:
        fail("map", label, f"cannot read artifact: {exc}", 6)
    try:
        width, height, indices = decode_indexed_png(data)
    except PngFormatError as exc:
        fail("map", label, str(exc), 6)
    if width != MAP_WIDTH or height != MAP_HEIGHT:
        fail(
            "map",
            label,
            f"artifact is {width}x{height} pixels, locked at {MAP_WIDTH}x{MAP_HEIGHT}",
            6,
        )
    highest = max(indices)
    if highest > len(WORLD_PALETTE_CHARS) - 1:  # indices 0-4 are locked
        offset = indices.index(highest)
        fail(
            "map",
            label,
            f"palette index {highest} at ({offset % width}, {offset // width}) is "
            "outside the locked 0-4 set (~ . # ^ I, section 6.3)",
            6,
        )
    return WorldGrid(width, height, indices)


# -- the locked geometry rules, re-derived from section 6.1 -------------------
def tiles_per_degree(width: int = MAP_WIDTH) -> float:
    return width / 360.0


def lat_lon_floor(value: float) -> int:
    """`math.floor` as an int (the projection's floor is load-bearing)."""
    return int(math.floor(value))


def tile_of_latlon(lat: float, lon: float) -> tuple[int, int]:
    """Grid cell containing a WGS84 point: floor projection, x wrapped.

    Matches section 6.1 (`lon = x/6 - 180`, `lat = 90 - y/6`) and the builder's
    `tile_of_latlon`; y is clamped into the grid (only the exact poles reach
    the edge).
    """
    scale = tiles_per_degree()
    x = lat_lon_floor((lon + 180.0) * scale) % MAP_WIDTH
    y = lat_lon_floor((90.0 - lat) * scale)
    return x, min(max(y, 0), MAP_HEIGHT - 1)


def chebyshev_wrap(dx: int, dy: int, width: int = MAP_WIDTH) -> int:
    """Chebyshev distance with longitude wrap (section 6.1)."""
    dx = abs(dx) % width
    return max(min(dx, width - dx), abs(dy))


def has_orthogonal_water(grid: WorldGrid, x: int, y: int) -> bool:
    """>= 1 orthogonally adjacent passable tile; x wraps, y is bounded."""
    width, height, p = grid.width, grid.height, grid.passable
    if p[y * width + (x - 1) % width] or p[y * width + (x + 1) % width]:
        return True
    if y > 0 and p[(y - 1) * width + x]:
        return True
    if y < height - 1 and p[(y + 1) * width + x]:
        return True
    return False


def snap_harbor(grid: WorldGrid, lat: float, lon: float,
                radius: int = HARBOR_SNAP_TILES):
    """Locked harbor rule (section 6.1): water, adjacent water, ties (y, x).

    Returns `(distance, y, x)`, or None when no candidate inside the Chebyshev
    radius satisfies the rule. This is the **berth** half only; section 8.1
    item 2b adds the harbor-pair requirement (20-* section 4.11.1).
    """
    px, py = tile_of_latlon(lat, lon)
    candidates = []
    for dy in range(-radius, radius + 1):
        y = py + dy
        if not (0 <= y < grid.height):
            continue
        for dx in range(-radius, radius + 1):
            x = (px + dx) % grid.width
            candidates.append((chebyshev_wrap(dx, dy, grid.width), y, x))
    candidates.sort()
    for distance, y, x in candidates:
        if grid.passable[y * grid.width + x] and has_orthogonal_water(grid, x, y):
            return distance, y, x
    return None


def snap_harbor_with_shore(grid: WorldGrid, lat: float, lon: float,
                           radius: int = HARBOR_SNAP_TILES):
    """The harbor-pair berth (section 6.1 + 20-* section 4.11.1).

    The section 6.1 snap with the pair constraint applied: a candidate water
    tile that has no orthogonally adjacent `#` shore tile is skipped. Candidates
    keep the locked `(distance, y, x)` order, so every port whose plain snap
    already has a shore tile keeps exactly that tile — only a berth with no
    shore neighbour moves (by one tile on the shipped map).

    Returns `(distance, y, x)` or None.
    """
    px, py = tile_of_latlon(lat, lon)
    candidates = []
    for dy in range(-radius, radius + 1):
        y = py + dy
        if not (0 <= y < grid.height):
            continue
        for dx in range(-radius, radius + 1):
            x = (px + dx) % grid.width
            candidates.append((chebyshev_wrap(dx, dy, grid.width), y, x))
    candidates.sort()
    for distance, y, x in candidates:
        if not (grid.passable[y * grid.width + x]
                and has_orthogonal_water(grid, x, y)):
            continue
        if shore_of_berth(grid, x, y, (px, py)) is None:
            continue
        return distance, y, x
    return None


def shore_of_berth(grid: WorldGrid, x: int, y: int, origin: tuple[int, int],
                   radius: int = HARBOR_SNAP_TILES):
    """Shore tile of a berth (20-* section 4.11.1): `(distance, y, x)` or None.

    The nearest orthogonally adjacent `#` tile to the port's derived origin,
    wrap-aware Chebyshev in x, tie-breaking to the smallest `(y, x)`.
    """
    ox, oy = origin
    candidates = []
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        yy = y + dy
        if not (0 <= yy < grid.height):
            continue
        xx = (x + dx) % grid.width
        if grid.indices[yy * grid.width + xx] != LAND_INDEX:
            continue
        candidates.append((chebyshev_wrap(xx - ox, yy - oy, grid.width), yy, xx))
    if not candidates:
        return None
    candidates.sort()
    distance, sy, sx = candidates[0]
    return distance, sy, sx


# -- reachability (section 8.1 item 3, `20-*` section 4.2) -------------------
def bfs_reachable(passable: bytearray, width: int, height: int,
                  start: int) -> bytearray:
    """Wrap-aware 8-directional BFS with corner cutting forbidden.

    A diagonal step (x+dx, y+dy) is legal only when both orthogonal neighbours
    of the corner — (x+dx, y) and (x, y+dy) — are passable. `x` wraps, `y` is
    bounded. Returns the visited bitmap (index = y*width + x).
    """
    visited = bytearray(width * height)
    if not passable[start]:
        return visited
    visited[start] = 1
    queue = deque([start])
    popleft = queue.popleft
    push = queue.append
    last_x = width - 1
    p = passable
    v = visited
    while queue:
        node = popleft()
        x = node % width
        y = node // width
        left = node - 1 if x else node + last_x
        right = node + 1 if x < last_x else node - last_x
        if p[left] and not v[left]:
            v[left] = 1
            push(left)
        if p[right] and not v[right]:
            v[right] = 1
            push(right)
        up = node - width
        if y:
            if p[up]:
                if not v[up]:
                    v[up] = 1
                    push(up)
                upper_left = up - 1 if x else up + last_x
                if p[left] and p[upper_left] and not v[upper_left]:
                    v[upper_left] = 1
                    push(upper_left)
                upper_right = up + 1 if x < last_x else up - last_x
                if p[right] and p[upper_right] and not v[upper_right]:
                    v[upper_right] = 1
                    push(upper_right)
        if y < height - 1:
            down = node + width
            if p[down]:
                if not v[down]:
                    v[down] = 1
                    push(down)
                lower_left = down - 1 if x else down + last_x
                if p[left] and p[lower_left] and not v[lower_left]:
                    v[lower_left] = 1
                    push(lower_left)
                lower_right = down + 1 if x < last_x else down - last_x
                if p[right] and p[lower_right] and not v[lower_right]:
                    v[lower_right] = 1
                    push(lower_right)
    return visited


def _corner_cut_self_check() -> None:
    """Assert `bfs_reachable` refuses a diagonal squeeze and honours wrap.

    A 4x4 all-land grid with only (1,1) and (2,2) passable: a plain 8-direction
    BFS would leak from one to the other through the corner; the locked rule
    must not. A 2x1 grid with both tiles passable must join x=0 and x=1 (wrap).
    """
    width = height = 4
    passable = bytearray(width * height)
    passable[1 * width + 1] = 1
    passable[2 * width + 2] = 1
    reached = bfs_reachable(passable, width, height, 1 * width + 1)
    if reached[2 * width + 2]:
        fail(
            "implement",
            "tools/validate_data.py",
            "BFS permits corner cutting: the diagonal squeeze (1,1)->(2,2) was "
            "traversed (docs/20-WORLD-AND-SAILING.md section 4.2 forbids it)",
            6,
        )
    wrapped = bfs_reachable(bytearray([1, 1]), 2, 1, 0)
    if not wrapped[1]:
        fail(
            "implement",
            "tools/validate_data.py",
            "BFS is not wrap-aware: x=0 did not reach x=1 on a 2-wide grid",
            6,
        )


def _passable_components(passable: bytearray, width: int, height: int,
                         skip: bytearray) -> list[tuple[int, int, int]]:
    """4-connected passable components not already in `skip` (wrap-aware).

    Returns `[(size, y, x), ...]` where (x, y) is the component's first tile in
    scan order. 4-connectivity is exactly 8-directional-with-no-corner-cutting,
    so a component here is a sea a fleet could actually sail.
    """
    seen = bytearray(skip)  # copy; `skip` stays the Lisbon-reachable bitmap
    components = []
    last_x = width - 1
    total = width * height
    for seed in range(total):
        if not passable[seed] or seen[seed]:
            continue
        seen[seed] = 1
        queue = deque([seed])
        pop = queue.popleft
        push = queue.append
        size = 0
        while queue:
            node = pop()
            size += 1
            x = node % width
            y = node // width
            left = node - 1 if x else node + last_x
            right = node + 1 if x < last_x else node - last_x
            if passable[left] and not seen[left]:
                seen[left] = 1
                push(left)
            if passable[right] and not seen[right]:
                seen[right] = 1
                push(right)
            if y:
                up = node - width
                if passable[up] and not seen[up]:
                    seen[up] = 1
                    push(up)
            if y < height - 1:
                down = node + width
                if passable[down] and not seen[down]:
                    seen[down] = 1
                    push(down)
        components.append((size, seed // width, seed % width))
    return components


# -- report parsing ----------------------------------------------------------
def _report_port_tiles(report: object, key: str) -> dict[str, tuple[int, int]]:
    """Read `world_report.json#ports[].<key>` into `{id: (x, y)}`."""
    if not isinstance(report, dict):
        fail("map", WORLD_REPORT_LABEL, "builder report is not a JSON object", 6)
    entries = report.get("ports")
    if not isinstance(entries, list):
        fail(
            "map",
            WORLD_REPORT_LABEL,
            "builder report has no 'ports' array (section 6.3)",
            6,
        )
    tiles: dict[str, tuple[int, int]] = {}
    for index, entry in enumerate(entries):
        path = f"ports[{index}]"
        if not isinstance(entry, dict):
            fail("map", WORLD_REPORT_LABEL, f"{path} is not an object", 6)
        port_id = entry.get("id")
        if not isinstance(port_id, str):
            fail("map", WORLD_REPORT_LABEL, f"{path} has no string 'id'", 6)
        tile = entry.get(key)
        if not isinstance(tile, dict):
            fail(
                "map",
                WORLD_REPORT_LABEL,
                f"{path} ({port_id}) has no '{key}' object",
                6,
            )
        x, y = tile.get("x"), tile.get("y")
        if not is_int(x) or not is_int(y):
            fail(
                "map",
                WORLD_REPORT_LABEL,
                f"{path} ({port_id}) {key} needs integer x/y",
                6,
            )
        if not (0 <= x < MAP_WIDTH and 0 <= y < MAP_HEIGHT):
            fail(
                "map",
                WORLD_REPORT_LABEL,
                f"{path} ({port_id}) {key} ({x}, {y}) is outside the "
                f"{MAP_WIDTH}x{MAP_HEIGHT} grid",
                6,
            )
        if port_id in tiles:
            fail("map", WORLD_REPORT_LABEL, f"{path} repeats port id {port_id!r}", 6)
        tiles[port_id] = (x, y)
    return tiles


def _report_harbor_tiles(report: object) -> dict[str, tuple[int, int]]:
    """Read `world_report.json#ports[].harbor_tile` (the **berth**) into `{id: (x, y)}`."""
    return _report_port_tiles(report, "harbor_tile")


def _report_shore_tiles(report: object) -> dict[str, tuple[int, int]]:
    """Read `world_report.json#ports[].shore_tile` into `{id: (x, y)}`."""
    return _report_port_tiles(report, "shore_tile")


# -- the analysis shared by the real run and the mutation harness ------------
def analyse_world_map(grid: WorldGrid, ports: list, report_tiles: dict,
                      discoveries: list, verbose: bool,
                      report_shores: dict | None = None) -> dict:
    """Harbor-pair agreement, reachability, probes, component listing.

    Section 8.1 items 2-5. `grid`, `ports`, `report_tiles` and `discoveries`
    are exactly the values the normal run builds, so the self-test harness can
    mutate in-memory copies and drive this same code path. `report_shores`
    defaults to `report_tiles` for the older harness cases that only exercise
    the berth half; the real run passes `world_report.json`'s `shore_tile` map.
    """
    width, height = grid.width, grid.height
    passable = grid.passable
    if report_shores is None:
        report_shores = report_tiles
    port_ids = [port.get("id") for port in ports]
    if len(set(port_ids)) != len(port_ids):
        fail("map", WORLD_PNG_LABEL, "ports.json repeats a port id", 6)

    # -- item 2: recompute every harbor tile from lat/lon, compare to report --
    computed: dict[str, tuple[int, int]] = {}
    computed_shores: dict[str, tuple[int, int]] = {}
    for port in ports:
        port_id = port["id"]
        lat, lon = float(port["lat"]), float(port["lon"])
        snapped = snap_harbor_with_shore(grid, lat, lon)
        if snapped is None:
            px, py = tile_of_latlon(lat, lon)
            plain = snap_harbor(grid, lat, lon)
            if plain is not None:
                fail(
                    "map",
                    WORLD_PNG_LABEL,
                    f"harbor pair: port '{port_id}' berth "
                    f"({plain[2]}, {plain[1]}) has no orthogonally adjacent "
                    f"'#' shore tile within {HARBOR_SNAP_TILES} tiles of port "
                    f"tile ({px}, {py}) and no other water candidate does "
                    "(20-* section 4.11.1)",
                    6,
                )
            fail(
                "map",
                WORLD_PNG_LABEL,
                f"harbor snap: port '{port_id}' at lat/lon ({lat:.4f}, {lon:.4f}) "
                f"has no water tile within {HARBOR_SNAP_TILES} tiles of "
                f"({px}, {py}) with an orthogonally adjacent water tile "
                "(section 6.1)",
                6,
            )
        distance, y, x = snapped
        computed[port_id] = (x, y)
        reported = report_tiles.get(port_id)
        if reported is None:
            fail(
                "map",
                WORLD_REPORT_LABEL,
                f"world_report.json has no harbor_tile for port '{port_id}' "
                f"(validator recomputed ({x}, {y}))",
                6,
            )
        if reported != (x, y):
            fail(
                "map",
                WORLD_PNG_LABEL,
                f"harbor snap: port '{port_id}' recomputes to ({x}, {y}) "
                f"(distance {distance}) but world_report.json says "
                f"({reported[0]}, {reported[1]})",
                6,
            )

        # -- item 2b: the harbor pair (20-* section 4.11.1) -------------------
        shore = shore_of_berth(grid, x, y, tile_of_latlon(lat, lon))
        if shore is None:
            fail(
                "map",
                WORLD_PNG_LABEL,
                f"harbor pair: port '{port_id}' berth ({x}, {y}) has no "
                f"orthogonally adjacent '#' shore tile — the docking gesture "
                f"and the port overlay both need one (20-* section 4.11.1)",
                6,
            )
        shore_distance, sy, sx = shore
        computed_shores[port_id] = (sx, sy)
        reported_shore = report_shores.get(port_id)
        if reported_shore is None:
            fail(
                "map",
                WORLD_REPORT_LABEL,
                f"world_report.json has no shore_tile for port '{port_id}' "
                f"(validator recomputed ({sx}, {sy}))",
                6,
            )
        if reported_shore != (sx, sy):
            fail(
                "map",
                WORLD_PNG_LABEL,
                f"harbor pair: port '{port_id}' shore tile recomputes to "
                f"({sx}, {sy}) (distance {shore_distance}) but "
                f"world_report.json says "
                f"({reported_shore[0]}, {reported_shore[1]})",
                6,
            )

    collisions: dict[tuple[int, int], str] = {}
    for port in ports:
        port_id = port["id"]
        tile = computed[port_id]
        if tile in collisions:
            fail(
                "map",
                WORLD_PNG_LABEL,
                f"harbor snap: ports '{collisions[tile]}' and '{port_id}' both "
                f"snap to harbor tile ({tile[0]}, {tile[1]})",
                6,
            )
        collisions[tile] = port_id

    shore_collisions: dict[tuple[int, int], str] = {}
    for port in ports:
        port_id = port["id"]
        tile = computed_shores[port_id]
        if tile in shore_collisions:
            fail(
                "map",
                WORLD_PNG_LABEL,
                f"harbor pair: ports '{shore_collisions[tile]}' and '{port_id}' "
                f"share shore tile ({tile[0]}, {tile[1]}) — only one could be "
                "docked into (20-* section 4.11.1)",
                6,
            )
        shore_collisions[tile] = port_id

    stale = sorted(set(report_tiles) - {port["id"] for port in ports})
    if stale:
        fail(
            "map",
            WORLD_REPORT_LABEL,
            f"builder report lists {len(stale)} port(s) that are not in "
            f"ports.json: {', '.join(stale)} — regenerate with tools/build_world.py",
            6,
        )

    # -- item 3: BFS from Lisbon over every passable tile --------------------
    lisbon = computed.get("lisbon")
    if lisbon is None:
        fail(
            "map",
            WORLD_PNG_LABEL,
            "ports.json has no 'lisbon' port to start the reachability BFS from",
            6,
        )
    start = lisbon[1] * width + lisbon[0]
    _corner_cut_self_check()
    reached = bfs_reachable(passable, width, height, start)
    if not reached[start]:
        fail(
            "map",
            WORLD_PNG_LABEL,
            f"Lisbon's harbor tile ({lisbon[0]}, {lisbon[1]}) is not passable "
            f"(tile is {grid.char_at(start)})",
            6,
        )

    # -- item 2b: shore tiles are land, so the water BFS must never reach one --
    # The pair's land half is presented and docked into, never sailed over
    # (20-* section 4.11.1): a shore tile appearing in the passable BFS would
    # mean the raster and the derived pair disagree.
    sailed_shores = [
        port_id for port_id, (sx, sy) in computed_shores.items()
        if reached[sy * width + sx]
    ]
    if sailed_shores:
        listed = ", ".join(
            f"{pid} ({computed_shores[pid][0]}, {computed_shores[pid][1]})"
            for pid in sailed_shores
        )
        fail(
            "map",
            WORLD_PNG_LABEL,
            f"harbor pair: {len(sailed_shores)} shore tile(s) are passable water "
            f"and therefore inside the sailing BFS — a shore tile is land "
            f"(20-* section 4.11.1): {listed}",
            6,
        )

    # -- item 4: probe ports (each names the strait it proves) --------------
    # A missing probe id is a data error on its own; reachability of a probe is
    # reported together with the harbor list below so one failure names both the
    # port that lost its water path and the strait that closed.
    for probe_id, strait in PROBE_PORTS.items():
        if computed.get(probe_id) is None:
            fail(
                "map",
                WORLD_PNG_LABEL,
                f"probe port '{probe_id}' is missing from ports.json; it proves "
                f"the {strait} is navigable (section 8.1)",
                6,
            )

    # -- item 3: all 100 harbor tiles ---------------------------------------
    unreachable_ports = [
        port["id"] for port in ports
        if not reached[computed[port["id"]][1] * width + computed[port["id"]][0]]
    ]
    if unreachable_ports:
        listed = ", ".join(
            f"{pid} ({computed[pid][0]}, {computed[pid][1]})"
            for pid in unreachable_ports
        )
        closed_straits = [
            f"{probe_id} ({strait})"
            for probe_id, strait in PROBE_PORTS.items()
            if probe_id in unreachable_ports
        ]
        strait_text = (
            f"; closed straits: {', '.join(closed_straits)}" if closed_straits else ""
        )
        fail(
            "map",
            WORLD_PNG_LABEL,
            f"reachability: {len(unreachable_ports)} harbor tile(s) are not "
            f"reachable from Lisbon ({lisbon[0]}, {lisbon[1]}) by 8-directional "
            f"no-corner-cut sailing (20-* section 4.2): {listed}{strait_text}",
            6,
        )

    # -- item 3: all discovery tiles ---------------------------------------
    discoveries_checked = 0
    unreachable_discoveries = []
    for discovery in discoveries:
        discovery_id = discovery["id"]
        lat, lon = float(discovery["lat"]), float(discovery["lon"])
        x, y = tile_of_latlon(lat, lon)
        discoveries_checked += 1
        node = y * width + x
        if passable[node]:
            if not reached[node]:
                unreachable_discoveries.append(
                    f"{discovery_id} ({x}, {y}) water tile not reached"
                )
            continue
        neighbours = [
            (yy, (x + dx) % width)
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
            for yy in (y + dy,)
            if 0 <= yy < height and passable[yy * width + (x + dx) % width]
        ]
        if not any(reached[yy * width + xx] for yy, xx in neighbours):
            unreachable_discoveries.append(
                f"{discovery_id} ({x}, {y}) tile is '{grid.char_at(node)}' with "
                f"{len(neighbours)} passable orthogonal neighbour(s), none reached"
            )
    if unreachable_discoveries:
        fail(
            "map",
            "data/discoveries.json",
            f"reachability: {len(unreachable_discoveries)} discovery tile(s) are "
            "not reachable from Lisbon (70-* section 4.4 requires the derived tile "
            f"to be passable or orthogonally adjacent to reached water): "
            f"{', '.join(unreachable_discoveries)}",
            6,
        )

    # -- item 5: informational disconnected components ---------------------
    components = _passable_components(passable, width, height, reached)
    large = [
        component for component in components
        if component[0] > COMPONENT_REPORT_TILES
    ]
    for size, y, x in sorted(large, reverse=True):
        print(
            f"WARN map {WORLD_PNG_LABEL} disconnected passable component of {size} "
            f"tiles (example tile ({x}, {y})) — informational only, never a "
            "failure (section 8.1 item 5)"
        )
    if verbose:
        separate_tiles = sum(size for size, _y, _x in components)
        print(
            f"INFO group 6 passable components: {len(components) + 1} total, "
            f"{len(large)} above {COMPONENT_REPORT_TILES} tiles, "
            f"{separate_tiles + sum(reached)} passable tiles"
        )
        if components:
            size, y, x = max(components)
            print(
                f"INFO group 6 largest disconnected component: {size} tiles at "
                f"({x}, {y}) (informational, never a failure: lakes are land)"
            )

    return {
        "ports_snapped": len(computed),
        "shores_snapped": len(computed_shores),
        "reachable_tiles": sum(reached),
        "lisbon_tile": lisbon,
        "discoveries": discoveries_checked,
        "probes": len(PROBE_PORTS),
        "large_components": large,
    }


def check_group6(docs: dict[str, object], verbose: bool) -> None:
    """World-map integrity: docs/10-DATA-SCHEMA.md section 8.1.

    Item 1 (the artifact) is checked by `_load_world_grid`; items 2-5 are
    `analyse_world_map`. Both are also what the `--self-test-g6` mutation
    harness drives, so the negatives prove the real code paths.
    """
    grid = _load_world_grid(WORLD_PNG, WORLD_PNG_LABEL)

    report = docs.get("world_report.json")
    if report is None:
        if not WORLD_REPORT.is_file():
            fail(
                "map",
                WORLD_REPORT_LABEL,
                "companion builder report is missing (section 6.3)",
                6,
            )
        try:
            report = json.loads(WORLD_REPORT.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail("map", WORLD_REPORT_LABEL, f"cannot read builder report: {exc}", 6)
    report_tiles = _report_harbor_tiles(report)
    report_shores = _report_shore_tiles(report)

    # -- harbors.json (unified-movement amendment): the persisted berth/
    # -- shore table the runtime READS (map_loader) — must exist, cover
    # -- every port, and match the builder report byte-for-value.
    harbors_path = DATA_DIR / "maps" / "harbors.json"
    if not harbors_path.is_file():
        fail(
            "map",
            "data/maps/harbors.json",
            "persisted harbors table is missing (run tools/build_world.py)",
            6,
        )
    try:
        harbors_doc = json.loads(harbors_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail("map", "data/maps/harbors.json", f"cannot read: {exc}", 6)
    if not isinstance(harbors_doc, dict) \
            or harbors_doc.get("version") != 1 \
            or not isinstance(harbors_doc.get("harbors"), list):
        fail("map", "data/maps/harbors.json", "malformed envelope", 6)
    loaded_harbors: dict[str, tuple[tuple[int, int], tuple[int, int]]] = {}
    for entry in harbors_doc["harbors"]:
        if not isinstance(entry, dict) or "id" not in entry \
                or not isinstance(entry.get("berth"), list) \
                or not isinstance(entry.get("shore"), list) \
                or len(entry["berth"]) != 2 or len(entry["shore"]) != 2:
            fail("map", "data/maps/harbors.json", "malformed harbor entry", 6)
        loaded_harbors[str(entry["id"])] = (
            (int(entry["berth"][0]), int(entry["berth"][1])),
            (int(entry["shore"][0]), int(entry["shore"][1])),
        )
    if set(loaded_harbors) != set(report_tiles):
        missing = sorted(set(report_tiles) - set(loaded_harbors))
        extra = sorted(set(loaded_harbors) - set(report_tiles))
        fail(
            "map",
            "data/maps/harbors.json",
            f"harbor coverage mismatch: missing {missing[:4]}, extra {extra[:4]}",
            6,
        )
    for port_id in sorted(loaded_harbors):
        berth, shore = loaded_harbors[port_id]
        if berth != report_tiles[port_id] or shore != report_shores[port_id]:
            fail(
                "map",
                "data/maps/harbors.json",
                f"{port_id}: persisted tiles disagree with the §6.1 snap "
                f"(berth {berth} vs {report_tiles[port_id]}; shore {shore} "
                f"vs {report_shores[port_id]})",
                6,
            )

    ports = docs["ports.json"]["ports"]
    discoveries = docs["discoveries.json"]["discoveries"]
    stats = analyse_world_map(grid, ports, report_tiles, discoveries, verbose,
                              report_shores)

    if verbose:
        lisbon = stats["lisbon_tile"]
        print(
            f"PASS group 6 world map ({grid.width}x{grid.height}, "
            f"{stats['ports_snapped']} ports snapped, "
            f"{stats['shores_snapped']} shore tiles, "
            f"{stats['reachable_tiles']} passable tiles in one component from "
            f"Lisbon ({lisbon[0]}, {lisbon[1]}), "
            f"{stats['discoveries']} discoveries reachable, "
            f"{stats['probes']} probe ports)"
        )


# ---------------------------------------------------------------------------
# Group 6 mutation harness (`--self-test-g6`)
# ---------------------------------------------------------------------------
#
# Each case mutates an in-memory copy (never real data), drives the same
# `_load_world_grid` / `analyse_world_map` functions the real run uses, and
# asserts the expected exit-6 failure naming the expected entity. A case that
# stays green is a harness failure (exit 1), because it would mean group 6
# cannot detect that class of world-map drift.

_G6_INLAND_PORT = "valencia"
_G6_INLAND_TILES = 3
_G6_BASIN_TILES = 60  # a 60x60 basin is 3600 tiles, above the 2000 threshold
# A port used by the harbor-pair negatives (2b): its berth must have exactly the
# kind of `#` neighbour the pair rule requires.
_G6_SHORE_PORT = "lisbon"


def _encode_indexed_png(width: int, height: int, indices: bytes | bytearray,
                        palette_entries: int,
                        filter_cycle: tuple[int, ...] = (0,)) -> bytes:
    """Minimal indexed-PNG writer used only to build corrupted temp artifacts.

    `filter_cycle` selects the per-row PNG filter type, applied for real (the
    row is filtered, not just labelled), so the decoder's filter support can be
    exercised end to end.
    """
    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    raw = bytearray()
    prev = bytes(width)
    for y in range(height):
        row = bytes(indices[y * width:(y + 1) * width])
        filter_type = filter_cycle[y % len(filter_cycle)]
        raw.append(filter_type)
        if filter_type == 0:
            raw += row
        else:
            encoded = bytearray(width)
            for i in range(width):
                left = row[i - 1] if i else 0
                up = prev[i]
                up_left = prev[i - 1] if i else 0
                if filter_type == 1:
                    predictor = left
                elif filter_type == 2:
                    predictor = up
                elif filter_type == 3:
                    predictor = (left + up) >> 1
                elif filter_type == 4:
                    p = left + up - up_left
                    pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                    predictor = (
                        left if pa <= pb and pa <= pc else (up if pb <= pc else up_left)
                    )
                else:
                    raise ValueError(f"undefined filter {filter_type}")
                encoded[i] = (row[i] - predictor) & 0xFF
            raw += encoded
        prev = row

    palette = bytearray()
    for entry in range(palette_entries):
        palette += bytes((entry, entry, entry))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)
    return (
        _PNG_SIGNATURE
        + chunk(b"IHDR", ihdr)
        + chunk(b"PLTE", bytes(palette))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b"")
    )


def _g6_mutated_grid(grid: WorldGrid, land_tiles, keep_water) -> WorldGrid:
    """Copy of `grid` with `land_tiles` turned to land, minus `keep_water`."""
    indices = bytearray(grid.indices)
    keep = set(keep_water)
    for x, y in land_tiles:
        if (x, y) in keep:
            continue
        indices[y * grid.width + x] = 2  # '#'
    return WorldGrid(grid.width, grid.height, indices)


def _expect_g6_failure(case: str, needle: str, action) -> bool:
    """Run `action`; PASS when it raises exit-6 CheckFailure naming `needle`."""
    try:
        action()
    except CheckFailure as exc:
        haystack = f"{exc.filename} {exc.details}".lower()
        if exc.code != 6:
            print(
                f"FAIL g6-self-test {case}: expected exit 6 but group 6 raised "
                f"exit {exc.code}: {exc.details}"
            )
            return False
        if needle.lower() not in haystack:
            print(
                f"FAIL g6-self-test {case}: failure does not name {needle!r}: "
                f"{exc.filename} {exc.details}"
            )
            return False
        print(f"PASS g6 negative {case}: {exc.filename} {exc.details}")
        return True
    except Exception as exc:  # a crash is not a check failure
        print(f"FAIL g6-self-test {case}: unexpected {type(exc).__name__}: {exc}")
        return False
    print(f"FAIL g6-self-test {case}: group 6 stayed green; the mutation was not detected")
    return False


def _carve_path_tiles(name: str) -> list[tuple[int, int]]:
    """Tiles of a named carve in `tools/map_overrides.json`.

    Read-only: the harness never edits the override file (removing the entry and
    rebuilding is task D's tool). It only needs to know which cells the carve
    creates so it can fill them with land.
    """
    path = REPO_ROOT / "tools" / "map_overrides.json"
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    entries = payload.get("overrides") if isinstance(payload, dict) else None
    if not isinstance(entries, list):
        return []
    tiles = []
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("name") != name:
            continue
        for point in entry.get("path") or []:
            if isinstance(point, (list, tuple)) and len(point) == 2:
                tiles.append(tile_of_latlon(float(point[0]), float(point[1])))
    return tiles


def _seal_carve(grid: WorldGrid, name: str, report_tiles: dict) -> WorldGrid | None:
    """Fill a carve's cells (and its 8-neighbour ring) with land.

    Harbor tiles stay wet so the snap check still passes and the reachability
    check is the one that fires.
    """
    tiles = _carve_path_tiles(name)
    if not tiles:
        return None
    keep_water = set(report_tiles.values())
    land_tiles = [
        ((x + dx) % grid.width, y + dy)
        for x, y in tiles
        for dy in (-1, 0, 1)
        for dx in (-1, 0, 1)
        if 0 <= y + dy < grid.height
    ]
    return _g6_mutated_grid(grid, land_tiles, keep_water)


def _g6_isolate_harbor(grid: WorldGrid, report_tiles: dict, port_id: str) -> WorldGrid | None:
    """Copy of `grid` with one harbor turned into a two-tile puddle.

    The harbor tile and one adjacent water tile stay water (so the snap rule's
    "adjacent water" clause still holds), but every other cell of their combined
    8-neighbourhood becomes land. The harbor is then snap-valid yet sealed off,
    which is the probe-port failure of section 8.1 item 4.
    """
    tile = report_tiles.get(port_id)
    if tile is None:
        return None
    width, height = grid.width, grid.height
    x0, y0 = tile
    # The pocket must keep an *orthogonally* adjacent water tile, otherwise the
    # snap rule's adjacency clause stops holding for the harbor itself.
    orthogonal = [
        ((x0 + dx) % width, y0 + dy)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
        if 0 <= y0 + dy < height
        and grid.passable[(y0 + dy) * width + (x0 + dx) % width]
    ]
    if not orthogonal:
        return None
    pocket = [(x0, y0), orthogonal[0]]
    indices = bytearray(grid.indices)
    for x, y in pocket:
        for dy in (-1, 0, 1):
            yy = y + dy
            if not (0 <= yy < height):
                continue
            for dx in (-1, 0, 1):
                candidate = ((x + dx) % width, yy)
                if candidate not in pocket:
                    indices[yy * width + candidate[0]] = 2  # '#'
    return WorldGrid(width, height, indices)


def _g6_desert_basin(grid: WorldGrid, side: int) -> WorldGrid | None:
    """Copy of `grid` with a `side`x`side` water basin carved from solid land.

    Scans temperate, non-polar solid-land blocks far bigger than the basin and
    floods the centre with `~`. The result is a disconnected passable component
    with no harbor and no discovery — exactly the lake-like case section 8.1
    item 5 says must be *listed*, never failed.
    """
    width, height = grid.width, grid.height
    margin = side // 2 + 4
    for centre_y in range(140, height - 140, 4):
        for centre_x in range(margin, width - margin, 4):
            solid = True
            for y in range(centre_y - margin, centre_y + margin + 1, 3):
                row = y * width
                for x in range(centre_x - margin, centre_x + margin + 1, 3):
                    # plain land only: polar ice ('I') is not a candidate site
                    if grid.indices[row + x] != 2:
                        solid = False
                        break
                if not solid:
                    break
            if not solid:
                continue
            indices = bytearray(grid.indices)
            for y in range(centre_y - side // 2, centre_y + side // 2):
                row = y * width
                indices[row + centre_x - side // 2:row + centre_x + side // 2] = (
                    bytes([0]) * side  # '~'
                )
            return WorldGrid(width, height, indices)
    return None


def _g6_setup() -> tuple[WorldGrid, dict, dict, list, list] | None:
    """Load the real grid/report/ports/discoveries for the harness."""
    grid = _load_world_grid(WORLD_PNG, WORLD_PNG_LABEL)
    try:
        report = json.loads(WORLD_REPORT.read_text(encoding="utf-8"))
        ports = json.loads(
            (DATA_DIR / "ports.json").read_text(encoding="utf-8")
        )["ports"]
        discoveries = json.loads(
            (DATA_DIR / "discoveries.json").read_text(encoding="utf-8")
        )["discoveries"]
    except (OSError, KeyError, json.JSONDecodeError) as exc:
        print(f"FAIL g6-self-test setup: cannot read world data: {exc}")
        return None
    return (grid, _report_harbor_tiles(report), _report_shore_tiles(report),
            ports, discoveries)


def _recomputed_report_maps(grid: WorldGrid, ports: list) -> tuple[dict, dict]:
    """Berth + shore maps a given grid yields, for mutated-grid cases.

    A pocket mutation moves the recomputed shore tile of the pocket's port,
    so the case needs the report maps the mutated grid itself derives (the
    validator's own snap functions — the same ones `analyse_world_map` uses).
    """
    berths: dict[str, tuple[int, int]] = {}
    shores: dict[str, tuple[int, int]] = {}
    for port in ports:
        lat, lon = float(port["lat"]), float(port["lon"])
        snapped = snap_harbor_with_shore(grid, lat, lon)
        if snapped is None:
            continue  # the case wants the probe failure, not a snap failure
        _distance, y, x = snapped
        berths[port["id"]] = (x, y)
        origin = tile_of_latlon(lat, lon)
        shore = shore_of_berth(grid, x, y, origin)
        if shore is not None:
            # validator shore_of_berth returns (distance, sy, sx)
            shores[port["id"]] = (shore[2], shore[1])
    return berths, shores


def run_group6_self_test() -> int:
    """Negative harness for group 6: every case must fail with exit code 6."""
    setup = _g6_setup()
    if setup is None:
        return 1
    grid, report_tiles, report_shores, ports, discoveries = setup
    results: list[bool] = []

    # Baseline: the unmutated world is green, otherwise a negative could "fail"
    # for the wrong reason and prove nothing.
    try:
        analyse_world_map(grid, ports, report_tiles, discoveries, False,
                          report_shores)
        print("PASS g6 baseline: the unmutated world map validates green")
        results.append(True)
    except CheckFailure as exc:
        print(f"FAIL g6-self-test baseline: real data is already red: {exc.details}")
        results.append(False)

    # (1) Gibraltar sealed: fill the carve's water cells with land (harbor tiles
    # stay wet). The Mediterranean loses its Atlantic entrance, so the
    # reachability failure must name ceuta among the stranded harbors.
    sealed_gibraltar = _seal_carve(grid, "gibraltar", report_tiles)
    if sealed_gibraltar is None:
        print(
            "FAIL g6-self-test gibraltar-sealed: no gibraltar carve in "
            "tools/map_overrides.json"
        )
        results.append(False)
    else:
        results.append(
            _expect_g6_failure(
                "gibraltar-sealed",
                "ceuta",
                lambda: analyse_world_map(
                    sealed_gibraltar, ports, report_tiles, discoveries, False,
                    report_shores,
                ),
            )
        )

    # (1b) A single probe harbor sealed off: Istanbul keeps its snap-valid water
    # (harbor + one adjacent tile) but loses the Bosphorus. The probe rule must
    # fire and name the port and the strait it proves. The pocket mutation also
    # moves the recomputed shore tile, so the case feeds the report maps the
    # mutated grid itself yields — keeping the case pointed at the probe rule.
    isolated = _g6_isolate_harbor(grid, report_tiles, "istanbul")
    if isolated is None:
        print("FAIL g6-self-test probe-harbor-sealed: cannot isolate 'istanbul'")
        results.append(False)
    else:
        iso_tiles, iso_shores = _recomputed_report_maps(isolated, ports)
        results.append(
            _expect_g6_failure(
                "probe-harbor-sealed",
                "bosphorus",
                lambda: analyse_world_map(
                    isolated, ports, iso_tiles, discoveries, False,
                    iso_shores,
                ),
            )
        )

    # (2) One port moved 3 tiles inland: the independent snap recomputation must
    # fail and name that port. Valencia's sea lies east, so a 3-tile westward
    # shift puts its derived tile deep in the Iberian landmass.
    inland_ports = copy.deepcopy(ports)
    for port in inland_ports:
        if port["id"] == _G6_INLAND_PORT:
            port["lon"] = float(port["lon"]) - _G6_INLAND_TILES / tiles_per_degree()
    results.append(
        _expect_g6_failure(
            "port-3-tiles-inland",
            _G6_INLAND_PORT,
            lambda: analyse_world_map(
                grid, inland_ports, report_tiles, discoveries, False,
                report_shores,
            ),
        )
    )

    # (2a) A > 2000-tile disconnected basin must stay informational: flooding a
    # deep-desert block far from every harbor creates exactly the lake-like sea
    # section 8.1 item 5 says is listed, never failed.
    basin = _g6_desert_basin(grid, _G6_BASIN_TILES)
    if basin is None:
        print("FAIL g6-self-test large-lake-informational: no all-land basin site found")
        results.append(False)
    else:
        try:
            stats = analyse_world_map(
                basin, ports, report_tiles, discoveries, False, report_shores
            )
        except CheckFailure as exc:
            print(
                "FAIL g6-self-test large-lake-informational: a large disconnected "
                f"passable basin failed group 6 (must be informational): {exc.details}"
            )
            results.append(False)
        else:
            listed = stats["large_components"]
            ok = any(size >= _G6_BASIN_TILES * _G6_BASIN_TILES // 2
                     for size, _y, _x in listed)
            if ok:
                print(
                    "PASS g6 negative large-lake-informational: a disconnected "
                    f"{_G6_BASIN_TILES}x{_G6_BASIN_TILES} basin stayed green and was "
                    f"listed as {max(listed)[0]} tiles at "
                    f"({max(listed)[2]}, {max(listed)[1]})"
                )
            else:
                print(
                    "FAIL g6-self-test large-lake-informational: the basin was not "
                    f"listed (large_components={listed})"
                )
            results.append(ok)

    # (2b) A stale report entry: patch a copy of the report so one port's
    # harbor_tile disagrees with the independent recomputation. The comparison
    # must name the port and both tiles.
    stale_report = dict(report_tiles)
    lisbon_tile = report_tiles["lisbon"]
    stale_report["lisbon"] = (
        (lisbon_tile[0] + 1) % grid.width,
        (lisbon_tile[1] + 1) % grid.height,
    )
    results.append(
        _expect_g6_failure(
            "report-harbor-tile-stale",
            "lisbon",
            lambda: analyse_world_map(
                grid, ports, stale_report, discoveries, False, report_shores
            ),
        )
    )

    # (2b-1) A berth with no shore tile: fill every orthogonally adjacent `#`
    # of one port's berth with water, so the pair rule's mandatory neighbour is
    # gone. The failure must name that port (item 2b).
    landless_port = _G6_SHORE_PORT
    landless_tile = report_tiles.get(landless_port)
    landless = None
    if landless_tile is not None:
        x0, y0 = landless_tile
        indices = bytearray(grid.indices)
        removed = 0
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            yy = y0 + dy
            xx = (x0 + dx) % grid.width
            if 0 <= yy < grid.height and indices[yy * grid.width + xx] == 2:
                indices[yy * grid.width + xx] = 0  # '~'
                removed += 1
        landless = WorldGrid(grid.width, grid.height, indices)
    if landless is None or removed == 0:
        print(
            "FAIL g6-self-test berth-no-shore: cannot strip the shore tile of "
            f"'{landless_port}'"
        )
        results.append(False)
    else:
        results.append(
            _expect_g6_failure(
                "berth-no-shore",
                landless_port,
                lambda: analyse_world_map(
                    landless, ports, report_tiles, discoveries, False,
                    report_shores,
                ),
            )
        )

    # (2b-2) A stale shore_tile in the report: the independent recomputation
    # must name the port and both tiles (item 2b's comparison clause).
    stale_shores = dict(report_shores)
    kenya_shore = report_shores.get(_G6_SHORE_PORT)
    if kenya_shore is None:
        print("FAIL g6-self-test report-shore-tile-stale: no shore tile reported")
        results.append(False)
    else:
        stale_shores[_G6_SHORE_PORT] = (
            (kenya_shore[0] + 1) % grid.width,
            (kenya_shore[1] + 1) % grid.height,
        )
        results.append(
            _expect_g6_failure(
                "report-shore-tile-stale",
                _G6_SHORE_PORT,
                lambda: analyse_world_map(
                    grid, ports, report_tiles, discoveries, False, stale_shores
                ),
            )
        )

    # (2c) Two ports on one harbor tile: `safi` is moved onto Lisbon's
    # coordinates and both report copies follow, so the snap and pair
    # comparisons pass and the collision rule (section 9) is what fires.
    duplicate_ports = copy.deepcopy(ports)
    duplicate_report = dict(report_tiles)
    duplicate_shores = dict(report_shores)
    lisbon_port = next(port for port in ports if port["id"] == "lisbon")
    for port in duplicate_ports:
        if port["id"] == "safi":
            port["lat"] = lisbon_port["lat"]
            port["lon"] = lisbon_port["lon"]
    duplicate_report["safi"] = report_tiles["lisbon"]
    duplicate_shores["safi"] = report_shores["lisbon"]
    results.append(
        _expect_g6_failure(
            "duplicate-harbor-tile",
            "both snap to harbor tile",
            lambda: analyse_world_map(
                grid, duplicate_ports, duplicate_report, discoveries, False,
                duplicate_shores,
            ),
        )
    )

    # (2c-1) Two ports on one **shore** tile: move `safi` beside another port's
    # shore tile, on a water cell that selects that same shore tile, so both
    # comparisons pass and the shore-collision rule is what fires.
    shore_ports = copy.deepcopy(ports)
    shore_report = dict(report_tiles)
    shared_shores = dict(report_shores)
    holder_id = None
    shore_neighbour = None
    shared_shore = None
    for candidate in ports:
        holder_id = candidate["id"]
        berth = report_tiles.get(holder_id)
        shore = report_shores.get(holder_id)
        if berth is None or shore is None or holder_id == "safi":
            continue
        origin = tile_of_latlon(candidate["lat"], candidate["lon"])
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            yy = shore[1] + dy
            xx = (shore[0] + dx) % grid.width
            if not (0 <= yy < grid.height) or (xx, yy) == berth:
                continue
            if not (grid.passable[yy * grid.width + xx]
                    and has_orthogonal_water(grid, xx, yy)):
                continue
            found = shore_of_berth(grid, xx, yy, origin)
            if found is not None and (found[2], found[1]) == shore:
                shore_neighbour = (xx, yy)
                shared_shore = shore
                break
        if shore_neighbour is not None:
            break
    if shore_neighbour is None:
        print("FAIL g6-self-test duplicate-shore-tile: no alternative berth "
              "selecting another port's shore tile")
        results.append(False)
    else:
        for port in shore_ports:
            if port["id"] == "safi":
                port["lat"] = 90.0 - (shore_neighbour[1] + 0.5) / tiles_per_degree()
                port["lon"] = (shore_neighbour[0] + 0.5) / tiles_per_degree() - 180.0
        shore_report["safi"] = shore_neighbour
        shared_shores["safi"] = shared_shore
        results.append(
            _expect_g6_failure(
                "duplicate-shore-tile",
                "share shore tile",
                lambda: analyse_world_map(
                    grid, shore_ports, shore_report, discoveries, False,
                    shared_shores,
                ),
            )
        )

    # (3) Corrupted artifacts, written to temp files and read back through the
    # real file-level artifact check.
    with tempfile.TemporaryDirectory(prefix="sailage-g6-") as tmp:
        tmp_dir = Path(tmp)

        half = grid.height // 2
        short_path = tmp_dir / "world-short.png"
        short_path.write_bytes(
            _encode_indexed_png(
                grid.width, half, grid.indices[: grid.width * half],
                len(WORLD_PALETTE_CHARS),
            )
        )
        results.append(
            _expect_g6_failure(
                "png-wrong-size",
                f"locked at {MAP_WIDTH}x{MAP_HEIGHT}",
                lambda: _load_world_grid(short_path, WORLD_PNG_LABEL),
            )
        )

        bad_indices = bytearray(grid.indices)
        bad_index = 5  # above the locked 0-4 set
        bad_indices[grid.width * 10 + 10] = bad_index
        bad_index_path = tmp_dir / "world-index5.png"
        bad_index_path.write_bytes(
            _encode_indexed_png(
                grid.width, grid.height, bad_indices,
                len(WORLD_PALETTE_CHARS) + 1,
            )
        )
        results.append(
            _expect_g6_failure(
                "png-palette-index-5",
                f"palette index {bad_index}",
                lambda: _load_world_grid(bad_index_path, WORLD_PNG_LABEL),
            )
        )

        # The decoder must accept all five PNG filter types, not just the
        # builder's filter 0. Re-encode a slice of the real grid cycling
        # filters 0-4 per row and require a byte-identical decode.
        slice_w, slice_h, slice_y, slice_x = 320, 160, 300, 1000
        slice_indices = bytearray()
        for y in range(slice_y, slice_y + slice_h):
            row = y * grid.width
            slice_indices += grid.indices[row + slice_x:row + slice_x + slice_w]
        filters_path = tmp_dir / "world-filters.png"
        filters_path.write_bytes(
            _encode_indexed_png(
                slice_w, slice_h, slice_indices, len(WORLD_PALETTE_CHARS),
                filter_cycle=(0, 1, 2, 3, 4),
            )
        )
        try:
            fw, fh, findices = decode_indexed_png(filters_path.read_bytes())
            same = (
                (fw, fh) == (slice_w, slice_h)
                and bytes(findices) == bytes(slice_indices)
            )
        except PngFormatError as exc:
            same = False
            print(f"INFO g6 filter round-trip raised: {exc}")
        if same:
            print(
                "PASS g6 negative png-filter-types: scanlines using filters 0-4 "
                f"round-trip byte-identically ({slice_w}x{slice_h} slice)"
            )
        else:
            print(
                "FAIL g6-self-test png-filter-types: the decoder did not reproduce "
                "the filtered slice"
            )
        results.append(same)

    passed = sum(1 for result in results if result)
    total = len(results)
    if passed == total:
        print(f"OK g6 self-test: {total} negative case(s) all failed as required")
        return 0
    print(f"FAIL g6-self-test {total - passed} of {total} negative case(s) did not fail")
    return 1



# --- Group-7 sub-block: facility_hours.json (added 2026-11-02, §4.19) -------
# The §8 exit table has no row of its own for facility hours; the config-
# block shape check rides in group 7 (exit 7) with its own check-id, like
# the other named messages above.

FACILITY_HOURS_JSON_LABEL = "data/facility_hours.json"
# The §4.1 facility ids (docs/30-* §4.1) — every one needs a default window.
FACILITY_IDS = ("market", "shipyard", "tavern", "inn", "guild", "palace")


def _facility_minutes(text: object, what: str) -> int:
    """Parses one `HH:MM` window bound to minutes; `fail`s on any deviation."""
    if not isinstance(text, str):
        fail("hours", FACILITY_HOURS_JSON_LABEL, f"{what}: must be a string", 7)
    parts = text.split(":")
    if len(parts) != 2 or not all(part.isdigit() and len(part) == 2
                                  for part in parts):
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             f"{what}: {text!r} is not HH:MM", 7)
    hours, minutes = int(parts[0]), int(parts[1])
    if not (0 <= hours <= 24 and 0 <= minutes <= 59):
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             f"{what}: {text!r} out of range", 7)
    value = hours * 60 + minutes
    if value == 0:
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             f"{what}: 00:00 is never a window bound", 7)
    return value


def _facility_window(value: object, what: str) -> tuple[int, int]:
    """One window: the string `\"24h\"` or the `[open, close]` pair."""
    if value == "24h":
        return (-1, -1)
    if not isinstance(value, list) or len(value) != 2:
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             f"{what}: must be \"24h\" or [open, close]", 7)
    open_min = _facility_minutes(value[0], f"{what} open")
    close_min = _facility_minutes(value[1], f"{what} close")
    if close_min != 1440 and open_min >= close_min:
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             f"{what}: open {value[0]!r} must precede close {value[1]!r}", 7)
    return (open_min, close_min)


def check_facility_hours(docs: dict[str, object], verbose: bool) -> None:
    """Facility opening hours: docs/10-DATA-SCHEMA.md section 4.19."""
    hours = docs.get("facility_hours.json")
    if not isinstance(hours, dict):
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             "missing (the §4.19 opening-hours table is required)", 7)
    version = hours.get("version")
    if not is_int(version) or version != 1:
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             f"'version' must be 1 (got {version!r})", 7)
    default = hours.get("default")
    if not isinstance(default, dict) or not default:
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             "'default' must be a non-empty object", 7)
    unknown = sorted(set(default) - set(FACILITY_IDS))
    if unknown:
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             f"'default' has unknown facility ids {unknown}", 7)
    missing = sorted(set(FACILITY_IDS) - set(default))
    if missing:
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             f"'default' is missing facility ids {missing} (30-* §4.1)", 7)
    windows: dict[str, tuple[int, int]] = {}
    for facility_id in FACILITY_IDS:
        if facility_id not in default:
            continue
        windows[facility_id] = _facility_window(
            default[facility_id], f"default.{facility_id}")
    if default.get("inn") != "24h":
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             f"default.inn must be \"24h\" (30-* §4.1b; got "
             f"{default.get('inn')!r})", 7)

    overrides = hours.get("overrides")
    if not isinstance(overrides, dict):
        fail("hours", FACILITY_HOURS_JSON_LABEL,
             "'overrides' must be an object", 7)
    port_ids = {port["id"] for port in docs["ports.json"]["ports"]}
    override_count = 0
    for port_id, table in overrides.items():
        if port_id not in port_ids:
            fail("hours", FACILITY_HOURS_JSON_LABEL,
                 f"overrides: unknown port id {port_id!r}", 7)
        if not isinstance(table, dict) or not table:
            fail("hours", FACILITY_HOURS_JSON_LABEL,
                 f"overrides.{port_id}: must be a non-empty object", 7)
        unknown_fac = sorted(set(table) - set(FACILITY_IDS))
        if unknown_fac:
            fail("hours", FACILITY_HOURS_JSON_LABEL,
                 f"overrides.{port_id}: unknown facility ids {unknown_fac}", 7)
        for facility_id, window in table.items():
            _facility_window(window, f"overrides.{port_id}.{facility_id}")
            override_count += 1

    if verbose:
        print(
            f"PASS group 7 facility hours ({len(windows)} default windows, "
            f"{override_count} override(s), inn 24h)"
        )


# ---------------------------------------------------------------------------
# Check group 7 — NPC & economy data
# ---------------------------------------------------------------------------


def _is_number(value) -> bool:
    """True for JSON numbers only (bool is not a number for schema purposes)."""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _check_complete_l10n(value, path: str, filename: str) -> None:
    """A self-contained complete-L10nString check (section 8.2: "complete
    i18n" inside the group-7 files). Group 2's recursion normally covers
    this; repeating it here keeps group 7's verdicts self-contained."""
    _check_l10n(value, path, filename)


def _check_npc_config(config: object) -> None:
    """npc_config.json (section 8.2 item 1, section 4.10)."""
    label = "npc_config.json"
    if not isinstance(config, dict):
        fail("npc-config", label, "config block must be a JSON object", 7)
    if config.get("version") != 1 or not is_int(config.get("version")):
        fail("npc-config", label, "version must be the integer 1 (section 4.10)", 7)
    extra = sorted(set(config) - set(NPC_CONFIG_KEYS) - set(NPC_CONFIG_OPTIONAL_KEYS))
    missing = sorted(set(NPC_CONFIG_KEYS) - set(config))
    if extra or missing:
        details = []
        if missing:
            details.append(f"missing {', '.join(missing)}")
        if extra:
            details.append(f"unexpected {', '.join(extra)}")
        fail("npc-config", label,
             f"config block keys must be exactly the section 4.10 set: "
             f"{'; '.join(details)}", 7)

    presets = config["presets"]
    if not isinstance(presets, dict) or set(presets) != set(NPC_PRESET_KEYS):
        fail(
            "npc-config",
            label,
            "presets keys must be exactly "
            f"{', '.join(NPC_PRESET_KEYS)} (section 4.10)",
            7,
        )
    for key, value in presets.items():
        if not _is_number(value):
            fail(
                "npc-config",
                label,
                f"presets.{key} must be a number (got {value!r})",
                7,
            )
        if value < 0:
            fail(
                "npc-config",
                label,
                f"presets.{key} must be >= 0 (got {value}) — a negative "
                "density multiplier is meaningless (section 8.2 item 1)",
                7,
            )
    neutral = [key for key, value in presets.items() if value == 1.0]
    if len(neutral) != 1:
        fail(
            "npc-config",
            label,
            f"exactly one preset multiplier must be 1.0 (found "
            f"{len(neutral)}: {', '.join(neutral) or 'none'})",
            7,
        )
    default_preset = config["default_preset"]
    if default_preset not in presets:
        fail(
            "npc-config",
            label,
            f"default_preset {default_preset!r} is not in presets",
            7,
        )
    if default_preset != neutral[0]:
        fail(
            "npc-config",
            label,
            f"default_preset {default_preset!r} must name the neutral "
            f"1.0 preset ({neutral[0]!r}), not the "
            f"{presets[default_preset]} multiplier",
            7,
        )

    for block_name, block_keys in (("budgets", NPC_BUDGET_KEYS),
                                   ("flow", NPC_FLOW_KEYS)):
        block = config[block_name]
        if not isinstance(block, dict) or set(block) != set(block_keys):
            fail(
                "npc-config",
                label,
                f"{block_name} keys must be exactly "
                f"{', '.join(block_keys)} (section 4.10)",
                7,
            )
        for key, value in block.items():
            if not _is_number(value):
                fail(
                    "npc-config",
                    label,
                    f"{block_name}.{key} must be a number (got {value!r})",
                    7,
                )
            if value <= 0:
                fail(
                    "npc-config",
                    label,
                    f"{block_name}.{key} must be > 0 (got {value})",
                    7,
                )

    absolute_cap = config["absolute_cap"]
    if not is_int(absolute_cap) or not (0 <= absolute_cap <= ABSOLUTE_CAP_MAX):
        fail(
            "npc-config",
            label,
            f"absolute_cap must be an integer in [0, {ABSOLUTE_CAP_MAX}] "
            f"(got {absolute_cap!r}) — the section 4.10 locked cap",
            7,
        )

    # Phase 7 (§8 group 7 / correction 15): the `neutral_coasters_mult` data
    # line — optional until task N lands it (W4), bounded > 0 whenever
    # present. §2.7 pins the authored value := 0.75.
    if "neutral_coasters_mult" in config:
        value = config["neutral_coasters_mult"]
        if not _is_number(value) or value <= 0:
            fail(
                "npc-config",
                label,
                f"neutral_coasters_mult must be a number > 0 (got {value!r}) "
                "— the §2.7 nationless-coaster spawn multiplier "
                "(authored 0.75, correction 15)",
                7,
            )

    # Phase 9 (§4.10 `ai_profiles` / §8.2 item 14; corrections 8+11): the
    # per-kind battle-behavior block — exact kind set, exact row shape,
    # enum membership, integer ranges and the locked value table, all from
    # day one. Presence is guaranteed by the exact-top-level-keys check
    # above (`ai_profiles` is a required §4.10 key).
    profiles = config["ai_profiles"]
    if not isinstance(profiles, dict) or set(profiles) != set(NPC_AI_PROFILE_KINDS):
        rows = profiles if isinstance(profiles, dict) else {}
        extra = sorted(set(rows) - set(NPC_AI_PROFILE_KINDS))
        missing = sorted(set(NPC_AI_PROFILE_KINDS) - set(rows))
        details = []
        if missing:
            details.append(f"missing {', '.join(missing)}")
        if extra:
            details.append(
                f"unexpected {', '.join(extra)}"
                + (" — no hunter row may exist (hunter battles enter as "
                   "kind navy, correction 8)" if "hunter" in extra else "")
            )
        fail(
            "npc-config",
            label,
            f"ai_profiles rows must be exactly the §4.10 nine kinds: "
            f"{'; '.join(details)}",
            7,
        )

    for kind in NPC_AI_PROFILE_KINDS:
        row = profiles[kind]
        rpath = f"ai_profiles.{kind}"
        if not isinstance(row, dict) or set(row) != set(NPC_AI_PROFILE_KEYS):
            keys = set(row) if isinstance(row, dict) else set()
            missing = [key for key in NPC_AI_PROFILE_KEYS if key not in keys]
            extra = sorted(keys - set(NPC_AI_PROFILE_KEYS))
            details = []
            if missing:
                details.append(f"missing {', '.join(missing)}")
            if extra:
                details.append(f"unexpected {', '.join(extra)}")
            fail(
                "npc-config",
                label,
                f"{rpath} must carry exactly the §4.10 nine keys "
                f"({', '.join(NPC_AI_PROFILE_KEYS)}): {'; '.join(details)}",
                7,
            )
        if row["kind"] != kind:
            fail(
                "npc-config",
                label,
                f"{rpath}.kind ({row['kind']!r}) must mirror the row's map "
                f"key ({kind!r}) (§8.2 item 14)",
                7,
            )
        if row["archetype"] not in NPC_AI_ARCHETYPES:
            fail(
                "npc-config",
                label,
                f"{rpath}.archetype must be one of "
                f"{'|'.join(NPC_AI_ARCHETYPES)} (got {row['archetype']!r}) "
                "— the T3 θ group selector (§4.10)",
                7,
            )
        if row["focus"] not in NPC_AI_FOCUS:
            fail(
                "npc-config",
                label,
                f"{rpath}.focus must be one of {'|'.join(NPC_AI_FOCUS)} "
                f"(got {row['focus']!r}) (§4.10)",
                7,
            )
        if row["formation"] not in NPC_AI_FORMATIONS:
            fail(
                "npc-config",
                label,
                f"{rpath}.formation must be one of "
                f"{'|'.join(NPC_AI_FORMATIONS)} (got {row['formation']!r}) "
                "(§4.10)",
                7,
            )
        for key, low, high in (("aggression", 0, 100),
                               ("preferred_range", 1, 3),
                               ("flee_below_hp_pct", 0, 100),
                               ("courage_mod", -10, 10)):
            value = row[key]
            if not is_int(value) or not low <= value <= high:
                fail(
                    "npc-config",
                    label,
                    f"{rpath}.{key} must be an integer in [{low}, {high}] "
                    f"(got {value!r}) (§4.10)",
                    7,
                )
        if not is_int(row["ai_level"]) or row["ai_level"] not in (0, 1):
            fail(
                "npc-config",
                label,
                f"{rpath}.ai_level must be the integer 0 or 1 "
                f"(got {row['ai_level']!r}) — T2 greedy vs T3 lookahead "
                "(§4.10)",
                7,
            )
        # §4.10 normative value table, verbatim — the fixture pin makes a
        # data-wave transcription error impossible to merge.
        pinned = dict(zip(NPC_AI_PROFILE_KEYS[1:], LOCKED_AI_PROFILES[kind]))
        for key, expected in pinned.items():
            if row[key] != expected:
                fail(
                    "npc-config",
                    label,
                    f"{rpath}.{key} must be the §4.10 locked value "
                    f"{expected!r} (got {row[key]!r})",
                    7,
                )


# §8.6 item 1 (W4-B, 2026-11-03): `data/npc_captains.json` is DELETED — the
# Phase-5 name pools are gone (§7.7); group 11 asserts the file's absence
# below (see check_group11).


def _check_named_pirates(pirates_doc: object, captains_doc: object,
                         equipment: list) -> None:
    """named_pirates.json (section 8.2 item 3, sections 4.12 / 7.8) — the
    Phase-8 v2 full-card form. Exactly the 4 locked ids, each a full captain
    card field-for-field identical to its canon copy in captains.json, with
    `drop` present and referencing a `rare: true` equipment item (the
    Phase-7 pin, semantics unchanged — correction 7). The distinctness /
    1:1 pairing with the 4 rare items is _check_pirate_drop_pairing below."""
    label = "named_pirates.json"
    pirates = pirates_doc.get("named_pirates") \
        if isinstance(pirates_doc, dict) else None
    if not isinstance(pirates, list):
        fail("named-pirates", label, "missing 'named_pirates' array", 7)
    if len(pirates) != NAMED_PIRATE_COUNT:
        fail(
            "named-pirates",
            label,
            f"exactly {NAMED_PIRATE_COUNT} named pirates are locked "
            f"(section 7.8), got {len(pirates)}",
            7,
        )
    canon = captains_doc.get("captains") \
        if isinstance(captains_doc, dict) else None
    if not isinstance(canon, list):
        fail(
            "named-pirates",
            label,
            "captains.json is missing — the v2 rows are canon copies "
            "(section 4.12)",
            7,
        )
    canon_by_id = {card.get("id"): card for card in canon
                   if isinstance(card, dict)}
    rare_ids = {item["id"] for item in equipment
                if item.get("rare") is True}
    seen: set[str] = set()
    drops: list[str] = []
    for index, pirate in enumerate(pirates):
        path = f"named_pirates[{index}]"
        if not isinstance(pirate, dict):
            fail("named-pirates", label,
                 f"{path} must be a captain card object", 7)
        pirate_id = pirate.get("id")
        if pirate_id not in LOCKED_NAMED_PIRATE_IDS:
            fail(
                "named-pirates",
                label,
                f"{path} id {pirate_id!r} is outside the 4 locked ids "
                f"({', '.join(LOCKED_NAMED_PIRATE_IDS)} — section 7.8)",
                7,
            )
        if pirate_id in seen:
            fail("named-pirates", label,
                 f"{path} repeats id {pirate_id!r}", 7)
        seen.add(pirate_id)
        # Field-for-field canon equality (§4.12): the bounty-facing copy IS
        # the canon card (the builder writes the same object into both
        # files), `drop` included.
        canon_card = canon_by_id.get(pirate_id)
        if canon_card is None or pirate != canon_card:
            fail(
                "named-pirates",
                label,
                f"{path} ({pirate_id}) is not field-for-field identical to "
                "its captains.json canon copy (section 4.12)",
                7,
            )
        tier = pirate.get("tier")
        if not is_int(tier) or not (NAMED_PIRATE_TIER_MIN <= tier
                                    <= NAMED_PIRATE_TIER_MAX):
            fail(
                "named-pirates",
                label,
                f"{path} ({pirate_id}) tier must be an integer in "
                f"{NAMED_PIRATE_TIER_MIN}-{NAMED_PIRATE_TIER_MAX} "
                f"(70-* section 4.5 bounty bands), got {tier!r}",
                7,
            )
        drop = pirate.get("drop")
        if not isinstance(drop, str) or not ID_RE.match(drop):
            fail("named-pirates", label,
                 f"{path} ({pirate_id}) drop must be an equipment id "
                 f"(got {drop!r})", 7)
        if drop not in rare_ids:
            fail(
                "named-pirates",
                label,
                f"{path} ({pirate_id}) drop {drop!r} does not reference a "
                "rare: true equipment item (§4.12 — drops come from the "
                "four rare items of §7.9)",
                7,
            )
        drops.append(drop)
    missing = [pid for pid in LOCKED_NAMED_PIRATE_IDS if pid not in seen]
    if missing:
        fail(
            "named-pirates",
            label,
            f"missing the locked named-pirate id(s) {', '.join(missing)} "
            "(section 7.8)",
            7,
        )
    # §8.2 item 12: the 4 drops are distinct (the 1:1 pairing with the 4
    # rare items is checked below in the economy block).
    if len(set(drops)) != len(drops):
        fail(
            "named-pirates",
            label,
            f"drops must be distinct (got {sorted(drops)}) — §8.2 item 12",
            7,
        )


def _check_market_events(events_doc: object, ports: list, good_ids: set) -> None:
    """market_events.json (section 8.2 item 4, Phase-7 rate-surge form —
    30-* section 4.5, IMPLEMENT-Phase7.md correction 9)."""
    label = "market_events.json"
    events = events_doc.get("market_events") \
        if isinstance(events_doc, dict) else None
    if not isinstance(events, list):
        fail("market-events", label, "missing 'market_events' array", 7)

    seen: set[str] = set()
    for index, event in enumerate(events):
        path = f"market_events[{index}]"
        required = {"id", "scope", "cadence_days", "duration_days",
                    "rate_override", "name"}
        if not isinstance(event, dict) or set(event) != required:
            fail(
                "market-events",
                label,
                f"{path} must be an object with exactly keys "
                "id,scope,cadence_days,duration_days,rate_override,name "
                "(section 4.13, Phase-7 rate_override form)",
                7,
            )
            continue
        _require_id(event["id"], f"{path}.id", label)
        if event["id"] in seen:
            fail("market-events", label,
                 f"{path} repeats id {event['id']!r}", 7)
        seen.add(event["id"])
        if event["scope"] != "port":
            fail(
                "market-events",
                label,
                f"{path} ({event['id']}) scope must be \"port\" — the only "
                "valid value this phase (section 4.13)",
                7,
            )
        for field in ("cadence_days", "duration_days"):
            if not is_int(event[field]) or event[field] <= 0:
                fail(
                    "market-events",
                    label,
                    f"{path} ({event['id']}) {field} must be an integer > 0 "
                    f"(got {event[field]!r})",
                    7,
                )
        _check_complete_l10n(event["name"], f"{path}.name", label)

        overrides = event["rate_override"]
        if not isinstance(overrides, list):
            fail(
                "market-events",
                label,
                f"{path} ({event['id']}) rate_override must be a list of "
                "good ids whose consumption the event surges ×3 "
                "(section 4.5)",
                7,
            )
            continue
        if not overrides:
            fail(
                "market-events",
                label,
                f"{path} ({event['id']}) rate_override is empty — an event "
                "surging nothing is a no-op, not a template",
                7,
            )
        surged: set[str] = set()
        for good_id in overrides:
            if not isinstance(good_id, str) or good_id not in good_ids:
                fail(
                    "market-events",
                    label,
                    f"{path} ({event['id']}) rate_override references "
                    f"unknown good {good_id!r}",
                    7,
                )
                continue
            if good_id in surged:
                fail(
                    "market-events",
                    label,
                    f"{path} ({event['id']}) rate_override repeats good "
                    f"{good_id!r} — a ×3 surge listed twice would read as "
                    "a magnitude",
                    7,
                )
                continue
            surged.add(good_id)


def _check_consumption_tiers(goods: list) -> tuple[set, set, set]:
    """Section 8.2 item 5, Phase-7 form (`10-*` §4.2): the tier is read from
    the goods flags — exactly 12 `staple: true` (staple tier), exactly 12
    `specialty: true` (luxury tier), the remaining 16 unflagged (middle).
    `exclusive ⇒ specialty` is asserted here and in group 3. Returns
    (staple_ids, middle_ids, luxury_ids)."""
    staples = sorted(g["id"] for g in goods if g.get("staple") is True)
    luxuries = sorted(g["id"] for g in goods if g.get("specialty") is True)
    middle = sorted(g["id"] for g in goods
                    if g.get("staple") is not True
                    and g.get("specialty") is not True)
    expected = CONSUMPTION_TIER_SPLIT
    actual = (len(staples), len(middle), len(luxuries))
    if actual != expected:
        detail = []
        if len(staples) != expected[0]:
            detail.append(
                f"{len(staples)} staple: true goods (want {expected[0]}: "
                f"{', '.join(staples)})")
        if len(luxuries) != expected[2]:
            detail.append(
                f"{len(luxuries)} specialty: true goods (want {expected[2]}: "
                f"{', '.join(luxuries)})")
        fail(
            "consumption-tiers",
            "goods.json",
            f"flag-driven consumption tiers must split {expected[0]}/"
            f"{expected[1]}/{expected[2]} (10-* §4.2 — `staple`/`specialty` "
            f"flags, the base-price-rank split is retired), got "
            f"{actual[0]}/{actual[1]}/{actual[2]}: {'; '.join(detail)}",
            7,
        )
    return set(staples), set(middle), set(luxuries)


# --- Phase-7 economy-graph checks (§8.2 items 6-13, task T) -----------------
# Normative spec docs/10-DATA-SCHEMA.md §8.2; graph semantics per
# `30-*` §4.2 / `IMPLEMENT-Phase7.md` §2.1 (decisions 21/22/25/23).
# The group-7 market-event checks above are UNTOUCHED by Phase 7's W2 wave
# (correction 9 — task K owns the event-shape transition in W3).


def _port_tile(port: dict) -> tuple[int, int]:
    """The §6.1 grid tile of a port's lat/lon (12 tiles/degree, wrap x).

    Group 7's coverage checks need only the derived tile — no raster decode;
    group 6 already proves the snapped harbor tiles agree with these.
    """
    return tile_of_latlon(port["lat"], port["lon"])


def _port_distance(a: dict, b: dict) -> int:
    """Wrap-aware Chebyshev tile distance between two ports (§6.1 grid)."""
    ax, ay = _port_tile(a)
    bx, by = _port_tile(b)
    return chebyshev_wrap(bx - ax, by - ay)


def _check_port_economy_graph(ports: list, staples: set) -> None:
    """§8.2 item 6 (correction 3): produces ∩ demands = ∅ (hard) and
    demands ⊇ (staples ∖ produces) per port — every staple not produced
    here is demanded here, so staples ⊆ produces ∪ demands everywhere."""
    for port in ports:
        port_id = port["id"]
        produces = set(port.get("produces", ()))
        demands = set(port.get("demands", ()))
        overlap = sorted(produces & demands)
        if overlap:
            fail(
                "economy-graph",
                "ports.json",
                f"port {port_id}: produces ∩ demands = {overlap} must be ∅ "
                "(§8.2 item 6 — the listing rule makes every listed good "
                "exactly one of producer or consumer)",
                7,
            )
        missing = sorted(staples - produces - demands)
        if missing:
            fail(
                "economy-graph",
                "ports.json",
                f"port {port_id}: demands misses the non-produced staples "
                f"{missing} — demands ⊇ (staples ∖ produces) "
                "(§8.2 item 6, correction 3: staples are ubiquitous by "
                "the data rule)",
                7,
            )


def _check_graph_shape(ports: list, goods: list) -> None:
    """§8.2 item 7 (decision 22): every good ≥ 2 producers and ≥ 4 consumers
    worldwide; every `specialty` good ≤ 6 producers (§4.2)."""
    for good in goods:
        good_id = good["id"]
        producers = sorted(p["id"] for p in ports
                           if good_id in p.get("produces", ()))
        consumers = sorted(p["id"] for p in ports
                           if good_id in p.get("demands", ()))
        if len(producers) < 2:
            fail(
                "graph-shape",
                "ports.json",
                f"good {good_id} has {len(producers)} producer(s) "
                f"({', '.join(producers) or 'none'}) — every good needs "
                "≥ 2 producers and ≥ 4 consumers (§8.2 item 7)",
                7,
            )
        if len(consumers) < 4:
            fail(
                "graph-shape",
                "ports.json",
                f"good {good_id} has {len(consumers)} consumer(s) — every "
                "good needs ≥ 2 producers and ≥ 4 consumers (§8.2 item 7)",
                7,
            )
        if good.get("specialty") is True and len(producers) > 6:
            fail(
                "graph-shape",
                "ports.json",
                f"specialty good {good_id} is produced at {len(producers)} "
                "ports — a specialty has ≤ 6 producers worldwide (§4.2)",
                7,
            )


def _check_staple_coverage(ports: list, staples: set) -> list[tuple]:
    """§8.2 item 8 (decision 21): from every port a staple producer within
    120 tiles (Chebyshev, wrap-aware) and ≥ 2 within 240; every band has
    ≥ 2 staple producers. Returns the (distance, port, producer, good)
    ranking of nearest-staple runs for the harness report."""
    producers = [p for p in ports if staples & set(p.get("produces", ()))]
    ranking: list[tuple] = []
    for port in ports:
        best = None
        best_producer = None
        best_good = None
        within_240 = 0
        for producer in producers:
            distance = _port_distance(port, producer)
            if distance <= 240:
                within_240 += 1
            if best is None or distance < best:
                best = distance
                best_producer = producer["id"]
                best_good = sorted(
                    staples & set(producer.get("produces", ())))[0]
        if best is None or best > 120:
            fail(
                "staple-coverage",
                "ports.json",
                f"port {port['id']}: nearest staple producer is "
                f"{best if best is not None else 'unreachable'} tiles away "
                f"({best_producer}) — every port needs one within 120 tiles "
                "(§8.2 item 8, decision 21)",
                7,
            )
        if within_240 < 2:
            fail(
                "staple-coverage",
                "ports.json",
                f"port {port['id']}: {within_240} staple producer(s) within "
                "240 tiles — every port needs ≥ 2 (§8.2 item 8)",
                7,
            )
        ranking.append((best, port["id"], best_producer, best_good))
    # ≥ 2 staple producers per band (§7.1 bands; the band set itself is
    # item 13's check below).
    by_band: dict[str, int] = {}
    for producer in producers:
        by_band[producer["band"]] = by_band.get(producer["band"], 0) + 1
    for band in sorted({p["band"] for p in ports}):
        if by_band.get(band, 0) < 2:
            fail(
                "staple-coverage",
                "ports.json",
                f"band {band}: {by_band.get(band, 0)} staple producer(s) — "
                "every band needs ≥ 2 (§8.2 item 8, decision 21)",
                7,
            )
    ranking.sort(key=lambda row: (-row[0], row[1]))
    return ranking


def _check_exclusive_coverage(ports: list, goods_by_id: dict) -> None:
    """§8.2 item 9: every neutral band (any band containing a
    `nation_id: ""` port) has ≥ 1 exclusive good produced within it."""
    neutral_bands = sorted({p["band"] for p in ports
                            if p.get("nation_id") == NEUTRAL_PORT_NATION_ID})
    produced_exclusive: dict[str, list[str]] = {}
    for port in ports:
        for good_id in port.get("produces", ()):
            good = goods_by_id.get(good_id, {})
            if good.get("exclusive") is True:
                produced_exclusive.setdefault(port["band"], [])
                if port["id"] not in produced_exclusive[port["band"]]:
                    produced_exclusive[port["band"]].append(port["id"])
    for band in neutral_bands:
        if not produced_exclusive.get(band):
            fail(
                "exclusive-coverage",
                "ports.json",
                f"neutral band {band}: no exclusive good is produced within "
                "it — every neutral band needs ≥ 1 exclusive producer "
                "(§8.2 item 9, §4.2)",
                7,
            )


def _check_port_classes(ports: list) -> None:
    """§8.2 item 10 (decision 25): protected only on sovereign rows, the set
    contains every capital and ≤ 4 ports per nation (membership is the
    contract — master ruling on the W2 staged data; the decision-25 core set
    is the authored member list), protected rows carry no sphere entries,
    and the authored `dev` floors: 3 on capitals/protected, 0 on every
    neutral, {1, 2} on the remaining sovereign contestable rows."""
    by_id = {p["id"]: p for p in ports}
    protected = sorted(p["id"] for p in ports if p.get("protected") is True)
    missing_capitals = sorted(set(CAPITAL_PORT_IDS) - set(protected))
    if missing_capitals:
        fail(
            "port-classes",
            "ports.json",
            f"capital(s) {', '.join(missing_capitals)} missing from the "
            "protected set — protected ⊇ the 6 capitals (§7.1)",
            7,
        )
    per_nation: dict[str, int] = {}
    for port_id in protected:
        port = by_id[port_id]
        if port.get("nation_id") == NEUTRAL_PORT_NATION_ID:
            fail(
                "port-classes",
                "ports.json",
                f"protected port {port_id} is a neutral-tier row — "
                "`protected` is sovereign-only (§7.1)",
                7,
            )
            continue
        per_nation[port["nation_id"]] = per_nation.get(port["nation_id"], 0) + 1
        if port.get("sphere"):
            fail(
                "port-classes",
                "ports.json",
                f"protected port {port_id} carries sphere entries — "
                "protected rows carry none (§7.1, never AI-investable)",
                7,
            )
    for nation_id, count in sorted(per_nation.items()):
        if count > 4:
            fail(
                "port-classes",
                "ports.json",
                f"nation {nation_id} has {count} protected ports — "
                "≤ 4 per nation (§7.1)",
                7,
            )
    for port in ports:
        port_id = port["id"]
        dev = port.get("dev")
        is_capital = port_id in CAPITAL_PORT_IDS
        is_protected = port.get("protected") is True
        if port.get("nation_id") == NEUTRAL_PORT_NATION_ID:
            if dev != 0:
                fail(
                    "port-classes",
                    "ports.json",
                    f"neutral port {port_id} has authored dev {dev} — the "
                    "neutral floor is 0 (§7.1)",
                    7,
                )
        elif is_capital or is_protected:
            if dev != 3:
                fail(
                    "port-classes",
                    "ports.json",
                    f"{('capital' if is_capital else 'protected')} port "
                    f"{port_id} has authored dev {dev} — the floor is 3 "
                    "(§7.1)",
                    7,
                )
        elif dev not in (1, 2):
            fail(
                "port-classes",
                "ports.json",
                f"sovereign contestable port {port_id} has authored dev "
                f"{dev} — majors carry 2, the rest 1 (§7.1)",
                7,
            )


def _check_hardware_tiers(ports: list, ships: list, equipment: list) -> None:
    """§8.2 item 11 (decision 23): ≥ 2 hulls per tier; equipment 2/2/2 per
    slot; ≥ 4 dev-3 sovereign ports whose shipyard stocks a tier-3 hull;
    equipment_stock ≥ 2 at every shipyard port; no `rare` item in any stock
    list."""
    ships_per_tier: dict[int, int] = {}
    for ship in ships:
        ships_per_tier[ship["tier"]] = ships_per_tier.get(ship["tier"], 0) + 1
    for tier in (1, 2, 3):
        if ships_per_tier.get(tier, 0) < 2:
            fail(
                "hardware-tiers",
                "ship_types.json",
                f"tier {tier} has {ships_per_tier.get(tier, 0)} hull(s) — "
                "≥ 2 per tier (§8.2 item 11)",
                7,
            )
    slot_tiers: dict[str, dict[int, int]] = {}
    for item in equipment:
        per_slot = slot_tiers.setdefault(item["slot"], {})
        per_slot[item["tier"]] = per_slot.get(item["tier"], 0) + 1
    rare_ids = {item["id"] for item in equipment if item.get("rare") is True}
    for slot in sorted(slot_tiers):
        per_slot = slot_tiers[slot]
        for tier in (1, 2, 3):
            if per_slot.get(tier, 0) != 2:
                fail(
                    "hardware-tiers",
                    "equipment.json",
                    f"slot {slot} tier {tier}: {per_slot.get(tier, 0)} "
                    "item(s) — exactly 2/2/2 per slot (§7.9)",
                    7,
                )
    tier3_by_id = {ship["id"]: ship["tier"] for ship in ships}
    dev3_tier3 = sorted(
        p["id"] for p in ports
        if p.get("nation_id") != NEUTRAL_PORT_NATION_ID
        and p.get("dev") == 3
        and any(tier3_by_id.get(h) == 3
                for h in p.get("facilities", {}).get("shipyard", ())))
    if len(dev3_tier3) < 4:
        fail(
            "hardware-tiers",
            "ports.json",
            f"only {len(dev3_tier3)} dev-3 sovereign port(s) stock a tier-3 "
            f"hull ({', '.join(dev3_tier3) or 'none'}) — ≥ 4 required "
            "(§8.2 item 11)",
            7,
        )
    for port in ports:
        facilities = port.get("facilities", {})
        if "shipyard" not in facilities:
            continue
        stock = facilities.get("equipment_stock", ())
        if len(stock) < EQUIPMENT_STOCK_MIN:
            fail(
                "hardware-tiers",
                "ports.json",
                f"shipyard port {port['id']} carries "
                f"{len(stock)} equipment_stock id(s) — ≥ "
                f"{EQUIPMENT_STOCK_MIN} at every shipyard port (§8.2 item 11)",
                7,
            )
        stocked_rare = sorted(set(stock) & rare_ids)
        if stocked_rare:
            fail(
                "hardware-tiers",
                "ports.json",
                f"port {port['id']} equipment_stock lists rare drop-only "
                f"item(s) {', '.join(stocked_rare)} — rare items are never "
                "stocked (§8.2 item 11, §7.9)",
                7,
            )
        # Master ruling 3 (W2 staged data): every list carries at least one
        # tier-1 item (the entry-level buy at every shipyard), and tier-3
        # items appear only in dev-3 capital lists (high-tier hardware is
        # development-gated, decision 23 — a stock list never front-runs the
        # dev gate). Full-set coverage is NOT asserted (content reachability
        # is the author's, not a lock).
        tier_by_id = {item["id"]: item["tier"] for item in equipment}
        if not any(tier_by_id.get(item_id) == 1 for item_id in stock):
            fail(
                "hardware-tiers",
                "ports.json",
                f"port {port['id']} equipment_stock has no tier-1 item — "
                "every shipyard port stocks at least one (W2 ruling)",
                7,
            )
        high = sorted(item_id for item_id in stock
                      if tier_by_id.get(item_id) == 3)
        if high and not (port["id"] in CAPITAL_PORT_IDS and port.get("dev") == 3):
            fail(
                "hardware-tiers",
                "ports.json",
                f"port {port['id']} equipment_stock lists tier-3 item(s) "
                f"{', '.join(high)} — tier-3 stock is a dev-3 capital "
                "prerogative (W2 ruling; decision 23)",
                7,
            )


def _check_pirate_drop_pairing(pirates: list, equipment: list) -> None:
    """§8.2 item 12: the 4 drops are distinct (checked in
    _check_named_pirates) and pair 1:1 with the 4 `rare: true` items."""
    rare_ids = sorted(item["id"] for item in equipment
                      if item.get("rare") is True)
    drops = sorted(p.get("drop") for p in pirates)
    if drops != rare_ids:
        fail(
            "pirate-drops",
            "named_pirates.json",
            f"the drops {drops} must pair 1:1 with the 4 rare items "
            f"{rare_ids} (§8.2 item 12)",
            7,
        )


def _check_band_set(ports: list) -> None:
    """§8.2 item 13: every port band ∈ the §7.1 recorded set; the six
    neutral-region skeleton ids are present; the set covers all 150 ports
    with no unused id."""
    used = sorted({p["band"] for p in ports})
    outside = sorted(set(used) - set(LOCKED_BANDS))
    if outside:
        fail(
            "band-set",
            "ports.json",
            f"band id(s) {', '.join(outside)} are outside the §7.1 recorded "
            "set — bands are authored by task P and recorded in §7.1, "
            "never invented per port (§8.2 item 13)",
            7,
        )
    missing_skeleton = sorted(set(LOCKED_BANDS) - set(used))
    if missing_skeleton:
        fail(
            "band-set",
            "ports.json",
            f"band id(s) {', '.join(missing_skeleton)} are unused — the §7.1 "
            "set covers all 150 ports with no unused id (§8.2 item 13)",
            7,
        )


def check_group7(docs: dict[str, object], verbose: bool) -> None:
    """Npc & economy data: docs/10-DATA-SCHEMA.md section 8.2.

    Owns structure, counts and bounds for the Phase-5 files still in force;
    L10nString completeness inside them is group 2's recursion. Phase 7 adds
    the economy-data checks of §8.2 items 5-13; Phase 8 removes the
    npc_captains reads (§8.2 item 2 — the retired name pools; W4-B deleted
    the file) and turns the named pirates into v2 full-card checks. The
    §4.19 facility-hours sub-block rides here (the §8 exit table has no row
    of its own for it).
    """
    _check_npc_config(docs.get("npc_config.json"))
    _check_named_pirates(
        docs["named_pirates.json"],
        docs.get("captains.json", {}),
        docs["equipment.json"]["equipment"],
    )
    _check_market_events(
        docs["market_events.json"],
        docs["ports.json"]["ports"],
        {good["id"] for good in docs["goods.json"]["goods"]},
    )
    staples, middle, luxuries = _check_consumption_tiers(
        docs["goods.json"]["goods"]
    )

    ports = docs["ports.json"]["ports"]
    goods = docs["goods.json"]["goods"]
    ships = docs["ship_types.json"]["ship_types"]
    equipment = docs["equipment.json"]["equipment"]
    pirates = docs["named_pirates.json"]["named_pirates"]
    goods_by_id = {good["id"]: good for good in goods}
    _check_port_economy_graph(ports, staples)
    _check_graph_shape(ports, goods)
    staple_ranking = _check_staple_coverage(ports, staples)
    _check_exclusive_coverage(ports, goods_by_id)
    _check_port_classes(ports)
    _check_hardware_tiers(ports, ships, equipment)
    _check_pirate_drop_pairing(pirates, equipment)
    _check_band_set(ports)

    # §4.19 sub-block: port-facility opening hours.
    check_facility_hours(docs, verbose)

    if verbose:
        print(
            f"PASS group 7 npc & economy data "
            f"({NAMED_PIRATE_COUNT} named pirates (v2 canon cards), "
            f"{len(docs['market_events.json']['market_events'])} event "
            f"templates, absolute_cap {docs['npc_config.json']['absolute_cap']}, "
            f"ai_profiles {len(docs['npc_config.json']['ai_profiles'])} kinds)"
        )
        print(
            f"INFO group 7 consumption tiers — staples: {', '.join(sorted(staples))}; "
            f"middle: {len(middle)} goods; luxuries: {', '.join(sorted(luxuries))}"
        )
        furthest = ", ".join(
            f"{port_id} ({distance} tiles → {producer}/{good})"
            for distance, port_id, producer, good in staple_ranking[:5])
        print(f"INFO group 7 economy graph — 150 ports / {len(goods)} goods; "
              f"furthest staple runs: {furthest}")


# ---------------------------------------------------------------------------
# Check group 8 — Trade routes (docs/10-DATA-SCHEMA.md section 8.3)
# ---------------------------------------------------------------------------

# Section 7.6: the locked 21-lane id set — exhaustive, closed (the 12
# Phase-5 lanes plus the 5 Phase-6 regional lanes of task P).
LOCKED_LANE_IDS = (
    "carreira_da_india",
    "west_indies_flota",
    "manila_galleon",
    "venice_alexandria",
    "venice_flanders",
    "genoa_grain",
    "hanseatic_north",
    "aden_gujarat_malacca",
    "red_sea_india",
    "basra_muscat_india",
    "iceland_cod",
    "grand_banks_cod",
    "canton_country_trade",
    "coromandel_bengal",
    "swahili_coast",
    "pacific_america",
    "west_africa",
    # 2026-11-02 route-network amendment (§7.6): four regional runs recorded
    # there — the North-Atlantic run, the Brazil run, the Brouwer route and
    # the Molucca spice run.
    "atlantic_north",
    "brasil_run",
    "brouwer_route",
    "molucca_run",
)

BUILT_ROUTES_LABEL = "data/trade_routes_built.json"
OVERRIDES_LABEL = "tools/route_overrides.json"
SPOKE_RADIUS = 40  # §4.14 minor-spoke Chebyshev radius (Phase-6 sweep: 20 → 40)


def _check_trade_lane_schema(lanes: list, nation_ids: set, good_ids: set) -> None:
    """§8.3 item 2: class/nations/goods/chokepoints/waypoint shapes."""
    label = "trade_routes.json"
    if len(lanes) != len(LOCKED_LANE_IDS):
        fail(
            "trade-routes",
            label,
            f"expected exactly {len(LOCKED_LANE_IDS)} lanes (section 7.6), "
            f"got {len(lanes)}",
            8,
        )
    for index, lane in enumerate(lanes):
        path = f"lanes[{index}]"
        if not isinstance(lane, dict):
            fail("trade-routes", label, f"{path} is not an object", 8)
        lane_id = lane.get("id")
        if not isinstance(lane_id, str) or not ID_RE.match(lane_id):
            fail("trade-routes", label, f"{path} has no well-formed 'id'", 8)
        where = f"{path} ({lane_id})"
        if lane.get("class") != "major":
            fail(
                "trade-routes",
                label,
                f"{where} class must be \"major\" — minor spokes are "
                "builder-generated and never stored in this file (section "
                "4.14)",
                8,
            )
        nations = lane.get("nations")
        if not isinstance(nations, list) or not nations:
            fail("trade-routes", label, f"{where} needs a non-empty nations array", 8)
        for nation_id in nations:
            if nation_id not in nation_ids:
                fail(
                    "trade-routes",
                    label,
                    f"{where} references unknown nation {nation_id!r}",
                    8,
                )
        goods = lane.get("goods")
        if not isinstance(goods, list) or not goods:
            fail("trade-routes", label, f"{where} needs a non-empty goods array", 8)
        for good_id in goods:
            if good_id not in good_ids:
                fail("trade-routes", label, f"{where} references unknown good {good_id!r}", 8)
        chokepoints = lane.get("chokepoints")
        if not isinstance(chokepoints, list) or not chokepoints:
            fail(
                "trade-routes",
                label,
                f"{where} needs >= 1 chokepoint tag (section 4.14)",
                8,
            )
        for tag in chokepoints:
            if not isinstance(tag, str) or not re.match(r"^[a-z0-9_]+$", tag):
                fail(
                    "trade-routes",
                    label,
                    f"{where} chokepoint tag {tag!r} must be snake_case",
                    8,
                )
        waypoints = lane.get("waypoints")
        if not isinstance(waypoints, list) or len(waypoints) < 2:
            fail(
                "trade-routes",
                label,
                f"{where} needs >= 2 [lat, lon] waypoints (section 4.14)",
                8,
            )
        for w_index, point in enumerate(waypoints):
            if (not isinstance(point, list) or len(point) != 2
                    or not all(isinstance(v, (int, float)) and
                               not isinstance(v, bool) for v in point)):
                fail(
                    "trade-routes",
                    label,
                    f"{where} waypoint {w_index} must be [lat, lon]",
                    8,
                )
            lat, lon = float(point[0]), float(point[1])
            if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
                fail(
                    "trade-routes",
                    label,
                    f"{where} waypoint {w_index} out of range: {point} "
                    "(section 3.1)",
                    8,
                )


def _check_trade_snap_and_segments(grid, lanes: list, lane_index: dict) -> dict:
    """§8.3 items 3-5: snap, passability, wrap continuity (shared helpers).

    Variant waypoints join the snap and unmasked-walk checks (§4.14: each
    variant's `waypoints` is a waypoint list like the base's); the in-month
    ice-mask walk is group 10's (§8.5) so its violations exit 10.
    """
    label = "trade_routes.json"
    stats = {"waypoints": 0, "segments": 0, "max_snap": 0, "at_limit": 0}

    def check_waypoint_set(lane_id: str, lane_pos: int, waypoints, what: str):
        for w_index, point in enumerate(waypoints):
            hit = route_builder.snap_waypoint(grid, float(point[0]),
                                              float(point[1]))
            stats["waypoints"] += 1
            if hit is None:
                px, py = grid.tile_of_latlon(float(point[0]), float(point[1]))
                fail(
                    "trade-routes",
                    label,
                    f"lanes[{lane_pos}] ({lane_id}) {what} waypoint "
                    f"{w_index} ({point[0]}, {point[1]}) has no water tile "
                    f"within {route_builder.WAYPOINT_SNAP_TILES} tiles of "
                    f"({px}, {py}) (section 8.3 item 3; fix via "
                    "tools/route_overrides.json or a reported waypoint "
                    "amendment)",
                    8,
                )
            stats["max_snap"] = max(stats["max_snap"], hit[2])
            if hit[2] == route_builder.WAYPOINT_SNAP_TILES:
                stats["at_limit"] += 1
        for s_index in range(len(waypoints) - 1):
            a = _snapped_of(grid, waypoints[s_index])
            b = _snapped_of(grid, waypoints[s_index + 1])
            # item 5: a dateline-crossing segment keeps per-segment x
            # monotonic under wrap — the shortest wrap step is <= half the
            # grid, i.e. the segment never jumps the seam.
            dx = abs(b[0] - a[0]) % grid.w
            dx = min(dx, grid.w - dx)
            if dx > grid.w / 2.0:
                fail(
                    "trade-routes",
                    label,
                    f"lanes[{lane_pos}] ({lane_id}) {what} segment "
                    f"{s_index} jumps the dateline seam (dx {dx} > "
                    f"{grid.w // 2}; section 8.3 item 5)",
                    8,
                )
            chain, bad = route_builder.walk_segment(grid, a, b)
            stats["segments"] += 1
            if chain is None:
                fail(
                    "trade-routes",
                    label,
                    f"lanes[{lane_pos}] ({lane_id}) {what} segment "
                    f"{s_index} ({a}) -> ({b}) walks onto an impassable "
                    f"tile at {bad} (section 8.3 item 4, corner cutting "
                    "forbidden)",
                    8,
                )

    for lane in lanes:
        lane_id = lane["id"]
        lane_pos = lane_index[lane_id]
        check_waypoint_set(lane_id, lane_pos, lane["waypoints"], "base")
        for variant in lane.get("variants") or []:
            check_waypoint_set(lane_id, lane_pos, variant["waypoints"],
                               f"variant '{variant.get('id')}'")
    return stats


def _snapped_of(grid, waypoint: list):
    """Re-snap one validated waypoint (must succeed; error text unused)."""
    hit = route_builder.snap_waypoint(grid, float(waypoint[0]),
                                      float(waypoint[1]))
    return (hit[0], hit[1])


def _check_trade_spokes(grid, ports: list, nations: list, lanes: list,
                        lane_index: dict, built: dict,
                        overrides: dict) -> dict:
    """§8.3 item 6: the §4.14 spoke rule for every one of the 100 ports."""
    label = BUILT_ROUTES_LABEL
    spokes = built.get("spokes")
    if not isinstance(spokes, list):
        fail("trade-spokes", label, "built artifact has no 'spokes' array", 8)

    # Lane waypoints snapped exactly as the builder snapped them.
    snapped_by_lane: dict[str, list] = {}
    for lane in lanes:
        snapped_by_lane[lane["id"]] = [
            _snapped_of(grid, point) for point in lane["waypoints"]
        ]
    lane_order = [lane["id"] for lane in lanes]
    capital_of = {nation["id"]: nation["capital_port_id"] for nation in nations}
    harbors = {}
    for port in ports:
        snapped = route_builder.bw.snap_harbor_with_shore(
            grid, float(port["lat"]), float(port["lon"]))
        harbors[port["id"]] = (snapped[0], snapped[1])

    by_port: dict[str, dict] = {}
    for index, spoke in enumerate(spokes):
        path = f"spokes[{index}]"
        if not isinstance(spoke, dict):
            fail("trade-spokes", label, f"{path} is not an object", 8)
        port_id = spoke.get("port")
        if port_id not in harbors:
            fail("trade-spokes", label, f"{path} names unknown port {port_id!r}", 8)
        if port_id in by_port:
            fail(
                "trade-spokes",
                label,
                f"{path} ({port_id}) — a second spoke for one port (§4.14: "
                "exactly one per port)",
                8,
            )
        by_port[port_id] = spoke
        tile_path = spoke.get("tile_path")
        if not isinstance(tile_path, list) or not tile_path:
            fail("trade-spokes", label, f"{path} ({port_id}) has no tile_path", 8)
        for t_index, tile in enumerate(tile_path):
            if (not isinstance(tile, list) or len(tile) != 2
                    or not is_int(tile[0]) or not is_int(tile[1])):
                fail(
                    "trade-spokes",
                    label,
                    f"{path} ({port_id}) tile_path[{t_index}] must be [x, y]",
                    8,
                )
            x, y = tile
            if not (0 <= x < grid.w and 0 <= y < grid.h):
                fail(
                    "trade-spokes",
                    label,
                    f"{path} ({port_id}) tile_path[{t_index}] ({x}, {y}) is "
                    "outside the grid",
                    8,
                )
            if not grid.is_water(x, y):
                fail(
                    "trade-spokes",
                    label,
                    f"{path} ({port_id}) tile_path[{t_index}] ({x}, {y}) is "
                    f"impassable ({grid.rows[y][x]} on the raster)",
                    8,
                )

    kinds = {"lane": 0, "capital": 0, "override": 0, "fallback": 0,
             "completion": 0}
    for port in ports:
        port_id = port["id"]
        spoke = by_port.get(port_id)
        if spoke is None:
            fail(
                "trade-spokes",
                label,
                f"port '{port_id}' has no spoke in the built artifact "
                "(section 8.3 item 6)",
                8,
            )
        harbor = harbors[port_id]
        kind = spoke.get("kind")
        path = spoke.get("tile_path") or []
        chain_tiles = [(tile[0], tile[1]) for tile in path]
        if chain_tiles[0] != harbor:
            fail(
                "trade-spokes",
                label,
                f"port '{port_id}' spoke starts at {chain_tiles[0]} but its "
                f"§6.1 harbor tile is {harbor}",
                8,
            )
        # Walk-aware rule 1, recomputed: the first in-radius candidate whose
        # straight walk succeeds (§4.14 pin) — every kind's legality keys on
        # it.
        candidates = route_builder.lane_waypoint_candidates(
            grid, harbor, snapped_by_lane, lane_order)
        resolved = route_builder.first_walkable_waypoint(
            grid, harbor, candidates, snapped_by_lane)
        if kind == "lane":
            kinds["lane"] += 1
            if resolved is None:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' claims a lane spoke but no in-radius "
                    f"lane waypoint's straight walk succeeds (§4.14 "
                    "walk-aware rule 1)",
                    8,
                )
            lane_id, wp_index, tile, distance = (
                resolved[0], resolved[1], resolved[2], resolved[3])
            if (spoke.get("lane") != lane_id
                    or spoke.get("waypoint_index") != wp_index
                    or spoke.get("distance") != distance
                    or chain_tiles[-1] != tile):
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' lane spoke "
                    f"({spoke.get('lane')} #{spoke.get('waypoint_index')} "
                    f"d={spoke.get('distance')}) does not match the §4.14 "
                    f"walk-aware rule ('{lane_id}' #{wp_index} d={distance}, "
                    f"tile {tile}; ties smallest (y, x), walk-failed "
                    "candidates skipped)",
                    8,
                )
            chain, bad = route_builder.walk_segment(grid, harbor, tile)
            if chain is None or [(x, y) for x, y in chain] != chain_tiles:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' lane spoke tile_path does not match "
                    f"the straight §4.14 walk to {tile} (first bad tile: "
                    f"{bad})",
                    8,
                )
        elif kind == "capital":
            kinds["capital"] += 1
            if resolved is not None:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' claims a capital fallback but the "
                    f"walk-aware lane rule succeeds (lane waypoint "
                    f"'{resolved[0]}' #{resolved[1]}, d={resolved[3]}) — the "
                    "lane rule takes precedence (§4.14)",
                    8,
                )
            capital_id = capital_of[port["nation_id"]]
            if spoke.get("capital") != capital_id:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' capital spoke names "
                    f"{spoke.get('capital')!r}, not its national capital "
                    f"'{capital_id}'",
                    8,
                )
            capital_tile = harbors[capital_id]
            chain, bad = route_builder.walk_segment(grid, harbor, capital_tile)
            if chain is None or [(x, y) for x, y in chain] != chain_tiles:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' capital spoke tile_path does not "
                    f"match the direct walk to '{capital_id}' {capital_tile} "
                    f"(first bad tile: {bad})",
                    8,
                )
        elif kind == "override":
            kinds["override"] += 1
            if resolved is not None:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}': superseded override — the walk-aware "
                    f"lane rule succeeds (lane waypoint '{resolved[0]}' "
                    f"#{resolved[1]}, d={resolved[3]}), so the "
                    f"{OVERRIDES_LABEL} entry must be removed (§4.14)",
                    8,
                )
            entry = overrides.get(port_id)
            if entry is None:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' has an override spoke but no entry in "
                    f"{OVERRIDES_LABEL}",
                    8,
                )
            connect_lane = entry["connect"]["lane"]
            wp_index = entry["connect"]["waypoint_index"]
            connect_tile = snapped_by_lane[connect_lane][wp_index]
            if spoke.get("connect") != {"lane": connect_lane,
                                        "waypoint_index": wp_index}:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' override spoke connect "
                    f"{spoke.get('connect')!r} does not match the declared "
                    f"{entry['connect']!r}",
                    8,
                )
            if chain_tiles[-1] != connect_tile:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' override spoke ends at "
                    f"{chain_tiles[-1]}, not the declared connect tile "
                    f"{list(connect_tile)} ({connect_lane} #{wp_index})",
                    8,
                )
        elif kind == "fallback":
            # §4.14 nationless fallback: a neutral port with no walkable
            # in-radius candidate and no override takes the nearest lane
            # waypoint unbounded, A*-pathfound.
            kinds["fallback"] += 1
            if port["nation_id"] != NEUTRAL_PORT_NATION_ID:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' claims a nationless fallback but is "
                    "not a neutral-tier port (§4.14)",
                    8,
                )
            if resolved is not None:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' claims a nationless fallback but the "
                    f"walk-aware lane rule succeeds ('{resolved[0]}' "
                    f"#{resolved[1]}) — §4.14 order violated",
                    8,
                )
            if overrides.get(port_id) is not None:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' claims a nationless fallback but an "
                    f"{OVERRIDES_LABEL} entry is declared — the override "
                    "takes precedence (§4.14)",
                    8,
                )
            nearest = None
            for rank, lane_id in enumerate(lane_order):
                for index, (x, y) in enumerate(snapped_by_lane[lane_id]):
                    distance = route_builder.chebyshev_wrap_tiles(
                        grid, harbor, (x, y))
                    key = (distance, y, x, rank, index)
                    if nearest is None or key < nearest[0]:
                        nearest = (key, lane_id, index, (x, y), distance)
            if nearest is None:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' nationless fallback: the lane "
                    "network has no waypoint at all",
                    8,
                )
            _key, lane_id, index, tile, distance = nearest
            if (spoke.get("lane") != lane_id
                    or spoke.get("waypoint_index") != index
                    or chain_tiles[-1] != tile):
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' nationless fallback does not end at "
                    f"the nearest lane waypoint '{lane_id}' #{index} {tile} "
                    "(§4.14)",
                    8,
                )
            astar = route_builder.astar_path(grid, harbor, tile)
            if (astar is None
                    or [(x, y) for x, y in astar] != chain_tiles):
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' nationless fallback tile_path is not "
                    f"the A* water path from {harbor} to {tile} (§4.14)",
                    8,
                )
        elif kind == "completion":
            # §4.14 rule 5 (2026-11-06): the connectivity-completion spoke.
            # Legal even when rule 1 succeeds — that is its purpose (the
            # strict coast cleanup re-opened walks and moved bridge spokes).
            # Must end at the named lane waypoint over the A* water path,
            # carry no override entry, and be LOAD-BEARING: without it the
            # junction graph is disconnected (a completion spoke that the
            # graph does not need is a §4.14 rule violation).
            kinds["completion"] += 1
            if overrides.get(port_id) is not None:
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' has a completion spoke but an "
                    f"{OVERRIDES_LABEL} entry is declared — the override "
                    "takes precedence (§4.14)",
                    8,
                )
            lane_id = spoke.get("lane")
            wp_index = spoke.get("waypoint_index")
            if (not isinstance(lane_id, str)
                    or lane_id not in snapped_by_lane
                    or not isinstance(wp_index, int)
                    or not (0 <= wp_index < len(snapped_by_lane[lane_id]))):
                fail(
                    "trade-spokes",
                    label,
                    f"port '{port_id}' completion spoke names an unknown "
                    f"lane waypoint ({lane_id!r} #{wp_index!r})",
                    8,
                )
            else:
                tile = tuple(snapped_by_lane[lane_id][wp_index])
                if chain_tiles[-1] != tile:
                    fail(
                        "trade-spokes",
                        label,
                        f"port '{port_id}' completion spoke ends at "
                        f"{chain_tiles[-1]}, not the named lane waypoint "
                        f"{tile} ({lane_id} #{wp_index})",
                        8,
                    )
                astar = route_builder.astar_path(grid, harbor, tile)
                if astar is None or [(x, y) for x, y in astar] != chain_tiles:
                    fail(
                        "trade-spokes",
                        label,
                        f"port '{port_id}' completion spoke tile_path is "
                        f"not the A* water path from {harbor} to {tile} "
                        "(§4.14 rule 5)",
                        8,
                    )
                # load-bearing: rebuild the graph WITHOUT this spoke; the
                # harbor and the target waypoint must land in different
                # components (otherwise rule 1 already connects the port
                # and a completion spoke is spurious).
                paths_wo: dict = {}
                for lane_entry in built.get("lanes", []):
                    paths_wo[f"lane:{lane_entry['id']}"] = [
                        (t[0], t[1]) for t in lane_entry["tile_path"]]
                for other in built.get("spokes", []):
                    if other["port"] != port_id:
                        paths_wo[f"spoke:{other['port']}"] = [
                            (t[0], t[1]) for t in other["tile_path"]]
                nodes2, edges2, t2n = route_builder.build_junction_graph(
                    paths_wo)
                if tuple(harbor) in t2n and tile in t2n:
                    adj2 = route_builder.graph_adjacency(edges2)
                    seen2 = route_builder.reachable_from(
                        adj2, t2n[tuple(harbor)])
                    if t2n[tile] in seen2:
                        fail(
                            "trade-spokes",
                            label,
                            f"port '{port_id}' completion spoke is not "
                            "load-bearing — the graph is already connected "
                            "without it (§4.14 rule 5 fires only on a "
                            "detached component)",
                            8,
                        )
        else:
            fail(
                "trade-spokes",
                label,
                f"port '{port_id}' spoke kind {kind!r} is not lane/capital/"
                "override/fallback/completion",
                8,
            )

    stale = sorted(set(by_port) - {port["id"] for port in ports})
    if stale:
        fail(
            "trade-spokes",
            label,
            f"built artifact lists {len(stale)} spoke port(s) missing from "
            f"ports.json: {', '.join(stale)} — regenerate with "
            "tools/build_routes.py",
            8,
        )
    return {
        "count": len(spokes),
        "kinds": kinds,
    }


def _check_trade_probes(grid, ports: list, built: dict) -> None:
    """§8.3 item 7: the named probes over the built junction graph."""
    junctions = built.get("junctions")
    if not isinstance(junctions, dict):
        fail(
            "trade-probes",
            BUILT_ROUTES_LABEL,
            "built artifact has no 'junctions' object",
            8,
        )
    nodes = junctions.get("nodes")
    edges = junctions.get("edges")
    if not isinstance(nodes, list) or not isinstance(edges, list):
        fail(
            "trade-probes",
            BUILT_ROUTES_LABEL,
            "junctions needs 'nodes' and 'edges' arrays",
            8,
        )
    node_tiles: dict[tuple[int, int], int] = {}
    for index, tile in enumerate(nodes):
        if (not isinstance(tile, list) or len(tile) != 2
                or not is_int(tile[0]) or not is_int(tile[1])):
            fail(
                "trade-probes",
                BUILT_ROUTES_LABEL,
                f"junctions.nodes[{index}] must be [x, y]",
                8,
            )
        node_tiles[(tile[0], tile[1])] = index
    adj = route_builder.graph_adjacency(edges)

    harbor_of = {}
    for port in ports:
        snapped = route_builder.bw.snap_harbor_with_shore(
            grid, float(port["lat"]), float(port["lon"]))
        harbor_of[port["id"]] = (snapped[0], snapped[1])

    def node_of(tile: tuple[int, int], what: str) -> int:
        index = node_tiles.get(tile)
        if index is None:
            fail(
                "trade-probes",
                BUILT_ROUTES_LABEL,
                f"{what} tile {list(tile)} is not a junction-graph node — "
                "path endpoints must all be nodes",
                8,
            )
        return index

    graph_probes = (
        ("port:acapulco", "port:manila",
         "acapulco <-> manila across the dateline wrap"),
        ("port:danzig", "lane:hanseatic_north",
         "hanseatic_north reaches danzig (base months)"),
        ("port:goa", "lane:carreira_da_india",
         "carreira_da_india reaches goa"),
        ("port:macau", "port:hirado",
         "macau <-> hirado joined via canton_country_trade"),
    )
    for source, target, description in graph_probes:
        source_tile = (harbor_of[source[5:]] if source.startswith("port:")
                       else _built_lane_start(built, source[5:]))
        target_tile = (harbor_of[target[5:]] if target.startswith("port:")
                       else _built_lane_start(built, target[5:]))
        start = node_of(source_tile, f"probe source {source}")
        goal = node_of(target_tile, f"probe target {target}")
        reached = route_builder.reachable_from(adj, start)
        if goal not in reached:
            fail(
                "trade-probes",
                BUILT_ROUTES_LABEL,
                f"probe failed: {description} — no path over the built "
                f"junction graph between node {start} and node {goal} "
                "(section 8.3 item 7)",
                8,
            )

    # The W3 gate's E-probes (IMPLEMENT-Phase6 task E done-when): spoke
    # records over the merged P lane content.
    spoke_by_port = {
        spoke.get("port"): spoke
        for spoke in built.get("spokes", []) if isinstance(spoke, dict)
    }

    def spoke_onto(port_id: str, lane_id: str, max_distance=None,
                   description: str = "") -> None:
        record = spoke_by_port.get(port_id)
        problems = []
        if record is None:
            problems.append("no spoke record")
        else:
            if record.get("kind") != "lane":
                problems.append(f"kind {record.get('kind')!r} is not 'lane'")
            if record.get("lane") != lane_id:
                problems.append(
                    f"lands on lane {record.get('lane')!r}, expected "
                    f"{lane_id!r}")
            if (max_distance is not None
                    and isinstance(record.get("distance"), int)
                    and record["distance"] > max_distance):
                problems.append(
                    f"distance {record['distance']} > {max_distance}")
        if problems:
            fail(
                "trade-probes",
                BUILT_ROUTES_LABEL,
                f"probe failed: {description or port_id} — "
                + "; ".join(problems) + " (section 8.3 item 7)",
                8,
            )

    spoke_onto("busan", "canton_country_trade",
               description="busan's spoke lands on canton_country_trade")
    spoke_onto("mombasa", "swahili_coast", max_distance=SPOKE_RADIUS,
               description="mombasa spoke <= 40 onto swahili_coast")
    for port_id in ("lima", "valparaiso", "guayaquil", "panama"):
        spoke_onto(port_id, "pacific_america",
                   description=f"{port_id} spoke onto pacific_america")
    for port_id in ("safi", "elmina", "luanda"):
        spoke_onto(port_id, "west_africa",
                   description=f"{port_id} spoke onto west_africa")

    # 2026-11-02 route-network amendment: the whole network is ONE component
    # — every lane's start node reaches every other lane's start node over
    # the junction graph (the hanseatic/iceland isolation class is a hard
    # failure, §8.3 item 7).
    lane_starts = []
    for lane in built.get("lanes", []):
        lid = lane.get("id")
        if not lid:
            continue
        start = lane.get("tile_path", [[0, 0]])[0]
        lane_starts.append((lid, (start[0], start[1])))
    adj_probe = route_builder.reachable_from(
        adj, node_of(lane_starts[0][1], "probe source lane:carreira_da_india"))
    for lid, start in lane_starts[1:]:
        node = node_of(start, f"probe source lane:{lid}")
        if node not in adj_probe:
            fail(
                "trade-probes",
                BUILT_ROUTES_LABEL,
                f"lane '{lid}' is not reachable from lane "
                f"'{lane_starts[0][0]}' over the built junction graph — the "
                "network must be a single connected component (section 8.3 "
                "item 7)",
                8,
            )


def _built_lane_start(built: dict, lane_id: str) -> tuple[int, int]:
    for lane in built.get("lanes", []):
        if lane.get("id") == lane_id:
            start = lane["tile_path"][0]
            return (start[0], start[1])
    fail(
        "trade-probes",
        BUILT_ROUTES_LABEL,
        f"built artifact has no lane '{lane_id}'",
        8,
    )


def _check_trade_determinism(verbose: bool) -> None:
    """§8.3 item 8: the committed artifact must rebuild byte-identical.

    With a data-root override (staged-sim protocol) the overridden checkout's
    own builder runs over its own tree when present — the merged sources must
    rebuild byte-identically where they live. The default run uses this
    repo's builder from this repo's root, exactly as before.
    """
    import subprocess

    builder_root = REPO_ROOT
    if DATA_DIR != _default_data_dir():
        staged_tools = DATA_DIR.parent / "tools" / "build_routes.py"
        if staged_tools.is_file():
            builder_root = DATA_DIR.parent
    result = subprocess.run(
        [sys.executable, str(builder_root / "tools" / "build_routes.py"),
         "--check", "--verbose"],
        capture_output=True,
        text=True,
        cwd=builder_root,
    )
    if verbose and result.stderr:
        for line in result.stderr.strip().splitlines():
            print(f"INFO group 8 {line}")
    if result.returncode != 0:
        tail = (result.stderr or result.stdout or "").strip().splitlines()
        detail = tail[-1] if tail else f"exit {result.returncode}"
        fail(
            "trade-determinism",
            BUILT_ROUTES_LABEL,
            f"rebuild drift: {detail} (tools/build_routes.py --check exited "
            f"{result.returncode}; section 8.3 item 8 — fix "
            "data/trade_routes.json or tools/route_overrides.json and "
            "regenerate, never hand-edit the built file)",
            8,
        )


def check_group8(docs: dict[str, object], verbose: bool) -> None:
    """Trade routes: docs/10-DATA-SCHEMA.md section 8.3.

    Runs after group 6 on the same PNG decoder (the builder's reader, per the
    §8.3 preamble). Items 1-5 check the authored lanes, item 6 the built
    spokes, item 7 the named connectivity probes over the built junction
    graph, item 8 the rebuild byte-equality of the tool-owned artifact.
    """
    lanes_doc = docs.get("trade_routes.json")
    if not isinstance(lanes_doc, dict) or not isinstance(
            lanes_doc.get("lanes"), list):
        fail("trade-routes", "trade_routes.json", "missing 'lanes' array", 8)
    lanes = lanes_doc["lanes"]
    built = docs.get(BUILT_ROUTES_LABEL.split("/")[-1])
    if not isinstance(built, dict):
        fail(
            "trade-built",
            BUILT_ROUTES_LABEL,
            "missing (generate with tools/build_routes.py)",
            8,
        )
    for key in ("version", "generated_by", "artifact", "lanes", "spokes",
                "junctions"):
        if key not in built:
            fail(
                "trade-built",
                BUILT_ROUTES_LABEL,
                f"built artifact is missing '{key}' (section 4.14 envelope)",
                8,
            )

    nation_ids = {nation["id"] for nation in docs["nations.json"]["nations"]}
    good_ids = {good["id"] for good in docs["goods.json"]["goods"]}

    # -- item 1: the locked id set ------------------------------------------
    ids = [lane.get("id") for lane in lanes]
    duplicates = sorted({i for i in ids if ids.count(i) > 1})
    if duplicates:
        fail(
            "trade-routes",
            "trade_routes.json",
            f"repeated lane id(s): {', '.join(duplicates)}",
            8,
        )
    missing = [i for i in LOCKED_LANE_IDS if i not in ids]
    extra = sorted(set(ids) - set(LOCKED_LANE_IDS))
    if missing or extra:
        detail = []
        if missing:
            detail.append(f"missing {', '.join(missing)}")
        if extra:
            detail.append(f"unexpected {', '.join(extra)}")
        fail(
            "trade-routes",
            "trade_routes.json",
            "lane id set must be exactly the locked "
            f"{len(LOCKED_LANE_IDS)} (section 7.6): "
            + "; ".join(detail),
            8,
        )

    # -- item 2: lane schema --------------------------------------------------
    _check_trade_lane_schema(lanes, nation_ids, good_ids)
    lane_index = {lane["id"]: i for i, lane in enumerate(lanes)}

    # -- items 3-5: snap, passability, wrap continuity ------------------------
    grid = route_builder.load_world_grid()
    snap_stats = _check_trade_snap_and_segments(grid, lanes, lane_index)

    # -- item 6: the §4.14 spoke rule over the built artifact -----------------
    if not route_builder.OVERRIDES_PATH.is_file():
        fail(
            "trade-spokes",
            OVERRIDES_LABEL,
            "missing (§4.14 hand-fix channel for the lane builder)",
            8,
        )
    try:
        overrides_payload = json.loads(
            route_builder.OVERRIDES_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(
            "trade-spokes",
            OVERRIDES_LABEL,
            f"cannot read overrides: {exc}",
            8,
        )
    overrides = route_builder.load_overrides(
        overrides_payload,
        lanes,
        docs["ports.json"]["ports"],
    )
    spoke_stats = _check_trade_spokes(
        grid, docs["ports.json"]["ports"],
        docs["nations.json"]["nations"], lanes, lane_index, built, overrides)

    # -- item 7: named probes --------------------------------------------------
    _check_trade_probes(grid, docs["ports.json"]["ports"], built)

    # -- item 8: rebuild byte-equality -----------------------------------------
    _check_trade_determinism(verbose)

    if verbose:
        kinds = spoke_stats["kinds"]
        print(
            f"PASS group 8 trade routes ({len(lanes)} lanes / "
            f"{snap_stats['waypoints']} waypoints snapped <= "
            f"{route_builder.WAYPOINT_SNAP_TILES} tiles "
            f"(max {snap_stats['max_snap']}), "
            f"{snap_stats['segments']} lane segments passable and "
            "wrap-continuous, "
            f"{spoke_stats['count']} spokes "
            f"[{kinds['lane']} lane / {kinds['capital']} capital / "
            f"{kinds['override']} override / {kinds['fallback']} fallback], "
            f"{built['junctions']['node_count']} junction nodes, "
            f"{built['junctions']['edge_count']} edges, probes 10/10, "
            "rebuild byte-identical)"
        )


# ---------------------------------------------------------------------------
# Check group 9 — Ocean rasters (docs/10-DATA-SCHEMA.md section 8.4)
# ---------------------------------------------------------------------------

WIND_PNG = DATA_DIR / "maps" / "wind_regions.png"
CURRENTS_PNG = DATA_DIR / "maps" / "currents.png"
WIND_PNG_LABEL = "data/maps/wind_regions.png"
CURRENTS_PNG_LABEL = "data/maps/currents.png"
WIND_JSON_LABEL = "data/wind_regions.json"
CURRENTS_JSON_LABEL = "data/ocean_currents.json"
ICE_JSON_LABEL = "data/ice_regions.json"

# §6.5 encodings.
CURRENT_INDEX_MAX = 24
COMPASS_DIRS = ("N", "NE", "E", "SE", "S", "SW", "W", "NW")

# Fast per-row violation scan: one int AND + popcount per row; the named
# iteration runs only on rows that have a violation.
_LAND_TABLE = bytes(0 if value in PASSABLE_INDICES else 1
                    for value in range(256))
_NONZERO_TABLE = bytes(0 if value == 0 else 1 for value in range(256))


def _ocean_region_count(wind_json_path: Path) -> int:
    try:
        doc = json.loads(wind_json_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail("ocean-raster", WIND_JSON_LABEL, f"cannot read: {exc}", 9)
    regions = doc.get("wind_regions") if isinstance(doc, dict) else None
    if not isinstance(regions, list) or not regions:
        fail(
            "ocean-raster",
            WIND_JSON_LABEL,
            "missing non-empty 'wind_regions' array (section 4.16)",
            9,
        )
    ids = [region.get("id") for region in regions]
    if any(not isinstance(i, str) or not i for i in ids):
        fail(
            "ocean-raster",
            WIND_JSON_LABEL,
            "every region needs a string 'id' (section 4.16)",
            9,
        )
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        fail(
            "ocean-raster",
            WIND_JSON_LABEL,
            f"repeated region id(s): {', '.join(dupes)}",
            9,
        )
    for index, region in enumerate(regions):
        _check_complete_l10n(region.get("name"),
                             f"wind_regions[{index}] ({ids[index]})",
                             WIND_JSON_LABEL)
    return len(regions)


def _ocean_system_corridors(currents_json_path: Path, grid: WorldGrid):
    """Systems of data/ocean_currents.json with their corridor tile sets.

    Used to NAME a violating tile (§8.4 item 4 names the system): the
    corridor geometry is the builder's own (tile stepping + Chebyshev
    dilation, §4.17's pinned corridor-expansion rule), while the violation
    detection itself is PNG-driven and independent of it. Also checks the
    systems' ids and name i18n (section 4.17) while it is here.
    """
    try:
        doc = json.loads(currents_json_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail("ocean-raster", CURRENTS_JSON_LABEL, f"cannot read: {exc}", 9)
    systems = doc.get("ocean_currents") if isinstance(doc, dict) else None
    if not isinstance(systems, list) or not systems:
        fail(
            "ocean-raster",
            CURRENTS_JSON_LABEL,
            "missing non-empty 'ocean_currents' array (section 4.17)",
            9,
        )
    sys.path.insert(0, str(REPO_ROOT / "tools"))
    import build_ocean as ocean_builder  # noqa: E402  (corridor naming only)

    tpd_grid = bw_grid_like(grid)
    corridors = []
    ids = []
    for index, system in enumerate(systems):
        system_id = system.get("id")
        where = f"ocean_currents[{index}] ({system_id!r})"
        if not isinstance(system_id, str) or not system_id:
            fail("ocean-raster", CURRENTS_JSON_LABEL,
                 f"{where}: missing string 'id' (section 4.17)", 9)
        _check_complete_l10n(system.get("name"), where, CURRENTS_JSON_LABEL)
        path = system.get("path")
        width = system.get("width_tiles")
        if (not isinstance(path, list) or len(path) < 2
                or not isinstance(width, int) or isinstance(width, bool)
                or width <= 0):
            fail(
                "ocean-raster",
                CURRENTS_JSON_LABEL,
                f"{where}: needs a >= 2-point path and an int width_tiles > 0 "
                "(section 4.17)",
                9,
            )
        ids.append(system_id)
        corridors.append((system_id, ocean_builder.corridor_tiles(
            tpd_grid, [(float(p[0]), float(p[1])) for p in path], width)))
    return ids, corridors, ocean_builder


def bw_grid_like(grid: WorldGrid):
    """A build_world.Grid over the same raster (for the corridor geometry)."""
    import build_world as bw  # local import: group 9's naming aid

    g = bw.Grid(grid.width, grid.height)
    for y in range(grid.height):
        g.rows[y][:] = grid.indices[y * grid.width:(y + 1) * grid.width]
    return g


def _check_ocean_raster(label: str, png_path: Path, world: WorldGrid,
                        index_max: int, name_of_index,
                        system_namer=None) -> int:
    """Decode + palette bounds + water coverage for one ocean raster.

    ``index_max`` is the inclusive palette bound (region_count for wind,
    24 for currents); ``name_of_index`` renders an index for messages;
    ``system_namer(tile)`` names the current system(s) of a violating tile
    (currents only). Returns the number of non-zero tiles (informational).
    """
    if not png_path.is_file():
        fail("ocean-raster", label, "missing (generate with "
             "tools/build_ocean.py)", 9)
    try:
        data = png_path.read_bytes()
        width, height, indices = decode_indexed_png(data)
    except PngFormatError as exc:
        fail(
            "ocean-raster",
            label,
            f"artifact decode failed: {exc} (section 8.4 item 1)",
            9,
        )
    if (width, height) != (MAP_WIDTH, MAP_HEIGHT):
        fail(
            "ocean-raster",
            label,
            f"must be exactly {MAP_WIDTH}x{MAP_HEIGHT}, got {width}x{height} "
            "(section 8.4 item 1)",
            9,
        )

    # item 2/3: palette bounds over the indices actually used.
    used = sorted(set(indices))
    too_high = [value for value in used if value > index_max]
    if too_high:
        fail(
            "ocean-raster",
            label,
            f"palette bound: index {min(too_high)} used but the §6.5 "
            f"encoding allows only 0..{index_max} "
            f"({'region count' if system_namer is None else '8 dirs x 3 strengths'})"
            " (section 8.4 item 2/3)",
            9,
        )

    # item 4: water coverage — a non-zero index on a land/reef/ice tile of
    # world.png names the tile and the region/system.
    violations = 0
    w, h = MAP_WIDTH, MAP_HEIGHT
    for y in range(h):
        land = int.from_bytes(
            world.indices[y * w:(y + 1) * w].translate(_LAND_TABLE), "big")
        nonzero = int.from_bytes(
            indices[y * w:(y + 1) * w].translate(_NONZERO_TABLE), "big")
        bad = land & nonzero
        if not bad:
            continue
        for x in range(w):
            index = indices[y * w + x]
            if index and not world.passable[y * w + x]:
                if system_namer is not None:
                    who = system_namer((x, y), index)
                else:
                    who = name_of_index(index)
                fail(
                    "ocean-raster",
                    label,
                    f"tile ({x}, {y}) is "
                    f"'{world.char_at(y * w + x)}' on world.png but carries "
                    f"{label.split('/')[-1]} index {index} ({who}) — a "
                    "non-zero index never lands on land/reef/permanent ice "
                    "(section 8.4 item 4)",
                    9,
                )
        violations += bin(bad).count("1")
    painted = sum(1 for value in indices if value)
    if verbose_enabled():
        print(
            f"PASS ocean-raster {label}: {painted} non-zero tiles "
            f"({violations} on land — impossible if this line prints), "
            f"indices 0..{max(used) if used else 0} <= {index_max}"
        )
    return painted


_verbose_flag = False


def verbose_enabled() -> bool:
    return _verbose_flag


def _check_ocean_determinism(verbose: bool) -> None:
    """§8.4 item 5: both committed rasters rebuild byte-identical."""
    import subprocess

    result = subprocess.run(
        [sys.executable, str(REPO_ROOT / "tools" / "build_ocean.py"),
         "--check", "--verbose"],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    if verbose and result.stderr:
        for line in result.stderr.strip().splitlines():
            print(f"INFO group 9 {line}")
    if result.returncode != 0:
        tail = (result.stderr or result.stdout or "").strip().splitlines()
        detail = tail[-1] if tail else f"exit {result.returncode}"
        fail(
            "ocean-determinism",
            "data/maps/{wind_regions,currents}.png",
            f"rebuild drift: {detail} (tools/build_ocean.py --check exited "
            f"{result.returncode}; section 8.4 item 5 — fix the JSON sources "
            "and regenerate, never hand-edit the rasters)",
            9,
        )


def _check_dist_raster(world: WorldGrid) -> int:
    """§6.7 audit of ``data/maps/dist_land.png`` (the 80-* §4.8 2026-11-06
    pixel-depth amendment's factor source): the raster decodes as an RGB8
    4320×2160 PNG whose R/G pair carries ``round(min(d,16)/16*65535)``;
    land pixels are exactly 0 (a land tile's nearest land is itself);
    nothing exceeds the saturation encode; and a deterministic probe
    sample (every 9157th raster pixel) matches the true Euclidean
    distance to land within the encode precision. The full byte-identical
    double-run stays a manual/acceptance gate (``tools/build_distance_field.py
    --check``) — re-running the whole EDT per validation pass would be the
    expensive-re-derivation the working agreements forbid."""
    path = DATA_DIR / "maps" / "dist_land.png"
    if not path.is_file():
        print("INFO group 9 data/maps/dist_land.png not present — the "
              "§6.7 distance raster is staged (80-* §4.8 2026-11-06)")
        return 0
    width = world.width
    height = world.height
    indices = world.indices
    rgb = _decode_rgb_png(path.read_bytes(), width, height)

    sat_enc = int(round(16.0 / 16.0 * 65535))
    probes = 0
    stride = 9157
    rad = 18
    for n in range(width * height):
        if n % stride:
            continue
        x = n % width
        y = n // width
        enc = (rgb[n * 3] << 8) | rgb[n * 3 + 1]
        if enc > sat_enc:
            fail("dist-bounds", "data/maps/dist_land.png",
                 f"pixel ({x}, {y}) decodes {enc} > saturation "
                 f"{sat_enc} (§6.7 encode)", 9)
        # true Euclidean distance via a bounded window scan (the
        # saturation radius makes an 18-tile window a complete one)
        d2 = None
        for ly in range(max(0, y - rad), min(height, y + rad + 1)):
            dy = ly - y
            row_base = ly * width
            for lx in range(max(0, x - rad), min(width, x + rad + 1)):
                if indices[row_base + lx] == 2:
                    dx = lx - x
                    cand = dx * dx + dy * dy
                    if d2 is None or cand < d2:
                        d2 = cand
        true_d = math.sqrt(d2) if d2 is not None else 99.0
        decoded = enc / 4096.0
        expect = min(true_d, 16.0)
        if abs(decoded - expect) > 0.01:
            fail("dist-probe", "data/maps/dist_land.png",
                 f"pixel ({x}, {y}): decoded {decoded:.4f} tiles, true "
                 f"{expect:.4f} (§6.7 sampled probe)", 9)
        if indices[n] == 2 and enc != 0:
            fail("dist-land-zero", "data/maps/dist_land.png",
                 f"land pixel ({x}, {y}) encodes {enc} != 0 (§6.7)", 9)
        probes += 1
    return probes


def _decode_rgb_png(data: bytes, width: int, height: int) -> bytearray:
    """Minimal RGB8 PNG decode to raw bytes (the §6.7 raster contract)."""
    pos = 8
    idat = b""
    w = h = bitdepth = colortype = 0
    while pos < len(data):
        length = int.from_bytes(data[pos:pos + 4], "big")
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            w = int.from_bytes(chunk[0:4], "big")
            h = int.from_bytes(chunk[4:8], "big")
            bitdepth, colortype = chunk[8], chunk[9]
        elif ctype == b"IDAT":
            idat += chunk
        pos += 12 + length
    if (w, h) != (width, height) or colortype != 2 or bitdepth != 8:
        raise ValueError(
            f"dist raster: {w}x{h} colour type {colortype} bit {bitdepth} "
            "!= the §6.7 RGB8 4320x2160 contract")
    raw = zlib.decompress(idat)
    stride = width * 3
    out = bytearray(width * height * 3)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        f = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if f == 1:
            for i in range(3, stride):
                line[i] = (line[i] + line[i - 3]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - 3] if i >= 3 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - 3] if i >= 3 else 0
                b = prev[i]
                c = prev[i - 3] if i >= 3 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return out


def check_group9(docs: dict[str, object], verbose: bool) -> None:
    """Ocean rasters: docs/10-DATA-SCHEMA.md section 8.4."""
    global _verbose_flag
    _verbose_flag = verbose

    region_count = _ocean_region_count(DATA_DIR / "wind_regions.json")
    world = _load_world_grid(WORLD_PNG, WORLD_PNG_LABEL)

    def wind_name(index: int) -> str:
        try:
            doc = json.loads(
                (DATA_DIR / "wind_regions.json").read_text(encoding="utf-8"))
            region = doc["wind_regions"][index - 1]
            return f"wind region {index} '{region['id']}'"
        except (OSError, json.JSONDecodeError, IndexError, KeyError):
            return f"wind region index {index}"

    # Currents naming needs the corridors; computed lazily on first failure.
    cached: dict = {}

    def current_namer(tile, index):
        if "corridors" not in cached:
            _ids, corridors, _builder = _ocean_system_corridors(
                DATA_DIR / "ocean_currents.json", world)
            cached["corridors"] = corridors
        direction = (index - 1) // 3
        strength = ((index - 1) % 3) + 1
        covering = [
            system_id for system_id, corridor in cached["corridors"]
            if tile in corridor
        ]
        decoded = (f"decodes to {COMPASS_DIRS[direction]}/{strength}")
        if covering:
            return f"current system(s) {', '.join(covering)}; {decoded}"
        return f"no re-computed covering system; {decoded}"

    wind_painted = _check_ocean_raster(
        WIND_PNG_LABEL, WIND_PNG, world, region_count, wind_name)
    currents_painted = _check_ocean_raster(
        CURRENTS_PNG_LABEL, CURRENTS_PNG, world, CURRENT_INDEX_MAX,
        lambda index: f"current index {index}", current_namer)

    dist_probes = _check_dist_raster(world)

    _check_ocean_determinism(verbose)

    if verbose:
        print(
            f"PASS group 9 ocean rasters (wind {wind_painted} painted tiles "
            f"over {region_count} regions, currents {currents_painted} "
            "painted tiles, palette bounds ok, water coverage ok, rebuild "
            "byte-identical)"
        )
        print(
            f"PASS group 9 dist raster (data/maps/dist_land.png: decode, "
            f"bounds, land-zero, {dist_probes} sampled Euclidean probes "
            "ok — the full byte-identical rebuild is "
            "tools/build_distance_field.py --check)"
        )


# ---------------------------------------------------------------------------
# Group 9 mutation harness (`--self-test-g9`)
# ---------------------------------------------------------------------------


def run_group9_self_test() -> int:
    """Negative harness for group 9: every case must fail with exit code 9."""
    global _verbose_flag
    _verbose_flag = False
    results: list[bool] = []
    world = _load_world_grid(WORLD_PNG, WORLD_PNG_LABEL)
    region_count = _ocean_region_count(DATA_DIR / "wind_regions.json")
    wind_bytes = WIND_PNG.read_bytes()
    currents_bytes = CURRENTS_PNG.read_bytes()

    def expect_failure(case: str, needle: str, action) -> bool:
        try:
            action()
        except CheckFailure as exc:
            haystack = f"{exc.filename} {exc.details}".lower()
            if exc.code != 9:
                print(
                    f"FAIL g9-self-test {case}: expected exit 9 but group 9 "
                    f"raised exit {exc.code}: {exc.details}"
                )
                return False
            if needle.lower() not in haystack:
                print(
                    f"FAIL g9-self-test {case}: failure does not name "
                    f"{needle!r}: {exc.filename} {exc.details}"
                )
                return False
            print(f"PASS g9 negative {case}: {exc.filename} {exc.details}")
            return True
        except Exception as exc:  # a crash is not a check failure
            print(f"FAIL g9-self-test {case}: unexpected "
                  f"{type(exc).__name__}: {exc}")
            return False
        print(f"FAIL g9-self-test {case}: group 9 stayed green; the mutation "
              "was not detected")
        return False

    def check_wind(path: Path):
        _check_ocean_raster(WIND_PNG_LABEL, path, world, region_count,
                            lambda index: f"wind region index {index}")

    def check_currents(path: Path):
        _check_ocean_raster(
            CURRENTS_PNG_LABEL, path, world, CURRENT_INDEX_MAX,
            lambda index: f"current index {index}",
            lambda tile, index: f"current index {index}")

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)

        # Baseline: the committed rasters are green (otherwise a negative
        # could pass for the wrong reason).
        try:
            check_wind(WIND_PNG)
            check_currents(CURRENTS_PNG)
            print("PASS g9 baseline: the committed ocean rasters validate "
                  "green")
            results.append(True)
        except CheckFailure as exc:
            print(f"FAIL g9-self-test baseline: real data is already red: "
                  f"{exc.details}")
            results.append(False)

        # (1) a wind pixel moved onto land: coverage failure naming the tile
        # and the region. Central Asia is '#' far from every coastline and
        # below the permanent ice band.
        _w, _h, indices = decode_indexed_png(wind_bytes)
        land_tile = None
        for y in range(300, 900):
            for x in range(1800, 2400):
                if not world.passable[y * MAP_WIDTH + x]:
                    land_tile = (x, y)
                    break
            if land_tile:
                break
        assert land_tile is not None
        mutated = bytearray(indices)
        mutated[land_tile[1] * MAP_WIDTH + land_tile[0]] = 1
        wind_on_land = _encode_indexed_png(MAP_WIDTH, MAP_HEIGHT, mutated,
                                           region_count + 1)
        path = tmpdir / "wind_on_land.png"
        path.write_bytes(wind_on_land)
        results.append(expect_failure(
            "wind-pixel-on-land", f"({land_tile[0]}, {land_tile[1]})",
            lambda: check_wind(path)))

        # (2) an out-of-range wind index (region_count + 1) on open water.
        water_tile = None
        for y in range(900, 1200):
            for x in range(3600, 4200):
                if world.passable[y * MAP_WIDTH + x]:
                    water_tile = (x, y)
                    break
            if water_tile:
                break
        assert water_tile is not None
        mutated = bytearray(indices)
        mutated[water_tile[1] * MAP_WIDTH + water_tile[0]] = region_count + 1
        wind_out_of_range = _encode_indexed_png(MAP_WIDTH, MAP_HEIGHT,
                                                mutated, region_count + 2)
        path = tmpdir / "wind_out_of_range.png"
        path.write_bytes(wind_out_of_range)
        results.append(expect_failure(
            "wind-index-out-of-range", "palette bound",
            lambda: check_wind(path)))

        # (2b) the same for currents: index 25 above the 24 encoding.
        _cw, _ch, cindices = decode_indexed_png(currents_bytes)
        mutated = bytearray(cindices)
        mutated[water_tile[1] * MAP_WIDTH + water_tile[0]] = 25
        currents_out_of_range = _encode_indexed_png(
            MAP_WIDTH, MAP_HEIGHT, mutated, 26)
        path = tmpdir / "currents_out_of_range.png"
        path.write_bytes(currents_out_of_range)
        results.append(expect_failure(
            "current-index-out-of-range", "palette bound",
            lambda: check_currents(path)))

        # (3) a corrupted size: the IDAT no longer matches 4320x2160.
        corrupted = _encode_indexed_png(MAP_WIDTH - 1, MAP_HEIGHT,
                                        indices[:MAP_WIDTH * MAP_HEIGHT],
                                        region_count + 1)
        path = tmpdir / "wind_wrong_size.png"
        path.write_bytes(corrupted)
        results.append(expect_failure(
            "corrupted-size", "exactly 4320x2160",
            lambda: check_wind(path)))

        # (3b) a non-indexed PNG (colour type flipped to 2 = truecolour, IHDR
        # CRC recomputed so the decoder reaches the colour-type check).
        def chunk_bytes(tag: bytes, payload: bytes) -> bytes:
            return (struct.pack(">I", len(payload)) + tag + payload
                    + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

        ihdr_payload = wind_bytes[16:29]
        broken = (wind_bytes[:8]
                  + chunk_bytes(b"IHDR",
                                ihdr_payload[:9] + b"\x02"
                                + ihdr_payload[10:])
                  + wind_bytes[33:])
        path = tmpdir / "wind_not_indexed.png"
        path.write_bytes(bytes(broken))
        results.append(expect_failure(
            "non-indexed-png", "indexed", lambda: check_wind(path)))

    # (4) a committed raster that differs from the rebuild by one byte: the
    # determinism check must exit 9 (via build_ocean --check exit 3). The
    # committed file is restored in a finally block and verified.
    flipped = bytearray(currents_bytes)
    mid = len(flipped) // 2
    flipped[mid] ^= 0xFF
    restored_ok = False
    try:
        CURRENTS_PNG.write_bytes(bytes(flipped))
        try:
            _check_ocean_determinism(False)
            print("FAIL g9-self-test one-byte-drift: the determinism check "
                  "stayed green over a one-byte mutation")
            results.append(False)
        except CheckFailure as exc:
            if exc.code != 9 or "rebuild drift" not in exc.details:
                print(f"FAIL g9-self-test one-byte-drift: unexpected failure "
                      f"(exit {exc.code}): {exc.details}")
                results.append(False)
            else:
                print(f"PASS g9 negative one-byte-drift: {exc.filename} "
                      f"{exc.details}")
                results.append(True)
    finally:
        CURRENTS_PNG.write_bytes(currents_bytes)
        restored_ok = CURRENTS_PNG.read_bytes() == currents_bytes
    if not restored_ok:
        print("FAIL g9-self-test one-byte-drift: the committed raster was "
              "not restored byte-exactly")
        results.append(False)

    if all(results):
        print(f"OK g9 self-test: all {len(results)} cases behaved as required")
        return 0
    return 1


# ---------------------------------------------------------------------------
# Check group 10 — Ice & lane variants (docs/10-DATA-SCHEMA.md section 8.5)
# ---------------------------------------------------------------------------

ICE_MONTH_MIN = 1
ICE_MONTH_MAX = 12


def _check_ice_structure(ice_doc: object) -> list[dict]:
    """§8.5 item 1: ice_regions.json structure; returns the parsed regions."""
    label = ICE_JSON_LABEL
    regions = ice_doc.get("ice_regions") if isinstance(ice_doc, dict) else None
    if not isinstance(regions, list) or not regions:
        fail("ice", label, "missing non-empty 'ice_regions' array (section 4.18)",
             10)
    ids = []
    parsed = []
    for index, region in enumerate(regions):
        where = f"ice_regions[{index}]"
        if not isinstance(region, dict):
            fail("ice", label, f"{where} is not an object", 10)
        region_id = region.get("id")
        if not isinstance(region_id, str) or not region_id:
            fail("ice", label, f"{where}: missing string 'id'", 10)
        ids.append(region_id)
        _check_complete_l10n(region.get("name"),
                             f"{where} ({region_id})", label)
        polygon = region.get("polygon")
        if not isinstance(polygon, list) or len(polygon) < 3:
            fail(
                "ice",
                label,
                f"{where} ({region_id}): polygon needs >= 3 [lat, lon] "
                "vertices (section 4.18)",
                10,
            )
        if polygon[0] != polygon[-1]:
            fail(
                "ice",
                label,
                f"{where} ({region_id}): polygon is not a closed ring — the "
                "first pair must repeat as the last (section 4.18)",
                10,
            )
        ring = []
        for v_index, pair in enumerate(polygon):
            if (not isinstance(pair, list) or len(pair) != 2
                    or not all(isinstance(v, (int, float))
                               and not isinstance(v, bool) for v in pair)):
                fail(
                    "ice",
                    label,
                    f"{where} ({region_id}) vertex {v_index} must be "
                    "[lat, lon]",
                    10,
                )
            lat, lon = float(pair[0]), float(pair[1])
            if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
                fail(
                    "ice",
                    label,
                    f"{where} ({region_id}) vertex {v_index} out of range: "
                    f"{pair} (section 3.1)",
                    10,
                )
            ring.append((lon, lat))
        months = region.get("months")
        if (not isinstance(months, list) or not months
                or not all(isinstance(m, int) and not isinstance(m, bool)
                           and ICE_MONTH_MIN <= m <= ICE_MONTH_MAX
                           for m in months)):
            fail(
                "ice",
                label,
                f"{where} ({region_id}): months must be a non-empty list of "
                f"ints {ICE_MONTH_MIN}-{ICE_MONTH_MAX} (section 4.18)",
                10,
            )
        if len(set(months)) != len(months):
            fail(
                "ice",
                label,
                f"{where} ({region_id}): months repeats a month",
                10,
            )
        parsed.append({"id": region_id, "months": list(months),
                       "ring": ring})
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        fail("ice", label, f"repeated ice region id(s): {', '.join(dupes)}",
             10)
    return parsed


def _ice_masks_for(grid, parsed_regions: list[dict]) -> dict[int, frozenset]:
    """Month -> impassable water tiles, from the parsed ice regions.

    Same membership primitive as the builder (``build_world.fill_ring`` at
    tile centres via ``build_routes._ring_water_tiles``), so builder and
    validator can never disagree about which water is frozen.
    """
    masks: dict[int, set] = {month: set() for month in range(1, 13)}
    for region in parsed_regions:
        tiles = route_builder._ring_water_tiles(grid, region["ring"])
        for month in region["months"]:
            masks[month] |= tiles
    return {month: frozenset(tiles) for month, tiles in masks.items()}


def _check_lane_variant_structure(lanes: list) -> dict[str, list[dict]]:
    """§8.5 item 2: variant ids/months/waypoints; returns the parsed variants.

    Pairwise-disjoint `months` + base coverage of the complement means a
    lane's months are total across base + variants by construction.
    """
    label = "trade_routes.json"
    parsed: dict[str, list[dict]] = {}
    for lane in lanes:
        lane_id = lane["id"]
        raw = lane.get("variants") or []
        if not raw:
            continue
        if not isinstance(raw, list):
            fail("ice-variants", label,
                 f"lane '{lane_id}': variants must be an array", 10)
        seen_ids: set[str] = set()
        seen_months: set[int] = set()
        out: list[dict] = []
        for v_index, variant in enumerate(raw):
            where = f"lanes[{lane_id}] variants[{v_index}]"
            if not isinstance(variant, dict):
                fail("ice-variants", label, f"{where} is not an object", 10)
            variant_id = variant.get("id")
            if not isinstance(variant_id, str) or not variant_id:
                fail("ice-variants", label, f"{where}: missing string 'id'",
                     10)
            if variant_id in seen_ids:
                fail(
                    "ice-variants",
                    label,
                    f"lane '{lane_id}': repeated variant id '{variant_id}' "
                    "(section 8.5 item 2)",
                    10,
                )
            seen_ids.add(variant_id)
            months = variant.get("months")
            if (not isinstance(months, list) or not months
                    or not all(isinstance(m, int) and not isinstance(m, bool)
                               and ICE_MONTH_MIN <= m <= ICE_MONTH_MAX
                               for m in months)):
                fail(
                    "ice-variants",
                    label,
                    f"{where} ('{variant_id}'): months must be a non-empty "
                    f"list of ints {ICE_MONTH_MIN}-{ICE_MONTH_MAX} "
                    "(section 8.5 item 2)",
                    10,
                )
            if len(set(months)) != len(months):
                fail(
                    "ice-variants",
                    label,
                    f"{where} ('{variant_id}'): months repeats a month",
                    10,
                )
            overlap = seen_months & set(months)
            if overlap:
                fail(
                    "ice-variants",
                    label,
                    f"lane '{lane_id}': variants '{variant_id}' and an "
                    f"earlier variant share month(s) {sorted(overlap)} — "
                    "variant months are pairwise disjoint (section 8.5 "
                    "item 2)",
                    10,
                )
            seen_months |= set(months)
            waypoints = variant.get("waypoints")
            if not isinstance(waypoints, list) or len(waypoints) < 2:
                fail(
                    "ice-variants",
                    label,
                    f"{where} ('{variant_id}'): needs >= 2 [lat, lon] "
                    "waypoints (section 8.5 item 2)",
                    10,
                )
            for w_index, point in enumerate(waypoints):
                if (not isinstance(point, list) or len(point) != 2
                        or not all(isinstance(v, (int, float))
                                   and not isinstance(v, bool)
                                   for v in point)):
                    fail(
                        "ice-variants",
                        label,
                        f"{where} ('{variant_id}') waypoint {w_index} must "
                        "be [lat, lon]",
                        10,
                    )
                lat, lon = float(point[0]), float(point[1])
                if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
                    fail(
                        "ice-variants",
                        label,
                        f"{where} ('{variant_id}') waypoint {w_index} out of "
                        f"range: {point}",
                        10,
                    )
            out.append({"id": variant_id, "months": list(months),
                        "waypoints": waypoints})
        parsed[lane_id] = out
    return parsed


def _check_month_windows(grid, lanes: list, variants: dict[str, list[dict]],
                         masks: dict[int, frozenset]) -> None:
    """§8.5 items 3-4: per lane and month, the active path must avoid the
    month's ice. An ice-crossing lane without a covering variant set fails
    here, naming the lane (and variant) and month."""
    label = "trade_routes.json"

    def chain_of(waypoints, lane_id, what):
        snapped = []
        for index, point in enumerate(waypoints):
            hit = route_builder.snap_waypoint(grid, float(point[0]),
                                              float(point[1]))
            if hit is None:
                fail(
                    "ice-variants",
                    label,
                    f"lane '{lane_id}' {what} waypoint {index} has no water "
                    "tile within the snap radius (section 8.5 item 3)",
                    10,
                )
            snapped.append((hit[0], hit[1]))
        tiles: set[tuple[int, int]] = set()
        for i in range(len(snapped) - 1):
            chain, _bad = route_builder.walk_segment(grid, snapped[i],
                                                     snapped[i + 1])
            if chain is None:
                fail(
                    "ice-variants",
                    label,
                    f"lane '{lane_id}' {what} segment {i} walks onto an "
                    "impassable tile (section 8.5 item 3)",
                    10,
                )
            tiles.update(chain)
        return tiles

    for lane in lanes:
        lane_id = lane["id"]
        lane_variants = variants.get(lane_id, [])
        covered = sorted({m for variant in lane_variants
                          for m in variant["months"]})
        base_tiles = None
        for month in range(1, 13):
            if month in covered:
                continue
            if base_tiles is None:
                base_tiles = chain_of(lane["waypoints"], lane_id, "base")
            bad = base_tiles & masks[month]
            if bad:
                tile = min(bad)
                fail(
                    "ice-variants",
                    label,
                    f"lane '{lane_id}' month {month}: the base path crosses "
                    f"in-force seasonal ice at tile {tile} — an "
                    "ice-crossing lane must carry a covering variant set or "
                    "avoid ice year-round (section 8.5 item 4)",
                    10,
                )
        for variant in lane_variants:
            variant_tiles = chain_of(variant["waypoints"], lane_id,
                                     f"variant '{variant['id']}'")
            for month in sorted(variant["months"]):
                bad = variant_tiles & masks[month]
                if bad:
                    tile = min(bad)
                    fail(
                        "ice-variants",
                        label,
                        f"lane '{lane_id}' variant '{variant['id']}' month "
                        f"{month}: the variant path crosses in-force "
                        f"seasonal ice at tile {tile} (section 8.5 item 3)",
                        10,
                    )


def check_group10(docs: dict[str, object], verbose: bool) -> None:
    """Ice & lane variants: docs/10-DATA-SCHEMA.md section 8.5."""
    ice_doc = docs.get("ice_regions.json")
    if not isinstance(ice_doc, dict):
        fail("ice", ICE_JSON_LABEL,
             "missing (the §4.18 seasonal-ice data is required)", 10)
    parsed_regions = _check_ice_structure(ice_doc)

    lanes_doc = docs.get("trade_routes.json")
    lanes = lanes_doc.get("lanes", []) if isinstance(lanes_doc, dict) else []
    variants = _check_lane_variant_structure(lanes)

    grid = route_builder.load_world_grid()
    masks = _ice_masks_for(grid, parsed_regions)
    _check_month_windows(grid, lanes, variants, masks)

    if verbose:
        frozen_months = sum(
            1 for month in range(1, 13) if masks[month])
        total_variants = sum(len(v) for v in variants.values())
        print(
            f"PASS group 10 ice & lane variants ({len(parsed_regions)} ice "
            f"regions freezing {frozen_months} months, {total_variants} "
            f"lane variant(s) over {len(lanes)} lanes, month-window "
            "passability 21 lanes x 12 months ok)"
        )


# ---------------------------------------------------------------------------
# Group 10 mutation harness (`--self-test-g10`)
# ---------------------------------------------------------------------------


def run_group10_self_test() -> int:
    """Negative harness for group 10: every case must fail with exit 10."""
    results: list[bool] = []
    try:
        ice_doc = json.loads(
            (DATA_DIR / "ice_regions.json").read_text(encoding="utf-8"))
        lanes = json.loads(
            (DATA_DIR / "trade_routes.json").read_text(encoding="utf-8")
        )["lanes"]
    except (OSError, json.JSONDecodeError, KeyError) as exc:
        print(f"FAIL g10-self-test setup: cannot read data: {exc}")
        return 1

    def expect_failure(case: str, needle: str, action) -> bool:
        try:
            action()
        except CheckFailure as exc:
            haystack = f"{exc.filename} {exc.details}".lower()
            if exc.code != 10:
                print(
                    f"FAIL g10-self-test {case}: expected exit 10 but group "
                    f"10 raised exit {exc.code}: {exc.details}"
                )
                return False
            if needle.lower() not in haystack:
                print(
                    f"FAIL g10-self-test {case}: failure does not name "
                    f"{needle!r}: {exc.filename} {exc.details}"
                )
                return False
            print(f"PASS g10 negative {case}: {exc.filename} {exc.details}")
            return True
        except Exception as exc:  # a crash is not a check failure
            print(f"FAIL g10-self-test {case}: unexpected "
                  f"{type(exc).__name__}: {exc}")
            return False
        print(f"FAIL g10-self-test {case}: group 10 stayed green; the "
              "mutation was not detected")
        return False

    # Baseline: the shipped ice + lanes validate green.
    try:
        grid = route_builder.load_world_grid()
        parsed = _check_ice_structure(ice_doc)
        variants = _check_lane_variant_structure(lanes)
        masks = _ice_masks_for(grid, parsed)
        _check_month_windows(grid, lanes, variants, masks)
        print("PASS g10 baseline: the shipped ice regions and lane variants "
              "validate green")
        results.append(True)
    except CheckFailure as exc:
        print(f"FAIL g10-self-test baseline: real data is already red: "
              f"{exc.details}")
        results.append(False)

    # (1) a variant walking into in-month ice: point the hanseatic winter
    # variant at the BASE waypoints (which enter the frozen Baltic in its
    # months 12-3).
    mutated = copy.deepcopy(lanes)
    for lane in mutated:
        if lane["id"] == "hanseatic_north":
            lane["variants"][0]["waypoints"] = copy.deepcopy(lane["waypoints"])
    results.append(expect_failure(
        "variant-into-in-month-ice", "hanseatic_north",
        lambda: _check_month_windows(
            grid, mutated, _check_lane_variant_structure(mutated), masks)))

    # (2) a lane with a month gap: drop month 3 from the winter variant's
    # window — month 3 then runs the BASE path through the frozen Baltic.
    mutated = copy.deepcopy(lanes)
    for lane in mutated:
        if lane["id"] == "hanseatic_north":
            lane["variants"][0]["months"] = [12, 1, 2]
    results.append(expect_failure(
        "month-gap-runs-icy-base", "hanseatic_north",
        lambda: _check_month_windows(
            grid, mutated, _check_lane_variant_structure(mutated), masks)))

    # (3) an ice polygon vertex out of bounds.
    mutated_ice = copy.deepcopy(ice_doc)
    mutated_ice["ice_regions"][0]["polygon"][1] = [95.0, 14.0]
    results.append(expect_failure(
        "ice-vertex-out-of-range", "out of range",
        lambda: _check_ice_structure(mutated_ice)))

    # (4) an open (not closed) ice polygon.
    mutated_ice = copy.deepcopy(ice_doc)
    ring = mutated_ice["ice_regions"][0]["polygon"]
    mutated_ice["ice_regions"][0]["polygon"] = ring[:-1]
    results.append(expect_failure(
        "ice-polygon-not-closed", "closed ring",
        lambda: _check_ice_structure(mutated_ice)))

    # (5) two variants of one lane with overlapping months.
    mutated = copy.deepcopy(lanes)
    for lane in mutated:
        if lane["id"] == "hanseatic_north":
            lane["variants"].append({
                "id": "overlap_probe",
                "months": [1],
                "waypoints": copy.deepcopy(lane["waypoints"]),
            })
    results.append(expect_failure(
        "variant-months-overlap", "pairwise disjoint",
        lambda: _check_lane_variant_structure(mutated)))

    if all(results):
        print(f"OK g10 self-test: all {len(results)} cases behaved as required")
        return 0
    return 1

# ---------------------------------------------------------------------------
# Check group 11 — Captain canon (Phase 8, docs/10-* §8.6)
# ---------------------------------------------------------------------------

CAPTAINS_JSON_LABEL = "data/captains.json"
PARTS_JSON_LABEL = "data/captain_name_parts.json"
# §4.11 envelope: the builder's fixed generated_by stamp.
CAPTAIN_BUILDER_STAMP = "tools/build_captains.py"


def _check_parts_shape(parts: object) -> None:
    """§4.11.1: the builder's authored source — the name-part sets, the
    personality vocabulary (all + per-role pools) and the appearance axes.
    Only the facts the card checks below consume; the rebuild determinism
    check covers the rest."""
    label = PARTS_JSON_LABEL
    if not isinstance(parts, dict):
        fail("canon-parts", label, "the §4.11.1 source block is required", 11)
    for block in ("surnames", "given_names"):
        sets = parts.get(block)
        expected_keys = set(LOCKED_NATIONS) | {""}
        if not isinstance(sets, dict) or set(sets) != expected_keys:
            fail(
                "canon-parts",
                label,
                f"{block} keys must be the 6 nation ids + the nationless "
                "'' set (§4.11.1)",
                11,
            )
        for nation_id, parts_list in sets.items():
            if not isinstance(parts_list, list) or not parts_list:
                fail(
                    "canon-parts",
                    label,
                    f"{block}[{nation_id!r}] must be a non-empty array of "
                    "L10nString parts",
                    11,
                )
    personalities = parts.get("personalities")
    if not isinstance(personalities, dict) \
            or not isinstance(personalities.get("all"), list) \
            or not isinstance(personalities.get("roles"), dict):
        fail(
            "canon-parts",
            label,
            "personalities must be {all: [...], roles: {pool: [...]}} "
            "(§4.11.1)",
            11,
        )
    all_tags = set(personalities["all"])
    if len(all_tags) < 8:
        fail(
            "canon-parts",
            label,
            f"the shared tag vocabulary must carry ≥ 8 tags "
            f"(got {len(all_tags)})",
            11,
        )
    for pool_id, pool in personalities["roles"].items():
        if not isinstance(pool, list) or not (2 <= len(pool) <= 5) \
                or not set(pool) <= all_tags:
            fail(
                "canon-parts",
                label,
                f"personality pool {pool_id!r} must be 2–5 tags from the "
                "shared vocabulary (§4.11.1)",
                11,
            )
    appearance = parts.get("appearance")
    if not isinstance(appearance, dict) or set(appearance) != set(APPEARANCE_AXES):
        fail(
            "canon-parts",
            label,
            f"appearance must carry exactly the 4 axes "
            f"{','.join(APPEARANCE_AXES)} (§4.11.1)",
            11,
        )
    for axis, values in appearance.items():
        if not isinstance(values, list) or len(values) < 4:
            fail(
                "canon-parts",
                label,
                f"appearance.{axis} must hold ≥ 4 values (§4.11.1)",
                11,
            )


def _check_captain_card(card: dict, index: int, nation_ids: set,
                        port_ids: set, parts: dict) -> None:
    """§4.11 card shape (types/enums/ranges/vocabularies) for every card —
    legend or generated."""
    path = f"captains[{index}]"
    label = CAPTAINS_JSON_LABEL
    card_id = card.get("id")
    if not isinstance(card_id, str) or not ID_RE.match(card_id):
        fail("canon-card", label, f"{path}.id is not a valid id: {card_id!r}", 11)
    _check_l10n(card.get("name"), f"{path}.name", label)
    nation_id = card.get("nation_id")
    if nation_id != "" and nation_id not in nation_ids:
        fail(
            "canon-card",
            label,
            f"{path} ({card_id}) nation_id {nation_id!r} must be a nation "
            "or '' (the nationless pirate/coaster rows)",
            11,
        )
    role = card.get("role")
    if role not in CAPTAIN_ROLES:
        fail(
            "canon-card",
            label,
            f"{path} ({card_id}) role {role!r} is outside the 7 locked "
            f"roles ({'|'.join(CAPTAIN_ROLES)})",
            11,
        )
    # §4.11: nationless cells carry the nationless roles only, and pirates
    # keep "".
    if nation_id == "" and role not in ("pirate", "coaster"):
        fail(
            "canon-card",
            label,
            f"{path} ({card_id}): nationless cards must be pirate or "
            "coaster (§8.6 item 4)",
            11,
        )
    if role == "pirate" and nation_id != "":
        fail(
            "canon-card",
            label,
            f"{path} ({card_id}): pirates keep nation_id ''",
            11,
        )
    tier = card.get("tier")
    if not is_int(tier) or tier < 1 or tier > 3:
        fail("canon-card", label,
             f"{path} ({card_id}) tier must be 1–3 (got {tier!r})", 11)
    lo, hi = CAPTAIN_ROLE_TIERS[role]
    if not lo <= tier <= hi:
        fail(
            "canon-card",
            label,
            f"{path} ({card_id}) tier {tier} is outside the {role} range "
            f"{lo}–{hi} (§4.11 role table)",
            11,
        )
    level = card.get("level")
    expected_level = 1 + tier * 4 + (2 if role in CAPTAIN_LEVEL_BONUS_ROLES
                                     else 0)
    if level != expected_level:
        fail(
            "canon-card",
            label,
            f"{path} ({card_id}) level {level!r} must be {expected_level} "
            "(1 + tier×4, +2 pirate/hunter — §4.11)",
            11,
        )
    _check_person_attributes(card, path, label)
    skills = card.get("skills")
    if not isinstance(skills, dict) or set(skills) != set(PLAYER_SKILLS):
        fail(
            "canon-card",
            label,
            f"{path}.skills must have exactly the 8 player skill keys",
            11,
        )
    for skill in PLAYER_SKILLS:
        _require_int(skills[skill], f"{path}.skills.{skill}", label, 0, 100)
    personality = card.get("personality")
    pool = parts["personalities"]["roles"].get(role, [])
    if not isinstance(personality, list) or not (
            1 <= len(personality) <= 2) \
            or not set(personality) <= set(pool):
        fail(
            "canon-card",
            label,
            f"{path} ({card_id}) personality must be 1–2 tags from the "
            f"{role} pool (§4.11.1)",
            11,
        )
    appearance = card.get("appearance")
    if not isinstance(appearance, dict) or set(appearance) != set(APPEARANCE_AXES):
        fail(
            "canon-card",
            label,
            f"{path} ({card_id}) appearance must carry exactly the 4 axes",
            11,
        )
    for axis in APPEARANCE_AXES:
        if appearance.get(axis) not in parts["appearance"][axis]:
            fail(
                "canon-card",
                label,
                f"{path} ({card_id}) appearance.{axis} "
                f"{appearance.get(axis)!r} is outside the §4.11.1 vocabulary",
                11,
            )
    if not isinstance(card.get("legend"), bool):
        fail("canon-card", label,
             f"{path} ({card_id}) legend must be a bool", 11)
    # §4.11: `drop` appears on the 4 named pirates only.
    if "drop" in card and card_id not in LOCKED_NAMED_PIRATE_IDS:
        fail(
            "canon-card",
            label,
            f"{path} ({card_id}) carries drop — only the 4 named pirates "
            "do (§8.6 item 7)",
            11,
        )
    if "drop" not in card and card_id in LOCKED_NAMED_PIRATE_IDS:
        fail(
            "canon-card",
            label,
            f"{path} ({card_id}) is a named pirate without its drop",
            11,
        )
    home_port = card.get("home_port")
    if home_port is not None and home_port not in port_ids:
        fail(
            "canon-card",
            label,
            f"{path} ({card_id}) home_port {home_port!r} is not a known "
            "port",
            11,
        )


def _check_generated_formulas(card: dict) -> None:
    """§4.11 generation rules, term-by-term (§8.6 item 7), for a non-legend
    card. The jitter is ±3, so every attribute is checked against its
    template BAND (main +3×tier, secondary +2×tier, others +1×tier around
    base 10) — never an exact value; the template's strict ordering is the
    generation intent, not an assertable invariant under jitter."""
    card_id = card["id"]
    role = card["role"]
    tier = card["tier"]
    main_attr, sec_attr, sig_skill, sec_skill = CAPTAIN_ROLE_TEMPLATES[role]
    bands = {
        main_attr: (10 + 3 * tier - 3, 10 + 3 * tier + 3),
        sec_attr: (10 + 2 * tier - 3, 10 + 2 * tier + 3),
    }
    for attr in PERSON_ATTRIBUTES:
        lo, hi = bands.get(attr, (10 + tier - 3, 10 + tier + 3))
        value = card["attributes"][attr]
        if not lo <= value <= hi:
            fail(
                "canon-formula",
                CAPTAINS_JSON_LABEL,
                f"{card_id}: generated {attr} {value} is outside the "
                f"{role} tier-{tier} band [{lo}, {hi}] (§8.6 item 7)",
                11,
            )
    skills = card["skills"]
    if role == "coaster":
        # The coaster names NO skills — all 0 — and its luck sits at the
        # others step (never the secondary step, §4.11 -low pin).
        if any(skills.values()):
            nonzero = {k: v for k, v in skills.items() if v}
            fail(
                "canon-formula",
                CAPTAINS_JSON_LABEL,
                f"{card_id}: a coaster card carries a nonzero skill "
                f"({nonzero}) — the coaster names no skills (§4.11)",
                11,
            )
        luck_lo, luck_hi = (10 + tier - 3, 10 + tier + 3)
        if not luck_lo <= card["attributes"]["luck"] <= luck_hi:
            fail(
                "canon-formula",
                CAPTAINS_JSON_LABEL,
                f"{card_id}: coaster luck {card['attributes']['luck']} is "
                f"outside the others step [{luck_lo}, {luck_hi}] (§4.11 "
                "-low pin)",
                11,
            )
        return
    signature = skills[sig_skill]
    if signature != max(skills.values()):
        fail(
            "canon-formula",
            CAPTAINS_JSON_LABEL,
            f"{card_id}: the signature skill {sig_skill} ({signature}) is "
            "not the maximum of skills (§8.6 item 7)",
            11,
        )
    if not 8 * tier <= signature <= 8 * tier + 6:
        fail(
            "canon-formula",
            CAPTAINS_JSON_LABEL,
            f"{card_id}: signature skill {sig_skill} = {signature} is "
            f"outside [{8 * tier}, {8 * tier + 6}] (§8.6 item 7)",
            11,
        )
    if skills[sec_skill] != 4 * tier:
        fail(
            "canon-formula",
            CAPTAINS_JSON_LABEL,
            f"{card_id}: secondary skill {sec_skill} = {skills[sec_skill]} "
            f"must be 4×tier = {4 * tier} (§8.6 item 7)",
            11,
        )
    nonzero = {skill: value for skill, value in skills.items()
               if skill not in (sig_skill, sec_skill) and value != 0}
    if nonzero:
        fail(
            "canon-formula",
            CAPTAINS_JSON_LABEL,
            f"{card_id}: skills outside the template pair must be 0 "
            f"(got {nonzero}) (§8.6 item 7)",
            11,
        )


def _derive_extreme_quotas(config: dict, ports: list,
                           nations: list) -> dict:
    """§8.6 item 3 — the extreme-preset per-role totals, derived
    INDEPENDENTLY from npc_config × ports × nations (mirror of
    npc_fleets.gd budget_for(): multiply-then-ceil with the preset inside
    the ceil). Treasure is transient and covered BY trader tier-2 cards
    (W1 pin), so it is returned separately, not as a card-role total."""
    extreme = float(config["presets"][EXTREME_PRESET])
    if extreme <= 0:
        fail("canon-quotas", "npc_config.json",
             f"presets.{EXTREME_PRESET} must be > 0", 11)
    budgets = config["budgets"]
    own = {nation["id"]: 0 for nation in nations}
    neutral = 0
    for port in ports:
        if port["nation_id"] == "":
            neutral += 1
        elif port["nation_id"] in own:
            own[port["nation_id"]] += 1

    totals: dict[str, int] = {role: 0 for role in CAPTAIN_ROLES}
    for nation_id in sorted(own):
        n = own[nation_id]
        # trader: ceili(own × traders_mult_per_port × preset)
        totals["trader"] += math.ceil(
            n * budgets["traders_mult_per_port"] * extreme)
        # coaster: ceili(own × coasters_mult_per_port × preset)
        totals["coaster"] += math.ceil(
            n * budgets["coasters_mult_per_port"] * extreme)
        # patrol: max(patrols_min, ceil(own / patrols_div_ports × preset))
        raw = math.ceil(n / float(budgets["patrols_div_ports"]) * extreme)
        totals["patrol"] += max(int(budgets["patrols_min"]), raw)
        # courier: ceili(couriers_per_nation × preset)
        totals["courier"] += math.ceil(
            budgets["couriers_per_nation"] * extreme)
    # nationless coasters: ceili(neutral × neutral_coasters_mult × preset)
    totals["coaster"] += math.ceil(
        neutral * config["neutral_coasters_mult"] * extreme)
    # privateer: per UNDIRECTED rivalry pair (§4.1.1; the builder's
    # attribution splits each pair's cards 4/4 between its two nations, so
    # the pair total ≥ the per-nation runtime count either way).
    pairs: set[frozenset] = set()
    for nation in nations:
        for rival in nation.get("rivals", ()):
            pairs.add(frozenset((nation["id"], str(rival))))
    per_pair = math.ceil(budgets["privateers_per_rivalry"] * extreme)
    totals["privateer"] += per_pair * len(pairs)
    # pirate: 25 normal pirates (8 pirate_base + 17 unpatrolled zones, the
    # Phase-7 measured composition) × preset.
    totals["pirate"] += math.ceil(
        (budgets["pirate_base"] + UNPATROLLED_ZONES_PHASE7) * extreme)
    # hunter: the transient row, worst case all 6 nations bountied × preset.
    transient = len(own) * math.ceil(len(own) * extreme) // len(own)
    totals["hunter"] += transient
    treasure = transient
    return {"totals": totals, "treasure": treasure, "extreme": extreme}


def _check_quota_table(doc: dict, roster: list, derived: dict) -> None:
    """§8.6 item 4: the artifact's quota_table equals the roster's actual
    per-(role, tier, nation) cell counts (metadata keys like note /
    covered_by skipped), every tier stays inside its role's range, and the
    derived rows are covered."""
    quota_table = doc.get("quota_table")
    if not isinstance(quota_table, dict) or not quota_table:
        fail("canon-quotas", CAPTAINS_JSON_LABEL,
             "the artifact must carry a quota_table (§4.11)", 11)
    actual: dict[tuple[str, int, str], int] = {}
    for card in roster:
        key = (card["role"], card["tier"], card["nation_id"])
        actual[key] = actual.get(key, 0) + 1
    for role, row in quota_table.items():
        if role == "treasure":
            # Recorded-only row: no treasure-ROLE cards exist (the fleets
            # are trader tier-2 cards of their nation, covered_by pin
            # checked below).
            continue
        for key, cell in row.items():
            if not key.isdigit():
                continue  # metadata: pirate `note`, treasure `covered_by`
            tier = int(key)
            if role in CAPTAIN_ROLE_TIERS:
                lo, hi = CAPTAIN_ROLE_TIERS[role]
                if not lo <= tier <= hi:
                    fail(
                        "canon-quotas",
                        CAPTAINS_JSON_LABEL,
                        f"quota_table[{role}] tier {tier} is outside the "
                        f"{role} range {lo}–{hi} (§4.11)",
                        11,
                    )
            if not isinstance(cell, dict):
                fail("canon-quotas", CAPTAINS_JSON_LABEL,
                     f"quota_table[{role}][{key}] must be a nation → count "
                     "object", 11)
            for nation_id, count in cell.items():
                held = actual.get((role, tier, nation_id), 0)
                if held != count:
                    fail(
                        "canon-quotas",
                        CAPTAINS_JSON_LABEL,
                        f"quota_table[{role}][{key}][{nation_id or '\"\"'}] = "
                        f"{count}, roster holds {held} (§8.6 item 4)",
                        11,
                    )
    # §8.6 items 3–4: per-role coverage ≥ the derived extreme totals, and
    # the grand total ≥ the derived grand total.
    for role, want in derived["totals"].items():
        got = sum(count for (r, _t, _n), count in actual.items() if r == role)
        if got < want:
            fail(
                "canon-quotas",
                CAPTAINS_JSON_LABEL,
                f"role {role}: {got} cards < the derived extreme-preset "
                f"total {want} (§7.7 — coverage is computed, never "
                "magic-numbered)",
                11,
            )
    grand_want = sum(derived["totals"].values())
    if len(roster) < grand_want:
        fail(
            "canon-quotas",
            CAPTAINS_JSON_LABEL,
            f"canon grand total {len(roster)} < the derived extreme-preset "
            f"fleet total {grand_want} (§8.6 item 3)",
            11,
        )
    # The treasure row is covered BY the trader tier-2 cards (W1 pin); the
    # builder records it as its own quota_table row.
    treasure_row = quota_table.get("treasure")
    if not isinstance(treasure_row, dict) \
            or treasure_row.get("covered_by") != "trader.tier2":
        fail(
            "canon-quotas",
            CAPTAINS_JSON_LABEL,
            "quota_table.treasure must record covered_by = trader.tier2 "
            "(§4.11 — a treasure fleet is a national trader convoy, no "
            "8th role)",
            11,
        )
    trader_t2 = sum(count for (r, t, _n), count in actual.items()
                    if r == "trader" and t == 2)
    if trader_t2 < derived["treasure"]:
        fail(
            "canon-quotas",
            CAPTAINS_JSON_LABEL,
            f"trader tier-2 cards ({trader_t2}) cannot cover the treasure "
            f"row ({derived['treasure']}) (§7.7 transient worst case)",
            11,
        )
    # The pinned pirate composition is recorded, not magic-numbered: the
    # quota_table's pirate row carries the 25 = 8 + 17 note (§7.7).
    note = quota_table.get("pirate", {}).get("note")
    if not isinstance(note, str) or not note.strip():
        fail(
            "canon-quotas",
            CAPTAINS_JSON_LABEL,
            "quota_table.pirate.note must record the pinned composition "
            "(8 pirate_base + 17 unpatrolled zones × the extreme preset)",
            11,
        )


def _check_canon_rebuild_determinism(verbose: bool) -> None:
    """§8.6 item 2: `tools/build_captains.py --check` re-builds all three
    products in memory and byte-compares them against the committed files.
    With a data-root override the overridden checkout's own builder runs
    over its own tree (the staged-sim protocol, like group 8)."""
    import subprocess

    builder_root = REPO_ROOT
    if DATA_DIR != _default_data_dir():
        staged_tools = DATA_DIR.parent / "tools" / "build_captains.py"
        if staged_tools.is_file():
            builder_root = DATA_DIR.parent
    result = subprocess.run(
        [sys.executable, str(builder_root / "tools" / "build_captains.py"),
         "--check"],
        capture_output=True,
        text=True,
        cwd=builder_root,
    )
    if verbose and result.stderr:
        for line in result.stderr.strip().splitlines():
            print(f"INFO group 11 {line}")
    if result.returncode != 0:
        tail = (result.stderr or result.stdout or "").strip().splitlines()
        detail = tail[-1] if tail else f"exit {result.returncode}"
        fail(
            "canon-rebuild",
            CAPTAINS_JSON_LABEL,
            f"rebuild drift: {detail} (tools/build_captains.py --check "
            f"exited {result.returncode}; §8.6 item 2 — fix "
            "data/captain_name_parts.json, tools/captain_overrides.json or "
            "tools/officer_overrides.json and regenerate, never hand-edit "
            "the built files)",
            11,
        )


def check_group11(docs: dict[str, object], verbose: bool) -> None:
    """Captain canon: docs/10-DATA-SCHEMA.md section 8.6.

    §8.6 item 1 (the retired name-pool file's absence), the envelope + card
    shapes + the generated-card formulas re-asserted term-by-term, the
    extreme-preset quota coverage re-derived independently from npc_config ×
    ports × nations, the artifact quota_table vs the roster cells, and name
    uniqueness across the canon and the officer roster. The byte-identical
    builder rebuild runs last (§8.6 item 2).
    """
    # §8.6 item 1: the Phase-5 name-pool file must NOT exist — its presence
    # is the failure (the successor machinery is retired, `60-*`; the canon +
    # `captain_states` replace it). W4-B deleted the file (2026-11-03).
    retired = DATA_DIR / "npc_captains.json"
    if retired.exists():
        fail(
            "canon-retired",
            "npc_captains.json",
            "data/npc_captains.json still exists — the Phase-5 name pools "
            "are retired (§7.7); delete the file (§8.6 item 1)",
            11,
        )
    doc = docs.get("captains.json")
    if not isinstance(doc, dict):
        fail("canon", CAPTAINS_JSON_LABEL,
             "missing (build with tools/build_captains.py)", 11)
    if doc.get("version") != 1:
        fail("canon", CAPTAINS_JSON_LABEL,
             f"'version' must be 1 (got {doc.get('version')!r})", 11)
    if doc.get("generated_by") != CAPTAIN_BUILDER_STAMP:
        fail(
            "canon",
            CAPTAINS_JSON_LABEL,
            f"'generated_by' must be {CAPTAIN_BUILDER_STAMP!r} "
            f"(got {doc.get('generated_by')!r})",
            11,
        )
    if doc.get("artifact") != "data/captains.json":
        fail("canon", CAPTAINS_JSON_LABEL,
             f"'artifact' must be data/captains.json "
             f"(got {doc.get('artifact')!r})", 11)
    if not isinstance(doc.get("build"), dict) \
            or not isinstance(doc.get("quota_table"), dict) \
            or not isinstance(doc.get("captains"), list):
        fail(
            "canon",
            CAPTAINS_JSON_LABEL,
            "the §4.11 envelope needs build, quota_table and captains "
            "(§8.6)",
            11,
        )
    roster = doc["captains"]
    seen_ids: set[str] = set()
    for index, card in enumerate(roster):
        if not isinstance(card, dict):
            fail("canon-card", CAPTAINS_JSON_LABEL,
                 f"captains[{index}] must be an object", 11)
        card_id = card.get("id")
        if card_id in seen_ids:
            fail("canon-card", CAPTAINS_JSON_LABEL,
                 f"captain id repeated: {card_id!r}", 11)
        seen_ids.add(card_id)

    nation_ids = {nation["id"] for nation in docs["nations.json"]["nations"]}
    port_ids = {port["id"] for port in docs["ports.json"]["ports"]}
    parts = docs.get("captain_name_parts.json")
    _check_parts_shape(parts)
    legends = 0
    for index, card in enumerate(roster):
        _check_captain_card(card, index, nation_ids, port_ids, parts)
        if card.get("legend") is True:
            legends += 1
        else:
            _check_generated_formulas(card)
    # §8.6 item 7: legend: true on exactly the 24 hand-authored cards.
    if legends != OFFICER_LEGEND_COUNT:
        fail(
            "canon-card",
            CAPTAINS_JSON_LABEL,
            f"exactly {OFFICER_LEGEND_COUNT} legend cards are hand-authored "
            f"(§7.7), got {legends}",
            11,
        )

    # §8.6 items 3–4: computed coverage + the quota-table match.
    derived = _derive_extreme_quotas(
        docs.get("npc_config.json", {}),
        docs["ports.json"]["ports"],
        docs["nations.json"]["nations"],
    )
    _check_quota_table(doc, roster, derived)

    # §8.6 item 5: name uniqueness across every person — canon ∪ officers
    # (zh and en separately; a collision in either locale is a reuse).
    officers = docs["officers.json"]["officers"]
    zh_names: dict[str, str] = {}
    en_names: dict[str, str] = {}
    for person in roster + officers:
        person_id = person.get("id", "?")
        name = person.get("name", {})
        for locale, registry in (("zh", zh_names), ("en", en_names)):
            key = name.get(locale)
            if not isinstance(key, str):
                continue  # group 2 already reported the malformed string
            if key in registry:
                fail(
                    "canon-names",
                    CAPTAINS_JSON_LABEL,
                    f"{locale} name {key!r} is reused by "
                    f"{registry[key]!r} and {person_id!r} — names are "
                    "never reused (§8.6 item 5)",
                    11,
                )
            registry[key] = person_id

    # §4.11.1 vocabulary closure in ui_strings: every personality tag and
    # appearance axis-value has its char.* string row.
    ui = docs.get("ui_strings.json")
    if isinstance(ui, dict):
        for tag in parts["personalities"]["all"]:
            if f"char.personality.{tag}" not in ui:
                fail(
                    "canon-vocab",
                    "ui_strings.json",
                    f"missing char.personality.{tag} — every personality "
                    "tag needs its string row (§4.11.1)",
                    11,
                )
        for axis, values in parts["appearance"].items():
            for value in values:
                key = f"char.appearance.{axis}.{value}"
                if key not in ui:
                    fail(
                        "canon-vocab",
                        "ui_strings.json",
                        f"missing {key} — every appearance value needs its "
                        "string row (§4.11.1)",
                        11,
                    )

    # §8.6 item 6 lives in group 7 (the v2 named-pirate full-card check,
    # including the drop → rare pin — see _check_named_pirates). §8.6 item 1
    # ran at the top of this group (the retired file's absence).

    # §8.6 item 2: rebuild determinism (byte-exact), LAST so the structural
    # verdicts above name problems before the builder is re-run.
    _check_canon_rebuild_determinism(verbose)
    if verbose:
        per_role = {role: sum(1 for c in roster if c["role"] == role)
                    for role in CAPTAIN_ROLES}
        print(
            f"PASS group 11 captain canon ({len(roster)} cards — "
            + " / ".join(f"{role} {per_role[role]}"
                         for role in CAPTAIN_ROLES)
            + f"; {legends} legends; extreme derived "
            + " / ".join(f"{role} {want}"
                         for role, want in derived["totals"].items())
            + f"; treasure {derived['treasure']} covered by trader tier-2)"
        )


# ---------------------------------------------------------------------------
# Check group 12 — RPG data (Phase 8, docs/10-* §8.7)
# ---------------------------------------------------------------------------

UI_STRINGS_LABEL = "data/ui_strings.json"
# §7.11: the Phase-8 ui_strings family prefixes (≥ 1 key each, both locales
# via group 2). skill.* / officer.post.* / advice.* own their named checks
# below; the rest are presence-checked here.
PHASE8_STRING_FAMILIES = (
    "char.", "gate.", "hail.", "interact.", "dossier.", "captain.table.",
    "creation.", "sail.autopilot.", "ending.rpg.",
)


def _check_officer_pools(officers: list, parts: dict) -> None:
    """§8.7 item 1: personality ⊆ the officer's native-role pool(s)
    (§4.11.1; pool id = native-role id). The seamanship main is ambiguous
    between boatswain and captain — the union is the pool, and seamanship
    main LEGENDS draw the boatswain pool only (the builder's recorded pin,
    tools/build_captains.py)."""
    pools = parts["personalities"]["roles"]
    for officer in officers:
        main = officer["main_skill"]
        pool_ids = OFFICER_MAIN_ROLE_POOLS.get(main)
        if not pool_ids:
            fail(
                "officer-pool",
                "officers.json",
                f"{officer['id']}: main_skill {main!r} maps to no native "
                "role (§4.5)",
                12,
            )
        pool = set().union(*(set(pools[p]) for p in pool_ids))
        tags = set(officer["personality"])
        if not tags <= pool:
            fail(
                "officer-pool",
                "officers.json",
                f"{officer['id']}: personality "
                f"{sorted(tags - pool)} is outside the {main}-native "
                f"pool(s) {pool_ids} (§8.7 item 1)",
                12,
            )
        if officer["legend"] and main == "seamanship" \
                and not tags <= set(pools["boatswain"]):
            fail(
                "officer-pool",
                "officers.json",
                f"{officer['id']}: seamanship-main legend must draw the "
                "boatswain pool (the boatswain/captain ambiguity)",
                12,
            )


def check_group12(docs: dict[str, object], verbose: bool) -> None:
    """RPG data: docs/10-DATA-SCHEMA.md section 8.7 — the officers v2
    quotas, the §4.20 skill gates, the §4.21 officer posts with their
    locked prereqs and advice strings, the §4.22 backgrounds, and the
    §7.11 ui_strings Phase-8 family presence."""
    officers = docs["officers.json"]["officers"]
    parts = docs["captain_name_parts.json"]

    # -- items 1–2: the 96 = 24 + 72 roster with its bands --------------------
    legends = [o for o in officers if o["legend"] is True]
    regulars = [o for o in officers if o["legend"] is not True]
    if len(officers) != OFFICER_TOTAL or len(officers) != \
            OFFICER_LEGEND_COUNT + OFFICER_REGULAR_COUNT:
        fail(
            "officer-quotas",
            "officers.json",
            f"officers: {len(officers)} != the locked "
            f"{OFFICER_TOTAL} = {OFFICER_LEGEND_COUNT} + "
            f"{OFFICER_REGULAR_COUNT} (§8.7 item 1)",
            12,
        )
    if len(legends) != OFFICER_LEGEND_COUNT:
        fail(
            "officer-quotas",
            "officers.json",
            f"{len(legends)} legend officers != the locked "
            f"{OFFICER_LEGEND_COUNT} (§8.7 item 1)",
            12,
        )
    for officer in legends:
        value = officer["skills"][officer["main_skill"]]
        if not LEGEND_MAIN_BAND[0] <= value <= LEGEND_MAIN_BAND[1]:
            fail(
                "officer-quotas",
                "officers.json",
                f"{officer['id']}: legend main skill {value} is outside "
                f"{LEGEND_MAIN_BAND} (§8.7 item 2)",
                12,
            )
        if not LEGEND_WAGE_BAND[0] <= officer["wage_daily"] <= LEGEND_WAGE_BAND[1]:
            fail(
                "officer-quotas",
                "officers.json",
                f"{officer['id']}: legend wage {officer['wage_daily']} g is "
                f"outside {LEGEND_WAGE_BAND} (§8.7 item 2)",
                12,
            )
    for officer in regulars:
        value = officer["skills"][officer["main_skill"]]
        if not REGULAR_MAIN_BAND[0] <= value <= REGULAR_MAIN_BAND[1]:
            fail(
                "officer-quotas",
                "officers.json",
                f"{officer['id']}: regular main skill {value} is outside "
                f"{REGULAR_MAIN_BAND} (§8.7 item 2)",
                12,
            )
        if not REGULAR_WAGE_BAND[0] <= officer["wage_daily"] <= REGULAR_WAGE_BAND[1]:
            fail(
                "officer-quotas",
                "officers.json",
                f"{officer['id']}: regular wage {officer['wage_daily']} g "
                f"is outside {REGULAR_WAGE_BAND} (§8.7 item 2)",
                12,
            )

    # -- item 3: specialty coverage -------------------------------------------
    carriers = {skill: sum(1 for o in officers
                           if o["skills"][skill] >= SPECIALTY_THRESHOLD)
                for skill in OFFICER_SKILL_NAMES}
    for skill, count in carriers.items():
        if count < SPECIALTY_MIN_CARRIERS:
            fail(
                "officer-quotas",
                "officers.json",
                f"specialty {skill}: {count} officers carry it at "
                f"≥ {SPECIALTY_THRESHOLD} < {SPECIALTY_MIN_CARRIERS} "
                "(§8.7 item 3 — the post-prereq band)",
                12,
            )

    # -- item 4: captain-qualified --------------------------------------------
    captain_qualified = sum(
        1 for o in officers
        if o["skills"]["seamanship"] >= 25 and o["attributes"]["courage"] >= 30)
    if captain_qualified < CAPTAIN_QUALIFIED_MIN:
        fail(
            "officer-quotas",
            "officers.json",
            f"captain-qualified officers: {captain_qualified} < "
            f"{CAPTAIN_QUALIFIED_MIN} (seamanship ≥ 25 ∧ courage ≥ 30, "
            "§8.7 item 4)",
            12,
        )

    # -- item 5: recruit ports (the §7.5 starters are identity-locked, so
    # they are exempt from the own-nation subset — off_diego_fernandez
    # recruits at ceuta, a portugal port) --------------------------------------
    ports_by_nation: dict[str, set] = {}
    for port in docs["ports.json"]["ports"]:
        ports_by_nation.setdefault(port["nation_id"], set()).add(port["id"])
    for officer in officers:
        if officer["id"] in STARTER_IDS:
            continue
        own = ports_by_nation.get(officer["nation_id"], set())
        outside = sorted(set(officer["recruit_ports"]) - own)
        if outside:
            fail(
                "officer-quotas",
                "officers.json",
                f"{officer['id']}: recruit ports {outside} are outside "
                f"{officer['nation_id']}'s ports (§8.7 item 5 — the "
                "home-port band; §7.5 starters are identity-exempt)",
                12,
            )

    # -- item 1 (pools): personality ⊆ the native-role pool -------------------
    _check_officer_pools(officers, parts)

    # -- item 6: skill_gates — the locked inventory + the autopilot pin -------
    gates = docs["skill_gates.json"]["skill_gates"]
    gate_features = {g["feature_id"] for g in gates}
    missing_gates = [f for f in LOCKED_GATE_FEATURES if f not in gate_features]
    if missing_gates:
        fail(
            "gates",
            "skill_gates.json",
            f"missing the locked gate row(s) {', '.join(missing_gates)} "
            "(§8.7 item 6 — the 50-* §2.2 Gates column + sail.autopilot)",
            12,
        )
    autopilot = next((g for g in gates
                      if g["feature_id"] == "sail.autopilot"), None)
    if not autopilot or autopilot["stat_or_skill"] != "navigation" \
            or autopilot["threshold"] != 40:
        fail(
            "gates",
            "skill_gates.json",
            "sail.autopilot must pin stat_or_skill = navigation and "
            "threshold = 40 (§8.7 item 6, the appointed-voyage gate)",
            12,
        )

    # -- item 7: officer_posts — the locked prereqs + advice strings ----------
    ui = docs.get("ui_strings.json")
    if not isinstance(ui, dict):
        ui = {}
    posts = {p["post_id"]: p for p in docs["officer_posts.json"]["officer_posts"]}
    if set(posts) != set(LOCKED_POST_IDS):
        fail(
            "posts",
            "officer_posts.json",
            f"post set {sorted(posts)} must be exactly the 7 locked posts "
            f"({', '.join(LOCKED_POST_IDS)}) (§8.7 item 7)",
            12,
        )
    for post_id, prereq in FLAGSHIP_POST_PREREQ.items():
        if posts[post_id].get("slot_type") != "flagship" \
                or posts[post_id].get("prereq") != prereq:
            fail(
                "posts",
                "officer_posts.json",
                f"post {post_id}: flagship prereq must be exactly {prereq} "
                "(the matching skill ≥ 20, §4.21)",
                12,
            )
    if posts["captain"].get("slot_type") != "captain" \
            or posts["captain"].get("prereq") != CAPTAIN_POST_PREREQ:
        fail(
            "posts",
            "officer_posts.json",
            f"post captain: prereq must be exactly {CAPTAIN_POST_PREREQ} "
            "(seamanship ≥ 25 ∧ courage ≥ 30, §4.21)",
            12,
        )
    for post_id, post in posts.items():
        for situation, params in post.get("advice", {}).items():
            expected = ADVICE_PARAMS.get(situation, {})
            if expected and params != expected:
                fail(
                    "posts",
                    "officer_posts.json",
                    f"post {post_id} advice {situation}: trigger params "
                    f"{params} must be exactly {expected} (§4.21 — the "
                    "numbers sit in this table, never in code)",
                    12,
                )
            if f"advice.{post_id}.{situation}" not in ui:
                fail(
                    "posts",
                    UI_STRINGS_LABEL,
                    f"missing advice.{post_id}.{situation} — every advice "
                    "situation needs its ui_strings row (§8.7 item 7)",
                    12,
                )

    # -- item 8: backgrounds — the §8.7 rules (re-asserted) -------------------
    _check_background_rules(docs["backgrounds.json"]["backgrounds"])

    # -- item 9: ui_strings Phase-8 families ----------------------------------
    ui_keys = set(ui) - {"version"}
    for prefix in PHASE8_STRING_FAMILIES:
        if not any(key.startswith(prefix) for key in ui_keys):
            fail(
                "strings",
                UI_STRINGS_LABEL,
                f"the Phase-8 ui_strings family {prefix}* is empty "
                "(§7.11/§8.7 item 9)",
                12,
            )
    for skill in OFFICER_SKILL_NAMES:
        if f"skill.{skill}" not in ui:
            fail(
                "strings",
                UI_STRINGS_LABEL,
                f"missing skill.{skill} — the 8 player + 3 ship-service "
                "skill names are locked strings (§7.11)",
                12,
            )
    for post_id in LOCKED_POST_IDS:
        if f"officer.post.{post_id}" not in ui:
            fail(
                "strings",
                UI_STRINGS_LABEL,
                f"missing officer.post.{post_id} — the 7 post names are "
                "locked strings (§8.7 item 9)",
                12,
            )
    if "officer.post.no_captain" not in ui:
        fail(
            "strings",
            UI_STRINGS_LABEL,
            "missing officer.post.no_captain (§8.7 item 9)",
            12,
        )
    # advice.* is closed: exactly the §4.21 rows, no strays.
    expected_advice = {
        f"advice.{post_id}.{situation}"
        for post_id, post in posts.items()
        for situation in post.get("advice", {})
    }
    stray = sorted(k for k in ui_keys if k.startswith("advice.")
                   and k not in expected_advice)
    if stray:
        fail(
            "strings",
            UI_STRINGS_LABEL,
            f"advice.* carries key(s) outside the §4.21 trigger table: "
            f"{', '.join(stray)}",
            12,
        )
    if verbose:
        print(
            f"PASS group 12 RPG data ({len(officers)} officers = "
            f"{len(legends)} + {len(regulars)}, captain-qualified "
            f"{captain_qualified}, specialty carriers "
            + " / ".join(f"{skill} {carriers[skill]}"
                         for skill in OFFICER_SKILL_NAMES)
            + f"; {len(gates)} gates, {len(posts)} posts, "
            f"{len(ui_keys)} ui_strings keys)"
        )


# ---------------------------------------------------------------------------
# Check group 13 — Generated UI art & shore raster (docs section 8.8)
# ---------------------------------------------------------------------------

ART_ROOT = DATA_DIR.parent  # staged-sim protocol: the tree the data/ lives in
ASSETS_UI = ART_ROOT / "assets" / "ui"
UI_ART_DIR = ART_ROOT / "tools" / "ui_art"
WORLD_SHORE_PNG = DATA_DIR / "maps" / "world_shore.png"
ART_PROMPTS_JSON = ART_ROOT / "tools" / "art_prompts.json"

# The §4.8.4 palette blocks, transcribed from docs/80-UI-UX.md §4.8 (and
# double-checked against scripts/palette.gd's block constants). Membership is
# per-class (W1 adjudication b): a sprite checks against its own class's
# block only; the §4.8 locked table joins every class's allowed set.
BLOCK_TERRAIN = frozenset({
    "#16446e", "#2f6f9e", "#7a5c2e", "#8f6d3a", "#5e4720", "#3d3d3d",
    "#565656", "#c9d6df", "#e4eef4", "#9fb4c4", "#dff0f4", "#101010",
    "#1a8c4e", "#b3191f", "#274b8f", "#d97b1e", "#6a3d9a", "#c9a227",
    "#9a9a9a",
})
BLOCK_ICON = frozenset({
    "#1c2230", "#121724", "#465468", "#5e7086", "#232c3e", "#e8e6df",
    "#f7f5ee", "#d9a441", "#f0c46a", "#a87a28", "#4e9e4e", "#74c26e",
    "#b3341f", "#d4573c", "#2f6f9e", "#9a9a9a", "#1a8c4e", "#b3191f",
    "#274b8f", "#d97b1e", "#6a3d9a", "#c9a227",
    "#2e2014", "#6a4e28", "#14100a",  # UW2 chrome skin (§4.8 amended
    # 2026-11-04, ledgered): walnut fill + bevel wood for the nine-patch
    # chrome tiles (PANEL_WOOD / PANEL_WOOD_HI / PANEL_WOOD_LO)
})
# Amended §4.8 hull block (2026-11-04, the shared-hull pennant scheme): 16
# distinct hexes — ink, wood ×3, sail ×3, HULL_GOLD, 9 PENNANT_* owner values.
# Wood/sail/ink/gold are owner-invariant; the owner rides ONLY the masthead
# pennant (the authored source hex #b3191f remaps to the owner's pennant and
# is itself the spain pennant value). The retired owner HI/BASE/LO ramp hexes
# are NO LONGER allowed in shipped hull pixels.
BLOCK_HULL = frozenset({
    "#101010", "#8f6d3a", "#7a5c2e", "#5e4720", "#f7f5ee", "#e8e6df",
    "#c2beb2", "#a8a496", "#9a6a3a", "#d9a441", "#1a8c4e", "#b3191f",
    "#274b8f", "#d97b1e", "#6a3d9a", "#c9a227", "#9a9a9a", "#b3341f",
})
BLOCK_FX = frozenset({
    "#26262c", "#8a929c", "#c6ccd4", "#555c66", "#dff0f4", "#9fc4d4",
    "#7a2d16", "#ff8c2a", "#ffd23e",
})
BLOCK_PORTRAIT = frozenset({
    "#101010", "#f0d0b0", "#d9a878", "#a87a52", "#1a1a1e", "#6b4a2a",
    "#b9bcc0", "#e8e6df", "#d9b98a", "#2e2014", "#8a929c", "#a87a28",
    "#9cc4dc", "#d9a441", "#465468", "#2f6f9e", "#4e9e4e", "#b3341f",
    "#1a8c4e", "#b3191f", "#274b8f", "#d97b1e", "#6a3d9a", "#c9a227",
})
# §4.8's locked palette table (the "chrome hexes already in §4.8's locked
# table" clause of §8.8 item 3).
BLOCK_LOCKED = frozenset({
    "#16446e", "#2f6f9e", "#7a5c2e", "#3d3d3d", "#c9d6df", "#9a9a9a",
    "#1c2230", "#465468", "#e8e6df", "#d9a441", "#4e9e4e", "#b3341f",
})

# Class → block (80-* §4.8.4 class→block mapping; world markers join the
# terrain block like the port markers they render beside).
CLASS_BLOCK = {
    "chrome": BLOCK_ICON,
    "icons": BLOCK_ICON,
    "hulls": BLOCK_HULL,
    "terrain": BLOCK_TERRAIN,
    "shore": BLOCK_TERRAIN,
    "markers": BLOCK_TERRAIN,
    "fx": BLOCK_FX,
    "portraits": BLOCK_PORTRAIT,
}

# Color budgets = the skill's size tiers (80-* §4.8.3: caps, not quotas).
G13_CAP_16 = 12
G13_CAP_32 = 20
G13_CAP_48 = 25

# Aux authoring docs that live inside class dirs but are inputs, not render
# declarations (master reconciliation 2026-11-04, ledgered): the hull rig
# library + authoring index (slot B) and the portrait anchors (slot D).
G13_AUX_DOCS = frozenset({"rig.json", "hulls.json", "anchors.json"})


def _g13_cap(width: int, height: int) -> int:
    side = max(width, height)
    if side <= 16:
        return G13_CAP_16
    if side <= 32:
        return G13_CAP_32
    return G13_CAP_48


# 8-direction transform ops (the pinned lossless set; identical index math
# to the manifest generator's — compared pixel-exact against artifacts).
def _g13_mirror_x(px, w, h):
    return [row[::-1] for row in px]


def _g13_mirror_y(px, w, h):
    return px[::-1]


def _g13_rot_180(px, w, h):
    return [row[::-1] for row in px[::-1]]


def _g13_rot_cw(px, w, h):
    n = len(px)
    return ["".join(px[n - 1 - x][y] for x in range(n)) for y in range(n)]


def _g13_rot_ccw(px, w, h):
    n = len(px)
    return ["".join(px[x][n - 1 - y] for x in range(n)) for y in range(n)]


def _g13_rot180_mirror_x(px, w, h):
    return _g13_mirror_x(_g13_rot_180(px, w, h), w, h)


G13_DERIVE_OPS = {
    "mirror_x": _g13_mirror_x,
    "mirror_y": _g13_mirror_y,
    "rot_180": _g13_rot_180,
    "rot_cw": _g13_rot_cw,
    "rot_ccw": _g13_rot_ccw,
    "rot180_mirror_x": _g13_rot180_mirror_x,
}

# Contract id inventories (80-* §4.8.6 heading8 table + A.1/A.2 of
# IMPLEMENT-Phase10.md). Data-driven families (goods/equipment/flags/hulls)
# join these from the data files at machine scope.
G13_DIR_IDS = ("n", "ne", "e", "se", "s", "sw", "w", "nw")
G13_CHROME_TILES = tuple(
    f"{stem}_{tile}"
    for stem in ("panel", "button", "button_focus", "field")
    for tile in ("corner", "edge", "fill")
) + ("bar_left", "bar_right", "bar_line")
G13_CHROME_SHEETS = tuple(
    f"ninepatch_{stem}.png"
    for stem in ("panel", "button", "button_focus", "field", "bar")
)
G13_ICON_PINNED = (
    "coin", "crew", "provisions", "morale", "durability",
    "compass", "calm", "fair", "strong", "storm",
    "cannon", "shot_round", "shot_chain", "shot_armor_piercing",
    "shot_grape", "hook", "ram", "surrender_flag",
    "chest", "scroll", "hammer", "bell",
    "anchor", "hourglass", "save", "skull", "crown",
    "trophy", "trend_up", "trend_down", "event_demand",
    "role_trader", "role_coaster", "role_courier", "role_patrol",
    "role_privateer", "role_pirate", "role_hunter",
    "formation_line_ahead", "formation_column", "formation_screen",
    "formation_swarm",
)
G13_FACILITY_TOKENS = (
    "facility_market", "facility_shipyard", "facility_tavern",
    "facility_inn", "facility_guild", "facility_palace",
)
G13_TOKEN_OWNERS_EXTRA = ("player", "neutral", "pirate")
# Tier footprint bands (80-* §4.8.7, long-axis px on the 64x64 canvas —
# the §4.8 64-canvas amendment 1664ba9; ×2 of the retired 32-canvas values).
G13_TIER_BANDS = {1: (28, 36), 2: (40, 52), 3: (52, 60)}
# The §4.8 64-canvas amendment (1664ba9): the shipped canvas for hull tokens
# and the terrain class is 64×64 — the exact ×2 nearest upscale of the
# authored 32-grid (the authored manifests REMAIN the 32-grid source of
# truth); a source already authored at 64 (sea_pattern) ships 1:1.
G13_CANVAS_64 = 64

# The top-down canvas = tier table (80-* §4.8 2026-11-07): one north token
# per ship at its tier's canvas, runtime-rotated.
G13_NORTH_TIER_SIZE = {1: 32, 2: 48, 3: 64}

# §4.8 hull block, amended 2026-11-04 (the shared-hull pennant scheme): the
# owner rides ONLY the masthead pennant — the authored maps carry the source
# hex below and the governor remaps it to the owner's pennant value; wood/
# sail/ink/gold are owner-invariant.  Spain's pennant equals the source hex
# (the legal identity remap).
G13_PENNANT_SOURCE = "#b3191f"
G13_PENNANTS = {
    "player": "#d9a441", "portugal": "#1a8c4e", "spain": "#b3191f",
    "england": "#274b8f", "holland": "#d97b1e", "ottoman": "#6a3d9a",
    "italy": "#c9a227", "neutral": "#9a9a9a", "pirate": "#b3341f",
}

# §4.8 model-pass ship ingestion (90-* §9.2 AI-ingestion path; the committed
# provenance ledger + the 5-direction generation amendment f6c00bb — the
# model only ever generates the BASE dirs, e/ne/se are mirror-derived at
# ingestion).  The ingested tokens are audited exactly like the generated
# ones (canvas/band/block/pennant above) plus the ledger contract here.
G13_INGEST_VERSION = 2
G13_INGEST_LEDGER = UI_ART_DIR / "ingest_ledger.json"
# PixelLab raw mode (80-* §4.8 2026-11-06): all 8 native rotations
RAW_INGEST_DIRS = ("n", "ne", "e", "se", "s", "sw", "w", "nw")
G13_INGEST_BASE_DIRS = ("n", "s", "w", "sw", "nw")
G13_INGEST_DERIVED = {"e": "w", "ne": "nw", "se": "sw"}  # exact h-flips
G13_MASTHEAD_MIN_PX = 3      # §4.8 ingestion contract: ≥3 source px
G13_MASTHEAD_TOP_FRAC = 0.45  # in the top 45% of the opaque bbox

# The icon + terrain ingest families (2026-11-05, ledger v2): the model
# icons re-quantize to the icon block and halve 64→32 (EXACT 2:1 nearest,
# origin-anchored out(x, y) = src(2x, 2y) — the validator re-derives the
# halving from the gitignored snapped source and byte-compares); the
# terrain land variants crop from the model plains sheet onto the land
# ramp with the authored phase-0 ring (the validator re-derives the whole
# file from the gitignored sheet).  Sources stay gitignored — provenance
# rides the committed ledger sha when the cache is absent (90-* §9.2).
G13_ICON_CACHE_DIRS = ("snapped", "studio/snapped", "pixellab_icons")
G13_ICON_INLINE = 32
G13_ICON_CAP_32 = 20
G13_TERRAIN_CACHE_SUBDIR = "gen"
G13_TERRAIN_VARIANTS = 4
G13_TERRAIN_SHEET = (1024, 512)
G13_TERRAIN_PATCH = 256
G13_TERRAIN_CROP_INSET = 96
G13_LAND_RAMP = ("#7a5c2e", "#8f6d3a", "#5e4720")  # LAND / LAND_HI / LAND_LO


def _g13_nearest_hex(hexv: str, block) -> str:
    """First-min nearest over the sorted block (the deterministic ingest
    metric — mirrors the governor's quantizers). ``hexv`` is a #rrggbb
    string (the decode_ui_png artifact form)."""
    rgb = tuple(int(hexv[i:i + 2], 16) for i in (1, 3, 5))
    best, best_d = None, None
    for hx in sorted(block):
        hv = tuple(int(hx[i:i + 2], 16) for i in (1, 3, 5))
        d = sum(abs(a - b) for a, b in zip(rgb, hv))
        if best_d is None or d < best_d:
            best, best_d = hx, d
    return best


def _g13_halve64(pixels) -> list[list[str]]:
    """The exact 2:1 nearest halving of a 64-grid hex matrix (out(x, y) =
    src(2x, 2y)) — the pinned inline-icon derivation."""
    return [row[::2] for row in pixels[::2]]


def _g13_upscale2x(pixels) -> list[list[str]]:
    """The exact ×2 nearest upscale of a 32-grid hex matrix (every source
    pixel becomes a 2×2 block) — the pinned hero-64 fallback derivation
    (the mirror of `_g13_halve64`'s convention)."""
    out: list[list[str]] = []
    for row in pixels:
        block_row: list[str] = []
        for c in row:
            block_row.extend([c, c])
        out.append(list(block_row))
        out.append(list(block_row))
    return out


def _g13_land_ring_hex(x: int, y: int) -> str:
    """The authored phase-0 ring lattice, mapped to the 64 canvas: HI iff
    (3(x//2) + 5(y//2)) % 16 == 3 (the manifest `ring` notes; the ×2
    upscale of the authored ring is byte-identical to this)."""
    return G13_LAND_RAMP[1] if (3 * (x // 2) + 5 * (y // 2)) % 16 == 3 \
        else G13_LAND_RAMP[0]

# §6.6 shore codes: indices 1-8 = n, ne, e, se, s, sw, w, nw (compass order,
# also the priority order), x wrap-aware, y out of range = non-land.
G13_SHORE_CODE_DELTAS = (
    (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1),
)
SHORE_WATER_CHARS = "~."
SHORE_HARD_CHARS = "#^I"


class _G13Sprite:
    """Decoded artifact pixels (RGBA hex per pixel, None = transparent)."""

    __slots__ = ("decl", "path", "w", "h", "pixels")

    def __init__(self, decl, path, w, h, pixels):
        self.decl = decl
        self.path = path
        self.w = w
        self.h = h
        self.pixels = pixels  # list of rows of hex-or-None

    def rows_hash(self):
        """Pixel rows as opaque-char rows ('.' = transparent) — the form the
        transform ops work on (alpha itself is not part of the relation)."""
        return ["".join("." if p is None else "x" for p in row)
                for row in self.pixels]


def decode_ui_png(data: bytes) -> tuple[int, int, list[list]]:
    """Decode a PNG written by render.js (indexed PLTE/tRNS or RGBA) into
    per-pixel "#rrggbb"/None rows. Raises PngFormatError structurally.

    Group 13's extension of the world-map reader: colour types 3 (with the
    per-entry-alpha tRNS) and 6, 8-bit, non-interlaced.
    """
    if not data.startswith(_PNG_SIGNATURE):
        raise PngFormatError("not a PNG (bad signature)")
    total = len(data)
    pos = len(_PNG_SIGNATURE)
    header = None
    palette = None
    trns = None
    idat = bytearray()
    saw_iend = False
    while pos < total:
        if pos + 8 > total:
            raise PngFormatError("truncated chunk header")
        chunk_length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        if pos + 12 + chunk_length > total:
            raise PngFormatError(f"truncated {tag!r} chunk")
        payload = data[pos + 8:pos + 8 + chunk_length]
        crc = struct.unpack(">I",
                            data[pos + 8 + chunk_length:pos + 12 + chunk_length])[0]
        if crc != (zlib.crc32(tag + payload) & 0xFFFFFFFF):
            raise PngFormatError(f"bad CRC in chunk {tag!r}")
        pos += 12 + chunk_length
        if tag == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif tag == b"PLTE":
            palette = payload
        elif tag == b"tRNS":
            trns = payload
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            saw_iend = True
            break
    if header is None:
        raise PngFormatError("no IHDR chunk")
    if not saw_iend:
        raise PngFormatError("no IEND chunk (truncated file)")
    width, height, depth, colour, compression, filter_method, interlace = header
    if depth != 8:
        raise PngFormatError(f"bit depth is {depth}, expected 8")
    if compression != 0 or filter_method != 0:
        raise PngFormatError(
            f"unsupported PNG compression/filter method "
            f"{compression}/{filter_method}")
    if interlace != 0:
        raise PngFormatError(f"interlaced PNG not supported (interlace {interlace})")
    if width == 0 or height == 0:
        raise PngFormatError(f"zero image dimension {width}x{height}")
    if colour == 3:
        if palette is None:
            raise PngFormatError("no PLTE chunk (an indexed PNG needs a palette)")
        samples = 1
    elif colour == 6:
        samples = 4
    elif colour == 2:
        # the model-pass gen sheets (the terrain ingest's crop source) are
        # opaque RGB — group 13 re-derives the crops from them
        samples = 3
    else:
        raise PngFormatError(
            f"unsupported colour type {colour} (group 13 reads indexed "
            "type-3, RGB type-2 and RGBA type-6 PNGs only)")
    if not idat:
        raise PngFormatError("no IDAT chunk (image data is empty)")
    try:
        raw = zlib.decompress(bytes(idat))
    except zlib.error as exc:
        raise PngFormatError(f"IDAT stream does not inflate: {exc}") from exc
    stride = width * samples
    if len(raw) != (stride + 1) * height:
        raise PngFormatError(
            f"IDAT inflates to {len(raw)} bytes, expected {(stride + 1) * height}")
    lines = []
    prev = bytes(stride)
    pos = 0
    for _ in range(height):
        filter_type = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if filter_type == 0:
            pass
        elif filter_type == 1:  # Sub
            for i in range(samples, stride):
                line[i] = (line[i] + line[i - samples]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = line[i - samples] if i >= samples else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                left = line[i - samples] if i >= samples else 0
                up = prev[i]
                up_left = prev[i - samples] if i >= samples else 0
                p = left + up - up_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                if pa <= pb and pa <= pc:
                    predictor = left
                elif pb <= pc:
                    predictor = up
                else:
                    predictor = up_left
                line[i] = (line[i] + predictor) & 0xFF
        else:
            raise PngFormatError(
                f"row uses undefined PNG filter type {filter_type}")
        lines.append(bytes(line))
        prev = line
    pixels: list[list] = []
    if colour == 3:
        entries = len(palette) // 3
        alphas = None
        if trns is not None and len(trns) > 0:
            alphas = trns
        for line in lines:
            row: list = []
            for idx in line:
                if idx >= entries:
                    raise PngFormatError(
                        f"palette index {idx} used but PLTE holds {entries}")
                alpha = 255
                if alphas is not None and idx < len(alphas):
                    alpha = alphas[idx]
                if alpha == 0:
                    row.append(None)
                else:
                    row.append("#%02x%02x%02x" % (
                        palette[idx * 3], palette[idx * 3 + 1],
                        palette[idx * 3 + 2]))
            pixels.append(row)
    else:
        for line in lines:
            row = []
            if colour == 2:
                for x in range(width):
                    r, g, b = line[x * 3:x * 3 + 3]
                    row.append("#%02x%02x%02x" % (r, g, b))
            else:
                for x in range(width):
                    r, g, b, a = line[x * 4:x * 4 + 4]
                    row.append(None if a == 0 else "#%02x%02x%02x" % (r, g, b))
            pixels.append(row)
    return width, height, pixels


def _g13_load_class(class_dir: Path) -> dict:
    """Parse one class's manifests (render.js tolerance: one object, an
    array, or {"sprites": [...]})."""
    decls: dict[str, tuple[dict, Path]] = {}
    paths = sorted(class_dir.rglob("*.json"))
    # Aux authoring docs (rig library, per-hull authoring index, portrait
    # anchors) are inputs, not render declarations — master reconciliation
    # 2026-11-04, ledgered (B/D own them; the governor skips them too).
    paths = [p for p in paths if p.name not in G13_AUX_DOCS]
    # The model-pass cache (90-* §9.2: gitignored, never committed) holds
    # runtime state (progress.json) + raw model output — not manifests.
    paths = [p for p in paths if "model_raw" not in p.relative_to(class_dir).parts]
    if not paths:
        fail("art-manifest", str(class_dir),
             "manifest dir holds no .json declarations (a class dir exists, "
             "so its manifests must too)", 13)
    for path in paths:
        try:
            doc = json.loads(path.read_text())
        except (OSError, ValueError) as exc:
            fail("art-manifest", path.name, f"cannot parse manifest: {exc}", 13)
        if isinstance(doc, list):
            items = doc
        elif isinstance(doc, dict) and isinstance(doc.get("sprites"), list):
            items = doc["sprites"]
        elif isinstance(doc, dict):
            items = [doc]
        else:
            fail("art-manifest", path.name,
                 "manifest must be a declaration object, an array, or "
                 '{"sprites": [...]}`, got '
                 + type(doc).__name__, 13)
        if isinstance(doc, list):
            items = doc
        elif isinstance(doc, dict) and isinstance(doc.get("sprites"), list):
            items = doc["sprites"]
        elif isinstance(doc, dict):
            items = [doc]
        else:
            fail("art-manifest", path.name,
                 "manifest must be a declaration object, an array, or "
                 '{"sprites": [...]}`, got '
                 + type(doc).__name__, 13)
        for decl in items:
            sprite_id = decl.get("id") if isinstance(decl, dict) else None
            if not isinstance(sprite_id, str) or not sprite_id:
                fail("art-manifest", path.name,
                     "declaration without a non-empty string id", 13)
            if sprite_id in decls:
                fail("art-manifest", path.name,
                     f"duplicate sprite id {sprite_id!r} (also in "
                     f"{decls[sprite_id][1].name})", 13)
            decls[sprite_id] = (decl, path)
    return decls


def _g13_decl_rows(decl: dict) -> list[str] | None:
    rows = decl.get("rows")
    if rows is None:
        return None
    if (not isinstance(rows, list) or not rows
            or any(not isinstance(r, str) for r in rows)
            or len({len(r) for r in rows}) != 1):
        fail("art-manifest", decl.get("id", "?"),
             "rows must be an array of equal-length strings", 13)
    return rows


def _g13_check_manifests(class_name: str, class_dir: Path, decls: dict,
                         block: frozenset) -> None:
    """Manifest-level checks: shape, output path, declared size, palette
    membership (string-maps carry exact hexes), budgets, derive refs."""
    seen_files: dict[str, str] = {}
    allowed = block | BLOCK_LOCKED
    for sprite_id, (decl, path) in sorted(decls.items()):
        if isinstance(decl, dict) and (decl.get("maps")
                                       or decl.get("id") == "hulls-registry"):
            # Hull authoring doc / registry: no direct artifact — the wood
            # intermediate is never shipped; the expanded owner grid is
            # checked at artifact level (master reconciliation, ledgered).
            continue
        label = f"tools/ui_art/{class_name}/{path.name}:{sprite_id}"
        d_probe = decl.get("derive")
        if isinstance(d_probe, dict) and \
                isinstance(d_probe.get("from", d_probe.get("base")), str):
            # Derive-only declaration: no render content — mode/size/palette
            # do not apply (the artifact is checked fully when generated, and
            # the transform relation is checked against its base). Master
            # reconciliation 2026-11-04, ledgered.
            continue
        if not decl.get("file") and "note" in decl and "rows" not in decl:
            # Id-only inventory declaration (the hero-64 display rule,
            # 2026-11-08): the marker/facility glyphs ship via their *64
            # hero families — the manifest stays as the id authority and
            # carries no render output.
            continue
        file = decl.get("file")
        if not isinstance(file, str) or not file:
            fail("art-manifest", label, "file: required output path", 13)
        parts = file.split("/")
        if (file.startswith("/") or ".." in parts
                or not file.startswith("assets/ui/")):
            fail("art-manifest", label,
                 f"file {file!r} must be a repo-root-relative path under "
                 "assets/ui/", 13)
        if file in seen_files and seen_files[file] != sprite_id:
            fail("art-manifest", label,
                 f"output file {file!r} also declared by "
                 f"{seen_files[file]!r}", 13)
        seen_files[file] = sprite_id
        mode = decl.get("mode")
        if mode not in ("string-map", "template"):
            fail("art-manifest", label,
                 f"mode must be \"string-map\" or \"template\", got {mode!r}",
                 13)
        width = decl.get("width")
        height = decl.get("height")
        if not (isinstance(width, int) and isinstance(height, int)
                and width > 0 and height > 0):
            fail("art-manifest", label,
                 "width/height: required positive ints (the A.x contract "
                 "pins every sprite's canvas)", 13)
        rows = _g13_decl_rows(decl)
        if mode == "string-map":
            if rows is None:
                if "derive" not in decl:
                    fail("art-manifest", label,
                         "string-map declaration without rows (and without "
                         "a derive reference)", 13)
            else:
                if len(rows) != height or len(rows[0]) != width:
                    fail("art-manifest", label,
                         f"rows are {len(rows[0])}x{len(rows)}, declared "
                         f"{width}x{height}", 13)
                palette = decl.get("palette")
                if not isinstance(palette, dict) or not palette:
                    fail("art-manifest", label,
                         "palette: required char→hex object", 13)
                used: set[str] = set()
                for row in rows:
                    for ch in row:
                        used.add(ch)
                missing = used - set(palette) - {"."}
                if missing:
                    fail("art-manifest", label,
                         f"row chars {sorted(missing)} missing from palette",
                         13)
                for ch, spec in sorted(palette.items()):
                    if spec == "transparent":
                        continue
                    if (not isinstance(spec, str) or len(spec) != 7
                            or not spec.startswith("#")):
                        fail("art-manifest", label,
                             f"palette[{ch!r}]: expected \"#rrggbb\" or "
                             f"\"transparent\", got {spec!r}", 13)
                    low = spec.lower()
                    # The sea_pattern mask (declared class
                    # "terrain_pattern") stores shader mask VALUES
                    # (#ffffff full / #000000 level 0), not art — exempt
                    # from the terrain block, pinned to the mask pair
                    # instead (master adjudication 2026-11-04, ledgered;
                    # §4.7.17: the ×0.82 darkening is render math).
                    mask = decl.get("class") == "terrain_pattern"
                    allowed_hex = ({"#ffffff", "#000000"} | BLOCK_LOCKED) \
                        if mask else allowed
                    if low not in allowed_hex:
                        fail("art-palette-manifest", label,
                             f"hex {low} is outside the {class_name} class "
                             "block (80-* §4.8.4 per-class membership)", 13)
                    palette[ch] = low
                opaque = {low for ch, low in palette.items()
                          if low != "transparent" and ch in used}
                cap = _g13_cap(width, height)
                if len(opaque) > cap:
                    fail("art-budget-manifest", label,
                         f"{len(opaque)} distinct declared colors > the "
                         f"{cap} cap for {width}x{height} (§8.8 item 4)", 13)
        else:
            grid = decl.get("grid")
            if not isinstance(grid, list) or not grid:
                fail("art-manifest", label,
                     "template declaration requires a non-empty grid", 13)
            if not isinstance(decl.get("materials"), dict):
                fail("art-manifest", label,
                     "template declaration requires a materials object", 13)
            scale = decl.get("scale", 1)
            if (not isinstance(scale, int) or scale < 1
                    or len(grid[0]) * scale != width or len(grid) * scale != height):
                fail("art-manifest", label,
                     f"declared {width}x{height} != grid {len(grid[0])}x"
                     f"{len(grid)} x scale {scale}", 13)
        derive = decl.get("derive")
        if derive is not None:
            if (not isinstance(derive, dict)
                    or derive.get("op") not in G13_DERIVE_OPS
                    or not isinstance(derive.get("from"), str)):
                fail("art-manifest", label,
                     f"derive must be {{\"from\", \"op\"}} with op in "
                     f"{sorted(G13_DERIVE_OPS)}, got {derive!r}", 13)
            base_id = derive["from"]
            if base_id not in decls:
                fail("art-manifest", label,
                     f"derive.from {base_id!r} is not declared in this "
                     "class", 13)
            base_rows = _g13_decl_rows(decls[base_id][0])
            if base_rows is not None and rows is not None:
                expect = G13_DERIVE_OPS[derive["op"]](base_rows, width, height)
                if expect != rows:
                    fail("art-manifest", label,
                         f"rows are not {derive['op']}({base_id!r}) — the "
                         "declared transform must match the emitted rows",
                         13)


def _g13_decode_artifact(decl: dict, path: Path) -> _G13Sprite:
    try:
        data = path.read_bytes()
    except OSError as exc:
        fail("art-artifact", f"assets/ui (via {decl['file']})",
             f"cannot read declared artifact: {exc}", 13)
    try:
        width, height, pixels = decode_ui_png(data)
    except PngFormatError as exc:
        fail("art-artifact", decl["file"],
             f"does not decode: {exc} (the hand-edit probe rejects any "
             "byte-level drift — §8.8 item 2)", 13)
    expect_w, expect_h = _g13_expected_size(decl)
    if width != expect_w or height != expect_h:
        fail("art-size", decl["file"],
             f"artifact is {width}x{height}, manifest declares "
             f"{decl.get('width')}x{decl.get('height')} (shipped canvas "
             f"{expect_w}x{expect_h})", 13)
    return _G13Sprite(decl, path, width, height, pixels)


def _g13_expected_size(decl: dict) -> tuple[int, int]:
    """The shipped-canvas size of a declared sprite. The §4.8 64-canvas
    amendment (1664ba9): terrain-class artifacts render at the 64 canvas —
    the exact ×2 nearest upscale of a declared 32-grid (a declaration
    already authored at 64 ships 1:1); every other class ships its declared
    size (hull tokens declare the 64 canvas directly via the registry
    expansion)."""
    width = int(decl.get("width", 0))
    height = int(decl.get("height", 0))
    if str(decl.get("class", "")) == "terrain" \
            and max(width, height) < G13_CANVAS_64:
        return width * 2, height * 2
    return width, height


def _g13_terrain_pixellab_ledger() -> dict:
    """The PixelLab coast-family ledger (80-* §4.8 2026-11-06): the
    tools/build_terrain_pixellab.py output beside the vendored tileset.
    Empty dict when absent or unparseable — the family is then simply not
    in the inventory (staged, like a class dir with no manifests)."""
    path = DATA_DIR.parent / "tools" / "assets" / "pixellab_raw" / \
        "pixellab_coast_ledger.json"
    if not path.is_file():
        return {}
    try:
        doc = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(doc.get("tiles"), dict) or not doc["tiles"]:
        return {}
    return doc


def _g13_vfx_ledger() -> dict:
    """The PixelLab waterline-family ledger (80-* §4.8 2026-11-07): the
    build_ui_art --import-fx-pixellab output. Empty dict when absent or
    unparseable — the family is then simply not in the inventory."""
    path = DATA_DIR.parent / "tools" / "assets" / "pixellab_raw" / \
        "pixellab_vfx_ledger.json"
    if not path.is_file():
        return {}
    try:
        doc = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    v = int(doc.get("version", 1))
    group = doc.get("ships") if v >= 4 \
        else doc.get("sizes") if v >= 2 else doc.get("dirs")
    if not isinstance(group, dict) or not group:
        return {}
    return doc


def _g13_fx_ship_ids() -> list[str]:
    """The 16 ship type ids (data/ship_types.json) — the per-ship wake
    family's key set (80-* §4.8 2026-11-08)."""
    doc = json.loads((DATA_DIR / "ship_types.json").read_text(
        encoding="utf-8"))
    return sorted(s["id"] for s in doc["ship_types"])


def _g13_png_dims(path) -> tuple[int, int]:
    """(w, h) straight from a PNG's IHDR — no full decode."""
    with open(path, "rb") as fh:
        head = fh.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"not a PNG: {path}")
    return (int.from_bytes(head[16:20], "big"),
            int.from_bytes(head[20:24], "big"))


def _g13_check_vfx_family(sprites: dict) -> None:
    """The waterline VFX family audit (80-* §4.8 2026-11-07/08; group 13):
    ledger ↔ committed sheets (sha256), the committed frame table's
    contract, and each sheet's decode dims against its frame grid.
    v1 (superseded same day): 8 dirs × back/front, anchor in the 64 box.
    v2/v3 (superseded): per-size families — v3 the single-layer sheet
    (`fx_waterline_{size}`, everything under the hull), anchor in the
    size's token box.
    v4 — the per-ship wake revision (2026-11-08): ONE sheet per SHIP
    TYPE (`fx_waterline_{ship}`), the table keys cross-checked against
    data/ship_types.json, anchor in the ship's OWN token box."""
    ledger = _g13_vfx_ledger()
    if not ledger:
        fail("vfx-ledger", "pixellab_vfx_ledger.json",
             "the fx class ships fx_waterline_* sheets but the provenance "
             "ledger is missing — run build_ui_art --import-fx-pixellab", 13)
    table_path = ART_ROOT / "assets" / "ui" / "fx" / "fx_waterline.json"
    if not table_path.is_file():
        fail("vfx-table", "fx_waterline.json",
             "the committed frame table is missing", 13)
    table_sha = hashlib.sha256(table_path.read_bytes()).hexdigest()
    if table_sha != ledger.get("table_sha256"):
        fail("vfx-table", "fx_waterline.json",
             f"sha256 {table_sha[:12]}… != ledger table_sha256 "
             f"{str(ledger.get('table_sha256'))[:12]}… — re-run "
             "build_ui_art --import-fx-pixellab", 13)
    try:
        table = json.loads(table_path.read_text())
    except ValueError as exc:
        fail("vfx-table", "fx_waterline.json",
             f"not valid JSON ({exc})", 13)
    version = int(ledger.get("version", 1))
    v4 = version >= 4
    v3 = version >= 3
    v2 = version >= 2
    table_version = int(table.get("version", 0))
    if v4 and table_version < 4:
        fail("vfx-table", "fx_waterline.json",
             "the v4 (per-ship) ledger needs the v4 frame table", 13)
    if v3 and not v4 and table_version < 3:
        fail("vfx-table", "fx_waterline.json",
             "the v3 (single-layer) ledger needs the v3 frame table", 13)
    if v2 and not v3 and table_version < 2:
        fail("vfx-table", "fx_waterline.json",
             "the v2 (per-size) ledger needs the v2 per-size frame table", 13)
    ledger_group = (ledger.get("ships", {}) if v4
                    else ledger.get("sizes", {}) if v2
                    else ledger.get("dirs", {}))
    ledger_keys = sorted(ledger_group)
    groups = (table.get("ships", {}) if v4
              else table.get("sizes", {}) if table_version >= 2
              else table.get("dirs", {}))
    if sorted(groups) != ledger_keys:
        fail("vfx-ledger", "fx_waterline.json",
             "table keys != ledger keys", 13)
    if v4:
        ship_ids = _g13_fx_ship_ids()
        if sorted(groups) != ship_ids:
            fail("vfx-ledger", "fx_waterline.json",
                 f"expected the 16 data/ship_types.json ids, table has "
                 f"{sorted(groups)}", 13)
    if v3 and not v4 and sorted(groups) != ["32", "48", "64"]:
        fail("vfx-ledger", "fx_waterline.json",
             f"expected the 3 sizes 32/48/64, table has {sorted(groups)}", 13)
    if not v2 and len(groups) != 8:
        fail("vfx-ledger", "fx_waterline.json",
             f"expected 8 dirs, table has {len(groups)}", 13)
    for d, entry in sorted(groups.items()):
        if v4:
            token = ART_ROOT / "assets" / "ui" / "hulls" / f"hull_{d}.png"
            if not token.is_file():
                fail("vfx-anchor", f"fx_waterline[{d}]",
                     f"the ship's north token is missing: {token}", 13)
                continue
            try:
                box = _g13_png_dims(token)[0]
            except (OSError, ValueError) as exc:
                fail("vfx-anchor", f"fx_waterline[{d}]",
                     f"token undecodable ({exc})", 13)
                continue
            if str(entry.get("sprite")) != f"hull_{d}":
                fail("vfx-sheet", f"fx_waterline[{d}]",
                     f"sprite {entry.get('sprite')} != hull_{d}", 13)
        else:
            box = int(d) if v2 else 64
        if int(entry.get("frames", 0)) != 8:
            fail("vfx-frames", f"fx_waterline[{d}]",
                 f"frames {entry.get('frames')} != the pinned 8 "
                 "(80-* §4.8 2026-11-07)", 13)
        if not bool(entry.get("loop", False)):
            fail("vfx-loop", f"fx_waterline[{d}]", "loop must be true", 13)
        if int(entry.get("frame_ms", 0)) <= 0:
            fail("vfx-frames", f"fx_waterline[{d}]", "frame_ms <= 0", 13)
        anchor = entry.get("anchor_sprite", {})
        ax, ay = int(anchor.get("x", -1)), int(anchor.get("y", -1))
        if not (0 <= ax <= box and 0 <= ay <= box):
            fail("vfx-anchor", f"fx_waterline[{d}]",
                 f"anchor ({ax},{ay}) outside the {box} box", 13)
        if v3 or v4:
            # single layer: one sheet record, id fx_waterline_{key}
            clip = entry.get("sheet", {})
            sid = f"fx_waterline_{d}"
            sprite = sprites.get(sid)
            if sprite is None:
                fail("vfx-sheet", sid, "sheet missing from the fx class "
                     "decode", 13)
                continue
            fw = int(clip.get("frame", {}).get("w", 0))
            fh = int(clip.get("frame", {}).get("h", 0))
            columns = int(clip.get("columns", 0))
            if fw <= 0 or fh <= 0 or columns <= 0:
                fail("vfx-sheet", sid, "frame/columns missing", 13)
                continue
            rows = (int(entry.get("frames", 0)) + columns - 1) // columns
            if sprite.w != fw * columns or sprite.h != fh * rows:
                fail("vfx-sheet", sid,
                     f"sheet {sprite.w}x{sprite.h} != the "
                     f"{columns}x{rows} grid of {fw}x{fh} frames", 13)
            actual = hashlib.sha256((ART_ROOT / "assets" / "ui" / "fx"
                                     / f"{sid}.png").read_bytes()).hexdigest()
            if ledger_group.get(d, {}).get("sheet_sha256") != actual:
                fail("vfx-sheet", sid,
                     f"sha256 != ledger ({actual[:12]}…)", 13)
            if not str(ledger_group.get(d, {}).get("effect_id", "")):
                fail("vfx-ledger", f"fx_waterline[{d}]",
                     "effect_id missing from the provenance ledger", 13)
            continue
        for layer in ("back", "front"):
            clip = entry.get("layers", {}).get(layer, {})
            sid = f"fx_waterline_{layer}_{d}"
            sprite = sprites.get(sid)
            if sprite is None:
                fail("vfx-sheet", sid, "sheet missing from the fx class "
                     "decode", 13)
                continue
            fw = int(clip.get("frame", {}).get("w", 0))
            fh = int(clip.get("frame", {}).get("h", 0))
            columns = int(clip.get("columns", 0))
            if fw <= 0 or fh <= 0 or columns <= 0:
                fail("vfx-sheet", sid, "frame/columns missing", 13)
                continue
            rows = (int(entry.get("frames", 0)) + columns - 1) // columns
            if sprite.w != fw * columns or sprite.h != fh * rows:
                fail("vfx-sheet", sid,
                     f"sheet {sprite.w}x{sprite.h} != the "
                     f"{columns}x{rows} grid of {fw}x{fh} frames", 13)
            led = (ledger.get("sizes", {}) if v2 and not v4
                   else ledger.get("dirs", {})).get(d, {}).get("sheets", {})
            actual = hashlib.sha256((ART_ROOT / "assets" / "ui" / "fx"
                                     / f"{sid}.png").read_bytes()).hexdigest()
            if led.get(layer) != actual:
                fail("vfx-sheet", sid,
                     f"sha256 != ledger ({actual[:12]}…)", 13)
        effect_id = (ledger.get("sizes", {}) if v2 and not v4
                     else ledger.get("dirs", {})).get(d, {}).get("effect_id",
                                                                 "")
        if not str(effect_id):
            fail("vfx-ledger", f"fx_waterline[{d}]",
                 "effect_id missing from the provenance ledger", 13)


def _g13_raw_pixellab_ingest() -> bool:
    """True when the last ship ingestion was a PixelLab raw mode
    (ledger generated_by marker or per-token pixellab provenance;
    80-* §4.8 2026-11-06 + the same-day top-down revision — palette/
    budget checks are waived for those families: the audit is the
    provenance ledger + fit + pennant)."""
    ledger = G13_INGEST_LEDGER
    if not ledger.is_file():
        return False
    try:
        doc = json.loads(ledger.read_text())
    except ValueError:
        return False
    by = str(doc.get("generated_by", ""))
    if "pixellab" in by or "import-ships-north" in by:
        return True
    tokens = doc.get("tokens") or {}
    return any(isinstance(rec, dict) and rec.get("pixellab")
               for rec in tokens.values())


def _g13_north_ingest() -> bool:
    """True when the last ship ingestion was the top-down north mode
    (80-* §4.8 2026-11-07): one owner-less tier-sized north file per ship
    (`hull_{ship}.png`, 32/48/64 by tier), runtime-rotated — no dir
    tokens exist."""
    ledger = G13_INGEST_LEDGER
    if not ledger.is_file():
        return False
    try:
        doc = json.loads(ledger.read_text())
    except ValueError:
        return False
    return "import-ships-north" in str(doc.get("generated_by", ""))


def _g13_check_pixels(class_name: str, sprite: _G13Sprite, block: frozenset) -> None:
    """§8.8 items 3–4 on a decoded artifact: block membership + budget."""
    allowed = block | BLOCK_LOCKED
    seen: dict[str, int] = {}
    for row in sprite.pixels:
        for px in row:
            if px is None:
                continue
            seen[px] = seen.get(px, 0) + 1
    off = sorted(set(seen) - allowed)
    if off:
        fail("art-palette", sprite.decl["file"],
             f"off-block hex(es) {off} — the {class_name} class checks "
             "against its own §4.8.4 block only", 13)
    cap = _g13_cap(sprite.w, sprite.h)
    if len(seen) > cap:
        fail("art-budget", sprite.decl["file"],
             f"{len(seen)} distinct colors > the {cap} cap for "
             f"{sprite.w}x{sprite.h} (§8.8 item 4)", 13)


def _g13_check_relations(class_name: str, decls: dict,
                         sprites: dict) -> None:
    """§8.8 item 5: every derived sprite is the pixel-exact transform of its
    authored base (transparent/opaque pattern compared)."""
    for sprite_id, (decl, _path) in sorted(decls.items()):
        derive = decl.get("derive") if isinstance(decl, dict) else None
        if not isinstance(derive, dict):
            continue
        base_id = derive.get("from", derive.get("base"))
        if not isinstance(base_id, str):
            continue
        if sprite_id not in sprites or base_id not in sprites:
            continue  # staged: both artifacts required for the relation
        got = sprites[sprite_id].rows_hash()
        base = sprites[base_id]
        expect = G13_DERIVE_OPS[derive["op"]](base.rows_hash(), base.w, base.h)
        if got != expect:
            fail("art-transform", sprites[sprite_id].decl["file"],
                 f"is not {derive['op']}({base_id}) pixel-exact (§8.8 item 5)",
                 13)


def _g13_check_chrome_seams(sprites: dict) -> None:
    """§8.8 item 8 (chrome part): edge tiles are torus-safe along the
    horizontal repeat axis (column 0 == column 15 pattern); bar_line also
    wraps vertically (row 0 == row 15). Corners do not repeat."""
    for sprite_id, sprite in sorted(sprites.items()):
        if sprite_id.endswith("_edge"):
            col0 = [row[0] for row in sprite.pixels]
            col15 = [row[sprite.w - 1] for row in sprite.pixels]
            if col0 != col15:
                fail("art-seam", sprite.decl["file"],
                     "edge tile is not torus-safe: column 0 != column "
                     f"{sprite.w - 1} (80-* §4.8 seam rule)", 13)
        if sprite_id == "bar_line":
            if sprite.pixels[0] != sprite.pixels[sprite.h - 1]:
                fail("art-seam", sprite.decl["file"],
                     "bar_line is not torus-safe: row 0 != row "
                     f"{sprite.h - 1}", 13)


def _g13_check_terrain_rings(class_name: str, decls: dict,
                             sprites: dict) -> None:
    """§8.8 item 8 (terrain part): variants of one kind share a
    byte-identical outer 1px ring. The PixelLab coast family is exempt —
    its 16 tiles are DISTINCT corner tiles of one Wang set (upper = land,
    lower = water), not variants of one kind; their seam guarantee is the
    shared corner-vertex geometry of the placement rule (80-* §4.8
    2026-11-06)."""
    pixellab_ids = set(_g13_terrain_pixellab_ledger().get("tiles", {}))
    kinds: dict[str, list[_G13Sprite]] = {}
    for sprite_id, sprite in sorted(sprites.items()):
        if sprite_id in pixellab_ids:
            continue
        parts = sprite_id.split("_")
        if len(parts) >= 3 and parts[0] == "terrain":
            kinds.setdefault("_".join(parts[1:-1]), []).append(sprite)
    for kind, group in sorted(kinds.items()):
        if len(group) < 2:
            continue
        first = group[0]
        for other in group[1:]:
            if other.w != first.w or other.h != first.h:
                fail("art-seam", other.decl["file"],
                     f"terrain kind {kind}: variant size {other.w}x{other.h} "
                     f"!= {first.w}x{first.h}", 13)
            ring = _g13_ring_pixels(first)
            if _g13_ring_pixels(other) != ring:
                fail("art-seam", other.decl["file"],
                     f"terrain kind {kind}: variants do not share the "
                     "byte-identical wrap-continuous outer 1px ring "
                     "(80-* §4.8 seam rule)", 13)


def _g13_ring_pixels(sprite: _G13Sprite) -> list:
    """The outer 1px ring as an ordered list (wrap-continuous walk)."""
    w, h = sprite.w, sprite.h
    ring = list(sprite.pixels[0])
    ring += [row[w - 1] for row in sprite.pixels[1:h - 1]]
    ring += sprite.pixels[h - 1][::-1]
    ring += [row[0] for row in sprite.pixels[h - 2:0:-1]]
    return ring


def _g13_check_hull_grid(decls: dict, ship_types: list, nations: list) -> None:
    """§8.8 item 6: the full 16x9x8 grid (+ facility tokens) declared —
    either as 1 158 per-id declarations, or via slot B's hull-doc registry
    shape; the governor expands owners × dirs onto assets/ui/tokens/.
    Coverage semantics (amended hull block, 2026-11-04): owner variants are
    the PENNANT REMAP of one shared authored map — wood/sail/ink are
    owner-invariant, the authored source hex never survives a remap (the
    artifact-level check is _g13_check_pennants).  Hull-doc shape (§8.8
    item 5/6 amendment): the amended UW2 docs author ALL EIGHT direction
    maps and carry no derive entries (a side-view ship does not rotate
    losslessly — 80-* §4.8.6); legacy docs on the n/ne + pinned-derive shape
    are accepted until re-authored."""
    owners = [n["id"] for n in nations] + list(G13_TOKEN_OWNERS_EXTRA)
    fac_got = {sid for sid in decls if sid.startswith("facility_")}
    if fac_got != set(G13_FACILITY_TOKENS):
        fail("hull-inventory", "tools/ui_art/hulls/",
             f"facility tokens declared {sorted(fac_got)[:6]}… != the pinned "
             f"{sorted(G13_FACILITY_TOKENS)}", 13)
    registry = None
    docs: dict[str, tuple[dict, Path]] = {}
    for sid, (decl, path) in decls.items():
        if not isinstance(decl, dict):
            continue
        if decl.get("maps") and decl.get("ship_type"):
            docs[decl["ship_type"]] = (decl, path)
    registry_path = Path("tools/ui_art/hulls/hulls.json")
    if registry_path.is_file():
        try:
            registry = (json.loads(registry_path.read_text()), registry_path)
        except (OSError, ValueError) as exc:
            fail("hull-inventory", str(registry_path),
                 f"cannot parse the hull registry: {exc}", 13)
    if registry is None:
        # Per-id shape: the literal §8.8 grid declared directly.
        expected = set()
        for ship in ship_types:
            for owner in owners:
                for dir_id in G13_DIR_IDS:
                    expected.add(f"hull_{ship['id']}_{owner}_{dir_id}")
        got = set(decls) - set(G13_FACILITY_TOKENS)
        if got != expected:
            missing = sorted(expected - got)[:6]
            extra = sorted(got - expected)[:6]
            fail("hull-inventory", "tools/ui_art/hulls/",
                 f"declared ids != the ship_types × owners × dirs grid "
                 f"(missing {missing}…, extra {extra}…; §8.8 item 6)", 13)
        return
    rdoc, rpath = registry
    if set(rdoc.get("owners") or []) != set(owners):
        fail("hull-inventory", str(rpath),
             "registry owners != nations ∪ {player, neutral, pirate} "
             "(§8.8 item 6, pennant remap coverage)", 13)
    raw_grid = _g13_raw_pixellab_ingest()
    if _g13_north_ingest():
        # North mode (the live grid): ONE tier-sized north file per ship.
        want_tmpl = "assets/ui/hulls/hull_{ship_type}.png"
    else:
        want_tmpl = ("assets/ui/hulls/hull_{ship_type}_{dir}.png" if raw_grid
                     else "assets/ui/hulls/hull_{ship_type}_{owner}_{dir}.png")
    if rdoc.get("path_template") != want_tmpl:
        fail("hull-inventory", str(rpath),
             f"registry path_template != the pinned hull token path "
             f"({'raw dedupe: shared file + runtime owner fallback' if raw_grid else '9-owner grid'})", 13)
    if raw_grid and not rdoc.get("owner_variant_rule"):
        fail("hull-inventory", str(rpath),
             "the raw-dedupe registry must document owner_variant_rule "
             "(the runtime owner-id fallback onto the shared file)", 13)
    ship_ids = {s["id"] for s in ship_types}
    if set(docs) != ship_ids:
        fail("hull-inventory", "tools/ui_art/hulls/authored/",
             f"hull docs != ship_types (missing "
             f"{sorted(ship_ids - set(docs))[:6]}…, extra "
             f"{sorted(set(docs) - ship_ids)[:6]}…)", 13)
    pin = {("e", "n", "rot_cw"), ("s", "n", "rot_180"),
           ("w", "n", "rot_ccw"), ("nw", "ne", "mirror_x"),
           ("se", "ne", "mirror_y"), ("sw", "ne", "rot_180")}
    uw2_dirs = set(G13_DIR_IDS)
    for ship_id, (doc, path) in sorted(docs.items()):
        maps = doc.get("maps") or {}
        if set(maps) == uw2_dirs:
            # Amended UW2 shape: all eight directions authored, no derive;
            # owner coverage is the pennant remap (wood/sail/ink are
            # owner-invariant) — the artifact-level pennant-presence check
            # runs in the governor and on the shipped grid below.
            deriv = doc.get("derive")
            if deriv is not None:
                fail("hull-doc", path.name, f"{ship_id}: an 8-map hull doc "
                     "must not carry derive entries (§4.8.6 amendment: all "
                     "eight hull directions are authored maps)", 13)
        elif set(maps) == {"n", "ne"}:
            # Legacy shape: two authored maps + the pinned six-op derive.
            got = set()
            for entry in doc.get("derive") or []:
                base = entry.get("from", entry.get("base"))
                got.add((entry.get("dir"), base, entry.get("op")))
            if got != pin:
                fail("hull-doc", path.name, f"{ship_id}: derive set != the "
                     f"§4.8.6 pinned ops (got {sorted(got)[:6]}…)", 13)
        else:
            fail("hull-doc", path.name, f"{ship_id}: authored maps "
                 f"{sorted(set(maps))[:8]}… are neither the amended 8-dir "
                 "UW2 set nor the legacy n + ne set (80-* §4.8.6 "
                 "amendment / A.3)", 13)


def _g13_check_footprints(sprites: dict, ship_types: list) -> None:
    """§8.8 item 7 (§4.8.7 amendment, 2026-11-04): the long-axis extent is
    measured on the SIDE VIEW (e/w — the profile shows the ship's length)
    and lies in the tier band; the stern/bow views (n/s) show the beam and
    the diagonals are the honest 3/4 views — both unbanded (canvas-fit
    only, left to the governor's canvas check).
    WAIVED for the PixelLab raw family (80-* §4.8 2026-11-06): bands are
    retired for model tokens — the audit is ledger provenance + fit +
    masthead pennant; the footprint line stays informational in the
    governor's build report."""
    if _g13_raw_pixellab_ingest():
        return
    tier_of = {s["id"]: s["tier"] for s in ship_types}
    for sprite_id, sprite in sorted(sprites.items()):
        if not sprite_id.startswith("hull_"):
            continue
        parts = sprite_id.split("_")
        if len(parts) != 4:
            continue
        _, ship_id, _owner, dir_id = parts
        if dir_id not in ("e", "w"):
            continue
        band = G13_TIER_BANDS.get(tier_of.get(ship_id))
        if band is None:
            continue
        opaque = [(x, y) for y, row in enumerate(sprite.pixels)
                  for x, px in enumerate(row) if px is not None]
        if not opaque:
            fail("hull-footprint", sprite.decl["file"],
                 "sprite is fully transparent", 13)
        xs = [p[0] for p in _g13_content_px(sprite, opaque)]
        extent = max(xs) - min(xs) + 1
        lo, hi = band
        # big-lateen tolerance (80-* §4.8.7, ledgered 2026-11-05): the
        # latin/galiot rigs draw 1px wide — +1 hi, matching the ingest gate.
        if ship_id in ("latin", "galiot", "sloop") and tier_of[ship_id] == 1:
            hi += 1
        if not lo <= extent <= hi:
            fail("hull-footprint", sprite.decl["file"],
                 f"long axis {extent}px outside the tier-{tier_of[ship_id]} "
                 f"band {lo}-{hi} (80-* §4.8.7)", 13)


# Band-measurement reconciliation (2026-11-05, mirrors the governor's
# BAND_SPECKLE_FLOOR): components below the floor are isolated rembg/snap
# fragments — excluded from the §4.8.7 long axis so the ingest gate and
# this audit measure the SAME content bbox (one source of truth).
G13_BAND_SPECKLE_FLOOR = 4


def _g13_content_px(sprite: _G13Sprite, opaque: list) -> list:
    """Opaque px of every 4-connected component >= the speckle floor."""
    w, h = sprite.w, sprite.h
    opaque_set = set(opaque)
    visited: set = set()
    keep: list = []
    for start in opaque:
        if start in visited:
            continue
        stack = [start]
        visited.add(start)
        comp = []
        while stack:
            pt = stack.pop()
            comp.append(pt)
            x, y = pt
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nb = (x + dx, y + dy)
                if 0 <= nb[0] < w and 0 <= nb[1] < h and nb in opaque_set \
                        and nb not in visited:
                    visited.add(nb)
                    stack.append(nb)
        if len(comp) >= G13_BAND_SPECKLE_FLOOR:
            keep.extend(comp)
    return keep


def _g13_check_pennants(sprites: dict, uw2_ships: set) -> None:
    """§8.8 item 6 (amended hull block, pennant remap coverage): every owner
    variant of an amended-shape (8-map) hull carries its PENNANT_* hex, and
    the authored source hex survives the remap only on the spain variant
    (identity).  Legacy-shape docs carry no pennant yet — exempt pending
    re-authoring."""
    for sprite_id, sprite in sorted(sprites.items()):
        if not sprite_id.startswith("hull_"):
            continue
        parts = sprite_id.split("_")
        if len(parts) != 4:
            continue
        _, ship_id, owner, _dir = parts
        pennant = G13_PENNANTS.get(owner)
        if pennant is None:
            continue  # facility tokens carry no pennant
        if ship_id not in uw2_ships:
            continue  # legacy-shape docs: pennant coverage pending re-authoring
        hexes = {px for row in sprite.pixels for px in row if px is not None}
        if pennant not in hexes:
            fail("hull-pennant", sprite.decl["file"],
                 f"the {owner} pennant hex {pennant} is missing — owner "
                 "coverage is the masthead-pennant remap (§8.8 item 6, "
                 "amended hull block)", 13)
        if G13_PENNANT_SOURCE in hexes and pennant != G13_PENNANT_SOURCE:
            fail("hull-pennant", sprite.decl["file"],
                 f"the authored pennant source hex {G13_PENNANT_SOURCE} "
                 f"survived the remap on a {owner} variant (§8.8 item 6)",
                 13)


def _g13_ingest_sprite(path: Path, label: str) -> _G13Sprite:
    """Decode a shipped token file for the ingest audit (64×64 pin)."""
    try:
        data = path.read_bytes()
    except OSError as exc:
        fail("art-ingest", label, f"cannot read token: {exc}", 13)
    try:
        width, height, pixels = decode_ui_png(data)
    except PngFormatError as exc:
        fail("art-ingest", label, f"token does not decode: {exc}", 13)
    if (width, height) != (G13_CANVAS_64, G13_CANVAS_64):
        fail("art-ingest", label,
             f"token is {width}x{height}, the shipped canvas is "
             f"{G13_CANVAS_64}x{G13_CANVAS_64}", 13)
    return _G13Sprite({"file": str(path)}, path, width, height, pixels)


def _g13_masthead_count(sprite: _G13Sprite) -> int:
    """Pennant-source px in the masthead region (top 45% of the opaque
    bbox) — mirrors the governor's ingestion gate (a bottom-hull red blob
    is not a pennant)."""
    opaque = [(x, y) for y, row in enumerate(sprite.pixels)
              for x, px in enumerate(row) if px is not None]
    if not opaque:
        return 0
    x0 = min(p[0] for p in opaque)
    x1 = max(p[0] for p in opaque)
    y0 = min(p[1] for p in opaque)
    y1 = max(p[1] for p in opaque)
    cut = y0 + int(G13_MASTHEAD_TOP_FRAC * (y1 - y0 + 1) + 0.5)
    n = 0
    for y in range(y0, min(cut, y1 + 1)):
        for x in range(x0, x1 + 1):
            if sprite.pixels[y][x] == G13_PENNANT_SOURCE:
                n += 1
    return n


def _g13_check_flip_pair(derived: Path, base: Path, label: str) -> None:
    """f6c00bb: the derived token is the EXACT horizontal flip of its base
    (same owner), alpha included — drift-proof mirror pairs."""
    d = _g13_ingest_sprite(derived, label)
    b = _g13_ingest_sprite(base, str(base))
    for y in range(d.h):
        drow, brow = d.pixels[y], b.pixels[y]
        for x in range(d.w):
            if drow[x] != brow[d.w - 1 - x]:
                fail("art-ingest", label,
                     f"derived token is not the exact h-flip of its base "
                     f"at ({x},{y}) (f6c00bb)", 13)


def _g13_check_ingest_icon_family(doc: dict, icon_ids: set) -> int:
    """The icon ingest family (ledger v2): every `icons{}` record names a
    contract icon, carries sha-256 + seed + source dir + date, its 32px
    file ships, and the file is the EXACT re-quantize + 2:1 halving of
    its snapped source where the gitignored cache exists (the halving
    assert rides the sha chain: sha matches → re-quantize + halve →
    byte-compare).  Returns the number of sources re-derived locally."""
    icons = doc.get("icons") or {}
    rejected = doc.get("icons_rejected") or []
    skipped = doc.get("icons_skipped") or []
    ci = doc.get("counts", {}).get("icons") or {}
    if not isinstance(icons, dict):
        fail("art-ingest", "tools/ui_art/ingest_ledger.json",
             "icons section must be an object", 13)
    if (ci.get("accepted") != len(icons)
            or ci.get("rejected") != len(rejected)
            or ci.get("skipped") != len(skipped)
            or ci.get("files") != len(icons)):
        fail("art-ingest", "tools/ui_art/ingest_ledger.json",
             "counts.icons drifts from the icons/icons_rejected/"
             "icons_skipped maps", 13)
    for note in skipped:
        if (not isinstance(note, dict) or not note.get("job")
                or not note.get("reason")):
            fail("art-ingest", "tools/ui_art/ingest_ledger.json",
                 f"icons_skipped entry {note!r} needs job + reason", 13)
    # derivation-only ids (manifest derive ops — the arrow families) must
    # NEVER appear as ingest records: the build owns those assets files
    # (§8.8 item 5 — an independently generated sibling breaks the
    # rot/mirror transform pin)
    derive_only: set = set()
    for mf in sorted((UI_ART_DIR / "icons").glob("*.json")):
        try:
            mdoc = json.loads(mf.read_text())
        except (OSError, ValueError):
            continue
        mitems = mdoc if isinstance(mdoc, list) else mdoc.get("sprites", [mdoc])
        for d in mitems:
            if isinstance(d, dict) and d.get("derive") and d.get("id"):
                derive_only.add(d["id"])
    ingested_derive_only = sorted(set(icons) & derive_only)
    if ingested_derive_only:
        fail("art-ingest", "tools/ui_art/ingest_ledger.json",
             f"derivation-only icon(s) ingested: {ingested_derive_only[:6]} — "
             "the build derives them from their n/ne sources (§8.8 item 5)",
             13)
    verified = 0
    for iid, rec in sorted(icons.items()):
        if iid not in icon_ids:
            fail("art-ingest", f"icons.{iid}",
                 "ingested icon id is outside the A.2 contract", 13)
        if rec.get("job") != f"icon_{iid}":
            fail("art-ingest", f"icons.{iid}",
                 f"job {rec.get('job')!r} != 'icon_{iid}'", 13)
        sha = rec.get("snapped_sha")
        if (not isinstance(sha, str) or len(sha) != 64
                or any(c not in "0123456789abcdef" for c in sha)):
            fail("art-ingest", f"icons.{iid}",
                 f"snapped_sha {sha!r} is not a sha-256 hex digest", 13)
        seed = rec.get("seed")
        if seed is not None and not is_int(seed):
            fail("art-ingest", f"icons.{iid}",
                 f"seed {seed!r} is neither an int nor null", 13)
        at = rec.get("accepted_at")
        if not isinstance(at, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", at):
            fail("art-ingest", f"icons.{iid}",
                 f"accepted_at {at!r} is not an ISO date (YYYY-MM-DD)", 13)
        src = rec.get("source")
        if src not in G13_ICON_CACHE_DIRS:
            fail("art-ingest", f"icons.{iid}",
                 f"source {src!r} is not a pinned icon cache dir "
                 f"({G13_ICON_CACHE_DIRS})", 13)
        # the hero-64 display rule (2026-11-08): the hero IS the shipped
        # icon art — the halved-32 inline family retired
        p = ASSETS_UI / "icons64" / f"{iid}.png"
        if not p.is_file():
            fail("art-ingest", str(p.relative_to(ART_ROOT)),
                 "ingested icon hero missing from the shipped grid "
                 "(the override ladder commits ledger + hero together)", 13)
        try:
            data = p.read_bytes()
            w, h, px = decode_ui_png(data)
        except (OSError, PngFormatError) as exc:
            fail("art-ingest", str(p.relative_to(ART_ROOT)),
                 f"ingested icon hero does not decode: {exc}", 13)
        if (w, h) != (64, 64):
            fail("art-ingest", str(p.relative_to(ART_ROOT)),
                 f"ingested icon hero is {w}x{h}, the hero canvas is "
                 "64x64", 13)
        got = {c for row in px for c in row if c is not None}
        off = sorted(got - (BLOCK_ICON | BLOCK_LOCKED))
        if off:
            fail("art-ingest", str(p.relative_to(ART_ROOT)),
                 f"off-block hex(es) {off} — the icon class checks against "
                 "the §4.8.4 icon block", 13)
        # the hero exactness rides the halving assert below (hero == the
        # re-quantized snapped source) — the 32 audits retire
        hero = p
        if not hero.is_file():
            fail("art-ingest", str(hero.relative_to(ART_ROOT)),
                 "ingested icon's hero 64 asset missing (ledger + 32 + "
                 "hero commit together) — re-run "
                 "build_ui_art --import-icons", 13)
        try:
            hw, hh, hpx = decode_ui_png(hero.read_bytes())
        except (OSError, PngFormatError) as exc:
            fail("art-ingest", str(hero.relative_to(ART_ROOT)),
                 f"hero asset does not decode: {exc}", 13)
        if (hw, hh) != (64, 64):
            fail("art-ingest", str(hero.relative_to(ART_ROOT)),
                 f"hero asset is {hw}x{hh}, the hero canvas is 64x64", 13)
        hgot = {c for row in hpx for c in row if c is not None}
        hoff = sorted(hgot - (BLOCK_ICON | BLOCK_LOCKED))
        if hoff:
            fail("art-ingest", str(hero.relative_to(ART_ROOT)),
                 f"hero off-block hex(es) {hoff} — the icon class checks "
                 "against the §4.8.4 icon block", 13)
        # the halving + hero asserts, re-derived from the gitignored source
        sp = (UI_ART_DIR / "model_raw" / "pixellab_icons" / iid
              / "snapped" / "icon.png") if src == "pixellab_icons" \
            else UI_ART_DIR / "model_raw" / src / f"icon_{iid}.png"
        if not sp.is_file():
            continue
        verified += 1
        if hashlib.sha256(sp.read_bytes()).hexdigest() != sha:
            fail("art-ingest", str(sp.relative_to(ART_ROOT)),
                 "ledger snapped_sha drifts from the local snapped source — "
                 "re-run build_ui_art --import-icons", 13)
        try:
            sw, sh, spx = decode_ui_png(sp.read_bytes())
        except (OSError, PngFormatError) as exc:
            fail("art-ingest", str(sp.relative_to(ART_ROOT)),
                 f"snapped source does not decode: {exc}", 13)
        if (sw, sh) != (64, 64):
            fail("art-ingest", str(sp.relative_to(ART_ROOT)),
                 f"snapped source is {sw}x{sh}, the model icon grid is "
                 "64x64", 13)
        q = [[None if c is None else _g13_nearest_hex(c, BLOCK_ICON)
              for c in row] for row in spx]
        # the hero-64 rule: the hero IS the shipped art — exact 1:1
        # re-quantize of the snapped source (the halving assert retired)
        if px != q:
            fail("art-ingest", str(p.relative_to(ART_ROOT)),
                 "is not the exact re-quantize of its snapped source "
                 "(hero 64 1:1) — re-run build_ui_art --import-icons", 13)
    # the hero-64 fallback sweep retired (the 2026-11-08 resolution):
    # every icon id is ledger-committed — the icons64 ladder serves them
    # and the per-id hero checks above own the contract
    return verified


def _g13_check_ingest_glyph_families(doc: dict) -> int:
    """The glyph ingest families (80-* §4.8 2026-11-08): every
    `markers{}` / `facility{}` record names a pinned inventory id,
    carries sha-256 + seed + the pixellab_glyphs source + date, its 32px
    file ships in its family dir, and the file is on the OWNING class
    block within the 32px cap and is the EXACT re-quantize + 2:1 halving
    of its snapped source where the gitignored cache exists.  Returns the
    number of exactness chains re-derived locally."""
    fam_dirs = {"markers": "markers", "facility": "tokens"}
    fam_blocks = {"markers": BLOCK_TERRAIN, "facility": BLOCK_HULL}
    fam_caps = {"markers": G13_CAP_32, "facility": G13_CAP_32}
    fam_hero_dirs = {"markers": "markers64", "facility": "tokens64"}
    fam_hero_prefixes = {"markers": "marker_", "facility": "facility_"}
    # the pinned inventories, read from the authored manifests
    inventories: dict[str, set] = {"markers": set(), "facility": set()}
    for mf in sorted((UI_ART_DIR / "markers").glob("*.json")):
        try:
            mdoc = json.loads(mf.read_text())
        except (OSError, ValueError):
            continue
        items = mdoc if isinstance(mdoc, list) else mdoc.get("sprites", [mdoc])
        for d in items:
            if isinstance(d, dict) and d.get("id"):
                inventories["markers"].add(str(d["id"]))
    for mf in sorted((UI_ART_DIR / "hulls").glob("facility_*.json")):
        try:
            mdoc = json.loads(mf.read_text())
        except (OSError, ValueError):
            continue
        items = mdoc if isinstance(mdoc, list) else mdoc.get("sprites", [mdoc])
        for d in items:
            if isinstance(d, dict) and d.get("id"):
                inventories["facility"].add(str(d["id"]))
    verified = 0
    for family in ("markers", "facility"):
        fam = doc.get(family) or {}
        rejected = doc.get(f"{family}_rejected") or []
        skipped = doc.get(f"{family}_skipped") or []
        cf = (doc.get("counts", {}) or {}).get(family) or {}
        if not isinstance(fam, dict):
            fail("art-ingest", "tools/ui_art/ingest_ledger.json",
                 f"{family} section must be an object", 13)
        if (cf.get("accepted") != len(fam)
                or cf.get("rejected") != len(rejected)
                or cf.get("skipped") != len(skipped)
                or cf.get("files") != len(fam)):
            fail("art-ingest", "tools/ui_art/ingest_ledger.json",
                 f"counts.{family} drifts from the {family}/"
                 f"{family}_rejected/{family}_skipped maps", 13)
        for note in skipped:
            if not (isinstance(note, dict) and note.get("job")
                    and note.get("reason")):
                fail("art-ingest", "tools/ui_art/ingest_ledger.json",
                     f"{family}_skipped entry {note!r} needs job + reason",
                     13)
        for iid, rec in sorted(fam.items()):
            if iid not in inventories[family]:
                fail("art-ingest", f"{family}.{iid}",
                     "ingested glyph id is outside the pinned inventory", 13)
            if rec.get("job") != iid:
                fail("art-ingest", f"{family}.{iid}",
                     f"job {rec.get('job')!r} != {iid!r}", 13)
            sha = rec.get("snapped_sha")
            if (not isinstance(sha, str) or len(sha) != 64
                    or any(c not in "0123456789abcdef" for c in sha)):
                fail("art-ingest", f"{family}.{iid}",
                     f"snapped_sha {sha!r} is not a sha-256 hex digest", 13)
            seed = rec.get("seed")
            if seed is not None and not is_int(seed):
                fail("art-ingest", f"{family}.{iid}",
                     f"seed {seed!r} is neither an int nor null", 13)
            at = rec.get("accepted_at")
            if not isinstance(at, str) or not re.fullmatch(
                    r"\d{4}-\d{2}-\d{2}", at):
                fail("art-ingest", f"{family}.{iid}",
                     f"accepted_at {at!r} is not an ISO date", 13)
            if rec.get("source") != "pixellab_glyphs":
                fail("art-ingest", f"{family}.{iid}",
                     f"source {rec.get('source')!r} is not "
                     "'pixellab_glyphs'", 13)
            # The 32 inline family retired with the hero-64 display rule
            # (2026-11-08): the glyph record audits its HERO only
            # (presence / 64 canvas / owning block / exactness).
            hero = (ASSETS_UI / fam_hero_dirs[family]
                    / f"{iid[len(fam_hero_prefixes[family]):]}.png")
            if not hero.is_file():
                fail("art-ingest", str(hero.relative_to(ART_ROOT)),
                     f"{family} hero 64 asset missing (ledger + 32 + "
                     "hero commit together) — re-run "
                     "build_ui_art --import-glyphs", 13)
            try:
                hw, hh, hpx = decode_ui_png(hero.read_bytes())
            except (OSError, PngFormatError) as exc:
                fail("art-ingest", str(hero.relative_to(ART_ROOT)),
                     f"hero asset does not decode: {exc}", 13)
            if (hw, hh) != (64, 64):
                fail("art-ingest", str(hero.relative_to(ART_ROOT)),
                     f"hero asset is {hw}x{hh}, the hero canvas is "
                     "64x64", 13)
            hgot = {c for row in hpx for c in row if c is not None}
            hoff = sorted(hgot - (fam_blocks[family] | BLOCK_LOCKED))
            if hoff:
                fail("art-ingest", str(hero.relative_to(ART_ROOT)),
                     f"hero off-block hex(es) {hoff} — the {family} class "
                     "checks against its owning §4.8.4 block", 13)
            sp = (UI_ART_DIR / "model_raw" / "pixellab_glyphs" / iid
                  / "snapped" / "icon.png")
            if not sp.is_file():
                continue
            verified += 1
            if hashlib.sha256(sp.read_bytes()).hexdigest() != sha:
                fail("art-ingest", str(sp.relative_to(ART_ROOT)),
                     "ledger snapped_sha drifts from the local snapped "
                     "source — re-run build_ui_art --import-glyphs", 13)
            try:
                sw, sh, spx = decode_ui_png(sp.read_bytes())
            except (OSError, PngFormatError) as exc:
                fail("art-ingest", str(sp.relative_to(ART_ROOT)),
                     f"snapped source does not decode: {exc}", 13)
            if (sw, sh) != (64, 64):
                fail("art-ingest", str(sp.relative_to(ART_ROOT)),
                     f"snapped source is {sw}x{sh}, the glyph grid is "
                     "64x64", 13)
            q = [[None if c is None else _g13_nearest_hex(c,
                                                         fam_blocks[family])
                  for c in row] for row in spx]
            if hpx != q:
                fail("art-ingest", str(hero.relative_to(ART_ROOT)),
                     "is not the exact re-quantize of its snapped source "
                     f"({family} hero 64 1:1) — re-run "
                     "build_ui_art --import-glyphs", 13)
    return verified


def _g13_check_ingest_terrain_family(doc: dict) -> int:
    """The terrain ingest family (ledger v2): every `terrain{}` key is one
    of the 4 live land variants, its 64px file ships on the terrain block
    with the authored phase-0 ring (the seam contract survives the swap),
    and the file is the EXACT crop + ramp quantize + ring stamp of the
    gitignored plains sheet where the cache exists."""
    terrain = doc.get("terrain") or {}
    rejected = doc.get("terrain_rejected") or []
    ct = doc.get("counts", {}).get("terrain") or {}
    if not isinstance(terrain, dict):
        fail("art-ingest", "tools/ui_art/ingest_ledger.json",
             "terrain section must be an object", 13)
    if (ct.get("accepted") != len(terrain)
            or ct.get("rejected", 0) != len(rejected)
            or ct.get("files") != len(terrain)):
        fail("art-ingest", "tools/ui_art/ingest_ledger.json",
             "counts.terrain drifts from the terrain map", 13)
    verified = 0
    for fname, rec in sorted(terrain.items()):
        mo = re.fullmatch(r"terrain_land_([0-3])\.png", fname)
        if mo is None:
            fail("art-ingest", f"terrain.{fname}",
                 "key is not one of the 4 live land variants "
                 "terrain_land_0..3.png (the rocky sheet stays held for "
                 "the blob wave — amending this pin is a doc amendment "
                 "first)", 13)
        variant = int(mo.group(1))
        sha = rec.get("sheet_sha")
        if (not isinstance(sha, str) or len(sha) != 64
                or any(c not in "0123456789abcdef" for c in sha)):
            fail("art-ingest", f"terrain.{fname}",
                 f"sheet_sha {sha!r} is not a sha-256 hex digest", 13)
        seed = rec.get("seed")
        if seed is not None and not is_int(seed):
            fail("art-ingest", f"terrain.{fname}",
                 f"seed {seed!r} is neither an int nor null", 13)
        at = rec.get("accepted_at")
        if not isinstance(at, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", at):
            fail("art-ingest", f"terrain.{fname}",
                 f"accepted_at {at!r} is not an ISO date (YYYY-MM-DD)", 13)
        job = rec.get("job")
        if not isinstance(job, str) or not job.startswith("terrain_"):
            fail("art-ingest", f"terrain.{fname}",
                 f"job {job!r} is not a terrain_* gen job", 13)
        patch = rec.get("patch")
        crop = rec.get("crop")
        if (not isinstance(patch, list) or len(patch) != 2
                or not all(is_int(v) and 0 <= v for v in patch)):
            fail("art-ingest", f"terrain.{fname}",
                 f"patch {patch!r} is not a [px, py] pair", 13)
        if (not isinstance(crop, list) or len(crop) != 2
                or not all(is_int(v) and 0 <= v for v in crop)
                or crop[0] + 64 > G13_TERRAIN_SHEET[0]
                or crop[1] + 64 > G13_TERRAIN_SHEET[1]):
            fail("art-ingest", f"terrain.{fname}",
                 f"crop {crop!r} does not fit the pinned 1024x512 sheet", 13)
        expect_crop = [patch[0] * G13_TERRAIN_PATCH + G13_TERRAIN_CROP_INSET,
                       patch[1] * G13_TERRAIN_PATCH + G13_TERRAIN_CROP_INSET]
        if variant >= 4 or crop != expect_crop:
            fail("art-ingest", f"terrain.{fname}",
                 f"crop {crop} != the pinned clean-interior crop {expect_crop} "
                 "of its patch", 13)
        p = ASSETS_UI / "terrain" / fname
        if not p.is_file():
            fail("art-ingest", str(p.relative_to(ART_ROOT)),
                 "ingested terrain file missing from the shipped grid "
                 "(the override ladder commits ledger + file together)", 13)
        try:
            w, h, px = decode_ui_png(p.read_bytes())
        except (OSError, PngFormatError) as exc:
            fail("art-ingest", str(p.relative_to(ART_ROOT)),
                 f"ingested terrain does not decode: {exc}", 13)
        if (w, h) != (G13_CANVAS_64, G13_CANVAS_64):
            fail("art-ingest", str(p.relative_to(ART_ROOT)),
                 f"ingested terrain is {w}x{h}, the shipped canvas is "
                 f"{G13_CANVAS_64}x{G13_CANVAS_64}", 13)
        got = {c for row in px for c in row if c is not None}
        off = sorted(got - (BLOCK_TERRAIN | BLOCK_LOCKED))
        if off:
            fail("art-ingest", str(p.relative_to(ART_ROOT)),
                 f"off-block hex(es) {off} — the terrain class checks "
                 "against the §4.8.4 terrain block", 13)
        if len(got) > G13_CAP_48:
            fail("art-ingest", str(p.relative_to(ART_ROOT)),
                 f"{len(got)} distinct colors > the 64px cap "
                 f"{G13_CAP_48} (§4.8.3)", 13)
        for x in range(64):
            for y in (0, 63):
                if px[y][x] != _g13_land_ring_hex(x, y):
                    fail("art-ingest", str(p.relative_to(ART_ROOT)),
                         f"ring grammar mismatch at ({x},{y}) — the ingested "
                         "variant must carry the authored phase-0 ring "
                         "(§4.8.2 + the manifest `ring` note)", 13)
        for y in range(1, 63):
            for x in (0, 63):
                if px[y][x] != _g13_land_ring_hex(x, y):
                    fail("art-ingest", str(p.relative_to(ART_ROOT)),
                         f"ring grammar mismatch at ({x},{y}) — the "
                         "ingested variant must carry the authored "
                         "phase-0 ring (§4.8.2 + the manifest `ring` "
                         "note)", 13)
        # the crop assert, re-derived from the gitignored sheet
        sheet = UI_ART_DIR / "model_raw" / G13_TERRAIN_CACHE_SUBDIR \
            / f"{job}.png"
        if not sheet.is_file():
            continue
        verified += 1
        if hashlib.sha256(sheet.read_bytes()).hexdigest() != sha:
            fail("art-ingest", str(sheet.relative_to(ART_ROOT)),
                 "ledger sheet_sha drifts from the local gen sheet — "
                 "re-run build_ui_art --import-terrain", 13)
        try:
            sw, sh, spx = decode_ui_png(sheet.read_bytes())
        except (OSError, PngFormatError) as exc:
            fail("art-ingest", str(sheet.relative_to(ART_ROOT)),
                 f"gen sheet does not decode: {exc}", 13)
        if (sw, sh) != G13_TERRAIN_SHEET:
            fail("art-ingest", str(sheet.relative_to(ART_ROOT)),
                 f"gen sheet is {sw}x{sh}, the pinned sheet canvas is "
                 f"{G13_TERRAIN_SHEET[0]}x{G13_TERRAIN_SHEET[1]}", 13)
        cx, cy = crop
        # tone-rank the crop onto the authored land family's distribution
        # (the governor's _tone_rank_land_quantize, mirrored): rank by
        # channel-sum luminance, ties by scan index; darkest 6% → LO,
        # brightest 6% → HI, middle → base.
        crop_px = []
        for y in range(64):
            for x in range(64):
                crop_px.append(spx[cy + y][cx + x])
        order = sorted(range(64 * 64),
                       key=lambda i: (sum(int(v, 16) for v in
                                          (crop_px[i][1:3],
                                           crop_px[i][3:5],
                                           crop_px[i][5:7])), i))
        n_lo = round(64 * 64 * 0.06)
        n_hi = round(64 * 64 * 0.06)
        tones = [None] * (64 * 64)
        for rank, i in enumerate(order):
            hx = (G13_LAND_RAMP[2] if rank < n_lo
                  else (G13_LAND_RAMP[1] if rank >= 64 * 64 - n_hi
                        else G13_LAND_RAMP[0]))
            tones[i] = hx
        want = []
        for y in range(64):
            row = []
            for x in range(64):
                ring = x in (0, 63) or y in (0, 63)
                row.append(_g13_land_ring_hex(x, y) if ring
                           else tones[y * 64 + x])
            want.append(row)
        if px != want:
            fail("art-ingest", str(p.relative_to(ART_ROOT)),
                 "is not the exact crop + tone-rank land quantize + phase-0 "
                 "ring stamp of the gen sheet — re-run build_ui_art "
                 "--import-terrain", 13)
    return verified


def _g13_check_ingest_ledger(docs: dict[str, object], verbose: bool,
                             icon_ids: set | None = None) -> None:
    """80-* §4.8 ingestion contract (90-* §9.2 AI-ingestion path; the
    committed provenance ledger + the 5-direction amendment f6c00bb): the
    ledger is coherent with the shipped token grid — every base token
    names a real ship/base dir, carries a sha-256 + date, and its 9 owner
    files ship; derived entries are exact h-flips of their base (same
    owner) and never mix with fallback inside a mirror group; the spain
    variant of every ingested base still shows the masthead source (≥3 px
    in the top 45% of the bbox — the pennant remap hit a real masthead);
    the ledger sha matches the snapped source where the gitignored cache
    exists locally (90-* §9.2: sources are never committed).  Canvas,
    block membership and the §4.8.7 band on the ingested files ride the
    generic hull artifact checks above (they decode ALL shipped tokens)."""
    if not G13_INGEST_LEDGER.is_file():
        print("INFO group 13 tools/ui_art/ingest_ledger.json not present — "
              "model-pass ingestion staged (build_ui_art --import-ships)")
        return
    try:
        doc = json.loads(G13_INGEST_LEDGER.read_text())
    except (OSError, ValueError) as exc:
        fail("art-ingest", "tools/ui_art/ingest_ledger.json",
             f"cannot parse: {exc}", 13)
    if doc.get("version") != G13_INGEST_VERSION:
        fail("art-ingest", "tools/ui_art/ingest_ledger.json",
             f"version {doc.get('version')!r} != {G13_INGEST_VERSION}", 13)
    tokens = doc.get("tokens") or {}
    derived = doc.get("derived") or {}
    rejected = doc.get("rejected") or []
    counts = doc.get("counts") or {}
    ship_types = docs["ship_types.json"]["ship_types"]
    ship_ids = {s["id"] for s in ship_types}
    nations = [n["id"] for n in docs["nations.json"]["nations"]]
    owners = set(nations) | set(G13_TOKEN_OWNERS_EXTRA)

    # counts coherence (the header numbers ARE the maps below them)
    derived_job_ids = {rec.get("job") for rec in derived.values()}
    painted = sum(1 for rec in tokens.values()
                  if rec.get("pennant") == "auto-painted")
    if (counts.get("accepted_base") != len(tokens)
            or counts.get("accepted_derived") != len(derived_job_ids)
            or counts.get("rejected") != len(rejected)
            or counts.get("pennant_auto_painted") != painted):
        fail("art-ingest", "tools/ui_art/ingest_ledger.json",
             "counts drift from the tokens/derived/rejected maps", 13)
    want_shipped = (len(tokens) if _g13_raw_pixellab_ingest()
                    else len(tokens) * len(owners))
    if counts.get("shipped_files") != want_shipped:
        fail("art-ingest", "tools/ui_art/ingest_ledger.json",
             f"counts.shipped_files {counts.get('shipped_files')} != the "
             f"shipped grid ({want_shipped}: "
             f"{'one owner-less file per token — raw dedupe' if _g13_raw_pixellab_ingest() else '9 owners per token'})", 13)

    # base token records: real ship × base dir (north mode: real ship —
    # the key IS the shipped file stem), sha-256 + ISO date, and the file
    # on the shipped grid
    north = _g13_north_ingest()
    for tid, rec in sorted(tokens.items()):
        raw_bases = _g13_raw_pixellab_ingest()
        if north:
            if not isinstance(tid, str) or not tid.startswith("hull_") \
                    or tid[len("hull_"):] not in ship_ids:
                fail("art-ingest", "tools/ui_art/ingest_ledger.json",
                     f"bad north token id {tid!r} (hull_{{ship}})", 13)
            ship, d = tid[len("hull_"):], None
        else:
            if not isinstance(tid, str) or not tid.startswith("hull_") \
                    or tid.count("_") < 2:
                fail("art-ingest", "tools/ui_art/ingest_ledger.json",
                     f"bad token id {tid!r}", 13)
            ship, d = tid[len("hull_"):].rsplit("_", 1)
            allowed_dirs = (RAW_INGEST_DIRS if raw_bases
                            else G13_INGEST_BASE_DIRS)
            if ship not in ship_ids or d not in allowed_dirs:
                fail("art-ingest", "tools/ui_art/ingest_ledger.json",
                     f"token {tid!r} is not a real ship's BASE dir "
                     f"({'pixellab 8-native' if raw_bases else 'f6c00bb bases'} "
                     f"{allowed_dirs})", 13)
        if rec.get("job") != tid:
            fail("art-ingest", tid, "token record's job != its key", 13)
        sha = rec.get("snapped_sha")
        if (not isinstance(sha, str) or len(sha) != 64
                or any(c not in "0123456789abcdef" for c in sha)):
            fail("art-ingest", tid,
                 f"snapped_sha {sha!r} is not a sha-256 hex digest", 13)
        seed = rec.get("seed")
        if seed is not None and not is_int(seed):
            fail("art-ingest", tid, f"seed {seed!r} is neither an int nor null", 13)
        # pennant provenance: "model" kept the model's own pennant at the
        # classic gate; "auto-painted" carries the deterministic flag
        # composite; "raw" (pixellab ship-as-drawn, 80-* §4.8 2026-11-06)
        # ships the model's pixels untouched — same token for every owner,
        # the pennant remap is suspended for this family.
        if rec.get("pennant") not in ("model", "auto-painted", "raw"):
            fail("art-ingest", tid,
                 f"pennant {rec.get('pennant')!r} is neither 'model' nor "
                 "'auto-painted'", 13)
        at = rec.get("accepted_at")
        if not isinstance(at, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", at):
            fail("art-ingest", tid,
                 f"accepted_at {at!r} is not an ISO date (YYYY-MM-DD)", 13)
        if north:
            p = ASSETS_UI / "hulls" / f"{tid}.png"
            if not p.is_file():
                fail("art-ingest", str(p.relative_to(ART_ROOT)),
                     "ingested north token file missing from the shipped "
                     "grid (one tier-sized file per ship; the runtime "
                     "rotates it)", 13)
        elif _g13_raw_pixellab_ingest():
            p = ASSETS_UI / "hulls" / f"hull_{ship}_{d}.png"
            if not p.is_file():
                fail("art-ingest", str(p.relative_to(ART_ROOT)),
                     "ingested base token file missing from the shipped "
                     "grid (raw dedupe: the owner-less file is the one "
                     "artifact every owner id resolves onto)", 13)
        else:
            for owner in sorted(owners):
                p = ASSETS_UI / "hulls" / f"hull_{ship}_{owner}_{d}.png"
                if not p.is_file():
                    fail("art-ingest", str(p.relative_to(ART_ROOT)),
                         "ingested base token file missing from the shipped grid",
                         13)

    # derived records: exact h-flips, base-referenced, group-coherent
    tokens_dir = ASSETS_UI / "hulls"
    flip_pairs = 0
    for fid, rec in sorted(derived.items()):
        if not isinstance(fid, str) or not fid.startswith("hull_") \
                or not fid.endswith(".png"):
            fail("art-ingest", "tools/ui_art/ingest_ledger.json",
                 f"bad derived file id {fid!r}", 13)
        ship, owner, d = fid[len("hull_"):-len(".png")].rsplit("_", 2)
        if ship not in ship_ids or owner not in owners:
            fail("art-ingest", "tools/ui_art/ingest_ledger.json",
                 f"derived file {fid!r} is not a real ship/owner pair", 13)
        base_d = G13_INGEST_DERIVED.get(d)
        if base_d is None:
            fail("art-ingest", fid,
                 f"dir {d!r} is not mirror-derived (f6c00bb derives "
                 "e/ne/se from w/nw/sw)", 13)
        if rec.get("flip") != "h":
            fail("art-ingest", fid,
                 f"flip {rec.get('flip')!r} != 'h' (f6c00bb)", 13)
        if rec.get("derived_from") != f"hull_{ship}_{owner}_{base_d}.png":
            fail("art-ingest", fid,
                 f"derived_from {rec.get('derived_from')!r} != the base's "
                 f"same-owner file hull_{ship}_{owner}_{base_d}.png", 13)
        if f"hull_{ship}_{base_d}" not in tokens:
            fail("art-ingest", fid,
                 "mirror-group mixing: a derived entry without its base "
                 "token entry (a rejected base falls BOTH dirs back)", 13)
        dp = tokens_dir / fid
        bp = tokens_dir / rec["derived_from"]
        if not dp.is_file() or not bp.is_file():
            fail("art-ingest", fid,
                 "derived or base token file missing from the shipped grid", 13)
        _g13_check_flip_pair(dp, bp, fid)
        flip_pairs += 1

    # spain variants keep the pennant SOURCE hex (identity remap) — the
    # masthead gate re-proven on the committed artifacts, base dirs only.
    # WAIVED in pixellab raw mode (80-* §4.8 2026-11-06): the model's own
    # flag ships untouched (no source-hex recolor), same token for all
    # owners.
    if not _g13_raw_pixellab_ingest():
        for tid in sorted(tokens):
            ship, d = tid[len("hull_"):].rsplit("_", 1)
            f = tokens_dir / f"hull_{ship}_spain_{d}.png"
            n = _g13_masthead_count(_g13_ingest_sprite(f, str(f)))
            if n < G13_MASTHEAD_MIN_PX:
                fail("art-ingest", str(f.relative_to(ART_ROOT)),
                     f"{n} pennant-source px in the masthead region < "
                     f"{G13_MASTHEAD_MIN_PX} — the ingested token's pennant is "
                     "not a masthead (§4.8 ingestion contract)", 13)

    # snapped-source sha provenance where the gitignored cache exists
    # (classic: model_raw/snapped/hull_{ship}_{dir}.png; pixellab raw:
    # model_raw/pixellab/<label>/snapped/{dir}.png, 80-* §4.8 2026-11-06;
    # north: model_raw/pixellab_topdown/<ship>/snapped/north.png, the
    # same-day top-down amendment)
    raw_px = _g13_raw_pixellab_ingest()
    cache = UI_ART_DIR / "model_raw" / "snapped"
    found = 0
    for tid, rec in sorted(tokens.items()):
        if north:
            ship = tid[len("hull_"):]
            sp = UI_ART_DIR / "model_raw" / "pixellab_topdown" / ship \
                / "snapped" / "north.png"
            if not sp.is_file():
                continue
        elif raw_px:
            ship, d = tid[len("hull_"):].rsplit("_", 1)
            sp = None
            for cand in (ship, f"{ship}_uw2"):
                c = UI_ART_DIR / "model_raw" / "pixellab" / cand \
                    / "snapped" / f"{d}.png"
                if c.is_file():
                    sp = c
                    break
            if sp is None:
                continue
        else:
            sp = cache / f"{tid}.png"
            if not sp.is_file():
                continue
        found += 1
        if hashlib.sha256(sp.read_bytes()).hexdigest() != rec.get("snapped_sha"):
            fail("art-ingest", str(sp.relative_to(ART_ROOT)),
                 "ledger snapped_sha drifts from the local snapped source — "
                 "re-run the import", 13)
        if raw_px:
            # ship-as-drawn artifact re-proof (80-* §4.8 2026-11-06): the
            # shipped owner-less file decodes to EXACTLY the snapped
            # source's pixels — any pipeline pixel edit (remap, quantize,
            # recolor) fails here. Compare PIXELS, not bytes: the import
            # re-encodes the container by design.
            tp = ASSETS_UI / "hulls" / f"{tid}.png"
            if tp.is_file():
                try:
                    got = decode_ui_png(tp.read_bytes())
                    want = decode_ui_png(sp.read_bytes())
                except (OSError, PngFormatError) as exc:
                    fail("art-ingest", str(tp.relative_to(ART_ROOT)),
                         f"does not decode: {exc}", 13)
                if got != want:
                    fail("art-ingest", str(tp.relative_to(ART_ROOT)),
                         "is not pixel-identical to its snapped source — "
                         "ship-as-drawn forbids pipeline pixel edits "
                         "(80-* §4.8)", 13)
    if found < len(tokens):
        print(f"INFO group 13 ingest: {len(tokens) - found}/{len(tokens)} "
              "snapped source(s) absent from the local gitignored model_raw "
              "cache (90-* §9.2) — sha provenance rides the committed ledger")

    if verbose:
        print(f"INFO group 13 ingest: {len(tokens)} base tokens + "
              f"{len(derived)} derived files audited "
              f"({flip_pairs} flip pairs, {len(rejected)} rejections "
              f"recorded, {painted} pennant auto-painted; {found} sha(s) "
              f"verified against the local cache)")

    # The icon + terrain families (ledger v2, 2026-11-05): staged-safe —
    # a tree whose ingest has not run yet carries no sections and the
    # string-map generator art passes the generic artifact checks alone.
    ids = icon_ids if icon_ids is not None else set()
    if doc.get("icons") or doc.get("icons_rejected"):
        n_icon = _g13_check_ingest_icon_family(doc, ids)
        if verbose:
            print(f"INFO group 13 ingest icons: {len(doc.get('icons') or {})} "
                  f"inline 32px icon(s) audited ({n_icon} halving chain(s) "
                  "re-derived from the local snapped cache)")
    else:
        print("INFO group 13 ingest icons: no icons{} section — the icon "
              "family is staged (build_ui_art --import-icons)")
    if doc.get("terrain") or doc.get("terrain_rejected"):
        n_terr = _g13_check_ingest_terrain_family(doc)
        if verbose:
            print(f"INFO group 13 ingest terrain: "
                  f"{len(doc.get('terrain') or {})} land variant(s) audited "
                  f"({n_terr} crop chain(s) re-derived from the local gen "
                  "sheet)")
    else:
        print("INFO group 13 ingest terrain: no terrain{} section — the "
              "terrain family is staged (build_ui_art --import-terrain)")
    if doc.get("markers") or doc.get("facility") \
            or doc.get("markers_rejected") or doc.get("facility_rejected"):
        n_glyph = _g13_check_ingest_glyph_families(doc)
        if verbose:
            print(f"INFO group 13 ingest glyphs: "
                  f"{len(doc.get('markers') or {})} marker(s) + "
                  f"{len(doc.get('facility') or {})} facility token(s) "
                  f"audited ({n_glyph} halving chain(s) re-derived from "
                  "the local snapped cache)")
    else:
        print("INFO group 13 ingest glyphs: no markers{}/facility{} "
              "sections — the glyph families are staged "
              "(build_ui_art --import-glyphs)")


def _g13_check_shore_strips(sprites: dict) -> None:
    """§8.8 item 8 (shore part): foam lives only on the land-facing band and
    the thickness is shared with the corner tiles."""
    bands: dict[str, int] = {}
    boxes: dict[str, tuple] = {}
    for sprite_id, sprite in sorted(sprites.items()):
        if not sprite_id.startswith("shore_"):
            continue
        dir_id = sprite_id[len("shore_"):]
        if dir_id not in G13_DIR_IDS:
            continue
        opaque = [(x, y) for y, row in enumerate(sprite.pixels)
                  for x, px in enumerate(row) if px is not None]
        if not opaque:
            fail("art-seam", sprite.decl["file"], "strip is fully transparent", 13)
        xs = [p[0] for p in opaque]
        ys = [p[1] for p in opaque]
        boxes[dir_id] = (min(xs), min(ys), max(xs), max(ys))
        if dir_id in ("n", "s"):
            bands[dir_id] = (max(ys) - min(ys) + 1) if dir_id == "n" else \
                (sprite.h - min(ys))
        elif dir_id in ("w", "e"):
            bands[dir_id] = (max(xs) + 1) if dir_id == "w" else \
                (sprite.w - min(xs))
    if not bands:
        return
    thickness = max(bands.values())
    for dir_id, band in bands.items():
        if band != thickness:
            fail("art-seam", f"shore_{dir_id}",
                 f"foam band {band}px != the shared thickness {thickness}px "
                 "(80-* §4.8: thickness shared with the corner tiles)", 13)
    for dir_id, (x0, y0, x1, y1) in boxes.items():
        sprite = sprites[f"shore_{dir_id}"]
        for y, row in enumerate(sprite.pixels):
            for x, px in enumerate(row):
                if px is None:
                    continue
                facing = {
                    "n": y < thickness,
                    "s": y >= sprite.h - thickness,
                    "w": x < thickness,
                    "e": x >= sprite.w - thickness,
                    "ne": y < thickness or x >= sprite.w - thickness,
                    "nw": y < thickness or x < thickness,
                    "se": y >= sprite.h - thickness or x >= sprite.w - thickness,
                    "sw": y >= sprite.h - thickness or x < thickness,
                }[dir_id]
                if not facing:
                    fail("art-seam", sprite.decl["file"],
                         f"foam pixel at ({x}, {y}) sits outside the "
                         f"{dir_id}-facing band (transparent elsewhere, "
                         "80-* §4.8)", 13)


def _g13_check_shore_raster(shore_path: Path, world: "WorldGrid") -> None:
    """§8.8 item 9: §6.6 integrity, re-derived independently from world.png
    (the validator's half of the cross-implementation check)."""
    label = "data/maps/world_shore.png"
    try:
        data = shore_path.read_bytes()
    except OSError as exc:
        fail("shore-raster", label, f"cannot read: {exc}", 13)
    try:
        width, height, indices = decode_indexed_png(data)
    except PngFormatError as exc:
        fail("shore-raster", label, f"does not decode: {exc}", 13)
    if width != world.width or height != world.height:
        fail("shore-raster", label,
             f"raster is {width}x{height}, world.png is {world.width}x"
             f"{world.height} (§6.6: one index per §6.1 tile)", 13)
    hard = set(SHORE_HARD_CHARS)
    water = set(SHORE_WATER_CHARS)
    w = width
    for y in range(height):
        base = y * w
        world_row = world.indices[base:base + w]
        shore_row = indices[base:base + w]
        for x in range(w):
            code = shore_row[x]
            kind = WORLD_PALETTE_CHARS[world_row[x]] \
                if world_row[x] < len(WORLD_PALETTE_CHARS) else "?"
            if code > 8:
                fail("shore-raster", label,
                     f"palette index {code} at ({x}, {y}) is outside the "
                     "§6.6 domain 0-8", 13)
            if kind in hard:
                if code != 0:
                    fail("shore-raster", label,
                         f"land/reef/ice cell ({x}, {y}) carries code "
                         f"{code} (§6.6: hard tiles are always 0)", 13)
                continue
            if code:
                dx, dy = G13_SHORE_CODE_DELTAS[code - 1]
                nx = (x + dx) % w
                ny = y + dy
                if not (0 <= ny < height):
                    fail("shore-raster", label,
                         f"cell ({x}, {y}) codes direction {code} toward a "
                         "y-out-of-range neighbour (§6.6: that yields no "
                         "code)", 13)
                nkind = WORLD_PALETTE_CHARS[
                    world.indices[ny * w + nx]] \
                    if world.indices[ny * w + nx] < len(WORLD_PALETTE_CHARS) \
                    else "?"
                if kind not in water:
                    fail("shore-raster", label,
                         f"non-water cell ({x}, {y}, kind {kind!r}) carries "
                         f"code {code} (§6.6 codes water only)", 13)
                if nkind not in hard:
                    fail("shore-raster", label,
                         f"cell ({x}, {y}) codes direction {code} but its "
                         f"neighbour ({nx}, {ny}) is {nkind!r} — codes must "
                         "point at land/reef/ice (§6.6)", 13)
            elif kind in water:
                # completeness: an uncoded water cell next to hard ground
                # must carry the highest-priority qualifying code.
                for priority, (dx, dy) in enumerate(G13_SHORE_CODE_DELTAS,
                                                    start=1):
                    nx = (x + dx) % w
                    ny = y + dy
                    if 0 <= ny < height:
                        nidx = world.indices[ny * w + nx]
                        nkind = WORLD_PALETTE_CHARS[nidx] \
                            if nidx < len(WORLD_PALETTE_CHARS) else "?"
                        if nkind in hard:
                            fail("shore-raster", label,
                                 f"water cell ({x}, {y}) borders hard ground "
                                 f"toward priority-{priority} but carries no "
                                 "code (§6.6 completeness)", 13)


def _g13_check_art_prompts(doc: object, legend_ids: list, pirate_ids: list,
                           discovery_ids: list) -> None:
    """§8.8 item 10: exactly the 24 legend captains + 4 named pirates + 30
    discoveries, one shared style_preamble, per-class canvas dimensions."""
    label = "tools/art_prompts.json"
    if not isinstance(doc, dict):
        fail("art-prompts", label, "top level must be an object", 13)
    preamble = doc.get("style_preamble")
    if not isinstance(preamble, str) or not preamble.strip():
        fail("art-prompts", label,
             "missing the shared style_preamble (§8.8 item 10)", 13)
    entries = None
    for key in ("prompts", "assets", "entries"):
        if isinstance(doc.get(key), list):
            entries = doc[key]
            break
    if entries is None and (isinstance(doc.get("portraits"), list)
                            or isinstance(doc.get("discoveries"), list)):
        # Per-class arrays shape (slot D's manifest) — master reconciliation
        # 2026-11-04, ledgered.
        entries = [e for e in (doc.get("portraits") or [])
                   + (doc.get("discoveries") or []) if isinstance(e, dict)]
    if entries is None:
        fail("art-prompts", label,
             "no prompt entry list (expected a \"prompts\" array)", 13)
    expected = {}
    for sprite_id in legend_ids + pirate_ids:
        expected[sprite_id] = (72, 96)
    for sprite_id in discovery_ids:
        expected[sprite_id] = (64, 64)
    got: dict[str, tuple[int, int]] = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            fail("art-prompts", label, f"entry {index} is not an object", 13)
        sprite_id = entry.get("id")
        if not isinstance(sprite_id, str) or not sprite_id:
            fail("art-prompts", label, f"entry {index} has no id", 13)
        canvas = entry.get("canvas")
        if isinstance(canvas, (list, tuple)) and len(canvas) == 2:
            dims = (canvas[0], canvas[1])
        else:
            dims = (entry.get("width"), entry.get("height"))
        if not all(isinstance(v, int) and v > 0 for v in dims):
            fail("art-prompts", label,
                 f"{sprite_id}: canvas dimensions missing (portraits 72x96, "
                 "discoveries 64x64)", 13)
        if sprite_id in got:
            fail("art-prompts", label, f"duplicate prompt id {sprite_id!r}", 13)
        got[sprite_id] = dims
    if got != expected:
        missing = sorted(set(expected) - set(got))[:6]
        extra = sorted(set(got) - set(expected))[:6]
        fail("art-prompts", label,
             f"prompt ids != the 24 legend captains + 4 named pirates + 30 "
             f"discoveries (missing {missing}…, extra {extra}…; §8.8 item "
             "10)", 13)
    for sprite_id, dims in got.items():
        if dims != expected[sprite_id]:
            fail("art-prompts", label,
                 f"{sprite_id}: canvas {dims[0]}x{dims[1]} != the class pin "
                 f"{expected[sprite_id][0]}x{expected[sprite_id][1]}", 13)


def _g13_rebuild_fixtures(verbose: bool) -> None:
    """§8.8 item 2 / fixture-command shape: the builders' own --check modes,
    run only where the scripts exist (staged)."""
    import subprocess

    for script, artifact_label, what in (
        ("tools/build_ui_art.py", "assets/ui", "generated UI art"),
        ("tools/build_shore.py", "data/maps/world_shore.png",
         "shore raster"),
    ):
        path = ART_ROOT / script
        if not path.is_file():
            print(f"INFO group 13 {script} not present — rebuild-equality "
                  f"for {what} is staged (slot B/C deliverable)")
            continue
        try:
            result = subprocess.run(
                [sys.executable, str(path), "--check"],
                capture_output=True, text=True, cwd=str(ART_ROOT),
                timeout=900,
            )
        except subprocess.TimeoutExpired:
            fail("art-rebuild", artifact_label,
                 f"{script} --check exceeded the 900s budget", 13)
        if verbose and result.stdout:
            for line in result.stdout.strip().splitlines()[-4:]:
                print(f"INFO group 13 {line}")
        if result.returncode != 0:
            tail = (result.stderr or result.stdout or "").strip().splitlines()
            detail = tail[-1] if tail else f"exit {result.returncode}"
            fail("art-rebuild", artifact_label,
                 f"rebuild drift: {detail} ({script} --check exited "
                 f"{result.returncode}; §8.8 item 2 — the double-run is the "
                 "hand-edit detector, regenerate, never hand-edit)", 13)


def check_group13(docs: dict[str, object], verbose: bool) -> None:
    """Generated UI art & shore raster: docs/10-DATA-SCHEMA.md section 8.8.

    Staged activation: a contract class without manifests is skipped with an
    informational note; manifests are checked wherever they exist; artifacts
    wherever they exist. Ends with the six negative probes (always run).
    """
    goods = docs["goods.json"]["goods"]
    equipment = docs["equipment.json"]["equipment"]
    nations = docs["nations.json"]["nations"]
    ship_types = docs["ship_types.json"]["ship_types"]

    icon_expected = set(G13_ICON_PINNED)
    # the wind arrows moved to runtime rotation (the 2026-11-08
    # amendment): ONE north texture ships; the seven sibling ids retired
    icon_expected.add("wind_arrow_n")
    icon_expected |= {f"current_arrow_{d}" for d in G13_DIR_IDS}
    icon_expected |= {f"flag_{n['id']}" for n in nations}
    icon_expected |= {f"flag_neutral"}
    icon_expected |= {f"good_{g['id']}" for g in goods}
    icon_expected |= {e["id"] for e in equipment}

    class_dirs = {}
    if UI_ART_DIR.is_dir():
        # `model_raw/` is the model-pass cache (90-* §9.2: gitignored,
        # never committed) — runtime state, not an art class.
        # `workflows/` is ComfyUI API workflow JSON (pipeline infra,
        # 2026-11-06) — likewise not an art class.
        class_dirs = {p.name: p for p in sorted(UI_ART_DIR.iterdir())
                      if p.is_dir()
                      and p.name not in ("model_raw", "workflows")}
    sprite_cache: dict[str, dict] = {}
    manifest_counts: dict[str, int] = {}
    for class_name, class_dir in sorted(class_dirs.items()):
        decls = _g13_load_class(class_dir)
        manifest_counts[class_name] = len(decls)
        block = CLASS_BLOCK.get(class_name)
        if block is None:
            print(f"INFO group 13 class {class_name!r}: no pinned palette "
                  "block — structural checks only")
        else:
            _g13_check_manifests(class_name, class_dir, decls, block)

        # Contract reconciliation where the doc pins the inventory.
        if class_name == "chrome":
            got = set(decls)
            if got != set(G13_CHROME_TILES):
                fail("chrome-inventory", "tools/ui_art/chrome/",
                     f"manifest ids != the 15 A.1 tiles (missing "
                     f"{sorted(set(G13_CHROME_TILES) - got)[:6]}…, extra "
                     f"{sorted(got - set(G13_CHROME_TILES))[:6]}…)", 13)
        elif class_name == "icons":
            got = set(decls)
            if got != icon_expected:
                fail("icons-inventory", "tools/ui_art/icons/",
                     f"manifest ids != the A.2 contract (missing "
                     f"{sorted(icon_expected - got)[:6]}…, extra "
                     f"{sorted(got - icon_expected)[:6]}…)", 13)
        elif class_name == "hulls":
            _g13_check_hull_grid(decls, ship_types, nations)

        # Artifacts: strict per-directory inventory once anything exists.
        declared: dict[str, list] = {}
        check_decls = dict(decls)
        if class_name == "hulls":
            # Registry shape: the artifact grid is the registry's
            # path_template expanded over ship_types × owners × dirs, plus
            # the facility declarations (master reconciliation, ledgered).
            # Synthetic declarations carry the §4.8.6 derive provenance so
            # the transform-relation check covers the derived 6/8 of each
            # owner family — for LEGACY n/ne docs only.  The §8.8 item 5/6
            # amendment (2026-11-04) exempts hulls authored on the amended
            # UW2 8-map shape: all eight directions are authored maps, no
            # lossless relation exists to check (80-* §4.8.6).
            rdecl = next((d for d, _p in decls.values()
                          if isinstance(d, dict)
                          and d.get("id") == "hulls-registry"), None)
            # hulls.json is an aux doc (skipped by the class loader), so
            # read the pinned template from the registry file directly —
            # the mode-aware default only covers a staged tree.
            reg_tmpl = None
            reg_file = Path("tools/ui_art/hulls/hulls.json")
            if rdecl is not None:
                reg_tmpl = rdecl.get("path_template")
            elif reg_file.is_file():
                try:
                    reg_tmpl = json.loads(reg_file.read_text()).get(
                        "path_template")
                except (OSError, ValueError):
                    reg_tmpl = None
            tmpl = reg_tmpl or (
                "assets/ui/hulls/hull_{ship_type}_{dir}.png"
                if _g13_raw_pixellab_ingest() else
                "assets/ui/hulls/hull_{ship_type}_{owner}_{dir}.png")
            uw2_ships = {decl.get("ship_type")
                         for decl, _p in decls.values()
                         if isinstance(decl, dict) and decl.get("maps")
                         and set(decl["maps"]) == set(G13_DIR_IDS)}
            hull_uw2_ships = uw2_ships  # for the pennant-coverage check
            entries_h: list = []
            hull_pin = {"e": ("n", "rot_cw"), "s": ("n", "rot_180"),
                        "w": ("n", "rot_ccw"), "nw": ("ne", "mirror_x"),
                        "se": ("ne", "mirror_y"), "sw": ("ne", "rot_180")}
            raw_dedupe_grid = _g13_raw_pixellab_ingest()
            if _g13_north_ingest():
                # North mode (80-* §4.8 2026-11-07): the shipped grid is
                # ONE tier-sized north file per ship — the runtime rotates
                # it; the ×8 dir and ×9 owner expansions do not apply.
                tier_of = {s["id"]: int(s["tier"]) for s in ship_types}
                for ship in ship_types:
                    sid = f"hull_{ship['id']}"
                    s_px = G13_NORTH_TIER_SIZE[tier_of[ship["id"]]]
                    entries_h.append(
                        (sid, {"id": sid, "width": s_px, "height": s_px,
                               "file": f"assets/ui/hulls/{sid}.png"}))
            elif raw_dedupe_grid:
                # Raw dedupe (80-* §4.8 2026-11-06): the shipped grid is
                # the owner-less 16 × 8 — the runtime falls owner ids onto
                # the shared file (registry owner_variant_rule), so the
                # ×9 owner expansion does not apply.
                for ship in ship_types:
                    for dir_id in G13_DIR_IDS:
                        sid = f"hull_{ship['id']}_{dir_id}"
                        entries_h.append(
                            (sid, {"id": sid, "width": 64, "height": 64,
                                   "file": tmpl.format(
                                       ship_type=ship["id"], dir=dir_id)}))
            else:
                for ship in ship_types:
                    for nation in nations + [{"id": o} for o in
                                             G13_TOKEN_OWNERS_EXTRA]:
                        sid_n = f"hull_{ship['id']}_{nation['id']}_n"
                        sid_ne = f"hull_{ship['id']}_{nation['id']}_ne"
                        entries_h.append(
                            (sid_n, {"id": sid_n, "width": 64, "height": 64,
                                     "file": tmpl.format(
                                         ship_type=ship["id"], owner=nation["id"],
                                         dir="n")}))
                        entries_h.append(
                            (sid_ne, {"id": sid_ne, "width": 64, "height": 64,
                                      "file": tmpl.format(
                                          ship_type=ship["id"], owner=nation["id"],
                                          dir="ne")}))
                        for dir_id, (base_dir, op) in hull_pin.items():
                            sid = f"hull_{ship['id']}_{nation['id']}_{dir_id}"
                            decl_c = {"id": sid, "width": 64, "height": 64,
                                      "file": tmpl.format(
                                          ship_type=ship["id"],
                                          owner=nation["id"], dir=dir_id)}
                            if ship["id"] not in uw2_ships:
                                decl_c["derive"] = {
                                    "from": (sid_n if base_dir == "n"
                                             else sid_ne),
                                    "op": op}
                            entries_h.append((sid, decl_c))
            # The facility id-only decls do NOT join the hull asset
            # inventory: their tokens64 heroes are audited by the glyph
            # family checks (the hero-64 display rule, 2026-11-08).
            declared.setdefault("assets/ui/hulls", entries_h)
            for sid, decl_c in entries_h:
                check_decls.setdefault(sid, (decl_c, None))
        else:
            for sprite_id, (decl, _path) in decls.items():
                if not decl.get("file") and "note" in decl \
                        and "rows" not in decl:
                    continue  # id-only inventory decl (the hero-64 rule)
                parent = str(Path(decl["file"]).parent)
                declared.setdefault(parent, []).append((sprite_id, decl))
            # §4.8 2026-11-06 — the PixelLab coast family: the vendored
            # tileset's tiles enter the terrain inventory through the
            # build-time ledger (tools/build_terrain_pixellab.py output),
            # the hulls-registry precedent. Palette/budget/ring checks are
            # waived for the family (the model's deliberate pixels ship as
            # drawn — the raw-pixellab hull ruling); its seam guarantee is
            # the Wang corner-vertex geometry, not the variant ring.
            coast_ledger = _g13_terrain_pixellab_ledger() \
                if class_name == "terrain" else None
            if coast_ledger:
                entries_c: list = []
                for sid in sorted(coast_ledger.get("tiles", {})):
                    decl_c = {"id": sid, "class": "terrain",
                              "file": f"assets/ui/terrain/{sid}.png",
                              "width": 64, "height": 64,
                              "pixellab": coast_ledger["tiles"][sid]}
                    entries_c.append((sid, decl_c))
                    check_decls.setdefault(sid, (decl_c, None))
                terrain_entries = declared.setdefault("assets/ui/terrain", [])
                terrain_entries.extend(entries_c)
            # §4.8 2026-11-07/08 — the PixelLab waterline family: the
            # sheets enter the fx inventory through the build-time ledger,
            # the coast-family precedent (raw-pixellab ruling — palette/
            # budget waived; the audit is the dedicated fx ledger +
            # frame-table contract below). v1: 8 dirs × back/front; v2:
            # per-size × back/front; v3: one sheet per size; v4 — the
            # per-ship wake revision: one sheet per ship type
            # (`fx_waterline_{ship}`).
            fx_ledger = _g13_vfx_ledger() if class_name == "fx" else {}
            if fx_ledger:
                # sheet dims come from the committed frame table (the pinned
                # grid contract): w = frame.w × columns, h = frame.h × rows
                fx_table_path = ART_ROOT / "assets" / "ui" / "fx" / \
                    "fx_waterline.json"
                fx_table = json.loads(fx_table_path.read_text()) \
                    if fx_table_path.is_file() else {}
                entries_f: list = []
                fx_version = int(fx_ledger.get("version", 1))
                fx_v2 = fx_version >= 2
                fx_v3 = fx_version >= 3
                fx_v4 = fx_version >= 4
                ledger_group = (fx_ledger.get("ships", {}) if fx_v4
                                else fx_ledger.get("sizes", {}) if fx_v2
                                else fx_ledger.get("dirs", {}))
                table_group = (fx_table.get("ships", {}) if fx_v4
                               else fx_table.get("sizes", {})
                               if int(fx_table.get("version", 0)) >= 2
                               else fx_table.get("dirs", {}))
                layer_names = ("sheet",) if fx_v3 or fx_v4 \
                    else ("back", "front")
                for d in sorted(ledger_group):
                    entry_t = table_group.get(d, {})
                    frames_n = int(entry_t.get("frames", 8))
                    for layer in layer_names:
                        clip = entry_t.get("sheet", {}) if fx_v3 or fx_v4 \
                            else entry_t.get("layers", {}).get(layer, {})
                        fw = int(clip.get("frame", {}).get("w", 0))
                        fh = int(clip.get("frame", {}).get("h", 0))
                        columns = int(clip.get("columns", 3))
                        sid_f = (f"fx_waterline_{d}" if fx_v3 or fx_v4
                                 else f"fx_waterline_{layer}_{d}")
                        decl_f = {"id": sid_f, "class": "fx",
                                  "file": f"assets/ui/fx/{sid_f}.png",
                                  "width": fw * columns,
                                  "height": fh * ((frames_n + columns - 1)
                                      // columns),
                                  "pixellab": True}
                        entries_f.append((sid_f, decl_f))
                        check_decls.setdefault(sid_f, (decl_f, None))
                fx_entries = declared.setdefault("assets/ui/fx", [])
                fx_entries.extend(entries_f)
        sprites: dict[str, _G13Sprite] = {}
        for parent, entries in sorted(declared.items()):
            dir_path = ART_ROOT / parent
            present = sorted(p.name for p in dir_path.glob("*.png")) \
                if dir_path.is_dir() else []
            sheets = set()
            if parent == "assets/ui/chrome":
                sheets = set(G13_CHROME_SHEETS)
            if not present:
                print(f"INFO group 13 {parent}: artifacts not generated yet "
                      f"({len(entries)} declared sprites staged)")
                continue
            expected_names = {Path(decl["file"]).name
                              for _sid, decl in entries
                              if decl.get("file")}
            missing = sorted(set(expected_names) - set(present))
            extra = sorted(set(present) - set(expected_names) - sheets)
            if missing or extra:
                fail("art-inventory", parent,
                     f"artifact set != manifest ids (missing {missing[:6]}…, "
                     f"extra/undeclared {extra[:6]}…; §8.8 item 1)", 13)
            for sprite_id, decl in entries:
                if not decl.get("file") and "note" in decl \
                        and "rows" not in decl:
                    # id-only inventory declaration (the hero-64 display
                    # rule) — no shipped 32 artifact to audit
                    continue
                sprite = _g13_decode_artifact(decl, ART_ROOT / decl["file"])
                if block is not None:
                    if class_name == "hulls" and _g13_raw_pixellab_ingest():
                        pass  # raw pixellab hulls: palette/budget waived
                    elif class_name == "terrain" and \
                            isinstance(decl, dict) and decl.get("pixellab"):
                        pass  # PixelLab coast family: same raw ruling
                    elif class_name == "fx" and \
                            isinstance(decl, dict) and decl.get("pixellab"):
                        pass  # waterline family: same raw ruling
                    else:
                        mask = isinstance(decl, dict) and \
                            decl.get("class") == "terrain_pattern"
                        _g13_check_pixels(class_name, sprite,
                                          {"#ffffff", "#000000"} | BLOCK_LOCKED
                                          if mask else block)
                sprites[sprite_id] = sprite
            if parent == "assets/ui/chrome":
                for sheet in sorted(sheets & set(present)):
                    data = (dir_path / sheet).read_bytes()
                    try:
                        width, height, _px = decode_ui_png(data)
                    except PngFormatError as exc:
                        fail("art-artifact", f"{parent}/{sheet}",
                             f"assembled sheet does not decode: {exc}", 13)
                    if (width, height) != (48, 48):
                        fail("art-size", f"{parent}/{sheet}",
                             f"nine-patch sheet is {width}x{height}, pinned "
                             "48x48 with 16px margins (§4.8.8)", 13)
        sprite_cache[class_name] = sprites
        if sprites:
            _g13_check_relations(class_name, check_decls, sprites)
            if class_name == "chrome":
                _g13_check_chrome_seams(sprites)
            elif class_name == "terrain":
                _g13_check_terrain_rings(class_name, decls, sprites)
            elif class_name == "hulls":
                _g13_check_footprints(sprites, ship_types)
                if not _g13_raw_pixellab_ingest():
                    # raw pixellab hulls: the model's own flag ships for
                    # every owner (no remap) — the per-owner pennant hex
                    # coverage is suspended (80-* §4.8 2026-11-06)
                    _g13_check_pennants(sprites, hull_uw2_ships)
            elif class_name == "shore":
                _g13_check_shore_strips(sprites)
            elif class_name == "fx":
                _g13_check_vfx_family(sprites)

    # Staged classes with artifacts but no manifests yet cannot exist (the
    # artifacts are generated FROM the manifests), so any file outside the
    # manifest-backed directories is noted, not failed.
    backed_dirs = {f"assets/ui/{name}" for name in class_dirs}
    if ASSETS_UI.is_dir():
        for png in sorted(ASSETS_UI.rglob("*.png")):
            parent = str(png.parent.relative_to(ART_ROOT))
            if parent not in backed_dirs:
                print(f"INFO group 13 {png.relative_to(ART_ROOT)}: outside "
                      "the manifest-backed classes (staged)")

    if WORLD_SHORE_PNG.is_file():
        world = _load_world_grid(ART_ROOT / "data" / "maps" / "world.png",
                                 "data/maps/world.png")
        _g13_check_shore_raster(WORLD_SHORE_PNG, world)
    else:
        print("INFO group 13 data/maps/world_shore.png not present — §6.6 "
              "integrity staged (slot C deliverable)")

    if ART_PROMPTS_JSON.is_file():
        try:
            prompts_doc = json.loads(ART_PROMPTS_JSON.read_text())
        except (OSError, ValueError) as exc:
            fail("art-prompts", "tools/art_prompts.json",
                 f"cannot parse: {exc}", 13)
        captains = docs.get("captains.json", {}).get("captains", [])
        pirates = docs.get("named_pirates.json", {}).get("named_pirates", [])
        discoveries = docs.get("discoveries.json", {}).get("discoveries", [])
        _g13_check_art_prompts(
            prompts_doc,
            [c["id"] for c in captains if c.get("legend") is True],
            [p["id"] for p in pirates],
            [d["id"] for d in discoveries],
        )
    else:
        print("INFO group 13 tools/art_prompts.json not present — prompt "
              "coverage staged (slot D deliverable)")

    _g13_check_ingest_ledger(docs, verbose, icon_ids=icon_expected)

    _g13_rebuild_fixtures(verbose)

    if verbose:
        counts = ", ".join(f"{name} {manifest_counts[name]}"
                           for name in sorted(manifest_counts)) or "none"
        arts = sum(len(s) for s in sprite_cache.values())
        print(f"PASS group 13 generated art ({counts}; {arts} artifacts "
              "decoded + budget/membership/relations/seams)")

    # §8.8 negative probes — proven red, every run, on temp fixtures.
    _g13_run_probes()


# --- group-13 negative probes (§8.8, six, red-then-discard) ------------------


def _g13_expect_failure(case: str, needle: str, action) -> bool:
    try:
        action()
    except CheckFailure as exc:
        if needle not in f"{exc.check_id} {exc.details}".lower():
            print(f"FAIL g13-probe {case}: failed with the wrong message "
                  f"({exc.check_id} {exc.details})")
            return False
        print(f"PASS g13-probe {case}: rejected ({exc.check_id})")
        return True
    print(f"FAIL g13-probe {case}: mutation passed validation (must go red)")
    return False


def _g13_write_rgba_png(path: Path, width: int, height: int,
                        pixel_fn) -> None:
    """Tiny RGBA (colour type 6) writer for probe fixtures."""
    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw += bytes(pixel_fn(x, y))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.write_bytes(
        _PNG_SIGNATURE + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


_G13_PROBE_BLOCK = BLOCK_ICON
_G13_PROBE_GOOD_HEX = "#e8e6df"  # TEXT — in the icon block
_G13_PROBE_BAD_HEX = "#123456"   # in no block


def _g13_run_probes() -> None:
    """The §8.8 probe set: every mutation must fail group 13, named.

    The probes run against temp fixtures through the same check functions
    the real tree uses — never against committed data — and discard their
    temps on exit. Baseline first (a negative that fails for the wrong
    reason proves nothing)."""
    results: list[bool] = []
    with tempfile.TemporaryDirectory(prefix="g13_probes_") as tmp:
        root = Path(tmp)
        icons_dir = root / "tools" / "ui_art" / "probeicons"
        icons_dir.mkdir(parents=True)
        assets_dir = root / "assets" / "ui" / "probeicons"
        assets_dir.mkdir(parents=True)

        def decl(sprite_id, rows, palette, derive=None):
            d = {
                "id": sprite_id,
                "file": f"assets/ui/probeicons/{sprite_id}.png",
                "width": 8, "height": 8,
                "mode": "string-map", "png": "indexed",
                "palette": palette, "rows": rows,
            }
            if rows is None:
                del d["rows"]
            if derive:
                d["derive"] = derive
            return d

        def write_manifest(decls):
            (icons_dir / "probe.json").write_text(
                json.dumps({"sprites": decls}))

        def render_probe_png(name, rows, palette_map):
            def px(x, y):
                ch = rows[y][x]
                spec = palette_map[ch]
                if spec == "transparent":
                    return (0, 0, 0, 0)
                return (int(spec[1:3], 16), int(spec[3:5], 16),
                        int(spec[5:7], 16), 255)
            _g13_write_rgba_png(assets_dir / f"{name}.png", 8, 8, px)

        base_rows = ["........",
                    ".xxxxxx.",
                    ".xxxxxx.",
                    ".xxxxxx.",
                    ".xxxxxx.",
                    ".xxxxxx.",
                    ".xxxxxx.",
                    "........"]
        flat = {".": "transparent", "x": _G13_PROBE_GOOD_HEX}

        # Baseline: the unmutated fixture tree validates green.
        write_manifest([decl("probe_base", base_rows, flat)])
        render_probe_png("probe_base", base_rows, flat)
        block = _G13_PROBE_BLOCK

        def baseline_ok():
            decls = _g13_load_class(icons_dir)
            _g13_check_manifests("probeicons", icons_dir, decls, block)
            sprites = {}
            for sid, (d, _p) in decls.items():
                sprite = _g13_decode_artifact(d, root / d["file"])
                _g13_check_pixels("probeicons", sprite, block)
                sprites[sid] = sprite
            _g13_check_relations("probeicons", decls, sprites)
            _g13_check_chrome_seams(sprites)
        try:
            baseline_ok()
            print("PASS g13-probe baseline: the unmutated fixture tree "
                  "validates green")
            results.append(True)
        except CheckFailure as exc:
            print(f"FAIL g13-probe baseline: fixture tree is already red: "
                  f"{exc.details}")
            results.append(False)

        # (1) Off-palette pixel: the artifact carries one hex outside every
        # §4.8 block while the manifest stays clean — the decoded-pixel
        # membership check is what must go red.
        off_rows = [row for row in base_rows]
        off_rows[3] = ".xxzxxx."
        off_palette = {".": "transparent", "x": _G13_PROBE_GOOD_HEX,
                       "z": _G13_PROBE_BAD_HEX}
        write_manifest([decl("probe_off", base_rows, flat)])
        render_probe_png("probe_off", off_rows, off_palette)
        results.append(_g13_expect_failure(
            "off-palette", "art-palette",
            lambda: _g13_manifest_then_pixels(icons_dir, block)))

        # (2) Hand-edited artifact (byte-flip probe): a corrupted IDAT must
        # be rejected at the artifact layer. (The full rebuild-equality
        # detector is build_ui_art.py --check at the wave gate.)
        write_manifest([decl("probe_base", base_rows, flat)])
        good_png = (assets_dir / "probe_base.png").read_bytes()
        idat_at = good_png.find(b"IDAT")
        corrupt = bytearray(good_png)
        corrupt[idat_at + 8 + 4] ^= 0xFF
        (assets_dir / "probe_base.png").write_bytes(bytes(corrupt))
        results.append(_g13_expect_failure(
            "hand-edited-artifact", "art-artifact",
            lambda: _g13_manifest_then_pixels(icons_dir, block)))

        # (3) Broken transform relation: the derived sprite's artifact is
        # not mirror_x(base) (derive-only declaration, governor-style — the
        # artifact-level relation is what must go red).
        mirror_rows = [row[::-1] for row in base_rows]
        tampered = [list(r) for r in mirror_rows]
        tampered[2][6] = "."
        tampered = ["".join(r) for r in tampered]
        write_manifest([
            decl("probe_base", base_rows, flat),
            decl("probe_derived", None, flat,
                 derive={"from": "probe_base", "op": "mirror_x"}),
        ])
        render_probe_png("probe_base", base_rows, flat)
        render_probe_png("probe_derived", tampered, flat)
        results.append(_g13_expect_failure(
            "broken-transform", "art-transform",
            lambda: _g13_manifest_then_pixels(icons_dir, block)))

        # (4) Pennant-remap leak: an owner variant of a hull carrying the
        # authored PENNANT_SOURCE hex (it may survive ONLY on the spain
        # variant — the pixellab pipeline's core invariant: option-B
        # pennant recolor + ×7 owner remap; 80-* §4.8 2026-11-06).
        # Replaces the retired out-of-band-footprint probe (§4.8.7 bands
        # are retired for the pixellab family — same amendment).
        hull_decl = {
            "id": "hull_sloop_england_e",
            "file": "assets/ui/hulls/hull_sloop_england_e.png",
            "width": 8, "height": 8,
            "mode": "string-map", "png": "indexed",
            "palette": {".": "transparent", "b3191f": "#b3191f"},
            "rows": ["........", "..b3191f.", "........"],
        }
        hull_pixels = [[None] * 8 for _ in range(8)]
        hull_pixels[1][2] = "#b3191f"  # authored source hex, england owner

        def pennant_check():
            sprite = _G13Sprite(hull_decl, Path(hull_decl["file"]), 8, 8,
                                hull_pixels)
            _g13_check_pennants({"hull_sloop_england_e": sprite},
                                {"sloop"})
        results.append(_g13_expect_failure(
            "pennant-remap-leak", "hull-pennant", pennant_check))

        # (5) Invalid shore code: a coded hard (land) cell — §6.6 says 0.
        shore_w = shore_h = 8
        world_indices = bytearray(shore_w * shore_h)
        for y in range(shore_h):
            for x in range(shore_w):
                world_indices[y * shore_w + x] = 2 if x == 0 else 0  # col 0 land
        shore_indices = bytearray(shore_w * shore_h)
        shore_indices[3 * shore_w + 0] = 3  # land cell with a code: invalid
        world_grid = WorldGrid(shore_w, shore_h, world_indices)
        shore_path = root / "world_shore.png"
        shore_path.write_bytes(_encode_indexed_png(
            shore_w, shore_h, shore_indices, palette_entries=9))

        def shore_check():
            _g13_check_shore_raster(shore_path, world_grid)
        results.append(_g13_expect_failure(
            "invalid-shore-code", "shore-raster", shore_check))

        # (5b) An unknown palette index (9) fails the §6.6 domain too.
        shore_indices2 = bytearray(shore_w * shore_h)
        shore_indices2[1 * shore_w + 4] = 9
        shore_path.write_bytes(_encode_indexed_png(
            shore_w, shore_h, shore_indices2, palette_entries=10))
        results.append(_g13_expect_failure(
            "invalid-shore-index", "shore-raster", shore_check))

        # (6) Seam violation: a chrome edge tile with column 0 != column 15.
        bad_edge = []
        for y in range(8):
            inner = "x" if y in (2, 3) else "."
            bad_edge.append("z" + "." * 6 + inner)  # col 0 fixed, col 7 varies
        bad_palette = {".": "transparent", "x": _G13_PROBE_GOOD_HEX,
                       "z": _G13_PROBE_GOOD_HEX}
        edge_decl = decl("panel_edge", bad_edge, bad_palette)
        write_manifest([edge_decl])
        render_probe_png("panel_edge", bad_edge, bad_palette)

        def seam_check():
            edge_decls = _g13_load_class(icons_dir)
            _g13_check_manifests("probeicons", icons_dir, edge_decls, block)
            sprites = {}
            for sid, (d, _p) in edge_decls.items():
                sprite = _g13_decode_artifact(d, root / d["file"])
                sprites[sid] = sprite
            _g13_check_chrome_seams(sprites)
        results.append(_g13_expect_failure(
            "seam-violation", "art-seam", seam_check))

    if not all(results):
        fail("g13-probes", "tools/validate_data.py",
             "negative-probe harness: "
             f"{results.count(False)} of {len(results)} cases did not go "
             "red as required (§8.8 probe set)", 13)


def _g13_manifest_then_pixels(icons_dir: Path, block: frozenset) -> None:
    """Manifest checks + artifact checks for the probe fixture class."""
    decls = _g13_load_class(icons_dir)
    _g13_check_manifests("probeicons", icons_dir, decls, block)
    sprites = {}
    for sid, (d, _p) in decls.items():
        sprite = _g13_decode_artifact(d, _g13_probe_root(icons_dir) / d["file"])
        _g13_check_pixels("probeicons", sprite, block)
        sprites[sid] = sprite
    _g13_check_relations("probeicons", decls, sprites)


def _g13_probe_root(icons_dir: Path) -> Path:
    return icons_dir.parents[2]  # <tmp>/tools/ui_art/<class> → <tmp>


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    # --data-root PATH: parse first, then re-exec with the env override set, so
    # every module-level path constant and the group-8 subprocess see one
    # resolution point. Without the flag nothing changes (byte-identical
    # default behavior; §8 preamble / task T staged-sim protocol).
    data_root = None
    rest: list[str] = []
    index = 0
    args = list(argv)
    while index < len(args):
        arg = args[index]
        if arg == "--data-root":
            if index + 1 >= len(args):
                print("--data-root requires a PATH argument")
                return 1
            data_root = args[index + 1]
            index += 2
            continue
        if arg.startswith("--data-root="):
            data_root = arg.split("=", 1)[1]
            index += 1
            continue
        rest.append(arg)
        index += 1

    verbose = "--verbose" in rest
    self_test = "--self-test-g6" in rest or os.environ.get("SAILAGE_G6_SELFTEST") == "1"
    self_test_g9 = "--self-test-g9" in rest
    self_test_g10 = "--self-test-g10" in rest
    known = {"--verbose", "--self-test-g6", "--self-test-g9",
             "--self-test-g10"}
    unknown = [arg for arg in rest[1:] if arg not in known]
    if unknown:
        print("usage: python3 tools/validate_data.py [--verbose] "
              "[--self-test-g6] [--self-test-g9] [--self-test-g10] "
              "[--data-root PATH]")
        return 1

    if data_root is not None and DATA_DIR != _resolve_data_dir(data_root):
        env = dict(os.environ)
        env["SAILAGE_DATA_ROOT"] = data_root
        # rest[0] is the script path (argv[0] passed through), so the child
        # argv is [python, script, *flags].
        os.execve(sys.executable,
                  [sys.executable, *rest],
                  env)

    if self_test:
        return run_group6_self_test()
    if self_test_g9:
        return run_group9_self_test()
    if self_test_g10:
        return run_group10_self_test()

    docs: dict[str, object] = {}
    groups = (
        ("1", check_group1),
        ("2", check_group2),
        ("3", check_group3),
        ("4", check_group4),
        ("5", check_group5),
        ("6", check_group6),
        ("7", check_group7),
        ("8", check_group8),
        ("9", check_group9),
        ("10", check_group10),
        ("11", check_group11),
        ("12", check_group12),
        ("13", check_group13),
    )

    for group_id, check in groups:
        try:
            check(docs, verbose)
        except CheckFailure as exc:
            print(f"FAIL {exc.check_id} {exc.filename} {exc.details}")
            return exc.code
        except Exception as exc:  # defensive: never leak a traceback as exit 0
            import traceback
            traceback.print_exc()
            print(f"FAIL internal group{group_id} tools/validate_data.py {exc!r}")
            return 3

    print(f"OK all check groups passed (1-{len(groups)})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
