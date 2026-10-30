#!/bin/bash
# WORKDIR git metadata protection (issue #10): _wrapper_protect_workdir_git
# in bin/ai_wrapper_data/ai_wrapper_lib.bash.
#
# Layers:
#   1. bind lists for every layout (normal repo, linked .git file, bare
#      repo, repo subdirectory, non-repo, absent entries, symlink / type
#      validation, relaxed mode, indirection WARNs) — any OS, Linux and
#      Darwin flag shapes;
#   2. AI_SANDBOX_ALLOW_GIT_CONFIG catalog / preset / launch-override
#      precedence — any OS;
#   3. refusal propagation through every wrapper (claude, codex, agy,
#      copilot, cursor-agent): a symlinked hooks/ stops the launch before
#      the client runs — any OS, no sandbox needed;
#   4. native enforcement through the codex wrapper (bwrap on Linux,
#      sandbox-exec on macOS; a missing backend is a failure, not a skip):
#      commits/branches/checkouts persist, config/hook/pointer writes and
#      metadata-root moves are denied in protected mode, root integrity
#      holds in relaxed mode, absent entries stay creatable (accepted
#      residual), bare repos, scaffolding and AI_SANDBOX_EXTRA_RW_DIRS
#      covering WORKDIR; nested / slash-named submodule git dirs (#12):
#      their config and hooks, and moves of every directory on the chain
#      to them, denied while submodule commits persist.
# Every e2e probe client first proves it found the expected fixture and
# prints SETUP_FAILED (exit 3) otherwise, so a setup error can never pass
# as a denied write.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

# Under the real $HOME for the reason given in tests/test_sandbox_common.bash.
FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
isolate_test_env "${FAKE_HOME}"
cleanup() { rm -rf "${FAKE_HOME}"; }
trap cleanup EXIT
# Host-side discovery must not climb out of the fixture tree.
export GIT_CEILING_DIRECTORIES="${FAKE_HOME}"

OS="$(uname -s)"
NL=$'\n'
R="${FAKE_HOME}/repos"

_load() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=../bin/ai_wrapper_data/codex_wrapper_lib.bash
    source "${REPO_ROOT}/bin/ai_wrapper_data/codex_wrapper_lib.bash"
}

echo "== workdir git metadata protection tests (${OS}) =="

if ! command -v git >/dev/null 2>&1; then
    _test_report 0 "git is installed (needed for every fixture)"
    tests_summary_and_exit
fi
git_q() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
_new_repo() { rm -rf "${1}"; git_q init "${1}" && git_q -C "${1}" commit --allow-empty -m init; }

# Run the protection in DIR and print rc, WRAPPER_FLAGS and stderr. These
# are flag-shape snapshots, not native proof: OS (default Linux) is set
# after sourcing so the host backend never decides the shape; Darwin
# selects the single-arg macOS shape. Native enforcement is layer 4.
_protect() {
    local dir="${1}" os="${2:-Linux}"
    ( cd "${dir}" && _load && _wrapper_os="${os}" && WRAPPER_FLAGS=() \
        && { _wrapper_protect_workdir_git; rc=$?; printf 'rc=%s\n' "${rc}"; printf '%s\n' "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}"; } ) 2>&1
}
# Linux-shaped flag for PATH: "--ro-bind\nP\nP\n".
_lflag() { printf '%s\n%s\n%s\n' "${1}" "${2}" "${2}"; }

# ---------------------------------------------------------------------------
echo "-- normal repository"
N="${R}/normal"
_new_repo "${N}"
[[ -d "${N}/.git/hooks" ]] || mkdir "${N}/.git/hooks"
out="$(_protect "${N}")"
assert_contains "${out}" "rc=0" "normal repo: launch allowed"
assert_contains "${out}" "$(_lflag --bind "${N}/.git")" "normal repo (Linux): .git self-bound (pinned mount point)"
assert_contains "${out}" "$(_lflag --ro-bind "${N}/.git/config")" "normal repo: config read-only"
assert_contains "${out}" "$(_lflag --ro-bind "${N}/.git/hooks")" "normal repo: hooks/ read-only"
assert_contains "${out}" "absent at launch" "normal repo: absent commondir reported"
assert_contains "${out}" "${N}/.git/commondir" "... naming commondir"
absent_line="$(printf '%s\n' "${out}" | grep 'absent at launch' || true)"
assert_not_contains "${absent_line}" "hooks/" "... and not hooks/ (it exists)"
order="$(printf '%s\n' "${out}" | grep -n -x -e "${N}/.git" -e "${N}/.git/config" | awk -F: 'NR%2==1{print $2}' | tr '\n' ' ')"
assert_eq "${order}" "${N}/.git ${N}/.git/config " "normal repo (Linux): pin mounted before its read-only children"
assert_not_contains "${out}" "not in a git repository" "normal repo: not classified as a new repo"
created=0; [[ -e "${N}/.git/commondir" ]] && created=1
assert_eq "${created}" "0" "normal repo: nothing created on the host"

out="$(_protect "${N}" Darwin)"
assert_contains "${out}" "--pin${NL}${N}/.git${NL}" "normal repo (macOS): .git pinned with --pin"
assert_contains "${out}" "--ro-bind${NL}${N}/.git/config${NL}" "normal repo (macOS): config read-only"
assert_contains "${out}" "--ro-bind${NL}${N}/.git/hooks" "normal repo (macOS): hooks/ read-only"

echo "-- WORKDIR reached through a symlink"
# bwrap mounts WORKDIR at the logical cwd; the over-mounts must target the
# same logical paths (sources stay resolved).
ln -s "${R}" "${FAKE_HOME}/repos-link"
L="${FAKE_HOME}/repos-link/normal"
out="$(_protect "${L}")"
assert_contains "${out}" "--bind${NL}${N}/.git${NL}${L}/.git${NL}" "symlinked cwd (Linux): pin mounted at the logical path"
assert_contains "${out}" "--ro-bind${NL}${N}/.git/config${NL}${L}/.git/config${NL}" "symlinked cwd (Linux): config RO at the logical path"
assert_contains "${out}" "--ro-bind${NL}${N}/.git/hooks${NL}${L}/.git/hooks" "symlinked cwd (Linux): hooks/ RO at the logical path"
assert_contains "${out}" "--bind${NL}${N}/.git${NL}${N}/.git${NL}" "symlinked cwd (Linux): pin also at the resolved path"
assert_contains "${out}" "--ro-bind${NL}${N}/.git/config${NL}${N}/.git/config${NL}" "symlinked cwd (Linux): config also RO at the resolved path"
out="$(_protect "${L}" Darwin)"
assert_contains "${out}" "--ro-bind${NL}${N}/.git/config${NL}" "symlinked cwd (macOS): resolved path (backend uses pwd -P)"

echo "-- normal repository: extra entries"
mkdir -p "${N}/.git/modules/sub1/hooks"; : >"${N}/.git/modules/sub1/config"
: >"${N}/.git/config.worktree"
git_q -C "${N}" worktree add "${R}/normal-wt" -b normal-wt
out="$(_protect "${N}")"
assert_contains "${out}" "$(_lflag --ro-bind "${N}/.git/config.worktree")" "config.worktree read-only when present"
assert_contains "${out}" "$(_lflag --ro-bind "${N}/.git/worktrees")" "worktrees/ (other checkouts' pointers) read-only"
assert_contains "${out}" "$(_lflag --ro-bind "${N}/.git/modules/sub1/config")" "submodule config read-only"
assert_contains "${out}" "$(_lflag --ro-bind "${N}/.git/modules/sub1/hooks")" "submodule hooks/ read-only"
assert_contains "${out}" "submodule checkouts' .git pointer files" "submodule pointer residual WARNed"
printf '%s\n' "../../elsewhere/.git" >"${N}/.git/commondir"
# Module git dirs get the same pointer checks as the root (#12).
printf '%s\n' "../../elsewhere/.git" >"${N}/.git/modules/sub1/commondir"
out="$(_protect "${N}")"
assert_contains "${out}" "$(_lflag --ro-bind "${N}/.git/commondir")" "commondir read-only when present"
assert_contains "${out}" "$(_lflag --ro-bind "${N}/.git/modules/sub1/commondir")" "submodule commondir read-only when present"
assert_not_contains "${out}" "absent at launch" "nothing reported absent when every entry exists"
rm -f "${N}/.git/commondir" "${N}/.git/config.worktree"
rm -rf "${N}/.git/modules"
git_q -C "${N}" worktree remove --force "${R}/normal-wt"
rm -rf "${N}/.git/worktrees"

