#!/usr/bin/env python3
"""SailAge data validator.

Implements check groups 1-7 of docs/10-DATA-SCHEMA.md section 8. Group 6 is
the generated world-map artifact check (section 8.1): it decodes
``data/maps/world.png`` with a stdlib PNG reader, recomputes every harbor tile
independently from ``lat``/``lon`` and compares it with
``data/maps/world_report.json``, then proves every harbor and discovery is
reachable from Lisbon by a wrap-aware 8-directional BFS that forbids corner
cutting (docs/20-WORLD-AND-SAILING.md section 4.2). Group 7 is the Phase-5
npc & economy data check (section 8.2): the density-dial config bounds, the
captain pools, the named pirates, the demand-event templates with their
rest-band shift bounds, and the consumption-tier split.

Usage (from the repo root):

    python3 tools/validate_data.py
    python3 tools/validate_data.py --verbose
    python3 tools/validate_data.py --self-test-g6      # negative harness

Exit codes:

    0  all checks pass
    1  parse & envelope failure
    2  i18n failure
    3  schema failure
    4  referential integrity failure
    5  locked-list failure
    6  world map failure (data/maps/world.png / world_report.json)
    7  npc & economy data failure (npc_config / npc_captains / named_pirates /
       market_events)

On the first failure a single line is printed to stdout:

    FAIL <check-id> <file> <details>

and the process exits with that check group's code.

``--self-test-g6`` (or ``SAILAGE_G6_SELFTEST=1``) runs the group-6 mutation
harness instead of the normal checks: it mutates in-memory copies of the tile
grid, the port list and the PNG and asserts that group 6 goes red, naming the
expected entity. It never touches real data and exits 0 only when every
negative case fails as required.
"""

from __future__ import annotations

import copy
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

REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "data"

# ---------------------------------------------------------------------------
# Contract tables (docs/10-DATA-SCHEMA.md sections 3, 6, 7)
# ---------------------------------------------------------------------------

ID_RE = re.compile(r"^[a-z][a-z0-9_]*$")
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
MARKER_RE = re.compile(r"^[0-9a-t]$")
PLACEHOLDER_RE = re.compile(r"\{([A-Za-z0-9_]+)\}")

MAP_WIDTH = 2160
MAP_HEIGHT = 1080

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
OFFICER_ROLES = ("navigator", "boatswain", "gunner")
EQUIPMENT_SLOTS = ("weapon", "armor", "figurehead", "sail")
DISCOVERY_CATEGORIES = ("natural", "ruins", "relic", "creature")
QUEST_TYPES = ("delivery", "bounty", "exploration", "royal")
QUEST_GIVERS = ("guild", "palace")

# docs/50-CHARACTER-AND-PROGRESSION.md section 4.2 (player) and
# docs/40-SHIPS-AND-FLEET.md (ship instance stats), for equipment modifiers.
PLAYER_STAT_NAMES = ("leadership", "seamanship", "combat", "navigation", "luck")
OFFICER_STAT_NAMES = ("leadership", "seamanship", "combat", "navigation")
SHIP_STAT_NAMES = ("durability", "capacity", "speed", "crew_max", "armament_slots")
EQUIPMENT_STAT_NAMES = frozenset(PLAYER_STAT_NAMES + SHIP_STAT_NAMES)

# Facility activation phases (docs/10-DATA-SCHEMA.md section 4.4).
FACILITY_PHASES = {
    "market": 1,
    "shipyard": 1,
    "tavern": 1,
    "inn": 1,
    "guild": 3,
    "palace": 3,
}
# Every Phase-1 port has these; `palace` only for the 6 capitals.
PORT_FACILITIES_REQUIRED = ("market", "shipyard", "tavern", "inn", "guild")

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
    # Phase 5 (section 8, group 1): npc_captains.json's plural key is `pools`,
    # named_pirates.json / market_events.json match their filenames.
    "npc_captains.json": "pools",
    "named_pirates.json": "named_pirates",
    "market_events.json": "market_events",
}

# Files with a bespoke envelope / no plural entity key (section 3.2, 4.9).
SPECIAL_FILES = {
    "map_legend.json", "ui_strings.json", "maps.json",
}
# Envelope exemption for a file that is *generated* rather than authored: its
# shape is pinned by the owning doc (docs/10-* §6.3) and has no plural array.
GENERATED_FILES = {"world_report.json"}
SPECIAL_FILES |= GENERATED_FILES
# Of those, only the legends require `version` in their section 4.9 schema.
# ui_strings.json (owned by T4) may omit it; section 8 group 2 treats `version`
# as the one key that is not an L10nString rather than a required field.
SPECIAL_REQUIRE_VERSION = {"map_legend.json"}
# Phase 5 (section 8, group 1): npc_config.json is a config block (§4.10), not
# an entity file — its shape is owned by group 7.
SPECIAL_FILES.add("npc_config.json")
SPECIAL_REQUIRE_VERSION.add("npc_config.json")

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
    # Phase 5: a pool's `names` is an array of L10nStrings — the walker's
    # locale-key heuristic covers each entry (no scalar L10n field here);
    # pirates/events carry their display string in `name`.
    "pools": (),
    "named_pirates": ("name",),
    "market_events": ("name",),
}

# --- Locked content tables (docs/10-DATA-SCHEMA.md section 7) --------------
# id: (zh, en, category, base_price)  -- section 7.2
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
}

