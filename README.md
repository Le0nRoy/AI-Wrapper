# ai-wrapper

AI orchestration tools, sandboxed wrappers, and agent skills for Claude, Codex, Antigravity (`agy`), Cursor Agent, and GitHub Copilot.

Managed with [chezmoi](https://www.chezmoi.io/). Compatible with any Linux machine — no Linux desktop config required.

## What This Deploys

Paths assume the chezmoi destination `~/ai-wrapper` that the scripts expect (`run_after_register-agent-skills.bash` runs `~/ai-wrapper/bin/setup_skills.bash`).

| Chezmoi source | Deployed path | Description |
|----------------|---------------|-------------|
| `bin/executable_claude_wrapper.bash` | `~/ai-wrapper/bin/claude_wrapper.bash` | Sandboxed Claude CLI launcher with account selection |
| `bin/executable_codex_wrapper.bash` | `~/ai-wrapper/bin/codex_wrapper.bash` | Sandboxed Codex CLI launcher with account selection |
| `bin/executable_agy_wrapper.bash` | `~/ai-wrapper/bin/agy_wrapper.bash` | Sandboxed Antigravity CLI (`agy`) launcher with account selection |
| `bin/executable_cursor_agent_wrapper.bash` | `~/ai-wrapper/bin/cursor_agent_wrapper.bash` | Sandboxed Cursor Agent launcher |
| `bin/executable_copilot_wrapper.bash` | `~/ai-wrapper/bin/copilot_wrapper.bash` | Sandboxed GitHub Copilot CLI launcher |
| `bin/executable_setup_ai_kube_access.bash` | `~/ai-wrapper/bin/setup_ai_kube_access.bash` | Kubernetes RBAC setup for AI agents |
| `bin/ai_agent_universal_wrapper.bash` | `~/ai-wrapper/bin/ai_agent_universal_wrapper.bash` | Bubblewrap sandbox library (sourced by wrappers) |
| `bin/ai_wrapper_data/` | `~/ai-wrapper/bin/ai_wrapper_data/` | Prompt templates and per-agent wrapper libs |
| `dot_agents/skills/` | `~/ai-wrapper/.agents/skills/` | Agent skills (synced to every wrapped client's native skill directory via `setup_skills.bash`) |
| `AGENTS.md` | `~/ai-wrapper/AGENTS.md` | System-wide AI agent rules (the sandbox RO-binds `~/AGENTS.md` when present) |
| `CLAUDE.md` | `~/ai-wrapper/CLAUDE.md` | Claude Code guidelines redirect (the sandbox RO-binds `~/CLAUDE.md` when present) |

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
- **Linux:** [bubblewrap](https://github.com/containers/bubblewrap) — read-only filesystem mounts (except specific project paths), network shared with the host (`--share-net`; no egress filtering), no access to `~/.ssh`, `~/.gnupg`, or credentials outside the sandbox unless opted in via `AI_SANDBOX_PASS_*` flags. `~/bin` and the skill source `~/ai-wrapper/.agents` are read-only, and `~/Android` and the Tailscale socket are absent, unless enabled with the Linux-only `AI_SANDBOX_ALLOW_BIN_RW`, `AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW`, `AI_SANDBOX_ALLOW_ANDROID` and `AI_SANDBOX_PASS_TAILSCALE` settings (the Tailscale socket bind is read-only, but the Tailscale API is not; see `docs/security-concerns.md` S-θ). The host `$XDG_RUNTIME_DIR` is not shared: the sandbox gets a private one, and only the SSH agent and rootless Docker/Podman sockets are shared when their settings are on; `AI_SANDBOX_ALLOW_XDG_RUNTIME_RW` restores the whole directory (S-ι). Kind is not supported inside the sandbox.
- **macOS:** `sandbox-exec` (Seatbelt), profile at `bin/ai_wrapper_data/claude_wrapper.sb` — same default-deny, opt-in-credential-gating model as the Linux backend.

WORKDIR is writable, but its own git metadata is not: the `.git` dir is pinned and existing `config`, `hooks/` and pointer files are read-only (also in submodule git dirs at any depth, whose directory chain is pinned), because host git runs hooks and config commands outside the sandbox. `git config`, `remote add` and upstream changes therefore fail inside the sandbox unless `AI_SANDBOX_ALLOW_GIT_CONFIG=1`; see `docs/security-concerns.md` B-ν for the residual risks. A linked worktree's shared `.git` is bound with the same read-only layers when it lies under `$HOME`; one outside `$HOME` (e.g. `/Data/...`) only for a session started with `AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES=1` (launch env or `s) Settings`, never saved in presets; B-ο).

Resource-limit enforcement (`RLIMIT_*` via `prlimit`) was removed 2026-09 and is not currently reintroduced on either backend; see `AGENTS.md` Section 3.

See `AGENTS.md` → Section 3 (Security) and `docs/security-concerns.md` for details.

## Testing

See `docs/testing.md` for safe test commands, test isolation (tests never
launch an installed AI client), per-OS scope and CI mapping.
