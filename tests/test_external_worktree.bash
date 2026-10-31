#!/bin/bash
# Linked worktrees whose repository (shared .git) lies outside $HOME (#13).
#   - AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES (default 0) gates eligibility of
#     an external common dir; off keeps the HOME-only rule, on admits
#     exactly the validated common dir with the same link / shape checks
#     and read-only overlays as under $HOME.
#   - the location guard _wrapper_git_external_location_ok (system, temp,
#     hidden and HOME-containing locations refused, per path component)
#   - the setting is session-only: never saved to / restored from presets
#   - the bind runs after the menu (_apply_post_menu_binds), so an s)
#     Settings toggle applies (driven through a real pty)
#   - raw AI_SANDBOX_EXTRA_RW_DIRS grants on git metadata WARN, not refuse
#   - native enforcement (bwrap on Linux, sandbox-exec on macOS): commits /
#     refs / objects persist, shared config / hooks / worktrees / pointers /
#     submodule metadata stay read-only, sibling and canary files outside
#     the common dir stay unreadable and unwritten.
# External fixtures live next to the fake HOME (outside it, never in real
# user repos); the system temp dir serves as the refused-location fixture.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
# Lexical-prefix sibling of the fake HOME ("<home>-prefix") and the
# candidate parent for the external fixture. Created before isolation
# changes HOME.
PREFIX_DIR="${FAKE_HOME}-prefix"
mkdir -p "${PREFIX_DIR}"
EXT_CANDIDATES="${HOME} ${REPO_ROOT}/tests"
SCRATCH="$(mktemp -d)"
SCRATCH="$(cd "${SCRATCH}" && pwd -P)"
EXT=""
isolate_test_env "${FAKE_HOME}"
cleanup() { rm -rf "${FAKE_HOME}" "${PREFIX_DIR}" "${SCRATCH}" ${EXT:+"${EXT}"} ${EXT:+"${EXT}.link"}; }
trap cleanup EXIT

OS="$(uname -s)"
NL=$'\n'
OPTIN=AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES

_load() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=../bin/ai_wrapper_data/codex_wrapper_lib.bash
    source "${REPO_ROOT}/bin/ai_wrapper_data/codex_wrapper_lib.bash"
}

echo "== external worktree tests (${OS}) =="

# ---------------------------------------------------------------------------
echo "-- location guard (pure string check)"
_loc() { ( _load; _wrapper_git_external_location_ok "${1}" "${FAKE_HOME}" ); }
for p in /etc/r/.git /usr/local/src/r/.git /var/lib/r/.git /private/var/folders/x/r/.git \
        /private/tmp/r/.git /tmp/r/.git /root/r/.git /opt/r/.git /nix/store/r.git \
        /proc/1/r/.git /Users/Shared/r/.git /Library/r/.git /System/r/.git; do
    out="$(_loc "${p}")"; rc=$?
    assert_eq "${rc}" "1" "location: ${p} refused"
    assert_contains "${out}" "under /" "location: ${p} names the refused root"
done
for p in /Data/projects/r/.git /Volumes/Work/r.git /mnt/disk/r/.git /srv/git/r.git \
        /media/usb/r/.git /home/other/r/.git /Users/other/r/.git /etcx/r/.git \
        /optional/r/.git /Data/a.b/r/.git; do
    out="$(_loc "${p}")"; rc=$?
    assert_eq "${rc}:${out}" "0:" "location: ${p} eligible"
