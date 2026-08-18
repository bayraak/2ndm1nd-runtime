# Privacy model

## Why this document is the important one

The premise of this system, in the author's words: *how much it knows for you,
that much it becomes you.* The ledger holds what you typed, to whom, in which
window, at what hour; what you copied, committed, browsed, sent and received.
Held together, that is not activity data — it is a working copy of your
memory, and a system that holds a working copy of your memory is, in a plain
and non-mystical sense, an extension of you. Its value and its danger come
from the same place.

Two design consequences follow, and everything on this page is one or the
other:

1. **Nothing leaves the machine except what you explicitly route through the
   brain.** You would not hand a copy of yourself to a cloud service, so no
   part of this system does it for you. Storage is SQLite and markdown on your
   disk; the one outbound channel is the brain's model session, which is
   optional, separate, and inspectable.
2. **Every guarantee is a code path, not a promise.** A system this intimate
   cannot ask to be trusted; it has to be checkable by its owner. Each claim
   below names the code that makes it true, and the
   [verification section](#verify-it-yourself) gives the exact commands a
   skeptic can run against this repository.

One thing this system deliberately is not: self-censoring. By the owner's
directive (recorded in Sources/SecondMindKit/Sensors/SensorHub.swift), capture
is verbatim — there is no content redaction, because a personal ledger that
edits your own life is lying to you. The privacy floor is about password
contexts and about where data can *go*, not about softening what you did.

## What every sensor and connector stores — and never stores

| component | stores | never stores |
|---|---|---|
| Focus sensor (`FocusContextSensor.swift`) | bundle id, app name, focused-window title, derived context (chat name, terminal cwd, project, file, browser tab title), attribution (`to`/`thread`/`channel`) | anything from a `never_record` app: those emit a `privacy-blocked-presence` event carrying the bundle id only — no title, no content |
| Input sensor (`InputSensor.swift`) | typed text verbatim (layout-aware, backspace-corrected), activity metrics (keystrokes, backspace ratio, clicks, scroll), and for terminal/chat replies a raw Q/A pair: the on-screen context at answer-start plus your literal reply | secure-input fields (password boxes): `IsSecureEventInputEnabled()` is checked in the tap callback and the event is dropped before any processing. `never_record` apps: the entire window is discarded at flush — no text, no counts, no event at all |
| Clipboard sensor (`ClipboardSensor.swift`) | copied text (first 10,000 chars), length, SHA-256, source app | copies made while a `never_record` app is frontmost: presence marker only — no content, no length, no hash ("even a length or hash of a copied password is a fingerprint", per the code). Non-text clipboard data: a type marker only |
| Power sensor (`PowerSensor.swift`) | sleep/wake/screensaver/lock event kinds | any content — there is none to store |
| Shell connector (`Connectors.swift`) | command lines from `~/.zsh_history` / `~/.bash_history` | anything not already in your shell history files |
| Git connector | commit SHA (10-char), author, subject, project name — local branches, authored commits, last 14 days | diffs, file contents, pulled remote commits, merges |
| IDE connector | workspace/project names and touch times from VS Code/Cursor workspace storage | file contents |
| Browser connector | URL, title, visit time from Chrome/Arc/Brave history databases | page contents; anything from browsers it does not read |
| Messages connector (FDA) | iMessage/SMS text, handle, direction from `chat.db` | nothing withheld within Messages — this is a full-content connector, gated on you granting Full Disk Access |
| Mail connector (FDA) | From/Subject/Date metadata in the ledger; verbatim copies of `.emlx` files and attachments in app data (so the sandboxed brain can read them) | parsed/derived mail content — no parsing or OCR happens at capture; and mail content never enters the vault (ledger/app-data only, per the connector's contract) |
| Claude Code connector | your real prompts to your agents from `~/.claude/projects/*.jsonl`, paired with the preceding assistant tail | the brain's own session transcripts (dropped by sentinel check — no feedback loop), tool dumps, system tags |
| EventKit connector | calendar event and reminder data, only after the system grant; contacts only on a manual run | anything before you grant; the scheduled path never prompts |

The `never_record` lists (apps and paths) are configuration
(`privacy.never_record_apps` / `never_record_paths` in `Config.swift`),
defaulting to password managers, Apple Passwords, `Atlas/Personal`, `~/.ssh`,
`~/.aws`. The floor is enforced in one place (`SensorHub`), which each sensor
consults.

## Capture makes zero model calls

There is no model anywhere in the capture path — not as a policy, but as an
absence of code. The sensors, connectors, event store, sessionizer and
scheduler contain no reference to `ClaudeRunner` (the single choke point
through which every Swift-side model call goes). The scheduled jobs the app
runs are exactly four — sessionize, retention, connectors, eventkit — all
deterministic (`wireJobs()` in `Sources/SecondMindApp/main.swift`, whose own
comment records the rule: the app runs no claude calls).

Full disclosure of the model call sites that *do* exist, all outside capture
and all user- or brain-initiated:

- `brain-loop.sh` — the brain's daily session (the point of the system);
- `2ndm1nd cortex <tier>` and `2ndm1nd brain-session` — on-demand subcommands
  you invoke;
- `POST /ask` on the localhost server — answers a question you asked;
- `2ndm1nd claude-smoke` / `claude-tools-smoke` — manual test commands.

Even the brain's own subprocess hygiene is structural: `brain-loop.sh` runs
`unset ANTHROPIC_API_KEY`, and the Swift runner replaces the child environment
wholesale with `HOME`/`USER`/`LOGNAME`/`PATH` — so no API key can reach any
spawned process, and subscription auth is the only possible path.

## Everything is local

- **Data at rest:** the ledger at
  `~/Library/Application Support/2ndMind/brain.db` (plus daily same-disk
  backups beside it), mail copies under the same app-data directory, markdown
  in your vault, JSONL logs under `~/Library/Logs/2ndm1nd`. No cloud storage,
  no telemetry, no analytics.
- **The HTTP server** (`BrainServer.swift`) binds `127.0.0.1` only, requires a
  bearer token on everything but `/health`, and the token is generated
  locally and chmod 0600. The MCP server and Raycast extension are thin
  clients of it, also local. (Exposing it beyond localhost — e.g. through a
  tunnel — is a choice you would have to make and secure yourself.)
- **Network calls, exhaustively:** the brain's `claude` session, and a
  connectivity probe of `https://api.anthropic.com` before starting one
  (transport check only; no payload). If you run capture without the brain,
  the number of network calls is zero.

## What leaves the machine, and when

Only the brain's model session, and only when it runs. Concretely, a cycle
sends to Anthropic: the boot prompt (constitution, yesterday's handoff letter,
the runner's VITALS block, primed entity notes), and whatever the model then
reads through its tools during the session — digest files, vault notes, ledger
query results, mail copies. That content is processed under your Claude
subscription's terms, like anything you paste into Claude yourself.

The control surface is honest and coarse: if the brain never runs, nothing
ever leaves. Pause it (`make v2-brain-pause`), uninstall it, or never install
it — capture and search remain fully functional. What the brain *can* read is
further bounded by the sandbox: credential paths are read-denied at the OS
level (`~/.ssh`, `~/.aws`, gcloud, `~/.cloudflared`, the vault's env file),
so an injected instruction in captured text cannot exfiltrate what its
process cannot read.

## The brain is caged by structure, not trust

The model session runs under `sandbox-exec`
(`ClaudeRunner.ensureSandboxProfile`): the vault is read-only except the
memory directories the brain owns; the runner, plists, and the brain's own
state files are write-denied (it cannot edit its budgets or its gates);
credentials are read-denied. The profile is inherited by every child process,
Bash included. [self-evolution.md](self-evolution.md) documents the full
envelope; the design argument is the project's recurring one: a control
enforced by instruction eventually gets bypassed, so the guarantee lives where
there is no code path around it.

## Verify it yourself

Run these from the repository root. Each maps to a claim above.

**No model call in the capture path** — expect *no output*:

```bash
grep -rn "ClaudeRunner" Sources/SecondMindKit/Sensors/ \
  Sources/SecondMindKit/Connectors.swift Sources/SecondMindKit/EventKitConnector.swift \
  Sources/SecondMindKit/EventStore.swift Sources/SecondMindKit/Sessionizer.swift \
  Sources/SecondMindKit/Scheduler.swift
```

**The scheduled jobs are deterministic** — read the four registrations and the
no-claude comment:

```bash
grep -n -A 3 "scheduler.add" Sources/SecondMindApp/main.swift
```

**Secure input dropped at the tap; never-record floor in every sensor:**

```bash
grep -n "IsSecureEventInputEnabled" Sources/SecondMindKit/Sensors/InputSensor.swift
grep -rn "isNeverRecordApp\|privacy-blocked-presence" Sources/SecondMindKit/Sensors/
```

**Localhost-only server, 0600 token:**

```bash
grep -n "127.0.0.1\|posixPermissions" Sources/SecondMindKit/BrainServer.swift
```

**No API key can reach a model subprocess:**

```bash
grep -n "ANTHROPIC_API_KEY" brain-loop.sh
grep -n -A 6 "process.environment" Sources/SecondMindKit/ClaudeRunner.swift
```

**The complete outbound-call inventory** — expect exactly the reachability
probe (plus this documentation):

```bash
grep -rn "api.anthropic.com" --include="*.swift" --include="*.sh" --include="*.py" .
grep -rn "URLSession" Sources/        # expect no output
```

**The sandbox that cages the brain** — read the whole profile generator; it is
one function:

```bash
grep -n -A 60 "func ensureSandboxProfile" Sources/SecondMindKit/ClaudeRunner.swift
```

If any of these greps stops returning what this page says it returns, the
documentation is wrong or the guarantee has regressed — either way, please
open an issue.
