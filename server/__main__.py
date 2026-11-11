"""`python -m server` — the single-command launch (90-ARCHITECTURE.md §0.5).

M0 scaffold: the frozen contract is — bind 127.0.0.1 (default port 8000,
``--port`` override), start uvicorn on server.app:app, open the browser
at http://127.0.0.1:{port}/. The implementation lands with the M2 FastAPI
shell; until then this module refuses to start so nobody mistakes the
shell for a runnable game.
"""

from __future__ import annotations

import sys


def main() -> int:
    print(
        "server: M0 scaffold — the FastAPI shell lands in M2 "
        "(docs/IMPLEMENT-WebMigration.md §3). Nothing to run yet.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
