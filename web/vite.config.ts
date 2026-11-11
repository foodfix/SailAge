import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev wiring (90-ARCHITECTURE.md §0.2): the Vite dev server proxies API
// calls and the WebSocket to the FastAPI server (frozen default port
// 8000). Production builds are served by FastAPI's static mount — the
// proxy only matters for `npm run dev`.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      "/api": "http://127.0.0.1:8000",
      "/ws": { target: "ws://127.0.0.1:8000", ws: true },
    },
  },
});
