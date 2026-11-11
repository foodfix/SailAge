/**
 * BattleCanvas — the React wrapper around BattleRenderer (the M4 pattern).
 *
 * The canvas fills its absolutely-placed parent box; the renderer owns the
 * 1920×928 design backing store + devicePixelRatio scaling, the RAF loop and
 * the camera. Pointer input is presentation-only:
 *   · drag pans (4 px threshold, §4.7.1), wheel zooms at the cursor;
 *   · a click on a ship selects it (Tab also cycles own ships);
 *   · a click on the minimap jumps the camera;
 *   · the `fitSignal` prop runs the `[fit]` view.
 */
import { useEffect, useRef } from "react";
import { BattleRenderer, type BattleScene } from "./renderer";
import { DRAG_THRESHOLD_PX, VIEW_H, VIEW_W } from "./constants";
import { minimapToCell } from "./camera";

export interface BattleCanvasProps {
  scene: BattleScene;
  /** Increment to run the `[fit]` camera. */
  fitSignal: number;
  onSelect: (shipId: string | null) => void;
}

export function BattleCanvas({ scene, fitSignal, onSelect }: BattleCanvasProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const rendererRef = useRef<BattleRenderer | null>(null);
  const dragRef = useRef<{ x: number; y: number; moved: boolean } | null>(null);

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
        dragRef.current = { x: event.clientX, y: event.clientY, moved: false };
      }}
      onPointerMove={(event) => {
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
        onSelect(ship ? ship.id : null);
      }}
      onPointerCancel={() => {
        dragRef.current = null;
      }}
    />
  );
}
