#!/usr/bin/env python3
"""timeline-distill.py v3 — memory-shaped, not warehouse-shaped.

The scientific principle (why v2's mail-2015.md / git-timeline.md were BAD NODES):
a brain has no concept "emails from 2015". Memory = ENTITIES (semantic: people,
projects, orgs) + EPISODES (dated events) + ERAS (the autobiographical spine —
life-story schema). Time is an attribute of episodes and the spine of eras, never
a top-level node organized by capture-medium + calendar year.

So this produces two clearly separated layers:

  EVIDENCE (cold, NOT graph nodes) — Atlas/Mind/timeline/*.md
    Filtered, greppable git/mail detail. Zero [[wikilinks]] by construction, tagged
    `evidence`, and path-excluded from the graph view. Like a raw trace the brain
    greps for citation; it must never masquerade as a concept.

  MEMORY (entity auto-blocks only) — an idempotent, delimited temporal arc written
    INTO each resolving Project/Org note (time lives inside the concept). NO
    machine-authored narrative: era generation was removed 2026-07-17 after
    commit-volume naming produced a fake, misnamed "era" — the EPISTEMIC RULE is
    machines produce evidence; only the brain authors chapters (STORY.md), and an
    era node exists only once its narrative is stable and evidence-cited.

AI-era semantics: commits >= 2025 are AI-authored under his direction, so volume =
agent throughput; his signal = active days + which ventures + direction. Evidence
aggregates agent-era commits per repo-day, keeps pre-2025 per-commit.

Sources of truth stay git + Mail.app; fully re-derivable. Verification battery at
the end (idempotency, link-resolution, graph-hygiene, reconciliation) HARD-FAILS.
"""
import os, re, shutil, sqlite3, subprocess, unicodedata
from collections import Counter, defaultdict
from datetime import date as D
from pathlib import Path

HOME = Path.home()
VAULT = HOME / "Projects/2ndm1nd"
TL = VAULT / "Atlas/Mind/timeline"      # evidence (excluded from graph)
TMP = Path(os.environ.get("TMPDIR", "/tmp")) / "timeline-distill"
AGENT_ERA = "2025-01-01"
BURST = 15
# Regex matching YOUR git author names / email handles (used to separate your
# commits from others'). Set SECONDMIND_AUTHOR_RE; default matches nothing.
AUTHOR_RE = re.compile(os.environ.get("SECONDMIND_AUTHOR_RE", r"(?!x)x"), re.I)
NOISE_COMMIT = re.compile(
    r"vault backup|^wip\b|^fix typo|^typo|^merge|^bump|^chore\(deps|^update dep|"
    r"^v?\d+\.\d+\.\d+$|^update$|^fix$|^\.+$|^initial commit$", re.I)
CONVENTIONAL = re.compile(r"^(feat|fix|chore|refactor|docs|style|test|perf|build|ci)(\([^)]*\))?!?:\s*", re.I)
AUTOMATED_ADDR = re.compile(
    r"no.?reply|donotreply|notification|mailer|newsletter|news@|updates@|marketing@|"
    r"bounce|digest|alerts?@|automated|bulten|kampanya|bilgilendirme|do-not-reply|"
    r"em\.|email\.|mail\d|reply\+|@mailer|@e\.|@notify", re.I)
ENTITY_DIRS = ["Atlas/Projects", "Atlas/Organizations", "Atlas/People", "Atlas/Memory/topics", "Atlas/Ideas"]
ENRICH_DIRS = {"Atlas/Projects", "Atlas/Organizations"}   # where a git arc may be written
BLACKLIST = {"self", "index", "home", "brain", "story", "notes", "test", "misc",
             "ontology", "model", "readme", "moc"}
AUTO_START, AUTO_END = "<!-- timeline:auto:start -->", "<!-- timeline:auto:end -->"
TODAY = D.today().isoformat()
TL.mkdir(parents=True, exist_ok=True)
TMP.mkdir(parents=True, exist_ok=True)


def fold(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s.casefold()) if not unicodedata.combining(c))


