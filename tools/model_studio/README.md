# SailAge Model Studio

Local web UI so the user can re-roll model-generated art themselves:
edit a job's prompt, re-roll it against the generation backend, inspect
the result, and accept it into the game build.

- **Server**: `server.py` — stdlib only (`http.server.ThreadingHTTPServer`),
  binds `127.0.0.1:8010`, no auth (local tool). One background worker thread
  runs generation jobs strictly one at a time from a FIFO queue.
- **Chain**: `chain.py` — the pixellab family layer. All four art
  families (ships, wakes, icons, glyphs) plus the coast tileset drive
  the build-time pixellab tools in-process (see the family sections
  below). The legacy TheNoise/ComfyUI icon chain and its driver parse
  (`tools/model_pass.py`, deleted) are REMOVED — 2026-11-08 user
  direction.
- **Frontend**: `www/` — single-page vanilla HTML/CSS/JS, dark theme.

## Launch

```sh
python3 tools/model_studio/server.py --port 8010 --repo /home/weidong/repo/SailAge
```

Then open <http://127.0.0.1:8010>.

`--repo` points at the **MAIN** repo: `model_raw/drafts/`, `progress.json`,
`report.json` and `tools/validate_data.py` are read from there (read-only),
and the studio cache is written to `<repo>/tools/ui_art/model_raw/studio/`
(gitignored). The canonical `gen/` and `snapped/` stores are never written.

## Coast tileset family (pixellab — the §4.8 terrain path, 2026-11-06)

ONE card per tileset (`coast`): the vendored 16-tile wang corner set the
world's coastlines render from (`tools/build_terrain_pixellab.py` +
`pixellab_coast_ledger.json` — the placement rule is the §4.8
water-flanking rule). The card shows the shipped 16-tile strip (draft),
the pending re-roll strip (raw), and the **wang mock preview** — a live
12×4-cell crop of the built world (Bay of Biscay) rendered 1:1 with the
tiles through the flanking rule (snapped). Re-roll = one
`/create-tileset` pro-mode call via `tools/pixellab_pass.py
run_coast_tileset` in-process (defaults from the vendored request
wording; the prompt box is a free-text **style clause appended to all
three descriptions**; seed = the tileset seed). The result stays in the
studio cache (gitignored) until **Accept + rebuild**: the vendored trio
(`tileset_coastline_<id>{,_request,_submit}.json`) is staged into
`tools/assets/pixellab_raw/`, `build_terrain_pixellab.py`'s pinned
`SOURCE_JSON` is repointed, and the builder regenerates the game tokens
+ ledger (byte-identical rebuild rules apply; git add/commit stays with
the user). No depth tileset (retired — pro corner-API crash history),
no per-tile cards; the legacy `terrain_*` texture jobs are HIDDEN entirely (2026-11-06 user direction — terrain re-rolls live on the coast tileset card; the retired texture chain is not re-rollable or visible).

## Chrome tilesets family (pixellab — the §4.8 2026-11-08 path)

TWO cards, one per family (`chrome_frame` = the parchment panel plate,
`chrome_click` = the light parchment click plate — the 2026-11-08
evening revision re-sourced the button families here and RETIRED the
chestnut leather set; the pinned
descriptions/seeds live in `tools/pixellab_pass.py CHROME_TILESETS` /
80-* §4.8, seeds 20261108 / 20261110). ONE `/v2/create-tileset` pro
tileset per re-roll via `run_chrome_tileset` **in-process**; defaults are
read from the vendored canonical trio (tileset id + seed from the
`_submit.json`, the three descriptions from the `_request.json`;
fallback = the pinned spec when the trio is missing). The prompt box
edits ONLY the free-text **style clause appended to all three
descriptions** (the coast convention — descriptions are pinned, never
edited); seed user-settable (blank → the pinned default seed). Re-rolls
STAGE the fresh vendored trio into the studio cache
(`model_raw/studio/chrome/` — the coast pattern: a discarded or failed
re-roll never leaves a second trio in the canonical raw dir). The card
shows the shipped vendored strip (draft), the pending re-roll strip
(raw), and the **nine-patch mock preview** (snapped): the 16
keyed-unaware wang tiles green-keyed and assembled through the §4.8
mapping (upper = material; TL = wang_1, T = wang_3, fill = wang_15, the
other cells dihedral mirrors/rotations — exactly `build_ui_art`'s
`FRAME_OPS` relations) into the 48×48 sheet, rendered as the sheet
itself plus a 160×64 panel rect (corners + tiled edges/fill) — the
click family adds a 96×28 button rect — on the muted review backdrop,
NEAREST-upscaled 3×. **Accept + rebuild**: the staged trio is copied
into `tools/assets/pixellab_raw/` under its canonical
`tileset_chrome_<family>_<id>{,_request,_submit}.json` names, the
previous canonical trio for the family is deleted (the ingest requires
exactly ONE `tileset_chrome_<family>_*.json` — `_chrome_find_tileset`),
and `build_ui_art --import-chrome-pixellab` re-lands the 18 derived
singles (panel/field from frame; button/hover/pressed/focus from
click) + the `chrome{}` ledger. The gate is the fresh `chrome{}`
section of `tools/ui_art/ingest_ledger.json` listing the new tileset id
for the family. Git add/commit stays with the user.

