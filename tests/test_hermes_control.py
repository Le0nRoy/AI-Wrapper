"""Hermes broker unit and Unix-socket integration tests; never start live units."""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock
import uuid


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin" / "ai_wrapper_data"))
from hermes_sandbox import control


class FakeSystemd:
    def __init__(self):
        self.calls = []
        self.units = {}
        self.launch_error = None
        self.launch_returncode = 0
        self.stop_error = None
        self.show_error = False

    def properties(self, unit, **changes):
        value = {
            "Id": unit, "LoadState": "loaded", "ActiveState": "active",
            "SubState": "running", "Result": "success", "ExecMainStatus": "0",
            "ExecMainCode": "0", "Transient": "yes", "Slice": "hermes-workers.slice",
            "Restart": "no", "Type": "exec", "RemainAfterExit": "yes",
        }
        value.update(changes)
        return value

    def __call__(self, argv, **kwargs):
        self.calls.append((list(argv), dict(kwargs)))
        if argv[0] == "/usr/bin/systemd-run":
            unit = next(value.split("=", 1)[1] for value in argv if value.startswith("--unit="))
            if self.launch_returncode == 0:
                self.units[unit] = self.properties(unit)
            if self.launch_error is not None:
                raise self.launch_error
            return subprocess.CompletedProcess(argv, self.launch_returncode, "", "")
        unit = argv[-1]
        if "stop" in argv:
            if self.stop_error is not None:
                raise self.stop_error
            self.units.pop(unit, None)
            return subprocess.CompletedProcess(argv, 0, "", "")
        if self.show_error:
            return subprocess.CompletedProcess(argv, 1, "", "bus unavailable")
        properties = self.units.get(unit)
        if properties is None:
            return subprocess.CompletedProcess(argv, 4, "LoadState=not-found\n", "")
        output = "\n".join(key + "=" + value for key, value in properties.items()) + "\n"
        return subprocess.CompletedProcess(argv, 0, output, "")

    def launches(self):
        return [argv for argv, _kwargs in self.calls if argv[0] == "/usr/bin/systemd-run"]

    def stops(self):
        return [argv for argv, _kwargs in self.calls if "stop" in argv]


class BrokerFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hermes-control-" + uuid.uuid4().hex + "-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.policy_dir = self.root / "policy"
        self.policy_dir.mkdir(mode=0o700)
        self.profiles_dir = self.policy_dir / "profiles"
        self.spool_dir = self.root / "control"
        self.runtime = self.root / "runtime"
        self.state = self.root / "state"
        self.workspace = self.root / "workspace"
        self.wrapper_dir = self.root / "bin"
        self.socket_dir = self.root / "socket"
        for path in (self.profiles_dir, self.spool_dir, self.runtime, self.state,
                     self.workspace, self.wrapper_dir, self.socket_dir):
            path.mkdir(mode=0o700)
        self.wrapper = self.wrapper_dir / "hermes_wrapper"
        self.wrapper.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.wrapper.chmod(0o700)
        interpreter_dir = self.runtime / ".venv" / "bin"
        interpreter_dir.mkdir(mode=0o700, parents=True)
        interpreter = interpreter_dir / "python"
        interpreter.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        interpreter.chmod(0o700)
        (self.runtime / ".venv" / "pyvenv.cfg").write_text("home = /usr/bin\n", encoding="utf-8")
        self.profile = "profile_" + uuid.uuid4().hex
        self.capability = uuid.uuid4().hex + uuid.uuid4().hex
        self.task = "task_" + uuid.uuid4().hex
        self.attempt = "attempt_" + uuid.uuid4().hex
        self.policy = {"version": 1, "runtime": str(self.runtime),
                       "state": str(self.state), "workspace": str(self.workspace)}
        self.policy_path = self.profiles_dir / (self.profile + ".json")
        self.write_policy()
        self.token_path = self.profiles_dir / (self.profile + ".token")
        self.token_path.write_text(self.capability, encoding="ascii")
        self.token_path.chmod(0o600)
        self.request = {"action": "launch", "profile": self.profile, "kind": "cron",
                        "task_id": self.task, "attempt_id": self.attempt,
                        "capability": self.capability}
        self.source = self.publish(self.request)
        self.runner = FakeSystemd()
        self.broker = self.new_broker()

    def write_policy(self):
        self.policy_path.write_text(json.dumps(self.policy), encoding="utf-8")
        self.policy_path.chmod(0o600)

    def new_broker(self):
        broker = control.Broker(self.profiles_dir, self.spool_dir, self.wrapper, runner=self.runner)
        self.addCleanup(broker.close)
        return broker

    def restart(self):
        self.broker.close()
        self.broker = self.new_broker()
        return self.broker

    def publish(self, request, payload=None, state=None):
        directory = (self.state if state is None else state) / "worker-spool" / request["kind"] / request["task_id"]
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        path = directory / (request["attempt_id"] + ".json")
        value = {field: request[field] for field in control.IDENTITY_FIELDS}
        value["payload"] = {"prompt": "run inside sandbox"} if payload is None else payload
        path.write_text(json.dumps(value), encoding="utf-8")
        path.chmod(0o600)
        return path

    def additional_profile(self):
        name = "other_" + uuid.uuid4().hex
        capability = uuid.uuid4().hex + uuid.uuid4().hex
        state = self.root / (name + "_state")
        workspace = self.root / (name + "_workspace")
        state.mkdir(mode=0o700)
        workspace.mkdir(mode=0o700)
        policy = dict(self.policy, state=str(state), workspace=str(workspace))
        policy_path = self.profiles_dir / (name + ".json")
        policy_path.write_text(json.dumps(policy), encoding="utf-8")
        policy_path.chmod(0o600)
        token_path = self.profiles_dir / (name + ".token")
        token_path.write_text(capability, encoding="ascii")
        token_path.chmod(0o600)
        request = dict(self.request, profile=name, capability=capability)
        self.publish(request, state=state)
        self.restart()
        return request, token_path

    def status_request(self, action="status"):
        return dict(self.request, action=action)

    def record_path(self):
        return self.spool_dir / "records" / (control._key(self.request) + ".json")

    def snapshot_path(self):
        return self.spool_dir / "snapshots" / self.profile / "cron" / (self.attempt + ".json")

    def assert_error(self, code, callback, *args):
        with self.assertRaises(control.BrokerError) as caught:
            callback(*args)
        self.assertEqual(caught.exception.code, code)


