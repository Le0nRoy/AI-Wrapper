#!/bin/bash
# shellcheck disable=SC2016,SC2034,SC2163  # single-quoted snippets run later; export "$@" takes NAME=VALUE pairs
# Linux process isolation (#64): user namespace preflight (L7), nested user
# namespace restriction (L3) and the terminal-injection seccomp filter (L5).
#
# - Preflight: /proc/sys knobs are read directly (no sysctl binary). An
#   absent knob is inconclusive, an explicit 0 / unreadable / malformed
#   knob refuses; a real bubblewrap probe with the launch's isolation
#   options runs before the client, and its failures are classified.
# - AI_SANDBOX_ALLOW_NESTED_USERNS=0 (default): --unshare-user
#   --disable-userns --assert-userns-disabled; 1 omits them with a warning.
# - AI_SANDBOX_ALLOW_TIOCSTI=0 (default): a python3 + libseccomp filter
#   (bin/ai_wrapper_data/linux_tty_seccomp.py) is passed with
#   --add-seccomp-fd; it fails ioctl(TIOCSTI/TIOCLINUX) with EPERM. Any
#   build failure refuses the launch; 1 omits it with a warning.
#
# Layers: the helper's Python unit tests; bwrap argv and failure handling
# through a stub bwrap (Linux); native bubblewrap probes (missing bwrap
# fails): nested unshare denial and relaxed success, ioctl EPERM against
# the unfiltered control, descriptor leaks, a caller filter combined with
# ours, real knob/probe denial in a child user namespace, and a private
# PTY driving a real launch (/dev/tty, raw input, resize, Ctrl+C,
# cancellation cleanup). Nothing is injected into the terminal running the
# tests; isolate_test_env traps every real client name.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

OS="$(uname -s)"
# Resolve the real bwrap before the stub dir shadows it on PATH.
REAL_BWRAP="$(type -P bwrap || true)"
HELPER="${REPO_ROOT}/bin/ai_wrapper_data/linux_tty_seccomp.py"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
STUB_DIR="$(mktemp -d)"
isolate_test_env "${FAKE_HOME}"
cleanup() {
    chmod -R u+rwX "${STUB_DIR}" 2>/dev/null
    rm -rf "${FAKE_HOME}" "${STUB_DIR}"
}
trap cleanup EXIT

RUN_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
WORK="${FAKE_HOME}/project-${RUN_ID}"
STATE="${STUB_DIR}/state"
PROC_SYS="${STUB_DIR}/proc-sys"
mkdir -p "${WORK}" "${PROC_SYS}/kernel" "${PROC_SYS}/user"
NL=$'\n'
EPERM=1

_load_linux() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
}

