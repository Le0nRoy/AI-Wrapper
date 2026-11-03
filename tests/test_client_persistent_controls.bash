#!/bin/bash
# shellcheck disable=SC2088  # "~/x" is display text in test names
# Per-client persistent controls (#48 / #87): the Claude, Codex, Copilot
# and AGY wrappers pass their settings / hooks / skills / plugins / prompt
# inventories to _wrapper_protect_client_controls after binding the
# profile RW. Covers, for each client:
#   - flag generation through the wrapper's real binder (_bind_claude_account,
#     _bind_codex_account, _copilot_bind_config_dirs, _bind_agy_account):
#     controls read-only, profile base pinned, auth / history / session state
#     left writable, named accounts covered at both paths;
#   - refusal of a symlinked control, AI_SANDBOX_ALLOW_SETTINGS=1, and the
#     trusted-maintenance exception (controls inside WORKDIR stay editable);
#   - native write-denial probes (bwrap on Linux, Seatbelt on macOS; skipped
#     when no backend is installed): control edits, replacement, creation in
#     a control dir and renames are denied; auth tokens, conversation state
#     and WORKDIR stay writable; maintenance from inside a control works.
# Core helper semantics are covered in tests/test_bind_hardening.bash.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
isolate_test_env "${FAKE_HOME}"
cleanup() { rm -rf "${FAKE_HOME}"; }
trap cleanup EXIT

OS="$(uname -s)"
NL=$'\n'
WORK="${FAKE_HOME}/work-$(uuidgen 2>/dev/null || echo "${RANDOM}${RANDOM}")"
mkdir -p "${WORK}"

echo "== client persistent controls tests (${OS}) =="

# ---------------------------------------------------------------------------
# Fixtures: every client profile gets a few controls and the mutable state
# that must stay writable.
_mk() { mkdir -p "$(dirname "${1}")" && printf '%s\n' "${2:-x}" >"${1}"; }

_fixture_claude() {
    local d="${HOME}/.claude"
    _mk "${d}/settings.json" '{}'
    _mk "${d}/CLAUDE.md"
    _mk "${d}/skills/s1/SKILL.md"
    _mk "${d}/plugins/installed_plugins.json" '{}'
    _mk "${d}/commands/c.md"
    _mk "${d}/hooks/h.sh"
    _mk "${d}/agents/a.md"
    _mk "${d}/.credentials.json" '{}'
    _mk "${d}/projects/p/session.jsonl"
    _mk "${HOME}/.claude.json" '{}'
}
_fixture_codex() {
    local d="${HOME}/.codex"
    _mk "${d}/config.toml" 'model = "x"'
    _mk "${d}/AGENTS.md"
    _mk "${d}/skills/s1/SKILL.md"
    _mk "${d}/rules/default.rules"
    _mk "${d}/prompts/p.md"
    _mk "${d}/auth.json" '{}'
    _mk "${d}/history.jsonl"
    _mk "${d}/sessions/s.jsonl"
}
_fixture_copilot() {
    local d="${HOME}/.copilot"
    _mk "${d}/config.json" '{}'
    _mk "${d}/settings.json" '{}'
    _mk "${d}/mcp-config.json" '{}'
    _mk "${d}/skills/s1/SKILL.md"
    _mk "${d}/agents/a.md"
    _mk "${d}/session-state/s.json"
    _mk "${HOME}/.config/github-copilot/config.json" '{}'
    _mk "${HOME}/.config/github-copilot/hosts.json" '{}'
    _mk "${HOME}/.local/share/copilot/logs/l.log"
}
_fixture_agy() {
    local d="${HOME}/.gemini"
    _mk "${d}/antigravity-cli/settings.json" '{}'
    _mk "${d}/antigravity-cli/antigravity-oauth-token" 'tok'
    _mk "${d}/antigravity-cli/conversations/c.db"
    _mk "${d}/antigravity-cli/brain/b/transcript.jsonl"
    _mk "${d}/config/mcp_config.json" '{}'
    _mk "${d}/config/GEMINI.md"
    _mk "${d}/config/skills/s1/SKILL.md"
    _mk "${d}/config/plugins/p/hooks.json" '{}'
}

