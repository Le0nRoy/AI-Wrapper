#!/bin/bash
# Per-workdir preset identity tests (#45). The preset file name is the
# first 12 hex chars of SHA-256 over the physical workdir path, computed by
# sha256sum (GNU coreutils) or `shasum -a 256` (macOS). When that identity
# cannot be computed the preset helpers must fail closed:
#   - missing / failing / malformed hash commands and an unusable `pwd -P`
#     make every path helper return 1 with no stdout;
#   - _preset_autosave / _preset_autoload / _preset_clear then write, load
#     and delete nothing (no shared "-<agent>.env" or ".env" fallback), and
#     the header shows a "saved settings disabled" line instead of a
#     "restored from" one;
#   - the agy trusted-target check refuses with "cannot be determined"
#     instead of checking dirname "" (= ".");
#   - valid identities match an independent oracle (python3 hashlib and a
#     fixed known vector), are distinct per project, follow symlinks to the
#     physical dir, and keep loading existing preset files unchanged.
# Hash tools are swapped by building a private PATH of stubs; the stubs
# compute digests with python3, never with the production pipeline.
# Runs on Linux and macOS (bash 3.2 compatible); no sandbox launch.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
isolate_test_env "${FAKE_HOME}"
cleanup() { rm -rf "${FAKE_HOME}"; }
trap cleanup EXIT

PRESET_DIR="${XDG_CONFIG_HOME}/ai-wrapper/last-preset"
# SHA-256("/") — fixed known vector for the identity of the root directory.
ROOT_IDENTITY="8a5edab28263"
HOST_PATH="${PATH}"

echo "== preset identity tests ($(uname -s)) =="
PY="$(command -v python3 2>/dev/null)"
if [[ -z "${PY}" ]]; then
    echo "  skip - python3 required for the independent SHA-256 oracle and hash stubs"
    tests_summary_and_exit
fi

_load() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/bin/ai_wrapper_data/${1}_wrapper_lib.bash"
}

# Independent oracle: first 12 hex chars of SHA-256 over $1.
_oracle() { "${PY}" -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' "${1}"; }

# Build a PATH dir holding only the basic tools the preset helpers use and
# no hash command. Print its path.
_toolbox() {
    local box="${FAKE_HOME}/path-${1}" tool src
    mkdir -p "${box}"
    for tool in dirname mkdir mv chmod date rm cat; do
        src="$(PATH="${HOST_PATH}" type -P "${tool}")" && ln -sf "${src}" "${box}/${tool}"
    done
    printf '%s' "${box}"
}

# _stub BOX NAME BODY — install an executable shell stub.
_stub() {
    printf '#!/bin/sh\n%s\n' "${3}" >"${1}/${2}"
    chmod +x "${1}/${2}"
}

# Stub bodies: a correct digest of stdin in "<hex>  -" form, and the same
# behind shasum's required "-a 256" arguments.
GOOD_SUM="exec '${PY}' -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest() + \"  -\")'"
GOOD_SHASUM="[ \"\$1 \$2 \$#\" = \"-a 256 2\" ] || exit 2
${GOOD_SUM}"

# Run "$@" (lib function calls) in DIR with agent AGENT and PATH=BOX.
# Prints stdout then "rc=N"; stderr goes to the ERR file.
ERR="${FAKE_HOME}/stderr"
_in() {
    local dir="${1}" agent="${2}" box="${3}"
    shift 3
    (
        cd "${dir}" || exit 99
        _load "${agent}"
        unset CLAUDE_ACCOUNT CODEX_ACCOUNT AI_WRAPPER_PRESET_AUTOLOADED_FROM
        PATH="${box}"
        eval "$*"
        echo "rc=$?"
    ) 2>"${ERR}"
}

# Recursive listing + content of the preset dir: a no-mutation snapshot.
_snap() {
    [[ -d "${PRESET_DIR}" ]] || { echo "absent"; return; }
    local f
    for f in "${PRESET_DIR}"/.[!.]* "${PRESET_DIR}"/*; do
        [[ -e "${f}" ]] || continue
        printf '%s:%s\n' "${f##*/}" "$(cat "${f}")"
    done
}

mkdir -p "${FAKE_HOME}/proj-a" "${FAKE_HOME}/proj-b"
ln -s "${FAKE_HOME}/proj-a" "${FAKE_HOME}/link-a"
A="${FAKE_HOME}/proj-a"
B="${FAKE_HOME}/proj-b"
ID_A="$(_oracle "${A}")"
ID_B="$(_oracle "${B}")"

