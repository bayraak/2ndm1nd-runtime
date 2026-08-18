#!/usr/bin/env python3
"""graph-audit.py — enforce the node taxonomy of a proper brain graph.

A graph node must be a CONCEPT THE MIND HOLDS: a person, organization, venture,
idea, topic, era, or a piece of his authored intellectual content. Anything that
is machinery (the brain's organs / cortex digests / logs / dashboards), a periodic
bucket (files keyed by date/week/quarter — time is an attribute of eras & episodes,
never a node), navigation (MOCs, INDEX, READMEs), or a template is NOT a concept:
it stays as a file but is EXCLUDED from the graph view.

This script is the single source of truth for that boundary: it (1) generates the
Obsidian graph filter into .obsidian/graph.json, and (2) audits every note, hard-
failing if any excluded-class file would still be graph-visible or any periodic/
organ node slipped into the memory set. Run: `make v2-graph-audit`.
"""
import json, re, sys
from collections import Counter, defaultdict
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
SKIP_TOP = {".git", ".obsidian", ".venv", ".scripts", ".claude", ".trash", "Assets"}

# --- the boundary (single source of truth) ---
EXCLUDE_PATHS = [           # whole subtrees that are machinery / buckets / nav / raw inbox
    "Atlas/AI",             # brain organs (WEEKLY/HANDOFF/SELF/LEARNINGS/journals…) + cortex digests + logs
    "Atlas/Mind/timeline",  # cold evidence (already)
    "Atlas/MOCs",           # navigation indexes
    "Calendar",             # periodic daily/weekly notes
    "Templates",            # scaffolds
    # RAW INBOX — imported source, NOT curated memory. The brain triages these into
    # real, properly-named nodes over the drip; until then they must not masquerade
    # as concepts (a note titled "Plan-" / ";" is unprocessed source).
    "Archive/iCloud-Notes",
    "Archive/Evernote",
    "Archive/Research",
    "Archive/jarvis-v1",
    "+Inbox",
    # WORKING-MEMORY / SCAFFOLDING layer (like prefrontal current-goals, not
    # semantic memory): project PLAN/STATUS/BACKLOG/OKR/SHIPPED docs + the brain's
    # own proposals. A brain doesn't hold "the status document" as a peer concept
    # next to a person — durable meaning is distilled into Projects/MODEL instead.
    "Efforts",
    "Atlas/Mind/proposals",
]
EXCLUDE_FILES = [           # specific machinery/nav files elsewhere
    "Atlas/INDEX.md", "Atlas/Dashboard.md", "Atlas/Mind/ONTOLOGY.md", "Atlas/Memory/MOC.md",
]
EXCLUDE_STEMS = {"README"}  # any README anywhere
# Names that must NEVER appear as a memory node (organ files); a safety net.
ORGAN_STEMS = {"WEEKLY", "HANDOFF", "SELF", "LEARNINGS", "HEALTH", "TICKLER",
               "PREDICTIONS", "Now", "Trigger", "ONTOLOGY", "INDEX", "Dashboard",
               "extractor-log", "curator-log", "weeklyreflect-log", "mail-cursor",
               "archive-cursor", "NEXT"}
# Date-STAMPED buckets only (YYYY-MM-DD / YYYY-Www / YYYY-Qn). NOT a bare 4-digit —
# an iCloud note titled "4075" is real content, not a periodic bucket.
PERIODIC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$|^\d{4}-W\d{2}$|^\d{4}-Q\d$")


def excluded(rel: str, stem: str):
    for pre in EXCLUDE_PATHS:
        if rel == pre or rel.startswith(pre + "/"):
            return "machinery/bucket/nav subtree"
    if rel in EXCLUDE_FILES:
        return "machinery/nav file"
    if stem in EXCLUDE_STEMS:
        return "README (nav)"
    return None


def graph_filter():
    terms = [f'-path:"{p}"' for p in EXCLUDE_PATHS + EXCLUDE_FILES] + ['-path:"README"']
    return " ".join(terms)


# FUNCTIONAL CLUSTERS — the brain's modules, made visible (like naming the
# default-mode / salience networks). Obsidian colours nodes by folder+type; these
# groups colour by CLUSTER so the force layout's communities are legible. Path-
# based so they're stable without editing notes. Order matters: first match wins.
# These queries are vault-specific: name your own ventures/clients/projects here.
# The shipped defaults are placeholders — edit them to match your vault's entities.
CLUSTERS = [
    ("venture-a", "#e0803a",     # e.g. a business venture and the people/orgs around it
     'path:"Atlas/Organizations" OR file:"Example Venture"'),
    ("client-work", "#c0504d",   # e.g. contract engineering clients
     'file:"Example Client"'),
    ("meta-tools", "#8064a2",    # the agent-loop toolchain
     'file:2ndm1nd'),
    ("self-personal", "#4f81bd", # the identity core (character)
     'path:"Atlas/Personal" OR file:Self OR file:MODEL OR file:STORY OR path:"Atlas/Context"'),
    ("ideas", "#9bbb59",         # the idea archive
     'path:"Atlas/Ideas"'),
]


def write_graph_json():
    p = V / ".obsidian/graph.json"
    d = json.loads(p.read_text()) if p.exists() else {}
    d["search"] = graph_filter()
    d["colorGroups"] = [{"query": q, "color": {"a": 1, "rgb": int(c[1:], 16)}}
                        for _name, c, q in CLUSTERS]
    d.setdefault("showOrphans", True)
    d.setdefault("showTags", False)
    d["showArrow"] = True
    p.write_text(json.dumps(d, indent=2))


def main():
    visible, excluded_ct = defaultdict(list), Counter()
    fails = []
    for f in V.rglob("*.md"):
        parts = f.relative_to(V).parts
        if parts[0] in SKIP_TOP:
            continue
        rel = "/".join(parts)
        reason = excluded(rel, f.stem)
        if reason:
            excluded_ct[reason] += 1
            continue
        # this file IS graph-visible — it must be a real concept
        m = re.search(r"^type:\s*(.+)$", f.read_text(encoding="utf-8", errors="replace")[:400], re.M)
        t = (m.group(1).strip() if m else "note")
        visible[t].append(rel)
        if PERIODIC_RE.match(f.stem):
            fails.append(f"periodic node visible: {rel}")
        if f.stem in ORGAN_STEMS:
            fails.append(f"organ node visible: {rel}")
        if t in ("timeline-evidence", "activity-spans", "daily", "moc", "dashboard", "index"):
            fails.append(f"machinery type '{t}' visible: {rel}")

    write_graph_json()
    total_vis = sum(len(v) for v in visible.values())
    print(f"GRAPH FILTER: {graph_filter()}\n")
    print(f"VISIBLE memory nodes: {total_vis}")
    for t, files in sorted(visible.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(files):4}  {t}")
    print(f"\nEXCLUDED from graph (kept as files):")
    for r, n in excluded_ct.most_common():
        print(f"  {n:4}  {r}")
    if fails:
        print("\nQA FAIL:")
        for x in fails[:20]:
            print("  ✗", x)
        sys.exit(1)
    print("\nQA OK: every graph-visible node is a concept; no periodic/organ/machinery leaked in.")


if __name__ == "__main__":
    main()