# Per client: lib name, binder, and the paths (relative to $HOME) the
# fixture creates as controls / as mutable state.
CLIENTS="claude codex copilot agy"
_lib_of() { [[ "${1}" == "copilot" ]] && echo copilot || echo "${1}"; }
_binder_of() {
    case "${1}" in
        claude) echo _bind_claude_account ;;
        codex) echo _bind_codex_account ;;
        copilot) echo _copilot_bind_config_dirs ;;
        agy) echo _bind_agy_account ;;
    esac
}
_profile_of() {
    case "${1}" in
        claude) echo .claude ;;
        codex) echo .codex ;;
        copilot) echo .copilot ;;
        agy) echo .gemini ;;
    esac
}
# Skills dir (relative to $HOME) used for the maintenance cases.
_skills_of() {
    case "${1}" in
        agy) echo .gemini/config/skills ;;
        *) echo "$(_profile_of "${1}")/skills" ;;
    esac
}
_controls_of() {
    case "${1}" in
        claude) echo ".claude/settings.json .claude/CLAUDE.md .claude/skills .claude/plugins .claude/commands .claude/hooks .claude/agents" ;;
        codex) echo ".codex/config.toml .codex/AGENTS.md .codex/skills .codex/rules .codex/prompts" ;;
        copilot) echo ".copilot/config.json .copilot/settings.json .copilot/mcp-config.json .copilot/skills .copilot/agents .config/github-copilot/config.json" ;;
        agy) echo ".gemini/antigravity-cli/settings.json .gemini/config/mcp_config.json .gemini/config/GEMINI.md .gemini/config/skills .gemini/config/plugins" ;;
    esac
}
_mutable_of() {
    case "${1}" in
        claude) echo ".claude.json .claude/.credentials.json .claude/projects" ;;
        codex) echo ".codex/auth.json .codex/history.jsonl .codex/sessions" ;;
        copilot) echo ".copilot/session-state .config/github-copilot/hosts.json .local/share/copilot" ;;
        agy) echo ".gemini/antigravity-cli/antigravity-oauth-token .gemini/antigravity-cli/conversations .gemini/antigravity-cli/brain" ;;
    esac
}

_load() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/bin/ai_wrapper_data/${1}_wrapper_lib.bash"
}

