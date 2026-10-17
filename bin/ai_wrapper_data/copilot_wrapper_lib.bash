#!/bin/bash
# Copilot-specific wrapper library. Sourced by executable_copilot_wrapper.bash.
#
# The globals below are consumed by ai_wrapper_lib.bash, not this file.
# shellcheck disable=SC2034

AI_WRAPPER_AGENT_NAME="GitHub Copilot CLI"
AI_AGENT_COMMAND="copilot"
AI_WRAPPER_AGENT_ID="copilot"
AI_SYSTEM_PROMPT_FLAG=""
AI_RESUME_ARGS=(--continue)

WRAPPER_DATA_DIR="${WRAPPER_DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
WRAPPER_HELP="${WRAPPER_HELP:-${WRAPPER_DATA_DIR}/copilot-help.md}"

source "${WRAPPER_DATA_DIR}/ai_wrapper_lib.bash"

# Copilot CLI accepts inline prompts via --prompt, which is the closest
# equivalent to the system-prompt injection in the other wrappers.
_agent_system_prompt_args() {
    AI_SYSTEM_PROMPT_ARGS=(--prompt "${1}")
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script is meant to be sourced, not executed directly." >&2
    exit 1
fi
