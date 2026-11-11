"""server.api — the REST action routers (M2).

Frozen shape (``docs/90-ARCHITECTURE.md`` §0.4): discrete actions are
``POST /api/<facility>/<action>`` with JSON in/out — success
``{"ok": true, …}``, refusal ``{"ok": false, "error": {"code", "msg"}}``.
The six fixed endpoints (``new_game`` / ``load`` / ``save`` / ``saves`` /
``state`` / ``locale``) are frozen now; the facility inventory is
:data:`server.session.FACILITY_INVENTORY` (frozen in the M2 record).

Every handler is a thin adapter: it forwards to
:meth:`server.session.Session.dispatch` (the sim wiring), queues the fresh
``state`` frame, and never evaluates a game rule itself. ``msg`` in a
refusal is a ``data/ui_strings.json`` key (the client owns the copy, the
§0.1 i18n rule); ``error.*`` keys cover protocol faults.
"""

from __future__ import annotations

from fastapi import APIRouter

from server.api.actions import build_actions_router
from server.api.fixed import build_fixed_router
from server.session import FACILITY_INVENTORY

__all__ = ["FACILITY_INVENTORY", "build_api_router"]


def build_api_router() -> APIRouter:
    """All HTTP API routes (fixed + facility), in one router."""
    router = APIRouter(prefix="/api", tags=["api"])
    router.include_router(build_fixed_router())
    router.include_router(build_actions_router())
    return router
