#!/bin/bash
# shellcheck disable=SC2016,SC2034,SC2163  # single-quoted snippets run later; export "$@" takes NAME=VALUE pairs
# Linux network isolation (#77, L4).
#
# - AI_SANDBOX_ALLOW_UNRESTRICTED_NET=0 (default): bwrap --unshare-net (the
#   sandbox has only its own loopback). The wrapper starts the host egress
#   proxy (ai_network_proxy.py) on a UNIX socket in a private 0700 dir,
#   binds it read-only at /run/ai-sandbox-net/proxy.sock with the loopback
#   forwarder (ai_sandbox_net_forwarder.py), launches the client through
#   the forwarder and exports http(s)_proxy / HTTP(S)_PROXY / all_proxy /
#   ALL_PROXY = http://127.0.0.1:3128 (sandbox loopback). The proxy stops
#   and its dir is removed after the launch; a proxy that cannot start
#   refuses the launch.
# - AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1: --share-net, no proxy, a WARNING.
#
# Layers: forwarder unit tests on the host (python); bwrap argv, proxy
# lifecycle and failure handling through a stub bwrap that also talks to
# the live proxy socket (Linux); native bubblewrap probes (missing bwrap
# fails): host abstract AF_UNIX socket and host loopback unreachable,
# direct egress unroutable, the proxy reachable and refusing loopback,
# with --share-net as the control. Only loopback test servers are used;
# nothing leaves the machine. isolate_test_env traps every real client.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

OS="$(uname -s)"
# Resolve the real bwrap before the stub dir shadows it on PATH.
REAL_BWRAP="$(type -P bwrap || true)"
FORWARDER="${REPO_ROOT}/bin/ai_wrapper_data/ai_sandbox_net_forwarder.py"
PROXY_HELPER="${REPO_ROOT}/bin/ai_wrapper_data/ai_network_proxy.py"
NET_DIR=/run/ai-sandbox-net
PROXY_URL=http://127.0.0.1:3128

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
STUB_DIR="$(mktemp -d)"
isolate_test_env "${FAKE_HOME}"
HOST_SERVER_PID=""
cleanup() {
    [[ -n "${HOST_SERVER_PID}" ]] && kill "${HOST_SERVER_PID}" 2>/dev/null
    rm -rf "${FAKE_HOME}" "${STUB_DIR}"
}
trap cleanup EXIT

RUN_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
WORK="${FAKE_HOME}/project-${RUN_ID}"
STATE="${STUB_DIR}/state"
PROC_SYS="${STUB_DIR}/proc-sys"
mkdir -p "${WORK}" "${PROC_SYS}/kernel" "${PROC_SYS}/user"
echo 1 >"${PROC_SYS}/kernel/unprivileged_userns_clone"
echo 15000 >"${PROC_SYS}/user/max_user_namespaces"
NL=$'\n'

_load_linux() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
}

