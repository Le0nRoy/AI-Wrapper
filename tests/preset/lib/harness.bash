#!/usr/bin/env bash
# Shared test harness for preset tests.
#
# Provides:
#   mk_scratch      — create per-test scratch dir, set HOME and PWD inside it.
#   source_lib      — source a sed-rewritten copy of ai_wrapper_lib.bash
#                     that redirects all /dev/tty writes to TEST_TTY_OUT
#                     and all /dev/tty reads from TEST_TTY_IN.
#   clean_scratch   — rm -rf the scratch dir (with defensive guards).
#   tty_in          — write canned input lines into TEST_TTY_IN.
#   clear_catalog_env — unset every catalog env var so tests start clean.
#
# Constants:
#   CANARY_BOOL     — bool used in many tests; rename here on catalog drift.
#   CANARY_BOOL_2   — second bool for multi-toggle save tests.
#   CANARY_STR      — str-type entry name (AI_SANDBOX_PASS_ENV).
#   CANARY_PATH     — path-type entry name (AI_SANDBOX_PROFILE).

# --- Canaries --------------------------------------------------------------

CANARY_BOOL="AI_SANDBOX_PASS_AWS"
CANARY_BOOL_2="AI_SANDBOX_PASS_KUBE"
CANARY_STR="AI_SANDBOX_PASS_ENV"
CANARY_PATH="AI_SANDBOX_PROFILE"

# --- Paths -----------------------------------------------------------------

_REPO_ROOT="/Users/vadim.trishin/bin"
_SRC_LIB="${_REPO_ROOT}/ai_wrapper_data/ai_wrapper_lib.bash"
_REAL_HOME="${HOME}"   # remember real home so we can refuse to clobber it
# Scratch root: prefers $TMPDIR (standard convention), but falls back to
# the repo-local tests/preset/_scratch when `mkdir -p` through the
# canonical $TMPDIR ancestor is blocked (the dev sandbox on this host
# refuses `mkdir /var/folders/gt`, which `mkdir -p` walks). Either way,
# each test still uses `mktemp -d` for its workspace and `clean_scratch`
# removes it on EXIT, so nothing persists across runs. Override with
# PRESET_TEST_SCRATCH_ROOT for one-off debugging.
_SCRATCH_ROOT_DEFAULT="${_REPO_ROOT}/tests/preset/_scratch"
if [[ -z "${PRESET_TEST_SCRATCH_ROOT:-}" ]]; then
    _SCRATCH_PROBE_DIR="${TMPDIR:-/tmp}"
    _SCRATCH_PROBE_DIR="${_SCRATCH_PROBE_DIR%/}"
    _SCRATCH_PROBE="${_SCRATCH_PROBE_DIR}/preset-test-probe.$$"
    # Probe with a deep `mkdir -p` because `_preset_save` itself uses
    # `mkdir -p` and trips on the same restriction.
    if mkdir -p "${_SCRATCH_PROBE}/a/b/c" 2>/dev/null; then
        rm -rf "${_SCRATCH_PROBE}" 2>/dev/null
        _SCRATCH_ROOT_DEFAULT="${_SCRATCH_PROBE_DIR}"
    fi
    unset _SCRATCH_PROBE _SCRATCH_PROBE_DIR
fi
_SCRATCH_ROOT="${PRESET_TEST_SCRATCH_ROOT:-${_SCRATCH_ROOT_DEFAULT}}"
# Ensure the repo-local fallback exists. mktemp -d will create the
# per-test workspace under it.
mkdir -p "${_SCRATCH_ROOT}" 2>/dev/null || true

# --- Platform guard --------------------------------------------------------

_require_darwin() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "FATAL: this suite targets macOS (uname -s != Darwin)." >&2
        return 1
    fi
    return 0
}

# --- Scratch dir lifecycle ------------------------------------------------

