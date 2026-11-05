# SailAge Model Studio

Local web UI so the user can re-roll model-generated art themselves:
edit a job's prompt, re-roll it against the local model services, inspect
the snapped result, and accept it.

- **Server**: `server.py` — stdlib only (`http.server.ThreadingHTTPServer`),
  binds `127.0.0.1:8010`, no auth (local tool). One background worker thread
  runs generation jobs strictly one at a time (~40 s each) from a FIFO queue.
- **Chain**: `chain.py` — self-contained re-implementation of the validated
  model-pass pipeline (`tools/model_pass.py` is parsed read-only for the
  canonical prompt wording, never imported).
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

## Chain (per sprite job)

1. **draft** — `model_raw/drafts/<job>.png` → base64 → POST
   `http://127.0.0.1:8001/edit` `{"image","prompt","seed"}` (response body
   IS the PNG, 2 attempts).
2. **rembg** — ComfyUI `http://127.0.0.1:8000`: multipart `/upload/image`,
   the API-format workflow from
   `LifeSimulator/src/lib/comfyui/workflow-template-rembg.json` **AS-IS**
   (InvertMask kept — polarity verified), `/prompt`, poll `/history`, `/view`.
3. **snap** — nearest-resize to 512×512 → majority-vote downscale to the 64
   logical grid over opaque px → quantize to `sorted(validate_data.BLOCK_HULL)`
   (`BLOCK_ICON` for icons) → hull-only pennant-source snap (channel-sum
   Δ≤40 of `#b3191f` → the exact source hex) + masthead presence check +
   e/w long-axis band check (tier bands 28–36 / 40–52 / 52–60).
4. **writes** — studio cache only, atomic (tmp + rename):
   `model_raw/studio/gen/<job>.png`, `studio/snapped/<job>.png` (64×64),
   `studio/debg/<job>.png` (rembg intermediate, kept so an offline re-check
   can re-run the snap deterministically), `studio/state.json` (per job:
   prompt, seed, status, metrics, timestamps), `studio/prompts.json`
   (edited prompts), `studio/accepted.json` (accept marks).

Terrain jobs follow the driver's terrain path instead: gen response decoded,
nearest-normalized to 1024×512 when it drifts, stored as the studio gen
artifact (no rembg/snap).

## API

| Method | Path | Body | Purpose |
|---|---|---|---|
| GET | `/api/jobs` | — | registry + studio state merged, `flagged` id list |
| GET | `/api/status` | — | worker idle/busy, queue, current job + stage |
| POST | `/api/reroll` | `{job, prompt?, seed?}` | persist prompt (if given), queue the job (seed omitted → random) |
| POST | `/api/prompt` | `{job, prompt}` | persist a prompt edit without queueing (empty → revert to canonical) |
| POST | `/api/accept` | `{job}` | mark the current result accepted in `accepted.json` |
| GET | `/thumb/<kind>/<job>.png` | — | `draft` / `raw` / `snapped` thumbnail (`raw`/`snapped` prefer the studio reroll, falling back to the canonical store); cache-busting via `?v=<mtime>` |

## UI

- One card per job: three thumbnails (draft | raw | snapped), band OK/OVER
  badge (e/w hull jobs; bands 28–36/40–52/52–60), pennant ✓/✗ badge,
  mirror-derived mark on `e`/`ne`/`se` (⇄ derived from `w`/`nw`/`sw`,
  doc f6c00bb), editable prompt textarea (persisted per job), seed field
  (blank → random; canonical seed shown as placeholder), Re-roll / Accept
  buttons, live status line (queued / generating Ns… / done / band-fail).
- Family tabs (All / Ships / Icons / Terrain / Flagged) and a
  **Re-roll ALL flagged** button (jobs with band OVER or pennant ✗).

## Robustness (hardened after the browser broken-thumb incident)

- **HTTP burst safety**: HTTP/1.1 keep-alive + `request_queue_size = 128`
  (the stdlib TCP default of 5 dropped connections when a browser fired
  ~500 `<img>` requests at once — the intermittently-broken-thumbnails
  mechanism; single curl requests never hit it). `do_HEAD` answers
  headers-only instead of the stdlib 501 HTML page.
- **Never-404 thumbs**: a hull mirror dir (`e`/`ne`/`se`) whose file is
  gone (the 5-dir canonical round can prune them) is served from its
  `w`/`nw`/`sw` base **horizontally flipped** (the ingestion's mirror_x —
  exact for the whole snap chain, which is cellwise under column mirror),
  with an `X-Mirrored: <base>` header and a `(⇄ base)` caption. Terrain
  `snapped` falls back to its normalized gen sheet (terrain has no
  rembg/snap). Flipped PNGs go through a bounded in-memory cache keyed by
  source path + mtime.
