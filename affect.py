#!/usr/bin/env python3
"""affect.py — the affective layer (L1 evidence). Affective science for the mind:
emotion = valence + arousal (circumplex), and emotional events consolidate
stronger. This detects AFFECT MARKERS in his own typed words — multilingual
lexicon (EN/TR/MK/AL), emoji classes, intensity punctuation — never
psychoanalysis: markers only, the brain (L3) interprets with evidence.
Outputs: daily valence trend, recent affect events (quoted), per-entity affect
hints (markers co-occurring with an entity name). -> Atlas/AI/Brain/affect.md
"""
import re, sqlite3, unicodedata
from collections import Counter, defaultdict
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
DB = Path.home() / "Library/Application Support/2ndMind/brain.db"
OUT = V / "Atlas/AI/Brain/affect.md"
DAYS = 60

POS = re.compile(
    r"\b(love|great|perfect|awesome|nice|beautiful|thanks|thank you|haha|lol|cool|excellent|"
    r"harika|süper|guzel|güzel|sağol|tesekkur|teşekkür|mükemmel|"
    r"te sakam|zemer|ubavo|blagodaram|mire|mirë|faleminderit|bravo)\b|❤|🥰|😍|😊|😂|🎉|👍|<3", re.I)
NEG = re.compile(
    r"\b(wtf|bullshit|fu?ck\w*|ffs|shit|damn|annoying|broken|hate|terrible|awful|poor|stuck|"
    r"berbat|kötü|kotu|saçma|sacma|sinir|rezalet|"
    r"losho|лошо|keq|problem)\b|😡|😤|😞|👎", re.I)
INTENSE = re.compile(r"!{2,}|\?!|\b[A-ZĞŞİÜÖÇ]{4,}\b")


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


idx = {}
for d in ["Atlas/People", "Atlas/Organizations", "Atlas/Projects"]:
    for p in (V / d).glob("*.md"):
        if p.name == "README.md":
            continue
        for t in {p.stem} | set(fm_aliases(p.read_text(encoding="utf-8", errors="replace")[:4096])):
            if len(t) >= 4:
                idx[fold(t)] = p.stem
pats = [(re.compile(rf"(?<!\w){re.escape(k)}(?!\w)"), v) for k, v in idx.items()]

con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
rows = con.execute(
    "SELECT datetime(ts,'unixepoch','localtime'), date(ts,'unixepoch','localtime'),"
    "       COALESCE(app,''), text FROM events"
    " WHERE kind IN ('activity-window','qa-exchange') AND text IS NOT NULL"
    "   AND LENGTH(text) > 8 AND ts > strftime('%s','now') - ? * 86400 ORDER BY ts", (DAYS,)).fetchall()
con.close()

daily = defaultdict(lambda: [0, 0])          # date -> [pos, neg]
events = []                                   # (dt, app, valence, clip)
ent_affect = defaultdict(lambda: [0, 0])
seen = set()   # (app, day, content-hash): a looping agent re-snapshots the SAME
               # screen for hours — 30 identical Q/As fabricated a euphoric day
               # (+37) when real markers were 2. Brain proposal 2026-07-19:
               # count identical content once per app-day.
for dt, d, app, text in rows:
    if text.startswith("Q: "):
        m = re.search(r"\nA: (.*)$", text, re.S)
        text = m.group(1) if m else ""
    key = (app, d, hash(re.sub(r"\s+", " ", text).strip()[:300].casefold()))
    if key in seen:
        continue
    seen.add(key)
    pos, neg = len(POS.findall(text)), len(NEG.findall(text))
    if not (pos or neg):
        continue
    daily[d][0] += pos
    daily[d][1] += neg
    val = "+" if pos > neg else ("-" if neg > pos else "±")
    intense = "!" if INTENSE.search(text) else ""
    clip = " ".join(text.split())[:120]
    events.append((dt, app.split(".")[-1], f"{val}{intense}", clip))
    ftext = fold(text)
    for pat, ent in pats:
        if pat.search(ftext):
            ent_affect[ent][0] += pos
            ent_affect[ent][1] += neg

body = ["---", "title: affect", "type: note", "---", "",
        f"# AFFECT — emotional markers in your own words (L1; {DAYS}d; lexicon EN/TR/MK/AL + emoji;"
        " markers only — I interpret with evidence, never psychoanalyze)", "",
        "## Daily valence (markers/day: + positive · − negative)"]
for d in sorted(daily)[-21:]:
    p, n = daily[d]
    body.append(f"- {d} · +{p} −{n} " + ("▲" if p > n else ("▼" if n > p else "·")))
body += ["", "## Recent affect events (newest last; the FEELING seam for my chronicle)"]
for dt, app, v, clip in events[-25:]:
    body.append(f"- {dt} [{app}] {v} “{clip}”")
body += ["", "## Per-entity affect hints (markers co-occurring with the name; hints, not verdicts)"]
for ent, (p, n) in sorted(ent_affect.items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:15]:
    body.append(f"- **{ent}** · +{p} −{n}")
OUT.write_text("\n".join(body) + "\n", encoding="utf-8")
print(f"affect: {len(events)} marker events, {len(ent_affect)} entities touched -> {OUT.name}")
