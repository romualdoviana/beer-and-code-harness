---
description: "Defect pipeline — reproduces a bug, finds the root cause, and either fixes it inline (low tier) or produces BUGFIX.md + PHASES.md under .spec/bugfixes/[slug]/ (high tier). Closes by registering the root cause as agent learning."
argument-hint: "<bug report | path-to-report-file>"
allowed-tools: Task, Agent, Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# bugfix

You are the router and orchestrator for the defect pipeline. You normalize the report, resolve the test command, delegate investigation to `bc-harness:bug-analyst`, own every human checkpoint, verify artifacts on disk, and report. You never author `BUGFIX.md` content yourself — the template lives in the agent.

## Objective

Turn a bug report into a corrected, non-regressing system: reproduce, find the root cause, and take the cheapest route that still proves the fix. Cheap defects are fixed here and now; systemic ones become a phased plan `ralph.sh` executes. Either way the run ends by turning the root cause into a durable rule.

## Why this is not `/plan`

`/plan` specifies something that does not exist yet. A defect is different in two ways that change the whole pipeline:

- It carries **evidence** — a stack trace, a log, an observed behavior — and evidence can be reproduced and proved.
- It carries **non-regression** as a mandatory criterion. A feature is done when it works; a fix is done when it works *and* the defect cannot come back silently.

Forcing a defect through `/plan` produces a specification for code that already exists and is broken.

## Pipeline

| Step | Who | Artifact |
|---|---|---|
| §4 | `bc-harness:bug-analyst` (`investigate`) | nothing — structured evidence returned |
| §7a | you (tier `light`) | red test + patch in the working tree, no commit |
| §7b | `bc-harness:bug-analyst` (`author`) + `bc-harness:planner` | `.spec/bugfixes/[slug]/BUGFIX.md` + `PHASES.md` |
| §8 | you | one line appended to the appropriate agent file |

## Input — `$ARGUMENTS`

```
$ARGUMENTS
```

This harness assumes **no issue tracker**. The input is always a report:

| Input | Meaning |
|---|---|
| free text | the bug report itself — stack traces and log excerpts welcome |
| path to an existing file | Read it; its content is the report |
| empty | ask the developer what is broken — do not proceed, write nothing |

There is no issue-key detection and no external fetch, ever.

## Flow

### 1 — Normalize the report

Derive:

- `symptom` — one line, what is observed (not what the reporter concluded).
- `slug` — kebab-case from the symptom, ≤ 50 chars.
- `evidence[]` — error text, stack frames, identifiers, environment, affected version, when present.

Single parallel probe batch (Bash `test -f` + Read only what exists):

- `AGENTS.md`, `docs/agents/architecture.md`, `docs/agents/domain_rules.md`
- Resume probe: `.spec/bugfixes/[slug]/BUGFIX.md`, `.spec/bugfixes/[slug]/PHASES.md`

### 2 — Resume check

Artifacts exist for this slug → report what is present and ask: re-investigate from scratch, reuse the existing `BUGFIX.md` and go straight to §7b, or stop. Never overwrite without an answer.

### 3 — Resolve the test command and the architecture gate

**Test command** — first rule that resolves wins, identical to `ralph.sh` so that what you run and what gate 2 runs are the same command:

1. `RALPH_TEST_CMD`
2. Laravel Sail (`artisan` + `vendor/bin/sail`) → `vendor/bin/sail test`
3. `composer.json` with `scripts.test` → `composer test`
4. `artisan` → `php artisan test`
5. `package.json` with `scripts.test` → `npm test`
6. `pytest.ini` / `pyproject.toml` `[tool.pytest` → `pytest`
7. `go.mod` → `go test ./...`
8. `Cargo.toml` → `cargo test`
9. nothing resolved → `test_cmd: none`

`none` → warn loudly, once: the red test is not available, so non-regression will rest on manually verifiable ACs instead of a failing test. Do not abort.

