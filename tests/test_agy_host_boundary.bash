#!/bin/bash
# Host-side boundary tests for the agy wrapper (#44). Everything here runs on
# the host BEFORE the OS sandbox exists, against synthetic state in a fake
# HOME (no real profiles, credentials or conversations):
#   - checkout import shadowing (json.py, sqlite3.py, ...) never executes
#   - conversation list/rename/delete stay inside the resolved profile:
#     symlinked antigravity-cli/brain/conversations ancestors, database and
#     title file are refused; symlinked artifact leaves are unlinked only;
#     missing databases are never created
#   - settings.json is validated read-only: success and every failure leave
#     the file, an approved symlink target and their parents unchanged;
#     missing files/dirs are never created; failures say what to change; a
#     symlinked settings.json is read only through the approved
#     profile+target pair
#   - rename stays available: it changes the displayed title and reports
#     lock/permission/conflict failures before touching the index
#   - deterministic race injection (path swaps, concurrent writers) by
#     monkeypatching os/sqlite3 calls around the embedded helper
#   - python3-less hosts fail closed (no jq/sqlite3 fallback)
# Runs on Linux and macOS (bash 3.2 compatible); no sandbox launch.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
isolate_test_env "${FAKE_HOME}"
OUTSIDE_HOME="$(mktemp -d)"
OUTSIDE_HOME="$(cd "${OUTSIDE_HOME}" && pwd -P)"
cleanup() { chmod -R u+rwx "${FAKE_HOME}" 2>/dev/null; rm -rf "${FAKE_HOME}" "${OUTSIDE_HOME}"; }
trap cleanup EXIT

LIB="${REPO_ROOT}/bin/ai_wrapper_data/agy_wrapper_lib.bash"
WORK="${FAKE_HOME}/work"
mkdir -p "${WORK}"
if ! command -v shasum >/dev/null 2>&1; then
    shasum() { sha256sum; }
    export -f shasum
fi

echo "== agy host-side boundary tests ($(uname -s)) =="
if ! command -v python3 >/dev/null 2>&1; then
    echo "  skip - python3 required"
    tests_summary_and_exit
fi

_load() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=../bin/ai_wrapper_data/agy_wrapper_lib.bash
    source "${LIB}"
}

# Fingerprint a path (content hash, or the link target for symlinks).
_fp() {
    if [[ -L "${1}" ]]; then printf 'link:%s' "$(readlink "${1}")"
    elif [[ -f "${1}" ]]; then shasum -a 256 <"${1}" | cut -c1-64
    elif [[ -d "${1}" ]]; then printf 'dir:'; (cd "${1}" && find . | LC_ALL=C sort | tr '\n' ' ')
    else printf 'absent'; fi
}
_mode() { python3 -I -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "${1}"; }
_is() { if "$@"; then echo yes; else echo no; fi; }
# Metadata that any create/rewrite/chmod/replace would change: inode, mode,
# mtime (for a directory, mtime changes when an entry is added or renamed).
_meta() { python3 -I -c 'import os,sys;st=os.stat(sys.argv[1]);print(st.st_ino,oct(st.st_mode),st.st_mtime_ns)' "${1}"; }
# Settings JSON that passes validation for the workspaces given as args.
_valid_settings() {
    python3 -I -c 'import json,sys;print(json.dumps({"colorScheme":"dark","toolPermission":"always-proceed","artifactReviewPolicy":"always-proceed","allowNonWorkspaceAccess":True,"enableTerminalSandbox":False,"trustedWorkspaces":sys.argv[1:]}))' "$@"
}
# Count entries of DIR whose name contains NEEDLE (hidden files included).
_count_named() {
    local entry n=0
    for entry in "${1}"/* "${1}"/.[!.]*; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        [[ "${entry##*/}" == *"${2}"* ]] && n=$((n + 1))
    done
    echo "${n}"
}

# Create a conversation database at PATH holding the given (id, title) rows.
_mkdb() {
    python3 -I - "$@" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("""CREATE TABLE conversation_summaries (conversation_id text PRIMARY KEY,
    title text NOT NULL DEFAULT "", preview text NOT NULL DEFAULT "",
    step_count integer NOT NULL DEFAULT 0, last_modified_time datetime NOT NULL,
    workspace_uris text NOT NULL, parent_conversation_id text NOT NULL DEFAULT "",
    nesting_depth integer NOT NULL DEFAULT 0)""")
args = sys.argv[2:]
for cid, title in zip(args[0::2], args[1::2]):
    conn.execute("INSERT INTO conversation_summaries VALUES (?, ?, '', 1, '2026-10-18 04:20:00', '[]', '', 0)",
                 (cid, title))
conn.commit()
conn.close()
PY
}
_dbtitle() {
    python3 -I -c 'import sqlite3,sys;r=sqlite3.connect(sys.argv[1]).execute("SELECT title FROM conversation_summaries WHERE conversation_id=?",(sys.argv[2],)).fetchone();print(r[0] if r else "<none>")' "$@"
}

# Fresh profile under FAKE_HOME: _profile NAME -> prints its path.
_profile() {
    local p="${FAKE_HOME}/.gemini-${1}"
    rm -rf "${p}"
    mkdir -p "${p}/antigravity-cli/brain" "${p}/antigravity-cli/conversations"
    printf '%s' "${p}"
}

CID="5a5a5a5a-0000-1111-2222-333333333333"
CID2="6b6b6b6b-0000-1111-2222-333333333333"

# ---------------------------------------------------------------------------
echo "-- checkout import shadowing never executes on the host"
checkout="${FAKE_HOME}/checkout"
canary_dir="${FAKE_HOME}/import-canary"
mkdir -p "${checkout}" "${canary_dir}"
for mod in json sqlite3 re os stat errno secrets signal glob traceback urllib contextlib fcntl shutil tempfile time sitecustomize usercustomize; do
    printf 'open(%s, "w").write("ran")\n' "'${canary_dir}/${mod}'" >"${checkout}/${mod}.py"
done
p="$(_profile shadow)"
_mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Shadow title"
mkdir -p "${p}/antigravity-cli/brain/${CID}"
(
    cd "${checkout}" || exit 1
    export PYTHONPATH="${checkout}" PYTHONSTARTUP="${checkout}/os.py"
    _load
    _agy_list_conversations "${p}" "${checkout}" 20 >/dev/null 2>&1
    _agy_rename_conversation "${p}" "${CID}" "Renamed" >/dev/null 2>&1
    _agy_validate_settings "${p}" >"${FAKE_HOME}/shadow-settings.out" 2>&1
    _agy_delete_conversation "${p}" "${CID}" >/dev/null 2>&1
)
assert_eq "$(ls -A "${canary_dir}")" "" "no checkout module (json.py, sqlite3.py, ...) ran on the host"
assert_contains "$(cat "${FAKE_HOME}/shadow-settings.out")" "settings.json: does not exist" "... while settings were still validated from the checkout"
assert_eq "$(_is test -e "${p}/antigravity-cli/brain/${CID}")" "no" "... and the conversation was deleted"
n_isolated="$(grep -c 'python3 -I -' "${LIB}")"
n_python="$(grep -cE '(^|[^-])python3 ' "${LIB}" | tr -d ' ')"
assert_eq "$(grep -E '(^|[^-#])python3 +-[^I]' "${LIB}" | grep -v 'command -v' || true)" "" \
    "every host-side python3 invocation in the agy lib uses -I (found ${n_isolated} of ${n_python})"

