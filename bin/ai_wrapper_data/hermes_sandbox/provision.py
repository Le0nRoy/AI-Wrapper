"""Opt-in preparation of a pinned Hermes runtime; never register or start services."""

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.parse
import urllib.request


REPOSITORY = "https://github.com/NousResearch/hermes-agent.git"
REVISION = "19cb1cbfedeafaca099be6ff0141a28a6c516c0f"
PYTHON_VERSION = "3.14.7"
INPUT_DIGESTS = {
    "pyproject.toml": "cadde2f6a92574d292103f43abf66408b1d841cd9ea332ca7f3e3dfc5dcc87fd",
    "uv.lock": "2bc4db483e9cba927cd7147f9ccbb09635f85bb3f1f36d6e9d51d06b65d1c67e",
    "pm/lock.json": "8b1278f3b535a18077020e21c2549d92c273149a64c2407715eca51178cd92ae",
    "package-lock.json": "9934677654ce672900b0946898cc28c73671f75896862b5768c24cca84776ccd",
    "package.json": "07122ef9f0c719603efb4ed473310d5c350c86dfa3f3496943df125a7c9d3f9b",
    ".npmrc": "cb762abe7fd1e479183cfea2d3da66ca3817f3e32fe71408c6e86fc80dd9a6c7",
}
EXCLUDED_EXTRAS = {
    "mcp": "not enabled by this sandbox contract",
    "computer-use": "private Desktop transport does not require the MCP computer-use driver",
    "all": "alias includes excluded MCP dependencies",
    "termux": "Android-only profile",
    "termux-all": "Android-only profile",
    "neutts": "upstream excludes Python 3.14",
}
EXTRAS = tuple(sorted((
    "uvloop", "anthropic", "exa", "firecrawl", "parallel-web", "ddgs", "fal", "edge-tts",
    "piper", "modal", "daytona", "vercel", "google-meet", "messaging", "cron", "slack",
    "wecom", "tts-premium", "voice", "wake", "telegram", "discord", "stt-whisper",
    "audio-io", "wake-openwakeword", "wake-sherpa", "wake-porcupine", "google-chat",
    "doc-extract", "trace-upload", "vision", "pty", "nemo-relay", "sms", "teams", "acp",
    "mistral", "otlp", "langfuse", "bedrock", "vertex", "azure-identity", "feishu", "google",
    "youtube", "web", "kittentts", "dingtalk", "silk", "matrix",
)))
SOURCE_BUILDS = frozenset({"alibabacloud-endpoint-util", "alibabacloud-gateway-dingtalk", "alibabacloud-tea",
                           "curated-tokenizers", "docopt", "misaki", "pilk", "python-olm"})
SYSTEM_TOOLS = {"git": "/usr/bin/git", "bwrap": "/usr/bin/bwrap", "python": "/usr/bin/python3"}
DESKTOP_TOOLS = {"Xvfb": "/usr/bin/Xvfb", "xpra": "/usr/bin/xpra", "xauth": "/usr/bin/xauth"}
BUILD_TOOLS = {"g++": "/usr/bin/g++", "make": "/usr/bin/make", "pkg-config": "/usr/bin/pkg-config",
               "cmake": "/usr/bin/cmake", "cargo": "/usr/bin/cargo", "rustc": "/usr/bin/rustc"}
MANIFEST = "hermes-provision.json"
PREPARATION_TIMEOUT = 3600


class ProvisionError(ValueError):
    pass


