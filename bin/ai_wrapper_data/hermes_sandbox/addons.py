"""Opt-in package extraction for a caller-validated private Hermes profile.

API: install_addon(name, state, archive=None, *, update=False) returns a Path.
CLI: python addons.py list; python addons.py install NAME --state STATE
     [--archive LOCAL_TAR_OR_ZIP] [--update]

The trusted host caller selects and validates STATE before invoking this API.
Installation is not an agent tool. Files are inert, read-only package content;
runtime sandboxing and approval of local artifacts remain the caller's job.
No profile, environment, credentials or model configuration is inferred here.
"""

import argparse
import contextlib
import ctypes
import errno
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tarfile
import tempfile
import unicodedata
import urllib.request
import uuid
import zipfile


MANIFEST_PATH = Path(__file__).with_name("addons.json")
MAX_ARCHIVE_BYTES = 16 * 1024 * 1024
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
MAX_MEMBERS = 2048
MAX_TAR_BYTES = MAX_TOTAL_BYTES + MAX_MEMBERS * 2048
MAX_PATH_DEPTH = 16
MAX_PATH_BYTES = 1024
COPY_CHUNK_BYTES = 64 * 1024
DOWNLOAD_TIMEOUT = 30
RECEIPT_NAME = ".addon.json"
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class AddonError(ValueError):
    """An addon, archive or destination failed validation."""


def list_addons():
    """Return the fixed catalog without network access or profile writes."""
    with MANIFEST_PATH.open(encoding="utf-8") as manifest_file:
        return json.load(manifest_file)["addons"]


def _addon(name):
    if not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z0-9-]*", name):
        raise AddonError("Invalid addon name")
    addon = list_addons().get(name)
    if addon is None:
        raise AddonError("Unknown addon name")
    if addon["status"] != "optional":
        raise AddonError(addon["reason"])
    return addon


def _path_parts(name, directory=False):
    if directory and name.endswith("/"):
        name = name[:-1]
    parts = name.split("/")
    if (
        not name
        or len(name.encode("utf-8")) > MAX_PATH_BYTES
        or len(parts) > MAX_PATH_DEPTH
        or "\\" in name
        or ":" in name
        or any(ord(character) < 32 or ord(character) == 127 for character in name)
        or any(part in ("", ".", "..") or part.endswith((".", " ")) for part in parts)
    ):
        raise AddonError("Unsafe archive path")
    return tuple(parts)


