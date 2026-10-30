# IMPLEMENT — Phase 3: Crown & Horizon

**STATUS: ✅ COMPLETE (2026-10-30) — Phase 3 shipped, merged and accepted.**

> **Superseded (2026-10-30):** the shipped dual-map world layer (task G's
> `p3_world.txt`/`map_legend_p3.json`/`ports_p3.json`, task C's p3-grid
> discovery positions, and the marker-charset pin of §4.9.8) is replaced by
> **`IMPLEMENT-Phase4.md`** (single real-Earth map, 2160×1080). The tasks
> below remain the historical record of what shipped.

All ten tasks A–J done (I skipped as the backlog allows). The full gate is
`python3 tools/validate_data.py` (exit 0) plus **30 headless suites, 4 545
checks, zero `SCRIPT ERROR`, `--quit-after 3` clean**; the eight new suites are
`test_save_v3` (141), `test_world_map` (62), `test_quests` (105),
`test_bounty` (80), `test_palace` (183), `test_tournament` (144),
`test_retirement` (78) and `test_phase3_acceptance` (102). Acceptance record:
`tools/demo_check_phase3.md`; per-task status and the completion record at the
bottom of this file.

Pre-work done before any code (the Phase-1/2 lesson: a value left "task-owned"
gets invented differently by each branch, and the merge then has to reconcile
two models of one rule). Landed as one doc-only commit (`83eeb2c`) ahead of
implementation:

| Doc | Amendment |
|---|---|
| `70-*` §4.9 | New normative section pinning every task-owned value: fame sources §4.9.1, title ladder + grants §4.9.2, quest seeds/draws §4.9.3, royal missions §4.9.4, piracy/rival table §4.9.5, closed ports §4.9.6, tournaments §4.9.7, world-map constants §4.9.8 |
| `70-*` §2, §4.4, §4.7 | `quests` superseded by `active_quests`; discovery radius/state pins; retirement save shape and the six summary rows |
| `90-*` §8.1/§8.2 | Save v3 shape (eleven new keys), `MIGRATIONS[2]` contents, migration purity, `quests` erasure |
| `90-*` §5.1/§5.4/§9.1 | Nine new EventBus signals, the transient tournament handoff fields, the `maps/maps.json` index |
| `10-*` §4.4.1, §4.7, §8 | `ports_p3.json` envelope, discovery schema, validator groups 6/7 |
| `30-*` §4.2, §4.7, §7 | `title_bonus` in the sell formula, closed-port rule, tavern/guild/palace wireframes, the 39/34 titled-London worked example |
| `80-*` §4.1–§4.3, §4.7.3, §4.7.4 | S12/S13/S16 + the `E` action + the S13→S10→S13 bracket edge, the three new screen wireframes, the Phase-3 `ui_strings` inventory |
| `20-*` §4.11/§4.12 | `world.map_id`, the Explore action, the minimap note |
| `50-*` §4.6 | Phase-3 reputation sources |

Ordered backlog (lettered, coarse by design; **task-owned** details are
decided inside the task per the cited docs). Execute as background-subagent
waves per the plan at the bottom: **max 4 concurrent subagents, one git
worktree per subagent, and the master agent merges each finished branch.**
Prerequisite: Phase 2 complete.

## A. Save migration v2 → v3

✅ **Done** (W1) — `SAVE_VERSION = 3`, pure `MIGRATIONS[2]` (eleven §8.1 v3 keys, `quests` erased, `world.map_id`), retired-save path (`last_loaded_retired` / `last_retired_summary`); `tools/test_save_v3.tscn` (141).

- Add `fame`, `titles`, `bounties`, `active_quests`,
  `completed_royal_missions`; `MIGRATIONS[2]`.
- **Docs:** `90-*` §8.2, `70-*` §2. **Done-when:** Phase-2 saves migrate and
  re-save as version 3.

## B. Guild activation + quest system

