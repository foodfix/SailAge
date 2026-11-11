/**
 * I18n React layer: context + hook. The provider owns the locale store and
 * exposes bound t / tKey / fmt functions. Screens never read the raw JSON.
 */
import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import { fmt as fmtRaw, t as tRaw, tKey as tKeyRaw, type L10nValue } from "./i18n";
import { localeStore } from "./store";
import type { L10nString, Locale } from "./types";

export interface I18nApi {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  toggleLocale: () => void;
  t: (l10n: L10nString) => string;
  tKey: (key: string) => string;
  fmt: (key: string, values: Record<string, L10nValue>) => string;
}

const I18nContext = createContext<I18nApi | null>(null);

export interface I18nProviderProps {
  children: ReactNode;
  /** Called after the store changes — the shell forwards it as POST /api/locale. */
  onLocaleChange?: (locale: Locale) => void;
}

export function I18nProvider({ children, onLocaleChange }: I18nProviderProps) {
  const locale = useSyncExternalStore(localeStore.subscribe, localeStore.get, localeStore.get);

  const setLocale = useCallback(
    (next: Locale) => {
      if (next === localeStore.get()) return;
      localeStore.set(next);
      onLocaleChange?.(next);
    },
    [onLocaleChange],
  );

  const toggleLocale = useCallback(() => {
    const next: Locale = localeStore.get() === "en" ? "zh" : "en";
    setLocale(next);
  }, [setLocale]);

  const api = useMemo<I18nApi>(
    () => ({
      locale,
      setLocale,
      toggleLocale,
      t: (l10n: L10nString) => tRaw(l10n, locale),
      tKey: (key: string) => tKeyRaw(key, locale),
      fmt: (key: string, values: Record<string, L10nValue>) => fmtRaw(key, values, locale),
    }),
    [locale, setLocale, toggleLocale],
  );

  return <I18nContext.Provider value={api}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nApi {
  const api = useContext(I18nContext);
  if (!api) throw new Error("useI18n must be used inside <I18nProvider>");
  return api;
}
