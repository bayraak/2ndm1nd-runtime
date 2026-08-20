# Manual judge: factual-consistency spot check

**This is a documented recipe, not a tool.** It is not wired into CI and
should not be: it costs a model call per sample, its verdicts are not
deterministic, and a model grading a model on every push is spend without a
baseline. Run it by hand, occasionally, when you want to know whether the
journal is *true* — the question [run.py](run.py) deliberately does not
answer.

## The idea

The journal is the brain's L2: dated observations that are supposed to be
traceable to ledger evidence. The spot check samples claims from a journal
entry, pulls the ledger rows for that day, and asks a model one narrow
question per claim: is this claim supported by, contradicted by, or absent
from the evidence?

## Recipe

1. Pick a recent journal day and extract a handful of checkable claims —
   sentences that assert something concrete happened (a commit landed, a
   message was sent, a file was edited). Skip interpretation and mood.

2. Dump that day's ledger evidence (read-only):

   ```bash
   sqlite3 "file:$HOME/Library/Application Support/2ndMind/brain.db?mode=ro" \
     "SELECT time(ts,'unixepoch','localtime'), source, kind, substr(text,1,200)
      FROM events
      WHERE date(ts,'unixepoch','localtime') = '2026-08-19'
      ORDER BY ts" > /tmp/evidence-2026-08-19.txt
   ```

   For a targeted claim, FTS is cheaper than the full day:

   ```bash
   sqlite3 "file:...brain.db?mode=ro" \
     "SELECT e.ts, substr(e.text,1,200) FROM events_fts f
      JOIN events e ON e.id = f.rowid
      WHERE events_fts MATCH 'your search terms' LIMIT 50"
   ```

3. Ask a headless model to grade, one claim at a time:

   ```bash
   claude -p "You are grading a memory system's journal against raw evidence.
   Claim (verbatim from the journal): <paste one claim>
   Evidence (captured events from that day): $(cat /tmp/evidence-2026-08-19.txt)
   Answer with exactly one of SUPPORTED / CONTRADICTED / NOT-IN-EVIDENCE,
   then one sentence citing the specific evidence line (or its absence)."
   ```

4. Score the sample: `supported / total` is the day's consistency rate.
   Anything CONTRADICTED deserves a manual look before you trust the number —
   the judge is sometimes wrong, and the point of the exercise is the reading,
   not the percentage.

## Caveats, honestly

- Each graded claim is a model call you pay for. A 10-claim sample is cheap;
  grading every journal line every day is not, and would itself need evals.
- NOT-IN-EVIDENCE is not automatically a fabrication: the brain also reads
  files and yesterday's handoff, so a claim can be true with its evidence
  outside the sampled window. Widen the evidence before concluding.
- The evidence dump is your own captured life. It stays on your machine, but
  it does pass through the model call — same trust boundary as the brain's
  own consolidation, no wider.
