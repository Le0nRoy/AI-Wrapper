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
export HOME="${FAKE_HOME}"
export XDG_CONFIG_HOME="${FAKE_HOME}/.config"
cleanup() { rm -rf "${FAKE_HOME}" "${OUTSIDE}"; }
trap cleanup EXIT

OS="$(uname -s)"
NL=$'\n'
if ! command -v shasum >/dev/null 2>&1; then
    shasum() { sha256sum; }   # Linux hosts without perl's shasum
    export -f shasum          # ... also for the wrapper child processes
fi

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
    if [[ "${OS}" == "Linux" ]]; then
        for ro in config hooks worktrees worktrees/wt/commondir worktrees/wt/gitdir; do
            assert_contains "${out}" "--ro-bind${NL}${mg}/${ro}${NL}" "legit worktree: ${ro} over-mounted read-only"
        done
        assert_contains "${out}" "--bind${NL}${mg}/worktrees/wt${NL}" "legit worktree: own worktree entry RW"
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
    if [[ "${OS}" == "Linux" ]]; then
        assert_contains "${out}" "--ro-bind${NL}${mg}/worktrees/wt/config.worktree" "worktreeConfig: config.worktree RO"
    fi
    git -C "${FAKE_HOME}/repos/main" config --unset extensions.worktreeConfig
    rm -f "${mg}/worktrees/wt/config.worktree"

    # Submodule git dirs: hooks/ and config RO.
    mkdir -p "${mg}/modules/sub1"; : >"${mg}/modules/sub1/config"
    out="$(_gitbind "${FAKE_HOME}/repos/wt")"
    if [[ "${OS}" == "Linux" ]]; then
        assert_contains "${out}" "--ro-bind${NL}${mg}/modules/sub1/hooks" "submodule hooks/ RO"
        assert_contains "${out}" "--ro-bind${NL}${mg}/modules/sub1/config" "submodule config RO"
    fi
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

    # End-to-end on Linux: a legit worktree can commit / branch / checkout
    # inside the sandbox, but cannot write hooks/, config, another
    # worktree's entry, or its own commondir link.
    if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
        git_q -C "${FAKE_HOME}/repos/main" worktree add "${FAKE_HOME}/repos/wt2" -b wt2
        mkdir -p "${FAKE_HOME}/bin"
        cat >"${FAKE_HOME}/bin/codex" <<'STUB'
#!/bin/bash
m="$(git rev-parse --git-common-dir)"
g() { git -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
echo x >file && g add file && g commit -m sandboxed && echo COMMIT_OK
g branch side && echo BRANCH_OK
g checkout -b feature && g checkout wt && echo CHECKOUT_OK
for f in "${m}/hooks/post-commit" "${m}/config" "${m}/worktrees/wt2/commondir" "${m}/worktrees/wt/commondir" "${m}/worktrees/newentry"; do
    if (echo evil >>"${f}" || mkdir "${f}") 2>/dev/null; then echo "WROTE:${f##*/.git/}"; else echo "DENIED:${f##*/.git/}"; fi
done
STUB
        chmod +x "${FAKE_HOME}/bin/codex"
        out="$(cd "${FAKE_HOME}/repos/wt" && PATH="${FAKE_HOME}/bin:${PATH}" \
            bash "${REPO_ROOT}/bin/executable_codex_wrapper.bash" x </dev/null 2>&1)"
        for ok in COMMIT_OK BRANCH_OK CHECKOUT_OK; do
            assert_contains "${out}" "${ok}" "e2e legit worktree: ${ok}"
        done
        for f in hooks/post-commit config worktrees/wt2/commondir worktrees/wt/commondir worktrees/newentry; do
            assert_contains "${out}" "DENIED:${f}" "e2e legit worktree: write to ${f} denied"
        done
        log="$(git -C "${FAKE_HOME}/repos/main" log --format=%s -1 wt)"
        assert_eq "${log}" "sandboxed" "e2e legit worktree: commit landed in the shared repo"
        hooks_planted=0; [[ -e "${mg}/hooks/post-commit" ]] && hooks_planted=1
        assert_eq "${hooks_planted}" "0" "e2e legit worktree: no hook planted on the host"
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

tests_summary_and_exit
