/**
 * Locale store — "zh" | "en", default "en", persisted in localStorage.
 * A tiny external store so React re-renders every string on a toggle
 * (the Godot locale_changed signal transplant).
 */
import { DEFAULT_LOCALE, isLocale, type Locale } from "./types";

const STORAGE_KEY = "sailage.locale";

function read(): Locale {
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY);
    if (isLocale(stored)) return stored;
  } catch (error) {
    console.error("I18n: localStorage unavailable", error);
  }
  return DEFAULT_LOCALE;
}

let current: Locale = read();
const listeners = new Set<() => void>();

export const localeStore = {
  get(): Locale {
    return current;
  },
  set(locale: Locale): void {
    if (!isLocale(locale)) {
      console.error(`I18n: invalid locale '${String(locale)}' (expected zh or en)`);
      return;
    }
    if (locale === current) return;
    current = locale;
    try {
      window.localStorage.setItem(STORAGE_KEY, locale);
    } catch (error) {
      console.error("I18n: localStorage unavailable", error);
    }
    for (const listener of listeners) listener();
  },
  toggle(): void {
    this.set(current === "en" ? "zh" : "en");
  },
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
};
