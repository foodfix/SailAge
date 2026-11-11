/**
 * <ListRows> — a data-declared dynamic list block (10-* §4.23 `lists`).
 *
 * Row i sits at base + (0, i·row_h), size (base.w, base.h), absolutely
 * placed inside the clipped viewport element. No flow is used: the rows
 * are plain absolutely-positioned boxes (the no-flow rule, 80-* §4.8.9).
 */
import type { ReactNode } from "react";
import { tile } from "./position";
import { getListBlock, type ScreenId } from "./types";

export interface ListRowsProps {
  screen: ScreenId;
  listId: string;
  count: number;
  renderRow: (index: number) => ReactNode;
}

export function ListRows({ screen, listId, count, renderRow }: ListRowsProps) {
  const block = getListBlock(screen, listId);
  if (!block) {
    console.error(`Layout: ${screen} list '${listId}' has no block — list not rendered`);
    return null;
  }
  return (
    <div className="sa-list-content">
      {Array.from({ length: count }, (_, index) => (
        <div
          key={index}
          className="sa-list-row"
          style={{
            left: tile(block.base.x),
            top: tile(block.base.y + index * block.row_h),
            width: tile(block.base.w),
            height: tile(block.base.h),
          }}
        >
          {renderRow(index)}
        </div>
      ))}
    </div>
  );
}

/** A 1-tile stacked stack for list sections without a `lists` block. */
export function StackRows({
  count,
  renderRow,
  left = 0,
}: {
  count: number;
  renderRow: (index: number) => ReactNode;
  left?: number;
}) {
  return (
    <div className="sa-list-content">
      {Array.from({ length: count }, (_, index) => (
        <div
          key={index}
          className="sa-list-row"
          style={{
            left: tile(left),
            top: `calc(var(--sailage-row-h) * ${index})`,
            width: "100%",
            height: "var(--sailage-row-h)",
          }}
        >
          {renderRow(index)}
        </div>
      ))}
    </div>
  );
}
