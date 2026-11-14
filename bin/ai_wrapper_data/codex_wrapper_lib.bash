#!/bin/bash
# Codex-specific wrapper library. Sources ai_wrapper_lib.bash.
# Sourced by executable_codex_wrapper.bash — not executed directly.
#
# The globals below are consumed by ai_wrapper_lib.bash, not this file.
# shellcheck disable=SC2034

AI_WRAPPER_AGENT_NAME="Codex CLI"
AI_AGENT_COMMAND="codex"
AI_WRAPPER_AGENT_ID="codex"
# Codex has no plain `--system-prompt <text>` flag; orchestration injects
# the prompt via `-c developer_instructions=<TOML string>` instead — see
# _agent_system_prompt_args below, which run_orchestrated_session prefers
# over this flag when defined.
AI_SYSTEM_PROMPT_FLAG=""
# `resume` is a subcommand: `codex resume [OPTIONS]`. AI_RESUME_ARGS_FIRST
# puts it ahead of AGENT_FLAGS so --dangerously-bypass-approvals-and-sandbox
# parses as a `resume` option (listed in `codex resume --help`).
AI_RESUME_ARGS=(resume)
AI_RESUME_ARGS_FIRST=1

WRAPPER_DATA_DIR="${WRAPPER_DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
WRAPPER_HELP="${WRAPPER_DATA_DIR}/codex-help.md"

source "${WRAPPER_DATA_DIR}/ai_wrapper_lib.bash"

# ===== ORCHESTRATION PROMPT INJECTION =====

# Replace every occurrence of $2 with $3 in the variable named $1.
# Deliberately not `${var//pat/rep}`: the replacement's quote and
# backslash handling differs across bash versions — 3.2 (macOS /bin/bash)
# keeps double quotes in a double-quoted replacement literally, 4.3+
# removes them, and 5.2's patsub_replacement turns an unquoted `\\` into
# `\`. Prefix/suffix removal with a quoted pattern is literal everywhere.
_toml_replace_all() {
    local rest="${!1}" out=""
    while [[ "${rest}" == *"${2}"* ]]; do
        out="${out}${rest%%"${2}"*}${3}"
        rest="${rest#*"${2}"}"
    done
    printf -v "${1}" '%s' "${out}${rest}"
}

# Encode $1 as a TOML basic string (double-quoted, with escapes) on stdout.
# codex parses the value of `-c key=value` as TOML and silently falls back
# to the raw string when parsing fails — relying on that fallback would
# make the prompt's meaning depend on whether it happens to be valid TOML,
# so always emit a well-formed basic string. Escapes per the TOML spec:
# backslash, double quote, the named controls (\b \t \n \f \r), and every
# other C0 control plus DEL as \uXXXX. Bash strings cannot contain NUL.
_toml_basic_string() {
    local s="${1}" bs='\' code ch esc
    _toml_replace_all s "${bs}" "${bs}${bs}"
    _toml_replace_all s '"' "${bs}\""
    _toml_replace_all s $'\b' "${bs}b"
    _toml_replace_all s $'\t' "${bs}t"
    _toml_replace_all s $'\n' "${bs}n"
    _toml_replace_all s $'\f' "${bs}f"
    _toml_replace_all s $'\r' "${bs}r"
    for code in 1 2 3 4 5 6 7 11 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 127; do
        printf -v ch "\\x$(printf '%02x' "${code}")"
        [[ "${s}" == *"${ch}"* ]] || continue
        printf -v esc '%su%04X' "${bs}" "${code}"
        _toml_replace_all s "${ch}" "${esc}"
    done
    printf '"%s"' "${s}"
}

# run_orchestrated_session hook (see ai_wrapper_lib.bash header): inject
# the orchestrator prompt as Codex developer instructions.
_agent_system_prompt_args() {
    local encoded
    encoded="$(_toml_basic_string "${1}")" || return 1
    AI_SYSTEM_PROMPT_ARGS=(-c "developer_instructions=${encoded}")
}

# ===== ACCOUNT SWITCHING =====
# Mirrors CLAUDE_ACCOUNT (claude_wrapper_lib.bash): ~/.codex-<name>/ is
# bound at ~/.codex inside the sandbox. "private" (or unset) = the default
# unsuffixed ~/.codex. Codex keeps auth.json and config.toml inside its
# home dir, so there is no separate top-level file to bind (unlike
# ~/.claude.json). Persisted per-workdir by the preset mechanism.
_AI_SETTINGS_LIST+=(
    "CODEX_ACCOUNT|str|private|info|Account profile|Which ~/.codex-<name>/ credential profile to use. 'private' = default ~/.codex. Type a profile name, or 'private' to reset. Named profiles are Linux-only; macOS refuses them at launch. Use when: this session should run under another login, e.g. a work account kept in ~/.codex-work.|account"
)

