/**
 * S17 Chart — the locked render constants (docs/80-UI-UX.md §4.6;
 * docs/20-WORLD-AND-SAILING.md §4.11/§4.12; docs/10-DATA-SCHEMA.md §6.1).
 *
 * Everything here is a doc-pinned number or a doc-derived projection. The
 * chart is a pure view of the session: it renders the whole world raster at
 * a fit-to-screen scale, masks it with the explored set, and overlays the
 * known ports + the fleet. Nothing here mutates state.
 */
import { GRID_HEIGHT, GRID_WIDTH } from "../world/constants";

/** §4.6 marker pins: known ports are 3 px nation-coloured dots. */
export const PORT_DOT_PX = 3;
/** §4.6: a capital's dot carries a ring (the debug chart's port layer). */
export const CAPITAL_RING_PX = 2;
/** §4.6: the fleet is a white 5 px square with a black outline. */
export const FLEET_MARKER_PX = 5;
/** §4.6: discovery leads are ACCENT crosses. */
export const LEAD_CROSS_PX = 6;
/** Port-name label size at fit scale (names are shown for known ports). */
export const PORT_LABEL_PX = 11;

/** §6.1: the single world grid, 12 tiles per degree. */
export const TILES_PER_DEGREE = 12;

/**
 * §4.6 role marker letters (the chart prefixes the role's letter itself;
 * the state's `marker_letter` uses the same alphabet, `T c k P p · N X`).
 */
export const ROLE_LETTER: Record<string, string> = {
  trader: "T",
  coaster: "c",
  courier: "k",
  patrol: "P",
  privateer: "p",
  pirate: "·",
  hunter: "N",
  treasure: "X",
};

/**
 * The §7.6 trade-lane ids in legend order (the debug side legend's lane
 * rows; `debug.lane.<id>` names them, §4.7.10).
 */
export const LANE_IDS: readonly string[] = [
  "carreira_da_india",
  "west_indies_flota",
  "manila_galleon",
  "venice_alexandria",
  "venice_flanders",
  "genoa_grain",
  "hanseatic_north",
  "aden_gujarat_malacca",
  "red_sea_india",
  "basra_muscat_india",
  "iceland_cod",
  "grand_banks_cod",
  "canton_country_trade",
  "coromandel_bengal",
  "swahili_coast",
  "pacific_america",
  "west_africa",
  "atlantic_north",
  "brasil_run",
  "brouwer_route",
  "molucca_run",
];

/** The §4.5.2 locked role set, in the side legend's row order. */
export const ROLE_IDS: readonly string[] = [
  "trader",
  "coaster",
  "courier",
  "patrol",
  "privateer",
  "pirate",
  "hunter",
  "treasure",
];

/** §6.1 grid cell containing a WGS84 point (12 tiles/degree). */
export function cellOfLatLon(lat: number, lon: number): { x: number; y: number } {
  const x = Math.floor((lon + 180) * TILES_PER_DEGREE);
  const y = Math.floor((90 - lat) * TILES_PER_DEGREE);
  return {
    x: ((x % GRID_WIDTH) + GRID_WIDTH) % GRID_WIDTH,
    y: Math.max(0, Math.min(GRID_HEIGHT - 1, y)),
  };
}

/** The chart's whole-world fit: the raster is letterboxed, never scrolled. */
export interface ChartMap {
  x: number;
  y: number;
  w: number;
  h: number;
  /** Design px per world tile (≈ 0.44 at the 1920 × 960 map area). */
  pxPerTile: number;
}

/** Fit the 4320 × 2160 grid inside the canvas rect (§4.6 "downscaled to fit"). */
export function chartMap(width: number, height: number): ChartMap {
  const pxPerTile = Math.min(width / GRID_WIDTH, height / GRID_HEIGHT);
  const w = GRID_WIDTH * pxPerTile;
  const h = GRID_HEIGHT * pxPerTile;
  return { x: (width - w) / 2, y: (height - h) / 2, w, h, pxPerTile };
}
