/**
 * Terrain-art layer for the S3 sailing canvas (docs/80-UI-UX.md §4.5
 * "web realization", §4.8 PixelLab coast program, §9.2; docs/10-DATA-SCHEMA.md
 * §6.7).
 *
 * The world map renders the committed terrain tileset instead of the flat
 * raster pyramid:
 *
 *  - every cell stamps `terrain_coast_wang_0` (painted water) as the base;
 *  - land cells stamp their coast tile per the §4.8 water-flanking rule
 *    (index bits = non-flanked corners, NW·8 + NE·4 + SW·2 + SE·1; interior
 *    15 = wang_15 through its 8 dihedral transforms as the §9.2 cell-hash
 *    variant pool; index 0 never occurs in the built world and falls back
 *    to the interior variant);
 *  - water cells carry the depth wash — factor 1.0 at ≤ 6 tiles to 0.6 at
 *    ≥ 10 tiles of distance-to-land (§6.7), realized as a per-cell PANEL_BG
 *    wash at alpha (1−factor)·0.75;
 *  - reef/ice cells stamp their sprites over the water base.
 *
 * Cell kinds and distances read the committed z0 pyramids (`world` — one
 * raster pixel per tile; `dist_land` — §6.7's `d = (R·256+G)/4096`), decoded
 * once per 256-tile chunk into cached arrays. Images still loading simply
 * draw nothing this frame — the RAF loop retries, the tiles.ts protocol.
 */
import { GRID_HEIGHT, GRID_WIDTH, PYRAMID_TILE_PX, VIEW_TILE_MARGIN } from "./constants";
import { mod, wrapX, type CameraView } from "./geometry";
import { pyramid, type TilePyramid } from "./pyramid";
import { spriteUrl } from "../../assets/sprites";
import { palette } from "./tokens";

/* ---------------------------------------------------------------------- */
/* Sprite cache                                                            */
/* ---------------------------------------------------------------------- */

const WANG_ID = (index: number) => `terrain_coast_wang_${index}`;

const sprites = new Map<string, HTMLImageElement>();

function sprite(id: string): HTMLImageElement | null {
  const hit = sprites.get(id);
  if (hit !== undefined) return hit.complete && hit.naturalWidth > 0 ? hit : null;
  const url = spriteUrl(id);
  if (!url) return null;
  const image = new Image();
  image.decoding = "async";
  image.src = url;
  sprites.set(id, image);
  return null;
}

/* ---------------------------------------------------------------------- */
/* Chunk decode — kinds from the world z0 pyramid, distance from dist_land */
/* ---------------------------------------------------------------------- */

/** §6.2 legend kinds, in raster palette order (~ . # ^ I). */
const KIND_SEA = 0;
const KIND_COAST = 1;
const KIND_LAND = 2;
const KIND_REEF = 3;
const KIND_ICE = 4;

interface ChunkArrays {
  /** One kind per pixel (tile), 256×256. */
  kinds: Uint8Array;
  /** Distance-to-land in tiles, clamped to 16 (§6.7), 256×256. */
  dist: Uint8Array;
}

const chunkCache = new Map<string, ChunkArrays | null>();
/** ~two screens of chunks per source pair; evicts the oldest decodes. */
const MAX_CACHED_CHUNKS = 96;

/** Last draw's warm-up state (the ?dev=1 world chip reads it). */
const terrainStatsInfo = { ready: false, chunks: 0, sprites: 0 };

/** Dev diagnostics for the terrain layer. */
export function terrainStats(): { ready: boolean; chunks: number; sprites: number } {
  return { ...terrainStatsInfo };
}
const scratch = document.createElement("canvas");
scratch.width = PYRAMID_TILE_PX;
scratch.height = PYRAMID_TILE_PX;
const scratchCtx = scratch.getContext("2d", { willReadFrequently: true });

