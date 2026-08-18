---
name: 2ndm1nd-runtime
description: Operates the 2ndm1nd second-brain runtime on macOS - a local-first ambient capture app plus a daily LLM brain loop over a personal SQLite ledger and markdown vault. Covers building with swift build, the cert-signing install path that preserves TCC grants, starting and stopping the capture and brain launchd agents, pausing and waking the brain, log locations, health checks, querying the events and spans ledger with the brain CLI or sqlite3 FTS, config keys, and the cadence and spend dials. Use when asked to install, run, debug, pause, or query 2ndm1nd, the second brain, ambient capture, the personal ledger, or the brain loop.
---

# Operating the 2ndm1nd runtime

Two launchd agents: `2ndm1nd` (capture — sensors and connectors appending to an
FTS-indexed SQLite ledger; no model calls, ever) and the brain (`brain-loop.sh`
— one resumed headless `claude -p` session per day consolidating the ledger
into a markdown vault). A `brain` CLI queries the ledger. Capture is complete
without the brain; the brain is optional and can be added later or never.
Architecture: see `docs/architecture.md`. Privacy guarantees and their
verification greps: see `docs/privacy.md`.

## Two invariants — never violate

1. **No model calls in the capture path.** Sensors, connectors, event store,
   sessionizer, scheduler are model-free by construction. Never add a model
   call there, directly or via a scheduled job (`CONTRIBUTING.md`).
2. **The brain writes only its own vault markdown.** A kernel `sandbox-exec`
   profile makes the vault read-only except the memory directories the brain
   owns, and read-denies credential paths. Its only ledger write-back is the
   insert-only `brain annotate` channel (separate `annotations.db`); the raw
   ledger stays append-only and verbatim. Never route brain output anywhere
   else. See `docs/self-evolution.md`.

## Key paths

| what | where |
|---|---|
| Ledger (SQLite) | `~/Library/Application Support/2ndMind/brain.db` |
| Brain runtime state (pause/wake markers) | `~/Library/Application Support/2ndMind/brain-runtime/` |
| Installed binaries + runtime scripts | `~/.local/share/2ndm1nd/bin/` |
| App log (JSONL) | `~/Library/Logs/2ndm1nd/2ndm1nd.jsonl` |
| Brain loop log | `~/Library/Logs/2ndm1nd/brain-loop.log` |
| Config (TOML) | `<vault>/Efforts/Active/2ndmind-v2/config.toml`, override with `SECONDMIND_CONFIG=/path` |
| Default vault | `~/Projects/2ndm1nd` |

**Vault path honesty:** the Swift side respects `paths.vault`, but
`brain-loop.sh` and the Python instruments hardcode `~/Projects/2ndm1nd`. If
the vault lives elsewhere, symlink `~/Projects/2ndm1nd` to it or edit those
paths (`docs/setup.md`).

## Build

Requires macOS 15+, Swift 6; the `claude` CLI (subscription-authenticated) only
for the brain.

```bash
swift build -c release   # produces .build/release/{2ndm1nd,brain}
swift test
```

## Install — the honest path

Full guide with rationale: `docs/setup.md`. The Makefile is written to be
included from a vault-root Makefile — bare `make v2-install` in a fresh clone
will not resolve. If the clone lives at `<somewhere>/.scripts/secondmind`, run
`make VAULT=<somewhere> v2-<target>`; otherwise do the steps by hand:

