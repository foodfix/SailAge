import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev wiring (90-ARCHITECTURE.md §0.2): the Vite dev server proxies API
// calls and the WebSocket to the FastAPI server (frozen default port
// 8537, 90-* §0.5). Override with `python -m server --port N` plus the
// same target here. Production builds are served by FastAPI's static
// mount — the proxy only matters for `npm run dev`.
export default defineConfig({
  plugins: [react()],
  // The 317 Phase-10 UI PNGs stay plain static assets (90-* §0.1);
  // the sprite registry imports them through Vite so dev serves them from
  // disk and the build emits content-hashed files.
  build: { assetsInlineLimit: 0 },
  server: {
    // The 317 UI PNGs live beside the app (repo `assets/ui/**`), not under
    // web/; allow the repo root in dev so the sprite imports serve instead
    // of 403ing through Vite's default fs allowlist (M4 report).
    fs: { allow: [".."] },
    proxy: {
      "/api": "http://127.0.0.1:8537",
      "/ws": { target: "ws://127.0.0.1:8537", ws: true },
    },
  },
});
