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

MAP_WIDTH = 128
MAP_HEIGHT = 96

# docs/10-DATA-SCHEMA.md section 6.2 -- char -> (kind, passable)
LOCKED_TILE_KINDS = {
    "~": ("sea", True),
    ".": ("coastal_sea", True),
    "#": ("land", False),
    "^": ("reef", False),
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
SPECIAL_FILES = {"map_legend.json", "ui_strings.json"}
# Of those, only map_legend.json has `version` in its section 4.9 schema.
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
    "latin": ("拉丁帆船", "Latin", "sail", 1200, 40, 30, 4, 8, 20, 2),
    "sloop": ("单桅纵帆船", "Sloop", "sail", 3000, 60, 60, 5, 10, 30, 4),
    "caravel": ("卡拉维尔帆船", "Caravel", "sail", 8000, 90, 120, 5, 15, 45, 6),
    "galley": ("桨帆船", "Galley", "oar", 10000, 70, 50, 6, 40, 120, 4),
    "brigantine": ("双桅帆船", "Brigantine", "sail", 15000, 110, 150, 6, 20, 60, 10),
    "nao": ("瑙船", "Nao", "sail", 22000, 140, 300, 4, 25, 80, 10),
    "carrack": ("卡拉克帆船", "Carrack", "sail", 40000, 180, 450, 4, 30, 100, 16),
    "galleon": ("盖伦帆船", "Galleon", "hybrid", 60000, 240, 400, 5, 40, 150, 24),
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

# id: (zh, en, nation_id, marker, x, y, produces, demands)  -- section 7.1
LOCKED_PORTS = {
    "lisbon": ("里斯本", "Lisbon", "portugal", "f", 7, 57,
               ("wine", "salt"), ("spices", "silk", "timber")),
    "seville": ("塞维利亚", "Seville", "spain", "m", 13, 65,
                ("olive_oil", "wine", "wool"), ("sugar", "spices")),
    "valencia": ("瓦伦西亚", "Valencia", "spain", "r", 27, 55,
                 ("silk", "ceramics"), ("wheat", "timber")),
    "barcelona": ("巴塞罗那", "Barcelona", "spain", "5", 33, 48,
                  ("wool", "cotton_cloth"), ("iron", "spices")),
    "marseille": ("马赛", "Marseille", "spain", "i", 41, 41,
                  ("wine", "salt", "perfume"), ("wool", "silk")),
    "bordeaux": ("波尔多", "Bordeaux", "spain", "7", 26, 33,
                 ("wine", "salt"), ("timber", "wool")),
    "london": ("伦敦", "London", "england", "g", 30, 13,
               ("wool", "cotton_cloth"), ("wine", "spices", "timber")),
    "amsterdam": ("阿姆斯特丹", "Amsterdam", "holland", "2", 40, 9,
                  ("cheese", "glassware"), ("spices", "silk", "wheat")),
    "antwerp": ("安特卫普", "Antwerp", "holland", "3", 39, 13,
                ("glassware", "wool"), ("spices", "wine")),
    "hamburg": ("汉堡", "Hamburg", "holland", "d", 51, 6,
                ("dried_fish", "timber", "amber"), ("wine", "salt")),
    "genoa": ("热那亚", "Genoa", "italy", "c", 49, 37,
              ("olive_oil", "cotton_cloth"), ("spices", "copper")),
    "naples": ("那不勒斯", "Naples", "italy", "j", 62, 50,
               ("olive_oil", "wine"), ("wheat", "timber")),
    "palermo": ("巴勒莫", "Palermo", "italy", "k", 60, 59,
                ("wheat", "olive_oil"), ("timber", "iron")),
    "syracuse": ("锡拉库萨", "Syracuse", "italy", "o", 64, 63,
                 ("salt", "wheat"), ("timber", "leather")),
    "cagliari": ("卡利亚里", "Cagliari", "italy", "8", 50, 56,
                 ("salt", "leather"), ("wheat", "glassware")),
    "valetta": ("瓦莱塔", "Valetta", "italy", "s", 62, 67,
                ("cotton_cloth",), ("wheat", "timber", "iron")),
    "venice": ("威尼斯", "Venice", "italy", "t", 57, 34,
               ("glassware", "perfume"), ("spices", "silk", "cotton_cloth")),
    "ragusa": ("拉古萨", "Ragusa", "italy", "l", 71, 44,
               ("timber", "leather", "wool"), ("wheat",)),
    "athens": ("雅典", "Athens", "ottoman", "4", 84, 60,
               ("olive_oil", "wine", "ceramics"), ("timber", "iron")),
    "candia": ("干地亚", "Candia", "ottoman", "9", 87, 69,
               ("wine", "olive_oil"), ("wheat", "salt")),
    "cyprus": ("塞浦路斯", "Cyprus", "ottoman", "b", 107, 70,
               ("copper", "sugar"), ("wheat", "timber")),
    "smyrna": ("士麦那", "Smyrna", "ottoman", "n", 92, 58,
               ("carpet",), ("wheat", "glassware", "iron")),
    "istanbul": ("伊斯坦布尔", "Istanbul", "ottoman", "e", 96, 49,
                 ("carpet", "perfume"), ("wheat", "iron", "timber")),
    "beirut": ("贝鲁特", "Beirut", "ottoman", "6", 112, 74,
               ("silk", "timber"), ("wheat", "salt")),
    "alexandria": ("亚历山大", "Alexandria", "ottoman", "1", 99, 84,
                   ("cotton_cloth", "sugar", "wheat"), ("timber", "iron", "wine")),
    "tripoli": ("的黎波里", "Tripoli", "ottoman", "p", 59, 78,
                ("leather", "salt"), ("wheat", "timber")),
    "tunis": ("突尼斯", "Tunis", "ottoman", "q", 52, 64,
              ("olive_oil", "leather"), ("wheat", "iron")),
    "algiers": ("阿尔及尔", "Algiers", "ottoman", "0", 36, 64,
                ("leather", "wool"), ("wheat", "timber", "wine")),
    "ceuta": ("休达", "Ceuta", "portugal", "a", 16, 67,
              ("wheat", "leather"), ("wine", "cotton_cloth")),
    "madeira": ("马德拉", "Madeira", "portugal", "h", 0, 78,
                ("sugar", "wine"), ("wheat", "iron")),
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

CAPITAL_PORT_IDS = tuple(
    row[7] for row in LOCKED_NATIONS.values()
)  # lisbon, seville, london, amsterdam, istanbul, venice

LOCKED_COUNTS = {
    "nations": 6,
    "goods": 20,
    "ship_types": 8,
    "ports": 30,
    "officers": 6,
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

        if not is_int(obj.get("version")):
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


def _require_tile_pos(value, path: str, filename: str) -> None:
    if not isinstance(value, dict) or set(value) != {"x", "y"}:
        fail("schema", filename, f"{path} must be an object with exactly keys x,y", 3)
    _require_int(value["x"], f"{path}.x", filename, 0, MAP_WIDTH - 1)
    _require_int(value["y"], f"{path}.y", filename, 0, MAP_HEIGHT - 1)


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
        entity_id = entity.get("id")
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
        if not isinstance(entity.get("color"), str) or not COLOR_RE.match(entity["color"]):
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


def _schema_ports(items: list) -> None:
    seen_markers: dict[str, str] = {}
    seen_positions: dict[tuple[int, int], str] = {}
    for index, entity in enumerate(items):
        path = f"ports[{index}]"
        _require_keys(
            entity,
            (
                "id",
                "name",
                "nation_id",
                "marker",
                "position",
                "produces",
                "demands",
                "facilities",
                "flavor",
            ),
            path,
            "ports.json",
        )
        _require_id(entity["nation_id"], f"{path}.nation_id", "ports.json")
        marker = entity["marker"]
        if not isinstance(marker, str) or not MARKER_RE.match(marker):
            fail(
                "schema",
                "ports.json",
                f"{path}.marker must be 1 char from 0-9 or a-t (got {marker!r})",
                3,
            )
        if marker in seen_markers:
            fail(
                "schema",
                "ports.json",
                f"{path}.marker {marker!r} already used by {seen_markers[marker]!r}",
                3,
            )
        seen_markers[marker] = entity["id"]
        _require_tile_pos(entity["position"], f"{path}.position", "ports.json")
        pos = (entity["position"]["x"], entity["position"]["y"])
        if pos in seen_positions:
            fail(
                "schema",
                "ports.json",
                f"{path}.position {pos} already used by {seen_positions[pos]!r}",
                3,
            )
        seen_positions[pos] = entity["id"]
        _require_id_list(entity["produces"], f"{path}.produces", "ports.json")
        _require_id_list(entity["demands"], f"{path}.demands", "ports.json")
        if "market_goods" in entity:
            _require_id_list(entity["market_goods"], f"{path}.market_goods", "ports.json")
        facilities = entity["facilities"]
        if not isinstance(facilities, dict):
            fail("schema", "ports.json", f"{path}.facilities must be an object", 3)
        for key, value in facilities.items():
            if key not in FACILITY_PHASES:
                fail(
                    "schema",
                    "ports.json",
                    f"{path}.facilities has unknown facility {key!r}",
                    3,
                )
            _require_int(value, f"{path}.facilities.{key}", "ports.json", 1)
            if value != FACILITY_PHASES[key]:
                fail(
                    "schema",
                    "ports.json",
                    f"{path}.facilities.{key} is locked at {FACILITY_PHASES[key]}",
                    3,
                )
        for key in PORT_FACILITIES_REQUIRED:
            if key not in facilities:
                fail(
                    "schema",
                    "ports.json",
                    f"{path}.facilities missing required facility {key!r}",
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
        for stat, delta in modifiers.items():
            _require_int(delta, f"{path}.modifiers.{stat}", "equipment.json")
        _require_int(entity["price"], f"{path}.price", "equipment.json", 0)
        _require_int(entity["phase"], f"{path}.phase", "equipment.json", 2, 2)


def _schema_discoveries(items: list) -> None:
    for index, entity in enumerate(items):
        path = f"discoveries[{index}]"
        _require_keys(
            entity,
            (
                "id",
                "name",
                "category",
                "position",
                "fame",
                "report_reward_gold",
                "region_hint",
                "phase",
            ),
            path,
            "discoveries.json",
        )
        _require_enum(
            entity["category"], DISCOVERY_CATEGORIES, f"{path}.category", "discoveries.json"
        )
        _require_tile_pos(entity["position"], f"{path}.position", "discoveries.json")
        _require_int(entity["fame"], f"{path}.fame", "discoveries.json", 1)
        _require_int(
            entity["report_reward_gold"], f"{path}.report_reward_gold", "discoveries.json", 0
        )
        _require_int(entity["phase"], f"{path}.phase", "discoveries.json", 3, 3)


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
            _require_keys(
                requirements, ("target_fleet_id",), f"{path}.requirements", "quests.json"
            )
            _require_id(
                requirements["target_fleet_id"],
                f"{path}.requirements.target_fleet_id",
                "quests.json",
            )
        elif entity["type"] == "exploration":
            _require_keys(
                requirements, ("discovery_id",), f"{path}.requirements", "quests.json"
            )
            _require_id(
                requirements["discovery_id"], f"{path}.requirements.discovery_id", "quests.json"
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
    _require_int(legend.get("tile_size_px"), "tile_size_px", "map_legend.json", 1)
    if legend["tile_size_px"] != 32:
        fail("schema", "map_legend.json", "tile_size_px is locked at 32", 3)
    grid = legend.get("grid")
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
    tiles = legend.get("tiles")
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
        if not isinstance(tile.get("kind"), str) or not tile["kind"]:
            fail("schema", "map_legend.json", f"tiles[{char!r}].kind must be a string", 3)
        if not isinstance(tile.get("passable"), bool):
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
    markers = legend.get("port_markers")
    if not isinstance(markers, dict):
        fail("schema", "map_legend.json", "port_markers must be an object", 3)
    for marker, port_id in markers.items():
        if not isinstance(marker, str) or not MARKER_RE.match(marker):
            fail(
                "schema",
                "map_legend.json",
                f"port_markers key {marker!r} must be 1 char from 0-9 or a-t",
                3,
            )
        _require_id(port_id, f"port_markers[{marker!r}]", "map_legend.json")


def check_group3(docs: dict[str, object], verbose: bool) -> None:
    """Per-entity fields, types, enums and ranges (section 4)."""
    items = {plural: docs[filename][plural] for filename, plural in ENTITY_FILES.items()}

    for plural in ENTITY_FILES.values():
        _check_unique_ids(items[plural], plural, f"{plural}.json")

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
        if port.get("produces") and port.get("demands"):
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
        for stat in item["modifiers"]:
            if stat not in EQUIPMENT_STAT_NAMES:
                fail(
                    "ref",
                    "equipment.json",
                    f"equipment[{index}] ({item['id']}) modifiers has unknown stat {stat!r}",
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
        if quest["type"] == "exploration":
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
    if value.get("zh") != zh or value.get("en") != en:
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

    _locked_id_sets(ports, LOCKED_PORTS, "ports", "ports.json")
    _locked_id_sets(goods, LOCKED_GOODS, "goods", "goods.json")
    _locked_id_sets(ship_types, LOCKED_SHIP_TYPES, "ship_types", "ship_types.json")
    _locked_id_sets(nations, LOCKED_NATIONS, "nations", "nations.json")
    _locked_id_sets(officers, LOCKED_OFFICERS, "officers", "officers.json")

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
        (
            zh,
            en,
            nation_id,
            marker,
            x,
            y,
            produces,
            demands,
        ) = LOCKED_PORTS[port["id"]]
        path = f"ports[{index}]"
        _check_l10n_text(port, "name", zh, en, path, "ports.json")
        expected = {
            "nation_id": nation_id,
            "marker": marker,
            "position": {"x": x, "y": y},
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

    if verbose:
        print(
            "PASS group 5 locked lists (30 ports, 20 goods, 8 ship types, "
            "6 nations, 6 officers)"
        )


# ---------------------------------------------------------------------------
# Check group 6 — Map (implemented by T3)
# ---------------------------------------------------------------------------


def check_group6(docs: dict[str, object], verbose: bool) -> None:
    """Map checks: docs/10-DATA-SCHEMA.md section 8, group 6.

    Boundary: this body is intentionally a no-op placeholder.
    # group 6 implemented by T3
    T3 replaces the placeholder inside this function with: map file presence and
    96x128 dimensions, charset membership against `map_legend.tiles`, each port
    marker appearing exactly once at its section 7.1 `position` (agreement with
    `map_legend.port_markers` and `Port.marker`), >=1 orthogonally adjacent `#`
    per marker tile, and 8-directional BFS sea-reachability from Lisbon. All of
    its failures must call fail(..., code=6); nothing else in this file needs to
    change, since main() already runs group 6 last.
    """
    map_path = DATA_DIR / "maps" / "p1_mediterranean.txt"
    if not map_path.exists():
        if verbose:
            print("SKIP group 6 map (data/maps/p1_mediterranean.txt absent; T3)")
        return

    # Nothing to validate yet: T3 fills this in. Presence alone is not an error.
    if verbose:
        print("SKIP group 6 map (map file present; checks land with T3)")


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
