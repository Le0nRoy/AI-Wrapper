---
name: updating-documentation
description: Use after implementation is reviewed and approved — updates README, env var docs, API docs, changelog, and context doc; never modifies source or test files
---

# Updating Documentation

Ensure all documentation is accurate and complete after implementation passes code review.

**Announce at start:** "I'm using the updating-documentation skill."

## When to Use

Dispatch after Phase 4 (code review) is approved. Never modify documentation speculatively
before review is complete — the implementation may still change.

## What to Update

### Always Check

- [ ] `README.md` — Setup, usage, or configuration changed?
- [ ] Env var documentation (`.env.example` or inline) — New or changed env vars?
- [ ] Context doc (`docs/plans/YYYY-MM-DD-<feature>-context.md`) — Still accurate after implementation?
- [ ] `CHANGELOG.md` (if exists) — Add user-facing change entry

### When API Changed

- [ ] OpenAPI/Swagger spec updated
- [ ] `docs/API.md` updated (if used instead of OpenAPI)
- [ ] Breaking changes documented with migration path
- [ ] Example requests/responses updated

### When Tests Added

- [ ] `docs/INTEGRATION_TESTING.md` (if exists) — Coverage table updated, gaps removed

## Env Var Documentation Format

Every env var must be documented as:
```bash
# Purpose of this variable (one sentence)
# Type: string | int | bool | URL | path
# Default: value (or REQUIRED)
# Example: VARIABLE_NAME=example_value
export VARIABLE_NAME="${VARIABLE_NAME:-default}"
```

## File Ownership Rule

Documentation-updater owns only documentation files:
- `README.md`, `CHANGELOG.md`, `docs/`
- `.env.example`, env documentation files

**Never modify source code or test files.**
If documentation gaps require source changes (e.g., missing docstrings), report them
to the orchestrator as required items for the code-writer.

## Report

Write `reports/documentation-updater-<feature>-YYYY-MM-DD.md` with:
- Files updated and what changed
- Documentation gaps that could not be addressed (requiring human input)
- Env vars found in code that are not yet documented

**IMPORTANT:** Add `reports/` to `.git/info/exclude`. Never stage or commit report files.

## Integration

**Called by:**
- **orchestrator-mode** — Phase 5 dispatches this role after code review is approved
