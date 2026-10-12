#!/bin/bash
# Codex wrapper parity tests:
#   - _toml_basic_string escaping (round-tripped through a real TOML parser
#     when python3 >= 3.11 is available)
#   - codex orchestrate / resume / start argv, and that Claude's argv for
#     the same LIB functions is unchanged
#   - CODEX_ACCOUNT validation and binding (invalid name, missing profile,
#     default ~/.codex symlink guards)
#   - the agent-generic LIB helpers moved out of the Claude wrapper
#     (_wrapper_bind_git_common_dir, _apply_post_menu_binds), under `set -u`
#   - per-agent per-workdir presets: no cross-agent clobbering, legacy
#     shared-file fallback and precedence, clear, missing agent id
#   - end-to-end: the real codex wrapper, with a stub `codex` binary, inside
#     the real sandbox (Linux only — the account remap is bwrap-only)
#
# Each case runs in a `( ... )` subshell so lib sourcing, `exit` calls and
# WRAPPER_FLAGS mutations never leak between cases. See
# tests/test_sandbox_common.bash for the FAKE_HOME-under-real-$HOME rationale.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
REAL_HOME="${HOME}"
export HOME="${FAKE_HOME}"
export XDG_CONFIG_HOME="${FAKE_HOME}/.config"
mkdir -p "${FAKE_HOME}/work"

cleanup() { rm -rf "${FAKE_HOME}"; }
trap cleanup EXIT

OS="$(uname -s)"
NL=$'\n'

# Source the universal wrapper + an agent lib ("codex" or "claude") into
# the current (sub)shell.
_load() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/bin/ai_wrapper_data/${1}_wrapper_lib.bash"
}

# Replacement for run_sandboxed_agent: print argv one word per line.
_stub_runner() {
    run_sandboxed_agent() { printf '%s\n' "$@"; }
}

echo "== codex wrapper parity tests (${OS}) =="

# ---------------------------------------------------------------------------
echo "-- _toml_basic_string"
_toml() { ( _load codex; _toml_basic_string "${1}" ); }

assert_eq "$(_toml 'plain text')" '"plain text"' "plain text is just quoted"
assert_eq "$(_toml 'say "hi"')" '"say \"hi\""' "double quotes escaped"
assert_eq "$(_toml 'a\b')" '"a\\b"' "backslash escaped"
assert_eq "$(_toml "l1${NL}l2")" '"l1\nl2"' "newline escaped"
assert_eq "$(_toml $'t\tr\r')" '"t\tr\r"' "tab and CR escaped"
assert_eq "$(_toml $'x\x01y\x1fz\x7f')" '"x\u0001y\u001Fz\u007F"' "other controls and DEL as \\uXXXX"
assert_eq "$(_toml 'unicode → ок')" '"unicode → ок"' "non-ASCII passes through"
assert_eq "$(_toml '\"')" '"\\\""' "backslash before quote: each escaped once"

prompt_file="${REPO_ROOT}/bin/ai_wrapper_data/orchestrator-prompt.md"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
    tricky=$'multi\nline "quoted" \\back\\slash\t tab \x01 ctrl \x7f del ünï'
    for sample_name in tricky orchestrator; do
        if [[ "${sample_name}" == "tricky" ]]; then sample="${tricky}"; else sample="$(cat "${prompt_file}")"; fi
        encoded="$(_toml "${sample}")"
        decoded="$(printf 'v = %s\n' "${encoded}" | python3 -c 'import sys,tomllib; sys.stdout.write(tomllib.loads(sys.stdin.read())["v"])')"
        rc=$?
        assert_eq "${rc}" "0" "${sample_name} sample encodes to valid TOML"
        assert_eq "${decoded}" "${sample}" "${sample_name} sample round-trips through tomllib unchanged"
    done
else
    echo "  skip - python3 tomllib unavailable; TOML round-trip not checked"
fi

if command -v codex >/dev/null 2>&1; then
    enc="$(_toml "$(cat "${prompt_file}")")"
    ( cd "${FAKE_HOME}/work" && HOME="${REAL_HOME}" codex -c "developer_instructions=${enc}" --help >/dev/null 2>&1 )
    assert_eq "$?" "0" "real codex accepts -c developer_instructions=<encoded orchestrator prompt>"
    ( cd "${FAKE_HOME}/work" && HOME="${REAL_HOME}" codex resume --dangerously-bypass-approvals-and-sandbox --help >/dev/null 2>&1 )
    assert_eq "$?" "0" "real codex accepts 'resume --dangerously-bypass-approvals-and-sandbox'"
