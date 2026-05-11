#!/usr/bin/env bats
# =============================================================================
# pair-relay-validate.bats — Sprint 2 B.2 acceptance
# =============================================================================
# Cycle: cycle-craft-cluster (simstim-20260511-craftc1c5)
# PRD/SDD: §2.1.1 (RFC #235)
#
# Acceptance contract per grimoires/loa/sprint.md Sprint 2 B.2:
#   - bats tests green
#   - validator exits 1 on schema errors, exits 2 on semantic errors
#   - >=5 invalid fixtures + >=3 valid fixtures
# =============================================================================

fail() {
    echo "FAIL: $*" >&2
    return 1
}

setup() {
    SUBSTRATE_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    VALIDATOR="$SUBSTRATE_ROOT/scripts/pair-relay-validate.sh"
    SCHEMA="$SUBSTRATE_ROOT/data/trajectory-schemas/pair-relay-composition.schema.json"
    VALID_DIR="$SUBSTRATE_ROOT/tests/fixtures/pair-relay/valid"
    INVALID_DIR="$SUBSTRATE_ROOT/tests/fixtures/pair-relay/invalid"

    [[ -x "$VALIDATOR" ]] || fail "validator not executable at $VALIDATOR"
    [[ -f "$SCHEMA" ]] || fail "schema not found at $SCHEMA"
    [[ -d "$VALID_DIR" ]] || fail "valid fixture dir missing"
    [[ -d "$INVALID_DIR" ]] || fail "invalid fixture dir missing"
}

# -----------------------------------------------------------------------------
# Valid fixtures (exit 0)
# -----------------------------------------------------------------------------

@test "valid: minimal 2-stage composition exits 0" {
    run "$VALIDATOR" "$VALID_DIR/minimal-2-stage.composition.yaml" --no-resolve
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status; out: $output"
}

@test "valid: fidelity-relay 3-stage (artisan -> crucible -> artisan) exits 0" {
    run "$VALIDATOR" "$VALID_DIR/fidelity-3-stage.composition.yaml" --no-resolve
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status; out: $output"
}

@test "valid: access-relay 3-stage (kansei -> artisan -> kansei) exits 0" {
    run "$VALIDATOR" "$VALID_DIR/access-3-stage.composition.yaml" --no-resolve
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status; out: $output"
}

@test "valid: frame-relay 3-stage (rosenzu -> artisan -> rosenzu) exits 0" {
    run "$VALIDATOR" "$VALID_DIR/frame-3-stage.composition.yaml" --no-resolve
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status; out: $output"
}

@test "valid: --json mode emits {\"ok\": true ...} on success" {
    run "$VALIDATOR" "$VALID_DIR/minimal-2-stage.composition.yaml" --no-resolve --json
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status"
    echo "$output" | jq -e '.ok == true' >/dev/null || fail "json.ok != true; out: $output"
}

# -----------------------------------------------------------------------------
# Invalid: schema errors (exit 1)
# -----------------------------------------------------------------------------

@test "invalid: pattern != 'pair-relay' exits 1 (schema)" {
    run "$VALIDATOR" "$INVALID_DIR/01-wrong-pattern.composition.yaml" --no-resolve
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status; out: $output"
    [[ "$output" == *"SCHEMA-FAIL"* ]] || fail "expected SCHEMA-FAIL in output: $output"
}

@test "invalid: sequence < 2 entries exits 1 (schema minItems)" {
    run "$VALIDATOR" "$INVALID_DIR/02-sequence-too-short.composition.yaml" --no-resolve
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status; out: $output"
    [[ "$output" == *"SCHEMA-FAIL"* ]] || fail "expected SCHEMA-FAIL"
}

@test "invalid: missing required field artifact_name exits 1 (schema)" {
    run "$VALIDATOR" "$INVALID_DIR/03-missing-artifact-name.composition.yaml" --no-resolve
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status; out: $output"
    [[ "$output" == *"artifact_name"* ]] || fail "expected 'artifact_name' in error: $output"
}

@test "invalid: surface_mode enum violation exits 1 (schema)" {
    run "$VALIDATOR" "$INVALID_DIR/04-bad-surface-mode.composition.yaml" --no-resolve
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status; out: $output"
    [[ "$output" == *"surface_mode"* ]] || fail "expected 'surface_mode' in error"
}

@test "invalid: construct slug pattern violation exits 1 (schema)" {
    run "$VALIDATOR" "$INVALID_DIR/06-bad-slug-pattern.composition.yaml" --no-resolve
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status; out: $output"
    [[ "$output" == *"construct"* ]] || fail "expected 'construct' in error"
}

