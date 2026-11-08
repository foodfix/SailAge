# IMPLEMENT — Phase 10: UI element kit & generated pixel art

Global theme, six widget atoms, a first-party pixel-art pass (chrome,
icons, tokens, terrain, FX, portrait placeholders), battle/UI/sea
animation, and a full de-duplication sweep of every screen.

> Authored and **verified against the live tree on 2026-11-04**. This
> document is self-contained: every contract, number proposal, inventory,
> gate, and correction below is normative as written here. No external
> document is required to execute it.

Runs after the **Phase-9 W6 gate** (complete — see `AGENTS.md`).

---

## Review corrections (folded in throughout — 2026-11-04 live-tree review)

1. **This phase is Phase 10.** There is no audio phase in the tree —
   `settings.audio.*` does not exist anywhere — so there are no audio
   preconditions, no S19 row coordination, and no share of the settings
   panel: S19 is simply restyled by the kit with no new rows. Audio is
   its own future phase.
2. **The new validator group is group 13.** `tools/validate_data.py`
   has groups 1–12 only; group 13 is the next free number.
3. **`80-* §4.7.1` heading placement.** §4.7.1 (S10 battle screen)
   through §4.7.16 already exist. The FX/UI-motion/sea timing tables
   land as **§4.7.17**; the Phase-10 `ui_strings` inventory (if any keys
   land beyond W2) reserves **§4.7.18**. New **§4.9** (theme & kit)
   slots after the existing §4.8 "Placeholder art & palette" — that is
   the section this phase rewrites.
4. **Screen numbers.** The world map is **S3** (S2 is nationality
   select) — the arrow field, world markers, the directional player
   token, and the `W`/`C` keys all target **S3**.
   **S13 is the palace, not combat** — the W5 combat sweep is S10/S11
   (duel modal)/S21 + overlays; the `trophy` icon is consumed by the S13
   commendation dialog and therefore lands in the W4 **port** slot.
5. **Role badges are 7, not 8.** `data/captains.json` roles are exactly
   `trader, coaster, courier, patrol, privateer, pirate, hunter` — there
   is no `treasure` role. A.2's badge set is 7 ids; the cloth sheet set
   stays 8 (7 roles + player) and A.7 is unchanged.
6. **Tier-3 non-legend captains: 61, not 41** (parking-lot pool).
7. **Sweep size: 484 `add_theme_*` call sites across 26 files**
   (measured 2026-11-04 via `grep -rn add_theme_ scenes/ scripts/`).
   No doc pins a count inside gates — the W6 audit test guards the
   *rule* (nothing styled outside
   `{ui_theme.gd, ui_kit.gd} ∪ allowlist`), so drift can never red a gate
   on a number.
8. **There is no "single toast owner".** Toasts are owned by the HUD
   (`hud.toast_text`, the real funnel used by S3/world and port screens)
   plus several private modal toasts. Decision 8's toast fade is applied
   at the HUD funnel **and** via a kit toast atom that private modal
   toasts adopt in their sweep slots; fade constants are pinned once
   (§4.7.17).
9. **`palette.gd` restructure is append-only.** Existing constant names
   (`SEA`, `PANEL_BG`, `BUTTON_H`, `nation_color()`, …) are referenced
   repo-wide and **may not be renamed**. Blocks = comment-grouped
   sections (the current §-anchored layout becomes the terrain/chrome
   blocks) plus new block constants appended per the W1 §4.8 hex tables.
10. **Node pinned to v24.16.0** (verified installed); the YoYoPixel
    clone is verified at `~/repo/yoyopixel` (`pixelart-skill.md`,
    `engine-v3.html`, `LICENSE` — MIT, © 2026 SbName). The
    `LICENSE-NOTES.md` entry cites exactly that.
11. **Shared-file ownership matrix** (new, §Execution protocol) — with
    four agents in parallel, `build_ui_art.py`, `validate_data.py`, and
    `ui_strings.json` each need exactly one writer per wave (or per
    phase), or worktrees collide at merge; the matrix is pinned per
    wave in §4.

### Review-verified facts (not designs — checked against the tree, W1 cites them)

- `data/captains.json`: **1 275** captains, **all** carrying
  `appearance` with exactly the value sets decision 10's composer uses
  (`face ∈ lean|round|scarred|weathered`, `beard ∈ clean|forked|full|stubble`,
  `hair ∈ black|brown|grey_streaked|sun_bleached`, `eyes ∈ dark|grey|hazel|pale_blue`);
  **24 `legend: true`**; roles as correction 5; tier-3 non-legend = 61.
- `data/named_pirates.json`: **4**. `data/ship_types.json`: **16**, tier
  partition **4 / 8 / 4** (the exact rosters used in A.3:
  t1: latin, sloop, galiot, pinnace; t2: caravel, galley, brigantine,
  fluyt, junk, dhow, caravela_redonda, xebec; t3: nao, carrack, galleon,
  galleass). `data/goods.json`: **40** (food 11 / material 14 /
  textile 6 / luxury 9). `data/equipment.json`: **24**.
  `data/discoveries.json`: **30** (natural 15 / ruins 10 / relic 4 /
  creature 1). `data/officers.json`: **96**. `data/nations.json`: **6**
  (portugal, spain, england, holland, ottoman, italy) → the 9-owner
  token set (6 nations + player + neutral + pirate) holds.
- Facilities in `data/ports.json` are market/tavern/inn ×150, shipyard
  ×109, guild ×105, palace ×6 (+ the `equipment_stock` capability flag,
  not a building) → the 6 facility tokens cover every building.
- `I18n.t_key` exists (`autoload/i18n.gd`). `title_screen.tscn` is the
  locked main scene. `tools/` carries **54** test suites;
  `tools/validate_data.py` groups 1–12. `data/ui_strings.json` has 988
  keys at review time.
- `palette.gd` already provides every color §2 below needs
  (`PANEL_BG`, `PANEL_LINE`, `TEXT`, `ACCENT`, `GOOD`, `WARN`, `BAD`,
  `SEA`, `COAST_SEA`, `PORT_NEUTRAL`) and the sizing constants the atoms
  need (`BUTTON_H = 40`, `ROW_H = 32`, `MARGIN = 16`).
- The wind-arrow color pins (`TEXT` wind / `COAST_SEA` current) match
  existing palette constants.

---

## Execution protocol — ≤ 4 background sub-agents, master merges (mirrors the Phase-9 protocol)

- **At most 4 concurrent sub-agents per wave.** Each agent gets:
  its **own worktree** (`worktree_create`), its **own branch** named
  `phase10/w<N>-<slot>-<slug>`, a **background** launch, and a prompt
  carrying: the wave spec slice, the owned-path matrix below, the gates
  it must run before reporting done, and a rule that it **never touches
  another slot's owned paths**.
- **Master merges sequentially A → B → C → D** onto `main`. After *each*
  merge the master runs `python3 tools/validate_data.py` (exit 0) plus
  the slot's targeted suites; at each wave gate the **full**
  `tools/run_tests.py` runs green before the next wave launches. Ledger
  lines (commit, gate results, adjudications) are appended to this
  doc's status block per merge, exactly as Phase 9 recorded them.
- **Single-owner rule:** within a wave each shared file has exactly one
  owning slot; the matrix is pinned per wave in the wave tables below.
  Other slots integrate against W1-pinned contracts (sprite ids,
  constants, doc tables), never against another slot's unmerged code.
- **`data/ui_strings.json` — one writer for the whole phase.** W2-C owns
  every new key (namespace `ui.kit.*`, zh/en both, inventoried in
  §4.7.18). Sweep slots (W4/W5) **reuse existing keys only**; a
  genuinely missing key escalates to the master ledger mid-wave and the
  master appends it on `main` directly (never a worktree collision).
- **`tools/build_ui_art.py` is owned by W3-B** (governor). Other W3
  slots ship declarative manifests under `tools/ui_art/<class>/` (new
  tool-owned dirs, added to the `90-*` tree in W1) plus fixture/reports;
  B's governor consumes them. `tools/validate_data.py` (group 13) is
  **W3-A only**. `data/maps/world_shore.png` + `tools/build_shore.py`
  are **W3-C only**. `tools/art_prompts.json`, `contact_sheet.png`,
  HTML preview are **W3-D only**.
- **Waves are sequential** (W1 → … → W6). W3's gate includes the
  **user contact-sheet review with veto** — the master presents the
  sheet; fixes iterate against the style guide / shader constants /
  hull rig fragments and rebuild (never a single-PNG edit).
- Slots that finish early report; the master never launches two waves
  at once and never merges out of order.

---

## 0. Decisions

1. **One code-built Theme** — `scripts/ui_theme.gd`: `build_theme() ->
   Theme` from `palette.gd` colors + named constants; applied at
   startup to the root window (`get_window().theme` in
   `title_screen._ready()` — S1 is the locked main scene) so it
   cascades to every control. **No `.tres`** (locked data-format
   decision). Headless tests that boot scenes directly apply
   `build_theme()` themselves (the direct-boot pattern is documented in
   the test docstring).
