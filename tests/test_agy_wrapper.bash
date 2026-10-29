#!/bin/bash
# Antigravity CLI (agy) wrapper parity tests:
#   - agy orchestrate / resume / start argv construction
#   - AGY_ACCOUNT validation and binding (invalid name, missing profile,
#     default ~/.gemini symlink guards, credential-dir symlink refusal)
#   - read-only settings.json validation (antigravity-cli/settings.json) and
#     managed skill sync (config/skills/orchestrator-mode/SKILL.md)
#   - per-agent per-workdir presets (<hash>-agy.env isolation from claude/codex)
#   - agy-help.md OS-conditional rendering
#   - end-to-end: the real agy wrapper, with a stub `agy` binary in
#     ~/.local/bin/agy, inside the real bubblewrap sandbox (Linux)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
isolate_test_env "${FAKE_HOME}"
mkdir -p "${FAKE_HOME}/work"

cleanup() { rm -rf "${FAKE_HOME}"; }
trap cleanup EXIT

OS="$(uname -s)"
NL=$'\n'
if ! command -v shasum >/dev/null 2>&1; then
    shasum() { sha256sum; }
    export -f shasum
fi

_load() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/bin/ai_wrapper_data/${1}_wrapper_lib.bash"
}

_stub_runner() {
    run_sandboxed_agent() { printf '%s\n' "$@"; }
}

echo "== agy wrapper parity tests (${OS}) =="

# ---------------------------------------------------------------------------
echo "-- argv construction (agy)"
_agy_argv() {
    (
        _load agy; _stub_runner
        WRAPPER_FLAGS=(--bind /w /w)
        AGENT_FLAGS=(--dangerously-skip-permissions)
        ORCHESTRATOR_PROMPT="${FAKE_HOME}/prompt.md"
        printf 'Orchestrate "now"\nline two\n' >"${ORCHESTRATOR_PROMPT}"
        case "${1}" in
            orchestrate) run_orchestrated_session ;;
            *) run_agent_session "${1}" ;;
        esac
    )
}
SEP="--"
assert_eq "$(_agy_argv start)" \
    "agy${NL}${SEP}${NL}--bind${NL}/w${NL}/w${NL}${SEP}${NL}--dangerously-skip-permissions" \
    "agy start: agent flags only"
assert_eq "$(_agy_argv resume)" \
    "agy${NL}${SEP}${NL}--bind${NL}/w${NL}/w${NL}${SEP}${NL}--dangerously-skip-permissions${NL}--continue" \
    "agy resume (non-interactive default): agent flags followed by --continue"
out="$(_agy_argv orchestrate)"
rc=$?
assert_eq "${rc}" "0" "agy orchestrate succeeds"
assert_eq "${out}" \
    "agy${NL}${SEP}${NL}--bind${NL}/w${NL}/w${NL}${SEP}${NL}--dangerously-skip-permissions${NL}--prompt-interactive${NL}Orchestrate \"now\"${NL}line two" \
    "agy orchestrate: --prompt-interactive <orchestrator prompt>"

# ---------------------------------------------------------------------------
echo "-- interactive resume conversation picker (_agy_list_conversations / _agent_resume_args)"
mkdir -p "${FAKE_HOME}/.gemini/antigravity-cli/brain/33333333-cccc-dddd-eeee-ffffffffffff/.system_generated/logs"
cat >"${FAKE_HOME}/.gemini/antigravity-cli/brain/33333333-cccc-dddd-eeee-ffffffffffff/.system_generated/logs/transcript.jsonl" <<'JSONL'
{"step_index":0,"type":"USER_INPUT","created_at":"2026-10-18T03:00:00Z","content":"<USER_REQUEST>\nFallback transcript conversation\n</USER_REQUEST>"}
{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-10-18T03:05:00Z","content":"Done"}
JSONL

python3 - "${FAKE_HOME}/.gemini/antigravity-cli/conversation_summaries.db" "${FAKE_HOME}/work" <<'PY'
import json, sqlite3, sys
db_path, workdir = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db_path)
conn.execute(
    """
    CREATE TABLE conversation_summaries (
        conversation_id text PRIMARY KEY,
        title text NOT NULL DEFAULT "",
        preview text NOT NULL DEFAULT "",
        step_count integer NOT NULL DEFAULT 0,
        last_modified_time datetime NOT NULL,
        workspace_uris text NOT NULL,
        parent_conversation_id text NOT NULL DEFAULT "",
        nesting_depth integer NOT NULL DEFAULT 0
    )
    """
)
rows = [
    ("11111111-aaaa-bbbb-cccc-dddddddddddd", "Current workdir session", "preview 1", 42, "2026-10-18 04:20:00+00:00", json.dumps([f"file://{workdir}"]), "", 0),
    ("22222222-bbbb-cccc-dddd-eeeeeeeeeeee", "Other project session", "preview 2", 15, "2026-10-18 05:00:00+00:00", json.dumps(["file:///other/project"]), "", 0),
    ("99999999-sub0-sub0-sub0-subagentsub0", "Subagent child session", "sub preview", 5, "2026-10-18 06:00:00+00:00", json.dumps([f"file://{workdir}"]), "11111111-aaaa-bbbb-cccc-dddddddddddd", 1),
]
conn.executemany("INSERT INTO conversation_summaries VALUES (?, ?, ?, ?, ?, ?, ?, ?)", rows)
conn.commit()
conn.close()
PY

