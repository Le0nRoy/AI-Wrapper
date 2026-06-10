---
name: planning-tests
description: Use before writing tests — designs the automated test strategy (unit + integration) and produces a test plan for the automation-tester to execute
---

# Planning Tests

Design the automated test strategy for implemented features before any tests are written.
Produce a test plan that the **writing-automated-tests** skill will execute.

**Announce at start:** "I'm using the planning-tests skill."

## When to Use

Dispatch this skill after Phase 2 (implementation) and before Phase 3 (test writing).
The testing-planner reads the implementation plan and context doc to understand what needs testing.

## Output

Write `docs/plans/YYYY-MM-DD-<feature>-test-plan.md`:

```markdown
# Test Plan: <Feature Name>

## Coverage Summary
- Unit tests needed: N
- Integration tests needed: N
- Files to test: path/to/file, ...

## Unit Tests

### Module: <name>
| Test name | What it verifies | Setup needed |
|-----------|-----------------|--------------|
| test_create_valid | Happy path | None |
| test_create_duplicate | Uniqueness constraint | Pre-existing entity |

## Integration Tests

### Scenario: <name>
- Infrastructure needed: postgres, redis, ...
- Positive control: case that MUST produce the expected result
- Negative control: case that MUST NOT produce the result
- Cleanup strategy: UUID-based data, explicit delete in finally

## Test Infrastructure

- New fixtures needed: ...
- New helpers needed: ...
- Environment variables for testing: ...

## Exclusions
Tests that cannot run in CI and why:
- TestDowntime_RedisRestart — requires Docker socket, excluded from CI

## File Ownership
| Test file | Owned by task | Depends on implementation in |
|-----------|--------------|------------------------------|
| tests/test_feature.py | Testing task 1 | Task 2 implementation |
```

## File Ownership Rule

Each test file must be owned by exactly one testing task.
No two **writing-automated-tests** subagents may write to the same test file simultaneously.
If multiple test tasks touch the same test file, sequence them with an explicit dependency.

## Coverage Gaps

Before designing new tests, run **common-automation-verifier** to identify existing coverage gaps.
Document gaps so the automation-tester knows what baseline already exists.

## Report

Write `reports/testing-planner-<feature>-YYYY-MM-DD.md` with:
- Coverage gaps found in existing tests
- New test infrastructure required
- Risks: anything that might block testing (missing Docker, env vars, etc.)

**IMPORTANT:** Add `reports/` to `.git/info/exclude`. Never stage or commit report files.

## Integration

**Called by:**
- **orchestrator-mode** — Phase 3 dispatches this role before writing-automated-tests

**Hands off to:**
- **writing-automated-tests** — receives the test plan file path
