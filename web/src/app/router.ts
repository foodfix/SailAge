/**
 * Hash router for the 32-screen set. The M3 shell builds the eight port
 * screens for real and stubs the rest; `#/port` is the default.
 */
import { useEffect, useState } from "react";
import { isScreenId, type ScreenId } from "../layout";

export function parseHash(hash: string): ScreenId {
  const raw = hash.replace(/^#\/?/, "").replace(/\/$/, "");
  if (isScreenId(raw)) return raw;
  // Dev seam: `?screen=world` opens a screen directly when no hash route is
  // present (the navigation gates use it); a hash route always wins.
  if (!raw) {
    const screen = new URLSearchParams(window.location.search).get("screen");
    if (screen && isScreenId(screen)) return screen;
  }
  return "port";
}

export function navigate(screen: ScreenId): void {
  window.location.hash = `#/${screen}`;
}

export function useScreenRoute(): ScreenId {
  const [screen, setScreen] = useState<ScreenId>(() => parseHash(window.location.hash));

  useEffect(() => {
    const onChange = () => {
      const next = parseHash(window.location.hash);
      setScreen(next);
      if (window.location.hash !== `#/${next}`) {
        window.history.replaceState(null, "", `#/${next}`);
      }
    };
    window.addEventListener("hashchange", onChange);
    onChange();
    return () => window.removeEventListener("hashchange", onChange);
  }, []);

  return screen;
}
