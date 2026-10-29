#!/bin/bash
# Shared assertion helpers for ai-wrapper's test scripts. Sourced, not run
# directly. Deliberately dependency-free (no test framework) to match the
# rest of this repo's plain-bash style, and to keep these tests runnable
# as-is on bash 3.2 (macOS) as well as bash 5 (Linux CI).

TESTS_RUN=0
TESTS_FAILED=0

_test_report() {
    local ok="${1}" desc="${2}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "${ok}" == "1" ]]; then
        printf '  ok   - %s\n' "${desc}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '  FAIL - %s\n' "${desc}" >&2
    fi
}

assert_eq() {
    local actual="${1}" expected="${2}" desc="${3}"
    if [[ "${actual}" == "${expected}" ]]; then
        _test_report 1 "${desc}"
    else
        _test_report 0 "${desc} (expected [${expected}], got [${actual}])"
    fi
}

assert_contains() {
    local haystack="${1}" needle="${2}" desc="${3}"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        _test_report 1 "${desc}"
    else
        _test_report 0 "${desc} (expected to find [${needle}])"
    fi
}

assert_not_contains() {
    local haystack="${1}" needle="${2}" desc="${3}"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        _test_report 1 "${desc}"
    else
        _test_report 0 "${desc} (expected NOT to find [${needle}])"
    fi
}

