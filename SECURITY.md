# Security

## Threat model

This is a local, single-user tool. It has no accounts, no server component
beyond a localhost listener, and no data plane off the machine. The asset that
matters is the **ledger** (`brain.db`) and the vault it feeds: together they
hold keystrokes, messages, mail, and browsing history — a working copy of the
owner's memory. The realistic threats are therefore local ones: another
process or user on the machine reading the ledger, a leaked backup, and
prompt injection through captured text that the brain later reads.

Protections, all structural:

- The ledger and app data live under the user's `~/Library`, protected by
  ordinary file permissions and macOS TCC (the capture binary itself needs
  explicit grants to read anything sensitive).
- The HTTP server binds `127.0.0.1` only and requires a bearer token
  (generated locally, stored 0600) on every route except `/health`.
- The brain's model session runs under a `sandbox-exec` profile that
  read-denies credential paths (`~/.ssh`, `~/.aws`, gcloud, `~/.cloudflared`,
  the vault's env file) and write-denies the runner, the launchd plists, and
  its own state. Prompt injection through captured content is treated as a
  real threat; the mitigation is that the payload a hijacked session would
  want is unreadable to it.

## The no-model guarantee is a security property

The capture path makes zero model calls (verify:
[docs/privacy.md](docs/privacy.md#verify-it-yourself)). Security-wise this
means the component with the broadest read access — the one holding the event
tap, Full Disk Access, and the clipboard — has **no outbound channel and no
instruction-following surface**. Captured text cannot prompt-inject a process
that never prompts a model, and capture cannot exfiltrate what it never
transmits. Contributions that weaken this boundary are rejected on principle
(see [CONTRIBUTING.md](CONTRIBUTING.md)).

## Where secrets live

- **No secrets in this repository.** The published plists are templates
  (`__HOME__`/`__USER__`); configuration carries paths, not credentials.
- The server bearer token: `~/Library/Application Support/2ndMind/server-token`,
  mode 0600, generated on first run.
- The code-signing identity: a self-signed certificate in a dedicated local
  keychain (`~/Library/Keychains/2ndm1nd-signing.keychain-db`). Its keychain
  password is a documented throwaway, used for nothing else — it protects a
  local-impersonation-only asset.
- Claude authentication is owned entirely by the `claude` CLI (its own
  keychain storage); this project unsets `ANTHROPIC_API_KEY` for its
  subprocesses and never handles model credentials itself.

## Reporting a vulnerability

Please use GitHub's **private security advisory** for this repository
(Security tab → "Report a vulnerability") rather than a public issue,
especially for anything that weakens the sandbox, the localhost boundary, or
the no-model guarantee. There is no bounty; reports get a human reply and
credit in the fix.