# _backend SETUP [NAME=VALUE...] -- CMD [ARGS...]: runs the Linux backend
# from WORK in a subshell. SETUP is evaluated after the wrapper is sourced
# (test-only overrides of its source-time internals).
_backend() {
    local setup="${1}"; shift
    local -a envs=()
    while [[ $# -gt 0 && "${1}" != "--" ]]; do envs+=("${1}"); shift; done
    shift
    ( cd "${WORK}" && { [[ ${#envs[@]} -eq 0 ]] || export "${envs[@]}"; } && _load_linux \
        && _AI_SANDBOX_PROC_SYS="${TEST_PROC_SYS}" && eval "${setup}" \
        && _run_sandboxed_agent_linux "${1}" -- -- "${@:2}" ) 2>&1
}

echo "== Linux network isolation (${OS}) =="

if [[ "${OS}" != "Linux" ]]; then
    echo "  skip - bwrap network namespaces are Linux-only"
    tests_summary_and_exit
fi

# ---------------------------------------------------------------------------
echo "-- forwarder unit tests"
forwarder_out="$(python3 -I -B "${REPO_ROOT}/tests/test_sandbox_net_forwarder.py" 2>&1)"
forwarder_rc=$?
assert_eq "${forwarder_rc}" 0 "ai_sandbox_net_forwarder.py tests pass"
[[ "${forwarder_rc}" == 0 ]] || printf '%s\n' "${forwarder_out}" >&2

# ---------------------------------------------------------------------------
# Stub bwrap: numbers each call and records its argv (argv.N). A call
# without --chdir is the launch probe (exit 0). For the launch, when a proxy
# socket is bound it records the bind source (sock.N), whether it is a live
# socket, its directory's mode, the proxy's session against the stub's
# (own session = Ctrl+C-proof) and the status line the proxy answers to
# CONNECT 127.0.0.1:9 over the socket; then exits STUB_LAUNCH_RC.
cat >"${STUB_DIR}/stub_probe.py" <<'PY'
import os, socket, sys
path = sys.argv[1]
print("IS_SOCKET=%s" % os.path.exists(path))
print("DIR_MODE=%o" % (os.stat(os.path.dirname(path)).st_mode & 0o777))
for pid in os.listdir("/proc"):
    if not pid.isdigit():
        continue
    try:
        cmdline = open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")
    except OSError:
        continue
    if path.encode() in cmdline and any(arg.endswith(b"ai_network_proxy.py") for arg in cmdline):
        print("PROXY_PID=%s" % pid)
        print("OWN_SESSION=%s" % (os.getsid(int(pid)) != os.getsid(0)))
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(5)
client.connect(path)
client.sendall(b"CONNECT 127.0.0.1:9 HTTP/1.1\r\n\r\n")
print("PROXY_STATUS=%s" % client.recv(4096).split(b"\r\n", 1)[0].decode())
PY
cat >"${STUB_DIR}/bwrap" <<STUB
#!/bin/bash
n=\$(( \$(cat "${STATE}/count" 2>/dev/null || echo 0) + 1 ))
echo "\${n}" >"${STATE}/count"
printf '%s\n' "\$@" >"${STATE}/argv.\${n}"
printf '%s\n' "\$@" | grep -qx -- --chdir || exit 0
args=("\$@")
for i in "\${!args[@]}"; do
    if [[ "\${args[i]}" == --ro-bind && "\${args[i+2]}" == "${NET_DIR}/proxy.sock" ]]; then
        echo "\${args[i+1]}" >"${STATE}/sock.\${n}"
        python3 -I "${STUB_DIR}/stub_probe.py" "\${args[i+1]}" >"${STATE}/live.\${n}" 2>&1
    fi
done
exit "\${STUB_LAUNCH_RC:-0}"
STUB
chmod +x "${STUB_DIR}/bwrap"

# _stub SETUP [NAME=VALUE...]: launch `true` through the stub. Sets OUT, RC,
# CALLS, LAUNCH_ARGV, SOCK (host proxy socket) and LIVE (stub_probe output).
_stub() {
    local setup="${1}"; shift
    rm -rf "${STATE}"; mkdir -p "${STATE}"
    OUT="$(TEST_PROC_SYS="${PROC_SYS}" _backend "${setup}" "PATH=${STUB_DIR}:${PATH}" AI_SANDBOX_DEBUG=1 "$@" -- true)"
    RC=$?
    CALLS="$(cat "${STATE}/count" 2>/dev/null || echo 0)"
    LAUNCH_ARGV="$(cat "${STATE}/argv.2" 2>/dev/null)"
    SOCK="$(cat "${STATE}/sock.2" 2>/dev/null)"
    LIVE="$(cat "${STATE}/live.2" 2>/dev/null)"
}

# _has_seq ARGV ENTRY...: ARGV holds the entries consecutively.
_has_seq() {
    local argv="${1}" seq="" item
    shift
    for item in "$@"; do seq+="${item}${NL}"; done
    [[ "${NL}${argv}${NL}" == *"${NL}${seq}"* ]]
}
_yes() { if "$@"; then echo yes; else echo no; fi; }
_proxy_pid() { sed -n 's/.*network proxy pid=\([0-9]*\) .*/\1/p' <<<"${OUT}" | head -n 1; }
_gone() { if kill -0 "${1}" 2>/dev/null; then echo running; else echo gone; fi; }
# _running TEXT: some process's command line contains TEXT.
_running() {
    local cmdline
    for cmdline in /proc/[0-9]*/cmdline; do
        tr '\0' ' ' <"${cmdline}" 2>/dev/null | grep -qF -- "${1}" && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
echo "-- default: private network namespace, proxy wired in"
_stub ""
assert_eq "${RC}" 0 "default: launch succeeds"
assert_eq "${CALLS}" 2 "default: bwrap ran twice (probe, then launch)"
assert_eq "$(_yes grep -qx -- --unshare-net <<<"${LAUNCH_ARGV}")" yes "default: --unshare-net"
assert_eq "$(_yes grep -qx -- --share-net <<<"${LAUNCH_ARGV}")" no "default: no --share-net"
for var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY; do
    assert_eq "$(_yes _has_seq "${LAUNCH_ARGV}" --setenv "${var}" "${PROXY_URL}")" yes "default: ${var}=${PROXY_URL}"
done
for var in no_proxy NO_PROXY; do
    assert_eq "$(_yes _has_seq "${LAUNCH_ARGV}" --setenv "${var}" "localhost,127.0.0.1,::1")" yes "default: ${var} keeps the sandbox's own loopback direct"
done
assert_contains "${SOCK}" "/ai-sandbox-net." "default: proxy socket in a private ai-sandbox-net dir"
assert_eq "$(_yes _has_seq "${LAUNCH_ARGV}" --ro-bind "${SOCK}" "${NET_DIR}/proxy.sock")" yes "default: proxy socket bound read-only"
assert_eq "$(_yes _has_seq "${LAUNCH_ARGV}" --ro-bind "${FORWARDER}" "${NET_DIR}/forwarder.py")" yes "default: forwarder bound read-only"
assert_eq "$(_yes _has_seq "${LAUNCH_ARGV}" -I "${NET_DIR}/forwarder.py" --socket "${NET_DIR}/proxy.sock" --port 3128 -- true)" yes \
    "default: client launched through the forwarder"
assert_eq "$(tail -n 1 <<<"${LAUNCH_ARGV}")" true "default: client command last, unchanged"
fwd_python="$(awk -v target="${NET_DIR}/forwarder.py" 'prev == "-I" && $0 == target { print before } { before = prev; prev = $0 }' <<<"${LAUNCH_ARGV}")"
case "${fwd_python}" in
    /usr/*|/bin/*) fwd_python_ok=yes ;;
    *) fwd_python_ok=no ;;
esac
assert_eq "${fwd_python_ok}" yes "default: forwarder runs the system python3 (${fwd_python}), visible in the sandbox"
assert_contains "${LIVE}" "IS_SOCKET=True" "default: proxy socket live during the launch"
assert_contains "${LIVE}" "DIR_MODE=700" "default: proxy dir is owner-only"
assert_contains "${LIVE}" "OWN_SESSION=True" "default: proxy runs in its own session (Ctrl+C-proof)"
assert_contains "${LIVE}" "PROXY_STATUS=HTTP/1.1 403" "default: live proxy refuses a loopback destination"
pid="$(_proxy_pid)"
assert_eq "$([[ -n "${pid}" ]] && echo yes || echo no)" yes "default: proxy pid logged at DEBUG"
assert_eq "$(_gone "${pid:-0}")" gone "default: proxy stopped after the launch"
assert_eq "$(_yes test -e "$(dirname "${SOCK:-/nonexistent/x}")")" no "default: proxy dir removed after the launch"
assert_contains "${OUT}" "refused 1 request(s)" "default: blocked requests reported at exit"
assert_contains "${OUT}" "[BLOCKED] CONNECT 127.0.0.1:9" "default: AI_SANDBOX_DEBUG=1 prints the proxy log"
assert_not_contains "${OUT}" "AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1:" "default: no unrestricted warning"

# The proxy variables come last: an AI_SANDBOX_PASS_ENV passthrough
# cannot point clients around the proxy.
_stub "" "HTTPS_PROXY=http://evil.invalid:1" AI_SANDBOX_PASS_ENV=HTTPS_PROXY
last_https="$(awk 'prev2 == "--setenv" && prev == "HTTPS_PROXY" { v = $0 } { prev2 = prev; prev = $0 } END { print v }' <<<"${LAUNCH_ARGV}")"
assert_eq "${last_https}" "${PROXY_URL}" "PASS_ENV=HTTPS_PROXY: the wrapper's proxy value wins (last --setenv)"

_stub "" STUB_LAUNCH_RC=3
assert_eq "${RC}" 3 "client exit status returned unchanged"
pid="$(_proxy_pid)"
assert_eq "$(_gone "${pid:-0}")" gone "failed client: proxy still stopped"
assert_eq "$(_yes test -e "$(dirname "${SOCK:-/nonexistent/x}")")" no "failed client: proxy dir still removed"

_stub "" AI_SANDBOX_ALLOW_UNRESTRICTED_NET=yes
assert_eq "$(_yes grep -qx -- --unshare-net <<<"${LAUNCH_ARGV}")" yes "UNRESTRICTED_NET=yes (not 1): still isolated"

# Caller EXIT trap: restored after the launch in the main shell.
trap_out="$( cd "${WORK}" && export PATH="${STUB_DIR}:${PATH}" && _load_linux && _AI_SANDBOX_PROC_SYS="${PROC_SYS}" \
    && rm -rf "${STATE}" && mkdir -p "${STATE}" \
    && bash -c 'source "$1"; _AI_SANDBOX_PROC_SYS="$2"; trap "echo CALLER_TRAP_RAN" EXIT; _run_sandboxed_agent_linux true -- -- 2>/dev/null; trap -p EXIT' \
        _ "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash" "${PROC_SYS}" )"
assert_contains "${trap_out}" "trap -- 'echo CALLER_TRAP_RAN' EXIT" "caller's EXIT trap restored after the launch"
assert_contains "${trap_out}" "CALLER_TRAP_RAN" "caller's EXIT trap still runs"

# ---------------------------------------------------------------------------
echo "-- AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1: host network, no proxy"
_stub "" AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1
assert_eq "${RC}" 0 "UNRESTRICTED_NET=1: launch succeeds"
assert_eq "$(_yes grep -qx -- --share-net <<<"${LAUNCH_ARGV}")" yes "UNRESTRICTED_NET=1: --share-net"
assert_eq "$(_yes grep -qx -- --unshare-net <<<"${LAUNCH_ARGV}")" no "UNRESTRICTED_NET=1: no --unshare-net"
assert_not_contains "${LAUNCH_ARGV}" "${NET_DIR}" "UNRESTRICTED_NET=1: no proxy socket or forwarder bound"
assert_eq "$(grep -ci '_proxy$' <<<"${LAUNCH_ARGV}")" 0 "UNRESTRICTED_NET=1: no proxy variables"
assert_not_contains "${OUT}" "network proxy pid=" "UNRESTRICTED_NET=1: no proxy started"
assert_eq "$(tail -n 1 <<<"${LAUNCH_ARGV}")" true "UNRESTRICTED_NET=1: client launched directly (no forwarder)"
assert_contains "${OUT}" "WARNING" "UNRESTRICTED_NET=1: launch warning"
assert_contains "${OUT}" "AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1" "UNRESTRICTED_NET=1: warning names the setting"
assert_contains "${OUT}" "cloud metadata" "UNRESTRICTED_NET=1: warning names what is exposed"

# ---------------------------------------------------------------------------
echo "-- fail closed: no proxy, no launch"
FAIL_HELPER="${STUB_DIR}/fail-proxy-${RUN_ID}.py"
printf 'import sys\nprint("cannot listen: test failure %s", file=sys.stderr)\nsys.exit(1)\n' "${RUN_ID}" >"${FAIL_HELPER}"
_stub "_AI_SANDBOX_NET_PROXY_HELPER=${FAIL_HELPER}"
assert_eq "${RC}" 1 "proxy exits at startup: launch refused"
assert_eq "${CALLS}" 1 "proxy exits at startup: only the probe ran"
assert_contains "${OUT}" "Cannot start the sandbox network proxy" "proxy exits at startup: error logged"
assert_contains "${OUT}" "test failure ${RUN_ID}" "proxy exits at startup: proxy's reason shown"
assert_contains "${OUT}" "AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1" "proxy exits at startup: names the explicit relaxation"
# Never reports READY: refused within the startup budget, process stopped.
HANG_HELPER="${STUB_DIR}/hang-proxy-${RUN_ID}.py"
printf 'import signal, sys\nsignal.signal(signal.SIGTERM, lambda *a: sys.exit(0))\nsignal.pause()\n' >"${HANG_HELPER}"
_stub "_AI_SANDBOX_NET_PROXY_HELPER=${HANG_HELPER}"
assert_eq "${RC}" 1 "proxy never ready: launch refused"
assert_contains "${OUT}" "did not report READY" "proxy never ready: reason given"
assert_eq "$(_yes _running "${HANG_HELPER}")" no "proxy never ready: process stopped"
_stub "_AI_SANDBOX_NET_PROXY_HELPER=/nonexistent/proxy-${RUN_ID}.py"
assert_eq "${RC}" 1 "missing proxy helper: launch refused"
assert_contains "${OUT}" "missing" "missing proxy helper: reason given"
_stub "_AI_SANDBOX_NET_FORWARDER_HELPER=/nonexistent/fwd-${RUN_ID}.py"
assert_eq "${RC}" 1 "missing forwarder: launch refused"
assert_eq "${CALLS}" 1 "missing forwarder: only the probe ran"
_stub "_AI_SANDBOX_NET_SYSTEM_PATH=${STUB_DIR}/empty-${RUN_ID}"
assert_eq "${RC}" 1 "no system python3 for the forwarder: launch refused"
assert_contains "${OUT}" "No python3" "no system python3: reason given"
_stub "_AI_SANDBOX_NET_PROXY_HELPER=${FAIL_HELPER}" AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1
assert_eq "${RC}" 0 "UNRESTRICTED_NET=1: the proxy is not needed"

# The proxy and forwarder inputs are assigned at source time.
src_check="$( export _AI_SANDBOX_NET_PROXY_HELPER=/x _AI_SANDBOX_NET_FORWARDER_HELPER=/x _AI_SANDBOX_NET_DIR=/x \
    _AI_SANDBOX_NET_PROXY_PORT=1 _AI_SANDBOX_NET_SYSTEM_PATH=/x && _load_linux \
    && echo "${_AI_SANDBOX_NET_PROXY_HELPER}|${_AI_SANDBOX_NET_FORWARDER_HELPER}|${_AI_SANDBOX_NET_DIR}|${_AI_SANDBOX_NET_PROXY_PORT}|${_AI_SANDBOX_NET_SYSTEM_PATH}" )"
assert_eq "${src_check}" "${PROXY_HELPER}|${FORWARDER}|${NET_DIR}|3128|/usr/bin:/bin:/usr/local/bin" \
    "caller environment cannot redirect the proxy or forwarder"

# ---------------------------------------------------------------------------
echo "-- native bubblewrap probes"
# Native certification: on Linux a missing bwrap is a failure, not a skip
# (CI smoke-linux installs bubblewrap).
if [[ -z "${REAL_BWRAP}" ]]; then
    _test_report 0 "native probes: bubblewrap (bwrap) available on Linux"
    tests_summary_and_exit
fi

# Host test server: an abstract AF_UNIX socket and a 127.0.0.1 TCP port,
# both answering "HOST_HELLO" to every connection.
ABSTRACT_NAME="ai-wrapper-test-${RUN_ID}"
SERVER_READY="${STUB_DIR}/server-ready-${RUN_ID}"
python3 -I - "${ABSTRACT_NAME}" "${SERVER_READY}" <<'PY' &
import socket, sys, threading
abstract = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
abstract.bind("\0" + sys.argv[1])
tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tcp.bind(("127.0.0.1", 0))
def serve(listener):
    listener.listen(8)
    while True:
        connection, _ = listener.accept()
        connection.sendall(b"HOST_HELLO")
        connection.close()
for listener in (abstract, tcp):
    threading.Thread(target=serve, args=(listener,), daemon=True).start()
with open(sys.argv[2] + ".tmp", "w") as ready:
    ready.write(str(tcp.getsockname()[1]))
import os
os.rename(sys.argv[2] + ".tmp", sys.argv[2])
threading.Event().wait()
PY
HOST_SERVER_PID=$!
for _ in $(seq 1 100); do [[ -s "${SERVER_READY}" ]] && break; sleep 0.05; done
HOST_PORT="$(cat "${SERVER_READY}" 2>/dev/null)"
assert_eq "$([[ -n "${HOST_PORT}" ]] && echo yes || echo no)" yes "host test server listening"

# Probe (in the sandbox): host abstract socket, host loopback port, direct
# egress to a public address, and the proxy path (CONNECT to the host
# loopback port through http_proxy, which the proxy must refuse).
cat >"${WORK}/net-probe.py" <<'PY'
import os, socket, sys
from urllib.parse import urlsplit
name, port = sys.argv[1], int(sys.argv[2])
def attempt(label, family, address):
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect(address)
        print("%s_REACHED %s" % (label, s.recv(64).decode()))
    except OSError as error:
        print("%s_DENIED %s" % (label, type(error).__name__))
    finally:
        s.close()
attempt("ABSTRACT", socket.AF_UNIX, "\0" + name)
attempt("LOOPBACK", socket.AF_INET, ("127.0.0.1", port))
attempt("EGRESS", socket.AF_INET, ("1.1.1.1", 443))
proxy = os.environ.get("https_proxy")
print("HTTPS_PROXY_ENV=%s" % proxy)
if proxy:
    parts = urlsplit(proxy)
    s = socket.create_connection((parts.hostname, parts.port), 5)
    s.sendall(b"CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" % port)
    print("VIA_PROXY %s" % s.recv(4096).split(b"\r\n", 1)[0].decode())
    s.close()
print("SOCK_IS_SOCKET=%s" % os.path.exists("/run/ai-sandbox-net/proxy.sock"))
try:
    open("/run/ai-sandbox-net/forwarder.py", "a").close()
    print("FORWARDER_WRITABLE")
except OSError:
    print("FORWARDER_READONLY")
PY
_native() {  # [NAME=VALUE...]
    TEST_PROC_SYS=/proc/sys _backend "" AI_SANDBOX_DEBUG=1 "$@" -- python3 -I ./net-probe.py "${ABSTRACT_NAME}" "${HOST_PORT}"
}

out="$(_native)"
assert_contains "${out}" "ABSTRACT_DENIED" "native default: host abstract AF_UNIX socket unreachable"
assert_contains "${out}" "LOOPBACK_DENIED" "native default: host loopback port unreachable"
assert_contains "${out}" "EGRESS_DENIED" "native default: no direct egress (no route out of the namespace)"
assert_contains "${out}" "HTTPS_PROXY_ENV=${PROXY_URL}" "native default: proxy variable exported"
assert_contains "${out}" "VIA_PROXY HTTP/1.1 403" "native default: proxy reachable via the forwarder, refuses host loopback"
assert_contains "${out}" "SOCK_IS_SOCKET=True" "native default: proxy socket mounted"
assert_contains "${out}" "FORWARDER_READONLY" "native default: forwarder read-only"
assert_not_contains "${out}" "HOST_HELLO" "native default: nothing on the host answered"
native_sock="$(sed -n 's/.*network proxy pid=[0-9]* socket=\(.*\)$/\1/p' <<<"${out}" | head -n 1)"
assert_eq "$([[ -n "${native_sock}" && ! -e "$(dirname "${native_sock}")" ]] && echo yes || echo no)" yes \
    "native default: proxy dir removed after the launch"

out="$(_native AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1)"
assert_contains "${out}" "ABSTRACT_REACHED HOST_HELLO" "native UNRESTRICTED_NET=1: host abstract socket reachable (control)"
assert_contains "${out}" "LOOPBACK_REACHED HOST_HELLO" "native UNRESTRICTED_NET=1: host loopback reachable (control)"
assert_contains "${out}" "HTTPS_PROXY_ENV=None" "native UNRESTRICTED_NET=1: no proxy variable"
assert_contains "${out}" "SOCK_IS_SOCKET=False" "native UNRESTRICTED_NET=1: no proxy socket"

assert_no_live_client_reached
tests_summary_and_exit
