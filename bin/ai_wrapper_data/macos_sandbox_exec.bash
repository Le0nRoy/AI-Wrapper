#!/usr/bin/env bash
# macOS sandbox-exec (Seatbelt) backend. Sourced by ai_agent_universal_wrapper.bash's
# run_sandboxed_agent() only when uname -s == Darwin. Provides _run_sandboxed_agent_impl(),
# matching the calling convention documented in ai_agent_universal_wrapper.bash.
# Ported from a macOS-only proof-of-concept; see
# docs/plans/2026-09-04-macos-sandbox-and-wrapper-unification-context.md for provenance.

# Escape regex metacharacters in a string so it can be safely concatenated into
# an SBPL `(regex ...)` rule. Used for paths that interpolate into a regex —
# without this, a `.` in $HOME (e.g. /Users/vadim.trishin) would be a wildcard.
_regex_escape() {
    local s="${1}"
    local out=""
    local i ch
    for (( i = 0; i < ${#s}; i++ )); do
        ch="${s:$i:1}"
        case "${ch}" in
            '.'|'\'|'^'|'$'|'*'|'+'|'?'|'|'|'('|')'|'['|']'|'{'|'}')
                out+="\\${ch}"
                ;;
            *)
                out+="${ch}"
                ;;
        esac
    done
    printf '%s' "${out}"
}

_run_sandboxed_agent_impl() {
    local cmd="${1}"
    shift
    local tag="${cmd}"

    if ! command -v sandbox-exec >/dev/null 2>&1; then
        echo_log "ERROR" "[${tag}] sandbox-exec not found (macOS only)"
        return 127
    fi

    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo_log "ERROR" "[${tag}] Command not found in PATH: ${cmd}"
        return 127
    fi

    # First `--` separator is required — see the calling-convention comment at
    # the top of this file. Without it, a caller that forgot the separator
    # would silently get their CMD_ARGS parsed as BIND_FLAGS.
    if [[ "${1:-}" != "--" ]]; then
        echo_log "ERROR" "[${tag}] calling convention: '--' separator missing before bind flags (got: ${1:-<end>}). Usage: run_sandboxed_agent CMD -- [--bind SRC ...] -- [CMD_ARGS...]"
        return 2
    fi
    shift

    # Parse bind flags up to the next "--".
    # Missing sources are a hard error: silently dropping a bind means the
    # agent runs without access it was promised, which surfaces as confusing
    # failures deep inside the sandboxed command. Callers must gate optional
    # binds at the call site (e.g. `[[ -e X ]] && WRAPPER_FLAGS+=(--bind X)`).
    local -a binds_rw=() binds_ro=() binds_meta=()
    while [[ $# -gt 0 && "${1}" != "--" ]]; do
        case "${1}" in
            --bind|--ro-bind|--meta-bind)
                # Single positional SRC. sandbox-exec cannot remap paths, so
                # there's no DST. A legacy two-arg call `--bind SRC DST` would
                # now consume DST as the next flag in the loop and almost
                # certainly fail — the explicit message below catches that
                # common pattern with a clear migration hint.
                #
                # --meta-bind grants `file-read-metadata` on the literal path
                # only — stat() works, readdir() doesn't, file contents don't.
                # Used for path-traversal-only access (e.g. parent dirs of a
                # worktree's shared .git that git needs to canonicalize but
                # not actually read). Tighter than --ro-bind.
                if [[ $# -lt 2 ]]; then
                    echo_log "ERROR" "[${tag}] ${1} requires SRC (got: ${*})"
                    return 2
                fi
                # Reject '--' as a path: it's almost certainly a caller typo
                # (forgotten SRC), and silently consuming it produces a
                # confusing downstream "source missing: --" error.
                if [[ "${2}" == "--" ]]; then
                    echo_log "ERROR" "[${tag}] ${1}: '--' is not a valid path; ${1} requires a SRC argument"
                    return 2
                fi
                if [[ ! -e "${2}" ]]; then
                    echo_log "ERROR" "[${tag}] ${1} source missing: ${2}"
                    return 1
                fi
                case "${1}" in
                    --bind)      binds_rw+=("${2}") ;;
                    --ro-bind)   binds_ro+=("${2}") ;;
                    --meta-bind) binds_meta+=("${2}") ;;
                esac
                shift 2
                ;;
            *)
                # Unknown flag: error rather than warn-and-shift-1. The latter
                # re-feeds SRC tokens as flags and either spams warnings or
                # misparses the rest of the bind block. The hint about the
                # old two-arg form catches callers migrating from the
                # pre-WS1 bubblewrap-shape vocabulary.
                if [[ -e "${1}" ]]; then
                    echo_log "ERROR" "[${tag}] Unexpected path '${1}' in flag position. Hint: --bind / --ro-bind / --meta-bind are single-arg (SRC only)."
                else
                    echo_log "ERROR" "[${tag}] Unsupported sandbox flag: ${1}"
                fi
                return 2
                ;;
        esac
    done
    [[ "${1:-}" == "--" ]] && shift
    local -a cmd_args=("$@")

    local workdir; workdir="$(pwd -P)"

    # Profile selection:
    #   AI_SANDBOX_PROFILE (env)  — explicit override; absolute or relative
    #                               to the universal wrapper's directory.
    #   default                   — claude_wrapper.sb, next to this file
    # The path is canonicalized via _realpath so symlinked wrappers still find
    # the profile next to the real file. wrapper_dir already IS
    # ai_wrapper_data/ (dirname of this file, which lives there) — the
    # default used to append "ai_wrapper_data/" again on top of that,
    # producing .../ai_wrapper_data/ai_wrapper_data/claude_wrapper.sb and a
    # "Sandbox profile not found" hard failure on every launch.
    local wrapper_dir
    if ! wrapper_dir="$(_realpath "$(dirname "${BASH_SOURCE[0]}")")" || [[ -z "${wrapper_dir}" ]]; then
        echo_log "ERROR" "[${tag}] Could not resolve wrapper directory."
        return 1
    fi
    local profile_path="${AI_SANDBOX_PROFILE:-${wrapper_dir}/claude_wrapper.sb}"
    [[ "${profile_path}" != /* ]] && profile_path="${wrapper_dir}/${profile_path}"
    if [[ ! -f "${profile_path}" ]]; then
        echo_log "ERROR" "[${tag}] Sandbox profile not found: ${profile_path}"
        return 1
    fi

    # Resolve real paths so symlinks (e.g. /tmp -> /private/tmp) match sandbox rules.
    local resolved_workdir
    if ! resolved_workdir="$(_realpath "${workdir}")" || [[ -z "${resolved_workdir}" ]]; then
        echo_log "ERROR" "[${tag}] Could not resolve workdir: ${workdir}"
        return 1
    fi
    if ! _validate_sandbox_path "${resolved_workdir}"; then
        echo_log "ERROR" "[${tag}] Workdir path is unsafe for SBPL interpolation: ${resolved_workdir}"
        return 1
    fi
    # Refuse to sandbox with a WORKDIR that's a system root or $HOME itself:
    # the profile grants RW on (subpath WORKDIR), so a too-broad cwd would
    # effectively neutralise the write fence. Caller must cd into a project
    # directory first.
    case "${resolved_workdir}" in
        /|/Users|/Users/Shared|/private|/private/tmp|/private/var|/private/var/tmp|/private/var/folders|/tmp|/var|/var/tmp|/etc|/usr|/usr/local|/bin|/sbin|/System|/Applications|/Library)
            echo_log "ERROR" "[${tag}] Refusing to sandbox with WORKDIR=${resolved_workdir} (top-level or system location). cd into a project directory first."
            return 1
            ;;
    esac
    # Resolve HOME the same way we resolved WORKDIR so the comparisons below
    # survive macOS's /var → /private/var symlink (and any user-installed
    # symlinks in the HOME chain). Fall back to the raw HOME%/ when realpath
    # can't resolve — that's a degenerate case but better than silently
    # skipping the safety check.
    local resolved_home=""
    if [[ -n "${HOME:-}" ]]; then
        resolved_home="$(_realpath "${HOME}")" || resolved_home="${HOME%/}"
        resolved_home="${resolved_home%/}"
    fi
    if [[ "${AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR:-}" != "1" && -n "${resolved_home}" && "${resolved_workdir}" == "${resolved_home}" ]]; then
        echo_log "ERROR" "[${tag}] Refusing to sandbox with WORKDIR=\$HOME (${HOME}); that would grant RW on the entire home directory. cd into a subdirectory first, or set AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 to override."
        return 1
    fi
    # Refuse WORKDIRs that sit on top of well-known credential / browser-data
    # locations. The `(allow file* (subpath WORKDIR))` rule grants RW on the cwd
    # unconditionally; picking a sensitive WORKDIR write-exposes files that the
    # (default-deny) read fence would not even let the agent read. Network plus
    # RW on a bad WORKDIR is sufficient for exfiltration of anything the agent
    # itself writes there.
    # Bypass with AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 when this is intentional
    # (e.g. you're explicitly maintaining one of these directories).
    if [[ "${AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR:-}" != "1" && -n "${resolved_home}" ]]; then
        case "${resolved_workdir}" in
            "${resolved_home}"/.*|"${resolved_home}"/Library|"${resolved_home}"/Library/*)
                echo_log "ERROR" "[${tag}] Refusing to sandbox with WORKDIR=${resolved_workdir} (under HOME dotfile dir or ~/Library — granting RW here likely exposes credentials). cd into a non-sensitive project directory, or set AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 to override."
                return 1
                ;;
        esac
    fi

    # WS3 / U-E: yellow-warn when WORKDIR is a direct $HOME child that
    # isn't on the project-dir allowlist. `~/Documents/foo`, `~/Desktop`,
    # `~/Downloads` etc. are accepted (the launch-refusal above only
    # blocks dotfiles + ~/Library) but the resulting write fence is
    # broader than the user probably realizes. The interactive banner is
    # rendered by ai_wrapper_lib.bash via $AI_SANDBOX_WORKDIR_WARNING;
    # echo_log fires on every launch so non-interactive callers see it
    # too.
    # WS3 / U-E: yellow-warn heuristic. Computes whether WORKDIR is a
    # direct $HOME child outside the project-dir allowlist, sets the
    # banner env var, and logs once. Idempotent — safe to call again
    # from claude_wrapper.bash pre-menu so the banner fires on the
    # first menu render too.
    _check_workdir_breadth "${tag}" "${resolved_workdir}" "${resolved_home}"

    # Path canonicalization (realpath/_PyConfig_InitPathConfig/git worktree
    # gitdir validation) walks DOWN from / to WORKDIR, stat()ing each
    # intermediate dir. Default-deny denies stat on every dir between $HOME
    # and WORKDIR that has no explicit rule — even though the WORKDIR subpath
    # is granted file*. That breaks any tool that calls realpath() on its own
    # executable (e.g. python venv's `venv/bin/python` startup) or otherwise
    # canonicalizes paths through the WORKDIR-parent chain.
    #
    # Walk parents from WORKDIR up to (but not including) HOME and emit one
    # --meta-bind per intermediate dir. file-read-metadata grants stat() only;
    # readdir and file contents stay denied. Capped at HOME because HOME
    # itself is already in the SBPL literal-read allowlist, so the walk has
    # a known terminator.
    if [[ -n "${resolved_home}" && "${resolved_workdir}" == "${resolved_home}"/* ]]; then
        local _wd_parent="${resolved_workdir%/*}"
        while [[ -n "${_wd_parent}" \
                && "${_wd_parent}" != "${resolved_home}" \
                && "${_wd_parent}" != "/" ]]; do
            binds_meta+=("${_wd_parent}")
            _wd_parent="${_wd_parent%/*}"
        done
        unset _wd_parent
    fi

    # $HOME is interpolated into the base profile via -D HOME_DIR=…; validate
    # it the same way as every other path before it goes near SBPL. We use
    # the realpath-canonicalized form (resolved_home) so SBPL (subpath ...)
    # rules anchored at HOME match the kernel's canonical path resolution,
    # even when HOME contains a symlinked component (uncommon but possible).
    if [[ -z "${resolved_home:-}" ]] || ! _validate_sandbox_path "${resolved_home}"; then
        echo_log "ERROR" "[${tag}] HOME is unset or unsafe for SBPL interpolation: ${HOME:-<unset>}"
        return 1
    fi
    # Regex-escaped HOME for rules that interpolate it into (regex …). Without
    # this, a literal dot in $HOME (e.g. /Users/vadim.trishin) acts as a regex
    # wildcard. Use resolved_home so the regex anchors to the canonical path
    # the kernel actually compares against.
    local home_dir_re
    home_dir_re="$(_regex_escape "${resolved_home}")"
    # Invariant: _regex_escape only inserts backslashes before regex
    # metacharacters. resolved_home is validated above to contain no
    # backslashes, so stripping every '\' from home_dir_re must yield
    # resolved_home exactly. If a future change to _regex_escape ever inserts
    # other special chars (quotes, parens, semicolons), the SBPL-injection
    # guard on HOME would silently break — catch that here instead.
    if [[ "${home_dir_re//\\/}" != "${resolved_home}" ]]; then
        echo_log "ERROR" "[${tag}] _regex_escape produced unexpected characters; aborting."
        return 1
    fi

    # Resolve macOS per-user temp/cache dirs so the SBPL profile can narrow
    # /private/var/folders to *this user's* UUID subdir. getconf returns an
    # absolute path with a trailing slash; strip it for (subpath ...) literals.
    # DARWIN_USER_DIR_X is the sibling `X/` subdir (os_signpost trace data;
    # not exposed by getconf, so derived from TEMP_DIR by replacing the
    # trailing /T with /X under the same UUID).
    #
    # getconf returns the path through the /var → /private/var symlink (e.g.
    # /var/folders/<XX>/<UUID>/T/). sandbox-exec matches (subpath ...) rules
    # against the *canonical* path, so passing the un-resolved /var/...
    # form yields a rule that never matches the actual T/ writes — they
    # show up under /private/var/folders/... in the kernel's path lookups.
    # Realpath-resolve first so the rule is anchored to the canonical form.
    local darwin_user_tmp darwin_user_cache darwin_user_signpost
    darwin_user_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" || darwin_user_tmp=""
    darwin_user_cache="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)" || darwin_user_cache=""
    darwin_user_tmp="${darwin_user_tmp%/}"
    darwin_user_cache="${darwin_user_cache%/}"
    if [[ -z "${darwin_user_tmp}" || -z "${darwin_user_cache}" ]]; then
        echo_log "ERROR" "[${tag}] Could not resolve DARWIN_USER_TEMP_DIR / DARWIN_USER_CACHE_DIR via getconf."
        return 1
    fi
    local resolved_tmp resolved_cache
    if ! resolved_tmp="$(_realpath "${darwin_user_tmp}")" || [[ -z "${resolved_tmp}" ]]; then
        echo_log "ERROR" "[${tag}] Could not canonicalize DARWIN_USER_TEMP_DIR: ${darwin_user_tmp}"
        return 1
    fi
    if ! resolved_cache="$(_realpath "${darwin_user_cache}")" || [[ -z "${resolved_cache}" ]]; then
        echo_log "ERROR" "[${tag}] Could not canonicalize DARWIN_USER_CACHE_DIR: ${darwin_user_cache}"
        return 1
    fi
    darwin_user_tmp="${resolved_tmp%/}"
    darwin_user_cache="${resolved_cache%/}"
    # Derive the X/ subdir from the T/ path: same UUID directory, last
    # component replaced with X. Used for os_signpost trace data on newer
    # macOS releases. This relies on the Apple-internal layout where the
    # per-user TEMP_DIR ends in "/T" — sanity-check the suffix before
    # deriving so a future macOS layout change surfaces as a WARN + skipped
    # rule rather than a (subpath ".../T/X") rule that never matches.
    darwin_user_signpost=""
    if [[ "${darwin_user_tmp}" == */T ]]; then
        darwin_user_signpost="${darwin_user_tmp%/T}/X"
    else
        echo_log "WARN" "[${tag}] DARWIN_USER_TEMP_DIR has unexpected suffix; skipping signpost path derivation"
    fi
    # O11: validating darwin_user_signpost is belt-and-braces — the input
    # is derived from the already-validated darwin_user_tmp by suffix
    # replacement, so it cannot contain characters that darwin_user_tmp
    # didn't already pass. Kept anyway as defense-in-depth so a future
    # refactor that changes the derivation surfaces here, not in SBPL.
    if ! _validate_sandbox_path "${darwin_user_tmp}" \
        || ! _validate_sandbox_path "${darwin_user_cache}"; then
        echo_log "ERROR" "[${tag}] DARWIN_USER_{TEMP,CACHE}_DIR unsafe for SBPL interpolation."
        return 1
    fi
    if [[ -n "${darwin_user_signpost}" ]] && ! _validate_sandbox_path "${darwin_user_signpost}"; then
        echo_log "ERROR" "[${tag}] DARWIN_USER_SIGNPOST_DIR unsafe for SBPL interpolation."
        return 1
    fi

    # Read-axis widening flags. All default 0; the SBPL profile gates the
    # corresponding (allow file-read* ...) blocks on these via (when ...).
    # ALLOW_RO_HOMEDIR widens read to all of $HOME *except* credential
    # subdirs (~/.ssh, ~/.aws, ~/.kube, ...). ALLOW_RO_CREDENTIALS widens
    # read to the residual cred dirs (~/.config/gcloud, ~/.gnupg, ~/.netrc,
    # ~/.npmrc, ~/.pypirc) — the per-service dirs (~/.ssh, ~/.aws, ~/.kube,
    # ~/.docker) are gated by the matching PASS_* flag instead, so flipping
    # PASS_SSH_AGENT etc. now both passes the env var AND grants RO on the
    # companion on-disk config. Normalize any non-"1" value to "0" so a
    # typo doesn't accidentally widen.
    local allow_ro_home="${AI_SANDBOX_ALLOW_RO_HOMEDIR:-0}"
    local allow_ro_creds="${AI_SANDBOX_ALLOW_RO_CREDENTIALS:-0}"
    local pass_ssh_agent="${AI_SANDBOX_PASS_SSH_AGENT:-0}"
    local pass_aws="${AI_SANDBOX_PASS_AWS:-0}"
    local pass_kube="${AI_SANDBOX_PASS_KUBE:-0}"
    local pass_docker="${AI_SANDBOX_PASS_DOCKER:-0}"
    # PASS_GITLAB gates the glab-cli config file-read rule in claude_wrapper.sb
    # (companion to the GITLAB_TOKEN / CI_JOB_TOKEN env-scrub bucket below).
    local pass_gitlab="${AI_SANDBOX_PASS_GITLAB:-0}"
    [[ "${allow_ro_home}"   == "1" ]] || allow_ro_home=0
    [[ "${allow_ro_creds}"  == "1" ]] || allow_ro_creds=0
    [[ "${pass_ssh_agent}"  == "1" ]] || pass_ssh_agent=0
    [[ "${pass_aws}"        == "1" ]] || pass_aws=0
    [[ "${pass_kube}"       == "1" ]] || pass_kube=0
    [[ "${pass_docker}"     == "1" ]] || pass_docker=0
    [[ "${pass_gitlab}"     == "1" ]] || pass_gitlab=0

    # WS4 / S-α: localhost network block. Off by default to keep dev
    # workflows (local DBs, dev servers) working. When set, the SBPL
    # profile emits a (deny network-* (remote/local ip "localhost:*"))
    # pair that blocks both connect() and bind()-style access to the
    # loopback interface.
    local block_localhost="${AI_SANDBOX_BLOCK_LOCALHOST:-0}"
    [[ "${block_localhost}" == "1" ]] || block_localhost=0

    # ALLOW_DOCKER gates the RW bind for the Docker / Colima sockets in the
    # SBPL profile. Default "0": the agent has no access to the local Docker
    # daemon. With a running daemon, RW on the socket is a full sandbox escape
    # via `docker run -v /:/host --privileged`. Set AI_SANDBOX_ALLOW_DOCKER=1
    # to opt in when the session legitimately needs `docker` from inside the
    # sandbox. Any non-"1" value normalises to "0" so a typo doesn't silently
    # re-enable the sockets.
    local allow_docker="${AI_SANDBOX_ALLOW_DOCKER:-0}"
    [[ "${allow_docker}" == "1" ]] || allow_docker=0

    # Env scrubbing (Phase 1 of the sandbox-migration plan; closes U-A/U-B).
    # Without this, the agent inherits the parent shell's full environment,
    # including SSH_AUTH_SOCK (ssh-agent forwarding to corporate hosts),
    # AWS_*, ANTHROPIC_API_KEY, GITHUB_TOKEN, etc. The Linux upstream wrapper
    # uses bwrap's --clearenv + --setenv allowlist for the same reason; the
    # macOS equivalent is `env -i KEY=VAL... sandbox-exec ...` at exec time.
    #
    # Three buckets:
    #   1. Baseline pass-through (locale, terminal, language toolchains,
    #      git/npm config, XDG dirs). Safe for every CLI to see.
    #   2. Prefix-matched pass-through (GIT_*, npm_config_*, CLAUDE_*).
    #      Same risk class as bucket 1.
    #   3. Opt-in pass-throughs (AI_SANDBOX_PASS_*). Each gated by its own
    #      env flag; banners in ai_wrapper_lib.bash mirror the yellow/red
    #      severity convention from the RO_HOMEDIR/RO_CREDENTIALS flags.
    local -a env_allowlist=()
    local _e_var _e_val

    # Bucket 1 — baseline vars passed through if non-empty.
    local -a _e_baseline=(
        HOME USER LOGNAME SHELL PATH TMPDIR
        TERM COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION
        LANG LC_ALL LC_CTYPE LC_COLLATE LC_MESSAGES LC_MONETARY LC_NUMERIC LC_TIME LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT LC_IDENTIFICATION
        EDITOR PAGER MANPAGER MANPATH INFOPATH
        XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_RUNTIME_DIR XDG_STATE_HOME
        HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY
        NODE_OPTIONS NODE_PATH NODE_ENV
        JAVA_HOME JDK_HOME GOPATH GOROOT RUSTUP_HOME CARGO_HOME
        PYENV_ROOT PYTHONPATH PYTHONHOME
        CONDA_DEFAULT_ENV CONDA_PREFIX CONDA_PYTHON_EXE
        ANTHROPIC_BASE_URL
    )
    for _e_var in "${_e_baseline[@]}"; do
        _e_val="${!_e_var:-}"
        [[ -n "${_e_val}" ]] && env_allowlist+=("${_e_var}=${_e_val}")
    done

    # Bucket 2 — prefix-matched pass-throughs. `compgen -e` lists exported
    # var names visible to subprocesses. We re-read each value indirectly so
    # values with embedded `=` survive intact (env(1) output would round-trip
    # the first `=` only; this is bash 3.2 compatible).
    while IFS= read -r _e_var; do
        case "${_e_var}" in
            GIT_*|npm_config_*|CLAUDE_*)
                # GIT_* deny-list: each of these makes git invoke an
                # arbitrary helper binary (askpass prompt, ssh transport,
                # editor, pager, sequence editor, external diff/proxy
                # command). Allowing them defeats the sandbox: the agent
                # can set GIT_SSH_COMMAND=/path/to/its/payload and `git
                # fetch` will exec it. They are code-exec vectors, not
                # configuration knobs, and don't belong in the GIT_*
                # passthrough.
                case "${_e_var}" in
                    GIT_ASKPASS|GIT_SSH|GIT_SSH_COMMAND|GIT_PROXY_COMMAND|GIT_EDITOR|GIT_PAGER|GIT_SEQUENCE_EDITOR|GIT_EXTERNAL_DIFF)
                        continue
                        ;;
                esac
                # npm_config_* deny-list: registry credentials and basic
                # auth vehicles. The literal-named knobs below are the
                # obvious ones; npm also expresses per-registry auth as
                # `npm_config_//registry.example.com/:_authToken` (URL
                # prefix becomes part of the var name), so the whole
                # `npm_config_//...` namespace is treated as credentials.
                case "${_e_var}" in
                    npm_config_email|npm_config_username|npm_config_password|npm_config_otp|npm_config__auth)
                        continue
                        ;;
                    npm_config_//*)
                        # Registry-scoped auth tokens (npm's URL-prefixed
                        # config form for `_authToken`, `_password`,
                        # `username`, etc.). Treat the whole
                        # `npm_config_//...` namespace as credential
                        # vehicles.
                        continue
                        ;;
                esac
                # Catch-all for npm_config_* vars whose name contains
                # `authToken` (either casing — npm normalises case in
                # some paths but the env-var name is what the user sets)
                # or that end in `_auth`. Belt and braces against future
                # naming variants.
                case "${_e_var}" in
                    npm_config_*authToken*|npm_config_*authtoken*|npm_config_*_auth)
                        continue
                        ;;
                esac
                _e_val="${!_e_var:-}"
                [[ -n "${_e_val}" ]] && env_allowlist+=("${_e_var}=${_e_val}")
                ;;
        esac
    done < <(compgen -e 2>/dev/null || true)

    # Bucket 3.A — yellow-severity opt-ins. ssh-agent forwarding gives the
    # agent push-as-user capability for any host whose key is loaded; Docker
    # and Kube env knobs grant the daemon/cluster as the user.
    if [[ "${AI_SANDBOX_PASS_SSH_AGENT:-0}" == "1" && -n "${SSH_AUTH_SOCK:-}" ]]; then
        env_allowlist+=("SSH_AUTH_SOCK=${SSH_AUTH_SOCK}")
    fi
    if [[ "${AI_SANDBOX_PASS_DOCKER:-0}" == "1" ]]; then
        [[ -n "${DOCKER_HOST:-}" ]]      && env_allowlist+=("DOCKER_HOST=${DOCKER_HOST}")
        [[ -n "${DOCKER_CONFIG:-}" ]]    && env_allowlist+=("DOCKER_CONFIG=${DOCKER_CONFIG}")
        [[ -n "${DOCKER_CERT_PATH:-}" ]] && env_allowlist+=("DOCKER_CERT_PATH=${DOCKER_CERT_PATH}")
        [[ -n "${DOCKER_BUILDKIT:-}" ]]  && env_allowlist+=("DOCKER_BUILDKIT=${DOCKER_BUILDKIT}")
    fi
    if [[ "${AI_SANDBOX_PASS_KUBE:-0}" == "1" ]]; then
        [[ -n "${KUBECONFIG:-}" ]]   && env_allowlist+=("KUBECONFIG=${KUBECONFIG}")
        [[ -n "${KUBE_EDITOR:-}" ]]  && env_allowlist+=("KUBE_EDITOR=${KUBE_EDITOR}")
    fi

    # Bucket 3.B — red-severity opt-ins. These carry credentials and
    # production-write authority; users opt in only when explicitly needed.
    if [[ "${AI_SANDBOX_PASS_AWS:-0}" == "1" ]]; then
        while IFS= read -r _e_var; do
            case "${_e_var}" in
                AWS_*)
                    _e_val="${!_e_var:-}"
                    [[ -n "${_e_val}" ]] && env_allowlist+=("${_e_var}=${_e_val}")
                    ;;
            esac
        done < <(compgen -e 2>/dev/null || true)
    fi
    if [[ "${AI_SANDBOX_PASS_GH:-0}" == "1" ]]; then
        [[ -n "${GITHUB_TOKEN:-}" ]] && env_allowlist+=("GITHUB_TOKEN=${GITHUB_TOKEN}")
        [[ -n "${GH_TOKEN:-}" ]]     && env_allowlist+=("GH_TOKEN=${GH_TOKEN}")
    fi
    if [[ "${pass_gitlab}" == "1" ]]; then
        [[ -n "${GITLAB_TOKEN:-}" ]] && env_allowlist+=("GITLAB_TOKEN=${GITLAB_TOKEN}")
        [[ -n "${CI_JOB_TOKEN:-}" ]] && env_allowlist+=("CI_JOB_TOKEN=${CI_JOB_TOKEN}")
    fi
    if [[ "${AI_SANDBOX_PASS_OPENAI:-0}" == "1" ]]; then
        while IFS= read -r _e_var; do
            case "${_e_var}" in
                OPENAI_*)
                    _e_val="${!_e_var:-}"
                    [[ -n "${_e_val}" ]] && env_allowlist+=("${_e_var}=${_e_val}")
                    ;;
            esac
        done < <(compgen -e 2>/dev/null || true)
    fi
    # Generic escape hatch: comma-separated list of additional var names.
    # Whitespace stripped; missing vars silently skipped. Red banner since
    # we cannot know in advance what's being passed.
    if [[ -n "${AI_SANDBOX_PASS_ENV:-}" ]]; then
        local _e_ifs_save="${IFS}"
        IFS=','
        # shellcheck disable=SC2206  # intentional word-splitting on commas
        local -a _e_extra=(${AI_SANDBOX_PASS_ENV})
        IFS="${_e_ifs_save}"
        for _e_var in "${_e_extra[@]}"; do
            # Trim surrounding whitespace.
            _e_var="${_e_var#"${_e_var%%[![:space:]]*}"}"
            _e_var="${_e_var%"${_e_var##*[![:space:]]}"}"
            [[ -z "${_e_var}" ]] && continue
            # Defensive: skip anything that isn't a plausible env var name.
            # Linux allows just [A-Za-z_][A-Za-z0-9_]*; reject everything else
            # so a typo or injection attempt cannot smuggle a KEY=VAL=... pair.
            if [[ ! "${_e_var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                echo_log "WARN" "[${tag}] AI_SANDBOX_PASS_ENV: ignoring invalid var name '${_e_var}'"
                continue
            fi
            _e_val="${!_e_var:-}"
            [[ -n "${_e_val}" ]] && env_allowlist+=("${_e_var}=${_e_val}")
        done
    fi

    # Build the profile: base file + per-bind rules.
    # Each `resolved` path is validated before interpolation. SBPL string
    # literals don't have a portable escape syntax, so the safe move is to
    # reject paths containing characters that could break the profile or
    # inject extra rules — quotes, backslashes, parens, dollar signs,
    # semicolons, newlines, or any other control character.
    #
    # Files use `(literal …)` and directories use `(subpath …)`. Mixing the
    # two matches what the base profile does for known files (e.g. .claude.lock)
    # vs directories (e.g. Library/Caches/claude-cli-nodejs) and avoids
    # ambiguity around whether `subpath` on a regular file is intended to match.
    #
    # --ro-bind: now allowlists the path under file-read* (was no-op before the
    # S1 default-deny rewrite). Per-call binds compose with the static read
    # allowlist in claude_wrapper.sb.
    local profile; profile="$(<"${profile_path}")"

    # WS3 / U-C: sanity-check the loaded profile body. An AI_SANDBOX_PROFILE
    # override pointing at a permissive profile like
    #   (version 1) (allow default)
    # would silently nullify the sandbox. The base SBPL contract is
    # (version 1) followed by (deny default) — verify both are present
    # somewhere in the first 80 non-comment, non-blank lines. If the
    # check fails, refuse to launch unless the operator has explicitly
    # set AI_SANDBOX_PROFILE_TRUST_ME=1 (red-banner opt-out).
    #
    # The check is intentionally cheap: a string-grep against the
    # profile body, not a full SBPL parse. False positives are
    # tolerable (the operator can set TRUST_ME=1) and false negatives
    # ("profile has the right magic strings in a comment but no actual
    # rule") are caught by the kernel parser downstream.
    if [[ "${AI_SANDBOX_PROFILE_TRUST_ME:-0}" != "1" ]]; then
        local _p_signal _p_version_seen=0 _p_deny_seen=0 _p_allow_default_seen=0 _p_line _p_inspected=0
        while IFS= read -r _p_line; do
            # Strip leading whitespace.
            _p_signal="${_p_line#"${_p_line%%[![:space:]]*}"}"
            # Skip blanks and SBPL comments (`;;`).
            [[ -z "${_p_signal}" ]] && continue
            [[ "${_p_signal}" == ';'* ]] && continue
            _p_inspected=$((_p_inspected + 1))
            [[ "${_p_signal}" == '(version 1)'* ]]   && _p_version_seen=1
            [[ "${_p_signal}" == '(deny default)'* ]] && _p_deny_seen=1
            # An `(allow default)` line — anywhere in the inspected window —
            # neutralises the `(deny default)` fence that the rest of this
            # block tries to enforce. The two strings can coexist in a
            # profile that still passes the version/deny presence check, so
            # we have to actively reject this case.
            [[ "${_p_signal}" == '(allow default)'* ]] && _p_allow_default_seen=1
            # Bail early; profile is invalid if version isn't first.
            [[ ${_p_inspected} -ge 80 ]] && break
        done <<< "${profile}"
        if [[ "${_p_version_seen}" != "1" || "${_p_deny_seen}" != "1" ]]; then
            echo_log "ERROR" "[${tag}] Sandbox profile ${profile_path} lacks (version 1) and/or (deny default) in the first 80 non-comment lines. A permissive profile silently neutralizes the sandbox; refusing to launch."
            echo_log "ERROR" "[${tag}] If this profile is intentional, set AI_SANDBOX_PROFILE_TRUST_ME=1 to bypass this check. Red banner will be shown at menu launch."
            return 1
        fi
        if [[ "${_p_allow_default_seen}" == "1" ]]; then
            echo_log "ERROR" "[${tag}] Sandbox profile ${profile_path} contains an (allow default) rule in the first 80 non-comment lines. (allow default) neutralises (deny default) and leaves the sandbox fully permissive; refusing to launch."
            echo_log "ERROR" "[${tag}] If this profile is intentional, set AI_SANDBOX_PROFILE_TRUST_ME=1 to bypass this check. Red banner will be shown at menu launch."
            return 1
        fi
    fi

    # Downstream extension hook (see AI_WRAPPER_EXTRA_PROFILE in
    # bin/executable_claude_wrapper.bash). Fires before binds are baked into
    # the SBPL profile so the callback can append to binds_rw / binds_ro /
    # binds_meta and mutate env_allowlist. Runs in the outer function scope
    # (not the subshell), matching the arrays' scope.
    if declare -f _extra_sandbox_setup >/dev/null 2>&1; then
        _extra_sandbox_setup
    fi

    local extra_rules
    if [[ ${#binds_rw[@]} -gt 0 ]]; then
        extra_rules="$(_append_bind_rules "${tag}" "file*" "--bind" "${binds_rw[@]}")" || return 1
        profile+="${extra_rules}"
    fi
    if [[ ${#binds_ro[@]} -gt 0 ]]; then
        extra_rules="$(_append_bind_rules "${tag}" "file-read*" "--ro-bind" "${binds_ro[@]}")" || return 1
        profile+="${extra_rules}"
    fi
    if [[ ${#binds_meta[@]} -gt 0 ]]; then
        # file-read-metadata + force-literal: stat() works, readdir() does not
        # and file contents are not exposed. Caller uses --meta-bind to allow
        # the kernel's path canonicalization on intermediate dirs (e.g. for
        # git worktree's gitdir-line validation) without exposing siblings.
        extra_rules="$(_append_bind_rules "${tag}" "file-read-metadata" "--meta-bind" "${binds_meta[@]}" --force-literal)" || return 1
        profile+="${extra_rules}"
    fi

    # Run the sandboxed process in a subshell so locals here don't leak into
    # the caller's shell. Rlimits used to be applied here in the same subshell;
    # all rlimit enforcement was dropped (see "Deferred: rlimits" in
    # docs/plans/2026-09-04-macos-sandbox-and-wrapper-unification-context.md).
    (
        # ${#} guard preserves set -u safety on bash 3.2 (macOS default), which
        # errors when splatting a defined-but-empty array under set -u.
        # ENABLE_SIGNPOST gates the SBPL signpost (allow …) rule (WS2 / B-δ).
        # On the B7 fallback (DARWIN_USER_TEMP_DIR not ending in /T) we pass
        # "0" and skip the DARWIN_USER_SIGNPOST_DIR -D entirely. The
        # corresponding SBPL (when …) block keeps the rule from rendering,
        # so a future stricter sandbox-exec cannot choke on the unbound
        # param.
        local enable_signpost="0"
        [[ -n "${darwin_user_signpost}" ]] && enable_signpost="1"

        local -a sandbox_argv=(
            -D "HOME_DIR=${resolved_home}"
            -D "HOME_DIR_RE=${home_dir_re}"
            -D "WORKDIR=${resolved_workdir}"
            -D "DARWIN_USER_TEMP_DIR=${darwin_user_tmp}"
            -D "DARWIN_USER_CACHE_DIR=${darwin_user_cache}"
            -D "ALLOW_RO_HOMEDIR=${allow_ro_home}"
            -D "ALLOW_RO_CREDENTIALS=${allow_ro_creds}"
            -D "PASS_SSH_AGENT=${pass_ssh_agent}"
            -D "PASS_AWS=${pass_aws}"
            -D "PASS_KUBE=${pass_kube}"
            -D "PASS_DOCKER=${pass_docker}"
            -D "PASS_GITLAB=${pass_gitlab}"
            -D "ENABLE_SIGNPOST=${enable_signpost}"
            -D "BLOCK_LOCALHOST=${block_localhost}"
            -D "ALLOW_DOCKER=${allow_docker}"
        )
        if [[ "${enable_signpost}" == "1" ]]; then
            sandbox_argv+=(-D "DARWIN_USER_SIGNPOST_DIR=${darwin_user_signpost}")
        fi
        sandbox_argv+=(-p "${profile}" "${cmd}")
        [[ ${#cmd_args[@]} -gt 0 ]] && sandbox_argv+=("${cmd_args[@]}")
        # AI_SANDBOX_DRYRUN: print the resolved sandbox-exec invocation, the
        # post-scrub child environment, and the rendered SBPL profile, then
        # exit without launching. Useful for iterating on profile changes
        # from within a nested context (where sandbox-exec itself returns 71).
        # The env block prints exactly what the child will see after `env -i`,
        # so a reviewer can confirm SSH_AUTH_SOCK / AWS_* / tokens are absent
        # by default and present only under the matching AI_SANDBOX_PASS_*.
        if [[ "${AI_SANDBOX_DRYRUN:-0}" == "1" ]]; then
            printf '=== AI_SANDBOX_DRYRUN: child env (after scrub, %d entries) ===\n' "${#env_allowlist[@]}"
            local kv
            for kv in "${env_allowlist[@]}"; do
                printf '  %q\n' "${kv}"
            done
            printf '\n=== AI_SANDBOX_DRYRUN: sandbox-exec argv ===\n'
            local arg
            for arg in "${sandbox_argv[@]}"; do
                # Quote -p payload separately so the multi-line profile
                # renders intact instead of breaking the argv view.
                if [[ "${arg}" == "${profile}" ]]; then
                    printf '  <profile body, %d bytes; see below>\n' "${#profile}"
                else
                    printf '  %q\n' "${arg}"
                fi
            done
            printf '\n=== Rendered SBPL profile ===\n%s\n' "${profile}"
            exit 0
        fi
        # env -i replaces the inherited environment with the allowlist built
        # above. Without this, the sandbox's read fence is bypassed by every
        # credential-bearing env var in the parent shell (SSH_AUTH_SOCK,
        # AWS_*, *_TOKEN, etc.) — see
        # docs/plans/2026-09-04-macos-sandbox-and-wrapper-unification-context.md.
        exec env -i "${env_allowlist[@]}" sandbox-exec "${sandbox_argv[@]}"
    )
    local exit_code=$?

    case ${exit_code} in
        0)   ;;
        71)  echo_log "ERROR" "[${tag}] sandbox-exec couldn't apply policy (71). Likely causes: launched from an already-sandboxed shell (nested sandboxes are blocked on macOS), malformed SBPL, or unsupported macOS version." ;;
        126) echo_log "ERROR" "[${tag}] Command not executable (126)" ;;
        127) echo_log "ERROR" "[${tag}] Command not found inside sandbox (127); check that required binaries are reachable under allowed read paths." ;;
        130) ;;  # SIGINT from user — don't spam.
        139) echo_log "ERROR" "[${tag}] Segmentation fault (139)" ;;
        143) echo_log "ERROR" "[${tag}] Process terminated by SIGTERM (143)" ;;
        *)   [[ ${exit_code} -gt 128 ]] && echo_log "ERROR" "[${tag}] Killed by signal $((exit_code - 128)) (exit ${exit_code})" ;;
    esac
    return ${exit_code}
}

# WS3 / U-E: emit a one-line WARN and set $AI_SANDBOX_WORKDIR_WARNING
# when WORKDIR is a direct $HOME child outside the project-dir
# allowlist (Workspace/Projects/src/code/bin/work/dev/repos and the
# lowercase variants). Callable pre-menu from claude_wrapper.bash so
# the interactive banner fires on the first menu render, and again
# from _run_sandboxed_agent_impl for non-interactive callers — both
# paths set the same env var, so the call is idempotent.
#
# Args: TAG RESOLVED_WORKDIR RESOLVED_HOME
# Side effects: exports AI_SANDBOX_WORKDIR_WARNING, prints WARN once.
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

# Resolve a path canonically. macOS lacks GNU `readlink -f`; use perl as the
# fallback that ships in the base system. Returns non-zero (and prints nothing)
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

# Reject paths containing characters that would break SBPL string literals or
# allow rule injection via concatenation. SBPL has no portable escape syntax
# for these inside `"..."`, so validation is the safe move. Control characters
# (tab, CR, LF, etc.) are also rejected — paths containing them are virtually
# always typos or attacks, and accepting them adds no real-world capability.
# Also rejects glob metacharacters `[ ] * ?` so a HOME containing them does
# not weaken case-pattern matches downstream (the sensitive-WORKDIR refusal
# uses `case "${resolved_workdir}" in "${resolved_home}"/.* | ...)`, which
# would silently over/under-match if HOME contained a glob metachar).
_validate_sandbox_path() {
    local p="${1}"
    case "${p}" in
        *[\"\\\(\)\$\;\[\]\*\?[:cntrl:]]*)
            return 1
            ;;
    esac
    return 0
}

# Emit SBPL bind rules to stdout for a list of paths.
# Signature: _append_bind_rules TAG RULE_PREFIX FLAG_NAME [PATH...]
#   TAG          — log tag for error messages
#   RULE_PREFIX  — SBPL rule head (e.g. "file*", "file-read*")
#   FLAG_NAME    — CLI flag name for diagnostics (e.g. "--bind", "--ro-bind")
#   PATH...      — zero or more paths to bind
# Each path is realpath-resolved and validated for SBPL safety; bare "/" (or
# any path that collapses to empty after trailing-slash strip) is rejected to
# avoid emitting a malformed `(subpath "")` rule that would surprise the SBPL
# parser. Directories use `(subpath ...)`, files use `(literal ...)`. Output
# is concatenated by the caller; errors go to stderr and produce a non-zero
# return.
_append_bind_rules() {
    local tag="${1}" rule_prefix="${2}" flag_name="${3}"
    shift 3
    # Optional trailing flag --force-literal makes the function emit (literal …)
    # rules even for directories. Used by --meta-bind so a metadata grant on
    # a parent dir does not expand to its children.
    local force_literal=0
    local -a paths=()
    local arg
    for arg in "$@"; do
        if [[ "${arg}" == "--force-literal" ]]; then
            force_literal=1
        else
            paths+=("${arg}")
        fi
    done
    local p resolved stripped
    for p in "${paths[@]}"; do
        if ! resolved="$(_realpath "${p}")" || [[ -z "${resolved}" ]]; then
            echo_log "ERROR" "[${tag}] Could not resolve ${flag_name} path: ${p}"
            return 1
        fi
        if ! _validate_sandbox_path "${resolved}"; then
            echo_log "ERROR" "[${tag}] ${flag_name} path is unsafe for SBPL interpolation: ${resolved}"
            return 1
        fi
        stripped="${resolved%/}"
        if [[ -z "${stripped}" ]]; then
            echo_log "ERROR" "[${tag}] ${flag_name} path '${resolved}' is too broad to sandbox (would emit an empty subpath rule)."
            return 1
        fi
        if [[ "${force_literal}" == "1" || ! -d "${resolved}" ]]; then
            printf '\n(allow %s (literal "%s"))' "${rule_prefix}" "${stripped}"
        else
            printf '\n(allow %s (subpath "%s"))' "${rule_prefix}" "${stripped}"
        fi
    done
    return 0
}
