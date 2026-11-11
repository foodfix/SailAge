import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./theme/base.css";

// The SPA mounts into #root. The scale-to-fit canvas lives in App; every
// player-facing string rides the i18n layer ({"zh","en"} from
// data/ui_strings.json), and the M3 audit gate keeps hardcoded strings out
// of TSX with an empty allowlist.
ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
