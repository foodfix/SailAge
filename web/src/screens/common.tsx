/**
 * Screen authoring helpers. These only compose the kit + layout layers;
 * they add no styling of their own (the audit gate would reject it).
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
import { Box, Element, type ScreenId, type SheetId, type TileRect } from "../layout";
import { Button, Icon, type ButtonKind, type ToastTone } from "../kit";
import type { SpriteId } from "../assets/sprites";
import { useGameClient } from "../client/context";
import type { LiveGameClient } from "../client/http";
import type { ActionFacility, ApiResult, GameClient } from "../client/types";

export type LabelTone = "default" | "dim" | "accent" | "warn" | "good" | "bad";
export type LabelAlign = "left" | "center" | "right";

export interface LabelElProps {
  screen: ScreenId;
  id: string;
  parent?: string;
  textKey?: string;
  text?: L10nString;
  /** Already-translated text (nested fmt / computed labels). */
  textValue?: string;
  values?: Record<string, L10nValue>;
  tone?: LabelTone;
  align?: LabelAlign;
  title?: boolean;
  heading?: boolean;
  hidden?: boolean;
}

export function LabelEl({
  screen,
  id,
  parent,
  textKey,
  text,
  textValue,
  values,
  tone = "default",
  align,
  title,
  heading,
  hidden,
}: LabelElProps) {
  const { t, tKey, fmt } = useI18n();
  const body = textValue ?? (text ? t(text) : textKey ? (values ? fmt(textKey, values) : tKey(textKey)) : "");
  const classes = [
    "sa-label",
    tone !== "default" ? `sa-label--${tone}` : "",
    align ? `sa-label--${align}` : "",
    title ? "sa-label--title" : "",
    heading ? "sa-label--heading" : "",
  ]
    .filter(Boolean)
    .join(" ");
  return (
    <Element screen={screen} id={id} parent={parent} className={classes} hidden={hidden}>
      {body}
    </Element>
  );
}

export interface ButtonElProps {
  screen: ScreenId;
  id: string;
  parent?: string;
  textKey?: string;
  text?: string;
  kind?: ButtonKind;
  icon?: SpriteId;
  onClick?: () => void;
  disabled?: boolean;
  hidden?: boolean;
  titleKey?: string;
}

export function ButtonEl({
  screen,
  id,
  parent,
  textKey,
  text,
  kind,
  icon,
  onClick,
  disabled,
  hidden,
  titleKey,
}: ButtonElProps) {
  return (
    <Element screen={screen} id={id} parent={parent} hidden={hidden}>
      <Button
        textKey={textKey}
        text={text}
        kind={kind}
        icon={icon}
        onClick={onClick}
        disabled={disabled}
        titleKey={titleKey}
        fill
      />
    </Element>
  );
}

export interface PanelElProps {
  screen: ScreenId;
  id: string;
  parent?: string;
  skin?: SheetId;
  className?: string;
  hidden?: boolean;
  children?: ReactNode;
}

export function PanelEl({ screen, id, parent, skin = "panel", className, hidden, children }: PanelElProps) {
  return (
    <Element screen={screen} id={id} parent={parent} skin={skin} className={className} hidden={hidden}>
      {children}
    </Element>
  );
}

export interface IconBoxProps {
  rect: TileRect;
  id: SpriteId;
  className?: string;
}

export function IconBox({ rect, id, className }: IconBoxProps) {
  return (
    <Box rect={rect} className={className}>
      <Icon id={id} />
    </Box>
  );
}

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
 * The M3 shell refreshes `GET /api/view/<screen>` only for the eight port
 * screens; the M6-c people surfaces also consume the `tavern` and
 * `provisions` projections (recruit rows / pooled supply days). The live
 * transport is asked for that one extra read; the fixture transport reads
 * the in-memory table. No rule is computed here.
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
 * A standalone host for an embeddable tab body: the 60 × 33.75 backdrop
 * plus a centered 32 × 12 page plate. The body rows keep their authored
 * 0,0-relative coordinates.
 */
export function StandaloneFrame({
  children,
  rect = { x: 14, y: 10.5, w: 32, h: 12 },
}: {
  children: ReactNode;
  rect?: TileRect;
}) {
  return (
    <div className="sa-screen">
      <Box rect={{ x: 0, y: 0, w: 60, h: 33.75 }} skin="backdrop" />
      <Box rect={rect} skin="panel">
        {children}
      </Box>
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
  screen,
  status,
  elementId = "background",
}: {
  screen: ScreenId;
  status: ScreenViewState;
  elementId?: string;
}) {
  const { tKey } = useI18n();
  const textKey =
    status.status === "error"
      ? status.errorKey ?? "ui.not_available"
      : "connection.connecting";
  return (
    <PanelEl screen={screen} id={elementId} skin="backdrop">
      <div className="sa-cell">{tKey(textKey)}</div>
    </PanelEl>
  );
}