# ---------------------------------------------------------------------------
echo "-- conversation confinement: symlinked database"
canary_db="${FAKE_HOME}/canary/conversation_summaries.db"
mkdir -p "${FAKE_HOME}/canary"
_mkdb "${canary_db}" "${CID}" "CANARY-SECRET-TITLE"
canary_fp="$(_fp "${canary_db}")"
p="$(_profile dblink)"
ln -s "${canary_db}" "${p}/antigravity-cli/conversation_summaries.db"
mkdir -p "${p}/antigravity-cli/brain/${CID}"

out="$( ( _load; _agy_list_conversations "${p}" "${WORK}" 20 ) 2>&1 )"
assert_not_contains "${out}" "CANARY-SECRET-TITLE" "list: symlinked database is never read"
assert_contains "${out}" "refusing symlinked database" "list: ... and the refusal is reported"
err="$( ( _load; _agy_rename_conversation "${p}" "${CID}" "pwned" ) 2>&1 )"; rc=$?
assert_eq "${rc}" "1" "rename: symlinked database fails nonzero"
assert_contains "${err}" "refusing symlinked database" "rename: ... naming the refusal"
assert_eq "$(_is test -e "${p}/antigravity-cli/brain/${CID}/.wrapper_title")" "no" "rename: ... before writing the title"
err="$( ( _load; _agy_delete_conversation "${p}" "${CID}" ) 2>&1 )"; rc=$?
assert_eq "${rc}" "1" "delete: symlinked database fails nonzero"
assert_eq "$(_is test -d "${p}/antigravity-cli/brain/${CID}")" "yes" "delete: ... and leaves artifacts in place"
assert_eq "$(_fp "${canary_db}")" "${canary_fp}" "symlink target database is unmodified"
assert_eq "$(_is test -L "${p}/antigravity-cli/conversation_summaries.db")" "yes" "the database symlink itself is preserved"

p="$(_profile sidecar)"
_mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Original"
echo "canary" >"${FAKE_HOME}/canary/journal"
ln -s "${FAKE_HOME}/canary/journal" "${p}/antigravity-cli/conversation_summaries.db-journal"
err="$( ( _load; _agy_rename_conversation "${p}" "${CID}" "pwned" ) 2>&1 )"; rc=$?
assert_eq "${rc}" "1" "rename: symlinked SQLite journal sidecar is refused"
assert_eq "$(cat "${FAKE_HOME}/canary/journal")" "canary" "... and its target is untouched"

# ---------------------------------------------------------------------------
echo "-- conversation confinement: symlinked ancestors"
for anc in antigravity-cli brain conversations; do
    p="$(_profile "anc-${anc}")"
    ext="${FAKE_HOME}/ext-${anc}"
    rm -rf "${ext}"
    case "${anc}" in
        antigravity-cli)
            mkdir -p "${ext}/brain/${CID}" "${ext}/conversations"
            _mkdb "${ext}/conversation_summaries.db" "${CID}" "EXT-TITLE"
            rm -rf "${p}/antigravity-cli"
            ln -s "${ext}" "${p}/antigravity-cli" ;;
        *)
            mkdir -p "${ext}/${CID}"
            : >"${ext}/${CID}.pb"
            rm -rf "${p}/antigravity-cli/${anc}"
            ln -s "${ext}" "${p}/antigravity-cli/${anc}"
            _mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Inside" ;;
    esac
    ext_fp="$(_fp "${ext}")"
    db_fp="$(_fp "${p}/antigravity-cli/conversation_summaries.db")"
    err="$( ( _load; _agy_delete_conversation "${p}" "${CID}" ) 2>&1 )"; rc=$?
    assert_eq "${rc}" "1" "delete: symlinked ${anc}/ ancestor fails nonzero"
    assert_contains "${err}" "refusing symlinked directory" "delete: ... with a symlinked-directory refusal (${anc})"
    assert_eq "$(_fp "${ext}")" "${ext_fp}" "delete: ... and the ${anc}/ symlink target is untouched"
    if [[ "${anc}" != antigravity-cli ]]; then
        assert_eq "$(_dbtitle "${p}/antigravity-cli/conversation_summaries.db" "${CID}")" "Inside" \
            "delete: ... before the index is updated (${anc})"
    fi
    err="$( ( _load; _agy_rename_conversation "${p}" "${CID}" "pwned" ) 2>&1 )"; rc=$?
    if [[ "${anc}" == conversations ]]; then
        assert_eq "${rc}" "0" "rename: a symlinked conversations/ is not used by rename"
    else
        assert_eq "${rc}" "1" "rename: symlinked ${anc}/ ancestor fails nonzero"
        assert_eq "$(_fp "${ext}")" "${ext_fp}" "rename: ... and the ${anc}/ symlink target is untouched"
        assert_eq "$(_fp "${p}/antigravity-cli/conversation_summaries.db")" "${db_fp}" "rename: ... before the index is updated (${anc})"
    fi
    out="$( ( _load; _agy_list_conversations "${p}" "${WORK}" 20 ) 2>&1 )"
    assert_not_contains "${out}" "EXT-TITLE" "list: never reads through a symlinked ${anc}/"
done

# ---------------------------------------------------------------------------
echo "-- conversation confinement: title file, leaf-only unlink, missing DB"
p="$(_profile title)"
_mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Original"
mkdir -p "${p}/antigravity-cli/brain/${CID}"
echo "TOP-SECRET-LINE" >"${FAKE_HOME}/canary/secret.txt"
ln -s "${FAKE_HOME}/canary/secret.txt" "${p}/antigravity-cli/brain/${CID}/.wrapper_title"
out="$( ( _load; _agy_list_conversations "${p}" "${WORK}" 20 ) 2>&1 )"
assert_not_contains "${out}" "TOP-SECRET-LINE" "list: a symlinked .wrapper_title is never read"
assert_contains "${out}" "Original" "list: ... and the database title is shown instead"
err="$( ( _load; _agy_rename_conversation "${p}" "${CID}" "pwned" ) 2>&1 )"; rc=$?
assert_eq "${rc}" "1" "rename: symlinked .wrapper_title fails nonzero"
assert_contains "${err}" "title file" "rename: ... naming the title file"
assert_eq "$(cat "${FAKE_HOME}/canary/secret.txt")" "TOP-SECRET-LINE" "rename: ... and the symlink target is untouched"
assert_eq "$(_dbtitle "${p}/antigravity-cli/conversation_summaries.db" "${CID}")" "Original" "rename: ... before the index is updated"

# Symlinked conversation dir: listing skips it, rename refuses to traverse.
p="$(_profile convlink)"
mkdir -p "${FAKE_HOME}/ext-conv/.system_generated/logs"
echo '{"type":"USER_INPUT","content":"EXT-TRANSCRIPT"}' >"${FAKE_HOME}/ext-conv/.system_generated/logs/transcript.jsonl"
ln -s "${FAKE_HOME}/ext-conv" "${p}/antigravity-cli/brain/${CID}"
out="$( ( _load; _agy_list_conversations "${p}" "${WORK}" 20 ) 2>&1 )"
assert_not_contains "${out}" "EXT-TRANSCRIPT" "list: a symlinked brain/<cid> is never traversed"
err="$( ( _load; _agy_rename_conversation "${p}" "${CID}" "pwned" ) 2>&1 )"; rc=$?
assert_eq "${rc}" "1" "rename: symlinked brain/<cid> fails nonzero"
assert_eq "$(_is test -e "${FAKE_HOME}/ext-conv/.wrapper_title")" "no" "rename: ... without writing into its target"

