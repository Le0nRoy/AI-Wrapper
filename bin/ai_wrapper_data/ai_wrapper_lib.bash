#!/usr/bin/env bash
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
#   WRAPPER_FLAGS          - Array of sandbox flags (--bind mounts, etc.)
#   AGENT_FLAGS            - Array of agent-specific CLI flags
#
# Optional variables:
#   WRAPPER_DATA_DIR       - Path to this directory (defaults to the directory containing this file)
#   WRAPPER_HELP           - Path to help file (defaults to wrapper-help.md in WRAPPER_DATA_DIR)
#   AI_SYSTEM_PROMPT_FLAG  - CLI flag for system prompt injection (e.g. "--append-system-prompt")
#                            If unset, orchestration mode starts a plain session with a warning.
#   AI_RESUME_ARGS         - Array of args for resume mode (default: --resume)

# pwd -P resolves symlinks so a symlinked install of this lib still finds its
# sibling data files (orchestrator-prompt.md, etc.) next to the real file.
WRAPPER_DATA_DIR="${WRAPPER_DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
WRAPPER_HELP="${WRAPPER_HELP:-${WRAPPER_DATA_DIR}/wrapper-help.md}"
ORCHESTRATOR_PROMPT="${WRAPPER_DATA_DIR}/orchestrator-prompt.md"

# ===== OS-AWARE BIND HELPERS =====
# bubblewrap (Linux) remaps paths: `--bind SRC DST` makes SRC appear at DST
# inside the sandbox — this is what lets a non-default account directory
# (e.g. ~/.claude-work) appear as ~/.claude to the Claude CLI running inside
# the sandbox. sandbox-exec (macOS) has no bind-mount capability; its
# `--bind` is a single-arg path-based ACL grant (see macos_sandbox_exec.bash
# header) — there is no remapping, so DST is dropped. Known consequence:
# path-remapping features (multi-account switching to a differently-named
# on-disk directory) only work as designed on the Linux backend today; on
# macOS every account maps to its own on-disk path rather than appearing as
# ~/.claude. This is a macOS-backend limitation (ai_wrapper_data/
# macos_sandbox_exec.bash, out of scope here), not a bug in this file.
#
# Shared across all three wrappers (Claude/Codex/Cursor) — every wrapper
# sources this file, so a single `uname -s` check here covers them all.
_wrapper_os="$(uname -s)"

_wrapper_add_bind() {
    local src="${1}" dst="${2:-${1}}"
    if [[ "${_wrapper_os}" == "Darwin" ]]; then
        WRAPPER_FLAGS+=(--bind "${src}")
    else
        WRAPPER_FLAGS+=(--bind "${src}" "${dst}")
    fi
}

_wrapper_add_ro_bind() {
    local src="${1}" dst="${2:-${1}}"
    if [[ "${_wrapper_os}" == "Darwin" ]]; then
        WRAPPER_FLAGS+=(--ro-bind "${src}")
    else
        WRAPPER_FLAGS+=(--ro-bind "${src}" "${dst}")
    fi
}

_wrapper_add_meta_bind() {
    # Metadata-only (stat, no read/write) binds exist to satisfy Seatbelt's
    # default-deny read fence while walking intermediate path components
    # (see macos_sandbox_exec.bash). bwrap's mount-namespace model has no
    # equivalent requirement — only explicitly bound paths are visible at
    # all, and path-walk stat() through WORKDIR's own parent chain is not
    # gated the way Seatbelt gates it — so this is a no-op on Linux.
    [[ "${_wrapper_os}" == "Darwin" ]] && WRAPPER_FLAGS+=(--meta-bind "${1}")
}