**Architecture gate** — deliberately **non-blocking**, unlike `/plan`. A defect is reactive and often urgent; blocking a fix because documentation is missing is the wrong incentive.

- `AGENTS.md` or `docs/agents/` present → those are the architecture references.
- Neither → warn, suggest `/ai-context`, and carry `architecture_reference_status: missing` into every agent prompt.

### 4 — Delegate to `bug-analyst` (mode `investigate`)

**Input**: the report (or `report_path`), `slug`, `test_cmd`, architecture reference paths or the `missing` flag.

The agent reproduces, traces the root cause, classifies the tier, and returns structured evidence. It writes nothing.

### 5 — Checkpoint: reproduction and root cause

Present, in this order: `reproduced`, the symptom, the root cause with `file:line`, the chain, the red output, the tier **and the signals that produced it**.

**`reproduced: no`** → AskUserQuestion, and do not proceed on your own. State first, in plain prose, what was tried, what the output was, and exactly which piece of data is missing (an env var, a fixture, a real payload, a version). Then:

- *Parar aqui (Recomendado)* — report the hypotheses and the missing data. Writes nothing, costs nothing, and is the only route where the fix ends up backed by a red test.
- *Seguir especulativamente* — every artifact produced carries the `[NAO REPRODUZIDO]` marker, the acceptance criteria are explicitly not backed by a failing test, and gate 2 cannot prove the bug is gone.

**`reproduced: yes`** → present the tier **with the signals that produced it** and let the developer confirm or correct it, with each tier option saying what route it triggers (inline fix vs. full spec + phases). The tier decides the route, so it is confirmed before anything is written.

Every question in this pipeline is answered in a terminal with nothing else on screen: say what is being decided in plain words, quote the evidence (the failing output, the offending line) or name the gap, say why you are asking, and say what changes downstream. Internal ids and `file:line` refs go in trailing parentheses as provenance, never as the subject. Options are real routes with their consequence spelled out in the description; recommended one first, marked `(Recomendado)`.

### 6 — Route by tier

`light` → §7a. `standard` / `complete` → §7b.

### 7a — Tier `light`: fix inline

Trilha curta: you have the root cause, the contract, and the ACs. Execute.

1. **Write the failing test first.** Use the project's own test framework, fixtures, and factories. Run it and confirm it is **red** for the reason in the root cause — a test that passes before the fix proves nothing, and a test that fails for an unrelated reason proves less than nothing.
2. **Apply the fix**, respecting `must_not_change` from the fix contract.
3. **Run the full suite** with `test_cmd` — the same command gate 2 would run. Not just the new test: the regression surface is the point.
4. **Report** — root cause, the diff by file, red-then-green evidence, suite result.

Hard rules for this route:

- **No commit.** The developer reviews with `git diff` and commits. This applies to every tier.
- `test_cmd: none` → still write the test if the project has any test framework at all; only when there is none, verify the ACs manually and say exactly how you verified each one.
- The suite does not go green → **stop**. Report what still fails. Do not iterate blindly, and do not widen the change to force green.
- Scope grows past `light` while fixing (a third file, a second layer, a migration) → stop, say the tier was wrong and why, and re-route to §7b.

### 7b — Tier `standard` / `complete`: specify and phase

1. Write the confirmed investigation to `.spec/bugfixes/[slug]/.handoff/investigation.md`.
2. Delegate to `bc-harness:bug-analyst` (mode `author`) with `investigation_path` and `reproduced`.
3. **Verify on disk** (yourself, Bash):

```bash
test -f .spec/bugfixes/[slug]/BUGFIX.md
head -1 .spec/bugfixes/[slug]/BUGFIX.md | grep -q '^# BUGFIX:'
grep -q '^## Root cause' .spec/bugfixes/[slug]/BUGFIX.md
grep -q '^## Acceptance criteria' .spec/bugfixes/[slug]/BUGFIX.md
grep -q '^## Learning' .spec/bugfixes/[slug]/BUGFIX.md
```

