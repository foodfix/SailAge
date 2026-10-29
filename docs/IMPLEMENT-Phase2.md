# IMPLEMENT — Phase 2: Steel & Gunpowder

**STATUS: 🔄 IN PROGRESS (started 2026-10-29).**

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

- Loot/salvage gold, battle XP, reputation deltas, all `battle.*`/`duel.*`
  strings in `ui_strings.json`, combat entry in glossary docs if terms added.
- **Docs:** `60-*` §4.8, `80-*` §4.4. **Done-when:** validator passes; demo
  battle completable in both locales with no `<key>` output.

## H. Phase-2 acceptance

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

