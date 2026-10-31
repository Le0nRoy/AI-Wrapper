#!/bin/bash
# shellcheck disable=SC2088,SC2163  # "~/x" is display text in test names; export "$@" takes NAME=VALUE pairs
# Linux host-path gates (#62): ~/bin and the shared agent-skill source
# ~/ai-wrapper/.agents are read-only unless AI_SANDBOX_ALLOW_BIN_RW /
# AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW; ~/Android and the Tailscale daemon
# socket are absent unless AI_SANDBOX_ALLOW_ANDROID / AI_SANDBOX_PASS_TAILSCALE;
# Kind support is gone (~/.kind and ~/kind_dot_kube are never mounted,
# KIND_EXPERIMENTAL_PROVIDER is not passed); missing host paths are omitted
# and never created. Also checks that the agy trust analysis
# (_agy_path_sandbox_writable) follows the same grants.
#
# Three layers: bwrap argv through a stub bwrap/sysctl (Linux code path on
# any host with bash), _agy_path_sandbox_writable (pure logic, any OS), and
# native bubblewrap probes (denial + persistence of legitimate writes) when
# real bwrap is installed. Synthetic fake HOME only; no real client is ever
# launched (isolate_test_env traps every client name).
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
TAILSCALE_PID=""
cleanup() {
    [[ -n "${TAILSCALE_PID}" ]] && kill "${TAILSCALE_PID}" 2>/dev/null
    rm -rf "${FAKE_HOME}" "${STUB_DIR}"
}
trap cleanup EXIT

RUN_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
WORK="${FAKE_HOME}/project-${RUN_ID}"
mkdir -p "${WORK}" "${FAKE_HOME}/bin" "${FAKE_HOME}/ai-wrapper/.agents/skills" \
    "${FAKE_HOME}/.kind" "${FAKE_HOME}/kind_dot_kube" "${FAKE_HOME}/.kube"
echo "kind-cred-${RUN_ID}" >"${FAKE_HOME}/kind_dot_kube/config"
echo "kube-cred-${RUN_ID}" >"${FAKE_HOME}/.kube/config"

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

_load_linux() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
}

# Run the Linux backend through the stubs; prints the bwrap argv, one per
# line. Extra env assignments go in "$@" (NAME=VALUE ...).
_argv() {
    rm -f "${ARGV_FILE}"
    ( cd "${WORK}" && export PATH="${STUB_DIR}:${PATH}" "$@" && _load_linux \
        && _run_sandboxed_agent_linux true -- -- ) >/dev/null 2>&1
    cat "${ARGV_FILE}" 2>/dev/null
}

# Succeeds when argv (newline list) has FLAG SRC DST as consecutive entries.
_has_bind() {
    local argv="${1}" flag="${2}" src="${3}" dst="${4}"
    [[ "${NL}${argv}${NL}" == *"${NL}${flag}${NL}${src}${NL}${dst}${NL}"* ]]
}
NL=$'\n'
_yes() { if "$@"; then echo yes; else echo no; fi; }

echo "== Linux host-path gates (${OS}) =="
H="${FAKE_HOME}"

# ---------------------------------------------------------------------------
echo "-- agy trust analysis follows the grants"
_writable() {
    # $1: path, $2: OS for _wrapper_os, rest: NAME=VALUE env.
    local path="${1}" os="${2}"; shift 2
    (
        { cd "${WORK}" && export "$@" && _load_linux \
            && source "${REPO_ROOT}/bin/ai_wrapper_data/agy_wrapper_lib.bash"; } >/dev/null 2>&1 \
            || { echo LOAD_FAILED; exit 0; }
        _wrapper_os="${os}"; WRAPPER_FLAGS=()
        if _agy_path_sandbox_writable "${path}" "${FAKE_HOME}/.gemini" 2>/dev/null; then echo yes; else echo no; fi
    )
}
mkdir -p "${H}/Android/sub" "${H}/bin/sub" "${H}/ai-wrapper/.agents/skills/x" "${H}/kind_dot_kube/sub" "${H}/.kind/sub"
for os in Linux Darwin; do
    assert_eq "$(_writable "${H}/bin/sub" "${os}" _NOOP=1)" no "${os}: ~/bin not writable by default"
    assert_eq "$(_writable "${H}/ai-wrapper/.agents/skills/x" "${os}" _NOOP=1)" no "${os}: skills not writable by default"
    assert_eq "$(_writable "${H}/Android/sub" "${os}" _NOOP=1)" no "${os}: ~/Android not writable by default"
    assert_eq "$(_writable "${H}/kind_dot_kube/sub" "${os}" AI_SANDBOX_PASS_KUBE=1)" no "${os}: ~/kind_dot_kube never writable"
    assert_eq "$(_writable "${H}/.kind/sub" "${os}" AI_SANDBOX_PASS_KUBE=1)" no "${os}: ~/.kind never writable"
    assert_eq "$(_writable "${WORK}/x" "${os}" _NOOP=1)" yes "${os}: WORKDIR still writable"
    assert_eq "$(_writable "${H}/bin/sub" "${os}" AI_SANDBOX_EXTRA_RW_DIRS="${H}/bin")" yes \
        "${os}: explicit RW extra over ~/bin still counts"
