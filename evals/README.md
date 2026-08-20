# Consolidation evals

The project's own roadmap admits the problem: the brain is self-evolving but
not self-measuring. It rewrites its memory every day, and the runner only
checks that the rewrite *happened* — a changed handoff, a smaller learnings
file — never whether it was any good. This directory is the deterministic half
of that roadmap item delivered: measurable claims about consolidation quality
instead of aspirations.

No LLM, no network, no dependencies beyond the Python 3 standard library.
The ledger is opened read-only; nothing here writes to your vault.

## Run it against your own instance

```bash
python3 evals/run.py \
  --vault ~/path/to/your/vault \
  --ledger "$HOME/Library/Application Support/2ndMind/brain.db"
```

Add `--json` for machine-readable output. The brain directory (the folder
holding `HANDOFF.md`, `LEARNINGS.md`, `journal/`) is auto-detected anywhere
under `--vault`; pass `--brain-dir` to name it exactly. Exit code is 0 only
when every check passes.

## The checks

**staleness-honesty** — how far behind reality is the memory, and is the
handoff honest about it. The handoff carries its own coverage claims: the
wake timestamp in the glance, the written-date in the letter footer, the
consolidated-through marker in the status section. The check parses the
latest of those and compares it to the newest event in the ledger (future-
timestamped rows, e.g. calendar entries, are ignored). Measured value: hours
of captured evidence newer than what the handoff claims to cover. Fails above
36 hours — one missed night plus slack — or immediately if the handoff claims
coverage of a moment that hasn't happened yet, because a memory that lies
about its own recency is worse than a stale one.

**redaction-hygiene** — leaks in brain-written prose. Scans only the surfaces
the brain itself writes (handoff, learnings, journals) for raw email
addresses, unbroken digit runs of 8+ (booking/invoice/account shapes), and
secret-shaped tokens (the shapes named by the roadmap's secret-scrubbing
item: common API-token prefixes, exported KEY/TOKEN/SECRET assignments,
authorization headers, long hex). Measured value: total leak count, broken
down per surface. Fails on anything above zero.

**structure-contract** — does the handoff keep the shape its own constitution
mandates: a glance section first (at most 5 lines, standing alone), then
sections for what happened, dated falsifiable beliefs, ripening items, open
questions, and predictions for the next cycle to grade. The section names are
matched by keyword, so emoji and phrasing may drift. Measured value: fraction
of required sections present.

**coverage** — does dreaming keep up with living. For each day in the window
(default 14) where the ledger holds at least 5 events, the check wants either
a journal file dated that day or a journal within the next 3 days that names
it (the runner folds a missed day into the next sleep, and that counts —
late is not lost). Measured value: fraction of ledger-active days
consolidated. Fails below 0.9.

## What a score does and does not claim

A passing run says the memory is fresh, honestly labeled, structurally
intact, complete day-over-day, and free of the leak shapes above. It does
**not** say the journal is *true* — a fluent, well-shaped consolidation can
still misattribute a quote or invent a connection. Factual consistency
requires judgment, which requires a model; [judge.md](judge.md) documents a
manual spot-check recipe for exactly that, and deliberately keeps it out of
CI.

## Our own instance fails this today

Run against the authors' live instance, staleness-honesty, structure-contract
and coverage pass — and **redaction-hygiene fails**: email addresses and long
digit runs sit in the handoff and journals, because the roadmap's
secret-scrubbing item is not shipped and the brain faithfully quotes what
capture recorded. The check is kept strict anyway.
That is the point of an eval harness: it reports the system you have, not the
system you describe. When scrubbing ships, this number is how we will know it
works.

## Fixtures and tests

`fixtures/build.py` generates a tiny synthetic vault and ledger (invented,
neutral content; dates relative to now) in two modes: `healthy` passes every
check, `broken` fails every one — a future-dated coverage claim, a leaked
email/token/order number, missing sections, an oversized glance, journal
gaps. `test_evals.py` (stdlib unittest) runs the harness over both and pins
the verdicts; CI runs it on every push:

```bash
python3 -m unittest discover -s evals
```
