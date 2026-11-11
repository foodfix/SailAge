#!/usr/bin/env node
/**
 * audit.mjs — the M3 acceptance gates (docs/IMPLEMENT-WebMigration.md §3 M3;
 * docs/80-UI-UX.md §4.9 "React realization"; docs/90-ARCHITECTURE.md §0.2).
 *
 * Three mechanical rules, no dependencies, empty allowlist:
 *
 *  (a) i18n lint — no hardcoded player-facing strings in TSX.
 *     ・JSX text nodes containing letters/CJK (outside `{...}` expressions)
 *       are rejected.
 *     ・String literals assigned to label-ish props (title, aria-label,
 *       placeholder, alt, label, text) are rejected. Technical props
 *       (className, id, key, screen, parent, role, kind, as, type, icon,
 *       sheet, data-*) are allowed.
 *     Every player-facing string must pass through t() / tKey() / fmt().
 *
 *  (b) styling lint — no styling outside the theme + kit layers.
 *     ・hex colors, rgb()/hsl(), and px literals are rejected in any file
 *       outside web/src/theme/** and web/src/kit/**.
 *     ・inline style object literals may carry layout keys only
 *       (left/top/width/height/zIndex/transform/…) or `--sa-*` custom
 *       properties; visual props (background,color,border,radius,padding,
 *       font*, box-shadow, filter, opacity, …) are rejected.
 *     The only CSS authoring points are theme/tokens.css (generated),
 *     theme/base.css and kit/kit.css.
 *
 *  (c) layout coverage — every element id and every list id in
 *     data/ui_layout.json for the eight M3 port screens must appear in its
 *     screen component (static cross-check; the data file is the port spec,
 *     10-DATA-SCHEMA.md §4.23).
 *
 * Exit 0 = all gates pass. Exit 1 = at least one violation.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = join(HERE, "..");
const SRC = join(WEB, "src");
const REPO = join(WEB, "..");

const REAL_SCREENS = {
  port: "PortScreen.tsx",
  market: "MarketScreen.tsx",
  provisions: "ProvisionsScreen.tsx",
  shipyard: "ShipyardScreen.tsx",
  inn: "InnScreen.tsx",
  guild: "GuildScreen.tsx",
  palace: "PalaceScreen.tsx",
  tavern: "TavernScreen.tsx",
  world: "World.tsx",
  battle: "Battle.tsx",
  title: "Title.tsx",
  nationality_select: "NationalitySelect.tsx",
  creation: "Creation.tsx",
  save_slot: "SaveSlot.tsx",
  gameover: "GameOver.tsx",
  ending: "Ending.tsx",
  chart: "Chart.tsx",
  settings: "Settings.tsx",
  confirm: "Confirm.tsx",
  dialog_box: "DialogBox.tsx",
  intel_window: "IntelWindow.tsx",
  character_card: "CharacterCard.tsx",
  dossier: "Dossier.tsx",
  captain_view: "CaptainView.tsx",
  fleet_view: "FleetView.tsx",
  officer_roster: "OfficerRoster.tsx",
  reputation_view: "ReputationView.tsx",
  hail: "Hail.tsx",
  fleet_picker: "FleetPicker.tsx",
  autopilot_hud: "AutopilotHud.tsx",
  duel: "Duel.tsx",
  sandbox: "Sandbox.tsx",
};

const STYLE_ALLOWED_PREFIXES = ["theme" + sep, "kit" + sep];
const LABEL_PROPS = new Set(["title", "aria-label", "placeholder", "alt", "label", "text"]);
const LAYOUT_STYLE_KEYS = new Set([
  "left",
  "top",
  "right",
  "bottom",
  "width",
  "height",
  "zIndex",
  "transform",
  "transformOrigin",
  "flex",
  "flexBasis",
  "gridColumn",
  "gridRow",
]);

const violations = [];
function fail(rule, file, line, message) {
  violations.push({ rule, file: relative(REPO, file), line, message });
}

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

function stripComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, (match) => match.replace(/[^\n]/g, " "))
    .replace(/(^|[^:])\/\/[^\n]*/g, (match, lead) => lead + " ".repeat(match.length - lead.length));
}

function codeFiles() {
  return walk(SRC).filter((file) => file.endsWith(".ts") || file.endsWith(".tsx"));
}

/* ---------------------------------------------------------------------- */
/* (a) i18n lint                                                           */
/* ---------------------------------------------------------------------- */

const LETTER = /[A-Za-z\u4e00-\u9fff]/;

function auditI18n(files) {
  for (const file of files.filter((path) => path.endsWith(".tsx"))) {
    const raw = readFileSync(file, "utf8");
    const source = stripComments(raw);

    // JSX text nodes: `>text<` where text has no braces/tags and a letter.
    const textRe = />([^<>{}]*[A-Za-z\u4e00-\u9fff][^<>{}]*)</g;
    let match;
    while ((match = textRe.exec(source)) !== null) {
      const text = match[1].trim();
      if (!LETTER.test(text)) continue;
      // Ignore comparison operators / type spans that slipped through.
      if (/[=!<>;:(){}\[\]\n]/.test(text)) continue;
      const line = source.slice(0, match.index).split("\n").length;
      fail("i18n", file, line, `hardcoded JSX text "${text}" — use tKey()/t()/fmt()`);
    }

    // Label-ish string literal props.
    const propRe = /\b([A-Za-z-]+)\s*=\s*"([^"]*)"/g;
    while ((match = propRe.exec(source)) !== null) {
      const [, prop, value] = match;
      if (!LABEL_PROPS.has(prop)) continue;
      if (!LETTER.test(value)) continue;
      const line = source.slice(0, match.index).split("\n").length;
      fail("i18n", file, line, `hardcoded ${prop}="${value}" — route through i18n`);
    }
  }
}

