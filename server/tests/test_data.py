"""server.tests.test_data — the DataLoader parity suite (M1).

Port of the guarantee, not the method (AGENTS.md test discipline): the
GDScript harnesses boot the engine and walk the loaded autoload; here a
few deterministic assertions pin the contract that matters — the real
shipped ``data/`` tree loads through ``server/sim/data`` with every
loader key present, the §7 locked counts, byte-level shape fidelity, the
read-only tool-built artifacts, and the loud-refusal error behavior
(docs/90-ARCHITECTURE.md §5.2; oracle: ``autoload/data_loader.gd``;
locked lists: docs/10-DATA-SCHEMA.md §7).

Corrupted fixtures are written under pytest's ``tmp_path`` (i.e. /tmp) —
never under ``data/``.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

import pytest

from server.sim.data import (
    DATA_DIR,
    HARBORS_JSON_PATH,
    MAPS_JSON_PATH,
    DataError,
    DataStore,
    data,
)

# The loader-key inventory (docs/90-* §5.2): every store member the
# GDScript DataLoader builds, with its container type.
_ID_KEYED: tuple[str, ...] = (
    "ports", "goods", "ship_types", "nations", "officers", "equipment",
    "discoveries", "quests", "named_pirates", "market_events",
    "wind_regions", "ocean_currents", "ice_regions", "captains",
    "backgrounds", "skill_gates", "officer_posts", "trade_routes",
)
_RAW_TABLES: tuple[str, ...] = (
    "trade_routes_built", "facility_hours", "captain_name_parts",
    "ui_strings", "map_legend", "npc_config",
)


def _raw(fname: str) -> Any:
    return json.loads((DATA_DIR / fname).read_bytes())


def test_loader_key_inventory() -> None:
    store = data()
    assert store.load_ok is True
    assert store.load_errors == []
    for key in _ID_KEYED:
        table = getattr(store, key)
        assert isinstance(table, dict) and table, key
        entries = getattr(store, f"{key}_list")
        assert isinstance(entries, list) and entries, f"{key}_list"
        # Id-keyed index covers exactly the file order (no entry dropped).
        assert len(table) == len(entries), key
    for key in _RAW_TABLES:
        table = getattr(store, key)
        assert isinstance(table, dict) and table, key
    assert store.map_index == [json.loads(MAPS_JSON_PATH.read_bytes())["maps"][0]]
    assert store.map_ids() == ["world"]
    # ui_strings is type-pure: the envelope 'version' key is metadata.
    assert "version" not in store.ui_strings
    assert store.ui_strings["ui.back"] == {"zh": "返回", "en": "Back"}


def test_locked_content_counts() -> None:
    """The docs/10-* §7 locked lists (task ledger numbers, 2026-11-11)."""
    store = data()
    assert len(store.ports) == 150  # 105 sovereign + the Phase-6 neutral tier
    assert sum(1 for p in store.ports_list if p["nation_id"] != "") == 105
    assert sum(1 for p in store.ports_list if p["nation_id"] == "") == 45
    assert len(store.goods) == 40
    assert len(store.ship_types) == 16
    assert len(store.nations) == 6
    assert len(store.officers) == 96
    assert len(store.trade_routes_list) == 21  # §7.6 locked lane ids
    assert len(store.named_pirates) == 4
    assert len(store.backgrounds) == 6
    assert len(store.equipment) == 24
    # data/ui_layout.json survives the M6 cutover as the web-era layout
    # data (10-* §4.23 final disposition) — the 32-screen set stays loaded.
    assert len(store.ui_layout) == 32


def test_get_port_round_trips_json_bytes() -> None:
    """get_port('lisbon') is the ports.json entry exactly as parsed — the
    loader normalizes nothing."""
    expected = next(p for p in _raw("ports.json")["ports"] if p["id"] == "lisbon")
    assert isinstance(expected["lat"], float) and isinstance(expected["lon"], float)
    assert data().get_port("lisbon") == expected


def test_accessor_contracts() -> None:
    store = data()
    # Gates key by feature_id, posts by post_id (10-* §4.20/§4.21).
    assert store.get_skill_gate("sail.autopilot")["threshold"] == 40
    assert store.get_officer_post("pilot")["post_id"] == "pilot"
    # Named pirates are v2 full captain cards with a rare-equipment drop.
    pirate = store.get_named_pirate("pirate_redbeard_khair")
    assert pirate["id"] == "pirate_redbeard_khair" and "drop" in pirate
    # Built lanes key by lane id; spokes key by port id (10-* §4.14).
    assert store.get_route_lane("carreira_da_india")["id"] == "carreira_da_india"
    assert store.get_route_lane("carreira_da_india")["tile_path"]
    spoke = store.get_route_spoke("lisbon")
    assert spoke["port"] == "lisbon" and spoke["tile_path"]
    # The junction graph the runtime routes over.
    graph = store.route_junction_graph()
    assert set(graph) == {"node_count", "nodes", "edge_count", "edges"}
    # Every lookup misses to {} — never None (GDScript _lookup semantics).
    for miss in (
        store.get_port("not_a_port"), store.get_skill_gate("nope"),
        store.get_route_spoke("not_a_port"), store.get_ui_string("no.such"),
        store.get_map("nope"), store.get_map_legend("nope"),
    ):
        assert miss == {}


def test_map_index_and_legend() -> None:
    store = data()
    entry = store.get_map("world")
    assert entry["id"] == "world"
    assert entry["file"] == "data/maps/world.png"
    files = store.get_map_files("world")
    assert files["id"] == "world" and files["file"] == "data/maps/world.png"
    assert "grid" in files["legend"] and "tiles" in files["legend"]
    # The legend the index binds is the loaded map_legend (10-* §9.1).
    assert store.get_map_legend("world") == store.map_legend


def test_tool_built_files_load_read_only() -> None:
    """The tool-built artifacts (never hand-edited per AGENTS.md) load
    through the same store, byte-faithful."""
    store = data()
    # officers.json v2: the 96-entry person-card roster (10-* §4.5).
    assert _raw("officers.json")["version"] == 2
    assert store.get_officer(store.officers_list[0]["id"]) is store.officers_list[0]
    # trade_routes_built.json mirrors the authored sources' 21 lanes and
    # carries exactly one spoke per port (10-* §4.14 builder rules).
    built = store.trade_routes_built
    assert built["version"] == 1 and built["lanes"] and built["spokes"]
    assert len(built["lanes"]) == len(store.trade_routes_list) == 21
    assert len(built["spokes"]) == len(store.ports) == 150
    graph = built["junctions"]
    assert len(graph["nodes"]) == graph["node_count"] > 0
    assert len(graph["edges"]) == graph["edge_count"] > 0
    # harbors.json: one berth+shore row per port (the §6.3/§8.1 snap output;
    # consumed by the raster module, exposed here as a path seam).
    harbors = json.loads(HARBORS_JSON_PATH.read_bytes())
    assert harbors["version"] == 1
    assert len(harbors["harbors"]) == len(store.ports)
    lisbon_row = next(h for h in harbors["harbors"] if h["id"] == "lisbon")
    assert len(lisbon_row["berth"]) == 2 and len(lisbon_row["shore"]) == 2
    # captains.json: the built canon indexed by id.
    assert _raw("captains.json")["version"] == 1
    assert store.get_captain(store.captains_list[0]["id"]) is store.captains_list[0]


def _temp_data_root(tmp_path: Path) -> Path:
    """A throwaway repo root whose data/ symlinks the real tree — corrupted
    fixtures replace single symlinks, never files under ``data/``."""
    root = tmp_path / "repo"
    data_dir = root / "data"
    data_dir.mkdir(parents=True)
    for src in DATA_DIR.rglob("*"):
        dst = data_dir / src.relative_to(DATA_DIR)
        if src.is_dir():
            dst.mkdir()
        else:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.symlink_to(src)
    return root


def test_corrupted_file_raises_data_error(tmp_path: Path) -> None:
    """A corrupt data file must refuse the load loudly, naming the file and
    the problem — and never touch the real tree."""
    real = DATA_DIR / "ports.json"
    digest = hashlib.sha256(real.read_bytes()).hexdigest()
    root = _temp_data_root(tmp_path)
    bad = root / "data" / "ports.json"
    bad.unlink()
    bad.write_bytes(b'{"version": 1, "ports": [ {"id": "lisbon", ', )
    with pytest.raises(DataError) as excinfo:
        DataStore(root / "data").load_all()
    assert "ports.json" in str(excinfo.value)
    assert "JSON parse error" in str(excinfo.value)
    assert hashlib.sha256(real.read_bytes()).hexdigest() == digest


def test_missing_file_raises_data_error(tmp_path: Path) -> None:
    root = _temp_data_root(tmp_path)
    (root / "data" / "goods.json").unlink()
    with pytest.raises(DataError) as excinfo:
        DataStore(root / "data").load_all()
    assert "goods.json" in str(excinfo.value)
    assert "file not found" in str(excinfo.value)


def test_shape_violation_raises_data_error(tmp_path: Path) -> None:
    """Valid JSON that fails a shape check refuses the same way (the
    map-index single-entry gate — no fallback ladder, 90-* §9.1)."""
    root = _temp_data_root(tmp_path)
    bad = root / "data" / "maps" / "maps.json"
    bad.unlink()  # replace the symlink, never write through to data/
    bad.write_bytes(b'{"version": 1, "maps": []}')
    with pytest.raises(DataError) as excinfo:
        DataStore(root / "data").load_all()
    assert "maps" in str(excinfo.value).lower()


def test_reload_is_idempotent() -> None:
    store = data()
    assert data() is store  # the singleton mirrors the autoload role
    store.load_all()  # a second full load reproduces the same store
    assert store.load_ok is True
    assert store.load_errors == []
    assert len(store.ports) == 150
    assert store.get_port("lisbon") == next(
        p for p in _raw("ports.json")["ports"] if p["id"] == "lisbon")
