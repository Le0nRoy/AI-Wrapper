#!/bin/bash
# Universal sandbox wrapper for AI agents. Dispatches to the OS-appropriate
# backend: bubblewrap on Linux, sandbox-exec (Seatbelt) on macOS.
#
# Rlimit enforcement (RLIMIT_AS/CPU/NOFILE/NPROC via prlimit) was removed
# 2026-09 — the maintainer isn't using it and wants it deferred to a
# separate tracked issue rather than carried as dead weight here. See
# docs/plans/2026-09-04-macos-sandbox-and-wrapper-unification-context.md
# "Deferred: rlimits" for the reasoning and what re-adding it would need.
#
# Usage:
#   run_sandboxed_agent COMMAND -- [BIND_FLAGS...] -- [CMD_ARGS...]
#
# BIND_FLAGS on Linux are bwrap-shaped: --bind SRC DST / --ro-bind SRC DST.
# BIND_FLAGS on macOS are single-arg (see macos_sandbox_exec.bash header):
# --bind SRC / --ro-bind SRC / --meta-bind SRC / --pin SRC.
# Callers that need to run on both OSes must branch on `uname -s` themselves
# when building BIND_FLAGS, same as executable_claude_wrapper.bash does.

function echo_log() {
    local log_level="${1}"
    shift
    echo -e "[$(date "+%F %T")] ${log_level}: $*" >&2
}

# Append NAME to the comma-separated AI_SANDBOX_PASS_ENV allowlist unless it
# is already listed (whitespace around entries is ignored). Exports the
# updated list. Used by wrappers that must pass their own env vars through
# the sandbox's scrubbed environment.
_sandbox_pass_env_add() {
    local name="${1}" entry pass_env="${AI_SANDBOX_PASS_ENV:-}"
    local -a pass_env_vars=()
    IFS=',' read -r -a pass_env_vars <<<"${pass_env}"
    for entry in "${pass_env_vars[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ "${entry}" == "${name}" ]] && return 0
    done
    [[ -n "${pass_env}" ]] && pass_env+=","
    pass_env+="${name}"
    export AI_SANDBOX_PASS_ENV="${pass_env}"
}

