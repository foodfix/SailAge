/**
 * M6-a screen slice (front door + bookends): title, nationality_select,
 * creation, save_slot, gameover, ending. Owned by exactly one M6 agent;
 * merged here so parallel screen agents never touch index.tsx.
 */
import type { ScreenId } from "../layout";
import { TitleScreen } from "./Title";
import { NationalitySelectScreen } from "./NationalitySelect";
import { CreationScreen } from "./Creation";
import { SaveSlotScreen } from "./SaveSlot";
import { GameOverScreen } from "./GameOver";
import { EndingScreen } from "./Ending";

export const M6A_SCREENS: Partial<Record<ScreenId, () => JSX.Element>> = {
  title: TitleScreen,
  nationality_select: NationalitySelectScreen,
  creation: CreationScreen,
  save_slot: SaveSlotScreen,
  gameover: GameOverScreen,
  ending: EndingScreen,
};
