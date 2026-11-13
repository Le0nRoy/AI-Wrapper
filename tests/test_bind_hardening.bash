#!/bin/bash
# shellcheck disable=SC2088,SC2163  # "~/x" is display text in test names; export "$@" takes NAME=VALUE pairs
# Regression tests for wrapper-side RW binds whose source path can be
# influenced by untrusted input:
#   - the git dir bind for worktrees and submodule checkouts
#     (_wrapper_bind_git_common_dir): the git dir comes from the WORKDIR's
#     `.git` file / `commondir`, so a crafted checkout must not get ~/.ssh,
#     a credential store, $HOME, /etc or an unrelated repo bound RW
#     (pointer sanity: shape and links, no location list; accepted
#     layouts and bind order: tests/test_git_dirs.bash)
#   - account/config dirs (~/.codex, ~/.codex-<name>, ~/.claude.json) that
#     are symlinks to outside $HOME or into credential dirs
#   - per-workdir preset values flowing into binds (CODEX_ACCOUNT,
#     AI_SANDBOX_EXTRA_RW_DIRS)
#   - the shared sensitive-dir classifier _sandbox_sensitive_dir_kind
#   - paths resolved before classification (#65): WORKDIR reached through
#     a symlink and AI_SANDBOX_EXTRA_{RW,RO}_DIRS entries (Linux argv via a
#     stub bwrap), and the config-symlink policy (dangling links, broad
#     roots, credential stores, shell startup files; relocated and
#     multi-account profiles still accepted)
# See tests/test_sandbox_common.bash for the FAKE_HOME rationale.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(_safe_mktemp_d "${HOME}/ai-wrapper-test.XXXXXX")" || exit 1
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
OUTSIDE="$(_safe_mktemp_d)" || exit 1
isolate_test_env "${FAKE_HOME}"
cleanup() { _safe_rm_rf "${FAKE_HOME}" "${OUTSIDE}"; }
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
echo "-- git dir pointer sanity (crafted checkouts)"
if command -v git >/dev/null 2>&1; then
    git_q() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
    # Make DIR look like a git dir so git accepts it as a commondir.
    _fake_gitdir() { mkdir -p "${1}/objects" "${1}/refs/heads"; echo 'ref: refs/heads/main' >"${1}/HEAD"; : >"${1}/config"; }
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
    _gitbind() { ( set -u; cd "${1}" && _load codex; WRAPPER_FLAGS=(); _wrapper_bind_git_common_dir; printf '%s\n' "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}" ) 2>&1; }

    # Legit worktree: the shared .git is bound read-write as a whole
    # (layouts and native enforcement: tests/test_git_dirs.bash).
    git_q init "${FAKE_HOME}/repos/main"
    git_q -C "${FAKE_HOME}/repos/main" commit --allow-empty -m init
    git_q -C "${FAKE_HOME}/repos/main" worktree add "${FAKE_HOME}/repos/main/wt" -b wt
    mg="${FAKE_HOME}/repos/main/.git"
    out="$(_gitbind "${FAKE_HOME}/repos/main/wt")"
    assert_contains "${out}" "--under-bind${NL}${mg}${NL}" "legit worktree: shared .git bound read-write"
    assert_not_contains "${out}" "--ro-bind" "legit worktree: no read-only overlay"
    assert_not_contains "${out}" "WARN" "legit worktree: no WARN"
    mkdir -p "${FAKE_HOME}/repos/main/wt/sub"
    out="$(_gitbind "${FAKE_HOME}/repos/main/wt/sub")"
    assert_contains "${out}" "--under-bind${NL}${mg}${NL}" "legit worktree subdirectory: shared .git bound"

    # Borrowed worktree entry: an untrusted checkout's .git file points at
    # an EXISTING worktree entry of another repo. Forward link holds; the
    # reverse link (<entry>/gitdir) names the real worktree, not this one.
    rm -rf "${FAKE_HOME}/repos/evil"; mkdir -p "${FAKE_HOME}/repos/evil"
    printf 'gitdir: %s\n' "${mg}/worktrees/wt" >"${FAKE_HOME}/repos/evil/.git"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "-bind${NL}" "borrowed worktree entry: not bound"
    assert_contains "${out}" "belongs to ${FAKE_HOME}/repos/main/wt/.git" "... rejected by the reverse-link rule"
    assert_contains "${out}" "git won't work in this checkout because" "... with the refusal WARN"

    # Crafted commondir -> ~/.ssh (made git-dir shaped so git accepts it).
    _fake_gitdir "${FAKE_HOME}/.ssh"
    _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}/.ssh"
    sanity="$(cd "${FAKE_HOME}/repos/evil" && git rev-parse --git-common-dir 2>/dev/null)"
    assert_eq "${sanity}" "${FAKE_HOME}/.ssh" "sanity: crafted repo makes git report ~/.ssh as common dir"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "-bind${NL}" "commondir -> ~/.ssh: not bound"
    assert_contains "${out}" "is not a worktree of it" "... rejected by the forward link (no location list, B-rho)"

    # Crafted commondir -> a credential store below a dotfile tree, and a
    # dir above one (it would expose ~/.config/gh).
    for cred in .gnupg/sub/r .local/share/keyrings/r .config; do
        _fake_gitdir "${FAKE_HOME}/${cred}"
        _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}/${cred}"
        out="$(_gitbind "${FAKE_HOME}/repos/evil")"
        assert_not_contains "${out}" "-bind${NL}" "commondir -> ~/${cred}: not bound"
        assert_contains "${out}" "is not a worktree of it" "commondir -> ~/${cred}: ... rejected by the forward link"
        rm -rf "${FAKE_HOME:?}/${cred}/objects" "${FAKE_HOME:?}/${cred}/refs" "${FAKE_HOME:?}/${cred}/HEAD" "${FAKE_HOME:?}/${cred}/config"
    done

    # Crafted commondir -> $HOME.
    _fake_gitdir "${FAKE_HOME}"
    _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "-bind${NL}" "commondir -> \$HOME: not bound"
    assert_contains "${out}" "is \$HOME itself" "... rejected as \$HOME itself"
    rm -rf "${FAKE_HOME}/objects" "${FAKE_HOME}/refs" "${FAKE_HOME}/HEAD" "${FAKE_HOME}/config"

    # Crafted commondir -> outside $HOME in the system temp dir.
    _fake_gitdir "${OUTSIDE}/.git"
    _crafted_repo "${FAKE_HOME}/repos/evil" "${OUTSIDE}/.git"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "-bind${NL}" "commondir in the system temp dir: not bound"

    # Crafted commondir -> another real repo's .git (under $HOME, right
    # shape) — rejected because WORKDIR isn't one of its worktrees.
    git_q init "${FAKE_HOME}/repos/private"
    _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}/repos/private/.git"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "-bind${NL}" "commondir -> unrelated repo's .git: not bound"
    assert_contains "${out}" "is not a worktree of it" "... rejected by the worktree back-link rule"

    # Crafted commondir -> any git-shaped dir: the forward link fails
    # whatever its name.
    _fake_gitdir "${FAKE_HOME}/data/stuff"
    _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}/data/stuff"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "-bind${NL}" "commondir -> git-shaped data dir: not bound"
    assert_contains "${out}" "is not a worktree of it" "... rejected by the forward link"

    # Crafted commondir via a symlink inside WORKDIR -> ~/.ssh: the
    # resolved target is what's checked (and would be bound).
    _crafted_repo "${FAKE_HOME}/repos/evil" "${FAKE_HOME}/repos/evil/link.git"
    ln -s "${FAKE_HOME}/.ssh" "${FAKE_HOME}/repos/evil/link.git"
    out="$(_gitbind "${FAKE_HOME}/repos/evil")"
    assert_not_contains "${out}" "-bind${NL}" "commondir symlink -> ~/.ssh: not bound"

    # Unit checks of the validator itself.
    _ok() { ( _load codex; _wrapper_git_common_dir_ok "${1}" "${FAKE_HOME}" "${2:-${FAKE_HOME}/repos/main/wt}" ); }
    _ok "${mg}" >/dev/null
    assert_eq "$?" "0" "validator accepts the legit common dir"
    _ok /etc >/dev/null
    assert_eq "$?" "1" "validator rejects /etc"
    mkdir -p "${FAKE_HOME}/repos/nogit/.git"
    out="$(_ok "${FAKE_HOME}/repos/nogit/.git")"
    assert_contains "${out}" "does not look like a git dir" "validator rejects a .git without HEAD/objects/refs"
    mkdir -p "${FAKE_HOME}/repos/symgit"; ln -s "${mg}" "${FAKE_HOME}/repos/symgit/.git"
    out="$(_ok "${FAKE_HOME}/repos/symgit/.git")"
    assert_contains "${out}" "not a resolved directory" "validator rejects a symlinked git dir"

    # Submodule git dirs: git's module layout under a real <super>/.git.
    share="${FAKE_HOME}/.local/share"
    _fake_gitdir "${share}/noparent/.git/modules/m"
    out="$(_ok "${share}/noparent/.git/modules/m")"
    assert_contains "${out}" "not a verified submodule git dir" "submodule: parent .git without HEAD/objects/refs rejected"
    _fake_gitdir "${FAKE_HOME}/repos/realparent/.git/modules/m"
    _fake_gitdir "${FAKE_HOME}/repos/realparent/.git"
    mkdir -p "${share}/symparent"
    ln -s "${FAKE_HOME}/repos/realparent/.git" "${share}/symparent/.git"
    out="$(_ok "${share}/symparent/.git/modules/m")"
    assert_contains "${out}" "not a verified submodule git dir" "submodule: symlinked parent .git rejected"
    _fake_gitdir "${share}/sup/.git"
    _fake_gitdir "${share}/sup/.git/modules/.git"
    out="$(_ok "${share}/sup/.git/modules/.git")"
    assert_contains "${out}" "not a verified submodule git dir" "submodule: modules/.git rejected"
    # No location list: a verified modules/<name> layout under
    # ~/.local/share (slash-named too) passes the shape checks and still
    # needs WORKDIR's own links to it.
    for name in m foo.git a/b; do
        _fake_gitdir "${share}/sup/.git/modules/${name}"
        out="$(_ok "${share}/sup/.git/modules/${name}")"
        assert_contains "${out}" "is not a worktree of it" "submodule: modules/${name} of an unrelated checkout rejected by the forward link"
    done

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
# Named-profile symlink checks force the Linux backend: macOS refuses named
# profiles before them (#46).
_bind_codex() { ( _load codex; [[ -n "${2:-}" ]] && _wrapper_os="${2}"; WRAPPER_FLAGS=(); CODEX_ACCOUNT="${1}"; _bind_codex_account; printf '%s\n' "${WRAPPER_FLAGS[@]}" ) 2>&1; }

