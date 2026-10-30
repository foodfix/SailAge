# IMPLEMENT — Phase 4: Terra Vera (Single Real-Earth World Map)

**STATUS: 📋 PLANNED (2026-10-30).** No task started.

Ordered, checkable task backlog (letters, coarse by design; **task-owned**
details are decided inside the task per the cited docs). Execute as
background-subagent waves per the plan at the bottom — max 4 concurrent, one
git worktree per subagent, master merges. Prerequisite: Phase 3 complete
(it is: 2026-10-30).

The design decisions below are normative; every
number lives in the [locked-constants table](#locked-constants) and must be
copied into the owning system doc by tasks A/B **before** any code task
starts (`00-OVERVIEW.md` §13 rule). Where this doc and an older doc
disagree, this doc wins until the owning doc is amended, after which the
owning doc wins.

---

## Decision record

1. **One map, not two.** The Phase-1 Mediterranean map and the Phase-3
   world map are replaced by a single world map. The dual-map machinery
   (`map_id` switching, `Port.marker`/`Port.position` vs `Port.p3`,
   `ports_p3.json`, `map_legend_p3.json`, minimap re-scaling per map) is
   retired.
2. **The Earth is the source of truth.** Coastlines are rasterized from
   public-domain shoreline data (Natural Earth 10 m land + minor islands;
   GSHHG acceptable substitute). Port and discovery positions are
   real-world `lat`/`lon` values stored in JSON; the grid cell is derived,
   never hand-placed. This makes map refinement a regeneration, not an
   authoring project.
3. **Grid: 2160 × 1080 = the whole globe at 6 tiles per degree**
   (1 tile = 10′ of latitude = 10 nm). Longitude wraps; circumnavigation
   is a first-class feature. Latitude edges are closed by polar ice tiles.
4. **Simulation stays tile-based.** 8-directional stepping, no corner
   cutting, per-step clock advance, harbor-tile entry — all `20-*` §4
   mechanics survive unchanged; only the grid and its data change. Spherical
   math (haversine, latitude wind bands) is used where real distance
   matters, not for movement.
5. **Presentation stays 2D plate carrée** (`lon = x/6 − 180`,
   `lat = 90 − y/6`). No Mercator: a uniform grid is load-bearing for the
   whole engine. The display projection is a render concern and may be
   revisited later without touching simulation.
6. **Map data leaves ASCII.** 2.3 MB of 2160-char lines is uneditable and
   undiffable. The shipped artifact is an indexed PNG (1 px = 1 tile);
   ASCII export remains a build-tool debug mode only. This amends the
   AGENTS.md hard rule "World map is ASCII text" (task A).
7. **Marker chars leave the map.** 100 ports cannot fit a readable charset
   in terrain (the Phase-3 Latin-1 hack proved it). Ports render as an
   overlay layer from JSON coordinates.
8. **Straits narrower than one tile are carved, not hoped for.** A locked
   override list forces water along named sea passages (Gibraltar,
   Bosphorus, …); every harbor is guaranteed water within a snap radius.
9. **Economy rescale, not redesign.** Speeds double (tiles/day) so
   historical daily distances (80–120 nm/day) hold on 10 nm tiles; the
   per-day ledger, storm odds methodology, and all port-screen economics
   are untouched.
10. **Google Maps is excluded.** Its ToS forbids derivative game assets.
    Only public-domain sources are vendored, fully offline.
11. **Monsoons, ocean currents, and seasonal ice are a Phase-5
    month-indexed layer, not Phase 4.** P4 weather stays latitude-band
    probabilities; a `20-*` §4.13 placeholder (task B) records the future
    layer and its public-domain data sources (Phase-5 candidates below);
    no P4 task pins numbers for it (§11 rule).

## Pre-state (2026-10-30)

All legacy map artifacts are still tracked and the validator is green:
`data/maps/p3_world.txt`,
`data/maps/p1_mediterranean.txt`, `data/map_legend_p3.json`,
`data/ports_p3.json` all exist, and `maps.json` still lists both maps.
**The repo turns validator-red (group 6) when task E retires the legacy
entries, and stays red until task F lands the generated world. Group 6
must not be "fixed" by re-authoring ASCII, and nothing is deleted before
its owning task — deletions are task-owned (E: the p3 artifacts; L: p1),
because a red tree before W1 breaks wave gating.** All 30
Phase-1–3 test suites (4,545 checks) still pass
(they are map-content independent except `test_discovery`/`test_world_map`/
`test_demo_loop`, which exercise the old maps and get reworked in F/G/J).

---

## Locked constants

The interface pin for every wave. Tasks A/B copy these into the owning
docs verbatim; later tasks implement to this table. Two tasks must never
derive one of these differently (the Phase-2/3 lesson).

| Constant | Value | Owning doc (amended by) |
|---|---|---|
| Grid | 2160 × 1080 tiles | `10-*` §6.1 (A) |
| Tiles per degree | 6; 1 tile = 10′ lat = 10 nm | `10-*` §6.1 (A) |
| Addressing | `lon = x/6 − 180`, `lat = 90 − y/6`; origin top-left, x east, y south | `10-*` §6.1 (A) |
| Longitude wrap | on; `x` taken mod 2160 everywhere (movement, BFS, camera, click) | `20-*` §4.1 (B) |
| Latitude edges | impassable (ice band, below) | `20-*` §4.1 (B) |
| `TILE_SIZE_PX` | 32 (unchanged) | `10-*` §6.1 (A) |
| Tile charset | `~ . # ^ I`; `I` = polar ice, impassable, not reef, not land for adjacency purposes except edge-blocking | `10-*` §6.2 (A) |
| Ice rule | a tile is `I` iff lat ≥ 70°N or lat ≤ 60°S (keeps Cape Horn 55.98°S, North Cape 71.2°N is iced: no NE/NW passage) | `10-*` §6.2 (A) |
| Coastal band | `.` iff within 3 tiles (Chebyshev, wrap-aware) of a passable-adjacent land/ice tile, else `~`; `.` is cosmetic only (same passability/speed as `~`) | `10-*` §6.1 (A) |
| Harbor snap | harbor tile within 2 tiles (Chebyshev) of `Port.lat/lon`, on water, with ≥ 1 orthogonally adjacent water tile | `10-*` §7.1 (A) |
| Port sighting | 24 tiles (≈ 4° ≈ 240 nm — same angular generosity as the old radius 8 on p1) | `20-*` §4.11 (B) |
| Discovery sighting | 18 tiles (≈ 3°; old p3 radius 3 at 1.5°/tile) | `70-*` §4.4 (B) |
| Ship speeds | ×2: base speeds become {8, 10, 12} tiles/day = 80–120 nm/day; floor 1 tile/day unchanged; fleet = slowest hull, unchanged | `40-*` §4.2 (B), `data/ship_types.json` (I) |
| Weather zones | 5 latitude bands (table below) replace "Atlantic strip x ≤ 6/8" | `20-*` §4.7 (B) |
| Map artifact | `data/maps/world.png` — indexed-color PNG, 2160×1080, 1 px = 1 tile, palette index 0–4 = `~ . # ^ I` | `10-*` §6.3 new (A) |
| Palette policy | append-only: indices 0–4 = `~ . # ^ I` are locked; indices ≥ 5 are reserved for future cosmetic/seasonal layers and never carry simulation semantics | `10-*` §6.3 new (A) |
| Lakes | `ne_10m_lakes` polygons rasterized as `#` (land for all purposes; the Caspian is land) | `10-*` §6.1 (A), built by C |
| Map index | `maps.json` exactly one entry, `id: "world"` | `90-*` §9.1 (B) |
| Save | version 4; `MIGRATIONS[3]` defined by task K | `90-*` §8.1–8.2 (B) |
| Port schema | `lat`, `lon` (WGS84 degrees, truth); `marker`, `position`, `p3`, `phase` keys removed; ports.json holds all 100 ports | `10-*` §4.5, §7.1 (A) |

**Weather bands** (columns per existing `20-*` §4.7 schema order:
clear / overcast / windy / storm; band = |lat|, symmetric N/S; the last
boreal band is north-only since south of 60°S is ice):

| Band | clear | overcast | windy | storm |
|---|---|---|---|---|
| Doldrums: \|lat\| < 8° | 0.30 | 0.45 | 0.15 | 0.10 |
| Trade winds: 8–30° | 0.15 | 0.30 | 0.20 | 0.35 |
| Variables: 30–40° | 0.30 | 0.40 | 0.20 | 0.10 |
| Westerlies: 40–60° | 0.10 | 0.30 | 0.35 | 0.25 |
| Boreal: 60–70°N | 0.15 | 0.35 | 0.30 | 0.20 |

Storm-reachability acceptance per band uses the T8 methodology (10,000
seeded rolls, ±0.02 per category). The old demo-loop "sail west from
Lisbon into the storm strip" step is re-anchored: **Lisbon → Santa Cruz de
Tenerife** crosses into the trade-wind belt; scripted gate "storm within 6
days in-band ≥ 0.90" (`1 − 0.65⁶ = 0.9245`).

---

## Tasks

### A — Amend `10-DATA-SCHEMA.md` + AGENTS.md (doc-first)

- **Goal:** the data contract for the real-Earth world, on paper.
- **Docs:** this doc's [locked constants](#locked-constants); current `10-*`
  §§3–8.
- **Changes:** §3 glossary `tilePos` bounds (2160×1080, wrap note); §4.5
  Port schema → `lat`/`lon` truth, marker/position/p3/phase removed; §6.1
  constants table (grid, tiles/degree, addressing, wrap, coastal band, snap,
  lake rule, map artifact pointer); §6.2 tile charset + `I` semantics + ice
  rule; §6.3 (new) PNG artifact spec: indexed PNG, palette indices 0–4,
  append-only palette policy (indices ≥ 5 reserved for cosmetic/seasonal
  layers, never simulation semantics), how the
  loader must read it (`FileAccess` + `Image.load_png_from_buffer` — it is
  data, not an imported texture; the placeholder-art rule is unaffected);
  §7.1 replaced by the 100-port lat/lon table (transcribe from
  `ports.json` + `ports_p3.json`, ids and trade data unchanged); §8 group 6
  rewritten to task F's spec. AGENTS.md: world-map hard rule reworded
  ("generated, tool-owned raster artifact `data/maps/world.png`; ASCII is a
  debug export; never hand-edit").
- **Done-when:** grep over `docs/10-*` finds no `128`, `160 × 96`, `p1`,
  `p3`, `0.42°`, `1.5°`, `marker`, `MARKER_RE` remnants; every locked
  constant appears exactly once; the §7.1 table has exactly 100 rows with
  plausible lat/lon (sanity: Lisbon 38.7°N 9.1°W, Nagasaki 32.7°N 129.9°E);
  AGENTS.md no longer promises ASCII maps.

### B — Amend `00-*`, `20-*`, `40-*`, `60-*`, `70-*`, `80-*`, `90-*` (doc-first)

- **Goal:** every consuming system doc re-anchored to the single world map.
- **Docs:** locked constants; current system docs.
- **Changes:** `00-*` §5 phase table (Phase 4 row; Phase-1 gate reworded to
  the world map), §7 demo loop re-anchored (start Lisbon; step 5 =
  Lisbon→Tenerife per the table above); `20-*` §4.1 grid/wrap/addressing,
  §4.2 movement adds hold-to-repeat + click-to-sail (task H spec),
  §4.4 speed scale note, §4.7 the 5-band table replacing the strip table
  (keep the seeded-roll acceptance style), §4.11 sighting 24,
  §4.12 minimap crop + Chart screen pointer to `80-*`, §4.13 (new
  placeholder) "seasonal wind & ocean currents": monsoon reversal,
  current drift, and seasonal ice are a Phase-5 month-indexed layer
  (decision 11); Phase 4 pins no numbers for them (§11 rule) — the
  placeholder cites the data sources in the Phase-5 candidates section;
  §5 constants;
  `40-*` §4.2 speed values/units note; `60-*` scale references swept;
  `70-*` §4.4 discovery sighting 18 + positions = lat/lon, §4.8 rewritten
  (world map is the only map; Phase-3 content scope folds in), §4.9.8
  marker-charset pin deleted; `80-*` §4.3 input (hold-to-repeat cadence,
  click-to-sail, chart key `Tab`), §4.5 camera (wrap at dateline: no clamp,
  no void), §4.6 minimap re-spec + new Chart screen wireframe (own S-number),
  §4.8 ice palette hex added; `90-*` §7 world fields (map_id stays, value
  `"world"`), §8.1 payload (unchanged fields; version 4), §8.2
  `MIGRATIONS[3]` contract (task K), §9 chunked map loader re-spec (task G):
  PNG → bytes, 128×128 chunk TileMaps, live-chunk bound, wrap-aware
  passability, port overlay from JSON.
- **Done-when:** cross-doc grep for `x ≤ 6`, `x ≤ 8`, `radius 8`,
  `128`, `160`, `p1`, `p3`, `2160` inconsistencies returns only
  historical/phase-record mentions; `00-*` §7's nine steps are all
  satisfiable on the new map (each step names real ports that exist in
  §7.1); `90-*` §9 and `20-*` §4.2 agree on corner-cut and wrap rules.

### C — Coastline vendor + `tools/build_world.py`

- **Goal:** deterministic, offline, parameterized world generation.
- **Docs:** `10-*` §6 as amended (A); locked constants.
- **Creates:** `tools/assets/` with Natural Earth 10 m land + minor islands
  (+ `ne_10m_lakes`) shapefiles and a `LICENSE-NOTES.md` (public domain,
  source URLs, download date); `tools/build_world.py`:
  `--degrees-per-tile` (default 1/6), `--ascii` debug export (2160-wide
  text, `--rows A:B` slicing), `--report` JSON. Raster passes in order:
  land polygon fill → `~`/`#`; lakes pass → `ne_10m_lakes` also `#`
  (locked: the Caspian is land);
  ice rule pass → `I`; coastal band pass → `.`; writes
  `data/maps/world.png` (palette per §6.3) + `data/maps/world_report.json`
  (sea fraction, component sizes > 2000 tiles, ice extent, build params).
  Pure-stdlib or numpy/matplotlib only (offline tool; runtime Godot code
  stays dependency-free).
- **Done-when:** rerunning twice is byte-identical; report sanity: land
  fraction 25–35 %, one dominant sea component > 1 M tiles; spot-checks in
  a viewer: Iberia, Italy, Greece recognizable; Britain an island; Iceland
  land (63–66°N, below ice line); Caspian interior reads `#` (lake pass
  applied); no `^` required this phase (reef layer
  explicitly out of scope; `^` count may be 0); `--ascii` slice of the
  Mediterranean readable; build completes < 60 s.

### D — Waterway overrides + harbor snap

- **Goal:** real coastlines that a tile fleet can actually sail.
- **Docs:** locked constants (override list, snap rule); `10-*` §6.3/§7.1
  as amended.
- **Creates:** `tools/map_overrides.json` — entries `{name, path:
  [[lat, lon]…], min_width_tiles}`; locked must-list: Gibraltar, Bosphorus,
  Dardanelles, Kerch, Messina, Øresund, Great Belt, Bab-el-Mandeb, Malacca,
  Sunda, Magellan; builder post-pass carves water along each path to
  `min_width_tiles` (default 1) and logs cells changed. **Tidal-river
  clause (pinned):** if a port's snap fails because its real-world
  location sits up a river narrower than a tile (expected candidates:
  hamburg/Elbe, london/Thames), the fix is applied in this order —
  (1) move the port's `lat`/`lon` to its estuary mouth in `ports.json`
  and the §7.1 table (coordinates are task-owned data; flavor text
  unchanged), (2) only if the mouth itself is not water, add a
  "tidal river" carve entry to `map_overrides.json`. The builder names
  the failing port either way. Harbor snap pass:
  each §7.1 port → nearest water tile within 2 tiles, writes
  `harbor_tile {x, y}` into `world_report.json` (runtime reads ports.json
  lat/lon and re-derives deterministically with the same rule — one
  implementation shared via spec, tested equal in F).
- **Done-when:** final PNG has a ≥ min-width water path on every listed
  waterway (asserted by the builder, not eyeballed); all 100 ports snap ≤ 2
  tiles with an orthogonally adjacent water tile; builder fails loudly
  (non-zero exit, named port/strait) if any snap or carve is impossible;
  report lists every override cell-count (expect < 0.5 % of tiles); any
  §7.1/`ports.json` coordinate amendment made under the tidal-river
  clause goes through E's owner (W3 pin).

### E — Port + discovery data migration

- **Goal:** one port file, geographic truth, no dual-map keys.
- **Docs:** `10-*` §4.5/§7.1 as amended (A).
- **Changes:** merge `ports.json` (30) + `ports_p3.json` (70) → single
  `ports.json` (100) with `lat`/`lon` added and `marker`/`position`/`p3`/
  `phase` removed; ids, nations, goods, facilities, flavor text unchanged.
  `data/discoveries.json`: 30 positions → `lat`/`lon` (placements
  **task-owned** but must match each discovery's zh/en hint text; open
  ocean or coastal waters only). Delete `ports_p3.json`,
  `data/map_legend_p3.json`, and `data/maps/p3_world.txt` — its
  `maps.json` entry dies with the single-`world` rewrite, and nothing is
  deleted by hand before this task (see Pre-state).
  `data/map_legend.json` → grid 2160×1080, tiles + `I`;
  `maps.json` → single `world` entry.
- **Done-when:** validator groups 1–5 exit 0 on the new schema (group 2–5
  checks extended to 100 ports); negative test: port in the Caspian
  (lat 42, lon 50) fails group 6 precursor with a named error; grep
  `data/` finds no `marker`/`p3` keys and no `p3` filename;
  `data/maps/` holds no `.txt` files; port count in validator summary =
  100.

### F — Validator group 6 rewrite (world.png)

- **Goal:** machine-checked world integrity, replacing marker-agreement.
- **Docs:** `10-*` §8 as amended (A); `20-*` §4.2 movement rules.
- **Changes:** group 6 checks: artifact exists, is indexed PNG, size
  2160×1080, palette ⊆ locked indices; harbor-tile rule per port (snap ≤ 2,
  water, adjacent water — recomputed independently of D and compared);
  BFS from Lisbon's harbor over **all** passable tiles (8-dir, corner-cut
  forbidden, **wrap-aware**, `~ . ^`-adjacent semantics per legend) reaches
  all 100 harbor tiles and all 30 discovery tiles; probe ports asserted
  reachable: istanbul (Bosphorus), copenhagen (Øresund/Great Belt), aden
  (Bab-el-Mandeb), nagasaki (Malacca/Sunda), venice, london, hamburg
  (Elbe, per D's tidal-river clause); with the lake
  pass no disconnected sea is expected, but the informational listing
  stays (any > 2000-tile component is named).
- **Done-when:** exit 0 on the C+D+E world; seeded negatives each fail with
  a named message: (1) delete the Gibraltar override from map_overrides.json
  → BFS unreachable named "ceuta or gibraltar-flank port"; (2) move one port
  3 tiles inland → snap failure; (3) corrupt PNG size → artifact failure;
  runtime under 30 s (pure Python, stdlib + PIL-free: use the tool's own
  PNG reader via zlib or the Godot-independent decoder in build_world.py).

### G — MapLoader rework: PNG → chunked TileMap

- **Goal:** the world renders and queries fast at 2.3 M tiles.
- **Docs:** `90-*` §9 as amended (B); `80-*` §4.5/§4.8; locked constants.
- **Changes:** `scripts/world/map_loader.gd`: load PNG via
  `FileAccess` + `Image.load_png_from_buffer` (works in exports; no import
  pipeline); passability via byte lookup on the decoded `Image` (wrap-aware
  `is_passable(x, y)`); rendering = 128×128-tile chunk TileMaps generated
  on demand around the camera (in-memory atlas per §9, palette colors),
  ≤ 24 live chunks, freed beyond margin; port overlay layer from
  ports.json (nation-colored square + label at harbor tiles, wrap-duplicated
  at the seam); camera centered on fleet, x wraps.
- **Done-when:** scene load to first frame < 3 s; pan the camera across the
  dateline with zero void frames; memory of live chunks < 50 MB (debug
  assert); `is_passable` correct at (0, y), (2159, y) and across the wrap
  for all 5 kinds; swapping `world.png` for a test PNG needs zero code
  edits; all 100 port overlays render with correct nation colors.

### H — Movement & input: hold-to-repeat + click-to-sail

- **Goal:** 10 nm steps must not take 10 nm of patience.
- **Docs:** `20-*` §4.2 as amended (B); `80-*` §4.3 as amended (B).
- **Changes:** held direction key steps at ~8 tiles/s after a 0.25 s delay
  (per-step clock/economy rules unchanged — N held-steps = N moves);
  click on any visible water tile → `AStarGrid2D` path (region 2160×1080,
  `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` = no corner cutting, jumping on),
  fleet walks it step-by-step through the normal per-step rules; wrap: if
  |Δx| > 1080, query the shifted target and normalize the path; path
  cancels on: land reached (never happens), manual input, battle
  interruption (re-computes remaining path after dismissal).
- **Done-when:** scripted: 2000-tile path computed < 1 s; held-key 20 steps
  produce 20 clock-advancing moves with correct provisions math
  (`test_movement` extended); corner-cut injection along an auto-path is
  impossible (A* mode test + manual diagonal spam); dateline click (fleet
  x=2100, click x=50) sails westward through the seam; battle mid-path
  resumes to the original target.

### I — Latitude weather + speed rescale

- **Goal:** the simulation believes in the Earth.
- **Docs:** `20-*` §4.4/§4.7 as amended (B); `40-*` §4.2; locked constants.
- **Changes:** `sailing_sim.gd` zone function = f(|lat|) per the 5-band
  table (band edges exactly as locked; fleet lat from `MapLoader` y→lat);
  Atlantic-strip code deleted; `ship_types.json` speeds 4→8, 5→10, 6→12;
  sighting radii constants (24 port / 18 discovery) in one constants
  location per `20-*` §5; wind-factor pipeline untouched.
- **Done-when:** seeded 10,000-roll checks per band match every category
  within ±0.02 (T8 harness generalized); a Lisbon (38.7°N) roll sample is
  'variables', a Tenerife (28°N) sample 'trade winds'; speed table sums and
  per-hull values match §7 unit tests updated ×2; suite `test_weather`
  green with the new bands; grep finds no `x <= 6`/`x <= 8` zone code.

### J — HUD minimap crop + full-screen Chart

- **Goal:** orientation at 233 万 tiles: near window + whole-world chart.
- **Docs:** `80-*` §4.1/§4.6 as amended (B); `20-*` §4.12.
- **Changes:** HUD minimap keeps its 256×192 box, becomes a wrap-aware
  128×96-tile crop around the fleet at 2 px/tile from the explored bitset
  (`PackedByteArray`, 291,600 bytes, set by the sighting pass); new
  `chart_screen.tscn` (S-number from `80-*`): whole world 2160×1080
  downscaled to fit, explored overlay + known ports (nation dots + names at
  zoom) + fleet marker + discovery hint icons; `Tab` toggles, `Esc` closes;
  zh/en labels via ui_strings (orchestrator-merged keys).
- **Done-when:** minimap crop is correct at the dateline (fleet x=2159
  shows x∈[2032..2159]∪[0..k]); chart renders in < 0.5 s open time;
  explored tiles appear identically on minimap and chart; Tab/Esc round-trip
  from world scene; suite `test_discovery` extended: reveal at 24 tiles,
  discovery reveal at 18, both visible on chart; ui_strings zero `<key>`
  fallbacks in both locales.

### K — Save v4: reposition + map_id

- **Goal:** old saves sail again, at the same port, on the new Earth.
- **Docs:** `90-*` §8 as amended (B).
- **Changes:** `SAVE_VERSION := 4`; `MIGRATIONS[3]`: `world.map_id` →
  `"world"`; `world.position` → harbor tile of the save's current port
  (saves are port-only by design — F5 at sea is refused); `clock_fraction`
  → 0; `known_ports` untouched (ids survived E). `DEFAULT_MAP_ID` = "world".
  v1→v2→v3→v4 chain preserved and tested (a real Phase-1 save fixture
  migrates end-to-end).
- **Done-when:** `test_save_v2` → `test_save_v4` green: fixtures for v1/v2/
  v3 saves all load, re-save as v4, round-trip byte-equal; migrated save
  puts the fleet exactly on its port's harbor tile (spot-check 3 ports);
  corrupt / future-version saves still refuse gracefully.

### L — Retire the old maps

- **Goal:** no dual-map code paths survive.
- **Docs:** `90-*` §7/§9 as amended (B).
- **Changes:** delete `data/maps/p1_mediterranean.txt`; remove map-index
  switching, legend-per-map resolution, and minimap rescale-on-map-change
  code; `map_legend_p3.json` deletion (E) confirmed swept in code; docs
  cross-references in code comments updated.
- **Done-when:** grep `scripts/` + `scenes/` + `autoload/` for
  `p1`, `p3`, `mediterranean`, `map_legend_p3` returns only
  migration/test fixtures; validator + all suites green; headless boot
  clean.

### M — Circumnavigation & chokepoint E2E

- **Goal:** proof the Earth works: wrap, straits, bands.
- **Docs:** `20-*` §4 as amended; locked constants.
- **Creates:** `tools/test_world_e2e.tscn`: scripted voyages — (1) Lisbon →
  Tenerife crossing into the trade belt; (2) Lisbon → Istanbul through the
  carved Dardanelles+Bosphorus; (3) Lisbon → Nagasaki via Cape of Good Hope
  + Malacca (the long way, asserts the Indian Ocean path); (4) westward
  circumnavigation from Lisbon through the dateline back to Lisbon
  (teleport-assisted between legs; asserts wrap, not stamina); each leg
  asserts arrival tile, day count within a generous envelope, and no
  game-over.
- **Done-when:** all four legs pass in headless; dateline leg crosses x=0
  and x=2159 boundaries; leg 2 proves the Bosphorus override in play, not
  around it; suite count and check count recorded.

### N — Phase-4 acceptance

- **Goal:** the phase definition of done.
- **Docs:** `00-*` §7 as amended (B); everything above.
- **Creates:** `tools/demo_check_phase4.md` — dated manual run of the
  re-anchored 9-step demo loop on the world map, zh and en.
- **Done-when (all nine amended steps, verifying exactly):** title/nation/
  market/save-load steps unchanged from Phase 1 but exercised on the world
  map; sea step uses hold-to-repeat and click-to-sail; storm step = Tenerife
  leg with the ≥ 0.90/6-day band gate; chart step (new) opens/closes and
  shows explored state; zh pass with zero `<key>` fallbacks;
  `python3 tools/validate_data.py` exit 0; all suites green with counts
  recorded in this file's completion record.

---

## Task dependency note

A, B unblock everything (they are pure docs; nothing launches before W1
merges). C needs A's §6.3 format. D needs C; E needs A's §7.1. F needs
D + E. G needs C (artifact) and F (green world) — it loads the real thing,
not a fixture. I is independent of C–G (engine + data constants) and needs
only B. H needs G's passability API. J needs G's explored/passability
queries. K needs E (port schema) and G's harbor-tile derivation. L needs
G + K. M needs H + I + K. N needs all.

## Shared-file pins (hard rule: one writer per file per wave)

- **W3:** E owns `ports.json`, the legend/map data files, and the §7.1
  transcription; if D's builder trips the tidal-river clause, the
  coordinate amendment goes through E's owner (one writer).
- **W4:** F owns `tools/validate_data.py`; I owns `sailing_sim.gd` +
  `ship_types.json`. Disjoint.
- **W6:** H owns `world_map.gd` input section + new
  `scripts/world/sail_path.gd`; J owns `hud.tscn`, `chart_screen.tscn`,
  discovery bookkeeping. Both touch `world_map.tscn` wiring — the wave
  master applies J's scene wiring after H merges.
- **ui_strings.json** remains orchestrator-owned: J (and any task adding
  keys) lists zh/en keys in its report; master merges after the wave.

## Subagent execution plan (max 4 background subagents, one worktree each)

Same protocol as Phase 3: master owns the base branch, creates/removes
worktrees, merges every branch, runs the validator between waves, and pins
**task-owned** numbers in the owning doc before launch (Phase-2/3 lesson).

| Wave | Tasks (parallel) | Gate (after) |
|---|---|---|
| W1 | A, B | — |
| W2 | C | W1 |
| W3 | D, E | W2 |
| W4 | F, I | W3 |
| W5 | G | W4 |
| W6 | H, J | W5 |
| W7 | K | W6 |
| W8 | L, M | W7 |
| W9 | N | W8 |

- W5 is single by dependency: the chunked loader is on every later path.
- W8 pairs L (deletions, grep-clean) with M (new E2E suite only) — disjoint
  files; M needs K's save v4 only to persist between legs.
- N is orchestrator-led (dated manual run), as in every phase.

## Phase-5 candidates (spec'd in Phase 5 — owners amend `20-*` first)

Out of Phase-4 scope by decision 11 (§11 rule); when a Phase-5 backlog
is written, its owners amend the owning system docs first:

- **Monsoon (seasonal wind):** month-indexed prevailing wind direction
  per sea region feeding `wind_factor` (`20-*` §4.4) as a season/
  direction input — additive to the pipeline, not a rewrite. Data:
  hand-authored region × month table in `data/` (UW2-style, tunable) or
  NCEP/NCAR Reanalysis-2 monthly mean 10 m winds (public domain) sampled
  by a builder pass.
- **Ocean currents:** tile-domain drift layer, ideally a second indexed
  PNG (`data/maps/currents.png`, 1 px = 1 tile) built like `world.png`
  from the NOAA Global Drifter Program climatological monthly mean
  currents (1° grid, public domain); NOAA OSCAR is the heavier
  alternative. Effect: with/against speed modifier or daily drift.
- **Seasonal sea ice:** month-indexed passability overlay (Baltic,
  Hudson Bay) sharing the monsoon/current month-indexed mechanism; the
  P4 `I` band stays the permanent polar edge.
- **Cosmetic terrain layer:** a second indexed PNG (land biomes/relief;
  rivers via `ne_10m_rivers_lake_centerlines`, added to the vendor pass
  when this lands) consumed only by the tile renderer — never
  simulation semantics; palette indices ≥ 5 per the append-only policy.
- **Quest hooks:** monsoon-timed trade voyages (e.g. run the SW monsoon
  to India) slot into `70-*` mission/quest content.

## Risks & pinned mitigations

| Risk | Mitigation (pinned here, verified in done-when) |
|---|---|
| Pure-Python rasterizer too slow at 2.3 M tiles | numpy/matplotlib allowed in the tool only; scanline fill; 60 s cap (C) |
| Straits narrower than a tile seal seas | locked override list + builder-asserted carve + probe-port BFS (D, F) |
| Harbor lands on a river/land cell at coarse resolution | snap ≤ 2 + adjacency + loud failure (D, F) |
| GDScript A* too slow for 2000-tile paths | engine `AStarGrid2D` (C++, jumping) pinned (H) |
| float32 jitter at 69,120 px world coords | camera-centered rendering, chunk culling; jitter checked at max coordinate (G) |
| Caspian/lakes trap the BFS or validator | lake pass rasterizes `ne_10m_lakes` as `#` (Caspian is land); F still lists any > 2000-tile disconnected component informationally (C, F) |
| River ports snap-fail at 10 nm tiles (hamburg/Elbe, london/Thames) | pinned tidal-river clause in D (move `lat`/`lon` to the estuary mouth first, carve second); hamburg added to F's probe ports (D, F) |
| Explored-state still unsaved (Phase-1 known limitation) | unchanged, documented; chart and minimap share the session bitset (J) |
| Old saves point at vanished p1 coordinates | MIGRATIONS[3] repositions by current port id — saves are port-only by design (K) |
| Someone hand-edits world.png | AGENTS.md hard rule reworded + builder determinism check (A, C) |