# _backend SETUP [NAME=VALUE...] -- CMD [ARGS...]: runs the Linux backend
# from WORK in a subshell. SETUP is evaluated after the wrapper is sourced
# (test-only overrides of its source-time internals, hooks).
_backend() {
    local setup="${1}"; shift
    local -a envs=()
    while [[ $# -gt 0 && "${1}" != "--" ]]; do envs+=("${1}"); shift; done
    shift
    ( cd "${WORK}" && { [[ ${#envs[@]} -eq 0 ]] || export "${envs[@]}"; } && _load_linux \
        && _AI_SANDBOX_PROC_SYS="${TEST_PROC_SYS}" && eval "${setup}" \
        && _run_sandboxed_agent_linux "${1}" -- -- "${@:2}" ) 2>&1
}

echo "== Linux process isolation (${OS}) =="

if [[ "${OS}" != "Linux" ]]; then
    echo "  skip - preflight, nested user namespaces and the terminal filter are Linux-only"
    tests_summary_and_exit
fi

# ---------------------------------------------------------------------------
echo "-- filter helper unit tests"
helper_out="$(python3 -I -B "${REPO_ROOT}/tests/test_linux_tty_seccomp.py" 2>&1)"
helper_rc=$?
assert_eq "${helper_rc}" 0 "linux_tty_seccomp.py unit tests pass"
[[ "${helper_rc}" == 0 ]] || printf '%s\n' "${helper_out}" >&2
EXPECTED_FILTER="${STUB_DIR}/expected.bpf"
printf '%b' "$(python3 -I "${HELPER}")" >"${EXPECTED_FILTER}"

# ---------------------------------------------------------------------------
# Stub bwrap: numbers each call, records its argv (argv.N) and the bytes of
# every seccomp descriptor it was given (filter.N.FD). A call without
# --chdir is the launch probe: it exits STUB_PROBE_RC after printing
# STUB_PROBE_ERR; the launch exits STUB_LAUNCH_RC. A stub sysctl records
# any call: the wrapper must not need it.
cat >"${STUB_DIR}/bwrap" <<STUB
#!/bin/bash
n=\$(( \$(cat "${STATE}/count" 2>/dev/null || echo 0) + 1 ))
echo "\${n}" >"${STATE}/count"
printf '%s\n' "\$@" >"${STATE}/argv.\${n}"
args=("\$@")
for i in "\${!args[@]}"; do
    case "\${args[i]}" in
        --add-seccomp-fd|--seccomp) fd="\${args[i+1]}"; cat <&"\${fd}" >"${STATE}/filter.\${n}.\${fd}" ;;
    esac
done
if printf '%s\n' "\$@" | grep -qx -- --chdir; then exit "\${STUB_LAUNCH_RC:-0}"; fi
[[ -n "\${STUB_PROBE_ERR:-}" ]] && echo "\${STUB_PROBE_ERR}" >&2
exit "\${STUB_PROBE_RC:-0}"
STUB
cat >"${STUB_DIR}/sysctl" <<STUB
#!/bin/bash
touch "${STATE}/sysctl-called"
exit 1
STUB
chmod +x "${STUB_DIR}/bwrap" "${STUB_DIR}/sysctl"

_set_knobs() {  # CLONE MAX ("-" = absent)
    rm -f "${PROC_SYS}/kernel/unprivileged_userns_clone" "${PROC_SYS}/user/max_user_namespaces"
    [[ "${1}" == "-" ]] || printf '%s\n' "${1}" >"${PROC_SYS}/kernel/unprivileged_userns_clone"
    [[ "${2}" == "-" ]] || printf '%s\n' "${2}" >"${PROC_SYS}/user/max_user_namespaces"
}

# _stub SETUP [NAME=VALUE...]: launch `true` through the stubs. Sets OUT,
# RC, CALLS, PROBE_ARGV (call 1) and LAUNCH_ARGV (call 2).
_stub() {
    local setup="${1}"; shift
    rm -rf "${STATE}"; mkdir -p "${STATE}"
    OUT="$(TEST_PROC_SYS="${PROC_SYS}" _backend "${setup}" "PATH=${STUB_DIR}:${PATH}" "$@" -- true)"
    RC=$?
    CALLS="$(cat "${STATE}/count" 2>/dev/null || echo 0)"
    PROBE_ARGV="$(cat "${STATE}/argv.1" 2>/dev/null)"
    LAUNCH_ARGV="$(cat "${STATE}/argv.2" 2>/dev/null)"
}

# _has_seq ARGV ENTRY...: ARGV holds the entries consecutively.
_has_seq() {
    local argv="${1}" seq="" item
    shift
    for item in "$@"; do seq+="${item}${NL}"; done
    [[ "${NL}${argv}${NL}" == *"${NL}${seq}"* ]]
}
_yes() { if "$@"; then echo yes; else echo no; fi; }
# Descriptor numbers following --add-seccomp-fd in ARGV.
_filter_fds() { awk 'prev == "--add-seccomp-fd" { print } { prev = $0 }' <<<"${1}"; }

TRUE_BIN="$(type -P true)"

# ---------------------------------------------------------------------------
echo "-- default launch: knobs, probe, nested userns restriction, terminal filter"
_set_knobs 1 15000
_stub ""
assert_eq "${RC}" 0 "default: launch succeeds"
assert_eq "${CALLS}" 2 "default: bwrap ran twice (probe, then launch)"
assert_eq "$(_yes test -e "${STATE}/sysctl-called")" no "default: sysctl binary not used"
assert_eq "$(tail -n 1 <<<"${PROBE_ARGV}")" "${TRUE_BIN}" "probe runs the absolute external true"
assert_eq "$(_yes grep -qx -- --unshare-user <<<"${PROBE_ARGV}")" yes "probe requires a new user namespace"
for argv_name in PROBE_ARGV LAUNCH_ARGV; do
    argv="${!argv_name}"
    assert_eq "$(_yes _has_seq "${argv}" --unshare-user --disable-userns --assert-userns-disabled)" yes \
        "${argv_name}: nested user namespaces disabled and asserted"
    assert_eq "$(_filter_fds "${argv}" | wc -l | tr -d ' ')" 1 "${argv_name}: one terminal filter descriptor"
done
assert_eq "$(_yes _has_seq "${PROBE_ARGV}" --ro-bind /usr /usr)" yes "probe binds /usr"
probe_fd="$(_filter_fds "${PROBE_ARGV}")"
launch_fd="$(_filter_fds "${LAUNCH_ARGV}")"
assert_eq "$(_yes cmp -s "${STATE}/filter.1.${probe_fd}" "${EXPECTED_FILTER}")" yes "probe got the whole helper filter"
assert_eq "$(_yes cmp -s "${STATE}/filter.2.${launch_fd}" "${EXPECTED_FILTER}")" yes "launch got the whole helper filter"
filter_size="$(wc -c <"${EXPECTED_FILTER}" | tr -d ' ')"
assert_eq "$(( filter_size > 0 && filter_size % 8 == 0 ))" 1 "filter is a non-empty whole BPF program (${filter_size} bytes)"
assert_eq "$(tail -n 1 <<<"${LAUNCH_ARGV}")" true "launch command unchanged"

# The caller's descriptor table is unchanged after the launch.
fd_state="$( cd "${WORK}" && export PATH="${STUB_DIR}:${PATH}" && _load_linux && _AI_SANDBOX_PROC_SYS="${PROC_SYS}" \
    && rm -rf "${STATE}" && mkdir -p "${STATE}" && me="${BASHPID}" && before="$(ls /proc/"${me}"/fd | sort -n)" \
    && _run_sandboxed_agent_linux true -- -- >/dev/null 2>&1; after="$(ls /proc/"${me}"/fd | sort -n)"
    [[ "${before}" == "${after}" ]] && echo SAME || echo "DIFF [${before//${NL}/ }] -> [${after//${NL}/ }]")"
assert_eq "${fd_state}" SAME "caller keeps no filter descriptor open after the launch"

# ---------------------------------------------------------------------------
echo "-- user namespace knobs (procfs, no sysctl)"
_set_knobs - -
_stub ""
assert_eq "${RC}" 0 "absent knobs are inconclusive: launch proceeds"
assert_eq "${CALLS}" 2 "absent knobs: probe and launch still run"
_set_knobs 1 -
_stub ""
assert_eq "${RC}" 0 "only unprivileged_userns_clone=1: launch proceeds"
_set_knobs - 7
_stub ""
assert_eq "${RC}" 0 "only max_user_namespaces=7: launch proceeds"
for case in "0 15000|kernel.unprivileged_userns_clone is 0" "1 0|user.max_user_namespaces is 0" \
        "- 0|user.max_user_namespaces is 0" "abc 1|not a number" "1 12x|not a number" "|not a number"; do
    knobs="${case%%|*}"; expect="${case#*|}"
    if [[ -z "${knobs}" ]]; then
        _set_knobs "" 1
    else
        # shellcheck disable=SC2086  # two words: CLONE MAX
        _set_knobs ${knobs}
    fi
    _stub ""
    assert_eq "${RC}" 1 "knobs [${knobs:-<empty> 1}]: launch refused"
    assert_contains "${OUT}" "${expect}" "knobs [${knobs:-<empty> 1}]: reason names the knob"
    assert_eq "${CALLS}" 0 "knobs [${knobs:-<empty> 1}]: bwrap never ran"
    assert_not_contains "${OUT}" "sudo" "knobs [${knobs:-<empty> 1}]: no privileged command prescribed"
done
_set_knobs 1 15000
chmod 000 "${PROC_SYS}/user/max_user_namespaces"
if [[ -r "${PROC_SYS}/user/max_user_namespaces" ]]; then
    echo "  skip - unreadable knob: running as a user that can read mode-000 files"
else
    _stub ""
    assert_eq "${RC}" 1 "unreadable knob: launch refused"
    assert_contains "${OUT}" "cannot read ${PROC_SYS}/user/max_user_namespaces" "unreadable knob: reason given"
fi
chmod 644 "${PROC_SYS}/user/max_user_namespaces"
_set_knobs 1 15000

# The knob source is assigned at source time, not taken from the caller.
src_check="$( export _AI_SANDBOX_PROC_SYS=/nonexistent _AI_SANDBOX_PYTHON=nope \
    _AI_SANDBOX_TTY_FILTER_HELPER=/nonexistent && _load_linux \
    && echo "${_AI_SANDBOX_PROC_SYS}|${_AI_SANDBOX_PYTHON}|${_AI_SANDBOX_TTY_FILTER_HELPER}" )"
assert_eq "${src_check}" "/proc/sys|python3|${HELPER}" "caller environment cannot redirect preflight inputs"

# ---------------------------------------------------------------------------
echo "-- AI_SANDBOX_ALLOW_NESTED_USERNS"
_stub "" AI_SANDBOX_ALLOW_NESTED_USERNS=1
assert_eq "${RC}" 0 "ALLOW_NESTED_USERNS=1: launch proceeds"
for argv_name in PROBE_ARGV LAUNCH_ARGV; do
    assert_not_contains "${!argv_name}" "--disable-userns" "ALLOW_NESTED_USERNS=1: ${argv_name} omits --disable-userns"
    assert_not_contains "${!argv_name}" "--assert-userns-disabled" "ALLOW_NESTED_USERNS=1: ${argv_name} omits the assertion"
done
assert_contains "${OUT}" "WARNING" "ALLOW_NESTED_USERNS=1: launch warning"
assert_contains "${OUT}" "AI_SANDBOX_ALLOW_NESTED_USERNS=1" "ALLOW_NESTED_USERNS=1: warning names the setting"
assert_eq "$(_filter_fds "${LAUNCH_ARGV}" | wc -l | tr -d ' ')" 1 "ALLOW_NESTED_USERNS=1: terminal filter still applied"
assert_eq "$(_yes grep -qx -- --unshare-user <<<"${PROBE_ARGV}")" yes \
    "ALLOW_NESTED_USERNS=1: probe still requires a new user namespace"
_stub "" AI_SANDBOX_ALLOW_NESTED_USERNS=yes
assert_eq "$(_yes _has_seq "${LAUNCH_ARGV}" --unshare-user --disable-userns --assert-userns-disabled)" yes \
    "ALLOW_NESTED_USERNS=yes (not 1): restriction kept"

# ---------------------------------------------------------------------------
echo "-- AI_SANDBOX_ALLOW_TIOCSTI"
FAIL_HELPER="${STUB_DIR}/fail_helper.py"
printf 'import sys\nsys.stderr.write("helper-boom-%s\\n")\nsys.exit(1)\n' "${RUN_ID}" >"${FAIL_HELPER}"
_stub "_AI_SANDBOX_TTY_FILTER_HELPER=${FAIL_HELPER}" AI_SANDBOX_ALLOW_TIOCSTI=1
assert_eq "${RC}" 0 "ALLOW_TIOCSTI=1: launch proceeds (filter helper not run)"
assert_not_contains "${PROBE_ARGV}${LAUNCH_ARGV}" "--add-seccomp-fd" "ALLOW_TIOCSTI=1: no terminal filter"
assert_contains "${OUT}" "AI_SANDBOX_ALLOW_TIOCSTI=1" "ALLOW_TIOCSTI=1: warning names the setting"
assert_eq "$(_yes _has_seq "${LAUNCH_ARGV}" --unshare-user --disable-userns --assert-userns-disabled)" yes \
    "ALLOW_TIOCSTI=1: nested userns restriction still applied"
_stub "" AI_SANDBOX_ALLOW_TIOCSTI=true
assert_eq "$(_filter_fds "${LAUNCH_ARGV}" | wc -l | tr -d ' ')" 1 "ALLOW_TIOCSTI=true (not 1): filter kept"

# ---------------------------------------------------------------------------
echo "-- terminal filter build failures refuse the launch"
GARBAGE_HELPER="${STUB_DIR}/garbage_helper.py"
for case in "_AI_SANDBOX_PYTHON=no-such-python-${RUN_ID}|not found on PATH" \
        "_AI_SANDBOX_TTY_FILTER_HELPER=${STUB_DIR}/missing.py|is missing" \
        "_AI_SANDBOX_TTY_FILTER_HELPER=${FAIL_HELPER}|helper-boom-${RUN_ID}" \
        "print('\\\\x00\\\\x01')|not a BPF program" "print('hello')|not a BPF program" \
        "pass|not a BPF program"; do
    setup="${case%%|*}"; expect="${case#*|}"
    if [[ "${setup}" != _AI_* ]]; then
        printf '%s\n' "${setup}" >"${GARBAGE_HELPER}"
        setup="_AI_SANDBOX_TTY_FILTER_HELPER=${GARBAGE_HELPER}"
        label="helper output [$(cat "${GARBAGE_HELPER}")]"
    else
        label="${setup%%=*} (${expect})"
    fi
    _stub "${setup}"
    assert_eq "${RC}" 1 "${label}: launch refused"
    assert_contains "${OUT}" "${expect}" "${label}: reason given"
    assert_contains "${OUT}" "AI_SANDBOX_ALLOW_TIOCSTI=1" "${label}: names the explicit relaxation"
    assert_contains "${OUT}" "libseccomp" "${label}: names the dependency"
    assert_eq "${CALLS}" 0 "${label}: bwrap never ran"
done

# ---------------------------------------------------------------------------
echo "-- launch probe failures are classified and stop the launch"
for case in "bwrap: Unknown option --disable-userns|lacks an option|AI_SANDBOX_ALLOW_NESTED_USERNS=1" \
        "bwrap: Unknown option --add-seccomp-fd|lacks an option|AI_SANDBOX_ALLOW_TIOCSTI=1" \
        "bwrap: No permissions to create a new namespace, likely because the kernel does not allow non-privileged user namespaces.|user namespaces cannot be created here|security module" \
        "bwrap: setting up uid map: Permission denied|user namespaces cannot be created here|denies them" \
        "bwrap: execvp ${TRUE_BIN}: No such file or directory|setup problem, not a user namespace denial|${TRUE_BIN}" \
        "bwrap: Creation of new user namespaces was not disabled as requested|could not stop nested user namespaces|AI_SANDBOX_ALLOW_NESTED_USERNS=1" \
        "bwrap: Invalid seccomp data, must be multiple of 8|terminal-injection filter|AI_SANDBOX_ALLOW_TIOCSTI=1" \
        "bwrap: prctl(PR_SET_SECCOMP): Invalid argument|terminal-injection filter|AI_SANDBOX_ALLOW_TIOCSTI=1" \
        "something odd|probe exited 1|something odd"; do
    err="${case%%|*}"; rest="${case#*|}"; expect="${rest%%|*}"; expect2="${rest#*|}"
    _stub "" STUB_PROBE_RC=1 "STUB_PROBE_ERR=${err}"
    assert_eq "${RC}" 1 "probe [${err}]: launch refused"
    assert_eq "${CALLS}" 1 "probe [${err}]: client launch never reached"
    assert_contains "${OUT}" "Sandbox launch probe failed" "probe [${err}]: refusal logged"
    assert_contains "${OUT}" "${expect}" "probe [${err}]: classified"
    assert_contains "${OUT}" "${expect2}" "probe [${err}]: actionable detail"
    assert_contains "${OUT}" "${err}" "probe [${err}]: bwrap's own message kept"
done
_stub "" STUB_PROBE_RC=1 "STUB_PROBE_ERR=bwrap: No permissions to create a new namespace"
assert_not_contains "${OUT}" "setup problem" "namespace denial is not reported as a setup problem"
_stub "" STUB_PROBE_RC=1 "STUB_PROBE_ERR=bwrap: execvp ${TRUE_BIN}: No such file or directory"
assert_not_contains "${OUT}" "cannot be created here" "setup failure is not reported as a namespace denial"
no_true="$( cd "${WORK}" && _load_linux && PATH="${STUB_DIR}/empty-${RUN_ID}" _sandbox_linux_probe; echo "rc=$?" )"
assert_contains "${no_true}" "no external 'true'" "probe without an external true reports a setup problem"
assert_contains "${no_true}" "rc=1" "probe without an external true fails"

# ---------------------------------------------------------------------------
echo "-- exit status and caller-supplied seccomp filters"
_stub "" STUB_LAUNCH_RC=3
assert_eq "${RC}" 3 "client exit status is returned unchanged"
assert_contains "${OUT}" "Process exited with code 3" "exit status still reported"

USER_FILTER_FILE="${STUB_DIR}/user-filter-${RUN_ID}"
printf 'user-filter-%s' "${RUN_ID}" >"${USER_FILTER_FILE}"
HOOK_SETUP='exec {USER_FD}<"'"${USER_FILTER_FILE}"'"; _extra_sandbox_setup() { bwrap_args+=(--seccomp "${USER_FD}"); }'
_stub "${HOOK_SETUP}"
assert_eq "${RC}" 0 "hook --seccomp: launch proceeds"
assert_not_contains "${NL}${LAUNCH_ARGV}${NL}" "${NL}--seccomp${NL}" "hook --seccomp switched to --add-seccomp-fd (bwrap refuses to mix them)"
assert_eq "$(_filter_fds "${LAUNCH_ARGV}" | wc -l | tr -d ' ')" 2 "hook filter and terminal filter both passed"
user_fd="$(_filter_fds "${LAUNCH_ARGV}" | head -n 1)"
ours_fd="$(_filter_fds "${LAUNCH_ARGV}" | tail -n 1)"
assert_eq "$(cat "${STATE}/filter.2.${user_fd}" 2>/dev/null)" "user-filter-${RUN_ID}" "hook filter content passed through untouched"
assert_eq "$(_yes cmp -s "${STATE}/filter.2.${ours_fd}" "${EXPECTED_FILTER}")" yes "terminal filter passed alongside"
_stub "${HOOK_SETUP}" AI_SANDBOX_ALLOW_TIOCSTI=1
assert_eq "$(_yes _has_seq "${LAUNCH_ARGV}" --seccomp)" yes "ALLOW_TIOCSTI=1: hook --seccomp left as given"
assert_not_contains "${LAUNCH_ARGV}" "--add-seccomp-fd" "ALLOW_TIOCSTI=1: no filter added to the hook's"

# ---------------------------------------------------------------------------
echo "-- native bubblewrap probes"
# Native certification: on Linux a missing bwrap is a failure, not a skip
# (CI smoke-linux installs bubblewrap).
if [[ -z "${REAL_BWRAP}" ]]; then
    _test_report 0 "native probes: bubblewrap (bwrap) available on Linux"
    tests_summary_and_exit
fi

# Host baseline: the relaxed-mode checks below need user namespaces here.
if unshare --user true 2>/dev/null; then host_userns=yes; else host_userns=no; fi
assert_eq "${host_userns}" yes "host baseline: unprivileged user namespaces available (needed by bwrap)"

# ioctl probe (in the sandbox): errno of TIOCSTI, its high-bit alias and
# TIOCLINUX on /dev/null (ENOTTY without a filter, EPERM with ours), plus
# every descriptor above stdio the client holds, with its target. The
# table is read first, before ctypes loads: libffi can keep a descriptor of
# its own open (seen as fd 3 under newer Python), which is the runtime's,
# not something the wrapper passed in. Listing /proc/self/fd opens a
# transient descriptor that is closed by the time it is read back, so only
# descriptors still open are reported.
cat >"${WORK}/ioctl-probe.py" <<'PY'
import os
for name in sorted(os.listdir("/proc/self/fd"), key=int):
    if int(name) <= 2:
        continue
    try:
        print("CLIENT_FD %s %s" % (name, os.readlink("/proc/self/fd/" + name)))
    except FileNotFoundError:
        pass
import ctypes, termios
libc = ctypes.CDLL(None, use_errno=True)
libc.ioctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p]
def err(fd, req):
    arg = ctypes.c_char(b"\0")
    ctypes.set_errno(0)
    return 0 if libc.ioctl(fd, req, ctypes.byref(arg)) == 0 else ctypes.get_errno()
fd = os.open("/dev/null", os.O_RDWR)
print("NULL_TIOCSTI=%d" % err(fd, termios.TIOCSTI))
print("NULL_TIOCSTI_HIGH=%d" % err(fd, (1 << 32) | termios.TIOCSTI))
print("NULL_TIOCLINUX=%d" % err(fd, termios.TIOCLINUX))
os.close(fd)
PY
_native() {  # SETUP SCRIPT [NAME=VALUE...]
    local setup="${1}" script="${2}" probe="${WORK}/probe-${RUN_ID}.sh"; shift 2
    printf '%s\necho PROBES_DONE\n' "${script}" >"${probe}"
    TEST_PROC_SYS=/proc/sys _backend "${setup}" "$@" -- /bin/bash "${probe}"
    rm -f "${probe}"
}
NATIVE_SCRIPT='if unshare --user true 2>/dev/null; then echo NESTED_OK; else echo NESTED_DENIED; fi
git --version >/dev/null 2>&1 && echo GIT_OK
echo "cli-'"${RUN_ID}"'" >"./cli-'"${RUN_ID}"'.txt" && grep -q "cli-'"${RUN_ID}"'" "./cli-'"${RUN_ID}"'.txt" && echo FILE_OK
python3 -I ./ioctl-probe.py'

out="$(_native "" "${NATIVE_SCRIPT}")"
assert_contains "${out}" "PROBES_DONE" "native default: sandbox ran the probe"
assert_contains "${out}" "NESTED_DENIED" "native default: nested user namespace creation fails"
assert_contains "${out}" "GIT_OK" "native default: ordinary CLI (git) works"
assert_contains "${out}" "FILE_OK" "native default: WORKDIR writes work"
assert_contains "${out}" "NULL_TIOCSTI=${EPERM}${NL}" "native default: TIOCSTI fails with EPERM"
assert_contains "${out}" "NULL_TIOCSTI_HIGH=${EPERM}${NL}" "native default: high-bit TIOCSTI alias fails with EPERM"
assert_contains "${out}" "NULL_TIOCLINUX=${EPERM}${NL}" "native default: TIOCLINUX fails with EPERM"

# Descriptor identity: a bwrap wrapper function logs, for each bubblewrap
# call, the target of every --add-seccomp-fd descriptor (FILTER) and, for
# the launch, the caller's whole descriptor table (CALLER); an EXIT trap
# logs the caller's table after the launch (AFTER). Descriptors the caller
# or CI runner already held pass through, as they always have. A deliberately
# inherited caller descriptor (CTRL) is the positive control: caller-owned
# descriptors must still reach the client, so an empty-handed check cannot
# pass. External find lists the table, so no shell redirection is active.
FD_LOG="${STUB_DIR}/fds-${RUN_ID}.log"
CTRL_FILE="${WORK}/ctrl-${RUN_ID}"
: >"${CTRL_FILE}"
FD_HOOK='exec {CTRL_FD}<"'"${CTRL_FILE}"'"
_fd_table() { find "/proc/${1}/fd" -mindepth 1 -maxdepth 1 -printf "${2} %f %l\n" >>"'"${FD_LOG}"'"; }
trap '"'"'_fd_table "${BASHPID}" AFTER'"'"' EXIT
bwrap() {
    local me="${BASHPID}" i; local -a a=("$@")
    for i in "${!a[@]}"; do
        [[ "${a[i]}" == --add-seccomp-fd ]] && printf "FILTER %s %s\n" "${a[i+1]}" "$(readlink "/proc/${me}/fd/${a[i+1]}")" >>"'"${FD_LOG}"'"
    done
    [[ " ${a[*]} " == *" --chdir "* ]] && _fd_table "${me}" CALLER
    command bwrap "$@"
}'
_fd_lines() { awk -v kind="${2}" '$1 == kind { print $2 " " $3 }' <<<"${1}" | sort -u; }
_fd_check() {  # LABEL OUT: no wrapper filter descriptor reaches the client or stays with the caller
    local label="${1}" out="${2}" log filters client caller after leaked
    log="$(cat "${FD_LOG}" 2>/dev/null)"
    filters="$(_fd_lines "${log}" FILTER)"
    client="$(_fd_lines "${out}" CLIENT_FD)"
    caller="$(_fd_lines "${log}" CALLER)"
    after="$(_fd_lines "${log}" AFTER)"
    assert_eq "$(wc -l <<<"${filters}" | tr -d ' ')" 2 "${label}: probe and launch each got a filter descriptor"
    assert_eq "$(_yes grep -qvx '[0-9]* pipe:\[[0-9]*\]' <<<"${filters}")" no "${label}: filter descriptors are pipes"
    assert_contains "${client}" " ${CTRL_FILE}" "${label}: caller-owned descriptor reaches the client (control)"
    leaked="$(awk 'NR == FNR { t[$2] = 1; next } ($2 in t)' <(printf '%s\n' "${filters}") <(printf '%s\n' "${client}"))"
    assert_eq "${leaked}" "" "${label}: no wrapper filter descriptor reaches the client"
    # By number: a path target can read differently inside the sandbox.
    leaked="$(comm -23 <(cut -d ' ' -f 1 <<<"${client}" | sort) <(cut -d ' ' -f 1 <<<"${caller}" | sort))"
    assert_eq "${leaked}" "" "${label}: client holds only descriptors the caller passed"
    leaked="$(awk 'NR == FNR { t[$2] = 1; next } ($2 in t)' <(printf '%s\n' "${filters}") <(printf '%s\n' "${after}"))"
    assert_eq "${leaked}" "" "${label}: caller holds no filter descriptor after the launch"
    assert_contains "${after}" " ${CTRL_FILE}" "${label}: caller-owned descriptor kept after the launch (control)"
}
rm -f "${FD_LOG}"
out="$(_native "${FD_HOOK}" 'python3 -I ./ioctl-probe.py')"
assert_contains "${out}" "NULL_TIOCSTI=${EPERM}${NL}" "native descriptors: terminal filter applied"
_fd_check "native descriptors" "${out}"

out="$(_native "" "${NATIVE_SCRIPT}" AI_SANDBOX_ALLOW_NESTED_USERNS=1)"
assert_contains "${out}" "NESTED_OK" "native ALLOW_NESTED_USERNS=1: nested user namespace creation works"
assert_contains "${out}" "GIT_OK" "native ALLOW_NESTED_USERNS=1: ordinary CLI works"
assert_contains "${out}" "NULL_TIOCSTI=${EPERM}${NL}" "native ALLOW_NESTED_USERNS=1: terminal filter still active"

# Control: without the filter the same calls do not fail with EPERM, so
# EPERM above is the filter's doing, not the kernel's.
out="$(_native "" "${NATIVE_SCRIPT}" AI_SANDBOX_ALLOW_TIOCSTI=1)"
assert_contains "${out}" "PROBES_DONE" "native ALLOW_TIOCSTI=1: sandbox ran the probe"
assert_contains "${out}" "NESTED_DENIED" "native ALLOW_TIOCSTI=1: nested userns still denied"
assert_not_contains "${out}" "NULL_TIOCSTI=${EPERM}${NL}" "native ALLOW_TIOCSTI=1: TIOCSTI not EPERM (control)"
assert_not_contains "${out}" "NULL_TIOCSTI_HIGH=${EPERM}${NL}" "native ALLOW_TIOCSTI=1: high-bit alias not EPERM (control)"
assert_not_contains "${out}" "NULL_TIOCLINUX=${EPERM}${NL}" "native ALLOW_TIOCSTI=1: TIOCLINUX not EPERM (control)"

# A caller filter (mkdir/mkdirat -> EXDEV) combined with ours: both apply.
NATIVE_USER_FILTER="${STUB_DIR}/user-mkdir.bpf"
python3 -I -B - "${REPO_ROOT}/bin/ai_wrapper_data" "${NATIVE_USER_FILTER}" <<'PY'
import errno, sys
sys.path.insert(0, sys.argv[1])
import linux_tty_seccomp as h
lib = h.load_libseccomp()
ctx = lib.seccomp_init(h.SCMP_ACT_ALLOW)
for name in (b"mkdir", b"mkdirat"):
    nr = lib.seccomp_syscall_resolve_name_arch(lib.seccomp_arch_native(), name)
    if nr >= 0:
        assert lib.seccomp_rule_add_array(ctx, h.SCMP_ACT_ERRNO_BASE | errno.EXDEV, nr, 0, None) == 0
with open(sys.argv[2], "wb") as out:
    out.write(h.export_bpf(lib, ctx))
PY
NATIVE_HOOK='exec {USER_FD}<"'"${NATIVE_USER_FILTER}"'"; _extra_sandbox_setup() { bwrap_args+=(--seccomp "${USER_FD}"); }'
MKDIR_SCRIPT='mkdir "./dir-'"${RUN_ID}"'" 2>/dev/null && echo MKDIR_OK || echo MKDIR_DENIED
python3 -I ./ioctl-probe.py'
out="$(_native "${NATIVE_HOOK}" "${MKDIR_SCRIPT}")"
assert_contains "${out}" "MKDIR_DENIED" "native combined: caller filter still enforced"
assert_contains "${out}" "NULL_TIOCLINUX=${EPERM}${NL}" "native combined: terminal filter enforced too"
out="$(_native "${NATIVE_HOOK}" "${MKDIR_SCRIPT}" AI_SANDBOX_ALLOW_TIOCSTI=1)"
assert_contains "${out}" "MKDIR_DENIED" "native ALLOW_TIOCSTI=1: caller --seccomp filter untouched"
assert_not_contains "${out}" "NULL_TIOCLINUX=${EPERM}${NL}" "native ALLOW_TIOCSTI=1: only the caller filter applies"
rmdir "${WORK}/dir-${RUN_ID}" 2>/dev/null

# Probe classification against real bubblewrap.
probe_res() { ( cd "${WORK}" && _load_linux && _sandbox_linux_probe "$@"; echo "rc=$?" ) 2>&1; }
res="$(probe_res)"
assert_contains "${res}" "rc=0" "native probe: plain probe passes"
res="$( cd "${WORK}" && _load_linux && _sandbox_linux_probe "${_AI_SANDBOX_NO_NESTED_USERNS_ARGS[@]}"; echo "rc=$?" )"
assert_contains "${res}" "rc=0" "native probe: this bubblewrap enforces --disable-userns/--assert-userns-disabled"
res="$(probe_res "--no-such-option-${RUN_ID}")"
assert_contains "${res}" "lacks an option" "native probe: unknown option classified"
assert_contains "${res}" "rc=1" "native probe: unknown option fails"
res="$(probe_res --chdir "/nonexistent-${RUN_ID}")"
assert_contains "${res}" "setup problem, not a user namespace denial" "native probe: setup failure classified"

# Real denial: in a child user namespace with max_user_namespaces=0 the
# wrapper refuses on the knob, and the probe itself reports a denial.
DENY_SCRIPT="${STUB_DIR}/deny-${RUN_ID}.sh"
cat >"${DENY_SCRIPT}" <<EOF
echo 0 >/proc/sys/user/max_user_namespaces || { echo CANNOT_LIMIT; exit 0; }
echo LIMIT_SET
cd "${WORK}" && source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
_sandbox_linux_probe; echo "probe_rc=\$?"
( _run_sandboxed_agent_linux true -- -- ); echo "wrapper_rc=\$?"
EOF
res="$(unshare --user --map-root-user bash "${DENY_SCRIPT}" 2>&1)"
assert_contains "${res}" "LIMIT_SET" "native denial: child namespace limit applied"
assert_contains "${res}" "user namespaces cannot be created here" "native denial: probe reports a namespace denial"
assert_contains "${res}" "probe_rc=1" "native denial: probe fails"
assert_contains "${res}" "user.max_user_namespaces is 0" "native denial: wrapper refuses on the real knob"
assert_contains "${res}" "wrapper_rc=1" "native denial: wrapper exits 1"

# ---------------------------------------------------------------------------
echo "-- native PTY: real launch on a private terminal"
# Inner probe (in the sandbox): /dev/tty, foreground process group,
# injection ioctls on the terminal, window size, raw input, resize via
# SIGWINCH, cooked-mode Ctrl+C as SIGINT. SIGWINCH/SIGINT are blocked and
# collected with sigtimedwait, so the markers do not race the handlers.
cat >"${WORK}/tty-probe-${RUN_ID}.py" <<'PY'
import ctypes, fcntl, os, select, signal, struct, sys, termios, tty
TIMEOUT = 20
def say(msg):
    os.write(1, (msg + "\r\n").encode())
def size():
    return struct.unpack("hhhh", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))[:2]
libc = ctypes.CDLL(None, use_errno=True)
libc.ioctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p]
def err(req):
    arg = ctypes.c_char(b"z")
    ctypes.set_errno(0)
    return 0 if libc.ioctl(0, req, ctypes.byref(arg)) == 0 else ctypes.get_errno()
signal.signal(signal.SIGINT, lambda *a: None)
signal.signal(signal.SIGWINCH, lambda *a: None)
signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGINT, signal.SIGWINCH])
try:
    os.close(os.open("/dev/tty", os.O_RDWR))
    say("DEVTTY ok")
