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
    "AGY_ACCOUNT|str|private|info|Account profile|Which ~/.gemini-<name>/ credential profile to use. 'private' = default ~/.gemini. Type a profile name, or 'private' to reset. Named profiles are Linux-only; macOS refuses them at launch.|account"
)

# No source-time `export AGY_ACCOUNT=private`: _preset_autoload treats a set
# variable as caller-set and would skip a saved account. The settings table
# shows "private" for unset via _setting_current_value's catalog default.


# Active resolved profile directory set by _bind_agy_account (used by the
# interactive resume conversation picker).
_AGY_ACTIVE_PROFILE_DIR=""

# How long a conversation delete waits for a locked conversation_summaries.db
# before failing (milliseconds).
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

# Host-side filesystem helper for the operations above the OS sandbox:
# conversation listing/rename/delete.
# It runs on the host before the sandbox exists, so:
#   - `python3 -I` keeps the CWD (a possibly hostile checkout), PYTHONPATH and
#     user site-packages off sys.path: a checkout `json.py` never executes;
#   - every path under the resolved profile is opened component by component
#     with O_NOFOLLOW and directory-relative (*at) calls, so a symlinked
#     antigravity-cli/, brain/, conversations/, database or title file is
#     refused instead of followed;
#   - the rename title file is replaced via an O_EXCL temp file + rename in
#     the verified directory, after re-checking the file and parent are
#     unchanged, while holding an advisory flock on that directory (serialises wrapper
#     instances; non-cooperating writers are not blocked, see B-μ);
#   - before any profile database is opened, a probe in a private temp dir
#     proves the linked SQLite refuses symlinked -journal/-wal/-shm files and
#     refuses to write once the database path has moved; otherwise the
#     SQLite operation is refused before it starts.
# Platforms lacking dir_fd/O_NOFOLLOW support fail closed. Python 3 is
# required for every operation but listing; there is no jq/sqlite3 fallback
# because neither can enforce the same boundary.
# Usage: _agy_host_py <list|rename|delete> ARGS...
_agy_host_py() {
    python3 -I - "$@" <<'PY'
import contextlib, errno, fcntl, json, os, re, secrets, shutil, signal, sqlite3, stat, sys, tempfile, time, traceback
from urllib.parse import unquote, urlparse

CLI_DIR_NAME = "antigravity-cli"
DB_NAME = "conversation_summaries.db"
SQLITE_SIDECAR_SUFFIXES = ("-journal", "-wal", "-shm")
TITLE_NAME = ".wrapper_title"
MAX_TITLE_BYTES = 4096
NEW_FILE_MODE = 0o600
NEW_DIR_MODE = 0o777  # narrowed by the umask, like `mkdir -p`
WRITE_LOCK_TIMEOUT_SECONDS = 10
WRITE_LOCK_POLL_SECONDS = 0.05
SQLITE_PROBE_PREFIX = "agy-sqlite-probe-"
SQLITE_PROBE_CANARY = b"agy sqlite probe canary\n"
CID_RE = re.compile(r"^[A-Za-z0-9_-]+$")
O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
DIR_OPEN_FLAGS = os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
FILE_READ_FLAGS = os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC | getattr(os, "O_NONBLOCK", 0)
TEMP_CREATE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC


class Refused(Exception):
    """A safety check failed; nothing (further) was modified."""


class ConcurrentChange(Refused):
    """The file changed between read and replace; safe to retry."""


def require_capabilities():
    missing = [name for name in ("O_NOFOLLOW", "O_DIRECTORY") if not hasattr(os, name)]
    for func in (os.open, os.stat, os.rename, os.unlink, os.mkdir, os.rmdir, os.readlink):
        if func not in os.supports_dir_fd:
            missing.append(func.__name__ + "(dir_fd)")
    if os.stat not in os.supports_follow_symlinks:
        missing.append("stat(follow_symlinks=False)")
    if os.scandir not in os.supports_fd:
        missing.append("scandir(fd)")
    if not hasattr(os, "fchdir"):
        missing.append("fchdir")
    if missing:
        raise Refused("this platform lacks no-follow directory-relative file operations ("
                      + ", ".join(missing) + "); refusing host-side AGY profile changes")


def same_file(a, b):
    return a is not None and b is not None and a.st_dev == b.st_dev and a.st_ino == b.st_ino


def leaf_stat(dir_fd, name):
    try:
        return os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def check_name(name):
    if not name or name in (".", "..") or "/" in name or "\0" in name:
        raise Refused("invalid path component: %r" % name)


def open_child_dir(parent_fd, name, display, create=False):
    """Open directory `name` under `parent_fd` without following symlinks.
    Returns None when it is missing and `create` is false."""
    check_name(name)
    st = leaf_stat(parent_fd, name)
    if st is None:
        if not create:
            return None
        try:
            os.mkdir(name, NEW_DIR_MODE, dir_fd=parent_fd)
        except FileExistsError:
            pass
        st = leaf_stat(parent_fd, name)
        if st is None:
            raise Refused("%s disappeared while it was being created" % display)
    if stat.S_ISLNK(st.st_mode):
        raise Refused("refusing symlinked directory %s" % display)
    if not stat.S_ISDIR(st.st_mode):
        raise Refused("%s exists but is not a directory" % display)
    try:
        fd = os.open(name, DIR_OPEN_FLAGS, dir_fd=parent_fd)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise Refused("%s was replaced while it was being opened" % display)
        raise
    if not same_file(os.fstat(fd), st):
        os.close(fd)
        raise Refused("%s was replaced while it was being opened" % display)
    return fd


def open_dir_path(path):
    """Open absolute `path` component by component, refusing any symlink."""
    if not os.path.isabs(path):
        raise Refused("expected an absolute path: %s" % path)
    fd = os.open("/", DIR_OPEN_FLAGS)
    display = ""
    for part in [p for p in path.split("/") if p]:
        display += "/" + part
        child = open_child_dir(fd, part, display)
        os.close(fd)
        if child is None:
            raise Refused("%s does not exist" % display)
        fd = child
    return fd


def verify_dir_still_at(path, dir_fd):
    """Re-walk `path` and confirm it still names the directory held open."""
    fd = open_dir_path(path)
    try:
        if not same_file(os.fstat(fd), os.fstat(dir_fd)):
            raise Refused("%s was replaced during the update" % path)
    finally:
        os.close(fd)


def read_regular(dir_fd, name, display, expected=None, max_bytes=None):
    """Read regular file `name` without following symlinks. Returns
    (bytes, fstat) or (None, None) when it does not exist."""
    try:
        fd = os.open(name, FILE_READ_FLAGS, dir_fd=dir_fd)
    except FileNotFoundError:
        return None, None
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise Refused("refusing symlinked file %s" % display)
        raise
    with os.fdopen(fd, "rb") as handle:
        st = os.fstat(handle.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise Refused("%s is not a regular file" % display)
        if expected is not None and not same_file(st, expected):
            raise ConcurrentChange("%s was replaced while it was being read" % display)
        data = handle.read(max_bytes) if max_bytes else handle.read()
    return data, st


def unchanged(current, expected):
    if current is None or expected is None:
        return current is None and expected is None
    return (same_file(current, expected) and stat.S_ISREG(current.st_mode)
            and current.st_size == expected.st_size
            and current.st_mtime_ns == expected.st_mtime_ns)


@contextlib.contextmanager
def dir_write_lock(dir_fd, display):
    """Hold an exclusive advisory flock on `dir_fd` for a read-modify-replace.
    Every wrapper instance takes it, so two wrappers never interleave their
    updates. It is advisory: a process that does not take it (agy itself, a
    sandboxed agent) is not blocked. A holder that never releases it makes
    the update fail after WRITE_LOCK_TIMEOUT_SECONDS instead of proceeding."""
    deadline = time.monotonic() + WRITE_LOCK_TIMEOUT_SECONDS
    while True:
        try:
            fcntl.flock(dir_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise Refused("%s is locked by another update (waited %ds); not modifying it"
                              % (display, WRITE_LOCK_TIMEOUT_SECONDS))
            time.sleep(WRITE_LOCK_POLL_SECONDS)
        except OSError as exc:
            raise Refused("cannot lock %s (%s); refusing to update it without coordinating writers"
                          % (display, exc.strerror or exc))
    try:
        yield
    finally:
        fcntl.flock(dir_fd, fcntl.LOCK_UN)


def atomic_replace(dir_fd, name, data, expected, display, verify_parent, before_commit=None):
    """Write `data` to a fresh O_EXCL temp file in `dir_fd` and rename it over
    `name`. `before_commit` runs once the temp file is written, so a failure
    to write here is reported before it makes any other change. Refuses when
    `name` no longer matches `expected` (None = absent) at the final
    re-check. This is not a compare-and-swap: a write by a process that does
    not hold dir_write_lock() landing between that re-check and the rename
    is lost (documented in B-μ). Callers hold dir_write_lock(dir_fd) across
    the read and this call."""
    mode = stat.S_IMODE(expected.st_mode) & 0o777 if expected is not None else NEW_FILE_MODE
    tmp_name = ".%s.agy-tmp-%s" % (name, secrets.token_hex(8))
    tmp_fd = os.open(tmp_name, TEMP_CREATE_FLAGS, NEW_FILE_MODE, dir_fd=dir_fd)
    renamed = False
    try:
        with os.fdopen(tmp_fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fchmod(handle.fileno(), mode)
            os.fsync(handle.fileno())
        if before_commit is not None:
            before_commit()
        if not unchanged(leaf_stat(dir_fd, name), expected):
            raise ConcurrentChange("%s changed while it was being updated; not overwriting it" % display)
        verify_parent()
        os.rename(tmp_name, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        renamed = True
    finally:
        if not renamed:
            try:
                os.unlink(tmp_name, dir_fd=dir_fd)
            except OSError:
                pass
    try:
        os.fsync(dir_fd)
    except OSError:
        pass


def remove_tree(parent_fd, name):
    """rm -rf `name` under `parent_fd`, never following symlinks."""
    fd = os.open(name, DIR_OPEN_FLAGS, dir_fd=parent_fd)
    try:
        with os.scandir(fd) as entries:
            children = [(e.name, e.is_dir(follow_symlinks=False)) for e in entries]
        for child, is_dir in children:
            if is_dir:
                remove_tree(fd, child)
            else:
                os.unlink(child, dir_fd=fd)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=parent_fd)


def verify_sqlite_opened(held_fd, expected):
    """Confirm that SQLite holds a descriptor to the verified database file
    (and not to whatever a concurrently swapped path pointed at)."""
    fd_dir = "/dev/fd" if os.path.isdir("/dev/fd") else "/proc/self/fd"
    try:
        names = os.listdir(fd_dir)
    except OSError:
        raise Refused("cannot list %s to verify which database file SQLite opened" % fd_dir)
    for fd_name in names:
        if not fd_name.isdigit() or int(fd_name) == held_fd:
            continue
        try:
            if same_file(os.fstat(int(fd_name)), expected):
                return
        except OSError:
            continue
    raise Refused("SQLite opened a different file than the verified database (path replaced concurrently?)")


def probe_sqlite_case(root, name, journal_mode, sidecar):
    """One probe: does this SQLite write through a symlinked `sidecar`
    (or, with sidecar=None, write after the database path moved)?
    Returns a description of the unsafe behaviour, or None."""
    case_dir = os.path.join(root, name)
    os.mkdir(case_dir, 0o700)
    db_path = os.path.join(case_dir, "probe.db")
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=%s" % journal_mode)
    conn.execute("CREATE TABLE t (x)")
    conn.commit()
    conn.close()
    canary = os.path.join(root, name + ".canary")
    with open(canary, "wb") as handle:
        handle.write(SQLITE_PROBE_CANARY)
    swapped_in = os.path.join(root, name + ".swapped-in")
    if sidecar is not None:
        os.symlink(canary, db_path + sidecar)
    conn = None
    wrote = False
    try:
        conn = sqlite3.connect("file:%s?mode=rw" % db_path, uri=True)
        conn.execute("SELECT count(*) FROM sqlite_master").fetchone()
        if sidecar is None:
            # Move the directory away and plant a symlink to another one,
            # as a concurrent same-UID process could do mid-transaction.
            os.rename(case_dir, case_dir + ".moved")
            os.mkdir(swapped_in, 0o700)
            os.symlink(swapped_in, case_dir)
        with conn:
            conn.execute("INSERT INTO t VALUES (1)")
        wrote = True
    except sqlite3.Error:
        pass
    finally:
        if conn is not None:
            conn.close()
    with open(canary, "rb") as handle:
        if handle.read() != SQLITE_PROBE_CANARY:
            return "writes through a symlinked %s file" % sidecar
    if sidecar is None:
        if os.listdir(swapped_in):
            return "creates rollback-journal files in a directory swapped in for the database's"
        if wrote:
            return "keeps writing after the database path moved"
    elif wrote or not os.path.islink(db_path + sidecar):
        return "accepts a symlinked %s file" % sidecar
    return None


SQLITE_PROBE_CASES = (
    ("journal", "DELETE", "-journal"),
    ("wal", "WAL", "-wal"),
    ("shm", "WAL", "-shm"),
    ("moved", "DELETE", None),
)
_sqlite_probe_passed = []


def require_safe_sqlite():
    """Refuse unless this SQLite build refuses symlinked -journal/-wal/-shm
    files (it opens them by path, with O_NOFOLLOW) and refuses writes once
    the database path has moved (SQLITE_READONLY_DBMOVED). Both are SQLite
    behaviours the helper cannot enforce itself, so they are proven on the
    running library, in a private temp dir, before any profile database is
    opened."""
    if _sqlite_probe_passed:
        return
    root = tempfile.mkdtemp(prefix=SQLITE_PROBE_PREFIX)
    try:
        for name, journal_mode, sidecar in SQLITE_PROBE_CASES:
            problem = probe_sqlite_case(root, name, journal_mode, sidecar)
            if problem:
                raise Refused("the SQLite library in use (%s) %s; refusing to open the AGY conversation database"
                              % (sqlite3.sqlite_version, problem))
    finally:
        shutil.rmtree(root, ignore_errors=True)
    _sqlite_probe_passed.append(True)


class Profile:
    """The resolved selected profile, opened without following symlinks."""

    def __init__(self, profile_dir):
        self.path = profile_dir
        self.fd = open_dir_path(profile_dir)
        self.cli_path = os.path.join(profile_dir, CLI_DIR_NAME)

    def cli(self, create=False):
        return open_child_dir(self.fd, CLI_DIR_NAME, self.cli_path, create)

    def verify_cli(self, cli_fd):
        verify_dir_still_at(self.path, self.fd)
        fd = self.cli()
        try:
            if not same_file(os.fstat(fd), os.fstat(cli_fd)):
                raise Refused("%s was replaced during the update" % self.cli_path)
        finally:
            os.close(fd)


def open_database(profile, cli_fd, readonly, timeout):
    """Open `conversation_summaries.db` in `cli_fd`. Returns (conn, held_fd)
    or (None, None) when it does not exist; never creates it."""
    db_display = os.path.join(profile.cli_path, DB_NAME)
    st = leaf_stat(cli_fd, DB_NAME)
    if st is None:
        return None, None
    if stat.S_ISLNK(st.st_mode):
        raise Refused("refusing symlinked database %s" % db_display)
    if not stat.S_ISREG(st.st_mode):
        raise Refused("%s is not a regular file" % db_display)
    require_safe_sqlite()
    for suffix in SQLITE_SIDECAR_SUFFIXES:
        side = leaf_stat(cli_fd, DB_NAME + suffix)
        if side is not None and not stat.S_ISREG(side.st_mode):
            raise Refused("refusing symlinked or non-regular SQLite file %s%s" % (db_display, suffix))
    try:
        held_fd = os.open(DB_NAME, FILE_READ_FLAGS, dir_fd=cli_fd)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise Refused("refusing symlinked database %s" % db_display)
        raise
    held_st = os.fstat(held_fd)
    if not same_file(held_st, st):
        os.close(held_fd)
        raise Refused("%s was replaced while it was being opened" % db_display)
    # Relative to the verified directory; SQLite resolves it via getcwd() and
    # opens the sidecars by path. A sidecar swapped for a symlink after the
    # check above is refused by SQLite itself (no-follow open), and a
    # directory swapped mid-transaction makes SQLite refuse the write
    # (database moved); require_safe_sqlite() proved both on this library.
    os.fchdir(cli_fd)
    conn = sqlite3.connect("file:%s?mode=%s" % (DB_NAME, "ro" if readonly else "rw"),
                           uri=True, timeout=timeout)
    try:
        conn.execute("SELECT count(*) FROM sqlite_master").fetchone()
        verify_sqlite_opened(held_fd, held_st)
    except BaseException:
        conn.close()
        os.close(held_fd)
        raise
    # held_fd stays open until exit: closing any descriptor of the database
    # file would drop SQLite's POSIX locks on it.
    return conn, held_fd


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
    match = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})", str(ts).strip())
    return "%s %s" % (match.group(1), match.group(2)) if match else str(ts).strip()[:16]


def classify_workspaces(uris_raw, workdir):
    paths = []
    if uris_raw:
        try:
            parsed = json.loads(uris_raw)
            if isinstance(parsed, list):
                for uri in parsed:
                    if isinstance(uri, str):
                        if uri.startswith("file://"):
                            paths.append(os.path.normpath(unquote(urlparse(uri).path)))
                        else:
                            paths.append(os.path.normpath(uri))
        except Exception:
            pass
    if not paths:
        return (1, "-")
    for path in paths:
        if path == workdir:
            return (0, "here")
    for path in paths:
        if workdir.startswith(path + "/") or path.startswith(workdir + "/"):
            return (1, os.path.basename(path) or path)
    return (2, os.path.basename(paths[0]) or paths[0])


def open_conversation_dir(brain_fd, brain_path, cid):
    """Conversation dir under brain/, or None when missing or a symlink
    (symlinked artifacts are never traversed)."""
    if brain_fd is None:
        return None
    try:
        return open_child_dir(brain_fd, cid, os.path.join(brain_path, cid))
    except Refused:
        return None


def read_override_title(brain_fd, brain_path, cid):
    conv_fd = open_conversation_dir(brain_fd, brain_path, cid)
    if conv_fd is None:
        return ""
    try:
        data, _ = read_regular(conv_fd, TITLE_NAME, TITLE_NAME, max_bytes=MAX_TITLE_BYTES)
        return clean_one_line(data.decode("utf-8", "replace")) if data else ""
    except (Refused, OSError):
        return ""
    finally:
        os.close(conv_fd)


def read_transcript(conv_fd, title):
    """(title, last_ts, steps, found) from .system_generated/logs/transcript.jsonl."""
    last_ts, steps = "", 0
    dir_fd = conv_fd
    for part in (".system_generated", "logs"):
        dir_fd = open_child_dir(dir_fd, part, part)
        if dir_fd is None:
            return title, last_ts, steps, False
    data, _ = read_regular(dir_fd, "transcript.jsonl", "transcript.jsonl")
    if data is None:
        return title, last_ts, steps, False
    for line in data.decode("utf-8", "replace").splitlines(True):
        steps += 1
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue
        if obj.get("created_at"):
            last_ts = str(obj["created_at"])
        if not title and obj.get("type") == "USER_INPUT":
            content = str(obj.get("content", ""))
            match = re.search(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", content, re.S)
            title = clean_one_line(match.group(1) if match else content)
    return title, last_ts, steps, True


def cmd_list(profile_dir, workdir, limit):
    limit = int(limit)
    workdir = os.path.normpath(workdir)
    profile = Profile(profile_dir)
    cli_fd = profile.cli()
    if cli_fd is None:
        return 0
    brain_path = os.path.join(profile.cli_path, "brain")
    brain_fd = open_child_dir(cli_fd, "brain", brain_path)

    records = {}
    try:
        conn, _ = open_database(profile, cli_fd, readonly=True, timeout=5)
        if conn is not None:
            cur = conn.execute(
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
            for cid, title, preview, steps, mtime, ws_uris, _parent, _depth in cur.fetchall():
                if not cid:
                    continue
                rank, ws_tag = classify_workspaces(ws_uris, workdir)
                label = (
                    (read_override_title(brain_fd, brain_path, cid) if CID_RE.match(str(cid)) else "")
                    or clean_one_line(title)
                    or clean_one_line(preview)
                    or "Untitled conversation"
                )
                records[cid] = {
                    "cid": cid, "rank": rank, "sort_ts": str(mtime or ""),
                    "ts": fmt_time(mtime), "steps": int(steps or 0),
                    "ws_tag": ws_tag or "-", "title": label,
                }
            conn.close()
    except sqlite3.Error:
        pass

    if brain_fd is not None:
        with os.scandir(brain_fd) as entries:
            candidates = sorted(e.name for e in entries if e.is_dir(follow_symlinks=False))
        for cid in candidates:
            if cid in records or not CID_RE.match(cid):
                continue
            conv_fd = open_conversation_dir(brain_fd, brain_path, cid)
            if conv_fd is None:
                continue
            override_title = read_override_title(brain_fd, brain_path, cid)
            try:
                title, last_ts, steps, found = read_transcript(conv_fd, override_title)
            except (Refused, OSError):
                continue
            finally:
                os.close(conv_fd)
            if not found and not override_title:
                continue
            records[cid] = {
                "cid": cid, "rank": 1, "sort_ts": last_ts, "ts": fmt_time(last_ts),
                "steps": steps, "ws_tag": "-", "title": title or "Untitled conversation",
            }

    ordered = sorted(
        records.values(),
        key=lambda r: (r["rank"], "" if not r["sort_ts"] else "".join(chr(255 - ord(c)) for c in r["sort_ts"][:32])),
    )[:limit]
    for rec in ordered:
        print("%s\t%s\t%s\t%s\t%s" % (rec["cid"], rec["ts"], rec["steps"], rec["ws_tag"], rec["title"]))
    return 0


def check_cid(cid):
    if not CID_RE.match(cid):
        raise Refused("invalid conversation ID: %r" % cid)


def update_index_title(conn, db_path, cid, new_title):
    """Set the index title; returns the number of rows changed."""
    try:
        with conn:
            cur = conn.execute("UPDATE conversation_summaries SET title = ? WHERE conversation_id = ?",
                               (new_title, cid))
    except sqlite3.Error as exc:
        raise Refused("cannot update the title in %s: %s" % (db_path, exc))
    finally:
        conn.close()
    return cur.rowcount


def cmd_rename(profile_dir, cid, new_title):
    """Rename in the index (when present) and in brain/<cid>/.wrapper_title,
    which the picker shows in preference to the index title. Every path is
    validated, and the title directory locked and its temp file written,
    before the index is changed."""
    check_cid(cid)
    profile = Profile(profile_dir)
    cli_fd = profile.cli()
    brain_path = os.path.join(profile.cli_path, "brain")
    conv_path = os.path.join(brain_path, cid)
    title_path = os.path.join(conv_path, TITLE_NAME)
    db_path = os.path.join(profile.cli_path, DB_NAME)
    brain_fd = open_child_dir(cli_fd, "brain", brain_path) if cli_fd is not None else None
    conv_fd = open_child_dir(brain_fd, cid, conv_path) if brain_fd is not None else None
    title_st = leaf_stat(conv_fd, TITLE_NAME) if conv_fd is not None else None
    if title_st is not None and not stat.S_ISREG(title_st.st_mode):
        raise Refused("refusing symlinked or non-regular title file %s" % title_path)

    conn = None
    if cli_fd is not None:
        conn, _ = open_database(profile, cli_fd, readonly=False, timeout=5)
    if conn is not None and conv_fd is None:
        # No conversation dir, so no title file can override the index.
        if update_index_title(conn, db_path, cid, new_title) == 0:
            raise Refused("conversation %s is not in %s and has no %s; nothing was renamed"
                          % (cid, db_path, conv_path))
        profile.verify_cli(cli_fd)
        return 0
    if conv_fd is None:
        cli_fd = profile.cli(create=True)
        brain_fd = open_child_dir(cli_fd, "brain", brain_path, create=True)
        conv_fd = open_child_dir(brain_fd, cid, conv_path, create=True)

    def update_index():
        if conn is not None:
            update_index_title(conn, db_path, cid, new_title)
            profile.verify_cli(cli_fd)
            index_updated.append(True)

    index_updated = []
    try:
        with dir_write_lock(conv_fd, conv_path):
            expected = None
            title_st = leaf_stat(conv_fd, TITLE_NAME)
            if title_st is not None:
                _, expected = read_regular(conv_fd, TITLE_NAME, title_path, expected=title_st)
            atomic_replace(conv_fd, TITLE_NAME, (new_title + "\n").encode("utf-8"), expected, title_path,
                           lambda: verify_dir_still_at(conv_path, conv_fd), before_commit=update_index)
    except (Refused, OSError) as exc:
        reason = exc if isinstance(exc, Refused) else "cannot write %s: %s" % (title_path, exc.strerror or exc)
        if index_updated:
            reason = "%s (the title in %s was already updated, but the picker shows %s, which still holds the old title)" \
                % (reason, db_path, title_path)
        raise Refused(reason)
    return 0


def remove_artifact(dir_fd, dir_path, name):
    """Remove one conversation artifact. A symlink is unlinked itself and its
    target is never touched. Returns False on failure."""
    path = os.path.join(dir_path, name)
    st = leaf_stat(dir_fd, name)
    if st is None:
        return True
    try:
        if stat.S_ISDIR(st.st_mode):
            remove_tree(dir_fd, name)
        else:
            os.unlink(name, dir_fd=dir_fd)
    except OSError as exc:
        sys.stderr.write("Failed to remove %s: %s\n" % (path, exc.strerror or exc))
        return False
    return True


def cmd_delete(profile_dir, cid, busy_timeout_ms):
    check_cid(cid)
    timeout = int(busy_timeout_ms) / 1000.0
    profile = Profile(profile_dir)
    cli_fd = profile.cli()
    if cli_fd is None:
        return 0
    # Validate every directory first: a refusal must leave the index and all
    # artifacts untouched.
    brain_path = os.path.join(profile.cli_path, "brain")
    conv_root_path = os.path.join(profile.cli_path, "conversations")
    brain_fd = open_child_dir(cli_fd, "brain", brain_path)
    conv_root_fd = open_child_dir(cli_fd, "conversations", conv_root_path)

    ids = [cid]
    db_path = os.path.join(profile.cli_path, DB_NAME)
    try:
        conn, _ = open_database(profile, cli_fd, readonly=False, timeout=timeout)
        if conn is not None:
            with conn:
                cur = conn.execute(
                    "SELECT conversation_id FROM conversation_summaries WHERE parent_conversation_id = ?", (cid,))
                ids += [r[0] for r in cur.fetchall() if r and r[0] and CID_RE.match(str(r[0]))]
                conn.execute(
                    "DELETE FROM conversation_summaries WHERE conversation_id = ? OR parent_conversation_id = ?",
                    (cid, cid))
            conn.close()
    except sqlite3.Error as exc:
        raise Refused("Failed to update %s for conversation '%s': %s" % (db_path, cid, exc))
    profile.verify_cli(cli_fd)

    ok = True
    for target in ids:
        if brain_fd is not None:
            ok = remove_artifact(brain_fd, brain_path, target) and ok
        if conv_root_fd is not None:
            for name in (target, target + ".pb", target + ".json"):
                ok = remove_artifact(conv_root_fd, conv_root_path, name) and ok
    return 0 if ok else 1


def raise_exit(signum, _frame):
    raise SystemExit(128 + signum)


COMMANDS = {"list": (cmd_list, 3), "rename": (cmd_rename, 3), "delete": (cmd_delete, 3)}


def main(argv):
    # Turn termination signals into exceptions so temp-file cleanup runs.
    for signame in ("SIGTERM", "SIGHUP"):
        if hasattr(signal, signame):
            signal.signal(getattr(signal, signame), raise_exit)
    if len(argv) < 1 or argv[0] not in COMMANDS or len(argv) - 1 != COMMANDS[argv[0]][1]:
        sys.stderr.write("usage: <list|rename|delete> ARGS...\n")
        return 2
    try:
        require_capabilities()
        func = COMMANDS[argv[0]][0]
        return func(*argv[1:])
    except Refused as exc:
        sys.stderr.write("ERROR: %s\n" % exc)
        return 1
    except Exception as exc:
        if os.environ.get("AI_WRAPPER_DEBUG") == "1":
            traceback.print_exc()
        else:
            sys.stderr.write("ERROR: %s\n" % (str(exc) or type(exc).__name__))
        return 1


sys.exit(main(sys.argv[1:]))
PY
}

# Canonical form of a profile directory (resolving a checked ~/.gemini symlink).
_agy_canonical_profile_dir() {
    _realpath "${1}" 2>/dev/null || printf '%s\n' "${1}"
}

# List saved top-level conversations for `<profile_dir>` as tab-separated lines:
#   <conversation_id>\t<timestamp>\t<steps>\t<workspace_tag>\t<title>
# Reads `<profile_dir>/antigravity-cli/conversation_summaries.db` first and
# falls back to scanning `<profile_dir>/antigravity-cli/brain/*` transcripts
# for any conversation not yet indexed in SQLite. Conversations matching
# `<workdir>` (or a parent/child worktree path) sort first, newest-first.
# Symlinked profile directories or database are refused (error on stderr);
# symlinked conversation dirs and title files are skipped, never read.
_agy_list_conversations() {
    local profile_dir="${1}"
    local workdir="${2}"
    local limit="${3:-20}"
    [[ -e "${profile_dir}/antigravity-cli" || -L "${profile_dir}/antigravity-cli" ]] || return 0

    if ! command -v python3 >/dev/null 2>&1; then
        wrapper_log "WARN" "python3 not found; saved conversations cannot be listed safely."
        return 0
    fi
    _agy_host_py list "$(_agy_canonical_profile_dir "${profile_dir}")" "${workdir}" "${limit}" || true
}

# Rename a saved conversation in `<profile_dir>/antigravity-cli`.
# Updates `conversation_summaries.db` (when present; never created) and
# writes `brain/<cid>/.wrapper_title` so transcript-only fallback entries and
# subsequent picker renders reflect the custom title. Symlinked ancestors,
# database or title file are refused before anything is modified. Returns 1,
# with the affected path and retry guidance, whenever the title was not
# saved.
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
    if ! command -v python3 >/dev/null 2>&1; then
        wrapper_log "ERROR" "python3 is required to rename conversations safely."
        return 1
    fi

    local err
    if ! err="$(_agy_host_py rename "$(_agy_canonical_profile_dir "${profile_dir}")" "${cid}" "${new_title}" 2>&1)"; then
        wrapper_log "ERROR" "Failed to rename conversation '${cid}'; the new title was not saved: ${err:-python3 failed}"
        wrapper_log "ERROR" "Fix the cause above (permissions, a lock held by another wrapper, a file changed by a running agy), then retry the rename."
        return 1
    fi
    return 0
}

# Delete a saved conversation (and any child subagent records) from
# `<profile_dir>/antigravity-cli/conversation_summaries.db`, `brain/<cid>`,
# and `conversations/<cid>*`. The index is updated first; when that fails
# (locked/read-only/corrupt DB, symlinked ancestors or database) no
# artifacts are touched. A symlinked artifact is unlinked itself; its target
# is never traversed. Returns 1 when the index update or any artifact
# removal fails.
_agy_delete_conversation() {
    local profile_dir="${1}"
    local cid="${2}"

    if [[ -z "${cid}" || ! "${cid}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        wrapper_log "ERROR" "Invalid conversation ID: '${cid}'"
        return 1
    fi

    local busy_timeout_ms="${AGY_DB_BUSY_TIMEOUT_MS:-${AGY_DEFAULT_DB_BUSY_TIMEOUT_MS}}"
    if [[ ! "${busy_timeout_ms}" =~ ^[0-9]+$ ]]; then
        wrapper_log "ERROR" "Invalid AGY_DB_BUSY_TIMEOUT_MS: '${busy_timeout_ms}' (expected milliseconds)"
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        wrapper_log "ERROR" "python3 is required to delete conversations safely."
        return 1
    fi

    local err
    if ! err="$(_agy_host_py delete "$(_agy_canonical_profile_dir "${profile_dir}")" "${cid}" "${busy_timeout_ms}" 2>&1)"; then
        wrapper_log "ERROR" "Failed to delete conversation '${cid}': ${err:-python3 failed}"
        return 1
    fi
    return 0
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

# Print STRING as a JSON string literal (quotes included). Pure bash, so
# no host interpreter runs against a possibly hostile checkout. Bytes are
# walked in the C locale: `"`, `\` and control characters are escaped,
# everything else (including UTF-8 sequences) passes through unchanged.
_agy_json_string() {
    local LC_ALL=C
    local input="${1}" out="" ch code i
    for (( i = 0; i < ${#input}; i++ )); do
        ch="${input:i:1}"
        case "${ch}" in
            '"') out+='\"' ;;
            '\') out+='\\' ;;
            [[:cntrl:]])
                printf -v code '%d' "'${ch}"
                printf -v ch '\\u%04x' "${code}"
                out+="${ch}"
                ;;
            *) out+="${ch}" ;;
        esac
    done
    printf '"%s"' "${out}"
}

# Session-only agy settings, passed as `--settings '<JSON>'` (agy applies
# them for this invocation and never saves them), so the host
# <profile>/antigravity-cli/settings.json is never read, created or
# rewritten, and concurrent wrappers in different workdirs cannot race:
#   - toolPermission / artifactReviewPolicy "always-proceed": tool calls and
#     artifact edits do not block on approval prompts
#   - allowNonWorkspaceAccess=true: sandbox-bound paths outside WORKDIR
#     (/tmp, ~/bin, AI_SANDBOX_EXTRA_*_DIRS, worktree common dirs) are usable
#   - enableTerminalSandbox=false: agy is already confined by the outer
#     bubblewrap / Seatbelt sandbox; a nested one fails or conflicts
#   - trustedWorkspaces=[WORKDIR]: no workspace-trust prompt on launch
# Args: [WORKDIR] (default: the resolved current directory).
_agy_build_settings_json() {
    local wd="${1:-}"
    if [[ -z "${wd}" ]]; then
        wd="$(_realpath "$(pwd -P)" 2>/dev/null)" || wd="$(pwd -P)"
    fi
    printf '{"toolPermission":"always-proceed","artifactReviewPolicy":"always-proceed","allowNonWorkspaceAccess":true,"enableTerminalSandbox":false,"trustedWorkspaces":[%s]}' \
        "$(_agy_json_string "${wd}")"
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

# ===== PERSISTENT CONTROLS (#48 / #87) =====
# Paths under the profile dir that every later Antigravity (and Gemini
# CLI) session loads: settings, hooks, MCP servers, global rules and
# prompts, workflows, sidecars, custom agents, plugins and skills.
# _bind_agy_account keeps the ones present at launch read-only via
# _wrapper_protect_client_controls, after _agy_sync_profile_skills has
# refreshed the managed skills on the host. Session state stays writable:
# antigravity-cli/ OAuth token, conversation databases, brain/,
# conversations/, presence, cache and logs; config/projects (agy's
# per-project registry) is runtime state too.
_AGY_CLIENT_CONTROLS=(
    antigravity-cli/settings.json antigravity-cli/hooks.json
    config/config.json config/mcp_config.json config/hooks.json
    config/workflows.json config/AGENTS.md config/GEMINI.md
    config/agents config/global_workflows config/plugins config/rules
    config/sidecars config/skills config/workflows
    jetski/sidecars
    AGENTS.md GEMINI.md settings.json commands extensions
)

# Resolve AGY_ACCOUNT to the profile dir, sync global skills, and append its
# bind (at ~/.gemini) and the read-only persistent controls to WRAPPER_FLAGS.
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
        _wrapper_check_account_supported "${account}" "AGY_ACCOUNT" || exit 1
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

    _agy_sync_profile_skills "${bind_src}" || exit 1

    _wrapper_add_bind "${bind_src}" "${HOME}/.gemini"
    _wrapper_protect_client_controls "agy" "${bind_src}" "${HOME}/.gemini" \
        "${_AGY_CLIENT_CONTROLS[@]}" || exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script is meant to be sourced, not executed directly." >&2
    exit 1
fi
