# Claude Code Guidelines — ai-wrapper

**This file redirects to the main AI agent guidelines.**

All rules for Claude Code (and other AI agents) are maintained in a single source of truth:

**→ See: [AGENTS.md](AGENTS.md)**

## This Repository

This is the **`ai-wrapper`** chezmoi-managed repository containing:
- AI agent sandbox wrappers (`claude_wrapper`, `codex_wrapper`, `cursor_agent_wrapper`)
- User-level AI agent policies (`AGENTS.md`) deployed to `~/`
- User-level skills (`~/.agents/skills/`) for AI workflow automation
- AI orchestration configs (`bin/ai_wrapper_data/`)

> Linux/system configurations (i3, polybar, bash, etc.) live in the separate `chezmoi-dotfiles` repo.

## Quick Reference

| Need | Where |
|------|-------|
| All rules and policies | `AGENTS.md` |
| Sandbox architecture | `ai-sandboxing` skill |
| Chezmoi naming/workflow | `chezmoi-workflow` skill |
| Code standards | `coding-standards` skill |
| Test writing | `qa-automation` skill |
| Code review process | `requesting-code-review` skill |
| Orchestration workflow | `orchestrator-mode` skill |
