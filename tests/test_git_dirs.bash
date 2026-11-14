#!/bin/bash
# Git inside the sandbox (docs/security-concerns.md B-ρ): the agent has
# full read-write access to the repository's git dir in plain
# repositories, linked worktrees (inside or outside their repository root,
# under $HOME or not, bare repositories included) and submodule checkouts
# (nested and slash-named); no setting turns this off or makes it
# read-only. A git dir outside WORKDIR is bound by
# _wrapper_bind_git_common_dir only after the pointer sanity checks of
# _wrapper_git_common_dir_ok (shape and links; no location list).
#   - plain repository: nothing extra bound, no read-only overlay;
#   - linked worktrees: exactly the validated common dir, read-write as a
#     whole, nothing of its parent tree, siblings or the repository root;
#   - submodule checkouts: exactly <super>/.git/modules/<name> (nested,
#     slash-named, ~/.local/share/<repo>, outside $HOME), never
#     <super>/.git or sibling submodules;
#   - refusals (WARN, nothing bound, launch continues): borrowed or forged
#     worktree links, crafted commondir, foreign gitfiles, core.worktree
#     mismatches, symlinked layouts; real repositories in the system temp
#     dir, a credential dir or a dotfile tree are accepted (B-rho);
#   - AI agent profile/state directories are not refused: a git dir there
#     that passes the link checks is bound read-write (owner-accepted
#     exception, docs/owner-accepted-exceptions.md);
#   - bind order: the git dir is an --under-bind, mounted before every
#     read-only overlay and pin (bwrap argv through a stub bwrap) and
#     never an exception to an --ro-bind write deny (Seatbelt rendering:
#     tests/test_macos_ro_overlays.bash);
#   - descriptor bind (#14): with --bind-fd the git dir is bound by an fd
#     naming exactly the checked directory; a path swapped for a symlink
#     after the check is not bound; without --bind-fd the path is bound;
#   - simulated macOS flag shape: stat()-only grants on the ancestors;
#   - retired settings: a stale preset naming them is handled quietly and
#     the launch environment cannot turn anything off;
#   - native enforcement through the codex wrapper (bwrap on Linux,
#     sandbox-exec on macOS): commit, config, hooks and commondir writes
#     succeed and persist on the host; files next to the git dir stay
#     unreadable and unwritten; read-only extra dirs inside the git dir,
#     or holding it, stay read-only.
# External fixtures live next to the fake HOME (outside it, never in real
# user repos), some in the system temp dir.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(_safe_mktemp_d "${HOME}/ai-wrapper-test.XXXXXX")" || exit 1
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
EXT_CANDIDATES="${HOME} ${REPO_ROOT}/tests"
SCRATCH="$(_safe_mktemp_d)" || exit 1
SCRATCH="$(cd "${SCRATCH}" && pwd -P)"
EXT=""
isolate_test_env "${FAKE_HOME}"
cleanup() { _safe_rm_rf "${FAKE_HOME}" "${SCRATCH}" ${EXT:+"${EXT}"}; rm -f ${EXT:+"${EXT}.link"}; }
trap cleanup EXIT

OS="$(uname -s)"
NL=$'\n'
RETIRED="AI_SANDBOX_ALLOW_GIT_CONFIG AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES AI_SANDBOX_BLOCK_LINKED_GIT_DIRS"

_load() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=../bin/ai_wrapper_data/codex_wrapper_lib.bash
    source "${REPO_ROOT}/bin/ai_wrapper_data/codex_wrapper_lib.bash"
}

echo "== git dir tests (${OS}) =="

if ! command -v git >/dev/null 2>&1; then
    echo "  skip - git not installed: no repository fixtures"
    assert_no_live_client_reached
    tests_summary_and_exit
fi

# Pick an external fixture parent outside the fake HOME (the real HOME on
# CI runners; the checkout otherwise).
for cand in ${EXT_CANDIDATES}; do
    cand="$(cd "${cand}" 2>/dev/null && pwd -P)" || continue
    EXT="$(mktemp -d "${cand}/ai-wrapper-ext.XXXXXX" 2>/dev/null)" || { EXT=""; continue; }
    EXT="$(cd "${EXT}" && pwd -P)"
    break
done
if [[ -z "${EXT}" ]]; then
    _test_report 0 "an eligible external fixture location exists (tried: ${EXT_CANDIDATES})"
    tests_summary_and_exit
fi
echo "  (external fixture root: ${EXT})"

git_q() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@t -c protocol.file.allow=always "$@" >/dev/null 2>&1; }
_mkrepo() { git_q init "${1}" && git_q -C "${1}" commit --allow-empty -m init; }
_fake_gitdir() { mkdir -p "${1}/objects" "${1}/refs/heads"; echo 'ref: refs/heads/main' >"${1}/HEAD"; : >"${1}/config"; }
# Run the git dir bind in DIR; print WRAPPER_FLAGS then the log. Extra args
# are assignments applied first (e.g. _wrapper_os=Darwin for a simulated
# macOS flag shape, or an export of a retired setting).
_gitbind() {
    local dir="${1}"; shift
    (
        cd "${dir}" || exit 1
        _load
        local a; for a in "$@"; do eval "${a}"; done
        WRAPPER_FLAGS=()
        _wrapper_bind_git_common_dir
        printf '%s\n' "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}"
    ) 2>&1
}
# Sources of every grant (--bind / --under-bind / --ro-bind / --pin) in a
# flag dump.
_grants() {
    printf '%s\n' "${1}" | awk 'prev == "--bind" || prev == "--under-bind" || prev == "--ro-bind" || prev == "--pin" { print } { prev = $0 }' | sort -u | tr '\n' ' '
}
# Exactly one grant: GIT_DIR read-write under every RO overlay, nothing
# read-only, no WARN.
_assert_rw_only() {
    local out="${1}" label="${2}" gd="${3}"
    assert_eq "$(_grants "${out}")" "${gd} " "${label}: exactly the git dir granted"
    assert_contains "${out}" "--under-bind${NL}${gd}${NL}" "${label}: git dir bound read-write (--under-bind)"
    assert_not_contains "${out}" "--ro-bind" "${label}: no read-only overlay"
    assert_not_contains "${out}" "WARN" "${label}: no WARN"
}
# Nothing granted, one refusal WARN naming REASON.
_assert_refused() {
    local out="${1}" label="${2}" reason="${3}"
    assert_eq "$(_grants "${out}")" "" "${label}: nothing bound"
    assert_contains "${out}" "git won't work in this checkout because" "${label}: refusal WARN"
    assert_contains "${out}" "${reason}" "${label}: ... naming the reason (${reason})"
    assert_eq "$(printf '%s\n' "${out}" | grep -c 'WARN')" "1" "${label}: exactly one WARN"
}

