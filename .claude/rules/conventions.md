# Conventions — beer-and-code-harness

Loaded when touching: always (cross-cutting, no paths)

## Conventions
- Never trigger Telegram notifications while working in this repo: `RALPH_NOTIFY_CMD` is exported in `~/.bashrc` and inherited by the Bash tool, so prefix every ralph / `scripts/test-ralph.sh` invocation with `RALPH_NOTIFY_CMD=` (or `env -u RALPH_NOTIFY_CMD`). `test-ralph.sh` clears `RALPH_*`, but do not rely on it for direct runs. Ralph runs on client projects keep notify on.
- A small `scripts/ralph.sh` tweak made as a side step of a project request does NOT justify the full `scripts/test-ralph.sh` suite (~770 asserts, slow): at most `bash -n` and, if really needed, one case (`test-ralph.sh <case>`); then go back to the user's project task.

<!-- source notes (auto-memory migration 2026-10-23): no-telegram-notifications.md, bc-sem-telegram.md, nao-testar-ralph-em-ajuste-pequeno.md -->

