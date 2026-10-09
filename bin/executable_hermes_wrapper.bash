#!/bin/bash

set -u -o pipefail

WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${WRAPPER_DIR}/ai_agent_universal_wrapper.bash"
source "${WRAPPER_DIR}/ai_wrapper_data/hermes_wrapper_lib.bash"

profile="default"
if [[ "${1:-}" == "--profile" ]]; then
    if [[ $# -lt 2 ]]; then
        echo_log "ERROR" "--profile requires a name."
        exit 2
    fi
    profile="${2}"
    shift 2
fi

if [[ "${1:-}" == "--wrapper-help" ]]; then
    printf '%s\n' \
        'Usage: hermes_wrapper.bash [--profile NAME] [HERMES_ARGS...]' \
        'Doctor: hermes_wrapper.bash [--profile NAME] doctor' \
        'Addons: hermes_wrapper.bash [--profile NAME] addons list|install NAME' \
        'Desktop: hermes_wrapper.bash [--profile NAME] desktop [ARGS...]' \
        'Worker: hermes_wrapper.bash --profile NAME _worker cron|kanban ATTEMPT_ID' \
        'Interactive: select a registered workspace and launch mode.' \
        'Register profiles with setup_hermes.bash init --runtime DIR [--workspace DIR].'
    exit 0
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo_log "ERROR" "Hermes sandboxing requires Linux and bubblewrap."
    exit 78
fi

for argument in "$@"; do
    case "${argument}" in
        --no-sandbox*|--no_sandbox*|--disable-sandbox*|--unsandboxed*|--sandbox*|--dangerously-bypass*|--profile|--profile=*|--hermes-home*|--home|--home=*)
            echo_log "ERROR" "Hermes sandbox policy cannot be disabled or overridden."
            exit 78
            ;;
    esac
done

if [[ $# -eq 0 && -t 0 && -t 1 ]]; then
    _hermes_resolve_profile "${profile}" || exit 1
    printf 'Hermes profile: %s\nSelect a registered workspace:\n' "${profile}" >/dev/tty
    workspace_options=("${_HERMES_WORKSPACE}" "${_HERMES_WORKSPACES[@]}")
    select selected_workspace in "${workspace_options[@]}"; do
        if [[ -n "${selected_workspace:-}" ]]; then
            _HERMES_START_WORKSPACE="${selected_workspace}"
            _HERMES_SELECTED_WORKSPACE="${selected_workspace}"
            break
        fi
        printf 'Choose a listed workspace, or interrupt to quit.\n' >/dev/tty
    done
    [[ -n "${_HERMES_START_WORKSPACE:-}" ]] || exit 0
    printf 'Launch mode:\n' >/dev/tty
    select launch_mode in 'CLI chat' 'Private Desktop' 'Gateway' 'Quit'; do
        case "${launch_mode:-}" in
            'CLI chat') break ;;
            'Private Desktop') set -- desktop --workspace-root "${_HERMES_START_WORKSPACE}"; break ;;
            Gateway) set -- gateway; break ;;
            Quit) exit 0 ;;
            *) printf 'Choose a listed launch mode.\n' >/dev/tty ;;
        esac
    done
fi

