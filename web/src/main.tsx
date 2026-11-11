import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";

// The SPA mounts into #root. The design canvas is 1920×1080 (60×33.75
// chrome tiles of 32 px, 80-UI-UX.md §4.8.9); the scale-to-fit canvas
// wrapper lands with M3's first screen. All player-facing strings ride
// the i18n layer ({"zh","en"} from data/ui_strings.json) — the M3 lint
// gate keeps hardcoded strings out of TSX with an empty allowlist.
ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
