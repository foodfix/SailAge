/**
 * S17 — the Chart screen (docs/80-UI-UX.md §4.6; the §4.9.1 composition;
 * docs/20-WORLD-AND-SAILING.md §4.11/§4.12; docs/90-ARCHITECTURE.md §0.3).
 *
 * A **pure view of the session**: it reads the authoritative snapshot (known
 * ports, the explored set, the fleet position, discovery hints) and renders
 * the whole world downscaled to fit, the explored fog, the known-port dots +
 * i18n names and the fleet marker. It never sends an intent and never mutates
 * state; closing returns to the opener route with the fleet and clock
 * untouched.
 *
 * Tab toggles / Esc closes (§4.3). The chart is a full hash route, so it
 * cannot know its opener from the router alone; per the M6-b contract it
 * defaults to `port` when the run is docked and `world` when it is at sea —
 * which is exactly the §4.2 edge for both hosts (S4 ──Tab──► S17 and
 * S3 ──Tab──► S17). If another surface deep-links the chart, its own back
 * navigation takes precedence (the route is replaceable by the opener).
 *
 * Debug layers: the S19 调试图层 row (`SettingsPanel.debug_overlays`,
 * session-only) unlocks the side legend and lifts the fog by default (§4.6,
 * amended 2026-11-01); `D` toggles back to the explored view. The legend is
 * a HUD plate over the map (§4.9.1); its live rows toggle the session-only
 * layer flags, the undrawn network/role layers render dimmed (reported).
 */
import { useCallback, useEffect, useMemo } from "react";
import { navigate } from "../app/router";
import { useI18n } from "../i18n";
import { useGameState } from "../state/context";
import { decodeExplored } from "../canvas/world";
import { ChartCanvas, LANE_IDS, ROLE_IDS, ROLE_LETTER, toggleChartView, useChartView } from "../canvas/chart";
import type { ChartViewFlags } from "../canvas/chart";
import { Button } from "../kit";
import { Label } from "./common";
import type { ScreenId } from "./ids";
import "./Chart.css";

const SCREEN: ScreenId = "chart";

interface SideHeader {
  kind: "header";
  id: string;
  labelKey: string;
}

interface SideItem {
  kind: "item";
  labelKey: string;
  glyph: string;
  /** A resolved value (counts); otherwise `valueKey` is the i18n state cell. */
  value?: string;
  valueKey?: string;
  /** Live layer rows are interactive; undrawn layers render dimmed (§4.6). */
  live?: { on: boolean; onClick: () => void };
  dim: boolean;
}

type SideEntry = SideHeader | SideItem;

/** The §4.6 side legend, in doc order (network → fleets → layers → census). */
function sideLegend(flags: ChartViewFlags, exploredCount: number): SideEntry[] {
  const entries: SideEntry[] = [];

  entries.push({ kind: "header", id: "sec_title", labelKey: "debug.title" });
  entries.push({ kind: "header", id: "sec_legend_network", labelKey: "debug.legend.network" });

  for (const lane of LANE_IDS) {
    entries.push({
      kind: "item",
      labelKey: `debug.lane.${lane}`,
      glyph: "·",
      valueKey: "settings.debug.off",
      dim: true,
    });
  }
  entries.push({
    kind: "item",
    labelKey: "debug.legend.spokes",
    glyph: "·",
    valueKey: "settings.debug.off",
    dim: true,
  });
  entries.push({
    kind: "item",
    labelKey: "debug.legend.chokepoints",
    glyph: "·",
    valueKey: "settings.debug.off",
    dim: true,
  });

  entries.push({ kind: "header", id: "sec_legend_fleets", labelKey: "debug.legend.fleets" });
  for (const role of ROLE_IDS) {
    entries.push({
      kind: "item",
      labelKey: `debug.role.${role}`,
      glyph: ROLE_LETTER[role] ?? "·",
      valueKey: "settings.debug.off",
      dim: true,
    });
  }
  entries.push({
    kind: "item",
    labelKey: "debug.legend.wrecks",
    glyph: "×",
    valueKey: "settings.debug.off",
    dim: true,
  });
  entries.push({
    kind: "item",
    labelKey: "debug.legend.hunter_intel",
    glyph: "+",
    valueKey: "settings.debug.off",
    dim: true,
  });
  entries.push({
    kind: "item",
    labelKey: "chart.debug.neutral",
    glyph: "·",
    valueKey: "settings.debug.off",
    dim: true,
  });

  const live = (key: keyof ChartViewFlags, labelKey: string, glyph: string): SideItem => {
    const on = flags[key];
    return {
      kind: "item",
      labelKey,
      glyph,
      valueKey: on ? "settings.debug.on" : "settings.debug.off",
      live: { on, onClick: () => toggleChartView(key) },
      dim: false,
    };
  };
  entries.push(live("omniscient", "debug.omniscient", "D"));
  entries.push({
    kind: "item",
    labelKey: "chart.hint",
    glyph: "E",
    value: String(exploredCount),
    live: { on: flags.fog, onClick: () => toggleChartView("fog") },
    dim: false,
  });
  entries.push(live("ports", "chart.legend.port", "P"));
  entries.push(live("fleet", "chart.legend.fleet", "F"));
  entries.push(live("discovery", "chart.legend.discovery", "?"));

  // The stall census row carries no marker glyph.
  entries.push({
    kind: "item",
    labelKey: "debug.legend.stalls",
    glyph: "",
    dim: true,
  });
  return entries;
}

