# Vendored source data & code — licensing notes

This directory holds the **inputs** to `tools/build_world.py`. None of it is
shipped to players; the shipped artifact is the generated raster
`data/maps/world.png` (plus its report `data/maps/world_report.json`).

## 1. Coastline data — Natural Earth 10 m (public domain)

| File | Source URL |
|---|---|
| `ne_10m_land.{shp,shx,dbf,prj,cpg}` | `https://naciscdn.org/naturalearth/10m/physical/ne_10m_land.zip` |
| `ne_10m_minor_islands.{shp,shx,dbf,prj,cpg}` | `https://naciscdn.org/naturalearth/10m/physical/ne_10m_minor_islands.zip` |
| `ne_10m_lakes.{shp,shx,dbf,prj,cpg}` | `https://naciscdn.org/naturalearth/10m/physical/ne_10m_lakes.zip` |

- **Download date:** 2026-10-30.
- **Licence:** Natural Earth is in the **public domain**. No permission is
  needed to use, modify, or redistribute the data, and **no attribution is
  required** — Natural Earth asks only that it be credited, which we do here
  and in `docs/10-DATA-SCHEMA.md` §6.3 (provenance).
  Terms: <https://www.naturalearthdata.com/about/terms-of-use/>
  ("All versions of Natural Earth raster + vector map data ... are in the
  public domain.").
- **Attribution (courtesy, not obligation):** *Made with Natural Earth.*
- **`prj` / `cpg`:** the `.prj` is the WGS84 (`EPSG:4326`) CRS the builder
  assumes; `.cpg` is the DBF code page. Neither is read by the builder, but
  both travel with the shapefile set so the vendor drop is self-describing.

### SHA-256 of the vendored geometry files

```
4cad3a49bc75c1a4c2f3d7efae04f2f8e63151c96764b2658effabf524331fa6  ne_10m_land.shp
f3b02a190c3020eeafd0f48de982619826b57ecd853cbc68e4fc049652891a04  ne_10m_land.shx
e422520372e65c6fb8220888580e5331d04699bcd71c27e53ad42e241a531cbd  ne_10m_land.dbf
efc446b18c3496c88ccec8cfe937f1af3f3f8c2dd1b63d9722a153b0744f0b48  ne_10m_minor_islands.shp
6bbc71e9fce78dca5e7b811155a488358250ab72bf66dd0deb9a697e1f572c59  ne_10m_minor_islands.shx
f3ecdcdffe964cfbb855c107c0ea39fff38072ad2d5362a06544145a386bc81b  ne_10m_minor_islands.dbf
11064fa55ed91b56a0d86733643c1a5bfcc137fdf044e83f471978a5b86617e1  ne_10m_lakes.shp
a11ffb02e862b6c4ec8c015e6e0c70502f21bc71dcd79312b8dbc676f7e4c557  ne_10m_lakes.shx
0edaa87f76c2221c986f0796ce0b54b1c418e9032afba46f8e302edc41193495  ne_10m_lakes.dbf
```

`build_world.py` recomputes these on every run and records them in
`data/maps/world_report.json#sources`; a mismatch is a loud failure. That,
plus the stable polygon order, is what makes the raster identical on every
machine (`docs/IMPLEMENT-Phase4.md` → *Risks*: "Shapefile/dependency drift").

**Do not edit these files.** Refining the map means changing
`tools/map_overrides.json` (waterways) or the builder, never the shoreline
source; and never hand-editing `data/maps/world.png`.

## 2. Vendored code — pyshp 3.1.6 (MIT)

`tools/vendor/pyshp.py` is an unmodified copy of `shapefile.py` from the
`pyshp` 3.1.6 wheel (pure Python, no dependencies beyond the stdlib).

- **Upstream:** <https://github.com/GeospatialPython/pyshp>
- **Licence:** MIT — full text in `tools/vendor/LICENSE-pyshp.txt`
  (Copyright © 2013 Joel Lawhead).
- **Why vendored:** the build must run offline with `python3` only; a vendored
  pure-Python reader is explicitly allowed by task C, and writing a `.shp`
  parser by hand would be a needless correctness risk.
- **Import:** `tools/build_world.py` inserts `tools/vendor/` on `sys.path` and
  does `import pyshp as shapefile`. `tools/requirements.txt` therefore pins
  **nothing** (see that file).

## 3. Generated artifacts

`data/maps/world.png` and `data/maps/world_report.json` are generated, not
authored. Regenerate with:

```
python3 tools/build_world.py                    # writes data/maps/world.png + world_report.json
python3 tools/build_world.py --ascii --rows 300:340   # debug view, prints to stdout
```

## 4. `tools/map_overrides.json`

Hand-authored **waterway carves** applied after the terrain passes. The
builder tolerates the file being absent (it then carves nothing) — the file
committed with `"overrides": []` is a schema stub that task D fills in.

Entry shape (the schema the builder consumes):

```json
{
  "version": 1,
  "overrides": [
    {
      "name": "gibraltar",
      "path": [[35.95, -5.60], [35.90, -5.32], [36.05, -5.10]],
      "min_width_tiles": 1
    }
  ]
}
```

- `name` — unique string; it is the key in `world_report.json#overrides` and in
  every failure message the builder prints.
- `path` — list of `[lat, lon]` WGS84 points, in order, ≥ 2 points. The
  polyline is walked at 1/20-tile resolution and converted to an ordered
  4-connected tile chain (diagonal steps are bridged with an orthogonal tile),
  so a one-tile channel is contiguous by construction.
- `min_width_tiles` — integer ≥ 1; omitted means `1`. The channel is realised
  at Chebyshev radius `min_width_tiles // 2`, i.e. width 1 → 1 tile,
  width 2–3 → 3 tiles, width 4–5 → 5 tiles. After carving, the builder
  **asserts** three things and exits non-zero naming the waterway otherwise:
  every channel tile is water; the perpendicular water run at every channel
  tile is at least `min_width_tiles`; and the channel's first and last tiles
  are in the same passable component (the carve actually joins the seas it was
  meant to join).
- Overrides may only turn **land/ice into water** (they carve, never fill).
  Cells changed per override are logged in `world_report.json#overrides`;
  `#override_details` records the channel tile count and width actually
  realised.

## 5. Credits

Natural Earth (public domain) for the shorelines. pyshp (MIT) for the
shapefile reader. The tile grid, palette, snap rule and ice rule are SailAge's
own — see `docs/10-DATA-SCHEMA.md` §6.
