/**
 * field atom helper: the nine-patch field plate + input. Screens pass a
 * ui_strings key for the accessible name (never a literal).
 */
import { useI18n } from "../i18n";

export interface FieldProps {
  value: string;
  onChange: (value: string) => void;
  ariaLabelKey: string;
  maxLength?: number;
}

export function Field({ value, onChange, ariaLabelKey, maxLength }: FieldProps) {
  const { tKey } = useI18n();
  return (
    <span className="sa-field">
      <input
        className="sa-field__input"
        type="text"
        inputMode="numeric"
        value={value}
        maxLength={maxLength}
        aria-label={tKey(ariaLabelKey)}
        onChange={(event) => onChange(event.target.value)}
      />
    </span>
  );
}
