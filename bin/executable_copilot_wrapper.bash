#!/bin/bash
# Minimal-privilege wrapper for the GitHub Copilot CLI. Sandboxes Copilot to
# the current working directory, the CLI config, and read-only system paths.
# Dispatches to bubblewrap on Linux or sandbox-exec (Seatbelt) on macOS via
# run_sandboxed_agent() in ai_agent_universal_wrapper.bash.

set -u -o pipefail

: "${XDG_RUNTIME_DIR:=}"
: "${COLORTERM:=}"
: "${TERM_PROGRAM:=}"

source "$(dirname "${BASH_SOURCE[0]}")/ai_agent_universal_wrapper.bash"
source "$(dirname "${BASH_SOURCE[0]}")/ai_wrapper_data/copilot_wrapper_lib.bash"

_load_extra_profile

check_agent_binary

WRAPPER_FLAGS=()

# Bind shared Git metadata for worktrees after validating its path and links.
_wrapper_bind_git_common_dir || exit 1

# Keep Copilot runtime state in its standard home paths while preventing broad
# access to unrelated system directories. Symlinked config paths are refused
# when they resolve outside $HOME or into credential directories.
_copilot_bind_config_dirs || exit 1

# Auto-approve all tools, filesystem paths, and URLs inside the OS sandbox.
AGENT_FLAGS=(--allow-all-tools --allow-all-paths --allow-all-urls)

if _wd_resolved="$(_realpath "$(pwd -P)")" && _home_resolved="$(_realpath "${HOME}")"; then
    _check_workdir_breadth "copilot" "${_wd_resolved%/}" "${_home_resolved%/}"
fi
unset _wd_resolved _home_resolved

if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    _preset_autoload
    show_main_menu
    _preset_autosave
    # Apply toggle-dependent binds AFTER the menu so flips made in the
    # Settings sub-menu reach WRAPPER_FLAGS.
    _apply_post_menu_binds || exit 1

    if declare -f _extra_post_menu_setup >/dev/null 2>&1; then
        _extra_post_menu_setup
    fi

    _copilot_enable_unrestricted_mode

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

_preset_autoload
_apply_post_menu_binds || exit 1
if declare -f _extra_post_menu_setup >/dev/null 2>&1; then
    _extra_post_menu_setup
fi
_copilot_enable_unrestricted_mode
run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}" "$@"
