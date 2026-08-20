#!/usr/bin/env python3
"""Consolidation evals — deterministic checks over the brain's own output.

The system rewrites its own memory daily but nothing measures whether that
rewriting is any good (ROADMAP item 2: "self-evolving, not self-measuring").
This harness is the deterministic half of that item: each check reads what the
brain actually wrote (the vault) against what capture actually recorded (the
ledger) and emits pass/fail plus a measured value. No LLM, no network, stdlib
only.

Usage:
    python3 evals/run.py --vault <vault-root> --ledger <path/to/brain.db> [--json]

The vault root is the directory that contains the brain's memory files
(HANDOFF.md, LEARNINGS.md, journal/). It may be nested anywhere below the
given path; pass --brain-dir to skip auto-detection.

Exit code 0 when every check passes, 1 otherwise.
"""

import argparse
import datetime as dt
import json
import os
import re
import sqlite3
import sys

# ---------------------------------------------------------------------------
# Thresholds. Grounded in how the runner actually behaves: one SLEEP per day
# plus WAKE cycles roughly hourly, so a healthy handoff should never trail the
# ledger by more than a day and a half even across a missed night.
# ---------------------------------------------------------------------------
STALENESS_MAX_HOURS = 36.0
COVERAGE_WINDOW_DAYS = 14
COVERAGE_MIN_EVENTS = 5      # a day with fewer captured events than this is not
                             # "a day the brain owed a consolidation"
COVERAGE_PASS_FRACTION = 0.9
GLANCE_MAX_LINES = 5         # the constitution's own limit for the GLANCE
CONSOLIDATION_LOOKAHEAD_DAYS = 3  # a day may be consolidated up to N days late
FUTURE_SLACK_SECS = 300

# The handoff sections the constitution mandates (PROMPT.md, step 7 "LETTER"):
# first `## GLANCE`, then: what happened, what I believe (falsifiable, dated),
# RIPENING, open questions, predictions. Matched by keyword so emoji and
# phrasing may drift without breaking the check.
REQUIRED_SECTIONS = [
    ("glance", ["glance"]),
    ("what-happened", ["happened"]),
    ("beliefs", ["believe"]),
    ("ripening", ["ripening"]),
    ("open-questions", ["open question"]),
    ("predictions", ["prediction"]),
]

# Secret shapes from the ROADMAP's secret-scrubbing item: common token shapes,
# `export KEY=`, `Authorization:` headers.
SECRET_PATTERNS = [
    ("api-token", re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_\-]{16,}")),
    ("aws-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9\-]{10,}\b")),
    ("auth-header", re.compile(r"Authorization:\s*(?:Bearer|Basic)\s+\S+", re.I)),
    ("export-secret", re.compile(
        r"export\s+[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*\s*=\s*\S+")),
    ("assigned-secret", re.compile(
        r"(?:api[_-]?key|secret|token|password)\s*[:=]\s*['\"]?[A-Za-z0-9_\-]{16,}",
        re.I)),
    ("long-hex", re.compile(r"\b[0-9a-f]{40,}\b")),
]
EMAIL_RE = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
# Booking/invoice/account-shaped: an unbroken run of 8+ digits.
DIGIT_RUN_RE = re.compile(r"(?<!\d)\d{8,}(?!\d)")

WAKE_RE = re.compile(r"WAKE\s+(\d{2})-(\d{2})\s+(\d{2}):(\d{2})")
WRITTEN_RE = re.compile(r"written\s+(\d{4})-(\d{2})-(\d{2})")
CONSOLIDATED_RE = re.compile(r"(\d{2})-(\d{2})\s+consolidated")
JOURNAL_NAME_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})\.md$")
HEADING_RE = re.compile(r"^(#{1,3})\s+(.*)$")


