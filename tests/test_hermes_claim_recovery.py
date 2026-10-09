import ast
import json
import logging
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest import mock


SUPPORT = Path(__file__).resolve().parents[1] / "bin/ai_wrapper_data"
sys.path.insert(0, str(SUPPORT))
from hermes_sandbox import adapter


class BrokerClaimRecoveryTests(unittest.TestCase):
    def setUp(self):
        upstream = Path(os.environ.get("HERMES_UPSTREAM_SOURCE", "/tmp/hermes-upstream-WdPss4"))
        if not upstream.is_dir():
            self.skipTest("Set HERMES_UPSTREAM_SOURCE to the reviewed checkout")
        adapter.validate_runtime(upstream)
        temporary = tempfile.TemporaryDirectory(prefix="hermes-recovery-")
        self.addCleanup(temporary.cleanup)
        self.state = Path(temporary.name)
        self.database = self.state / "board.db"
        self.handle = adapter._worker_handle("work", "task", "1")
        self.connection = sqlite3.connect(self.database)
        self.addCleanup(self.connection.close)
        self.connection.executescript(
            "CREATE TABLE tasks (id TEXT, status TEXT, worker_pid INTEGER, current_run_id INTEGER, "
            "claim_lock TEXT, claim_expires INTEGER);"
            "CREATE TABLE task_runs (id INTEGER, ended_at INTEGER, worker_pid INTEGER, claim_expires INTEGER);")
        expires = int(time.time()) + 300
        self.connection.execute("INSERT INTO tasks VALUES (?,?,?,?,?,?)",
                                ("task", "running", self.handle, 1, "claim", expires))
        self.connection.execute("INSERT INTO task_runs VALUES (?,?,?,?)", (1, None, self.handle, expires))
        self.connection.commit()
        owner = self.state / "worker-spool/kanban/task/1.owner.json"
        owner.parent.mkdir(parents=True)
        owner.write_text(json.dumps(dict(pid=self.handle, profile="work", kind="kanban",
                                         task_id="task", attempt_id="1", claim_lock="claim")))
        self.environment = dict(HERMES_KANBAN_TASK="task", HERMES_KANBAN_RUN_ID="1",
                                HERMES_KANBAN_CLAIM_LOCK="claim", HERMES_KANBAN_DB=str(self.database))
        tree = ast.parse((upstream / "agent/kanban_turn_recovery.py").read_text())
        selected = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                        and node.name == "worker_claim_is_live")
        namespace = dict(os=os, Path=Path, sqlite3=sqlite3, logger=logging.getLogger(__name__),
                         kanban_task_id=lambda: os.environ.get("HERMES_KANBAN_TASK"),
                         _kanban_db_path=lambda: os.environ.get("HERMES_KANBAN_DB"),
                         _now=lambda: int(time.time()))
        exec(compile(ast.Module(body=[selected], type_ignores=[]), "pinned-claim-proof", "exec"), namespace)
        self.native = namespace["worker_claim_is_live"]
        self.check = adapter._broker_claim_check(self.native, "work", self.state)

    def test_broker_identity_preserves_native_live_lease_retry_proof(self):
        with mock.patch.dict(os.environ, self.environment):
            self.assertFalse(self.native())
            self.assertTrue(self.check())
            self.assertNotEqual(os.getpid(), self.handle)

    def test_stale_run_expired_lease_closed_run_and_foreign_identity_fail_closed(self):
        mutations = (
            "UPDATE tasks SET current_run_id=2",
            "UPDATE tasks SET claim_lock='foreign'",
            "UPDATE tasks SET claim_expires=1",
            "UPDATE task_runs SET claim_expires=1",
            "UPDATE task_runs SET ended_at=1",
            "UPDATE task_runs SET worker_pid=123",
        )
        with mock.patch.dict(os.environ, self.environment):
            for statement in mutations:
                with self.subTest(statement=statement):
                    self.connection.execute("SAVEPOINT change")
                    self.connection.execute(statement)
                    self.connection.execute("RELEASE change")
                    self.assertFalse(self.check())
                    expires = int(time.time()) + 300
                    self.connection.execute("UPDATE tasks SET current_run_id=1,claim_lock='claim',claim_expires=?", (expires,))
                    self.connection.execute("UPDATE task_runs SET ended_at=NULL,worker_pid=?,claim_expires=?", (self.handle, expires))
                    self.connection.commit()
            with mock.patch.dict(os.environ, {"HERMES_KANBAN_RUN_ID": "other"}):
                self.assertFalse(self.check())


if __name__ == "__main__":
    unittest.main()