done
out="$(_loc /Data/.hidden/r/.git)"; rc=$?
assert_eq "${rc}" "1" "location: below a hidden directory refused"
assert_contains "${out}" "hidden" "... naming the reason"
out="$(_loc /home/bob/.config/x/r/.git)"; rc=$?
assert_eq "${rc}" "1" "location: another user's dotfile tree refused"
out="$(_loc "${FAKE_HOME%/*}")"; rc=$?
assert_eq "${rc}" "1" "location: a directory containing \$HOME refused"
assert_contains "${out}" "contains \$HOME" "... naming the reason"
out="$(_loc relative/r/.git)"; rc=$?
assert_eq "${rc}" "1" "location: relative path refused"

if ! command -v git >/dev/null 2>&1; then
    echo "  skip - git not installed: no worktree fixtures"
    assert_no_live_client_reached
    tests_summary_and_exit
fi

# Pick an external fixture parent: outside the fake HOME and in a location
# the guard accepts (the real HOME on CI runners; the checkout otherwise).
for cand in ${EXT_CANDIDATES}; do
    cand="$(cd "${cand}" 2>/dev/null && pwd -P)" || continue
    if ( _load; _wrapper_git_external_location_ok "${cand}/x/r/.git" "${FAKE_HOME}" >/dev/null ); then
        EXT="$(mktemp -d "${cand}/ai-wrapper-ext.XXXXXX")"
        EXT="$(cd "${EXT}" && pwd -P)"
        break
    fi
done
if [[ -z "${EXT}" ]]; then
    _test_report 0 "an eligible external fixture location exists (tried: ${EXT_CANDIDATES})"
    tests_summary_and_exit
fi
echo "  (external fixture root: ${EXT})"

git_q() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
_mkrepo() { git_q init "${1}" && git_q -C "${1}" commit --allow-empty -m init; }
_fake_gitdir() { mkdir -p "${1}/objects" "${1}/refs/heads"; echo 'ref: refs/heads/main' >"${1}/HEAD"; : >"${1}/config"; }
# Run the common-dir bind in DIR with the opt-in set to VALUE ("unset"
# leaves it unset); print WRAPPER_FLAGS then the log. Extra args are
# assignments applied first (e.g. _wrapper_os=Darwin for a simulated
# macOS flag shape).
_gitbind() {
    local dir="${1}" val="${2}"; shift 2
    (
        cd "${dir}" || exit 1
        _load
        if [[ "${val}" == "unset" ]]; then unset "${OPTIN}"; else export "${OPTIN}=${val}"; fi
        local a; for a in "$@"; do eval "${a}"; done
        WRAPPER_FLAGS=()
        _wrapper_bind_git_common_dir
        printf '%s\n' "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}"
    ) 2>&1
}

# Fixtures: EXT/main with worktrees EXT/wt and FAKE_HOME/repos/hwt; a
# sibling repo and canary next to it; a HOME repo for the regression.
_mkrepo "${EXT}/main"
git_q -C "${EXT}/main" worktree add "${EXT}/wt" -b wt
mkdir -p "${FAKE_HOME}/repos"
git_q -C "${EXT}/main" worktree add "${FAKE_HOME}/repos/hwt" -b hwt
_mkrepo "${EXT}/sibling"
echo "sibling-secret" >"${EXT}/sibling/secret.txt"
echo "canary" >"${EXT}/canary.txt"
_mkrepo "${FAKE_HOME}/repos/home-main"
git_q -C "${FAKE_HOME}/repos/home-main" worktree add "${FAKE_HOME}/repos/home-wt" -b home-wt
MG="${EXT}/main/.git"
HMG="${FAKE_HOME}/repos/home-main/.git"
sanity="$(cd "${EXT}/wt" && git rev-parse --git-common-dir 2>/dev/null)"
sanity="$(cd "${EXT}/wt" && cd "${sanity}" 2>/dev/null && pwd -P)"
assert_eq "${sanity}" "${MG}" "sanity: git reports the external common dir for EXT/wt"

# ---------------------------------------------------------------------------
echo "-- opt-in off: HOME-only eligibility kept"
for val in unset 0; do
    out="$(_gitbind "${EXT}/wt" "${val}")"
    assert_not_contains "${out}" "--bind" "opt-in ${val}: external common dir not bound"
    assert_contains "${out}" "AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES is off" "opt-in ${val}: rejection names the setting"
    assert_contains "${out}" "set AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES=1" "opt-in ${val}: WARN points to the session opt-in"
    assert_not_contains "${out}" "EXTRA_RW_DIRS" "opt-in ${val}: no advice to use a raw RW grant"
    out="$(_gitbind "${FAKE_HOME}/repos/hwt" "${val}")"
    assert_not_contains "${out}" "--bind" "opt-in ${val}: HOME-side worktree of an external repo not bound"
    out="$(_gitbind "${FAKE_HOME}/repos/home-wt" "${val}")"
    assert_contains "${out}" "--bind${NL}${HMG}${NL}" "opt-in ${val}: HOME worktree still bound (no opt-in needed)"
    assert_not_contains "${out}" "WARN" "opt-in ${val}: HOME worktree binds without WARN"
done
# Lexical prefix of $HOME is not "under $HOME".
_mkrepo "${PREFIX_DIR}/main"
git_q -C "${PREFIX_DIR}/main" worktree add "${PREFIX_DIR}/wt" -b wt
out="$(_gitbind "${PREFIX_DIR}/wt" unset)"
assert_not_contains "${out}" "--bind" "\$HOME-prefixed sibling (${PREFIX_DIR##*/}): not treated as under \$HOME"
assert_contains "${out}" "is off" "... rejected as external with the opt-in off"