export function ChartScreen() {
  const { state } = useGameState();
  const { locale, tKey } = useI18n();
  const flags = useChartView();

  const explored = useMemo(() => decodeExplored(state.explored_tiles), [state.explored_tiles]);
  const entries = useMemo(() => sideLegend(flags, explored.size), [flags, explored.size]);

  const close = useCallback(() => {
    navigate(state.current_port ? "port" : "world");
  }, [state.current_port]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Tab" || event.key === "Escape") {
        event.preventDefault();
        close();
        return;
      }
      if ((event.key === "d" || event.key === "D") && flags.debugOverlays) {
        toggleChartView("omniscient");
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [close, flags.debugOverlays]);

  const renderEntry = (entry: SideEntry) => {
    if (entry.kind === "header") {
      return <Label key={entry.id} textKey={entry.labelKey} tone="accent" />;
    }
    const tone = entry.dim ? " sa-label--dim" : "";
    const value = entry.value ?? (entry.valueKey ? tKey(entry.valueKey) : "");
    return (
      <div className="chart__legend_row" key={entry.labelKey}>
        <span className={`chart__legend_glyph sa-cell${tone}`}>{entry.glyph}</span>
        <span className={`chart__legend_label sa-cell${tone}`} onClick={entry.live?.onClick}>
          {tKey(entry.labelKey)}
        </span>
        <span className={`chart__legend_value sa-cell sa-cell--right${tone}`}>{value}</span>
      </div>
    );
  };

  return (
    <div className="sa-screen chart" data-screen={SCREEN}>
      <div className="chart__top sa-verb-bar">
        <Label textKey="chart.title" title className="chart__title" />
        <Button textKey="chart.close" onClick={close} />
      </div>

      <div className="chart__main">
        <div className="chart__map">
          <ChartCanvas snapshot={state} locale={locale} />
        </div>

        {/* The side legend floats over the map and scrolls (§4.6); it is
            unlocked by the S19 调试图层 row only. */}
        {flags.debugOverlays ? (
          <div className="chart__side sa-plate sa-scroll">{entries.map(renderEntry)}</div>
        ) : null}
      </div>

      <div className="chart__legend">
        <Label textKey="chart.hint" tone="accent" className="sa-chip" />
        <Label textKey="chart.legend.port" className="sa-chip" />
        <Label textKey="chart.legend.fleet" className="sa-chip" />
        <Label textKey="chart.legend.discovery" className="sa-chip" />
        <Label textKey="chart.wind.title" tone="dim" className="sa-chip" />
        <Label textKey="chart.current.title" tone="dim" className="sa-chip" />
        <Label textKey="chart.ice.title" tone="dim" className="sa-chip" />
      </div>
    </div>
  );
}