def find_brain_dir(vault):
    """The directory holding HANDOFF.md with a journal/ or LEARNINGS.md beside it."""
    vault = os.path.abspath(os.path.expanduser(vault))
    candidates = []
    for root, dirs, files in os.walk(vault):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d != "node_modules"]
        if "HANDOFF.md" in files:
            score = int("journal" in dirs) + int("LEARNINGS.md" in files)
            candidates.append((-score, root))
    if not candidates:
        return None
    candidates.sort()
    return candidates[0][1]


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def open_ledger_ro(path):
    path = os.path.abspath(os.path.expanduser(path))
    uri = "file:%s?mode=ro" % path.replace("?", "%3f")
    return sqlite3.connect(uri, uri=True)


def infer_year(month, day, anchor):
    """MM-DD markers carry no year; pick the year that lands closest to anchor."""
    best = None
    for year in (anchor.year - 1, anchor.year, anchor.year + 1):
        try:
            cand = dt.datetime(year, month, day)
        except ValueError:
            continue
        if best is None or abs(cand - anchor) < abs(best - anchor):
            best = cand
    return best


def parse_claimed_coverage(handoff_text, anchor):
    """The latest moment the handoff itself claims to cover.

    Markers, in the order the brain writes them today:
      - "WAKE MM-DD HH:MM" in the GLANCE (refreshed each wake cycle)
      - "-- written YYYY-MM-DD" in the letter footer (the SLEEP rewrite)
      - "MM-DD consolidated" in the consolidation-status section
        (coverage through the END of that day)
    """
    marks = []
    written_dt = None
    m = WRITTEN_RE.search(handoff_text)
    if m:
        written_dt = dt.datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        marks.append(("written", written_dt))
    year_anchor = written_dt or anchor
    for m in WAKE_RE.finditer(handoff_text):
        base = infer_year(int(m.group(1)), int(m.group(2)), year_anchor)
        if base:
            marks.append(("wake", base.replace(
                hour=int(m.group(3)), minute=int(m.group(4)))))
    for m in CONSOLIDATED_RE.finditer(handoff_text):
        base = infer_year(int(m.group(1)), int(m.group(2)), year_anchor)
        if base:
            marks.append(("consolidated-through", base + dt.timedelta(days=1)))
    if not marks:
        return None, None
    kind, when = max(marks, key=lambda kv: kv[1])
    return kind, when


def check_staleness_honesty(brain_dir, conn, now):
    """How far behind the ledger is the handoff, and is its own claim truthful."""
    detail = {}
    handoff = read(os.path.join(brain_dir, "HANDOFF.md"))
    if handoff is None:
        return dict(name="staleness-honesty", ok=False, value=None,
                    detail={"error": "HANDOFF.md not found"})
    anchor = dt.datetime.fromtimestamp(now)
    kind, claimed = parse_claimed_coverage(handoff, anchor)
    if claimed is None:
        return dict(name="staleness-honesty", ok=False, value=None,
                    detail={"error": "no coverage markers (WAKE/written/"
                                     "consolidated) found in handoff"})
    row = conn.execute(
        "SELECT MAX(ts), (SELECT COUNT(*) FROM events WHERE ts > ?) "
        "FROM events WHERE ts <= ?", (now, now)).fetchone()
    ledger_max, future_rows = row[0], row[1]
    if ledger_max is None:
        return dict(name="staleness-honesty", ok=False, value=None,
                    detail={"error": "ledger has no events at or before now"})
    claimed_ts = claimed.timestamp()
    lag_hours = max(0.0, (ledger_max - claimed_ts) / 3600.0)
    claim_in_future = claimed_ts > now + FUTURE_SLACK_SECS
    detail.update(
        claim_kind=kind,
        claimed_coverage=claimed.strftime("%Y-%m-%d %H:%M"),
        ledger_newest=dt.datetime.fromtimestamp(ledger_max).strftime("%Y-%m-%d %H:%M"),
        future_timestamped_rows=future_rows,
        claim_in_future=claim_in_future,
        threshold_hours=STALENESS_MAX_HOURS,
    )
    ok = (not claim_in_future) and lag_hours <= STALENESS_MAX_HOURS
    return dict(name="staleness-honesty", ok=ok,
                value=round(lag_hours, 2), unit="hours-behind-ledger",
                detail=detail)


