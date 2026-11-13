#!/bin/bash
# Self-test for _safe_mktemp_d / _safe_rm_rf (tests/lib_test_helpers.bash),
# the guards against the 2026-11 incident where a failed mktemp left
# FAKE_HOME empty, `cd ""` resolved it to the repo root and cleanup's
# rm -rf deleted the checkout.
#
# Everything happens inside one temp dir under ${TMPDIR:-/tmp}. The
# "checkout" and "real home" the guard protects are redirected to
# sacrificial dirs inside it, so no refusal case ever points at a real
# path: a broken guard can only delete this test's own temp dir.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

echo "== safe temp-dir helpers =="

BASE="$(_safe_mktemp_d "${TMPDIR:-/tmp}/ai-wrapper-guard-test.XXXXXX")" || exit 1
trap '_safe_rm_rf "${BASE}"' EXIT
_yes() { if "$@"; then echo yes; else echo no; fi; }

# Sacrificial stand-ins, set in the subshells that run the guard.
FAKE_ROOT="${BASE}/home/checkout"
mkdir -p "${FAKE_ROOT}/tests" "${BASE}/tmp/plain" "${BASE}/home/work.AbC123"
_guarded() {  # CMD...: run with the protected paths redirected into BASE
    ( _TEST_REPO_ROOT="${FAKE_ROOT}"; _TEST_REAL_HOME="${BASE}/home"; cd "${FAKE_ROOT}" && "$@" ) 2>&1
}

# ---------------------------------------------------------------------------
echo "-- _safe_mktemp_d"
made="$(_safe_mktemp_d "${BASE}/tmp/new.XXXXXX")"
assert_eq "$?" 0 "creates a dir"
assert_eq "$(_yes test -d "${made}")" yes "prints an existing directory"
assert_eq "${made}" "$(cd "${made}" && pwd -P)" "prints the physical path"
out="$(_safe_mktemp_d "${BASE}/missing/sub/new.XXXXXX" 2>/dev/null)"
assert_eq "$?" 1 "mktemp failure: returns 1"
assert_eq "${out}" "" "mktemp failure: prints no path (never an empty string to cd into)"
assert_contains "$(_safe_mktemp_d "${BASE}/missing/new.XXXXXX" 2>&1 >/dev/null)" "FATAL" "mktemp failure: reason on stderr"

# ---------------------------------------------------------------------------
echo "-- _safe_rm_rf refusals"
# No "/" case: a broken guard must never get a target outside BASE.
for target in . "tmp/plain"; do
    out="$(_guarded _safe_rm_rf "${target}")"
    assert_contains "${out}" "REFUSING" "refuses '${target}'"
done
for target in "${FAKE_ROOT}" "${FAKE_ROOT}/" "${BASE}/home" "${BASE}" "${FAKE_ROOT}/tests/.."; do
    out="$(_guarded _safe_rm_rf "${target}")"
    assert_contains "${out}" "REFUSING" "refuses the checkout, the home or an ancestor (${target#"${BASE}"})"
done
assert_eq "$(_yes test -d "${FAKE_ROOT}/tests")" yes "protected stand-ins still exist"
out="$(_guarded _safe_rm_rf "${BASE}/tmp/plain")"
assert_contains "${out}" "not a test temp dir name" "refuses a dir not named like a mktemp result"
assert_eq "$(_yes test -d "${BASE}/tmp/plain")" yes "... and leaves it"
out="$(_guarded _safe_rm_rf "")"
assert_eq "${out}" "" "empty argument (never created): skipped silently"

# ---------------------------------------------------------------------------
echo "-- _safe_rm_rf removals"
_guarded _safe_rm_rf "${made}" "${BASE}/home/work.AbC123" >/dev/null
assert_eq "$(_yes test -e "${made}")" no "removes a _safe_mktemp_d dir"
assert_eq "$(_yes test -e "${BASE}/home/work.AbC123")" no "removes a temp-named dir under the home"
assert_eq "$(_yes test -d "${FAKE_ROOT}/tests")" yes "checkout stand-in untouched"

tests_summary_and_exit
