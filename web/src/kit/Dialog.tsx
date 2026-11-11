/**
 * dialog atom (80-* §4.9.1): the indigo message window — gold double
 * frame, light text. Screens mount it over the `.sa-dim` layer.
 */
import type { ReactNode } from "react";
import { useI18n } from "../i18n";

export interface DialogProps {
  titleKey?: string;
  children?: ReactNode;
  className?: string;
  scroll?: boolean;
}

export function Dialog({ titleKey, children, className, scroll }: DialogProps) {
  const { tKey } = useI18n();
  return (
    <div className={`sa-dialog${className ? ` ${className}` : ""}`}>
      {titleKey ? <div className="sa-dialog__title">{tKey(titleKey)}</div> : null}
      <div className={`sa-dialog__body${scroll ? " sa-scroll" : ""}`}>{children}</div>
    </div>
  );
}