if [[ "${1:-}" == "doctor" ]]; then
    if [[ $# -ne 1 ]]; then
        echo_log "ERROR" "doctor does not accept runtime arguments."
        exit 2
    fi
    python3 -I "${WRAPPER_DATA_DIR}/hermes_sandbox/profile.py" doctor --profile "${profile}"
    exit $?
fi

if [[ "${1:-}" == "desktop" ]]; then
    shift
    [[ -n "${_HERMES_SELECTED_WORKSPACE:-}" ]] || _hermes_resolve_profile "${profile}" || exit 1
    if [[ "${1:-}" == "--workspace-root" ]]; then
        workspace_root="${2:-}"
        [[ -n "${workspace_root}" ]] || exit 2
        shift 2
    else
        workspace_root="${_HERMES_SELECTED_WORKSPACE:-${_HERMES_WORKSPACE:-}}"
    fi
    python3 -I "${WRAPPER_DATA_DIR}/hermes_sandbox/profile.py" desktop --profile "${profile}" \
        --workspace-root "${workspace_root}" -- "$@"
    exit $?
fi
if [[ "${1:-}" == "serve" ]]; then
    shift
    [[ -n "${_HERMES_SELECTED_WORKSPACE:-}" ]] || _hermes_resolve_profile "${profile}" || exit 1
    python3 -I "${WRAPPER_DATA_DIR}/hermes_sandbox/profile.py" serve --profile "${profile}" \
        --workspace-root "${_HERMES_SELECTED_WORKSPACE:-${_HERMES_WORKSPACE:-}}" -- "$@"
    exit $?
fi

_HERMES_KIND=cli
if [[ "${1:-}" == "_worker" ]]; then
    if [[ $# -ne 3 ]]; then
        echo_log "ERROR" "_worker requires a kind and attempt identifier."
        exit 2
    fi
    _hermes_resolve_profile "${profile}" --worker "${2}" "${3}" || exit 1
    _HERMES_KIND=worker
    adapter_args=(worker "${2}" "${3}")
elif [[ "${1:-}" == "_desktop_server" ]]; then
    if [[ $# -lt 2 ]]; then
        echo_log "ERROR" "_desktop_server requires its protected display bridge."
        exit 2
    fi
    bridge_path="${2}"
    shift 2
    if [[ "${1:-}" == "--workspace-root" ]]; then
        _HERMES_START_WORKSPACE="${2:-}"
        [[ -n "${_HERMES_START_WORKSPACE}" ]] || exit 2
        shift 2
    fi
    _hermes_resolve_profile "${profile}" --desktop-bridge "${bridge_path}" || exit 1
    if [[ -z "${_HERMES_BACKEND_MANIFEST}" ]]; then
        echo_log "ERROR" "Desktop requires a protected authenticated backend connection."
        exit 78
    fi
    _HERMES_KIND=desktop-server
    adapter_args=(cli -- desktop "$@")
elif [[ "${1:-}" == "_serve_server" ]]; then
    if [[ $# -lt 3 ]]; then
        echo_log "ERROR" "_serve_server requires protected backend token and connection paths."
        exit 2
    fi
    backend_directory="${2}"
    backend_manifest="${3}"
    shift 3
    if [[ "${1:-}" == "--workspace-root" ]]; then
        _HERMES_START_WORKSPACE="${2:-}"
        [[ -n "${_HERMES_START_WORKSPACE}" ]] || exit 2
        shift 2
    fi
    _hermes_resolve_profile "${profile}" --backend-directory "${backend_directory}" \
        --backend-manifest "${backend_manifest}" || exit 1
    _HERMES_KIND=backend-server
    adapter_args=(cli -- serve "$@")
else
    if [[ "${1:-}" == "gateway" ]]; then
        _hermes_resolve_profile "${profile}" --require-control || exit 1
    else
        _hermes_resolve_profile "${profile}" || exit 1
    fi
    case "${1:-}" in
        gateway) _HERMES_KIND=gateway ;;
        serve) _HERMES_KIND=serve ;;
    esac
    adapter_args=(cli -- "$@")
fi

if [[ "${1:-}" == "addons" ]]; then
    shift
    if [[ "${1:-}" != "list" && "${1:-}" != "install" ]]; then
        echo_log "ERROR" "addons requires list or install."
        exit 2
    fi
    for argument in "$@"; do
        case "${argument}" in
            --state|--state=*)
                echo_log "ERROR" "Addon state is fixed by the registered profile."
                exit 78
                ;;
        esac
    done
    if [[ ! -f "${WRAPPER_DATA_DIR}/hermes_sandbox/addons.py" ]]; then
        echo_log "ERROR" "Hermes addon module is not installed."
        exit 78
    fi
    module_path=/opt/hermes-sandbox/addons.py
    if [[ "${1}" == "list" ]]; then
        adapter_args=("$@")
    else
        adapter_args=("$@" --state "${_HERMES_STATE}")
    fi
else
    module_path=/opt/hermes-sandbox/adapter.py
fi

if [[ ! -f "${WRAPPER_DATA_DIR}/hermes_sandbox/adapter.py" || ! -f "${WRAPPER_DATA_DIR}/hermes_sandbox/frontends.py" ]]; then
    echo_log "ERROR" "Hermes compatibility adapter is not installed."
    exit 78
fi

cd "${_HERMES_WORKSPACE}" || exit 1
export AI_SANDBOX_AGENT_PROFILE=hermes
run_sandboxed_agent "${AI_AGENT_COMMAND}" -- -- -I "${module_path}" "${adapter_args[@]}"