@test "invalid: additionalProperties rejected exits 1 (schema)" {
    run "$VALIDATOR" "$INVALID_DIR/07-extra-property.composition.yaml" --no-resolve
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status; out: $output"
    [[ "$output" == *"Additional"* || "$output" == *"unknown_field"* ]] || fail "expected additionalProperties msg: $output"
}

# -----------------------------------------------------------------------------
# Invalid: semantic errors (exit 2)
# -----------------------------------------------------------------------------

@test "invalid: max_cycles < sequence.length exits 2 (semantic)" {
    run "$VALIDATOR" "$INVALID_DIR/05-max-cycles-too-low.composition.yaml" --no-resolve
    [[ "$status" -eq 2 ]] || fail "expected 2 got $status; out: $output"
    [[ "$output" == *"SEMANTIC-FAIL"* ]] || fail "expected SEMANTIC-FAIL marker: $output"
    [[ "$output" == *"max_cycles_too_low"* ]] || fail "expected max_cycles_too_low kind: $output"
}

@test "invalid: --json mode on semantic failure still exits 2 with errors[]" {
    run "$VALIDATOR" "$INVALID_DIR/05-max-cycles-too-low.composition.yaml" --no-resolve --json
    [[ "$status" -eq 2 ]] || fail "expected 2 got $status"
    echo "$output" | jq -e '.ok == false' >/dev/null || fail "json.ok != false"
    local kind
    kind="$(echo "$output" | jq -r '.errors[0].kind')"
    [[ "$kind" == "max_cycles_too_low" ]] || fail "expected first error kind=max_cycles_too_low, got $kind"
}

# -----------------------------------------------------------------------------
# Slug resolution path
# -----------------------------------------------------------------------------

@test "slug-resolve: missing resolver + no --no-resolve flag exits 2" {
    # Explicit --resolver pointing at a path that doesn't exist routes through
    # the resolver_missing branch (validator treats a non-executable explicit
    # resolver as missing rather than failing every slug independently).
    run "$VALIDATOR" "$VALID_DIR/minimal-2-stage.composition.yaml" \
        --resolver /tmp/definitely-not-an-executable.sh
    [[ "$status" -eq 2 ]] || fail "expected 2 got $status; out: $output"
    [[ "$output" == *"resolver_missing"* ]] || fail "expected resolver_missing kind: $output"
}

@test "slug-resolve: stub resolver returning 0 lets validation pass" {
    local stub_dir
    stub_dir="$(mktemp -d)"
    cat > "$stub_dir/resolve-stub.sh" <<'STUB'
#!/usr/bin/env bash
# Always resolve successfully — used to exercise the slug-resolution branch
# when no real construct-resolve.sh is available.
exit 0
STUB
    chmod +x "$stub_dir/resolve-stub.sh"
    run "$VALIDATOR" "$VALID_DIR/fidelity-3-stage.composition.yaml" \
        --resolver "$stub_dir/resolve-stub.sh"
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status; out: $output"
    rm -rf "$stub_dir"
}

@test "slug-resolve: stub resolver returning 1 surfaces unresolvable_slug exit 2" {
    local stub_dir
    stub_dir="$(mktemp -d)"
    cat > "$stub_dir/resolve-stub.sh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$stub_dir/resolve-stub.sh"
    run "$VALIDATOR" "$VALID_DIR/fidelity-3-stage.composition.yaml" \
        --resolver "$stub_dir/resolve-stub.sh" --json
    [[ "$status" -eq 2 ]] || fail "expected 2 got $status; out: $output"
    local kind
    kind="$(echo "$output" | jq -r '.errors[0].kind')"
    [[ "$kind" == "unresolvable_slug" ]] || fail "expected unresolvable_slug, got $kind"
    rm -rf "$stub_dir"
}

# -----------------------------------------------------------------------------
# CLI surface
# -----------------------------------------------------------------------------

@test "cli: missing positional arg prints usage exits 1" {
    run "$VALIDATOR"
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status"
    [[ "$output" == *"composition_path required"* ]] || fail "expected usage msg"
}

@test "cli: nonexistent composition path exits 1" {
    run "$VALIDATOR" /tmp/definitely-not-a-real-composition.yaml --no-resolve
    [[ "$status" -eq 1 ]] || fail "expected 1 got $status"
    [[ "$output" == *"not found"* ]] || fail "expected 'not found' msg: $output"
}

@test "cli: --help exits 0 and prints usage" {
    run "$VALIDATOR" --help
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status"
    [[ "$output" == *"pair-relay-validate.sh"* ]] || fail "expected usage banner"
}

@test "cli: --schema override accepts a custom schema path" {
    run "$VALIDATOR" "$VALID_DIR/minimal-2-stage.composition.yaml" --no-resolve --schema "$SCHEMA"
    [[ "$status" -eq 0 ]] || fail "expected 0 got $status; out: $output"
}
