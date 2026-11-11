/**
 * App — the M3 shell. Composition root:
 *   fixture state -> fixture client -> i18n -> scaled 60 × 33.75 canvas.
 *
 * The canvas is the 1920 × 1080 design surface (80-* §4.8.9); its scale is
 * measured from the viewport so the authored pixel rects need no math.
 */
import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import { fixtureClient } from "./client/fixture";
import { GameClientProvider } from "./client/context";
import { fixtureState, fixtureViews } from "./state/fixture";
import { GameStateProvider } from "./state/context";
import { I18nProvider, useI18n } from "./i18n";
import { ScreenHost } from "./screens";
import { useScreenRoute } from "./app/router";
import { DevNav } from "./app/DevNav";

function useCanvasScale() {
  const canvasRef = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(1);

  useLayoutEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const update = () => {
      const width = canvas.offsetWidth;
      const height = canvas.offsetHeight;
      if (width > 0 && height > 0) {
        setScale(Math.min(window.innerWidth / width, window.innerHeight / height));
      }
    };
    update();
    window.addEventListener("resize", update);
    return () => window.removeEventListener("resize", update);
  }, []);

  return { canvasRef, scale };
}

/** 80-* §4.3: the `L` key toggles zh/en (persisted by the locale store). */
function LocaleHotkey() {
  const { toggleLocale } = useI18n();
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key?.toLowerCase() !== "l" || event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target;
      if (target instanceof HTMLElement) {
        const tag = target.tagName.toLowerCase();
        if (tag === "input" || tag === "textarea") return;
      }
      toggleLocale();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [toggleLocale]);
  return null;
}

export default function App() {
  const screen = useScreenRoute();
  const { canvasRef, scale } = useCanvasScale();

  return (
    <GameClientProvider client={fixtureClient}>
      <GameStateProvider value={{ state: fixtureState, views: fixtureViews }}>
        <I18nProvider onLocaleChange={(locale) => void fixtureClient.setLocale(locale)}>
          <LocaleHotkey />
          <div className="sa-viewport" style={{ "--sa-scale": scale } as CSSProperties}>
            <div className="sa-frame-box">
              <div ref={canvasRef} className="sa-canvas" data-current-screen={screen}>
                <ScreenHost screen={screen} />
              </div>
            </div>
          </div>
          <DevNav screen={screen} />
        </I18nProvider>
      </GameStateProvider>
    </GameClientProvider>
  );
}