class LifecycleTests(BrokerFixture):
    def test_fixed_launch_and_immutable_snapshot(self):
        with self.subTest(phase="Arrange"):
            original_bytes = self.source.read_bytes()
        with self.subTest(phase="Act"):
            result = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(result["stage"], "adopted")
            self.assertEqual(result["outcome"], "running")
            self.assertEqual(self.runner.launches(), [[
                "/usr/bin/systemd-run", "--user", "--unit=" + result["unit"],
                "--property=Type=exec", "--property=Restart=no", "--property=RemainAfterExit=yes",
                "--slice=hermes-workers.slice",
                str(self.wrapper), "--profile", self.profile, "_worker", "cron", self.attempt,
            ]])
            self.assertEqual(self.snapshot_path().read_bytes(), original_bytes)
            self.assertEqual(stat.S_IMODE(self.snapshot_path().stat().st_mode), 0o400)
            self.assertEqual(stat.S_IMODE(self.record_path().stat().st_mode), 0o600)
            self.assertTrue(json.loads(self.record_path().read_text())["dispatch_started"])
            self.assertFalse({"pid", "argv", "payload", "state", "runtime"} & set(result))
            for _argv, kwargs in self.runner.calls:
                self.assertEqual(kwargs["cwd"], "/")
                self.assertFalse(kwargs.get("shell", False))
                self.assertEqual(kwargs["timeout"], control.COMMAND_TIMEOUT)

    def test_retry_and_restart_adopt_without_rereading_source(self):
        with self.subTest(phase="Arrange"):
            first = self.broker.handle(self.request)
            self.source.unlink()
            self.restart()
        with self.subTest(phase="Act"):
            recovered = self.broker.recover()
            retry = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(recovered, [first])
            self.assertEqual(retry, first)
            self.assertEqual(len(self.runner.launches()), 1)

    def test_finished_status_persists_success_and_failure(self):
        for active, result, status, outcome in (
                ("active", "success", "0", "succeeded"),
                ("inactive", "success", "0", "succeeded"),
                ("failed", "exit-code", "9", "failed"),
                ("inactive", "signal", "15", "failed")):
            with self.subTest(phase="Arrange", outcome=outcome):
                request = dict(self.request, attempt_id="attempt_" + uuid.uuid4().hex)
                self.publish(request)
                launched = self.broker.handle(request)
                unit = launched["unit"]
                self.runner.units[unit] = self.runner.properties(
                    unit, ActiveState=active, SubState="exited", Result=result,
                    ExecMainStatus=status, ExecMainCode="1")
            with self.subTest(phase="Act", outcome=outcome):
                finished = self.broker.handle(dict(request, action="status"))
                self.runner.units.pop(unit)
                self.restart()
                retried = self.broker.handle(request)
            with self.subTest(phase="Assert", outcome=outcome):
                self.assertEqual(finished["stage"], "finished")
                self.assertEqual(finished["outcome"], outcome)
                self.assertEqual(finished["exit_status"], int(status))
                self.assertEqual(retried, finished)
                self.assertEqual(sum("--unit=" + unit in argv for argv in self.runner.launches()), 1)

    def test_collected_unit_is_unknown_and_never_replayed(self):
        with self.subTest(phase="Arrange"):
            launched = self.broker.handle(self.request)
            self.runner.units.clear()
            self.restart()
        with self.subTest(phase="Act"):
            finished = self.broker.handle(self.request)
            retry = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(finished["unit"], launched["unit"])
            self.assertEqual(finished["stage"], "finished")
            self.assertEqual(finished["outcome"], "unknown")
            self.assertEqual(retry, finished)
            self.assertEqual(len(self.runner.launches()), 1)

    def test_launch_timeout_adopts_worker_that_did_start(self):
        with self.subTest(phase="Arrange"):
            self.runner.launch_error = subprocess.TimeoutExpired("fake", 15)
        with self.subTest(phase="Act"):
            self.assert_error("systemd_unavailable", self.broker.handle, self.request)
            self.restart()
            result = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(result["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_late_unit_is_adopted_after_uncertain_dispatch(self):
        with self.subTest(phase="Arrange"):
            self.runner.launch_returncode = 1
            unknown = self.broker.handle(self.request)
            self.restart()
            self.runner.units[unknown["unit"]] = self.runner.properties(unknown["unit"])
        with self.subTest(phase="Act"):
            adopted = self.broker.handle(self.status_request())
            retried = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(unknown["stage"], "accepted")
            self.assertEqual(unknown["outcome"], "unknown")
            self.assertEqual(adopted["stage"], "adopted")
            self.assertEqual(adopted["unit"], unknown["unit"])
            self.assertEqual(retried, adopted)
            self.assertEqual(len(self.runner.launches()), 1)

    def test_completion_while_broker_is_down_preserves_exit_status(self):
        with self.subTest(phase="Arrange"):
            launched = self.broker.handle(self.request)
            self.broker.close()
            self.runner.units[launched["unit"]] = self.runner.properties(
                launched["unit"], ActiveState="active", SubState="exited",
                ExecMainCode="1", ExecMainStatus="0")
        with self.subTest(phase="Act"):
            self.broker = self.new_broker()
            recovered = self.broker.recover()
            retry = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(recovered[0]["stage"], "finished")
            self.assertEqual(recovered[0]["outcome"], "succeeded")
            self.assertEqual(recovered[0]["exit_status"], 0)
            self.assertEqual(retry, recovered[0])
            self.assertEqual(len(self.runner.launches()), 1)

    def test_orphan_snapshot_after_crash_is_reused_without_changed_source(self):
        with self.subTest(phase="Arrange"):
            original = self.source.read_bytes()
        with self.subTest(phase="Act"):
            with mock.patch.object(self.broker, "_save", side_effect=RuntimeError("crash before acceptance")):
                with self.assertRaises(RuntimeError):
                    self.broker.handle(self.request)
            self.publish(self.request, {"prompt": "new payload after crash"})
            self.restart()
            launched = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(self.snapshot_path().read_bytes(), original)
            self.assertEqual(launched["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_concurrent_duplicate_launches_create_one_unit(self):
        with self.subTest(phase="Arrange"):
            barrier = threading.Barrier(2)
            results = []
            errors = []
            def launch():
                try:
                    barrier.wait(timeout=5)
                    results.append(self.broker.handle(self.request))
                except BaseException as error:
                    errors.append(error)
            threads = [threading.Thread(target=launch, daemon=True) for _index in range(2)]
        with self.subTest(phase="Act"):
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=5)
        with self.subTest(phase="Assert"):
            self.assertFalse(any(thread.is_alive() for thread in threads))
            self.assertEqual(errors, [])
            self.assertEqual(len(results), 2)
            self.assertEqual(results[0], results[1])
            self.assertEqual(len(self.runner.launches()), 1)

    def test_crash_after_intent_before_dispatch_does_not_replay(self):
        with self.subTest(phase="Arrange"):
            original_save = self.broker._save
            def save_and_crash(record):
                original_save(record)
                if record["dispatch_started"]:
                    raise RuntimeError("simulated crash after fsync")
        with self.subTest(phase="Act"):
            with mock.patch.object(self.broker, "_save", side_effect=save_and_crash):
                with self.assertRaises(RuntimeError):
                    self.broker.handle(self.request)
            self.restart()
            result = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(result["outcome"], "unknown")
            self.assertEqual(self.runner.launches(), [])

    def test_crash_before_dispatch_intent_resumes_same_snapshot(self):
        with self.subTest(phase="Arrange"):
            original_save = self.broker._save
            def save_and_crash(record):
                original_save(record)
                raise RuntimeError("simulated crash after acceptance")
        with self.subTest(phase="Act"):
            with mock.patch.object(self.broker, "_save", side_effect=save_and_crash):
                with self.assertRaises(RuntimeError):
                    self.broker.handle(self.request)
            self.publish(self.request, {"prompt": "changed after acceptance"})
            self.restart()
            result = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(result["stage"], "adopted")
            snapshot = control.read_snapshot(self.spool_dir, self.profile, "cron", self.attempt)
            self.assertEqual(snapshot["payload"]["prompt"], "run inside sandbox")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_cancel_is_durable_and_idempotent(self):
        with self.subTest(phase="Arrange"):
            launched = self.broker.handle(self.request)
        with self.subTest(phase="Act"):
            cancelled = self.broker.handle(self.status_request("cancel"))
            self.restart()
            retry = self.broker.handle(self.request)
            cancelled_again = self.broker.handle(self.status_request("cancel"))
        with self.subTest(phase="Assert"):
            self.assertEqual(cancelled["stage"], "finished")
            self.assertEqual(cancelled["outcome"], "cancelled")
            self.assertEqual(retry, cancelled)
            self.assertEqual(cancelled_again, cancelled)
            self.assertEqual(self.runner.stops(), [["/usr/bin/systemctl", "--user", "stop", launched["unit"]]])
            self.assertEqual(len(self.runner.launches()), 1)

    def test_cancel_recovers_after_stop_timeout(self):
        with self.subTest(phase="Arrange"):
            self.broker.handle(self.request)
            self.runner.stop_error = subprocess.TimeoutExpired("fake", 15)
        with self.subTest(phase="Act"):
            self.assert_error("systemd_unavailable", self.broker.handle, self.status_request("cancel"))
            self.runner.stop_error = None
            self.restart()
            result = self.broker.recover()
        with self.subTest(phase="Assert"):
            self.assertEqual(result[0]["outcome"], "cancelled")
            self.assertEqual(len(self.runner.launches()), 1)
            self.assertTrue(json.loads(self.record_path().read_text())["cancel_confirmed"])

    def test_failed_start_and_bus_failure_never_replay(self):
        with self.subTest(phase="Arrange"):
            self.runner.launch_returncode = 1
        with self.subTest(phase="Act"):
            result = self.broker.handle(self.request)
            self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(result["outcome"], "unknown")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_systemd_unavailable_does_not_claim_finished(self):
        with self.subTest(phase="Arrange"):
            self.broker.handle(self.request)
            self.runner.show_error = True
        with self.subTest(phase="Act"):
            self.assert_error("systemd_unavailable", self.broker.handle, self.status_request())
        with self.subTest(phase="Assert"):
            self.assertEqual(json.loads(self.record_path().read_text())["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_identity_conflict_and_missing_status_have_no_side_effects(self):
        with self.subTest(phase="Arrange"):
            self.broker.handle(self.request)
            changed = dict(self.request, task_id="different")
            missing = dict(self.request, attempt_id="missing", action="status")
            count = len(self.runner.calls)
        with self.subTest(phase="Act"):
            self.assert_error("attempt_identity_conflict", self.broker.handle, changed)
            self.assert_error("task_not_found", self.broker.handle, missing)
        with self.subTest(phase="Assert"):
            self.assertEqual(len(self.runner.calls), count)

    def test_kanban_uses_distinct_unit_and_snapshot(self):
        with self.subTest(phase="Arrange"):
            request = dict(self.request, kind="kanban")
            self.publish(request)
        with self.subTest(phase="Act"):
            cron = self.broker.handle(self.request)
            kanban = self.broker.handle(request)
        with self.subTest(phase="Assert"):
            self.assertNotEqual(cron["unit"], kanban["unit"])
            self.assertEqual(control.read_snapshot(self.spool_dir, self.profile, "kanban", self.attempt)["kind"], "kanban")


class ValidationTests(BrokerFixture):
    def test_closed_schema_and_lexical_ids(self):
        with self.subTest(phase="Arrange"):
            cases = [(dict(self.request, **{field: value}), "invalid_token")
                     for field in control.IDENTITY_FIELDS
                     for value in ("../escape", "/absolute", "-flag", "$(id)", "a..b",
                                   "a" * (65 if field == "profile" else 129), None, [])]
            cases += [(dict(self.request, profile=value), "invalid_token")
                      for value in ("Uppercase", "a.b")]
            cases += [(dict(self.request, **{field: "value"}), "invalid_request_schema")
                      for field in ("argv", "env", "mount", "pid", "flags", "path", "payload")]
            cases += [(dict(self.request, action="ack"), "invalid_action"),
                      (dict(self.request, kind="shell"), "invalid_kind")]
        with self.subTest(phase="Act"):
            for request, code in cases:
                with self.subTest(request=request):
                    self.assert_error(code, self.broker.handle, request)
        with self.subTest(phase="Assert"):
            self.assertEqual(self.runner.calls, [])
            self.assertEqual(list((self.spool_dir / "records").iterdir()), [])

    def test_safe_long_dotted_identifiers_match_adapter_contract(self):
        with self.subTest(phase="Arrange"):
            request = dict(self.request, task_id="task." + "a" * 123,
                           attempt_id="attempt." + "b" * 120)
            self.publish(request)
        with self.subTest(phase="Act"):
            result = self.broker.handle(request)
            snapshot = control.read_snapshot(self.spool_dir, self.profile, "cron", request["attempt_id"])
        with self.subTest(phase="Assert"):
            self.assertEqual(result["stage"], "adopted")
            self.assertEqual(snapshot["task_id"], request["task_id"])
            self.assertEqual(self.runner.launches()[0][-1], request["attempt_id"])
            self.assertEqual(len(self.runner.launches()), 1)

    def test_json_rejects_duplicate_keys_nonfinite_utf8_and_depth(self):
        with self.subTest(phase="Arrange"):
            cases = [(b'{"action":"status","action":"launch"}', "duplicate_json_key"),
                     (b'{"payload":NaN}', "invalid_json"), (b'{"payload":Infinity}', "invalid_json"),
                     (b'{"payload":1e9999}', "invalid_json"),
                     (b'\xff', "invalid_json"), (b'[' * 2000 + b']' * 2000, "invalid_json")]
        with self.subTest(phase="Act"):
            for data, code in cases:
                self.assert_error(code, control._decode, data, 10000)
        with self.subTest(phase="Assert"):
            self.assertEqual(self.runner.calls, [])

    def test_payload_schema_identity_size_and_nonfinite_rejected(self):
        with self.subTest(phase="Arrange"):
            original = self.source.read_bytes()
            value = json.loads(original)
            wrong = dict(value, task_id="wrong")
            extra = dict(value, argv=["sh"])
            cases = [(json.dumps(wrong).encode(), "payload_identity_mismatch"),
                     (json.dumps(extra).encode(), "invalid_payload_schema"),
                     (json.dumps(dict(value, payload="shell")).encode(), "payload_identity_mismatch"),
                     (b"x" * (control.MAX_PAYLOAD_BYTES + 1), "size_limit"),
                     (b'{"payload":NaN}', "invalid_json")]
        with self.subTest(phase="Act"):
            for data, code in cases:
                self.source.write_bytes(data)
                self.assert_error(code, self.broker.handle, self.request)
            self.source.write_bytes(original)
            positive = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(positive["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_source_symlink_hardlink_fifo_and_directory_rejected(self):
        with self.subTest(phase="Arrange"):
            target = self.root / "untrusted-target"
            target.write_bytes(self.source.read_bytes())
            self.source.unlink()
        with self.subTest(phase="Act"):
            self.source.symlink_to(target)
            self.assert_error("unsafe_file", self.broker.handle, self.request)
            self.source.unlink()
            os.link(target, self.source)
            self.assert_error("unsafe_file", self.broker.handle, self.request)
            self.source.unlink()
            os.mkfifo(self.source, 0o600)
            self.assert_error("unsafe_file", self.broker.handle, self.request)
            self.source.unlink()
            self.source.mkdir()
            self.assert_error("unsafe_file", self.broker.handle, self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(self.runner.launches(), [])

    def test_source_parent_symlink_rejected(self):
        with self.subTest(phase="Arrange"):
            directory = self.source.parent
            real_directory = directory.with_name("moved_" + uuid.uuid4().hex)
            directory.rename(real_directory)
            directory.symlink_to(real_directory, target_is_directory=True)
        with self.subTest(phase="Act"):
            self.assert_error("unsafe_or_missing_path", self.broker.handle, self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(self.runner.launches(), [])

    def test_policy_schema_and_dangerous_paths_rejected(self):
        with self.subTest(phase="Arrange"):
            self.broker.close()
            original = copy.deepcopy(self.policy)
            home = str(Path.home())
            cases = [(dict(original, version=True), "invalid_profile_version"),
                     (dict(original, flags=[]), "invalid_profile_schema"),
                     (dict(original, workspace="/"), "unsafe_profile_path"),
                     (dict(original, workspace=home), "unsafe_profile_path"),
                     (dict(original, state=str(self.root)), "overlapping_profile_paths"),
                     (dict(original, workspace="relative"), "invalid_path"),
                     (dict(original, runtime=str(self.root / "missing")), "unsafe_or_missing_path"),
                     (dict(original, state=str(self.profiles_dir)), "overlapping_policy"),
                     (dict(original, workspace=str(self.policy_dir)), "overlapping_policy"),
                     (dict(original, workspace=str(self.wrapper_dir)), "overlapping_policy"),
                     (dict(original, state=str(self.spool_dir)), "overlapping_policy")]
        with self.subTest(phase="Act"):
            for policy, code in cases:
                with self.subTest(policy=policy):
                    self.policy = policy
                    self.write_policy()
                    self.assert_error(code, self.new_broker)
        with self.subTest(phase="Assert"):
            self.assertEqual(self.runner.calls, [])

    def test_profile_file_and_runtime_symlink_rejected(self):
        with self.subTest(phase="Arrange"):
            self.broker.close()
            target = self.root / "policy-copy.json"
            target.write_bytes(self.policy_path.read_bytes())
            target.chmod(0o600)
            self.policy_path.unlink()
        with self.subTest(phase="Act"):
            self.policy_path.symlink_to(target)
            self.assert_error("unsafe_file", self.new_broker)
            self.policy_path.unlink()
            self.write_policy()
            alias = self.root / "runtime-alias"
            alias.symlink_to(self.runtime, target_is_directory=True)
            self.policy["runtime"] = str(alias)
            self.write_policy()
            self.assert_error("unsafe_or_missing_path", self.new_broker)
        with self.subTest(phase="Assert"):
            self.assertEqual(self.runner.calls, [])

    def test_policy_permissions_wrapper_and_spool_rejected(self):
        with self.subTest(phase="Arrange"):
            self.broker.close()
        with self.subTest(phase="Act"):
            self.policy_path.chmod(0o666)
            self.assert_error("unsafe_permissions", self.new_broker)
            self.policy_path.chmod(0o600)
            self.wrapper.chmod(0o600)
            self.assert_error("wrapper_not_executable", self.new_broker)
            self.wrapper.chmod(0o700)
            self.wrapper_dir.chmod(0o777)
            self.assert_error("unsafe_permissions", self.new_broker)
            self.wrapper_dir.chmod(0o700)
            self.spool_dir.chmod(0o755)
            self.assert_error("unsafe_permissions", self.new_broker)
        with self.subTest(phase="Assert"):
            self.assertEqual(self.runner.calls, [])

    def test_cross_profile_writable_ancestor_rejected(self):
        with self.subTest(phase="Arrange"):
            self.broker.close()
            policy = dict(self.policy, state=str(self.root))
            policy["runtime"] = str(self.runtime)
            additional = self.profiles_dir / ("another_" + uuid.uuid4().hex + ".json")
            additional.write_text(json.dumps(policy))
            additional.chmod(0o600)
        with self.subTest(phase="Act"):
            self.assert_error("overlapping_profile_paths", self.new_broker)
        with self.subTest(phase="Assert"):
            self.assertEqual(self.runner.calls, [])

    def test_policy_change_blocks_old_attempt_on_restart(self):
        with self.subTest(phase="Arrange"):
            self.broker.handle(self.request)
            alternate = self.root / "alternate-workspace"
            alternate.mkdir(mode=0o700)
            self.policy["workspace"] = str(alternate)
            self.write_policy()
        with self.subTest(phase="Act"):
            pinned = self.broker.handle(self.status_request())
            self.restart()
            self.assert_error("profile_policy_changed", self.broker.handle, self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(pinned["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_unknown_profile_corrupt_record_and_unit_policy_fail_closed(self):
        with self.subTest(phase="Arrange"):
            launched = self.broker.handle(self.request)
            original_record = self.record_path().read_bytes()
            original_unit = self.runner.units[launched["unit"]]
        with self.subTest(phase="Act"):
            self.assert_error("access_denied", self.broker.handle, dict(self.request, profile="unknown"))
            self.record_path().write_text('{"version":1}')
            self.assert_error("corrupt_record", self.broker.handle, self.request)
            self.record_path().write_bytes(original_record)
            self.runner.units[launched["unit"]] = dict(original_unit, Restart="always")
            self.assert_error("unit_policy_mismatch", self.broker.handle, self.status_request())
        with self.subTest(phase="Assert"):
            self.assertEqual(len(self.runner.launches()), 1)

    def test_single_broker_ownership_and_worker_record_limits(self):
        with self.subTest(phase="Arrange"):
            self.broker.handle(self.request)
            second = dict(self.request, attempt_id="attempt_" + uuid.uuid4().hex)
            self.publish(second)
        with self.subTest(phase="Act"):
            self.assert_error("broker_already_running", self.new_broker)
            with mock.patch.object(control, "MAX_ACTIVE_WORKERS", 1):
                self.assert_error("worker_limit", self.broker.handle, second)
            with mock.patch.object(control, "MAX_RECORDS", 1):
                self.assert_error("record_limit", self.broker.handle, second)
        with self.subTest(phase="Assert"):
            self.assertEqual(len(self.runner.launches()), 1)
            self.assertFalse((self.spool_dir / "snapshots" / self.profile / "cron" / (second["attempt_id"] + ".json")).exists())

    def test_wrong_uid_rejected_without_pid_contract(self):
        with self.subTest(phase="Arrange"):
            peer = mock.Mock()
            peer.getsockopt.return_value = struct.pack("3i", 1234, os.getuid() + 1, 99)
        with self.subTest(phase="Act"):
            self.assert_error("unauthorized_peer", control._check_peer, peer)
            peer.getsockopt.return_value = struct.pack("3i", 9876, os.getuid(), 99)
            control._check_peer(peer)
        with self.subTest(phase="Assert"):
            self.assertEqual(self.runner.calls, [])


class RetentionTests(BrokerFixture):
    def finish(self, request):
        unit = control._unit(request)
        self.runner.units[unit] = self.runner.properties(
            unit, ActiveState="active", SubState="exited", ExecMainCode="1", ExecMainStatus="0")
        return self.broker.handle(dict(request, action="status"))

    def next_request(self):
        request = dict(self.request, attempt_id="attempt_" + uuid.uuid4().hex)
        self.publish(request)
        return request

    def archive_path(self, request):
        return self.spool_dir / "archive" / (control._key(request) + ".json")

    def test_threshold_archive_survives_restart_and_never_replays_or_rebinds(self):
        with self.subTest(phase="Arrange"):
            self.broker.handle(self.request)
            finished = self.finish(self.request)
            audit = self.record_path().read_bytes()
            next_request = self.next_request()
        with self.subTest(phase="Act"):
            with mock.patch.object(control, "MAX_RECORDS", 1):
                next_result = self.broker.handle(next_request)
            self.restart()
            launch_count = len(self.runner.launches())
            stop_count = len(self.runner.stops())
            with mock.patch.object(control.os, "scandir", side_effect=RuntimeError("unexpected archive scan")):
                retries = [self.broker.handle(dict(self.request, action=action))
                           for action in ("launch", "status", "cancel")]
                self.assert_error("attempt_identity_conflict", self.broker.handle,
                                  dict(self.request, task_id="different_task"))
        with self.subTest(phase="Assert"):
            self.assertEqual(retries, [finished] * 3)
            self.assertEqual(self.archive_path(self.request).read_bytes(), audit)
            self.assertFalse(self.record_path().exists())
            self.assertFalse(self.snapshot_path().exists())
            self.assertTrue(self.source.exists())
            self.assertEqual(next_result["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), launch_count)
            self.assertEqual(len(self.runner.stops()), stop_count)
            self.assertEqual(self.runner.stops(), [["/usr/bin/systemctl", "--user", "stop", finished["unit"]]])

    def test_repeated_completed_jobs_do_not_hit_permanent_record_limit(self):
        with self.subTest(phase="Arrange"):
            requests = [self.request] + [self.next_request() for _index in range(4)]
        with self.subTest(phase="Act"):
            with mock.patch.object(control, "MAX_RECORDS", 1):
                for request in requests:
                    self.broker.handle(request)
                    self.finish(request)
            live_files = list((self.spool_dir / "records").glob("*.json"))
            archives = list((self.spool_dir / "archive").glob("*.json"))
            snapshots = list((self.spool_dir / "snapshots").rglob("*.json"))
        with self.subTest(phase="Assert"):
            self.assertEqual(len(live_files), 1)
            self.assertEqual(len(archives), 4)
            self.assertEqual(len(snapshots), 1)
            self.assertEqual(len(self.runner.launches()), 5)
            self.assertEqual(len(self.runner.stops()), 4)
            self.assertEqual(len(self.runner.units), 1)
            for path in archives:
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                self.assertEqual(json.loads(path.read_text())["stage"], "finished")

    def test_active_and_uncertain_attempts_are_never_archived(self):
        for uncertain in (False, True):
            with self.subTest(phase="Arrange", uncertain=uncertain):
                request = self.next_request()
                self.runner.launch_returncode = 1 if uncertain else 0
                self.broker.handle(request)
                rejected = self.next_request()
                record_path = self.spool_dir / "records" / (control._key(request) + ".json")
                original = record_path.read_bytes()
                count = len(list((self.spool_dir / "records").glob("*.json")))
            with self.subTest(phase="Act", uncertain=uncertain):
                with mock.patch.object(control, "MAX_RECORDS", count):
                    self.assert_error("record_limit", self.broker.handle, rejected)
            with self.subTest(phase="Assert", uncertain=uncertain):
                self.assertEqual(record_path.read_bytes(), original)
                self.assertFalse(self.archive_path(request).exists())
                self.assertEqual(self.runner.stops(), [])

    def test_limit_reconciliation_archives_only_finished_record_among_active(self):
        with self.subTest(phase="Arrange"):
            self.broker.handle(self.request)
            active_request = self.next_request()
            active = self.broker.handle(active_request)
            self.runner.units[control._unit(self.request)] = self.runner.properties(
                control._unit(self.request), ActiveState="active", SubState="exited", ExecMainCode="1")
            next_request = self.next_request()
        with self.subTest(phase="Act"):
            with mock.patch.object(control, "MAX_RECORDS", 2):
                result = self.broker.handle(next_request)
            active_status = self.broker.handle(dict(active_request, action="status"))
        with self.subTest(phase="Assert"):
            self.assertTrue(self.archive_path(self.request).exists())
            self.assertFalse(self.archive_path(active_request).exists())
            self.assertEqual(active_status, active)
            self.assertEqual(result["stage"], "adopted")
            self.assertEqual(len(self.runner.stops()), 1)
            self.assertNotIn(active["unit"], self.runner.stops()[0])

    def test_finished_policy_change_is_safe_but_active_policy_change_fails(self):
        with self.subTest(phase="Arrange"):
            self.broker.handle(self.request)
            finished = self.finish(self.request)
            active_request = self.next_request()
            with mock.patch.object(control, "MAX_RECORDS", 1):
                self.broker.handle(active_request)
            alternate = self.root / ("workspace_" + uuid.uuid4().hex)
            alternate.mkdir(mode=0o700)
            self.policy["workspace"] = str(alternate)
            self.write_policy()
            self.restart()
            launch_count = len(self.runner.launches())
        with self.subTest(phase="Act"):
            archived_result = self.broker.handle(self.request)
            self.assert_error("profile_policy_changed", self.broker.handle, active_request)
        with self.subTest(phase="Assert"):
            self.assertEqual(archived_result, finished)
            self.assertEqual(len(self.runner.launches()), launch_count)

    def test_live_finished_policy_change_also_preserves_terminal_identity(self):
        with self.subTest(phase="Arrange"):
            self.broker.handle(self.request)
            finished = self.finish(self.request)
            alternate = self.root / ("workspace_" + uuid.uuid4().hex)
            alternate.mkdir(mode=0o700)
            self.policy["workspace"] = str(alternate)
            self.write_policy()
            self.restart()
        with self.subTest(phase="Act"):
            retry = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(retry, finished)
            self.assertEqual(len(self.runner.launches()), 1)
            self.assertTrue(self.record_path().exists())

    def test_snapshot_symlink_is_preserved_without_deleting_its_target(self):
        with self.subTest(phase="Arrange"):
            self.broker.handle(self.request)
            finished = self.finish(self.request)
            target = self.root / ("preserve_" + uuid.uuid4().hex)
            target.write_text("host user file")
            self.snapshot_path().unlink()
            self.snapshot_path().symlink_to(target)
            next_request = self.next_request()
        with self.subTest(phase="Act"):
            with mock.patch.object(control, "MAX_RECORDS", 1):
                positive = self.broker.handle(next_request)
            retry = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(target.read_text(), "host user file")
            self.assertTrue(self.snapshot_path().is_symlink())
            self.assertEqual(retry, finished)
            self.assertEqual(positive["stage"], "adopted")
            self.assertTrue(self.archive_path(self.request).exists())

    def test_archive_gc_does_not_stop_unit_that_is_currently_running(self):
        with self.subTest(phase="Arrange"):
            self.broker.handle(self.request)
            finished = self.finish(self.request)
            self.runner.units[finished["unit"]] = self.runner.properties(finished["unit"])
            next_request = self.next_request()
        with self.subTest(phase="Act"):
            with mock.patch.object(control, "MAX_RECORDS", 1):
                positive = self.broker.handle(next_request)
        with self.subTest(phase="Assert"):
            self.assertTrue(self.archive_path(self.request).exists())
            self.assertEqual(positive["stage"], "adopted")
            self.assertEqual(self.runner.stops(), [])
            self.assertIn(finished["unit"], self.runner.units)


class CapabilityTests(BrokerFixture):
    def test_each_action_denies_cross_profile_access_before_record_lookup(self):
        with self.subTest(phase="Arrange"):
            foreign_request, _token_path = self.additional_profile()
            own = self.broker.handle(self.request)
            foreign = self.broker.handle(foreign_request)
            initial_calls = len(self.runner.calls)
        with self.subTest(phase="Act"):
            with mock.patch.object(self.broker, "_load", side_effect=RuntimeError("unauthorized lookup")):
                for action in ("launch", "status", "cancel"):
                    denied = dict(foreign_request, action=action, capability=self.capability)
                    self.assert_error("access_denied", self.broker.handle, denied)
                    self.assert_error("access_denied", self.broker.handle,
                                      dict(denied, profile="unknown"))
            final_calls = len(self.runner.calls)
            own_status = self.broker.handle(self.status_request())
            foreign_status = self.broker.handle(dict(foreign_request, action="status"))
        with self.subTest(phase="Assert"):
            self.assertEqual(final_calls, initial_calls)
            self.assertEqual(own_status, own)
            self.assertEqual(foreign_status, foreign)
            self.assertEqual(self.runner.stops(), [])
            self.assertEqual(len(self.runner.launches()), 2)

    def test_bad_missing_and_malformed_capabilities_have_no_effect(self):
        with self.subTest(phase="Arrange"):
            values = ("0" * 64, "F" * 64, "short", "../token", None, [], {}, 123)
            missing = {key: value for key, value in self.request.items() if key != "capability"}
        with self.subTest(phase="Act"):
            for value in values:
                self.assert_error("access_denied", self.broker.handle, dict(self.request, capability=value))
            self.assert_error("invalid_request_schema", self.broker.handle, missing)
            positive = self.broker.handle(self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(positive["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_token_is_never_in_snapshots_ledger_responses_or_errors(self):
        with self.subTest(phase="Arrange"):
            rejected = dict(self.request, capability="0" * 64)
        with self.subTest(phase="Act"):
            result = self.broker.handle(self.request)
            with self.assertRaises(control.BrokerError) as caught:
                self.broker.handle(rejected)
            files = list(self.spool_dir.rglob("*.json"))
        with self.subTest(phase="Assert"):
            self.assertNotIn(self.capability, json.dumps(result))
            self.assertNotIn(self.capability, str(caught.exception))
            self.assertNotIn("capability", result)
            self.assertGreaterEqual(len(files), 2)
            for path in files:
                data = path.read_text(encoding="utf-8")
                self.assertNotIn(self.capability, data)
                self.assertNotIn('"capability"', data)

    def test_missing_malformed_and_readable_host_tokens_fail_startup(self):
        with self.subTest(phase="Arrange"):
            self.broker.close()
            self.token_path.unlink()
        with self.subTest(phase="Act"):
            self.assert_error("missing_profile_capability", self.new_broker)
            self.token_path.write_text("invalid")
            self.token_path.chmod(0o600)
            self.assert_error("invalid_capability_file", self.new_broker)
            self.token_path.write_text(self.capability + "\n")
            self.assert_error("invalid_capability_file", self.new_broker)
            self.token_path.write_text(self.capability)
            self.token_path.chmod(0o644)
            self.assert_error("unsafe_permissions", self.new_broker)
            self.token_path.chmod(0o600)
            positive = self.new_broker()
        with self.subTest(phase="Assert"):
            self.assertEqual(self.runner.calls, [])
            self.assertIsInstance(positive, control.Broker)

    def test_token_symlinks_hardlinks_and_nonprivate_registry_parent_fail(self):
        with self.subTest(phase="Arrange"):
            self.broker.close()
            target = self.root / "capability-copy"
            target.write_bytes(self.token_path.read_bytes())
            target.chmod(0o600)
            self.token_path.unlink()
        with self.subTest(phase="Act"):
            self.token_path.symlink_to(target)
            self.assert_error("unsafe_file", self.new_broker)
            self.token_path.unlink()
            os.link(target, self.token_path)
            self.assert_error("unsafe_file", self.new_broker)
            self.token_path.unlink()
            self.token_path.write_text(self.capability)
            self.token_path.chmod(0o600)
            self.policy_dir.chmod(0o755)
            self.assert_error("unsafe_permissions", self.new_broker)
        with self.subTest(phase="Assert"):
            self.assertEqual(self.runner.calls, [])


class SocketIntegrationTests(BrokerFixture):
    def start_server(self):
        socket_path = self.socket_dir / "broker.sock"
        stop = threading.Event()
        ready = threading.Event()
        failures = []
        def serve():
            try:
                self.broker.serve(socket_path, stop_event=stop, ready_event=ready)
            except BaseException as error:
                failures.append(error)
                ready.set()
        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        def cleanup():
            stop.set()
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive(), "server did not stop")
            if failures:
                raise failures[0]
        self.addCleanup(cleanup)
        self.assertTrue(ready.wait(timeout=5), "server did not become ready")
        if failures:
            raise failures[0]
        return socket_path

    def raw_request(self, path, data):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(str(path))
            connection.sendall(data)
            connection.shutdown(socket.SHUT_WR)
            response = []
            while True:
                try:
                    chunk = connection.recv(65536)
                except ConnectionResetError:
                    if response:
                        break
                    raise
                if not chunk:
                    break
                response.append(chunk)
            return json.loads(b"".join(response))

    def test_socket_round_trip_permissions_and_rejected_capability(self):
        with self.subTest(phase="Arrange"):
            path = self.start_server()
        with self.subTest(phase="Act"):
            positive = control.client_request(path, self.request)
            negative = self.raw_request(path, json.dumps(dict(self.request, argv=["sh"])).encode())
            retry = control.client_request(path, self.request)
            cancelled = control.client_request(path, self.status_request("cancel"))
        with self.subTest(phase="Assert"):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(positive, retry)
            self.assertEqual(negative, {"ok": False, "error": "invalid_request_schema"})
            self.assertEqual(cancelled["outcome"], "cancelled")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_socket_size_duplicate_json_and_invalid_utf8_controls(self):
        with self.subTest(phase="Arrange"):
            path = self.start_server()
            original = json.dumps(self.request).encode()
            duplicate = original[:-1] + b',"action":"status"}'
        with self.subTest(phase="Act"):
            duplicate_result = self.raw_request(path, duplicate)
            oversized = self.raw_request(path, b"x" * (control.MAX_REQUEST_BYTES + 1))
            invalid = self.raw_request(path, b"\xff")
            positive = control.client_request(path, self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(duplicate_result["error"], "duplicate_json_key")
            self.assertEqual(oversized["error"], "size_limit")
            self.assertEqual(invalid["error"], "invalid_json")
            self.assertEqual(positive["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_peer_rejection_prevents_launch_but_authorized_request_succeeds(self):
        with self.subTest(phase="Arrange"):
            path = self.start_server()
        with self.subTest(phase="Act"):
            with mock.patch.object(control, "_check_peer", side_effect=control.BrokerError("unauthorized_peer")):
                try:
                    negative = self.raw_request(path, json.dumps(self.request).encode())
                except (BrokenPipeError, ConnectionResetError):
                    negative = {"ok": False, "error": "transport_rejected"}
            rejected_launch_count = len(self.runner.launches())
            positive = control.client_request(path, self.request)
        with self.subTest(phase="Assert"):
            self.assertFalse(negative["ok"])
            self.assertIn(negative["error"], ("unauthorized_peer", "transport_rejected"))
            self.assertEqual(rejected_launch_count, 0)
            self.assertEqual(positive["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_lost_response_retry_uses_one_unit_and_bad_request_has_no_effect(self):
        with self.subTest(phase="Arrange"):
            path = self.start_server()
        with self.subTest(phase="Act"):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as abandoned:
                abandoned.connect(str(path))
                abandoned.sendall(json.dumps(self.request).encode())
                abandoned.shutdown(socket.SHUT_WR)
            retry = control.client_request(path, self.request)
            rejected = self.raw_request(path, json.dumps(dict(self.request, env={})).encode())
            status = control.client_request(path, self.status_request())
        with self.subTest(phase="Assert"):
            self.assertEqual(retry["unit"], control._unit(self.request))
            self.assertEqual(status, retry)
            self.assertEqual(rejected["error"], "invalid_request_schema")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_stale_socket_is_replaced_and_live_socket_is_preserved(self):
        with self.subTest(phase="Arrange"):
            path = self.socket_dir / "broker.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stale:
                stale.bind(str(path))
            path.chmod(0o600)
        with self.subTest(phase="Act"):
            self.start_server()
            positive = control.client_request(path, self.request)
            inode = path.stat().st_ino
            self.assert_error("socket_in_use", self.broker.serve, path)
            retry = control.client_request(path, self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(path.stat().st_ino, inode)
            self.assertEqual(positive, retry)
            self.assertEqual(len(self.runner.launches()), 1)

    def test_socket_in_writable_tree_and_symlink_refused(self):
        with self.subTest(phase="Arrange"):
            target = self.socket_dir / "target"
            target.write_text("preserve me")
            alias = self.socket_dir / "alias.sock"
            alias.symlink_to(target)
        with self.subTest(phase="Act"):
            self.assert_error("overlapping_policy", self.broker.serve, self.workspace / "broker.sock")
            self.assert_error("unsafe_socket", self.broker.serve, alias)
            path = self.start_server()
            positive = control.client_request(path, self.request)
        with self.subTest(phase="Assert"):
            self.assertEqual(target.read_text(), "preserve me")
            self.assertEqual(positive["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_cli_request_uses_same_transport_and_fails_closed(self):
        with self.subTest(phase="Arrange"):
            path = self.start_server()
            argv = ["request", "--socket", str(path), "--action", "launch",
                    "--profile", self.profile, "--kind", "cron", "--task-id", self.task,
                    "--token-file", str(self.token_path), "--attempt-id", self.attempt]
            output = io.StringIO()
        with self.subTest(phase="Act"):
            with contextlib.redirect_stdout(output):
                positive = control.main(argv)
            failure_output = io.StringIO()
            with contextlib.redirect_stdout(failure_output):
                negative = control.main(argv[:-1] + ["../escape"])
        with self.subTest(phase="Assert"):
            self.assertEqual(positive, 0)
            self.assertEqual(negative, 1)
            self.assertEqual(json.loads(output.getvalue())["stage"], "adopted")
            self.assertEqual(json.loads(failure_output.getvalue())["error"], "invalid_token")
            self.assertEqual(len(self.runner.launches()), 1)

    def test_client_discovers_only_selected_token_and_cannot_control_other_profile(self):
        with self.subTest(phase="Arrange"):
            foreign_request, _token_path = self.additional_profile()
            path = self.start_server()
            own_request = {key: value for key, value in self.request.items() if key != "capability"}
            wrong_profile = {key: value for key, value in foreign_request.items() if key != "capability"}
        with self.subTest(phase="Act"):
            with mock.patch.dict(os.environ, {"HERMES_SANDBOX_CONTROL_TOKEN_FILE": str(self.token_path)}):
                positive = control.client_request(path, own_request)
                for action in ("launch", "status", "cancel"):
                    self.assert_error("access_denied", control.client_request, path,
                                      dict(wrong_profile, action=action))
            foreign = control.client_request(path, foreign_request)
        with self.subTest(phase="Assert"):
            self.assertEqual(positive["stage"], "adopted")
            self.assertEqual(foreign["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), 2)
            self.assertEqual(self.runner.stops(), [])
            self.assertNotIn("capability", positive)

    def test_client_without_selected_token_has_no_uid_fallback(self):
        with self.subTest(phase="Arrange"):
            path = self.start_server()
            request = {key: value for key, value in self.request.items() if key != "capability"}
            missing = self.socket_dir / "missing.token"
        with self.subTest(phase="Act"):
            with mock.patch.dict(os.environ, {"HERMES_SANDBOX_CONTROL_TOKEN_FILE": str(missing)}):
                self.assert_error("access_denied", control.client_request, path, request)
            positive = control.client_request(path, request, token_file=self.token_path)
        with self.subTest(phase="Assert"):
            self.assertEqual(positive["stage"], "adopted")
            self.assertEqual(len(self.runner.launches()), 1)


if __name__ == "__main__":
    unittest.main()
