#!/bin/bash

AI_WRAPPER_AGENT_NAME="Hermes Agent"
WRAPPER_DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

_hermes_resolve_profile() {
    local profile="${1}"
    shift
    local values value
    if ! values="$(python3 -I "${WRAPPER_DATA_DIR}/hermes_sandbox/profile.py" resolve --profile "${profile}" "$@")"; then
        return 1
    fi
    local -a paths=()
    while IFS= read -r value; do
        paths+=("${value}")
    done <<<"${values}"
    if [[ ${#paths[@]} -ne 9 ]]; then
        echo_log "ERROR" "Invalid Hermes profile resolver response."
        return 1
    fi
    _HERMES_RUNTIME="${paths[0]}"
    _HERMES_STATE="${paths[1]}"
    _HERMES_WORKSPACE="${paths[2]}"
    _HERMES_SNAPSHOT="${paths[3]}"
    _HERMES_CONTROL_SOCKET="${paths[4]}"
    _HERMES_DESKTOP_BRIDGE="${paths[5]}"
    _HERMES_CONTROL_TOKEN="${paths[6]}"
    _HERMES_BACKEND_DIRECTORY="${paths[7]}"
    _HERMES_BACKEND_MANIFEST="${paths[8]}"
    [[ "${_HERMES_SNAPSHOT}" == "-" ]] && _HERMES_SNAPSHOT=""
    [[ "${_HERMES_CONTROL_SOCKET}" == "-" ]] && _HERMES_CONTROL_SOCKET=""
    [[ "${_HERMES_DESKTOP_BRIDGE}" == "-" ]] && _HERMES_DESKTOP_BRIDGE=""
    [[ "${_HERMES_CONTROL_TOKEN}" == "-" ]] && _HERMES_CONTROL_TOKEN=""
    [[ "${_HERMES_BACKEND_DIRECTORY}" == "-" ]] && _HERMES_BACKEND_DIRECTORY=""
    [[ "${_HERMES_BACKEND_MANIFEST}" == "-" ]] && _HERMES_BACKEND_MANIFEST=""
    _HERMES_PROFILE="${profile}"
    AI_AGENT_COMMAND="${_HERMES_RUNTIME}/.venv/bin/python"
    return 0
}

_run_hermes_sandbox_linux() {
    if [[ $# -lt 3 || "${2:-}" != "--" || "${3:-}" != "--" ]]; then
        echo_log "ERROR" "Hermes profiles require COMMAND -- -- ARGS without extra bind flags."
        return 78
    fi
    local command="${1}"
    shift 3
    if [[ -z "${_HERMES_RUNTIME:-}" || -z "${_HERMES_STATE:-}" || -z "${_HERMES_WORKSPACE:-}" ]]; then
        echo_log "ERROR" "Hermes profile paths have not been validated."
        return 78
    fi
    if [[ "${command}" != "${_HERMES_RUNTIME}/.venv/bin/python" || ! -x "${command}" ]]; then
        echo_log "ERROR" "Hermes must use the registered runtime's provisioned Python interpreter."
        return 78
    fi
    local bwrap_binary
    bwrap_binary="$(command -v bwrap)" || {
        echo_log "ERROR" "Hermes requires bubblewrap; sandbox setup has no fallback."
        return 127
    }
    local -a hermes_args=(
        --die-with-parent --new-session --unshare-all --unshare-user --unshare-pid --share-net
        --cap-drop ALL
        --ro-bind /usr /usr
        --ro-bind /bin /bin
        --ro-bind /lib /lib
        --tmpfs /tmp --tmpfs /var --tmpfs /run
        --proc /proc --dev /dev
        --perms 0700 --dir /home/hermes
        --perms 0700 --dir /home/hermes/.hermes
        --perms 0700 --dir /home/hermes/.hermes/desktop-ssh
        --perms 0700 --dir /run/hermes
        --clearenv
        --setenv HOME /home/hermes
        --setenv USER hermes
        --setenv PATH "${_HERMES_RUNTIME}/.venv/bin:/usr/bin:/bin"
        --setenv LANG "${LANG:-C.UTF-8}"
        --setenv TERM "${TERM:-xterm-256color}"
        --setenv HERMES_HOME "${_HERMES_STATE}"
        --setenv HERMES_PROFILE_NAME "${_HERMES_PROFILE}"
        --setenv HERMES_SANDBOX_PROFILE "${_HERMES_PROFILE}"
        --setenv HERMES_SANDBOX_RUNTIME "${_HERMES_RUNTIME}"
        --setenv HERMES_SANDBOX_WORKSPACE "${_HERMES_WORKSPACE}"
        --setenv HERMES_SANDBOX_WORKER_SNAPSHOT /run/hermes/worker.json
        --setenv HERMES_SANDBOX_CONTROL_SOCKET /run/hermes/control.sock
        --setenv HERMES_SANDBOX_CONTROL_TOKEN_FILE /run/hermes/control.token
        --setenv _HERMES_PROFILE "${_HERMES_PROFILE}"
        --setenv _HERMES_RUNTIME "${_HERMES_RUNTIME}"
        --setenv _HERMES_STATE "${_HERMES_STATE}"
        --setenv _HERMES_WORKSPACE "${_HERMES_WORKSPACE}"
        --setenv _HERMES_SNAPSHOT /run/hermes/worker.json
        --setenv XDG_CONFIG_HOME /home/hermes/.config
        --setenv XDG_CACHE_HOME "${_HERMES_STATE}/cache"
        --setenv XDG_DATA_HOME /home/hermes/.local/share
        --setenv XDG_STATE_HOME /home/hermes/.local/state
        --setenv UV_CACHE_DIR "${_HERMES_STATE}/cache/uv"
        --setenv PIP_CACHE_DIR "${_HERMES_STATE}/cache/pip"
        --setenv PYTHONDONTWRITEBYTECODE 1
        --setenv PYTHONNOUSERSITE 1
        --ro-bind "${_HERMES_RUNTIME}" "${_HERMES_RUNTIME}"
        --ro-bind "${WRAPPER_DATA_DIR}/hermes_sandbox" /opt/hermes-sandbox
        --bind "${_HERMES_STATE}" "${_HERMES_STATE}"
        --bind "${_HERMES_WORKSPACE}" "${_HERMES_WORKSPACE}"
        --chdir "${_HERMES_WORKSPACE}"
    )
    [[ -d /lib64 ]] && hermes_args+=(--ro-bind /lib64 /lib64)
    local system_path
    for system_path in /etc/resolv.conf /etc/hosts /etc/nsswitch.conf /etc/passwd /etc/group /etc/ssl /etc/pki /etc/ca-certificates /etc/localtime /etc/fonts /etc/mime.types; do
        [[ -e "${system_path}" ]] && hermes_args+=(--ro-bind "${system_path}" "${system_path}")
    done
    if [[ -n "${_HERMES_SNAPSHOT:-}" ]]; then
        hermes_args+=(--ro-bind "${_HERMES_SNAPSHOT}" /run/hermes/worker.json)
    fi
    if [[ -n "${_HERMES_CONTROL_SOCKET:-}" ]]; then
        hermes_args+=(--ro-bind "${_HERMES_CONTROL_SOCKET}" /run/hermes/control.sock)
    fi
    if [[ -n "${_HERMES_CONTROL_TOKEN:-}" ]]; then
        hermes_args+=(--ro-bind "${_HERMES_CONTROL_TOKEN}" /run/hermes/control.token)
    fi
    if [[ -n "${_HERMES_DESKTOP_BRIDGE:-}" ]]; then
        hermes_args+=(--bind "${_HERMES_DESKTOP_BRIDGE}" /run/hermes-desktop)
    fi
    if [[ -n "${_HERMES_BACKEND_DIRECTORY:-}" ]]; then
        hermes_args+=(--ro-bind "${_HERMES_BACKEND_DIRECTORY}" "/home/hermes/.hermes/desktop-ssh/${_HERMES_BACKEND_DIRECTORY##*/}")
    fi
    if [[ -n "${_HERMES_BACKEND_MANIFEST:-}" ]]; then
        hermes_args+=(--ro-bind "${_HERMES_BACKEND_MANIFEST}" /run/hermes/backend.json
                     --setenv HERMES_SANDBOX_BACKEND_MANIFEST /run/hermes/backend.json)
    fi
    local variable
    for variable in TZ; do
        [[ -n "${!variable:-}" ]] && hermes_args+=(--setenv "${variable}" "${!variable}")
    done
    if [[ "${_HERMES_KIND:-cli}" == "worker" ]]; then
        env -i PATH=/usr/bin:/bin "${bwrap_binary}" "${hermes_args[@]}" "${command}" "$@"
    else
        python3 -I "${WRAPPER_DATA_DIR}/hermes_sandbox/profile.py" execute \
            --profile "${_HERMES_PROFILE}" --kind "${_HERMES_KIND:-cli}" -- \
            "${bwrap_binary}" "${hermes_args[@]}" "${command}" "$@"
    fi
}