# ---------------------------------------------------------------------------
echo "-- valid identities (host tools, sha256sum-only, shasum-only)"
out="$(_in / claude "${HOST_PATH}" _preset_path_prefix)"
assert_eq "${out}" "${PRESET_DIR}/${ROOT_IDENTITY}rc=0" "host tools: identity of / is the known SHA-256 vector"
out="$(_in "${A}" claude "${HOST_PATH}" _preset_path_prefix)"
assert_eq "${out}" "${PRESET_DIR}/${ID_A}rc=0" "host tools: identity matches the python3 oracle"

box="$(_toolbox sha256sum-only)"
_stub "${box}" sha256sum "${GOOD_SUM}"
out="$(_in "${A}" claude "${box}" _preset_path_prefix)"
assert_eq "${out}" "${PRESET_DIR}/${ID_A}rc=0" "sha256sum only (Linux coreutils): same identity"

box="$(_toolbox shasum-only)"
_stub "${box}" shasum "${GOOD_SHASUM}"
out="$(_in "${A}" claude "${box}" _preset_path_prefix)"
assert_eq "${out}" "${PRESET_DIR}/${ID_A}rc=0" "shasum -a 256 only (macOS): same identity"
SHASUM_ONLY="${box}"

out="$(_in "${B}" claude "${HOST_PATH}" _preset_path_prefix)"
assert_eq "${out}" "${PRESET_DIR}/${ID_B}rc=0" "a second project gets its own identity"
assert_eq "$([[ "${ID_A}" != "${ID_B}" ]] && echo distinct)" "distinct" "... distinct from the first"
out="$(_in "${FAKE_HOME}/link-a" claude "${HOST_PATH}" _preset_path_prefix)"
assert_eq "${out}" "${PRESET_DIR}/${ID_A}rc=0" "a symlinked workdir resolves to its physical dir's identity"

# ---------------------------------------------------------------------------
echo "-- missing / failing / malformed hash commands fail closed"
_expect_fail() {
    local box="${1}" desc="${2}" out
    out="$(_in "${A}" claude "${box}" _preset_path_prefix)"
    assert_eq "${out}" "rc=1" "${desc}: prefix returns 1 with no stdout"
    assert_contains "$(cat "${ERR}")" "ERROR:" "${desc}: reports an error"
}

box="$(_toolbox none)"
_expect_fail "${box}" "no sha256sum and no shasum"
assert_contains "$(cat "${ERR}")" "sha256sum" "... naming the supported tools"
NO_HASH="${box}"

box="$(_toolbox fail-sha256sum)"
_stub "${box}" sha256sum 'exit 1'
_expect_fail "${box}" "sha256sum exits 1 silently"

box="$(_toolbox fail-valid-output)"
_stub "${box}" sha256sum "'${PY}' -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest() + \"  -\")'; exit 1"
_expect_fail "${box}" "sha256sum prints a valid digest but exits 1"

box="$(_toolbox fail-shasum)"
_stub "${box}" shasum "'${PY}' -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest() + \"  -\")'; exit 3"
_expect_fail "${box}" "shasum (only tool) prints a valid digest but exits 3"

hex64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
n=0
for bad in "" "  -" "xxxxxxxxxxxx  -" "0123456789ab  -" "${hex64%?}  -" "${hex64}0  -" \
        "$(printf '%s' "${hex64}" | tr 'a-f' 'A-F')  -" "${hex64}" "${hex64}  -\n${hex64}  -" \
        "0123456789abZZZZ  -" "0123456789ab${hex64#0123456789ab}garbage  -"; do
    n=$((n + 1))
    box="$(_toolbox malformed-${n})"
    _stub "${box}" sha256sum "cat >/dev/null; printf '${bad}\\n'"
    _expect_fail "${box}" "malformed output #${n} [${bad}]"
done

# Identity from a failing `pwd -P`: never hash an empty or relative path.
out="$(_in "${A}" claude "${HOST_PATH}" 'pwd() { return 1; }; _preset_path_prefix')"
assert_eq "${out}" "rc=1" "pwd -P failure: prefix returns 1 with no stdout"
assert_contains "$(cat "${ERR}")" "working directory" "... naming the working directory"
out="$(_in "${A}" claude "${HOST_PATH}" 'pwd() { :; }; _preset_path_prefix')"
assert_eq "${out}" "rc=1" "empty pwd -P: prefix returns 1 (no SHA-256 of the empty string)"
out="$(_in "${A}" claude "${HOST_PATH}" 'pwd() { echo rel/dir; }; _preset_path_prefix')"
assert_eq "${out}" "rc=1" "relative pwd -P: prefix returns 1"