## Ship family (top-down north tokens — the §4.8 2026-11-07 path)

One card per fleet ship, keyed by label (`td_<label>`; the 16 accepted
fleet labels — labels without a snapped north token are hidden).
Generation = `tools/pixellab_pass.py run_topdown` **in-process**: ONE
straight-overhead (directly from above) north token per ship, canvas =
tier size (32/48/64), `create-object-pro-flash`, no style image —
description is FREE TEXT (the prompt box; the default seeds once from
the tool's `_desc_topdown` + pinned overhead style suffix), the seed is
user-settable (blank → random). After the ~20–60 s render the raw north
token lands in `model_raw/pixellab_topdown/<label>/` (gitignored) and
**snap is a byte-identical passthrough** into `snapped/north.png`. The
card previews the 8 runtime rotations (PIL NEAREST — the same
resampling family the game pins; the game rotates the token, so only
the north family ever exists). Accept passes the pixellab_topdown raw
store straight to `build_ui_art --import-ships-north <raw_root>` (its
`<ship>/snapped/north.png` + manifest layout is exactly what the
ingestion walks — a fleet-completeness pre-check refuses the accept if
any ship's snapped token is missing, since a gap would silently fall
back to the generated token); the gate is the ship's
`hull_<ship>` ledger token with `pennant: "raw"`. Cost ≈ $0.008/roll.

## Wake VFX family (pixellab v6 — the §4.8 2026-11-08 per-ship path)

16 cards, one per SHIP TYPE (`fx_<ship>`; the committed table
`assets/ui/fx/fx_waterline.json` keys the same 16
`data/ship_types.json` ids). The wake is ONE sheet per ship rendered
UNDER the hull — each sheet is authored around that ship's own hull
silhouette; ships rotate at runtime, so the sheet rotates with them and
only the north family exists. Generation =
`tools/pixellab_vfx_pass.py run_ship` **in-process**
(POST `/v2/vfx`, pro artist, `game_pack: true`, the ship's OWN north
token as the sprite input) — description is FREE TEXT (default = the
pinned `V5_DESCRIPTION` of record, verbatim in 80-* §4.8; the envelope
has NO seed — the card shows the quote, ≈10 generations ≈ per roll,
instead). A re-roll stages into the studio cache
(`model_raw/studio/fx/<ship>/` + a staging `pixellab_vfx.json`
manifest — the coast pattern: a discarded or failed re-roll never
pollutes the canonical raw store). The card shows the staged pack's
frame-0 composite (wake under the ship's north token on the review sea
blue) next to the SHIPPED composite built from `assets/ui/fx/` —
old vs new side by side; with a staged re-roll the API's animated gif
preview is served too. Accept copies the staged ship dir + its manifest
record into `model_raw/pixellab_vfx/v6/` and runs
`build_ui_art --import-fx-pixellab` (all 16 ships re-land,
idempotent — the other wake cards stamp in-game too); the gate is
the ship's record (sheet sha256 + effect_id) in
`tools/assets/pixellab_raw/pixellab_vfx_ledger.json`.

The retired per-SIZE wake family (`fx_32/48/64`, the v5 single-layer
path) is REMOVED (2026-11-08 user direction — the per-ship revision
replaced it): its cards, persisted state entries and stage dirs are
gone; the registry enumerates only `chain.FX_SHIPS`.

The §4.8 2026-11-06 oblique ship family (`px_<label>`, 8 native
rotations) and the pre-PixelLab legacy ship jobs (`hull_*` per-dir,
`sheet_*` 5-cell sheets) are REMOVED entirely (2026-11-07 user
direction — the top-down amendment replaced that art): not listed, not
re-rollable, and their chain machinery is gone from `chain.py`. The
icon/icon-sheet families and the (hidden) terrain machinery are
untouched.

## Icon family (pixellab prompt-only — the §4.8 2026-11-08 hero rule)

117 cards, ONE per id (`ic_<id>`; the pinned `_ICON_DESCRIPTORS`
generation list — the six `current_arrow_*` siblings are
derivation-only, derived at ingest from the n/ne bases, and have no
card). Generation = `tools/pixellab_pass.py run_icon` **in-process**:
ONE prompt-only `generate-image-v2` job per id on the pinned 64×64
canvas, the 4-field envelope `{description, image_size, no_background,
seed}` — never a style_image or reference_images. The prompt box is
free text (default = the pinned descriptor + the frozen `ICON_SUFFIX`);
seed user-settable (blank → the pinned 92000). Re-rolls STAGE into the
studio cache (`model_raw/studio/icons/<id>/`, gitignored — the coast/fx
pattern: a discarded or failed re-roll never pollutes the canonical raw
store). The card shows the staged re-roll vs the canonical raw 64 (the
shipped pixels' source). Accept moves the staged dir + manifest record
into `model_raw/pixellab_icons/` and runs `build_ui_art --import-icons
<canonical>` (the whole family re-lands, idempotent); the gate is the
id's `icons{}` ledger record + the shipped hero file
`assets/ui/icons64/<id>.png`. Cost ≈ $0.008/roll.

## Glyph family (pixellab prompt-only — markers + facility tokens)

12 cards (`gl_<id>`): the 6 `marker_*` discovery/treasure/wreck markers
and the 6 `facility_*` port tokens — the same prompt-only envelope
against the frozen `MARKER_SUFFIX` / `FACILITY_SUFFIX` (no icon
heritage). Staging, accept and gates mirror the icon family:
`--import-glyphs <canonical>`; the gate is the `markers{}`/`facility{}`
ledger record + the shipped hero `assets/ui/markers64/<bare>.png` /
`assets/ui/tokens64/<bare>.png` (the hero dirs hold BARE ids — the
registry strips the family prefix).

## API

| Method | Path | Body | Purpose |
|---|---|---|---|
| GET | `/api/jobs` | — | registry + studio state merged, `flagged` id list |
| GET | `/api/status` | — | worker idle/busy, queue, current job + stage |
| POST | `/api/reroll` | `{job, prompt?, seed?}` | persist prompt (if given), queue the job (seed omitted → random; ignored for `fx_*` — the envelope has no seed) |
| POST | `/api/prompt` | `{job, prompt}` | persist a prompt edit without queueing (empty → revert to canonical) |
| POST | `/api/accept` | `{job}` | mark the current result accepted in `accepted.json` |
| GET | `/api/layout/file` | — | the committed `data/ui_layout.json` text + mtime + the last in-session commit-gate verdict (`{content: null}` 404-shape when absent) |
| POST | `/api/layout/commit` | `{layout}` | serialize per 10-\* §4.23, gate behind a full `tools/validate_data.py` pass, write **only on validator exit 0**; answers `{ok: true, bytes}` / `{ok: false, error: <FAIL text>}` — never a 500 |
| GET | `/thumb/<kind>/<job>.png` | — | `draft` / `raw` / `snapped` thumbnail (`raw`/`snapped` prefer the studio reroll, falling back to the canonical store); cache-busting via `?v=<mtime>` |
| GET | `/thumb/td/<label>/<deg>.png` | — | top-down ship rotation preview (PIL NEAREST, pinned degrees) |
| GET | `/thumb/fx/<size>/<kind>` | — | wake previews: `anim.gif` (staged API gif) / `comp.png` (staged wake under the ship) / `shipped.png` (the committed family — in game now) |

## Layout tab (Phase 11 — the visual UI-layout editor, 80-* §4.8.9)

The **Layout** tab swaps the card grid for a live UI-layout editor:
screen list + element tree on the left, the game's real viewport frame
with 32 px-tile boxes on the canvas, the override inspector on the
right, and the commit bar underneath.

- **Launch contract** — the game carries the bridge; the studio never
  launches Godot. Start the game with

  ```sh
  godot --path . -- --layout-bridge
  ```

  then open the Layout tab and hit **Connect** (the endpoint is the
  bridge's `ws://127.0.0.1:8765`; a hint line shows the launch command
  whenever disconnected). Without the flag the game runs no listener.
- **Protocol** — the browser connects DIRECTLY to the game's
  LayoutBridge; `server.py` never proxies WebSocket. The message table
  is frozen verbatim in `docs/90-ARCHITECTURE.md` §5.7: `hello` /
  `screen_changed` / `tree` / `frame` / `error` game→studio,
  `get_tree` `get_frame` `move` `resize` `reorder` `assign_sheet`
  `revert` `reset_screen` `commit` studio→game. Every edit is sent as
  its §5.7 message; the game replies with a fresh `tree` + `frame` and
  the tab re-renders. The wire discriminator rides under **both** `msg`
  and `type` keys so either reader convention works (the frozen table
  names messages, not envelope keys); edit payloads carry the §4.23
  override key names (`x`, `y`, `w`, `h`, `min_w`, `min_h`, `order`,
  `sheet`), and `reorder` carries the absolute sibling index. Anchors
  have no live message (the frozen set has none) — the anchor dropdown
  edits the session only and is applied from the committed file at game
  restart.
- **Session** — the edit session accumulates browser-side as
  `{screen: {element_id: {…overrides}}}`, STARTING from the committed
  `data/ui_layout.json` (fetched on tab open), so edits compose over
  what is already committed. Per-element **Revert** drops that element's
  override (and tells the bridge); **Reset screen** drops the screen's.
- **Single writer** — the game and its bridge never write files. The
  studio writes `data/ui_layout.json` and NOTHING else, and only behind
  the validator gate: Commit POSTs the full table to
  `/api/layout/commit`, the server serializes and runs a FULL
  `tools/validate_data.py` pass (all groups 1–14) against a staged
  `SAILAGE_DATA_ROOT` tree holding the candidate, and writes the real
  file ONLY on validator exit 0. A rejected commit answers
  `{ok: false, error: <FAIL text>}` and leaves the committed file
  byte-unchanged. Git add/commit stays with the user.
- **Serialization rules** (10-* §4.23, deterministic bytes):
  `json.dumps(layout, indent=2, sort_keys=True) + "\n"` — sorted keys,
  2-space indent, trailing newline; `{}` serializes to exactly
  `{}\n`. Tile integers only; the §8.9 group-14 rules (screen ids,
  dotted element ids, key whitelist, grid bounds `x+w ≤ 60`,
  `y+h ≤ 33`, `anchor` ⇒ no `y`) are enforced by the validator gate and
  pre-clamped in the editor.
- **Manual-suite reminder** — the studio cannot run Godot: after a
  layout commit, run the port-screen locale layout suites (`zh` + `en`)
  — the Commit banner under the bar says so too (the §4.8.9 both-locale
  guard: a commit that clips either locale fails the suite).

## UI

- **Top-down ship cards** (`td_<label>`): an 8-rotation strip in compass
  order (n ne e se s sw w nw — the runtime rotation preview of ONE north
  token, PIL NEAREST), free-text prompt box (edit base = the pinned
  `_desc_topdown` + overhead style suffix), seed field, Re-roll /
  Accept, live status incl. the render stage (`posting`,
  `render:…`, `snapping`), and the job_id/seed provenance from the tool
  manifest.

- **Wake VFX cards** (`fx_<ship>`, 16 ships): the staged animated gif →
  the staged frame-0 composite → the shipped composite (what the game
  shows now), free-text prompt box (edit base = the pinned
  `V5_DESCRIPTION` of record), **no seed field** (the envelope has
  none — the card shows the quote instead), Re-roll / Accept, and the
  effect_id provenance.

- Icon/terrain job cards: three thumbnails (draft | raw | snapped),
  editable prompt textarea (persisted per job), seed field
  (blank → random; canonical seed shown as placeholder), Re-roll / Accept
  buttons, live status line (queued / generating Ns… / done / error).
- Family tabs (All / Ships / Wake VFX / Coast / Icons / Flagged / In
  game) and a **Re-roll ALL flagged** button.

## Robustness (hardened after the browser broken-thumb incident)

- **HTTP burst safety**: HTTP/1.1 keep-alive + `request_queue_size = 128`
  (the stdlib TCP default of 5 dropped connections when a browser fired
  ~500 `<img>` requests at once — the intermittently-broken-thumbnails
  mechanism; single curl requests never hit it). `do_HEAD` answers
  headers-only instead of the stdlib 501 HTML page.
- **Never-404 thumbs**: every thumb slot of a listed job degrades to a
  `missing` cell in the UI instead of breaking the grid. Thumbs go
  through a bounded in-memory cache keyed by source path + mtime.
- **Prompts never go empty**: the edit base comes from the pass tools'
  pinned descriptors (`_ICON_DESCRIPTORS` / `_glyph_desc` /
  `_desc_topdown` / the wake V5 wording) or the canonical raw manifest's
  recorded description. `default_prompt` never raises; `registry()`
  guards each job so one bad store file cannot 500 `/api/jobs`.
- **Original prompts (user direction: edit from the actual original)**:
  every generation stores the EXACT prompt in `studio/state.json`
  (`original_prompt` + `original_prompt_source: "exact"`); the card's
  edit base is the canonical manifest's recorded description (the
  wording that produced the shipped art), else the pinned descriptor.
  The textarea pre-fills the original; **↺ original** reverts the box
  (and clears the saved custom edit) byte-identically.

The registry **never raises**: a failing card is skipped with a warning
(reported in `/api/status` → `registry.warnings` and `/api/jobs` →
`warnings`) — the API always answers valid JSON.

## Accept → in game (一键进游戏)

**Accept** flows straight into the game build per family:

1. **Top-down ships** (`td_<label>`): the pixellab_topdown raw store is
   passed straight to `build_ui_art --import-ships-north` (after a
   fleet-completeness pre-check — a missing snapped token would
   silently fall back to the generated art); the gate is the ship's
   `hull_<ship>` token in `ingest_ledger.json` with `pennant: "raw"`.
2. **Wake VFX** (`fx_<ship>`): the staged ship dir + manifest record are
   copied into `model_raw/pixellab_vfx/v6/` and the worker runs
   `build_ui_art --import-fx-pixellab` — all 16 ships re-land
   (idempotent), so the other wake cards stamp in-game too; the gate is
   the ship's record (sheet sha256 + effect_id) in
   `tools/assets/pixellab_raw/pixellab_vfx_ledger.json`.
3. **Icons / glyphs** (`ic_<id>` / `gl_<id>`): a staged re-roll first
   moves into the canonical pixellab raw store, then one
   `build_ui_art --import-icons <pixellab_icons>` /
   `--import-glyphs <pixellab_glyphs>` run re-lands the WHOLE family
   (idempotent — the sibling cards stamp in-game too); the gate is the
   id's ledger record + the shipped hero file (`assets/ui/icons64/`,
   `assets/ui/markers64/`, `assets/ui/tokens64/`).
4. The card status walks **queued for ingest → ingesting… → in game ✓**
   or **REJECTED / error: <reason>**; the result (state, reason, log
   tail) is stored per job in `studio/state.json` (`ingest` key) and
   mirrored into `accepted.json`.
5. Header/filter chip **In game (n)** lists accepted+ingested jobs.
6. Icon/glyph accepts are full accept→in-game flows (no pending state —
   the import is the game build).

Restart note: the token runtime loads data artifacts (no `godot --import`
needed after a token replace) — restart the game to see accepted art.
The studio never shells out to godot itself.

## Notes

- All studio output lives under `model_raw/studio/**` (gitignored);
  the canonical pixellab raw stores are written ONLY on Accept (the
  staging contract). Generation jobs run strictly serially (one worker
  thread), so concurrent re-rolls queue instead of racing.
