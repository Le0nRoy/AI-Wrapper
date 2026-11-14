#!/usr/bin/env bash
# Shared menu and orchestration library for AI agent wrappers.
# Sourced by agent-specific libs after setting required variables.
#
# Prerequisites (must be satisfied before sourcing):
#   run_sandboxed_agent    - function from ai_agent_universal_wrapper.bash (source that first)
#
# Required variables (set before sourcing):
#   AI_WRAPPER_AGENT_NAME  - Display name (e.g. "Claude CLI")
#   AI_AGENT_COMMAND       - Binary to run (e.g. "claude")
#   AI_WRAPPER_AGENT_ID    - Stable agent id (e.g. "claude"); names the
#                            per-workdir preset file <hash>-<id>.env.
#                            Unlike AI_WRAPPER_AGENT_NAME it never gets an
#                            account suffix, and unlike AI_AGENT_COMMAND it
#                            is not swapped out by tests.
#
# Required variables (set by the calling wrapper, used by run_orchestrated_session/run_agent_session):
#   WRAPPER_FLAGS          - Array of sandbox flags (--bind mounts, etc.)
#   AGENT_FLAGS            - Array of agent-specific CLI flags
#
# Optional variables:
#   WRAPPER_DATA_DIR       - Path to this directory (defaults to the directory containing this file)
#   WRAPPER_HELP           - Path to help file (defaults to wrapper-help.md in WRAPPER_DATA_DIR)
#   AI_SYSTEM_PROMPT_FLAG  - CLI flag for system prompt injection (e.g. "--append-system-prompt")
#                            If unset, orchestration mode starts a plain session with a warning.
#   AI_RESUME_ARGS         - Array of args for resume mode (default: --resume)
#   AI_RESUME_ARGS_FIRST   - "1" to place AI_RESUME_ARGS BEFORE AGENT_FLAGS in
#                            the resume argv (for agents whose resume is a
#                            subcommand, e.g. `codex resume <flags>`).
#                            Default "0": AGENT_FLAGS first (Claude).
#
# Optional per-agent hook (define in the agent lib to override the default
# `AI_SYSTEM_PROMPT_FLAG <prompt>` pair in run_orchestrated_session):
#   _agent_system_prompt_args PROMPT
#                          - set the global array AI_SYSTEM_PROMPT_ARGS to the
#                            argv words that inject PROMPT as a system /
#                            developer prompt; return non-zero on failure.

# pwd -P resolves symlinks so a symlinked install of this lib still finds its
# sibling data files (orchestrator-prompt.md, etc.) next to the real file.
WRAPPER_DATA_DIR="${WRAPPER_DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
WRAPPER_HELP="${WRAPPER_HELP:-${WRAPPER_DATA_DIR}/wrapper-help.md}"
ORCHESTRATOR_PROMPT="${WRAPPER_DATA_DIR}/orchestrator-prompt.md"

# ===== OS-AWARE BIND HELPERS =====
# bubblewrap (Linux) remaps paths: `--bind SRC DST` makes SRC appear at DST
# inside the sandbox — this is what lets a non-default account directory
# (e.g. ~/.claude-work) appear as ~/.claude to the Claude CLI running inside
# the sandbox. sandbox-exec (macOS) has no bind-mount capability; its
# `--bind` is a single-arg path-based ACL grant (see macos_sandbox_exec.bash
# header) — there is no remapping, so DST is dropped. Known consequence:
# path-remapping features (multi-account switching to a differently-named
# on-disk directory) only work on the Linux backend; on macOS a named
# account would be granted at its own on-disk path while the CLI still
# reads ~/.claude, so the session would silently run on the default
# profile. _wrapper_check_account_supported refuses such selections before
# any host-side change (see #46).
#
# Shared across every wrapper (Claude/Codex/Antigravity/Copilot) — each
# sources this file, so a single `uname -s` check here covers them all.
_wrapper_os="$(uname -s)"

_wrapper_add_bind() {
    local src="${1}" dst="${2:-${1}}"
    if [[ "${_wrapper_os}" == "Darwin" ]]; then
        WRAPPER_FLAGS+=(--bind "${src}")
    else
        WRAPPER_FLAGS+=(--bind "${src}" "${dst}")
    fi
}

# Refuse a named (non-default) account profile on macOS. Each _bind_*_account
# remaps ~/.<cli>-<name> onto the CLI's default config root, which
# sandbox-exec cannot do (see above), and none of the maintained CLIs has a
# verified invocation-local config-root override that covers all of its
# credentials and state. Call after the account name is validated and
# before any host-state mutation (mkdir, settings checks, skill sync).
#   $1 - normalised account name ("" = default 'private' profile)
#   $2 - the setting name, for the error message (e.g. CLAUDE_ACCOUNT)
_wrapper_check_account_supported() {
    local account="${1}" var_name="${2}"
    [[ -z "${account}" || "${_wrapper_os}" != "Darwin" ]] && return 0
    echo "ERROR: ${var_name}='${account}' is not supported on macOS: sandbox-exec cannot remap ~/.<cli>-${account} onto the CLI's default config directory, so the session would silently use the default profile." >&2
    echo "Set ${var_name}=private (or unset it) to use the default profile on macOS; named account profiles work on Linux only." >&2
    return 1
}

_wrapper_add_ro_bind() {
    local src="${1}" dst="${2:-${1}}"
    if [[ "${_wrapper_os}" == "Darwin" ]]; then
        WRAPPER_FLAGS+=(--ro-bind "${src}")
    else
        WRAPPER_FLAGS+=(--ro-bind "${src}" "${dst}")
    fi
}

# Pin PATH so the agent cannot rename, remove or replace it (its children
# stay as writable as before). bwrap: a self-bind turns PATH into a mount
# point, and rename(2)/rmdir(2) of a mount point fail with EBUSY. Seatbelt:
# --pin renders a literal write deny on PATH and its ancestors below $HOME
# (_append_pin_rules in macos_sandbox_exec.bash). Used for the client
# profile directories holding persistent controls
# (_wrapper_protect_client_controls).
_wrapper_add_pin() {
    local src="${1}" dst="${2:-${1}}"
    if [[ "${_wrapper_os}" == "Darwin" ]]; then
        WRAPPER_FLAGS+=(--pin "${src}")
    else
        WRAPPER_FLAGS+=(--bind "${src}" "${dst}")
    fi
}

# Read-write grant that every read-only overlay and pin stays on top of,
# wherever it sits relative to them (equal, containing, inside). bwrap:
# the backend mounts it before every --ro-bind and pin (later mount wins),
# by descriptor when bwrap has --bind-fd. Seatbelt: an allow rule that,
# unlike --bind, never carves an exception out of an --ro-bind write deny.
# Used for the git dir of a linked worktree or submodule checkout
# (_wrapper_bind_git_common_dir).
_wrapper_add_under_bind() {
    local src="${1}" dst="${2:-${1}}"
    if [[ "${_wrapper_os}" == "Darwin" ]]; then
        WRAPPER_FLAGS+=(--under-bind "${src}")
    else
        WRAPPER_FLAGS+=(--under-bind "${src}" "${dst}")
    fi
}

_wrapper_add_meta_bind() {
    # Metadata-only (stat, no read/write) binds exist to satisfy Seatbelt's
    # default-deny read fence while walking intermediate path components
    # (see macos_sandbox_exec.bash). bwrap's mount-namespace model has no
    # equivalent requirement — only explicitly bound paths are visible at
    # all, and path-walk stat() through WORKDIR's own parent chain is not
    # gated the way Seatbelt gates it — so this is a no-op on Linux.
    [[ "${_wrapper_os}" == "Darwin" ]] && WRAPPER_FLAGS+=(--meta-bind "${1}")
}

# ===== PORTABLE PATH-RESOLUTION HELPERS =====
# _realpath lives in ai_agent_universal_wrapper.bash (sourced before this
# file, see Prerequisites above). _check_workdir_breadth normally lives in
# ai_wrapper_data/macos_sandbox_exec.bash, but that file is only sourced
# lazily inside run_sandboxed_agent() when $(uname -s) == Darwin — it is
# NOT available here, before the menu, on any OS. It is OS-generic (plain
# string comparisons), so it is duplicated here (structurally equivalent to
# macos_sandbox_exec.bash) rather than invented differently, to keep
# behavior identical to whatever the macOS backend does with the same
# inputs later in the run.
# WS3 / U-E: emit a one-line WARN and set $AI_SANDBOX_WORKDIR_WARNING when
# WORKDIR is a direct $HOME child outside the project-dir allowlist
# (Workspace/Projects/src/code/bin/work/dev/repos and lowercase variants).
# Args: TAG RESOLVED_WORKDIR RESOLVED_HOME
_check_workdir_breadth() {
    local tag="${1}" wd="${2}" home="${3}"
    unset AI_SANDBOX_WORKDIR_WARNING || true
    [[ -z "${home}" || -z "${wd}" ]] && return 0
    local wd_parent="${wd%/*}"
    [[ "${wd_parent}" != "${home}" ]] && return 0
    local wd_leaf="${wd##*/}"
    case "${wd_leaf}" in
        Workspace|Projects|src|code|bin|work|dev|repos|workspace|projects)
            return 0
            ;;
    esac
    echo_log "WARN" "[${tag}] WORKDIR=${wd} is a direct \$HOME child outside the project-dir allowlist (Workspace/Projects/src/code/bin/work/dev/repos). The write fence grants RW on every file under it. cd one level deeper if that's broader than you intend."
    export AI_SANDBOX_WORKDIR_WARNING="${wd}"
    return 0
}

# ===== AGENT-GENERIC BIND HELPERS =====
# Shared by every wrapper entry script (Claude/Codex). Both append to the
# caller's WRAPPER_FLAGS via the OS-aware helpers above and are safe under
# `set -u` (the Claude wrapper runs with it on).

