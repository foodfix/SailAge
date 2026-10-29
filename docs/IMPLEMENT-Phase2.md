# IMPLEMENT — Phase 2: Steel & Gunpowder

**STATUS: ✅ COMPLETE (2026-10-30) — Phase 2 shipped, merged and accepted.**
All eight tasks A–H done; the full gate is `python3 tools/validate_data.py`
(exit 0) plus **22 headless suites, 3 599 checks, zero `SCRIPT ERROR`,
`--quit-after 3` clean**: `test_battle` (218), `test_battle_screen` (122),
`test_battle_economy` (68), `test_duel` (148), `test_encounters` (156),
`test_equipment` (149), `test_save_v2` (80), `test_phase2_acceptance` (142),
and the 14 Phase-1 suites unchanged (2 516). Acceptance record:
`tools/demo_check_phase2.md`; per-task status and the completion record at the
bottom of this file.

Pre-work done before any code (the Phase-1 lesson: a value left "task-owned"
gets invented differently by each branch, and the merge then has to reconcile
two models of one rule):

| Doc | Amendment |
|---|---|
| `60-*` §4.1, §4.11.3, §4.11.11.2 | Navy spawn chance (2%/day, 2–4 ships) and the full spawn-roll order pinned |
| `60-*` §4.11 | New section: every number §4.2–§4.10 left open is now fixed — seed formula, deployment tiles, enemy composition, MP/reload/initiative, cannon & ram formulas (incl. storm rounding), duel tie rules, capture/loss/surrender resolution, AI tie-breaks, end conditions, rewards & rep deltas |
| `60-*` §4.11.11.1–§4.11.11.3 | Marker movement, contact detection, pursuit cooldown, spawn immunity, `battle_started` handoff |
| `60-*` §4.11.12–§4.11.13 | Equipment ownership (player vs ship slots), battle/duel effects, and the locked 8-item content set |
| `60-*` §4.12 | Module interface pins: `BattleSim`, `AiFleet`, `Duel`, `BattleResult`, `BattleRewards`, `Encounters`, the outcome block |
| `90-*` §8.1/§8.2 | Save v2 shape (`hostile_fleets`, `proximity_cooldowns`), `MIGRATIONS[1]` contents, migration purity rule |
| `90-*` §5.1/§5.4 | New signals (`battle_started`, `battle_finished`, `duel_finished`), new GameState fields |
| `40-*` §4.1/§4.3 | Ship `equipment` block, effective max durability, refit row enabled, buy-equipment rule |
| `50-*` §4.8 | Player `equipment` block |
| `80-*` §4.1/§4.2/§4.3/§4.4/§4.7.1/§4.7.2 | S10/S11 scenes, battle nav edges, battle input keys, `battle.*`/`duel.*`/`encounter.*` namespaces, battle-screen and shipyard-equipment wireframes |
| `10-*` §4.6 | Equipment schema now points at the pinned content set |
| `00-*` §12 | Glossary terms for hostile fleet, loot, equipment, retreat, surrender, captured |

Ordered backlog (lettered sections, coarser than Phase 1 by design; details
marked **task-owned** are decided inside the task, following the cited doc).
Execute as background-subagent waves per the plan at the bottom: **max 4
concurrent subagents, one git worktree per subagent, master merges each
finished branch.** Prerequisite: Phase 1 complete (`IMPLEMENT-Phase1.md`
T19 passed).

## A. Save migration v1 → v2

✅ **Done** (W1) — `SAVE_VERSION = 2`, `MIGRATIONS[1]` pure migration, `MIGRATIONS` is a `static var` (GDScript rejects a `Callable` in a const); `tools/test_save_v2.tscn` (80).

- Add `hostile_fleets` + battle fields to GameState/save; `MIGRATIONS[1]`.
- **Docs:** `90-*` §8.2, `60-*` §2. **Done-when:** a Phase-1 save loads in
  Phase-2 code with migrated fields and re-saves as version 2.

