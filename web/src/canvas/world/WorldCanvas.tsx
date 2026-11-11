/**
 * WorldCanvas — the React wrapper around WorldRenderer. The canvas is sized by
 * its absolutely-placed parent box; the renderer owns the 1920×1080 backing
 * store + devicePixelRatio scaling, the RAF loop and the camera.
 */
import { useEffect, useRef } from "react";
import type { TickFrame } from "../../client/types";
import type { Locale } from "../../i18n";
import type { Vec2 } from "./geometry";
import { WorldRenderer, type WorldScene } from "./renderer";

export interface WorldCanvasProps {
  scene: WorldScene;
  tick: TickFrame;
  zoom: number;
  locale: Locale;
  onSailTo: (cell: Vec2) => void;
}

export function WorldCanvas({ scene, tick, zoom, locale, onSailTo }: WorldCanvasProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const rendererRef = useRef<WorldRenderer | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const renderer = new WorldRenderer(canvas, scene, tick);
    renderer.setLocale(locale);
    renderer.setZoom(zoom);
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
    rendererRef.current?.pushTick(tick);
  }, [tick]);

  useEffect(() => {
    rendererRef.current?.setLocale(locale);
  }, [locale]);

  useEffect(() => {
    rendererRef.current?.setZoom(zoom);
  }, [zoom]);

  return (
    <canvas
      ref={canvasRef}
      style={{ width: "100%", height: "100%" }}
      onClick={(event) => {
        const cell = rendererRef.current?.tileAt(event.clientX, event.clientY);
        if (cell) onSailTo(cell);
      }}
    />
  );
}