except OSError as exc:
    say("DEVTTY errno=%d" % exc.errno)
say("FG %s" % (os.tcgetpgrp(0) == os.getpgrp()))
say("TTY_TIOCSTI=%d" % err(termios.TIOCSTI))
say("TTY_TIOCSTI_HIGH=%d" % err((1 << 32) | termios.TIOCSTI))
say("TTY_TIOCLINUX=%d" % err(termios.TIOCLINUX))
termios.tcflush(0, termios.TCIFLUSH)
say("SIZE %d %d" % size())
saved = termios.tcgetattr(0)
tty.setraw(0)
say("READY")
if signal.sigtimedwait([signal.SIGWINCH], TIMEOUT) is None:
    say("NO_WINCH"); sys.exit(3)
say("WINCH %d %d" % size())
if not select.select([0], [], [], TIMEOUT)[0]:
    say("NO_INPUT"); sys.exit(4)
say("RAW_BYTE %d" % os.read(0, 1)[0])
termios.tcsetattr(0, termios.TCSADRAIN, saved)
say("RESTORED %s" % (termios.tcgetattr(0) == saved))
say("COOKED")
if signal.sigtimedwait([signal.SIGINT], TIMEOUT) is None:
    say("NO_SIGINT"); sys.exit(5)
say("SIGINT_CAUGHT")
PY
# Host driver: private pty (24x80) as the controlling terminal of
# `bash RUNNER`; resizes to 40x100 at READY, types 'q' at WINCH, Ctrl+C at
# COOKED. MODE ignore-int: the wrapper shell and bwrap inherit SIGINT
# ignored, so only the client acts on it and the run must end 0; MODE
# default-int: real Ctrl+C semantics, the run must end (any status).
cat >"${STUB_DIR}/pty-driver.py" <<'PY'
import fcntl, os, select, signal, struct, sys, termios, time
DEADLINE = 90
mode, runner = sys.argv[1], sys.argv[2]
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
pid = os.fork()
if pid == 0:
    os.close(master)
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2):
        os.dup2(slave, fd)
    if mode == "ignore-int":
        signal.signal(signal.SIGINT, signal.SIG_IGN)
    os.execvp("bash", ["bash", runner])