def brain_surfaces(brain_dir):
    """The files the brain itself writes: handoff, learnings, journals."""
    surfaces = []
    for name in ("HANDOFF.md", "LEARNINGS.md"):
        p = os.path.join(brain_dir, name)
        if os.path.isfile(p):
            surfaces.append((name, p))
    jdir = os.path.join(brain_dir, "journal")
    if os.path.isdir(jdir):
        for fn in sorted(os.listdir(jdir)):
            if fn.endswith(".md"):
                surfaces.append(("journal/" + fn, os.path.join(jdir, fn)))
    return surfaces


def check_redaction_hygiene(brain_dir):
    """Leaks the ROADMAP's scrubbing item says should never reach prose."""
    per_surface = {}
    totals = {"emails": 0, "digit-runs": 0, "secrets": 0}
    for label, path in brain_surfaces(brain_dir):
        text = read(path) or ""
        counts = {
            "emails": len(EMAIL_RE.findall(text)),
            "digit-runs": len(DIGIT_RUN_RE.findall(text)),
            "secrets": sum(len(rx.findall(text)) for _, rx in SECRET_PATTERNS),
        }
        if any(counts.values()):
            per_surface[label] = counts
        for k in totals:
            totals[k] += counts[k]
    total = sum(totals.values())
    return dict(name="redaction-hygiene", ok=(total == 0),
                value=total, unit="leaks",
                detail={"totals": totals, "surfaces_with_leaks": per_surface,
                        "surfaces_scanned": len(brain_surfaces(brain_dir))})


def check_structure_contract(brain_dir):
    """The handoff carries the sections its own constitution mandates."""
    handoff = read(os.path.join(brain_dir, "HANDOFF.md"))
    if handoff is None:
        return dict(name="structure-contract", ok=False, value=0.0,
                    detail={"error": "HANDOFF.md not found"})
    headings = []  # (level, text) for ## and ### only; # is the title
    for line in handoff.splitlines():
        m = HEADING_RE.match(line)
        if m and len(m.group(1)) >= 2:
            headings.append(m.group(2).strip().lower())
    present, missing = [], []
    for name, keywords in REQUIRED_SECTIONS:
        if any(any(kw in h for kw in keywords) for h in headings):
            present.append(name)
        else:
            missing.append(name)
    glance_first = bool(headings) and "glance" in headings[0]
    # GLANCE budget: non-empty lines between the GLANCE heading and the next
    # heading or rule. The constitution says <= 5 lines, standing alone.
    glance_lines = 0
    in_glance = False
    for line in handoff.splitlines():
        m = HEADING_RE.match(line)
        if m and len(m.group(1)) >= 2:
            if in_glance:
                break
            in_glance = "glance" in m.group(2).lower()
            continue
        if in_glance and line.strip() and not line.strip().startswith("---"):
            glance_lines += 1
    fraction = len(present) / float(len(REQUIRED_SECTIONS))
    ok = (not missing) and glance_first and glance_lines <= GLANCE_MAX_LINES
    return dict(name="structure-contract", ok=ok,
                value=round(fraction, 2), unit="required-sections-present",
                detail={"present": present, "missing": missing,
                        "glance_is_first_section": glance_first,
                        "glance_lines": glance_lines,
                        "glance_max_lines": GLANCE_MAX_LINES})


