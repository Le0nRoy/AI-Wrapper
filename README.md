# ai-wrapper

AI orchestration tools, sandboxed wrappers, and agent skills for Claude, Codex, Antigravity (`agy`), Cursor Agent, and GitHub Copilot.

Managed with [chezmoi](https://www.chezmoi.io/). Compatible with any Linux machine — no Linux desktop config required.

## What This Deploys

| Chezmoi source | Deployed path | Description |
|----------------|---------------|-------------|
| `bin/executable_claude_wrapper.bash` | `~/bin/claude_wrapper` | Sandboxed Claude CLI launcher with account selection |
| `bin/executable_codex_wrapper.bash` | `~/bin/codex_wrapper` | Sandboxed Codex CLI launcher with account selection |
| `bin/executable_agy_wrapper.bash` | `~/bin/agy_wrapper` | Sandboxed Antigravity CLI (`agy`) launcher with account selection |
| `bin/executable_cursor_agent_wrapper.bash` | `~/bin/cursor_agent_wrapper` | Sandboxed Cursor Agent launcher |
| `bin/executable_copilot_wrapper.bash` | `~/bin/copilot_wrapper` | Sandboxed GitHub Copilot CLI launcher |
| `bin/executable_setup_ai_kube_access.bash` | `~/bin/setup_ai_kube_access` | Kubernetes RBAC setup for AI agents |
| `bin/executable_setup_kind.bash` | `~/bin/setup_kind` | kind + kubectl installer for AI sandboxing |
| `bin/ai_agent_universal_wrapper.bash` | `~/bin/ai_agent_universal_wrapper.bash` | Bubblewrap sandbox library (sourced by wrappers) |
| `bin/ai_wrapper_data/` | `~/bin/ai_wrapper_data/` | Prompt templates and per-agent wrapper libs |
| `dot_agents/skills/` | `~/.agents/skills/` | Agent skills (synced to every wrapped client's native skill directory via `setup_skills.bash`) |
| `AGENTS.md` | `~/AGENTS.md` | System-wide AI agent rules |
| `CLAUDE.md` | `~/CLAUDE.md` | Claude Code guidelines redirect |

## Prerequisites

- Linux (tested on Arch Linux) or macOS
- [`chezmoi`](https://www.chezmoi.io/) installed
- Linux: `bubblewrap` (`bwrap`) for sandbox wrappers, `kernel.unprivileged_userns_clone = 1` in sysctl
- macOS: `sandbox-exec` (ships with the OS)
- The target AI CLI tools installed (`claude`, `codex`, `agy`, `cursor-agent`, `copilot` as applicable)

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

The active shared set is `caveman` (concise chat), `orchestrator-mode` (delegated investigation, planning, and implementation), `ponytail` (smallest complete changes and evidence-based scope pushback; owner default: ultra), `session-retro` (session analysis), and `tortuga` (on-demand use of the existing GitHub runner). Redundant development workflow skills are no longer deployed. On upgraded installs `setup_skills.bash` moves their leftover source copies and managed client copies to `~/ai-wrapper/.retired-skills/`, outside discovery roots; unmanaged same-name skills are left alone.

In the secondary-source installation, source files are `dot_agents/skills/`, deployed to `~/ai-wrapper/.agents/skills/`. `~/.agents/skills` is the agent-neutral alias on this host. `~/ai-wrapper/bin/setup_skills.bash` makes sandbox-safe managed copies for Claude Code, Codex, Antigravity CLI, Cursor Agent, and GitHub Copilot CLI, including existing named Claude, Codex, and Antigravity profiles. A single source is maintained, not per-client editable variants. Run it after adding a profile or changing skills; it preserves unmanaged skills. Hermes uses `skills.external_dirs` pointing to `~/.agents/skills` and auto-loads only caveman/ponytail. Other skills remain discoverable on demand. Installing a skill does not guarantee a running client has activated it.

Tortuga's small `scripts/gh.py` helper reuses `make get-github-token REPO=OWNER/REPO` and `gh`; it does not create an executor, queue, permanent credential store or service. Set `TORTUGA_HOME` on another machine. Explicit `--repo` works outside a checkout; default targeting uses the caller's GitHub origin. App access and project-specific verification settings are still required. No automatic GitHub App installation, task launch or arbitrary local-folder execution is provided.

## Sandbox Architecture

The wrappers dispatch to an OS-appropriate sandbox backend (`ai_agent_universal_wrapper.bash` picks one via `uname -s`):
- **Linux:** [bubblewrap](https://github.com/containers/bubblewrap) — read-only filesystem mounts (except specific project paths), network access controlled per-wrapper, no access to `~/.ssh`, `~/.gnupg`, or credentials outside the sandbox unless opted in via `AI_SANDBOX_PASS_*` flags.
- **macOS:** `sandbox-exec` (Seatbelt), profile at `bin/ai_wrapper_data/claude_wrapper.sb` — same default-deny, opt-in-credential-gating model as the Linux backend.

WORKDIR is writable, but its own git metadata is not: the `.git` dir is pinned and existing `config`, `hooks/` and pointer files are read-only, because host git runs hooks and config commands outside the sandbox. `git config`, `remote add` and upstream changes therefore fail inside the sandbox unless `AI_SANDBOX_ALLOW_GIT_CONFIG=1`; see `docs/security-concerns.md` B-ν for the residual risks.

Resource-limit enforcement (`RLIMIT_*` via `prlimit`) was removed 2026-09 and is not currently reintroduced on either backend; see `AGENTS.md` Section 3.

See `AGENTS.md` → Section 3 (Security) and `docs/security-concerns.md` for details.

## Testing

See `docs/testing.md` for safe test commands, test isolation (tests never
launch an installed AI client), per-OS scope and CI mapping.
