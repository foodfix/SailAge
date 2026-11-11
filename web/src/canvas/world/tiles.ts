/**
 * Tile-layer drawing for the S3 canvas (docs/10-DATA-SCHEMA.md §6.8;
 * docs/80-UI-UX.md §4.5 camera rules).
 *
 * Only the visible window (+ one pyramid tile of prefetch apron) is sampled.
 * Level *z* stores one raster pixel per 2^z world tiles; the whole level grid
 * covers `[0, 4320) × [0, 2160)` with cropped edge tiles, so the seam is
 * rendered by splitting the visible x range into wrapped runs — the pyramid
 * never duplicates wrap content.
 */
import { GRID_HEIGHT, GRID_WIDTH, PYRAMID_TILE_PX, VIEW_TILE_MARGIN } from "./constants";
import { wrapX, type CameraView } from "./geometry";
import type { TilePyramid } from "./pyramid";

export interface TileLayerResult {
  /** The pyramid level actually drawn. */
  level: number;
}

/**
 * Draw one raster level. `fallback` paints the areas whose bitmap has not
 * loaded yet (the sea colour, so the viewport is never void).
 */
export function drawTileLayer(
  ctx: CanvasRenderingContext2D,
  tiles: TilePyramid,
  camera: CameraView,
  level: number,
  fallback: string,
): TileLayerResult {
  if (fallback) {
    ctx.fillStyle = fallback;
    ctx.fillRect(0, 0, camera.width, camera.height);
  }

  const scale = 2 ** level;
  const levelW = Math.ceil(GRID_WIDTH / scale);
  const levelH = Math.ceil(GRID_HEIGHT / scale);
  const viewTilesW = camera.width / camera.tilePx;
  const viewTilesH = camera.height / camera.tilePx;
  const ly0 = camera.originY / scale;
  const ly1 = Math.min((camera.originY + viewTilesH) / scale, levelH);
  if (ly1 <= ly0) return { level };

  const destPerLevelPx = camera.tilePx * scale;
  const ty0 = Math.floor(ly0 / PYRAMID_TILE_PX);
  const ty1 = Math.floor((ly1 - 1e-9) / PYRAMID_TILE_PX);

  const xStart = camera.originX;
  const wrapped = wrapX(xStart);
  // The visible x range may cross the seam at most once (a viewport is far
  // smaller than the world); draw both wrapped runs into one screen span.
  const runs: { start: number; length: number; offset: number }[] = [];
  const first = Math.min(viewTilesW, GRID_WIDTH - wrapped);
  runs.push({ start: wrapped, length: first, offset: 0 });
  if (viewTilesW > first) {
    runs.push({ start: 0, length: viewTilesW - first, offset: first });
  }

  let tx0 = Number.POSITIVE_INFINITY;
  let tx1 = Number.NEGATIVE_INFINITY;

  for (const run of runs) {
    const lx0 = run.start / scale;
    const lx1 = Math.min((run.start + run.length) / scale, levelW);
    if (lx1 <= lx0) continue;
    const runTx0 = Math.floor(lx0 / PYRAMID_TILE_PX);
    const runTx1 = Math.floor((lx1 - 1e-9) / PYRAMID_TILE_PX);
    tx0 = Math.min(tx0, runTx0);
    tx1 = Math.max(tx1, runTx1);

    for (let ty = ty0; ty <= ty1; ty += 1) {
      for (let tx = runTx0; tx <= runTx1; tx += 1) {
        const sx0 = Math.max(lx0, tx * PYRAMID_TILE_PX);
        const sx1 = Math.min(lx1, (tx + 1) * PYRAMID_TILE_PX, levelW);
        const sy0 = Math.max(ly0, ty * PYRAMID_TILE_PX);
        const sy1 = Math.min(ly1, (ty + 1) * PYRAMID_TILE_PX, levelH);
        if (sx1 <= sx0 || sy1 <= sy0) continue;

        const image = tiles.image(level, tx, ty);
        if (!image) continue;

        const dx = (run.offset + (sx0 - run.start / scale)) * camera.tilePx;
        const dy = (sy0 - ly0) * destPerLevelPx;
        ctx.drawImage(
          image,
          sx0 - tx * PYRAMID_TILE_PX,
          sy0 - ty * PYRAMID_TILE_PX,
          sx1 - sx0,
          sy1 - sy0,
          dx,
          dy,
          (sx1 - sx0) * destPerLevelPx,
          (sy1 - sy0) * destPerLevelPx,
        );
      }
    }
  }

  if (Number.isFinite(tx0)) {
    tiles.prefetch(
      level,
      tx0 - VIEW_TILE_MARGIN,
      tx1 + VIEW_TILE_MARGIN,
      ty0 - VIEW_TILE_MARGIN,
      ty1 + VIEW_TILE_MARGIN,
    );
  }
  return { level };
}
