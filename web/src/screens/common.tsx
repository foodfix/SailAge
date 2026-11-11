/**
 * Screen authoring helpers. Screens compose the CSS-drawn kit (80-*
 * §4.9.1) directly — these keep the server projections, the toast state
 * and the at-sea hand-offs, plus the two tiny composition seams (the
 * label-class builder and the standalone intel-tab shell). They add no
 * visual CSS of their own (the audit gate would reject it).
 */
import { useCallback, useEffect, useState, type ReactNode } from "react";
import type { L10nString, L10nValue } from "../i18n";
import { useI18n } from "../i18n";
import { useGameState } from "../state/context";
import type {
  ScreenViewId,
  ScreenViewOf,
  ScreenViewState,
} from "../state/views";
import type { ScreenId } from "./ids";
import { Frame, type ToastTone } from "../kit";
import { useGameClient } from "../client/context";
import type { LiveGameClient } from "../client/http";
import type { ActionFacility, ApiResult, GameClient } from "../client/types";

/* ---------------------------------------------------------------------- */
/* Composition seams (class-string builders; no styling here)              */
/* ---------------------------------------------------------------------- */

export interface LabelOpts {
  tone?: "default" | "dim" | "accent" | "warn" | "good" | "bad";
  align?: "left" | "center" | "right";
  title?: boolean;
  heading?: boolean;
  light?: boolean;
  wrap?: boolean;
  className?: string;
}

/** The `.sa-label` class string (kit-owned visuals; screens own geometry). */
export function labelClass(opts?: LabelOpts): string {
  if (!opts) return "sa-label";
  return [
    "sa-label",
    opts.tone && opts.tone !== "default" ? `sa-label--${opts.tone}` : "",
    opts.align ? `sa-label--${opts.align}` : "",
    opts.title ? "sa-label--title" : "",
    opts.heading ? "sa-label--heading" : "",
    opts.light ? "sa-label--light" : "",
    opts.wrap ? "sa-label--wrap" : "",
    opts.className ?? "",
  ]
    .filter(Boolean)
    .join(" ");
}

/** A translated label element (the screen supplies textKey/text/textValue). */
export function Label({
  textKey,
  text,
  textValue,
  values,
  ...opts
}: LabelOpts & {
  textKey?: string;
  text?: L10nString;
  /** Already-translated text (nested fmt / computed labels). */
  textValue?: string;
  values?: Record<string, L10nValue>;
}) {
  const { t, tKey, fmt } = useI18n();
  const body = textValue ?? (text ? t(text) : textKey ? (values ? fmt(textKey, values) : tKey(textKey)) : "");
  return <div className={labelClass(opts)}>{body}</div>;
}

/* ---------------------------------------------------------------------- */
/* Toast state                                                             */
/* ---------------------------------------------------------------------- */

export interface ToastState {
  messageKey: string;
  values?: Record<string, L10nValue>;
  tone?: ToastTone;
}

export function useToastState() {
  const [toast, setToast] = useState<ToastState | null>(null);
  const showToast = useCallback(
    (messageKey: string, values?: Record<string, L10nValue>, tone?: ToastTone) => {
      setToast({ messageKey, values, tone });
    },
    [],
  );
  const clearToast = useCallback(() => setToast(null), []);
  return { toast, showToast, clearToast };
}

/* ---------------------------------------------------------------------- */
/* Server projections (90-* §0.4 — the no-rules-in-TS channel)             */
/* ---------------------------------------------------------------------- */

export interface ScreenViewResult<S extends ScreenViewId> {
  /** The projection once it has arrived; null while loading / on error. */
  view: ScreenViewOf<S> | null;
  status: ScreenViewState;
}

/**
 * Reads the active screen's server projection. The shell fetches it on
 * screen activation and on every `state` frame (`GET /api/view/<screen>`),
 * so a screen only renders server-computed values; until the projection
 * arrives it renders the shared fallback instead of inventing numbers.
 */