# ---------------------------------------------------------------------------
echo "-- opt-in on: exact validated common dir, same overlays"
_assert_protected_bind() {
    local out="${1}" label="${2}" entry="${3}" ro
    assert_contains "${out}" "--bind${NL}${MG}${NL}" "${label}: shared .git bound"
    for ro in config hooks worktrees "worktrees/${entry}/commondir" "worktrees/${entry}/gitdir"; do
        assert_contains "${out}" "--ro-bind${NL}${MG}/${ro}${NL}" "${label}: ${ro} read-only"
    done
    assert_contains "${out}" "--bind${NL}${MG}/worktrees/${entry}${NL}" "${label}: own worktree entry RW"
    # Darwin adds a stat()-only --meta-bind on the parent (checked below);
    # what must never appear is a content or RW grant on it.
    assert_not_contains "${out}" "--bind${NL}${EXT}${NL}" "${label}: no RW grant on the external parent"
    assert_not_contains "${out}" "--ro-bind${NL}${EXT}${NL}" "${label}: no read grant on the external parent"
    assert_not_contains "${out}" "${EXT}/sibling" "${label}: sibling repo not granted"
    assert_not_contains "${out}" "${EXT}/canary" "${label}: canary not granted"
}
out="$(_gitbind "${EXT}/wt" 1)"
_assert_protected_bind "${out}" "external worktree" wt
assert_contains "${out}" "binding git common dir ${MG} (outside \$HOME)" "external worktree: bind is logged"
if [[ "${OS}" == "Linux" ]]; then
    order="$(printf '%s\n' "${out}" | grep -n -x -e "${MG}" -e "${MG}/worktrees" -e "${MG}/worktrees/wt" -e "${MG}/worktrees/wt/gitdir" | awk -F: 'NR%2==1{print $2}' | tr '\n' ' ')"
    assert_eq "${order}" "${MG} ${MG}/worktrees ${MG}/worktrees/wt ${MG}/worktrees/wt/gitdir " "external worktree: bind order RW, RO, RW, RO"
fi
out="$(_gitbind "${FAKE_HOME}/repos/hwt" 1)"
_assert_protected_bind "${out}" "HOME-side worktree of an external repo" hwt
out="$(_gitbind "${EXT}/wt" 1 "export AI_SANDBOX_ALLOW_GIT_CONFIG=1")"
assert_contains "${out}" "--ro-bind${NL}${MG}/config${NL}" "ALLOW_GIT_CONFIG=1 does not relax external shared config"
assert_contains "${out}" "--ro-bind${NL}${MG}/hooks${NL}" "ALLOW_GIT_CONFIG=1 does not relax external shared hooks/"
out="$(_gitbind "${PREFIX_DIR}/wt" 1)"
assert_contains "${out}" "--bind${NL}${PREFIX_DIR}/main/.git${NL}" "\$HOME-prefixed sibling: eligible as an external repo with the opt-in"
# Alias: reaching the worktree through a symlinked parent binds the
# resolved common dir only.
ln -s "${EXT}" "${EXT}.link"
out="$(_gitbind "${EXT}.link/wt" 1)"
assert_contains "${out}" "--bind${NL}${MG}${NL}" "symlinked alias of the external root: resolved common dir bound"
assert_not_contains "${out}" "${EXT}.link" "... never the alias path"
# Simulated macOS flag shape (flag rendering only; native enforcement is
# the e2e block below): stat()-only grants on the external ancestors of
# the common dir and WORKDIR, none on siblings.
out="$(_gitbind "${EXT}/wt" 1 "_wrapper_os=Darwin")"
for p in "${EXT}/main" "${EXT}" "${EXT%/*}"; do
    assert_contains "${out}" "--meta-bind${NL}${p}${NL}" "simulated macOS: metadata-only grant on ${p}"
done
assert_not_contains "${out}" "--bind${NL}${EXT}${NL}" "simulated macOS: no RW grant on the external parent"
assert_not_contains "${out}" "--ro-bind${NL}${EXT}${NL}" "simulated macOS: no read grant on the external parent"
assert_not_contains "${out}" "${EXT}/sibling" "simulated macOS: nothing on the sibling repo"
out="$(_gitbind "${FAKE_HOME}/repos/home-wt" unset "_wrapper_os=Darwin")"
assert_not_contains "${out}" "--meta-bind${NL}${EXT}" "simulated macOS: HOME worktree gets no external grants"

