#!/bin/bash
# Lightweight, minimal-privilege wrapper for Cursor Agent CLI using bubblewrap.
# Uses the universal AI agent wrapper with cursor-agent-specific configuration.
#
# Features:
# - Agent orchestration (plan → implement → test → review → merge)
# - Sandboxed execution with resource limits
# - Session resume support

source "$(dirname "${BASH_SOURCE[0]}")/ai_agent_universal_wrapper.bash"

# Requires `chezmoi apply` to have been run — if source fails, the wrapper is not yet deployed.
source "$(dirname "${BASH_SOURCE[0]}")/ai_wrapper_data/cursor_wrapper_lib.bash"

# Bubblewrap (sandbox) flags - filesystem bindings
WRAPPER_FLAGS=(
    --ro-bind /opt/cursor-agent /opt/cursor-agent
    --bind "${HOME}/.cursor" "${HOME}/.cursor"
    --bind "${HOME}/.config/cursor" "${HOME}/.config/cursor"
    --bind "${HOME}/.local/share/cursor-agent" "${HOME}/.local/share/cursor-agent"
)

# Cursor Agent CLI flags - full autonomy within sandbox (no approvals needed)
AGENT_FLAGS=(
    --force
)

check_agent_binary

# Interactive session selection (only if no arguments provided and stdin/stdout are terminals)
if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    # Auto-load the per-workdir preset before the menu renders so restored
    # AI_SANDBOX_* settings are visible in the settings table on first paint.
    # Silent no-op when no preset file exists (first run).
    _preset_autoload
    show_main_menu
    _preset_autosave

    case "${WRAPPER_MENU_CHOICE}" in
        orchestrate)
            run_orchestrated_session
            _dispatch_rc=$?
            ;;
        *)
            run_agent_session "${WRAPPER_MENU_CHOICE}"
            _dispatch_rc=$?
            ;;
    esac

    exit "${_dispatch_rc}"
fi

# Non-interactive or argument pass-through. No menu runs, so load the
# per-workdir preset (AI_SANDBOX_* flags) directly so a scripted invocation
# still picks up settings saved from an earlier interactive session in this
# workdir, instead of silently reverting to catalog defaults.
# AI rules (AGENTS.md and CLAUDE.md) are bound by default in universal wrapper
_preset_autoload
run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}" "$@"
