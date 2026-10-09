# ai-wrapper

AI orchestration tools, sandboxed wrappers, and agent skills for Claude, Codex, Cursor Agent, and Hermes.

Managed with [chezmoi](https://www.chezmoi.io/). CLI wrappers do not require the Linux desktop configuration. Hermes uses a separate Linux-only profile; its private Desktop requires Xpra and Xvfb.

## What This Deploys

With this repository deployed directly to the home directory:

| Chezmoi source | Deployed path | Description |
|----------------|---------------|-------------|
| `bin/executable_claude_wrapper.bash` | `~/bin/claude_wrapper.bash` | Sandboxed Claude CLI launcher with account selection |
| `bin/executable_codex_wrapper.bash` | `~/bin/codex_wrapper.bash` | Sandboxed Codex CLI launcher with account selection |
| `bin/executable_cursor_agent_wrapper.bash` | `~/bin/cursor_agent_wrapper.bash` | Sandboxed Cursor Agent launcher |
| `bin/executable_hermes_wrapper.bash` | `~/bin/hermes_wrapper.bash` | Protected Hermes CLI, backend, gateway, Desktop, and worker entry point |
| `bin/executable_setup_hermes.bash` | `~/bin/setup_hermes.bash` | Explicit runtime preparation, profile registration, and diagnosis |
| `bin/executable_setup_ai_kube_access.bash` | `~/bin/setup_ai_kube_access.bash` | Kubernetes RBAC setup for AI agents |
| `bin/executable_setup_kind.bash` | `~/bin/setup_kind.bash` | kind + kubectl installer for AI sandboxing |
| `bin/ai_agent_universal_wrapper.bash` | `~/bin/ai_agent_universal_wrapper.bash` | Bubblewrap sandbox library (sourced by wrappers) |
| `bin/ai_wrapper_data/` | `~/bin/ai_wrapper_data/` | Prompt templates and per-agent wrapper libs |
| `dot_agents/skills/` | `~/.agents/skills/` | Agent skills (synced to `~/.claude/skills/` via `setup_skills.bash`) |
| `AGENTS.md` | `~/AGENTS.md` | System-wide AI agent rules |
| `CLAUDE.md` | `~/CLAUDE.md` | Claude Code guidelines redirect |

The parent `chezmoi-dotfiles` repository instead deploys this source to `~/ai-wrapper` through `run_always_install-ai-wrapper.bash`. In that installation, Hermes commands are `~/ai-wrapper/bin/hermes_wrapper.bash` and `~/ai-wrapper/bin/setup_hermes.bash`; the parent also supplies the Hermes systemd user units. Documentation and tests are excluded from chezmoi deployment.

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
chezmoi diff
chezmoi apply
```

If you already use chezmoi with another dotfiles repo, apply this as a secondary source:

```bash
chezmoi diff --source "$HOME/.local/share/ai-wrapper"
chezmoi apply --source "$HOME/.local/share/ai-wrapper"
```

## Skills

Skills are deployed to `~/.agents/skills/` and synced into `~/.claude/skills/` on every `chezmoi apply` by `run_always_register-agent-skills.bash` (via `~/bin/setup_skills.bash`). Claude Code discovers them automatically via the skills directory.

## Hermes

The Hermes implementation pins upstream revision `19cb1cbfedeafaca099be6ff0141a28a6c516c0f`. It separates the read-only application runtime, private writable profile state, and one approved writable workspace. Provider credentials and browser sessions belong to that profile and remain readable inside it. Networking is shared and unrestricted, including host loopback and abstract AF_UNIX sockets. MCP and computer-use are excluded from Hermes dispatch, not from arbitrary scripts calling network APIs.

For the parent-repository installation, prepare private parent directories and an existing project workspace, then inspect preparation before running it:

```bash
mkdir -p -m 700 "$HOME/.local/share/hermes-runtimes" "$HOME/.local/share/hermes-sandbox/profiles"
~/ai-wrapper/bin/setup_hermes.bash prepare --profile work \
    --runtime "$HOME/.local/share/hermes-runtimes/19cb1cb" \
    --workspace "$HOME/projects/my-project" --dry-run
```

Remove `--dry-run` to explicitly prepare and register the profile. Preparation requires working Linux user namespaces, Git, bubblewrap, the pinned system Python version, and declared native tools for the confined Desktop build; it does not install host packages or start services. Runtime execution additionally requires `systemd-run` and a working systemd user manager for mandatory scope budgets. An existing reviewed runtime with its preparation manifest/PM seed can instead be registered with `setup_hermes.bash init --profile work --runtime DIR --workspace DIR`.

```bash
~/ai-wrapper/bin/setup_hermes.bash doctor --profile work
~/ai-wrapper/bin/hermes_wrapper.bash --profile work
~/ai-wrapper/bin/hermes_wrapper.bash --profile work serve --port 9119
~/ai-wrapper/bin/hermes_wrapper.bash --profile work desktop
~/ai-wrapper/bin/hermes_wrapper.bash --profile work addons list
```

The complete Desktop application, its PTY, and preview run inside bubblewrap on a private Xvfb display; the host Xpra client renders the result. Clipboard, file transfer, host URL/file opening, and audio bridges are disabled. This requires Xpra, Xvfb, xauth, fonts, and a prepared Desktop package with the protected backend compatibility gates; host dependencies are never installed automatically with sudo. Host display cookies/sockets are not intentionally mounted, but shared abstract sockets can expose X11 when it trusts local clients. Use cookie-authenticated host X11 without local `xhost` grants; this is not full network/GUI access isolation.

See [Hermes sandbox](docs/features/hermes-sandbox.md) for registration, credentials, services, optional add-ons, and validation. The source implementation and automated checks do not establish live provisioning, Desktop operation, provider authentication, or systemd restart recovery on this machine. Those remain acceptance checks before claiming the full feature target.

Native profile APIs are pinned to the selected registration; separate registry profiles require their own host setup and CLI/gateway instances. Manage registration/policy edits and reviewed pin upgrades on the host. Native `hermes update` cannot update the read-only application checkout.

## Sandbox Architecture

The wrappers dispatch to an OS-appropriate sandbox backend (`ai_agent_universal_wrapper.bash` picks one via `uname -s`):
- **Linux:** [bubblewrap](https://github.com/containers/bubblewrap) — read-only filesystem mounts (except specific project paths), network access controlled per-wrapper, no access to `~/.ssh`, `~/.gnupg`, or credentials outside the sandbox unless opted in via `AI_SANDBOX_PASS_*` flags.
- **macOS:** `sandbox-exec` (Seatbelt), profile at `bin/ai_wrapper_data/claude_wrapper.sb` — same default-deny, opt-in-credential-gating model as the Linux backend.

Resource-limit enforcement (`RLIMIT_*` via `prlimit`) was removed 2026-09 and is not currently reintroduced on either backend; see `AGENTS.md` Section 3.

Hermes selects a dedicated strict Linux policy instead of the default wrapper mounts and credential passthrough flags. Its broker accepts only registered cron/Kanban worker identities; host D-Bus and Docker/SSH-agent sockets are not mounted into the profile. The parent repository supplies aggregate systemd slice limits, and interactive execution enters mandatory user scopes within `hermes.slice`; workers use independent broker-controlled units.

See `AGENTS.md` → Section 3 (Security) and the `ai-sandboxing` skill for details.
