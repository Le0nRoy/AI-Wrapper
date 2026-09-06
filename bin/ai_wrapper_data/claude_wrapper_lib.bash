#!/usr/bin/env bash
# Claude-specific wrapper library. Sources ai_wrapper_lib.bash.
# Sourced by executable_claude_wrapper.bash — not executed directly.
#
# Note: AI_RESUME_ARGS is not set here because the shared lib's default
# (--resume) is already what the Claude CLI expects. Override here only if
# Claude's resume flag ever changes.

AI_WRAPPER_AGENT_NAME="Claude CLI"
AI_AGENT_COMMAND="claude"
AI_SYSTEM_PROMPT_FLAG="--append-system-prompt"

# Declared (empty) so the shared lib's `${AI_RESUME_ARGS[@]:---resume}` fallback
# triggers cleanly on bash 3.2 under `set -u`. The lib treats an empty array
# the same as unset and substitutes the `--resume` default.
AI_RESUME_ARGS=()

# pwd -P resolves symlinks so a symlinked install of this lib still finds its
# sibling data files (ai_wrapper_lib.bash, wrapper-help.md, etc.) next to the
# real file.
WRAPPER_DATA_DIR="${WRAPPER_DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
WRAPPER_HELP="${WRAPPER_DATA_DIR}/wrapper-help.md"

source "${WRAPPER_DATA_DIR}/ai_wrapper_lib.bash"

# ===== ACCOUNT SWITCHING =====
# Multi-account credential profiles (~/.claude-<name>/, ~/.claude-<name>.json)
# are exposed as a settings-catalog entry so they're selectable from the same
# menu as every other sandbox flag, shown in the header, and persisted
# per-workdir by the existing preset mechanism. "private" is the default
# account (today's unsuffixed ~/.claude) — CLAUDE_ACCOUNT=private and
# CLAUDE_ACCOUNT=<unset> are treated identically.
_AI_SETTINGS_LIST+=(
    "CLAUDE_ACCOUNT|str|private|info|Account profile|Which ~/.claude-<name>/ credential profile to use. 'private' = default ~/.claude. Type a profile name, or 'private' to reset.|account"
)

# The shared catalog's DEFAULT field is display-only for str/path entries —
# _setting_current_value() never substitutes it (str/path treats empty as
# meaningful, unlike bool), so an unset CLAUDE_ACCOUNT would render as
# "<unset>" in the settings table rather than "private" even though
# _bind_claude_account() (executable_claude_wrapper.bash) treats the two
# identically. Export the default explicitly here so the displayed state
# matches the resolved behavior; _preset_autoload overrides this with a
# saved value when one exists, same as any other exported default.
export CLAUDE_ACCOUNT="${CLAUDE_ACCOUNT:-private}"

# List available account profile names (directory-name suffixes of
# ~/.claude-<name>/), one per line, for the user to reference when typing
# a value at the Settings prompt. Not currently rendered inline in the
# catalog DETAIL text (that's static) — surfaced via `h`/Help instead;
# see wrapper-help.md.
_claude_list_account_profiles() {
    local dir name
    for dir in "${HOME}/.claude-"*/; do
        [[ -d "${dir}" ]] || continue
        name="${dir#"${HOME}/.claude-"}"
        name="${name%/}"
        [[ "${name}" =~ ^[a-zA-Z0-9_-]+$ ]] && printf '%s\n' "${name}"
    done
}
