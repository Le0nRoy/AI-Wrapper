"""Pinned Hermes frontend integration and private Xpra display lifecycle.

The wrapper runs desktop-server inside its existing bubblewrap namespace and
desktop-client on the host. Only a freshly allocated socket directory crosses
that boundary, mounted at DISPLAY_DIRECTORY. Install Xpra, Xvfb, xauth and fonts and provision
the packaged Hermes Desktop before launching; this module never installs them.
Profile service leases live outside writable state and prevent duplicate owners
of a service kind. Concurrent service kinds use frontend_patches transactions.
"""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qsl, urlsplit, urlunsplit


PINNED_REVISION = "19cb1cbfedeafaca099be6ff0141a28a6c516c0f"
DISPLAY = ":100"
DISPLAY_DIRECTORY = Path("/run/hermes-desktop")
DISPLAY_SOCKET = "xpra.sock"
PROFILE_PATTERN = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
SERVICE_KINDS = frozenset({"serve", "gateway", "desktop"})
READY_TIMEOUT = 30.0
STOP_TIMEOUT = 5.0
POLL_INTERVAL = 0.05
BRIDGE_OPTIONS = (
    "--clipboard=no", "--clipboard-direction=disabled", "--file-transfer=no",
    "--open-files=no", "--open-url=no", "--printing=no", "--webcam=no",
    "--speaker=disabled", "--microphone=disabled", "--pulseaudio=no",
    "--dbus=no", "--dbus-control=no", "--notifications=no",
    "--system-tray=no", "--mmap=no", "--remote-logging=no",
)


class FrontendError(RuntimeError):
    pass


def _canonical_path(value):
    raw = os.fspath(value)
    if not raw or any(ord(character) < 32 for character in raw):
        raise FrontendError("Invalid private path")
    path = Path(raw)
    if not path.is_absolute() or str(path) != raw or ".." in path.parts:
        raise FrontendError("Private paths must be canonical and absolute")
    for component in (path, *path.parents):
        if component.is_symlink():
            raise FrontendError("Symlinked private paths are refused")
        if component.exists():
            metadata = component.stat()
            shared_tmp = metadata.st_uid == 0 and metadata.st_mode & stat.S_ISVTX
            if metadata.st_uid not in {0, os.getuid()} or metadata.st_mode & 0o022 and not shared_tmp:
                raise FrontendError("Untrusted private path ancestor")
    return path


def private_directory(value):
    path = _canonical_path(value)
    metadata = path.stat()
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o700):
        raise FrontendError("Expected an owned private directory with mode 0700")
    return path


def _private_file(metadata):
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o077 or metadata.st_nlink != 1):
        raise FrontendError("Expected an owned private, non-hardlinked lock file")


