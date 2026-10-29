#!/bin/bash
# Host-side boundary tests for the agy wrapper (#44). Everything here runs on
# the host BEFORE the OS sandbox exists, against synthetic state in a fake
# HOME (no real profiles, credentials or conversations):
#   - checkout import shadowing (json.py, sqlite3.py, ...) never executes
#   - conversation list/rename/delete stay inside the resolved profile:
#     symlinked antigravity-cli/brain/conversations ancestors, database and
#     title file are refused; symlinked artifact leaves are unlinked only;
#     missing databases are never created
#   - settings.json: invalid JSON is never reset, permissions are kept,
#     predictable temp-file symlinks are inert, a symlinked settings.json is
#     written through only to the approved profile+target pair
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
    _agy_configure_sandbox_permissions "${p}" >/dev/null 2>&1
    _agy_delete_conversation "${p}" "${CID}" >/dev/null 2>&1
)
assert_eq "$(ls -A "${canary_dir}")" "" "no checkout module (json.py, sqlite3.py, ...) ran on the host"
assert_eq "$(_is test -f "${p}/antigravity-cli/settings.json")" "yes" "... while settings were still written from the checkout"
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
echo "-- settings.json: regular file handling"
_settings() { ( cd "${WORK}" && _load && WRAPPER_FLAGS=() && _agy_configure_sandbox_permissions "$@" ) 2>&1; }

p="$(_profile perms)"
printf '{"colorScheme":"dark"}\n' >"${p}/antigravity-cli/settings.json"
chmod 0640 "${p}/antigravity-cli/settings.json"
out="$(_settings "${p}")"; rc=$?
assert_eq "${rc}" "0" "existing settings.json is updated"
assert_eq "$(_mode "${p}/antigravity-cli/settings.json")" "0o640" "... keeping its permissions"
assert_contains "$(cat "${p}/antigravity-cli/settings.json")" '"colorScheme": "dark"' "... and unrelated keys"
assert_eq "$(_count_named "${p}/antigravity-cli" tmp)" "0" "... leaving no temp files"

p="$(_profile newfile)"
_settings "${p}" >/dev/null; rc=$?
assert_eq "${rc}" "0" "missing settings.json is created"
assert_eq "$(_mode "${p}/antigravity-cli/settings.json")" "0o600" "... as a private file"

for bad in '{"colorScheme": "dark",' '["not", "an", "object"]'; do
    p="$(_profile badjson)"
    printf '%s\n' "${bad}" >"${p}/antigravity-cli/settings.json"
    before="$(_fp "${p}/antigravity-cli/settings.json")"
    out="$(_settings "${p}")"; rc=$?
    assert_eq "${rc}" "1" "invalid settings.json (${bad}) fails nonzero"
    assert_eq "$(_fp "${p}/antigravity-cli/settings.json")" "${before}" "... and is not reset"
done

# The old predictable temp name (settings.json.tmp.<pid>) is inert now.
p="$(_profile tmplink)"
echo canary >"${FAKE_HOME}/canary/tmp-target"
(
    cd "${WORK}" || exit 1
    _load
    WRAPPER_FLAGS=()
    ln -s "${FAKE_HOME}/canary/tmp-target" "${p}/antigravity-cli/settings.json.tmp.$$"
    ln -s "${FAKE_HOME}/canary/tmp-target" "${p}/antigravity-cli/settings.json.tmp.${BASHPID:-$$}"
    _agy_configure_sandbox_permissions "${p}"
) >/dev/null 2>&1
assert_eq "$(cat "${FAKE_HOME}/canary/tmp-target")" "canary" "pre-created temp-file symlinks never receive settings"
assert_eq "$(_is test -L "${p}/antigravity-cli/settings.json")" "no" "... and settings.json is a regular file"

p="$(_profile nondir)"
rm -rf "${p}/antigravity-cli"
ln -s "${FAKE_HOME}/canary" "${p}/antigravity-cli"
out="$(_settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "symlinked antigravity-cli/ is refused for settings"
assert_eq "$(_is test -e "${FAKE_HOME}/canary/settings.json")" "no" "... without writing into its target"

if [[ "$(id -u)" != "0" ]]; then
    p="$(_profile rodir)"
    printf '{"a":1}\n' >"${p}/antigravity-cli/settings.json"
    before="$(_fp "${p}/antigravity-cli/settings.json")"
    chmod 0500 "${p}/antigravity-cli"
    out="$(_settings "${p}")"; rc=$?
    chmod 0700 "${p}/antigravity-cli"
    assert_eq "${rc}" "1" "unwritable antigravity-cli/ fails nonzero"
    assert_eq "$(_fp "${p}/antigravity-cli/settings.json")" "${before}" "... leaving settings.json unchanged"
