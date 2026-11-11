/**
 * World-map overlays for the S3 canvas (docs/80-UI-UX.md §4.5, §4.5.2).
 *
 * Player token: the flagship's hull sprite from the committed Phase-10 art
 * (`assets/ui/hulls/hull_<ship_type>.png`) with a flat hull-coloured fallback.
 * NPC fleets: nation-coloured role squares + the state's `marker_letter`
 * (§4.5.2); wrecks: an ACCENT × over 2×2 tiles; ports: shore-tile square in the
 * nation colour plus the i18n name. Everything is viewport-culled.
 */
import { spriteUrl } from "../../assets/sprites";
import { t } from "../../i18n";
import type { Locale } from "../../i18n";
import type { Direction8 } from "../../state/types";
import { HEADING_DEGREES, WAKE_TILES } from "./constants";
import { worldToScreen, type CameraView, type Vec2 } from "./geometry";
import { nationColor, PORT_MARKERS } from "./ports";
import { palette } from "./tokens";
import type { NpcMarkerState } from "../../state/types";

const hullCache = new Map<string, HTMLImageElement | null>();
const reportedMissing = new Set<string>();

function hullImage(shipTypeId: string): HTMLImageElement | null {
  const hit = hullCache.get(shipTypeId);
  if (hit !== undefined) return hit && hit.complete && hit.naturalWidth > 0 ? hit : null;
  const url = spriteUrl(`hull_${shipTypeId}`);
  if (!url) {
    if (!reportedMissing.has(shipTypeId)) {
      reportedMissing.add(shipTypeId);
      console.error(`World: no hull token 'hull_${shipTypeId}' — flat fallback`);
    }
    hullCache.set(shipTypeId, null);
    return null;
  }
  const image = new Image();
  image.decoding = "async";
  image.src = url;
  hullCache.set(shipTypeId, image);
  return null;
}

function offscreen(camera: CameraView, point: Vec2, pad: number): boolean {
  return point.x < -pad || point.y < -pad || point.x > camera.width + pad || point.y > camera.height + pad;
}

/** Draw the player fleet token at a (fractional, interpolated) tile position. */
export function drawPlayerToken(
  ctx: CanvasRenderingContext2D,
  camera: CameraView,
  cell: Vec2,
  heading: Direction8,
  shipTypeId: string,
): void {
  const point = worldToScreen(camera, cell);
  const size = camera.tilePx;
  if (offscreen(camera, point, size)) return;

  const image = hullImage(shipTypeId);
  ctx.save();
  ctx.translate(point.x, point.y);
  ctx.rotate((HEADING_DEGREES[heading] ?? 0) * (Math.PI / 180));
  if (image) {
    ctx.drawImage(image, -size / 2, -size / 2, size, size);
  } else {
    const half = size * 0.32;
    ctx.fillStyle = palette.hullPlayer();
    ctx.strokeStyle = palette.portInk();
    ctx.lineWidth = Math.max(1, size * 0.04);
    ctx.beginPath();
    ctx.moveTo(0, -half);
    ctx.lineTo(half, 0);
    ctx.lineTo(0, half);
    ctx.lineTo(-half, 0);
    ctx.closePath();
    ctx.fill();
    ctx.stroke();
  }
  ctx.restore();
}

/** §4.5.2: a moving marker drags a 5-tile dashed, fading trail. */
function drawWake(ctx: CanvasRenderingContext2D, camera: CameraView, marker: NpcMarkerState): void {
  const wake = marker.wake ?? [];
  if (marker.docked || wake.length === 0) return;
  const points = wake.slice(0, WAKE_TILES).map((cell) => worldToScreen(camera, cell));
  const head = worldToScreen(camera, marker.position);
  ctx.save();
  ctx.strokeStyle = palette.panelLine();
  ctx.lineWidth = Math.max(1, camera.tilePx * 0.02);
  ctx.setLineDash([camera.tilePx * 0.15, camera.tilePx * 0.2]);
  const all = [head, ...points];
  for (let index = 0; index < all.length - 1; index += 1) {
    const alpha = 0.55 - index * 0.1;
    if (alpha <= 0) break;
    ctx.globalAlpha = alpha;
    ctx.beginPath();
    ctx.moveTo(all[index].x, all[index].y);
    ctx.lineTo(all[index + 1].x, all[index + 1].y);
    ctx.stroke();
  }
  ctx.restore();
}

