/**
 * S17 — the Chart screen (docs/80-UI-UX.md §4.6; docs/20-WORLD-AND-SAILING.md
 * §4.11/§4.12; docs/90-ARCHITECTURE.md §0.3).
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
 * amended 2026-11-01); `D` toggles back to the explored view. The network /
 * role legend rows are declared by the layout and shown dimmed because the
 * lane/ecology layers are not part of this slice (reported).
 */
import { useCallback, useEffect, useMemo } from "react";
import { navigate } from "../app/router";
import { useI18n } from "../i18n";
import { Box, CANVAS_TILES, Element, ListRows, getElementRect, getListBlock, type ScreenId, type TileRect } from "../layout";
import { useGameState } from "../state/context";
import { decodeExplored } from "../canvas/world";
import { ChartCanvas, LANE_IDS, ROLE_IDS, ROLE_LETTER, toggleChartView, useChartView } from "../canvas/chart";
import type { ChartViewFlags } from "../canvas/chart";
import { ButtonEl, LabelEl, PanelEl } from "./common";

const SCREEN: ScreenId = "chart";

/** The map box: between the two authored 64 px bars (layout rows, not code). */
const MAP_RECT: TileRect = (() => {
  const top = getElementRect(SCREEN, "top_bar");
  const bottom = getElementRect(SCREEN, "bottom_bar");
  if (!top || !bottom) {
    console.error("Layout: chart bars missing — the map falls back to the full canvas");
    return { x: 0, y: 0, w: CANVAS_TILES.w, h: CANVAS_TILES.h };
  }
  return { x: 0, y: top.y + top.h, w: CANVAS_TILES.w, h: bottom.y - (top.y + top.h) };
})();

const PANEL_LIST = getListBlock(SCREEN, "panel_rows");
const PANEL_RECT = getElementRect(SCREEN, "debug_panel");
/** The legend scrolls between the bars, inside the authored panel (§4.6). */
const PANEL_VIEWPORT: TileRect = {
  x: PANEL_LIST?.viewport.x ?? 0,
  y: MAP_RECT.y,
  w: PANEL_RECT?.w ?? CANVAS_TILES.w,
  h: MAP_RECT.h,
};

/**
 * The authored per-row cell rects (`data/ui_layout.json`). Row 39 is the
 * census row and carries label + value only — the layout's shape mirrors
 * the §4.6 side legend exactly (39 marker rows + the stall census).
 */