ln -s "${OUTSIDE}" "${FAKE_HOME}/.codex-out"
out="$(_bind_codex out Linux)"; rc=$?
assert_eq "${rc}" "1" "named ~/.codex-<name> symlinked outside \$HOME is refused"
assert_contains "${out}" "outside" "... with outside-\$HOME error"

mkdir -p "${FAKE_HOME}/.ssh"
ln -s "${FAKE_HOME}/.ssh" "${FAKE_HOME}/.codex-cred"
out="$(_bind_codex cred Linux)"; rc=$?
assert_eq "${rc}" "1" "named ~/.codex-<name> symlinked into ~/.ssh is refused"
assert_contains "${out}" "credential location" "... with credential-location error"

rm -rf "${FAKE_HOME}/.codex"; ln -s "${FAKE_HOME}/.ssh" "${FAKE_HOME}/.codex"
out="$(_bind_codex private)"; rc=$?
assert_eq "${rc}" "1" "default ~/.codex symlinked into ~/.ssh is refused"
rm -f "${FAKE_HOME}/.codex"

mkdir -p "${FAKE_HOME}/profiles/ok"
ln -s "${FAKE_HOME}/profiles/ok" "${FAKE_HOME}/.codex-ok"
out="$(_bind_codex ok Linux)"; rc=$?
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
echo "-- path resolution helpers (#65)"
RES_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
R="${FAKE_HOME}/res-${RES_ID}"
mkdir -p "${R}/real" "${FAKE_HOME}/.ssh"
ln -s "${R}/real" "${R}/link"
ln -s "${R}/missing" "${R}/dangling"
ln -s "${R}/loop-b" "${R}/loop-a"; ln -s "${R}/loop-a" "${R}/loop-b"
ln -s "${FAKE_HOME}/.ssh" "${R}/to-ssh"
: >"${R}/file"
_resolve_extra() { ( _load codex; _sandbox_resolve_extra_dir t AI_SANDBOX_EXTRA_RW_DIRS "${1}" ) 2>/dev/null; }
assert_eq "$( ( source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"; _realpath "${R}/link" ) )" "${R}/real" \
    "_realpath is defined by the universal wrapper alone"