# Leaf-only unlink: symlinked artifacts go, their targets stay.
p="$(_profile leaf)"
_mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Leaf"
mkdir -p "${FAKE_HOME}/leaf-target-dir/keep"
echo keep >"${FAKE_HOME}/leaf-target-dir/keep/file"
echo keep >"${FAKE_HOME}/leaf-target-file"
ln -s "${FAKE_HOME}/leaf-target-dir" "${p}/antigravity-cli/brain/${CID}"
ln -s "${FAKE_HOME}/leaf-target-file" "${p}/antigravity-cli/conversations/${CID}.pb"
mkdir -p "${p}/antigravity-cli/conversations/${CID}/nested"
ln -s "${FAKE_HOME}/leaf-target-dir" "${p}/antigravity-cli/conversations/${CID}/nested/link"
err="$( ( _load; _agy_delete_conversation "${p}" "${CID}" ) 2>&1 )"; rc=$?
assert_eq "${rc}" "0" "delete: symlinked artifact leaves are removed successfully"
assert_eq "$(_is test -L "${p}/antigravity-cli/brain/${CID}")" "no" "delete: brain/<cid> symlink unlinked"
assert_eq "$(_is test -L "${p}/antigravity-cli/conversations/${CID}.pb")" "no" "delete: conversations/<cid>.pb symlink unlinked"
assert_eq "$(_is test -e "${p}/antigravity-cli/conversations/${CID}")" "no" "delete: conversations/<cid> dir removed"
assert_eq "$(cat "${FAKE_HOME}/leaf-target-dir/keep/file")/$(cat "${FAKE_HOME}/leaf-target-file")" "keep/keep" \
    "delete: symlink targets (incl. one nested in a removed dir) are untouched"
assert_eq "$(_dbtitle "${p}/antigravity-cli/conversation_summaries.db" "${CID}")" "<none>" "delete: index row removed"

# Missing database: validation never creates it.
p="$(_profile nodb)"
mkdir -p "${p}/antigravity-cli/brain/${CID}" "${p}/antigravity-cli/brain/${CID2}"
( _load; _agy_rename_conversation "${p}" "${CID}" "Fresh title" ) >/dev/null 2>&1; rc=$?
assert_eq "${rc}" "0" "rename without a database succeeds (title file only)"
assert_eq "$(cat "${p}/antigravity-cli/brain/${CID}/.wrapper_title")" "Fresh title" "... and writes the title"
( _load; _agy_delete_conversation "${p}" "${CID2}" ) >/dev/null 2>&1; rc=$?
assert_eq "${rc}" "0" "delete without a database succeeds"
( _load; _agy_list_conversations "${p}" "${WORK}" 20 ) >/dev/null 2>&1
assert_eq "$(_is test -e "${p}/antigravity-cli/conversation_summaries.db")" "no" "rename/delete/list never create a missing database"

# Normal operations still work end to end.
p="$(_profile normal)"
_mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Normal one" "${CID2}" "Normal two"
mkdir -p "${p}/antigravity-cli/brain/${CID}" "${p}/antigravity-cli/brain/${CID2}"
: >"${p}/antigravity-cli/conversations/${CID2}.pb"
( _load; _agy_rename_conversation "${p}" "${CID}" "Renamed one" ) >/dev/null 2>&1
assert_eq "$(_dbtitle "${p}/antigravity-cli/conversation_summaries.db" "${CID}")" "Renamed one" "normal rename updates the index"
assert_eq "$(_mode "${p}/antigravity-cli/brain/${CID}/.wrapper_title")" "0o600" "... and writes a private title file"
( _load; _agy_delete_conversation "${p}" "${CID2}" ) >/dev/null 2>&1; rc=$?
assert_eq "${rc}" "0" "normal delete succeeds"
assert_eq "$(_is test -e "${p}/antigravity-cli/conversations/${CID2}.pb")" "no" "... removing conversations/<cid>.pb"
out="$( ( _load; _agy_list_conversations "${p}" "${WORK}" 20 ) 2>&1 )"
assert_contains "${out}" "Renamed one" "normal list shows the renamed conversation"
assert_not_contains "${out}" "Normal two" "normal list omits the deleted conversation"

# ---------------------------------------------------------------------------
echo "-- rename stays available: displayed title, failures reported, nothing half-done"
p="$(_profile override)"
_mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Index title"
mkdir -p "${p}/antigravity-cli/brain/${CID}"
echo "Old override" >"${p}/antigravity-cli/brain/${CID}/.wrapper_title"
out="$( ( _load; AGY_RESUME_PICK=$'r 1 Brand new title\nq' _AGY_ACTIVE_PROFILE_DIR="${p}" _agent_resume_args ) 2>&1 )"
assert_contains "${out}" "Renamed [${CID%%-*}] -> 'Brand new title'." "picker rename is available and reports success"
out="$( ( _load; _agy_list_conversations "${p}" "${WORK}" 20 ) 2>&1 )"
assert_contains "${out}" "Brand new title" "rename changes the displayed title even when a .wrapper_title existed"
assert_not_contains "${out}" "Old override" "... the old override title is gone"
assert_eq "$(_dbtitle "${p}/antigravity-cli/conversation_summaries.db" "${CID}")" "Brand new title" "... and the index agrees"

# Not in the index and no conversation dir: an error, never a silent success.
p="$(_profile unknown)"
_mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Only one"
err="$( ( _load; _agy_rename_conversation "${p}" "${CID2}" "Ghost" ) 2>&1 )"; rc=$?
assert_eq "${rc}" "1" "rename of an unknown conversation fails nonzero"
assert_contains "${err}" "nothing was renamed" "... saying nothing was renamed"
assert_eq "$(_is test -e "${p}/antigravity-cli/brain/${CID2}")" "no" "... without creating a conversation dir"

if [[ "$(id -u)" != "0" ]]; then
    p="$(_profile rotitle)"
    _mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Kept title"
    mkdir -p "${p}/antigravity-cli/brain/${CID}"
    echo "Kept override" >"${p}/antigravity-cli/brain/${CID}/.wrapper_title"
    chmod 0500 "${p}/antigravity-cli/brain/${CID}"
    out="$( ( _load; AGY_RESUME_PICK=$'r 1 Denied title\nq' _AGY_ACTIVE_PROFILE_DIR="${p}" _agent_resume_args ) 2>&1 )"
    chmod 0700 "${p}/antigravity-cli/brain/${CID}"
    assert_contains "${out}" "Failed to rename conversation [${CID%%-*}]" "unwritable title dir: the picker reports the failure"
    assert_not_contains "${out}" "Renamed [" "unwritable title dir: ... and never prints success"
    assert_contains "${out}" "${p}/antigravity-cli/brain/${CID}/.wrapper_title" "unwritable title dir: ... naming the affected path"
    assert_contains "${out}" "retry the rename" "unwritable title dir: ... with retry guidance"
    assert_eq "$(_dbtitle "${p}/antigravity-cli/conversation_summaries.db" "${CID}")" "Kept title" \
        "unwritable title dir: ... and the index is not changed (no half-done rename)"
    assert_eq "$(cat "${p}/antigravity-cli/brain/${CID}/.wrapper_title")" "Kept override" "unwritable title dir: ... nor the title file"
else
    echo "  skip - unwritable title dir check (running as root)"
fi

# ---------------------------------------------------------------------------
echo "-- settings.json: read-only validation of a regular file"
_settings() { ( cd "${WORK}" && _load && WRAPPER_FLAGS=() && _agy_validate_settings "$@" ) 2>&1; }
# _unchanged LABEL PATH... : assert content + metadata of each PATH are as captured by _snap.
_snap() { local f; for f in "$@"; do printf '%s|%s|%s\n' "${f}" "$(_fp "${f}")" "$( [[ -e "${f}" ]] && _meta "${f}")"; done; }

