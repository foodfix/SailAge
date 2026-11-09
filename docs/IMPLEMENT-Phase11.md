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

- [ ] `python3 tools/validate_data.py` exit 0 — groups 1–14 — on the
      shipped `{}` AND on a committed fixture; group 14 rejects each
      §8.9 rule (one negative probe per rule).
- [ ] All suites green (`run_tests.py`), count recorded here; the
      port-screen locale layout pins (zh + en) green against the
      shipped file — proof the default path is byte-stable.
- [ ] `build_ui_art.py --check` / `build_shore.py --check`
      byte-identical (the phase touches no art).
- [ ] Live loop demonstrated once, scripted: launch
      `godot --path . -- --layout-bridge`, studio Layout tab, drag a
      toolbar (32 px snap), resize the invest control, assign a panel
      `sheet: backdrop`, revert one element, Commit →
      `data/ui_layout.json` contains exactly those overrides; game
      restart WITHOUT the flag applies them; deleting the file returns
      defaults.
- [ ] A deliberately bad commit (min_w clipping zh text) fails the
      locale layout suite when run against the committed file —
      demonstrated once, then reverted.
- [ ] Game without the flag: no listener on :8765, saves unaffected,
      `SAVE_VERSION` untouched (9), EventBus unchanged.
- [ ] Styling-audit allowlist still empty.

## 6. Status log

- **W0+W1 (2026-11-09): launched** — master direct (no parallelism;
  the seam defines every contract the parallel wave codes against).