_pick_resume() {
    (
        cd "${FAKE_HOME}/work" || exit 1
        _load agy; _stub_runner
        WRAPPER_FLAGS=(--bind /w /w)
        AGENT_FLAGS=(--dangerously-skip-permissions)
        _AGY_ACTIVE_PROFILE_DIR="${FAKE_HOME}/.gemini"
        AGY_RESUME_PICK="${1}"
        export AGY_RESUME_PICK
        run_agent_session resume
    )
}

out="$(_pick_resume "")"; rc=$?
assert_eq "${rc}" "0" "resume picker: Enter selects top conversation for current workdir"
assert_contains "${out}" "Saved Antigravity conversations:" "resume picker: renders header"
assert_contains "${out}" "Current workdir session (42 steps) [11111111]" "resume picker: lists current workdir session first"
assert_contains "${out}" "Fallback transcript conversation (2 steps) [33333333]" "resume picker: includes brain transcript fallback"
assert_contains "${out}" "Other project session (15 steps) [project] [22222222]" "resume picker: tags other-workspace conversation"
sub_present=0
[[ "${out}" == *"Subagent child session"* ]] && sub_present=1
assert_eq "${sub_present}" "0" "resume picker: subagent child conversations excluded"
assert_eq "${out##*${NL}}" "--conversation=11111111-aaaa-bbbb-cccc-dddddddddddd" \
    "resume picker: Enter passes --conversation=<first_id>"

out="$(_pick_resume "3")"; rc=$?
assert_eq "${rc}" "0" "resume picker: numeric pick 3 succeeds"
assert_eq "${out##*${NL}}" "--conversation=22222222-bbbb-cccc-dddd-eeeeeeeeeeee" \
    "resume picker: numeric pick 3 passes --conversation=<third_id>"

out="$(_pick_resume "33333333")"; rc=$?
assert_eq "${rc}" "0" "resume picker: UUID prefix pick succeeds"
assert_eq "${out##*${NL}}" "--conversation=33333333-cccc-dddd-eeee-ffffffffffff" \
    "resume picker: UUID prefix resolves to full conversation ID"

out="$(_pick_resume "c")"; rc=$?
assert_eq "${rc}" "0" "resume picker: 'c' selects --continue"
assert_eq "${out##*${NL}}" "--continue" \
    "resume picker: 'c' passes --continue"

out="$(_pick_resume "q")"; rc=$?
assert_eq "${rc}" "1" "resume picker: 'q' cancels with non-zero status"

# Inline rename (`r 1 New title`) updates SQLite and re-renders picker before selection.
mkdir -p "${FAKE_HOME}/.gemini/antigravity-cli/brain/11111111-aaaa-bbbb-cccc-dddddddddddd"
mkdir -p "${FAKE_HOME}/.gemini/antigravity-cli/brain/99999999-sub0-sub0-sub0-subagentsub0"
out="$(_pick_resume $'r 1 Renamed Workdir Session\n1')"; rc=$?
assert_eq "${rc}" "0" "resume picker: inline rename ('r 1 <title>') then pick 1 succeeds"
assert_contains "${out}" "Renamed [11111111] -> 'Renamed Workdir Session'." "resume picker: confirms inline rename"
assert_contains "${out}" "Renamed Workdir Session (42 steps) [11111111]" "resume picker: re-renders updated title"
assert_eq "${out##*${NL}}" "--conversation=11111111-aaaa-bbbb-cccc-dddddddddddd" \
    "resume picker: launches renamed conversation"

