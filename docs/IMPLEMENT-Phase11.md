# IMPLEMENT — Phase 11: The studio layout editor (live bridge, data-driven UI layout)

> Source plan: `.opencode` session plan of 2026-11-09 (authored with the
> user; the five design decisions were user-locked the same day — live
> bridge, all port screens, every control, assign-existing-sheets only,
> 32 px snap + anchor flags). Doc owners: `80-*` §4.8.9, `90-*` §5.7,
> `10-*` §4.23/§8.9.

## 1. Goal

A visual, live UI-layout editor in the SailAge Model Studio: the game
runs a debug-gated WebSocket bridge, the studio shows the real screen
(viewport frames) with draggable element boxes snapped to the 32 px
chrome-tile grid, and Commit serializes the session into
`data/ui_layout.json` behind an in-process validator gate. Tileset
changes per element = assignment among the 7 assignable nine-patch
sheets. Defaults stay code-pinned (the override file ships `{}`), so
every existing layout pin keeps holding byte-identically.

## 2. Locked decisions (user, 2026-11-09)

1. **Live bridge** over a snapshot-file loop.
2. **Pilot scope: all 8 port screens** (`port`, `market`, `inn`,
   `guild`, `provisions`, `palace`, `tavern`, `shipyard`).
3. **Every control** gets a stable id (dynamic children use
   data-derived segments).
4. **Tileset change = assignment only** among the 7 assignable sheets;
   new tileset art keeps flowing through the existing chrome cards.
5. **32 px snap + anchor flags**; 16 px margins quantize to tiles;
   bars use anchor semantics (1080 is not tile-integral).

Standing rules the phase must not break: single writer (the game never
writes files — the studio does, behind the validator gate); styling
stays in `ui_theme.gd` (the styling-audit allowlist stays empty); no
save-format change; no EventBus signal; §4.8.8 tile-grid floors intact.

## 3. Waves & slots

Execution protocol (`AGENTS.md`): ≤ 4 background sub-agents per wave,
one worktree + branch each, master merges A → B → C → D with the
validator + suite gates after each merge.

| Wave | Slot | Deliverable | Done-when |
|---|---|---|---|
| W0 | master | Doc amendments: `80-*` §4.8.9, `90-*` §5.7 + §4 tree + autoload table, `10-*` §4.23 + §8.9, this file | every cross-citation resolves; the WS protocol table is frozen verbatim in `90-*` §5.7 |
| W1 | master | Game seam: DataLoader `ui_layout` table + light shape check, `scripts/ui/layout_registry.gd`, `UiTheme.sheet_override()`, empty `data/ui_layout.json`, validator group 14 | validator exits 0 on `{}` and on a fixture, rejects each §8.9 rule; registry suite green |
| W2 | A | `autoload/layout_bridge.gd` + `project.godot` autoload + `tools/test_layout_bridge.gd` | headless boot with `-- --layout-bridge`: connect, `hello`/`tree` shapes, one live `move`, `revert`, `commit` writes NO file; without the flag no listener |
| W3 | B | Port screens A (port, market, provisions, shipyard): id pass + dynamic re-apply | each screen registers every persistent control; market rows re-apply on rebuild; existing suites green unchanged |
| W4 | C | Port screens B (inn, guild, palace, tavern): id pass | same as W3 |
| W5 | D | Studio Layout tab (`www/` + `server.py` endpoints + commit w/ validator gate) | tab connects to ws://127.0.0.1:8765, drag/resize/snap on canvas, sheet picker, Commit writes `data/ui_layout.json` only on validator pass |
| W6 | master | Acceptance | the §5 block below, filled |

