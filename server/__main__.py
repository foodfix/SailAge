"""``python -m server`` — the single-command launch (90-ARCHITECTURE.md §0.5).

Frozen contract: bind ``127.0.0.1`` (default port **8537**, ``--port``
override), serve ``server.app:app`` through uvicorn, and open the browser at
``http://127.0.0.1:{port}/``. ``--help`` prints the usage and exits without
starting anything; ``--no-browser`` is the headless/CI switch.
"""

from __future__ import annotations

import argparse
import threading
import webbrowser

import uvicorn

__all__ = ["DEFAULT_HOST", "DEFAULT_PORT", "build_parser", "main"]

#: The frozen bind (docs/90-* §0.5). 8537 rather than 8000/8001: those are
#: routinely taken by other local services, and nothing in the protocol
#: depends on the port.
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8537
#: Seconds to wait before opening the browser (uvicorn needs to be listening).
BROWSER_DELAY_SECONDS = 0.8


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m server",
        description="SailAge — start the local game server and open the game.")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"TCP port to bind (default {DEFAULT_PORT})")
    parser.add_argument("--host", default=DEFAULT_HOST,
                        help=f"bind address (default {DEFAULT_HOST})")
    parser.add_argument("--no-browser", action="store_true",
                        help="do not open the browser after startup")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    url = f"http://{args.host}:{int(args.port)}/"
    if not args.no_browser:
        timer = threading.Timer(BROWSER_DELAY_SECONDS, webbrowser.open,
                                args=[url])
        timer.daemon = True
        timer.start()
    uvicorn.run("server.app:app", host=str(args.host),
                port=int(args.port), log_level="info")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
