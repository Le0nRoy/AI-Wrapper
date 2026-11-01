#!/bin/bash
# shellcheck disable=SC2034,SC2163  # export "$@" takes NAME=VALUE pairs
# Linux user runtime dir (#63): the host $XDG_RUNTIME_DIR is not bound into
# the sandbox. The sandbox gets a private 0700 runtime dir (the host path
# when that is safe, else /run/user/UID), exported as XDG_RUNTIME_DIR
# after --clearenv, even when the host value is unset or invalid. Only
# named sockets are shared: the SSH agent at its exact path
# (AI_SANDBOX_PASS_SSH_AGENT) and the rootless Docker / Podman sockets
# (AI_SANDBOX_ALLOW_DOCKER). AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1 restores the
# RW bind of the validated host dir, with a warning; invalid input then
# fails the launch. Also checks that the agy trust analysis
# (_agy_path_sandbox_writable) follows the same rules.
#
# Three layers: _agy_path_sandbox_writable (pure logic, Linux and macOS),
# then on Linux only bwrap argv through a stub bwrap/sysctl, and native
# bubblewrap probes that talk to synthetic UNIX socket servers (a missing
# bwrap fails). Synthetic fake HOME and runtime dirs under /tmp only; the
# host session's runtime dir, buses and agents are never touched, and no
# real client is launched (isolate_test_env traps every client name).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

OS="$(uname -s)"
# Resolve the real bwrap before the stub dir shadows it on PATH.
REAL_BWRAP="$(type -P bwrap || true)"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
STUB_DIR="$(mktemp -d)"
isolate_test_env "${FAKE_HOME}"
# Synthetic runtime dirs: RT below /tmp (reused as the sandbox path),
# OUT_RT for SSH sockets outside the runtime dir, WD_RT for a WORKDIR
# overlap. mktemp -d creates them 0700 and owned by the test user.
RT="$(mktemp -d /tmp/ai-wrapper-rt.XXXXXX)"
RT="$(cd "${RT}" && pwd -P)"
OUT_RT="$(mktemp -d /tmp/ai-wrapper-ssh.XXXXXX)"
OUT_RT="$(cd "${OUT_RT}" && pwd -P)"
WD_RT="$(mktemp -d /tmp/ai-wrapper-wdrt.XXXXXX)"
WD_RT="$(cd "${WD_RT}" && pwd -P)"
SERVER_PIDS=()
cleanup() {
    local pid
    for pid in "${SERVER_PIDS[@]+"${SERVER_PIDS[@]}"}"; do kill "${pid}" 2>/dev/null; done
    rm -rf "${FAKE_HOME}" "${STUB_DIR}" "${RT}" "${OUT_RT}" "${WD_RT}"
}
trap cleanup EXIT

RUN_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
H="${FAKE_HOME}"
WORK="${H}/project-${RUN_ID}"
# HOME_RT: a runtime dir the sandbox cannot reuse (not below /run or /tmp).
HOME_RT="${H}/rt-${RUN_ID}"
mkdir -p "${WORK}" "${HOME_RT}"
chmod 0700 "${HOME_RT}"
ln -s "${RT}" "${H}/rt-link-${RUN_ID}"
UID_NUM="$(id -u)"
SYNTH_RT="/run/user/${UID_NUM}"
NL=$'\n'
_yes() { if "$@"; then echo yes; else echo no; fi; }

_load_linux() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
}

echo "== Linux user runtime dir (${OS}) =="

# ---------------------------------------------------------------------------
echo "-- agy trust analysis: host runtime dir is not a default RW root"
_writable() {
    # $1: path, $2: OS for _wrapper_os, rest: NAME=VALUE env.
    local path="${1}" os="${2}"; shift 2
    (
        { cd "${WORK}" && export "$@" && _load_linux \
            && source "${REPO_ROOT}/bin/ai_wrapper_data/agy_wrapper_lib.bash"; } >/dev/null 2>&1 \
            || { echo LOAD_FAILED; exit 0; }
        _wrapper_os="${os}"; WRAPPER_FLAGS=()
        if _agy_path_sandbox_writable "${path}" "${H}/.gemini" 2>/dev/null; then echo yes; else echo no; fi
    )
}
# HOME_RT (not RT): on macOS /tmp is a shared RW temp root anyway.
for os in Linux Darwin; do
    assert_eq "$(_writable "${HOME_RT}/sub" "${os}" XDG_RUNTIME_DIR="${HOME_RT}")" no \
        "${os}: host runtime dir not writable by default"
    assert_eq "$(_writable "${HOME_RT}/sub" "${os}" XDG_RUNTIME_DIR="${HOME_RT}" \
        AI_SANDBOX_EXTRA_RW_DIRS="${HOME_RT}")" yes "${os}: explicit RW extra over the runtime dir still counts"
