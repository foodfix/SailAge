"""server.ws — the one-client WebSocket (``90-ARCHITECTURE.md`` §0.3, frozen).

Transport: JSON text, one object per frame, payload keys inlined. One
client per session — a second concurrent connection is closed with code
**4001**; a reconnect re-handshakes (``hello`` is re-sent).

Server → client: ``hello`` / ``state`` / ``tick`` / ``battle_tick`` /
``event`` / ``error``. Client → server intents: ``helm`` / ``sail_trim`` /
``sail_to`` / ``wait`` / ``intercept`` / ``autopilot`` / ``battle_order`` /
``battle_action`` / ``locale``. Every intent is validated by
:meth:`server.session.Session.intent`; an unknown/malformed/refused intent
becomes one ``error`` frame and the run continues (never a crash).

Backpressure: :class:`server.session.ClientConnection` keeps at most one
``tick``/``battle_tick`` frame (newest wins) while ``state``/``event``/
``error`` frames are never dropped (§0.3).
"""

from __future__ import annotations

import json
import logging
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from server.session import ApiError, ClientConnection, Session

__all__ = ["build_ws_router"]

logger = logging.getLogger(__name__)

#: The frozen refusal code for a second concurrent connection (§0.3).
DUPLICATE_CLIENT_CODE = 4001


def build_ws_router() -> APIRouter:
    router = APIRouter()

    @router.websocket("/ws")
    async def websocket_endpoint(websocket: WebSocket) -> None:
        session: Session = websocket.app.state.session
        await websocket.accept()
        connection = ClientConnection(websocket)
        if not session.attach_client(connection):
            # The first connection is authoritative (§0.3).
            await websocket.close(code=DUPLICATE_CLIENT_CODE)
            return
        connection.start()
        try:
            connection.enqueue(session.hello_payload())
            connection.enqueue({"type": "state", **session.state_payload()})
            while True:
                raw = await websocket.receive_text()
                frame = _parse(raw)
                if frame is None:
                    connection.enqueue({
                        "type": "error",
                        "code": "bad_frame",
                        "msg": "error.bad_frame",
                    })
                    continue
                try:
                    session.intent(frame)
                except ApiError as error:
                    connection.enqueue(
                        {"type": "error", "code": error.code,
                         "msg": error.msg})
                    continue
                except Exception:  # noqa: BLE001 - never crash the run
                    logger.exception("ws intent failed")
                    connection.enqueue({
                        "type": "error", "code": "internal",
                        "msg": "error.internal",
                    })
                    continue
                if frame.get("type") == "locale":
                    session.queue_state()
        except WebSocketDisconnect:
            pass
        except Exception:  # noqa: BLE001 - a dead socket never kills the app
            logger.debug("ws connection ended", exc_info=True)
        finally:
            await session.detach_client(connection)

    return router


def _parse(raw: Any) -> dict[str, Any] | None:
    """One JSON-object frame, or ``None`` when malformed (§0.3)."""
    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8")
        except UnicodeDecodeError:
            return None
    if not isinstance(raw, str):
        return None
    try:
        frame = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(frame, dict):
        return None
    if not isinstance(frame.get("type"), str) or not frame.get("type"):
        return None
    return frame
