"""server.app — the FastAPI application root (M2 deliverable).

Frozen contract (90-ARCHITECTURE.md §0.2/§0.4/§0.5):
- binds 127.0.0.1:8000 (default; ``--port`` override) via ``python -m server``;
- mounts the built web/ SPA and assets/ statically;
- hosts the REST action endpoints (POST /api/<facility>/<action>; the six
  fixed endpoints frozen at §0.4) and the one-client WebSocket at /ws
  (server.ws).
M0 status: empty shell — the module exists so imports resolve; the
implementation lands in M2.
"""