echo "-- absent entries (no host creation, launch allowed)"
A="${R}/absent"
_new_repo "${A}"
rm -rf "${A}/.git/hooks"
git -C "${A}" config extensions.worktreeConfig true
out="$(_protect "${A}")"
assert_contains "${out}" "rc=0" "missing hooks/: launch allowed"
assert_not_contains "${out}" "${A}/.git/hooks${NL}" "missing hooks/: no bind for it"
assert_contains "${out}" "${A}/.git/hooks/" "missing hooks/: reported absent"
assert_contains "${out}" "${A}/.git/config.worktree" "active extensions.worktreeConfig without config.worktree: reported absent"
made=0; [[ -e "${A}/.git/hooks" || -e "${A}/.git/config.worktree" ]] && made=1
assert_eq "${made}" "0" "absent entries: nothing created on the host"
git -C "${A}" config --unset extensions.worktreeConfig
out="$(_protect "${A}")"
assert_not_contains "${out}" "config.worktree" "inactive worktreeConfig: config.worktree not reported"
mv "${A}/.git/config" "${A}/.git/config.saved"
out="$(_protect "${A}")"
assert_contains "${out}" "rc=0" "missing config: launch allowed"
assert_contains "${out}" "${A}/.git/config " "missing config: reported absent"
made=0; [[ -e "${A}/.git/config" ]] && made=1
assert_eq "${made}" "0" "missing config: not created on the host"
mv "${A}/.git/config.saved" "${A}/.git/config"

echo "-- relaxed mode (AI_SANDBOX_ALLOW_GIT_CONFIG=1)"
mkdir -p "${N}/.git/modules/sub1/hooks"; : >"${N}/.git/modules/sub1/config"
printf '%s\n' "../x" >"${N}/.git/commondir"
out="$(AI_SANDBOX_ALLOW_GIT_CONFIG=1 _protect "${N}")"
assert_contains "${out}" "rc=0" "relaxed: launch allowed"
assert_contains "${out}" "$(_lflag --bind "${N}/.git")" "relaxed (Linux): root still pinned"
assert_contains "${out}" "$(_lflag --ro-bind "${N}/.git/commondir")" "relaxed: commondir pointer still read-only"
assert_not_contains "${out}" "${N}/.git/config${NL}" "relaxed: config writable"
assert_not_contains "${out}" "${N}/.git/hooks${NL}" "relaxed: hooks/ writable"
assert_not_contains "${out}" "${N}/.git/modules/sub1/config${NL}" "relaxed: submodule config writable"
assert_contains "${out}" "AI_SANDBOX_ALLOW_GIT_CONFIG=1" "relaxed: WARN names the setting"
out="$(AI_SANDBOX_ALLOW_GIT_CONFIG=1 _protect "${N}" Darwin)"
assert_contains "${out}" "--pin${NL}${N}/.git${NL}" "relaxed (macOS): root still pinned (no RO child to derive a pin from)"
out="$(AI_SANDBOX_ALLOW_GIT_CONFIG=yes _protect "${N}")"
assert_contains "${out}" "$(_lflag --ro-bind "${N}/.git/config")" "non-1 value (yes) keeps protection on"
rm -f "${N}/.git/commondir"; rm -rf "${N}/.git/modules"

echo "-- symlink / type validation (both modes)"
mkdir -p "${R}/target-dir"; : >"${R}/target-file"
for mode in 0 1; do
    for entry in hooks config config.worktree commondir worktrees modules; do
        V="${R}/sym-${entry}"
        _new_repo "${V}"
        rm -rf "${V:?}/.git/${entry}"
        case "${entry}" in
            hooks|worktrees|modules) ln -s "${R}/target-dir" "${V}/.git/${entry}" ;;
            *) ln -s "${R}/target-file" "${V}/.git/${entry}" ;;
        esac
        out="$(AI_SANDBOX_ALLOW_GIT_CONFIG="${mode}" _protect "${V}")"
        assert_contains "${out}" "rc=1" "ALLOW_GIT_CONFIG=${mode}: symlinked .git/${entry} refuses the launch"
        assert_contains "${out}" "is a symlink" "... with the symlink ERROR"
        assert_not_contains "${out}" "--bind" "... before any bind is added"
    done
    V="${R}/sym-module"
    _new_repo "${V}"
    mkdir -p "${V}/.git/modules"; ln -s "${R}/target-dir" "${V}/.git/modules/m"
    out="$(AI_SANDBOX_ALLOW_GIT_CONFIG="${mode}" _protect "${V}")"
    assert_contains "${out}" "rc=1" "ALLOW_GIT_CONFIG=${mode}: symlinked .git/modules/<name> refuses the launch"
    V="${R}/sym-root"
    rm -rf "${V}"; mkdir -p "${V}"; ln -s "${N}/.git" "${V}/.git"
    out="$(AI_SANDBOX_ALLOW_GIT_CONFIG="${mode}" _protect "${V}")"
    assert_contains "${out}" "rc=1" "ALLOW_GIT_CONFIG=${mode}: symlinked .git refuses the launch"
    V="${R}/type-hooks"
    _new_repo "${V}"
    rm -rf "${V}/.git/hooks"; : >"${V}/.git/hooks"
    out="$(AI_SANDBOX_ALLOW_GIT_CONFIG="${mode}" _protect "${V}")"
    assert_contains "${out}" "rc=1" "ALLOW_GIT_CONFIG=${mode}: hooks as a regular file refuses the launch"
    assert_contains "${out}" "not a regular directory" "... with the type ERROR"
    V="${R}/type-config"
    _new_repo "${V}"
    mv "${V}/.git/config" "${V}/.git/config.saved"; mkdir "${V}/.git/config"
    out="$(AI_SANDBOX_ALLOW_GIT_CONFIG="${mode}" _protect "${V}")"
    assert_contains "${out}" "rc=1" "ALLOW_GIT_CONFIG=${mode}: config as a directory refuses the launch"
done
rm -rf "${R}"/sym-* "${R}"/type-*

# ---------------------------------------------------------------------------
# Nested submodule git dirs (#12). Real Git layout: superproject with the
# submodule `plain` and the slash-named `ns/inner/mid`, which has its own
# submodule `deep/leaf`:
#   .git/modules/plain
#   .git/modules/ns/inner/mid                       (ns, ns/inner: namespaces)
#   .git/modules/ns/inner/mid/modules/deep/leaf     (deep: namespace)
git_sub() { git_q -c protocol.file.allow=always "$@"; }
NSRC="${R}/nested-src"
_new_repo "${NSRC}/leaf"
_new_repo "${NSRC}/mid"
git_sub -C "${NSRC}/mid" submodule add "${NSRC}/leaf" deep/leaf
git_q -C "${NSRC}/mid" commit -m add-leaf
# Build superproject TOP from NSRC; every module git dir gets a hooks/.
_new_nested_super() {
    local top="${1}" gd
    _new_repo "${top}"
    git_sub -C "${top}" submodule add "${NSRC}/mid" ns/inner/mid
    git_sub -C "${top}" submodule add "${NSRC}/leaf" plain
    git_q -C "${top}" commit -m add-subs
    git_sub -C "${top}" submodule update --init --recursive
    for gd in plain ns/inner/mid ns/inner/mid/modules/deep/leaf; do
        mkdir -p "${top}/.git/modules/${gd}/hooks"
    done
    mkdir -p "${top}/.git/hooks"
}
# The module git dirs and the directory chain the protection must pin.
_nested_gitdirs() { printf '%s\n' plain ns/inner/mid ns/inner/mid/modules/deep/leaf; }
_nested_chain() { printf '%s\n' "" /ns /ns/inner /ns/inner/mid /ns/inner/mid/modules /ns/inner/mid/modules/deep \
    /ns/inner/mid/modules/deep/leaf /plain; }

echo "-- nested submodule git dirs: real layout (#12)"
NS="${R}/nested"
_new_nested_super "${NS}"
NM="${NS}/.git/modules"
ok=0; [[ -f "${NM}/ns/inner/mid/modules/deep/leaf/HEAD" && -f "${NM}/plain/HEAD" && ! -e "${NM}/ns/HEAD" ]] && ok=1
assert_eq "${ok}" "1" "fixture: git created nested and slash-named module git dirs"
# Ordinary object storage below a git dir is not searched: a symlink there
# must not refuse the launch.
ln -s "${R}/target-dir" "${NM}/plain/objects/not-searched"
out="$(_protect "${NS}")"
assert_contains "${out}" "rc=0" "nested: launch allowed"
while IFS= read -r c; do
    assert_contains "${out}" "$(_lflag --bind "${NM}${c}")" "nested (Linux): modules${c} pinned"
done < <(_nested_chain)
while IFS= read -r g; do
    assert_contains "${out}" "$(_lflag --ro-bind "${NM}/${g}/config")" "nested: modules/${g}/config read-only"
    assert_contains "${out}" "$(_lflag --ro-bind "${NM}/${g}/hooks")" "nested: modules/${g}/hooks read-only"
done < <(_nested_gitdirs)
for n in ns ns/inner ns/inner/mid/modules/deep; do
    assert_not_contains "${out}" "${NM}/${n}/config${NL}" "nested: namespace modules/${n} not treated as a git dir (config)"
    assert_not_contains "${out}" "${NM}/${n}/commondir" "nested: namespace modules/${n} not treated as a git dir (commondir)"