done
assert_eq "$(_writable "${HOME_RT}/sub" Linux XDG_RUNTIME_DIR="${HOME_RT}" AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1)" yes \
    "Linux: ALLOW_XDG_RUNTIME_RW=1 makes the host runtime dir writable"
assert_eq "$(_writable "${RT}/sub" Linux XDG_RUNTIME_DIR="${H}/rt-link-${RUN_ID}" AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1)" yes \
    "Linux: ALLOW_XDG_RUNTIME_RW=1 via a symlink alias covers the canonical dir"
assert_eq "$(_writable "${HOME_RT}/sub" Linux XDG_RUNTIME_DIR="${HOME_RT}" AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=yes)" no \
    "Linux: non-1 toggle value grants nothing"
assert_eq "$(_writable "${HOME_RT}/sub" Darwin XDG_RUNTIME_DIR="${HOME_RT}" AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1)" no \
    "Darwin: Linux-only toggle grants nothing"
assert_eq "$(_writable "${WORK}/rt/sub" Linux XDG_RUNTIME_DIR="${WORK}/rt")" yes \
    "Linux: a runtime dir inside WORKDIR stays writable (WORKDIR grant)"
assert_eq "$(_writable "${H}/missing-rt-${RUN_ID}/sub" Linux XDG_RUNTIME_DIR="${H}/missing-rt-${RUN_ID}" \
    AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1)" no "Linux: missing runtime dir is not a root"
assert_eq "$(_yes test -e "${H}/missing-rt-${RUN_ID}")" no "missing runtime dir is not created on the host"

# ---------------------------------------------------------------------------
if [[ "${OS}" != "Linux" ]]; then
    echo "  skip - bwrap argv and native probes are Linux-only"
    tests_summary_and_exit
fi

# Stub bwrap: records one argv entry per line. Stub sysctl: userns enabled.
ARGV_FILE="${STUB_DIR}/argv"
cat >"${STUB_DIR}/bwrap" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"${ARGV_FILE}"
STUB
cat >"${STUB_DIR}/sysctl" <<'STUB'
#!/bin/bash
echo "kernel.unprivileged_userns_clone = 1"
STUB
chmod +x "${STUB_DIR}/bwrap" "${STUB_DIR}/sysctl"

# Run the Linux backend through the stubs from DIR; sets ARGV (bwrap argv,
# one per line; empty when bwrap was not reached), OUT (wrapper log) and
# RC. Extra env assignments go in "$@" (NAME=VALUE ...).
_run_in() {
    local dir="${1}"; shift
    rm -f "${ARGV_FILE}"
    OUT="$( cd "${dir}" && export PATH="${STUB_DIR}:${PATH}" "$@" && _load_linux \
        && _run_sandboxed_agent_linux true -- -- 2>&1 )"
    RC=$?
    ARGV="$(cat "${ARGV_FILE}" 2>/dev/null)"
}
_run() { _run_in "${WORK}" "$@"; }

# Succeeds when ARGV holds the given entries consecutively.
_has_seq() {
    local seq="" item
    for item in "$@"; do seq+="${item}${NL}"; done
    [[ "${NL}${ARGV}${NL}" == *"${NL}${seq}"* ]]
}
# Line of the first `--setenv NAME`, or 0.
_setenv_idx() { awk -v n="${1}" 'prev == "--setenv" && $0 == n { print NR; exit } { prev = $0 }' <<<"${ARGV}" | grep . || echo 0; }
_setenv_count() { awk -v n="${1}" 'prev == "--setenv" && $0 == n { c++ } { prev = $0 } END { print c + 0 }' <<<"${ARGV}"; }
_setenv_value() { awk -v n="${1}" 'p2 == "--setenv" && p1 == n { print; exit } { p2 = p1; p1 = $0 }' <<<"${ARGV}"; }
_clearenv_idx() { grep -nxF -- --clearenv <<<"${ARGV}" | head -1 | cut -d: -f1; }