else
    echo "  skip - codex not installed; real-CLI argv acceptance not checked"
fi

# ---------------------------------------------------------------------------
echo "-- argv construction (codex)"
_codex_argv() {
    (
        _load codex; _stub_runner
        WRAPPER_FLAGS=(--bind /w /w)
        AGENT_FLAGS=(--dangerously-bypass-approvals-and-sandbox)
        ORCHESTRATOR_PROMPT="${FAKE_HOME}/prompt.md"
        printf 'line "one"\nline two\n' >"${ORCHESTRATOR_PROMPT}"
        case "${1}" in
            orchestrate) run_orchestrated_session ;;
            *) run_agent_session "${1}" ;;
        esac
    )
}
SEP="--"
assert_eq "$(_codex_argv resume)" "codex${NL}${SEP}${NL}--bind${NL}/w${NL}/w${NL}${SEP}${NL}resume${NL}--dangerously-bypass-approvals-and-sandbox" \
    "codex resume: subcommand precedes agent flags"
assert_eq "$(_codex_argv start)" "codex${NL}${SEP}${NL}--bind${NL}/w${NL}/w${NL}${SEP}${NL}--dangerously-bypass-approvals-and-sandbox" \
    "codex start: agent flags only"
out="$(_codex_argv orchestrate)"
rc=$?
assert_eq "${rc}" "0" "codex orchestrate no longer errors"
assert_eq "${out}" "codex${NL}${SEP}${NL}--bind${NL}/w${NL}/w${NL}${SEP}${NL}--dangerously-bypass-approvals-and-sandbox${NL}-c${NL}developer_instructions=\"line \\\"one\\\"\\nline two\"" \
    "codex orchestrate: -c developer_instructions=<TOML basic string>"

echo "-- argv construction (claude, unchanged)"
_claude_argv() {
    (
        _load claude; _stub_runner
        WRAPPER_FLAGS=()
        AGENT_FLAGS=(--dangerously-skip-permissions)
        ORCHESTRATOR_PROMPT="${FAKE_HOME}/prompt.md"
        printf 'P "q"\n' >"${ORCHESTRATOR_PROMPT}"
        case "${1}" in
            orchestrate) run_orchestrated_session ;;
            *) run_agent_session "${1}" ;;
        esac
    )
}
assert_eq "$(_claude_argv resume)" "claude${NL}${SEP}${NL}${SEP}${NL}--dangerously-skip-permissions${NL}--resume" \
    "claude resume: agent flags then --resume"
assert_eq "$(_claude_argv orchestrate)" "claude${NL}${SEP}${NL}${SEP}${NL}--dangerously-skip-permissions${NL}--append-system-prompt${NL}P \"q\"" \
    "claude orchestrate: --append-system-prompt <raw prompt>"

# shellcheck disable=SC2034  # globals read by run_orchestrated_session
out="$(
    _load codex; _stub_runner
    unset -f _agent_system_prompt_args; AI_SYSTEM_PROMPT_FLAG=""
    WRAPPER_FLAGS=(); AGENT_FLAGS=(x)
    ORCHESTRATOR_PROMPT="${FAKE_HOME}/prompt.md"
    run_orchestrated_session 2>&1
)"
rc=$?
assert_eq "${rc}" "1" "orchestrate still refuses when an agent has neither hook nor flag"
assert_contains "${out}" "cannot inject orchestrator prompt" "... with the explanatory error"

# ---------------------------------------------------------------------------
echo "-- CODEX_ACCOUNT binding"
# Run _bind_codex_account in a subshell; print WRAPPER_FLAGS / agent name
# on success, stderr on failure.
_bind() {
    (
        _load codex
        WRAPPER_FLAGS=()
        CODEX_ACCOUNT="${1}"
        _bind_codex_account
        printf '%s\n' "${WRAPPER_FLAGS[@]}" "NAME=${AI_WRAPPER_AGENT_NAME}"
    ) 2>&1
}