# Create a unique scratch dir. Sets:
#   TEST_SCRATCH      - absolute path to scratch
#   HOME              - scratch/home
#   TEST_TTY_OUT      - scratch/tty.out
#   TEST_TTY_IN       - scratch/tty.in
#   AI_WRAPPER_TEST_LIB - scratch/lib.bash
# Also `cd`s into TEST_SCRATCH/work so $(pwd -P) gives a path under TMPDIR.
mk_scratch() {
    mkdir -p "${_SCRATCH_ROOT}" 2>/dev/null || true
    TEST_SCRATCH="$(mktemp -d "${_SCRATCH_ROOT}/preset-test.XXXXXX")" || return 1
    mkdir "${TEST_SCRATCH}/home" || return 1
    mkdir "${TEST_SCRATCH}/work" || return 1
    HOME="${TEST_SCRATCH}/home"
    export HOME
    TEST_TTY_OUT="${TEST_SCRATCH}/tty.out"
    TEST_TTY_IN="${TEST_SCRATCH}/tty.in"
    : > "${TEST_TTY_OUT}"
    : > "${TEST_TTY_IN}"
    AI_WRAPPER_TEST_LIB="${TEST_SCRATCH}/lib.bash"
    _prepare_test_lib "${AI_WRAPPER_TEST_LIB}" "${TEST_TTY_OUT}" "${TEST_TTY_IN}" \
        || return 1
    cd "${TEST_SCRATCH}/work" || return 1
}