W2–W5 run as the parallel wave (file-disjoint after W1; W5 codes
against the frozen §5.7 protocol, not W2's branch). Merge order
A → B → C → D.

## 4. Tasks per slot (pointers, not re-specs)

The normative specs live in the docs; this section only names each
slot's file inventory:

- **W2-A:** `autoload/layout_bridge.gd` (new), `project.godot`
  (autoload line last, after FleetSim),
  `tools/test_layout_bridge.gd` (+ `.tscn` runner if the suite
  convention needs one).
- **W3-B / W4-C:** the 4 port-screen `.gd` files per slot
  (`scenes/port/{port_screen, market_screen, provisions_dialog,
  shipyard_screen}` / `{inn_screen, guild_screen, palace_screen,
  tavern_screen}`) — `LayoutRegistry.register(...)` at build,
  `screen_active()` in `_ready`, re-apply in the dynamic-rebuild paths.
  NO behavior change with the file empty.
- **W5-D:** `tools/model_studio/www/` (Layout tab: screen list, element
  tree, frame canvas with 32 px grid overlay, inspector, sheet picker),
  `tools/model_studio/server.py` (`GET /api/layout/file`,
  `GET /api/layout/committed`, `POST /api/layout/commit` — serialize,
  validate in-process, write only on pass), `tools/model_studio/README.md`.
- **W1 (master):** `autoload/data_loader.gd`,
  `scripts/ui/layout_registry.gd` (new), `scripts/ui_theme.gd`,
  `data/ui_layout.json` (new, `{}`), `tools/validate_data.py`
  (`check_group14` + group table + exit-code doc row),
  `tools/test_layout_registry.gd` (new).

## 5. Acceptance criteria (fill at W6)

- [x] `python3 tools/validate_data.py` exit 0 — groups 1–14 — on the
      shipped `{}`; group 14 rejects each §8.9 rule via
      `--self-test-g14` (13/13 cases: unknown screen, bad shape, bad id
      regex, unknown key, non-int, bad anchor, bad sheet (the bar band
      refused), w/h/min/order bounds, anchor+`y`).
- [x] All suites green — final sweep recorded below at W6; the
      port-screen behavior suites (market/port_hub/shipyard/inn/
      tavern/palace/quests …) green against the shipped file — the
      default path is byte-stable.
- [x] `build_ui_art.py --check` / `build_shore.py --check`
      byte-identical — pinned by validator group 13 in every gate run
      (the §8.8 byte-compare lives in the builders' `--check` modes;
      the phase touches no art).
- [x] Live loop demonstrated: the committed fixture reached the live
      market screen through the REAL boot path (DataLoader → registry
      → apply) with NO bridge flag — x/y/w/h tiles landed as pixels,
      the sheet resolved, a non-overridden element kept its default,
      and the fixture arrived through `DataLoader.ui_layout`
      (`tools/phase11_acceptance.tscn`, 6 checks — a one-time scene,
      deleted after the run; the WS round-trip side is permanently
      pinned by `test_layout_bridge`: connect → tree → live move →
      revert → resize → assign_sheet → commit answers `ok` and writes
      NOTHING). Restoring `{}` returns defaults (the bounds suite's
      restored case).
- [x] AMENDED (the demonstration found a gap, then closed it): the
      deliberately clipping commit (a 30-tile header) did NOT fail the
      pre-existing port-screen suites — they pin state invariance, not
      geometry. The guarantee now has its own committed guard:
      `test_layout_bounds` mounts the market screen in BOTH locales
      and pins containment of every unclipped registered row inside
      the 60 × 33.75 canvas (33 rows, `{}` green) — and the same
      fixture BREACHES containment (header @(0,−2), content pushed to
      y=75). The studio Commit banner keeps the manual-suite reminder.
- [x] Game without the flag: no listener on :8765 (slot A's live
      smoke: flagful boot listens, flagless boot does not), saves
      unaffected, `SAVE_VERSION` untouched (9), EventBus unchanged.
- [x] Styling-audit allowlist still empty (5/5 `test_ui_*` green at
      every gate).

## 6. Status log

- **W0+W1 (2026-11-09): ✅ complete** — master direct, one commit
  (`d771c26` on the integration branch). W0: `80-*` §4.8.9, `90-*`
  §5.7 + §4 tree + the autoload table (7th, flag-gated), `10-*`
  §4.23 + §8.9 + the §8 exit table row, this file. W1:
  `DataLoader.ui_layout` (light shape check; ships `{}`),
  `scripts/ui/layout_registry.gd` (register/screen_active/apply/
  apply_overrides/revert/reset_screen/tree; baselines, self-pruning,
  the `data_ordered` lock), `UiTheme.sheet_override` +
  `clear_sheet_override` (all stylebox construction stays in
  `ui_theme.gd`), `data/ui_layout.json` (`{}`),
  `check_group14` + `--self-test-g14` (13 cases green), and
  `tools/test_layout_registry.gd` (34 checks, ALL PASS).
  Gates at the commit: `validate_data.py` exit 0 (groups 1–14);
  the full suite sweep 64/64 green (388 s, zombie/hang 0, the new
  registry suite included) and `run_tests.py --only test_ui_` 5/5
  green incl. the styling audit (allowlist still empty).
- **Parallel wave launched (2026-11-09)** — four background slots, one
  worktree + branch each off the W1 commit: A `phase11/bridge`
  (LayoutBridge + suite), B `phase11/port-a` (port/market/provisions/
  shipyard id pass), C `phase11/port-b` (inn/guild/palace/tavern id
  pass), D `phase11/studio` (the Layout tab + commit endpoints).
  Merge order A → B → C → D with the validator + suite gates after
  each merge.
- **Merge A (W2-A, `e586c239` → merged): ✅** — `LayoutBridge` (the
  dual-wiring WS server: 4.5+ `TCPServer` + `accept_stream`, 4.0–4.4
  legacy `create_server` dispatch — the 4.7 binary REMOVED
  `WebSocketPeer.create_server`; plain JSON text frames, browser-WS
  interop probed), the flag gate (live smoke: listens on :8765 only
  with `-- --layout-bridge`), the single-writer commit reply, headless
  frame degradation, keep-newest. `test_layout_bridge` 29 checks ALL
  PASS; `project.godot` diff one line. Slot deviations adjudicated: no
  `class_name` on the autoload (the parser refuses it — repo
  convention), `.uid` sidecars swept to master.
- **Merge B (W3-B, `940c4889` → merged): ✅** — the port/market/
  provisions/shipyard id pass: 33/413/35/107 registered controls
  (dynamic ids `rows.<good_id>`(+16 parts), `cards.<facility_id>`,
  `fleet.<index>`, `equip.*`; locked: facility grid + data-ordered
  rows), rebuild paths wired (`_refresh`/`rebuild` → re-register +
  `apply_screen`). Gates: validator exit 0; market/port_hub/shipyard/
  registry suites ALL PASS; UI sweep 5/5. Master micro-integration at
  the gate: the rebuild-window duplicate-id guard (`queue_free`
  replacement is the designed flow — `8776293`).
- **Merge D (W5-D, `85d75b07` → merged): ✅** — the studio Layout tab
  (WS client to :8765, frame canvas + 32px grid + drag/resize/reorder/
  sheet picker, session commit) + `GET /api/layout/file` +
  `POST /api/layout/commit` (the §4.23 serialization behind a FULL
  validator pass on a staged `SAILAGE_DATA_ROOT` candidate — write
  only on exit 0). Live endpoint verification on the merged tree:
  GET `{}`, valid commit `ok:true` + the file written in the §4.23
  shape (sorted keys, 2-space indent), invalid commit (x=200) → the
  file byte-unchanged; restored to `{}` after.
- **Merge C (W4-C, `e90b2ad5` → merged): ✅** — the inn/guild/palace/
  tavern id pass: 17/21/43/42 static ids + the data-derived dynamic
  families (`captains.rows.<sighting_id>`, `offers.rows.<instance_id>`,
  `board.rows.*`, `inform.rows.<poster_id>`, `rumors.rows.*`,
  `officers.recruitable.<officer_id>` …), all `data_ordered` row
  containers locked; rebuild paths wired (the `_bind_*` builders +
  `_refresh_morale_bar`). Slot mechanics probed and documented:
  dynamic rebuilds defer re-registration one frame (a same-frame
  re-register over queue-freed-but-live rows would trip the duplicate
  guard). Gates: validator exit 0; inn/tavern/palace/quests/port_hub/
  phase2/phase3 suites ALL PASS, zero SCRIPT ERRORs; UI sweep 5/5.
  Known cosmetic: test_inn's pre-existing un-awaited `_test_menu_
  wiring()` quirk briefly co-mounts two inn instances → the registry's
  duplicate-id notices fire in that one suite's log (last-wins
  semantics; the live instance takes the ids; suite green — two LIVE
  instances claiming one id SHOULD be loud).
- **W6 acceptance (2026-11-09): ✅** — the §5 block above, all boxes
  checked. The end-to-end demonstration (committed file → live screen,
  no flag) ran via a one-time scene, 6/6, deleted after; the bridge
  WS loop is permanently pinned (29 checks); the commit endpoint was
  live-verified on the merged tree; the clipping-commit demonstration
  found the geometry-guard gap and closed it with the committed
  `test_layout_bounds` (5 checks) + the tree dump's `clipped` field
  (a §5.7 tree-payload note: rows additionally carry `parent` and
  `clipped` beyond the frozen table). Final sweep: **66/66 suites
  green** (390 s, zombie/hang 0 — the 63 pre-phase suites +
  `test_layout_registry` 34 + `test_layout_bridge` 29 +
  `test_layout_bounds` 5), `validate_data.py` exit 0 (groups 1–14),
  `data/ui_layout.json` shipped `{}`, worktrees merged and removable.
- **Post-acceptance fix (2026-11-09, user-reported): the WS outbound
  overflow** — a live studio session hit `ERR_OUT_OF_MEMORY` on the
  first frame push: the engine's default WS outbound buffer is 64 KiB
  while a `frame` carries a full-viewport PNG in base64. The fix raises
  every accepted peer's buffers (`_configure_peer`, 16 MiB out /
  1 MiB in, both wirings — the suite now pins the floors, bridge suite
  31 checks). The headless suite never caught it because headless
  frames degrade to empty payloads — noted as the guard's blind spot.
- **Post-acceptance fixes (2026-11-09, live-session reports, round 2):**
  the duplicate-id guard reads tree membership (a queued wrapper frees
  its descendants without their own deletion flag — `474e595`); the
  studio guard reminder shows only after a successful commit
  (`bb63c7b`); the simplified canvas selection model — the element
  list is the only selection surface, and the canvas renders only the
  selected element's box (`1e6c4d5`); and the child-revert geometry
  fix — a container child's position/size are parent-owned and the
  baseline captured them pre-layout, so a child revert restores only
  the min-size floor + sibling slot + sheet (the reported
  facility_grid "min_w 58 → after revert 20" was the stretched rect
  displayed as a min, then the stale pre-layout size restored). The
  inspector's min_w/min_h fields are now override-only (empty = code
  default; the live rect lives in the meta block). Registry suite 38
  checks; the bounds + port-screen suites green.
- **The min-authoritative flag pin (2026-11-09, drag-resize round 3):**
  the user's "after release the box width goes to max" — the stored
  min_w was correct; the DRAWING rendered the control's actual rect,
  and with the default FILL flags the parent re-stretched it to max
  the moment the min applied. A min override on a container child now
  also pins BOTH size flags to shrink-begin — the control measures
  exactly the dragged min (the drag is authoritative on both axes) —
  and child revert restores the captured flags. Registry suite 40
  checks; port_hub/market suites green. The 80-* §4.8.9 child-resize
  cell gains the flag-pin note.
- **The grid guarantee (2026-11-09, drag-resize round 4, user
  direction — "make ALL elements on the 32×32 grid"):** the resize
  fight's root cause — content minimums are font-metric and off-grid,
  so clamps landed off-tile, and the bridge replied with pre-layout
  rects. Now: an overridden min (and a free resize) SUBSUMES the
  content floor quantized UP to whole tiles (the applied size is an
  exact tile multiple — `get_minimum_size()` content, never the
  override's own custom); the bridge's post-edit tree+frame replies go
  DEFERRED one frame (post container sort, coalesced — `_queue_update`),
  so replies carry settled rects; tree rows carry `min_tiles` (the
  content drag floor) and the studio clamps drags to it. Registry suite
  42 checks; bridge 31 (deferred replies green); port_hub 327.
