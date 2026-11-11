/**
 * Configurable loader. Dev/build today import the JSON statically (single
 * source, no duplication); when FastAPI serves the SPA the same functions
 * fetch from the configurable base URL (default: same origin).
 *
 * M2 contract note: the server owns data/ — the client never writes it.
 */
import { installUiStrings } from "./i18n";
import { uiStrings, type UiStrings } from "./strings";
import type { L10nString } from "./types";

export interface DataSourceConfig {
  /** e.g. "" (same origin) or "http://127.0.0.1:8000". */
  baseUrl: string;
}

function joinUrl(baseUrl: string, path: string): string {
  return `${baseUrl.replace(/\/$/, "")}/${path.replace(/^\//, "")}`;
}

async function fetchJson<T>(url: string): Promise<T> {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`I18n: GET ${url} failed (${response.status})`);
  }
  return (await response.json()) as T;
}

/** Load ui_strings.json from the server and install it. */
export async function loadUiStrings(config: DataSourceConfig): Promise<UiStrings> {
  const raw = await fetchJson<Record<string, unknown>>(
    joinUrl(config.baseUrl, "data/ui_strings.json"),
  );
  const table = Object.fromEntries(
    Object.entries(raw).filter(([key]) => key !== "version"),
  ) as UiStrings;
  installUiStrings(table);
  return table;
}

/** Generic content JSON fetch (ports/goods/ships/... when a screen needs names). */
export async function loadContentFile<T>(config: DataSourceConfig, name: string): Promise<T> {
  return fetchJson<T>(joinUrl(config.baseUrl, `data/${name}.json`));
}

/** The bundled table — what the fixture build uses. */
export function bundledUiStrings(): UiStrings {
  return uiStrings;
}

export type { L10nString };