# ---------------------------------------------------------------------------
echo "-- every helper and caller fails closed on hash failure"
# Seed: the accidental shared paths the old code produced on hash failure,
# a valid other-project preset, and a valid preset for this project.
mkdir -p "${PRESET_DIR}"
printf 'CLAUDE_ACCOUNT=leaked\n' >"${PRESET_DIR}/-claude.env"
printf 'CODEX_ACCOUNT=leaked\n' >"${PRESET_DIR}/-codex.env"
printf 'CLAUDE_ACCOUNT=leaked\n' >"${PRESET_DIR}/.env"
printf 'CLAUDE_ACCOUNT=other\n' >"${PRESET_DIR}/${ID_B}-claude.env"
printf 'CLAUDE_ACCOUNT=mine\n' >"${PRESET_DIR}/${ID_A}-claude.env"
printf 'CLAUDE_ACCOUNT=legacy\nAI_SANDBOX_PASS_KUBE=1\n' >"${PRESET_DIR}/${ID_A}.env"
before="$(_snap)"

for agent in claude codex; do
    out="$(_in "${A}" "${agent}" "${NO_HASH}" _preset_autosave_path)"
    assert_eq "${out}" "rc=1" "${agent}: _preset_autosave_path returns 1 with no stdout"
    out="$(_in "${A}" "${agent}" "${NO_HASH}" _preset_legacy_path)"
    assert_eq "${out}" "rc=1" "${agent}: _preset_legacy_path returns 1 with no stdout"

    out="$(_in "${A}" "${agent}" "${NO_HASH}" 'CLAUDE_ACCOUNT=x CODEX_ACCOUNT=x _preset_autosave')"
    assert_eq "${out}" "rc=1" "${agent}: _preset_autosave returns 1"
    assert_eq "$(_snap)" "${before}" "${agent}: ... and writes nothing"

    out="$(_in "${A}" "${agent}" "${NO_HASH}" 'AI_WRAPPER_PRESET_AUTOLOADED_FROM=stale _preset_autoload; rc=$?
        echo "C=${CLAUDE_ACCOUNT:-} X=${CODEX_ACCOUNT:-} FROM=${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-} OFF=${_AI_WRAPPER_PRESET_UNAVAILABLE:-}"
        banner="$(declare -f _render_preset_banner_line)"; eval "${banner//\/dev\/tty//dev/stdout}"
        _render_preset_banner_line; (exit ${rc})')"
    assert_contains "${out}" "C= X= FROM= OFF=1" "${agent}: _preset_autoload loads nothing and drops any restored-from marker"
    assert_contains "${out}" "Saved settings disabled" "${agent}: ... header says saved settings are disabled"
    assert_not_contains "${out}" "restored from" "${agent}: ... and never claims settings were restored"
    assert_contains "${out}" "rc=1" "${agent}: ... returning 1"
    assert_eq "$(_snap)" "${before}" "${agent}: ... and modifies nothing"

    out="$(_in "${A}" "${agent}" "${NO_HASH}" _preset_clear)"
    assert_eq "${out}" "rc=1" "${agent}: _preset_clear returns 1"
    assert_eq "$(_snap)" "${before}" "${agent}: ... and deletes nothing (not even the accidental shared files)"
done

# Per-agent path computes, legacy path fails: clear must delete neither and
# autoload must not fall back. The stub succeeds once, then fails.
box="$(_toolbox flaky)"
_stub "${box}" sha256sum "if [ -e '${box}/used' ]; then exit 1; fi; : >'${box}/used'; ${GOOD_SUM}"
out="$(_in "${A}" claude "${box}" _preset_clear)"
assert_eq "${out}" "rc=1" "clear with a failing legacy path returns 1"
assert_eq "$(_snap)" "${before}" "... and deletes neither file"
rm -f "${box}/used"
mv "${PRESET_DIR}/${ID_A}-claude.env" "${FAKE_HOME}/mine.bak"
out="$(_in "${A}" claude "${box}" '_preset_autoload; rc=$?; echo "C=${CLAUDE_ACCOUNT:-}"; (exit ${rc})')"
assert_contains "${out}" $'C=\nrc=1' "autoload with a failing legacy path loads nothing and returns 1"
mv "${FAKE_HOME}/mine.bak" "${PRESET_DIR}/${ID_A}-claude.env"

