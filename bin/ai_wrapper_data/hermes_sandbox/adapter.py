"""Broker integration for Hermes commit 19cb1cbfedeafaca099be6ff0141a28a6c516c0f.

The protected launcher invokes cli -- ARGS or worker KIND ATTEMPT. main() verifies
the checkout before importing Hermes, explicitly restores isolated Python import
paths, and enters Hermes' PM bootstrap. Broker transport uses IDs only and never
starts a host process. Workers consume the wrapper's read-only snapshot mount.
Durable broker identities replace kernel PID authority across private namespaces.
"""

from __future__ import annotations

import contextlib
import copy
import dataclasses
import fcntl
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import types
import uuid


UPSTREAM_COMMIT = "19cb1cbfedeafaca099be6ff0141a28a6c516c0f"
SNAPSHOT_PATH = Path("/run/hermes/worker.json")
CONTROL_SOCKET = Path("/run/hermes/control.sock")
KINDS = frozenset({"cron", "kanban"})
TERMINAL_STATES = frozenset({"completed", "failed", "unknown"})
POLL_SECONDS = 1.0
MAX_SNAPSHOT_BYTES = 1024 * 1024
_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z", re.ASCII)
_PROFILE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z", re.ASCII)
PINNED_FILES = {
    "cron/scheduler.py": "9fc6f48862ba58ff50fa9af3ab767c8f7beb1692bf7065cba274a87e446708aa",
    "cron/executions.py": "75e15a1be8aaacb6303c3a5fe9916aa41b6a89a5352bc74f0acf2d296a70b19c",
    "hermes_cli/kanban_db_dispatch.py": "0fb9d75d5d242cd9ea06bc0c9cec40658e6b1f21da56bd773767a9598f7843a6",
    "tools/process_registry.py": "4dacd3f6753d7b81e4ab338f7612624ec1f11c074cc969db49024a967a3b625e",
    "hermes_cli/main.py": "1491ff17d20b54c024c052003d394798cb2e673c8b9565b4a8be4c1fd6b21dae",
    "hermes_cli/config.py": "d8118b064bb442e10ce6a90e8e23c7f347b6ff532781febab206d9c652f3c7dd",
    "hermes_cli/profiles.py": "9095f318bb2a646b7685943e347b2ef9c2f99d3297da83133ad8a0f768f472c8",
    "hermes_constants.py": "5d43e6102c69748a2e64fc91623a49e1b0d76623416ce4ec37f23f216c3ce91f",
    "agent/kanban_turn_recovery.py": "c654aed03c88d45ca99ff0376e9e01bf2254033cf0bfb42f7187c68bd28b9e9d",
    "tools/registry.py": "597777c40320f90f5ca62f10d74a3112061193d2c712b752fd9d7300350f3c4b",
    "tools/mcp_tool_discovery.py": "01d977547d3871bd1e9dd2b2ae5af4fa3212e6e126c8eb68ed770329ee39e83d",
    "tools/terminal_tool_backends.py": "cc7642a4ce80deb12772bc17cc8221ad07a8317cd2d899aefdb95ef712047d60",
    "tools/terminal_tool_config.py": "89c5cc844c75f0c42a078038a98eb8a594e0ee6e49e5f96dfb292ca33fdd8f75",
}
CHILD_MODULES = frozenset({"hermes_cli.main", "tui_gateway.entry", "tui_gateway.compute_host",
                           "gateway.run", "cron.scheduler"})
_ACTIVE_ADAPTER = None
CRON_JOB_KEYS = frozenset({
    "id", "name", "prompt", "schedule", "schedule_display", "skills", "skill", "model",
    "provider", "base_url", "reasoning_effort", "enabled_toolsets", "no_agent", "script",
    "interpreter", "monitor_script", "monitor_url", "monitor_state", "workdir", "origin",
    "deliver", "failure_deliver", "repeat", "enabled", "state", "created_at", "updated_at",
    "next_run_at", "last_run_at", "last_status", "last_error", "last_failure", "failure_streak",
    "last_delivery_error", "last_delivery_queued", "last_delivery_unverified", "last_dispatch",
    "last_fire_error", "paused_at", "paused_reason", "pending_slot", "preflight_alerted",
    "manual_run_at", "manual_run_prompt", "context_from", "attach_to_session", "execution_id",
    "fire_claim", "run_claim", "latest_execution", "_scheduled_instant", "_quota_hold_seconds",
    "_model_unreachable", "_bot_chat_delivery_receipts", "_bot_chat_run_id",
    "_notification_all_targets_suppressed",
})
KANBAN_TASK_KEYS = frozenset({
    "id", "title", "body", "assignee", "status", "priority", "created_by", "created_at",
    "started_at", "completed_at", "workspace_kind", "workspace_path", "claim_lock",
    "claim_expires", "tenant", "branch_name", "project_id", "result", "idempotency_key",
    "consecutive_failures", "worker_pid", "last_failure_error", "max_runtime_seconds",
    "last_heartbeat_at", "current_run_id", "workflow_template_id", "current_step_key", "skills",
    "model_override", "provider_override", "reasoning_effort", "max_retries", "goal_mode",
    "goal_max_turns", "session_id", "block_kind", "block_recurrences", "completion_contract",
})


def _json_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate snapshot key")
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError("Non-finite snapshot value")


def _read_json(path, *, limit=MAX_SNAPSHOT_BYTES):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        import stat
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("Expected a regular snapshot file")
        encoded = stream.read(limit + 1)
    if len(encoded) > limit:
        raise ValueError("Worker snapshot is too large")
    return json.loads(encoded, object_pairs_hook=_json_pairs, parse_constant=_invalid_constant)


def _closed_object(value, allowed, *, required=()):
    if not isinstance(value, dict) or not set(value) <= allowed or not set(required) <= set(value):
        raise ValueError("Unsupported nested worker payload")


def _validate_cron_job(job):
    _closed_object(job, CRON_JOB_KEYS, required={"id", "execution_id"})
    for name, keys in (
        ("schedule", {"kind", "expr", "minutes", "run_at", "display"}),
        ("repeat", {"times", "completed"}),
        ("fire_claim", {"by", "at", "scheduled_at", "manual"}),
        ("run_claim", {"by", "at", "outage"}),
        ("origin", {"platform", "chat_id", "chat_name", "thread_id", "user_id", "user_name",
                    "session_id", "session_key", "profile", "channel_id"}),
    ):
        if job.get(name) is not None:
            _closed_object(job[name], keys)
    for name in ("skills", "enabled_toolsets", "context_from"):
        value = job.get(name)
        if value is not None and (not isinstance(value, list) or any(not isinstance(item, str) for item in value)):
            raise ValueError("Invalid cron string list")


