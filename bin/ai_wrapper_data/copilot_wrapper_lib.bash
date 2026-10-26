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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script is meant to be sourced, not executed directly." >&2
    exit 1
fi
