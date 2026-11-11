/**
 * The shared dialog box (docs/80-UI-UX.md §4.7: `dialog_box.tscn` — message +
 * OK, centred, dimming the background; chained events queue and show one at a
 * time, never simultaneously; §4.3: Enter/Y confirm).
 *
 * Two shapes, one component:
 *  · **in place** — `<DialogBox request={…} onClose={…}/>` for a host screen;
 *  · **routed** — the `dialog_box` screen id, fed by `showDialog(request)` /
 *    `enqueueDialogs(requests)`. `showDialog` resolves when the player
 *    acknowledges; `enqueueDialogs` is the §4.7 day-dialog queue (storm damage
 *    → desertion → greeting, in fixed order).
 *
 * Optional `entries` are the key/value lines the day-dialog queue carries
 * (e.g. damage amounts); each is one `<Row>` inside the message body, so no
 * new layout rows are invented.
 */
import { useCallback, useEffect, useSyncExternalStore } from "react";
import { navigate, parseHash } from "../app/router";
import { useI18n, type L10nString, type L10nValue } from "../i18n";
import { Element, type ScreenId } from "../layout";
import type { SpriteId } from "../assets/sprites";
import { useGameState } from "../state/context";
import { ButtonEl, PanelEl } from "./common";
import { defaultBackScreen } from "./Confirm";
import { Icon, Row } from "../kit";

export const DIALOG_SCREEN: ScreenId = "dialog_box";

/** One key/value line in the dialog body (the day-dialog queue's detail). */
export interface DialogEntry {
  /** i18n key for the label (preferred). */
  labelKey?: string;
  /** `{placeholder}` values for the label key. */
  labelValues?: Record<string, L10nValue>;
  /** Already-resolved label (content L10nString). */
  label?: L10nString;
  /** The value: a number, an already-localized string, or a content L10nString. */
  value?: string | number | L10nString;
}

export interface DialogRequest {
  /** Optional heading line above the message (i18n key). */
  titleKey?: string;
  messageKey?: string;
  message?: L10nString;
  values?: Record<string, L10nValue>;
  /** Key/value detail lines (the day-dialog queue). */
  entries?: DialogEntry[];
  okKey?: string;
  /** The §4.10.1-adjacent marker/icon sprite; defaults to the bell. */
  icon?: SpriteId;
  /** The route to return to when the box closes (default: the opener). */
  opener?: ScreenId;
}

interface PendingDialog {
  request: DialogRequest;
  resolve: () => void;
}

let queue: PendingDialog[] = [];
const listeners = new Set<() => void>();

function emit(): void {
  queue = [...queue];
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function snapshot(): PendingDialog[] {
  return queue;
}

function push(request: DialogRequest, resolve: () => void): void {
  const opener = request.opener ?? parseHash(window.location.hash);
  queue.push({ request: { ...request, opener }, resolve });
  emit();
}

/** Queue one dialog and open the routed dialog screen; resolves on OK. */
export function showDialog(request: DialogRequest): Promise<void> {
  return new Promise<void>((resolve) => {
    push(request, resolve);
    navigate(DIALOG_SCREEN);
  });
}

/**
 * Queue a fixed-order chain (§4.7: chained events never show simultaneously).
 * The routed screen advances one per OK; the last one returns to the opener.
 */
export function enqueueDialogs(requests: readonly DialogRequest[]): void {
  if (requests.length === 0) return;
  for (const request of requests) push(request, () => undefined);
  navigate(DIALOG_SCREEN);
}

function dismiss(fallback: ScreenId): void {
  const head = queue[0];
  if (!head) {
    navigate(fallback);
    return;
  }
  queue = queue.slice(1);
  emit();
  head.resolve();
  if (queue.length === 0) navigate(head.request.opener ?? fallback);
}

export interface DialogBoxProps {
  request: DialogRequest;
  onClose: () => void;
}

/** The shared dialog body (in-place and routed shapes both render this). */
export function DialogBox({ request, onClose }: DialogBoxProps) {
  const { t, tKey, fmt } = useI18n();

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const key = event.key.toLowerCase();
      if (key === "enter" || key === "y" || key === "escape") {
        event.preventDefault();
        onClose();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const message = request.messageKey
    ? fmt(request.messageKey, request.values ?? {})
    : request.message
      ? t(request.message)
      : "";

  const entryText = (value: DialogEntry["value"]): string => {
    if (value === undefined) return "";
    if (typeof value === "object") return t(value);
    return String(value);
  };

  const entryLabel = (entry: DialogEntry): string => {
    if (entry.labelKey) {
      return entry.labelValues ? fmt(entry.labelKey, entry.labelValues) : tKey(entry.labelKey);
    }
    return entry.label ? t(entry.label) : "";
  };

  return (
    <>
      <Element screen={DIALOG_SCREEN} id="dim" className="sa-dim" />
      <PanelEl screen={DIALOG_SCREEN} id="panel">
        <Element screen={DIALOG_SCREEN} id="panel.body" parent="panel">
          <Element screen={DIALOG_SCREEN} id="panel.body.icon" parent="panel.body">
            <Icon id={request.icon ?? "bell"} />
          </Element>
          <Element screen={DIALOG_SCREEN} id="panel.body.message" parent="panel.body">
            {request.titleKey ? (
              <div className="sa-label sa-label--heading">{tKey(request.titleKey)}</div>
            ) : null}
            <div className="sa-label">{message}</div>
            {(request.entries ?? []).map((entry, index) => (
              <Row
                key={index}
                cols={[
                  <span className="sa-cell" key="label">
                    {entryLabel(entry)}
                  </span>,
                  <span className="sa-cell sa-label--right" key="value">
                    {entryText(entry.value)}
                  </span>,
                ]}
              />
            ))}
          </Element>
        </Element>
        <ButtonEl
          screen={DIALOG_SCREEN}
          id="panel.ok"
          parent="panel"
          text={tKey(request.okKey ?? "ui.ok")}
          kind="primary"
          onClick={onClose}
        />
      </PanelEl>
    </>
  );
}

/** The routed `dialog_box` screen (§4.2 / DevNav). */
export function DialogScreen() {
  const { state } = useGameState();
  const pending = useSyncExternalStore(subscribe, snapshot, snapshot);
  const head = pending[0];
  const fallback = defaultBackScreen(state.current_port);
  const onClose = useCallback(() => dismiss(fallback), [fallback]);

  const request: DialogRequest = head?.request ?? { opener: fallback };
  return <DialogBox request={request} onClose={onClose} />;
}