def check_platform(desktop=False):
    tools = {name: os.access(path, os.X_OK) for name, path in SYSTEM_TOOLS.items()}
    optional = {name: os.access(path, os.X_OK) for name, path in DESKTOP_TOOLS.items()}
    build = {name: os.access(path, os.X_OK) for name, path in BUILD_TOOLS.items()}
    supported = sys.platform == "linux" and platform.machine() in {"x86_64", "aarch64"}
    missing = [name for name, present in tools.items() if not present]
    desktop_missing = [name for name, present in optional.items() if not present]
    packages = {"git": "git", "bwrap": "bubblewrap", "python": "python", "Xvfb": "xorg-server-xvfb", "xpra": "xpra", "xauth": "xorg-xauth"}
    requested = missing + desktop_missing
    return {
        "ready": supported and not missing and (not desktop or not desktop_missing),
        "supported": supported,
        "tools": tools,
        "missing": missing,
        "desktop_ready": supported and not desktop_missing,
        "desktop_missing": desktop_missing,
        "native_build_tools": build,
        "arch_build_command": "sudo pacman -S --needed base-devel cmake rust" if not all(build.values()) else None,
        "available_helpers": {name: os.access("/usr/bin/" + name, os.X_OK) for name in ("uv", "node")},
        "required_runtime_python": PYTHON_VERSION,
        "arch_optional_command": "sudo pacman -S --needed " + " ".join(packages[name] for name in requested) if requested else None,
        "notes": [
            "Linux x86_64/aarch64 with working unprivileged user namespaces is required.",
            "Desktop launch additionally needs Xvfb, Xpra and xauth; package builds do not launch a display.",
            "Native Node dependencies may require base-devel; no host build hooks are executed.",
            "Reviewed source-only extras build from the frozen lock inside preparation, never on the host.",
            "Browser shared-library availability is checked during confined preparation.",
        ],
    }


def _profile_module():
    specification = importlib.util.spec_from_file_location("hermes_provision_profile", Path(__file__).with_name("profile.py"))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def validate_request(runtime, revision, workspace, state):
    if revision != REVISION:
        raise ProvisionError(f"Only the reviewed official revision is supported: {REVISION}")
    profile = _profile_module()
    paths = {}
    for label, value in (("runtime", runtime), ("workspace", workspace), ("state", state)):
        if not isinstance(value, str) or not value or any(ord(character) < 32 for character in value):
            raise ProvisionError(f"Invalid {label} path")
        path = Path(value)
        profile._no_symlinks(path)
        if str(path.resolve()) != value or str(path) in profile.SYSTEM_ROOTS or path == Path.home().resolve():
            raise ProvisionError(f"{label} must be a canonical, narrow absolute path")
        registry = profile.profiles_directory().parent
        protected = [registry, *(Path.home().resolve() / name for name in profile.CREDENTIAL_DIRS)]
        if any(profile._under(path, directory) or profile._under(directory, path) for directory in protected):
            raise ProvisionError(f"{label} overlaps protected registry or credentials")
        paths[label] = path
    for left, right in (("runtime", "workspace"), ("runtime", "state"), ("workspace", "state")):
        if profile._under(paths[left], paths[right]) or profile._under(paths[right], paths[left]):
            raise ProvisionError(f"{left} and {right} must not overlap")
    profile._directory(workspace, "workspace")
    home = Path.home().resolve()
    if paths["workspace"].is_relative_to(home) and paths["workspace"].relative_to(home).parts[0].startswith("."):
        raise ProvisionError("Workspace must not be a home dotfile directory")
    if paths["runtime"].exists():
        raise ProvisionError("Runtime already exists; use a new versioned destination")
    profile._private(paths["runtime"].parent, directory=True)
    profile._private(paths["state"] if paths["state"].exists() else paths["state"].parent, directory=True)
    return {"version": 1, **{label: str(path) for label, path in paths.items()}}


def clean_environment():
    return {
        "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": "/dev/null", "XDG_CONFIG_HOME": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ATTR_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/bin/false",
    }


