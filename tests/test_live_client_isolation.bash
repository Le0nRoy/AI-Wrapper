#!/bin/bash
# Regression canaries for isolate_test_env (tests/lib_test_helpers.bash):
# wrapper tests must never reach a real, possibly authenticated AI client
# through the host PATH, the real HOME, or inherited shell/env state.
#
# Simulated "live" clients are canary scripts that only touch a marker file;
# no real client is ever executed. Covers:
#   - a live client in a non-HOME PATH dir (stands in for /usr/local/bin or
#     /usr/bin, which a test cannot write) is shadowed by the trap
#   - PATH entries under the real HOME, and empty/relative entries, dropped
#   - exported shell functions, BASH_ENV, client/wrapper env vars and
#     credentials from the parent environment are cleared
#   - HOME / XDG_* point into the fake HOME; toolchain dirs are kept
#   - end-to-end (Linux + bwrap): a wrapper launched without a stub hits the
#     trap inside the sandbox, not a live client
#
# PATH hygiene is not filesystem confinement; this file does not claim
# host files are unreadable to tests.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

REAL_HOME="${HOME}"
FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
# Outside the real HOME so its PATH entry survives the filter, like a
# system-wide install would.
LIVE_DIR="$(mktemp -d)"
LIVE_MARK="${LIVE_DIR}/reached"
HOME_LIVE_DIR="${FAKE_HOME}-homebin"
cleanup() { rm -rf "${FAKE_HOME}" "${LIVE_DIR}" "${HOME_LIVE_DIR}"; }
trap cleanup EXIT

OS="$(uname -s)"
echo "== live client isolation canaries (${OS}) =="

# --- Hostile parent environment ---------------------------------------------
mkdir -p "${LIVE_DIR}/bin" "${HOME_LIVE_DIR}"
for client in ${TEST_AI_CLIENTS} live-only-client; do
    printf '#!/bin/sh\necho LIVE >>"%s"\n' "${LIVE_MARK}" >"${LIVE_DIR}/bin/${client}"
    chmod +x "${LIVE_DIR}/bin/${client}"
done
cp "${LIVE_DIR}/bin/live-only-client" "${HOME_LIVE_DIR}/home-only-client"
printf 'codex() { echo LIVE >>"%s"; }\n' "${LIVE_MARK}" >"${LIVE_DIR}/bash_env"
# shellcheck disable=SC2329,SC2317  # invoked indirectly via export -f
claude() { echo LIVE >>"${LIVE_MARK}"; }
export -f claude
export BASH_ENV="${LIVE_DIR}/bash_env"
export PATH="${LIVE_DIR}/bin:${HOME_LIVE_DIR}::.:${PATH}"
export XDG_CONFIG_HOME="${REAL_HOME}/.config" CODEX_HOME="${REAL_HOME}/.codex"
export AI_WRAPPER_EXTRA_PROFILE="${LIVE_DIR}/bash_env" CODEX_ACCOUNT=live
export GITHUB_TOKEN=canary-not-a-secret OPENAI_API_KEY=canary-not-a-secret
export GIT_DIR="${REAL_HOME}/.git"
TOOLCHAIN_BEFORE="$(command -v bash) $(command -v git 2>/dev/null)"

isolate_test_env "${FAKE_HOME}"

# --- Environment after isolation -------------------------------------------
echo "-- environment"
assert_eq "${HOME}" "${FAKE_HOME}" "HOME is the fake HOME"
for v in XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; do
    assert_contains "${!v}/" "${FAKE_HOME}/" "${v} is under the fake HOME"
done
for v in BASH_ENV CODEX_HOME AI_WRAPPER_EXTRA_PROFILE CODEX_ACCOUNT GITHUB_TOKEN OPENAI_API_KEY GIT_DIR; do
    assert_eq "${!v+set}" "" "inherited ${v} is cleared"
done
assert_eq "$(bash -c 'type -t claude')" "file" "exported claude() function no longer shadows PATH in children"
assert_eq "$(bash -c 'type -t codex')" "file" "BASH_ENV codex() function is not loaded by children"