1. **Signing first.** macOS TCC keys permission grants to the code-signing
   identity; ad-hoc signing mints a new cdhash per rebuild and silently resets
   Accessibility, Input Monitoring, and Full Disk Access. Run
   `bash signing/setup-signing.sh` (idempotent; creates the "2ndm1nd Code
   Signing" identity), or create a Code Signing certificate in Keychain Access.
2. **Copy and sign the binaries:**
   ```bash
   mkdir -p ~/.local/share/2ndm1nd/bin
   cp .build/release/2ndm1nd ~/.local/share/2ndm1nd/bin/2ndm1nd
   cp .build/release/brain   ~/.local/share/2ndm1nd/bin/brain
   codesign -s "2ndm1nd Code Signing" -i org.2ndm1nd.app   -f ~/.local/share/2ndm1nd/bin/2ndm1nd
   codesign -s "2ndm1nd Code Signing" -i org.2ndm1nd.brain -f ~/.local/share/2ndm1nd/bin/brain
   ```
3. **Deploy the runtime scripts** (`brain-loop.sh`, `await-wake.sh`, and the
   instrument `*.py` listed under `SM_RUNTIME_PY` in the Makefile) into
   `~/.local/share/2ndm1nd/bin/`. Replace shell scripts via
   `cp x x.new && mv -f x.new x`, never a bare `cp` — a live `bash
   brain-loop.sh` holds its file open by inode and an in-place rewrite
   corrupts the running loop. `brain-loop.sh` must pass `/bin/bash -n`
   (system bash 3.2) before deploying.
4. **Render and load the capture plist** (templates in `plists/` use
   `__HOME__`/`__USER__` placeholders):
   ```bash
   mkdir -p ~/Library/Logs/2ndm1nd
   sed -e "s|__HOME__|$HOME|g" -e "s|__USER__|$(id -un)|g" \
       plists/org.2ndm1nd.app.plist > ~/Library/LaunchAgents/org.2ndm1nd.app.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.2ndm1nd.app.plist
   launchctl kickstart -k gui/$(id -u)/org.2ndm1nd.app
   ```
5. **Grant TCC permissions** to **2ndm1nd** in System Settings → Privacy &
   Security (the menu-bar icon shows live state and opens the right pane):

   | grant | needed by | without it |
   |---|---|---|
   | Accessibility | focus + input sensors | capture runs but spans lose window-title context |
   | Input Monitoring | input sensor's CGEventTap | the tap "succeeds" but silently delivers nothing |
   | Full Disk Access | messages + mail connectors | those two connectors no-op with a logged hint |
   | Calendar/Reminders/Contacts | EventKit connector | optional; prompted once at startup |

## Capture start / stop / status

With the Makefile (`VAULT` set): `make v2-up`, `make v2-down`, `make
v2-status`, `make v2-logs`. By hand: the `launchctl bootstrap`/`kickstart`
lines above to start; `launchctl bootout gui/$(id -u)/org.2ndm1nd.app` to stop.

## Brain start / pause / wake / stop

Requires `claude` on PATH, subscription-authenticated. The runner deliberately
unsets `ANTHROPIC_API_KEY` — API-key billing is never used.

- **Start:** render + bootstrap `plists/org.2ndm1nd.brain.plist` exactly like
  step 4 above (or `make v2-brain-up`). Note its `WorkingDirectory` is
  `__HOME__/Projects/2ndm1nd` — the hardcoded vault assumption again.
- **Pause** (capture keeps running):
  `touch ~/Library/Application\ Support/2ndMind/brain-runtime/paused`
  — current shift finishes, no new one starts. **Resume:** remove that file.
- **Wake** (run a cycle now instead of idling):
  `touch ~/Library/Application\ Support/2ndMind/brain-runtime/wake`
- **Force a METAMORPHOSIS cycle** (LEARNINGS compression + SELF.md rewrite):
  `make v2-brain-morph`, or remove `brain-runtime/morph-done-YYYYMM` then wake.
- **Stop:** `launchctl bootout gui/$(id -u)/org.2ndm1nd.brain`, then kill only
  this project's session: `pkill -f 2NDM1ND-BRAIN-SESSION` (the sentinel marks
  our session so other projects' `claude -p` processes are never touched).
- **Status / logs:** `make v2-brain-status`, or
  `launchctl list | grep org.2ndm1nd` plus
  `tail -f ~/Library/Logs/2ndm1nd/brain-loop.log`.
- **Proposals awaiting the owner:** `make proposals` — the brain diagnoses its
  own rails but cannot apply changes (sandbox denies writes to its runner);
  a human decides.

## Health checks

```bash
launchctl list | grep org.2ndm1nd                          # both agents loaded?
ls -lh ~/Library/Application\ Support/2ndMind/brain.db     # ledger growing?
~/.local/share/2ndm1nd/bin/brain search "something typed today"
tail -f ~/Library/Logs/2ndm1nd/brain-loop.log              # brain cycles
```

`make v2-doctor` checks binaries, running process, and recent log errors.
`make v2-selftest` runs the instruments' regression battery (hard-fails).
Feedback loop: run the check → fix what it names → re-run until clean.

## Querying the ledger

Prefer the `brain` CLI (all output JSON; opens the store read-only):

```bash
brain search "<term>" [--limit N]      # FTS5 over event text
brain spans [--date YYYY-MM-DD]        # activity spans for a day
brain query "SELECT ..."               # read-only SQL (SELECT/WITH only)
brain stats                            # row counts + freshness
brain annotate <event_id> <key> <value> [--by who]   # insert-only write-back
brain annotations [--event ID] [--key K] [--limit N]
```

Direct `sqlite3` (open read-only; the capture process owns writes):

```bash
sqlite3 "file:$HOME/Library/Application Support/2ndMind/brain.db?mode=ro"
```

Schema (columns are real, from `EventStore.swift` / the README):

- `events(id, ts, source, kind, app, text, payload, spanId)` — `ts` is a unix
  epoch double; common `kind` values: `context-snapshot`, `activity-window`,
  `visit`, `app-activated`, `qa-exchange`, `commit`, `message`,
  `clipboard-changed`, `command`.
- `spans(id, t0, t1, activity, app, project, title, entities, evidence, day)`
  — `day` is `YYYY-MM-DD`.
- `events_fts` — FTS5 over `events.text` (`content_rowid = id`).

Examples:

```sql
-- FTS match, newest first
SELECT e.ts, e.kind, e.app, e.text FROM events_fts f
JOIN events e ON e.id = f.rowid
WHERE events_fts MATCH 'invoice NEAR payment' ORDER BY e.ts DESC LIMIT 20;

-- A day's spans with durations
SELECT activity, app, project, title, CAST((t1-t0)/60 AS INT) AS minutes
FROM spans WHERE day = '2026-08-18' ORDER BY t0;

-- Event volume by kind, last 7 days
SELECT kind, COUNT(*) FROM events
WHERE ts > strftime('%s','now') - 7*86400 GROUP BY kind ORDER BY 2 DESC;
```

## Configuration

One TOML file, every key has a safe default (the app runs with no config file).
All keys and defaults: `Sources/SecondMindKit/Config.swift`. Most-touched:

```toml
[paths]
vault = "/Users/you/Projects/2ndm1nd"     # also: paths.appdata, paths.logs

[privacy]
never_record_apps  = ["com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords"]
never_record_paths = ["~/Projects/2ndm1nd/Atlas/Personal", "~/.ssh", "~/.aws"]

[sessionizer]
idle_close_s = 90
```

Other keys: `models.opus`, `thinking.effort`, `claude.timeout_s`,
`brain.interval_min`, `brain.min_batch`, `brain.max_pending_age_min`,
`brain.max_calls_per_day` (Cortex's wrapper-enforced daily budget),
`server.port` (localhost HTTP, default 4517).

## Cadence and spend dials

Environment variables read by `brain-loop.sh`, set in the brain plist
(`docs/token-economy.md` documents each with rationale):

| key | template | script default | meaning |
|---|---|---|---|
| `SECONDMIND_MIN_RELAUNCH` | 10800 | 3600 | floor between cycles (seconds) |
| `SECONDMIND_MAX_SESSIONS` | 9 | 26 | hard daily cap on cycles |
| `SECONDMIND_CYCLE_MAX` | 2700 | 1800 | per-cycle time budget (s); DREAM/MORPH get 2x |
| `SECONDMIND_IDLE_MIN` | — | 20 | skip the cycle below this many new events |
| `SECONDMIND_IDLE_RECHECK` | — | 900 | seconds before re-checking after an idle skip |

Also: `SECONDMIND_AUTHOR_RE` — regex matched against git author name/email so
`timeline-distill.py` can tell the owner's commits apart; default matches
nothing until set. Turning spend down to one consolidation per day is a plist
edit, not a code change.
