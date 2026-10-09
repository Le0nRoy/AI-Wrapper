import argparse
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import signal
import shutil
import stat
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit


PROFILE_PATTERN = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z", re.ASCII)
PROFILE_KEYS = {"version", "runtime", "state", "workspace"}
MAX_PROFILE_BYTES = 65536
MAX_SNAPSHOT_BYTES = 1024 * 1024
PINNED_REVISION = "19cb1cbfedeafaca099be6ff0141a28a6c516c0f"
MEMORY_MAX = "6G"
CPU_QUOTA = "200%"
TASKS_MAX = "512"
BACKEND_READY_TIMEOUT = 30
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
SYSTEM_ROOTS = {
    "/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64",
    "/media", "/mnt", "/opt", "/proc", "/root", "/run", "/sbin",
    "/srv", "/sys", "/tmp", "/usr", "/var",
}
CREDENTIAL_DIRS = (
    ".ssh", ".aws", ".kube", ".docker", ".gnupg", ".claude", ".codex",
    ".cursor", ".config/gcloud", ".config/glab-cli", ".local/share/glab-cli",
)
IMMUTABLE_ROOTS = ("/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc",
                   "/proc", "/sys", "/dev", "/run", "/boot", "/opt/hermes-sandbox")


class ProfileError(ValueError):
    pass


class ProcessInterrupted(BaseException):
    def __init__(self, signum):
        self.signum = signum


def _interrupt(signum, frame):
    raise ProcessInterrupted(signum)


def validate_name(name):
    if not isinstance(name, str) or not PROFILE_PATTERN.fullmatch(name):
        raise ProfileError("Profile names must use lowercase letters, digits, underscores, or hyphens.")
    return name


def profiles_directory():
    return Path.home() / ".config/hermes-sandbox/profiles"


def control_directory():
    return Path.home() / ".local/share/hermes-sandbox/control/spool"


def support_directory():
    return Path(__file__).resolve().parent


def launcher_directory():
    return support_directory().parents[1]


def control_socket(required=False):
    path = Path(f"/run/user/{os.getuid()}/hermes-sandbox/control.sock")
    _no_symlinks(path)
    if not path.exists():
        if required:
            raise ProfileError("Hermes control socket is unavailable; start hermes-control.service.")
        return None
    _private(path.parent, directory=True)
    metadata = path.lstat()
    if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise ProfileError("Unsafe Hermes control socket.")
    return path


def control_token(name, required=False, registry_root=None):
    validate_name(name)
    root = Path(registry_root) if registry_root is not None else profiles_directory()
    _private(root.parent, directory=True)
    _private(root, directory=True)
    path = root / f"{name}.token"
    if not path.exists() and not path.is_symlink():
        if required:
            raise ProfileError("Profile control capability is missing; initialize it through host setup.")
        return None
    _private(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
            raise ProfileError("Unsafe profile control capability permissions.")
        value = stream.read(65)
    if re.fullmatch(rb"[0-9a-f]{64}", value) is None:
        raise ProfileError("Invalid profile control capability.")
    return path


def create_control_token(name, registry_root=None):
    validate_name(name)
    root = Path(registry_root) if registry_root is not None else profiles_directory()
    _private(root.parent, directory=True)
    _private(root, directory=True)
    path = root / f"{name}.token"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="ascii") as stream:
        stream.write(secrets.token_hex(32))
        stream.flush()
        os.fsync(stream.fileno())
    return path


def _no_symlinks(path):
    if not path.is_absolute() or any(component in {".", ".."} for component in str(path).split("/")):
        raise ProfileError("Paths must be canonical and absolute.")
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ProfileError(f"Symlinked paths are refused: {path}")
        if component.exists() and component != path:
            metadata = component.stat()
            shared_tmp = metadata.st_uid == 0 and metadata.st_mode & stat.S_ISVTX
            if metadata.st_uid not in {0, os.getuid()} or metadata.st_mode & 0o022 and not shared_tmp:
                raise ProfileError(f"Untrusted path ancestor: {component}")


