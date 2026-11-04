# VENDORED.md — provenance of `tools/yoyopixel/`

Vendored from the **YoYoPixel** pixel-art engine project — MIT License,
© 2026 SbName. Adopted by **vendored re-extraction only**: nothing in this
directory references the source clone live (no paths outside this
directory, no network access at runtime, no npm install).

| file | origin |
|------|--------|
| `pixelart-skill.md` | copied verbatim from the upstream clone |
| `LICENSE` | copied verbatim (MIT full text, © 2026 SbName) |
| `render.js` | engine core **extracted** from the upstream `engine-v3.html` `<script>` — the pixel-math only: `PB`, `blit`/`blitA`, `H`, `hx`, `nz`, `pk`, `inE`/`inRR`, `shade`/`dk`/`lt`, `adaptiveOutlineColor`, `MAT_SHADERS`, `renderSprite` — wrapped with a first-party stdlib-only PNG encoder and a JSON-declaration CLI. The single deliberate code change vs upstream is marked `[SailAge]` inline (`renderSprite` pass 2 iterates material keys in sorted order, for byte-determinism). Deviations are listed in `render.md`. |
| `render.md`, `fixture_check.py`, `fixtures/` | first-party (this repo) |

- Provenance verified against the source clone at `~/repo/yoyopixel`
  (`pixelart-skill.md`, `engine-v3.html`, `LICENSE`); extraction date
  **2026-11-04** (Phase 10, wave 2, slot D). The licensing record lives in
  `LICENSE-NOTES.md` ("Scope: tools/yoyopixel/").
- Upstream **demo content** (the demo scene builders, the demo `SPRITES`
  templates and `C` palette in `engine-v3.html`) is not engine math and is
  not vendored; every sprite declaration used in this repo is first-party
  authored under `fixtures/` and the Phase-10 art pipeline.
- **No URLs are cited** (the convention of `LICENSE-NOTES.md`'s Phase-5
  section): the work is identified by title (YoYoPixel), author (SbName),
  year (2026), and license (MIT) only.
