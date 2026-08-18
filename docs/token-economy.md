# Token economy

The system runs against a personal Claude subscription, so model spend is a
first-class design constraint, not an afterthought. The theme running through
every mechanism below: **deterministic pre-filtering, bounded budgets, gated
invocation, resumable context.** Code does everything code can do; the model is
called only when there is something genuinely new to think about, with its
evidence already compiled.

Every mechanism here is traceable to a file in this repository.

## 1. Capture costs zero tokens, forever

The entire sensing layer is model-free (see
[architecture.md](architecture.md#the-capture-path-and-the-no-llm-boundary) and
[privacy.md](privacy.md) for the greps). The consequence for spend: token cost
is completely decoupled from capture volume. You can capture ten times more —
more sensors, more connectors, denser windows — and the model bill does not
move, because the ledger is written by code and read in batch.

This was learned, not assumed. An early event-driven design distilled events
with a model call per event and burned roughly 89 calls in a single day
(owner-reported; the surviving comment in
Sources/SecondMindKit/Sensors/InputSensor.swift records the directive:
"the periodic brain tick does all LLM work in batch; event-driven Opus calls
were burning the subscription"). Batch consolidation replaced it and the
per-event call path was removed entirely.

## 2. One session per day, resumed — not re-sent

brain-loop.sh keeps **one claude session id per calendar day**
(`$STATE_DIR/day-session-YYYYMMDD`) and every cycle resumes it with
`--resume <id>`; the id is read back from each cycle's JSON result
(`session_id`) and persisted for the next one. Context therefore accumulates
server-side in one conversation instead of being rebuilt and re-sent each hour
— a WAKE cycle's prompt is a short instruction block plus fresh evidence, not
the day's history.

The day boundary is the compression point: a new day starts a fresh session
whose boot context is the constitution plus **yesterday's HANDOFF letter** — a
deliberately compact, rewritten-whole summary — rather than raw history. The
letter is the day's memory at letter length; the raw events stay in the ledger
where the model can query them if it needs to.

## 3. Gates: most potential cycles never call the model

Two gates in brain-loop.sh turn quiet time into zero-cost time:

- **Idle gate.** `pending_events()` counts ledger events since the last
  successful fold (excluding mail and power, which arrive regardless of the
  human). Below `SECONDMIND_IDLE_MIN` (default 20) new events, the cycle is
  skipped: the deterministic health check still runs, and the runner re-looks
  in `SECONDMIND_IDLE_RECHECK` seconds (default 900). The in-code comment
  records why this rail exists: before it, overnight cycles burned ~$0.6–0.8
  each narrating "still asleep".
- **Offline gate.** `api_reachable()` is a transport-level probe of
  `api.anthropic.com` (any HTTP response counts as reachable). A dead network
  parks the runner for 600 s instead of launching a claude process into it —
  which previously wedged whole cycles.

Two further gates protect the *expensive* cycles specifically: the presence
gate defers a DREAM when the machine is on battery with no input for 15
minutes (a consolidation severed by system sleep is tokens spent for nothing),
and failure classification refunds the day's session slot only when the cycle's
reported `total_cost_usd` shows no real reasoning happened (`cost < 0.10`) —
so a misclassified expensive cycle can't hand back a slot whose tokens were
genuinely spent.

## 4. Cadence is the user-facing spend dial

The launchd template `plists/org.2ndm1nd.brain.plist` sets the budget keys as
environment variables, which brain-loop.sh reads with defaults:

| key | template value | script default | meaning |
|---|---|---|---|
| `SECONDMIND_MIN_RELAUNCH` | 10800 | 3600 | floor between cycles (seconds) — ~3 h as shipped, hourly when unset |
| `SECONDMIND_MAX_SESSIONS` | 9 | 26 | hard daily cap on cycles |
| `SECONDMIND_CYCLE_MAX` | 2700 | 1800 | per-cycle time budget (seconds); DREAM and MORPH get 2× |
| `SECONDMIND_IDLE_MIN` | — | 20 | new-event threshold below which a cycle is skipped |

The deep consolidation (DREAM) is once per day by marker regardless of
cadence, and the relaunch floor is persisted across runner restarts so a
crash-loop cannot burn cycles. Turning the whole dial down to "one
consolidation per day and nothing else" is a plist edit, not a code change.
The per-cycle watchdog counts *awake* seconds, not wall seconds, so a sleeping
Mac cannot consume a cycle's budget while suspended.

On the Swift side, `ClaudeGate` (Sources/SecondMindKit/ClaudeRunner.swift)
serializes all scheduled model calls — at most one claude subprocess at a
time, ever — and a usage-limit response is thrown as its own error class so
callers cool down instead of retrying into a closed window.

## 5. Deterministic jobs do the mechanical work

The app's Scheduler (Sources/SecondMindApp/main.swift, `wireJobs()`) runs
sessionize, retention, connectors and eventkit on cadence — all pure code. The
model never spends tokens turning raw events into activity spans, pruning old
rows, or pulling browser history: a query can do that, so a query does.

The same principle runs the pre-cycle instruments (`*.py`): before each model
cycle, brain-loop.sh regenerates the digest, deltas, co-activation table,
communities, rhythm, register and the rest deterministically. The in-code
rationale: "the model spends its turns on cognition, not exploratory SQL —
code guarantees completeness; a model can only intend it." Token cost aside,
this is also a quality mechanism: a script enumerates every event in the
window; a model sampling the ledger by querying would miss some.

## 6. Targeted retrieval, not vault-dumping

The vault is never injected wholesale. `brain-prime.py` reads the newest
ledger text since the watermark (at most 800 events / 250,000 characters),
matches it word-boundary against entity note names and aliases, and injects
only the top-scoring notes — the runner invokes it with `--max-files 8
--max-bytes 14000`, and each primed note is capped at 2,200 characters. The
model wakes with the *relevant* memories loaded instead of either searching
for them (tool-call turns) or receiving everything (context bloat).

For everything else, retrieval is pull, not push: the FTS5 ledger answers
"what happened" queries deterministically through the `brain` CLI
(`brain search`, `brain query "SELECT …"`), so evidence enters the context
only when the model actually asks for it.

## 7. Bounded context surfaces

The files that enter every prompt have explicit budgets, measured from outside
the model:

- **SELF.md** — stated budget `SECONDMIND_SELF_MAX_BYTES` (6,000 bytes). The
  runner measures the real size every cycle and injects the percentage into
  the VITALS block, because (in-code rationale) "a budget the model cannot see
  is not a budget." The Cortex write path additionally hard-rejects any
  SELF.md write over 16 KB in code (`applyWrite`, Cortex.swift).
- **LEARNINGS.md** — caps at 600 lines *and* 60,000 bytes
  (`LEARNINGS_MAX_LINES` / `LEARNINGS_MAX_BYTES`); crossing either makes a
  monthly METAMORPHOSIS cycle due, whose explicit job is compression.
- **HANDOFF.md** — the day-boundary compression: rewritten whole each DREAM,
  "a letter and a pointer, not an archive" (CortexFallbackPrompts.swift).

Upstream of all of this, signal control at the sensor level is token control:
the filesystem sensor was deleted outright when raw FSEvents proved to be
~96 % of ledger volume as low-signal noise (comment in
Sources/SecondMindKit/Sensors/SensorHub.swift) — "what did I work on" comes
from the git/IDE/shell connectors and focus context instead. Noise that never
enters the ledger is noise the digest never compiles and the model never reads.

## The honest limit

There is no per-cycle token metering or spend report today. The runner reads
`total_cost_usd` from each cycle's JSON result, but only to decide slot
refunds — nothing aggregates cost per day, per cycle kind, or over time, and
nothing correlates spend with consolidation quality. That last correlation is
the same gap as [ROADMAP.md](../ROADMAP.md)'s consolidation-evals item: a
system that measured what a DREAM produced could also say what it cost to
produce it.
