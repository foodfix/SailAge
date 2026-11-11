/**
 * Router target for any screen without a real component yet. The shell
 * keeps the locked 32-screen set reachable; a UW2 placeholder window
 * (no layout lookups — 80-* §4.9.1).
 */
import { Button, Frame } from "../kit";
import { navigate } from "../app/router";
import type { ScreenId } from "./ids";

export function StubScreen({ screen }: { screen: ScreenId }) {
  return (
    <div className="sa-screen sa-fill-center" data-stub-screen={screen}>
      <Frame titleKey="ui.not_available" className="sa-frame-fallback">
        <div className="sa-col sa-grow" style={{ gap: "var(--sailage-base-unit)" }}>
          <div className="sa-cell">{screen}</div>
          <div className="sa-footer">
            <Button textKey="ui.back" kind="primary" onClick={() => navigate("port")} />
          </div>
        </div>
      </Frame>
    </div>
  );
}
