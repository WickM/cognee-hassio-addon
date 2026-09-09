#!/usr/bin/env python3
"""
Combined launcher: cognee REST API on port 8000 + MCP SSE on port 8001.

Architecture:
  Port 8000 — cognee FastAPI (unmodified, same as v0.2.x)
  Port 8001 — MCP SSE server (/sse + /messages/)

Why two ports instead of one ASGI mount:
  The MCP SDK's StreamableHTTP transport requires a session-manager that is
  initialized via Starlette's ASGI lifespan. A raw ASGI dispatcher swallows
  lifespan events, so the session manager never starts. The SSE transport
  creates a fresh session per connection and does NOT need lifespan init —
  making it the simplest reliable integration path.

  Agents connect to http://cognee:8001/sse for MCP.

Usage:
  python3 /usr/sbin/cognee_combined_app.py   # both servers
  ENABLE_MCP=false python3 ...                # cognee only (v0.2.x compat)
"""

import asyncio
import os
import sys

# Auth bypass — must be set before any cognee import (see run.sh comments).
os.environ.setdefault("ENABLE_BACKEND_ACCESS_CONTROL", "false")
os.environ.setdefault("REQUIRE_AUTHENTICATION", "false")

COGNEE_PORT = int(os.environ.get("COGNEE_PORT", "8000"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").lower()
MCP_ENABLED = os.environ.get("ENABLE_MCP", "true").lower() == "true"
MCP_PORT = int(os.environ.get("MCP_PORT", "8001"))


async def run_cognee():
    """Start cognee REST API on COGNEE_PORT."""
    import uvicorn
    from cognee.api.client import app as cognee_app

    config = uvicorn.Config(
        cognee_app,
        host="0.0.0.0",
        port=COGNEE_PORT,
        log_level=LOG_LEVEL,
        access_log=False,
    )
    server = uvicorn.Server(config)
    print(f"[combined] cognee API on 0.0.0.0:{COGNEE_PORT}")
    await server.serve()


async def run_mcp():
    """Start MCP SSE server on MCP_PORT."""
    from cognee_mcp_server import mcp

    mcp.settings.host = "0.0.0.0"
    mcp.settings.port = MCP_PORT
    mcp.settings.log_level = LOG_LEVEL.upper()

    print(f"[combined] MCP SSE on 0.0.0.0:{MCP_PORT}  (endpoints: /sse, /messages/)")
    await mcp.run_sse_async()


async def main():
    if not MCP_ENABLED:
        print("[combined] ENABLE_MCP=false — cognee API only (v0.2.x compat)")
        await run_cognee()
        return

    # Start both servers as concurrent asyncio tasks.
    # run_sse_async() starts its own uvicorn internally; run_cognee() starts
    # another. Both share the same event loop, each on its own port.
    await asyncio.gather(
        asyncio.create_task(run_cognee()),
        asyncio.create_task(run_mcp()),
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("[combined] shutdown")
        sys.exit(0)
