#!/bin/bash
# Minimal-privilege wrapper for the Claude CLI. Sandboxes Claude to the
# current working directory, the agent config, and read-only system paths.
# Dispatches to bubblewrap on Linux or sandbox-exec (Seatbelt) on macOS via
# run_sandboxed_agent() in ai_agent_universal_wrapper.bash — this script
# itself is OS-agnostic and must not assume either backend's flag shape
# without checking $(uname -s) first (see _wrapper_add_bind in the shared
# ai_wrapper_data/ai_wrapper_lib.bash).
#
# Interactive launch (no args, attached TTY): shows the orchestration menu.
# Non-interactive launch (args, or no TTY): forwards args to claude inside
# the sandbox.
#
# Multi-account credential profiles: set CLAUDE_ACCOUNT=<name> to use
# ~/.claude-<name>/ instead of the default ~/.claude, or pick "Account
# profile" from the s) Settings menu. Persists per-workdir like every other
# sandbox setting. See wrapper-help.md.

set -u -o pipefail

# Defensive defaults: ai_agent_universal_wrapper.bash's Linux backend reads
# several optional passthrough env vars unguarded (no ${VAR:-} fallback) —
# harmless under normal shell options, but this script's `set -u` above is
# a shell-wide option that stays in effect for every sourced file executing
# in this same process, turning each into an "unbound variable" hard-crash
# whenever the invoking environment doesn't have it set (observed for all
# four below in a su/sudo-switched and a non-login shell during testing;
# a normal interactive desktop login sets most of these via systemd-logind
# / the terminal emulator, which is why this doesn't surface in everyday
# use). Defaulting them to empty here — rather than patching the other
# file, which is out of this task's file ownership — is sufficient: an
# empty value still correctly fails that file's `-n` checks.
: "${XDG_RUNTIME_DIR:=}"
: "${COLORTERM:=}"
: "${TERM_PROGRAM:=}"
: "${KIND_EXPERIMENTAL_PROVIDER:=}"

source "$(dirname "${BASH_SOURCE[0]}")/ai_agent_universal_wrapper.bash"

# Requires `chezmoi apply` to have been run — if source fails, the wrapper is not yet deployed.
source "$(dirname "${BASH_SOURCE[0]}")/ai_wrapper_data/claude_wrapper_lib.bash"

# Downstream extension hook. If AI_WRAPPER_EXTRA_PROFILE points at a bash
# file, source it once here so a proprietary / per-machine / corporate-policy
# integrator can extend the sandbox without patching this file. The plugin
# can define one or more callbacks that fire later:
#   _extra_sandbox_setup      — before binds are baked into the SBPL / bwrap
#                               profile (mutate binds_rw / binds_ro /
#                               binds_meta on Darwin, bwrap_args on Linux,
#                               env_allowlist either OS).
#   _extra_post_menu_setup    — after the interactive menu, before dispatch
#                               (mutate AGENT_FLAGS / AI_SANDBOX_PROFILE /
#                               any env-var toggle the plugin cares about).
#   _extra_settings_register  — append entries to _AI_SETTINGS_LIST before
#                               the banner / toggle menu reads it.
#   _extra_category_label     — printf a label for an unknown category key
#                               and return 0; non-zero falls back to raw key.
#   _extra_header_extras      — render extra status lines below the settings
#                               table in show_header.
#   _extra_menu_options       — print extra menu options (echo … >/dev/tty).
#   _extra_menu_dispatch      — handle an unknown choice; return 0 = handled
#                               (menu re-renders), non-zero = fall through.
# See also: docs/wrapper-help.md § "Extensions via AI_WRAPPER_EXTRA_PROFILE".
# Zero behavior change when the env var is unset. Auditable at
# `env | grep AI_WRAPPER`.
_load_extra_profile

# Rlimit enforcement was dropped 2026-09 (see the header comment in
# ai_agent_universal_wrapper.bash) — the user accepts the risk of unbounded
# CPU / memory / file-descriptor / process consumption by the sandboxed
# agent in exchange for wrapper simplification.

# Fail fast if the agent binary is missing.
check_agent_binary

# OS-aware bind helpers (_wrapper_add_bind / _wrapper_add_ro_bind /
# _wrapper_add_meta_bind / _wrapper_os) and the portable path-resolution
# helpers (_realpath / _check_workdir_breadth) now live in the shared
# ai_wrapper_data/ai_wrapper_lib.bash — sourced above via
# ai_wrapper_data/claude_wrapper_lib.bash — so Codex and Cursor get them too
# instead of hardcoding Linux-shaped 2-arg bind flags.

WRAPPER_FLAGS=()

