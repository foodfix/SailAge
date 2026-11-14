/**
 * World-map overlays for the S3 canvas (docs/80-UI-UX.md §4.5, §4.5.2 +
 * the 2026-11-05 NPC world-fleet hull-token amendment).
 *
 * Player token: the flagship's hull sprite from the committed Phase-10 art
 * (`assets/ui/hulls/hull_<ship_type>.png`) with a flat hull-coloured fallback.
 * NPC fleets: the same 8-dir hull token as the player (flagship ship type,
 * movement heading, 1:1 tile) with the §4.5.2 square demoted to a corner
 * role chip (role colour + letter); the bare nation square + letter stays
 * as the fallback when no token resolves (docked / unknown heading).
 * Wrecks: an ACCENT × over 2×2 tiles; ports: shore-tile square in the
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
import { portSpriteId } from "./terrain";
import type { NpcMarkerState } from "../../state/types";

const hullCache = new Map<string, HTMLImageElement | null>();
const reportedMissing = new Set<string>();

/**
 * Live fleet rows carry the save payload's `cell` (`90-*` §0.3 state
 * frame = the §8.1 payload) while the fixture rows carry the §4.5.2
 * `position`. Accept either — a marker without either is skipped, never
 * a crash (one bad row may not blank the sailing view).
 */
export function markerCell(marker: NpcMarkerState): Vec2 | undefined {
  const withCell = marker as NpcMarkerState & { cell?: Vec2 | null };
  if (marker.position && typeof marker.position.x === "number") return marker.position;
  if (withCell.cell && typeof withCell.cell.x === "number") return withCell.cell;
  return undefined;
}

/** §4.5.2 role letter: the fixture pins T/P/c; others derive from the role. */
const ROLE_LETTERS: Record<string, string> = { trader: "T", patrol: "P", coaster: "c" };

function roleLetter(role: string): string {
  return ROLE_LETTERS[role] ?? role.charAt(0).toUpperCase();
}

/** Terrain-sprite image cache (the §9.2 port sprites; terrain.ts owns land/water). */
const terrainSprites = new Map<string, HTMLImageElement | null>();

function portSprite(id: string): HTMLImageElement | null {
  const hit = terrainSprites.get(id);
  if (hit !== undefined) return hit && hit.complete && hit.naturalWidth > 0 ? hit : null;
  const url = spriteUrl(id);
  if (!url) {
    terrainSprites.set(id, null);
    return null;
  }
  const image = new Image();
  image.decoding = "async";
  image.src = url;
  terrainSprites.set(id, image);
  return null;
}

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
  const headCell = markerCell(marker);
  if (marker.docked || wake.length === 0 || !headCell) return;
  const points = wake.slice(0, WAKE_TILES).map((cell) => worldToScreen(camera, cell));
  const head = worldToScreen(camera, headCell);
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

/** The marker's role colour: pirate BAD red, else the nation's colour. */
function roleColor(marker: NpcMarkerState): string {
  return marker.role === "pirate" ? palette.bad() : (nationColor(marker.nation_id) ?? palette.portNeutral());
}

/**
 * The §4.5.2 fallback square + letter — docked fleets and rows whose
 * token does not resolve (no ship_type / no hull sprite).
 */
function drawRoleSquare(
  ctx: CanvasRenderingContext2D,
  camera: CameraView,
  point: Vec2,
  marker: NpcMarkerState,
): void {
  const side = Math.max(6, camera.tilePx * 0.78);
  ctx.fillStyle = roleColor(marker);
  ctx.strokeStyle = palette.portInk();
  ctx.lineWidth = Math.max(1, camera.tilePx * 0.03);
  ctx.fillRect(point.x - side / 2, point.y - side / 2, side, side);
  ctx.strokeRect(point.x - side / 2, point.y - side / 2, side, side);

  const letter = marker.marker_letter ?? roleLetter(marker.role);
  if (letter) {
    ctx.fillStyle = palette.portInk();
    ctx.font = `${Math.round(camera.tilePx * 0.46)}px Georgia, serif`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(letter, point.x, point.y);
  }
}

/**
 * The corner role chip on a hull token (80-* amendment: the §4.5.2
 * square demoted to ~a quarter tile — role colour + letter, screen-aligned).
 */
