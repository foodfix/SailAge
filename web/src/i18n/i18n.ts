/**
 * The translation functions — same contract as autoload/i18n.gd:
 *   t(l10n, locale)    -> the locale's text, or "<missing>" + console.error
 *   tKey(key, locale)  -> the ui_strings entry, or "<key>" + console.error
 *   fmt(key, values)   -> tKey() plus {name} substitution
 */
import { uiStrings, type UiStrings } from "./strings";
import type { L10nString, Locale } from "./types";

let table: UiStrings = uiStrings;

/** Swap in a table fetched from the M2 server (loader.ts). */
export function installUiStrings(next: UiStrings): void {
  table = next;
}

export function t(l10n: L10nString, locale: Locale): string {
  const text = l10n[locale];
  if (typeof text === "string" && text.length > 0) return text;
  console.error(`I18n: missing '${locale}' locale in L10nString ${JSON.stringify(l10n)}`);
  return "<missing>";
}

export function tKey(key: string, locale: Locale): string {
  const l10n = table[key];
  if (!l10n) {
    console.error(`I18n: unknown ui_strings key '${key}'`);
    return `<${key}>`;
  }
  return t(l10n, locale);
}

export type L10nValue = string | number | L10nString;

export function fmt(
  key: string,
  values: Record<string, L10nValue>,
  locale: Locale,
): string {
  let text = tKey(key, locale);
  for (const [name, value] of Object.entries(values)) {
    const rendered =
      typeof value === "object" ? t(value, locale) : String(value);
    text = text.split(`{${name}}`).join(rendered);
  }
  return text;
}