# Prompted multi-step rename (`r` -> `2` -> `Renamed Fallback Session` -> `2`) on transcript-only session.
out="$(_pick_resume $'r\n2\nRenamed Fallback Session\n2')"; rc=$?
assert_eq "${rc}" "0" "resume picker: step-by-step rename on fallback transcript session succeeds"
assert_contains "${out}" "Renamed [33333333] -> 'Renamed Fallback Session'." "resume picker: confirms prompted rename"
assert_contains "${out}" "Renamed Fallback Session (2 steps) [33333333]" "resume picker: re-renders transcript session with new title"
assert_eq "${out##*${NL}}" "--conversation=33333333-cccc-dddd-eeee-ffffffffffff" \
    "resume picker: launches #2 after prompted rename"

# Delete cancellation ('n') leaves conversation intact.
out="$(_pick_resume $'d 3\nn\n3')"; rc=$?
assert_eq "${rc}" "0" "resume picker: declining delete confirmation keeps session"
assert_contains "${out}" "Deletion cancelled." "resume picker: reports cancelled deletion"
assert_eq "${out##*${NL}}" "--conversation=22222222-bbbb-cccc-dddd-eeeeeeeeeeee" \
    "resume picker: can still select conversation after declining delete"

# A single invalid token in a comma-separated delete list aborts the entire batch.
out="$(_pick_resume $'d 1,99\n1')"; rc=$?
assert_eq "${rc}" "0" "resume picker: invalid token in comma-separated delete aborts batch and recovers"
assert_contains "${out}" "Invalid conversation: '99'." "resume picker: reports the invalid token"
assert_eq "${out##*${NL}}" "--conversation=11111111-aaaa-bbbb-cccc-dddddddddddd" \
    "resume picker: conversation #1 was not deleted when batch had a bad token"

# Comma-separated delete confirmation ('d 1, 3' + 'y') removes multiple conversations,
# child subagents in SQLite, and brain dirs in one pass.
out="$(_pick_resume $'d 1, 3\ny\n1')"; rc=$?
assert_eq "${rc}" "0" "resume picker: comma-separated delete ('d 1, 3' + 'y') then pick 1 succeeds"
assert_contains "${out}" "Deleted 2 conversations ([11111111] [22222222])." "resume picker: confirms batch deletion"
del_brain_exists=0
[[ -e "${FAKE_HOME}/.gemini/antigravity-cli/brain/11111111-aaaa-bbbb-cccc-dddddddddddd" ]] && del_brain_exists=1
[[ -e "${FAKE_HOME}/.gemini/antigravity-cli/brain/99999999-sub0-sub0-sub0-subagentsub0" ]] && del_brain_exists=1
assert_eq "${del_brain_exists}" "0" "resume picker: deleted conversation and child subagent brain dirs removed"
assert_eq "${out##*${NL}}" "--conversation=33333333-cccc-dddd-eeee-ffffffffffff" \
    "resume picker: after deleting #1 and #3, remaining #1 is 33333333"

# Path-traversal conversation IDs are rejected by rename/delete helpers.
(
    _load agy
    _agy_rename_conversation "${FAKE_HOME}/.gemini" "../escape" "bad" 2>/dev/null
)
assert_eq "$?" "1" "_agy_rename_conversation rejects path-traversal ID"
(
    _load agy
    _agy_delete_conversation "${FAKE_HOME}/.gemini" "../escape" 2>/dev/null
)
assert_eq "$?" "1" "_agy_delete_conversation rejects path-traversal ID"

# A failed index update (corrupt/locked DB) must fail the delete and leave
# artifacts in place so the index and on-disk state stay consistent.
del_profile="${FAKE_HOME}/.gemini-delfail"
del_cid="44444444-dddd-eeee-ffff-000000000000"
mkdir -p "${del_profile}/antigravity-cli/brain/${del_cid}"
printf 'not a sqlite database' >"${del_profile}/antigravity-cli/conversation_summaries.db"
err_out="$( ( _load agy; _agy_delete_conversation "${del_profile}" "${del_cid}" ) 2>&1 )"; rc=$?
assert_eq "${rc}" "1" "_agy_delete_conversation fails when the index update fails"
assert_contains "${err_out}" "Failed to update" "... and reports the database error"
del_brain_exists=0
[[ -d "${del_profile}/antigravity-cli/brain/${del_cid}" ]] && del_brain_exists=1
assert_eq "${del_brain_exists}" "1" "... without deleting conversation artifacts"

