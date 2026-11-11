#!/usr/bin/env node
/**
 * audit.mjs — the SPA's mechanical gates (docs/IMPLEMENT-WebMigration.md
 * §9 M7; docs/80-UI-UX.md §4.9.1 "styling boundary"; docs/90-ARCHITECTURE.md §0.2).
 *
 * Two mechanical rules, no dependencies, empty allowlist:
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
 *  (b) styling boundary — only theme/ + kit/ author visual CSS.
 *     ・hex colors, rgb()/hsl(), and px literals are rejected in any TS/TSX
 *       file outside web/src/theme/** and web/src/kit/**.
 *     ・inline style object literals in TSX may carry layout keys only
 *       (left/top/width/height/zIndex/transform/…) or `--sa-*` custom
 *       properties; visual props (background,color,border,radius,padding,
 *       font*, box-shadow, filter, opacity, …) are rejected.
 *     ・a screen's structural CSS module (a CSS file under
 *       web/src/screens/) may author flex/grid/geometry rules, but every
 *       colour, font family and px literal in it must still be a token
 *       reference — hex literals, color functions, px literals and
 *       `font-family` declarations are rejected there too.
 *     The visual CSS authoring points are theme/tokens.css (generated),
 *     theme/base.css and kit/kit.css. (The M7 retirement: the former rule
 *     (c) — ui_layout.json id coverage — died with the file.)
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

function screenCssFiles() {
  const dir = join(SRC, "screens");
  try {
    return walk(dir).filter((file) => file.endsWith(".css"));
  } catch {
    return [];
  }
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
/* (b) styling boundary                                                    */
/* ---------------------------------------------------------------------- */

const HEX = /#[0-9a-fA-F]{3,8}\b/;
const COLOR_FN = /\b(?:rgb|rgba|hsl|hsla)\s*\(/;
const PX = /\b\d+(?:\.\d+)?px\b/;

function auditStyling(files) {
  for (const file of files) {
    const rel = relative(SRC, file);
    if (rel.startsWith("theme" + sep) || rel.startsWith("kit" + sep)) continue;

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
      if (PX.test(line)) {
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

/**
 * Structural screen CSS: flex/grid/geometry allowed, but colours, fonts
 * and px literals stay token-only (80-* §4.9.1).
 */
function auditScreenCss(files) {
  for (const file of files) {
    const raw = readFileSync(file, "utf8");
    const source = raw
      .replace(/\/\*[\s\S]*?\*\//g, (match) => match.replace(/[^\n]/g, " "))
      .replace(/(^|[^:"'])\/\/[^\n]*/g, (match, lead) => lead + " ".repeat(match.length - lead.length));
    const lines = source.split("\n");
    lines.forEach((line, index) => {
      if (HEX.test(line)) {
        fail("style", file, index + 1, "hex colour in a screen CSS module (use a --sailage-* token)");
      }
      if (COLOR_FN.test(line)) {
        fail("style", file, index + 1, "color function in a screen CSS module (use a token)");
      }
      if (PX.test(line)) {
        fail("style", file, index + 1, "px literal in a screen CSS module (use a --sailage-* token)");
      }
      if (/\bfont-family\s*:/.test(line)) {
        fail("style", file, index + 1, "font-family in a screen CSS module (theme owns the stack)");
      }
    });
  }
}

/* ---------------------------------------------------------------------- */

const files = codeFiles();
auditI18n(files);
auditStyling(files);
auditScreenCss(screenCssFiles());

if (violations.length > 0) {
  console.error(`audit: ${violations.length} violation(s)`);
  for (const v of violations) {
    console.error(`  [${v.rule}] ${v.file}${v.line ? `:${v.line}` : ""} — ${v.message}`);
  }
  process.exit(1);
}

console.log(
  "audit: OK — i18n allowlist empty (0 hardcoded strings), styling boundary clean " +
    "(theme+kit own visuals; screen CSS is structural, token-only)",
);
