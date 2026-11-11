/**
 * The chart's explored mask (docs/90-ARCHITECTURE.md §8.1 `explored_tiles`;
 * docs/20-WORLD-AND-SAILING.md §4.12).
 *
 * The save/frame value is standard base64 of 6-byte little-endian runs
 * `[u16 y][u16 x0][u16 len−1]`, sorted by `(y, x0)` — the same payload
 * `canvas/world/explored.ts` decodes for the HUD minimap. The chart needs the
 * run *spans* (not the point predicate) to paint the fog mask in one pass, so
 * this module collects them; the predicate helper stays the M4 decoder's job
 * (`Chart.tsx` uses `decodeExplored().size`).
 *
 * The mask is a device-pixel canvas: explored spans are opaque, everything
 * else is transparent, and the renderer composites the world raster through
 * it (`destination-in`). Unknown tiles therefore stay `PANEL_BG` (§4.6).
 */
import { GRID_WIDTH } from "../world/constants";
import { palette } from "../world/tokens";
import type { ChartMap } from "./constants";

export interface ExploredRun {
  y: number;
  x0: number;
  x1: number;
}

/** Decode the §8.1 run payload into spans (empty on a malformed payload). */
export function decodeExploredRuns(text: string): ExploredRun[] {
  if (!text) return [];
  let bytes: Uint8Array;
  try {
    const binary = atob(text);
    bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  } catch {
    console.error("Chart: invalid explored base64 payload");
    return [];
  }
  if (bytes.length === 0 || bytes.length % 6 !== 0) {
    console.error(`Chart: explored run payload length ${bytes.length} is not a multiple of 6`);
    return [];
  }
  const runs: ExploredRun[] = [];
  for (let offset = 0; offset < bytes.length; offset += 6) {
    const y = bytes[offset] | (bytes[offset + 1] << 8);
    const x0 = bytes[offset + 2] | (bytes[offset + 3] << 8);
    const length = (bytes[offset + 4] | (bytes[offset + 5] << 8)) + 1;
    runs.push({ y, x0, x1: Math.min(x0 + length - 1, GRID_WIDTH - 1) });
  }
  return runs;
}

interface MaskCache {
  key: string;
  canvas: HTMLCanvasElement;
}

let cache: MaskCache | null = null;

/**
 * Build (or reuse) the explored mask at the canvas's device resolution.
 * One `fillRect` per run; at least one device pixel per span so sub-pixel
 * rows (the fit view is ≈ 0.44 px/tile) never drop out.
 */
export function exploredMask(
  runs: readonly ExploredRun[],
  key: string,
  width: number,
  height: number,
  map: ChartMap,
  dpr: number,
): HTMLCanvasElement {
  if (cache && cache.key === key && cache.canvas.width === width && cache.canvas.height === height) {
    return cache.canvas;
  }

  const canvas = cache?.canvas ?? document.createElement("canvas");
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
  const ctx = canvas.getContext("2d");
  if (!ctx) return canvas;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalCompositeOperation = "source-over";
  ctx.clearRect(0, 0, width, height);
  // The colour is irrelevant (alpha-only mask); a palette token keeps the
  // "no colour literals outside theme/kit" rule.
  ctx.fillStyle = palette.text();

  for (const run of runs) {
    const x0 = Math.round((map.x + run.x0 * map.pxPerTile) * dpr);
    const x1 = Math.max(x0 + 1, Math.round((map.x + (run.x1 + 1) * map.pxPerTile) * dpr));
    const y0 = Math.round((map.y + run.y * map.pxPerTile) * dpr);
    const y1 = Math.max(y0 + 1, Math.round((map.y + (run.y + 1) * map.pxPerTile) * dpr));
    const dx = Math.max(0, x0);
    const dy = Math.max(0, y0);
    const dw = Math.min(width, x1) - dx;
    const dh = Math.min(height, y1) - dy;
    if (dw <= 0 || dh <= 0) continue;
    ctx.fillRect(dx, dy, dw, dh);
  }

  cache = { key, canvas };
  return canvas;
}
