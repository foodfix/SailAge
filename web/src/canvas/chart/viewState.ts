/**
 * Chart-local view state (docs/80-UI-UX.md §4.6, §4.6.3).
 *
 * The chart's layer flags are **session-only view state** — they mutate
 * nothing and never enter a save. The one shared symbol is the S19
 * 调试图层 row: `SettingsPanel.debug_overlays` (static, default off,
 * never persisted). Turning it on lifts the chart's fog by default
 * (§4.6 "opening the chart lifts the fog", amended 2026-11-01); `D`
 * toggles back to the explored view while the row is on.
 *
 * A module-level external store so the Settings screen and the Chart screen
 * (two separate routes) see the same flag without touching game state.
 */
import { useSyncExternalStore } from "react";

export interface ChartViewFlags {
  /** The S19 row (§4.6 symbol contract). */
  debugOverlays: boolean;
  /** `D` — ignore the explored set + known-ports filter. */
  omniscient: boolean;
  /** Draw the explored-raster mask (unknown tiles stay PANEL_BG). */
  fog: boolean;
  /** Draw the port dots + known-port names. */
  ports: boolean;
  /** Draw the player fleet marker. */
  fleet: boolean;
  /** Draw the hinted-discovery lead crosses. */
  discovery: boolean;
}

const DEFAULTS: ChartViewFlags = {
  debugOverlays: false,
  omniscient: false,
  fog: true,
  ports: true,
  fleet: true,
  discovery: true,
};

let current: ChartViewFlags = { ...DEFAULTS };
const listeners = new Set<() => void>();

function publish(next: ChartViewFlags): void {
  current = next;
  for (const listener of listeners) listener();
}

export function chartView(): ChartViewFlags {
  return current;
}

export function subscribeChartView(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** Patch one or more layer flags (never persisted). */
export function setChartView(patch: Partial<ChartViewFlags>): void {
  publish({ ...current, ...patch });
}

/** Toggle one layer flag. */
export function toggleChartView(key: keyof ChartViewFlags): void {
  publish({ ...current, [key]: !current[key] });
}

/**
 * The S19 row's setter: on ⇒ the chart opens in omniscient mode (§4.6),
 * off ⇒ back to the explored view. Session-only.
 */
export function setDebugOverlays(on: boolean): void {
  publish({ ...current, debugOverlays: on, omniscient: on });
}

/** The React binding (the chart re-renders when a flag changes). */
export function useChartView(): ChartViewFlags {
  return useSyncExternalStore(subscribeChartView, chartView, chartView);
}