# id: (zh, en, class, base_price, durability, capacity, speed, crew_min,
#      crew_max, armament_slots)  -- section 7.3
LOCKED_SHIP_TYPES = {
    "latin": ("拉丁帆船", "Latin", "sail", 1200, 40, 30, 8, 8, 20, 2),
    "sloop": ("单桅纵帆船", "Sloop", "sail", 3000, 60, 60, 10, 10, 30, 4),
    "caravel": ("卡拉维尔帆船", "Caravel", "sail", 8000, 90, 120, 10, 15, 45, 6),
    "galley": ("桨帆船", "Galley", "oar", 10000, 70, 50, 12, 40, 120, 4),
    "brigantine": ("双桅帆船", "Brigantine", "sail", 15000, 110, 150, 12, 20, 60, 10),
    "nao": ("瑙船", "Nao", "sail", 22000, 140, 300, 8, 25, 80, 10),
    "carrack": ("卡拉克帆船", "Carrack", "sail", 40000, 180, 450, 8, 30, 100, 16),
    "galleon": ("盖伦帆船", "Galleon", "hybrid", 60000, 240, 400, 10, 40, 150, 24),
}

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

# id: (zh, en, nation_id, lat, lon, produces, demands)  -- section 7.1
# Phase 4: 100 ports keyed by real WGS84 coordinates; the grid tile is derived
# by section 6.1's harbor-snap rule, never stored. Transcribed from section 7.1
# and cross-checked against data/ports.json (group 5 asserts both directions).
LOCKED_PORTS = {
    "lisbon": ("里斯本", "Lisbon", "portugal", 38.72, -9.14,
                 ("wine", "salt"), ("spices", "silk", "timber")),
    "seville": ("塞维利亚", "Seville", "spain", 37.0, -6.35,
                 ("olive_oil", "wine", "wool"), ("sugar", "spices")),
    "valencia": ("瓦伦西亚", "Valencia", "spain", 39.45, -0.33,
                 ("silk", "ceramics"), ("wheat", "timber")),
    "barcelona": ("巴塞罗那", "Barcelona", "spain", 41.35, 2.17,
                 ("wool", "cotton_cloth"), ("iron", "spices")),
    "marseille": ("马赛", "Marseille", "spain", 43.3, 5.37,
                 ("wine", "salt", "perfume"), ("wool", "silk")),
    "bordeaux": ("波尔多", "Bordeaux", "spain", 45.55, -1.15,
                 ("wine", "salt"), ("timber", "wool")),
    "london": ("伦敦", "London", "england", 51.47, 0.75,
                 ("wool", "cotton_cloth"), ("wine", "spices", "timber")),
    "amsterdam": ("阿姆斯特丹", "Amsterdam", "holland", 52.46, 4.6,
                 ("cheese", "glassware"), ("spices", "silk", "wheat")),
    "antwerp": ("安特卫普", "Antwerp", "holland", 51.44, 3.6,
                 ("glassware", "wool"), ("spices", "wine")),
    "hamburg": ("汉堡", "Hamburg", "holland", 53.87, 8.7,
                 ("dried_fish", "timber", "amber"), ("wine", "salt")),
    "genoa": ("热那亚", "Genoa", "italy", 44.41, 8.93,
                 ("olive_oil", "cotton_cloth"), ("spices", "copper")),
    "naples": ("那不勒斯", "Naples", "italy", 40.84, 14.25,
                 ("olive_oil", "wine"), ("wheat", "timber")),
    "palermo": ("巴勒莫", "Palermo", "italy", 38.12, 13.36,
                 ("wheat", "olive_oil"), ("timber", "iron")),
    "syracuse": ("锡拉库萨", "Syracuse", "italy", 37.07, 15.29,
                 ("salt", "wheat"), ("timber", "leather")),
    "cagliari": ("卡利亚里", "Cagliari", "italy", 39.22, 9.11,
                 ("salt", "leather"), ("wheat", "glassware")),
    "valetta": ("瓦莱塔", "Valetta", "italy", 35.9, 14.51,
                 ("cotton_cloth",), ("wheat", "timber", "iron")),
    "venice": ("威尼斯", "Venice", "italy", 45.44, 12.33,
                 ("glassware", "perfume"), ("spices", "silk", "cotton_cloth")),
    "ragusa": ("拉古萨", "Ragusa", "italy", 42.65, 18.09,
                 ("timber", "leather", "wool"), ("wheat",)),
    "athens": ("雅典", "Athens", "ottoman", 37.94, 23.64,
                 ("olive_oil", "wine", "ceramics"), ("timber", "iron")),
    "candia": ("干地亚", "Candia", "ottoman", 35.34, 25.13,
                 ("wine", "olive_oil"), ("wheat", "salt")),
    "cyprus": ("塞浦路斯", "Cyprus", "ottoman", 34.67, 33.04,
                 ("copper", "sugar"), ("wheat", "timber")),
    "smyrna": ("士麦那", "Smyrna", "ottoman", 38.42, 27.14,
                 ("carpet",), ("wheat", "glassware", "iron")),
    "istanbul": ("伊斯坦布尔", "Istanbul", "ottoman", 41.01, 28.97,
                 ("carpet", "perfume"), ("wheat", "iron", "timber")),
    "beirut": ("贝鲁特", "Beirut", "ottoman", 33.9, 35.5,
                 ("silk", "timber"), ("wheat", "salt")),
    "alexandria": ("亚历山大", "Alexandria", "ottoman", 31.2, 29.92,
                 ("cotton_cloth", "sugar", "wheat"), ("timber", "iron", "wine")),
    "tripoli": ("的黎波里", "Tripoli", "ottoman", 32.9, 13.18,
                 ("leather", "salt"), ("wheat", "timber")),
    "tunis": ("突尼斯", "Tunis", "ottoman", 36.82, 10.3,
                 ("olive_oil", "leather"), ("wheat", "iron")),
    "algiers": ("阿尔及尔", "Algiers", "ottoman", 36.77, 3.06,
                 ("leather", "wool"), ("wheat", "timber", "wine")),
    "ceuta": ("休达", "Ceuta", "portugal", 35.89, -5.32,
                 ("wheat", "leather"), ("wine", "cotton_cloth")),
    "madeira": ("马德拉", "Madeira", "portugal", 32.65, -16.91,
                 ("sugar", "wine"), ("wheat", "iron")),
    "havana": ("哈瓦那", "Havana", "spain", 23.13, -82.38,
                 ("sugar", "amber"), ("wine", "cotton_cloth")),
    "vera_cruz": ("韦拉克鲁斯", "Veracruz", "spain", 19.2, -96.13,
                 ("copper", "sugar"), ("iron", "glassware")),
    "cartagena": ("卡塔赫纳", "Cartagena", "spain", 10.39, -75.53,
                 ("amber", "sugar"), ("wine", "wool")),
    "portobelo": ("波托贝洛", "Portobelo", "spain", 9.55, -79.65,
                 ("sugar",), ("silk", "spices")),
    "lima": ("利马", "Lima", "spain", -12.06, -77.15,
                 ("copper", "sugar"), ("glassware", "wine")),
    "buenos_aires": ("布宜诺斯艾利斯", "Buenos Aires", "spain", -34.6, -58.37,
                 ("leather", "wheat"), ("iron", "glassware")),
    "san_juan": ("圣胡安", "San Juan", "spain", 18.47, -66.11,
                 ("sugar", "salt"), ("cotton_cloth", "wine")),
    "santo_domingo": ("圣多明各", "Santo Domingo", "spain", 18.47, -69.88,
                 ("sugar", "leather"), ("silk", "glassware")),
    "acapulco": ("阿卡普尔科", "Acapulco", "spain", 16.85, -99.9,
                 ("silk", "copper"), ("wheat", "glassware")),
    "panama": ("巴拿马", "Panama", "spain", 8.98, -79.52,
                 ("amber", "copper"), ("wine", "iron")),
    "valparaiso": ("瓦尔帕莱索", "Valparaiso", "spain", -33.03, -71.63,
                 ("copper", "wine"), ("glassware", "wool")),
    "guayaquil": ("瓜亚基尔", "Guayaquil", "spain", -2.6, -80.3,
                 ("sugar", "timber"), ("iron", "glassware")),
    "bahia": ("巴伊亚", "Bahia", "portugal", -12.97, -38.5,
                 ("sugar", "timber"), ("glassware", "iron")),
    "rio_de_janeiro": ("里约热内卢", "Rio de Janeiro", "portugal", -22.9, -43.18,
                 ("sugar", "timber", "amber"), ("iron", "wool")),
    "recife": ("累西腓", "Recife", "portugal", -8.06, -34.87,
                 ("sugar", "cotton_cloth"), ("wine", "iron")),
    "belem": ("贝伦", "Belem", "portugal", -1.35, -48.48,
                 ("timber", "spices"), ("salt", "glassware")),
    "boston": ("波士顿", "Boston", "england", 42.36, -71.05,
                 ("dried_fish", "timber"), ("wine", "salt")),
    "new_york": ("纽约", "New York", "england", 40.7, -74.02,
                 ("timber", "dried_fish"), ("wine", "spices")),
    "jamestown": ("詹姆斯敦", "Jamestown", "england", 37.0, -76.3,
                 ("timber", "wheat"), ("wine", "iron")),
    "charleston": ("查尔斯顿", "Charleston", "england", 32.78, -79.93,
                 ("sugar", "timber"), ("wine", "salt")),
    "new_foundland": ("纽芬兰", "Newfoundland", "england", 47.56, -52.71,
                 ("dried_fish", "timber"), ("wine", "salt")),
    "quebec": ("魁北克", "Quebec", "england", 47.0, -70.5,
                 ("timber", "dried_fish"), ("wine", "salt")),
    "curacao": ("库拉索", "Curacao", "holland", 12.11, -68.93,
                 ("salt", "sugar"), ("timber", "wine")),
    "suriname": ("苏里南", "Suriname", "holland", 5.9, -55.15,
                 ("sugar", "timber"), ("iron", "wine")),
    "elmina": ("埃尔米纳", "Elmina", "portugal", 5.08, -1.35,
                 ("amber", "salt"), ("cotton_cloth", "iron")),
    "luanda": ("罗安达", "Luanda", "portugal", -8.78, 13.23,
                 ("amber", "leather"), ("glassware", "wool")),
    "mozambique": ("莫桑比克", "Mozambique", "portugal", -15.03, 40.73,
                 ("amber", "spices"), ("cotton_cloth", "iron")),
    "mombasa": ("蒙巴萨", "Mombasa", "ottoman", -4.06, 39.68,
                 ("spices", "amber"), ("glassware", "wine")),
    "cape_town": ("开普敦", "Cape Town", "holland", -33.92, 18.42,
                 ("wine", "wheat"), ("timber", "iron")),
    "safi": ("萨菲", "Safi", "portugal", 32.3, -9.24,
                 ("salt", "leather"), ("silk", "spices")),
    "saint_louis": ("圣路易", "Saint-Louis", "holland", 16.0, -16.51,
                 ("leather", "salt"), ("glassware", "wool")),
    "accra": ("阿克拉", "Accra", "england", 5.53, -0.2,
                 ("amber", "salt"), ("cotton_cloth", "wine")),
    "goa": ("果阿", "Goa", "portugal", 15.5, 73.83,
                 ("spices", "cotton_cloth"), ("wine", "glassware")),
    "calicut": ("卡利卡特", "Calicut", "portugal", 11.25, 75.77,
                 ("spices", "carpet"), ("glassware", "copper")),
    "cochin": ("科钦", "Cochin", "holland", 9.97, 76.27,
                 ("spices", "timber"), ("iron", "wine")),
    "bombay": ("孟买", "Bombay", "england", 18.92, 72.83,
                 ("cotton_cloth", "spices"), ("iron", "wine")),
    "surat": ("苏拉特", "Surat", "england", 21.1, 72.7,
                 ("cotton_cloth", "carpet"), ("glassware", "amber")),
    "colombo": ("科伦坡", "Colombo", "holland", 6.93, 79.85,
                 ("spices", "ceramics"), ("wine", "iron")),
    "pondicherry": ("本地治里", "Pondicherry", "england", 11.93, 79.83,
                 ("cotton_cloth", "spices"), ("glassware", "amber")),
    "muscat": ("马斯喀特", "Muscat", "ottoman", 23.62, 58.59,
                 ("amber", "carpet"), ("wine", "timber")),
    "basra": ("巴士拉", "Basra", "ottoman", 30.0, 48.5,
                 ("carpet", "dried_fish"), ("iron", "timber")),
    "bandar_abbas": ("阿巴斯港", "Bandar Abbas", "ottoman", 27.18, 56.28,
                 ("carpet", "amber"), ("glassware", "sugar")),
    "aden": ("亚丁", "Aden", "ottoman", 12.79, 45.03,
                 ("amber", "salt"), ("wheat", "iron")),
    "jiddah": ("吉达", "Jiddah", "ottoman", 21.48, 39.18,
                 ("carpet", "amber"), ("wheat", "timber")),
    "suakin": ("苏阿金", "Suakin", "ottoman", 19.1, 37.33,
                 ("salt", "leather"), ("glassware", "wine")),
    "mogadishu": ("摩加迪沙", "Mogadishu", "ottoman", 2.03, 45.34,
                 ("spices", "leather"), ("iron", "wine")),
    "malacca": ("马六甲", "Malacca", "portugal", 2.19, 102.25,
                 ("spices", "amber"), ("iron", "wool")),
    "batavia": ("巴达维亚", "Batavia", "holland", -6.13, 106.81,
                 ("spices", "sugar"), ("wine", "iron")),
    "macassar": ("望加锡", "Macassar", "holland", -5.13, 119.41,
                 ("spices", "timber"), ("glassware", "wool")),
    "amboina": ("安汶", "Amboina", "holland", -3.69, 128.18,
                 ("spices", "salt"), ("iron", "wine")),
    "manila": ("马尼拉", "Manila", "spain", 14.58, 120.97,
                 ("silk", "spices"), ("wheat", "iron")),
    "macau": ("澳门", "Macao", "portugal", 22.19, 113.54,
                 ("silk", "ceramics"), ("sugar", "glassware")),
    "canton": ("广州", "Canton", "england", 22.75, 113.65,
                 ("silk", "ceramics", "timber"), ("copper", "salt")),
    "nagasaki": ("长崎", "Nagasaki", "holland", 32.75, 129.88,
                 ("copper", "silk"), ("sugar", "wine")),
    "osaka": ("大阪", "Osaka", "holland", 34.65, 135.43,
                 ("copper", "ceramics"), ("silk", "glassware")),
    "zeelandia": ("热兰遮", "Zeelandia", "holland", 22.99, 120.16,
                 ("sugar", "timber"), ("silk", "iron")),
    "patani": ("北大年", "Patani", "holland", 6.87, 101.25,
                 ("spices", "timber"), ("cotton_cloth", "iron")),
    "brunei": ("文莱", "Brunei", "spain", 5.0, 115.05,
                 ("timber", "spices"), ("glassware", "wool")),
    "ternate": ("特尔纳特", "Ternate", "holland", 0.79, 127.38,
                 ("spices", "salt"), ("wine", "iron")),
    "timor": ("帝汶", "Timor", "portugal", -10.17, 123.6,
                 ("spices", "timber"), ("glassware", "iron")),
    "botany_bay": ("植物学湾", "Botany Bay", "england", -33.98, 151.18,
                 ("timber", "dried_fish"), ("wine", "iron")),
    "siam": ("暹罗", "Siam", "portugal", 13.5, 100.58,
                 ("timber", "ceramics"), ("glassware", "wool")),
    "cadiz": ("加的斯", "Cadiz", "spain", 36.53, -6.29,
                 ("salt", "wine"), ("spices", "timber")),
    "oporto": ("波尔图", "Oporto", "portugal", 41.14, -8.68,
                 ("wine", "leather"), ("spices", "glassware")),
    "plymouth": ("普利茅斯", "Plymouth", "england", 50.37, -4.14,
                 ("dried_fish", "wool"), ("wine", "spices")),
    "bergen": ("卑尔根", "Bergen", "holland", 60.39, 5.32,
                 ("dried_fish", "timber"), ("wine", "salt")),
    "danzig": ("但泽", "Danzig", "holland", 54.4, 18.68,
                 ("timber", "amber"), ("wine", "salt")),
    "stockholm": ("斯德哥尔摩", "Stockholm", "holland", 59.32, 18.1,
                 ("copper", "iron"), ("wine", "salt")),
    "trieste": ("的里雅斯特", "Trieste", "italy", 45.65, 13.77,
                 ("glassware", "timber"), ("spices", "sugar")),
    "corfu": ("科孚", "Corfu", "italy", 39.62, 19.92,
                 ("olive_oil", "salt"), ("wine", "timber")),
}

