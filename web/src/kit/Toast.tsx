/**
 * toast atom (80-* §4.9): a private modal toast; the screen supplies a
 * ui_strings key + placeholder values. Auto-dismisses (fade timing owned
 * by the kit, 80-* §4.7.17).
 */
import { useEffect } from "react";
import { useI18n, type L10nValue } from "../i18n";

export type ToastTone = "good" | "bad" | "neutral";

export interface ToastProps {
  messageKey: string;
  values?: Record<string, L10nValue>;
  tone?: ToastTone;
  onDismiss: () => void;
  durationMs?: number;
}

export function Toast({ messageKey, values, tone = "neutral", onDismiss, durationMs = 2600 }: ToastProps) {
  const { fmt } = useI18n();
  useEffect(() => {
    const timer = window.setTimeout(onDismiss, durationMs);
    return () => window.clearTimeout(timer);
  }, [messageKey, values, onDismiss, durationMs]);
  return (
    <div className={`sa-toast sa-toast--${tone}`} role="status">
      {fmt(messageKey, values ?? {})}
    </div>
  );
}
