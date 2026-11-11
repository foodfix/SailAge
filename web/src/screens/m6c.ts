/**
 * M6-c screen slice (people surfaces + at-sea modals): intel_window,
 * character_card, dossier, captain_view, fleet_view, officer_roster,
 * reputation_view, hail, fleet_picker, autopilot_hud, duel, sandbox.
 * Owned by exactly one M6 agent; merged here so parallel screen agents
 * never touch index.tsx.
 */
import type { ScreenId } from "../layout";

export const M6C_SCREENS: Partial<Record<ScreenId, () => JSX.Element>> = {};