## B. Combat engine core (`battle_sim.gd`)

✅ **Done** (W1) — `BattleSim` + `AiFleet`, 16×10 grid, §4.11 pins implemented verbatim, §5 numbers exact (cannon 16/12 storm, ram 27/11, galley 21); `tools/test_battle.tscn` (218).

- 16×10 grid, deployment bands, initiative order, MP rules, actions
  (cannon/ram/board/hold), reload, damage formulas.
- **Docs:** `60-*` §4.2–4.5. **Done-when:** unit tests reproduce `60-*` §5
  numbers; engine runs headless start-to-finish vs. scripted moves.

## C. Duel modal (`duel_modal.tscn`)

✅ **Done** (W2) — `Duel.start` byte-equal to `BattleSim.resolve_duel`, `BattleResult.apply` for capture/FLEET_MAX/loot/`gameover.captured`, S11 modal; `tools/test_duel.tscn` (148).

- Best-of-5 flow, equipment modifiers, capture/loss outcomes incl.
  `gameover.captured`.
- **Docs:** `60-*` §4.6, §6; `80-*` S11. **Task-owned:** round-presentation
  polish. **Done-when:** seeded duel reproduces scripted round outcomes;
  capture respects `FLEET_MAX` and cargo rules.

## D. Battle scene + HUD

✅ **Done** (W2) — S10 grid/tokens/highlight/action menu/log, §4.12.4 end sequence with guarded sibling modules, all six §4.9 AI rules observable; `tools/test_battle_screen.tscn` (122).

- `battle_screen.tscn`: grid rendering (palette placeholders), unit tokens,
  move/attack highlighting, action menu, retreat, after-action loot dialog.
- **Docs:** `60-*` §4.2–4.10, §4.9 (AI priority list), `80-*` §4.3 (input).
  **Task-owned:** token/animation presentation. **Done-when:** a full player
  vs AI battle is playable via mouse+keyboard; all §4.9 AI rules observable.

## E. Equipment data + effects

✅ **Done** (W1) — the 8 §4.11.13 items, validator groups 3/4/5 extended, refit enabled, four slots wired; `tools/test_equipment.tscn` (149).

- `data/equipment.json` first content set (~8 items, task-owned list within
  `10-*` §4.6 schema), shipyard refit activation, figurehead/sail slots.
- **Docs:** `10-*` §4.6, `40-*` §4.3 (refit row enables), `50-*` §4.2.
- **Done-when:** refit buy/sell works (cannon 100g/5 units); worn equipment
  alters duel rolls per `60-*` §4.6.

## F. World-map encounters

✅ **Done** (W2) — `Encounters` spawn/move/contact/cooldown, measured 0.986% pirate and 1.99% navy over 100k days, navy −20 once at battle start; `tools/test_encounters.tscn` (156).

- `encounters.gd`: pirate spawn rules, navy hunters (bounty hook from
  Phase 3 noted but navy spawn tables delivered here), contact → battle,
  marker movement, post-battle cooldowns.
- **Docs:** `60-*` §4.1, §4.8. **Done-when:** seeded spawn rates match
  table; contact opens battle with correct fleet compositions; rep −20 on
  attacking a navy.

## G. Economy & strings integration

✅ **Done** (W3) — `BattleRewards.apply` (salvage/XP/rep, idempotent), the full
§4.12.5 inventory (47 keys: 46 `battle.*`/`duel.*`/`encounter.*` plus
`gameover.captured`) and the combat glossary terms;
`tools/test_battle_economy.tscn` (68).

- Loot/salvage gold, battle XP, reputation deltas, all `battle.*`/`duel.*`
  strings in `ui_strings.json`, combat entry in glossary docs if terms added.
- **Docs:** `60-*` §4.8, `80-*` §4.4. **Done-when:** validator passes; demo
  battle completable in both locales with no `<key>` output.

## H. Phase-2 acceptance

