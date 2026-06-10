#!/bin/bash
# Cursor-specific wrapper library. Sources ai_wrapper_lib.bash.
# Sourced by executable_cursor_agent_wrapper.bash — not executed directly.

AI_WRAPPER_AGENT_NAME="Cursor Agent"
AI_AGENT_COMMAND="cursor-agent"
# TODO: Set to the correct system prompt injection flag once verified.
# Common candidates: --instructions, --system-prompt
AI_SYSTEM_PROMPT_FLAG=""
AI_RESUME_ARGS=(--resume)

WRAPPER_DATA_DIR="${WRAPPER_DATA_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
WRAPPER_HELP="${WRAPPER_DATA_DIR}/cursor-help.md"

source "${WRAPPER_DATA_DIR}/ai_wrapper_lib.bash"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script is meant to be sourced, not executed directly." >&2
    exit 1
fi