# ===== PORTABLE PATH-RESOLUTION HELPERS =====
# _realpath / _check_workdir_breadth normally live in
# ai_wrapper_data/macos_sandbox_exec.bash, but that file is only sourced
# lazily inside run_sandboxed_agent() when $(uname -s) == Darwin — it is
# NOT available here, before the menu, on any OS. Both helpers are
# OS-generic in their own implementation (realpath(1)/perl/pure-bash
# fallback chain; plain string comparisons), so they are duplicated here
# (structurally equivalent to macos_sandbox_exec.bash) rather than invented
# differently, to keep behavior identical to whatever the macOS backend does
# with the same inputs later in the run.
_realpath() {
    local p="${1}" out
    if command -v realpath >/dev/null 2>&1; then
        if out="$(realpath "${p}" 2>/dev/null)" && [[ -n "${out}" ]]; then
            [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: branch=realpath path=${p}"
            echo "${out}"
            return 0
        fi
    fi
    if command -v perl >/dev/null 2>&1; then
        if out="$(perl -MCwd=abs_path -e 'my $r = abs_path($ARGV[0]); print $r if defined $r' "${p}" 2>/dev/null)" && [[ -n "${out}" ]]; then
            [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: branch=perl-abs_path path=${p}"
            echo "${out}"
            return 0
        fi
    fi
    # Last-ditch: canonicalize via `cd … && pwd -P`. Works for directories
    # directly; for files, follow any final-component symlinks via readlink
    # (capped to a small depth to prevent loops) before resolving the parent
    # and re-attaching the basename so symlinks in the directory chain are
    # also resolved.
    local parent base resolved_parent
    if [[ -d "${p}" ]]; then
        if out="$( cd "${p}" 2>/dev/null && pwd -P )" && [[ -n "${out}" ]]; then
            [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: branch=cd-pwd-dir path=${p}"
            echo "${out}"
            return 0
        fi
    elif [[ -e "${p}" || -L "${p}" ]]; then
        local cur="${p}" target depth=0
        local -a seen=()
        local _s_i
        while [[ -L "${cur}" && ${depth} -lt 40 ]]; do
            seen+=("${cur}")
            target="$(readlink "${cur}" 2>/dev/null)" || break
            [[ -z "${target}" ]] && break
            if [[ "${target}" == /* ]]; then
                cur="${target}"
            else
                cur="$(dirname -- "${cur}")/${target}"
            fi
            depth=$((depth + 1))
            for (( _s_i = 0; _s_i < ${#seen[@]}; _s_i++ )); do
                if [[ "${seen[$_s_i]}" == "${cur}" ]]; then
                    [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: symlink cycle detected path=${p} depth=${depth}"
                    return 1
                fi
            done
        done
        if [[ -d "${cur}" ]]; then
            if out="$( cd "${cur}" 2>/dev/null && pwd -P )" && [[ -n "${out}" ]]; then
                [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: branch=cd-pwd-symlink-walk-dir path=${p} depth=${depth}"
                echo "${out}"
                return 0
            fi
        fi
        parent="$(dirname -- "${cur}")"
        base="$(basename -- "${cur}")"
        if resolved_parent="$( cd "${parent}" 2>/dev/null && pwd -P )" && [[ -n "${resolved_parent}" ]]; then
            [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: branch=cd-pwd-symlink-walk-file path=${p} depth=${depth}"
            echo "${resolved_parent%/}/${base}"
            return 0
        fi
    fi
    return 1
}

# WS3 / U-E: emit a one-line WARN and set $AI_SANDBOX_WORKDIR_WARNING when
# WORKDIR is a direct $HOME child outside the project-dir allowlist
# (Workspace/Projects/src/code/bin/work/dev/repos and lowercase variants).
# Args: TAG RESOLVED_WORKDIR RESOLVED_HOME
_check_workdir_breadth() {
    local tag="${1}" wd="${2}" home="${3}"
    unset AI_SANDBOX_WORKDIR_WARNING || true
    [[ -z "${home}" || -z "${wd}" ]] && return 0
    local wd_parent="${wd%/*}"
    [[ "${wd_parent}" != "${home}" ]] && return 0
    local wd_leaf="${wd##*/}"
    case "${wd_leaf}" in
        Workspace|Projects|src|code|bin|work|dev|repos|workspace|projects)
            return 0
            ;;
    esac
    echo_log "WARN" "[${tag}] WORKDIR=${wd} is a direct \$HOME child outside the project-dir allowlist (Workspace/Projects/src/code/bin/work/dev/repos). The write fence grants RW on every file under it. cd one level deeper if that's broader than you intend."
    export AI_SANDBOX_WORKDIR_WARNING="${wd}"
    return 0
}

# ===== SETTINGS CATALOG =====
# Centralised list of env vars that change wrapper runtime behaviour.
# Drives the startup banner table AND the interactive toggle sub-menu so
# the two views never drift. Adding a new tunable is a one-line change here.
#
# Format: NAME|TYPE|DEFAULT|SEVERITY|HEADLINE|DETAIL|CATEGORY|OS_SCOPE
#   TYPE     - bool (0/1), str (free text), path (free text, path-shaped)
#   DEFAULT  - value substituted when the var is unset/empty (bools only;
#              str/path treat empty as meaningful)
#   SEVERITY - info (no banner colour), yellow (scope widening), red
#              (credential / sandbox-defeating). Drives banner colour and
#              the in-table marker colour.
#   HEADLINE - short verb-led label shown on row 1 (user-facing; no env var name)
#   DETAIL   - supporting explanation shown on the indented row 2
#   CATEGORY - grouping key; one of debug, additional, sensitive,
#              credentials, networking. Entries with the same CATEGORY
#              render under a shared header in both the banner and
#              toggle views.
#   OS_SCOPE - optional 8th field: "darwin" (macOS-only, hidden on Linux),
#              "linux" (Linux-only, hidden on macOS), or empty/omitted
#              (shown on every OS — the default). Entries without a
#              trailing "|OS_SCOPE" parse with an empty 8th field via the
#              `read` splitting below, so existing 7-field rows need no
#              changes. Used for settings whose backend is only
#              implemented on one OS today (see _AI_SETTINGS_LIST filtering
#              right after this array literal).
# Per-OS text fragments for catalog entries that are shown on every OS but
# describe an OS-specific mechanic. Computed once here (from the _wrapper_os
# set above) rather than re-checking `uname` per entry. Entries that are
# ENTIRELY OS-specific (no backend at all on the other OS) use the OS_SCOPE
# 8th field instead — see AI_SANDBOX_PROFILE* and the darwin-only rows below.
if [[ "${_wrapper_os}" == "Darwin" ]]; then
    _ai_sensitive_workdir_extra=", ~/Library"
    _ai_gitlab_bind_note="RO-binds ~/Library/Application Support/glab-cli"
else
    _ai_sensitive_workdir_extra=""
    _ai_gitlab_bind_note="RO-binds the XDG glab-cli config paths (~/.config/glab-cli, ~/.local/share/glab-cli)"
fi

# Order here is the display order in both views; categories are
# arranged so the most frequently used (networking) sits closest to the
# input prompt at the bottom, and rarer ones (debug) are at the top.
_AI_SETTINGS_LIST=(
    # Debug
    "AI_SANDBOX_DRYRUN|bool|0|info|Dry run — print plan, don't launch|Shows what would run (argv, env, profile) and exits|debug|darwin"
    "AI_SANDBOX_DEBUG|bool|0|info|Show verbose internal logging|For troubleshooting the wrapper itself — path-resolution details|debug"

    # Additional settings (env vars, profiles)
    "AI_SANDBOX_PASS_ENV|str||red|Pass extra env vars by name|Comma-separated list of variable names to share (advanced)|additional"
    "AI_SANDBOX_PROFILE|path||red|Custom sandbox profile override|Path to a custom SBPL file. Default: ai_wrapper_data/claude_wrapper.sb. Set only if you have a custom restrictions file.|additional|darwin"
    "AI_SANDBOX_PROFILE_TRUST_ME|bool|0|red|Skip safety check on custom profile|Bypasses the (version 1) + (deny default) validation. Set only if your profile intentionally relaxes the sandbox.|additional|darwin"

    # Sensitive directories
    "AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR|bool|0|red|Allow launch from sensitive dirs|Permits launching from \$HOME itself, a dotfile dir directly under \$HOME${_ai_sensitive_workdir_extra}, or a top-level system directory — the write fence then grants RW there, which likely exposes credentials|sensitive"
    "AI_SANDBOX_ALLOW_RO_HOMEDIR|bool|0|yellow|Share home directory (read-only)|Agent can read everything in \$HOME except credentials|sensitive|darwin"

    # Credentials
    "AI_SANDBOX_ALLOW_RO_CREDENTIALS|bool|0|red|Let agent read residual credential files|Includes ~/.config/gcloud, ~/.gnupg, ~/.netrc, ~/.npmrc, ~/.pypirc. ~/.ssh, ~/.aws, ~/.kube, ~/.docker are gated by their matching PASS_* setting instead.|credentials"
    "AI_SANDBOX_PASS_SSH_AGENT|bool|0|red|Share SSH agent + ~/.ssh|Passes SSH_AUTH_SOCK and RO-grants ~/.ssh so agent reads private key files and known_hosts directly|credentials"
    "AI_SANDBOX_PASS_KUBE|bool|0|red|Share Kubernetes context + ~/.kube|Passes KUBECONFIG / KUBE_EDITOR and RO-grants ~/.kube; agent reads cluster certs/tokens and can deploy to your clusters|credentials"
    "AI_SANDBOX_PASS_AWS|bool|0|red|Share AWS credentials + ~/.aws|Passes all AWS_* env vars and RO-grants ~/.aws — agent has full AWS account access|credentials"
    "AI_SANDBOX_PASS_GH|bool|0|red|Share GitHub token|Passes GITHUB_TOKEN / GH_TOKEN; agent can push to your repos|credentials"
    "AI_SANDBOX_PASS_GITLAB|bool|0|red|Share GitLab token + glab config|Passes GITLAB_TOKEN / CI_JOB_TOKEN env vars AND ${_ai_gitlab_bind_note} so glab reads its on-disk token. Agent can push to your repos.|credentials"
    "AI_SANDBOX_PASS_OPENAI|bool|0|red|Share OpenAI credentials|Passes all OPENAI_* env vars (advanced)|credentials"

    # Networking (localhost, local docker)
    "AI_SANDBOX_BLOCK_LOCALHOST|bool|0|info|Block localhost network access|Denies network access to services running on your own machine|networking|darwin"
    "AI_SANDBOX_ALLOW_DOCKER|bool|0|red|Mount Docker / Colima socket|RW on /var/run/docker.sock, ~/.colima, ~/.docker. With the daemon running this is a full sandbox escape: agent can launch privileged containers and obtain host root. Off by default — opt in only when the session needs docker.|networking"
    "AI_SANDBOX_PASS_DOCKER|bool|0|red|Share Docker client env vars + ~/.docker|Passes DOCKER_HOST, DOCKER_CONFIG, DOCKER_CERT_PATH, DOCKER_BUILDKIT and RO-grants ~/.docker (registry auth tokens). Pair with 'Mount Docker / Colima socket' to actually talk to the daemon.|networking"
)
unset _ai_sensitive_workdir_extra _ai_gitlab_bind_note

# OS-scope filtering: drop catalog rows whose trailing OS_SCOPE field
# doesn't match the current OS, so a setting with no backend on this OS
# (e.g. AI_SANDBOX_BLOCK_LOCALHOST / AI_SANDBOX_ALLOW_RO_HOMEDIR, macOS-only
# today) is hidden from the menu entirely rather than shown-but-nonfunctional.
# Runs once at source-time, before any function iterates _AI_SETTINGS_LIST
# and before agent-specific libs (e.g. claude_wrapper_lib.bash) `+=` onto it.
# `IFS='|' read -r ... <<<"${entry}"` naturally yields an empty 8th field
# for 7-field rows, so existing rows need no trailing "|" added.
_ai_settings_os="$(uname -s)"
_ai_settings_filtered=()
for _ai_settings_entry in "${_AI_SETTINGS_LIST[@]}"; do
    IFS='|' read -r _ai_n _ai_t _ai_d _ai_sev _ai_hl _ai_det _ai_cat _ai_scope <<<"${_ai_settings_entry}"
    case "${_ai_scope}" in
        darwin) [[ "${_ai_settings_os}" == "Darwin" ]] && _ai_settings_filtered+=("${_ai_settings_entry}") ;;
        linux)  [[ "${_ai_settings_os}" == "Linux"  ]] && _ai_settings_filtered+=("${_ai_settings_entry}") ;;
        *)      _ai_settings_filtered+=("${_ai_settings_entry}") ;;
    esac
