#!/bin/bash
# macOS (Seatbelt) credential policy (issue #67):
#   - custom-profile sanity check (_sandbox_profile_violation) scans the
#     whole body, ignores comments and string literals, and token-matches
#     (allow default) across whitespace and case — any OS;
#   - git credential-store files (~/.git-credentials,
#     ~/.config/git/credentials) are denied, also under
#     AI_SANDBOX_ALLOW_RO_HOMEDIR=1 — profile text on any OS, native read
#     probes on macOS;
#   - Keychain file and SecurityServer/securityd IPC grants are gated on
#     AI_SANDBOX_ALLOW_KEYCHAIN (default 0) — profile text on any OS,
#     a synthetic keychain-db file probe on macOS, and a `security` probe
#     against a throwaway keychain on CI only;
#   - glab (GitLab CLI) config dirs (default macOS + relocated XDG paths) are
#     readable only through AI_SANDBOX_PASS_GITLAB, also under
#     AI_SANDBOX_ALLOW_RO_HOMEDIR=1 (issue #47) — profile text on any OS,
#     a HOMEDIR x PASS_GITLAB native read matrix on macOS.
# Off macOS getconf and sandbox-exec are stubbed; only generated text is
# checked. No real keychain, credential file or client state is touched:
# every fixture lives in the fake home.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

# Read before isolate_test_env: the `security` probe creates (and deletes) a
# throwaway keychain, which also edits the user keychain search list, so it
# runs only on CI runners or on explicit opt-in.
RUN_KEYCHAIN_PROBE=0
if [[ "${CI:-}" == "true" || "${AI_WRAPPER_TEST_SYNTHETIC_KEYCHAIN:-0}" == "1" ]]; then
    RUN_KEYCHAIN_PROBE=1
fi

# Under the real $HOME for the reason given in tests/test_sandbox_common.bash.
FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
isolate_test_env "${FAKE_HOME}"

OS="$(uname -s)"
RUN_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
SYNTH_KEYCHAIN="${FAKE_HOME}/Library/Keychains/synthetic-${RUN_ID}.keychain-db"
SYNTH_PASS="synthetic-pass-${RUN_ID}"
SYNTH_SERVICE="ai-wrapper-test-${RUN_ID}"
SYNTH_SECRET="synthetic-secret-${RUN_ID}"
keychain_created=0

cleanup() {
    if [[ "${keychain_created}" == "1" ]]; then
        security delete-keychain "${SYNTH_KEYCHAIN}" >/dev/null 2>&1 || true
    fi
    rm -rf "${FAKE_HOME}"
}
trap cleanup EXIT

_load_backend() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=../bin/ai_wrapper_data/macos_sandbox_exec.bash
    source "${REPO_ROOT}/bin/ai_wrapper_data/macos_sandbox_exec.bash"
}

echo "== macOS credential policy tests (${OS}) =="

# ---------------------------------------------------------------------------
echo "-- custom profile sanity check"
_violation() { ( _load_backend; _sandbox_profile_violation "$1" ) 2>&1; }
_expect_violation() {
    local body="$1" want="$2" label="$3"
    assert_eq "$(_violation "${body}")" "${want}" "${label}"
}

GOOD=$'(version 1)\n(deny default)\n(allow file-read* (subpath "/usr"))'
_expect_violation "${GOOD}" "" "minimal (version 1) + (deny default) profile accepted"
_expect_violation "$(<"${REPO_ROOT}/bin/ai_wrapper_data/claude_wrapper.sb")" "" "shipped claude_wrapper.sb accepted"
_expect_violation $'(deny default)\n(allow file-read*)' "header" "missing (version 1) rejected"
_expect_violation $'(version 1)\n(allow file-read*)' "header" "missing (deny default) rejected"
_expect_violation $'; (version 1)\n; (deny default)\n(allow file-read*)' "header" "header only inside comments rejected"
_expect_violation $'(define x "(version 1) (deny default)")\n(allow file-read*)' "header" "header only inside a string literal rejected"
_expect_violation $'(version 1) ; trailing comment\n(deny default)' "" "trailing comments after the header accepted"

