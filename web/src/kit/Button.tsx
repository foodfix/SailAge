/**
 * button atom (80-* §4.9): kind ∈ default/primary/danger/quiet, optional
 * icon, min 2×2 tiles for standalone use. Inside an authored layout row
 * pass `fill` so the data rect is applied exactly (rule 2).
 */
import { useI18n } from "../i18n";
import type { SpriteId } from "../assets/sprites";
import { Icon } from "./Icon";

export type ButtonKind = "default" | "primary" | "danger" | "quiet";

export interface ButtonProps {
  /** ui_strings key — use `text` instead when the label needs placeholders. */
  textKey?: string;
  /** Already-translated label (fmt() output). */
  text?: string;
  kind?: ButtonKind;
  icon?: SpriteId;
  onClick?: () => void;
  disabled?: boolean;
  fill?: boolean;
  titleKey?: string;
}

export function Button({
  textKey,
  text,
  kind = "default",
  icon,
  onClick,
  disabled,
  fill,
  titleKey,
}: ButtonProps) {
  const { tKey } = useI18n();
  const label = text ?? (textKey ? tKey(textKey) : "");
  return (
    <button
      type="button"
      className={`sa-button sa-button--${kind}${fill ? " sa-button--fill" : ""}`}
      onClick={onClick}
      disabled={disabled}
      title={titleKey ? tKey(titleKey) : undefined}
    >
      {icon ? <Icon id={icon} className="sa-button__icon" /> : null}
      <span className="sa-button__label">{label}</span>
    </button>
  );
}