# id: (zh, en, nation_id, role, recruit_ports, wage_daily)  -- section 7.5
LOCKED_OFFICERS = {
    "off_mateus_alvares": ("马特乌斯·阿尔瓦雷斯", "Mateus Álvares", "portugal",
                          "navigator", ("lisbon", "madeira"), 30),
    "off_diego_fernandez": ("迭戈·费尔南德斯", "Diego Fernández", "spain",
                           "boatswain", ("seville", "ceuta"), 28),
    "off_thomas_reed": ("托马斯·里德", "Thomas Reed", "england",
                        "gunner", ("london",), 32),
    "off_jan_de_vries": ("扬·德弗里斯", "Jan de Vries", "holland",
                         "boatswain", ("amsterdam", "antwerp"), 28),
    "off_kemal_agha": ("凯末尔阿迦", "Kemal Agha", "ottoman",
                       "gunner", ("istanbul", "smyrna"), 30),
    "off_marco_bellini": ("马尔科·贝里尼", "Marco Bellini", "italy",
                          "navigator", ("venice", "genoa"), 30),
}

# id: (zh, en, slot, modifiers, price)  -- docs/60-COMBAT.md section 4.11.13
# (reachable from docs/10-DATA-SCHEMA.md section 4.6). All Phase-2 items.
LOCKED_EQUIPMENT = {
    "eq_cutlass": ("水手弯刀", "Sailor's Cutlass", "weapon", {"combat": 3}, 400),
    "eq_rapier": ("贵族细剑", "Noble's Rapier", "weapon", {"combat": 5}, 1200),
    "eq_breastplate": ("胸甲", "Breastplate", "armor", {"combat": 2}, 700),
    "eq_lucky_charm": ("幸运护符", "Lucky Charm", "armor",
                       {"combat": 1, "luck": 5}, 900),
    "eq_mermaid_figurehead": ("美人鱼船首像", "Mermaid Figurehead",
                              "figurehead", {"durability": 10}, 1500),
    "eq_dragon_figurehead": ("龙首船像", "Dragon Figurehead",
                             "figurehead", {"durability": 20}, 3200),
    "eq_cotton_sails": ("棉帆", "Cotton Sails", "sail", {"speed": 1}, 1000),
    "eq_storm_sails": ("风暴帆", "Storm Sails", "sail",
                       {"speed": 1, "durability": 5}, 2600),
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
    "goods": 20,
    "ship_types": 8,
    "ports": 100,
    "officers": 6,
    "equipment": 8,
}

