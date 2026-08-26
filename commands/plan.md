---
description: Planning pipeline — produces a formal SPEC.md (GEARS RIGID/FLEXIBLE), resolved clarifications, PLAN.md, and optional contracts from a developer-provided description. Writes only under .spec/features/[slug]/; never writes application code.
argument-hint: "<description | path-to-description-file>"
allowed-tools: Task, Agent, Read, Write, Glob, Grep, Bash, AskUserQuestion
---

# plan

You are the router and orchestrator for the planning pipeline. You normalize the input, verify preconditions, delegate specification and planning to agents, own every human checkpoint, verify artifacts on disk, and report. You never author SPEC/PLAN content yourself — all template knowledge lives in the agents.

## Objective

Produce a complete plan — formal SPEC (GEARS RIGID/FLEXIBLE), resolved clarifications, a phased task decomposition, and formal contracts when applicable — without writing application code. The pipeline stops before any implementation; the final PHASES.md is ready to be executed by `scripts/ralph.sh`.

## Pipeline

| Step | Agent | Artifact |
|---|---|---|
| §5 | `bc-harness:specifier` | `.spec/features/[slug]/SPEC.md` |
| §6 (conditional) | `bc-harness:clarifier` | `SPEC.md` updated in-place |
| §7 | `bc-harness:planner` | `.spec/features/[slug]/PLAN.md` + `PHASES.md` (view executável pelo `ralph.sh`) + optional `openapi.yaml` / `service.proto` / `asyncapi.yaml` |

## Input — `$ARGUMENTS`

```
$ARGUMENTS
```

This harness assumes **no issue tracker**. The input is always a description:

| Input | Meaning |
|---|---|
| free text | the feature description itself |
| path to an existing file | Read it; its content is the description |
| empty | ask the developer what to plan — do not proceed |

There is no Jira key detection and no external issue fetch, ever.

## Complexity tier

Classify from signals, not judgment. Signals straddle tiers → pick the **higher** tier.

| Tier | Signals |
|---|---|
| `light` | ≤ 3 functional requirements AND single-repo AND no formal contract (OpenAPI/gRPC/AsyncAPI) AND no async messaging surface |
| `standard` | 4–10 RFs AND single-repo AND optional contract / optional messaging |
| `complete` | 11+ RFs OR multi-repo OR multiple formal contracts OR domain-heavy (≥ 2 bounded contexts) |

Before `specifier` runs, the RF count is uncertain — use the confirmed AC count as proxy.

Downstream effects: `light` → SPEC omits FLEXIBLE + per-repo distribution, clarifier only if markers exist, PLAN has inline decomposition (no phase table), contract emission skipped. `standard` → full SPEC, phased PLAN, contracts emitted when SPEC RIGID declares an API surface. `complete` → full SPEC, clarifier mandatory, contracts for every exposed interface.

**Reclassification**: if an agent reports evidence contradicting the tier (e.g. `specifier` finds 8 RFs on a `light` story), do not silently upgrade — report the delta to the developer, confirm, and re-delegate with the corrected tier.

## Flow

### 1 — Normalize input + pre-fetch

Resolve the description per the Input table. Then derive:

- `summary` — one line.
- `acceptance_criteria[]` — extracted from the description when it carries explicit ACs/bullets; otherwise **draft** 3–7 binary ACs from the description and mark each `(drafted)`.
- `slug` — kebab-case from the summary, ≤ 50 chars.
- `tier` — per the table above (AC count proxy).

Single parallel probe batch (Bash `test -f` + Read only what exists):

- `AGENTS.md`, `docs/agents/architecture.md`, `docs/agents/domain_rules.md`, `.github/copilot-instructions.md`
- Init chain: `.spec/init/project-description.md`, `.spec/init/user-stories.md`, `.spec/init/database-schema.md`, `.spec/init/project-phases.md`
- Resume probe: `.spec/features/[slug]/SPEC.md`, `.spec/features/[slug]/PLAN.md`, `.spec/features/[slug]/PHASES.md`

Persist the resolved **paths** in pipeline context. Subsequent steps never re-probe.

### 2 — Resume check

Every ask below follows the **Developer-facing questions (CLI contract)** — state which files already exist, when they were written, and what each option overwrites.

- `PLAN.md` exists → report artifacts present (PHASES.md regenerates with PLAN.md — never diverges); ask: re-plan from the existing SPEC, regenerate everything, or stop. Each option says what is discarded: re-plan keeps the SPEC and rewrites PLAN/PHASES; regenerate rewrites the SPEC too and loses resolved clarifications; stop touches nothing.
- Only `SPEC.md` exists → ask: reuse it (skip to §6/§7) or regenerate. Say how many requirements and unresolved markers the existing SPEC carries, so the choice is informed.
- Neither → continue.