# _flags CLIENT [OS] — run the client's binder from CWD (default WORK);
# print WRAPPER_FLAGS one word per line, then "rc=N", then stderr.
_flags() {
    local client="${1}" os="${2:-}"
    (
        cd "${CC_CWD:-${WORK}}" && _load "$(_lib_of "${client}")" || exit 99
        [[ -n "${os}" ]] && _wrapper_os="${os}"
        WRAPPER_FLAGS=()
        # The binders exit on refusal; report the flags and status either way.
        rc=0
        trap 'rc=$?; printf "%s\n" "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}" "rc=${rc}"' EXIT
        "$(_binder_of "${client}")"
    ) 2>&1
}
# _overlays_last FLAGS — "1" when no pin / bind (Linux 3-word form) comes
# after a read-only overlay on the same path or one of its ancestors:
# bwrap applies mounts in order, so such a bind would undo the overlay.
_overlays_last() {
    local -a w=()
    local line i j ro bound
    while IFS= read -r line; do w+=("${line}"); done <<<"${1}"
    for (( i = 0; i < ${#w[@]}; i++ )); do
        [[ "${w[i]}" == "--ro-bind" ]] || continue
        ro="${w[i+2]}"
        for (( j = i + 3; j < ${#w[@]}; j++ )); do
            [[ "${w[j]}" == "--bind" ]] || continue
            bound="${w[j+2]}"
            if [[ "${ro}" == "${bound}" || "${ro}" == "${bound}"/* ]]; then
                echo "0 (${w[j]} ${bound} after --ro-bind ${ro})"; return
            fi
        done
    done
    echo 1
}
# _count_line FLAGS LINE — how many words equal LINE.
_count_line() { printf '%s\n' "${1}" | grep -c -x -e "${2}"; }
_ro3() { printf -- '--ro-bind\n%s\n%s' "${1}" "${2:-${1}}"; }

_reset_home() {
    rm -rf "${HOME}/.claude" "${HOME}/.claude.json" "${HOME}/.claude-alt" "${HOME}/.claude-alt.json" \
        "${HOME}/.codex" "${HOME}/.codex-alt" "${HOME}/.copilot" "${HOME}/.config/github-copilot" \
        "${HOME}/.local/share/copilot" "${HOME}/.gemini" "${HOME}/.gemini-alt"
    unset CLAUDE_ACCOUNT CODEX_ACCOUNT AGY_ACCOUNT AI_SANDBOX_ALLOW_SETTINGS
}

# ---------------------------------------------------------------------------
echo "-- flag generation per client (Linux shape)"
for client in ${CLIENTS}; do
    _reset_home
    "_fixture_${client}"
    out="$(_flags "${client}" Linux)"
    assert_contains "${out}" "rc=0" "${client}: binder succeeds with controls present"
    # RW bind (2 words) plus the pin (2 words).
    assert_eq "$(( $(_count_line "${out}" "${HOME}/$(_profile_of "${client}")") >= 4 ))" "1" "${client}: profile base pinned on top of its RW bind"
    for rel in $(_controls_of "${client}"); do
        assert_contains "${out}" "$(_ro3 "${HOME}/${rel}")" "${client}: ~/${rel} read-only"
    done
    for rel in $(_mutable_of "${client}"); do
        assert_not_contains "${out}" "--ro-bind${NL}${HOME}/${rel}${NL}" "${client}: ~/${rel} stays writable"
    done
    assert_not_contains "${out}" "WARN" "${client}: no WARN by default"
    assert_eq "$(_overlays_last "${out}")" "1" "${client}: no RW bind or pin mounted over a read-only overlay"
done

# Profile without any control (fresh machine): base pinned, nothing RO.
for client in ${CLIENTS}; do
    _reset_home
    out="$(_flags "${client}" Linux)"
    assert_contains "${out}" "rc=0" "${client}: fresh profile still launches"
    if [[ "${client}" == "agy" ]]; then
        # _bind_agy_account syncs the managed skills into config/skills
        # first, so that is the one control present.
        assert_eq "$(_count_line "${out}" --ro-bind)" "1" "agy: fresh profile has one read-only overlay"
        assert_contains "${out}" "$(_ro3 "${HOME}/.gemini/config/skills")" "agy: ... the synced config/skills"
    else
        assert_not_contains "${out}" "--ro-bind" "${client}: fresh profile adds no read-only overlay"
    fi
done

echo "-- macOS shape (single-arg flags)"
for client in ${CLIENTS}; do
    _reset_home
    "_fixture_${client}"
    out="$(_flags "${client}" Darwin)"
    assert_contains "${out}" "rc=0" "${client} (Darwin): binder succeeds"
    assert_contains "${out}" "--pin${NL}${HOME}/$(_profile_of "${client}")${NL}" "${client} (Darwin): profile base pinned"
    for rel in $(_controls_of "${client}"); do
        assert_contains "${out}" "--ro-bind${NL}${HOME}/${rel}${NL}" "${client} (Darwin): ~/${rel} read-only"
    done
done

echo "-- named accounts (Linux): controls covered at sandbox and host path"
for client in claude codex agy; do
    _reset_home
    "_fixture_${client}"
    prof="$(_profile_of "${client}")"
    mv "${HOME}/${prof}" "${HOME}/${prof}-alt"
    case "${client}" in
        claude) export CLAUDE_ACCOUNT=alt; rel=settings.json ;;
        codex) export CODEX_ACCOUNT=alt; rel=config.toml ;;
        agy) export AGY_ACCOUNT=alt; rel=antigravity-cli/settings.json ;;
    esac
    out="$(_flags "${client}" Linux)"
    assert_contains "${out}" "rc=0" "${client} alt: binder succeeds"
    assert_contains "${out}" "$(_ro3 "${HOME}/${prof}-alt/${rel}" "${HOME}/${prof}/${rel}")" "${client} alt: ${rel} read-only at ~/${prof}"
    assert_contains "${out}" "$(_ro3 "${HOME}/${prof}-alt/${rel}")" "${client} alt: ${rel} read-only at its host path"
    unset CLAUDE_ACCOUNT CODEX_ACCOUNT AGY_ACCOUNT
done

echo "-- symlinked control refuses the launch"
for client in ${CLIENTS}; do
    _reset_home
    "_fixture_${client}"
    skills="${HOME}/$(_skills_of "${client}")"
    # Target inside $HOME so only the control check (not the profile
    # symlink guard) can refuse it.
    mkdir -p "${HOME}/elsewhere/${client}-skills"
    rm -rf "${skills}"
    ln -s "${HOME}/elsewhere/${client}-skills" "${skills}"
    out="$(_flags "${client}" Linux)"
    assert_not_contains "${out}" "rc=0" "${client}: symlinked skills dir refuses the launch"
    assert_contains "${out}" "is a symlink" "${client}: ... with an ERROR naming the cause"
    assert_not_contains "${out}" "--ro-bind${NL}${HOME}/elsewhere" "${client}: ... and never binds the link target"
done

echo "-- AI_SANDBOX_ALLOW_SETTINGS=1 leaves controls writable"
for client in ${CLIENTS}; do
    _reset_home
    "_fixture_${client}"
    out="$(AI_SANDBOX_ALLOW_SETTINGS=1 _flags "${client}" Linux)"
    assert_contains "${out}" "rc=0" "${client}: launch allowed with the switch"
    assert_not_contains "${out}" "--ro-bind" "${client}: no read-only overlay with the switch"
    assert_contains "${out}" "AI_SANDBOX_ALLOW_SETTINGS=1" "${client}: WARN names the switch"
done

echo "-- trusted maintenance: controls inside WORKDIR stay editable"
for client in ${CLIENTS}; do
    _reset_home
    "_fixture_${client}"
    prof="$(_profile_of "${client}")"
    skills="$(_skills_of "${client}")"
    # WORKDIR inside a control: that control stays writable (WARN), the
    # others are still protected.
    out="$(CC_CWD="${HOME}/${skills}/s1" _flags "${client}" Linux)"
    assert_contains "${out}" "rc=0" "${client}: WORKDIR inside skills/ launches"
    assert_not_contains "${out}" "--ro-bind${NL}${HOME}/${skills}${NL}" "${client}: WORKDIR inside skills/: skills/ writable"
    assert_contains "${out}" "WARN" "${client}: ... with a WARN"
    first="$(_controls_of "${client}")"; first="${first%% *}"
    assert_contains "${out}" "$(_ro3 "${HOME}/${first}")" "${client}: ... ~/${first} still read-only"
    # WORKDIR is the profile itself: every control inside it is editable.
    out="$(CC_CWD="${HOME}/${prof}" _flags "${client}" Linux)"
    assert_contains "${out}" "rc=0" "${client}: WORKDIR=~/${prof} launches"
    assert_not_contains "${out}" "--ro-bind${NL}${HOME}/${prof}/" "${client}: WORKDIR=~/${prof}: its controls stay editable"
done

# ---------------------------------------------------------------------------
echo "-- native write-denial probes"
native=0
if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    native=1
elif [[ "${OS}" == "Darwin" ]] && command -v sandbox-exec >/dev/null 2>&1; then
    native=1
fi

# Each argument is OP:PATH; prints WROTE:<arg> or DENIED:<arg>.
#   a = append to a file   r = replace a file (tmp + rename)
#   c = create an entry in a dir   m = rename a path away
# read -d '' rather than "$(cat <<'PROBE' ...)": bash 3.2 (macOS /bin/bash)
# misparses the case-pattern parentheses inside a command substitution.
IFS= read -r -d '' PROBE <<'PROBE' || true
ren() { perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$@"; }
for arg in "$@"; do
    op="${arg%%:*}"; p="${arg#*:}"
    case "${op}" in
        a) ( echo evil >>"$p" ) ;;
        r) ( echo evil >"$p.tmp" && ren "$p.tmp" "$p" ) ;;
        c) ( echo evil >"$p/evil-probe" ) ;;
        m) ( ren "$p" "$p.old" ) ;;
    esac >/dev/null 2>&1 && echo "WROTE:${arg}" || echo "DENIED:${arg}"
    rm -f "$p.tmp" 2>/dev/null
done
echo PROBES_DONE
PROBE

# _native CLIENT CWD PROBE_ARG... — bind with the native backend from CWD
# and run the probe in the sandbox.
_native() {
    local client="${1}" cwd="${2}"; shift 2
    (
        cd "${cwd}" && _load "$(_lib_of "${client}")" || exit 99
        WRAPPER_FLAGS=()
        "$(_binder_of "${client}")" >/dev/null 2>&1 || { echo "BINDER_FAILED"; exit 1; }
        run_sandboxed_agent /bin/sh -- "${WRAPPER_FLAGS[@]}" -- -c "${PROBE}" _ "$@"
    ) 2>&1
}

# Denied / allowed probe arguments per client.
_deny_args() {
    local h="${HOME}"
    case "${1}" in
        claude) echo "a:${h}/.claude/settings.json r:${h}/.claude/settings.json a:${h}/.claude/CLAUDE.md a:${h}/.claude/skills/s1/SKILL.md c:${h}/.claude/skills c:${h}/.claude/hooks c:${h}/.claude/commands c:${h}/.claude/plugins m:${h}/.claude/skills m:${h}/.claude/plugins m:${h}/.claude" ;;
        codex) echo "a:${h}/.codex/config.toml r:${h}/.codex/config.toml a:${h}/.codex/AGENTS.md a:${h}/.codex/skills/s1/SKILL.md c:${h}/.codex/skills c:${h}/.codex/rules c:${h}/.codex/prompts m:${h}/.codex/skills m:${h}/.codex" ;;
        copilot) echo "a:${h}/.copilot/config.json r:${h}/.copilot/settings.json a:${h}/.copilot/mcp-config.json a:${h}/.copilot/skills/s1/SKILL.md c:${h}/.copilot/agents m:${h}/.copilot/skills m:${h}/.copilot a:${h}/.config/github-copilot/config.json" ;;
        agy) echo "a:${h}/.gemini/antigravity-cli/settings.json r:${h}/.gemini/antigravity-cli/settings.json a:${h}/.gemini/config/mcp_config.json a:${h}/.gemini/config/GEMINI.md a:${h}/.gemini/config/skills/s1/SKILL.md c:${h}/.gemini/config/skills c:${h}/.gemini/config/plugins m:${h}/.gemini/config/skills m:${h}/.gemini/config m:${h}/.gemini" ;;
    esac
}
_allow_args() {
    local h="${HOME}"
    case "${1}" in
        claude) echo "a:${h}/.claude.json a:${h}/.claude/.credentials.json c:${h}/.claude/projects a:${h}/.claude/projects/p/session.jsonl c:${h}/.claude" ;;
        codex) echo "a:${h}/.codex/auth.json r:${h}/.codex/auth.json a:${h}/.codex/history.jsonl c:${h}/.codex/sessions" ;;
        copilot) echo "c:${h}/.copilot/session-state a:${h}/.config/github-copilot/hosts.json c:${h}/.local/share/copilot/logs" ;;
        agy) echo "a:${h}/.gemini/antigravity-cli/antigravity-oauth-token r:${h}/.gemini/antigravity-cli/antigravity-oauth-token c:${h}/.gemini/antigravity-cli/conversations c:${h}/.gemini/antigravity-cli/brain" ;;
    esac
}

if [[ "${native}" == "1" ]]; then
    for client in ${CLIENTS}; do
        _reset_home
        "_fixture_${client}"
        first="$(_controls_of "${client}")"; first="${HOME}/${first%% *}"
        before="$(cksum <"${first}")"
        # shellcheck disable=SC2046  # probe args are space-free by construction
        out="$(_native "${client}" "${WORK}" $(_deny_args "${client}") $(_allow_args "${client}") "c:${WORK}")"
        echo "  (${client} native probe output: ${out})"
        assert_contains "${out}" "PROBES_DONE" "${client} native: probe ran"
        for arg in $(_deny_args "${client}"); do
            assert_contains "${out}" "DENIED:${arg}" "${client} native: ${arg} denied"
        done
        for arg in $(_allow_args "${client}"); do
            assert_contains "${out}" "WROTE:${arg}" "${client} native: ${arg} allowed"
        done
        assert_contains "${out}" "WROTE:c:${WORK}" "${client} native: WORKDIR stays writable"
        assert_eq "$(cksum <"${first}")" "${before}" "${client} native: host ${first#"${HOME}/"} unchanged"
        skills="${HOME}/$(_skills_of "${client}")"
        assert_eq "$([[ -d "${skills}" && ! -e "${skills}/evil-probe" ]] && echo 1)" "1" "${client} native: host skills/ unchanged"

        # Trusted maintenance from inside a control (WORKDIR under a
        # dotfile dir needs the sensitive-WORKDIR override): the skill is
        # editable, the settings file still is not.
        _reset_home
        "_fixture_${client}"
        first="$(_controls_of "${client}")"; first="${HOME}/${first%% *}"
        out="$(AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 _native "${client}" "${skills}/s1" \
            "a:${skills}/s1/SKILL.md" "c:${skills}/s1" "a:${first}")"
        assert_contains "${out}" "WROTE:a:${skills}/s1/SKILL.md" "${client} native maintenance: skill inside WORKDIR editable"
        assert_contains "${out}" "WROTE:c:${skills}/s1" "${client} native maintenance: new file inside WORKDIR allowed"
        assert_contains "${out}" "DENIED:a:${first}" "${client} native maintenance: control outside WORKDIR still denied"

        # Maintenance switch: controls writable in the sandbox.
        out="$(AI_SANDBOX_ALLOW_SETTINGS=1 _native "${client}" "${WORK}" "a:${first}")"
        assert_contains "${out}" "WROTE:a:${first}" "${client} native: AI_SANDBOX_ALLOW_SETTINGS=1 leaves controls writable"
    done
else
    echo "  skip - native probes need bwrap (Linux) or sandbox-exec (macOS)"
fi

tests_summary_and_exit
