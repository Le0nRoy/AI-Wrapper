# ai-wrapper

AI orchestration tools, sandboxed wrappers, and agent skills for Claude, Codex, and Cursor Agent.

Managed with [chezmoi](https://www.chezmoi.io/). Compatible with any Linux machine — no Linux desktop config required.

## What This Deploys

| Chezmoi source | Deployed path | Description |
|----------------|---------------|-------------|
| `bin/executable_claude_wrapper.bash` | `~/bin/claude_wrapper` | Sandboxed Claude CLI launcher with account selection |
| `bin/executable_codex_wrapper.bash` | `~/bin/codex_wrapper` | Sandboxed Codex CLI launcher |
| `bin/executable_cursor_agent_wrapper.bash` | `~/bin/cursor_agent_wrapper` | Sandboxed Cursor Agent launcher |
| `bin/executable_setup_ai_kube_access.bash` | `~/bin/setup_ai_kube_access` | Kubernetes RBAC setup for AI agents |
| `bin/executable_setup_kind.bash` | `~/bin/setup_kind` | kind + kubectl installer for AI sandboxing |
| `bin/ai_agent_universal_wrapper.bash` | `~/bin/ai_agent_universal_wrapper.bash` | Bubblewrap sandbox library (sourced by wrappers) |
| `bin/ai_wrapper_data/` | `~/bin/ai_wrapper_data/` | Prompt templates and per-agent wrapper libs |
| `dot_agents/skills/` | `~/.agents/skills/` | Agent skills (synced to `~/.claude/skills/` via `setup_skills.bash`) |
| `AGENTS.md` | `~/AGENTS.md` | System-wide AI agent rules |
| `CLAUDE.md` | `~/CLAUDE.md` | Claude Code guidelines redirect |

## Prerequisites

- Linux (tested on Arch Linux) or macOS
- [`chezmoi`](https://www.chezmoi.io/) installed
- Linux: `bubblewrap` (`bwrap`) for sandbox wrappers, `kernel.unprivileged_userns_clone = 1` in sysctl
- macOS: `sandbox-exec` (ships with the OS)
- The target AI CLI tools installed (`claude`, `codex`, `cursor-agent` as applicable)

## Setup

```bash
# Clone
git clone https://github.com/Le0nRoy/ai-wrapper.git ~/.local/share/ai-wrapper

# Apply with chezmoi
chezmoi init --source ~/.local/share/ai-wrapper
chezmoi apply
```

If you already use chezmoi with another dotfiles repo, apply this as a secondary source:

```bash
CHEZMOI_SOURCE_DIR="$HOME/.local/share/ai-wrapper" chezmoi apply
```

## Skills

Skills are deployed to `~/.agents/skills/` and synced into `~/.claude/skills/` on every `chezmoi apply` by `run_always_register-agent-skills.bash` (via `~/bin/setup_skills.bash`). Claude Code discovers them automatically via the skills directory.

## Sandbox Architecture

The wrappers dispatch to an OS-appropriate sandbox backend (`ai_agent_universal_wrapper.bash` picks one via `uname -s`):
- **Linux:** [bubblewrap](https://github.com/containers/bubblewrap) — read-only filesystem mounts (except specific project paths), network access controlled per-wrapper, no access to `~/.ssh`, `~/.gnupg`, or credentials outside the sandbox unless opted in via `AI_SANDBOX_PASS_*` flags.
- **macOS:** `sandbox-exec` (Seatbelt), profile at `bin/ai_wrapper_data/claude_wrapper.sb` — same default-deny, opt-in-credential-gating model as the Linux backend.

Resource-limit enforcement (`RLIMIT_*` via `prlimit`) was removed 2026-09 and is not currently reintroduced on either backend; see `AGENTS.md` Section 3.

See `AGENTS.md` → Section 3 (Security) and the `ai-sandboxing` skill for details.
