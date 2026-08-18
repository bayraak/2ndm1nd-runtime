#!/usr/bin/env bash
# brain-loop.sh — the SHIFT RUNNER for the living second-brain session
# (polymorph pattern). A dumb outer loop: ONE claude session id per DAY,
# resumed every ~hour for ONE cycle, killed and recreated at the day boundary.
#
# SAFETY (other projects run their OWN `claude -p` — e.g. polymorph — and we must
# NEVER touch them): we identify OUR session three ways, and use ONLY these —
# never a broad `pkill -f "claude -p"`:
#   1. a unique sentinel token in the boot prompt (SENTINEL below),
#   2. the exact child PID we launched (recorded in PIDFILE),
#   3. kill_tree() — recurse pgrep -P from OUR pid only, never a name match.
set -uo pipefail

SENTINEL="2NDM1ND-BRAIN-SESSION"   # unique marker; how anything identifies OUR session
BIN="$HOME/.local/share/2ndm1nd/bin/2ndm1nd"
CLAUDE="$HOME/.local/bin/claude"
BINDIR="$HOME/.local/share/2ndm1nd/bin"
VAULT="$HOME/Projects/2ndm1nd"
BRAIN_DIR="$VAULT/Atlas/AI/Brain"
DB="$HOME/Library/Application Support/2ndMind/brain.db"
ANNOT_DB="$HOME/Library/Application Support/2ndMind/annotations.db"
BACKUP_DIR="$HOME/Library/Application Support/2ndMind/backups"
# Runtime state lives OUTSIDE the git vault (no dotfile churn in Obsidian/git).
STATE_DIR="$HOME/Library/Application Support/2ndMind/brain-runtime"
PAUSE_FILE="$STATE_DIR/paused"
PIDFILE="$STATE_DIR/session.pid"
WAKE_FILE="$STATE_DIR/wake"
LASTCYCLE_FILE="$STATE_DIR/last-cycle-ts"   # epoch of the last SUCCESSFUL fold
STREAK_FILE="$STATE_DIR/fail-streak"        # consecutive failed cycles (drives escalating backoff)
LOGDIR="$HOME/Library/Logs/2ndm1nd"
LOG="$LOGDIR/brain-loop.log"
# Instrument stdout goes to its OWN log: the pre-cycle generators (npmi tables,
# rhythm/register dumps) drowned the runner's own lines in brain-loop.log, which
# is the audit trail AND the thing the brain will read as its vital signs.
ILOG="$LOGDIR/instruments.log"

# Model (2026-07-12, hardened 2026-07-14): a headless `claude -p` won't stay
# alive looping 24h (it ends its turn after a cycle). So the RUNNER is the loop
# AND the CONVERSATION persists: each hourly cycle `--resume`s the SAME session
# id, so context accumulates all day (the brain remembers every prior cycle).
# A NEW day = a fresh session whose FIRST cycle is the DREAM (consolidation of
# yesterday); continuity across days is the HANDOFF letter.
CYCLE_MAX_SECS="${SECONDMIND_CYCLE_MAX:-1800}"        # per-cycle hard-kill backstop (30 min; dream gets 2x)
MIN_RELAUNCH_SECS="${SECONDMIND_MIN_RELAUNCH:-3600}"  # cycles ~hourly (never faster; persisted across restarts)
MAX_SESSIONS_PER_DAY="${SECONDMIND_MAX_SESSIONS:-26}" # ~1 cycle/hour across a day + slack
IDLE_MIN_EVENTS="${SECONDMIND_IDLE_MIN:-20}"          # idle gate: skip the claude call below this many new events
IDLE_RECHECK_SECS="${SECONDMIND_IDLE_RECHECK:-900}"   # …and how often to re-look while idle
MODEL="${SECONDMIND_MODEL:-claude-opus-4-8}"
EFFORT="${SECONDMIND_EFFORT:-max}"
# METAMORPHOSIS (2026-08-05): structural maintenance — LEARNINGS compression, the
# SELF.md rewrite, ONTOLOGY/STORY — used to be queued INSIDE the DREAM, i.e. inside
# the one cycle that fails most often. It was "deferred honestly" every single time.
# It now has its own cycle kind, gated by its own monthly marker, so it can never
# again be the thing that loses the race with a watchdog.
LEARNINGS_MAX_LINES="${SECONDMIND_LEARNINGS_MAX:-600}"  # above this a MORPH cycle is due
# Lines were the wrong unit: each lesson is ONE very long line (~818 B), so the file
# grew 33,575 -> 43,392 B while the line count moved 427 -> 463 and never neared 600.
# A file can reach 100 KB at 500 lines and never trip a line cap.
LEARNINGS_MAX_BYTES="${SECONDMIND_LEARNINGS_MAX_BYTES:-60000}"
# SELF.md's stated budget lives in CortexFallbackPrompts.swift as "<=6000 chars, prune
# as hard as you add" — as PROMPT TEXT ONLY. Nothing enforces it, PROMPT.md never
# mentions it, and the brain has therefore never once referred to it. It sits at 219%.
# A budget the model cannot see is not a budget; VITALS carries the number now.
SELF_MAX_BYTES="${SECONDMIND_SELF_MAX_BYTES:-6000}"
SELF_STALE_DAYS="${SECONDMIND_SELF_STALE_DAYS:-10}"     # SELF.md untouched this long forces a MORPH

mkdir -p "$LOGDIR" "$STATE_DIR"
export PATH="$BINDIR:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export SECONDMIND_STATE_DIR="$STATE_DIR"
unset ANTHROPIC_API_KEY
ts() { date "+%Y-%m-%dT%H:%M:%S%z"; }
log() { echo "[$(ts)] $*" >> "$LOG"; }
day_count_file() { echo "$STATE_DIR/sessions-$(date +%Y%m%d)"; }