done
_AI_SETTINGS_LIST=("${_ai_settings_filtered[@]}")
unset _ai_settings_os _ai_settings_filtered _ai_settings_entry _ai_scope
unset _ai_n _ai_t _ai_d _ai_sev _ai_hl _ai_det _ai_cat

# Bump only when the load logic needs version-conditional handling.
# Today: written into the preset file header for forward-compat
# debugging; not consulted on load (older presets load with a WARN
# on unrecognised keys, not a hard error).
_AI_WRAPPER_PRESET_FORMAT_VERSION="2026-05-28"

# Parse one catalog entry into globals: _set_name _set_type _set_default
# _set_severity _set_headline _set_detail _set_category _set_os_scope.
# Globals because bash 3.2 lacks namerefs and returning an 8-tuple via
# stdout would force the caller to split it again. _set_os_scope is the
# optional 8th field — a 7-field entry (no trailing "|OS_SCOPE") yields an
# empty string here, same backward-compatible contract as the filtering
# step above.
_parse_setting_entry() {
    local entry="${1}"
    _set_name="${entry%%|*}"; entry="${entry#*|}"
    _set_type="${entry%%|*}"; entry="${entry#*|}"
    _set_default="${entry%%|*}"; entry="${entry#*|}"
    _set_severity="${entry%%|*}"; entry="${entry#*|}"
    _set_headline="${entry%%|*}"; entry="${entry#*|}"
    _set_detail="${entry%%|*}"; entry="${entry#*|}"
    _set_category="${entry%%|*}"
    if [[ "${entry}" == *"|"* ]]; then
        entry="${entry#*|}"
        _set_os_scope="${entry}"
    else
        _set_os_scope=""
    fi
}

