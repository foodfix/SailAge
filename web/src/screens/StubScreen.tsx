/**
 * Router target for the 24 screens that M3 stubs. The shell keeps the
 * locked 32-screen set reachable; the eight port screens are real.
 */
import { Box } from "../layout";
import { Button, Frame } from "../kit";
import { navigate } from "../app/router";
import type { ScreenId } from "../layout";

export function StubScreen({ screen }: { screen: ScreenId }) {
  return (
    <div className="sa-screen" data-stub-screen={screen}>
      <Box rect={{ x: 18, y: 9, w: 24, h: 16 }}>
        <Frame titleKey="ui.not_available">
          <div className="sa-cell">{screen}</div>
          <div className="sa-footer">
            <Button textKey="ui.back" kind="primary" onClick={() => navigate("port")} />
          </div>
        </Frame>
      </Box>
    </div>
  );
}