# Git worktree and submodule support: in a `git worktree add`-created tree
# or a submodule checkout, WORKDIR's top-level `.git` is a file pointing at
# a git dir outside WORKDIR: <common>/worktrees/<name> of the repository
# that holds the shared object store, refs and config, or
# <super>/.git/modules/<name> for a submodule (nested and slash-named
# submodules included), which is its own common dir. Without that dir
# every git command fails with "fatal: not a git repository" because the
# sandbox's default-deny fence hides it.
#
# `git rev-parse --git-common-dir` names the dir that holds the shared
# data. When it lies outside WORKDIR it is bound read-write as a whole
# (config, hooks/, commondir, config.worktree, info/, worktrees/ and
# modules/ included), so git in the sandbox works as on the host: commits,
# git config, remote add, push -u, git worktree add/prune, git gc,
# submodule updates. A plain repository's .git inside WORKDIR is writable
# through the WORKDIR bind.
#
# OWNER-ACCEPTED EXCEPTION (docs/owner-accepted-exceptions.md; reasoning in
# docs/security-concerns.md B-rho): full read-write access to the git dir
# is intended. The agent can change what host git runs later (hooks,
# core.fsmonitor, aliases, filter drivers). Do not add read-only overlays,
# pins or location blocklists here; the protection is the pointer checks
# below and the bind order (--under-bind: every read-only overlay and pin
# stays on top of the git dir). AI agent profile/state directories are
# not refused either: a git dir there that passes the link checks is
# bound read-write (owner-accepted exception "Git dirs inside AI agent
# profile/state directories are not refused"; do not reintroduce a
# refusal without owner approval).
#
# POINTER SANITY: the common dir comes from files inside WORKDIR (the
# `.git` gitfile and the `commondir` file it points at), i.e. from the
# checkout, which may be untrusted. _wrapper_git_common_dir_ok validates
# the resolved candidate first (real dir, not $HOME, git-dir shape, module
# layout, forward and reverse links). The reverse link is a file inside
# the candidate naming this checkout, so a crafted pointer can only reach
# a directory the agent could already write. A rejected candidate is
# WARNed and nothing of it is bound: the launch continues, git just does
# not work in that checkout. Only the validated, resolved dir is bound,
# never its parent tree: for a submodule checkout that is
# <super>/.git/modules/<name>, not <super>/.git or sibling submodules.
# Nothing inside the git dir (worktrees/*/gitdir, commondir, alternates,
# symlinks in objects/ or refs/) is followed to pick a bind target.
#
# macOS: git canonicalizes the absolute paths it reads, which needs stat()
# on every directory on the way to the git dir; Seatbelt gets metadata-
# only grants for those (_wrapper_add_meta_bind; a no-op on Linux).
_wrapper_bind_git_common_dir() {
    local git_common_dir git_common_resolved wd_resolved home_resolved wt_parent reason
    git_common_dir="$(git -C "$(pwd -P)" rev-parse --git-common-dir 2>/dev/null)" || return 0
    [[ -n "${git_common_dir}" ]] || return 0
    # `git rev-parse --git-common-dir` returns either an absolute path or a
    # path relative to CWD (typically just ".git"). Canonicalize so the bind
    # source is unambiguous and so symlinks in the chain are resolved the
    # same way the kernel's path lookup will. Only the validated, resolved
    # path is ever bound — never the raw, possibly-symlinked one.
    if [[ "${git_common_dir}" != /* ]]; then
        git_common_dir="$(pwd -P)/${git_common_dir}"
    fi
    git_common_resolved="$(_realpath "${git_common_dir}")" || return 0
    [[ -n "${git_common_resolved}" && -d "${git_common_resolved}" ]] || return 0
    wd_resolved="$(_realpath "$(pwd -P)")" || wd_resolved=""
    home_resolved="$(_realpath "${HOME}")" || home_resolved="${HOME%/}"
    home_resolved="${home_resolved%/}"
    # Skip when the git dir is already inside WORKDIR — a plain repository
    # gets it through the WORKDIR bind.
    [[ -n "${wd_resolved}" ]] || return 0
    [[ "${git_common_resolved}" != "${wd_resolved}"/* \
        && "${git_common_resolved}" != "${wd_resolved}" ]] || return 0

    if ! reason="$(_wrapper_git_common_dir_ok "${git_common_resolved}" "${home_resolved}" "${wd_resolved}")"; then
        echo_log "WARN" "[${AI_AGENT_COMMAND:-ai-wrapper}] git won't work in this checkout because its git dir ${git_common_resolved} failed a pointer check: ${reason}. Nothing of it is bound."
        return 0
    fi
    # Mounted under every read-only overlay and pin (client persistent
    # controls, ~/bin, credential overlays, AI_SANDBOX_EXTRA_RO_DIRS), so
    # they stay read-only even when the git dir contains them or sits
    # inside one. On bwrap the Linux backend binds it by descriptor.
    _wrapper_add_under_bind "${git_common_resolved}"

    # stat()-only grants on the git dir's ancestors below $HOME (Seatbelt
    # only, see _wrapper_add_meta_bind). The WORKDIR branch of this walk is
    # handled by each backend already.
    wt_parent="${git_common_resolved%/*}"
    while [[ -n "${wt_parent}" \
            && "${wt_parent}" != "${home_resolved}" \
            && "${wt_parent}" != "/" ]]; do
        _wrapper_add_meta_bind "${wt_parent}"
        wt_parent="${wt_parent%/*}"
    done
    # The backends walk WORKDIR's parents only up to $HOME; a checkout
    # outside $HOME needs the same stat()-only grants up to /.
    if [[ -z "${home_resolved}" || "${wd_resolved}" != "${home_resolved}"/* ]]; then
        wt_parent="${wd_resolved%/*}"
        while [[ -n "${wt_parent}" && "${wt_parent}" != "/" ]]; do
            _wrapper_add_meta_bind "${wt_parent}"
            wt_parent="${wt_parent%/*}"
        done
    fi
    return 0
}

# ----- Submodule git dirs as common dirs -----
# A submodule checkout's git dir lives in its superproject's git dir:
# <super>/.git/modules/<name>, a nested submodule's below its parent's
# (<super>/.git/modules/a/modules/b), and <name> may contain slashes
# (modules/libs/foo). For a checkout launched directly, that git dir is
# also the common dir.

# Pure layout split of a resolved DIR at its first `.git` component. Prints
# <super> (empty for /.git/...) and returns 0 when DIR lies strictly below
# <super>/.git/modules/; returns 1 (printing nothing) otherwise. Does not
# validate anything: see _wrapper_git_module_dir_ok.
_wrapper_git_module_super() {
    local dir="${1%/}" super
    [[ "${dir}" == */.git/* ]] || return 1
    super="${dir%%/.git/*}"
    [[ "${dir#"${super}/.git/"}" == modules/?* ]] || return 1
    printf '%s' "${super}"
}

# Structural check of a module git dir DIR below SUPER/.git/modules (both
# realpath-resolved; SUPER from _wrapper_git_module_super). Returns 0 when
# SUPER is not / and SUPER/.git is a real git dir (not a symlink; HEAD,
# config, objects/, refs/), SUPER/.git/modules a real directory, and the
# path below it follows git's module layout down to DIR: name components
# (not empty, not starting with `.`) that are either namespace parents or
# module git dirs (a regular HEAD or config makes a module git dir: git
# never places one inside another's namespace); below a module git dir only its own
# `modules/`; every component a real directory; DIR itself a module git
# dir. So a git-shaped directory below a module's objects/, refs/ or
# worktrees/ never qualifies. Otherwise prints the reason and returns 1.
# Reads file types only.
_wrapper_git_module_dir_ok() {
    local dir="${1%/}" super="${2}" super_git cur rest comp after_gitdir=0
    if [[ -z "${super}" ]]; then
        echo "the superproject would be /"; return 1
    fi
    super_git="${super}/.git"
    if [[ -L "${super_git}" || ! -d "${super_git}" || -L "${super_git}/HEAD" || ! -f "${super_git}/HEAD" \
            || ! -f "${super_git}/config" || ! -d "${super_git}/objects" || ! -d "${super_git}/refs" ]]; then
        echo "${super_git} is a symlink or not a git dir"; return 1
    fi
    cur="${super_git}/modules"
    if [[ -L "${cur}" || ! -d "${cur}" ]]; then
        echo "${cur} is a symlink or not a directory"; return 1
    fi
    rest="${dir#"${cur}/"}"
    while [[ -n "${rest}" ]]; do
        comp="${rest%%/*}"
        if [[ "${rest}" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
        if (( after_gitdir )); then
            if [[ "${comp}" != "modules" ]]; then
                echo "${cur}/${comp} is inside the module git dir ${cur}, not below its modules/"; return 1
            fi
        elif [[ -z "${comp}" || "${comp}" == .* ]]; then
            echo "'${comp}' below ${cur} is not a submodule name"; return 1
        fi
        cur="${cur}/${comp}"
        if [[ -L "${cur}" || ! -d "${cur}" ]]; then
            echo "${cur} is a symlink or not a directory"; return 1
        fi
        if (( after_gitdir )); then
            after_gitdir=0
            continue
        fi
        if [[ -L "${cur}/HEAD" || -L "${cur}/config" ]]; then
            echo "${cur}/HEAD or ${cur}/config is a symlink"; return 1
        fi
        [[ -f "${cur}/HEAD" || -f "${cur}/config" ]] && after_gitdir=1
    done
    if [[ "${cur}" != "${dir}" ]] || (( ! after_gitdir )); then
        echo "${dir} is a namespace parent, not a module git dir"; return 1
    fi
    return 0
}

# Reverse and forward links of a submodule checkout launched directly
# (WORKDIR's git dir is the verified module git dir DIR). Args: DIR
# RESOLVED_WORKDIR. Returns 0 when:
#   - DIR/config core.worktree is set (read with `git config --file`, no
#     includes, nothing executed) and resolves (relative to DIR, as git
#     does) to exactly git's work tree for WORKDIR (rev-parse
#     --show-toplevel), and WORKDIR is that checkout or below it — git
#     honours core.worktree, so a stray gitfile elsewhere would otherwise
#     report the real checkout;
#   - that checkout's .git is a regular gitfile (not a symlink) whose
#     gitdir resolves to exactly DIR.
# Otherwise prints the reason and returns 1.
_wrapper_git_submodule_checkout_ok() {
    local dir="${1}" wd="${2}" top worktree pointer target
    top="$(git -C "${wd}" rev-parse --show-toplevel 2>/dev/null)" || top=""
    if [[ -n "${top}" ]]; then
        top="$(_realpath "${top}")" || top=""
    fi
    worktree="$(_wrapper_host_git -C "${dir}" config --file "${dir}/config" --get core.worktree 2>/dev/null)" || worktree=""
    if [[ -z "${worktree}" ]]; then
        echo "${dir}/config core.worktree is not set, so the submodule checkout it belongs to cannot be verified"; return 1
    fi
    [[ "${worktree}" == /* ]] || worktree="${dir}/${worktree}"
    worktree="$(_realpath "${worktree}")" || worktree=""
    if [[ -z "${worktree}" || -z "${top}" || "${worktree}" != "${top}" ]]; then
        echo "${dir}/config core.worktree (${worktree:-unresolved}) is not git's work tree for WORKDIR (${top:-unknown})"; return 1
    fi
    if [[ "${wd}" != "${top}" && "${wd}" != "${top}"/* ]]; then
        echo "WORKDIR ${wd} is not inside the submodule checkout ${top} named by ${dir}/config core.worktree"; return 1
    fi
    pointer=""
    if [[ -f "${top}/.git" && ! -L "${top}/.git" ]]; then
        IFS= read -r pointer <"${top}/.git" || [[ -n "${pointer}" ]] || pointer=""
    fi
    target="${pointer#gitdir: }"
    if [[ -n "${target}" && "${target}" != "${pointer}" ]]; then
        [[ "${target}" == /* ]] || target="${top}/${target}"
        target="$(_realpath "${target}")" || target=""
    else
        target=""
    fi
    if [[ "${target}" != "${dir}" ]]; then
        echo "${top}/.git is not a gitfile naming ${dir}"; return 1
    fi
    return 0
}

# Validate a resolved git common dir before it is bound RW. Args:
# RESOLVED_COMMON_DIR RESOLVED_HOME RESOLVED_WORKDIR. Returns 0 when every
# check passes; otherwise prints the rejection reason and returns 1.
#   (a) a real directory (not a symlink), not $HOME itself;
#   (b) shaped like a git dir: regular HEAD and config files plus objects/
#       and refs/ dirs; a dir below <super>/.git/modules/ must also follow
#       git's module layout (_wrapper_git_module_dir_ok: nested and
#       slash-named submodules included, <super>/.git a real git dir);
#   (c) forward link: git's gitdir for WORKDIR resolves to exactly
#       <common>/worktrees/<name> (one path component) or, for a verified
#       module git dir, to the common dir itself — a submodule checkout,
#       whose links are core.worktree and the checkout's gitfile
#       (_wrapper_git_submodule_checkout_ok) instead of (d);
#   (d) reverse link: <common>/worktrees/<name>/gitdir — written by
#       `git worktree add` in the repository, not writable from an
#       untrusted checkout — resolves to exactly <worktree top>/.git, where
#       <worktree top> is WORKDIR's toplevel. Without (d) a checkout could
#       borrow any existing worktree entry of any repository by pointing
#       its .git file at it.
# (c) and (d) are what tie the git dir to this checkout: a pointer from a
# crafted checkout at an unrelated directory fails them however that
# directory is shaped. The reverse link (worktree gitdir file, or a
# module's config core.worktree) lives inside the candidate, so passing
# needs a file there naming this checkout: written by git when the user
# created the worktree or submodule, or by someone who can already write
# the candidate. There is no location blocklist (owner decision, B-rho):
# a crafted pointer can only reach a directory the agent could already
# write, and read-only overlays stay on top of the bind (--under-bind).
# AI agent profile/state directories included (owner-accepted exception).
# Both sides of every comparison are realpath-resolved. A worktree may lie
# anywhere (inside or outside its repository root, of a bare repository).
_wrapper_git_common_dir_ok() {
    local dir="${1%/}" home="${2%/}" wd="${3%/}" git_dir name top back
    local module_super="" why
    if [[ -L "${dir}" || ! -d "${dir}" ]]; then
        echo "not a resolved directory"; return 1
    fi
    if [[ -z "${home}" ]]; then
        echo "\$HOME unresolved"; return 1
    fi
    if [[ "${dir}" == "${home}" ]]; then
        echo "is \$HOME itself"; return 1
    fi
    # (b) shape.
    if module_super="$(_wrapper_git_module_super "${dir}")"; then
        if ! why="$(_wrapper_git_module_dir_ok "${dir}" "${module_super}")"; then
            echo "not a verified submodule git dir of ${module_super:-/} (${why})"; return 1
        fi
    fi
    if [[ ! -f "${dir}/HEAD" || -L "${dir}/HEAD" || ! -f "${dir}/config" \
            || ! -d "${dir}/objects" || ! -d "${dir}/refs" ]]; then
        echo "does not look like a git dir (config, HEAD, objects/, refs/)"; return 1
    fi
    # (c) forward link.
    git_dir="$(git -C "${wd}" rev-parse --absolute-git-dir 2>/dev/null)" || git_dir=""
    if [[ -n "${git_dir}" ]]; then
        git_dir="$(_realpath "${git_dir}")" || git_dir=""
    fi
    if [[ -n "${module_super}" && "${git_dir}" == "${dir}" ]]; then
        # Submodule checkout launched directly: no worktree entry, the
        # links are core.worktree and the checkout's gitfile.
        why="$(_wrapper_git_submodule_checkout_ok "${dir}" "${wd}")" \
            || { echo "${why}"; return 1; }
        return 0
    fi
    name="${git_dir#"${dir}/worktrees/"}"
    if [[ -z "${git_dir}" || "${name}" == "${git_dir}" || -z "${name}" || "${name}" == */* \
            || -L "${git_dir}" || ! -d "${git_dir}" ]]; then
        echo "WORKDIR's gitdir (${git_dir:-unknown}) is not a worktree of it"; return 1
    fi
    # (d) reverse link.
    top="$(git -C "${wd}" rev-parse --show-toplevel 2>/dev/null)" || top=""
    if [[ -n "${top}" ]]; then
        top="$(_realpath "${top}")" || top=""
    fi
    back=""
    if [[ -f "${git_dir}/gitdir" && ! -L "${git_dir}/gitdir" ]]; then
        IFS= read -r back <"${git_dir}/gitdir" || [[ -n "${back}" ]] || back=""
        # git may record a path relative to the entry dir
        # (worktree.useRelativePaths).
        [[ -n "${back}" && "${back}" != /* ]] && back="${git_dir}/${back}"
        if [[ -n "${back}" ]]; then
            back="$(_realpath "${back}")" || back=""
        fi
    fi
    if [[ -z "${top}" || -z "${back}" || "${back}" != "${top}/.git" ]]; then
        echo "worktree entry ${git_dir} belongs to ${back:-unknown}, not this checkout (${top:-unknown}/.git)"; return 1
    fi
    return 0
}

# Host-side git for classification only (rev-parse / config --file, which
# run no hooks or configured commands). Inherited redirections are dropped
# so the result matches what git finds from WORKDIR inside the sandbox,
# whose environment is scrubbed; a bare repo is accepted even under
# safe.bareRepository=explicit.
_wrapper_host_git() {
    ( unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR; git -c safe.bareRepository=all "$@" )
}

# Locations, relative to the resolved $HOME, that a symlinked agent config
# path (_wrapper_check_config_symlink) must not resolve to, into, or above
# (git dirs use no location list, see _wrapper_bind_git_common_dir):
# credential stores the sandbox otherwise exposes only behind explicit
# PASS_* opt-ins, files and dirs the host shell, git or session manager
# runs or loads (an RW bind there is host code execution), and the paths
# kept read-only by default (~/bin, the shared skill source; #62).
# "Above" makes the broad roots holding them (~/.config, ~/.local,
# ~/.local/share, ~/Library, ...) refusals too. A denylist: anything not
# listed under $HOME stays accepted (relocated, dotpath and multi-account
# profiles such as ~/.config/claude, ~/.claude-work, ~/profiles/codex).
_WRAPPER_CONFIG_SYMLINK_DENIED=(
    .ssh .gnupg .aws .azure .kube .docker .colima .podman
    .netrc .npmrc .pypirc .git-credentials .password-store .gitconfig
    .config/git .config/gh .config/gcloud .config/glab-cli .config/containers
    .config/systemd .config/autostart .config/environment.d
    .local/share/glab-cli .local/share/keyrings .local/bin
    "Library/Application Support/glab-cli" Library/Keychains Library/LaunchAgents
    .bashrc .bash_profile .bash_login .bash_logout .profile
    .zshrc .zshenv .zprofile .zlogin .zlogout .config/fish
    bin ai-wrapper/.agents
)
# Broad roots refused even when nothing listed above exists below them.
_WRAPPER_CONFIG_SYMLINK_BROAD_ROOTS=(
    .config .local .local/share .local/state .cache
    Library "Library/Application Support"
)

# Match a resolved path P under the resolved HOME against the lists above.
# Prints "broad <entry>" when P is a broad root itself, "denied <entry>"
# when P is in, at or above a denied location, and returns 0; returns 1
# when neither applies. Pure string check. Args: P HOME
_wrapper_home_location_denied() {
    local p="${1%/}" home="${2%/}" entry
    for entry in "${_WRAPPER_CONFIG_SYMLINK_BROAD_ROOTS[@]}"; do
        if [[ "${p}" == "${home}/${entry}" ]]; then
            printf 'broad %s' "${entry}"; return 0
        fi
    done
    for entry in "${_WRAPPER_CONFIG_SYMLINK_DENIED[@]}"; do
        if [[ "${p}" == "${home}/${entry}" || "${p}" == "${home}/${entry}"/* \
                || "${home}/${entry}" == "${p}"/* ]]; then
            printf 'denied %s' "${entry}"; return 0
        fi
    done
    return 1
}

# Guard for an agent config path (~/.claude, ~/.codex, ~/.<agent>-<name>,
# ~/.claude-<name>.json, ~/.copilot, Antigravity's profile config/) that
# the wrapper binds RW. Applies when PATH is a symlink, or resolves
# elsewhere than its spelling because an ancestor is one; other paths pass
# (callers check type/existence and may create them).
#   Mandatory validation: the symlink must resolve, without a loop, to an
#   existing target (a dangling link would let touch/mkdir create the
#   target before the bind).
#   Authorization: the target must lie strictly under $HOME, not be $HOME
#   or a broad root (_WRAPPER_CONFIG_SYMLINK_BROAD_ROOTS), and not sit in,
#   at, or above a _WRAPPER_CONFIG_SYMLINK_DENIED location — a planted
#   symlink must not turn the account bind into RW on ~/.ssh, ~/.bashrc,
#   ~/.config or /etc.
# Prints an ERROR and returns 1 on refusal. Args: PATH
_wrapper_check_config_symlink() {
    local p="${1%/}" resolved home raw_home expected entry kind=symlink
    raw_home="${HOME%/}"
    home="$(_realpath "${HOME}")" || home="${raw_home}"
    home="${home%/}"
    if [[ ! -L "${p}" ]]; then
        [[ -e "${p}" ]] || return 0
        resolved="$(_realpath "${p}")" || resolved=""
        case "${p}" in
            "${raw_home}"/*) expected="${home}/${p#"${raw_home}"/}" ;;
            *) expected="${p}" ;;
        esac
        [[ -n "${resolved}" && "${resolved%/}" == "${expected}" ]] && return 0
        kind="path behind a symlinked parent"
    fi
    if ! resolved="$(_realpath "${p}")" || [[ -z "${resolved}" ]]; then
        echo "ERROR: ${p} is a ${kind} whose target cannot be resolved (symlink loop or unreadable). Inspect and remove before launching." >&2
        return 1
    fi
    resolved="${resolved%/}"
    if [[ ! -e "${resolved}" ]]; then
        echo "ERROR: ${p} is a ${kind} whose target does not exist (resolves to ${resolved}). Create the target or remove the link before launching." >&2
        return 1
    fi
    if [[ -z "${home}" || "${resolved}" != "${home}"/* ]]; then
        echo "ERROR: ${p} is a ${kind} pointing outside \$HOME (resolves to ${resolved}). Refusing — the bind would grant RW on the target." >&2
        return 1
    fi
    entry="$(_wrapper_home_location_denied "${resolved}" "${home}")" || return 0
    if [[ "${entry}" == "broad "* ]]; then
        echo "ERROR: ${p} is a ${kind} to a broad directory (resolves to ${resolved}). Refusing — point it at a dedicated directory such as ${home}/${entry#broad }/<agent>." >&2
    else
        echo "ERROR: ${p} is a ${kind} into or above a credential location or host-executed path (${home}/${entry#denied }; resolves to ${resolved}). Refusing — the bind would grant RW on it." >&2
    fi
    return 1
}

# ===== CLIENT PERSISTENT CONTROLS (#48 / #86) =====
# A client profile dir (~/.claude, ~/.codex, ...) is bound RW for session,
# history and auth state, but it also holds controls every later session
# loads: settings, skills, plugins, hooks, prompts. An agent that edits
# them changes future (also unsandboxed) sessions. This helper keeps the
# controls that exist at launch read-only and pins their directories:
#   - the profile base and every directory between it and a control are
#     pinned (_wrapper_add_pin), so none can be renamed away and replaced;
#   - each existing control is over-mounted read-only (_wrapper_add_ro_bind;
#     bwrap mount point / Seatbelt write deny incl. ancestor pins).
# All pins are emitted before the first RO overlay (bwrap: later mount
# wins). Call after the RW bind of SRC_BASE and after the menu
# (AI_SANDBOX_ALLOW_SETTINGS is a menu setting).
# Absent controls are skipped and stay creatable (nothing is created on
# the host). A control that is a symlink, sits behind one inside the
# profile, or is neither a file nor a directory refuses the launch:
# binding its target would protect, or expose, the wrong path. Controls
# inside WORKDIR stay editable (trusted maintenance of the active
# repository); a control containing WORKDIR is left writable with a WARN.
# AI_SANDBOX_ALLOW_SETTINGS=1 skips everything with a WARN.
#   TAG       - log tag
#   SRC_BASE  - host profile dir (may be reached through a symlink)
#   DST_BASE  - where the sandbox sees it ("" = SRC_BASE; Linux remapping
#               of named accounts, dropped on macOS)
#   CONTROL.. - paths relative to the base, or absolute (no remapping)
# Returns 1 (after an ERROR) when the launch must be refused.
_wrapper_protect_client_controls() {
    local tag="${1}" src_base="${2%/}" dst_base="${3:-${2}}"
    shift 3
    dst_base="${dst_base%/}"
    if [[ "${AI_SANDBOX_ALLOW_SETTINGS:-0}" == "1" ]]; then
        echo_log "WARN" "[${tag}] AI_SANDBOX_ALLOW_SETTINGS=1: client persistent controls (settings, skills, plugins, hooks) in ${src_base} are writable in the sandbox. The agent can modify future behavior outside this session; review any changes before running un-sandboxed tools."
        return 0
    fi
    if [[ ! -d "${src_base}" ]]; then
        [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_wrapper_protect_client_controls: ${src_base} absent; nothing to protect"
        return 0
    fi
    local base wd
    if ! base="$(_realpath "${src_base}")" || [[ -z "${base}" ]]; then
        echo_log "ERROR" "[${tag}] Cannot resolve ${src_base}; refusing to launch without client settings protection."
        return 1
    fi
    base="${base%/}"
    wd="$(_realpath "$(pwd -P)" 2>/dev/null)" || wd=""
    wd="${wd%/}"

    # Pins as relative dirs ("" = base) or absolute paths; RO overlays as
    # SRC / DST pairs.
    local -a pins=("") ro_src=() ro_dst=()
    local control src dst expected resolved prefix part
    for control in "$@"; do
        control="${control%/}"
        if [[ "${control}" == /* ]]; then
            src="${control}"; dst="${control}"
            expected="$(_realpath "$(dirname -- "${control}")" 2>/dev/null)" || expected=""
            expected="${expected%/}/$(basename -- "${control}")"
        else
            src="${base}/${control}"; dst="${dst_base}/${control}"; expected="${src}"
        fi
        if [[ ! -e "${src}" && ! -L "${src}" ]]; then
            [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_wrapper_protect_client_controls: ${src} absent; stays creatable"
            continue
        fi
        if [[ -L "${src}" ]] || ! resolved="$(_realpath "${src}")" || [[ "${resolved%/}" != "${expected}" ]]; then
            echo_log "ERROR" "[${tag}] Refusing to launch: client control ${src} is a symlink or behind one (it would protect or expose another path). Replace it with a regular file or directory, or set AI_SANDBOX_ALLOW_SETTINGS=1 to leave client settings writable."
            return 1
        fi
        if [[ ! -f "${src}" && ! -d "${src}" ]]; then
            echo_log "ERROR" "[${tag}] Refusing to launch: client control ${src} is neither a regular file nor a directory."
            return 1
        fi
        src="${resolved%/}"
        if [[ -n "${wd}" && ( "${src}" == "${wd}" || "${src}" == "${wd}"/* ) ]]; then
            [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_wrapper_protect_client_controls: ${src} is inside WORKDIR ${wd}; left writable"
            continue
        fi
        if [[ -n "${wd}" && "${wd}" == "${src}"/* ]]; then
            echo_log "WARN" "[${tag}] WORKDIR ${wd} is inside client control ${src}; it stays writable in the sandbox so this session can edit it. Review changes before later sessions load them."
            continue
        fi
        if [[ "${control}" != /* ]]; then
            prefix=""
            while [[ "${control}" == */* ]]; do
                part="${control%%/*}"; control="${control#*/}"
                prefix="${prefix:+${prefix}/}${part}"
                pins+=("${prefix}")
            done
        fi
        ro_src+=("${src}"); ro_dst+=("${dst}")
    done

    local -a unique=()
    local p seen i
    for p in "${pins[@]}"; do
        for seen in "${unique[@]+"${unique[@]}"}"; do
            [[ "${seen}" == "${p}" ]] && continue 2
        done
        unique+=("${p}")
    done
    for p in "${unique[@]}"; do
        _wrapper_client_control_bind _wrapper_add_pin "${base}${p:+/${p}}" "${dst_base}${p:+/${p}}"
    done
    for i in ${ro_src[@]+"${!ro_src[@]}"}; do
        _wrapper_client_control_bind _wrapper_add_ro_bind "${ro_src[i]}" "${ro_dst[i]}"
    done
    return 0
}

