#!/usr/bin/env bats
# =============================================================================
# surface-envelope.bats — Sprint 2 B.3 acceptance
# =============================================================================
# Cycle: cycle-craft-cluster (simstim-20260511-craftc1c5)
# PRD/SDD: §2.1.3 (RFC #235); BR-CRAFT-005 remediation preserved
#
# Acceptance contract per grimoires/loa/sprint.md Sprint 2 B.3:
#   - bats tests cover all 3 modes + cleanup + FIFO timeout (env-overridable)
#   - summary <=24 lines <=80 cols
# =============================================================================

fail() {
    echo "FAIL: $*" >&2
    return 1
}

setup() {
    SUBSTRATE_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SURFACE="$SUBSTRATE_ROOT/scripts/surface-envelope.sh"

    [[ -x "$SURFACE" ]] || fail "surface-envelope.sh not executable at $SURFACE"

    TMPRUN="$(mktemp -d)"
    ENV="$TMPRUN/envelope.json"
    cat > "$ENV" <<'EOF'
{
  "construct_slug": "artisan",
  "output_type": "Verdict",
  "verdict": "fidelity-leaked",
  "invocation_mode": "Form-A",
  "cycle_id": "bats-1",
  "persona": "ALEXANDER",
  "why": {
    "rationale": "Sample rationale text used to verify summary mode line-wrapping and cap behavior in the surface-envelope script. This is intentionally a few sentences long to ensure that the textwrap path is exercised but stays well under the 8-line rationale cap.",
    "decisions_considered": ["alpha decision text", "beta decision text", "gamma decision text", "delta would-be-truncated"],
    "tools_used": ["scoring-experience", "Read", "Edit"]
  }
}
EOF
}

