/**
 * Browser tile cache for the committed pyramids (docs/10-DATA-SCHEMA.md §6.8).
 *
 * `web/public/tiles/<source>/<z>/<x>_<y>.png`, 256 px tiles, z 0–3. Images
 * load lazily; the renderer's RAF loop simply redraws until the bitmap is
 * available (no callbacks, no layout work). One cache is shared per source so
 * the sailing view and the HUD minimap reuse each other's bitmaps.
 */
import { PYRAMID_TILE_PX, type TileSource } from "./constants";

interface Entry {
  image: HTMLImageElement;
  failed: boolean;
}

/** ~two screens of z0 tiles plus the minimap crop; evicts oldest loads. */
const MAX_CACHED_TILES = 128;

export class TilePyramid {
  private readonly entries = new Map<string, Entry>();

  constructor(readonly source: TileSource) {}

  /**
   * The loaded bitmap for one level tile, or null while it is still loading
   * (the caller draws its fallback and retries next frame).
   */
  image(level: number, tx: number, ty: number): HTMLImageElement | null {
    const key = `${level}/${tx}_${ty}`;
    const found = this.entries.get(key);
    if (found) {
      if (found.failed) return null;
      return found.image.complete && found.image.naturalWidth > 0 ? found.image : null;
    }
    if (tx < 0 || ty < 0) return null;
    const image = new Image();
    const entry: Entry = { image, failed: false };
    image.decoding = "async";
    image.onerror = () => {
      entry.failed = true;
      console.error(`Tiles: missing ${this.source} tile ${key} — retrying in 5s`);
      // A dropped response over a slow link must not kill the chunk for the
      // session: drop the entry so the next frame retries the load.
      window.setTimeout(() => {
        if (this.entries.get(key) === entry) this.entries.delete(key);
      }, 5000);
    };
    image.src = `${import.meta.env.BASE_URL}tiles/${this.source}/${level}/${tx}_${ty}.png`;
    this.entries.set(key, entry);
    this.trim();
    return null;
  }

  /** Warm the neighbouring tiles outside the visible window (one-tile apron). */
  prefetch(level: number, tx0: number, tx1: number, ty0: number, ty1: number): void {
    const maxX = Math.ceil(Math.ceil(4320 / 2 ** level) / PYRAMID_TILE_PX) - 1;
    const maxY = Math.ceil(Math.ceil(2160 / 2 ** level) / PYRAMID_TILE_PX) - 1;
    for (let ty = Math.max(0, ty0); ty <= Math.min(maxY, ty1); ty += 1) {
      for (let tx = Math.max(0, tx0); tx <= Math.min(maxX, tx1); tx += 1) {
        this.image(level, tx, ty);
      }
    }
  }

  private trim(): void {
    if (this.entries.size <= MAX_CACHED_TILES) return;
    for (const key of this.entries.keys()) {
      if (this.entries.size <= MAX_CACHED_TILES) break;
      const entry = this.entries.get(key);
      if (entry && entry.image.complete) this.entries.delete(key);
    }
  }
}

const pyramids = new Map<TileSource, TilePyramid>();

/** The shared cache for one pyramid source. */
export function pyramid(source: TileSource): TilePyramid {
  let found = pyramids.get(source);
  if (!found) {
    found = new TilePyramid(source);
    pyramids.set(source, found);
  }
  return found;
}
