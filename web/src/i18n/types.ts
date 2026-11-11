/**
 * i18n primitives — the web transplant of autoload/i18n.gd
 * (docs/90-ARCHITECTURE.md §0.2; docs/80-UI-UX.md §4.4).
 *
 * Contract (identical to the Godot I18n):
 *   * every player-facing string is `{"zh": "...", "en": "..."}`;
 *   * missing locale  => console.error + visible "<missing>";
 *   * missing ui key  => console.error + visible "<key>";
 *   * there is no silent fallback chain.
 */

export type Locale = "zh" | "en";

export const LOCALES: readonly Locale[] = ["zh", "en"] as const;
export const DEFAULT_LOCALE: Locale = "en";

export interface L10nString {
  zh: string;
  en: string;
}

export function isLocale(value: unknown): value is Locale {
  return value === "zh" || value === "en";
}