def _private(path, directory=False):
    _no_symlinks(path)
    metadata = path.stat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise ProfileError(f"Expected an owned {'directory' if directory else 'file'}: {path}")
    if stat.S_IMODE(metadata.st_mode) & 0o077 or directory and stat.S_IMODE(metadata.st_mode) != 0o700:
        raise ProfileError(f"Group and other permissions must be disabled: {path}")
    if not directory and metadata.st_nlink != 1:
        raise ProfileError(f"Hardlinked registry files are refused: {path}")


def _under(path, parent):
    return path == parent or parent in path.parents


def _overlap(first, second):
    return _under(first, second) or _under(second, first)


def _directory(value, label, allow_missing=False):
    if not isinstance(value, str) or not value or any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ProfileError(f"Invalid {label} path.")
    path = Path(value)
    _no_symlinks(path)
    if (not path.is_dir() and not allow_missing) or path.exists() and not path.is_dir() or str(path.resolve()) != value:
        raise ProfileError(f"{label} must be an existing canonical absolute directory.")
    home = Path.home().resolve()
    if str(path) in SYSTEM_ROOTS or _under(home, path):
        raise ProfileError(f"Refusing broad {label} directory: {path}")
    for credential in CREDENTIAL_DIRS:
        if _overlap(path, home / credential):
            raise ProfileError(f"Refusing credential directory for {label}.")
    if label in {"state", "workspace"} and any(_under(path, Path(root)) for root in IMMUTABLE_ROOTS):
        raise ProfileError(f"Refusing system directory for {label}.")
    return path


def validate_profile(profile, registry_root=None, allow_missing_state=False):
    if not isinstance(profile, dict) or set(profile) != PROFILE_KEYS:
        raise ProfileError("Registry must contain exactly version, runtime, state, and workspace.")
    if type(profile["version"]) is not int or profile["version"] != 1:
        raise ProfileError("Unsupported registry version.")
    paths = {key: _directory(profile[key], key, allow_missing=key == "state" and allow_missing_state)
             for key in ("runtime", "state", "workspace")}
    registry = Path(registry_root) if registry_root is not None else profiles_directory()
    _no_symlinks(registry)
    protected = (registry.parent, control_directory().parent, launcher_directory(),
                 support_directory(), Path(f"/run/user/{os.getuid()}/hermes-sandbox"))
    for label, path in paths.items():
        for location in protected:
            _no_symlinks(location)
            if _overlap(path, location):
                raise ProfileError(f"{label} overlaps protected policy, control, or launcher paths.")
    for left, right in (("runtime", "state"), ("runtime", "workspace"), ("state", "workspace")):
        if _overlap(paths[left], paths[right]):
            raise ProfileError(f"{left} and {right} directories must not overlap.")
    home = Path.home().resolve()
    workspace = paths["workspace"]
    if _under(workspace, home) and workspace.relative_to(home).parts[0].startswith("."):
        raise ProfileError("Workspace must not be inside a home dotfile directory.")
    if paths["state"].exists() or not allow_missing_state:
        _private(paths["state"], directory=True)
    venv = paths["runtime"] / ".venv"
    _no_symlinks(venv / "bin")
    if not (venv / "pyvenv.cfg").is_file() or (venv / "pyvenv.cfg").is_symlink():
        raise ProfileError("Runtime must provide a provisioned .venv/pyvenv.cfg.")
    python = paths["runtime"] / ".venv/bin/python"
    if not python.is_file() or not os.access(python, os.X_OK):
        raise ProfileError("Runtime must provide an executable .venv/bin/python.")
    interpreter = python.resolve()
    if not any(_under(interpreter, parent) for parent in (paths["runtime"], Path("/usr"), Path("/bin"))):
        raise ProfileError("Runtime Python must resolve inside the runtime or system installation.")
    return dict(profile)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProfileError("Duplicate registry JSON keys.")
        result[key] = value
    return result


def _decode(stream):
    data = stream.read(MAX_PROFILE_BYTES + 1)
    if len(data) > MAX_PROFILE_BYTES:
        raise ProfileError("Registry exceeds its size limit.")
    try:
        return json.loads(data, object_pairs_hook=_pairs)
    except (ValueError, UnicodeError) as error:
        raise ProfileError("Invalid registry JSON.") from error