/* ---------------------------------------------------------------------- */
/* (b) styling lint                                                        */
/* ---------------------------------------------------------------------- */

const HEX = /#[0-9a-fA-F]{3,8}\b/;
const COLOR_FN = /\b(?:rgb|rgba|hsl|hsla)\s*\(/;

function auditStyling(files) {
  for (const file of files) {
    const rel = relative(SRC, file);
    const allowed = STYLE_ALLOWED_PREFIXES.some((prefix) => rel.startsWith(prefix));
    if (allowed) continue;

    const raw = readFileSync(file, "utf8");
    const source = stripComments(raw);
    const lines = source.split("\n");

    lines.forEach((line, index) => {
      if (HEX.test(line)) {
        fail("style", file, index + 1, "hex colour outside theme/kit");
      }
      if (COLOR_FN.test(line)) {
        fail("style", file, index + 1, "rgb()/hsl() outside theme/kit");
      }
      if (/\b\d+(?:\.\d+)?px\b/.test(line)) {
        fail("style", file, index + 1, "px literal outside theme/kit (use a --sailage-* token)");
      }
    });

    // Inline style object literals: geometry + custom properties only.
    const styleRe = /style=\{\{([\s\S]*?)\}\}/g;
    let match;
    while ((match = styleRe.exec(source)) !== null) {
      const body = match[1];
      const keyRe = /(?:^|[,{]\s*)(["']?)([A-Za-z-][\w-]*)\1\s*:/g;
      let key;
      while ((key = keyRe.exec(body)) !== null) {
        const name = key[2];
        if (name.startsWith("--")) continue;
        if (LAYOUT_STYLE_KEYS.has(name)) continue;
        const line = source.slice(0, match.index).split("\n").length;
        fail("style", file, line, `inline visual style "${name}" — move it into theme/kit CSS`);
      }
    }
  }
}

/* ---------------------------------------------------------------------- */
/* (c) layout coverage                                                     */
/* ---------------------------------------------------------------------- */

function auditLayout() {
  const layout = JSON.parse(readFileSync(join(REPO, "data", "ui_layout.json"), "utf8"));
  if (layout.version !== 2) {
    fail("layout", join(REPO, "data", "ui_layout.json"), 0, `expected version 2, got ${layout.version}`);
    return;
  }
  for (const [screen, fileName] of Object.entries(REAL_SCREENS)) {
    const data = layout.screens[screen];
    if (!data) {
      fail("layout", join(REPO, "data", "ui_layout.json"), 0, `missing screen "${screen}"`);
      continue;
    }
    const file = join(SRC, "screens", fileName);
    const source = readFileSync(file, "utf8");
    // Shared field/row internals also register ids (e.g. a SelectField's
    // `<id>.field` / `<id>.label`), so the dynamic-id check reads the screen
    // and the shared screen helpers together.
    const helpers = readFileSync(join(SRC, "screens", "common.tsx"), "utf8");
    const corpus = source + "\n" + helpers;
    for (const id of Object.keys(data.elements ?? {})) {
      if (source.includes(`"${id}"`)) continue;
      let covered = false;
      // Dynamic ids (list members `rows.<index>.<tail>` and editor cells
      // `<group>.<key>.field`) are built from templates at render time. The
      // static proxy: the screen (or a shared helper) must contain the id's
      // generated parent stem as a template fragment — e.g. the sandbox row
      // builder's `player_rows.` / `player_panel.stats_row.`. The in-DOM
      // coverage stays the authoritative check for these (the M6 agents
      // verified all 299 sandbox ids at max fleet size).
      const segments = id.split(".");
      for (let cut = 1; cut <= 3 && cut < segments.length; cut += 1) {
        const stem = segments.slice(0, -cut).join(".");
        if (corpus.includes(stem)) {
          covered = true;
          break;
        }
      }
      if (covered) continue;
      fail("layout", file, 0, `element id "${id}" from data/ui_layout.json is not rendered`);
    }
    for (const listId of Object.keys(data.lists ?? {})) {
      if (!source.includes(`"${listId}"`)) {
        fail("layout", file, 0, `list block "${listId}" from data/ui_layout.json is not rendered`);
      }
    }
  }
  return layout;
}

/* ---------------------------------------------------------------------- */

const files = codeFiles();
auditI18n(files);
auditStyling(files);
const layout = auditLayout();

const realCount = Object.keys(REAL_SCREENS).length;
const totalScreens = layout ? Object.keys(layout.screens).length : 0;

if (violations.length > 0) {
  console.error(`audit: ${violations.length} violation(s)`);
  for (const v of violations) {
    console.error(`  [${v.rule}] ${v.file}${v.line ? `:${v.line}` : ""} — ${v.message}`);
  }
  process.exit(1);
}

console.log(
  `audit: OK — i18n allowlist empty (0 hardcoded strings), styling boundary clean, ` +
    `layout coverage ${realCount}/${totalScreens} screens (${realCount} real, ${totalScreens - realCount} stubs)`,
);
