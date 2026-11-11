/**
 * frame atom (80-* §4.9.1): the parchment window plate — gold outer rule,
 * brown inner rule, optional 32px title band, 16px body inset. `scroll`
 * turns the body into the thin kit scrollbar viewport.
 */
import type { ReactNode } from "react";
import { useI18n } from "../i18n";

export interface FrameProps {
  titleKey?: string;
  children?: ReactNode;
  className?: string;
  scroll?: boolean;
}

export function Frame({ titleKey, children, className, scroll }: FrameProps) {
  const { tKey } = useI18n();
  return (
    <div
      className={`sa-window${titleKey ? " sa-window--titled" : ""}${className ? ` ${className}` : ""}`}
    >
      {titleKey ? <div className="sa-window__title">{tKey(titleKey)}</div> : null}
      <div className={`sa-window__body${scroll ? " sa-scroll" : ""}`}>{children}</div>
    </div>
  );
}