done
assert_eq "$(_writable "${H}/bin/sub" Linux AI_SANDBOX_ALLOW_BIN_RW=1)" yes "Linux: ALLOW_BIN_RW=1 makes ~/bin writable"
assert_eq "$(_writable "${H}/ai-wrapper/.agents/skills/x" Linux AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW=1)" yes \
    "Linux: ALLOW_AGENTS_SKILLS_RW=1 makes skills writable"
assert_eq "$(_writable "${H}/Android/sub" Linux AI_SANDBOX_ALLOW_ANDROID=1)" yes "Linux: ALLOW_ANDROID=1 makes ~/Android writable"
assert_eq "$(_writable "${H}/ai-wrapper/.agents/skills/x" Linux AI_SANDBOX_EXTRA_RW_DIRS="${H}/ai-wrapper")" yes \
    "Linux: RW extra on a parent of the skills dir counts"
assert_eq "$(_writable "${H}/bin/sub" Darwin AI_SANDBOX_ALLOW_BIN_RW=1)" no "Darwin: Linux-only toggle grants nothing"
assert_eq "$(_writable "${H}/bin/sub" Linux AI_SANDBOX_ALLOW_BIN_RW=yes)" no "Linux: non-1 toggle value grants nothing"
rm -rf "${H}/Android" "${H}/bin/sub" "${H}/ai-wrapper/.agents/skills/x" "${H}/kind_dot_kube/sub" "${H}/.kind/sub"

# ---------------------------------------------------------------------------
if [[ "${OS}" != "Linux" ]]; then
    echo "  skip - bwrap argv and native probes are Linux-only"
    tests_summary_and_exit
fi

# ---------------------------------------------------------------------------
echo "-- bwrap argv: default protected mode"
argv="$(_argv)"
assert_contains "${argv}" "--die-with-parent" "stubbed bwrap captured an argv"

assert_eq "$(_yes _has_bind "${argv}" --ro-bind "${H}/bin" "${H}/bin")" yes "~/bin is --ro-bind by default"
assert_eq "$(_yes _has_bind "${argv}" --bind "${H}/bin" "${H}/bin")" no "~/bin is not --bind by default"
assert_eq "$(_yes _has_bind "${argv}" --ro-bind "${H}/ai-wrapper/.agents" "${H}/ai-wrapper/.agents")" yes \
    "~/ai-wrapper/.agents is --ro-bind by default"
assert_eq "$(_yes _has_bind "${argv}" --bind "${H}/ai-wrapper/.agents" "${H}/ai-wrapper/.agents")" no \
    "~/ai-wrapper/.agents is not --bind by default"
assert_not_contains "${argv}" "/run/tailscale" "Tailscale socket absent by default"
assert_not_contains "${argv}" "${H}/.kind" "~/.kind never mounted"
assert_not_contains "${argv}" "${H}/kind_dot_kube" "~/kind_dot_kube never mounted"
assert_not_contains "${argv}" "${H}/.kube" "~/.kube absent without AI_SANDBOX_PASS_KUBE"
# The protected baseline mounts before WORKDIR so a workspace (or explicit
# RW extra) at or above these paths keeps its grant (later bwrap mount wins).
bin_idx="$(grep -nxF -- "${H}/bin" <<<"${argv}" | head -1 | cut -d: -f1)"
wd_idx="$(grep -nxF -- "${WORK}" <<<"${argv}" | head -1 | cut -d: -f1)"
assert_eq "$(_yes test "${bin_idx:-0}" -gt 0 -a "${bin_idx:-0}" -lt "${wd_idx:-0}")" yes \
    "protected ~/bin bind precedes the WORKDIR bind"

