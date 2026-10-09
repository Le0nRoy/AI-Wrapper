#!/bin/bash
# Minimal-privilege wrapper for the Codex CLI. Sandboxes Codex to the
# current working directory, the agent config, and read-only system paths.
# Dispatches to bubblewrap on Linux or sandbox-exec (Seatbelt) on macOS via
# run_sandboxed_agent() in ai_agent_universal_wrapper.bash.
#
# Features (parity with executable_claude_wrapper.bash):
# - Agent orchestration (plan → implement → test → review → merge); the
#   orchestrator prompt is injected via `-c developer_instructions=...`
# - Session resume (`codex resume`)
# - Multi-account credential profiles: CODEX_ACCOUNT=<name> uses
#   ~/.codex-<name>/ (bound at ~/.codex) instead of the default ~/.codex,
#   or pick "Account profile" from the s) Settings menu
# - Git worktree support (shared .git bound RW), glab config bind when
#   AI_SANDBOX_PASS_GITLAB=1, AI_WRAPPER_EXTRA_PROFILE plugin hooks
#
# Rlimit enforcement was dropped 2026-09 (see the header comment in
# ai_agent_universal_wrapper.bash).

source "$(dirname "${BASH_SOURCE[0]}")/ai_agent_universal_wrapper.bash"

# Requires `chezmoi apply` to have been run — if source fails, the wrapper is not yet deployed.
source "$(dirname "${BASH_SOURCE[0]}")/ai_wrapper_data/codex_wrapper_lib.bash"

# Downstream extension hook (AI_WRAPPER_EXTRA_PROFILE). Same callback
# contract as the Claude wrapper — see the comment block above
# _load_extra_profile in executable_claude_wrapper.bash and
# wrapper-help.md § "Extensions via AI_WRAPPER_EXTRA_PROFILE".
_load_extra_profile

# Fail fast if the agent binary is missing.
check_agent_binary

# Sandbox flags - filesystem bindings. Uses the OS-aware _wrapper_add_bind /
# _wrapper_add_ro_bind helpers (ai_wrapper_data/ai_wrapper_lib.bash) rather
# than hardcoding bwrap's 2-arg `--bind SRC DST` shape: sandbox-exec (macOS)
# takes a single-arg `--bind SRC` and hard-errors on a stray second token.
# The ~/.codex bind itself is added after the menu by _bind_codex_account
# (CODEX_ACCOUNT may change there).
WRAPPER_FLAGS=()

# Shared .git of a `git worktree` checkout (see ai_wrapper_lib.bash).
_wrapper_bind_git_common_dir

# Codex CLI flags - full autonomy within sandbox (no approvals needed)
AGENT_FLAGS=(
    --dangerously-bypass-approvals-and-sandbox
)

# Evaluate the WORKDIR-breadth heuristic before showing the menu so the
# yellow banner is visible on first render.
if _wd_resolved="$(_realpath "$(pwd -P)")" && _home_resolved="$(_realpath "${HOME}")"; then
    _check_workdir_breadth "codex" "${_wd_resolved%/}" "${_home_resolved%/}"
fi
unset _wd_resolved _home_resolved

# Interactive session selection (only if no arguments provided and stdin/stdout are terminals)
if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    # Auto-load this workdir's codex preset before the menu renders so restored
    # settings (including CODEX_ACCOUNT) are visible in the settings table
    # on first paint. Silent no-op when no preset file exists (first run).
    _preset_autoload
    show_main_menu
    _preset_autosave
    # Resolve CODEX_ACCOUNT and apply toggle-dependent binds AFTER the
    # menu so flips made in the Settings sub-menu reach WRAPPER_FLAGS.
    _bind_codex_account
    _apply_post_menu_binds

    # Plugin post-menu hook (AI_WRAPPER_EXTRA_PROFILE); no-op when undefined.
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
# workdir's codex preset (CODEX_ACCOUNT, AI_SANDBOX_* flags) directly so a
# scripted invocation still picks up settings saved from an earlier
# interactive session in this workdir, instead of silently reverting to
# catalog defaults.
# AI rules (AGENTS.md and CLAUDE.md) are bound by default in universal wrapper
_preset_autoload
_bind_codex_account
_apply_post_menu_binds
if declare -f _extra_post_menu_setup >/dev/null 2>&1; then
    _extra_post_menu_setup
fi
run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}" "$@"
