/**
 * S3 sailing canvas — the locked constants (docs/10-DATA-SCHEMA.md §6.1,
 * §6.8; docs/80-UI-UX.md §4.5, §4.8).
 *
 * Everything here is a doc-pinned number. Render-only numbers (marker sizes,
 * label insets) derive from the tile size; nothing gameplay-facing lives in
 * this file (the tick frames carry the rules' results).
 */
import type { Direction8, SailTrim } from "../../state/types";

/** §6.1: the single world grid, 12 tiles/degree, x wraps at 4320. */
export const GRID_WIDTH = 4320;
export const GRID_HEIGHT = 2160;

/**
 * §4.8 "64-canvas" render pin: the world map draws terrain at 64 design px
 * per tile (the battle grid's 32 px is a separate surface).
 */
export const WORLD_TILE_PX = 64;

/** §4.8 world zoom-out: exactly two camera levels, integer halving. */
export const ZOOM_NEAR = 1;
export const ZOOM_WIDE = 0.5;

/** §6.8 web tile pyramid: 256 px tiles, levels z 0–3. */
export const PYRAMID_TILE_PX = 256;
export const PYRAMID_LEVELS = 4;
export const TILE_SOURCES = ["world", "wind", "currents", "dist_land"] as const;
export type TileSource = (typeof TILE_SOURCES)[number];

/** One tile of apron around the visible window (§4.5 chunk margin spirit). */
export const VIEW_TILE_MARGIN = 1;

/** §4.12 HUD minimap: 128×96-tile crop at 2 px/tile (256×192 px). */
export const MINIMAP_PX_PER_TILE = 2;
export const MINIMAP_TILES_W = 128;
export const MINIMAP_TILES_H = 96;

/** §4.5 camera: the fleet sits at the centre of the viewport. */
export const CAMERA_FOLLOW = true;

/** §4.5 supply readout: `need = ceil(crew / RATION_SIZE)` (20-* §4.10). */
export const RATION_SIZE = 5;

/** §4.15 calendar: 30-day months, 12-month years. */
export const MONTH_DAYS = 30;
export const YEAR_MONTHS = 12;

/** §4.8.6 dir ids in heading8 bucket order (bucket 0 = east). */
export const HEADING8: readonly Direction8[] = ["E", "NE", "N", "NW", "W", "SW", "S", "SE"];

/** The clockwise degrees a north-facing token rotates to face each heading. */
export const HEADING_DEGREES: Record<Direction8, number> = {
  N: 0,
  NE: 45,
  E: 90,
  SE: 135,
  S: 180,
  SW: 225,
  W: 270,
  NW: 315,
};

/** Tile-space delta per 8-dir compass token (y grows southward, §6.1). */
export const DIRECTION_DELTAS: Record<Direction8, { x: number; y: number }> = {
  N: { x: 0, y: -1 },
  NE: { x: 1, y: -1 },
  E: { x: 1, y: 0 },
  SE: { x: 1, y: 1 },
  S: { x: 0, y: 1 },
  SW: { x: -1, y: 1 },
  W: { x: -1, y: 0 },
  NW: { x: -1, y: -1 },
};

/** §4.17 trim order (furled → reefed → normal → full, wraps). */
export const TRIM_ORDER: readonly SailTrim[] = ["furled", "reefed", "normal", "full"];

/** §4.5 morale tier thresholds (excellent/good/strained/dangerous/mutinous). */
export const MORALE_TIERS: readonly { min: number; tier: string }[] = [
  { min: 80, tier: "excellent" },
  { min: 60, tier: "good" },
  { min: 40, tier: "strained" },
  { min: 20, tier: "dangerous" },
  { min: 0, tier: "mutinous" },
];

/** §4.5 supply-day tier thresholds (GOOD ≥ 10, WARN 3–9, BAD ≤ 2). */
export const SUPPLY_GOOD_DAYS = 10;
export const SUPPLY_WARN_DAYS = 3;

/** §4.5 area label: nearest known port within 16 tiles. */
export const AREA_RADIUS = 16;

/** §4.5.2 wake: a 5-tile dashed trail. */
export const WAKE_TILES = 5;

/** §4.5.2: a marker pending more than this many tiles snaps, never glides. */
export const NPC_GLIDE_SNAP_TILES = 24;

/**
 * The pyramid level for a display scale (10-* §6.8).
 *
 * Level z holds one raster pixel per 2^z world tiles; its natural 1:1
 * display is one device pixel per 2^z tiles. The game camera is heavily
 * *magnified* relative to every shipped level (64 design px per tile at
 * near zoom), so the finest level z0 wins at sailing scales; the coarser
 * levels become correct only far out (a whole-world overview). The
 * expression is kept general so a future chart scale needs no new code.
 */
export function selectTileLevel(screenPxPerTile: number, devicePixelRatio: number): number {
  if (!(screenPxPerTile > 0)) return 0;
  const devicePxPerTile = screenPxPerTile * Math.max(devicePixelRatio, 1);
  const ideal = Math.round(-Math.log2(devicePxPerTile));
  return Math.max(0, Math.min(PYRAMID_LEVELS - 1, ideal));
}
