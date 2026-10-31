# AI Agent Rules

> **Repo:** This file is deployed from the [`ai-wrapper`](https://github.com/Le0nRoy/ai-wrapper) chezmoi repo.
> Linux system configs (i3, polybar, bash, etc.) live in the separate `chezmoi-dotfiles` repo.

These rules apply to **Claude Code** (and any other AI agents) working on **any project** on this system.

**User**: Vadim (le0nRoy) | **Platform**: Linux (Arch-based) | **Shell**: bash (primary)

---

## Where to Find Resources

| Resource | Location |
|----------|----------|
| User-level skills | `~/.agents/skills/` (copied into every wrapped client's native skill directory by `setup_skills.bash`; named Claude, Codex, and Antigravity profiles are included, and each managed copy carries a `.setup_skills_managed` marker) |
| Orchestrator prompt | `~/ai-wrapper/bin/ai_wrapper_data/orchestrator-prompt.md` |
| Installed plugins | `~/.claude/settings.json` → `enabledPlugins` |
| Plugin marketplace | `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/` |
| Sandbox settings / account switching | `s) Settings` in the wrapper's main menu — toggles `AI_SANDBOX_*` flags and the active `CLAUDE_ACCOUNT` / `CODEX_ACCOUNT` / `AGY_ACCOUNT` profile; persists per-workdir and per-agent |
| macOS sandbox backend | `sandbox-exec` (Seatbelt), auto-selected via `uname -s` — see `bin/ai_wrapper_data/macos_sandbox_exec.bash` and `claude_wrapper.sb` |

**Core guidance lives in this file** (coding standards: Section 2; testing
and isolation: Section 4; this repo's chezmoi and sandbox rules: Section 3
and "This Repository"). In the `ai-wrapper` checkout, `README.md`,
`docs/security-concerns.md` and `docs/testing.md` hold the details.

---

## 1. Read Before Writing

- Read files completely before modifying them
- Understand context, patterns, and existing conventions
- Check `git log --oneline -10` and `git status` at session start to understand current state
- Look for `README`, `CONTRIBUTING`, `AGENTS.md`, `CLAUDE.md`, `TODO.md`

---

## 2. Preserve User Preferences

- Respect existing code style and formatting (indentation, naming, structure)
- Follow project-specific conventions over general guidelines
- **Do not revert user's SVC changes between sessions**: if the user removed files from stage, made fixes, or reset commits between sessions — honor that state. Check `git status` and `git log` before acting, not after.
- If you find unexpected state (untracked files, uncommitted changes, detached HEAD) — investigate and ask before overwriting

**Coding standards** (when the project has none of its own):
- Descriptive names; no single-letter names outside tight loops
- No magic numbers — named constants
- Early returns; keep nesting to 3 levels or fewer
- One responsibility per function
- No race conditions: no check-then-act on shared files, no unconditional sleeps — poll with a deadline

---

## 3. Security First

Sandbox architecture (this repo): `README.md` → Sandbox Architecture,
`bin/ai_agent_universal_wrapper.bash` (Linux bubblewrap),
`bin/ai_wrapper_data/macos_sandbox_exec.bash` + `claude_wrapper.sb` (macOS
Seatbelt), and `docs/security-concerns.md` for known gaps and decisions.

**Always:**
- Never commit secrets, credentials, API keys, private keys, or tokens
- Validate all paths before operations (no directory traversal)
- Use `--ro-bind` in sandbox modifications (not `--bind`)
- Ask before executing destructive commands (`rm -rf`, `mkfs`, `dd`, etc.)
- Never modify file permissions arbitrarily

**When working in this repo (chezmoi wrappers):**
- Never weaken bubblewrap or Seatbelt restrictions (mounts, credential
  fences, env scrubbing, network gates); opt-in access stays behind
  `AI_SANDBOX_*` flags that default to off
- Rlimit enforcement is currently disabled (dropped 2026-09, both Linux and
  macOS backends) — don't reintroduce it ad hoc; re-adding it is tracked as
  a separate follow-up issue
- Preserve all path validation logic

---

## 4. Test and Validate

- Validate syntax before claiming completion: `bash -n script.bash`, `python -m py_compile`, `jq .`
- Use dry-run modes when available
- Test in safe environments (subshells, staging) when possible
- Run `shellcheck` if available for bash scripts
- Verify changes work as intended before reporting done
- Isolate tests: fake `HOME`/XDG dirs, temp dirs cleaned up on exit, stub
  clients. Never let a test reach a real authenticated CLI, live account,
  or real credential/config dir
- Cover both the success path and the rejection path
- Report skipped or unavailable checks as skipped, never as passed
- In this repo: see `docs/testing.md` (safe commands, `isolate_test_env`,
  per-OS scope, CI mapping)

---

## 5. Git Workflow

### Commits During Work

Commits are allowed during work. Commit at logical checkpoints, not just at the end.

**Commit message format:**
```
type: brief summary (≤50 chars)

Optional explanation of what and why (≤72 chars per line).
```
Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

### Session Squash (Important)

At the end of a work session, **squash all session commits** so the user can review one clean diff:

```bash
# Find the SHA before this session started
SESSION_START_SHA=$(git log --oneline | tail -1 | awk '{print $1}')  # adjust as needed

# Show the user what changed this session
git log --oneline ${SESSION_START_SHA}..HEAD

# Squash into one (or few logical) commits
git rebase -i ${SESSION_START_SHA}
# → mark all except first as 'squash' or 'fixup'
```

Present to user:
```
Session complete. I made N commits during this session.
Start SHA: {session_start_sha}
Current SHA: {HEAD}
Review all changes: git diff {session_start_sha} HEAD
Squash already done — you have 1 clean commit to review.
```

### Branches

- Never push without explicit user instruction
- Feature work on `feat/`, fixes on `fix/`, docs on `docs/`

### Do Not

- Force-push to `main`/`master` without explicit instruction
- `git reset --hard` or discard uncommitted changes without asking
- Re-stage files the user removed from staging

---

## 6. Documentation Maintenance

**Always keep documentation up to date** as part of completing any task.

| Doc type | Where | When to update |
|----------|-------|----------------|
| High-level design | `docs/design/` | Architecture changes |
| Feature design | `docs/features/<name>.md` | New features, significant changes |
| API / interface docs | Inline docstrings + `docs/api/` | Endpoint or interface changes |
| Onboarding (human) | `README.md`, `docs/ONBOARDING.md` | Setup/workflow changes |
| Onboarding (AI) | `AGENTS.md`, `CLAUDE.md` | Policy/convention changes |
| Testing docs | `docs/TESTING.md` | New test infra, coverage changes |
| Legal compliance | `docs/legal/` or `docs/COMPLIANCE.md` | Data handling, PII, new integrations |

**Legal docs required when:** feature handles user data, stores PII, processes payments, or integrates with external services.

---

## 7. Communication

- **Be specific**: reference `file.ext:line_number` not just "the file"
- **Explain reasoning**: why, not just what
- **Mention side effects**: what else might be affected by a change
- **Provide test commands**: help the user verify changes
- **Document non-obvious changes**: brief inline comment or doc update

### When Asking for Clarification

- Ask before making structural changes
- Offer alternatives with trade-offs
- Be explicit about what you don't know
- Do not ask multiple questions in one message — ask the most important one first

---

## 8. Prohibited Actions

**NEVER:**
- Commit secrets, credentials, API keys, tokens, or private keys
- Weaken sandbox security or remove bubblewrap restrictions
- Delete files without confirmation
- Execute destructive commands without confirmation (`rm -rf`, `mkfs`, `dd`, disk operations)
- Break existing user workflows
- Modify dotfiles without understanding their deployment impact (chezmoi prefixes)
- Stage or re-stage files the user deliberately removed from staging
- Ignore existing uncommitted user changes — always check `git status` first

---

## 9. Recommended Actions

**ALWAYS:**
- Read files before modifying
- Check `git status` at the start of every session
- Preserve existing patterns and conventions
- Validate syntax before completing tasks
- Communicate with file:line references
- Update relevant documentation when changing behavior
- When in doubt about impact on user's system — ask first

---

## 10. When in Doubt

1. **Read first** — understand before acting
2. **Check state** — `git status`, `git log`, look for existing patterns
3. **Ask user** — one clear question about the most important uncertainty
4. **Test safely** — dry-run, validation commands, subshells
5. **Document** — explain what you did and why
6. **Be conservative** — prefer minimal, reversible changes

---

## This Repository (Chezmoi-Specific)

- **Naming:** `dot_x` deploys as `.x`; `executable_x` deploys with the
  execute bit; `private_x` deploys with owner-only permissions; `x.tmpl`
  is rendered as a chezmoi template; `run_once_*` / `run_after_*` scripts
  run on `chezmoi apply`. `README.md` → "What This Deploys" maps sources to
  targets; `.chezmoiignore` lists what is never deployed (`docs/`, `tests/`,
  `.github/`, `README.md`).
- **Edit the source, not the target:** change files here, never the
  deployed copies under `~/ai-wrapper` (e.g. `~/ai-wrapper/bin`,
  `~/ai-wrapper/.agents`) or `~/`.
- **Deploy:** `chezmoi diff` to preview, `chezmoi apply` only when the user
  asks. Changes do not deploy until then. This repo may be a secondary
  source: `CHEZMOI_SOURCE_DIR="$HOME/.local/share/ai-wrapper" chezmoi diff`.
- **Security-critical files** (Section 3 applies in full):
  `bin/ai_agent_universal_wrapper.bash`, `bin/ai_wrapper_data/macos_sandbox_exec.bash`,
  `bin/ai_wrapper_data/claude_wrapper.sb`, `bin/ai_wrapper_data/ai_wrapper_lib.bash`,
  `bin/ai_wrapper_data/*_wrapper_lib.bash`, `bin/executable_*_wrapper.bash`.
- **Tests:** `docs/testing.md`. Write bash that also runs on macOS bash 3.2.