out="$(_bind 'bad/../name')"; rc=$?
assert_eq "${rc}" "1" "invalid account name rejected"
assert_contains "${out}" "Invalid CODEX_ACCOUNT" "... with validation error"

mkdir -p "${FAKE_HOME}/.codex-alt"
out="$(_bind 'missing')"; rc=$?
assert_eq "${rc}" "1" "missing profile directory is an error"
assert_contains "${out}" "Account profile directory not found: ${FAKE_HOME}/.codex-missing" "... naming the missing dir"
assert_contains "${out}" "Available profiles: alt" "... and listing existing profiles"

out="$(_bind 'alt')"; rc=$?
assert_eq "${rc}" "0" "existing named profile binds"
if [[ "${OS}" == "Darwin" ]]; then
    assert_eq "${out}" "--bind${NL}${FAKE_HOME}/.codex-alt${NL}NAME=Codex CLI [alt]" "named profile: single-arg bind on macOS"
else
    assert_eq "${out}" "--bind${NL}${FAKE_HOME}/.codex-alt${NL}${FAKE_HOME}/.codex${NL}NAME=Codex CLI [alt]" "named profile remapped to ~/.codex"
fi

out="$(_bind 'private')"; rc=$?
assert_eq "${rc}" "0" "default account binds"
created=0; [[ -d "${FAKE_HOME}/.codex" ]] && created=1
assert_eq "${created}" "1" "default ~/.codex is created when absent"
assert_eq "${out##*${NL}}" "NAME=Codex CLI" "default account keeps the plain agent name"
assert_eq "$(_bind '')" "$(_bind 'private')" "empty CODEX_ACCOUNT behaves like 'private'"

outside="$(mktemp -d)"
rm -rf "${FAKE_HOME}/.codex"
ln -s "${outside}" "${FAKE_HOME}/.codex"
out="$(_bind 'private')"; rc=$?
assert_eq "${rc}" "1" "default ~/.codex symlinked outside \$HOME is refused"
assert_contains "${out}" "symlink pointing outside" "... with symlink error"
rm -f "${FAKE_HOME}/.codex"; rmdir "${outside}"

mkdir -p "${FAKE_HOME}/codex-real"
ln -s "${FAKE_HOME}/codex-real" "${FAKE_HOME}/.codex"
out="$(_bind 'private')"; rc=$?
assert_eq "${rc}" "0" "default ~/.codex symlinked inside \$HOME is allowed"
rm -f "${FAKE_HOME}/.codex"

: >"${FAKE_HOME}/.codex"
out="$(_bind 'private')"; rc=$?
assert_eq "${rc}" "1" "default ~/.codex as a regular file is refused"
assert_contains "${out}" "not a directory" "... with non-directory error"
rm -f "${FAKE_HOME}/.codex"

assert_contains "$( _load codex; printf '%s\n' "${_AI_SETTINGS_LIST[@]}" )" "CODEX_ACCOUNT|str|private|" \
    "CODEX_ACCOUNT is in the codex settings catalog"
assert_not_contains "$( _load claude; printf '%s\n' "${_AI_SETTINGS_LIST[@]}" )" "CODEX_ACCOUNT|" \
    "CODEX_ACCOUNT is not in the claude settings catalog"

# ---------------------------------------------------------------------------
echo "-- shared LIB bind helpers (set -u)"
if command -v git >/dev/null 2>&1; then
    git_q() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
    git_q init "${FAKE_HOME}/repos/main"
    git_q -C "${FAKE_HOME}/repos/main" commit --allow-empty -m init
    git_q -C "${FAKE_HOME}/repos/main" worktree add "${FAKE_HOME}/wt" -b wt
    _gitbind() { ( set -u; cd "${1}" && _load "${2}"; WRAPPER_FLAGS=(); _wrapper_bind_git_common_dir; printf '%s\n' "${WRAPPER_FLAGS[@]}" ) 2>&1; }
    main_git="$(cd "${FAKE_HOME}/repos/main/.git" && pwd -P)"
    for agent in claude codex; do
        out="$(_gitbind "${FAKE_HOME}/wt" "${agent}")"
        assert_contains "${out}" "--bind${NL}${main_git}" "${agent}: worktree binds the shared .git RW"
        if [[ "${OS}" == "Darwin" ]]; then
            assert_contains "${out}" "--meta-bind${NL}$(cd "${FAKE_HOME}/repos" && pwd -P)" "${agent}: meta-binds intermediate dirs on macOS"
        else
            assert_not_contains "${out}" "--meta-bind" "${agent}: no meta-binds on Linux"
        fi
        assert_eq "$(_gitbind "${FAKE_HOME}/repos/main" "${agent}")" "" "${agent}: regular repo adds no bind"
        assert_eq "$(_gitbind "${FAKE_HOME}/work" "${agent}")" "" "${agent}: non-repo adds no bind"
    done
