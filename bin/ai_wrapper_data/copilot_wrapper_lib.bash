#!/bin/bash
# Copilot-specific wrapper library. Sourced by executable_copilot_wrapper.bash.
#
# The globals below are consumed by ai_wrapper_lib.bash, not this file.
# shellcheck disable=SC2034

AI_WRAPPER_AGENT_NAME="GitHub Copilot CLI"
AI_AGENT_COMMAND="copilot"
AI_WRAPPER_AGENT_ID="copilot"
AI_SYSTEM_PROMPT_FLAG=""
AI_RESUME_ARGS=(--resume)

WRAPPER_DATA_DIR="${WRAPPER_DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
WRAPPER_HELP="${WRAPPER_HELP:-${WRAPPER_DATA_DIR}/copilot-help.md}"

source "${WRAPPER_DATA_DIR}/ai_wrapper_lib.bash"

# Copilot CLI accepts inline prompts via --prompt.
_agent_system_prompt_args() {
    AI_SYSTEM_PROMPT_ARGS=(--prompt "${1}")
}

# The CLI's assisted-approval judge takes precedence over --allow-all-tools.
# Disable it explicitly, then pass the no-prompt workspace-trust setting
# through the sandbox's scrubbed environment using its explicit env allowlist.
_copilot_enable_unrestricted_mode() {
    _sandbox_pass_env_add COPILOT_ALLOW_ALL
    _sandbox_pass_env_add COPILOT_ASSISTED_APPROVAL
    export COPILOT_ALLOW_ALL=true
    export COPILOT_ASSISTED_APPROVAL=false
}

# Bind one Copilot config directory RW at its standard path. A symlinked
# path gets the shared config-symlink guard (target under $HOME, outside
# credential dirs) and is bound from its resolved source. Missing optional
# paths are skipped; ~/.copilot is created so the first run can initialize
# it. Prints an ERROR and returns 1 on refusal. Args: PATH [required]
_copilot_bind_config_path() {
    local p="${1}" required="${2:-}" src
    _wrapper_check_config_symlink "${p}" || return 1
    if [[ -e "${p}" && ! -d "${p}" ]]; then
        echo "ERROR: ${p} exists but is not a directory. Move or remove it before launching." >&2
        return 1
    fi
    if [[ ! -e "${p}" ]]; then
        [[ -n "${required}" ]] || return 0
        if [[ -L "${p}" ]] || ! mkdir -p "${p}"; then
            echo "ERROR: failed to create ${p}" >&2
            return 1
        fi
    fi
    if ! src="$(_realpath "${p}")" || [[ -z "${src}" ]]; then
        echo "ERROR: cannot resolve ${p}" >&2
        return 1
    fi
    _wrapper_add_bind "${src}" "${p}"
}

# Keep Copilot runtime state in its standard home paths. Returns 1 when any
# path is refused.
_copilot_bind_config_dirs() {
    _copilot_bind_config_path "${HOME}/.copilot" required || return 1
    _copilot_bind_config_path "${HOME}/.config/github-copilot" || return 1
    _copilot_bind_config_path "${HOME}/.local/share/copilot" || return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script is meant to be sourced, not executed directly." >&2
    exit 1
fi
