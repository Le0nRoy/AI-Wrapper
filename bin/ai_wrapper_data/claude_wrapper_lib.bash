#!/usr/bin/env bash
# Claude-specific wrapper library. Sources ai_wrapper_lib.bash.
# Sourced by executable_claude_wrapper.bash — not executed directly.
#
# Note: AI_RESUME_ARGS is not set here because the shared lib's default
# (--resume) is already what the Claude CLI expects. Override here only if
# Claude's resume flag ever changes.
#
# The globals below are consumed by ai_wrapper_lib.bash, not this file.
# shellcheck disable=SC2034

AI_WRAPPER_AGENT_NAME="Claude CLI"
AI_AGENT_COMMAND="claude"
AI_WRAPPER_AGENT_ID="claude"
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
    "CLAUDE_ACCOUNT|str|private|info|Account profile|Which ~/.claude-<name>/ credential profile to use. 'private' = default ~/.claude. Type a profile name, or 'private' to reset. Named profiles are Linux-only; macOS refuses them at launch. Use when: this session should run under another login, e.g. a work account kept in ~/.claude-work.|account"
)

# No source-time `export CLAUDE_ACCOUNT=private`: _preset_autoload treats a set
# variable as caller-set and would skip a saved account. The settings table
# shows "private" for unset via _setting_current_value's catalog default.


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

# ===== PERSISTENT CONTROLS (#48 / #87) =====
# Paths under the profile dir that every later Claude session loads:
# settings (incl. hooks and statusline commands), memory / prompt files,
# custom agents, slash commands, output styles, hooks, plugins and skills.
# _bind_claude_account keeps the ones present at launch read-only via
# _wrapper_protect_client_controls. Session state stays writable:
# ~/.claude.json (OAuth / account state, bound as its own file),
# .credentials.json, projects/ (transcripts), todos/, history, logs.
_CLAUDE_CLIENT_CONTROLS=(
    settings.json settings.local.json
    CLAUDE.md AGENTS.md RTK.md
    agents commands hooks output-styles plugins skills
)

