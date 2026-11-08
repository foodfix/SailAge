# SailAge Model Studio

Local web UI so the user can re-roll model-generated art themselves:
edit a job's prompt, re-roll it against the generation backend, inspect
the result, and accept it into the game build.

- **Server**: `server.py` — stdlib only (`http.server.ThreadingHTTPServer`),
  binds `127.0.0.1:8010`, no auth (local tool). One background worker thread
  runs generation jobs strictly one at a time from a FIFO queue.
- **Chain**: `chain.py` — the pixellab family layer. **Ships, wakes and
  the icon + glyph families** drive `tools/pixellab_pass.py` /
  `tools/pixellab_vfx_pass.py` in-process (see the family sections
  below); the LEGACY icon/icon-sheet path still re-implements the
  model-pass pipeline (`tools/model_pass.py` parsed read-only for the
  canonical icon prompt wording, never imported) pending its removal
  commit.
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

## Chain (per sprite job — the LEGACY icon path; superseded by the
## icon/glyph families above, kept until the removal commit)

## API

| Method | Path | Body | Purpose |
|---|---|---|---|
| GET | `/api/jobs` | — | registry + studio state merged, `flagged` id list |
| GET | `/api/status` | — | worker idle/busy, queue, current job + stage |
| POST | `/api/reroll` | `{job, prompt?, seed?}` | persist prompt (if given), queue the job (seed omitted → random; ignored for `fx_*` — the envelope has no seed) |
| POST | `/api/prompt` | `{job, prompt}` | persist a prompt edit without queueing (empty → revert to canonical) |
| POST | `/api/accept` | `{job}` | mark the current result accepted in `accepted.json` |
| GET | `/thumb/<kind>/<job>.png` | — | `draft` / `raw` / `snapped` thumbnail (`raw`/`snapped` prefer the studio reroll, falling back to the canonical store); cache-busting via `?v=<mtime>` |
| GET | `/thumb/td/<label>/<deg>.png` | — | top-down ship rotation preview (PIL NEAREST, pinned degrees) |
| GET | `/thumb/fx/<size>/<kind>` | — | wake previews: `anim.gif` (staged API gif) / `comp.png` (staged wake under the ship) / `shipped.png` (the committed family — in game now) |

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
- **Never-404 thumbs**: terrain `snapped` falls back to its normalized
  gen sheet (terrain has no rembg/snap); every thumb slot of a listed
  job degrades to a `missing` cell in the UI instead of breaking the
  grid. Thumbs go through a bounded in-memory cache keyed by source
  path + mtime.
- **Prompts never go empty**: `tools/model_pass.py` is untracked and
  rewritten by re-roll rounds — a torn or reshaped parse now keeps the
  last good parse, else falls back to the **embedded** proven-wording
  constants (icon overrides + style shipped in chain.py; the td/fx edit
  bases come from the pass tools' pinned descriptors).
  `default_prompt` and `canonical_seed` never raise; `registry()` guards
  each job so one bad store file cannot 500 `/api/jobs` (that 500 was the
  empty-grid / empty-textarea failure mode). Driver source + error are
  visible at `GET /api/status` → `driver`.
- **Original prompts (user direction: edit from the actual original)**:
  every generation stores the EXACT prompt in `studio/state.json`
  (`original_prompt` + `original_prompt_source: "exact"`); icon jobs are
  backfilled with a faithful **reconstruction** of the driver's actual
  wording (ICON_PROMPT_OVERRIDES + style; terrain per-sheet clauses),
  tagged `original_prompt_source: "reconstructed"`
  (or `"default"` if even the fallback wording had to be used — never
  pinned to state.json so it upgrades when the driver parses again;
  the td/fx families share this never-pin rule — `td_default_prompt`
  degrades to the bare `{ship} sailing ship` template only when the
  pinned descriptor AND the raw-store manifest both fail, and the
  registry tags that source `"default"` via `td_fallback_prompt`).
  The textarea pre-fills the original; **↺ original** reverts the box
  (and clears the saved custom edit) byte-identically.

## Job shapes (icons — driver-drift tolerant)

- **Icon group sheets** `iconsheet_<group>` (progress key `icons_<group>`;
  12 families of 8–14 icons): the card shows the sheet draft, the
  generated sheet, and the group's **first icon crop** as the snapped
  representative; they lead the Icons tab. **Re-roll** regenerates the
  whole group through chain.py's ported driver chain — layout → 384px
  clamped windows → green-killed 64px cell masks vs 32px draft masks →
  aligned-IoU greedy assignment (the model may move icons) → per-icon
  rembg + key + snap → **canonical `model_raw/snapped/icon_<id>.png`
  writes** (+ studio copies + debg). **Accept** records the group and
  triggers one `--import-icons <raw>/snapped <studio>/snapped` run (later
  dirs win per id, so studio re-roll crops win); per-icon in-game /
  rejected reasons surface in the card's status line.

The registry **never raises**: draft files whose id starts with a
retired prefix (`hull_` / `sheet_` / `terrain_` / `px_`) are skipped
outright, an unparseable/unknown draft id is degraded to a generic card,
and both are reported in `/api/status` → `registry.warnings` and
`/api/jobs` → `warnings` — the API always answers valid JSON.

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
3. **Icon sheets** (`iconsheet_<group>`): one
   `build_ui_art --import-icons <raw>/snapped <studio>/snapped` run;
   per-icon REJECT lines surface per icon in the card's status.
4. The card status walks **queued for ingest → ingesting… → in game ✓**
   or **REJECTED / error: <reason>**; the result (state, reason, log
   tail) is stored per job in `studio/state.json` (`ingest` key) and
   mirrored into `accepted.json`.
5. Header/filter chip **In game (n)** lists accepted+ingested jobs.
6. Single-icon accepts record acceptance only — tagged
   **accepted (game flow pending)**.

Restart note: the token runtime loads data artifacts (no `godot --import`
needed after a token replace) — restart the game to see accepted art.
The studio never shells out to godot itself.

**Coordination caution**: the batch per-hull refactor writes the same
canonical `model_raw/snapped/` paths — avoid accepting a job while a
batch re-roll is writing that same job's file (the single-file atomic
copy tolerates it; the next ingest run picks up whichever bytes won).

## Notes

- Canonical prompts are reconstructed from `tools/model_pass.py` by AST
  parsing (literals via `ast.literal_eval`; `ICON_PROMPT_OVERRIDES` — which
  references `ICON_STYLE` — via an AST-gated eval). If the driver's constant
  surface drifts, boot fails loudly instead of shipping stale wording.
- The studio queue is independent of any concurrent `model_pass.py` batch:
  all studio output lives under `model_raw/studio/**`; ComfyUI uploads use
  unique filenames and client id `sailage-studio`.
