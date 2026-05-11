#!/usr/bin/env bash
# =============================================================================
# pair-relay-validate.sh — Pair-relay composition descriptor validator
# =============================================================================
# Cycle: cycle-craft-cluster (simstim-20260511-craftc1c5), Sprint 2, task B.2
# PRD/SDD: §2.1 (RFC #235)
#
# Validates a pair-relay composition YAML/JSON file against
# data/trajectory-schemas/pair-relay-composition.schema.json plus the
# cross-field semantic rules from SDD §2.1.1:
#
#   - max_cycles >= sequence.length
#   - Every construct slug resolves via construct-resolve.sh (unless --no-resolve)
#
# Exit codes (per sprint.md B.2 acceptance):
#   0   OK
#   1   Schema error (required-field missing, type mismatch, regex/enum violation,
#       JSON/YAML parse error, file not found)
#   2   Semantic error (cross-field rule violation, unresolvable slug)
#
# Usage:
#   pair-relay-validate.sh <composition_path> [--no-resolve] [--json]
#                                              [--schema <path>] [--resolver <path>]
#
# Composition file format: YAML (.yaml/.yml) or JSON (.json) — sniffed by extension.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSTRATE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default schema lookup: substrate-canonical first, then host-installed location.
DEFAULT_SCHEMA="$SUBSTRATE_ROOT/data/trajectory-schemas/pair-relay-composition.schema.json"
HOST_SCHEMA_FALLBACK="${LOA_PROJECT_ROOT:-$SUBSTRATE_ROOT}/.claude/data/trajectory-schemas/pair-relay-composition.schema.json"

# Default resolver lookup: host-installed expected.
DEFAULT_RESOLVER="${LOA_PROJECT_ROOT:-$SUBSTRATE_ROOT}/.claude/scripts/construct-resolve.sh"

usage() {
    cat <<EOF
Usage: pair-relay-validate.sh <composition_path> [options]

Options:
  --no-resolve      Skip construct-slug resolution (for unit-test fixtures)
  --json            Emit structured JSON report to stdout
  --schema PATH     Override schema path
  --resolver PATH   Override construct-resolve.sh path
  -h, --help        Show this help

Exit codes:
  0  OK
  1  Schema error
  2  Semantic error (cross-field or slug resolution)
EOF
}

COMPOSITION_PATH=""
NO_RESOLVE=0
EMIT_JSON=0
SCHEMA_OVERRIDE=""
RESOLVER_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-resolve) NO_RESOLVE=1; shift ;;
        --json) EMIT_JSON=1; shift ;;
        --schema) SCHEMA_OVERRIDE="$2"; shift 2 ;;
        --resolver) RESOLVER_OVERRIDE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "ERROR: unknown flag '$1'" >&2; usage >&2; exit 1 ;;
        *) if [[ -z "$COMPOSITION_PATH" ]]; then COMPOSITION_PATH="$1"; else echo "ERROR: extra positional arg '$1'" >&2; exit 1; fi; shift ;;
    esac
done

if [[ -z "$COMPOSITION_PATH" ]]; then
    echo "ERROR: composition_path required" >&2
    usage >&2
    exit 1
fi

if [[ ! -f "$COMPOSITION_PATH" ]]; then
    echo "ERROR: composition not found: $COMPOSITION_PATH" >&2
    exit 1
fi

# Resolve schema path: --schema > substrate-canonical > host-installed
if [[ -n "$SCHEMA_OVERRIDE" ]]; then
    SCHEMA_PATH="$SCHEMA_OVERRIDE"
elif [[ -f "$DEFAULT_SCHEMA" ]]; then
    SCHEMA_PATH="$DEFAULT_SCHEMA"
elif [[ -f "$HOST_SCHEMA_FALLBACK" ]]; then
    SCHEMA_PATH="$HOST_SCHEMA_FALLBACK"
else
    echo "ERROR: schema not found (tried: $DEFAULT_SCHEMA, $HOST_SCHEMA_FALLBACK)" >&2
    exit 1