# A database subprocess that exits nonzero without any output must still
# fail the delete before artifacts are touched.
printf 'placeholder' >"${del_profile}/antigravity-cli/conversation_summaries.db"
err_out="$( ( _load agy; python3() { cat >/dev/null; return 1; }; _agy_delete_conversation "${del_profile}" "${del_cid}" ) 2>&1 )"; rc=$?
assert_eq "${rc}" "1" "_agy_delete_conversation fails when python3 exits nonzero silently"
assert_contains "${err_out}" "python3 failed" "... and reports an actionable error"
del_brain_exists=0
[[ -d "${del_profile}/antigravity-cli/brain/${del_cid}" ]] && del_brain_exists=1
assert_eq "${del_brain_exists}" "1" "... without deleting conversation artifacts"
assert_eq "$(cat "${del_profile}/antigravity-cli/conversation_summaries.db")" "placeholder" \
    "... and leaves the database untouched"

# The SQLite busy timeout is one named setting shared by both backends.
err_out="$( ( export AGY_DB_BUSY_TIMEOUT_MS=abc; _load agy; _agy_delete_conversation "${del_profile}" "${del_cid}" ) 2>&1 )"; rc=$?
assert_eq "${rc}" "1" "_agy_delete_conversation rejects a non-integer AGY_DB_BUSY_TIMEOUT_MS"
assert_contains "${err_out}" "AGY_DB_BUSY_TIMEOUT_MS" "... and names the invalid setting"
del_brain_exists=0
[[ -d "${del_profile}/antigravity-cli/brain/${del_cid}" ]] && del_brain_exists=1
assert_eq "${del_brain_exists}" "1" "... without deleting conversation artifacts"

# A failed artifact removal is propagated instead of reported as success.
# Removal runs in the host helper (not rm), so make the artifact really
# undeletable: a read-only conversation dir with content. Root ignores
# directory permissions, so the check needs an unprivileged user.
rm -f "${del_profile}/antigravity-cli/conversation_summaries.db"
if [[ "$(id -u)" != "0" ]]; then
    : >"${del_profile}/antigravity-cli/brain/${del_cid}/artifact"
    chmod 0500 "${del_profile}/antigravity-cli/brain/${del_cid}"
    err_out="$( ( _load agy; _agy_delete_conversation "${del_profile}" "${del_cid}" ) 2>&1 )"; rc=$?
    chmod 0700 "${del_profile}/antigravity-cli/brain/${del_cid}"
    assert_eq "${rc}" "1" "_agy_delete_conversation fails when an artifact cannot be removed"
    assert_contains "${err_out}" "Failed to remove ${del_profile}/antigravity-cli/brain/${del_cid}" \
        "... and names the artifact left behind"
else
    echo "  skip - undeletable-artifact check (running as root)"
fi

# The picker reports partial batch failures instead of a blanket success.
out="$(
    cd "${FAKE_HOME}/work" || exit 1
    _load agy; _stub_runner
    _AGY_ACTIVE_PROFILE_DIR="${del_profile}"
    _agy_list_conversations() {
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "aaaaaaaa-0000-0000-0000-000000000000" "2026-10-18 01:00" 1 here "Ok" \
            "bbbbbbbb-0000-0000-0000-000000000000" "2026-10-18 02:00" 1 here "Stuck"
    }
    _agy_delete_conversation() { [[ "${2}" == aaaaaaaa-* ]]; }
    AGY_RESUME_PICK=$'d 1,2\ny\nq'
    export AGY_RESUME_PICK
    run_agent_session resume
)"
assert_contains "${out}" "Failed to delete conversation [bbbbbbbb]." "resume picker: reports the failed deletion"
assert_contains "${out}" "Deleted 1 of 2 conversations ([aaaaaaaa])." "resume picker: reports partial batch success"
assert_not_contains "${out}" "Deleted 2 conversations" "resume picker: no blanket success on partial failure"

err_out="$( ( _load agy; AI_WRAPPER_DEBUG=0 _agy_list_conversations "${FAKE_HOME}/.gemini" "${FAKE_HOME}/work" "not-an-int" ) 2>&1 )"
assert_not_contains "${err_out}" "ValueError" "_agy_list_conversations: stderr suppressed when AI_WRAPPER_DEBUG=0"
err_out="$( ( _load agy; AI_WRAPPER_DEBUG=1 _agy_list_conversations "${FAKE_HOME}/.gemini" "${FAKE_HOME}/work" "not-an-int" ) 2>&1 )"
assert_contains "${err_out}" "ValueError" "_agy_list_conversations: stderr exposed when AI_WRAPPER_DEBUG=1"

