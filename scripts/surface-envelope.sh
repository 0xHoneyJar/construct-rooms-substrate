#!/usr/bin/env bash
# =============================================================================
# surface-envelope.sh — Pair-relay envelope surfacing
# =============================================================================
# Cycle: cycle-craft-cluster (simstim-20260511-craftc1c5), Sprint 2, task B.3
# PRD/SDD: §2.1.3 (RFC #235); BR-CRAFT-005 remediation preserved
#
# Surfaces a handoff envelope produced by a pair-relay stage according to the
# composition's surface_mode. Three modes:
#
#   silent       — write to .jsonl only; no stderr emit, no FIFO block
#   summary      — write to .jsonl + <=24-line <=80-col stderr summary
#   interactive  — write + summary + FIFO-blocking wait at
#                  .run/compose/<run_id>/.relay-control.fifo
#                + WAITING-OPERATOR side-channel signal:
#                  .run/compose/<run_id>/WAITING-OPERATOR flag
#                + entry appended to .run/waiting-on-operator.jsonl
#                  aggregator. Cleanup on FIFO read or timeout.
#
# Side-channel timeout (interactive mode):
#   Env-overridable via LOA_SURFACE_ENVELOPE_FIFO_TIMEOUT_SECONDS (default 1800).
#
# Orchestrator event:
#   On every surface call (any mode), appends one envelope.surfaced row to
#   <run_dir>/orchestrator.jsonl with {ts, cycle, envelope_path, surface_mode,
#   surfaced_at, blocked_ms}.
#
# Exit codes:
#   0  Surfaced (or interactive surfaced + operator responded within timeout)
#   1  Bad args / envelope missing / unreadable
#   2  Interactive timeout reached (envelope still surfaced, but operator did
#      not respond within LOA_SURFACE_ENVELOPE_FIFO_TIMEOUT_SECONDS)
#
# Usage:
#   surface-envelope.sh <envelope_path> --run-dir <path> --cycle <n>
#                       --mode {silent|summary|interactive}
# =============================================================================
set -euo pipefail

ENVELOPE_PATH=""
RUN_DIR=""
CYCLE=""
MODE=""
TIMEOUT="${LOA_SURFACE_ENVELOPE_FIFO_TIMEOUT_SECONDS:-1800}"

usage() {
    cat <<EOF
Usage: surface-envelope.sh <envelope_path> --run-dir <path> --cycle <n>
                            --mode {silent|summary|interactive}

Options:
  --run-dir PATH     Directory holding orchestrator.jsonl + FIFO state
  --cycle N          Cycle index for orchestrator logging
  --mode MODE        silent | summary | interactive
  --timeout SEC      Override LOA_SURFACE_ENVELOPE_FIFO_TIMEOUT_SECONDS (default 1800)
  -h, --help         Show this help

Exit codes:
  0  Surfaced
  1  Bad args / envelope missing
  2  Interactive timeout reached
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-dir) RUN_DIR="$2"; shift 2 ;;
        --cycle) CYCLE="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "ERROR: unknown flag '$1'" >&2; usage >&2; exit 1 ;;
        *) if [[ -z "$ENVELOPE_PATH" ]]; then ENVELOPE_PATH="$1"; else echo "ERROR: extra arg '$1'" >&2; exit 1; fi; shift ;;
    esac
done

if [[ -z "$ENVELOPE_PATH" || -z "$RUN_DIR" || -z "$CYCLE" || -z "$MODE" ]]; then
    echo "ERROR: envelope_path, --run-dir, --cycle, and --mode are all required" >&2
    usage >&2
    exit 1
fi

case "$MODE" in
    silent|summary|interactive) ;;
    *) echo "ERROR: --mode must be silent|summary|interactive (got '$MODE')" >&2; exit 1 ;;
esac

if [[ ! -f "$ENVELOPE_PATH" ]]; then
    echo "ERROR: envelope not found: $ENVELOPE_PATH" >&2
    exit 1
fi

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --timeout must be a non-negative integer (got '$TIMEOUT')" >&2
    exit 1
fi

mkdir -p "$RUN_DIR"
ORCHESTRATOR_LOG="$RUN_DIR/orchestrator.jsonl"
ROOT_AGGREGATOR_DIR="$(dirname "$(dirname "$RUN_DIR")")"
AGGREGATOR_LOG="$ROOT_AGGREGATOR_DIR/waiting-on-operator.jsonl"