# --- Phase 5 npc & economy data (docs/10-DATA-SCHEMA.md sections 4.10-4.13,
# normative validator spec section 8.2) --------------------------------------

# npc_config.json: the locked §4.10 key sets. The values are bounds-checked
# (§8.2 item 1); the key sets themselves are exact.
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
                   "absolute_cap")
# §4.10: exactly one preset multiplier is 1.0 and `default_preset` names it.
NEUTRAL_PRESET = "normal"
# §4.10: hard upper bound on live NPC fleets (group 7 enforces the locked cap).
ABSOLUTE_CAP_MAX = 2048

# npc_captains.json: §7.7's closed set — the 6 nation ids plus the nationless
# `""` pool pirates draw from; every pool carries at least this many names.
NATIONLESS_POOL_ID = ""
CAPTAIN_POOL_MIN_NAMES = 8

# named_pirates.json: §7.8 locks the count and the tier band (tier semantics:
# 70-* §4.5 bounty bands 5000/10000/20000 for tiers 1/2/3).
NAMED_PIRATE_COUNT = 4
NAMED_PIRATE_TIER_MIN = 1
NAMED_PIRATE_TIER_MAX = 3

# market_events.json rest-band bounds. Resting stock per port-good takes the
# §4.2 (`30-*`) resting values: 160 where the good is produced, 40 where it is
# demanded, 100 otherwise; an event shifts REST and the result is clamped to
# the §4.13 effect band [10, 190] (§8.2 item 4 asserts the shift stays inside
# the band for every resting value the good takes across the 100 ports).
REST_PRODUCED = 160
REST_DEMANDED = 40
REST_NEUTRAL = 100
REST_BAND_MIN = 10
REST_BAND_MAX = 190