done
assert_not_contains "${out}" "not-searched" "nested: objects/ of a module git dir not searched"
# bwrap: every pin before the first read-only layer below modules/.
last_pin="$(printf '%s\n' "${out}" | grep -n -x -F -e "--bind" | tail -1 | cut -d: -f1)"
first_ro="$(printf '%s\n' "${out}" | grep -n -x -F -e "--ro-bind" | head -1 | cut -d: -f1)"
ok=0; [[ -n "${last_pin}" && -n "${first_ro}" && "${last_pin}" -lt "${first_ro}" ]] && ok=1
assert_eq "${ok}" "1" "nested (Linux): all pins precede the read-only layers"
out="$(_protect "${NS}" Darwin)"
for c in /ns /ns/inner/mid/modules/deep /ns/inner/mid/modules/deep/leaf; do
    assert_contains "${out}" "--pin${NL}${NM}${c}${NL}" "nested (macOS): modules${c} pinned with --pin"
done
assert_contains "${out}" "--ro-bind${NL}${NM}/ns/inner/mid/modules/deep/leaf/config${NL}" "nested (macOS): deepest config read-only"
rm -f "${NM}/plain/objects/not-searched"

echo "-- nested submodule git dirs: relaxed mode"
out="$(AI_SANDBOX_ALLOW_GIT_CONFIG=1 _protect "${NS}")"
assert_contains "${out}" "rc=0" "nested relaxed: launch allowed"
while IFS= read -r c; do
    assert_contains "${out}" "$(_lflag --bind "${NM}${c}")" "nested relaxed (Linux): modules${c} still pinned"
done < <(_nested_chain)
assert_not_contains "${out}" "--ro-bind${NL}${NM}" "nested relaxed: no submodule config/hooks layer"
assert_contains "${out}" "submodule git dirs" "nested relaxed: WARN covers submodules"
printf '%s\n' "../x" >"${NM}/ns/inner/mid/modules/deep/leaf/commondir"
mkdir -p "${NM}/plain/worktrees"
out="$(AI_SANDBOX_ALLOW_GIT_CONFIG=1 _protect "${NS}")"
assert_contains "${out}" "$(_lflag --ro-bind "${NM}/ns/inner/mid/modules/deep/leaf/commondir")" "nested relaxed: nested commondir pointer still read-only"
assert_contains "${out}" "$(_lflag --ro-bind "${NM}/plain/worktrees")" "nested relaxed: submodule worktrees/ still read-only"
out="$(AI_SANDBOX_ALLOW_GIT_CONFIG=1 _protect "${NS}" Darwin)"
assert_contains "${out}" "--pin${NL}${NM}/ns/inner${NL}" "nested relaxed (macOS): namespace still pinned"
rm -f "${NM}/ns/inner/mid/modules/deep/leaf/commondir"; rmdir "${NM}/plain/worktrees"

echo "-- nested submodule git dirs: missing config / hooks (no host creation)"
LEAF="${NM}/ns/inner/mid/modules/deep/leaf"
mv "${LEAF}/config" "${R}/leaf-config.saved"
rm -rf "${NM}/plain/hooks"
git -C "${NS}" config extensions.worktreeConfig true
git config --file "${NM}/ns/inner/mid/config" extensions.worktreeConfig true
out="$(_protect "${NS}")"
assert_contains "${out}" "rc=0" "missing nested config/hooks: launch allowed"
assert_contains "${out}" "$(_lflag --bind "${LEAF}")" "missing config: git dir still recognised by HEAD (pinned)"
assert_contains "${out}" "$(_lflag --ro-bind "${LEAF}/hooks")" "missing config: its hooks/ still read-only"
absent_line="$(printf '%s\n' "${out}" | grep 'absent at launch' || true)"
assert_contains "${absent_line}" "${LEAF}/config " "missing nested config reported absent"
assert_contains "${absent_line}" "${NM}/plain/hooks/" "missing submodule hooks/ reported absent"
assert_contains "${absent_line}" "${NM}/ns/inner/mid/config.worktree" "submodule worktreeConfig without config.worktree reported absent"
made=0; [[ -e "${LEAF}/config" || -e "${NM}/plain/hooks" || -e "${NM}/ns/inner/mid/config.worktree" ]] && made=1
assert_eq "${made}" "0" "missing nested entries: nothing created on the host"
mv "${R}/leaf-config.saved" "${LEAF}/config"; mkdir "${NM}/plain/hooks"
git -C "${NS}" config --unset extensions.worktreeConfig
git config --file "${NM}/ns/inner/mid/config" --unset extensions.worktreeConfig
# A namespace may hold stray regular files (not git dirs): ignored.
: >"${NM}/ns/stray"
out="$(_protect "${NS}")"
assert_contains "${out}" "rc=0" "regular file in a namespace: launch allowed"
assert_not_contains "${out}" "${NM}/ns/stray" "regular file in a namespace: not bound"
rm -f "${NM}/ns/stray"

echo "-- nested submodule git dirs: symlink / type validation (both modes)"
CANARY="${R}/canary"
rm -rf "${CANARY}"; mkdir -p "${CANARY}/hooks"; printf 'canary\n' >"${CANARY}/config"; printf 'ref: x\n' >"${CANARY}/HEAD"
canary_before="$(ls -A "${CANARY}" "${CANARY}/hooks"; cksum "${CANARY}/config" "${CANARY}/HEAD")"
# Each case: path below .git/modules, what replaces it.
_nested_bad() {
    local mode="${1}" rel="${2}" kind="${3}" label="${4}" expect="${5}" V="${R}/nested-bad"
    rm -rf "${V}"; cp -R "${NS}" "${V}"
    local p="${V}/.git/modules/${rel}"
    rm -rf "${p}"
    case "${kind}" in
        dirlink) ln -s "${CANARY}" "${p}" ;;
        filelink) ln -s "${CANARY}/config" "${p}" ;;
        file) : >"${p}" ;;
    esac
    out="$(AI_SANDBOX_ALLOW_GIT_CONFIG="${mode}" _protect "${V}")"
    assert_contains "${out}" "rc=1" "ALLOW_GIT_CONFIG=${mode}: ${label} refuses the launch"
    assert_contains "${out}" "${expect}" "... with the ERROR"
    assert_not_contains "${out}" "--bind" "... before any bind is added"
    rm -rf "${V}"
}
for mode in 0 1; do
    _nested_bad "${mode}" ns dirlink "symlinked namespace parent" "is a symlink"
    _nested_bad "${mode}" ns/inner/mid/modules dirlink "symlinked nested modules/" "is a symlink"
    _nested_bad "${mode}" ns/inner/mid/modules/deep/leaf dirlink "symlinked nested module git dir" "is a symlink"
    _nested_bad "${mode}" ns/inner/mid/modules/deep/leaf/hooks dirlink "symlinked nested hooks/" "is a symlink"
    _nested_bad "${mode}" ns/inner/mid/modules/deep/leaf/config filelink "symlinked nested config" "is a symlink"
    _nested_bad "${mode}" ns/inner/mid/modules/deep/leaf/HEAD filelink "symlinked nested HEAD" "is a symlink"
    _nested_bad "${mode}" ns/inner/mid/modules/deep/leaf/commondir filelink "symlinked nested commondir" "is a symlink"
    _nested_bad "${mode}" ns/inner/mid/modules/deep/leaf/hooks file "nested hooks/ as a regular file" "not a regular directory"
    _nested_bad "${mode}" ns/inner/mid/modules file "nested modules as a regular file" "not a regular directory"
done
assert_eq "$(ls -A "${CANARY}" "${CANARY}/hooks"; cksum "${CANARY}/config" "${CANARY}/HEAD")" "${canary_before}" "symlink refusals: external canary untouched"