out="$(_resolve_extra "${R}/link")"; rc=$?
assert_eq "${rc}:${out}" "0:${R}/real" "extra dir: symlink resolves to its target"
out="$(_resolve_extra "${R}/real/..")"; rc=$?
assert_eq "${rc}:${out}" "0:${R}" "extra dir: '..' is resolved away"
out="$(_resolve_extra "${R}/to-ssh")"; rc=$?
assert_eq "${rc}:${out}" "0:${FAKE_HOME}/.ssh" "extra dir: symlink into ~/.ssh resolves to ~/.ssh (classified later)"
_resolve_extra "${R}/nope" >/dev/null; rc=$?
assert_eq "${rc}" "2" "extra dir: a missing entry is skipped (rc 2)"
for bad in dangling loop-a file; do
    _resolve_extra "${R}/${bad}" >/dev/null; rc=$?
    assert_eq "${rc}" "1" "extra dir: ${bad} entry fails closed (rc 1)"
done

# ---------------------------------------------------------------------------
echo "-- config symlink policy (#65)"
_cfg_check() { ( _load codex; _wrapper_check_config_symlink "${1}" ) 2>&1; }
C="${FAKE_HOME}/cfg-${RES_ID}"
mkdir -p "${C}" "${FAKE_HOME}/.config/gh" "${FAKE_HOME}/.config/systemd/user" \
    "${FAKE_HOME}/.local/share" "${FAKE_HOME}/.password-store" "${FAKE_HOME}/bin" \
    "${FAKE_HOME}/ai-wrapper/.agents/skills" "${FAKE_HOME}/.config/claude" \
    "${FAKE_HOME}/.local/share/gemini" "${FAKE_HOME}/profiles/work" "${FAKE_HOME}/dotfiles"
