/**
 * M6-b screen slice (chart + everyday modals): chart, settings, confirm,
 * dialog_box. Owned by exactly one M6 agent; merged here so parallel
 * screen agents never touch index.tsx.
 */
import type { ScreenId } from "../layout";

export const M6B_SCREENS: Partial<Record<ScreenId, () => JSX.Element>> = {};
