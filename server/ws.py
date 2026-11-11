"""server.ws — the one-client WebSocket: state stream + intents (M2 deliverable).

Frozen protocol (90-ARCHITECTURE.md §0.3 — amend the table, never the
code first): JSON text frames ``{"type": ...}``; server→client
hello/state/tick/battle_tick/event/error; client→server intents
helm/sail_trim/sail_to/wait/intercept/autopilot/battle_order/
battle_action/locale. One client — a second concurrent connection is
closed with code 4001. Broadcast at WS_BROADCAST_HZ = 10 with tick-frame
coalescing (state/event frames never dropped).
M0 status: empty shell — the implementation lands in M2.
"""