else
    echo "  skip - git not installed"
fi

mkdir -p "${FAKE_HOME}/.config/glab-cli"
out="$( set -u; _load claude; WRAPPER_FLAGS=(); AI_SANDBOX_PASS_GITLAB=1 _apply_post_menu_binds; printf '%s\n' "${WRAPPER_FLAGS[@]}" )"
assert_contains "${out}" "--ro-bind${NL}${FAKE_HOME}/.config/glab-cli" "PASS_GITLAB=1 RO-binds glab config"
out="$( set -u; _load codex; WRAPPER_FLAGS=(); AI_SANDBOX_PASS_GITLAB=0 _apply_post_menu_binds; printf '%s\n' "${WRAPPER_FLAGS[@]}" )"
assert_eq "${out}" "" "PASS_GITLAB=0 adds no glab bind"

# ---------------------------------------------------------------------------
echo "-- per-agent per-workdir presets (claude and codex in one workdir)"
if ! command -v shasum >/dev/null 2>&1; then
    shasum() { sha256sum; }   # Linux hosts without perl's shasum
fi
# Each case gets its own workdir so preset files never leak between cases.
_pdir() { mkdir -p "${FAKE_HOME}/preset-${1}" && printf '%s' "${FAKE_HOME}/preset-${1}"; }
# Print the per-agent preset path for agent $1 in dir $2.
_ppath() { ( cd "${2}" && _load "${1}" && _preset_autosave_path ); }
# Print the legacy shared preset path for dir $1.
_plegacy() { ( cd "${1}" && _load claude && _preset_legacy_path ); }
# Autoload agent $1's preset in dir $2 from a clean env; print the values.
_pload() {
    (
        cd "${2}" || exit 1
        unset CLAUDE_ACCOUNT CODEX_ACCOUNT AI_SANDBOX_PASS_AWS AI_SANDBOX_PASS_KUBE
        _load "${1}"
        unset CLAUDE_ACCOUNT CODEX_ACCOUNT   # agent libs may default these
        _preset_autoload 2>&1
        printf 'C=%s X=%s AWS=%s KUBE=%s FROM=%s\n' "${CLAUDE_ACCOUNT:-<unset>}" \
            "${CODEX_ACCOUNT:-<unset>}" "${AI_SANDBOX_PASS_AWS:-<unset>}" \
            "${AI_SANDBOX_PASS_KUBE:-<unset>}" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-<unset>}"
    )
}

# Control: a single agent round-trips its own settings.
d="$(_pdir control)"
( cd "${d}" && _load claude && CLAUDE_ACCOUNT=work AI_SANDBOX_PASS_AWS=1 _preset_autosave )
claude_path="$(_ppath claude "${d}")"
assert_eq "$(basename "${claude_path}")" "$(basename "$(_plegacy "${d}")" .env)-claude.env" "claude preset file is <hash>-claude.env"
out="$(_pload claude "${d}")"
assert_contains "${out}" "C=work X=<unset> AWS=1" "control: claude save -> claude load restores its settings"
assert_contains "${out}" "FROM=${claude_path}" "control: restored-from marker names the per-agent file"