export function useScreenView<S extends ScreenViewId>(screen: S): ScreenViewResult<S> {
  const { views, viewStatus } = useGameState();
  const status: ScreenViewState = viewStatus[screen] ?? {
    status: views[screen] ? "ready" : "idle",
  };
  const value = status.status === "ready" ? views[screen] : undefined;
  return {
    view: (value ?? null) as ScreenViewOf<S> | null,
    status,
  };
}

/**
 * Reads a server projection for a screen that the shell does not own.
 *
 * The shell refreshes `GET /api/view/<screen>` only for the eight port
 * screens; the people surfaces also consume the `tavern` and `provisions`
 * projections (recruit rows / pooled supply days). The live transport is
 * asked for that one extra read; the fixture transport reads the
 * in-memory table. No rule is computed here.
 */
export function useFetchedView<S extends ScreenViewId>(screen: S): ScreenViewResult<S> {
  const { views, viewStatus } = useGameState();
  const client = useGameClient();
  const [fetched, setFetched] = useState<ScreenViewOf<S> | null>(null);
  const [errorKey, setErrorKey] = useState<string | undefined>(undefined);
  const shared = views[screen] as ScreenViewOf<S> | undefined;

  useEffect(() => {
    if (shared) return;
    if (client.transport !== "http") return;
    let live = true;
    const liveClient = client as unknown as LiveGameClient;
    void liveClient.getView(screen).then((envelope) => {
      if (!live) return;
      if (envelope.ok) setFetched(envelope.views);
      else setErrorKey(envelope.error.msg);
    });
    return () => {
      live = false;
    };
  }, [client, screen, shared]);

  const value = shared ?? fetched;
  const status: ScreenViewState = viewStatus[screen]
    ?? (value ? { status: "ready" } : errorKey ? { status: "error", errorKey } : { status: "idle" });
  return {
    view: status.status === "ready" ? value ?? null : null,
    status,
  };
}

/**
 * A standalone host for an embeddable tab body: a centered UW2 window on
 * the plain canvas (the intel window's tab bodies render inside the
 * window itself; the standalone routes wrap the same body).
 */
export function StandaloneFrame({
  titleKey,
  scroll,
  children,
  className,
}: {
  titleKey?: string;
  scroll?: boolean;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className="sa-screen">
      <div className="sa-fill-center">
        <Frame titleKey={titleKey} scroll={scroll} className={className}>
          {children}
        </Frame>
      </div>
    </div>
  );
}

/**
 * The at-sea talk hand-off: the picker's talk verb opens the hail route, and
 * the chosen fleet id cannot travel through the hash router. One session
 * value carries it (never a game rule; a reload simply drops it).
 */
let hailFleetId: string | null = null;

export function setHailFleetId(fleetId: string | null): void {
  hailFleetId = fleetId;
}

export function getHailFleetId(): string | null {
  return hailFleetId;
}

/**
 * The `people` / `fleet` facility verbs are frozen in the server inventory
 * (`90-*` §0.4) but absent from the frozen `ActionFacility` union in
 * `client/types.ts` (M6-c report). One cast keeps the routes honest.
 */
export function peopleAction<T = Record<string, unknown>>(
  client: GameClient,
  verb: string,
  body?: Record<string, unknown>,
): Promise<ApiResult<T>> {
  return client.action<T>("people" as unknown as ActionFacility, verb, body);
}

export function fleetAction<T = Record<string, unknown>>(
  client: GameClient,
  verb: string,
  body?: Record<string, unknown>,
): Promise<ApiResult<T>> {
  return client.action<T>("fleet" as unknown as ActionFacility, verb, body);
}

/** The loading/error state every port screen renders in place of its body. */
export function ViewFallback({
  status,
}: {
  screen?: ScreenId;
  status: ScreenViewState;
  elementId?: string;
}) {
  const { tKey } = useI18n();
  const textKey =
    status.status === "error"
      ? status.errorKey ?? "ui.not_available"
      : "connection.connecting";
  return (
    <div className="sa-screen">
      <div className="sa-fill-center">
        <Frame titleKey="ui.not_available" className="sa-frame-fallback">
          <div className="sa-cell">{tKey(textKey)}</div>
        </Frame>
      </div>
    </div>
  );
}
