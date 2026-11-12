/**
 * WorldRenderer — the imperative canvas layer behind the S3 screen.
 *
 * Pure renderer: it owns tile-pyramid drawing, the wrap-aware camera and the
 * render-only fleet interpolation between authoritative `tick` positions.
 * No rule lives here (docs/90-ARCHITECTURE.md §0: server-authoritative tick;
 * docs/20-WORLD-AND-SAILING.md §4.2 "interpolated rendering ... a render-only
 * offset").
 */
import type { GameSnapshot, NpcMarkerState } from "../../state/types";
import type { TickFrame } from "../../client/types";
import type { Locale } from "../../i18n";
import {
  NPC_GLIDE_SNAP_TILES,
  selectTileLevel,
  WORLD_TILE_PX,
  ZOOM_NEAR,
  ZOOM_WIDE,
} from "./constants";
import { clamp, makeCamera, sameCell, screenToTile, wrapDeltaX, type CameraView, type Vec2 } from "./geometry";
import { drawNpcMarkers, drawPlayerToken, drawPorts, drawWrecks, markerCell } from "./markers";
import { pyramid } from "./pyramid";
import { drawTileLayer } from "./tiles";
import { drawTerrain } from "./terrain";

/** The 1920×1080 design surface (docs/80-UI-UX.md §4.8.9). */
const VIEW_W = 1920;
const VIEW_H = 1080;

/** Render-only glide when an authoritative position changes (ms bounds). */
const GLIDE_MIN_MS = 80;
const GLIDE_MAX_MS = 1200;
const GLIDE_DEFAULT_MS = 160;

export interface WorldScene {
  snapshot: GameSnapshot;
  npcMarkers: readonly NpcMarkerState[];
}

interface Motion {
  from: Vec2;
  to: Vec2;
  start: number;
  duration: number;
}

/** One NPC marker's render motion plus its latest slice row. */
interface MarkerMotion extends Motion {
  row: NpcMarkerState;
}

export class WorldRenderer {
  private readonly ctx: CanvasRenderingContext2D;
  private readonly canvas: HTMLCanvasElement;
  private scene: WorldScene;
  private tick: TickFrame;
  private locale: Locale = "en";
  private zoom = ZOOM_NEAR;
  private motion: Motion;
  private lastChangeAt = 0;
  /** The glide interval the player's last step used (§4.5.2 shared cadence). */
  private lastGlideMs = GLIDE_DEFAULT_MS;
  private markerMotions = new Map<string, MarkerMotion>();
  private raf = 0;
  private running = false;

  constructor(canvas: HTMLCanvasElement, scene: WorldScene, tick: TickFrame) {
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("WorldRenderer: 2D context unavailable");
    this.canvas = canvas;
    this.ctx = ctx;
    this.scene = scene;
    this.tick = tick;
    const start: Vec2 = { x: tick.position.x, y: tick.position.y };
    this.motion = { from: start, to: start, start: 0, duration: 0 };
  }

  setScene(scene: WorldScene): void {
    this.syncMarkers(scene.npcMarkers, performance.now());
    this.scene = scene;
  }

  setLocale(locale: Locale): void {
    this.locale = locale;
  }

  setZoom(zoom: number): void {
    this.zoom = zoom;
  }

  zoomWide(): boolean {
    return this.zoom === ZOOM_WIDE;
  }

  /** Feed one authoritative sailing tick (10 Hz); positions glide, nothing else. */
  pushTick(tick: TickFrame): void {
    const now = performance.now();
    if (!sameCell(this.tick.position, tick.position)) {
      const current = this.positionAt(now);
      const interval = this.lastChangeAt > 0 ? now - this.lastChangeAt : GLIDE_DEFAULT_MS;
      this.lastGlideMs = clamp(interval, GLIDE_MIN_MS, GLIDE_MAX_MS);
      this.motion = {
        from: current,
        to: {
          x: current.x + wrapDeltaX(tick.position.x, current.x),
          y: tick.position.y,
        },
        start: now,
        duration: this.lastGlideMs,
      };
      this.lastChangeAt = now;
    }
    this.tick = tick;
  }

  /** Current render-only fleet position (fractional tile). */
  private positionAt(now: number): Vec2 {
    const { from, to, start, duration } = this.motion;
    if (duration <= 0) return { x: to.x, y: to.y };
    const t = clamp((now - start) / duration, 0, 1);
    return { x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t };
  }