✅ **Done** (W4) — `tools/test_phase2_acceptance.tscn` (142 checks): four
scenarios, each from a real Phase-1 `save_version: 1` file loaded through
`SaveSystem.load(1)` so the v1→v2 migration runs, then driven through the real
scenes — S1 cannon victory, S2 boarding capture (+ full-fleet loot/scuttle),
S3 retreat, S4 last-ship duel loss → `gameover.captured`. Acceptance record:
`tools/demo_check_phase2.md`.

- Scripted E2E: start Phase-1 save → encounter pirate → win by cannons;
  second save: win by boarding+capture; third: retreat; fourth: lose duel as
  last ship → `gameover.captured`. All four run clean.

---

## Subagent execution plan (max 4 background subagents, one worktree each)

Same protocol as `IMPLEMENT-Phase1.md`, hardened with the W9/W10 lesson from
that phase: **every subagent works in its own git worktree and never in the
master's tree; the master agent alone merges.** The summary here is
self-sufficient.

- **Roles:** the master (orchestrating session) owns the base branch, creates
  and removes worktrees, runs every merge, resolves conflicts, and is the only
  writer of `data/ui_strings.json`. Subagents implement one task each inside
  their worktree and commit there.
- **Launch:** per wave, the master creates one worktree + branch per task
  (`git worktree add ../sailage-w1-a -b p2/w1-a main`), then launches one
  background `general` subagent per task as parallel calls in one message,
  passing the worktree path. At most **4** run concurrently; further ready
  tasks queue FIFO. Never launch a subagent without a dedicated worktree.
- **Subagent prompt:** the task block verbatim + cited `60-*`/`80-*`/`10-*`
  sections + the AGENTS.md hard rules + the wave's pins + the worktree path
  and branch name; the report lists every done-when criterion with its
  pass/fail result, the branch name + commit SHA, the test/validator commands
  run and their output, and any new `ui_strings.json` keys (zh + en) as text.
- **Subagent boundaries:** a subagent edits only files under its worktree; it
  does not touch `main`, does not create other worktrees, does not merge or
  rebase onto the base branch, and does not edit `data/ui_strings.json`
  (exception: a wave with a single subagent — W3 — owns that file outright).
  Uncommitted work in a worktree is a failed report.
- **Hard rules:** no two running subagents edit the same file (worktrees make
  ownership physical, but a merge still conflicts if two branches touch one
  file); the master merges `ui_strings.json` keys from reports itself; a
  blocked subagent stops and reports — the master amends the owning doc first,
  then relaunches it in a fresh worktree.
- **Wave gate:** a wave is done only when every subagent has reported, the
  master has merged every branch, and the merged tree passes the full check
  (`python3 tools/validate_data.py` if the wave touched `data/`, plus the
  relevant headless Godot tests with script-error counts compared against the
  pre-merge baseline). Only then does the next wave launch.

### Merge protocol (master only)

1. Read every report; reject a branch whose done-when results are missing or
   whose report does not name a commit SHA.
2. Merge branches **one at a time, in the wave's listed order**, with
   `git merge --no-ff p2/<wave>-<task>` on the base branch — never a
   multi-branch octopus merge.
3. After each merge, run `python3 tools/validate_data.py` (must exit 0) and
   the touched headless tests; **compare check counts**, not just the
   `ALL PASS` line (Phase 1 lost 141→103 checks behind a green summary).
4. On conflict: prefer the branch that matches the owning doc and the wave
   pin; if the branches encode two different models of the same rule, stop,
   amend the owning system doc (`00-OVERVIEW.md` §13), and reconcile by hand
   in the merged tree before continuing.
5. After the wave is green, apply the collected `ui_strings.json` keys in one
   commit, re-run the validator, remove the merged worktrees
   (`git worktree remove ../sailage-w<n>-<task>`), and delete the branches.
6. Record any deviation (relaunch, pin change, reordering) in a completion
   record at the bottom of this file, as Phase 1 does.