: >"${FAKE_HOME}/.gitconfig"; : >"${FAKE_HOME}/.bashrc"; : >"${FAKE_HOME}/dotfiles/claude.json"
_cfg_reject() {  # LINK_NAME TARGET LABEL [EXPECTED_SUBSTRING]
    ln -sfn "${2}" "${C}/${1}"
    out="$(_cfg_check "${C}/${1}")"; rc=$?
    assert_eq "${rc}" "1" "config symlink to ${3} is refused"
    [[ -z "${4:-}" ]] || assert_contains "${out}" "${4}" "... (${4})"
}
_cfg_accept() {  # LINK_NAME TARGET LABEL
    ln -sfn "${2}" "${C}/${1}"
    out="$(_cfg_check "${C}/${1}")"; rc=$?
    assert_eq "${rc}" "0" "config symlink to ${3} is accepted"
}
_cfg_reject dangling "${FAKE_HOME}/not-there-${RES_ID}" "a missing target (dangling)" "does not exist"
ln -sfn "${C}/loop2" "${C}/loop1"; ln -sfn "${C}/loop1" "${C}/loop2"
out="$(_cfg_check "${C}/loop1")"; rc=$?
assert_eq "${rc}" "1" "config symlink loop is refused"
_cfg_reject home "${FAKE_HOME}" "\$HOME itself" "outside"
_cfg_reject etc /etc "/etc" "outside"
_cfg_reject config "${FAKE_HOME}/.config" "~/.config (broad root)"
_cfg_reject local "${FAKE_HOME}/.local" "~/.local (broad root)"
_cfg_reject share "${FAKE_HOME}/.local/share" "~/.local/share (broad root)"
_cfg_reject bin "${FAKE_HOME}/bin" "~/bin (read-only by default, #62)"
_cfg_reject aiw "${FAKE_HOME}/ai-wrapper" "~/ai-wrapper (above the skill source)"
_cfg_reject gh "${FAKE_HOME}/.config/gh" "~/.config/gh" "credential location"
_cfg_reject pass "${FAKE_HOME}/.password-store" "~/.password-store" "credential location"
_cfg_reject sysd "${FAKE_HOME}/.config/systemd/user" "~/.config/systemd/user"
_cfg_reject gitconfig "${FAKE_HOME}/.gitconfig" "~/.gitconfig"
_cfg_reject bashrc "${FAKE_HOME}/.bashrc" "~/.bashrc"
_cfg_reject ssh "${FAKE_HOME}/.ssh" "~/.ssh" "credential location"
_cfg_accept work "${FAKE_HOME}/profiles/work" "~/profiles/work (multi-account profile)"
_cfg_accept cclaude "${FAKE_HOME}/.config/claude" "~/.config/claude (relocated dotpath)"
_cfg_accept gem "${FAKE_HOME}/.local/share/gemini" "~/.local/share/gemini (relocated dotpath)"
_cfg_accept json "${FAKE_HOME}/dotfiles/claude.json" "~/dotfiles/claude.json (relocated file)"
out="$(_cfg_check "${FAKE_HOME}/profiles/work")"; rc=$?
assert_eq "${rc}" "0" "a plain (non-symlink) config dir passes"
out="$(_cfg_check "${C}/absent-${RES_ID}")"; rc=$?
assert_eq "${rc}" "0" "a missing (non-symlink) config path passes (callers create it)"
ln -sfn "${FAKE_HOME}/.ssh" "${C}/parent"
mkdir -p "${FAKE_HOME}/.ssh/agentcfg"
out="$(_cfg_check "${C}/parent/agentcfg")"; rc=$?
assert_eq "${rc}" "1" "config path behind a symlinked parent into ~/.ssh is refused"
assert_contains "${out}" "symlinked parent" "... naming the symlinked parent"
rm -rf "${FAKE_HOME}/.ssh/agentcfg"

# ---------------------------------------------------------------------------
echo "-- Linux bwrap argv: paths resolved before classification (#65)"
if [[ "${OS}" == "Linux" ]]; then
    STUB_DIR="${OUTSIDE}/stub-bwrap"
    ARGV_FILE="${STUB_DIR}/argv"
    mkdir -p "${STUB_DIR}"
    cat >"${STUB_DIR}/bwrap" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"${ARGV_FILE}"