def _run(argv, *, cwd, env=None):
    try:
        result = subprocess.run(argv, cwd=cwd, env=env or clean_environment(), text=True,
                                capture_output=True, timeout=PREPARATION_TIMEOUT, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ProvisionError(f"Preparation command failed: {argv[0]}: {error}") from error
    if result.returncode:
        diagnostics = f"stdout:\n{result.stdout[-12000:]}\nstderr:\n{result.stderr[-12000:]}"
        raise ProvisionError(f"Preparation command failed ({result.returncode}): {argv[0]}:\n{diagnostics}")
    return result.stdout.strip()


def checkout(stage, revision, source=None):
    prefix = [SYSTEM_TOOLS["git"], "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=",
              "-c", "credential.interactive=false", "-c", "core.fsmonitor=false",
              "-c", "protocol.file.allow=never", "-c", "protocol.ext.allow=never",
              "-c", "http.followRedirects=false", "-c", "uploadpack.packObjectsHook="]
    if source is not None:
        origin = Path(source)
        profile = _profile_module()
        profile._no_symlinks(origin)
        profile._private(origin, directory=True)
        if str(origin.resolve()) != source or not (origin / ".git").is_dir() or (origin / ".git").is_symlink():
            raise ProvisionError("Local source must be a canonical private Git checkout")
        if _run([*prefix, "rev-parse", "HEAD^{commit}"], cwd=origin) != revision:
            raise ProvisionError("Local source does not match the reviewed upstream commit")
        prefix.extend(("-c", "protocol.file.allow=always"))
    _run([*prefix, "init", "--template=", str(stage)], cwd=stage.parent)
    _run([*prefix, "fetch", "--no-tags", "--depth=1", source or REPOSITORY, revision], cwd=stage)
    actual = _run([*prefix, "rev-parse", "FETCH_HEAD^{commit}"], cwd=stage)
    if actual != revision:
        raise ProvisionError("Fetched commit does not match the trusted pin")
    _run([*prefix, "checkout", "--detach", revision], cwd=stage)
    verify_inputs(stage)


def verify_inputs(root):
    for name, expected in INPUT_DIGESTS.items():
        path = root / name
        if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ProvisionError(f"Pinned source input is missing or changed: {name}")


def sandbox_command(stage, runtime, build=False):
    runtime = Path(runtime)
    command = [SYSTEM_TOOLS["bwrap"], "--die-with-parent", "--new-session",
               "--unshare-all", "--share-net", "--cap-drop", "ALL", "--clearenv"]
    for directory in ("/usr", "/bin", "/lib", "/lib64"):
        if Path(directory).exists():
            command.extend(("--ro-bind", directory, directory))
    command.extend(("--tmpfs", "/etc", "--tmpfs", "/tmp", "--tmpfs", "/var", "--tmpfs", "/run",
                    "--proc", "/proc", "--dev", "/dev", "--dir", "/home/hermes"))
    for name in ("ssl", "pki", "ca-certificates", "resolv.conf", "hosts", "nsswitch.conf", "passwd", "group"):
        path = Path("/etc") / name
        if path.exists():
            command.extend(("--ro-bind", str(path.resolve()), str(path)))
    command.extend(("--bind" if build else "--ro-bind", str(stage), str(runtime)))
    if build:
        command.extend(("--ro-bind", str(stage / ".git"), str(runtime / ".git"),
                        "--ro-bind", str(stage / ".venv"), str(runtime / ".venv")))
    else:
        command.extend(("--bind", str(stage / ".venv"), str(runtime / ".venv"),
                        "--bind", str(stage / ".provision"), str(runtime / ".provision")))
    command.extend(("--ro-bind", str(Path(__file__).resolve()), "/opt/hermes-provision.py",
                    "--ro-bind", str(Path(__file__).with_name("frontend_patches.py").resolve()), "/opt/hermes-frontend-patches.py"))
    environment = {
        "HOME": "/home/hermes", "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8",
        "XDG_CACHE_HOME": str(runtime / ".provision/cache"),
        "XDG_CONFIG_HOME": "/home/hermes/.config", "XDG_DATA_HOME": "/home/hermes/.local/share",
        "HERMES_PROVISION_SANDBOX": "1", "HERMES_HOME": str(runtime / ".provision/home"),
        "HERMES_RUNTIME_DIR": str(runtime / ".provision/store"),
        "HERMES_INSTALL_ROOT": str(runtime / ".provision"),
        "UV_CACHE_DIR": str(runtime / ".provision/cache/uv"), "UV_NO_CONFIG": "1",
        "UV_PYTHON_DOWNLOADS": "never", "UV_LINK_MODE": "hardlink",
        "UV_PROJECT_ENVIRONMENT": str(runtime / ".venv"),
        "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/bin/false",
        "CI": "1", "NODE_OPTIONS": "--max-old-space-size=2048", "RAYON_NUM_THREADS": "2",
        "HERMES_WEB_BUILD_THREADS": "2", "HERMES_BUILD_COMMIT": REVISION,
        "npm_config_cache": str(runtime / ".provision/cache/npm"),
        "npm_config_userconfig": "/dev/null", "npm_config_globalconfig": "/dev/null",
        "ELECTRON_CACHE": str(runtime / ".provision/cache/electron"),
        "ELECTRON_BUILDER_CACHE": str(runtime / ".provision/cache/electron-builder"),
    }
    for name, value in environment.items():
        command.extend(("--setenv", name, value))
    command.extend(("--chdir", str(runtime), "--", SYSTEM_TOOLS["python"], "-I",
                    "/opt/hermes-provision.py", "_build" if build else "_install", "--runtime", str(runtime)))
    return command


class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        if urllib.parse.urlsplit(url).scheme != "https":
            raise ProvisionError("Artifact redirects must preserve HTTPS")
        return super().redirect_request(request, response, code, message, headers, url)


def download_tool(package, destination):
    artifact = package["artifacts"]["linux-x64" if platform.machine() == "x86_64" else "linux-arm64"]
    address = urllib.parse.urlsplit(artifact["url"])
    if address.scheme != "https" or address.hostname != "github.com" or address.username or address.password:
        raise ProvisionError("Bootstrap artifacts must come from pinned public GitHub HTTPS URLs")
    if not re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]):
        raise ProvisionError("Bootstrap artifact is missing a SHA256 pin")
    destination.mkdir(mode=0o700)
    archive = destination / "artifact.tar.gz"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), HTTPSRedirects())
    digest = hashlib.sha256()
    with opener.open(artifact["url"], timeout=60) as response, archive.open("xb") as output:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
            output.write(chunk)
    if digest.hexdigest() != artifact["sha256"]:
        raise ProvisionError("Bootstrap artifact SHA256 mismatch")
    with tarfile.open(archive) as package_archive:
        package_archive.extractall(destination, filter="data")
    archive.unlink()