✅ **Done** (W2) — `quest_gen.gd` (deterministic per-(port, week) offers over 9 templates, delivery/bounty/exploration, accept/complete/fail/tick/prune, shared `objective_text`), S12 `guild_screen.tscn`, character-panel `Quests` tab, and both documented scene hooks (port-entry completion, immediate cargo-loss failure); `tools/test_quests.tscn` (105).

- `guild_screen.tscn`, `quest_gen.gd` (delivery/bounty/exploration from
  templates), quest tracking UI (character panel tab), refresh cadence,
  fail/complete hooks.
- **Docs:** `70-*` §4.2, `10-*` §4.8, `30-*` §4.1 (stub activates).
  **Task-owned:** initial template set (~6 templates) in `data/quests.json`.
  **Done-when:** seeded offers deterministic per (port, week); each type
  completable; failure paths (expiry, cargo sold) fire correct deltas.

## C. Discovery system + content

✅ **Done** (W3) — `scripts/world/discovery.gd` (radius 3, Explore, report-once, 100g hints), 30 discoveries with zh/en hints, validator groups 6/7 position checks, tavern `Rumours` tab, world-map `E` plus the in-range HUD hint **and** button; `tools/test_tavern` rumours section (268 total), `tools/test_world_map` (62).

- Explore action, sighting radius 3, report at guild, tavern Rumors tab
  (100g hints), `data/discoveries.json` content set.
- **Docs:** `70-*` §4.4, `10-*` §4.7. **Task-owned:** ~30 discoveries with
  positions on the Phase-3 world map + hints in zh/en. **Done-when:**
  hint→find→report loop yields exact `report_reward_gold`/`fame`; validator
  extended to check discovery positions ⊆ active map.

## D. Palace activation, royal missions, titles

✅ **Done** (W3) — S13 `palace_screen.tscn`, rep-30 gate, three rotating mission kinds (one per nation), `fame.gd` ladder with all four grants wired into `TradeEngine.title_units`, `ShipyardEngine.repair_cost` and `QuestGen.max_active_quests`; `tools/test_palace.tscn` (183).

- `palace_screen.tscn`, rep ≥ 30 gate, three mission kinds, title ladder with
  ceremony and grants (sell-price `title_bonus`, quest slot, repair
  discount).
- **Docs:** `70-*` §4.3, `30-*` §4.2 (bonus hook). **Done-when:** ladder
  thresholds exact; every grant mechanically verifiable; per-nation
  independence shown.

## E. Piracy & bounty loop

✅ **Done** (W2) — `bounty.gd` (rival table from `data/nations.json#rivals`, −20/+2 at navy battle start, issue at ≤ −50 with `500 × |rep|`, both clear paths → exactly −10), closed-port rows with the palace pay exception, hunter spawns; `tools/test_bounty.tscn` (80).

- Piracy rep deltas, rival-nation bonus table (**task-owned** per
  `70-*` §4.5 note), port closure, hunter integration (Phase-2 encounters),
  both bounty-clearing paths.
- **Docs:** `70-*` §4.5, `60-*` §4.1/§4.7. **Done-when:** rep −50 closes
  that nation's ports + spawns hunters; payment and surrender both reset to
  −10; no path to unrecoverable lockout (self-nation included).

## F. Tournaments

✅ **Done** (W4) — `tournament.gd` (30-day rotation over the §7.4 capitals, day 1–5 window, 1,000g fee, 3 escalating bouts with durability carry, 10,000g/+100 fame vs 500g + 50 % repair), S13 entry with the S10→S13 bracket return, tournament tier pinned in `BattleSim.FLEET_TIER`, tavern+guild announcements; `tools/test_tournament.tscn` (144).

- Monthly rotation, entry window, 3-battle bracket with durability carry,
  prize/consolation, rumor/guild announcements.
- **Docs:** `70-*` §4.6, `60-*`. **Done-when:** tournament completes in all
  outcomes; prizes exact; bounty-closed host blocks entry.

