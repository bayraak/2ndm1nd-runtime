#!/usr/bin/env python3
"""co-activation.py — Hebbian edge strength for the memory graph.

Real neurons wire by co-activation: "cells that fire together wire together"
(Hebb), and unused synapses are pruned. My graph's links were binary and never
weighted or pruned. This computes, for every pair of entities, how often they
CO-OCCUR across the substrate — the same day in the ledger, the same journal
entry, the same note — which is the literal Hebbian signal. Output:
  Atlas/AI/Brain/coactivation.md (graph-excluded) — the brain's edge-strength
  table: STRONG untracked pairs to make explicit links, and EXISTING links with
  near-zero co-activation to review as spurious (the vik↔Polymorph failure mode).
This is EVIDENCE (L1) — the brain decides which edges to draw/prune (L3). It
never writes links itself. Run: `make v2-coactivation`.
"""
import math, re, sqlite3, unicodedata
from collections import Counter, defaultdict
from itertools import combinations
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
DB = Path.home() / "Library/Application Support/2ndMind/brain.db"
OUT = V / "Atlas/AI/Brain/coactivation.md"
ENTITY_DIRS = ["Atlas/Projects", "Atlas/Organizations", "Atlas/People", "Atlas/Memory/topics", "Atlas/Ideas"]
BLACKLIST = {"self", "readme", "index", "moc", "story", "model", "ontology"}


def fold(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s.casefold()) if not unicodedata.combining(c))


def aliases(text):
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


# entity index: folded term (>=4 chars, word-safe) -> canonical
idx, canon = {}, {}
for d in ENTITY_DIRS:
    base = V / d
    if not base.is_dir():
        continue
    for p in sorted(base.glob("*.md")):
        if p.stem.casefold() in BLACKLIST:
            continue
        head = p.read_text(encoding="utf-8", errors="replace")[:4096]
        # alias-of: this "person" is a persona of another node (e.g. a business
        # persona that is really the user himself). Map its terms to the TARGET so
        # no phantom person-pair edges are scored (brain proposal 2026-07-19).
        m = re.search(r"^alias-of:\s*\"?(?:\[\[)?([^\]\"\n]+)", head, re.M)
        target = m.group(1).strip() if m else p.stem
        if target == p.stem:
            canon[p.stem] = p
        for t in {p.stem} | set(aliases(head)):
            ft = fold(t)
            if len(ft) >= 4 and ft not in BLACKLIST:
                idx.setdefault(ft, target)

pats = [(re.compile(rf"(?<![\w]){re.escape(t)}(?![\w])"), c) for t, c in idx.items()]


def entities_in(text):
    t = fold(text)
    return {c for pat, c in pats if pat.search(t)}


# ---- co-activation over ledger DAYS (Hebbian temporal binding) ----
# Raw co-count is dominated by base frequency (two projects you touch daily
# co-occur a lot without being RELATED). PMI corrects for that: association =
# how much MORE than chance they co-fire. PMI(a,b)=log2( P(a,b)/(P(a)P(b)) );
# >0 means above chance, and normalized PMI (npmi) ∈ [-1,1] makes it comparable.
co, present, ndays = Counter(), Counter(), 0
try:
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    byday = defaultdict(str)
    for day, txt in con.execute(
            "SELECT date(ts,'unixepoch','localtime'), COALESCE(text,'')||' '||COALESCE(app,'') "
            "FROM events WHERE text IS NOT NULL OR app IS NOT NULL"):
        byday[day] += " " + txt
    con.close()
    ndays = len(byday)
    for blob in byday.values():
        ents = entities_in(blob)
        for e in ents:
            present[e] += 1
        for a, b in combinations(sorted(ents), 2):
            co[(a, b)] += 1
except Exception as e:
    print("ledger co-activation skipped:", e)

# ---- co-mention in a shared NOTE (semantic binding — high-confidence, human/brain wrote them together) ----
note_co = Counter()
for sub in ["Atlas/AI/Brain/journal", *ENTITY_DIRS]:
    d = V / sub
    if not d.is_dir():
        continue
    for p in d.rglob("*.md"):
        ents = entities_in(p.read_text(encoding="utf-8", errors="replace"))
        for a, b in combinations(sorted(ents), 2):
            note_co[(a, b)] += 1

# ---- existing explicit links ----
linked = set()
for c, p in canon.items():
    for L in re.findall(r"\[\[([^\]|#]+)", p.read_text(encoding="utf-8", errors="replace")):
        tgt = idx.get(fold(L.strip().split("/")[-1]))
        if tgt and tgt != c:              # ignore a note referencing itself
            linked.add(tuple(sorted((c, tgt))))


def npmi(a, b):
    """Normalized PMI in [-1,1]; None if too rare to trust."""
    c = co.get((a, b), 0)
    if c < 3 or ndays == 0 or not present[a] or not present[b]:
        return None
    p_ab, p_a, p_b = c / ndays, present[a] / ndays, present[b] / ndays
    pmi = math.log2(p_ab / (p_a * p_b))
    return pmi / (-math.log2(p_ab))


# candidate real edges: high association (npmi) OR co-mentioned in a shared note, and not yet linked
cands = {}
for (a, b), c in co.items():
    if (a, b) in linked:
        continue
    s = npmi(a, b)
    if s is not None and s > 0.20:
        cands[(a, b)] = (round(s, 2), c, note_co.get((a, b), 0))
for (a, b), n in note_co.items():
    if (a, b) in linked or (a, b) in cands:
        continue
    if n >= 2:                    # discussed together in ≥2 notes
        cands[(a, b)] = (0.0, co.get((a, b), 0), n)
strong = sorted(cands.items(), key=lambda kv: (kv[1][0], kv[1][2], kv[1][1]), reverse=True)[:40]

# candidate spurious edges: linked but LOW association and never co-mentioned
weak = []
for a, b in linked:
    s = npmi(a, b)
    if (s is None or s < 0.05) and note_co.get((a, b), 0) == 0:
        weak.append((s if s is not None else 0.0, a, b, co.get((a, b), 0)))
weak = sorted(weak)[:30]

out = ["---", "title: coactivation", "type: note", "---", "",
       "# CO-ACTIVATION — Hebbian edge strength via PMI (EVIDENCE; I decide which edges to draw/prune)",
       "",
       f"Over {ndays} ledger-days + shared notes. Association = normalized PMI (co-fire ABOVE "
       f"chance, so two daily-frequent-but-unrelated ventures score LOW). {len(linked)} explicit "
       "links exist. This is L1 evidence — I draw/prune with judgment, never blindly.", "",
       "## STRONG but UNLINKED — make these explicit if the relationship is real (npmi · co-days · shared-notes)"]
out += [f"- **{a}** ↔ **{b}** — npmi {v[0]} · {v[1]}d · {v[2]}n" for (a, b), v in strong] or ["- (none)"]
out += ["", "## LINKED but WEAK — review as possibly spurious (low association, never co-mentioned)"]
out += [f"- [[{a}]] ↔ [[{b}]] — npmi {round(s,2)} · {c}d" for s, a, b, c in weak] or ["- (none)"]
OUT.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"co-activation: {len(strong)} strong-unlinked, {len(weak)} weak-linked -> {OUT.relative_to(V)}")
for (a, b), v in strong[:10]:
    print(f"  npmi {v[0]:>5}  {a} <-> {b}  ({v[1]}d, {v[2]}n)")
