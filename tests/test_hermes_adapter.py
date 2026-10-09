"""Adapter contract tests with isolated RPCs and pinned, selectively compiled SQL seams."""

import ast
import contextlib
import dataclasses
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
import types
import typing
import unittest
from unittest import mock


SUPPORT = Path(__file__).resolve().parents[1] / "bin" / "ai_wrapper_data"
sys.path.insert(0, str(SUPPORT))
from hermes_sandbox import adapter
from hermes_sandbox.patches import ledger


UPSTREAM = Path(os.environ.get("HERMES_UPSTREAM_SOURCE", "/tmp/hermes-upstream-WdPss4"))


def source_functions(path, names, namespace):
    tree = ast.parse(path.read_bytes(), filename=str(path))
    selected = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
    if {node.name for node in selected} != set(names):
        raise AssertionError("Pinned source functions are missing")
    future = ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0)
    module = ast.fix_missing_locations(ast.Module(body=[future, *selected], type_ignores=[]))
    exec(compile(module, str(path), "exec"), namespace)
    return namespace


def fake_module(name, **values):
    module = types.ModuleType(name)
    vars(module).update(values)
    module.__name__ = name
    return module


@contextlib.contextmanager
def fake_modules(modules):
    supplied = dict(modules)
    for name in modules:
        parts = name.split(".")
        for length in range(1, len(parts)):
            parent = ".".join(parts[:length])
            if parent not in supplied:
                supplied[parent] = fake_module(parent, __path__=[])
    with mock.patch.dict(sys.modules, supplied):
        yield


class FakeRPC:
    def __init__(self, stage="adopted", outcome="running"):
        self.stage = stage
        self.outcome = outcome
        self.requests = []
        self.error = None

    def __call__(self, request):
        self.requests.append(dict(request))
        if self.error is not None:
            raise self.error
        return {**{name: request[name] for name in ("profile", "kind", "task_id", "attempt_id")},
                "stage": self.stage, "outcome": self.outcome, "unit": "opaque.service"}


class AdapterFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hermes-adapter-test-")
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name) / "state"
        self.state.mkdir(mode=0o700)
        self.workspace = Path(self.temporary.name) / "workspace"
        self.workspace.mkdir(mode=0o700)
        self.rpc = FakeRPC()
        self.integration = adapter.Adapter("default", self.state, self.rpc)

    def publish(self, kind="cron", task_id="task.1", attempt_id="attempt-1", payload=None):
        if payload is None:
            payload = {"job": {"id": task_id, "execution_id": attempt_id},
                       "profile_home": str(self.state), "multiplex_active": False}
        return adapter.write_snapshot(self.state, profile="default", kind=kind,
                                      task_id=task_id, attempt_id=attempt_id, payload=payload)

    def owner(self, attempt_id="1", task_id="task.1", claim_lock="host:claim"):
        path = self.state / "worker-spool" / "kanban" / task_id / f"{attempt_id}.owner.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        handle = adapter._worker_handle("default", task_id, attempt_id)
        path.write_text(json.dumps(dict(pid=handle, claim_lock=claim_lock, profile="default",
                                       kind="kanban", task_id=task_id, attempt_id=attempt_id)))
        return handle


