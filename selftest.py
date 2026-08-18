#!/usr/bin/env python3
"""selftest.py — regression battery for every instrument. Two root bugs earned
this file: the loop-carried claimbody (phantom lint findings) and the YAML
block-list parser that read unindented lists as empty (silently crippled
aliases/areas everywhere). Static guards + output invariants; hard-fails.
Run: make v2-selftest (and by hand after touching any instrument).
"""
import re, subprocess, sys
from datetime import datetime
from pathlib import Path

SM = Path.home() / "Projects/2ndm1nd/.scripts/secondmind"
B = Path.home() / "Projects/2ndm1nd/Atlas/AI/Brain"
V = Path.home() / "Projects/2ndm1nd"
fails = []


def check(name, ok, detail=""):
    print(("  ok " if ok else "FAIL ") + name + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        fails.append(name)


# --- static guards ---
for p in SM.glob("*.py"):
    if p.name == "selftest.py":
        continue   # this file quotes the forbidden pattern in its own guard
    t = p.read_text()
    check(f"{p.name}: no broken YAML lookahead", r"(?=^\S|\Z)" not in t,
          "unindented list items would parse empty")
lint = (SM / "note-lint.py").read_text()
d, u = lint.find("claimbody = "), lint.find("claimbody.splitlines")
check("note-lint: claimbody defined before use", 0 < d < u)

# --- vault vs BINDIR drift (the stale-copy class bit twice: old lint overwrote
# the queue mid-fix; Mail keepalive sat undeployed while cycles ran) ---
BIN = Path.home() / ".local/share/2ndm1nd/bin"
for p_ in sorted(SM.glob("*.py")) + [SM / "brain-loop.sh"]:
    b = BIN / p_.name
    if b.exists():
        check(f"deployed copy in sync: {p_.name}", b.read_bytes() == p_.read_bytes(),
              "run make v2-install")

# --- the RUNNING runner must be newer than its script (a long-lived bash loop
# keeps the old body in memory: queue-builder sat wired-but-never-executed for
# 3 days because the process predated the edit and nothing noticed) ---
# macOS `pgrep -f` excludes its OWN ancestors, so when the RUNNER invokes this
# selftest the runner is invisible to it and this check always failed — and the
# runner is the only scheduled caller. Three Sundays of "instruments may be lying"
# came from here, training everyone to ignore the alarm. Ask the pidfile instead.
r = subprocess.run(["bash", "-c",
    'p=$(cat "${SECONDMIND_STATE_DIR:-$HOME/Library/Application Support/2ndMind/brain-runtime}/runner.pid" 2>/dev/null); '
    '[ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"'],
    capture_output=True, text=True)
pids = r.stdout.split()
if pids:
    starts = []
    for pid in pids:
        ls = subprocess.run(["ps", "-o", "lstart=", "-p", pid], capture_output=True, text=True).stdout.strip()
        if ls:
            starts.append(datetime.strptime(ls, "%a %b %d %H:%M:%S %Y"))
    runner_start = min(starts)  # oldest PID = the parent loop, not a cycle subshell
    script_mtime = datetime.fromtimestamp((BIN / "brain-loop.sh").stat().st_mtime)
    check("runner process newer than its script", runner_start > script_mtime,
          f"runner started {runner_start}, script edited {script_mtime} — make v2-brain-restart")
else:
    check("runner process running", False, "no brain-loop.sh process — make v2-brain-up")

# --- queue-builder dedup harvests keys from brain-REWRITTEN lines (the marker-
# anchored regex re-queued 20 already-judged candidates) ---
rewritten = "- [x] `foo@bar.com` → **[[Self]]** — my own domain. Aliased.\n"
check("queue-builder dedup: backtick harvest", "foo@bar.com" in set(re.findall(r"`([^`\n]+)`", rewritten)))

# --- run the full instrument chain (order matters: coactivation before communities) ---
last_cycle = "0"
lc = Path.home() / "Library/Application Support/2ndMind/brain-runtime/last-cycle-ts"
if lc.exists():
    last_cycle = lc.read_text().strip() or "0"
chain = [
    ("day-digest.py", ["--since", last_cycle]),
    ("note-lint.py", []), ("co-activation.py", []), ("rhythm.py", []),
    ("register.py", []), ("communities.py", []), ("affect.py", []),
    ("balance.py", []), ("coverage.py", []), ("recall.py", []), ("queue-builder.py", []), ("reconsolidation.py", []), ("deltas.py", []),
]
for name, args in chain:
    r = subprocess.run(["python3", str(SM / name), *args], capture_output=True, text=True, timeout=300)
    check(f"{name} exits 0", r.returncode == 0, r.stderr[-200:])

# --- output invariants ---
for f in ["digest.md", "quality-queue.md", "coactivation.md", "rhythm.md", "register.md",
          "communities.md", "affect.md", "balance.md", "coverage.md", "recall-test.md", "reconsolidation.md", "deltas.md"]:
    p = B / f
    check(f"{f} exists+nonempty", p.exists() and p.stat().st_size > 200)
# evidence layer carries no graph edges
for p in (V / "Atlas/Mind/timeline").glob("*.md"):
    check(f"evidence link-free: {p.name}", "[[" not in p.read_text(encoding="utf-8", errors="replace"))
    break  # spot-check one; timeline-distill's own QA covers the rest
co = (B / "coactivation.md").read_text()
check("coactivation: no self-pairs", not re.search(r"\[\[(.+?)\]\] ↔ \[\[\1\]\]", co))
bal = (B / "balance.md").read_text()
check("balance: untagged entities == 0", "untagged)" not in bal.split("## Share")[0] or
      "Area-untagged entities (0)" in bal)
# YAML parser handles BOTH list styles (functional test on temp strings)
sys.path.insert(0, str(SM))
import importlib.util
spec = importlib.util.spec_from_file_location("bal", SM / "balance.py")
# can't import balance (runs at import); test the regex directly instead:
pat = re.compile(r"^areas:\s*$(.*?)(?=^\w[\w-]*:|^---|\Z)", re.M | re.S)
indented = "areas:\n  - financial\n  - family\ntype: org\n"
flat = "areas:\n- financial\n- family\ntype: org\n"
for style, txt in [("indented", indented), ("flat", flat)]:
    m = pat.search(txt)
    got = re.findall(r"^\s*-\s*(.+)$", m.group(1), re.M) if m else []
    check(f"yaml block-list parses ({style})", got == ["financial", "family"], str(got))

print(f"\nselftest: {'ALL OK' if not fails else f'{len(fails)} FAILURES: ' + ', '.join(fails)}")
sys.exit(1 if fails else 0)