@contextmanager
def profile_owner(lock_directory, profile, kind, *, writable_roots=()):
    """Host service lease; serve and gateway may coexist, duplicate kinds cannot.

    Keep this context alive until the sandbox and its children have exited.
    The protected directory must never be mounted writable inside the sandbox.
    Locks remain on disk after release so a waiter cannot acquire a new inode.
    """
    if not isinstance(profile, str) or not PROFILE_PATTERN.fullmatch(profile) or kind not in SERVICE_KINDS:
        raise FrontendError("Invalid profile service identity")
    directory = private_directory(lock_directory)
    for value in writable_roots:
        root = _canonical_path(value)
        if directory.is_relative_to(root) or root.is_relative_to(directory):
            raise FrontendError("Service locks overlap sandbox writable paths")
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    descriptor = None
    try:
        descriptor = os.open(f"{profile}.{kind}.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                             0o600, dir_fd=directory_fd)
        _private_file(os.fstat(descriptor))
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise FrontendError(f"Profile {profile} already has a {kind} owner") from error
        record = json.dumps({"profile": profile, "kind": kind, "pid": os.getpid()}).encode()
        os.ftruncate(descriptor, 0)
        os.write(descriptor, record)
        os.fsync(descriptor)
        yield descriptor
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(directory_fd)


def backend_connection(websocket_url):
    """Accept only the known loopback backend's authenticated /api/ws URL."""
    if not isinstance(websocket_url, str) or any(ord(character) < 33 for character in websocket_url):
        raise FrontendError("Invalid backend connection")
    try:
        parts = urlsplit(websocket_url)
        address = ipaddress.ip_address(parts.hostname or "")
        credentials = parse_qsl(parts.query, keep_blank_values=True, strict_parsing=True)
        valid = (parts.scheme == "ws" and str(address) in {"127.0.0.1", "::1"} and parts.port is not None
                 and parts.port > 0 and parts.path == "/api/ws" and not parts.fragment
                 and parts.username is None and parts.password is None
                 and len(credentials) == 1 and credentials[0][0] == "token"
                 and credentials[0][1] and not any(ord(character) < 32 for character in credentials[0][1]))
    except (ValueError, TypeError):
        valid = False
    if not valid:
        raise FrontendError("A known authenticated loopback /api/ws backend is required")
    return urlunsplit(("http", parts.netloc, "", "", "")), credentials[0][1]


def attach_environment(websocket_url):
    base_url, token = backend_connection(websocket_url)
    return {"HERMES_TUI_GATEWAY_URL": websocket_url,
            "HERMES_DESKTOP_REMOTE_URL": base_url,
            "HERMES_DESKTOP_REMOTE_TOKEN": token}


def wait_backend_ready(websocket_url, *, timeout=READY_TIMEOUT, probe=None, cancelled=None):
    """Wait for the actual authenticated gateway.ping response before Electron."""
    backend_connection(websocket_url)
    if not math.isfinite(timeout) or timeout <= 0:
        raise FrontendError("Invalid backend readiness timeout")
    cancelled = threading.Event() if cancelled is None else cancelled
    deadline = time.monotonic() + timeout
    while not cancelled.is_set():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise FrontendError("Authenticated Hermes backend did not become ready")
        try:
            if probe is None:
                with BackendRPC(websocket_url, timeout=min(1.0, remaining)) as rpc:
                    reply = rpc.call("gateway.ping", {})
            else:
                reply = probe()
            if isinstance(reply, dict) and reply.get("ok") is True:
                return
        except (OSError, TimeoutError, FrontendError):
            pass
        cancelled.wait(min(POLL_INTERVAL, max(0.0, deadline - time.monotonic())))
    raise FrontendError("Backend readiness was cancelled")


def create_backend_token(directory):
    """Host helper: create the exact pinned one-shot token layout in private policy.

    Read-only bind host_directory to sandbox_directory before serve. Upstream
    suppresses its one-shot unlink failure on this read-only mount. Keep the
    returned token in the protected connection manifest, never writable state.
    """
    root = private_directory(directory)
    owner = secrets.token_hex(16)
    target = root / owner
    target.mkdir(mode=0o700)
    filename = secrets.token_hex(8) + ".token"
    path = target / filename
    token = secrets.token_hex(32)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="ascii") as stream:
        stream.write(token)
        stream.flush()
        os.fsync(stream.fileno())
    sandbox = Path("/home/hermes/.hermes/desktop-ssh") / owner
    return {"host_directory": str(target), "sandbox_directory": str(sandbox),
            "token_file": str(sandbox / filename), "token": token, "owner_nonce": owner}


def serve_argv(python, token_file, owner_nonce, port=9119):
    path = Path(token_file)
    root = Path("/home/hermes/.hermes/desktop-ssh")
    if (not path.is_relative_to(root) or len(path.relative_to(root).parts) != 2
            or not re.fullmatch(r"[0-9a-f]{32}", path.parent.name)
            or not re.fullmatch(r"[0-9a-f]{16}\.token", path.name)
            or not re.fullmatch(r"[0-9a-f]{32}", owner_nonce)
            or type(port) is not int or not 1 <= port <= 65535):
        raise FrontendError("Invalid authenticated serve identity")
    return [os.fspath(python), "-m", "hermes_cli.main", "serve", "--isolated",
            "--host", "127.0.0.1", "--port", str(port),
            "--ssh-session-token-file", str(path), "--ssh-owner-nonce", owner_nonce]