echo "-- bwrap argv: Android absent by default, opt-in binds RW"
mkdir -p "${H}/Android"
argv="$(_argv)"
assert_not_contains "${argv}" "${H}/Android" "~/Android absent by default even when it exists"
argv="$(_argv AI_SANDBOX_ALLOW_ANDROID=1)"
assert_eq "$(_yes _has_bind "${argv}" --bind "${H}/Android" "${H}/Android")" yes "AI_SANDBOX_ALLOW_ANDROID=1 binds ~/Android RW"
rmdir "${H}/Android"
argv="$(_argv AI_SANDBOX_ALLOW_ANDROID=1)"
assert_not_contains "${argv}" "${H}/Android" "AI_SANDBOX_ALLOW_ANDROID=1 with no ~/Android binds nothing"
assert_eq "$(_yes test -e "${H}/Android")" no "missing ~/Android is not created on the host"

echo "-- bwrap argv: explicit relaxed modes"
argv="$(_argv AI_SANDBOX_ALLOW_BIN_RW=1)"
assert_eq "$(_yes _has_bind "${argv}" --bind "${H}/bin" "${H}/bin")" yes "AI_SANDBOX_ALLOW_BIN_RW=1 binds ~/bin RW"
assert_eq "$(_yes _has_bind "${argv}" --ro-bind "${H}/bin" "${H}/bin")" no "AI_SANDBOX_ALLOW_BIN_RW=1 drops the RO bind"
assert_eq "$(_yes _has_bind "${argv}" --ro-bind "${H}/ai-wrapper/.agents" "${H}/ai-wrapper/.agents")" yes \
    "AI_SANDBOX_ALLOW_BIN_RW=1 leaves skills RO (separate control)"
argv="$(_argv AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW=1)"
assert_eq "$(_yes _has_bind "${argv}" --bind "${H}/ai-wrapper/.agents" "${H}/ai-wrapper/.agents")" yes \
    "AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW=1 binds skills RW"
assert_eq "$(_yes _has_bind "${argv}" --ro-bind "${H}/bin" "${H}/bin")" yes \
    "AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW=1 leaves ~/bin RO (separate control)"
argv="$(_argv AI_SANDBOX_ALLOW_BIN_RW=yes)"
assert_eq "$(_yes _has_bind "${argv}" --ro-bind "${H}/bin" "${H}/bin")" yes "non-1 value (yes) keeps ~/bin RO"

echo "-- bwrap argv: Kind support removed, ordinary kube access kept"
argv="$(_argv AI_SANDBOX_PASS_KUBE=1 KIND_EXPERIMENTAL_PROVIDER=podman KUBECONFIG="${H}/.kube/config")"
assert_eq "$(_yes _has_bind "${argv}" --ro-bind "${H}/.kube" "${H}/.kube")" yes "AI_SANDBOX_PASS_KUBE=1 still RO-binds ~/.kube"
assert_contains "${argv}" "KUBECONFIG${NL}${H}/.kube/config" "AI_SANDBOX_PASS_KUBE=1 still passes KUBECONFIG"
assert_not_contains "${argv}" "${H}/kind_dot_kube" "PASS_KUBE=1 does not mount ~/kind_dot_kube"
assert_not_contains "${argv}" "${H}/.kind" "PASS_KUBE=1 does not mount ~/.kind"
assert_not_contains "${argv}" "KIND_EXPERIMENTAL_PROVIDER" "KIND_EXPERIMENTAL_PROVIDER is not passed"
assert_eq "$(_yes test -d "${H}/.kind" -a -f "${H}/kind_dot_kube/config")" yes "host Kind state is left in place"

echo "-- bwrap argv: Tailscale socket opt-in (RO bind, missing socket omitted)"
rm -f "${ARGV_FILE}"
( cd "${WORK}" && export PATH="${STUB_DIR}:${PATH}" AI_SANDBOX_PASS_TAILSCALE=1 && _load_linux \
    && _AI_SANDBOX_TAILSCALE_SOCKET="${H}/nonexistent.sock" && _run_sandboxed_agent_linux true -- -- ) >/dev/null 2>&1
argv="$(cat "${ARGV_FILE}" 2>/dev/null)"
assert_not_contains "${argv}" "/run/tailscale" "PASS_TAILSCALE=1 with no socket binds nothing"
assert_eq "$(_yes test -e "${H}/nonexistent.sock")" no "missing socket is not created"
TS_SOCK=""
if command -v python3 >/dev/null 2>&1; then
    TS_SOCK="${STUB_DIR}/ts-${RUN_ID}.sock"
    # Synthetic daemon: accepts connections, echoes what it receives.
    python3 -I -c '
