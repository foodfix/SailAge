/**
 * The battle canvas's normalized view model.
 *
 * The only input is the frozen `battle_tick` frame (docs/90-ARCHITECTURE.md
 * §0.3) — plus the §8.1 `state` slice for the day and the player's gunnery
 * (selector gating). Nothing here derives a rule: hull maxima and crew
 * maxima are content data (`data/ship_types.json`), the rest is frame data.
 */
import type { Direction8, Weather } from "../../state/types";

export type BattleSide = "player" | "enemy";

export interface Vec2 {
  x: number;
  y: number;
}

export interface BattleShip {
  id: string;
  side: BattleSide;
  /** Hull id (`data/ship_types.json`) — selects the token art. */
  kind: string;
  /** Current cell (fractional only while the renderer glides). */
  position: Vec2;
  velocity: Vec2;
  heading8: Direction8;
  /** Bucket index 0..7 in the §4.8.6 order (what the wire carries). */
  headingBucket: number;
  hull: number;
  hullMax: number;
  crew: number;
  crewMax: number;
  /** Side morale (the frame repeats it per ship, §0.3). */
  morale: number;
  /** The round at which each side is loaded again (§4.4a). */
  reload: { port: number; starboard: number };
  alive: boolean;
}

export interface BattleView {
  round: number;
  /** `player` | `enemy` | `over` | `none` (the §0.3 frame's phase). */
  phase: string;
  ships: BattleShip[];
  wind: { dir: Direction8; strength: number };
  weather: Weather;
  ordersDue: boolean;
  /** §0.3 (2026-11-14): the acting unit's ship id ("" when none/over). */
  actingId: string;
  /** The acting player unit's reachable endpoints (the overlay data). */
  moveRange: Vec2[];
}

/** The §4.9b order five-tuple, as the client edits and sends it. */
export interface BattleOrder {
  station: [number, number];
  headingBucket: number;
  speedBand: [number, number];
  assignedTargetId: string | null;
  discipline: boolean;
}

export interface BattleCamera {
  /** World-pixel centre. */
  cx: number;
  cy: number;
  zoom: number;
}
