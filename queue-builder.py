#!/usr/bin/env python3
"""queue-builder.py — feeds the graph's growth (L1). The user's gap feeling was
right: deep sources (14K human mails, 8.5K commits) had NO path into the graph —
integration only walked the imported-notes inbox. This mines the evidence layer
for ENTITY CANDIDATES and queues them for the brain's judgment:
  mail  correspondents with >=8 human messages and no matching entity node
  git   repos with >=10 active authored days and no matching Project node
Appends idempotent CANDIDATE items to archive-cursor.md; the brain verifies each
(create a real node with evidence, or dismiss with a reason — never blind).
Runs at sleep-boot (runner) or via make v2-queue-build.
"""
import re, subprocess, os, unicodedata
from collections import defaultdict
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
CURSOR = V / "Atlas/AI/Brain/archive-cursor.md"
TL = V / "Atlas/Mind/timeline"
ENTITY_DIRS = ["Atlas/Projects", "Atlas/Organizations", "Atlas/People", "Atlas/Ideas", "Atlas/Memory/topics", "Atlas/Mind"]
AUTOMATED = re.compile(r"no.?reply|donotreply|notification|mailer|newsletter|news@|updates@|marketing@|"
                       r"bounce|digest|alerts?@|automated|bulten|kampanya|awards@|hello@|hi@|info@join|"
                       r"security@|forum@|@update\.|@dlvr\.|smartbearmail|milesandsmiles|facebookmail|"
                       r"@mp1\.|@americas\.comm|@e\.|@mail\.|@em\.", re.I)


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


# known-entity term index (names, aliases, and email addresses found in notes)
known = set()
for d in ENTITY_DIRS:
    for p in (V / d).glob("*.md"):
        if p.name == "README.md":
            continue
        t = p.read_text(encoding="utf-8", errors="replace")
        for a in {p.stem} | set(fm_aliases(t)):
            if len(a) >= 3:
                known.add(fold(a))
        for addr in re.findall(r"[\w.+-]+@[\w.-]+", t):
            known.add(fold(addr))

cursor = CURSOR.read_text(encoding="utf-8", errors="replace")
# Dedup key = ANY backticked token in the cursor — the brain rewrites dispositioned
# candidate lines in its own words (dropping the CANDIDATE marker) but keeps the
# `key` in backticks, so a marker-anchored regex re-queues everything it already
# judged. Over-matching only suppresses a queue item; re-queuing wastes a verdict.
existing_keys = set(re.findall(r"`([^`\n]+)`", cursor))

# ---- mail correspondents from the evidence layer ----
corr = defaultdict(lambda: [0, None, None, "", 0])   # addr -> [n, first, last, name, outbound]
for p in sorted(TL.glob("mail-*.md")):
    for d, arrow, name, addr in re.findall(
            r"^- (\d{4}-\d{2}-\d{2}) (->|<-) (.*?) <([^>]+)> —", p.read_text(encoding="utf-8", errors="replace"), re.M):
        c = corr[addr.lower()]
        c[0] += 1
        c[1] = min(c[1] or d, d)
        c[2] = max(c[2] or d, d)
        if name and "@" not in name:
            c[3] = name
        if arrow == "->":
            c[4] += 1

mail_cands = []
for addr, (n, first, last, name, outbound) in corr.items():
    if n < 8 or last < "2024":          # active-era relationships first
        continue
    # precision gates: a real relationship means HE WROTE to them at least once,
    # or heavy human traffic that isn't machine-shaped (netflix/dell survived v1)
    if AUTOMATED.search(addr):
        continue
    if outbound < 1 and n < 20:
        continue
    if fold(addr) in known or (name and fold(name) in known):
        continue
    if any(fold(t) in known for t in re.split(r"[\s,]+", name) if len(t) >= 4):
        continue
    mail_cands.append((n, name or addr, addr, first, last))
mail_cands.sort(reverse=True)

# ---- repos without a Project node ----
git_cands = []
try:
    repos = []
    for root, dirs, _ in os.walk(Path.home() / "Projects"):
        dirs[:] = [d for d in dirs if d not in ("node_modules", ".build", ".next", "vendor")
                   and not (d.startswith(".") and d != ".git")]
        if ".git" in dirs:
            repos.append(Path(root)); dirs.remove(".git")
    for r in repos:
        if r.resolve() == V.resolve():
            continue
        rel = str(r.relative_to(Path.home() / "Projects"))
        if any(fold(t) in known for t in [rel, r.name] + [w for w in re.split(r"[/._-]", rel) if len(w) >= 4]):
            continue
        out = subprocess.run(["git", "-C", str(r), "log", "--all", "--no-merges",
                              "--date=format:%Y-%m-%d", "--format=%ad|%an"],
                             capture_output=True, text=True, timeout=60).stdout
        days = {l.split("|")[0] for l in out.splitlines()
                if re.search(os.environ.get("SECONDMIND_AUTHOR_RE", r"(?!x)x"), l, re.I)}
        if len(days) >= 10:
            git_cands.append((len(days), rel, min(days), max(days)))
    git_cands.sort(reverse=True)
except Exception as e:
    print("git scan partial:", e)

added = []
lines = []
for n, name, addr, first, last in mail_cands[:15]:
    key = addr
    if key in existing_keys:
        continue
    lines.append(f"- [ ] CANDIDATE person/org: `{key}` — {name}, {n} human msgs, {first} → {last}"
                 f" (mail evidence; verify: real relationship → node + links, else dismiss with reason)")
    added.append(key)
for days, rel, first, last in git_cands[:10]:
    key = rel
    if key in existing_keys:
        continue
    lines.append(f"- [ ] CANDIDATE project: `{key}` — {days} active days, {first} → {last}"
                 f" (git evidence; verify: real venture/experiment → node, else dismiss)")
    added.append(key)

if lines:
    header = "\n## Entity candidates (queue-builder — the graph's growth feed; verify then create or dismiss)\n"
    if "## Entity candidates" in cursor:
        cursor = cursor.rstrip("\n") + "\n" + "\n".join(lines) + "\n"
    else:
        cursor = cursor.rstrip("\n") + "\n" + header + "\n".join(lines) + "\n"
    CURSOR.write_text(cursor, encoding="utf-8")
print(f"queue-builder: {len(added)} new candidates queued "
      f"({len(mail_cands)} mail-eligible, {len(git_cands)} git-eligible)")
for k in added[:8]:
    print("  +", k)
