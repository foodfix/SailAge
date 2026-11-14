"""server.app — the FastAPI application root (M2).

Frozen contract (``docs/90-ARCHITECTURE.md`` §0.2/§0.4/§0.5):

* the six fixed endpoints and the facility inventory (``server.api``);
* the one-client WebSocket at ``/ws`` (``server.ws``);
* static mounts: ``/assets`` → ``assets/``, ``/data`` → ``data/`` (JSON
  only), ``/tiles`` → ``web/public/tiles/``;
* ``/`` → the built SPA (``web/dist``) with an ``index.html`` fallback for
  client-side routes, and a clear **503** JSON when that build is absent
  (the M3 SPA lands in parallel — the server tolerates its absence);
* CORS is deliberately not enabled (same origin, §0.5).

The single live game lives on ``app.state.session``
(:class:`server.session.Session`); the lifespan starts/stops its 10 Hz sim
loop (``SIM_TICK_HZ``, §0.5). ``create_app`` builds an isolated instance
for tests; the module-level ``app`` is what ``python -m server`` serves.
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from server.api import build_api_router
from server.api.views import build_views_router
from server.session import ApiError, Session
from server.ws import build_ws_router

__all__ = ["app", "create_app", "REPO_ROOT"]

logger = logging.getLogger(__name__)

#: The repository root (``data/``, ``assets/``, ``web/`` live beside it).
REPO_ROOT = Path(__file__).resolve().parent.parent
ASSETS_DIR = REPO_ROOT / "assets"
DATA_DIR = REPO_ROOT / "data"
WEB_DIST = REPO_ROOT / "web" / "dist"
WEB_DIST_ASSETS = WEB_DIST / "assets"
WEB_TILES = REPO_ROOT / "web" / "public" / "tiles"


def create_app(session: Session | None = None) -> FastAPI:
    """Builds the app; ``session`` is the test seam (one game per process)."""
    live = session if session is not None else Session()

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        await live.start()
        try:
            yield
        finally:
            await live.stop()

    app = FastAPI(title="SailAge", docs_url="/api/docs",
                  openapi_url="/api/openapi.json", lifespan=lifespan)
    app.state.session = live
    app.include_router(build_api_router())
    # The M3 screen-projection channel (90-* §0.4): GET /api/view/<id>.
    app.include_router(build_views_router(), prefix="/api")
    app.include_router(build_ws_router())

    # --- Static mounts -----------------------------------------------------
    # `/assets` hosts the SPA's Vite-emitted, content-hashed bundle
    # (`web/dist/assets/*`) *and* the Phase-10 UI art (`assets/**`). The M3
    # build's assets must win; an explicit resolver keeps both under the one
    # frozen path (a StaticFiles mount here would shadow the bundle).
    if ASSETS_DIR.is_dir() or WEB_DIST_ASSETS.is_dir():
        @app.get("/assets/{path:path}")
        async def assets(path: str) -> Any:
            for root in (WEB_DIST_ASSETS, ASSETS_DIR):
                root_resolved = root.resolve()
                candidate = (root / path).resolve()
                if root_resolved in candidate.parents and candidate.is_file():
                    return FileResponse(candidate)
            return JSONResponse(status_code=404, content={
                "ok": False,
                "error": {"code": "not_found", "msg": "error.not_found"},
            })
    if WEB_TILES.is_dir():
        app.mount("/tiles", StaticFiles(directory=str(WEB_TILES)),
                  name="tiles")

    @app.get("/data/{path:path}")
    async def data_file(path: str) -> Any:
        """JSON content only (the SPA resolves i18n/content from here)."""
        return _json_data_response(path)

    # --- The SPA shell (registered last: it is the fallback) ---------------
    @app.get("/")
    @app.get("/{full_path:path}")
    async def spa(full_path: str = "") -> Any:
        if full_path.startswith(("api", "assets", "data", "tiles", "ws")):
            return JSONResponse(status_code=404, content={
                "ok": False,
                "error": {"code": "not_found", "msg": "error.not_found"},
            })
        index = WEB_DIST / "index.html"
        if not index.is_file():
            return JSONResponse(status_code=503, content={
                "ok": False,
                "error": {
                    "code": "no_web_build",
                    "msg": "error.no_web_build",
                },
            })
        candidate = (WEB_DIST / full_path).resolve()
        if full_path and candidate.is_file() \
                and WEB_DIST.resolve() in candidate.parents:
            return FileResponse(candidate)
        # The shell always revalidates (`no-cache` = store + revalidate):
        # it names the content-hashed bundle files, so a stale cached copy
        # points at builds the next `npm run build` deleted — the browser
        # then 404s the bundle and shows only the page background. The
        # hashed assets themselves keep heuristic caching (their names
        # change with their content), so only the shell needs this.
        return FileResponse(index, headers={"Cache-Control": "no-cache"})

    # --- Frozen refusal shape (§0.4) --------------------------------------
    @app.exception_handler(ApiError)
    async def api_error_handler(_request: Request,
                                error: ApiError) -> JSONResponse:
        return JSONResponse(status_code=error.status,
                            content=error.payload())

    @app.exception_handler(RequestValidationError)
    async def validation_handler(_request: Request,
                                 _error: RequestValidationError
                                 ) -> JSONResponse:
        return JSONResponse(status_code=400, content={
            "ok": False,
            "error": {"code": "bad_request", "msg": "error.bad_request"},
        })

    return app


def _json_data_response(path: str) -> Any:
    """Resolves ``data/<path>`` but only for ``.json`` files inside it."""
    if not path or not path.endswith(".json"):
        return JSONResponse(status_code=404, content={
            "ok": False,
            "error": {"code": "not_found", "msg": "error.not_found"},
        })
    root = DATA_DIR.resolve()
    candidate = (DATA_DIR / path).resolve()
    if root not in candidate.parents or not candidate.is_file():
        return JSONResponse(status_code=404, content={
            "ok": False,
            "error": {"code": "not_found", "msg": "error.not_found"},
        })
    return FileResponse(candidate, media_type="application/json")


app = create_app()