echo "-- nested submodule git dirs: depth and count limits"
_fake_mod() { mkdir -p "${1}" && : >"${1}/HEAD"; }
LM="${R}/limits"
_new_repo "${LM}"
# 15 namespace parents + the git dir = depth 16 (the limit): allowed.
chain=""; for i in $(seq 1 15); do chain+="/n${i}"; done
_fake_mod "${LM}/.git/modules${chain}/g"
out="$(_protect "${LM}")"
assert_contains "${out}" "rc=0" "depth 16 (namespace chain): allowed"
assert_contains "${out}" "$(_lflag --bind "${LM}/.git/modules${chain}/g")" "depth 16: deepest git dir pinned"
assert_contains "${out}" "$(_lflag --bind "${LM}/.git/modules/n1")" "depth 16: top namespace pinned"
# One more namespace level: refused, not truncated.
rm -rf "${LM}/.git/modules"; _fake_mod "${LM}/.git/modules${chain}/n16/g"
out="$(_protect "${LM}")"
assert_contains "${out}" "rc=1" "depth 17 (namespace chain): refused"
assert_contains "${out}" "deeper than the supported 16" "... naming the depth limit"
assert_not_contains "${out}" "--bind" "... before any bind"
# Nested modules/ dirs count as levels: a/modules/b/.../modules/h is 15.
rm -rf "${LM}/.git/modules"
nest=""; for n in a b c d e f g h; do nest+="${nest:+/modules}/${n}"; _fake_mod "${LM}/.git/modules${nest}"; done
out="$(_protect "${LM}")"
assert_contains "${out}" "rc=0" "depth 15 (8 nested git dirs): allowed"
assert_contains "${out}" "$(_lflag --bind "${LM}/.git/modules${nest}")" "8 nested git dirs: deepest pinned"
mkdir "${LM}/.git/modules${nest}/modules"
out="$(_protect "${LM}")"
assert_contains "${out}" "rc=0" "depth 16 (empty nested modules/): allowed"
_fake_mod "${LM}/.git/modules${nest}/modules/i"
out="$(_protect "${LM}")"
assert_contains "${out}" "rc=1" "depth 17 (git dir below the 16th level): refused"
assert_contains "${out}" "deeper than the supported 16" "... naming the depth limit"
# Count: 256 git dirs (one of them nested) allowed, 257 refused.
rm -rf "${LM}/.git/modules"
for i in $(seq 1 255); do _fake_mod "${LM}/.git/modules/m${i}"; done
_fake_mod "${LM}/.git/modules/m1/modules/x"
out="$(_protect "${LM}")"
assert_contains "${out}" "rc=0" "256 module git dirs: allowed"
assert_contains "${out}" "$(_lflag --bind "${LM}/.git/modules/m255")" "256 module git dirs: last one pinned"
assert_contains "${out}" "$(_lflag --bind "${LM}/.git/modules/m1/modules/x")" "256 module git dirs: nested one pinned"
_fake_mod "${LM}/.git/modules/m1/modules/y"
out="$(_protect "${LM}")"
assert_contains "${out}" "rc=1" "257 module git dirs: refused"
assert_contains "${out}" "more than 256 submodule git dirs" "... naming the count limit"
assert_not_contains "${out}" "--bind" "... before any bind"
rm -rf "${LM}"

echo "-- linked worktree pointer (.git file)"
M="${R}/main"
_new_repo "${M}"
git_q -C "${M}" worktree add "${R}/wt" -b wt
for mode in 0 1; do
    out="$(AI_SANDBOX_ALLOW_GIT_CONFIG="${mode}" _protect "${R}/wt")"
    assert_contains "${out}" "rc=0" "ALLOW_GIT_CONFIG=${mode}: linked worktree launch allowed"
    assert_contains "${out}" "$(_lflag --ro-bind "${R}/wt/.git")" "ALLOW_GIT_CONFIG=${mode}: .git pointer file read-only"
    assert_not_contains "${out}" "--bind${NL}${R}/wt/.git${NL}" "ALLOW_GIT_CONFIG=${mode}: pointer file not pinned RW"
    assert_not_contains "${out}" "WARN" "ALLOW_GIT_CONFIG=${mode}: legit worktree pointer: no WARN"
done
out="$(_protect "${R}/wt" Darwin)"
assert_contains "${out}" "--ro-bind${NL}${R}/wt/.git" "linked worktree (macOS): pointer file read-only"
assert_not_contains "${out}" "${R}/wt/.git${NL}${R}/wt/.git" "linked worktree (macOS): single-arg flag shape"
I="${R}/inner-gitdir"
rm -rf "${I}"; mkdir -p "${I}"
git_q init --separate-git-dir "${I}/.meta" "${I}"
out="$(_protect "${I}")"
assert_contains "${out}" "$(_lflag --ro-bind "${I}/.git")" ".git file -> git dir inside WORKDIR: pointer read-only"
assert_contains "${out}" "points at a git dir inside WORKDIR" "... and the writable target WARNed"

echo "-- bare repository / WORKDIR is a git dir"
B="${R}/bare.git"
rm -rf "${B}"; git_q clone --bare "${M}" "${B}"
[[ -d "${B}/hooks" ]] || mkdir "${B}/hooks"
out="$(_protect "${B}")"
assert_contains "${out}" "rc=0" "bare repo: launch allowed"
assert_contains "${out}" "$(_lflag --ro-bind "${B}/config")" "bare repo: config read-only"
assert_contains "${out}" "$(_lflag --ro-bind "${B}/hooks")" "bare repo: hooks/ read-only"
assert_not_contains "${out}" "--bind${NL}${B}${NL}" "bare repo: WORKDIR itself is not re-bound"
assert_not_contains "${out}" "not in a git repository" "bare repo: not classified as a new repo"
out="$( (cd "${B}" && _load && WRAPPER_FLAGS=() && GIT_DIR=/nonexistent _wrapper_protect_workdir_git; printf '%s\n' "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}") 2>&1 )"
assert_contains "${out}" "${B}/config" "bare repo: inherited GIT_DIR does not change the classification"
out="$(_protect "${M}/.git")"
assert_contains "${out}" "$(_lflag --ro-bind "${M}/.git/config")" "WORKDIR = <repo>/.git: protected as the git dir"
out="$(_protect "${M}/.git/refs")"
assert_contains "${out}" "rc=1" "WORKDIR inside a git dir: launch refused"

echo "-- repository subdirectory and non-repo"
mkdir -p "${M}/sub/deeper" "${R}/wt/sub"
for d in "${M}/sub/deeper" "${R}/wt/sub"; do
    out="$(_protect "${d}")"
    assert_contains "${out}" "rc=0" "subdirectory ${d#"${R}/"}: launch allowed"
    assert_not_contains "${out}" "--" "subdirectory ${d#"${R}/"}: no binds (git dir outside WORKDIR)"
    assert_not_contains "${out}" "WARN" "subdirectory ${d#"${R}/"}: not classified as a new repo"
done
S="${R}/scaffold"
mkdir -p "${S}"
out="$(_protect "${S}")"
assert_contains "${out}" "rc=0" "non-repo: launch allowed"
assert_contains "${out}" "not in a git repository" "non-repo: new-metadata WARN"
assert_contains "${out}" "git init" "... mentioning git init"
made=0; [[ -e "${S}/.git" ]] && made=1
assert_eq "${made}" "0" "non-repo: no .git created on the host"

echo "-- indirection WARNs"
X="${R}/indirect"
_new_repo "${X}"
mkdir -p "${X}/.husky" "${X}/scripts"; : >"${X}/scripts/pre-commit"
git -C "${X}" config core.hooksPath .husky
git -C "${X}" config core.fsmonitor ./scripts/fsmon
git -C "${X}" config include.path ../.gitconfig.local
git -C "${X}" config 'includeIf.gitdir:**/indirect/.git.path' "${X}/.gitconfig.cond"
mkdir -p "${X}/.git/hooks"; ln -s ../../scripts/pre-commit "${X}/.git/hooks/pre-commit"
out="$(_protect "${X}")"
assert_contains "${out}" "rc=0" "indirection: launch allowed"
assert_contains "${out}" "core.hooksPath=.husky" "core.hooksPath into WORKDIR WARNed"
assert_contains "${out}" "core.fsmonitor=./scripts/fsmon" "core.fsmonitor script in WORKDIR WARNed"
assert_contains "${out}" "include.path=../.gitconfig.local" "include.path into WORKDIR WARNed"
assert_contains "${out}" ".gitconfig.cond" "includeIf path into WORKDIR WARNed"
assert_contains "${out}" "hook symlink ${X}/.git/hooks/pre-commit" "hook symlink into WORKDIR WARNed"
assert_contains "${out}" "$(_lflag --ro-bind "${X}/.git/config")" "indirection: config still read-only"
git -C "${X}" config core.hooksPath "${FAKE_HOME}/global-hooks"
git -C "${X}" config core.fsmonitor true
out="$(_protect "${X}")"
assert_not_contains "${out}" "core.hooksPath=" "core.hooksPath outside WORKDIR: no WARN"
assert_not_contains "${out}" "core.fsmonitor=" "core.fsmonitor=true (built-in): no WARN"
rm -rf "${X}"

