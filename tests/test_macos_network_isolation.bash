#!/bin/bash
# shellcheck disable=SC2016,SC2034  # single-quoted snippets run later; some vars are read by helpers
# macOS (Seatbelt) network isolation (#78, M2).
#
# - AI_SANDBOX_ALLOW_UNRESTRICTED_NET=0 (default): claude_wrapper.sb denies
#   IP networking except outbound TCP to localhost:PROXY_PORT (UNIX-domain
#   sockets keep working). The wrapper starts the host egress proxy
#   (ai_network_proxy.py) on 127.0.0.1 (ephemeral port) with its log in a
#   private 0700 dir, passes -D ALLOW_UNRESTRICTED_NET=0 -D PROXY_PORT=<port>
#   and exports http(s)_proxy / HTTP(S)_PROXY / all_proxy / ALL_PROXY =
#   http://127.0.0.1:<port>. The proxy stops and its dir is removed after
#   the launch; a proxy that cannot start refuses the launch.
# - AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1: (allow network*), no proxy, a
#   WARNING, -D ALLOW_UNRESTRICTED_NET=1 -D PROXY_PORT=0.
#
# Layers: profile text (any OS); argv/env, proxy lifecycle and failure
# handling through a stub sandbox-exec whose "client" talks to the live
# proxy (any OS; getconf is stubbed off macOS); native Seatbelt probes on
# macOS (missing sandbox-exec fails): direct egress and a host loopback port
# denied, the proxy reachable and refusing loopback, with
# AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1 as the control. Only loopback test
# servers and connection attempts that Seatbelt refuses are used.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

OS="$(uname -s)"
# Resolve the real sandbox-exec before the stub dir shadows it on PATH.
REAL_SANDBOX_EXEC="$(type -P sandbox-exec || true)"
PROFILE="${REPO_ROOT}/bin/ai_wrapper_data/claude_wrapper.sb"
PROXY_VARS="http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY"

# Under the real $HOME for the reason given in tests/test_sandbox_common.bash.
FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
STUB_DIR="$(mktemp -d)"
STUB_DIR="$(cd "${STUB_DIR}" && pwd -P)"
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
mkdir -p "${WORK}" "${STUB_DIR}/bin"
NL=$'\n'

# Off macOS: getconf answers the per-user temp/cache dirs from the fake home.
TEMP_DIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
if [[ "${OS}" != "Darwin" ]]; then
    mkdir -p "${FAKE_HOME}/darwin/T" "${FAKE_HOME}/darwin/C"
    printf '#!/bin/sh\ncase "$1" in DARWIN_USER_TEMP_DIR) echo "%s/darwin/T/";; DARWIN_USER_CACHE_DIR) echo "%s/darwin/C/";; *) exit 1;; esac\n' \
        "${FAKE_HOME}" "${FAKE_HOME}" >"${STUB_DIR}/bin/getconf"
    chmod +x "${STUB_DIR}/bin/getconf"
    TEMP_DIR="${FAKE_HOME}/darwin/T"
fi
TEMP_DIR="$(cd "${TEMP_DIR}" && pwd -P)"

_load_backend() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=../bin/ai_wrapper_data/macos_sandbox_exec.bash
    source "${REPO_ROOT}/bin/ai_wrapper_data/macos_sandbox_exec.bash"
}

