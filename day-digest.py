#!/usr/bin/env python3
"""day-digest.py — deterministic evidence pre-digestion for the nightly fold.

Quality principle: the model's turns should be spent on COGNITION, not on
exploratory SQL. Code can guarantee evidence completeness; a model can only
intend it. The runner calls this before each cycle; it compiles the window's
evidence into ONE organ file (Atlas/AI/Brain/digest.md, graph-excluded) that
the brain reads first, drilling into the ledger only where the digest is thin.

Sections: SHAPE (hour x source) · his words (qa-exchanges, claude-code turns,
typed text) · clipboard · commits · shell · browser · NEW MAIL since cursor ·
UPCOMING 7d · @brain hits · inbox + quality-queue status. Bounded output.
"""
import argparse, json, re, sqlite3
from collections import Counter
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
BRAIN = V / "Atlas/AI/Brain"
DB = Path.home() / "Library/Application Support/2ndMind/brain.db"

ap = argparse.ArgumentParser()
ap.add_argument("--since", type=float, required=True)
ap.add_argument("--out", default=str(BRAIN / "digest.md"))
a = ap.parse_args()

con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
q = lambda sql, *p: con.execute(sql, p).fetchall()
win = "ts > ? AND ts <= strftime('%s','now')"

def sec(title):
    out.append(f"\n## {title}\n")

def clip(s, n):
    s = " ".join((s or "").split())
    return s[: n - 1] + "…" if len(s) > n else s

out = ["---", "title: digest", "type: note", "---", "",
       "# DIGEST — deterministic evidence for this window (generated; I read this FIRST, "
       "then drill into the ledger only where this is thin)"]

hours = q(f"SELECT strftime('%Y-%m-%d %Hh',ts,'unixepoch','localtime'), source, COUNT(*) "
          f"FROM events WHERE {win} AND source NOT IN ('mail','calendar','reminders') "
          f"GROUP BY 1,2 ORDER BY 1", a.since)
sec(f"SHAPE — activity by hour ({len(hours)} rows)")
byh = {}
for h, s, n in hours:
    byh.setdefault(h, []).append(f"{s}:{n}")
for h in sorted(byh):
    out.append(f"- {h} · " + " ".join(byh[h]))

sec("YOUR WORDS — qa-exchanges (verbatim, every one in the window)")
# The Q is a SUFFIX of a screen dump and the A is his actual reply, so it sits at the
# END of the text. Clipping the FIRST 700 chars therefore threw away every word he
# wrote and kept, for a chat, the conversation SIDEBAR — a list of ~20 contact names.
# The section titled "YOUR WORDS" was showing none of his words and a menu of wrong
# answers to "who was he talking to" (found 2026-08-05, pre-SLEEP audit). Keep the
# TAIL: the whole A, plus enough Q for context. Carry the event id + attribution so a
# resolution can be written back with `brain annotate <id> to "<name>"` — without the
# id, resolving means inventing SQL, and it will not happen.
for ts, app, txt, eid, chan, to, unres, stale in q(
        f"SELECT datetime(ts,'unixepoch','localtime'), COALESCE(app,''), text, id, "
        f"COALESCE(json_extract(payload,'$.channel'),''), "
        f"COALESCE(json_extract(payload,'$.to'),''), "
        f"json_extract(payload,'$.addressee_unresolved'), "
        f"json_extract(payload,'$.attribution_stale') "
        f"FROM events WHERE kind='qa-exchange' AND text IS NOT NULL AND {win} "
        f"ORDER BY ts", a.since):
    body = " ".join((txt or "").split())
    body = ("…" + body[-1000:]) if len(body) > 1000 else body
    tag = f"id={eid}"
    if chan:  tag += f" ch={chan}"
    if to:    tag += f" to={to}"
    elif unres is not None: tag += " UNRESOLVED"
    if stale is not None:   tag += " STALE"
    out.append(f"- {ts} [{app}] ({tag}) {body}")

sec("YOUR WORDS — claude-code session turns")
for ts, txt in q(f"SELECT datetime(ts,'unixepoch','localtime'), text FROM events "
                 f"WHERE source='claude-code' AND text IS NOT NULL AND {win} ORDER BY ts LIMIT 120", a.since):
    out.append(f"- {ts} {clip(txt, 500)}")