# Real-CLI flag acceptance is not checked here: tests never launch an
# installed, possibly authenticated agy (see isolate_test_env).
echo "  skip - real agy argv acceptance (manual check only; no live clients in tests)"

# ---------------------------------------------------------------------------
echo "-- AGY_ACCOUNT binding, settings validation, and skills sync"
# Write a settings.json that passes validation for the given workspaces.
_write_valid_settings() {
    local file="${1}"
    shift
    mkdir -p "$(dirname "${file}")"
    python3 -I -c 'import json,sys;print(json.dumps({"toolPermission":"always-proceed","artifactReviewPolicy":"always-proceed","allowNonWorkspaceAccess":True,"enableTerminalSandbox":False,"trustedWorkspaces":sys.argv[1:]}))' "$@" >"${file}"
}
_bind() {
    (
        cd "${FAKE_HOME}/work" || exit 1
        _load agy
        WRAPPER_FLAGS=()
        AGY_ACCOUNT="${1}"
        _bind_agy_account
        printf '%s\n' "${WRAPPER_FLAGS[@]}" "NAME=${AI_WRAPPER_AGENT_NAME}"
    ) 2>&1
}

out="$(_bind 'bad/../name')"; rc=$?
assert_eq "${rc}" "1" "invalid AGY_ACCOUNT name rejected"
assert_contains "${out}" "Invalid AGY_ACCOUNT" "... with validation error"

mkdir -p "${FAKE_HOME}/.gemini-alt/antigravity-cli"
cat >"${FAKE_HOME}/.gemini-alt/antigravity-cli/settings.json" <<'JSON'
{
  "colorScheme": "tokyo night",
  "vimInsertFirst": true,
  "toolPermission": "request-review",
  "enableTerminalSandbox": true,
  "trustedWorkspaces": ["/existing/workspace"]
}
JSON

out="$(_bind 'missing')"; rc=$?
assert_eq "${rc}" "1" "missing profile directory is an error"
assert_contains "${out}" "Account profile directory not found: ${FAKE_HOME}/.gemini-missing" "... naming the missing dir"
assert_contains "${out}" "Available profiles: alt" "... and listing existing profiles"

alt_file="${FAKE_HOME}/.gemini-alt/antigravity-cli/settings.json"
alt_before="$(cat "${alt_file}")"
out="$(_bind 'alt')"; rc=$?
assert_eq "${rc}" "1" "settings.json lacking the sandbox settings fails the bind"
assert_contains "${out}" '"toolPermission" is "request-review"; required: "always-proceed"' "... naming each wrong setting"
assert_contains "${out}" '"enableTerminalSandbox" is true; required: false' "... including the terminal sandbox"
assert_contains "${out}" "does not include the current workspace \"${FAKE_HOME}/work\"" "... and the missing workspace trust"
assert_contains "${out}" "then relaunch" "... with how to retry"
assert_eq "$(cat "${alt_file}")" "${alt_before}" "... and the wrapper never edits settings.json"

_write_valid_settings "${alt_file}" /existing/workspace "${FAKE_HOME}/work"
out="$(_bind 'alt')"; rc=$?
assert_eq "${rc}" "0" "existing named profile binds once settings.json is valid"
if [[ "${OS}" == "Darwin" ]]; then
    assert_eq "${out}" "--bind${NL}${FAKE_HOME}/.gemini-alt${NL}NAME=Antigravity CLI [alt]" "named profile: single-arg bind on macOS"
else
    assert_eq "${out}" "--bind${NL}${FAKE_HOME}/.gemini-alt${NL}${FAKE_HOME}/.gemini${NL}NAME=Antigravity CLI [alt]" "named profile remapped to ~/.gemini"
fi


skill_synced=0
[[ -f "${FAKE_HOME}/.gemini-alt/config/skills/orchestrator-mode/SKILL.md" ]] && skill_synced=1
assert_eq "${skill_synced}" "1" "orchestrator-mode skill synced into named profile's config/skills/"