@contextlib.contextmanager
def _open_directory(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts or path == Path("/"):
        raise AddonError("State must be an existing absolute private profile directory")
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in path.parts[1:]:
            next_descriptor = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        yield descriptor
    finally:
        os.close(descriptor)


def _github_source(addon):
    repository = addon["repository"]
    commit = addon["commit"]
    digest = addon["sha256"]
    if (
        repository not in ("artemiimillier/start-second-brain", "artemiimillier/hermes-models-table")
        or not re.fullmatch(r"[0-9a-f]{40}", commit)
        or not re.fullmatch(r"[0-9a-f]{64}", digest)
    ):
        raise AddonError("Invalid pinned GitHub source")
    return f"https://codeload.github.com/{repository}/tar.gz/{commit}"


def _copy_bounded(source, destination, limit):
    total = 0
    digest = hashlib.sha256()
    while True:
        chunk = source.read(min(COPY_CHUNK_BYTES, limit - total + 1))
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise AddonError("Archive size limit exceeded")
        destination.write(chunk)
        digest.update(chunk)
    return digest.hexdigest(), total


def _download(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": "hermes-optional-addons"})
    with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT) as response:
        if response.geturl() != url:
            raise AddonError("Unexpected archive download redirect")
        return _copy_bounded(response, destination, MAX_ARCHIVE_BYTES)[0]


def _entries(package, zipped):
    entries = []
    seen = {}
    total = 0
    for member in package.infolist() if zipped else package:
        if len(entries) >= MAX_MEMBERS:
            raise AddonError("Archive member count limit exceeded")
        directory = member.is_dir() if zipped else member.isdir()
        name = member.orig_filename if zipped else member.name
        parts = _path_parts(name, directory)
        mode = member.external_attr >> 16 if zipped else member.mode
        size = member.file_size if zipped else member.size
        if zipped:
            file_type = stat.S_IFMT(mode)
            allowed_types = (0, stat.S_IFDIR) if directory else (0, stat.S_IFREG)
            safe_type = file_type in allowed_types and not member.flag_bits & 1
        else:
            safe_type = member.isdir() or member.isreg()
            safe_type = safe_type and not member.issparse()
        if not safe_type:
            raise AddonError("Archive links, special files, sparse files or encryption are forbidden")
        if size < 0 or size > MAX_FILE_BYTES or (directory and size):
            raise AddonError("Archive member size limit exceeded")
        total += size
        if total > MAX_TOTAL_BYTES:
            raise AddonError("Archive expanded size limit exceeded")
        folded = tuple(unicodedata.normalize("NFC", component).casefold() for component in parts)
        for depth in range(1, len(parts) + 1):
            key = folded[:depth]
            original = parts[:depth]
            is_directory = depth < len(parts) or directory
            previous = seen.get(key)
            if previous is not None:
                old_parts, old_directory, explicit = previous
                if old_parts != original or old_directory != is_directory or (depth == len(parts) and explicit):
                    raise AddonError("Duplicate or colliding archive paths")
            seen[key] = (original, is_directory, depth == len(parts) or bool(previous and previous[2]))
        entries.append((member, parts, directory, size, mode))
    return entries


def _prefix(entries, addon):
    if addon["source"] == "github":
        return (addon["repository"].split("/")[1] + "-" + addon["commit"],)
    files = {parts for member, parts, directory, size, mode in entries if not directory}
    if ("SKILL.md",) in files:
        return ()
    candidates = {parts[:-1] for parts in files if len(parts) == 2 and parts[-1] == "SKILL.md"}
    if len(candidates) == 1:
        return candidates.pop()
    raise AddonError("Local archive needs SKILL.md at its root or in one package folder")


def _included(relative, addon):
    return any(
        relative == allowed or (allowed.endswith("/") and relative.startswith(allowed))
        for allowed in addon["include"]
    )


@contextlib.contextmanager
def _package_directory(stage_descriptor, parts):
    descriptor = os.dup(stage_descriptor)
    try:
        for component in parts:
            try:
                os.mkdir(component, 0o700, dir_fd=descriptor)
            except FileExistsError:
                pass
            next_descriptor = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        yield descriptor
    finally:
        os.close(descriptor)


def _directory_mode(descriptor, mode):
    for child in os.listdir(descriptor):
        metadata = os.stat(child, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISDIR(metadata.st_mode):
            child_descriptor = os.open(child, DIRECTORY_FLAGS, dir_fd=descriptor)
            try:
                _directory_mode(child_descriptor, mode)
            finally:
                os.close(child_descriptor)
    os.fchmod(descriptor, mode)


def _extract(archive_path, stage_descriptor, addon):
    zipped = zipfile.is_zipfile(archive_path)
    if not zipped:
        with archive_path.open("rb") as source:
            compressed = source.read(2) == b"\x1f\x8b"
        raw_path = archive_path.with_name("package.tar")
        opener = gzip.open if compressed else open
        with opener(archive_path, "rb") as source, raw_path.open("xb") as target:
            _copy_bounded(source, target, MAX_TAR_BYTES)
        archive_path = raw_path
    package = zipfile.ZipFile(archive_path) if zipped else tarfile.open(archive_path, mode="r:")
    with package:
        entries = _entries(package, zipped)
        prefix = _prefix(entries, addon)
        installed = set()
        for member, parts, directory, size, mode in entries:
            if prefix and parts[:len(prefix)] != prefix:
                raise AddonError("Archive contains files outside the package folder")
            if directory:
                continue
            relative = "/".join(parts[len(prefix):])
            if not relative or relative.casefold() == RECEIPT_NAME:
                raise AddonError("Reserved package metadata path")
            if not _included(relative, addon):
                continue
            relative_parts = parts[len(prefix):]
            with _package_directory(stage_descriptor, relative_parts[:-1]) as parent_descriptor:
                descriptor = os.open(relative_parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent_descriptor)
                with os.fdopen(descriptor, "wb") as target:
                    reader = package.open(member) if zipped else package.extractfile(member)
                    with reader as source:
                        digest, written = _copy_bounded(source, target, size)
                    if written != size:
                        raise AddonError("Archive member length mismatch")
                    executable = relative in addon["executable_files"]
                    os.fchmod(target.fileno(), 0o444 | (mode & 0o111 if executable else 0))
            installed.add(relative)
        if not set(addon["required"]).issubset(installed):
            raise AddonError("Archive is missing required package files")


def _existing(root_descriptor, name, update):
    try:
        metadata = os.stat(name, dir_fd=root_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return False
    if not stat.S_ISDIR(metadata.st_mode):
        raise AddonError("Addon destination must be a directory, never a symlink")
    if not update:
        raise AddonError("Addon already exists; trusted host user must explicitly request --update")
    return True


def _publish(source_descriptor, root_descriptor, stage_name, name, existing):
    """Publish with no replacement or an atomic exchange, without a missing-live gap."""
    library = ctypes.CDLL(None, use_errno=True)
    rename = getattr(library, "renameat2", None)
    if rename is None:
        raise AddonError("Atomic addon publication requires Linux renameat2")
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    flags = 2 if existing else 1
    if rename(source_descriptor, os.fsencode(stage_name), root_descriptor, os.fsencode(name), flags):
        error_number = ctypes.get_errno()
        if error_number == errno.EEXIST:
            raise AddonError("Addon already exists; installation did not replace it")
        raise OSError(error_number, os.strerror(error_number))


def _cleanup_stage(root_descriptor, stage_name):
    """Remove only the private staging directory, including a swapped old package."""
    descriptor = os.open(stage_name, DIRECTORY_FLAGS, dir_fd=root_descriptor)
    try:
        _directory_mode(descriptor, 0o700)
    finally:
        os.close(descriptor)
    shutil.rmtree(stage_name, dir_fd=root_descriptor)


def _install(name, state, archive, addon, update):
    state = Path(state)
    with _open_directory(state) as state_descriptor:
        try:
            os.mkdir("skills", 0o700, dir_fd=state_descriptor)
        except FileExistsError:
            pass
        root_descriptor = os.open("skills", DIRECTORY_FLAGS, dir_fd=state_descriptor)
        try:
            fcntl.flock(root_descriptor, fcntl.LOCK_EX)
            existing = _existing(root_descriptor, name, update)
            stage_name = ".addon-stage-" + uuid.uuid4().hex
            os.mkdir(stage_name, 0o700, dir_fd=state_descriptor)
            stage_descriptor = os.open(stage_name, DIRECTORY_FLAGS, dir_fd=state_descriptor)
            try:
                with tempfile.TemporaryDirectory(prefix=".download-", dir=f"/proc/self/fd/{stage_descriptor}") as temporary:
                    archive_path = Path(temporary) / "package"
                    with archive_path.open("xb") as target:
                        if archive is None:
                            digest = _download(_github_source(addon), target)
                        else:
                            source_descriptor = os.open(archive, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
                            with os.fdopen(source_descriptor, "rb") as source:
                                if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                                    raise AddonError("Local archive must be a regular file")
                                digest, size = _copy_bounded(source, target, MAX_ARCHIVE_BYTES)
                    if addon["source"] == "github" and digest != addon["sha256"]:
                        raise AddonError("Pinned archive SHA-256 mismatch")
                    _extract(archive_path, stage_descriptor, addon)
                receipt = {
                    "name": name,
                    "sha256": digest,
                    "commit": addon.get("commit"),
                    "kind": addon["kind"],
                    "mode": addon["mode"],
                    "runtime_requires_sandbox": addon.get("runtime_requires_sandbox", False),
                    "host_plugins": False,
                    "import_model_claims": False,
                }
                receipt_descriptor = os.open(RECEIPT_NAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=stage_descriptor)
                with os.fdopen(receipt_descriptor, "w", encoding="utf-8") as receipt_file:
                    receipt_file.write(json.dumps(receipt, indent=2) + "\n")
                    os.fchmod(receipt_file.fileno(), 0o444)
                _directory_mode(stage_descriptor, 0o555)
                os.fchmod(stage_descriptor, 0o700)
                _existing(root_descriptor, name, update)
                stage_metadata = os.stat(stage_name, dir_fd=state_descriptor, follow_symlinks=False)
                if not os.path.samestat(stage_metadata, os.fstat(stage_descriptor)):
                    raise AddonError("Staging directory was replaced")
                _publish(state_descriptor, root_descriptor, stage_name, name, existing)
            finally:
                os.close(stage_descriptor)
                if os.path.lexists(Path(f"/proc/self/fd/{state_descriptor}") / stage_name):
                    _cleanup_stage(state_descriptor, stage_name)
        finally:
            fcntl.flock(root_descriptor, fcntl.LOCK_UN)
            os.close(root_descriptor)
    return state / "skills" / name


def install_addon(name, state, archive=None, *, update=False):
    """Install one allowed addon after explicit host opt-in; never execute its content.

    STATE is the active profile's existing absolute private state directory,
    validated by the trusted caller. Local sources require a provided archive.
    UPDATE is reserved for an explicit trusted host user request, not agents.
    """
    addon = _addon(name)
    if addon["source"] == "local" and archive is None:
        raise AddonError("This optional addon requires a user-provided local archive")
    try:
        return _install(name, state, archive, addon, update)
    except (OSError, tarfile.TarError, zipfile.BadZipFile, EOFError) as error:
        raise AddonError(f"Addon installation failed: {error}") from error


def main(argv=None):
    """Standalone host CLI; the wrapper can delegate after profile validation."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="List optional and deferred addons without installing")
    install = commands.add_parser("install", help="Explicitly opt in to one profile-scoped addon")
    install.add_argument("name", choices=tuple(list_addons()))
    install.add_argument("--state", required=True, type=Path)
    install.add_argument("--archive", type=Path)
    install.add_argument("--update", action="store_true", help="Explicit host user authorization to replace an addon")
    arguments = parser.parse_args(argv)
    if arguments.command == "list":
        print(json.dumps(list_addons(), indent=2))
        return 0
    try:
        destination = install_addon(arguments.name, arguments.state, arguments.archive, update=arguments.update)
    except AddonError as error:
        parser.exit(1, f"{error}\n")
    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
