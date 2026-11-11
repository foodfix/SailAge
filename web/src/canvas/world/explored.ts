/**
 * The §8.1 `explored_tiles` decoder (docs/90-ARCHITECTURE.md §8.1;
 * docs/20-WORLD-AND-SAILING.md §4.12).
 *
 * The save/frame value is standard base64 of 6-byte little-endian runs
 * `[u16 y][u16 x0][u16 len−1]`, sorted by `(y, x0)`. The minimap renders
 * explored tiles only; this module keeps the decode tiny and cache-friendly.
 */
import { GRID_WIDTH } from "./constants";

interface Run {
  y: number;
  x0: number;
  x1: number;
}

export interface ExploredSet {
  has(x: number, y: number): boolean;
  readonly size: number;
}

const EMPTY: ExploredSet = { has: () => false, size: 0 };

function decodeBase64(text: string): Uint8Array {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function decodeExplored(text: string): ExploredSet {
  if (!text) return EMPTY;
  let bytes: Uint8Array;
  try {
    bytes = decodeBase64(text);
  } catch {
    console.error("Explored: invalid base64 payload");
    return EMPTY;
  }
  if (bytes.length === 0 || bytes.length % 6 !== 0) {
    console.error(`Explored: run payload length ${bytes.length} is not a multiple of 6`);
    return EMPTY;
  }

  const rows = new Map<number, Run[]>();
  let count = 0;
  for (let offset = 0; offset < bytes.length; offset += 6) {
    const y = bytes[offset] | (bytes[offset + 1] << 8);
    const x0 = bytes[offset + 2] | (bytes[offset + 3] << 8);
    const length = (bytes[offset + 4] | (bytes[offset + 5] << 8)) + 1;
    const x1 = Math.min(x0 + length - 1, GRID_WIDTH - 1);
    let list = rows.get(y);
    if (!list) {
      list = [];
      rows.set(y, list);
    }
    list.push({ y, x0, x1 });
    count += x1 - x0 + 1;
  }

  const cache = new Map<number, Run[]>();
  return {
    size: count,
    has(x: number, y: number): boolean {
      const wrapped = ((x % GRID_WIDTH) + GRID_WIDTH) % GRID_WIDTH;
      let runs = cache.get(y);
      if (!runs) {
        runs = rows.get(y) ?? [];
        cache.set(y, runs);
      }
      for (const run of runs) {
        if (wrapped >= run.x0 && wrapped <= run.x1) return true;
      }
      return false;
    },
  };
}