echo "-- PATH"
assert_eq "${PATH%%:*}" "${FAKE_HOME}/bin" "fake HOME bin dir is first on PATH"
assert_not_contains ":${PATH}:" "::" "no empty PATH entries"
assert_not_contains ":${PATH}:" ":.:" "no relative PATH entries"
assert_not_contains ":${PATH}:" ":${HOME_LIVE_DIR}:" "PATH entry under the real HOME dropped"
assert_eq "$(command -v home-only-client)" "" "client installed only under the real HOME is unreachable"
assert_contains ":${PATH}:" ":${LIVE_DIR}/bin:" "non-HOME PATH dirs (toolchains) are kept"
assert_eq "$(command -v bash) $(command -v git 2>/dev/null)" "${TOOLCHAIN_BEFORE}" "bash and git resolve as before"

echo "-- fail-closed traps"
for client in ${TEST_AI_CLIENTS}; do
    assert_client_is_fake "${client}"
    err="$("${client}" --help 2>&1)"; rc=$?
    assert_eq "${rc}" "${LIVE_CLIENT_TRAP_RC}" "un-stubbed ${client} hits the trap"
    assert_contains "${err}" "LIVE_CLIENT_TRAP" "... and says so"
done
assert_eq "$(bash -c 'codex; claude' 2>/dev/null; echo "rc=$?")" "rc=${LIVE_CLIENT_TRAP_RC}" \
    "child bash resolves clients to traps"
assert_eq "$(ls -A "${HOME}/.live-client-trap" | sort | tr '\n' ' ')" "$(printf '%s\n' ${TEST_AI_CLIENTS} | sort | tr '\n' ' ')" \
    "trap hits are recorded for every client"
rm -rf "${HOME}/.live-client-trap"

# A test's own stub replaces exactly one trap.
printf '#!/bin/sh\necho STUB\n' >"${FAKE_HOME}/bin/codex"
assert_eq "$(codex)" "STUB" "a test stub overrides its trap"
assert_eq "$(claude 2>/dev/null; echo "rc=$?")" "rc=${LIVE_CLIENT_TRAP_RC}" "... other clients stay trapped"
install_live_client_trap "${FAKE_HOME}/bin/codex"
rm -rf "${HOME}/.live-client-trap"

# A stub in ~/.local/bin with its ~/bin trap removed (the agy e2e layout)
# resolves to the stub only when ~/.local/bin is on the evaluation PATH;
# otherwise the live client in a system-like dir wins.
mkdir -p "${FAKE_HOME}/.local/bin"
printf '#!/bin/sh\necho STUB\n' >"${FAKE_HOME}/.local/bin/agy"
chmod +x "${FAKE_HOME}/.local/bin/agy"
rm -f "${FAKE_HOME}/bin/agy"
hash -r
PATH="${FAKE_HOME}/.local/bin:${PATH}" assert_client_is_fake agy
assert_eq "$(PATH="${FAKE_HOME}/.local/bin:${PATH}" agy)" "STUB" "... and runs the ~/.local/bin stub"
assert_eq "$(command -v agy)" "${LIVE_DIR}/bin/agy" "without ~/.local/bin on PATH the trap-less agy is not fake"
install_live_client_trap "${FAKE_HOME}/bin/agy"
rm -f "${FAKE_HOME}/.local/bin/agy"
hash -r
assert_client_is_fake agy

echo "-- end-to-end: un-stubbed client inside the sandbox"
if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    mkdir -p "${FAKE_HOME}/work"
    for agent in codex claude; do
        out="$(cd "${FAKE_HOME}/work" && bash "${REPO_ROOT}/bin/executable_${agent}_wrapper.bash" x </dev/null 2>&1)"
        rc=$?
        assert_eq "$([[ "${rc}" -ne 0 ]] && echo failed || echo succeeded)" "failed" "${agent} wrapper without a stub fails closed"
        assert_contains "${out}" "LIVE_CLIENT_TRAP: unstubbed ${agent}" "... the trap ran inside the sandbox"
    done
else
    echo "  skip - Linux + bwrap required"
fi

assert_eq "$([[ -e "${LIVE_MARK}" ]] && echo reached || echo untouched)" "untouched" \
    "no simulated live client was ever executed"

tests_summary_and_exit
