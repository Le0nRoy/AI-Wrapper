#!/bin/bash
# Minimal-privilege wrapper for the Antigravity CLI (agy). Sandboxes agy to the
# current working directory, the agent config (~/.gemini), and read-only system
# paths. Dispatches to bubblewrap on Linux or sandbox-exec (Seatbelt) on macOS
# via run_sandboxed_agent() in ai_agent_universal_wrapper.bash.
#
# Features (parity with executable_claude_wrapper.bash and executable_codex_wrapper.bash):
# - Agent orchestration (plan → implement → test → review → merge); the
#   orchestrator prompt is injected via `--prompt-interactive <prompt>` and
#   managed skills (including `orchestrator-mode`) are synced into the active
#   profile's `config/skills/`
# - Session resume: interactive conversation picker backed by
#   `antigravity-cli/conversation_summaries.db` (launching `agy --conversation=<id>`
#   or `--continue`)
# - Multi-account credential profiles: AGY_ACCOUNT=<name> uses
#   ~/.gemini-<name>/ (bound at ~/.gemini) instead of the default ~/.gemini,
#   or pick "Account profile" from the s) Settings menu
# - Full autonomy inside the OS sandbox: passes `--dangerously-skip-permissions`
#   and configures `antigravity-cli/settings.json` with `always-proceed` tool
#   and artifact policies, workspace trust, and outer-sandbox compatibility
# - Git worktree support (shared .git bound RW), glab config bind when
#   AI_SANDBOX_PASS_GITLAB=1, AI_WRAPPER_EXTRA_PROFILE plugin hooks

set -u -o pipefail

# Defensive defaults for optional passthrough env vars read under `set -u`.
: "${XDG_RUNTIME_DIR:=}"
: "${COLORTERM:=}"
: "${TERM_PROGRAM:=}"
: "${KIND_EXPERIMENTAL_PROVIDER:=}"

source "$(dirname "${BASH_SOURCE[0]}")/ai_agent_universal_wrapper.bash"

# Requires `chezmoi apply` to have been run — if source fails, the wrapper is not yet deployed.
source "$(dirname "${BASH_SOURCE[0]}")/ai_wrapper_data/agy_wrapper_lib.bash"

# Downstream extension hook (AI_WRAPPER_EXTRA_PROFILE).
_load_extra_profile

# Fail fast if the agent binary is missing.
check_agent_binary

# Sandbox flags - filesystem bindings. The ~/.gemini bind is added after the
# menu by _bind_agy_account (AGY_ACCOUNT may change there).
WRAPPER_FLAGS=()

# Shared .git of a `git worktree` checkout (see ai_wrapper_lib.bash).
_wrapper_bind_git_common_dir

# User-installed CLI binaries (agy is commonly installed in ~/.local/bin).
if [[ -d "${HOME}/.local/bin" ]]; then
    _wrapper_add_ro_bind "${HOME}/.local/bin"
fi

# Antigravity CLI flags — full autonomy within the OS sandbox boundary.
AGENT_FLAGS=(
    --dangerously-skip-permissions
)

# Evaluate the WORKDIR-breadth heuristic before showing the menu so the
# yellow banner is visible on first render.
if _wd_resolved="$(_realpath "$(pwd -P)")" && _home_resolved="$(_realpath "${HOME}")"; then
    _check_workdir_breadth "agy" "${_wd_resolved%/}" "${_home_resolved%/}"
fi
unset _wd_resolved _home_resolved

# Interactive session selection (only if no arguments provided and stdin/stdout are terminals)
if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    # Auto-load this workdir's agy preset before the menu renders so restored
    # settings (including AGY_ACCOUNT) are visible in the settings table
    # on first paint. Silent no-op when no preset file exists (first run).
    _preset_autoload
    show_main_menu
    _preset_autosave
    # Resolve AGY_ACCOUNT and apply toggle-dependent binds AFTER the
    # menu so flips made in the Settings sub-menu reach WRAPPER_FLAGS.
    _bind_agy_account
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

# Non-interactive or argument pass-through. Load the workdir's agy preset
# (AGY_ACCOUNT, AI_SANDBOX_* flags) directly so a scripted invocation picks
# up settings saved from an earlier interactive session in this workdir.
_preset_autoload
_bind_agy_account
_apply_post_menu_binds
if declare -f _extra_post_menu_setup >/dev/null 2>&1; then
    _extra_post_menu_setup
fi
run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}" "$@"
