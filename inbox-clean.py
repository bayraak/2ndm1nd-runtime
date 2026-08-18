#!/usr/bin/env python3
"""inbox-clean.py — hygiene for the raw-import INBOX (Archive/iCloud-Notes).

Raw imports are an inbox the brain triages, not memory. This one-time-safe,
re-runnable pass removes what should never have been a node:
  - CONTENTLESS notes (body < 8 meaningful chars) -> deleted (they're extracted
    copies; originals live in iCloud).
  - SECRET-BEARING notes (passwords / api keys / private keys) -> MOVED out of the
    vault to ~/Library/Application Support/2ndMind/notes-quarantine/ (they must not
    sit in git/GitHub). The brain never needs raw credentials.
Substantive notes stay — the brain integrates them into the graph over the drip.
Reports what it did; never touches anything outside Archive/iCloud-Notes.
"""
import re, shutil
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
INBOX = V / "Archive/iCloud-Notes"
QUAR = Path.home() / "Library/Application Support/2ndMind/notes-quarantine"
QUAR.mkdir(parents=True, exist_ok=True)

SECRET = re.compile(
    r"(?im)^\s*(pass(word)?|pwd|api[_-]?key|secret|token|client[_-]?secret)\s*[:=]\s*\S"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"
    r"|\b[A-Za-z0-9]*!\s*$"          # a bare 'Something1!' line == a password
)


def body_of(text):
    b = re.sub(r"^---.*?---\n", "", text, flags=re.S)
    b = re.sub(r"\n---\nEntities:.*$", "", b, flags=re.S)
    b = re.sub(r"^#[^\n]*\n", "", b.strip())
    return b.strip()


deleted, quarantined, kept = [], [], 0
for p in sorted(INBOX.glob("*.md")):
    text = p.read_text(encoding="utf-8", errors="replace")
    body = body_of(text)
    meaningful = re.sub(r"[\s\W_]+", "", body)
    if len(meaningful) < 8:
        p.unlink(); deleted.append(p.name); continue
    # count secret-looking lines; quarantine if the note is credential-dominated
    hits = len(SECRET.findall(body))
    if hits >= 1 and (hits >= 2 or len(meaningful) < 200):
        shutil.move(str(p), str(QUAR / p.name)); quarantined.append(p.name); continue
    kept += 1

print(f"inbox-clean: {kept} kept · {len(deleted)} contentless deleted · "
      f"{len(quarantined)} secret-bearing quarantined -> {QUAR}")
if quarantined:
    print("  quarantined:", ", ".join(quarantined[:12]))