# No source-time `export CODEX_ACCOUNT=private`: _preset_autoload treats a set
# variable as caller-set and would skip a saved account. The settings table
# shows "private" for unset via _setting_current_value's catalog default.


# List available account profile names (suffixes of ~/.codex-<name>/),
# one per line.
_codex_list_account_profiles() {
    local dir name
    for dir in "${HOME}/.codex-"*/; do
        [[ -d "${dir}" ]] || continue
        name="${dir#"${HOME}/.codex-"}"
        name="${name%/}"
        [[ "${name}" =~ ^[a-zA-Z0-9_-]+$ ]] && printf '%s\n' "${name}"
    done
}

# ===== PERSISTENT CONTROLS (#48 / #87) =====
# Paths under the profile dir that every later Codex session loads:
# config.toml (model, MCP servers, notify commands, project trust),
# hooks, global instructions, exec-policy rules, custom prompts, agents,
# plugins and skills. _bind_codex_account keeps the ones present at launch
# read-only via _wrapper_protect_client_controls. Session state stays
# writable: auth.json, history.jsonl, sessions/, log/, cache.
_CODEX_CLIENT_CONTROLS=(
    config.toml config.json hooks.json
    AGENTS.md AGENTS.override.md
    agents hooks plugins prompts rules skills
)

# Resolve CODEX_ACCOUNT to the profile dir and append its bind (at
# ~/.codex) and the read-only persistent controls to WRAPPER_FLAGS. Must run AFTER _preset_autoload and the menu
# — CODEX_ACCOUNT isn't authoritative until then. Exits on invalid input,
# same contract as _bind_claude_account in executable_claude_wrapper.bash.
_bind_codex_account() {
    local account="${CODEX_ACCOUNT:-private}"
    [[ "${account}" == "private" ]] && account=""

    local codex_dir
    if [[ -n "${account}" ]]; then
        if [[ ! "${account}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "ERROR: Invalid CODEX_ACCOUNT '${account}': must contain only letters, digits, hyphens, underscores" >&2
            exit 1
        fi
        _wrapper_check_account_supported "${account}" "CODEX_ACCOUNT" || exit 1
        codex_dir="${HOME}/.codex-${account}"
        if [[ ! -d "${codex_dir}" ]]; then
            echo "ERROR: Account profile directory not found: ${codex_dir}" >&2
            echo "Available profiles: $(_codex_list_account_profiles | tr '\n' ' ')" >&2
            exit 1
        fi
        # A named profile dir that is a symlink gets the same target
        # check as the default dir below.
        _wrapper_check_config_symlink "${codex_dir}" || exit 1
        AI_WRAPPER_AGENT_NAME="Codex CLI [${account}]"
    else
        codex_dir="${HOME}/.codex"

        # Symlink-safety guard (same as ~/.claude): refuse a ~/.codex that
        # is a non-directory, or a symlink resolving outside $HOME or into
        # a credential dir — the mkdir/bind below would otherwise follow
        # it and grant RW on the symlink target's real location.
        if [[ -L "${codex_dir}" ]]; then
            _wrapper_check_config_symlink "${codex_dir}" || exit 1
        elif [[ -e "${codex_dir}" && ! -d "${codex_dir}" ]]; then
            echo "ERROR: ${codex_dir} exists but is not a directory or symlink. Move or remove it before launching." >&2
            exit 1
        fi

        # Bind sources must exist; create on a fresh machine so the first
        # codex run doesn't fail before the CLI can initialize it.
        if ! mkdir -p "${codex_dir}"; then
            echo "ERROR: failed to create ${codex_dir}" >&2
            exit 1
        fi
    fi

    # Bind the resolved path, never a (checked) symlink unresolved.
    local bind_src
    bind_src="$(_realpath "${codex_dir}")" || bind_src="${codex_dir}"
    _wrapper_add_bind "${bind_src}" "${HOME}/.codex"
    _wrapper_protect_client_controls "codex" "${bind_src}" "${HOME}/.codex" \
        "${_CODEX_CLIENT_CONTROLS[@]}" || exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script is meant to be sourced, not executed directly." >&2
    exit 1
fi
