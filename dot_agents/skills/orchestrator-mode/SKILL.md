---
name: orchestrator-mode
description: Use when a task warrants delegation — investigation across multiple sources, planning, or multi-step implementation. Main thread stays clean; subagents do the work; deliverable is chat text unless the user asks for a file.
---

# Orchestrator Mode

Delegate. The main thread's context is precious — reserve it for reading
subagent reports and making decisions. Any investigation that would take
more than a couple of file reads or a grep across a repo belongs in a
subagent.

## Mission types

Route by the user's verb:

- **investigate / diagnose / trace / audit / "why", "look into"** —
  Investigation mission.
- **plan / design / propose / estimate / retro / retrospective** —
  Planning mission.
- **implement / build / fix / add / refactor** — Implementation mission.

If the verb is ambiguous, ask before dispatching.

## Kernel (same for every mission)

1. Decompose the mission into independent work units.
2. Dispatch one subagent per unit. Bundle everything into one prompt.
3. Read the report. Inline file reads only for lines the report cited.
4. Loop only when a new question emerged — don't preemptively re-dispatch.
5. Deliver the result **in-session** as chat text. Not files.

## Delegation discipline (critical rules)

### Main thread reads reports, not files

Any investigation that would require more than 2 file reads or a grep
across a repo MUST be delegated to a subagent — `Explore` for read-only
research, `general-purpose` for multi-step tasks with writes, `Plan` for
architecture-design work.

Direct `Read` / `Bash grep` / `rg` from the main thread is reserved for:

- Files and lines a subagent report already cited (verification reads).
- Single-shot commands (`glab mr diff`, `git branch`, `git status`)
  whose output is itself the artefact.
- Skill files under `~/.claude/skills/` when editing them.

If you catch yourself opening a third file inline to answer a question,
stop and dispatch a subagent. Same for a second round of `rg`.

Bundle everything you need from one investigation into a single subagent
prompt — chained "one more question" dispatches double context cost.

### No file conflicts between parallel subagents

Multiple subagents MUST NOT work on the same file simultaneously. Plan
tasks so each file is owned by at most one active subagent. If tasks
share files, run them sequentially — never in parallel.

## Deliverable contract

The mission's output goes in the assistant's chat turn:

- **Investigation** → findings under section headers with source
  citations (log query, dashboard URL, MR number, file:line).
- **Planning** → the plan text, formatted for the user to read or paste.
- **Implementation** → the code diff (git SHA / PR link).
- **Retro** → the retro output.

**No plan or report files.** Exceptions:

- The user explicitly asks for a file.
- The mission's own diff includes real repo artefacts (docs page,
  config, test file) — that's normal implementation output, not
  orchestrator bookkeeping.
- A downstream deliverable needs Jira-paste formatting (as
  `plan-manual-tests` does for `customfield_10385`) — still chat, user
  copies from there.

Do not write `reports/orchestrator-*.md`, `docs/plans/*.md`, or similar
scratch files.

## Investigation mission

Dispatch one investigator per source. Common sources:

- Log search — `Explore` with the specific query and time window.
- Metrics / dashboards — `Explore` with the dashboard URL / metric
  names.
- MR diffs — `Explore` with the `glab mr diff` command.
- Jira / Confluence — `Explore` with the issue key or page URL.
- Git history — `Explore` with the branch, path, and
  `git log --grep`.

Read each report. Cross-reference. If a new question emerges from the
reports, dispatch one more investigator. Otherwise synthesise in the
chat turn and stop.

## Planning mission

Route to the matching planning skill:

- Manual test planning for a Jira Story → `plan-manual-tests`.
- Integration-test automation planning → `plan-automation-tests`.
- Session retrospective → `session-retro`.
- Anything else → produce the plan inline.

The planning skill runs under the same kernel. Its investigations still
go through subagents; its deliverable is still chat text.

## Implementation mission

Decompose into tasks. Dispatch one implementer subagent
(`general-purpose`) per task. Sequence tasks that touch the same file.

Worktrees are the user's responsibility — do not create or tear down.

Testing, review, documentation: **use whatever the repo's own skills
define**. Do not hardcode a chain here. If the repo has no test skill
and the change needs tests, say so and stop.

If a diff review is warranted, `caveman-review` and `ponytail-review`
(both plugin-provided) are the current review tools — invoke them like
any other skill. Advisory, not mandatory.

## Agent dispatch reference

- `Explore` — read-only research, single or multi-file.
- `general-purpose` — multi-step tasks that write files.
- `Plan` — architecture / design proposals.

Well-scoped `Explore` prompts eliminate a second round trip: include
the question, the paths already known relevant, the specific greps /
commands to run, and the shape of the report expected.

Call agents directly — you are already inside the sandbox.
