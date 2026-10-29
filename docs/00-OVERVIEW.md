# SailAge — Design Overview

## 1. Purpose & Phase

This document is the entry point for the SailAge design documentation set. It
defines the vision, pillars, phase scope, documentation conventions, shared
glossary, and the Phase-1 demo-loop definition of "playable". It gates all
phases: every other doc depends on the conventions defined here.

## 2. Vision

SailAge is a single-player, offline, 2D open-world sailing/trading/adventure
game in the spirit of *Uncharted Waters 2: New Horizons*, built in Godot 4 with
GDScript. The player picks a nationality, receives a small ship in a home port,
and builds fortune and fame by trading between ports, surviving the sea —
and, in later phases, fighting, exploring, and rising through the nobility.

There is no scripted storyline and no fixed end state in Phase 1: the sea
itself (weather, provisions, morale) is the antagonist. Phase 3 adds the
long-arc goals (titles, discovery, retirement).

## 3. Design Pillars

1. **The sea has a cost.** Every day at sea consumes provisions, water, and
   wages. Distance is the core resource; route planning is the core skill.
2. **Information is profit.** Prices differ per port via supply/demand.
   Knowing what a port produces and demands beats any single stat.
3. **Data before code.** Every piece of game content (ports, goods, ships,
   officers, quests) lives in JSON files under `data/`. Adding content is a
   data-only change, editable without the Godot editor.
4. **Placeholder-first.** Colored rectangles and text are legitimate art until
   a documented replacement pass. No task may block on art.
5. **Agent-authorable.** All docs give concrete numbers and exact file/key
   paths so that AI coding agents can implement tasks without asking design
   questions.

## 4. Tone

Grounded Age-of-Sail prose: pragmatic, lightly adventurous. Port flavor text
may be evocative; system text (HUD, dialogs, warnings) is terse and factual.
All player-facing strings exist in Chinese and English (see i18n rule, §9).

## 5. Scope & Phases

| Phase | Name | Content | "Done" means |
|---|---|---|---|
| 1 | Sail & Trade | Tile-grid world map (Mediterranean + W. Europe, 30 ports), free sailing, clock/day tick, crew/provisions/morale, storms, markets, shipyard, tavern, officers, inn, save/load, zh/en toggle | Demo loop (§7) passes end-to-end |
| 2 | Steel & Gunpowder | Turn-based grid sea combat (cannon/ram/board), captain duels, equipment, loot/capture, enemy fleets, loot economy | See `docs/IMPLEMENT-Phase2.md` |
| 3 | Crown & Horizon | Guild quests, royal missions, nobility titles, discoveries, piracy/bounty, tournaments, full world map (~100 ports), retirement/victory | See `docs/IMPLEMENT-Phase3.md` |

Out of scope entirely: multiplayer, accounts, online services,
platform-specific builds beyond desktop, real art production, audio design
beyond a placeholder note.

## 6. Locked Decisions

| Area | Decision |
|---|---|
| Engine | Godot 4.x, GDScript, 2D, desktop-first, 1280×720 logical window, keyboard+mouse |
| Sailing | Free-sail on a large ASCII-authored tile grid (8-directional movement; land tiles block), backed by Godot TileMap |
| Map authoring | ASCII-art grid text files under `data/maps/` with a legend in `data/map_legend.json` |
| Combat (Phase 2) | Turn-based grid-lite tactical battles: square grid, alternating turns, move + 1 action |
| Protagonist | Nationality choice at new game (6 nations → start port/ship/gold/reputation); no scripted storylines |
| World map (P1) | Exactly 30 ports (locked list in `docs/10-DATA-SCHEMA.md` §7.1) |
| Game over (P1) | Sea-death only (starvation, scurvy, ship sunk). No bankruptcy game-over; inn harbor-relief odd-job prevents softlock |
| Data format | JSON under `data/` — never `.tres` — with a schema validator (`tools/validate_data.py`) |
| i18n | Every game-content string is a `{"zh": "...", "en": "..."}` pair in data files; runtime toggle; **no** Godot `.po` |
| Players | Single-player, offline |
| Art | Placeholder-first (colored shapes/free assets); palette in `docs/80-UI-UX.md` |