p="$(_profile valid)"
_valid_settings "${WORK}" >"${p}/antigravity-cli/settings.json"
chmod 0640 "${p}/antigravity-cli/settings.json"
before="$(_snap "${p}/antigravity-cli/settings.json" "${p}/antigravity-cli")"
out="$(_settings "${p}")"; rc=$?
assert_eq "${rc}" "0" "valid settings.json passes (${out})"
assert_eq "$(_snap "${p}/antigravity-cli/settings.json" "${p}/antigravity-cli")" "${before}" \
    "... and the file and its directory are unchanged (content, inode, mode, mtime)"

_valid_settings "file://${WORK}" >"${p}/antigravity-cli/settings.json"
out="$(_settings "${p}")"; rc=$?
assert_eq "${rc}" "0" "a file:// trustedWorkspaces entry for the workspace is accepted (${out})"

p="$(_profile newfile)"
before="$(_snap "${p}/antigravity-cli")"
out="$(_settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "missing settings.json fails the launch"
assert_contains "${out}" "settings.json: does not exist" "... saying it does not exist"
assert_contains "${out}" '"toolPermission": "always-proceed"' "... showing the settings to create"
assert_contains "${out}" "\"${WORK}\"" "... including the current workspace"
assert_contains "${out}" "then relaunch" "... and how to retry"
assert_eq "$(_is test -e "${p}/antigravity-cli/settings.json")" "no" "... without creating it"
assert_eq "$(_snap "${p}/antigravity-cli")" "${before}" "... or touching its directory"

p="$(_profile nocli)"
rm -rf "${p}/antigravity-cli"
out="$(_settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "missing antigravity-cli/ fails the launch"
assert_contains "${out}" "create that first" "... asking for the directory to be created"
assert_eq "$(_is test -e "${p}/antigravity-cli")" "no" "... without creating the parent directory"

# Each missing/wrong requirement is named; the file is never touched.
_check_bad() {
    local label="${1}" json="${2}" needle="${3}"
    p="$(_profile badsetting)"
    printf '%s\n' "${json}" >"${p}/antigravity-cli/settings.json"
    before="$(_snap "${p}/antigravity-cli/settings.json" "${p}/antigravity-cli")"
    out="$(_settings "${p}")"; rc=$?
    assert_eq "${rc}" "1" "${label}: fails the launch"
    assert_contains "${out}" "${needle}" "${label}: ... naming the problem"
    assert_contains "${out}" "never creates or edits it" "${label}: ... saying the wrapper will not change it"
    assert_eq "$(_snap "${p}/antigravity-cli/settings.json" "${p}/antigravity-cli")" "${before}" "${label}: ... and leaves it unchanged"
}
good_tail="\"allowNonWorkspaceAccess\":true,\"enableTerminalSandbox\":false,\"trustedWorkspaces\":[\"${WORK}\"]"
_check_bad "toolPermission request-review" "{\"toolPermission\":\"request-review\",\"artifactReviewPolicy\":\"always-proceed\",${good_tail}}" \
    '"toolPermission" is "request-review"; required: "always-proceed"'
_check_bad "artifactReviewPolicy missing" "{\"toolPermission\":\"always-proceed\",${good_tail}}" \
    '"artifactReviewPolicy" is missing'
_check_bad "allowNonWorkspaceAccess false" "{\"toolPermission\":\"always-proceed\",\"artifactReviewPolicy\":\"always-proceed\",\"allowNonWorkspaceAccess\":false,\"enableTerminalSandbox\":false,\"trustedWorkspaces\":[\"${WORK}\"]}" \
    '"allowNonWorkspaceAccess" is false; required: true'
_check_bad "enableTerminalSandbox 0" "{\"toolPermission\":\"always-proceed\",\"artifactReviewPolicy\":\"always-proceed\",\"allowNonWorkspaceAccess\":true,\"enableTerminalSandbox\":0,\"trustedWorkspaces\":[\"${WORK}\"]}" \
    '"enableTerminalSandbox" is 0; required: false'
_check_bad "workspace not trusted" "{\"toolPermission\":\"always-proceed\",\"artifactReviewPolicy\":\"always-proceed\",\"allowNonWorkspaceAccess\":true,\"enableTerminalSandbox\":false,\"trustedWorkspaces\":[\"/elsewhere\"]}" \
    "does not include the current workspace \"${WORK}\""
_check_bad "invalid JSON" '{"colorScheme": "dark",' "is not valid JSON"
_check_bad "non-object JSON" '["not", "an", "object"]' "does not hold a JSON object"
assert_contains "${out}" "Fix the file by hand" "invalid settings: ... with how to fix it"

# Pre-created temp-name symlinks are never followed: nothing is written at all.
p="$(_profile tmplink)"
echo canary >"${FAKE_HOME}/canary/tmp-target"
_valid_settings "${WORK}" >"${p}/antigravity-cli/settings.json"
(
    cd "${WORK}" || exit 1
    _load
    WRAPPER_FLAGS=()
    ln -s "${FAKE_HOME}/canary/tmp-target" "${p}/antigravity-cli/settings.json.tmp.$$"
    ln -s "${FAKE_HOME}/canary/tmp-target" "${p}/antigravity-cli/settings.json.tmp.${BASHPID:-$$}"
    _agy_validate_settings "${p}"
) >/dev/null 2>&1
assert_eq "$(cat "${FAKE_HOME}/canary/tmp-target")" "canary" "pre-created temp-file symlinks never receive settings"
assert_eq "$(_is test -L "${p}/antigravity-cli/settings.json")" "no" "... and settings.json stays a regular file"

p="$(_profile nondir)"
rm -rf "${p}/antigravity-cli"
_valid_settings "${WORK}" >"${FAKE_HOME}/canary/settings.json"
ln -s "${FAKE_HOME}/canary" "${p}/antigravity-cli"
out="$(_settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "symlinked antigravity-cli/ is refused for settings"
assert_contains "${out}" "refusing symlinked directory" "... with a symlinked-directory refusal"
rm -f "${FAKE_HOME}/canary/settings.json"

if [[ "$(id -u)" != "0" ]]; then
    p="$(_profile rodir)"
    _valid_settings "${WORK}" >"${p}/antigravity-cli/settings.json"
    chmod 0444 "${p}/antigravity-cli/settings.json"
    chmod 0500 "${p}/antigravity-cli"
    out="$(_settings "${p}")"; rc=$?
    chmod 0700 "${p}/antigravity-cli"
    assert_eq "${rc}" "0" "read-only settings.json in a read-only dir passes: validation needs no write access (${out})"
else
    echo "  skip - read-only directory check (running as root)"
fi

# ---------------------------------------------------------------------------
echo "-- settings.json: symlink + trusted target (profile AND file approval)"
dot="${FAKE_HOME}/dotfiles/agy"
mkdir -p "${dot}"
_mklinked() {
    local p
    p="$(_profile "${1}")"
    _valid_settings /x "${WORK}" >"${dot}/settings.json"
    chmod 0644 "${dot}/settings.json"
    ln -s "${dot}/settings.json" "${p}/antigravity-cli/settings.json"
    printf '%s' "${p}"
}

p="$(_mklinked unconfigured)"
before="$(_fp "${dot}/settings.json")"
out="$(_settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "symlinked settings.json without approval fails closed"
assert_contains "${out}" "AGY_SETTINGS_TRUSTED_TARGET" "... telling the user how to approve it"
assert_eq "$(_fp "${dot}/settings.json")" "${before}" "... leaving the target unchanged"
assert_eq "$(_is test -L "${p}/antigravity-cli/settings.json")" "yes" "... and the symlink in place"

