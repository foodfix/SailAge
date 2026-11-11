import { createContext, useContext, type ReactNode } from "react";
import type { GameSnapshot, ScreenViews } from "./types";

export interface GameStateValue {
  state: GameSnapshot;
  views: ScreenViews;
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