fi

if [[ ! -f "$SCHEMA_PATH" ]]; then
    echo "ERROR: schema override path missing: $SCHEMA_PATH" >&2
    exit 1
fi

# Resolve resolver path: --resolver > LOA_PROJECT_ROOT/.claude/scripts > on PATH.
# Explicit --resolver must point at an executable file; otherwise we treat it
# the same as "no resolver available" so the resolver_missing branch fires.
if [[ -n "$RESOLVER_OVERRIDE" ]]; then
    if [[ -x "$RESOLVER_OVERRIDE" ]]; then
        RESOLVER_PATH="$RESOLVER_OVERRIDE"
    else
        RESOLVER_PATH=""
    fi
elif [[ -x "$DEFAULT_RESOLVER" ]]; then
    RESOLVER_PATH="$DEFAULT_RESOLVER"
elif command -v construct-resolve.sh >/dev/null 2>&1; then
    RESOLVER_PATH="$(command -v construct-resolve.sh)"
else
    RESOLVER_PATH=""
fi

# Phase 1: schema validation (embedded Python jsonschema)
SCHEMA_RESULT="$(python3 - "$COMPOSITION_PATH" "$SCHEMA_PATH" <<'PYEOF'
import json
import sys
from pathlib import Path

composition_path = Path(sys.argv[1])
schema_path = Path(sys.argv[2])

result = {"phase": "schema", "ok": False, "errors": []}

try:
    import jsonschema
except ImportError:
    result["errors"].append({"kind": "missing_dependency", "msg": "python3 jsonschema package not installed"})
    print(json.dumps(result))
    sys.exit(0)

# Parse composition (YAML or JSON)
suffix = composition_path.suffix.lower()
try:
    raw = composition_path.read_text()
    if suffix in (".yaml", ".yml"):
        try:
            import yaml
        except ImportError:
            result["errors"].append({"kind": "missing_dependency", "msg": "python3 pyyaml package not installed"})
            print(json.dumps(result))
            sys.exit(0)
        composition = yaml.safe_load(raw)
    else:
        composition = json.loads(raw)
except Exception as e:
    result["errors"].append({"kind": "parse_error", "msg": f"{type(e).__name__}: {e}"})
    print(json.dumps(result))
    sys.exit(0)

# Load + validate schema itself
try:
    schema = json.loads(schema_path.read_text())
    jsonschema.Draft202012Validator.check_schema(schema)
except Exception as e:
    result["errors"].append({"kind": "schema_load_error", "msg": f"{type(e).__name__}: {e}"})
    print(json.dumps(result))
    sys.exit(0)

# Validate composition against schema
validator = jsonschema.Draft202012Validator(schema)
errors = sorted(validator.iter_errors(composition), key=lambda e: list(e.absolute_path))
if errors:
    for err in errors:
        result["errors"].append({
            "kind": "schema_violation",
            "path": "/".join(str(p) for p in err.absolute_path) or "<root>",
            "msg": err.message,
        })
    print(json.dumps(result))
    sys.exit(0)

result["ok"] = True
# Pass through composition data for phase 2
result["composition"] = composition
print(json.dumps(result))
sys.exit(0)
PYEOF
)"

SCHEMA_OK="$(echo "$SCHEMA_RESULT" | python3 -c 'import json,sys; r=json.load(sys.stdin); print("yes" if r["ok"] else "no")')"

if [[ "$SCHEMA_OK" != "yes" ]]; then
    if [[ "$EMIT_JSON" -eq 1 ]]; then
        echo "$SCHEMA_RESULT"
    else
        echo "$SCHEMA_RESULT" | python3 -c '
import json, sys
r = json.load(sys.stdin)
print("[SCHEMA-FAIL]", file=sys.stderr)
for e in r["errors"]:
    kind = e["kind"]
    path = e.get("path", "")
    msg = e["msg"]
    print("  " + kind + ": " + path + " :: " + msg, file=sys.stderr)
'
    fi
    exit 1
fi

