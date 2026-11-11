#!/bin/bash
# Claude wrapper tests: Claude Code UI env vars (CLAUDE_CODE_NO_FLICKER,
# mouse / alternate-screen / scroll settings) reach the client through the
# scrubbed Linux sandbox env when the caller sets them, and only for Claude.
#   - _claude_pass_ui_env allowlist logic (any OS)
#   - Linux bwrap argv via a stub bwrap (claude vs copilot)
#   - Linux e2e with real bwrap and a stub claude printing its env
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
isolate_test_env "${FAKE_HOME}"
STUB_DIR="$(mktemp -d)"
cleanup() { rm -rf "${FAKE_HOME}" "${STUB_DIR}"; }
trap cleanup EXIT

source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
source "${REPO_ROOT}/bin/ai_wrapper_data/claude_wrapper_lib.bash"

OS="$(uname -s)"
NL=$'\n'
UI_VARS="CLAUDE_CODE_NO_FLICKER CLAUDE_CODE_DISABLE_MOUSE CLAUDE_CODE_DISABLE_MOUSE_CLICKS CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN CLAUDE_CODE_SCROLL_SPEED"

echo "== Claude wrapper tests (${OS}) =="

echo "-- _claude_pass_ui_env allowlist"
# Run _claude_pass_ui_env as OS with the NAME=VALUE pairs in "$@" exported
# and every UI var otherwise unset; print the resulting allowlist, or
# <unset> when the helper left AI_SANDBOX_PASS_ENV unset.
_ui_pass_env() {
    (
        local os="${1}" var; shift
        for var in ${UI_VARS}; do unset "${var}"; done
        unset AI_SANDBOX_PASS_ENV
        [[ $# -gt 0 ]] && export "$@"
        # shellcheck disable=SC2034  # read by _claude_pass_ui_env
        _wrapper_os="${os}"
        _claude_pass_ui_env
        printf '%s\n' "${AI_SANDBOX_PASS_ENV-<unset>}"
    )
}

assert_eq "$(_ui_pass_env Linux CLAUDE_CODE_NO_FLICKER=1)" "CLAUDE_CODE_NO_FLICKER" \
    "Linux: a set CLAUDE_CODE_NO_FLICKER is allowlisted"
assert_eq "$(_ui_pass_env Linux)" "<unset>" \
    "Linux: no UI var set leaves AI_SANDBOX_PASS_ENV untouched"
assert_eq "$(_ui_pass_env Linux CLAUDE_CODE_NO_FLICKER=)" "<unset>" \
    "Linux: an empty value is not allowlisted"
assert_eq "$(_ui_pass_env Linux CLAUDE_CODE_NO_FLICKER=1 CLAUDE_CODE_DISABLE_MOUSE=1 \
    CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1 CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 CLAUDE_CODE_SCROLL_SPEED=3)" \
    "CLAUDE_CODE_NO_FLICKER,CLAUDE_CODE_DISABLE_MOUSE,CLAUDE_CODE_DISABLE_MOUSE_CLICKS,CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN,CLAUDE_CODE_SCROLL_SPEED" \
    "Linux: every set UI var is allowlisted"
assert_eq "$(_ui_pass_env Linux CLAUDE_CODE_SCROLL_SPEED=3)" "CLAUDE_CODE_SCROLL_SPEED" \
    "Linux: only the set vars are allowlisted"
assert_eq "$(_ui_pass_env Linux AI_SANDBOX_PASS_ENV=MY_VAR CLAUDE_CODE_NO_FLICKER=1)" "MY_VAR,CLAUDE_CODE_NO_FLICKER" \
    "Linux: a caller's AI_SANDBOX_PASS_ENV entries are kept"
assert_eq "$(_ui_pass_env Linux "AI_SANDBOX_PASS_ENV=CLAUDE_CODE_NO_FLICKER" CLAUDE_CODE_NO_FLICKER=1)" "CLAUDE_CODE_NO_FLICKER" \
    "Linux: an already listed name is not duplicated"
assert_eq "$(_ui_pass_env Darwin CLAUDE_CODE_NO_FLICKER=1)" "<unset>" \
    "Darwin: nothing added (CLAUDE_* already passes through)"
assert_contains "$(grep -n 'CLAUDE_\*)' "${REPO_ROOT}/bin/ai_wrapper_data/macos_sandbox_exec.bash")" "CLAUDE_*" \
    "Darwin: macOS backend still passes every CLAUDE_* name"

if [[ "${OS}" == "Linux" ]]; then
    echo "-- Linux bwrap argv (stub bwrap)"
    ARGV_FILE="${STUB_DIR}/argv"
    cat >"${STUB_DIR}/bwrap" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"${ARGV_FILE}"
STUB
    printf '#!/bin/bash\necho "kernel.unprivileged_userns_clone = 1"\n' >"${STUB_DIR}/sysctl"
    chmod +x "${STUB_DIR}/bwrap" "${STUB_DIR}/sysctl"
    mkdir -p "${FAKE_HOME}/work" "${FAKE_HOME}/stubbin"
    for client in claude copilot; do
        printf '#!/bin/bash\necho RAN\n' >"${FAKE_HOME}/stubbin/${client}"
        chmod +x "${FAKE_HOME}/stubbin/${client}"
    done
    # Launch wrapper CLIENT non-interactively through the stubs with the
    # NAME=VALUE env in "$@". Sets rc and argv (one bwrap arg per line).
    _wrapper_argv() {
        local client="${1}"; shift
        rm -f "${ARGV_FILE}"
        (cd "${FAKE_HOME}/work" && export PATH="${STUB_DIR}:${FAKE_HOME}/stubbin:${PATH}" "$@" \
            && bash "${REPO_ROOT}/bin/executable_${client}_wrapper.bash" x </dev/null >/dev/null 2>&1)
        rc=$?
        argv="$(cat "${ARGV_FILE}" 2>/dev/null)"
    }

    _wrapper_argv claude CLAUDE_CODE_NO_FLICKER=1 CLAUDE_CODE_SCROLL_SPEED=3
    assert_eq "${rc}" "0" "claude: launch with UI vars set succeeds"
    assert_contains "${argv}" "--setenv${NL}CLAUDE_CODE_NO_FLICKER${NL}1" \
        "claude: bwrap gets --setenv CLAUDE_CODE_NO_FLICKER 1"
    assert_contains "${argv}" "--setenv${NL}CLAUDE_CODE_SCROLL_SPEED${NL}3" \
        "claude: bwrap gets --setenv CLAUDE_CODE_SCROLL_SPEED 3"
    assert_not_contains "${argv}" "CLAUDE_CODE_DISABLE_MOUSE" "claude: unset CLAUDE_CODE_DISABLE_MOUSE* is not passed"
    assert_not_contains "${argv}" "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN" \
        "claude: unset CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN is not passed"
    assert_eq "$(printf '%s\n' "${argv}" | grep -cx CLAUDE_CODE_NO_FLICKER)" "1" \
        "claude: CLAUDE_CODE_NO_FLICKER is set exactly once"

    _wrapper_argv claude AI_SANDBOX_PASS_ENV=MY_VAR MY_VAR=keep CLAUDE_CODE_NO_FLICKER=1
    assert_contains "${argv}" "--setenv${NL}MY_VAR${NL}keep" "claude: caller AI_SANDBOX_PASS_ENV still honoured"
    assert_contains "${argv}" "--setenv${NL}CLAUDE_CODE_NO_FLICKER${NL}1" "... alongside the UI var"

    _wrapper_argv claude _NOOP=1
    assert_eq "${rc}" "0" "claude: launch without UI vars succeeds"
    assert_contains "${argv}" "--clearenv" "claude: env is still cleared"
    assert_not_contains "${argv}" "CLAUDE_CODE_" "claude: no UI var passed when none is set"

    _wrapper_argv copilot CLAUDE_CODE_NO_FLICKER=1 CLAUDE_CODE_SCROLL_SPEED=3
    assert_eq "${rc}" "0" "copilot: launch with Claude UI vars set succeeds"
    assert_contains "${argv}" "--setenv${NL}COPILOT_ALLOW_ALL${NL}true" "copilot: its own passthrough is unchanged"
    assert_not_contains "${argv}" "CLAUDE_CODE_" "copilot: Claude UI vars are not passed to other agents"
else
    echo "  skip - bwrap argv checks are Linux-only"
fi

if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    echo "-- Linux e2e (real bwrap, stub claude)"
    mkdir -p "${FAKE_HOME}/bin" "${FAKE_HOME}/work"
    cat >"${FAKE_HOME}/bin/claude" <<'STUB'
#!/bin/bash
printf 'NO_FLICKER=%s\n' "${CLAUDE_CODE_NO_FLICKER:-<unset>}"
printf 'DISABLE_MOUSE=%s\n' "${CLAUDE_CODE_DISABLE_MOUSE:-<unset>}"
STUB
    chmod +x "${FAKE_HOME}/bin/claude"
    assert_client_is_fake claude
    out="$(cd "${FAKE_HOME}/work" && CLAUDE_CODE_NO_FLICKER=1 \
        bash "${REPO_ROOT}/bin/executable_claude_wrapper.bash" x </dev/null 2>&1)"
    assert_contains "${out}" "NO_FLICKER=1" "sandboxed claude sees CLAUDE_CODE_NO_FLICKER=1"
    assert_contains "${out}" "DISABLE_MOUSE=<unset>" "sandboxed claude does not see an unset UI var"
    out="$(cd "${FAKE_HOME}/work" && bash "${REPO_ROOT}/bin/executable_claude_wrapper.bash" x </dev/null 2>&1)"
    assert_contains "${out}" "NO_FLICKER=<unset>" "control: without the caller var the sandbox has none"
else
    echo "  skip - bwrap e2e (Linux with bwrap only)"
fi

assert_no_live_client_reached
tests_summary_and_exit
