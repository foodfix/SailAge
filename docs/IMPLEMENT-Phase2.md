# IMPLEMENT — Phase 2: Steel & Gunpowder

Ordered backlog (lettered sections, coarser than Phase 1 by design; details
marked **task-owned** are decided inside the task, following the cited doc).
Prerequisite: Phase 1 complete (`IMPLEMENT-Phase1.md` T19 passed).

## A. Save migration v1 → v2

- Add `hostile_fleets` + battle fields to GameState/save; `MIGRATIONS[1]`.
- **Docs:** `90-*` §8.2, `60-*` §2. **Done-when:** a Phase-1 save loads in
  Phase-2 code with migrated fields and re-saves as version 2.

## B. Combat engine core (`battle_sim.gd`)

- 16×10 grid, deployment bands, initiative order, MP rules, actions
  (cannon/ram/board/hold), reload, damage formulas.
- **Docs:** `60-*` §4.2–4.5. **Done-when:** unit tests reproduce `60-*` §5
  numbers; engine runs headless start-to-finish vs. scripted moves.

## C. Duel modal (`duel_modal.tscn`)

- Best-of-5 flow, equipment modifiers, capture/loss outcomes incl.
  `gameover.captured`.
- **Docs:** `60-*` §4.6, §6; `80-*` S11. **Task-owned:** round-presentation
  polish. **Done-when:** seeded duel reproduces scripted round outcomes;
  capture respects `FLEET_MAX` and cargo rules.

## D. Battle scene + HUD

- `battle_screen.tscn`: grid rendering (palette placeholders), unit tokens,
  move/attack highlighting, action menu, retreat, after-action loot dialog.
- **Docs:** `60-*` §4.2–4.10, §4.9 (AI priority list), `80-*` §4.3 (input).
  **Task-owned:** token/animation presentation. **Done-when:** a full player
  vs AI battle is playable via mouse+keyboard; all §4.9 AI rules observable.

## E. Equipment data + effects

- `data/equipment.json` first content set (~8 items, task-owned list within
  `10-*` §4.6 schema), shipyard refit activation, figurehead/sail slots.
- **Docs:** `10-*` §4.6, `40-*` §4.3 (refit row enables), `50-*` §4.2.
- **Done-when:** refit buy/sell works (cannon 100g/5 units); worn equipment
  alters duel rolls per `60-*` §4.6.

## F. World-map encounters

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
