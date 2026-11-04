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

## Notes

- Canonical prompts are reconstructed from `tools/model_pass.py` by AST
  parsing (literals via `ast.literal_eval`; `ICON_PROMPT_OVERRIDES` — which
  references `ICON_STYLE` — via an AST-gated eval). If the driver's constant
  surface drifts, boot fails loudly instead of shipping stale wording.
- The studio queue is independent of any concurrent `model_pass.py` batch:
  all studio output lives under `model_raw/studio/**`; ComfyUI uploads use
  unique filenames and client id `sailage-studio`.
