# Claude Wrapper Help

This wrapper provides an interactive menu for starting Claude CLI sessions with
optional orchestration workflows. It also supports multiple Claude accounts
(e.g. personal and corporate) with automatic profile selection.

## Account Selection

On each interactive launch, the wrapper checks for account profile directories
at `~/.claude-<name>/`. If two or more exist, an account picker is shown before
the session menu. The chosen account's credentials are bound into the sandbox;
the session menu header reflects the active account (e.g. `Claude CLI [private]`).

### Setting up profiles

```bash
# Copy your current ~/.claude into named profiles
cp -a ~/.claude ~/.claude-private
cp -a ~/.claude ~/.claude-corporate   # then log in to the corporate account

# Optional: separate settings files per profile
cp ~/.claude.json ~/.claude-private.json
cp ~/.claude.json ~/.claude-corporate.json
```

Inside the corporate profile, run `claude auth login` (or set the API key) to
authenticate that account. The two profiles are fully isolated — each session
only sees its own credentials.

### Non-interactive / scripted use

Set the `CLAUDE_ACCOUNT` environment variable to skip the menu.
`CLAUDE_ACCOUNT` takes priority in **all** modes — interactive and non-interactive alike:

```bash
CLAUDE_ACCOUNT=corporate claude_wrapper.bash --some-flag   # scripted
CLAUDE_ACCOUNT=corporate claude_wrapper.bash               # interactive, skips picker
```

Non-interactive invocations (with arguments, or with stdin/stdout redirected) that do
**not** set `CLAUDE_ACCOUNT` always use the default `~/.claude` credentials.

### Fallback behaviour

- **No profiles** (`~/.claude-*/` directories absent): uses `~/.claude` as-is,
  no account prompt shown. Fully backwards-compatible.
- **Single profile**: auto-selected without a prompt in interactive mode.
- **Non-interactive without `CLAUDE_ACCOUNT`**: uses `~/.claude` regardless of how many
  profiles exist — set `CLAUDE_ACCOUNT` explicitly for scripted multi-profile use.
- **`~/.claude-<name>.json` absent**: falls back to the shared `~/.claude.json`.

## Menu Options

### 1) Start orchestration
Launches Claude with the `orchestrator-mode` skill pre-loaded as a system prompt.
Use for multi-phase development workflows: plan → implement → test → review → merge.

**Phases:**
- Phase 0: Project verification
- Phase 1: Planning (produces `docs/plans/YYYY-MM-DD-<feature>.md`)
- Phase 2: Implementation (TDD, per-task subagents)
- Phase 3: Testing (test plan + automated tests)
- Phase 4: Code review
- Phase 5: Documentation
- Phase 6: Finalization (merge options)

### 2) Start bulletproof
Launches Claude with the `bulletproof` skill pre-loaded as a system prompt.
Use for the 12-stage adaptive development workflow (research → spec → plan →
implement → verify → review → deploy).

### 3) Start new conversation
Launches a plain Claude session with no additional system prompt.

### 4) Resume from list
Resumes a previous Claude session (Claude will show a session picker).

### h) Help
Shows this help document.

## Skills

Skills are located in `~/.agents/skills/` (symlinked from `~/.claude/skills/`).
Claude Code discovers them automatically.

Key skills available:
- `orchestrator-mode` — Full feature delivery orchestration
- `bulletproof` — 12-stage verified dev workflow
- `writing-plans` — Implementation plan creation
- `implementing-tasks` — TDD task execution with file ownership and self-review
- `planning-tests` — Test strategy design (produces test plan for automation-tester)
- `writing-automated-tests` — AAA-structured test writing with isolation and control cases
- `updating-documentation` — Post-review doc updates (README, env vars, changelog)
- `subagent-driven-development` — Same-session plan execution with reviews
- `executing-plans` — Parallel session plan execution
- `requesting-code-review` — Code review dispatch
- `using-git-worktrees` — Isolated workspace creation
- `finishing-a-development-branch` — Branch completion and merge options
- `find-skills` — Discover installable skills

## Keyboard Shortcuts

In Claude CLI:
- `Ctrl+C`: Cancel current operation
- `Ctrl+D`: Exit session
- `/help`: Show Claude CLI help
