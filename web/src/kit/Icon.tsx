/**
 * <Icon> — resolves a typed sprite id through the asset registry and
 * renders the flat fallback when the id is absent (80-* §4.9). Decorative
 * by default: the surrounding label carries the accessible text.
 */
import { useEffect } from "react";
import { reportMissingSprite, spriteUrl, type SpriteId } from "../assets/sprites";

export interface IconProps {
  id: SpriteId;
  className?: string;
}

export function Icon({ id, className }: IconProps) {
  const url = spriteUrl(id);
  useEffect(() => {
    if (!url) reportMissingSprite(id);
  }, [id, url]);
  if (!url) {
    return <span className={`sa-icon sa-icon--missing${className ? ` ${className}` : ""}`} aria-hidden="true" />;
  }
  return (
    <img
      className={`sa-icon${className ? ` ${className}` : ""}`}
      src={url}
      alt=""
      aria-hidden="true"
      draggable={false}
    />
  );
}
