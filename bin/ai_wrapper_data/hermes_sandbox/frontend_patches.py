"""Reversible compatibility hooks for concurrent pinned Hermes frontends.

MemoryStore._mutate and skill_manage already reload inside native file locks;
auth refreshes already re-read under _provider_state_transaction. SessionDB
turn leases already fence writes and qualify holders with PID namespaces.
This adapter preserves those protocols and adds cross-process configuration
transactions, optimistic snapshot merging, and immediate skill cache refresh.
Every sandbox runtime and worker must install these hooks before entry.
"""

from contextlib import contextmanager
import copy
import fcntl
import functools
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import stat
import threading


PINNED_REVISION = "19cb1cbfedeafaca099be6ff0141a28a6c516c0f"
_MISSING = object()
_LOCKS = {}
_LOCKS_GUARD = threading.Lock()
LEARNING_MARKER = re.compile(r"\n\n\[Hermes shared learning revision: ([0-9a-f]{64})\]\Z")
DESKTOP_SOURCE_DIGESTS = {
    "apps/desktop/electron/main.ts": "bb3b24e09a0ffe69b9f5dbcb53f4fc573ff4af1b1783f89c7f369be7a77bc76f",
    "apps/desktop/electron/desktop-remote-route.ts": "f856a1bb3675baf1f7ad8ced264c3fa5ed40acf71f1563e66e77dc11549e4e86",
}


class StateConflict(RuntimeError):
    pass


def desktop_source_patches(sources):
    """Return pinned Electron compatibility overlays for provision's staging tree.

    Never write the official inspection checkout. Apply these returned texts
    before building the packaged Desktop. Existing profile and registry routes
    must not override the protected backend URL/token provided by the wrapper.
    """
    if set(sources) != set(DESKTOP_SOURCE_DIGESTS):
        raise StateConflict("Desktop patch requires both pinned source files")
    for name, expected in DESKTOP_SOURCE_DIGESTS.items():
        if hashlib.sha256(sources[name].encode("utf-8")).hexdigest() != expected:
            raise StateConflict("Desktop source does not match " + PINNED_REVISION)
    result = dict(sources)
    route_name = "apps/desktop/electron/desktop-remote-route.ts"
    route_anchor = "}: DesktopRemoteRouteInput): DesktopRemoteRoute | null {\n"
    route_gate = """  if (process.env.HERMES_SANDBOX_DESKTOP_ATTACH_ONLY === '1') {
    const url = String(env.url || '').trim()
    const token = String(env.token || '').trim()
    const endpoint = new URL(url)
    if (!token || endpoint.protocol !== 'http:' || !endpoint.port ||
        !['127.0.0.1', '[::1]'].includes(endpoint.hostname) ||
        endpoint.username || endpoint.password || endpoint.search || endpoint.hash || endpoint.pathname !== '/') {
      throw new Error('Sandbox Desktop requires its protected authenticated backend.')
    }
    return { authMode: 'token', kind: 'remote', source: 'env', token, url }
  }
"""
    main_name = "apps/desktop/electron/main.ts"
    main = result[main_name]
    resolver = "async function resolveHermesBackend(backendArgs: string[]): Promise<ResolvedHermesBackend> {\n"
    guard = """  if (process.env.HERMES_SANDBOX_DESKTOP_ATTACH_ONLY === '1') {
    throw new Error('Sandbox Desktop cannot spawn a second Hermes backend.')
  }
"""
    registry = """  opts: { passive?: boolean; spawnPriority?: LocalBackendSpawnPriority } = {}
) {
"""
    registry_gate = """  if (process.env.HERMES_SANDBOX_DESKTOP_ATTACH_ONLY === '1') {
    return ensureBackend(profile, opts)
  }
"""
    remote = """  options: { forceRegistryPrimary?: boolean; poolKey?: string; primary?: boolean } = {}
) {
"""
    remote_gate = """  if (process.env.HERMES_SANDBOX_DESKTOP_ATTACH_ONLY === '1') {
    const route = resolveDesktopRemoteRoute({ config: {}, registry: readDesktopConnectionsRegistry(),
      env: { url: process.env.HERMES_DESKTOP_REMOTE_URL, token: process.env.HERMES_DESKTOP_REMOTE_TOKEN } })
    if (!route || route.kind !== 'remote') {
      throw new Error('Sandbox Desktop lost its protected backend connection.')
    }
    return buildRemoteConnection(route.url, 'token', route.token, 'env')
  }
"""
    for anchor, gate in ((resolver, guard), (registry, registry_gate), (remote, remote_gate)):
        if main.count(anchor) != 1:
            raise StateConflict("Pinned Desktop integration seam is ambiguous")
        main = main.replace(anchor, anchor + gate, 1)
    if result[route_name].count(route_anchor) != 1:
        raise StateConflict("Pinned Desktop route seam is ambiguous")
    result[route_name] = result[route_name].replace(route_anchor, route_anchor + route_gate, 1)
    result[main_name] = main
    return result