# §8.2 item 5 (`30-*` §4.2): rank goods by (base_price asc, id asc) —
# indices 0-4 staples, 5-14 middle, 15-19 luxuries.
CONSUMPTION_TIER_SPLIT = (5, 10, 5)

# Files whose structure/counts/bounds group 7 owns outright (§8.2 preamble);
# group 3's generic id loop skips them.
GROUP7_ENTITY_FILES = frozenset({
    "npc_captains.json", "named_pirates.json", "market_events.json",
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


def _schema_ship_types(items: list) -> None:
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
            ),
            path,
            "ship_types.json",
        )
        _require_enum(entity["class"], SHIP_CLASSES, f"{path}.class", "ship_types.json")
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


def _schema_ports(items: list, filename: str = "ports.json") -> None:
    """Port schema (docs/10-* section 4.4, Phase 4): `lat`/`lon` are the
    geographic truth and the grid tile is derived by section 6.1's harbor-snap
    rule. The retired dual-map keys (`marker`, `position`, `p3`, `phase`) are
    rejected outright so a stale edit cannot smuggle one back in."""
    RETIRED = ("marker", "position", "p3", "phase")
    for index, entity in enumerate(items):
        path = f"{filename}[{index}]"
        _require_keys(
            entity,
            ("id", "name", "nation_id", "lat", "lon", "produces", "demands",
             "facilities", "flavor"),
            path,
            filename,
        )
        for key in RETIRED:
            if key in entity:
                fail(
                    "schema",
                    filename,
                    f"{path}.{key} is retired in Phase 4 "
                    "(lat/lon are the only coordinates, 10-* 4.4)",
                    3,
                )
        _require_id(entity["nation_id"], f"{path}.nation_id", filename)
        _require_number(entity["lat"], f"{path}.lat", filename, -90.0, 90.0)
        _require_number(entity["lon"], f"{path}.lon", filename, -180.0, 180.0)
        _require_id_list(entity["produces"], f"{path}.produces", filename)
        _require_id_list(entity["demands"], f"{path}.demands", filename)
        if "market_goods" in entity:
            _require_id_list(entity["market_goods"], f"{path}.market_goods", filename)
        facilities = entity["facilities"]
        if not isinstance(facilities, dict):
            fail("schema", filename, f"{path}.facilities must be an object", 3)
        for key, value in facilities.items():
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


