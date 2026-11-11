#!/usr/bin/env bash
# SailAge — the single-command launch (docs/90-ARCHITECTURE.md §0.5).
# Binds 127.0.0.1:8000 by default, opens the browser, forwards --port.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x .venv/bin/python ]; then
    exec .venv/bin/python -m server "$@"
fi
exec python3 -m server "$@"
