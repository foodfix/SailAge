/**
 * S1 title — the front door (docs/80-UI-UX.md §4.1, §4.2, §4.6.3;
 * docs/90-ARCHITECTURE.md §0).
 *
 * Every `title` element row of data/ui_layout.json is rendered:
 * `background`, `game_title`, `subtitle`, `phase_tag`, `new_game`,
 * `sandbox`, `load`, `settings`, `quit`, `data_error`.
 *
 * The phase-tag row carries the version / save-presence readout and the
 * immediate language toggle (§4.6.3: the locale is persisted by the
 * locale store and forwarded to the server through `POST /api/locale` by
 * the shell). Load opens the 3-slot dialog in load mode; New Game starts
 * the two-step nationality → creation flow.
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
import { Box, Element, isScreenId, type ScreenId } from "../layout";
import { Button, Toast } from "../kit";
import { ButtonEl, LabelEl, PanelEl, useToastState } from "./common";
import { navigate } from "../app/router";
import { openSaveSlot, setEndingRetiredMode } from "./SaveSlot";

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
    <>
      <PanelEl screen={SCREEN} id="background" skin="backdrop" />
      <LabelEl screen={SCREEN} id="game_title" textValue={GAME_TITLE} title align="center" />
      <LabelEl screen={SCREEN} id="subtitle" textKey="title.subtitle" tone="dim" align="center" />

      <Element screen={SCREEN} id="phase_tag">
        <Box rect={{ x: 0, y: 0, w: 5, h: 2 }}>
          <span className="sa-label sa-label--dim">{versionText}</span>
        </Box>
        <Box rect={{ x: 5, y: 0, w: 5, h: 2 }}>
          <Button textKey="ui.language_toggle" kind="quiet" fill onClick={toggleLocale} />
        </Box>
      </Element>

      <ButtonEl
        screen={SCREEN}
        id="new_game"
        textKey="title.new_game"
        kind="primary"
        onClick={() => navigate("nationality_select")}
      />
      <ButtonEl
        screen={SCREEN}
        id="sandbox"
        textKey="sandbox.title"
        onClick={() => navigate("sandbox")}
      />
      <ButtonEl
        screen={SCREEN}
        id="load"
        textKey="title.load_game"
        onClick={() => openSaveSlot("load")}
      />
      <ButtonEl
        screen={SCREEN}
        id="settings"
        textKey="settings.title"
        onClick={() => navigate("settings")}
      />
      <ButtonEl
        screen={SCREEN}
        id="quit"
        textKey="title.quit"
        kind="quiet"
        onClick={() => showToast("ui.not_available", undefined, "bad")}
      />

      <LabelEl
        screen={SCREEN}
        id="data_error"
        textKey="title.data_error"
        values={{ reason: tKey(errorKey ?? "error.network") }}
        tone="bad"
        align="center"
        hidden={!errorKey}
      />

      {toast ? (
        <Toast messageKey={toast.messageKey} values={toast.values} tone={toast.tone} onDismiss={clearToast} />
      ) : null}
    </>
  );
}