import os, socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(4)
while True:
    c, _ = s.accept(); data = c.recv(64); c.sendall(b"daemon-got:" + data); c.close()
' "${TS_SOCK}" &
    TAILSCALE_PID=$!
    for _ in $(seq 1 50); do [[ -S "${TS_SOCK}" ]] && break; sleep 0.1; done
    # The socket path is a source-time constant, not an env knob: a caller's
    # environment cannot point it elsewhere. Tests override it after sourcing.
    rm -f "${ARGV_FILE}"
    ( cd "${WORK}" && export PATH="${STUB_DIR}:${PATH}" AI_SANDBOX_PASS_TAILSCALE=1 \
        _AI_SANDBOX_TAILSCALE_SOCKET="${TS_SOCK}" && _load_linux && _run_sandboxed_agent_linux true -- -- ) >/dev/null 2>&1
    argv="$(cat "${ARGV_FILE}" 2>/dev/null)"
    assert_not_contains "${argv}" "${TS_SOCK}" "socket source path cannot be set from the environment"
    rm -f "${ARGV_FILE}"
    ( cd "${WORK}" && export PATH="${STUB_DIR}:${PATH}" AI_SANDBOX_PASS_TAILSCALE=1 && _load_linux \
        && _AI_SANDBOX_TAILSCALE_SOCKET="${TS_SOCK}" && _run_sandboxed_agent_linux true -- -- ) >/dev/null 2>&1
    argv="$(cat "${ARGV_FILE}" 2>/dev/null)"
    assert_eq "$(_yes _has_bind "${argv}" --ro-bind "${TS_SOCK}" /run/tailscale/tailscaled.sock)" yes \
        "PASS_TAILSCALE=1 RO-binds the daemon socket"
    assert_eq "$(_yes _has_bind "${argv}" --bind "${TS_SOCK}" /run/tailscale/tailscaled.sock)" no \
        "Tailscale socket is never bound RW"
    rm -f "${ARGV_FILE}"
    ( cd "${WORK}" && export PATH="${STUB_DIR}:${PATH}" && _load_linux \
        && _AI_SANDBOX_TAILSCALE_SOCKET="${TS_SOCK}" && _run_sandboxed_agent_linux true -- -- ) >/dev/null 2>&1
    argv="$(cat "${ARGV_FILE}" 2>/dev/null)"
    assert_not_contains "${argv}" "/run/tailscale" "existing socket stays absent without PASS_TAILSCALE"
    out="$( cd "${WORK}" && export PATH="${STUB_DIR}:${PATH}" AI_SANDBOX_PASS_TAILSCALE=1 && _load_linux \
        && _AI_SANDBOX_TAILSCALE_SOCKET="${TS_SOCK}" && _run_sandboxed_agent_linux true -- -- 2>&1 )"
    assert_contains "${out}" "AI_SANDBOX_PASS_TAILSCALE=1" "PASS_TAILSCALE=1 logs a launch warning"
    assert_contains "${out}" "does not make the API read-only" "Tailscale warning does not claim a read-only API"
else
    echo "  skip - python3 required for the synthetic Tailscale socket"
fi

echo "-- relaxed-mode launch warnings"
out="$( cd "${WORK}" && export PATH="${STUB_DIR}:${PATH}" AI_SANDBOX_ALLOW_BIN_RW=1 \
    AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW=1 && _load_linux && _run_sandboxed_agent_linux true -- -- 2>&1 )"
assert_contains "${out}" "AI_SANDBOX_ALLOW_BIN_RW=1" "ALLOW_BIN_RW=1 logs a launch warning"
assert_contains "${out}" "AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW=1" "ALLOW_AGENTS_SKILLS_RW=1 logs a launch warning"
out="$( cd "${WORK}" && export PATH="${STUB_DIR}:${PATH}" && _load_linux && _run_sandboxed_agent_linux true -- -- 2>&1 )"
assert_not_contains "${out}" "WARNING" "protected default launch logs no relaxed-mode warning"

# ---------------------------------------------------------------------------
echo "-- native bubblewrap probes"
if [[ "${OS}" != "Linux" || -z "${REAL_BWRAP}" ]]; then
    echo "  skip - native probes need Linux with bubblewrap (CI smoke-linux)"
    tests_summary_and_exit
