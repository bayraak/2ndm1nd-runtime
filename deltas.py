#!/usr/bin/env python3
"""deltas.py — the change-perception layer (L1). Nervous systems respond to
DEVIATION, not state: nine instruments report snapshots, this reports what
MOVED. Each run snapshots key metrics (state json outside the vault) and emits
Atlas/AI/Brain/deltas.md — the diff the brain reads FIRST after the digest:
affect swings, balance shifts, edge changes, queue movements, rhythm deviations.
Runs LAST in the pre-cycle instrument chain.
"""
import json, re, sqlite3
from datetime import date, datetime
from pathlib import Path

V = Path.home() / "Projects/2ndm1nd"
B = V / "Atlas/AI/Brain"
DB = Path.home() / "Library/Application Support/2ndMind/brain.db"
STATE = Path.home() / "Library/Application Support/2ndMind/instrument-state.json"
OUT = B / "deltas.md"


def read(p):
    f = B / p
    return f.read_text(encoding="utf-8", errors="replace") if f.exists() else ""


now = {}
# lint totals by class
qq = read("quality-queue.md")
m = re.search(r"- \d{4}-\d{2}-\d{2} :: (\d+) issues", qq.split("## Trend")[-1].strip().splitlines()[-1]) if "## Trend" in qq else None
now["lint_total"] = int(m.group(1)) if m else len(re.findall(r"^- \[ \]", qq, re.M))
# queues
now["inbox_pending"] = len(re.findall(r"^- \[ \]", read("archive-cursor.md"), re.M))
props = list((V / "Atlas/Mind/proposals").glob("*.md")) if (V / "Atlas/Mind/proposals").is_dir() else []
now["proposals_open"] = sum(1 for pp in props if "status: open" in pp.read_text(encoding="utf-8", errors="replace")[:400])
# balance shares
now.update({f"balance_{a}": int(p) for a, p in
            re.findall(r"^- \*\*([\w()-]+)\*\* █* (\d+)%", read("balance.md"), re.M)})
# affect today + trailing
today = date.today().isoformat()
aff = re.findall(r"^- (\d{4}-\d{2}-\d{2}) · \+(\d+) −(\d+)", read("affect.md"), re.M)
if aff:
    now["affect_pos_today"], now["affect_neg_today"] = next(
        ((int(p), int(n)) for d, p, n in aff if d == today), (0, 0))
    last7 = aff[-8:-1] or aff
    now["affect_neg_7davg"] = round(sum(int(n) for _, _, n in last7) / max(1, len(last7)), 1)
# coactivation
co = read("coactivation.md")
now["edges_strong_unlinked"] = len(re.findall(r"^- \*\*.+?\*\* ↔", co, re.M))
now["edges_weak_linked"] = len(re.findall(r"^- \[\[", co, re.M))
# communities
cm = read("communities.md")
now["communities"] = len(re.findall(r"^## \d+\.", cm, re.M))
now["isolated"] = int(m.group(1)) if (m := re.search(r"## Isolated \((\d+)\)", cm)) else 0
# ledger + rhythm deviation (activity in baseline-low hours today)
try:
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    now["ledger_events"] = con.execute("SELECT COUNT(*) FROM events").fetchone()[0]
    low = [int(h) for h in re.findall(r"presence < 18% of days\): ([\d, ]+)", read("rhythm.md"))
           for h in h.split(",") if h.strip().isdigit()]
    if low:
        qmarks = ",".join("?" * len(low))
        now["low_hour_activity_today"] = con.execute(
            f"SELECT COUNT(*) FROM events WHERE source IN ('input','focus')"
            f" AND date(ts,'unixepoch','localtime')=? AND"
            f" CAST(strftime('%H',ts,'unixepoch','localtime') AS INT) IN ({qmarks})",
            (today, *low)).fetchone()[0]
    con.close()
except Exception:
    pass

prev = json.loads(STATE.read_text()) if STATE.exists() else {}
prev_at = prev.get("_at", "never")
body = ["---", "title: deltas", "type: note", "---", "",
        f"# DELTAS — what MOVED since my last look ({prev_at} → {datetime.now():%Y-%m-%d %H:%M})",
        "", "Salience = deviation. I read this right after the digest.", "",
        "| metric | prev | now | Δ |", "|---|---|---|---|"]
notable = []
for k in sorted(now):
    p, n = prev.get(k), now[k]
    if p is None:
        body.append(f"| {k} | — | {n} | new |")
        continue
    d = n - p if isinstance(n, (int, float)) and isinstance(p, (int, float)) else "·"
    mark = ""
    if isinstance(d, (int, float)) and d != 0:
        mark = f"{'+' if d > 0 else ''}{round(d,1)}"
        if k.startswith("balance_") and abs(d) >= 5:
            notable.append(f"balance shift: **{k[8:]}** {mark} pts")
        if k == "affect_neg_today" and n >= 2 * max(1, now.get('affect_neg_7davg', 1)):
            notable.append(f"negative-affect spike today ({n} vs ~{now.get('affect_neg_7davg')} avg)")
        if k == "low_hour_activity_today" and n > 30:
            notable.append(f"activity in your baseline-quiet hours ({n} events) — rhythm deviation")
        if k == "lint_total" and d > 0:
            notable.append(f"quality regressed by {mark}")
        if k == "isolated" and d > 0:
            notable.append(f"{mark} new isolated node(s)")
        if k == "proposals_open" and d > 0:
            notable.append(f"{mark} new open proposal(s) awaiting review — Mind/proposals/")
    body.append(f"| {k} | {p} | {n} | {mark or '='} |")
body += ["", "## Notable (deviation-salient)"]
body += [f"- {x}" for x in notable] or ["- nothing crossed a deviation threshold"]
OUT.write_text("\n".join(body) + "\n", encoding="utf-8")
now["_at"] = f"{datetime.now():%Y-%m-%d %H:%M}"
STATE.write_text(json.dumps(now, indent=1))
print(f"deltas: {len(notable)} notable deviations -> deltas.md")