# Fixtures: EXT/main with worktrees inside its root (EXT/main/.worktrees/in)
# and outside it (EXT/wt, FAKE_HOME/repos/hwt); a sibling repo and canary
# next to it; a HOME repo with worktrees inside and outside its root; bare
# repositories named <name>.git and .bare.
_mkrepo "${EXT}/main"
git_q -C "${EXT}/main" worktree add "${EXT}/wt" -b wt
git_q -C "${EXT}/main" worktree add "${EXT}/main/.worktrees/in" -b in
mkdir -p "${FAKE_HOME}/repos"
git_q -C "${EXT}/main" worktree add "${FAKE_HOME}/repos/hwt" -b hwt
_mkrepo "${EXT}/sibling"
echo "sibling-secret" >"${EXT}/sibling/secret.txt"
echo "canary" >"${EXT}/canary.txt"
_mkrepo "${FAKE_HOME}/repos/home-main"
git_q -C "${FAKE_HOME}/repos/home-main" worktree add "${FAKE_HOME}/repos/home-wt" -b home-wt
git_q -C "${FAKE_HOME}/repos/home-main" worktree add "${FAKE_HOME}/repos/home-main/.worktrees/hin" -b hin
git_q clone --bare "${EXT}/main" "${EXT}/bare.git"
git_q -C "${EXT}/bare.git" worktree add "${EXT}/bare-wt" -b bare-wt
git_q clone --bare "${EXT}/main" "${EXT}/proj/.bare"
git_q -C "${EXT}/proj/.bare" worktree add "${EXT}/proj/feat" -b feat
MG="${EXT}/main/.git"
HMG="${FAKE_HOME}/repos/home-main/.git"
IN="${EXT}/main/.worktrees/in"
sanity="$(cd "${EXT}/wt" && git rev-parse --git-common-dir 2>/dev/null)"
sanity="$(cd "${EXT}/wt" && cd "${sanity}" 2>/dev/null && pwd -P)"
assert_eq "${sanity}" "${MG}" "sanity: git reports the external common dir for EXT/wt"
ok=0; [[ -f "${IN}/.git" && -f "${EXT}/bare-wt/.git" && -f "${EXT}/proj/feat/.git" ]] && ok=1
assert_eq "${ok}" "1" "sanity: worktree fixtures exist"

# ---------------------------------------------------------------------------
echo "-- plain repository: the .git dir comes with WORKDIR"
for dir in "${EXT}/main" "${FAKE_HOME}/repos/home-main"; do
    out="$(_gitbind "${dir}")"
    assert_eq "${out}" "" "plain repo ${dir##*/}: nothing extra bound, no WARN"
done
# A repository subdirectory as WORKDIR: the work tree around it is not in
# the sandbox, so its .git (outside WORKDIR, no worktree link) stays out.
mkdir -p "${EXT}/main/src/deep"
_assert_refused "$(_gitbind "${EXT}/main/src/deep")" "plain repo subdirectory" "is not a worktree of it"
out="$(_gitbind "${EXT}/main/.git")"
assert_eq "${out}" "" "WORKDIR is the git dir itself: nothing extra bound"
out="$(_gitbind "${EXT}/bare.git")"
assert_eq "${out}" "" "WORKDIR is a bare repository: nothing extra bound"
mkdir -p "${FAKE_HOME}/norepo"
assert_eq "$(_gitbind "${FAKE_HOME}/norepo")" "" "no repository: nothing bound, no WARN"
# The full launch path adds no read-only overlay or pin on WORKDIR's .git.
out="$( cd "${EXT}/main" && _load && WRAPPER_FLAGS=() && _apply_post_menu_binds 2>&1; echo "rc=$?"; printf '%s\n' "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}" )"
assert_contains "${out}" "rc=0" "plain repo: post-menu binds succeed"
assert_not_contains "${out}" "${MG}" "plain repo: no overlay, pin or bind on its .git"
assert_not_contains "${out}" "WARN" "plain repo: no WARN"

# ---------------------------------------------------------------------------
echo "-- linked worktrees: the shared .git read-write, anywhere"
for case in "${IN}|${MG}|inside the root, external disk" "${EXT}/wt|${MG}|outside the root, external disk" \
        "${FAKE_HOME}/repos/hwt|${MG}|under \$HOME, repo outside" \
        "${FAKE_HOME}/repos/home-main/.worktrees/hin|${HMG}|\$HOME repo, inside the root" \
        "${FAKE_HOME}/repos/home-wt|${HMG}|\$HOME repo, outside the root" \
        "${EXT}/bare-wt|${EXT}/bare.git|bare <name>.git repository" \
        "${EXT}/proj/feat|${EXT}/proj/.bare|bare .bare repository"; do
    IFS='|' read -r dir gd label <<<"${case}"
    out="$(_gitbind "${dir}")"
    _assert_rw_only "${out}" "worktree, ${label}" "${gd}"
done
out="$(_gitbind "${EXT}/wt")"
assert_not_contains "$(_grants "${out}")" "${EXT}/main " "outside-root worktree: repository root not granted"
assert_not_contains "${out}" "${EXT}/sibling" "outside-root worktree: sibling repo not granted"
assert_not_contains "${out}" "${EXT}/canary" "outside-root worktree: canary not granted"
mkdir -p "${IN}/sub/deeper"
_assert_rw_only "$(_gitbind "${IN}/sub/deeper")" "worktree subdirectory" "${MG}"
# Through symlinked paths: the resolved common dir only.
ln -s "${EXT}" "${EXT}.link"
out="$(_gitbind "${EXT}.link/wt")"
_assert_rw_only "${out}" "worktree reached through a symlinked parent" "${MG}"
assert_not_contains "${out}" "${EXT}.link" "... never the alias path"
_mkrepo "${EXT}/real-store"
mkdir -p "${EXT}/symroot"; ln -s "${EXT}/real-store/.git" "${EXT}/symroot/.git"
git_q -C "${EXT}/symroot" worktree add "${EXT}/symroot/.worktrees/s" -b s
out="$(_gitbind "${EXT}/symroot/.worktrees/s")"
_assert_rw_only "${out}" "worktree of a symlinked <root>/.git" "${EXT}/real-store/.git"
assert_not_contains "${out}" "${EXT}/symroot/.git" "... never the symlink path"
# A worktree of repo A inside repo B's root binds A's .git.
_mkrepo "${EXT}/other"
git_q -C "${EXT}/other" worktree add "${EXT}/main/.worktrees/foreign" -b foreign
_assert_rw_only "$(_gitbind "${EXT}/main/.worktrees/foreign")" "worktree of another repo inside this root" "${EXT}/other/.git"
# Nothing is created or changed in the git dir on the host.
rm -rf "${EXT}/other/.git/hooks"
before="$(ls -A "${EXT}/other/.git" | tr '\n' ' ')"
_gitbind "${EXT}/main/.worktrees/foreign" >/dev/null
assert_eq "$(ls -A "${EXT}/other/.git" | tr '\n' ' ')" "${before}" "worktree bind creates nothing in the common dir (no placeholder hooks/)"
# Retired settings in the launch environment change nothing.
for setting in ${RETIRED}; do
    _assert_rw_only "$(_gitbind "${EXT}/wt" "export ${setting}=1")" "${setting}=1 at launch has no effect" "${MG}"
