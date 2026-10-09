#!/bin/bash

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${REPO_ROOT}/tests/lib_test_helpers.bash"
REAL_BWRAP="$(command -v bwrap || true)"

if [[ "$(uname -s)" != "Linux" ]]; then
    printf 'Hermes wrapper tests require Linux; skipped.\n'
    exit 0
fi

_fixture() {
    case_root="$(mktemp -d "${TMPDIR:-/tmp}/hermes-wrapper.XXXXXXXX")" || exit 1
    trap 'rm -r -- "${case_root}"' EXIT
    export HOME="${case_root}/home"
    install="${case_root}/install/bin"
    mkdir -p "${HOME}" "${install}/ai_wrapper_data/hermes_sandbox" "${case_root}/stubs" "${HOME}/runtime" "${HOME}/workspace"
    cp "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash" "${REPO_ROOT}/bin/executable_hermes_wrapper.bash" "${REPO_ROOT}/bin/executable_setup_hermes.bash" "${install}/"
    cp "${REPO_ROOT}/bin/ai_wrapper_data/hermes_wrapper_lib.bash" "${install}/ai_wrapper_data/"
    cp "${REPO_ROOT}/bin/ai_wrapper_data/hermes_sandbox/profile.py" "${install}/ai_wrapper_data/hermes_sandbox/"
    python3 -m venv --without-pip "${HOME}/runtime/.venv" || exit 1
    printf 'raise RuntimeError("HOST_FALLBACK_EXECUTED")\n' >"${install}/ai_wrapper_data/hermes_sandbox/adapter.py"
    cat >"${install}/ai_wrapper_data/hermes_sandbox/frontends.py" <<'PY'
from contextlib import contextmanager
@contextmanager
def profile_owner(lock_directory, profile, kind, writable_roots=()):
    print("LEASE:" + kind, flush=True)
    yield
PY
    cat >"${case_root}/stubs/bwrap" <<'PY'
#!/usr/bin/python3
import os
import sys
for argument in sys.argv[1:]:
    print("ARG:" + argument)
for key in sorted(os.environ):
    print("ENV:" + key)
PY
    chmod 0700 "${case_root}/stubs/bwrap"
    cat >"${case_root}/stubs/systemd-run" <<'PY'
#!/usr/bin/python3
import os
import sys
for argument in sys.argv[1:sys.argv.index("--")]:
    print("BUDGET:" + argument, flush=True)
command = sys.argv[sys.argv.index("--") + 1:]
os.execv(command[0], command)
PY
    chmod 0700 "${case_root}/stubs/systemd-run"
    export PATH="${case_root}/stubs:${PATH}"
    bash "${install}/executable_setup_hermes.bash" init --runtime "${HOME}/runtime" --workspace "${HOME}/workspace" || exit 1
}

_policy_case() (
    _fixture
    mv "${HOME}/.config/hermes-sandbox/profiles/default.json" "${HOME}/.config/hermes-sandbox/profiles/team-profile.json"
    mv "${HOME}/.config/hermes-sandbox/profiles/default.token" "${HOME}/.config/hermes-sandbox/profiles/team-profile.token"
    mkdir -p "${HOME}/Android" "${HOME}/.ssh" "${HOME}/.kind" "${HOME}/kind_dot_kube" "${HOME}/bin" "${HOME}/other-state"
    printf 'echo PLUGIN_EXECUTED\n' >"${HOME}/plugin.bash"
    export OPENAI_API_KEY=SECRET_CONTROL_VALUE SSH_AUTH_SOCK="${HOME}/host-agent.sock" DISPLAY=:0 WAYLAND_DISPLAY=wayland-0
    export HERMES_PROFILE_NAME=HOST_PROFILE_OVERRIDE
    export AI_SANDBOX_PASS_ENV=OPENAI_API_KEY AI_SANDBOX_PASS_OPENAI=1 AI_SANDBOX_ALLOW_DOCKER=1 AI_SANDBOX_PASS_SSH_AGENT=1
    export AI_SANDBOX_EXTRA_RW_DIRS="${HOME}/other-state" AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 AI_WRAPPER_EXTRA_PROFILE="${HOME}/plugin.bash"
    export XDG_RUNTIME_DIR="${HOME}" BWRAP_STRICT=1 TZ=UTC
    printf '#!/bin/bash\necho LEGACY_SYSCTL_CALLED; exit 97\n' >"${case_root}/stubs/sysctl"
    chmod 0700 "${case_root}/stubs/sysctl"
    bash "${install}/executable_hermes_wrapper.bash" --profile team-profile chat 'a prompt with spaces'
)

