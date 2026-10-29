# IMPLEMENT — Phase 3: Crown & Horizon

Ordered backlog (lettered, coarse by design; **task-owned** details are
decided inside the task per the cited docs). Execute as background-subagent
waves per the plan at the bottom: **max 4 concurrent subagents, one git
worktree per subagent, and the master agent merges each finished branch.**
Prerequisite: Phase 2 complete.

## A. Save migration v2 → v3

- Add `fame`, `titles`, `bounties`, `active_quests`,
  `completed_royal_missions`; `MIGRATIONS[2]`.
- **Docs:** `90-*` §8.2, `70-*` §2. **Done-when:** Phase-2 saves migrate and
  re-save as version 3.

## B. Guild activation + quest system

- `guild_screen.tscn`, `quest_gen.gd` (delivery/bounty/exploration from
  templates), quest tracking UI (character panel tab), refresh cadence,
  fail/complete hooks.
- **Docs:** `70-*` §4.2, `10-*` §4.8, `30-*` §4.1 (stub activates).
  **Task-owned:** initial template set (~6 templates) in `data/quests.json`.
  **Done-when:** seeded offers deterministic per (port, week); each type
  completable; failure paths (expiry, cargo sold) fire correct deltas.

## C. Discovery system + content

- Explore action, sighting radius 3, report at guild, tavern Rumors tab
  (100g hints), `data/discoveries.json` content set.
- **Docs:** `70-*` §4.4, `10-*` §4.7. **Task-owned:** ~30 discoveries with
  positions on the Phase-3 world map + hints in zh/en. **Done-when:**
  hint→find→report loop yields exact `report_reward_gold`/`fame`; validator
  extended to check discovery positions ⊆ active map.

## D. Palace activation, royal missions, titles

- `palace_screen.tscn`, rep ≥ 30 gate, three mission kinds, title ladder with
  ceremony and grants (sell-price `title_bonus`, quest slot, repair
  discount).
- **Docs:** `70-*` §4.3, `30-*` §4.2 (bonus hook). **Done-when:** ladder
  thresholds exact; every grant mechanically verifiable; per-nation
  independence shown.

## E. Piracy & bounty loop

- Piracy rep deltas, rival-nation bonus table (**task-owned** per
  `70-*` §4.5 note), port closure, hunter integration (Phase-2 encounters),
  both bounty-clearing paths.
- **Docs:** `70-*` §4.5, `60-*` §4.1/§4.7. **Done-when:** rep −50 closes
  that nation's ports + spawns hunters; payment and surrender both reset to
  −10; no path to unrecoverable lockout (self-nation included).

## F. Tournaments

- Monthly rotation, entry window, 3-battle bracket with durability carry,
  prize/consolation, rumor/guild announcements.
- **Docs:** `70-*` §4.6, `60-*`. **Done-when:** tournament completes in all
  outcomes; prizes exact; bounty-closed host blocks entry.

## G. Full world map content

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

- Duke gate, retirement flow, ending/summary screen, retired-save behavior.
- **Docs:** `70-*` §4.7, `80-*` §4.2. **Done-when:** full loop from Duke
  ceremony to locked summary save works in both locales.

## I. Placeholder-art replacement pass (optional)

- Swap coded squares for a free-asset tile/token set; must remain
  palette-conformant fallback if assets missing.
- **Docs:** `80-*` §4.8. **Task-owned** entirely.

## J. Phase-3 acceptance

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
