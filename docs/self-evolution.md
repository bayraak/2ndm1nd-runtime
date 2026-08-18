# The self-evolution envelope

The brain rewrites itself every day. This document is precise about what
"itself" means: which surfaces the model may change, where the hard boundary
sits, and why the boundary is a set of code paths rather than a set of
instructions. Every claim names the code that makes it true.

## What the brain may rewrite

The model's write surface is vault markdown, and inside it the prompts
(CortexFallbackPrompts.swift, plus the seeded constitution in
`Cortex.ensureBrainScaffold`) authorize:

- **SELF.md** — its own self-prompt. The seed file says it plainly: "This file
  is mine: each tick I may rewrite it as I learn what matters."
- **HANDOFF.md** — the letter each day's session writes to the next,
  rewritten whole.
- **LEARNINGS.md** — compounding lessons, `[user]` and `[self]` tagged,
  superseded with strikethrough rather than deleted.
- **The journal** (`Atlas/AI/Brain/journal/<day>.md`) — mandatory every
  session; visible reasoning, not conclusions.
- **The entity graph** — `Atlas/Projects`, `Atlas/People`,
  `Atlas/Organizations`, `Atlas/Memory/topics`: dated, wikilinked, factual.
- **Atlas/Mind** — the brain's self-organized universe: ontology, story,
  skills, and *proposals* (more on those below).
- Dashboard and digest surfaces: `Now.md`, `WEEKLY.md`, daily/weekly digests.

Two enforcement layers define this surface. The kernel sandbox
(`ClaudeRunner.ensureSandboxProfile`, ClaudeRunner.swift) write-denies the
entire vault, then allows back exactly `Atlas/AI`, `Atlas/Memory`,
`Atlas/Projects`, `Atlas/People`, `Atlas/Organizations`, `Atlas/Mind`,
`Atlas/Ideas`. The Cortex WRITE-block path applies the same list in code
(`writeWhitelist`, Cortex.swift), rejecting anything else "regardless of what
the model outputs."

One honest inclusion: the constitution itself (`Atlas/AI/Brain/PROMPT.md`)
lives on the writable surface. It is seeded once and from then on the brain
may rewrite it. So the evolving side of the line contains the brain's
knowledge, its voice, its model of the owner, *and its own instructions*. What
it does not contain is anything that decides when the brain runs, what it can
spend, or what it can reach.

## What it can never touch — and the code path for each

These are structural claims, not policy claims: for each there is a mechanism
with no code path around it, all in `ensureSandboxProfile`
(ClaudeRunner.swift) unless noted. The sandbox is `sandbox-exec` at the OS
level and is inherited by every process the model spawns, Bash included.

| surface | why it is out of reach |
|---|---|
| The runner (`brain-loop.sh`) and binaries | The deployed runtime at `~/.local/share/2ndm1nd` is write-denied. The source tree is inside the vault (write-denied except the Atlas allow-backs) — and even a hypothetical source edit would be inert, because what launchd runs is the deployed copy, refreshed only by a human running `make v2-install` / `v2-sync-scripts`. |
| Its own cadence | The wake/pause/marker state lives in `~/Library/Application Support/2ndMind/brain-runtime`, which is explicitly write-denied — the model cannot touch its own wake file, session counters, DREAM markers, or fold watermark. The budget env keys (`SECONDMIND_MIN_RELAUNCH`, `SECONDMIND_MAX_SESSIONS`, …) live in the launchd plist, and `~/Library/LaunchAgents` is write-denied too. The runner decides when the brain wakes; the human decides the runner's settings. |
| Its budgets | `SELF_MAX_BYTES`, `LEARNINGS_MAX_LINES/BYTES`, the cycle caps and the session cap are variables of the deterministic runner, measured and enforced outside the loop being audited. The auditor is not the audited: the model can fill its files, but the thing that measures them and decides consequences (a forced METAMORPHOSIS, a refused completion marker) is bash it cannot edit. |
| The capture path | A separate process in a separate launchd job, containing no model call (see [architecture.md](architecture.md)). Nothing the brain writes is executed by capture; the one ingestion channel from claude-session logs back into the ledger explicitly drops the brain's own transcripts by sentinel check (`isBrainSessionFile`, Connectors.swift), closing the feedback loop. |
| The ledger schema | Defined by GRDB migrations compiled into the Swift binary (EventStore.swift). The brain's write-back channel to the ledger is `brain annotate` — an insert-only sidecar database; the raw events table is never edited, and a later annotation supersedes an earlier one, so even corrections leave history intact. |
| Credentials | Read-denied outright — `~/.ssh`, `~/.aws`, gcloud, `~/.cloudflared`, the vault's MCP env file. The brain is mandated to explore the disk read-only for evidence, so secrets are made unreadable, not merely unwritable. |

