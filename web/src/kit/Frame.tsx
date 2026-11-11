/**
 * frame atom (80-* §4.9): titled panel with the sheet's 16 px content
 * inset. The panel skin is the generated nine-patch; no local styling.
 */
import type { ReactNode } from "react";
import { useI18n } from "../i18n";

export interface FrameProps {
  titleKey?: string;
  children?: ReactNode;
  className?: string;
}

export function Frame({ titleKey, children, className }: FrameProps) {
  const { tKey } = useI18n();
  return (
    <div className={`sa-frame${className ? ` ${className}` : ""}`}>
      <div className="sa-skin sa-sheet--panel" aria-hidden="true" />
      {titleKey ? <div className="sa-frame__title sa-label sa-label--title">{tKey(titleKey)}</div> : null}
      <div className="sa-frame__body">{children}</div>
    </div>
  );
}
