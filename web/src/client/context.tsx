import { createContext, useContext, type ReactNode } from "react";
import type { GameClient } from "./types";

const GameClientContext = createContext<GameClient | null>(null);

export function GameClientProvider({ client, children }: { client: GameClient; children: ReactNode }) {
  return <GameClientContext.Provider value={client}>{children}</GameClientContext.Provider>;
}

export function useGameClient(): GameClient {
  const client = useContext(GameClientContext);
  if (!client) throw new Error("useGameClient must be used inside <GameClientProvider>");
  return client;
}