2. **Numbers are code constants, doc-pinned** — every stylebox number
   is a named constant in `ui_theme.gd`, pinned doc-first in `80-*`
   §4.9. No JSON theme, no validator changes for the theme itself.
3. **`scripts/ui_kit.gd` static factory, six atoms**:
   `button(text_key, kind ∈ default/primary/danger)` (40px min
   height, optional icon), `frame(title_key)` (titled PanelContainer:
   header + 16px-margin VBox), `row(cols, height=32)`,
   `footer(buttons)`, `value_bar(value, max, tier)` (GOOD/WARN/BAD),
   `field_row(label_key, control)`. Labels resolve through
   `I18n.t_key`; screens keep their `locale_changed` re-render pattern.
4. **Full sweep, combat included** — every per-screen styling builder
   (`add_theme_*`, local `StyleBoxFlat` factories, chart scrollbar
   styling) retires (484 sites / 26 files at review; see correction 7);
   theme + kit become the only styling path. Mechanical sweep: no
   screen redesign; visible diffs limited to unified hover/pressed/
   focus states, on-palette scrollbars, and the generated art.
   Exceptions require a documented §4.9 allowlist entry.
5. **Art is first-party, generated by `tools/build_ui_art.py`**
   (governor), authored in the YoYoPixel format (MIT,
   © 2026 SbName; source clone verified at `~/repo/yoyopixel`):
   - Vendored under `tools/yoyopixel/`: `pixelart-skill.md`,
     `LICENSE`, and the **extracted engine core** (the pixel-math
     script from `engine-v3.html`) wrapped as node `render.js` —
     reads JSON sprite declarations, writes PNGs via node stdlib zlib
     (~50-line encoder). **Zero npm dependencies; node pinned to
     v24.16.0** (verified present). `LICENSE-NOTES.md` gains the MIT
     entry (W1).
   - Two declaration styles: **string-array maps** (width/height +
     palette dict + pixel rows) for chrome, arrows, semantic marks;
     **engine templates / region+material declarations** for item-like
     32px classes (goods, equipment, facilities, FX) and 48px+ classes
     (portrait part sheets). The real engine renders the latter — no
     hand ports.
   - **Python is the pipeline governor**: 8-direction lossless
     transforms, owner remap tables, seam-ring application, nine-patch
     assembly, atlases, `contact_sheet.png`, validator glue. No browser
     in the build; rebuilds byte-identical under the pinned node +
     vendored engine (double-run fixture test).
   - **Color budgets = the skill's size tiers, everywhere**: 16×16 →
     8–12 · 32×32 → 12–20 · 48px+ → 15–25 — caps, not quotas.
   - **Consistency lives in doc-pinned shared palette blocks** —
     `palette.gd` gains comment-grouped blocks (append-only, correction
     9): shared icon block (~20–24), hull block (neutral shading ramps
     + 9 owner tint ramps; owner variants derive via remap tables),
     FX block, portrait block (~16–24 with skin/hair/cloth ramps),
     terrain block. Every palette hex must map to a block constant or
     group 13 fails it.
   - Output: indexed PNGs under `assets/ui/`, nearest-neighbor import,
     `.import` files committed (a single master-run
     `godot --headless --import` pass after the W3 merges, verified
     headless). Default Godot font unchanged; no custom fonts, no
     external textures.
6. **Sizes** — tiles, tokens and icons are **32×32**; chrome tiles are
   **16×16** (assembled into 48×48 nine-patch sheets, 16px margins,
   edge tiles in tile-repeat mode — frames render at any size at
   runtime); FX: cannonball/smoke 16×16, splash/impact 32×32; portraits
   **72×96** (3:4 vertical bust); discoveries **64×64**.
7. **Validator group 13** — byte-identical rebuild (Python + engine
   double-run); per-sprite hexes ⊆ class block, count ≤ size tier;
   inventory == consumed ids for every contract class; 8-direction
   transform relations pixel-exact; hull remap-table coverage; seam
   checks; hull tier footprint bands; `world_shore.png` byte-identity +
   edge-code domain + `world.png` consistency; `art_prompts.json`
   coverage. The heading8→dir-id table is pinned in `80-* §4.8` at W1.
8. **Animation** — timings doc-pinned at W1 (proposals in brackets;
   final values are W1's pins, recorded in §4.7.17):
   - **Battle FX**: presentation-only FX layer in `battle_screen` —
     cannonball flight tween (parabolic arc [300 ms]), splash
     [400 ms] / impact [300 ms] / smoke [500 ms] frame sets, sink fade
     [600 ms], per-event pause [150 ms]; an event sequencer queues
     move→volley→flight→impact. Respects the existing animate/instant
     switch (instant = all durations 0; sim, logs, determinism
     untouched — instant-mode logs stay byte-identical).
   - **UI transitions**: opacity/modulate only — toast fade-in
     [100 ms] / fade-out [150 ms] at the HUD `toast_text` funnel + the
     kit toast atom adopted by private modal toasts (correction 8);
     button press flash [100 ms] in `ui_kit.button()`. Gated by a
     `UiMotion` static (default on; suites off). Focus/hover and dialog
     open stay instant.
   - **Animated sea**: water kinds (`sea`, `coastal_sea`) render as
     flat tiles on a dedicated water TileMap layer with a canvas-item
     shader scrolling `sea_pattern.png` (64×64 two-level torus-safe
     dither mask) — period [800 ms], darkening [×0.82] (render math,
     not asset color); `UiMotion` off freezes at offset 0. Zero
     per-frame CPU, no cell swapping. S10 battle water reuses it.
     Chart + minimap stay flat raster (pinned).
9. **Art-style consistency, four layers**:
   1. **Style guide** (`80-* §4.8`, W1): uniform 1px outline on tokens
      (tool-applied; authored maps are outline-less); shading per the
      skill (highlight+base+shadow, texture hints at 32px, dither
      gradients at 48px+); light from NW; silhouette-first, readable at
      1:1; top-down for tokens, front-facing for icons; one dither
      family for terrain. **Seam rules**: all variants of a terrain
      kind share a byte-identical, wrap-continuous outer 1px ring (may
      carry dither); interiors vary freely; dither density ≤ 30% (W1
      pin); `sea_pattern.png` and nine-patch edge tiles torus-safe
      along their repeating axis; shore strips foam only on the
      land-facing band, transparent elsewhere, thickness shared with
      corner tiles. Engine seamlessness from TileMap chunk batching +
      nearest filtering + integer placement.
   2. **Style lives in the tool** — hull rig fragments (masts, lateen
      triangles, oar dots, tier-banded hull lengths), shared pattern
      functions, auto-outline pass; style fixes edit fragments/guide +
      rebuild, never single PNGs.
   3. **Machine proxies** (group 13) — budgets, outline rings, density
      bands, dither family, seam checks, transform relations.
   4. **Review gate (W3)** — tool emits `contact_sheet.png` (with a
      seam montage: 3×3 tiling per terrain variant, pattern repeat
      strip, shore corner mock) + optional self-contained HTML preview
      gallery; user eyeball pass with veto (fixes iterate
      guide/fragments, then rebuild).
10. **Portraits & placeholder classes**:
    - **v1 ships procedural busts for all 1 275 NPC captains + the
      player**: `scripts/ui/portrait_composer.gd` composes 72×96 busts
      from each captain's `appearance` dict (verified present on all
      1 275 — see review-verified facts) + role cloth (7 roles +
      player) — 256 combinations, 25 part sheets (A.7). Deterministic,
      instant, fully offline. Portrait slots land in dossier, hail,
      wanted posters, sightings, battle after-action, and the player
      card. Roster rows keep text + role badge.
    - **Pre-generated overrides**: `portrait_{id}.png` (72×96) for the
      24 `legend: true` captains + 4 named pirates, prompted in
      `tools/art_prompts.json`; **an override file always wins**.
      Tier-3 non-legend captains (**61**) can be promoted later by
      manifest edit.
    - **Discovery reveal pictures ×30** (64×64) are model-pass
      placeholders; the map side ships now as category markers (§
      inventory). `art_prompts.json` carries one shared
      `style_preamble` (pixel art, canvas per class, transparent
      background, single subject centered, 1px outline, palette hex
      list, Age-of-Sail 16th–17th c., no text/gradients/anti-aliasing;
      prompts in English) + per-asset `subject`.
    - **Future ingestion** (model pass): never commit raw model
      output — `build_ui_art.py --import <dir>` crops portraits to
      3:4, palette-quantizes BEFORE nearest-downscale, applies the
      outline pass and alpha threshold, then writes; group 13 gates
      the result. Per-class style anchors (one approved reference +
      img2img/reference-conditioning) for set consistency; every
      import run regenerates the contact sheet for human review.
    - **Runtime ComfyUI-style generation is deferred** — a future plan
      owns the optional localhost client, S19 enable row,
      `user://portraits/` cache, and the doc-first offline-lock
      amendment. The override-wins seam is the only hook it needs.
    - Officers (96) stay text cards (parking lot).