echo "-- bwrap argv: private runtime dir by default"
_run XDG_RUNTIME_DIR="${RT}"
assert_contains "${ARGV}" "--die-with-parent" "stubbed bwrap captured an argv"
assert_eq "$(_yes _has_seq --bind "${RT}" "${RT}")" no "host runtime dir not bound RW"
assert_eq "$(_yes _has_seq --ro-bind "${RT}" "${RT}")" no "host runtime dir not bound RO either"
assert_eq "$(_yes _has_seq --perms 0700 --dir "${RT}")" yes "private 0700 runtime dir at the host path"
assert_eq "$(_setenv_value XDG_RUNTIME_DIR)" "${RT}" "XDG_RUNTIME_DIR exported as the private dir"
assert_eq "$(_setenv_count XDG_RUNTIME_DIR)" 1 "XDG_RUNTIME_DIR exported once"
assert_eq "$(_yes test "$(_setenv_idx XDG_RUNTIME_DIR)" -gt "$(_clearenv_idx)")" yes \
    "XDG_RUNTIME_DIR set after --clearenv"
first_setenv="$(grep -nxF -- --setenv <<<"${ARGV}" | head -1 | cut -d: -f1)"
assert_eq "$(_yes test "${first_setenv:-0}" -gt "$(_clearenv_idx)")" yes "no --setenv precedes --clearenv"
assert_not_contains "${OUT}" "WARNING" "protected default logs no warning"