os.close(slave)
end = time.time() + DEADLINE
buf = b""
actions = [(b"READY", lambda: fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))),
           (b"WINCH ", lambda: os.write(master, b"q")),
           (b"COOKED", lambda: os.write(master, b"\x03"))]
eof = False
while not eof and time.time() < end:
    ready = select.select([master], [], [], 0.5)[0]
    if ready:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            chunk = b""
        if not chunk:
            eof = True
        buf += chunk
    while actions and actions[0][0] in buf:
        actions.pop(0)[1]()
if not eof:
    sys.stdout.write("DRIVER_TIMEOUT\n")
    os.killpg(pid, signal.SIGKILL)
_, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode(errors="replace").replace("\r", ""))
if os.WIFEXITED(status):
    sys.stdout.write("\nDRIVER_EXIT code=%d\n" % os.WEXITSTATUS(status))
else:
    sys.stdout.write("\nDRIVER_EXIT signal=%d\n" % os.WTERMSIG(status))
PY
PTY_RUNNER="${STUB_DIR}/pty-runner.sh"
cat >"${PTY_RUNNER}" <<EOF
cd "${WORK}" && source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
_run_sandboxed_agent_linux python3 -- -- -I "${WORK}/tty-probe-${RUN_ID}.py"
EOF
_pty() {  # MODE [NAME=VALUE...]
    local mode="${1}"; shift
    ( [[ $# -eq 0 ]] || export "$@"; python3 -I "${STUB_DIR}/pty-driver.py" "${mode}" "${PTY_RUNNER}" ) 2>&1
}

out="$(_pty ignore-int)"
assert_contains "${out}" "DEVTTY ok" "pty default: /dev/tty opens in the sandbox"
assert_contains "${out}" "FG True" "pty default: client is in the terminal's foreground process group"
assert_contains "${out}" "TTY_TIOCSTI=${EPERM}${NL}" "pty default: TIOCSTI on the terminal fails with EPERM"
assert_contains "${out}" "TTY_TIOCSTI_HIGH=${EPERM}${NL}" "pty default: high-bit alias fails with EPERM"
assert_contains "${out}" "TTY_TIOCLINUX=${EPERM}${NL}" "pty default: TIOCLINUX fails with EPERM"
assert_contains "${out}" "SIZE 24 80" "pty default: window size visible"
assert_contains "${out}" "WINCH 40 100" "pty default: resize delivers SIGWINCH and the new size"
assert_contains "${out}" "RAW_BYTE 113" "pty default: raw-mode keystroke read"
assert_contains "${out}" "RESTORED True" "pty default: terminal attributes restored"
assert_contains "${out}" "SIGINT_CAUGHT" "pty default: Ctrl+C reaches the client as SIGINT"
assert_contains "${out}" "DRIVER_EXIT code=0" "pty default: launch exits 0"
assert_not_contains "${out}" "DRIVER_TIMEOUT" "pty default: no hang"

out="$(_pty ignore-int AI_SANDBOX_ALLOW_TIOCSTI=1)"
assert_contains "${out}" "DEVTTY ok" "pty ALLOW_TIOCSTI=1: /dev/tty opens"
assert_contains "${out}" "TTY_TIOCSTI=" "pty ALLOW_TIOCSTI=1: TIOCSTI measured"
assert_not_contains "${out}" "TTY_TIOCSTI=${EPERM}${NL}" "pty ALLOW_TIOCSTI=1: TIOCSTI not EPERM (control: kernel EIO or allowed on the private pty)"
assert_not_contains "${out}" "TTY_TIOCLINUX=${EPERM}${NL}" "pty ALLOW_TIOCSTI=1: TIOCLINUX not EPERM (control)"
assert_contains "${out}" "SIGINT_CAUGHT" "pty ALLOW_TIOCSTI=1: same terminal behaviour"
assert_contains "${out}" "DRIVER_EXIT code=0" "pty ALLOW_TIOCSTI=1: launch exits 0"

# Real Ctrl+C: the wrapper and bwrap get SIGINT too. The run must end
# without hanging and leave no sandboxed process behind.
out="$(_pty default-int)"
assert_contains "${out}" "COOKED" "pty Ctrl+C: client reached cooked mode"
assert_contains "${out}" "DRIVER_EXIT" "pty Ctrl+C: run ended"
assert_not_contains "${out}" "DRIVER_TIMEOUT" "pty Ctrl+C: no hang"
# Scan every process's argv; "[.]" keeps grep's own argv from matching.
leftover=yes
deadline=$(( SECONDS + 10 ))
while (( SECONDS < deadline )); do
    grep -qsa "tty-probe-${RUN_ID}[.]py" /proc/[0-9]*/cmdline || { leftover=no; break; }
    sleep 0.2
done
assert_eq "${leftover}" no "pty Ctrl+C: no sandboxed client left running"

assert_no_live_client_reached
tests_summary_and_exit