else
    echo "  skip - unwritable-directory check (running as root)"
fi

# ---------------------------------------------------------------------------
echo "-- settings.json: symlink + trusted target (profile AND file approval)"
dot="${FAKE_HOME}/dotfiles/agy"
mkdir -p "${dot}"
_mklinked() {
    local p
    p="$(_profile "${1}")"
    printf '{"colorScheme":"tokyo","trustedWorkspaces":["/x"]}\n' >"${dot}/settings.json"
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
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "0" "approved profile+target: update succeeds (${out})"
assert_eq "$(readlink "${p}/antigravity-cli/settings.json")" "${dot}/settings.json" "... the symlink is preserved"
assert_contains "$(cat "${dot}/settings.json")" '"toolPermission": "always-proceed"' "... the target receives the sandbox settings"
assert_contains "$(cat "${dot}/settings.json")" '"colorScheme": "tokyo"' "... unrelated JSON is preserved"
assert_eq "$(_mode "${dot}/settings.json")" "0o644" "... target permissions are preserved"
assert_eq "$(ls -A "${dot}")" "settings.json" "... no temp file is left next to the target"

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
assert_eq "$(_fp "${dot}/settings.json")/$(_fp "${dot}/other.json")" "${before}/$(_fp "${dot}/other.json")" "... writing neither file"
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
printf '{"k":1}\n' >"${dot}/settings.json"
ln -sf "${dot}/settings.json" "${FAKE_HOME}/.gemini-first/antigravity-cli/settings.json"
ln -sf "${dot}/settings.json" "${FAKE_HOME}/.gemini-second/antigravity-cli/settings.json"
_bind_acct() {
    ( cd "${WORK}" && _load && WRAPPER_FLAGS=() && AGY_ACCOUNT="${1}" \
        AGY_SETTINGS_TRUSTED_PROFILE="${FAKE_HOME}/.gemini-first" \
        AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _bind_agy_account ) 2>&1
}
out="$(_bind_acct first)"; rc=$?
assert_eq "${rc}" "0" "account switch: approved account binds"
before="$(_fp "${dot}/settings.json")"
out="$(_bind_acct second)"; rc=$?
assert_eq "${rc}" "1" "account switch: the other account does not reuse the approval"
assert_eq "$(_fp "${dot}/settings.json")" "${before}" "account switch: ... and the target is untouched"

p="$(_mklinked dangling)"
rm -f "${dot}/settings.json"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "dangling approved symlink fails closed"
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
printf '{}\n' >"${OUTSIDE_HOME}/settings.json"
ln -s "${OUTSIDE_HOME}/settings.json" "${p}/antigravity-cli/settings.json"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${OUTSIDE_HOME}/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "approved target outside \$HOME fails closed"
assert_eq "$(cat "${OUTSIDE_HOME}/settings.json")" "{}" "... and is untouched"
p="$(_profile cred)"
mkdir -p "${FAKE_HOME}/.ssh"
printf '{}\n' >"${FAKE_HOME}/.ssh/settings.json"
ln -s "${FAKE_HOME}/.ssh/settings.json" "${p}/antigravity-cli/settings.json"
out="$(AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${FAKE_HOME}/.ssh/settings.json" _settings "${p}")"; rc=$?
assert_eq "${rc}" "1" "approved target in a credential dir fails closed"
assert_eq "$(cat "${FAKE_HOME}/.ssh/settings.json")" "{}" "... and is untouched"

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
    _agy_configure_sandbox_permissions "${p}" 2>&1 && echo CONFIGURED
)"
assert_contains "${out}" "CONFIGURED" "approval saved via the preset is honoured on reload"

# The preset that carries the approval must not be writable by the agent.
out="$(
    cd "${WORK}" || exit 1
    export XDG_CONFIG_HOME="${WORK}/.config"
    _load
    WRAPPER_FLAGS=()
    AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" \
        _agy_configure_sandbox_permissions "${p}" 2>&1
)"; rc=$?
assert_eq "${rc}" "1" "approval refused when the preset dir is inside WORKDIR"
assert_contains "${out}" "writable inside the sandbox" "... explaining that the agent could forge it"
out="$(
    cd "${WORK}" || exit 1
    _load
    WRAPPER_FLAGS=()
    AI_SANDBOX_EXTRA_RW_DIRS="/nonexistent, ~/.config" AGY_SETTINGS_TRUSTED_PROFILE="${p}" \
        AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" _agy_configure_sandbox_permissions "${p}" 2>&1
)"; rc=$?
assert_eq "${rc}" "1" "approval refused when an extra RW bind exposes the preset dir"
out="$(
    cd "${WORK}" || exit 1
    _load
    WRAPPER_FLAGS=(--bind "${FAKE_HOME}/.config" "${FAKE_HOME}/.config")
    AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" \
        _agy_configure_sandbox_permissions "${p}" 2>&1
)"; rc=$?
assert_eq "${rc}" "1" "approval refused when a wrapper --bind exposes the preset dir"