# Both agents save different values in the same workdir; neither clobbers.
d="$(_pdir both)"
( cd "${d}" && _load claude && CLAUDE_ACCOUNT=work AI_SANDBOX_PASS_AWS=1 AI_SANDBOX_PASS_KUBE=0 _preset_autosave )
( cd "${d}" && _load codex && CODEX_ACCOUNT=alt AI_SANDBOX_PASS_AWS=0 AI_SANDBOX_PASS_KUBE=1 _preset_autosave )
claude_path="$(_ppath claude "${d}")"
codex_path="$(_ppath codex "${d}")"
assert_eq "$(basename "${codex_path}")" "$(basename "$(_plegacy "${d}")" .env)-codex.env" "codex preset file is <hash>-codex.env"
claude_file="$(cat "${claude_path}" 2>&1)"
codex_file="$(cat "${codex_path}" 2>&1)"
assert_contains "${claude_file}" "CLAUDE_ACCOUNT=work" "claude file keeps its account after codex saved"
assert_contains "${claude_file}" "AI_SANDBOX_PASS_AWS=1" "claude file keeps its shared setting after codex saved"
assert_not_contains "${claude_file}" "CODEX_ACCOUNT" "claude file holds no codex key"
assert_contains "${claude_file}" "# agent: claude" "claude file has '# agent: claude' header"
assert_contains "${claude_file}" "# workdir: $(cd "${d}" && pwd -P)" "claude file keeps the '# workdir:' header"
assert_contains "${codex_file}" "CODEX_ACCOUNT=alt" "codex file has its own account"
assert_contains "${codex_file}" "AI_SANDBOX_PASS_AWS=0" "codex file has its own shared setting"
assert_not_contains "${codex_file}" "CLAUDE_ACCOUNT" "codex file holds no claude key"
assert_contains "${codex_file}" "# agent: codex" "codex file has '# agent: codex' header"
out="$(_pload claude "${d}")"
assert_contains "${out}" "C=work X=<unset> AWS=1 KUBE=0" "claude reload after codex save restores claude's values"
assert_not_contains "${out}" "unknown setting" "claude reload emits no unknown-setting WARN"
out="$(_pload codex "${d}")"
assert_contains "${out}" "C=<unset> X=alt AWS=0 KUBE=1" "codex reload restores codex's values"

# Migration: no per-agent file yet -> load from the legacy shared file.
d="$(_pdir legacy)"
legacy_path="$(_plegacy "${d}")"
mkdir -p "$(dirname "${legacy_path}")"
printf '# workdir: %s\nCLAUDE_ACCOUNT=old\nCODEX_ACCOUNT=oldx\nAI_SANDBOX_PASS_KUBE=1\n' "${d}" >"${legacy_path}"
legacy_before="$(cat "${legacy_path}")"
out="$(_pload claude "${d}")"
assert_contains "${out}" "C=old X=<unset> AWS=<unset> KUBE=1" "claude falls back to the legacy file (codex key not exported)"
assert_contains "${out}" "FROM=${legacy_path}" "restored-from marker names the legacy file"
assert_not_contains "${out}" "unknown setting" "legacy fallback skips the other agent's key without WARN"
out="$(_pload codex "${d}")"
assert_contains "${out}" "C=<unset> X=oldx AWS=<unset> KUBE=1" "codex falls back to the same legacy file"
( cd "${d}" && _load claude && _preset_autoload 2>/dev/null && _preset_autosave )
assert_eq "$(cat "${legacy_path}" 2>&1)" "${legacy_before}" "autosave after migration leaves the legacy file untouched"
assert_contains "$(cat "$(_ppath claude "${d}")" 2>&1)" "CLAUDE_ACCOUNT=old" "migrated values land in the per-agent file"

# Precedence: per-agent file wins over legacy when both exist.
d="$(_pdir precedence)"
legacy_path="$(_plegacy "${d}")"
claude_path="$(_ppath claude "${d}")"
mkdir -p "$(dirname "${legacy_path}")"
printf 'CLAUDE_ACCOUNT=old\nAI_SANDBOX_PASS_KUBE=1\n' >"${legacy_path}"
printf 'CLAUDE_ACCOUNT=new\nAI_SANDBOX_PASS_KUBE=0\n' >"${claude_path}"
out="$(_pload claude "${d}")"
assert_contains "${out}" "C=new X=<unset> AWS=<unset> KUBE=0" "per-agent file takes precedence over legacy"
assert_contains "${out}" "FROM=${claude_path}" "restored-from marker names the per-agent file, not legacy"

