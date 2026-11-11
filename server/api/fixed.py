"""The six fixed HTTP endpoints (``90-ARCHITECTURE.md`` §0.4, frozen).

* ``POST /api/new_game {nation_id, background_id, attr_alloc, skill_alloc}``
* ``POST /api/load {slot}``
* ``POST /api/save {slot}``
* ``GET  /api/saves``
* ``GET  /api/state``
* ``POST /api/locale {locale}``

Success is ``{"ok": true, …}``; the fresh authoritative snapshot rides the
next ``state`` WS frame (§0.3/§0.4) — except ``GET /api/state``, which
returns the same snapshot over HTTP for a page that has not connected the
socket yet. Refusals raise :class:`server.session.ApiError`; the app's
exception handler renders the frozen ``{"ok": false, "error": {...}}`` body.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Request
from fastapi.concurrency import run_in_threadpool

from server.session import ApiError, Session

__all__ = ["build_fixed_router"]


def _session(request: Request) -> Session:
    return request.app.state.session  # type: ignore[no-any-return]


def _attrs(value: Any) -> dict[str, int]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ApiError("bad_request", "error.bad_request", 400)
    out: dict[str, int] = {}
    for key, amount in value.items():
        if isinstance(amount, bool) or not isinstance(amount, int):
            raise ApiError("bad_request", "error.bad_request", 400)
        out[str(key)] = int(amount)
    return out


def build_fixed_router() -> APIRouter:
    router = APIRouter()

    @router.post("/new_game")
    async def new_game(request: Request,
                       payload: dict[str, Any] | None = None) -> dict[str, Any]:
        body = payload if isinstance(payload, dict) else {}
        nation_id = body.get("nation_id")
        background_id = body.get("background_id", "")
        if not isinstance(nation_id, str) or not nation_id:
            raise ApiError("bad_request", "error.bad_request", 400)
        if not isinstance(background_id, str):
            raise ApiError("bad_request", "error.bad_request", 400)
        session = _session(request)
        result = session.new_game(
            nation_id, background_id,
            _attrs(body.get("attr_alloc")), _attrs(body.get("skill_alloc")))
        session.queue_state()
        return result

    @router.post("/load")
    async def load(request: Request,
                   payload: dict[str, Any] | None = None) -> dict[str, Any]:
        body = payload if isinstance(payload, dict) else {}
        slot = body.get("slot")
        if isinstance(slot, bool) or not isinstance(slot, int):
            raise ApiError("bad_request", "error.bad_request", 400)
        session = _session(request)
        result = session.load_slot(int(slot))
        session.queue_state()
        return result

    @router.post("/save")
    async def save_slot(request: Request,
                        payload: dict[str, Any] | None = None
                        ) -> dict[str, Any]:
        body = payload if isinstance(payload, dict) else {}
        slot = body.get("slot")
        if isinstance(slot, bool) or not isinstance(slot, int):
            raise ApiError("bad_request", "error.bad_request", 400)
        session = _session(request)
        result = await run_in_threadpool(session.save_slot, int(slot))
        session.emit_event("save_completed", {"slot": int(slot)})
        session.queue_state()
        return result

    @router.get("/saves")
    async def saves(request: Request) -> dict[str, Any]:
        from server import save as save_module
        return {"ok": True, "save_version": save_module.SAVE_VERSION,
                "saves": save_module.list_saves()}

    @router.get("/state")
    async def state(request: Request) -> dict[str, Any]:
        session = _session(request)
        return {"ok": True, "state": session.state_payload(),
                "hello": session.hello_payload()}

    @router.post("/locale")
    async def locale(request: Request,
                     payload: dict[str, Any] | None = None) -> dict[str, Any]:
        body = payload if isinstance(payload, dict) else {}
        value = body.get("locale")
        if not isinstance(value, str):
            raise ApiError("bad_request", "error.bad_request", 400)
        session = _session(request)
        result = session.set_locale(value)
        session.queue_state()
        return result

    return router
