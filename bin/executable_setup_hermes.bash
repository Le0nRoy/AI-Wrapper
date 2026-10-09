#!/bin/bash

set -eu -o pipefail

WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
profile="default"
runtime=""
workspace=""
state=""
revision="19cb1cbfedeafaca099be6ff0141a28a6c516c0f"
action="init"
dry_run=0

case "${1:-}" in
    init|register|prepare|doctor) action="${1}"; shift ;;
esac

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --profile|--runtime|--workspace|--state|--revision)
            if [[ $# -lt 2 ]]; then
                printf 'ERROR: %s requires a value.\n' "${1}" >&2
                exit 2
            fi
            case "${1}" in
                --profile) profile="${2}" ;;
                --runtime) runtime="${2}" ;;
                --workspace) workspace="${2}" ;;
                --state) state="${2}" ;;
                --revision) revision="${2}" ;;
            esac
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --help|-h)
            printf '%s\n' \
                'Usage: setup_hermes.bash init|register --runtime DIR --workspace DIR [--profile NAME] [--state DIR]' \
                'Prepare: setup_hermes.bash prepare --runtime DIR --workspace DIR [--state DIR] [--revision PIN] [--dry-run]' \
                'Doctor: setup_hermes.bash doctor [--profile NAME]' \
                'Runtime must be an installed Hermes checkout with .venv/bin/python.' \
                'Existing profiles are never overwritten. Paths must be canonical and absolute.' \
                'Default state: ~/.local/share/hermes-sandbox/profiles/NAME'
            exit 0
            ;;
        *)
            printf 'ERROR: unknown setup option: %s\n' "${1}" >&2
            exit 2
            ;;
    esac
done

if [[ "$(uname -s)" != "Linux" ]]; then
    printf 'ERROR: Hermes sandboxing requires Linux.\n' >&2
    exit 78
fi
if [[ "${action}" == "doctor" ]]; then
    python3 -I "${WRAPPER_DIR}/ai_wrapper_data/hermes_sandbox/profile.py" doctor --profile "${profile}"
    exit $?
fi
if [[ -z "${runtime}" || -z "${workspace}" ]]; then
    printf 'ERROR: --runtime and --workspace are required.\n' >&2
    exit 2
fi
state="${state:-${HOME}/.local/share/hermes-sandbox/profiles/${profile}}"
if [[ "${action}" == "prepare" ]]; then
    provision="${WRAPPER_DIR}/ai_wrapper_data/hermes_sandbox/provision.py"
    if [[ ! -f "${provision}" ]]; then
        printf 'ERROR: Hermes provisioning module is not installed.\n' >&2
        exit 78
    fi
    provision_args=(prepare --runtime "${runtime}" --revision "${revision}" --workspace "${workspace}" --state "${state}")
    [[ "${dry_run}" == "1" ]] && provision_args+=(--dry-run)
    python3 -I "${provision}" "${provision_args[@]}"
    [[ "${dry_run}" == "1" ]] && exit 0
elif [[ "${dry_run}" == "1" ]]; then
    printf 'ERROR: --dry-run is supported only with prepare.\n' >&2
    exit 2
fi
python3 -I "${WRAPPER_DIR}/ai_wrapper_data/hermes_sandbox/profile.py" init \
    --profile "${profile}" --runtime "${runtime}" --state "${state}" --workspace "${workspace}"
