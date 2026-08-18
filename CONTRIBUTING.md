# Contributing

This is a personal system published as-is, but issues and pull requests are
welcome. Small, focused changes have the best odds.

## Build and test

```bash
swift build                      # or: swift build -c release
swift test                       # SecondMindKit tests
python3 -m compileall -q *.py mcp   # Python syntax (what CI runs)
for f in *.sh; do bash -n "$f"; done # shell syntax against bash 3.2 semantics
```

CI (.github/workflows/ci.yml) runs exactly these four steps on macOS 15. Note
that `brain-loop.sh` must parse under macOS's system bash **3.2** — the
Makefile refuses to deploy it otherwise, and the script's comments record real
3.2 parser traps (e.g. no apostrophes inside a quoted heredoc nested in
`$( )`).

## The invariant

**Nothing in the capture path may call a model.** Sensors, connectors, the
event store, the sessionizer and the scheduler are model-free by construction,
and the entire privacy and cost story rests on that
([docs/privacy.md](docs/privacy.md), [docs/token-economy.md](docs/token-economy.md)).
A PR that introduces a model call into capture — directly, via a scheduled
job, or by making capture depend on the brain process — will be rejected on
principle, regardless of what it gains. Model work belongs in the brain
process, in batch, behind its gates.

If you touch the privacy floor (`never_record` handling, the sandbox profile,
the presence-marker semantics), update docs/privacy.md in the same PR — its
verification greps are asserted against this repo's contents.

## Most wanted: brain providers

The brain speaks to exactly one provider today: the `claude` CLI. The seam is
two call sites — `Sources/SecondMindKit/ClaudeRunner.swift` and the invocation
block in `brain-loop.sh` — and there is deliberately no speculative provider
interface waiting in the code; the abstraction should be introduced by the
first real second provider ([ROADMAP.md](ROADMAP.md), item 1).

Derived from how the runner is actually invoked, a provider must offer:

- **Headless one-shot invocation** — prompt in (stdin on the Swift side;
  argv on the runner side), complete response out, process exits.
- **Text and JSON output** — the Swift path consumes plain text; the shift
  runner consumes JSON and reads `session_id` and an `is_error` flag from it.
- **Session resume by id** — the brain's day is one accumulating conversation
  (`--resume <id>` per cycle). A provider without resumable sessions would
  need to emulate this (e.g. by replaying context), and should say so
  honestly in its docs.
- **Classifiable failures** — meaningful exit codes plus recognizable
  usage-limit / auth / network error text; the runner's backoff logic keys on
  these classes.
- **Sandbox compatibility** — the process (and its children) must tolerate
  running under `sandbox-exec` with the write/read denials described in
  [docs/self-evolution.md](docs/self-evolution.md).

A fully local model behind this seam makes the whole system offline, which is
the roadmap's headline goal.

## Code style

Match the file you are editing. Concretely: Swift 6 with strict concurrency
(annotate isolation deliberately, no `@unchecked` without a stated reason);
Python is stdlib-only for the runtime instruments; comments in this codebase
explain *why* — often with the date and the failure that taught the lesson —
and that convention is worth keeping. No new runtime dependencies without a
strong case (GRDB is currently the only one).
