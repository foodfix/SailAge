# IMPLEMENT — Phase 3: Crown & Horizon

Ordered backlog (lettered, coarse by design; **task-owned** details are
decided inside the task per the cited docs). Execute as background-subagent
waves per the plan at the bottom (max 4 concurrent). Prerequisite: Phase 2
complete.

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

## Subagent execution plan (max 4 background subagents)

Same protocol as `IMPLEMENT-Phase1.md` (background `general` subagents, max 4
concurrent, wave-gated, orchestrator-owned `data/ui_strings.json`, validator
run after any wave that touched `data/`); the summary here is self-sufficient.

- **Launch:** per wave, one background subagent per task, all launched as
  parallel calls in one message; wait for every report + done-when
  verification before the next wave.
- **Subagent prompt:** the task block verbatim + cited doc sections + the
  AGENTS.md hard rules + the wave's pins; the report lists every done-when
  criterion with its pass/fail result.
- **Hard rules:** no two running subagents edit the same file (the
  orchestrator merges `ui_strings.json` keys from reports); a blocked
  subagent stops and reports — the orchestrator amends the owning doc first,
  then relaunches.

| Wave | Background subagents (parallel) | Gate (after) |
|---|---|---|
| W1 | A, G | — |
| W2 | B, E | W1 |
| W3 | C, D | W2 |
| W4 | F, I (optional) | W3 |
| W5 | H | W4 |
| W6 | J | W5 |

Wave notes:

- **W1 ownership split:** A owns save fields + `MIGRATIONS[2]`; G owns
  `data/maps/`, the legend, `data/ports.json`, the validator extension, and
  the new-game map toggle.
- **P4 (B∥E):** B spawns bounty-quest fleets through the Phase-2 encounter
  spawn API unmodified; E owns `encounters.gd` (hunter tables) and
  `Bounty.pay_off()` (`70-*` §4.5). E's pay-path done-when is verified after
  W3, when D adds the palace pay-bounty row calling `Bounty.pay_off()`.
- **P5 (C∥D):** C owns found-discovery state and exposes
  `Discoveries.found_count()`; D's charting mission reads only that API. C's
  report UI lands in the guild screen delivered by W2.
- **W4/W5 split:** F and H both extend the palace screen (tournament entry
  vs. Retire flow), so H waits one wave. I (art pass) is optional and touches
  only scene visuals, so it may run beside F — or be skipped entirely.