# ---------------------------------------------------------------------------
echo "-- opt-in on: mandatory checks still refuse"
# Borrowed entry: a checkout's .git points at EXT/wt's existing entry.
for evil in "${EXT}/evil" "${FAKE_HOME}/repos/evil"; do
    mkdir -p "${evil}"
    printf 'gitdir: %s\n' "${MG}/worktrees/wt" >"${evil}/.git"
    out="$(_gitbind "${evil}" 1)"
    assert_not_contains "${out}" "--bind" "borrowed entry from ${evil#"${EXT%/*}/"}: not bound"
    assert_contains "${out}" "belongs to ${EXT}/wt/.git" "... rejected by the reverse link"
done
# Forged backlink: the entry's gitdir replaced by a symlink naming the
# checkout.
git_q -C "${EXT}/main" worktree add "${EXT}/wt3" -b wt3
printf '%s\n' "${EXT}/wt3/.git" >"${EXT}/forged-gitdir"
rm -f "${MG}/worktrees/wt3/gitdir"; ln -s "${EXT}/forged-gitdir" "${MG}/worktrees/wt3/gitdir"
out="$(_gitbind "${EXT}/wt3" 1)"
assert_not_contains "${out}" "--bind" "symlinked backlink: not bound"
assert_contains "${out}" "belongs to unknown" "... rejected by the reverse link"
# Backlink naming another checkout.
printf '%s\n' "${EXT}/wt/.git" >"${EXT}/other-gitdir"
rm -f "${MG}/worktrees/wt3/gitdir"; cp "${EXT}/other-gitdir" "${MG}/worktrees/wt3/gitdir"
out="$(_gitbind "${EXT}/wt3" 1)"
assert_not_contains "${out}" "--bind" "backlink naming another checkout: not bound"
assert_contains "${out}" "belongs to ${EXT}/wt/.git" "... rejected by the reverse link"
git_q -C "${EXT}/main" worktree remove --force "${EXT}/wt3"; rm -rf "${EXT}/wt3" "${MG}/worktrees/wt3"
# Crafted commondir at a non-repo external dir and at a sibling's work tree.
_crafted_repo() {
    local wd="${1}" target="${2}"
    rm -rf "${wd}"; mkdir -p "${wd}/.g/wt"
    echo 'ref: refs/heads/main' >"${wd}/.g/wt/HEAD"
    printf '%s\n' "${target}" >"${wd}/.g/wt/commondir"
    printf 'gitdir: %s\n' "${wd}/.g/wt" >"${wd}/.git"
}
_fake_gitdir "${EXT}/notrepo"
_crafted_repo "${FAKE_HOME}/repos/crafted" "${EXT}/notrepo"
out="$(_gitbind "${FAKE_HOME}/repos/crafted" 1)"
assert_not_contains "${out}" "--bind" "crafted commondir -> external non-.git dir: not bound"
assert_contains "${out}" "basename 'notrepo'" "... rejected by the basename rule"
_crafted_repo "${FAKE_HOME}/repos/crafted" "${EXT}/sibling/.git"
out="$(_gitbind "${FAKE_HOME}/repos/crafted" 1)"
assert_not_contains "${out}" "--bind" "crafted commondir -> sibling repo's .git: not bound"
assert_contains "${out}" "is not a worktree of it" "... rejected by the forward link"
# Refused locations, real Git layout: the system temp dir and a hidden dir.
_mkrepo "${SCRATCH}/main"
git_q -C "${SCRATCH}/main" worktree add "${EXT}/tmpwt" -b tmpwt
out="$(_gitbind "${EXT}/tmpwt" 1)"
assert_not_contains "${out}" "--bind" "repo in the system temp dir (${SCRATCH%/*}): not bound"
assert_contains "${out}" "refused location" "... rejected by the location guard"
_mkrepo "${EXT}/.hidden/main"
git_q -C "${EXT}/.hidden/main" worktree add "${EXT}/hidwt" -b hidwt
out="$(_gitbind "${EXT}/hidwt" 1)"
assert_not_contains "${out}" "--bind" "repo below a hidden external dir: not bound"
assert_contains "${out}" "below a hidden directory" "... rejected by the location guard"
# The ~/.local/share submodule exception stays HOME-only.
_fake_gitdir "${EXT}/sup/.git"; _fake_gitdir "${EXT}/sup/.git/modules/m"
out="$( ( _load; export "${OPTIN}=1"; _wrapper_git_common_dir_ok "${EXT}/sup/.git/modules/m" "${FAKE_HOME}" "${EXT}/wt" ) 2>&1 )"
assert_contains "${out}" "refused location (below a hidden directory)" "external .git/modules/<name> common dir rejected (no submodule exception)"

# ---------------------------------------------------------------------------
echo "-- session-only: excluded from preset save and load"
P="${FAKE_HOME}/preset-wd"
mkdir -p "${P}"
_in_preset() { ( cd "${P}" && _load && eval "${1}" ) 2>&1; }
catalog="$( _load; printf '%s\n' "${_AI_SETTINGS_LIST[@]}" )"
assert_contains "${catalog}" "${OPTIN}|bool|0|" "catalog: bool, default 0"
row="$(printf '%s\n' "${catalog}" | grep "^${OPTIN}|")"
assert_eq "${row##*|}" "sensitive" "catalog: listed under sensitive settings on every OS"
saved="$(_in_preset "export ${OPTIN}=1; _preset_autosave 2>/dev/null; cat \"\$(_preset_autosave_path)\"")"
assert_not_contains "${saved}" "${OPTIN}" "autosave: session opt-in never written"
assert_contains "${saved}" "AI_SANDBOX_ALLOW_GIT_CONFIG=" "autosave: other settings still written"
preset_file="$(_in_preset '_preset_autosave_path')"
printf '%s=1\n' "${OPTIN}" >>"${preset_file}"
out="$(_in_preset "unset ${OPTIN}; _preset_autoload; echo \"VAL=\${${OPTIN}:-unset}\"")"
assert_contains "${out}" "VAL=unset" "autoload: injected =1 does not authorize"
assert_contains "${out}" "Ignoring ${OPTIN} in the saved preset" "autoload: injected entry WARNs"
out="$(_in_preset "export ${OPTIN}=0; _preset_autoload; echo \"VAL=\${${OPTIN}}\"")"
assert_contains "${out}" "VAL=0" "autoload: explicit launch =0 kept over an injected =1"
printf '%s=0\n' "${OPTIN}" >>"${preset_file}"
out="$(_in_preset "export ${OPTIN}=1; _preset_autoload; echo \"VAL=\${${OPTIN}}\"")"
assert_contains "${out}" "VAL=1" "autoload: launch =1 kept over a saved =0"
legacy_file="$(_in_preset '_preset_legacy_path')"
rm -f "${preset_file}"
printf '%s=1\nAI_SANDBOX_DEBUG=0\n' "${OPTIN}" >"${legacy_file}"
out="$(_in_preset "unset ${OPTIN}; _preset_autoload; echo \"VAL=\${${OPTIN}:-unset}\"")"
assert_contains "${out}" "VAL=unset" "autoload: legacy preset =1 does not authorize"
rm -f "${legacy_file}"

# ---------------------------------------------------------------------------
echo "-- raw AI_SANDBOX_EXTRA_RW_DIRS on git metadata: warning only"
_rawwarn() { ( cd "${1}" && _load && _WRAPPER_GIT_COMMON_PROTECTED="${3:-}" && _sandbox_warn_extra_rw_git codex "${2}"; echo "RC=$?" ) 2>&1; }
out="$(_rawwarn "${EXT}/wt" "${MG}")"
assert_contains "${out}" "exposes git metadata ${MG} read-write without the read-only config / hooks/ overlays" "raw RW on an unprotected .git: WARN"
assert_contains "${out}" "AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES=1" "... pointing to the protected opt-in"
assert_contains "${out}" "RC=0" "... without refusing"
out="$(_rawwarn "${EXT}/wt" "${EXT}/sibling")"
assert_contains "${out}" "exposes git metadata ${EXT}/sibling/.git" "raw RW on a repo work tree: WARN names its .git"
out="$(_rawwarn "${EXT}/wt" "${MG}" "${MG}")"
assert_not_contains "${out}" "WARNING" "raw RW on the protected common dir: no false overlay claim"
out="$(_rawwarn "${EXT}/sibling" "${EXT}/sibling")"
assert_not_contains "${out}" "WARNING" "raw RW on WORKDIR itself (own .git protected): no WARN"
mkdir -p "${EXT}/plain"
out="$(_rawwarn "${EXT}/wt" "${EXT}/plain")"
assert_not_contains "${out}" "WARNING" "raw RW on a non-git dir: no WARN"

# ---------------------------------------------------------------------------
# Native enforcement through the codex wrapper.
sandbox_e2e=0
if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    sandbox_e2e=1
elif [[ "${OS}" == "Darwin" ]]; then
    if command -v sandbox-exec >/dev/null 2>&1; then
        sandbox_e2e=1
    else
        _test_report 0 "e2e external worktree: sandbox-exec available on macOS"
    fi
else
    echo "  skip - e2e external worktree: no bwrap (Linux) / sandbox-exec (macOS) on this host"
fi
stub_ro_dirs=""
[[ "${OS}" == "Darwin" ]] && stub_ro_dirs="${FAKE_HOME}/bin"
mkdir -p "${MG}/modules/sub1/hooks"; : >"${MG}/modules/sub1/config"
[[ -e "${MG}/hooks/pre-commit.sample" ]] || : >"${MG}/hooks/pre-commit.sample"

# Probe client: proves discovery of exactly the fixture before any write
# (SETUP_FAILED + exit 3 otherwise), then probes and ends with PROBES_DONE.
_dev_ino() { stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"; }
_write_probe_stub() {
    {
        printf '#!/bin/bash\nexpect_m=%q\nexpect_w=%q\nexpect_wt_git=%q\next=%q\next_id=%q\nwt_id=%q\n' \
            "${MG}" "${MG}/worktrees/wt" "${EXT}/wt/.git" "${EXT}" "$(_dev_ino "${EXT}")" "$(_dev_ino "${EXT}/wt")"
        cat <<'STUB'
setup_failed() { echo "SETUP_FAILED: $*"; exit 3; }
m="$(git rev-parse --git-common-dir 2>&1)" || setup_failed "git rev-parse --git-common-dir: ${m}"
w="$(git rev-parse --absolute-git-dir 2>&1)" || setup_failed "git rev-parse --absolute-git-dir: ${w}"
m="$(cd "${m}" 2>&1 && pwd -P)" || setup_failed "cannot enter common dir: ${m}"
[[ "${m}" == "${expect_m}" && "${w}" == "${expect_w}" ]] \
    || setup_failed "discovered common='${m}' own='${w}', expected '${expect_m}' '${expect_w}'"
for p in config hooks/pre-commit.sample modules/sub1/config modules/sub1/hooks objects refs \
        worktrees/hwt/HEAD; do
    [[ -e "${m}/${p}" ]] || setup_failed "missing ${m}/${p}"
done
[[ "$(cat "${w}/gitdir" 2>&1)" == "${expect_wt_git}" ]] || setup_failed "${w}/gitdir does not point back to ${expect_wt_git}"
echo DISCOVERY_OK
g() { git -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
echo "$$-${RANDOM}" >file && g add file && g commit -m sandboxed && echo COMMIT_OK
g branch ext-side && echo BRANCH_OK
ren() { perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$@"; }
export -f ren
dev_ino() { stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null; }
# Backing identity of the external parent as seen in the sandbox: same
# st_dev:st_ino as on the host means host-backed (writes must be denied);
# a different one is a private mountpoint skeleton (bwrap). Unknown
# (stat denied) counts as host-backed. WORKDIR, bound from the host, is
# the positive control that the identity check works in the sandbox.
[[ "$(dev_ino .)" == "${wt_id}" ]] && echo "WT:host-backed" || echo "WT:mismatch"
now_id="$(dev_ino "${ext}")"
if [[ -n "${now_id}" && "${now_id}" != "${ext_id}" ]]; then echo "PARENT:private"; else echo "PARENT:host-backed"; fi
# Listed before any write probe so a private scratch file planted by the
# probes below cannot be mistaken for a host canary.
listing="$(ls -A "${ext}" 2>/dev/null)"
case "${listing}" in *sibling*|*canary*) echo "LEAK:parent-listing" ;; *) echo "NOLEAK:parent-listing" ;; esac
probe() { local name="${1}"; shift; if ("$@") >/dev/null 2>&1; then echo "WROTE:${name}"; else echo "DENIED:${name}"; fi; }
probe append-config sh -c 'echo evil >>"$1"' _ "${m}/config"
probe replace-config bash -c 'echo evil >cfg.tmp && ren cfg.tmp "$1"' _ "${m}/config"
probe hook-create sh -c 'echo evil >"$1"' _ "${m}/hooks/post-commit"
probe hooks-rename ren "${m}/hooks" "${m}/hooks.old"
probe other-entry-head sh -c 'echo evil >"$1"' _ "${m}/worktrees/hwt/HEAD"
probe worktrees-newentry mkdir "${m}/worktrees/newentry"
probe own-commondir sh -c 'echo evil >>"$1"' _ "${w}/commondir"
probe own-gitdir sh -c 'echo evil >>"$1"' _ "${w}/gitdir"
probe module-config sh -c 'echo evil >>"$1"' _ "${m}/modules/sub1/config"
probe module-hook sh -c 'echo evil >"$1"' _ "${m}/modules/sub1/hooks/post-commit"
probe objects-touch sh -c 'touch "$1/objects/probe" && rm -f "$1/objects/probe"' _ "${m}"
probe refs-touch sh -c 'mkdir -p "$1/refs/probe" && rmdir "$1/refs/probe"' _ "${m}"
probe own-entry-file sh -c 'touch "$1/probe" && rm -f "$1/probe"' _ "${w}"
probe sibling-read cat "${ext}/sibling/secret.txt"
probe sibling-write sh -c 'echo evil >>"$1"' _ "${ext}/sibling/secret.txt"
probe canary-read cat "${ext}/canary.txt"
probe canary-write sh -c 'echo evil >>"$1"' _ "${ext}/canary.txt"
probe parent-create sh -c 'echo evil >"$1"' _ "${ext}/planted"
echo PROBES_DONE
STUB
    } >"${FAKE_HOME}/bin/codex"
    chmod +x "${FAKE_HOME}/bin/codex"
}
_write_probe_stub

# Negative controls (unconfined): the stub refuses a wrong or missing repo.
out="$(cd "${FAKE_HOME}/repos/home-wt" && bash "${FAKE_HOME}/bin/codex" 2>&1)"; rc=$?
assert_eq "${rc}" "3" "probe stub: discovery of another repo exits 3"
assert_contains "${out}" "SETUP_FAILED: discovered" "probe stub: wrong repo reported"
assert_not_contains "${out}" "DENIED:" "probe stub: wrong repo runs no probe"

_protected_sums() {
    local f
    for f in config worktrees/wt/commondir worktrees/wt/gitdir worktrees/hwt/HEAD modules/sub1/config; do
        printf '%s ' "${f}"; cksum <"${MG}/${f}" 2>&1
    done
    ls -A "${MG}/hooks" "${MG}/modules/sub1/hooks" "${MG}/worktrees" 2>&1
    cksum <"${EXT}/sibling/secret.txt"; cksum <"${EXT}/canary.txt"; ls -A "${EXT}"
}
_launch_ext() {
    ( cd "${EXT}/wt" && env PATH="${FAKE_HOME}/bin:${PATH}" AI_SANDBOX_EXTRA_RO_DIRS="${stub_ro_dirs}" "$@" \
        bash "${REPO_ROOT}/bin/executable_codex_wrapper.bash" x </dev/null 2>&1 )
}

if [[ "${sandbox_e2e}" == "1" ]]; then
    sums_before="$(_protected_sums)"
    canary_before="$(cksum <"${EXT}/canary.txt")"
    assert_not_contains "${sums_before}" "No such file" "e2e: fixture has every protected path before the run"

    # Opt-in off (unset, and an injected preset =1): git cannot reach the
    # external common dir.
    preset_file="$(cd "${EXT}/wt" && _load && _preset_autosave_path)"
    mkdir -p "$(dirname "${preset_file}")"
    printf '%s=1\n' "${OPTIN}" >"${preset_file}"
    out="$(_launch_ext)"; rc=$?
    echo "  (e2e opt-in off output: ${out})"
    assert_eq "${rc}" "3" "e2e opt-in off: probe stops at discovery"
    assert_contains "${out}" "SETUP_FAILED" "e2e opt-in off: external common dir not reachable"
    assert_contains "${out}" "Ignoring ${OPTIN} in the saved preset" "e2e opt-in off: injected preset ignored"
    assert_contains "${out}" "is off" "e2e opt-in off: host WARN names the setting"
    assert_not_contains "${out}" "COMMIT_OK" "e2e opt-in off: no git write"
    rm -f "${preset_file}"

    out="$(_launch_ext "${OPTIN}=1")"; rc=$?
    echo "  (e2e opt-in on output: ${out})"
    assert_eq "${rc}" "0" "e2e opt-in on: probe client exits 0"
    assert_contains "${out}" "DISCOVERY_OK" "e2e opt-in on: probe found the external common dir"
    assert_not_contains "${out}" "SETUP_FAILED" "e2e opt-in on: no probe setup failure"
    assert_contains "${out}" "PROBES_DONE" "e2e opt-in on: probe ran to the end"
    assert_contains "${out}" "COMMIT_OK" "e2e opt-in on: commit works"
    assert_contains "${out}" "BRANCH_OK" "e2e opt-in on: branch works"
    for p in append-config replace-config hook-create hooks-rename other-entry-head worktrees-newentry \
            own-commondir own-gitdir module-config module-hook sibling-read sibling-write canary-read; do
        assert_contains "${out}" "DENIED:${p}" "e2e opt-in on: ${p} denied"
    done
    assert_contains "${out}" "WT:host-backed" "e2e opt-in on: identity probe sees the host-backed WORKDIR (positive control)"
    # Writes into the external parent: denied when the sandbox sees the
    # host directory. bwrap shows it as a private mountpoint skeleton
    # (different st_dev:st_ino), where a new scratch file is not a host
    # write; the host checks below prove nothing reached the host parent.
    expect_parent="PARENT:host-backed"
    [[ "${OS}" == "Linux" ]] && expect_parent="PARENT:private"
    assert_contains "${out}" "${expect_parent}" "e2e opt-in on: external parent backing is ${expect_parent#PARENT:}"
    if [[ "${out}" != *"PARENT:private"* ]]; then
        for p in canary-write parent-create; do
            assert_contains "${out}" "DENIED:${p}" "e2e opt-in on: ${p} denied on the host-backed parent"
        done
    fi
    assert_eq "$(cksum <"${EXT}/canary.txt")" "${canary_before}" "e2e opt-in on: host canary bytes unchanged"
    ok=0; [[ -e "${EXT}/planted" ]] || ok=1
    assert_eq "${ok}" "1" "e2e opt-in on: nothing planted in the host external parent"
    for p in objects-touch refs-touch own-entry-file; do
        assert_contains "${out}" "WROTE:${p}" "e2e opt-in on: ${p} writable (positive control)"
    done
    assert_contains "${out}" "NOLEAK:parent-listing" "e2e opt-in on: external parent listing shows no sibling or canary"
    assert_eq "$(_protected_sums)" "${sums_before}" "e2e opt-in on: protected, sibling and canary bytes unchanged on the host"
    assert_eq "$(git -C "${EXT}/main" log --format=%s -1 wt)" "sandboxed" "e2e opt-in on: commit object and ref persisted in the external repo"
    ok=0; git -C "${EXT}/main" rev-parse --verify -q ext-side >/dev/null && ok=1
    assert_eq "${ok}" "1" "e2e opt-in on: branch ref persisted in the external repo"
    git -C "${EXT}/wt" diff --cached --quiet HEAD 2>/dev/null; assert_eq "$?" "0" "e2e opt-in on: index consistent with the new commit"

    # Raw extra RW on a sibling repo: warned, still granted.
    printf '#!/bin/bash\necho RAN\n' >"${FAKE_HOME}/bin/codex"; chmod +x "${FAKE_HOME}/bin/codex"
    out="$(_launch_ext "${OPTIN}=1" AI_SANDBOX_EXTRA_RW_DIRS="${EXT}/sibling")"; rc=$?
    assert_contains "${out}" "exposes git metadata ${EXT}/sibling/.git" "e2e raw RW on a sibling repo: WARN"
    assert_not_contains "${out}" "exposes git metadata ${MG}" "e2e raw RW: no WARN about the protected common dir"
    assert_contains "${out}" "RAN" "e2e raw RW: launch not refused"
    _write_probe_stub
fi

# ---------------------------------------------------------------------------
echo "-- interactive menu: s) Settings opt-in applies before the binds"
if command -v python3 >/dev/null 2>&1; then
    idx="$( _load; i=1; for e in "${_AI_SETTINGS_LIST[@]}"; do [[ "${e%%|*}" == "${OPTIN}" ]] && { echo "${i}"; break; }; i=$((i + 1)); done )"
    cat >"${SCRATCH}/pty_drive.py" <<'PY'
import os, pty, select, sys, time
cwd, wrapper, idx = sys.argv[1:4]
steps = [(b"Choose an option", b"s\n"), (b"Choose setting", idx.encode() + b"\n"),
         (b"Choose setting", b"b\n"), (b"Choose an option", b"2\n")]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execvp("bash", ["bash", wrapper])
buf, pos, deadline = b"", 0, time.time() + 300
while True:
    if time.time() > deadline:
        buf += b"\nPTY_TIMEOUT\n"
        os.kill(pid, 9)
        break
    ready, _, _ = select.select([fd], [], [], 0.5)
    if ready:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        buf += data
    if steps:
        hit = buf.find(steps[0][0], pos)
        if hit >= 0:
            pos = hit + len(steps[0][0])
            os.write(fd, steps[0][1])
            steps.pop(0)
_, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace"))
code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128
sys.stdout.write("\nPTY_EXIT=%d STEPS_LEFT=%d\n" % (code, len(steps)))
PY
    sums_before="$(_protected_sums)"
    out="$(env TERM=dumb PATH="${FAKE_HOME}/bin:${PATH}" AI_SANDBOX_EXTRA_RO_DIRS="${stub_ro_dirs}" \
        python3 -I "${SCRATCH}/pty_drive.py" "${EXT}/wt" "${REPO_ROOT}/bin/executable_codex_wrapper.bash" "${idx}" 2>&1)"
    echo "  (interactive output tail: $(printf '%s\n' "${out}" | tail -n 40))"
    assert_contains "${out}" "STEPS_LEFT=0" "interactive: menu, settings toggle and start were driven"
    assert_not_contains "${out}" "PTY_TIMEOUT" "interactive: wrapper finished"
    assert_contains "${out}" "binding git common dir ${MG} (outside \$HOME)" "interactive: toggled opt-in reached the post-menu bind"
    assert_not_contains "${out}" "Not binding git common dir" "interactive: no pre-menu rejection"
    saved="$(cat "$(cd "${EXT}/wt" && _load && _preset_autosave_path)" 2>&1)"
    assert_contains "${saved}" "AI_SANDBOX_ALLOW_GIT_CONFIG=" "interactive: preset autosaved"
    assert_not_contains "${saved}" "${OPTIN}" "interactive: toggled opt-in not persisted to the preset"
    if [[ "${sandbox_e2e}" == "1" ]]; then
        assert_contains "${out}" "PTY_EXIT=0" "interactive e2e: wrapper exits 0"
        assert_contains "${out}" "DISCOVERY_OK" "interactive e2e: probe found the external common dir"
        assert_contains "${out}" "COMMIT_OK" "interactive e2e: commit works"
        assert_contains "${out}" "DENIED:append-config" "interactive e2e: shared config still read-only"
        assert_contains "${out}" "DENIED:hook-create" "interactive e2e: shared hooks still read-only"
        assert_contains "${out}" "PROBES_DONE" "interactive e2e: probe ran to the end"
        assert_eq "$(_protected_sums)" "${sums_before}" "interactive e2e: protected, sibling and canary bytes unchanged"
    fi
else
    echo "  skip - interactive menu: python3 not installed"
fi

assert_no_live_client_reached
tests_summary_and_exit
