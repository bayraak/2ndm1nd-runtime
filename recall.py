#!/usr/bin/env python3
"""recall.py — cognition recall-test (L1). Capture coverage is measured;
COMPREHENSION isn't: did the chronicle actually cover what happened? This
samples 5 high-activity hours from the last 7 days (deterministic per ISO week,
so the whole week's Sunday sweep sees the same paper) with enough context to
check. The brain grades itself Sunday: journal covered it → [audit] HIT;
missed → MISS + backfill + lesson. The instrument that would have caught
"very poor" before he did. -> Atlas/AI/Brain/recall-test.md
"""
import random, sqlite3
from datetime import date
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
DB = Path.home() / "Library/Application Support/2ndMind/brain.db"
OUT = V / "Atlas/AI/Brain/recall-test.md"

con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
hours = con.execute(
    "SELECT strftime('%Y-%m-%d %H', ts, 'unixepoch', 'localtime') h, COUNT(*) n"
    " FROM events WHERE source IN ('input','focus','git')"
    "  AND ts > strftime('%s','now') - 7*86400"
    " GROUP BY h HAVING n > 80 ORDER BY h").fetchall()

rng = random.Random(date.today().isocalendar()[1])  # stable within an ISO week
sample = sorted(rng.sample(hours, min(5, len(hours))))

body = ["---", "title: recall-test", "type: note", "---", "",
        "# RECALL TEST — did my chronicle cover these? (5 sampled busy hours, stable per week)",
        "",
        "Sunday sweep: for each hour, check the journal/chronicle covered its substance.",
        "Covered → `[audit] HIT` in PREDICTIONS.md; missed → MISS + backfill + [self] lesson."]
for h, n in sample:
    body += ["", f"## {h}:00 — {n} activity events"]
    for app, txt in con.execute(
            "SELECT COALESCE(app,''), substr(text,1,160) FROM events"
            " WHERE strftime('%Y-%m-%d %H', ts,'unixepoch','localtime') = ?"
            "  AND text IS NOT NULL AND LENGTH(text) > 20"
            " ORDER BY LENGTH(text) DESC LIMIT 3", (h,)):
        body.append(f"- [{app.split('.')[-1]}] “{' '.join(txt.split())}”")
con.close()
OUT.write_text("\n".join(body) + "\n", encoding="utf-8")
print(f"recall-test: {len(sample)} sampled hours -> {OUT.name}")