# Map a category key from the catalog to its user-facing label. Unknown
# keys round-trip unchanged so a typo in the catalog is visible rather
# than silently swallowed.
_category_label() {
    case "${1}" in
        debug)        printf 'Debug' ;;
        account)      printf 'Account' ;;
        additional)   printf 'Additional settings' ;;
        sensitive)    printf 'Sensitive directories' ;;
        credentials)  printf 'Credentials' ;;
        networking)   printf 'Networking' ;;
        *)            printf '%s' "${1}" ;;
    esac
}

# Category headers all share one hue (bold dark blue). Per-row colour
# now encodes state (green=disabled, red=enabled), so giving each
# category a distinct colour too would over-saturate the palette. The
# helper still takes a category key for forward-compatibility / future
# differentiation.
_category_color() {
    printf '\033[1;34m'
}

# Pick the row colour from the setting's current state, not its
# severity. Green = currently inactive (bool=0 or str/path empty);
# red = currently active. Applied to the headline + dotted leader +
# state line in the banner and to the matching "N) [ ] ..." line in
# the toggle sub-menu.
_setting_state_color() {
    local cur="${1}"
    if [[ -n "${cur}" && "${cur}" != "0" ]]; then
        printf '\033[1;31m'   # red — enabled
    else
        printf '\033[1;32m'   # green — disabled
    fi
}

# Echo the current value of a setting (after default-substitution). For
# bools, anything other than "1" is normalised to "0" — matching how the
# wrapper itself interprets these vars elsewhere.
_setting_current_value() {
    local name="${1}" type="${2}" default="${3}" cur
    cur="${!name:-}"
    case "${type}" in
        bool)
            [[ -z "${cur}" ]] && cur="${default}"
            [[ "${cur}" == "1" ]] || cur="0"
            ;;
        str|path)
            # No default substitution for non-bool (empty is meaningful).
            ;;
    esac
    printf '%s' "${cur}"
}

