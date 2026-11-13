#!/bin/bash
# Sandbox features that exist only on the macOS (sandbox-exec) backend:
# AI_SANDBOX_DRYRUN and the AI_SANDBOX_PROFILE safety check. No Linux
# equivalent exists for either (see tests/test_catalog_os_scope.bash's
# DARWIN_ONLY_KEYS) — skips itself gracefully off-macOS so it's harmless to
# include in a shared "run everything" pass on Linux.
#
# NOTE: unlike test_sandbox_common.bash, this file was authored without
# being able to run it against real sandbox-exec (this development
# environment is Linux-only) — it's grounded in a direct reading of
# macos_sandbox_exec.bash's validation logic, but treat a first red run on
# an actual macOS CI job as expected/normal, not a sign the test itself is
# broken.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "== macOS-only sandbox tests: skipped (running on $(uname -s), not Darwin) =="
    exit 0
fi

FAKE_HOME="$(_safe_mktemp_d)" || exit 1
isolate_test_env "${FAKE_HOME}"
# shellcheck source=../bin/ai_agent_universal_wrapper.bash
source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
mkdir -p "${FAKE_HOME}/project"

cleanup() { _safe_rm_rf "${FAKE_HOME}"; }
trap cleanup EXIT

echo "== macOS-only sandbox tests =="

# --- AI_SANDBOX_DRYRUN: prints the plan, never actually launches ---
MARKER="${FAKE_HOME}/should-not-exist"
out="$(cd "${FAKE_HOME}/project" && AI_SANDBOX_DRYRUN=1 run_sandboxed_agent /usr/bin/touch -- -- "${MARKER}" 2>&1)"
rc=$?
echo "  (DRYRUN output: ${out})"
assert_eq "${rc}" "0" "AI_SANDBOX_DRYRUN=1 exits 0"
if [[ -e "${MARKER}" ]]; then
    _test_report 0 "AI_SANDBOX_DRYRUN=1 does not actually launch the command"
else
    _test_report 1 "AI_SANDBOX_DRYRUN=1 does not actually launch the command"
fi

# --- AI_SANDBOX_PROFILE safety check: refuses a profile missing the
# (version 1) / (deny default) header, unless TRUST_ME=1 ---
BAD_PROFILE="${FAKE_HOME}/bad.sb"
printf '; a profile missing the required header entirely\n(allow file-read*)\n' >"${BAD_PROFILE}"

out="$(cd "${FAKE_HOME}/project" && AI_SANDBOX_PROFILE="${BAD_PROFILE}" run_sandboxed_agent /bin/echo -- -- hi 2>&1)"
echo "  (bad-profile launch output: ${out})"
assert_contains "${out}" "lacks (version 1) and/or (deny default)" "malformed custom profile is rejected with the documented message"

out_trusted="$(cd "${FAKE_HOME}/project" && AI_SANDBOX_PROFILE="${BAD_PROFILE}" AI_SANDBOX_PROFILE_TRUST_ME=1 run_sandboxed_agent /bin/echo -- -- hi 2>&1)"
echo "  (bad-profile + TRUST_ME launch output: ${out_trusted})"
assert_not_contains "${out_trusted}" "lacks (version 1) and/or (deny default)" "AI_SANDBOX_PROFILE_TRUST_ME=1 bypasses the header check"

# The whole body is scanned (#67): an (allow default) far past the old
# 80-line window, split across lines, is still refused. Scanner edge cases
# live in tests/test_macos_credential_policy.bash.
LATE_PROFILE="${FAKE_HOME}/late.sb"
{
    printf '(version 1)\n(deny default)\n'
    for _ in $(seq 1 120); do printf '(allow file-read* (literal "/dev/null"))\n'; done
    printf '(  allow\n   default )\n'
} >"${LATE_PROFILE}"
out="$(cd "${FAKE_HOME}/project" && AI_SANDBOX_PROFILE="${LATE_PROFILE}" run_sandboxed_agent /bin/echo -- -- hi 2>&1)"
echo "  (late allow-default launch output: ${out})"
assert_contains "${out}" "contains an (allow default) rule" "(allow default) after line 80 is rejected"

tests_summary_and_exit