def _check_other_profiles(profile, root, name=None):
    if not root.exists():
        return
    for entry in root.iterdir():
        if entry.name.startswith(".profile-"):
            continue
        if entry.suffix == ".token":
            control_token(entry.stem, required=True, registry_root=root)
            continue
        if entry.suffix != ".json":
            raise ProfileError("Unexpected file in the profile registry.")
        validate_name(entry.stem)
        if entry.stem == name:
            continue
        _private(entry)
        descriptor = os.open(entry, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
            other = validate_profile(_decode(stream), root)
        for label in ("runtime", "state", "workspace"):
            for other_label in ("runtime", "state", "workspace"):
                if label == other_label == "runtime":
                    continue
                if _overlap(Path(profile[label]), Path(other[other_label])):
                    raise ProfileError("Profile paths overlap another profile's writable state or workspace.")


def load_profile(name, registry_root=None):
    validate_name(name)
    root = Path(registry_root) if registry_root is not None else profiles_directory()
    _private(root.parent, directory=True)
    _private(root, directory=True)
    path = root / f"{name}.json"
    _private(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
        metadata = os.fstat(stream.fileno())
        if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077 or metadata.st_nlink != 1:
            raise ProfileError("Unsafe registry file permissions.")
        profile = _decode(stream)
    profile = validate_profile(profile, root)
    _check_other_profiles(profile, root, name)
    return profile


def register_profile(name, runtime, state, workspace):
    validate_name(name)
    root = profiles_directory()
    _no_symlinks(root)
    profile = validate_profile({
        "version": 1, "runtime": runtime, "state": state, "workspace": workspace,
    }, root, allow_missing_state=True)
    for directory in (root.parent, root):
        if directory.exists():
            _private(directory, directory=True)
        else:
            directory.mkdir(mode=0o700, parents=True)
            _private(directory, directory=True)
    destination = root / f"{name}.json"
    token_destination = root / f"{name}.token"
    if destination.exists() or destination.is_symlink() or token_destination.exists() or token_destination.is_symlink():
        raise ProfileError("Profile already exists; registration will not overwrite it.")
    _check_other_profiles(profile, root)
    private_control_directory("spool")
    state_path = Path(state)
    if not state_path.exists():
        state_path.mkdir(mode=0o700, parents=True)
    validate_profile(profile, root)
    descriptor, temporary = tempfile.mkstemp(prefix=".profile-", dir=root)
    token_created = False
    published = False
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(profile, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        create_control_token(name, root)
        token_created = True
        os.link(temporary, destination)
        published = True
    finally:
        os.unlink(temporary)
        if token_created and not published:
            token_destination.unlink()
    directory_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)
    return profile


def worker_snapshot(profile_name, kind, attempt_id):
    validate_name(profile_name)
    if kind not in {"cron", "kanban"} or not isinstance(attempt_id, str) or not IDENTIFIER_PATTERN.fullmatch(attempt_id) or ".." in attempt_id:
        raise ProfileError("Invalid worker kind or attempt identifier.")
    import control

    spool = control_directory()
    snapshot = control.read_snapshot(spool, profile_name, kind, attempt_id)
    path = spool / "snapshots" / profile_name / kind / f"{attempt_id}.json"
    _private(path)
    if path.stat().st_size > MAX_SNAPSHOT_BYTES:
        raise ProfileError("Worker snapshot exceeds its size limit.")
    with path.open("r", encoding="utf-8") as stream:
        if json.load(stream) != snapshot:
            raise ProfileError("Worker snapshot changed during validation.")
    return path


def doctor(name):
    profile = load_profile(name)
    if sys.platform != "linux":
        raise ProfileError("Hermes sandboxing requires Linux.")
    if shutil.which("bwrap") is None:
        raise ProfileError("bubblewrap is not installed.")
    if shutil.which("systemd-run") is None:
        raise ProfileError("systemd-run is required for interactive cgroup budgets.")
    adapter = support_directory() / "adapter.py"
    if not adapter.is_file():
        raise ProfileError("Hermes compatibility adapter is unavailable.")
    if not (support_directory() / "frontends.py").is_file():
        raise ProfileError("Hermes frontend ownership module is unavailable.")
    socket_path = control_socket()
    token_path = control_token(name)
    return {"profile": name, "runtime": profile["runtime"], "state": profile["state"],
            "workspace": profile["workspace"], "control_socket": socket_path is not None,
            "control_token": token_path is not None, "revision": PINNED_REVISION}


def private_control_directory(name):
    parent = control_directory().parent
    root = parent / name
    _no_symlinks(root)
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    _private(parent, directory=True)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    _private(root, directory=True)
    return root


def desktop_bridge(name, value):
    validate_name(name)
    path = _directory(value, "desktop bridge")
    expected = control_directory().parent / "displays" / name
    if path.parent != expected or not path.name.startswith("session-"):
        raise ProfileError("Desktop bridge must be a fresh protected profile display directory.")
    _private(expected, directory=True)
    _private(path, directory=True)
    return path


def backend_paths(name, directory, manifest):
    validate_name(name)
    path = _directory(directory, "backend token")
    expected = control_directory().parent / "backends" / name
    if path.parent != expected or re.fullmatch(r"[0-9a-f]{32}", path.name) is None:
        raise ProfileError("Backend token directory is outside protected profile control.")
    _private(expected, directory=True)
    _private(path, directory=True)
    connection = Path(manifest)
    if connection != path / "connection.json":
        raise ProfileError("Backend connection manifest must be fixed inside its token directory.")
    _private(connection)
    import frontends

    frontends.read_backend_connection(connection)
    return path, connection


def connection_manifest(name):
    path = control_directory().parent / "connections" / f"{validate_name(name)}.json"
    _no_symlinks(path)
    if not path.exists():
        return None
    _private(path.parent, directory=True)
    _private(path)
    import frontends

    frontends.read_backend_connection(path)
    return path


def _write_private_json(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())


@contextlib.contextmanager
def backend_bundle(name, port):
    import frontends

    parent = private_control_directory("backends") / validate_name(name)
    _no_symlinks(parent)
    parent.mkdir(mode=0o700, exist_ok=True)
    _private(parent, directory=True)
    identity = frontends.create_backend_token(parent)
    host = Path(identity["host_directory"])
    manifest = host / "connection.json"
    value = {"version": 1, "websocket_url": f"ws://127.0.0.1:{port}/api/ws?token={identity['token']}"}
    published = private_control_directory("connections") / f"{name}.json"
    published_identity = None
    try:
        _write_private_json(manifest, value)
        backend_paths(name, str(host), str(manifest))
        if published.exists() or published.is_symlink():
            _private(published)
        descriptor, temporary = tempfile.mkstemp(prefix=".connection-", dir=published.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(value, stream)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, published)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        published_identity = published.stat().st_ino
        yield identity, manifest
    finally:
        if published_identity is not None and published.exists() and published.lstat().st_ino == published_identity:
            published.unlink()
        shutil.rmtree(host)


def _wrapper_path():
    wrapper = launcher_directory() / "hermes_wrapper.bash"
    if not wrapper.is_file():
        wrapper = launcher_directory() / "executable_hermes_wrapper.bash"
    return wrapper


def _wrapper_environment():
    environment = {"HOME": str(Path.home()), "PATH": "/usr/bin:/bin"}
    for variable in ("TERM", "LANG", "TZ"):
        if variable in os.environ:
            environment[variable] = os.environ[variable]
    return environment


def _serve_command(name, registered, identity, manifest, port):
    import frontends

    runtime_args = frontends.serve_argv(Path(registered["runtime"]) / ".venv/bin/python",
                                      identity["token_file"], identity["owner_nonce"], port)
    return ["/bin/bash", str(_wrapper_path()), "--profile", name, "_serve_server",
            identity["host_directory"], str(manifest), *runtime_args[4:]]


def serve(name, argv):
    options = argparse.ArgumentParser(prog="hermes_wrapper.bash serve")
    options.add_argument("--port", type=int, default=9119)
    options.add_argument("--host", choices=("127.0.0.1",), default="127.0.0.1")
    options.add_argument("--isolated", action="store_true")
    arguments = options.parse_args(argv)
    if not 1 <= arguments.port <= 65535:
        raise ProfileError("Invalid backend port.")
    registered = load_profile(name)
    import frontends

    with frontends.profile_owner(private_control_directory("locks"), name, "serve",
                                 writable_roots=(registered["state"], registered["workspace"])):
        with backend_bundle(name, arguments.port) as (identity, manifest):
            return subprocess.call(_serve_command(name, registered, identity, manifest, arguments.port),
                                   env=_wrapper_environment())


def execute(name, kind, argv):
    if kind not in {"cli", "gateway", "serve", "desktop-server", "backend-server"} or not argv:
        raise ProfileError("Invalid runtime lease or execution arguments.")
    registered = load_profile(name)
    import frontends

    manager = shutil.which("systemd-run")
    controller = shutil.which("systemctl")
    if manager is None or controller is None:
        raise ProfileError("Interactive Hermes requires systemd-run and systemctl for mandatory cgroup budgets.")
    scope = f"hermes-{name}-{kind}-{secrets.token_hex(16)}.scope"
    command = [manager, "--user", "--scope", "--quiet", "--collect", f"--unit={scope}", "--slice=hermes.slice",
               f"--property=MemoryMax={MEMORY_MAX}", f"--property=CPUQuota={CPU_QUOTA}",
               f"--property=TasksMax={TASKS_MAX}", "--property=TimeoutStopSec=10s",
               "--", "/usr/bin/env", "-i", "PATH=/usr/bin:/bin", *argv]
    runtime = f"/run/user/{os.getuid()}"
    environment = {"PATH": "/usr/bin:/bin", "XDG_RUNTIME_DIR": runtime,
                   "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime}/bus"}
    lease = contextlib.nullcontext()
    if kind in {"gateway", "serve"}:
        lease = frontends.profile_owner(private_control_directory("locks"), name, kind,
                                        writable_roots=(registered["state"], registered["workspace"]))
    with lease:
        try:
            return subprocess.call(command, env=environment)
        except BaseException:
            try:
                stopped = subprocess.run([controller, "--user", "stop", scope], env=environment,
                                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, timeout=15, check=False)
                if stopped.returncode not in {0, 5}:
                    print(f"ERROR: Could not confirm shutdown of Hermes scope {scope}.", file=sys.stderr)
            except (OSError, subprocess.TimeoutExpired):
                print(f"ERROR: Could not confirm shutdown of Hermes scope {scope}.", file=sys.stderr)
            raise


def wait_backend(manifest, process=None, timeout=BACKEND_READY_TIMEOUT):
    import frontends

    url = frontends.read_backend_connection(manifest)
    frontends.backend_connection(url)
    parsed = urlsplit(url)
    deadline = time.monotonic() + timeout
    condition = threading.Event()
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            raise ProfileError("Authenticated backend exited before readiness.")
        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        request = (f"GET {parsed.path}?{parsed.query} HTTP/1.1\r\nHost: {parsed.netloc}\r\n"
                   f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                   f"Sec-WebSocket-Key: {key}\r\n\r\n").encode("ascii")
        try:
            with socket.create_connection((parsed.hostname, parsed.port), timeout=min(1.0, max(0.001, deadline - time.monotonic()))) as connection:
                connection.sendall(request)
                response = b""
                while b"\r\n\r\n" not in response and len(response) < 16384:
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    response += chunk
                lines = response.split(b"\r\n")
                expected = base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest())
                accept = next((line.split(b":", 1)[1].strip() for line in lines[1:]
                               if line.lower().startswith(b"sec-websocket-accept:")), b"")
                if lines[0].startswith(b"HTTP/1.1 101 ") and accept == expected:
                    return
        except OSError:
            pass
        condition.wait(min(0.05, max(0, deadline - time.monotonic())))
    raise ProfileError("Authenticated backend readiness timed out.")


def desktop(name, argv):
    registered = load_profile(name)
    import frontends

    displays = private_control_directory("displays") / name
    _no_symlinks(displays)
    displays.mkdir(mode=0o700, exist_ok=True)
    _private(displays, directory=True)
    bridge = Path(tempfile.mkdtemp(prefix="session-", dir=displays))
    server = None
    backend = None
    try:
        with contextlib.ExitStack() as stack:
            stack.enter_context(frontends.profile_owner(private_control_directory("locks"), name, "desktop",
                                                         writable_roots=(registered["state"], registered["workspace"])))
            environment = _wrapper_environment()
            manifest = connection_manifest(name)
            if manifest is None:
                stack.enter_context(frontends.profile_owner(private_control_directory("locks"), name, "serve",
                                                             writable_roots=(registered["state"], registered["workspace"])))
                identity, manifest = stack.enter_context(backend_bundle(name, 9119))
                backend = subprocess.Popen(_serve_command(name, registered, identity, manifest, 9119), env=environment)
            try:
                wait_backend(manifest, backend)
                server = subprocess.Popen(["/bin/bash", str(_wrapper_path()), "--profile", name,
                                           "_desktop_server", str(bridge), *argv], env=environment)
                result = frontends.run_desktop_client(bridge, server)
                return result if type(result) is int else 0
            finally:
                for process in (server, backend):
                    if process is not None and process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=10)
    finally:
        shutil.rmtree(bridge)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Protected Hermes sandbox profiles")
    subcommands = parser.add_subparsers(dest="command", required=True)
    resolve = subcommands.add_parser("resolve")
    resolve.add_argument("--profile", default="default")
    resolve.add_argument("--worker", nargs=2, metavar=("KIND", "ATTEMPT"))
    resolve.add_argument("--desktop-bridge")
    resolve.add_argument("--require-control", action="store_true")
    resolve.add_argument("--backend-directory")
    resolve.add_argument("--backend-manifest")
    register = subcommands.add_parser("register", aliases=["init"])
    register.add_argument("--profile", default="default")
    register.add_argument("--runtime", required=True)
    register.add_argument("--state", required=True)
    register.add_argument("--workspace", required=True)
    diagnosis = subcommands.add_parser("doctor")
    diagnosis.add_argument("--profile", default="default")
    execution = subcommands.add_parser("execute")
    execution.add_argument("--profile", default="default")
    execution.add_argument("--kind", required=True, choices=("cli", "gateway", "serve", "desktop-server", "backend-server"))
    execution.add_argument("argv", nargs=argparse.REMAINDER)
    display = subcommands.add_parser("desktop")
    display.add_argument("--profile", default="default")
    display.add_argument("argv", nargs=argparse.REMAINDER)
    backend = subcommands.add_parser("serve")
    backend.add_argument("--profile", default="default")
    backend.add_argument("argv", nargs=argparse.REMAINDER)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command in {"register", "init"}:
            register_profile(arguments.profile, arguments.runtime, arguments.state, arguments.workspace)
            print(f"Registered Hermes sandbox profile: {arguments.profile}")
        elif arguments.command == "doctor":
            result = doctor(arguments.profile)
            for key, value in result.items():
                print(f"{key}: {value}")
        elif arguments.command in {"execute", "desktop", "serve"}:
            argv = arguments.argv[1:] if arguments.argv[:1] == ["--"] else arguments.argv
            if arguments.command == "execute":
                return execute(arguments.profile, arguments.kind, argv)
            if arguments.command == "serve":
                return serve(arguments.profile, argv)
            return desktop(arguments.profile, argv)
        else:
            profile = load_profile(arguments.profile)
            snapshot = worker_snapshot(arguments.profile, *arguments.worker) if arguments.worker else None
            for key in ("runtime", "state", "workspace"):
                print(profile[key])
            print(snapshot if snapshot is not None else "-")
            required = bool(arguments.worker) or arguments.require_control
            socket_path = control_socket(required=required)
            print(socket_path if socket_path is not None else "-")
            bridge = desktop_bridge(arguments.profile, arguments.desktop_bridge) if arguments.desktop_bridge else None
            print(bridge if bridge is not None else "-")
            token_path = control_token(arguments.profile, required=required)
            print(token_path if token_path is not None else "-")
            if bool(arguments.backend_directory) != bool(arguments.backend_manifest):
                raise ProfileError("Backend directory and connection manifest must be supplied together.")
            if arguments.backend_directory:
                backend_directory, manifest = backend_paths(arguments.profile, arguments.backend_directory, arguments.backend_manifest)
            else:
                backend_directory, manifest = None, connection_manifest(arguments.profile)
            print(backend_directory if backend_directory is not None else "-")
            print(manifest if manifest is not None else "-")
    except ProcessInterrupted as error:
        return 128 + error.signum
    except (ValueError, OSError, ImportError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    signal.signal(signal.SIGINT, _interrupt)
    signal.signal(signal.SIGTERM, _interrupt)
    raise SystemExit(main())
