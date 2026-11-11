/**
 * M6-c screen slice (people surfaces + at-sea modals): intel_window,
 * character_card, dossier, captain_view, fleet_view, officer_roster,
 * reputation_view, hail, fleet_picker, autopilot_hud, duel, sandbox.
 * Owned by exactly one M6 agent; merged here so parallel screen agents
 * never touch index.tsx.
 *
 * This file stays `.ts` (the extension point master imports); the one
 * component needing props (`character_card`'s standalone player view) is
 * composed with `createElement` rather than JSX.
 */
import { createElement } from "react";
import type { ScreenId } from "../layout";
import { AutopilotHud } from "./AutopilotHud";
import { CaptainView } from "./CaptainView";
import { CharacterCard } from "./CharacterCard";
import { Dossier } from "./Dossier";
import { Duel } from "./Duel";
import { FleetPicker } from "./FleetPicker";
import { FleetView } from "./FleetView";
import { Hail } from "./Hail";
import { IntelWindow } from "./IntelWindow";
import { OfficerRoster } from "./OfficerRoster";
import { ReputationView } from "./ReputationView";
import { Sandbox } from "./Sandbox";

export const M6C_SCREENS: Partial<Record<ScreenId, () => JSX.Element>> = {
  intel_window: IntelWindow,
  character_card: () => createElement(CharacterCard, { kind: "player", standalone: true }),
  dossier: Dossier,
  captain_view: () => createElement(CaptainView, {}),
  fleet_view: () => createElement(FleetView, {}),
  officer_roster: () => createElement(OfficerRoster, {}),
  reputation_view: () => createElement(ReputationView, {}),
  hail: () => createElement(Hail, {}),
  fleet_picker: FleetPicker,
  autopilot_hud: () => createElement(AutopilotHud, {}),
  duel: Duel,
  sandbox: Sandbox,
};
