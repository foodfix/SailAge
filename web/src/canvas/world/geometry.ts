/**
 * Camera + wrap-aware geometry for the S3 canvas (docs/20-WORLD-AND-SAILING.md
 * §4.1/§4.2; docs/80-UI-UX.md §4.5).
 *
 * The map wraps on x at 4320 and is closed at the latitude edges. The camera's
 * x origin is therefore unbounded (the renderer samples across the seam) while
 * y is clamped inside the grid. All functions are pure.
 */
import { GRID_HEIGHT, GRID_WIDTH } from "./constants";

export interface Vec2 {
  x: number;
  y: number;
}

export interface CameraView {
  /** Unwrapped world-tile x at the viewport's left edge (may be < 0 or > 4320). */
  originX: number;
  /** Clamped world-tile y at the viewport's top edge. */
  originY: number;
  /** Unwrapped world-tile x at the viewport's centre (the fleet's x). */
  centerX: number;
  /** Clamped world-tile y at the viewport's centre. */
  centerY: number;
  /** Design px per world tile (64 at near zoom, 32 at wide zoom). */
  tilePx: number;
  /** Viewport size in design px. */
  width: number;
  height: number;
}

export function mod(value: number, modulus: number): number {
  return ((value % modulus) + modulus) % modulus;
}

export function wrapX(x: number): number {
  return mod(x, GRID_WIDTH);
}

export function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

/** Shortest signed x delta on the wrapping axis (a → b). */
export function wrapDeltaX(b: number, a: number): number {
  let delta = mod(b - a, GRID_WIDTH);
  if (delta > GRID_WIDTH / 2) delta -= GRID_WIDTH;
  return delta;
}

export function sameCell(a: Vec2, b: Vec2): boolean {
  return wrapX(a.x) === wrapX(b.x) && a.y === b.y;
}

export function makeCamera(center: Vec2, zoom: number, width: number, height: number, tilePxBase: number): CameraView {
  const tilePx = tilePxBase * zoom;
  const viewTilesW = width / tilePx;
  const viewTilesH = height / tilePx;
  // x wraps: the origin stays unbounded; the seam is drawn, never clamped.
  const originX = center.x - viewTilesW / 2;
  // y is closed: keep the whole view inside [0, GRID_HEIGHT].
  const clampedCenterY = clamp(center.y, viewTilesH / 2, GRID_HEIGHT - viewTilesH / 2);
  const originY = clampedCenterY - viewTilesH / 2;
  return {
    originX,
    originY,
    centerX: center.x,
    centerY: clampedCenterY,
    tilePx,
    width,
    height,
  };
}

/** Screen position of a cell, taking the camera-nearest x representation. */
export function worldToScreen(camera: CameraView, cell: Vec2): Vec2 {
  const x = camera.centerX + wrapDeltaX(cell.x, camera.centerX);
  return {
    x: (x - camera.originX) * camera.tilePx,
    y: (cell.y - camera.originY) * camera.tilePx,
  };
}

/** The world tile under a canvas point (x wrapped into [0, 4320)). */
export function screenToTile(camera: CameraView, point: Vec2): Vec2 {
  const worldX = camera.originX + point.x / camera.tilePx;
  return {
    x: wrapX(Math.floor(worldX)),
    y: clamp(Math.floor(camera.originY + point.y / camera.tilePx), 0, GRID_HEIGHT - 1),
  };
}

/** Split an unwrapped x range into contiguous wrapped runs (no void at the seam). */
export function wrappedSegments(start: number, length: number): { start: number; length: number; offset: number }[] {
  const out: { start: number; length: number; offset: number }[] = [];
  let cursor = start;
  let remaining = length;
  let offset = 0;
  let guard = 0;
  while (remaining > 1e-9 && guard < 8) {
    const wrapped = wrapX(cursor);
    const piece = Math.min(remaining, GRID_WIDTH - wrapped);
    out.push({ start: wrapped, length: piece, offset });
    cursor += piece;
    remaining -= piece;
    offset += piece;
    guard += 1;
  }
  return out;
}
