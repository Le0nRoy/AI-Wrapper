#!/bin/bash
# Antigravity-specific wrapper library. Sources ai_wrapper_lib.bash.
# Sourced by executable_agy_wrapper.bash — not executed directly.
#
# The globals below are consumed by ai_wrapper_lib.bash, not this file.
# shellcheck disable=SC2034

AI_WRAPPER_AGENT_NAME="Antigravity CLI"
AI_AGENT_COMMAND="agy"
AI_WRAPPER_AGENT_ID="agy"
# Antigravity CLI injects an initial prompt into an interactive session via
# `--prompt-interactive <prompt>` (`-i`).
AI_SYSTEM_PROMPT_FLAG="--prompt-interactive"
# Default resume flags when invoked non-interactively or when continuing the
# most recent conversation (`--continue`). In interactive mode, choosing
# `3) Resume from list` invokes `_agent_resume_args()` to present a numbered
# conversation picker backed by `<profile>/antigravity-cli/conversation_summaries.db`
# (and `brain/*/transcript.jsonl` fallback) and sets
# `AI_RESUME_ARGS=(--conversation=<id>)`.
AI_RESUME_ARGS=(--continue)
AI_RESUME_ARGS_FIRST=0

WRAPPER_DATA_DIR="${WRAPPER_DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
WRAPPER_HELP="${WRAPPER_DATA_DIR}/agy-help.md"

source "${WRAPPER_DATA_DIR}/ai_wrapper_lib.bash"

# ===== ACCOUNT SWITCHING =====
# Mirrors CODEX_ACCOUNT (codex_wrapper_lib.bash): ~/.gemini-<name>/ is
# bound at ~/.gemini inside the sandbox. "private" (or unset) = the default
# unsuffixed ~/.gemini. Antigravity CLI stores OAuth tokens, conversation
# databases, settings, and global skills inside ~/.gemini, so no separate
# top-level file bind is needed. Persisted per-workdir by the preset mechanism.
_AI_SETTINGS_LIST+=(
    "AGY_ACCOUNT|str|private|info|Account profile|Which ~/.gemini-<name>/ credential profile to use. 'private' = default ~/.gemini. Type a profile name, or 'private' to reset.|account"
)

# Export the default so the settings table shows "private" rather than
# "<unset>" (str entries don't substitute DEFAULT).
export AGY_ACCOUNT="${AGY_ACCOUNT:-private}"

# Active resolved profile directory set by _bind_agy_account (used by the
# interactive resume conversation picker).
_AGY_ACTIVE_PROFILE_DIR=""

# How long a conversation delete waits for a locked conversation_summaries.db
# before failing (milliseconds). Shared by the python3 and sqlite3 backends.
AGY_DEFAULT_DB_BUSY_TIMEOUT_MS=1000

# List available account profile names (suffixes of ~/.gemini-<name>/),
# one per line.
_agy_list_account_profiles() {
    local dir name
    for dir in "${HOME}/.gemini-"*/; do
        [[ -d "${dir}" ]] || continue
        name="${dir#"${HOME}/.gemini-"}"
        name="${name%/}"
        [[ "${name}" =~ ^[a-zA-Z0-9_-]+$ ]] && printf '%s\n' "${name}"
    done
}

# List saved top-level conversations for `<profile_dir>` as tab-separated lines:
#   <conversation_id>\t<timestamp>\t<steps>\t<workspace_tag>\t<title>
# Reads `<profile_dir>/antigravity-cli/conversation_summaries.db` first and
# falls back to scanning `<profile_dir>/antigravity-cli/brain/*` transcripts
# for any conversation not yet indexed in SQLite. Conversations matching
# `<workdir>` (or a parent/child worktree path) sort first, newest-first.
_agy_list_conversations() {
    local profile_dir="${1}"
    local workdir="${2}"
    local limit="${3:-20}"
    local cli_dir="${profile_dir}/antigravity-cli"
    [[ -d "${cli_dir}" ]] || return 0

    if command -v python3 >/dev/null 2>&1; then
        {
            if [[ "${AI_WRAPPER_DEBUG:-0}" == "1" ]]; then
                python3 - "${cli_dir}" "${workdir}" "${limit}"
            else
                python3 - "${cli_dir}" "${workdir}" "${limit}" 2>/dev/null
            fi
        } <<'PY'
import glob, json, os, re, sqlite3, sys
from urllib.parse import unquote, urlparse

cli_dir, workdir, limit = sys.argv[1], os.path.normpath(sys.argv[2]), int(sys.argv[3])
db_path = os.path.join(cli_dir, "conversation_summaries.db")
brain_dir = os.path.join(cli_dir, "brain")

def clean_one_line(text, max_len=72):
    if not text:
        return ""
    for line in str(text).splitlines():
        line = re.sub(r"\s+", " ", line).strip()
        if line:
            return line[: max_len - 1] + "…" if len(line) > max_len else line
    return ""

def fmt_time(ts):
    if not ts:
        return "unknown-time"
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})", str(ts).strip())
    return f"{m.group(1)} {m.group(2)}" if m else str(ts).strip()[:16]