/** The five locked legend hexes as RGB, read from the generated tokens. */
function legendColor(tokenValue: string): [number, number, number] | null {
  const hex = tokenValue.trim();
  if (!/^#[0-9a-fA-F]{6}$/.test(hex)) return null;
  return [
    parseInt(hex.slice(1, 3), 16),
    parseInt(hex.slice(3, 5), 16),
    parseInt(hex.slice(5, 7), 16),
  ];
}

function decodeChunk(
  world: TilePyramid,
  dist: TilePyramid,
  tx: number,
  ty: number,
): ChunkArrays | null {
  const key = `${tx}_${ty}`;
  if (chunkCache.has(key)) return chunkCache.get(key) ?? null;
  const worldImage = world.image(0, tx, ty);
  const distImage = dist.image(0, tx, ty);
  if (!worldImage || !distImage || !scratchCtx) return null;
  if (!worldImage.complete || worldImage.naturalWidth === 0) return null;
  if (!distImage.complete || distImage.naturalWidth === 0) return null;

  // Kind per pixel: nearest legend hex (the z0 slice carries the raster's
  // own 5-colour palette, so exact matches dominate; the nearest pass keeps
  // resampled edge tiles deterministic).
  const legend = [
    legendColor(palette.sea()),
    legendColor(palette.coastSea()),
    legendColor(palette.land()),
    legendColor(palette.reef()),
    legendColor(palette.ice()),
  ];
  scratchCtx.clearRect(0, 0, PYRAMID_TILE_PX, PYRAMID_TILE_PX);
  scratchCtx.drawImage(worldImage, 0, 0);
  const pixels = scratchCtx.getImageData(0, 0, PYRAMID_TILE_PX, PYRAMID_TILE_PX).data;
  const kinds = new Uint8Array(PYRAMID_TILE_PX * PYRAMID_TILE_PX);
  for (let index = 0; index < kinds.length; index += 1) {
    const r = pixels[index * 4];
    const g = pixels[index * 4 + 1];
    const b = pixels[index * 4 + 2];
    let bestKind = KIND_SEA;
    let bestDist = Number.POSITIVE_INFINITY;
    for (let kind = 0; kind < legend.length; kind += 1) {
      const color = legend[kind];
      if (!color) continue;
      const dr = r - color[0];
      const dg = g - color[1];
      const db = b - color[2];
      const d = dr * dr + dg * dg + db * db;
      if (d < bestDist) {
        bestDist = d;
        bestKind = kind;
      }
    }
    kinds[index] = bestKind;
  }

  // §6.7 decode: d = (R·256 + G) / 4096 tiles, saturated at 16; store ×16.
  scratchCtx.clearRect(0, 0, PYRAMID_TILE_PX, PYRAMID_TILE_PX);
  scratchCtx.drawImage(distImage, 0, 0);
  const distPixels = scratchCtx.getImageData(0, 0, PYRAMID_TILE_PX, PYRAMID_TILE_PX).data;
  const distOut = new Uint8Array(PYRAMID_TILE_PX * PYRAMID_TILE_PX);
  for (let index = 0; index < distOut.length; index += 1) {
    const value = (distPixels[index * 4] * 256 + distPixels[index * 4 + 1]) / 4096;
    distOut[index] = Math.round(Math.min(value, 16) * 16);
  }

  const chunk: ChunkArrays = { kinds, dist: distOut };
  chunkCache.set(key, chunk);
  if (chunkCache.size > MAX_CACHED_CHUNKS) {
    const oldest = chunkCache.keys().next().value;
    if (oldest !== undefined && oldest !== key) chunkCache.delete(oldest);
  }
  return chunk;
}

function kindAt(chunk: ChunkArrays, cellX: number, cellY: number, ty: number): number {
  // The camera origin is fractional while the fleet glides (§4.2 render-only
  // interpolation) — a fractional cell must sample the same tile as its
  // floor, never a typed-array hole (which would read as "not land" and
  // blank the whole coastline while under way, the M7.1 live report).
  const localX = Math.floor(mod(cellX, PYRAMID_TILE_PX));
  const localY = Math.floor(cellY - ty * PYRAMID_TILE_PX);
  if (localY < 0 || localY >= PYRAMID_TILE_PX) return KIND_SEA;
  return chunk.kinds[localY * PYRAMID_TILE_PX + localX];
}

function distAt(chunk: ChunkArrays, cellX: number, cellY: number, ty: number): number {
  const localX = Math.floor(mod(cellX, PYRAMID_TILE_PX));
  const localY = Math.floor(cellY - ty * PYRAMID_TILE_PX);
  if (localY < 0 || localY >= PYRAMID_TILE_PX) return 16 * 16;
  return chunk.dist[localY * PYRAMID_TILE_PX + localX] / 16;
}

/** Kind of one world cell (0 = sea, 1 = coastal sea, 2 = land, 3 = reef, 4 = ice). */
function cellKind(
  chunkGetter: (tx: number, ty: number) => ChunkArrays | null,
  cellX: number,
  cellY: number,
): number {
  const wrapped = ((cellX % GRID_WIDTH) + GRID_WIDTH) % GRID_WIDTH;
  const tx = Math.floor(wrapped / PYRAMID_TILE_PX);
  const ty = Math.floor(cellY / PYRAMID_TILE_PX);
  const chunk = chunkGetter(tx, ty);
  if (!chunk) return -1;
  return kindAt(chunk, wrapped, cellY, ty);
}

/** §6.7 distance-to-land of one world cell in tiles (16 when unknown). */
function cellDist(
  chunkGetter: (tx: number, ty: number) => ChunkArrays | null,
  cellX: number,
  cellY: number,
): number {
  const wrapped = ((cellX % GRID_WIDTH) + GRID_WIDTH) % GRID_WIDTH;
  const tx = Math.floor(wrapped / PYRAMID_TILE_PX);
  const ty = Math.floor(cellY / PYRAMID_TILE_PX);
  const chunk = chunkGetter(tx, ty);
  if (!chunk) return 16;
  return distAt(chunk, wrapped, cellY, ty);
}

/* ---------------------------------------------------------------------- */
/* The coast program                                                       */
/* ---------------------------------------------------------------------- */

/** §4.5 depth wash: factor 1.0 at ≤ 6 tiles, 0.6 at ≥ 10, linear between. */
function depthFactor(distanceTiles: number): number {
  if (distanceTiles <= 6) return 1;
  if (distanceTiles >= 10) return 0.6;
  return 1 - ((distanceTiles - 6) / 4) * 0.4;
}

/** The direction deltas (N E S W) used by the water-flanking rule. */
const FLANK_NEIGHBOURS: Record<number, [number, number][]> = {
  // corner bit → the three adjacent map neighbours that flank it
  8: [[0, -1], [-1, 0], [-1, -1]], // NW ← N / W / NW
  4: [[0, -1], [1, 0], [1, -1]], // NE ← N / E / NE
  2: [[0, 1], [-1, 0], [-1, 1]], // SW ← S / W / SW
  1: [[0, 1], [1, 0], [1, 1]], // SE ← S / E / SE
};

/** §9.2 cell hash — the variant picker. */
function cellHash(cellX: number, cellY: number): number {
  return (((cellX * 31 + cellY * 17) % 8) + 8) % 8;
}

/** The 8 dihedral transforms of one sprite, around the cell centre. */
function drawDihedral(
  ctx: CanvasRenderingContext2D,
  image: HTMLImageElement,
  x: number,
  y: number,
  size: number,
  variant: number,
): void {
  // variant 0 identity; 1..3 rotate ×90°; 4..7 mirror then rotate.
  const angle = ((variant % 4) * Math.PI) / 2;
  ctx.save();
  ctx.translate(x + size / 2, y + size / 2);
  if (variant >= 4) ctx.scale(-1, 1);
  ctx.rotate(angle);
  ctx.drawImage(image, -size / 2, -size / 2, size, size);
  ctx.restore();
}

/* ---------------------------------------------------------------------- */
/* The layer                                                               */
/* ---------------------------------------------------------------------- */

/** One wrapped visible run of the camera window (the tiles.ts seam rule). */
function wrappedRuns(originX: number, viewTilesW: number): { start: number; length: number; offset: number }[] {
  const wrapped = wrapX(originX);
  const first = Math.min(viewTilesW, GRID_WIDTH - wrapped);
  const runs = [{ start: wrapped, length: first, offset: 0 }];
  if (viewTilesW > first) {
    runs.push({ start: 0, length: viewTilesW - first, offset: first });
  }
  return runs;
}

export interface TerrainDrawResult {
  /** True once every sampled chunk is decoded (the first frames warm up). */
  ready: boolean;
}

const seaFallback = () => palette.sea();

/**
 * Draw the terrain layer for the camera window (the world-map base; the
 * marker/port overlays render on top per markers.ts).
 *
 * Always paints the sea colour first, so a cold cache (or a chunk that
 * never decodes) shows water instead of a void. Any throw is contained:
 * the layer logs once and reports not-ready, and the renderer falls back
 * to the flat raster for that frame (the pre-M7.1 look) — the sailing
 * screen can never end up blank because of this layer.
 */
export function drawTerrain(
  ctx: CanvasRenderingContext2D,
  camera: CameraView,
): TerrainDrawResult {
  ctx.fillStyle = seaFallback();
  ctx.fillRect(0, 0, camera.width, camera.height);
  try {
    const result = drawTerrainInner(ctx, camera);
    terrainStatsInfo.ready = result.ready;
    terrainStatsInfo.chunks = chunkCache.size;
    terrainStatsInfo.sprites = sprites.size;
    return result;
  } catch (err) {
    if (!terrainFailureLogged) {
      terrainFailureLogged = true;
      console.error(`Terrain: layer draw failed — flat raster fallback (${String(err)})`);
    }
    (window as unknown as { __saTerrainErr?: string }).__saTerrainErr = String(err).slice(0, 220);
    terrainStatsInfo.ready = false;
    return { ready: false };
  }
}

let terrainFailureLogged = false;

function drawTerrainInner(
  ctx: CanvasRenderingContext2D,
  camera: CameraView,
): TerrainDrawResult {
  const world = pyramid("world");
  const dist = pyramid("dist_land");
  const chunkFor = (tx: number, ty: number) => {
    const key = `${tx}_${ty}`;
    if (chunkCache.has(key)) return chunkCache.get(key) ?? null;
    return decodeChunk(world, dist, tx, ty);
  };

  const water = sprite(WANG_ID(0));
  const interior = sprite(WANG_ID(15));
  const reef = sprite("terrain_reef_0");
  const ice0 = sprite("terrain_polar_ice_0");
  const ice1 = sprite("terrain_polar_ice_1");

  const viewTilesW = camera.width / camera.tilePx;
  const viewTilesH = camera.height / camera.tilePx;
  const tilePx = camera.tilePx;
  const originY = camera.originY;
  const cellY0 = Math.max(0, Math.floor(originY));
  const cellY1 = Math.min(GRID_HEIGHT - 1, Math.ceil(originY + viewTilesH) - 1);

  // Warm the chunk cache for the window (+ one-tile apron) before drawing.
  const runs = wrappedRuns(camera.originX - VIEW_TILE_MARGIN, viewTilesW + VIEW_TILE_MARGIN * 2);
  for (const run of runs) {
    for (let cellY = Math.max(0, cellY0 - 1); cellY <= Math.min(GRID_HEIGHT - 1, cellY1 + 1); cellY += 1) {
      for (let step = 0; step < run.length; step += PYRAMID_TILE_PX) {
        const cellX = run.start + step;
        chunkFor(Math.floor(cellX / PYRAMID_TILE_PX), Math.floor(cellY / PYRAMID_TILE_PX));
        chunkFor(Math.floor((wrapX(cellX - 1)) / PYRAMID_TILE_PX), Math.floor(cellY / PYRAMID_TILE_PX));
        chunkFor(Math.floor((wrapX(cellX + 1)) / PYRAMID_TILE_PX), Math.floor(cellY / PYRAMID_TILE_PX));
      }
    }
  }

  const wash = palette.panelBg();
  let ready = true;

  ctx.imageSmoothingEnabled = false;
  for (const run of wrappedRuns(camera.originX, viewTilesW)) {
    for (let cellY = cellY0; cellY <= cellY1; cellY += 1) {
      for (let step = 0; step < Math.ceil(run.length); step += 1) {
        // The cell this screen column shows — floored, because a gliding
        // camera makes the run origin fractional (the sampled tile may not).
        const worldX = Math.floor(run.start + step);
        const screenX = run.offset * tilePx + step * tilePx;
        const screenY = (cellY - originY) * tilePx;

        const kind = cellKind(chunkFor, worldX, cellY);
        if (kind < 0) {
          ready = false;
          continue;
        }

        // Water base (painted tile) under every cell.
        if (water) ctx.drawImage(water, screenX, screenY, tilePx, tilePx);

        if (kind === KIND_LAND) {
          // §4.8 water-flanking rule: index bits = non-flanked corners.
          let flanked = 0;
          for (const [bit, neighbours] of Object.entries(FLANK_NEIGHBOURS)) {
            const bitValue = Number(bit);
            for (const [dx, dy] of neighbours) {
              const neighbour = cellKind(chunkFor, worldX + dx, cellY + dy);
              if (neighbour === KIND_SEA || neighbour === KIND_COAST || neighbour < 0) {
                flanked |= bitValue;
                break;
              }
            }
          }
          const index = (~flanked) & 0xf;
          if (index === 15 || index === 0 || !sprite(WANG_ID(index))) {
            if (interior) drawDihedral(ctx, interior, screenX, screenY, tilePx, cellHash(worldX, cellY));
          } else {
            const coast = sprite(WANG_ID(index));
            if (coast) ctx.drawImage(coast, screenX, screenY, tilePx, tilePx);
          }
        } else if (kind === KIND_REEF) {
          if (reef) ctx.drawImage(reef, screenX, screenY, tilePx, tilePx);
        } else if (kind === KIND_ICE) {
          const ice = cellHash(worldX, cellY) % 2 === 0 ? ice0 : ice1;
          if (ice) ctx.drawImage(ice, screenX, screenY, tilePx, tilePx);
        } else {
          // Water: the §6.7 depth wash (deep water flattens toward PANEL_BG).
          const distance = cellDist(chunkFor, worldX, cellY);
          const washAlpha = (1 - depthFactor(distance)) * 0.75;
          if (washAlpha > 0.01 && wash) {
            ctx.globalAlpha = washAlpha;
            ctx.fillStyle = wash;
            ctx.fillRect(screenX, screenY, tilePx, tilePx);
            ctx.globalAlpha = 1;
          }
        }
      }
    }
  }

  return { ready };
}

/** The port overlay sprite id for a nation id ("" → neutral). */
export function portSpriteId(nationId: string): string {
  return `terrain_port_${nationId || "neutral"}`;
}