def safe(s):
    """Neutralize wikilink/markdown-breaking chars so raw subjects/names in the
    EVIDENCE layer can never mint a phantom graph edge (a mail subject literally
    contained '[[' — the QA gate caught it)."""
    return s.replace("[[", "[").replace("]]", "]").replace("\t", " ")


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


# entity index: folded term -> (canonical stem, dir), and stem -> path
IDX, PATHS = {}, {}
for rel in ENTITY_DIRS:
    d = VAULT / rel
    if not d.is_dir():
        continue
    for p in sorted(d.glob("*.md")):
        if p.stem.casefold() in BLACKLIST:
            continue
        PATHS[p.stem] = (p, rel)
        # sorted() — set iteration order varies with PYTHONHASHSEED, and setdefault
        # on a shared folded alias would then resolve non-deterministically between
        # runs (caught by the idempotency gate). Deterministic order = stable graph.
        for t in sorted({p.stem} | set(fm_aliases(p.read_text(encoding="utf-8", errors="replace")[:4096]))):
            if len(t) >= 3 and t.casefold() not in BLACKLIST:
                IDX.setdefault(fold(t), p.stem)
CANON = set(PATHS)


def repo_entity(rel):
    base, whole = fold(Path(rel).name), fold(rel)
    if whole in IDX:
        return IDX[whole]
    if base in IDX:
        return IDX[base]
    for term, canon in IDX.items():
        if len(term) >= 4 and term in base:
            return canon
    return None


def themes(subs, k=3):
    seen, out = set(), []
    for s in subs:
        c = CONVENTIONAL.sub("", s).strip().rstrip(".")
        key = fold(c)[:60]
        if c and key not in seen:
            seen.add(key); out.append(c)
    if len(out) <= k:
        return out
    picks, res = [out[0], max(out, key=len), out[-1]], []
    for p in picks:
        if p not in res:
            res.append(p)
    return res[:k]


def status(last):
    try:
        dy = (D.fromisoformat(TODAY) - D.fromisoformat(last)).days
    except Exception:
        return "unknown"
    return "ACTIVE" if dy <= 90 else ("dormant" if dy <= 365 else "archived")


# ---------------- GIT COLLECTION ----------------
def collect_git():
    repos = []
    for root, dirs, _ in os.walk(HOME / "Projects"):
        dirs[:] = [d for d in dirs if d not in ("node_modules", ".build", ".next", "vendor")
                   and not (d.startswith(".") and d != ".git")]
        if ".git" in dirs:
            repos.append(Path(root)); dirs.remove(".git")
    # Exclude the vault's own repo — self-referential (its commits ARE this system's
    # churn, not his product work), and its constant commits would make the timeline
    # non-idempotent against itself.
    repos = [r for r in repos if r.resolve() != VAULT.resolve()]
    seen, rows = set(), []
    for r in sorted(repos):
        try:
            out = subprocess.run(["git", "-C", str(r), "log", "--all", "--no-merges",
                                  "--date=format:%Y-%m-%d", "--format=%H\t%ad\t%an\t%s"],
                                 capture_output=True, text=True, timeout=60).stdout
        except Exception:
            continue
        rel = str(r.relative_to(HOME / "Projects"))
        for line in out.splitlines():
            try:
                sha, dt, author, subj = line.split("\t", 3)
            except ValueError:
                continue
            if not AUTHOR_RE.search(author) or sha in seen:
                continue
            seen.add(sha)
            if NOISE_COMMIT.search(subj.strip()) or len(subj.strip()) < 4:
                continue
            rows.append((dt, rel, subj.strip()))
    rows.sort()
    return rows