/** §4.5.2 NPC role squares (nation colour, pirate = BAD red) + role letter. */
export function drawNpcMarkers(
  ctx: CanvasRenderingContext2D,
  camera: CameraView,
  markers: readonly NpcMarkerState[],
): void {
  for (const marker of markers) {
    drawWake(ctx, camera, marker);
    const point = worldToScreen(camera, marker.position);
    if (offscreen(camera, point, camera.tilePx * 2)) continue;

    const side = Math.max(6, camera.tilePx * 0.78);
    const color =
      marker.role === "pirate" ? palette.bad() : (nationColor(marker.nation_id) ?? palette.portNeutral());
    ctx.fillStyle = color;
    ctx.strokeStyle = palette.portInk();
    ctx.lineWidth = Math.max(1, camera.tilePx * 0.03);
    ctx.fillRect(point.x - side / 2, point.y - side / 2, side, side);
    ctx.strokeRect(point.x - side / 2, point.y - side / 2, side, side);

    if (marker.marker_letter) {
      ctx.fillStyle = palette.portInk();
      ctx.font = `${Math.round(camera.tilePx * 0.46)}px Georgia, serif`;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(marker.marker_letter, point.x, point.y);
    }
  }
}

/** §4.5.2 wreck icon: an ACCENT × glyph 2×2 tiles at the site. */
export function drawWrecks(
  ctx: CanvasRenderingContext2D,
  camera: CameraView,
  wrecks: readonly { id: string; position: Vec2 }[],
): void {
  ctx.save();
  ctx.strokeStyle = palette.accent();
  ctx.lineWidth = Math.max(1, camera.tilePx * 0.06);
  for (const wreck of wrecks) {
    const point = worldToScreen(camera, wreck.position);
    if (offscreen(camera, point, camera.tilePx * 2)) continue;
    const half = camera.tilePx;
    ctx.beginPath();
    ctx.moveTo(point.x - half, point.y - half);
    ctx.lineTo(point.x + half, point.y + half);
    ctx.moveTo(point.x + half, point.y - half);
    ctx.lineTo(point.x - half, point.y + half);
    ctx.stroke();
  }
  ctx.restore();
}

/** Port overlay: a shore-tile square in the nation colour + the i18n name. */
export function drawPorts(ctx: CanvasRenderingContext2D, camera: CameraView, locale: Locale): void {
  const fontPx = Math.max(10, Math.round(camera.tilePx * 0.19));
  ctx.save();
  ctx.font = `${fontPx}px Georgia, "Times New Roman", serif`;
  ctx.textAlign = "center";
  ctx.textBaseline = "bottom";
  for (const port of PORT_MARKERS) {
    const point = worldToScreen(camera, port.shore);
    if (offscreen(camera, point, camera.tilePx * 4)) continue;
    const side = Math.max(4, camera.tilePx * 0.3);
    ctx.fillStyle = port.nationId ? (nationColor(port.nationId) ?? palette.portNeutral()) : palette.portNeutral();
    ctx.strokeStyle = palette.portInk();
    ctx.lineWidth = Math.max(1, camera.tilePx * 0.03);
    ctx.fillRect(point.x - side / 2, point.y - side / 2, side, side);
    ctx.strokeRect(point.x - side / 2, point.y - side / 2, side, side);

    const label = t(port.name, locale);
    ctx.lineWidth = Math.max(2, fontPx * 0.22);
    ctx.strokeStyle = palette.panelBg();
    ctx.strokeText(label, point.x, point.y - side);
    ctx.fillStyle = palette.text();
    ctx.fillText(label, point.x, point.y - side);
  }
  ctx.restore();
}