# Resolve CLAUDE_ACCOUNT (from a persisted preset or a Settings-menu edit)
# to the credential dir/file to bind, and append the binds to
# WRAPPER_FLAGS. Must run AFTER _preset_autoload and any menu interaction
# — CLAUDE_ACCOUNT isn't authoritative until then. Called from both the
# interactive path (after show_main_menu) and the non-interactive path
# (after _preset_autoload, before dispatch) — see bottom of this file.
_bind_claude_account() {
    local account="${CLAUDE_ACCOUNT:-private}"
    [[ "${account}" == "private" ]] && account=""

    local claude_dir claude_json_src
    if [[ -n "${account}" ]]; then
        if [[ ! "${account}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "ERROR: Invalid CLAUDE_ACCOUNT '${account}': must contain only letters, digits, hyphens, underscores" >&2
            exit 1
        fi
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

        # WS3 / B-alpha: symlink-safety guard. Refuse if ~/.claude exists as
        # a non-directory (a stray file from a botched migration) or as a
        # symlink whose target escapes $HOME. A rogue symlink would cause
        # `mkdir -p` to follow it, then the subsequent bind would grant RW
        # on the symlink target's real location — silently moving the
        # write fence somewhere unintended. Only applies to the private
        # (default) account — a named account's directory must already
        # exist as a real directory (checked above).
        if [[ -L "${claude_dir}" ]]; then
            local _resolved_claude_dir
            if ! _resolved_claude_dir="$(_realpath "${claude_dir}")" || [[ -z "${_resolved_claude_dir}" ]]; then
                echo "ERROR: ${claude_dir} is a symlink whose target cannot be resolved. Inspect and remove before launching." >&2
                exit 1
            fi
            case "${_resolved_claude_dir}" in
                "${HOME}"/*) ;;
                *)
                    echo "ERROR: ${claude_dir} is a symlink pointing outside \$HOME (resolves to ${_resolved_claude_dir}). Refusing — the bind would grant RW on the target." >&2
                    exit 1
                    ;;
            esac
        elif [[ -e "${claude_dir}" && ! -d "${claude_dir}" ]]; then
            echo "ERROR: ${claude_dir} exists but is not a directory or symlink. Move or remove it before launching." >&2
            exit 1
        fi

        # Ensure ~/.claude exists before binding: the universal wrapper
        # requires bind sources to exist, so a fresh machine (no prior
        # Claude run) would otherwise hard-fail here instead of letting
        # Claude initialize the directory itself.
        _wrapper_check_config_symlink "${claude_dir}" || exit 1
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
    # symlinked profile dir / .claude.json whose target is outside $HOME or
    # inside a credential location. Covers the named-account paths, the
    # ~/.claude.json file, and credential-dir targets of ~/.claude, none of
    # which the checks above caught.
    _wrapper_check_config_symlink "${claude_dir}" || exit 1
    _wrapper_check_config_symlink "${claude_json_src}" || exit 1

    _wrapper_add_bind "${claude_dir}" "${HOME}/.claude"
    _wrapper_add_bind "${claude_json_src}" "${HOME}/.claude.json"
}

# Git worktree common-dir bind (shared .git outside WORKDIR) and the
# post-menu glab bind (_apply_post_menu_binds, called below) live in the
# shared ai_wrapper_data/ai_wrapper_lib.bash so the Codex wrapper gets the
# same behavior. See the comments there.
_wrapper_bind_git_common_dir

# Claude CLI flags — full autonomy *within the sandbox boundary*.
# The sandbox (bwrap args / SBPL profile) is the permission fence here:
# Claude's own per-tool prompts are turned off because writes are already
# confined to WORKDIR + ~/.claude + tmp.
AGENT_FLAGS=(
    --dangerously-skip-permissions
)

# WS3 / U-E: evaluate the WORKDIR-breadth heuristic before showing the
# menu so the yellow banner is visible on first render.
if _wd_resolved="$(_realpath "$(pwd -P)")" && _home_resolved="$(_realpath "${HOME}")"; then
    _check_workdir_breadth "claude" "${_wd_resolved%/}" "${_home_resolved%/}"
fi
unset _wd_resolved _home_resolved

# Interactive launch: show the orchestration / session menu.
# show_main_menu is called directly (not via `$()`) so that any env-var toggles
# the user makes in the s) Settings sub-menu propagate to this shell — and
# therefore to run_sandboxed_agent below. The chosen action is returned via
# the global $WRAPPER_MENU_CHOICE.
if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    # Auto-load the per-workdir preset before the menu renders so the
    # restored settings (including CLAUDE_ACCOUNT) are visible in the
    # settings table on first paint. Silent no-op when no preset file
    # exists (first run).
    _preset_autoload
    show_main_menu
    _preset_autosave
    # Resolve CLAUDE_ACCOUNT and apply toggle-dependent binds AFTER the
    # menu so flips made in the Settings sub-menu (account switch,
    # PASS_GITLAB) actually reach WRAPPER_FLAGS.
    _bind_claude_account
    _apply_post_menu_binds

    # Plugin post-menu hook: downstream extensions (loaded via
    # AI_WRAPPER_EXTRA_PROFILE) can mutate AGENT_FLAGS / AI_SANDBOX_PROFILE /
    # env-var toggles here, after the menu but before dispatch. Runs when
    # defined; a bare wrapper without the hook is a no-op.
    if declare -f _extra_post_menu_setup >/dev/null 2>&1; then
        _extra_post_menu_setup
    fi

    case "${WRAPPER_MENU_CHOICE}" in
        orchestrate)
            run_orchestrated_session
            _dispatch_rc=$?
            ;;
        *)
            run_agent_session "${WRAPPER_MENU_CHOICE}"
            _dispatch_rc=$?
            ;;
    esac

    exit "${_dispatch_rc}"
fi

# Non-interactive or argument pass-through. No menu runs, so load the
# per-workdir preset (CLAUDE_ACCOUNT, AI_SANDBOX_* flags) directly so a
# scripted invocation still picks up settings saved from an earlier
# interactive session in this workdir, instead of silently reverting to
# catalog defaults.
_preset_autoload
_bind_claude_account
_apply_post_menu_binds
# Non-interactive plugin hook: same contract as the interactive path above
# so scripted invocations pick up plugin post-menu mutations too.
if declare -f _extra_post_menu_setup >/dev/null 2>&1; then
    _extra_post_menu_setup
fi
run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}" "$@"
