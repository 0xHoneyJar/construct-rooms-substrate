# Spinout from cycle-construct-rooms

This repo was extracted from [`0xHoneyJar/loa-constructs#234`](https://github.com/0xHoneyJar/loa-constructs/pull/234) (cycle: `simstim-20260509-aead9136`).

## Why a separate repo

`construct-rooms-substrate` is **substrate, not expertise**. It does not embody any construct — it provides the runtime that puts every construct into an isolated room. Architecturally it sits between:

- **L3 Runtime: `loa-finn`** (sessions, model routing, tool sandbox)
- **Constructs** (expertise packs: artisan, observer, k-hole, etc.)

The user's framing: *"this runtime substrate is exactly the missing gap between Finn and constructs."*

A pack that everyone composes with does not belong inside the network repo (loa-constructs) or the framework repo (loa). It is its own thing — opt-in, installable, versioned independently.

## What's in this repo

Identical to `loa-constructs/construct-rooms-substrate/` at the time of PR #234. 34 files:

- `README.md` — what this IS / what this IS NOT (read first)
- `construct.yaml` — pack manifest (slug, contributes, requirements, post_install, non_goals)
- `scripts/` — generator, validators, dispatcher, parity-check, migration
- `scripts/lib/` — adapter-generator.py, construct-handoff-lib.sh
- `templates/` — adapter template (instructs WHY-required handoffs)
- `data/{schemas,trajectory-schemas}/` — 3 JSON Schemas
- `hooks/{subagent-start,subagent-stop}/` + `INSTALLATION.md`
- `docs/runtime/` — operator-facing runtime doc
- `tests/integration/` — 4 bats suites (35 tests)
- `tests/fixtures/` — only this pack's fixtures

## Migration path

1. **Operator**: create GitHub repo `0xHoneyJar/construct-rooms-substrate`
   ```bash
   gh repo create 0xHoneyJar/construct-rooms-substrate --public --description "substrate that puts every loa construct into an isolated room"
   ```

2. **Wire remote + initial commit**:
   ```bash
   cd ~/Documents/GitHub/construct-rooms-substrate
   git remote add origin git@github.com:0xHoneyJar/construct-rooms-substrate.git
   git add -A
   git commit -m "feat: initial substrate extracted from loa-constructs#234

   First-class repo for the runtime substrate. Contents mirror the cycle-construct-rooms pack source. See README.md for what this IS / IS NOT, and SPINOUT.md for migration provenance.

   Originating cycle: simstim-20260509-aead9136
   Originating PR: https://github.com/0xHoneyJar/loa-constructs/pull/234

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   git push -u origin main
   ```

3. **Register with Loa Constructs Network**: publish to `constructs.network` registry per the network's pack-publishing flow. After registration, `/constructs install construct-rooms-substrate` in any Loa-mounted repo will pull this pack.

4. **Retire the loa-constructs duplication**: open follow-up PR in loa-constructs that:
   - Deletes `loa-constructs/construct-rooms-substrate/` (now lives in its own repo)
   - Optionally deletes `loa-constructs/.claude/{scripts,data,hooks,agents}/` cycle-substrate files (consumers install via `/constructs install construct-rooms-substrate`)
   - Updates loa-constructs README to reference this repo

## What's deliberately not done in the spinout

- **Not pushed.** The local repo is initialized but no remote. Operator decides when + where to push.
- **No new GitHub repo created.** That's an operator action requiring `gh repo create`.
- **No registry publication.** Requires the network's publish flow.
- **No git remote configured.** See migration step 2 above.
- **No initial commit made.** The 34 files are unstaged in the new repo. Inspect first, commit when ready.

## Pre-publication checklist

Before pushing + publishing:

- [ ] Verify all 35 bats tests pass against the substrate when installed in a fresh repo
- [ ] Verify the construct-adapter-gen.sh works against `~/.loa/constructs/packs/<slug>/construct.yaml` paths (not just loa-constructs's `.claude/constructs/packs/`)
- [ ] Decide on initial version (suggest `0.1.0` per the manifest)
- [ ] Address Bridgebuilder F002, F003, F004, F006-F018 (12 MEDIUM/LOW polish items deferred from cycle-construct-rooms — see PR #234 review thread)
- [ ] Decide whether to ship with `loa-validator-*` migration script or strip it (it's specific to the .claude/subagents/ legacy migration; not all consumers need it)
- [ ] Run `migrate-subagents-verify.sh` shape against a clean repo

## Future-cycle work

- **Hounfour-routed model selection**: integrate `loa-hounfour@8.3.1` intelligence routing so adapter `model:` field reflects task-adaptive routing rather than `inherit`. See construct-rooms-substrate README §"Model routing & token cost".
- **Observability station**: a small UI (zero-native.dev evaluated, alternatives welcome) that visualizes envelope chains across multi-stage compositions. Render the structured `why` fields, surface rationale-vs-behavior divergence per the NLA paper.
- **Per-construct rehearsal**: S2-T7 from the originating cycle — operator-workflow rehearsal for Form A dispatch.
- **Hook integration verification**: empirical confirmation that Claude Code's `SubagentStart`/`SubagentStop` events actually fire the hooks at `.claude/hooks/subagent-{start,stop}/`. Currently bats tests invoke directly via env vars; production firing is operator-controlled.