  /**
   * §4.5.2 marker playback (web transport, 2026-11-12 amendment): one entry
   * per fleet id from the latest scene rows; a changed cell glides from the
   * currently rendered position at the player's glide cadence, a fleet
   * pending more than `NPC_GLIDE_SNAP_TILES` snaps, ids gone from the slice
   * are dropped (they left the §0.3 radius = already off-screen).
   */
  private syncMarkers(rows: readonly NpcMarkerState[], now: number): void {
    const next = new Map<string, MarkerMotion>();
    for (const row of rows) {
      const cell = markerCell(row);
      if (!cell) continue;
      const prev = this.markerMotions.get(row.id);
      const unchanged =
        prev !== undefined && sameCell(prev.to, cell) && prev.duration <= 0;
      if (unchanged && prev) {
        next.set(row.id, { ...prev, row });
        continue;
      }
      if (prev) {
        const pending = Math.max(
          Math.abs(wrapDeltaX(cell.x, prev.to.x)),
          Math.abs(cell.y - prev.to.y),
        );
        if (pending <= NPC_GLIDE_SNAP_TILES) {
          // Glide on from wherever the previous motion has reached.
          const current = this.motionPositionAt(prev, now);
          next.set(row.id, {
            row,
            from: current,
            to: { x: current.x + wrapDeltaX(cell.x, current.x), y: cell.y },
            start: now,
            duration: this.lastGlideMs,
          });
          continue;
        }
      }
      next.set(row.id, {
        row,
        from: { x: cell.x, y: cell.y },
        to: { x: cell.x, y: cell.y },
        start: 0,
        duration: 0,
      });
    }
    this.markerMotions = next;
  }

  /** Current render-only position of one marker motion (fractional tile). */
  private motionPositionAt(motion: Motion, now: number): Vec2 {
    const { from, to, start, duration } = motion;
    if (duration <= 0) return { x: to.x, y: to.y };
    const t = clamp((now - start) / duration, 0, 1);
    return { x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t };
  }

  /** The scene's NPC markers with their interpolated render cells. */
  private markersAt(now: number): NpcMarkerState[] {
    const out: NpcMarkerState[] = [];
    for (const motion of this.markerMotions.values()) {
      out.push({ ...motion.row, position: this.motionPositionAt(motion, now) });
    }
    return out;
  }

  private cameraAt(now: number): CameraView {
    return makeCamera(this.positionAt(now), this.zoom, VIEW_W, VIEW_H, WORLD_TILE_PX);
  }

  /** World tile under a DOM pointer event (x wrapped; y clamped by camera). */
  tileAt(clientX: number, clientY: number): Vec2 {
    const rect = this.canvas.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return { x: 0, y: 0 };
    const point = {
      x: ((clientX - rect.left) / rect.width) * VIEW_W,
      y: ((clientY - rect.top) / rect.height) * VIEW_H,
    };
    return screenToTile(this.cameraAt(performance.now()), point);
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

  /** Run one overlay pass; a throw is logged once and the RAF loop lives. */
  private readonly safe = (pass: () => void): void => {
    try {
      pass();
    } catch (err) {
      if (!this.overlayFailureLogged) {
        this.overlayFailureLogged = true;
        console.error(`World: overlay pass failed — skipped (${String(err)})`);
      }
    }
  };

  private overlayFailureLogged = false;

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

    const camera = this.cameraAt(now);
    const fleet = this.positionAt(now);
    const terrain = drawTerrain(ctx, camera);
    if (!terrain.ready) {
      // Warm-up (or layer failure): the flat raster underneath — the exact
      // pre-M7.1 view — until every sampled chunk decodes.
      const level = selectTileLevel(camera.tilePx, dpr);
      drawTileLayer(ctx, pyramid("world"), camera, level, "");
    }
    // Each overlay pass is contained: one bad row (a projection shape the
    // renderer did not expect) may skip that pass, never kill the RAF loop
    // — a dead loop froze the whole view blank (the M7.1 live report).
    this.safe(() => drawWrecks(ctx, camera, this.scene.snapshot.wrecks));
    this.safe(() => drawPorts(ctx, camera, this.locale));
    this.safe(() => drawNpcMarkers(ctx, camera, this.markersAt(now)));
    this.safe(() =>
      drawPlayerToken(
        ctx,
        camera,
        fleet,
        this.tick.heading,
        this.scene.snapshot.fleet[0]?.ship_type_id ?? "",
      ),
    );

    this.raf = requestAnimationFrame(this.frame);
  };
}

export { ZOOM_NEAR, ZOOM_WIDE };
