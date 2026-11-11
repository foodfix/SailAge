/**
 * data/ui_layout.json v2 — the port spec (docs/10-DATA-SCHEMA.md §4.23;
 * docs/80-UI-UX.md §4.8.9 "React realization").
 *
 * THE DATA FILE IS THE LAYOUT: every static element's rect is in 32 px
 * chrome tiles, parent-relative. The canvas is 60 × 33.75 tiles
 * (1920 × 1080). There are no code defaults underneath a managed screen:
 * a missing row is a loud console.error + the authored (0,0,2,2) fallback.
 */
import rawLayout from "../../../data/ui_layout.json";

export const LAYOUT_VERSION = 2;

export const SHEET_IDS = [
  "panel",
  "button",
  "button_hover",
  "button_pressed",
  "button_focus",
  "field",
  "backdrop",
] as const;
export type SheetId = (typeof SHEET_IDS)[number];

export interface TileRect {
  x: number;
  y: number;
  w: number;
  h: number;
  sheet?: SheetId;
}

export interface ListBlock {
  base: TileRect;
  row_h: number;
  viewport: TileRect;
}

export interface ScreenLayout {
  elements: Record<string, TileRect>;
  lists: Record<string, ListBlock>;
}

interface LayoutFile {
  version: number;
  screens: Record<string, ScreenLayout>;
}

/** The locked 32-screen set (10-* §4.23). */
export const SCREEN_IDS = [
  // The Phase-11 pilot eight — real in M3.
  "port",
  "market",
  "provisions",
  "shipyard",
  "inn",
  "guild",
  "palace",
  "tavern",
  // The title trio.
  "title",
  "nationality_select",
  "creation",
  // The world family.
  "world",
  "chart",
  "hail",
  "fleet_picker",
  "autopilot_hud",
  // The combat trio.
  "battle",
  "sandbox",
  "duel",
  // The shared/modals family.
  "confirm",
  "save_slot",
  "settings",
  "intel_window",
  "dialog_box",
  "dossier",
  "character_card",
  "captain_view",
  "fleet_view",
  "officer_roster",
  "reputation_view",
  "gameover",
  "ending",
] as const;

export type ScreenId = (typeof SCREEN_IDS)[number];

export const REAL_SCREENS = SCREEN_IDS.slice(0, 8);
export const STUB_SCREENS = SCREEN_IDS.slice(8);

export const CANVAS_TILES = { w: 60, h: 33.75 } as const;
export const FALLBACK_TILES: TileRect = { x: 0, y: 0, w: 2, h: 2 };

const layoutFile = rawLayout as LayoutFile;

if (layoutFile.version !== LAYOUT_VERSION) {
  console.error(
    `Layout: data/ui_layout.json version ${String(layoutFile.version)} — expected ${LAYOUT_VERSION}`,
  );
}

export function isScreenId(value: string): value is ScreenId {
  return (SCREEN_IDS as readonly string[]).includes(value);
}

export function getScreenLayout(screen: ScreenId): ScreenLayout {
  const found = layoutFile.screens[screen];
  if (!found) {
    console.error(`Layout: screen '${screen}' is absent from data/ui_layout.json`);
    return { elements: {}, lists: {} };
  }
  return found;
}

/** One element's authored rect, or undefined when the row is missing. */
export function getElementRect(screen: ScreenId, id: string): TileRect | undefined {
  return getScreenLayout(screen).elements[id];
}

export function getListBlock(screen: ScreenId, listId: string): ListBlock | undefined {
  return getScreenLayout(screen).lists[listId];
}
