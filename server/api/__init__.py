"""server.api — REST action routers (M2 deliverable).

Frozen shape (90-ARCHITECTURE.md §0.4): POST /api/<facility>/<action>,
JSON in → {"ok": true, ...} | {"ok": false, "error": {code, msg}}; the
six fixed endpoints (new_game/load/save/saves/state/locale) are frozen
now; the facility inventory freezes in the M2 acceptance record before
the first screen consumes it. Refusals never crash the run.
M0 status: empty package — routers land in M2.
"""
