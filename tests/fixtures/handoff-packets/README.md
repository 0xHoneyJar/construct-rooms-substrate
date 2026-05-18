# Handoff packet fixtures

Test inputs for `construct-handoff.schema.json` validation. Positive fixtures MUST pass; negative fixtures MUST fail with the named reason.

## Positive (validation passes)

| File | Purpose |
|---|---|
| `valid-required-only.json` | Minimum legal envelope — only required fields. Hits the recommended-field-threshold blocker by design (used to test threshold behavior). |
| `valid-full.json` | v1.0 envelope with most fields populated. Backwards-compat anchor — must always pass under future schema versions. |
| `valid-with-vault-provenance.json` | v1.1 envelope demonstrating `source_provenance` + `kaironic_context` + `pushback_invitation` populated correctly. |

## Negative (validation fails — added 2026-05-15, v1.1.1)

| File | Failure reason | Closes finding |
|---|---|---|
| `invalid-vault-public-scope.json` | `source_type=vault` + `privacy_scope=public` → allOf rejects (vault MUST be actor_private). | BB-F1 + Flatline-SKP-001 |
| `invalid-vault-usable.json` | `source_type=vault` + `use_label=usable` → allOf rejects (raw vault MUST NOT be authority; use `source_type=activated_doctrine` instead). | Flatline-SKP-001-other |
| `invalid-empty-pushback.json` | `pushback_invitation: {}` → required fields `primary_uncertainty` + `operator_check` missing. | BB-F3 |
| `invalid-empty-kaironic.json` | `kaironic_context: {}` → required field `trigger` missing. | BB-F4 |

## Negative (validation fails — added 2026-05-17, v1.2)

| File | Failure reason | Closes finding |
|---|---|---|
| `invalid-empty-translation-note.json` | `translation_note: {}` → required field `note` missing. | construct-DDD cycle 2026-05-17 |
| `invalid-vague-translation-note.json` | `translation_note.note: "short note"` → minLength 30 not met. | construct-DDD cycle 2026-05-17 |
| `invalid-invalid-affinity-slug.json` | `source_construct_affinity` with `"The-Arcade"` / `"Some Bad Slug"` fails `^[a-z][a-z0-9-]*$` pattern. | construct-DDD cycle 2026-05-17 |

## Positive v1.2

| File | What it exercises |
|---|---|
| `valid-with-translation-note.json` | full v1.2 envelope: k-hole → artisan handoff with translation_note (now includes `privacy_scope: actor_private` per v1.2.1) + source_construct_affinity on vault + external sources. |

## Negative (validation fails — added 2026-05-17 v1.2.1, post-review iteration)

| File | Failure reason | Closes finding |
|---|---|---|
| `invalid-asymmetric-translation-pair.json` | `translation_note.from_construct` present but `to_construct` missing → allOf symmetric-pairing fails. | BB-medium-translation-note-pair-not-enforced + Flatline-SKP-002 (partial) |
| `invalid-v12-fields-without-version.json` | `translation_note` present but `schema_version: "1.0"` → root allOf forces `^1\.([2-9]...)$` when v1.2 fields present. | BB-medium-no-version-gate-on-translation-note + Flatline-IMP-010 |
| `invalid-duplicate-affinity.json` | `source_construct_affinity: ["the-arcade", "the-arcade"]` → uniqueItems fails. | BB-medium-no-uniqueitems-on-affinity |
| `invalid-trailing-hyphen-slug.json` | `"the-arcade-"` → tightened slug pattern `^[a-z][a-z0-9]*(-[a-z0-9]+)*$` rejects. | BB-medium-slug-pattern-allows-trailing-hyphen |

## Parity pair

`parity-pair/native-artisan-stage0.json` + `parity-pair/headless-artisan-stage0.json` exercise `handoff-parity-check.sh` (native vs headless divergence detection).

## Running

```bash
./scripts/handoff-validate.sh tests/fixtures/handoff-packets/<file> \
  --schema data/trajectory-schemas/construct-handoff.schema.json
```

Exit codes: `0` = OK, `1` = FAIL (required field missing or schema violation), `2` = BLOCKER (recommended overage > threshold).

Negative fixtures should produce exit `1` with the schema-violation reason matching the row above.
