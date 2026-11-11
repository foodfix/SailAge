/**
 * Dev-only screen index (?dev=1). Renders the technical screen ids (never
 * game copy) so every one of the 32 routes is reachable while M3 lands.
 */
import { SCREEN_IDS, type ScreenId } from "../screens/ids";
import { isRealScreen } from "../screens";
import { navigate } from "./router";

export function DevNav({ screen }: { screen: ScreenId }) {
  const enabled = new URLSearchParams(window.location.search).has("dev");
  if (!enabled) return null;
  return (
    <nav className="sa-devnav">
      {SCREEN_IDS.map((id) => (
        <button
          key={id}
          type="button"
          className="sa-devnav__btn"
          data-active={id === screen}
          data-real={isRealScreen(id)}
          onClick={() => navigate(id)}
        >
          {id}
        </button>
      ))}
    </nav>
  );
}