## G. Full world map content

✅ **Done** (W1) — `data/maps/p3_world.txt` (160×96) + `map_legend_p3.json` + `ports_p3.json` (70 new, 100 total) + `maps/maps.json` index, validator group 7 (strict BFS, marker/position agreement, discovery positions), S2 world selector, `new_game(..., map_id)`; `tools/test_world_map.tscn` (62). P1 stays playable.

- `data/maps/p3_world.txt` + legend additions + ~100-port list
  (**task-owned**: grid size, coordinates, port table with
  produces/demands/flavor in zh/en, sea lanes sane for `20-*` economics),
  validator extended to the new map, swap mechanism (new game offers world
  or Milestone toggle — **task-owned**: simplest is separate new-game
  option).
- **Docs:** `70-*` §4.8, `10-*` §6, `90-*` §9. **Done-when:** pipeline loads
  the new map with zero code edits; validator BFS reaches all ports;
  Phase-1 map still loads and plays.

## H. Retirement & victory

✅ **Done** (W5) — duke gate at the docked nation's palace, `palace.retire.confirm`, Retire row hidden outside the gate, S16 six-row summary in live and summary modes, retired payload + summary-only load in both locales; `tools/test_retirement.tscn` (78).

- Duke gate, retirement flow, ending/summary screen, retired-save behavior.
- **Docs:** `70-*` §4.7, `80-*` §4.2. **Done-when:** full loop from Duke
  ceremony to locked summary save works in both locales.

## I. Placeholder-art replacement pass (optional)

⏭ **Skipped** — optional per the backlog; Phase 1's placeholder-art rule (colored shapes + `scripts/palette.gd`) is still satisfied on every screen, so Task I is simply not taken.

- Swap coded squares for a free-asset tile/token set; must remain
  palette-conformant fallback if assets missing.
- **Docs:** `80-*` §4.8. **Task-owned** entirely.

## J. Phase-3 acceptance

✅ **Done** (W6) — `tools/test_phase3_acceptance.tscn` (102): trade → 2 discovery reports → duke → tournament win → retire, plus raid → bounty → hunters → both clear paths, both locales, save/load round trip at v3; record in `tools/demo_check_phase3.md`.

- E2E: new game → trade to fund expeditions → report 2 discoveries →
  climb to Duke with one nation → win one tournament → retire; plus a piracy
  run: raid → bounty → hunters → clear bounty. All with zh/en spot-checks
  and validator green.

---

## Subagent execution plan (max 4 background subagents, one worktree each)

Same protocol as `IMPLEMENT-Phase2.md`, built on the Phase-1 W9/W10 lesson:
**every subagent works in its own git worktree and never in the master's tree;
the master agent alone merges.** The summary here is self-sufficient.

- **Roles:** the master (orchestrating session) owns the base branch, creates
  and removes worktrees, runs every merge, resolves conflicts, and is the only
  writer of `data/ui_strings.json`. Subagents implement one task each inside
  their worktree and commit there.
- **Pre-flight (once, before W1):** base branch `main` is clean and green
  (validator exit 0 + Phase-2 suites), no stale `p3/*` branches or worktrees
  exist (`git worktree list`), and every branch of a wave is cut from the same
  merged base commit.
- **Worktrees:** one per subagent, created by the master with
  `git worktree add ../sailage-w<n>-<task> -b p3/w<n>-<task> <base>` (or the
  harness equivalent, e.g. `opencode.worktree_create` + `session_move`) —
  keep them outside the repo; a worktree is removed only after its branch is
  merged and green.
- **Before launching a wave:** pin every number the wave's tasks share (any
  `**task-owned**` value two branches could implement differently) in the
  owning `70-*`/`10-*` doc — the Phase-2 lesson: a value left open gets
  invented twice and the merge then reconciles two models of one rule.