const PANEL_ROW_IDS: readonly { dot?: string; label: string; value: string }[] = [
  { dot: "panel_rows.row_0.dot", label: "panel_rows.row_0.label", value: "panel_rows.row_0.value" },
  { dot: "panel_rows.row_1.dot", label: "panel_rows.row_1.label", value: "panel_rows.row_1.value" },
  { dot: "panel_rows.row_2.dot", label: "panel_rows.row_2.label", value: "panel_rows.row_2.value" },
  { dot: "panel_rows.row_3.dot", label: "panel_rows.row_3.label", value: "panel_rows.row_3.value" },
  { dot: "panel_rows.row_4.dot", label: "panel_rows.row_4.label", value: "panel_rows.row_4.value" },
  { dot: "panel_rows.row_5.dot", label: "panel_rows.row_5.label", value: "panel_rows.row_5.value" },
  { dot: "panel_rows.row_6.dot", label: "panel_rows.row_6.label", value: "panel_rows.row_6.value" },
  { dot: "panel_rows.row_7.dot", label: "panel_rows.row_7.label", value: "panel_rows.row_7.value" },
  { dot: "panel_rows.row_8.dot", label: "panel_rows.row_8.label", value: "panel_rows.row_8.value" },
  { dot: "panel_rows.row_9.dot", label: "panel_rows.row_9.label", value: "panel_rows.row_9.value" },
  { dot: "panel_rows.row_10.dot", label: "panel_rows.row_10.label", value: "panel_rows.row_10.value" },
  { dot: "panel_rows.row_11.dot", label: "panel_rows.row_11.label", value: "panel_rows.row_11.value" },
  { dot: "panel_rows.row_12.dot", label: "panel_rows.row_12.label", value: "panel_rows.row_12.value" },
  { dot: "panel_rows.row_13.dot", label: "panel_rows.row_13.label", value: "panel_rows.row_13.value" },
  { dot: "panel_rows.row_14.dot", label: "panel_rows.row_14.label", value: "panel_rows.row_14.value" },
  { dot: "panel_rows.row_15.dot", label: "panel_rows.row_15.label", value: "panel_rows.row_15.value" },
  { dot: "panel_rows.row_16.dot", label: "panel_rows.row_16.label", value: "panel_rows.row_16.value" },
  { dot: "panel_rows.row_17.dot", label: "panel_rows.row_17.label", value: "panel_rows.row_17.value" },
  { dot: "panel_rows.row_18.dot", label: "panel_rows.row_18.label", value: "panel_rows.row_18.value" },
  { dot: "panel_rows.row_19.dot", label: "panel_rows.row_19.label", value: "panel_rows.row_19.value" },
  { dot: "panel_rows.row_20.dot", label: "panel_rows.row_20.label", value: "panel_rows.row_20.value" },
  { dot: "panel_rows.row_21.dot", label: "panel_rows.row_21.label", value: "panel_rows.row_21.value" },
  { dot: "panel_rows.row_22.dot", label: "panel_rows.row_22.label", value: "panel_rows.row_22.value" },
  { dot: "panel_rows.row_23.dot", label: "panel_rows.row_23.label", value: "panel_rows.row_23.value" },
  { dot: "panel_rows.row_24.dot", label: "panel_rows.row_24.label", value: "panel_rows.row_24.value" },
  { dot: "panel_rows.row_25.dot", label: "panel_rows.row_25.label", value: "panel_rows.row_25.value" },
  { dot: "panel_rows.row_26.dot", label: "panel_rows.row_26.label", value: "panel_rows.row_26.value" },
  { dot: "panel_rows.row_27.dot", label: "panel_rows.row_27.label", value: "panel_rows.row_27.value" },
  { dot: "panel_rows.row_28.dot", label: "panel_rows.row_28.label", value: "panel_rows.row_28.value" },
  { dot: "panel_rows.row_29.dot", label: "panel_rows.row_29.label", value: "panel_rows.row_29.value" },
  { dot: "panel_rows.row_30.dot", label: "panel_rows.row_30.label", value: "panel_rows.row_30.value" },
  { dot: "panel_rows.row_31.dot", label: "panel_rows.row_31.label", value: "panel_rows.row_31.value" },
  { dot: "panel_rows.row_32.dot", label: "panel_rows.row_32.label", value: "panel_rows.row_32.value" },
  { dot: "panel_rows.row_33.dot", label: "panel_rows.row_33.label", value: "panel_rows.row_33.value" },
  { dot: "panel_rows.row_34.dot", label: "panel_rows.row_34.label", value: "panel_rows.row_34.value" },
  { dot: "panel_rows.row_35.dot", label: "panel_rows.row_35.label", value: "panel_rows.row_35.value" },
  { dot: "panel_rows.row_36.dot", label: "panel_rows.row_36.label", value: "panel_rows.row_36.value" },
  { dot: "panel_rows.row_37.dot", label: "panel_rows.row_37.label", value: "panel_rows.row_37.value" },
  { dot: "panel_rows.row_38.dot", label: "panel_rows.row_38.label", value: "panel_rows.row_38.value" },
  { label: "panel_rows.row_39.label", value: "panel_rows.row_39.value" },
];

interface SideHeader {
  kind: "header";
  id: string;
  labelKey: string;
}

interface SideItem {
  kind: "item";
  row: number;
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
  let row = 0;

  entries.push({ kind: "header", id: "panel_rows.sec_title.label", labelKey: "debug.title" });
  entries.push({
    kind: "header",
    id: "panel_rows.sec_legend.network.label",
    labelKey: "debug.legend.network",
  });

  for (const lane of LANE_IDS) {
    entries.push({
      kind: "item",
      row: row++,
      labelKey: `debug.lane.${lane}`,
      glyph: "·",
      valueKey: "settings.debug.off",
      dim: true,
    });
  }
  entries.push({
    kind: "item",
    row: row++,
    labelKey: "debug.legend.spokes",
    glyph: "·",
    valueKey: "settings.debug.off",
    dim: true,
  });
  entries.push({
    kind: "item",
    row: row++,
    labelKey: "debug.legend.chokepoints",
    glyph: "·",
    valueKey: "settings.debug.off",
    dim: true,
  });

