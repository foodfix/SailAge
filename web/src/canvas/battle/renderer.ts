/**
 * BattleRenderer — the imperative canvas layer behind the S10 screen.
 *
 * Pure presentation (docs/90-ARCHITECTURE.md §0.1.5): it draws the 48×30
 * battle world from the authoritative `battle_tick` frames, glides ship
 * tokens between frames, and renders the §4.7.1 overlays — broadside arc
 * fans, the hook ring, target marks, hull/crew/reload bars and the 192×120
 * minimap. No rule lives here: the arcs/hook ring are geometric reads of
 * frame state against the pinned §4.4/§4.6a conditions (the server decides),
 * and the camera is presentation arithmetic.
 */
import { spriteUrl } from "../../assets/sprites";
import {
  ARC_FAN_ALPHA,
  ARC_PORT_STEPS,
  ARC_STARBOARD_STEPS,
  BAR_GOOD_RATIO,
  BAR_WARN_RATIO,
  CANNON_RANGE_MAX,
  DRAG_THRESHOLD_PX,
  HEADING8,
  HEADING_DEGREES,
  HOOK_RING_RADIUS,
  HOOK_SPEED_MAX,
  HOOK_STORM_WEATHER,
  MINIMAP_H,
  MINIMAP_PX_PER_CELL,
  MINIMAP_W,
  SELECTION_RING,
  TILE_PX,
  TOKEN_INSET,
  VIEW_H,
  VIEW_W,
  WORLD_H,
  WORLD_W,
  ZOOM_FIT,
  ZOOM_MAX,
  ZOOM_MIN,
} from "./constants";
import {
  cameraOrigin,
  clamp,
  fitCamera,
  followCamera,
  minimapRect,
  minimapToScreen,
  panCamera,
  worldToScreen,
  zoomAt,
} from "./camera";
import { chebyshev, speedOf } from "./frame";
import { palette } from "./palette";
import type { BattleCamera, BattleShip, BattleView, Vec2 } from "./types";

export interface BattleScene {
  view: BattleView;
  /** Selected own ship (the arcs / order window act on it). */
  selectedId: string | null;
  /** The order's assigned target (a crosshair mark). */
  targetId: string | null;
  /** Instant AI turns (the battle menu's speed switch) — no glide. */
  aiInstant: boolean;
}

interface Motion {
  from: Vec2;
  to: Vec2;
  start: number;
  duration: number;
}

const hullCache = new Map<string, HTMLImageElement | null>();
const reportedMissing = new Set<string>();

function hullImage(kind: string): HTMLImageElement | null {
  const hit = hullCache.get(kind);
  if (hit !== undefined) return hit && hit.complete && hit.naturalWidth > 0 ? hit : null;
  const url = spriteUrl(`hull_${kind}`);
  if (!url) {
    if (!reportedMissing.has(kind)) {
      reportedMissing.add(kind);
      console.error(`Battle: no hull token 'hull_${kind}' — flat fallback`);
    }
    hullCache.set(kind, null);
    return null;
  }
  const image = new Image();
  image.decoding = "async";
  image.src = url;
  hullCache.set(kind, image);
  return null;
}

function bucketAngle(bucket: number): number {
  // §4.8.6 bucket 0 = east; canvas y grows south, so one bucket = −45°.
  return (-bucket * Math.PI) / 4;
}

export class BattleRenderer {
  private readonly canvas: HTMLCanvasElement;
  private readonly ctx: CanvasRenderingContext2D;
  private scene: BattleScene;
  private camera: BattleCamera = fitCamera();
  private follow = true;
  private raf = 0;
  private running = false;
  private lastRound = -1;
  private motions = new Map<string, Motion>();

  constructor(canvas: HTMLCanvasElement, scene: BattleScene) {
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("BattleRenderer: 2D context unavailable");
    this.canvas = canvas;
    this.ctx = ctx;
    this.scene = scene;
    this.camera = fitCamera();
  }