# Apply ADDER (_wrapper_add_pin / _wrapper_add_ro_bind) to SRC at DST and,
# on Linux when they differ, at SRC too: an alias of the host path (e.g.
# AI_SANDBOX_EXTRA_RW_DIRS naming it) must not stay writable.
_wrapper_client_control_bind() {
    local adder="${1}" src="${2}" dst="${3}"
    [[ "${dst}" != "${src}" && "${_wrapper_os}" != "Darwin" ]] && "${adder}" "${src}"
    "${adder}" "${src}" "${dst}"
}

# Bind-list flags that the interactive Settings sub-menu can toggle
# need to be evaluated AFTER the menu — otherwise enabling them via
# `s)` has no effect (WRAPPER_FLAGS is frozen by then). The shared
# wrapper re-reads env-passthrough gates inside run_sandboxed_agent
# at exec time, so those keep working; this function covers only the
# bind-list side. Callers exit on a non-zero return (no step refuses the
# launch today).
_apply_post_menu_binds() {
    # The git dir of a linked worktree or submodule checkout (outside
    # WORKDIR). No setting gates it; it runs here so every wrapper gets it
    # from one call site.
    _wrapper_bind_git_common_dir

    # GitLab CLI (glab) on-disk credentials. AI_SANDBOX_PASS_GITLAB
    # already propagates GITLAB_TOKEN / CI_JOB_TOKEN env vars; when
    # the user has no env var set, glab reads its token from the
    # on-disk config instead. Bind that config dir RO when the same
    # flag is set so `glab` works end-to-end without the user having
    # to also export the token. RO is sufficient: glab only writes
    # the config when running `glab auth login`, which is not the
    # agent's job.
    #
    # macOS uses ~/Library/Application Support/glab-cli/; the XDG
    # paths under ~/.config/glab-cli and ~/.local/share/glab-cli are
    # honoured as fallbacks (some users set XDG_CONFIG_HOME to
    # relocate) and are the only paths that exist on Linux.
    if [[ "${AI_SANDBOX_PASS_GITLAB:-0}" == "1" ]]; then
        local _glab_dir
        for _glab_dir in \
                "${HOME}/Library/Application Support/glab-cli" \
                "${HOME}/.config/glab-cli" \
                "${HOME}/.local/share/glab-cli"; do
            [[ -d "${_glab_dir}" ]] && _wrapper_add_ro_bind "${_glab_dir}"
        done
    fi
    return 0
}