STUB
    printf '#!/bin/bash\necho "kernel.unprivileged_userns_clone = 1"\n' >"${STUB_DIR}/sysctl"
    chmod +x "${STUB_DIR}/bwrap" "${STUB_DIR}/sysctl"
    # Run the Linux backend from DIR through the stubs. Sets out (stderr),
    # rc and argv (one entry per line). Extra NAME=VALUE env in "$@".
    _linux_run() {
        local dir="${1}"; shift
        rm -f "${ARGV_FILE}"
        out="$( cd "${dir}" && export PATH="${STUB_DIR}:${PATH}" "$@" \
            && source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash" \
            && _run_sandboxed_agent_linux true -- -- 2>&1 >/dev/null )"; rc=$?
        argv="$(cat "${ARGV_FILE}" 2>/dev/null)"
    }
    _has_seq() { [[ "${NL}${1}${NL}" == *"${NL}${2}${NL}"* ]]; }
    _yes() { if "$@"; then echo yes; else echo no; fi; }
    W="${FAKE_HOME}/wd-${RES_ID}"
    mkdir -p "${W}/real-proj"
    ln -s "${FAKE_HOME}/.ssh" "${W}/to-ssh"
    ln -s /etc "${W}/to-etc"
    ln -s "${FAKE_HOME}" "${W}/to-home"
    ln -s "${W}/real-proj" "${W}/proj-link"

    for link in to-ssh to-etc to-home; do
        _linux_run "${W}/${link}" _NOOP=1
        assert_eq "${rc}" "1" "WORKDIR via symlink ${link} is refused"
        assert_contains "${out}" "Refusing to sandbox with WORKDIR" "... by the sensitive-WORKDIR guard (${link})"
        assert_eq "${argv}" "" "... before bwrap runs (${link})"
    done
    _linux_run "${W}/to-ssh" AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1
    assert_eq "${rc}" "0" "AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 still overrides a symlinked sensitive WORKDIR"

    _linux_run "${W}/proj-link" _NOOP=1
    assert_eq "${rc}" "0" "WORKDIR via a symlink to a project dir launches"
    assert_eq "$(_yes _has_seq "${argv}" "--bind${NL}${W}/real-proj${NL}${W}/real-proj")" yes \
        "... binding the resolved path"
    assert_eq "$(_yes _has_seq "${argv}" "--bind${NL}${W}/real-proj${NL}${W}/proj-link")" yes \
        "... also mounted at the logical path"
    assert_eq "$(_yes _has_seq "${argv}" "--chdir${NL}${W}/proj-link")" yes "... and --chdir to the logical cwd"
    assert_eq "$(_yes _has_seq "${argv}" "--bind${NL}${W}/proj-link${NL}${W}/proj-link")" no \
        "... never binding the unresolved symlink as the source"

    _linux_run "${W}/real-proj" _NOOP=1
    assert_eq "$(_yes _has_seq "${argv}" "--bind${NL}${W}/real-proj${NL}${W}/real-proj")" yes \
        "plain WORKDIR: bound once at its own path"
    assert_eq "$(printf '%s\n' "${argv}" | grep -cx -- "${W}/real-proj")" "3" \
        "plain WORKDIR: no second (logical) mount"

    for entry in "${W}/to-ssh" "${W}/real-proj/../to-home" "${W}/real-proj/../../.ssh" "${W}/to-etc"; do
        for var in AI_SANDBOX_EXTRA_RW_DIRS AI_SANDBOX_EXTRA_RO_DIRS; do
            _linux_run "${W}/real-proj" "${var}=${entry}"
            assert_eq "${rc}" "1" "${var}=${entry#"${FAKE_HOME}"/} is refused after resolution"
            assert_contains "${out}" "Refusing extra bind" "... by the extra-bind guard"
        done
    done
    _linux_run "${W}/real-proj" "AI_SANDBOX_EXTRA_RW_DIRS=${W}/to-ssh" AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1
    assert_eq "${rc}" "0" "AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 still overrides a symlinked sensitive extra dir"
    assert_eq "$(_yes _has_seq "${argv}" "--bind${NL}${FAKE_HOME}/.ssh${NL}${FAKE_HOME}/.ssh")" yes \
        "... and binds the resolved target"

    mkdir -p "${W}/data-real"; ln -s "${W}/data-real" "${W}/data-link"
    _linux_run "${W}/real-proj" "AI_SANDBOX_EXTRA_RW_DIRS=${W}/data-link" "AI_SANDBOX_EXTRA_RO_DIRS=${W}/data-link/"
    assert_eq "${rc}" "0" "benign symlinked extra dirs launch"
    assert_eq "$(_yes _has_seq "${argv}" "--bind${NL}${W}/data-real${NL}${W}/data-real")" yes "... RW bound at the resolved path"
    assert_eq "$(_yes _has_seq "${argv}" "--ro-bind${NL}${W}/data-real${NL}${W}/data-real")" yes "... RO bound at the resolved path"
    assert_not_contains "${argv}" "${W}/data-link" "... the symlink itself is never a bind source"

    _linux_run "${W}/real-proj" "AI_SANDBOX_EXTRA_RW_DIRS=${W}/missing-${RES_ID},${W}/data-real"
    assert_eq "${rc}" "0" "a missing extra dir is skipped, the launch continues"
    assert_contains "${out}" "does not exist" "... with a WARNING"
    ln -s "${W}/gone-${RES_ID}" "${W}/dangling"
    : >"${W}/plain-file"
    for bad in dangling plain-file; do
        for var in AI_SANDBOX_EXTRA_RW_DIRS AI_SANDBOX_EXTRA_RO_DIRS; do
            _linux_run "${W}/real-proj" "${var}=${W}/${bad}" AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1
            assert_eq "${rc}" "1" "${var}=${bad} fails closed, even with the sensitivity override"
            assert_contains "${out}" "does not resolve to a directory" "... naming the invalid entry (${bad}, ${var})"
        done
    done

    echo "-- claude wrapper binds resolved config sources (#65)"
    mkdir -p "${FAKE_HOME}/profiles/claude-w" "${W}/claude-work"
    : >"${FAKE_HOME}/dotfiles/claude-w.json"
    ln -sfn "${FAKE_HOME}/profiles/claude-w" "${FAKE_HOME}/.claude-w${RES_ID}"
    ln -sfn "${FAKE_HOME}/dotfiles/claude-w.json" "${FAKE_HOME}/.claude-w${RES_ID}.json"
    printf '#!/bin/bash\necho RAN\n' >"${FAKE_HOME}/bin/claude"; chmod +x "${FAKE_HOME}/bin/claude"
    rm -f "${ARGV_FILE}"
    out="$(cd "${W}/claude-work" && PATH="${STUB_DIR}:${FAKE_HOME}/bin:${PATH}" CLAUDE_ACCOUNT="w${RES_ID}" \
        bash "${REPO_ROOT}/bin/executable_claude_wrapper.bash" x </dev/null 2>&1)"; rc=$?
    argv="$(cat "${ARGV_FILE}" 2>/dev/null)"
    assert_eq "${rc}" "0" "claude: symlinked named profile and .json launch"
    assert_eq "$(_yes _has_seq "${argv}" "--bind${NL}${FAKE_HOME}/profiles/claude-w${NL}${FAKE_HOME}/.claude")" yes \
        "claude: profile dir bound from its resolved path"
    assert_eq "$(_yes _has_seq "${argv}" "--bind${NL}${FAKE_HOME}/dotfiles/claude-w.json${NL}${FAKE_HOME}/.claude.json")" yes \
        "claude: profile .json bound from its resolved path"
    ln -sfn "${FAKE_HOME}/.bashrc" "${FAKE_HOME}/.claude-w${RES_ID}.json"
    rm -f "${ARGV_FILE}"
    out="$(cd "${W}/claude-work" && PATH="${STUB_DIR}:${FAKE_HOME}/bin:${PATH}" CLAUDE_ACCOUNT="w${RES_ID}" \
        bash "${REPO_ROOT}/bin/executable_claude_wrapper.bash" x </dev/null 2>&1)"; rc=$?
    assert_eq "${rc}" "1" "claude: profile .json symlinked to ~/.bashrc is refused"
    assert_eq "$(cat "${ARGV_FILE}" 2>/dev/null)" "" "... before bwrap runs"
    rm -f "${FAKE_HOME}/.claude-w${RES_ID}" "${FAKE_HOME}/.claude-w${RES_ID}.json"