def require_preparation_namespace():
    mapping = Path("/proc/self/uid_map").read_text().split()
    if (os.environ.get("HERMES_PROVISION_SANDBOX") != "1"
            or Path(__file__).resolve() != Path("/opt/hermes-provision.py")
            or len(mapping) != 3 or mapping[2] != "1"):
        raise ProvisionError("Dependency installation is only allowed in the preparation user namespace")


def install_runtime(runtime):
    require_preparation_namespace()
    root = Path(runtime)
    verify_inputs(root)
    lock = json.loads((root / "pm/lock.json").read_text())
    project = tomllib.loads((root / "pyproject.toml").read_text())
    if not set(EXTRAS).issubset(project["project"]["optional-dependencies"]):
        raise ProvisionError("Pinned runtime extras are unavailable")
    if set(project["project"]["optional-dependencies"]) != set(EXTRAS) | set(EXCLUDED_EXTRAS):
        raise ProvisionError("Pinned extras inventory differs from the reviewed preparation contract")
    bootstrap = root / ".provision/bootstrap"
    bootstrap.mkdir(mode=0o700)
    if platform.python_version() != lock["packages"]["python"]["version"].split("+", 1)[0]:
        raise ProvisionError(f"The controlled /usr/bin/python3 must be Python {PYTHON_VERSION}; prepare never adopts a transient managed interpreter")
    download_tool(lock["packages"]["uv"], bootstrap / "uv")
    uv_candidates = list((bootstrap / "uv").rglob("uv"))
    python = Path(SYSTEM_TOOLS["python"])
    if len(uv_candidates) != 1 or not uv_candidates[0].is_file():
        raise ProvisionError("Pinned bootstrap tool archive has an unsupported layout")
    uv = uv_candidates[0]
    environment = dict(os.environ)
    environment.update({"CARGO_HOME": str(root / ".provision/cache/cargo"), "CMAKE_BUILD_PARALLEL_LEVEL": "2",
                        "CARGO_BUILD_JOBS": "2", "MAKEFLAGS": "-j2"})
    _run([str(uv), "venv", "--relocatable", "--no-project", "--no-config",
          "--no-managed-python",
          "--python", str(python), str(root / ".venv")], cwd=root, env=environment)
    python_lock = tomllib.loads((root / "uv.lock").read_text())
    packages = python_lock.get("package", [])
    constraints = root / ".provision/build-constraints.txt"
    requirements = [f"{package['name']}=={package['version']}" for package in packages
                    if "git" not in package.get("source", {}) and package["name"] != "hermes-agent"]
    constraints.write_text("".join(requirement + "\n" for requirement in requirements), encoding="utf-8")
    prepared_project = root / ".provision/python-project"
    prepared_project.mkdir(mode=0o700)
    project_text = (root / "pyproject.toml").read_text(encoding="utf-8")
    anchor = "[tool.uv]\n"
    setting = "build-constraint-dependencies = " + json.dumps(requirements) + "\n"
    configured = project_text.replace(anchor, anchor + setting, 1) if anchor in project_text else project_text + "\n" + anchor + setting
    (prepared_project / "pyproject.toml").write_text(configured, encoding="utf-8")
    shutil.copyfile(root / "uv.lock", prepared_project / "uv.lock")
    environment.pop("UV_NO_CONFIG", None)
    command = [str(uv), "sync", "--frozen", "--no-default-groups", "--no-install-project",
               "--project", str(prepared_project), "--no-managed-python", "--python", str(python)]
    for package in packages:
        if package["name"] not in SOURCE_BUILDS:
            command.extend(("--no-build-package", package["name"]))
    for extra in EXTRAS:
        command.extend(("--extra", extra))
    _run(command, cwd=root, env=environment)
    _write_json(root / ".provision/install-stamp.json", {
        "schemaVersion": 2, "commit": REVISION, "updateMechanism": "external",
        "source": "hermes-sandbox", "payload": "bootstrap", "dirty": False,
        "displayVersion": "git." + REVISION[:7], "baseVersion": None,
    })
    browser_probe = (
        "import importlib, json, pathlib, platform, subprocess, sys; "
        "assert pathlib.Path(sys.prefix) == pathlib.Path(sys.argv[1]) / '.venv', 'Runtime Python did not activate the final venv'; "
        "assert pathlib.Path(sys.executable) == pathlib.Path(sys.argv[1]) / '.venv/bin/python', 'Unexpected runtime interpreter path'; "
        "sys.path.insert(0, sys.argv[1]); "
        "[importlib.import_module(name) for name in ('openai', 'fastapi', 'uvicorn', 'croniter', 'browser_harness', 'telegram', 'discord', 'slack_sdk')]; "
        "import pm; [pm.ensure(name, explicit=True) for name in ('ffmpeg', 'ripgrep', 'npm')]; "
        "runner = pm.ensure('agent-browser', explicit=True); "
        "environment = runner.env; "
        "required = ('PLAYWRIGHT_BROWSERS_PATH', 'AGENT_BROWSER_EXECUTABLE_PATH'); "
        "assert all(environment.get(name) for name in required), 'Private browser environment is missing'; "
        "assert pathlib.Path(environment['AGENT_BROWSER_EXECUTABLE_PATH']).is_file(), 'Private browser executable is missing'; "
        "subprocess.run([environment['AGENT_BROWSER_EXECUTABLE_PATH'], '--headless', '--disable-gpu', "
        "'--disable-dev-shm-usage', '--no-sandbox', '--dump-dom', 'about:blank'], "
        "env=environment, check=True, capture_output=True, timeout=60); "
        "print(json.dumps({'browser': {name: environment[name] for name in required}, "
        "'interpreter': {'executable': sys.executable, 'prefix': sys.prefix, "
        "'base_executable': str(pathlib.Path(sys._base_executable).resolve()), 'version': platform.python_version()}}))"
    )
    proof = json.loads(_run([str(root / ".venv/bin/python"), "-I", "-c", browser_probe, str(root)], cwd=root, env=environment).splitlines()[-1])
    report = {"python": lock["packages"]["python"]["version"], "uv": lock["packages"]["uv"]["version"],
              "extras": list(EXTRAS), **proof}
    _write_json(root / ".provision/result.json", report)