# Render the settings table (used by show_header and toggle_settings_menu).
# Output goes to /dev/tty so show_main_menu's $() capture stays clean.
# Colour is only applied when (a) the setting is non-default AND (b) its
# severity is yellow/red. Default-state rows render uncoloured.
#
# First arg: mode — "compact" or "full".
#   compact — skip rows whose current value equals the catalog default; if
#             every row is filtered out, print a one-line "All settings at
#             default" hint so the screen doesn't look empty. Category
#             headers are suppressed when no row under them survives.
#   full    — render every row (used by toggle_settings_menu's full view).
#
# Layout B (two rows per entry):
#   Row 1: 2-sp indent + headline + dotted leader + state (≈78 col wide).
#   Row 2: 4-sp indent + "↳ " + detail, soft-wrapped at ~74 cols with
#          continuations indented 6 sp to align under the arrow.
# The env var name is intentionally absent from this view — it appears
# only at the value-edit prompt in toggle_settings_menu.
_render_settings_table() {
    local mode="${1:-full}"
    local entry cur reset state line wrapped first
    local last_category=""
    local headline_width=50 total_width=78
    local rendered_any=0
    reset='\033[0m'
    echo "Current settings:" >/dev/tty
    for entry in "${_AI_SETTINGS_LIST[@]}"; do
        _parse_setting_entry "${entry}"
        cur="$(_setting_current_value "${_set_name}" "${_set_type}" "${_set_default}")"
        # In compact mode, skip rows whose current value matches the
        # catalog default. For bools _setting_current_value normalises
        # to "0"/"1" and the default is "0"; for str/path the default
        # is empty in the catalog and an unset/empty current value is
        # treated as default. A direct string compare covers both cases.
        if [[ "${mode}" == "compact" && "${cur}" == "${_set_default}" ]]; then
            continue
        fi
        if [[ "${_set_category}" != "${last_category}" ]]; then
            echo "" >/dev/tty
            printf '%b%s%b\n' "$(_category_color "${_set_category}")" "$(_category_label "${_set_category}")" "${reset}" >/dev/tty
            last_category="${_set_category}"
        fi
        case "${_set_type}" in
            bool)
                if [[ "${cur}" == "1" ]]; then state="[x]"; else state="[ ]"; fi
                ;;
            str|path)
                if [[ -n "${cur}" ]]; then state="= ${cur}"; else state="= <unset>"; fi
                ;;
        esac
        # Row colour: green if currently disabled, red if currently
        # enabled. Severity (red/yellow per knob) is no longer used —
        # the active/inactive split is the visual encoding.
        local row_color
        row_color="$(_setting_state_color "${cur}")"
        # Row 1: headline + dotted leader + state. If the headline is
        # wider than headline_width, fall back to "<headline> <state>"
        # with a single space — no leader, no truncation.
        local hl_len=${#_set_headline} st_len=${#state} pad_count dots
        if (( hl_len < headline_width )); then
            pad_count=$(( total_width - hl_len - st_len - 2 - 1 ))
            (( pad_count < 3 )) && pad_count=3
            dots=""
            local _i
            for (( _i=0; _i<pad_count; _i++ )); do dots+="."; done
            line="  ${_set_headline} ${dots} ${state}"
        else
            line="  ${_set_headline} ${state}"
        fi
        printf '%b%s%b\n' "${row_color}" "${line}" "${reset}" >/dev/tty
        # Row 2: detail, soft-wrapped. First wrapped line gets the arrow
        # prefix; continuations align under the text after the arrow.
        # Detail text stays uncoloured so the colour-coding signal is
        # concentrated on the headline/state row.
        wrapped="$(printf '%s\n' "${_set_detail}" | fold -s -w 74)"
        first=1
        while IFS= read -r dline; do
            if (( first == 1 )); then
                printf '    ↳ %s\n' "${dline}" >/dev/tty
                first=0
            else
                printf '      %s\n' "${dline}" >/dev/tty
            fi
        done <<<"${wrapped}"
        rendered_any=1
    done
    # Compact mode with zero surviving rows: leave a one-line marker so
    # the menu doesn't look empty / broken. Full mode never hits this
    # branch — the catalog always has entries.
    if [[ "${mode}" == "compact" ]] && (( rendered_any == 0 )); then
        echo "  All settings at default. Press 's' to change." >/dev/tty
    fi
    echo "" >/dev/tty
}

# ----- Per-workdir auto-persist preset helpers -----
#
# Settings are automatically saved to a per-workdir file under
# $XDG_CONFIG_HOME/ai-wrapper/last-preset/<hash>.env where hash is
# the first 12 hex chars of shasum -a 256 over the resolved workdir
# path. The file header carries a human-readable "# workdir: <path>"
# comment so users can grep to identify files.
#
# Three public functions:
#   _preset_autosave_path  — compute (but do not create) the file path
#   _preset_autosave       — write every catalog key verbatim
#   _preset_autoload       — apply saved settings (no-op silently if no file)
#   _preset_clear          — rm -f the file + unset AUTOLOADED_FROM

# Compute the path to the per-workdir preset file. Uses resolved CWD
# as the identity so symlinked worktrees resolve to the same file as
# their physical path. Does NOT create any directories.
_preset_autosave_path() {
    local workdir hash dir
    workdir="$(pwd -P)"
    # shasum -a 256 outputs "<hex>  -"; take the first 12 hex chars.
    hash="$(printf '%s' "${workdir}" | shasum -a 256 | cut -c1-12)"
    dir="${XDG_CONFIG_HOME:-${HOME}/.config}/ai-wrapper/last-preset"
    printf '%s/%s.env' "${dir}" "${hash}"
}

# Write every catalog key to the per-workdir preset file. Saves ALL
# keys verbatim (including bool=0 and empty str/path) so a user who
# explicitly disabled a previously-enabled setting sees that persist.
# Uses temp-rename to avoid partial-write corruption.
_preset_autosave() {
    local path dir entry cur
    path="$(_preset_autosave_path)"
    dir="$(dirname "${path}")"

    if ! mkdir -p "${dir}" 2>/dev/null; then
        echo "WARN: _preset_autosave: could not create ${dir}" >/dev/tty
        return 1
    fi

    local tmp="${path}.tmp.$$"
    {
        printf '# ai-wrapper auto-preset\n'
        printf '# workdir: %s\n' "$(pwd -P)"
        printf '# saved: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf '# wrapper-version: %s\n' "${_AI_WRAPPER_PRESET_FORMAT_VERSION}"
        for entry in "${_AI_SETTINGS_LIST[@]}"; do
            _parse_setting_entry "${entry}"
            cur="$(_setting_current_value "${_set_name}" "${_set_type}" "${_set_default}")"
            printf '%s=%s\n' "${_set_name}" "${cur}"
        done
    } > "${tmp}" 2>/dev/null || {
        rm -f "${tmp}" 2>/dev/null
        echo "WARN: _preset_autosave: failed to write ${tmp}" >/dev/tty
        return 1
    }

    if ! mv -f "${tmp}" "${path}" 2>/dev/null; then
        rm -f "${tmp}" 2>/dev/null
        echo "WARN: _preset_autosave: failed to rename ${tmp} -> ${path}" >/dev/tty
        return 1
    fi
    chmod 0644 "${path}" 2>/dev/null || true
    return 0
}