# Resolve CLAUDE_ACCOUNT (from a persisted preset or a Settings-menu edit)
# to the credential dir/file to bind, and append the binds to
# WRAPPER_FLAGS. Must run AFTER _preset_autoload and any menu interaction
# — CLAUDE_ACCOUNT isn't authoritative until then. Called from both the
# interactive path (after show_main_menu) and the non-interactive path
# (after _preset_autoload, before dispatch) — see the bottom of
# executable_claude_wrapper.bash.
_bind_claude_account() {
    local account="${CLAUDE_ACCOUNT:-private}"
    [[ "${account}" == "private" ]] && account=""

    local claude_dir claude_json_src
    if [[ -n "${account}" ]]; then
        if [[ ! "${account}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "ERROR: Invalid CLAUDE_ACCOUNT '${account}': must contain only letters, digits, hyphens, underscores" >&2
            exit 1
        fi
        _wrapper_check_account_supported "${account}" "CLAUDE_ACCOUNT" || exit 1
        claude_dir="${HOME}/.claude-${account}"
        if [[ ! -d "${claude_dir}" ]]; then
            echo "ERROR: Account profile directory not found: ${claude_dir}" >&2
            echo "Available profiles: $(_claude_list_account_profiles | tr '\n' ' ')" >&2
            exit 1
        fi
        if [[ -f "${HOME}/.claude-${account}.json" ]]; then
            claude_json_src="${HOME}/.claude-${account}.json"
        else
            claude_json_src="${HOME}/.claude.json"
        fi
        AI_WRAPPER_AGENT_NAME="Claude CLI [${account}]"
    else
        claude_dir="${HOME}/.claude"
        claude_json_src="${HOME}/.claude.json"

        # WS3 / B-alpha: symlink-safety guard. Refuse if ~/.claude is a
        # symlink the shared guard rejects (dangling, outside $HOME, a broad
        # root or a credential location — `mkdir -p` would follow it and
        # the bind would grant RW on the target) or exists as a
        # non-directory (a stray file from a botched migration). Only
        # applies to the private (default) account — a named account's
        # directory must already exist as a directory (checked above).
        _wrapper_check_config_symlink "${claude_dir}" || exit 1
        if [[ -e "${claude_dir}" && ! -d "${claude_dir}" ]]; then
            echo "ERROR: ${claude_dir} exists but is not a directory. Move or remove it before launching." >&2
            exit 1
        fi

        # Ensure ~/.claude exists before binding: the universal wrapper
        # requires bind sources to exist, so a fresh machine (no prior
        # Claude run) would otherwise hard-fail here instead of letting
        # Claude initialize the directory itself.
        if ! mkdir -p "${claude_dir}"; then
            echo "ERROR: failed to create ${claude_dir}" >&2
            exit 1
        fi

        # Ensure ~/.claude.json exists before binding. Claude's atomic-write
        # pattern is `write .claude.json.tmp.<...> -> rename .claude.json`;
        # binding a nonexistent destination would leave that rename with
        # nothing to land on. If the path exists but isn't a regular file,
        # refuse rather than silently binding a misshapen path.
        # Check a symlinked ~/.claude.json BEFORE touch follows it.
        _wrapper_check_config_symlink "${claude_json_src}" || exit 1
        if [[ -e "${claude_json_src}" && ! -f "${claude_json_src}" ]]; then
            echo "ERROR: ${claude_json_src} exists but is not a regular file. Move or remove it before launching." >&2
            exit 1
        fi
        if ! touch "${claude_json_src}" 2>/dev/null; then
            if [[ ! -f "${claude_json_src}" ]]; then
                echo "ERROR: failed to create ${claude_json_src}; sandbox cannot bind a nonexistent file." >&2
                exit 1
            fi
            echo "WARN: could not update ${claude_json_src} mtime; continuing because the file exists." >&2
        fi
    fi

    # Shared symlink-target guard (ai_wrapper_lib.bash): refuses a
    # symlinked profile dir / .claude.json that is dangling or whose target
    # is outside $HOME, a broad root, or in/above a credential location.
    # Covers the named-account paths and their .json files.
    _wrapper_check_config_symlink "${claude_dir}" || exit 1
    _wrapper_check_config_symlink "${claude_json_src}" || exit 1

    # Bind the resolved paths, never a (checked) symlink unresolved. A
    # missing ~/.claude.json (named account without its own .json) stays
    # as-is; the sandbox skips a missing bind source with a warning.
    local claude_dir_src claude_json_bind_src="${claude_json_src}"
    if ! claude_dir_src="$(_realpath "${claude_dir}")" || [[ -z "${claude_dir_src}" ]]; then
        echo "ERROR: cannot resolve ${claude_dir}" >&2
        exit 1
    fi
    if [[ -e "${claude_json_src}" ]] && ! claude_json_bind_src="$(_realpath "${claude_json_src}")"; then
        echo "ERROR: cannot resolve ${claude_json_src}" >&2
        exit 1
    fi
    _wrapper_add_bind "${claude_dir_src}" "${HOME}/.claude"
    _wrapper_add_bind "${claude_json_bind_src}" "${HOME}/.claude.json"
    _wrapper_protect_client_controls "claude" "${claude_dir_src}" "${HOME}/.claude" \
        "${_CLAUDE_CLIENT_CONTROLS[@]}" || exit 1
}

# ===== CLAUDE CODE UI ENV PASSTHROUGH =====
# Claude Code reads its display settings from env vars (fullscreen
# renderer, mouse capture, alternate screen, wheel scroll speed). The Linux
# bwrap backend starts the client with --clearenv, so they never arrive
# unless named on the AI_SANDBOX_PASS_ENV allowlist. UI preferences only,
# never credentials. macOS needs nothing here: macos_sandbox_exec.bash
# already passes every CLAUDE_* name through.
_CLAUDE_UI_ENV_VARS=(
    CLAUDE_CODE_NO_FLICKER
    CLAUDE_CODE_DISABLE_MOUSE
    CLAUDE_CODE_DISABLE_MOUSE_CLICKS
    CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN
    CLAUDE_CODE_SCROLL_SPEED
)

# Add each _CLAUDE_UI_ENV_VARS name that is set (non-empty) in the caller's
# environment to AI_SANDBOX_PASS_ENV; unset names are left out. Call after
# _preset_autoload and _preset_autosave: AI_SANDBOX_PASS_ENV is a saved
# setting, so adding to it earlier would hide a saved list from autoload
# and persist these names into the workdir preset.
_claude_pass_ui_env() {
    [[ "${_wrapper_os}" == "Darwin" ]] && return 0
    local name
    for name in "${_CLAUDE_UI_ENV_VARS[@]}"; do
        [[ -n "${!name:-}" ]] && _sandbox_pass_env_add "${name}"
    done
    return 0
}
