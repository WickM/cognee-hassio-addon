#!/usr/bin/env python3
"""
Cognee MCP Server — exposes cognee's graph memory as MCP tools.

Tools:
  - cognee_search        Semantic search across the knowledge graph
  - cognee_add_text      Add text content to a dataset
  - cognee_cognify       Process pending data into the graph
  - cognee_recall        Memory-oriented search alias
  - cognee_list_datasets  List all datasets
  - cognee_create_dataset  Create a new dataset
  - cognee_get_dataset_data  Get raw data from a dataset
  - cognee_get_graph     Get the knowledge graph for a dataset

Transport: Streamable HTTP (/mcp) + SSE (/sse + /messages/)
"""

import json
import os
import io
from typing import Optional

import httpx
from mcp.server.fastmcp import FastMCP

COGNEE_BASE = os.environ.get("COGNEE_BASE_URL", "http://localhost:8000/api/v1")
HTTP_TIMEOUT = httpx.Timeout(connect=10, read=300, write=30, pool=10)

mcp = FastMCP("cognee")


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

async def _get(path: str, **params) -> dict | list:
    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
        resp = await client.get(f"{COGNEE_BASE}{path}", params=params)
        resp.raise_for_status()
        return resp.json()


async def _post_json(path: str, body: dict | None = None) -> dict | list:
    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
        resp = await client.post(f"{COGNEE_BASE}{path}", json=body or {})
        resp.raise_for_status()
        return resp.json()


def _fmt(result) -> str:
    """Format result as indented JSON string for tool return."""
    if isinstance(result, str):
        return result
    return json.dumps(result, indent=2, default=str)


# ---------------------------------------------------------------------------
# MCP Tools
# ---------------------------------------------------------------------------

@mcp.tool()
async def cognee_search(
    query: str,
    datasets: Optional[list[str]] = None,
    top_k: int = 5,
) -> str:
    """Semantic search across the Cognee knowledge graph.

    Use this to find relevant information stored in the graph memory.
    Always call this before answering questions about previously ingested context.

    Args:
        query: The search query string.
        datasets: Optional list of dataset names to scope the search.
        top_k: Maximum number of results to return (default 5).

    Returns:
        JSON string with search results from the knowledge graph.
    """
    body: dict = {"query": query, "topK": top_k}
    if datasets:
        body["datasets"] = datasets
    return _fmt(await _post_json("/search", body))


@mcp.tool()
async def cognee_add_text(
    text: str,
    dataset_name: str = "default",
) -> str:
    """Add text content to a Cognee dataset for later processing.

    After adding text, call cognee_cognify to process it into the knowledge graph.

    Args:
        text: The text content to ingest into the graph memory.
        dataset_name: Target dataset name (default: "default").

    Returns:
        JSON string with ingestion confirmation.
    """
    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
        resp = await client.post(
            f"{COGNEE_BASE}/add",
            files={
                "data": (
                    "content.txt",
                    io.BytesIO(text.encode("utf-8")),
                    "text/plain",
                )
            },
            data={"datasetName": dataset_name},
        )
        resp.raise_for_status()
        return _fmt(resp.json())


@mcp.tool()
async def cognee_cognify(
    datasets: Optional[list[str]] = None,
) -> str:
    """Process added data into the knowledge graph.

    Runs cognee's cognify pipeline: text chunking, entity extraction,
    relationship detection, embedding generation, and graph indexing.
    Call this after cognee_add_text to make the data searchable.

    Args:
        datasets: Optional list of dataset names to process.
            If omitted, processes all pending data.

    Returns:
        JSON string with processing result and run ID.
    """
    body: dict = {}
    if datasets:
        body["datasets"] = datasets
    return _fmt(await _post_json("/cognify", body))


@mcp.tool()
async def cognee_recall(
    query: str,
    datasets: Optional[list[str]] = None,
    top_k: int = 5,
) -> str:
    """Recall information from the knowledge graph (memory-oriented search).

    Similar to cognee_search but optimized for memory recall.
    Use this when retrieving previously stored facts or context.

    Args:
        query: The recall query string.
        datasets: Optional list of dataset names to search within.
        top_k: Maximum number of results (default 5).

    Returns:
        JSON string with recalled information.
    """
    body: dict = {"query": query, "topK": top_k}
    if datasets:
        body["datasets"] = datasets
    return _fmt(await _post_json("/recall", body))


@mcp.tool()
async def cognee_list_datasets() -> str:
    """List all available Cognee datasets.

    Returns:
        JSON array of datasets with id, name, and timestamps.
    """
    return _fmt(await _get("/datasets"))


@mcp.tool()
async def cognee_create_dataset(name: str) -> str:
    """Create a new Cognee dataset.

    Args:
        name: Name for the new dataset.

    Returns:
        JSON string with created dataset info including its UUID.
    """
    return _fmt(await _post_json("/datasets", {"name": name}))


@mcp.tool()
async def cognee_get_dataset_data(dataset_id: str) -> str:
    """Get raw data entries from a specific dataset.

    Args:
        dataset_id: UUID of the dataset.

    Returns:
        JSON string with raw data entries.
    """
    return _fmt(await _get(f"/datasets/{dataset_id}/data"))


@mcp.tool()
async def cognee_get_graph(dataset_id: str) -> str:
    """Get the knowledge graph (nodes + edges) for a dataset.

    Args:
        dataset_id: UUID of the dataset.

    Returns:
        JSON string with graph structure.
    """
    return _fmt(await _get(f"/datasets/{dataset_id}/graph"))
