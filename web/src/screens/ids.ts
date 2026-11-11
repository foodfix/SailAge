/**
 * The locked 32-screen set (80-UI-UX.md §4.1; formerly `layout/types.ts`,
 * re-homed here when the ui_layout rect layer was retired at M7).
 */
export const SCREEN_IDS = [
  // The Phase-11 pilot eight — the port family.
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

export function isScreenId(value: string): value is ScreenId {
  return (SCREEN_IDS as readonly string[]).includes(value);
}