## 7. Phase-1 Demo Loop (definition of "playable")

The following scenario must be completable end-to-end and is the final
acceptance scenario of `docs/IMPLEMENT-Phase1.md`:

1. Start the game at 1280×720. Title screen offers New Game / Load Game /
   language toggle (zh ↔ en, applies immediately to all on-screen text).
2. New game → pick one of 6 nationalities → see that nation's start port,
   starter ship, and starting gold on a confirmation screen (all strings
   localized).
3. Spawn in home port. Open the market, buy a quantity of a good; gold and
   cargo update on the HUD immediately.
4. Sail out onto the tile-grid map. Move 8-directionally; each in-game day of
   sailing consumes provisions and water per crew member and deducts daily
   wages. Land tiles block movement.
5. A storm event is reachable (strip location fixed in
   `docs/20-WORLD-AND-SAILING.md`); running out of provisions/water reaches
   the starvation/scurvy fail state → game over screen → back to title.
6. Arrive at a second port; port-entry flow shows day count and a port
   greeting. Sell the good: the sale price reflects that port's supply/demand
   modifier; profit/loss is shown in the trade dialog.
7. Visit the shipyard (repair + refit available), the tavern (recruit one
   officer; officer appears in the character panel with stats), and the inn.
8. Save from the port menu; quit to title; Load Game; position, day, gold,
   cargo, crew, morale, morale tier, officers, and reputation are all fully
   restored.
9. Toggle language to Chinese and back at runtime; every player-facing string
   (port names, good names, menus, warnings) switches with no missing keys.

## 8. Doc Map

Read in this order. Each doc follows the Doc Template (§10).

| Order | File | Contents | Phase |
|---|---|---|---|
| 1 | `docs/00-OVERVIEW.md` | This file: vision, conventions, glossary, demo loop | all |
| 2 | `docs/10-DATA-SCHEMA.md` | JSON schemas, i18n rule, validator spec, locked content lists, map legend | all |
| 3 | `docs/90-ARCHITECTURE.md` | Godot project layout, autoloads, save format, scene/data split | all |
| 4 | `docs/20-WORLD-AND-SAILING.md` | Tile grid, movement, clock, consumption, morale, weather, fail states | 1 |
| 5 | `docs/30-PORTS-AND-TRADE.md` | Port facilities, price formulas, trade UI flows | 1 |
| 6 | `docs/40-SHIPS-AND-FLEET.md` | Ship stats, buy/repair/refit, fleet & cargo maths | 1 |
| 7 | `docs/50-CHARACTER-AND-PROGRESSION.md` | Nationality, stats, XP, officers, harbor relief | 1 |
| 8 | `docs/80-UI-UX.md` | Screen inventory, navigation, HUD, dialog conventions, placeholder palette | 1+ |
| 9 | `docs/60-COMBAT.md` | Turn-based sea combat, duels, AI | 2 |
| 10 | `docs/70-QUESTS-DISCOVERY-ENDGAME.md` | Quests, titles, discovery, piracy, tournaments, victory | 3 |
| — | `docs/IMPLEMENT-Phase1.md` | Ordered Phase-1 task backlog | 1 |
| — | `docs/IMPLEMENT-Phase2.md` | Ordered Phase-2 task backlog | 2 |
| — | `docs/IMPLEMENT-Phase3.md` | Ordered Phase-3 task backlog | 3 |

Repo root `AGENTS.md` points agents at this file and restates the i18n and
placeholder-art rules.

## 9. i18n Rule (summary; normative spec in `10-DATA-SCHEMA.md` §3)