def build_frontends(runtime):
    require_preparation_namespace()
    root = Path(runtime)
    verify_inputs(root)
    specification = importlib.util.spec_from_file_location("hermes_desktop_overlays", "/opt/hermes-frontend-patches.py")
    patches = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(patches)
    sources = {name: (root / name).read_text(encoding="utf-8") for name in patches.DESKTOP_SOURCE_DIGESTS}
    replacements = patches.desktop_source_patches(sources)
    environment = dict(os.environ)
    environment["HERMES_INSTALL_ROOT"] = str(root / ".provision")
    try:
        for name, content in replacements.items():
            (root / name).write_text(content, encoding="utf-8")
        desktop_build = (
            "import runpy, sys; sys.path.insert(0, sys.argv[1]); "
            "sys.argv = ['hermes', 'desktop', '--build-only', '--force-build']; "
            "runpy.run_module('hermes_cli.main', run_name='__main__')"
        )
        _run([str(root / ".venv/bin/python"), "-I", "-B", "-c", desktop_build, str(root)], cwd=root, env=environment)
        web_build = (
            "import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; "
            "from hermes_cli.source_build import source_build_env, build_source_web; "
            "build_source_web(Path(sys.argv[1]), env=source_build_env(explicit=True))"
        )
        _run([str(root / ".venv/bin/python"), "-I", "-B", "-c", web_build, str(root)], cwd=root, env=environment)
    finally:
        for name, content in sources.items():
            (root / name).write_text(content, encoding="utf-8")
    probe = (
        "import json, pathlib, sys; sys.path.insert(0, sys.argv[1]); "
        "from hermes_cli.main_desktop import _desktop_packaged_executable, _renderer_bundle_dir, "
        "_renderer_bundle_torn, _packaged_node_pty_missing; "
        "root = pathlib.Path(sys.argv[1]); desktop = root / 'apps/desktop'; "
        "exe = _desktop_packaged_executable(desktop); dist = _renderer_bundle_dir(desktop, source_mode=False); "
        "assert exe and dist and (dist / 'index.html').is_file(), 'Packaged Desktop is missing'; "
        "assert not _renderer_bundle_torn(dist) and not _packaged_node_pty_missing(dist), 'Packaged Desktop is incomplete'; "
        "main = dist / 'electron-main.mjs'; text = main.read_text(); "
        "assert 'HERMES_SANDBOX_DESKTOP_ATTACH_ONLY' in text and 'Sandbox Desktop cannot spawn a second Hermes backend.' in text, 'Desktop overlays were not packaged'; "
        "import pm; pm.ensure('npm', explicit=True); "
        "print(json.dumps({'executable': str(exe.relative_to(root)), 'electron_main': str(main.relative_to(root)), "
        "'web_index': 'hermes_cli/web_dist/index.html'}))"
    )
    artifacts = json.loads(_run([str(root / ".venv/bin/python"), "-I", "-B", "-c", probe, str(root)], cwd=root, env=environment).splitlines()[-1])
    report = {
        "electron": json.loads((root / "apps/desktop/package.json").read_text())["devDependencies"]["electron"],
        "overlays": {name: hashlib.sha256(content.encode()).hexdigest() for name, content in replacements.items()},
        "artifacts": {name: {"path": value, "sha256": hashlib.sha256((root / value).read_bytes()).hexdigest()}
                      for name, value in artifacts.items()},
    }
    _write_json(root / ".provision/frontends.json", report)


