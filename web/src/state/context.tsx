/**
 * Game state context. The provider carries the authoritative snapshot
 * (§0.3 `state` frame) and, since M3, the server-computed screen
 * projections (`GET /api/view/<screen_id>`, 90-* §0.4) plus their
 * per-screen status. Screens read the pair through `useScreenView`
 * (screens/common.tsx) and never compute a rule themselves.
 */
import { createContext, useContext, type ReactNode } from "react";
import type { BattleTickFrame, EventFrame, TickFrame } from "../client/types";
import type { GameSnapshot } from "./types";
import type { ScreenViewId, ScreenViews, ScreenViewState } from "./views";

export interface GameStateValue {
  state: GameSnapshot;
  /** The last successful projection per screen (fixture or live). */
  views: Partial<ScreenViews>;
  /** Per-screen projection status (idle/loading/ready/error). */
  viewStatus: Partial<Record<ScreenViewId, ScreenViewState>>;
  /** The M3 live transport's sailing/battle slices (additive for M4). */
  tick?: TickFrame | null;
  battleTick?: BattleTickFrame | null;
  /** The last `event` frame (the §0.3 notification transcript, §5.1 names). */
  lastEvent?: EventFrame | null;
}

const GameStateContext = createContext<GameStateValue | null>(null);

export function GameStateProvider({ value, children }: { value: GameStateValue; children: ReactNode }) {
  return <GameStateContext.Provider value={value}>{children}</GameStateContext.Provider>;
}

export function useGameState(): GameStateValue {
  const value = useContext(GameStateContext);
  if (!value) throw new Error("useGameState must be used inside <GameStateProvider>");
  return value;
}
