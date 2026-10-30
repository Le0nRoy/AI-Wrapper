#!/bin/bash
# Regression tests for wrapper-side RW binds whose source path can be
# influenced by untrusted input:
#   - the git-worktree common-dir bind (_wrapper_bind_git_common_dir): the
#     common dir comes from the WORKDIR's `.git` file / `commondir`, so a
#     crafted checkout must not get ~/.ssh, $HOME, /etc or an unrelated repo
#     bound RW
#   - account/config dirs (~/.codex, ~/.codex-<name>, ~/.claude.json) that
#     are symlinks to outside $HOME or into credential dirs
#   - per-workdir preset values flowing into binds (CODEX_ACCOUNT,
#     AI_SANDBOX_EXTRA_RW_DIRS)
#   - the shared sensitive-dir classifier _sandbox_sensitive_dir_kind
# See tests/test_sandbox_common.bash for the FAKE_HOME rationale.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
OUTSIDE="$(mktemp -d)"
isolate_test_env "${FAKE_HOME}"
cleanup() { rm -rf "${FAKE_HOME}" "${OUTSIDE}"; }
trap cleanup EXIT

OS="$(uname -s)"
NL=$'\n'

_load() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/bin/ai_wrapper_data/${1}_wrapper_lib.bash"
}

echo "== bind hardening tests (${OS}) =="

# ---------------------------------------------------------------------------
echo "-- _sandbox_sensitive_dir_kind"
_kind() { ( _load codex; _sandbox_sensitive_dir_kind "${1}" "${FAKE_HOME}" ); }
assert_eq "$(_kind /etc)" "system" "/etc is a system location"
assert_eq "$(_kind /)" "system" "/ is a system location"
assert_eq "$(_kind "${FAKE_HOME}")" "home" "\$HOME itself"
assert_eq "$(_kind "${FAKE_HOME}/")" "home" "\$HOME with trailing slash"
assert_eq "$(_kind "${FAKE_HOME}/.ssh")" "dotfile" "\$HOME/.ssh is under a dotfile dir"
assert_eq "$(_kind "${FAKE_HOME}/.local/share/x/.git")" "dotfile" "anything below a \$HOME dotfile dir"
assert_eq "$(_kind "${FAKE_HOME}/projects/x/.git")" "" "a normal project .git is not sensitive"

