---
name: implementing-tasks
description: Use when implementing plan tasks one at a time — covers file ownership, TDD, commit convention, self-review, and reporting
---

# Implementing Tasks

Execute tasks from an implementation plan, one task at a time, following TDD and coding standards.

**Announce at start:** "I'm using the implementing-tasks skill."

## Per-Task Process

1. Read the task description (provided in full by the orchestrator — do not read the plan file yourself)
2. Identify the files this task owns
3. Write the failing test(s) first
4. Implement until tests pass
5. Self-review against coding standards
6. Commit with the task commit convention
7. Write report

## File Ownership Rule

**Only modify files listed in the task's "Files owned" section.**

If you discover you need to change a file owned by another task:
- Stop immediately and report to the orchestrator
- Do NOT modify files outside your task's scope
- This prevents merge conflicts with parallel subagents

## TDD — Non-Negotiable

Write the failing test before writing any production code.
Run it to confirm it fails (for the right reason), then implement.

## Coding Standards

- Max 3 levels of nesting — use guard clauses / early returns
- No magic numbers — use named constants
- All variables and functions descriptively named
- No race conditions — use mutexes, atomics, or channels
- Error paths handled and propagated, never silently swallowed
- All bash variables quoted
- No secrets or credentials in code

## Commit Convention

```
[task-N] Short description (≤50 chars)

Optional explanation of what and why.
```

## Self-Review Before Handoff

Before marking a task done, check:
- [ ] Tests pass
- [ ] Coding standards met (nesting, naming, no magic numbers)
- [ ] No files modified outside task scope
- [ ] Commit message follows convention
- [ ] No secrets in committed code

## Report

Write `reports/code-writer-task-<N>-YYYY-MM-DD.md` with:
- What was implemented
- Test results (pass count, coverage delta)
- Files modified
- Any deviations from the plan and reason
- Open questions for the reviewer

**IMPORTANT:** Add `reports/` to `.git/info/exclude`. Never stage or commit report files.

## Integration

**Called by:**
- **orchestrator-mode** — Phase 2 dispatches this role per task
- **subagent-driven-development** — dispatches this role per task with review between tasks

**Uses:**
- **coding-standards** — apply throughout all code written
- **requesting-code-review** — reviewer subagent dispatched after each task
