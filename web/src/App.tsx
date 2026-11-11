/**
 * App — the composition root. Two transports:
 *
 *  * **live (default):** the frozen `GameClient` over the FastAPI server
 *    (`client/http.ts`) — `GET /api/state` + one WS (`/ws`, §0.3) feed this
 *    provider, and every `state` frame refreshes the active screen's
 *    server projection (`GET /api/view/<screen>`, §0.4). All rules stay in
 *    Python (90-* §0.1).
 *  * **fixture (`?fixture=1`):** the offline demo client + fixture state
 *    (the M3 foundation), unchanged.
 *
 * The canvas is the 1920 × 1080 design surface (80-* §4.8.9); its scale is
 * measured from the viewport so the authored pixel rects need no math.
 */
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";
import { fixtureClient } from "./client/fixture";
import { GameClientProvider } from "./client/context";
import { createHttpClient, CLOSE_OTHER_CLIENT, type LiveGameClient } from "./client/http";
import type {
  BattleTickFrame,
  EventFrame,
  GameClient,
  ServerFrame,
  TickFrame,
} from "./client/types";import { fixtureState, fixtureViews } from "./state/fixture";
import { GameStateProvider, useGameState, type GameStateValue } from "./state/context";
import type { GameSnapshot } from "./state/types";
import { isScreenViewId, type ScreenViewId, type ScreenViews, type ScreenViewState } from "./state/views";
import { I18nProvider, useI18n } from "./i18n";
import { Toast } from "./kit";
import { ScreenHost } from "./screens";
import { navigate, useScreenRoute } from "./app/router";
import { DevNav } from "./app/DevNav";
import type { ScreenId } from "./screens/ids";

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

/**
 * Run-end routing (M6-a integration gap): a `game_over` event or a retired
 * snapshot lands on its bookend screen once. Port/world screens never
 * navigate themselves, so this is the one global handler.
 */
function RunEndRouter({ screen }: { screen: ScreenId }) {
  const { state, lastEvent } = useGameState();
  useEffect(() => {
    if (!state) return;
    const over = lastEvent?.type === "event" && lastEvent.name === "game_over";
    if (over && screen !== "gameover") {
      navigate("gameover");
      return;
    }
    if (state.retired && screen !== "ending" && screen !== "title") {
      navigate("ending");
    }
  }, [state, lastEvent, screen]);
  return null;
}

/** 80-* §4.2/§4.6: `Tab` opens the Chart from the world/port and closes back. */
function ChartHotkey({ screen }: { screen: ScreenId }) {
  const { state } = useGameState();
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Tab") return;
      event.preventDefault();
      if (screen === "chart") {
        navigate(state?.current_port != null ? "port" : "world");
        return;
      }
      if (screen === "world" || screen === "port") navigate("chart");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [screen, state]);
  return null;
}

interface ShellProps {
  screen: ScreenId;
  children: ReactNode;
}

/** The scaled 60 × 33.75 tile canvas + the dev screen index. */
function Shell({ screen, children }: ShellProps) {
  const { canvasRef, scale } = useCanvasScale();
  return (
    <>
      <div className="sa-viewport" style={{ "--sa-scale": scale } as CSSProperties}>
        <div className="sa-frame-box">
          <div ref={canvasRef} className="sa-canvas" data-current-screen={screen}>
            {children}
          </div>
        </div>
      </div>
      <DevNav screen={screen} />
    </>
  );
}

/** The boot / connection notice frame (outside any screen projection). */
function ShellNotice({ messageKey }: { messageKey: string }) {
  const { tKey } = useI18n();
  return (
    <div className="sa-viewport">
      <div className="sa-frame-box">
        <div className="sa-canvas">
          <div className="sa-cell">{tKey(messageKey)}</div>
        </div>
      </div>
    </div>
  );
}

/* ---------------------------------------------------------------------- */
/* Fixture mode (?fixture=1) — the M3 foundation, unchanged                */
/* ---------------------------------------------------------------------- */

const FIXTURE_VIEW_STATUS: Record<ScreenViewId, ScreenViewState> = {
  port: { status: "ready" },
  market: { status: "ready" },
  provisions: { status: "ready" },
  shipyard: { status: "ready" },
  inn: { status: "ready" },
  guild: { status: "ready" },
  palace: { status: "ready" },
  tavern: { status: "ready" },
};

function FixtureApp({ screen }: { screen: ScreenId }) {
  const value = useMemo<GameStateValue>(
    () => ({
      state: fixtureState,
      views: fixtureViews,
      viewStatus: FIXTURE_VIEW_STATUS,
      tick: null,
      battleTick: null,
      lastEvent: null,
    }),
    [],
  );
  return (
    <GameClientProvider client={fixtureClient}>
      <GameStateProvider value={value}>
        <I18nProvider onLocaleChange={(locale) => void fixtureClient.setLocale(locale)}>
          <LocaleHotkey />
          <RunEndRouter screen={screen} />
          <ChartHotkey screen={screen} />
          <Shell screen={screen}>
            <ScreenHost screen={screen} />
          </Shell>
        </I18nProvider>
      </GameStateProvider>
    </GameClientProvider>
  );
}

/* ---------------------------------------------------------------------- */
/* Live mode (default) — the FastAPI server                                */
/* ---------------------------------------------------------------------- */

