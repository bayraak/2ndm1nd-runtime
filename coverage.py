#!/usr/bin/env python3
"""coverage.py — the HUNGER signal (L1). A self-evolving mind needs to know
where its evidence is thin before it can learn to gather more. This measures
capture coverage mechanically:
  DARK APPS    apps you actively use (focus events) whose CONTENT we never
               capture (no typed text / qa there) — candidate new senses
  DARK HOURS   hours with heavy presence but near-zero words — activity the
               mind sees but cannot read
  STALE SOURCES  per-source last-event age vs its normal cadence
  HARVESTERS   the brain's own registered senses (Mind/skills/harvest-*) status
The brain reads this each sleep and SENSE-HUNTS: probe one dark spot read-only,
grow a harvester skill if there's signal, or file a proposal if it needs rails.
-> Atlas/AI/Brain/coverage.md
"""
import sqlite3, time
from collections import defaultdict
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
DB = Path.home() / "Library/Application Support/2ndMind/brain.db"
OUT = V / "Atlas/AI/Brain/coverage.md"
SKILLS = V / "Atlas/Mind/skills"
DAYS = 14

con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
focus = dict(con.execute(
    "SELECT COALESCE(app,'?'), COUNT(*) FROM events WHERE source='focus'"
    " AND ts > strftime('%s','now') - ? * 86400 GROUP BY 1", (DAYS,)))
words = dict(con.execute(
    "SELECT COALESCE(app,'?'), COUNT(*) FROM events WHERE source='input'"
    " AND text IS NOT NULL AND ts > strftime('%s','now') - ? * 86400 GROUP BY 1", (DAYS,)))
dark_hours = con.execute(
    "SELECT COUNT(*) FROM (SELECT strftime('%Y-%m-%d %H', ts,'unixepoch','localtime') h,"
    " SUM(source='focus') f, SUM(source='input' AND text IS NOT NULL) w FROM events"
    " WHERE ts > strftime('%s','now') - ? * 86400 GROUP BY h HAVING f > 50 AND w < 5)",
    (DAYS,)).fetchone()[0]
sources = con.execute(
    "SELECT source, COUNT(*), CAST((strftime('%s','now') - MAX(ts)) / 3600 AS INT)"
    " FROM events GROUP BY source ORDER BY 2 DESC").fetchall()
# ATTRIBUTION HUNGER (2026-08-05). Content without an addressee is a monologue:
# 806 WhatsApp Web exchanges were captured as exactly that, and the "who is brate"
# question stayed unanswerable for weeks because nothing MEASURED the gap. Capture
# now stamps to/channel/win_title per utterance, so the hole is countable — and a
# countable hole is one the brain is constitutionally required to sense-hunt.
attribution = con.execute(
    "SELECT COALESCE(json_extract(payload,'$.channel'),'(none)') ch, COUNT(*) n,"
    " SUM(json_extract(payload,'$.to') IS NOT NULL) resolved,"
    " SUM(json_extract(payload,'$.addressee_unresolved') IS NOT NULL) unresolved,"
    " SUM(json_extract(payload,'$.attribution_stale') IS NOT NULL) stale"
    " FROM events WHERE source='input' AND text IS NOT NULL"
    " AND ts > strftime('%s','now') - ? * 86400 GROUP BY ch ORDER BY n DESC", (DAYS,)).fetchall()
con.close()
con2 = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
# The queue must not re-present work already done. vitals() subtracts sidecar
# annotations; coverage did not, so the brain read two meters that disagreed and
# correctly demoted this one to "a ceiling, not a work-list". Same source of truth now.
ANNOT = Path.home() / "Library/Application Support/2ndMind/annotations.db"
_resolved = set()
if ANNOT.exists():
    try:
        _a = sqlite3.connect(f"file:{ANNOT}?mode=ro", uri=True, timeout=5)
        _resolved = {r[0] for r in _a.execute("SELECT DISTINCT event_id FROM annotations WHERE key='to'")}
        _a.close()
    except Exception:
        pass

dark_apps = sorted(((f, app) for app, f in focus.items()
                    if f >= 150 and words.get(app, 0) < 10), reverse=True)

harvesters = sorted(SKILLS.glob("harvest-*")) if SKILLS.is_dir() else []

body = ["---", "title: coverage", "type: note", "---", "",
        f"# COVERAGE — where my evidence is thin (the hunger signal; {DAYS}d; coverage.py)",
        "",
        "I SENSE-HUNT from this: pick ONE dark spot per sleep, probe read-only, grow a",
        "harvester skill if there's signal, or file a proposal if it needs rails.",
        "",
        f"## Dark apps ({len(dark_apps)}) — you use them; I capture no words there"]