filler=""
for _ in $(seq 1 120); do filler+=$'(allow file-read* (literal "/dev/null"))\n'; done
_expect_violation "${GOOD}"$'\n'"${filler}(allow default)" "allow-default" "(allow default) after line 80 rejected"
_expect_violation "${filler}${GOOD}" "" "header after line 80 accepted (whole body scanned)"
_expect_violation $'(version 1)\n(deny default) (allow default)' "allow-default" "(allow default) after another form on the same line rejected"
_expect_violation $'(version 1)\n(deny default)\n(  allow\n\t default  )' "allow-default" "(allow default) split across whitespace and lines rejected"
_expect_violation $'(version 1)\n(deny default)\n(allow default (with report))' "allow-default" "(allow default <modifier>) rejected"
_expect_violation $'(version 1)\n(deny default)\n(allow file-read* default)' "allow-default" "default in an allow operation list rejected"
_expect_violation $'(VERSION 1)\n(Deny Default)\n(ALLOW DEFAULT)' "allow-default" "case-folded (ALLOW DEFAULT) rejected"
_expect_violation $'(version 1)\n(deny default)\n(allow file-read* (literal "/a;b")) (allow default)' "allow-default" \
    "(allow default) after a string containing ';' rejected"
_expect_violation $'(version 1)\n(deny default)\n(allow file-read* (literal "/a\\"b")) (allow default)' "allow-default" \
    "(allow default) after a string with an escaped quote rejected"
_expect_violation $'(version 1)\n(deny default)\n(allow file-read* (regex #"^/x;y$")) (allow default)' "allow-default" \
    "(allow default) after a #\"regex\" containing ';' rejected"
_expect_violation $'(version 1)\n(deny default)\n; (allow default)\n(allow file-read* (literal "(allow default)"))' "" \
    "(allow default) only in a comment or string literal accepted"
_expect_violation $'(version 1)\n(deny default)\n(define q #\\") (allow default) ; "' "syntax" \
    "character literal that could hide a rule rejected"
_expect_violation $'(version 1)\n(deny default)\n#| " |# (allow default) ; "' "syntax" "block comment rejected"
_expect_violation $'(version 1)\n(deny default)\n#; "x" (allow default)' "syntax" "datum comment rejected"

# ---------------------------------------------------------------------------
echo "-- rendered profile (AI_SANDBOX_DRYRUN)"
STUB_BIN="${FAKE_HOME}/stub-bin"
mkdir -p "${STUB_BIN}" "${FAKE_HOME}/project"
dry_path="${PATH}"
if [[ "${OS}" != "Darwin" ]]; then
    mkdir -p "${FAKE_HOME}/darwin/T" "${FAKE_HOME}/darwin/C"
    printf '#!/bin/sh\necho "stub sandbox-exec must not run" >&2\nexit 99\n' >"${STUB_BIN}/sandbox-exec"
    printf '#!/bin/sh\ncase "$1" in DARWIN_USER_TEMP_DIR) echo "%s/darwin/T/";; DARWIN_USER_CACHE_DIR) echo "%s/darwin/C/";; *) exit 1;; esac\n' \
        "${FAKE_HOME}" "${FAKE_HOME}" >"${STUB_BIN}/getconf"
    chmod +x "${STUB_BIN}/sandbox-exec" "${STUB_BIN}/getconf"
    dry_path="${STUB_BIN}:${PATH}"
    echo "  (mocked: getconf and sandbox-exec stubbed on ${OS}; generated profile only)"
fi
_dryrun() {
    ( cd "${FAKE_HOME}/project" && PATH="${dry_path}" && _load_backend \
        && AI_SANDBOX_DRYRUN=1 _run_sandboxed_agent_impl /bin/echo -- -- hi ) 2>&1
}

out="$(_dryrun)"; rc=$?
assert_eq "${rc}" "0" "default dry run exits 0"
assert_contains "${out}" "ALLOW_KEYCHAIN=0" "AI_SANDBOX_ALLOW_KEYCHAIN defaults to ALLOW_KEYCHAIN=0"
out="$(AI_SANDBOX_ALLOW_KEYCHAIN=1 _dryrun)"
assert_contains "${out}" "ALLOW_KEYCHAIN=1" "AI_SANDBOX_ALLOW_KEYCHAIN=1 passes ALLOW_KEYCHAIN=1"
out="$(AI_SANDBOX_ALLOW_KEYCHAIN=yes _dryrun)"
assert_contains "${out}" "ALLOW_KEYCHAIN=0" "non-1 AI_SANDBOX_ALLOW_KEYCHAIN normalises to 0"

