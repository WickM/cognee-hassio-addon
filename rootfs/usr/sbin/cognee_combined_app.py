#!/usr/bin/env python3
"""
Combined ASGI app: cognee FastAPI + MCP SSE on a single port (8000).

Architecture:
  A lightweight ASGI middleware intercepts `/sse` and `/messages/` requests
  and routes them to the MCP SSE app. Everything else goes to cognee's
  unmodified FastAPI app. Both run on the same port, in a single uvicorn.

  Only SSE transport is used here — the StreamableHTTP transport requires a
  session-manager initialized via ASGI lifespan, which is complex to
  integrate. SSE creates a fresh session per connection and works without
  lifespan initialization, making it the simplest reliable path.

  Agents connect to http://cognee:8000/sse (SSE transport).

Usage:
  python3 -m uvicorn cognee_combined_app:app --host 0.0.0.0 --port 8000
  ENABLE_MCP=false python3 -m uvicorn cognee.api.client:app ...
"""

import os

# Auth bypass — must be set before any cognee import (see run.sh comments).
os.environ.setdefault("ENABLE_BACKEND_ACCESS_CONTROL", "false")
os.environ.setdefault("REQUIRE_AUTHENTICATION", "false")

from cognee.api.client import app as _cognee_app  # noqa: E402
from cognee_mcp_server import mcp  # noqa: E402

MCP_ENABLED = os.environ.get("ENABLE_MCP", "true").lower() == "true"

# Create the MCP SSE ASGI app once at module level.
# SSE transport does NOT need lifespan initialization — it creates a fresh
# session per connection via SseServerTransport.connect_sse().
_mcp_sse = mcp.sse_app() if MCP_ENABLED else None


async def app(scope, receive, send):
    """ASGI dispatcher: route to MCP SSE or cognee based on path."""
    if scope["type"] == "http" and MCP_ENABLED:
        path = scope.get("path", "")

        # SSE transport paths — handled by the MCP SDK's Starlette app.
        if path == "/sse" or path.startswith("/messages"):
            await _mcp_sse(scope, receive, send)
            return

    # Everything else → cognee's unmodified FastAPI app.
    await _cognee_app(scope, receive, send)
