# Beer and Code Harness (`bc-harness`)

> 🇧🇷 [Documentação em português](README.pt-BR.md)

A [Claude Code](https://claude.com/claude-code) plugin with commands, agents, and scripts that take a project from idea to implementation in a structured way: formal specification, phased planning, and autonomous execution with mechanical validation — while keeping a human in control at every decision point.

The harness is **stack-agnostic**: language, framework, commands, and conventions are defined by the project's own documents (`AGENTS.md`, `CLAUDE.md`, the `.spec/` chain), never by the harness.

## Workflow overview

```
 IDEA                                              CODE
   │                                                 ▲
   ▼                                                 │
 /init:project-description  ──┐                      │
 /init:user-stories           │  init chain          │
 /init:database-schema        │  (.spec/init/)       │
 /init:project-phases       ──┘                      │
   │                                                 │
   │            /plan "<feature description>"        │
   │            (.spec/features/<slug>/)             │
   ▼                                                 │
 project-phases.md  or  PHASES.md ────────► scripts/ralph.sh
                                            (autonomous execution
                                             with 4 gates)
   ▲                                                 │
   │            /bugfix "<bug report>"               │
   │            light  ─► inline fix, no commit  ────┤
   └──────────  high   ─► .spec/bugfixes/<slug>/     │
                                                     │
 /ai-context ─► AGENTS.md + docs/agents/*  (documents the ALREADY implemented
                                            code; feeds /plan, /bugfix, ralph)
```

Four independent pipelines that fit together:

1. **`/init`** — from zero to a project build plan (description → user stories → schema → phases).
2. **`/plan`** — from a feature description to a formal SPEC + phased plan, ready for execution.
3. **`/bugfix`** — from a bug report to a proved root cause and a fix: inline when the defect is small, phased when it is systemic.
4. **`ralph.sh`** — executes any phase document autonomously, one fresh agent session per phase, with mechanical gates and one commit per completed phase.

Cross-cutting: **`/ai-context`** keeps the context tree (`AGENTS.md`, `CLAUDE.md`, `docs/agents/*.md`) in sync with the real code.

## Installation

This repository is a Claude Code plugin (`.claude-plugin/plugin.json`). Install it via marketplace/local path according to your plugin setup:

```
/plugin install bc-harness
```

Commands are namespaced: `/bc-harness:init`, `/bc-harness:plan`, etc. (abbreviated without the namespace throughout this document).

`ralph.sh` is a standalone bash script — copy or reference `scripts/ralph.sh` and run it directly in the target project's repository.

Current plugin version: **0.5.0** (`.claude-plugin/plugin.json`). `ralph.sh` has no version of its own — it ships with the plugin.

**ralph.sh prerequisites:**

- Codex engine (default): `npm install -g @openai/codex`, authenticated
- Claude engine: `npm install -g @anthropic-ai/claude-code`, authenticated, **plus `jq`** (required: every claude verdict is read from the `stream-json` output)
- Preflight only checks that the engine CLI is on `PATH` — a logged-in CLI or an exported API key both work
- bash 4+, git, coreutils; optional `python3` (`--serve`), `docker` (environment recovery)
- Root of a git repository with a **clean** working tree

## Commands

### `/init` — init chain router

Shows the state of the `.spec/init/` artifacts (present / absent / stale) and **invokes the next command in the chain** (one hop per run — re-run `/init` to advance). Writes nothing itself; all authoring lives in the invoked `init:*` command.

The chain, in order:

| # | Artifact | Command | Inputs |
|---|---|---|---|
| 1 | `.spec/init/project-description.md` | `/init:project-description` | — (head of chain) |
| 2 | `.spec/init/user-stories.md` | `/init:user-stories` | project-description |
| 3 | `.spec/init/database-schema.md` | `/init:database-schema` | description + stories |
| 4 | `.spec/init/project-phases.md` | `/init:project-phases` | description + stories + schema |
| — | `.spec/init/design/` | manual (optional) | — |

Every generated artifact carries a **stamp** of its inputs on line 3 (`file@sha256:<12 chars>`). If an input changes later, `/init` detects it and reports the downstream artifact as *stale* — re-running the corresponding command is upsert-safe: it interviews only about the deltas and refreshes the stamp.

- **`/init:project-description`** — interviews the developer, discovers the stack, and produces a structured project description.
- **`/init:user-stories`** — derives structured, testable user stories from the description.
- **`/init:database-schema`** — derives a suggested database schema in DBML.
- **`/init:project-phases`** — plans the build into numbered, agent-ready phases with tasks, acceptance criteria, and feature tests. **This is `ralph.sh`'s default input.** Reads `.spec/init/design/` when present (screen/component refs).

### `/plan` — feature planning pipeline

```
/plan "<feature description or path to a description file>"
```

Produces, under `.spec/features/<slug>/`:

| Artifact | Content |
|---|---|
| `SPEC.md` | Formal specification in GEARS syntax, with RIGID/FLEXIBLE sections, AS IS / TO BE diagrams, and binary acceptance criteria |
| `PLAN.md` | Architecture-aware task decomposition with dependency phases, risks, and validation criteria |
| `PHASES.md` | The PLAN rendered in the format executable by `ralph.sh` |
| `openapi.yaml` / `service.proto` / `asyncapi.yaml` | Formal contracts, when the SPEC declares an API surface (conditional) |

Key characteristics:

- **No issue tracker** — the confirmed description + ACs are the source of truth. No Jira.
- **Complexity tier** (`light` / `standard` / `complete`) classified from objective signals (requirement count, multi-repo, contracts, messaging); adjusts SPEC depth, whether the clarifier is mandatory, and contract emission.
- **Human checkpoints** at every step: confirmation of the normalized input, SPEC approval, ambiguity resolution, decomposition sign-off.
- **Two-phase clarifier** — the agent analyzes the SPEC and returns prioritized questions; the router presents them to the developer and re-invokes the agent with the answers, which updates the SPEC in-place.
- **Architecture gate** — requires `AGENTS.md` / `docs/agents/` (or warns and flags `architecture_reference_status: missing`). The pipeline never plans silently without architecture context.
- **Per-phase task numbering** — `PHASES.md` checkboxes restart at `T01` inside every phase, with a trailing `(PLAN: TNN)` tag pointing back to the PLAN.md task. ralph's gate 3 indexes tasks by position within the phase, so continuous numbering across phases would fail a finished phase.
- **Screens without an artboard** — a task with a `Tela:` field whose PNG-target (3rd field) is empty must carry `Referência visual:` and `Layout:` lines; the 3rd field is positional, never prose.
- **Never writes application code.** The close-out points at the execution handoff:

```bash
./ralph.sh .spec/features/<slug>/PHASES.md
```

### `/bugfix` — defect pipeline

```
/bugfix "<bug report or path to a report file>"
```

`/plan` specifies something that does not exist yet. A defect is different in two ways that change the whole pipeline: it carries **evidence** (stack trace, log, observed behavior) that can be reproduced and proved, and it carries **non-regression** as a mandatory criterion. Forcing a defect through `/plan` produces a specification for code that already exists and is broken.

The pipeline reproduces the bug, traces the root cause, then takes the cheapest route that still proves the fix:

| Tier | Signals | Route |
|---|---|---|
| `light` | root cause identified AND ≤ 2 files AND single layer AND no migration AND no public contract change | fixed inline: failing test → patch → full suite, **no commit** |
| `standard` | 3+ files OR 2+ layers OR requires a migration OR alters an API/event contract | `.spec/bugfixes/<slug>/BUGFIX.md` + `PHASES.md` |
| `complete` | multi-repo OR systemic root cause OR cascading regression risk | same as `standard` |

Signals straddle tiers → the higher tier wins. The tier is presented **with the signals that produced it** and confirmed by the developer before anything is written.

Key characteristics:

- **Root cause, never symptom.** No root cause → no patch and no `PHASES.md`. The command reports the hypotheses and what data is missing.
- **Red test first.** The test command is resolved with the exact same rules `ralph.sh` uses, so what the fix runs and what gate 2 runs are the same command. No test runner in the project → loud warning and manually verifiable ACs instead.
- **The red test and the fix live in the same phase.** `ralph.sh` gate 2 runs the tests the phase touched (and the whole suite on the last one); a phase ending red would burn all its fix cycles and abort the run. Phase 1 is `reproduce and fix`; phase 2+ cover regression and edge cases. No phase ever ends with a red suite.
- **Unreproduced bug stops at a checkpoint.** The developer chooses: stop and gather data, or proceed speculatively — in which case every artifact carries the `[NAO REPRODUZIDO]` marker and the ACs are explicitly not backed by a failing test.
- **Non-blocking architecture gate**, unlike `/plan`: a defect is reactive and often urgent, so a missing `AGENTS.md` produces a warning and an `architecture_reference_status: missing` flag, never a block.
- **Closes by registering the learning.** The root cause is classified one level above this instance, scoped (global vs `-project`), and proposed as a single `| bug | root cause | prevention |` line in English for the right agent file — written only after explicit confirmation.
- **No git writes, any tier.** The developer reviews with `git diff` and commits.

High tier closes with the execution handoff:

```bash
./ralph.sh .spec/bugfixes/<slug>/PHASES.md
```

### `/ai-context` — canonical context tree

```
/ai-context [path] [+file] [-file] [--adopt]
```

Generates or refreshes 10 artifacts from the **implemented code** (never reads `.spec/`):

| Artifact | Content |
|---|---|
| `AGENTS.md` | 6 sections: commands, conventions, behavioral rules, setup, references, docs index |
| `CLAUDE.md` | ≤ 400-byte redirect to AGENTS.md |
| `docs/agents/project_overview.md` | Purpose, consumers, macro flow |
| `docs/agents/architecture.md` | Style, layout, layer responsibilities |
| `docs/agents/tech_stack.md` | Language, framework, runtime, test tooling |
| `docs/agents/coding_guidelines.md` | ≥ 3 observed patterns + enforcement |
| `docs/agents/domain_rules.md` | Business rules as implemented |
| `docs/agents/api_contracts.md` | Endpoints, payloads, message formats |
| `docs/agents/data_model.md` | Entities, storage, migrations |
| `docs/agents/dependencies.md` | External services, internal libs, shared infra |

Core rules:

- **Idempotent** — safe upsert; re-running updates only what drifted.
- **Documents reality (AS IS)** — code, manifests, CI, and configs are the only sources; never invents, never prescribes.
- **Ownership contract** — every generated file carries a banner on line 3. A file without the banner (hand-written) is never clobbered; `--adopt` folds its concrete rules into the generated tree and takes ownership.
- **Preserves third-party blocks** — `<tag>...</tag>` regions (e.g. Laravel Boost) are re-appended verbatim on regeneration. A block closes only on the closing tag **with the same name**, so inner lines such as `</code-snippet>` stay inside it.
- `+file` / `-file` filters generate only a subset (e.g. `/ai-context +AGENTS +architecture`).

## `scripts/ralph.sh` — execution orchestrator

Reads a phase document, splits it on the `## Phase N: <title>` heading, and feeds each phase to a **fresh** Codex CLI or Claude Code session, with no human interaction from start to finish.

```bash
./scripts/ralph.sh [options] [path-to-file]
```

With no argument, the input resolves in this order: `.spec/init/project-phases.md` → `.spec/project-phases.md` (pre-init layout, with a warning). A feature `PHASES.md` is also valid input.

> **Autonomy and permissions note**: ralph is an unattended orchestrator by design. Implementation sessions run without permission prompts — claude with `--dangerously-skip-permissions`, codex with `--sandbox danger-full-access` — so the agent can edit files and run commands in the repository freely. Run it only in repositories you trust, ideally in a disposable branch or isolated environment (container/VM). Every phase lands as a separate commit, so `git revert`/`git reset` always gets you back. The verification session (gate 3) is read-only: claude gets only `Read,Glob,Grep`; codex runs with `--sandbox read-only` and is told to inspect only with `rg`, `sed`, `git diff`, and `git status`.
>
> `--attach` draws the panel over a run **already in progress** in the same directory, from a second terminal: it runs no phase, needs no clean tree, and is read-only over the run.

### Invariants

1. Every phase **and** every fix cycle runs in a fresh session with a self-contained prompt. Sessions are never reused.
2. Zero questions — fully autonomous execution.
3. A phase is only "complete" when it passes the **4 mechanical gates**, never by the engine's exit code.
4. API usage limit → waits for the reset and re-runs the **same** phase, without consuming a fix cycle.
5. **One commit per completed phase** (`feat(phase-N): <title>`). Before committing, ralph ticks the phase's checkboxes (`- [x]`) in the input document; the progress stamp ignores checkbox state.
6. A surgical repair or a rescue never commits and never replaces a gate.

Commits ralph can create:

| Commit | When |
|---|---|
| `feat(phase-N): <title>` | Phase passed the gates (a rescue-closed phase adds a body line saying so) |
| `test(baseline): sanea o vermelho herdado de HEAD` | HEAD healing turned an inherited red suite green |
| `wip(phase-N): incomplete — see .phases/logs/` | Phase failed with `--keep-going` |
| `wip(phase-N): interrompido por falha de ambiente — see .phases/logs/` | Run ended by a downed environment |

### The 4 gates

| Gate | Question | How it decides |
|---|---|---|
| 0 | Did the engine actually finish? | claude: `is_error` in the result JSON; codex: exit code |
| 1 | Did the session write code? | Tree signature (including `HEAD`, so a session that commits by itself counts) before/after. **A signal, not a verdict** — an already-implemented phase makes the engine (correctly) write nothing; the signal feeds the fix-cycle cause |
| 2 | Do the project's tests pass? | Run **by ralph itself**, outside the agent session — the agent cannot "fake green". The **scope varies per phase**: see below |
| 3 | Is each task actually in the code? | Independent read-only verifier session that emits `TASK <n>: DONE — <evidence>` / `TASK <n>: INCOMPLETE` per task. With `RALPH_VERIFY=auto` (default) it is **skipped** only when gate 2 really ran tests for this phase and passed, on cycle 1, after a session that wrote code; otherwise it runs. `always` runs it on every phase. On the claude engine it uses `sonnet` |

Gate 3 details: tasks are indexed **by position** (`1..N`) inside the phase; if the verifier answers with labels (`T03`) they are mapped back to positions. With `RALPH_VERIFY_EVIDENCE=required` (default), a `DONE` without `— <evidence>` (`file:line` or a `.png` path) fails the gate on protocol.

Any red gate → **fix cycle**: a fresh session receives the full phase + the real failure cause (never a generic "tests failed"). Default: 2 cycles per phase.

Green gates with a clean tree → the phase was already implemented at HEAD: marked done, no commit.

### Gate 2 scope — the full suite is the SPEC's gate, not each phase's

Running the whole suite at the end of every phase costs minutes per phase, but the worse cost is the incentive: a mechanical phase (wiring, config, rename, view) that has to "close gate 2" pushes the engine to invent a test — a getter, a cast, "the class exists" — just to have something green in its own scope. A useless test is permanent noise in the repository.

Per phase, gate 2 resolves one of three scopes, first rule that matches:

| # | Condition | Scope |
|---|---|---|
| 1 | `--full-suite` / `RALPH_TEST_SCOPE=full` | whole suite |
| 2 | **Last pending phase** of the document (the end of the spec) | whole suite |
| 3 | Gate 3 disabled (`--no-verify`): gate 2 is the only mechanical proof left | whole suite |
| 4 | The phase declares `Suite: completa` in its own text | whole suite |
| 5 | The phase's diff touches a critical path (migrations, dependency manifests, config, bootstrap, images, CI — `RALPH_CRITICAL_PATHS`) | whole suite |
| 6 | A test file was changed in the tree or named in the phase's `Testes:` field, and the runner accepts paths | only those tests |
| 7 | None of the above | not run — gate 3 alone judges the phase |

Fail-safe on every edge: a runner that does not take a path (`go`, `cargo`, an unknown command, a compound command) falls back to the whole suite, never to a scoped run. A phase may **escalate** rigor (`Suite: completa`), never lower it. And a phase whose gate 2 was skipped (rule 7) always goes through gate 3: scope shortens gate 2, never the proof that the phase was done.

The `Testes:` field is also a mandate for the executor: it must create exactly the tests listed there, no more.

`--full-suite` restores the previous behavior (whole suite on every phase).

### Surgical repair (before the cycle)

A fix cycle is expensive: a fresh session with the context preamble, the whole phase in the prompt, and full project access. Paying that because **one** assertion went red is waste. Before spending a cycle, ralph can try **surgical repairs**. **Off by default**: enable with `RALPH_REPAIR=on` plus `RALPH_MAX_REPAIRS=N` (or `--max-repairs N`). With `RALPH_REPAIR` off, `--max-repairs` alone has no effect.

- **Minimal prompt**: only the failure signature — the failing test, `file:line`, the assertion message — or only the verifier's `INCOMPLETE` lines. No preamble, no phase.
- **Its own strong model** (`RALPH_REPAIR_MODEL`, claude default `opus`): it is the only step that writes code from a minimal context, and the only one that can abort the phase on its own (`REPAIR_ABORT`). A blind patch and a wrong bail-out both cost more than the model difference.
- **Does not consume a cycle**: `--max-cycles` stays fully in reserve.

**Fail-closed.** It only repairs what it can localize. Straight to the full cycle: a red gate 0 (the engine died), test output with no localizable failure, a failure spread across more than `RALPH_REPAIR_MAX_FILES` files, more than `RALPH_REPAIR_MAX_TASKS` incomplete tasks, and a gate 3 failed on verifier **protocol** (which is not missing code). The model can also bail out on its own by answering `REPAIR_ABORT: <reason>` — bailing out cheaply beats a blind patch, and ralph escalates immediately instead of spending the next round.

**Revalidation.** Between rounds gate 3 runs **scoped**: only the tasks that were `INCOMPLETE`, at their original positions (nothing is renumbered). An `INCOMPLETE` outside the scope fails the gate — that is the repair having broken something that already stood. Scope green **does not close the phase**: the full chain (gate 2 at the phase's scope + verification of every task) runs before any commit. A repair never commits.

`--no-repair` (or `--max-repairs 0`) turns it off and restores the old behavior: red gate → cycle.

### Rescue session (before giving the phase up)

When a phase gets stuck — the repair bails out with `REPAIR_ABORT`, the repairs run out, a cycle turns unproductive, or `--max-cycles` is exhausted — ralph used to stop and hand the developer a log. But the real reason for the deadlock is almost never model horsepower: it is that **every earlier step works with narrow authority**. The cycle fixes "what is missing"; the repair only touches the file in the signature; neither may reorganize the implementation or touch an existing test that now contradicts the phase.

The rescue is the step with the authority that was missing — **1 session per phase** by default (`RALPH_MAX_RESCUES`):

- **Wide, self-contained prompt**: context preamble + the whole phase + why it got stuck + the raw verdict of the last gate + the repair's bail-out **verbatim** + the `git diff` of the partial work in the tree.
- **Its own strong model** (`RALPH_RESCUE_MODEL`, claude default `opus`).
- **May** reorganize the implementation across files and layers, and **may** adjust an existing test that contradicts the behavior the phase requires — the only case for touching a pre-existing test.
- **May not** loosen a test to go green (delete, skip, comment out, weaken an assert, change the runner or config), nor create a test the phase did not ask for. Every test change is justified in writing (`TESTE ALTERADO: ...`).
- **Consumes neither cycle nor repair**: its own budget, per phase.

**It does not replace a gate.** After the rescue the **full** chain runs — gate 2 at the phase's scope + gate 3 over every task — and only then does the phase commit, like any other. Rescue green is the same green; the commit records where it came from, because that phase deserves human review first.

**Honest bail-out.** If the blocker is a contradiction in the **spec itself** (the phase requires A, another agreed rule requires not-A), the rescue stops without editing anything and answers `RESCUE_BLOCKED: <conflict>`. No extra round is spent: that call is human. An environment that is down also does **not** trigger a rescue — a dead service is not a code defect.

`--no-rescue` (or `--max-rescues 0`) turns it off and restores the previous behavior: stuck phase → the run stops.

### HEAD healing (red inherited from HEAD)

**Opt-in** (`--heal-head` or `RALPH_HEAL_HEAD=on`; off by default, because the full suite at HEAD cost minutes before any phase moved). When on, before phase 1 ralph runs the suite **once at HEAD** (the tree is clean, guaranteed by preflight). Red there is not any phase's defect — it is red the run inherited, and it would trap the fix cycle of every phase.

- One **healing session** (`RALPH_HEAL_ROUNDS`, default 1) gets an explicit mandate to fix the inherited red — including updating an obsolete guard of another feature when the frozen text changed by a recorded decision, while preserving the rule the guard protects. It may give up with `HEAL_ABORT: <reason>`.
- Green → its own commit, `test(baseline): sanea o vermelho herdado de HEAD`, and the run proceeds on a clean HEAD.
- Still red → aborts **before phase 1**, naming the tests: a human call that costs one suite run instead of a whole phase.
- `--baseline` takes precedence and disables healing (the red is declared intentional, e.g. TDD with the test committed red). `--no-heal-head` (or `RALPH_HEAL_HEAD=off`) keeps it off.

### Visual evidence (`Tela:` field)

A task may carry, inside its checkbox block:

```
Tela: <route> | <CSS selector>[, <selector>...] | <png-target> | <theme>
```

Route and selectors are required; the PNG-target and the theme are optional. ralph itself — never the engine — takes the screenshots with `RALPH_UI_SHOT_CMD` / `--ui-shot-cmd` (empty = auto-detect `scripts/ralph-ui-shot.{mjs,js,sh,py}` in the project), called as `<cmd> <route> <out.png> [<selectors>] [<theme>]`, once per viewport (`RALPH_UI_VIEWPORT=desktop|mobile`). Captures land in `.phases/evidence/<phase>/task-<n>[-mobile].png`; the verifier reads the capture **and** the target and fails objective visual defects. The executor uses the same command to check itself in `.phases/selfcheck/` before delivering.

**Fail-closed**: a phase with `Tela:` and no capture command fails. `--no-ui-verify` (or `RALPH_UI_VERIFY=off`) turns it off on purpose.

### Usage limits

A usage limit is not a failure: ralph waits for the reset and re-runs the **same** phase without spending a cycle. While waiting, a `Retomando em …` line is logged only at milestones (4h/3h/2h/1h/30m/15m/5m/1m), not with the panel active.

**Weekly limit**: if the reset is further away than `RALPH_WEEKLY_THRESHOLD` (default 21600 s = 6 h), ralph does **not** sleep — it ends the run with exit 1, fires `limit_abort`, and prints the resume command (`./ralph.sh <file> --from N`). Detection covers the claude CLI 2.x "session limit" text and `api_error_status: 429`.

### Environment down (gate 2's own verdict)

An external service that is down — database, cache, queue, a container killed by host memory pressure — is **not a code defect**: the suite never got to judge the phase. Treating it as a red gate 2 costs a cycle, costs a surgical repair, and in the end throws the phase's work away, because no patch brings a dead container back.

When it recognizes the signature (connection refused, DNS that does not resolve, connection `SQLSTATE`), ralph:

1. **Tries to bring back what is down** — `docker start` on the containers **named in the error itself** (they may belong to another compose project) and, if the project uses Sail with its containers stopped, `sail up -d`.
2. **Re-runs the suite once** (once per phase). Back to green: the run continues normally, no cycle spent.
3. **Still down**: it ends the **whole run** — even with `--keep-going`, because the next phase would hit the same dead service —, saves the phase's work as `wip(phase-N): interrompido por falha de ambiente — see .phases/logs/` and exits with **exit code 3**.

Re-running with the environment up revalidates the phase and continues where it stopped. `--no-env-guard` (or `RALPH_ENV_GUARD=off`) turns it off — useful if your suite **asserts** connection error messages and the guard mistakes them for a downed environment.

### Test command detection (gate 2)

First rule that resolves wins: `--test-cmd` → `RALPH_TEST_CMD` → a literal `RALPH_TEST_CMD='…'` (or `"…"`) declared in the phase document itself, used verbatim → manifest detection (Laravel Sail → `composer test` → `php artisan test` → `npm test` → `pytest` → `go test ./...` → `cargo test`) → nothing resolved = gate 2 skipped with a loud warning (gate 3 holds the line alone).

Laravel Sail projects: the suite runs **inside the container** (`vendor/bin/sail test`); stopped containers abort at preflight — every gate 2 would fail and burn fix cycles for nothing.

### Options and variables

| Option | Effect |
|---|---|
| `--engine codex\|claude` | Implementation engine (default: `codex`) |
| `--model NAME` | Model for the implementation/fix sessions (default: the engine CLI's own) |
| `--from N` | Starts at phase N (clears progress for phases ≥ N) |
| `--keep-going` | Continues after a phase fails (creates a `wip(phase-N)` commit; default: stop) |
| `--max-cycles N` | Fix cycles per phase (default: 2) |
| `--max-repairs N` | Surgical repairs per cycle (default: 0; only effective with `RALPH_REPAIR=on`) |
| `--no-repair` | Disables surgical repair |
| `--max-rescues N` | Rescue sessions per phase (default: 1; `0` disables) |
| `--no-rescue` | Disables the rescue session |
| `--rescue-model NAME` | Rescue session model (claude default: `opus`) |
| `--test-cmd "<cmd>"` | Project test command (gate 2) |
| `--full-suite` | Gate 2 runs the whole suite on every phase (previous behavior) |
| `--baseline` / `--no-baseline` | Measures what is already red at HEAD and makes gate 2 charge only the **delta** (default: off; disables HEAD healing) |
| `--heal-head` / `--no-heal-head` | Enables/disables HEAD healing before phase 1 (default: off) |
| `--no-verify` | Disables gate 3 |
| `--ui-shot-cmd "<cmd>"` | Screenshot command for `Tela:` tasks |
| `--no-ui-verify` | Disables visual evidence |
| `--no-env-guard` | Disables environment-down detection: every failure is a red phase again |
| `--ui-layout <name>` | Initial screen: `cockpit` (default), `focus`, `diagnostic` |
| `--verbose` / `--quiet` | Streams engine progress to the terminal / only ralph's scoreboard (default) |
| `--ui` / `--no-ui` | Forces the ANSI panel on / off (see below) |
| `--serve[=PORT]` | Local web dashboard over the same state |
| `--attach` | Panel over a run already in progress in this directory; runs nothing |
| `-h`, `--help` | Prints the script header |

Every value option also accepts `--opt=value`. The verifier and repair models have no flag: use `RALPH_VERIFY_MODEL` / `RALPH_REPAIR_MODEL`.

| Variable | Effect |
|---|---|
| `RALPH_TEST_CMD` | Test command (gate 2) |
| `RALPH_TEST_SCOPE` | Gate 2 scope: `auto` (default) \| `full` |
| `RALPH_CRITICAL_PATHS` | ERE for critical paths: a phase whose diff matches runs the whole suite |
| `RALPH_TEST_FILE_RE` | ERE that recognizes a test file |
| `RALPH_BASELINE` | `on` enables the gate 2 baseline (same as `--baseline`; default: `off`) |
| `RALPH_VERIFY` | Gate 3: `auto` (default: only when gate 2's verdict isn't enough) \| `always` \| `off` |
| `RALPH_VERIFY_MODEL` | Verifier model (claude default: `sonnet`) |
| `RALPH_VERIFY_EVIDENCE` | `required` (default: a `DONE` without evidence fails gate 3) \| `optional` |
| `RALPH_HEAL_HEAD` | HEAD healing before phase 1: `off` (default) \| `on` |
| `RALPH_HEAL_ROUNDS` | Healing sessions before aborting (default: 1) |
| `RALPH_UI_VERIFY` | Visual evidence for `Tela:` tasks: `auto` (default) \| `off` |
| `RALPH_UI_SHOT_CMD` | Screenshot command (empty = auto-detect `scripts/ralph-ui-shot.*`) |
| `RALPH_UI_SHOT_TIMEOUT` | Capture timeout in seconds (default: 120) |
| `RALPH_MODEL` | Model for the implementation/fix sessions (empty = the CLI's own) |
| `RALPH_CAVEMAN` | Caveman plugin level for claude code-writing sessions (default: `ultra`; `off` disables; inert without the plugin) |
| `RALPH_ENV_GUARD` | Environment-down detection: `on` (default) \| `off` |
| `RALPH_ENV_RECOVER_TIMEOUT` | Seconds to wait for services when bringing them up (default: 90) |
| `RALPH_MAX_CYCLES` | Fix cycles per phase (default: 2) |
| `RALPH_REPAIR` | Surgical repair: `off` (default) \| `on` |
| `RALPH_MAX_REPAIRS` | Repairs per cycle (default: `0` = off) |
| `RALPH_REPAIR_MODEL` | Surgical repair model (claude default: `opus`) |
| `RALPH_RESCUE` | Rescue session: `on` (default) \| `off` |
| `RALPH_MAX_RESCUES` | Rescue sessions per phase (default: 1; `0` disables) |
| `RALPH_RESCUE_MODEL` | Rescue session model (claude default: `opus`) |
| `RALPH_REPAIR_MAX_FILES` | Above N files in the failure signature, go straight to the cycle (default: 5) |
| `RALPH_REPAIR_MAX_TASKS` | Above N incomplete tasks, same (default: 3) |
| `RALPH_MAX_LIMIT_WAITS` | Consecutive usage-limit waits, per phase (default: 20) |
| `RALPH_LIMIT_WAIT_DEFAULT` | Fallback wait in seconds (default: 1800) |
| `RALPH_LIMIT_BUFFER` | Extra seconds after the reset (default: 60) |
| `RALPH_WEEKLY_THRESHOLD` | Reset further away than N seconds = weekly limit, run ends (default: 21600) |
| `RALPH_NOTIFY_CMD` | Notification command (empty = disabled) |
| `RALPH_NOTIFY_TIMEOUT` | Notification command timeout in seconds (default: 20) |
| `RALPH_VERBOSE` | `1` streams engine progress (same as `--verbose`; default: 0) |
| `RALPH_HEARTBEAT` | Seconds between heartbeats in quiet mode (default: 60; `0` disables) |
| `RALPH_UI` | Panel: `auto` (default) \| `panel` \| `plain` |
| `RALPH_UI_LAYOUT` | Initial screen: `cockpit` (default), `focus`, `diagnostic` |
| `RALPH_UI_FPS` | Panel repaints per second (default: 2) |
| `RALPH_UI_KEYS` | Keyboard and mouse in the panel (needs a readable `/dev/tty`): `1` (default) \| `0` disables both |
| `RALPH_UI_GLYPHS` | Panel glyphs: `ascii` (default) \| `unicode` |
| `RALPH_SERVE_PORT` | First port `--serve` tries (default: 7433) |
| `RALPH_ATTACH_INTERVAL` | Seconds between refreshes in `--attach` (default: 3) |

During each session, ralph exports `RALPH_ENGINE`, `RALPH_PROJECT`, `RALPH_PHASE_TITLE`, `RALPH_PHASE_NUM`, `RALPH_PHASE_TOTAL`, `RALPH_PHASE_ATTEMPT`, `RALPH_PHASE_MAX_ATTEMPTS`, `RALPH_PHASE_REPAIR` (repair round; `0` = none), and `RALPH_PHASE_RESCUE` (rescue round; `0` = none). The capture command also receives `RALPH_UI_VIEWPORT`; the notification command receives `RALPH_EVENT`.

### Visual panel and web dashboard

A run is watched, not read. ralph draws a full-screen panel while the run happens:

```text
RALPH   beer-and-code                                  CODEX      ● IMPLEMENTANDO
─────────────────────────────────────────────────────────────────────────────────
TEMPO TOTAL        FASES CONCLUÍDAS       CICLO ATUAL          PROGRESSO / FASES
18m 42s            02 / 06                01 / 05              33%
▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬
✓ 01 Setup     ✓ 02 Dados     ▶ 03 API     · 04 UI     · 05 Integração     · 06 Final
  EM ANDAMENTO / FASE 03                        VALIDAÇÃO DA FASE
  API de pedidos                                G0 Sessão       aguardando
  ▶ Tarefa 3: Validar estoque                   G1 Código       alteração detectada
  2 verificadas / 1 ativa / 2 pendentes         G2 Testes       aguardando
  › Editando OrderService.php                   G3 Verificação  aguardando
ÚLTIMOS EVENTOS
14:32:08    Fase 02 concluída e commit registrado
─────────────────────────────────────────────────────────────────────────────────
 1 Visão geral      2 Foco      3 Diagnóstico                 f Seguir    q Sair
```

The mock-up above uses the Unicode glyphs (`RALPH_UI_GLYPHS=unicode`); the default is `ascii` (`>`, `*`, `#`, `.`, `+`, `-`, `^`), which renders on any terminal.

The panel runs in the terminal's **alternate screen buffer** (like `vim` or `less`): it owns the screen during the run and, on exit, gives the terminal back with the previous scrollback intact. That is what allows a layout that adapts to the terminal size.

Use **1 / 2 / 3** (or click the tab) to switch screens without interrupting execution:

| Screen | Content |
|---|---|
| **1 · Visão geral** (overview, default) | Header, four metrics, segmented progress bar, phase journey, current task and phase validation boxes, latest events |
| **2 · Foco** (focus) | Current (or clicked) phase and task with its subtitle and live action, independent confirmation count, the phase's task list, pipeline and next step |
| **3 · Diagnóstico** (diagnostics) | Failed gate banner with headline and test scope, previous attempt, current correction, timeline and test output — or a green `● Nenhum gate falhou` strip when no gate failed |

Select the initial screen with `--ui-layout cockpit|focus|diagnostic` or `RALPH_UI_LAYOUT` (`cockpit` is kept as the name of the overview). This also works with `--attach`, including runs already in progress:

```bash
./ralph.sh --attach --ui-layout diagnostic
```

The layout follows the terminal size: at 144×40 the boxes sit side by side and every region shows; between 100×24 and 144×40 the boxes stack and, when height runs out, regions drop in a fixed order — first `ÚLTIMOS EVENTOS` (overview), then `LINHA DO TEMPO` and `SAÍDA DO TESTE` (diagnostics). Below 100×24 the panel shows only the warning `aumente para 100×24`; the run keeps going. An empty field shows `—` in the same position.

`Declarada` means the engine marked a task; it is not independent verification. Inference (`~`) never overrides a verdict. Skipped gates remain distinct from passed gates, G1 is a change signal, and prior phases without published gate history do not receive invented green verdicts. Infrastructure interruptions have their own indication.

Keys and mouse work without stopping the run:

| Key / click | Action |
| --- | --- |
| `1` / `2` / `3`, click on a tab | Visão geral / Foco / Diagnóstico |
| `↑` / `↓`, `k` / `j`, mouse wheel over a list | One row up / down |
| `PgUp` / `PgDn`, space | One screen up / down |
| `g` / `Home`, `G` / `End` | First / last row |
| click on a journey phase or on a task | Opens Foco with that phase/task selected (following is suspended) |
| `a` / `f`, click on `f Seguir` | Back to automatic mode: follow the current phase and active task, dropping manual selection and scroll |
| `q`, click on `q Sair` | Closes **only the panel** (see below) |

The mouse follows the same switch as the keyboard: it is enabled only with `RALPH_UI_KEYS=1` (default) and a readable `/dev/tty`. With no TTY, with `RALPH_UI_KEYS=0`, or with an unreadable `/dev/tty`, no mouse-reporting sequence is ever emitted and the panel falls back to the previous behavior. **While mouse reporting is on, copying text from the terminal requires Shift+drag** — plain dragging is delivered to the panel as clicks.

Reading a key or a click **blocks nothing**: it replaces the wait between repaints, so the run keeps moving through the gates regardless of what is typed — the "zero questions" invariant still holds. Malformed or unknown mouse sequences are ignored.

`q` / `q Sair` in a live run closes the panel and restores the terminal (mouse off, cursor visible, main screen, `stty` as before). **The run keeps going** in the line-by-line scoreboard until the end, with the same exit code, verdicts and commits as a run where nobody pressed `q`. Reopen the panel from any terminal with `./ralph.sh --attach`. In `--attach` and in `ralph-watch.sh`, `q` leaves the viewer without touching the run.

`./ralph-watch.sh [repo]` delegates to `ralph.sh`: live mode becomes `ralph.sh --attach` (same screens, keys, mouse and `q`), and `--once` draws a single frame with the same renderer as the run, writing nothing to `.phases/`.

An engine session runs for minutes and the CLI may emit nothing readable in that time. The live `›` line of the EM ANDAMENTO box (plus the stage line) answers one question: *is it stuck or working?* Everything in it is measured **by the process painting the screen**, not published by the orchestrator — during `run_split` the main process is blocked waiting on the engine and could not republish anything:

| Signal | Source | Why it moves on its own |
|---|---|---|
| Stage + its own elapsed | `stage_start`, rewritten on every stage change | separates "3m in this phase" from "3m in this gate" |
| Engine output + rate | `wc -c` on both session logs, delta between frames | a live engine writes; a stuck one does not |
| Files touched | `git status --porcelain`, recomputed every ~3s | shows the work landing in the tree |
| Last progress line | `tail` of the `.stderr.log`, read every frame | when the CLI streams, this is what it is doing |

The line shows the engine's last action, read live from the stream (`claude -p --output-format stream-json`): the tool and its target, e.g. `Edit app/Models/RemittanceBatch.php`. While the engine has not used a tool yet, the line says how long it has been on that step. The action counter and the touched-file count are the proof of life.

### Which task is being worked on

The engine runs in an **opaque** session: no event says which task it is on. What does exist is (a) the task text, which names code identifiers, and (b) the working tree changing. The panel matches one against the other.

From each task ralph extracts **anchors** — backticked content, `CamelCase`, `snake_case`, paths and file names, discarding anything that does not look like an identifier. Every ~3s it checks which anchors already appear in some repository path (tracked or freshly created):

- **`▶ ~67%`** — active task: one of its anchors matches the **most recently modified** file
- **`◐ ~100%`** — the task's artifacts already showed up, but another one is being touched right now
- **`· Pendente`** — no anchor matched, or the task names no identifier at all

The **`~` is deliberate**: it is a guess grounded in a real file, not a verdict. A file existing does not prove a correct implementation — gate 3 still judges the task, and its verdict (`✓ Concluída` / `! Incompleta`) **always** replaces the inference once it arrives. A task whose text cites no identifier produces no guess at all, rather than an invented one.


Status marks: `✓ Concluída`, `✓ Declarada` (the engine ticked the checkbox; no gate 3 verdict yet), `▶ Em execução`, `! Incompleta`, `✗ Falhou`, `» Pulada`, `· Pendente`. Gate marks: `·` not run, `⣾` running (spinner), `✓` green, `✗` red, `⊘` skipped. While waiting on a usage limit, the header status becomes a countdown to the reset.

`RALPH_UI=auto` (the default) draws the panel **only** when stdout is a TTY. Under `nohup`, in CI, or through a pipe the output is the line-by-line scoreboard, byte for byte identical to a ralph without the panel — that compatibility is asserted by the suite. `--verbose` always wins: the two engine streams need the terminal. With the panel active the scoreboard is diverted to `.phases/ui/messages.log`, shows in the footer, and is **reprinted in full on the normal screen** when the panel exits — otherwise it would live only in the file. Long output (a red gate's cause, the final report) always comes after the panel is torn down. **A failure to draw degrades to the scoreboard: the panel never changes a gate verdict or the exit code.**

`--serve` additionally writes a self-contained `.phases/ui/index.html` (no CDN, no remote font, no external fetch — DejaVu Sans Mono is embedded in the page) and starts `python3 -m http.server` bound to `127.0.0.1`, on the first free port from 7433. The page is rewritten at the start of every run, so an old dashboard is never served. The URL is printed once at the top; the browser is **not** opened. The page shows the same three tabs as the terminal (1 Visão geral, 2 Foco, 3 Diagnóstico) with the same values, read only from `../state.json` and `../events.jsonl` every 1.5 s; tabs, `f Seguir`, phases and tasks are clickable and switch immediately, and there is no `Sair` in the browser. The exit trap kills the server; the state stays on disk for later inspection. No `python3` in `PATH` → loud warning and the run proceeds with the panel only.

### Structured state

The panel, the dashboard, and any external tool read the same two files. None of them parses the human scoreboard — that is the point.

| File | Shape | Role |
|---|---|---|
| `.phases/state.json` | JSON snapshot | The now: current phase, cycle, each gate's verdict, phase list with status, usage-limit wait, last engine progress line |
| `.phases/events.jsonl` | append-only JSON Lines | The history: one line per transition |

`state.json` is rewritten atomically (`tmp` + `mv`), so a concurrent reader sees the old version or the new one, never half a file. `events.jsonl` carries `phase_start`, `gate_start` / `gate_end` — with verdict and duration — for all 4 gates on every phase, `repair_start` / `repair_end`, `rescue_start` / `rescue_end`, plus the same 7 events the notification hook receives, under the same names. Per-gate timing exists nowhere else in the harness.

### Progress notifications

A long run does not need an open terminal. With `RALPH_NOTIFY_CMD` set, ralph calls `$RALPH_NOTIFY_CMD <event> <message>` on every relevant event:

| Event | When |
|---|---|
| `run_start` | Run started — pending phase count, engine, and input file |
| `phase_done` | Phase passed the gates (committed, or already implemented at HEAD) |
| `phase_failed` | Phase rejected after `RALPH_MAX_CYCLES`, or the commit failed |
| `limit_hit` | Usage limit reached — includes the predicted reset time |
| `limit_over` | Limit lifted, resuming the same phase |
| `limit_abort` | Aborted after `RALPH_MAX_LIMIT_WAITS` waits on the same phase, or weekly limit hit |
| `run_done` | Final report: completed, failed, skipped, and total duration |

The command runs under `timeout` with stdin closed and every error is swallowed — **notifying never changes the run's outcome**. `RALPH_PROJECT` reaches the command's environment, which tells parallel runs of different projects apart.

Ready-made Telegram adapter at `scripts/notify-telegram.sh` (credentials via env or `~/.config/ralph-notify/telegram.env` only, never in the script):

```bash
export RALPH_NOTIFY_CMD="$HOME/.claude/scripts/notify-telegram.sh"
./ralph.sh .spec/features/<slug>/PHASES.md
```

Telegram messages identify the outcome in the title: start, completed phase, failure, usage-limit wait, or infrastructure interruption. Phase events include the cycle, G2/G3 results, and test scope; failures include the log path. The final run message uses the actual outcome without inheriting the previous phase. Long messages are truncated before HTML escaping to preserve delivery and context.

The hook additionally receives `RALPH_OUTCOME`, `RALPH_RUN_ID`, `RALPH_GATE2`, `RALPH_GATE3`, `RALPH_TEST_SCOPE`, and `RALPH_LOG_PATH`. The seven event names and positional arguments remain unchanged. `phase_failed` can also indicate infrastructure: `RALPH_OUTCOME=environment` distinguishes that outcome. Adapter tests use a fake `curl` and send no real messages.

### State and progress

Internal work lives in `.phases/` (registered in `.git/info/exclude`, without touching the project's `.gitignore`): split phases, prompts, logs, manifest, `.progress`, the structured state (`state.json`, `events.jsonl`), the panel/dashboard assets (`ui/`) and the screenshots (`evidence/`, `selfcheck/`). Progress survives across runs, but only for the **same input** (sha256 stamp) — a changed phase document resets progress.

Every engine session writes **two** logs, never merged:

| File | Stream | Role |
|---|---|---|
| `.phases/logs/<phase>.<step>.log` | stdout | Engine's final response — the **only** source gates read a verdict from |
| `.phases/logs/<phase>.<step>.stderr.log` | stderr | Progress/telemetry — diagnostics only |

Both go whole to the logs; `--verbose` also streams them live. Merging them (`2>&1`) made Codex echo the final response into both streams, so gate 3 counted every task twice and failed a fully implemented phase for "incomplete coverage". Gate 3 therefore measures coverage in **unique task indices**: a duplicated echo neither inflates nor hides coverage, `INCOMPLETE` beats `DONE` on the same index, and an index outside `1..N` or a task with no verdict keeps the gate red.

Exit code: `0` = all phases green (also `--attach`); `1` = some phase failed or aborted, including the usage-limit cap and the weekly limit; `3` = run ended by a downed environment (no verdict on the code — bring the services up and re-run); `130` = interrupted by the operator (INT/TERM).

### Input format contract

Validated at preflight:

- ≥ 1 heading `## Phase N: <title>` (only this English form — `## Fase N` is not a phase)
- No `## Phase ...` heading outside that format (a malformed heading silently disappears from the run — preflight aborts before burning tokens)
- Sub-phases as `### Phase N.M:` (do not become their own session)
- Any other `## ` heading ends the previous phase's capture
- Tasks are `- [ ]` / `- [x]` lines; indented lines below a task belong to its block (`Testes:`, `Tela:`, …). A leading `T<n> —` label is stripped; gate 3 counts by position
- Optional per-phase line `Suite: completa` (forces the whole suite in gate 2)

## Agents

Commands are **thin routers** — all template knowledge lives in the agents:

| Agent | Pipeline | Role |
|---|---|---|
| `specifier` | `/plan` §5 | Confirmed description + ACs → formal SPEC.md (GEARS, RIGID/FLEXIBLE) |
| `clarifier` | `/plan` §6 | Adversarial requirements QA: finds ambiguities, resolves them with the developer's answers |
| `planner` | `/plan` §7, `/bugfix` §7b | SPEC (or BUGFIX) → PLAN.md + PHASES.md + contracts; read-only over the code |
| `bug-analyst` | `/bugfix` §4 and §7b | `investigate`: reproduce, trace the root cause, classify the tier. `author`: write BUGFIX.md. Never writes application code |
| `ai-context-inspector` | `/ai-context` §3 | Read-only repo sweep → structured digest |
| `ai-context-core` | `/ai-context` §4 | Digest → `AGENTS.md` + `CLAUDE.md` |
| `ai-context-docs` | `/ai-context` §4 | Digest → the 8 `docs/agents/*.md` files |

The two `/ai-context` writers run in parallel (disjoint files, read-only digest).

## Repository structure

```
.claude-plugin/
  plugin.json                  plugin manifest (v0.5.0)
  marketplace.json             marketplace descriptor
hooks/hooks.json               PreToolUse(Bash) hook → scripts/sail-guard.sh
commands/
  init.md                      /init (diagnostic router)
  init/                        /init:project-description, user-stories,
                               database-schema, project-phases
  plan.md                      /plan (planning pipeline router)
  bugfix.md                    /bugfix (defect pipeline router)
  ai-context.md                /ai-context (context tree router)
agents/                        specifier, clarifier, planner, bug-analyst,
                               ai-context-{inspector,core,docs}
scripts/
  ralph.sh                     phase-by-phase execution orchestrator
  test-ralph.sh                red/green suite for ralph with a mock engine
  notify-telegram.sh           RALPH_NOTIFY_CMD adapter for Telegram
  sail-guard.sh                hook: blocks host php/artisan/composer/… in
                               Sail projects and suggests ./vendor/bin/sail
  check-init-drift.sh          guards against textual drift of the rules
                               duplicated across the init commands
  check-shell.sh               bash -n + shellcheck over scripts/*.sh
docs/agents/                   context tree generated by /ai-context
AGENTS.md, CLAUDE.md           generated by /ai-context (do not hand-edit)
README.md, README.pt-BR.md     this document (EN / PT-BR)
```

### Sail guard hook

The plugin registers a `PreToolUse` hook on `Bash`. In a project with `vendor/bin/sail`, it blocks host `php`, `artisan`, `composer`, `vendor/bin/*`, `mysql`, `mariadb`, `psql`, and `redis-cli` commands (exit 2) and prints the `./vendor/bin/sail …` equivalent on stderr. Without `jq` or `python3` to parse the hook input, it lets everything through (fail-open).

## Development

```bash
scripts/test-ralph.sh        # ralph.sh suite — fake `claude`/`codex` binaries
                             # on PATH, zero network, zero tokens; exit 0 = green
scripts/test-ralph.sh <case> # run a single case
scripts/check-shell.sh       # bash -n over all scripts + shellcheck when available
scripts/check-init-drift.sh  # verbatim anchors for the shared init:* rules
```

About `check-init-drift.sh`: the four `commands/init/*.md` files **intentionally inline** the same interview, language, re-run, and staleness rules — plugin commands must be self-contained at runtime (they execute inside the developer's project, where the plugin root is not reachable via `@`-includes). The cost of that duplication is silent drift; the script makes drift loud.

## Design principles

- **Thin routers, agents own the content** — commands orchestrate, verify artifacts on disk, and report; they never author SPEC/PLAN/docs.
- **Trust, but verify** — every artifact delivered by an agent is mechanically validated (existence, headings, counts) by the router.
- **Reality ≠ intent** — `/ai-context` documents only what is implemented; `.spec/` is invisible to it. The `.spec/` chain documents intent.
- **No git writes from commands** — the developer reviews with `git diff` and commits manually. The only thing that commits is `ralph.sh`, by design (one commit per validated phase).
- **No secrets** — `.env` is never read; env var names come from `.env.example` only.
- **Explicit, never blocking staleness** — sha256 stamps detect outdated inputs; the decision always belongs to the developer.

## License

[MIT](LICENSE)