- **Launch:** per wave, the master creates one worktree + branch per task,
  then launches one background `general` subagent per task as parallel calls in
  one message, passing the worktree path and branch name. At most **4** run
  concurrently; further ready tasks queue FIFO. Never launch a subagent
  without a dedicated worktree (worked example: [below](#worked-wave-example)).
- **Validation in the worktree:** a subagent runs the validator and its
  headless suites **inside its own worktree**
  (`godot --headless --path ../sailage-w<n>-<task> ...`), never against the
  master's tree, and pastes the check counts in its report. A fresh worktree
  has no `.godot/` import cache, so allow the first run to import.
- **Subagent working directory:** a subagent session starts in the master's
  directory, so its prompt states the worktree path as the working directory
  and requires every command, test and edit to use that path (absolute or
  `cd`-prefixed). Any edit that lands outside the worktree fails the report.
- **Subagent prompt:** the task block verbatim + cited `70-*`/`10-*`/`60-*`/
  `90-*`/`80-*` sections + the AGENTS.md hard rules + the wave's pins + the
  worktree path and branch name. The report lists every done-when criterion
  with its pass/fail result, the branch name + commit SHA, the test/validator
  commands run and their output, and any new `ui_strings.json` keys (zh + en)
  as text.
- **Subagent boundaries:** a subagent edits only files under its worktree; it
  does not touch `main`, does not create other worktrees, does not merge or
  rebase onto the base branch, does not amend the design docs (a needed spec
  change is reported to the master, who amends it per `00-OVERVIEW.md` §13),
  and does not edit `data/ui_strings.json`. (Exception: in a single-subagent
  wave the master may hand `ui_strings.json` to the sole subagent — as Phase 2
  did in W3 — because no conflict is possible.) Uncommitted work in a worktree
  is a failed report.
- **Hard rules:** no two running subagents edit the same file (worktrees make
  ownership physical, but a merge still conflicts if two branches touch one
  file); the master merges `ui_strings.json` keys from reports itself; a
  blocked subagent stops and reports — the master amends the owning doc first
  (`00-OVERVIEW.md` §13), then relaunches it in a fresh worktree.
- **Wave gate:** a wave is done only when every subagent has reported, the
  master has merged every branch, and the merged tree passes the full check
  (`python3 tools/validate_data.py` if the wave touched `data/`, plus the
  relevant headless Godot tests with check counts compared against the
  pre-merge baseline). Only then does the next wave launch.
- **Opportunistic fill:** while a wave runs, a later task may start early in
  its own worktree — filling the 4th slot — only if all its dependencies are
  done and it shares no file with any running subagent and no wave pin breaks.

### Merge protocol (master only)

1. Read every report; reject a branch whose done-when results are missing or
   whose report does not name a commit SHA.
2. Merge branches **one at a time, in the wave's listed merge order**, with
   `git merge --no-ff p3/<wave>-<task>` on the base branch — never a
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
   record at the bottom of this file, as Phases 1 and 2 do.

### Worked wave example

Wave W3 (C ∥ D), cut from the post-W2 `main`; task branches are named
`p3/w<wave>-<task>` and worktrees live beside the repo:

```sh
git switch main                 # base is already the merged post-W2 commit
git worktree add ../sailage-w3-c -b p3/w3-c main
git worktree add ../sailage-w3-d -b p3/w3-d main
# launch both subagents in one message (background, one worktree each):
#   C -> ../sailage-w3-c on p3/w3-c     D -> ../sailage-w3-d on p3/w3-d
# when both reports name a commit SHA:
git merge --no-ff p3/w3-c     # then validator + touched suites, compare counts
git merge --no-ff p3/w3-d     # then validator + touched suites, compare counts
# wave green, ui_strings keys applied, worktrees and branches retired:
git worktree remove ../sailage-w3-c
git worktree remove ../sailage-w3-d
git branch -d p3/w3-c p3/w3-d
```

If `p3/w3-d` was cut before C landed and its report shows a stubbed
`Discoveries` call, the master rebases it (`git rebase main`), re-runs its
suites, and only then merges it.

| Wave | Subagents (parallel, one worktree each) | Merge order | Gate (after) |
|---|---|---|---|
| W1 | A, G | A → G | — |
| W2 | B, E | B → E | W1 |
| W3 | C, D | C → D | W2 |
| W4 | F, I (optional) | F → I | W3 |
| W5 | H | H | W4 |
| W6 | J | J | W5 |

Wave notes:

- **Using all 4 slots:** the table lists each wave's *ready set*; W1–W4 have
  only two ready tasks, so two slots stay free until opportunistic fill
  promotes a later task whose dependencies are already green and whose files
  are disjoint. The 4-subagent cap is a ceiling, not a quota — never widen a
  wave by splitting one task across two worktrees.
- **W1 ownership split:** A owns save fields + `MIGRATIONS[2]`; G owns
  `data/maps/`, the legend, `data/ports.json`, the validator extension, and
  the new-game map toggle. Both branches may collide in
  `tools/validate_data.py` only if A extends validator groups — A must not;
  the map validator extension belongs to G alone.
- **P4 (B∥E):** B spawns bounty-quest fleets through the Phase-2 encounter
  spawn API unmodified; E owns `encounters.gd` (hunter tables) and
  `Bounty.pay_off()` (`70-*` §4.5). E's pay-path done-when is verified after
  W3, when D adds the palace pay-bounty row calling `Bounty.pay_off()`; E
  merges after B so the encounter API it consumes is already on the base.
- **P5 (C∥D):** C owns found-discovery state and exposes
  `Discoveries.found_count()`; D's charting mission reads only that API and
  must not stub it. Both branches are cut from the post-W2 base; C merges
  first so D's branch either already resolves the call or is rebased onto the
  merged base by the master (with its tests re-run) before merging.
- **W4/W5 split:** F and H both extend the palace screen (tournament entry
  vs. Retire flow), so H waits one wave in its own worktree. I (art pass) is
  optional and touches only scene visuals, so it may run beside F — or be
  skipped entirely.
- **J (W6):** the acceptance task runs against the fully merged tree, so its
  worktree is cut from the post-W5 base and its branch carries only the E2E
  scripts + completion record; the master verifies the scenarios before
  merging.

A wave may be split or merged with another only if the substitute order keeps
every task's cited docs implemented elsewhere first; record the change in the
completion record.

---

## Completion record

*(Filled in by the master as Phase 3 closes: per-task status with evidence,
deviations from the sanctioned wave plan and why, doc amendments made during
implementation, integration defects caught at merge, and the final gate —
validator exit 0 plus the full headless suite with check counts.)*

### Status (2026-10-30)

Phase 3 is **complete and accepted**. Every task A–J is done, the tree is green,
and both §J scenarios pass end to end on the shipped Phase-3 world. The E2E
record with the per-leg numbers lives in `tools/demo_check_phase3.md`.

| Task | Status | Evidence |
|---|---|---|
| A — save migration v2 → v3 | ✅ Done | `SAVE_VERSION = 3`, pure `MIGRATIONS[2]` (adds the eleven §8.1 v3 keys, erases `quests`, adds `world.map_id = "p1"`), retired-save path (`last_loaded_retired` / `last_retired_summary`); `test_save_v3` (141) |
| B — guild activation + quests | ✅ Done | `quest_gen.gd` (seeded offers, 9 templates, delivery/bounty/exploration, accept/complete/fail/tick/prune, `objective_text`/`type_key` shared by both UIs), `guild_screen.tscn`; `test_quests` (105) |
| C — discovery system + content | ✅ Done | `scripts/world/discovery.gd` (radius 3, explore, report-once, priced hints), 30 discoveries with zh/en hints, validator group 6/7 position checks, tavern `Rumours` tab (`80-*` §4.7.3); `test_tavern` rumours section (268 total), `test_world_map` (62) |
| D — palace, royal missions, titles | ✅ Done | `palace_engine.gd` (rep-30 gate, three rotating mission kinds, one per nation, ceremony, repair bays, retire), `fame.gd` ladder + all four grants wired into `TradeEngine.title_units` / `ShipyardEngine.repair_cost` / `QuestGen.max_active_quests`; `test_palace` (183) |
| E — piracy & bounty loop | ✅ Done | `bounty.gd` (rival table from data, −20/+2, issue at ≤ −50 with `500 × |rep|`, both clear paths → exactly −10), closed-port rule + palace pay exception in the hub; `test_bounty` (80) |
| F — tournaments | ✅ Done | `tournament.gd` (30-day rotation, day 1–5 window, fee, 3 escalating bouts with carry, 10 000g/+100 fame, 500g + 50 % repair), S13 entry + S10 → S13 bracket return; `test_tournament` (144) |
| G — full world map | ✅ Done | `data/maps/p3_world.txt` (160×96) + `map_legend_p3.json` + `ports_p3.json` (70 new ports, 100 total), `maps/maps.json` index, validator group 7 (BFS, marker/position agreement, discovery positions), S2 world selector, `new_game(..., map_id)`; `test_world_map` (62) |
| H — retirement & victory | ✅ Done | duke gate at the docked nation's palace, `palace.retire.confirm`, S16 six-row summary in both modes, retired payload + summary-only load; `test_retirement` (78) |
| I — art pass (optional) | ⏭ Skipped | The backlog marks it optional and Phase 1's placeholder-art rule (colored shapes + `palette.gd`) is still satisfied everywhere |
| J — Phase-3 acceptance | ✅ Done | `tools/test_phase3_acceptance.tscn` (102): trade → 2 reports → duke → tournament win → retire, plus raid → bounty → hunters → both clear paths, both locales; record in `tools/demo_check_phase3.md` |

**Gate:** `python3 tools/validate_data.py` exit 0; **30 suites, 4 545 checks**,
zero `SCRIPT ERROR`; `godot --headless --path . --quit-after 3` exit 0.
Phase 2 closed at 22 suites / 3 599 checks, so Phase 3 adds 8 suites / 895
checks plus 51 checks inside five existing suites (character +24, tavern +23,
port_hub +2, save +1, save_v2 +1) — all of them new Phase-3 assertions, none a
dropped count.

### Deviations from the sanctioned wave plan

| Deviation | Why | Effect |
|---|---|---|
| The wave table was executed as **one serial stream in the master tree** instead of background worktrees | Each wave's tasks were finished and committed before the next started, so no two tasks ever held uncommitted edits in one file — the property the worktree split exists to guarantee | Same task order (`A∥G → B∥E → C∥D → F → H → J`); the pins landed **before** any code (`83eeb2c`), which is the part of the protocol that prevents two models of one rule |
| Task **I** (art pass) was skipped | Optional per the backlog; the placeholder-art rule is still met | No visual change; `palette.gd` remains the single colour source |
| `data/ports_p3.json` instead of extending `data/ports.json` | `10-*` §7.1's 30-port list is a **locked** content table the validator compares exactly; adding 70 ports there would have required rewriting a locked list | `DataLoader` merges both files; a port carries either a `p1` `position` or a `p3` block, so the P1 map stays byte-compatible and the validator still checks §7.1 verbatim |
| The p3 grid is 160×96 spanning 80°W–160°E | The task-owned grid was generated together with a validator-equivalent BFS so every one of the 100 ports is reachable with no corner cutting | `70-*` §4.9.8 was amended to the shipped span before the file was generated |
| Two transient `GameState` fields (`pending_tournament_round`, `last_tournament_outcome`) | §4.9.7's bracket must survive the S13 → S10 → S13 hop; a node reference would violate `90-*` §5.1's "cross-screen communication never uses direct node references" | Both are declared transient/never-saved in `90-*` §5.4 and cleared by `new_game()` |
| `ShipyardEngine.repair_cost/can_repair/repair` gained an optional `port_id` parameter | The count grant is per **port nation**, and the palace bays repair at a palace, not at the shipyard's docked port | Default preserved (`GameState.current_port`), so every existing call site is unchanged; `test_shipyard` stays at 141 |

### Doc amendments made during Phase-3 implementation

All were made in the owning doc **before** the code that needed them, per
`00-OVERVIEW.md` §13:

- `70-*` §4.9 new normative section (pins every task-owned value): fame sources
  §4.9.1, title ladder + grants §4.9.2, quest seeds/draws §4.9.3, royal missions
  §4.9.4, piracy/rival table §4.9.5, closed ports §4.9.6, tournaments §4.9.7,
  world-map constants §4.9.8; plus §4.4 discovery radius/state pins and the §4.7
  retirement save shape.
- `90-*` §8.1 save v3 fields, §8.2 `MIGRATIONS[2]`, §5.1 the six new signals,
  §5.4 the two transient tournament fields, §9.1 the map index.
- `10-*` §4.4.1 the `ports_p3.json` envelope, §4.7 discoveries, validator
  groups 6/7.
- `30-*` §4.2 the `title_bonus` term and the closed-port rule, §4.7 tavern
  `Rumors` / guild / palace wireframes, §7 acceptance line for the 39/34 titled
  London example.
- `80-*` §4.1/§4.2/§4.3 S12/S13/S16 + the `E` action + the tournament S13→S10→S13
  edge, §4.7.3 the three new screens, §4.7.4 the Phase-3 `ui_strings` inventory.
- `20-*` `world.map_id`, the Explore action and the minimap note.
- `50-*` Phase-3 reputation sources.

### Integration defects caught at merge

1. **A tournament bout returned to the world map.** `battle_screen`'s
   after-action `Continue` always routed to S3, so the bracket lost the palace
   between bouts and the next round never started (§4.9.7's "three successive
   battles" was unreachable in play). Fixed with `return_scene()`: a
   `tournament_`-tagged encounter returns to S13, everything else to S3.
2. **A delivery quest could never complete in play.** §4.9.3 pins both "port
   entry of `dest_port_id` completes the delivery" and "a cargo mutation fails it
   immediately", but neither hook was ever called: `world_map._enter_port` only
   docked and greeted. Fixed by wiring `Phase3Hooks.on_port_entered` into port
   entry and `Phase3Hooks.on_cargo_changed` into the `fleet_changed` funnel.
3. **A navy battle start charged only the −20.** §4.9.5 pins "the `+2` is
   applied once per battle, at battle start, next to the Phase-2 `−20`", and
   the scene charged the −20 alone, so the rival table never fired in play.
   Fixed by routing `world_map._charge_navy_piracy` through
   `Bounty.apply_piracy` (which also re-evaluates the bounty threshold, so a
   raid can issue a bounty at battle start).
4. **The Retire row was always visible, just disabled.** §4.7 pins "the palace
   shows the `Retire` row **only** while the docked port's nation title is
   duke"; the screen rendered it greyed for everyone. Fixed by hiding the row
   outside the gate (and by skipping hidden rows in `all_text()`).
5. **The palace's tournament row hid its own reason.** The entered case was
   handled before the generic `blocked` branch, so an out-of-window or
   wrong-host palace still printed `Entry recorded`. Fixed by letting
   `status.blocked` drive both label and tooltip.
6. **`PalaceEngine._delivery_offer` drew from `GameState.day` instead of the
   day it was asked about.** A test or a screen previewing a future day got the
   live day's delivery; fixed by threading `day` through.
7. **The palace's repair path refunded a discount instead of quoting it.** Two
   price implementations could drift; `ShipyardEngine.repair()` now takes the
   port and charges the discounted amount once.

