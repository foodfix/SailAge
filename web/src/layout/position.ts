import type { CSSProperties } from "react";
import type { TileRect } from "./types";

/**
 * Tiles -> CSS px. The one chrome pixel number is the generated token
 * (--sailage-chrome-tile); nothing here hardcodes 32.
 */
export function tile(value: number): string {
  return `calc(var(--sailage-chrome-tile) * ${value})`;
}

export function positionStyle(rect: TileRect): CSSProperties {
  return {
    left: tile(rect.x),
    top: tile(rect.y),
    width: tile(rect.w),
    height: tile(rect.h),
  };
}

/** Rule 1: a child cannot leave its parent's rect (clamp on apply). */
export function clampInside(rect: TileRect, parent: TileRect): TileRect {
  const w = Math.min(rect.w, parent.w);
  const h = Math.min(rect.h, parent.h);
  return {
    ...rect,
    w,
    h,
    x: Math.max(0, Math.min(rect.x, parent.w - w)),
    y: Math.max(0, Math.min(rect.y, parent.h - h)),
  };
}