def _private_directory(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise StateConflict("State must use an absolute private path")
    for component in (path, *path.parents):
        if component.is_symlink():
            raise StateConflict("Symlinked transaction paths are refused")
    metadata = path.stat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise StateConflict("State transaction directory must be private and owned")
    return path


@contextmanager
def transaction(state, name="config"):
    """Cooperative reentrant operation lock; never a whole-profile runtime lease."""
    if name not in {"config", "skills"}:
        raise StateConflict("Unknown profile transaction")
    state = _private_directory(state)
    key = (str(state), name)
    with _LOCKS_GUARD:
        gate, local = _LOCKS.setdefault(key, (threading.RLock(), threading.local()))
    with gate:
        if getattr(local, "depth", 0):
            local.depth += 1
            try:
                yield
            finally:
                local.depth -= 1
            return
        root_fd = os.open(state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        lock_fd = None
        try:
            lock_fd = os.open(f".frontend-{name}.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                              0o600, dir_fd=root_fd)
            metadata = os.fstat(lock_fd)
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                    or metadata.st_mode & 0o077 or metadata.st_nlink != 1):
                raise StateConflict("Unsafe profile transaction lock")
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            local.depth = 1
            try:
                yield
            finally:
                local.depth = 0
        finally:
            if lock_fd is not None:
                os.close(lock_fd)
            os.close(root_fd)


def merge_config(base, proposed, latest, path=()):
    """Apply changed leaves only; refuse concurrent changes of the same leaf."""
    if proposed == base:
        return copy.deepcopy(latest) if latest is not _MISSING else _MISSING
    if latest == base or proposed == latest:
        return copy.deepcopy(proposed) if proposed is not _MISSING else _MISSING
    if all(isinstance(value, dict) for value in (base, proposed, latest)):
        result = {}
        for key in base.keys() | proposed.keys() | latest.keys():
            value = merge_config(base.get(key, _MISSING), proposed.get(key, _MISSING),
                                 latest.get(key, _MISSING), (*path, str(key)))
            if value is not _MISSING:
                result[key] = value
        return result
    if base is _MISSING and isinstance(proposed, dict) and isinstance(latest, dict):
        return merge_config({}, proposed, latest, path)
    raise StateConflict("Configuration changed concurrently at " + (".".join(path) or "root"))


class ConfigSnapshot(dict):
    def __init__(self, content, loader, args, kwargs):
        super().__init__(content)
        self.baseline = copy.deepcopy(dict(content))
        self.loader = loader
        self.loader_args = args
        self.loader_kwargs = kwargs

    def copy(self):
        result = ConfigSnapshot(dict(self), self.loader, self.loader_args, self.loader_kwargs)
        result.baseline = copy.deepcopy(self.baseline)
        return result


class LearningRevision:
    """Refresh persisted prompt bytes only when shared learning actually changes."""

    def __init__(self, state, prompts, system):
        self.state = state
        self.prompts = prompts
        self.system = system

    def signature(self, agent):
        memory = getattr(agent, "_memory_store", None)
        files = []
        if memory is not None:
            for target in ("memory", "user"):
                path = memory._path_for(target)
                try:
                    metadata = path.stat()
                    signature = (metadata.st_dev, metadata.st_ino, metadata.st_size,
                                 metadata.st_mtime_ns, metadata.st_ctime_ns)
                except FileNotFoundError:
                    signature = None
                files.append((str(path), signature))
        with transaction(self.state, "skills"):
            skills = [(tier, str(root), self.prompts._build_skills_manifest(root))
                      for tier, root in self.prompts.get_skill_search_roots(self.state / "skills")]
        payload = json.dumps([files, skills], sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(payload.encode()).hexdigest()

    def matches(self, prompt, revision):
        marker = LEARNING_MARKER.search(prompt) if isinstance(prompt, str) else None
        return marker is not None and marker.group(1) == revision

    def refresh(self, agent):
        revision = self.signature(agent)
        prompt = getattr(agent, "_cached_system_prompt", None)
        if prompt is not None and not self.matches(prompt, revision):
            self.system.invalidate_system_prompt(agent)
        agent._frontend_learning_revision = revision

    def builder(self, original):
        @functools.wraps(original)
        def build(agent, *args, **kwargs):
            revision = self.signature(agent)
            agent._frontend_learning_revision = revision
            memory = getattr(agent, "_memory_store", None)
            if memory is not None:
                memory.load_from_disk()
            result = original(agent, *args, **kwargs)
            result = LEARNING_MARKER.sub("", result)
            return result + "\n\n[Hermes shared learning revision: " + revision + "]"
        return build

    def runtime_matcher(self, original):
        @functools.wraps(original)
        def match(agent, prompt):
            revision = getattr(agent, "_frontend_learning_revision", None) or self.signature(agent)
            return self.matches(prompt, revision) and original(agent, prompt)
        return match


def refresh_admitted_history(original, learning=None):
    """Refresh inactive frontends too, while holding the native durable lease."""
    @functools.wraps(original)
    def admit(agent, *args, **kwargs):
        admission = original(agent, *args, **kwargs)
        if admission.lease is None or admission.early_result is not None:
            return admission
        try:
            if learning is not None:
                learning.refresh(agent)
            database = admission.lease.db
            session_id = agent.session_id
            if database.get_session(session_id) is None:
                return admission
            latest = database.resolve_resume_session_id(session_id) or session_id
            agent.session_id = latest
            kwargs["task_context"]["session_id"] = latest
            history = database.get_messages_as_conversation(latest, repair_alternation=True, include_row_ids=True)
            from agent.session_persistence import _PERSIST_AFTER_ADMISSION_INTERRUPT
            carried = [message for message in (kwargs.get("conversation_history") or [])
                       if isinstance(message, dict) and message.get(_PERSIST_AFTER_ADMISSION_INTERRUPT)
                       and "_row_id" not in message]
            history.extend(carried)
            admission.conversation_history = history
            return admission
        except BaseException:
            admission.lease.release()
            raise
    return admit


class ConfigLock:
    def __init__(self, original, state):
        self.original = original
        self.state = state
        self.local = threading.local()

    def __enter__(self):
        self.original.acquire()
        context = transaction(self.state, "config")
        try:
            context.__enter__()
        except BaseException:
            self.original.release()
            raise
        stack = getattr(self.local, "stack", None)
        if stack is None:
            self.local.stack = stack = []
        stack.append(context)
        return self

    def __exit__(self, *error):
        try:
            return self.local.stack.pop().__exit__(*error)
        finally:
            self.original.release()


class FrontendPatches:
    """Context manager for install/uninstall; rollback installation failures."""

    def __init__(self, state):
        self.state = _private_directory(state)
        self.originals = []

    def _replace(self, module, name, replacement):
        original = getattr(module, name)
        self.originals.append((module, name, original, replacement))
        setattr(module, name, replacement)

    def _reader(self, original, config_lock):
        @functools.wraps(original)
        def read(*args, **kwargs):
            with config_lock:
                result = original(*args, **kwargs)
                if type(result) is dict:
                    return ConfigSnapshot(result, original, args, kwargs)
                return result
        return read

    def _writer(self, original, config_lock, data_position):
        @functools.wraps(original)
        def write(*args, **kwargs):
            with config_lock:
                arguments = list(args)
                data_key = "config" if data_position == 0 else "data"
                proposed = arguments[data_position] if len(arguments) > data_position else kwargs[data_key]
                if isinstance(proposed, ConfigSnapshot):
                    latest = proposed.loader(*proposed.loader_args, **proposed.loader_kwargs)
                    proposed = merge_config(proposed.baseline, dict(proposed), dict(latest))
                elif original.__name__ == "save_config":
                    kwargs = dict(kwargs, merge_existing=True)
                if len(arguments) > data_position:
                    arguments[data_position] = proposed
                else:
                    kwargs = dict(kwargs, **{data_key: proposed})
                return original(*arguments, **kwargs)
        return write

    def install(self):
        if self.originals:
            return self
        try:
            config = importlib.import_module("hermes_cli.config")
            skills = importlib.import_module("tools.skills_tool")
            manager = importlib.import_module("tools.skill_manager_tool")
            memory = importlib.import_module("tools.memory_tool_store")
            auth = importlib.import_module("hermes_cli.auth")
            leases = importlib.import_module("agent.turn_facade_lease")
            prompts = importlib.import_module("agent.prompt_builder")
            system = importlib.import_module("agent.system_prompt")
            conversation = importlib.import_module("agent.conversation_loop")
            required = ((memory.MemoryStore, "_mutate"), (auth, "_provider_state_transaction"),
                        (leases, "admit_durable_turn_lease"), (manager, "_skill_mutation_locks"),
                        (manager, "_skill_mutation_lock"), (skills, "clear_skills_cache"),
                        (system, "build_system_prompt"), (system, "invalidate_system_prompt"),
                        (conversation, "_stored_prompt_matches_runtime"))
            if any(not callable(getattr(module, name, None)) for module, name in required):
                raise StateConflict("Hermes state protocols do not match " + PINNED_REVISION)
            if isinstance(config._CONFIG_LOCK, ConfigLock):
                raise StateConflict("Frontend state hooks are already installed")
            lock = ConfigLock(config._CONFIG_LOCK, self.state)
            self._replace(config, "_CONFIG_LOCK", lock)
            learning = LearningRevision(self.state, prompts, system)
            self._replace(system, "build_system_prompt", learning.builder(system.build_system_prompt))
            self._replace(conversation, "_stored_prompt_matches_runtime",
                          learning.runtime_matcher(conversation._stored_prompt_matches_runtime))
            self._replace(leases, "admit_durable_turn_lease",
                          refresh_admitted_history(leases.admit_durable_turn_lease, learning))
            for name in ("load_config", "read_raw_config", "read_user_config_raw"):
                self._replace(config, name, self._reader(getattr(config, name), lock))
            for name, position in (("save_config", 0), ("atomic_config_write", 1), ("atomic_config_replace", 1)):
                self._replace(config, name, self._writer(getattr(config, name), lock, position))
            original_catalog = skills._skill_catalog
            original_manage = manager.skill_manage
            original_prompt = prompts.build_skills_system_prompt
            last_prompt_signature = None

            @functools.wraps(original_prompt)
            def prompt(*args, **kwargs):
                nonlocal last_prompt_signature
                with transaction(self.state, "skills"):
                    root = Path(kwargs["skills_dir_override"]) if kwargs.get("skills_dir_override") else prompts.get_skills_dir()
                    signature = tuple((tier, str(path), prompts._build_skills_manifest(path))
                                      for tier, path in prompts.get_skill_search_roots(root))
                    if signature != last_prompt_signature:
                        prompts.clear_skills_system_prompt_cache()
                        last_prompt_signature = signature
                    return original_prompt(*args, **kwargs)

            @functools.wraps(original_catalog)
            def catalog(*args, **kwargs):
                with transaction(self.state, "skills"):
                    skills.clear_skills_cache()
                    return original_catalog(*args, **kwargs)

            @functools.wraps(original_manage)
            def manage(*args, **kwargs):
                with transaction(self.state, "skills"):
                    try:
                        return original_manage(*args, **kwargs)
                    finally:
                        skills.clear_skills_cache()

            self._replace(skills, "_skill_catalog", catalog)
            self._replace(manager, "skill_manage", manage)
            self._replace(prompts, "build_skills_system_prompt", prompt)
        except BaseException:
            self.uninstall()
            raise
        return self

    def uninstall(self):
        for module, name, original, replacement in reversed(self.originals):
            if getattr(module, name) is replacement:
                setattr(module, name, original)
        self.originals.clear()

    def __enter__(self):
        return self.install()

    def __exit__(self, *error):
        self.uninstall()


def install(state):
    return FrontendPatches(state).install()
