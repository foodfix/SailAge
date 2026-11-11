/**
 * ChartCanvas — the React mount for the S17 chart renderer.
 *
 * The canvas fills its absolutely-placed map box (between the two 64 px
 * bars, from the layout rows); `drawChart` reads the canvas's CSS size as the
 * design-px map rect. Redraws are event-driven; a **bounded** RAF retry only
 * spans the first frames while the pyramid bitmaps decode (§4.6: open build
 * < 0.5 s, then no per-frame work).
 */
import { useEffect, useMemo, useRef } from "react";
import type { Locale } from "../../i18n";
import type { GameSnapshot } from "../../state/types";
import { decodeExploredRuns } from "./mask";
import { drawChart } from "./renderer";
import { useChartView } from "./viewState";

/** Stop retrying after this many frames (~2 s at 60 Hz) — never a RAF loop. */
const MAX_RETRY_FRAMES = 120;

export interface ChartCanvasProps {
  snapshot: GameSnapshot;
  locale: Locale;
}

export function ChartCanvas({ snapshot, locale }: ChartCanvasProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const flags = useChartView();

  const runs = useMemo(() => decodeExploredRuns(snapshot.explored_tiles), [snapshot.explored_tiles]);

  useEffect(() => {
    let raf = 0;
    let frames = 0;
    const draw = () => {
      const canvas = canvasRef.current;
      if (!canvas) return;
      const result = drawChart(canvas, {
        snapshot,
        locale,
        flags,
        runs,
        exploredKey: snapshot.explored_tiles,
      });
      frames += 1;
      if (result.pending && frames < MAX_RETRY_FRAMES) {
        raf = requestAnimationFrame(draw);
      }
    };
    draw();
    return () => {
      if (raf) cancelAnimationFrame(raf);
    };
  }, [snapshot, locale, flags, runs]);

  return <canvas ref={canvasRef} style={{ width: "100%", height: "100%" }} />;
}