# Resolve a path canonically. The single definition for both backends and
# the wrapper libs (ai_wrapper_lib.bash, macos_sandbox_exec.bash), which
# are always sourced after this file. macOS lacks GNU `readlink -f`; use
# perl as the fallback that ships in the base system. Returns non-zero (and prints nothing)
# if no resolver is available or the resolution fails — callers must check.
# We deliberately don't synthesize an unresolved fallback: symlink-mismatched
# paths silently break sandbox rules, which is worse than failing loudly.
_realpath() {
    local p="${1}" out
    if command -v realpath >/dev/null 2>&1; then
        if out="$(realpath "${p}" 2>/dev/null)" && [[ -n "${out}" ]]; then
            [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: branch=realpath path=${p}"
            echo "${out}"
            return 0
        fi
    fi
    if command -v perl >/dev/null 2>&1; then
        if out="$(perl -MCwd=abs_path -e 'my $r = abs_path($ARGV[0]); print $r if defined $r' "${p}" 2>/dev/null)" && [[ -n "${out}" ]]; then
            [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: branch=perl-abs_path path=${p}"
            echo "${out}"
            return 0
        fi
    fi
    # Last-ditch: canonicalize via `cd … && pwd -P`. Works for directories
    # directly; for files, follow any final-component symlinks via readlink
    # (capped to a small depth to prevent loops) before resolving the parent
    # and re-attaching the basename so symlinks in the directory chain are
    # also resolved.
    local parent base resolved_parent
    if [[ -d "${p}" ]]; then
        if out="$( cd "${p}" 2>/dev/null && pwd -P )" && [[ -n "${out}" ]]; then
            [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: branch=cd-pwd-dir path=${p}"
            echo "${out}"
            return 0
        fi
    elif [[ -e "${p}" || -L "${p}" ]]; then
        local cur="${p}" target depth=0
        # Cycle detection: the depth cap protects against unbounded
        # recursion, but a tight loop (a → b → a) would otherwise spin up
        # to 40 iterations and then silently return a non-canonical
        # intermediate path. Track visited paths and bail the moment we
        # revisit one. Bash 3.2-compatible: linear scan of a small array
        # (cap is the depth limit, so ~40 entries max).
        local -a seen=()
        local _s_i
        while [[ -L "${cur}" && ${depth} -lt 40 ]]; do
            seen+=("${cur}")
            target="$(readlink "${cur}" 2>/dev/null)" || break
            [[ -z "${target}" ]] && break
            if [[ "${target}" == /* ]]; then
                cur="${target}"
            else
                cur="$(dirname -- "${cur}")/${target}"
            fi
            depth=$((depth + 1))
            for (( _s_i = 0; _s_i < ${#seen[@]}; _s_i++ )); do
                if [[ "${seen[$_s_i]}" == "${cur}" ]]; then
                    [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: symlink cycle detected path=${p} depth=${depth}"
                    return 1
                fi
            done
        done
        # After following the chain, the target might itself be a directory.
        if [[ -d "${cur}" ]]; then
            if out="$( cd "${cur}" 2>/dev/null && pwd -P )" && [[ -n "${out}" ]]; then
                [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: branch=cd-pwd-symlink-walk-dir path=${p} depth=${depth}"
                echo "${out}"
                return 0
            fi
        fi
        parent="$(dirname -- "${cur}")"
        base="$(basename -- "${cur}")"
        if resolved_parent="$( cd "${parent}" 2>/dev/null && pwd -P )" && [[ -n "${resolved_parent}" ]]; then
            [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "_realpath: branch=cd-pwd-symlink-walk-file path=${p} depth=${depth}"
            echo "${resolved_parent%/}/${base}"
            return 0
        fi
    fi
    return 1
}

# Classify a directory path against the sandbox's sensitive-location
# rules. Prints one of:
#   system  - "" / a filesystem root or top-level system location
#   home    - exactly $HOME
#   dotfile - under a dotfile dir directly under $HOME (on macOS also
#             ~/Library), where credentials live
# and returns 0; prints nothing and returns 1 when PATH is not sensitive.
# Pure string classification: callers pass an already-resolved PATH and
# HOME (trailing slashes are stripped here). Single source for both
# backends' WORKDIR and AI_SANDBOX_EXTRA_{RW,RO}_DIRS refusals (Linux below,
# macOS in macos_sandbox_exec.bash; each backend keeps its own override
# policy) and the wrapper-side git-worktree bind guard (ai_wrapper_lib.bash).
# System entries are exact roots, not subtrees. On macOS /tmp, /var and
# /etc are listed with their canonical /private/... targets, since callers
# pass realpath-resolved paths.
_sandbox_sensitive_dir_kind() {
    local path="${1%/}" home="${2%/}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        case "${path}" in
            ""|/|/Users|/Users/Shared|/private|/private/tmp|/private/var|/private/var/tmp|/private/var/folders|/private/etc|/tmp|/var|/var/tmp|/etc|/usr|/usr/local|/bin|/sbin|/System|/Applications|/Library)
                echo system; return 0 ;;
        esac
    else
        case "${path}" in
            ""|/|/tmp|/var|/etc|/usr|/bin|/sbin|/opt|/home|/root|/proc|/sys|/dev|/boot|/mnt|/media|/srv|/run)
                echo system; return 0 ;;
        esac
    fi
    [[ -n "${home}" ]] || return 1
    if [[ "${path}" == "${home}" ]]; then
        echo home; return 0
    fi
    case "${path}" in
        "${home}"/.*)
            echo dotfile; return 0 ;;
        "${home}"/Library|"${home}"/Library/*)
            if [[ "$(uname -s)" == "Darwin" ]]; then echo dotfile; return 0; fi ;;
    esac
    return 1
}

# Classify a path both as given (LOGICAL, against the raw HOME) and as
# resolved (RESOLVED, against the resolved HOME) and print the first
# sensitive kind found, resolved first; prints nothing and returns 1 when
# neither is sensitive. The resolved form catches a symlink or ".." that
# leads into a sensitive location; the logical form keeps refusing a path
# spelled as one (e.g. ~/.config symlinked to a data disk still holds the
# credentials ~/.config would). Args: LOGICAL RESOLVED HOME RESOLVED_HOME
_sandbox_sensitive_pair_kind() {
    _sandbox_sensitive_dir_kind "${2}" "${4}" || _sandbox_sensitive_dir_kind "${1}" "${3}"
}

# Resolve one AI_SANDBOX_EXTRA_{RW,RO}_DIRS entry (trimmed, ~ expanded) to
# the canonical directory that gets bound and classified.
#   0 - prints the resolved directory
#   2 - nothing exists at ENTRY: WARNING, the caller skips it (a preset
#       naming a path from another machine stays usable; nothing is granted)
#   1 - ENTRY exists but does not resolve to a directory (dangling symlink,
#       symlink loop, unreadable component, non-directory): ERROR, the
#       caller refuses the launch. Not covered by
#       AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR.
# Args: AGENT_TAG VAR_NAME ENTRY
_sandbox_resolve_extra_dir() {
    local tag="${1}" var="${2}" entry="${3}" resolved
    if [[ ! -e "${entry}" && ! -L "${entry}" ]]; then
        echo_log "WARNING" "[${tag}] ${var}: skipping '${entry}' (does not exist)"
        return 2
    fi
    if ! resolved="$(_realpath "${entry}")" || [[ -z "${resolved}" || ! -d "${resolved}" ]]; then
        echo_log "ERROR" "[${tag}] ${var}: '${entry}' does not resolve to a directory (dangling symlink, symlink loop, unreadable path or not a directory). Fix or remove the entry."
        return 1
    fi
    [[ "${resolved}" == "/" ]] || resolved="${resolved%/}"
    if [[ "${resolved}" != "${entry}" && "${resolved}" != "${entry%/}" ]]; then
        echo_log "INFO" "[${tag}] ${var}: '${entry}' resolves to ${resolved}; the sandbox binds it there."
    fi
    printf '%s\n' "${resolved}"
}

# Warn when an accepted AI_SANDBOX_EXTRA_RW_DIRS entry DIR is a git dir or
# a work tree with a .git dir: the raw grant gets none of the read-only
# config / hooks/ overlays the wrapper puts on git metadata it binds
# itself. Silent for the metadata that does get them (WORKDIR's own .git,
# the validated worktree common dir in _WRAPPER_GIT_COMMON_PROTECTED, set
# by _wrapper_bind_git_common_dir). A warning only — the grant stays.
# Args: AGENT_TAG DIR
_sandbox_warn_extra_rw_git() {
    local tag="${1}" dir="${2}" resolved gd="" wd IFS=$' \t\n'
    resolved="$(cd "${dir}" 2>/dev/null && pwd -P)" || return 0
    if [[ -f "${resolved}/HEAD" && -d "${resolved}/objects" && -d "${resolved}/refs" ]]; then
        gd="${resolved}"
    elif [[ -d "${resolved}/.git" ]]; then
        gd="$(cd "${resolved}/.git" 2>/dev/null && pwd -P)" || return 0
    fi
    [[ -n "${gd}" ]] || return 0
    [[ -n "${_WRAPPER_GIT_COMMON_PROTECTED:-}" && "${gd}" == "${_WRAPPER_GIT_COMMON_PROTECTED}" ]] && return 0
    wd="$(pwd -P)"
    [[ "${gd}" == "${wd%/}/.git" ]] && return 0
    echo_log "WARNING" "[${tag}] AI_SANDBOX_EXTRA_RW_DIRS: '${dir}' exposes git metadata ${gd} read-write without the read-only config / hooks/ overlays: the agent can plant hooks or config (core.hooksPath, core.fsmonitor, aliases) that run on the host the next time you use git there. For a linked worktree, launch from the worktree instead (with AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES=1 if the repository is outside \$HOME): its shared .git is then bound after link validation with config and hooks/ read-only."
}

run_sandboxed_agent() {
    case "$(uname -s)" in
        Linux)
            _run_sandboxed_agent_linux "$@"
            ;;
        Darwin)
            # shellcheck source=ai_wrapper_data/macos_sandbox_exec.bash
            source "$(dirname "${BASH_SOURCE[0]}")/ai_wrapper_data/macos_sandbox_exec.bash"
            _run_sandboxed_agent_impl "$@"
            ;;
        *)
            echo_log "ERROR" "Unsupported OS: $(uname -s). This wrapper supports Linux (bubblewrap) and macOS (sandbox-exec) only."
            return 78
            ;;
    esac
}

# Host tailscaled socket bound by AI_SANDBOX_PASS_TAILSCALE=1. Assigned at
# source time, so the caller's environment cannot redirect the bind source.
_AI_SANDBOX_TAILSCALE_SOCKET=/run/tailscale/tailscaled.sock

# Rootless container daemon sockets, relative to the user runtime dir,
# shared by AI_SANDBOX_ALLOW_DOCKER=1: rootless dockerd's default
# DOCKER_HOST and the podman.socket user unit's endpoint (the default of
# `podman --remote` / CONTAINER_HOST).
_AI_SANDBOX_ROOTLESS_DOCKER_SOCKET=docker.sock
_AI_SANDBOX_ROOTLESS_PODMAN_SOCKET=podman/podman.sock

# Mode of the sandbox's private runtime directory (XDG Base Directory spec).
_AI_SANDBOX_RUNTIME_DIR_PERMS=0700

# Linux process isolation inputs: the procfs sysctl root read by the user
# namespace knob check, and the interpreter and host helper that build the
# terminal-injection seccomp filter. Assigned at source time, so the
# caller's environment cannot redirect them.
_AI_SANDBOX_PROC_SYS=/proc/sys
_AI_SANDBOX_PYTHON=python3
_AI_SANDBOX_TTY_FILTER_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/ai_wrapper_data/linux_tty_seccomp.py"
# Options that stop the sandboxed process creating user namespaces of its
# own (AI_SANDBOX_ALLOW_NESTED_USERNS=0). --disable-userns needs an
# explicit --unshare-user: --unshare-all only tries one.
_AI_SANDBOX_NO_NESTED_USERNS_ARGS=(--unshare-user --disable-userns --assert-userns-disabled)

# Restricted network (AI_SANDBOX_ALLOW_UNRESTRICTED_NET=0): the sandbox gets
# its own network namespace (--unshare-net, loopback only) and reaches the
# outside through the host egress proxy, which listens on a UNIX socket in
# a private directory and refuses loopback, LAN and link-local / cloud
# metadata destinations. The socket and the in-sandbox loopback forwarder
# are bound under NET_DIR; clients get http(s)_proxy pointing at
# 127.0.0.1:PROXY_PORT on the sandbox's own loopback (no host port is
# opened). The sandbox's python3 is looked up in SYSTEM_PATH only (the
# read-only system binds). Assigned at source time, so the caller's
# environment cannot redirect them.
_AI_SANDBOX_DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/ai_wrapper_data"
_AI_SANDBOX_NET_PROXY_HELPER="${_AI_SANDBOX_DATA_DIR}/ai_network_proxy.py"
_AI_SANDBOX_NET_FORWARDER_HELPER="${_AI_SANDBOX_DATA_DIR}/ai_sandbox_net_forwarder.py"
_AI_SANDBOX_NET_DIR=/run/ai-sandbox-net
_AI_SANDBOX_NET_PROXY_PORT=3128
_AI_SANDBOX_NET_NO_PROXY=localhost,127.0.0.1,::1
_AI_SANDBOX_NET_SYSTEM_PATH=/usr/bin:/bin:/usr/local/bin
_AI_SANDBOX_NET_POLL_SECONDS=0.05
# 5 s at the poll interval, for the proxy's READY line and for its exit.
_AI_SANDBOX_NET_MAX_POLLS=100
# sun_path holds 108 bytes including the terminating NUL.
_AI_SANDBOX_UNIX_SOCKET_PATH_MAX=107
# The running proxy (set by _sandbox_start_network_proxy).
_AI_SANDBOX_NET_PROXY_PID=""
_AI_SANDBOX_NET_PROXY_DIR=""
_AI_SANDBOX_NET_PROXY_ERROR=""

# Starts the host egress proxy on a UNIX socket in a fresh private (0700)
# directory under BASE (/tmp when empty) and
# waits for its READY line. The proxy runs in its own session (Ctrl+C in
# the terminal does not stop it) and stops by itself if this shell dies
# without cleaning up (--parent-pid). Sets _AI_SANDBOX_NET_PROXY_PID and
# _AI_SANDBOX_NET_PROXY_DIR; on failure stops what it started, sets
# _AI_SANDBOX_NET_PROXY_ERROR to the reason and returns 1. Runs in the
# calling shell, never in $(...): the proxy's parent must be the shell
# that launches the sandbox. Args: BASE
_sandbox_start_network_proxy() {
    local base="${1:-/tmp}" python_bin dir sock shell_pid polls=0 reason
    _AI_SANDBOX_NET_PROXY_ERROR=""
    if ! python_bin="$(type -P "${_AI_SANDBOX_PYTHON}")"; then
        _AI_SANDBOX_NET_PROXY_ERROR="${_AI_SANDBOX_PYTHON} not found on PATH"; return 1
    fi
    if [[ ! -r "${_AI_SANDBOX_NET_PROXY_HELPER}" ]]; then
        _AI_SANDBOX_NET_PROXY_ERROR="helper ${_AI_SANDBOX_NET_PROXY_HELPER} is missing"; return 1
    fi
    if ! dir="$(mktemp -d "${base%/}/ai-sandbox-net.XXXXXXXX" 2>&1)"; then
        _AI_SANDBOX_NET_PROXY_ERROR="cannot create a private directory under ${base}: ${dir}"; return 1
    fi
    if ! chmod 0700 "${dir}"; then
        rm -rf -- "${dir}"
        _AI_SANDBOX_NET_PROXY_ERROR="cannot make ${dir} private"; return 1
    fi
    sock="${dir}/proxy.sock"
    if (( ${#sock} > _AI_SANDBOX_UNIX_SOCKET_PATH_MAX )); then
        rm -rf -- "${dir}"
        _AI_SANDBOX_NET_PROXY_ERROR="socket path ${sock} is longer than ${_AI_SANDBOX_UNIX_SOCKET_PATH_MAX} bytes"; return 1
    fi
    _AI_SANDBOX_NET_PROXY_DIR="${dir}"
    # Read before the fork: an async command's words expand in the child.
    shell_pid="${BASHPID}"
    "${python_bin}" -I "${_AI_SANDBOX_NET_PROXY_HELPER}" --socket "${sock}" --parent-pid "${shell_pid}" \
        >"${dir}/ready" 2>"${dir}/proxy.log" </dev/null &
    _AI_SANDBOX_NET_PROXY_PID=$!
    until grep -qxF "READY unix ${sock}" "${dir}/ready" 2>/dev/null; do
        if ! kill -0 "${_AI_SANDBOX_NET_PROXY_PID}" 2>/dev/null; then
            reason="$(cat -- "${dir}/proxy.log" 2>/dev/null)"
            _sandbox_stop_network_proxy
            _AI_SANDBOX_NET_PROXY_ERROR="the proxy exited during startup (${reason:-no output})"; return 1
        fi
        if (( polls++ >= _AI_SANDBOX_NET_MAX_POLLS )); then
            reason="$(cat -- "${dir}/proxy.log" 2>/dev/null)"
            _sandbox_stop_network_proxy
            _AI_SANDBOX_NET_PROXY_ERROR="the proxy did not report READY in time (${reason:-no output})"; return 1
        fi
        sleep "${_AI_SANDBOX_NET_POLL_SECONDS}"
    done
    [[ "${AI_SANDBOX_DEBUG:-0}" == "1" ]] && echo_log "DEBUG" "network proxy pid=${_AI_SANDBOX_NET_PROXY_PID} socket=${sock}"
    return 0
}

# Sets _AI_SANDBOX_OWN_EXIT_TRAP to this shell's own EXIT trap ("" if
# none). A subshell's `trap -p` also lists the parent's traps until the
# subshell changes any trap, and a parent's trap must not be restored (and
# so run) when the subshell exits. Resetting a pseudo-signal that shows no
# trap changes nothing but ends that listing. When every candidate shows a
# trap, the source cannot be told: report none (never run a parent's trap).
# bash 3.2 (macOS /bin/bash) keeps listing the parent's traps after any
# reset, so in a subshell there it always reports none: a subshell's own
# EXIT trap is then cleared, not restored, after the launch.
_sandbox_read_own_exit_trap() {
    _AI_SANDBOX_OWN_EXIT_TRAP=""
    if [[ -z "${BASHPID:-}" ]]; then
        # bash 3.2 has no BASHPID: a command substitution's exec'd sh is a
        # child of this shell, so its PPID is this shell's PID.
        [[ "$(exec sh -c 'echo "${PPID}"')" != "$$" ]] && return 0
    elif [[ "${BASHPID}" != "$$" ]]; then
        local probe
        for probe in RETURN ERR DEBUG ""; do
            [[ -z "${probe}" ]] && return 0
            [[ -z "$(trap -p "${probe}")" ]] && break
        done
        trap - "${probe}"
    fi
    _AI_SANDBOX_OWN_EXIT_TRAP="$(trap -p EXIT)"
}

# Stops the proxy started by _sandbox_start_network_proxy (SIGTERM, SIGKILL
# if it has not exited within the poll budget), reports how many requests
# the network policy refused (with AI_SANDBOX_DEBUG=1, the proxy's log
# too), and removes its private directory. Safe to call when nothing runs.
# Args: [AGENT_TAG]
_sandbox_stop_network_proxy() {
    local tag="${1:-sandbox}" pid="${_AI_SANDBOX_NET_PROXY_PID}" dir="${_AI_SANDBOX_NET_PROXY_DIR}" polls=0 blocked
    _AI_SANDBOX_NET_PROXY_PID=""
    _AI_SANDBOX_NET_PROXY_DIR=""
    if [[ -n "${pid}" ]]; then
        kill -TERM "${pid}" 2>/dev/null
        while kill -0 "${pid}" 2>/dev/null && (( polls++ < _AI_SANDBOX_NET_MAX_POLLS )); do
            sleep "${_AI_SANDBOX_NET_POLL_SECONDS}"
        done
        kill -KILL "${pid}" 2>/dev/null
        wait "${pid}" 2>/dev/null
    fi
    [[ -n "${dir}" && -d "${dir}" ]] || return 0
    blocked="$(grep -c '\[BLOCKED\]' "${dir}/proxy.log" 2>/dev/null)"
    if (( ${blocked:-0} > 0 )); then
        echo_log "WARNING" "[${tag}] The sandbox network policy refused ${blocked} request(s) (loopback, LAN or link-local / cloud metadata destinations). AI_SANDBOX_DEBUG=1 lists them."
    fi
    if [[ "${AI_SANDBOX_DEBUG:-0}" == "1" && -s "${dir}/proxy.log" ]]; then
        echo_log "DEBUG" "[${tag}] network proxy log:"
        cat -- "${dir}/proxy.log" >&2
    fi
    rm -rf -- "${dir}"
}

# Kernel knobs that can switch unprivileged user namespaces off; bubblewrap
# needs them. A knob this kernel does not have is inconclusive (the launch
# probe decides). One that exists refuses the launch when it is 0, cannot
# be read, or does not hold a number. Prints the reason and returns 1.
_sandbox_userns_knobs_check() {
    local knob path value
    for knob in kernel/unprivileged_userns_clone user/max_user_namespaces; do
        path="${_AI_SANDBOX_PROC_SYS}/${knob}"
        [[ -e "${path}" ]] || continue
        if ! value="$(cat -- "${path}" 2>/dev/null)"; then
            echo "cannot read ${path}"; return 1
        fi
        if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
            echo "${path} holds '${value}', not a number"; return 1
        fi
        if (( value == 0 )); then
            echo "${knob//\//.} is 0: unprivileged user namespaces are disabled on this host, and bubblewrap needs them"; return 1
        fi
    done
    return 0
}

# Builds the terminal-injection seccomp filter with the host helper (python3
# -I + libseccomp; see linux_tty_seccomp.py). Prints the filter as printf
# %b escapes, or the reason with return 1: a missing interpreter, a helper
# failure (missing library, symbol or architecture support, a filter that
# fails its self-test) or output that is not a whole BPF program.
_sandbox_tty_filter() {
    local python_bin out rc=0
    local -r escape_len=4 bpf_insn_bytes=8
    python_bin="$(type -P "${_AI_SANDBOX_PYTHON}")" || { echo "${_AI_SANDBOX_PYTHON} not found on PATH"; return 1; }
    [[ -r "${_AI_SANDBOX_TTY_FILTER_HELPER}" ]] || { echo "helper ${_AI_SANDBOX_TTY_FILTER_HELPER} is missing"; return 1; }
    out="$("${python_bin}" -I "${_AI_SANDBOX_TTY_FILTER_HELPER}" 2>&1 </dev/null)" || rc=$?
    if (( rc != 0 )); then
        echo "${out:-helper exited ${rc}}"; return 1
    fi
    if [[ ! "${out}" =~ ^(\\x[0-9a-f]{2})+$ ]] || (( ${#out} % (escape_len * bpf_insn_bytes) != 0 )); then
        echo "helper output is not a BPF program"; return 1
    fi
    printf '%s\n' "${out}"
}

# Launch probe: runs the external `true` in a minimal bubblewrap sandbox with
# the launch's isolation options OPTION... (nested user namespace
# restriction, a fresh terminal-filter descriptor), so that a host that
# cannot create user namespaces, a bubblewrap without a required option or
# a filter bubblewrap cannot load is refused, with the reason, before the
# client starts. Mirrors the launch's system binds that exist here. Always
# requires a new user namespace (--unshare-user): --unshare-all alone only
# tries one, so a caller holding namespace capabilities (e.g. root in a
# parent user namespace) would pass without one being created. Prints the
# reason and returns 1 on failure.
_sandbox_linux_probe() {
    local true_bin out rc=0 dir
    true_bin="$(type -P true)" || { echo "setup problem: no external 'true' executable on PATH for the probe"; return 1; }
    local -a probe_args=(--die-with-parent --unshare-all --unshare-user "$@")
    for dir in /usr /bin /lib /lib64; do
        [[ -e "${dir}" ]] && probe_args+=(--ro-bind "${dir}" "${dir}")
    done
    out="$(bwrap "${probe_args[@]}" "${true_bin}" 2>&1 </dev/null)" || rc=$?
    (( rc == 0 )) && return 0
    out="${out:-no output}"
    case "${out}" in
        *"Unknown option"*)
            echo "this bubblewrap lacks an option the sandbox needs (${out}). Upgrade bubblewrap, or turn the protection that needs it off: AI_SANDBOX_ALLOW_NESTED_USERNS=1 (--disable-userns, --assert-userns-disabled) or AI_SANDBOX_ALLOW_TIOCSTI=1 (--add-seccomp-fd)." ;;
        *"not disabled"*|*"disable-userns"*|*"max_user_namespaces"*)
            echo "bubblewrap could not stop nested user namespaces (${out}). Set AI_SANDBOX_ALLOW_NESTED_USERNS=1 to launch without that restriction." ;;
        *seccomp*|*SECCOMP*)
            echo "bubblewrap could not load the terminal-injection filter (${out}). Set AI_SANDBOX_ALLOW_TIOCSTI=1 to launch without it." ;;
        *execvp*|*"No such file or directory"*)
            echo "setup problem, not a user namespace denial: the probe could not run ${true_bin} in a minimal sandbox (${out})." ;;
        *namespace*|*"uid map"*|*"Operation not permitted"*|*"Permission denied"*)
            echo "user namespaces cannot be created here; the kernel, a security module (e.g. AppArmor) or a container runtime denies them (${out})." ;;
        *)
            echo "bubblewrap probe exited ${rc} (${out})." ;;
    esac
    return 1
}

# Canonical path of the host user runtime dir DIR (normally $XDG_RUNTIME_DIR).
# Prints the resolved path and returns 0 when DIR is set, absolute, an
# existing directory, and owned by the current user; otherwise prints the
# reason and returns 1. Symlinked spellings resolve to their target.
_sandbox_runtime_dir_canonical() {
    local dir="${1}" canon
    [[ -n "${dir}" ]] || { echo "XDG_RUNTIME_DIR is not set"; return 1; }
    [[ "${dir}" == /* ]] || { echo "'${dir}' is not an absolute path"; return 1; }
    [[ -d "${dir}" ]] || { echo "'${dir}' is not an existing directory"; return 1; }
    canon="$(cd "${dir}" 2>/dev/null && pwd -P)" || { echo "'${dir}' cannot be resolved"; return 1; }
    [[ -O "${canon}" ]] || { echo "${canon} is not owned by you"; return 1; }
    printf '%s\n' "${canon}"
}

# Validation for AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1, which binds the host
# runtime dir RW. On top of _sandbox_runtime_dir_canonical, refuses system
# roots, $HOME, dotfile dirs under it, a dir containing $HOME, and a dir
# writable by group or others. Prints the canonical path, or the reason
# with return 1. Args: DIR HOME
_sandbox_broad_runtime_dir() {
    local dir="${1}" home="${2%/}" canon home_canon perm_out perm_rc=0
    canon="$(_sandbox_runtime_dir_canonical "${dir}")" || { echo "${canon}"; return 1; }
    home_canon="$(cd "${home}" 2>/dev/null && pwd -P)" || home_canon="${home}"
    if _sandbox_sensitive_dir_kind "${canon}" "${home}" >/dev/null \
            || _sandbox_sensitive_dir_kind "${canon}" "${home_canon}" >/dev/null; then
        echo "${canon} is a system location, \$HOME or a dotfile directory under \$HOME"; return 1
    fi
    case "${home_canon}/" in
        "${canon}"/*) echo "${canon} contains \$HOME"; return 1 ;;
    esac
    # Fail closed: a checker that exits nonzero refuses, whatever it printed.
    perm_out="$(find "${canon}" -maxdepth 0 \( -perm -020 -o -perm -002 \) -print 2>&1)" || perm_rc=$?
    if (( perm_rc != 0 )); then
        echo "cannot check permissions of ${canon}: ${perm_out:-find exited ${perm_rc}}"; return 1
    fi
    if [[ -n "${perm_out}" ]]; then
        echo "${canon} is writable by other users"; return 1
    fi
    printf '%s\n' "${canon}"
}

# Succeeds when the private runtime dir can use the host runtime dir's own
# canonical path CANON inside the sandbox, so paths the host session hands
# out ($XDG_RUNTIME_DIR/..., DOCKER_HOST, SSH_AUTH_SOCK) stay valid. CANON
# must lie below /run or /tmp (fresh tmpfs in the sandbox), and no path
# already in the bwrap argv (ARGS: host binds such as WORKDIR) may equal,
# contain or lie inside it: --dir there could create or reuse a
# host-backed directory instead of a private one. Args: CANON ARGS...
_sandbox_runtime_dir_mirrorable() {
    local canon="${1}" arg
    shift
    case "${canon}" in
        /run/?*|/tmp/?*) ;;
        *) return 1 ;;
    esac
    for arg in "$@"; do
        [[ "${arg}" == /* ]] || continue
        case "${arg}" in /run|/tmp) continue ;; esac
        [[ "${arg}" == "${canon}" || "${canon}" == "${arg%/}/"* || "${arg}" == "${canon}/"* ]] && return 1
    done
    return 0
}

_run_sandboxed_agent_linux() {
    local agent_name="${1}"
    local command="${1}"
    shift

    # ===== PRE-FLIGHT VALIDATION =====

    # Check required commands exist
    if ! command -v bwrap &>/dev/null; then
        echo_log "ERROR" "[$agent_name] Required commands not found: bwrap"
        echo_log "ERROR" "Please install: bubblewrap"
        exit 127
    fi

    # User namespace knobs, read from procfs (no sysctl binary needed). An
    # absent knob is not a failure: the launch probe below runs a real
    # bubblewrap sandbox before the client starts.
    local userns_reason
    if ! userns_reason="$(_sandbox_userns_knobs_check)"; then
        echo_log "ERROR" "[$agent_name] User namespaces are not available: ${userns_reason}"
        exit 1
    fi

    # Validate command specified
    if [[ -z "${command}" ]]; then
        echo_log "ERROR" "[$agent_name] No command specified."
        echo_log "ERROR" "Usage: run_sandboxed_agent COMMAND -- [BWRAP_FLAGS...] -- [CMD_ARGS...]"
        exit 1
    fi

    # Verify command exists
    if ! command -v "${command}" &>/dev/null; then
        echo_log "ERROR" "[${agent_name}] Command not found: ${command}"
        echo_log "ERROR" "Please ensure '${command}' is installed and in PATH."
        exit 127
    fi

    # Opt-in credential/daemon access — same flag names and semantics as the
    # macOS SBPL profile's (when (equal? (param "...") "1") ...) gates, so a
    # single Settings-menu toggle controls both backends. Default "0";
    # normalize any non-"1" value to "0" so a typo doesn't silently widen.
    local pass_kube="${AI_SANDBOX_PASS_KUBE:-0}"; [[ "${pass_kube}" == "1" ]] || pass_kube=0
    local pass_aws="${AI_SANDBOX_PASS_AWS:-0}"; [[ "${pass_aws}" == "1" ]] || pass_aws=0
    local pass_ssh_agent="${AI_SANDBOX_PASS_SSH_AGENT:-0}"; [[ "${pass_ssh_agent}" == "1" ]] || pass_ssh_agent=0
    local pass_docker="${AI_SANDBOX_PASS_DOCKER:-0}"; [[ "${pass_docker}" == "1" ]] || pass_docker=0
    local allow_docker="${AI_SANDBOX_ALLOW_DOCKER:-0}"; [[ "${allow_docker}" == "1" ]] || allow_docker=0
    local pass_gh="${AI_SANDBOX_PASS_GH:-0}"; [[ "${pass_gh}" == "1" ]] || pass_gh=0
    local pass_gitlab="${AI_SANDBOX_PASS_GITLAB:-0}"; [[ "${pass_gitlab}" == "1" ]] || pass_gitlab=0
    local pass_openai="${AI_SANDBOX_PASS_OPENAI:-0}"; [[ "${pass_openai}" == "1" ]] || pass_openai=0
    local allow_sensitive_workdir="${AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR:-0}"; [[ "${allow_sensitive_workdir}" == "1" ]] || allow_sensitive_workdir=0
    local allow_ro_credentials="${AI_SANDBOX_ALLOW_RO_CREDENTIALS:-0}"; [[ "${allow_ro_credentials}" == "1" ]] || allow_ro_credentials=0
    # Linux-only host-path gates (catalog OS_SCOPE "linux"; the macOS
    # backend never binds these paths).
    local allow_bin_rw="${AI_SANDBOX_ALLOW_BIN_RW:-0}"; [[ "${allow_bin_rw}" == "1" ]] || allow_bin_rw=0
    local allow_skills_rw="${AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW:-0}"; [[ "${allow_skills_rw}" == "1" ]] || allow_skills_rw=0
    local allow_android="${AI_SANDBOX_ALLOW_ANDROID:-0}"; [[ "${allow_android}" == "1" ]] || allow_android=0
    local pass_tailscale="${AI_SANDBOX_PASS_TAILSCALE:-0}"; [[ "${pass_tailscale}" == "1" ]] || pass_tailscale=0
    local allow_xdg_runtime_rw="${AI_SANDBOX_ALLOW_XDG_RUNTIME_RW:-0}"; [[ "${allow_xdg_runtime_rw}" == "1" ]] || allow_xdg_runtime_rw=0
    local allow_nested_userns="${AI_SANDBOX_ALLOW_NESTED_USERNS:-0}"; [[ "${allow_nested_userns}" == "1" ]] || allow_nested_userns=0
    local allow_tiocsti="${AI_SANDBOX_ALLOW_TIOCSTI:-0}"; [[ "${allow_tiocsti}" == "1" ]] || allow_tiocsti=0
    local allow_unrestricted_net="${AI_SANDBOX_ALLOW_UNRESTRICTED_NET:-0}"; [[ "${allow_unrestricted_net}" == "1" ]] || allow_unrestricted_net=0
    # AI_SANDBOX_PASS_ENV is a str (comma-separated var-name list), not a
    # bool — no 0/1 normalization, empty is the meaningful default.
    local pass_env_list="${AI_SANDBOX_PASS_ENV:-}"

    # Skip the separator "--" between command and bwrap flags
    if [[ "${1}" == "--" ]]; then
        shift
    fi

    # Parse extra bwrap flags (until next --)
    local -a extra_bwrap_flags=()
    while [[ $# -gt 0 && "${1}" != "--" ]]; do
        extra_bwrap_flags+=("${1}")
        shift
    done

    # Skip the separator "--" between bwrap flags and command args
    if [[ "${1}" == "--" ]]; then
        shift
    fi

    # Remaining args are command arguments
    local -a cmd_args=("$@")

    # AI_SANDBOX_EXTRA_{RW,RO}_DIRS: comma-separated absolute paths that
    # extend the per-call bind list without patching individual wrappers.
    # Populated by the interactive Settings sub-menu (str catalog entries
    # in ai_wrapper_lib.bash) or set directly in the environment. Each
    # entry is resolved (_sandbox_resolve_extra_dir) before it is bound or
    # classified, so a symlink or ".." cannot carry a sensitive target past
    # the guard below. Missing entries WARN and are skipped — a preset that
    # references a path present on the user's other machine should stay
    # usable here; an entry that exists but does not resolve to a
    # directory refuses the launch.
    # Entries accepted from AI_SANDBOX_EXTRA_{RW,RO}_DIRS, tracked separately
    # from extra_bwrap_flags (which also carries the wrapper's own trusted
    # binds, e.g. ~/.claude via WRAPPER_FLAGS). The sensitivity guard below
    # must only ever see user-supplied entries — scanning extra_bwrap_flags
    # wholesale would also flag those trusted binds and refuse to launch.
    # Tilde is preserved verbatim in preset files; quoted [[ -d ]] does not
    # expand it, so use parameter substitution to expand a leading ~ to $HOME.
    # _user_extra_bind_dirs holds the resolved directories (what is bound),
    # _user_extra_bind_names the entries as given (classified too, see
    # _sandbox_sensitive_pair_kind, and named in refusals).
    local -a _user_extra_bind_dirs=() _user_extra_bind_names=() _user_extra_bwrap_flags=()
    local _extra_dirs_ifs _d _d_resolved _d_rc
    if [[ -n "${AI_SANDBOX_EXTRA_RW_DIRS:-}" ]]; then
        _extra_dirs_ifs="${IFS}"; IFS=','
        for _d in ${AI_SANDBOX_EXTRA_RW_DIRS}; do
            _d="${_d#"${_d%%[![:space:]]*}"}"
            _d="${_d%"${_d##*[![:space:]]}"}"
            [[ -z "${_d}" ]] && continue
            _d="${_d/#\~/${HOME}}"
            _d_resolved="$(_sandbox_resolve_extra_dir "${agent_name}" AI_SANDBOX_EXTRA_RW_DIRS "${_d}")"; _d_rc=$?
            (( _d_rc == 2 )) && continue
            (( _d_rc == 0 )) || exit 1
            _user_extra_bwrap_flags+=(--bind "${_d_resolved}" "${_d_resolved}")
            _user_extra_bind_dirs+=("${_d_resolved}")
            _user_extra_bind_names+=("${_d}")
            _sandbox_warn_extra_rw_git "${agent_name}" "${_d_resolved}"
        done
        IFS="${_extra_dirs_ifs}"
    fi
    if [[ -n "${AI_SANDBOX_EXTRA_RO_DIRS:-}" ]]; then
        _extra_dirs_ifs="${IFS}"; IFS=','
        for _d in ${AI_SANDBOX_EXTRA_RO_DIRS}; do
            _d="${_d#"${_d%%[![:space:]]*}"}"
            _d="${_d%"${_d##*[![:space:]]}"}"
            [[ -z "${_d}" ]] && continue
            _d="${_d/#\~/${HOME}}"
            _d_resolved="$(_sandbox_resolve_extra_dir "${agent_name}" AI_SANDBOX_EXTRA_RO_DIRS "${_d}")"; _d_rc=$?
            (( _d_rc == 2 )) && continue
            (( _d_rc == 0 )) || exit 1
            extra_bwrap_flags+=(--ro-bind "${_d_resolved}" "${_d_resolved}")
            _user_extra_bind_dirs+=("${_d_resolved}")
            _user_extra_bind_names+=("${_d}")
        done
        IFS="${_extra_dirs_ifs}"
    fi

    # User RW extras mount BEFORE the wrapper's own binds: bwrap's later
    # mount wins, so an extra RW dir equal to or above WORKDIR (or a
    # worktree's shared .git) must not cover the wrapper's read-only git
    # metadata layers. User RO extras stay after them, so the wrapper's RW
    # binds (git dir pin, worktree common dir) cannot reopen a directory
    # the user asked to be read-only. (The macOS backend renders RO as
    # order-independent denies instead.)
    extra_bwrap_flags=("${_user_extra_bwrap_flags[@]+"${_user_extra_bwrap_flags[@]}"}" \
        "${extra_bwrap_flags[@]+"${extra_bwrap_flags[@]}"}")

    # Setup paths
    WORKDIR="$(pwd)"
    HOME_DIR="${HOME}"

    # Validate critical paths
    if [[ ! -d "${HOME_DIR}" ]]; then
        echo_log "ERROR" "[$agent_name] HOME directory does not exist: ${HOME_DIR}"
        exit 1
    fi

    if [[ ! -d "${WORKDIR}" ]]; then
        echo_log "ERROR" "[$agent_name] Working directory does not exist: ${WORKDIR}"
        exit 1
    fi

    # Classify and bind the canonical WORKDIR, not the logical $(pwd): a cwd
    # reached through a symlink (~/proj -> /etc, ~/proj -> ~/.ssh) or a
    # symlinked ancestor would otherwise pass the string guard below while
    # bwrap follows the link and binds the sensitive target read-write.
    # HOME is resolved the same way so the comparisons hold when $HOME
    # itself sits behind a symlink.
    local resolved_workdir resolved_home
    if ! resolved_workdir="$(_realpath "${WORKDIR}")" || [[ -z "${resolved_workdir}" || ! -d "${resolved_workdir}" ]]; then
        echo_log "ERROR" "[$agent_name] Cannot resolve the working directory ${WORKDIR}; refusing to launch."
        exit 1
    fi
    [[ "${resolved_workdir}" == "/" ]] || resolved_workdir="${resolved_workdir%/}"
    resolved_home="$(_realpath "${HOME_DIR}")" || resolved_home="${HOME_DIR%/}"
    resolved_home="${resolved_home%/}"
    local workdir_label="${resolved_workdir}"
    [[ "${WORKDIR}" == "${resolved_workdir}" ]] || workdir_label="${resolved_workdir} (via ${WORKDIR})"

    # Refuse to sandbox with a WORKDIR that's a system root, $HOME itself, or
    # a dotfile dir directly under $HOME: the WORKDIR bind above grants RW on
    # (subpath WORKDIR) unconditionally, so a too-broad cwd neutralises the
    # write fence and can expose credentials the read fence would otherwise
    # deny. Mirrors macos_sandbox_exec.bash's WORKDIR refusal (see its
    # AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR handling), adapted to Linux
    # top-level system directories instead of macOS-specific ones
    # (/Users, /Library, /Applications, /System don't exist here).
    # Bypass with AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 when intentional.
    if [[ "${allow_sensitive_workdir}" != "1" ]]; then
        local home_normalized="${HOME_DIR%/}"
        case "$(_sandbox_sensitive_pair_kind "${WORKDIR}" "${resolved_workdir}" "${home_normalized}" "${resolved_home}")" in
            system)
                echo_log "ERROR" "[$agent_name] Refusing to sandbox with WORKDIR=${workdir_label} (top-level or system location). cd into a project directory first, or set AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 to override."
                exit 1
                ;;
            home)
                echo_log "ERROR" "[$agent_name] Refusing to sandbox with WORKDIR=\$HOME (${workdir_label}); that would grant RW on the entire home directory. cd into a subdirectory first, or set AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 to override."
                exit 1
                ;;
            dotfile)
                echo_log "ERROR" "[$agent_name] Refusing to sandbox with WORKDIR=${workdir_label} (a dotfile directory directly under \$HOME — granting RW here likely exposes credentials). cd into a non-sensitive project directory, or set AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 to override."
                exit 1
                ;;
        esac

        # Same sensitivity guard applied to every directory accepted from
        # AI_SANDBOX_EXTRA_RW_DIRS / AI_SANDBOX_EXTRA_RO_DIRS. Without this,
        # a settings-menu preset like AI_SANDBOX_EXTRA_RW_DIRS=~/.local
        # would grant broad RW/RO on a HOME dotfile subtree that the WORKDIR
        # guard above was specifically designed to refuse. Scoped to
        # _user_extra_bind_dirs (not extra_bwrap_flags) so it never sees the
        # wrapper's own trusted binds (~/.claude, ~/.claude.json, etc.).
        local _d_i _d_label
        for (( _d_i = 0; _d_i < ${#_user_extra_bind_dirs[@]}; _d_i++ )); do
            _d="${_user_extra_bind_names[_d_i]}"
            _d_label="${_d}"
            [[ "${_d%/}" == "${_user_extra_bind_dirs[_d_i]}" ]] || _d_label="${_d} -> ${_user_extra_bind_dirs[_d_i]}"
            case "$(_sandbox_sensitive_pair_kind "${_d}" "${_user_extra_bind_dirs[_d_i]}" "${home_normalized}" "${resolved_home}")" in
                system)
                    echo_log "ERROR" "[$agent_name] Refusing extra bind '${_d_label}' (top-level or system location). Remove it from AI_SANDBOX_EXTRA_RW_DIRS/AI_SANDBOX_EXTRA_RO_DIRS, or set AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 to override."
                    exit 1
                    ;;
                home)
                    echo_log "ERROR" "[$agent_name] Refusing extra bind '${_d_label}' (== \$HOME). Set AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 to override."
                    exit 1
                    ;;
                dotfile)
                    echo_log "ERROR" "[$agent_name] Refusing extra bind '${_d_label}' (under HOME dotfile dir — grants read/write on credentials). Set AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 to override."
                    exit 1
                    ;;
            esac
        done
    fi

    # ===== PATH VALIDATION FOR BIND MOUNTS =====

    # Validate and filter paths in extra_bwrap_flags
    local strict_mode="${BWRAP_STRICT:-0}"
    local -a validated_bwrap_flags=()
    local i=0
    local bind_errors=0

    while [[ ${i} -lt ${#extra_bwrap_flags[@]} ]]; do
        local flag="${extra_bwrap_flags[$i]}"

        # Check if this is a bind flag that requires path validation
        if [[ "${flag}" =~ ^--(ro-)?bind$ ]]; then
            local src_path="${extra_bwrap_flags[$((i+1))]}"
            local dst_path="${extra_bwrap_flags[$((i+2))]}"

            if [[ -n "${src_path}" && ! "${src_path}" =~ ^-- ]]; then
                if [[ ! -e "${src_path}" ]]; then
                    if [[ "${strict_mode}" == "1" ]]; then
                        echo_log "ERROR" "[$agent_name] Bind source path does not exist: ${src_path}"
                        bind_errors=$((bind_errors + 1))
                        # Skip this bind in strict mode (will exit after loop)
                        i=$((i + 3))
                        continue
                    else
                        echo_log "WARNING" "[$agent_name] Bind source path does not exist (skipping): ${src_path}"
                        # Skip this bind mount entirely
                        i=$((i + 3))
                        continue
                    fi
                fi
            fi

            # Path exists or is special, add all three arguments
            validated_bwrap_flags+=("${flag}" "${src_path}" "${dst_path}")
            i=$((i + 3))
        else
            # Not a bind flag, just add it
            validated_bwrap_flags+=("${flag}")
            i=$((i + 1))
        fi
    done

    if [[ ${bind_errors} -gt 0 ]]; then
        echo_log "ERROR" "[$agent_name] ${bind_errors} bind path(s) missing. Set BWRAP_STRICT=0 to continue with warnings."
        exit 1
    fi

    # ~/bin (on the sandbox PATH, and run by the host user outside the
    # sandbox) and the shared agent-skill source (copied into every client's
    # skill dir by setup_skills) are read-only unless explicitly relaxed:
    # a writable copy lets the agent plant binaries or poison skills that
    # later run unsandboxed. Mounted before WORKDIR and the extra binds so
    # an explicit grant at or above them (WORKDIR, AI_SANDBOX_EXTRA_RW_DIRS)
    # still wins — bwrap's later mount covers the earlier one. Missing
    # paths are skipped, never created.
    local -a protected_home_binds=()
    local _p_dir _p_rw _p_var
    for _p_dir in bin ai-wrapper/.agents; do
        if [[ "${_p_dir}" == "bin" ]]; then
            _p_rw="${allow_bin_rw}"; _p_var=AI_SANDBOX_ALLOW_BIN_RW
        else
            _p_rw="${allow_skills_rw}"; _p_var=AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW
        fi
        [[ -d "${HOME_DIR}/${_p_dir}" ]] || continue
        if [[ "${_p_rw}" == "1" ]]; then
            echo_log "WARNING" "[$agent_name] ${_p_var}=1: ~/${_p_dir} is writable inside the sandbox; the agent can change files the host runs or loads outside it."
            protected_home_binds+=(--bind "${HOME_DIR}/${_p_dir}" "${HOME_DIR}/${_p_dir}")
        else
            protected_home_binds+=(--ro-bind "${HOME_DIR}/${_p_dir}" "${HOME_DIR}/${_p_dir}")
        fi
    done

    # Network: a private network namespace by default (no host loopback,
    # host abstract UNIX sockets, LAN or direct egress; the proxy is wired
    # in at launch below); the host network only when opted in.
    local -a net_args=(--unshare-net)
    if [[ "${allow_unrestricted_net}" == "1" ]]; then
        echo_log "WARNING" "[$agent_name] AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1: the sandbox shares the host network; the agent can reach services on this machine (loopback, abstract UNIX sockets such as X11 or D-Bus), your LAN and cloud metadata endpoints, and send traffic anywhere without the egress proxy."
        net_args=(--share-net)
    fi

    # Build bwrap arguments
    local -a bwrap_args=(
        --die-with-parent
        --unshare-all
        "${net_args[@]}"
        # Common read-only system binds
        --ro-bind /usr /usr
        --ro-bind /bin /bin
        --ro-bind /lib /lib
        --ro-bind /lib64 /lib64
        # /etc is bound wholesale below, which already covers ssl/hosts/
        # resolv.conf/nsswitch.conf — separate --ro-bind entries for those
        # used to exist here too. They were pure dead weight when the path
        # existed (already covered by the /etc bind) and a hard sandbox-
        # launch failure when it didn't (e.g. a minimal container without
        # /etc/ssl) — bwrap errors on a missing bind source regardless of
        # whether a parent directory was already bound. Confirmed via a
        # real Ubuntu 24.04 + bubblewrap 0.9.0 repro.
        --ro-bind /etc /etc
        # Virtual filesystems
        --tmpfs /tmp
        --tmpfs /var
        --proc /proc
        --dev /dev
        "${protected_home_binds[@]+"${protected_home_binds[@]}"}"
        # Working directory (read-write), from its resolved path
        --bind "${resolved_workdir}" "${resolved_workdir}"
    )
    # A cwd reached through a symlink is also mounted at the logical path,
    # so --chdir below keeps the cwd tooling and the user expect. The git
    # metadata overlays (_wrapper_git_ro_bind / _wrapper_git_pin) cover
    # both paths.
    [[ "${WORKDIR}" == "${resolved_workdir}" ]] || bwrap_args+=(--bind "${resolved_workdir}" "${WORKDIR}")

    # Nested user namespaces: by default the agent cannot create its own
    # (each one is fresh kernel attack surface and a way to gain namespace
    # capabilities). Clients reaching Docker/Podman through a host socket
    # are unaffected; nested bubblewrap, Chromium's namespace sandbox and
    # daemons that build their own namespaces need the opt-out.
    local -a isolation_args=()
    if [[ "${allow_nested_userns}" == "1" ]]; then
        echo_log "WARNING" "[$agent_name] AI_SANDBOX_ALLOW_NESTED_USERNS=1: the agent can create its own user namespaces inside the sandbox, which exposes more kernel attack surface."
    else
        isolation_args+=("${_AI_SANDBOX_NO_NESTED_USERNS_ARGS[@]}")
    fi
    bwrap_args+=("${isolation_args[@]+"${isolation_args[@]}"}")

    # Android SDK/AVD dir (RW, includes debug keystores) only when opted in.
    if [[ "${allow_android}" == "1" && -d "${HOME_DIR}/Android" ]]; then
        bwrap_args+=(--bind "${HOME_DIR}/Android" "${HOME_DIR}/Android")
    fi

    # Add system-wide AI agent rules (read-only) if they exist
    if [[ -f "${HOME_DIR}/AGENTS.md" ]]; then
        bwrap_args+=(--ro-bind "${HOME_DIR}/AGENTS.md" "${HOME_DIR}/AGENTS.md")
    fi
    if [[ -f "${HOME_DIR}/CLAUDE.md" ]]; then
        bwrap_args+=(--ro-bind "${HOME_DIR}/CLAUDE.md" "${HOME_DIR}/CLAUDE.md")
    fi

    # Add /run for network services, systemd-resolved, and Docker
    # Note: Docker socket needs write access, so we bind specific paths
    if [[ -d /run ]]; then
        # Create tmpfs for /run and bind specific needed subdirs
        bwrap_args+=(--tmpfs /run)

        # Create /var/run as symlink to /run (Docker compatibility)
        bwrap_args+=(--symlink /run /var/run)

        # Bind systemd-resolved for DNS
        if [[ -d /run/systemd/resolve ]]; then
            bwrap_args+=(--ro-bind /run/systemd/resolve /run/systemd/resolve)
        fi

        if [[ "${allow_docker}" == "1" ]]; then
            # Bind Docker socket with write access if it exists
            if [[ -S /run/docker.sock ]]; then
                bwrap_args+=(--bind /run/docker.sock /run/docker.sock)
            fi

            # Bind Docker runtime directory for container management
            if [[ -d /run/docker ]]; then
                bwrap_args+=(--bind /run/docker /run/docker)
            fi

            # Bind Docker containerd socket if it exists
            if [[ -S /run/containerd/containerd.sock ]]; then
                bwrap_args+=(--bind /run/containerd/containerd.sock /run/containerd/containerd.sock)
            fi
        fi

        # Tailscale daemon socket only when opted in. --ro-bind only stops
        # the socket inode being replaced or removed; connecting and talking
        # to the LocalAPI still works, and tailscaled authorises each
        # request by the caller's UID (the sandbox runs as the host user),
        # so what the agent can do is whatever tailscaled allows that user.
        if [[ "${pass_tailscale}" == "1" && -S "${_AI_SANDBOX_TAILSCALE_SOCKET}" ]]; then
            echo_log "WARNING" "[$agent_name] AI_SANDBOX_PASS_TAILSCALE=1: the Tailscale LocalAPI is reachable with your user's tailscaled permissions; the read-only socket bind does not make the API read-only."
            bwrap_args+=(--ro-bind "${_AI_SANDBOX_TAILSCALE_SOCKET}" /run/tailscale/tailscaled.sock)
        fi

    elif [[ -d /var/run ]]; then
        bwrap_args+=(--tmpfs /var/run)

        if [[ "${allow_docker}" == "1" && -S /var/run/docker.sock ]]; then
            bwrap_args+=(--bind /var/run/docker.sock /var/run/docker.sock)
        fi
    fi

    # Add Docker data directories for container filesystem access
    # This allows agents to interact with running containers and their volumes
    if [[ "${allow_docker}" == "1" && -d /var/lib/docker ]]; then
        # Need to create parent directory structure since /var is tmpfs
        bwrap_args+=(--dir /var/lib)
        bwrap_args+=(--bind /var/lib/docker /var/lib/docker)
    fi

    # User runtime directory (XDG_RUNTIME_DIR). The host one holds the
    # session's sockets — D-Bus session bus, systemd --user, keyring,
    # display and audio servers, SSH/GPG agents, rootless container
    # daemons — and those daemons authorise callers by UID, which the
    # sandbox shares; a read-only bind would not change that. So by
    # default the sandbox gets its own empty, private (0700) runtime dir
    # and only named sockets are shared: rootless Docker / Podman below
    # (AI_SANDBOX_ALLOW_DOCKER) and the SSH agent further down
    # (AI_SANDBOX_PASS_SSH_AGENT). The private dir keeps the host path
    # when that is safe (_sandbox_runtime_dir_mirrorable), else
    # /run/user/UID. XDG_RUNTIME_DIR is optional on the host (CI runners,
    # containers, non-desktop sessions): an unset or unusable value gets
    # the private dir too, never a host grant.
    # AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1 restores the old wholesale RW bind
    # of the validated host dir; an invalid host dir then fails the launch.
    local raw_runtime_dir="${XDG_RUNTIME_DIR:-}" host_runtime_dir="" sandbox_runtime_dir="" runtime_reason=""
    local rootless_docker_shared=0 _rt_sock
    if [[ "${allow_xdg_runtime_rw}" == "1" ]]; then
        if ! host_runtime_dir="$(_sandbox_broad_runtime_dir "${raw_runtime_dir}" "${HOME_DIR}")"; then
            echo_log "ERROR" "[$agent_name] AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1 but the host runtime directory cannot be shared: ${host_runtime_dir}. Point XDG_RUNTIME_DIR at your own session runtime dir (usually /run/user/$(id -u)), or turn the setting off to give the sandbox a private runtime dir."
            exit 1
        fi
        echo_log "WARNING" "[$agent_name] AI_SANDBOX_ALLOW_XDG_RUNTIME_RW=1: ${host_runtime_dir} is bound read-write. Every socket in it is reachable with your user ID (D-Bus session bus, systemd --user, keyring, display/audio, SSH/GPG agents, rootless Docker/Podman), whatever the other sandbox settings say; what the agent can do depends on each service and may include running programs outside the sandbox. Turn it off unless a tool in the session needs these services."
        sandbox_runtime_dir="${host_runtime_dir}"
        bwrap_args+=(--bind "${host_runtime_dir}" "${host_runtime_dir}")
        [[ -S "${host_runtime_dir}/${_AI_SANDBOX_ROOTLESS_DOCKER_SOCKET}" ]] && rootless_docker_shared=1
    else
        host_runtime_dir="$(_sandbox_runtime_dir_canonical "${raw_runtime_dir}")" || { runtime_reason="${host_runtime_dir}"; host_runtime_dir=""; }
        if [[ -n "${host_runtime_dir}" ]] && _sandbox_runtime_dir_mirrorable "${host_runtime_dir}" "${bwrap_args[@]}"; then
            sandbox_runtime_dir="${host_runtime_dir}"
        else
            sandbox_runtime_dir="/run/user/$(id -u)"
            [[ -n "${raw_runtime_dir}" ]] && echo_log "INFO" "[$agent_name] XDG_RUNTIME_DIR=${raw_runtime_dir}: ${runtime_reason:-path cannot be reused inside the sandbox}; the sandbox uses a private ${sandbox_runtime_dir} instead."
        fi
        bwrap_args+=(--perms "${_AI_SANDBOX_RUNTIME_DIR_PERMS}" --dir "${sandbox_runtime_dir}")
        if [[ "${allow_docker}" == "1" && -n "${host_runtime_dir}" ]]; then
            for _rt_sock in "${_AI_SANDBOX_ROOTLESS_DOCKER_SOCKET}" "${_AI_SANDBOX_ROOTLESS_PODMAN_SOCKET}"; do
                [[ -S "${host_runtime_dir}/${_rt_sock}" && ! -L "${host_runtime_dir}/${_rt_sock}" \
                    && -O "${host_runtime_dir}/${_rt_sock}" ]] || continue
                bwrap_args+=(--bind "${host_runtime_dir}/${_rt_sock}" "${sandbox_runtime_dir}/${_rt_sock}")
                [[ "${_rt_sock}" == "${_AI_SANDBOX_ROOTLESS_DOCKER_SOCKET}" ]] && rootless_docker_shared=1
            done
        fi
    fi

    # Add extra bwrap flags (user-specified binds, etc.) - using validated flags
    bwrap_args+=("${validated_bwrap_flags[@]}")

    # Environment and working directory
    bwrap_args+=(
        --clearenv
        --setenv HOME "${HOME_DIR}"
        --setenv USER "${USER:-$(id -un)}"
        --setenv PATH "${HOME_DIR}/bin:/usr/bin:/usr/sbin:/bin:/sbin:${HOME_DIR}/.local/bin"
        --setenv LANG "${LANG:-en_US.UTF-8}"
        --setenv TERM "${TERM:-xterm-256color}"
        --chdir "${WORKDIR}"
        --setenv XDG_RUNTIME_DIR "${sandbox_runtime_dir}"
    )

    # Pass through additional terminal-related variables if set (for better terminal support)
    [[ -n "${COLORTERM:-}" ]] && bwrap_args+=(--setenv COLORTERM "${COLORTERM}")
    [[ -n "${TERM_PROGRAM:-}" ]] && bwrap_args+=(--setenv TERM_PROGRAM "${TERM_PROGRAM}")

    # Pass through Docker environment variables and ~/.docker config if opted in
    if [[ "${pass_docker}" == "1" ]]; then
        # A DOCKER_HOST naming the shared rootless socket under a host
        # runtime dir spelling the sandbox does not reuse (symlink alias,
        # synthetic /run/user/UID) is pointed at where the socket is bound.
        local docker_host="${DOCKER_HOST:-}" _rt_prefix
        if [[ "${rootless_docker_shared}" == "1" ]]; then
            for _rt_prefix in "${raw_runtime_dir%/}" "${host_runtime_dir}"; do
                [[ -n "${_rt_prefix}" && "${docker_host}" == "unix://${_rt_prefix}/${_AI_SANDBOX_ROOTLESS_DOCKER_SOCKET}" ]] \
                    && docker_host="unix://${sandbox_runtime_dir}/${_AI_SANDBOX_ROOTLESS_DOCKER_SOCKET}"
            done
        fi
        [[ -n "${docker_host}" ]]        && bwrap_args+=(--setenv DOCKER_HOST "${docker_host}")
        [[ -n "${DOCKER_CONFIG:-}" ]]    && bwrap_args+=(--setenv DOCKER_CONFIG "${DOCKER_CONFIG}")
        [[ -n "${DOCKER_CERT_PATH:-}" ]] && bwrap_args+=(--setenv DOCKER_CERT_PATH "${DOCKER_CERT_PATH}")
        [[ -d "${HOME_DIR}/.docker" ]]   && bwrap_args+=(--ro-bind "${HOME_DIR}/.docker" "${HOME_DIR}/.docker")
    fi

    # Pass through KUBECONFIG and bind ~/.kube if opted in
    if [[ "${pass_kube}" == "1" ]]; then
        [[ -n "${KUBECONFIG:-}" ]] && bwrap_args+=(--setenv KUBECONFIG "${KUBECONFIG}")
        [[ -d "${HOME_DIR}/.kube" ]] && bwrap_args+=(--ro-bind "${HOME_DIR}/.kube" "${HOME_DIR}/.kube")
    fi

    # Pass through AWS credentials/config if opted in
    if [[ "${pass_aws}" == "1" ]]; then
        [[ -d "${HOME_DIR}/.aws" ]] && bwrap_args+=(--ro-bind "${HOME_DIR}/.aws" "${HOME_DIR}/.aws")
        local _e_var _e_val
        while IFS= read -r _e_var; do
            case "${_e_var}" in
                AWS_*)
                    _e_val="${!_e_var:-}"
                    [[ -n "${_e_val}" ]] && bwrap_args+=(--setenv "${_e_var}" "${_e_val}")
                    ;;
            esac
        done < <(compgen -e 2>/dev/null || true)
    fi

    # Pass through SSH agent socket and ~/.ssh if opted in. These are two
    # independent grants (catalog/help text: "passes SSH_AUTH_SOCK AND
    # RO-grants ~/.ssh") — ~/.ssh must still be readable for direct
    # private-key/known_hosts access even when no agent socket happens to
    # be live, so it's not nested inside the socket-liveness check.
    if [[ "${pass_ssh_agent}" == "1" ]]; then
        if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
            bwrap_args+=(--bind "${SSH_AUTH_SOCK}" "${SSH_AUTH_SOCK}" --setenv SSH_AUTH_SOCK "${SSH_AUTH_SOCK}")
        fi
        [[ -d "${HOME_DIR}/.ssh" ]] && bwrap_args+=(--ro-bind "${HOME_DIR}/.ssh" "${HOME_DIR}/.ssh")
    fi

    # Pass through GitHub token env vars if opted in. Mirrors macOS's
    # AI_SANDBOX_PASS_GH handling (macos_sandbox_exec.bash, PASS_GH block).
    if [[ "${pass_gh}" == "1" ]]; then
        [[ -n "${GITHUB_TOKEN:-}" ]] && bwrap_args+=(--setenv GITHUB_TOKEN "${GITHUB_TOKEN}")
        [[ -n "${GH_TOKEN:-}" ]]     && bwrap_args+=(--setenv GH_TOKEN "${GH_TOKEN}")
    fi

    # Pass through GitLab token env vars and RO-bind glab's on-disk config if
    # opted in. Mirrors macOS's AI_SANDBOX_PASS_GITLAB handling (env vars:
    # macos_sandbox_exec.bash PASS_GITLAB block; glab-cli config bind: added
    # to claude_wrapper.sb's PASS_GITLAB block in this same change, since the
    # macOS side previously only passed the env vars and never actually
    # bound the on-disk config despite documenting that it does). Only the
    # XDG paths exist on Linux — there's no ~/Library equivalent.
    if [[ "${pass_gitlab}" == "1" ]]; then
        [[ -n "${GITLAB_TOKEN:-}" ]] && bwrap_args+=(--setenv GITLAB_TOKEN "${GITLAB_TOKEN}")
        [[ -n "${CI_JOB_TOKEN:-}" ]] && bwrap_args+=(--setenv CI_JOB_TOKEN "${CI_JOB_TOKEN}")
        [[ -d "${HOME_DIR}/.config/glab-cli" ]] && bwrap_args+=(--ro-bind "${HOME_DIR}/.config/glab-cli" "${HOME_DIR}/.config/glab-cli")
        [[ -d "${HOME_DIR}/.local/share/glab-cli" ]] && bwrap_args+=(--ro-bind "${HOME_DIR}/.local/share/glab-cli" "${HOME_DIR}/.local/share/glab-cli")
    fi

    # Pass through every OPENAI_* env var if opted in. Mirrors macOS's
    # AI_SANDBOX_PASS_OPENAI handling (macos_sandbox_exec.bash, PASS_OPENAI
    # block) — same compgen -e loop pattern as the AWS_* passthrough above.
    if [[ "${pass_openai}" == "1" ]]; then
        local _e_var _e_val
        while IFS= read -r _e_var; do
            case "${_e_var}" in
                OPENAI_*)
                    _e_val="${!_e_var:-}"
                    [[ -n "${_e_val}" ]] && bwrap_args+=(--setenv "${_e_var}" "${_e_val}")
                    ;;
            esac
        done < <(compgen -e 2>/dev/null || true)
    fi

    # Generic escape hatch: comma-separated list of additional env var names
    # to pass through. Ported verbatim (trimming + name validation) from
    # macos_sandbox_exec.bash's AI_SANDBOX_PASS_ENV handling — invalid names
    # are WARNed and skipped rather than failing the launch; missing vars
    # are silently skipped.
    if [[ -n "${pass_env_list}" ]]; then
        local _e_ifs_save="${IFS}"
        IFS=','
        # shellcheck disable=SC2206  # intentional word-splitting on commas
        local -a _e_extra=(${pass_env_list})
        IFS="${_e_ifs_save}"
        local _e_var _e_val
        for _e_var in "${_e_extra[@]}"; do
            # Trim surrounding whitespace.
            _e_var="${_e_var#"${_e_var%%[![:space:]]*}"}"
            _e_var="${_e_var%"${_e_var##*[![:space:]]}"}"
            [[ -z "${_e_var}" ]] && continue
            if [[ ! "${_e_var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                echo_log "WARNING" "[$agent_name] AI_SANDBOX_PASS_ENV: ignoring invalid var name '${_e_var}'"
                continue
            fi
            _e_val="${!_e_var:-}"
            [[ -n "${_e_val}" ]] && bwrap_args+=(--setenv "${_e_var}" "${_e_val}")
        done
    fi

    # RO-bind residual credential files/dirs not covered by a dedicated
    # PASS_* flag, if opted in. Mirrors macOS's AI_SANDBOX_ALLOW_RO_CREDENTIALS
    # handling (claude_wrapper.sb, ALLOW_RO_CREDENTIALS block) — same path
    # list, minus the macOS-only paths that have no Linux equivalent. bwrap's
    # --ro-bind works identically for files and directories, unlike SBPL's
    # literal-vs-subpath distinction, so no special-casing is needed here.
    if [[ "${allow_ro_credentials}" == "1" ]]; then
        [[ -d "${HOME_DIR}/.config/gcloud" ]] && bwrap_args+=(--ro-bind "${HOME_DIR}/.config/gcloud" "${HOME_DIR}/.config/gcloud")
        [[ -d "${HOME_DIR}/.gnupg" ]]         && bwrap_args+=(--ro-bind "${HOME_DIR}/.gnupg" "${HOME_DIR}/.gnupg")
        [[ -f "${HOME_DIR}/.netrc" ]]         && bwrap_args+=(--ro-bind "${HOME_DIR}/.netrc" "${HOME_DIR}/.netrc")
        [[ -f "${HOME_DIR}/.npmrc" ]]         && bwrap_args+=(--ro-bind "${HOME_DIR}/.npmrc" "${HOME_DIR}/.npmrc")
        [[ -f "${HOME_DIR}/.pypirc" ]]        && bwrap_args+=(--ro-bind "${HOME_DIR}/.pypirc" "${HOME_DIR}/.pypirc")
    fi

    # Downstream extension hook (see AI_WRAPPER_EXTRA_PROFILE in
    # bin/executable_claude_wrapper.bash). Fires before bwrap exec so the
    # callback can append its own --bind / --ro-bind / --setenv pairs to
    # bwrap_args. Symmetric with the Darwin hook in macos_sandbox_exec.bash.
    if declare -f _extra_sandbox_setup >/dev/null 2>&1; then
        _extra_sandbox_setup
    fi

    # Terminal injection: a seccomp filter fails ioctl(TIOCSTI) and
    # ioctl(TIOCLINUX) with EPERM, so the agent cannot push keystrokes into
    # the terminal's input queue for the shell to run after it exits. Other
    # syscalls and terminal ioctls are untouched: the controlling terminal,
    # /dev/tty, raw input, resize (SIGWINCH) and Ctrl+C keep working. The
    # filter rides alongside any the caller or hook added (bwrap applies
    # every --add-seccomp-fd program; a --seccomp FD is switched to
    # --add-seccomp-fd, its equivalent, since bwrap refuses to mix the two).
    local tty_filter="" _a
    if [[ "${allow_tiocsti}" == "1" ]]; then
        echo_log "WARNING" "[$agent_name] AI_SANDBOX_ALLOW_TIOCSTI=1: no terminal-injection filter; on kernels that still allow TIOCSTI the agent can type commands into your terminal that run after the session ends."
    else
        if ! tty_filter="$(_sandbox_tty_filter)"; then
            echo_log "ERROR" "[$agent_name] Cannot build the terminal-injection filter: ${tty_filter}"
            echo_log "ERROR" "It needs python3 and the libseccomp runtime library (e.g. libseccomp2) on the host. Install them, or set AI_SANDBOX_ALLOW_TIOCSTI=1 to launch without this protection."
            exit 1
        fi
        for _a in "${!bwrap_args[@]}"; do
            [[ "${bwrap_args[_a]}" == "--seccomp" ]] && bwrap_args[_a]="--add-seccomp-fd"
        done
    fi

    # Launch probe with the same isolation options (its own filter copy:
    # bubblewrap consumes the descriptor it reads).
    local probe_reason probe_filter_fd="" tty_filter_fd="" probe_rc=0
    local -a probe_args=("${isolation_args[@]+"${isolation_args[@]}"}")
    if [[ -n "${tty_filter}" ]]; then
        exec {probe_filter_fd}< <(printf '%b' "${tty_filter}")
        probe_args+=(--add-seccomp-fd "${probe_filter_fd}")
    fi
    probe_reason="$(_sandbox_linux_probe "${probe_args[@]+"${probe_args[@]}"}")" || probe_rc=$?
    [[ -n "${probe_filter_fd}" ]] && exec {probe_filter_fd}<&-
    if (( probe_rc != 0 )); then
        echo_log "ERROR" "[$agent_name] Sandbox launch probe failed: ${probe_reason}"
        exit 1
    fi

    # Restricted network: start the host proxy (after the probe, before the
    # filter descriptor opens, so the proxy inherits neither), bind its
    # socket and the forwarder read-only into the sandbox (connecting to a
    # socket needs no write access to the mount) and launch the client
    # through the forwarder. The proxy variables are set last, so no
    # passthrough (AI_SANDBOX_PASS_ENV, hook) can point them elsewhere.
    # Fails closed: a proxy that cannot start refuses the launch.
    local -a launch_cmd=("${command}")
    local previous_exit_trap="" sandbox_python _proxy_var
    if [[ "${allow_unrestricted_net}" != "1" ]]; then
        local net_setup_hint="Fix it, or set AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1 to share the host network without filtering."
        if ! sandbox_python="$(PATH="${_AI_SANDBOX_NET_SYSTEM_PATH}" type -P python3)"; then
            echo_log "ERROR" "[$agent_name] No python3 in ${_AI_SANDBOX_NET_SYSTEM_PATH//:/, } for the sandbox's network forwarder. ${net_setup_hint}"
            exit 1
        fi
        if [[ ! -r "${_AI_SANDBOX_NET_FORWARDER_HELPER}" ]]; then
            echo_log "ERROR" "[$agent_name] Network forwarder ${_AI_SANDBOX_NET_FORWARDER_HELPER} is missing. ${net_setup_hint}"
            exit 1
        fi
        # The proxy's private directory goes in the host runtime dir when it
        # is a normal one under /run (tmpfs, per user), else in /tmp.
        local proxy_base=/tmp
        [[ "${host_runtime_dir}" == /run/?* ]] && proxy_base="${host_runtime_dir}"
        if ! _sandbox_start_network_proxy "${proxy_base}"; then
            echo_log "ERROR" "[$agent_name] Cannot start the sandbox network proxy: ${_AI_SANDBOX_NET_PROXY_ERROR}. ${net_setup_hint}"
            exit 1
        fi
        # Stops the proxy if the shell exits or is killed (SIGHUP, SIGTERM)
        # during the session; restored after the launch below.
        _sandbox_read_own_exit_trap
        previous_exit_trap="${_AI_SANDBOX_OWN_EXIT_TRAP}"
        # shellcheck disable=SC2064  # the tag is expanded (and quoted) now
        trap "_sandbox_stop_network_proxy $(printf '%q' "${agent_name}")" EXIT
        bwrap_args+=(
            --ro-bind "${_AI_SANDBOX_NET_PROXY_DIR}/proxy.sock" "${_AI_SANDBOX_NET_DIR}/proxy.sock"
            --ro-bind "${_AI_SANDBOX_NET_FORWARDER_HELPER}" "${_AI_SANDBOX_NET_DIR}/forwarder.py"
        )
        for _proxy_var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY; do
            bwrap_args+=(--setenv "${_proxy_var}" "http://127.0.0.1:${_AI_SANDBOX_NET_PROXY_PORT}")
        done
        bwrap_args+=(--setenv no_proxy "${_AI_SANDBOX_NET_NO_PROXY}" --setenv NO_PROXY "${_AI_SANDBOX_NET_NO_PROXY}")
        launch_cmd=("${sandbox_python}" -I "${_AI_SANDBOX_NET_DIR}/forwarder.py"
            --socket "${_AI_SANDBOX_NET_DIR}/proxy.sock" --port "${_AI_SANDBOX_NET_PROXY_PORT}" -- "${command}")
    fi

    if [[ -n "${tty_filter}" ]]; then
        exec {tty_filter_fd}< <(printf '%b' "${tty_filter}")
        bwrap_args+=(--add-seccomp-fd "${tty_filter_fd}")
    fi

    # ===== EXECUTE — no more setpriv/prlimit wrapper =====

    bwrap "${bwrap_args[@]}" "${launch_cmd[@]}" "${cmd_args[@]}"

    local exit_code=$?
    [[ -n "${tty_filter_fd}" ]] && exec {tty_filter_fd}<&-
    if [[ "${allow_unrestricted_net}" != "1" ]]; then
        _sandbox_stop_network_proxy "${agent_name}"
        # Hand this shell's own EXIT trap back (none: clear ours).
        if [[ -n "${previous_exit_trap}" ]]; then
            eval "${previous_exit_trap}"
        else
            trap - EXIT
        fi
    fi

    # ===== EXIT CODE TRANSLATION & FEEDBACK =====

    if [[ ${exit_code} -eq 0 ]]; then
        return 0
    fi

    # Translate common signal exit codes
    case ${exit_code} in
        139)
            echo_log "ERROR" "[$agent_name] Segmentation fault (exit code 139)"
            echo_log "ERROR" "The process crashed. This may indicate:"
            echo_log "ERROR" "  - A bug in ${command}"
            echo_log "ERROR" "  - Incompatible sandbox environment"
            echo_log "ERROR" "  - Missing required files or libraries"
            ;;
        143)
            echo_log "ERROR" "[$agent_name] Process terminated (SIGTERM, exit code 143)"
            echo_log "ERROR" "The process was terminated, possibly due to:"
            echo_log "ERROR" "  - External termination signal"
            ;;
        127)
            echo_log "ERROR" "[$agent_name] Command not found inside sandbox (exit code 127)"
            echo_log "ERROR" "The command '${command}' could not be executed in the sandbox."
            echo_log "ERROR" "This usually means required binaries or libraries are missing from bind mounts."
            ;;
        126)
            echo_log "ERROR" "[$agent_name] Command not executable (exit code 126)"
            echo_log "ERROR" "The command '${command}' exists but cannot be executed."
            echo_log "ERROR" "Check file permissions and executable bit."
            ;;
        *)
            # For other non-zero exits, just report the code
            if [[ ${exit_code} -gt 128 ]]; then
                local signal=$((exit_code - 128))
                echo_log "ERROR" "[$agent_name] Process terminated by signal ${signal} (exit code ${exit_code})"
            else
                echo_log "ERROR" "[$agent_name] Process exited with code ${exit_code}"
            fi
            ;;
    esac

    return ${exit_code}
}

# If script is executed directly (not sourced), show usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo_log "ERROR" "This script is meant to be sourced, not executed directly."
    exit 1
fi