def _schema_officers(items: list) -> None:
    for index, entity in enumerate(items):
        path = f"officers[{index}]"
        _require_keys(
            entity,
            (
                "id",
                "name",
                "nation_id",
                "role",
                "stats",
                "wage_daily",
                "recruit_ports",
                "bio",
            ),
            path,
            "officers.json",
        )
        _require_id(entity["nation_id"], f"{path}.nation_id", "officers.json")
        _require_enum(entity["role"], OFFICER_ROLES, f"{path}.role", "officers.json")
        stats = entity["stats"]
        if not isinstance(stats, dict) or set(stats) != set(OFFICER_STAT_NAMES):
            fail(
                "schema",
                "officers.json",
                f"{path}.stats must have exactly keys "
                f"leadership,seamanship,combat,navigation",
                3,
            )
        for stat in OFFICER_STAT_NAMES:
            _require_int(stats[stat], f"{path}.stats.{stat}", "officers.json", 1, 20)
        _require_int(entity["wage_daily"], f"{path}.wage_daily", "officers.json", 0)
        _require_id_list(
            entity["recruit_ports"], f"{path}.recruit_ports", "officers.json", allow_empty=False
        )


def _schema_equipment(items: list) -> None:
    for index, entity in enumerate(items):
        path = f"equipment[{index}]"
        _require_keys(
            entity, ("id", "name", "slot", "modifiers", "price", "phase"), path, "equipment.json"
        )
        _require_enum(entity["slot"], EQUIPMENT_SLOTS, f"{path}.slot", "equipment.json")
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
        _require_int(entity["price"], f"{path}.price", "equipment.json", 0)
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
        if filename in GROUP7_ENTITY_FILES:
            # Group 7 owns these files' structure, counts and bounds outright
            # (docs/10-* section 8.2 preamble), including pool/pirate/event id
            # uniqueness — a pool has no `id` field at all (its key is
            # `nation_id`).
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

    for index, port in enumerate(ports):
        path = f"ports[{index}]"
        if port["nation_id"] not in nation_ids:
            fail(
                "ref",
                "ports.json",
                f"{path} ({port['id']}) nation_id {port['nation_id']!r} is not a known nation",
                4,
            )
        for field in ("produces", "demands", "market_goods"):
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
        if port.get("produces",) and port.get("demands",):
            overlap = sorted(set(port["produces"]) & set(port["demands"]))
            if overlap and verbose:
                print(
                    f"WARN produces/demands overlap at port {port['id']}: "
                    f"{', '.join(overlap)} (allowed, likely pointless)"
                )

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

    for index, item in enumerate(equipment):
        slot = item.get("slot",)
        modifiers = item.get("modifiers",)
        if not isinstance(modifiers, dict):
            continue  # schema group already reported this
        for stat in modifiers:
            if stat not in EQUIPMENT_STAT_NAMES:
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


