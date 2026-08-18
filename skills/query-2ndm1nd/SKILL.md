---
name: query-2ndm1nd
description: Queries the owner's 2ndm1nd second brain - the 2ndm1nd vault and capture ledger - and lands the answer in the project he is currently working in. Use whenever the owner says "my 2ndm1nd", "my second brain", "check my brain", "where did we leave off", "have I done this before", "what's the latest on", or asks what they were working on, decided, or learned previously.
---

# query-2ndm1nd — ask your second brain

Set `SECONDMIND_VAULT` to your vault path (the runtime's default layout is assumed:
`Atlas/AI/Brain/` for handoff and learnings, `Atlas/{Projects,People,Organizations}/`
for entity notes, the ledger at `~/Library/Application Support/2ndMind/brain.db`).
Copy this folder into your agent's skills directory.

You are not a search engine. Retrieve, then LAND it: the answer must say what it
means for the work in the current directory. Retrieval without consequence is noise.

## MUST — re-scan your draft before replying
- Non-public people, suppliers, clients → initials only.
- Booking / BL / invoice / case / order numbers → `[…]`. Money amounts → omit.
- Never read `Atlas/Personal/`. No health, family, or finances unless the owner explicitly asks.
- If any of the above appear in your draft, rewrite the draft. Then send.

## Output shape — exactly this, nothing more
1. **Answer** — at most 3 bullets. Only what the question asked.
2. **For <current project>** — at most 3 bullets: what this changes or implies for
   the code/work here. Mandatory whenever cwd is a project; derive the project from cwd.
3. **Source + freshness** — one line: which memory (handoff / learnings / note name /
   ledger) and the newest timestamp you actually saw.

No open-watches dumps, no side threads, no life status — unless asked for.

## Freshness protocol — MANDATORY for "latest / status / what happened" questions
1. Read the entity note; note the date of its newest dated line.
2. ALWAYS then check the ledger for anything newer on the topic:
   ```bash
   sqlite3 "$HOME/Library/Application Support/2ndMind/brain.db" \
     "SELECT datetime(ts,'unixepoch','localtime'), source, substr(replace(text,char(10),' '),1,160)
      FROM events WHERE id IN (SELECT rowid FROM events_fts WHERE events_fts MATCH '<topic>')
        AND ts > strftime('%s','<note date>')
      ORDER BY ts DESC LIMIT 15;"
   ```
   Mail events (`source='mail'`) are ground truth for negotiations and outcomes.
3. If the ledger holds anything newer than the note: the ledger wins. Lead with the
   newer truth and say plainly that the vault memory is N hours behind.
4. Never claim "nothing new" unless the query in step 2 actually returned zero rows.

## Surfaces
- Unscoped "where did we leave off" → `## GLANCE` block (first ~50 lines) of
  `$SECONDMIND_VAULT/Atlas/AI/Brain/HANDOFF.md`. Keep only what was asked.
- Lessons / "burned before?" → `$SECONDMIND_VAULT/Atlas/AI/Brain/LEARNINGS.md`.
- Named project/person/company → entity note in `$SECONDMIND_VAULT/Atlas/{Projects,People,Organizations}/`
  + backlinks: `grep -rl "[[<Name>]]" $SECONDMIND_VAULT/Atlas` + if a code project,
  `git -C <repo> log --oneline -10` and `status --short`. The interesting answers live
  in DISAGREEMENTS between vault story, repo state, and ledger.
- Anything else → the ledger FTS query above without the ts filter.
