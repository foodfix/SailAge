/**
 * Typed sprite registry — the 317 Phase-10 UI PNGs under assets/ui/**
 * stay plain static assets (90-ARCHITECTURE.md §0.1 decision 3; the
 * Godot wrapper is discarded, not the bitmaps).
 *
 * Vite compiles the files into content-hashed URLs at build time and
 * serves them from disk in dev; the sprite ids below are the basenames
 * the kit contracts use (`good_{id}`, `eq_{id}`, `role_{id}`,
 * `facility_{id}`, plus the flat ui/fx/marker/hull/portrait families).
 * An absent id is the flat fallback (80-* §4.9) — no crash.
 */

export type SpriteId = string;

type Urls = Record<string, string>;

function collect(): Urls {
  const iconModules = import.meta.glob("../../../assets/ui/icons64/*.png", { eager: true }) as Urls;
  const tokenModules = import.meta.glob("../../../assets/ui/tokens64/*.png", { eager: true }) as Urls;
  const otherModules = import.meta.glob(
    [
      "../../../assets/ui/hulls/*.png",
      "../../../assets/ui/markers64/*.png",
      "../../../assets/ui/fx/*.png",
      "../../../assets/ui/terrain/*.png",
      "../../../assets/ui/portraits/*.png",
    ],
    { eager: true },
  ) as Urls;

  const urlOf = (value: unknown): string =>
    typeof value === "string" ? value : ((value as { default: string }).default ?? "");
  const map: Urls = {};
  const add = (url: string, id: string) => {
    if (!(id in map)) map[id] = url;
  };
  for (const [path, url] of Object.entries(iconModules)) {
    add(urlOf(url), basename(path));
  }
  for (const [path, url] of Object.entries(tokenModules)) {
    add(urlOf(url), `facility_${basename(path)}`);
  }
  for (const [path, url] of Object.entries(otherModules)) {
    add(urlOf(url), basename(path));
  }
  return map;
}

function basename(path: string): string {
  const file = path.split("/").pop() ?? path;
  return file.replace(/\.png$/, "");
}

let registry: Urls | null = null;
const warned = new Set<string>();

function table(): Urls {
  if (!registry) registry = collect();
  return registry;
}

export function spriteUrl(id: SpriteId): string | undefined {
  return table()[id];
}

export function hasSprite(id: SpriteId): boolean {
  return spriteUrl(id) !== undefined;
}

/** One warning per absent id; the flat fallback is the visible cue. */
export function reportMissingSprite(id: SpriteId): void {
  if (warned.has(id)) return;
  warned.add(id);
  console.error(`Sprite: unknown id '${id}' — flat fallback`);
}

export function spriteIds(): SpriteId[] {
  return Object.keys(table()).sort();
}