# Refuse to clean if the scratch dir is suspicious. Defensive.
clean_scratch() {
    local rv=$?
    if [[ -z "${TEST_SCRATCH:-}" ]]; then
        return ${rv}
    fi
    case "${TEST_SCRATCH}" in
        "${_SCRATCH_ROOT}"/*|"${TMPDIR:-/tmp}"/*|/tmp/*|/var/folders/*|/private/var/folders/*)
            ;;
        *)
            echo "REFUSING to clean unrecognised scratch path: ${TEST_SCRATCH}" >&2
            return 1
            ;;
    esac
    # Restore write perms on anything chmod-locked by the test.
    chmod -R u+rwX "${TEST_SCRATCH}" 2>/dev/null || true
    rm -rf "${TEST_SCRATCH}"
    TEST_SCRATCH=""
    return ${rv}
}

# Belt-and-braces: explode if we are about to touch the real home.
guard_home() {
    if [[ -z "${HOME:-}" ]]; then
        echo "FATAL: HOME unset in test." >&2
        exit 1
    fi
    if [[ "${HOME}" == "${_REAL_HOME}" ]]; then
        echo "FATAL: HOME equals real user home (${_REAL_HOME}); test refuses to run." >&2
        exit 1
    fi
    case "${PWD}" in
        "${_SCRATCH_ROOT}"/*|"${TMPDIR%/}"*|/tmp/*|/var/folders/*|/private/var/folders/*) ;;
        *)
            echo "FATAL: PWD=${PWD} is not under a scratch root; test refuses to run." >&2
            exit 1
            ;;
    esac
}

# --- /dev/tty substitution ------------------------------------------------

# Build a copy of ai_wrapper_lib.bash with /dev/tty rewritten to point at
# the scratch files. The only patterns in the source are `>/dev/tty` and
# `</dev/tty`.
#
# Output is rewritten to `>>${TEST_TTY_OUT}` (append, so multi-line writes
# accumulate).
#
# Input is rewritten to `<&9`. The harness's `open_tty_input` opens
# FD 9 once on `${TEST_TTY_IN}` so successive `read` calls advance through
# the file (re-opening the file by name re-reads line 1 each time, which
# is what bit the first cut of the harness — bug surfaced when
# `presets_menu` looped forever on the same `s` choice).
_prepare_test_lib() {
    local dest="${1}" tty_out="${2}" tty_in="${3}"
    if [[ ! -f "${_SRC_LIB}" ]]; then
        echo "FATAL: source lib not found at ${_SRC_LIB}" >&2
        return 1
    fi
    sed -e "s#>/dev/tty#>>${tty_out}#g" \
        -e "s#</dev/tty#<\&9#g" \
        "${_SRC_LIB}" > "${dest}" || return 1
    # Sanity: confirm there are no stray /dev/tty references left.
    if grep -qE '[<>][<>]?/dev/tty' "${dest}"; then
        echo "FATAL: sed substitution incomplete in ${dest}" >&2
        return 1
    fi
}

# Open FD 9 onto TEST_TTY_IN so subsequent `read ... <&9` calls advance.
# Idempotent: closes any prior FD 9 first. Tests call this after tty_in
# (or after appending more input) and before the first lib call that
# `read`s from /dev/tty.
open_tty_input() {
    exec 9<&- 2>/dev/null || true
    exec 9<"${TEST_TTY_IN}"
}

# Close FD 9 (used by clean_scratch indirectly via subshell exit).
close_tty_input() {
    exec 9<&- 2>/dev/null || true
}

# Source the prepared library with the minimum required shims in place.
# This is the entry point used by every test file.
source_lib() {
    export AI_WRAPPER_AGENT_NAME="test-agent"
    export AI_AGENT_COMMAND="true"
    # No-op the sandbox launcher so a stray call cannot launch anything.
    run_sandboxed_agent() { :; }
    # Stub the screen-clearing header so integration tests do not
    # actually call clear(1) and reset the developer's terminal.
    show_header() { :; }
    # The lib reads BASH_SOURCE[0] near the top; under `set -u` that is
    # safe because BASH_SOURCE is always set when the file is sourced.
    # shellcheck disable=SC1090
    . "${AI_WRAPPER_TEST_LIB}"
    # Open the input FD now so the lib's `read ... <&9` calls have a
    # source to draw from. Tests that need to rewrite TEST_TTY_IN
    # mid-test (e.g. tty_reset / tty_in for a second presets_menu
    # invocation) must call open_tty_input again afterwards.
    open_tty_input
}

# --- TTY input helpers ----------------------------------------------------

# Write the given args (joined by newlines) into TEST_TTY_IN. Re-opens
# FD 9 so the next `read ... <&9` starts at the top of the new content.
# Trailing newline is added so `read` returns 0 on the last line.
tty_in() {
    : > "${TEST_TTY_IN}"
    local line
    for line in "$@"; do
        printf '%s\n' "${line}" >> "${TEST_TTY_IN}"
    done
    # Re-point FD 9 at the fresh file so the lib's reads see new input.
    # Safe to call before source_lib (TEST_TTY_IN exists from mk_scratch).
    open_tty_input
}

# Append more input (used when a flow needs additional lines mid-test).
# Does NOT re-open FD 9 (FD 9 already points at the file by inode/path
# but `exec 9<file` resnapshots length — we re-open to be safe).
tty_in_append() {
    local line
    for line in "$@"; do
        printf '%s\n' "${line}" >> "${TEST_TTY_IN}"
    done
}

# --- Env helpers ----------------------------------------------------------

# Unset every catalog env var. Hardcoded list (mirror of _AI_SETTINGS_LIST
# in ai_wrapper_lib.bash). If the catalog changes, append to this list.
clear_catalog_env() {
    unset AI_SANDBOX_DRYRUN
    unset AI_SANDBOX_DEBUG
    unset AI_SANDBOX_PASS_ENV
    unset AI_SANDBOX_PROFILE
    unset AI_SANDBOX_PROFILE_TRUST_ME
    unset AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR
    unset AI_SANDBOX_ALLOW_RO_HOMEDIR
    unset AI_SANDBOX_ALLOW_RO_CREDENTIALS
    unset AI_SANDBOX_PASS_SSH_AGENT
    unset AI_SANDBOX_PASS_KUBE
    unset AI_SANDBOX_PASS_AWS
    unset AI_SANDBOX_PASS_GH
    unset AI_SANDBOX_PASS_GITLAB
    unset AI_SANDBOX_PASS_OPENAI
    unset AI_SANDBOX_BLOCK_LOCALHOST
    unset AI_SANDBOX_ALLOW_DOCKER
    unset AI_SANDBOX_PASS_DOCKER
    unset AI_SANDBOX_WORKDIR_WARNING
}

# --- macOS stat mode bits -------------------------------------------------

# Return the file mode bits as octal (e.g. "0644" or "644"). Caller
# matches with regex ^0?644$ to tolerate either form.
stat_mode() {
    stat -f '%A' "${1}" 2>/dev/null
}

# --- root-skip ------------------------------------------------------------

is_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

# --- TTY capture helpers --------------------------------------------------

tty_dump() {
    [[ -f "${TEST_TTY_OUT}" ]] && cat "${TEST_TTY_OUT}"
}

# Reset TTY_OUT between sub-cases inside one test file.
tty_reset() {
    : > "${TEST_TTY_OUT}"
}
