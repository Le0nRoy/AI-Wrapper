"""Bounded host-only Hermes worker broker; no payload executes in this module.

Profiles are protected <profiles-dir>/<name>.json files with exactly version=1,
runtime, state and workspace. All directories and the executable wrapper must
already exist without symlinks. Policy, wrapper and host spool must be outside
every writable state/workspace tree, and those trees must not contain policy
ancestors. Each profile also requires a private owned mode-0600 <name>.token
regular file containing exactly 64 lowercase hex digits.
The broker pins policy and capabilities until restart. A confined client gets
only its selected token read-only at /run/hermes/control.token.

The adapter publishes <state>/worker-spool/<kind>/<task_id>/<attempt_id>.json,
with exactly profile, kind, task_id, attempt_id and payload (a JSON object).
The broker copies its bytes into a private, read-only host snapshot at
<spool-dir>/snapshots/<profile>/<kind>/<attempt_id>.json. A host wrapper may use
read_snapshot() or that fixed path, then bind it read-only into its sandbox.
The wrapper receives only --profile NAME _worker KIND ATTEMPT_ID.

Broker.handle() accepts exactly action, profile, kind, task_id, attempt_id and
capability. Capabilities are compared before any task access and never stored
in the ledger or returned. Unknown profiles and wrong tokens both deny access.
Actions are launch/status/cancel. Attempt IDs are unique per profile/kind and
are permanently bound to their task. Responses include stage (accepted,
adopted, finished), outcome, unit, and opaque identity, never host paths/PIDs.
Accepted records precede dispatch; dispatch intent is fsynced before launch.
Uncertain dispatches stay accepted/unknown for later adoption, never replayed.
Worker units are retained
with RemainAfterExit=yes and Restart=no so their terminal exit status survives
broker restarts. Garbage collection is a separate host operation after the
finished record is persisted. Externally removed units have unknown outcomes.
At the live-record limit, the oldest persisted finished record is atomically
moved to private archive/KEY.json. Its identity, result and audit hashes remain
durable indefinitely; direct archive lookup prevents replay across restarts.
Only then may its matching host snapshot be pruned and its confirmed terminal
unit stopped. Active and uncertain records are never archived. The compact
archive grows over time; live records and normal request scans remain bounded.

serve --profiles-dir DIR --spool-dir DIR --wrapper FILE --socket FILE
request --socket FILE --action ACTION --profile NAME --kind KIND
        --task-id ID --attempt-id ID

Transport: one bounded UTF-8 JSON object, EOF on the sending half, then one
JSON response and EOF. Linux SO_PEERCRED must match the broker's UID. This is
a capability for a confined same-UID agent, not isolation from host processes
of that UID. The host spool and socket parent must be private mode 0700.
"""

import argparse
import contextlib
import errno
import fcntl
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import pwd
import re
import socket
import stat
import struct
import subprocess
import threading
import time
import uuid

if __package__:
    from .profile import ProfileError, load_profile
else:
    from profile import ProfileError, load_profile


MAX_REQUEST_BYTES = 4096
MAX_PROFILE_BYTES = 16384
MAX_RECORD_BYTES = 16384
MAX_PAYLOAD_BYTES = 1024 * 1024
MAX_PROFILES = 64
MAX_RECORDS = 1024
MAX_ACTIVE_WORKERS = 32
MAX_JSON_DEPTH = 64
DEFAULT_SPOOL_DIR = Path(pwd.getpwuid(os.getuid()).pw_dir) / ".local/share/hermes-sandbox/control/spool"
SOCKET_TIMEOUT = 3
COMMAND_TIMEOUT = 15
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z", re.ASCII)
PROFILE_PATTERN = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z", re.ASCII)
CAPABILITY_PATTERN = re.compile(r"[0-9a-f]{64}\Z", re.ASCII)
DEFAULT_TOKEN_FILE = "/run/hermes/control.token"
IDENTITY_FIELDS = {"profile", "kind", "task_id", "attempt_id"}
REQUEST_FIELDS = IDENTITY_FIELDS | {"action", "capability"}
SHOW_PROPERTIES = (
    "Id", "LoadState", "ActiveState", "SubState", "Result", "ExecMainStatus",
    "ExecMainCode", "Transient", "Slice", "Restart", "Type", "RemainAfterExit",
)
RECORD_FIELDS = IDENTITY_FIELDS | {
    "version", "unit", "stage", "outcome", "dispatch_started",
    "cancel_requested", "cancel_confirmed", "snapshot_sha256", "policy_sha256",
    "result", "exit_status",
}


