#!/bin/bash
# Suite inventory (#51): every test file has a CI path on each OS it
# covers, is reached by tests/run_all.bash, and is listed in
# docs/testing.md. Pure text checks over the repo; no wrapper is sourced
# and nothing is launched.
#
# Rules:
#   - each suite is named in .github/workflows/ci.yml, or is invoked by a
#     tests/ file that is (e.g. test_linux_tty_seccomp.py runs inside
#     test_linux_process_isolation.bash)
#   - each tests/test_*.bash other than test_linux_*.bash runs in a macOS
#     job (logic-tests or smoke-macos)
#   - each tests/test_*.bash other than test_sandbox_macos_only.bash runs
#     in a Linux job (logic-tests or smoke-linux)
#   - tests/run_all.bash runs every tests/test_*.py and the preset suite
#   - docs/testing.md names every suite
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"
cd "${REPO_ROOT}" || exit 1

CI_FILE=".github/workflows/ci.yml"
RUN_ALL="tests/run_all.bash"
DOC_FILE="docs/testing.md"

# Body of one top-level job in the CI file (lines up to the next job).
_ci_job() {
    awk -v job="  ${1}:" '
        $0 == job { inside = 1; next }
        inside && /^  [A-Za-z0-9_-]+:/ { exit }
        inside { print }
    ' "${CI_FILE}"
}

_job_runs() { [[ "${2}" == *"run: bash ${1}"* || "${2}" == *"run: python3"*" ${1}"* ]]; }

echo "== test suite inventory =="

ci_text="$(cat "${CI_FILE}")"
run_all_text="$(cat "${RUN_ALL}")"
doc_text="$(cat "${DOC_FILE}")"
logic_job="$(_ci_job logic-tests)"
linux_job="$(_ci_job smoke-linux)"
macos_job="$(_ci_job smoke-macos)"
assert_contains "${logic_job}" "run: bash" "logic-tests job found"
assert_contains "${linux_job}" "run: bash" "smoke-linux job found"
assert_contains "${macos_job}" "run: bash" "smoke-macos job found"

suites=()
for suite in tests/test_*.bash tests/test_*.py tests/run-preset-tests.sh \
        dot_agents/skills/*/scripts/test_*.py; do
    [[ -f "${suite}" ]] && suites+=("${suite}")
done

for suite in "${suites[@]}"; do
    name="${suite##*/}"

    assert_contains "${doc_text}" "${name}\`" "${name}: listed in ${DOC_FILE}"

    ci_path=""
    if [[ "${ci_text}" == *"${suite}"* ]]; then
        ci_path="direct"
    else
        for parent in tests/test_*.bash; do
            [[ "${parent}" == "${suite}" ]] && continue
            if grep -q "tests/${name}" "${parent}" && [[ "${ci_text}" == *"${parent}"* ]]; then
                ci_path="via ${parent}"
                break
            fi
        done
    fi
    assert_eq "$([[ -n "${ci_path}" ]] && echo yes || echo no)" "yes" "${name}: has a CI path ${ci_path}"

    [[ "${suite}" == tests/test_*.bash ]] || continue
    if [[ "${name}" != test_linux_* ]]; then
        on_macos=no
        { _job_runs "${suite}" "${logic_job}" || _job_runs "${suite}" "${macos_job}"; } && on_macos=yes
        assert_eq "${on_macos}" "yes" "${name}: runs in a macOS CI job"
    fi
    if [[ "${name}" != test_sandbox_macos_only.bash ]]; then
        on_linux=no
        { _job_runs "${suite}" "${logic_job}" || _job_runs "${suite}" "${linux_job}"; } && on_linux=yes
        assert_eq "${on_linux}" "yes" "${name}: runs in a Linux CI job"
    fi
done

# run_all.bash reaches every suite through its loops or by name.
assert_contains "${run_all_text}" 'for test_file in tests/test_*.bash' "run_all: runs every tests/test_*.bash"
assert_contains "${run_all_text}" 'for test_file in tests/test_*.py' "run_all: runs every tests/test_*.py"
assert_contains "${run_all_text}" 'dot_agents/skills/*/scripts/test_*.py' "run_all: runs skill helper tests"
assert_contains "${run_all_text}" 'tests/run-preset-tests.sh' "run_all: runs or reports the preset suite"
assert_contains "${run_all_text}" 'SKIPPED' "run_all: off-Darwin preset skip is visible"

# The preset suite's only CI path is native macOS.
assert_contains "${macos_job}" "run: bash tests/run-preset-tests.sh" "smoke-macos keeps the preset suite (#50)"

tests_summary_and_exit