out="$(_policy_case 2>&1)"; rc=$?
assert_eq "${rc}" "0" "dedicated Hermes profile launches without legacy preflight/settings"
assert_contains "${out}" $'ARG:HERMES_PROFILE_NAME\nARG:team-profile\n' "native profile identity matches the selected registry profile"
assert_not_contains "${out}" 'HOST_PROFILE_OVERRIDE' "native profile identity ignores inherited overrides"
for expected in 'ARG:--new-session' 'ARG:--unshare-user' 'ARG:--unshare-pid' 'ARG:--cap-drop' 'ARG:ALL' 'ARG:--clearenv' 'ARG:/opt/hermes-sandbox/adapter.py' 'ARG:a prompt with spaces' 'ARG:UTC'; do
    assert_contains "${out}" "${expected}" "Hermes launch contains ${expected}"
done
for forbidden in PLUGIN_EXECUTED LEGACY_SYSCTL_CALLED SECRET_CONTROL_VALUE SSH_AUTH_SOCK OPENAI_API_KEY WAYLAND_DISPLAY 'ARG::0' /run/docker.sock /run/dbus /run/systemd/resolve /other-state /Android /kind_dot_kube /home/bin; do
    assert_not_contains "${out}" "${forbidden}" "Hermes launch excludes ${forbidden}"
done
assert_not_contains "${out}" $'ARG:/etc\n' "whole host /etc is not mounted"
assert_contains "${out}" 'ENV:PATH' "bwrap host environment has its fixed system PATH"
assert_not_contains "${out}" 'ENV:HOME' "bwrap does not inherit host HOME"
assert_not_contains "${out}" 'ENV:AI_' "bwrap does not inherit sandbox settings"
assert_not_contains "${out}" 'LEASE:cli' "separate CLI sessions do not take a broad profile lease"
for budget in MemoryMax=6G CPUQuota=200% TasksMax=512; do
    assert_contains "${out}" "BUDGET:--property=${budget}" "interactive CLI enforces ${budget}"
done

_rejection_case() (
    _fixture
    for option in --no-sandbox --no-sandbox=1 --sandbox=none --disable-sandbox --profile=other; do
        bash "${install}/executable_hermes_wrapper.bash" "${option}" 2>&1
        printf 'REJECT_RC:%s\n' "$?"
    done
    bash "${install}/executable_hermes_wrapper.bash" --profile ../default chat 2>&1
    printf 'TRAVERSAL_RC:%s\n' "$?"
    bash "${install}/executable_hermes_wrapper.bash" _worker cron ../id 2>&1
    printf 'WORKER_RC:%s\n' "$?"
    source "${install}/ai_agent_universal_wrapper.bash"
    AI_SANDBOX_AGENT_PROFILE=unknown run_sandboxed_agent /bin/echo -- -- unsafe 2>&1
    printf 'PROFILE_RC:%s\n' "$?"
    uname() { printf 'Darwin\n'; }
    AI_SANDBOX_AGENT_PROFILE=hermes run_sandboxed_agent /bin/echo -- -- unsafe 2>&1
    printf 'MAC_RC:%s\n' "$?"
)

out="$(_rejection_case 2>&1)"
assert_contains "${out}" 'REJECT_RC:78' "sandbox-disabling and inner-profile flags are refused"
assert_contains "${out}" 'TRAVERSAL_RC:1' "profile traversal is refused before launch"
assert_contains "${out}" 'WORKER_RC:1' "worker traversal is refused before launch"
assert_contains "${out}" 'PROFILE_RC:78' "unknown profile has no default fallback"
assert_contains "${out}" 'MAC_RC:78' "Hermes profile refuses unsupported macOS"
assert_not_contains "${out}" 'ARG:--new-session' "refused requests never invoke bwrap"

