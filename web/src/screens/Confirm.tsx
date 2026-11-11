/**
 * The shared confirm dialog (docs/80-UI-UX.md §4.9.1: dialogs are indigo
 * message windows — gold frames over the dim layer; §4.7: message +
 * confirm/cancel, centred; §4.3: Enter/Y confirm, N/Esc cancel).
 *
 * Two shapes, one component:
 *  · **in place** — `<ConfirmDialog request={…} onConfirm={…} onCancel={…}/>`
 *    rendered by a host screen (e.g. Settings' return-to-menu row);
 *  · **routed** — the `confirm` screen id, driven by the imperative
 *    `confirmAction(request): Promise<boolean>` helper. The helper records the
 *    opener route and returns there on resolution (or goes to `request.next`
 *    on confirm), so any screen can `if (await confirmAction({…})) …`.
 *
 * The dialog owns all input while open (modal rule). The routed shape cannot
 * dim a live host — the router swaps screens — so the dim plate covers the
 * canvas background; in-place usage dims the host screen as the doc intends.
 */
import { useCallback, useEffect, useSyncExternalStore } from "react";
import { navigate, parseHash } from "../app/router";
import { useI18n, type L10nString, type L10nValue } from "../i18n";
import type { ScreenId } from "./ids";
import { useGameState } from "../state/context";
import { Button, Dialog, Footer } from "../kit";
import { Label } from "./common";
import "./Confirm.css";

export const CONFIRM_SCREEN: ScreenId = "confirm";

export interface ConfirmRequest {
  /** Optional heading line above the message (i18n key). */
  titleKey?: string;
  /** The question (i18n key; `values` fills `{placeholders}`). */
  messageKey?: string;
  /** Already-resolved question (content L10nString) — used instead of messageKey. */
  message?: L10nString;
  values?: Record<string, L10nValue>;
  confirmKey?: string;
  cancelKey?: string;
  /** The destructive-action rule (§4.7): paints the confirm button as danger. */
  destructive?: boolean;
  /** The route to return to when the dialog closes (default: the opener). */
  opener?: ScreenId;
  /** Where a confirmed action navigates next (default: the opener). */
  next?: ScreenId;
}

interface PendingConfirm {
  request: ConfirmRequest;
  resolve: (confirmed: boolean) => void;
}

let queue: PendingConfirm[] = [];
const listeners = new Set<() => void>();

function emit(): void {
  queue = [...queue];
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function snapshot(): PendingConfirm[] {
  return queue;
}

/** The run's landing route when a modal has no recorded opener (§4.2). */
export function defaultBackScreen(currentPort: string | null): ScreenId {
  return currentPort ? "port" : "world";
}

/**
 * Open the routed confirm dialog and resolve when the player answers.
 * The promise never rejects; a dismissed dialog resolves `false`.
 */
export function confirmAction(request: ConfirmRequest): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    const opener = request.opener ?? parseHash(window.location.hash);
    queue.push({ request: { ...request, opener }, resolve });
    emit();
    navigate(CONFIRM_SCREEN);
  });
}

function resolveHead(confirmed: boolean, fallback: ScreenId): void {
  const head = queue[0];
  if (!head) {
    navigate(fallback);
    return;
  }
  queue = queue.slice(1);
  emit();
  head.resolve(confirmed);
  if (queue.length > 0) return; // the next queued dialog keeps the route open
  const target = confirmed ? (head.request.next ?? head.request.opener ?? fallback) : (head.request.opener ?? fallback);
  // The caller's continuation (promise microtask) may navigate too; an
  // explicit `next` wins by construction.
  navigate(target);
}

export interface ConfirmDialogProps {
  request: ConfirmRequest;
  onConfirm: () => void;
  onCancel: () => void;
}

/** The shared dialog body (in-place and routed shapes both render this). */
export function ConfirmDialog({ request, onConfirm, onCancel }: ConfirmDialogProps) {
  const { t, tKey, fmt } = useI18n();

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const key = event.key.toLowerCase();
      if (key === "enter" || key === "y") {
        event.preventDefault();
        onConfirm();
      } else if (key === "escape" || key === "n") {
        event.preventDefault();
        onCancel();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onConfirm, onCancel]);

  const message = request.messageKey
    ? fmt(request.messageKey, request.values ?? {})
    : request.message
      ? t(request.message)
      : "";

  return (
    <>
      <div className="confirm__dim sa-dim" aria-hidden="true" />

      <div className="sa-fill-center confirm__layer">
        <Dialog titleKey={request.titleKey} className="confirm__window">
          <Label textValue={message} light wrap />
          <Footer
            buttons={[
              <Button
                key="confirm"
                text={tKey(request.confirmKey ?? "ui.confirm")}
                kind={request.destructive ? "danger" : "primary"}
                onClick={onConfirm}
              />,
              <Button
                key="cancel"
                text={tKey(request.cancelKey ?? "ui.cancel")}
                onClick={onCancel}
              />,
            ]}
          />
        </Dialog>
      </div>
    </>
  );
}

/** The routed `confirm` screen (§4.2 / DevNav). */
export function ConfirmScreen() {
  const { state } = useGameState();
  const pending = useSyncExternalStore(subscribe, snapshot, snapshot);
  const head = pending[0];
  const fallback = defaultBackScreen(state.current_port);

  const onConfirm = useCallback(() => resolveHead(true, fallback), [fallback]);
  const onCancel = useCallback(() => resolveHead(false, fallback), [fallback]);

  // A direct route with no pending request still renders the modal shell (a
  // blank confirm that returns to the run's landing screen).
  const request: ConfirmRequest = head?.request ?? {
    titleKey: "ui.confirm_title",
    opener: fallback,
  };

  return (
    <div className="sa-screen confirm" data-screen={CONFIRM_SCREEN}>
      <ConfirmDialog request={request} onConfirm={onConfirm} onCancel={onCancel} />
    </div>
  );
}