| Wave | Background subagents (parallel, one worktree each) | Merge order | Gate (after) |
|---|---|---|---|
| W1 | A, B, E | A → B → E | — |
| W2 | C, D, F | C → D → F | W1 |
| W3 | G | G | W2 |
| W4 | H | H | W3 |

Wave notes:

- **W1 ownership split:** A owns GameState/save fields + `MIGRATIONS[1]`;
  B keeps all battle state local to `battle_sim.gd` (headless, no GameState
  edits in this wave); E owns `data/equipment.json` + shipyard refit
  activation. Disjoint files, so the three worktrees share nothing at merge
  except possibly `ui_strings.json` keys, which the master applies.
- **P2 (C∥D):** C implements `duel_modal.tscn` +
  `Duel.start(config) -> outcome` per `60-*` §4.6/§6; D's boarding action
  calls that API. C does not edit battle scenes. C merges first so D's call
  resolves; D's worktree must not stub `Duel` itself.
- **P3 (D∥F):** D exposes `open_battle(encounter) -> result`; F calls it on
  contact per `60-*` §4.1 and does not edit battle scenes. D merges first;
  if F's branch was cut before D landed, the master rebases the F branch onto
  the merged base and re-runs F's tests before merging.
- **Signal boundary:** D/F only emit the battle/duel outcome signals (per
  `90-*` §5.1); G (W3, single subagent, own worktree) applies loot gold,
  battle XP, and reputation deltas and adds the `battle.*`/`duel.*` strings
  (G *may* edit `ui_strings.json` directly — it is the only subagent in its
  wave; conflicts are impossible).
- **H (W4):** the acceptance task runs against the fully merged tree, so its
  worktree is cut from the post-W3 base and its branch carries only the E2E
  scripts + completion record; the master verifies all four scenarios before
  merging.


---

## Completion record (2026-10-30)

Phase 2 is **complete and accepted**. Every task A–H is done, the tree is
green, and the four §H scenarios pass end to end from real Phase-1 save files.
The record below follows Phase 1's shape: per-task status, deviations from the
sanctioned wave plan, the doc amendments made during implementation, and the
integration defects the merge itself caught.

### Per-task status

| Task | Wave | Status | Evidence |
|---|---|---|---|
| A — save migration v1 → v2 | W1 | ✅ Done | `SAVE_VERSION = 2`, pure `MIGRATIONS[1]`, `MIGRATIONS` a `static var` (a `Callable` is not a constant expression); `test_save_v2` (80) |
| B — combat engine core | W1 | ✅ Done | `battle_sim.gd` + `ai_fleet.gd`, 16×10 grid, §4.11 pins verbatim, §5 numbers exact (cannon 16/12 storm, ram 27/11, galley 21); `test_battle` (218) |
| C — duel modal | W2 | ✅ Done | `Duel.start` byte-equal to `BattleSim.resolve_duel`, `BattleResult.apply` for capture/`FLEET_MAX`/loot/`gameover.captured`, S11 modal; `test_duel` (148) |
| D — battle scene + HUD | W2 | ✅ Done | S10 grid/tokens/highlight/action menu/log, §4.12.4 end sequence behind guarded seams, all six §4.9 AI rules observable; `test_battle_screen` (122) |
| E — equipment data + effects | W1 | ✅ Done | the 8 §4.11.13 items, validator groups 3/4/5 extended, refit enabled, four slots wired; `test_equipment` (149) |
| F — world-map encounters | W2 | ✅ Done | `Encounters` spawn/move/contact/cooldown, measured 0.986 % pirate and 1.99 % navy over 100 k days, navy −20 charged once at battle start; `test_encounters` (156) |
| G — economy & strings | W3 | ✅ Done | `BattleRewards.apply` (salvage/XP/rep, idempotent), the full §4.12.5 inventory (47 keys: 46 `battle.*`/`duel.*`/`encounter.*` plus `gameover.captured`), glossary; `test_battle_economy` (68) |
| H — Phase-2 acceptance | W4 | ✅ Done | four scripted E2E scenarios from Phase-1 saves; `test_phase2_acceptance` (142); record in `tools/demo_check_phase2.md` |