function drawRoleChip(
  ctx: CanvasRenderingContext2D,
  camera: CameraView,
  point: Vec2,
  marker: NpcMarkerState,
): void {
  const side = Math.max(6, Math.round(camera.tilePx * 0.25));
  const x = point.x + camera.tilePx / 2 - side;
  const y = point.y + camera.tilePx / 2 - side;
  ctx.fillStyle = roleColor(marker);
  ctx.strokeStyle = palette.portInk();
  ctx.lineWidth = Math.max(1, camera.tilePx * 0.02);
  ctx.fillRect(x, y, side, side);
  ctx.strokeRect(x, y, side, side);

  const letter = marker.marker_letter ?? roleLetter(marker.role);
  if (letter) {
    ctx.fillStyle = palette.portInk();
    ctx.font = `${Math.round(side * 0.72)}px Georgia, serif`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(letter, x + side / 2, y + side / 2);
  }
}

/**
 * §4.5.2 + the 80-* NPC world-fleet-token amendment: a sailing fleet
 * renders the flagship's 8-dir hull token (1:1 tile, heading rotation)
 * with the corner role chip; the bare square is the fallback.
 */
export function drawNpcMarkers(
  ctx: CanvasRenderingContext2D,
  camera: CameraView,
  markers: readonly NpcMarkerState[],
): void {
  for (const marker of markers) {
    drawWake(ctx, camera, marker);
    const cell = markerCell(marker);
    if (!cell) continue;
    const point = worldToScreen(camera, cell);
    if (offscreen(camera, point, camera.tilePx * 2)) continue;

    const heading = marker.heading;
    const image = !marker.docked && heading && marker.ship_type
      ? hullImage(marker.ship_type)
      : null;
    if (image && HEADING_DEGREES[heading] !== undefined) {
      ctx.save();
      ctx.translate(point.x, point.y);
      ctx.rotate((HEADING_DEGREES[heading] ?? 0) * (Math.PI / 180));
      ctx.drawImage(image, -camera.tilePx / 2, -camera.tilePx / 2, camera.tilePx, camera.tilePx);
      ctx.restore();
      drawRoleChip(ctx, camera, point, marker);
    } else {
      drawRoleSquare(ctx, camera, point, marker);
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

/**
 * Port overlay: the §9.2 `terrain_port_{owner}` sprite on the shore tile
 * plus the i18n name (the flat nation square is the sprite-missing
 * fallback).
 */
export function drawPorts(ctx: CanvasRenderingContext2D, camera: CameraView, locale: Locale): void {
  const fontPx = Math.max(10, Math.round(camera.tilePx * 0.19));
  ctx.save();
  ctx.font = `${fontPx}px Georgia, "Times New Roman", serif`;
  ctx.textAlign = "center";
  ctx.textBaseline = "bottom";
  for (const port of PORT_MARKERS) {
    const point = worldToScreen(camera, port.shore);
    if (offscreen(camera, point, camera.tilePx * 4)) continue;
    const side = camera.tilePx;
    const spriteImage = portSprite(portSpriteId(port.nationId));
    if (spriteImage) {
      ctx.drawImage(spriteImage, point.x - side / 2, point.y - side / 2, side, side);
    } else {
      const small = Math.max(4, camera.tilePx * 0.3);
      ctx.fillStyle = port.nationId ? (nationColor(port.nationId) ?? palette.portNeutral()) : palette.portNeutral();
      ctx.strokeStyle = palette.portInk();
      ctx.lineWidth = Math.max(1, camera.tilePx * 0.03);
      ctx.fillRect(point.x - small / 2, point.y - small / 2, small, small);
      ctx.strokeRect(point.x - small / 2, point.y - small / 2, small, small);
    }

    const label = t(port.name, locale);
    ctx.lineWidth = Math.max(2, fontPx * 0.22);
    ctx.strokeStyle = palette.panelBg();
    ctx.strokeText(label, point.x, point.y - side * 0.45);
    ctx.fillStyle = palette.text();
    ctx.fillText(label, point.x, point.y - side * 0.45);
  }
  ctx.restore();
}
