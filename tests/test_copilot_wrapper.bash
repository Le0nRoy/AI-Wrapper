#!/bin/bash
# Copilot wrapper option and no-prompt environment tests.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
export HOME="${FAKE_HOME}"
cleanup() { rm -rf "${FAKE_HOME}"; }
trap cleanup EXIT

source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
source "${REPO_ROOT}/bin/ai_wrapper_data/copilot_wrapper_lib.bash"

echo "== Copilot wrapper tests =="

AI_SANDBOX_PASS_ENV="EXISTING_TOKEN, COPILOT_ALLOW_ALL"
export COPILOT_ALLOW_ALL=false COPILOT_ASSISTED_APPROVAL=true
_copilot_enable_unrestricted_mode
assert_eq "${COPILOT_ALLOW_ALL}" "true" "workspace trust is enabled"
assert_eq "${COPILOT_ASSISTED_APPROVAL}" "false" "assisted approval is disabled"
assert_eq "${AI_SANDBOX_PASS_ENV}" "EXISTING_TOKEN, COPILOT_ALLOW_ALL,COPILOT_ASSISTED_APPROVAL" \
    "explicit env allowlist is preserved and extended"

AI_SANDBOX_PASS_ENV=""
_copilot_enable_unrestricted_mode
assert_eq "${AI_SANDBOX_PASS_ENV}" "COPILOT_ALLOW_ALL,COPILOT_ASSISTED_APPROVAL" \
    "required Copilot env vars are allowlisted when the list is empty"

# Direct tests for the shared allowlist helper (_sandbox_pass_env_add).
AI_SANDBOX_PASS_ENV=""
_sandbox_pass_env_add NEW_VAR
assert_eq "${AI_SANDBOX_PASS_ENV}" "NEW_VAR" "helper adds to an empty allowlist"

unset AI_SANDBOX_PASS_ENV
_sandbox_pass_env_add NEW_VAR
assert_eq "${AI_SANDBOX_PASS_ENV}" "NEW_VAR" "helper adds when the allowlist is unset"

AI_SANDBOX_PASS_ENV="A_VAR,  NEW_VAR  ,B_VAR"
_sandbox_pass_env_add NEW_VAR
assert_eq "${AI_SANDBOX_PASS_ENV}" "A_VAR,  NEW_VAR  ,B_VAR" \
    "helper is idempotent when the name is listed with surrounding whitespace"

AI_SANDBOX_PASS_ENV="A_VAR"
_sandbox_pass_env_add NEW_VAR
_sandbox_pass_env_add NEW_VAR
assert_eq "${AI_SANDBOX_PASS_ENV}" "A_VAR,NEW_VAR" "helper does not duplicate a name added twice"

AI_SANDBOX_PASS_ENV="A_VAR"
_sandbox_pass_env_add A_VAR_EXTRA
assert_eq "${AI_SANDBOX_PASS_ENV}" "A_VAR,A_VAR_EXTRA" \
    "helper matches whole entries, not name prefixes"

_stub_runner() { run_sandboxed_agent() { printf '%s\n' "$@"; }; }
_copilot_argv() {
    (
        _stub_runner
        WRAPPER_FLAGS=()
        AGENT_FLAGS=(--allow-all-tools --allow-all-paths --allow-all-urls)
        case "${1}" in
            resume) AI_RESUME_ARGS=(--resume); run_agent_session resume ;;
            *) run_agent_session start ;;
        esac
    )
}
NL=$'\n'
SEP="--"
assert_eq "$(_copilot_argv start)" \
    "copilot${NL}${SEP}${NL}${SEP}${NL}--allow-all-tools${NL}--allow-all-paths${NL}--allow-all-urls" \
    "start explicitly bypasses tool, path, and URL prompts"
assert_eq "$(_copilot_argv resume)" \
    "copilot${NL}${SEP}${NL}${SEP}${NL}--allow-all-tools${NL}--allow-all-paths${NL}--allow-all-urls${NL}--resume" \
    "resume picker also receives unrestricted permission flags"

if command -v copilot >/dev/null 2>&1; then
    copilot --allow-all-tools --allow-all-paths --allow-all-urls --help >/dev/null 2>&1
    assert_eq "$?" "0" "installed Copilot CLI accepts explicit unrestricted flags"
fi

if [[ "$(uname -s)" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    mkdir -p "${FAKE_HOME}/bin" "${FAKE_HOME}/work"
    cat >"${FAKE_HOME}/bin/copilot" <<'STUB'
#!/bin/bash
printf 'ALLOW_ALL=%s\nASSISTED_APPROVAL=%s\n' \
    "${COPILOT_ALLOW_ALL:-<unset>}" "${COPILOT_ASSISTED_APPROVAL:-<unset>}"
printf 'ARG=%s\n' "$@"
STUB
    chmod +x "${FAKE_HOME}/bin/copilot"
    out="$(cd "${FAKE_HOME}/work" && PATH="${FAKE_HOME}/bin:${PATH}" \
        bash "${REPO_ROOT}/bin/executable_copilot_wrapper.bash" --prompt test 2>&1)"
    assert_contains "${out}" "ALLOW_ALL=true" "sandboxed Copilot receives workspace trust opt-in"
    assert_contains "${out}" "ASSISTED_APPROVAL=false" "sandboxed Copilot has assisted approval disabled"
    for flag in --allow-all-tools --allow-all-paths --allow-all-urls --prompt test; do
        assert_contains "${out}" "ARG=${flag}" "sandboxed Copilot receives ${flag}"
    done
fi

tests_summary_and_exit
