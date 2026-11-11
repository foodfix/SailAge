/**
 * S1 title — the front door (docs/80-UI-UX.md §4.1, §4.2, §4.6.3, §4.9.1;
 * docs/90-ARCHITECTURE.md §0).
 *
 * The UW2 title layout (§4.9.1): the sea scene backdrop, the logotype
 * plate (the brand proper noun + `title.subtitle`) centered around 38%
 * canvas height, and the framed menu column beneath it — new game
 * (primary), the sea-battle sandbox, load, settings and the quit notice.
 * The phase-tag plate (top-left) carries the version / save-presence
 * readout and the immediate language toggle (§4.6.3: the locale is
 * persisted by the locale store and forwarded to the server through
 * `POST /api/locale` by the shell). Load opens the 3-slot dialog in load
 * mode; New Game starts the two-step nationality → creation flow. A
 * failed save listing shows the `title.data_error` line under the menu.
 *
 * Boot landing (M6-a): the hash router opens `#/port` by default. This
 * module probes `GET /api/state` once at import time (when no explicit
 * route is present) and asks the server's frozen `hello` payload where the
 * app belongs: a no-run server lands on the title, a live run lands on its
 * `current_screen`. The router file itself stays untouched.
 */
import { useEffect, useState } from "react";
import { useI18n } from "../i18n";
import { useGameClient } from "../client/context";
import { useGameState } from "../state/context";
import type { SaveSlot } from "../client/types";
import type { BootstrapHello } from "../state/views";
import { isScreenId, type ScreenId } from "./ids";
import { Button, Frame, Toast } from "../kit";
import { Label, useToastState } from "./common";
import { navigate } from "../app/router";
import { openSaveSlot, setEndingRetiredMode } from "./SaveSlot";
import "./Title.css";

const SCREEN: ScreenId = "title";

/** The brand proper noun (the Godot title scene pinned it verbatim). */
const GAME_TITLE = "SailAge";

/**
 * Boot landing probe. Runs once at module import (the screen slice is
 * imported by screens/index.tsx, i.e. before the first paint). `has_run ===
 * false` lands on the title; otherwise the server's `current_screen` wins.
 * An explicit hash route or `?screen=` seam always wins over the probe.
 */
function bootLanding(): void {
  if (typeof window === "undefined") return;
  const params = new URLSearchParams(window.location.search);
  if (params.get("fixture") === "1") return;
  const hash = window.location.hash.replace(/^#\/?/, "").replace(/\/$/, "");
  if (hash || params.has("screen")) return;
  void fetch("/api/state", { headers: { accept: "application/json" } })
    .then((response) => response.json())
    .then((body: unknown) => {
      const hello = (body as { hello?: BootstrapHello }).hello;
      if (!hello) return;
      const target = hello.has_run === false ? "title" : hello.current_screen;
      if (isScreenId(target) && window.location.hash !== `#/${target}`) {
        navigate(target);
      }
    })
    .catch(() => {
      // The shell's connection notice owns transport faults; boot never
      // fabricates a route from a failed probe.
    });
}

bootLanding();

export function TitleScreen() {
  const { state } = useGameState();
  const client = useGameClient();
  const { tKey, toggleLocale } = useI18n();
  const { toast, showToast, clearToast } = useToastState();
  const [saves, setSaves] = useState<SaveSlot[]>([]);
  const [errorKey, setErrorKey] = useState<string | null>(null);

  useEffect(() => {
    // A fresh title visit is never a retired-save summary.
    setEndingRetiredMode(false);
    let alive = true;
    void client
      .getSaves()
      .then((response) => {
        if (alive) setSaves(response.saves);
      })
      .catch(() => {
        if (alive) setErrorKey("error.network");
      });
    return () => {
      alive = false;
    };
  }, [client]);

  const filled = saves.filter((entry) => entry.day > 0).length;
  const slots = saves.length > 0 ? saves.length : 3;
  const versionText = `${state.save_version} · ${filled}/${slots}`;

  return (
    <div className="sa-screen title" data-screen={SCREEN}>
      <div className="sa-scene" aria-hidden="true" />

      <div className="title__stack">
        <div className="title__logotype sa-plate">
          <Label textValue={GAME_TITLE} title align="center" />
          <Label textKey="title.subtitle" tone="dim" align="center" />
        </div>

        <Frame className="title__menu">
          <div className="title__menu_col">
            <Button
              textKey="title.new_game"
              kind="primary"
              onClick={() => navigate("nationality_select")}
            />
            <Button textKey="sandbox.title" onClick={() => navigate("sandbox")} />
            <Button textKey="title.load_game" onClick={() => openSaveSlot("load")} />
            <Button textKey="settings.title" onClick={() => navigate("settings")} />
            <Button
              textKey="title.quit"
              kind="quiet"
              onClick={() => showToast("ui.not_available", undefined, "bad")}
            />
          </div>
        </Frame>

        {errorKey ? (
          <Label
            className="title__error"
            textKey="title.data_error"
            values={{ reason: tKey(errorKey) }}
            tone="bad"
            align="center"
          />
        ) : null}
      </div>

      <div className="title__phase sa-plate">
        <Label textValue={versionText} tone="dim" />
        <Button textKey="ui.language_toggle" kind="quiet" onClick={toggleLocale} />
      </div>

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </div>
  );
}