_socket_case() (
    _fixture
    source "${install}/ai_agent_universal_wrapper.bash"
    source "${install}/ai_wrapper_data/hermes_wrapper_lib.bash"
    _hermes_resolve_profile default || exit 1
    snapshot="${case_root}/snapshot.json"
    printf '{}\n' >"${snapshot}"
    chmod 0400 "${snapshot}"
    _HERMES_SNAPSHOT="${snapshot}"
    _HERMES_CONTROL_SOCKET="${case_root}/control.sock"
    _HERMES_KIND=worker
    python3 -c 'import socket,sys; connection=socket.socket(socket.AF_UNIX); connection.bind(sys.argv[1]); connection.close()' "${_HERMES_CONTROL_SOCKET}"
    export AI_SANDBOX_AGENT_PROFILE=hermes
    run_sandboxed_agent "${AI_AGENT_COMMAND}" -- -- -I /opt/hermes-sandbox/adapter.py worker cron attempt-1
)

out="$(_socket_case 2>&1)"; rc=$?
assert_eq "${rc}" "0" "worker mount policy runs through the dedicated profile"
assert_contains "${out}" 'ARG:/run/hermes/worker.json' "worker snapshot destination is fixed"
assert_contains "${out}" 'ARG:/run/hermes/control.sock' "only broker socket destination is exposed"
assert_contains "${out}" 'ARG:HERMES_SANDBOX_CONTROL_SOCKET' "adapter receives the private broker socket contract"
assert_contains "${out}" 'ARG:/run/hermes/control.token' "only the active profile capability is mounted"
assert_contains "${out}" 'ARG:HERMES_SANDBOX_CONTROL_TOKEN_FILE' "capability file path is fixed"
assert_not_contains "${out}" 'ARG:/run/user/' "host runtime directory is not mounted"
assert_not_contains "${out}" 'LEASE:cli' "worker attempt does not take an exclusive CLI lease"

_setup_case() (
    _fixture
    bash "${install}/executable_setup_hermes.bash" doctor
    printf 'DOCTOR_RC:%s\n' "$?"
    bash "${install}/executable_setup_hermes.bash" register --runtime "${HOME}/runtime" --workspace "${HOME}/workspace"
    printf 'REGISTER_AGAIN_RC:%s\n' "$?"
    cat >"${install}/ai_wrapper_data/hermes_sandbox/provision.py" <<'PY'
import sys
print("PREPARE:" + " ".join(sys.argv[1:]))
raise SystemExit(0 if "--dry-run" in sys.argv else 37)
PY
    bash "${install}/executable_setup_hermes.bash" prepare --profile fresh --runtime "${HOME}/runtime" --workspace "${HOME}/workspace" --dry-run
    printf 'PREPARE_DRY_RC:%s\n' "$?"
    bash "${install}/executable_setup_hermes.bash" prepare --profile fresh --runtime "${HOME}/runtime" --workspace "${HOME}/workspace"
    printf 'PREPARE_FAIL_RC:%s\n' "$?"
    [[ ! -e "${HOME}/.config/hermes-sandbox/profiles/fresh.json" ]] && printf 'NO_PREPARE_REGISTRATION\n'
    printf 'pass\n' >"${install}/ai_wrapper_data/hermes_sandbox/addons.py"
    bash "${install}/executable_hermes_wrapper.bash" addons list
    printf 'ADDONS_RC:%s\n' "$?"
    bash "${install}/executable_hermes_wrapper.bash" addons install test --state /wrong
    printf 'ADDON_OVERRIDE_RC:%s\n' "$?"
)

out="$(_setup_case 2>&1)"
assert_contains "${out}" 'DOCTOR_RC:0' "doctor validates the real registered profile"
assert_contains "${out}" 'REGISTER_AGAIN_RC:1' "registration never overwrites an existing profile"
assert_contains "${out}" 'PREPARE_DRY_RC:0' "setup routes prepare dry-run"
assert_contains "${out}" '19cb1cbfedeafaca099be6ff0141a28a6c516c0f' "setup uses the pinned default revision"
assert_contains "${out}" 'PREPARE_FAIL_RC:37' "provision failure propagates without registration"
assert_contains "${out}" 'NO_PREPARE_REGISTRATION' "dry-run and failed provision do not create registry entries"
assert_contains "${out}" 'ARG:/opt/hermes-sandbox/addons.py' "addons execute inside the sandbox"
assert_contains "${out}" 'ADDONS_RC:0' "addon listing routes successfully"
assert_contains "${out}" 'ADDON_OVERRIDE_RC:78' "addon state cannot override its profile"