p="$(_mklinked approved)"
before="$(_snap "${dot}/settings.json" "${dot}" "${p}/antigravity-cli")"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "0" "approved profile+target with valid settings passes (${out})"
assert_eq "$(readlink "${p}/antigravity-cli/settings.json")" "${dot}/settings.json" "... the symlink is preserved"
assert_eq "$(_snap "${dot}/settings.json" "${dot}" "${p}/antigravity-cli")" "${before}" \
    "... the target, its directory and the profile dir are unchanged"

p="$(_mklinked approvedbad)"
printf '{"colorScheme":"tokyo"}\n' >"${dot}/settings.json"
before="$(_snap "${dot}/settings.json" "${dot}" "${p}/antigravity-cli")"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "approved target lacking required settings fails the launch"
assert_contains "${out}" "Edit ${dot}/settings.json" "... asking for the approved target itself to be edited"
assert_contains "${out}" '"toolPermission" is missing' "... naming what is missing"
assert_eq "$(_snap "${dot}/settings.json" "${dot}" "${p}/antigravity-cli")" "${before}" \
    "... the target, its directory and the profile dir are unchanged"
assert_eq "$(readlink "${p}/antigravity-cli/settings.json")" "${dot}/settings.json" "... and the symlink stays intact"

p="$(_mklinked tilde)"
# shellcheck disable=SC2088  # a literal "~" is what the settings menu stores
out="$(AGY_SETTINGS_TRUSTED_PROFILE="~/.gemini-tilde" AGY_SETTINGS_TRUSTED_TARGET="~/dotfiles/agy/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "0" "approval values may use ~ for \$HOME"

p="$(_mklinked mismatch)"
before="$(_fp "${dot}/settings.json")"
echo '{}' >"${dot}/other.json"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/other.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "approved target mismatch fails closed"
assert_contains "${out}" "not the approved target" "... naming the mismatch"
assert_eq "$(_fp "${dot}/settings.json")/$(_fp "${dot}/other.json")" "${before}/$(_fp "${dot}/other.json")" "... changing neither file"
rm -f "${dot}/other.json"

out="$(AGY_SETTINGS_TRUSTED_PROFILE="${FAKE_HOME}/.gemini-approved" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "approval for another profile fails closed"
assert_contains "${out}" "not the selected profile" "... naming the profile mismatch"

out="$(AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "target approval without a profile fails closed"
assert_contains "${out}" "must both be set" "... naming the missing half"

# Account switching: an approval saved while using one account is not
# reused after switching to another account whose settings.json links to
# the same file.
mkdir -p "${FAKE_HOME}/.gemini-first/antigravity-cli" "${FAKE_HOME}/.gemini-second/antigravity-cli"
_valid_settings "${WORK}" >"${dot}/settings.json"
ln -sf "${dot}/settings.json" "${FAKE_HOME}/.gemini-first/antigravity-cli/settings.json"
ln -sf "${dot}/settings.json" "${FAKE_HOME}/.gemini-second/antigravity-cli/settings.json"
_bind_acct() {
    ( cd "${WORK}" && _load && WRAPPER_FLAGS=() && AGY_ACCOUNT="${1}" \
        AGY_SETTINGS_TRUSTED_PROFILE="${FAKE_HOME}/.gemini-first" \
        AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _bind_agy_account ) 2>&1
}
out="$(_bind_acct first)"; rc=$?
assert_eq "${rc}" "0" "account switch: approved account binds (${out})"
before="$(_fp "${dot}/settings.json")"
out="$(_bind_acct second)"; rc=$?
assert_eq "${rc}" "1" "account switch: the other account does not reuse the approval"
assert_eq "$(_fp "${dot}/settings.json")" "${before}" "account switch: ... and the target is untouched"

p="$(_mklinked dangling)"
rm -f "${dot}/settings.json"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "dangling approved symlink fails closed"
assert_contains "${out}" "create that file, then relaunch" "... with how to fix it"
assert_eq "$(_is test -e "${dot}/settings.json")" "no" "... without creating the target"

p="$(_mklinked nonregular)"
rm -f "${dot}/settings.json"; mkdir "${dot}/settings.json"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "non-regular approved target fails closed"
rmdir "${dot}/settings.json"

p="$(_mklinked invalid)"
printf 'export PATH=/evil\n' >"${dot}/settings.json"
before="$(_fp "${dot}/settings.json")"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "approved target holding non-JSON fails closed"
assert_eq "$(_fp "${dot}/settings.json")" "${before}" "... and is not overwritten"

# Symlinked parent: the approval must name the canonical path.
p="$(_mklinked parentlink)"
ln -sfn "${dot}" "${FAKE_HOME}/dot-alias"
ln -sf "${FAKE_HOME}/dot-alias/settings.json" "${p}/antigravity-cli/settings.json"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${FAKE_HOME}/dot-alias/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "approval naming a path through a symlinked parent fails closed"
assert_contains "${out}" "canonical" "... asking for the canonical path"

# Outside $HOME / credential locations.
p="$(_profile outside)"
_valid_settings "${WORK}" >"${OUTSIDE_HOME}/settings.json"
ln -s "${OUTSIDE_HOME}/settings.json" "${p}/antigravity-cli/settings.json"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${OUTSIDE_HOME}/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "approved target outside \$HOME fails closed"
assert_contains "${out}" "outside \$HOME" "... naming the reason"
p="$(_profile cred)"
mkdir -p "${FAKE_HOME}/.ssh"
_valid_settings "${WORK}" >"${FAKE_HOME}/.ssh/settings.json"
ln -s "${FAKE_HOME}/.ssh/settings.json" "${p}/antigravity-cli/settings.json"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${FAKE_HOME}/.ssh/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "approved target in a credential dir fails closed"
assert_contains "${out}" "credential location" "... naming the reason"

# ---------------------------------------------------------------------------
echo "-- approval persistence: settings menu catalog, preset, sandbox-writable preset"
catalog="$( _load; printf '%s\n' "${_AI_SETTINGS_LIST[@]}" )"
assert_contains "${catalog}" "AGY_SETTINGS_TRUSTED_PROFILE|path||" "trusted profile is a path entry in the agy settings menu"
assert_contains "${catalog}" "AGY_SETTINGS_TRUSTED_TARGET|path||" "trusted target is a path entry in the agy settings menu"
assert_not_contains "$( source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"; source "${REPO_ROOT}/bin/ai_wrapper_data/claude_wrapper_lib.bash"; printf '%s\n' "${_AI_SETTINGS_LIST[@]}" )" \
    "AGY_SETTINGS_TRUSTED" "trusted-target settings are agy-only"

p="$(_mklinked preset)"
(
    cd "${WORK}" || exit 1
    _load
    AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _preset_autosave
) 2>/dev/null
out="$(
    cd "${WORK}" || exit 1
    _load
    unset AGY_SETTINGS_TRUSTED_PROFILE AGY_SETTINGS_TRUSTED_TARGET
    _preset_autoload 2>&1
    WRAPPER_FLAGS=()
    _agy_validate_settings "${p}" 2>&1 && echo CONFIGURED
)"
assert_contains "${out}" "CONFIGURED" "approval saved via the preset is honoured on reload"