# ===== SETTINGS CATALOG =====
# Centralised list of env vars that change wrapper runtime behaviour.
# Drives the startup banner table AND the interactive toggle sub-menu so
# the two views never drift. Adding a new tunable is a one-line change here.
#
# Format: NAME|TYPE|DEFAULT|SEVERITY|HEADLINE|DETAIL|CATEGORY|OS_SCOPE
#   TYPE     - bool (0/1), str (free text), path (free text, path-shaped)
#   DEFAULT  - value substituted when the var is unset/empty (bools only;
#              str/path treat empty as meaningful)
#   SEVERITY - info (no banner colour), yellow (scope widening), red
#              (credential / sandbox-defeating). Drives banner colour and
#              the in-table marker colour.
#   HEADLINE - short verb-led label shown on row 1 (user-facing; no env var name)
#   DETAIL   - supporting explanation shown on the indented row 2
#   CATEGORY - grouping key; one of debug, additional, sensitive,
#              credentials, networking. Entries with the same CATEGORY
#              render under a shared header in both the banner and
#              toggle views.
#   OS_SCOPE - optional 8th field: "darwin" (macOS-only, hidden on Linux),
#              "linux" (Linux-only, hidden on macOS), or empty/omitted
#              (shown on every OS — the default). Entries without a
#              trailing "|OS_SCOPE" parse with an empty 8th field via the
#              `read` splitting below, so existing 7-field rows need no
#              changes. Used for settings whose backend is only
#              implemented on one OS today (see _AI_SETTINGS_LIST filtering
#              right after this array literal).
# Per-OS text fragments for catalog entries that are shown on every OS but
# describe an OS-specific mechanic. Computed once here (from the _wrapper_os
# set above) rather than re-checking `uname` per entry. Entries that are
# ENTIRELY OS-specific (no backend at all on the other OS) use the OS_SCOPE
# 8th field instead — see AI_SANDBOX_PROFILE* and the darwin-only rows below.
if [[ "${_wrapper_os}" == "Darwin" ]]; then
    _ai_sensitive_workdir_extra=", ~/Library"
    _ai_sensitive_workdir_system=", and binding those or a top-level system directory as extra RW/RO dirs; launching from a system directory stays refused on macOS"
    _ai_gitlab_bind_note="RO-binds ~/Library/Application Support/glab-cli"
    _ai_docker_rootless_note=""
else
    _ai_sensitive_workdir_extra=""
    _ai_sensitive_workdir_system=", or a top-level system directory, and binding such dirs as extra RW/RO dirs"
    _ai_gitlab_bind_note="RO-binds the XDG glab-cli config paths (~/.config/glab-cli, ~/.local/share/glab-cli)"
    _ai_docker_rootless_note=" Also shares the rootless Docker and Podman sockets (\$XDG_RUNTIME_DIR/docker.sock, \$XDG_RUNTIME_DIR/podman/podman.sock) when they exist."
fi

# Order here is the display order in both views; categories are
# arranged so the most frequently used (networking) sits closest to the
# input prompt at the bottom, and rarer ones (debug) are at the top.
_AI_SETTINGS_LIST=(
    # Debug
    "AI_SANDBOX_DRYRUN|bool|0|info|Dry run — print plan, don't launch|Shows what would run (argv, env, profile) and exits. Use when: checking which argv, environment and SBPL rules a settings change produces before a real launch, or attaching that plan to a bug report.|debug|darwin"
    "AI_SANDBOX_DEBUG|bool|0|info|Show verbose internal logging|For troubleshooting the wrapper itself — path-resolution details. Use when: a bind, preset or launch refusal behaves unexpectedly, or to list the requests the egress proxy refused.|debug"

    # Additional settings (env vars, profiles)
    "AI_SANDBOX_PASS_ENV|str||red|Pass extra env vars by name|Comma-separated list of variable names to share (advanced). Use when: a build or tool inside the sandbox needs one variable from your shell, e.g. JAVA_HOME, GOFLAGS or a project config path; not for secrets you would not hand the agent.|additional"
    "AI_SANDBOX_EXTRA_RW_DIRS|str||yellow|Extra read-write bind directories|Comma-separated absolute paths granted RW inside the sandbox (in addition to WORKDIR), at their resolved path. Missing entries WARN and are skipped; an entry that does not resolve to a directory refuses the launch. Use when: the task must write outside WORKDIR, e.g. a sibling repo changed together with this one or a shared build output dir.|additional"
    "AI_SANDBOX_EXTRA_RO_DIRS|str||yellow|Extra read-only bind directories|Comma-separated absolute paths granted RO inside the sandbox, at their resolved path. Missing entries WARN and are skipped; an entry that does not resolve to a directory refuses the launch. Use when: the agent must read material outside WORKDIR without changing it, e.g. another checkout, an SDK, docs or datasets.|additional"
    "AI_SANDBOX_ALLOW_ANDROID|bool|0|yellow|Share ~/Android (read-write)|Binds ~/Android RW (Android SDK, emulator images, debug keystores). The agent can change SDK tools the host runs later. Off: ~/Android is not visible inside the sandbox. Use when: building or testing Android apps (gradle, adb, the emulator) from the sandbox.|additional|linux"
    "AI_SANDBOX_PROFILE|path||red|Custom sandbox profile override|Path to a custom SBPL file. Default: ai_wrapper_data/claude_wrapper.sb. Set only if you have a custom restrictions file. Use when: you maintain your own SBPL restrictions, e.g. a stricter profile for untrusted repos.|additional|darwin"
    "AI_SANDBOX_PROFILE_TRUST_ME|bool|0|red|Skip safety check on custom profile|Bypasses the (version 1) + (deny default) validation. Set only if your profile intentionally relaxes the sandbox. Use when: your reviewed custom profile is deliberately permissive and fails that check.|additional|darwin"

    # Sensitive directories
    "AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR|bool|0|red|Allow launch from sensitive dirs|Permits launching from \$HOME itself, a dotfile dir directly under \$HOME${_ai_sensitive_workdir_extra}${_ai_sensitive_workdir_system} — the write fence then grants RW there, which likely exposes credentials. Use when: you deliberately let the agent edit your dotfiles or \$HOME itself (e.g. maintaining ~/.config) and accept that write fence.|sensitive"
    "AI_SANDBOX_ALLOW_SETTINGS|bool|0|red|Allow editing client settings and skills|Leaves the client profile's settings, skills, plugins, hooks and prompts writable (advanced: maintaining them from a session). The agent can then change how later sessions, also unsandboxed ones, behave. Off: the ones present at launch are read-only and their directories pinned; controls inside WORKDIR stay editable. Use when: you edit the client's own settings, skills, plugins or hooks from a session (e.g. developing a skill in place) and review the result.|sensitive"
    "AI_SANDBOX_ALLOW_BIN_RW|bool|0|red|Allow writing ~/bin|Binds ~/bin RW instead of read-only. ~/bin is first on the sandbox PATH and on yours, so the agent can plant or replace programs you later run outside the sandbox. Off: ~/bin stays usable (read and run) but not writable. Use when: the task is to add or update your own scripts in ~/bin and you review them before running them.|sensitive|linux"
    "AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW|bool|0|red|Allow editing the shared agent-skill source|Binds ~/ai-wrapper/.agents RW instead of read-only. setup_skills copies it into every client's skill dir, so the agent can rewrite skills other clients and sessions load. Off: skills stay readable but not writable. Use when: developing or editing the shared skills themselves from a session.|sensitive|linux"
    "AI_SANDBOX_ALLOW_XDG_RUNTIME_RW|bool|0|red|Share the whole user runtime dir (read-write)|Binds your \$XDG_RUNTIME_DIR (usually /run/user/UID) RW after checking it is your own, non-shared directory. Every socket in it becomes reachable with your user ID — D-Bus session bus, systemd --user, keyring, display and audio servers, SSH/GPG agents, rootless Docker/Podman — whatever the SSH-agent and Docker settings say; what the agent can do depends on each service and may include running programs outside the sandbox. Off: the sandbox gets a private, empty runtime dir with only the sockets you enable. Use when: the agent must reach a session service the named sockets do not cover, e.g. systemctl --user or other D-Bus clients, a GPG agent, the keyring, Wayland or X11 apps, PipeWire audio; prefer the SSH-agent and Docker settings when they suffice.|sensitive|linux"
    "AI_SANDBOX_ALLOW_NESTED_USERNS|bool|0|red|Allow nested user namespaces|Lets the agent create its own user namespaces inside the sandbox (needed by nested bubblewrap/Flatpak, Chromium or Playwright without --no-sandbox, and rootless container engines run inside the sandbox; Docker/Podman through a shared host socket work without it). Use when: the agent runs tools that build their own sandbox or containers inside this one. Needs it: npx playwright test, headless Chrome with its own sandbox, podman run / buildah bud inside the sandbox, bwrap, flatpak run, unshare -Ur. Not needed: docker/podman via the host socket, Chromium --no-sandbox. Each namespace gives the agent namespace-root capabilities and more kernel attack surface. Off: creating a user namespace fails; the launch is refused if bubblewrap cannot enforce that.|sensitive|linux"
    "AI_SANDBOX_ALLOW_TIOCSTI|bool|0|yellow|Allow terminal input injection (TIOCSTI)|Launches without the seccomp filter that blocks ioctl(TIOCSTI) and ioctl(TIOCLINUX). On kernels that still allow TIOCSTI the agent can then type commands into your terminal that run after the session ends. Off: the filter is built with python3 + libseccomp and the launch is refused if it cannot be; the terminal, /dev/tty, resize and Ctrl+C work as usual. Use when: that refusal blocks you: the host lacks python3 or the libseccomp runtime, an unsupported CPU architecture, a bubblewrap too old for --add-seccomp-fd, or the kernel rejects the filter. Usually harmless where sysctl dev.tty.legacy_tiocsti=0 (Linux 6.2+ then refuses TIOCSTI to unprivileged processes).|sensitive|linux"
    "AI_SANDBOX_ALLOW_RO_HOMEDIR|bool|0|yellow|Share home directory (read-only)|Agent can read everything in \$HOME except credentials. Use when: the task reads files spread across your home (other projects, notes, tool configs) and you accept that most of \$HOME is readable.|sensitive|darwin"

    # Credentials
    "AI_SANDBOX_ALLOW_RO_CREDENTIALS|bool|0|red|Let agent read residual credential files|Includes ~/.config/gcloud, ~/.gnupg, ~/.netrc, ~/.npmrc, ~/.pypirc. ~/.ssh, ~/.aws, ~/.kube, ~/.docker are gated by their matching PASS_* setting instead. Use when: a tool in the session needs one of them, e.g. the gcloud CLI, gpg signing or verification, npm or pip with private registries or publishing, .netrc-authenticated downloads.|credentials"
    "AI_SANDBOX_PASS_SSH_AGENT|bool|0|red|Share SSH agent + ~/.ssh|Passes SSH_AUTH_SOCK and RO-grants ~/.ssh so agent reads private key files and known_hosts directly. Use when: the agent must use your SSH keys, e.g. git over SSH (also needs unrestricted network), ssh or scp to your hosts, SSH commit signing.|credentials"
    "AI_SANDBOX_PASS_KUBE|bool|0|red|Share Kubernetes context + ~/.kube|Passes KUBECONFIG / KUBE_EDITOR and RO-grants ~/.kube; agent reads cluster certs/tokens and can deploy to your clusters. Also lets the egress proxy reach the kubeconfig server host names when they resolve to private LAN addresses (servers given as IP addresses cannot be allowed by name). Use when: the agent runs kubectl, helm or k9s against your clusters.|credentials"
    "AI_SANDBOX_PASS_AWS|bool|0|red|Share AWS credentials + ~/.aws|Passes all AWS_* env vars and RO-grants ~/.aws — agent has full AWS account access. Use when: the agent runs the aws CLI, terraform or SDK code against your AWS account.|credentials"
    "AI_SANDBOX_PASS_GH|bool|0|red|Share GitHub token|Passes GITHUB_TOKEN / GH_TOKEN; agent can push to your repos. Use when: the agent uses gh (PRs, issues, releases) or pushes to GitHub over HTTPS.|credentials"
    "AI_SANDBOX_PASS_GITLAB|bool|0|red|Share GitLab token + glab config|Passes GITLAB_TOKEN / CI_JOB_TOKEN env vars AND ${_ai_gitlab_bind_note} so glab reads its on-disk token. Agent can push to your repos. Also lets the egress proxy reach the GitLab hosts named by GITLAB_HOST / GL_HOST and glab's config.yml (hosts: and api_host:; gitlab.com excluded) when they resolve to private LAN addresses. Use when: the agent uses glab or pushes to GitLab over HTTPS.|credentials"
    "AI_SANDBOX_PASS_OPENAI|bool|0|red|Share OpenAI credentials|Passes all OPENAI_* env vars (advanced). Use when: code the agent runs (tests, scripts, evals) calls the OpenAI API with your key.|credentials"
    "AI_SANDBOX_ALLOW_KEYCHAIN|bool|0|red|Allow macOS Keychain access|Grants RW on ~/Library/Keychains and lookups of the SecurityServer / securityd keychain daemons and secd (com.apple.securityd.xpc, the Data Protection keychain). The agent can then read (and add or change) any keychain item whose access list lets the calling program in without a prompt. Off: keychain-backed logins (Claude Code keeps its OAuth login in the Keychain) fail inside the sandbox; pass the credential through an env var (e.g. CLAUDE_CODE_OAUTH_TOKEN) instead. Use when: a client must use its Keychain login and you cannot pass a token, or a tool needs Keychain items (e.g. git credential-osxkeychain).|credentials|darwin"

    # Networking (localhost, local docker)
    "AI_SANDBOX_ALLOW_UNRESTRICTED_NET|bool|0|red|Allow unrestricted network access|Gives the sandbox open networking without the egress proxy: the agent can reach services on this machine (localhost; on Linux also abstract UNIX sockets such as X11 or D-Bus), your LAN, Tailscale peers and cloud metadata endpoints, and connect anywhere. Off: the sandbox cannot connect out directly (Linux: its own network namespace; macOS: Seatbelt denies IP networking); HTTP(S) goes through a host proxy that refuses loopback, private LAN (RFC 1918), 100.64.0.0/10 (incl. Tailscale), link-local incl. cloud metadata 169.254.169.254, IPv6 ULA and link-local, multicast and reserved destinations. Use when: SSH git remotes (git@github.com:...), ssh, scp or rsync; tools that ignore http_proxy; reaching localhost dev servers or databases on the host; LAN or Tailscale hosts; raw TCP/UDP.|networking"
    "AI_SANDBOX_BLOCK_LOCALHOST|bool|0|info|Block localhost network access|Denies network access to services running on your own machine. Only matters with AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1: the default restricted network already blocks localhost. Use when: you need unrestricted networking (e.g. SSH remotes) but the agent must not reach dev databases, kubectl proxy or other services on loopback.|networking|darwin"
    "AI_SANDBOX_ALLOW_DOCKER|bool|0|red|Mount Docker / Colima socket|RW on /var/run/docker.sock, ~/.colima, ~/.docker. With the daemon running this is a full sandbox escape: agent can launch privileged containers and obtain host root. Off by default — opt in only when the session needs docker.${_ai_docker_rootless_note}. Use when: the session must build or run containers (docker build, docker compose up, testcontainers) and you accept the host-root risk.|networking"
    "AI_SANDBOX_PASS_TAILSCALE|bool|0|red|Share Tailscale daemon socket|RO-binds /run/tailscale/tailscaled.sock. The read-only bind only stops the socket file being replaced; it does not make the Tailscale API read-only. tailscaled authorises requests by your user ID, so the agent can do whatever tailscaled lets your user do (e.g. change settings or connect to peers, if you are the operator). Also lets the egress proxy reach *.ts.net (MagicDNS) names on Tailscale (100.64.0.0/10) addresses. Off: no socket in the sandbox. Use when: the agent runs the tailscale CLI (status, ping, serve) through your daemon.|networking|linux"
    "AI_SANDBOX_PRIVATE_HOSTS|str||yellow|Reach internal hosts by name through the proxy|Space- or comma-separated host suffixes (e.g. corp.example) the egress proxy may connect to when they resolve to private LAN addresses (10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7); a suffix also covers its subdomains. Loopback and link-local / cloud metadata stay blocked. Anyone who controls DNS for these names can point them at other internal machines. Use when: the agent must reach internal HTTP(S) APIs, package mirrors, artifact registries or docs on private LAN addresses without opening unrestricted network access.|networking"
    "AI_SANDBOX_PASS_DOCKER|bool|0|red|Share Docker client env vars + ~/.docker|Passes DOCKER_HOST, DOCKER_CONFIG, DOCKER_CERT_PATH, DOCKER_BUILDKIT and RO-grants ~/.docker (registry auth tokens). Pair with 'Mount Docker / Colima socket' to actually talk to the daemon. Use when: the docker client needs your DOCKER_HOST, contexts or registry logins, e.g. pulling private images or docker push.|networking"
)
unset _ai_sensitive_workdir_extra _ai_sensitive_workdir_system _ai_gitlab_bind_note _ai_docker_rootless_note