# User-managed custom skill (no .setup_skills_managed marker) is never overwritten.
mkdir -p "${FAKE_HOME}/.gemini-alt/config/skills/orchestrator-mode"
rm -f "${FAKE_HOME}/.gemini-alt/config/skills/orchestrator-mode/.setup_skills_managed"
echo "custom-user-skill" >"${FAKE_HOME}/.gemini-alt/config/skills/orchestrator-mode/SKILL.md"
_bind 'alt' >/dev/null
assert_eq "$(cat "${FAKE_HOME}/.gemini-alt/config/skills/orchestrator-mode/SKILL.md")" "custom-user-skill" \
    "unmanaged skill directory is not overwritten"

out="$(_bind 'private')"; rc=$?
assert_eq "${rc}" "1" "default account without settings.json fails the bind"
assert_contains "${out}" "${FAKE_HOME}/.gemini/antigravity-cli/settings.json: does not exist" "... naming the file to create"
created=0; [[ -d "${FAKE_HOME}/.gemini" ]] && created=1
assert_eq "${created}" "1" "default ~/.gemini is created when absent"
assert_eq "$([[ -e "${FAKE_HOME}/.gemini/antigravity-cli/settings.json" ]] && echo yes || echo no)" "no" "... but settings.json is not"
_write_valid_settings "${FAKE_HOME}/.gemini/antigravity-cli/settings.json" "${FAKE_HOME}/work"
out="$(_bind 'private')"; rc=$?
assert_eq "${rc}" "0" "default account binds once settings.json is valid"
assert_eq "${out##*${NL}}" "NAME=Antigravity CLI" "default account keeps the plain agent name"
assert_eq "$(_bind '')" "$(_bind 'private')" "empty AGY_ACCOUNT behaves like 'private'"

outside="$(mktemp -d)"
rm -rf "${FAKE_HOME}/.gemini"
ln -s "${outside}" "${FAKE_HOME}/.gemini"
out="$(_bind 'private')"; rc=$?
assert_eq "${rc}" "1" "default ~/.gemini symlinked outside \$HOME is refused"
assert_contains "${out}" "symlink pointing outside" "... with symlink error"
rm -f "${FAKE_HOME}/.gemini"; rmdir "${outside}"

mkdir -p "${FAKE_HOME}/.ssh"
ln -s "${FAKE_HOME}/.ssh" "${FAKE_HOME}/.gemini"
out="$(_bind 'private')"; rc=$?
assert_eq "${rc}" "1" "default ~/.gemini symlinked to ~/.ssh is refused"
assert_contains "${out}" "credential location" "... with credential location error"
rm -f "${FAKE_HOME}/.gemini"

mkdir -p "${FAKE_HOME}/gemini-real"
_write_valid_settings "${FAKE_HOME}/gemini-real/antigravity-cli/settings.json" "${FAKE_HOME}/work"
ln -s "${FAKE_HOME}/gemini-real" "${FAKE_HOME}/.gemini"
out="$(_bind 'private')"; rc=$?
assert_eq "${rc}" "0" "default ~/.gemini symlinked inside \$HOME is allowed"
rm -f "${FAKE_HOME}/.gemini"

: >"${FAKE_HOME}/.gemini"
out="$(_bind 'private')"; rc=$?
assert_eq "${rc}" "1" "default ~/.gemini as a regular file is refused"
assert_contains "${out}" "not a directory" "... with non-directory error"
rm -f "${FAKE_HOME}/.gemini"

assert_contains "$( _load agy; printf '%s\n' "${_AI_SETTINGS_LIST[@]}" )" "AGY_ACCOUNT|str|private|" \
    "AGY_ACCOUNT is in the agy settings catalog"
assert_not_contains "$( _load claude; printf '%s\n' "${_AI_SETTINGS_LIST[@]}" )" "AGY_ACCOUNT|" \
    "AGY_ACCOUNT is not in the claude settings catalog"
assert_not_contains "$( _load codex; printf '%s\n' "${_AI_SETTINGS_LIST[@]}" )" "AGY_ACCOUNT|" \
    "AGY_ACCOUNT is not in the codex settings catalog"