# The preset that carries the approval must not be writable by the agent.
out="$(
    cd "${WORK}" || exit 1
    export XDG_CONFIG_HOME="${WORK}/.config"
    _load
    WRAPPER_FLAGS=()
    AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" \
        _agy_validate_settings "${p}" 2>&1
)"; rc=$?
assert_eq "${rc}" "1" "approval refused when the preset dir is inside WORKDIR"
assert_contains "${out}" "writable inside the sandbox" "... explaining that the agent could forge it"
out="$(
    cd "${WORK}" || exit 1
    _load
    WRAPPER_FLAGS=()
    AI_SANDBOX_EXTRA_RW_DIRS="/nonexistent, ~/.config" AGY_SETTINGS_TRUSTED_PROFILE="${p}" \
        AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _agy_validate_settings "${p}" 2>&1
)"; rc=$?
assert_eq "${rc}" "1" "approval refused when an extra RW bind exposes the preset dir"
out="$(
    cd "${WORK}" || exit 1
    _load
    WRAPPER_FLAGS=(--bind "${FAKE_HOME}/.config" "${FAKE_HOME}/.config")
    AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" \
        _agy_validate_settings "${p}" 2>&1
)"; rc=$?
assert_eq "${rc}" "1" "approval refused when a wrapper --bind exposes the preset dir"

# A plugin hook that can add binds after the trust decision makes the
# preset's writability unknowable, so the approval is refused; a plugin
# without such hooks does not affect it.
for hook in _extra_post_menu_setup _extra_sandbox_setup; do
    plugin="${FAKE_HOME}/plugin-${hook}.bash"
    printf '%s() { WRAPPER_FLAGS+=(--bind "%s/.config"); bwrap_args+=(--bind "%s/.config" "%s/.config"); binds_rw+=("%s/.config"); }\n' \
        "${hook}" "${FAKE_HOME}" "${FAKE_HOME}" "${FAKE_HOME}" "${FAKE_HOME}" >"${plugin}"
    before="$(_fp "${dot}/settings.json")"
    out="$(
        cd "${WORK}" || exit 1
        _load
        AI_WRAPPER_EXTRA_PROFILE="${plugin}" _load_extra_profile
        WRAPPER_FLAGS=()
        AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" \
            _agy_validate_settings "${p}" 2>&1
    )"; rc=$?
    assert_eq "${rc}" "1" "approval refused when a plugin defines ${hook} (late sandbox binds)"
    assert_contains "${out}" "cannot be determined" "${hook}: ... explaining that writability is unknown"
    assert_eq "$(_fp "${dot}/settings.json")" "${before}" "${hook}: ... and the approved target is untouched"
done
plugin="${FAKE_HOME}/plugin-header.bash"
printf '_extra_header_extras() { :; }\n' >"${plugin}"
out="$(
    cd "${WORK}" || exit 1
    _load
    AI_WRAPPER_EXTRA_PROFILE="${plugin}" _load_extra_profile
    WRAPPER_FLAGS=()
    AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" \
        _agy_validate_settings "${p}" 2>&1 && echo CONFIGURED
)"
assert_contains "${out}" "CONFIGURED" "a plugin without bind hooks does not block the approval"

# ---------------------------------------------------------------------------
echo "-- deterministic race injection around the embedded helper"
HELPER="${FAKE_HOME}/agy_host_helper.py"
awk 'index($0, "_agy_host_py() {") == 1 {f=1; next} f && $0 == "PY" {exit} f && p {print} f && /<<.PY.$/ {p=1}' "${LIB}" >"${HELPER}"
HARNESS_DIR="$(mktemp -d "${FAKE_HOME}/harness.XXXXXX")"
cat >"${HARNESS_DIR}/inject.py" <<'PY'
"""Run the embedded helper with one os/sqlite3 call wrapped by a scenario."""
import fcntl, os, sqlite3, sys, time

helper, scenario, swap_a, swap_b = sys.argv[1:5]
state = {"calls": 0}

def swap_to_symlink(path, target):
    os.rename(path, path + ".moved")
    os.symlink(target, path)

def concurrent_write(path, always):
    if always or state["calls"] == 1:
        with open(path, "w") as handle:
            handle.write('{"writer": %d}\n' % state["calls"])
        os.utime(path, ns=(state["calls"] * 10**9, state["calls"] * 10**9))

real_fsync, real_connect, real_open, real_rename = os.fsync, sqlite3.connect, os.open, os.rename
PROBE_PREFIX = "agy-sqlite-probe-"

def profile_db(args):
    """True for the helper's connect() of the profile database (not its probe)."""
    return bool(args) and str(args[0]).startswith("file:conversation_summaries.db")

class HookedConnection(sqlite3.Connection):
    """Swap a path right before the helper's first UPDATE/DELETE statement."""
    def execute(self, sql, *args):
        if not state.get("swapped") and sql.lstrip().upper().startswith(("UPDATE", "DELETE")):
            state["swapped"] = True
            if scenario == "sidecar-write":
                os.symlink(swap_b, swap_a)
            elif scenario == "ancestor-write":
                swap_to_symlink(swap_a, swap_b)
        return super().execute(sql, *args)

def drop_probe_symlinks(args):
    """Emulate an SQLite that follows symlinked sidecars: let probe writes succeed."""
    path = str(args[0]) if args else ""
    if PROBE_PREFIX not in path:
        return
    probe_dir = os.path.dirname(path.split("?", 1)[0].replace("file:", "", 1))
    for entry in os.listdir(probe_dir):
        if os.path.islink(os.path.join(probe_dir, entry)):
            os.unlink(os.path.join(probe_dir, entry))

def fsync(fd):
    real_fsync(fd)
    state["calls"] += 1
    if scenario == "writer-once":
        concurrent_write(swap_a, False)
    elif scenario == "writer-always":
        concurrent_write(swap_a, True)
    elif scenario == "parent-swap" and state["calls"] == 1:
        swap_to_symlink(swap_a, swap_b)

def connect(*args, **kwargs):
    if scenario == "sqlite-follows":
        drop_probe_symlinks(args)
    elif profile_db(args):
        if scenario == "db-swap":
            swap_to_symlink(swap_a, swap_b)
        elif scenario == "sidecar-connect":
            os.symlink(swap_b, swap_a)
        elif scenario in ("sidecar-write", "ancestor-write"):
            kwargs["factory"] = HookedConnection
    return real_connect(*args, **kwargs)

def rename(src, dst, *args, **kwargs):
    """The boundary between the final re-check and the rename of a temp file."""
    if "agy-tmp" in str(src):
        if scenario == "lock-probe":
            fd = os.open(swap_a, os.O_RDONLY)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                sys.stderr.write("BOUNDARY: lock free\n")
            except BlockingIOError:
                sys.stderr.write("BOUNDARY: lock held\n")
            finally:
                os.close(fd)
        elif scenario == "boundary-writer":
            with open(swap_a, "w") as handle:
                handle.write('{"uncooperative": true}\n')
    return real_rename(src, dst, *args, **kwargs)

if scenario == "lock-busy":
    # Another wrapper instance holds the lock and never releases it; a fake
    # clock lets the helper reach its deadline without real waiting.
    held_fd = os.open(swap_a, os.O_RDONLY)
    fcntl.flock(held_fd, fcntl.LOCK_EX)
    clock = [0.0]
    time.monotonic = lambda: clock[0]
    time.sleep = lambda seconds: clock.__setitem__(0, clock[0] + seconds)

def open_(path, flags, *args, **kwargs):
    if scenario == "leaf-swap" and path == os.path.basename(swap_a) and kwargs.get("dir_fd") is not None \
            and state["calls"] == 0 and flags & getattr(os, "O_DIRECTORY", 0):
        state["calls"] += 1
        swap_to_symlink(swap_a, swap_b)
    return real_open(path, flags, *args, **kwargs)