# Clear: removes own file + legacy, leaves the other agent's file.
codex_path="$(_ppath codex "${d}")"
printf 'CODEX_ACCOUNT=alt\n' >"${codex_path}"
( cd "${d}" && _load claude && _preset_clear )
assert_eq "$([[ -e "${claude_path}" ]] && echo present || echo absent)" "absent" "clear removes the agent's own file"
assert_eq "$([[ -e "${legacy_path}" ]] && echo present || echo absent)" "absent" "clear removes the legacy file (no resurrection via fallback)"
assert_eq "$([[ -e "${codex_path}" ]] && echo present || echo absent)" "present" "clear leaves the other agent's file"

# Missing agent id fails loudly instead of writing a shared file.
d="$(_pdir noid)"
out="$( cd "${d}" && _load claude && AI_WRAPPER_AGENT_ID="" && _preset_autosave 2>&1; echo "rc=$?" )"
assert_contains "${out}" "ERROR: AI_WRAPPER_AGENT_ID is unset" "unset agent id: autosave reports an error"
assert_contains "${out}" "rc=1" "unset agent id: autosave returns 1"
assert_eq "$(ls -A "$(dirname "$(_plegacy "${d}")")" | grep -c "^$(basename "$(_plegacy "${d}")" .env)")" "0" "unset agent id: no preset file written"
out="$( cd "${d}" && _load claude && AI_WRAPPER_AGENT_ID="../x" && _preset_autosave_path 2>&1; echo "rc=$?" )"
assert_contains "${out}" "rc=1" "agent id with a path separator is rejected"

# ---------------------------------------------------------------------------
echo "-- end-to-end: real codex wrapper + stub codex in the sandbox"
if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    mkdir -p "${FAKE_HOME}/bin" "${FAKE_HOME}/.codex-alt"
    echo "alt-profile" >"${FAKE_HOME}/.codex-alt/marker"
    cat >"${FAKE_HOME}/bin/codex" <<'STUB'
#!/bin/bash
printf 'ARGV:%s\n' "$*"
cat "${HOME}/.codex/marker" 2>&1
STUB
    chmod +x "${FAKE_HOME}/bin/codex"
    out="$(cd "${FAKE_HOME}/work" && PATH="${FAKE_HOME}/bin:${PATH}" CODEX_ACCOUNT=alt \
        bash "${REPO_ROOT}/bin/executable_codex_wrapper.bash" exec hello </dev/null 2>&1)"
    rc=$?
    assert_eq "${rc}" "0" "wrapper launches the stub codex"
    assert_contains "${out}" "ARGV:--dangerously-bypass-approvals-and-sandbox exec hello" "non-interactive argv is AGENT_FLAGS + user args"
    assert_contains "${out}" "alt-profile" "\$HOME/.codex-alt is visible at \$HOME/.codex inside the sandbox"

    _fresh_dir="$(mktemp -d "${FAKE_HOME}/work-invalid-XXXXXX")"
    out="$(cd "${_fresh_dir}" && PATH="${FAKE_HOME}/bin:${PATH}" CODEX_ACCOUNT='x;y' \
        bash "${REPO_ROOT}/bin/executable_codex_wrapper.bash" exec hello </dev/null 2>&1)"
    rc=$?
    assert_eq "${rc}" "1" "wrapper refuses an invalid CODEX_ACCOUNT before launch"
    assert_not_contains "${out}" "ARGV:" "... and never runs codex"

    # Whole-script check of the refactored worktree bind for BOTH wrappers:
    # git inside the sandbox can only read a worktree's history if the
    # shared .git (outside WORKDIR) was bound.
    if [[ -d "${FAKE_HOME}/wt" ]]; then
        for agent in claude codex; do
            cat >"${FAKE_HOME}/bin/${agent}" <<'STUB'
#!/bin/bash
git log --format='LOG:%s' -1 2>&1
STUB
            chmod +x "${FAKE_HOME}/bin/${agent}"
            out="$(cd "${FAKE_HOME}/wt" && PATH="${FAKE_HOME}/bin:${PATH}" \
                bash "${REPO_ROOT}/bin/executable_${agent}_wrapper.bash" x </dev/null 2>&1)"
            assert_contains "${out}" "LOG:init" "${agent} wrapper: git works in a worktree inside the sandbox"
        done
    fi
else
    echo "  skip - Linux + bwrap required"
fi

tests_summary_and_exit
