/**
 * row atom (80-* §4.9.1): one 32px table row. Inside a `.sa-table` the
 * zebra striping, the `PANEL_WOOD` header band (head) and the selection
 * ring (selected) are kit-owned; `height` (px) stretches a tall row —
 * px is allowed here because this IS the kit.
 */
import type { CSSProperties, ReactNode } from "react";

export interface RowProps {
  cols: ReactNode[];
  head?: boolean;
  selected?: boolean;
  height?: number;
  className?: string;
  onClick?: () => void;
}

export function Row({ cols, head, selected, height, className, onClick }: RowProps) {
  const classes = ["sa-row", head ? "sa-row--head" : "", className ? ` ${className}` : ""]
    .filter(Boolean)
    .join(" ");
  const style = height === undefined ? undefined : ({ height: `${height}px` } as CSSProperties);
  return (
    <div
      className={classes}
      style={style}
      data-selected={selected ? "true" : undefined}
      onClick={onClick}
    >
      {cols.map((cell, index) => (
        <div className="sa-row__cell" key={index}>
          {cell}
        </div>
      ))}
    </div>
  );
}