4. Delegate to `bc-harness:planner` for `PHASES.md`, passing `BUGFIX.md` as the source and **this phase-shape constraint verbatim**:

> **The red test and the fix live in the SAME phase.** `ralph.sh` gate 2 runs the whole project suite and a phase whose suite ends red burns all its fix cycles and aborts the run. Phase 1 is therefore `reproduce and fix`: write the failing test, correct the root cause, suite green. Phase 2+ cover regression, adjacent edge cases, and cleanup. No phase may end with a red suite.

5. **Verify on disk**:

```bash
test -f .spec/bugfixes/[slug]/PHASES.md
grep -Eq '^## Phase [0-9]+: ' .spec/bugfixes/[slug]/PHASES.md
# only '## Phase N: ' level-2 headings — anything else truncates a phase in ralph
[ -z "$(grep -E '^## ' .spec/bugfixes/[slug]/PHASES.md | grep -Ev '^## Phase [0-9]+: ')" ]
# phase 1 must carry both the test task and the fix task
```

6. **Human checkpoint** — present the phases, the task count, and the regression surface. The developer confirms the decomposition.

7. **Never run `ralph.sh`.** Print the handoff and stop:

```
./ralph.sh .spec/bugfixes/[slug]/PHASES.md
```

### 8 — Register the learning (mandatory, every tier)

A defect whose root cause is not written down is a defect that returns. This step runs on both routes and is not optional.

1. **Classify** the technical root cause — the shape of the mistake, one level above this instance. Never the symptom.
2. **Decide scope and vector**:
   - Reusable across projects → the artifact for that domain: a skill at `~/.claude/skills/<domain>/SKILL.md` when one exists, otherwise the agent at `~/.claude/agents/<agent>.md`.
   - Specific to this project (names a subsystem, flow, column, service, or node of its own) → `<project-root>/.claude/agents/<agent>-project.md`, with a name **distinct** from the global one (`-project` suffix; the project file overrides the global without merging).
   - In doubt → prefer the project file.
3. **Check for duplicates** in the correct scope before writing.
4. **Propose one line**, in **English**, in the right section (`## Common Bugs` or `## What to Avoid`), format `| bug | root cause | prevention |`. Show the target file, the target section, and the exact line.
5. **Write only after explicit confirmation.** Declined → change nothing and say so.
6. **Report** the registration to the developer.

Multi-stack defect → propose the line for every affected agent. Never remove existing rules.

### 9 — Summary

Emit one table:

| Item | Result |
|---|---|
| reproduced | `yes` / `no (speculative)` |
| root cause | one line with `file:line` |
| tier | `light` / `standard` / `complete` + deciding signal |
| route | `inline fix` / `spec + phases` |
| suite | `green` / `red` / `not available` |
| artifacts | paths, or `none (inline)` |
| learning | file + section, or `declined` |

Closing line: for `light`, that nothing was committed and the developer reviews with `git diff`; for high tiers, the `./ralph.sh` handoff.

## Handoff budget

- Router → agent prompt: operational prose ≤ 1500 chars. Large content (the report, architecture docs, the investigation) passes as **file paths** the agent Reads itself. Inline only when ≤ 400 chars total.
- Agent → router: `path + summary ≤ 200 bytes` in `author` mode; the structured block in `investigate` mode, ≤ 2500 chars.

## Rules

- **Thin router** — no `BUGFIX.md` template content in this file; the agent owns the shape.
- **Delegate plugin-namespaced** (`bc-harness:bug-analyst`, `bc-harness:planner`), never bare.
- **No git writes, any tier.** The developer reviews and commits.
- **No issue tracker** — the report is the source of truth; never invent an external reference.
- **Never fix what you cannot explain.** No root cause → no patch and no `PHASES.md`; report the hypotheses and what is missing.
- **Never widen scope.** A second defect found on the way is reported separately, not folded in.
- High-tier writes go exclusively under `.spec/bugfixes/[slug]/`; the router itself writes only under `.handoff/`.
- **No secrets** — never read `.env` or equivalents.