# OS-scope filtering: drop catalog rows whose trailing OS_SCOPE field
# doesn't match the current OS, so a setting with no backend on this OS
# (e.g. AI_SANDBOX_BLOCK_LOCALHOST / AI_SANDBOX_ALLOW_RO_HOMEDIR, macOS-only
# today) is hidden from the menu entirely rather than shown-but-nonfunctional.
# Runs once at source-time, before any function iterates _AI_SETTINGS_LIST
# and before agent-specific libs (e.g. claude_wrapper_lib.bash) `+=` onto it.
# `IFS='|' read -r ... <<<"${entry}"` naturally yields an empty 8th field
# for 7-field rows, so existing rows need no trailing "|" added.
_ai_settings_os="$(uname -s)"
_ai_settings_filtered=()
for _ai_settings_entry in "${_AI_SETTINGS_LIST[@]}"; do
    IFS='|' read -r _ai_n _ai_t _ai_d _ai_sev _ai_hl _ai_det _ai_cat _ai_scope <<<"${_ai_settings_entry}"
    case "${_ai_scope}" in
        darwin) [[ "${_ai_settings_os}" == "Darwin" ]] && _ai_settings_filtered+=("${_ai_settings_entry}") ;;
        linux)  [[ "${_ai_settings_os}" == "Linux"  ]] && _ai_settings_filtered+=("${_ai_settings_entry}") ;;
        *)      _ai_settings_filtered+=("${_ai_settings_entry}") ;;
    esac
done
_AI_SETTINGS_LIST=("${_ai_settings_filtered[@]}")
unset _ai_settings_os _ai_settings_filtered _ai_settings_entry _ai_scope
unset _ai_n _ai_t _ai_d _ai_sev _ai_hl _ai_det _ai_cat

# Plugin hook `_extra_settings_register` is invoked from _load_extra_profile
# (below) right after the plugin file is sourced. Invoking it here would fire
# before AI_WRAPPER_EXTRA_PROFILE is loaded by the wrapper entry script — the
# callback would be undefined, no rows would land, and the later preset
# autoload would emit "unknown setting" WARNs for every plugin-owned key.

# Bump only when the load logic needs version-conditional handling.
# Today: written into the preset file header for forward-compat
# debugging; not consulted on load (older presets load with a WARN
# on unrecognised keys, not a hard error).
_AI_WRAPPER_PRESET_FORMAT_VERSION="2026-05-28"

# Settings removed from the catalog that saved presets may still name
# (_preset_autosave writes every key). _preset_autoload skips them without
# the "unknown setting" WARN and prints one notice when the saved value
# asked for something other than the old default, since that behaviour is
# gone; the next autosave drops them. The three git settings were retired
# when git dirs became fully writable (docs/security-concerns.md "Git
# metadata is writable by the agent"). Space-separated.
_AI_RETIRED_SETTINGS="AI_SANDBOX_ALLOW_GIT_CONFIG AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES AI_SANDBOX_BLOCK_LINKED_GIT_DIRS"

# Returns 0 when NAME is in _AI_RETIRED_SETTINGS.
_setting_is_retired() {
    case " ${_AI_RETIRED_SETTINGS} " in
        *" ${1} "*) return 0 ;;
    esac
    return 1
}

# Parse one catalog entry into globals: _set_name _set_type _set_default
# _set_severity _set_headline _set_detail _set_category _set_os_scope.
# Globals because bash 3.2 lacks namerefs and returning an 8-tuple via
# stdout would force the caller to split it again. _set_os_scope is the
# optional 8th field — a 7-field entry (no trailing "|OS_SCOPE") yields an
# empty string here, same backward-compatible contract as the filtering
# step above.
_parse_setting_entry() {
    local entry="${1}"
    _set_name="${entry%%|*}"; entry="${entry#*|}"
    _set_type="${entry%%|*}"; entry="${entry#*|}"
    _set_default="${entry%%|*}"; entry="${entry#*|}"
    _set_severity="${entry%%|*}"; entry="${entry#*|}"
    _set_headline="${entry%%|*}"; entry="${entry#*|}"
    _set_detail="${entry%%|*}"; entry="${entry#*|}"
    _set_category="${entry%%|*}"
    if [[ "${entry}" == *"|"* ]]; then
        entry="${entry#*|}"
        _set_os_scope="${entry}"
    else
        _set_os_scope=""
    fi
}

# Map a category key from the catalog to its user-facing label. Unknown
# keys round-trip unchanged so a typo in the catalog is visible rather
# than silently swallowed.
_category_label() {
    case "${1}" in
        debug)        printf 'Debug' ;;
        account)      printf 'Account' ;;
        additional)   printf 'Additional settings' ;;
        sensitive)    printf 'Sensitive directories' ;;
        credentials)  printf 'Credentials' ;;
        networking)   printf 'Networking' ;;
        *)
            # Defer unknown categories to a plugin-provided label function
            # (loaded via AI_WRAPPER_EXTRA_PROFILE) so plugin-registered
            # settings can group under their own category header. The
            # callback must printf the label and return 0 to consume the
            # key; a non-zero return (or no callback) falls back to the raw
            # key so a typo in the catalog is visible rather than silently
            # swallowed.
            if declare -f _extra_category_label >/dev/null 2>&1 \
                    && _extra_category_label "${1}"; then
                :
            else
                printf '%s' "${1}"
            fi
            ;;
    esac
}

# Category headers all share one hue (bold dark blue). Per-row colour
# now encodes state (green=disabled, red=enabled), so giving each
# category a distinct colour too would over-saturate the palette. The
# helper still takes a category key for forward-compatibility / future
# differentiation.
_category_color() {
    printf '\033[1;34m'
}

# Pick the row colour from the setting's current state, not its
# severity. Green = currently inactive (bool=0 or str/path empty);
# red = currently active. Applied to the headline + dotted leader +
# state line in the banner and to the matching "N) [ ] ..." line in
# the toggle sub-menu.
_setting_state_color() {
    local cur="${1}"
    if [[ -n "${cur}" && "${cur}" != "0" ]]; then
        printf '\033[1;31m'   # red — enabled
    else
        printf '\033[1;32m'   # green — disabled
    fi
}

# Echo the current value of a setting (after default-substitution). For
# bools, anything other than "1" is normalised to "0" — matching how the
# wrapper itself interprets these vars elsewhere. An empty str/path takes
# the catalog default (e.g. CLAUDE_ACCOUNT -> "private"); most str/path
# defaults are empty, so empty stays empty for them. Agent libs must not
# export such defaults at source time: _preset_autoload treats any set
# variable as caller-set and would skip the saved value.
_setting_current_value() {
    local name="${1}" type="${2}" default="${3}" cur
    cur="${!name:-}"
    [[ -z "${cur}" ]] && cur="${default}"
    if [[ "${type}" == "bool" && "${cur}" != "1" ]]; then
        cur="0"
    fi
    printf '%s' "${cur}"
}