done

# ---------------------------------------------------------------------------
echo "-- submodule checkouts: only the module git dir, read-write"
MSRC="${EXT}/msrc"
_mkrepo "${MSRC}"
# A superproject with submodules `sub` (holding a nested `inner`) and
# `libs/foo` (a slash-containing name), all cloned from MSRC.
_mksuper() {
    local sup="${1}"
    _mkrepo "${sup}"
    git_q -C "${sup}" submodule add "${MSRC}" sub
    git_q -C "${sup}" submodule add "${MSRC}" libs/foo
    git_q -C "${sup}/sub" submodule add "${MSRC}" inner
    git_q -C "${sup}/sub" commit -m add-inner
    git_q -C "${sup}" add -A
    git_q -C "${sup}" commit -m add-modules
}
_mksuper "${EXT}/msup"
MSG="${EXT}/msup/.git"
MSD="${MSG}/modules/sub"
ok=0
[[ -f "${EXT}/msup/sub/.git" && -f "${MSD}/HEAD" && -f "${MSD}/modules/inner/HEAD" && -f "${MSG}/modules/libs/foo/HEAD" ]] && ok=1
assert_eq "${ok}" "1" "sanity: superproject fixture with sub, sub/inner and libs/foo"
assert_eq "$(git -C "${MSD}" config --file "${MSD}/config" --get core.worktree)" "../../../sub" "sanity: git records core.worktree for the submodule"
_mksuper "${FAKE_HOME}/repos/hsup"
_mksuper "${FAKE_HOME}/.local/share/chez"
LSG="${FAKE_HOME}/.local/share/chez/.git"
for case in "${EXT}/msup/sub|${MSD}|outside \$HOME" "${EXT}/msup/libs/foo|${MSG}/modules/libs/foo|slash-named" \
        "${EXT}/msup/sub/inner|${MSD}/modules/inner|nested" \
        "${FAKE_HOME}/repos/hsup/sub|${FAKE_HOME}/repos/hsup/.git/modules/sub|\$HOME superproject" \
        "${FAKE_HOME}/.local/share/chez/sub|${LSG}/modules/sub|~/.local/share/<repo>" \
        "${FAKE_HOME}/.local/share/chez/sub/inner|${LSG}/modules/sub/modules/inner|~/.local/share/<repo>, nested" \
        "${FAKE_HOME}/.local/share/chez/libs/foo|${LSG}/modules/libs/foo|~/.local/share/<repo>, slash-named"; do
    IFS='|' read -r dir gd label <<<"${case}"
    out="$(_gitbind "${dir}")"
    _assert_rw_only "${out}" "submodule checkout, ${label}" "${gd}"
done
out="$(_gitbind "${EXT}/msup/sub")"
assert_not_contains "$(_grants "${out}")" "${MSG} " "submodule checkout: superproject .git not granted"
assert_not_contains "${out}" "${MSG}/modules/libs" "submodule checkout: sibling submodule git dir not granted"
assert_not_contains "$(_grants "${out}")" "${EXT}/msup " "submodule checkout: superproject root not granted"
mkdir -p "${EXT}/msup/sub/deeper/dir"
_assert_rw_only "$(_gitbind "${EXT}/msup/sub/deeper/dir")" "submodule checkout subdirectory" "${MSD}"
# Linked worktrees of a submodule: inside or outside the superproject.
git_q -C "${EXT}/msup/sub" worktree add "${EXT}/msup/.worktrees/subwt" -b subwt
git_q -C "${EXT}/msup/sub" worktree add "${EXT}/subwt-out" -b subwt-out
git_q -C "${FAKE_HOME}/.local/share/chez/sub" worktree add "${FAKE_HOME}/repos/chez-wt" -b chez-wt
_assert_rw_only "$(_gitbind "${EXT}/msup/.worktrees/subwt")" "submodule worktree inside the superproject" "${MSD}"
_assert_rw_only "$(_gitbind "${EXT}/subwt-out")" "submodule worktree outside the superproject" "${MSD}"
_assert_rw_only "$(_gitbind "${FAKE_HOME}/repos/chez-wt")" "\$HOME/.local/share/<repo> submodule worktree" "${LSG}/modules/sub"
# The submodule checkout moved out of its superproject: the links still
# name each other, which is what counts.
mv "${EXT}/msup/libs/foo" "${EXT}/moved-foo"
git config --file "${MSG}/modules/libs/foo/config" core.worktree "${EXT}/moved-foo"
printf 'gitdir: %s\n' "${MSG}/modules/libs/foo" >"${EXT}/moved-foo/.git"
_assert_rw_only "$(_gitbind "${EXT}/moved-foo")" "submodule checkout outside its superproject, links verified" "${MSG}/modules/libs/foo"
mv "${EXT}/moved-foo" "${EXT}/msup/libs/foo"
git config --file "${MSG}/modules/libs/foo/config" core.worktree ../../../../libs/foo
printf 'gitdir: ../../.git/modules/libs/foo\n' >"${EXT}/msup/libs/foo/.git"
_assert_rw_only "$(_gitbind "${EXT}/msup/libs/foo")" "sanity: libs/foo restored" "${MSG}/modules/libs/foo"

# Simulated macOS flag shape: stat()-only grants on the git dir's and
# WORKDIR's ancestors outside $HOME, no content grant on them.
out="$(_gitbind "${EXT}/wt" "_wrapper_os=Darwin")"
assert_contains "${out}" "--under-bind${NL}${MG}${NL}" "simulated macOS: shared .git bound read-write (--under-bind)"
for p in "${EXT}/main" "${EXT}" "${EXT%/*}"; do
    assert_contains "${out}" "--meta-bind${NL}${p}${NL}" "simulated macOS: metadata-only grant on ${p}"
done
assert_eq "$(_grants "${out}")" "${MG} " "simulated macOS: no other content grant"
out="$(_gitbind "${EXT}/msup/sub" "_wrapper_os=Darwin")"
for p in "${MSG}/modules" "${MSG}" "${EXT}/msup" "${EXT}"; do
    assert_contains "${out}" "--meta-bind${NL}${p}${NL}" "simulated macOS, submodule: metadata-only grant on ${p}"
done
assert_eq "$(_grants "${out}")" "${MSD} " "simulated macOS, submodule: only the module git dir granted"
out="$(_gitbind "${FAKE_HOME}/repos/home-main/.worktrees/hin" "_wrapper_os=Darwin")"
assert_not_contains "${out}" "--meta-bind${NL}${EXT}" "simulated macOS: HOME worktree gets no external grants"
out="$(_gitbind "${EXT}/wt" "_wrapper_os=Linux")"
assert_not_contains "${out}" "--meta-bind" "Linux: no metadata-only flags"