echo "-- bwrap argv: unset, empty and invalid host values get /run/user/UID"
for value in UNSET "" "rel/rt-${RUN_ID}" "${H}/missing-rt-${RUN_ID}" / /etc "${H}/.bashrc-${RUN_ID}"; do
    label="${value:-<empty>}"
    if [[ "${value}" == UNSET ]]; then _run _NOOP=1; else _run XDG_RUNTIME_DIR="${value}"; fi
    assert_eq "${RC}" 0 "${label}: launch proceeds"
    assert_eq "$(_yes _has_seq --perms 0700 --dir "${SYNTH_RT}")" yes "${label}: private ${SYNTH_RT}"
    assert_eq "$(_setenv_value XDG_RUNTIME_DIR)" "${SYNTH_RT}" "${label}: XDG_RUNTIME_DIR=${SYNTH_RT}"
    if [[ "${value}" == /* ]]; then
        assert_eq "$(_yes _has_seq --bind "${value}" "${value}")" no "${label}: host value not bound"
    fi
done
assert_eq "$(_yes test -e "${H}/missing-rt-${RUN_ID}")" no "missing runtime dir not created on the host"
_run XDG_RUNTIME_DIR="${H}/missing-rt-${RUN_ID}"
assert_contains "${OUT}" "private ${SYNTH_RT}" "invalid host value logs the private fallback"

echo "-- bwrap argv: symlink alias and non-reusable host paths"
_run XDG_RUNTIME_DIR="${H}/rt-link-${RUN_ID}"
assert_eq "$(_yes _has_seq --perms 0700 --dir "${RT}")" yes "alias: private dir at the canonical path"
assert_eq "$(_setenv_value XDG_RUNTIME_DIR)" "${RT}" "alias: canonical path exported"
assert_not_contains "${ARGV}" "${H}/rt-link-${RUN_ID}" "alias: symlink path not mounted"
_run XDG_RUNTIME_DIR="${HOME_RT}"
assert_eq "$(_yes _has_seq --perms 0700 --dir "${SYNTH_RT}")" yes "runtime dir under HOME: private ${SYNTH_RT}"
assert_not_contains "${ARGV}" "${HOME_RT}" "runtime dir under HOME: not mounted"
# WORKDIR inside / above the runtime dir: --dir there would reuse a
# host-backed directory, so the sandbox uses /run/user/UID instead.
mkdir -p "${WD_RT}/proj"
_run_in "${WD_RT}/proj" XDG_RUNTIME_DIR="${WD_RT}"
assert_eq "$(_yes _has_seq --perms 0700 --dir "${SYNTH_RT}")" yes "WORKDIR inside runtime dir: private ${SYNTH_RT}"
assert_eq "$(_yes _has_seq --dir "${WD_RT}")" no "WORKDIR inside runtime dir: no --dir on the host-backed path"
_run_in "${WD_RT}" XDG_RUNTIME_DIR="${WD_RT}/proj"
assert_eq "$(_yes _has_seq --perms 0700 --dir "${SYNTH_RT}")" yes "runtime dir inside WORKDIR: private ${SYNTH_RT}"
assert_eq "$(_yes _has_seq --dir "${WD_RT}/proj")" no "runtime dir inside WORKDIR: no --dir on the host-backed path"

# Synthetic socket servers: reply "<tag>:<what they received>".
SERVER_PY='
import socket, sys
path, tag = sys.argv[1], sys.argv[2].encode()
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(16)
while True:
    c, _ = s.accept()
    try:
        c.sendall(tag + b":" + c.recv(64))
    finally:
        c.close()
'
SOCKETS_OK=1
_serve() {
    local path="${1}" tag="${2}"
    mkdir -p "$(dirname "${path}")"
    python3 -I -c "${SERVER_PY}" "${path}" "${tag}" &
    SERVER_PIDS+=($!)
    for _ in $(seq 1 50); do [[ -S "${path}" ]] && return 0; sleep 0.1; done
    SOCKETS_OK=0
}
if ! command -v python3 >/dev/null 2>&1; then
    _test_report 0 "python3 available for the synthetic socket servers"
    tests_summary_and_exit
fi
_serve "${RT}/bus" "bus-${RUN_ID}"
_serve "${RT}/systemd/private" "systemd-${RUN_ID}"
_serve "${RT}/docker.sock" "docker-${RUN_ID}"
_serve "${RT}/podman/podman.sock" "podman-${RUN_ID}"
_serve "${RT}/ssh-agent.socket" "ssh-${RUN_ID}"
_serve "${OUT_RT}/agent.sock" "outssh-${RUN_ID}"
_serve "${HOME_RT}/docker.sock" "homedocker-${RUN_ID}"
assert_eq "${SOCKETS_OK}" 1 "synthetic socket servers listening"

echo "-- bwrap argv: named socket grants"
_run XDG_RUNTIME_DIR="${RT}"
for s in bus systemd/private docker.sock podman/podman.sock ssh-agent.socket; do
    assert_not_contains "${ARGV}" "${RT}/${s}" "default: ${s} not mounted"
done
assert_eq "$(_setenv_count SSH_AUTH_SOCK)" 0 "default: SSH_AUTH_SOCK not passed"
_run XDG_RUNTIME_DIR="${RT}" AI_SANDBOX_ALLOW_DOCKER=1
assert_eq "$(_yes _has_seq --bind "${RT}/docker.sock" "${RT}/docker.sock")" yes "ALLOW_DOCKER=1: rootless Docker socket bound"
assert_eq "$(_yes _has_seq --bind "${RT}/podman/podman.sock" "${RT}/podman/podman.sock")" yes \
    "ALLOW_DOCKER=1: rootless Podman socket bound"
dir_idx="$(grep -nxF -- "${RT}" <<<"${ARGV}" | head -1 | cut -d: -f1)"
sock_idx="$(grep -nxF -- "${RT}/docker.sock" <<<"${ARGV}" | head -1 | cut -d: -f1)"
assert_eq "$(_yes test "${dir_idx:-0}" -gt 0 -a "${dir_idx:-0}" -lt "${sock_idx:-0}")" yes \
    "private dir created before the socket binds inside it"
for s in bus systemd/private ssh-agent.socket; do
    assert_not_contains "${ARGV}" "${RT}/${s}" "ALLOW_DOCKER=1: ${s} not mounted"
done
assert_eq "$(_setenv_count DOCKER_HOST)" 0 "ALLOW_DOCKER=1 alone passes no DOCKER_HOST (PASS_DOCKER is separate)"
_run XDG_RUNTIME_DIR="${RT}" AI_SANDBOX_PASS_DOCKER=1 DOCKER_HOST="unix://${RT}/docker.sock"
assert_eq "$(_setenv_value DOCKER_HOST)" "unix://${RT}/docker.sock" "PASS_DOCKER=1 passes DOCKER_HOST unchanged"
assert_not_contains "${ARGV}" "--bind${NL}${RT}/docker.sock" "PASS_DOCKER=1 alone shares no socket"
_run XDG_RUNTIME_DIR="${HOME_RT}" AI_SANDBOX_ALLOW_DOCKER=1 AI_SANDBOX_PASS_DOCKER=1 DOCKER_HOST="unix://${HOME_RT}/docker.sock"
assert_eq "$(_yes _has_seq --bind "${HOME_RT}/docker.sock" "${SYNTH_RT}/docker.sock")" yes \
    "non-reusable runtime dir: socket bound into ${SYNTH_RT}"
assert_eq "$(_setenv_value DOCKER_HOST)" "unix://${SYNTH_RT}/docker.sock" "non-reusable runtime dir: DOCKER_HOST follows the bind"
_run XDG_RUNTIME_DIR="${HOME_RT}" AI_SANDBOX_PASS_DOCKER=1 DOCKER_HOST="unix://${HOME_RT}/docker.sock"
assert_eq "$(_setenv_value DOCKER_HOST)" "unix://${HOME_RT}/docker.sock" "DOCKER_HOST not rewritten when no socket is shared"
# Not a socket / a symlink to a socket: never bound.
SOCK_RT="$(mktemp -d /tmp/ai-wrapper-rt.XXXXXX)"
echo x >"${SOCK_RT}/docker.sock"
mkdir -p "${SOCK_RT}/podman" && ln -s "${RT}/podman/podman.sock" "${SOCK_RT}/podman/podman.sock"
_run XDG_RUNTIME_DIR="${SOCK_RT}" AI_SANDBOX_ALLOW_DOCKER=1
assert_not_contains "${ARGV}" "${SOCK_RT}/docker.sock" "regular file named docker.sock not bound"
assert_not_contains "${ARGV}" "${SOCK_RT}/podman/podman.sock" "symlinked podman.sock not bound"
rm -rf "${SOCK_RT}"
_run XDG_RUNTIME_DIR="${RT}" AI_SANDBOX_PASS_SSH_AGENT=1 SSH_AUTH_SOCK="${RT}/ssh-agent.socket"
assert_eq "$(_yes _has_seq --bind "${RT}/ssh-agent.socket" "${RT}/ssh-agent.socket")" yes "PASS_SSH_AGENT=1: agent socket at its exact path"
assert_eq "$(_setenv_value SSH_AUTH_SOCK)" "${RT}/ssh-agent.socket" "PASS_SSH_AGENT=1: SSH_AUTH_SOCK passed"
assert_not_contains "${ARGV}" "${RT}/docker.sock" "PASS_SSH_AGENT=1: Docker socket not mounted"
_run XDG_RUNTIME_DIR="${RT}" SSH_AUTH_SOCK="${RT}/ssh-agent.socket"
assert_not_contains "${ARGV}" "${RT}/ssh-agent.socket" "SSH_AUTH_SOCK alone (PASS_SSH_AGENT off) shares nothing"

echo "-- bwrap argv: broad override"
_run XDG_RUNTIME_DIR="${RT}" AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1
assert_eq "${RC}" 0 "broad: launch proceeds"
assert_eq "$(_yes _has_seq --bind "${RT}" "${RT}")" yes "broad: host runtime dir bound RW"
assert_eq "$(_yes _has_seq --dir "${RT}")" no "broad: no private --dir over the host dir"
assert_eq "$(_setenv_value XDG_RUNTIME_DIR)" "${RT}" "broad: XDG_RUNTIME_DIR exported"
assert_eq "$(_yes test "$(_setenv_idx XDG_RUNTIME_DIR)" -gt "$(_clearenv_idx)")" yes "broad: set after --clearenv"
assert_contains "${OUT}" "WARNING" "broad: launch warning logged"
assert_contains "${OUT}" "AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1" "broad: warning names the setting"
_run XDG_RUNTIME_DIR="${H}/rt-link-${RUN_ID}" AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1
assert_eq "$(_yes _has_seq --bind "${RT}" "${RT}")" yes "broad alias: canonical dir bound"
_run XDG_RUNTIME_DIR="${HOME_RT}" AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1
assert_eq "$(_yes _has_seq --bind "${HOME_RT}" "${HOME_RT}")" yes "broad: legitimate non-/run runtime dir kept"
WRITABLE_RT="$(mktemp -d /tmp/ai-wrapper-rt.XXXXXX)"
chmod 0777 "${WRITABLE_RT}"
mkdir -p "${H}/.cfg-${RUN_ID}"
REAL_PARENT="$(dirname "${H}")"
for value in UNSET "" "rel/rt" "${H}/missing-rt-${RUN_ID}" / /etc /run "${H}" "${H}/.cfg-${RUN_ID}" \
        "${REAL_PARENT}" "${WRITABLE_RT}"; do
    label="${value:-<empty>}"
    if [[ "${value}" == UNSET ]]; then
        _run AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1
    else
        _run XDG_RUNTIME_DIR="${value}" AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1
    fi
    assert_eq "$(_yes test "${RC}" -ne 0)" yes "broad refuses ${label}"
    assert_eq "${ARGV}" "" "broad ${label}: bwrap not launched"
    assert_contains "${OUT}" "AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1 but the host runtime directory cannot be shared" \
        "broad ${label}: diagnostic names the problem"
done
assert_eq "$(_yes test -e "${H}/missing-rt-${RUN_ID}")" no "broad: missing runtime dir not created"
rm -rf "${WRITABLE_RT}" "${H}/.cfg-${RUN_ID}"

# ---------------------------------------------------------------------------
echo "-- native bubblewrap probes"
# Native certification: on Linux a missing bwrap is a failure, not a skip
# (CI smoke-linux installs bubblewrap).
if [[ -z "${REAL_BWRAP}" ]]; then
    _test_report 0 "native probes: bubblewrap (bwrap) available on Linux"
    tests_summary_and_exit
fi

# Client: talk NAME PATH -> OK:NAME:<reply> or DENIED:NAME:<error>.
cat >"${WORK}/client.py" <<'PY'
import socket, sys
name, path = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(path)
    s.sendall(b"ping")
    print("OK:%s:%s" % (name, s.recv(64).decode()))
except OSError as e:
    print("DENIED:%s:%s" % (name, type(e).__name__))
PY
# Creates a listening socket at PATH (the sandbox's own runtime dir).
cat >"${WORK}/listen.py" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)
print("LISTEN_OK")
PY
PROBE_HEAD="talk() { python3 -I ${WORK}/client.py \"\$1\" \"\$2\"; }"
# _native_in DIR SCRIPT [NAME=VALUE...]: runs SCRIPT with bash in a sandbox
# launched from DIR (the script is written there, so it is always visible).
_native_in() {
    local dir="${1}" script="${2}" probe="${1}/probe-${RUN_ID}.sh"; shift 2
    printf '%s\n%s\necho PROBES_DONE\n' "${PROBE_HEAD}" "${script}" >"${probe}"
    ( cd "${dir}" && export "$@" && _load_linux \
        && _run_sandboxed_agent_linux /bin/bash -- -- "${probe}" ) 2>&1
    rm -f "${probe}"
}
_native() { _native_in "${WORK}" "$@"; }

ALL_TALK="talk bus ${RT}/bus
talk systemd ${RT}/systemd/private
talk docker ${RT}/docker.sock
talk podman ${RT}/podman/podman.sock
talk ssh ${RT}/ssh-agent.socket
talk outssh ${OUT_RT}/agent.sock"
canary="canary-${RUN_ID}"

# Default: private runtime dir, no host socket reachable.
out="$(_native "echo \"ENV:XDG=\${XDG_RUNTIME_DIR:-<unset>}\"
echo \"ENV:SSH=\${SSH_AUTH_SOCK:-<unset>}\"
echo \"STAT:\$(stat -c '%a %u' \"\${XDG_RUNTIME_DIR}\")\"
echo \"LS:\$(ls -A \"\${XDG_RUNTIME_DIR}\" | tr '\n' ' ')\"
echo private >\"\${XDG_RUNTIME_DIR}/${canary}\" && echo FILE_OK
python3 -I ${WORK}/listen.py \"\${XDG_RUNTIME_DIR}/${canary}.sock\"
${ALL_TALK}" XDG_RUNTIME_DIR="${RT}")"
assert_contains "${out}" "PROBES_DONE" "default: probe client ran"
assert_contains "${out}" "ENV:XDG=${RT}" "default: XDG_RUNTIME_DIR reaches the client"
assert_contains "${out}" "ENV:SSH=<unset>" "default: no SSH_AUTH_SOCK"
assert_contains "${out}" "STAT:700 ${UID_NUM}" "default: runtime dir is 0700 and owned by the user"
assert_contains "${out}" "LS:${NL}" "default: runtime dir starts empty"
assert_contains "${out}" "FILE_OK" "default: client can create files in its runtime dir"
assert_contains "${out}" "LISTEN_OK" "default: client can create sockets in its runtime dir"
for s in bus systemd docker podman ssh outssh; do
    assert_contains "${out}" "DENIED:${s}:" "default: ${s} socket unreachable"
done
assert_not_contains "${out}" "-${RUN_ID}:ping" "default: no synthetic daemon answered"
assert_eq "$(_yes test -e "${RT}/${canary}")" no "default: runtime file does not leak to the host"
assert_eq "$(_yes test -e "${RT}/${canary}.sock")" no "default: runtime socket does not leak to the host"

# Unset host value: synthetic /run/user/UID, same properties.
out="$(_native "echo \"ENV:XDG=\${XDG_RUNTIME_DIR:-<unset>}\"
echo \"STAT:\$(stat -c '%a %u' \"\${XDG_RUNTIME_DIR}\")\"
echo ok >\"\${XDG_RUNTIME_DIR}/${canary}\" && echo FILE_OK" _NOOP=1)"
assert_contains "${out}" "ENV:XDG=${SYNTH_RT}" "unset: XDG_RUNTIME_DIR=${SYNTH_RT}"
assert_contains "${out}" "STAT:700 ${UID_NUM}" "unset: runtime dir is 0700 and owned by the user"
assert_contains "${out}" "FILE_OK" "unset: runtime dir writable"

# SSH agent opt-in: exactly the agent socket, inside and outside the runtime dir.
out="$(_native "echo \"ENV:SSH=\${SSH_AUTH_SOCK:-<unset>}\"
talk agent \"\${SSH_AUTH_SOCK}\"
${ALL_TALK}" XDG_RUNTIME_DIR="${RT}" AI_SANDBOX_PASS_SSH_AGENT=1 SSH_AUTH_SOCK="${RT}/ssh-agent.socket")"
assert_contains "${out}" "ENV:SSH=${RT}/ssh-agent.socket" "PASS_SSH_AGENT=1: SSH_AUTH_SOCK reaches the client"
assert_contains "${out}" "OK:agent:ssh-${RUN_ID}:ping" "PASS_SSH_AGENT=1: agent reachable via SSH_AUTH_SOCK"
for s in bus systemd docker podman outssh; do
    assert_contains "${out}" "DENIED:${s}:" "PASS_SSH_AGENT=1: ${s} socket unreachable"
done
out="$(_native "talk agent \"\${SSH_AUTH_SOCK}\"
talk bus ${RT}/bus" XDG_RUNTIME_DIR="${RT}" AI_SANDBOX_PASS_SSH_AGENT=1 SSH_AUTH_SOCK="${OUT_RT}/agent.sock")"
assert_contains "${out}" "OK:agent:outssh-${RUN_ID}:ping" "PASS_SSH_AGENT=1: agent outside the runtime dir reachable"
assert_contains "${out}" "DENIED:bus:" "PASS_SSH_AGENT=1 (outside): bus unreachable"

# Rootless Docker + Podman opt-in.
out="$(_native "talk dockerenv \"\${DOCKER_HOST#unix://}\"
talk podmandefault \"\${XDG_RUNTIME_DIR}/podman/podman.sock\"
${ALL_TALK}" XDG_RUNTIME_DIR="${RT}" AI_SANDBOX_ALLOW_DOCKER=1 AI_SANDBOX_PASS_DOCKER=1 DOCKER_HOST="unix://${RT}/docker.sock")"
assert_contains "${out}" "OK:dockerenv:docker-${RUN_ID}:ping" "ALLOW_DOCKER=1: rootless Docker reachable via DOCKER_HOST"
assert_contains "${out}" "OK:podmandefault:podman-${RUN_ID}:ping" "ALLOW_DOCKER=1: rootless Podman at its default endpoint"
for s in bus systemd ssh outssh; do
    assert_contains "${out}" "DENIED:${s}:" "ALLOW_DOCKER=1: ${s} socket unreachable"
done
out="$(_native "talk dockerenv \"\${DOCKER_HOST#unix://}\"
echo \"ENV:XDG=\${XDG_RUNTIME_DIR}\"
echo \"VISIBLE:\$(test -e ${HOME_RT} && echo yes || echo no)\"" XDG_RUNTIME_DIR="${HOME_RT}" \
    AI_SANDBOX_ALLOW_DOCKER=1 AI_SANDBOX_PASS_DOCKER=1 DOCKER_HOST="unix://${HOME_RT}/docker.sock")"
assert_contains "${out}" "ENV:XDG=${SYNTH_RT}" "non-reusable runtime dir: private ${SYNTH_RT}"
assert_contains "${out}" "OK:dockerenv:homedocker-${RUN_ID}:ping" "non-reusable runtime dir: DOCKER_HOST reaches the bound socket"
assert_contains "${out}" "VISIBLE:no" "non-reusable runtime dir: host dir not visible"

# WORKDIR inside the runtime dir: private dir elsewhere, host dir untouched.
mkdir -p "${WD_RT}/proj"
before="$(stat -c '%a' "${WD_RT}")"
out="$(_native_in "${WD_RT}/proj" "echo \"ENV:XDG=\${XDG_RUNTIME_DIR}\"
echo x >\"\${XDG_RUNTIME_DIR}/${canary}\" && echo FILE_OK" XDG_RUNTIME_DIR="${WD_RT}")"
assert_contains "${out}" "ENV:XDG=${SYNTH_RT}" "WORKDIR inside runtime dir: private ${SYNTH_RT}"
assert_contains "${out}" "FILE_OK" "WORKDIR inside runtime dir: private dir writable"
assert_eq "$(_yes test -e "${WD_RT}/${canary}")" no "WORKDIR inside runtime dir: no write to the host runtime dir"
assert_eq "$(stat -c '%a' "${WD_RT}")" "${before}" "WORKDIR inside runtime dir: host mode unchanged"

# Broad override: the host tree, its sockets and writes are shared.
out="$(_native "echo \"ENV:XDG=\${XDG_RUNTIME_DIR}\"
echo broad >\"\${XDG_RUNTIME_DIR}/${canary}\" && echo FILE_OK
${ALL_TALK}" XDG_RUNTIME_DIR="${RT}" AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1)"
assert_contains "${out}" "WARNING" "broad: launch warning"
assert_contains "${out}" "ENV:XDG=${RT}" "broad: XDG_RUNTIME_DIR reaches the client"
assert_contains "${out}" "OK:bus:bus-${RUN_ID}:ping" "broad: session bus reachable"
assert_contains "${out}" "OK:docker:docker-${RUN_ID}:ping" "broad: Docker socket reachable without ALLOW_DOCKER"
assert_contains "${out}" "DENIED:outssh:" "broad: sockets outside the runtime dir still unreachable"
assert_eq "$(cat "${RT}/${canary}" 2>/dev/null)" "broad" "broad: runtime dir write persists on the host"
rm -f "${RT}/${canary}"

assert_no_live_client_reached
tests_summary_and_exit