def verify_frontends(stage, report):
    if report.get("electron") != json.loads((stage / "apps/desktop/package.json").read_text())["devDependencies"]["electron"]:
        raise ProvisionError("Packaged Electron version differs from the pinned workspace")
    artifacts = report.get("artifacts", {})
    if set(artifacts) != {"executable", "electron_main", "web_index"}:
        raise ProvisionError("Desktop/web build did not produce all required artifacts")
    for name, artifact in artifacts.items():
        relative = Path(artifact["path"])
        path = stage / relative
        if relative.is_absolute() or ".." in relative.parts or not path.resolve().is_relative_to(stage):
            raise ProvisionError("Frontend artifact escapes the prepared runtime")
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != artifact["sha256"]:
            raise ProvisionError("Frontend artifact is missing or has changed")
        if name == "executable":
            with path.open("rb") as executable:
                magic = executable.read(4)
            if not os.access(path, os.X_OK) or magic != b"\x7fELF":
                raise ProvisionError("Packaged Desktop executable is not a Linux ELF executable")


def _write_json(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(value, output, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())


def publish(stage, destination):
    library = ctypes.CDLL(None, use_errno=True)
    rename = getattr(library, "renameat2", None)
    if rename is None:
        raise ProvisionError("Atomic no-overwrite publication requires Linux renameat2")
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    parent = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if rename(parent, os.fsencode(stage.name), parent, os.fsencode(destination.name), 1):
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(destination))
        os.fsync(parent)
    finally:
        os.close(parent)


