/**
 * BattleCanvas — the React wrapper around BattleRenderer (the M4 pattern).
 *
 * The canvas fills its absolutely-placed parent box; the renderer owns the
 * 1920×928 design backing store + devicePixelRatio scaling, the RAF loop and
 * the camera. Pointer input is presentation-only:
 *   · drag pans (4 px threshold, §4.7.1), wheel zooms at the cursor;
 *   · a two-finger pinch zooms at the pinch midpoint (touch, 80-* §4.9.2);
 *   · a click on a ship selects it (Tab also cycles own ships);
 *   · a click on the minimap jumps the camera;
 *   · the `fitSignal` prop runs the `[fit]` view.
 */
import { useEffect, useRef } from "react";
import { BattleRenderer, type BattleScene } from "./renderer";
import { DRAG_THRESHOLD_PX, VIEW_H, VIEW_W } from "./constants";
import { minimapToCell } from "./camera";

interface PointerSpot {
  x: number;
  y: number;
}

export interface BattleCanvasProps {
  scene: BattleScene;
  /** Increment to run the `[fit]` camera. */
  fitSignal: number;
  onSelect: (shipId: string | null) => void;
  /** A click on a reachable-set endpoint (§4.3: the move order). */
  onEndpoint?: (cell: { x: number; y: number }) => void;
}

export function BattleCanvas({ scene, fitSignal, onSelect, onEndpoint }: BattleCanvasProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const rendererRef = useRef<BattleRenderer | null>(null);
  const dragRef = useRef<{ x: number; y: number; moved: boolean } | null>(null);
  /** Live pointers for the pinch gesture; single-pointer drag stays in dragRef. */
  const pointersRef = useRef<Map<number, PointerSpot>>(new Map());
  const pinchDistRef = useRef<number>(0);

  /** Convert a client point into the design-px anchor (the wheel rule). */
  const designAnchor = (clientX: number, clientY: number): { x: number; y: number } | null => {
    const canvas = canvasRef.current;
    if (!canvas) return null;
    const rect = canvas.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return null;
    return {
      x: ((clientX - rect.left) / rect.width) * VIEW_W,
      y: ((clientY - rect.top) / rect.height) * VIEW_H,
    };
  };

  const pinchSpots = (): [PointerSpot, PointerSpot] => {
    const spots = [...pointersRef.current.values()];
    return [spots[0], spots[1]];
  };

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const renderer = new BattleRenderer(canvas, scene);
    renderer.start();
    rendererRef.current = renderer;
    return () => {
      renderer.stop();
      rendererRef.current = null;
    };
    // The renderer lives for the screen's lifetime; live values arrive below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    rendererRef.current?.setScene(scene);
  }, [scene]);

  useEffect(() => {
    if (fitSignal > 0) rendererRef.current?.fit();
  }, [fitSignal]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const onWheel = (event: WheelEvent) => {
      event.preventDefault();
      const rect = canvas.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;
      const anchor = {
        x: ((event.clientX - rect.left) / rect.width) * VIEW_W,
        y: ((event.clientY - rect.top) / rect.height) * VIEW_H,
      };
      rendererRef.current?.zoomWheel(event.deltaY, anchor);
    };
    const onContextMenu = (event: MouseEvent) => event.preventDefault();
    canvas.addEventListener("wheel", onWheel, { passive: false });
    canvas.addEventListener("contextmenu", onContextMenu);
    return () => {
      canvas.removeEventListener("wheel", onWheel);
      canvas.removeEventListener("contextmenu", onContextMenu);
    };
  }, []);

  return (
    <canvas
      ref={canvasRef}
      style={{ width: "100%", height: "100%" }}
      onPointerDown={(event) => {
        event.currentTarget.setPointerCapture(event.pointerId);
        pointersRef.current.set(event.pointerId, { x: event.clientX, y: event.clientY });
        if (pointersRef.current.size === 1) {
          dragRef.current = { x: event.clientX, y: event.clientY, moved: false };
          return;
        }
        // A second finger turns the gesture into a pinch; the pending
        // drag is discarded so its lift never selects.
        dragRef.current = null;
        const [a, b] = pinchSpots();
        pinchDistRef.current = Math.hypot(a.x - b.x, a.y - b.y);
      }}
      onPointerMove={(event) => {
        const pointers = pointersRef.current;
        if (!pointers.has(event.pointerId)) return;
        pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
        if (pointers.size >= 2) {
          // Pinch zoom (80-* §4.9.2): the wheel rule anchored at the
          // pinch midpoint — fingers apart zooms in, together zooms out.
          const [a, b] = pinchSpots();
          const dist = Math.hypot(a.x - b.x, a.y - b.y);
          const anchor = designAnchor((a.x + b.x) / 2, (a.y + b.y) / 2);
          if (pinchDistRef.current > 0 && dist > 0 && anchor) {
            rendererRef.current?.zoomBy(dist / pinchDistRef.current, anchor);
          }
          pinchDistRef.current = dist;
          return;
        }
        const drag = dragRef.current;
        if (!drag) return;
        const rect = event.currentTarget.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return;
        const dx = ((event.clientX - drag.x) / rect.width) * VIEW_W;
        const dy = ((event.clientY - drag.y) / rect.height) * VIEW_H;
        if (!drag.moved && Math.hypot(dx, dy) < DRAG_THRESHOLD_PX) return;
        drag.moved = true;
        drag.x = event.clientX;
        drag.y = event.clientY;
        rendererRef.current?.panBy(dx, dy);
      }}
      onPointerUp={(event) => {
        pointersRef.current.delete(event.pointerId);
        pinchDistRef.current = 0;
        if (pointersRef.current.size === 1) {
          // One finger survived a pinch: re-base it as a moved drag so
          // its lift never selects.
          const [spot] = [...pointersRef.current.values()];
          dragRef.current = { x: spot.x, y: spot.y, moved: true };
          return;
        }
        const drag = dragRef.current;
        dragRef.current = null;
        if (!drag || drag.moved) return;
        const renderer = rendererRef.current;
        if (!renderer) return;
        const minimap = renderer.minimapPointAt(event.clientX, event.clientY);
        if (minimap) {
          renderer.jumpToMinimapCell(minimapToCell(minimap));
          return;
        }
        const ship = renderer.shipAt(event.clientX, event.clientY);
        if (ship) {
          onSelect(ship.id);
          return;
        }
        const endpoint = onEndpoint ? renderer.endpointAt(event.clientX, event.clientY) : null;
        if (endpoint && onEndpoint) onEndpoint({ x: endpoint.x, y: endpoint.y });
        else onSelect(null);
      }}
      onPointerCancel={(event) => {
        pointersRef.current.delete(event.pointerId);
        pinchDistRef.current = 0;
        dragRef.current = null;
      }}
    />
  );
}