# Phase 2: semantic checks
SEMANTIC_RESULT="$(echo "$SCHEMA_RESULT" | python3 -c '
import json, sys
r = json.load(sys.stdin)
comp = r["composition"]
errors = []

seq_len = len(comp.get("sequence", []))
max_cycles = comp.get("max_cycles", 2)
if max_cycles < seq_len:
    errors.append({
        "kind": "max_cycles_too_low",
        "msg": f"max_cycles ({max_cycles}) must be >= sequence.length ({seq_len}) so at least one full walk completes",
    })

slugs = []
for i, stage in enumerate(comp.get("sequence", [])):
    slug = stage.get("construct")
    if slug:
        slugs.append((i, slug))

print(json.dumps({"errors": errors, "slugs": slugs}))
')"

PHASE2_ERRORS="$(echo "$SEMANTIC_RESULT" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(len(r["errors"]))')"
SLUGS_JSON="$(echo "$SEMANTIC_RESULT" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps(r["slugs"]))')"

# Slug resolution (unless --no-resolve)
SLUG_ERRORS_JSON='[]'
if [[ "$NO_RESOLVE" -ne 1 ]]; then
    if [[ -z "$RESOLVER_PATH" ]]; then
        # Resolver missing AND --no-resolve was not requested. Per SDD §2.1.1 every
        # slug must resolve or composition fails validation — treat missing resolver
        # as a semantic error so this doesn't silently pass in unconfigured envs.
        SLUG_ERRORS_JSON='[{"kind":"resolver_missing","msg":"construct-resolve.sh not found; pass --no-resolve for unit tests or --resolver <path>"}]'
    else
        SLUG_ERRORS_ACC="["
        FIRST=1
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            IDX="$(echo "$entry" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')"
            SLUG="$(echo "$entry" | python3 -c 'import json,sys; print(json.load(sys.stdin)[1])')"
            if ! "$RESOLVER_PATH" resolve "$SLUG" >/dev/null 2>&1; then
                if [[ "$FIRST" -eq 0 ]]; then SLUG_ERRORS_ACC+=","; fi
                SLUG_ERRORS_ACC+="{\"kind\":\"unresolvable_slug\",\"path\":\"sequence/$IDX/construct\",\"msg\":\"construct slug '$SLUG' did not resolve via $RESOLVER_PATH\"}"
                FIRST=0
            fi
        done < <(echo "$SLUGS_JSON" | python3 -c '
import json, sys
slugs = json.load(sys.stdin)
for entry in slugs:
    print(json.dumps(entry))
')
        SLUG_ERRORS_ACC+="]"
        SLUG_ERRORS_JSON="$SLUG_ERRORS_ACC"
    fi
fi

# Aggregate phase-2 + slug errors
TOTAL_SEMANTIC="$(python3 -c "
import json
phase2 = json.loads('''$SEMANTIC_RESULT''')['errors']
slug_errs = json.loads('''$SLUG_ERRORS_JSON''')
all_errs = phase2 + slug_errs
print(json.dumps({'ok': len(all_errs) == 0, 'errors': all_errs}))
")"

OK="$(echo "$TOTAL_SEMANTIC" | python3 -c 'import json,sys; print("yes" if json.load(sys.stdin)["ok"] else "no")')"

if [[ "$OK" == "yes" ]]; then
    if [[ "$EMIT_JSON" -eq 1 ]]; then
        echo '{"ok": true, "phase": "complete"}'
    else
        echo "OK: pair-relay composition validates"
    fi
    exit 0
fi

if [[ "$EMIT_JSON" -eq 1 ]]; then
    echo "$TOTAL_SEMANTIC"
else
    echo "[SEMANTIC-FAIL]" >&2
    echo "$TOTAL_SEMANTIC" | python3 -c '
import json, sys
r = json.load(sys.stdin)
for e in r["errors"]:
    kind = e["kind"]
    path = e.get("path", "")
    msg = e["msg"]
    print("  " + kind + ": " + path + " :: " + msg, file=sys.stderr)
'
fi
exit 2