# Apply the per-workdir preset to the current shell. Silent no-op when
# no file exists (first run). WARN + skip on unknown keys or invalid
# values — never aborts on data errors. Sets
# AI_WRAPPER_PRESET_AUTOLOADED_FROM=<path> when >=1 setting was applied
# so show_header can render the dim "restored from" banner line.
_preset_autoload() {
    local path entry line key val catalog_type applied=0
    path="$(_preset_autosave_path)"
    # First run: no file yet — silent no-op.
    [[ -f "${path}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip blank lines and comments.
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        # Must contain '='.
        if [[ "${line}" != *=* ]]; then
            echo "  WARN: _preset_autoload: skipping malformed line: ${line}" >/dev/tty
            continue
        fi
        key="${line%%=*}"
        val="${line#*=}"
        # Validate key format.
        if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "  WARN: _preset_autoload: invalid key name: ${key}" >/dev/tty
            continue
        fi
        # Reject keys not in the catalog — a corrupt file must not set
        # arbitrary env vars.
        catalog_type=""
        for entry in "${_AI_SETTINGS_LIST[@]}"; do
            _parse_setting_entry "${entry}"
            if [[ "${_set_name}" == "${key}" ]]; then
                catalog_type="${_set_type}"
                break
            fi
        done
        if [[ -z "${catalog_type}" ]]; then
            echo "  WARN: _preset_autoload: unknown setting: ${key}" >/dev/tty
            continue
        fi
        # Validate value against type.
        case "${catalog_type}" in
            bool)
                if [[ "${val}" != "0" && "${val}" != "1" ]]; then
                    echo "  WARN: _preset_autoload: ${key}: expected 0 or 1, got '${val}'" >/dev/tty
                    continue
                fi
                ;;
            str|path)
                # No further validation — accept-any-string contract.
                ;;
        esac
        export "${key}=${val}"
        applied=$((applied + 1))
    done < "${path}"
    # Only signal "settings were restored" when at least one setting
    # applied. If the file exists but all lines were unknown/bad, the
    # banner would mislead the user into thinking settings are active.
    if (( applied > 0 )); then
        export AI_WRAPPER_PRESET_AUTOLOADED_FROM="${path}"
    fi
    return 0
}

# Remove the per-workdir preset file and clear the AUTOLOADED_FROM
# marker. No-op (return 0) when the file does not exist.
_preset_clear() {
    local path
    path="$(_preset_autosave_path)"
    rm -f "${path}" 2>/dev/null || true
    unset AI_WRAPPER_PRESET_AUTOLOADED_FROM
    return 0
}

# Render the dim "restored from <path>" banner line. Called by
# show_header iff AI_WRAPPER_PRESET_AUTOLOADED_FROM is set. Extracted
# into its own function so integration tests can call it directly
# without invoking the full show_header (which clears the screen, etc.).
_render_preset_banner_line() {
    [[ -n "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}" ]] || return 0
    local reset='\033[0m' dim='\033[2m'
    printf '%b(restored from %s)%b\n' "${dim}" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM}" "${reset}" >/dev/tty
}

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
    # Unified settings table replaces the per-var banner stanzas: the
    # catalog drives both this view and the interactive sub-menu, so the
    # two never drift. Severity colouring (yellow/red) is applied per-row
    # only when the setting is non-default. "compact" mode hides default-
    # state rows so the header stays short as the catalog grows; the full
    # table is available inside the s) Settings sub-menu.
    _render_settings_table compact
    # Dim "restored from <path>" line when auto-preset was applied.
    # Rendered before the workdir warning so the warning always sits
    # immediately above the menu options.
    _render_preset_banner_line
    # WS3 / U-E: yellow warn when WORKDIR is a direct $HOME child not on
    # the project-dir allowlist. The universal wrapper exports
    # AI_SANDBOX_WORKDIR_WARNING with the resolved WORKDIR path when the
    # heuristic fires. This banner is dynamic (carries the resolved path)
    # so it stays outside the catalog table.
    if [[ -n "${AI_SANDBOX_WORKDIR_WARNING:-}" ]]; then
        printf '\033[1;33mWARNING: WORKDIR=%s grants RW on every file under it. cd one level deeper if that is broader than you intend.\033[0m\n' "${AI_SANDBOX_WORKDIR_WARNING}" >/dev/tty
        echo "" >/dev/tty
    fi
}

# Streams a markdown help file to stdout, dropping blocks wrapped in
#   <!-- os:darwin --> ... <!-- os:end -->
#   <!-- os:linux -->  ... <!-- os:end -->
# whose OS doesn't match _wrapper_os. Lines outside any such block pass
# through unchanged; the marker lines themselves are always stripped. Lets
# one help file stay the single source for both platforms instead of
# duplicating the shared sections, same motivation as the settings
# catalog's OS_SCOPE field above.
_render_os_conditional_doc() {
    local os_want
    case "${_wrapper_os}" in
        Darwin) os_want="darwin" ;;
        Linux)  os_want="linux" ;;
        *)      os_want="" ;;
    esac
    awk -v os="${os_want}" '
        BEGIN                        { show=1 }
        /^<!-- os:end -->$/          { show=1; next }
        /^<!-- os:[^ ]+ -->$/        { show=($0 == "<!-- os:" os " -->"); next }
        show                         { print }
    ' "${1}"
}