def read_backend_connection(manifest):
    """Read attachment authority from a host-owned, read-only-bound manifest."""
    path = _canonical_path(manifest)
    private_directory(path.parent)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
        _private_file(os.fstat(stream.fileno()))
        raw = stream.read(8193)
    if len(raw) > 8192:
        raise FrontendError("Backend connection manifest exceeds size limit")
    try:
        pairs = json.loads(raw, object_pairs_hook=lambda values: values)
        if (not isinstance(pairs, list) or len(pairs) != 2
                or len({key for key, value in pairs}) != 2):
            raise ValueError("Invalid manifest")
        data = dict(pairs)
        if set(data) != {"version", "websocket_url"} or type(data["version"]) is not int or data["version"] != 1:
            raise ValueError("Invalid manifest schema")
    except (ValueError, TypeError) as error:
        raise FrontendError("Invalid backend connection manifest") from error
    backend_connection(data["websocket_url"])
    return data["websocket_url"]


@contextmanager
def session_owner(lock_directory, profile, session_id, *, writable_roots=()):
    """Host-only live-conversation lease; independent sessions remain parallel."""
    if not isinstance(session_id, str) or not session_id or len(session_id) > 512:
        raise FrontendError("Invalid session ownership identity")
    digest = hashlib.sha256(session_id.encode("utf-8")).hexdigest()
    directory = private_directory(lock_directory)
    if not isinstance(profile, str) or not PROFILE_PATTERN.fullmatch(profile):
        raise FrontendError("Invalid profile identity")
    for root_value in writable_roots:
        root = _canonical_path(root_value)
        if directory.is_relative_to(root) or root.is_relative_to(directory):
            raise FrontendError("Session locks overlap sandbox writable paths")
    descriptor = os.open(directory / f"{profile}.session-{digest}.lock",
                         os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        _private_file(os.fstat(descriptor))
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise FrontendError("Conversation is already active in another frontend") from error
        yield descriptor
    finally:
        os.close(descriptor)


def attach_session(rpc, stored_session_id):
    """Use pinned session.resume's stored id, then activate its runtime id."""
    if not isinstance(stored_session_id, str) or not stored_session_id or len(stored_session_id) > 512:
        raise FrontendError("A stored session identifier is required")
    resumed = rpc.call("session.resume", {"session_id": stored_session_id, "source": "cli",
                                        "close_on_disconnect": False})
    if not isinstance(resumed, dict) or not isinstance(resumed.get("session_id"), str) or not resumed["session_id"]:
        raise FrontendError("Backend did not return a runtime session identifier")
    activated = rpc.call("session.activate", {"session_id": resumed["session_id"]})
    if not isinstance(activated, dict) or activated.get("session_id") != resumed["session_id"]:
        raise FrontendError("Backend did not activate the resumed session")
    return activated


class BackendRPC:
    """Synchronous attach handshake using the pinned newline JSON-RPC WS wire."""

    def __init__(self, websocket_url, *, connect=None, timeout=READY_TIMEOUT):
        backend_connection(websocket_url)
        if not math.isfinite(timeout) or timeout <= 0:
            raise FrontendError("Invalid backend timeout")
        if connect is None:
            try:
                from websockets.sync.client import connect
            except ImportError as error:
                raise FrontendError("Hermes frontend requires the provisioned websockets dependency") from error
        try:
            self.connection = connect(websocket_url, open_timeout=timeout, proxy=None)
        except Exception:
            raise FrontendError("Known backend WebSocket authentication failed") from None
        self.timeout = timeout
        self.sequence = 0

    def call(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.connection.send(json.dumps({"jsonrpc": "2.0", "id": request_id,
                                         "method": method, "params": params}) + "\n")
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            raw = self.connection.recv(timeout=max(0.001, deadline - time.monotonic()))
            try:
                frames = [json.loads(line) for line in raw.splitlines() if line.strip()]
            except (ValueError, AttributeError) as error:
                raise FrontendError("Invalid backend RPC frame") from error
            for frame in frames:
                if not isinstance(frame, dict) or frame.get("jsonrpc") != "2.0":
                    raise FrontendError("Invalid backend RPC envelope")
                if frame.get("id") != request_id:
                    if "id" in frame:
                        raise FrontendError("Unexpected backend RPC response or interactive request")
                    continue
                if "error" in frame or "result" not in frame:
                    raise FrontendError("Backend rejected frontend attachment")
                return frame["result"]
        raise FrontendError("Backend attachment timed out")

    def close(self):
        self.connection.close()

    def __enter__(self):
        return self

    def __exit__(self, *error):
        self.close()


def cli_argv(python, stored_session_id=None):
    command = [os.fspath(python), "-m", "hermes_cli.main", "--tui"]
    if stored_session_id is not None:
        if not isinstance(stored_session_id, str) or not stored_session_id or stored_session_id.startswith("-"):
            raise FrontendError("Invalid stored session identifier")
        command.extend(["--resume", stored_session_id])
    return command


def desktop_environment(websocket_url, environment=None):
    """Environment inside bwrap: only the private virtual display is reachable."""
    result = dict(os.environ if environment is None else environment)
    for key in list(result):
        if key.startswith("XPRA_"):
            result.pop(key)
    for key in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS",
                "DBUS_SYSTEM_BUS_ADDRESS", "SSH_AUTH_SOCK", "SESSION_MANAGER",
                "PULSE_SERVER", "PIPEWIRE_REMOTE", "DESKTOP_STARTUP_ID", "NODE_OPTIONS"):
        result.pop(key, None)
    result.update(attach_environment(websocket_url))
    state = _canonical_path(result.get("HERMES_HOME", "/home/hermes/.hermes"))
    result.update({"DISPLAY": DISPLAY, "XDG_RUNTIME_DIR": "/run/hermes-desktop-runtime",
                   "HERMES_SANDBOX_DESKTOP_ATTACH_ONLY": "1",
                   "HERMES_DESKTOP_USER_DATA_DIR": str(state / "desktop-user-data"),
                   "ELECTRON_OZONE_PLATFORM_HINT": "x11", "HERMES_DESKTOP_PASSWORD_STORE": "basic",
                   "XPRA_SYSTEM_CONF_DIRS": "/nonexistent", "XPRA_USER_CONF_DIRS": "/nonexistent",
                   "XPRA_DEFAULT_CONF_DIRS": "/nonexistent"})
    return result


def desktop_server_argv(python):
    """Run the complete pinned packaged Desktop under Xpra's private Xvfb."""
    child = [os.fspath(python), "-m", "hermes_cli.main", "desktop", "--skip-build"]
    return ["xpra", "start", DISPLAY, *BRIDGE_OPTIONS, "--daemon=no", "--mdns=no",
            "--html=no", "--start-via-proxy=no", "--systemd-run=no", "--input-method=none",
            "--dbus-launch=", "--sharing=no",
            "--start-new-commands=no", "--exit-with-children=yes", "--exit-with-client=yes",
            "--terminate-children=yes", "--socket-permissions=600",
            f"--socket-dir={DISPLAY_DIRECTORY}", f"--socket-dirs={DISPLAY_DIRECTORY}",
            f"--bind={DISPLAY_DIRECTORY / DISPLAY_SOCKET}",
            "--xvfb=Xvfb -screen 0 1920x1080x24 -nolisten tcp -nolisten local -noreset -auth $XAUTHORITY",
            f"--start-child={shlex.join(child)}"]


def desktop_client_argv(socket_directory):
    directory = private_directory(socket_directory)
    return ["xpra", "attach", f"socket://{directory / DISPLAY_SOCKET}", *BRIDGE_OPTIONS,
            f"--socket-dir={directory}", f"--socket-dirs={directory}", "--tray=no"]


def desktop_dependencies():
    return [name for name in ("xpra", "Xvfb", "xauth") if shutil.which(name) is None]


def verify_desktop_bundle(runtime):
    """Fail closed unless the provisioned packaged app includes the routing gates.

    Provision restores official tracked source after compiling its overlays;
    inspect the built app rather than the restored source tree. ASAR stores
    bundled JavaScript uncompressed. This is a compatibility check, not a trust
    boundary: the wrapper independently validates and read-only binds runtime.
    """
    runtime = _canonical_path(runtime)
    release = runtime / "apps/desktop/release"
    candidates = [release / directory / name for directory in ("linux-unpacked", "linux-arm64-unpacked")
                  for name in ("hermes", "Hermes")]
    candidates = [path for path in candidates if path.is_file()]
    if not candidates:
        raise FrontendError("Provision the packaged Hermes Desktop before launching")
    executable = max(candidates, key=lambda path: path.stat().st_mtime)
    archive = _canonical_path(executable.parent / "resources/app.asar")
    markers = {b"HERMES_SANDBOX_DESKTOP_ATTACH_ONLY",
               b"Sandbox Desktop cannot spawn a second Hermes backend.",
               b"Sandbox Desktop requires its protected authenticated backend.",
               b"Sandbox Desktop lost its protected backend connection."}
    tail = b""
    limit = 1024 * 1024 * 1024
    with archive.open("rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode) or os.fstat(stream.fileno()).st_size > limit:
            raise FrontendError("Invalid packaged Desktop archive")
        while markers:
            block = stream.read(65536)
            if not block:
                break
            content = tail + block
            markers = {marker for marker in markers if marker not in content}
            tail = content[-256:]
    if markers:
        raise FrontendError("Packaged Desktop is missing the protected backend compatibility gates")
    return executable


def _stop_process(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=STOP_TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=STOP_TIMEOUT)


def run_desktop_server(python, websocket_url, *, popen=None, readiness=None):
    """Inside bwrap only; the wrapper provides private /tmp, /run and socket bind."""
    missing = desktop_dependencies()
    if missing:
        raise FrontendError("Desktop requires setup dependencies: " + ", ".join(missing))
    private_directory(DISPLAY_DIRECTORY)
    if (DISPLAY_DIRECTORY / DISPLAY_SOCKET).exists():
        raise FrontendError("Desktop requires a fresh private socket directory")
    runtime = Path("/run/hermes-desktop-runtime")
    runtime.mkdir(mode=0o700, exist_ok=True)
    private_directory(runtime)
    verify_desktop_bundle(Path(python).parent.parent.parent)
    (wait_backend_ready if readiness is None else readiness)(websocket_url)
    process = (subprocess.Popen if popen is None else popen)(
        desktop_server_argv(python), env=desktop_environment(websocket_url), start_new_session=True)
    try:
        return process.wait()
    finally:
        _stop_process(process)


def run_desktop_client(socket_directory, server_process=None, *, run=None, timeout=READY_TIMEOUT, cancelled=None):
    """Host renderer only; wait for the private socket and a live sandbox owner."""
    directory = private_directory(socket_directory)
    if not math.isfinite(timeout) or timeout <= 0:
        raise FrontendError("Invalid Desktop readiness timeout")
    cancelled = threading.Event() if cancelled is None else cancelled
    deadline = time.monotonic() + timeout
    while True:
        if cancelled.is_set():
            raise FrontendError("Desktop attachment was cancelled")
        if server_process is not None and server_process.poll() is not None:
            raise FrontendError("Sandbox Desktop exited before attachment")
        path = directory / DISPLAY_SOCKET
        _canonical_path(path)
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            metadata = None
        if metadata is not None:
            if (not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid()
                    or metadata.st_mode & 0o077):
                raise FrontendError("Unsafe Desktop bridge socket")
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise FrontendError("Sandbox Desktop did not publish its private socket")
        cancelled.wait(min(POLL_INTERVAL, remaining))
    environment = dict(os.environ, XPRA_SYSTEM_CONF_DIRS="/nonexistent", XPRA_USER_CONF_DIRS="/nonexistent",
                       XPRA_DEFAULT_CONF_DIRS="/nonexistent")
    return (subprocess.run if run is None else run)(desktop_client_argv(directory), check=False,
                                                 env=environment).returncode


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    server = subparsers.add_parser("desktop-server")
    server.add_argument("--python", required=True)
    client = subparsers.add_parser("desktop-client")
    client.add_argument("--socket-directory", required=True)
    subparsers.add_parser("dependencies")
    args = parser.parse_args(argv)
    try:
        if args.command == "desktop-server":
            return run_desktop_server(args.python, os.environ.get("HERMES_TUI_GATEWAY_URL", ""))
        if args.command == "desktop-client":
            return run_desktop_client(args.socket_directory)
        missing = desktop_dependencies()
        print(json.dumps({"ready": not missing, "missing": missing}))
        return int(bool(missing))
    except (FrontendError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 78


if __name__ == "__main__":
    sys.exit(main())