# ---------------------------------------------------------------------------
echo "-- setting: catalog, preset and launch override"
catalog="$( _load; printf '%s\n' "${_AI_SETTINGS_LIST[@]}" )"
assert_contains "${catalog}" "AI_SANDBOX_ALLOW_GIT_CONFIG|bool|0|red|" "catalog: bool, default 0 (protected), red"
row="$(printf '%s\n' "${catalog}" | grep '^AI_SANDBOX_ALLOW_GIT_CONFIG|')"
assert_eq "${row##*|}" "sensitive" "catalog: listed under sensitive settings on every OS"
P="${R}/preset-wd"
mkdir -p "${P}"
_in_preset() { ( cd "${P}" && _load && eval "${1}" ) 2>&1; }
saved="$(_in_preset 'AI_SANDBOX_ALLOW_GIT_CONFIG=1 _preset_autosave 2>/dev/null; cat "$(_preset_autosave_path)"')"
assert_contains "${saved}" "AI_SANDBOX_ALLOW_GIT_CONFIG=1" "preset: autosave persists the setting"
out="$(_in_preset '_preset_autoload; echo "VAL=${AI_SANDBOX_ALLOW_GIT_CONFIG:-unset}"')"
assert_contains "${out}" "VAL=1" "preset: autoload restores the relaxed value"
assert_contains "${out}" "Restored AI_SANDBOX_ALLOW_GIT_CONFIG=1" "preset: restoring the relaxed value WARNs"
out="$(export AI_SANDBOX_ALLOW_GIT_CONFIG=0; _in_preset '_preset_autoload; echo "VAL=${AI_SANDBOX_ALLOW_GIT_CONFIG}"')"
assert_contains "${out}" "VAL=0" "explicit launch value 0 wins over a saved 1"
assert_not_contains "${out}" "Restored" "... without the restore WARN"
out="$(_in_preset 'AI_SANDBOX_ALLOW_GIT_CONFIG=0 _preset_autosave 2>/dev/null; _preset_autoload; echo "VAL=${AI_SANDBOX_ALLOW_GIT_CONFIG}"')"
assert_contains "${out}" "VAL=0" "preset: saved 0 restores protected mode"
assert_not_contains "${out}" "Restored" "preset: restoring 0 does not WARN"
help_md="$(cat "${REPO_ROOT}/bin/ai_wrapper_data/wrapper-help.md")"
assert_contains "${help_md}" "AI_SANDBOX_ALLOW_GIT_CONFIG" "wrapper-help.md documents the setting"

# ---------------------------------------------------------------------------
echo "-- refusal propagates through every wrapper"
V="${R}/refuse"
_new_repo "${V}"
rm -rf "${V}/.git/hooks"; ln -s "${R}/target-dir" "${V}/.git/hooks"
# agy validates (never writes) its settings.json before the post-menu binds.
mkdir -p "${FAKE_HOME}/.gemini/antigravity-cli"
python3 -I -c 'import json,sys;print(json.dumps({"toolPermission":"always-proceed","artifactReviewPolicy":"always-proceed","allowNonWorkspaceAccess":True,"enableTerminalSandbox":False,"trustedWorkspaces":sys.argv[1:]}))' \
    "${V}" >"${FAKE_HOME}/.gemini/antigravity-cli/settings.json"
# Nested submodule metadata (#12): a symlinked namespace parent two levels
# down, in WORKDIR's own .git and in a linked worktree's shared common dir.
VN="${R}/refuse-nested"
rm -rf "${VN}"; cp -R "${NS}" "${VN}"
mv "${VN}/.git/modules/ns/inner" "${R}/refuse-inner.saved"
ln -s "${R}/refuse-inner.saved" "${VN}/.git/modules/ns/inner"
VW="${R}/refuse-wt"
git_q -C "${VN}" worktree add "${VW}" -b refuse-wt
python3 -I -c 'import json,sys;print(json.dumps({"toolPermission":"always-proceed","artifactReviewPolicy":"always-proceed","allowNonWorkspaceAccess":True,"enableTerminalSandbox":False,"trustedWorkspaces":sys.argv[1:]}))' \
    "${V}" "${VN}" "${VW}" >"${FAKE_HOME}/.gemini/antigravity-cli/settings.json"
canary_before="$(ls -A "${R}/refuse-inner.saved")"
for client in claude codex agy copilot cursor_agent; do
    out="$(cd "${V}" && bash "${REPO_ROOT}/bin/executable_${client}_wrapper.bash" x </dev/null 2>&1)"; rc=$?
    assert_eq "${rc}" "1" "${client}: symlinked hooks/ exits 1"
    assert_contains "${out}" "is a symlink" "${client}: ... with the refusal ERROR"
    assert_not_contains "${out}" "LIVE_CLIENT_TRAP" "${client}: ... before the client runs"
    out="$(cd "${VN}" && bash "${REPO_ROOT}/bin/executable_${client}_wrapper.bash" x </dev/null 2>&1)"; rc=$?
    assert_eq "${rc}" "1" "${client}: symlinked nested submodule namespace exits 1"
    assert_contains "${out}" "is a symlink" "${client}: ... with the refusal ERROR"
    assert_not_contains "${out}" "LIVE_CLIENT_TRAP" "${client}: ... before the client runs"
    # cursor-agent never binds a worktree's common dir (nothing to refuse).
    [[ "${client}" == "cursor_agent" ]] && continue
    out="$(cd "${VW}" && bash "${REPO_ROOT}/bin/executable_${client}_wrapper.bash" x </dev/null 2>&1)"; rc=$?
    assert_eq "${rc}" "1" "${client}: symlinked submodule namespace in a worktree's common dir exits 1"
    assert_contains "${out}" "is a symlink" "${client}: ... with the refusal ERROR"
    assert_not_contains "${out}" "LIVE_CLIENT_TRAP" "${client}: ... before the client runs"
done
assert_eq "$(ls -A "${R}/refuse-inner.saved")" "${canary_before}" "nested refusals: symlink target untouched"
git_q -C "${VN}" worktree remove --force "${VW}"
rm -rf "${V}" "${VN}" "${VW}" "${R}/refuse-inner.saved"

# ---------------------------------------------------------------------------
echo "-- native enforcement (codex wrapper)"
sandbox_e2e=0
if [[ "${OS}" == "Linux" ]]; then
    if command -v bwrap >/dev/null 2>&1; then
        sandbox_e2e=1
    else
        _test_report 0 "bwrap available on Linux (native enforcement cannot be certified)"
    fi
elif [[ "${OS}" == "Darwin" ]]; then
    if command -v sandbox-exec >/dev/null 2>&1; then
        sandbox_e2e=1
    else
        _test_report 0 "sandbox-exec available on macOS (native enforcement cannot be certified)"
    fi
fi

