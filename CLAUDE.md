# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

A dependency-free **Mix project** (Elixir 1.18+, stdlib only — the built-in `JSON` module avoids a
`Jason` dependency). Source in `lib/`, ExUnit suites in `test/`, runnable explainers at the root.

```bash
mix test                          # run all suites (72 tests)
mix test --cover                  # with built-in line coverage
mix format                        # format (also enforced by a hook)
mix run golden_record_ddd.exs     # a demo (compiles lib/ first); also _api/_stress
elixir golden_record.exs          # the one standalone explainer (defines its own modules)
```

CI runs `mix test` inside the official `elixir` Docker image, matrixed over 1.18 and 1.19
(`.github/workflows/ci.yml`).

## Architecture Overview

- `lib/golden_record_core.ex` — the engine: flat modules (`Codes`, `Substrate`, `Cluster`,
  `IdentityLedger`, `Stewardship`, `Catalog`, `History`, `Api`, `PublicId`, …), pure functions,
  event-sourced. Loaded by Mix; cross-referenced by the ingest.
- `lib/ingest/` — the legacy-medipim ingest pipeline: `envelope_loader.ex` (gr-n8i: parse/validate
  the contract-C `HistoryEnvelope`, spec in `docs/HISTORY_ENVELOPE.md`) → `claim_mapping.ex`
  (gr-beo: fold listings → canonicalize/partition → engine claims) → (next) cluster + reconcile.
- `test/ingest/fixtures/` — real data, incl. the full delta history of medipim entity `422156`,
  plus `gen_422156.exs` which regenerates the decoded envelope from the raw dump.

## Conventions & Patterns

- **No external dependencies.** Reach for the stdlib first (e.g. the built-in `JSON`); adding a Hex
  dep is a deliberate decision, not a default.
- **Flat module names** for now (no `GoldenRecord.*` namespace) — a known future follow-up.
- **Pure functions, no GenServers** — there is no runtime state to manage; the event log is the
  system of record and every projection is a fold over it.