printf '%s\n%s(allow default)\n' "${GOOD}" "${filler}" >"${FAKE_HOME}/late.sb"
out="$(AI_SANDBOX_PROFILE="${FAKE_HOME}/late.sb" _dryrun)"; rc=$?
assert_eq "${rc}" "1" "custom profile with (allow default) after line 80 refused (rc)"
assert_contains "${out}" "contains an (allow default) rule" "... with the documented message"
out="$(AI_SANDBOX_PROFILE="${FAKE_HOME}/late.sb" AI_SANDBOX_PROFILE_TRUST_ME=1 _dryrun)"; rc=$?
assert_eq "${rc}" "0" "AI_SANDBOX_PROFILE_TRUST_ME=1 still bypasses the check"
printf '(version 1)\n(deny default)\n#| x |#\n' >"${FAKE_HOME}/syntax.sb"
out="$(AI_SANDBOX_PROFILE="${FAKE_HOME}/syntax.sb" _dryrun)"; rc=$?
assert_eq "${rc}" "1" "custom profile with unverifiable syntax refused (rc)"
assert_contains "${out}" "AI_SANDBOX_PROFILE_TRUST_ME=1" "... and names the bypass"

# Rule text and order in the shipped profile. Seatbelt applies the last
# matching rule, so the credential deny must follow every read grant that
# covers it (the ~/.config/git subpath, ALLOW_RO_HOMEDIR, ALLOW_RO_CREDENTIALS).
SB="$(<"${REPO_ROOT}/bin/ai_wrapper_data/claude_wrapper.sb")"
_line_of() { grep -nF -- "$1" <<<"${SB}" | head -1 | cut -d: -f1; }
git_creds_deny="$(_line_of '(deny file-read*')"
assert_contains "$(sed -n "${git_creds_deny:-1},+3p" <<<"${SB}")" '"/.git-credentials"' "deny rule covers ~/.git-credentials"
assert_contains "$(sed -n "${git_creds_deny:-1},+3p" <<<"${SB}")" '"/.config/git/credentials"' "deny rule covers ~/.config/git/credentials"
for anchor in '"/.config/git"))' '(when (equal? (param "ALLOW_RO_HOMEDIR") "1")' '(when (equal? (param "ALLOW_RO_CREDENTIALS") "1")'; do
    a="$(_line_of "${anchor}")"
    ok=0; [[ -n "${a}" && -n "${git_creds_deny}" && "${git_creds_deny}" -gt "${a}" ]] && ok=1
    assert_eq "${ok}" "1" "git credential deny comes after ${anchor}"
done
assert_contains "${SB}" '(require-not (literal  (string-append (param "HOME_DIR") "/.git-credentials")))' \
    "ALLOW_RO_HOMEDIR excludes ~/.git-credentials"
assert_contains "${SB}" '(require-not (literal  (string-append (param "HOME_DIR") "/.config/git/credentials")))' \
    "ALLOW_RO_HOMEDIR excludes ~/.config/git/credentials"
# glab config dirs (#47): excluded from ALLOW_RO_HOMEDIR, granted only by
# PASS_GITLAB. The documented paths (wrapper-help.md) are the default macOS
# dir plus the relocated XDG config/data dirs.
GLAB_DIRS=("/Library/Application Support/glab-cli" "/.config/glab-cli" "/.local/share/glab-cli")
homedir_when="$(_line_of '(when (equal? (param "ALLOW_RO_HOMEDIR") "1")')"
homedir_block="$(sed -n "${homedir_when:-1},/^\$/p" <<<"${SB}")"
gitlab_when="$(_line_of '(when (equal? (param "PASS_GITLAB") "1")')"
gitlab_block="$(sed -n "${gitlab_when:-1},+4p" <<<"${SB}")"
for glab_dir in "${GLAB_DIRS[@]}"; do
    rule="(subpath (string-append (param \"HOME_DIR\") \"${glab_dir}\"))"
    assert_contains "${homedir_block}" "(require-not ${rule})" "ALLOW_RO_HOMEDIR excludes ~${glab_dir}"
    assert_contains "${gitlab_block}" "${rule}" "PASS_GITLAB grants ~${glab_dir}"
    hits="$(grep -nF -- "\"${glab_dir}\"))" <<<"${SB}" | grep -v 'require-not' | cut -d: -f1)"
    ok=1
    for h in ${hits}; do [[ -n "${gitlab_when}" && "${h}" -gt "${gitlab_when}" && "${h}" -le "$((gitlab_when + 4))" ]] || ok=0; done
    [[ -n "${hits}" ]] || ok=0
    assert_eq "${ok}" "1" "~${glab_dir} granted only under PASS_GITLAB"