class BrokerContractTests(AdapterFixture):
    def test_requests_contain_only_identifiers_and_closed_actions(self):
        self.integration.broker_tool("status", {"kind": "cron", "task_id": "task.1", "attempt_id": "a-1"})
        self.assertEqual(self.rpc.requests, [dict(action="status", profile="default", kind="cron",
                                                task_id="task.1", attempt_id="a-1")])
        for action in ("start", "exec", "launch"):
            with self.subTest(action=action), self.assertRaises(ValueError):
                self.integration.broker_tool(action, {"kind": "cron", "task_id": "task", "attempt_id": "a"})
        with self.assertRaises(ValueError):
            self.integration.broker_tool("cancel", {"kind": "cron", "task_id": "task", "attempt_id": "a",
                                                    "profile": "other"})

    def test_broker_accepted_unknown_is_uncertain_not_invalid(self):
        self.rpc.stage, self.rpc.outcome = "accepted", "unknown"
        record = self.integration._call("status", "default", "cron", "task", "attempt")
        self.assertEqual((record["stage"], record["outcome"]), ("accepted", "unknown"))

    def test_reply_identity_and_lifecycle_are_checked(self):
        for changed in ({"profile": "other"}, {"attempt_id": "different"}, {"stage": "started"},
                        {"stage": "finished", "outcome": "running"}, {"ok": False}):
            with self.subTest(changed=changed), mock.patch.object(
                    self.integration, "request", lambda request: {**self.rpc(request), **changed}):
                with self.assertRaises(RuntimeError):
                    self.integration._call("status", "default", "cron", "task", "attempt")

    def test_tokens_align_with_broker_and_traversal_is_refused(self):
        self.assertEqual(adapter._identifier("a" + "_" * 127), "a" + "_" * 127)
        self.assertEqual(adapter._identifier("lower" + "-" * 59, profile=True), "lower" + "-" * 59)
        for value in ("a..b", "../a", "a/b", ".a", "a" * 129, "é", "", None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                adapter._identifier(value)
        for profile in ("Default", "profile.dot", "a" * 65):
            with self.subTest(profile=profile), self.assertRaises(ValueError):
                adapter._identifier(profile, profile=True)


class SnapshotTests(AdapterFixture):
    def test_exact_envelope_private_atomic_and_no_overwrite(self):
        path = self.publish()
        self.assertEqual(json.loads(path.read_text()), dict(
            kind="cron", task_id="task.1", attempt_id="attempt-1", profile="default",
            payload={"job": {"id": "task.1", "execution_id": "attempt-1"},
                     "profile_home": str(self.state), "multiplex_active": False}))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertFalse(list(path.parent.glob("*.tmp")))
        with self.assertRaises(FileExistsError):
            self.publish()
        adapter._worker_snapshot("cron", "attempt-1", "default", path)

    def test_spool_symlink_and_snapshot_symlink_are_rejected(self):
        (self.state / "worker-spool").symlink_to(self.workspace, target_is_directory=True)
        with self.assertRaises(OSError):
            self.publish()
        self.assertEqual(list(self.workspace.iterdir()), [])
        target = self.workspace / "target.json"
        target.write_text("{}")
        link = self.workspace / "link.json"
        link.symlink_to(target)
        with self.assertRaises(OSError):
            adapter._read_json(link)

    def test_snapshot_limit_matches_one_megabyte_broker_limit(self):
        with self.assertRaisesRegex(ValueError, "too large"):
            self.publish(payload={"text": "x" * (1024 * 1024)})
        path = self.workspace / "oversized.json"
        path.write_bytes(b" " * (1024 * 1024 + 1))
        with self.assertRaisesRegex(ValueError, "too large"):
            adapter._read_json(path)

    def test_duplicate_keys_nonfinite_unknown_envelope_and_foreign_identity(self):
        path = self.workspace / "malformed.json"
        for contents in ('{"kind":"cron","kind":"kanban"}', '{"payload":NaN}'):
            path.write_text(contents)
            with self.subTest(contents=contents), self.assertRaises(ValueError):
                adapter._read_json(path)
        valid = json.loads(self.publish().read_text())
        for changed in ({"argv": ["sh"]}, {"profile": "other"}, {"attempt_id": "different"}):
            path.write_text(json.dumps({**valid, **changed}))
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                adapter._worker_snapshot("cron", "attempt-1", "default", path)

    def test_closed_cron_payload_is_checked_before_upstream_import(self):
        payload = {"job": {"id": "task.1", "execution_id": "attempt-1"},
                   "profile_home": str(self.state), "multiplex_active": False}
        for changed in ({"argv": ["sh"]}, {"multiplex_active": "true"},
                        {"profile_home": str(self.workspace)}, {"job": {"id": "different", "execution_id": "attempt-1"}},
                        {"job": {"id": "task.1", "execution_id": "attempt-1", "env": {"LD_PRELOAD": "evil"}}}):
            path = self.workspace / "snapshot.json"
            path.write_text(json.dumps(dict(kind="cron", task_id="task.1", attempt_id="attempt-1",
                                            profile="default", payload={**payload, **changed})))
            with self.subTest(changed=changed), mock.patch.object(adapter.importlib, "import_module") as imports:
                with self.assertRaises(ValueError):
                    adapter.run_worker("cron", "attempt-1", "default", self.state, snapshot_path=path)
                imports.assert_not_called()

    def test_valid_native_one_shot_outage_claim_is_supported(self):
        adapter._validate_cron_job(dict(id="job", execution_id="execution", schedule={"kind": "once", "run_at": "date"},
                                       run_claim={"at": "date", "by": "host", "outage": True}))

    def test_kanban_nested_values_and_generic_commands_are_refused(self):
        valid = dict(id="task", assignee="default", current_run_id=1, claim_lock="host:claim")
        adapter._validate_kanban_task(valid)
        for changed in ({"env": {}}, {"argv": ["sh"]}, {"skills": [1]}, {"current_run_id": True},
                        {"claim_lock": None}, {"body": {"argv": ["sh"]}}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                adapter._validate_kanban_task({**valid, **changed})

    def test_cron_worker_preserves_upstream_adoption_payload_and_boolean_result(self):
        path = self.publish()
        observed = []

        def worker(payload_file, ack_file):
            observed.append((json.loads(payload_file.read_text()), stat.S_IMODE(payload_file.stat().st_mode), ack_file))
            payload_file.unlink()
            return False

        with fake_modules({"cron.scheduler": fake_module("cron.scheduler", _run_external_worker_payload=worker)}):
            self.assertFalse(adapter.run_worker("cron", "attempt-1", "default", self.state, snapshot_path=path))
        self.assertEqual(observed[0][0], json.loads(path.read_text())["payload"])
        self.assertEqual(observed[0][1], 0o600)
        self.assertEqual(observed[0][2], self.state / "cron" / "external-workers" / "attempt-1.ready")


class OwnershipTests(AdapterFixture):
    def test_cron_liveness_never_uses_colliding_namespace_pid(self):
        self.publish()
        with mock.patch.object(os, "kill", side_effect=AssertionError("Kernel PID authority is forbidden")):
            self.assertTrue(self.integration.execution_owner_alive({"id": "attempt-1", "pid": 1}))
            self.rpc.stage, self.rpc.outcome = "finished", "failed"
            self.assertFalse(self.integration.execution_owner_alive({"id": "attempt-1", "pid": 1}))
            self.assertEqual(self.rpc.requests[-1]["task_id"], "task.1")

    def test_cron_uncertainty_keeps_owner_live(self):
        self.publish()
        self.rpc.error = OSError("unavailable")
        self.assertTrue(self.integration.execution_owner_alive({"id": "attempt-1", "pid": 1}))
        self.assertTrue(self.integration.execution_owner_alive({"id": "missing", "pid": 1}))

    def test_kanban_handles_survive_namespace_pid_collision_and_dispatcher_restart(self):
        first = self.owner("1")
        second = self.owner("2")
        self.assertNotEqual(first, second)
        reloaded = adapter.Adapter("default", self.state, self.rpc)
        with mock.patch.object(os, "kill", side_effect=AssertionError("No raw PID signalling")):
            self.assertTrue(reloaded.worker_alive(first, "broker|1"))
            self.rpc.stage, self.rpc.outcome = "finished", "cancelled"
            result = reloaded.terminate_kanban(second, "host:claim")
            self.assertTrue(result["terminated"])
        self.assertEqual(self.rpc.requests[-1], dict(action="cancel", profile="default", kind="kanban",
                                                    task_id="task.1", attempt_id="2"))

    def test_unknown_handle_and_changed_claim_are_never_signalled_or_reclaimed(self):
        handle = self.owner()
        with mock.patch.object(os, "kill", side_effect=AssertionError("No raw PID signalling")):
            self.assertTrue(self.integration.worker_alive(123))
            result = self.integration.terminate_kanban(handle, "different-claim")
            self.assertFalse(result["terminated"])
            self.assertTrue(result["signal_refused"])
            self.assertEqual(self.rpc.requests, [])

    def test_cancellation_must_be_confirmed_before_release(self):
        handle = self.owner()
        result = self.integration.terminate_kanban(handle, "host:claim")
        self.assertFalse(result["terminated"])
        with self.assertRaises(OSError):
            self.integration.cancel_pid(handle)


class CronHandoffTests(AdapterFixture):
    def scheduler(self, status="claimed"):
        self.execution = {"status": status}
        self.scheduler_module = fake_module(
            "cron.scheduler", _get_hermes_home=lambda: self.state,
            mark_execution_handoff_pending=mock.Mock(return_value={"handoff_pending": 1}),
            _inflight_key=lambda task: ("default", task), _running_lock=threading.Lock(),
            _restart_safe_waiter_job_ids=set(), _scope_isolated_job_ids=set(),
            _record_external_cron_worker=mock.Mock(), get_execution=lambda attempt: dict(self.execution),
            recover_interrupted_executions=mock.Mock(), finish_execution=mock.Mock(),
            _ExternalWorkerPostHandoffError=type("PostHandoffError", (RuntimeError,), {}))
        return fake_modules({
            "cron.scheduler": self.scheduler_module,
            "cron.scheduler_provider": fake_module("cron.scheduler_provider", routed_profile_fire=lambda: False),
            "agent.secret_scope": fake_module("agent.secret_scope", is_multiplex_active=lambda: False)})

    def test_completed_ledger_not_broker_adoption_is_success_authority(self):
        with self.scheduler(status="completed"):
            self.assertTrue(self.integration.launch_cron({"id": "task", "execution_id": "attempt"}))
        self.assertEqual(self.rpc.requests[0]["action"], "launch")
        self.scheduler_module._record_external_cron_worker.assert_called_once_with("task", None, scope_isolated=True)
        self.assertEqual(self.scheduler_module._restart_safe_waiter_job_ids, set())
        self.assertEqual(self.scheduler_module._scope_isolated_job_ids, set())

    def test_uncertain_handoff_is_not_safe_to_fallback_or_duplicate(self):
        self.rpc.error = OSError("lost reply after launch")
        with self.scheduler(), self.assertRaises(self.scheduler_module._ExternalWorkerPostHandoffError):
            self.integration.launch_cron({"id": "task", "execution_id": "attempt"})
        self.scheduler_module.finish_execution.assert_not_called()
        self.assertEqual(len(self.rpc.requests), 1)
        self.assertEqual(self.scheduler_module._restart_safe_waiter_job_ids, set())

    def test_finished_before_adoption_is_durable_failed_not_success(self):
        self.rpc.stage, self.rpc.outcome = "finished", "failed"
        with self.scheduler(), self.assertRaises(self.scheduler_module._ExternalWorkerPostHandoffError):
            self.integration.launch_cron({"id": "task", "execution_id": "attempt"})
        self.scheduler_module.finish_execution.assert_called_once_with(
            "attempt", success=False, error="Broker worker exited before cron adoption")

    def test_lost_execution_claim_never_launches(self):
        with self.scheduler():
            self.scheduler_module.mark_execution_handoff_pending.return_value = None
            with self.assertRaises(RuntimeError):
                self.integration.launch_cron({"id": "task", "execution_id": "attempt"})
        self.assertEqual(self.rpc.requests, [])


@unittest.skipUnless((UPSTREAM / "cron" / "executions.py").is_file(),
                     "Set HERMES_UPSTREAM_SOURCE to the read-only pinned checkout for source integration tests")
class PinnedLedgerTests(AdapterFixture):
    @classmethod
    def setUpClass(cls):
        adapter.validate_runtime(UPSTREAM)

    def setUp(self):
        super().setUp()
        self.connection = sqlite3.connect(self.state / "executions.db")
        self.connection.row_factory = sqlite3.Row
        self.addCleanup(self.connection.close)
        self.connection.execute(
            "CREATE TABLE executions (id TEXT PRIMARY KEY, job_id TEXT, status TEXT, process_id TEXT, "
            "pid INTEGER, process_started_at INTEGER, handoff_pending INTEGER, handoff_started_at REAL, "
            "claimed_at TEXT, progress_at TEXT, finished_at TEXT, error TEXT)")
        self.connection.commit()
        self.emitted = []

        @contextlib.contextmanager
        def transaction():
            with self.connection:
                yield self.connection

        self.source_module = fake_module("cron.executions", **vars(typing))
        vars(self.source_module).update(
            __file__=str(UPSTREAM / "cron" / "executions.py"), _transaction=transaction,
            _PROCESS_ID="dispatcher-process", _hermes_now=lambda: datetime.now(timezone.utc),
            _OWNER_GONE_REASON="owner gone", _OWNER_WEDGED_REASON="wedged",
            HANDOFF_ADOPTION_GRACE_SECONDS=30, time=time,
            _live_owner_stale_after_seconds=lambda: None, _stale_age_seconds=lambda *arguments: 0,
            _prune_unlocked=lambda connection: None,
            _emit_execution_state=lambda record: self.emitted.append(record),
            _owner_is_live=mock.Mock(side_effect=AssertionError("Cross-namespace PID probe is forbidden")),
            latest_execution=lambda job: self.latest(job))
        source_functions(Path(self.source_module.__file__), {"_fetch"}, vars(self.source_module))
        self.functions = ledger.broker_owner_functions(self.source_module, self.integration.execution_owner_alive)

    def latest(self, job):
        row = self.connection.execute("SELECT * FROM executions WHERE job_id=?", (job,)).fetchone()
        return dict(row) if row is not None else None

    def insert(self, attempt="attempt-1", status="running", handoff_pending=0, handoff_started_at=None,
               process_id="worker-process", pid=1):
        self.publish(attempt_id=attempt)
        self.connection.execute("INSERT INTO executions (id,job_id,status,process_id,pid,process_started_at,"
                                "handoff_pending,handoff_started_at,claimed_at) VALUES (?,?,?,?,?,?,?,?,?)",
                                (attempt, "task.1", status, process_id, pid, 123, handoff_pending,
                                 handoff_started_at, datetime.now(timezone.utc).isoformat()))
        self.connection.commit()

    def test_actual_pinned_ast_replaces_all_three_owner_entrypoints(self):
        self.assertEqual(set(self.functions), {"recover_interrupted_executions", "terminalize_dead_owner",
                                              "live_inflight_execution"})
        for name, function in self.functions.items():
            with self.subTest(name=name):
                self.assertNotIn("_owner_is_live", function.__code__.co_names)
                self.assertIn("_sandbox_owner_is_live", function.__code__.co_names)

    def test_broker_adopted_owner_survives_sql_recovery_despite_pid_one_collision(self):
        self.insert()
        self.assertEqual(self.functions["recover_interrupted_executions"](), 0)
        self.assertEqual(self.latest("task.1")["status"], "running")
        self.assertEqual(self.functions["live_inflight_execution"]("task.1")["pid"], 1)
        self.source_module._owner_is_live.assert_not_called()

    def test_finished_broker_changes_abandoned_running_sql_to_unknown_once(self):
        self.insert()
        self.rpc.stage, self.rpc.outcome = "finished", "failed"
        self.assertEqual(self.functions["recover_interrupted_executions"](), 1)
        self.assertEqual(self.latest("task.1")["status"], "unknown")
        self.assertEqual(self.functions["recover_interrupted_executions"](), 0)
        self.assertIsNone(self.functions["live_inflight_execution"]("task.1"))
        self.assertEqual(len(self.emitted), 1)

    def test_sql_adoption_grace_preserved_even_if_broker_finished(self):
        self.insert(status="claimed", handoff_pending=1, handoff_started_at=time.time())
        self.rpc.stage, self.rpc.outcome = "finished", "failed"
        self.assertEqual(self.functions["recover_interrupted_executions"](), 0)
        self.assertFalse(self.functions["terminalize_dead_owner"]("attempt-1", reason="broker failed"))
        self.connection.execute("UPDATE executions SET handoff_started_at=?", (time.time() - 60,))
        self.connection.commit()
        self.assertTrue(self.functions["terminalize_dead_owner"]("attempt-1", reason="broker failed"))
        self.assertEqual(self.latest("task.1")["error"], "broker failed")

    def test_dispatcher_restart_reloads_identity_without_original_pid_namespace(self):
        self.insert()
        restarted = adapter.Adapter("default", self.state, self.rpc)
        functions = ledger.broker_owner_functions(self.source_module, restarted.execution_owner_alive)
        self.assertEqual(functions["recover_interrupted_executions"](), 0)
        self.rpc.error = RuntimeError("broker restart in progress")
        self.assertEqual(functions["recover_interrupted_executions"](), 0)
        self.assertEqual(self.latest("task.1")["status"], "running")

    def test_own_dispatcher_and_terminal_rows_are_never_rewritten(self):
        self.insert(status="completed")
        self.insert(attempt="attempt-2", process_id="dispatcher-process")
        self.rpc.stage, self.rpc.outcome = "finished", "failed"
        self.assertEqual(self.functions["recover_interrupted_executions"](), 0)
        self.assertEqual(self.rpc.requests, [])

    def test_modified_recovery_source_is_rejected_before_compile(self):
        forged = self.workspace / "executions.py"
        forged.write_text(Path(self.source_module.__file__).read_text() + "\nchanged = True\n")
        self.source_module.__file__ = str(forged)
        with self.assertRaisesRegex(ValueError, "pinned contract"):
            ledger.broker_owner_functions(self.source_module, self.integration.execution_owner_alive)


@unittest.skipUnless((UPSTREAM / "hermes_cli" / "kanban_db_dispatch.py").is_file(),
                     "Set HERMES_UPSTREAM_SOURCE to the pinned checkout for Kanban source tests")
class PinnedKanbanTests(AdapterFixture):
    @classmethod
    def setUpClass(cls):
        adapter.validate_runtime(UPSTREAM)

    def setUp(self):
        super().setUp()
        self.connection = sqlite3.connect(self.state / "kanban.db")
        self.connection.row_factory = sqlite3.Row
        self.addCleanup(self.connection.close)
        self.connection.executescript(
            "CREATE TABLE tasks (id TEXT PRIMARY KEY, assignee TEXT, current_run_id INTEGER, claim_lock TEXT, "
            "status TEXT, worker_pid INTEGER, worker_started_at TEXT, claim_expires INTEGER, max_runtime_seconds INTEGER);"
            "CREATE TABLE task_runs (id INTEGER PRIMARY KEY, worker_pid INTEGER, worker_started_at TEXT, "
            "claim_expires INTEGER, started_at INTEGER);")
        self.events = []

        def worker_log(*arguments):
            stream = open(self.state / "worker.log", "ab")
            self.addCleanup(stream.close)
            return stream

        @contextlib.contextmanager
        def write_txn(connection, *, allow_nested=False):
            if connection.in_transaction:
                if not allow_nested:
                    raise RuntimeError("Nested transaction not explicitly allowed")
                yield connection
            else:
                with connection:
                    connection.execute("BEGIN IMMEDIATE")
                    yield connection

        self.board_db = fake_module(
            "hermes_cli.kanban_db", dataclass=dataclasses.dataclass, field=dataclasses.field,
            write_txn=write_txn, _IS_WINDOWS=False,
            connect=lambda **options: self.connection,
            kanban_db_path=lambda **options: self.state / "kanban.db",
            workspaces_root=lambda **options: self.workspace,
            _normalize_board_slug=lambda board: board,
            get_current_board=lambda: "default",
            _current_run_id=lambda connection, task: connection.execute(
                "SELECT current_run_id FROM tasks WHERE id=?", (task,)).fetchone()[0],
            _append_event=lambda *arguments, **options: self.events.append((arguments, options)))
        tree = ast.parse((UPSTREAM / "hermes_cli" / "kanban_db.py").read_bytes())
        task_class = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Task")
        future = ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0)
        task_module = ast.fix_missing_locations(ast.Module(body=[future, task_class], type_ignores=[]))
        with fake_modules({"hermes_cli.kanban_db": self.board_db}):
            exec(compile(task_module, "pinned-Task", "exec"), vars(self.board_db))
        namespace = dict(__name__="hermes_cli.kanban_db_dispatch", _kb=self.board_db,
                         os=os, sys=sys, subprocess=subprocess, contextlib=contextlib,
                         KANBAN_TERMINAL_TIMEOUT_GRACE_SECONDS=30,
                         UNVERIFIED_WORKER_FINGERPRINT="unverified",
                         _process_fingerprint=self.integration.worker_fingerprint,
                         _worker_profile_scope=lambda *arguments, **options: contextlib.nullcontext(),
                         _resolve_worker_cli_toolsets=lambda home: ["terminal", "file"],
                         _resolve_hermes_argv=lambda: ["/workspace/planted-hermes"],
                         _retag_legacy_worker_sessions=mock.Mock(), _propagate_module_import_root=mock.Mock(),
                         _restart_safe_worker_argv=mock.Mock(side_effect=AssertionError("No nested systemd launcher")),
                         _open_worker_log=worker_log)
        source_functions(UPSTREAM / "hermes_cli" / "kanban_db_dispatch.py",
                         {"_default_spawn", "_worker_argv", "_set_worker_pid", "_worker_terminal_timeout_env"}, namespace)
        self.dispatch = fake_module("hermes_cli.kanban_db_dispatch", **{
            name: value for name, value in namespace.items() if name != "__name__"})
        self.modules = {
            "hermes_cli.kanban_db": self.board_db, "hermes_cli.kanban_db_dispatch": self.dispatch,
            "hermes_cli.profiles": fake_module("hermes_cli.profiles", normalize_profile_name=lambda profile: profile,
                                               resolve_profile_env=lambda profile: str(self.state)),
            "agent.secret_scope": fake_module("agent.secret_scope", is_multiplex_active=lambda: False),
            "agent.delegation_context": fake_module("agent.delegation_context",
                                                     DELEGATED_CHILD_ENV_MARKER="HERMES_DELEGATED_CHILD_CONTEXT"),
            "tools.environments.local": fake_module(
                "tools.environments.local", _is_routed_home=lambda home: False,
                build_subprocess_env=lambda **options: dict(os.environ),
                strip_launch_profile_env=lambda env, home: None),
            "tools.process_registry": fake_module("tools.process_registry", systemd_user_bus_env=lambda env: env),
            "gateway.session_context": fake_module("gateway.session_context", _VAR_MAP={"HERMES_CHAT_ID": "chat"})}

    def task(self, **changes):
        arguments = dict(id="task.1", title="Task", body="not shell argv", assignee="default", status="running",
                         priority=0, created_by="user", created_at=1, started_at=1, completed_at=None,
                         workspace_kind="existing", workspace_path=str(self.workspace), claim_lock="host:claim",
                         claim_expires=int(time.time()) + 300, tenant=None, current_run_id=1,
                         skills=["skill with spaces"], model_override="model", provider_override="provider",
                         reasoning_effort="high", max_runtime_seconds=600)
        return self.board_db.Task(**{**arguments, **changes})

    def insert(self, task):
        self.connection.execute("INSERT INTO tasks (id,assignee,current_run_id,claim_lock,status,claim_expires,"
                                "max_runtime_seconds) VALUES (?,?,?,?,?,?,?)",
                                (task.id, task.assignee, task.current_run_id, task.claim_lock, task.status,
                                 task.claim_expires, task.max_runtime_seconds))
        self.connection.execute("INSERT INTO task_runs (id,started_at) VALUES (?,?)",
                                (task.current_run_id, int(time.time()) - 1000))
        self.connection.commit()

    def test_native_task_fields_match_closed_adapter_schema(self):
        self.assertEqual({field.name for field in dataclasses.fields(self.board_db.Task)}, set(adapter.KANBAN_TASK_KEYS))
        adapter._validate_kanban_task(dataclasses.asdict(self.task()))

    def test_spawn_publishes_claimed_task_without_argv_env_or_parent_pid(self):
        task = self.task()
        with fake_modules(self.modules), mock.patch.object(subprocess, "Popen", side_effect=AssertionError("No parent spawn")):
            self.assertIsNone(self.integration.spawn_kanban(task, str(self.workspace), board="default"))
        path = self.state / "worker-spool" / "kanban" / "task.1" / "1.json"
        snapshot = json.loads(path.read_text())
        self.assertEqual(set(snapshot["payload"]), {"task", "workspace", "board", "db", "workspaces_root"})
        self.assertEqual(snapshot["payload"]["task"], dataclasses.asdict(task))
        self.assertEqual(self.rpc.requests[0], dict(action="launch", profile="default", kind="kanban",
                                                  task_id="task.1", attempt_id="1"))

    def test_actual_native_worker_builder_reexecs_protected_cli_after_durable_adoption(self):
        task = self.task()
        self.insert(task)
        payload = dict(task=dataclasses.asdict(task), workspace=str(self.workspace), board="default",
                       db=str(self.state / "kanban.db"), workspaces_root=str(self.workspace))
        path = self.publish("kanban", task.id, "1", payload)
        captured = {}
        statements = []
        self.connection.set_trace_callback(statements.append)

        class ProcessReplaced(BaseException):
            pass

        def replace(executable, arguments, environment):
            captured.update(executable=executable, argv=arguments, env=environment)
            raise ProcessReplaced()

        with fake_modules(self.modules), mock.patch.dict(os.environ, {"HERMES_CHAT_ID": "must-not-inherit"}), \
                mock.patch.object(os, "dup2"), mock.patch.object(os, "chdir"), \
                mock.patch.object(os, "execvpe", side_effect=replace), self.assertRaises(ProcessReplaced):
            adapter.run_worker("kanban", "1", "default", self.state, snapshot_path=path)
        self.assertEqual(captured["argv"][:5], [sys.executable, "-I", str(Path(adapter.__file__).resolve()), "cli", "--"])
        self.assertEqual(captured["argv"][5:], ["-p", "default", "--cli", "--accept-hooks", "--skills",
                                              "skill with spaces", "-m", "model", "--provider", "provider",
                                              "--reasoning", "high", "--toolsets", "terminal,file",
                                              "chat", "-q", "work kanban task task.1"])
        self.assertNotIn("HERMES_CHAT_ID", captured["env"])
        self.assertEqual(captured["env"]["HERMES_KANBAN_CLAIM_LOCK"], "host:claim")
        self.assertEqual(captured["env"]["HERMES_KANBAN_RUN_ID"], "1")
        self.assertEqual(captured["env"]["HERMES_KANBAN_DB"], str(self.state / "kanban.db"))
        row = self.connection.execute("SELECT worker_pid,worker_started_at FROM tasks").fetchone()
        self.assertEqual(row["worker_pid"], adapter._worker_handle("default", task.id, "1"))
        self.assertEqual(row["worker_started_at"], "broker|1")
        begin = statements.index("BEGIN IMMEDIATE")
        validation = next(index for index, statement in enumerate(statements)
                          if statement.startswith("SELECT current_run_id, claim_lock, status"))
        registration = next(index for index, statement in enumerate(statements)
                            if statement.startswith("UPDATE tasks SET worker_pid="))
        self.assertLess(begin, validation)
        self.assertLess(validation, registration)
        self.assertEqual(statements.count("COMMIT"), 1)
        self.assertTrue(self.events)
        self.dispatch._restart_safe_worker_argv.assert_not_called()

    def test_changed_claim_exits_before_exec_or_worker_pid_registration(self):
        task = self.task()
        self.insert(task)
        self.connection.execute("UPDATE tasks SET claim_lock='different'")
        self.connection.commit()
        path = self.publish("kanban", task.id, "1", dict(task=dataclasses.asdict(task), workspace=str(self.workspace),
                                                        board="default", db=str(self.state / "kanban.db"),
                                                        workspaces_root=str(self.workspace)))
        with fake_modules(self.modules), mock.patch.object(os, "execvpe") as replace:
            with self.assertRaisesRegex(ValueError, "claim changed"):
                adapter.run_worker("kanban", "1", "default", self.state, snapshot_path=path)
        replace.assert_not_called()
        self.assertEqual(self.events, [])

    def test_timeout_does_not_release_claim_while_broker_cancellation_is_pending(self):
        task = self.task()
        self.insert(task)
        handle = self.owner()
        self.connection.execute("UPDATE tasks SET worker_pid=?", (handle,))
        self.connection.commit()
        with fake_modules(self.modules), mock.patch.object(self.integration, "_record_kanban_failure_locked") as failure:
            self.assertEqual(self.integration.enforce_kanban_runtime(self.connection), [])
        failure.assert_not_called()
        self.assertEqual(self.connection.execute("SELECT status FROM tasks").fetchone()[0], "running")

    def test_pending_worker_reconciliation_extends_claim_without_resetting_attempt(self):
        task = self.task(claim_expires=1)
        self.insert(task)
        self.publish("kanban", task.id, "1", {})
        with fake_modules(self.modules):
            self.integration.reconcile_kanban(self.connection)
        row = self.connection.execute("SELECT status,claim_expires,current_run_id,claim_lock FROM tasks").fetchone()
        self.assertEqual((row["status"], row["current_run_id"], row["claim_lock"]), ("running", 1, "host:claim"))
        self.assertGreater(row["claim_expires"], int(time.time()))


class PolicyTests(AdapterFixture):
    def setUp(self):
        super().setUp()

        class Registry:
            def get_entry(self, name, *, scope=None):
                toolset = {"screen": "computer_use", "mcp_hidden": "terminal", "remote": "mcp-server"}.get(name, "terminal")
                return types.SimpleNamespace(toolset=toolset)

            def get_definitions(self, names, quiet=False):
                return sorted(names)

            def dispatch(self, name, arguments, *, scope=None, **options):
                return json.dumps({"allowed": name})

        self.registry = Registry()
        self.config = fake_module(
            "hermes_cli.config", _load_config_impl=lambda **options: dict(
                terminal={"backend": "ssh"}, agent={"disabled_toolsets": []}, mcp_servers={"remote": {}}),
            read_raw_config=lambda: dict(terminal={"backend": "docker"}),
            apply_terminal_config_to_env=lambda **options: options.get("env", os.environ))
        self.factory = mock.Mock(return_value="local-environment")
        self.discovery = fake_module("tools.mcp_tool_discovery", discover_mcp_tools=mock.Mock())
        self.processes = fake_module("tools.process_registry", _checkpoint_path=lambda: self.state / "processes.json")
        self.registry_module = fake_module(
            "tools.registry", ToolRegistry=Registry, tool_error=lambda error: json.dumps({"error": error}),
            _tool_module_candidates=lambda directory: [directory / "terminal_tool.py",
                                                       directory / "computer_use_tool.py",
                                                       directory / "computer_use" / "tool.py"])
        self.terminal = fake_module("tools.terminal_tool_config", _tenv=lambda key, default="": os.environ.get(key, default))
        self.modules = {"hermes_cli.config": self.config, "tools.terminal_tool_config": self.terminal,
                        "tools.terminal_tool_backends": fake_module("tools.terminal_tool_backends", _create_environment=self.factory),
                        "hermes_cli.mcp_startup": fake_module("hermes_cli.mcp_startup", _has_configured_mcp_servers=lambda: True),
                        "tools.mcp_tool_discovery": self.discovery, "tools.registry": self.registry_module,
                        "tools.process_registry": self.processes}

    def test_mutable_config_scope_and_factory_cannot_enable_forbidden_backends(self):
        with fake_modules(self.modules), mock.patch.dict(os.environ, {"TERMINAL_ENV": "ssh"}):
            adapter.install_policy()
            config = self.config._load_config_impl(want_deepcopy=False)
            self.assertEqual(config["terminal"]["backend"], "local")
            self.assertEqual(config["mcp_servers"], {})
            self.assertIn("computer_use", config["agent"]["disabled_toolsets"])
            os.environ["TERMINAL_ENV"] = "docker"
            self.assertEqual(self.terminal._tenv("TERMINAL_ENV"), "local")
            self.modules["tools.terminal_tool_backends"]._create_environment("ssh", image="image", cwd="/workspace", timeout=10)
            self.factory.assert_called_once_with("local", image="image", cwd="/workspace", timeout=10)
            target = {"TERMINAL_ENV": "modal"}
            self.config.apply_terminal_config_to_env(env=target, config={"terminal": {"backend": "modal"}})
            self.assertEqual(target["TERMINAL_ENV"], "local")

    def test_registry_filters_and_direct_dispatch_refuse_mcp_and_computer_use(self):
        with fake_modules(self.modules), mock.patch.dict(os.environ):
            adapter.install_policy()
            self.assertEqual(self.registry.get_definitions({"terminal", "screen", "remote", "mcp_hidden"}), ["terminal"])
            for name in ("screen", "remote", "mcp_hidden", "computer_use"):
                with self.subTest(name=name):
                    self.assertIn("error", json.loads(self.registry.dispatch(name, {}, scope="plugin-scope")))
            self.assertEqual(json.loads(self.registry.dispatch("terminal", {})), {"allowed": "terminal"})
            self.assertEqual(self.discovery.discover_mcp_tools(), [])
            self.assertEqual(self.registry_module._tool_module_candidates(Path("/tools")), [Path("/tools/terminal_tool.py")])

    def test_process_checkpoints_do_not_adopt_other_namespace_pid_files(self):
        with fake_modules(self.modules), mock.patch.dict(os.environ):
            adapter.install_policy()
            with mock.patch.object(os, "readlink", return_value="pid:[101]"):
                first = self.processes._checkpoint_path()
            with mock.patch.object(os, "readlink", return_value="pid:[202]"):
                second = self.processes._checkpoint_path()
        self.assertNotEqual(first, second)
        self.assertEqual(first.parent, self.state)

    def test_cli_forbidden_commands_are_rejected_before_any_bootstrap(self):
        with mock.patch.object(adapter, "bootstrap") as bootstrap:
            for arguments in (["cli", "--", "mcp"], ["cli", "--", "-p", "default", "computer-use"]):
                with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                    adapter.main(arguments)
            bootstrap.assert_not_called()


class BootstrapTests(AdapterFixture):
    def setUp(self):
        super().setUp()
        self.runtime = self.workspace / "runtime"
        (self.runtime / ".venv" / "bin").mkdir(parents=True)
        (self.runtime / ".venv" / "bin" / "python").symlink_to(sys.executable)
        self.order = []
        self.state_hooks = object()
        self.client = mock.Mock(side_effect=lambda socket, request: self.rpc(request))
        self.frontend_install = mock.Mock(side_effect=lambda state: self.install_state(state))
        self.modules = {
            "hermes_bootstrap": fake_module("hermes_bootstrap"),
            "hermes_constants": fake_module("hermes_constants",
                                            get_default_hermes_root=lambda *, home=None: Path("/unmounted/default")),
            "hermes_cli.profiles": fake_module("hermes_cli.profiles", normalize_profile_name=lambda name: name,
                                               resolve_profile_env=lambda name: "unconfined",
                                               _get_default_hermes_home=lambda: Path("/unmounted/default"),
                                               get_profile_dir=lambda name: Path("/unmounted") / name,
                                               profile_exists=lambda name: False,
                                               get_active_profile=lambda root=None: "unconfined",
                                               get_active_profile_name=lambda: "unconfined",
                                               list_profiles=lambda *, lazy_skill_count=False: [],
                                               profiles_to_serve=lambda multiplex, **options: [],
                                               _profile_info=lambda name, path, *, is_default, alias_name=None,
                                               lazy_skill_count=False: types.SimpleNamespace(
                                                   name=name, path=path, is_default=is_default)),
            "control": fake_module("control", client_request=self.client),
            "frontend_patches": fake_module("frontend_patches", install=self.frontend_install),
            "frontends": fake_module("frontends", read_backend_connection=mock.Mock(return_value="private-ws"),
                                     attach_environment=mock.Mock(return_value={"HERMES_TUI_GATEWAY_URL": "private-ws"}))}
        self.environment = dict(HERMES_HOME=str(self.state), HERMES_SANDBOX_RUNTIME=str(self.runtime),
                                HERMES_SANDBOX_PROFILE="default", HERMES_SANDBOX_WORKSPACE=str(self.workspace),
                                HERMES_SANDBOX_CONTROL_TOKEN_FILE="/run/hermes/control.token")

    def install_state(self, state):
        self.order.append("state-hooks")
        self.assertEqual(state, self.state)
        return self.state_hooks

    @contextlib.contextmanager
    def bootstrap_context(self, *, manifest=None):
        environment = dict(self.environment)
        if manifest is not None:
            environment["HERMES_SANDBOX_BACKEND_MANIFEST"] = manifest
        original_import = adapter.importlib.import_module

        def import_module(name):
            if name == "hermes_bootstrap":
                self.order.append("upstream-pm")
                os.environ["PYTHONPATH"] = str(self.runtime / "pm-generation")
            return original_import(name)

        def install(profile, state, request):
            self.order.append("worker-hooks")
            self.assertEqual((profile, state), ("default", self.state))
            self.integration.request = request
            return self.integration

        with fake_modules(self.modules), mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch.object(adapter, "_ACTIVE_ADAPTER", None), mock.patch.object(sys, "path", list(sys.path)), \
                mock.patch.object(adapter, "validate_runtime", side_effect=lambda runtime: self.verify_runtime(runtime)), \
                mock.patch.object(adapter, "_apply_runtime_environment"), \
                mock.patch.object(adapter.importlib, "import_module", side_effect=import_module), \
                mock.patch.object(adapter, "install_policy", side_effect=lambda: self.order.append("policy")), \
                mock.patch.object(adapter, "install", side_effect=install), \
                mock.patch.object(adapter, "_register_broker_tools", side_effect=lambda installed: self.order.append("tools")):
            yield

    def verify_runtime(self, runtime):
        self.order.append("pin-verified")
        self.assertEqual(runtime, str(self.runtime))
        return self.runtime

    def test_verified_isolated_bootstrap_keeps_pm_paths_and_frontend_hooks(self):
        with self.bootstrap_context():
            installed = adapter.bootstrap()
            self.assertIs(installed, self.integration)
            self.assertIs(installed.state_hooks, self.state_hooks)
            protected_support = Path(adapter.__file__).resolve().parent
            expected_paths = [str(protected_support / "patches"), str(protected_support), str(self.runtime),
                              str(self.runtime / "pm-generation")]
            self.assertEqual(os.environ["PYTHONPATH"].split(os.pathsep), expected_paths)
            self.assertEqual(os.environ["PYTHONSAFEPATH"], "1")
            self.assertEqual(os.environ["TERMINAL_ENV"], "local")
            self.assertIs(adapter.bootstrap(), installed)
            self.assertEqual(self.order, ["pin-verified", "upstream-pm", "policy", "state-hooks", "worker-hooks", "tools"])
        self.frontend_install.assert_called_once_with(self.state)

    def test_current_profile_only_and_capability_transport_remains_inside_control_client(self):
        with self.bootstrap_context():
            installed = adapter.bootstrap()
            profiles = self.modules["hermes_cli.profiles"]
            self.assertEqual(profiles.resolve_profile_env("default"), str(self.state))
            self.assertEqual(self.modules["hermes_constants"].get_default_hermes_root(), self.state)
            self.assertEqual(profiles._get_default_hermes_home(), self.state)
            self.assertEqual(profiles.get_profile_dir("default"), self.state)
            self.assertTrue(profiles.profile_exists("default"))
            self.assertFalse(profiles.profile_exists("other"))
            self.assertEqual(profiles.get_active_profile(), "default")
            self.assertEqual(profiles.get_active_profile_name(), "default")
            self.assertEqual(profiles.profiles_to_serve(True), [("default", self.state)])
            self.assertEqual(profiles.list_profiles(lazy_skill_count=True)[0].path, self.state)
            with self.assertRaises(ValueError):
                profiles.resolve_profile_env("other")
            with self.assertRaises(ValueError):
                profiles.get_profile_dir("other")
            installed.broker_tool("status", dict(kind="cron", task_id="task", attempt_id="attempt"))
        self.client.assert_called_once_with(Path("/run/hermes/control.sock"), dict(
            action="status", profile="default", kind="cron", task_id="task", attempt_id="attempt"))

    def test_backend_manifest_bridge_is_fixed_mount_only(self):
        with self.bootstrap_context(manifest="/run/hermes/backend.json"):
            adapter.bootstrap()
            self.assertEqual(os.environ["HERMES_TUI_GATEWAY_URL"], "private-ws")
        self.modules["frontends"].read_backend_connection.assert_called_once_with("/run/hermes/backend.json")
        with self.bootstrap_context(manifest=str(self.state / "backend.json")), self.assertRaises(ValueError):
            adapter.bootstrap()

    def test_pin_failure_precedes_any_upstream_import(self):
        with mock.patch.object(adapter, "_ACTIVE_ADAPTER", None), \
                mock.patch.object(adapter, "validate_runtime", side_effect=ValueError("wrong pin")), \
                mock.patch.object(adapter.importlib, "import_module") as imports:
            with self.assertRaisesRegex(ValueError, "wrong pin"):
                adapter.bootstrap()
            imports.assert_not_called()

    def test_workers_use_explicit_false_exit_one_and_true_exit_zero(self):
        with mock.patch.dict(os.environ, {"HERMES_SANDBOX_PROFILE": "default",
                                          "HERMES_SANDBOX_WORKER_SNAPSHOT": "/run/hermes/worker.json"}), \
                mock.patch.object(adapter, "_worker_snapshot") as snapshot, \
                mock.patch.object(adapter, "bootstrap", return_value=self.integration), \
                mock.patch.object(adapter, "run_worker", side_effect=[False, True]) as worker:
            self.assertEqual(adapter.main(["worker", "cron", "attempt"]), 1)
            self.assertEqual(adapter.main(["worker", "cron", "attempt"]), 0)
            snapshot.assert_called_with("cron", "attempt", "default", Path("/run/hermes/worker.json"))
            worker.assert_called_with("cron", "attempt", "default", self.state)

    def test_worker_exception_entry_exit_two_does_not_log_credentials(self):
        tree = ast.parse(Path(adapter.__file__).read_bytes())
        entry = tree.body[-1]
        self.assertIsInstance(entry, ast.If)
        entry_module = ast.fix_missing_locations(ast.Module(body=[entry], type_ignores=[]))
        stderr = io.StringIO()
        namespace = dict(__name__="__main__", sys=sys, main=mock.Mock(side_effect=ValueError("invalid worker")))
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as stopped:
            exec(compile(entry_module, "adapter-entry", "exec"), namespace)
        self.assertEqual(stopped.exception.code, 2)
        self.assertEqual(stderr.getvalue(), "Hermes sandbox adapter refused: invalid worker\n")

    def test_worker_rejects_extra_arguments_and_alternate_snapshot_before_bootstrap(self):
        with mock.patch.object(adapter, "bootstrap") as bootstrap:
            with self.assertRaises(ValueError):
                adapter.main(["worker", "cron", "attempt", "/writable/payload"])
            with mock.patch.dict(os.environ, {"HERMES_SANDBOX_WORKER_SNAPSHOT": "/writable/payload"}):
                with self.assertRaises(ValueError):
                    adapter.main(["worker", "cron", "attempt"])
        bootstrap.assert_not_called()


@unittest.skipUnless((UPSTREAM / "cron" / "executions.py").is_file(),
                     "Set HERMES_UPSTREAM_SOURCE to test installation against pinned execution seams")
class InstallationTests(AdapterFixture):
    @classmethod
    def setUpClass(cls):
        adapter.validate_runtime(UPSTREAM)

    def setUp(self):
        super().setUp()
        execution_names = {"recover_interrupted_executions", "terminalize_dead_owner", "live_inflight_execution"}
        self.executions = fake_module("cron.executions", **vars(typing))
        vars(self.executions).update(__file__=str(UPSTREAM / "cron" / "executions.py"))
        self.scheduler_module = fake_module(
            "cron.scheduler", _launch_external_cron_worker=mock.Mock(), mark_execution_handoff_pending=mock.Mock(),
            _record_external_cron_worker=mock.Mock(), _ExternalWorkerPostHandoffError=RuntimeError,
            _running_lock=threading.Lock(), _restart_safe_waiter_job_ids=set(), _scope_isolated_job_ids=set())
        for name in execution_names:
            original = mock.Mock(name=name)
            setattr(self.executions, name, original)
            setattr(self.scheduler_module, name, original)
        self.kanban = fake_module("hermes_cli.kanban_db_dispatch")
        self.board_db = fake_module("hermes_cli.kanban_db")
        self.native_tick = mock.Mock(return_value="native-tick")
        self.kanban.dispatch_once = self.native_tick
        self.board_db.dispatch_once = self.native_tick
        for name in ("_default_spawn", "_terminate_reclaimed_worker", "_kill_fn", "_worker_alive", "_pid_alive",
                     "_process_fingerprint", "_pid_recycled", "enforce_max_runtime"):
            original = mock.Mock(name=name)
            setattr(self.kanban, name, original)
            setattr(self.board_db, name, original)
        self.modules = {"cron.scheduler": self.scheduler_module, "cron.executions": self.executions,
                        "hermes_cli.kanban_db_dispatch": self.kanban, "hermes_cli.kanban_db": self.board_db,
                        "agent.kanban_turn_recovery": fake_module("agent.kanban_turn_recovery",
                                                                  worker_claim_is_live=lambda: False),
                        "patches.ledger": ledger}
        self.originals = {module: dict(vars(module)) for module in (
            self.executions, self.scheduler_module, self.kanban, self.board_db)}

    def test_actual_install_patches_ledger_aliases_spawn_liveness_shutdown_and_timeout_seams(self):
        with fake_modules(self.modules):
            installed = self.integration.install()
            self.assertIs(installed, self.integration)
            for name in ("recover_interrupted_executions", "terminalize_dead_owner", "live_inflight_execution"):
                with self.subTest(name=name):
                    self.assertIs(getattr(self.scheduler_module, name), getattr(self.executions, name))
                    self.assertNotIn("_owner_is_live", getattr(self.executions, name).__code__.co_names)
            self.assertEqual(self.scheduler_module._launch_external_cron_worker, self.integration.launch_cron)
            for name, expected in {
                "_default_spawn": self.integration.spawn_kanban,
                "_terminate_reclaimed_worker": self.integration.terminate_kanban,
                "_worker_alive": self.integration.worker_alive, "_pid_alive": self.integration.worker_alive,
                "_process_fingerprint": self.integration.worker_fingerprint,
                "_pid_recycled": self.integration.worker_recycled,
                "enforce_max_runtime": self.integration.enforce_kanban_runtime,
            }.items():
                with self.subTest(name=name):
                    self.assertEqual(getattr(self.kanban, name), expected)
                    self.assertEqual(getattr(self.board_db, name), expected)
            self.assertEqual(self.kanban._kill_fn(None), self.integration.cancel_pid)
            saved_count = len(self.integration._originals)
            self.assertIs(self.integration.install(), installed)
            self.assertEqual(len(self.integration._originals), saved_count)
            connection = object()
            with mock.patch.object(self.integration, "reconcile_kanban") as reconcile:
                self.assertEqual(self.kanban.dispatch_once(connection, board="default", max_spawn=1), "native-tick")
                reconcile.assert_called_once_with(connection, board="default")
            self.native_tick.assert_called_once_with(connection, board="default", max_spawn=1)
            self.integration.uninstall()
        for module, originals in self.originals.items():
            for name, original in originals.items():
                with self.subTest(module=module.__name__, name=name):
                    self.assertIs(getattr(module, name), original)
        self.assertEqual(self.integration._originals, [])

    def test_uninstall_does_not_overwrite_later_owners_replacement(self):
        with fake_modules(self.modules):
            self.integration.install()
            later = mock.Mock(name="later-owned-hook")
            self.kanban._default_spawn = later
            self.integration.uninstall()
            self.assertIs(self.kanban._default_spawn, later)

    def test_partial_install_failure_rolls_back_changed_process_hooks(self):
        failing_modules = {**self.modules, "hermes_cli.kanban_db": None}
        with fake_modules(failing_modules), self.assertRaises(ImportError):
            self.integration.install()
        self.assertEqual(self.integration._originals, [])
        for module in (self.executions, self.scheduler_module, self.kanban):
            for name, original in self.originals[module].items():
                with self.subTest(module=module.__name__, name=name):
                    self.assertIs(getattr(module, name), original)


if __name__ == "__main__":
    unittest.main()