# Call at the end of every test file. Prints a summary and returns/exits
# non-zero if any assertion in this file failed, so `set -e` callers (and
# CI step failure) propagate correctly.
tests_summary_and_exit() {
    echo ""
    echo "${TESTS_RUN} tests, ${TESTS_FAILED} failed"
    if [[ "${TESTS_FAILED}" -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Test environment isolation
# ---------------------------------------------------------------------------
# Client binaries the wrappers launch (AI_AGENT_COMMAND in
# bin/ai_wrapper_data/*_lib.bash) plus related AI CLIs a host may carry.
# Every one of them gets a fail-closed trap in the fake HOME's bin dir.
TEST_AI_CLIENTS="claude codex agy copilot cursor-agent gemini"
# Exit status of a trap; distinct from 0/1/2/127 so it never looks like a
# normal client or wrapper result.
LIVE_CLIENT_TRAP_RC=97
# Directories on the sandbox's own PATH (see --setenv PATH in
# ai_agent_universal_wrapper.bash). A client installed here wins over
# ~/.local/bin inside bwrap, whatever the test's PATH says.
SANDBOX_SYSTEM_BIN_DIRS="/usr/bin /usr/sbin /bin /sbin"

# isolate_test_env FAKE_HOME
#
# Call right after creating FAKE_HOME, before sourcing wrapper code or
# launching anything. Afterwards:
#   - HOME and XDG_{CONFIG,DATA,STATE,CACHE}_HOME point into FAKE_HOME;
#   - inherited wrapper settings, client state/credential variables, git
#     redirections, BASH_ENV/ENV and exported shell functions are gone, so
#     the host environment cannot steer a wrapper or shadow a stub;
#   - PATH is FAKE_HOME/bin followed by the host PATH minus empty/relative
#     entries and entries under the real HOME (where per-user client
#     installs live). Toolchains elsewhere (/usr/local, Homebrew, /usr/bin)
#     stay available;
#   - FAKE_HOME/bin holds a fail-closed trap for every TEST_AI_CLIENTS name.
#     A test that needs a client overwrites that one trap with its stub.
#     FAKE_HOME/bin is also first on the bwrap sandbox PATH, so an
#     un-stubbed client resolves to the trap on the host and in the sandbox,
#     even when a real client is installed in /usr/bin or /usr/local/bin.
#
# This is PATH/env hygiene for tests, not confinement: nothing here makes
# host files unreadable. Never pass a real HOME.
isolate_test_env() {
    local fake_home="${1:?isolate_test_env: FAKE_HOME required}"
    local real_home="${HOME}"
    if [[ "${fake_home}" != /* || "${fake_home}" == "${real_home}" ]]; then
        echo "FATAL: isolate_test_env needs an absolute fake HOME (got ${fake_home})" >&2
        exit 1
    fi

    # Stop exporting every function (bash 3.2's `declare -F` does not show
    # the export attribute, so do not filter on it), and drop any function
    # named like a client so it cannot shadow a trap in this shell.
    local _kw fn_name client
    while read -r _kw fn_name; do
        export -nf "${fn_name##* }"
    done < <(declare -F)
    for client in ${TEST_AI_CLIENTS}; do
        unset -f "${client}"
    done
    unset BASH_ENV ENV CDPATH

    local var
    for var in $(compgen -e); do
        case "${var}" in
            AI_SANDBOX_*|AI_WRAPPER_*|AI_AGENT_*|*_ACCOUNT|WRAPPER_DATA_DIR| \
            CLAUDE_*|ANTHROPIC_*|CODEX_*|OPENAI_*|GEMINI_*|GOOGLE_*|AGY_*| \
            ANTIGRAVITY_*|COPILOT_*|CURSOR_*|GH_*|GITHUB_*|GITLAB_*|GLAB_*| \
            CI_JOB_TOKEN|AWS_*|KUBECONFIG|DOCKER_*|SSH_AUTH_SOCK|SSH_ASKPASS| \
            GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_COMMON_DIR|GIT_CONFIG*| \
            GIT_ASKPASS|*TOKEN*|*API_KEY*|*SECRET*|*PASSWORD*)
                unset "${var}" ;;
        esac
    done

    export HOME="${fake_home}"
    export XDG_CONFIG_HOME="${fake_home}/.config"
    export XDG_DATA_HOME="${fake_home}/.local/share"
    export XDG_STATE_HOME="${fake_home}/.local/state"
    export XDG_CACHE_HOME="${fake_home}/.cache"

    local kept="" entry old_ifs="${IFS}"
    IFS=:
    for entry in ${PATH}; do
        case "${entry}" in
            ""|[!/]*|"${real_home}"|"${real_home}"/*) continue ;;
        esac
        kept="${kept}:${entry}"
    done
    IFS="${old_ifs}"
    export PATH="${fake_home}/bin${kept}"
    hash -r

    mkdir -p "${fake_home}/bin"
    for client in ${TEST_AI_CLIENTS}; do
        install_live_client_trap "${fake_home}/bin/${client}"
    done
}

# install_live_client_trap PATH — (re)install a fail-closed trap at PATH.
# The trap never execs anything: it reports on stderr, records itself
# under $HOME/.live-client-trap when that is writable (best effort: the
# sandbox may mount HOME read-only, so stub-output assertions remain the
# primary in-sandbox check), and exits LIVE_CLIENT_TRAP_RC.
install_live_client_trap() {
    local trap_path="${1}"
    cat >"${trap_path}" <<TRAP
#!/bin/sh
echo "LIVE_CLIENT_TRAP: unstubbed \${0##*/} reached; refusing to run a real client" >&2
mkdir -p "${HOME}/.live-client-trap" 2>/dev/null && : 2>/dev/null >>"${HOME}/.live-client-trap/\${0##*/}"
exit ${LIVE_CLIENT_TRAP_RC}
TRAP
    chmod +x "${trap_path}"
}

# Print the first executable NAME in SANDBOX_SYSTEM_BIN_DIRS, if any.
sandbox_system_client() {
    local name="${1}" dir
    for dir in ${SANDBOX_SYSTEM_BIN_DIRS}; do
        if [[ -x "${dir}/${name}" ]]; then
            printf '%s\n' "${dir}/${name}"
            return 0
        fi
    done
    return 1
}

# Fail unless NAME resolves (via the current PATH) inside FAKE_HOME.
assert_client_is_fake() {
    local name="${1}" resolved
    resolved="$(command -v "${name}" 2>/dev/null)"
    if [[ -n "${resolved}" && "${resolved}" == "${HOME}"/* ]]; then
        _test_report 1 "${name} resolves inside the fake HOME"
    else
        _test_report 0 "${name} resolves inside the fake HOME (got [${resolved:-<none>}])"
    fi
}

# Fail if any trap recorded a hit. Call before tests_summary_and_exit in
# files that launch wrappers.
assert_no_live_client_reached() {
    local hits=""
    if [[ -d "${HOME}/.live-client-trap" ]]; then
        hits="$(ls -A "${HOME}/.live-client-trap")"
    fi
    assert_eq "${hits}" "" "no un-stubbed AI client was reached"
}
