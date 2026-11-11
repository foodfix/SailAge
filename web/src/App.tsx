/**
 * App — the M0 shell placeholder (docs/IMPLEMENT-WebMigration.md §3).
 *
 * M3 replaces this with the real screen set (title, nationality_select,
 * creation, port, market, provisions, shipyard, tavern, inn, guild,
 * palace, world, chart, hail, fleet_picker, autopilot_hud, battle,
 * sandbox, duel + the shared/modals family — the 32-screen set of
 * data/ui_layout.json). Until then this renders a static card so the
 * build pipeline is verifiable end-to-end.
 *
 * The one string below is the placeholder's own label; it moves into
 * data/ui_strings.json when M3 wires the i18n layer (lint gate lands
 * with the first screen, not retrofitted).
 */
export default function App() {
  return (
    <div
      style={{
        display: "grid",
        placeItems: "center",
        height: "100vh",
        background: "#16446e",
        color: "#e8e0c8",
        fontFamily: "monospace",
      }}
    >
      <div style={{ textAlign: "center" }}>
        <h1 style={{ fontSize: 48, letterSpacing: 4 }}>SailAge</h1>
        <p>web shell — M0 scaffold (screens land in M3)</p>
      </div>
    </div>
  );
}
