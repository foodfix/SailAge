/**
 * Palette access for the canvas layers.
 *
 * The locked palette lives once in `scripts/palette.gd` and is generated into
 * `src/theme/tokens.css` (docs/80-UI-UX.md §4.8.9/§4.9); the canvas reads the
 * generated custom properties at runtime so no colour literal exists outside
 * the theme layer (the M3 styling-audit rule).
 */

const cache = new Map<string, string>();

/** One `--sailage-*` token value (cached; empty string when absent). */
export function token(name: string): string {
  const key = `--sailage-${name}`;
  const hit = cache.get(key);
  if (hit !== undefined) return hit;
  const value =
    typeof window === "undefined"
      ? ""
      : getComputedStyle(document.documentElement).getPropertyValue(key).trim();
  cache.set(key, value);
  return value;
}

/** Named palette roles used by the world renderer (80-* §4.8 hex table). */
export const palette = {
  sea: () => token("sea"),
  coastSea: () => token("coast-sea"),
  land: () => token("land"),
  reef: () => token("reef"),
  ice: () => token("ice"),
  panelBg: () => token("panel-bg"),
  panelLine: () => token("panel-line"),
  text: () => token("text"),
  accent: () => token("accent"),
  good: () => token("good"),
  warn: () => token("warn"),
  bad: () => token("bad"),
  portInk: () => token("port-ink"),
  portNeutral: () => token("port-neutral"),
  hullPlayer: () => token("hull-player"),
  hullPlayerHi: () => token("hull-player-hi"),
};