# ---------------------------------------------------------------------------
echo "-- pointer sanity: refusals"
# Borrowed entry: a checkout's .git points at EXT/wt's existing entry.
for evil in "${EXT}/evil" "${FAKE_HOME}/repos/evil" "${EXT}/main/.worktrees/evil"; do
    mkdir -p "${evil}"
    printf 'gitdir: %s\n' "${MG}/worktrees/wt" >"${evil}/.git"
    _assert_refused "$(_gitbind "${evil}")" "borrowed entry from ${evil#"${EXT%/*}/"}" "belongs to ${EXT}/wt/.git"
done
# Forged backlink: the entry's gitdir replaced by a symlink naming the
# checkout, or naming another checkout.
git_q -C "${EXT}/main" worktree add "${EXT}/wt3" -b wt3
printf '%s\n' "${EXT}/wt3/.git" >"${EXT}/forged-gitdir"
rm -f "${MG}/worktrees/wt3/gitdir"; ln -s "${EXT}/forged-gitdir" "${MG}/worktrees/wt3/gitdir"
_assert_refused "$(_gitbind "${EXT}/wt3")" "symlinked backlink" "belongs to unknown"
rm -f "${MG}/worktrees/wt3/gitdir"; printf '%s\n' "${EXT}/wt/.git" >"${MG}/worktrees/wt3/gitdir"
_assert_refused "$(_gitbind "${EXT}/wt3")" "backlink naming another checkout" "belongs to ${EXT}/wt/.git"
git_q -C "${EXT}/main" worktree remove --force "${EXT}/wt3"; rm -rf "${EXT}/wt3" "${MG}/worktrees/wt3"
# Crafted commondir at a git-shaped non-repo dir, at a sibling repo's .git.
_crafted_repo() {
    local wd="${1}" target="${2}"
    rm -rf "${wd}"; mkdir -p "${wd}/.g/wt"
    echo 'ref: refs/heads/main' >"${wd}/.g/wt/HEAD"
    printf '%s\n' "${target}" >"${wd}/.g/wt/commondir"
    printf 'gitdir: %s\n' "${wd}/.g/wt" >"${wd}/.git"
}
_fake_gitdir "${EXT}/notrepo"
_crafted_repo "${FAKE_HOME}/repos/crafted" "${EXT}/notrepo"
_assert_refused "$(_gitbind "${FAKE_HOME}/repos/crafted")" "crafted commondir -> git-shaped external dir" "is not a worktree of it"
_crafted_repo "${FAKE_HOME}/repos/crafted" "${EXT}/sibling/.git"
_assert_refused "$(_gitbind "${FAKE_HOME}/repos/crafted")" "crafted commondir -> sibling repo's .git" "is not a worktree of it"
# No location list (B-rho): real repositories in the system temp dir, a
# credential dir or a dotfile tree verify by their links and are bound; a
# crafted pointer at a client profile fails the links however it is
# shaped.
_mkrepo "${SCRATCH}/main"
git_q -C "${SCRATCH}/main" worktree add "${EXT}/tmpwt" -b tmpwt
_assert_rw_only "$(_gitbind "${EXT}/tmpwt")" "worktree of a repo in the system temp dir (${SCRATCH%/*})" "${SCRATCH}/main/.git"
_mkrepo "${FAKE_HOME}/.password-store"
git_q -C "${FAKE_HOME}/.password-store" worktree add "${FAKE_HOME}/repos/pw" -b pw
_assert_rw_only "$(_gitbind "${FAKE_HOME}/repos/pw")" "worktree of ~/.password-store" "${FAKE_HOME}/.password-store/.git"
_fake_gitdir "${FAKE_HOME}/.claude"
_crafted_repo "${FAKE_HOME}/repos/crafted" "${FAKE_HOME}/.claude"
_assert_refused "$(_gitbind "${FAKE_HOME}/repos/crafted")" "crafted commondir -> client profile ~/.claude" "is not a worktree of it"
rm -rf "${FAKE_HOME}/.claude"
_mksuper "${FAKE_HOME}/.config/gh/dsup"
_assert_rw_only "$(_gitbind "${FAKE_HOME}/.config/gh/dsup/sub")" "submodule of a superproject in ~/.config/gh" "${FAKE_HOME}/.config/gh/dsup/.git/modules/sub"
_mksuper "${SCRATCH}/tsup"
_assert_rw_only "$(_gitbind "${SCRATCH}/tsup/sub")" "submodule of a superproject in the system temp dir" "${SCRATCH}/tsup/.git/modules/sub"
# Submodule gitfiles from a directory that is not the checkout
# core.worktree names (outside the superproject, or elsewhere inside it).
for evil in "${EXT}/foreign" "${FAKE_HOME}/repos/foreign" "${EXT}/msup/vendor/evil"; do
    mkdir -p "${evil}"
    printf 'gitdir: %s\n' "${MSD}" >"${evil}/.git"
    _assert_refused "$(_gitbind "${evil}")" "gitfile -> ${MSD#"${EXT}/"} from ${evil#"${EXT%/*}/"}" "is not inside the submodule checkout ${EXT}/msup/sub"
done
# core.worktree: pointing elsewhere, at the superproject root (whose .git
# is no gitfile), or unset.
cp "${MSD}/config" "${SCRATCH}/msd-config.saved"
git -C "${MSD}" config --file "${MSD}/config" core.worktree ../../../libs/foo
_assert_refused "$(_gitbind "${EXT}/msup/sub")" "core.worktree naming another checkout" "core.worktree"
git -C "${MSD}" config --file "${MSD}/config" core.worktree ../../..
_assert_refused "$(_gitbind "${EXT}/msup/sub")" "core.worktree naming the superproject root" "${EXT}/msup/.git is not a gitfile"
git -C "${MSD}" config --file "${MSD}/config" --unset core.worktree
_assert_refused "$(_gitbind "${EXT}/msup/sub")" "core.worktree unset" "core.worktree is not set"
cp "${SCRATCH}/msd-config.saved" "${MSD}/config"
_assert_rw_only "$(_gitbind "${EXT}/msup/sub")" "core.worktree restored" "${MSD}"
# The checkout's .git must be a regular gitfile, not a symlink.
mkdir -p "${EXT}/msup/symco"
printf 'gitdir: %s\n' "${MSD}" >"${EXT}/msup/symco/.gitfile"
ln -s .gitfile "${EXT}/msup/symco/.git"
git -C "${MSD}" config --file "${MSD}/config" core.worktree ../../../symco
_assert_refused "$(_gitbind "${EXT}/msup/symco")" "submodule checkout with a symlinked .git" "${EXT}/msup/symco/.git is not a gitfile"
cp "${SCRATCH}/msd-config.saved" "${MSD}/config"
rm -rf "${EXT}/msup/symco"
# Validator units: symlinks in the layout (the binder only passes resolved
# paths), git dirs that are not git's module layout.
_modok() { ( _load; _wrapper_git_common_dir_ok "${1}" "${FAKE_HOME}" "${EXT}/msup/sub" ) 2>&1; echo "|rc=$?"; }
mkdir -p "${EXT}/lsup"; ln -s "${MSG}" "${EXT}/lsup/.git"
assert_contains "$(_modok "${EXT}/lsup/.git/modules/sub")" "not a verified submodule git dir" "symlinked <super>/.git: rejected"
ln -s sub "${MSG}/modules/symsub"
assert_contains "$(_modok "${MSG}/modules/symsub")" "not a resolved directory" "symlinked submodule git dir: rejected"
ln -s libs "${MSG}/modules/libsl"
assert_contains "$(_modok "${MSG}/modules/libsl/foo")" "not a verified submodule git dir" "symlinked namespace on the way to the git dir: rejected"
rm -f "${MSG}/modules/symsub" "${MSG}/modules/libsl"
_fake_gitdir "${MSD}/objects/fake"
assert_contains "$(_modok "${MSD}/objects/fake")" "not a verified submodule git dir" "git-shaped dir below a module's objects/: rejected"
assert_contains "$(_modok "${MSG}/modules/libs")" "not a verified submodule git dir" "namespace parent as the git dir: rejected"
_fake_gitdir "${MSG}/modules/.hid"
assert_contains "$(_modok "${MSG}/modules/.hid")" "not a verified submodule git dir" "hidden module name: rejected"
rm -rf "${MSD}/objects/fake" "${MSG}/modules/.hid"
out="$(_modok "${MSD}")"
assert_contains "${out}" "|rc=0" "validator: the real submodule git dir passes"

# ---------------------------------------------------------------------------
echo "-- agent profile and state directories: not refused (owner-accepted exception)"
# docs/owner-accepted-exceptions.md: a git dir in a client profile is bound
# read-write like any other once it passes the link checks. A hand-planted
# pair (git-shaped dir with a worktree entry naming CHECKOUT, and
# CHECKOUT's gitfile naming that entry) in ~/.claude passes them.
_fake_gitdir "${FAKE_HOME}/.claude/planted"
mkdir -p "${FAKE_HOME}/.claude/planted/worktrees/w" "${FAKE_HOME}/repos/planted"
echo 'ref: refs/heads/main' >"${FAKE_HOME}/.claude/planted/worktrees/w/HEAD"
echo '../..' >"${FAKE_HOME}/.claude/planted/worktrees/w/commondir"
printf '%s\n' "${FAKE_HOME}/repos/planted/.git" >"${FAKE_HOME}/.claude/planted/worktrees/w/gitdir"
printf 'gitdir: %s\n' "${FAKE_HOME}/.claude/planted/worktrees/w" >"${FAKE_HOME}/repos/planted/.git"
_assert_rw_only "$(_gitbind "${FAKE_HOME}/repos/planted")" "planted pair in ~/.claude: bound read-write (accepted exception)" \
    "${FAKE_HOME}/.claude/planted"
rm -rf "${FAKE_HOME}/.claude" "${FAKE_HOME}/repos/planted"

# ---------------------------------------------------------------------------
echo "-- bind order: read-only overlays stay on top of the git dir"
# Two read-only extra dirs (AI_SANDBOX_EXTRA_RO_DIRS) for the same check:
# A) one inside a repository's git dir, so the git dir contains it; B) one
# holding a repository, so the git dir sits under it. Either way the git
# bind must come first (bwrap: the later mount wins).
DOTS="${FAKE_HOME}/repos/dots"
DOTSG="${DOTS}/.git"
ROT="${FAKE_HOME}/repos/rotree"
SKG="${ROT}/sk/.git"
_mkrepo "${DOTS}"
git_q -C "${DOTS}" worktree add "${FAKE_HOME}/repos/dots-wt" -b dots-wt
# Sets CTL_RO, the read-only extra dir of the case.
_ctl_case() {
    rm -rf "${DOTSG}/ro-inside" "${ROT}"
    case "${1}" in
        A)  mkdir -p "${DOTSG}/ro-inside/sub"
            echo 'keep' >"${DOTSG}/ro-inside/file"
            CTL_RO="${DOTSG}/ro-inside" ;;
        B)  _mkrepo "${ROT}/sk"
            git_q -C "${ROT}/sk" worktree add "${FAKE_HOME}/repos/sk-wt-${2:-1}" -b "sk-wt-${2:-1}"
            CTL_RO="${ROT}" ;;
    esac
}
# Line number of the first match of a 3-token sequence in an argv dump.
_seq_idx() { printf '%s\n' "${1}" | awk -v a="${2}" -v b="${3}" -v c="${4}" \
    '{ t[NR] = $0 } END { for (i = 1; i + 2 <= NR; i++) if (t[i] == a && t[i+1] == b && t[i+2] == c) { print i; exit } }'; }
# Line numbers of every --ro-bind whose source is under the fake HOME or
# the external fixtures, and of every self-bind pin of the profile.
_ro_idxs() { printf '%s\n' "${1}" | awk -v h="${FAKE_HOME}" -v e="${EXT}" \
    'prev == "--ro-bind" && (index($0, h "/") == 1 || index($0, e "/") == 1) { print NR - 1 } { prev = $0 }'; }
# argv order check: GIT_IDX before every index on stdin.
_all_after() { local idx="${1}" n bad=0; while read -r n; do (( n > idx )) || bad=1; done; echo "${bad}"; }

# Wrapper flags (any OS, Linux shape): the git dir is an --under-bind.
_ctl_case A
out="$( cd "${FAKE_HOME}/repos/dots-wt" && _load && _wrapper_os=Linux && WRAPPER_FLAGS=() && _bind_codex_account \
    && _apply_post_menu_binds && printf '%s\n' "${WRAPPER_FLAGS[@]}" END ) 2>&1"
assert_contains "${out}" "--under-bind${NL}${DOTSG}${NL}${DOTSG}${NL}" "case A flags: git dir is an --under-bind"
assert_not_contains "${out}" "WARN" "case A flags: no WARN (no location refusal)"

if [[ "${OS}" == "Linux" ]]; then
    STUB_DIR="${SCRATCH}/stub-bwrap"
    ARGV_FILE="${STUB_DIR}/argv"
    FDLINKS="${STUB_DIR}/fdlinks"
    mkdir -p "${STUB_DIR}"
    # Stub bwrap: --help advertises --bind-fd only when STUB_BWRAP_BIND_FD
    # is set; a launch records its argv and what each --bind-fd names.
    cat >"${STUB_DIR}/bwrap" <<STUB
#!/bin/bash
if [[ "\${1:-}" == "--help" ]]; then
    echo "usage: bwrap [OPTIONS...] [--] COMMAND [ARGS...]"
    [[ -n "\${STUB_BWRAP_BIND_FD:-}" ]] && echo "    --bind-fd FD DEST            Bind open directory or path fd on DEST"
    exit 0
fi
printf '%s\n' "\$@" >"${ARGV_FILE}"
: >"${FDLINKS}"
prev=""
for a in "\$@"; do
    [[ "\${prev}" == "--bind-fd" ]] && readlink "/proc/self/fd/\${a}" >>"${FDLINKS}"
    prev="\${a}"
done
exit 0
STUB
    chmod +x "${STUB_DIR}/bwrap"
    # The real codex wrapper, non-interactive, through the stub. The
    # terminal filter and the egress proxy are off: they do not change
    # the bind list, and this layer must not depend on libseccomp.
    _stub_launch() {
        local dir="${1}"; shift
        rm -f "${ARGV_FILE}" "${FDLINKS}"
        out="$( cd "${dir}" && env PATH="${STUB_DIR}:${FAKE_HOME}/bin:${PATH}" AI_SANDBOX_ALLOW_TIOCSTI=1 \
            AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1 "$@" bash "${REPO_ROOT}/bin/executable_codex_wrapper.bash" x </dev/null 2>&1 )"
        rc=$?
        argv="$(cat "${ARGV_FILE}" 2>/dev/null)"
        fdlinks="$(cat "${FDLINKS}" 2>/dev/null)"
    }
    for ctl in A B; do
        _ctl_case "${ctl}" order
        if [[ "${ctl}" == "A" ]]; then wd="${FAKE_HOME}/repos/dots-wt"; gd="${DOTSG}"; else wd="${FAKE_HOME}/repos/sk-wt-order"; gd="${SKG}"; fi
        # Descriptor bind.
        _stub_launch "${wd}" STUB_BWRAP_BIND_FD=1 AI_SANDBOX_EXTRA_RO_DIRS="${CTL_RO}"
        assert_eq "${rc}" "0" "case ${ctl} argv (--bind-fd): launch reaches bwrap"
        fd_idx="$(printf '%s\n' "${argv}" | grep -nxF -- --bind-fd | head -1 | cut -d: -f1)"
        assert_eq "$(printf '%s\n' "${argv}" | grep -cxF -- --bind-fd)" "1" "case ${ctl} argv: one --bind-fd"
        assert_eq "${fdlinks}" "${gd}" "case ${ctl} argv: the descriptor names exactly the checked git dir"
        assert_eq "$(printf '%s\n' "${argv}" | sed -n "$(( ${fd_idx:-0} + 2 ))p")" "${gd}" "case ${ctl} argv: ... mounted at the git dir's path"
        assert_eq "$(_seq_idx "${argv}" --bind "${gd}" "${gd}")" "" "case ${ctl} argv: no path bind of the git dir"
        ro="$(_ro_idxs "${argv}")"
        assert_eq "$([[ -n "${ro}" ]] && echo yes)" "yes" "case ${ctl} argv: read-only overlays present"
        assert_eq "$(printf '%s\n' "${ro}" | _all_after "${fd_idx:-999999}")" "0" "case ${ctl} argv: git dir mounted before every read-only overlay"
        assert_not_contains "${out}" "git won't work" "case ${ctl} argv: no git refusal"
        # Path fallback (bwrap without --bind-fd).
        _stub_launch "${wd}" AI_SANDBOX_EXTRA_RO_DIRS="${CTL_RO}"
        idx="$(_seq_idx "${argv}" --bind "${gd}" "${gd}")"
        assert_eq "$([[ -n "${idx}" ]] && echo yes)" "yes" "case ${ctl} argv (no --bind-fd): git dir bound by path"
        assert_eq "$(printf '%s\n' "$(_ro_idxs "${argv}")" | _all_after "${idx:-999999}")" "0" "case ${ctl} argv (no --bind-fd): ... before every read-only overlay"
        assert_contains "${out}" "has no --bind-fd" "case ${ctl} argv (no --bind-fd): INFO names the residual"
        assert_not_contains "${argv}" "--bind-fd" "case ${ctl} argv (no --bind-fd): no descriptor flag"
    done
    _ctl_case A
    _stub_launch "${FAKE_HOME}/repos/dots-wt" STUB_BWRAP_BIND_FD=1 AI_SANDBOX_EXTRA_RO_DIRS="${CTL_RO}"
    assert_eq "$([[ -n "$(_seq_idx "${argv}" --ro-bind "${DOTSG}/ro-inside" "${DOTSG}/ro-inside")" ]] && echo yes)" \
        "yes" "case A argv: the read-only dir inside the git dir is overlaid read-only"

    echo "-- descriptor bind: a path swapped after the check is not bound (#14)"
    mkdir -p "${SCRATCH}/swap/real"
    ln -s "${SCRATCH}/swap/real" "${SCRATCH}/swap/now-a-link"
    _backend_run() {
        rm -f "${ARGV_FILE}" "${FDLINKS}"
        out="$( cd "${FAKE_HOME}/norepo" && export PATH="${STUB_DIR}:${PATH}" AI_SANDBOX_ALLOW_TIOCSTI=1 \
            AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1 STUB_BWRAP_BIND_FD=1 && _load \
            && _run_sandboxed_agent_linux true -- "$@" -- 2>&1 >/dev/null )"; rc=$?
        argv="$(cat "${ARGV_FILE}" 2>/dev/null)"
        fdlinks="$(cat "${FDLINKS}" 2>/dev/null)"
    }
    _backend_run --under-bind "${SCRATCH}/swap/now-a-link" "${SCRATCH}/swap/now-a-link"
    assert_eq "${rc}" "0" "swapped to a symlink: launch continues"
    assert_contains "${out}" "Not binding ${SCRATCH}/swap/now-a-link: it changed after it was checked" "swapped to a symlink: WARN"
    assert_eq "${fdlinks}" "" "swapped to a symlink: no descriptor bound"
    assert_not_contains "${argv}" "${SCRATCH}/swap" "swapped to a symlink: neither path nor target in the argv"
    _backend_run --under-bind "${SCRATCH}/swap/real" "${SCRATCH}/swap/real"
    assert_eq "${fdlinks}" "${SCRATCH}/swap/real" "unchanged directory: bound by descriptor"
    assert_not_contains "${out}" "Not binding" "unchanged directory: no WARN"
    _backend_run --under-bind "${SCRATCH}/swap/gone" "${SCRATCH}/swap/gone"
    assert_eq "${rc}:${fdlinks}" "0:" "missing under-bind source: skipped, launch continues"
    rm -rf "${SCRATCH}/swap"
else
    echo "  skip - bwrap argv and descriptor checks are Linux-only (Seatbelt rendering: tests/test_macos_ro_overlays.bash)"
fi
rm -rf "${FAKE_HOME}/.codex"

# ---------------------------------------------------------------------------
echo "-- retired settings in a saved preset"
P="${FAKE_HOME}/preset-wd"
mkdir -p "${P}"
_in_preset() { ( cd "${P}" && _load && eval "${1}" ) 2>&1; }
catalog="$( _load; printf '%s\n' "${_AI_SETTINGS_LIST[@]}" )"
for setting in ${RETIRED}; do
    assert_not_contains "${catalog}" "${setting}|" "catalog: ${setting} retired"
done
saved="$(_in_preset "_preset_autosave 2>/dev/null; cat \"\$(_preset_autosave_path)\"")"
assert_contains "${saved}" "AI_SANDBOX_DEBUG=" "autosave: catalog settings written"
for setting in ${RETIRED}; do
    assert_not_contains "${saved}" "${setting}" "autosave: retired ${setting} never written"
done
preset_file="$(_in_preset '_preset_autosave_path')"
printf 'AI_SANDBOX_ALLOW_GIT_CONFIG=0\nAI_SANDBOX_ALLOW_EXTERNAL_WORKTREES=1\nAI_SANDBOX_BLOCK_LINKED_GIT_DIRS=1\nAI_SANDBOX_DEBUG=1\n' >"${preset_file}"
out="$(_in_preset "unset ${RETIRED} AI_SANDBOX_DEBUG; _preset_autoload; for k in ${RETIRED}; do echo \"\${k}=\${!k:-unset}\"; done; echo \"DEBUG=\${AI_SANDBOX_DEBUG:-unset}\"")"
for setting in ${RETIRED}; do
    assert_contains "${out}" "${setting}=unset" "autoload: retired ${setting} not exported"
done
assert_contains "${out}" "DEBUG=1" "autoload: other saved settings still restored"
assert_contains "${out}" "Ignoring retired setting AI_SANDBOX_BLOCK_LINKED_GIT_DIRS=1" "autoload: saved non-default retired value: one NOTE"
assert_contains "${out}" "Ignoring retired setting AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES=1" "autoload: ... for each such key"
assert_not_contains "${out}" "AI_SANDBOX_ALLOW_GIT_CONFIG=0" "autoload: saved old default (0): silent"
assert_eq "$(printf '%s\n' "${out}" | grep -c 'retired setting')" "2" "autoload: exactly one NOTE per non-default retired key"
assert_not_contains "${out}" "Restored" "autoload: retired keys produce no restore WARN"
out="$(_in_preset "unset ${RETIRED} AI_SANDBOX_DEBUG; _preset_autoload >/dev/null 2>&1; _preset_autosave 2>/dev/null; cat \"\$(_preset_autosave_path)\"")"
for setting in ${RETIRED}; do
    assert_not_contains "${out}" "${setting}" "autosave after loading a stale preset drops ${setting}"
done
rm -f "${preset_file}"

# ---------------------------------------------------------------------------
# Native enforcement through the codex wrapper.
sandbox_e2e=0
if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    sandbox_e2e=1
elif [[ "${OS}" == "Darwin" ]]; then
    if command -v sandbox-exec >/dev/null 2>&1; then
        sandbox_e2e=1
    else
        _test_report 0 "e2e git dirs: sandbox-exec available on macOS"
    fi
else
    echo "  skip - e2e git dirs: no bwrap (Linux) / sandbox-exec (macOS) on this host"
fi
stub_ro_dirs=""
[[ "${OS}" == "Darwin" ]] && stub_ro_dirs="${FAKE_HOME}/bin"

# Probe client: proves discovery of exactly the expected git dir before any
# write (SETUP_FAILED + exit 3 otherwise), then commits and writes config,
# a hook and commondir-adjacent metadata, and tries files next to the git
# dir (EXTRA_READ / EXTRA_WRITE, which must stay unreachable).
_write_probe_stub() {
    {
        printf '#!/bin/bash\nexpect_gd=%q\nextra_read=%q\nextra_write=%q\n' "${1}" "${2}" "${3}"
        cat <<'STUB'
setup_failed() { echo "SETUP_FAILED: $*"; exit 3; }
gd="$(git rev-parse --git-common-dir 2>&1)" || setup_failed "git rev-parse --git-common-dir: ${gd}"
gd="$(cd "${gd}" 2>&1 && pwd -P)" || setup_failed "cannot enter git dir: ${gd}"
[[ "${gd}" == "${expect_gd}" ]] || setup_failed "discovered '${gd}', expected '${expect_gd}'"
[[ -f "${gd}/config" && -d "${gd}/objects" ]] || setup_failed "missing ${gd}/config or objects/"
echo DISCOVERY_OK
g() { git -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
echo "$$-${RANDOM}" >probe-file && g add probe-file && g commit -m sandboxed && echo COMMIT_OK
g branch e2e-side && echo BRANCH_OK
g branch -D e2e-side && echo BRANCH_DELETE_OK
g config --local aiw.e2e yes && echo CONFIG_OK
(printf '#!/bin/sh\nexit 0\n' >"${gd}/hooks/post-checkout") 2>/dev/null && echo HOOK_OK
(: >"${gd}/info/aiw-e2e") 2>/dev/null && echo INFO_OK
if [[ -n "${extra_read}" ]]; then
    if cat "${extra_read}" >/dev/null 2>&1; then echo READ:extra; else echo NOREAD:extra; fi
    if (echo evil >>"${extra_write}") 2>/dev/null; then echo WROTE:extra; else echo DENIED:extra; fi
fi
echo PROBES_DONE
STUB
    } >"${FAKE_HOME}/bin/codex"
    chmod +x "${FAKE_HOME}/bin/codex"
}
_launch_at() {
    local dir="${1}"; shift
    ( cd "${dir}" && env PATH="${FAKE_HOME}/bin:${PATH}" AI_SANDBOX_EXTRA_RO_DIRS="${stub_ro_dirs}" "$@" \
        bash "${REPO_ROOT}/bin/executable_codex_wrapper.bash" x </dev/null 2>&1 )
}

# Negative control (unconfined): the stub refuses a wrong repository.
mkdir -p "${FAKE_HOME}/bin"
_write_probe_stub "${MG}" "" ""
out="$(cd "${FAKE_HOME}/repos/home-wt" && bash "${FAKE_HOME}/bin/codex" 2>&1)"; rc=$?
assert_eq "${rc}" "3" "probe stub: discovery of another repo exits 3"
assert_contains "${out}" "SETUP_FAILED: discovered" "probe stub: wrong repo reported"
assert_not_contains "${out}" "COMMIT_OK" "probe stub: wrong repo runs no git write"

if [[ "${sandbox_e2e}" == "1" ]]; then
    mkdir -p "${MG}/info" "${MSD}/info" "${HMG}/info"
    # label|launch dir|git dir|extra file next to the git dir (or "")
    for case in "plain repository|${FAKE_HOME}/repos/home-main|${HMG}|" \
            "worktree outside its root|${EXT}/wt|${MG}|${EXT}/canary.txt" \
            "submodule checkout|${EXT}/msup/sub|${MSD}|${MSG}/config"; do
        IFS='|' read -r label dir gd extra <<<"${case}"
        extra_before="$([[ -n "${extra}" ]] && cksum <"${extra}")"
        _write_probe_stub "${gd}" "${extra}" "${extra}"
        out="$(_launch_at "${dir}")"; rc=$?
        echo "  (e2e ${label} output: ${out})"
        assert_eq "${rc}" "0" "e2e ${label}: probe client exits 0"
        assert_contains "${out}" "DISCOVERY_OK" "e2e ${label}: probe found the git dir"
        for ok in COMMIT_OK BRANCH_OK BRANCH_DELETE_OK CONFIG_OK HOOK_OK INFO_OK PROBES_DONE; do
            assert_contains "${out}" "${ok}" "e2e ${label}: ${ok}"
        done
        assert_not_contains "${out}" "git won't work" "e2e ${label}: no git refusal at launch"
        assert_eq "$(git -C "${dir}" log --format=%s -1)" "sandboxed" "e2e ${label}: commit persisted on the host"
        assert_eq "$(git --git-dir="${gd}" config --get aiw.e2e)" "yes" "e2e ${label}: config change persisted on the host"
        ok=0; [[ -f "${gd}/hooks/post-checkout" && -f "${gd}/info/aiw-e2e" ]] && ok=1
        assert_eq "${ok}" "1" "e2e ${label}: hook and info/ file persisted on the host"
        if [[ -n "${extra}" ]]; then
            assert_contains "${out}" "NOREAD:extra" "e2e ${label}: ${extra#"${EXT}/"} next to the git dir not readable"
            [[ "${OS}" == "Darwin" ]] && assert_contains "${out}" "DENIED:extra" "e2e ${label}: ... and not writable"
            assert_eq "$(cksum <"${extra}")" "${extra_before}" "e2e ${label}: ... bytes unchanged on the host"
        fi
        git --git-dir="${gd}" config --unset aiw.e2e
        rm -f "${gd}/hooks/post-checkout" "${gd}/info/aiw-e2e"
    done

    # A refused pointer (a borrowed worktree entry): the launch continues,
    # git just does not work.
    _write_probe_stub "${MG}" "" ""
    out="$(_launch_at "${FAKE_HOME}/repos/evil")"; rc=$?
    echo "  (e2e refused pointer output: ${out})"
    assert_eq "${rc}" "3" "e2e refused pointer: git fails inside the sandbox (probe stops at discovery)"
    assert_contains "${out}" "git won't work in this checkout because" "e2e refused pointer: host WARN"
    assert_not_contains "${out}" "COMMIT_OK" "e2e refused pointer: no git write"

    # Read-only overlays stay read-only whatever the git dir's position:
    # A) a read-only extra dir inside the git dir, B) the git dir inside a
    # read-only extra dir.
    _write_ctl_stub() {
        {
            printf '#!/bin/bash\ntargets=('
            printf '%q ' "$@"
            printf ')\n'
            cat <<'STUB'
for f in "${targets[@]}"; do (echo probe >>"${f}") 2>/dev/null && echo "WROTE:${f}" || echo "DENIED:${f}"; done
git log --format=%s -1 >/dev/null 2>&1 && echo LOG_OK
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m sandboxed-ctl >/dev/null 2>&1 && echo COMMIT_OK
echo PROBES_DONE
STUB
        } >"${FAKE_HOME}/bin/codex"
        chmod +x "${FAKE_HOME}/bin/codex"
    }
    _ctl_case A
    mkdir -p "${DOTSG}/info"
    ctl_before="$(cksum <"${DOTSG}/ro-inside/file")"
    _write_ctl_stub "${DOTSG}/ro-inside/file" "${DOTSG}/ro-inside/sub/planted" "${DOTSG}/info/aiw-ctl"
    out="$(_launch_at "${FAKE_HOME}/repos/dots-wt" AI_SANDBOX_EXTRA_RO_DIRS="${stub_ro_dirs:+${stub_ro_dirs},}${CTL_RO}")"; rc=$?
    echo "  (e2e read-only dir inside the git dir output: ${out})"
    assert_contains "${out}" "PROBES_DONE" "e2e read-only dir inside the git dir: probe ran"
    assert_contains "${out}" "DENIED:${DOTSG}/ro-inside/file" "e2e read-only dir inside the git dir: its file stays read-only"
    assert_contains "${out}" "DENIED:${DOTSG}/ro-inside/sub/planted" "e2e read-only dir inside the git dir: nothing can be created in it"
    assert_contains "${out}" "WROTE:${DOTSG}/info/aiw-ctl" "e2e read-only dir inside the git dir: rest of the git dir writable"
    assert_contains "${out}" "COMMIT_OK" "e2e read-only dir inside the git dir: git commit works"
    assert_eq "$(cksum <"${DOTSG}/ro-inside/file")" "${ctl_before}" "e2e read-only dir inside the git dir: file bytes unchanged on the host"
    ok=0; [[ ! -e "${DOTSG}/ro-inside/sub/planted" ]] && ok=1
    assert_eq "${ok}" "1" "e2e read-only dir inside the git dir: nothing planted on the host"
    rm -f "${DOTSG}/info/aiw-ctl"

    _ctl_case B e2e
    mkdir -p "${SKG}/info"
    ctl_before="$(cksum <"${SKG}/config")"
    _write_ctl_stub "${SKG}/config" "${SKG}/info/aiw-ctl"
    out="$(_launch_at "${FAKE_HOME}/repos/sk-wt-e2e" AI_SANDBOX_EXTRA_RO_DIRS="${stub_ro_dirs:+${stub_ro_dirs},}${CTL_RO}")"; rc=$?
    echo "  (e2e git dir inside a read-only dir output: ${out})"
    assert_contains "${out}" "PROBES_DONE" "e2e git dir inside a read-only dir: probe ran"
    assert_contains "${out}" "DENIED:${SKG}/config" "e2e git dir inside a read-only dir: its config stays read-only"
    assert_contains "${out}" "DENIED:${SKG}/info/aiw-ctl" "e2e git dir inside a read-only dir: ... as does the rest of it"
    assert_not_contains "${out}" "COMMIT_OK" "e2e git dir inside a read-only dir: no git commit"
    assert_eq "$(cksum <"${SKG}/config")" "${ctl_before}" "e2e git dir inside a read-only dir: config bytes unchanged on the host"
    rm -rf "${ROT}" "${FAKE_HOME}/.codex"
fi

assert_no_live_client_reached
tests_summary_and_exit