done
out="$(_dryrun)"
assert_contains "${out}" "PASS_GITLAB=0" "AI_SANDBOX_PASS_GITLAB defaults to PASS_GITLAB=0"
out="$(AI_SANDBOX_PASS_GITLAB=1 _dryrun)"
assert_contains "${out}" "PASS_GITLAB=1" "AI_SANDBOX_PASS_GITLAB=1 passes PASS_GITLAB=1"
# The keychain grants appear only inside the ALLOW_KEYCHAIN block.
kc_when="$(_line_of '(when (equal? (param "ALLOW_KEYCHAIN") "1")')"
assert_eq "$(grep -c '"com.apple.SecurityServer"\|"com.apple.securityd"' <<<"${SB}")" "2" "SecurityServer / securityd named once each"
for name in '"com.apple.SecurityServer"' '"com.apple.securityd"' '"/Library/Keychains")))'; do
    hits="$(grep -nF -- "${name}" <<<"${SB}" | grep -v 'require-not' | cut -d: -f1)"
    ok=1
    for h in ${hits}; do [[ -n "${kc_when}" && "${h}" -gt "${kc_when}" ]] || ok=0; done
    [[ -n "${hits}" ]] || ok=0
    assert_eq "${ok}" "1" "${name} granted only under ALLOW_KEYCHAIN"
done
assert_contains "${SB}" '(global-name "com.apple.trustd")' "trustd (TLS evaluation) stays unconditionally reachable"

# ---------------------------------------------------------------------------
if [[ "${OS}" != "Darwin" ]]; then
    echo "  skip - native Seatbelt probes (${OS} is not Darwin)"
    assert_no_live_client_reached
    tests_summary_and_exit
fi
if ! command -v sandbox-exec >/dev/null 2>&1; then
    _test_report 1 "sandbox-exec is available for native probes"
    tests_summary_and_exit
fi

echo "-- native: git credential files"
mkdir -p "${FAKE_HOME}/.config/git" "${FAKE_HOME}/Library/Keychains"
printf 'https://synthetic:%s@example.invalid\n' "${RUN_ID}" >"${FAKE_HOME}/.git-credentials"
printf 'https://synthetic:%s@example.invalid\n' "${RUN_ID}" >"${FAKE_HOME}/.config/git/credentials"
printf '*.swp\n' >"${FAKE_HOME}/.config/git/ignore"
_read_probe() {
    # shellcheck disable=SC2016  # expanded by the sandboxed sh
    printf '%s' 'for f in "$@"; do if cat "$f" >/dev/null 2>&1; then echo "READ:$f"; else echo "DENIED:$f"; fi; done'
}
_native() {
    ( cd "${FAKE_HOME}/project" && _load_backend \
        && _run_sandboxed_agent_impl /bin/sh -- -- -c "$(_read_probe)" _ "$@" ) 2>&1
}
for homedir in 0 1; do
    out="$(AI_SANDBOX_ALLOW_RO_HOMEDIR=${homedir} _native "${FAKE_HOME}/.git-credentials" \
        "${FAKE_HOME}/.config/git/credentials" "${FAKE_HOME}/.config/git/ignore")"
    echo "  (ALLOW_RO_HOMEDIR=${homedir} output: ${out})"
    assert_contains "${out}" "DENIED:${FAKE_HOME}/.git-credentials" "native ALLOW_RO_HOMEDIR=${homedir}: ~/.git-credentials denied"
    assert_contains "${out}" "DENIED:${FAKE_HOME}/.config/git/credentials" "native ALLOW_RO_HOMEDIR=${homedir}: ~/.config/git/credentials denied"
    assert_contains "${out}" "READ:${FAKE_HOME}/.config/git/ignore" "native ALLOW_RO_HOMEDIR=${homedir}: ~/.config/git/ignore still readable"
done

echo "-- native: glab config (ALLOW_RO_HOMEDIR x PASS_GITLAB)"
# Fixtures sit in the fake home under the real $HOME, outside the /tmp and
# DARWIN_USER_TEMP_DIR trees the profile grants broadly.
glab_files=(
    "${FAKE_HOME}/Library/Application Support/glab-cli/config.yml"
    "${FAKE_HOME}/.config/glab-cli/config.yml"
    "${FAKE_HOME}/.local/share/glab-cli/state.yml"
)
for glab_file in "${glab_files[@]}"; do
    mkdir -p "$(dirname "${glab_file}")"
    printf 'token: synthetic-glab-%s\n' "${RUN_ID}" >"${glab_file}"
