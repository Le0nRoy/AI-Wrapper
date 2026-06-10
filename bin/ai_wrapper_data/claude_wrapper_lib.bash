#!/bin/bash
# Claude-specific wrapper library. Sources ai_wrapper_lib.bash.
# Sourced by executable_claude_wrapper.bash — not executed directly.

AI_WRAPPER_AGENT_NAME="Claude CLI"
AI_AGENT_COMMAND="claude"
AI_SYSTEM_PROMPT_FLAG="--append-system-prompt"
AI_RESUME_ARGS=(--resume)

WRAPPER_DATA_DIR="${WRAPPER_DATA_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
WRAPPER_HELP="${WRAPPER_DATA_DIR}/wrapper-help.md"

source "${WRAPPER_DATA_DIR}/ai_wrapper_lib.bash"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script is meant to be sourced, not executed directly." >&2
    echo "Usage: source claude_wrapper_lib.bash" >&2
    exit 1
fi