# ---------------------------------------------------------------------------
echo "-- per-agent per-workdir presets (claude, codex, and agy in one workdir)"
_pdir() { mkdir -p "${FAKE_HOME}/preset-${1}" && printf '%s' "${FAKE_HOME}/preset-${1}"; }
_ppath() { ( cd "${2}" && _load "${1}" && _preset_autosave_path ); }
_plegacy() { ( cd "${1}" && _load claude && _preset_legacy_path ); }
_pload() {
    (
        cd "${2}" || exit 1
        unset CLAUDE_ACCOUNT CODEX_ACCOUNT AGY_ACCOUNT AI_SANDBOX_PASS_AWS AI_SANDBOX_PASS_KUBE
        _load "${1}"
        unset CLAUDE_ACCOUNT CODEX_ACCOUNT AGY_ACCOUNT
        _preset_autoload 2>&1
        printf 'C=%s X=%s A=%s AWS=%s KUBE=%s\n' "${CLAUDE_ACCOUNT:-<unset>}" \
            "${CODEX_ACCOUNT:-<unset>}" "${AGY_ACCOUNT:-<unset>}" \
            "${AI_SANDBOX_PASS_AWS:-<unset>}" "${AI_SANDBOX_PASS_KUBE:-<unset>}"
    )
}

d="$(_pdir multi)"
( cd "${d}" && _load claude && CLAUDE_ACCOUNT=work AI_SANDBOX_PASS_AWS=1 AI_SANDBOX_PASS_KUBE=0 _preset_autosave )
( cd "${d}" && _load codex && CODEX_ACCOUNT=alt AI_SANDBOX_PASS_AWS=0 AI_SANDBOX_PASS_KUBE=1 _preset_autosave )
( cd "${d}" && _load agy && AGY_ACCOUNT=corp AI_SANDBOX_PASS_AWS=1 AI_SANDBOX_PASS_KUBE=1 _preset_autosave )

agy_path="$(_ppath agy "${d}")"
assert_eq "$(basename "${agy_path}")" "$(basename "$(_plegacy "${d}")" .env)-agy.env" "agy preset file is <hash>-agy.env"
agy_file="$(cat "${agy_path}" 2>&1)"
assert_contains "${agy_file}" "AGY_ACCOUNT=corp" "agy file has its own account"
assert_contains "${agy_file}" "# agent: agy" "agy file has '# agent: agy' header"
assert_not_contains "${agy_file}" "CLAUDE_ACCOUNT" "agy file holds no claude key"
assert_not_contains "${agy_file}" "CODEX_ACCOUNT" "agy file holds no codex key"

out="$(_pload agy "${d}")"
assert_contains "${out}" "C=<unset> X=<unset> A=corp AWS=1 KUBE=1" "agy reload restores agy's values"
assert_not_contains "${out}" "unknown setting" "agy reload emits no unknown-setting WARN"

( cd "${d}" && _load agy && _preset_clear )
assert_eq "$([[ -e "${agy_path}" ]] && echo present || echo absent)" "absent" "clear removes agy's own file"
assert_eq "$([[ -e "$(_ppath claude "${d}")" ]] && echo present || echo absent)" "present" "clear leaves claude's file"
assert_eq "$([[ -e "$(_ppath codex "${d}")" ]] && echo present || echo absent)" "present" "clear leaves codex's file"

# ---------------------------------------------------------------------------
echo "-- agy-help.md OS-conditional rendering"
_help_dump() {
    (
        if [[ "${1}" == "darwin" ]]; then
            uname() { if [[ "${1:-}" == "-s" ]]; then echo Darwin; else command uname "$@"; fi; }
        elif [[ "${1}" == "linux" ]]; then
            uname() { if [[ "${1:-}" == "-s" ]]; then echo Linux; else command uname "$@"; fi; }
        fi
        # shellcheck source=../bin/ai_wrapper_data/ai_wrapper_lib.bash
        source "${REPO_ROOT}/bin/ai_wrapper_data/ai_wrapper_lib.bash"
        _render_os_conditional_doc "${REPO_ROOT}/bin/ai_wrapper_data/agy-help.md"
    )
}
linux_help="$(_help_dump linux)"
darwin_help="$(_help_dump darwin)"
assert_not_contains "${linux_help}" 'macOS limitation:' "macOS account-switching limitation absent on Linux"
assert_contains "${darwin_help}" 'macOS limitation:' "macOS account-switching limitation present on macOS"
assert_not_contains "${linux_help}" '<!-- os:' "no leaked marker syntax in Linux render"
assert_not_contains "${darwin_help}" '<!-- os:' "no leaked marker syntax in macOS render"