else
    echo "  skip - bwrap argv checks are Linux-only"
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

# ---------------------------------------------------------------------------
echo "-- client persistent controls (_wrapper_protect_client_controls, #86)"
CC="${FAKE_HOME}/.cc-client"
CC_DST="${FAKE_HOME}/.cc-dst"
CC_WD="${FAKE_HOME}/work-cc"
mkdir -p "${CC}/skills/s1" "${CC}/plugins" "${CC}/sessions" "${CC_WD}/.inrepo" "${FAKE_HOME}/.ssh"
echo '{}' >"${CC}/settings.json"
echo x >"${CC}/plugins/config.json"
echo x >"${CC}/my settings.json"
echo x >"${CC}/skills/s1/SKILL.md"
echo x >"${CC_WD}/.inrepo/settings.json"
# Run the helper from CWD (default CC_WD) with _wrapper_os=OS; print rc,
# then WRAPPER_FLAGS one word per line, then stderr.
_cc() {
    local os="${1}"; shift
    ( cd "${CC_CWD:-${CC_WD}}" && _load codex && _wrapper_os="${os}" && WRAPPER_FLAGS=() || exit 99
      _wrapper_protect_client_controls "$@"; echo "rc=$?"
      printf '%s\n' "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}" ) 2>&1
}
_bind3() { printf '%s\n%s\n%s\n' "${1}" "${2}" "${3}"; }

out="$(_cc Linux t "${CC}" "" settings.json skills plugins/config.json hooks missing.json "my settings.json")"
assert_contains "${out}" "rc=0" "controls: protection succeeds"
assert_contains "${out}" "$(_bind3 --bind "${CC}" "${CC}")" "controls (Linux): profile base pinned"
assert_contains "${out}" "$(_bind3 --bind "${CC}/plugins" "${CC}/plugins")" "controls (Linux): intermediate plugins/ pinned"
assert_contains "${out}" "$(_bind3 --ro-bind "${CC}/settings.json" "${CC}/settings.json")" "controls (Linux): settings.json read-only"
assert_contains "${out}" "$(_bind3 --ro-bind "${CC}/skills" "${CC}/skills")" "controls (Linux): skills/ read-only"
assert_contains "${out}" "$(_bind3 --ro-bind "${CC}/plugins/config.json" "${CC}/plugins/config.json")" "controls (Linux): nested plugins/config.json read-only"
assert_contains "${out}" "$(_bind3 --ro-bind "${CC}/my settings.json" "${CC}/my settings.json")" "controls (Linux): path with a space read-only"
assert_not_contains "${out}" "hooks" "controls: absent hooks/ skipped"
assert_not_contains "${out}" "missing.json" "controls: absent file skipped"
assert_not_contains "${out}" "${CC}/sessions" "controls: mutable session state not touched"
assert_not_contains "${out}" "WARN" "controls: no WARN by default"
# bwrap: later mount wins, so every pin must precede every RO overlay.
last_pin="$(printf '%s\n' "${out}" | grep -n -x -e '--bind' | tail -1 | cut -d: -f1)"
first_ro="$(printf '%s\n' "${out}" | grep -n -x -e '--ro-bind' | head -1 | cut -d: -f1)"
assert_eq "$(( ${last_pin:-999} < ${first_ro:-0} ))" "1" "controls (Linux): pins mounted before read-only overlays"
assert_eq "$(printf '%s\n' "${out}" | grep -c -x -e "${CC}/plugins")" "2" "controls (Linux): plugins/ pinned once"

out="$(_cc Linux t "${CC}" "")"
assert_contains "${out}" "$(_bind3 --bind "${CC}" "${CC}")" "controls: empty list still pins the base"
assert_not_contains "${out}" "--ro-bind" "controls: empty list adds no read-only overlay"

out="$(_cc Linux t "${FAKE_HOME}/.cc-absent" "" settings.json)"
assert_eq "${out}" "rc=0" "controls: absent profile base is a no-op"

