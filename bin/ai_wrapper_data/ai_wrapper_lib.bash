#!/bin/bash
# Shared menu and orchestration library for AI agent wrappers.
# Sourced by agent-specific libs after setting required variables.
#
# Prerequisites (must be satisfied before sourcing):
#   run_sandboxed_agent    - function from ai_agent_universal_wrapper.bash (source that first)
#
# Required variables (set before sourcing):
#   AI_WRAPPER_AGENT_NAME  - Display name (e.g. "Claude CLI")
#   AI_AGENT_COMMAND       - Binary to run (e.g. "claude")
#
# Required variables (set by the calling wrapper, used by run_orchestrated_session/run_agent_session):
#   WRAPPER_FLAGS          - Array of bubblewrap flags (--bind mounts, etc.)
#   AGENT_FLAGS            - Array of agent-specific CLI flags
#
# Optional variables:
#   WRAPPER_DATA_DIR       - Path to this directory (defaults to the directory containing this file)
#   WRAPPER_HELP           - Path to help file (defaults to wrapper-help.md in WRAPPER_DATA_DIR)
#   AI_SYSTEM_PROMPT_FLAG  - CLI flag for system prompt injection (e.g. "--append-system-prompt")
#                            If unset, orchestration mode starts a plain session with a warning.
#   AI_RESUME_ARGS         - Array of args for resume mode (default: --resume)
#                            Note: an empty array (AI_RESUME_ARGS=()) also triggers the default.

WRAPPER_DATA_DIR="${WRAPPER_DATA_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
WRAPPER_HELP="${WRAPPER_HELP:-${WRAPPER_DATA_DIR}/wrapper-help.md}"
ORCHESTRATOR_PROMPT="${WRAPPER_DATA_DIR}/orchestrator-prompt.md"
BULLETPROOF_PROMPT="${WRAPPER_DATA_DIR}/bulletproof-prompt.md"

# ===== UTILITY FUNCTIONS =====

wrapper_log() {
    local level="${1}"
    shift
    printf '[%s] %s: %s\n' "${AI_WRAPPER_AGENT_NAME:-ai-wrapper}" "${level}" "$*" >&2
}

# ===== BINARY CHECK =====

# Check that the agent binary exists. Exits with 127 if not found.
# Call from the parent shell (not a subshell) so exit propagates correctly.
check_agent_binary() {
    if ! command -v "${AI_AGENT_COMMAND}" &>/dev/null; then
        echo "ERROR: '${AI_AGENT_COMMAND}' not found in PATH." >&2
        echo "Please install ${AI_WRAPPER_AGENT_NAME} before using this wrapper." >&2
        exit 127
    fi
}

# ===== MENU DISPLAY =====
# All menu output goes to /dev/tty to avoid capture by $() subshells.

show_header() {
    clear >/dev/tty
    echo "==========================================" >/dev/tty
    printf "    %-38s\n" "${AI_WRAPPER_AGENT_NAME} - Session Options" >/dev/tty
    echo "==========================================" >/dev/tty
    echo "" >/dev/tty
}

display_help() {
    show_header
    if [[ -f "${WRAPPER_HELP}" ]]; then
        if command -v less &>/dev/null; then
            less "${WRAPPER_HELP}" </dev/tty >/dev/tty
        else
            cat "${WRAPPER_HELP}" >/dev/tty
        fi
    else
        echo "Wrapper for ${AI_WRAPPER_AGENT_NAME}" >/dev/tty
        echo "" >/dev/tty
        echo "Options:" >/dev/tty
        echo "  Orchestration - Multi-phase dev workflow (orchestrator-mode skill)" >/dev/tty
        echo "  Bulletproof   - 12-stage verified dev workflow (bulletproof skill)" >/dev/tty
        echo "  Start new     - Plain ${AI_WRAPPER_AGENT_NAME} session" >/dev/tty
        echo "  Resume        - Resume a previous session" >/dev/tty
        echo "" >/dev/tty
        echo "Press Enter to return to menu..." >/dev/tty
        read -r </dev/tty
    fi
}

# Show main menu and echo selected action to stdout.
# Outputs one of: orchestrate, bulletproof, start, resume
show_main_menu() {
    while true; do
        show_header

        echo "Options:" >/dev/tty
        echo "  1) Start orchestration  (orchestrator-mode skill)" >/dev/tty
        echo "  2) Start bulletproof    (12-stage verified workflow)" >/dev/tty
        echo "  3) Start new conversation" >/dev/tty
        echo "  4) Resume from list" >/dev/tty
        echo "  h) Help" >/dev/tty
        echo "" >/dev/tty
        echo -n "Choose an option [1-4, h]: " >/dev/tty
        read -r choice </dev/tty

        case "${choice}" in
            1) echo "orchestrate"; return 0 ;;
            2) echo "bulletproof"; return 0 ;;
            3) echo "start"; return 0 ;;
            4) echo "resume"; return 0 ;;
            h|H|help) display_help ;;
            *)
                echo "Invalid choice. Press Enter to continue..." >/dev/tty
                read -r </dev/tty
                ;;
        esac
    done
}

# ===== ORCHESTRATION =====

build_orchestrator_prompt() {
    if [[ ! -f "${ORCHESTRATOR_PROMPT}" ]]; then
        wrapper_log "ERROR" "Orchestrator prompt not found: ${ORCHESTRATOR_PROMPT}"
        return 1
    fi
    cat "${ORCHESTRATOR_PROMPT}"
}

build_bulletproof_prompt() {
    if [[ ! -f "${BULLETPROOF_PROMPT}" ]]; then
        wrapper_log "ERROR" "Bulletproof prompt not found: ${BULLETPROOF_PROMPT}"
        return 1
    fi
    cat "${BULLETPROOF_PROMPT}"
}

# Run an orchestrated session. Uses WRAPPER_FLAGS and AGENT_FLAGS from the calling wrapper.
# AI_SYSTEM_PROMPT_FLAG must be set to the agent's system prompt injection flag.
run_orchestrated_session() {
    local mode="${1:-orchestrate}"

    local prompt_content
    if [[ "${mode}" == "bulletproof" ]]; then
        prompt_content=$(build_bulletproof_prompt) || { wrapper_log "ERROR" "Failed to build bulletproof prompt."; return 1; }
    else
        prompt_content=$(build_orchestrator_prompt) || { wrapper_log "ERROR" "Failed to build orchestrator prompt."; return 1; }
    fi
    if [[ -z "${prompt_content}" ]]; then
        wrapper_log "ERROR" "Prompt is empty."
        return 1
    fi

    if [[ -z "${AI_SYSTEM_PROMPT_FLAG}" ]]; then
        wrapper_log "WARN" "AI_SYSTEM_PROMPT_FLAG not set for ${AI_WRAPPER_AGENT_NAME}; starting plain session."
        run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}"
    else
        run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- \
            "${AGENT_FLAGS[@]}" "${AI_SYSTEM_PROMPT_FLAG}" "${prompt_content}"
    fi
}

# Run a plain agent session (start or resume). Uses AI_RESUME_ARGS if set.
run_agent_session() {
    local action="${1:-start}"
    local -a resume_args=("${AI_RESUME_ARGS[@]:-"--resume"}")

    case "${action}" in
        resume)
            run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}" "${resume_args[@]}"
            ;;
        start|*)
            run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}"
            ;;
    esac
}

# ===== SCRIPT GUARD =====

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script is meant to be sourced, not executed directly." >&2
    exit 1
fi
