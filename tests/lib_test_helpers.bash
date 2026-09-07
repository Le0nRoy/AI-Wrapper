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
