/**
 * S3 keyboard input (docs/80-UI-UX.md §4.3; docs/20-WORLD-AND-SAILING.md
 * §4.2, §4.17).
 *
 * The client only turns keys into frozen intents (`90-*` §0.3) — no movement
 * rule runs here. Step mode: a direction keydown sends `helm {dir}` on change
 * and any release sends `{dir:"stop"}`. Helm mode: a direction key latches the
 * persisted heading and releases send nothing; `Space` stops a moving helm and
 * a second `Space` waits one day.
 */
import { useEffect, useRef } from "react";
import type { GameClient } from "../../client/types";
import type { Direction8, GameSnapshot, SailTrim } from "../../state/types";
import { DIRECTION_DELTAS, TRIM_ORDER } from "./constants";

const KEYS: Record<string, Direction8> = {
  arrowup: "N",
  arrowdown: "S",
  arrowleft: "W",
  arrowright: "E",
  w: "N",
  a: "W",
  s: "S",
  d: "E",
};

const NUMPAD: Record<string, Direction8> = {
  Numpad8: "N",
  Numpad2: "S",
  Numpad4: "W",
  Numpad6: "E",
  Numpad7: "NW",
  Numpad9: "NE",
  Numpad1: "SW",
  Numpad3: "SE",
};

function directionOf(event: KeyboardEvent): Direction8 | null {
  const byCode = NUMPAD[event.code];
  if (byCode) return byCode;
  if (event.metaKey || event.ctrlKey || event.altKey) return null;
  return KEYS[event.key.toLowerCase()] ?? null;
}

function nextTrim(current: SailTrim, forward: boolean): SailTrim {
  const index = TRIM_ORDER.indexOf(current);
  const base = index >= 0 ? index : TRIM_ORDER.indexOf("normal");
  const size = TRIM_ORDER.length;
  return TRIM_ORDER[(((base + (forward ? 1 : -1)) % size) + size) % size];
}

export interface WorldInputOptions {
  client: GameClient;
  snapshot: GameSnapshot;
  trim: SailTrim;
  /** Called on Esc while docked (the caller routes back to the port hub). */
  onDock: () => void;
  /** `Z` camera toggle — session-local, never persisted (§4.8). */
  onToggleZoom: () => void;
}

export function useWorldInput({ client, snapshot, trim, onDock, onToggleZoom }: WorldInputOptions): void {
  const trimRef = useRef(trim);
  trimRef.current = trim;
  const snapshotRef = useRef(snapshot);
  snapshotRef.current = snapshot;

  useEffect(() => {
    /** Direction keys currently held, most recent last. */
    const held: { key: string; dir: Direction8 }[] = [];
    let helmMoving = false;

    const helmMode = () => snapshotRef.current.control_prefs.input_mode === "helm";

    const sendHelm = (dir: Direction8 | "stop") => {
      client.send({ type: "helm", dir });
      helmMoving = dir !== "stop";
    };

    const onKeyDown = (event: KeyboardEvent) => {
      const target = event.target;
      if (target instanceof HTMLElement) {
        const tag = target.tagName.toLowerCase();
        if (tag === "input" || tag === "textarea" || target.isContentEditable) return;
      }
      if (event.repeat) return;

      const dir = directionOf(event);
      if (dir) {
        event.preventDefault();
        const key = event.code || event.key;
        if (held.some((entry) => entry.key === key)) return;
        held.push({ key, dir });
        // Both modes emit the same intent; `input_mode` decides whether the
        // server treats it as one step or a latched helm course (§4.2).
        sendHelm(dir);
        return;
      }

      if (event.code === "Space") {
        event.preventDefault();
        if (helmMode() && helmMoving) {
          sendHelm("stop");
        } else {
          client.send({ type: "wait" });
        }
        return;
      }

      if (event.key === "]") {
        event.preventDefault();
        client.send({ type: "sail_trim", trim: nextTrim(trimRef.current, true) });
        return;
      }
      if (event.key === "[") {
        event.preventDefault();
        client.send({ type: "sail_trim", trim: nextTrim(trimRef.current, false) });
        return;
      }
      if (event.key === "Escape") {
        if (snapshotRef.current.current_port) onDock();
        return;
      }
      if (event.key.toLowerCase() === "z") {
        event.preventDefault();
        onToggleZoom();
        return;
      }
      if (event.key === "Tab") {
        // Chart seam: S17 (Tab) is a separate fullscreen overlay and lands
        // with the M6 chart screen; swallow the focus jump until then.
        event.preventDefault();
      }
    };

    const onKeyUp = (event: KeyboardEvent) => {
      const dir = directionOf(event);
      if (!dir) return;
      event.preventDefault();
      if (helmMode()) return; // a helm course is latched (§4.2)
      const key = event.code || event.key;
      const index = held.findIndex((entry) => entry.key === key);
      if (index >= 0) held.splice(index, 1);
      sendHelm(held.length > 0 ? held[held.length - 1].dir : "stop");
    };

    const onBlur = () => {
      held.length = 0;
      if (!helmMode()) sendHelm("stop");
    };

    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("keyup", onKeyUp);
    window.addEventListener("blur", onBlur);
    return () => {
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("keyup", onKeyUp);
      window.removeEventListener("blur", onBlur);
    };
  }, [client, onDock, onToggleZoom]);
}

/** Tile delta of a direction token (fixture + tests). */
export function stepOf(dir: Direction8): { x: number; y: number } {
  return DIRECTION_DELTAS[dir];
}