teardown() {
    if [[ -n "${TMPRUN:-}" && -d "$TMPRUN" ]]; then
        find "$TMPRUN" -delete 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# Mode dispatch
# -----------------------------------------------------------------------------

@test "silent mode: no stderr summary, orchestrator event logged, exit 0" {
    run "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 1 --mode silent
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status"
    # No '--- relay envelope ---' summary banner.
    [[ "$output" != *"--- relay envelope"* ]] || fail "silent leaked summary"
    [[ -f "$TMPRUN/orchestrator.jsonl" ]] || fail "orchestrator log missing"
    local mode
    mode="$(jq -r '.surface_mode' "$TMPRUN/orchestrator.jsonl")"
    [[ "$mode" == "silent" ]] || fail "expected surface_mode=silent in log, got $mode"
}

@test "summary mode: emits banner + key fields to stderr, exit 0" {
    run "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 2 --mode summary
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status"
    [[ "$output" == *"--- relay envelope (cycle 2) ---"* ]] || fail "missing banner"
    [[ "$output" == *"construct : artisan"* ]] || fail "missing construct line"
    [[ "$output" == *"persona   : ALEXANDER"* ]] || fail "missing persona line"
    [[ "$output" == *"verdict   : fidelity-leaked"* ]] || fail "missing verdict line"
    [[ "$output" == *"rationale"* ]] || fail "missing rationale line"
}

@test "summary mode: output stays within <=24 lines and <=80 columns per line" {
    run "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 3 --mode summary
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status"
    local line_count
    line_count="$(echo "$output" | wc -l | tr -d ' ')"
    [[ "$line_count" -le 24 ]] || fail "summary too tall: $line_count lines (cap 24)"
    local widest
    widest="$(echo "$output" | awk '{print length}' | sort -rn | head -1)"
    [[ "$widest" -le 80 ]] || fail "summary too wide: longest line $widest cols (cap 80)"
}

# -----------------------------------------------------------------------------
# Interactive mode: FIFO + side-channel + cleanup
# -----------------------------------------------------------------------------

@test "interactive mode: FIFO written within timeout returns exit 0 + cleans state" {
    ( sleep 0.2 && echo "go" > "$TMPRUN/.relay-control.fifo" ) &
    local writer=$!
    run "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 4 --mode interactive --timeout 5
    wait "$writer" 2>/dev/null || true
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status; out: $output"
    [[ ! -p "$TMPRUN/.relay-control.fifo" ]] || fail "FIFO not cleaned"
    [[ ! -f "$TMPRUN/WAITING-OPERATOR" ]] || fail "WAITING-OPERATOR flag not cleaned"
}

@test "interactive mode: FIFO timeout returns exit 2 + cleans state" {
    run "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 5 --mode interactive --timeout 1
    [[ "$status" -eq 2 ]] || fail "expected 2 got $status; out: $output"
    [[ "$output" == *"timed out after 1s"* ]] || fail "missing timeout msg: $output"
    [[ ! -p "$TMPRUN/.relay-control.fifo" ]] || fail "FIFO not cleaned"
    [[ ! -f "$TMPRUN/WAITING-OPERATOR" ]] || fail "WAITING-OPERATOR flag not cleaned"
}

@test "interactive mode: WAITING-OPERATOR side-channel + aggregator entries written" {
    # Use a slow writer so we can observe the side-channel flag during the wait.
    ( sleep 0.5 && [[ -f "$TMPRUN/WAITING-OPERATOR" ]] && echo "FLAG_OBSERVED" > "$TMPRUN/observed.txt"; echo "go" > "$TMPRUN/.relay-control.fifo" ) &
    local writer=$!
    run "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 6 --mode interactive --timeout 5
    wait "$writer" 2>/dev/null || true
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status; out: $output"
    [[ -f "$TMPRUN/observed.txt" ]] || fail "WAITING-OPERATOR flag was never visible during wait"
    # Aggregator lives one directory above the run-dir's parent (RUN_DIR is treated
    # as <state-root>/compose/<run_id>, so aggregator is at <state-root>/...).
    local aggregator_root agg
    aggregator_root="$(dirname "$(dirname "$TMPRUN")")"
    agg="$aggregator_root/waiting-on-operator.jsonl"
    [[ -f "$agg" ]] || fail "aggregator log not written at $agg"
    local n_waiting n_responded
    n_waiting="$(grep -c 'envelope.waiting-on-operator' "$agg" 2>/dev/null || echo 0)"
    n_responded="$(grep -c 'envelope.operator-responded' "$agg" 2>/dev/null || echo 0)"
    [[ "$n_waiting" -ge 1 && "$n_responded" -ge 1 ]] || fail "aggregator missing rows: waiting=$n_waiting responded=$n_responded"
    rm -f "$agg"
}

@test "interactive mode: timeout obeys LOA_SURFACE_ENVELOPE_FIFO_TIMEOUT_SECONDS env" {
    local start now elapsed
    start="$(date +%s)"
    run env LOA_SURFACE_ENVELOPE_FIFO_TIMEOUT_SECONDS=1 \
        "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 7 --mode interactive
    now="$(date +%s)"
    elapsed=$((now - start))
    [[ "$status" -eq 2 ]] || fail "expected 2 got $status"
    [[ "$elapsed" -le 3 ]] || fail "env-driven timeout did not honor LOA_..._SECONDS=1 (took ${elapsed}s)"
}

# -----------------------------------------------------------------------------
# Orchestrator logging
# -----------------------------------------------------------------------------

@test "orchestrator.jsonl: every surface call appends envelope.surfaced row" {
    "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 8 --mode silent >/dev/null
    "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 9 --mode summary >/dev/null 2>/dev/null
    local n
    n="$(wc -l < "$TMPRUN/orchestrator.jsonl" | tr -d ' ')"
    [[ "$n" -eq 2 ]] || fail "expected 2 orchestrator rows, got $n"
    local first_event
    first_event="$(head -1 "$TMPRUN/orchestrator.jsonl" | jq -r '.event')"
    [[ "$first_event" == "envelope.surfaced" ]] || fail "unexpected event $first_event"
}

@test "orchestrator.jsonl: blocked_ms is 0 for non-interactive modes" {
    "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 10 --mode silent >/dev/null
    local blocked
    blocked="$(jq -r '.blocked_ms' "$TMPRUN/orchestrator.jsonl")"
    [[ "$blocked" -eq 0 ]] || fail "silent mode should be blocked_ms=0, got $blocked"
}

# -----------------------------------------------------------------------------
# CLI surface
# -----------------------------------------------------------------------------

@test "cli: missing required args exits 1" {
    run "$SURFACE"
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status"
    [[ "$output" == *"required"* ]] || fail "expected required-args msg"
}

@test "cli: unknown mode exits 1" {
    run "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 1 --mode bogus
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status"
    [[ "$output" == *"silent|summary|interactive"* ]] || fail "expected enum msg"
}

@test "cli: missing envelope file exits 1" {
    run "$SURFACE" /tmp/definitely-not-an-envelope.json \
        --run-dir "$TMPRUN" --cycle 1 --mode silent
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status"
    [[ "$output" == *"not found"* ]] || fail "expected not-found msg"
}

@test "cli: non-integer --timeout exits 1" {
    run "$SURFACE" "$ENV" --run-dir "$TMPRUN" --cycle 1 --mode silent --timeout abc
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status"
    [[ "$output" == *"non-negative integer"* ]] || fail "expected integer-validation msg"
}

@test "cli: --help exits 0 and prints usage" {
    run "$SURFACE" --help
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status"
    [[ "$output" == *"surface-envelope.sh"* ]] || fail "expected usage banner"
}
