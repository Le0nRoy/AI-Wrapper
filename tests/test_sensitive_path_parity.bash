#!/bin/bash
# Sensitive-path refusals across the Linux (bubblewrap) and macOS
# (sandbox-exec) backends (#15). Both backends classify WORKDIR and
# AI_SANDBOX_EXTRA_{RW,RO}_DIRS with the shared _sandbox_sensitive_dir_kind
# (ai_agent_universal_wrapper.bash); each keeps its own enforcement:
#   - Linux: system / $HOME / dotfile refusals, all overridable with
#     AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1;
#   - macOS: a system WORKDIR is refused unconditionally; $HOME, dotfile /
#     ~/Library WORKDIRs and every extra-dir refusal are overridable.
#
# Three layers, reported separately:
#   1. classifier tables for the Linux and Darwin rules (uname shadowed) —
#      pure string checks, any OS;
#   2. the macOS backend's refusals (_run_sandboxed_agent_impl) — native on
#      macOS; off macOS uname reports Darwin and getconf / sandbox-exec are
#      stubbed, so it checks refusal logic and dry-run rendering only;
#   3. native refusals through run_sandboxed_agent on the host's own
#      backend, client a stub that must never run when refused.
# Fixtures live under a fake HOME; real system roots are only used for
# refusals (or macOS dry runs), never granted to a launched client.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

# Under the real $HOME for the reason given in tests/test_sandbox_common.bash.
FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
isolate_test_env "${FAKE_HOME}"
cleanup() { rm -rf "${FAKE_HOME}"; }
trap cleanup EXIT

OS="$(uname -s)"
SYSTEM_MSG="top-level or system location"
MARKER="${FAKE_HOME}/client-ran"
mkdir -p "${FAKE_HOME}/project" "${FAKE_HOME}/.cfg" "${FAKE_HOME}/Library"

echo "== sensitive-path parity tests (${OS}) =="

# ---------------------------------------------------------------------------
echo "-- classifier tables (simulated OS via shadowed uname)"
# $1: Darwin|Linux, $2: path. Prints the kind ("" when not sensitive).
_kind_on() {
    ( os="${1}"
      # shellcheck disable=SC2317,SC2329  # called by the sourced wrapper
      uname() { if [[ "${1:-}" == "-s" ]]; then echo "${os}"; else command uname "$@"; fi; }
      # shellcheck source=../bin/ai_agent_universal_wrapper.bash
      source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
      _sandbox_sensitive_dir_kind "${2}" "${FAKE_HOME}" )
}
# $1: OS, $2: expected kind, rest: paths.
_expect_kind() {
    local os="${1}" want="${2}" path
    shift 2
    for path in "$@"; do
        assert_eq "$(_kind_on "${os}" "${path}")" "${want}" "${os}: '${path}' -> '${want:-not sensitive}'"
    done
}
_expect_kind Linux system / /tmp /var /etc /usr /bin /sbin /opt /home /root /proc /sys /dev /boot /mnt /media /srv /run "/etc/"
_expect_kind Linux "" /etcx /mnt/repo /media/disk/repo /srv/www /home/user/project /tmp/project \
    /private/etc /private/tmp /Users /Volumes /Library /System
_expect_kind Darwin system / /Users /Users/Shared /private /private/tmp /private/var /private/var/tmp \
    /private/var/folders /tmp /var /var/tmp /etc /private/etc /private/etc/ /usr /usr/local /bin /sbin \
    /System /Applications /Library
# /Volumes stays as before: neither the mount root nor its children.
_expect_kind Darwin "" /Volumes /Volumes/External /Volumes/External/repo /etcx /private/etcx \
    /private/etc/ssh /private/tmp/project /Users/someone/project /home /root /mnt /media /srv /opt
for os in Linux Darwin; do
    _expect_kind "${os}" home "${FAKE_HOME}" "${FAKE_HOME}/"
    _expect_kind "${os}" dotfile "${FAKE_HOME}/.ssh" "${FAKE_HOME}/.config/gh"
    _expect_kind "${os}" "" "${FAKE_HOME}/project" "${FAKE_HOME}/LibraryX" "${FAKE_HOME}x"
done
_expect_kind Darwin dotfile "${FAKE_HOME}/Library" "${FAKE_HOME}/Library/Keychains"
_expect_kind Linux "" "${FAKE_HOME}/Library" "${FAKE_HOME}/Library/Keychains"

# ---------------------------------------------------------------------------
echo "-- macOS backend refusals"
STUB_BIN="${FAKE_HOME}/stub-bin"
mkdir -p "${STUB_BIN}"
mac_path="${PATH}"
mac_os_shadow=0
if [[ "${OS}" != "Darwin" ]]; then
    # Mocked: off macOS the backend only renders; nothing is enforced.
    mac_os_shadow=1
    mkdir -p "${FAKE_HOME}/darwin/T" "${FAKE_HOME}/darwin/C"
    printf '#!/bin/sh\necho "stub sandbox-exec must not run" >&2\nexit 99\n' >"${STUB_BIN}/sandbox-exec"
    # shellcheck disable=SC2016  # $1 belongs to the generated stub
    printf '#!/bin/sh\ncase "$1" in DARWIN_USER_TEMP_DIR) echo "%s/darwin/T/";; DARWIN_USER_CACHE_DIR) echo "%s/darwin/C/";; *) exit 1;; esac\n' \
        "${FAKE_HOME}" "${FAKE_HOME}" >"${STUB_BIN}/getconf"
    chmod +x "${STUB_BIN}/sandbox-exec" "${STUB_BIN}/getconf"
    mac_path="${STUB_BIN}:${PATH}"
    echo "  (mocked: uname reports Darwin; getconf and sandbox-exec stubbed on ${OS})"