for f, app in dark_apps[:12]:
    body.append(f"- **{app}** — {f} focus events, ~0 text. Where does its content live on disk?")
if not dark_apps:
    body.append("- none — every heavily-used app yields text")
body += ["", f"## Dark hours: {dark_hours} app-hours of heavy presence with <5 captured words",
         "", "## Source freshness (hours since last event)"]
for s, n, age in sources:
    flag = " ⚠️" if (s in ("mail", "input", "focus") and (age or 0) > 30) else ""
    body.append(f"- {s} — {n} total · last {age}h ago{flag}")
body += ["", "## Attribution — do I know WHO he was talking to?",
         "",
         "Every utterance now carries `channel` + raw `win_title`; `to` is filled only where",
         "the channel names the addressee in its window title. **A row with unresolved > 0 is",
         "a conversation I recorded one half of.** Resolve those from the raw evidence at SLEEP",
         "(the Q snapshot holds the conversation pane) and record channel-qualified handles in",
         "`Atlas/People/*` aliases — shaped `whatsapp:<handle>`, `slack:<handle>` — so the same human",
         "stops being several strangers. Do NOT ask for a code change to fix a name: the evidence",
         "is in the ledger, the resolution is yours to make.",
         "",
         "Write the resolution back with **`brain annotate <event_id> to \"<name>\" --by brain`**",
         "(insert-only, sidecar db — the raw ledger is never edited; re-annotating supersedes).",
         "Read them back with `brain annotations --key to`. This is your only write path into",
         "the ledger's meaning, and it is enough: capture owns the eye, you own the interpretation.",
         ""]
if attribution:
    body.append("| channel | utterances | to resolved | unresolved | stale |")
    body.append("|---|---|---|---|---|")
    for ch, n, res, unres, stale in attribution:
        flag = " ⚠️" if (unres or 0) > 0 else ""
        body.append(f"| {ch}{flag} | {n} | {res or 0} | {unres or 0} | {stale or 0} |")
else:
    body.append("- no attributed utterances yet (capture predates the attribution build)")

# The actual work queue. An exhortation with no ids is a wish; a list of ids is a task.
unresolved_rows = con2.execute(
    "SELECT id, datetime(ts,'unixepoch','localtime'),"
    " COALESCE(json_extract(payload,'$.channel'),''),"
    " COALESCE(json_extract(payload,'$.win_title'),''),"
    " json_extract(payload,'$.attribution_stale')"
    " FROM events WHERE source='input' AND text IS NOT NULL"
    " AND json_extract(payload,'$.addressee_unresolved') IS NOT NULL"
    " AND ts > strftime('%s','now') - ? * 86400 ORDER BY ts DESC LIMIT 40", (DAYS,)).fetchall()
if unresolved_rows:
    body += ["", f"### Unresolved queue ({len([r for r in unresolved_rows if r[0] not in _resolved])} shown) — resolve these by id", "",
             "**Method** (the snapshot contains BOTH the sidebar list and the open thread, so the",
             "salient name is usually the WRONG one): find the sidebar row whose preview text and",
             "timestamp match the open thread's last message — that row names the thread. If no such",
             "match exists, leave it unresolved and say so. A wrong name is worse than no name.",
             "Rows marked STALE had the window title change mid-capture: the text may span two",
             "conversations — resolve only on an unambiguous pane match, else skip.",
             "Alias into `Atlas/People/*` only after the same handle matches in **≥2** separate",
             "windows; one match earns an annotation and a journal note, not an identity.", ""]
    unresolved_rows = [r for r in unresolved_rows if r[0] not in _resolved]
    for rid, rts, rch, rtitle, rstale in unresolved_rows:
        body.append(f"- `{rid}` · {rts} · {rch}{' · STALE' if rstale is not None else ''} · {rtitle[:60]}")

body += ["", f"## My own harvesters ({len(harvesters)}) — senses I grew myself (Mind/skills/harvest-*)"]
for h in harvesters:
    age_d = int((time.time() - h.stat().st_mtime) / 86400)
    body.append(f"- `{h.name}` (touched {age_d}d ago) — registry: Mind/skills/HARVEST.md")
if not harvesters:
    body.append("- none yet — grow the first one from a dark spot above")
con2.close()
OUT.write_text("\n".join(body) + "\n", encoding="utf-8")
print(f"coverage: {len(dark_apps)} dark apps, {dark_hours} dark hours, {len(harvesters)} harvesters")
for f, a in dark_apps[:5]:
    print(f"  dark: {a} ({f} focus)")
