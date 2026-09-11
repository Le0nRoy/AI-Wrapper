#!/usr/bin/env bash
# Assertion helpers. Each prints a structured FAIL line on mismatch and
# returns non-zero. Tests run each case in a sub-process so a failed
# assertion aborts only that case.

# Print a FAIL line and capture context. Caller is expected to exit
# non-zero. Args: case_id, message, expected, actual
_fail() {
    local case_id="${1}" msg="${2}" expected="${3:-}" actual="${4:-}"
    printf 'FAIL %s: %s\n' "${case_id}" "${msg}" >&2
    if [[ -n "${expected}" || -n "${actual}" ]]; then
        printf '  expected: %s\n' "${expected}" >&2
        printf '  actual:   %s\n' "${actual}" >&2
    fi
    if [[ -n "${TEST_TTY_OUT:-}" && -f "${TEST_TTY_OUT}" ]]; then
        printf '  --- TTY_OUT (last 40 lines) ---\n' >&2
        tail -n 40 "${TEST_TTY_OUT}" | sed 's/^/    /' >&2
        printf '  --- end ---\n' >&2
    fi
    return 1
}

assert_eq() {
    local case_id="${1}" expected="${2}" actual="${3}"
    if [[ "${expected}" != "${actual}" ]]; then
        _fail "${case_id}" "values differ" "${expected}" "${actual}"
        return 1
    fi
    return 0
}

assert_match() {
    local case_id="${1}" needle="${2}" haystack="${3}"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        _fail "${case_id}" "expected to contain '${needle}'" "${needle}" "${haystack}"
        return 1
    fi
    return 0
}

assert_unmatch() {
    local case_id="${1}" needle="${2}" haystack="${3}"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        _fail "${case_id}" "expected NOT to contain '${needle}'" "(absent)" "${haystack}"
        return 1
    fi
    return 0
}

assert_file_exists() {
    local case_id="${1}" path="${2}"
    if [[ ! -e "${path}" ]]; then
        _fail "${case_id}" "expected file to exist: ${path}"
        return 1
    fi
    return 0
}

assert_file_absent() {
    local case_id="${1}" path="${2}"
    if [[ -e "${path}" ]]; then
        _fail "${case_id}" "expected file NOT to exist: ${path}"
        return 1
    fi
    return 0
}

assert_returns_zero() {
    local case_id="${1}" rc="${2}"
    if (( rc != 0 )); then
        _fail "${case_id}" "expected return 0, got ${rc}"
        return 1
    fi
    return 0
}

assert_returns_nonzero() {
    local case_id="${1}" rc="${2}"
    if (( rc == 0 )); then
        _fail "${case_id}" "expected non-zero return, got 0"
        return 1
    fi
    return 0
}

# Assert a regex matches. Uses bash =~ (no PCRE).
assert_regex() {
    local case_id="${1}" pattern="${2}" actual="${3}"
    if [[ ! "${actual}" =~ ${pattern} ]]; then
        _fail "${case_id}" "expected to match regex /${pattern}/" "${pattern}" "${actual}"
        return 1
    fi
    return 0
}

# Match a tty-out file against a needle.
assert_tty_contains() {
    local case_id="${1}" needle="${2}"
    local content=""
    [[ -f "${TEST_TTY_OUT}" ]] && content="$(cat "${TEST_TTY_OUT}")"
    if [[ "${content}" != *"${needle}"* ]]; then
        _fail "${case_id}" "TTY_OUT missing '${needle}'" "${needle}" "${content}"
        return 1
    fi
    return 0
}

assert_tty_lacks() {
    local case_id="${1}" needle="${2}"
    local content=""
    [[ -f "${TEST_TTY_OUT}" ]] && content="$(cat "${TEST_TTY_OUT}")"
    if [[ "${content}" == *"${needle}"* ]]; then
        _fail "${case_id}" "TTY_OUT unexpectedly contains '${needle}'" "(absent)" "${content}"
        return 1
    fi
    return 0
}