# Emit a <=24-line <=80-col stderr summary, drawing only from envelope fields
# named in SDD §2.1.3 (construct_slug, persona, verdict, why.rationale,
# why.decisions_considered, why.tools_used).
_emit_summary() {
    python3 - "$ENVELOPE_PATH" "$CYCLE" <<'PYEOF'
import json
import sys
import textwrap

envelope_path = sys.argv[1]
cycle = sys.argv[2]

try:
    with open(envelope_path) as f:
        env = json.load(f)
except Exception as e:
    print(f"[surface] (could not parse envelope: {e})", file=sys.stderr)
    sys.exit(0)

construct = env.get("construct_slug", "<no-construct>")
persona = env.get("persona") or "<no-persona>"
verdict = env.get("verdict", "<no-verdict>")
why = env.get("why", {}) or {}
rationale = why.get("rationale", "")
decisions = why.get("decisions_considered", []) or []
tools = why.get("tools_used", []) or []

lines = []
lines.append(f"--- relay envelope (cycle {cycle}) ---")
lines.append(f"construct : {construct}")
lines.append(f"persona   : {persona}")
lines.append(f"verdict   : {verdict}")

# Wrap rationale to <=80 cols, "rationale: " prefix consumes 12 columns.
if rationale:
    wrapped = textwrap.wrap(rationale, width=80, initial_indent="rationale : ",
                            subsequent_indent="            ")
    lines.extend(wrapped[:8])  # cap rationale at 8 lines

if decisions:
    lines.append(f"decisions : {len(decisions)} considered")
    for d in decisions[:3]:
        # Cap per-decision line to <=80 cols.
        text = (d if isinstance(d, str) else json.dumps(d, ensure_ascii=False))
        prefix = "  - "
        room = 80 - len(prefix)
        if len(text) > room:
            text = text[: max(0, room - 1)] + "…"
        lines.append(prefix + text)

if tools:
    tool_line = "tools     : " + ", ".join(str(t) for t in tools)
    if len(tool_line) > 80:
        tool_line = tool_line[:79] + "…"
    lines.append(tool_line)

# Hard cap to <=24 lines total per SDD §2.1.3.
out = lines[:24]
for line in out:
    # Hard cap each line to <=80 cols defensively.
    if len(line) > 80:
        line = line[:79] + "…"
    print(line, file=sys.stderr)
PYEOF
}

_now_ms() {
    python3 -c 'import time; print(int(time.time()*1000))'
}

_log_orchestrator() {
    local ts_iso surface_mode envelope blocked_ms
    ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    surface_mode="$1"
    envelope="$2"
    blocked_ms="$3"
    python3 - "$ts_iso" "$CYCLE" "$envelope" "$surface_mode" "$blocked_ms" "$ORCHESTRATOR_LOG" <<'PYEOF'
import json
import sys

ts, cycle, env, mode, blocked_ms, log = sys.argv[1:]
row = {
    "event": "envelope.surfaced",
    "ts": ts,
    "cycle": int(cycle) if cycle.lstrip("-").isdigit() else cycle,
    "envelope_path": env,
    "surface_mode": mode,
    "surfaced_at": ts,
    "blocked_ms": int(blocked_ms),
}
with open(log, "a") as f:
    f.write(json.dumps(row) + "\n")
PYEOF
}

_aggregator_append() {
    local kind ts run_id
    kind="$1"
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    run_id="$(basename "$RUN_DIR")"
    mkdir -p "$(dirname "$AGGREGATOR_LOG")"
    python3 - "$kind" "$ts" "$run_id" "$CYCLE" "$ENVELOPE_PATH" "$AGGREGATOR_LOG" <<'PYEOF'
import json
import sys

kind, ts, run_id, cycle, env, log = sys.argv[1:]
row = {
    "event": kind,
    "ts": ts,
    "run_id": run_id,
    "cycle": int(cycle) if cycle.lstrip("-").isdigit() else cycle,
    "envelope_path": env,
}
with open(log, "a") as f:
    f.write(json.dumps(row) + "\n")
PYEOF
}

# Mode dispatch
START_MS="$(_now_ms)"
BLOCKED_MS=0
EXIT_CODE=0

case "$MODE" in
    silent)
        :
        ;;
    summary)
        _emit_summary
        ;;
    interactive)
        _emit_summary

        FIFO_PATH="$RUN_DIR/.relay-control.fifo"
        FLAG_PATH="$RUN_DIR/WAITING-OPERATOR"
        if [[ ! -p "$FIFO_PATH" ]]; then
            rm -f "$FIFO_PATH"
            mkfifo "$FIFO_PATH"
        fi
        : > "$FLAG_PATH"
        _aggregator_append "envelope.waiting-on-operator"

        echo "[surface] waiting for operator on $FIFO_PATH (timeout ${TIMEOUT}s)" >&2

        WAIT_START_MS="$(_now_ms)"
        # `read -t` only times out read(), not open(). On a FIFO with no
        # writer yet, open() blocks indefinitely and the timeout never fires.
        # Open the FIFO read-write in this process so open() returns
        # immediately; then read -t honors the timeout.
        exec 9<>"$FIFO_PATH"
        if read -r -t "$TIMEOUT" _operator_response <&9; then
            EXIT_CODE=0
        else
            EXIT_CODE=2
            echo "[surface] FIFO read timed out after ${TIMEOUT}s" >&2
        fi
        exec 9>&-
        WAIT_END_MS="$(_now_ms)"
        BLOCKED_MS=$((WAIT_END_MS - WAIT_START_MS))

        # Cleanup — always remove the flag + FIFO, so subsequent cycles start clean.
        rm -f "$FLAG_PATH" "$FIFO_PATH"
        _aggregator_append "envelope.operator-responded"
        ;;
esac

# Always log orchestrator event (silent surfacing is still surfacing).
_log_orchestrator "$MODE" "$ENVELOPE_PATH" "$BLOCKED_MS"

exit "$EXIT_CODE"
