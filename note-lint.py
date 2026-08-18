#!/usr/bin/env python3
"""note-lint.py — deterministic quality scanner for the memory graph.

"Quality is a must" needs a MECHANISM, not intentions. This lints every graph-
visible memory node against the house rules and writes a burn-down queue the
brain works through nightly (Atlas/AI/Brain/quality-queue.md), plus a dated
trend line so quality is measurable over time. Deterministic checks find;
the brain (or Claude Code) fixes. Run: `make v2-lint-notes`.

Checks:
  VOICE     bare third-person (he/him/his/the user) outside quoted text
  UNDATED   entity claim bullets with no date anchor
  STUB      node with almost no body (enrich or merge)
  ORPHAN    node with no inbound AND no outbound links
  DUPNAME   same folded name in two dirs (one entity = one note)
  BROKEN    [[link]] that resolves to nothing (alias-aware)
  STRAY     .md at vault root that isn't a known root doc
  OVERSIZE  > 250 lines (split or prune)
  MECHANISM implementation-trivia words in entity notes (fold meaning, not mechanism)
"""
import re, sys, unicodedata
from collections import defaultdict
from datetime import date
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
QUEUE = V / "Atlas/AI/Brain/quality-queue.md"
MEMORY_DIRS = ["Atlas/Projects", "Atlas/Organizations", "Atlas/People",
               "Atlas/Memory/topics", "Atlas/Ideas", "Atlas/Mind", "Atlas/Context"]
ROOT_OK = {"CLAUDE.md", "README.md"}
ENTITY_DIRS = {"Atlas/Projects", "Atlas/Organizations", "Atlas/People", "Atlas/Memory/topics"}
MECHANISM = re.compile(r"\b(font|css|px\b|padding|margin|\.tsx|\.jsx|refactor|linter|webpack|tailwind)\b", re.I)
QUOTEISH = re.compile(r'["“”*`]')          # lines carrying quote markers are exempt from VOICE
VOICE = re.compile(r"\b(he|him|his|the user)\b", re.I)
DATED = re.compile(r"\b20\d\d\b|\d{4}-\d{2}")


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


def body_of(text):
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end > 0:
            return text[end + 4:]
    return text


# ---- collect corpus ----
notes = {}          # rel -> text
resolvable = set()  # folded terms that resolve
canon_by_fold = defaultdict(list)
SKIP_TOP = {".git", ".obsidian", ".venv", ".scripts", ".claude", ".trash"}
for p in sorted(V.rglob("*.md")):
    parts = p.relative_to(V).parts
    if parts[0] in SKIP_TOP:
        continue
    rel = str(p.relative_to(V))
    # every vault note resolves links (stem, aliases, and path-suffix form)
    text_all = p.read_text(encoding="utf-8", errors="replace")
    for t in {p.stem} | set(fm_aliases(text_all)):
        resolvable.add(fold(t))
    resolvable.add(fold(rel[:-3]))            # full path w/o .md
    resolvable.add(fold("/".join(parts[-2:]))[:-3] if len(parts) > 1 else fold(p.stem))
    # but only MEMORY notes are linted
    if any(rel.startswith(d + "/") for d in MEMORY_DIRS) and "/timeline/" not in rel \
            and p.name != "README.md":
        notes[rel] = text_all
        canon_by_fold[fold(p.stem)].append(rel)

inbound = defaultdict(int)
for rel, text in notes.items():
    for link in re.findall(r"\[\[([^\]|#]+)", body_of(text)):
        inbound[fold(link.strip())] += 1

issues = defaultdict(list)   # code -> [(rel, detail)]

for name in (p.name for p in V.glob("*.md")):
    if name not in ROOT_OK:
        issues["STRAY"].append((name, "entity/junk file at vault root"))

for f, rels in canon_by_fold.items():
    if len(rels) > 1:
        issues["DUPNAME"].append((rels[0], f"same name in: {', '.join(rels)}"))