- **Prompts never go empty**: `tools/model_pass.py` is untracked and
  rewritten by re-roll rounds — a torn or reshaped parse now keeps the
  last good parse, else falls back to the **embedded** proven-wording
  constants (all families/dirs/rigs/icon overrides shipped in chain.py).
  `default_prompt` and `canonical_seed` never raise; `registry()` guards
  each job so one bad store file cannot 500 `/api/jobs` (that 500 was the
  empty-grid / empty-textarea failure mode). Driver source + error are
  visible at `GET /api/status` → `driver`.
- **Original prompts (user direction: edit from the actual original)**:
  every generation stores the EXACT prompt in `studio/state.json`
  (`original_prompt` + `original_prompt_source: "exact"`); legacy batch
  jobs are backfilled with a faithful **reconstruction** of the driver's
  actual wording (hull template + the re-roll round's kept `stated_px`
  calibration from progress.json, ICON_PROMPT_OVERRIDES, terrain
  per-sheet clauses), tagged `original_prompt_source: "reconstructed"`
  (or `"default"` if even the fallback wording had to be used — never
  pinned to state.json so it upgrades when the driver parses again).
  The textarea pre-fills the original; **↺ original** reverts the box
  (and clears the saved custom edit) byte-identically.

## Job shapes (legacy + sheets + icon groups — driver-drift tolerant)

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

The store has carried two ship-job shapes; the registry supports both and
**never raises**: an unparseable/unknown draft id is skipped (or degraded
to a generic card) and reported in `/api/status` → `registry.warnings`
and `/api/jobs` → `warnings` — the API always answers valid JSON.

- **Legacy** `hull_<ship>_<dir>` — per-dir jobs; e/ne/se are mirror
  displays (⇄ badge, flip-served thumbs when their files are pruned).
  When a hull has a sheet job, its leftover per-direction jobs are marked
  `superseded: true` (with `superseded_by: sheet_<hull>`): they stay
  listed in `/api/jobs` for transparency, render **read-only** (no
  Re-roll/Accept, note: "re-roll the sheet card instead") and only in the
  collapsed **Legacy** tab — hidden from All/Ships/Flagged, skipped by
  Re-roll ALL flagged, and refused (409) at the reroll/accept API so the
  retired per-dir path can never shadow the sheet pipeline's canonical
  outputs.
- **Per-hull sheets** `sheet_<hull>` (draft name; progress/ledger key
  `hull_<hull>`) — one 1792×1152 5-cell sheet per /edit (w/n/s/sw/nw
  512² cells + legend). The card shows the sheet draft, the generated
  sheet, and the **w crop** as the snapped representative (w is the
  band-gated base cell; the other 4 crops live at their legacy per-dir
  paths). Band/pennant/flags ride the w cell. A studio re-roll crops the
  generated sheet per cell (nearest, driver box math incl. non-integer
  scale), rembg + chroma-green keys + snaps each into
  `studio/snapped/hull_<hull>_<dir>.png`; **Accept** atomically copies
  those crops to the canonical per-dir paths and triggers one ingest run
  gated on the w base — or, with no studio crops, just records
  acceptance + the ingest (the batch driver writes the canonical crops
  itself).

## Accept → in game (一键进游戏)

**Accept** on a ship job now flows straight into the game build:

1. The accepted snapped PNG (`studio/snapped/<job>.png`, falling back to
   the canonical store file) is atomically copied to
   `model_raw/snapped/<job>.png` — the stable ingestion-input path.
2. The worker (same FIFO as generation) runs
   `python3 <repo>/tools/build_ui_art.py --import-ships <repo>/tools/ui_art/model_raw/snapped`
   — the idempotent full-ladder re-run (~1–2 min). Gate rejections are
   non-fatal fallbacks: band out-of-range / masthead missing / pennant
   snap failures come back as `REJECT <job>: <reason> — <detail>` lines.
3. The card status walks **queued for ingest → ingesting… → in game ✓**
   or **REJECTED: <reason>**; the result (state, reason, ledger sha,
   log tail) is stored per job in `studio/state.json` (`ingest` key) and
   mirrored into `accepted.json`. e/ne/se accepts resolve through their
   `w`/`nw`/`sw` base (the ingestion gates the base; mirrors derive).
4. Header/filter chip **In game (n)** lists accepted+ingested jobs.
5. Icon/terrain accepts record acceptance only — tagged
   **accepted (game flow pending)** until their ingestion surfaces land.

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
