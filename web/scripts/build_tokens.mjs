#!/usr/bin/env node
/**
 * build_tokens.mjs — deterministic CSS-token generator for the M3 shell.
 *
 * Source of truth: web/src/theme/palette.json (extracted from the retired
 * scripts/palette.gd at the M6 cutover; docs/80-UI-UX.md §4.8 remains the
 * locked design source). Output: web/src/theme/tokens.css.
 *
 *   node scripts/build_tokens.mjs            # write the file
 *   node scripts/build_tokens.mjs --check    # byte-compare, exit 1 on drift
 *
 * Rules (the raster-family discipline):
 *   * no dependencies — node stdlib only;
 *   * every `const NAME := Color("#rrggbb")` becomes
 *     `--sailage-<name-kebab>: #rrggbb;`
 *   * every numeric `const NAME := <expr>` becomes
 *     `--sailage-<name-kebab>: <value>px;` (the chrome grid is the only
 *     chrome pixel source, 80-* §4.8);
 *   * output bytes depend only on palette.json — two runs are byte-identical.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const PALETTE = join(HERE, "..", "src", "theme", "palette.json");
const OUT = join(HERE, "..", "src", "theme", "tokens.css");

const KEBAB = (name) => name.toLowerCase().replace(/_/g, "-");

/** Tiny integer expression evaluator: + - * / parentheses and constants. */
function evalNumeric(expr, consts) {
  let i = 0;
  const s = expr.replace(/\s+/g, "");

  function parsePrimary() {
    if (s[i] === "(") {
      i += 1;
      const v = parseExpr();
      if (s[i] !== ")") throw new Error(`unbalanced '(' in ${expr}`);
      i += 1;
      return v;
    }
    const start = i;
    while (i < s.length && /[0-9]/.test(s[i])) i += 1;
    if (start !== i) return Number(s.slice(start, i));
    const nameStart = i;
    while (i < s.length && /[A-Za-z0-9_]/.test(s[i])) i += 1;
    const name = s.slice(nameStart, i);
    if (!(name in consts)) throw new Error(`unknown constant '${name}' in ${expr}`);
    return consts[name];
  }

  function parseTerm() {
    let v = parsePrimary();
    for (;;) {
      if (s[i] === "*") {
        i += 1;
        v *= parsePrimary();
      } else if (s[i] === "/") {
        i += 1;
        v = Math.trunc(v / parsePrimary());
      } else {
        return v;
      }
    }
  }

  function parseExpr() {
    let v = parseTerm();
    for (;;) {
      if (s[i] === "+") {
        i += 1;
        v += parseTerm();
      } else if (s[i] === "-") {
        i += 1;
        v -= parseTerm();
      } else {
        return v;
      }
    }
  }

  const value = parseExpr();
  if (i !== s.length) throw new Error(`trailing input in ${expr}`);
  return value;
}

function generate() {
  const palette = JSON.parse(readFileSync(PALETTE, "utf8"));
  if (palette.version !== 1) {
    throw new Error(`unsupported palette.json version ${palette.version}`);
  }
  const colors = Object.entries(palette.colors ?? {});
  const numbers = Object.entries(palette.numbers ?? {});
  for (const [name, hex] of colors) {
    if (!/^#[0-9a-f]{6}$/i.test(String(hex))) {
      throw new Error(`palette color ${name} is not a #rrggbb hex`);
    }
  }
  for (const [name, value] of numbers) {
    if (!Number.isInteger(value)) {
      throw new Error(`palette size ${name} is not an integer`);
    }
  }

  const lines = [];
  lines.push("/*");
  lines.push(" * GENERATED FILE — DO NOT EDIT.");
  lines.push(" * Source: web/src/theme/palette.json (docs/80-UI-UX.md §4.8).");
  lines.push(" * Regenerate: node scripts/build_tokens.mjs");
  lines.push(" * Check:      node scripts/build_tokens.mjs --check");
  lines.push(" *");
  lines.push(` * ${colors.length} color tokens + ${numbers.length} sizing tokens.`);
  lines.push(" */");
  lines.push(":root {");
  lines.push("  /* Palette colors (append-only, §4.8). */");
  for (const [name, hex] of colors) {
    lines.push(`  --sailage-${KEBAB(name)}: ${hex};`);
  }
  lines.push("");
  lines.push("  /* Chrome sizing grid (§4.8: 1 tile = CHROME_TILE). */");
  for (const [name, value] of numbers) {
    lines.push(`  --sailage-${KEBAB(name)}: ${value}px;`);
  }
  lines.push("}");
  lines.push("");
  return { text: lines.join("\n"), colors: colors.length, numbers: numbers.length };
}

const { text, colors, numbers } = generate();

if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(OUT, "utf8");
  } catch {
    console.error(`tokens: ${OUT} is missing — run node scripts/build_tokens.mjs`);
    process.exit(1);
  }
  if (current !== text) {
    console.error(
      `tokens: ${OUT} is stale (${colors} colors / ${numbers} sizes expected) — ` +
        "run node scripts/build_tokens.mjs and commit the result",
    );
    process.exit(1);
  }
  console.log(`tokens: OK (${colors} colors, ${numbers} sizes)`);
} else {
  writeFileSync(OUT, text);
  console.log(`tokens: wrote ${OUT} (${colors} colors, ${numbers} sizes)`);
}