def verify_venv(stage, destination, report):
    executable = stage / ".venv/bin/python"
    controlled = Path(SYSTEM_TOOLS["python"]).resolve()
    if not executable.is_symlink() or executable.resolve() != controlled or not os.access(controlled, os.X_OK):
        raise ProvisionError("Runtime Python must resolve to the controlled system interpreter")
    expected = {"executable": str(destination / ".venv/bin/python"), "prefix": str(destination / ".venv"),
                "base_executable": str(controlled), "version": PYTHON_VERSION}
    if report.get("interpreter") != expected:
        raise ProvisionError("Confined runtime interpreter identity does not match the final venv")
    configuration = stage / ".venv/pyvenv.cfg"
    if configuration.is_symlink() or not configuration.is_file():
        raise ProvisionError("Runtime pyvenv.cfg is missing")
    configuration_text = configuration.read_text()
    settings = dict(line.split("=", 1) for line in configuration_text.splitlines() if "=" in line)
    versions = {name.strip(): value.strip() for name, value in settings.items()}
    if versions.get("version_info", versions.get("version")) != PYTHON_VERSION:
        raise ProvisionError("Runtime pyvenv.cfg has the wrong Python version")
    candidates = [configuration, *(stage / ".venv/bin").iterdir(),
                  *(stage / ".venv").glob("lib/python*/site-packages/*.dist-info/direct_url.json"),
                  *(stage / ".venv").glob("lib/python*/site-packages/*.pth")]
    for path in candidates:
        if path.is_symlink():
            if str(stage) in str(path.readlink()):
                raise ProvisionError("Runtime symlink still references physical staging")
            continue
        if path.is_file() and os.fsencode(stage) in path.read_bytes():
            raise ProvisionError("Runtime executable or metadata still references physical staging")