fi

# Synthetic client: runs PROBE in the sandbox. Probes print OK:<name> or
# DENIED:<name>; a missing fixture fails as SETUP_FAILED, never as DENIED.
_native() {
    local script="${1}"; shift
    ( cd "${WORK}" && export "$@" && _load_linux \
        && _run_sandboxed_agent_linux /bin/bash -- -- -c "${script}" ) 2>&1
}
PROBE_LIB='probe() { local n="${1}"; shift; if ("$@") >/dev/null 2>&1; then echo "OK:${n}"; else echo "DENIED:${n}"; fi; }'

canary="canary-${RUN_ID}"
echo "bin-original" >"${H}/bin/existing-${RUN_ID}"
echo "skill-original" >"${H}/ai-wrapper/.agents/skills/existing-${RUN_ID}"

# Default protected mode: reads work, every write is denied, host unchanged.
out="$(_native "${PROBE_LIB}
[[ -f ${H}/bin/existing-${RUN_ID} && -d ${H}/ai-wrapper/.agents/skills ]] || { echo SETUP_FAILED; exit 3; }
probe bin-read cat ${H}/bin/existing-${RUN_ID}
probe bin-create sh -c 'echo evil >${H}/bin/${canary}'
probe bin-append sh -c 'echo evil >>${H}/bin/existing-${RUN_ID}'
probe bin-unlink sh -c 'rm -f ${H}/bin/existing-${RUN_ID} && [ ! -e ${H}/bin/existing-${RUN_ID} ]'
probe skills-read cat ${H}/ai-wrapper/.agents/skills/existing-${RUN_ID}
probe skills-create sh -c 'echo evil >${H}/ai-wrapper/.agents/skills/${canary}'
probe skills-mkdir mkdir ${H}/ai-wrapper/.agents/skills/evil-${RUN_ID}
probe android-visible test -e ${H}/Android
probe kind-visible test -e ${H}/.kind
probe kind-kube-visible test -e ${H}/kind_dot_kube
probe tailscale-visible test -e /run/tailscale/tailscaled.sock
probe workdir-write sh -c 'echo ok >${WORK}/legit-${RUN_ID}'
echo PROBES_DONE" _NOOP=1)"
assert_contains "${out}" "PROBES_DONE" "default: probe client ran"
assert_not_contains "${out}" "SETUP_FAILED" "default: fixture found"
for p in bin-read skills-read workdir-write; do assert_contains "${out}" "OK:${p}" "default: ${p} works"; done
for p in bin-create bin-append bin-unlink skills-create skills-mkdir android-visible kind-visible \
        kind-kube-visible tailscale-visible; do
    assert_contains "${out}" "DENIED:${p}" "default: ${p} denied"
done
assert_eq "$(_yes test -e "${H}/bin/${canary}")" no "default: no canary in host ${H}/bin"
assert_eq "$(cat "${H}/bin/existing-${RUN_ID}")" "bin-original" "default: host ${H}/bin file unchanged"
assert_eq "$(_yes test -e "${H}/ai-wrapper/.agents/skills/${canary}")" no "default: no canary in host skills"
assert_eq "$(cat "${WORK}/legit-${RUN_ID}" 2>/dev/null)" "ok" "default: WORKDIR write persists on host"

# PASS_KUBE=1: ${H}/.kube is the real one (not kind_dot_kube) and RO.
out="$(_native "${PROBE_LIB}
cat ${H}/.kube/config
probe kube-read cat ${H}/.kube/config
probe kube-write sh -c 'echo evil >>${H}/.kube/config'
probe kind-visible test -e ${H}/.kind
echo PROBES_DONE" AI_SANDBOX_PASS_KUBE=1)"
assert_contains "${out}" "kube-cred-${RUN_ID}" "PASS_KUBE=1: ${H}/.kube shows the real kubeconfig"
assert_not_contains "${out}" "kind-cred-${RUN_ID}" "PASS_KUBE=1: kind_dot_kube does not shadow ${H}/.kube"
assert_contains "${out}" "DENIED:kube-write" "PASS_KUBE=1: ${H}/.kube stays read-only"
assert_contains "${out}" "DENIED:kind-visible" "PASS_KUBE=1: ${H}/.kind still absent"

