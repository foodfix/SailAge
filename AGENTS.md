# SailAge — Agent Guide

Single-player 2D sailing/trade/adventure game (Uncharted Waters 2-like),
Godot 4 + GDScript, desktop-first. Design is fully specified in `docs/` —
**read the docs before writing any code or data.**

## Doc reading order

1. `docs/00-OVERVIEW.md` — vision, phases, conventions, glossary, demo loop
2. `docs/10-DATA-SCHEMA.md` — JSON contract, i18n rule, locked content lists
3. `docs/90-ARCHITECTURE.md` — project layout, autoloads, save format
4. System docs as needed: `20`-world/sailing, `30`-ports/trade, `40`-ships,
   `50`-character, `80`-UI/UX, `60`-combat (P2), `70`-quests/endgame (P3)
5. Task backlogs: `docs/IMPLEMENT-Phase1.md` (current), then Phase2/Phase3

## Hard rules (violations = rework)

- **i18n:** every player-facing string is `{"zh": "...", "en": "..."}` in a
  JSON data file (`data/*.json`), never hardcoded, never Godot `.po`. Both
  locales required. UI-frame strings live in `data/ui_strings.json`.
- **Data-first:** game content (ports, goods, ships, officers, quests,
  discoveries, equipment) is JSON under `data/`. Adding content must be a
  data-only change. After editing `data/`, run
  `python3 tools/validate_data.py` — it must exit 0.
- **Concrete numbers only:** if a mechanic needs a number not in the docs,
  the doc is amended first; never invent values in code (see
  `docs/00-OVERVIEW.md` §11).
- **Placeholder art:** colored shapes + default font only; palette constants
  in `docs/80-UI-UX.md` §4.8 (via `scripts/palette.gd`). No imported textures
  in Phase 1.
- **Architecture:** autoloads, scene flow, and save format follow
  `docs/90-ARCHITECTURE.md` exactly (EventBus signal names, autoload order,
  save versioning with migrations).
- **World map** is ASCII text under `data/maps/` (legend in
  `data/map_legend.json`); port coordinates/markers must match
  `docs/10-DATA-SCHEMA.md` §7.1 — the validator enforces agreement.

## Working agreements

- Tasks come from `docs/IMPLEMENT-PhaseN.md`; each task names its docs and
  "done-when" criteria — implement to those, not to taste.
- Design questions discovered during a task are answered in the owning
  system doc first (`docs/00-OVERVIEW.md` §13), then the task proceeds.
- Doc short-hands: `20-*` = `docs/20-WORLD-AND-SAILING.md`, etc.
