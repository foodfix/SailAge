/**
 * Chart overlays (docs/80-UI-UX.md §4.6): known-port dots + names, hinted
 * discovery leads, the fleet marker.
 *
 * Ports render on their **shore** tile (the port's map location, `20-*`
 * §4.11.1), nation-coloured, neutral grey for `nation_id: ""` ports
 * (§4.8); capitals carry a ring in the debug (omniscient) port layer.
 * Everything is read-only: the layer never mutates the session.
 */
import { content, t, type Locale } from "../../i18n";
import { nations } from "../../i18n/strings";
import { PORT_MARKERS, nationColor } from "../world/ports";
import { palette } from "../world/tokens";
import {
  CAPITAL_RING_PX,
  FLEET_MARKER_PX,
  LEAD_CROSS_PX,
  PORT_DOT_PX,
  PORT_LABEL_PX,
  cellOfLatLon,
  type ChartMap,
} from "./constants";

export interface ChartOverlayInput {
  map: ChartMap;
  locale: Locale;
  knownPorts: readonly string[];
  /** The S19 debug row lifted the fog: draw every port (§4.6). */
  omniscient: boolean;
  showPorts: boolean;
  showFleet: boolean;
  showDiscovery: boolean;
  fleet: { x: number; y: number };
  /** Discovery ids the run holds a hint for (`state.discovery_hints`). */
  hintedDiscoveries: readonly string[];
}

/** Nation capitals (the §4.6 omniscient port layer rings them). */
const CAPITALS = new Set(
  Array.from(nations.values()).map((nation) => nation.capital_port_id),
);

function project(map: ChartMap, cell: { x: number; y: number }): { x: number; y: number } {
  return {
    x: map.x + (cell.x + 0.5) * map.pxPerTile,
    y: map.y + (cell.y + 0.5) * map.pxPerTile,
  };
}

function drawPorts(ctx: CanvasRenderingContext2D, input: ChartOverlayInput): void {
  const known = new Set(input.knownPorts);
  const ports = input.omniscient
    ? PORT_MARKERS
    : PORT_MARKERS.filter((port) => known.has(port.id));

  ctx.save();
  ctx.font = `${PORT_LABEL_PX}px Georgia, "Times New Roman", serif`;
  ctx.textAlign = "center";
  ctx.textBaseline = "bottom";
  for (const port of ports) {
    const point = project(input.map, port.shore);
    const colour = port.nationId
      ? (nationColor(port.nationId) ?? palette.portNeutral())
      : palette.portNeutral();
    ctx.fillStyle = colour;
    ctx.strokeStyle = palette.portInk();
    ctx.lineWidth = 1;
    ctx.fillRect(point.x - PORT_DOT_PX / 2, point.y - PORT_DOT_PX / 2, PORT_DOT_PX, PORT_DOT_PX);
    ctx.strokeRect(point.x - PORT_DOT_PX / 2, point.y - PORT_DOT_PX / 2, PORT_DOT_PX, PORT_DOT_PX);

    if (input.omniscient && CAPITALS.has(port.id)) {
      const ring = PORT_DOT_PX + CAPITAL_RING_PX;
      ctx.beginPath();
      ctx.arc(point.x, point.y, ring, 0, Math.PI * 2);
      ctx.stroke();
    }

    // §4.6: names are shown for the run's known ports (all ports at zoom in
    // the debug chart; the fit view labels the known set to stay legible).
    if (known.has(port.id)) {
      const label = t(port.name, input.locale);
      const y = point.y - PORT_DOT_PX;
      ctx.lineWidth = 2;
      ctx.strokeStyle = palette.panelBg();
      ctx.strokeText(label, point.x, y);
      ctx.fillStyle = palette.text();
      ctx.fillText(label, point.x, y);
    }
  }
  ctx.restore();
}

function drawLeads(ctx: CanvasRenderingContext2D, input: ChartOverlayInput): void {
  if (input.hintedDiscoveries.length === 0) return;
  ctx.save();
  ctx.strokeStyle = palette.accent();
  ctx.lineWidth = 2;
  for (const id of input.hintedDiscoveries) {
    const discovery = content.discovery(id);
    if (!discovery) continue;
    const point = project(input.map, cellOfLatLon(discovery.lat, discovery.lon));
    const half = LEAD_CROSS_PX / 2;
    ctx.beginPath();
    ctx.moveTo(point.x - half, point.y - half);
    ctx.lineTo(point.x + half, point.y + half);
    ctx.moveTo(point.x + half, point.y - half);
    ctx.lineTo(point.x - half, point.y + half);
    ctx.stroke();
  }
  ctx.restore();
}

function drawFleet(ctx: CanvasRenderingContext2D, input: ChartOverlayInput): void {
  const point = project(input.map, input.fleet);
  const half = FLEET_MARKER_PX / 2;
  ctx.save();
  ctx.fillStyle = palette.text();
  ctx.strokeStyle = palette.portInk();
  ctx.lineWidth = 1;
  ctx.fillRect(point.x - half, point.y - half, FLEET_MARKER_PX, FLEET_MARKER_PX);
  ctx.strokeRect(point.x - half, point.y - half, FLEET_MARKER_PX, FLEET_MARKER_PX);
  ctx.restore();
}

/** Draw every enabled overlay layer, bottom to top (§4.6 layer order). */
export function drawChartOverlays(
  ctx: CanvasRenderingContext2D,
  input: ChartOverlayInput,
): void {
  if (input.showPorts) drawPorts(ctx, input);
  if (input.showDiscovery) drawLeads(ctx, input);
  if (input.showFleet) drawFleet(ctx, input);
}
