#!/bin/bash
# Runs every test file in this directory, in order. Same entry point used
# locally (on either Linux or macOS during development) and by CI — see
# ../.github/workflows/ci.yml. macOS-only tests skip themselves on Linux;
# there is currently no Linux-only equivalent test file.
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

echo ""
if [[ "${failed}" -eq 0 ]]; then
    echo "All test files passed."
else
    echo "One or more test files FAILED." >&2
fi
exit "${failed}"
