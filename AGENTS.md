# AI Agent Rules

> **Repo:** This file is deployed from the [`ai-wrapper`](https://github.com/Le0nRoy/ai-wrapper) chezmoi repo.
> Linux system configs (i3, polybar, bash, etc.) live in the separate `chezmoi-dotfiles` repo.

These rules apply to **Claude Code** (and any other AI agents) working on **any project** on this system.

**User**: Vadim (le0nRoy) | **Platform**: Linux (Arch-based) | **Shell**: bash (primary)

---

## Where to Find Resources

| Resource | Location |
|----------|----------|
| User-level skills | `~/.agents/skills/` (copied into `~/.claude/skills/` by `setup_skills.bash`; each managed copy carries a `.setup_skills_managed` marker so reruns refresh it in place) |
| Orchestrator prompt | `~/bin/ai_wrapper_data/orchestrator-prompt.md` |
| Installed plugins | `~/.claude/settings.json` → `enabledPlugins` |
| Plugin marketplace | `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/` |
| Sandbox settings / account switching | `s) Settings` in the wrapper's main menu — toggles `AI_SANDBOX_*` flags and (Claude wrapper only) the active `CLAUDE_ACCOUNT` profile; persists per-workdir |
| macOS sandbox backend | `sandbox-exec` (Seatbelt), auto-selected via `uname -s` — see `bin/ai_wrapper_data/macos_sandbox_exec.bash` and `claude_wrapper.sb` |

**Key skills (always relevant):**
- `coding-standards` — naming, nesting, no magic numbers, no race conditions
- `qa-automation` — test structure, isolation, integration patterns
- `requesting-code-review` — review process + legal compliance checks
- `chezmoi-workflow` — **required when working in this repo**
- `ai-sandboxing` — bubblewrap sandbox architecture and restrictions
- `common-automation-verifier` — project setup verification

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

---

## 3. Security First

See **`ai-sandboxing`** skill for sandbox architecture details.

**Always:**
- Never commit secrets, credentials, API keys, private keys, or tokens
- Validate all paths before operations (no directory traversal)
- Use `--ro-bind` in sandbox modifications (not `--bind`)
- Ask before executing destructive commands (`rm -rf`, `mkfs`, `dd`, etc.)
- Never modify file permissions arbitrarily

**When working in this repo (chezmoi wrappers):**
- Never weaken bubblewrap security restrictions — see `ai-sandboxing` skill
- Rlimit enforcement is currently disabled (dropped 2026-09, both Linux and
  macOS backends) — don't reintroduce it ad hoc; re-adding it is tracked as
  a separate follow-up issue
- Preserve all path validation logic

---

## 4. Test and Validate

See **`qa-automation`** skill for test structure and patterns.

- Validate syntax before claiming completion: `bash -n script.bash`, `python -m py_compile`, `jq .`
- Use dry-run modes when available
- Test in safe environments (subshells, staging) when possible
- Run `shellcheck` if available for bash scripts
- Verify changes work as intended before reporting done

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
- See `using-git-worktrees` skill for isolated feature work
- See `finishing-a-development-branch` skill for branch completion

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

**Legal docs required when:** feature handles user data, stores PII, processes payments, integrates with external services. See `requesting-code-review` skill for the legal compliance checklist.

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

See **`chezmoi-workflow`** skill for:
- File naming conventions (`dot_`, `executable_`, `private_`, `.tmpl`)
- Deployment workflow (`chezmoi diff`, `chezmoi apply`)
- Repository structure
- Security-critical wrapper files

**Remember:** Changes in this repo don't deploy until `chezmoi apply`. Always use `chezmoi diff` to preview before applying.