fi
_load_mac_backend() {
    if (( mac_os_shadow )); then
        # shellcheck disable=SC2317,SC2329  # called by the sourced backend
        uname() { if [[ "${1:-}" == "-s" ]]; then echo Darwin; else command uname "$@"; fi; }
    fi
    PATH="${mac_path}"
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=../bin/ai_wrapper_data/macos_sandbox_exec.bash
    source "${REPO_ROOT}/bin/ai_wrapper_data/macos_sandbox_exec.bash"
}
# Launch the stub client (touch MARKER) from WORKDIR $1. Refusals must
# happen before the client (or the sandbox-exec stub) runs.
_mac_launch() { ( cd "${1}" && _load_mac_backend && _run_sandboxed_agent_impl /usr/bin/touch -- -- "${MARKER}" ) 2>&1; }
# Same, as a dry run: renders the plan, never launches.
_mac_dryrun() { ( cd "${1}" && _load_mac_backend && AI_SANDBOX_DRYRUN=1 _run_sandboxed_agent_impl /usr/bin/touch -- -- "${MARKER}" ) 2>&1; }
# $1: description, $2: expected message fragment; reads the last launch.
_expect_refused() {
    assert_eq "${rc}" "1" "${1}: refused"
    assert_contains "${out}" "${2}" "${1}: names the reason"
    assert_not_contains "${out}" "stub sandbox-exec must not run" "${1}: refused before sandbox-exec"
    local ran=0; [[ -e "${MARKER}" ]] && ran=1
    assert_eq "${ran}" "0" "${1}: client did not run"
    rm -f "${MARKER}"
}

rm -f "${MARKER}"
out="$(_mac_dryrun "${FAKE_HOME}/project")"; rc=$?
assert_eq "${rc}" "0" "macOS: project WORKDIR renders"

out="$(_mac_launch "${FAKE_HOME}")"; rc=$?
_expect_refused "macOS: WORKDIR=\$HOME" "WORKDIR=\$HOME"
out="$(_mac_launch "${FAKE_HOME}/.cfg")"; rc=$?
_expect_refused "macOS: dotfile WORKDIR" "under HOME dotfile dir or ~/Library"
out="$(_mac_launch "${FAKE_HOME}/Library")"; rc=$?
_expect_refused "macOS: ~/Library WORKDIR" "under HOME dotfile dir or ~/Library"
for wd in "${FAKE_HOME}" "${FAKE_HOME}/.cfg" "${FAKE_HOME}/Library"; do
    out="$(AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 _mac_dryrun "${wd}")"; rc=$?
    assert_eq "${rc}" "0" "macOS: AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 still overrides WORKDIR ${wd#"${FAKE_HOME}"}"
done

# A system WORKDIR stays refused on macOS even with the override; /etc
# reaches the backend as /private/etc on macOS (pwd -P), as /etc elsewhere.
out="$(_mac_launch /etc)"; rc=$?
_expect_refused "macOS: WORKDIR=/etc" "${SYSTEM_MSG}"
out="$(AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 _mac_launch /etc)"; rc=$?
_expect_refused "macOS: WORKDIR=/etc with the override" "${SYSTEM_MSG}"
if [[ "${OS}" == "Darwin" ]]; then
    out="$(_mac_launch /private/etc)"; rc=$?
    _expect_refused "macOS: WORKDIR=/private/etc" "${SYSTEM_MSG}"
    out="$(AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 _mac_launch /private/tmp)"; rc=$?
    _expect_refused "macOS: WORKDIR=/private/tmp with the override" "${SYSTEM_MSG}"
    # /Volumes is unchanged: a dry run renders (nothing is launched there).
    out="$(_mac_dryrun /Volumes)"; rc=$?
    assert_eq "${rc}" "0" "macOS: WORKDIR=/Volumes still accepted (dry run)"
fi