# ---------------------------------------------------------------------------
echo "-- end-to-end: real agy wrapper + stub agy in ~/.local/bin inside sandbox"
if [[ "${OS}" == "Linux" ]] && command -v bwrap >/dev/null 2>&1; then
    mkdir -p "${FAKE_HOME}/.local/bin" "${FAKE_HOME}/.gemini-alt"
    echo "alt-gemini-profile" >"${FAKE_HOME}/.gemini-alt/marker"
    _write_valid_settings "${FAKE_HOME}/.gemini-alt/antigravity-cli/settings.json" "${FAKE_HOME}/work"
    # Inside bwrap, PATH is ~/bin:<system dirs>:~/.local/bin. Without the
    # ~/bin trap, an agy in a system dir would beat the ~/.local/bin stub, so
    # the trap is only dropped when no such agy exists; otherwise the stub
    # also goes to ~/bin and ~/.local/bin resolution is reported as skipped.
    if sys_agy="$(sandbox_system_client agy)"; then
        echo "  skip - ${sys_agy} precedes ~/.local/bin on the sandbox PATH; ~/.local/bin resolution not checked"
    else
        rm -f "${FAKE_HOME}/bin/agy"
    fi
    _sync_agy_stub() {
        chmod +x "${FAKE_HOME}/.local/bin/agy"
        if [[ -n "${sys_agy}" ]]; then cp "${FAKE_HOME}/.local/bin/agy" "${FAKE_HOME}/bin/agy"; fi
    }
    cat >"${FAKE_HOME}/.local/bin/agy" <<'STUB'
#!/bin/bash
printf 'ARGV:%s\n' "$*"
cat "${HOME}/.gemini/marker" 2>&1
[[ -f "${HOME}/.gemini/antigravity-cli/settings.json" ]] && echo "SETTINGS_OK"
[[ -f "${HOME}/.gemini/config/skills/orchestrator-mode/SKILL.md" ]] && echo "SKILL_OK"
STUB
    _sync_agy_stub
    # Host-side launches put ~/.local/bin first, so check resolution on
    # that same PATH (the ~/bin trap may have been removed above).
    agy_path="${FAKE_HOME}/.local/bin:${PATH}"
    PATH="${agy_path}" assert_client_is_fake agy

    out="$(cd "${FAKE_HOME}/work" && PATH="${agy_path}" AGY_ACCOUNT=alt \
        bash "${REPO_ROOT}/bin/executable_agy_wrapper.bash" chat hello </dev/null 2>&1)"
    rc=$?
    assert_eq "${rc}" "0" "wrapper launches stub agy from ~/.local/bin inside sandbox"
    assert_contains "${out}" "ARGV:--dangerously-skip-permissions chat hello" "non-interactive argv is AGENT_FLAGS + user args"
    assert_contains "${out}" "alt-gemini-profile" "\$HOME/.gemini-alt is visible at \$HOME/.gemini inside the sandbox"
    assert_contains "${out}" "SETTINGS_OK" "antigravity-cli/settings.json is visible inside the sandbox"
    assert_contains "${out}" "SKILL_OK" "orchestrator-mode skill is visible inside the sandbox"

    _fresh_dir="$(mktemp -d "${FAKE_HOME}/work-invalid-XXXXXX")"
    out="$(cd "${_fresh_dir}" && PATH="${agy_path}" AGY_ACCOUNT='x;y' \
        bash "${REPO_ROOT}/bin/executable_agy_wrapper.bash" chat hello </dev/null 2>&1)"
    rc=$?
    assert_eq "${rc}" "1" "wrapper refuses an invalid AGY_ACCOUNT before launch"
    assert_not_contains "${out}" "ARGV:" "... and never runs agy"

    if command -v git >/dev/null 2>&1; then
        git_q() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
        git_q init "${FAKE_HOME}/repos/main"
        git_q -C "${FAKE_HOME}/repos/main" commit --allow-empty -m init
        git_q -C "${FAKE_HOME}/repos/main" worktree add "${FAKE_HOME}/wt" -b wt
        _write_valid_settings "${FAKE_HOME}/.gemini/antigravity-cli/settings.json" "${FAKE_HOME}/wt"
        cat >"${FAKE_HOME}/.local/bin/agy" <<'STUB'
#!/bin/bash
git log --format='LOG:%s' -1 2>&1
STUB
        _sync_agy_stub
        out="$(cd "${FAKE_HOME}/wt" && PATH="${agy_path}" \
            bash "${REPO_ROOT}/bin/executable_agy_wrapper.bash" x </dev/null 2>&1)"
        assert_contains "${out}" "LOG:init" "agy wrapper: git works in a worktree inside the sandbox"
    fi
else
    echo "  skip - Linux + bwrap required"
fi

assert_no_live_client_reached
tests_summary_and_exit