def prepare(runtime, revision, workspace, state, dry_run=False, source=None):
    profile = validate_request(runtime, revision, workspace, state)
    prerequisites = check_platform()
    if not prerequisites["ready"]:
        raise ProvisionError("Missing preparation prerequisites: " + json.dumps(prerequisites))
    plan = {"status": "dry-run", "repository": REPOSITORY, "revision": revision,
            "profile": profile, "extras": list(EXTRAS), "excluded_extras": EXCLUDED_EXTRAS,
            "frontends": "Confined packaged Electron Desktop and compiled web UI; no launch",
            "browser": "PM-pinned agent-browser + Chromium/Playwright",
            "prerequisites": prerequisites,
            "registration": "Register this profile only after prepare succeeds; no registry or services are changed.",
            "spool": str(Path.home() / ".local/share/hermes-sandbox/control/spool")}
    if dry_run:
        return plan
    destination = Path(runtime)
    stage = Path(tempfile.mkdtemp(prefix=".hermes-prepare-", dir=destination.parent))
    created_state = False
    try:
        print("provision: acquiring pinned source", file=sys.stderr)
        checkout(stage, revision, source)
        for name in (".venv", ".provision"):
            (stage / name).mkdir(mode=0o700)
        print("provision: preparing frozen Python dependencies and private browser in bubblewrap", file=sys.stderr)
        _run(sandbox_command(stage, runtime), cwd=stage.parent)
        print("provision: building packaged Electron Desktop and web UI in bubblewrap", file=sys.stderr)
        _run(sandbox_command(stage, runtime, build=True), cwd=stage.parent)
        verify_inputs(stage)
        _run([SYSTEM_TOOLS["git"], "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
              "diff", "--no-ext-diff", "--quiet", "HEAD", "--"], cwd=stage)
        report_path = stage / ".provision/result.json"
        descriptor = os.open(report_path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, encoding="utf-8") as report_file:
            report = json.load(report_file)
        pins = json.loads((stage / "pm/lock.json").read_text())["packages"]
        if (report.get("extras") != list(EXTRAS)
                or any(report.get(name) != pins[name]["version"] for name in ("python", "uv"))
                or not (stage / ".venv/bin/python").is_symlink()):
            raise ProvisionError("Preparation did not produce the required runtime and dependency report")
        verify_venv(stage, destination, report)
        frontend_report = json.loads((stage / ".provision/frontends.json").read_text())
        verify_frontends(stage, frontend_report)
        for name in ("PLAYWRIGHT_BROWSERS_PATH", "AGENT_BROWSER_EXECUTABLE_PATH"):
            value = report.get("browser", {}).get(name)
            if (not isinstance(value, str) or os.path.normpath(value) != value
                    or not Path(value).is_relative_to(destination / ".provision/store")):
                raise ProvisionError("Browser paths must stay inside the private runtime store")
        validate_request(runtime, revision, workspace, state)
        seed = destination / ".provision/store"
        mutable = Path(state) / "tools"
        environment = {"HERMES_RUNTIME_DIR": str(mutable), "HERMES_INSTALL_ROOT": str(destination / ".provision"),
                       **{name: str(mutable / Path(value).relative_to(seed)) for name, value in report["browser"].items()}}
        manifest = {"version": 1, "repository": REPOSITORY, "revision": revision,
                    "inputs": INPUT_DIGESTS, "dependencies": report, "frontends": frontend_report,
                    "excluded_extras": EXCLUDED_EXTRAS, "environment": environment,
                    "pm_seed": {"source": str(seed), "destination": str(mutable), "copy_required": True,
                                "trust": "Mutable PM tools are less trusted than the pinned read-only application.",
                                "registration": "Seed on first confined launch into a fresh private tools generation; never overwrite live tools."},
                    "writable_generations": "Private profile state owns later PM generations; never mutate this runtime."}
        _write_json(stage / MANIFEST, manifest)
        if not Path(state).exists():
            Path(state).mkdir(mode=0o700)
            created_state = True
        publish(stage, destination)
        return {**plan, "status": "prepared", "manifest": str(destination / MANIFEST),
                "environment": manifest["environment"], "python": str(destination / ".venv/bin/python")}
    finally:
        if stage.exists():
            shutil.rmtree(stage)
            if created_state:
                Path(state).rmdir()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preparation = commands.add_parser("prepare", help="Build a new pinned runtime in a preparation user namespace")
    for name in ("runtime", "revision", "workspace", "state"):
        preparation.add_argument("--" + name, required=True)
    preparation.add_argument("--dry-run", action="store_true", help="Validate and print a plan without filesystem or network changes")
    preparation.add_argument("--source", help="Read a private checkout at the exact trusted pin instead of fetching GitHub again")
    doctor = commands.add_parser("doctor", aliases=["checkplatform"], help="Report system prerequisites; never install packages")
    doctor.add_argument("--desktop", action="store_true", help="Also require private Desktop's Xvfb/Xpra prerequisites")
    internal = commands.add_parser("_install", help=argparse.SUPPRESS)
    internal.add_argument("--runtime", required=True)
    build = commands.add_parser("_build", help=argparse.SUPPRESS)
    build.add_argument("--runtime", required=True)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "prepare":
            result = prepare(arguments.runtime, arguments.revision, arguments.workspace, arguments.state, arguments.dry_run, arguments.source)
        elif arguments.command == "_install":
            install_runtime(arguments.runtime)
            return 0
        elif arguments.command == "_build":
            build_frontends(arguments.runtime)
            return 0
        else:
            result = check_platform(arguments.desktop)
        print(json.dumps(result, sort_keys=True))
        return 0 if result.get("ready", True) else 1
    except (ProvisionError, ValueError, OSError, KeyError, tarfile.TarError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