_failure_case() (
    _fixture
    printf '#!/bin/bash\nexit 43\n' >"${case_root}/stubs/bwrap"
    bash "${install}/executable_hermes_wrapper.bash" chat
    printf 'BWRAP_FAIL_RC:%s\n' "$?"
    rm "${install}/ai_wrapper_data/hermes_sandbox/adapter.py"
    bash "${install}/executable_hermes_wrapper.bash" chat
    printf 'ADAPTER_FAIL_RC:%s\n' "$?"
)

out="$(_failure_case 2>&1)"
assert_contains "${out}" 'BWRAP_FAIL_RC:43' "sandbox launch failures propagate"
assert_contains "${out}" 'ADAPTER_FAIL_RC:78' "missing adapter fails closed"
assert_not_contains "${out}" HOST_FALLBACK_EXECUTED "sandbox failure never executes adapter on the host"

_live_case() (
    _fixture
    rm "${case_root}/stubs/bwrap"
    export PATH="${case_root}/stubs:/usr/bin:/bin"
    export OPENAI_API_KEY=HOST_AUTH_SENTINEL
    printf 'host-only\n' >"${HOME}/host-marker"
    cat >"${install}/ai_wrapper_data/hermes_sandbox/adapter.py" <<'PY'
import os
from pathlib import Path
state = Path(os.environ["HERMES_HOME"])
workspace = Path(os.environ["HERMES_SANDBOX_WORKSPACE"])
runtime = Path(os.environ["HERMES_SANDBOX_RUNTIME"])
assert not (workspace.parent / "host-marker").exists()
assert not (workspace.parent / ".config/hermes-sandbox/profiles/default.json").exists()
assert not Path("/run/dbus").exists()
assert "OPENAI_API_KEY" not in os.environ
assert os.environ["HERMES_PROFILE_NAME"] == os.environ["HERMES_SANDBOX_PROFILE"] == "default"
(state / "state-write").write_text("allowed")
(workspace / "workspace-write").write_text("allowed")
try:
    (runtime / "runtime-write").write_text("denied")
except OSError:
    print("LIVE_RUNTIME_READONLY")
else:
    raise AssertionError("runtime unexpectedly writable")
print("LIVE_STATE_WORKSPACE_OK")
PY
    bash "${install}/executable_hermes_wrapper.bash" chat
    live_rc=$?
    [[ "${live_rc}" == "0" && -f "${HOME}/workspace/workspace-write" && -f "${HOME}/.local/share/hermes-sandbox/profiles/default/state-write" ]] && printf 'LIVE_HOST_SIDE_EFFECTS_OK\n'
    [[ ! -f "${HOME}/runtime/runtime-write" ]] || exit 98
    exit "${live_rc}"
)

if [[ -n "${REAL_BWRAP}" ]]; then
    out="$(_live_case 2>&1)"; rc=$?
    if [[ "${rc}" != "0" && ( "${out}" == *'Operation not permitted'* || "${out}" == *'No permissions to create'* ) ]]; then
        printf '  skip - live bubblewrap integration: namespace creation blocked in this environment\n'
        printf '%s\n' "${out}"
    else
        assert_eq "${rc}" "0" "live bubblewrap launches the isolated runtime fixture"
        assert_contains "${out}" LIVE_STATE_WORKSPACE_OK "live sandbox denies host sentinel and permits state/workspace writes"
        assert_contains "${out}" LIVE_RUNTIME_READONLY "live sandbox keeps runtime read-only"
        assert_contains "${out}" LIVE_HOST_SIDE_EFFECTS_OK "allowed writes persist only in approved host roots"
    fi
else
    printf '  skip - live bubblewrap integration: bubblewrap unavailable\n'
fi

tests_summary_and_exit