def check_group5(docs: dict[str, object], verbose: bool) -> None:
    """Exact id sets and content against the section 7 tables."""
    ports = docs["ports.json"]["ports"]
    goods = docs["goods.json"]["goods"]
    ship_types = docs["ship_types.json"]["ship_types"]
    nations = docs["nations.json"]["nations"]
    officers = docs["officers.json"]["officers"]
    equipment = docs["equipment.json"]["equipment"]

    _locked_id_sets(ports, LOCKED_PORTS, "ports", "ports.json")
    _locked_id_sets(goods, LOCKED_GOODS, "goods", "goods.json")
    _locked_id_sets(ship_types, LOCKED_SHIP_TYPES, "ship_types", "ship_types.json")
    _locked_id_sets(nations, LOCKED_NATIONS, "nations", "nations.json")
    _locked_id_sets(officers, LOCKED_OFFICERS, "officers", "officers.json")
    _locked_id_sets(equipment, LOCKED_EQUIPMENT, "equipment", "equipment.json")

    for plural, expected_count in LOCKED_COUNTS.items():
        items = docs[f"{plural}.json"][plural]
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

    for index, port in enumerate(ports):
        zh, en, nation_id, lat, lon, produces, demands = LOCKED_PORTS[port["id"]]
        path = f"ports[{index}]"
        _check_l10n_text(port, "name", zh, en, path, "ports.json")
        expected = {
            "nation_id": nation_id,
            "lat": lat,
            "lon": lon,
            "produces": list(produces),
            "demands": list(demands),
        }
        for field, value in expected.items():
            if port[field] != value:
                fail(
                    "locked-content",
                    "ports.json",
                    f"{path} ({port['id']}) {field} must be {value}",
                    5,
                )

    for index, officer in enumerate(officers):
        zh, en, nation_id, role, recruit_ports, wage_daily = LOCKED_OFFICERS[officer["id"]]
        path = f"officers[{index}]"
        _check_l10n_text(officer, "name", zh, en, path, "officers.json")
        expected = {
            "nation_id": nation_id,
            "role": role,
            "recruit_ports": list(recruit_ports),
            "wage_daily": wage_daily,
        }
        for field, value in expected.items():
            if officer[field] != value:
                fail(
                    "locked-content",
                    "officers.json",
                    f"{path} ({officer['id']}) {field} must be {value}",
                    5,
                )

    # docs/60-COMBAT.md section 4.11.13: the locked 8-item content set. Mirrors
    # the doc table field by field, so a data-only edit (a price tweak, a stat
    # swap, a renamed item) fails loudly instead of drifting from the spec.
    for index, item in enumerate(equipment):
        zh, en, slot, modifiers, price = LOCKED_EQUIPMENT[item["id"]]
        path = f"equipment[{index}]"
        _check_l10n_text(item, "name", zh, en, path, "equipment.json")
        expected = {
            "slot": slot,
            "modifiers": dict(modifiers),
            "price": price,
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
            "PASS group 5 locked lists (100 ports, 20 goods, 8 ship types, "
            "6 nations, 6 officers, 8 equipment items)"
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
    # fire and name the port and the strait it proves.
    isolated = _g6_isolate_harbor(grid, report_tiles, "istanbul")
    if isolated is None:
        print("FAIL g6-self-test probe-harbor-sealed: cannot isolate 'istanbul'")
        results.append(False)
    else:
        results.append(
            _expect_g6_failure(
                "probe-harbor-sealed",
                "bosphorus",
                lambda: analyse_world_map(
                    isolated, ports, report_tiles, discoveries, False,
                    report_shores,
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
                "locked at 2160x1080",
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
    extra = sorted(set(config) - set(NPC_CONFIG_KEYS))
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


def _check_npc_captains(captains: object) -> None:
    """npc_captains.json (section 8.2 item 2, sections 4.11 / 7.7)."""
    label = "npc_captains.json"
    pools = captains.get("pools") if isinstance(captains, dict) else None
    if not isinstance(pools, list):
        fail("captain-pools", label, "missing 'pools' array", 7)

    expected_pools = set(LOCKED_NATIONS) | {NATIONLESS_POOL_ID}
    seen: set[str] = set()
    for index, pool in enumerate(pools):
        path = f"pools[{index}]"
        if not isinstance(pool, dict) or set(pool) != {"nation_id", "names"}:
            fail(
                "captain-pools",
                label,
                f"{path} must be an object with exactly keys "
                "nation_id,names (section 4.11)",
                7,
            )
        pool_id = pool["nation_id"]
        if not isinstance(pool_id, str) or pool_id not in expected_pools:
            fail(
                "captain-pools",
                label,
                f"{path}.nation_id {pool_id!r} must be one of the 6 locked "
                f"nation ids or the nationless '' pool (section 7.7)",
                7,
            )
        if pool_id in seen:
            fail("captain-pools", label,
                 f"{path} repeats pool {pool_id!r}", 7)
        seen.add(pool_id)

        names = pool["names"]
        if not isinstance(names, list) or len(names) < CAPTAIN_POOL_MIN_NAMES:
            count = len(names) if isinstance(names, list) else "non-array"
            fail(
                "captain-pools",
                label,
                f"{path} (pool {pool_id!r}) must carry at least "
                f"{CAPTAIN_POOL_MIN_NAMES} names (got {count})",
                7,
            )
        for name_index, name in enumerate(names):
            _check_complete_l10n(
                name, f"{path}.names[{name_index}]", label
            )

    missing = sorted(expected_pools - seen)
    if missing:
        fail(
            "captain-pools",
            label,
            f"missing pool(s) {', '.join(repr(m) for m in missing)} — the "
            "section 7.7 pool set is closed (6 nations + '')",
            7,
        )
    if len(pools) != len(expected_pools):
        fail(
            "captain-pools",
            label,
            f"pool count {len(pools)} != the locked {len(expected_pools)} "
            "(section 7.7)",
            7,
        )


def _check_named_pirates(pirates_doc: object) -> None:
    """named_pirates.json (section 8.2 item 3, sections 4.12 / 7.8)."""
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
    seen: set[str] = set()
    for index, pirate in enumerate(pirates):
        path = f"named_pirates[{index}]"
        if not isinstance(pirate, dict) or set(pirate) != {"id", "name", "tier"}:
            fail(
                "named-pirates",
                label,
                f"{path} must be an object with exactly keys "
                "id,name,tier (section 4.12)",
                7,
            )
        _require_id(pirate["id"], f"{path}.id", label)
        if pirate["id"] in seen:
            fail("named-pirates", label,
                 f"{path} repeats id {pirate['id']!r}", 7)
        seen.add(pirate["id"])
        _check_complete_l10n(pirate["name"], f"{path}.name", label)
        tier = pirate["tier"]
        if not is_int(tier) or not (NAMED_PIRATE_TIER_MIN <= tier
                                    <= NAMED_PIRATE_TIER_MAX):
            fail(
                "named-pirates",
                label,
                f"{path} ({pirate['id']}) tier must be an integer in "
                f"{NAMED_PIRATE_TIER_MIN}-{NAMED_PIRATE_TIER_MAX} "
                f"(70-* section 4.5 bounty bands), got {tier!r}",
                7,
            )


def _rest_classes_for(good_id: str, produced_goods: set, demanded_goods: set) -> list[int]:
    """Every §4.2 resting value `good_id` takes across the 100 ports."""
    classes = [REST_NEUTRAL]
    if good_id in produced_goods:
        classes.append(REST_PRODUCED)
    if good_id in demanded_goods:
        classes.append(REST_DEMANDED)
    return classes


def _check_market_events(events_doc: object, ports: list, good_ids: set) -> None:
    """market_events.json (section 8.2 item 4, section 4.13)."""
    label = "market_events.json"
    events = events_doc.get("market_events") \
        if isinstance(events_doc, dict) else None
    if not isinstance(events, list):
        fail("market-events", label, "missing 'market_events' array", 7)

    produced_goods = {
        good_id for port in ports for good_id in port.get("produces", [])
    }
    demanded_goods = {
        good_id for port in ports for good_id in port.get("demands", [])
    }

    seen: set[str] = set()
    for index, event in enumerate(events):
        path = f"market_events[{index}]"
        required = {"id", "scope", "cadence_days", "duration_days",
                    "shifts", "name"}
        if not isinstance(event, dict) or set(event) != required:
            fail(
                "market-events",
                label,
                f"{path} must be an object with exactly keys "
                "id,scope,cadence_days,duration_days,shifts,name "
                "(section 4.13)",
                7,
            )
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

        shifts = event["shifts"]
        if not isinstance(shifts, dict):
            fail(
                "market-events",
                label,
                f"{path} ({event['id']}) shifts must be an object",
                7,
            )
        for good_id, shift in shifts.items():
            if good_id not in good_ids:
                fail(
                    "market-events",
                    label,
                    f"{path} ({event['id']}) shifts references unknown good "
                    f"{good_id!r}",
                    7,
                )
            if not is_int(shift):
                fail(
                    "market-events",
                    label,
                    f"{path} ({event['id']}) shifts.{good_id} must be an "
                    f"integer delta (got {shift!r})",
                    7,
                )
            if shift == 0:
                fail(
                    "market-events",
                    label,
                    f"{path} ({event['id']}) shifts.{good_id} is 0 — a no-op "
                    "typo, not an event shift",
                    7,
                )
            # Rest-band bound (section 8.2 item 4): the shift must keep rest
            # inside the §4.13 effect clamp for EVERY resting value the good
            # takes across the 100 ports.
            for rest in _rest_classes_for(good_id, produced_goods,
                                          demanded_goods):
                shifted = rest + shift
                if not (REST_BAND_MIN <= shifted <= REST_BAND_MAX):
                    fail(
                        "market-events",
                        label,
                        f"{path} ({event['id']}) shift {shift:+d} on "
                        f"'{good_id}' pushes resting stock {rest} to "
                        f"{shifted}, outside the [{REST_BAND_MIN}, "
                        f"{REST_BAND_MAX}] effect band (section 8.2 item 4; "
                        "resting classes 160/40/100 per 30-* section 4.2)",
                        7,
                    )


def _check_consumption_tiers(goods: list) -> None:
    """Section 8.2 item 5 (`30-*` section 4.2): the (base_price asc, id asc)
    ranking splits into 5 staples / 10 middle / 5 luxuries."""
    ranked = sorted(goods, key=lambda good: (good["base_price"], good["id"]))
    staples, middle, luxuries = [], [], []
    for index, good in enumerate(ranked):
        if index < CONSUMPTION_TIER_SPLIT[0]:
            staples.append(good["id"])
        elif index < CONSUMPTION_TIER_SPLIT[0] + CONSUMPTION_TIER_SPLIT[1]:
            middle.append(good["id"])
        else:
            luxuries.append(good["id"])
    expected = CONSUMPTION_TIER_SPLIT
    actual = (len(staples), len(middle), len(luxuries))
    if actual != expected:
        fail(
            "consumption-tiers",
            "goods.json",
            f"consumption tiers must split {expected[0]}/{expected[1]}/"
            f"{expected[2]} (30-* section 4.2), got "
            f"{actual[0]}/{actual[1]}/{actual[2]}",
            7,
        )
    return staples, middle, luxuries


def check_group7(docs: dict[str, object], verbose: bool) -> None:
    """Npc & economy data: docs/10-DATA-SCHEMA.md section 8.2.

    Owns structure, counts and bounds for the four Phase-5 files; L10nString
    completeness inside them is group 2's recursion.
    """
    _check_npc_config(docs.get("npc_config.json"))
    pools = docs["npc_captains.json"]["pools"]
    _check_npc_captains(docs["npc_captains.json"])
    _check_named_pirates(docs["named_pirates.json"])
    _check_market_events(
        docs["market_events.json"],
        docs["ports.json"]["ports"],
        {good["id"] for good in docs["goods.json"]["goods"]},
    )
    staples, middle, luxuries = _check_consumption_tiers(
        docs["goods.json"]["goods"]
    )

    if verbose:
        print(
            f"PASS group 7 npc & economy data ({len(pools)} captain pools, "
            f"{NAMED_PIRATE_COUNT} named pirates, "
            f"{len(docs['market_events.json']['market_events'])} event "
            f"templates, absolute_cap {docs['npc_config.json']['absolute_cap']})"
        )
        print(
            f"INFO group 7 consumption tiers — staples: {', '.join(staples)}; "
            f"middle: {len(middle)} goods; luxuries: {', '.join(luxuries)}"
        )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    verbose = "--verbose" in argv
    self_test = "--self-test-g6" in argv or os.environ.get("SAILAGE_G6_SELFTEST") == "1"
    known = {"--verbose", "--self-test-g6"}
    unknown = [arg for arg in argv[1:] if arg not in known]
    if unknown:
        print("usage: python3 tools/validate_data.py [--verbose] [--self-test-g6]")
        return 1

    if self_test:
        return run_group6_self_test()

    docs: dict[str, object] = {}
    groups = (
        ("1", check_group1),
        ("2", check_group2),
        ("3", check_group3),
        ("4", check_group4),
        ("5", check_group5),
        ("6", check_group6),
        ("7", check_group7),
    )

    for group_id, check in groups:
        try:
            check(docs, verbose)
        except CheckFailure as exc:
            print(f"FAIL {exc.check_id} {exc.filename} {exc.details}")
            return exc.code
        except Exception as exc:  # defensive: never leak a traceback as exit 0
            print(f"FAIL internal group{group_id} tools/validate_data.py {exc!r}")
            return 3

    if verbose:
        print("OK all check groups passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