# Write the probe client to ~/bin/codex. EXPECT_GITDIR: the git dir git
# must discover from WORKDIR ("" = none: WORKDIR must not be in a repo);
# REQUIRED: space-separated paths that must exist first; BODY: probes.
_write_probe() {
    local expect="${1}" required="${2}" body="${3}"
    {
        printf '#!/bin/bash\nexpect=%q\nrequired=%q\n' "${expect}" "${required}"
        cat <<'STUB'
setup_failed() { echo "SETUP_FAILED: $*"; exit 3; }
if [[ -n "${expect}" ]]; then
    gd="$(git rev-parse --absolute-git-dir 2>&1)" || setup_failed "git rev-parse: ${gd}"
    gd="$(cd "${gd}" 2>&1 && pwd -P)" || setup_failed "cannot enter git dir: ${gd}"
    [[ "${gd}" == "${expect}" ]] || setup_failed "discovered '${gd}', expected '${expect}'"
elif git rev-parse --absolute-git-dir >/dev/null 2>&1; then
    setup_failed "WORKDIR is unexpectedly inside a repository"
fi
for p in ${required}; do [[ -e "${p}" ]] || setup_failed "missing ${p}"; done
echo DISCOVERY_OK
g() { git -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
# rename(2) without mv's copy+delete fallback.
ren() { perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$@"; }
export -f ren
probe() { local name="${1}"; shift; if ("$@") >/dev/null 2>&1; then echo "WROTE:${name}"; else echo "DENIED:${name}"; fi; }
STUB
        printf '%s\necho PROBES_DONE\n' "${body}"
    } >"${FAKE_HOME}/bin/codex"
    chmod +x "${FAKE_HOME}/bin/codex"
}
# Launch the codex wrapper in DIR with extra env assignments (VAR=VAL...).
_launch() {
    local dir="${1}"; shift
    local ro=""
    # macOS: ~/bin is not on the base read allowlist.
    [[ "${OS}" == "Darwin" ]] && ro="${FAKE_HOME}/bin"
    ( cd "${dir}" && env AI_SANDBOX_EXTRA_RO_DIRS="${ro}" "$@" \
        bash "${REPO_ROOT}/bin/executable_codex_wrapper.bash" x </dev/null 2>&1 )
}
_assert_ran() {
    local out="${1}" rc="${2}" label="${3}"
    echo "  (${label} output: ${out})"
    assert_eq "${rc}" "0" "${label}: probe client exits 0"
    assert_contains "${out}" "DISCOVERY_OK" "${label}: probe found the fixture"
    assert_not_contains "${out}" "SETUP_FAILED" "${label}: no setup failure"
    assert_contains "${out}" "PROBES_DONE" "${label}: probe ran to the end"
}
_sums() { local f; for f in "$@"; do printf '%s ' "${f}"; if [[ -d "${f}" ]]; then ls -A "${f}" | tr '\n' ' '; echo; else cksum <"${f}" 2>&1; fi; done; }

# Probes shared by the normal-repo runs; TAG makes each run's commit,
# branch and file content fresh, so a later run on the same fixture never
# hits "nothing to commit" or "branch already exists". .git/cfg.tmp keeps
# the atomic replacement on the .git mount (a cross-mount rename would
# fail with EXDEV for the wrong reason).
_normal_probes() {
    local tag="${1}"
    printf '%s\n' \
        "echo ${tag} >file && g add file && g commit -m sandboxed-${tag} && echo COMMIT_OK" \
        "g branch side-${tag} && echo BRANCH_OK" \
        "g checkout -b feature-${tag} && g checkout main && echo CHECKOUT_OK"
    cat <<'PROBES'
probe git-config g config user.name evil
probe remote-add g remote add evil /nonexistent
probe append-config sh -c "echo \"[alias] x = !true\" >>.git/config"
probe replace-config bash -c "cp .git/config .git/cfg.tmp && echo \"[core] fsmonitor = ./x\" >>.git/cfg.tmp && ren .git/cfg.tmp .git/config"
probe hook-create sh -c "echo evil >.git/hooks/post-checkout && chmod +x .git/hooks/post-checkout"
probe hooks-rename ren .git/hooks .git/hooks.old
probe gitdir-move bash -c "ren .git .git.moved; rc=\$?; [ \"\${rc}\" = 0 ] && ren .git.moved .git; exit \${rc}"
probe gitdir-rmdir-swap bash -c "ren .git .git.old && mkdir .git"
g push -u origin main; echo "PUSH_RC=$?"
rm -f .git/cfg.tmp
PROBES
}
# The persisted state a _normal_probes TAG run must leave on the host.
_assert_normal_persisted() {
    local tag="${1}" label="${2}" ok
    for ok in COMMIT_OK BRANCH_OK CHECKOUT_OK; do
        assert_contains "${out}" "${ok}" "${label}: ${ok}"
    done
    assert_eq "$(git -C "${E}" log --format=%s -1 main)" "sandboxed-${tag}" "${label}: commit persisted on the host"
    assert_eq "$(git -C "${E}" show "main:file" 2>&1)" "${tag}" "${label}: committed content persisted on the host"
    ok=0; git -C "${E}" rev-parse -q --verify "side-${tag}" >/dev/null \
        && git -C "${E}" rev-parse -q --verify "feature-${tag}" >/dev/null && ok=1
    assert_eq "${ok}" "1" "${label}: branches persisted on the host"
    assert_eq "$(git -C "${E}" symbolic-ref --short HEAD)" "main" "${label}: checkout returned to main"
    assert_eq "$(git -C "${E}" status --porcelain)" "" "${label}: index and work tree consistent on the host"
    assert_eq "$(git -C "${E}/remote.git" log --format=%s -1 main 2>&1)" "sandboxed-${tag}" "${label}: push reached the remote"
}

# Probes for the nested-submodule fixture (_new_nested_super), run from
# its work tree. TAG makes the submodule commits fresh. Temp files stay in
# the directory they replace (a cross-mount rename would fail with EXDEV
# for the wrong reason); every move probe moves the directory back.
_nested_probes() {
    local tag="${1}"
    printf '%s\n' \
        "(cd plain && g commit --allow-empty -m sub-${tag}) && echo SUB_COMMIT_OK" \
        "(cd ns/inner/mid/deep/leaf && g commit --allow-empty -m leaf-${tag}) && echo LEAF_COMMIT_OK"
    cat <<'PROBES'
M=.git/modules
L=${M}/ns/inner/mid/modules/deep/leaf
mvback() { ren "$1" "$2"; rc=$?; [ "${rc}" = 0 ] && ren "$2" "$1"; return "${rc}"; }
export -f mvback
probe leaf-config-append sh -c "echo evil >>${L}/config"
probe mid-config-replace bash -c "cp ${M}/ns/inner/mid/config ${M}/ns/inner/mid/cfg.tmp && echo '[core] fsmonitor = ./x' >>${M}/ns/inner/mid/cfg.tmp && ren ${M}/ns/inner/mid/cfg.tmp ${M}/ns/inner/mid/config"
probe leaf-hook-create sh -c "echo evil >${L}/hooks/post-commit"
probe modules-move bash -c "mvback ${M} .git/modules.moved"
probe namespace-move bash -c "mvback ${M}/ns ${M}/ns.moved"
probe namespace-swap bash -c "ren ${M}/ns/inner ${M}/ns/inner.old && mkdir -p ${M}/ns/inner/mid"
probe nested-modules-move bash -c "mvback ${M}/ns/inner/mid/modules ${M}/ns/inner/mid/modules.moved"
probe deep-namespace-move bash -c "mvback ${M}/ns/inner/mid/modules/deep ${M}/ns/inner/mid/modules/deep.moved"
probe leaf-move bash -c "mvback ${L} ${L}.moved"
probe module-root-move bash -c "mvback ${M}/plain ${M}/plain.moved"
probe scratch-move bash -c "mkdir ${M}/scratch && mvback ${M}/scratch ${M}/scratch.moved && rmdir ${M}/scratch"
rm -f ${M}/ns/inner/mid/cfg.tmp
PROBES
}
_nested_moves="modules-move namespace-move namespace-swap nested-modules-move deep-namespace-move leaf-move module-root-move"
# The nested fixture's config bytes and hook dirs.
_nested_sums() {
    local top="${1}" g
    for g in plain ns/inner/mid ns/inner/mid/modules/deep/leaf; do
        _sums "${top}/.git/modules/${g}/config" "${top}/.git/modules/${g}/hooks"
    done
}

if [[ "${sandbox_e2e}" == "1" ]]; then
    E="${R}/e2e"
    _new_repo "${E}"
    [[ -d "${E}/.git/hooks" ]] || mkdir "${E}/.git/hooks"
    [[ -e "${E}/.git/hooks/pre-commit.sample" ]] || : >"${E}/.git/hooks/pre-commit.sample"
    # Push target inside WORKDIR (the sandbox cannot reach anything else);
    # hidden from the work tree via info/exclude.
    git_q init --bare "${E}/remote.git"
    git -C "${E}" remote add origin "${E}/remote.git"
    printf 'remote.git/\n' >>"${E}/.git/info/exclude"
    required="${E}/.git/config ${E}/.git/hooks/pre-commit.sample ${E}/remote.git/HEAD"

    echo "-- e2e: normal repo, protected"
    before="$(_sums "${E}/.git/config" "${E}/.git/hooks")"
    # unlink last: in relaxed mode the same probe would delete the config.
    _write_probe "${E}/.git" "${required}" "$(_normal_probes protected)${NL}probe unlink-config rm -f .git/config"
    out="$(_launch "${E}")"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e protected"
    _assert_normal_persisted protected "e2e protected"
    for p in git-config remote-add append-config replace-config unlink-config hook-create hooks-rename \
            gitdir-move gitdir-rmdir-swap; do
        assert_contains "${out}" "DENIED:${p}" "e2e protected: ${p} denied"
    done
    assert_eq "$(_sums "${E}/.git/config" "${E}/.git/hooks")" "${before}" "e2e protected: config bytes and hooks/ unchanged on the host"
    assert_eq "$(git -C "${E}" config --get branch.main.remote)" "" "e2e protected: push -u tracking config not written locally"
    ok=0; [[ -d "${E}/.git" && ! -e "${E}/.git.moved" && ! -e "${E}/.git.old" ]] && ok=1
    assert_eq "${ok}" "1" "e2e protected: .git still in place on the host"

    echo "-- e2e: normal repo, AI_SANDBOX_ALLOW_GIT_CONFIG=1"
    _write_probe "${E}/.git" "${required}" "$(_normal_probes relaxed)"
    out="$(_launch "${E}" AI_SANDBOX_ALLOW_GIT_CONFIG=1)"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e relaxed"
    assert_contains "${out}" "AI_SANDBOX_ALLOW_GIT_CONFIG=1" "e2e relaxed: WARN printed"
    _assert_normal_persisted relaxed "e2e relaxed"
    assert_eq "$(git -C "${E}" config --get branch.main.remote)" "origin" "e2e relaxed: push -u tracking config written (positive control)"
    for p in git-config remote-add append-config replace-config hook-create; do
        assert_contains "${out}" "WROTE:${p}" "e2e relaxed: ${p} allowed (positive control)"
    done
    for p in gitdir-move gitdir-rmdir-swap; do
        assert_contains "${out}" "DENIED:${p}" "e2e relaxed: ${p} denied (root integrity)"
    done
    assert_eq "$(git -C "${E}" config --get user.name)" "evil" "e2e relaxed: config edit persisted on the host"
    ok=0; [[ -d "${E}/.git" && ! -e "${E}/.git.moved" && ! -e "${E}/.git.old" ]] && ok=1
    assert_eq "${ok}" "1" "e2e relaxed: .git still in place on the host"
    # Restore a clean fixture config for later runs.
    git -C "${E}" config --unset user.name; git -C "${E}" remote remove evil 2>/dev/null
    git -C "${E}" config --unset-all core.fsmonitor 2>/dev/null
    git -C "${E}" config --remove-section alias 2>/dev/null
    git -C "${E}" config --remove-section branch.main 2>/dev/null
    rm -f "${E}/.git/hooks/post-checkout"
    # The relaxed hooks-rename probe moved hooks/ away; put it back.
    if [[ -d "${E}/.git/hooks.old" ]]; then
        rm -rf "${E}/.git/hooks"; mv "${E}/.git/hooks.old" "${E}/.git/hooks"
    fi

    echo "-- e2e: absent hooks/ and config.worktree (accepted residual)"
    rm -rf "${E}/.git/hooks"
    git -C "${E}" config extensions.worktreeConfig true
    before="$(_sums "${E}/.git/config")"
    _write_probe "${E}/.git" "${E}/.git/config" '
[[ -e .git/hooks ]] && echo HOOKS_PRESENT_AT_START || echo HOOKS_ABSENT_AT_START
probe hooks-create sh -c "mkdir .git/hooks && echo probe >.git/hooks/residual-probe"
probe config-worktree-create sh -c "echo probe >.git/config.worktree"
probe append-config sh -c "echo evil >>.git/config"
probe gitdir-move bash -c "ren .git .git.moved; rc=\$?; [ \"\${rc}\" = 0 ] && ren .git.moved .git; exit \${rc}"
g commit --allow-empty -m absent-run && echo COMMIT_OK
'
    out="$(_launch "${E}")"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e absent"
    assert_contains "${out}" "absent at launch" "e2e absent: WARN lists the absent entries"
    assert_contains "${out}" "HOOKS_ABSENT_AT_START" "e2e absent: wrapper did not create hooks/"
    assert_contains "${out}" "WROTE:hooks-create" "e2e absent: absent hooks/ stays creatable (documented residual)"
    assert_contains "${out}" "WROTE:config-worktree-create" "e2e absent: absent config.worktree stays creatable (documented residual)"
    assert_contains "${out}" "DENIED:append-config" "e2e absent: existing config still read-only"
    assert_contains "${out}" "DENIED:gitdir-move" "e2e absent: root still pinned"
    assert_contains "${out}" "COMMIT_OK" "e2e absent: commit works"
    assert_eq "$(_sums "${E}/.git/config")" "${before}" "e2e absent: config bytes unchanged on the host"
    rm -rf "${E}/.git/hooks" "${E}/.git/config.worktree"
    git -C "${E}" config --unset extensions.worktreeConfig

    echo "-- e2e: absent hooks/ in relaxed mode keeps the root pinned"
    _write_probe "${E}/.git" "${E}/.git/config" '
probe gitdir-move bash -c "ren .git .git.moved; rc=\$?; [ \"\${rc}\" = 0 ] && ren .git.moved .git; exit \${rc}"
probe gitdir-rmdir-swap bash -c "ren .git .git.old && mkdir .git"
probe objects-touch sh -c "touch .git/objects/probe && rm -f .git/objects/probe"
'
    out="$(_launch "${E}" AI_SANDBOX_ALLOW_GIT_CONFIG=1)"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e relaxed absent"
    assert_contains "${out}" "DENIED:gitdir-move" "e2e relaxed absent: .git rename denied"
    assert_contains "${out}" "DENIED:gitdir-rmdir-swap" "e2e relaxed absent: .git replacement denied"
    assert_contains "${out}" "WROTE:objects-touch" "e2e relaxed absent: objects/ writable (positive control)"
    mkdir "${E}/.git/hooks"

    echo "-- e2e: AI_SANDBOX_EXTRA_RW_DIRS covering WORKDIR does not reopen config"
    before="$(_sums "${E}/.git/config")"
    _write_probe "${E}/.git" "${E}/.git/config" '
probe append-config sh -c "echo evil >>.git/config"
probe hook-create sh -c "echo evil >.git/hooks/post-checkout"
probe gitdir-move bash -c "ren .git .git.moved; rc=\$?; [ \"\${rc}\" = 0 ] && ren .git.moved .git; exit \${rc}"
'
    out="$(_launch "${E}" AI_SANDBOX_EXTRA_RW_DIRS="${R}")"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e extra-rw parent"
    for p in append-config hook-create gitdir-move; do
        assert_contains "${out}" "DENIED:${p}" "e2e extra-rw parent: ${p} denied"
    done
    assert_eq "$(_sums "${E}/.git/config")" "${before}" "e2e extra-rw parent: config bytes unchanged on the host"

    echo "-- e2e: WORKDIR reached through a symlink"
    EL="${FAKE_HOME}/repos-link/e2e"
    # Linux sees the logical mount path; macOS resolves it.
    el_expect="${EL}/.git"; [[ "${OS}" == "Darwin" ]] && el_expect="${E}/.git"
    before="$(_sums "${E}/.git/config" "${E}/.git/hooks")"
    # Resolved tree also granted RW: the alias must not be writable either.
    probe_resolved="probe resolved-alias-config sh -c \"echo evil >>${E}/.git/config\""
    [[ "${OS}" == "Darwin" ]] && probe_resolved=""
    _write_probe "${el_expect}" ".git/config" "
probe append-config sh -c \"echo evil >>.git/config\"
probe hook-create sh -c \"echo evil >.git/hooks/post-checkout\"
probe gitdir-move bash -c \"ren .git .git.moved; rc=\\\$?; [ \\\"\\\${rc}\\\" = 0 ] && ren .git.moved .git; exit \\\${rc}\"
${probe_resolved}
g commit --allow-empty -m via-link && echo COMMIT_OK
"
    out="$(_launch "${EL}" AI_SANDBOX_EXTRA_RW_DIRS="${R}")"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e symlinked cwd"
    [[ -n "${probe_resolved}" ]] && assert_contains "${out}" "DENIED:resolved-alias-config" "e2e symlinked cwd: resolved-path alias (extra RW dir) denied"
    for p in append-config hook-create gitdir-move; do
        assert_contains "${out}" "DENIED:${p}" "e2e symlinked cwd: ${p} denied"
    done
    assert_contains "${out}" "COMMIT_OK" "e2e symlinked cwd: commit works"
    assert_eq "$(_sums "${E}/.git/config" "${E}/.git/hooks")" "${before}" "e2e symlinked cwd: config and hooks/ unchanged on the host"

    echo "-- e2e: AI_SANDBOX_EXTRA_RO_DIRS on .git is not reopened by the pin"
    ro_list="${E}/.git"; [[ "${OS}" == "Darwin" ]] && ro_list="${FAKE_HOME}/bin,${E}/.git"
    _write_probe "${E}/.git" "${E}/.git/config" '
probe append-config sh -c "echo evil >>.git/config"
probe hook-create sh -c "echo evil >.git/hooks/post-checkout"
probe gitdir-file sh -c "echo x >.git/probe-file"
'
    out="$(cd "${E}" && AI_SANDBOX_EXTRA_RO_DIRS="${ro_list}" AI_SANDBOX_ALLOW_GIT_CONFIG=1 \
        bash "${REPO_ROOT}/bin/executable_codex_wrapper.bash" x </dev/null 2>&1)"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e extra-ro .git (relaxed)"
    for p in append-config hook-create gitdir-file; do
        assert_contains "${out}" "DENIED:${p}" "e2e extra-ro .git (relaxed): ${p} denied"
    done
    rm -f "${E}/.git/probe-file" "${E}/.git/hooks/post-checkout"

    echo "-- e2e: linked worktree pointer"
    git_q -C "${E}" worktree add "${R}/e2e-wt" -b e2e-wt
    W="${R}/e2e-wt"
    entry="$(cd "${E}/.git/worktrees/e2e-wt" && pwd -P)"
    for mode in 0 1; do
        before="$(_sums "${W}/.git")"
        _write_probe "${entry}" "${W}/.git" '
probe pointer-append sh -c "echo gitdir: /tmp/evil >>.git"
probe pointer-replace bash -c "echo gitdir: /tmp/evil >ptr.tmp && ren ptr.tmp .git"
probe pointer-unlink rm -f .git
g commit --allow-empty -m wt-run && echo COMMIT_OK
'
        out="$(_launch "${W}" AI_SANDBOX_ALLOW_GIT_CONFIG="${mode}")"; rc=$?
        _assert_ran "${out}" "${rc}" "e2e worktree ALLOW_GIT_CONFIG=${mode}"
        for p in pointer-append pointer-replace pointer-unlink; do
            assert_contains "${out}" "DENIED:${p}" "e2e worktree ALLOW_GIT_CONFIG=${mode}: ${p} denied"
        done
        assert_contains "${out}" "COMMIT_OK" "e2e worktree ALLOW_GIT_CONFIG=${mode}: commit works"
        assert_eq "$(_sums "${W}/.git")" "${before}" "e2e worktree ALLOW_GIT_CONFIG=${mode}: pointer bytes unchanged on the host"
        rm -f "${W}/ptr.tmp"
    done

    echo "-- e2e: bare repository"
    EB="${R}/e2e-bare.git"
    rm -rf "${EB}"; git_q clone --bare "${E}" "${EB}"
    [[ -d "${EB}/hooks" ]] || mkdir "${EB}/hooks"
    before="$(_sums "${EB}/config" "${EB}/hooks")"
    _write_probe "${EB}" "${EB}/config ${EB}/hooks" '
g branch bare-side main && echo BRANCH_OK
probe append-config sh -c "echo evil >>config"
probe git-config g config user.name evil
probe hook-create sh -c "echo evil >hooks/post-receive"
'
    out="$(_launch "${EB}")"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e bare"
    assert_contains "${out}" "BRANCH_OK" "e2e bare: ref update works"
    for p in append-config git-config hook-create; do
        assert_contains "${out}" "DENIED:${p}" "e2e bare: ${p} denied"
    done
    assert_eq "$(_sums "${EB}/config" "${EB}/hooks")" "${before}" "e2e bare: config and hooks/ unchanged on the host"
    ok=0; git -C "${EB}" rev-parse -q --verify bare-side >/dev/null && ok=1
    assert_eq "${ok}" "1" "e2e bare: branch persisted on the host"

    echo "-- e2e: nested submodules, protected (#12)"
    EN="${R}/e2e-nested"
    _new_nested_super "${EN}"
    ENM="${EN}/.git/modules"
    rm -rf "${ENM}/plain/hooks"
    nested_required="${ENM}/ns/inner/mid/modules/deep/leaf/config ${ENM}/ns/inner/mid/modules/deep/leaf/hooks ${ENM}/ns/inner/mid/config ${ENM}/plain/HEAD ${EN}/plain/.git ${EN}/ns/inner/mid/deep/leaf/.git"
    before="$(_nested_sums "${EN}" 2>&1)"
    _write_probe "${EN}/.git" "${nested_required}" '
[[ -e .git/modules/plain/hooks ]] && echo PLAIN_HOOKS_PRESENT_AT_START || echo PLAIN_HOOKS_ABSENT_AT_START
'"$(_nested_probes protected)"'
probe plain-hooks-create sh -c "mkdir .git/modules/plain/hooks && echo probe >.git/modules/plain/hooks/residual-probe"
'
    out="$(_launch "${EN}")"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e nested protected"
    assert_contains "${out}" "SUB_COMMIT_OK" "e2e nested protected: submodule commit works"
    assert_contains "${out}" "LEAF_COMMIT_OK" "e2e nested protected: nested submodule commit works"
    assert_eq "$(git -C "${EN}/plain" log --format=%s -1)" "sub-protected" "e2e nested protected: submodule commit persisted on the host"
    assert_eq "$(git -C "${EN}/ns/inner/mid/deep/leaf" log --format=%s -1)" "leaf-protected" "e2e nested protected: nested submodule commit persisted on the host"
    for p in leaf-config-append mid-config-replace leaf-hook-create ${_nested_moves}; do
        assert_contains "${out}" "DENIED:${p}" "e2e nested protected: ${p} denied"
    done
    assert_contains "${out}" "WROTE:scratch-move" "e2e nested protected: new dirs below modules/ still movable (positive control)"
    assert_contains "${out}" "PLAIN_HOOKS_ABSENT_AT_START" "e2e nested protected: wrapper did not create the absent submodule hooks/"
    assert_contains "${out}" "${ENM}/plain/hooks/" "e2e nested protected: absent submodule hooks/ WARNed"
    assert_contains "${out}" "WROTE:plain-hooks-create" "e2e nested protected: absent submodule hooks/ stays creatable (documented residual)"
    rm -rf "${ENM}/plain/hooks"
    assert_eq "$(_nested_sums "${EN}" 2>&1)" "${before}" "e2e nested protected: submodule config bytes and hooks/ unchanged on the host"
    ok=0; [[ -d "${ENM}/ns/inner/mid/modules/deep/leaf" && ! -e "${ENM}/ns.moved" && ! -e "${ENM}/ns/inner.old" && ! -e "${EN}/.git/modules.moved" ]] && ok=1
    assert_eq "${ok}" "1" "e2e nested protected: module tree still in place on the host"
    mkdir "${ENM}/plain/hooks"

    echo "-- e2e: nested submodules, AI_SANDBOX_ALLOW_GIT_CONFIG=1"
    saved="${R}/e2e-nested-saved"; rm -rf "${saved}"; mkdir -p "${saved}"
    cp "${ENM}/ns/inner/mid/config" "${saved}/mid"; cp "${ENM}/ns/inner/mid/modules/deep/leaf/config" "${saved}/leaf"
    _write_probe "${EN}/.git" "${nested_required}" "$(_nested_probes relaxed)"
    out="$(_launch "${EN}" AI_SANDBOX_ALLOW_GIT_CONFIG=1)"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e nested relaxed"
    assert_contains "${out}" "LEAF_COMMIT_OK" "e2e nested relaxed: nested submodule commit works"
    assert_eq "$(git -C "${EN}/ns/inner/mid/deep/leaf" log --format=%s -1)" "leaf-relaxed" "e2e nested relaxed: nested commit persisted on the host"
    for p in leaf-config-append mid-config-replace leaf-hook-create; do
        assert_contains "${out}" "WROTE:${p}" "e2e nested relaxed: ${p} allowed (positive control)"
    done
    for p in ${_nested_moves}; do
        assert_contains "${out}" "DENIED:${p}" "e2e nested relaxed: ${p} denied (chain integrity)"
    done
    ok=0; grep -q evil "${ENM}/ns/inner/mid/modules/deep/leaf/config" && ok=1
    assert_eq "${ok}" "1" "e2e nested relaxed: nested config edit persisted on the host"
    cp "${saved}/mid" "${ENM}/ns/inner/mid/config"; cp "${saved}/leaf" "${ENM}/ns/inner/mid/modules/deep/leaf/config"
    rm -rf "${saved}" "${ENM}/ns/inner/mid/modules/deep/leaf/hooks/post-commit"

    echo "-- e2e: nested submodules through a symlinked WORKDIR and a resolved-path RW alias"
    ENL="${FAKE_HOME}/repos-link/e2e-nested"
    enl_expect="${ENL}/.git"; [[ "${OS}" == "Darwin" ]] && enl_expect="${EN}/.git"
    before="$(_nested_sums "${EN}" 2>&1)"
    alias_probe="probe resolved-alias-leaf-config sh -c \"echo evil >>${ENM}/ns/inner/mid/modules/deep/leaf/config\""
    alias_probe+="${NL}probe resolved-alias-namespace-move bash -c \"mvback ${ENM}/ns ${ENM}/ns.moved\""
    [[ "${OS}" == "Darwin" ]] && alias_probe=""
    _write_probe "${enl_expect}" ".git/modules/ns/inner/mid/modules/deep/leaf/config" "$(_nested_probes alias)${NL}${alias_probe}"
    out="$(_launch "${ENL}" AI_SANDBOX_EXTRA_RW_DIRS="${R}")"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e nested symlinked cwd"
    for p in leaf-config-append mid-config-replace leaf-hook-create ${_nested_moves}; do
        assert_contains "${out}" "DENIED:${p}" "e2e nested symlinked cwd: ${p} denied"
    done
    if [[ -n "${alias_probe}" ]]; then
        assert_contains "${out}" "DENIED:resolved-alias-leaf-config" "e2e nested symlinked cwd: resolved-path alias config write denied"
        assert_contains "${out}" "DENIED:resolved-alias-namespace-move" "e2e nested symlinked cwd: resolved-path alias namespace move denied"
    fi
    assert_contains "${out}" "LEAF_COMMIT_OK" "e2e nested symlinked cwd: nested submodule commit works"
    assert_eq "$(_nested_sums "${EN}" 2>&1)" "${before}" "e2e nested symlinked cwd: submodule config bytes and hooks/ unchanged on the host"

    echo "-- e2e: non-repo scaffolding"
    ES="${R}/e2e-scaffold"
    rm -rf "${ES}"; mkdir -p "${ES}"
    _write_probe "" "" '
g init -q && g commit --allow-empty -m scaffold && echo INIT_OK
'
    out="$(_launch "${ES}")"; rc=$?
    _assert_ran "${out}" "${rc}" "e2e scaffold"
    assert_contains "${out}" "not in a git repository" "e2e scaffold: new-metadata WARN printed"
    assert_contains "${out}" "INIT_OK" "e2e scaffold: git init and commit work"
    assert_eq "$(git -C "${ES}" log --format=%s -1 2>&1)" "scaffold" "e2e scaffold: new repo persisted on the host"

    # Negative control (unconfined, any backend): the probe stops before
    # any write when discovery finds another repo.
    _write_probe "${E}/.git" "" 'probe should-not-run true'
    out="$(cd "${EB}" && bash "${FAKE_HOME}/bin/codex" 2>&1)"; rc=$?
    assert_eq "${rc}" "3" "probe control: wrong repo exits 3"
    assert_not_contains "${out}" "WROTE:" "probe control: wrong repo runs no probe"
fi
install_live_client_trap "${FAKE_HOME}/bin/codex"

assert_no_live_client_reached
tests_summary_and_exit