# A plugin hook that can add binds after the trust decision makes the
# preset's writability unknowable, so the approval is refused; a plugin
# without such hooks does not affect it.
for hook in _extra_post_menu_setup _extra_sandbox_setup; do
    plugin="${FAKE_HOME}/plugin-${hook}.bash"
    printf '%s() { WRAPPER_FLAGS+=(--bind "%s/.config"); bwrap_args+=(--bind "%s/.config" "%s/.config"); binds_rw+=("%s/.config"); }\n' \
        "${hook}" "${FAKE_HOME}" "${FAKE_HOME}" "${FAKE_HOME}" "${FAKE_HOME}" >"${plugin}"
    printf '{"k":1}\n' >"${dot}/settings.json"
    before="$(_fp "${dot}/settings.json")"
    out="$(
        cd "${WORK}" || exit 1
        _load
        AI_WRAPPER_EXTRA_PROFILE="${plugin}" _load_extra_profile
        WRAPPER_FLAGS=()
        AGY_SETTINGS_TRUSTED_PROFILE="${p}" AGY_SETTINGS_TRUSTED_TARGET="${dot}/settings.json" \
            _agy_configure_sandbox_permissions "${p}" 2>&1
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
        _agy_configure_sandbox_permissions "${p}" 2>&1 && echo CONFIGURED
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
        if state["calls"] == 0 and sql.lstrip().upper().startswith(("UPDATE", "DELETE")):
            state["calls"] += 1
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

# Concurrent writer once: retried, the writer's update is merged, not lost.
p="$(_profile writer)"
printf '{"a":1}\n' >"${p}/antigravity-cli/settings.json"
out="$(_inject writer-once "${p}/antigravity-cli/settings.json" - settings "${p}" "${WORK}" "${FAKE_HOME}" "" "" "")"; rc=$?
assert_eq "${rc}" "0" "concurrent writer: update retried and succeeds (${out})"
assert_contains "$(cat "${p}/antigravity-cli/settings.json")" '"writer": 1' "concurrent writer: ... its change is merged, not lost"
assert_contains "$(cat "${p}/antigravity-cli/settings.json")" '"toolPermission"' "concurrent writer: ... alongside the sandbox settings"

# A writer that never stops: give up nonzero, keep the writer's content, no temp left.
out="$(_inject writer-always "${p}/antigravity-cli/settings.json" - settings "${p}" "${WORK}" "${FAKE_HOME}" "" "" "")"; rc=$?
assert_eq "${rc}" "1" "persistent concurrent writer: fails nonzero after retries"
assert_contains "${out}" "changed while it was being updated" "persistent concurrent writer: ... explaining why"
assert_not_contains "$(cat "${p}/antigravity-cli/settings.json")" '"toolPermission"' "persistent concurrent writer: ... without overwriting it"
assert_eq "$(_count_named "${p}/antigravity-cli" agy-tmp)" "0" "persistent concurrent writer: ... and cleans up temp files"

# Parent swap of the approved target's directory between write and rename.
p="$(_mklinked parentswap)"
mkdir -p "${FAKE_HOME}/attacker"
echo '{"attacker":true}' >"${FAKE_HOME}/attacker/settings.json"
att_fp="$(_fp "${FAKE_HOME}/attacker/settings.json")"
out="$(_inject parent-swap "${dot}" "${FAKE_HOME}/attacker" settings "${p}" "${WORK}" "${FAKE_HOME}" "${p}" "${dot}/settings.json" "")"; rc=$?
assert_eq "${rc}" "1" "parent swap: approved target directory replaced mid-update fails"
assert_contains "${out}" "refusing symlinked directory ${dot}" "parent swap: ... reported on the re-walk before rename"
assert_eq "$(_fp "${FAKE_HOME}/attacker/settings.json")" "${att_fp}" "parent swap: ... the swapped-in file is untouched"
assert_eq "$(_count_named "${dot}.moved" agy-tmp)" "0" "parent swap: ... and the temp file is cleaned up"
rm -f "${dot}"; mv "${dot}.moved" "${dot}"

# antigravity-cli/ swapped for a symlink while settings.json is replaced.
p="$(_profile cliswap)"
printf '{}\n' >"${p}/antigravity-cli/settings.json"
mkdir -p "${FAKE_HOME}/cli-attacker"
out="$(_inject parent-swap "${p}/antigravity-cli" "${FAKE_HOME}/cli-attacker" settings "${p}" "${WORK}" "${FAKE_HOME}" "" "" "")"; rc=$?
assert_eq "${rc}" "1" "antigravity-cli swap mid-update fails"
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

