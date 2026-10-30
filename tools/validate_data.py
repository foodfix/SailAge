#!/usr/bin/env python3
"""SailAge data validator.

Implements check groups 1-5 of docs/10-DATA-SCHEMA.md section 8.
Group 6 (map) is implemented by task T3 (see check_group6 stub below).

Usage (from the repo root):

    python3 tools/validate_data.py
    python3 tools/validate_data.py --verbose

Exit codes:

    0  all checks pass
    1  parse & envelope failure
    2  i18n failure
    3  schema failure
    4  referential integrity failure
    5  locked-list failure
    6  map failure (T3)

On the first failure a single line is printed to stdout:

    FAIL <check-id> <file> <details>

and the process exits with that check group's code.
"""

from __future__ import annotations

import json
import re
import sys
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

def check_group6(docs: dict[str, object], verbose: bool) -> None:
    """World-map integrity: docs/10-DATA-SCHEMA.md section 8.1.

    Task F (W4) replaces this body with the artifact checks: indexed-PNG
    validation, independent harbor-tile recomputation against
    `world_report.json`, and the wrap-aware no-corner-cut BFS over all 100
    harbors and 30 discoveries. Until it lands this group reports the gap
    explicitly instead of validating the retired ASCII map, so a red here is
    always attributable (see IMPLEMENT-Phase4.md "Pre-state").
    """
    fail(
        "map",
        "data/maps/world.png",
        "world-map group 6 is being rewritten for the PNG artifact "
        "(docs/IMPLEMENT-Phase4.md task F); the retired ASCII checks no longer apply",
        6,
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    verbose = "--verbose" in argv
    unknown = [arg for arg in argv[1:] if arg != "--verbose"]
    if unknown:
        print(f"usage: python3 tools/validate_data.py [--verbose]")
        return 1

    docs: dict[str, object] = {}
    groups = (
        ("1", check_group1),
        ("2", check_group2),
        ("3", check_group3),
        ("4", check_group4),
        ("5", check_group5),
        ("6", check_group6),
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