interface LiveController {
  state: GameSnapshot | null;
  views: Partial<ScreenViews>;
  viewStatus: Partial<Record<ScreenViewId, ScreenViewState>>;
  tick: TickFrame | null;
  battleTick: BattleTickFrame | null;
  lastEvent: EventFrame | null;
  noticeKey: string | null;
  toastKey: string | null;
  dismissToast: () => void;
  loadView: (screen: ScreenViewId) => void;
}

function useLiveGame(client: LiveGameClient, screen: ScreenId): LiveController {
  const [state, setState] = useState<GameSnapshot | null>(null);
  const [views, setViews] = useState<Partial<ScreenViews>>({});
  const [viewStatus, setViewStatus] = useState<Partial<Record<ScreenViewId, ScreenViewState>>>({});
  const [tick, setTick] = useState<TickFrame | null>(null);
  const [battleTick, setBattleTick] = useState<BattleTickFrame | null>(null);
  const [lastEvent, setLastEvent] = useState<EventFrame | null>(null);
  const [noticeKey, setNoticeKey] = useState<string | null>(null);
  const [toastKey, setToastKey] = useState<string | null>(null);

  const loadView = useCallback(
    (target: ScreenViewId) => {
      if (!isScreenViewId(target)) return;
      setViewStatus((prev) => ({ ...prev, [target]: { status: "loading" } }));
      void client.getView(target).then((envelope) => {
        if (envelope.ok) {
          setViews((prev) => ({ ...prev, [target]: envelope.views }));
          setViewStatus((prev) => ({ ...prev, [target]: { status: "ready" } }));
        } else {
          setViewStatus((prev) => ({
            ...prev,
            [target]: { status: "error", errorKey: envelope.error.msg },
          }));
        }
      });
    },
    [client],
  );

  useEffect(() => {
    const onFrame = (frame: ServerFrame) => {
      if (frame.type === "state") {
        const snapshot = { ...frame } as GameSnapshot;
        setState(snapshot);
        return;
      }
      if (frame.type === "tick") {
        setTick(frame);
        return;
      }
      if (frame.type === "battle_tick") {
        setBattleTick(frame);
        return;
      }
      if (frame.type === "event") {
        // The notification transcript (§0.3 `event` = the §5.1 EventBus
        // table). M4/M5 surfaces consume `lastEvent`; no M3 port screen
        // renders a toast from it yet.
        setLastEvent(frame);
        return;
      }
      if (frame.type === "error") {
        setToastKey(frame.msg);
      }
    };
    const unsubscribe = client.connect({
      onFrame,
      onClose: (code) => {
        if (code === CLOSE_OTHER_CLIENT) setNoticeKey("connection.other_client");
      },
    });
    void client
      .getState()
      .then((snapshot) => setState(snapshot))
      .catch(() => setNoticeKey("connection.lost"));
    return unsubscribe;
  }, [client]);

  // On screen activation and after every `state` frame, refresh the view.
  useEffect(() => {
    if (isScreenViewId(screen)) loadView(screen);
  }, [screen, loadView]);
  useEffect(() => {
    if (state && isScreenViewId(screen)) loadView(screen);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state]);

  const dismissToast = useCallback(() => setToastKey(null), []);

  return {
    state,
    views,
    viewStatus,
    tick,
    battleTick,
    lastEvent,
    noticeKey,
    toastKey,
    dismissToast,
    loadView,
  };
}

function LiveApp({ screen }: { screen: ScreenId }) {
  const [client] = useState<LiveGameClient>(() => createHttpClient());
  const live = useLiveGame(client, screen);

  const value = useMemo<GameStateValue | null>(() => {
    if (!live.state) return null;
    return {
      state: live.state,
      views: live.views,
      viewStatus: live.viewStatus,
      tick: live.tick,
      battleTick: live.battleTick,
      lastEvent: live.lastEvent,
    };
  }, [live.state, live.views, live.viewStatus, live.tick, live.battleTick, live.lastEvent]);

  let body: ReactNode;
  if (live.noticeKey) {
    body = <ShellNotice messageKey={live.noticeKey} />;
  } else if (!value) {
    body = <ShellNotice messageKey="connection.connecting" />;
  } else {
    body = (
      <Shell screen={screen}>
        <ScreenHost screen={screen} />
      </Shell>
    );
  }

  return (
    <GameClientProvider client={client as GameClient}>
      <I18nProvider onLocaleChange={(locale) => void client.setLocale(locale)}>
        <LocaleHotkey />
        {value ? (
          <GameStateProvider value={value}>
            <RunEndRouter screen={screen} />
            <ChartHotkey screen={screen} />
            {body}
            {live.toastKey ? (
              <Toast messageKey={live.toastKey} onDismiss={live.dismissToast} tone="bad" />
            ) : null}
          </GameStateProvider>
        ) : (
          body
        )}
      </I18nProvider>
    </GameClientProvider>
  );
}

export default function App() {
  const screen = useScreenRoute();
  const fixtureMode = useMemo(
    () => new URLSearchParams(window.location.search).get("fixture") === "1",
    [],
  );
  return fixtureMode ? <FixtureApp screen={screen} /> : <LiveApp screen={screen} />;
}
