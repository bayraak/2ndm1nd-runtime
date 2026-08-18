#!/usr/bin/env python3
"""brain-prime.py — deterministic entity PRIMING for the brain's hourly cycle.

Human memory doesn't search, it associates: seeing a name activates what you
know about it. This script gives the brain that reflex — before each cycle the
runner asks: which entity notes (Atlas/Projects|People|Organizations|Memory/topics)
are mentioned in the ledger window the brain is about to read? Those files are
injected into the cycle prompt so the model wakes already primed, instead of
having to *decide* to Grep for them.

Zero LLM. Bounded output. Read-only ledger access. Failure = empty output
(the runner treats priming as best-effort).
"""

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path

# (dir, recursive) — Atlas/Mind is the brain's self-organized universe, so its
# depth is unknown by design; the inherited dirs stay flat.
ENTITY_DIRS = [
    ("Atlas/Projects", False),
    ("Atlas/People", False),
    ("Atlas/Organizations", False),
    ("Atlas/Memory/topics", False),
    ("Atlas/Mind", True),
]
# Never prime on these stems — generic words / the brain's own organs.
BLACKLIST = {"self", "index", "home", "brain", "story", "notes", "test", "misc",
             "ontology", "proposals", "skills", "readme"}
CORPUS_ROWS = 800          # newest events considered
CORPUS_CAP = 250_000       # chars of corpus scanned
FILE_READ_CAP = 32_768     # bytes read per entity file
PER_FILE_CHARS = 2_200     # chars of each primed note injected


def frontmatter_aliases(text: str) -> list[str]:
    """Parse `aliases:` out of YAML frontmatter (block list or inline list)."""
    if not text.startswith("---"):
        return []
    end = text.find("\n---", 3)
    if end < 0:
        return []
    fm = text[3:end]
    aliases: list[str] = []
    inline = re.search(r"^aliases:\s*\[(.*?)\]\s*$", fm, re.MULTILINE)
    if inline:
        aliases += [a.strip().strip("'\"") for a in inline.group(1).split(",")]
    block = re.search(r"^aliases:\s*$(.*?)(?=^\w[\w-]*:|^---|\Z)", fm, re.MULTILINE | re.DOTALL)
    if block:
        aliases += [
            m.group(1).strip().strip("'\"")
            for m in re.finditer(r"^\s*-\s*(.+)$", block.group(1), re.MULTILINE)
        ]
    return [a for a in aliases if a]


def gather_corpus(db: str, since: float) -> str:
    """Newest ledger text since the watermark — window titles, typed text,
    mail From/Subject, commits, browser pages. Mail payload from/subject ride
    in `text`; `app` catches bundle ids naming projects."""
    uri = f"file:{db}?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=3)
    try:
        rows = con.execute(
            "SELECT COALESCE(text,'') || ' ' || COALESCE(app,'') FROM events "
            "WHERE ts > ? AND (text IS NOT NULL OR app IS NOT NULL) "
            "ORDER BY ts DESC LIMIT ?",
            (since, CORPUS_ROWS),
        ).fetchall()
    finally:
        con.close()
    return "\n".join(r[0] for r in rows)[:CORPUS_CAP].casefold()


def entity_index(vault: Path) -> list[tuple[str, Path, list[str]]]:
    """(name, path, match-terms) for every entity note."""
    out = []
    for rel, recursive in ENTITY_DIRS:
        d = vault / rel
        if not d.is_dir():
            continue
        for p in sorted(d.rglob("*.md") if recursive else d.glob("*.md")):
            name = p.stem
            if name.casefold() in BLACKLIST:
                continue
            try:
                head = p.read_text(encoding="utf-8", errors="replace")[:4096]
            except OSError:
                head = ""
            terms = {name} | set(frontmatter_aliases(head))
            terms = {t for t in terms if len(t) >= 3 and t.casefold() not in BLACKLIST}
            if terms:
                out.append((name, p, sorted(terms)))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--vault", required=True)
    ap.add_argument("--since", type=float, required=True)
    ap.add_argument("--max-files", type=int, default=5)
    ap.add_argument("--max-bytes", type=int, default=9000)
    args = ap.parse_args()

    try:
        corpus = gather_corpus(args.db, args.since)
    except Exception:
        return 0  # best-effort: no corpus, no priming
    if not corpus.strip():
        return 0

    scored: list[tuple[int, str, Path]] = []
    for name, path, terms in entity_index(Path(args.vault)):
        score = 0
        for t in terms:
            # Word-boundary match so "Deb" never fires on "debug".
            score += len(re.findall(rf"\b{re.escape(t.casefold())}\b", corpus))
        if score > 0:
            scored.append((score, name, path))
    scored.sort(key=lambda x: (-x[0], x[1]))

    budget = args.max_bytes
    blocks: list[str] = []
    for score, name, path in scored[: args.max_files]:
        try:
            body = path.read_text(encoding="utf-8", errors="replace")[:FILE_READ_CAP]
        except OSError:
            continue
        body = body[:PER_FILE_CHARS].rstrip()
        rel = path.relative_to(args.vault)
        block = f"=== PRIMED: {name} ({rel}) — {score}× in your window ===\n{body}"
        if len(block) > budget:
            break
        blocks.append(block)
        budget -= len(block) + 2
    if blocks:
        sys.stdout.write("\n\n".join(blocks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