done
benign_file="${FAKE_HOME}/benign-home-${RUN_ID}.txt"
printf 'benign\n' >"${benign_file}"
for homedir in 0 1; do
    for gitlab in 0 1; do
        label="native ALLOW_RO_HOMEDIR=${homedir} PASS_GITLAB=${gitlab}"
        out="$(AI_SANDBOX_ALLOW_RO_HOMEDIR=${homedir} AI_SANDBOX_PASS_GITLAB=${gitlab} \
            _native "${glab_files[@]}" "${benign_file}")"
        want_glab="DENIED"; [[ "${gitlab}" == "1" ]] && want_glab="READ"
        want_benign="DENIED"; [[ "${homedir}" == "1" ]] && want_benign="READ"
        for glab_file in "${glab_files[@]}"; do
            assert_contains "${out}" "${want_glab}:${glab_file}" "${label}: ${glab_file#"${FAKE_HOME}"/} ${want_glab}"
        done
        assert_contains "${out}" "${want_benign}:${benign_file}" "${label}: benign home file ${want_benign} (control)"
    done
done

echo "-- native: Keychain file path"
printf 'not-a-real-keychain\n' >"${FAKE_HOME}/Library/Keychains/probe-${RUN_ID}.keychain-db"
probe_db="${FAKE_HOME}/Library/Keychains/probe-${RUN_ID}.keychain-db"
out="$(_native "${probe_db}")"
assert_contains "${out}" "DENIED:${probe_db}" "native default: ~/Library/Keychains unreadable"
out="$(AI_SANDBOX_ALLOW_KEYCHAIN=1 _native "${probe_db}")"
assert_contains "${out}" "READ:${probe_db}" "native ALLOW_KEYCHAIN=1: ~/Library/Keychains readable"
rm -f "${probe_db}"

echo "-- native: synthetic keychain through securityd"
if [[ "${RUN_KEYCHAIN_PROBE}" != "1" ]]; then
    echo "  skip - synthetic keychain probe (runs on CI or with AI_WRAPPER_TEST_SYNTHETIC_KEYCHAIN=1)"
else
    # Only the throwaway keychain is ever named; the default keychain and
    # the user's items are never queried.
    if security create-keychain -p "${SYNTH_PASS}" "${SYNTH_KEYCHAIN}" >/dev/null 2>&1; then
        keychain_created=1
    fi
    assert_eq "${keychain_created}" "1" "synthetic keychain created in the fake home"
    security unlock-keychain -p "${SYNTH_PASS}" "${SYNTH_KEYCHAIN}" >/dev/null 2>&1
    security add-generic-password -a synthetic -s "${SYNTH_SERVICE}" -w "${SYNTH_SECRET}" \
        -T /usr/bin/security "${SYNTH_KEYCHAIN}" >/dev/null 2>&1
    # shellcheck disable=SC2016  # expanded by the sandboxed sh
    kc_probe='security find-generic-password -s "$1" -w "$2" 2>/dev/null || echo KEYCHAIN_DENIED'
    out="$( cd "${FAKE_HOME}/project" && _load_backend \
        && _run_sandboxed_agent_impl /bin/sh -- -- -c "${kc_probe}" _ "${SYNTH_SERVICE}" "${SYNTH_KEYCHAIN}" 2>&1 )"
    assert_not_contains "${out}" "${SYNTH_SECRET}" "native default: synthetic keychain item unreadable"
    assert_contains "${out}" "KEYCHAIN_DENIED" "native default: security lookup fails"
    out="$( cd "${FAKE_HOME}/project" && _load_backend && export AI_SANDBOX_ALLOW_KEYCHAIN=1 \
        && _run_sandboxed_agent_impl /bin/sh -- -- -c "${kc_probe}" _ "${SYNTH_SERVICE}" "${SYNTH_KEYCHAIN}" 2>&1 )"
    assert_contains "${out}" "${SYNTH_SECRET}" "native ALLOW_KEYCHAIN=1: synthetic keychain item readable"
fi

assert_no_live_client_reached
tests_summary_and_exit
