/**
 * footer atom (80-* §4.9): a right-aligned button row.
 */
import type { ReactNode } from "react";

export interface FooterProps {
  buttons: ReactNode[];
}

export function Footer({ buttons }: FooterProps) {
  return <div className="sa-footer">{buttons}</div>;
}
