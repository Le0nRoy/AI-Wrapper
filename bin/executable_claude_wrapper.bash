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
        if ! mkdir -p "${claude_dir}"; then
            echo "ERROR: failed to create ${claude_dir}" >&2
            exit 1
        fi

        # Ensure ~/.claude.json exists before binding. Claude's atomic-write
        # pattern is `write .claude.json.tmp.<...> -> rename .claude.json`;
        # binding a nonexistent destination would leave that rename with
        # nothing to land on. If the path exists but isn't a regular file,
        # refuse rather than silently binding a misshapen path.
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

    _wrapper_add_bind "${claude_dir}" "${HOME}/.claude"
    _wrapper_add_bind "${claude_json_src}" "${HOME}/.claude.json"
}

# Git worktree support: when WORKDIR is a `git worktree add`-created tree, its
# top-level `.git` is a file (not a dir) that points at <main>/.git/worktrees/<name>
# in the main repo. The shared object store + refs live at the main repo's
# `.git/`, which is OUTSIDE WORKDIR — so every git operation (status, log,
# fetch, commit) fails with "fatal: not a git repository: <gitdir>" because
# the sandbox's default-deny fence hides the shared `.git`.
#
# `git rev-parse --git-common-dir` returns the shared `.git` directory. When
# it differs from `$PWD/.git`, bind it RW so the worktree is fully functional.
# RW (not RO) is required: `git commit` / `git fetch` / `git gc` all mutate
# the shared object store and refs. The bind is silently skipped when the
# detection fails (not a git repo, git missing, or a regular non-worktree
# repo where common-dir resolves to $PWD/.git which is already inside WORKDIR).
if _git_common_dir="$(git -C "$(pwd -P)" rev-parse --git-common-dir 2>/dev/null)" \
        && [[ -n "${_git_common_dir}" ]]; then
    # `git rev-parse --git-common-dir` returns either an absolute path or a
    # path relative to CWD (typically just ".git"). Canonicalize so the bind
    # source is unambiguous and so symlinks in the chain are resolved the
    # same way the kernel's path lookup will.
    if [[ "${_git_common_dir}" != /* ]]; then
        _git_common_dir="$(pwd -P)/${_git_common_dir}"
    fi
    if _git_common_resolved="$(_realpath "${_git_common_dir}")" \
            && [[ -n "${_git_common_resolved}" && -d "${_git_common_resolved}" ]]; then
        _wd_resolved_for_git="$(_realpath "$(pwd -P)")" || _wd_resolved_for_git=""
        _home_resolved_for_git="$(_realpath "${HOME}")" || _home_resolved_for_git="${HOME%/}"
        _home_resolved_for_git="${_home_resolved_for_git%/}"
        # Skip when the shared .git is already inside WORKDIR — a regular
        # (non-worktree) repo binds it via the WORKDIR rule.
        if [[ -n "${_wd_resolved_for_git}" \
                && "${_git_common_resolved}" != "${_wd_resolved_for_git}"/* \
                && "${_git_common_resolved}" != "${_wd_resolved_for_git}" ]]; then
            _wrapper_add_bind "${_git_common_resolved}"
            # Git canonicalizes the absolute paths in the gitdir line
            # (mainrepo/.git/worktrees/<name>) which requires stat() on every
            # intermediate dir between $HOME and the shared .git (Seatbelt
            # only — see _wrapper_add_meta_bind). Add only the shared-.git
            # branch here; the WORKDIR branch of this walk is handled by
            # each backend already.
            _wt_parent="${_git_common_resolved%/*}"
            while [[ -n "${_wt_parent}" \
                    && "${_wt_parent}" != "${_home_resolved_for_git}" \
                    && "${_wt_parent}" != "/" ]]; do
                _wrapper_add_meta_bind "${_wt_parent}"
                _wt_parent="${_wt_parent%/*}"
            done
            unset _wt_parent
        fi
        unset _wd_resolved_for_git _home_resolved_for_git
    fi
fi
unset _git_common_dir _git_common_resolved

# Bind-list flags that the interactive Settings sub-menu can toggle
# need to be evaluated AFTER the menu — otherwise enabling them via
# `s)` has no effect (WRAPPER_FLAGS is frozen by then). The shared
# wrapper re-reads env-passthrough gates inside run_sandboxed_agent
# at exec time, so those keep working; this function covers only the
# bind-list side.
_apply_post_menu_binds() {
    # GitLab CLI (glab) on-disk credentials. AI_SANDBOX_PASS_GITLAB
    # already propagates GITLAB_TOKEN / CI_JOB_TOKEN env vars; when
    # the user has no env var set, glab reads its token from the
    # on-disk config instead. Bind that config dir RO when the same
    # flag is set so `glab` works end-to-end without the user having
    # to also export the token. RO is sufficient: glab only writes
    # the config when running `glab auth login`, which is not the
    # agent's job.
    #
    # macOS uses ~/Library/Application Support/glab-cli/; the XDG
    # paths under ~/.config/glab-cli and ~/.local/share/glab-cli are
    # honoured as fallbacks (some users set XDG_CONFIG_HOME to
    # relocate) and are the only paths that exist on Linux.
    if [[ "${AI_SANDBOX_PASS_GITLAB:-0}" == "1" ]]; then
        local _glab_dir
        for _glab_dir in \
                "${HOME}/Library/Application Support/glab-cli" \
                "${HOME}/.config/glab-cli" \
                "${HOME}/.local/share/glab-cli"; do
            [[ -d "${_glab_dir}" ]] && _wrapper_add_ro_bind "${_glab_dir}"
        done
    fi
}

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
run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}" "$@"
