/**
 * The S10 battle canvas module — public surface.
 *
 * The screen composes `BattleCanvas` inside the layout's world viewport and
 * binds the HUD to the frames; everything else here is the renderer's
 * internals (camera, frame normalization, palette reads).
 */
export { BattleCanvas } from "./BattleCanvas";
export { BattleRenderer } from "./renderer";
export type { BattleScene } from "./renderer";
export {
  ARC_PORT_STEPS,
  ARC_STARBOARD_STEPS,
  ARMOR_PIERCING_GATE,
  BAR_GOOD_RATIO,
  BAR_WARN_RATIO,
  CANNON_RANGE_MAX,
  CHAIN_GATE,
  GRID_H,
  GRID_W,
  HEADING8,
  HEADING_DEGREES,
  MINIMAP_H,
  MINIMAP_PX_PER_CELL,
  MINIMAP_W,
  SPEED_BANDS,
  TILE_PX,
  VIEW_H,
  VIEW_W,
  WORLD_H,
  WORLD_W,
  ZOOM_FIT,
  ZOOM_MAX,
  ZOOM_MIN,
} from "./constants";
export {
  clampCamera,
  fitCamera,
  followCamera,
  minimapRect,
  minimapToCell,
  minimapToScreen,
  panCamera,
  screenToCell,
  worldToScreen,
  zoomAt,
} from "./camera";
export {
  chebyshev,
  headingBucket,
  headingToken,
  livingShips,
  sideMorale,
  speedOf,
  toBattleShip,
  toBattleView,
  windOf,
} from "./frame";
export type { BattleCamera, BattleOrder, BattleShip, BattleSide, BattleView, Vec2 } from "./types";
export { palette } from "./palette";
