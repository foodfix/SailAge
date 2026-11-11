/**
 * ChartRenderer — the imperative whole-world canvas behind S17
 * (docs/80-UI-UX.md §4.6).
 *
 * Design (the §4.6 pinned approach):
 *  · **source:** the committed `world` tile pyramid
 *    (`web/public/tiles/world/<z>/…`, `10-*` §6.8). The fit view is
 *    ≈ 0.44 design px per world tile, so `selectTileLevel` picks z1 (one
 *    raster pixel per 2 tiles) at dpr 1 and z0 on a HiDPI surface — the
 *    level closest to 1:1, drawn nearest-neighbour (`imageSmoothingEnabled
 *    = false`), never upscaled by the renderer.
 *  · **scale:** the 4320 × 2160 grid is downscaled to fit the map rect
 *    (between the two 64 px bars) exactly — 1920 × 960 at the 1920 × 1080
 *    design canvas, i.e. 4/9 px per tile; the raster is letterboxed, never
 *    scrolled (§4.6 "no scrolling, no per-region tabs"; the dateline is
 *    implicit in the full-world image, no seam crop).
 *  · **fog:** the explored mask (base64 run spans, `20-*` §4.12) is painted
 *    into a device-pixel alpha canvas and the raster is composited through
 *    it; unknown tiles stay `PANEL_BG` (§4.6). The S19 debug row lifts it
 *    (omniscient mode).
 *  · **ports / fleet / leads:** drawn in design px over the raster by
 *    `markers.ts` — known-port dots + i18n names, hinted-discovery ACCENT
 *    crosses, and the white 5 px fleet square.
 *
 * Redraws are event-driven (open, flag change, a `state` frame, locale) plus
 * a bounded RAF retry while tiles load. No per-frame work (§4.6).
 */
import type { Locale } from "../../i18n";
import type { GameSnapshot } from "../../state/types";
import { GRID_HEIGHT, GRID_WIDTH, PYRAMID_TILE_PX, selectTileLevel } from "../world/constants";
import { pyramid } from "../world/pyramid";
import { palette } from "../world/tokens";
import { chartMap, type ChartMap } from "./constants";
import { drawChartOverlays } from "./markers";
import { exploredMask, type ExploredRun } from "./mask";
import type { ChartViewFlags } from "./viewState";

export interface ChartDrawInput {
  snapshot: GameSnapshot;
  locale: Locale;
  flags: ChartViewFlags;
  /** Decoded §8.1 run spans (the fog mask source). */
  runs: readonly ExploredRun[];
  /** The raw `explored_tiles` payload — the mask cache key. */
  exploredKey: string;
}

export interface ChartDrawResult {
  /** True while a pyramid bitmap the draw needs has not finished loading. */
  pending: boolean;
}

let scratch: HTMLCanvasElement | null = null;

function scratchCanvas(width: number, height: number): HTMLCanvasElement {
  if (!scratch) scratch = document.createElement("canvas");
  if (scratch.width !== width || scratch.height !== height) {
    scratch.width = width;
    scratch.height = height;
  }
  return scratch;
}

/**
 * Draw every pyramid tile of one level into the map rect. The level's edge
 * tiles are pre-cropped (§6.8), so the source rect is the tile's own size.
 */
function drawWorld(
  ctx: CanvasRenderingContext2D,
  level: number,
  map: ChartMap,
): boolean {
  const scale = 2 ** level;
  const levelW = Math.ceil(GRID_WIDTH / scale);
  const levelH = Math.ceil(GRID_HEIGHT / scale);
  const coef = map.pxPerTile * scale;
  const cols = Math.ceil(levelW / PYRAMID_TILE_PX);
  const rows = Math.ceil(levelH / PYRAMID_TILE_PX);
  const tiles = pyramid("world");
  let pending = false;

  for (let ty = 0; ty < rows; ty += 1) {
    for (let tx = 0; tx < cols; tx += 1) {
      const image = tiles.image(level, tx, ty);
      if (!image) {
        pending = true;
        continue;
      }
      const sx0 = tx * PYRAMID_TILE_PX;
      const sy0 = ty * PYRAMID_TILE_PX;
      const sx1 = Math.min(sx0 + PYRAMID_TILE_PX, levelW);
      const sy1 = Math.min(sy0 + PYRAMID_TILE_PX, levelH);
      // Both edges of a boundary use the same expression, so adjacent tiles
      // meet exactly (no sub-pixel seams) and the draw stays integer-true.
      const dx0 = map.x + sx0 * coef;
      const dx1 = map.x + sx1 * coef;
      const dy0 = map.y + sy0 * coef;
      const dy1 = map.y + sy1 * coef;
      ctx.drawImage(
        image,
        0,
        0,
        sx1 - sx0,
        sy1 - sy0,
        dx0,
        dy0,
        dx1 - dx0,
        dy1 - dy0,
      );
    }
  }
  return pending;
}

/** Draw the chart into `canvas` (its CSS size is the design-px map rect). */
export function drawChart(
  canvas: HTMLCanvasElement,
  input: ChartDrawInput,
): ChartDrawResult {
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  if (width <= 0 || height <= 0) return { pending: true };

  const dpr = Math.max(1, window.devicePixelRatio || 1);
  const backingW = Math.round(width * dpr);
  const backingH = Math.round(height * dpr);
  if (canvas.width !== backingW || canvas.height !== backingH) {
    canvas.width = backingW;
    canvas.height = backingH;
  }
  const ctx = canvas.getContext("2d");
  if (!ctx) return { pending: false };
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.imageSmoothingEnabled = false;

  // Unknown tiles are PANEL_BG (§4.6): the fog colour is the base fill.
  ctx.fillStyle = palette.panelBg();
  ctx.fillRect(0, 0, width, height);

  const map = chartMap(width, height);
  const level = selectTileLevel(map.pxPerTile, dpr);
  let pending = false;

  if (input.flags.fog && !input.flags.omniscient) {
    // Unknown tiles stay PANEL_BG (§4.6) — an empty explored set means the
    // whole chart is fogged, so no raster layer is drawn at all.
    if (input.runs.length > 0) {
      const layer = scratchCanvas(backingW, backingH);
      const layerCtx = layer.getContext("2d");
      if (!layerCtx) return { pending: false };
      layerCtx.setTransform(1, 0, 0, 1, 0, 0);
      layerCtx.clearRect(0, 0, backingW, backingH);
      layerCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
      layerCtx.imageSmoothingEnabled = false;
      pending = drawWorld(layerCtx, level, map);

      layerCtx.setTransform(1, 0, 0, 1, 0, 0);
      layerCtx.globalCompositeOperation = "destination-in";
      layerCtx.drawImage(
        exploredMask(input.runs, input.exploredKey, backingW, backingH, map, dpr),
        0,
        0,
      );
      layerCtx.globalCompositeOperation = "source-over";

      ctx.drawImage(layer, 0, 0, width, height);
    }
  } else {
    pending = drawWorld(ctx, level, map);
  }

  const hinted: string[] = [];
  for (const [id, known] of Object.entries(input.snapshot.discovery_hints ?? {})) {
    if (known) hinted.push(id);
  }

  drawChartOverlays(ctx, {
    map,
    locale: input.locale,
    knownPorts: input.snapshot.known_ports,
    omniscient: input.flags.omniscient,
    showPorts: input.flags.ports,
    showFleet: input.flags.fleet,
    showDiscovery: input.flags.discovery,
    fleet: input.snapshot.world.position,
    hintedDiscoveries: hinted,
  });

  return { pending };
}
