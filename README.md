# SailAge — 帆海纪元

A single-player, offline, 2D Age-of-Sail trading / sailing / adventure game in
the spirit of *Uncharted Waters 2: New Horizons*.

You pick a nation and a background, take command of a small ship in your home
port, and make your way by trading between real-world ports, surviving weather,
provisions and morale — then by fighting, exploring, and rising through the
nobility. There is no scripted storyline: the sea is the antagonist, and the
long arc is titles, discoveries and retirement.

SailAge is a **local web app**. A Python/FastAPI server owns the whole
simulation; a React/TypeScript single-page app is a pure renderer and intent
sender. Nothing leaves your machine — no accounts, no multiplayer, no online
services.

---

## What's in the game

- **One real-Earth world** — a 4320 × 2160 tile globe (12 tiles/degree,
  1 tile ≈ 5 nm) that wraps at the dateline, with 150 ports placed by real
  latitude/longitude.
- **Sailing with a cost** — day/clock ticks, provisions, water, crew wages,
  morale, storms, scurvy and starvation, seasonal sea ice, prevailing winds,
  monsoons, ocean currents, and sail trim.
- **A living economy** — supply/demand stock pricing over 40 goods
  (staple / specialty / exclusive), regional demand events, tariffs, permits,
  port development and a national allegiance tug-of-war.
- **Ports with depth** — market, shipyard, tavern, inn, guild and palace;
  buying/repairing/refitting ships, 16 ship types, 24 equipment items,
  officers with posts and loyalty, inn rest and the harbor-relief odd job.
- **People and careers** — a unified character model (5 attributes, 8 skills)
  shared by the player, 96 recruitable officers and named NPC captains;
  inspect / talk / gift / befriend / appoint, dossiers and a 28-tier title
  ladder.
- **Quests, discovery and endgame** — guild commissions, royal missions,
  permits, commendations, 30 discoveries, bounties and piracy, tournaments,
  and retirement as the victory state.
- **Naval combat** — turn-based 48 × 30 battles: velocity physics, 8-direction
  headings, port/starboard broadsides with independent reload, four shot
  types, ramming, hook-and-board, captain duels, side morale and surrender;
  AI profiles plus a one-ply lookahead commander.
- **Living sea traffic** — nation-owned NPC fleets in eight roles on
  historical trade lanes (traders, coasters, patrols, couriers, privateers,
  pirates, hunters, treasure fleets), convoys, wrecks, sightings and wanted
  posters.
- **32 screens, fully localized** — every player-facing string exists in
  Chinese and English and switches live at runtime.

---

## How it's built

```
server/   THE simulation — Python 3.10+, FastAPI. Every game rule lives here.
  app.py        FastAPI app + static mounts
  session.py    the single live session, action adapters, 10 Hz tick loop
  api/          HTTP endpoints + per-screen projections
  ws.py         the one-client WebSocket protocol
  save.py       save v1 (3 slots) + explored-tiles codec
  sim/          world, sailing, trade, character, combat, quests…
  tests/        pytest contract/parity suites

web/      the SPA — React 18 + TypeScript + Vite. A pure renderer.
  src/screens/   the 32 screens
  src/canvas/    world, chart and battle renderers
  src/kit/       the UI atoms + nine-patch chrome
  src/i18n/      zh/en string layer (data-driven, no hardcoded strings)
  public/tiles/  the generated tile pyramids

data/     all game content as JSON (ports, goods, ships, people, quests…)
assets/   first-party generated pixel art
tools/    stdlib-only build/validation tools for data + rasters + tiles
docs/     the full design specification
```

Design rule that shapes everything: **the client computes no game rules.** The
server streams state over one WebSocket (10 Hz ticks) and answers discrete
actions over HTTP; the TSX renders and sends intents. Saves are server-owned
files.

---

## Requirements

- **Python 3.10+** (tested on 3.14) — server dependencies are pinned in
  `server/requirements.txt`.
- **Node.js 20+** (tested on 24) with npm — for building the SPA.
- A modern browser (Chromium/Firefox/Safari). No GPU requirements.

---

## Quick start

```bash
# 1. Server dependencies (a local venv inside server/)
python3 -m venv server/.venv
server/.venv/bin/pip install -r server/requirements.txt

# 2. Build the web client
cd web
npm ci
npm run build
cd ..

# 3. Play
./run.sh
```

`./run.sh` (or `server/.venv/bin/python -m server`) starts uvicorn on
**http://127.0.0.1:8537/** and opens your browser. Drop the build step and the
server still runs, but `/` answers a clear “web client is not built” message
until `web/dist` exists.

Useful flags:

```bash
server/.venv/bin/python -m server --port 9000   # another port
server/.venv/bin/python -m server --no-browser  # headless / leave the tab alone
server/.venv/bin/python -m server --host 0.0.0.0
```

First launch has no save, so you land on the title screen: **New Game →
nation → background → allocate free points → your home port.**

### Development loop

Run the two halves separately for hot reload:

```bash
# terminal 1 — API + WS (no browser)
server/.venv/bin/python -m server --no-browser

# terminal 2 — Vite dev server (proxies /api and /ws to port 8537)
cd web && npm run dev
```

