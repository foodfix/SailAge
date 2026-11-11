/**
 * HUD minimap (docs/20-WORLD-AND-SAILING.md §4.12; docs/80-UI-UX.md §4.5).
 *
 * A wrap-aware 128×96-tile crop around the fleet at 2 px/tile (256×192 px),
 * explored tiles only. Terrain comes from the same committed `world` pyramid
 * as the sailing view; known ports and the fleet are 2×2 px dots.
 */
import type { ExploredSet } from "./explored";
import {
  GRID_HEIGHT,
  MINIMAP_PX_PER_TILE,
  MINIMAP_TILES_H,
  MINIMAP_TILES_W,
} from "./constants";
import { clamp, wrapDeltaX, wrapX, type CameraView, type Vec2 } from "./geometry";
import { nationColor, portById } from "./ports";
import { pyramid } from "./pyramid";
import { drawTileLayer } from "./tiles";
import { palette } from "./tokens";

export interface MinimapInput {
  fleet: Vec2;
  knownPorts: readonly string[];
  explored: ExploredSet;
  devicePixelRatio: number;
}

let scratch: HTMLCanvasElement | null = null;

function scratchCanvas(): HTMLCanvasElement {
  if (!scratch) {
    scratch = document.createElement("canvas");
    scratch.width = MINIMAP_TILES_W;
    scratch.height = MINIMAP_TILES_H;
  }
  return scratch;
}

export function drawMinimap(canvas: HTMLCanvasElement, input: MinimapInput): void {
  const dpr = Math.max(1, input.devicePixelRatio);
  const width = MINIMAP_TILES_W * MINIMAP_PX_PER_TILE;
  const height = MINIMAP_TILES_H * MINIMAP_PX_PER_TILE;
  if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(height * dpr)) {
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
  }
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.imageSmoothingEnabled = false;

  const originX = input.fleet.x - MINIMAP_TILES_W / 2;
  const originY = clamp(
    input.fleet.y - MINIMAP_TILES_H / 2,
    0,
    Math.max(0, GRID_HEIGHT - MINIMAP_TILES_H),
  );
  const camera: CameraView = {
    originX,
    originY,
    centerX: input.fleet.x,
    centerY: input.fleet.y,
    tilePx: 1,
    width: MINIMAP_TILES_W,
    height: MINIMAP_TILES_H,
  };

  const tileCanvas = scratchCanvas();
  const tileCtx = tileCanvas.getContext("2d", { willReadFrequently: true });
  if (!tileCtx) return;
  tileCtx.setTransform(1, 0, 0, 1, 0, 0);
  tileCtx.clearRect(0, 0, MINIMAP_TILES_W, MINIMAP_TILES_H);
  drawTileLayer(tileCtx, pyramid("world"), camera, 0, palette.sea());

  // Explored tiles only (§4.12): mask everything the run has not seen.
  const image = tileCtx.getImageData(0, 0, MINIMAP_TILES_W, MINIMAP_TILES_H);
  const data = image.data;
  for (let py = 0; py < MINIMAP_TILES_H; py += 1) {
    const worldY = Math.round(originY) + py;
    for (let px = 0; px < MINIMAP_TILES_W; px += 1) {
      const worldX = wrapX(Math.round(originX) + px);
      if (!input.explored.has(worldX, worldY)) {
        data[(py * MINIMAP_TILES_W + px) * 4 + 3] = 0;
      }
    }
  }
  tileCtx.putImageData(image, 0, 0);

  ctx.fillStyle = palette.panelBg();
  ctx.fillRect(0, 0, width, height);
  ctx.drawImage(tileCanvas, 0, 0, width, height);

  const dot = MINIMAP_PX_PER_TILE;
  for (const portId of input.knownPorts) {
    const port = portById(portId);
    if (!port) continue;
    const dx = wrapDeltaX(port.shore.x, input.fleet.x);
    const col = Math.round(MINIMAP_TILES_W / 2) + dx;
    const row = Math.round(MINIMAP_TILES_H / 2) + (port.shore.y - input.fleet.y);
    if (col < 0 || row < 0 || col >= MINIMAP_TILES_W || row >= MINIMAP_TILES_H) continue;
    ctx.fillStyle = port.nationId
      ? (nationColor(port.nationId) ?? palette.portNeutral())
      : palette.portNeutral();
    ctx.fillRect(col * MINIMAP_PX_PER_TILE, row * MINIMAP_PX_PER_TILE, dot, dot);
  }

  // The fleet dot is always at the crop centre (column 64, row 48).
  ctx.fillStyle = palette.text();
  ctx.fillRect(
    Math.round(MINIMAP_TILES_W / 2) * MINIMAP_PX_PER_TILE,
    Math.round(MINIMAP_TILES_H / 2) * MINIMAP_PX_PER_TILE,
    dot,
    dot,
  );
}