Gate: `python3 tools/validate_data.py` exit 0; **22 suites, 3 599 checks**
(Phase-1 14 suites = 2 516 unchanged, Phase-2 8 suites = 1 083), zero
`SCRIPT ERROR`; `godot --headless --path . --quit-after 3` exit 0.

### Deviations from the sanctioned wave plan

| Deviation | Why | Effect |
|---|---|---|
| **A was not purely additive on GameState** | `battle_screen._ready` reads `GameState.pending_encounter` for the §4.11.11.3 handoff, and A owns the field | A declared it (transient, never saved) and D read it behind `"pending_encounter" in GameState` guards, so a worktree cut before A still parsed |
| **B added two seams beyond the first §4.12.1 table** | The AI and S10 need to enumerate units, and the two menu-only outcomes are not per-unit actions | `units()`, `living_units()`, `flagship_unit()`, `flagship_index()`, `is_acting()`, `retreat()`, `offer_surrender()` were appended to §4.12.1 rather than invented per caller |
| **B accepted an optional `rng` in the config** | §4.11.1 requires the duel to continue the stream composition already consumed | Added as an optional extra; `seed` alone still reproduces any battle |
| **D did not stub `Duel`** (as P2 planned) | C's `Duel` merged first, and the guard (`ResourceLoader` + `has_method`) is what keeps the module optional | D calls `Duel.start` for presentation only; `BattleSim.board()` remains the single data path |
| **The master applied `ui_strings.json` in one commit after W3** | G was the wave's only subagent, but the master is the sole writer of that file | 47 keys landed in one commit, then the validator re-ran |
| **W4's branch carries three minimal fixes, not just scripts** | The acceptance harness exposed three genuine integration defects (below), and item 5 of the task authorises a minimal fix when a scenario finds one | All three are in `scenes/combat/battle_screen.gd`, none changes a pinned number |
| **`test_sailing` was fixed on the way in** | It referenced `Character.` through the global class cache and failed to parse on a fresh checkout | Replaced by a `preload` (the repo-wide convention), so a cold `godot --headless` run parses |

### Doc amendments made during Phase-2 implementation

Every one of these is an owning-doc change made *before* the code that needed
it, per `00-OVERVIEW.md` §13. They are listed here so a later reader can see
which numbers were pinned during the phase rather than before it.

