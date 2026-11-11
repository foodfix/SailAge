/**
 * S10 battle canvas — the locked constants.
 *
 * Every number is a doc pin: the 48×30 grid and deployment bands
 * (docs/60-COMBAT.md §4.2), the 64 px battle tile (docs/80-UI-UX.md §4.7.1
 * "battle-64 amendment"), the camera clamp 0.45×–1.5×, the 192×120
 * minimap at 4 px/cell, the broadside arc buckets and the 1..3 Chebyshev
 * cannon range (§4.4), the §4.6a hook condition inputs. Render-only numbers
 * (bar tier cut-offs, glow radii) are marked as such — no game rule is
 * computed in the client (`90-*` §0.1.5).
 */
import type { Direction8 } from "../../state/types";

/** §4.2: the battle grid is 48×30 cells. */
export const GRID_W = 48;
export const GRID_H = 30;

/** §4.7.1 battle-64: 1 tile = 64 design px, tokens render 1:1. */
export const TILE_PX = 64;
export const WORLD_W = GRID_W * TILE_PX;
export const WORLD_H = GRID_H * TILE_PX;

/**
 * §4.7.1: the camera viewport is 1920 px wide; the authored layout gives
 * the world rows 2..30 of the 34-tile (1080 px) design canvas — the top bar
 * is 2 tiles and the bottom bar 3 (the battle HUD pins, 80-* §4.7.1).
 */
export const CHROME_TILE_PX = 32;
export const TOP_TILES = 2;
export const BOTTOM_TILES = 3;
export const VIEW_W = 60 * CHROME_TILE_PX;
export const VIEW_H = (34 - TOP_TILES - BOTTOM_TILES) * CHROME_TILE_PX;

/** §4.7.1: wheel zoom 0.45×–1.5×, anchored at the cursor. */
export const ZOOM_MIN = 0.45;
export const ZOOM_MAX = 1.5;

/** The `[fit]` view: the whole 3072×1920 world inside the viewport. */
export const ZOOM_FIT = Math.min(VIEW_W / WORLD_W, VIEW_H / WORLD_H);

/** §4.7.1: the minimap is 192×120 px = 4 px/cell over the 48×30 grid. */
export const MINIMAP_W = 192;
export const MINIMAP_H = 120;
export const MINIMAP_MARGIN = 8;
export const MINIMAP_PX_PER_CELL = 4;

/** §4.7.1: the click/drag threshold (design px). */
export const DRAG_THRESHOLD_PX = 4;

/** §4.8.6 heading buckets in order (bucket 0 = east, 22.5° steps). */
export const HEADING8: readonly Direction8[] = ["E", "NE", "N", "NW", "W", "SW", "S", "SE"];

/** Clockwise degrees a north-facing sprite rotates to face each token. */
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

/**
 * §4.4: broadside arcs relative to the attacker's heading8 bucket —
 * port {45°,90°,135°} = steps {1,2,3}, starboard {225°,270°,315°} =
 * steps {5,6,7}. Buckets 0/180 sit in neither arc.
 */
export const ARC_PORT_STEPS: readonly number[] = [1, 2, 3];
export const ARC_STARBOARD_STEPS: readonly number[] = [5, 6, 7];

/** §4.4: the broadside Chebyshev range is 1..3. */
export const CANNON_RANGE_MIN = 1;
export const CANNON_RANGE_MAX = 3;

/** §4.6a: the hook is orthogonal adjacency with both speeds ≤ 1. */
export const HOOK_SPEED_MAX = 1;
export const HOOK_STORM_WEATHER = "storm";

/** §4.4a shot gates (doc pins used for the selector's greyed states). */
export const CHAIN_GATE = 25;
export const ARMOR_PIERCING_GATE = 50;

/** The player order-window speed bands (battle_max_speed ≤ 5, §4.3a). */
export const SPEED_BANDS: readonly (readonly [number, number])[] = [
  [1, 1],
  [1, 2],
  [2, 3],
  [1, 5],
];

/** Render-only hull-bar tier cut-offs (ratio of max durability). */
export const BAR_GOOD_RATIO = 0.5;
export const BAR_WARN_RATIO = 0.25;

/** Render-only token/overlay sizing (fractions of the tile size). */
export const TOKEN_INSET = 0.08;
export const SELECTION_RING = 0.5;
export const ARC_FAN_ALPHA = 0.18;
export const HOOK_RING_RADIUS = 0.46;