def _validate_kanban_task(task):
    _closed_object(task, KANBAN_TASK_KEYS, required={"id", "assignee", "current_run_id", "claim_lock"})
    if type(task["current_run_id"]) is not int or task["current_run_id"] <= 0:
        raise ValueError("Invalid Kanban attempt")
    if not isinstance(task["claim_lock"], str) or not task["claim_lock"]:
        raise ValueError("Invalid Kanban claim")
    for name, value in task.items():
        if name == "skills":
            if value is not None and (not isinstance(value, list) or any(not isinstance(item, str) for item in value)):
                raise ValueError("Invalid Kanban skills")
        elif not isinstance(value, (str, int, type(None))):
            raise ValueError("Unsupported Kanban field")


def validate_runtime(runtime):
    """Check git identity and tracked source integrity before any upstream import."""
    runtime = _absolute_directory(runtime)
    git = ["/usr/bin/git", "--no-optional-locks", "-c", "core.fsmonitor=false",
           "-c", "core.hooksPath=/dev/null", "-C", str(runtime)]
    revision = subprocess.run(git + ["rev-parse", "HEAD"], capture_output=True,
                              text=True, check=False, timeout=10)
    if revision.returncode or revision.stdout.strip() != UPSTREAM_COMMIT:
        raise ValueError("Hermes runtime is not the approved pinned commit")
    clean = subprocess.run(git + ["diff", "--quiet", "--no-ext-diff", "--no-textconv", "HEAD", "--"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           check=False, timeout=10)
    if clean.returncode:
        raise ValueError("Hermes runtime has modified tracked sources")
    for relative, expected in PINNED_FILES.items():
        source = runtime / relative
        if not source.resolve().is_relative_to(runtime.resolve()):
            raise ValueError("Hermes source escapes the pinned runtime")
        if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise ValueError("Hermes runtime source does not match the approved pin")
    return runtime


def _identifier(value, *, profile=False):
    pattern = _PROFILE if profile else _IDENTIFIER
    if not isinstance(value, str) or not pattern.fullmatch(value) or ".." in value:
        raise ValueError("Invalid worker identity")
    return value


def _absolute_directory(value):
    directory = Path(value)
    if not directory.is_absolute() or ".." in directory.parts:
        raise ValueError("Worker directories must be absolute")
    return directory


def _seed_private_store(seed, state):
    target = state / "tools"
    descriptor = os.open(state / ".pm-seed.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                or metadata.st_mode & 0o077 or metadata.st_nlink != 1):
            raise ValueError("Unsafe private PM seed lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        if target.is_symlink():
            raise ValueError("Private PM store cannot be a symlink")
        if target.exists():
            if not target.is_dir():
                raise ValueError("Private PM store must be a directory")
            return target
        for directory, children, files in os.walk(seed, followlinks=False):
            for name in (*children, *files):
                path = Path(directory) / name
                if path.is_symlink() and not path.resolve().is_relative_to(seed.resolve()):
                    raise ValueError("Prepared PM seed symlink escapes its store")
        staging = Path(tempfile.mkdtemp(prefix=".tools-seed-", dir=state))
        try:
            shutil.copytree(seed, staging, symlinks=True, dirs_exist_ok=True)
            provision = importlib.import_module("provision")
            provision.publish(staging, target)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
        return target
    finally:
        os.close(descriptor)


def _apply_runtime_environment(runtime, state):
    manifest = _read_json(runtime / "hermes-provision.json")
    if (not isinstance(manifest, dict) or type(manifest.get("version")) is not int
            or manifest["version"] != 1 or manifest.get("revision") != UPSTREAM_COMMIT):
        raise ValueError("Prepared runtime manifest does not match the reviewed pin")
    expected = {"HERMES_RUNTIME_DIR", "HERMES_INSTALL_ROOT", "PLAYWRIGHT_BROWSERS_PATH",
                "AGENT_BROWSER_EXECUTABLE_PATH"}
    environment = manifest.get("environment")
    if not isinstance(environment, dict) or set(environment) != expected:
        raise ValueError("Unsupported prepared runtime environment")
    seed_policy = manifest.get("pm_seed")
    seed = runtime / ".provision/store"
    if (not isinstance(seed_policy, dict) or seed_policy.get("source") != str(seed)
            or seed_policy.get("copy_required") is not True or not seed.is_dir()
            or seed.is_symlink()):
        raise ValueError("Prepared runtime has no confined PM seed")
    original = _absolute_directory(seed_policy.get("destination", ""))
    if (environment["HERMES_RUNTIME_DIR"] != str(original)
            or environment["HERMES_INSTALL_ROOT"] != str(runtime / ".provision")
            or not (runtime / ".provision/install-stamp.json").is_file()):
        raise ValueError("Prepared PM environment has invalid ownership")
    paths = {}
    for name in ("PLAYWRIGHT_BROWSERS_PATH", "AGENT_BROWSER_EXECUTABLE_PATH"):
        value = _absolute_directory(environment[name])
        if str(value) != environment[name] or not value.is_relative_to(original):
            raise ValueError("Prepared browser paths escape private PM state")
        relative = value.relative_to(original)
        source = seed / relative
        if not source.exists() or not source.resolve().is_relative_to(seed.resolve()):
            raise ValueError("Prepared browser assets are unavailable")
        paths[name] = relative
    target = _seed_private_store(seed, state)
    os.environ.update({"HERMES_RUNTIME_DIR": str(target),
                       "HERMES_INSTALL_ROOT": str(runtime / ".provision"),
                       **{name: str(target / relative) for name, relative in paths.items()}})


def _worker_handle(profile, task_id, attempt_id):
    identity = json.dumps([profile, task_id, attempt_id], separators=(",", ":"))
    return (int.from_bytes(hashlib.sha256(identity.encode()).digest()[:8], "big") >> 1) | (1 << 40)


def write_snapshot(state, *, profile, kind, task_id, attempt_id, payload):
    """Publish the exact broker envelope once, without following spool symlinks."""
    state = _absolute_directory(state)
    _identifier(profile, profile=True)
    _identifier(task_id)
    _identifier(attempt_id)
    if kind not in KINDS or not isinstance(payload, dict):
        raise ValueError("Unsupported worker payload")
    envelope = dict(kind=kind, task_id=task_id, attempt_id=attempt_id,
                    profile=profile, payload=payload)
    encoded = json.dumps(envelope, ensure_ascii=False, allow_nan=False).encode("utf-8")
    if len(encoded) > MAX_SNAPSHOT_BYTES:
        raise ValueError("Worker snapshot is too large")
    descriptor = os.open(state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = f".{attempt_id}.{uuid.uuid4().hex}.tmp"
    try:
        for component in ("worker-spool", kind, task_id):
            with contextlib.suppress(FileExistsError):
                os.mkdir(component, mode=0o700, dir_fd=descriptor)
            next_descriptor = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                      dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        output = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=descriptor)
        with os.fdopen(output, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, f"{attempt_id}.json", src_dir_fd=descriptor,
                dst_dir_fd=descriptor, follow_symlinks=False)
        os.fsync(descriptor)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary, dir_fd=descriptor)
        os.close(descriptor)
    return state / "worker-spool" / kind / task_id / f"{attempt_id}.json"


class Adapter:
    """Install process-local hooks; the broker independently owns worker units.

    resolve_profile(home) may return (profile, state) for a multiplexed runtime.
    Without it, the adapter accepts only its own state as HERMES_HOME. request
    receives exactly action/profile/kind/task_id/attempt_id, never argv or env.
    """

    def __init__(self, profile, state, request, *, resolve_profile=None):
        self.profile = _identifier(profile, profile=True)
        self.state = _absolute_directory(state)
        self.request = request
        self.resolve_profile = resolve_profile
        self._originals = []

    def _owner(self, home):
        home = _absolute_directory(home)
        if self.resolve_profile is not None:
            profile, state = self.resolve_profile(home)
            return _identifier(profile, profile=True), _absolute_directory(state)
        if home.resolve() != self.state.resolve():
            raise ValueError("Routed profile requires an explicit profile resolver")
        return self.profile, self.state

    def _call(self, action, profile, kind, task_id, attempt_id):
        if action not in {"launch", "status", "cancel"} or kind not in KINDS:
            raise ValueError("Unsupported broker operation")
        _identifier(profile, profile=True)
        _identifier(task_id)
        _identifier(attempt_id)
        result = self.request(dict(action=action, profile=profile, kind=kind,
                                   task_id=task_id, attempt_id=attempt_id))
        if not isinstance(result, dict) or result.get("ok") is False:
            raise RuntimeError("Broker did not acknowledge the worker request")
        if any(result.get(name) != value for name, value in (
            ("profile", profile), ("kind", kind), ("task_id", task_id), ("attempt_id", attempt_id),
        )) or result.get("stage") not in {"accepted", "adopted", "finished"}:
            raise RuntimeError("Broker worker identity mismatch")
        outcomes = {"accepted": {"pending", "unknown"}, "adopted": {"running"},
                    "finished": {"succeeded", "failed", "cancelled", "unknown"}}
        if result.get("outcome") not in outcomes[result["stage"]]:
            raise RuntimeError("Broker worker lifecycle mismatch")
        return result

    def install(self):
        """Replace only the pinned upstream cron handoff and Kanban spawn seams."""
        if self._originals:
            return self
        try:
            return self._install_hooks()
        except BaseException:
            self.uninstall()
            raise

    def _install_hooks(self):
        scheduler = importlib.import_module("cron.scheduler")
        kanban = importlib.import_module("hermes_cli.kanban_db_dispatch")
        required = ("_launch_external_cron_worker", "mark_execution_handoff_pending",
                    "_record_external_cron_worker", "_ExternalWorkerPostHandoffError",
                    "_running_lock", "_restart_safe_waiter_job_ids", "_scope_isolated_job_ids")
        if any(not hasattr(scheduler, name) for name in required) or not hasattr(kanban, "_default_spawn"):
            raise RuntimeError(f"Hermes worker seams do not match {UPSTREAM_COMMIT}")
        ledger = importlib.import_module("patches.ledger")
        executions = importlib.import_module("cron.executions")
        for name, replacement in ledger.broker_owner_functions(executions, self.execution_owner_alive).items():
            original = getattr(executions, name)
            self._originals.append((executions, name, original, replacement))
            setattr(executions, name, replacement)
            if hasattr(scheduler, name):
                self._originals.append((scheduler, name, getattr(scheduler, name), replacement))
                setattr(scheduler, name, replacement)
        for module, name, replacement in (
            (scheduler, "_launch_external_cron_worker", self.launch_cron),
            (kanban, "_default_spawn", self.spawn_kanban),
            (kanban, "_terminate_reclaimed_worker", self.terminate_kanban),
            (kanban, "_kill_fn", lambda signal_fn: self.cancel_pid),
            (kanban, "_worker_alive", self.worker_alive),
            (kanban, "_pid_alive", self.worker_alive),
            (kanban, "_process_fingerprint", self.worker_fingerprint),
            (kanban, "_pid_recycled", self.worker_recycled),
            (kanban, "enforce_max_runtime", self.enforce_kanban_runtime),
        ):
            self._originals.append((module, name, getattr(module, name), replacement))
            setattr(module, name, replacement)
        original_tick = kanban.dispatch_once

        def dispatch_once(conn, **options):
            self.reconcile_kanban(conn, board=options.get("board"))
            return original_tick(conn, **options)

        self._originals.append((kanban, "dispatch_once", original_tick, dispatch_once))
        kanban.dispatch_once = dispatch_once
        board_db = importlib.import_module("hermes_cli.kanban_db")
        for name in ("_terminate_reclaimed_worker", "dispatch_once", "_default_spawn", "_worker_alive",
                     "_pid_alive", "_process_fingerprint", "_pid_recycled", "enforce_max_runtime"):
            if hasattr(board_db, name):
                replacement = getattr(kanban, name)
                self._originals.append((board_db, name, getattr(board_db, name), replacement))
                setattr(board_db, name, replacement)
        recovery = importlib.import_module("agent.kanban_turn_recovery")
        original = recovery.worker_claim_is_live
        replacement = _broker_claim_check(original, self.profile, self.state)
        self._originals.append((recovery, "worker_claim_is_live", original, replacement))
        recovery.worker_claim_is_live = replacement
        return self

    def uninstall(self):
        for module, name, original, replacement in reversed(self._originals):
            if getattr(module, name) == replacement:
                setattr(module, name, original)
        self._originals.clear()

    def launch_cron(self, job):
        """Keep upstream's synchronous handoff contract and durable execution authority."""
        scheduler = importlib.import_module("cron.scheduler")
        secrets = importlib.import_module("agent.secret_scope")
        provider = importlib.import_module("cron.scheduler_provider")
        home = scheduler._get_hermes_home()
        profile, state = self._owner(home)
        task_id = _identifier(str(job["id"]))
        attempt_id = _identifier(str(job["execution_id"]))
        _validate_cron_job(job)
        if scheduler.mark_execution_handoff_pending(attempt_id) is None:
            raise RuntimeError("Cron execution no longer belongs to this dispatcher")
        write_snapshot(state, profile=profile, kind="cron", task_id=task_id,
                       attempt_id=attempt_id, payload={
                           "job": job, "profile_home": str(Path(home).resolve()),
                           "multiplex_active": secrets.is_multiplex_active() or provider.routed_profile_fire(),
                       })
        key = scheduler._inflight_key(task_id)
        with scheduler._running_lock:
            scheduler._restart_safe_waiter_job_ids.add(key)
        try:
            try:
                record = self._call("launch", profile, "cron", task_id, attempt_id)
                scheduler._record_external_cron_worker(task_id, None, scope_isolated=True)
                while True:
                    current = scheduler.get_execution(attempt_id)
                    if current and current.get("status") in TERMINAL_STATES:
                        return True
                    if current and current.get("status") == "running":
                        scheduler.recover_interrupted_executions()
                    if record["stage"] == "finished":
                        scheduler.recover_interrupted_executions()
                        current = scheduler.get_execution(attempt_id)
                        if current and current.get("status") in TERMINAL_STATES:
                            return True
                        if current and current.get("status") == "claimed":
                            scheduler.finish_execution(attempt_id, success=False,
                                                       error="Broker worker exited before cron adoption")
                            raise RuntimeError("Broker worker exited before cron adoption")
                        raise RuntimeError("Broker worker exited without a durable cron outcome")
                    time.sleep(POLL_SECONDS)
                    record = self._call("status", profile, "cron", task_id, attempt_id)
            except Exception as error:
                raise scheduler._ExternalWorkerPostHandoffError(str(error)) from error
        finally:
            with scheduler._running_lock:
                scheduler._restart_safe_waiter_job_ids.discard(key)
                scheduler._scope_isolated_job_ids.discard(key)

    def execution_owner_alive(self, row):
        """Broker identity, rather than a PID from another namespace, proves liveness."""
        attempt_id = _identifier(str(row["id"]))
        candidates = list((self.state / "worker-spool" / "cron").glob(f"*/{attempt_id}.json"))
        if len(candidates) != 1:
            return True
        try:
            snapshot = _worker_snapshot("cron", attempt_id, self.profile, candidates[0])
            record = self._call("status", self.profile, "cron", snapshot["task_id"], attempt_id)
            return record["stage"] != "finished"
        except (OSError, ValueError, RuntimeError):
            return True

    def spawn_kanban(self, task, workspace, *, board=None):
        """Retain the claimed Task and board pins; worker-side adoption is authoritative."""
        if not task.assignee or task.current_run_id is None or not task.claim_lock:
            raise ValueError("Kanban worker requires an assignee and a claimed attempt")
        profiles = importlib.import_module("hermes_cli.profiles")
        profile = _identifier(profiles.normalize_profile_name(task.assignee), profile=True)
        home = profiles.resolve_profile_env(profile)
        resolved_profile, state = self._owner(home)
        if resolved_profile != profile:
            raise ValueError("Kanban assignee does not match the resolved profile")
        kanban = importlib.import_module("hermes_cli.kanban_db")
        task_id = _identifier(str(task.id))
        attempt_id = _identifier(str(task.current_run_id))
        _validate_kanban_task(dataclasses.asdict(task))
        write_snapshot(state, profile=profile, kind="kanban", task_id=task_id,
                       attempt_id=attempt_id, payload={
                           "task": dataclasses.asdict(task),
                           "workspace": str(_absolute_directory(workspace)),
                           "board": board,
                           "db": str(_absolute_directory(kanban.kanban_db_path(board=board))),
                           "workspaces_root": str(_absolute_directory(kanban.workspaces_root(board=board))),
                       })
        try:
            self._call("launch", profile, "kanban", task_id, attempt_id)
        except Exception:
            try:
                self._call("status", profile, "kanban", task_id, attempt_id)
            except Exception as error:
                if getattr(error, "code", None) == "task_not_found":
                    registry = importlib.import_module("tools.process_registry")
                    raise registry.RestartSafeScopeUnavailable("Broker rejected the worker") from error
        return None

    def _pid_identity(self, pid, claim_lock=None):
        if type(pid) is not int or pid <= 0:
            raise ValueError("Invalid worker PID")
        matches = []
        for owner_file in (self.state / "worker-spool" / "kanban").glob("*/*.owner.json"):
            owner = _read_json(owner_file, limit=4096)
            if owner.get("pid") != pid or (claim_lock is not None and owner.get("claim_lock") != claim_lock):
                continue
            if set(owner) != {"pid", "claim_lock", "profile", "kind", "task_id", "attempt_id"}:
                raise ValueError("Invalid worker PID mapping")
            for name in ("profile", "task_id", "attempt_id"):
                _identifier(owner[name])
            if owner["profile"] != self.profile or owner["kind"] != "kanban":
                raise ValueError("Foreign worker PID mapping")
            matches.append(owner)
        if len(matches) != 1:
            raise ValueError("Worker PID has no unique broker identity")
        return matches[0]

    def worker_alive(self, pid, started_at=None):
        if not pid:
            return False
        try:
            identity = self._pid_identity(pid)
            record = self._call("status", **{name: identity[name] for name in (
                "profile", "kind", "task_id", "attempt_id")})
            return record["stage"] != "finished"
        except (OSError, ValueError, RuntimeError):
            return True

    def worker_fingerprint(self, pid):
        try:
            identity = self._pid_identity(pid)
            return "broker|" + identity["attempt_id"]
        except (OSError, ValueError):
            return None

    def worker_recycled(self, pid, started_at):
        fingerprint = self.worker_fingerprint(pid)
        return fingerprint is None or (started_at is not None and fingerprint != started_at)

    def cancel_pid(self, pid, signal_number=None):
        try:
            identity = self._pid_identity(pid)
            record = self._call("cancel", **{name: identity[name] for name in (
                "profile", "kind", "task_id", "attempt_id")})
            if record["stage"] != "finished":
                raise OSError("Broker has not confirmed worker cancellation")
        except (ValueError, RuntimeError) as error:
            raise OSError("Broker worker cancellation is unconfirmed") from error

    def terminate_kanban(self, pid, claim_lock, *, signal_fn=None, started_at=None):
        result = dict(prev_pid=pid, host_local=True, termination_attempted=False,
                      terminated=False, sigkill=False)
        if not pid:
            return result
        try:
            identity = self._pid_identity(pid, claim_lock)
            record = self._call("cancel", **{name: identity[name] for name in (
                "profile", "kind", "task_id", "attempt_id")})
            result.update(termination_attempted=True, terminated=record["stage"] == "finished")
        except (OSError, ValueError, RuntimeError):
            result["signal_refused"] = True
        return result

    def reconcile_kanban(self, conn, *, board=None):
        """Protect pending launches and account workers that die before publishing a PID."""
        dispatch = importlib.import_module("hermes_cli.kanban_db_dispatch")
        board_db = importlib.import_module("hermes_cli.kanban_db")
        rows = conn.execute(
            "SELECT id, assignee, current_run_id, claim_lock FROM tasks "
            "WHERE status='running' AND current_run_id IS NOT NULL").fetchall()
        for row in rows:
            if row["assignee"] != self.profile:
                continue
            task_id, attempt_id = str(row["id"]), str(row["current_run_id"])
            snapshot = self.state / "worker-spool" / "kanban" / task_id / f"{attempt_id}.json"
            if not snapshot.is_file():
                continue
            try:
                record = self._call("status", self.profile, "kanban", task_id, attempt_id)
            except Exception:
                record = {"stage": "accepted"}
            with board_db.write_txn(conn):
                current = conn.execute("SELECT current_run_id, claim_lock, status FROM tasks WHERE id=?",
                                       (task_id,)).fetchone()
                if (not current or current["status"] != "running"
                        or current["current_run_id"] != row["current_run_id"]
                        or current["claim_lock"] != row["claim_lock"]):
                    continue
                if record["stage"] != "finished":
                    expires = int(time.time()) + 300
                    conn.execute("UPDATE tasks SET claim_expires=MAX(COALESCE(claim_expires,0),?) WHERE id=?",
                                 (expires, task_id))
                    conn.execute("UPDATE task_runs SET claim_expires=? WHERE id=?",
                                 (expires, row["current_run_id"]))
                    continue
                self._record_kanban_failure_locked(
                    conn, task_id, "Broker worker exited without a terminal Kanban transition",
                    outcome="crashed", release_claim=True, end_run=True,
                    event_payload_extra={"broker_outcome": record.get("outcome", "unknown")})

    def _record_kanban_failure_locked(self, conn, task_id, error, **options):
        dispatch = importlib.import_module("hermes_cli.kanban_db_dispatch")
        board_db = importlib.import_module("hermes_cli.kanban_db")
        original = dispatch._record_task_failure
        namespace = dict(original.__globals__)
        nested_db = types.SimpleNamespace(**vars(board_db))
        nested_db.write_txn = lambda connection: board_db.write_txn(connection, allow_nested=True)
        namespace["_kb"] = nested_db
        record = types.FunctionType(original.__code__, namespace, original.__name__,
                                    original.__defaults__, original.__closure__)
        record.__kwdefaults__ = original.__kwdefaults__
        return record(conn, task_id, error, **options)

    def enforce_kanban_runtime(self, conn, *, signal_fn=None):
        """Only release a timed-out attempt after the broker confirms it has stopped."""
        board_db = importlib.import_module("hermes_cli.kanban_db")
        rows = conn.execute(
            "SELECT tasks.id, tasks.assignee, tasks.current_run_id, tasks.claim_lock, "
            "tasks.worker_pid, tasks.max_runtime_seconds, task_runs.started_at "
            "FROM tasks JOIN task_runs ON tasks.current_run_id=task_runs.id "
            "WHERE tasks.status='running' AND tasks.max_runtime_seconds IS NOT NULL").fetchall()
        timed_out = []
        for row in rows:
            if row["assignee"] != self.profile or not row["worker_pid"]:
                continue
            elapsed = int(time.time()) - int(row["started_at"])
            limit = int(row["max_runtime_seconds"])
            if elapsed < limit:
                continue
            termination = self.terminate_kanban(row["worker_pid"], row["claim_lock"])
            if not termination["terminated"]:
                continue
            with board_db.write_txn(conn):
                current = conn.execute("SELECT current_run_id, claim_lock, status FROM tasks WHERE id=?",
                                       (row["id"],)).fetchone()
                if (not current or current["status"] != "running"
                        or current["current_run_id"] != row["current_run_id"]
                        or current["claim_lock"] != row["claim_lock"]):
                    continue
                self._record_kanban_failure_locked(
                    conn, row["id"], f"elapsed {elapsed}s > limit {limit}s",
                    outcome="timed_out", release_claim=True, end_run=True)
                timed_out.append(row["id"])
        return timed_out

    def broker_tool(self, action, arguments):
        if action not in {"status", "cancel"}:
            raise ValueError("Unsupported worker tool")
        if not isinstance(arguments, dict) or set(arguments) != {"kind", "task_id", "attempt_id"}:
            raise ValueError("Worker tools accept only kind, task_id and attempt_id")
        return self._call(action, self.profile, **arguments)


def install(profile, state, request, *, resolve_profile=None):
    return Adapter(profile, state, request, resolve_profile=resolve_profile).install()


def _worker_snapshot(kind, attempt_id, profile, snapshot_path):
    if kind not in KINDS:
        raise ValueError("Unsupported worker kind")
    _identifier(attempt_id)
    _identifier(profile, profile=True)
    snapshot = _read_json(snapshot_path)
    if not isinstance(snapshot, dict) or set(snapshot) != {"kind", "task_id", "attempt_id", "profile", "payload"}:
        raise ValueError("Invalid worker snapshot envelope")
    if any(snapshot[name] != expected for name, expected in (
        ("kind", kind), ("attempt_id", attempt_id), ("profile", profile),
    )) or not isinstance(snapshot["payload"], dict):
        raise ValueError("Worker snapshot identity mismatch")
    _identifier(snapshot["task_id"])
    return snapshot


def _exec_kanban(command, *, cwd, env, stdin, stdout, stderr, **unused):
    """Replace the already isolated worker with upstream's static CLI command."""
    if command[:3] != [sys.executable, "-m", "hermes_cli.main"]:
        raise ValueError("Unexpected Kanban worker command")
    if cwd:
        os.chdir(cwd)
    with open(os.devnull, "rb") as null_input:
        os.dup2(null_input.fileno(), 0)
    os.dup2(stdout.fileno(), 1)
    os.dup2(stdout.fileno(), 2)
    adapter_command = [sys.executable, "-I", str(Path(__file__).resolve()), "cli", "--", *command[3:]]
    os.execvpe(adapter_command[0], adapter_command, env)


def _broker_claim_check(original, profile, state):
    def check():
        try:
            task_id = _identifier(os.environ.get("HERMES_KANBAN_TASK", ""))
            attempt_id = _identifier(os.environ.get("HERMES_KANBAN_RUN_ID", ""))
            claim = os.environ.get("HERMES_KANBAN_CLAIM_LOCK", "")
            handle = _worker_handle(profile, task_id, attempt_id)
            owner = _read_json(state / "worker-spool/kanban" / task_id / f"{attempt_id}.owner.json", limit=4096)
            expected = dict(pid=handle, claim_lock=claim, profile=profile, kind="kanban",
                            task_id=task_id, attempt_id=attempt_id)
            if not claim or owner != expected:
                return False
            namespace = dict(original.__globals__)
            namespace["os"] = types.SimpleNamespace(**{**vars(os), "getpid": lambda: handle})
            native = types.FunctionType(original.__code__, namespace, original.__name__,
                                        original.__defaults__, original.__closure__)
            native.__kwdefaults__ = original.__kwdefaults__
            return native()
        except (OSError, ValueError):
            return False
    return check


def run_worker(kind, attempt_id, profile, state, *, snapshot_path=SNAPSHOT_PATH):
    """Run an existing upstream attempt inside bwrap, never a snapshot-supplied command."""
    snapshot = _worker_snapshot(kind, attempt_id, profile, snapshot_path)
    state = _absolute_directory(state)
    payload = snapshot["payload"]
    if kind == "cron":
        if set(payload) != {"job", "profile_home", "multiplex_active"} or not isinstance(payload["job"], dict):
            raise ValueError("Invalid cron payload")
        _validate_cron_job(payload["job"])
        if (str(payload["job"].get("id")) != snapshot["task_id"]
                or str(payload["job"].get("execution_id")) != attempt_id
                or Path(payload["profile_home"]).resolve() != state.resolve()
                or type(payload["multiplex_active"]) is not bool):
            raise ValueError("Cron payload identity mismatch")
        worker_dir = state / "cron" / "external-workers"
        worker_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        scheduler = importlib.import_module("cron.scheduler")
        with tempfile.TemporaryDirectory(prefix="hermes-cron-") as temporary:
            worker_file = Path(temporary) / "payload.json"
            descriptor = os.open(worker_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(payload, stream, allow_nan=False)
            return scheduler._run_external_worker_payload(worker_file, worker_dir / f"{attempt_id}.ready")
    if set(payload) != {"task", "workspace", "board", "db", "workspaces_root"}:
        raise ValueError("Invalid Kanban payload")
    _validate_kanban_task(payload["task"])
    if payload["board"] is not None:
        _identifier(payload["board"])
    kanban = importlib.import_module("hermes_cli.kanban_db")
    task = kanban.Task(**payload["task"])
    if (str(task.id) != snapshot["task_id"] or str(task.current_run_id) != attempt_id
            or task.assignee != profile or not task.claim_lock):
        raise ValueError("Kanban payload identity mismatch")
    for path_key in ("workspace", "db", "workspaces_root"):
        _absolute_directory(payload[path_key])
    os.environ["HERMES_KANBAN_DB"] = payload["db"]
    os.environ["HERMES_KANBAN_WORKSPACES_ROOT"] = payload["workspaces_root"]
    dispatch = importlib.import_module("hermes_cli.kanban_db_dispatch")
    owner_file = state / "worker-spool" / "kanban" / snapshot["task_id"] / f"{attempt_id}.owner.json"
    descriptor = os.open(owner_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(dict(pid=_worker_handle(profile, snapshot["task_id"], attempt_id),
                       claim_lock=task.claim_lock, profile=profile,
                       kind=kind, task_id=task.id, attempt_id=attempt_id), stream)
        stream.flush()
        os.fsync(stream.fileno())
    with kanban.connect(board=payload["board"]) as connection:
        with kanban.write_txn(connection):
            current = connection.execute("SELECT current_run_id, claim_lock, status FROM tasks WHERE id=?",
                                         (task.id,)).fetchone()
            if (not current or current["status"] != "running" or current["current_run_id"] != task.current_run_id
                    or current["claim_lock"] != task.claim_lock):
                raise ValueError("Kanban claim changed before worker adoption")
            handle = _worker_handle(profile, snapshot["task_id"], attempt_id)
            fingerprint = "broker|" + attempt_id
            connection.execute("UPDATE tasks SET worker_pid=?, worker_started_at=? WHERE id=?",
                               (handle, fingerprint, task.id))
            connection.execute("UPDATE task_runs SET worker_pid=?, worker_started_at=? WHERE id=?",
                               (handle, fingerprint, task.current_run_id))
            kanban._append_event(connection, task.id, "spawned",
                                 {"pid": handle, "started_at": fingerprint}, run_id=task.current_run_id)
    original = dispatch._default_spawn
    if isinstance(getattr(original, "__self__", None), Adapter):
        owner = original.__self__
        original = next(saved for module, name, saved, replacement in owner._originals
                        if module is dispatch and name == "_default_spawn")
    worker_globals = dict(original.__globals__)
    worker_globals["_resolve_hermes_argv"] = lambda: [sys.executable, "-m", "hermes_cli.main"]
    argv_builder = dispatch._worker_argv
    worker_globals["_worker_argv"] = types.FunctionType(
        argv_builder.__code__, worker_globals, argv_builder.__name__, argv_builder.__defaults__,
        argv_builder.__closure__)
    worker_globals["_restart_safe_worker_argv"] = lambda task, command: command
    worker_globals["subprocess"] = types.SimpleNamespace(
        Popen=_exec_kanban, DEVNULL=-3, STDOUT=-2, CREATE_NO_WINDOW=0)
    spawn = types.FunctionType(original.__code__, worker_globals, original.__name__,
                               original.__defaults__, original.__closure__)
    spawn.__kwdefaults__ = original.__kwdefaults__
    return spawn(task, payload["workspace"], board=payload["board"])


def _sanitized_config(config):
    result = copy.deepcopy(config)
    result["mcp_servers"] = {}
    terminal = result.setdefault("terminal", {})
    terminal["backend"] = "local"
    agent = result.setdefault("agent", {})
    disabled = agent.get("disabled_toolsets") or []
    if not isinstance(disabled, list):
        disabled = [disabled]
    agent["disabled_toolsets"] = list(dict.fromkeys([*disabled, "computer_use", "mcp"]))
    return result


def _blocked_tool(registry, name, *, scope=None):
    entry = registry.get_entry(name, scope=scope)
    toolset = getattr(entry, "toolset", "")
    return (name == "computer_use" or name.startswith("mcp_") or toolset == "computer_use"
            or toolset == "mcp" or toolset.startswith("mcp-"))


def install_policy():
    """Apply runtime policy independently of mutable config or session toolsets."""
    config = importlib.import_module("hermes_cli.config")
    if getattr(config, "_sandbox_policy_installed", False):
        return
    original_config = config._load_config_impl

    def load_config(*arguments, **options):
        os.environ["TERMINAL_ENV"] = "local"
        return _sanitized_config(original_config(*arguments, **options))

    config._load_config_impl = load_config
    original_raw = config.read_raw_config
    config.read_raw_config = lambda *arguments, **options: _sanitized_config(original_raw(*arguments, **options))
    original_bridge = config.apply_terminal_config_to_env

    def bridge(*arguments, **options):
        result = original_bridge(*arguments, **options)
        target = options.get("env")
        (os.environ if target is None else target)["TERMINAL_ENV"] = "local"
        return result

    config.apply_terminal_config_to_env = bridge
    terminal_config = importlib.import_module("tools.terminal_tool_config")
    original_tenv = terminal_config._tenv
    terminal_config._tenv = lambda key, *arguments, **options: (
        "local" if key == "TERMINAL_ENV" else original_tenv(key, *arguments, **options))
    backends = importlib.import_module("tools.terminal_tool_backends")
    original_factory = backends._create_environment
    backends._create_environment = lambda env_type, *arguments, **options: original_factory(
        "local", *arguments, **options)
    startup = importlib.import_module("hermes_cli.mcp_startup")
    startup._has_configured_mcp_servers = lambda: False
    discovery = importlib.import_module("tools.mcp_tool_discovery")
    for name in ("discover_mcp_tools", "register_mcp_servers", "_register_mcp_servers"):
        setattr(discovery, name, lambda *arguments, **options: [])
    registry_module = importlib.import_module("tools.registry")
    original_candidates = registry_module._tool_module_candidates
    registry_module._tool_module_candidates = lambda directory: [
        candidate for candidate in original_candidates(directory)
        if "computer_use" not in candidate.parts and candidate.stem != "computer_use_tool"]
    registry_class = registry_module.ToolRegistry
    original_definitions = registry_class.get_definitions
    original_dispatch = registry_class.dispatch

    def definitions(registry, tool_names, *arguments, **options):
        selected = {name for name in tool_names if not _blocked_tool(registry, name)}
        return original_definitions(registry, selected, *arguments, **options)

    def dispatch(registry, name, arguments, *, scope=None, **options):
        if _blocked_tool(registry, name, scope=scope):
            return registry_module.tool_error("This tool is excluded by the Hermes sandbox policy")
        return original_dispatch(registry, name, arguments, scope=scope, **options)

    registry_class.get_definitions = definitions
    registry_class.dispatch = dispatch
    processes = importlib.import_module("tools.process_registry")
    original_checkpoint = processes._checkpoint_path

    def checkpoint_path():
        namespace = os.readlink("/proc/self/ns/pid")
        identity = hashlib.sha256(namespace.encode("utf-8")).hexdigest()[:16]
        original = original_checkpoint()
        return original.with_name(f"{original.stem}.{identity}{original.suffix}")

    processes._checkpoint_path = checkpoint_path
    config._sandbox_policy_installed = True


def _register_broker_tools(adapter):
    registry = importlib.import_module("tools.registry").registry
    for action in ("status", "cancel"):
        name = "hermes_worker_" + action
        registry.register(
            name=name, toolset="terminal",
            schema={"name": name, "description": f"{action.title()} this profile's broker worker attempt.",
                    "parameters": {"type": "object", "additionalProperties": False,
                                   "required": ["kind", "task_id", "attempt_id"],
                                   "properties": {"kind": {"type": "string", "enum": sorted(KINDS)},
                                                  "task_id": {"type": "string"},
                                                  "attempt_id": {"type": "string"}}}},
            handler=lambda arguments, _action=action, **unused: adapter.broker_tool(_action, arguments))


def _install_profile_authority(profile, state):
    constants = importlib.import_module("hermes_constants")
    profiles = importlib.import_module("hermes_cli.profiles")

    def profile_directory(name):
        normalized = profiles.normalize_profile_name(name)
        if normalized not in {profile, "default"}:
            raise ValueError("Profile is outside this sandbox's registered authority")
        return state

    def profile_exists(name):
        try:
            profile_directory(name)
            return True
        except ValueError:
            return False

    def list_profiles(*, lazy_skill_count=False):
        return [profiles._profile_info(profile, state, is_default=True,
                                       lazy_skill_count=lazy_skill_count)]

    def default_root(*, home=None):
        if home is not None and Path(home).resolve() not in {state.resolve(), Path.home().resolve()}:
            raise ValueError("Root is outside this sandbox's registered authority")
        return state

    def active_profile(root=None):
        if root is not None and Path(root).resolve() != state.resolve():
            raise ValueError("Root is outside this sandbox's registered authority")
        return profile

    def managed_lifecycle(*arguments, **options):
        raise ValueError("Profile identity changes require host-side sandbox registration")

    hooks = []
    for module, name, replacement in (
        (constants, "get_default_hermes_root", default_root),
        (profiles, "_get_default_hermes_home", lambda: state),
        (profiles, "resolve_profile_env", lambda name: str(profile_directory(name))),
        (profiles, "get_profile_dir", profile_directory),
        (profiles, "profile_exists", profile_exists),
        (profiles, "get_active_profile", active_profile),
        (profiles, "get_active_profile_name", lambda: profile),
        (profiles, "list_profiles", list_profiles),
        (profiles, "profiles_to_serve", lambda multiplex, **options: [(profile, state)]),
    ):
        original = getattr(module, name)
        hooks.append((module, name, original, replacement))
    for name in ("create_profile", "delete_profile", "rename_profile", "import_profile"):
        if hasattr(profiles, name):
            hooks.append((profiles, name, getattr(profiles, name), managed_lifecycle))
    if hasattr(profiles, "set_active_profile"):
        def set_active(name):
            profile_directory(name)
        hooks.append((profiles, "set_active_profile", profiles.set_active_profile, set_active))
    for module, name, original, replacement in hooks:
        setattr(module, name, replacement)
    os.environ["HERMES_PROFILE_NAME"] = profile
    os.environ["HERMES_PROFILE"] = profile
    return hooks


def bootstrap():
    """Restore PM dependencies and policy for the protected isolated entry point."""
    global _ACTIVE_ADAPTER
    if _ACTIVE_ADAPTER is not None:
        return _ACTIVE_ADAPTER
    runtime = validate_runtime(os.environ.get("HERMES_SANDBOX_RUNTIME", ""))
    support = Path(__file__).resolve().parent
    state = _absolute_directory(os.environ.get("HERMES_HOME", ""))
    workspace = _absolute_directory(os.environ.get("HERMES_SANDBOX_WORKSPACE", ""))
    profile = _identifier(os.environ.get("HERMES_SANDBOX_PROFILE", ""), profile=True)
    if not state.is_dir() or not workspace.is_dir():
        raise ValueError("Sandbox state and workspace must already exist")
    interpreter = runtime / ".venv" / "bin" / "python"
    if not interpreter.is_file() or not os.path.samefile(interpreter, sys.executable):
        raise ValueError("Sandbox entry requires this runtime's prepared venv interpreter")
    for directory in (runtime, support):
        if str(directory) not in sys.path:
            sys.path.insert(0, str(directory))
    _apply_runtime_environment(runtime, state)
    patches = support / "patches"
    os.environ["PYTHONPATH"] = os.pathsep.join(map(str, (patches, support, runtime)))
    os.environ["PYTHONSAFEPATH"] = "1"
    os.environ["TERMINAL_ENV"] = "local"
    profile_hooks = _install_profile_authority(profile, state)
    importlib.import_module("hermes_bootstrap")
    dependency_paths = os.environ.get("PYTHONPATH", "").split(os.pathsep)
    os.environ["PYTHONPATH"] = os.pathsep.join(dict.fromkeys(
        [str(patches), str(support), str(runtime), *filter(None, dependency_paths)]))
    install_policy()
    control = importlib.import_module("control")
    frontend_patches = importlib.import_module("frontend_patches")
    state_hooks = frontend_patches.install(state)
    installed = install(profile, state, lambda request: control.client_request(CONTROL_SOCKET, request))
    installed.state_hooks = state_hooks
    manifest = os.environ.get("HERMES_SANDBOX_BACKEND_MANIFEST")
    if manifest:
        if manifest != "/run/hermes/backend.json":
            raise ValueError("Backend connection must use the fixed read-only mount")
        frontends = importlib.import_module("frontends")
        os.environ.update(frontends.attach_environment(frontends.read_backend_connection(manifest)))
    _register_broker_tools(installed)
    installed._originals.extend(profile_hooks)
    _ACTIVE_ADAPTER = installed
    return _ACTIVE_ADAPTER


def bootstrap_child():
    """Called only for known Hermes processes by protected sitecustomize."""
    original_argv = getattr(sys, "orig_argv", [])
    module = None
    if "-m" in original_argv:
        module_index = original_argv.index("-m") + 1
        if module_index < len(original_argv):
            module = original_argv[module_index]
    command = Path(sys.argv[0]).name if sys.argv else ""
    if module not in CHILD_MODULES and command not in {"hermes", "hermes.exe"}:
        return
    try:
        bootstrap()
    except BaseException as error:
        raise SystemExit("Hermes sandbox child bootstrap refused: " + type(error).__name__) from error


def main(argv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    if not arguments or arguments[0] not in {"cli", "worker"}:
        raise ValueError("Expected cli -- ARGS or worker KIND ATTEMPT_ID")
    mode = arguments.pop(0)
    if mode == "cli":
        if not arguments or arguments.pop(0) != "--":
            raise ValueError("CLI arguments require the explicit -- separator")
        if _cli_command(arguments) in {"mcp", "computer-use"}:
            raise ValueError("This command is excluded by sandbox policy")
        sys.argv = ["hermes", *arguments]
    elif len(arguments) != 2:
        raise ValueError("Worker accepts only KIND and ATTEMPT_ID")
    if mode == "worker":
        kind, attempt_id = arguments
        profile = os.environ.get("HERMES_SANDBOX_PROFILE", "")
        if os.environ.get("HERMES_SANDBOX_WORKER_SNAPSHOT", str(SNAPSHOT_PATH)) != str(SNAPSHOT_PATH):
            raise ValueError("Worker snapshot must use the fixed read-only mount")
        _worker_snapshot(kind, attempt_id, profile, SNAPSHOT_PATH)
    adapter = bootstrap()
    if mode == "worker":
        return 0 if run_worker(kind, attempt_id, adapter.profile, adapter.state) else 1
    if _cli_command(arguments) in {"desktop", "gui"}:
        frontends = importlib.import_module("frontends")
        return frontends.run_desktop_server(sys.executable, os.environ.get("HERMES_TUI_GATEWAY_URL", ""))
    entry = importlib.import_module("hermes_cli.main")
    return entry.main()


def _cli_command(arguments):
    values = {"--profile", "-p", "--model", "-m", "--provider", "--toolsets", "-t", "--skills",
              "--query", "-q", "--resume", "--reasoning", "--max-turns", "--image"}
    index = 0
    while index < len(arguments):
        value = arguments[index]
        if value in values:
            index += 2
        elif value.startswith("-"):
            index += 1
        else:
            return value
    return None


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, RuntimeError) as error:
        print("Hermes sandbox adapter refused: " + str(error), file=sys.stderr)
        raise SystemExit(2) from error