sec("YOUR WORDS — typed text (non-terminal apps)")
for ts, app, txt in q(f"SELECT datetime(ts,'unixepoch','localtime'), COALESCE(app,''), text "
                      f"FROM events WHERE kind='activity-window' AND text IS NOT NULL "
                      f"AND LENGTH(text) > 15 AND {win} ORDER BY ts LIMIT 200", a.since):
    out.append(f"- {ts} [{app}] {clip(txt, 400)}")

sec("CLIPBOARD")
for ts, txt in q(f"SELECT datetime(ts,'unixepoch','localtime'), text FROM events "
                 f"WHERE kind='clipboard-changed' AND text IS NOT NULL AND {win} ORDER BY ts LIMIT 40", a.since):
    out.append(f"- {ts} {clip(txt, 300)}")

sec("GIT commits")
for ts, txt in q(f"SELECT datetime(ts,'unixepoch','localtime'), text FROM events "
                 f"WHERE source='git' AND {win} ORDER BY ts LIMIT 120", a.since):
    out.append(f"- {ts} {clip(txt, 200)}")

sec("SHELL")
for txt, in q(f"SELECT text FROM events WHERE source='shell-history' AND text IS NOT NULL "
              f"AND {win} ORDER BY ts LIMIT 60", a.since):
    out.append(f"- {clip(txt, 200)}")

sec("BROWSER (deduped titles)")
seen = set()
for txt, in q(f"SELECT text FROM events WHERE source='browser' AND text IS NOT NULL AND {win} "
              f"ORDER BY ts LIMIT 300", a.since):
    c = clip(txt, 160)
    if c not in seen:
        seen.add(c)
        out.append(f"- {c}")
    if len(seen) >= 80:
        break

cursor = 0
cf = BRAIN / "mail-cursor.md"
if cf.exists():
    m = re.search(r"\d+", cf.read_text())
    cursor = int(m.group()) if m else 0
sec(f"NEW MAIL — rowid > {cursor}, dated within 3d (I advance mail-cursor.md after folding)")
for rid, frm, subj, txt in q(
        "SELECT rowid, payload->>'from', payload->>'subject', substr(text,1,500) FROM events "
        "WHERE source='mail' AND rowid > ? AND ts > strftime('%s','now')-3*86400 ORDER BY rowid LIMIT 60",
        cursor):
    out.append(f"- rowid {rid} · {clip(frm or '', 60)} — {clip(subj or '', 140)}")
    out.append(f"  {clip(txt or '', 350)}")

sec("UPCOMING 7 days (calendar/reminders)")
for ts, s, txt in q("SELECT datetime(ts,'unixepoch','localtime'), source, text FROM events "
                    "WHERE source IN ('calendar','reminders') AND ts BETWEEN strftime('%s','now') "
                    "AND strftime('%s','now')+7*86400 ORDER BY ts LIMIT 30"):
    out.append(f"- {ts} [{s}] {clip(txt, 120)}")

sec("@BRAIN mentions (verify: a terminal displaying my code is NOT you addressing me)")
for ts, app, txt in q(f"SELECT datetime(ts,'unixepoch','localtime'), COALESCE(app,''), substr(text,1,400) "
                      f"FROM events WHERE text LIKE '%@brain%' AND {win} ORDER BY ts LIMIT 10", a.since):
    out.append(f"- {ts} [{app}] {clip(txt, 400)}")

sec("WORK QUEUES")
ac = BRAIN / "archive-cursor.md"
if ac.exists():
    t = ac.read_text()
    pend = len(re.findall(r"^- \[ \]", t, re.M))
    nxt = re.findall(r"^- \[ \] (.+)$", t, re.M)[:10]
    out.append(f"- INBOX INTEGRATION: {pend} pending; next: " + "; ".join(clip(x, 60) for x in nxt))
qq = BRAIN / "quality-queue.md"
if qq.exists():
    t = qq.read_text()
    pend = len(re.findall(r"^- \[ \]", t, re.M))
    out.append(f"- QUALITY QUEUE: {pend} open lint issues (see quality-queue.md)")
pdir = V / "Atlas/Mind/proposals"
if pdir.is_dir():
    openp = [p.name for p in sorted(pdir.glob("*.md"))
             if "status: open" in p.read_text(encoding="utf-8", errors="replace")[:400]]
    out.append(f"- OPEN PROPOSALS: {len(openp)}" + (" — " + "; ".join(openp) if openp else ""))

con.close()
body = "\n".join(out) + "\n"
Path(a.out).write_text(body, encoding="utf-8")
print(f"digest: {len(body)//1024}KB -> {a.out}")
