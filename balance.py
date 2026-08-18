#!/usr/bin/env python3
"""balance.py — life-area balance (L1 evidence). This operationalizes HIS OWN
classification canon — the 13 Core Areas of Personal Growth (Atlas/Context/*.md
are the area definitions) and the founding "All human activities hypothesis":
every activity belongs to life areas, and the interesting question is the SHARE.
Method: ledger activity events (30d) -> entity match (alias, word-boundary) ->
the entity's `areas:` frontmatter -> area shares. Honest accounting: unmatched
activity and area-untagged entities are REPORTED, never guessed.
-> Atlas/AI/Brain/balance.md   (the brain tags missing `areas:` at night)
"""
import re, sqlite3, unicodedata
from collections import Counter, defaultdict
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
DB = Path.home() / "Library/Application Support/2ndMind/brain.db"
OUT = V / "Atlas/AI/Brain/balance.md"
DAYS = 30

AREAS = sorted(p.stem for p in (V / "Atlas/Context").glob("*.md") if p.stem != "README")


def fold(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s.casefold())
                   if not unicodedata.combining(c))


def fm_list(text, key):
    m = re.search(rf"^{key}:\s*\[(.*?)\]\s*$", text[:800], re.M)
    if m:
        return [a.strip().strip("'\"") for a in m.group(1).split(",") if a.strip()]
    m = re.search(rf"^{key}:\s*$(.*?)(?=^\w[\w-]*:|^---|\Z)", text[:800], re.M | re.S)
    if m:
        return [x.group(1).strip().strip("'\"") for x in re.finditer(r"^\s*-\s*(.+)$", m.group(1), re.M)]
    return []


ent_areas, idx = {}, {}
untagged = []
for d in ["Atlas/Projects", "Atlas/Organizations", "Atlas/People", "Atlas/Ideas"]:
    for p in (V / d).glob("*.md"):
        if p.name == "README.md":
            continue
        t = p.read_text(encoding="utf-8", errors="replace")
        areas = [a.casefold() for a in fm_list(t, "areas")]
        ent_areas[p.stem] = areas
        if not areas and d in ("Atlas/Projects", "Atlas/Ideas"):
            untagged.append(f"{d}/{p.stem}")
        for a in {p.stem} | set(fm_list(t, "aliases")):
            if len(a) >= 4:
                idx.setdefault(fold(a), p.stem)
pats = [(re.compile(rf"(?<!\w){re.escape(k)}(?!\w)"), v) for k, v in idx.items()]

con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
rows = con.execute(
    "SELECT COALESCE(text,'') || ' ' || COALESCE(app,''), source FROM events"
    " WHERE source IN ('input','focus','git','browser','shell-history')"
    "   AND ts > strftime('%s','now') - ? * 86400", (DAYS,)).fetchall()
con.close()

area_units, ent_units = Counter(), Counter()
matched = unmatched = 0
for blob, src in rows:
    f = fold(blob)
    hit = None
    for pat, ent in pats:
        if pat.search(f):
            hit = ent
            break
    if hit:
        matched += 1
        ent_units[hit] += 1
        for a in (ent_areas.get(hit) or ["(area-untagged)"]):
            area_units[a] += 1
    else:
        unmatched += 1

total = matched + unmatched or 1
body = ["---", "title: balance", "type: note", "---", "",
        f"# BALANCE — activity share across YOUR 13 areas (L1; {DAYS}d, {total} activity units; "
        f"entity-matched {100*matched//total}%, unmatched {100*unmatched//total}% reported honestly)",
        "",
        f"Canon: your `Atlas/Context/` areas ({len(AREAS)}): {', '.join(AREAS)}", "",
        "## Share of matched activity by life area"]
msum = sum(area_units.values()) or 1
for a, n in area_units.most_common():
    bar = "█" * max(1, round(24 * n / msum))
    body.append(f"- **{a}** {bar} {100*n//msum}%")
body += ["", "## Top entities by activity units"]
for e, n in ent_units.most_common(12):
    ars = ", ".join(ent_areas.get(e) or ["—"])
    body.append(f"- **{e}** — {n} units · areas: {ars}")
body += ["", f"## Area-untagged entities ({len(untagged)}) — I tag these at night (his 13-area canon)"]
body += [f"- {u}" for u in untagged[:20]]
OUT.write_text("\n".join(body) + "\n", encoding="utf-8")
print(f"balance: matched {100*matched//total}% of {total} units; "
      f"top areas: {', '.join(f'{a}:{100*n//msum}%' for a, n in area_units.most_common(4))}; "
      f"untagged entities: {len(untagged)}")
