# Setup

An honest install guide for a new user on macOS 15. This is a personal system
published as-is; several paths are the author's and are called out below
rather than papered over. Read the whole page once before starting.

## Prerequisites

- **macOS 15+** (Sequoia). The Swift package declares `.macOS(.v15)`.
- **Xcode Command Line Tools** with **Swift 6** (`xcode-select --install`;
  check `swift --version`).
- **python3** and **sqlite3** — the versions macOS ships are fine. The
  instrument scripts use only the standard library.
- **Optional: the `claude` CLI** with a Claude subscription — required only
  for the brain. Capture works completely without it. The code prefers the
  self-contained native binary at `~/.local/bin/claude` and will warn if it
  falls back to a Node-shim install (`ClaudeRunner.findBinary`).

## Build

```bash
git clone https://github.com/bayraak/2ndm1nd-runtime
cd 2ndm1nd-runtime
swift build -c release
swift test
```

This produces two binaries under `.build/release/`: `2ndm1nd` (the menu-bar
capture app) and `brain` (the ledger CLI).

**A note on the Makefile.** The Makefile is written to be included from the
author's vault-root Makefile: its paths are built from a `VAULT` variable
(`SM_DIR := $(VAULT)/.scripts/secondmind`), so bare `make v2-build` in a fresh
clone will not resolve. The targets are still the best documentation of the
install procedure, and everything they do is spelled out manually below. If
your clone lives at `<somewhere>/.scripts/secondmind` you can drive it with
`make VAULT=<somewhere> v2-<target>`.

## Code signing — why, and how

macOS TCC (the Privacy & Security permission system) keys grants to a
binary's code-signing identity. If you ad-hoc sign (or don't sign), every
rebuild mints a new cdhash and **silently resets** Accessibility, Input
Monitoring and Full Disk Access. The Makefile's answer (`v2-install`) is a
stable self-signed identity: signing with a named certificate pins the
Designated Requirement to `identifier "org.2ndm1nd.app" and certificate leaf`,
which is constant across rebuilds, so grants survive `make v2-install`.

`make v2-signing-setup` runs `signing/setup-signing.sh`, which idempotently:
generates a self-signed Code Signing certificate ("2ndm1nd Code Signing",
RSA-2048, 10 years) with a `.p12` backup under
`~/.local/share/2ndm1nd/signing/`; creates a dedicated, never-auto-locking
keychain `~/Library/Keychains/2ndm1nd-signing.keychain-db` with a throwaway
password (deliberately not a real credential — the script's header explains
why); imports the identity; and pre-authorizes `codesign` against it so
signing never pops a dialog. The only risk of a self-signed identity on a
personal machine is local impersonation of the app's TCC identity, which
already requires local access.

Manual equivalent, if you would rather do it yourself: create any
"Code Signing" certificate in Keychain Access (Certificate Assistant → Create
a Certificate → type: Code Signing), then:

```bash
mkdir -p ~/.local/share/2ndm1nd/bin
cp .build/release/2ndm1nd ~/.local/share/2ndm1nd/bin/2ndm1nd
cp .build/release/brain   ~/.local/share/2ndm1nd/bin/brain
codesign -s "2ndm1nd Code Signing" -i org.2ndm1nd.app   -f ~/.local/share/2ndm1nd/bin/2ndm1nd
codesign -s "2ndm1nd Code Signing" -i org.2ndm1nd.brain -f ~/.local/share/2ndm1nd/bin/brain
```

`make v2-install` does the above plus: syntax-checks `brain-loop.sh` against
the system bash 3.2 before deploying, copies the runtime scripts
(`brain-loop.sh`, `await-wake.sh`, and the instrument `*.py` files listed in
`SM_RUNTIME_PY`) into `~/.local/share/2ndm1nd/bin/`, and — a detail worth
copying if you script this yourself — replaces the shell scripts via
`cp x x.new && mv -f x.new x`, never a bare `cp`, because a live
`bash brain-loop.sh` holds its file open by inode and rewriting it in place
corrupts the running loop.

## Installing the launchd agents

The plists in `plists/` are templates: `__HOME__` and `__USER__` are
placeholders, substituted at install time. The Makefile's `v2-up` and
`v2-brain-up` do exactly this:

```bash
mkdir -p ~/Library/Logs/2ndm1nd
sed -e "s|__HOME__|$HOME|g" -e "s|__USER__|$(id -un)|g" \
    plists/org.2ndm1nd.app.plist > ~/Library/LaunchAgents/org.2ndm1nd.app.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.2ndm1nd.app.plist
launchctl kickstart -k gui/$(id -u)/org.2ndm1nd.app
```

That starts capture only. A brain icon appears in the menu bar with live
permission state.

## Permissions (TCC), and why each

