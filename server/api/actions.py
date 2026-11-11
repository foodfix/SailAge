"""The facility action router (``90-ARCHITECTURE.md`` §0.4).

One dynamic route, ``POST /api/{facility}/{action}``, dispatches only the
inventory in :data:`server.session.FACILITY_INVENTORY`; anything else is a
404 refusal. The adapter body is :meth:`server.session.Session.dispatch` —
no rules live here.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Request

from server.session import FACILITY_INVENTORY, Session

__all__ = ["INVENTORY", "build_actions_router"]


# The inventory constant is re-exported for the test that freezes it.
INVENTORY = FACILITY_INVENTORY


def _session(request: Request) -> Session:
    return request.app.state.session  # type: ignore[no-any-return]


def build_actions_router() -> APIRouter:
    router = APIRouter()

    @router.post("/{facility}/{action}")
    async def facility_action(facility: str, action: str, request: Request,
                              payload: dict[str, Any] | None = None
                              ) -> dict[str, Any]:
        session = _session(request)
        result = session.dispatch(facility, action, payload)
        session.queue_state()
        return result

    return router