display_help() {
    show_header
    if [[ -f "${WRAPPER_HELP}" ]]; then
        if command -v less &>/dev/null; then
            # -F: quit if content fits one screen; -X: don't clear the screen on exit.
            # Process substitution (not a pipe) so less still gets a file-like
            # input while its own stdin stays free for </dev/tty keypresses.
            less -FX <(_render_os_conditional_doc "${WRAPPER_HELP}") </dev/tty >/dev/tty
        else
            _render_os_conditional_doc "${WRAPPER_HELP}" >/dev/tty
        fi
    else
        echo "Wrapper for ${AI_WRAPPER_AGENT_NAME}" >/dev/tty
        echo "" >/dev/tty
        echo "Options:" >/dev/tty
        echo "  Orchestration - Multi-phase dev workflow (orchestrator-mode skill)" >/dev/tty
        echo "  Start new     - Plain ${AI_WRAPPER_AGENT_NAME} session" >/dev/tty
        echo "  Resume        - Resume a previous session" >/dev/tty
        echo "" >/dev/tty
        echo "Press Enter to return to menu..." >/dev/tty
        read -r </dev/tty
    fi
}

# Show the main menu and set $WRAPPER_MENU_CHOICE to the chosen action.
# Sets one of: orchestrate, start, resume.
#
# IMPORTANT: this function intentionally does NOT echo to stdout. Callers must
# invoke it directly (not via `$(show_main_menu)`) and read $WRAPPER_MENU_CHOICE
# afterwards. The reason: `$()` runs the whole menu loop in a subshell, which
# means any `export` made by toggle_settings_menu inside that loop dies when
# the subshell exits — settings toggled via the s) sub-menu would never reach
# run_sandboxed_agent. Returning the choice via a global var keeps the menu
# in the parent shell so exports propagate.
show_main_menu() {
    WRAPPER_MENU_CHOICE=""
    while true; do
        show_header

        echo "Options:" >/dev/tty
        echo "  1) Start orchestration  (orchestrator-mode skill)" >/dev/tty
        echo "  2) Start new conversation" >/dev/tty
        echo "  3) Resume from list" >/dev/tty
        echo "  s) Settings (toggle sandbox flags)" >/dev/tty
        echo "  c) Clear saved settings for this workdir" >/dev/tty
        echo "  h) Help" >/dev/tty
        echo "" >/dev/tty
        echo -n "Choose an option [1-3, s, c, h]: " >/dev/tty
        # `read` returns non-zero on EOF (e.g. /dev/tty unexpectedly closed,
        # or in a test harness where stdin is exhausted). Without this guard
        # the case-default branch would re-loop, re-render the menu, re-read
        # EOF, and spin forever. Treat any read failure as "abort the menu".
        if ! read -r choice </dev/tty; then
            WRAPPER_MENU_CHOICE=""
            return 1
        fi

        case "${choice}" in
            1) WRAPPER_MENU_CHOICE="orchestrate"; return 0 ;;
            2) WRAPPER_MENU_CHOICE="start"; return 0 ;;
            3) WRAPPER_MENU_CHOICE="resume"; return 0 ;;
            s|S|settings) toggle_settings_menu ;;
            c|C|clear)
                # Clear the auto-saved preset for this workdir and
                # re-render the menu so the "restored from" banner
                # disappears immediately. No confirmation — the user
                # can re-save by simply returning to the menu (autosave
                # fires before dispatch) or by editing Settings.
                _preset_clear
                ;;
            h|H|help) display_help ;;
            *)
                echo "Invalid choice. Press Enter to continue..." >/dev/tty
                read -r </dev/tty || return 1
                ;;
        esac
    done
}