# Render the settings table (used by show_header and toggle_settings_menu).
# Output goes to /dev/tty so show_main_menu's $() capture stays clean.
# Colour is only applied when (a) the setting is non-default AND (b) its
# severity is yellow/red. Default-state rows render uncoloured.
#
# First arg: mode — "compact" or "full".
#   compact — skip rows whose current value equals the catalog default; if
#             every row is filtered out, print a one-line "All settings at
#             default" hint so the screen doesn't look empty. Category
#             headers are suppressed when no row under them survives.
#   full    — render every row (used by toggle_settings_menu's full view).
#
# Layout B (two rows per entry):
#   Row 1: 2-sp indent + headline + dotted leader + state (≈78 col wide).
#   Row 2: 4-sp indent + "↳ " + detail, soft-wrapped at ~74 cols with
#          continuations indented 6 sp to align under the arrow.
# The env var name is intentionally absent from this view — it appears
# only at the value-edit prompt in toggle_settings_menu.
_render_settings_table() {
    local mode="${1:-full}"
    local entry cur reset state line wrapped first
    local last_category=""
    local headline_width=50 total_width=78
    local rendered_any=0
    reset='\033[0m'
    echo "Current settings:" >/dev/tty
    for entry in "${_AI_SETTINGS_LIST[@]}"; do
        _parse_setting_entry "${entry}"
        cur="$(_setting_current_value "${_set_name}" "${_set_type}" "${_set_default}")"
        # In compact mode, skip rows whose current value matches the
        # catalog default. For bools _setting_current_value normalises
        # to "0"/"1" and the default is "0"; for str/path the default
        # is empty in the catalog and an unset/empty current value is
        # treated as default. A direct string compare covers both cases.
        if [[ "${mode}" == "compact" && "${cur}" == "${_set_default}" ]]; then
            continue
        fi
        if [[ "${_set_category}" != "${last_category}" ]]; then
            echo "" >/dev/tty
            printf '%b%s%b\n' "$(_category_color "${_set_category}")" "$(_category_label "${_set_category}")" "${reset}" >/dev/tty
            last_category="${_set_category}"
        fi
        case "${_set_type}" in
            bool)
                if [[ "${cur}" == "1" ]]; then state="[x]"; else state="[ ]"; fi
                ;;
            str|path)
                if [[ -n "${cur}" ]]; then state="= ${cur}"; else state="= <unset>"; fi
                ;;
        esac
        # Row colour: green if currently disabled, red if currently
        # enabled. Severity (red/yellow per knob) is no longer used —
        # the active/inactive split is the visual encoding.
        local row_color
        row_color="$(_setting_state_color "${cur}")"
        # Row 1: headline + dotted leader + state. If the headline is
        # wider than headline_width, fall back to "<headline> <state>"
        # with a single space — no leader, no truncation.
        local hl_len=${#_set_headline} st_len=${#state} pad_count dots
        if (( hl_len < headline_width )); then
            pad_count=$(( total_width - hl_len - st_len - 2 - 1 ))
            (( pad_count < 3 )) && pad_count=3
            dots=""
            local _i
            for (( _i=0; _i<pad_count; _i++ )); do dots+="."; done
            line="  ${_set_headline} ${dots} ${state}"
        else
            line="  ${_set_headline} ${state}"
        fi
        printf '%b%s%b\n' "${row_color}" "${line}" "${reset}" >/dev/tty
        # Row 2: detail, soft-wrapped. First wrapped line gets the arrow
        # prefix; continuations align under the text after the arrow.
        # Detail text stays uncoloured so the colour-coding signal is
        # concentrated on the headline/state row.
        wrapped="$(printf '%s\n' "${_set_detail}" | fold -s -w 74)"
        first=1
        while IFS= read -r dline; do
            if (( first == 1 )); then
                printf '    ↳ %s\n' "${dline}" >/dev/tty
                first=0
            else
                printf '      %s\n' "${dline}" >/dev/tty
            fi
        done <<<"${wrapped}"
        rendered_any=1
    done
    # Compact mode with zero surviving rows: leave a one-line marker so
    # the menu doesn't look empty / broken. Full mode never hits this
    # branch — the catalog always has entries.
    if [[ "${mode}" == "compact" ]] && (( rendered_any == 0 )); then
        echo "  All settings at default. Press 's' to change; ?N there shows what setting N does and when to use it." >/dev/tty
    fi
    echo "" >/dev/tty
}

# ----- Per-workdir, per-agent auto-persist preset helpers -----
#
# Settings are automatically saved to a per-workdir, per-agent file under
# $XDG_CONFIG_HOME/ai-wrapper/last-preset/<hash>-<agent>.env where hash
# is the first 12 hex chars of the SHA-256 of the resolved workdir
# path (sha256sum, or shasum -a 256 where sha256sum is absent) and
# agent is AI_WRAPPER_AGENT_ID (set by each agent lib, e.g. "claude",
# "codex"). Per-agent files keep the Claude and Codex wrappers
# from clobbering each other's settings when both run in one workdir.
# The file header carries human-readable "# workdir: <path>" and
# "# agent: <id>" comments so users can grep to identify files.
#
# Migration: releases before per-agent files wrote one shared
# <hash>.env per workdir. _preset_autoload falls back to that legacy
# file (read-only) until this agent's own file exists; the next
# _preset_autosave then writes the per-agent file. The legacy file is
# left in place so the other agents can migrate from it too, and is
# only removed by an explicit _preset_clear.
#
# Fail closed: when the workdir identity cannot be computed (no usable
# hash command, a failing one, malformed output, or an unusable pwd -P)
# every path helper returns 1 with no output, and autosave / autoload /
# clear write, read and delete nothing. There is deliberately no shared
# fallback name: "<dir>/-<agent>.env" would mix settings across projects.
#
# Public functions:
#   _preset_autosave_path  — compute (but do not create) the file path
#   _preset_legacy_path    — compute the pre-per-agent shared file path
#   _preset_autosave       — write every catalog key verbatim
#   _preset_autoload       — apply saved settings (no-op silently if no file)
#   _preset_clear          — rm -f the files + unset AUTOLOADED_FROM