---

## 1. Doc-first wave (W1)

| Doc | Amendment |
|---|---|
| `docs/00-OVERVIEW.md` | §5 Phase-10 row; glossary: 主题 theme / 控件 atom / 样式盒 stylebox / 焦点框 focus ring / 像素画 pixel art / 令牌 token |
| `docs/80-UI-UX.md` | new **§4.9 "Shared theme & widget kit"** (application point, every pinned number, state matrix, atom contracts, variations, icon params, no-per-screen-styling rule + allowlist); §4.7 toast-fade amendment + **§4.7.17 FX/UI-motion/sea timing tables** (§4.7.1–4.7.16 taken — correction 3); **§4.8 rewrite** — generated-art rule: `build_ui_art.py` is the only art source, the art-language style-guide block (outline, skill-tier budgets, palette blocks with full hex tables, shading, light, perspective, seam rules), hull-letter overlay rule, heading8→dir table, tier footprint bands (final px values pinned here), icon sizes/display rule, NPC world-map LOD stays squares, **S3** arrow-field spec (stride 4×4, `W`/`C` keys, default off, TEXT/COAST_SEA colors, month re-sample) |
| `docs/90-ARCHITECTURE.md` | §4 tree gains `scripts/ui_theme.gd`, `scripts/ui_kit.gd`, `scripts/ui/portrait_composer.gd`, `scripts/world/arrow_field.gd`, `assets/ui/`, `tools/build_ui_art.py`, `tools/build_shore.py`, `tools/art_prompts.json`, `tools/ui_art/<class>/` (manifest dirs), `tools/yoyopixel/` (skill + LICENSE + extracted engine core + node `render.js`, node pinned v24.16.0), `data/maps/world_shore.png`; why `project.godot` stays unchanged; map_loader terrain-art + overlay-layer note; `--import` AI-ingestion path; portrait resolution ladder with the future-client hook left open |
| `docs/10-DATA-SCHEMA.md` | **§8 group-13 spec** (all checks of decision 7); `assets/ui/` joins the tool-owned artifact family (never hand-edited, same rule as `world.png`); **new §6.x** — `data/maps/world_shore.png` raster spec (edge codes, adjacency rule, `tools/build_shore.py`, byte-identity) |
| `LICENSE-NOTES.md` | YoYoPixel entry (SbName, 2026, MIT; title/author/year/license, no URL) — entry follows the existing entries' format |

---

## 2. Theme layer — control coverage

- **Button** (+ Primary/Danger/Quiet variations): bg `PANEL_BG`,
  border 2px `PANEL_LINE`; hover border `ACCENT`; pressed bg
  `PANEL_LINE`; disabled text `PANEL_LINE`; keyboard focus = extra
  2px `ACCENT` ring (first unified focus visuals; game is
  keyboard+mouse). ("Primary"/"Danger" variations take `ACCENT`/`BAD`
  accents per the W1 state matrix.)
- **V/HScrollBar**: transparent trough, 8px grabber `PANEL_LINE`,
  hover/pressed `ACCENT`, min grabber 24px.
- **Panel/PanelContainer**: `PANEL_BG` + 2px `PANEL_LINE`, radius
  4px (nine-patch sheets layered at W3; flat StyleBoxFlat remains
  the fallback when a texture id is absent).
- **LineEdit/TextEdit**: `PANEL_BG`, border `PANEL_LINE`, focus
  `ACCENT`. **Sliders** (S19): grabber `ACCENT`, groove
  `PANEL_LINE`. **Tooltips**: `PANEL_BG`/`TEXT`, radius 4px, 8px
  padding. **Label**: `TEXT`, plus a `Dim` variation for secondary
  row text.

All hexes resolve to existing `palette.gd` constants (review-verified).

---

## 3. Systems riding on the art

- **S3 wind/current arrow field** — `scripts/world/arrow_field.gd`
  (pure): samples decoded ocean layers (`prevailing_for(cell, month)`
  for wind; reversal-applied current vector → 8-bucket) on a 4×4-tile
  grid over the visible window + apron, water cells only, re-sampled
  on month change. `W`/`C` keys on S3 (session-local, default off),
  mirroring the chart's toggles. The HUD's existing wind/current
  arrows swap to the same sprites (hud.gd change owned by W4-B,
  sprite ids pinned by W3-A); S10 minimap keeps its pinned vector
  arrows.
- **World markers** — `marker_wreck`, `marker_treasure`, and
  `marker_discovery_{category}` render at world tiles like port
  markers (static). Discovery markers are **discovered-only**
  (undiscovered sites stay hidden; the hunt is `region_hint` +
  chart amber leads).
- **Portrait ladder** — override file → procedural composer.
- **Settings** — S19 (both mounts: S1 and S4) is **restyled via the
  kit; no new rows**. There are no audio rows to coordinate with —
  audio is a future phase (correction 1).

---

## 4. Waves — slots, ownership, gates

### W1 — Docs (≤ 3 slots; merges A → B → C)

| Slot | Branch | Owns | Deliverable |
|---|---|---|---|
| A | `phase10/w1-a-80` | `docs/80-UI-UX.md` | §4.9 + §4.8 rewrite + §4.7.17 timing tables + every number pin (stylebox constants, palette-block hex tables + budgets, footprint bands, heading8→dir table, arrow-field spec) |
| B | `phase10/w1-b-schema` | `docs/10-DATA-SCHEMA.md` | §8 group-13 spec; `assets/ui/` family row; §6.x `world_shore.png` spec |
| C | `phase10/w1-c-arch` | `docs/90-ARCHITECTURE.md`, `docs/00-OVERVIEW.md`, `LICENSE-NOTES.md` | §4 tree + notes; §5 Phase-10 row + glossary; MIT entry |