os.fsync, sqlite3.connect, os.open, os.rename = fsync, connect, open_, rename
# The wrappers forward dir_fd, so advertise them like the real calls.
os.supports_dir_fd = set() if scenario == "no-dir-fd" else set(os.supports_dir_fd) | {open_, rename}
sys.argv = [helper] + sys.argv[5:]
with open(helper) as handle:
    code = compile(handle.read(), helper, "exec")
exec(code, {"__name__": "__main__"})
PY
_inject() { (cd "${WORK}" && python3 -I "${HARNESS_DIR}/inject.py" "${HELPER}" "$@") 2>&1; }
assert_contains "$(head -1 "${HELPER}")" "import" "embedded helper extracted for injection"

# A writer changing the title file while rename replaces it: the rename
# fails, says the index was already updated, and keeps the writer's title.
p="$(_profile writer)"
_mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Index title"
mkdir -p "${p}/antigravity-cli/brain/${CID}"
echo "Old title" >"${p}/antigravity-cli/brain/${CID}/.wrapper_title"
out="$(_inject writer-once "${p}/antigravity-cli/brain/${CID}/.wrapper_title" - rename "${p}" "${CID}" "Mine")"; rc=$?
assert_eq "${rc}" "1" "concurrent title writer: rename fails nonzero"
assert_contains "${out}" "changed while it was being updated" "concurrent title writer: ... explaining why"
assert_contains "${out}" "was already updated" "concurrent title writer: ... and that the index already changed"
assert_contains "$(cat "${p}/antigravity-cli/brain/${CID}/.wrapper_title")" '"writer": 1' "concurrent title writer: ... the writer's title is kept"
assert_eq "$(_count_named "${p}/antigravity-cli/brain/${CID}" agy-tmp)" "0" "concurrent title writer: ... and temp files are cleaned up"

# Conversation dir swapped for a symlink between the temp write and rename.
p="$(_profile parentswap)"
mkdir -p "${p}/antigravity-cli/brain/${CID}" "${FAKE_HOME}/attacker-conv"
out="$(_inject parent-swap "${p}/antigravity-cli/brain/${CID}" "${FAKE_HOME}/attacker-conv" rename "${p}" "${CID}" "pwned")"; rc=$?
assert_eq "${rc}" "1" "parent swap: conversation dir replaced mid-rename fails"
assert_contains "${out}" "refusing symlinked directory ${p}/antigravity-cli/brain/${CID}" "parent swap: ... reported on the re-walk before rename"
assert_eq "$(ls -A "${FAKE_HOME}/attacker-conv")" "" "parent swap: ... nothing written to the swapped-in dir"
assert_eq "$(_count_named "${p}/antigravity-cli/brain/${CID}.moved" agy-tmp)" "0" "parent swap: ... and the temp file is cleaned up"

# antigravity-cli/ swapped for a symlink while the title is replaced.
p="$(_profile cliswap)"
mkdir -p "${p}/antigravity-cli/brain/${CID}" "${FAKE_HOME}/cli-attacker"
out="$(_inject parent-swap "${p}/antigravity-cli" "${FAKE_HOME}/cli-attacker" rename "${p}" "${CID}" "pwned")"; rc=$?
assert_eq "${rc}" "1" "antigravity-cli swap mid-rename fails"
assert_eq "$(ls -A "${FAKE_HOME}/cli-attacker")" "" "antigravity-cli swap: ... nothing written to the swapped-in dir"

# Database swapped for a symlink right before SQLite opens it.
p="$(_profile dbswap)"
_mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Real"
canary_fp="$(_fp "${canary_db}")"
out="$(_inject db-swap "${p}/antigravity-cli/conversation_summaries.db" "${canary_db}" rename "${p}" "${CID}" "pwned")"; rc=$?
assert_eq "${rc}" "1" "database swap before SQLite open is detected"
assert_contains "${out}" "different file" "database swap: ... reported"
assert_eq "$(_fp "${canary_db}")" "${canary_fp}" "database swap: ... and the swapped-in database is untouched"

# Conversation dir swapped for a symlink between check and removal.
p="$(_profile leafswap)"
mkdir -p "${p}/antigravity-cli/brain/${CID}" "${FAKE_HOME}/leafswap-target"
echo keep >"${FAKE_HOME}/leafswap-target/file"
out="$(_inject leaf-swap "${p}/antigravity-cli/brain/${CID}" "${FAKE_HOME}/leafswap-target" delete "${p}" "${CID}" 1000)"; rc=$?
assert_eq "${rc}" "1" "artifact swap between check and removal fails"
assert_eq "$(cat "${FAKE_HOME}/leafswap-target/file")" "keep" "artifact swap: ... and the symlink target is untouched"

# SQLite sidecars are opened by SQLite, by path. A sidecar swapped for a
# symlink after the pre-check, or a directory swapped mid-transaction, must
# never let SQLite modify a file outside the profile.
_walify() { python3 -I -c 'import sqlite3,sys;c=sqlite3.connect(sys.argv[1]);c.execute("PRAGMA journal_mode=WAL");c.close()' "${1}"; }
victim="${FAKE_HOME}/sidecar-victim"
for spec in "-journal:DELETE" "-wal:WAL" "-shm:WAL"; do
    suffix="${spec%%:*}"; jmode="${spec#*:}"
    p="$(_profile "sidecar${suffix}")"
    db="${p}/antigravity-cli/conversation_summaries.db"
    _mkdb "${db}" "${CID}" "Real"
    [[ "${jmode}" == "WAL" ]] && _walify "${db}"
    printf 'victim bytes\n' >"${victim}"
    victim_fp="$(_fp "${victim}")"
    out="$(_inject sidecar-connect "${db}${suffix}" "${victim}" rename "${p}" "${CID}" "pwned")"; rc=$?
    assert_eq "${rc}" "1" "${suffix} swapped for a symlink before SQLite opens it: rename fails"
    assert_eq "$(_fp "${victim}")" "${victim_fp}" "${suffix} swap at open: ... the external file's bytes are unchanged"
    rm -f "${db}${suffix}"  # the planted link; SQLite (rightly) refuses to read past it
    assert_eq "$(_dbtitle "${db}" "${CID}")" "Real" "${suffix} swap at open: ... and the title is not changed"
done
p="$(_profile sidecarwrite)"
db="${p}/antigravity-cli/conversation_summaries.db"
_mkdb "${db}" "${CID}" "Real"
printf 'victim bytes\n' >"${victim}"
victim_fp="$(_fp "${victim}")"
out="$(_inject sidecar-write "${db}-journal" "${victim}" rename "${p}" "${CID}" "pwned")"; rc=$?
assert_eq "${rc}" "1" "-journal swapped for a symlink right before the UPDATE: rename fails"
assert_eq "$(_fp "${victim}")" "${victim_fp}" "-journal swap at write: ... the external file's bytes are unchanged"
rm -f "${db}-journal"  # the planted link; SQLite (rightly) refuses to read past it
assert_eq "$(_dbtitle "${db}" "${CID}")" "Real" "-journal swap at write: ... and the title is not changed"

