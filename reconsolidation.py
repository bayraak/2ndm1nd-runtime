#!/usr/bin/env python3
"""reconsolidation.py — enforced memory maintenance (L1). Memory science:
retrieval REWRITES a memory (reconsolidation), and un-revisited memories drift
stale while life moves on. This finds exactly that drift, mechanically:
  STALE-BUT-ALIVE  entities active in the last-7d ledger whose note hasn't been
                   updated in >=14d — the life moved, the memory didn't.
  EXPIRING CLAIMS  MODEL state-claims older than 12 months (state half-life
                   ~18mo) — present-tense assertions nearing re-verification.
The brain revisits the top items each SLEEP (re-read, verify, supersede or
re-date). -> Atlas/AI/Brain/reconsolidation.md
"""
import re, sqlite3, unicodedata
from datetime import date, datetime
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
DB = Path.home() / "Library/Application Support/2ndMind/brain.db"
OUT = V / "Atlas/AI/Brain/reconsolidation.md"
DIRS = ["Atlas/Projects", "Atlas/Organizations", "Atlas/People"]


def fold(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s.casefold())
                   if not unicodedata.combining(c))


def fm_aliases(text):
    if not text.startswith("---"):
        return []
    end = text.find("\n---", 3)
    if end < 0:
        return []
    fm, out = text[3:end], []
    m = re.search(r"^aliases:\s*\[(.*?)\]\s*$", fm, re.M)
    if m:
        out += [a.strip().strip("'\"") for a in m.group(1).split(",")]
    m = re.search(r"^aliases:\s*$(.*?)(?=^\w[\w-]*:|^---|\Z)", fm, re.M | re.S)
    if m:
        out += [x.group(1).strip().strip("'\"") for x in re.finditer(r"^\s*-\s*(.+)$", m.group(1), re.M)]
    return [a for a in out if a]


ents = {}
for d in DIRS:
    for p in (V / d).glob("*.md"):
        if p.name == "README.md":
            continue
        t = p.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"^updated:\s*(\d{4}-\d{2}-\d{2})", t[:800], re.M)
        # fall back to newest dated bullet, else file mtime
        if not m:
            dates = re.findall(r"\b(20\d\d-\d\d-\d\d)\b", t)
            upd = max(dates) if dates else datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d")
        else:
            upd = m.group(1)
        terms = sorted({x for x in ({p.stem} | set(fm_aliases(t))) if len(x) >= 4})
        ents[p.stem] = (str(p.relative_to(V)), upd, terms)

con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
blob = " ".join(r[0] for r in con.execute(
    "SELECT COALESCE(text,'')||' '||COALESCE(app,'') FROM events"
    " WHERE ts > strftime('%s','now') - 7*86400"
    "   AND (text IS NOT NULL OR app IS NOT NULL) LIMIT 20000"))
con.close()
fblob = fold(blob)

today = date.today()
stale = []
for stem, (rel, upd, terms) in ents.items():
    hits = sum(len(re.findall(rf"(?<!\w){re.escape(fold(t))}(?!\w)", fblob)) for t in terms)
    try:
        age = (today - date.fromisoformat(upd)).days
    except ValueError:
        age = 999
    if hits >= 15 and age >= 14:
        stale.append((hits * age, stem, rel, upd, age, hits))
stale.sort(reverse=True)

model = (V / "Atlas/Mind/MODEL.md").read_text(encoding="utf-8", errors="replace") \
    if (V / "Atlas/Mind/MODEL.md").exists() else ""
expiring = []
for m in re.finditer(r"^- \[state · (\d{4})-(\d{2})[^\]]*\] (.{0,90})", model, re.M):
    y, mo = int(m.group(1)), int(m.group(2))
    months = (today.year - y) * 12 + today.month - mo
    if months >= 12:
        expiring.append((months, m.group(3).strip()))

body = ["---", "title: reconsolidation", "type: note", "---", "",
        "# RECONSOLIDATION — memories to revisit (L1; retrieval rewrites memory, "
        "staleness is measured, not felt)", "",
        f"## Stale-but-alive ({len(stale)}) — active in your last 7 days, note untouched ≥14d",
        "I revisit the top 2-3 each sleep: re-read, verify, supersede or re-date."]
for _, stem, rel, upd, age, hits in stale[:12]:
    body.append(f"- **{stem}** (`{rel}`) — {hits} activity hits / note {age}d old (updated {upd})")
if not stale:
    body.append("- none — every active memory is fresh")
body += ["", f"## Expiring state-claims ({len(expiring)}) — past 12 of ~18mo half-life; re-verify or re-tense"]
body += [f"- ({mo} mo) {c}" for mo, c in sorted(expiring, reverse=True)[:10]] or ["- none"]
OUT.write_text("\n".join(body) + "\n", encoding="utf-8")
print(f"reconsolidation: {len(stale)} stale-but-alive, {len(expiring)} expiring claims")
for _, stem, rel, upd, age, hits in stale[:5]:
    print(f"  {stem}: {hits} hits, {age}d stale")
