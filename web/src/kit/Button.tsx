/**
 * button atom (80-* §4.9.1): kind ∈ default/primary/danger/quiet, cream
 * beveled plate, the 4-state matrix in CSS. `compact` is the 32px dense
 * variant for table-row actions. Children (a `.sa-button__stack` or a
 * custom composition) replace the plain label.
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
  compact?: boolean;
  titleKey?: string;
  /** Full custom content (e.g. the verb-bar icon/name/status stack). */
  children?: React.ReactNode;
}

export function Button({
  textKey,
  text,
  kind = "default",
  icon,
  onClick,
  disabled,
  fill,
  compact,
  titleKey,
  children,
}: ButtonProps) {
  const { tKey } = useI18n();
  const classes = [
    "sa-button",
    `sa-button--${kind}`,
    fill ? "sa-button--fill" : "",
    compact ? "sa-button--compact" : "",
  ]
    .filter(Boolean)
    .join(" ");
  return (
    <button
      type="button"
      className={classes}
      onClick={onClick}
      disabled={disabled}
      title={titleKey ? tKey(titleKey) : undefined}
    >
      {children ?? (
        <>
          {icon ? <Icon id={icon} className="sa-button__icon" /> : null}
          <span className="sa-button__label">{text ?? (textKey ? tKey(textKey) : "")}</span>
        </>
      )}
    </button>
  );
}