Gate: cross-doc refs resolve; `validate_data.py` exit 0 after each
merge. (Biggest single W1 task = palette-block hex tables in slot A —
decision 5's blocks and every hex, since group 13 enforces membership.)

### W2 — Theme + kit + gallery + engine bring-up (4 slots; merges A → B → C → D)

| Slot | Branch | Owns | Depends on | Deliverable |
|---|---|---|---|---|
| A | `phase10/w2-a-palette` | `scripts/palette.gd` | W1 | Block restructure, append-only (correction 9); comment-grouped blocks + new block constants with the W1-pinned hexes; no renames; `nation_color()` stays |
| B | `phase10/w2-b-theme` | `scripts/ui_theme.gd` (new), `scripts/ui/` (new dir), `scenes/title/title_screen.gd`, `tools/test_ui_theme.*` | W1 pins (+ A merged; may develop against the hex tables before A lands since contract = W1 doc) | `build_theme()+apply in title_screen._ready(); tools/test_ui_theme suite (pins: colors == palette constants, button min-height 40, scrollbar 8, min grabber 24, focus ring ACCENT, radius/pad 4/8); direct-boot pattern documented in suite docstring |
| C | `phase10/w2-c-kit` | `scripts/ui_kit.gd` (new), `scripts/ui_motion.gd` (new — the `UiMotion` static), gallery scene, `tools/test_ui_kit.*`, **`data/ui_strings.json` (sole phase writer: `ui.kit.*` namespace)** | W1 pins | Six atoms; press flash; `UiMotion`; headless-bootable widget gallery; `test_ui_kit` suite (heights 32/40, variations exist, zh/en key resolution, value_bar tiers at pinned thresholds, icon id → texture); §4.7.18 key inventory staged |
| D | `phase10/w2-d-engine` | `tools/yoyopixel/` (new), node `render.js`, pinned-node fixture checker | W1 | YoYoPixel vendoring (skill md + LICENSE + engine core extracted from `engine-v3.html`), ~50-line stdlib-zlib PNG encoder, zero npm deps, node v24.16.0 pinned, double-run byte-identity fixture |

Gate: suites green (`test_ui_theme`, `test_ui_kit`, plus spot
regressions); engine fixture green; validator exit 0 after each merge;
zh/en parity green.

### W3 — Art pass (4 slots; merges A → B → C → D)

Contract for all slots: every sprite id below is the contract pinned in
`80-* §4.8/§4.9` at W1; slots never hand-edit another class's manifest
dir.

| Slot | Branch | Owns | Deliverable |
|---|---|---|---|
| A | `phase10/w3-a-icons` | `tools/ui_art/chrome/`, `tools/ui_art/icons/`, `tools/validate_data.py` (group 13, sole writer), `scripts/ui_theme.gd` (nine-patch texture-variant edit) | Chrome string-array maps (15 tiles); all A.2 semantic-icon manifests; **group-13 validator** (all decision-7 checks + negative probes); nine-patch `StyleBoxTexture` variants layered over the StyleBoxFlat fallback in the theme |
| B | `phase10/w3-b-hulls` | `tools/build_ui_art.py` (governor, sole writer), `tools/ui_art/hulls/`, Python 8-dir transform + remap machinery | Governor (engine render loop, transforms, remap tables, seam-ring pass, nine-patch assembly from A's tiles, atlases); hull rig fragments; 16 hulls × 2 authored maps; 9-owner remap tables from the hull block; footprint-band checks; 1 152 token derivations + 6 facility tokens |
| C | `phase10/w3-c-terrain` | `tools/ui_art/terrain/`, `tools/build_shore.py` (new), `data/maps/world_shore.png` (new) | Terrain manifests (13) + `sea_pattern.png`; `build_shore.py` from `world.png` (edge codes only on water cells adjacent to land/reef/ice); byte-identical double-run; seam + edge-code fixtures |
| D | `phase10/w3-d-fx-portraits` | `tools/ui_art/fx/`, `tools/ui_art/portraits/`, `tools/art_prompts.json`, `contact_sheet.png`, HTML preview | FX frames (11) + portrait part sheets (25) via engine declarations; prompt manifest (one shared style_preamble + per-asset subjects: 24 legend + 4 pirates + 30 discoveries); contact sheet + seam montage + optional HTML preview |

Gate: validator exit 0 (groups 1–13; new negative probes go red on
off-palette pixel / hand-edited PNG / broken transform / out-of-band
footprint / invalid shore code / seam violation); double-run
byte-identity; **user contact-sheet review (veto → iterate
guide/fragments → rebuild)**; master-run `godot --headless --import`
pass commits the `assets/ui/*.import` files; gallery/theme boot with
textures.

### W4 — Sweep, non-combat (4 slots; merges A → B → C → D)

Sweep rule everywhere: **no screen redesign**; styling retires to
theme/kit; only unified states + on-palette scrollbars + generated art
may visually change; new keys are forbidden (reuse `ui.kit.*` + existing
keys — escalation protocol in the execution rules).

| Slot | Branch | Owns | Scope |
|---|---|---|---|
| A | `phase10/w4-a-port` | `scenes/port/` (8 `.gd`) | Port hub + facility screens (S4–S7, S12, S13 + provisioning modal): kit frames/rows/footers; `good_{id}` icons + `trend_up`/`trend_down`/`event_demand` in market rows (S5); `eq_{id}` in shipyard/market/drops (S6); facility tokens on port cards; **S13 `trophy` icon in the commendation dialog** (correction 4); toast-atom adoption for private toasts |
| B | `phase10/w4-b-shared` | `scenes/ui_shared/` (13 `.gd`) | HUD (`hud.gd`: resource icons, **wind/current arrow sprite swap** using W3-A's pinned ids, toast-fade at `toast_text`), S19 settings panel restyle (no new rows), intel window tabs (captain view, fleet list tokens + role badges, officer roster, 海图 tab untouched except styling), wanted posters + sighting rows (role badges; portrait slot consumption per D's composer contract), dialogs (confirm/save-slot/dialog box), ending + gameover, `fleet_picker` host-faces |
| C | `phase10/w4-c-world` | `scenes/world/` (5 `.gd`), `scripts/world/map_loader.gd`, `scripts/world/arrow_field.gd` (new), `scripts/world/` consumers | map_loader: terrain tiles per legend kind + cell-hash variant pick, shore overlay TileMap layer from `world_shore.png`, dedicated water layer + sea shader (S10 reuses the same shader via shared script); S3: directional player token (8-dir), `arrow_field` + `W`/`C` keys (default off, re-sample on month), world markers (`marker_wreck/treasure/discovery_*`, discovered-only), discovery-moment/log illustration slots (category placeholder), hail modal portrait slot |
| D | `phase10/w4-d-title-ui` | `scenes/title/` (3), `scenes/ui/` (2), `scripts/ui/portrait_composer.gd` (new) | Title/nationality/creation screens via kit (theme application point already landed at W2-B); `portrait_composer.gd`: fixed `appearance` dict → fixed part list, override-file-wins; dossier panel + character card portrait slots (player card); dossier/sighting surface contracts handed to B |

Merge-time note: chart scrollbar styling and S17 chart screen styling
retire under C (chart + minimap rendering itself stays flat raster —
pinned). Cross-slot contracts (HUD sprite ids B↔A-W3; portrait slot
calls B/C↔D) are pinned in the W1/W2 docs or the master ledger, never
imported across branches.

Gate: targeted suites after each merge; **full `tools/run_tests.py`**
green + validator exit 0 at the wave gate; day-tick profiling unchanged
in behavior.

### W5 — Sweep, combat + FX (2 slots; merges A → B)

| Slot | Branch | Owns | Scope |
|---|---|---|---|
| A | `phase10/w5-a-battle` | `scenes/combat/battle_screen.gd`, `scenes/combat/battle_grid_overlay.gd` | S10: battle-grid hull tokens ← `heading8` (heading8→dir table per W1 pin); battle water layer reusing the sea shader; `formation_*` icons; the presentation-only FX layer — event sequencer (move→volley→flight→impact), parabolic flight tween, splash/impact/smoke frame players, sink fade, per-event pauses; animate/instant switch (instant = durations 0, logs byte-identical, determinism untouched); after-action portrait slot |
| B | `phase10/w5-b-sandbox` | `scenes/combat/battle_sandbox.gd`, `scenes/combat/duel_modal.gd` | S21 sandbox + S11 duel modal: kit/theme sweep only (no new behavior; S21's zero-write audit stays green) |

Gate: `test_battle_screen`, `test_battle`, `test_tournament`,
`test_battle_sandbox` all green; instant-mode battle logs byte-identical.

### W6 — Acceptance (master only)

- Full `tools/run_tests.py` green (54+ suites);
  `python3 tools/validate_data.py` exit 0, **groups 1–13**.
- Byte-identical rebuild check: `build_ui_art.py` + `build_shore.py`
  double-run produces zero diffs; **no hand-authored PNG under
  `assets/ui/`** (rebuild-diff clean).
- Grep bounds: `add_theme_stylebox_override` / `StyleBoxFlat` /
  `StyleBoxTexture` appear only in `{ui_theme.gd, ui_kit.gd} ∪ allowlist`.
- Day-tick gate unchanged (≤ 75 ms at the measured fleet count); no
  per-frame CPU in the sea layer.
- §4.7.18 `ui_strings` inventory finalized (or amended to "no keys
  beyond §4.7.18-staged set" if sweep needed none).
- Acceptance record fills this doc's W6 block (suites, checks, group-13
  probe counts, user review outcome); `AGENTS.md` gains the Phase-10
  line and the new parking lot (decision-10 future work + §7 below).

---

## 5. Tests (no overkill)

- **Theme pins** (`test_ui_theme`): stylebox colors == `palette.gd`
  constants; button min-height 40; scrollbar thickness 8; focus ring
  `ACCENT`; radius/pad 4/8 tooltips — theme values, never rendering.
- **Kit atoms** (`test_ui_kit`): heights (32/40), variations exist,
  i18n key resolution zh/en, `value_bar` tier mapping at fixed
  thresholds, icon id → texture resolution.
- **Art group 13** (validator): everything in decision 7; negative
  probes (off-palette pixel, hand-edited PNG, broken transform
  relation, out-of-band footprint, invalid shore code, seam-rule
  violation) go red.
- **Token mapping**: 16 hulls × 8 dirs × 9 owners all resolve; owner
  set == nations ∪ {player, neutral, pirate} (== 6 + 3, review-verified);
  heading8→dir table covers every bucket.
- **Terrain wiring**: every legend kind + variant resolves; variant
  hash pinned (fixed cells → fixed ids: `(x·31+y·17)%n`); shore overlay
  maps every edge code; water layer resolves flat tiles + pattern +
  shader.
- **Arrow field**: deterministic sampling against a fixture decode;
  wind uses the month's `prevailing_for`; `W`/`C` state default off;
  month rollover re-samples.
- **World markers**: every discovery category resolves (4 categories
  covering all 30 sites); discovered-only visibility (undiscovered
  never renders).
- **Portrait composer**: fixed `appearance` dict → fixed part list;
  every distinct appearance value in `captains.json` resolves (4×4×4×4
  sets review-verified); override-wins fixture.
- **Prompt manifest**: covers exactly 24 legend captains + 4 named
  pirates + 30 discoveries; canvas dimensions asserted per class.
- **Motion**: duration constants == §4.7.17 tables; `UiMotion` off →
  zero pending tweens + water scroll frozen; battle FX sequencer in
  instant mode produces no timers (logs byte-identical).
- **Sweep guard** (audit test): scan `scenes/` + `scripts/` +
  `autoload/` for `add_theme_stylebox_override`/`StyleBoxFlat`/
  `StyleBoxTexture` outside `{ui_theme.gd, ui_kit.gd} ∪ allowlist`.
- **One gallery headless boot**: theme applied, zero errors;
  direct-boot pattern documented.

---

## 6. Risks & fallbacks

- **16 hull silhouettes at 32×32** — sail-plan differentiation + kept
  letter overlay carries identification.
- **Node engine dependency** — node pinned v24.16.0, zero npm deps,
  double-run byte-identity fixture; vendored MIT engine adopted by
  re-extraction, never live; fallback = Python hand-ports (quality risk
  accepted).
- **Shore overlay pipeline** — `world_shore.png` joins the
  never-hand-edit family alongside `world.png`; one extra TileMap layer
  is trivial for the frame budget.
- **Palette blocks are the biggest W1 task** — doc-first pinning of
  every block hex; group 13 enforces membership so drift cannot enter
  silently. The append-only restructure (correction 9) keeps the
  repo-wide existing-name references intact.
- **Style drift across ~1 366 assets** — four-layer defense (decision
  9); counts no longer enforce flatness, so the contact-sheet review
  carries the consistency load (user veto on the W3 gate).
- **Nearest-neighbor imports in headless CI** — `.import` files
  committed via a single master-run `godot --headless --import` pass at
  the W3 gate; import step verified there.
- **Parallel-worktree collisions** — bounded by the execution protocol:
  single-owner matrix, `build_ui_art.py` / `validate_data.py` /
  `ui_strings.json` each with one writer for the phase or wave, key
  escalations through the master ledger.
- **Sweep scale** (484 sites / 26 files, correction 7) — bounded by
  wave gates and the audit test; the count itself is never pinned, so
  drift cannot red a gate.
- **Toast ownership is distributed** (correction 8) — the HUD funnel +
  kit-atom adoption covers all sites; fade constants pinned once.
- **zh/en label fit** on 40px buttons — buttons size to content;
  locale-parity discipline; `test_ui_kit` asserts both locales resolve.
- **Combat visual drift** — the sweep runs after Phase-9 W6
  acceptance (complete); battle suites + instant-mode log byte-identity
  gate it.

---

## 7. Parking lot (future work)

Officer portraits (96); tier-3 non-legend captain promotion (**61**
ids → manifest edit); runtime ComfyUI-style generation +
`user://portraits/` cache + offline-lock amendment (own future plan);
discovery reveal pics ×30 (model pass via `art_prompts.json`);
sail-state hull variants; named-pirate ship variant; world-map wake
(**claimed 2026-11-07** — delivered as the PixelLab waterline VFX
family's BACK sheet, `80-*` §4.8 2026-11-07 amendment; **revised same
day** — the family regenerates as one north sheet per ship size
{32,48,64} under the top-down hull token amendment, `80-*` §4.8);
animations beyond the pinned set.

---

## Appendix — `build_ui_art.py` inventory (~1 371 PNGs + 1 raster)

> Counts reconciled at the 2026-11-04 review (corrections 4/5): 7 role
> badges, and chrome tiles and the sheets assembled from them are
> counted separately. Group 13's inventory check reconciles the exact
> count from the manifest at machine scope, so the approximate total
> below is informational only.

### A.1 UI chrome, 16×16 tiles → 48×48 nine-patch sheets (15 tiles → 5 sheets)

| Set | Tiles | Consumed by |
|---|---|---|
| `panel` | corner / edge / fill | frames, PanelContainer |
| `button` | corner / edge / fill | Button normal |
| `button_focus` | corner / edge / fill | focus/hover (ACCENT border) |
| `field` | corner / edge / fill | LineEdit/TextEdit inset |
| `bar` | left cap / right cap / line | value_bar frame (H) |

### A.2 Semantic icons, 32×32 (129)

All icon-class assets render 1× (32) inline — flush full-cell in 32px
rows; 2× (64) allowed for hero contexts (nearest only). Semantic marks
(trend, formation, weather, arrows) authored sparse.

- **HUD resources (5):** `coin`, `crew`, `provisions`, `morale`,
  `durability`
- **Nav/weather (5 + 16 dirs):** `compass`, `calm`, `fair`, `strong`,
  `storm`; directional sets `wind_arrow_{n..nw}` ×8 (`TEXT`) +
  `current_arrow_{n..nw}` ×8 (`COAST_SEA`) — 2 authored maps each
  (`n`, `ne`), lossless derivation
- **Battle (8):** `cannon`, `shot_round`, `shot_chain`,
  `shot_armor_piercing`, `shot_grape`, `hook`, `ram`,
  `surrender_flag`
- **Economy/port (4):** `chest`, `scroll`, `hammer`, `bell`
- **Meta/status (5):** `anchor`, `hourglass`, `save`, `skull`, `crown`
- **Nation flags (7):** 6 nations (portugal, spain, england, holland,
  ottoman, italy) + neutral, from `nations.json`
- **Trading goods (40):** `good_{id}` per `goods.json` id — food 11,
  material 14, textile 6, luxury 9; category motif families
  (organic / raw / bolt / faceted), category-color mapping W1-pinned
- **Equipment (24):** `eq_{id}` per `equipment.json` id — weapons,
  armor, sails, figureheads
- **NPC role badges (7):** `role_{trader|coaster|courier|patrol|
  privateer|pirate|hunter}` — the exact 7 roles in `captains.json`
  (correction 5)
- **Formations (4):** `formation_{line_ahead|column|screen|swarm}`
- **Meta/trophy (1):** `trophy` (consumed by S13's commendation dialog
  — W4-A, correction 4)
- **Market trend/event (3):** `trend_up`, `trend_down`,
  `event_demand` (W1 pins: up `GOOD`, down `BAD`, event `ACCENT`)

Total: 5 + 5 + 16 + 8 + 4 + 5 + 7 + 40 + 24 + 7 + 4 + 1 + 3 = **129**.

### A.3 Tokens, 32×32, directional (1158)

- **Hulls (1152)**: `hull_{ship_type_id}_{owner}_{dir}.png` —
  16 hulls × 9 owners (player white/black-outline | 6 nations |
  neutral | pirate) × 8 dirs (`n, ne, e, se, s, sw, w, nw`).
  **Authored: 2 top-down maps per hull (`n`, `ne`)**; the tool derives
  the other six by lossless 90° rotations/mirrors and bakes owner tints
  via remap tables from the hull palette block. **Footprint by
  `ship_types.tier`** (partition review-verified): tier 1 (latin,
  sloop, galiot, pinnace) ≈ 14–18 px long; tier 2 (caravel, galley,
  brigantine, fluyt, junk, dhow, caravela_redonda, xebec) ≈ 20–26 px;
  tier 3 (nao, carrack, galleon, galleass) ≈ 26–30 px (exact band
  values pinned at W1; validator checks the long axis). **Hull letters
  stay** as overlay badges (rule pinned in §4.8). Consumers: S10 units
  ← `heading8`; S3 player fleet ← 8-dir movement; lists/rosters ←
  static `n`. World-map NPC fleets stay colored squares; minimap dots
  unchanged.
- **Facilities (6)**: `facility_market`, `facility_shipyard`,
  `facility_tavern`, `facility_inn`, `facility_guild`,
  `facility_palace` — static; covers every building in `ports.json`
  (review-verified; `equipment_stock` is a capability, not a building).

### A.4 World markers, 32×32 (6)

`marker_wreck`, `marker_treasure`, and `marker_discovery_{natural|
ruins|relic|creature}` (categories cover all 30 discoveries: natural
15, ruins 10, relic 4, creature 1 — review-verified). Static grid
markers like ports; discovery markers discovered-only.

### A.5 Terrain tiles, 32×32 (13) + water pattern (1)

- **Static kinds (11):** `terrain_land_{0..3}`, `terrain_reef_0`,
  `terrain_polar_ice_{0..1}` — dithered within the terrain block,
  variants picked by cell hash `(x·31+y·17)%n`; seam rules per
  decision 9.1.
- **Water kinds (2):** `terrain_sea_0`, `terrain_coastal_sea_0` —
  flat fills on the shader-animated water layer.
- **Port markers (7):** `terrain_port_{owner}` — harbor silhouette
  × 6 nations + neutral.
- **Water pattern (1):** `sea_pattern.png` 64×64 — two-level
  torus-safe dither mask (four quadrants = the authored sea-variant
  maps).
- Legend (`data/map_legend.json`) keeps owning kind semantics;
  chart + minimap stay flat raster (pinned).

### A.6 Shore-edge strips, 32×32 (8)

`shore_{n,ne,e,se,s,sw,w,nw}` — water-side foam strips; authored
`n` + corner, the rest derived losslessly. Consumed by the
`map_loader` overlay layer from `data/maps/world_shore.png`
(generated by `tools/build_shore.py` from `world.png`; W3-C owned;
edge codes only on water cells adjacent to land/reef/ice;
byte-identical rebuild; never hand-edited — same family rule as
`world.png`).

### A.7 FX frames (11) & portrait part sheets (25)

- `fx_cannonball` 16×16 ×1 (tweened; all four shot types reuse);
  `fx_splash_{0..3}` 32×32; `fx_impact_{0..2}` 32×32;
  `fx_smoke_{0..2}` 16×16. Instant mode renders frame 0.
- Portrait parts, 72×96 RGBA layers: `pp_base` ×1;
  `pp_face_{lean|round|scarred|weathered}` ×4;
  `pp_beard_{clean|forked|full|stubble}` ×4;
  `pp_hair_{black|brown|grey_streaked|sun_bleached}` ×4;
  `pp_eyes_{dark|grey|hazel|pale_blue}` ×4;
  `pp_cloth_{7 roles + player}` ×8. Portrait palette block only;
  composed at runtime by `portrait_composer.gd`; override wins.

All files: indexed PNG, nearest-neighbor import, group-13 validated;
ids are the contract — kit/scenes reference ids, the tool owns pixels.

**Inventory total: 15 chrome tiles + 5 sheets + 129 icons + 1 158
tokens + 6 markers + 13 terrain + 1 pattern + 8 shore + 11 FX + 25
portrait sheets + 1 raster (`world_shore.png`).**

---

## Status log

_Waves ledger entries are appended here by the master as merges land
(Phase-9 convention)._

### W1 — docs (2026-11-04) — COMPLETE

- **Master pre-wave adjudication** (`6bb60f5`): the Phase-10 pin of §4.9
  (theme & kit) collided with the live tree's §4.9 (Phase-7 W3/W4 symbol
  contracts). Resolved in the owning doc: contracts renumbered
  **§4.9 → §4.16** in `80-*` (heading + §1 cite) with a full reference
  sweep (`docs/60-*` 1 hit; code comments in `game_state.gd`,
  `allegiance.gd`, `shipyard_engine.gd`, `npc_fleets.gd`, `npc_intel.gd`,
  `sailing_sim.gd`, `market_screen.gd`, `test_allegiance/test_shipyard/
  test_market_screen/test_trade`). `§4.9` is now unambiguous.
- **A** `phase10/w1-a-80` @ `a65344f`, merged → validator exit 0.
  `80-*`: §4.7 toast-fade amendment; **§4.7.17** timing tables (final
  pins: flight 300 / splash 400 / impact 300 / smoke 500 / sink 600 /
  event pause 150 ms; toast 100/150 ms; press flash 100 ms; sea period
  800 ms, darkening ×0.82); **§4.7.18** reserved; **§4.8 rewrite**
  (generated-art rule, style guide, budgets 12/20/25 caps, dither ≤ 30%,
  seam rules, heading8→dir table, footprint bands 14–18 / 20–26 / 26–30,
  icon display rules, LOD pins, S3 arrow-field spec); **§4.9 theme & kit**
  (every stylebox constant, state matrix, six atom contracts, allowlist
  starts empty). Palette blocks pinned: terrain 19, icon 22, hull 33
  distinct (7 shared steps + 9 owner triples), fx 9, portrait 24.
  Adjudications (master-accepted): (a) S3 `C`-key shadow convention for
  the current-arrow field (field on ⇒ `C` toggles the field, intel `C`
  shadowed; mirrors the S17 chart shadow); (b) block membership is
  **per-class** — group 13 checks a sprite only against its class block
  (value reuse across blocks allowed); (c) terrain block carries the 6
  nation hexes + `PORT_NEUTRAL` + `PORT_INK` + `FOAM` (terrain-class
  sprites need them); (d) goods category→color map pinned food `GOOD` /
  material `ACCENT_LO` / textile `COAST_SEA` / luxury `ACCENT`; (e) class
  assignments: chrome tiles → `icon` block, facility tokens → `hull`
  block; (f) the Phase-1 "24×24 ship squares" bullet retired (player
  token becomes the 8-dir sprite; NPC squares persist via §4.5.2).
- **B** `phase10/w1-b-schema` @ `8b744d1`, merged → validator exit 0.
  `10-*`: §6.3 generated-artifact family amendment (`.import` scope split:
  map rasters stay import-free data — decision 5 verbatim); **§6.6**
  `world_shore.png` spec (indices 1–8 = `n…nw`, priority = compass order,
  wrap-aware, land/reef/ice ⇒ 0); §8 preamble group-13 row; **§8.8
  group-13 normative spec** — 10 checks + 6 negative probes, counts
  reconciled at machine scope (never hard-pinned). Adjudications:
  token class = 1 152 hulls **plus** 6 facility tokens; terrain class =
  13 tiles + `sea_pattern.png`; §6.6 heading carries the `*(Phase 10)*`
  suffix convention.
- **C** `phase10/w1-c-arch` @ `00d412e`, merged → validator exit 0.
  `90-*`: §1 Phase-10 sentence, §4 tree (10 new entries incl.
  `ui_motion.gd`), **§9.2** terrain-art/overlay + `--import` ingestion +
  portrait ladder + `project.godot`-unchanged notes. `00-*`: §5 Phase-10
  row + out-of-scope clarification; §12 glossary +6 terms.
  `LICENSE-NOTES.md`: YoYoPixel MIT entry (© 2026 SbName, no URL).
  Master follow-up on `main`: §8 doc map gained the missing Phase-9 row
  plus the Phase-10 row.
- **Gate:** cross-doc refs resolve (§4.7.17/§4.7.18/§4.8/§4.9/§4.16,
  §6.6, §8.8, §9.2, §5 row, glossary rows all verified present);
  `validate_data.py` exit 0 after every merge. No code touched.

### W2 — theme + kit + gallery + engine bring-up (2026-11-04) — COMPLETE

- **A** `phase10/w2-a-palette` @ `8b4edb9`, merged → validator 0 +
  `test_chart`/`test_demo_loop` GREEN. `scripts/palette.gd` append-only
  (223 insertions, 0 deletions): +96 block constants — terrain 13, icon
  15, hull 34 (7 shared + 9 owner ramps × 3), fx 9, portrait 25
  (`PORTRAIT_INK` prefix = ledger adjudication; ramp rule HI ×1.25 /
  LO ×0.72 in the block header). Master-pinned constant-name scheme
  (A/B/C prompts carried it): `HULL_{owner}[_HI|_LO]`,
  `CLOTH_*`/`SKIN_*`/`HAIR_*`/`EYE_*` per §4.8 tables.
- **B** `phase10/w2-b-theme` @ `76bb1b5`, merged → validator 0 +
  `test_ui_theme` (79 checks)/`test_demo_loop`/`test_creation` GREEN.
  `scripts/ui_theme.gd` `UiTheme.build_theme()` — full §4.9 table +
  state matrix; variations `Primary`/`Danger`/`Quiet` (Button),
  `Dim` (Label); `title_screen._ready()` applies to the root window
  (guarded `get_window()`). Adjudications: (1) `StyleBox.min_size`
  does not exist in Godot 4.7 — scrollbar thickness/min-length ride
  **stylebox content margins** (VScrollBar measures exactly (8, 24),
  suite-pinned); (2) the button 40px floor is control-level
  (`custom_minimum_size.y`, kit atom + title already set it) — theme
  pads 8/8; absorbing 40px into margins would render ~63px buttons;
  (3) variation reads are control-level; suites assert via
  `get_type_variation_base`; (4) only B's own two `.uid` sidecars
  committed (scan spillover discarded); (5) title uses the repo's
  `UiThemeLib` preload convention.
- **C** `phase10/w2-c-kit` @ `500e741`, merged → validator 0 +
  `test_ui_kit` (54 checks)/`test_ui_theme`/`test_demo_loop` GREEN.
  `scripts/ui_motion.gd` (`UiMotion.enabled` default on; `dur`/`fade`/
  `freeze_shader`/`run_shader`), `scripts/ui_kit.gd` (six atoms +
  `toast` + icon registry, `meta["body"]`/`meta["cells"]` conventions),
  `tools/widget_gallery.tscn` (master adjudication: gallery lives in
  `tools/` beside the harness scenes — §4 tree line to be added at the
  W6 doc finalization), `ui.kit.*` keys ×11 (sole-writer rule held;
  gallery reuses existing `ui.*` keys per §4.7.18), `test_ui_kit`.
  Adjudications: thresholds stay doc-owned in callers (supply 10/3
  §4.6.1, morale 40/20 §4.8) and are pinned through `UiKit.auto_tier`;
  toast max-1 is a synchronous `free()` with `is_instance_valid`
  guards; fresh-worktree boots use `preload` consts, `class_name`
  declarations kept for the W4+ contract.
- **D** `phase10/w2-d-engine` @ `c1d9e89`, merged → validator 0 +
  `tools/yoyopixel/fixture_check.py` GREEN (5 fixtures, run1 == run2 ==
  committed, node v24.16.0). Vendored `pixelart-skill.md` + `LICENSE` +
  authored `VENDORED.md`/`render.md`; `render.js` = verbatim
  transcription of engine-v3.html's pixel-math (`PB`, `blit/blitA`,
  `shade`, 15 `MAT_SHADERS`, `renderSprite` 3-pass) + first-party PNG
  encoder (stdlib zlib; indexed PLTE+tRNS per-entry alpha + RGBA).
  Declared deviations (all ledger-recorded, all documented in-tree):
  browser canvas writer → stdlib PNG encoder; material iteration
  **sorted** (byte-identity requires it; verified on a permuted
  declaration); demo `SPRITES`/scene builders not vendored;
  `background` post-fills transparent pixels; string-map mode renders
  flat exact colors (chrome/marks usage).
- **Wave gate:** full `tools/run_tests.py` **56/56 GREEN (284.1s)**;
  `validate_data.py` exit 0 (groups 1–12); zh/en parity green (group 2).
  Merge order A → B → C → D held; W3 launches next (art pass).

### W3 — art pass (2026-11-04) — COMPLETE (user review: APPROVED)

- **A** `phase10/w3-a-icons` @ `45db66b`, merged → validator 0 (groups
  1–13 staged) + `test_ui_theme`/`test_ui_kit`/`test_demo_loop` GREEN.
  Chrome 15 + icons 129 manifests (19 files; committed generator
  `gen_icons.py`, byte-stable `--check`); **validator group 13** (§8.8
  items 1–10 + 8 verified-red negative probes; staged activation);
  nine-patch `StyleBoxTexture` variants in `ui_theme.gd`
  (`use_textures := true` default, flat fallback; `test_ui_theme` pinned
  to `build_theme(false)`). Adjudications: icons authored as
  **string-maps** (engine template noise/shading provably breaks §8.8.3–4
  membership+budget — a template-mode switch needs a §8.8 doc amendment
  first); goods sprites `good_{id}` / equipment raw `eq_*` ids; focus
  sheet = ACCENT ring, transparent fill; Primary/Danger/Quiet stay flat
  in texture mode; footprint bands checked on cardinals; England cross =
  FLAG_SPAIN red, ottoman field = pinned purple.
- **B** `phase10/w3-b-hulls` @ `89ecd5b`, merged → full build + `--check`
  byte-identity ×3; footprints t1 17 / t2 25 / t3 29 (in-band).
  `build_ui_art.py` governor (render via render.js, node ==v24.16.0
  enforced, 8-dir derivations, 9-owner wood-step remaps, 1px HULL_INK
  outline, seam-ring verify, nine-patch assembly incl. the pinned bar
  layout, footprint audit, `--check`, `--contact-sheet` with a first-party
  3×5 font) + rig fragments (`rig.json`) + 16 hulls × 2 authored maps +
  6 facility tokens. Adjudications: authored maps are literal string-maps
  (remap contract needs exact WOOD_* hexes; fragment vocabulary pinned as
  data in rig.json); footprint semantics = n-token bbox max (ne is
  canvas-fit only); beam ~33–40% for galley family; contact-sheet
  capability governor-owned, artifact master-committed; `--import`
  AI-ingestion deferred (future work, docstring note).
- **C** `phase10/w3-c-terrain` @ `23148df`, merged → `build_shore.py
  --check` ×2 byte-identical; `world_shore.png` committed (82 139 coded
  cells; full-grid naive §6.6 recompute = 0/9 331 200 mismatches; Lisbon
  berth = `e`). Terrain 16 (4 land + reef + 2 ice + 2 water + 7 ports) +
  `sea_pattern.png` + shore 8 (2 authored + 6 derive); torus dither
  lattices (HI (3x+5y+p)%16, LO (5x+3y+7+p)%16), shared byte-identical
  rings, densities 6.2–11.8% ≤ 30%.
- **D** `phase10/w3-d-fx-portraits` @ `e8a270f`, merged → compose_check
  ALL GREEN (36 declarations render, pixel-level block purity, 4 legend
  busts compose). FX 11 (string-maps, exact fx-block hexes), portrait
  sheets 25 (72×96 RGBA, `anchors.json` + generator + composer stack
  **base→face→eyes→beard→hair→cloth**), `art_prompts.json` (24 legend +
  30 discoveries; the 4 named pirates ⊆ the 24). W4-D composer
  contracts pinned: beards render `HAIR_BROWN` → composer palette-swaps
  to the captain's hair hex; patrol/privateer sash = CLOTH_ACCENT cells
  → composer re-tints to the owner nation's CLOTH hex; paths
  `assets/ui/fx/`, `assets/ui/portraits/`.
- **Master merge reconciliations** (`06e4627`, post-C commit, `5cde265`):
  governor derives from **RAW** pixels (outline-before-derive broke
  §8.8.5 relations via staging re-reads); bar tile names `bar_left/
  right/line`; derive key alias `from`/`base`; validator aux-doc skip
  (`rig.json`/`hulls.json`/`anchors.json`) + recursive manifest glob +
  registry-shape hull grid (docs + pinned derive ops + synthetic token
  decls for artifact checks); derive-only decls skip render.js and
  manifest mode/size; `sea_pattern` mask-hex exemption (`class:
  terrain_pattern`, `#ffffff`/`#000000`); torus proxy = uniform dither
  density (exact-tile wrap; edge-equality not required); art_prompts
  per-class arrays accepted; `--check` compares PNGs only; .uid
  normalization; `.gitignore` for non-game-texture `.import` spillover.
  Note: the C-reconciliation commit (`eaeb432`, `git add -A`) swept the
  mid-wave `assets/ui` build into history early — the artifacts were the
  verified byte-identical build output; the D-class PNGs landed in the
  gate commit.
- **Gate:** full build = **1 368 PNGs**, `--check` byte-identical double
  run; validator **groups 1–13 exit 0** (all classes live: inventories,
  budgets, membership, transform relations, footprints, seams, shore
  raster, prompts); `godot --headless --import` pass committed the
  `assets/ui/*.import` sidecars; **user contact-sheet review: APPROVED**
  (no veto items). Full `tools/run_tests.py` **56/56 GREEN (284.1s)**
  with textures live. W4 (sweep, non-combat) launches next.

### W4 — sweep, non-combat (2026-11-04) — COMPLETE

- **A** `phase10/w4-a-port` @ `0868dc2` + follow-ups `7ef828d`/`d9bf3d9`
  (master), merged → 179 sites → 0 across 8 files; icons (`good_*`,
  trends, `eq_*`, facility tokens, `trophy`, `role_*` badges, `scroll`),
  atoms (frame/button kinds/footer/value_bar+auto_tier/toast), 21
  targeted suites GREEN. **Master adjudications:** (1) doc-pinned
  tier/accent TEXT colors ride NEW theme Label variations `Accent`/
  `Warn`/`Good`/`Bad` + `CardStatus`/`CardStatusGood`/`CardStatusDim`
  (12px §4.8.1 status line) — `theme_type_variation` is a plain
  property, gate-compliant; sites flipped by A's continuation.
- **B** `phase10/w4-b-shared` @ `51a6713` + follow-up `cb8de9f`, merged
  → 115 sites → 0 across 13 files; HUD resource icons, **wind/current
  arrow sprite swap** (null ⇒ drawn fallback), **toast fade 100/150 ms
  at the `toast_text` funnel** via UiMotion, fleet rows `hull_*_n`
  tokens, dialogs/ending/gameover kit; S19 restyled, **no new rows**;
  17 suites GREEN. Follow-up: `dialog_box` consumes W4-C's optional
  `icon_id` (32px beside the message; inert without). Escalation
  accepted: poster/sighting surfaces live in A/C/D files; officers
  carry no role (decision 10 parking lot).
- **C** `phase10/w4-c-world` @ `abe7fea` + follow-up `85c086b`, merged
  → map_loader terrain art (data-driven legend kinds, variant hash
  `(x·31+y·17)%n`, wrapped), **dedicated water layer** +
  `sea_water.gdshader` (`u_period` 0.8 s, `u_darken` 0.82, `u_motion`
  gate, TIME-driven — zero per-frame CPU) in shared `water_layer.gd`
  (the S10 reuse seam), **shore overlay** from `world_shore.png`
  (data-byte decode, frame-2 warm-up keeps the 3 000 ms boot budget),
  port markers → `terrain_port_{owner}` sprites, S3 directional player
  token (`hull_{type}_player_{dir}`), **arrow_field.gd** (pure; §4.8.6
  table; stride-4 lattice) + W/C keys, world markers discovered-only,
  hail portrait slot (guarded), chart chrome sweep. New
  `tools/test_terrain_art` (98 → **109 checks**). **Master doc
  amendment:** §4.8.10's original C-key pin made the current field
  unreachable — amended (C toggles current while either field is on;
  full matrix suite-pinned). Marker sprites: **the A.4 row was
  assigned to no W3 slot** — master follow-up `30a9173` authored the 6
  manifests (terrain block, ≤ 5 colors), governor `CLASS_DIRS` +
  contact-sheet walk gained the class; `assets/ui/markers/` committed
  (1 374 files byte-identical).
- **D** `phase10/w4-d-title-ui` @ `bc45ada`, merged → **portrait
  composer** (`compose_image`/`portrait_texture`, override-wins ladder,
  HAIR_BROWN→hair + sash→nation swaps, deterministic cache; 48-check
  suite incl. the 4×4×4×4 domain + override fixture) + **texture
  registry bootstrap** (`texture_registry.gd`, 1 348 ids, called from
  `title_screen._ready()`) + title/ui sweep (81 sites → 0) + portrait
  slots on the character card/dossier. Adjudications: per-screen font
  sizes retire to theme defaults (§4.9 rule); Godot 4 container
  separations are theme constants only (`theme_override_constants`
  channel).
- **Gate:** full `tools/run_tests.py` — first run 57/58 with one flaky
  red, **immediate re-run 58/58 GREEN (294.1s)**; validator exit 0
  (groups 1–13); **day-tick 74 ms ≤ 75** (PROFILE day_tick_avg_ms);
  styling grep: only `ui_theme.gd`/`ui_kit.gd` + the three W5 combat
  files (their sweep is W5's scope); allowlist still empty. `build_ui_art
  --check` byte-identical at 1 374 files. W5 (combat + FX) launches
  next.

### W5 — combat + FX (2026-11-04) — COMPLETE

- **A** `phase10/w5-a-battle` @ `fc810e0` + follow-up `39d5009`, merged
  → 26 sites → 0; the **FX layer** (`battle_fx_layer.gd` —
  timer/tween-free `_process` sequencer, camera-free world-px drawing,
  read-only drain of the existing sim stream): volley smoke 500 →
  parabolic flight 300 (`FLIGHT_PEAK_PX = 24.0`, proposal constant) →
  impact 300 (`damage > 0`) else splash 400 → sink fade 600; ram =
  impact→smoke→sinks; moves ride the 150 ms pause; per-event pause
  150 ms; **instant ⇒ every duration 0, queue never fills, no timers
  (source-audited), logs byte-identical** (animate-vs-instant fixture
  pin). Battle sea = the shared `WaterLayer` (one cached S3/S10
  material; the sea gate is `UiMotion` only — ledgered). Hull tokens
  `hull_{type}_{owner}_{dir}` via the §4.8.6 table (player white
  livery / pirate / nation / neutral), letter badges runtime overlays,
  placeholder fallback; `formation_*` icons; after-action portrait via
  the composer (null ⇒ text-only). `test_battle_screen` 201 → **230
  checks**. Follow-up: the escalated [fit] overflow was a measurement
  error (no live defect) — the bar's zero-slack risk removed instead
  (4–9px slack; forced-40px scenario exact-fit).
- **B** `phase10/w5-b-sandbox` @ `cf85102`, merged → 58 sites → 0
  (sandbox 48, duel 10; zero-write audit intact, 130 checks); **zero
  suite edits needed**. Delivered **`tools/test_ui_styling_audit`**
  (§5 sweep guard: the three tokens across scenes/scripts/autoload +
  `.tscn` StyleBox sub_resources / `theme_override_styles/`, allowed =
  {ui_theme.gd, ui_kit.gd} ∪ the empty §4.9 allowlist, walk-integrity
  checks, staged-expectation docstring) — **fully GREEN on main** after
  A's merge: the §4.9 rule is machine-enforced, allowlist empty.
  Ledger note: a pre-existing benign SCRIPT ERROR at `test_duel.gd:778`
  reproduces on the pristine base (untouched modules, suite exits 0).
- **Gate:** battle family (4 suites) + `test_tournament` GREEN;
  full `tools/run_tests.py` **59/59 GREEN (294.1s)** incl. the audit;
  validator exit 0 (groups 1–13). Composer-suite marker pin updated on
  main (markers registered since the W3 follow-up — W5-A escalation).
  Markers `.import` sidecars committed (master import pass).

### W6 — acceptance (2026-11-04) — COMPLETE

- Full `tools/run_tests.py`: **59/59 GREEN** (58 + `test_ui_styling_audit`;
  294.1s wall). `python3 tools/validate_data.py`: **exit 0, groups
  1–13**.
- Byte-identical rebuild: `build_ui_art.py --check` — **1 374 files,
  zero diffs** (double run); `build_shore.py --check` — byte-identical
  (sha256 `ffac0c19…`); **no hand-authored PNG under `assets/ui/`** (the
  rebuild-diff clean is the detector, §8.8 item 2).
- Grep bounds: `test_ui_styling_audit` GREEN — `add_theme_stylebox_
  override` / `StyleBoxFlat` / `StyleBoxTexture` appear only in
  {`ui_theme.gd`, `ui_kit.gd`}; the §4.9 allowlist remains **empty**.
- Day-tick gate: **72 ms avg ≤ 75** (PROFILE day_tick_avg_ms; worst
  frame 85 ms) at the measured fleet count; no per-frame CPU in the sea
  layer (TIME-driven shader, W4-C).
- §4.7.18 finalized: exactly the 11 W2-staged `ui.kit.gallery.*` keys;
  the sweep needed none beyond them (zero escalations).
- User contact-sheet review (W3 gate): **APPROVED**, no veto items.
- AGENTS.md gains the Phase-10 line + the new parking lot (§7 of this
  doc: officer portraits (96), tier-3 promotion (61), the runtime
  ComfyUI-style generation plan, discovery reveal pics ×30 (model pass
  via `art_prompts.json`), sail-state hull variants, named-pirate ship
  variant, world-map wake, animations beyond the pinned set).

### W7 — PixelLab chrome tilesets amendment (2026-11-08) — COMPLETE

- User-direction amendment (80-* §4.8/§4.9 amended first, the doc-first
  rule): the chrome families' art source moves to the PixelLab tileset
  API — two pro-mode 16px Wang corner tilesets (`frame` = parchment
  panel plate, seed 20261108; `button` = chestnut leather plate, seed
  20261109), the lower material the authoring-only green chroma key;
  the authored string maps remain the deterministic fallback; `bar`
  stays authored.
- Generation: `pixellab_pass.py --chrome run` — vendored trios
  `tileset_chrome_frame_b95672e0…` / `tileset_chrome_button_dc0c6ad6…`
  (16 tiles each, name↔corners bits verified at import).
- Ingest: `build_ui_art --import-chrome-pixellab` — green-key
  (g ≥ r+32 ∧ g ≥ b+32) → 18 derived singles (panel/field from frame;
  button/hover/pressed/focus from button; pressed = 180° rim +
  ×0.80, hover = +18% lift, field = inverted rim + ×0.62 recess,
  focus = ACCENT silhouette ring), seven sheets (self-verified
  pixel-exact), the committed `chrome{}` ledger section; import
  idempotent (ledger byte-identical across runs).
- Runtime: `ui_theme.gd` gains the hover/pressed sheet slots (the
  2026-11-04 dimming ladder = the missing-sheet fallback), the
  §4.9 tile-mode amendment (middle regions AXIS_STRETCH_MODE_TILE),
  and the ink seam (Label/Dim/LineEdit → INK_WARM, Accent/Warn →
  ACCENT_LO, Button stays TEXT, `surface_fill()` → PARCH);
  `palette.gd` appends PARCH/PARCH_HI/PARCH_LO/INK_WARM (append-only).
- Gates: validator **groups 1–13 OK** (chrome inventory 15 authored /
  21 shipped, ledger synthesis = the coast precedent, seam waiver for
  the keyed Wang tiles, g13 probes 8/8); `build_ui_art --check`
  **271 files byte-identical** (double run); full
  `tools/run_tests.py` **62/62 GREEN** (432.1s, -j4) incl.
  `test_ui_theme` (amended to the keyed-geometry pins), `test_ui_kit`,
  `test_ui_styling_audit` (allowlist still empty).
- Studio: `chrome_frame` / `chrome_button` cards (the coast-card
  pattern) — re-roll in-process with the style clause as the only
  prompt edit, staged in the gitignored cache, accept = trio swap +
  re-import gated on the fresh ledger.
- Pending user review: the contact sheet (regenerated) + the studio
  card previews; a re-roll of either tileset is a card action, not a
  code change.

### W7.1 — the light click plate (2026-11-08 evening) — COMPLETE

- User direction (black-on-chestnut contrast): the button families
  re-source to the THIRD tileset `click` (light parchment click plate,
  double brass line + rosettes, seed 20261110, the same envelope/green
  key) and the chestnut leather set is RETIRED (trio `git rm`'d,
  `chrome_button` studio card removed; two live tilesets: frame +
  click). Root cause the revision supersedes: card-style Buttons carry
  child Labels, which resolve the Label ink (dark) on the dark
  chestnut plate — on the light plate that ink is correct by design.
- Derivations unchanged (base / lift / press / ring from `click`); the
  file ids, sheets and runtime paths unchanged. Tones: face mean
  `#ddbd90` (ink `INK_WARM` ≈ 7.5:1), rim `#b67625`, pressed ×0.80,
  hover +18%, focus ring `ACCENT`.
- §4.9: the Button font states ride the ink seam (`INK_WARM` texture /
  cream flat; disabled = ink @ 0.55). `test_ui_theme` amended to the
  new pins.
- Gates: validator **groups 1–13 OK**; `build_ui_art --check`
  **271 files byte-identical** (double run); full
  `tools/run_tests.py` **62/62 GREEN** (442.1s, -j4).
- Studio: `chrome_click` card replaces `chrome_button` (registry,
  chain, mock, README).
