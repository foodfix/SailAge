/**
 * M6-a screen slice (front door + bookends): title, nationality_select,
 * creation, save_slot, gameover, ending. Owned by exactly one M6 agent;
 * merged here so parallel screen agents never touch index.tsx.
 */
import type { ScreenId } from "../layout";

export const M6A_SCREENS: Partial<Record<ScreenId, () => JSX.Element>> = {};