# _backend PATH_PREFIX SETUP [NAME=VALUE...] -- CMD [ARGS...]: runs the macOS
# backend from WORK in a subshell with PATH_PREFIX first on PATH. SETUP is
# evaluated after the backend is sourced (test-only overrides).
_backend() {
    local path_prefix="${1}" setup="${2}"; shift 2
    local -a envs=()
    while [[ $# -gt 0 && "${1}" != "--" ]]; do envs+=("${1}"); shift; done
    shift
    ( cd "${WORK}" && export PATH="${path_prefix}${PATH}" \
        && { [[ ${#envs[@]} -eq 0 ]] || export "${envs[@]}"; } && _load_backend && eval "${setup}" \
        && _run_sandboxed_agent_impl "${1}" -- -- "${@:2}" ) 2>&1
}

echo "== macOS network isolation (${OS}) =="

# ---------------------------------------------------------------------------
echo "-- profile text"
SB="$(<"${PROFILE}")"
_line_of() { grep -nF -- "$1" <<<"${SB}" | head -1 | cut -d: -f1; }
_yes() { if "$@"; then echo yes; else echo no; fi; }
_after() { [[ -n "${1}" && -n "${2}" && "${2}" -gt "${1}" ]]; }
violation="$( _load_backend && _sandbox_profile_violation "${SB}" )"
assert_eq "${violation}" "" "shipped claude_wrapper.sb passes the custom-profile check"
unrestricted_when="$(_line_of '(when (equal? (param "ALLOW_UNRESTRICTED_NET") "1")')"
restricted_when="$(_line_of '(when (not (equal? (param "ALLOW_UNRESTRICTED_NET") "1"))')"
deny_net="$(_line_of '(deny network*)')"
proxy_allow="$(_line_of '(allow network-outbound (remote ip (string-append "localhost:" (param "PROXY_PORT"))))')"
unix_allow="$(_line_of '(allow network* (subpath "/"))')"
open_net="$(grep -n '^ *(allow network\*)' <<<"${SB}" | cut -d: -f1)"
assert_eq "$([[ -n "${unrestricted_when}" ]] && echo yes || echo no)" yes "unrestricted branch gated on ALLOW_UNRESTRICTED_NET=1"
assert_eq "$([[ -n "${restricted_when}" ]] && echo yes || echo no)" yes "restricted branch is every other value"
assert_eq "$(wc -l <<<"${open_net}" | tr -d ' ')" 1 "(allow network*) appears once"
assert_eq "$(_yes _after "${unrestricted_when}" "${open_net}")" yes "(allow network*) only in the unrestricted branch"
assert_eq "$(_yes _after "${open_net}" "${restricted_when}")" yes "... which closes before the restricted branch"
assert_eq "$(_yes _after "${restricted_when}" "${deny_net}")" yes "restricted branch: (deny network*)"
assert_eq "$(_yes _after "${deny_net}" "${proxy_allow}")" yes "restricted branch: proxy port allowed after the deny"
assert_eq "$(_yes _after "${deny_net}" "${unix_allow}")" yes "restricted branch: UNIX-domain sockets allowed after the deny"
assert_eq "$(grep -c 'remote ip' <<<"$(sed -n "${restricted_when:-1},\$p" <<<"${SB}" | grep -v '^ *;')")" 1 \
    "restricted branch: the proxy rule is the only IP grant"
block_when="$(_line_of '(when (equal? (param "BLOCK_LOCALHOST") "1")')"
assert_eq "$(_yes _after "${unrestricted_when}" "${block_when}")" yes "BLOCK_LOCALHOST applies inside the unrestricted branch"
assert_eq "$(_yes _after "${block_when}" "${restricted_when}")" yes "... and not to the restricted branch"
assert_contains "${SB}" "(allow system-socket)" "system-socket stays allowed"

# ---------------------------------------------------------------------------
# Stub sandbox-exec: records argv (argv) and the child env (env), then runs
# the command after `-p PROFILE` unsandboxed, exiting STUB_LAUNCH_RC when
# the command succeeds (the wrapper's env -i drops test variables, so the
# status comes from STATE/launch_rc). The probe client CONNECTs to
# 127.0.0.1:9 through https_proxy and prints the proxy's status line.
cat >"${STUB_DIR}/probe.py" <<'PY'
import os, socket
from urllib.parse import urlsplit
proxy = os.environ.get("https_proxy")
print("HTTPS_PROXY_ENV=%s" % proxy)
if proxy:
    parts = urlsplit(proxy)
    s = socket.create_connection((parts.hostname, parts.port), 5)
    s.sendall(b"CONNECT 127.0.0.1:9 HTTP/1.1\r\n\r\n")
    print("VIA_PROXY %s" % s.recv(4096).split(b"\r\n", 1)[0].decode())
    s.close()
PY
mkdir -p "${STUB_DIR}/stub"
cat >"${STUB_DIR}/stub/sandbox-exec" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"${STATE}/argv"
env >"${STATE}/env"
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == -p ]]; then shift 2; break; fi
    shift
done
"\$@" >"${STATE}/client" 2>&1 || exit \$?
exit "\$(cat "${STATE}/launch_rc" 2>/dev/null || echo 0)"
STUB
chmod +x "${STUB_DIR}/stub/sandbox-exec"
STUB_PATH="${STUB_DIR}/stub:${STUB_DIR}/bin:"

# _stub SETUP [NAME=VALUE...]: launch the probe through the stub. Sets OUT,
# RC, ARGV, CHILD_ENV, CLIENT and PORT (the PROXY_PORT -D value).
_stub() {
    local setup="${1}"; shift
    rm -rf "${STATE}"; mkdir -p "${STATE}"
    [[ -n "${STUB_LAUNCH_RC:-}" ]] && echo "${STUB_LAUNCH_RC}" >"${STATE}/launch_rc"
    OUT="$(_backend "${STUB_PATH}" "${setup}" AI_SANDBOX_DEBUG=1 "$@" -- python3 -I "${STUB_DIR}/probe.py")"
    RC=$?
    ARGV="$(cat "${STATE}/argv" 2>/dev/null)"
    CHILD_ENV="$(cat "${STATE}/env" 2>/dev/null)"
    CLIENT="$(cat "${STATE}/client" 2>/dev/null)"
    PORT="$(sed -n 's/^PROXY_PORT=//p' <<<"${ARGV}" | head -n 1)"
}
_proxy_pid() { sed -n 's/.*network proxy pid=\([0-9]*\) .*/\1/p' <<<"${OUT}" | head -n 1; }
_proxy_dir() { sed -n 's/.*network proxy pid=[0-9]* port=[0-9]* dir=\(.*\)$/\1/p' <<<"${OUT}" | head -n 1; }
_gone() { if kill -0 "${1}" 2>/dev/null; then echo running; else echo gone; fi; }
_leftover_dirs() { find "${TEMP_DIR}" -maxdepth 1 -name 'ai-sandbox-net.*' 2>/dev/null | wc -l | tr -d ' '; }
_running() { ps -A -o command= 2>/dev/null | grep -F -- "${1}" | grep -vq grep; }

echo "-- default: Seatbelt network deny, proxy wired in"
_stub ""
assert_eq "${RC}" 0 "default: launch succeeds"
assert_eq "$(_yes grep -qx -- 'ALLOW_UNRESTRICTED_NET=0' <<<"${ARGV}")" yes "default: -D ALLOW_UNRESTRICTED_NET=0"
assert_eq "$([[ "${PORT}" =~ ^[1-9][0-9]*$ ]] && echo yes || echo no)" yes "default: -D PROXY_PORT is the proxy's ephemeral port (${PORT})"
for var in ${PROXY_VARS}; do
    assert_eq "$(grep -c "^${var}=" <<<"${CHILD_ENV}")" 1 "default: ${var} set once"
    assert_eq "$(_yes grep -qx -- "${var}=http://127.0.0.1:${PORT}" <<<"${CHILD_ENV}")" yes "default: ${var}=http://127.0.0.1:${PORT}"
done
assert_contains "${CLIENT}" "VIA_PROXY HTTP/1.1 403" "default: live proxy reachable, refuses a loopback destination"
pid="$(_proxy_pid)"
dir="$(_proxy_dir)"
assert_eq "$([[ -n "${pid}" ]] && echo yes || echo no)" yes "default: proxy pid logged at DEBUG"
assert_eq "$(_gone "${pid:-0}")" gone "default: proxy stopped after the launch"
assert_eq "$([[ "${dir}" == "${TEMP_DIR}"/ai-sandbox-net.* ]] && echo yes || echo no)" yes "default: proxy dir under DARWIN_USER_TEMP_DIR"
assert_eq "$(_yes test -e "${dir:-/nonexistent}")" no "default: proxy dir removed after the launch"
assert_contains "${OUT}" "refused 1 request(s)" "default: blocked requests reported at exit"
assert_contains "${OUT}" "[BLOCKED] CONNECT 127.0.0.1:9" "default: AI_SANDBOX_DEBUG=1 prints the proxy log"
assert_not_contains "${OUT}" "AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1:" "default: no unrestricted warning"

# The proxy variables come last: a passthrough cannot point clients around
# the proxy (Seatbelt would refuse a direct connection anyway).
_stub "" "HTTPS_PROXY=http://evil.invalid:1" "all_proxy=http://evil.invalid:1" AI_SANDBOX_PASS_ENV=HTTPS_PROXY,all_proxy
assert_eq "$(grep -c '^HTTPS_PROXY=' <<<"${CHILD_ENV}")" 1 "PASS_ENV=HTTPS_PROXY: one HTTPS_PROXY in the child env"
assert_eq "$(_yes grep -qx -- "HTTPS_PROXY=http://127.0.0.1:${PORT}" <<<"${CHILD_ENV}")" yes "PASS_ENV=HTTPS_PROXY: the wrapper's value wins"
assert_eq "$(_yes grep -qx -- "all_proxy=http://127.0.0.1:${PORT}" <<<"${CHILD_ENV}")" yes "PASS_ENV=all_proxy: the wrapper's value wins"
assert_not_contains "${CHILD_ENV}" "evil.invalid" "PASS_ENV: no passthrough proxy value left"
# The _extra_sandbox_setup hook runs before the proxy variables are set.
_stub '_extra_sandbox_setup() { env_allowlist+=("http_proxy=http://hook.invalid:1"); }'
assert_eq "$(grep -c '^http_proxy=' <<<"${CHILD_ENV}")" 1 "hook-added http_proxy replaced"
assert_not_contains "${CHILD_ENV}" "hook.invalid" "hook cannot point clients around the proxy"

STUB_LAUNCH_RC=3 _stub ""
assert_eq "${RC}" 3 "client exit status returned unchanged"
assert_eq "$(_gone "$(_proxy_pid)")" gone "failed client: proxy still stopped"
assert_eq "$(_yes test -e "$(_proxy_dir)")" no "failed client: proxy dir still removed"

_stub "" AI_SANDBOX_ALLOW_UNRESTRICTED_NET=yes
assert_eq "$(_yes grep -qx -- 'ALLOW_UNRESTRICTED_NET=0' <<<"${ARGV}")" yes "UNRESTRICTED_NET=yes (not 1): still restricted"
assert_contains "${CLIENT}" "VIA_PROXY HTTP/1.1 403" "UNRESTRICTED_NET=yes: proxy still wired in"

# AI_SANDBOX_DRYRUN shows the proxy env and parameters, launches nothing
# and still stops the proxy.
_stub "" AI_SANDBOX_DRYRUN=1
assert_eq "${RC}" 0 "dry run exits 0"
assert_eq "$(_yes test -e "${STATE}/argv")" no "dry run: sandbox-exec not run"
assert_contains "${OUT}" "ALLOW_UNRESTRICTED_NET=0" "dry run: shows ALLOW_UNRESTRICTED_NET"
assert_eq "$([[ "${OUT}" =~ PROXY_PORT=[1-9][0-9]* ]] && echo yes || echo no)" yes "dry run: shows PROXY_PORT"
assert_eq "$([[ "${OUT}" =~ https_proxy=http://127.0.0.1:[1-9][0-9]* ]] && echo yes || echo no)" yes "dry run: shows the proxy env"
assert_eq "$(_gone "$(_proxy_pid)")" gone "dry run: proxy stopped"

assert_eq "$(_leftover_dirs)" 0 "no proxy dirs left behind"

# Caller EXIT trap: restored after the launch in the main shell.
trap_body='source "$1"; source "$2"; trap "echo CALLER_TRAP_RAN" EXIT
    _run_sandboxed_agent_impl true -- -- 2>/dev/null; trap -p EXIT'
trap_out="$( cd "${WORK}" && export PATH="${STUB_PATH}${PATH}" && rm -rf "${STATE}" && mkdir -p "${STATE}" \
    && bash -c "${trap_body}" _ "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash" \
        "${REPO_ROOT}/bin/ai_wrapper_data/macos_sandbox_exec.bash" )"
assert_contains "${trap_out}" "trap -- 'echo CALLER_TRAP_RAN' EXIT" "caller's EXIT trap restored after the launch"
assert_contains "${trap_out}" "CALLER_TRAP_RAN" "caller's EXIT trap still runs"
# In a subshell (also a command substitution, as tests/test_sandbox_common.bash
# runs it): a trap it only inherited (here the parent's) is not run when it
# exits. Checked with BASHPID, without it (the bash 3.2 path) and, on macOS,
# under /bin/bash (3.2), whose subshells keep listing the parent's traps.
subshell_body='source "$1"; source "$2"; [[ "$3" == nobashpid ]] && unset BASHPID
    trap "echo PARENT_TRAP_RAN" EXIT
    ( trap "echo SUBSHELL_TRAP_RAN" EXIT; _run_sandboxed_agent_impl true -- -- 2>/dev/null; echo "OWN_TRAP_SET=[$(trap -p EXIT)]" )
    echo SUBSHELL_1_DONE
    ( _run_sandboxed_agent_impl true -- -- 2>/dev/null; echo "OWN_TRAP=[$(trap -p EXIT)]" )
    echo SUBSHELL_2_DONE
    echo "SUBST=[$(_run_sandboxed_agent_impl true -- -- 2>/dev/null)]"
    trap - EXIT'
subshell_shells="bash:bashpid bash:nobashpid"
[[ "${OS}" == "Darwin" ]] && subshell_shells="${subshell_shells} /bin/bash:system"
for shell_mode in ${subshell_shells}; do
    trap_out="$( cd "${WORK}" && export PATH="${STUB_PATH}${PATH}" && rm -rf "${STATE}" && mkdir -p "${STATE}" \
        && "${shell_mode%%:*}" -c "${subshell_body}" _ "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash" \
            "${REPO_ROOT}/bin/ai_wrapper_data/macos_sandbox_exec.bash" "${shell_mode#*:}" )"
    assert_contains "${trap_out}" "SUBSHELL_1_DONE" "${shell_mode}: subshell with its own EXIT trap completes"
    assert_contains "${trap_out}" "OWN_TRAP=[]${NL}SUBSHELL_2_DONE" "${shell_mode}: subshell without its own EXIT trap: none left after the launch"
    assert_contains "${trap_out}" "SUBST=[]" "${shell_mode}: command substitution completes"
    assert_not_contains "${trap_out}" "PARENT_TRAP_RAN" "${shell_mode}: parent's EXIT trap not run by the subshell"
    # bash >= 4 tells its own trap from an inherited one: restored and run.
    if [[ "${shell_mode}" == bash:bashpid && "$(bash -c 'echo "${BASH_VERSINFO[0]}"')" -ge 4 ]]; then
        assert_contains "${trap_out}" "OWN_TRAP_SET=[trap -- 'echo SUBSHELL_TRAP_RAN' EXIT]${NL}SUBSHELL_TRAP_RAN${NL}SUBSHELL_1_DONE" \
            "${shell_mode}: subshell's own EXIT trap restored after the launch and runs"
    fi
done
# Killed during the session: the EXIT trap stops the proxy.
kill_out="$( cd "${WORK}" && export PATH="${STUB_PATH}${PATH}" && rm -rf "${STATE}" && mkdir -p "${STATE}" \
    && bash -c 'source "$1"; source "$2"; AI_SANDBOX_DEBUG=1 _run_sandboxed_agent_impl sh -- -- -c "kill -TERM $$; sleep 2"' \
        _ "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash" "${REPO_ROOT}/bin/ai_wrapper_data/macos_sandbox_exec.bash" 2>&1 )"
OUT="${kill_out}"
kill_pid="$(_proxy_pid)"
for _ in $(seq 1 100); do [[ "$(_gone "${kill_pid:-0}")" == gone ]] && break; sleep 0.05; done
assert_eq "$([[ -n "${kill_pid}" ]] && echo yes || echo no)" yes "killed wrapper: proxy had started"
assert_eq "$(_gone "${kill_pid:-0}")" gone "killed wrapper: proxy stopped"
assert_eq "$(_leftover_dirs)" 0 "killed wrapper: proxy dir removed"

# ---------------------------------------------------------------------------
echo "-- AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1: open network, no proxy"
_stub "" AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1
assert_eq "${RC}" 0 "UNRESTRICTED_NET=1: launch succeeds"
assert_eq "$(_yes grep -qx -- 'ALLOW_UNRESTRICTED_NET=1' <<<"${ARGV}")" yes "UNRESTRICTED_NET=1: -D ALLOW_UNRESTRICTED_NET=1"
assert_eq "${PORT}" 0 "UNRESTRICTED_NET=1: -D PROXY_PORT=0"
assert_eq "$(grep -ci '^[a-z_]*_proxy=' <<<"${CHILD_ENV}")" 0 "UNRESTRICTED_NET=1: no proxy variables"
assert_contains "${CLIENT}" "HTTPS_PROXY_ENV=None" "UNRESTRICTED_NET=1: client sees no proxy"
assert_not_contains "${OUT}" "network proxy pid=" "UNRESTRICTED_NET=1: no proxy started"
assert_contains "${OUT}" "WARNING" "UNRESTRICTED_NET=1: launch warning"
assert_contains "${OUT}" "AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1" "UNRESTRICTED_NET=1: warning names the setting"
assert_contains "${OUT}" "cloud metadata" "UNRESTRICTED_NET=1: warning names what is exposed"

# ---------------------------------------------------------------------------
echo "-- fail closed: no proxy, no launch"
FAIL_HELPER="${STUB_DIR}/fail-proxy-${RUN_ID}.py"
printf 'import sys\nprint("cannot listen: test failure %s", file=sys.stderr)\nsys.exit(1)\n' "${RUN_ID}" >"${FAIL_HELPER}"
_stub "_AI_SANDBOX_NET_PROXY_HELPER=${FAIL_HELPER}"
assert_eq "${RC}" 1 "proxy exits at startup: launch refused"
assert_eq "$(_yes test -e "${STATE}/argv")" no "proxy exits at startup: sandbox-exec not run"
assert_contains "${OUT}" "Cannot start the sandbox network proxy" "proxy exits at startup: error logged"
assert_contains "${OUT}" "test failure ${RUN_ID}" "proxy exits at startup: proxy's reason shown"
assert_contains "${OUT}" "AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1" "proxy exits at startup: names the explicit relaxation"
HANG_HELPER="${STUB_DIR}/hang-proxy-${RUN_ID}.py"
printf 'import signal, sys\nsignal.signal(signal.SIGTERM, lambda *a: sys.exit(0))\nsignal.pause()\n' >"${HANG_HELPER}"
_stub "_AI_SANDBOX_NET_PROXY_HELPER=${HANG_HELPER}"
assert_eq "${RC}" 1 "proxy never ready: launch refused"
assert_contains "${OUT}" "did not report READY" "proxy never ready: reason given"
assert_eq "$(_yes _running "${HANG_HELPER}")" no "proxy never ready: process stopped"
_stub "_AI_SANDBOX_NET_PROXY_HELPER=/nonexistent/proxy-${RUN_ID}.py"
assert_eq "${RC}" 1 "missing proxy helper: launch refused"
assert_contains "${OUT}" "missing" "missing proxy helper: reason given"
_stub "_AI_SANDBOX_PYTHON=python3-missing-${RUN_ID}"
assert_eq "${RC}" 1 "no python3: launch refused"
assert_contains "${OUT}" "not found" "no python3: reason given"
_stub "_AI_SANDBOX_NET_PROXY_HELPER=${FAIL_HELPER}" AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1
assert_eq "${RC}" 0 "UNRESTRICTED_NET=1: the proxy is not needed"
assert_eq "$(_leftover_dirs)" 0 "failures leave no proxy dirs behind"

# ---------------------------------------------------------------------------
echo "-- native Seatbelt probes"
if [[ "${OS}" != "Darwin" ]]; then
    echo "  skip - native Seatbelt probes (${OS} is not Darwin)"
    assert_no_live_client_reached
    tests_summary_and_exit
fi
if [[ -z "${REAL_SANDBOX_EXEC}" ]]; then
    _test_report 0 "native probes: sandbox-exec available on macOS"
    tests_summary_and_exit
fi

# Host test server on a 127.0.0.1 port, answering "HOST_HELLO".
SERVER_READY="${STUB_DIR}/server-ready-${RUN_ID}"
python3 -I - "${SERVER_READY}" <<'PY' &
import os, socket, sys
tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tcp.bind(("127.0.0.1", 0))
tcp.listen(8)
with open(sys.argv[1] + ".tmp", "w") as ready:
    ready.write(str(tcp.getsockname()[1]))
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
while True:
    connection, _ = tcp.accept()
    connection.sendall(b"HOST_HELLO")
    connection.close()
PY
HOST_SERVER_PID=$!
for _ in $(seq 1 100); do [[ -s "${SERVER_READY}" ]] && break; sleep 0.05; done
HOST_PORT="$(cat "${SERVER_READY}" 2>/dev/null)"
assert_eq "$([[ -n "${HOST_PORT}" ]] && echo yes || echo no)" yes "host test server listening"

# Probe (in the sandbox, system perl): the host loopback port, direct egress
# to a public address, and the proxy path (CONNECT to the host loopback
# port through https_proxy, which the proxy must refuse).
cat >"${WORK}/net-probe.pl" <<'PL'
use strict; use warnings; use IO::Socket::INET;
my $port = $ARGV[0];
sub attempt {
    my ($label, $host, $p) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $p, Proto => 'tcp', Timeout => 3);
    if ($s) { my $buf = ''; $s->recv($buf, 64); print "${label}_REACHED $buf\n"; close $s; }
    else { print "${label}_DENIED $!\n"; }
}
attempt("LOOPBACK", "127.0.0.1", $port);
attempt("EGRESS", "1.1.1.1", 443);
my $proxy = $ENV{https_proxy} // '';
print "HTTPS_PROXY_ENV=$proxy\n";
if ($proxy =~ m{^http://([^:/]+):(\d+)}) {
    my $s = IO::Socket::INET->new(PeerAddr => $1, PeerPort => $2, Proto => 'tcp', Timeout => 5)
        or do { print "PROXY_DENIED $!\n"; exit 0 };
    print $s "CONNECT 127.0.0.1:$port HTTP/1.1\r\n\r\n";
    my $line = <$s> // ''; $line =~ s/\r?\n$//;
    print "VIA_PROXY $line\n";
}
PL
_native() {  # [NAME=VALUE...]
    _backend "" "" AI_SANDBOX_DEBUG=1 "$@" -- /usr/bin/perl ./net-probe.pl "${HOST_PORT}"
}

out="$(_native)"
echo "  (default output: $(grep -E '_(REACHED|DENIED)|VIA_PROXY|PROXY_ENV' <<<"${out}" | tr '\n' ' '))"
assert_contains "${out}" "LOOPBACK_DENIED" "native default: host loopback port unreachable"
assert_contains "${out}" "EGRESS_DENIED" "native default: no direct egress"
assert_contains "${out}" "HTTPS_PROXY_ENV=http://127.0.0.1:" "native default: proxy variable exported"
assert_contains "${out}" "VIA_PROXY HTTP/1.1 403" "native default: proxy port reachable, refuses host loopback"
assert_not_contains "${out}" "HOST_HELLO" "native default: nothing on the host answered"
OUT="${out}"
assert_eq "$(_yes test -e "$(_proxy_dir)")" no "native default: proxy dir removed after the launch"

out="$(_native AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1)"
assert_contains "${out}" "LOOPBACK_REACHED HOST_HELLO" "native UNRESTRICTED_NET=1: host loopback reachable (control)"
assert_contains "${out}" "HTTPS_PROXY_ENV=${NL}" "native UNRESTRICTED_NET=1: no proxy variable"

assert_no_live_client_reached
tests_summary_and_exit
