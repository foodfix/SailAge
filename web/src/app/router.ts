/**
 * Hash router for the 32-screen set. The M3 shell builds the eight port
 * screens for real and stubs the rest; `#/port` is the default.
 */
import { useEffect, useState } from "react";
import { isScreenId, type ScreenId } from "../layout";

export function parseHash(hash: string): ScreenId {
  const raw = hash.replace(/^#\/?/, "").replace(/\/$/, "");
  return isScreenId(raw) ? raw : "port";
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
