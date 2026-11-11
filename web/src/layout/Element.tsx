/**
 * <Element> — absolutely places one data row on the tile grid.
 *
 * Contract (80-* §4.8.9 React realization; 10-* §4.23):
 *   * the data row is the whole truth — point anchors, nothing stretched;
 *   * a child is clamped inside its parent's rect (rule 1);
 *   * the parent applies its committed rect exactly (rule 2);
 *   * a missing row is a loud console.error + the (0,0,2,2) fallback,
 *     never a crash and never a silent code default.
 *
 * Only geometric props are written inline; every visual style lives in
 * the kit/theme CSS (the no-per-screen-styling rule, 80-* §4.9).
 */
import type { ReactNode } from "react";
import { useI18n } from "../i18n";
import { clampInside, positionStyle } from "./position";
import {
  FALLBACK_TILES,
  getElementRect,
  type ScreenId,
  type SheetId,
  type TileRect,
} from "./types";

export interface ElementProps {
  screen: ScreenId;
  id: string;
  /** Registered parent id — used only for the rule-1 clamp. */
  parent?: string;
  /** Chrome nine-patch skin for this element ("panel", "backdrop", "field"). */
  skin?: SheetId;
  className?: string;
  hidden?: boolean;
  /** `button` makes the whole element a keyboard-reachable click target. */
  as?: "div" | "button";
  onClick?: () => void;
  disabled?: boolean;
  ariaLabelKey?: string;
  children?: ReactNode;
}

export function sheetClass(sheet: SheetId): string {
  return `sa-sheet--${sheet.replace(/_/g, "-")}`;
}

function resolveRect(
  screen: ScreenId,
  id: string,
  parent: string | undefined,
): TileRect {
  const authored = getElementRect(screen, id);
  let rect: TileRect;
  if (!authored) {
    console.error(
      `Layout: ${screen} '${id}' has no rect row — applying the (0,0,2,2) fallback`,
    );
    rect = FALLBACK_TILES;
  } else {
    rect = authored;
  }
  if (parent) {
    const parentRect = getElementRect(screen, parent);
    if (parentRect) rect = clampInside(rect, parentRect);
    else console.error(`Layout: ${screen} '${id}' names missing parent '${parent}'`);
  }
  return rect;
}

export function Element({
  screen,
  id,
  parent,
  skin,
  className,
  hidden,
  as = "div",
  onClick,
  disabled,
  ariaLabelKey,
  children,
}: ElementProps) {
  const { tKey } = useI18n();
  const rect = resolveRect(screen, id, parent);
  const appliedSkin = skin ?? rect.sheet;
  const classes = `sa-el${className ? ` ${className}` : ""}`;
  const style = positionStyle(rect);
  const body = (
    <>
      {appliedSkin ? <div className={`sa-skin ${sheetClass(appliedSkin)}`} aria-hidden="true" /> : null}
      {children}
    </>
  );

  if (as === "button") {
    return (
      <button
        type="button"
        className={classes}
        data-element-id={id}
        data-screen={screen}
        hidden={hidden}
        style={style}
        onClick={onClick}
        disabled={disabled}
        aria-label={ariaLabelKey ? tKey(ariaLabelKey) : undefined}
      >
        {body}
      </button>
    );
  }

  return (
    <div
      className={classes}
      data-element-id={id}
      data-screen={screen}
      hidden={hidden}
      style={style}
      onClick={onClick}
    >
      {body}
    </div>
  );
}

/** A builder-owned cell inside a dynamic list row (unregistered by §4.8.9). */
export function Box({
  rect,
  className,
  skin,
  children,
}: {
  rect: TileRect;
  className?: string;
  skin?: SheetId;
  children?: ReactNode;
}) {
  return (
    <div
      className={`sa-el${className ? ` ${className}` : ""}`}
      style={positionStyle(rect)}
    >
      {skin ? <div className={`sa-skin ${sheetClass(skin)}`} aria-hidden="true" /> : null}
      {children}
    </div>
  );
}
