/**
 * Battle camera — pure world↔screen math (docs/80-UI-UX.md §4.7.1).
 *
 * The 48×30 world at 64 px is 3072×1920; the camera shows the 1920×928
 * viewport at 0.45×–1.5×. All functions are pure and pinned by the
 * constants: clamp (never show outside the world unless letterboxed),
 * zoom anchored at the cursor, the `[fit]` view, and the minimap mapping
 * (4 px per cell).
 */
import {
  GRID_H,
  GRID_W,
  MINIMAP_H,
  MINIMAP_PX_PER_CELL,
  MINIMAP_W,
  TILE_PX,
  VIEW_H,
  VIEW_W,
  WORLD_H,
  WORLD_W,
  ZOOM_FIT,
  ZOOM_MAX,
  ZOOM_MIN,
} from "./constants";
import type { BattleCamera, Vec2 } from "./types";

export function clamp(value: number, low: number, high: number): number {
  return Math.max(low, Math.min(high, value));
}

export function fitCamera(): BattleCamera {
  return { cx: WORLD_W / 2, cy: WORLD_H / 2, zoom: ZOOM_FIT };
}

/** Clamps a camera centre so the world fills the viewport (or stays centred). */
export function clampCamera(camera: BattleCamera): BattleCamera {
  const zoom = clamp(camera.zoom, ZOOM_MIN, ZOOM_MAX);
  const halfW = VIEW_W / (2 * zoom);
  const halfH = VIEW_H / (2 * zoom);
  const cx = WORLD_W <= halfW * 2 ? WORLD_W / 2 : clamp(camera.cx, halfW, WORLD_W - halfW);
  const cy = WORLD_H <= halfH * 2 ? WORLD_H / 2 : clamp(camera.cy, halfH, WORLD_H - halfH);
  return { cx, cy, zoom };
}

/** World pixels at the viewport's top-left corner. */
export function cameraOrigin(camera: BattleCamera): Vec2 {
  return {
    x: camera.cx - VIEW_W / (2 * camera.zoom),
    y: camera.cy - VIEW_H / (2 * camera.zoom),
  };
}

/** Design-px position of a (fractional) cell. */
export function worldToScreen(camera: BattleCamera, cell: Vec2): Vec2 {
  const origin = cameraOrigin(camera);
  return {
    x: (cell.x + 0.5) * TILE_PX * camera.zoom - origin.x * camera.zoom,
    y: (cell.y + 0.5) * TILE_PX * camera.zoom - origin.y * camera.zoom,
  };
}

/** The cell under a design-px point (may be outside the grid). */
export function screenToCell(camera: BattleCamera, point: Vec2): Vec2 {
  const origin = cameraOrigin(camera);
  return {
    x: (point.x + origin.x * camera.zoom) / (TILE_PX * camera.zoom) - 0.5,
    y: (point.y + origin.y * camera.zoom) / (TILE_PX * camera.zoom) - 0.5,
  };
}

/** Zooms around a design-px anchor (the cursor), keeping its world point put. */
export function zoomAt(camera: BattleCamera, anchor: Vec2, nextZoom: number): BattleCamera {
  const zoom = clamp(nextZoom, ZOOM_MIN, ZOOM_MAX);
  const before = screenToCell(camera, anchor);
  const unclamped: BattleCamera = { cx: camera.cx, cy: camera.cy, zoom };
  const after = screenToCell(unclamped, anchor);
  return clampCamera({
    cx: camera.cx + (before.x - after.x) * TILE_PX,
    cy: camera.cy + (before.y - after.y) * TILE_PX,
    zoom,
  });
}

/** Pans by a design-px delta (drag). */
export function panCamera(camera: BattleCamera, dx: number, dy: number): BattleCamera {
  return clampCamera({
    cx: camera.cx - dx / camera.zoom,
    cy: camera.cy - dy / camera.zoom,
    zoom: camera.zoom,
  });
}

/** Follow camera centred on a cell (the acting/selected unit). */
export function followCamera(cell: Vec2, zoom: number): BattleCamera {
  return clampCamera({
    cx: (cell.x + 0.5) * TILE_PX,
    cy: (cell.y + 0.5) * TILE_PX,
    zoom,
  });
}

/** Minimap design-px origin (top-right corner, §4.7.1). */
export function minimapOrigin(): Vec2 {
  return { x: VIEW_W - MINIMAP_W - 8, y: 8 };
}

/** Cell → minimap design-px point (4 px/cell, top-left origin of the widget). */
export function minimapToScreen(cell: Vec2): Vec2 {
  return {
    x: (cell.x + 0.5) * MINIMAP_PX_PER_CELL,
    y: (cell.y + 0.5) * MINIMAP_PX_PER_CELL,
  };
}

/** Minimap point (widget-relative) → clamped grid cell. */
export function minimapToCell(point: Vec2): Vec2 {
  return {
    x: clamp(Math.floor(point.x / MINIMAP_PX_PER_CELL), 0, GRID_W - 1),
    y: clamp(Math.floor(point.y / MINIMAP_PX_PER_CELL), 0, GRID_H - 1),
  };
}

/** The minimap widget's rect in design px. */
export function minimapRect(): { x: number; y: number; w: number; h: number } {
  const origin = minimapOrigin();
  return { x: origin.x, y: origin.y, w: MINIMAP_W, h: MINIMAP_H };
}
