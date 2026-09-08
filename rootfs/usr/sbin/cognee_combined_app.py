#!/usr/bin/env python3
"""
Combined ASGI app: cognee FastAPI + MCP server.

Routing:
  /api/v1/*      → cognee FastAPI app (unmodified)
  /health, /docs → cognee FastAPI app
  /mcp           → MCP Streamable HTTP transport
  /sse           → MCP SSE transport (GET)
  /messages/*    → MCP SSE transport (POST)
"""

import os

# Auth bypass — must be set before any cognee import (see run.sh comments).
os.environ.setdefault("ENABLE_BACKEND_ACCESS_CONTROL", "false")
os.environ.setdefault("REQUIRE_AUTHENTICATION", "false")

from cognee.api.client import app as _cognee_app  # noqa: E402
from cognee_mcp_server import mcp  # noqa: E402

# MCP ASGI apps — one per transport.
_mcp_http = mcp.streamable_http_app()
_mcp_sse = mcp.sse_app()


async def app(scope, receive, send):
    """ASGI dispatcher: route to cognee or MCP based on path."""
    path = scope.get("path", "")

    if path == "/mcp":
        await _mcp_http(scope, receive, send)
    elif path == "/sse" or path.startswith("/messages"):
        await _mcp_sse(scope, receive, send)
    else:
        await _cognee_app(scope, receive, send)