for rel, text in notes.items():
    body = body_of(text)
    # strip forward-looking sections (watch/questions/done-means) before claim
    # checks — intentions aren't citable claims. MUST be computed per-note HERE:
    # it was once defined lower in the loop and a later check consumed the
    # PREVIOUS note's claimbody (phantom UNDATED findings, caught 2026-07-18).
    claimbody = re.sub(r"^## .*(watching|Open questions|Done means).*\n.*?(?=^## |\Z)", "",
                       body, flags=re.M | re.S | re.I)
    lines = [l for l in body.splitlines() if l.strip()]
    stem = Path(rel).stem
    is_entity = any(rel.startswith(d + "/") for d in ENTITY_DIRS)
    if not re.search(r"^type:\s*\S", text[:400], re.M):
        issues["UNTYPED"].append((rel, "missing type: frontmatter"))
    if (rel.startswith("Atlas/Projects/") or rel.startswith("Atlas/Ideas/")) \
            and not re.search(r"^areas:", text[:800], re.M):
        issues["AREAS"].append((rel, "no areas: tag (his 13-area canon; balance.md needs it)"))
    if len(lines) < 6 and "Mind/skills" not in rel and "proposals" not in rel:
        issues["STUB"].append((rel, f"{len(lines)} body lines — enrich or merge"))
    if len(lines) > 250:
        issues["OVERSIZE"].append((rel, f"{len(lines)} lines — split or prune"))
    if "[[" not in body and inbound[fold(stem)] == 0 and is_entity:
        issues["ORPHAN"].append((rel, "no inbound or outbound links"))
    seen_broken = set()
    for link in re.findall(r"\[\[([^\]|#]+)", body):
        l = link.strip()
        f_l = fold(l)
        tail = fold(l.split("/")[-1])
        if f_l in resolvable or tail in resolvable or (V / f"{l}.md").exists():
            continue
        if "\n" in link:
            detail = f"LINE-WRAPPED link [[{' '.join(l.split())}]] (won't render)"
        else:
            detail = f"[[{l}]] resolves to nothing"
        if detail not in seen_broken:
            seen_broken.add(detail)
            issues["BROKEN"].append((rel, detail))
    # TEMPLATE residue: a note is what the mind KNOWS, never a form.
    fm_empty = re.findall(r'^(\w[\w-]*):\s*""\s*$', text[:800], re.M)
    if fm_empty:
        issues["TEMPLATE"].append((rel, f"empty frontmatter field(s): {', '.join(fm_empty)}"))
    if is_entity:
        boxes = len(re.findall(r"^- \[ \]", body, re.M))
        if boxes:
            issues["TEMPLATE"].append((rel, f"{boxes} task checkbox(es) — entities hold watch-threads, not to-dos"))
        for bad in ("## Conversations to have", "## Open tasks", "## Definition of done",
                    "## Last contact log\n\n#"):
            if bad.replace("\\n", "\n") in body:
                issues["TEMPLATE"].append((rel, f"form section: {bad[:40]}"))
    if is_entity:
        vhits = [l.strip()[:80] for l in body.splitlines()
                 if VOICE.search(l) and not QUOTEISH.search(l)]
        if vhits:
            issues["VOICE"].append((rel, f"{len(vhits)} bare-3rd-person line(s), e.g. “{vhits[0]}”"))
        undated = [l.strip()[:60] for l in claimbody.splitlines()
                   if re.match(r"^- \S", l) and not DATED.search(l) and "[[" not in l[:20]
                   and not l.strip().startswith("- [ ]")]
        if len(undated) >= 3:
            issues["UNDATED"].append((rel, f"{len(undated)} undated claim bullets"))
    # EPISTEMIC RULE: claims/narrative (entities, MODEL, STORY) must be traceable —
    # a claim line with neither a date, a quote, a [[link]], nor a source marker
    # is unsourced and subject to deletion. Machines produce evidence; the brain
    # produces CITED claims; nothing else belongs at that layer.
    if is_entity or rel.endswith("Mind/MODEL.md") or rel.endswith("Mind/STORY.md"):
        SOURCEY = re.compile(r"20\d\d|\[\[|[\"\u201c\u201d*`]|\((mail|git|ledger|calendar|journal|evernote|icloud|@)")
        unsourced = [l.strip()[:70] for l in claimbody.splitlines()
                     if re.match(r"^- \w", l) and len(l.strip()) > 45
                     and not SOURCEY.search(l)]
        if unsourced:
            issues["UNSOURCED"].append((rel, f"{len(unsourced)} uncited claim(s), e.g. \u201c{unsourced[0]}\u201d"))
        mech = [l.strip()[:70] for l in body.splitlines()
                if MECHANISM.search(l) and not QUOTEISH.search(l)]
        if mech:
            issues["MECHANISM"].append((rel, f"e.g. “{mech[0]}”"))

# ---- write queue + trend ----
total = sum(len(v) for v in issues.values())
order = ["STRAY", "DUPNAME", "TEMPLATE", "BROKEN", "UNSOURCED", "VOICE", "MECHANISM", "ORPHAN", "STUB",
         "UNDATED", "UNTYPED", "AREAS", "OVERSIZE"]
out = ["---", "title: quality-queue", "type: note", "---", "",
       "# QUALITY QUEUE — deterministic lint findings (I burn ≥5 down nightly)",
       "",
       f"Generated by `note-lint.py`. {total} open issues. Fix = edit the note "
       "properly (not cosmetically), then re-run `make v2-lint-notes` — fixed items "
       "disappear; the trend log below is the quality scoreboard.", ""]
for code in order:
    if not issues.get(code):
        continue
    out.append(f"## {code} ({len(issues[code])})")
    for rel, detail in issues[code][:40]:
        out.append(f"- [ ] `{rel}` — {detail}")
    out.append("")
trend = ""
if QUEUE.exists():
    m = re.search(r"## Trend\n(.*)$", QUEUE.read_text(), re.S)
    if m:
        trend = m.group(1).strip() + "\n"
counts = " ".join(f"{c}:{len(issues[c])}" for c in order if issues.get(c))
out += ["## Trend", trend + f"- {date.today().isoformat()} :: {total} issues ({counts})"]
QUEUE.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"note-lint: {total} issues -> {QUEUE.relative_to(V)}")
for c in order:
    if issues.get(c):
        print(f"  {c:9} {len(issues[c])}")
sys.exit(0)
