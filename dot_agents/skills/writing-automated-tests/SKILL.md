---
name: writing-automated-tests
description: Use after planning-tests has produced a test plan — writes and runs automated tests following AAA structure, isolation rules, and control case requirements
---

# Writing Automated Tests

Write and run automated tests according to the test plan produced by **planning-tests**.

**Announce at start:** "I'm using the writing-automated-tests skill."

## When to Use

Dispatch after **planning-tests** has written the test plan to `docs/plans/YYYY-MM-DD-<feature>-test-plan.md`.
Read the test plan to understand what to write, which files to own, and what infrastructure exists.

## Test Writing Rules

### Structure: Always Arrange / Act / Assert

Every test follows this structure — no exceptions:
```
# Arrange — set up data, mocks, preconditions
# Act     — call the function under test
# Assert  — verify output AND side effects
# Cleanup — delete created data (integration tests)
```

### Isolation

- Each test creates its own data using UUID-based unique identifiers
- Each test cleans up in `finally`/`defer` — even on failure
- No test relies on data created by another test
- No global mutable state between tests

### Both Control Cases Required for Integration Tests

Every integration test scenario must include:
- A case that **MUST** produce the expected result (positive control)
- A case that **MUST NOT** produce the result (negative control)

Missing either case is a test coverage gap, not a complete test.

### No Unconditional Sleep

Use condition-based waiting or environment variables to control timing:
```bash
SERVICE_BATCH_THRESHOLD=1 pytest tests/integration/  # trigger immediate processing
```
Never use `time.sleep(N)` or `sleep N` without a timeout and a condition check.

## File Ownership Rule

**Only write to test files assigned to your task in the test plan.**
Do NOT modify production code — report any needed production changes to the orchestrator.

## When Tests Cannot Run (Sandbox Gaps)

If the sandbox blocks tests (no Docker, no DB, missing services):

1. Write the test code anyway — it should be correct and ready to run
2. Document exactly which tests could not run and why
3. Create `docs/sandbox-improvements/<feature>.md`:
   ```markdown
   # Sandbox Improvements Needed: <Feature>
   ## Blocked Tests
   - TestIntegration_FullFlow: needs PostgreSQL (unavailable in sandbox)
   ## Required Changes
   - Add PostgreSQL to sandbox Docker Compose
   - Expose port 5432 in test environment
   ```
4. Report to orchestrator: "N tests written, M could not run due to [reason]"

## Report

Write `reports/automation-tester-<feature>-YYYY-MM-DD.md` with:
- Tests written: count and list
- Tests run: pass/fail counts
- Coverage delta (before → after)
- Tests blocked from running and reasons
- Any production code issues found while testing

**IMPORTANT:** Add `reports/` to `.git/info/exclude`. Never stage or commit report files.

## Integration

**Called by:**
- **orchestrator-mode** — Phase 3 dispatches this role after planning-tests

**Reads:**
- Test plan from `docs/plans/YYYY-MM-DD-<feature>-test-plan.md`

**Uses:**
- **coding-standards** — test code held to the same standards as production code