  setScene(scene: BattleScene): void {
    const now = performance.now();
    if (scene.view.round !== this.lastRound) {
      this.lastRound = scene.view.round;
      this.follow = true;
    }
    for (const ship of scene.view.ships) {
      const previous = this.scene.view.ships.find((entry) => entry.id === ship.id);
      const from = previous ? this.positionAt(ship.id, now) : ship.position;
      if (!previous || from.x !== ship.position.x || from.y !== ship.position.y) {
        this.motions.set(ship.id, {
          from,
          to: { ...ship.position },
          start: now,
          duration: scene.aiInstant ? 0 : 110,
        });
      }
    }
    this.scene = scene;
  }

  getCamera(): BattleCamera {
    return this.camera;
  }

  setCamera(camera: BattleCamera): void {
    this.camera = camera;
  }

  fit(): void {
    this.camera = fitCamera();
    this.follow = false;
  }

  isFollowing(): boolean {
    return this.follow;
  }

  /** A manual pan pauses follow until the next round (80-* §4.7.1). */
  panBy(dx: number, dy: number): void {
    this.follow = false;
    this.camera = panCamera(this.camera, dx, dy);
  }

  zoomBy(factor: number, anchor: Vec2): void {
    this.camera = zoomAt(this.camera, anchor, clamp(this.camera.zoom * factor, ZOOM_MIN, ZOOM_MAX));
  }

  zoomWheel(deltaY: number, anchor: Vec2): void {
    this.zoomBy(deltaY < 0 ? 1.1 : 1 / 1.1, anchor);
  }

  /** The world cell under a DOM pointer event. */
  cellAt(clientX: number, clientY: number): Vec2 | null {
    const point = this.designPoint(clientX, clientY);
    if (!point) return null;
    const origin = {
      x: this.camera.cx - VIEW_W / (2 * this.camera.zoom),
      y: this.camera.cy - VIEW_H / (2 * this.camera.zoom),
    };
    const scale = TILE_PX * this.camera.zoom;
    return {
      x: (point.x + origin.x * this.camera.zoom) / scale - 0.5,
      y: (point.y + origin.y * this.camera.zoom) / scale - 0.5,
    };
  }

