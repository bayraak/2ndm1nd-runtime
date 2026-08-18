# Roadmap

This roadmap names the project's current limits on purpose: a reader should be
able to see what the system is not, as clearly as what it is.

## 1. Brain provider abstraction

The brain supports exactly one provider today: the `claude` CLI, invoked
headless (`claude -p`). There is no provider interface in the code — the seam
is two concrete call sites, `Sources/SecondMindKit/ClaudeRunner.swift` and the
invocation block in `brain-loop.sh`. The goal is to abstract that seam so a
provider can be added by implementing one boundary: headless prompt-in/
text-or-JSON-out, session resume by id, and distinguishable failure classes
(see [docs/architecture.md](docs/architecture.md#the-provider-seam) for the
full contract). The most interesting provider is a fully local model, which
would make the entire system offline. This is the most-wanted contribution —
see [CONTRIBUTING.md](CONTRIBUTING.md).

## 2. Consolidation evals

The system rewrites its own memory and self-prompt daily, but nothing measures
whether consolidation quality improves: today it is self-evolving, not
self-measuring. The runner already gates completion on *activity* (a rewritten
handoff, a shrunk LEARNINGS file); the goal is an eval harness over the
brain's own output — journal accuracy against the ledger, handoff prediction
hit rates over time, entity-note quality — so "self-learning" becomes a
measured claim instead of an aspiration. The same harness would give spend a
denominator (see the honest limit in
[docs/token-economy.md](docs/token-economy.md)).

## 3. Runner migration

`brain-loop.sh` is ~750 lines of load-bearing bash: the idle and offline
gates, the presence gate, the awake-clock watchdog, failure classification,
VITALS. It works, and its comments carry a lot of operational history, but
bash 3.2 is a hostile substrate for logic this important. The goal is to fold
the shift runner into the typed Swift binary — same gates, same budgets, same
one-session-per-day model — while keeping the two-process boundary exactly as
it is: capture must never depend on the brain.

## Secret scrubbing in capture

The shell-history connector captures commands verbatim — including exported API
keys and tokens typed into the terminal, which then live in the ledger. Planned:
pattern-based scrubbing at capture time (common token shapes, `export KEY=`,
`Authorization:` headers) replacing matches with a presence marker, same policy
as private apps. Until then: treat the ledger file with the sensitivity of your
shell history, because it contains it.
