---
paths:
  - "scripts/ralph.sh"
  - "scripts/test-ralph.sh"
---
# ralph.sh runner design invariants — beer-and-code-harness

Loaded when touching: `scripts/ralph.sh`, `scripts/test-ralph.sh`

## Conventions
- Repair stage (since 2026-09-01) runs between a red gate and the correction cycle: minimal prompt (only the failure signature — test, `file:line`, assertion — or only the verifier `INCOMPLETE` lines), own cheap model `RALPH_REPAIR_MODEL` (default sonnet), up to 2 rounds per cycle, does not consume `MAX_CYCLES`.
- User-fixed design (do not re-derive): repair is an EXTRA attempt, never a substitute for full cycles; scope is only the error; scoped revalidation between rounds, but the FULL chain (whole suite + gate 3 of all tasks) before any commit; repair never commits.
- Fail-closed: gate 0, unparseable cause, wide failure (>5 files), >3 incomplete tasks and gate 3 broken by verifier protocol go straight to the cycle; `REPAIR_ABORT:` from the model escalates immediately.

## Bugs

| Bug | Root cause | Prevention |
|---|---|---|
| Scoped repair verification produced false reds | Every out-of-scope verifier verdict was rejected, including `DONE` lines | Out-of-scope `DONE` is noise and must be discarded; only out-of-scope `INCOMPLETE` fails (regression caused by the repair) |

<!-- source notes (auto-memory migration 2026-10-23): ralph-repair-stage.md -->

