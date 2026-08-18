#!/usr/bin/env python3
"""Live MCP verification: spawn brain_mcp.py, handshake, list + call tools."""
import asyncio
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

HERE = os.path.dirname(os.path.abspath(__file__))
PY = os.path.join(HERE, ".venv", "bin", "python")


async def main() -> int:
    params = StdioServerParameters(command=PY, args=[os.path.join(HERE, "brain_mcp.py")])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            names = [t.name for t in tools.tools]
            print("TOOLS:", names)
            assert {"brain_search", "brain_now", "brain_spans", "brain_stats", "brain_ask"} <= set(names), "missing tools"

            stats = await session.call_tool("brain_stats", {})
            print("brain_stats ->", stats.content[0].text.replace("\n", " ")[:160])

            search = await session.call_tool("brain_search", {"query": "brain", "limit": 1})
            txt = search.content[0].text
            print("brain_search ->", ("HIT" if "brain" in txt.lower() else "empty"), txt.replace("\n", " ")[:120])
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