# Remapped named account (Linux): host profile appears at DST_BASE.
out="$(_cc Linux t "${CC}" "${CC_DST}" settings.json plugins/config.json)"
assert_contains "${out}" "$(_bind3 --bind "${CC}" "${CC_DST}")" "controls remapped: base pinned at its sandbox path"
assert_contains "${out}" "$(_bind3 --bind "${CC}" "${CC}")" "controls remapped: base pinned at its host path"
assert_contains "${out}" "$(_bind3 --bind "${CC}/plugins" "${CC_DST}/plugins")" "controls remapped: plugins/ pinned at its sandbox path"
assert_contains "${out}" "$(_bind3 --ro-bind "${CC}/settings.json" "${CC_DST}/settings.json")" "controls remapped: settings.json read-only at its sandbox path"
assert_contains "${out}" "$(_bind3 --ro-bind "${CC}/settings.json" "${CC}/settings.json")" "controls remapped: settings.json read-only at its host path"

# Profile base reached through a symlink: sources are resolved, the
# destination keeps the spelling the CLI uses.
ln -sfn "${CC}" "${FAKE_HOME}/.cc-link"
out="$(_cc Linux t "${FAKE_HOME}/.cc-link" "" settings.json)"
assert_contains "${out}" "$(_bind3 --ro-bind "${CC}/settings.json" "${FAKE_HOME}/.cc-link/settings.json")" "controls via symlinked base: resolved source, CLI-visible destination"
assert_contains "${out}" "$(_bind3 --ro-bind "${CC}/settings.json" "${CC}/settings.json")" "controls via symlinked base: resolved path covered too"
rm -f "${FAKE_HOME}/.cc-link"

# A symlinked control (or a symlinked parent of one) refuses the launch:
# binding its target would expose or protect the wrong file.
ln -sfn "${FAKE_HOME}/.ssh" "${CC}/agents"
out="$(_cc Linux t "${CC}" "" settings.json agents)"
assert_contains "${out}" "rc=1" "controls: symlinked control entry refuses the launch"
assert_contains "${out}" "is a symlink" "... with an ERROR naming the cause"
assert_not_contains "${out}" "${FAKE_HOME}/.ssh" "... and never binds the link target"
rm -f "${CC}/agents"
mkdir -p "${OUTSIDE}/plug"; echo x >"${OUTSIDE}/plug/config.json"
ln -sfn "${OUTSIDE}/plug" "${CC}/linkdir"
out="$(_cc Linux t "${CC}" "" linkdir/config.json)"
assert_contains "${out}" "rc=1" "controls: control behind a symlinked parent refuses the launch"
assert_not_contains "${out}" "--ro-bind" "... before any read-only overlay"
rm -f "${CC}/linkdir"
mkfifo "${CC}/fifo-control" 2>/dev/null && {
    out="$(_cc Linux t "${CC}" "" fifo-control)"
    assert_contains "${out}" "rc=1" "controls: control that is neither file nor directory refuses the launch"
    rm -f "${CC}/fifo-control"
}

# WORKDIR overlap: controls inside WORKDIR stay editable (trusted
# maintenance of the active repository); others are still protected.
out="$(_cc Linux t "${CC_WD}/.inrepo" "" settings.json)"
assert_not_contains "${out}" "--ro-bind" "controls inside WORKDIR: left writable"
assert_contains "${out}" "rc=0" "controls inside WORKDIR: launch allowed"
out="$(_cc Linux t "${CC}" "" settings.json "${CC_WD}/.inrepo/settings.json")"
assert_not_contains "${out}" "${CC_WD}/.inrepo/settings.json" "absolute control inside WORKDIR: left writable"
assert_contains "${out}" "$(_bind3 --ro-bind "${CC}/settings.json" "${CC}/settings.json")" "control outside WORKDIR: still read-only"
out="$(CC_CWD="${CC}/skills/s1" _cc Linux t "${CC}" "" settings.json skills)"
assert_not_contains "${out}" "--ro-bind${NL}${CC}/skills${NL}" "WORKDIR inside skills/: skills/ left writable"
assert_contains "${out}" "WARN" "... with a WARN"
assert_contains "${out}" "$(_bind3 --ro-bind "${CC}/settings.json" "${CC}/settings.json")" "WORKDIR inside skills/: settings.json still read-only"

# Trusted-maintenance switch.
out="$(AI_SANDBOX_ALLOW_SETTINGS=1 _cc Linux t "${CC}" "" settings.json skills)"
assert_contains "${out}" "rc=0" "AI_SANDBOX_ALLOW_SETTINGS=1: launch allowed"
assert_not_contains "${out}" "--ro-bind" "AI_SANDBOX_ALLOW_SETTINGS=1: no read-only overlay"
assert_not_contains "${out}" "--bind" "AI_SANDBOX_ALLOW_SETTINGS=1: no pin"
assert_contains "${out}" "WARN" "AI_SANDBOX_ALLOW_SETTINGS=1: WARN banner"
assert_contains "${out}" "AI_SANDBOX_ALLOW_SETTINGS=1" "... naming the switch"
out="$(AI_SANDBOX_ALLOW_SETTINGS=0 _cc Linux t "${CC}" "" settings.json)"
assert_contains "${out}" "--ro-bind" "AI_SANDBOX_ALLOW_SETTINGS=0: protected"