  entries.push({
    kind: "header",
    id: "panel_rows.sec_legend.fleets.label",
    labelKey: "debug.legend.fleets",
  });
  for (const role of ROLE_IDS) {
    entries.push({
      kind: "item",
      row: row++,
      labelKey: `debug.role.${role}`,
      glyph: ROLE_LETTER[role] ?? "·",
      valueKey: "settings.debug.off",
      dim: true,
    });
  }
  entries.push({
    kind: "item",
    row: row++,
    labelKey: "debug.legend.wrecks",
    glyph: "×",
    valueKey: "settings.debug.off",
    dim: true,
  });
  entries.push({
    kind: "item",
    row: row++,
    labelKey: "debug.legend.hunter_intel",
    glyph: "+",
    valueKey: "settings.debug.off",
    dim: true,
  });
  entries.push({
    kind: "item",
    row: row++,
    labelKey: "chart.debug.neutral",
    glyph: "·",
    valueKey: "settings.debug.off",
    dim: true,
  });

  const live = (key: keyof ChartViewFlags, labelKey: string, glyph: string): SideItem => {
    const on = flags[key];
    return {
      kind: "item",
      row: row++,
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
    row: row++,
    labelKey: "chart.hint",
    glyph: "E",
    value: String(exploredCount),
    live: { on: flags.fog, onClick: () => toggleChartView("fog") },
    dim: false,
  });
  entries.push(live("ports", "chart.legend.port", "P"));
  entries.push(live("fleet", "chart.legend.fleet", "F"));
  entries.push(live("discovery", "chart.legend.discovery", "?"));

  // Row 39: the stall census row carries no marker dot in the layout.
  entries.push({
    kind: "item",
    row: row,
    labelKey: "debug.legend.stalls",
    glyph: "",
    dim: true,
  });
  return entries;
}

function SideLegendRow({ entry, tKey }: { entry: SideItem; tKey: (key: string) => string }): JSX.Element {
  const ids = PANEL_ROW_IDS[entry.row];
  const value = entry.value ?? (entry.valueKey ? tKey(entry.valueKey) : "");
  const tone = entry.dim ? " sa-label--dim" : "";
  return (
    <>
      {ids.dot ? (
        <Element screen={SCREEN} id={ids.dot} className={`sa-cell${tone}`}>
          {entry.glyph}
        </Element>
      ) : null}
      <Element
        screen={SCREEN}
        id={ids.label}
        className={`sa-cell${tone}`}
        onClick={entry.live?.onClick}
      >
        {tKey(entry.labelKey)}
      </Element>
      <Element screen={SCREEN} id={ids.value} className={`sa-cell sa-label--right${tone}`}>
        {value}
      </Element>
    </>
  );
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

  return (
    <div className="sa-screen" data-chart-screen="chart">
      <Box rect={MAP_RECT}>
        <ChartCanvas snapshot={state} locale={locale} />
      </Box>

      {/* The side panel paints below the bars so it never covers the top bar
          (§4.6); its rows scroll inside the authored viewport. */}
      <PanelEl screen={SCREEN} id="debug_panel" skin="panel" hidden={!flags.debugOverlays}>
        <Box rect={PANEL_VIEWPORT} className="sa-scroll">
          <ListRows
            screen={SCREEN}
            listId="panel_rows"
            count={entries.length}
            renderRow={(index) => {
              const entry = entries[index];
              if (entry.kind === "header") {
                return <LabelEl screen={SCREEN} id={entry.id} textKey={entry.labelKey} tone="accent" />;
              }
              return <SideLegendRow entry={entry} tKey={tKey} />;
            }}
          />
        </Box>
      </PanelEl>

      <PanelEl screen={SCREEN} id="top_bar" skin="panel" />
      <LabelEl screen={SCREEN} id="top_bar.title" parent="top_bar" textKey="chart.title" title />
      <ButtonEl screen={SCREEN} id="toolbar.back" parent="top_bar" textKey="chart.close" onClick={close} />

      <LabelEl screen={SCREEN} id="legend.hint" textKey="chart.hint" tone="accent" />
      <LabelEl screen={SCREEN} id="legend.port" textKey="chart.legend.port" />
      <LabelEl screen={SCREEN} id="legend.fleet" textKey="chart.legend.fleet" />
      <LabelEl screen={SCREEN} id="legend.discovery" textKey="chart.legend.discovery" />
      <LabelEl screen={SCREEN} id="legend.wind" textKey="chart.wind.title" tone="dim" />
      <LabelEl screen={SCREEN} id="legend.current" textKey="chart.current.title" tone="dim" />
      <LabelEl screen={SCREEN} id="legend.ice" textKey="chart.ice.title" tone="dim" />

      <PanelEl screen={SCREEN} id="bottom_bar" skin="panel" />
    </div>
  );
}
