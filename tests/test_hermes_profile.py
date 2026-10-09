import base64
import contextlib
import hashlib
import importlib.util
import json
import os
import io
from pathlib import Path
import stat
import socket
import signal
import sys
import tempfile
import types
import threading
import unittest
from unittest import mock
import uuid
import venv


MODULE_DIR = Path(__file__).resolve().parents[1] / "bin/ai_wrapper_data/hermes_sandbox"
sys.path.insert(0, str(MODULE_DIR))
spec = importlib.util.spec_from_file_location("hermes_profile", MODULE_DIR / "profile.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix=f"hermes-profile-{uuid.uuid4()}-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home"
        self.home.mkdir(mode=0o700)
        environment = mock.patch.dict(os.environ, {"HOME": str(self.home)}, clear=False)
        environment.start()
        self.addCleanup(environment.stop)
        self.runtime = self.home / "runtime"
        self.state = self.home / "state"
        self.workspace = self.home / "workspace"
        for directory in (self.runtime, self.state, self.workspace):
            directory.mkdir(mode=0o700)
        venv.EnvBuilder(with_pip=False).create(self.runtime / ".venv")
        self.registry = profile.profiles_directory()
        self.registry.parent.mkdir(parents=True, mode=0o700)
        self.registry.mkdir(mode=0o700)
        self.value = {"version": 1, "runtime": str(self.runtime),
                      "state": str(self.state), "workspace": str(self.workspace)}
        self.path = self.registry / "default.json"
        self.write_registry(self.value)

    def write_registry(self, value, path=None):
        destination = path or self.path
        destination.write_text(json.dumps(value), encoding="utf-8")
        destination.chmod(0o600)

    def test_load_valid_private_registry(self):
        result = profile.load_profile("default")
        self.assertEqual(result, self.value)
        self.assertEqual(self.path.read_text(), json.dumps(self.value))

    def test_fixed_control_paths_ignore_inherited_xdg(self):
        with mock.patch.dict(os.environ, {"XDG_STATE_HOME": "/wrong", "XDG_CONFIG_HOME": "/wrong"}):
            self.assertEqual(profile.control_directory(), self.home / ".local/share/hermes-sandbox/control/spool")
            self.assertEqual(profile.profiles_directory(), self.registry)

    def test_names_reject_traversal_uppercase_and_options(self):
        for name in ("../default", "a/b", "UPPER", "--default", "", "a" * 65):
            with self.subTest(name=name), self.assertRaises(profile.ProfileError):
                profile.load_profile(name)
        self.assertEqual(profile.validate_name("private-2_test"), "private-2_test")

    def test_exact_schema_and_integer_version(self):
        for value in (dict(self.value, extra=True), dict(self.value, version=True),
                      dict(self.value, version=2), {"version": 1}):
            self.write_registry(value)
            with self.subTest(value=value), self.assertRaises(profile.ProfileError):
                profile.load_profile("default")

    def test_duplicate_json_keys_and_oversized_registry(self):
        for contents in ('{"version":1,"version":1}', " " * (profile.MAX_PROFILE_BYTES + 1)):
            self.path.write_text(contents)
            with self.subTest(size=len(contents)), self.assertRaises(profile.ProfileError):
                profile.load_profile("default")

    def test_registry_permissions_and_symlink_rejected(self):
        self.path.chmod(0o644)
        with self.assertRaises(profile.ProfileError):
            profile.load_profile("default")
        self.path.chmod(0o600)
        moved = self.registry / ".profile-original"
        self.path.rename(moved)
        self.path.symlink_to(moved)
        with self.assertRaises(profile.ProfileError):
            profile.load_profile("default")

    def test_registry_hardlink_rejected(self):
        os.link(self.path, self.root / "linked-policy")
        with self.assertRaises(profile.ProfileError):
            profile.load_profile("default")

    def test_registry_parent_permissions_rejected(self):
        self.registry.parent.chmod(0o755)
        with self.assertRaises(profile.ProfileError):
            profile.load_profile("default")

    def test_state_permissions_rejected(self):
        self.state.chmod(0o755)
        with self.assertRaises(profile.ProfileError):
            profile.load_profile("default")

    def test_noncanonical_relative_and_control_paths_rejected(self):
        for path in ("workspace", str(self.workspace) + "/", str(self.workspace) + "/../workspace",
                     str(self.workspace) + "\n"):
            self.write_registry(dict(self.value, workspace=path))
            with self.subTest(path=path), self.assertRaises(profile.ProfileError):
                profile.load_profile("default")

    def test_home_system_and_dotfile_workspaces_rejected(self):
        hidden = self.home / ".project"
        hidden.mkdir()
        for path in (self.home, Path("/"), Path("/usr"), hidden):
            self.write_registry(dict(self.value, workspace=str(path)))
            with self.subTest(path=path), self.assertRaises(profile.ProfileError):
                profile.load_profile("default")

    def test_credentials_rejected_for_all_mount_roles(self):
        credential = self.home / ".ssh"
        credential.mkdir(mode=0o700)
        for role in ("runtime", "state", "workspace"):
            with self.subTest(role=role), self.assertRaises(profile.ProfileError):
                profile.validate_profile(dict(self.value, **{role: str(credential)}))

    def test_symlinked_mounts_and_ancestors_rejected(self):
        alias = self.home / "alias"
        alias.symlink_to(self.workspace, target_is_directory=True)
        for path in (alias, alias / "nested"):
            with self.subTest(path=path), self.assertRaises(profile.ProfileError):
                profile.validate_profile(dict(self.value, workspace=str(path)))

    def test_overlapping_profile_mounts_rejected(self):
        for role, path in (("workspace", self.runtime), ("state", self.workspace),
                           ("workspace", self.home)):
            with self.subTest(role=role), self.assertRaises(profile.ProfileError):
                profile.validate_profile(dict(self.value, **{role: str(path)}))

    def test_policy_ancestor_and_descendant_rejected(self):
        for role in ("runtime", "state", "workspace"):
            for path in (self.registry.parent, self.registry, self.registry.parent.parent):
                with self.subTest(role=role, path=path), self.assertRaises(profile.ProfileError):
                    profile.validate_profile(dict(self.value, **{role: str(path)}))

    def test_control_root_and_ancestor_rejected(self):
        spool = profile.control_directory()
        spool.mkdir(mode=0o700, parents=True)
        for path in (spool, spool.parent, spool.parent.parent):
            with self.subTest(path=path), self.assertRaises(profile.ProfileError):
                profile.validate_profile(dict(self.value, state=str(path)))

    def test_launcher_and_support_ancestor_rejected(self):
        for path in (profile.launcher_directory(), profile.support_directory(),
                     profile.launcher_directory().parent):
            with self.subTest(path=path), self.assertRaises(profile.ProfileError):
                profile.validate_profile(dict(self.value, workspace=str(path)))

    def test_another_profiles_state_is_not_mountable(self):
        other_workspace = self.home / "other-workspace"
        other_workspace.mkdir(mode=0o700)
        other_state = self.home / "other-state"
        other_state.mkdir(mode=0o700)
        other = dict(self.value, state=str(other_state), workspace=str(other_workspace))
        self.write_registry(other, self.registry / "other.json")
        self.assertEqual(profile.load_profile("default"), self.value)
        self.write_registry(dict(self.value, workspace=str(other_state)))
        with self.assertRaises(profile.ProfileError):
            profile.load_profile("default")

    def test_missing_venv_and_external_interpreter_rejected(self):
        configuration = self.runtime / ".venv/pyvenv.cfg"
        configuration.unlink()
        with self.assertRaises(profile.ProfileError):
            profile.load_profile("default")
        configuration.write_text("home = /usr/bin\n")
        python = self.runtime / ".venv/bin/python"
        python.unlink()
        external = self.home / "external-python"
        external.write_text("untrusted")
        external.chmod(0o700)
        python.symlink_to(external)
        with self.assertRaises(profile.ProfileError):
            profile.load_profile("default")

    def test_init_creates_private_state_and_policy_without_overwrite(self):
        self.path.unlink()
        state = self.home / "fresh-state"
        result = profile.register_profile("default", str(self.runtime), str(state), str(self.workspace))
        self.assertEqual(result["state"], str(state))
        self.assertEqual(stat.S_IMODE(state.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        token = self.registry / "default.token"
        self.assertEqual(stat.S_IMODE(token.stat().st_mode), 0o600)
        self.assertEqual(len(token.read_bytes()), 64)
        self.assertEqual(profile.control_token("default", required=True), token)
        for directory in (profile.control_directory().parent, profile.control_directory()):
            self.assertTrue(directory.is_dir())
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        original = self.path.read_bytes()
        with self.assertRaises(profile.ProfileError):
            profile.register_profile("default", str(self.runtime), str(state), str(self.workspace))
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(list(self.registry.glob(".profile-*")), [])

    def test_init_refuses_unsafe_existing_control_permissions_without_chmod(self):
        self.path.unlink()
        parent = profile.control_directory().parent
        parent.mkdir(parents=True, mode=0o755)
        state = self.home / "fresh-state"
        with self.assertRaises(profile.ProfileError):
            profile.register_profile("default", str(self.runtime), str(state), str(self.workspace))
        self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o755)
        self.assertFalse(profile.control_directory().exists())
        self.assertFalse(self.path.exists())
        self.assertFalse((self.registry / "default.token").exists())
        self.assertFalse(state.exists())

    def test_init_refuses_symlinked_control_spool(self):
        self.path.unlink()
        parent = profile.control_directory().parent
        parent.mkdir(parents=True, mode=0o700)
        profile.control_directory().symlink_to(self.workspace, target_is_directory=True)
        state = self.home / "fresh-state"
        with self.assertRaises(profile.ProfileError):
            profile.register_profile("default", str(self.runtime), str(state), str(self.workspace))
        self.assertTrue(profile.control_directory().is_symlink())
        self.assertFalse(self.path.exists())
        self.assertFalse((self.registry / "default.token").exists())
        self.assertFalse(state.exists())

    def test_control_capability_is_exclusive_and_not_returned(self):
        token = profile.create_control_token("default")
        original = token.read_bytes()
        with self.assertRaises(FileExistsError):
            profile.create_control_token("default")
        self.assertTrue(token.read_bytes() == original)
        self.assertEqual(profile.control_token("default"), token)
        self.assertNotIn("capability", profile.load_profile("default"))

    def test_missing_capability_is_optional_for_cli_and_required_for_workers(self):
        self.assertIsNone(profile.control_token("default"))
        with self.assertRaises(profile.ProfileError):
            profile.control_token("default", required=True)

    def test_capability_content_permissions_and_symlinks_rejected(self):
        token = profile.create_control_token("default")
        token.chmod(0o644)
        with self.assertRaises(profile.ProfileError):
            profile.control_token("default")
        token.chmod(0o600)
        token.write_text("invalid")
        with self.assertRaises(profile.ProfileError):
            profile.control_token("default")
        token.unlink()
        token.symlink_to(self.path)
        with self.assertRaises(profile.ProfileError):
            profile.control_token("default")

    def test_invalid_init_does_not_create_state_or_policy(self):
        self.path.unlink()
        unsafe_state = self.workspace / "should-not-exist"
        with self.assertRaises(profile.ProfileError):
            profile.register_profile("default", str(self.runtime), str(unsafe_state), str(self.workspace))
        self.assertFalse(unsafe_state.exists())
        self.assertFalse(self.path.exists())

    def test_doctor_reports_profile_and_missing_broker_without_credentials(self):
        support = self.root / "install/bin/ai_wrapper_data/hermes_sandbox"
        support.mkdir(parents=True)
        (support / "adapter.py").write_text("pass\n")
        (support / "frontends.py").write_text("pass\n")
        with mock.patch.object(profile, "support_directory", return_value=support), \
                mock.patch.object(profile.shutil, "which", return_value="/usr/bin/bwrap"), \
                mock.patch.object(profile, "control_socket", return_value=None):
            result = profile.doctor("default")
        self.assertEqual(result["profile"], "default")
        self.assertFalse(result["control_socket"])
        self.assertEqual(result["revision"], profile.PINNED_REVISION)

    def test_doctor_fails_when_bubblewrap_is_missing(self):
        with mock.patch.object(profile.shutil, "which", return_value=None), self.assertRaises(profile.ProfileError):
            profile.doctor("default")

    def make_snapshot(self):
        directory = profile.control_directory() / "snapshots/default/cron"
        directory.mkdir(mode=0o700, parents=True)
        for path in (directory, directory.parent, directory.parent.parent, profile.control_directory()):
            path.chmod(0o700)
        value = {"kind": "cron", "profile": "default", "task_id": "task-1",
                 "attempt_id": "attempt-1", "payload": {"prompt": "fixed job"}}
        path = directory / "attempt-1.json"
        path.write_text(json.dumps(value))
        path.chmod(0o400)
        return path, value

    def test_worker_reads_real_protected_broker_snapshot(self):
        path, value = self.make_snapshot()
        result = profile.worker_snapshot("default", "cron", "attempt-1")
        self.assertEqual(result, path)
        self.assertEqual(json.loads(path.read_text()), value)

    def test_worker_identity_mismatch_is_refused(self):
        path, value = self.make_snapshot()
        value["profile"] = "other"
        path.chmod(0o600)
        path.write_text(json.dumps(value))
        path.chmod(0o400)
        with self.assertRaises(ValueError):
            profile.worker_snapshot("default", "cron", "attempt-1")

    def test_worker_invalid_kind_and_attempt_never_read_files(self):
        for kind, attempt in (("shell", "id"), ("cron", "../id"), ("kanban", "id..other")):
            with self.subTest(kind=kind, attempt=attempt), self.assertRaises(profile.ProfileError):
                profile.worker_snapshot("default", kind, attempt)

    def test_worker_allows_broker_dotted_ids_and_rejects_oversize(self):
        self.assertIsNotNone(profile.IDENTIFIER_PATTERN.fullmatch("a.b-c_1"))
        self.assertIsNone(profile.IDENTIFIER_PATTERN.fullmatch("a" * 129))

    def test_execute_leases_kind_and_clears_host_environment(self):
        owner = mock.Mock(return_value=contextlib.nullcontext())
        frontend = types.SimpleNamespace(profile_owner=owner)
        with mock.patch.dict(sys.modules, {"frontends": frontend}), \
                mock.patch.object(profile.subprocess, "call", return_value=17) as launch:
            result = profile.execute("default", "gateway", ["/usr/bin/bwrap", "fixed"])
        self.assertEqual(result, 17)
        launched = launch.call_args.args[0]
        self.assertIn("--property=MemoryMax=6G", launched)
        self.assertEqual(launched[-2:], ["/usr/bin/bwrap", "fixed"])
        self.assertEqual(launch.call_args.kwargs["env"]["PATH"], "/usr/bin:/bin")
        self.assertNotIn("OPENAI_API_KEY", launch.call_args.kwargs["env"])
        owner.assert_called_once_with(profile.control_directory().parent / "locks", "default", "gateway",
                                      writable_roots=(str(self.state), str(self.workspace)))

    def test_execute_rejects_unknown_lease_kind(self):
        with self.assertRaises(profile.ProfileError):
            profile.execute("default", "all", ["/usr/bin/bwrap"])

    def test_private_desktop_bridge_cannot_select_workspace(self):
        parent = profile.private_control_directory("displays") / "default"
        parent.mkdir(mode=0o700)
        bridge = parent / "session-test"
        bridge.mkdir(mode=0o700)
        self.assertEqual(profile.desktop_bridge("default", str(bridge)), bridge)
        with self.assertRaises(profile.ProfileError):
            profile.desktop_bridge("default", str(self.workspace))

    def test_desktop_cleans_server_and_bridge_on_client_failure(self):
        frontend = types.SimpleNamespace(
            profile_owner=mock.Mock(return_value=contextlib.nullcontext()),
            run_desktop_client=mock.Mock(side_effect=ValueError("client failed")),
        )
        server = mock.Mock()
        server.poll.return_value = None
        with mock.patch.dict(sys.modules, {"frontends": frontend}), \
                mock.patch.object(profile.subprocess, "Popen", return_value=server) as launch, \
                mock.patch.object(profile, "connection_manifest", return_value=self.root / "known-connection.json"), \
                mock.patch.object(profile, "wait_backend", return_value=None) as readiness, \
                self.assertRaises(ValueError):
            profile.desktop("default", [])
        server.terminate.assert_called_once()
        server.wait.assert_called_once_with(timeout=10)
        self.assertEqual(list((profile.control_directory().parent / "displays/default").iterdir()), [])
        self.assertNotIn("OPENAI_API_KEY", launch.call_args.kwargs["env"])
        self.assertEqual(launch.call_args.args[0][4], "_desktop_server")
        readiness.assert_called_once_with(self.root / "known-connection.json", None)
        frontend.profile_owner.assert_called_once_with(
            profile.control_directory().parent / "locks", "default", "desktop",
            writable_roots=(str(self.state), str(self.workspace)))

    def test_desktop_backend_readiness_failure_cleans_without_display_launch(self):
        backend = mock.Mock()
        backend.poll.return_value = None
        with mock.patch.object(profile.subprocess, "Popen", return_value=backend) as launch, \
                mock.patch.object(profile, "wait_backend", side_effect=profile.ProfileError("Not ready")), \
                self.assertRaises(profile.ProfileError):
            profile.desktop("default", [])
        self.assertEqual(launch.call_count, 1)
        self.assertEqual(launch.call_args.args[0][4], "_serve_server")
        backend.terminate.assert_called_once()
        backend.wait.assert_called_once_with(timeout=10)
        self.assertFalse((profile.control_directory().parent / "connections/default.json").exists())
        self.assertEqual(list((profile.control_directory().parent / "backends/default").iterdir()), [])
        self.assertEqual(list((profile.control_directory().parent / "displays/default").iterdir()), [])

    def test_desktop_interruption_cleans_owned_backend_and_display(self):
        import frontends

        backend = mock.Mock()
        display = mock.Mock()
        for process in (backend, display):
            process.poll.return_value = None
        with mock.patch.object(profile.subprocess, "Popen", side_effect=(backend, display)), \
                mock.patch.object(profile, "wait_backend", return_value=None), \
                mock.patch.object(frontends, "run_desktop_client",
                                  side_effect=profile.ProcessInterrupted(signal.SIGTERM)), \
                self.assertRaises(profile.ProcessInterrupted):
            profile.desktop("default", [])
        for process in (backend, display):
            process.terminate.assert_called_once()
            process.wait.assert_called_once_with(timeout=10)
        self.assertFalse((profile.control_directory().parent / "connections/default.json").exists())
        self.assertEqual(list((profile.control_directory().parent / "backends/default").iterdir()), [])
        self.assertEqual(list((profile.control_directory().parent / "displays/default").iterdir()), [])

    def test_separate_cli_sessions_do_not_take_profile_lease(self):
        owner = mock.Mock()
        frontend = types.SimpleNamespace(profile_owner=owner)
        with mock.patch.dict(sys.modules, {"frontends": frontend}), \
                mock.patch.object(profile.subprocess, "call", return_value=0):
            self.assertEqual(profile.execute("default", "cli", ["/usr/bin/bwrap"]), 0)
        owner.assert_not_called()

    def test_control_socket_requires_private_owned_socket(self):
        directory = self.home / "socket-parent"
        directory.mkdir(mode=0o700)
        path = directory / "control.sock"
        connection = socket.socket(socket.AF_UNIX)
        self.addCleanup(connection.close)
        connection.bind(str(path))
        path.chmod(0o600)
        real_path = Path
        expected = f"/run/user/{os.getuid()}/hermes-sandbox/control.sock"
        with mock.patch.object(profile, "Path", side_effect=lambda value: path if value == expected else real_path(value)):
            self.assertEqual(profile.control_socket(required=True), path)
            path.chmod(0o666)
            with self.assertRaises(profile.ProfileError):
                profile.control_socket()

    def test_serve_accepts_unit_loopback_host_and_cleans_authentication(self):
        with mock.patch.object(profile.subprocess, "call", return_value=0) as launch:
            result = profile.serve("default", ["--host", "127.0.0.1", "--port", "9123"])
        self.assertEqual(result, 0)
        command = launch.call_args.args[0]
        self.assertIn("_serve_server", command)
        self.assertIn("--ssh-session-token-file", command)
        self.assertIn("--ssh-owner-nonce", command)
        self.assertEqual(command[command.index("--host") + 1], "127.0.0.1")
        self.assertFalse((profile.control_directory().parent / "connections/default.json").exists())
        self.assertEqual(list((profile.control_directory().parent / "backends/default").iterdir()), [])

    def test_serve_refuses_public_network_override(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            profile.serve("default", ["--host", "0.0.0.0"])
        self.assertFalse((profile.control_directory().parent / "backends").exists())

    def test_cgroup_manager_missing_has_no_execution_fallback(self):
        with mock.patch.object(profile.shutil, "which", return_value=None), \
                mock.patch.object(profile.subprocess, "call") as launch, \
                self.assertRaises(profile.ProfileError):
            profile.execute("default", "cli", ["/usr/bin/bwrap"])
        launch.assert_not_called()

    def test_interrupted_scope_stops_exact_unit_before_releasing_gateway_lease(self):
        events = []

        @contextlib.contextmanager
        def owner(*args, **kwargs):
            events.append("acquire")
            try:
                yield
            finally:
                events.append("release")

        def stopped(command, **kwargs):
            events.append("stop")
            launched = launch.call_args.args[0]
            scope = next(argument.split("=", 1)[1] for argument in launched if argument.startswith("--unit="))
            self.assertEqual(command[-2:], ["stop", scope])
            self.assertRegex(scope, r"^hermes-default-gateway-[0-9a-f]{32}\.scope$")
            self.assertEqual(kwargs["timeout"], 15)
            self.assertEqual(kwargs["env"], launch.call_args.kwargs["env"])
            return types.SimpleNamespace(returncode=0)

        frontend = types.SimpleNamespace(profile_owner=owner)
        with mock.patch.dict(sys.modules, {"frontends": frontend}), \
                mock.patch.object(profile.subprocess, "call", side_effect=profile.ProcessInterrupted(signal.SIGTERM)) as launch, \
                mock.patch.object(profile.subprocess, "run", side_effect=stopped), \
                self.assertRaises(profile.ProcessInterrupted):
            profile.execute("default", "gateway", ["/usr/bin/bwrap"])
        self.assertEqual(events, ["acquire", "stop", "release"])

    def test_scope_cleanup_failure_preserves_original_interruption(self):
        with mock.patch.object(profile.subprocess, "call", side_effect=profile.ProcessInterrupted(signal.SIGTERM)), \
                mock.patch.object(profile.subprocess, "run", side_effect=OSError("user manager unavailable")), \
                contextlib.redirect_stderr(io.StringIO()) as errors, \
                self.assertRaises(profile.ProcessInterrupted):
            profile.execute("default", "cli", ["/usr/bin/bwrap"])
        self.assertIn("Could not confirm shutdown", errors.getvalue())

    def test_interruption_returns_signal_exit_status(self):
        with mock.patch.object(profile, "execute", side_effect=profile.ProcessInterrupted(signal.SIGTERM)):
            result = profile.main(["execute", "--kind", "cli", "--", "/usr/bin/bwrap"])
        self.assertEqual(result, 143)

    def readiness_fixture(self, accepted):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        self.addCleanup(listener.close)
        port = listener.getsockname()[1]
        manifest = self.home / "connection.json"
        manifest.write_text(json.dumps({"version": 1, "websocket_url": f"ws://127.0.0.1:{port}/api/ws?token=test-token"}))
        manifest.chmod(0o600)

        def respond():
            try:
                connection, address = listener.accept()
                with connection:
                    request = b""
                    while b"\r\n\r\n" not in request:
                        request += connection.recv(4096)
                    key = next(line.split(b":", 1)[1].strip() for line in request.split(b"\r\n")
                               if line.lower().startswith(b"sec-websocket-key:"))
                    if accepted:
                        response = base64.b64encode(hashlib.sha1(key + profile.WEBSOCKET_GUID.encode()).digest())
                        connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: " + response + b"\r\n\r\n")
                    else:
                        connection.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
            finally:
                listener.close()

        worker = threading.Thread(target=respond, daemon=True)
        worker.start()
        self.addCleanup(lambda: worker.join(timeout=2))
        return manifest

    def test_authenticated_backend_readiness_requires_websocket_upgrade(self):
        manifest = self.readiness_fixture(True)
        process = mock.Mock()
        process.poll.return_value = None
        self.assertIsNone(profile.wait_backend(manifest, process, timeout=2))

    def test_backend_authentication_rejection_times_out_without_attachment(self):
        manifest = self.readiness_fixture(False)
        with self.assertRaises(profile.ProfileError):
            profile.wait_backend(manifest, timeout=0.2)


if __name__ == "__main__":
    unittest.main()