# Write coordination: every wrapper instance holds a lock on the written
# directory across read -> final re-check -> rename.
p="$(_profile lockprobe)"
printf '{"a":1}\n' >"${p}/antigravity-cli/settings.json"
out="$(_inject lock-probe "${p}/antigravity-cli" - settings "${p}" "${WORK}" "${FAKE_HOME}" "" "" "")"; rc=$?
assert_eq "${rc}" "0" "settings update with the boundary probe succeeds (${out})"
assert_contains "${out}" "BOUNDARY: lock held" "settings: a cooperating wrapper cannot write between the final re-check and rename"
mkdir -p "${p}/antigravity-cli/brain/${CID}"
out="$(_inject lock-probe "${p}/antigravity-cli/brain/${CID}" - rename "${p}" "${CID}" "Locked")"; rc=$?
assert_eq "${rc}" "0" "title rename with the boundary probe succeeds (${out})"
assert_contains "${out}" "BOUNDARY: lock held" "title: a cooperating wrapper cannot write between the final re-check and rename"

p="$(_profile lockbusy)"
printf '{"a":1}\n' >"${p}/antigravity-cli/settings.json"
before="$(_fp "${p}/antigravity-cli/settings.json")"
out="$(_inject lock-busy "${p}/antigravity-cli" - settings "${p}" "${WORK}" "${FAKE_HOME}" "" "" "")"; rc=$?
assert_eq "${rc}" "1" "lock never released by another wrapper: settings update fails closed"
assert_contains "${out}" "locked by another update" "lock never released: ... explaining why"
assert_eq "$(_fp "${p}/antigravity-cli/settings.json")" "${before}" "lock never released: ... settings.json untouched"

# Documented residual (B-μ): the lock is advisory, and a check followed by
# rename is not a compare-and-swap. A process that does not take the lock
# and writes exactly between the final re-check and rename loses its write.
# Pinned so the documentation stays accurate if this ever changes.
p="$(_profile boundarywriter)"
printf '{"a":1}\n' >"${p}/antigravity-cli/settings.json"
out="$(_inject boundary-writer "${p}/antigravity-cli/settings.json" - settings "${p}" "${WORK}" "${FAKE_HOME}" "" "" "")"; rc=$?
assert_eq "${rc}" "0" "residual: non-locking writer at the re-check/rename boundary is not detected"
assert_not_contains "$(cat "${p}/antigravity-cli/settings.json")" "uncooperative" "residual: ... and its write is lost (documented in B-μ)"

# Platforms without dir_fd / O_NOFOLLOW support fail closed.
p="$(_profile nocap)"
out="$(_inject no-dir-fd - - settings "${p}" "${WORK}" "${FAKE_HOME}" "" "" "")"; rc=$?
assert_eq "${rc}" "1" "missing dir_fd support fails closed"
assert_contains "${out}" "lacks no-follow directory-relative" "... with an explicit capability error"
assert_eq "$(_is test -e "${p}/antigravity-cli/settings.json")" "no" "... and writes nothing"

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
printf '{"a":1}\n' >"${p}/antigravity-cli/settings.json"
before="$(_fp "${p}/antigravity-cli/settings.json")"
# shellcheck disable=SC2034  # WRAPPER_FLAGS is read by the sourced lib
out="$( cd "${WORK}" && _load && PATH="${nopy}" && hash -r && WRAPPER_FLAGS=() &&
    { _agy_configure_sandbox_permissions "${p}"; echo "settings_rc=$?";
      _agy_rename_conversation "${p}" "${CID}" "x"; echo "rename_rc=$?";
      _agy_delete_conversation "${p}" "${CID}"; echo "delete_rc=$?";
      _agy_list_conversations "${p}" "${WORK}" 20; echo "list_rc=$?"; } 2>&1 )"
assert_contains "${out}" "settings_rc=1" "no python3: settings update fails clearly"
assert_contains "${out}" "python3 is required" "no python3: ... naming the missing dependency"
assert_contains "${out}" "rename_rc=1" "no python3: rename fails"
assert_contains "${out}" "delete_rc=1" "no python3: delete fails"
assert_contains "${out}" "list_rc=0" "no python3: listing degrades to empty with a warning"
assert_eq "$(_fp "${p}/antigravity-cli/settings.json")" "${before}" "no python3: settings.json untouched"
assert_eq "$(_dbtitle "${p}/antigravity-cli/conversation_summaries.db" "${CID}")" "Kept" "no python3: database untouched"
assert_eq "$(_count_named "${FAKE_HOME}/canary" -ran)" "0" "no python3: jq/sqlite3 fallbacks are never invoked"

assert_no_live_client_reached
tests_summary_and_exit
