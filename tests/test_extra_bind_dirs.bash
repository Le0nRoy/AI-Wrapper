#!/bin/bash
# Functional smoke tests for AI_SANDBOX_EXTRA_{RW,RO}_DIRS and its
# sensitivity guard, via the shared run_sandboxed_agent() entry point.
#
# Specifically regression-tests a bug caught in review: the guard must
# only ever examine directories that came from AI_SANDBOX_EXTRA_RW_DIRS /
# AI_SANDBOX_EXTRA_RO_DIRS. An earlier draft scanned the wrapper's own
# --bind flags too (e.g. the ~/.claude bind every real launch carries),
# which made the guard refuse to launch at all any time both a trusted
# wrapper bind AND the extra-dirs env var were present — i.e. every real
# launch. See tests/test_sandbox_common.bash for the FAKE_HOME rationale.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"
# shellcheck source=../bin/ai_agent_universal_wrapper.bash
source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
export HOME="${FAKE_HOME}"
mkdir -p "${FAKE_HOME}/project" "${FAKE_HOME}/.claude" "${FAKE_HOME}/extra_data" "${FAKE_HOME}/.ssh"
echo "extra-dir-ok" >"${FAKE_HOME}/extra_data/marker.txt"

cleanup() { rm -rf "${FAKE_HOME}"; }
trap cleanup EXIT

echo "== AI_SANDBOX_EXTRA_{RW,RO}_DIRS smoke tests ($(uname -s)) =="

# --- a benign extra dir is actually bound and readable ---
out="$(cd "${FAKE_HOME}/project" && AI_SANDBOX_EXTRA_RW_DIRS="${FAKE_HOME}/extra_data" \
    run_sandboxed_agent /bin/cat -- -- "${FAKE_HOME}/extra_data/marker.txt" 2>&1)"
rc=$?
echo "  (benign extra-dir read output: ${out})"
assert_eq "${rc}" "0" "benign AI_SANDBOX_EXTRA_RW_DIRS entry launches successfully"
assert_contains "${out}" "extra-dir-ok" "benign AI_SANDBOX_EXTRA_RW_DIRS entry is actually bound and readable"

# --- REGRESSION: a wrapper-internal trusted bind (~/.claude, as every
# real claude_wrapper launch passes via WRAPPER_FLAGS) must NOT be
# rejected by the extra-dirs sensitivity guard just because
# AI_SANDBOX_EXTRA_RW_DIRS is also set in the same call. ---
# macOS backend is single-arg (--bind SRC); Linux bwrap is two-arg (--bind SRC DST).
if [[ "$(uname -s)" == "Darwin" ]]; then
    _test_bind_flags=(--bind "${FAKE_HOME}/.claude")
else
    _test_bind_flags=(--bind "${FAKE_HOME}/.claude" "${FAKE_HOME}/.claude")
fi
out="$(cd "${FAKE_HOME}/project" && AI_SANDBOX_EXTRA_RW_DIRS="${FAKE_HOME}/extra_data" \
    run_sandboxed_agent /bin/echo -- "${_test_bind_flags[@]}" -- trusted-bind-ok 2>&1)"
rc=$?
unset _test_bind_flags
echo "  (trusted ~/.claude bind + extra dir output: ${out})"
assert_eq "${rc}" "0" "wrapper-internal ~/.claude bind is not rejected by the extra-dirs guard"
assert_contains "${out}" "trusted-bind-ok" "command still runs when both a trusted bind and an extra dir are present"

# --- a genuinely user-supplied sensitive extra dir is still refused ---
out="$(cd "${FAKE_HOME}/project" && AI_SANDBOX_EXTRA_RW_DIRS="${FAKE_HOME}/.ssh" \
    run_sandboxed_agent /bin/echo -- -- hi 2>&1)"
rc=$?
echo "  (sensitive extra-dir refusal output: ${out})"
assert_eq "${rc}" "1" "AI_SANDBOX_EXTRA_RW_DIRS pointing under a HOME dotfile dir is refused"

# --- the refusal has the same override escape hatch ---
out="$(cd "${FAKE_HOME}/project" && AI_SANDBOX_EXTRA_RW_DIRS="${FAKE_HOME}/.ssh" \
    AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 run_sandboxed_agent /bin/echo -- -- hi 2>&1)"
rc=$?
assert_eq "${rc}" "0" "AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 overrides the extra-dirs refusal too"

tests_summary_and_exit
