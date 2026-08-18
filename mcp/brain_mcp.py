#!/usr/bin/env python3
"""2ndMind brain — MCP server.

Exposes the local second brain as MCP tools so any MCP client (Claude Code,
Desktop, or — via the CF tunnel — claude.ai / mobile) can query it. Wraps the
`brain` CLI (ledger) + the BrainServer (now/ask); touches nothing else.

Run:  uv run --with "mcp[cli]" python brain_mcp.py     (see .mcp.json)
"""
import json
import os
import subprocess
import urllib.request
from pathlib import Path

from mcp.server.fastmcp import FastMCP

HOME = Path.home()
BRAIN = str(HOME / ".local/share/2ndm1nd/bin/brain")
VAULT = str(HOME / "Projects/2ndm1nd")
PORT = 4517
TOKEN_PATH = HOME / "Library/Application Support/2ndMind/server-token"

mcp = FastMCP("2ndmind-brain")


def _token() -> str:
    return TOKEN_PATH.read_text().strip()


def _brain(*args: str) -> str:
    r = subprocess.run([BRAIN, *args], capture_output=True, text=True, timeout=30)
    return r.stdout if r.returncode == 0 else f"error: {r.stderr.strip()}"


def _server(path: str, method: str = "GET", body: dict | None = None, timeout: int = 120) -> str:
    url = f"http://127.0.0.1:{PORT}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {_token()}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode()


@mcp.tool()
def brain_search(query: str, limit: int = 20) -> str:
    """Full-text search across ALL captured activity — browser history, shell
    commands, focused apps/windows, messages, emails, files. Returns JSON hits
    with source, timestamp, and a highlighted snippet."""
    return _brain("search", query, "--limit", str(limit))


@mcp.tool()
def brain_spans(date: str = "") -> str:
    """Human-readable activity spans for a day (default today). `date` is
    YYYY-MM-DD. Each span: time range, activity (coding/browsing/…), app, project."""
    args = ["spans"] + (["--date", date] if date else [])
    return _brain(*args)


@mcp.tool()
def brain_now() -> str:
    """The current rolling recommendation — what to do now to best advance the
    user's goals (Atlas/AI/Now.md), produced by the cortex solver."""
    p = Path(VAULT) / "Atlas/AI/Now.md"
    return p.read_text() if p.exists() else "(no Now.md yet)"


@mcp.tool()
def brain_stats() -> str:
    """Ledger stats: total events, spans, latest-event timestamp."""
    return _brain("stats")


@mcp.tool()
def brain_ask(question: str) -> str:
    """Ask an agentic question about the user's own activity and memory. The
    brain searches its ledger + markdown memory and answers with evidence.
    May take up to a minute (runs a headless Opus call)."""
    try:
        out = _server("/ask", method="POST", body={"q": question})
        return json.loads(out).get("answer", out)
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


if __name__ == "__main__":
    mcp.run()
