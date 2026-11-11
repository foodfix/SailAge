/**
 * HUD minimap widget — mounts the §4.12 128×96-tile crop canvas.
 */
import { useEffect, useMemo, useRef } from "react";
import type { TickFrame } from "../../client/types";
import type { GameSnapshot } from "../../state/types";
import { decodeExplored } from "./explored";
import { drawMinimap } from "./minimap";

export function MinimapCanvas({ snapshot, tick }: { snapshot: GameSnapshot; tick: TickFrame }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const explored = useMemo(() => decodeExplored(snapshot.explored_tiles), [snapshot.explored_tiles]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    drawMinimap(canvas, {
      fleet: tick.position,
      knownPorts: snapshot.known_ports,
      explored,
      devicePixelRatio: window.devicePixelRatio || 1,
    });
  }, [tick, snapshot.known_ports, explored]);

  return <canvas ref={canvasRef} style={{ width: "100%", height: "100%" }} />;
}