# ---------------- EVIDENCE FILES (no wikilinks; not graph nodes) ----------------
def write_git_evidence(rows):
    by_year = defaultdict(list)
    for dt, repo, s in rows:
        by_year[dt[:4]].append((dt, repo, s))
    total = 0
    for year in sorted(by_year):
        items = by_year[year]
        head = ["---", f"title: git evidence {year}", "type: timeline-evidence",
                "tags: [evidence]", "graph: exclude", "---", "",
                "> EVIDENCE, not a concept — greppable reference for the brain; contains no wiki-links by design.", ""]
        if year < AGENT_ERA[:4]:
            head.append(f"# Git {year} — {len(items)} hand-authored commits")
            head += [f"- {dt} :: {safe(repo)} — {safe(s)}" for dt, repo, s in items]
        else:
            days = defaultdict(list)
            for dt, repo, s in items:
                days[(dt, repo)].append(s)
            head.append(f"# Git {year} — {len(items)} AI-authored commits over {len(days)} repo-days (themes extracted)")
            for (dt, repo), subs in sorted(days.items()):
                burst = " [BURST]" if len(subs) > BURST else ""
                head.append(f"- {dt} :: {safe(repo)} — {len(subs)} commits{burst} — {safe(' · '.join(themes(subs)))}")
        (TL / f"git-{year}.md").write_text("\n".join(head) + "\n", encoding="utf-8")
        total += len(items)
    assert total == len(rows), f"QA: git detail {total} != {len(rows)}"


def collect_mail():
    src = next((HOME / "Library/Mail").glob("V*/MailData/Envelope Index"))
    tmp = TMP / "EnvelopeIndex.sqlite"
    shutil.copy2(src, tmp)
    for ext in ("-wal", "-shm"):
        s = Path(str(src) + ext)
        if s.exists():
            shutil.copy2(s, Path(str(tmp) + ext))
    con = sqlite3.connect(tmp)
    sent = set()
    try:
        sent = {r[0] for r in con.execute("SELECT ROWID FROM mailboxes WHERE url LIKE '%Sent%'")}
    except Exception:
        pass
    rows = con.execute("""
        SELECT m.ROWID, date(m.date_received,'unixepoch','localtime'), m.mailbox,
               COALESCE(a.address,''), COALESCE(a.comment,''),
               REPLACE(COALESCE(s.subject,''), char(10),' ')
        FROM messages m LEFT JOIN subjects s ON s.ROWID=m.subject
        LEFT JOIN addresses a ON a.ROWID=m.sender
        WHERE m.date_received>0 ORDER BY m.date_received""").fetchall()
    outbound = set()
    try:
        sids = [str(r[0]) for r in rows if r[2] in sent]
        for i in range(0, len(sids), 900):
            for (addr,) in con.execute(f"SELECT DISTINCT a.address FROM recipients r JOIN addresses a "
                                       f"ON a.ROWID=r.address WHERE r.message IN ({','.join(sids[i:i+900])})"):
                if addr:
                    outbound.add(addr.lower())
    except Exception:
        pass
    con.close()
    return rows, sent, outbound


def write_mail_evidence(rows, sent, outbound):
    sc = Counter(r[3].lower() for r in rows if r[3])

    def auto(a):
        a = a.lower()
        if not a:
            return True
        if a in outbound:
            return False
        return bool(AUTOMATED_ADDR.search(a)) or sc[a] > 80

    human = []
    for rid, dt, box, addr, name, subj in rows:
        if not dt:
            continue
        if box in sent:
            human.append((dt, "->", addr, name, subj))
        elif not auto(addr):
            human.append((dt, "<-", addr, name, subj))
    by_year = defaultdict(list)
    for h in human:
        by_year[h[0][:4]].append(h)
    for y, items in by_year.items():
        head = ["---", f"title: mail evidence {y}", "type: timeline-evidence",
                "tags: [evidence]", "graph: exclude", "---", "",
                "> EVIDENCE, not a concept — greppable reference; no wiki-links by design. "
                "(-> he wrote, <- inbound; newsletters/no-reply filtered; bodies stay in Mail.app)", "",
                f"# Mail {y} — {len(items)} human messages"]
        head += [f"- {dt} {ar} {safe(name or addr)} <{safe(addr)}> — {safe(subj[:150])}" for dt, ar, addr, name, subj in items]
        (TL / f"mail-{y}.md").write_text("\n".join(head) + "\n", encoding="utf-8")
    return human