class BrokerError(ValueError):
    """Closed, non-sensitive error code suitable for returning to a client."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _token(value, profile=False):
    pattern = PROFILE_PATTERN if profile else TOKEN_PATTERN
    if not isinstance(value, str) or pattern.fullmatch(value) is None or ".." in value:
        raise BrokerError("invalid_token")
    return value


def _validate_identity(request):
    for field in IDENTITY_FIELDS:
        _token(request[field], profile=field == "profile")
    if request["kind"] not in ("cron", "kanban"):
        raise BrokerError("invalid_kind")


def validate_request(request):
    """Validate the closed request without exposing any capability contents."""
    if not isinstance(request, dict) or set(request) != REQUEST_FIELDS:
        raise BrokerError("invalid_request_schema")
    capability = request["capability"]
    if not isinstance(capability, str) or CAPABILITY_PATTERN.fullmatch(capability) is None:
        raise BrokerError("access_denied")
    _validate_identity(request)
    if request["action"] not in ("launch", "status", "cancel"):
        raise BrokerError("invalid_action")
    return dict(request)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise BrokerError("duplicate_json_key")
        result[key] = value
    return result


def _constant(value):
    raise BrokerError("invalid_json")


def _decode(data, limit):
    if len(data) > limit:
        raise BrokerError("size_limit")
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=_pairs,
                           parse_constant=_constant)
    except (UnicodeError, ValueError, RecursionError) as error:
        if isinstance(error, BrokerError):
            raise
        raise BrokerError("invalid_json") from error
    pending = [(value, 0)]
    while pending:
        item, depth = pending.pop()
        if depth > MAX_JSON_DEPTH or isinstance(item, float) and not math.isfinite(item):
            raise BrokerError("invalid_json")
        if isinstance(item, dict):
            pending.extend((child, depth + 1) for child in item.values())
        elif isinstance(item, list):
            pending.extend((child, depth + 1) for child in item)
    return value


def _encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")


def _absolute(path):
    if not isinstance(path, (str, os.PathLike)):
        raise BrokerError("invalid_path")
    value = os.fspath(path)
    if not isinstance(value, str) or "\x00" in value or not value.startswith("/"):
        raise BrokerError("invalid_path")
    if value != str(Path(value)) or any(part in (".", "..") for part in value.split("/")):
        raise BrokerError("invalid_path")
    return Path(value)


def _trusted(metadata, private=False, directory=False):
    mode = stat.S_IMODE(metadata.st_mode)
    if private:
        required = 0o700 if directory else 0o600
        if metadata.st_uid != os.getuid() or mode != required:
            raise BrokerError("unsafe_permissions")
    elif metadata.st_uid not in (0, os.getuid()) or mode & 0o022:
        shared_tmp = directory and metadata.st_uid == 0 and mode & stat.S_ISVTX
        if not shared_tmp:
            raise BrokerError("unsafe_permissions")


def _open_directory(path, protected=False, private=False):
    path = _absolute(path)
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.parts[1:]:
            if protected:
                _trusted(os.fstat(descriptor), directory=True)
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                            | os.O_CLOEXEC, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        if protected or private:
            _trusted(os.fstat(descriptor), private=private, directory=True)
        return descriptor
    except OSError as error:
        os.close(descriptor)
        raise BrokerError("unsafe_or_missing_path") from error
    except BaseException:
        os.close(descriptor)
        raise


def _read_file(directory, name, limit, protected=False, snapshot=False, private=False):
    descriptor = None
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                             | os.O_CLOEXEC, dir_fd=directory)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise BrokerError("unsafe_file")
        if protected or private:
            _trusted(before, private=private)
        if snapshot and (before.st_uid != os.getuid()
                         or stat.S_IMODE(before.st_mode) != 0o400):
            raise BrokerError("unsafe_snapshot")
        if before.st_size > limit:
            raise BrokerError("size_limit")
        chunks = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(descriptor, min(remaining, 65536))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise BrokerError("file_changed")
        if len(data) > limit:
            raise BrokerError("size_limit")
        return data
    except FileNotFoundError:
        raise
    except OSError as error:
        raise BrokerError("unsafe_file") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _child_directory(parent, name):
    try:
        os.mkdir(name, 0o700, dir_fd=parent)
        os.fsync(parent)
    except FileExistsError:
        pass
    try:
        descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                             | os.O_CLOEXEC, dir_fd=parent)
    except OSError as error:
        raise BrokerError("unsafe_or_missing_path") from error
    try:
        _trusted(os.fstat(descriptor), private=True, directory=True)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _atomic_write(directory, name, data, immutable=False):
    temporary = ".pending-" + uuid.uuid4().hex
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            if immutable:
                os.fchmod(handle.fileno(), 0o400)
            os.fsync(handle.fileno())
        if immutable:
            os.link(temporary, name, src_dir_fd=directory, dst_dir_fd=directory,
                    follow_symlinks=False)
            os.unlink(temporary, dir_fd=directory)
        else:
            os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary, dir_fd=directory)


def _contains(parent, child):
    return parent == child or parent in child.parents


def _read_capability(directory, name):
    data = _read_file(directory, name, 65, private=True)
    try:
        value = data.decode("ascii")
    except UnicodeError as error:
        raise BrokerError("invalid_capability_file") from error
    if CAPABILITY_PATTERN.fullmatch(value) is None:
        raise BrokerError("invalid_capability_file")
    return value


def _overlap(first, second):
    return _contains(first, second) or _contains(second, first)


def _identity(value):
    return {field: value[field] for field in IDENTITY_FIELDS}


def _key(value):
    return hashlib.sha256(_encode([value["profile"], value["kind"],
                                  value["attempt_id"]])).hexdigest()


def _unit(value):
    return "hermes-worker-" + value["kind"] + "-" + _key(value) + ".service"


def _validate_snapshot(data, expected):
    value = _decode(data, MAX_PAYLOAD_BYTES)
    if not isinstance(value, dict) or set(value) != IDENTITY_FIELDS | {"payload"}:
        raise BrokerError("invalid_payload_schema")
    if _identity(value) != _identity(expected) or not isinstance(value["payload"], dict):
        raise BrokerError("payload_identity_mismatch")
    return value


def read_snapshot(spool_dir, profile, kind, attempt_id):
    """Read a protected immutable snapshot for a host wrapper, without execution."""
    _token(profile, profile=True)
    for value in (kind, attempt_id):
        _token(value)
    if kind not in ("cron", "kanban"):
        raise BrokerError("invalid_kind")
    root = _absolute(spool_dir)
    descriptor = _open_directory(root / "snapshots" / profile / kind,
                                 protected=True, private=True)
    try:
        data = _read_file(descriptor, attempt_id + ".json", MAX_PAYLOAD_BYTES,
                          protected=True, snapshot=True)
        value = _decode(data, MAX_PAYLOAD_BYTES)
        if not isinstance(value, dict) or set(value) != IDENTITY_FIELDS | {"payload"}:
            raise BrokerError("invalid_payload_schema")
        _token(value["task_id"])
        return _validate_snapshot(data, {"profile": profile, "kind": kind,
                                         "attempt_id": attempt_id,
                                         "task_id": value["task_id"]})
    finally:
        os.close(descriptor)


class Broker:
    """Single-owner durable broker; runner injection is only a host Python API."""

    def __init__(self, profiles_dir, spool_dir, wrapper, runner=None):
        self.profiles_dir = _absolute(profiles_dir)
        self.spool_dir = _absolute(spool_dir)
        self.wrapper = _absolute(wrapper)
        self.runner = subprocess.run if runner is None else runner
        self._mutex = threading.RLock()
        self._descriptors = []
        self._closed = False
        try:
            profiles_descriptor = self._hold(_open_directory(self.profiles_dir, protected=True, private=True))
            registry_parent = _open_directory(self.profiles_dir.parent, protected=True, private=True)
            os.close(registry_parent)
            wrapper_parent = _open_directory(self.wrapper.parent, protected=True)
            try:
                _read_file(wrapper_parent, self.wrapper.name, MAX_PAYLOAD_BYTES, protected=True)
                metadata = os.stat(self.wrapper.name, dir_fd=wrapper_parent, follow_symlinks=False)
                if not metadata.st_mode & 0o111:
                    raise BrokerError("wrapper_not_executable")
            finally:
                os.close(wrapper_parent)
            self.profiles = self._profiles(profiles_descriptor)
            self._capabilities = {}
            for name in self.profiles:
                try:
                    self._capabilities[name] = _read_capability(profiles_descriptor, name + ".token")
                except FileNotFoundError as error:
                    raise BrokerError("missing_profile_capability") from error
            self._check_separation((self.profiles_dir, self.spool_dir, self.wrapper.parent))
            if _overlap(self.profiles_dir, self.spool_dir):
                raise BrokerError("overlapping_policy")
            for name, bounded_profile in self.profiles.items():
                try:
                    shared_profile = load_profile(name, self.profiles_dir)
                except (ProfileError, OSError) as error:
                    raise BrokerError("invalid_profile_policy") from error
                expected = {key: str(value) if isinstance(value, Path) else value
                            for key, value in bounded_profile.items()}
                if shared_profile != expected:
                    raise BrokerError("profile_policy_changed")
            self._spool = self._hold(_open_directory(self.spool_dir, protected=True, private=True))
            lock = os.open("broker.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
                           | os.O_CLOEXEC | os.O_NONBLOCK, 0o600, dir_fd=self._spool)
            self._hold(lock)
            metadata = os.fstat(lock)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise BrokerError("unsafe_file")
            _trusted(metadata, private=True)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise BrokerError("broker_already_running") from error
            self._records = self._hold(_child_directory(self._spool, "records"))
            self._archive = self._hold(_child_directory(self._spool, "archive"))
            self._snapshots = self._hold(_child_directory(self._spool, "snapshots"))
        except BaseException:
            self.close()
            raise

    def _hold(self, descriptor):
        self._descriptors.append(descriptor)
        return descriptor

    def close(self):
        with self._mutex:
            for descriptor in reversed(self._descriptors):
                os.close(descriptor)
            self._descriptors.clear()
            self._closed = True

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def _profiles(self, descriptor):
        profiles = {}
        token_names = set()
        seen = 0
        with os.scandir(descriptor) as entries:
            for entry in entries:
                seen += 1
                if seen > MAX_PROFILES * 2:
                    raise BrokerError("profile_limit")
                if entry.name.endswith(".token"):
                    token_names.add(_token(entry.name[:-6], profile=True))
                    continue
                if not entry.name.endswith(".json"):
                    raise BrokerError("invalid_profile_registry")
                name = _token(entry.name[:-5], profile=True)
                value = _decode(_read_file(descriptor, entry.name, MAX_PROFILE_BYTES,
                                           protected=True), MAX_PROFILE_BYTES)
                required_fields = {"version", "runtime", "state", "workspace"}
                if (not isinstance(value, dict) or not required_fields <= set(value)
                        or set(value) - required_fields - {"workspaces"}):
                    raise BrokerError("invalid_profile_schema")
                if type(value["version"]) is not int or value["version"] != 1:
                    raise BrokerError("invalid_profile_version")
                extra_workspaces = value.get("workspaces", [])
                if (not isinstance(extra_workspaces, list) or len(extra_workspaces) > 32
                        or any(not isinstance(path, str) for path in extra_workspaces)):
                    raise BrokerError("invalid_profile_schema")
                for field in ("runtime", "state", "workspace"):
                    path = _absolute(value[field])
                    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
                    if _contains(path, home) or path == Path("/"):
                        raise BrokerError("unsafe_profile_path")
                    check = _open_directory(path)
                    os.close(check)
                    value[field] = path
                workspaces = [value["workspace"]]
                for workspace in extra_workspaces:
                    path = _absolute(workspace)
                    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
                    if _contains(path, home) or path == Path("/"):
                        raise BrokerError("unsafe_profile_path")
                    check = _open_directory(path)
                    os.close(check)
                    workspaces.append(path)
                if len(set(workspaces)) != len(workspaces) or any(
                        _overlap(left, right) for index, left in enumerate(workspaces)
                        for right in workspaces[index + 1:]):
                    raise BrokerError("overlapping_profile_paths")
                if any(_overlap(value[label], workspace) for label in ("state", "runtime")
                       for workspace in workspaces):
                    raise BrokerError("overlapping_profile_paths")
                if "workspaces" in value:
                    value["workspaces"] = workspaces[1:]
                profiles[name] = value
                if len(profiles) > MAX_PROFILES:
                    raise BrokerError("profile_limit")
        if not profiles:
            raise BrokerError("empty_profile_registry")
        if token_names - set(profiles):
            raise BrokerError("invalid_profile_registry")
        return profiles

    def _check_separation(self, protected_paths):
        home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        for protected in protected_paths:
            if _contains(protected, home) or protected == Path("/"):
                raise BrokerError("unsafe_policy_path")
            for profile in self.profiles.values():
                for field in ("state", "workspace"):
                    if _overlap(protected, profile[field]):
                        raise BrokerError("overlapping_policy")
                if any(_overlap(protected, workspace) for workspace in profile.get("workspaces", [])):
                    raise BrokerError("overlapping_policy")
                if _contains(profile["runtime"], protected):
                    raise BrokerError("overlapping_policy")

    def _policy_digest(self, profile):
        def serialize(value):
            if isinstance(value, Path):
                return str(value)
            if isinstance(value, list):
                return [serialize(item) for item in value]
            return value

        value = {key: serialize(path) for key, path in self.profiles[profile].items()}
        value["wrapper"] = str(self.wrapper)
        return hashlib.sha256(_encode(value)).hexdigest()

    def _load(self, key):
        archived = False
        try:
            data = _read_file(self._records, key + ".json", MAX_RECORD_BYTES, protected=True)
        except FileNotFoundError:
            try:
                data = _read_file(self._archive, key + ".json", MAX_RECORD_BYTES, protected=True)
                archived = True
            except FileNotFoundError:
                return None
        record = _decode(data, MAX_RECORD_BYTES)
        if not isinstance(record, dict) or set(record) != RECORD_FIELDS:
            raise BrokerError("corrupt_record")
        _validate_identity(record)
        if (type(record["version"]) is not int or record["version"] != 1
                or _key(record) != key or record["unit"] != _unit(record)
                or record["stage"] not in ("accepted", "adopted", "finished")
                or record["outcome"] not in ("pending", "running", "succeeded", "failed",
                                             "cancelled", "unknown")
                or any(type(record[field]) is not bool for field in (
                    "dispatch_started", "cancel_requested", "cancel_confirmed"))):
            raise BrokerError("corrupt_record")
        if archived and record["stage"] != "finished":
            raise BrokerError("corrupt_record")
        if record["stage"] != "finished" and (
                record["profile"] not in self.profiles
                or record["policy_sha256"] != self._policy_digest(record["profile"])):
            raise BrokerError("profile_policy_changed")
        for field in ("snapshot_sha256", "policy_sha256"):
            if not isinstance(record[field], str) or re.fullmatch(
                    r"[0-9a-f]{64}", record[field]) is None:
                raise BrokerError("corrupt_record")
        return record

    def _save(self, record):
        _atomic_write(self._records, _key(record) + ".json", _encode(record))

    def _all_records(self):
        records = []
        seen = 0
        with os.scandir(self._records) as entries:
            for entry in entries:
                seen += 1
                if seen > MAX_RECORDS * 2:
                    raise BrokerError("record_limit")
                if entry.name.startswith(".pending-"):
                    continue
                if re.fullmatch(r"[0-9a-f]{64}\.json", entry.name) is None:
                    raise BrokerError("corrupt_record")
                records.append(self._load(entry.name[:-5]))
                if len(records) > MAX_RECORDS:
                    raise BrokerError("record_limit")
        return records

    def _archive_finished(self, records):
        finished = [record for record in records if record["stage"] == "finished"]
        if not finished:
            raise BrokerError("record_limit")
        record = min(finished, key=lambda item: os.stat(
            _key(item) + ".json", dir_fd=self._records,
            follow_symlinks=False).st_mtime_ns)
        key = _key(record)
        name = key + ".json"
        data = _read_file(self._records, name, MAX_RECORD_BYTES, private=True)
        if _decode(data, MAX_RECORD_BYTES) != record:
            raise BrokerError("record_changed")
        try:
            _read_file(self._archive, name, MAX_RECORD_BYTES, private=True)
        except FileNotFoundError:
            pass
        else:
            raise BrokerError("archive_identity_conflict")
        os.rename(name, name, src_dir_fd=self._records, dst_dir_fd=self._archive)
        os.fsync(self._archive)
        os.fsync(self._records)
        with contextlib.suppress(BrokerError, OSError):
            self._prune_archived_snapshot(record)
        with contextlib.suppress(BrokerError, OSError):
            self._release_terminal_unit(record)
        return [item for item in records if _key(item) != key]

    def _prune_archived_snapshot(self, record):
        descriptors = []
        try:
            parent = self._snapshots
            for name in (record["profile"], record["kind"]):
                descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                                     | os.O_CLOEXEC, dir_fd=parent)
                descriptors.append(descriptor)
                _trusted(os.fstat(descriptor), private=True, directory=True)
                parent = descriptor
            name = record["attempt_id"] + ".json"
            data = _read_file(parent, name, MAX_PAYLOAD_BYTES, snapshot=True)
            _validate_snapshot(data, record)
            if hashlib.sha256(data).hexdigest() != record["snapshot_sha256"]:
                raise BrokerError("snapshot_changed")
            os.unlink(name, dir_fd=parent)
            os.fsync(parent)
        except FileNotFoundError:
            pass
        finally:
            for descriptor in reversed(descriptors):
                os.close(descriptor)

    def _release_terminal_unit(self, record):
        if record["stage"] != "finished":
            raise BrokerError("unfinished_record")
        properties = self._show(record)
        if properties is None:
            return
        terminal = properties["ActiveState"] in ("inactive", "failed") or (
            properties["ActiveState"] == "active" and properties["SubState"] == "exited"
            and properties["ExecMainCode"] in ("1", "2", "3"))
        if not terminal:
            return
        response = self._run(["/usr/bin/systemctl", "--user", "stop", record["unit"]])
        if response.returncode != 0:
            raise BrokerError("systemd_unavailable")

    def _snapshot(self, request):
        profile_dir = _child_directory(self._snapshots, request["profile"])
        try:
            kind_dir = _child_directory(profile_dir, request["kind"])
        finally:
            os.close(profile_dir)
        try:
            name = request["attempt_id"] + ".json"
            try:
                data = _read_file(kind_dir, name, MAX_PAYLOAD_BYTES,
                                  protected=True, snapshot=True)
            except FileNotFoundError:
                source = self.profiles[request["profile"]]["state"] / "worker-spool"
                source = source / request["kind"] / request["task_id"]
                source_dir = _open_directory(source)
                try:
                    try:
                        data = _read_file(source_dir, name, MAX_PAYLOAD_BYTES)
                    except FileNotFoundError as error:
                        raise BrokerError("payload_not_found") from error
                finally:
                    os.close(source_dir)
                _validate_snapshot(data, request)
                _atomic_write(kind_dir, name, data, immutable=True)
            _validate_snapshot(data, request)
            return hashlib.sha256(data).hexdigest()
        finally:
            os.close(kind_dir)

    def _run(self, argv):
        uid = os.getuid()
        environment = {
            "PATH": "/usr/bin:/bin", "HOME": pwd.getpwuid(uid).pw_dir,
            "XDG_RUNTIME_DIR": "/run/user/" + str(uid), "LC_ALL": "C",
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/" + str(uid) + "/bus",
        }
        try:
            return self.runner(argv, capture_output=True, text=True, check=False,
                               timeout=COMMAND_TIMEOUT, env=environment, cwd="/")
        except (OSError, subprocess.TimeoutExpired) as error:
            raise BrokerError("systemd_unavailable") from error

    def _show(self, record):
        response = self._run([
            "/usr/bin/systemctl", "--user", "show", "--no-pager",
            "--property=" + ",".join(SHOW_PROPERTIES), record["unit"],
        ])
        if len(response.stdout) > MAX_RECORD_BYTES:
            raise BrokerError("systemd_invalid_response")
        properties = {}
        for line in response.stdout.splitlines():
            key, separator, value = line.partition("=")
            if not separator or key in properties or key not in SHOW_PROPERTIES:
                raise BrokerError("systemd_invalid_response")
            properties[key] = value
        if properties.get("LoadState") == "not-found" and response.returncode in (0, 4):
            return None
        if response.returncode != 0:
            raise BrokerError("systemd_unavailable")
        if set(properties) != set(SHOW_PROPERTIES):
            raise BrokerError("systemd_invalid_response")
        if any(properties[key] != expected for key, expected in {
                "Id": record["unit"], "Transient": "yes", "Slice": "hermes-workers.slice",
                "Restart": "no", "Type": "exec", "RemainAfterExit": "yes",
                "LoadState": "loaded"}.items()):
            raise BrokerError("unit_policy_mismatch")
        if properties["ActiveState"] not in (
                "active", "activating", "deactivating", "inactive", "failed", "reloading"):
            raise BrokerError("systemd_invalid_response")
        return properties

    def _finish(self, record, outcome):
        record["stage"] = "finished"
        record["outcome"] = outcome
        self._save(record)
        return record

    def _reconcile(self, record):
        if record["stage"] == "finished" or not record["dispatch_started"]:
            return record
        properties = self._show(record)
        if properties is None:
            if record["stage"] == "accepted" and not record["cancel_confirmed"]:
                record["outcome"] = "unknown"
                self._save(record)
                return record
            return self._finish(record, "cancelled" if record["cancel_confirmed"] else "unknown")
        record["stage"] = "adopted"
        record["outcome"] = "running"
        if properties["ActiveState"] in ("inactive", "failed") or (
                properties["ActiveState"] == "active" and properties["SubState"] == "exited"):
            record["result"] = properties["Result"]
            try:
                record["exit_status"] = int(properties["ExecMainStatus"])
            except ValueError as error:
                raise BrokerError("systemd_invalid_response") from error
            succeeded = (properties["ActiveState"] in ("inactive", "active")
                         and properties["Result"] == "success"
                         and properties["ExecMainCode"] == "1"
                         and record["exit_status"] == 0)
            outcome = "succeeded" if succeeded else "failed"
            if record["cancel_confirmed"]:
                outcome = "cancelled"
            return self._finish(record, outcome)
        self._save(record)
        if record["cancel_requested"]:
            return self._cancel(record)
        return record

    def _cancel(self, record):
        if record["stage"] == "finished":
            return record
        if not record["cancel_requested"]:
            record["cancel_requested"] = True
            self._save(record)
        if not record["dispatch_started"]:
            return self._finish(record, "cancelled")
        result = self._run(["/usr/bin/systemctl", "--user", "stop", record["unit"]])
        if result.returncode != 0:
            raise BrokerError("systemd_unavailable")
        record["cancel_confirmed"] = True
        self._save(record)
        properties = self._show(record)
        if properties is None or properties["ActiveState"] in ("inactive", "failed"):
            return self._finish(record, "cancelled")
        record["stage"] = "adopted"
        record["outcome"] = "running"
        self._save(record)
        return record

    def recover(self):
        """Adopt running units and persist observed terminals without dispatching."""
        with self._mutex:
            if self._closed:
                raise BrokerError("broker_closed")
            return [self._public(self._reconcile(record)) for record in self._all_records()]

    @staticmethod
    def _public(record):
        return {field: record[field] for field in IDENTITY_FIELDS | {
            "unit", "stage", "outcome", "cancel_requested", "result", "exit_status"}}

    def handle(self, request):
        request = validate_request(request)
        with self._mutex:
            if self._closed:
                raise BrokerError("broker_closed")
            capability = self._capabilities.get(request["profile"])
            matched = hmac.compare_digest(request["capability"], capability or "0" * 64)
            if capability is None or not matched:
                raise BrokerError("access_denied")
            record = self._load(_key(request))
            if record is not None:
                if _identity(record) != _identity(request):
                    raise BrokerError("attempt_identity_conflict")
                record = self._reconcile(record)
            elif request["action"] != "launch":
                raise BrokerError("task_not_found")
            else:
                records = self._all_records()
                if len(records) >= MAX_RECORDS:
                    records = [self._reconcile(item) for item in records]
                    records = self._archive_finished(records)
                if sum(item["stage"] != "finished" for item in records) >= MAX_ACTIVE_WORKERS:
                    raise BrokerError("worker_limit")
                snapshot_digest = self._snapshot(request)
                record = dict(_identity(request), version=1, unit=_unit(request),
                              stage="accepted", outcome="pending", dispatch_started=False,
                              cancel_requested=False, cancel_confirmed=False,
                              snapshot_sha256=snapshot_digest,
                              policy_sha256=self._policy_digest(request["profile"]),
                              result=None, exit_status=None)
                self._save(record)
            if request["action"] == "cancel":
                record = self._cancel(record)
            elif request["action"] == "launch" and not record["dispatch_started"] \
                    and record["stage"] != "finished":
                properties = self._show(record)
                if properties is not None:
                    raise BrokerError("unit_already_exists")
                snapshot = read_snapshot(self.spool_dir, record["profile"], record["kind"],
                                         record["attempt_id"])
                if _identity(snapshot) != _identity(record):
                    raise BrokerError("payload_identity_mismatch")
                if self._snapshot(request) != record["snapshot_sha256"]:
                    raise BrokerError("snapshot_changed")
                record["dispatch_started"] = True
                self._save(record)
                result = self._run([
                    "/usr/bin/systemd-run", "--user",
                    "--unit=" + record["unit"], "--property=Type=exec",
                    "--property=Restart=no", "--property=RemainAfterExit=yes",
                    "--slice=hermes-workers.slice",
                    str(self.wrapper), "--profile", record["profile"], "_worker",
                    record["kind"], record["attempt_id"],
                ])
                if result.returncode == 0:
                    record["stage"] = "adopted"
                    record["outcome"] = "running"
                    self._save(record)
                record = self._reconcile(record)
            return self._public(record)

    def serve(self, socket_path, stop_event=None, ready_event=None):
        """Serve serialized requests with deadlines and periodic reconciliation."""
        path = _absolute(socket_path)
        self._check_separation((path.parent,))
        parent = _open_directory(path.parent, protected=True, private=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        bound_inode = None
        try:
            try:
                metadata = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                metadata = None
            if metadata is not None:
                if not stat.S_ISSOCK(metadata.st_mode):
                    raise BrokerError("unsafe_socket")
                _trusted(metadata, private=True)
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                    probe.settimeout(SOCKET_TIMEOUT)
                    try:
                        probe.connect(str(path))
                    except OSError as error:
                        if error.errno != errno.ECONNREFUSED:
                            raise BrokerError("socket_in_use") from error
                    else:
                        raise BrokerError("socket_in_use")
                os.unlink(path.name, dir_fd=parent)
            listener.bind(str(path))
            os.chmod(path.name, 0o600, dir_fd=parent, follow_symlinks=False)
            bound_inode = os.stat(path.name, dir_fd=parent, follow_symlinks=False).st_ino
            listener.listen(8)
            listener.settimeout(0.2)
            self.recover()
            if ready_event is not None:
                ready_event.set()
            next_recovery = time.monotonic() + 1
            while stop_event is None or not stop_event.is_set():
                try:
                    connection, _address = listener.accept()
                except socket.timeout:
                    if time.monotonic() >= next_recovery:
                        with contextlib.suppress(BrokerError):
                            self.recover()
                        next_recovery = time.monotonic() + 1
                    continue
                with connection:
                    connection.settimeout(SOCKET_TIMEOUT)
                    try:
                        _check_peer(connection)
                        request = _decode(_receive(connection, MAX_REQUEST_BYTES), MAX_REQUEST_BYTES)
                        response = {"ok": True, "record": self.handle(request)}
                    except BrokerError as error:
                        response = {"ok": False, "error": error.code}
                    except (OSError, TimeoutError):
                        response = {"ok": False, "error": "transport_error"}
                    with contextlib.suppress(OSError):
                        connection.sendall(_encode(response))
        finally:
            listener.close()
            if bound_inode is not None:
                with contextlib.suppress(FileNotFoundError):
                    if os.stat(path.name, dir_fd=parent, follow_symlinks=False).st_ino == bound_inode:
                        os.unlink(path.name, dir_fd=parent)
            os.close(parent)


def _check_peer(connection):
    credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                        struct.calcsize("3i"))
    _pid, uid, _gid = struct.unpack("3i", credentials)
    if uid != os.getuid():
        raise BrokerError("unauthorized_peer")


def _receive(connection, limit):
    chunks = []
    count = 0
    deadline = time.monotonic() + SOCKET_TIMEOUT
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise BrokerError("transport_timeout")
        connection.settimeout(remaining)
        chunk = connection.recv(min(65536, limit + 1 - count))
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        count += len(chunk)
        if count > limit:
            raise BrokerError("size_limit")


def client_request(socket_path, request, token_file=None):
    """Add only the selected token and send over a local same-UID Unix socket.

    Without an explicit capability, read token_file or the fixed sandbox path
    selected by HERMES_SANDBOX_CONTROL_TOKEN_FILE. No protected host registry
    lookup or per-UID authorization fallback is performed by the client.
    """
    if isinstance(request, dict) and "capability" not in request:
        if set(request) != REQUEST_FIELDS - {"capability"}:
            raise BrokerError("invalid_request_schema")
        path = _absolute(token_file if token_file is not None else os.environ.get(
            "HERMES_SANDBOX_CONTROL_TOKEN_FILE", DEFAULT_TOKEN_FILE))
        directory = _open_directory(path.parent, protected=True)
        try:
            request = dict(request, capability=_read_capability(directory, path.name))
        except FileNotFoundError as error:
            raise BrokerError("access_denied") from error
        finally:
            os.close(directory)
    request = validate_request(request)
    data = _encode(request)
    if len(data) > MAX_REQUEST_BYTES:
        raise BrokerError("size_limit")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(SOCKET_TIMEOUT)
        connection.connect(str(_absolute(socket_path)))
        _check_peer(connection)
        connection.sendall(data)
        connection.shutdown(socket.SHUT_WR)
        response = _decode(_receive(connection, MAX_RECORD_BYTES), MAX_RECORD_BYTES)
    if not isinstance(response, dict) or type(response.get("ok")) is not bool:
        raise BrokerError("invalid_response")
    if not response["ok"]:
        if set(response) != {"ok", "error"} or not isinstance(response["error"], str):
            raise BrokerError("invalid_response")
        raise BrokerError(response["error"])
    if set(response) != {"ok", "record"} or not isinstance(response["record"], dict):
        raise BrokerError("invalid_response")
    return response["record"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    server = commands.add_parser("serve")
    for name in ("profiles-dir", "wrapper", "socket"):
        server.add_argument("--" + name, required=True)
    server.add_argument("--spool-dir", default=str(DEFAULT_SPOOL_DIR))
    client = commands.add_parser("request")
    client.add_argument("--socket", required=True)
    client.add_argument("--token-file")
    client.add_argument("--action", choices=("launch", "status", "cancel"), required=True)
    client.add_argument("--profile", required=True)
    client.add_argument("--kind", choices=("cron", "kanban"), required=True)
    client.add_argument("--task-id", required=True)
    client.add_argument("--attempt-id", required=True)
    options = parser.parse_args(argv)
    try:
        if options.command == "serve":
            with Broker(options.profiles_dir, options.spool_dir, options.wrapper) as broker:
                broker.serve(options.socket)
        else:
            value = client_request(options.socket, {
                "action": options.action, "profile": options.profile, "kind": options.kind,
                "task_id": options.task_id, "attempt_id": options.attempt_id,
            }, token_file=options.token_file)
            print(_encode(value).decode("utf-8"))
        return 0
    except (BrokerError, OSError) as error:
        code = error.code if isinstance(error, BrokerError) else "host_io_error"
        print(_encode({"ok": False, "error": code}).decode("utf-8"))
        return 1
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
