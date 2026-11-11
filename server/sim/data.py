"""server.sim.data — the DataLoader port (Godot → Python, M1).

Normative contract: ``docs/90-ARCHITECTURE.md`` §5.2 (DataLoader) read in
the light of §0 (the web-stack era — this module is the server-side
replacement of the autoload; the GDScript tree stays the parity oracle).
Artifact inventory, file envelope and the i18n rule: ``docs/10-DATA-SCHEMA.md``
§2 / §3. Oracle file: ``autoload/data_loader.gd`` (frozen read-only).

Loads every ``data/*.json`` at startup into typed dictionaries keyed by id
(exactly the loader-key set the GDScript autoload builds, plus the two
envelope files the task ledger adds to the key set: ``trade_routes.json``
— read raw by ``scripts/port/allegiance.gd`` in the Godot era — and
``captain_name_parts.json``, the canon builder's authored source). Each
file's dict shape is kept EXACTLY as parsed: no normalization, no key
remapping — downstream systems index these shapes.

Error behavior: every problem is recorded (file + problem, mirrored from
the GDScript ``_record`` messages) and loading continues so one pass
reports every file's problems; at the end a loud :class:`DataError` is
raised — the Python server must refuse to start on invalid data exactly
like the GDScript title screen refuses (90-§5.2). Loading is idempotent:
:meth:`DataStore.load_all` re-reads everything deterministically, and the
module-level singleton accessor :func:`data` mirrors the autoload role.

Raster seam (deliberately NOT ported here): the GDScript loader hands the
world PNG off to MapLoader / OceanLayers (90-§9). This module exposes the
FILE PATHS (``WORLD_PNG_PATH``, ``WIND_REGIONS_PNG_PATH``,
``CURRENTS_PNG_PATH``, ``DIST_LAND_PATH``) and decodes no raster; the
decode lives in ``server/sim/world/raster.py`` (in flight).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Final

__all__ = [
    "DATA_DIR",
    "REPO_ROOT",
    "MAPS_DIR",
    "MAPS_JSON_PATH",
    "WORLD_PNG_PATH",
    "WIND_REGIONS_PNG_PATH",
    "CURRENTS_PNG_PATH",
    "DIST_LAND_PATH",
    "HARBORS_JSON_PATH",
    "DEFAULT_MAP_ID",
    "DataError",
    "DataStore",
    "data",
]

# Paths resolve from the REPO ROOT (data/ is a sibling of server/).
REPO_ROOT: Final[Path] = Path(__file__).resolve().parents[2]
DATA_DIR: Final[Path] = REPO_ROOT / "data"

# The raster/map handoff seam (90-§9; no decoding in this module).
MAPS_DIR: Final[Path] = DATA_DIR / "maps"
MAPS_JSON_PATH: Final[Path] = MAPS_DIR / "maps.json"
WORLD_PNG_PATH: Final[Path] = MAPS_DIR / "world.png"
WIND_REGIONS_PNG_PATH: Final[Path] = MAPS_DIR / "wind_regions.png"
CURRENTS_PNG_PATH: Final[Path] = MAPS_DIR / "currents.png"
DIST_LAND_PATH: Final[Path] = MAPS_DIR / "dist_land.png"
HARBORS_JSON_PATH: Final[Path] = MAPS_DIR / "harbors.json"

## The locked map id (docs/90-* §5.4: `world.map_id` is always this value).
DEFAULT_MAP_ID: Final[str] = "world"

# ui_layout.json v2 screen whitelist + element keys, verbatim from the
# GDScript _parse_ui_layout consts (docs/10-* §4.23; heavy validation is
# validator group 14).
_UI_LAYOUT_SCREENS: Final[frozenset[str]] = frozenset({
    "port", "market", "inn", "guild", "provisions",
    "palace", "tavern", "shipyard",
    "title", "nationality_select", "creation",
    "world", "chart", "hail", "fleet_picker", "autopilot_hud",
    "battle", "sandbox", "duel",
    "confirm", "save_slot", "settings", "intel_window",
    "dialog_box", "dossier", "character_card", "captain_view",
    "fleet_view", "officer_roster", "reputation_view", "gameover",
    "ending",
})
_UI_LAYOUT_ELEMENT_KEYS: Final[frozenset[str]] = frozenset(
    {"x", "y", "w", "h", "sheet"})


class DataError(RuntimeError):
    """Raised when the data tree fails to load — the server refuses to start."""


class DataStore:
    """The loaded data tree — one instance plays DataLoader's autoload role.

    Member names mirror the GDScript vars verbatim (snake_case). Id-keyed
    entity tables sit next to their insertion-ordered ``*_list`` copies (UI
    iteration and the Phase-6 raster index map use the lists — 10-§6.5:
    palette index i of wind_regions.png is ``wind_regions_list[i - 1]``).
    """

    def __init__(self, data_dir: Path | None = None) -> None:
        self._data_dir: Final[Path] = data_dir if data_dir is not None else DATA_DIR
        self._repo_root: Final[Path] = self._data_dir.parent
        self._ui_layout_bytes: str = ""
        self.load_ok: bool = False
        self.load_errors: list[str] = []

        # Id-keyed entity dictionaries (docs/90-* §5.2).
        self.ports: dict[str, Any] = {}
        self.goods: dict[str, Any] = {}
        self.ship_types: dict[str, Any] = {}
        self.nations: dict[str, Any] = {}
        self.officers: dict[str, Any] = {}
        self.equipment: dict[str, Any] = {}
        self.discoveries: dict[str, Any] = {}
        self.quests: dict[str, Any] = {}
        self.named_pirates: dict[str, Any] = {}
        self.market_events: dict[str, Any] = {}
        self.wind_regions: dict[str, Any] = {}
        self.ocean_currents: dict[str, Any] = {}
        self.ice_regions: dict[str, Any] = {}
        self.captains: dict[str, Any] = {}
        self.backgrounds: dict[str, Any] = {}
        self.skill_gates: dict[str, Any] = {}
        self.officer_posts: dict[str, Any] = {}
        self.trade_routes: dict[str, Any] = {}

        # Insertion-ordered lists copied from the JSON arrays.
        self.ports_list: list[Any] = []
        self.goods_list: list[Any] = []
        self.ship_types_list: list[Any] = []
        self.nations_list: list[Any] = []
        self.officers_list: list[Any] = []
        self.equipment_list: list[Any] = []
        self.discoveries_list: list[Any] = []
        self.quests_list: list[Any] = []
        self.named_pirates_list: list[Any] = []
        self.market_events_list: list[Any] = []
        self.captains_list: list[Any] = []
        self.backgrounds_list: list[Any] = []
        self.skill_gates_list: list[Any] = []
        self.officer_posts_list: list[Any] = []
        self.wind_regions_list: list[Any] = []
        self.ocean_currents_list: list[Any] = []
        self.ice_regions_list: list[Any] = []
        self.trade_routes_list: list[Any] = []

        # Lanes and spokes of the built route artifact, id-keyed for lookup.
        self.route_lanes: dict[str, Any] = {}
        self.route_spokes: dict[str, Any] = {}

        # Raw (NOT id-keyed) tables.
        self.trade_routes_built: dict[str, Any] = {}
        self.facility_hours: dict[str, Any] = {}
        self.captain_name_parts: dict[str, Any] = {}
        self.ui_strings: dict[str, Any] = {}
        self.map_legend: dict[str, Any] = {}
        self.npc_config: dict[str, Any] = {}
        self.ui_layout: dict[str, Any] = {}

        # Map index (data/maps/maps.json): exactly one entry, id "world".
        self.map_index: list[Any] = []

    # --- Queries ------------------------------------------------------------

    def _lookup(self, table: dict[str, Any], key: str) -> dict[str, Any]:
        value = table.get(key)
        return value if isinstance(value, dict) else {}

    def get_port(self, id: str) -> dict[str, Any]:
        return self._lookup(self.ports, id)

    def get_good(self, id: str) -> dict[str, Any]:
        return self._lookup(self.goods, id)

    def get_ship_type(self, id: str) -> dict[str, Any]:
        return self._lookup(self.ship_types, id)

    def get_nation(self, id: str) -> dict[str, Any]:
        return self._lookup(self.nations, id)

    def get_officer(self, id: str) -> dict[str, Any]:
        return self._lookup(self.officers, id)

    def get_equipment(self, id: str) -> dict[str, Any]:
        return self._lookup(self.equipment, id)

    def get_discovery(self, id: str) -> dict[str, Any]:
        return self._lookup(self.discoveries, id)

    def get_quest(self, id: str) -> dict[str, Any]:
        return self._lookup(self.quests, id)

    def get_named_pirate(self, id: str) -> dict[str, Any]:
        return self._lookup(self.named_pirates, id)

    def get_market_event(self, id: str) -> dict[str, Any]:
        return self._lookup(self.market_events, id)

    def get_captain(self, id: str) -> dict[str, Any]:
        return self._lookup(self.captains, id)

    def get_background(self, id: str) -> dict[str, Any]:
        return self._lookup(self.backgrounds, id)

    def get_skill_gate(self, feature_id: str) -> dict[str, Any]:
        return self._lookup(self.skill_gates, feature_id)

    def get_officer_post(self, post_id: str) -> dict[str, Any]:
        return self._lookup(self.officer_posts, post_id)

    def get_wind_region(self, id: str) -> dict[str, Any]:
        return self._lookup(self.wind_regions, id)

    def get_ocean_current(self, id: str) -> dict[str, Any]:
        return self._lookup(self.ocean_currents, id)

    def get_ice_region(self, id: str) -> dict[str, Any]:
        return self._lookup(self.ice_regions, id)

    def get_route_lane(self, id: str) -> dict[str, Any]:
        return self._lookup(self.route_lanes, id)

    def get_route_spoke(self, port_id: str) -> dict[str, Any]:
        return self._lookup(self.route_spokes, port_id)

    def get_trade_route(self, id: str) -> dict[str, Any]:
        return self._lookup(self.trade_routes, id)

    def route_junction_graph(self) -> dict[str, Any]:
        """The junction graph the runtime routes over: ``{node_count, nodes,
        edge_count, edges}`` — nodes ``[x, y]`` tiles, edges
        ``[a, b, tile_length]`` index pairs (docs/10-* §4.14)."""
        graph = self.trade_routes_built.get("junctions")
        return graph if isinstance(graph, dict) else {}

    def get_ui_string(self, key: str) -> dict[str, Any]:
        """L10nString for a UI key, or ``{}`` when the key is absent."""
        value = self.ui_strings.get(key)
        return value if isinstance(value, dict) else {}

    # --- Map index (docs/90-* §9.1) -----------------------------------------

    def map_ids(self) -> list[str]:
        """Every selectable map id, in ``maps.json`` order. Phase 4 ships
        exactly one: ``["world"]``. No fallback ladder — a missing index is
        a data error."""
        out: list[str] = []
        for entry in self.map_index:
            if isinstance(entry, dict):
                id = str(entry.get("id", ""))
                if id:
                    out.append(id)
        return out

    def get_map(self, map_id: str) -> dict[str, Any]:
        """The index entry for ``map_id`` (``{id, file, legend, name}``), or
        ``{}`` when the id is not in the index (a logged data error, never a
        silent fallback). The miss is console-only — mirroring the GDScript
        ``push_error``, it does not dirty ``load_errors`` after a clean
        boot."""
        for entry in self.map_index:
            if isinstance(entry, dict) and str(entry.get("id", "")) == map_id:
                return entry
        print(f"DataLoader: maps/maps.json: '{map_id}' is not in "
              "data/maps/maps.json (docs/90-* §9.1)", file=sys.stderr)
        return {}

    def get_map_legend(self, map_id: str) -> dict[str, Any]:
        """The legend record for ``map_id`` — one legend for one map."""
        return self.map_legend if map_id in self.map_ids() else {}

    def get_map_files(self, map_id: str) -> dict[str, Any]:
        """Resolves the map's data file and legend together (what a loader
        needs). No raster decoding here — the raster module consumes
        ``file`` against the ``*_PNG_PATH`` seams."""
        entry = self.get_map(map_id)
        if not entry:
            return {}
        id = str(entry.get("id", map_id))
        return {
            "id": id,
            "file": str(entry.get("file", "")),
            "legend": self.get_map_legend(id),
        }

    # --- Loading ------------------------------------------------------------

    def load_all(self) -> None:
        """Loads every data file; idempotent. Raises :class:`DataError`
        listing every problem when anything failed to load or shape-check —
        the server must not start on invalid data (90-§5.2)."""
        self.load_ok = False
        self.load_errors = []

        self.ports_list = self._load_list("ports", "ports.json")
        self.ports = self._index_by_id(self.ports_list, "ports.json")

        self.goods_list = self._load_list("goods", "goods.json")
        self.goods = self._index_by_id(self.goods_list, "goods.json")

        self.ship_types_list = self._load_list("ship_types", "ship_types.json")
        self.ship_types = self._index_by_id(self.ship_types_list, "ship_types.json")

        self.nations_list = self._load_list("nations", "nations.json")
        self.nations = self._index_by_id(self.nations_list, "nations.json")

        self.officers_list = self._load_list("officers", "officers.json")
        self.officers = self._index_by_id(self.officers_list, "officers.json")

        self.equipment_list = self._load_list("equipment", "equipment.json")
        self.equipment = self._index_by_id(self.equipment_list, "equipment.json")

        self.discoveries_list = self._load_list("discoveries", "discoveries.json")
        self.discoveries = self._index_by_id(self.discoveries_list, "discoveries.json")

        self.quests_list = self._load_list("quests", "quests.json")
        self.quests = self._index_by_id(self.quests_list, "quests.json")

        # Phase 5 living economy (docs/10-* §4.10–4.13). Phase 8 retires
        # npc_captains.json (the name pools — docs/10-* §7.7).
        self.npc_config = self._load_npc_config()
        self.named_pirates_list = self._load_list("named_pirates", "named_pirates.json")
        self.named_pirates = self._index_by_id(self.named_pirates_list, "named_pirates.json")
        self.market_events_list = self._load_list("market_events", "market_events.json")
        self.market_events = self._index_by_id(self.market_events_list, "market_events.json")

        # Phase 6 seasonal ocean layers (docs/10-* §4.16–4.18): plural key ==
        # basename, so the ordinary entity-file path loads them (§3.2). The
        # baked lookups live in the rasters (decoded by the raster module,
        # not here); these tables are the authored sources.
        self.wind_regions_list = self._load_list("wind_regions", "wind_regions.json")
        self.wind_regions = self._index_by_id(self.wind_regions_list, "wind_regions.json")
        self.ocean_currents_list = self._load_list("ocean_currents", "ocean_currents.json")
        self.ocean_currents = self._index_by_id(self.ocean_currents_list, "ocean_currents.json")
        self.ice_regions_list = self._load_list("ice_regions", "ice_regions.json")
        self.ice_regions = self._index_by_id(self.ice_regions_list, "ice_regions.json")

        # Tool-owned route artifact (docs/10-* §4.14) — not an entity file.
        # The authored lane sources load alongside (the built lanes carry no
        # nations; the sources remain the single truth).
        self.trade_routes_list = self._load_list("lanes", "trade_routes.json")
        self.trade_routes = self._index_by_key(self.trade_routes_list, "id", "trade_routes.json")
        self.trade_routes_built = self._load_trade_routes_built()
        self.route_lanes = self._index_route_lanes(self.trade_routes_built)
        self.route_spokes = self._index_route_spokes(self.trade_routes_built)

        # Facility opening hours (docs/10-* §4.19) — a plain object file,
        # like npc_config.
        self.facility_hours = self._load_facility_hours()

        # Phase-8 canon/data files (docs/10-* §4.11, §4.20–§4.22): plural key
        # == basename for the envelopes. Captains are the tool-built canon
        # (never hand-edited); captain_name_parts is the canon builder's
        # authored source (a config-object file, not an envelope).
        self.captains_list = self._load_list("captains", "captains.json")
        self.captains = self._index_by_id(self.captains_list, "captains.json")
        self.captain_name_parts = self._load_captain_name_parts()
        self.backgrounds_list = self._load_list("backgrounds", "backgrounds.json")
        self.backgrounds = self._index_by_id(self.backgrounds_list, "backgrounds.json")
        self.skill_gates_list = self._load_list("skill_gates", "skill_gates.json")
        self.skill_gates = self._index_by_key(self.skill_gates_list, "feature_id", "skill_gates.json")
        self.officer_posts_list = self._load_list("officer_posts", "officer_posts.json")
        self.officer_posts = self._index_by_key(self.officer_posts_list, "post_id", "officer_posts.json")

        self.ui_strings = self._load_ui_strings()
        self.map_legend = self._load_map_legend()
        self.ui_layout = self._load_ui_layout()
        self._load_map_index()

        self.load_ok = not self.load_errors
        if self.load_errors:
            raise DataError(
                f"DataLoader: {len(self.load_errors)} data error(s); the game "
                "must not start with invalid data (docs/90-* §5.2):\n  - "
                + "\n  - ".join(self.load_errors))

    # --- Loading helpers ----------------------------------------------------

    def _record(self, message: str) -> None:
        self.load_errors.append(message)
        print(f"DataLoader: {message}", file=sys.stderr)

    def _data_path(self, file_name: str) -> Path:
        return self._data_dir / file_name

    def _read_json(self, file_name: str) -> Any:
        """Parses a data file relative to ``data/``; returns ``None`` (and
        records the problem) on any failure. Unlike the GDScript parser no
        float→int normalization is needed: Python's JSON parser keeps the
        schema's ints int."""
        path = self._data_path(file_name)
        if not path.is_file():
            self._record(f"{file_name}: file not found ({path})")
            return None
        text = path.read_text(encoding="utf-8")
        if not text:
            self._record(f"{file_name}: file is empty or unreadable ({path})")
            return None
        try:
            return json.loads(text)
        except json.JSONDecodeError as err:
            self._record(
                f"{file_name}: JSON parse error at line {err.lineno}: {err.msg}")
            return None

    def _load_list(self, plural: str, file_name: str) -> list[Any]:
        data = self._read_json(file_name)
        if data is None:
            return []
        if not isinstance(data, dict):
            self._record(f"{file_name}: top-level value must be an object")
            return []
        version = data.get("version")
        if isinstance(version, bool) or not isinstance(version, int):
            self._record(f"{file_name}: envelope is missing an integer 'version'")
        entries = data.get(plural)
        if not isinstance(entries, list):
            self._record(f"{file_name}: missing array '{plural}'")
            return []
        return entries

    def _index_by_id(self, entries: list[Any], file_name: str) -> dict[str, Any]:
        return self._index_by_key(entries, "id", file_name)

    def _index_by_key(self, entries: list[Any], key_field: str, file_name: str) -> dict[str, Any]:
        """Indexes a list by an arbitrary string key field (``feature_id``
        for the gates, ``post_id`` for the posts — docs/10-* §4.20–§4.21)."""
        table: dict[str, Any] = {}
        for index, entry in enumerate(entries):
            if not isinstance(entry, dict):
                self._record(f"{file_name}[{index}]: entry must be an object")
                continue
            id = entry.get(key_field)
            if not isinstance(id, str) or not id:
                self._record(
                    f"{file_name}[{index}]: entry has no string '{key_field}'")
                continue
            if id in table:
                self._record(f"{file_name}[{index}]: duplicate id '{id}'")
                continue
            table[id] = entry
        return table

    def _load_ui_strings(self) -> dict[str, Any]:
        raw = self._read_json("ui_strings.json")
        table: dict[str, Any] = {}
        if raw is None:
            return table
        if not isinstance(raw, dict):
            self._record("ui_strings.json: top-level value must be an object")
            return table
        for key, value in raw.items():
            if key == "version":
                # Envelope metadata, not an L10nString; keep the table
                # type-pure.
                continue
            if not isinstance(value, dict):
                self._record(f"ui_strings.json: '{key}' must be an L10nString object")
                continue
            for locale in ("zh", "en"):
                text = value.get(locale)
                if not isinstance(text, str) or not text.strip():
                    self._record(f"ui_strings.json: '{key}.{locale}' is missing or empty")
            table[key] = value
        return table

    def _load_ui_layout(self) -> dict[str, Any]:
        """Reads ``data/ui_layout.json`` — the absolute layout file, v2
        (docs/10-* §4.23, docs/80-* §4.8.9). Light shape checks only — key
        whitelist, types and screen-id membership; the heavy validation is
        group 14 (docs/10-* §8.9). Absent file ⇒ ``{}`` (NOT an error —
        every screen runs unmanaged/flow-free authored until the capture
        populates its table). A file that is not v2 records an error and
        yields ``{}`` (no migration — the capture regenerates it)."""
        path = self._data_path("ui_layout.json")
        if not path.is_file():
            return {}
        text = path.read_text(encoding="utf-8")
        self._ui_layout_bytes = text
        return self._parse_ui_layout(text)

    def reload_ui_layout_if_changed(self) -> None:
        """Re-reads ``ui_layout.json`` when its bytes changed on disk
        (docs/80-* §4.8.9): the studio's commit lands on the next screen
        activation — no restart. A byte-identical file is a no-op. A
        re-read that fails shape-check raises :class:`DataError` (the same
        refusal contract as the boot load)."""
        path = self._data_path("ui_layout.json")
        if not path.is_file():
            return
        text = path.read_text(encoding="utf-8")
        if text == self._ui_layout_bytes:
            return
        errors_before = len(self.load_errors)
        self._ui_layout_bytes = text
        self.ui_layout = self._parse_ui_layout(text)
        if len(self.load_errors) > errors_before:
            raise DataError(
                "DataLoader: ui_layout.json re-read failed:\n  - "
                + "\n  - ".join(self.load_errors[errors_before:]))

    def _parse_ui_layout(self, text: str) -> dict[str, Any]:
        """The v2 shape walk shared by the boot load and the drift reload."""
        table: dict[str, Any] = {}
        try:
            raw = json.loads(text)
        except json.JSONDecodeError as err:
            self._record(f"ui_layout.json: invalid JSON ({err.msg})")
            return table
        if not isinstance(raw, dict):
            self._record("ui_layout.json: top-level value must be an object")
            return table
        if raw.get("version", None) != 2 or isinstance(raw.get("version"), bool):
            self._record("ui_layout.json: 'version' must be 2 (10-* §4.23)")
            return table
        screens = raw.get("screens")
        if not isinstance(screens, dict):
            self._record("ui_layout.json: 'screens' must be an object")
            return table
        for screen, data in screens.items():
            if screen not in _UI_LAYOUT_SCREENS:
                self._record(f"ui_layout.json: unknown screen '{screen}'")
                continue
            if not isinstance(data, dict):
                self._record(f"ui_layout.json: screens.{screen} must be an object")
                continue
            screen_table: dict[str, Any] = {"elements": {}, "lists": {}}
            elements = data.get("elements", {})
            if isinstance(elements, dict):
                for element, rect in elements.items():
                    if not isinstance(rect, dict):
                        self._record(
                            f"ui_layout.json: screens.{screen}.{element} must be an object")
                        continue
                    for key in rect:
                        if key not in _UI_LAYOUT_ELEMENT_KEYS:
                            self._record(
                                f"ui_layout.json: screens.{screen}.{element}: "
                                f"unknown key '{key}'")
                    screen_table["elements"][element] = rect
            else:
                self._record(
                    f"ui_layout.json: screens.{screen}.elements must be an object")
            lists = data.get("lists", {})
            if isinstance(lists, dict):
                screen_table["lists"] = lists
            elif "lists" in data:
                self._record(
                    f"ui_layout.json: screens.{screen}.lists must be an object")
            table[screen] = screen_table
        return table

    def _load_trade_routes_built(self) -> dict[str, Any]:
        """Reads ``data/trade_routes_built.json`` — the route-builder
        artifact (docs/10-* §4.14). A tool output, not an entity file: the
        envelope is ``{version, generated_by, artifact, build, lanes,
        spokes, junctions}``. Read-only — never hand-edited (AGENTS.md)."""
        data = self._read_json("trade_routes_built.json")
        if data is None:
            return {}
        if not isinstance(data, dict):
            self._record("trade_routes_built.json: top-level value must be an object")
            return {}
        version = data.get("version")
        if isinstance(version, bool) or not isinstance(version, int):
            self._record("trade_routes_built.json: missing integer 'version'")
        for key in ("generated_by", "artifact", "build", "lanes", "spokes",
                    "junctions"):
            if key not in data:
                self._record(
                    f"trade_routes_built.json: missing '{key}' (docs/10-* §4.14)")
        junctions = data.get("junctions")
        if isinstance(junctions, dict):
            if not isinstance(junctions.get("nodes"), list):
                self._record("trade_routes_built.json: junctions.nodes must be an array")
            if not isinstance(junctions.get("edges"), list):
                self._record("trade_routes_built.json: junctions.edges must be an array")
        return data

    def _index_route_lanes(self, built: dict[str, Any]) -> dict[str, Any]:
        """Indexes the built lanes by their ``id`` (light shape check only;
        the deep structural checks live in validator group 8, §8.3)."""
        lanes = built.get("lanes")
        if not isinstance(lanes, list):
            return {}
        table: dict[str, Any] = {}
        for index, lane in enumerate(lanes):
            if not isinstance(lane, dict) or not isinstance(lane.get("id"), str):
                self._record(
                    f"trade_routes_built.json: lanes[{index}] has no string 'id'")
                continue
            if not isinstance(lane.get("tile_path"), list):
                self._record(
                    f"trade_routes_built.json: lane '{lane['id']}' has no tile_path")
                continue
            table[lane["id"]] = lane
        return table

    def _index_route_spokes(self, built: dict[str, Any]) -> dict[str, Any]:
        """Indexes the built spokes by their ``port`` (docs/10-* §4.14)."""
        spokes = built.get("spokes")
        if not isinstance(spokes, list):
            return {}
        table: dict[str, Any] = {}
        for index, spoke in enumerate(spokes):
            if not isinstance(spoke, dict) or not isinstance(spoke.get("port"), str):
                self._record(
                    f"trade_routes_built.json: spokes[{index}] has no string 'port'")
                continue
            if not isinstance(spoke.get("tile_path"), list):
                self._record(
                    f"trade_routes_built.json: spoke '{spoke['port']}' has no tile_path")
                continue
            table[spoke["port"]] = spoke
        return table

    def _load_npc_config(self) -> dict[str, Any]:
        """Reads ``data/npc_config.json`` — the density-dial config block
        (docs/10-* §4.10). A config object, not an entity envelope."""
        data = self._read_json("npc_config.json")
        if data is None:
            return {}
        if not isinstance(data, dict):
            self._record("npc_config.json: top-level value must be an object")
            return {}
        for key in ("version", "presets", "default_preset", "budgets", "flow",
                    "absolute_cap"):
            if key not in data:
                self._record(f"npc_config.json: missing '{key}' (docs/10-* §4.10)")
        return data

    def _load_facility_hours(self) -> dict[str, Any]:
        """Reads ``data/facility_hours.json`` — the facility opening-hour
        table (docs/10-* §4.19, 30-* §4.1b). A plain object file: ``default``
        windows per facility id plus optional per-port ``overrides``.
        Shape errors are recorded but never fatal here — the runtime reads
        windows through the sailing sim, which falls back to "always open"
        on a missing entry so a bad file cannot close every port."""
        data = self._read_json("facility_hours.json")
        if data is None:
            return {}
        if not isinstance(data, dict):
            self._record("facility_hours.json: top-level value must be an object")
            return {}
        for key in ("version", "default", "overrides"):
            if key not in data:
                self._record(f"facility_hours.json: missing '{key}' (docs/10-* §4.19)")
        if not isinstance(data.get("default", {}), dict):
            self._record("facility_hours.json: 'default' must be an object")
        if not isinstance(data.get("overrides", {}), dict):
            self._record("facility_hours.json: 'overrides' must be an object")
        return data

    def _load_captain_name_parts(self) -> dict[str, Any]:
        """Reads ``data/captain_name_parts.json`` — the canon builder's
        authored source (docs/10-* §4.11.1): per-nation name parts +
        personality pools + appearance vocabulary. A config-object file
        (top-level object, no plural array); the byte-identity gate lives
        in the builder's ``--check``, not here."""
        data = self._read_json("captain_name_parts.json")
        if data is None:
            return {}
        if not isinstance(data, dict):
            self._record("captain_name_parts.json: top-level value must be an object")
            return {}
        return data

    def _load_map_legend(self) -> dict[str, Any]:
        """Reads ``data/map_legend.json`` — the single legend (docs/90-*
        §9.1). No per-tile port-marker table exists any more: ports are an
        overlay from lat/lon (10-* §6.2, decision 7)."""
        data = self._read_json("map_legend.json")
        if data is None:
            return {}
        if not isinstance(data, dict):
            self._record("map_legend.json: top-level value must be an object")
            return {}
        if "grid" not in data or "tiles" not in data:
            self._record("map_legend.json: missing 'grid' or 'tiles'")
        return data

    def _load_map_index(self) -> None:
        """Reads ``data/maps/maps.json`` (exactly one entry, docs/90-* §9.1)
        and binds its legend. A missing or empty index is a data error:
        there is no P1/P3 fallback ladder any more. File existence is
        checked here; decoding stays in the raster module."""
        self.map_index = []
        data = self._read_json("maps/maps.json")
        if not isinstance(data, dict) or not isinstance(data.get("maps"), list):
            self._record("maps/maps.json: missing 'maps' array (docs/90-* §9.1)")
            return
        self.map_index = list(data["maps"])
        if not self.map_index:
            self._record("maps/maps.json: the index has no entries (docs/90-* §9.1)")
        for entry in self.map_index:
            if not isinstance(entry, dict):
                self._record("maps/maps.json: every entry must be an object")
                continue
            id = str(entry.get("id", ""))
            if not id:
                self._record("maps/maps.json: an entry has no 'id'")
                continue
            legend_path = str(entry.get("legend", ""))
            file_path = str(entry.get("file", ""))
            if not file_path:
                self._record(f"maps/maps.json: '{id}' has no 'file' path")
            else:
                for path in (file_path, legend_path):
                    if path and not (self._repo_root / path).is_file():
                        self._record(
                            f"maps/maps.json: '{id}' names a missing file {path}")
            # The legend file is the same table already loaded as
            # `map_legend`; the index is authoritative about *which* file, so
            # re-read it by that path (a swapped legend file is a data-only
            # change).
            if not legend_path:
                self._record(f"maps/maps.json: '{id}' has no 'legend' path")
                continue
            legend = self._read_json(legend_path.removeprefix("data/"))
            if not isinstance(legend, dict):
                self._record(
                    f"maps/maps.json: legend '{legend_path}' is missing or invalid")
                continue
            if "grid" not in legend or "tiles" not in legend:
                self._record(f"maps/maps.json: legend '{legend_path}' lacks grid/tiles")
                continue
            if id == DEFAULT_MAP_ID:
                self.map_legend = legend


_STORE: DataStore | None = None


def data() -> DataStore:
    """The module-level singleton — mirrors DataLoader's autoload role.

    Loads once, lazily; repeated calls return the same instance (loading
    itself is idempotent via :meth:`DataStore.load_all`). Raises
    :class:`DataError` on the first call if the data tree is invalid — the
    server refuses to start.
    """
    global _STORE
    if _STORE is None:
        store = DataStore()
        store.load_all()
        _STORE = store
    return _STORE
