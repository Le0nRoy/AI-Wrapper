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

# Keep Copilot runtime state in its standard home paths while preventing broad
# access to unrelated system directories.
_wrapper_add_bind "${HOME}/.copilot"
if [[ -d "${HOME}/.config/github-copilot" ]]; then
    _wrapper_add_bind "${HOME}/.config/github-copilot"
fi
if [[ -d "${HOME}/.local/share/copilot" ]]; then
    _wrapper_add_bind "${HOME}/.local/share/copilot"
fi

# Copilot defaults to a permissive CLI flow, but the actual permission model is
# controlled by command flags. Match the other wrappers' default autonomy.
AGENT_FLAGS=(--allow-all)

if _wd_resolved="$(_realpath "$(pwd -P)")" && _home_resolved="$(_realpath "${HOME}")"; then
    _check_workdir_breadth "copilot" "${_wd_resolved%/}" "${_home_resolved%/}"
fi
unset _wd_resolved _home_resolved

if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    _preset_autoload
    show_main_menu
    _preset_autosave

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

_preset_autoload
if declare -f _extra_post_menu_setup >/dev/null 2>&1; then
    _extra_post_menu_setup
fi
run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]}" -- "${AGENT_FLAGS[@]}" "$@"