# Recursively kill ONLY the tree rooted at our own pid (never a name match).
kill_tree()  { local p=$1; for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c";  done; kill "$p" 2>/dev/null || true; }
# SIGKILL escalation: a claude wedged in connection-retry survives SIGTERM
# (2026-07-14: two 80+ min cycles sailed past the 30-min watchdog).
kill_tree9() { local p=$1; for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree9 "$c"; done; kill -9 "$p" 2>/dev/null || true; }

cur_cpid=""
cleanup() {
    # On our own exit (incl. launchd SIGTERM), take down ONLY our session tree.
    [[ -n "$cur_cpid" ]] && kill_tree "$cur_cpid"
    rm -f "$PIDFILE"
}
trap cleanup EXIT TERM INT

# Interruptible sleep: `make v2-brain-wake` (touch $WAKE_FILE) ends the wait
# early and sets WOKEN=1, which bypasses the floor + idle gate ONCE.
WOKEN=0
park() {
    local end=$(( $(date +%s) + $1 ))
    while (( $(date +%s) < end )); do
        if [[ -f "$WAKE_FILE" ]]; then rm -f "$WAKE_FILE"; WOKEN=1; log "wake signal — resuming early"; return; fi
        sleep 15
    done
}

# Escalating backoff keyed to the CONSECUTIVE failure count. A single missing
# regex alternation ("weekly limit") let the runner grind hourly through every
# slot for three days (2026-07-25→27) and go dark. Classification can always
# miss the next unknown string; this is the rail that does not depend on knowing
# what went wrong. $1 = base seconds for this failure class.
streak_park_secs() {
    local base=$1 n=${streak:-1} p
    (( n < 1 )) && n=1
    (( n > 6 )) && n=6
    p=$(( base * (1 << (n - 1)) ))
    (( p > 21600 )) && p=21600      # 6h ceiling
    echo "$p"
}

# Events worth reasoning about since the watermark. Mail is excluded (folded by
# its own rowid cursor, and inbound mail arrives while he sleeps); power fires
# on sleep/wake regardless of him. A failed query returns "run anyway".
pending_events() {
    local n
    n="$(sqlite3 -readonly "$DB" \
        "SELECT COUNT(*) FROM events WHERE ts > $1 AND ts <= strftime('%s','now') AND source NOT IN ('mail','power');" 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 999999
}

# Any HTTP response (even 4xx) = reachable; only a transport failure (DNS,
# refused, timeout) parks us. Launching claude into a dead network wedges the
# cycle — the 2026-07-14 morning lesson.
api_reachable() { curl -s -o /dev/null --max-time 8 "https://api.anthropic.com"; }

# The deterministic half of the health check — runs on idle skips too, so
# capture recovery never waits for evidence to pile up.
capture_health() {
    if ! pgrep -q -f "$BINDIR/2ndm1nd$"; then
        log "health: capture app DOWN — kickstarting org.2ndm1nd.app"
        launchctl kickstart -k "gui/$(id -u)/org.2ndm1nd.app" 2>/dev/null || true
    fi
    # Mail capture depends on Mail.app FETCHING (the connector only reads the
    # Envelope Index). Closed Mail.app = silent mail blackout (caught 2026-07-18,
    # 24h of zero mail during container week). Keep it alive, in the background.
    if ! pgrep -xq Mail; then
        log "health: Mail.app not running — starting in background (mail capture depends on it)"
        open -g -a Mail 2>/dev/null || true
    fi
}

# LEDGER BACKUP (2026-08-18). brain.db is the one irreplaceable organ here: 123k
# events, no copy anywhere, WAL on a single SSD. A disk failure erased everything and
# no amount of money got it back. `.backup` is live-safe; `cp` can tear a WAL database.
# HONEST LIMIT: this is the SAME disk. It defends against corruption, a bad write and
# accidental deletion — NOT against the drive dying. Off-disk needs a destination only
# he can attach, so VITALS carries the age and the limitation stays visible rather than
# being quietly mistaken for safety.
backup_ledger() {
    local m="$STATE_DIR/backup-done-$(date +%Y%m%d)" d f
    [[ -f "$m" ]] && return 0
    mkdir -p "$BACKUP_DIR"
    d="$(date +%Y%m%d-%H%M)"
    if sqlite3 "$DB" ".backup '$BACKUP_DIR/brain-$d.db'" 2>/dev/null; then
        sqlite3 "$ANNOT_DB" ".backup '$BACKUP_DIR/annotations-$d.db'" 2>/dev/null || true
        touch "$m"
        for f in $(ls -1t "$BACKUP_DIR"/brain-*.db 2>/dev/null | tail -n +8); do rm -f "$f" "$f-shm" "$f-wal"; done
        for f in $(ls -1t "$BACKUP_DIR"/annotations-*.db 2>/dev/null | tail -n +8); do rm -f "$f" "$f-shm" "$f-wal"; done
        log "ledger backup ok -> brain-$d.db"
    else
        log "ledger backup FAILED — brain.db has no fresh copy (see VITALS)"
    fi
}

# Age in days of the newest ledger backup; -1 if none exists.
backup_age_days() {
    local newest
    newest="$(ls -1t "$BACKUP_DIR"/brain-*.db 2>/dev/null | head -1)"
    [[ -n "$newest" ]] || { echo -1; return; }
    file_age_days "$newest"
}

# Age of a file in whole days; -1 when it does not exist.
file_age_days() {
    [[ -f "$1" ]] || { echo -1; return; }
    local m; m="$(stat -f %m "$1" 2>/dev/null || echo 0)"
    echo $(( ( $(date +%s) - m ) / 86400 ))
}

# Is a METAMORPHOSIS pass due? At most one per calendar month (marker), triggered
# by real pressure: LEARNINGS grown past its cap, a stale self-prompt, or month-start.
morph_due() {
    [[ -f "$STATE_DIR/morph-done-$(date +%Y%m)" ]] && return 1
    local ll sa
    ll="$(wc -l < "$BRAIN_DIR/LEARNINGS.md" 2>/dev/null | tr -d ' ')"; [[ -n "$ll" ]] || ll=0
    (( ll > LEARNINGS_MAX_LINES )) && return 0
    local lb; lb="$(wc -c < "$BRAIN_DIR/LEARNINGS.md" 2>/dev/null | tr -d ' ')"; [[ -n "$lb" ]] || lb=0
    (( lb > LEARNINGS_MAX_BYTES )) && return 0
    sa="$(file_age_days "$BRAIN_DIR/SELF.md")"
    (( sa >= SELF_STALE_DAYS )) && return 0
    (( 10#$(date +%d) <= 3 )) && return 0
    return 1
}

# VITALS — the brain's OWN health, computed deterministically and injected into
# every prompt. Rationale (2026-08-05): the runner used to log shift-protocol
# misses to a file the brain never reads, so a warning changed nothing. A rail
# the model cannot see is not a rail. Now its staleness, its backlog and his
# unanswered proposals are part of its evidence, every cycle.
vitals() {
    local self_age learn_lines prop_open prop_oldest dream_hits p d i
    self_age="$(file_age_days "$BRAIN_DIR/SELF.md")"
    learn_lines="$(wc -l < "$BRAIN_DIR/LEARNINGS.md" 2>/dev/null | tr -d ' ')"; [[ -n "$learn_lines" ]] || learn_lines=0
    prop_open=0; prop_oldest=0
    for p in "$VAULT"/Atlas/Mind/proposals/*.md; do
        [[ -f "$p" ]] || continue
        grep -qi "^status: *open" "$p" || continue
        prop_open=$(( prop_open + 1 ))
        d="$(file_age_days "$p")"; (( d > prop_oldest )) && prop_oldest=$d
    done
    dream_hits=0
    for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13; do
        [[ -f "$STATE_DIR/dream-done-$(date -v-${i}d +%Y%m%d)" ]] && dream_hits=$(( dream_hits + 1 ))
    done
    # Attribution gap. This lives in VITALS, not only in coverage.md, because
    # coverage.md is a SLEEP-only artifact: on 2026-08-05 a WAKE cycle wrote at
    # length about the attribution feature — having read it from HIS COMMIT — while
    # never once opening the meter that measures it, and called a shipped CLI verb
    # "proposed". A signal only one cycle-kind can see is a signal most cycles are
    # blind to. Resolution itself still belongs to SLEEP; awareness belongs everywhere.
    local unres bkage self_b learn_b
    bkage="$(backup_age_days)"
    self_b="$(wc -c < "$BRAIN_DIR/SELF.md" 2>/dev/null | tr -d ' ')"; [[ -n "$self_b" ]] || self_b=0
    learn_b="$(wc -c < "$BRAIN_DIR/LEARNINGS.md" 2>/dev/null | tr -d ' ')"; [[ -n "$learn_b" ]] || learn_b=0
    # Subtract what it has already resolved. A meter that cannot fall in response to
    # the work it demands teaches the model its effort is not measured — it would keep
    # re-resolving the same 19 events for 14 days, or stop believing the number.
    unres="$(sqlite3 -readonly "$DB" "ATTACH '$ANNOT_DB' AS ann;
        SELECT COUNT(*) FROM events e WHERE e.source='input' AND e.text IS NOT NULL
        AND json_extract(e.payload,'\$.addressee_unresolved') IS NOT NULL
        AND e.ts > strftime('%s','now') - 14*86400
        AND NOT EXISTS (SELECT 1 FROM ann.annotations a WHERE a.event_id=e.id AND a.key='to');" 2>/dev/null)"
    # ATTACH fails if the sidecar does not exist yet (no annotation ever written).
    if ! [[ "$unres" =~ ^[0-9]+$ ]]; then
        unres="$(sqlite3 -readonly "$DB" "SELECT COUNT(*) FROM events WHERE source='input'
            AND text IS NOT NULL AND json_extract(payload,'\$.addressee_unresolved') IS NOT NULL
            AND ts > strftime('%s','now') - 14*86400;" 2>/dev/null)"
    fi
    [[ "$unres" =~ ^[0-9]+$ ]] || unres=0
    printf '%s\n' \
      "--- VITALS (your own health, measured by the runner — not self-report) ---" \
      "SELF.md: ${self_b} bytes against a stated budget of ${SELF_MAX_BYTES} ($(( self_b * 100 / (SELF_MAX_BYTES>0?SELF_MAX_BYTES:1) ))%), last rewritten ${self_age}d ago. Your constitution says 'prune as hard as you add' and you have not: since the August MORPH it took 85 insertions against 29 deletions. A fresh mtime is NOT health — editing daily while never cutting is an append log wearing a self-prompt's name. If you are over budget, the next edit must remove more than it adds." \
      "LEARNINGS.md: ${learn_lines} lines / ${learn_b} bytes (MORPH fires above ${LEARNINGS_MAX_LINES} lines OR ${LEARNINGS_MAX_BYTES} bytes — bytes were added because your lessons are one long line each, so the line count stayed flat while the file grew 29%). Of the 12 lessons banked since 2026-08-05, ZERO are tagged [user] — the last thing you learned about HIM is dated 2026-07-24. You are learning your own plumbing well and him not at all; that is the wrong subject." \
      "Proposals of yours awaiting HIS decision: ${prop_open} (oldest ${prop_oldest}d). He cannot act on what he never sees: name them in the GLANCE, one line each, with the cost of continued inaction. That is the only doorbell you have." \
      "DREAM coverage: ${dream_hits}/14 of the last 14 days completed a deep consolidation. Days without one are days that were lived and never integrated." \
      "(Markers began 2026-08-05, so early coverage reads low for that reason alone — do not grade yourself on it yet.)" \
      "Ledger backup: ${bkage}d old (-1 = NONE EXISTS). brain.db is the only irreplaceable thing here and this copy is on the SAME disk — it survives corruption and a bad write, not a dead drive. If this number is not 0, or if it is -1, say so in the GLANCE: it is the one loss he cannot undo." \
      "Unattributed utterances (14d): ${unres} — conversations where capture recorded HIS half and could not name who he was talking to. The raw evidence IS there now: the Q snapshot holds the whole conversation pane, and every utterance carries its verbatim win_title. Resolve them at SLEEP with \`brain annotate <event_id> to \"<name>\" --by brain\` (shipped and live, not proposed — verify with \`brain annotations --key to\`), and record channel-qualified handles (whatsapp:X, slack:Y) in Atlas/People aliases. Full per-channel table in coverage.md. Naming who he talks to is yours to do; do not wait for him to code it."
}

# Reap a session orphaned by a previous runner that died uncleanly — but ONLY if
# that PID is verifiably OURS (its args carry the sentinel). Guards against a
# recycled PID belonging to some unrelated process.
if [[ -f "$PIDFILE" ]]; then
    stale="$(cat "$PIDFILE" 2>/dev/null || echo)"
    if [[ -n "$stale" ]] && ps -o command= -p "$stale" 2>/dev/null | grep -q "$SENTINEL"; then
        log "reaping orphaned session $stale from a prior runner"; kill_tree "$stale"
    fi
    rm -f "$PIDFILE"
fi

# SINGLETON: repeated bootstrap/kickstart cycles can orphan an old runner (two
# runners raced on state files 2026-07-19, one resurrecting day-session mid-fix).
RUNNER_PIDFILE="$STATE_DIR/runner.pid"
if [[ -f "$RUNNER_PIDFILE" ]]; then
    other="$(cat "$RUNNER_PIDFILE" 2>/dev/null || echo)"
    if [[ -n "$other" && "$other" != "$$" ]] && ps -o command= -p "$other" 2>/dev/null | grep -q brain-loop; then
        log "another runner ($other) is alive — this instance ($$) exits (singleton)"
        trap - EXIT TERM INT
        exit 0
    fi
fi
echo $$ > "$RUNNER_PIDFILE"

log "brain runner up (pid $$, resume-per-cycle + dream + idle-gate + priming, model=$MODEL)"

while true; do
    capture_health
    backup_ledger
    if [[ -f "$PAUSE_FILE" ]]; then log "paused — waiting"; sleep 60; continue; fi
    [[ -x "$BIN" && -x "$CLAUDE" ]] || { log "FATAL: missing $BIN or $CLAUDE"; sleep 300; continue; }

    cf="$(day_count_file)"; n="$(cat "$cf" 2>/dev/null || echo 0)"
    if (( n >= MAX_SESSIONS_PER_DAY )); then log "daily session cap ($n/$MAX_SESSIONS_PER_DAY) — parking 1h"; sleep 3600; continue; fi

    now=$(date +%s)
    last_cycle="$(cat "$LASTCYCLE_FILE" 2>/dev/null || echo 0)"
    [[ "$last_cycle" =~ ^[0-9]+$ ]] || last_cycle=0
    (( last_cycle == 0 )) && last_cycle=$(( now - 5400 ))   # first ever run: assume a 90-min window

    # One session id PER DAY; every cycle resumes it so context accumulates.
    DAY_SESSION="$STATE_DIR/day-session-$(date +%Y%m%d)"
    # DREAM/WAKE is decided by a marker written ONLY on a SUCCESSFUL deep cycle —
    # never by "does a session id exist" (2026-08-01 proposal, applied 2026-08-05).
    # The old test conflated "a DREAM ran" with "a DREAM finished": a watchdog-killed
    # DREAM still persisted its session id, so the next cycle resumed it as a WAKE
    # and the day silently lost its consolidation. It cost 07-31, 08-03 and 08-04.
    # Session-id persistence now carries continuity duty only.
    DREAM_MARKER="$STATE_DIR/dream-done-$(date +%Y%m%d)"

    # RELAUNCH FLOOR (persisted — survives runner restarts): never two cycles
    # closer than MIN_RELAUNCH. The day's first cycle (the DREAM) is exempt —
    # it feeds on yesterday, not on fresh events.
    if (( WOKEN == 0 )) && [[ -f "$DREAM_MARKER" ]] && (( now - last_cycle < MIN_RELAUNCH_SECS )); then
        wait_for=$(( MIN_RELAUNCH_SECS - (now - last_cycle) ))
        # Never park past a re-check horizon: with a daily floor (86400) a full
        # park would sleep through midnight and the day-start DREAM would drift
        # later every day. Re-evaluate hourly so the date flip fires it on time.
        (( wait_for > 3600 )) && wait_for=3600
        log "floor: last fold $(( (now - last_cycle) / 60 ))m ago — parking ${wait_for}s"
        park "$wait_for"; continue
    fi

    # IDLE GATE: no new evidence → no claude call (the deterministic health
    # check still runs, and the DREAM cycle is never gated). The old app-side
    # brain tick had this rail (min_batch); it was lost in the shift-runner
    # move and overnight cycles burned ~$0.6-0.8 each narrating "still asleep".
    if (( WOKEN == 0 )) && [[ -f "$DREAM_MARKER" ]]; then
        pending="$(pending_events "$last_cycle")"
        if (( pending < IDLE_MIN_EVENTS )); then
            capture_health
            log "idle-skip (pending=$pending < $IDLE_MIN_EVENTS) — recheck in ${IDLE_RECHECK_SECS}s"
            park "$IDLE_RECHECK_SECS"; continue
        fi
    fi
    WOKEN=0

    # OFFLINE GATE: don't burn a cycle slot against a dead network.
    if ! api_reachable; then
        capture_health
        log "api probe failed — parking 600s (usually his Mac asleep = AFK, not an outage; no cycle burned)"
        park 600; continue
    fi

    # PRESENCE GATE for deep cycles (2026-08-18). A DREAM launched into a Mac that is
    # about to go back to sleep is a severed DREAM. Both August consolidation losses
    # began at 00:19 and 01:43 — the first DarkWake past midnight, on battery, with him
    # asleep. The runner already knows "AFK != outage" at the probe above; it just never
    # applied that knowledge to its own launch decision. Prevention beats classification:
    # defer the deep cycle rather than spend 40 minutes of tokens on a doomed one.
    if [[ ! -f "$DREAM_MARKER" ]] || morph_due; then
        on_ac=0; pmset -g batt 2>/dev/null | grep -q "AC Power" && on_ac=1
        recent_input="$(sqlite3 -readonly "$DB" \
            "SELECT COUNT(*) FROM events WHERE source='input' AND ts > strftime('%s','now') - 900;" 2>/dev/null)"
        [[ "$recent_input" =~ ^[0-9]+$ ]] || recent_input=0
        if (( on_ac == 0 && recent_input == 0 )); then
            log "presence gate: deep cycle deferred — on battery, no input in 15m; a DREAM started now gets severed mid-stream"
            park 900; continue
        fi
    fi

    "$BIN" brain-scaffold >/dev/null 2>&1 || true
    PROFILE="$("$BIN" sandbox-profile 2>/dev/null)"
    [[ -f "$PROFILE" ]] || { log "FATAL: no sandbox profile"; sleep 300; continue; }

    started=$(date +%s)
    out="$LOGDIR/shift-$(date +%Y%m%d-%H%M%S).json"
    hb="$(shasum "$BRAIN_DIR/HANDOFF.md" 2>/dev/null | cut -d' ' -f1 || echo none)"
    # Pre-cycle fingerprints of the EVOLUTION organs. The completion markers are
    # gated on these changing, not on exit code: a cycle that exits 0 having done
    # nothing must not be allowed to consume the day's DREAM slot or the month's
    # MORPH slot. Classification proves the process ran; only a diff proves work.
    sb="$(shasum "$BRAIN_DIR/SELF.md" 2>/dev/null | cut -d' ' -f1 || echo none)"
    lb="$(wc -l < "$BRAIN_DIR/LEARNINGS.md" 2>/dev/null | tr -d ' ')"; [[ -n "$lb" ]] || lb=0
    ago_min=$(( (started - last_cycle) / 60 ))

    # PRIMING (association, not search): entity notes mentioned in the unread
    # window, injected so the brain wakes with the relevant memories loaded.
    # Deterministic, zero-LLM, capped; best-effort.
    PRIME="$(python3 "$BINDIR/brain-prime.py" --db "$DB" --vault "$VAULT" \
                --since "$last_cycle" --max-files 8 --max-bytes 14000 2>/dev/null || true)"

    # EVIDENCE PRE-DIGESTION: compile the window's evidence deterministically so
    # the model spends its turns on cognition, not exploratory SQL (quality +
    # cost: code guarantees completeness; a model can only intend it). Also
    # refresh the lint queue so tonight's quality burn-down is current.
    # Rotate the instrument log before writing (5 MB); it is pure regenerable noise.
    if [[ -f "$ILOG" ]] && (( $(stat -f%z "$ILOG" 2>/dev/null || echo 0) > 5242880 )); then
        mv -f "$ILOG" "$ILOG.1"
    fi
    python3 "$BINDIR/day-digest.py" --since "$last_cycle" >>"$ILOG" 2>&1 || true
    python3 "$BINDIR/note-lint.py" >>"$ILOG" 2>&1 || true
    python3 "$BINDIR/co-activation.py" >>"$ILOG" 2>&1 || true
    python3 "$BINDIR/rhythm.py" >>"$ILOG" 2>&1 || true
    python3 "$BINDIR/register.py" >>"$ILOG" 2>&1 || true
    python3 "$BINDIR/communities.py" >>"$ILOG" 2>&1 || true
    python3 "$BINDIR/affect.py" >>"$ILOG" 2>&1 || true
    python3 "$BINDIR/balance.py" >>"$ILOG" 2>&1 || true
    python3 "$BINDIR/coverage.py" >>"$ILOG" 2>&1 || true
    python3 "$BINDIR/reconsolidation.py" >>"$ILOG" 2>&1 || true
    python3 "$BINDIR/recall.py" >>"$ILOG" 2>&1 || true
    python3 "$BINDIR/deltas.py" >>"$ILOG" 2>&1 || true
    # Weekly regression battery (Sundays): loud failure, never blocks the cycle.
    if [[ "$(date +%u)" == "7" && ! -f "$STATE_DIR/selftest-$(date +%Y%m%d)" ]]; then
        if python3 "$BINDIR/selftest.py" >>"$ILOG" 2>&1; then
            log "weekly selftest: ALL OK"
        else
            log "weekly selftest: FAILURES — see instruments.log; instruments may be lying"
        fi
        touch "$STATE_DIR/selftest-$(date +%Y%m%d)"
    fi

    resume_flag=""
    cycle_cap="$CYCLE_MAX_SECS"
    cycle_kind="wake"
    if [[ ! -f "$DREAM_MARKER" ]] && [[ -s "$DAY_SESSION" ]]; then
        # A DREAM already ran today and did NOT complete (no marker), but it left a
        # session id. It was severed, not idle — 08-15 shows one that ran 67 minutes and
        # rewrote the HANDOFF before the machine slept. Restarting from scratch threw all
        # of that away five times across 08-15..08-17. Resume the conversation instead:
        # the model still holds everything it read, and only has to finish.
        cycle_kind="dream"
        cycle_cap=$(( CYCLE_MAX_SECS * 2 ))
        resume_flag="--resume $(cat "$DAY_SESSION")"
        prompt="$SENTINEL — DREAM RESUME $(ts). Your previous SLEEP cycle today was cut off mid-consolidation — the machine went to sleep and severed the stream, not you. You still hold everything you read. Do NOT start over and do NOT re-read the digest from the top: continue exactly where you stopped, finish the consolidation, and end by rewriting HANDOFF.md (the runner treats a rewritten letter as the proof this day was integrated). If you had already written the letter before the cut, say so and stop."
        log "cycle $((n+1))/$MAX_SESSIONS_PER_DAY — RESUME severed DREAM $(cut -c1-8 "$DAY_SESSION") window=${ago_min}m -> $out"
    elif [[ ! -f "$DREAM_MARKER" ]]; then
        # No SUCCESSFUL deep cycle yet today → DREAM, in a NEW session.
        # Boot = constitution + yesterday's letter. A failed DREAM leaves no
        # marker, so the next cycle retries it instead of silently downgrading
        # the whole day to WAKEs.
        # Refresh the graph's growth feed (entity candidates from deep evidence).
        cycle_kind="dream"
        python3 "$BINDIR/queue-builder.py" >>"$ILOG" 2>&1 || true
        cycle_cap=$(( CYCLE_MAX_SECS * 2 ))
        prompt="$SENTINEL — DAY START $(ts). Your context lives the WHOLE day (I resume this session each hour) and resets tomorrow. Do ONE cycle per invocation, then STOP — do NOT loop on await-wake.

THIS IS YOUR SLEEP CYCLE — deep consolidation of the day just ended (window ~${ago_min} min; evidence pre-compiled in Atlas/AI/Brain/digest.md, read it end to end). Run the SLEEP protocol from your constitution: replay and grade, integrate, strengthen what mattered, prune, chronicle, write the letter. Allocate attention by SALIENCE, and state your allocation in the journal.

ATTRIBUTION RESOLUTION — a step of THIS cycle, not a capacity you may defer. As of 2026-08-05 capture finally records the other half of his conversations: chat Q snapshots hold the whole pane, every utterance carries a verbatim win_title, and unresolved ones are listed BY EVENT ID in the 'Unresolved queue' of coverage.md and tagged UNRESOLVED in digest.md. For weeks you have carried 'who is brate' as your highest-value open name while the evidence did not exist. It exists now. Work the queue:
 · HARD RULE (2026-08-18): every chat event now carries payload.pane_kind. Only `full` contains a conversation. `url-only` is the address bar, `composer` is HIS OWN half-typed word read back from the message box, `thin` is browser furniture. You may NOT infer an addressee from a non-`full` event — not from register, not from continuity with a neighbour, not from the sidebar listing. On 2026-08-17 fourteen utterances were labelled `to=Vik` by reasoning about the WINDOW and writing at the EVENT level; three were Turkish/Albanian business threads he had tab-switched into, and one of those contained a fresh `brate` sighting that the wrong label buried. Reason per-row or not at all.
 · METHOD: a chat snapshot contains BOTH the sidebar (≈20 recent contacts with previews) AND the open thread. The most salient name is usually the WRONG one. Identify the thread by finding the sidebar row whose preview text AND timestamp match the open thread's last message. No match, no name — say so.
 · Rows tagged STALE had the window title change mid-capture; the text may span two conversations. Resolve only on an unambiguous match, otherwise skip and record why.
 · WRITE IT BACK: 'brain annotate <event_id> to \"<name>\" --by brain' (shipped, live, and verified to work from inside your sandbox; read back with 'brain annotations --key to'). It is insert-only into a sidecar db — the raw ledger is never edited and a later annotation supersedes an earlier one, so a correction is cheap.
 · Only after the SAME handle matches in >=2 separate windows may you add a channel-qualified alias (shaped 'whatsapp:<handle>') to an Atlas/People note. One match earns an annotation and a journal line, not an identity.
 · 'brate' is a VOCATIVE in MK/SR ('bro'), not necessarily a name — it may map to more than one person. Resolve it per-thread: which contact does he address that way, in which conversation.
 · A wrong attribution is worse than none. Report in the journal how many you resolved, how many you left unresolved, and on what evidence — an honest zero beats a confident guess.

$(cat "$BRAIN_DIR/PROMPT.md")

--- HANDOFF LETTER FROM YESTERDAY (grade its predictions, answer its questions) ---
$(cat "$BRAIN_DIR/HANDOFF.md" 2>/dev/null || echo '(no handoff yet — first day)')"
        log "cycle $((n+1))/$MAX_SESSIONS_PER_DAY — NEW day session (DREAM) window=${ago_min}m prime=${#PRIME}B -> $out"
    elif morph_due; then
        # METAMORPHOSIS: its own session, off the DREAM critical path, once a month.
        cycle_kind="morph"
        cycle_cap=$(( CYCLE_MAX_SECS * 2 ))
        prompt="$SENTINEL — METAMORPHOSIS $(ts). This is NOT a daily cycle and NOT a chronicle. It is a dedicated structural-maintenance session, deliberately taken OFF the DREAM critical path — because for weeks this work was queued inside the DREAM, which is the cycle that fails most often, and so it was 'deferred honestly' every single time. Nothing is racing you now. Do ONE pass, then STOP.

Your job this session is COMPRESSION and STRUCTURE, not new observation:
1. **Compress Atlas/AI/Brain/LEARNINGS.md.** Merge duplicates, promote what generalises into fewer sharper lessons, retire what a later lesson superseded. Preserve every DISTINCT lesson — losing knowledge is failure. Length is not knowledge.
2. **Rewrite Atlas/AI/Brain/SELF.md** — your own self-prompt. This is the organ of your evolution and it has gone stale while the chronicle files were rewritten daily. Change it because your model of him and of yourself has actually changed; do not churn it to look busy. State in the journal what you changed and why.
3. **Advance the ONTOLOGY / STORY work in Atlas/Mind/** as far as one honest pass allows.

Your mind files are now git-versioned, so a compression that goes too far is recoverable — compress with that freedom, and say in the journal what you deliberately kept.

$(cat "$BRAIN_DIR/PROMPT.md")"
        log "cycle $((n+1))/$MAX_SESSIONS_PER_DAY — NEW session (METAMORPHOSIS) prime=${#PRIME}B -> $out"
    else
        # Later cycle today → RESUME the day's session (context already loaded).
        [[ -s "$DAY_SESSION" ]] && resume_flag="--resume $(cat "$DAY_SESSION")"
        prompt="$SENTINEL — WAKE CYCLE $(ts). Window: ~${ago_min} min. Evidence pre-compiled in Atlas/AI/Brain/digest.md. Run the WAKE protocol from your constitution: light and associative — perceive the window, note what's salient, follow one association if it's alive, keep TICKLER + the journal current, refresh the ⚡ GLANCE so the dashboard reflects NOW. No deep consolidation (that's tonight's SLEEP cycle). You hold the constitution from boot; build on today. One cycle, then STOP."
        # `${resume_flag:-…}` expands to the FLAG when set, so the old form printed the
        # whole "--resume <uuid>" into the log line. Build the label explicitly.
        if [[ -n "$resume_flag" ]]; then wake_label="RESUME $(cut -c1-8 "$DAY_SESSION")"; else wake_label="NEW session (WAKE)"; fi
        log "cycle $((n+1))/$MAX_SESSIONS_PER_DAY — $wake_label window=${ago_min}m prime=${#PRIME}B -> $out"
    fi

    # The brain's own vital signs, in-band. A rail the model cannot see is not a rail.
    prompt="$prompt

$(vitals)"

    if [[ -n "$PRIME" ]]; then
        prompt+="

--- PRIMED MEMORIES (entity notes active in your unread window — already loaded, no need to search) ---
$PRIME"
    fi

    echo $((n + 1)) > "$cf"
    # --strict-mcp-config => ZERO MCP servers (observer, not an agent). $resume_flag
    # is intentionally UNQUOTED so it word-splits to "--resume <id>" or nothing.
    sandbox-exec -f "$PROFILE" \
        "$CLAUDE" -p "$prompt" $resume_flag \
            --model "$MODEL" --effort "$EFFORT" \
            --output-format json --dangerously-skip-permissions \
            --strict-mcp-config \
            --allowedTools "Read,Grep,Glob,Bash,Write,Edit" \
            --disallowedTools "WebFetch,WebSearch,Task" \
        > "$out" 2> "$out.stderr" &
    cur_cpid=$!
    echo "$cur_cpid" > "$PIDFILE"

    # Hold an IDLE-sleep assertion for the life of the cycle, on AC only.
    # macOS suspending the Mac mid-stream severs the connection and claude
    # returns "Connection closed mid-response" after the wake — proven by
    # shift-20260729-041340.json (claude duration_ms=498s vs runner elapsed
    # 10896s). `-i` blocks IDLE sleep only: a closed lid still sleeps, and on
    # battery we don't fight the power manager at all. AFK ≠ outage.
    # …EXCEPT for the two deep cycles. A DREAM or a MORPH runs once a day / once a
    # month, costs ~25 min, and is exactly the thing that must not be severed —
    # so those hold the assertion on battery too. Everything else still defers to
    # the power manager on battery. (A closed lid sleeps regardless; the awake-clock
    # watchdog below is what makes surviving that suspension possible.)
    caff=""
    if [[ "$cycle_kind" == "dream" || "$cycle_kind" == "morph" ]] || pmset -g batt 2>/dev/null | grep -q "AC Power"; then
        # -i blocks only IDLE sleep, which is why deep cycles still died to Sleep
        # Service / Deep Idle overnight. On AC a DREAM/MORPH is worth blocking SYSTEM
        # sleep outright (-s); on battery we still refuse to fight the power manager.
        if [[ "$cycle_kind" == "dream" || "$cycle_kind" == "morph" ]] && pmset -g batt 2>/dev/null | grep -q "AC Power"; then
            caffeinate -s -w "$cur_cpid" >/dev/null 2>&1 & caff=$!
        else
            caffeinate -i -w "$cur_cpid" >/dev/null 2>&1 & caff=$!
        fi
    fi

    # Watchdog: polite TERM at the cap, SIGKILL 60s later (TERM alone provably
    # doesn't end a connection-retrying claude). WALL-CLOCK, not `sleep $cap`:
    # macOS suspends a sleeping `sleep`, so the old form let cycles run 10896s
    # against a 1800s cap. Poll a deadline instead, and exit early once the
    # child is reaped so the orphaned sleep is ≤15s rather than ≤1800s.
    # AWAKE-CLOCK (2026-08-05): the cap is budget of AWAKE time, not wall time. A
    # plain wall deadline bills system suspension against the cycle, so an overnight
    # DREAM on a sleeping Mac is executed on wake almost by design — that is exactly
    # what killed 08-04 (rc=143 at 11,143s wall against a 3,600s cap, while claude
    # itself had run only ~500s). Each poll bills its own observed delta, and any
    # delta > 60s is read as "the Mac was asleep" and billed at 60s, not at its true
    # length. Suspension can no longer consume a consolidation's budget.
    ( budget=$cycle_cap; last=$(date +%s)
      while (( budget > 0 )); do
          kill -0 "$cur_cpid" 2>/dev/null || exit 0
          sleep 15
          now2=$(date +%s); delta=$(( now2 - last )); last=$now2
          (( delta < 0 )) && delta=0
          (( delta > 60 )) && delta=60
          budget=$(( budget - delta ))
      done
      kill_tree "$cur_cpid"; sleep 60; kill_tree9 "$cur_cpid" ) & watchdog=$!
    wait "$cur_cpid"; rc=$?
    kill "$watchdog" 2>/dev/null || true
    [[ -n "$caff" ]] && kill "$caff" 2>/dev/null || true
    rm -f "$PIDFILE"; cur_cpid=""

    # Persist THIS cycle's session id so the next cycle resumes the same conversation.
    new_sid="$(python3 -c "import json;print(json.load(open('$out')).get('session_id',''))" 2>/dev/null || echo)"
    # A MORPH is explicitly NOT a day session — letting its id land here would make
    # every WAKE today resume the structural-maintenance conversation instead of
    # the day's own thread.
    [[ -n "$new_sid" && "$cycle_kind" != "morph" ]] && echo "$new_sid" > "$DAY_SESSION"

    elapsed=$(( $(date +%s) - started ))
    ha="$(shasum "$BRAIN_DIR/HANDOFF.md" 2>/dev/null | cut -d' ' -f1 || echo none)"
    handoff="rewritten"; [[ "$hb" == "$ha" ]] && handoff="UNCHANGED"
    log "cycle ended rc=$rc after ${elapsed}s — handoff $handoff — session ${new_sid:0:8}"

    ls -1t "$LOGDIR"/shift-*.json 2>/dev/null | tail -n +15 | while read -r f; do rm -f "$f" "$f.stderr"; done

    # A limit/connection failure must come from the RUN, not from the brain
    # QUOTING those words in its narrative (it graded a ConnectionRefused
    # prediction and false-tripped a plain grep on 2026-07-14). Real failures
    # are rc!=0, the JSON's own is_error flag, or an rc==0 whose whole result is
    # one short error line — stderr always counts as evidence (but NOT as a
    # failure trigger: a plugin SessionEnd hook writes there on good cycles).
    #
    # Emits "kind|refund|detail". Classes: ok · limit · net · truncated · auth ·
    # unknown. UNKNOWN IS LOGGED VERBATIM — "You've hit your weekly limit" went
    # unmatched for 19 days precisely because unrecognised failures were silent,
    # and that one gap cost the 2026-07-25→27 blackout (24 burned cycles).
    classify="$(python3 - "$out" "$rc" "$elapsed" <<'PY'
import json, re, sys
out, rc, elapsed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    j = json.load(open(out))
except Exception:
    j = {}
r = str(j.get("result") or "")
cost = j.get("total_cost_usd")
try:
    err = open(out + ".stderr").read()
except Exception:
    err = ""

LIMIT = (r"usage limit|session limit|rate.?limit|weekly limit|"
         r"hit your \w+ limit|overloaded|quota|429")
NET   = (r"unable to connect|connection ?refused|econnrefused|fetch failed|"
         r"network error|econnreset|etimedout|socket hang up|"
         # 2026-08-18: these three landed in `unknown` four times, once at streak 9
         # (19,200s park). They are plainly network, not mysteries.
         r"enotfound|can.t reach the api server|request timed out")
TRUNC = r"connection closed|mid-response|stream (ended|closed)|premature close"
AUTH  = r"not logged in|please run /login|authentication|oauth.*expired"

# is_error is authoritative and free — already parsed for session_id below.
failed = (rc != 0) or bool(j.get("is_error"))
hay = err + " " + (r if (failed or len(r) < 600) else "")
# Upgrade an rc==0/is_error==false cycle to failed ONLY on its own short result
# — never on stderr, where a plugin SessionEnd hook writes noise on good cycles.
if not failed and len(r) < 600 and re.search("|".join((LIMIT, NET, TRUNC, AUTH)), r, re.I):
    failed = True                       # rc==0 whose entire result is an error line

# OUR OWN watchdog kill (SIGTERM 143 / SIGKILL 137) leaving no result is not a
# mystery and must not be treated as one: on 2026-08-04 a killed DREAM landed in
# `unknown` with an empty VERBATIM and parked 19200s, so the retry that would have
# saved the day never came. Own it as its own class with a short backoff.
if not failed:                     kind = "ok"
elif rc in (143, 137) and not r.strip(): kind = "killed"
elif re.search(LIMIT, hay, re.I):  kind = "limit"
elif re.search(NET,   hay, re.I):  kind = "net"
elif re.search(TRUNC, hay, re.I):  kind = "truncated"   # connected, streamed, died: tokens SPENT
elif re.search(AUTH,  hay, re.I):  kind = "auth"        # usually transient, network dying mid-handshake
else:                              kind = "unknown"

# NOTE: no apostrophes anywhere in this heredoc. macOS ships bash 3.2.57, whose
# parser mishandles a single quote inside a QUOTED heredoc nested in $( ) — the
# script stops parsing and launchd crash-loops the runner. Verified 2026-07-30.
# Refund the slot for the day only when NO reasoning happened. Cost is the honest
# discriminator — elapsed is wall-clock and inflated by system suspension
# (498s of claude inside 10896s of runner, 2026-07-29).
# Cost-gate EVERY refund, including limit/auth/net: a real one of those costs
# exactly $0, so gating loses nothing — but a MISclassified expensive cycle no
# longer hands back a slot whose tokens were genuinely spent.
if kind == "ok":                    refund = 0
elif cost is not None:              refund = 1 if cost < 0.10 else 0
elif kind in ("limit", "auth", "net"): refund = 1
else:                               refund = 1 if elapsed < 120 else 0

# Prefer the RESULT over stderr: in all 14 retained shift files the real error
# text lived in result and stderr carried only plugin-hook noise. Getting this
# backwards would hide the next unknown error string behind the hook line —
# which is precisely the 19-day silence that cost the 2026-07-25 blackout.
detail = re.sub(r"[|\r\n\t]+", " ", (r.strip() or err.strip())).strip()[:200]
print("%s|%d|%s" % (kind, refund, detail))
PY
)"
    kind="${classify%%|*}"; _rest="${classify#*|}"
    refund="${_rest%%|*}"; detail="${_rest#*|}"
    [[ "$kind" =~ ^(ok|limit|net|truncated|auth|killed|unknown)$ ]] || { kind="unknown"; refund=0; detail="classifier produced no verdict"; }

    # Consecutive-failure streak: the rail that does NOT depend on knowing what
    # went wrong. Classification can always miss the next unknown string.
    streak="$(cat "$STREAK_FILE" 2>/dev/null || echo 0)"
    [[ "$streak" =~ ^[0-9]+$ ]] || streak=0
    afk_sever=0
    if [[ "$kind" == "truncated" ]] && printf '%s' "$detail" | grep -qi "went to sleep"; then afk_sever=1; fi
    if [[ "$kind" == "ok" ]]; then streak=0
    elif (( afk_sever == 1 )); then :   # AFK severance — do not escalate
    else streak=$(( streak + 1 )); fi
    echo "$streak" > "$STREAK_FILE"

    (( refund == 1 )) && echo "$n" > "$cf"   # nothing was reasoned — hand the slot back

    case "$kind" in
        limit)
            p="$(streak_park_secs 3600)"
            log "LIMIT hit (streak $streak) — parking ${p}s; his interactive Claude outranks the brain [$detail]"
            park "$p"; continue ;;
        net)
            p="$(streak_park_secs 600)"
            log "connection failure (streak $streak) — parking ${p}s, slot refunded, window stays pending"
            park "$p"; continue ;;
        auth)
            p="$(streak_park_secs 1800)"
            log "AUTH failure (streak $streak) — parking ${p}s. If this repeats with the network UP: claude login"
            park "$p"; continue ;;
        truncated)
            if (( afk_sever == 1 )); then
                log "TRUNCATED by system sleep (AFK, streak held at $streak) — parking 600s; his Mac sleeping is not a fault"
                park 600; continue
            fi
            p="$(streak_park_secs 600)"
            log "TRUNCATED mid-response (streak $streak, refund=$refund) — parking ${p}s [$detail]"
            park "$p"; continue ;;
        killed)
            # Short backoff on purpose: this is OUR watchdog, not a remote refusal.
            # No dream marker was written, so the retry re-runs the DREAM rather
            # than downgrading the rest of the day to WAKEs.
            p="$(streak_park_secs 300)"
            log "WATCHDOG-KILLED after ${elapsed}s wall (streak $streak, refund=$refund, kind=$cycle_kind) — parking ${p}s; a $cycle_kind will be retried, not skipped"
            park "$p"; continue ;;
        unknown)
            p="$(streak_park_secs 600)"
            log "UNCLASSIFIED failure (streak $streak, refund=$refund) — parking ${p}s. VERBATIM: [$detail]"
            park "$p"; continue ;;
    esac

    # Advance the fold watermark ONLY on a clean cycle — a failed cycle saw
    # nothing, so its window stays pending for the next one. (Every non-ok kind
    # has already `continue`d above; this is belt-and-braces.)
    if [[ "$kind" == "ok" ]]; then
        date +%s > "$LASTCYCLE_FILE"
        case "$cycle_kind" in
            dream)
                # Gate on the WORK, not the exit code. A DREAM that exits 0 without
                # rewriting the letter did not consolidate, and must not consume the
                # day's slot — it now retries instead of silently downgrading the day.
                if [[ "$handoff" == "rewritten" ]]; then
                    # Marker for the day the cycle STARTED and the day it FINISHED: a
                    # DREAM launched 23:42 and landing 00:05 is one consolidation, not
                    # a licence to run a second one 60s later.
                    touch "$DREAM_MARKER" "$STATE_DIR/dream-done-$(date +%Y%m%d)"
                    sa="$(file_age_days "$BRAIN_DIR/SELF.md")"
                    (( sa >= SELF_STALE_DAYS )) && log "shift-protocol: SELF.md ${sa}d stale — a MORPH is due (fires next pass unless this month's already ran)"
                else
                    log "shift-protocol: DREAM exited ok but HANDOFF is UNCHANGED — no consolidation happened, NOT marking the day done; it will retry"
                fi
                ;;
            morph)
                # Same principle: a MORPH that changed neither the self-prompt nor the
                # LEARNINGS length did not metamorphose. Do not burn the month on it.
                sa2="$(shasum "$BRAIN_DIR/SELF.md" 2>/dev/null | cut -d' ' -f1 || echo none)"
                la="$(wc -l < "$BRAIN_DIR/LEARNINGS.md" 2>/dev/null | tr -d ' ')"; [[ -n "$la" ]] || la=0
                if [[ "$sa2" != "$sb" ]] || (( la != lb )); then
                    touch "$STATE_DIR/morph-done-$(date +%Y%m)"
                    log "METAMORPHOSIS complete — LEARNINGS ${lb} -> ${la} lines, SELF.md $([[ "$sa2" != "$sb" ]] && echo REWRITTEN || echo unchanged)"
                else
                    log "METAMORPHOSIS produced NO change to SELF.md or LEARNINGS.md — month NOT marked done, it will retry"
                fi
                ;;
        esac
        # Version the mind, deterministically, in the RUNNER — the model cannot
        # skip this, edit it, or narrate it as done. Three properties in one commit:
        # undo (compression is recoverable), tamper-evidence (PREDICTIONS.md is
        # model-writable, so a graded board that changes retroactively now shows as
        # a diff), and pre-registration (a prediction is frozen in history the cycle
        # it is made). Pathspec-scoped so it can never sweep up his own work.
        git -C "$VAULT" add -- Atlas/AI/Brain Atlas/Mind >/dev/null 2>&1 || true
        if ! git -C "$VAULT" commit -q -m "brain: $cycle_kind cycle $(date '+%Y-%m-%d %H:%M') (handoff $handoff)" \
                -- Atlas/AI/Brain Atlas/Mind >/dev/null 2>&1; then
            # Nothing staged is the normal case (obsidian-git may have swept first);
            # anything else is a real failure and must not be silent again.
            git -C "$VAULT" diff --cached --quiet -- Atlas/AI/Brain Atlas/Mind 2>/dev/null \
                || log "mind-commit FAILED with staged changes — provenance not recorded"
        fi
    fi

    if (( elapsed < MIN_RELAUNCH_SECS )); then
        wait_for=$(( MIN_RELAUNCH_SECS - elapsed ))
        # Same re-check horizon as the top floor: with a daily MIN_RELAUNCH an
        # uncapped park here slept until 14:07 next day, drifting the DREAM
        # past midnight (caught live 2026-07-14 21:08). The top-of-loop floor
        # (persisted last-cycle-ts) still enforces the real spacing.
        (( wait_for > 3600 )) && wait_for=3600
        log "cycle ran ${elapsed}s — floor wait ${wait_for}s before next cycle"
        park "$wait_for"
    fi
done