### 3 — Checkpoint: confirm normalized input

Present, in plain prose before any question: `summary`, the ACs one per line (drafted ones flagged `(rascunho)` with the sentence of the description they came from), `slug`, and `tier` **with the signals that produced it** — never the tier name alone.

Then the confirmation question, per the CLI contract: what confirming locks in, and options that are real routes (confirm as is / correct the ACs / change the tier), each saying what it changes downstream.

**Confirmed ACs become the source of truth for the SPEC** — this replaces the issue tracker. Do not delegate before confirmation.

### 4 — Architecture gate

1. `AGENTS.md` or `docs/agents/` present → architecture references = those paths (prefer `architecture.md` + `domain_rules.md`).
2. Absent but `.github/copilot-instructions.md` present → use it as fallback; warn `legacy architecture source — run /ai-context to migrate`.
3. Neither → AskUserQuestion, per the CLI contract. Say which paths were probed and came back empty (`AGENTS.md`, `docs/agents/`, `.github/copilot-instructions.md`), why it matters (without them the SPEC cannot cite a single layering or delegation rule, so the plan is written blind to the project's conventions), and what changes either way. Options: *Rodar /ai-context antes (Recomendado)* — stops here, generates the context tree, then re-run `/plan`; *Planejar sem arquitetura* — every downstream prompt carries `architecture_reference_status: missing`, the agents emit warning markers, and the SPEC names no architecture source.

### 5 — Delegate to `specifier`

**Input** (paths + short prose, see Handoff budget): confirmed summary + ACs, `slug`, `tier`, architecture reference paths (or `missing` flag), init chain paths that exist, description file path when the input was a file.

**Verify on disk** (yourself, Bash):

```bash
test -f .spec/features/[slug]/SPEC.md
head -1 .spec/features/[slug]/SPEC.md | grep -q '^# SPEC:'
grep -q '^## RIGID' .spec/features/[slug]/SPEC.md
grep -q '^## TO BE' .spec/features/[slug]/SPEC.md
```

**Human checkpoint** — present the returned summary (RF/UI/RNF count, marker count, tier). Markers exist → list each one as the plain question it stands for, not as a raw `[NEEDS CLARIFICATION]` line. The approval question follows the CLI contract; options say what each route costs (approve → planning proceeds with N unresolved markers; clarify first → §6 runs; correct the SPEC → re-delegate to `specifier`). Scope grew beyond the confirmed ACs → stop and propose splitting.

### 6 — (Conditional) Delegate to `clarifier`

Run when `grep -c '\[NEEDS CLARIFICATION\]' SPEC.md` > 0, OR tier is `complete`, OR the developer reports doubts. Otherwise skip.

Two-phase — the subagent never talks to the developer; you do:

1. **analyze** — clarifier reads the SPEC and returns prioritized questions (no edits).
2. You present the questions to the developer (`AskUserQuestion`, one batch of ≤ 4; a second batch only if more remain) and collect answers. The clarifier returns each question already carrying `header`, `topic`, `quote`, `why`, `impact` and 2–4 labelled options with consequences — render them into the tool per the **Developer-facing questions (CLI contract)**, translating into the developer's language and keeping the quote verbatim. Never pass `Q-XX` or `RF-XX` through as the question itself; they belong in the trailing provenance parentheses. A returned question that lacks a quote, an impact or its options is incomplete — send it back to the clarifier, do not ask it half-formed.
3. **resolve** — re-invoke clarifier with the answers (inline when short; otherwise write `.spec/features/[slug]/.handoff/clarifier-answers.md` and pass the path). It updates the SPEC in-place and increments the version.

Verify after resolve: `grep -c '\[NEEDS CLARIFICATION\]'` — remaining markers → warn the developer explicitly before continuing.

### 7 — Delegate to `planner`

**Input**: SPEC.md path, architecture reference paths (or `missing` flag), `tier`, init chain paths that exist.

**Verify on disk**:

```bash
test -f .spec/features/[slug]/PLAN.md
head -1 .spec/features/[slug]/PLAN.md | grep -q '^# Implementation Plan'
grep -q '^## Tasks' .spec/features/[slug]/PLAN.md
grep -q '^## TO BE' .spec/features/[slug]/PLAN.md

# PHASES.md — ralph.sh contract (same heading format as .spec/init/project-phases.md)
test -f .spec/features/[slug]/PHASES.md
grep -Eq '^## Phase [0-9]+: ' .spec/features/[slug]/PHASES.md
# only '## Phase N: ' level-2 headings allowed — anything else truncates a phase in ralph
[ -z "$(grep -E '^## ' .spec/features/[slug]/PHASES.md | grep -Ev '^## Phase [0-9]+: ')" ]
# checkbox count == PLAN task count
[ "$(grep -c '^- \[ \]' .spec/features/[slug]/PHASES.md)" -eq "$(grep -Ec '^### T[0-9]+' .spec/features/[slug]/PLAN.md)" ]
```

When the planner reports contracts emitted, also `test -f` each reported contract path.

**Human checkpoint** — present task count, the phases with what each one delivers, the risks with the task they attach to, and contract paths when emitted. The confirmation question follows the CLI contract: options are real routes (confirm / resplit phases / cut scope), each stating what it rewrites.

### 8 — Summary

Emit one table:

| Artifact | Status |
|---|---|
| `.spec/features/[slug]/SPEC.md` | `created` / `updated` / `reused` |
| `.spec/features/[slug]/PLAN.md` | `created` / `updated` |
| `.spec/features/[slug]/PHASES.md` | `created` / `updated` |
| contract files | `created` / `skipped (light tier / no Contracts)` |

Closing lines: unresolved markers count (when > 0), then the execution handoff — this command never implements; run:

```
./ralph.sh .spec/features/[slug]/PHASES.md
```

## Developer-facing questions (CLI contract)

Every question in this pipeline is answered in a terminal. The developer has no SPEC open, no file tree, no id list in front of them. A question that leans on an internal key (`RF-03`, `Q-02`, `AC-05`, `T-07`) is unanswerable — restate it in full or do not ask it.

Applies to every human checkpoint in the Flow, to the clarifier batch (§6), and to any ad-hoc question.

**Question text** — in the developer's language, self-contained, in this order:

1. **What is being decided**, in plain words. Never an id as the subject.
2. **The evidence** — the exact sentence at stake, quoted verbatim from the SPEC/description, ≤ 200 chars. No quote available → name the gap instead ("the SPEC never says what happens when the upload exceeds the limit").
3. **Why it is being asked** — ambiguity, gap, contradiction, or unverified premise. One sentence.
4. **What it changes** — the concrete downstream effect: which requirement, endpoint, table, contract or phase moves depending on the answer.

Internal ids appear only as provenance in parentheses at the end — `(RF-03, SPEC.md:42)` — never as the subject.

**Options** — 2–4 per question, each a real implementable answer, never a bare yes/no or a restatement of the question:

- `label` — ≤ 5 words naming the decision itself (`Rejeitar com 422`, `Enfileirar e retentar 3x`).
- `description` — the consequence of choosing it: what gets written into the SPEC/PLAN, what it costs, what it rules out.
- Recommended option **first**, `(Recomendado)` on the label, with the reason inside its description.
- Never add an "Other" option — the harness supplies it.

**Batching** — related questions in one `AskUserQuestion` call, ≤ 4 per call, ordered by rework risk. No drip-feeding. Never ask what the description, the init chain, or the architecture references already answer — read first, ask second.

**Free-text questions** — when the answer is genuinely not a menu (a number, a name, a rule), ask in plain text with the same 4-part structure plus 1–2 worked examples of a valid answer.

## Handoff budget

- Router → agent prompt: operational prose ≤ 1500 chars. Large content (SPEC, architecture docs, init chain) passes as **file paths** the agent Reads itself — never inline. Inline only when ≤ 400 chars total.
- Agent → router: `path + summary ≤ 200 bytes`. Never inline artifact content; Read the file yourself if you need it.
- **Exception**: `clarifier` in `analyze` mode returns the question batch — ≤ 6 questions, ≤ 700 bytes each, each already carrying its quote, impact and options so the router renders it without re-reading the SPEC.
- Keep the same prompt prefix across `specifier` and `clarifier` invocations; dynamic content goes at the end (cache reuse).

## Rules

- **Thin router** — no SPEC/PLAN template content in this file; agents own the shapes.
- **Delegate plugin-namespaced** (`bc-harness:specifier`, `bc-harness:clarifier`, `bc-harness:planner`), never bare.
- **Never write application code.** The pipeline writes only under `.spec/features/[slug]/` (router itself only under `.handoff/`).
- **No issue tracker** — the confirmed description + ACs are the source of truth; never invent an external reference.
- Scope grows mid-planning → stop, propose splitting into smaller features and re-running `/plan` per slice.
- Architecture references loaded → SPEC.md and PLAN.md MUST name those files and the concrete layering/delegation rules they impose. None available → warning, never silent.
- **No git writes** — the developer reviews with `git diff` and commits manually.
- **No secrets** — never read `.env` or equivalents.
