---
name: orchestrator-mode
description: Use when activated as development orchestrator to manage full feature delivery — covers phase workflow, subagent dispatch, file ownership rules, and report conventions
---

# Orchestrator Mode

Coordinate the full development workflow by dispatching fresh specialist subagents for each phase.
Keep your own context minimal — never read file contents yourself, delegate all work.

## Critical Rules

### No File Conflicts Between Subagents
Multiple subagents MUST NOT work on the same file simultaneously.
Plan tasks so each file is owned by at most one active subagent at a time.
If tasks share files, run them sequentially — never in parallel.

### Report Files Are Temporary
Before dispatching any agent: `echo "reports/" >> .git/info/exclude`
Report files MUST NEVER be staged or committed. Remind every subagent of this rule.

## Workflow Phases

### Phase 0: Project Verification
Dispatch subagent with **common-automation-verifier** skill.
Note critical gaps before planning (missing AGENTS.md, zero test coverage, no env template).

### Phase 1: Planning
Dispatch **task-planner** subagent using **writing-plans** skill.
- Plan → `docs/plans/YYYY-MM-DD-<feature>.md`
- Context doc → `docs/plans/YYYY-MM-DD-<feature>-context.md`
- **Gate**: Human reviews plan before proceeding.

### Phase 2: Implementation
Dispatch **code-writer** subagent using **implementing-tasks** skill.
- For large features (>5 tasks): set up worktree first (**using-git-worktrees** skill)
- One subagent per task; dispatch sequentially unless tasks are file-conflict-free

### Phase 3: Testing
1. Dispatch **testing-planner** subagent using **planning-tests** skill → produces test plan
2. Dispatch **automation-tester** subagent using **writing-automated-tests** skill → executes test plan
- Gate: All runnable tests must pass before proceeding

### Phase 4: Code Review
Dispatch **code-reviewer** subagent using **requesting-code-review** skill.
If issues found: dispatch code-writer to fix, then re-review.

### Phase 5: Documentation
Dispatch **documentation-updater** subagent using **updating-documentation** skill.

### Phase 6: Finalization
Dispatch **task-finisher** subagent using **finishing-a-development-branch** skill.

## Agent Dispatch

Use the Task tool with the appropriate subagent_type:
- Exploration/research: `subagent_type="Explore"`
- Implementation/coding: `subagent_type="general-purpose"`
- Planning: `subagent_type="Plan"`

Call agents directly (already inside sandbox) — `claude` not `claude_wrapper.bash`.

## Context Management
- Pass only file paths and brief descriptions between phases
- Plan file + context doc are the shared artifacts for all phases
- Each subagent prompt must include: plan file path, their skill name, the report rule

## Your Report

Write `reports/orchestrator-<feature>-YYYY-MM-DD.md` — orchestration decisions only, not code changes.

Covers:
- How tasks were divided between subagents and why
- Which skill was active per phase
- Gates hit (human review, test failures) and outcomes
- What slowed orchestration; what would be faster next time

**IMPORTANT:** Add `reports/` to `.git/info/exclude`. Never stage or commit report files.