def check_coverage(brain_dir, conn, now, window_days, min_events):
    """Does consolidation keep up with capture: for each ledger-active day,
    a journal file for that day exists, or a following journal consolidates it."""
    today = dt.date.fromtimestamp(now)
    start = now - window_days * 86400
    rows = conn.execute(
        "SELECT date(ts,'unixepoch','localtime') d, COUNT(*) c FROM events "
        "WHERE ts >= ? AND ts <= ? GROUP BY d HAVING c >= ? ORDER BY d",
        (start, now, min_events)).fetchall()
    active_days = [dt.date.fromisoformat(r[0]) for r in rows
                   if dt.date.fromisoformat(r[0]) < today]
    jdir = os.path.join(brain_dir, "journal")
    journal_dates = {}
    if os.path.isdir(jdir):
        for fn in os.listdir(jdir):
            m = JOURNAL_NAME_RE.match(fn)
            if m:
                journal_dates[dt.date(int(m.group(1)), int(m.group(2)),
                                      int(m.group(3)))] = os.path.join(jdir, fn)
    covered, uncovered = [], []
    for day in active_days:
        if day in journal_dates:
            covered.append(day)
            continue
        # A day may be folded into a later SLEEP ("consolidating ... 08-10").
        hit = False
        for ahead in range(1, CONSOLIDATION_LOOKAHEAD_DAYS + 1):
            later = journal_dates.get(day + dt.timedelta(days=ahead))
            if later:
                text = read(later) or ""
                if day.strftime("%m-%d") in text or day.isoformat() in text:
                    hit = True
                    break
        (covered if hit else uncovered).append(day)
    if not active_days:
        return dict(name="coverage", ok=False, value=None,
                    detail={"error": "no ledger-active days in window "
                                     "(wrong ledger, or min-events too high)"})
    fraction = len(covered) / float(len(active_days))
    return dict(name="coverage", ok=fraction >= COVERAGE_PASS_FRACTION,
                value=round(fraction, 2), unit="days-consolidated",
                detail={"window_days": window_days,
                        "active_days": len(active_days),
                        "covered_days": len(covered),
                        "uncovered": [d.isoformat() for d in uncovered],
                        "pass_threshold": COVERAGE_PASS_FRACTION})


def run_all(vault, ledger, brain_dir=None, now=None,
            window_days=COVERAGE_WINDOW_DAYS, min_events=COVERAGE_MIN_EVENTS):
    now = now if now is not None else dt.datetime.now().timestamp()
    brain_dir = brain_dir or find_brain_dir(vault)
    if brain_dir is None:
        raise SystemExit("error: no brain directory (a folder holding HANDOFF.md) "
                         "found under %s" % vault)
    conn = open_ledger_ro(ledger)
    try:
        results = [
            check_staleness_honesty(brain_dir, conn, now),
            check_redaction_hygiene(brain_dir),
            check_structure_contract(brain_dir),
            check_coverage(brain_dir, conn, now, window_days, min_events),
        ]
    finally:
        conn.close()
    return brain_dir, results


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--vault", required=True,
                    help="vault root (the brain dir is auto-detected below it)")
    ap.add_argument("--ledger", required=True, help="path to the sqlite ledger")
    ap.add_argument("--brain-dir", default=None,
                    help="exact brain directory; skips auto-detection")
    ap.add_argument("--days", type=int, default=COVERAGE_WINDOW_DAYS,
                    help="coverage window in days (default %(default)s)")
    ap.add_argument("--min-events", type=int, default=COVERAGE_MIN_EVENTS,
                    help="events needed for a day to count as active "
                         "(default %(default)s)")
    ap.add_argument("--now", type=float, default=None,
                    help="override 'now' as a unix timestamp (testing hook)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args(argv)

    brain_dir, results = run_all(args.vault, args.ledger,
                                 brain_dir=args.brain_dir, now=args.now,
                                 window_days=args.days,
                                 min_events=args.min_events)
    all_ok = all(r["ok"] for r in results)
    if args.json:
        print(json.dumps({"brain_dir": brain_dir, "ok": all_ok,
                          "checks": results}, indent=2))
    else:
        print("brain dir: %s" % brain_dir)
        for r in results:
            verdict = "PASS" if r["ok"] else "FAIL"
            value = r.get("value")
            unit = r.get("unit", "")
            vtxt = "-" if value is None else ("%s %s" % (value, unit)).strip()
            print("%-4s %-20s %s" % (verdict, r["name"], vtxt))
            det = r.get("detail", {})
            if "error" in det:
                print("     error: %s" % det["error"])
            elif not r["ok"]:
                for k, v in det.items():
                    print("     %s: %s" % (k, v))
        print("overall: %s" % ("PASS" if all_ok else "FAIL"))
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