- Every game-content display string is a JSON object `{"zh": "...", "en": "..."}`.
- UI-frame strings (menus, buttons, HUD labels) also follow the same
  `{"zh","en"}` rule, stored in `data/ui_strings.json`.
- The runtime locale is a GameState field (`"zh"` or `"en"`), changeable at any
  time; UI text rebinding is immediate and global.
- A string missing either locale is a data-validation error, not a runtime
  fallback.

## 10. Doc Template (mandatory skeleton for every doc in `docs/`)

1. **Purpose & Phase** — what this doc specifies; which phase(s) it gates.
2. **Artifacts** — exact files/scenes/data keys this doc defines.
3. **Dependencies** — which docs must be read first.
4. **Systems/Mechanics** — concrete numbers and formulas, never adjectives
   (e.g., `price = base × (0.8 + 0.4·supplyFactor)`, clamp `[0.5×, 2×]`).
5. **Data Examples** — valid JSON, `zh` and `en` both filled.
6. **Edge Cases & Fail States** — enumerated explicitly.
7. **Acceptance Criteria** — checklist verifiable without judgment calls.

## 11. Vibe-Coding Conventions (apply to all docs and all implementation)

- **No "TBD".** Resolve every value inline as a concrete number, or mark it
  `OUT OF SCOPE (phase N)` with a reason.
- **Named artifacts.** Every mechanic maps 1:1 to named scenes, scripts, and
  data keys (e.g., `data/ports.json#ports[].base_gold`). A mechanic without an
  artifact path is an incomplete design.
- **Valid JSON.** Every JSON example in docs must parse; spot-check during the
  writing session.
- **Bilingual completeness.** Every `zh` string has an `en` pair and vice
  versa; the glossary (§12) covers both.
- **First-pass numbers are final-for-now.** Balance tuning is a later task,
  not a reason to leave blanks.
- **Scene-vs-data split.** Data files describe *what*; scenes/scripts describe
  *how it behaves*. Content additions must be data-only changes
  (see `docs/90-ARCHITECTURE.md`).

## 12. Glossary (canonical CN/EN pairs)

Used in docs, data files, and UI strings. New terms must be added here first.

