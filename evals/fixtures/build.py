#!/usr/bin/env python3
"""Build synthetic eval fixtures: a tiny fake vault plus a tiny sqlite ledger.

Two modes:
  healthy  — a well-run instance: fresh handoff with every required section,
             clean prose, a journal for every active ledger day.
  broken   — an instance that should fail every check: a stale handoff that
             also claims coverage in the future, missing sections, an
             over-budget glance, leaked email/token/digit-run, journal gaps.

All content is invented and neutral. Dates are generated relative to now so
the staleness and coverage checks stay meaningful whenever the tests run.

Usage: python3 evals/fixtures/build.py <outdir> [healthy|broken]
Creates <outdir>/vault/... and <outdir>/ledger.db.
"""

import datetime as dt
import os
import sqlite3
import sys

DAYS = 10  # of ledger history
EVENTS_PER_DAY = 12


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def build_ledger(path, now):
    if os.path.exists(path):
        os.remove(path)
    conn = sqlite3.connect(path)
    conn.execute(
        'CREATE TABLE "events" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, '
        '"ts" DOUBLE NOT NULL, "source" TEXT NOT NULL, "kind" TEXT NOT NULL, '
        '"app" TEXT, "text" TEXT, "payload" TEXT NOT NULL, "spanId" INTEGER)')
    base = dt.datetime.fromtimestamp(now)
    rows = []
    for back in range(DAYS, -1, -1):
        day = base - dt.timedelta(days=back)
        for i in range(EVENTS_PER_DAY):
            ts = day.replace(hour=9, minute=0, second=0,
                             microsecond=0) + dt.timedelta(minutes=30 * i)
            if ts.timestamp() > now:
                continue
            rows.append((ts.timestamp(), "fixture", "note", "editor",
                         "worked on the garden planner, task %d" % i, "{}"))
    # one future-timestamped row (a calendar entry), as real ledgers have
    rows.append((now + 5 * 86400, "calendar", "event", None,
                 "seed order pickup", "{}"))
    conn.executemany(
        "INSERT INTO events (ts, source, kind, app, text, payload) "
        "VALUES (?,?,?,?,?,?)", rows)
    conn.commit()
    conn.close()


def _journal_body(day, prev):
    return (
        "# %s — SLEEP (consolidating %s: a quiet fixture day in the garden "
        "planner project)\n\n"
        "The day's work was replanning the raised beds and comparing seed "
        "suppliers. Nothing urgent surfaced.\n"
        % (day.isoformat(), prev.strftime("%m-%d")))


def _handoff_healthy(now):
    n = dt.datetime.fromtimestamp(now)
    yesterday = (n - dt.timedelta(days=1)).date()
    return (
        "# HANDOFF — a letter from each session to the next\n\n"
        "## ⚡ GLANCE\n"
        "> **NOW (WAKE %s):** the garden planner's bed layout is settled; "
        "seed order drafted, not sent.\n"
        "> **Board:** rhythm 1/0 · project 2/1.\n"
        "> **Today %s:** compare the two remaining seed suppliers.\n\n"
        "## What actually happened (%s)\n"
        "A slow planning day. The bed layout moved from sketch to a measured "
        "plan; the compost question stayed open.\n\n"
        "## What I believe (dated, falsifiable)\n"
        "- [MEDIUM, %s] The south bed gets enough light for tomatoes. "
        "Breaks if the fence shadow reaches it after the equinox.\n\n"
        "## ⏰ RIPENING (information, never a task)\n"
        "- The seed order window closes at the end of the month.\n\n"
        "## Open questions (mine to answer by observing)\n"
        "- Does the planner get opened on non-weekend days at all?\n\n"
        "## Predictions for the next SLEEP to grade\n"
        "- The seed order is placed within three days.\n\n"
        "## Curate / consolidation status\n"
        "- **%s consolidated** (journal %s).\n\n"
        "— written %s @SLEEP. A short day, honestly recorded.\n"
        % (n.strftime("%m-%d %H:%M"), n.strftime("%m-%d"),
           yesterday.strftime("%m-%d"), yesterday.isoformat(),
           yesterday.strftime("%m-%d"), n.date().isoformat(),
           n.date().isoformat()))


def _handoff_broken(now):
    n = dt.datetime.fromtimestamp(now)
    stale = n - dt.timedelta(days=6)          # letter written six days ago...
    future = n + dt.timedelta(days=2)         # ...yet claims a future WAKE
    return (
        "# HANDOFF\n\n"
        "## ⚡ GLANCE\n"
        "> **NOW (WAKE %s):** everything is fine.\n"
        "> line two\n> line three\n> line four\n> line five\n"
        "> line six — one over the budget\n\n"
        "## What actually happened (%s)\n"
        "Contact the supplier at ops.desk@example-supplier.test about "
        "order 940271135566.\n"
        "Deploy note: export PLANNER_API_KEY=sk-fixture00aaaa11bbbb22cccc\n\n"
        "## Predictions for the next SLEEP to grade\n"
        "- none carried.\n\n"
        "— written %s @SLEEP.\n"
        % (future.strftime("%m-%d %H:%M"), stale.strftime("%m-%d"),
           stale.date().isoformat()))


def build_vault(root, mode, now):
    brain = os.path.join(root, "Atlas", "AI", "Brain")
    n = dt.datetime.fromtimestamp(now)
    if mode == "healthy":
        _write(os.path.join(brain, "HANDOFF.md"), _handoff_healthy(now))
        _write(os.path.join(brain, "LEARNINGS.md"),
               "# LEARNINGS\n\n- [self] Grade the bet on the timestamp, "
               "not on when the mail surfaced.\n")
        # a journal for every day the ledger is active on (except today,
        # which coverage excludes anyway — write it too, it is harmless)
        for back in range(DAYS, -1, -1):
            day = (n - dt.timedelta(days=back)).date()
            prev = day - dt.timedelta(days=1)
            _write(os.path.join(brain, "journal", "%s.md" % day.isoformat()),
                   _journal_body(day, prev))
    elif mode == "broken":
        _write(os.path.join(brain, "HANDOFF.md"), _handoff_broken(now))
        _write(os.path.join(brain, "LEARNINGS.md"),
               "# LEARNINGS\n\n- Reached me at gardener@example.test "
               "about invoice 20887766554.\n")
        # journals only for the two oldest active days — a large gap
        for back in (DAYS, DAYS - 1):
            day = (n - dt.timedelta(days=back)).date()
            prev = day - dt.timedelta(days=1)
            _write(os.path.join(brain, "journal", "%s.md" % day.isoformat()),
                   _journal_body(day, prev))
    else:
        raise SystemExit("mode must be healthy or broken, got %r" % mode)


def build(outdir, mode, now=None):
    now = now if now is not None else dt.datetime.now().timestamp()
    outdir = os.path.abspath(outdir)
    vault = os.path.join(outdir, "vault")
    ledger = os.path.join(outdir, "ledger.db")
    os.makedirs(outdir, exist_ok=True)
    build_vault(vault, mode, now)
    build_ledger(ledger, now)
    return vault, ledger


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    out = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "healthy"
    v, l = build(out, mode)
    print("vault:  %s" % v)
    print("ledger: %s" % l)