# Print the preset directory + "/<hash>" prefix for the resolved CWD.
# Uses resolved CWD as the identity so symlinked worktrees resolve to the
# same file as their physical path. Does NOT create any directories.
# Prints nothing and returns 1 (with an ERROR on stderr) when the
# identity cannot be computed; see "Fail closed" above.
_preset_path_prefix() {
    local workdir tool out dir
    local digest_re='^([0-9a-f]{64})[[:space:]]+[*]?-$'
    if ! workdir="$(pwd -P)" || [[ "${workdir}" != /* ]]; then
        echo "ERROR: cannot resolve the physical working directory; per-workdir settings preset disabled." >&2
        return 1
    fi
    # Same SHA-256 from either tool: GNU coreutils sha256sum (Linux) or
    # perl shasum (macOS). Both print "<64 hex>  -" for stdin. Resolved via
    # PATH only (type -P) so a shell function cannot stand in for it.
    if tool="$(type -P sha256sum)"; then
        out="$(printf '%s' "${workdir}" | "${tool}")" || out=""
    elif tool="$(type -P shasum)"; then
        out="$(printf '%s' "${workdir}" | "${tool}" -a 256)" || out=""
    else
        echo "ERROR: neither sha256sum nor shasum is on PATH; per-workdir settings preset disabled (install coreutils or perl shasum)." >&2
        return 1
    fi
    # Validate the whole digest line, not just a 12-char prefix, so a
    # failing, truncated or garbled tool can never name a preset file.
    if [[ ! "${out}" =~ ${digest_re} ]]; then
        echo "ERROR: ${tool} did not produce a SHA-256 digest of the working directory; per-workdir settings preset disabled." >&2
        return 1
    fi
    dir="${XDG_CONFIG_HOME:-${HOME}/.config}/ai-wrapper/last-preset"
    printf '%s/%s' "${dir}" "${BASH_REMATCH[1]:0:12}"
}

# Compute the path to this agent's per-workdir preset file. Fails loudly
# (stderr, return 1, no output) when AI_WRAPPER_AGENT_ID is unset or not
# a plain lowercase identifier: silently falling back to a shared name
# would reintroduce cross-agent clobbering, and the strict pattern keeps
# the id from injecting path separators into the filename.
_preset_autosave_path() {
    local agent="${AI_WRAPPER_AGENT_ID:-}"
    if [[ ! "${agent}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "ERROR: AI_WRAPPER_AGENT_ID is unset or invalid ('${agent}'); per-workdir settings preset disabled." >&2
        return 1
    fi
    local prefix
    prefix="$(_preset_path_prefix)" || return 1
    printf '%s-%s.env' "${prefix}" "${agent}"
}

# Path of the legacy shared <hash>.env written before per-agent files.
# Read-only fallback for _preset_autoload; removed by _preset_clear.
_preset_legacy_path() {
    local prefix
    prefix="$(_preset_path_prefix)" || return 1
    printf '%s.env' "${prefix}"
}

# Record that this session's preset path could not be computed, so the
# header says saved settings are disabled instead of staying silent.
_preset_mark_unavailable() {
    _AI_WRAPPER_PRESET_UNAVAILABLE=1
    unset AI_WRAPPER_PRESET_AUTOLOADED_FROM
}

# Write every catalog key to this agent's per-workdir preset file. Saves
# ALL keys verbatim (including bool=0 and empty str/path) so a user who
# explicitly disabled a previously-enabled setting sees that persist.
# Uses temp-rename to avoid partial-write corruption.
_preset_autosave() {
    local path dir entry cur
    path="$(_preset_autosave_path)" || { _preset_mark_unavailable; return 1; }
    dir="$(dirname "${path}")"

    if ! mkdir -p "${dir}" 2>/dev/null; then
        echo "WARN: _preset_autosave: could not create ${dir}" >/dev/tty
        return 1
    fi

    local tmp="${path}.tmp.$$"
    {
        printf '# ai-wrapper auto-preset\n'
        printf '# workdir: %s\n' "$(pwd -P)"
        printf '# agent: %s\n' "${AI_WRAPPER_AGENT_ID}"
        printf '# saved: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf '# wrapper-version: %s\n' "${_AI_WRAPPER_PRESET_FORMAT_VERSION}"
        for entry in "${_AI_SETTINGS_LIST[@]}"; do
            _parse_setting_entry "${entry}"
            cur="$(_setting_current_value "${_set_name}" "${_set_type}" "${_set_default}")"
            printf '%s=%s\n' "${_set_name}" "${cur}"
        done
    } > "${tmp}" 2>/dev/null || {
        rm -f "${tmp}" 2>/dev/null
        echo "WARN: _preset_autosave: failed to write ${tmp}" >/dev/tty
        return 1
    }

    if ! mv -f "${tmp}" "${path}" 2>/dev/null; then
        rm -f "${tmp}" 2>/dev/null
        echo "WARN: _preset_autosave: failed to rename ${tmp} -> ${path}" >/dev/tty
        return 1
    fi
    chmod 0644 "${path}" 2>/dev/null || true
    return 0
}

# Apply this agent's per-workdir preset to the current shell. Falls back
# to the legacy shared <hash>.env when the per-agent file doesn't exist
# yet (see migration note above). Silent no-op when neither exists (first
# run). WARN + skip on unknown keys or invalid values — never aborts on
# data errors. Unknown keys in the legacy file are skipped silently: it
# legitimately holds other agents' keys (e.g. CODEX_ACCOUNT when loading
# from the Claude wrapper). Retired keys (_AI_RETIRED_SETTINGS) are
# skipped with at most a one-line NOTE. Sets AI_WRAPPER_PRESET_AUTOLOADED_FROM=<path>
# when >=1 setting was applied so show_header can render the dim
# "restored from" banner line.
#
# The launch environment wins: a key already set in the caller's
# environment (even to an empty string) is left untouched, so a one-off
# `AI_SANDBOX_PASS_AWS=0 claude_wrapper` cannot be undone by a saved
# relaxed value. Must run once, before the menu, so only launch-time
# values count as caller-set. Restoring a non-default red or yellow
# setting WARNs on stderr so scripted launches see what was relaxed.
_preset_autoload() {
    local path entry line key val catalog_type applied=0 legacy=0
    path="$(_preset_autosave_path)" || { _preset_mark_unavailable; return 1; }
    if [[ ! -f "${path}" ]]; then
        path="$(_preset_legacy_path)" || { _preset_mark_unavailable; return 1; }
        # First run: no file yet — silent no-op.
        [[ -f "${path}" ]] || return 0
        legacy=1
    fi
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip blank lines and comments.
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        # Must contain '='.
        if [[ "${line}" != *=* ]]; then
            echo "  WARN: _preset_autoload: skipping malformed line: ${line}" >/dev/tty
            continue
        fi
        key="${line%%=*}"
        val="${line#*=}"
        # Validate key format.
        if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "  WARN: _preset_autoload: invalid key name: ${key}" >/dev/tty
            continue
        fi
        if _setting_is_retired "${key}"; then
            # stderr, not /dev/tty: scripted launches must see it too.
            # A saved 0 (or empty) was the old default and changes nothing.
            if [[ -n "${val}" && "${val}" != "0" ]]; then
                echo "  NOTE: [${AI_AGENT_COMMAND:-ai-wrapper}] Ignoring retired setting ${key}=${val} in the saved preset ${path}: git now works in plain repositories, linked worktrees and submodule checkouts, with the git dir (config and hooks included) writable by the agent." >&2
            fi
            continue
        fi
        # Reject keys not in the catalog — a corrupt file must not set
        # arbitrary env vars.
        catalog_type=""
        for entry in "${_AI_SETTINGS_LIST[@]}"; do
            _parse_setting_entry "${entry}"
            if [[ "${_set_name}" == "${key}" ]]; then
                catalog_type="${_set_type}"
                break
            fi
        done
        # _set_* now describe the matched entry (when catalog_type is set).
        if [[ -z "${catalog_type}" ]]; then
            (( legacy )) && continue
            echo "  WARN: _preset_autoload: unknown setting: ${key}" >/dev/tty
            continue
        fi
        # Validate value against type.
        case "${catalog_type}" in
            bool)
                if [[ "${val}" != "0" && "${val}" != "1" ]]; then
                    echo "  WARN: _preset_autoload: ${key}: expected 0 or 1, got '${val}'" >/dev/tty
                    continue
                fi
                ;;
            str|path)
                # No further validation — accept-any-string contract.
                ;;
        esac
        # Caller environment precedence (set, even if empty).
        [[ -n "${!key+x}" ]] && continue
        _preset_warn_restored "${key}" "${val}"
        export "${key}=${val}"
        applied=$((applied + 1))
    done < "${path}"
    # Only signal "settings were restored" when at least one setting
    # applied. If the file exists but all lines were unknown/bad, the
    # banner would mislead the user into thinking settings are active.
    if (( applied > 0 )); then
        export AI_WRAPPER_PRESET_AUTOLOADED_FROM="${path}"
    fi
    return 0
}

# WARN on stderr (not /dev/tty: scripted launches must see it too) when
# _preset_autoload restores KEY=VAL for a red or yellow setting at a
# non-default value. Reads the _set_* globals of KEY's catalog entry.
_preset_warn_restored() {
    local key="${1}" val="${2}" tag="[${AI_AGENT_COMMAND:-ai-wrapper}]"
    case "${_set_severity}" in
        red|yellow) ;;
        *) return 0 ;;
    esac
    [[ -z "${val}" || "${val}" == "${_set_default}" ]] && return 0
    if [[ "${key}" == "AI_SANDBOX_ALLOW_SETTINGS" ]]; then
        echo "  WARN: ${tag} Restored AI_SANDBOX_ALLOW_SETTINGS=1 from the saved preset: client settings, skills and plugins will be writable by the agent (set AI_SANDBOX_ALLOW_SETTINGS=0 at launch or toggle it in s) Settings to protect them)." >&2
        return 0
    fi
    echo "  WARN: ${tag} Restored ${key}=${val} from the saved preset (${_set_severity}: ${_set_headline}); set ${key} at launch or change it in s) Settings to override." >&2
}

# Remove this agent's per-workdir preset file and clear the
# AUTOLOADED_FROM marker. Also removes the legacy shared <hash>.env: left
# in place it would be picked up again by _preset_autoload's fallback and
# silently resurrect the settings the user just cleared. Other agents'
# per-agent files are untouched (an agent that hasn't migrated yet starts
# from defaults). No-op (return 0) when the files do not exist. Both
# paths are computed before either is removed.
_preset_clear() {
    local path legacy
    path="$(_preset_autosave_path)" || { _preset_mark_unavailable; return 1; }
    legacy="$(_preset_legacy_path)" || { _preset_mark_unavailable; return 1; }
    rm -f "${path}" "${legacy}" 2>/dev/null || true
    unset AI_WRAPPER_PRESET_AUTOLOADED_FROM
    return 0
}

# Render the dim "restored from <path>" banner line. Called by
# show_header iff AI_WRAPPER_PRESET_AUTOLOADED_FROM is set. Extracted
# into its own function so integration tests can call it directly
# without invoking the full show_header (which clears the screen, etc.).
_render_preset_banner_line() {
    local reset='\033[0m' dim='\033[2m' yellow='\033[1;33m'
    if [[ -n "${_AI_WRAPPER_PRESET_UNAVAILABLE:-}" ]]; then
        printf '%bSaved settings disabled: the per-workdir preset path could not be computed (needs sha256sum or shasum on PATH and a resolvable workdir). Nothing is restored, saved or cleared.%b\n' "${yellow}" "${reset}" >/dev/tty
        return 0
    fi
    [[ -n "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}" ]] || return 0
    printf '%b(restored from %s)%b\n' "${dim}" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM}" "${reset}" >/dev/tty
}

# ===== UTILITY FUNCTIONS =====

wrapper_log() {
    local level="${1}"
    shift
    printf '[%s] %s: %s\n' "${AI_WRAPPER_AGENT_NAME:-ai-wrapper}" "${level}" "$*" >&2
}

# Source AI_WRAPPER_EXTRA_PROFILE when set. Silent no-op when unset or empty.
# Emits WARN on stderr when the path is set but the file does not exist.
# Extracted here (rather than inlined in each wrapper) so tests can exercise
# the live guard logic directly via source_lib + _load_extra_profile.
_load_extra_profile() {
    [[ -n "${AI_WRAPPER_EXTRA_PROFILE:-}" ]] || return 0
    if [[ -f "${AI_WRAPPER_EXTRA_PROFILE}" ]]; then
        # shellcheck source=/dev/null
        source "${AI_WRAPPER_EXTRA_PROFILE}"
    else
        echo "WARN: AI_WRAPPER_EXTRA_PROFILE=${AI_WRAPPER_EXTRA_PROFILE} not found; ignoring." >&2
        return 0
    fi
    # Fire the settings-catalog registration callback now that the plugin
    # has had a chance to define it. _AI_SETTINGS_LIST is already populated
    # and OS-filtered at this point (see the source-time block earlier in
    # this file), so plugin appends survive filtering unchanged.
    if declare -f _extra_settings_register >/dev/null 2>&1; then
        _extra_settings_register
    fi
}

# ===== BINARY CHECK =====

# Check that the agent binary exists. Exits with 127 if not found.
# Call from the parent shell (not a subshell) so exit propagates correctly.
check_agent_binary() {
    if ! command -v "${AI_AGENT_COMMAND}" &>/dev/null; then
        echo "ERROR: '${AI_AGENT_COMMAND}' not found in PATH." >&2
        echo "Please install ${AI_WRAPPER_AGENT_NAME} before using this wrapper." >&2
        exit 127
    fi
}

# ===== MENU DISPLAY =====
# All menu output goes to /dev/tty to avoid capture by $() subshells.

show_header() {
    clear >/dev/tty
    echo "==========================================" >/dev/tty
    printf "    %-38s\n" "${AI_WRAPPER_AGENT_NAME} - Session Options" >/dev/tty
    echo "==========================================" >/dev/tty
    # Unified settings table replaces the per-var banner stanzas: the
    # catalog drives both this view and the interactive sub-menu, so the
    # two never drift. Severity colouring (yellow/red) is applied per-row
    # only when the setting is non-default. "compact" mode hides default-
    # state rows so the header stays short as the catalog grows; the full
    # table is available inside the s) Settings sub-menu.
    _render_settings_table compact
    # Plugin header hook: extensions loaded via AI_WRAPPER_EXTRA_PROFILE can
    # render extra status lines under the settings table (e.g. background-
    # service indicators). Runs when defined; no-op otherwise.
    if declare -f _extra_header_extras >/dev/null 2>&1; then
        _extra_header_extras
    fi
    # Dim "restored from <path>" line when auto-preset was applied.
    # Rendered before the workdir warning so the warning always sits
    # immediately above the menu options.
    _render_preset_banner_line
    # WS3 / U-E: yellow warn when WORKDIR is a direct $HOME child not on
    # the project-dir allowlist. The universal wrapper exports
    # AI_SANDBOX_WORKDIR_WARNING with the resolved WORKDIR path when the
    # heuristic fires. This banner is dynamic (carries the resolved path)
    # so it stays outside the catalog table.
    if [[ -n "${AI_SANDBOX_WORKDIR_WARNING:-}" ]]; then
        printf '\033[1;33mWARNING: WORKDIR=%s grants RW on every file under it. cd one level deeper if that is broader than you intend.\033[0m\n' "${AI_SANDBOX_WORKDIR_WARNING}" >/dev/tty
        echo "" >/dev/tty
    fi
}

# Streams a markdown help file to stdout, dropping blocks wrapped in
#   <!-- os:darwin --> ... <!-- os:end -->
#   <!-- os:linux -->  ... <!-- os:end -->
# whose OS doesn't match _wrapper_os. Lines outside any such block pass
# through unchanged; the marker lines themselves are always stripped. Lets
# one help file stay the single source for both platforms instead of
# duplicating the shared sections, same motivation as the settings
# catalog's OS_SCOPE field above.
_render_os_conditional_doc() {
    local os_want
    case "${_wrapper_os}" in
        Darwin) os_want="darwin" ;;
        Linux)  os_want="linux" ;;
        *)      os_want="" ;;
    esac
    awk -v os="${os_want}" '
        BEGIN                        { show=1 }
        /^<!-- os:end -->$/          { show=1; next }
        /^<!-- os:[^ ]+ -->$/        { show=($0 == "<!-- os:" os " -->"); next }
        show                         { print }
    ' "${1}"
}

display_help() {
    show_header
    if [[ -f "${WRAPPER_HELP}" ]]; then
        if command -v less &>/dev/null; then
            # -F: quit if content fits one screen; -X: don't clear the screen on exit.
            # Process substitution (not a pipe) so less still gets a file-like
            # input while its own stdin stays free for </dev/tty keypresses.
            less -FX <(_render_os_conditional_doc "${WRAPPER_HELP}") </dev/tty >/dev/tty
        else
            _render_os_conditional_doc "${WRAPPER_HELP}" >/dev/tty
        fi
    else
        echo "Wrapper for ${AI_WRAPPER_AGENT_NAME}" >/dev/tty
        echo "" >/dev/tty
        echo "Options:" >/dev/tty
        echo "  Orchestration - Multi-phase dev workflow (orchestrator-mode skill)" >/dev/tty
        echo "  Start new     - Plain ${AI_WRAPPER_AGENT_NAME} session" >/dev/tty
        echo "  Resume        - Resume a previous session" >/dev/tty
        echo "" >/dev/tty
        echo "Press Enter to return to menu..." >/dev/tty
        read -r </dev/tty
    fi
}

# Show the main menu and set $WRAPPER_MENU_CHOICE to the chosen action.
# Sets one of: orchestrate, start, resume.
#
# IMPORTANT: this function intentionally does NOT echo to stdout. Callers must
# invoke it directly (not via `$(show_main_menu)`) and read $WRAPPER_MENU_CHOICE
# afterwards. The reason: `$()` runs the whole menu loop in a subshell, which
# means any `export` made by toggle_settings_menu inside that loop dies when
# the subshell exits — settings toggled via the s) sub-menu would never reach
# run_sandboxed_agent. Returning the choice via a global var keeps the menu
# in the parent shell so exports propagate.
show_main_menu() {
    WRAPPER_MENU_CHOICE=""
    while true; do
        show_header

        echo "Options:" >/dev/tty
        echo "  1) Start orchestration  (orchestrator-mode skill)" >/dev/tty
        echo "  2) Start new conversation" >/dev/tty
        echo "  3) Resume from list" >/dev/tty
        echo "  s) Settings (toggle sandbox flags)" >/dev/tty
        echo "  c) Clear saved settings for this workdir" >/dev/tty
        echo "  h) Help" >/dev/tty
        # Plugin menu hook: extensions loaded via AI_WRAPPER_EXTRA_PROFILE can
        # append extra numbered / lettered options here. Pair with
        # _extra_menu_dispatch below to handle the letters the callback prints.
        if declare -f _extra_menu_options >/dev/null 2>&1; then
            _extra_menu_options
        fi
        echo "" >/dev/tty
        echo -n "Choose an option [1-3, s, c, h]: " >/dev/tty
        # `read` returns non-zero on EOF (e.g. /dev/tty unexpectedly closed,
        # or in a test harness where stdin is exhausted). Without this guard
        # the case-default branch would re-loop, re-render the menu, re-read
        # EOF, and spin forever. Treat any read failure as "abort the menu".
        if ! read -r choice </dev/tty; then
            WRAPPER_MENU_CHOICE=""
            return 1
        fi

        case "${choice}" in
            1) WRAPPER_MENU_CHOICE="orchestrate"; return 0 ;;
            2) WRAPPER_MENU_CHOICE="start"; return 0 ;;
            3) WRAPPER_MENU_CHOICE="resume"; return 0 ;;
            s|S|settings) toggle_settings_menu ;;
            c|C|clear)
                # Clear the auto-saved preset for this workdir and
                # re-render the menu so the "restored from" banner
                # disappears immediately. No confirmation — the user
                # can re-save by simply returning to the menu (autosave
                # fires before dispatch) or by editing Settings.
                _preset_clear
                ;;
            h|H|help) display_help ;;
            *)
                # Plugin dispatch first: an _extra_menu_dispatch defined by
                # AI_WRAPPER_EXTRA_PROFILE gets first shot at unknown choices
                # printed by _extra_menu_options. Returning 0 = handled
                # (re-render menu). Any non-zero return, or the callback being
                # undefined, falls through to the invalid-choice re-render.
                if declare -f _extra_menu_dispatch >/dev/null 2>&1 \
                        && _extra_menu_dispatch "${choice}"; then
                    continue
                fi
                echo "Invalid choice. Press Enter to continue..." >/dev/tty
                read -r </dev/tty || return 1
                ;;
        esac
    done
}

# Full help of catalog entries for the s) Settings "?N" choice: number,
# headline, variable name, type, default and current value, then the
# soft-wrapped detail (what it does, when to use it, what Off means).
# Arg: comma-separated 1-based numbers. An invalid number prints the same
# "Invalid choice" message as a bad toggle. Waits for Enter; returns 1 on
# EOF (the caller treats that as "back"). Output goes to /dev/tty.
_show_setting_help() {
    local spec="${1}" tok cur wrapped dline
    local -a picks=() toks=()
    IFS=',' read -r -a toks <<<"${spec}"
    for tok in "${toks[@]+"${toks[@]}"}"; do
        tok="${tok#"${tok%%[![:space:]]*}"}"
        tok="${tok%"${tok##*[![:space:]]}"}"
        [[ -z "${tok}" ]] && continue
        if ! [[ "${tok}" =~ ^[0-9]+$ ]] || (( tok < 1 || tok > ${#_AI_SETTINGS_LIST[@]} )); then
            echo "Invalid choice: '?${tok}'. Press Enter to continue..." >/dev/tty
            read -r </dev/tty || return 1
            return 0
        fi
        picks+=("${tok}")
    done
    (( ${#picks[@]} > 0 )) || return 0
    show_header
    for tok in "${picks[@]}"; do
        _parse_setting_entry "${_AI_SETTINGS_LIST[$((tok - 1))]}"
        cur="$(_setting_current_value "${_set_name}" "${_set_type}" "${_set_default}")"
        printf '%b%2d) %s%b\n' "$(_category_color "${_set_category}")" "${tok}" "${_set_headline}" '\033[0m' >/dev/tty
        printf '    %s (%s, default %s, now %s; %s)\n' "${_set_name}" "${_set_type}" "${_set_default:-<unset>}" \
            "${cur:-<unset>}" "$(_category_label "${_set_category}")" >/dev/tty
        wrapped="$(printf '%s\n' "${_set_detail}" | fold -s -w 74)"
        while IFS= read -r dline; do
            printf '    %s\n' "${dline}" >/dev/tty
        done <<<"${wrapped}"
        echo "" >/dev/tty
    done
    echo "Press Enter to return to the settings list..." >/dev/tty
    read -r </dev/tty || return 1
    return 0
}

# Interactive settings editor. Loops until the user picks "back".
# Toggles bools, prompts for str/path values; empty input on str/path
# unsets the var. All mutations use `export` so they reach
# run_sandboxed_agent later in the same shell.
toggle_settings_menu() {
    while true; do
        show_header

        echo "Settings - toggle/edit:" >/dev/tty
        local i=1 entry cur checkbox display wrapped first dline reset
        local last_category=""
        reset='\033[0m'
        for entry in "${_AI_SETTINGS_LIST[@]}"; do
            _parse_setting_entry "${entry}"
            if [[ "${_set_category}" != "${last_category}" ]]; then
                echo "" >/dev/tty
                printf '%b%s%b\n' "$(_category_color "${_set_category}")" "$(_category_label "${_set_category}")" "${reset}" >/dev/tty
                last_category="${_set_category}"
            fi
            cur="$(_setting_current_value "${_set_name}" "${_set_type}" "${_set_default}")"
            # Row colour mirrors the banner: green when disabled, red
            # when enabled. The active/inactive split is the visual
            # encoding — categories use one shared hue (above) so they
            # read as section labels, not state.
            local row_color row_line
            row_color="$(_setting_state_color "${cur}")"
            case "${_set_type}" in
                bool)
                    if [[ "${cur}" == "1" ]]; then checkbox="[x]"; else checkbox="[ ]"; fi
                    row_line="$(printf '%2d) %s %s' "${i}" "${checkbox}" "${_set_headline}")"
                    ;;
                *)
                    display="${cur:-<unset>}"
                    row_line="$(printf '%2d) %s = %s' "${i}" "${_set_headline}" "${display}")"
                    ;;
            esac
            printf '%b%s%b\n' "${row_color}" "${row_line}" "${reset}" >/dev/tty
            # Row 2: soft-wrapped detail, arrow on first line, aligned
            # continuations on subsequent lines (matches banner table).
            # Detail text stays uncoloured.
            wrapped="$(printf '%s\n' "${_set_detail}" | fold -s -w 74)"
            first=1
            while IFS= read -r dline; do
                if (( first == 1 )); then
                    printf '        ↳ %s\n' "${dline}" >/dev/tty
                    first=0
                else
                    printf '          %s\n' "${dline}" >/dev/tty
                fi
            done <<<"${wrapped}"
            i=$((i + 1))
        done

        printf '\nChoose setting [1-%d, comma-separated for multi, ?N=help and use cases for N, b=back]: ' "${#_AI_SETTINGS_LIST[@]}" >/dev/tty
        local choice
        # Treat EOF on /dev/tty as "back" (matches the empty-input branch
        # below). Without this, a closed-tty / exhausted-stdin condition
        # would re-loop forever — same hazard as in show_main_menu.
        if ! read -r choice </dev/tty; then
            return 0
        fi
        case "${choice}" in
            ""|b|B|back) return 0 ;;
            \?*)
                # ?N (or ?N,M): the full help of those entries on a fresh
                # screen. The list above is taller than most terminals, so
                # an entry's help may have scrolled out of view.
                _show_setting_help "${choice#\?}" || return 0
                ;;
            *)
                # Tokenise on comma so "1,4,7" toggles three settings in
                # one pass. Whitespace around tokens is ignored; each
                # token must be a positive integer within range. A single
                # bad token aborts the whole batch — silently skipping
                # would mask typos in larger selections.
                local -a _picks_raw=() picks=()
                local tok ok=1
                IFS=',' read -r -a _picks_raw <<<"${choice}"
                for tok in "${_picks_raw[@]}"; do
                    tok="${tok#"${tok%%[![:space:]]*}"}"
                    tok="${tok%"${tok##*[![:space:]]}"}"
                    [[ -z "${tok}" ]] && continue
                    if ! [[ "${tok}" =~ ^[0-9]+$ ]] \
                       || (( tok < 1 || tok > ${#_AI_SETTINGS_LIST[@]} )); then
                        echo "Invalid choice: '${tok}'. Press Enter to continue..." >/dev/tty
                        read -r </dev/tty || return 0
                        ok=0
                        break
                    fi
                    picks+=("${tok}")
                done
                if (( ok == 0 )) || (( ${#picks[@]} == 0 )); then
                    continue
                fi
                for tok in "${picks[@]}"; do
                    _parse_setting_entry "${_AI_SETTINGS_LIST[$((tok - 1))]}"
                    cur="$(_setting_current_value "${_set_name}" "${_set_type}" "${_set_default}")"
                    case "${_set_type}" in
                        bool)
                            if [[ "${cur}" == "1" ]]; then
                                export "${_set_name}"="0"
                            else
                                export "${_set_name}"="1"
                            fi
                            ;;
                        str|path)
                            printf 'New value for %s (empty to unset): ' "${_set_name}" >/dev/tty
                            local newval
                            # EOF here is treated the same as an empty input
                            # (unset the var). Matches the "empty to unset"
                            # contract printed to the user.
                            read -r newval </dev/tty || newval=""
                            if [[ -z "${newval}" ]]; then
                                unset "${_set_name}"
                            else
                                export "${_set_name}"="${newval}"
                            fi
                            ;;
                    esac
                done
                ;;
        esac
    done
}


# ===== ORCHESTRATION =====

build_orchestrator_prompt() {
    if [[ ! -f "${ORCHESTRATOR_PROMPT}" ]]; then
        wrapper_log "ERROR" "Orchestrator prompt not found: ${ORCHESTRATOR_PROMPT}"
        return 1
    fi
    cat "${ORCHESTRATOR_PROMPT}"
}

# Run an orchestrated session. Uses WRAPPER_FLAGS and AGENT_FLAGS from the calling wrapper.
# AI_SYSTEM_PROMPT_FLAG must be set to the agent's system prompt injection flag.
run_orchestrated_session() {
    local prompt_content
    prompt_content=$(build_orchestrator_prompt) || { wrapper_log "ERROR" "Failed to build orchestrator prompt."; return 1; }
    if [[ -z "${prompt_content}" ]]; then
        wrapper_log "ERROR" "Prompt is empty."
        return 1
    fi

    # Agents whose system-prompt injection isn't a plain `FLAG VALUE` pair
    # (e.g. Codex: `-c developer_instructions=<TOML string>`) define
    # _agent_system_prompt_args in their lib; everyone else uses
    # AI_SYSTEM_PROMPT_FLAG.
    AI_SYSTEM_PROMPT_ARGS=()
    if declare -f _agent_system_prompt_args >/dev/null 2>&1; then
        if ! _agent_system_prompt_args "${prompt_content}"; then
            wrapper_log "ERROR" "Failed to build system prompt args for ${AI_WRAPPER_AGENT_NAME}."
            return 1
        fi
    elif [[ -n "${AI_SYSTEM_PROMPT_FLAG:-}" ]]; then
        AI_SYSTEM_PROMPT_ARGS=("${AI_SYSTEM_PROMPT_FLAG}" "${prompt_content}")
    fi

    if [[ ${#AI_SYSTEM_PROMPT_ARGS[@]} -eq 0 ]]; then
        # The user explicitly chose orchestrate; silently falling back
        # to a plain session would run the wrong workflow.
        wrapper_log "ERROR" "AI_SYSTEM_PROMPT_FLAG is not set for ${AI_WRAPPER_AGENT_NAME}; cannot inject orchestrator prompt."
        wrapper_log "ERROR" "Set AI_SYSTEM_PROMPT_FLAG (or define _agent_system_prompt_args) in the agent's wrapper lib, or pick 'Start new conversation'."
        return 1
    fi

    run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}" -- \
        "${AGENT_FLAGS[@]+"${AGENT_FLAGS[@]}"}" "${AI_SYSTEM_PROMPT_ARGS[@]}"
}

# Run a plain agent session (start or resume). Uses AI_RESUME_ARGS if set.
run_agent_session() {
    local action="${1:-start}"
    # `${arr[@]:-default}` returns `default` when arr is unset or empty,
    # otherwise expands to arr. Safe under `set -u`, unlike `${#arr[@]}`
    # on an unset array (bash 3.2 errors there).
    local -a resume_args=("${AI_RESUME_ARGS[@]:---resume}")

    case "${action}" in
        resume)
            # Agents whose session resume requires dynamic resolution or a
            # pre-launch conversation picker (e.g. agy: `--conversation=<id>`
            # selected from conversation_summaries.db) define
            # _agent_resume_args in their lib to populate AI_RESUME_ARGS.
            if declare -f _agent_resume_args >/dev/null 2>&1; then
                if ! _agent_resume_args; then
                    return 1
                fi
                resume_args=("${AI_RESUME_ARGS[@]:---resume}")
            fi
            if [[ "${AI_RESUME_ARGS_FIRST:-0}" == "1" ]]; then
                # Resume is a subcommand (e.g. `codex resume`): it must
                # precede the agent flags so they parse as its options.
                run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}" -- "${resume_args[@]}" "${AGENT_FLAGS[@]+"${AGENT_FLAGS[@]}"}"
            else
                run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}" -- "${AGENT_FLAGS[@]+"${AGENT_FLAGS[@]}"}" "${resume_args[@]}"
            fi
            ;;
        start)
            run_sandboxed_agent "${AI_AGENT_COMMAND}" -- "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}" -- "${AGENT_FLAGS[@]+"${AGENT_FLAGS[@]}"}"
            ;;
        *)
            wrapper_log "ERROR" "Unknown action: ${action} (expected 'start' or 'resume')"
            return 2
            ;;
    esac
}

# ===== SCRIPT GUARD =====

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: This script is meant to be sourced, not executed directly." >&2
    exit 1
fi