| zh | en | Meaning |
|---|---|---|
| 港口 | Port | A visitable harbor settlement with facilities |
| 船队 | Fleet | All ships the player owns, sailing together |
| 旗舰 | Flagship | The ship the player character commands; combat/movement stats derive from it |
| 货物 | Goods | Tradable commodities; measured in cargo units |
| 货物舱位 | Cargo unit | Abstract hold space; 1 unit of any good = 1 cargo unit |
| 补给 | Provisions | Food; 1 unit feeds `RATION_SIZE` (5) crew for 1 day (`20-*` §4.5) |
| 淡水 | Fresh water | 1 unit waters `RATION_SIZE` (5) crew for 1 day (`20-*` §4.5) |
| 船员 | Crew | Sailors on a ship; consume provisions/water, draw wages |
| 日薪 | Daily wage | Gold paid per crew member per day at sea and in port |
| 士气 | Morale | 0–100 crew happiness; low morale causes desertion/mutiny |
| 哗变 | Mutiny | Crew revolt event at critical morale |
| 逃散 | Desertion | Crew members leave when morale is low on port arrival |
| 耐久 | Durability | Ship hit points; 0 = ship sinks |
| 载重 | Capacity | Max cargo units (goods + provisions + water combined) |
| 航速 | Speed | Tiles moved per day, before modifiers |
| 市场 | Market | Port facility: buy/sell goods |
| 造船厂 | Shipyard | Port facility: buy/repair ships |
| 酒馆 | Tavern | Port facility: recruit crew and officers, hear rumors |
| 旅店 | Inn | Port facility: rest, harbor relief (odd jobs) |
| 公会 | Guild | Port facility: quests (Phase 3) |
| 王宫 | Palace | Port facility: royal missions, titles (Phase 3) |
| 声望 | Reputation | Per-nation standing, −100…+100 |
| 爵位 | Nobility title | Royal rank ladder (Phase 3) |
| 发现物 | Discovery | Explorable landmark/relic reported for fame (Phase 3) |
| 任务 | Quest | Guild/royal commission (Phase 3) |
| 悬赏 | Bounty | Price on the player's head from piracy (Phase 3) |
| 海战 | Sea battle | Turn-based tactical combat (Phase 2) |
| 接舷战 | Boarding | Triggering a captain duel by adjacency (Phase 2) |
| 决斗 | Duel | Simplified best-of-N captain fight (Phase 2) |
| 敌船队 | Hostile fleet | World-map pirate/navy marker that can start a battle (Phase 2) |
| 战利品 | Loot | Salvage gold + captured cargo after a battle (Phase 2) |
| 打捞 | Salvage | Reward gold for ships sunk by the player: `Σ floor(base_price × 0.05)` (`60-*` §4.11.10) |
| 装备 | Equipment | Weapon/armor (player) or figurehead/sail (ship) items (Phase 2) |
| 撤退 | Retreat | Leaving a battle without victory (Phase 2) |
| 投降 | Surrender | Ending a battle by yielding hold or flagship (Phase 2) |
| 被俘 | Captured | Game-over reason: the player's last ship is taken (Phase 2) |
| 海盗行为 | Piracy | Attacking a navy fleet: one −20 reputation with its nation per battle (`60-*` §4.11.10) |
| 风暴 | Storm | Weather event damaging ships and pushing them off course |
| 断粮 | Starvation | Fail state: provisions exhausted too long |
| 坏血病 | Scurvy | Fail state: fresh water exhausted too long |
| 沉没 | Sinking | Fail state: hull integrity reaches 0 at sea |
| 港口救济 | Harbor relief | Inn odd-job fallback income; prevents softlock |
| 声望值 | Fame | Permanent, non-decaying renown (`70-*` §4.1); currency of the title ladder |
| 爵位阶梯 | Title ladder | Per-nation Knight→Duke progression (`70-*` §4.9.2) |
| 授勋典礼 | Ceremony | The palace dialog that grants the next title |
| 委托 | Commission | A guild quest instance (`70-*` §4.9.3); see 任务 |
| 王室委托 | Royal mission | Palace-only mission tied to one nation (`70-*` §4.9.4) |
| 传闻 | Rumour | A purchased discovery hint (`70-*` §4.4) |
| 探索 | Explore | The world-map action that finds discoveries within radius 3 |
| 悬赏金 | Bounty | The price a wanted captain pays to clear a nation's bounty |
| 封闭港 | Closed port | A bountied nation's port whose facilities are shut (`70-*` §4.9.6) |
| 比武大会 | Tournament | The monthly 3-round palace bracket (`70-*` §4.9.7) |
| 退休 | Retirement | The win state: Duke rank plus a locked summary save (`70-*` §4.7) |
| 环球海图 | World chart | The Phase-3 160×96 map (`70-*` §4.9.8) |

## 13. Edge Cases & Fail States (doc-set level)

- **Contradiction between docs** — the lower-numbered doc wins; file an issue
  section entry under the wronged doc and fix at the next cross-check pass.
- **A mechanic needing a number not in its doc** — violates §11; the doc must
  be amended before implementation, not guessed at.
- **A task in `IMPLEMENT-PhaseN.md` raising a design question** — the design
  question is answered in the owning system doc first, then the task proceeds.

## 14. Acceptance Criteria

- [ ] Every doc listed in §8 exists and follows the §10 template.
- [ ] Every JSON example in the doc set parses.
- [ ] Every display string in examples and glossary has both `zh` and `en`.
- [ ] Phase-1 demo loop (§7) is traceable through the Phase-1 docs with no
      unresolved reference.
- [ ] Every `IMPLEMENT-PhaseN.md` task cites the docs it draws from and gives
      a "done-when" acceptance criterion.