The app preflights every grant and shows state in its menu; each line opens
the right Settings pane. Grant them to **2ndm1nd** (the binary name is the
name macOS shows):

| grant | needed by | for |
|---|---|---|
| **Accessibility** | FocusContextSensor, InputSensor | reading focused-window titles (which chat / project / tab) and the on-screen context snapshots for Q/A capture. Without it, capture still runs but spans lose most of their meaning. |
| **Input Monitoring** | InputSensor | the CGEventTap itself. The v1 lesson baked into the code: the tap "succeeds" without this grant and silently delivers nothing, which is why the app checks and warns loudly. |
| **Full Disk Access** | messages and mail connectors | reading `~/Library/Messages/chat.db` and `~/Library/Mail` (Envelope Index + `.emlx`). Skip it and those two connectors no-op with a logged hint; everything else works. |
| Calendar / Reminders / Contacts | EventKitConnector | optional; prompted once at app startup. Contacts seeding additionally only ever runs manually (`2ndm1nd eventkit`). |

## Configuration

Configuration is one TOML file, read by `Config.swift`. Default location:
`<vault>/Efforts/Active/2ndmind-v2/config.toml`; override with
`SECONDMIND_CONFIG=/path/to/config.toml`. Every key has a safe default — the
app runs with no config file at all. The keys and defaults are all in
`Sources/SecondMindKit/Config.swift`; the ones most people will touch:

```toml
[paths]
vault = "/Users/you/Projects/2ndm1nd"   # default: ~/Projects/2ndm1nd

[privacy]
never_record_apps  = ["com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords"]
never_record_paths = ["~/Projects/2ndm1nd/Atlas/Personal", "~/.ssh", "~/.aws"]

[sessionizer]
idle_close_s = 90
```

**Vault path honesty.** The Swift side respects `paths.vault`, but
`brain-loop.sh` hardcodes `VAULT="$HOME/Projects/2ndm1nd"` and the Python
instruments hardcode `Path.home()/"Projects/2ndm1nd"`. If your vault lives
anywhere else, either symlink `~/Projects/2ndm1nd` to it or edit those paths.
The README's status section means it: expect to edit paths.

**`SECONDMIND_AUTHOR_RE`** — a regex matched against git author names/emails
so the timeline instrument (`timeline-distill.py`) can tell your commits from
other people's in shared repos. The default matches nothing, which means
"treat no commits as yours" until you set it. Example:
`export SECONDMIND_AUTHOR_RE='(?i)(your name|you@example.com)'`.

## Running capture without the brain — fully supported

Capture is designed to be complete on its own: don't install the brain agent,
and nothing model-related ever runs. You still get the full ledger, activity
spans, `brain search`/`brain spans`/`brain query` over your history, the
localhost HTTP server, and the Raycast/MCP surfaces. No `claude` CLI, no
subscription, no network calls at all. The brain can be added months later
against the same ledger — or never.

## Starting the brain (optional)

Requires the `claude` CLI on PATH, authenticated
(`claude login`) with a subscription. The brain deliberately runs
subscription-only: the runner unsets `ANTHROPIC_API_KEY` and the Swift runner
strips the environment, so API-key billing is never used.

```bash
sed -e "s|__HOME__|$HOME|g" -e "s|__USER__|$(id -un)|g" \
    plists/org.2ndm1nd.brain.plist > ~/Library/LaunchAgents/org.2ndm1nd.brain.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.2ndm1nd.brain.plist
```

The plist's environment variables are the budget dials
([docs/token-economy.md](token-economy.md) documents them):
`SECONDMIND_MIN_RELAUNCH` (seconds between cycles; template ships 10800),
`SECONDMIND_MAX_SESSIONS` (daily cap; template 9), `SECONDMIND_CYCLE_MAX`
(per-cycle seconds; deep cycles get double). Useful controls once running,
via the Makefile or by hand: `v2-brain-status`, `v2-brain-logs`,
`v2-brain-pause` / `v2-brain-resume` (touch/remove
`~/Library/Application Support/2ndMind/brain-runtime/paused`),
`v2-brain-wake` (touch `.../brain-runtime/wake`).

Note the brain plist's `WorkingDirectory` is `__HOME__/Projects/2ndm1nd` — the
same hardcoded vault assumption as above.

## Verifying

```bash
launchctl list | grep org.2ndm1nd            # both agents loaded?
ls -lh ~/Library/Application\ Support/2ndMind/brain.db   # ledger growing?
~/.local/share/2ndm1nd/bin/brain search "something you typed today"
tail -f ~/Library/Logs/2ndm1nd/brain-loop.log            # brain cycles (if installed)
```

The menu-bar icon shows a warning badge until every permission the sensors
need is granted.
