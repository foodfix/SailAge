/**
 * row atom (80-* §4.9): `cols` cells on one horizontal row, 1 tile tall
 * by default. Used inside dynamic list rows (builder-owned flow).
 */
import type { ReactNode } from "react";
import { tile } from "../layout/position";

export interface RowProps {
  cols: ReactNode[];
  /** Row height in chrome tiles (default 1 tile = Palette.ROW_H). */
  height?: number;
}

export function Row({ cols, height }: RowProps) {
  return (
    <div
      className="sa-row"
      style={height === undefined ? undefined : { height: tile(height) }}
    >
      {cols.map((cell, index) => (
        <div className="sa-row__cell" key={index}>
          {cell}
        </div>
      ))}
    </div>
  );
}
