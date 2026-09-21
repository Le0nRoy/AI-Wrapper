#!/usr/bin/env bash
# Top-level runner for the preset test suite.
#
# 1. Smoke-tests the /dev/tty substitution strategy (planner's risk #1).
# 2. Discovers every tests/preset/unit/*.bash and tests/preset/integration/*.bash.
# 3. Runs each in its own bash sub-process; captures stdout/stderr.
# 4. Surfaces failure details verbatim.
# 5. Prints "N passed, M failed, K skipped" and exits non-zero on any failure.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PRESET_DIR="${SCRIPT_DIR}/preset"
SRC_LIB="${REPO_ROOT}/ai_wrapper_data/ai_wrapper_lib.bash"

# Platform guard (the lib targets macOS; integration helpers use stat -f).
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "FATAL: this suite targets macOS (uname -s != Darwin)." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Smoke test #1: /dev/tty substitution must produce a runnable lib copy and
# the rewritten lib must still let the helpers print user-facing text.
# Honours planner risk callout #1.
# ---------------------------------------------------------------------------

smoke_tty_substitution() {
    local tmp out_file lib_copy
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/preset-smoke.XXXXXX")" || return 1
    out_file="${tmp}/tty.out"
    lib_copy="${tmp}/lib.bash"
    : > "${out_file}"

    if [[ ! -f "${SRC_LIB}" ]]; then
        echo "FATAL: source lib not found at ${SRC_LIB}" >&2
        rm -rf "${tmp}"
        return 1
    fi

    # Same substitution the harness performs. Output -> append, input -> FD 9.
    sed -e "s#>/dev/tty#>>${out_file}#g" \
        -e "s#</dev/tty#<\&9#g" \
        "${SRC_LIB}" > "${lib_copy}" || { rm -rf "${tmp}"; return 1; }

    # Sanity: nothing actionable left referencing /dev/tty.
    if grep -qE '[<>][<>]?/dev/tty' "${lib_copy}"; then
        echo "FATAL: /dev/tty substitution left actionable references in lib copy:" >&2
        grep -nE '[<>][<>]?/dev/tty' "${lib_copy}" >&2
        rm -rf "${tmp}"
        return 1
    fi

    # Parse-check (bash -n) the rewritten lib.
    if ! bash -n "${lib_copy}" 2>"${tmp}/parse.err"; then
        echo "FATAL: rewritten lib failed bash -n:" >&2
        cat "${tmp}/parse.err" >&2
        rm -rf "${tmp}"
        return 1
    fi

    # Functional check: source the rewritten lib with the minimum shims and
    # exercise _preset_autosave (with a bad dir) so it emits a WARN to
    # the captured tty output. We make the config dir unwritable to force
    # the mkdir failure path.
    (
        set +u
        export AI_WRAPPER_AGENT_NAME="smoke"
        export AI_AGENT_COMMAND="true"
        run_sandboxed_agent() { :; }
        show_header() { :; }
        : > "${tmp}/tty.in"
        exec 9<"${tmp}/tty.in"
        # shellcheck disable=SC1090
        . "${lib_copy}"
        # Point XDG_CONFIG_HOME at an unwritable path to trigger the WARN.
        export HOME="${tmp}"
        mkdir -p "${tmp}/work"
        cd "${tmp}/work"
        export XDG_CONFIG_HOME="${tmp}/nodir/noparent"
        # _preset_autosave_path just computes, _preset_autosave tries to mkdir.
        _preset_autosave 2>/dev/null || true
    )

    if ! grep -q 'WARN\|workdir\|ai-wrapper' "${out_file}" 2>/dev/null; then
        echo "FATAL: smoke test could not capture /dev/tty output." >&2
        echo "       Expected WARN or workdir in ${out_file}; got:" >&2
        sed 's/^/    /' "${out_file}" >&2 2>/dev/null || true
        rm -rf "${tmp}"
        return 1
    fi

    rm -rf "${tmp}"
    return 0
}

echo "smoke: /dev/tty substitution..."
if ! smoke_tty_substitution; then
    echo "ABORT: /dev/tty substitution smoke test failed; refusing to run suite." >&2
    exit 2
fi
echo "smoke: ok"
echo ""

# ---------------------------------------------------------------------------
# Discover and run test files.
# Per-file outcome counted as a single test for the file-level summary;
# the file's own "SUMMARY ... pass=N fail=M skip=K" line gives the case-level
# count, which we sum into TOTAL_PASS/FAIL/SKIP.
# ---------------------------------------------------------------------------

FILES_PASS=0
FILES_FAIL=0
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FAILED_FILES=()

run_one() {
    local kind="${1}" file="${2}"
    local short out rc
    short="$(basename "${file}")"
    out="$(bash "${file}" 2>&1)"
    rc=$?
    # Extract counts from the SUMMARY line written by each file's footer.
    local pass=0 fail=0 skip=0
    local summary
    summary="$(printf '%s\n' "${out}" | grep -E '^SUMMARY ' | tail -n1)"
    if [[ -n "${summary}" ]]; then
        pass="$(printf '%s' "${summary}" | sed -E 's/.*pass=([0-9]+).*/\1/')"
        fail="$(printf '%s' "${summary}" | sed -E 's/.*fail=([0-9]+).*/\1/')"
        skip="$(printf '%s' "${summary}" | sed -E 's/.*skip=([0-9]+).*/\1/')"
    fi
    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
    TOTAL_SKIP=$((TOTAL_SKIP + skip))
    if (( rc == 0 && fail == 0 )); then
        FILES_PASS=$((FILES_PASS + 1))
        printf '[%-4s] %-44s PASS  (%d pass, %d skip)\n' "${kind}" "${short}" "${pass}" "${skip}"
    else
        FILES_FAIL=$((FILES_FAIL + 1))
        FAILED_FILES+=("${file}")
        printf '[%-4s] %-44s FAIL  (rc=%d, %d pass, %d fail, %d skip)\n' \
            "${kind}" "${short}" "${rc}" "${pass}" "${fail}" "${skip}"
        # Surface full output for diagnosis (verbatim per instructions).
        printf -- '----- begin output: %s -----\n' "${short}"
        printf '%s\n' "${out}"
        printf -- '----- end output: %s -----\n' "${short}"
    fi
}

# Unit tests.
for f in "${PRESET_DIR}"/unit/*.bash; do
    [[ -f "${f}" ]] || continue
    run_one "unit" "${f}"
done

# Integration tests.
for f in "${PRESET_DIR}"/integration/*.bash; do
    [[ -f "${f}" ]] || continue
    run_one "int" "${f}"
done

echo ""
printf 'Files: %d passed, %d failed.\n' "${FILES_PASS}" "${FILES_FAIL}"
printf 'Cases: %d passed, %d failed, %d skipped\n' "${TOTAL_PASS}" "${TOTAL_FAIL}" "${TOTAL_SKIP}"

if (( FILES_FAIL > 0 )); then
    echo ""
    echo "Failed files:"
    for f in "${FAILED_FILES[@]}"; do
        echo "  ${f}"
    done
    exit 1
fi
exit 0