# Relaxed modes: legitimate writes persist on the host.
mkdir -p "${H}/Android"
out="$(_native "${PROBE_LIB}
probe bin-create sh -c 'echo built >${H}/bin/${canary}'
probe skills-create sh -c 'echo edited >${H}/ai-wrapper/.agents/skills/${canary}'
probe android-create sh -c 'echo sdk >${H}/Android/${canary}'
echo PROBES_DONE" AI_SANDBOX_ALLOW_BIN_RW=1 AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW=1 AI_SANDBOX_ALLOW_ANDROID=1)"
for p in bin-create skills-create android-create; do assert_contains "${out}" "OK:${p}" "relaxed: ${p} works"; done
assert_eq "$(cat "${H}/bin/${canary}" 2>/dev/null)" "built" "relaxed: ${H}/bin write persists on host"
assert_eq "$(cat "${H}/ai-wrapper/.agents/skills/${canary}" 2>/dev/null)" "edited" "relaxed: skills write persists on host"
assert_eq "$(cat "${H}/Android/${canary}" 2>/dev/null)" "sdk" "relaxed: ${H}/Android write persists on host"
rm -rf "${H:?}/Android" "${H:?}/bin/${canary}" "${H}/ai-wrapper/.agents/skills/${canary}"

# Explicit overlapping grants keep working: RW extra on ${H}/bin, WORKDIR
# under ${H}/bin, WORKDIR above the skills dir.
out="$(_native "${PROBE_LIB}
probe bin-create sh -c 'echo x >${H}/bin/${canary}'
echo PROBES_DONE" AI_SANDBOX_EXTRA_RW_DIRS="${H}/bin")"
assert_contains "${out}" "OK:bin-create" "explicit RW extra on ${H}/bin is writable"
rm -f "${H}/bin/${canary}"
mkdir -p "${H}/bin/tool-${RUN_ID}"
out="$( cd "${H}/bin/tool-${RUN_ID}" && _load_linux && _run_sandboxed_agent_linux /bin/bash -- -- -c "${PROBE_LIB}
probe wd-write sh -c 'echo x >./${canary}'
probe bin-sibling sh -c 'echo x >${H}/bin/${canary}'
echo PROBES_DONE" 2>&1 )"
assert_contains "${out}" "OK:wd-write" "WORKDIR inside ${H}/bin stays writable"
assert_contains "${out}" "DENIED:bin-sibling" "rest of ${H}/bin stays RO with WORKDIR inside it"
assert_eq "$(_yes test -f "${H}/bin/tool-${RUN_ID}/${canary}")" yes "WORKDIR-inside-${H}/bin write persists"
rm -rf "${H}/bin/tool-${RUN_ID}"
out="$( cd "${H}/ai-wrapper" && _load_linux && _run_sandboxed_agent_linux /bin/bash -- -- -c "${PROBE_LIB}
probe skills-create sh -c 'echo x >${H}/ai-wrapper/.agents/skills/${canary}'
echo PROBES_DONE" 2>&1 )"
assert_contains "${out}" "OK:skills-create" "WORKDIR above the skills dir keeps its RW grant"
rm -f "${H}/ai-wrapper/.agents/skills/${canary}"

# Tailscale opt-in: socket reachable through the RO bind, and the RO bind
# does not stop socket I/O (so it is not a read-only API).
if [[ -n "${TS_SOCK}" && -S "${TS_SOCK}" ]]; then
    out="$( cd "${WORK}" && export AI_SANDBOX_PASS_TAILSCALE=1 && _load_linux \
        && _AI_SANDBOX_TAILSCALE_SOCKET="${TS_SOCK}" && _run_sandboxed_agent_linux /bin/bash -- -- -c "${PROBE_LIB}
probe ts-unlink sh -c 'rm -f /run/tailscale/tailscaled.sock && [ ! -e /run/tailscale/tailscaled.sock ]'
python3 -I -c '
import socket
s = socket.socket(socket.AF_UNIX); s.connect(\"/run/tailscale/tailscaled.sock\")
s.sendall(b\"ping\"); print(s.recv(64).decode())'
echo PROBES_DONE" 2>&1 )"
    assert_contains "${out}" "daemon-got:ping" "PASS_TAILSCALE=1: daemon reachable (RO bind does not block socket I/O)"
    assert_contains "${out}" "DENIED:ts-unlink" "PASS_TAILSCALE=1: socket inode cannot be removed"
    assert_eq "$(_yes test -S "${TS_SOCK}")" yes "host socket still present"
fi

tests_summary_and_exit
