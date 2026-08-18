#!/usr/bin/env bash
# await-wake.sh — the living session's idle primitive (polymorph pattern).
# The brain calls this as a Bash tool between actions; it BLOCKS (keeping the
# claude -p session alive) and prints ONE keyword telling the brain what to do:
#
#   CYCLE-NOW  — an hour has passed → do a full reason/learn cycle
#   SHIFT-END  — the ~24h shift deadline passed → write handoff and STOP
#   WOKEN      — a wake signal appeared → check now
#   IDLE       — nothing due; call me again to keep idling
#
# Cadence is enforced HERE (via state files in STATE_DIR, outside the git vault),
# not trusted to the model. A single sleep can't exceed the ~10-min Bash-tool
# ceiling, so we sleep in one chunk and return; the brain loops us.
set -uo pipefail
STATE_DIR="${SECONDMIND_STATE_DIR:-$HOME/Library/Application Support/2ndMind/brain-runtime}"
DEADLINE_FILE="$STATE_DIR/shift-deadline"
NEXTCYCLE_FILE="$STATE_DIR/next-cycle"
WAKE_FILE="$STATE_DIR/wake"
CHUNK="${1:-540}"          # one sleep chunk (< the ~600s Bash-tool ceiling)
CYCLE_EVERY=3600           # seconds between full cycles
mkdir -p "$STATE_DIR"

now=$(date +%s)
deadline=$(cat "$DEADLINE_FILE" 2>/dev/null || echo 0)
nextcycle=$(cat "$NEXTCYCLE_FILE" 2>/dev/null || echo 0)

if [[ "$deadline" -gt 0 && "$now" -ge "$deadline" ]]; then echo "SHIFT-END"; exit 0; fi
if [[ "$nextcycle" -eq 0 ]]; then echo $((now + CYCLE_EVERY)) > "$NEXTCYCLE_FILE"; echo "CYCLE-NOW"; exit 0; fi
if [[ "$now" -ge "$nextcycle" ]]; then echo $((now + CYCLE_EVERY)) > "$NEXTCYCLE_FILE"; echo "CYCLE-NOW"; exit 0; fi

end=$((now + CHUNK))
[[ "$deadline"  -gt 0 && "$end" -gt "$deadline"  ]] && end=$deadline
[[ "$nextcycle" -gt 0 && "$end" -gt "$nextcycle" ]] && end=$nextcycle
while [[ $(date +%s) -lt $end ]]; do
    if [[ -f "$WAKE_FILE" ]]; then rm -f "$WAKE_FILE"; echo "WOKEN"; exit 0; fi
    sleep 10
done

now=$(date +%s)
if   [[ "$deadline" -gt 0 && "$now" -ge "$deadline" ]]; then echo "SHIFT-END"
elif [[ "$now" -ge "$nextcycle" ]]; then echo $((now + CYCLE_EVERY)) > "$NEXTCYCLE_FILE"; echo "CYCLE-NOW"
else echo "IDLE"; fi
exit 0