Open the Vite URL it prints. To browse the UI without a server, any screen can
run on the built-in fixture state with `?fixture=1` (e.g.
`http://localhost:5173/?fixture=1#/world`).

---

## Controls

| Context | Input | Action |
|---|---|---|
| At sea | `↑ ↓ ← →` / `WASD` / numpad | Sail one tile; hold to repeat (Step mode) or set the helm heading (Helm mode) |
| At sea | `Space` | Wait one day (Step mode) / stop the ship (Helm mode) |
| At sea | `[` / `]` | Cycle sail trim: furled → reefed → normal → full |
| At sea | Click a water tile | Sail there (server-validated route); land/ice is refused |
| At sea | `Z` | Toggle camera zoom (near / wide) |
| At sea / port | `Tab` | Open the Chart; `Tab`/`Esc` closes it |
| At sea / port | `C` / `F` | Intel window: captain tab / fleet tab |
| At sea | Right-click a fleet / a port | Fleet picker (inspect, talk, attack) / port context menu |
| Anywhere | `Esc` | Back / close the current screen |
| Anywhere | `L` | Toggle Chinese ↔ English |
| Battle | `1`–`4` | Pick shot type (round / chain / armor-piercing / grape) |
| Battle | `Tab` | Cycle your ships |
| Battle | Mouse drag / wheel / `Home` | Pan / zoom / fit the battle view |
| Battle | `Esc` | Battle menu (retreat, surrender, …) |
| Saves | In port | Save / Load from the port hub (3 slots) |

All other interaction is on-screen: facility buttons, dialogs, list rows.

---

## Saves

- Three slots at `~/.sailage/saves/save_{1..3}.json` (a normal user-profile
  location; nothing is written into the repository).
- Set `SAILAGE_HOME` to relocate the profile directory (used by the tests).
- Save format version **1**. There is deliberately **no migration chain**:
  a save written by any other version is refused rather than half-loaded.

---

## Data-driven content and i18n

Every piece of content — ports, goods, ships, equipment, officers, captains,
quests, discoveries — is JSON under `data/`. Adding content is a data-only
change; no code edit is required. Every player-facing string, including UI
labels, is a `{"zh": "...", "en": "..."}` pair in a data file; the build's
audit fails on a hardcoded string.

The world raster, the shoreline/distance fields and `web/public/tiles/**` are
**generated artifacts** (built by `tools/build_*.py`), never hand-edited.

---

## Tests and gates

Run from the repository root, with the server dependencies installed:

```bash
# 1. Data / raster / art / tile validation (groups 1–15)
python3 tools/validate_data.py

# 2. Server contract suites
server/.venv/bin/python -m pytest server/tests -q

# 3. Web build, i18n/styling/layout audit, design tokens
cd web && npm run build && npm run audit && npm run tokens:check && cd ..

# 4. Headless end-to-end demo loop (new game → trade → sail → save/load)
server/.venv/bin/python -m server.demo_loop_smoke
```

Optional checks for tool-built artifacts are byte-identical rebuilds, e.g.
`python3 tools/build_web_tiles.py --check` or `python3 tools/build_world.py
--check`.

---

## Documentation

The full specification ships with the game — read it in this order:

| Doc | Contents |
|---|---|
| `docs/00-OVERVIEW.md` | vision, pillars, phases, glossary, the demo loop |
| `docs/10-DATA-SCHEMA.md` | JSON contract, i18n rule, validator spec, locked content lists |
| `docs/90-ARCHITECTURE.md` | web-era architecture (§0: server/client split, WS protocol, HTTP shape, save v1); §1–§13 are the retired Godot-era history |
| `docs/20-WORLD-AND-SAILING.md` | grid, movement, clock, consumption, morale, weather |
| `docs/30-PORTS-AND-TRADE.md` | facilities, price formulas, trade flows |
| `docs/40-SHIPS-AND-FLEET.md` | ships, repair/refit, cargo and fleet maths |
| `docs/50-CHARACTER-AND-PROGRESSION.md` | nations, stats, XP, officers, titles |
| `docs/60-COMBAT.md` | battle engine, duels, AI, NPC fleet ecology |
| `docs/70-QUESTS-DISCOVERY-ENDGAME.md` | quests, discoveries, piracy, tournaments, retirement |
| `docs/80-UI-UX.md` | screens, navigation, HUD, palette, input |
| `docs/IMPLEMENT-WebMigration.md` | the M0–M6 delivery ledger and acceptance records |

`AGENTS.md` is the short contributor/agent rulebook (i18n, data-first,
server-authoritative, concrete numbers).

---

## License and provenance

Third-party and provenance notes live in [`LICENSE-NOTES.md`](LICENSE-NOTES.md):
game data is first-party, nothing is vendored from copyrighted datasets, and
the one vendored code component (the YoYoPixel pixel-art engine under
`tools/yoyopixel/`) is MIT-licensed with its license text alongside. There is
no project-level license file in this repository yet — treat it as
all-rights-reserved until one is added.