The escape hatch is deliberate and human-shaped: **proposals.** When the brain
diagnoses a problem with its own rails — a gate misfiring, a budget set wrong —
it writes a proposal into `Atlas/Mind/proposals` (writable) and waits. The
Makefile's `proposals` target is the doorbell, and its own text states the
contract: "These are the brain's own diagnoses of its rails — it CANNOT apply
them (the sandbox denies it write access to its runner, by design). Nothing
happens until you decide."

## Why the boundary is structural

The owner's thesis, applied here as everywhere else in his work: a control
enforced by instruction eventually gets bypassed, so put the guarantee where
there is no code path around it. A system that could widen its own envelope
would eventually do so — not necessarily by intent; by drift, by a
plausible-sounding self-edit, by an injected instruction in captured text it
later reads. So the envelope is amendable only from outside: a human editing
the runner, the plist, or the sandbox profile generator.

The codebase carries its own evidence that instruction-level control fails.
Before the kernel sandbox, write discipline was a prompt convention — and a
comment in ClaudeRunner.swift records the outcome: "enforcement is the kernel,
not a prompt convention (which it forgot: a session once narrated writes it
never made)." The model was honest in intent and wrong in fact; only the
sandbox made the question moot in both directions — it can no longer fail to
write where it may, or write where it may not.

Self-evolution of knowledge, never of authority.

## VITALS: governed self-editing

Inside the envelope, self-editing is not unsupervised. Every cycle prompt
carries a VITALS block computed by the runner (`vitals()`, brain-loop.sh) —
facts about the brain's own behavior it cannot dispute, because it did not
produce them. The in-code rationale: "a rail the model cannot see is not a
rail."

The measured values are SELF.md's byte size against its stated budget and its
age in days, LEARNINGS.md's line and byte counts, the count and age of
proposals awaiting the human, DREAM coverage over the last 14 days, ledger
backup age, and the unresolved-attribution backlog. The prompt text then holds
the brain to its own constitution with that evidence — from the actual rail:

> "SELF.md: … bytes against a stated budget of … Your constitution says
> 'prune as hard as you add' and you have not: since the August MORPH it took
> 85 insertions against 29 deletions. A fresh mtime is NOT health — editing
> daily while never cutting is an append log wearing a self-prompt's name. If
> you are over budget, the next edit must remove more than it adds."

(The byte counts and ages are computed live each cycle; the insertion/deletion
history in that sentence is owner-observed evidence written into the rail
text.)

The same principle gates completion. A DREAM only marks the day consolidated
if `HANDOFF.md`'s hash actually changed; a METAMORPHOSIS only marks the month
done if SELF.md's hash or LEARNINGS' length actually moved. Exit code 0 proves
the process ran; only a diff proves work. And after each clean cycle the
*runner* commits `Atlas/AI/Brain` and `Atlas/Mind` to git — undo for
over-aggressive compression, tamper-evidence for the model-writable prediction
board, and pre-registration for predictions, none of which the model can skip
or narrate as done.

## Honest limits

- **Evolution is not yet measured for quality.** The markers above prove
  activity (a rewritten letter, a shrunk LEARNINGS), not improvement. Nothing
  scores whether this month's SELF.md steers better than last month's, or
  whether consolidations are getting more accurate. That is
  [ROADMAP.md](../ROADMAP.md)'s consolidation-evals item, and until it exists,
  "self-improving" is an architecture here, not a result.
- **The envelope is a deny-list plus process boundaries, not a capability
  system.** The brain holds real Bash and has network egress (curl is on
  PATH); the sandbox denies the writes and reads that matter rather than
  enumerating what is allowed. Practically: the known gaps are handled
  point-wise — the ledger's directory must stay writable for SQLite WAL, so
  raw-ledger integrity rests on tooling convention (read-only connections, the
  insert-only annotation sidecar) rather than the kernel; and because captured
  text written by other people flows into the brain's reading material, prompt
  injection is treated as real, with the mitigation being that credential
  files are unreadable rather than that injection is impossible. A human
  auditing the envelope should read `ensureSandboxProfile` top to bottom; it
  is one function, and it is the whole boundary.