# Extra dirs: every refusal is overridable, as before.
out="$(AI_SANDBOX_EXTRA_RW_DIRS="${FAKE_HOME}/.cfg" _mac_launch "${FAKE_HOME}/project")"; rc=$?
_expect_refused "macOS: extra RW dotfile dir" "Refusing extra bind '${FAKE_HOME}/.cfg' (under HOME dotfile dir"
out="$(AI_SANDBOX_EXTRA_RW_DIRS="${FAKE_HOME}/Library" _mac_launch "${FAKE_HOME}/project")"; rc=$?
_expect_refused "macOS: extra RW ~/Library" "Refusing extra bind '${FAKE_HOME}/Library' (under HOME dotfile dir"
out="$(AI_SANDBOX_EXTRA_RO_DIRS="${FAKE_HOME}" _mac_launch "${FAKE_HOME}/project")"; rc=$?
_expect_refused "macOS: extra RO \$HOME" "(== \$HOME)"
out="$(AI_SANDBOX_EXTRA_RO_DIRS=/etc _mac_launch "${FAKE_HOME}/project")"; rc=$?
_expect_refused "macOS: extra RO /etc" "Refusing extra bind '/etc' (${SYSTEM_MSG})"
out="$(AI_SANDBOX_EXTRA_RO_DIRS=/ _mac_launch "${FAKE_HOME}/project")"; rc=$?
_expect_refused "macOS: extra RO /" "Refusing extra bind '/' (${SYSTEM_MSG})"
out="$(AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 AI_SANDBOX_EXTRA_RW_DIRS="${FAKE_HOME}/.cfg" _mac_dryrun "${FAKE_HOME}/project")"; rc=$?
assert_eq "${rc}" "0" "macOS: override still accepts an extra dotfile dir"
out="$(AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 AI_SANDBOX_EXTRA_RO_DIRS=/etc _mac_dryrun "${FAKE_HOME}/project")"; rc=$?
assert_eq "${rc}" "0" "macOS: override still accepts an extra system dir (dry run)"
mkdir -p "${FAKE_HOME}/data"
out="$(AI_SANDBOX_EXTRA_RW_DIRS="${FAKE_HOME}/data" _mac_dryrun "${FAKE_HOME}/project")"; rc=$?
assert_eq "${rc}" "0" "macOS: a non-sensitive extra dir is accepted"

# Fail closed when the shared classifier is missing.
out="$( ( cd "${FAKE_HOME}/project" && _load_mac_backend && unset -f _sandbox_sensitive_dir_kind \
    && _run_sandboxed_agent_impl /usr/bin/touch -- -- "${MARKER}" ) 2>&1 )"; rc=$?
_expect_refused "macOS: classifier unavailable" "sensitive-path classifier _sandbox_sensitive_dir_kind is not loaded"

# ---------------------------------------------------------------------------
echo "-- native refusals via run_sandboxed_agent (${OS} backend)"
_native() { ( cd "${1}" && source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash" \
    && run_sandboxed_agent /usr/bin/touch -- -- "${MARKER}" ) 2>&1; }
rm -f "${MARKER}"
out="$(_native /etc)"; rc=$?
_expect_refused "${OS}: WORKDIR=/etc" "${SYSTEM_MSG}"
out="$(_native "${FAKE_HOME}")"; rc=$?
_expect_refused "${OS}: WORKDIR=\$HOME" "WORKDIR=\$HOME"
out="$(_native "${FAKE_HOME}/.cfg")"; rc=$?
_expect_refused "${OS}: dotfile WORKDIR" "dotfile dir"
out="$(AI_SANDBOX_EXTRA_RW_DIRS="${FAKE_HOME}/.cfg" _native "${FAKE_HOME}/project")"; rc=$?
_expect_refused "${OS}: extra RW dotfile dir" "Refusing extra bind '${FAKE_HOME}/.cfg' (under HOME dotfile dir"
out="$(AI_SANDBOX_EXTRA_RO_DIRS=/etc _native "${FAKE_HOME}/project")"; rc=$?
_expect_refused "${OS}: extra RO /etc" "Refusing extra bind '/etc' (${SYSTEM_MSG})"
if [[ "${OS}" == "Darwin" ]]; then
    out="$(_native /private/etc)"; rc=$?
    _expect_refused "Darwin: WORKDIR=/private/etc" "${SYSTEM_MSG}"
    out="$(AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 _native /etc)"; rc=$?
    _expect_refused "Darwin: WORKDIR=/etc with the override" "${SYSTEM_MSG}"
    out="$(_native "${FAKE_HOME}/Library")"; rc=$?
    _expect_refused "Darwin: ~/Library WORKDIR" "dotfile dir or ~/Library"
fi
# Positive controls: a project and the existing overrides still launch
# the stub client (empty synthetic HOME / dotfile fixtures only).
out="$(_native "${FAKE_HOME}/project")"; rc=$?
echo "  (project launch output: ${out})"
assert_eq "${rc}" "0" "${OS}: project WORKDIR launches"
ran=0; [[ -e "${MARKER}" ]] && ran=1
assert_eq "${ran}" "1" "${OS}: ... and the client ran"
rm -f "${MARKER}"
out="$(AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 _native "${FAKE_HOME}/.cfg")"; rc=$?
echo "  (dotfile override launch output: ${out})"
assert_eq "${rc}" "0" "${OS}: AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 overrides a dotfile WORKDIR"
out="$(AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 AI_SANDBOX_EXTRA_RW_DIRS="${FAKE_HOME}/.cfg" _native "${FAKE_HOME}/project")"; rc=$?
echo "  (extra-dir override launch output: ${out})"
assert_eq "${rc}" "0" "${OS}: AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 overrides an extra dotfile dir"
rm -f "${MARKER}"

tests_summary_and_exit