# Interactive settings editor. Loops until the user picks "back".
# Toggles bools, prompts for str/path values; empty input on str/path
# unsets the var. All mutations use `export` so they reach
# run_sandboxed_agent later in the same shell.
toggle_settings_menu() {
    while true; do
        show_header

        echo "Settings - toggle/edit:" >/dev/tty
        local i=1 entry cur checkbox display wrapped first dline reset
        local last_category=""
        reset='\033[0m'
        for entry in "${_AI_SETTINGS_LIST[@]}"; do
            _parse_setting_entry "${entry}"
            if [[ "${_set_category}" != "${last_category}" ]]; then
                echo "" >/dev/tty
                printf '%b%s%b\n' "$(_category_color "${_set_category}")" "$(_category_label "${_set_category}")" "${reset}" >/dev/tty
                last_category="${_set_category}"
            fi
            cur="$(_setting_current_value "${_set_name}" "${_set_type}" "${_set_default}")"
            # Row colour mirrors the banner: green when disabled, red
            # when enabled. The active/inactive split is the visual
            # encoding — categories use one shared hue (above) so they
            # read as section labels, not state.
            local row_color row_line
            row_color="$(_setting_state_color "${cur}")"
            case "${_set_type}" in
                bool)
                    if [[ "${cur}" == "1" ]]; then checkbox="[x]"; else checkbox="[ ]"; fi
                    row_line="$(printf '%2d) %s %s' "${i}" "${checkbox}" "${_set_headline}")"
                    ;;
                *)
                    display="${cur:-<unset>}"
                    row_line="$(printf '%2d) %s = %s' "${i}" "${_set_headline}" "${display}")"
                    ;;
            esac
            printf '%b%s%b\n' "${row_color}" "${row_line}" "${reset}" >/dev/tty
            # Row 2: soft-wrapped detail, arrow on first line, aligned
            # continuations on subsequent lines (matches banner table).
            # Detail text stays uncoloured.
            wrapped="$(printf '%s\n' "${_set_detail}" | fold -s -w 74)"
            first=1
            while IFS= read -r dline; do
                if (( first == 1 )); then
                    printf '        ↳ %s\n' "${dline}" >/dev/tty
                    first=0
                else
                    printf '          %s\n' "${dline}" >/dev/tty
                fi
            done <<<"${wrapped}"
            i=$((i + 1))
        done

        printf '\nChoose setting [1-%d, comma-separated for multi, b=back]: ' "${#_AI_SETTINGS_LIST[@]}" >/dev/tty
        local choice
        # Treat EOF on /dev/tty as "back" (matches the empty-input branch
        # below). Without this, a closed-tty / exhausted-stdin condition
        # would re-loop forever — same hazard as in show_main_menu.
        if ! read -r choice </dev/tty; then
            return 0
        fi
        case "${choice}" in
            ""|b|B|back) return 0 ;;
            *)
                # Tokenise on comma so "1,4,7" toggles three settings in
                # one pass. Whitespace around tokens is ignored; each
                # token must be a positive integer within range. A single
                # bad token aborts the whole batch — silently skipping
                # would mask typos in larger selections.
                local -a _picks_raw=() picks=()
                local tok ok=1
                IFS=',' read -r -a _picks_raw <<<"${choice}"
                for tok in "${_picks_raw[@]}"; do
                    tok="${tok#"${tok%%[![:space:]]*}"}"
                    tok="${tok%"${tok##*[![:space:]]}"}"
                    [[ -z "${tok}" ]] && continue
                    if ! [[ "${tok}" =~ ^[0-9]+$ ]] \
                       || (( tok < 1 || tok > ${#_AI_SETTINGS_LIST[@]} )); then
                        echo "Invalid choice: '${tok}'. Press Enter to continue..." >/dev/tty
                        read -r </dev/tty || return 0
                        ok=0
                        break
                    fi
                    picks+=("${tok}")
                done
                if (( ok == 0 )) || (( ${#picks[@]} == 0 )); then
                    continue
                fi
                for tok in "${picks[@]}"; do
                    _parse_setting_entry "${_AI_SETTINGS_LIST[$((tok - 1))]}"
                    cur="$(_setting_current_value "${_set_name}" "${_set_type}" "${_set_default}")"
                    case "${_set_type}" in
                        bool)
                            if [[ "${cur}" == "1" ]]; then
                                export "${_set_name}"="0"
                            else
                                export "${_set_name}"="1"
                            fi
                            ;;
                        str|path)
                            printf 'New value for %s (empty to unset): ' "${_set_name}" >/dev/tty
                            local newval
                            # EOF here is treated the same as an empty input
                            # (unset the var). Matches the "empty to unset"
                            # contract printed to the user.
                            read -r newval </dev/tty || newval=""
                            if [[ -z "${newval}" ]]; then
                                unset "${_set_name}"
                            else
                                export "${_set_name}"="${newval}"
                            fi
                            ;;
                    esac
                done
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

# Run an orchestrated session. Uses WRAPPER_FLAGS and AGENT_FLAGS from the calling wrapper.
# AI_SYSTEM_PROMPT_FLAG must be set to the agent's system prompt injection flag.
run_orchestrated_session() {
    local prompt_content
    prompt_content=$(build_orchestrator_prompt) || { wrapper_log "ERROR" "Failed to build orchestrator prompt."; return 1; }
    if [[ -z "${prompt_content}" ]]; then
        wrapper_log "ERROR" "Prompt is empty."
        return 1
    fi

    if [[ -z "${AI_SYSTEM_PROMPT_FLAG:-}" ]]; then
        # The user explicitly chose orchestrate; silently falling back
        # to a plain session would run the wrong workflow.
        wrapper_log "ERROR" "AI_SYSTEM_PROMPT_FLAG is not set for ${AI_WRAPPER_AGENT_NAME}; cannot inject orchestrator prompt."
        wrapper_log "ERROR" "Set AI_SYSTEM_PROMPT_FLAG in the agent's wrapper lib (e.g. --append-system-prompt) or pick 'Start new conversation'."
        return 1
    fi

    run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- \
        "${AGENT_FLAGS[@]}" "${AI_SYSTEM_PROMPT_FLAG}" "${prompt_content}"
}

# Run a plain agent session (start or resume). Uses AI_RESUME_ARGS if set.
run_agent_session() {
    local action="${1:-start}"
    # `${arr[@]:-default}` returns `default` when arr is unset or empty,
    # otherwise expands to arr. Safe under `set -u`, unlike `${#arr[@]}`
    # on an unset array (bash 3.2 errors there).
    local -a resume_args=("${AI_RESUME_ARGS[@]:---resume}")

    case "${action}" in
        resume)
            run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}" "${resume_args[@]}"
            ;;
        start)
            run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}"
            ;;
        *)
            wrapper_log "ERROR" "Unknown action: ${action} (expected 'start' or 'resume')"
            return 2
            ;;
    esac
}

# ===== SCRIPT GUARD =====

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: This script is meant to be sourced, not executed directly." >&2
    exit 1
fi