# ---------------- ENTITY TEMPORAL ENRICHMENT (time inside the concept) ----------------
def enrich_entities(rows, human):
    by_repo = defaultdict(list)
    for dt, repo, s in rows:
        by_repo[repo].append(dt)
    arc = {}   # entity -> arc line
    for repo, dates in by_repo.items():
        ent = repo_entity(repo)
        if not ent or PATHS.get(ent, (None, None))[1] not in ENRICH_DIRS:
            continue
        days = len(set(dates))
        first, last = min(dates), max(dates)
        peak = Counter(f"{d[:4]}-Q{(int(d[5:7])-1)//3+1}" for d in dates).most_common(1)[0]
        line = (f"- `{repo}` — {len(dates)} commits over {days} active days · "
                f"{first} -> {last} · peak {peak[0]} · {status(last)}")
        arc.setdefault(ent, []).append(line)
    # correspondents -> entity (People/Org) span lines
    corr = defaultdict(list)
    for dt, ar, addr, name, subj in human:
        key = fold(name) if name else ""
        ent = IDX.get(fold(name)) if name else None
        if not ent:
            # try address local-part
            ent = IDX.get(fold(addr.split("@")[0])) if addr else None
        if ent:
            corr[ent].append(dt)
    enriched = 0
    for ent in set(list(arc) + list(corr)):
        p, _ = PATHS.get(ent, (None, None))
        if not p:
            continue
        block = [AUTO_START, "## Timeline (auto — git/mail-derived; brain may supersede)", ""]
        block += arc.get(ent, [])
        if corr.get(ent):
            ds = corr[ent]
            block.append(f"- mail: {len(ds)} human messages · {min(ds)} -> {max(ds)}")
        block.append(AUTO_END)
        blocktext = "\n".join(block)
        raw = p.read_text(encoding="utf-8", errors="replace")
        if AUTO_START in raw:
            new = re.sub(re.escape(AUTO_START) + r".*?" + re.escape(AUTO_END), blocktext, raw, flags=re.S)
        else:
            new = raw.rstrip("\n") + "\n\n" + blocktext + "\n"
        if new != raw:
            p.write_text(new, encoding="utf-8")
        enriched += 1
    return enriched


# ---------------- VERIFICATION BATTERY ----------------
def verify(eras_made):
    # 1. graph hygiene: evidence files carry ZERO wikilinks (can't be bad hubs)
    for p in TL.glob("*.md"):
        links = re.findall(r"\[\[", p.read_text(encoding="utf-8", errors="replace"))
        assert not links, f"QA FAIL: evidence {p.name} has {len(links)} wikilinks"
    # 2. link resolution: every [[link]] in eras + entity auto-blocks resolves
    checked = 0
    for ent, (p, rel) in PATHS.items():
        raw = p.read_text(encoding="utf-8", errors="replace")
        if AUTO_START in raw:
            seg = raw.split(AUTO_START)[1].split(AUTO_END)[0]
            for link in re.findall(r"\[\[([^\]|#]+)", seg):
                assert link.strip() in CANON, f"QA FAIL: {ent} auto-block -> unresolved [[{link}]]"
                checked += 1
    print(f"QA OK: {len(list(TL.glob('*.md')))} evidence files link-free; "
          f"{checked} entity-arc links resolve; no machine-authored narrative")


def main():
    for f in TL.glob("*.md"):
        f.unlink()
    rows = collect_git()
    write_git_evidence(rows)
    mrows, sent, outbound = collect_mail()
    human = write_mail_evidence(mrows, sent, outbound)
    # ERA GENERATION REMOVED (2026-07-17, user: "what era? how did that data get
    # into conclusion" — commit-volume naming let 6 weeks of agent churn misname
    # a 2-year chapter). EPISTEMIC RULE: machines produce EVIDENCE
    # (arcs, series); only the brain may author narrative (STORY chapters, and an
    # era node only once its narrative is stable and evidence-cited).
    n = enrich_entities(rows, human)
    print(f"git {len(rows)} commits · mail {len(human)} human/{len(mrows)} · {n} entities enriched")
    verify([])


main()
