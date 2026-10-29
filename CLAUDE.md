# Claude Code Guidelines — ai-wrapper

**This file redirects to the main AI agent guidelines.**

All rules for Claude Code (and other AI agents) are maintained in a single source of truth:

**→ See: [AGENTS.md](AGENTS.md)**

## This Repository

This is the **`ai-wrapper`** chezmoi-managed repository containing:
- AI agent sandbox wrappers (`claude_wrapper`, `codex_wrapper`, `agy_wrapper`, `cursor_agent_wrapper`, `copilot_wrapper`)
- User-level AI agent policies (`AGENTS.md`) deployed to `~/`
- User-level skills (`~/.agents/skills/`) for AI workflow automation
- AI orchestration configs (`bin/ai_wrapper_data/`)

> Linux/system configurations (i3, polybar, bash, etc.) live in the separate `chezmoi-dotfiles` repo.

## Quick Reference

| Need | Where |
|------|-------|
| All rules and policies | `AGENTS.md` |
| Sandbox architecture | `AGENTS.md` § 3, `README.md` → Sandbox Architecture, `docs/security-concerns.md` |
| Chezmoi naming/workflow | `AGENTS.md` → This Repository |
| Code standards | `AGENTS.md` § 2 |
| Test writing and safe test commands | `AGENTS.md` § 4, `docs/testing.md` |
| Orchestration workflow | `orchestrator-mode` skill |
| Tortuga task operations | Shared `tortuga` skill; only on request |
