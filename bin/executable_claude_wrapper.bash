#!/bin/bash
# Lightweight, minimal-privilege wrapper for Claude CLI using bubblewrap.
# Uses the universal AI agent wrapper with claude-specific configuration.
#
# Features:
# - Multi-account credential management (auto-discovers ~/.claude-<name>/ profiles)
# - Agent orchestration (plan → implement → test → review → merge)
# - Sandboxed execution with resource limits
# - Session resume support
#
# Non-interactive account selection: set CLAUDE_ACCOUNT=<name> in the environment.

source "$(dirname "${BASH_SOURCE[0]}")/ai_agent_universal_wrapper.bash"

# Requires `chezmoi apply` to have been run — if source fails, the wrapper is not yet deployed.
source "$(dirname "${BASH_SOURCE[0]}")/ai_wrapper_data/claude_wrapper_lib.bash"

# Configurable rlimits (adjusted for test debugging with pytest-xdist and Playwright)
export RLIMIT_AS=unlimited                       # Unlimited for large models and WebAssembly
export RLIMIT_CPU=unlimited                      # Unlimited CPU time
export RLIMIT_NOFILE=4096                        # Higher limit for browsers and test files
export RLIMIT_NPROC=4096                         # High limit for parallel test workers and browser processes

# Discover available account profiles from ~/.claude-<name>/ directories.
# With 0 or 1 profiles, returns the name without prompting (or "" for default).
# With 2+ profiles, shows an interactive selection menu.
select_claude_account() {
    local -a profiles=()
    for dir in "${HOME}/.claude-"*/; do
        [[ -d "${dir}" ]] || continue
        local name="${dir#"${HOME}/.claude-"}"
        name="${name%/}"
        if [[ ! "${name}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "Skipping profile with invalid name '${name}' (must match [a-zA-Z0-9_-]+)" >/dev/tty
            continue
        fi
        profiles+=("${name}")
    done

    [[ ${#profiles[@]} -eq 0 ]] && { echo ""; return 0; }
    [[ ${#profiles[@]} -eq 1 ]] && { echo "${profiles[0]}"; return 0; }

    echo "==========================================" >/dev/tty
    echo "    Claude CLI - Account Selection"        >/dev/tty
    echo "==========================================" >/dev/tty
    echo ""                                          >/dev/tty
    local i=1
    for name in "${profiles[@]}"; do
        printf "  %d) %s\n" "${i}" "${name}" >/dev/tty
        i=$((i + 1))
    done
    echo "" >/dev/tty

    local choice
    while true; do
        printf "Choose account [1-%d]: " "${#profiles[@]}" >/dev/tty
        read -r choice </dev/tty
        if [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le ${#profiles[@]} ]]; then
            echo "${profiles[$((choice - 1))]}"
            return 0
        fi
        echo "Invalid choice, try again." >/dev/tty
    done
}

# Verify the agent binary is present before doing anything else — runs unconditionally
# so that non-interactive/scripted callers also get a clear error rather than a
# cryptic sandbox failure later.
check_agent_binary

# Resolve account: CLAUDE_ACCOUNT env var takes priority in all modes;
# interactive picker shown as fallback for terminal sessions without arguments.
# Non-interactive callers without CLAUDE_ACCOUNT always use the default ~/.claude.
if [[ -n "${CLAUDE_ACCOUNT:-}" ]]; then
    account="${CLAUDE_ACCOUNT}"
    if [[ ! "${account}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Invalid CLAUDE_ACCOUNT '${account}': must contain only letters, digits, hyphens, underscores" >&2
        exit 1
    fi
elif [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    account=$(select_claude_account)
else
    account=""
fi

# Map account name to credential paths; update display name so the menu header reflects it
if [[ -n "${account}" ]]; then
    claude_dir="${HOME}/.claude-${account}"
    [[ -d "${claude_dir}" ]] || { echo "Account profile directory not found: ${claude_dir}" >&2; exit 1; }
    if [[ -f "${HOME}/.claude-${account}.json" ]]; then
        claude_json_src="${HOME}/.claude-${account}.json"
    else
        claude_json_src="${HOME}/.claude.json"
    fi
    AI_WRAPPER_AGENT_NAME="Claude CLI [${account}]"
else
    claude_dir="${HOME}/.claude"
    claude_json_src="${HOME}/.claude.json"
fi

# Bubblewrap (sandbox) flags - filesystem bindings
WRAPPER_FLAGS=(
    --bind "${claude_dir}" "${HOME}/.claude"
    --bind "/Data/Job/secrets/kuber/dot_kube_devenv" "${HOME}/.kube"
)
[[ -f "${claude_json_src}" ]] && WRAPPER_FLAGS+=(--bind "${claude_json_src}" "${HOME}/.claude.json")

# Claude CLI flags - full autonomy within sandbox (no approvals needed)
AGENT_FLAGS=(
    --dangerously-skip-permissions
)

# Interactive session selection (only if no arguments provided and stdin/stdout are terminals)
if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
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
