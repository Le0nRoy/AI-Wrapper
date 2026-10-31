#!/bin/bash
# Runs every test file in this directory, in order — the local "run
# everything" entry point on Linux or macOS. CI runs the same files as
# separate steps per job (../.github/workflows/ci.yml); keep the two in
# sync. macOS-only tests skip themselves on Linux; Linux bwrap e2e blocks
# print "skip" lines on macOS. See docs/testing.md for side effects and
# per-OS scope.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

failed=0
for test_file in tests/test_*.bash; do
    echo ""
    echo "### ${test_file}"
    if ! bash "${test_file}"; then
        failed=1
    fi
done

# Python unit tests for helpers shipped inside skills (offline, no credentials).
for test_file in dot_agents/skills/*/scripts/test_*.py; do
    [[ -f "${test_file}" ]] || continue
    echo ""
    echo "### ${test_file}"
    if ! python3 -B "${test_file}"; then
        failed=1
    fi
done

# Preset test suite (macOS only — run-preset-tests.sh exits 2 on non-Darwin).
echo ""
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "### tests/run-preset-tests.sh (macOS only)"
    if ! bash "tests/run-preset-tests.sh"; then
        failed=1
    fi
else
    echo "### tests/run-preset-tests.sh: SKIPPED (macOS only; covered by CI smoke-macos)"
fi

echo ""
if [[ "${failed}" -eq 0 ]]; then
    echo "All test files passed."
else
    echo "One or more test files FAILED." >&2
fi
exit "${failed}"
