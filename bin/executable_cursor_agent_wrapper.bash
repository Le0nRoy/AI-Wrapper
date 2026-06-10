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

export RLIMIT_AS=unlimited                       # Unlimited address space
export RLIMIT_CPU=unlimited                      # Unlimited CPU time
export RLIMIT_NOFILE=4096                        # Higher limit for browsers and test files
export RLIMIT_NPROC=4096                         # High limit for parallel test workers and browser processes

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

# Interactive session selection (only if no arguments provided and stdin/stdout are terminals)
if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    check_agent_binary
    action=$(show_main_menu)

    case "${action}" in
        orchestrate|bulletproof)
            run_orchestrated_session "${action}"
            exit $?
            ;;
        *)
            run_agent_session "${action}"
            exit $?
            ;;
    esac
fi

# Non-interactive mode or with arguments
# AI rules (AGENTS.md and CLAUDE.md) are bound by default in universal wrapper
run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}" "$@"