  /** The ship token under a pointer event (cells are 1×1). */
  shipAt(clientX: number, clientY: number): BattleShip | null {
    const cell = this.cellAt(clientX, clientY);
    if (!cell) return null;
    let best: BattleShip | null = null;
    let bestDistance = 1.2;
    for (const ship of this.scene.view.ships) {
      if (!ship.alive) continue;
      const position = this.positionAt(ship.id, performance.now());
      const distance = Math.hypot(position.x - cell.x, position.y - cell.y);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = ship;
      }
    }
    return best;
  }

  /** Design-px point inside the minimap widget (null when outside). */
  minimapPointAt(clientX: number, clientY: number): Vec2 | null {
    const point = this.designPoint(clientX, clientY);
    if (!point) return null;
    const rect = minimapRect();
    if (
      point.x < rect.x ||
      point.y < rect.y ||
      point.x > rect.x + rect.w ||
      point.y > rect.y + rect.h
    ) {
      return null;
    }
    return { x: point.x - rect.x, y: point.y - rect.y };
  }

  /** Jumps the camera to a minimap cell. */
  jumpToMinimapCell(cell: Vec2): void {
    this.follow = false;
    this.camera = followCamera(cell, this.camera.zoom);
  }

  private designPoint(clientX: number, clientY: number): Vec2 | null {
    const rect = this.canvas.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return null;
    return {
      x: ((clientX - rect.left) / rect.width) * VIEW_W,
      y: ((clientY - rect.top) / rect.height) * VIEW_H,
    };
  }

  private positionAt(id: string, now: number): Vec2 {
    const motion = this.motions.get(id);
    if (!motion) {
      return this.scene.view.ships.find((ship) => ship.id === id)?.position ?? { x: 0, y: 0 };
    }
    if (motion.duration <= 0) return { ...motion.to };
    const t = clamp((now - motion.start) / motion.duration, 0, 1);
    return {
      x: motion.from.x + (motion.to.x - motion.from.x) * t,
      y: motion.from.y + (motion.to.y - motion.from.y) * t,
    };
  }

  /** The selected ship (or the first living own ship) — the camera follows it. */
  private focusShip(): BattleShip | null {
    const ships = this.scene.view.ships;
    const selected = ships.find((ship) => ship.id === this.scene.selectedId && ship.alive);
    if (selected) return selected;
    return ships.find((ship) => ship.side === "player" && ship.alive) ?? null;
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.raf = requestAnimationFrame(this.frame);
  }

  stop(): void {
    this.running = false;
    if (this.raf) cancelAnimationFrame(this.raf);
    this.raf = 0;
  }

  private readonly frame = (now: number): void => {
    if (!this.running) return;
    const dpr = Math.max(1, window.devicePixelRatio || 1);
    const backingW = Math.round(VIEW_W * dpr);
    const backingH = Math.round(VIEW_H * dpr);
    if (this.canvas.width !== backingW || this.canvas.height !== backingH) {
      this.canvas.width = backingW;
      this.canvas.height = backingH;
    }
    const ctx = this.ctx;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, VIEW_W, VIEW_H);

    const focus = this.focusShip();
    if (this.follow && focus) {
      this.camera = followCamera(this.positionAt(focus.id, now), this.camera.zoom);
    }

    this.drawSea();
    const selected = this.scene.view.ships.find(
      (ship) => ship.id === this.scene.selectedId && ship.alive,
    );
    if (selected) this.drawArcs(selected, now);
    this.drawHookRings(selected, now);
    this.drawTargetMark(now);
    for (const ship of this.scene.view.ships) {
      this.drawShip(ship, now);
    }
    this.drawWeatherWash();
    this.drawMinimap();
    this.drawWorldBorder();
    this.raf = requestAnimationFrame(this.frame);
  };

  private drawSea(): void {
    const ctx = this.ctx;
    ctx.fillStyle = palette.sea();
    ctx.fillRect(0, 0, VIEW_W, VIEW_H);
    const scale = TILE_PX * this.camera.zoom;
    const originX = (this.camera.cx - VIEW_W / (2 * this.camera.zoom)) * this.camera.zoom;
    const originY = (this.camera.cy - VIEW_H / (2 * this.camera.zoom)) * this.camera.zoom;
    ctx.save();
    ctx.strokeStyle = palette.panelLine();
    ctx.globalAlpha = 0.22;
    ctx.lineWidth = 1;
    ctx.beginPath();
    const firstX = Math.floor(originX / scale);
    const lastX = Math.ceil((originX + VIEW_W) / scale);
    for (let x = firstX; x <= lastX; x += 1) {
      const px = x * scale - originX;
      ctx.moveTo(px, 0);
      ctx.lineTo(px, VIEW_H);
    }
    const firstY = Math.floor(originY / scale);
    const lastY = Math.ceil((originY + VIEW_H) / scale);
    for (let y = firstY; y <= lastY; y += 1) {
      const py = y * scale - originY;
      ctx.moveTo(0, py);
      ctx.lineTo(VIEW_W, py);
    }
    ctx.stroke();
    ctx.restore();
  }

  private drawWorldBorder(): void {
    const ctx = this.ctx;
    const topLeft = worldToScreen(this.camera, { x: -0.5, y: -0.5 });
    const bottomRight = worldToScreen(this.camera, { x: 47.5, y: 29.5 });
    ctx.save();
    ctx.strokeStyle = palette.accent();
    ctx.globalAlpha = 0.35;
    ctx.lineWidth = 2;
    ctx.strokeRect(
      topLeft.x,
      topLeft.y,
      bottomRight.x - topLeft.x,
      bottomRight.y - topLeft.y,
    );
    ctx.restore();
  }

  /** §4.4/§4.7.1: the two broadside arc fans of the acting ship. */
  private drawArcs(ship: BattleShip, now: number): void {
    if (ship.side !== "player") return;
    const ctx = this.ctx;
    const point = worldToScreen(this.camera, this.positionAt(ship.id, now));
    const radius = CANNON_RANGE_MAX * TILE_PX * this.camera.zoom;
    const heading = bucketAngle(ship.headingBucket);
    const fans: { steps: readonly number[]; color: string }[] = [
      { steps: ARC_PORT_STEPS, color: palette.warn() },
      { steps: ARC_STARBOARD_STEPS, color: palette.good() },
    ];
    ctx.save();
    for (const fan of fans) {
      const first = heading + bucketAngle(fan.steps[0]);
      const last = heading + bucketAngle(fan.steps[fan.steps.length - 1]);
      ctx.globalAlpha = ARC_FAN_ALPHA;
      ctx.fillStyle = fan.color;
      ctx.beginPath();
      ctx.moveTo(point.x, point.y);
      ctx.arc(point.x, point.y, radius, Math.min(first, last) - Math.PI / 8, Math.max(first, last) + Math.PI / 8);
      ctx.closePath();
      ctx.fill();
      ctx.globalAlpha = 0.4;
      ctx.strokeStyle = fan.color;
      ctx.lineWidth = 1;
      ctx.stroke();
    }
    ctx.restore();
  }

  /** §4.6a hook highlight: orthogonal adjacency + both speeds ≤ 1, no storm. */
  private drawHookRings(ship: BattleShip | undefined, now: number): void {
    if (!ship) return;
    const ctx = this.ctx;
    const position = this.positionAt(ship.id, now);
    for (const other of this.scene.view.ships) {
      if (!other.alive || other.side === ship.side) continue;
      const target = this.positionAt(other.id, now);
      const adjacent =
        chebyshev(position, target) === 1 &&
        Math.abs(position.x - target.x) + Math.abs(position.y - target.y) === 1;
      if (
        !adjacent ||
        speedOf(ship) > HOOK_SPEED_MAX ||
        speedOf(other) > HOOK_SPEED_MAX ||
        this.scene.view.weather === HOOK_STORM_WEATHER
      ) {
        continue;
      }
      const point = worldToScreen(this.camera, target);
      ctx.save();
      ctx.strokeStyle = palette.good();
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(point.x, point.y, TILE_PX * this.camera.zoom * HOOK_RING_RADIUS, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }
  }

  private drawTargetMark(now: number): void {
    const target = this.scene.view.ships.find(
      (ship) => ship.id === this.scene.targetId && ship.alive,
    );
    if (!target) return;
    const point = worldToScreen(this.camera, this.positionAt(target.id, now));
    const size = TILE_PX * this.camera.zoom * 0.42;
    const ctx = this.ctx;
    ctx.save();
    ctx.strokeStyle = palette.accent();
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(point.x - size, point.y - size);
    ctx.lineTo(point.x - size / 3, point.y - size);
    ctx.moveTo(point.x + size, point.y - size);
    ctx.lineTo(point.x + size / 3, point.y - size);
    ctx.moveTo(point.x - size, point.y + size);
    ctx.lineTo(point.x - size / 3, point.y + size);
    ctx.moveTo(point.x + size, point.y + size);
    ctx.lineTo(point.x + size / 3, point.y + size);
    ctx.stroke();
    ctx.restore();
  }

  private drawShip(ship: BattleShip, now: number): void {
    const ctx = this.ctx;
    const position = this.positionAt(ship.id, now);
    const point = worldToScreen(this.camera, position);
    const size = TILE_PX * this.camera.zoom;
    if (
      point.x < -size ||
      point.y < -size ||
      point.x > VIEW_W + size ||
      point.y > VIEW_H + size
    ) {
      return;
    }
    const selected = ship.id === this.scene.selectedId && ship.alive;
    const token = size * (1 - TOKEN_INSET * 2);

    if (selected) {
      ctx.save();
      ctx.strokeStyle = palette.accent();
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(point.x, point.y, size * SELECTION_RING, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    if (!ship.alive) {
      ctx.save();
      ctx.strokeStyle = palette.bad();
      ctx.lineWidth = Math.max(2, size * 0.08);
      ctx.beginPath();
      ctx.moveTo(point.x - size * 0.25, point.y - size * 0.25);
      ctx.lineTo(point.x + size * 0.25, point.y + size * 0.25);
      ctx.moveTo(point.x + size * 0.25, point.y - size * 0.25);
      ctx.lineTo(point.x - size * 0.25, point.y + size * 0.25);
      ctx.stroke();
      ctx.restore();
      return;
    }

    const image = hullImage(ship.kind);
    ctx.save();
    ctx.translate(point.x, point.y);
    ctx.rotate((HEADING_DEGREES[ship.heading8] ?? 0) * (Math.PI / 180));
    if (image) {
      ctx.drawImage(image, -token / 2, -token / 2, token, token);
    } else {
      const half = token * 0.4;
      ctx.fillStyle = ship.side === "player" ? palette.hullPlayer() : palette.hullPirate();
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
      // Bow mark (north-facing before the rotation).
      ctx.beginPath();
      ctx.moveTo(0, -half);
      ctx.lineTo(0, -half * 0.2);
      ctx.stroke();
    }
    ctx.restore();

    this.drawBars(ship, point, size);
  }

  /** Hull / crew bars + the per-side reload pips (§4.4a, §4.7.1). */
  private drawBars(ship: BattleShip, point: Vec2, size: number): void {
    const ctx = this.ctx;
    const width = size * 0.78;
    const height = Math.max(2, size * 0.06);
    const left = point.x - width / 2;
    const top = point.y + size * 0.36;
    const hullRatio = ship.hullMax > 0 ? ship.hull / ship.hullMax : 0;
    const hullColor =
      hullRatio >= BAR_GOOD_RATIO
        ? palette.good()
        : hullRatio >= BAR_WARN_RATIO
          ? palette.warn()
          : palette.bad();
    ctx.save();
    ctx.fillStyle = palette.panelBg();
    ctx.fillRect(left, top, width, height);
    ctx.fillStyle = hullColor;
    ctx.fillRect(left, top, width * clamp(hullRatio, 0, 1), height);
    const crewRatio = ship.crewMax > 0 ? ship.crew / ship.crewMax : 0;
    ctx.fillStyle = palette.panelBg();
    ctx.fillRect(left, top + height * 1.6, width, height);
    ctx.fillStyle = palette.text();
    ctx.fillRect(left, top + height * 1.6, width * clamp(crewRatio, 0, 1), height);

    const pip = Math.max(2, size * 0.09);
    const pipTop = point.y - size * 0.42;
    const loadedPort = this.scene.view.round >= ship.reload.port;
    const loadedStarboard = this.scene.view.round >= ship.reload.starboard;
    ctx.fillStyle = palette.panelBg();
    ctx.fillRect(left, pipTop, pip, pip);
    ctx.fillRect(left + width - pip, pipTop, pip, pip);
    ctx.fillStyle = loadedPort ? palette.accent() : palette.panelLine();
    ctx.fillRect(left, pipTop, pip, pip);
    ctx.fillStyle = loadedStarboard ? palette.accent() : palette.panelLine();
    ctx.fillRect(left + width - pip, pipTop, pip, pip);
    ctx.restore();
  }

  /** Storm/strong-weather wash (render-only presentation). */
  private drawWeatherWash(): void {
    const weather = this.scene.view.weather;
    if (weather !== "storm" && weather !== "strong") return;
    const ctx = this.ctx;
    ctx.save();
    ctx.fillStyle = palette.panelBg();
    ctx.globalAlpha = weather === "storm" ? 0.34 : 0.16;
    ctx.fillRect(0, 0, VIEW_W, VIEW_H);
    ctx.restore();
  }

  /** §4.7.1 minimap: 192×120 at 4 px/cell, top-right, viewport + ships + wind. */
  private drawMinimap(): void {
    const ctx = this.ctx;
    const rect = minimapRect();
    ctx.save();
    ctx.fillStyle = palette.panelBg();
    ctx.globalAlpha = 0.9;
    ctx.fillRect(rect.x, rect.y, MINIMAP_W, MINIMAP_H);
    ctx.globalAlpha = 1;
    ctx.strokeStyle = palette.panelLine();
    ctx.lineWidth = 1;
    ctx.strokeRect(rect.x + 0.5, rect.y + 0.5, MINIMAP_W - 1, MINIMAP_H - 1);

    // The camera's visible world rect in minimap px (4 px per 64 px tile).
    const minimapPerWorld = MINIMAP_PX_PER_CELL / TILE_PX;
    const origin = cameraOrigin(this.camera);
    const viewX = rect.x + origin.x * minimapPerWorld;
    const viewY = rect.y + origin.y * minimapPerWorld;
    const viewW = (VIEW_W / this.camera.zoom) * minimapPerWorld;
    const viewH = (VIEW_H / this.camera.zoom) * minimapPerWorld;
    // At the [fit] zoom the visible world is wider than the minimap crop —
    // clip the viewport frame to the widget (the minimap covers the grid).
    const clippedX = Math.max(rect.x, viewX);
    const clippedY = Math.max(rect.y, viewY);
    const clippedW = Math.min(rect.x + MINIMAP_W, viewX + viewW) - clippedX;
    const clippedH = Math.min(rect.y + MINIMAP_H, viewY + viewH) - clippedY;
    ctx.strokeStyle = palette.accent();
    ctx.globalAlpha = 0.6;
    if (clippedW > 0 && clippedH > 0) {
      ctx.strokeRect(clippedX, clippedY, clippedW, clippedH);
    }
    ctx.globalAlpha = 1;

    const dot = MINIMAP_PX_PER_CELL;
    for (const ship of this.scene.view.ships) {
      const point = minimapToScreen(ship.position);
      ctx.fillStyle = !ship.alive
        ? palette.panelLine()
        : ship.side === "player"
          ? palette.hullPlayer()
          : palette.bad();
      ctx.fillRect(
        rect.x + point.x - dot / 2,
        rect.y + point.y - dot / 2,
        dot,
        dot,
      );
    }
    if (this.scene.selectedId) {
      const selected = this.scene.view.ships.find((ship) => ship.id === this.scene.selectedId);
      if (selected) {
        const point = minimapToScreen(selected.position);
        ctx.strokeStyle = palette.accent();
        ctx.strokeRect(rect.x + point.x - dot, rect.y + point.y - dot, dot * 2, dot * 2);
      }
    }

    // Wind arrow (the §4.7.1 minimap readout; FROM-token → blows to +180°).
    const wind = this.scene.view.wind.dir;
    const windBucket = HEADING8.indexOf(wind);
    const angle = bucketAngle(windBucket) + Math.PI;
    const center = { x: rect.x + MINIMAP_W - 12, y: rect.y + MINIMAP_H - 12 };
    const reach = 8;
    ctx.strokeStyle = palette.accent();
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(center.x - Math.cos(angle) * reach, center.y - Math.sin(angle) * reach);
    ctx.lineTo(center.x + Math.cos(angle) * reach, center.y + Math.sin(angle) * reach);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(center.x + Math.cos(angle) * reach, center.y + Math.sin(angle) * reach);
    ctx.lineTo(
      center.x + Math.cos(angle + 2.6) * reach * 0.7,
      center.y + Math.sin(angle + 2.6) * reach * 0.7,
    );
    ctx.lineTo(
      center.x + Math.cos(angle - 2.6) * reach * 0.7,
      center.y + Math.sin(angle - 2.6) * reach * 0.7,
    );
    ctx.closePath();
    ctx.fillStyle = palette.accent();
    ctx.fill();
    ctx.restore();
  }
}

export { DRAG_THRESHOLD_PX, WORLD_W, WORLD_H, ZOOM_FIT, ZOOM_MAX, ZOOM_MIN };
