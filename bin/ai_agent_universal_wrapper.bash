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
# --bind SRC / --ro-bind SRC / --meta-bind SRC.
# Callers that need to run on both OSes must branch on `uname -s` themselves
# when building BIND_FLAGS, same as executable_claude_wrapper.bash does.

function echo_log() {
    local log_level="${1}"
    shift
    echo -e "[$(date "+%F %T")] ${log_level}: $*" >&2
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

_run_sandboxed_agent_linux() {
    local agent_name="${1}"
    local command="${1}"
    shift

    # ===== PRE-FLIGHT VALIDATION =====

    # Check required commands exist
    local missing_commands=()
    for cmd in bwrap sysctl; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing_commands+=("${cmd}")
        fi
    done

    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        echo_log "ERROR" "[$agent_name] Required commands not found: ${missing_commands[*]}"
        echo_log "ERROR" "Please install: bubblewrap, util-linux (or equivalent)"
        exit 127
    fi

    # Check if user namespaces are enabled
    UNPRIVILEGED_USERNS_CLONE="$(sysctl kernel.unprivileged_userns_clone 2>/dev/null | awk -F ' = ' '{print $2}')"
    if [[ -z "${UNPRIVILEGED_USERNS_CLONE}" ]]; then
        echo_log "ERROR" "[$agent_name] Failed to check user namespace support."
        echo_log "ERROR" "Cannot read 'sysctl kernel.unprivileged_userns_clone'."
        exit 1
    elif [[ "${UNPRIVILEGED_USERNS_CLONE}" -ne 1 ]]; then
        echo_log "ERROR" "[$agent_name] User namespaces are not enabled."
        echo_log "ERROR" "Please set 'kernel.unprivileged_userns_clone = 1' in '/etc/sysctl.d/00-unpriv-ns.conf'"
        echo_log "ERROR" "and run 'sudo sysctl --system' to fix it."
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

    # Build bwrap arguments
    local -a bwrap_args=(
        --die-with-parent
        --unshare-all
        --share-net
        # Common read-only system binds
        --ro-bind /usr /usr
        --ro-bind /bin /bin
        --ro-bind /lib /lib
        --ro-bind /lib64 /lib64
        --ro-bind /etc /etc
        --ro-bind /etc/ssl /etc/ssl
        --ro-bind /etc/hosts /etc/hosts
        --ro-bind /etc/resolv.conf /etc/resolv.conf
        --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf
        # Virtual filesystems
        --tmpfs /tmp
        --tmpfs /var
        --proc /proc
        --dev /dev
        # Working directory (read-write)
        --bind "${WORKDIR}" "${WORKDIR}"
    )

    # Add default Android directory if it exists
    if [[ -d "${HOME_DIR}/Android" ]]; then
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

        # Bind Tailscale socket for read-only query access (status, ip, peers)
        # Note: write/modify permissions are enforced by the Tailscale daemon itself
        if [[ -S /run/tailscale/tailscaled.sock ]]; then
            bwrap_args+=(--bind /run/tailscale/tailscaled.sock /run/tailscale/tailscaled.sock)
        fi

        # Bind user runtime directory if it exists
        if [[ -n "${XDG_RUNTIME_DIR}" && -d "${XDG_RUNTIME_DIR}" ]]; then
            bwrap_args+=(--bind "${XDG_RUNTIME_DIR}" "${XDG_RUNTIME_DIR}")
            bwrap_args+=(--setenv XDG_RUNTIME_DIR "${XDG_RUNTIME_DIR}")
        fi
    elif [[ -d /var/run ]]; then
        bwrap_args+=(--tmpfs /var/run)

        if [[ -S /var/run/docker.sock ]]; then
            bwrap_args+=(--bind /var/run/docker.sock /var/run/docker.sock)
        fi
    fi

    # Add Docker data directories for container filesystem access
    # This allows agents to interact with running containers and their volumes
    if [[ -d /var/lib/docker ]]; then
        # Need to create parent directory structure since /var is tmpfs
        bwrap_args+=(--dir /var/lib)
        bwrap_args+=(--bind /var/lib/docker /var/lib/docker)
    fi

    # Add kind configuration directory if it exists
    if [[ -d "${HOME_DIR}/.kind" ]]; then
        bwrap_args+=(--bind "${HOME_DIR}/.kind" "${HOME_DIR}/.kind")
    fi

    # Add kubectl configuration directory if it exists
    if [[ -d "${HOME_DIR}/kind_dot_kube" ]]; then
        bwrap_args+=(--bind "${HOME_DIR}/kind_dot_kube" "${HOME_DIR}/.kube")
    fi

    # Add ~/bin directory if it exists (for kind, kubectl, and other user binaries)
    if [[ -d "${HOME_DIR}/bin" ]]; then
        bwrap_args+=(--bind "${HOME_DIR}/bin" "${HOME_DIR}/bin")
    fi

    # Add ~/bin directory if it exists (for kind, kubectl, and other user binaries)
    if [[ -d "${HOME_DIR}/.agents" ]]; then
        bwrap_args+=(--bind "${HOME_DIR}/.agents" "${HOME_DIR}/.agents")
    fi


    # Add extra bwrap flags (user-specified binds, etc.) - using validated flags
    bwrap_args+=("${validated_bwrap_flags[@]}")

    # Environment and working directory
    bwrap_args+=(
        --clearenv
        --setenv HOME "${HOME_DIR}"
        --setenv USER "${USER}"
        --setenv PATH "${HOME_DIR}/bin:/usr/bin:/usr/sbin:/bin:/sbin"
        --setenv LANG "${LANG:-en_US.UTF-8}"
        --setenv TERM "${TERM:-xterm-256color}"
        --chdir "${WORKDIR}"
    )

    # Pass through additional terminal-related variables if set (for better terminal support)
    [[ -n "${COLORTERM}" ]] && bwrap_args+=(--setenv COLORTERM "${COLORTERM}")
    [[ -n "${TERM_PROGRAM}" ]] && bwrap_args+=(--setenv TERM_PROGRAM "${TERM_PROGRAM}")

    # Pass through Docker environment variables if set
    [[ -n "${DOCKER_HOST}" ]] && bwrap_args+=(--setenv DOCKER_HOST "${DOCKER_HOST}")
    [[ -n "${DOCKER_CONFIG}" ]] && bwrap_args+=(--setenv DOCKER_CONFIG "${DOCKER_CONFIG}")
    [[ -n "${DOCKER_CERT_PATH}" ]] && bwrap_args+=(--setenv DOCKER_CERT_PATH "${DOCKER_CERT_PATH}")

    # Pass through Kubernetes/kind environment variables if set
    [[ -n "${KUBECONFIG}" ]] && bwrap_args+=(--setenv KUBECONFIG "${KUBECONFIG}")
    [[ -n "${KIND_EXPERIMENTAL_PROVIDER}" ]] && bwrap_args+=(--setenv KIND_EXPERIMENTAL_PROVIDER "${KIND_EXPERIMENTAL_PROVIDER}")

    # ===== EXECUTE — no more setpriv/prlimit wrapper =====

    bwrap "${bwrap_args[@]}" "${command}" "${cmd_args[@]}"

    local exit_code=$?

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