# Darwin flags are single-arg; DST_BASE is dropped.
out="$(_cc Darwin t "${CC}" "${CC_DST}" settings.json skills plugins/config.json)"
assert_contains "${out}" "--pin${NL}${CC}${NL}" "controls (Darwin): base pinned"
assert_contains "${out}" "--pin${NL}${CC}/plugins${NL}" "controls (Darwin): plugins/ pinned"
assert_contains "${out}" "--ro-bind${NL}${CC}/settings.json${NL}" "controls (Darwin): settings.json read-only"
assert_contains "${out}" "--ro-bind${NL}${CC}/skills${NL}" "controls (Darwin): skills/ read-only"
assert_not_contains "${out}" "${CC_DST}" "controls (Darwin): no remapped destination"
assert_eq "$(printf '%s\n' "${out}" | grep -c -x -e "${CC}/settings.json")" "1" "controls (Darwin): each control listed once"

# Native enforcement, when a sandbox backend is installed.
cc_native=0
if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    cc_native=1
elif [[ "${OS}" == "Darwin" ]] && command -v sandbox-exec >/dev/null 2>&1; then
    cc_native=1
fi
if [[ "${cc_native}" == "1" ]]; then
    cc_flags=()
    while IFS= read -r line; do cc_flags+=("${line}"); done < <(
        cd "${CC_WD}" && _load codex && WRAPPER_FLAGS=() && _wrapper_add_bind "${CC}" \
            && _wrapper_protect_client_controls t "${CC}" "" settings.json skills plugins/config.json \
            && printf '%s\n' "${WRAPPER_FLAGS[@]}")
    settings_before="$(cksum <"${CC}/settings.json")"
    cc_probe="$(cat <<'PROBE'
ren() { perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$@"; }
probe() { n="$1"; shift; if ("$@") >/dev/null 2>&1; then echo "WROTE:$n"; else echo "DENIED:$n"; fi; }
app() { echo evil >>"$1"; }
repl() { echo evil >"$1.tmp" && ren "$1.tmp" "$1"; }
c="$1"
probe settings-append app "$c/settings.json"
probe settings-replace repl "$c/settings.json"
probe skill-edit app "$c/skills/s1/SKILL.md"
probe skill-create mkdir "$c/skills/evil"
probe skills-rename ren "$c/skills" "$c/skills.old"
probe plugins-rename ren "$c/plugins" "$c/plugins.old"
probe base-rename ren "$c" "$c.old"
probe session-write app "$c/sessions/s.jsonl"
rm -f "$c/settings.json.tmp"
echo PROBES_DONE
PROBE
)"
    out="$(cd "${CC_WD}" && _load codex && run_sandboxed_agent /bin/sh -- "${cc_flags[@]}" -- -c "${cc_probe}" _ "${CC}" 2>&1)"
    echo "  (native controls probe output: ${out})"
    assert_contains "${out}" "PROBES_DONE" "native controls probe ran"
    for p in settings-append settings-replace skill-edit skill-create skills-rename plugins-rename base-rename; do
        assert_contains "${out}" "DENIED:${p}" "native controls: ${p} denied"
    done
    assert_contains "${out}" "WROTE:session-write" "native controls: session state stays writable"
    assert_eq "$(cksum <"${CC}/settings.json")" "${settings_before}" "native controls: host settings.json unchanged"
    assert_eq "$([[ -d "${CC}/skills" && -d "${CC}/plugins" && ! -e "${CC}/skills/evil" ]] && echo 1)" "1" "native controls: host tree unchanged"
else
    echo "  skip - native controls probe needs bwrap (Linux) or sandbox-exec (macOS)"
fi

# Setting: catalog row and preset restore WARN.
catalog="$( _load codex; printf '%s\n' "${_AI_SETTINGS_LIST[@]}" )"
assert_contains "${catalog}" "AI_SANDBOX_ALLOW_SETTINGS|bool|0|red|" "catalog: AI_SANDBOX_ALLOW_SETTINGS bool, default 0, red"
row="$(printf '%s\n' "${catalog}" | grep '^AI_SANDBOX_ALLOW_SETTINGS|')"
assert_eq "${row##*|}" "sensitive" "catalog: AI_SANDBOX_ALLOW_SETTINGS under sensitive on every OS"
_in_cc_preset() { ( cd "${CC_WD}" && _load codex && eval "${1}" ) 2>&1; }
_in_cc_preset 'AI_SANDBOX_ALLOW_SETTINGS=1 _preset_autosave' >/dev/null
out="$(_in_cc_preset '_preset_autoload; echo "VAL=${AI_SANDBOX_ALLOW_SETTINGS:-unset}"')"
assert_contains "${out}" "VAL=1" "preset: AI_SANDBOX_ALLOW_SETTINGS=1 restored"
assert_contains "${out}" "Restored AI_SANDBOX_ALLOW_SETTINGS=1" "preset: restoring it WARNs"
out="$(export AI_SANDBOX_ALLOW_SETTINGS=0; _in_cc_preset '_preset_autoload; echo "VAL=${AI_SANDBOX_ALLOW_SETTINGS}"')"
assert_contains "${out}" "VAL=0" "preset: launch value 0 wins over a saved 1"
assert_not_contains "${out}" "Restored AI_SANDBOX_ALLOW_SETTINGS" "... without the restore WARN"
_in_cc_preset '_preset_clear' >/dev/null
rm -rf "${CC}" "${CC_WD}"

assert_no_live_client_reached
tests_summary_and_exit
