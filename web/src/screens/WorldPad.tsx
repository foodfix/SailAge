/**
 * The S3 virtual helm pad (docs/80-UI-UX.md §4.9.2) — the touch
 * equivalent of the §4.3 sailing keys, hidden on fine-pointer viewports.
 *
 * Presentation only: every press sends the same frozen intent its key
 * sends (`90-*` §0.3) — `helm {dir}` with the keyboard's release
 * semantics (a latched course in Helm mode, `{dir:"stop"}` in Step
 * mode), the center cell mirrors `Space` (stop a moving helm / wait one
 * day), and the side column cycles the sail trim (`]`), toggles the two
 * camera zoom levels (`Z`) and opens the Chart (`Tab`). No movement
 * rule lives here; the server owns hold-to-repeat.
 */
import { useCallback, useRef, useState } from "react";
import { useGameClient } from "../client/context";
import { navigate } from "../app/router";
import { useI18n } from "../i18n";
import { cycleTrim } from "../canvas/world";
import type { Direction8, SailTrim } from "../state/types";

const PAD_DIRS: { dir: Direction8; glyph: string }[] = [
  { dir: "NW", glyph: "↖" },
  { dir: "N", glyph: "↑" },
  { dir: "NE", glyph: "↗" },
  { dir: "W", glyph: "←" },
  { dir: "E", glyph: "→" },
  { dir: "SW", glyph: "↙" },
  { dir: "S", glyph: "↓" },
  { dir: "SE", glyph: "↘" },
];

export interface WorldPadProps {
  trim: SailTrim;
  /** `control_prefs.input_mode` — decides the release semantics. */
  inputMode: string;
  /** The `Z` camera toggle (session-local, never persisted). */
  onToggleZoom: () => void;
}

export function WorldPad({ trim, inputMode, onToggleZoom }: WorldPadProps) {
  const client = useGameClient();
  const { tKey } = useI18n();
  const helmMode = inputMode === "helm";
  // The center cell's label follows the Space semantics: a moving helm
  // stops, everything else waits one day.
  const [moving, setMoving] = useState(false);
  /** Pointers currently holding a direction cell, in press order. */
  const held = useRef<Map<number, Direction8>>(new Map());

  const sendHelm = useCallback(
    (dir: Direction8 | "stop") => {
      client.send({ type: "helm", dir });
      setMoving(dir !== "stop");
    },
    [client],
  );

  const currentHeld = useCallback((): Direction8 | "stop" => {
    const dirs = [...held.current.values()];
    return dirs.length > 0 ? dirs[dirs.length - 1] : "stop";
  }, []);

  const onDirDown = useCallback(
    (pointerId: number, dir: Direction8) => {
      held.current.set(pointerId, dir);
      sendHelm(dir);
    },
    [sendHelm],
  );

  const onDirUp = useCallback(
    (pointerId: number) => {
      held.current.delete(pointerId);
      // A Helm course is latched — releasing sends nothing (§4.3).
      if (helmMode) return;
      sendHelm(currentHeld());
    },
    [currentHeld, helmMode, sendHelm],
  );

  const onCenterPress = useCallback(() => {
    if (helmMode && moving) sendHelm("stop");
    else client.send({ type: "wait" });
  }, [client, helmMode, moving, sendHelm]);

  const onTrimPress = useCallback(() => {
    client.send({ type: "sail_trim", trim: cycleTrim(trim) });
  }, [client, trim]);

  return (
    <div className="world__pad" onContextMenu={(event) => event.preventDefault()}>
      <div className="world__pad_side">
        <button type="button" className="sa-button world__pad_key" onClick={onTrimPress}>
          {tKey(`world.trim.${trim}`)}
        </button>
        <button type="button" className="sa-button world__pad_key" onClick={onToggleZoom}>
          {tKey("world.pad.zoom")}
        </button>
        <button type="button" className="sa-button world__pad_key" onClick={() => navigate("chart")}>
          {tKey("chart.title")}
        </button>
      </div>
      <div className="world__pad_ring">
        {PAD_DIRS.map(({ dir, glyph }) => (
          <button
            key={dir}
            type="button"
            data-dir={dir}
            className="sa-button world__pad_cell"
            onPointerDown={(event) => {
              event.currentTarget.setPointerCapture(event.pointerId);
              onDirDown(event.pointerId, dir);
            }}
            onPointerUp={(event) => onDirUp(event.pointerId)}
            onPointerCancel={(event) => onDirUp(event.pointerId)}
          >
            {glyph}
          </button>
        ))}
        <button
          type="button"
          className="sa-button sa-button--primary world__pad_cell world__pad_cell_center"
          onPointerDown={(event) => {
            event.currentTarget.setPointerCapture(event.pointerId);
            onCenterPress();
          }}
        >
          {tKey(helmMode && moving ? "world.pad.stop" : "world.pad.wait")}
        </button>
      </div>
    </div>
  );
}
