#!/bin/bash
# Copilot wrapper option and no-prompt environment tests.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
isolate_test_env "${FAKE_HOME}"
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

echo "-- Copilot config binds"
NL=$'\n'
_copilot_binds() {
    (
        WRAPPER_FLAGS=()
        _copilot_bind_config_dirs || exit 1
        printf '%s\n' "${WRAPPER_FLAGS[@]}"
    ) 2>&1
}
_reset_copilot_home() {
    rm -rf "${FAKE_HOME}/.copilot" "${FAKE_HOME}/.config/github-copilot" \
        "${FAKE_HOME}/.local/share/copilot"
}
REAL_FAKE_HOME="$(_realpath "${FAKE_HOME}")"
mkdir -p "${FAKE_HOME}/.ssh" "${FAKE_HOME}/.config" "${FAKE_HOME}/.local/share"
OUTSIDE_DIR="$(mktemp -d)"

_reset_copilot_home
out="$(_copilot_binds)"; rc=$?
assert_eq "${rc}" "0" "fresh home: Copilot config binds succeed"
assert_contains "${out}" "${REAL_FAKE_HOME}/.copilot" "fresh home: ~/.copilot is created and bound"
assert_not_contains "${out}" "github-copilot" "fresh home: missing optional config dir is skipped"

for cfg in .copilot .config/github-copilot .local/share/copilot; do
    for target in "${FAKE_HOME}/.ssh" "${OUTSIDE_DIR}"; do
        _reset_copilot_home
        ln -s "${target}" "${FAKE_HOME}/${cfg}"
        out="$(_copilot_binds)"; rc=$?
        assert_eq "${rc}" "1" "HOME/${cfg} symlink to ${target##*/} is refused"
        assert_contains "${out}" "ERROR: ${FAKE_HOME}/${cfg} is a symlink" "... with a symlink error"
        assert_not_contains "${out}" "--bind" "... before any bind is added"
    done
done

_reset_copilot_home
mkdir -p "${FAKE_HOME}/.config"
printf 'x' >"${FAKE_HOME}/.config/github-copilot"
out="$(_copilot_binds)"; rc=$?
assert_eq "${rc}" "1" "non-directory Copilot config path is refused"
assert_contains "${out}" "is not a directory" "... with a type error"

_reset_copilot_home
mkdir -p "${FAKE_HOME}/copilot-state"
ln -s "${FAKE_HOME}/copilot-state" "${FAKE_HOME}/.copilot"
out="$(_copilot_binds)"; rc=$?
assert_eq "${rc}" "0" "HOME/.copilot symlink inside HOME is accepted"
if [[ "$(uname -s)" == "Linux" ]]; then
    assert_contains "${out}" "--bind${NL}${REAL_FAKE_HOME}/copilot-state${NL}${FAKE_HOME}/.copilot" \
        "... and bound from its resolved source at the standard path"
fi
_reset_copilot_home
rm -rf "${OUTSIDE_DIR}" "${FAKE_HOME}/copilot-state"

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
SEP="--"
assert_eq "$(_copilot_argv start)" \
    "copilot${NL}${SEP}${NL}${SEP}${NL}--allow-all-tools${NL}--allow-all-paths${NL}--allow-all-urls" \
    "start explicitly bypasses tool, path, and URL prompts"
assert_eq "$(_copilot_argv resume)" \
    "copilot${NL}${SEP}${NL}${SEP}${NL}--allow-all-tools${NL}--allow-all-paths${NL}--allow-all-urls${NL}--resume" \
    "resume picker also receives unrestricted permission flags"

# Real-CLI flag acceptance is not checked here: tests never launch an
# installed, possibly authenticated copilot (see isolate_test_env).
echo "  skip - real copilot flag acceptance (manual check only; no live clients in tests)"

# Argument passthrough applies the shared post-menu binds: with GitLab
# passthrough enabled, file-based glab auth is bound read-only.
mkdir -p "${FAKE_HOME}/stubbin" "${FAKE_HOME}/work" "${FAKE_HOME}/.config/glab-cli"
printf '#!/bin/bash\n' >"${FAKE_HOME}/stubbin/copilot"
chmod +x "${FAKE_HOME}/stubbin/copilot"
cat >"${FAKE_HOME}/stub-profile.bash" <<'PROFILE'
run_sandboxed_agent() { printf 'ARG=%s\n' "$@"; }
PROFILE
_glab_out() {
    (cd "${FAKE_HOME}/work" && PATH="${FAKE_HOME}/stubbin:${PATH}" \
        AI_WRAPPER_EXTRA_PROFILE="${FAKE_HOME}/stub-profile.bash" AI_SANDBOX_PASS_GITLAB="${1}" \
        bash "${REPO_ROOT}/bin/executable_copilot_wrapper.bash" --prompt test </dev/null 2>&1)
}
out="$(_glab_out 1)"
assert_contains "${out}" "ARG=--ro-bind${NL}ARG=${FAKE_HOME}/.config/glab-cli" \
    "AI_SANDBOX_PASS_GITLAB=1 binds the glab config read-only"
out="$(_glab_out 0)"
assert_not_contains "${out}" "glab-cli" "glab config is not bound without GitLab passthrough"

if [[ "$(uname -s)" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    mkdir -p "${FAKE_HOME}/bin" "${FAKE_HOME}/work"
    cat >"${FAKE_HOME}/bin/copilot" <<'STUB'
#!/bin/bash
printf 'ALLOW_ALL=%s\nASSISTED_APPROVAL=%s\n' \
    "${COPILOT_ALLOW_ALL:-<unset>}" "${COPILOT_ASSISTED_APPROVAL:-<unset>}"
printf 'ARG=%s\n' "$@"
STUB
    chmod +x "${FAKE_HOME}/bin/copilot"
    assert_client_is_fake copilot
    out="$(cd "${FAKE_HOME}/work" && PATH="${FAKE_HOME}/bin:${PATH}" \
        bash "${REPO_ROOT}/bin/executable_copilot_wrapper.bash" --prompt test 2>&1)"
    assert_contains "${out}" "ALLOW_ALL=true" "sandboxed Copilot receives workspace trust opt-in"
    assert_contains "${out}" "ASSISTED_APPROVAL=false" "sandboxed Copilot has assisted approval disabled"
    for flag in --allow-all-tools --allow-all-paths --allow-all-urls --prompt test; do
        assert_contains "${out}" "ARG=${flag}" "sandboxed Copilot receives ${flag}"
    done
fi

assert_no_live_client_reached
tests_summary_and_exit
