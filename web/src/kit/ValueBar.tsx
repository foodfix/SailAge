/**
 * value_bar atom (80-* §4.9): GOOD/WARN/BAD by tier; value/max are state
 * numbers, never literals in a screen.
 */
import type { CSSProperties } from "react";

export type ValueTier = "good" | "warn" | "bad";

export interface ValueBarProps {
  value: number;
  max: number;
  tier: ValueTier;
}

export function ValueBar({ value, max, tier }: ValueBarProps) {
  const pct = max > 0 ? Math.max(0, Math.min(100, (value / max) * 100)) : 0;
  const style = { "--sa-fill": `${pct}%` } as CSSProperties;
  return (
    <div className={`sa-value-bar sa-value-bar--${tier}`} style={style}>
      <div className="sa-value-bar__fill" />
    </div>
  );
}