def classify_workspaces(uris_raw):
    paths = []
    if uris_raw:
        try:
            parsed = json.loads(uris_raw)
            if isinstance(parsed, list):
                for u in parsed:
                    if isinstance(u, str):
                        if u.startswith("file://"):
                            paths.append(os.path.normpath(unquote(urlparse(u).path)))
                        else:
                            paths.append(os.path.normpath(u))
        except Exception:
            pass
    if not paths:
        return (1, "-")
    for p in paths:
        if p == workdir:
            return (0, "here")
    for p in paths:
        if workdir.startswith(p + "/") or p.startswith(workdir + "/"):
            return (1, os.path.basename(p) or p)
    return (2, os.path.basename(paths[0]) or paths[0])

def read_override_title(cid):
    tfile = os.path.join(brain_dir, cid, ".wrapper_title")
    if os.path.isfile(tfile):
        try:
            with open(tfile, "r", encoding="utf-8", errors="replace") as f:
                return clean_one_line(f.read())
        except Exception:
            pass
    return ""

records = {}
if os.path.isfile(db_path):
    try:
        conn = sqlite3.connect(db_path)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT conversation_id, title, preview, step_count,
                   last_modified_time, workspace_uris,
                   parent_conversation_id, nesting_depth
            FROM conversation_summaries
            WHERE (parent_conversation_id = '' OR parent_conversation_id IS NULL)
              AND (nesting_depth = 0 OR nesting_depth IS NULL)
            ORDER BY last_modified_time DESC
            """
        )
        for cid, title, preview, steps, mtime, ws_uris, parent_id, depth in cur.fetchall():
            if not cid:
                continue
            rank, ws_tag = classify_workspaces(ws_uris)
            label = (
                read_override_title(cid)
                or clean_one_line(title)
                or clean_one_line(preview)
                or "Untitled conversation"
            )
            records[cid] = {
                "cid": cid,
                "rank": rank,
                "sort_ts": str(mtime or ""),
                "ts": fmt_time(mtime),
                "steps": int(steps or 0),
                "ws_tag": ws_tag or "-",
                "title": label,
            }
        conn.close()
    except Exception:
        pass

if os.path.isdir(brain_dir):
    for entry in sorted(glob.glob(os.path.join(brain_dir, "*"))):
        cid = os.path.basename(entry)
        if cid in records or not os.path.isdir(entry):
            continue
        tpath = os.path.join(entry, ".system_generated", "logs", "transcript.jsonl")
        override_title = read_override_title(cid)
        if not os.path.isfile(tpath) and not override_title:
            continue
        title = override_title
        last_ts = ""
        steps = 0
        if os.path.isfile(tpath):
            try:
                with open(tpath, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        steps += 1
                        try:
                            obj = json.loads(line)
                        except Exception:
                            continue
                        if obj.get("created_at"):
                            last_ts = str(obj["created_at"])
                        if not title and obj.get("type") == "USER_INPUT":
                            c = str(obj.get("content", ""))
                            m = re.search(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", c, re.S)
                            title = clean_one_line(m.group(1) if m else c)
            except Exception:
                continue
        records[cid] = {
            "cid": cid,
            "rank": 1,
            "sort_ts": last_ts,
            "ts": fmt_time(last_ts),
            "steps": steps,
            "ws_tag": "-",
            "title": title or "Untitled conversation",
        }

ordered = sorted(
    records.values(),
    key=lambda r: (r["rank"], "" if not r["sort_ts"] else "".join(chr(255 - ord(c)) for c in r["sort_ts"][:32])),
)[:limit]

for r in ordered:
    print(f"{r['cid']}\t{r['ts']}\t{r['steps']}\t{r['ws_tag']}\t{r['title']}")
PY
        return 0
    fi

    if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${cli_dir}/conversation_summaries.db" ]]; then
        sqlite3 -separator $'\t' "${cli_dir}/conversation_summaries.db" \
            "SELECT conversation_id, substr(last_modified_time, 1, 16), step_count, '-', CASE WHEN title != '' THEN replace(replace(title, char(10), ' '), char(9), ' ') ELSE 'Untitled conversation' END FROM conversation_summaries WHERE (parent_conversation_id = '' OR parent_conversation_id IS NULL) AND (nesting_depth = 0 OR nesting_depth IS NULL) ORDER BY last_modified_time DESC LIMIT ${limit};" 2>/dev/null || true
    fi
}

# Rename a saved conversation in `<profile_dir>/antigravity-cli`.
# Updates `conversation_summaries.db` (when present) and writes
# `brain/<cid>/.wrapper_title` so transcript-only fallback entries and
# subsequent picker renders reflect the custom title.
_agy_rename_conversation() {
    local profile_dir="${1}"
    local cid="${2}"
    local new_title="${3}"

    if [[ -z "${cid}" || ! "${cid}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        wrapper_log "ERROR" "Invalid conversation ID: '${cid}'"
        return 1
    fi
    new_title="${new_title//$'\r'/ }"
    new_title="${new_title//$'\n'/ }"
    new_title="${new_title//$'\t'/ }"
    new_title="${new_title#"${new_title%%[![:space:]]*}"}"
    new_title="${new_title%"${new_title##*[![:space:]]}"}"
    if [[ -z "${new_title}" ]]; then
        wrapper_log "ERROR" "New title cannot be empty."
        return 1
    fi

    local cli_dir="${profile_dir}/antigravity-cli"
    local db_path="${cli_dir}/conversation_summaries.db"
    local brain_conv_dir="${cli_dir}/brain/${cid}"

    if [[ -d "${brain_conv_dir}" && ! -L "${brain_conv_dir}" ]]; then
        printf '%s\n' "${new_title}" >"${brain_conv_dir}/.wrapper_title" 2>/dev/null || true
    fi

    if [[ -f "${db_path}" ]]; then
        if command -v python3 >/dev/null 2>&1; then
            python3 - "${db_path}" "${cid}" "${new_title}" <<'PY' 2>/dev/null || return 1
import sqlite3, sys
db_path, cid, new_title = sys.argv[1], sys.argv[2], sys.argv[3]
conn = sqlite3.connect(db_path)
conn.execute("UPDATE conversation_summaries SET title = ? WHERE conversation_id = ?", (new_title, cid))
conn.commit()
conn.close()
PY
        elif command -v sqlite3 >/dev/null 2>&1; then
            local esc_title="${new_title//\'/\'\'}"
            local esc_cid="${cid//\'/\'\'}"
            sqlite3 "${db_path}" "UPDATE conversation_summaries SET title = '${esc_title}' WHERE conversation_id = '${esc_cid}';" 2>/dev/null || return 1
        fi
    elif [[ ! -d "${brain_conv_dir}" ]]; then
        mkdir -p "${brain_conv_dir}" 2>/dev/null || return 1
        printf '%s\n' "${new_title}" >"${brain_conv_dir}/.wrapper_title" 2>/dev/null || return 1
    fi
    return 0
}

# Delete a saved conversation (and any child subagent records) from
# `<profile_dir>/antigravity-cli/conversation_summaries.db`, `brain/<cid>`,
# and `conversations/<cid>*`. The index is updated first; when that fails
# (locked/read-only/corrupt DB, no SQLite client) no artifacts are touched.
# Returns 1 when the index update or any artifact removal fails.
_agy_delete_conversation() {
    local profile_dir="${1}"
    local cid="${2}"

    if [[ -z "${cid}" || ! "${cid}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        wrapper_log "ERROR" "Invalid conversation ID: '${cid}'"
        return 1
    fi

    local cli_dir="${profile_dir}/antigravity-cli"
    local db_path="${cli_dir}/conversation_summaries.db"
    local -a ids_to_remove=("${cid}")
    local busy_timeout_ms="${AGY_DB_BUSY_TIMEOUT_MS:-${AGY_DEFAULT_DB_BUSY_TIMEOUT_MS}}"

    if [[ ! "${busy_timeout_ms}" =~ ^[0-9]+$ ]]; then
        wrapper_log "ERROR" "Invalid AGY_DB_BUSY_TIMEOUT_MS: '${busy_timeout_ms}' (expected milliseconds)"
        return 1
    fi

    if [[ -f "${db_path}" ]]; then
        local db_out="" db_err=""
        if command -v python3 >/dev/null 2>&1; then
            if ! db_out="$(python3 - "${db_path}" "${cid}" "${busy_timeout_ms}" 2>&1 <<'PY'
import sqlite3, sys
db_path, cid, busy_timeout_ms = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    conn = sqlite3.connect(db_path, timeout=busy_timeout_ms / 1000)
    with conn:
        cur = conn.cursor()
        cur.execute("SELECT conversation_id FROM conversation_summaries WHERE parent_conversation_id = ?", (cid,))
        children = [r[0] for r in cur.fetchall() if r and r[0]]
        cur.execute("DELETE FROM conversation_summaries WHERE conversation_id = ? OR parent_conversation_id = ?", (cid, cid))
    conn.close()
except sqlite3.Error as exc:
    sys.stderr.write("%s\n" % exc)
    sys.exit(1)
for c in children:
    print(c)
PY
            )"; then
                db_err="${db_out:-python3 failed}"
            fi
        elif command -v sqlite3 >/dev/null 2>&1; then
            local esc_cid="${cid//\'/\'\'}"
            if ! db_err="$(sqlite3 -cmd ".timeout ${busy_timeout_ms}" "${db_path}" "DELETE FROM conversation_summaries WHERE conversation_id = '${esc_cid}' OR parent_conversation_id = '${esc_cid}';" 2>&1)"; then
                db_err="${db_err:-sqlite3 failed}"
            else
                db_err=""
            fi
        else
            db_err="neither python3 nor sqlite3 is available"
        fi
        if [[ -n "${db_err}" ]]; then
            wrapper_log "ERROR" "Failed to update ${db_path} for conversation '${cid}': ${db_err}"
            return 1
        fi
        local child_id
        while IFS= read -r child_id; do
            [[ -n "${child_id}" && "${child_id}" =~ ^[a-zA-Z0-9_-]+$ ]] && ids_to_remove+=("${child_id}")
        done <<<"${db_out}"
    fi

    local target_id target_path failed=0
    for target_id in "${ids_to_remove[@]}"; do
        [[ -n "${target_id}" && "${target_id}" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        for target_path in \
            "${cli_dir}/brain/${target_id}" \
            "${cli_dir}/conversations/${target_id}" \
            "${cli_dir}/conversations/${target_id}.pb" \
            "${cli_dir}/conversations/${target_id}.json"
        do
            [[ -L "${target_path}" || -e "${target_path}" ]] || continue
            if [[ -d "${target_path}" && ! -L "${target_path}" ]]; then
                rm -rf "${target_path}" 2>/dev/null
            else
                rm -f "${target_path}" 2>/dev/null
            fi
            if [[ -L "${target_path}" || -e "${target_path}" ]]; then
                wrapper_log "ERROR" "Failed to remove ${target_path}"
                failed=1
            fi
        done
    done
    return "${failed}"
}

# Resolve a user token (1-based list number or UUID / prefix) against the
# current picker's `conv_ids` array. Sets `_agy_resolved_cid` and
# `_agy_resolved_idx` (0-based, or -1 if external UUID).
_agy_resolve_picker_target() {
    local token="${1}"
    shift
    local -a ids=("$@")
    _agy_resolved_cid=""
    _agy_resolved_idx=-1

    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    [[ -n "${token}" ]] || return 1

    if [[ "${token}" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#ids[@]} )); then
        _agy_resolved_idx=$((token - 1))
        _agy_resolved_cid="${ids[${_agy_resolved_idx}]}"
        return 0
    fi

    local i=0 matched="" matched_idx=-1 candidate
    for candidate in "${ids[@]}"; do
        if [[ "${candidate}" == "${token}"* ]]; then
            if [[ -z "${matched}" ]]; then
                matched="${candidate}"
                matched_idx=${i}
            else
                matched="ambiguous"
                break
            fi
        fi
        i=$((i + 1))
    done
    if [[ -n "${matched}" && "${matched}" != "ambiguous" ]]; then
        _agy_resolved_cid="${matched}"
        _agy_resolved_idx=${matched_idx}
        return 0
    fi
    return 1
}

# Resolve which profile directory is active for this session.
_agy_resolve_profile_dir() {
    if [[ -n "${_AGY_ACTIVE_PROFILE_DIR:-}" ]]; then
        printf '%s\n' "${_AGY_ACTIVE_PROFILE_DIR}"
        return 0
    fi
    local account="${AGY_ACCOUNT:-private}"
    [[ "${account}" == "private" ]] && account=""
    local dir="${HOME}/.gemini"
    [[ -n "${account}" ]] && dir="${HOME}/.gemini-${account}"
    _realpath "${dir}" 2>/dev/null || printf '%s\n' "${dir}"
}

# Hook invoked by `run_agent_session "resume"` (ai_wrapper_lib.bash).
# In interactive mode (or when AGY_RESUME_PICK / AGY_RESUME_INTERACTIVE is set
# for tests), lists saved conversations from the active Antigravity profile and
# lets the user pick one to resume via `--conversation=<id>`, rename (`r`),
# delete (`d`), or press `c` for `--continue`.
# In non-interactive mode without AGY_RESUME_PICK / AGY_RESUME_INTERACTIVE,
# keeps `AI_RESUME_ARGS=(--continue)`.
_agent_resume_args() {
    if [[ -z "${AGY_RESUME_PICK+x}" && "${AGY_RESUME_INTERACTIVE:-0}" != "1" ]] && { [[ ! -t 0 ]] || [[ ! -t 1 ]]; }; then
        AI_RESUME_ARGS=(--continue)
        return 0
    fi

    local profile_dir wd
    profile_dir="$(_agy_resolve_profile_dir)"
    wd="$(_realpath "$(pwd -P)" 2>/dev/null)" || wd="$(pwd -P)"

    local scripted_mode=0
    local scripted_buf=""
    local scripted_has_buf=0
    if [[ -n "${AGY_RESUME_PICK+x}" ]]; then
        scripted_mode=1
        scripted_buf="${AGY_RESUME_PICK}"
        scripted_has_buf=1
    elif [[ "${AGY_RESUME_INTERACTIVE:-0}" == "1" ]]; then
        scripted_mode=1
    fi

    local out_fd="/dev/tty"
    if (( scripted_mode == 1 )) || [[ ! -w "/dev/tty" ]]; then
        out_fd="/dev/stdout"
    fi

    # Read one prompt response from AGY_RESUME_PICK (line-by-line), test stdin,
    # or /dev/tty.
    _agy_picker_read() {
        local _prompt="${1:-}"
        if [[ -n "${AGY_RESUME_PICK+x}" ]]; then
            if (( scripted_has_buf == 0 )); then
                return 1
            fi
            [[ -n "${_prompt}" ]] && printf '%s\n' "${_prompt}" >"${out_fd}"
            if [[ "${scripted_buf}" == *$'\n'* ]]; then
                _agy_picker_line="${scripted_buf%%$'\n'*}"
                scripted_buf="${scripted_buf#*$'\n'}"
            else
                _agy_picker_line="${scripted_buf}"
                scripted_buf=""
                scripted_has_buf=0
            fi
            return 0
        fi
        [[ -n "${_prompt}" ]] && printf '%s' "${_prompt}" >"${out_fd}"
        if [[ "${AGY_RESUME_INTERACTIVE:-0}" == "1" || ! -r "/dev/tty" ]]; then
            read -r _agy_picker_line
        else
            read -r _agy_picker_line </dev/tty
        fi
    }

    local -a conv_ids=() conv_titles=() conv_lines=()
    local cid ts steps ws_tag title tag_suffix short_id idx

    while true; do
        conv_ids=()
        conv_titles=()
        conv_lines=()
        idx=0
        while IFS=$'\t' read -r cid ts steps ws_tag title; do
            [[ -n "${cid}" ]] || continue
            idx=$((idx + 1))
            conv_ids+=("${cid}")
            conv_titles+=("${title}")
            short_id="${cid%%-*}"
            tag_suffix=""
            if [[ -n "${ws_tag}" && "${ws_tag}" != "here" && "${ws_tag}" != "-" ]]; then
                tag_suffix=" [${ws_tag}]"
            fi
            conv_lines+=("$(printf '  %2d) %s  %s (%s steps)%s [%s]' "${idx}" "${ts}" "${title}" "${steps}" "${tag_suffix}" "${short_id}")")
        done < <(_agy_list_conversations "${profile_dir}" "${wd}" 20)

        if [[ ${#conv_ids[@]} -eq 0 ]]; then
            wrapper_log "INFO" "No saved conversations found in ${profile_dir}; continuing with --continue."
            AI_RESUME_ARGS=(--continue)
            return 0
        fi

        {
            echo ""
            echo "Saved Antigravity conversations:"
            local line
            for line in "${conv_lines[@]}"; do
                echo "${line}"
            done
            echo "   c) Continue most recent (--continue)"
            echo "   r) Rename a conversation (e.g. 'r 1 New title' or 'r')"
            echo "   d) Delete conversation(s) (e.g. 'd 2', 'd 1,3' or 'd')"
            echo "   q) Cancel"
            echo ""
        } >"${out_fd}"

        local choice
        while true; do
            _agy_picker_read "Select conversation [1-${#conv_ids[@]}, r, d, c, q] (Enter = 1): " || return 1
            choice="${_agy_picker_line}"
            choice="${choice#"${choice%%[![:space:]]*}"}"
            choice="${choice%"${choice##*[![:space:]]}"}"

            case "${choice}" in
                "")
                    AI_RESUME_ARGS=("--conversation=${conv_ids[0]}")
                    return 0
                    ;;
                c|C)
                    AI_RESUME_ARGS=(--continue)
                    return 0
                    ;;
                q|Q)
                    echo "Cancelled." >"${out_fd}"
                    return 1
                    ;;
                r|R|rename|r[[:space:]]*|R[[:space:]]*|rename[[:space:]]*)
                    local r_rest="" r_target="" r_title=""
                    if [[ "${choice}" == *[[:space:]]* ]]; then
                        r_rest="${choice#*[[:space:]]}"
                        r_rest="${r_rest#"${r_rest%%[![:space:]]*}"}"
                        if [[ "${r_rest}" == *[[:space:]]* ]]; then
                            r_target="${r_rest%%[[:space:]]*}"
                            r_title="${r_rest#*[[:space:]]}"
                            r_title="${r_title#"${r_title%%[![:space:]]*}"}"
                        else
                            r_target="${r_rest}"
                        fi
                    fi
                    if [[ -z "${r_target}" ]]; then
                        _agy_picker_read "Conversation to rename [1-${#conv_ids[@]} or ID]: " || return 1
                        r_target="${_agy_picker_line}"
                    fi
                    if ! _agy_resolve_picker_target "${r_target}" "${conv_ids[@]}"; then
                        echo "Invalid conversation: '${r_target}'." >"${out_fd}"
                        continue
                    fi
                    local target_cid="${_agy_resolved_cid}"
                    if [[ -z "${r_title}" ]]; then
                        _agy_picker_read "New title for [${target_cid%%-*}]: " || return 1
                        r_title="${_agy_picker_line}"
                    fi
                    if _agy_rename_conversation "${profile_dir}" "${target_cid}" "${r_title}"; then
                        echo "Renamed [${target_cid%%-*}] -> '${r_title}'." >"${out_fd}"
                    else
                        echo "Failed to rename conversation [${target_cid%%-*}]." >"${out_fd}"
                    fi
                    # Refresh and re-render the list
                    break
                    ;;
                d|D|del|delete|rm|d[[:space:]]*|D[[:space:]]*|del[[:space:]]*|delete[[:space:]]*|rm[[:space:]]*)
                    local d_target=""
                    if [[ "${choice}" == *[[:space:]]* ]]; then
                        d_target="${choice#*[[:space:]]}"
                        d_target="${d_target#"${d_target%%[![:space:]]*}"}"
                    fi
                    if [[ -z "${d_target}" ]]; then
                        _agy_picker_read "Conversation(s) to delete [e.g. 1,3 or ID]: " || return 1
                        d_target="${_agy_picker_line}"
                    fi
                    # Tokenise on comma (matching show_settings_menu in
                    # ai_wrapper_lib.bash): whitespace around tokens is
                    # ignored, and a single bad token aborts the batch so
                    # typos never cause partial deletion.
                    local -a _del_raw=() del_cids=() del_titles=() del_shorts=()
                    local tok del_ok=1 existing_cid dup
                    IFS=',' read -r -a _del_raw <<<"${d_target}"
                    for tok in "${_del_raw[@]}"; do
                        tok="${tok#"${tok%%[![:space:]]*}"}"
                        tok="${tok%"${tok##*[![:space:]]}"}"
                        [[ -z "${tok}" ]] && continue
                        if ! _agy_resolve_picker_target "${tok}" "${conv_ids[@]}"; then
                            echo "Invalid conversation: '${tok}'." >"${out_fd}"
                            del_ok=0
                            break
                        fi
                        dup=0
                        for existing_cid in "${del_cids[@]:-}"; do
                            if [[ "${existing_cid}" == "${_agy_resolved_cid}" ]]; then
                                dup=1
                                break
                            fi
                        done
                        if (( dup == 0 )); then
                            del_cids+=("${_agy_resolved_cid}")
                            del_titles+=("${conv_titles[${_agy_resolved_idx}]:-${_agy_resolved_cid}}")
                            del_shorts+=("[${_agy_resolved_cid%%-*}]")
                        fi
                    done
                    if (( del_ok == 0 )) || (( ${#del_cids[@]} == 0 )); then
                        continue
                    fi
                    local confirm="${AGY_RESUME_CONFIRM:-}"
                    if [[ -z "${confirm}" ]]; then
                        if (( ${#del_cids[@]} == 1 )); then
                            _agy_picker_read "Delete '${del_titles[0]}' ${del_shorts[0]}? [y/N]: " || return 1
                        else
                            _agy_picker_read "Delete ${#del_cids[@]} conversations (${del_shorts[*]})? [y/N]: " || return 1
                        fi
                        confirm="${_agy_picker_line}"
                    fi
                    case "${confirm}" in
                        y|Y|yes|YES)
                            local del_cid del_failed=0
                            local -a del_done=()
                            for del_cid in "${del_cids[@]}"; do
                                if _agy_delete_conversation "${profile_dir}" "${del_cid}"; then
                                    del_done+=("[${del_cid%%-*}]")
                                else
                                    echo "Failed to delete conversation [${del_cid%%-*}]." >"${out_fd}"
                                    del_failed=1
                                fi
                            done
                            if (( del_failed == 0 )); then
                                if (( ${#del_cids[@]} == 1 )); then
                                    echo "Deleted conversation ${del_shorts[0]}." >"${out_fd}"
                                else
                                    echo "Deleted ${#del_cids[@]} conversations (${del_shorts[*]})." >"${out_fd}"
                                fi
                            elif (( ${#del_done[@]} > 0 )); then
                                echo "Deleted ${#del_done[@]} of ${#del_cids[@]} conversations (${del_done[*]})." >"${out_fd}"
                            fi
                            # Refresh and re-render the list
                            break
                            ;;
                        *)
                            echo "Deletion cancelled." >"${out_fd}"
                            continue
                            ;;
                    esac
                    ;;
                *)
                    if _agy_resolve_picker_target "${choice}" "${conv_ids[@]}"; then
                        AI_RESUME_ARGS=("--conversation=${_agy_resolved_cid}")
                        return 0
                    fi
                    if [[ "${choice}" =~ ^[0-9a-fA-F-]{8,}$ ]]; then
                        AI_RESUME_ARGS=("--conversation=${choice}")
                        return 0
                    fi
                    echo "Invalid selection: '${choice}'." >"${out_fd}"
                    ;;
            esac
        done
    done
}

# Ensure the active Antigravity profile directory has full autonomy within
# the outer OS sandbox (bubblewrap / Seatbelt):
#   - toolPermission="always-proceed" & artifactReviewPolicy="always-proceed"
#     so tool calls and artifact edits do not block on interactive prompts
#   - allowNonWorkspaceAccess=true so extra sandbox-bound paths (/tmp, ~/bin,
#     AI_SANDBOX_EXTRA_*_DIRS, git worktree common dirs) are accessible
#   - enableTerminalSandbox=false because agy is already confined by the
#     outer ai-wrapper OS sandbox (nested bwrap/sandbox-exec fails or
#     conflicts with outer bind mounts)
#   - trustedWorkspaces includes the resolved WORKDIR so agy does not
#     prompt for workspace trust on launch
# Existing user settings (colorScheme, vimInsertFirst, editorMode, etc.)
# in settings.json are preserved.
_agy_configure_sandbox_permissions() {
    local profile_dir="${1}"
    local cli_dir="${profile_dir}/antigravity-cli"
    local settings_file="${cli_dir}/settings.json"
    local wd

    _wrapper_check_config_symlink "${cli_dir}" || return 1
    if [[ -e "${cli_dir}" && ! -d "${cli_dir}" ]]; then
        echo "ERROR: ${cli_dir} exists but is not a directory." >&2
        return 1
    fi
    if ! mkdir -p "${cli_dir}"; then
        echo "ERROR: failed to create ${cli_dir}" >&2
        return 1
    fi

    _wrapper_check_config_symlink "${settings_file}" || return 1
    if [[ -e "${settings_file}" && ! -f "${settings_file}" ]]; then
        echo "ERROR: ${settings_file} exists but is not a regular file." >&2
        return 1
    fi

    wd="$(_realpath "$(pwd -P)" 2>/dev/null)" || wd="$(pwd -P)"
    local tmp="${settings_file}.tmp.$$"

    if command -v jq >/dev/null 2>&1; then
        local src_json="{}"
        if [[ -s "${settings_file}" ]]; then
            src_json="$(cat "${settings_file}" 2>/dev/null)" || src_json="{}"
        fi
        if printf '%s\n' "${src_json}" | jq --arg wd "${wd}" '
            (if type == "object" then . else {} end)
            | .toolPermission = "always-proceed"
            | .artifactReviewPolicy = "always-proceed"
            | .allowNonWorkspaceAccess = true
            | .enableTerminalSandbox = false
            | .trustedWorkspaces = (
                ((.trustedWorkspaces // []) | if type == "array" then . else [] end)
                + [$wd] | unique
              )
        ' >"${tmp}" 2>/dev/null && [[ -s "${tmp}" ]]; then
            mv -f "${tmp}" "${settings_file}" 2>/dev/null || { rm -f "${tmp}"; return 1; }
            return 0
        fi
        rm -f "${tmp}" 2>/dev/null
    fi

    if command -v python3 >/dev/null 2>&1; then
        if python3 - "${settings_file}" "${tmp}" "${wd}" <<'PY' 2>/dev/null
import json, os, sys
settings_path, tmp_path, wd = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
if os.path.isfile(settings_path) and os.path.getsize(settings_path) > 0:
    try:
        with open(settings_path, "r", encoding="utf-8") as f:
            loaded = json.load(f)
            if isinstance(loaded, dict):
                data = loaded
    except Exception:
        data = {}
data["toolPermission"] = "always-proceed"
data["artifactReviewPolicy"] = "always-proceed"
data["allowNonWorkspaceAccess"] = True
data["enableTerminalSandbox"] = False
tw = data.get("trustedWorkspaces")
if not isinstance(tw, list):
    tw = []
if wd not in tw:
    tw.append(wd)
data["trustedWorkspaces"] = tw
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
        then
            mv -f "${tmp}" "${settings_file}" 2>/dev/null || { rm -f "${tmp}"; return 1; }
            return 0
        fi
        rm -f "${tmp}" 2>/dev/null
    fi

    if [[ ! -f "${settings_file}" ]]; then
        local wd_escaped="${wd//\\/\\\\}"
        wd_escaped="${wd_escaped//\"/\\\"}"
        cat >"${tmp}" <<EOF
{
  "toolPermission": "always-proceed",
  "artifactReviewPolicy": "always-proceed",
  "allowNonWorkspaceAccess": true,
  "enableTerminalSandbox": false,
  "trustedWorkspaces": [
    "${wd_escaped}"
  ]
}
EOF
        mv -f "${tmp}" "${settings_file}" 2>/dev/null || { rm -f "${tmp}"; return 1; }
    fi
    return 0
}

# Sync managed ai-wrapper skills into <profile_dir>/config/skills/ so
# Antigravity CLI discovers `orchestrator-mode` and companion skills in
# every profile (default ~/.gemini and named ~/.gemini-<account>) without
# relying on symlinks outside the sandbox mount.
_agy_sync_profile_skills() {
    local profile_dir="${1}"
    local skills_src="${HOME}/ai-wrapper/.agents/skills"
    if [[ ! -d "${skills_src}" ]]; then
        local repo_skills
        repo_skills="$(_realpath "${WRAPPER_DATA_DIR}/../../dot_agents/skills" 2>/dev/null)" || repo_skills=""
        [[ -n "${repo_skills}" && -d "${repo_skills}" ]] && skills_src="${repo_skills}"
    fi
    [[ -d "${skills_src}" ]] || return 0

    local config_dir="${profile_dir}/config"
    local skills_dst="${config_dir}/skills"
    local marker=".setup_skills_managed"

    _wrapper_check_config_symlink "${config_dir}" || return 1
    if [[ -e "${config_dir}" && ! -d "${config_dir}" ]]; then
        echo "ERROR: ${config_dir} exists but is not a directory." >&2
        return 1
    fi
    _wrapper_check_config_symlink "${skills_dst}" || return 1
    if [[ -e "${skills_dst}" && ! -d "${skills_dst}" ]]; then
        echo "ERROR: ${skills_dst} exists but is not a directory." >&2
        return 1
    fi
    mkdir -p "${skills_dst}" || return 1

    local skill_path name src dest
    for skill_path in "${skills_src}"/*/; do
        [[ -d "${skill_path}" ]] || continue
        name="$(basename "${skill_path}")"
        src="${skill_path%/}"
        dest="${skills_dst}/${name}"

        # Never clobber symlinks or user-managed skill directories (those
        # without our marker file).
        if [[ -L "${dest}" ]]; then
            continue
        elif [[ -d "${dest}" ]]; then
            [[ -f "${dest}/${marker}" ]] || continue
        elif [[ -e "${dest}" ]]; then
            continue
        fi

        rm -rf "${dest}.new" 2>/dev/null || true
        if cp -a "${src}" "${dest}.new" 2>/dev/null; then
            printf '%s\n' "${src}" >"${dest}.new/${marker}"
            rm -rf "${dest}" 2>/dev/null || true
            mv -f "${dest}.new" "${dest}" 2>/dev/null || rm -rf "${dest}.new" 2>/dev/null
        else
            rm -rf "${dest}.new" 2>/dev/null || true
        fi
    done
    return 0
}

# Resolve AGY_ACCOUNT to the profile dir, prepare sandbox permissions +
# global skills, and append its bind (at ~/.gemini) to WRAPPER_FLAGS.
# Must run AFTER _preset_autoload and the menu — AGY_ACCOUNT isn't
# authoritative until then. Exits on invalid input, same contract as
# _bind_codex_account and _bind_claude_account.
_bind_agy_account() {
    local account="${AGY_ACCOUNT:-private}"
    [[ "${account}" == "private" ]] && account=""

    local gemini_dir
    if [[ -n "${account}" ]]; then
        if [[ ! "${account}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "ERROR: Invalid AGY_ACCOUNT '${account}': must contain only letters, digits, hyphens, underscores" >&2
            exit 1
        fi
        gemini_dir="${HOME}/.gemini-${account}"
        if [[ ! -d "${gemini_dir}" ]]; then
            echo "ERROR: Account profile directory not found: ${gemini_dir}" >&2
            echo "Available profiles: $(_agy_list_account_profiles | tr '\n' ' ')" >&2
            exit 1
        fi
        _wrapper_check_config_symlink "${gemini_dir}" || exit 1
        AI_WRAPPER_AGENT_NAME="Antigravity CLI [${account}]"
    else
        gemini_dir="${HOME}/.gemini"

        # Symlink-safety guard (same as ~/.claude and ~/.codex): refuse a
        # ~/.gemini that is a non-directory, or a symlink resolving outside
        # $HOME or into a credential dir.
        if [[ -L "${gemini_dir}" ]]; then
            _wrapper_check_config_symlink "${gemini_dir}" || exit 1
        elif [[ -e "${gemini_dir}" && ! -d "${gemini_dir}" ]]; then
            echo "ERROR: ${gemini_dir} exists but is not a directory or symlink. Move or remove it before launching." >&2
            exit 1
        fi

        if ! mkdir -p "${gemini_dir}"; then
            echo "ERROR: failed to create ${gemini_dir}" >&2
            exit 1
        fi
    fi

    # Bind the resolved path, never a (checked) symlink unresolved.
    local bind_src
    bind_src="$(_realpath "${gemini_dir}")" || bind_src="${gemini_dir}"
    _AGY_ACTIVE_PROFILE_DIR="${bind_src}"

    _agy_configure_sandbox_permissions "${bind_src}" || exit 1
    _agy_sync_profile_skills "${bind_src}" || exit 1

    _wrapper_add_bind "${bind_src}" "${HOME}/.gemini"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script is meant to be sourced, not executed directly." >&2
    exit 1
fi
