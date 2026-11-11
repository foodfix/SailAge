/**
 * Port overlay data for the world map (docs/10-DATA-SCHEMA.md §6.1 harbor
 * pair; docs/80-UI-UX.md §4.5).
 *
 * The harbor pair is tool-derived and committed (`data/maps/harbors.json`);
 * the runtime never re-snaps lat/lon. Ports are an overlay, not terrain
 * (§6.2), and render on the shore tile.
 */
import harborsRaw from "../../../../data/maps/harbors.json";
import { content } from "../../i18n";
import { ports as portDefs } from "../../i18n/strings";
import type { L10nString } from "../../i18n";
import { AREA_RADIUS } from "./constants";
import { wrapDeltaX, type Vec2 } from "./geometry";

interface HarborsFile {
  version: number;
  harbors: { id: string; berth: [number, number]; shore: [number, number] }[];
}

export interface PortMarker {
  id: string;
  name: L10nString;
  nationId: string;
  shore: Vec2;
  berth: Vec2;
}

const harborById = new Map<string, { berth: Vec2; shore: Vec2 }>();
for (const row of (harborsRaw as HarborsFile).harbors) {
  harborById.set(row.id, {
    berth: { x: row.berth[0], y: row.berth[1] },
    shore: { x: row.shore[0], y: row.shore[1] },
  });
}

/** Every port that has a committed harbor pair (the only drawable ones). */
export const PORT_MARKERS: PortMarker[] = [];
for (const [id, def] of portDefs) {
  const harbor = harborById.get(id);
  if (!harbor) continue;
  PORT_MARKERS.push({
    id,
    name: content.portName(id),
    nationId: def.nation_id,
    berth: harbor.berth,
    shore: harbor.shore,
  });
}

const portByIdMap = new Map(PORT_MARKERS.map((port) => [port.id, port]));

/** One port's committed marker row (undefined for unknown ids). */
export function portById(id: string): PortMarker | undefined {
  return portByIdMap.get(id);
}

/** A port's berth cell (the fleet stands here when docked), or undefined. */
export function portBerth(portId: string): Vec2 | undefined {
  return portByIdMap.get(portId)?.berth;
}

/**
 * The §4.5 area label: the nearest **known** port within 16 tiles (Chebyshev,
 * wrap-aware on x), else "" (the caller renders `world.open_sea`).
 */
export function nearestKnownPort(cell: Vec2, knownPorts: readonly string[]): string {
  let best = "";
  let bestDistance = AREA_RADIUS + 1;
  for (const portId of knownPorts) {
    const berth = portBerth(portId);
    if (!berth) continue;
    const dx = Math.abs(wrapDeltaX(berth.x, cell.x));
    const dy = Math.abs(berth.y - cell.y);
    const distance = Math.max(dx, dy);
    if (distance <= AREA_RADIUS && distance < bestDistance) {
      bestDistance = distance;
      best = portId;
    }
  }
  return best;
}

export function nationColor(nationId: string): string | undefined {
  return content.nation(nationId)?.color;
}
