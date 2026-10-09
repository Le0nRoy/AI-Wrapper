#!/bin/bash
# Runs every test file in this directory, in order. Same entry point used
# locally (on either Linux or macOS during development) and by CI — see
# ../.github/workflows/ci.yml. macOS-only tests skip themselves on Linux;
# there is currently no Linux-only equivalent test file.
set -uo pipefail
shopt -s nullglob

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

failed=0
for test_file in tests/test_*.bash; do
    echo ""
    echo "### ${test_file}"
    if ! bash "${test_file}"; then
        failed=1
    fi
done

python_test_files=(tests/test_*.py)
if [[ "${#python_test_files[@]}" -gt 0 ]]; then
    echo ""
    echo "### Python unittest discovery (tests/test_*.py)"
    if ! PYTHONPATH="${REPO_ROOT}/bin/ai_wrapper_data${PYTHONPATH:+:${PYTHONPATH}}" \
        python3 -m unittest discover -s tests -p 'test_*.py' -v; then
        failed=1
    fi
fi

# Preset test suite (macOS only — run-preset-tests.sh exits 2 on non-Darwin).
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo ""
    echo "### tests/run-preset-tests.sh (macOS only)"
    if ! bash "tests/run-preset-tests.sh"; then
        failed=1
    fi
fi

echo ""
if [[ "${failed}" -eq 0 ]]; then
    echo "All test files passed."
else
    echo "One or more test files FAILED." >&2
fi
exit "${failed}"