# antigravity-cli/ swapped for a symlink to a directory holding same-named
# sidecar files, right before the write: nothing there may change.
for spec in "rename:DELETE" "delete:DELETE" "rename:WAL"; do
    op="${spec%%:*}"; jmode="${spec#*:}"
    p="$(_profile "ancestor-${op}-${jmode}")"
    db="${p}/antigravity-cli/conversation_summaries.db"
    _mkdb "${db}" "${CID}" "Real"
    [[ "${jmode}" == "WAL" ]] && _walify "${db}"
    mkdir -p "${p}/antigravity-cli/brain/${CID}"
    att="${FAKE_HOME}/ancestor-attacker-${op}-${jmode}"
    mkdir -p "${att}"
    for suffix in -journal -wal -shm; do printf 'victim bytes\n' >"${att}/conversation_summaries.db${suffix}"; done
    att_fp="$(_fp "${att}")$(cat "${att}"/conversation_summaries.db-*)"
    if [[ "${op}" == "rename" ]]; then
        out="$(_inject ancestor-write "${p}/antigravity-cli" "${att}" rename "${p}" "${CID}" "pwned")"; rc=$?
    else
        out="$(_inject ancestor-write "${p}/antigravity-cli" "${att}" delete "${p}" "${CID}" 1000)"; rc=$?
    fi
    assert_eq "${rc}" "1" "antigravity-cli swapped mid-${op} (${jmode}): fails"
    assert_eq "$(_fp "${att}")$(cat "${att}"/conversation_summaries.db-*)" "${att_fp}" \
        "antigravity-cli swap mid-${op} (${jmode}): ... same-named sidecars in the swapped-in dir are untouched"
    assert_eq "$(_is test -d "${p}/antigravity-cli.moved/brain/${CID}")" "yes" \
        "antigravity-cli swap mid-${op} (${jmode}): ... and no artifact is removed"
done

# An SQLite that would follow a symlinked sidecar is refused before the
# profile database is opened.
p="$(_profile sqlitefollows)"
db="${p}/antigravity-cli/conversation_summaries.db"
_mkdb "${db}" "${CID}" "Real"
mkdir -p "${p}/antigravity-cli/brain/${CID}"
out="$(_inject sqlite-follows - - rename "${p}" "${CID}" "pwned")"; rc=$?
assert_eq "${rc}" "1" "SQLite following symlinked sidecars: rename fails closed"
assert_contains "${out}" "refusing to open the AGY conversation database" "SQLite following symlinked sidecars: ... with an explicit error"
assert_eq "$(_dbtitle "${db}" "${CID}")" "Real" "SQLite following symlinked sidecars: ... the database is untouched"
assert_eq "$(_is test -e "${p}/antigravity-cli/brain/${CID}/.wrapper_title")" "no" "SQLite following symlinked sidecars: ... and no title is written"
assert_eq "$(ls -d "${TMPDIR:-/tmp}"/agy-sqlite-probe-* 2>/dev/null | wc -l | tr -d ' ')" "0" "SQLite probe leaves no temp dirs behind"

# Write coordination: every wrapper instance holds a lock on the title
# directory across read -> final re-check -> rename.
p="$(_profile lockprobe)"
mkdir -p "${p}/antigravity-cli/brain/${CID}"
out="$(_inject lock-probe "${p}/antigravity-cli/brain/${CID}" - rename "${p}" "${CID}" "Locked")"; rc=$?
assert_eq "${rc}" "0" "title rename with the boundary probe succeeds (${out})"
assert_contains "${out}" "BOUNDARY: lock held" "title: a cooperating wrapper cannot write between the final re-check and rename"

# Another wrapper holds the lock and never releases it: the rename fails
# before the index is touched.
p="$(_profile lockbusy)"
_mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Index title"
mkdir -p "${p}/antigravity-cli/brain/${CID}"
echo "Kept" >"${p}/antigravity-cli/brain/${CID}/.wrapper_title"
out="$(_inject lock-busy "${p}/antigravity-cli/brain/${CID}" - rename "${p}" "${CID}" "Blocked")"; rc=$?
assert_eq "${rc}" "1" "lock never released by another wrapper: rename fails closed"
assert_contains "${out}" "${p}/antigravity-cli/brain/${CID} is locked by another update" "lock never released: ... naming the locked path"
assert_eq "$(cat "${p}/antigravity-cli/brain/${CID}/.wrapper_title")" "Kept" "lock never released: ... title file untouched"
assert_eq "$(_dbtitle "${p}/antigravity-cli/conversation_summaries.db" "${CID}")" "Index title" "lock never released: ... and the index untouched"

# Documented residual (B-μ): the lock is advisory, and a check followed by
# rename is not a compare-and-swap. A title writer that does not take the
# lock and writes exactly between the final re-check and rename loses its
# write. Pinned so the documentation stays accurate if this ever changes.
p="$(_profile boundarywriter)"
mkdir -p "${p}/antigravity-cli/brain/${CID}"
out="$(_inject boundary-writer "${p}/antigravity-cli/brain/${CID}/.wrapper_title" - rename "${p}" "${CID}" "Wrapper title")"; rc=$?
assert_eq "${rc}" "0" "residual: non-locking title writer at the re-check/rename boundary is not detected"
assert_eq "$(cat "${p}/antigravity-cli/brain/${CID}/.wrapper_title")" "Wrapper title" "residual: ... and its write is lost (documented in B-μ)"

# Platforms without dir_fd / O_NOFOLLOW support fail closed.
p="$(_profile nocap)"
out="$(_inject no-dir-fd - - settings "${p}" "${WORK}" "${FAKE_HOME}" "" "" "")"; rc=$?
assert_eq "${rc}" "1" "missing dir_fd support fails closed"
assert_contains "${out}" "lacks no-follow directory-relative" "... with an explicit capability error"
assert_eq "$(_is test -e "${p}/antigravity-cli/settings.json")" "no" "... and creates nothing"

# ---------------------------------------------------------------------------
echo "-- backends: python3 required, jq/sqlite3 never used as unsafe fallbacks"
nopy="${FAKE_HOME}/nopy-bin"
mkdir -p "${nopy}"
for tool in realpath dirname readlink cat uname perl; do
    tool_path="$(command -v "${tool}" 2>/dev/null)" && ln -sf "${tool_path}" "${nopy}/${tool}"
done
for tool in jq sqlite3; do
    printf '#!/bin/sh\necho ran >>"%s/canary/%s-ran"\nexit 0\n' "${FAKE_HOME}" "${tool}" >"${nopy}/${tool}"
    chmod +x "${nopy}/${tool}"
done
p="$(_profile nopy)"
_mkdb "${p}/antigravity-cli/conversation_summaries.db" "${CID}" "Kept"
_valid_settings "${WORK}" >"${p}/antigravity-cli/settings.json"
before="$(_fp "${p}/antigravity-cli/settings.json")"
# shellcheck disable=SC2034  # WRAPPER_FLAGS is read by the sourced lib
out="$( cd "${WORK}" && _load && PATH="${nopy}" && hash -r && WRAPPER_FLAGS=() &&
    { _agy_validate_settings "${p}"; echo "settings_rc=$?";
      _agy_rename_conversation "${p}" "${CID}" "x"; echo "rename_rc=$?";
      _agy_delete_conversation "${p}" "${CID}"; echo "delete_rc=$?";
      _agy_list_conversations "${p}" "${WORK}" 20; echo "list_rc=$?"; } 2>&1 )"
assert_contains "${out}" "settings_rc=1" "no python3: settings check fails clearly"
assert_contains "${out}" "python3 is required" "no python3: ... naming the missing dependency"
assert_contains "${out}" "rename_rc=1" "no python3: rename fails"
assert_contains "${out}" "delete_rc=1" "no python3: delete fails"
assert_contains "${out}" "list_rc=0" "no python3: listing degrades to empty with a warning"
assert_eq "$(_fp "${p}/antigravity-cli/settings.json")" "${before}" "no python3: settings.json untouched"
assert_eq "$(_dbtitle "${p}/antigravity-cli/conversation_summaries.db" "${CID}")" "Kept" "no python3: database untouched"
assert_eq "$(_count_named "${FAKE_HOME}/canary" -ran)" "0" "no python3: jq/sqlite3 fallbacks are never invoked"

assert_no_live_client_reached
tests_summary_and_exit
