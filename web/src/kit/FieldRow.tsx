/**
 * field_row atom (80-* §4.9): label + control on one 1-tile row.
 * The control is caller-supplied (Field, value bar, swatch, ...).
 */
import type { ReactNode } from "react";
import { useI18n } from "../i18n";

export interface FieldRowProps {
  labelKey: string;
  children: ReactNode;
}

export function FieldRow({ labelKey, children }: FieldRowProps) {
  const { tKey } = useI18n();
  return (
    <div className="sa-field-row">
      <span className="sa-field-row__label sa-label">{tKey(labelKey)}</span>
      <span className="sa-field-row__control">{children}</span>
    </div>
  );
}
