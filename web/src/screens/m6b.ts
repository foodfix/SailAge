/**
 * M6-b screen slice (chart + everyday modals): chart, settings, confirm,
 * dialog_box. Owned by exactly one M6 agent; merged here so parallel
 * screen agents never touch index.tsx.
 *
 * The shared modal helpers are re-exported for the other screens:
 *   `confirmAction(request): Promise<boolean>` — the routed confirm dialog;
 *   `showDialog(request)` / `enqueueDialogs(requests)` — the dialog box and
 *   the §4.7 day-dialog queue;
 *   `<ConfirmDialog/>` / `<DialogBox/>` — the in-place modal bodies.
 */
import type { ScreenId } from "./ids";
import { ChartScreen } from "./Chart";
import { ConfirmScreen } from "./Confirm";
import { DialogScreen } from "./DialogBox";
import { SettingsScreen } from "./Settings";

export const M6B_SCREENS: Partial<Record<ScreenId, () => JSX.Element>> = {
  chart: ChartScreen,
  settings: SettingsScreen,
  confirm: ConfirmScreen,
  dialog_box: DialogScreen,
};

export { ConfirmDialog, ConfirmScreen, confirmAction } from "./Confirm";
export { DialogBox, DialogScreen, enqueueDialogs, showDialog } from "./DialogBox";
export { ChartScreen, SettingsScreen };
export type { ConfirmRequest } from "./Confirm";
export type { DialogEntry, DialogRequest } from "./DialogBox";