# ---------------------------------------------------------------------------
echo "-- git common-dir bind validation"
if command -v git >/dev/null 2>&1; then
    git_q() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
    # Make DIR look like a git dir so git accepts it as a commondir.
    _fake_gitdir() { mkdir -p "${1}/objects" "${1}/refs/heads"; echo 'ref: refs/heads/main' >"${1}/HEAD"; }
    # Craft an untrusted checkout at WORKDIR whose .git file points at a
    # gitdir inside WORKDIR whose `commondir` names TARGET.
    _crafted_repo() {
        local wd="${1}" target="${2}"
        rm -rf "${wd}"; mkdir -p "${wd}/.g/wt"
        echo 'ref: refs/heads/main' >"${wd}/.g/wt/HEAD"
        printf '%s\n' "${target}" >"${wd}/.g/wt/commondir"
        printf 'gitdir: %s\n' "${wd}/.g/wt" >"${wd}/.git"
    }
    # Run the bind in WORKDIR; print WRAPPER_FLAGS then stderr.
    _gitbind() { ( set -u; cd "${1}" && _load codex; WRAPPER_FLAGS=(); _wrapper_bind_git_common_dir; printf '%s\n' "${WRAPPER_FLAGS[@]}" ) 2>&1; }

    # Legit worktree: still bound.
    git_q init "${FAKE_HOME}/repos/main"
    git_q -C "${FAKE_HOME}/repos/main" commit --allow-empty -m init
    git_q -C "${FAKE_HOME}/repos/main" worktree add "${FAKE_HOME}/repos/wt" -b wt
    out="$(_gitbind "${FAKE_HOME}/repos/wt")"
    assert_contains "${out}" "--bind${NL}${FAKE_HOME}/repos/main/.git" "legit worktree: shared .git bound"
    assert_not_contains "${out}" "WARN" "legit worktree: no WARN"
    mg="${FAKE_HOME}/repos/main/.git"
    for ro in config hooks worktrees worktrees/wt/commondir worktrees/wt/gitdir; do
        assert_contains "${out}" "--ro-bind${NL}${mg}/${ro}${NL}" "legit worktree: ${ro} over-mounted read-only"
    done
    assert_contains "${out}" "--bind${NL}${mg}/worktrees/wt${NL}" "legit worktree: own worktree entry RW"
    if [[ "${OS}" == "Linux" ]]; then
        # Order matters for bwrap (later mount wins): RW common first,
        # RO worktrees/ before the RW own entry, RO links last.
        order="$(printf '%s\n' "${out}" | grep -n -x -e "${mg}" -e "${mg}/worktrees" -e "${mg}/worktrees/wt" -e "${mg}/worktrees/wt/gitdir" | awk -F: 'NR%2==1{print $2}' | tr '\n' ' ')"
        assert_eq "${order}" "${mg} ${mg}/worktrees ${mg}/worktrees/wt ${mg}/worktrees/wt/gitdir " "legit worktree: bind order RW, RO, RW, RO"
    fi

    # Borrowed worktree entry: an untrusted checkout's .git file points at
    # an EXISTING worktree entry of another repo. Forward link holds; the
    # reverse link (<entry>/gitdir) names the real worktree, not this one.
    rm -rf "${FAKE_HOME}/repos/evil"; mkdir -p "${FAKE_HOME}/repos/evil"
    printf 'gitdir: %s\n' "${mg}/worktrees/wt" >"${FAKE_HOME}/repos/evil/.git"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "--bind" "borrowed worktree entry: not bound"
    assert_contains "${out}" "belongs to ${FAKE_HOME}/repos/wt/.git" "... rejected by the reverse-link rule"

    # Subdirectory of a legit worktree still binds.
    mkdir -p "${FAKE_HOME}/repos/wt/sub"
    out="$(_gitbind "${FAKE_HOME}/repos/wt/sub")"
    assert_contains "${out}" "--bind${NL}${mg}${NL}" "legit worktree subdirectory: shared .git bound"

    # A symlink among the over-mount targets aborts the bind.
    mv "${mg}/hooks" "${mg}/hooks.real"; ln -s "${FAKE_HOME}/.ssh" "${mg}/hooks"
    out="$(_gitbind "${FAKE_HOME}/repos/wt")"
    assert_not_contains "${out}" "--bind" "symlinked hooks/: common dir not bound"
    assert_contains "${out}" "is a symlink" "... with symlink WARN"
    rm -f "${mg}/hooks"; mv "${mg}/hooks.real" "${mg}/hooks"

    # Missing hooks/ is created (so it can be over-mounted RO).
    rm -rf "${mg}/hooks"
    out="$(_gitbind "${FAKE_HOME}/repos/wt")"
    hooks_made=0; [[ -d "${mg}/hooks" ]] && hooks_made=1
    assert_eq "${hooks_made}" "1" "missing hooks/ is created before binding"

    # extensions.worktreeConfig: config.worktree pre-created and RO.
    git -C "${FAKE_HOME}/repos/main" config extensions.worktreeConfig true
    out="$(_gitbind "${FAKE_HOME}/repos/wt")"
    cw_made=0; [[ -f "${mg}/worktrees/wt/config.worktree" ]] && cw_made=1
    assert_eq "${cw_made}" "1" "worktreeConfig: config.worktree pre-created"
    assert_contains "${out}" "--ro-bind${NL}${mg}/worktrees/wt/config.worktree" "worktreeConfig: config.worktree RO"
    git -C "${FAKE_HOME}/repos/main" config --unset extensions.worktreeConfig
    rm -f "${mg}/worktrees/wt/config.worktree"

    # Submodule git dirs: config RO; a missing hooks/ is no longer created
    # on the host (#12) but reported absent.
    mkdir -p "${mg}/modules/sub1"; : >"${mg}/modules/sub1/config"
    out="$(_gitbind "${FAKE_HOME}/repos/wt")"
    assert_contains "${out}" "--ro-bind${NL}${mg}/modules/sub1/config" "submodule config RO"
    hooks_made=0; [[ -e "${mg}/modules/sub1/hooks" ]] && hooks_made=1
    assert_eq "${hooks_made}" "0" "submodule: missing hooks/ not created on the host"
    assert_contains "${out}" "absent at launch" "submodule: missing hooks/ reported absent"
    assert_contains "${out}" "${mg}/modules/sub1/hooks/" "... naming it"
    mkdir "${mg}/modules/sub1/hooks"
    out="$(_gitbind "${FAKE_HOME}/repos/wt")"
    assert_contains "${out}" "--ro-bind${NL}${mg}/modules/sub1/hooks" "submodule hooks/ RO when present"
    rm -rf "${mg}/modules"

    # Crafted commondir -> ~/.ssh (made git-dir shaped so git accepts it).
    _fake_gitdir "${FAKE_HOME}/.ssh"
    _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}/.ssh"
    sanity="$(cd "${FAKE_HOME}/repos/evil" && git rev-parse --git-common-dir 2>/dev/null)"
    assert_eq "${sanity}" "${FAKE_HOME}/.ssh" "sanity: crafted repo makes git report ~/.ssh as common dir"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "--bind" "commondir -> ~/.ssh: not bound"
    assert_contains "${out}" "WARN" "commondir -> ~/.ssh: WARN printed"
    assert_contains "${out}" "sensitive location" "... naming the reason"

    # Crafted commondir -> $HOME.
    _fake_gitdir "${FAKE_HOME}"
    _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "--bind" "commondir -> \$HOME: not bound"
    assert_contains "${out}" "not strictly under" "... rejected as not strictly under \$HOME"
    rm -rf "${FAKE_HOME}/objects" "${FAKE_HOME}/refs" "${FAKE_HOME}/HEAD"

    # Crafted commondir -> outside $HOME.
    _fake_gitdir "${OUTSIDE}/.git"
    _crafted_repo "${FAKE_HOME}/repos/evil" "${OUTSIDE}/.git"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "--bind" "commondir outside \$HOME: not bound"

    # Crafted commondir -> another real repo's .git (under $HOME, right
    # shape) — rejected because WORKDIR isn't one of its worktrees.
    git_q init "${FAKE_HOME}/repos/private"
    _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}/repos/private/.git"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "--bind" "commondir -> unrelated repo's .git: not bound"
    assert_contains "${out}" "is not a worktree of it" "... rejected by the worktree back-link rule"

    # Crafted commondir -> git-shaped dir not named .git / *.git.
    _fake_gitdir "${FAKE_HOME}/data/stuff"
    _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}/data/stuff"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "--bind" "commondir with wrong basename: not bound"

    # A submodule worktree uses <superproject>/.git/modules/<name> as its
    # common dir. This specific nested layout under ~/.local/share is valid
    # when Git's worktree entry and reverse link both prove ownership.
    nested_parent="${FAKE_HOME}/.local/share/chezmoi"
    nested_source="${FAKE_HOME}/repos/module-source"
    nested_wt="${FAKE_HOME}/repos/module-worktree"
    git_q init "${nested_parent}"
    git_q -C "${nested_parent}" commit --allow-empty -m parent-init
    git_q init "${nested_source}"
    git_q -C "${nested_source}" commit --allow-empty -m module-init
    git -c init.defaultBranch=main -c user.name=t -c user.email=t@t \
        -c protocol.file.allow=always -C "${nested_parent}" \
        submodule add "${nested_source}" ai-wrapper >/dev/null 2>&1
    git_q -C "${nested_parent}" add .
    git_q -C "${nested_parent}" commit -m add-module
    git_q -C "${nested_parent}/ai-wrapper" worktree add "${nested_wt}" -b module-wt
    nested_common="$(git -C "${nested_wt}" rev-parse --git-common-dir)"
    nested_entry="$(git -C "${nested_wt}" rev-parse --absolute-git-dir)"
    out="$(_gitbind "${nested_wt}")"
    assert_contains "${out}" "--bind${NL}${nested_common}${NL}" "nested submodule worktree: parent .git/modules metadata bound"
    assert_not_contains "${out}" "WARN" "nested submodule worktree: validated links accepted"
    assert_contains "${out}" "--ro-bind${NL}${nested_common}/config${NL}" "nested submodule worktree: common config stays read-only"
    assert_contains "${out}" "--ro-bind${NL}${nested_common}/hooks${NL}" "nested submodule worktree: common hooks stay read-only"
    assert_contains "${out}" "--bind${NL}${nested_entry}${NL}" "nested submodule worktree: own worktree entry stays writable"

    # Crafted commondir via a symlink inside WORKDIR -> ~/.ssh: the
    # resolved target is what's checked (and would be bound).
    _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}/repos/evil/link.git"
    ln -s "${FAKE_HOME}/.ssh" "${FAKE_HOME}/repos/evil/link.git"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "--bind" "commondir symlink -> ~/.ssh: not bound"

    # Unit checks of the validator itself.
    _ok() { ( _load codex; _wrapper_git_common_dir_ok "${1}" "${FAKE_HOME}" "${2:-${FAKE_HOME}/repos/wt}" ); }
    _ok "${FAKE_HOME}/repos/main/.git" >/dev/null
    assert_eq "$?" "0" "validator accepts the legit common dir"
    _ok /etc >/dev/null
    assert_eq "$?" "1" "validator rejects /etc"
    mkdir -p "${FAKE_HOME}/repos/nogit/.git"
    _ok "${FAKE_HOME}/repos/nogit/.git" >/dev/null
    assert_eq "$?" "1" "validator rejects a .git without HEAD/objects/refs"

    # Submodule common-dir relaxation: only the verified
    # ~/.local/share/<repo>/.git/modules/<name> layout may skip the
    # sensitive-location and basename rules.
    _ok "${nested_common}" "${nested_wt}" >/dev/null
    assert_eq "$?" "0" "validator accepts a verified submodule worktree common dir"
    _fake_gitdir() { mkdir -p "${1}/objects" "${1}/refs" && : >"${1}/HEAD" && : >"${1}/config"; }
    share="${FAKE_HOME}/.local/share"
    _fake_gitdir "${share}/noparent/.git/modules/m"
    out="$(_ok "${share}/noparent/.git/modules/m")"
    assert_contains "${out}" "sensitive location" "submodule: parent .git without HEAD/objects/refs rejected"
    _fake_gitdir "${FAKE_HOME}/repos/realparent/.git/modules/m"
    _fake_gitdir "${FAKE_HOME}/repos/realparent/.git"
    mkdir -p "${share}/symparent"
    ln -s "${FAKE_HOME}/repos/realparent/.git" "${share}/symparent/.git"
    out="$(_ok "${share}/symparent/.git/modules/m")"
    assert_contains "${out}" "sensitive location" "submodule: symlinked parent .git rejected"
    _fake_gitdir "${share}/sup/.git"
    for bad in foo.git .git a/b; do
        _fake_gitdir "${share}/sup/.git/modules/${bad}"
        out="$(_ok "${share}/sup/.git/modules/${bad}")"
        assert_contains "${out}" "sensitive location" "submodule: modules/${bad} rejected"
    done
    out="$(_ok "${FAKE_HOME}/repos/realparent/.git/modules/m")"
    assert_contains "${out}" "basename 'm'" "submodule: modules/<name> outside ~/.local/share rejected"

    # End-to-end through the codex wrapper (bwrap on Linux, native
    # sandbox-exec on macOS): a legit worktree can commit / branch /
    # checkout inside the sandbox, but every way of changing hooks/,
    # config, another worktree's entry or its own link files fails and the
    # protected bytes are unchanged on the host. On macOS a missing
    # sandbox-exec is a failure, not a skip: this block is the native
    # certification of the Seatbelt write-deny rules.
    # Probe client for the e2e block below, written to DEST. ALIAS_COMMON
    # is an optional alias path of the common dir. Before any write the stub
    # proves it found the fixture: git discovery must succeed and name
    # exactly the expected common dir and own entry, every probe target must
    # exist and the entry's links must point back. Otherwise it prints
    # SETUP_FAILED and exits 3, so an empty or wrong path can never turn
    # into a DENIED (or rm -f into a WROTE) on an unrelated path.
    _write_probe_stub() {
        local dest="${1}" alias_common="${2}"
        {
            printf '#!/bin/bash\nalias_common=%q\nexpect_m=%q\nexpect_w=%q\nexpect_wt_git=%q\n' \
                "${alias_common}" "${mg}" "${mg}/worktrees/wt" "${FAKE_HOME}/repos/wt/.git"
            cat <<'STUB'
setup_failed() { echo "SETUP_FAILED: $*"; exit 3; }
m="$(git rev-parse --git-common-dir 2>&1)" || setup_failed "git rev-parse --git-common-dir: ${m}"
w="$(git rev-parse --absolute-git-dir 2>&1)" || setup_failed "git rev-parse --absolute-git-dir: ${w}"
[[ -n "${m}" && -n "${w}" ]] || setup_failed "empty git dirs (common='${m}' own='${w}')"
m="$(cd "${m}" 2>&1 && pwd -P)" || setup_failed "cannot enter common dir: ${m}"
[[ "${m}" == "${expect_m}" && "${w}" == "${expect_w}" ]] \
    || setup_failed "discovered common='${m}' own='${w}', expected '${expect_m}' '${expect_w}'"
for p in config hooks/pre-commit.sample modules/sub1/hooks modules/sub1/config objects refs logs/HEAD \
        worktrees/wt2/commondir worktrees/wt2/HEAD; do
    [[ -e "${m}/${p}" ]] || setup_failed "missing ${m}/${p}"
done
[[ "$(cat "${w}/gitdir" 2>&1)" == "${expect_wt_git}" ]] || setup_failed "${w}/gitdir does not point back to ${expect_wt_git}"
[[ "$(cd "${w}/$(cat "${w}/commondir")" 2>&1 && pwd -P)" == "${m}" ]] || setup_failed "${w}/commondir does not resolve to ${m}"
echo DISCOVERY_OK
g() { git -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
echo x >file && g add file && g commit -m sandboxed && echo COMMIT_OK
g branch side && echo BRANCH_OK
g checkout -b feature && g checkout wt && echo CHECKOUT_OK
# rename(2) without mv's cross-device copy+delete fallback, which under
# bwrap would delete files from the (writable) source instead of failing.
ren() { perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$@"; }
export -f ren
probe() { local name="${1}"; shift; if ("$@") >/dev/null 2>&1; then echo "WROTE:${name}"; else echo "DENIED:${name}"; fi; }
probe append-config sh -c 'echo evil >>"$1"' _ "${m}/config"
probe truncate-config sh -c ': >"$1"' _ "${m}/config"
probe replace-config bash -c 'echo evil >cfg.tmp && ren cfg.tmp "$1"' _ "${m}/config"
probe unlink-config sh -c 'rm -f "$1" && [ ! -e "$1" ]' _ "${m}/config"
probe symlink-config sh -c 'ln -sf "$1" cfg-link && echo evil >>cfg-link' _ "${m}/config"
probe hardlink-config sh -c 'ln -f "$1" cfg-hard && echo evil >>cfg-hard' _ "${m}/config"
[[ -n "${alias_common}" ]] && probe alias-config sh -c 'echo evil >>"$1"' _ "${alias_common}/config"
probe hook-create sh -c 'echo evil >"$1"' _ "${m}/hooks/post-commit"
probe hook-mkdir mkdir "${m}/hooks/sub"
probe hook-chmod chmod +x "${m}/hooks/pre-commit.sample"
probe hooks-rename ren "${m}/hooks" "${m}/hooks.old"
probe hooks-recreate sh -c 'rm -rf "$1" && mkdir "$1" && echo evil >"$1/post-commit"' _ "${m}/hooks"
probe submodule-hook-dance bash -c 'ren "$1/modules/sub1" "$1/objects/sub1-moved"; echo evil >"$1/objects/sub1-moved/hooks/post-commit"; rc=$?; ren "$1/objects/sub1-moved" "$1/modules/sub1"; exit "${rc}"' _ "${m}"
probe wt2-commondir sh -c 'echo evil >>"$1"' _ "${m}/worktrees/wt2/commondir"
probe wt2-head sh -c 'echo evil >"$1"' _ "${m}/worktrees/wt2/HEAD"
probe worktrees-newentry mkdir "${m}/worktrees/newentry"
probe own-commondir sh -c 'echo evil >>"$1"' _ "${w}/commondir"
probe own-gitdir sh -c 'echo evil >>"$1"' _ "${w}/gitdir"
probe own-entry-dance bash -c 'ren "$1" "$2/objects/wt-moved" && echo evil >>"$2/objects/wt-moved/commondir"; rc=$?; ren "$2/objects/wt-moved" "$1"; exit "${rc}"' _ "${w}" "${m}"
probe objects-touch sh -c 'touch "$1/objects/probe" && rm -f "$1/objects/probe"' _ "${m}"
probe refs-touch sh -c 'mkdir -p "$1/refs/probe" && rmdir "$1/refs/probe"' _ "${m}"
probe logs-touch touch "${m}/logs/HEAD"
probe own-entry-file sh -c 'touch "$1/probe" && rm -f "$1/probe"' _ "${w}"
echo PROBES_DONE
STUB
        } >"${dest}"
        chmod +x "${dest}"
    }

    # Negative controls (any OS, unconfined): the same stub where discovery
    # fails or finds a different repo must stop before any probe or write.
    _write_probe_stub "${OUTSIDE}/probe-stub" ""
    nogit_dir="$(mktemp -d)"
    out="$(cd "${nogit_dir}" && GIT_CEILING_DIRECTORIES="${nogit_dir%/*}" bash "${OUTSIDE}/probe-stub" 2>&1)"; rc=$?
    rmdir "${nogit_dir}"
    assert_eq "${rc}" "3" "probe stub: failed git discovery exits 3"
    assert_contains "${out}" "SETUP_FAILED: git rev-parse" "probe stub: failed git discovery reported"
    assert_not_contains "${out}" "WROTE:" "probe stub: failed discovery runs no probe (WROTE)"
    assert_not_contains "${out}" "DENIED:" "probe stub: failed discovery runs no probe (DENIED)"
    private_cfg="$(cksum <"${FAKE_HOME}/repos/private/.git/config")"
    out="$(cd "${FAKE_HOME}/repos/private" && bash "${OUTSIDE}/probe-stub" 2>&1)"; rc=$?
    assert_eq "${rc}" "3" "probe stub: discovery of another repo exits 3"
    assert_contains "${out}" "SETUP_FAILED: discovered" "probe stub: wrong repo reported with the paths found"
    assert_not_contains "${out}" "DENIED:" "probe stub: wrong repo runs no probe"
    assert_not_contains "${out}" "COMMIT_OK" "probe stub: wrong repo runs no git write"
    assert_eq "$(cksum <"${FAKE_HOME}/repos/private/.git/config")" "${private_cfg}" "probe stub: wrong repo config untouched"
    rm -f "${OUTSIDE}/probe-stub"

    sandbox_e2e=0
    if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
        sandbox_e2e=1
    elif [[ "${OS}" == "Darwin" ]]; then
        if command -v sandbox-exec >/dev/null 2>&1; then
            sandbox_e2e=1
        else
            _test_report 0 "e2e legit worktree: sandbox-exec available on macOS"
        fi
    fi
    if [[ "${sandbox_e2e}" == "1" ]]; then
        git_q -C "${FAKE_HOME}/repos/main" worktree add "${FAKE_HOME}/repos/wt2" -b wt2
        # Every protected path exists before the snapshot, so wrapper
        # setup (which creates a missing hooks/) cannot change it.
        mkdir -p "${mg}/modules/sub1/hooks" "${FAKE_HOME}/bin"
        : >"${mg}/modules/sub1/config"
        [[ -e "${mg}/hooks/pre-commit.sample" ]] || : >"${mg}/hooks/pre-commit.sample"
        # Host-side alias of the common dir through /tmp (itself a symlink
        # to /private/tmp on macOS). /tmp is a private tmpfs under bwrap, so
        # only the macOS run can follow it.
        alias_dir=""
        if [[ "${OS}" == "Darwin" ]]; then
            alias_dir="$(mktemp -d /tmp/ai-wrapper-alias.XXXXXX)"
            ln -s "${mg}" "${alias_dir}/common"
        fi
        _protected_sums() {
            local f
            for f in config worktrees/wt/commondir worktrees/wt/gitdir worktrees/wt2/commondir worktrees/wt2/HEAD; do
                printf '%s ' "${f}"; cksum <"${mg}/${f}" 2>&1
            done
            ls -A "${mg}/hooks" "${mg}/modules/sub1/hooks" 2>&1
        }
        sums_before="$(_protected_sums)"
        assert_not_contains "${sums_before}" "No such file" "e2e legit worktree: fixture has every protected path before the run"
        _write_probe_stub "${FAKE_HOME}/bin/codex" "${alias_dir:+${alias_dir}/common}"
        # macOS: ~/bin is not on the base read allowlist, so expose the stub
        # through the RO extra-dir setting (it gets the same deny rules).
        stub_ro_dirs=""
        [[ "${OS}" == "Darwin" ]] && stub_ro_dirs="${FAKE_HOME}/bin"
        out="$(cd "${FAKE_HOME}/repos/wt" && PATH="${FAKE_HOME}/bin:${PATH}" \
            AI_SANDBOX_EXTRA_RO_DIRS="${stub_ro_dirs}" \
            bash "${REPO_ROOT}/bin/executable_codex_wrapper.bash" x </dev/null 2>&1)"
        rc=$?
        echo "  (e2e legit worktree output: ${out})"
        assert_eq "${rc}" "0" "e2e legit worktree: probe client exits 0"
        assert_contains "${out}" "DISCOVERY_OK" "e2e legit worktree: probe found the fixture git dirs"
        assert_not_contains "${out}" "SETUP_FAILED" "e2e legit worktree: no probe setup failure"
        assert_contains "${out}" "PROBES_DONE" "e2e legit worktree: probe client ran to the end"
        for ok in COMMIT_OK BRANCH_OK CHECKOUT_OK; do
            assert_contains "${out}" "${ok}" "e2e legit worktree: ${ok}"
        done
        for p in append-config truncate-config replace-config unlink-config symlink-config hardlink-config \
                hook-create hook-mkdir hook-chmod hooks-rename hooks-recreate submodule-hook-dance \
                wt2-commondir wt2-head worktrees-newentry own-commondir own-gitdir own-entry-dance; do
            assert_contains "${out}" "DENIED:${p}" "e2e legit worktree: ${p} denied"
        done
        if [[ -n "${alias_dir}" ]]; then
            assert_contains "${out}" "DENIED:alias-config" "e2e legit worktree: write through a /tmp alias of the common dir denied"
        fi
        for p in objects-touch refs-touch logs-touch own-entry-file; do
            assert_contains "${out}" "WROTE:${p}" "e2e legit worktree: ${p} still writable"
        done
        assert_eq "$(_protected_sums)" "${sums_before}" "e2e legit worktree: protected bytes and hook dirs unchanged on the host"
        log="$(git -C "${FAKE_HOME}/repos/main" log --format=%s -1 wt)"
        assert_eq "${log}" "sandboxed" "e2e legit worktree: commit landed in the shared repo"
        side_ok=0; git -C "${FAKE_HOME}/repos/main" rev-parse --verify -q side >/dev/null && side_ok=1
        assert_eq "${side_ok}" "1" "e2e legit worktree: branch landed in the shared repo"
        hooks_planted=0
        [[ -e "${mg}/hooks/post-commit" || -e "${mg}/modules/sub1/hooks/post-commit" ]] && hooks_planted=1
        assert_eq "${hooks_planted}" "0" "e2e legit worktree: no hook planted on the host"
        entry_in_place=0; [[ -f "${mg}/worktrees/wt/commondir" && -d "${mg}/modules/sub1/hooks" ]] && entry_in_place=1
        assert_eq "${entry_in_place}" "1" "e2e legit worktree: worktree entry and submodule dir still in place"
        [[ -n "${alias_dir}" ]] && rm -rf "${alias_dir}"
        rm -rf "${mg}/modules" "${mg}/objects/wt-moved" "${mg}/objects/sub1-moved"
    fi
    # End-to-end on Linux: the crafted repo launches (no abort) and the
    # agent cannot write into ~/.ssh.
    if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
        _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}/.ssh"
        mkdir -p "${FAKE_HOME}/bin"
        cat >"${FAKE_HOME}/bin/codex" <<'STUB'
#!/bin/bash
echo pwned >"${HOME}/.ssh/planted" 2>/dev/null && echo WROTE || echo DENIED
STUB
        chmod +x "${FAKE_HOME}/bin/codex"
        out="$(cd "${FAKE_HOME}/repos/evil" && PATH="${FAKE_HOME}/bin:${PATH}" \
            bash "${REPO_ROOT}/bin/executable_codex_wrapper.bash" x </dev/null 2>&1)"
        assert_contains "${out}" "DENIED" "e2e: crafted repo cannot write ~/.ssh through the sandbox"
        planted=0; [[ -e "${FAKE_HOME}/.ssh/planted" ]] && planted=1
        assert_eq "${planted}" "0" "e2e: nothing planted in ~/.ssh"
    fi
else
    echo "  skip - git not installed"
fi

# ---------------------------------------------------------------------------
echo "-- config dir / file symlink guards"
# shellcheck disable=SC2034  # CODEX_ACCOUNT is read by _bind_codex_account
_bind_codex() { ( _load codex; WRAPPER_FLAGS=(); CODEX_ACCOUNT="${1}"; _bind_codex_account; printf '%s\n' "${WRAPPER_FLAGS[@]}" ) 2>&1; }

ln -s "${OUTSIDE}" "${FAKE_HOME}/.codex-out"
out="$(_bind_codex out)"; rc=$?
assert_eq "${rc}" "1" "named ~/.codex-<name> symlinked outside \$HOME is refused"
assert_contains "${out}" "outside" "... with outside-\$HOME error"

mkdir -p "${FAKE_HOME}/.ssh"
ln -s "${FAKE_HOME}/.ssh" "${FAKE_HOME}/.codex-cred"
out="$(_bind_codex cred)"; rc=$?
assert_eq "${rc}" "1" "named ~/.codex-<name> symlinked into ~/.ssh is refused"
assert_contains "${out}" "credential location" "... with credential-location error"

rm -rf "${FAKE_HOME}/.codex"; ln -s "${FAKE_HOME}/.ssh" "${FAKE_HOME}/.codex"
out="$(_bind_codex private)"; rc=$?
assert_eq "${rc}" "1" "default ~/.codex symlinked into ~/.ssh is refused"
rm -f "${FAKE_HOME}/.codex"

mkdir -p "${FAKE_HOME}/profiles/ok"
ln -s "${FAKE_HOME}/profiles/ok" "${FAKE_HOME}/.codex-ok"
out="$(_bind_codex ok)"; rc=$?
assert_eq "${rc}" "0" "named profile symlinked to a plain dir under \$HOME is allowed"
assert_contains "${out}" "--bind${NL}${FAKE_HOME}/profiles/ok" "... and the resolved path (not the symlink) is bound"

if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    echo "-- claude ~/.claude.json symlink guard (e2e, stub claude)"
    mkdir -p "${FAKE_HOME}/bin" "${FAKE_HOME}/work"
    printf '#!/bin/bash\necho RAN\n' >"${FAKE_HOME}/bin/claude"; chmod +x "${FAKE_HOME}/bin/claude"
    rm -f "${FAKE_HOME}/.claude.json"
    ln -s "${OUTSIDE}/victim.json" "${FAKE_HOME}/.claude.json"
    out="$(cd "${FAKE_HOME}/work" && PATH="${FAKE_HOME}/bin:${PATH}" \
        bash "${REPO_ROOT}/bin/executable_claude_wrapper.bash" x </dev/null 2>&1)"
    rc=$?
    assert_eq "${rc}" "1" "claude: ~/.claude.json symlinked outside \$HOME is refused"
    assert_not_contains "${out}" "RAN" "... before launching"
    created=0; [[ -e "${OUTSIDE}/victim.json" ]] && created=1
    assert_eq "${created}" "0" "... and the symlink target was not created by touch"
    rm -f "${FAKE_HOME}/.claude.json"
    out="$(cd "${FAKE_HOME}/work" && PATH="${FAKE_HOME}/bin:${PATH}" \
        bash "${REPO_ROOT}/bin/executable_claude_wrapper.bash" x </dev/null 2>&1)"
    assert_contains "${out}" "RAN" "claude: control — regular ~/.claude.json still launches"
fi

# ---------------------------------------------------------------------------
echo "-- preset values cannot inject binds"
mkdir -p "${FAKE_HOME}/work"
preset_path="$(cd "${FAKE_HOME}/work" && _load codex && _preset_autosave_path)"
mkdir -p "$(dirname "${preset_path}")"
printf 'CODEX_ACCOUNT=../../etc\n' >"${preset_path}"
out="$( cd "${FAKE_HOME}/work" && _load codex && WRAPPER_FLAGS=() && _preset_autoload && _bind_codex_account 2>&1 )"
rc=$?
assert_eq "${rc}" "1" "CODEX_ACCOUNT=../../etc from a preset is rejected"
assert_contains "${out}" "Invalid CODEX_ACCOUNT" "... by the name validation"
if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    printf 'CODEX_ACCOUNT=private\nAI_SANDBOX_EXTRA_RW_DIRS=%s\n' "${FAKE_HOME}/.ssh" >"${preset_path}"
    printf '#!/bin/bash\necho RAN\n' >"${FAKE_HOME}/bin/codex"; chmod +x "${FAKE_HOME}/bin/codex"
    out="$(cd "${FAKE_HOME}/work" && PATH="${FAKE_HOME}/bin:${PATH}" \
        bash "${REPO_ROOT}/bin/executable_codex_wrapper.bash" x </dev/null 2>&1)"
    rc=$?
    assert_eq "${rc}" "1" "AI_SANDBOX_EXTRA_RW_DIRS=~/.ssh from a preset is refused by the sandbox"
    assert_not_contains "${out}" "RAN" "... before launching codex"
fi
rm -f "${preset_path}"

assert_no_live_client_reached
tests_summary_and_exit
