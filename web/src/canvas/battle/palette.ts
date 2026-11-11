/**
 * Palette access for the battle canvas layers.
 *
 * Colours live once in the generated `theme/tokens.css` (docs/80-UI-UX.md
 * §4.8/§4.9); the canvas reads the custom properties at runtime so no
 * colour literal exists outside the theme layer (the M3 styling audit).
 */

const cache = new Map<string, string>();

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

export const palette = {
  sea: () => token("sea"),
  coastSea: () => token("coast-sea"),
  foam: () => token("foam"),
  panelBg: () => token("panel-bg"),
  panelLine: () => token("panel-line"),
  text: () => token("text"),
  accent: () => token("accent"),
  good: () => token("good"),
  warn: () => token("warn"),
  bad: () => token("bad"),
  hullPlayer: () => token("hull-player"),
  hullInk: () => token("hull-ink"),
  hullNeutral: () => token("hull-neutral"),
  hullPirate: () => token("hull-pirate"),
  portInk: () => token("port-ink"),
};