| Doc | Section | Amendment |
|---|---|---|
| `60-*` | §4.1, §4.11.3, §4.11.11.2 | Navy spawn chance (2 %/day, 2–4 ships) and the full spawn-roll order pinned |
| `60-*` | §4.11 (new) | Every number §4.2–§4.10 left open: seed formula, deployment tiles, enemy composition, MP/reload/initiative, cannon and ram formulas (incl. storm rounding), duel tie rules, capture/loss/surrender resolution, AI tie-breaks, end conditions, rewards and rep deltas |
| `60-*` | §4.11.11.1–§4.11.11.3 | Marker movement, contact detection, pursuit cooldown, spawn immunity, `battle_started` handoff |
| `60-*` | §4.11.12–§4.11.13 | Equipment ownership (player vs ship slots), battle/duel effects, the locked 8-item set |
| `60-*` | §4.12 | Module interface pins (`BattleSim`, `AiFleet`, `Duel`, `BattleResult`, `BattleRewards`, `Encounters`, the outcome block) |
| `60-*` | §4.12.1 (additive seams) | The seven extra `BattleSim` methods and the optional `rng` config key, added once B's implementation showed they were needed |
| `60-*` | §4.12.4 | Battle-end call order (five steps) so file ownership stays disjoint |
| `60-*` | §4.11.10 | **Navy-rep charging semantics**: exactly one −20 per navy battle, at battle start, never in `rep_deltas` — so applying an outcome twice cannot double-charge |
| `60-*` | §4.11.10 | **Two-ports-then-dedupe reading** of the pirate +2 rule: the two nearest ports are selected first, then their nations deduplicated (no third port is considered) |
| `60-*` | §4.11.10, §4.12.4 step 4 | **Retreat exception**: a `retreat` is not a resolved battle, so §4.12.4 step 4 keeps the marker and calls `set_pursuit_cooldown(id, day + 1)` (still recording the 3-day spawn immunity); §4.11.10's "marker is removed" is the aftermath of a resolved battle only |
| `60-*` | §4.12.5 | The full `battle.*`/`duel.*`/`encounter.*` string inventory |
| `90-*` | §8.1/§8.2 | Save v2 shape (`hostile_fleets`, `proximity_cooldowns`), `MIGRATIONS[1]` contents, migration purity rule |
| `90-*` | §5.1/§5.4 | New signals (`battle_started`, `battle_finished`, `duel_finished`), new GameState fields |
| `40-*` | §4.1/§4.3 | Ship `equipment` block, effective max durability, refit row enabled, buy-equipment rule |
| `50-*` | §4.8 | Player `equipment` block |
| `80-*` | §4.1/§4.2/§4.3/§4.4/§4.7.1/§4.7.2 | S10/S11 scenes, battle nav edges, battle input keys, the `battle.*`/`duel.*`/`encounter.*` namespaces, battle-screen and shipyard-equipment wireframes |
| `10-*` | §4.6 | Equipment schema now points at the pinned content set |
| `00-*` | §12 | Glossary terms for hostile fleet, loot, equipment, retreat, surrender, captured |
| `60-*` | §4.11.11.1 | **Cooldown inclusivity**: `cooldown_until_day` is the *last idle day* (`D + 1`), deliberately different from `proximity_cooldowns` (a first legal day), plus "a marker on pursuit cooldown raises no contact" |
| `60-*` | §4.12.5 | **String inventory growth, 41 → 47 keys**, as D/C/F needed rows G's first draft did not carry |

### Integration defects caught at merge

| Defect | How it showed | Fix |
|---|---|---|
| A temporary `battle_strings.gd` bridge | C/D/F needed text before G's `ui_strings.json` keys landed, and a hard-coded GDScript string table violates the i18n hard rule | Deleted; every battle/duel/encounter string now comes only from `data/ui_strings.json` |
| `pending_encounter` leaked between test fixtures | A previous suite's queued descriptor made the next `battle_screen._ready` open a stale battle | Every fixture builder resets `GameState.pending_encounter = null` (H's `_clobber_state` does too) |
| `test_sailing` global-class parse failure on a fresh checkout | `Character.` resolved only through the editor's class cache, so a cold `godot --headless` run failed to parse | Replaced with the repo-wide `preload` convention |
| Stale "refit disabled" assertion in `tools/test_demo_loop.gd` | Phase 1's step 7 asserted the refit row was **disabled**; Phase 2 enables it | The single check now asserts present + disabled at 0 cannons + enabled at 5; the suite stays at **87 checks** |

### Defects found by this acceptance task (W4)

Three integration bugs only the whole loop could expose; each fixed minimally
in `scenes/combat/battle_screen.gd` (details in `tools/demo_check_phase2.md`):

1. `open_battle` took `contact` from the marker's `position` instead of the
   player's tile, so the §4.11.1 seed and the §4.11.10 return tile were wrong
   whenever the marker was not exactly on the fleet.
2. A retreat deleted the marker (`Encounters.remove`), making §4.10's +1 day
   pursuit cooldown unreachable and silently erasing the pirate fleet.
3. `BattleResult.apply` received bare ship instances instead of
   `BattleSim.units()`, so `captured_units[].index` was always `-1`.