# ---------------------------------------------------------------------------
echo "-- existing valid presets keep working"
out="$(_in "${A}" claude "${HOST_PATH}" '_preset_autoload; echo "C=${CLAUDE_ACCOUNT:-} FROM=${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}"')"
assert_contains "${out}" "C=mine FROM=${PRESET_DIR}/${ID_A}-claude.env" "existing <hash>-claude.env loads unchanged"
out="$(_in "${A}" codex "${SHASUM_ONLY}" '_preset_autoload; echo "KUBE=${AI_SANDBOX_PASS_KUBE:-} FROM=${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}"')"
assert_contains "${out}" "KUBE=1 FROM=${PRESET_DIR}/${ID_A}.env" "existing legacy <hash>.env loads via shasum-only fallback"
out="$(_in "${FAKE_HOME}/link-a" claude "${HOST_PATH}" '_preset_autoload; echo "C=${CLAUDE_ACCOUNT:-}"')"
assert_contains "${out}" "C=mine" "symlinked workdir loads the physical dir's preset"
out="$(_in "${A}" codex "${HOST_PATH}" 'CODEX_ACCOUNT=alt _preset_autosave')"
assert_eq "${out}" "rc=0" "autosave succeeds with a valid identity"
assert_contains "$(cat "${PRESET_DIR}/${ID_A}-codex.env" 2>&1)" "CODEX_ACCOUNT=alt" "... writing <hash>-codex.env"
out="$(_in "${A}" claude "${HOST_PATH}" _preset_clear)"
assert_eq "${out}" "rc=0" "clear succeeds with a valid identity"
_exists() { [[ -e "${PRESET_DIR}/${1}" ]] && echo present || echo absent; }
assert_eq "$(_exists "${ID_A}-claude.env") $(_exists "${ID_A}.env")" "absent absent" \
    "... removing this project's claude and legacy files"
assert_eq "$(_exists "${ID_A}-codex.env") $(_exists "${ID_B}-claude.env") $(_exists -claude.env) $(_exists .env)" \
    "present present present present" "... leaving other agents, projects and unrelated files alone"

# ---------------------------------------------------------------------------
echo "-- agy trusted-target check on hash failure"
mkdir -p "${FAKE_HOME}/agy-stub" "${FAKE_HOME}/.gemini-x/antigravity-cli" "${FAKE_HOME}/dot"
_stub "${FAKE_HOME}/agy-stub" sha256sum 'exit 1'
"${PY}" -I -c 'import json,sys;print(json.dumps({"colorScheme":"dark","toolPermission":"always-proceed","artifactReviewPolicy":"always-proceed","allowNonWorkspaceAccess":True,"enableTerminalSandbox":False,"trustedWorkspaces":sys.argv[1:]}))' \
    "${A}" >"${FAKE_HOME}/dot/settings.json"
ln -s "${FAKE_HOME}/dot/settings.json" "${FAKE_HOME}/.gemini-x/antigravity-cli/settings.json"
# _agy_trusted PATH-PREFIX: validate the approved symlinked settings.json.
_agy_trusted() {
    (
        cd "${A}" || exit 1
        _load agy
        PATH="${1}${HOST_PATH}"
        # shellcheck disable=SC2034  # read by _agy_validate_settings
        WRAPPER_FLAGS=()
        AGY_SETTINGS_TRUSTED_PROFILE="${FAKE_HOME}/.gemini-x" \
            AGY_SETTINGS_TRUSTED_TARGET="${FAKE_HOME}/dot/settings.json" \
            _agy_validate_settings "${FAKE_HOME}/.gemini-x" && echo CONFIGURED
    ) 2>&1
}
out="$(_agy_trusted "")"
assert_contains "${out}" "CONFIGURED" "agy control: approval honoured with a valid identity (${out})"
out="$(_agy_trusted "${FAKE_HOME}/agy-stub:")"
assert_contains "${out}" "per-workdir preset location cannot be determined" "agy: approval refused, preset location undeterminable"
assert_not_contains "${out}" "CONFIGURED" "agy: ... failing the launch check"
assert_not_contains "${out}" "preset directory . is writable" "agy: ... never checks dirname of an empty path"

tests_summary_and_exit
