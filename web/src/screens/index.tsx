/**
 * ScreenHost — the 32-screen switch. Eight port screens are real in M3, the
 * S3 sailing screen in M4 and the S10 battle screen in M5; the remaining 22
 * render the stub panel (the M6 backlog).
 */
import { SCREEN_IDS, type ScreenId } from "../layout";
import { PortScreen } from "./PortScreen";
import { MarketScreen } from "./MarketScreen";
import { ProvisionsScreen } from "./ProvisionsScreen";
import { ShipyardScreen } from "./ShipyardScreen";
import { InnScreen } from "./InnScreen";
import { GuildScreen } from "./GuildScreen";
import { PalaceScreen } from "./PalaceScreen";
import { TavernScreen } from "./TavernScreen";
import { WorldScreen } from "./World";
import { BattleScreen } from "./Battle";
import { StubScreen } from "./StubScreen";

const REAL: Partial<Record<ScreenId, () => JSX.Element>> = {
  port: PortScreen,
  market: MarketScreen,
  provisions: ProvisionsScreen,
  shipyard: ShipyardScreen,
  inn: InnScreen,
  guild: GuildScreen,
  palace: PalaceScreen,
  tavern: TavernScreen,
  world: WorldScreen,
  battle: BattleScreen,
};

export function isRealScreen(screen: ScreenId): boolean {
  return REAL[screen] !== undefined;
}

export function ScreenHost({ screen }: { screen: ScreenId }) {
  const Screen = REAL[screen];
  return Screen ? <Screen /> : <StubScreen screen={screen} />;
}

export const ALL_SCREENS = SCREEN_IDS;
