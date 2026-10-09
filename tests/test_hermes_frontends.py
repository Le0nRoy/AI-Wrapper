"""Frontend test plan: private paths, service/session leases, pinned attachment,
configuration merging, cache refresh, and Desktop process lifecycle. Positive
and negative controls use isolated temporary directories and mocked external
processes. Native-source checks execute the pinned MemoryStore and SessionDB
against temporary state, replacing only the unavailable YAML dependency and
MemoryStore's module facade. No Desktop or model process is launched.
"""

import copy
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import socket
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest import mock


SUPPORT = Path(__file__).resolve().parents[1] / "bin/ai_wrapper_data/hermes_sandbox"
UPSTREAM = Path(os.environ.get("HERMES_TEST_UPSTREAM", "/tmp/hermes-upstream-WdPss4"))


def load_module(name):
    specification = importlib.util.spec_from_file_location(name, SUPPORT / f"{name}.py")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


frontends = load_module("frontends")
patches = load_module("frontend_patches")


class FrontendFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hermes-frontends-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.locks = self.directory("locks")
        self.state = self.directory("state")
        self.bridge = self.directory("bridge")
        self.url = "ws://127.0.0.1:9119/api/ws?token=" + "a" * 64

    def directory(self, name):
        path = self.root / name
        path.mkdir(mode=0o700)
        return path

    def bind_socket(self, path=None):
        path = self.bridge / frontends.DISPLAY_SOCKET if path is None else path
        connection = socket.socket(socket.AF_UNIX)
        self.addCleanup(connection.close)
        connection.bind(str(path))
        path.chmod(0o600)
        return connection


class FrontendTests(FrontendFixture):

    def test_service_kinds_concurrent_duplicate_owner_blocked_and_release(self):
        with self.subTest(phase="Arrange"):
            inode = None
        with self.subTest(phase="Act"):
            with frontends.profile_owner(self.locks, "work", "serve", writable_roots=(self.state,)):
                inode = (self.locks / "work.serve.lock").stat().st_ino
                with frontends.profile_owner(self.locks, "work", "gateway"):
                    with self.assertRaises(frontends.FrontendError):
                        with frontends.profile_owner(self.locks, "work", "serve"):
                            self.fail("Duplicate serve owner admitted")
            with frontends.profile_owner(self.locks, "work", "serve"):
                released_inode = (self.locks / "work.serve.lock").stat().st_ino
        with self.subTest(phase="Assert"):
            self.assertEqual(inode, released_inode)
            self.assertEqual(stat.S_IMODE((self.locks / "work.serve.lock").stat().st_mode), 0o600)

    def test_session_owner_conflicts_only_same_conversation(self):
        with self.subTest(phase="Arrange"):
            session = "stored/session title"
        with self.subTest(phase="Act"):
            with frontends.session_owner(self.locks, "work", session, writable_roots=(self.state,)):
                with frontends.session_owner(self.locks, "work", "another session"):
                    with frontends.session_owner(self.locks, "other", session):
                        with self.assertRaises(frontends.FrontendError):
                            with frontends.session_owner(self.locks, "work", session):
                                self.fail("Same session admitted twice")
            with frontends.session_owner(self.locks, "work", session):
                pass
        with self.subTest(phase="Assert"):
            self.assertEqual(len(list(self.locks.glob("*.lock"))), 3)

    def test_owner_exception_releases_without_unlink(self):
        with self.subTest(phase="Act"):
            with self.assertRaisesRegex(RuntimeError, "turn failure"):
                with frontends.profile_owner(self.locks, "work", "gateway"):
                    raise RuntimeError("turn failure")
            with frontends.profile_owner(self.locks, "work", "gateway"):
                record = json.loads((self.locks / "work.gateway.lock").read_text())
        with self.subTest(phase="Assert"):
            self.assertEqual(record["kind"], "gateway")

    def test_owner_unsafe_paths_hardlinks_and_overlap_refused(self):
        with self.subTest(phase="Arrange"):
            alias = self.root / "alias"
            alias.symlink_to(self.locks)
            target = self.locks / "work.serve.lock"
            target.write_text("preserve")
            target.chmod(0o600)
            os.link(target, self.root / "hardlink")
            shared = self.directory("shared")
            shared.chmod(0o755)
        with self.subTest(phase="Act"):
            for directory in (alias, shared, self.state, str(self.locks) + "/../locks"):
                with self.subTest(directory=str(directory)), self.assertRaises(frontends.FrontendError):
                    with frontends.profile_owner(directory, "work", "gateway", writable_roots=(self.state,)):
                        self.fail("Unsafe owner path admitted")
            with self.assertRaises(frontends.FrontendError):
                with frontends.profile_owner(self.locks, "work", "serve"):
                    self.fail("Hardlinked lock admitted")
        with self.subTest(phase="Assert"):
            self.assertEqual(target.read_text(), "preserve")

    def test_attach_environment_rejects_external_or_ambiguous_credentials(self):
        with self.subTest(phase="Act"):
            environment = frontends.attach_environment(self.url)
            for invalid in ("ws://example.com:9119/api/ws?token=secret", self.url + "&token=other",
                            self.url.replace("127.0.0.1", "localhost"), self.url + "#fragment",
                            self.url.replace("127.0.0.1", "127.0.0.2"),
                            self.url.replace("/api/ws", "/api/console"), self.url.replace("ws:", "http:"),
                            "ws://user@127.0.0.1:9119/api/ws?token=secret", "ws://127.0.0.1:9119/api/ws?token="):
                with self.subTest(url=invalid), self.assertRaises(frontends.FrontendError):
                    frontends.attach_environment(invalid)
        with self.subTest(phase="Assert"):
            self.assertEqual(environment["HERMES_TUI_GATEWAY_URL"], self.url)
            self.assertEqual(environment["HERMES_DESKTOP_REMOTE_TOKEN"], "a" * 64)
            self.assertEqual(environment["HERMES_DESKTOP_REMOTE_URL"], "http://127.0.0.1:9119")

    def test_attach_uses_stored_id_then_runtime_id_and_no_fake_endpoints(self):
        with self.subTest(phase="Arrange"):
            rpc = mock.Mock()
            rpc.call.side_effect = [{"session_id": "runtime-42"}, {"session_id": "runtime-42", "messages": []}]
        with self.subTest(phase="Act"):
            result = frontends.attach_session(rpc, "stored-12")
        with self.subTest(phase="Assert"):
            self.assertEqual(result["session_id"], "runtime-42")
            self.assertEqual(rpc.call.call_args_list, [
                mock.call("session.resume", {"session_id": "stored-12", "source": "cli", "close_on_disconnect": False}),
                mock.call("session.activate", {"session_id": "runtime-42"})])

    def test_attach_invalid_resume_or_activation_fails_closed(self):
        with self.subTest(phase="Act"):
            for responses in (({},), ({"session_id": "runtime"}, {"session_id": "other"})):
                rpc = mock.Mock()
                rpc.call.side_effect = responses
                with self.assertRaises(frontends.FrontendError):
                    frontends.attach_session(rpc, "stored")
        with self.subTest(phase="Assert"):
            self.assertLessEqual(rpc.call.call_count, 2)

    def test_actual_rpc_wire_batches_notifications_and_redacts_error_payload(self):
        with self.subTest(phase="Arrange"):
            connection = mock.Mock()
            connection.recv.side_effect = [
                '{"jsonrpc":"2.0","method":"gateway.ready","params":{}}\n' +
                '{"jsonrpc":"2.0","id":1,"result":{"session_id":"runtime"}}\n',
                '{"jsonrpc":"2.0","id":2,"error":{"message":"SECRET"}}\n']
            connect = mock.Mock(return_value=connection)
        with self.subTest(phase="Act"):
            with frontends.BackendRPC(self.url, connect=connect) as rpc:
                result = rpc.call("session.resume", {"session_id": "stored"})
                with self.assertRaises(frontends.FrontendError) as failed:
                    rpc.call("session.activate", {"session_id": "runtime"})
        with self.subTest(phase="Assert"):
            self.assertEqual(result["session_id"], "runtime")
            request = json.loads(connection.send.call_args_list[0].args[0])
            self.assertEqual(request["method"], "session.resume")
            self.assertTrue(connection.send.call_args_list[0].args[0].endswith("\n"))
            self.assertNotIn("SECRET", str(failed.exception))
            connection.close.assert_called_once()

    def test_backend_readiness_uses_authenticated_rpc_and_waits_only_until_ready(self):
        with self.subTest(phase="Arrange"):
            probe = mock.Mock(side_effect=[OSError("connection refused"), {"ok": True}])
            cancelled = mock.Mock()
            cancelled.is_set.return_value = False
        with self.subTest(phase="Act"):
            frontends.wait_backend_ready(self.url, probe=probe, cancelled=cancelled)
            cancelled.is_set.return_value = True
            with self.assertRaises(frontends.FrontendError):
                frontends.wait_backend_ready(self.url, probe=probe, cancelled=cancelled)
        with self.subTest(phase="Assert"):
            self.assertEqual(probe.call_count, 2)
            cancelled.wait.assert_called_once()

    def test_backend_readiness_does_not_accept_public_health_or_false_auth(self):
        with self.subTest(phase="Arrange"):
            connection = mock.Mock()
            connection.recv.return_value = '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}'
        with self.subTest(phase="Act"):
            with mock.patch.object(frontends, "BackendRPC") as rpc:
                rpc.return_value.__enter__.return_value.call.return_value = {"ok": True}
                frontends.wait_backend_ready(self.url)
            with self.assertRaises(frontends.FrontendError):
                frontends.wait_backend_ready(self.url, probe=lambda: {"status": "healthy"}, timeout=0.001)
        with self.subTest(phase="Assert"):
            rpc.return_value.__enter__.return_value.call.assert_called_once_with("gateway.ping", {})

    def test_token_layout_and_protected_connection_manifest(self):
        with self.subTest(phase="Act"):
            identity = frontends.create_backend_token(self.locks)
            host_token = Path(identity["host_directory"]) / Path(identity["token_file"]).name
            manifest = self.locks / "connection.json"
            manifest.write_text(json.dumps({"version": 1, "websocket_url": self.url}))
            manifest.chmod(0o600)
            connection = frontends.read_backend_connection(manifest)
            command = frontends.serve_argv("/runtime/.venv/bin/python", identity["token_file"], identity["owner_nonce"])
            manifest.chmod(0o644)
            with self.assertRaises(frontends.FrontendError):
                frontends.read_backend_connection(manifest)
        with self.subTest(phase="Assert"):
            self.assertEqual(host_token.read_text(), identity["token"])
            self.assertEqual(len(identity["token"]), 64)
            self.assertEqual(stat.S_IMODE(host_token.stat().st_mode), 0o600)
            self.assertIn("--ssh-session-token-file", command)
            self.assertEqual(connection, self.url)

    def test_desktop_commands_have_private_display_and_disable_host_bridges(self):
        with self.subTest(phase="Act"):
            server = frontends.desktop_server_argv("/runtime with space/python")
            client = frontends.desktop_client_argv(self.bridge)
            environment = frontends.desktop_environment(self.url, {
                "DISPLAY": ":0", "WAYLAND_DISPLAY": "wayland-0", "DBUS_SESSION_BUS_ADDRESS": "unix:/run/user/bus",
                "HERMES_HOME": str(self.state), "HERMES_DESKTOP_USER_DATA_DIR": "/host/desktop-config",
                "SSH_AUTH_SOCK": "/host/agent.sock", "NODE_OPTIONS": "--require /host/evil.js"})
        with self.subTest(phase="Assert"):
            self.assertEqual(server[:3], ["xpra", "start", ":100"])
            self.assertIn("--bind=/run/hermes-desktop/xpra.sock", server)
            self.assertIn("--xvfb=Xvfb -screen 0 1920x1080x24 -nolisten tcp -nolisten local -noreset -auth $XAUTHORITY", server)
            self.assertFalse(any(option.startswith("--bind-") for option in server))
            self.assertIn("desktop --skip-build", server[-1])
            for option in frontends.BRIDGE_OPTIONS:
                self.assertIn(option, server)
                self.assertIn(option, client)
            self.assertEqual(environment["DISPLAY"], ":100")
            self.assertEqual(environment["HERMES_DESKTOP_USER_DATA_DIR"], str(self.state / "desktop-user-data"))
            self.assertFalse({"WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "SSH_AUTH_SOCK", "NODE_OPTIONS"} & environment.keys())
            self.assertEqual(client[2], f"socket://{self.bridge}/xpra.sock")

    def test_desktop_client_waits_on_ready_socket_and_detects_dead_owner(self):
        with self.subTest(phase="Arrange"):
            self.bind_socket()
            run = mock.Mock(return_value=types.SimpleNamespace(returncode=0))
            process = mock.Mock()
            process.poll.return_value = None
        with self.subTest(phase="Act"):
            positive = frontends.run_desktop_client(self.bridge, process, run=run)
            process.poll.return_value = 1
            with self.assertRaises(frontends.FrontendError):
                frontends.run_desktop_client(self.bridge, process, run=run)
        with self.subTest(phase="Assert"):
            self.assertEqual(positive, 0)
            run.assert_called_once()

    def test_desktop_client_refuses_loose_socket_symlink_and_timeout(self):
        with self.subTest(phase="Arrange"):
            self.bind_socket()
            path = self.bridge / "xpra.sock"
            path.chmod(0o666)
            run = mock.Mock()
        with self.subTest(phase="Act"):
            with self.assertRaises(frontends.FrontendError):
                frontends.run_desktop_client(self.bridge, run=run)
            empty = self.directory("empty")
            with self.assertRaises(frontends.FrontendError):
                frontends.run_desktop_client(empty, run=run, timeout=0.001)
            (empty / "xpra.sock").symlink_to(path)
            with self.assertRaises(frontends.FrontendError):
                frontends.run_desktop_client(empty, run=run)
        with self.subTest(phase="Assert"):
            run.assert_not_called()

    def test_desktop_server_missing_dependencies_and_existing_socket_fail_closed(self):
        with self.subTest(phase="Arrange"):
            popen = mock.Mock()
        with self.subTest(phase="Act"):
            with mock.patch.object(frontends, "desktop_dependencies", return_value=["xpra", "Xvfb"]):
                with self.assertRaisesRegex(frontends.FrontendError, "setup dependencies"):
                    frontends.run_desktop_server("python", self.url, popen=popen)
            self.bind_socket()
            with mock.patch.object(frontends, "desktop_dependencies", return_value=[]), \
                    mock.patch.object(frontends, "DISPLAY_DIRECTORY", self.bridge):
                with self.assertRaisesRegex(frontends.FrontendError, "fresh private"):
                    frontends.run_desktop_server("python", self.url, popen=popen)
        with self.subTest(phase="Assert"):
            popen.assert_not_called()

    def test_process_cleanup_is_condition_based_and_escalates_timeout(self):
        with self.subTest(phase="Arrange"):
            process = mock.Mock(pid=123)
            process.poll.return_value = None
            process.wait.side_effect = [subprocess.TimeoutExpired("xpra", 5), 0]
        with self.subTest(phase="Act"):
            with mock.patch.object(frontends.os, "killpg") as kill:
                frontends._stop_process(process)
                process.poll.return_value = 0
                frontends._stop_process(process)
        with self.subTest(phase="Assert"):
            self.assertEqual(kill.call_count, 2)
            self.assertEqual(process.wait.call_count, 2)

    def test_desktop_bundle_requires_compiled_protected_route_gates(self):
        with self.subTest(phase="Arrange"):
            runtime = self.directory("runtime")
            package = runtime / "apps/desktop/release/linux-unpacked"
            (package / "resources").mkdir(parents=True)
            executable = package / "hermes"
            executable.write_text("prepared executable")
            archive = package / "resources/app.asar"
            archive.write_bytes(b"unpatched stock bundle")
        with self.subTest(phase="Act"):
            with self.assertRaisesRegex(frontends.FrontendError, "compatibility gates"):
                frontends.verify_desktop_bundle(runtime)
            archive.write_bytes(b"HERMES_SANDBOX_DESKTOP_ATTACH_ONLY\n"
                                b"Sandbox Desktop cannot spawn a second Hermes backend.\n"
                                b"Sandbox Desktop requires its protected authenticated backend.\n"
                                b"Sandbox Desktop lost its protected backend connection.\n")
            result = frontends.verify_desktop_bundle(runtime)
        with self.subTest(phase="Assert"):
            self.assertEqual(result, executable)

    def test_cli_builder_forces_attach_capable_tui(self):
        with self.subTest(phase="Act"):
            command = frontends.cli_argv("/runtime/python", "stored-session")
            with self.assertRaises(frontends.FrontendError):
                frontends.cli_argv("python", "--cli")
        with self.subTest(phase="Assert"):
            self.assertEqual(command[-3:], ["--tui", "--resume", "stored-session"])


class StateAdapterTests(FrontendFixture):
    def fake_modules(self):
        path = self.state / "config.json"
        path.write_text('{"model":"initial","display":{"theme":"dark"}}')
        config = types.ModuleType("hermes_cli.config")
        config._CONFIG_LOCK = threading.RLock()

        def load_config():
            with config._CONFIG_LOCK:
                return json.loads(path.read_text())

        def save_config(content, **kwargs):
            with config._CONFIG_LOCK:
                path.write_text(json.dumps(content))

        def atomic_config_replace(target, data, **kwargs):
            with config._CONFIG_LOCK:
                Path(target).write_text(json.dumps(data))

        config.load_config = load_config
        config.read_raw_config = load_config
        config.read_user_config_raw = load_config
        config.save_config = save_config
        config.atomic_config_write = atomic_config_replace
        config.atomic_config_replace = atomic_config_replace
        skills = types.ModuleType("tools.skills_tool")
        skills.clear_skills_cache = mock.Mock()
        skills._skill_catalog = mock.Mock(return_value=[{"name": "latest"}])
        manager = types.ModuleType("tools.skill_manager_tool")
        manager.skill_manage = mock.Mock(return_value='{"success":true}')
        manager._skill_mutation_lock = mock.Mock()
        manager._skill_mutation_locks = mock.Mock()
        memory = types.SimpleNamespace(MemoryStore=types.SimpleNamespace(_mutate=mock.Mock()))
        auth = types.SimpleNamespace(_provider_state_transaction=mock.Mock())
        leases = types.SimpleNamespace(admit_durable_turn_lease=mock.Mock())
        prompts = types.SimpleNamespace(build_skills_system_prompt=mock.Mock(return_value="latest index"),
                                        clear_skills_system_prompt_cache=mock.Mock(),
                                        get_skills_dir=lambda: self.state / "skills",
                                        get_skill_search_roots=lambda root: [(1, root)],
                                        _build_skills_manifest=mock.Mock(return_value={"learned/SKILL.md": [1, 2, 3, 4]}))
        system = types.SimpleNamespace(build_system_prompt=mock.Mock(return_value="current learning"),
                                       invalidate_system_prompt=mock.Mock())
        conversation = types.SimpleNamespace(_stored_prompt_matches_runtime=mock.Mock(return_value=True))
        modules = {"hermes_cli.config": config, "tools.skills_tool": skills,
                   "tools.skill_manager_tool": manager, "tools.memory_tool_store": memory,
                   "hermes_cli.auth": auth, "agent.turn_facade_lease": leases,
                   "agent.prompt_builder": prompts, "agent.system_prompt": system,
                   "agent.conversation_loop": conversation}
        return modules, config, skills, manager

    def test_config_two_stale_snapshots_preserve_disjoint_changes_reject_conflict(self):
        with self.subTest(phase="Arrange"):
            modules, config, skills, manager = self.fake_modules()
            original = config.save_config
        with self.subTest(phase="Act"):
            with mock.patch.object(patches.importlib, "import_module", side_effect=modules.__getitem__):
                with patches.FrontendPatches(self.state):
                    first = config.load_config()
                    second = config.load_config().copy()
                    conflict = config.load_config()
                    first["model"] = "updated"
                    second["display"]["theme"] = "light"
                    conflict["model"] = "conflicting"
                    config.save_config(first)
                    config.save_config(second)
                    with self.assertRaisesRegex(patches.StateConflict, "model"):
                        config.save_config(conflict)
                    result = config.load_config()
        with self.subTest(phase="Assert"):
            self.assertEqual(dict(result), {"model": "updated", "display": {"theme": "light"}})
            self.assertIs(config.save_config, original)

    def test_config_delete_merge_and_same_add_conflict(self):
        with self.subTest(phase="Act"):
            result = patches.merge_config({"old": 1, "stay": 2}, {"stay": 2}, {"old": 1, "stay": 3})
            with self.assertRaises(patches.StateConflict):
                patches.merge_config({}, {"new": 1}, {"new": 2})
        with self.subTest(phase="Assert"):
            self.assertEqual(result, {"stay": 3})

    def test_skill_catalog_invalidates_worker_cache_and_mutation_failure_releases(self):
        with self.subTest(phase="Arrange"):
            modules, config, skills, manager = self.fake_modules()
            manager.skill_manage.side_effect = RuntimeError("mutation failed")
        with self.subTest(phase="Act"):
            with mock.patch.object(patches.importlib, "import_module", side_effect=modules.__getitem__):
                with patches.FrontendPatches(self.state):
                    result = skills._skill_catalog()
                    with self.assertRaises(RuntimeError):
                        manager.skill_manage("patch", "learned")
                    second = skills._skill_catalog()
                    with patches.transaction(self.state, "skills"):
                        pass
        with self.subTest(phase="Assert"):
            self.assertEqual(result, second)
            self.assertEqual(skills.clear_skills_cache.call_count, 3)

    def test_failed_install_restores_replacements(self):
        with self.subTest(phase="Arrange"):
            modules, config, skills, manager = self.fake_modules()
            original_lock = config._CONFIG_LOCK
            del config.atomic_config_replace
        with self.subTest(phase="Act"):
            with mock.patch.object(patches.importlib, "import_module", side_effect=modules.__getitem__):
                with self.assertRaises(AttributeError):
                    patches.install(self.state)
        with self.subTest(phase="Assert"):
            self.assertIs(config._CONFIG_LOCK, original_lock)

    def test_skill_prompt_cache_invalidates_only_when_manifest_changes(self):
        with self.subTest(phase="Arrange"):
            modules, config, skills, manager = self.fake_modules()
            prompts = modules["agent.prompt_builder"]
        with self.subTest(phase="Act"):
            with mock.patch.object(patches.importlib, "import_module", side_effect=modules.__getitem__):
                with patches.FrontendPatches(self.state):
                    first = prompts.build_skills_system_prompt()
                    second = prompts.build_skills_system_prompt()
                    unchanged_count = prompts.clear_skills_system_prompt_cache.call_count
                    prompts._build_skills_manifest.return_value = {"new/SKILL.md": [5, 6, 7, 8]}
                    third = prompts.build_skills_system_prompt()
        with self.subTest(phase="Assert"):
            self.assertEqual((first, second, third), ("latest index",) * 3)
            self.assertEqual(unchanged_count, 1)
            self.assertEqual(prompts.clear_skills_system_prompt_cache.call_count, 2)

    def test_config_separate_processes_preserve_changes_from_stale_snapshots(self):
        with self.subTest(phase="Arrange"):
            modules, config, skills, manager = self.fake_modules()
            context = multiprocessing.get_context("fork")
            workers = []

            def worker(channel, field, value):
                try:
                    snapshot = config.load_config()
                    channel.send("loaded")
                    channel.recv()
                    snapshot[field] = value
                    config.save_config(snapshot)
                    channel.send("saved")
                finally:
                    channel.close()

        with self.subTest(phase="Act"):
            with mock.patch.object(patches.importlib, "import_module", side_effect=modules.__getitem__):
                with patches.FrontendPatches(self.state):
                    try:
                        for field, value in (("model", "new model"), ("added", "gateway value")):
                            parent, child = context.Pipe()
                            self.addCleanup(parent.close)
                            process = context.Process(target=worker, args=(child, field, value))
                            process.start()
                            child.close()
                            workers.append((process, parent))
                        for process, channel in workers:
                            self.assertTrue(channel.poll(5))
                            self.assertEqual(channel.recv(), "loaded")
                        for process, channel in workers:
                            channel.send("write")
                        for process, channel in workers:
                            self.assertTrue(channel.poll(5))
                            self.assertEqual(channel.recv(), "saved")
                            process.join(timeout=5)
                            self.assertEqual(process.exitcode, 0)
                        result = config.load_config()
                    finally:
                        for process, channel in workers:
                            if process.is_alive():
                                process.terminate()
                            process.join(timeout=5)
        with self.subTest(phase="Assert"):
            self.assertEqual(result["model"], "new model")
            self.assertEqual(result["added"], "gateway value")
            self.assertEqual(result["display"]["theme"], "dark")

    def test_transaction_reentrant_release_and_symlink_lock_refusal(self):
        with self.subTest(phase="Act"):
            with self.assertRaises(RuntimeError):
                with patches.transaction(self.state):
                    with patches.transaction(self.state):
                        raise RuntimeError("failed")
            with patches.transaction(self.state):
                pass
            target = self.root / "target"
            target.write_text("untouched")
            (self.state / ".frontend-skills.lock").symlink_to(target)
            with self.assertRaises(OSError):
                with patches.transaction(self.state, "skills"):
                    self.fail("Symlink lock admitted")
        with self.subTest(phase="Assert"):
            self.assertEqual(target.read_text(), "untouched")


NATIVE_SETUP = """
import sys, types, os, json
from pathlib import Path
sys.path.insert(0, sys.argv[1])
sys.modules['hermes_yaml'] = types.ModuleType('hermes_yaml')
os.environ['HERMES_HOME'] = sys.argv[2]
os.environ['HOME'] = sys.argv[2]
"""


class NativeStateTests(FrontendFixture):
    def native_run(self, source):
        if not (UPSTREAM / "tools/memory_tool_store.py").is_file():
            self.skipTest("Set HERMES_TEST_UPSTREAM to the pinned official checkout for native state checks")
        revision = subprocess.run(["git", "-C", str(UPSTREAM), "rev-parse", "HEAD"],
                                  capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(revision, frontends.PINNED_REVISION)
        result = subprocess.run([sys.executable, "-B", "-c", NATIVE_SETUP + source,
                                 str(UPSTREAM), str(self.state)],
                                capture_output=True, text=True, timeout=30,
                                env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return json.loads(result.stdout.strip().splitlines()[-1])

    def test_pinned_desktop_overlays_gate_profile_overrides_and_validate_typescript(self):
        with self.subTest(phase="Arrange"):
            if not UPSTREAM.is_dir():
                self.skipTest("Pinned official checkout unavailable")
            sources = {name: (UPSTREAM / name).read_text() for name in patches.DESKTOP_SOURCE_DIGESTS}
        with self.subTest(phase="Act"):
            overlays = patches.desktop_source_patches(sources)
            with self.assertRaises(patches.StateConflict):
                patches.desktop_source_patches(dict(sources, **{"apps/desktop/electron/main.ts": "changed"}))
        with self.subTest(phase="Assert"):
            route = overlays["apps/desktop/electron/desktop-remote-route.ts"]
            gate = route.index("process.env.HERMES_SANDBOX_DESKTOP_ATTACH_ONLY")
            self.assertLess(gate, route.index("const profileKey = connectionScopeKey(profile)"))
            self.assertIn("cannot spawn a second Hermes backend", overlays["apps/desktop/electron/main.ts"])
            self.assertNotIn("HERMES_SANDBOX_DESKTOP_ATTACH_ONLY", sources["apps/desktop/electron/main.ts"])
            self.assertIsNotNone(shutil.which("node"), "Native Desktop routing check requires Node.js")
            if shutil.which("node"):
                script = """
const fs = require('fs');
const assert = require('assert');
const {stripTypeScriptTypes} = require('node:module');
const overlays = JSON.parse(fs.readFileSync(0, 'utf8'));
if (stripTypeScriptTypes) {
  for (const source of Object.values(overlays)) stripTypeScriptTypes(source);
}
process.env.HERMES_SANDBOX_DESKTOP_ATTACH_ONLY = '1';
const input = {config: {profiles: {work: {mode: 'ssh', host: 'other'}}}, profile: 'work',
  registry: {connections: []}, env: {url: 'http://127.0.0.1:9119', token: 'private'}};
for (const strip of [undefined, stripTypeScriptTypes].filter((value, index) => !index || value)) {
  const source = overlays['apps/desktop/electron/desktop-remote-route.ts'];
  let select;
  if (strip) {
    const route = strip(source).replace(/^import[\\s\\S]*?from ['"][^'"]+['"];?$/gm, '').replace(/^export /gm, '');
    select = new Function(route + '\\nreturn resolveDesktopRemoteRoute;')();
  } else {
    const start = source.indexOf("  if (process.env.HERMES_SANDBOX_DESKTOP_ATTACH_ONLY");
    const end = source.indexOf('  const profileKey = connectionScopeKey(profile)', start);
    assert.ok(start > 0 && end > start);
    select = new Function('{config, env = {}, profile, registry}', source.slice(start, end));
  }
  assert.equal(select(input).source, 'env');
  assert.equal(select(input).url, input.env.url);
  assert.throws(() => select({...input, env: {...input.env, token: ''}}));
  assert.throws(() => select({...input, env: {...input.env, url: 'http://evil.test:9119'}}));
}
"""
                process = subprocess.run(["node", "-e", script], input=json.dumps(overlays),
                                         capture_output=True, text=True, timeout=20)
                self.assertEqual(process.returncode, 0, process.stderr)

    def test_native_skill_patch_writers_keep_disjoint_changes_and_refuse_stale_patch(self):
        with self.subTest(phase="Act"):
            result = self.native_run("""
import multiprocessing
skill = Path(sys.argv[2]) / 'skills/learned'
(skill / 'references').mkdir(parents=True)
(skill / 'SKILL.md').write_text('---\\nname: learned\\ndescription: Use for testing.\\n---\\nUse references.\\n')
note = skill / 'references/note.md'
note.write_text('first=old\\nsecond=old\\n')
from tools import skill_manager_tool as manager
manager._skill_gate_bypass.set(True)
context = multiprocessing.get_context('fork')
parent, child = context.Pipe()
def writer(channel):
    assert note.read_text() == 'first=old\\nsecond=old\\n'
    channel.send('loaded')
    channel.recv()
    result = manager.skill_manage('patch', 'learned', file_path='references/note.md',
                                  old_string='second=old', new_string='second=new')
    assert json.loads(result)['success'], result
    channel.send('saved')
process = context.Process(target=writer, args=(child,))
process.start()
child.close()
try:
    assert parent.poll(5) and parent.recv() == 'loaded'
    result = manager.skill_manage('patch', 'learned', file_path='references/note.md',
                                  old_string='first=old', new_string='first=new')
    assert json.loads(result)['success'], result
    parent.send('write')
    assert parent.poll(5) and parent.recv() == 'saved'
    stale = manager.skill_manage('patch', 'learned', file_path='references/note.md',
                                 old_string='first=old', new_string='lost stale change')
    assert not json.loads(stale)['success']
    process.join(5)
    assert process.exitcode == 0
finally:
    if process.is_alive():
        process.terminate()
    process.join(5)
    parent.close()
print(json.dumps(note.read_text()))
""")
        with self.subTest(phase="Assert"):
            self.assertEqual(result, "first=new\nsecond=new\n")

    def test_native_independent_memory_writer_processes_preserve_latest_changes(self):
        with self.subTest(phase="Act"):
            result = self.native_run("""
import fcntl, multiprocessing
facade = types.ModuleType('tools.memory_tool')
facade.fcntl = fcntl
facade.msvcrt = None
facade.get_memory_dir = lambda: Path(sys.argv[2]) / 'memories'
sys.modules['tools.memory_tool'] = facade
from tools.memory_tool_store import MemoryStore
first = MemoryStore()
first.load_from_disk()
context = multiprocessing.get_context('fork')
parent, child = context.Pipe()
def writer(channel):
    second = MemoryStore()
    second.load_from_disk()
    channel.send('loaded')
    channel.recv()
    assert second.add('memory', 'User prefers keyboard navigation')['success']
    channel.send('saved')
    channel.recv()
    assert not second.replace('memory', 'dark theme', 'Lost stale change')['success']
    channel.send('stale refused')
process = context.Process(target=writer, args=(child,))
process.start()
child.close()
try:
    assert parent.poll(5) and parent.recv() == 'loaded'
    assert first.add('memory', 'User prefers dark theme')['success']
    parent.send('write')
    assert parent.poll(5) and parent.recv() == 'saved'
    assert first.replace('memory', 'dark theme', 'User prefers light theme')['success']
    parent.send('replace stale')
    assert parent.poll(5) and parent.recv() == 'stale refused'
    process.join(5)
    assert process.exitcode == 0
finally:
    if process.is_alive():
        process.terminate()
    process.join(5)
    parent.close()
latest = MemoryStore()
latest.load_from_disk()
print(json.dumps(latest._entries_for('memory')))
""")
        with self.subTest(phase="Assert"):
            self.assertEqual(result, ["User prefers light theme", "User prefers keyboard navigation"])

    def test_native_sqlite_session_lease_foreign_pidns_heartbeat_and_history(self):
        with self.subTest(phase="Act"):
            result = self.native_run("""
import subprocess
from hermes_state import SessionDB
from hermes_state_pidns import holder_pid_checkable
database = Path(sys.argv[2]) / 'state.db'
first, second = SessionDB(database), SessionDB(database)
first.create_session('shared', 'cli')
foreign = 'pid=999999:pidns=999999999:turn=desktop'
assert not holder_pid_checkable(foreign)
assert first.try_acquire_session_turn_lease('shared', foreign, ttl_seconds=60)
assert first.refresh_session_turn_lease('shared', foreign, ttl_seconds=60)
child_source = '''
import sys, types, os, json
from pathlib import Path
sys.path.insert(0, sys.argv[1])
sys.modules['hermes_yaml'] = types.ModuleType('hermes_yaml')
os.environ['HERMES_HOME'] = sys.argv[2]
from hermes_state import SessionDB
db = SessionDB(Path(sys.argv[2]) / 'state.db')
assert not db.try_acquire_session_turn_lease('shared', 'pid=999998:pidns=888888888:turn=gateway', ttl_seconds=60)
assert db.try_acquire_session_turn_lease('other-session', 'independent', ttl_seconds=60)
db.release_session_turn_lease('other-session', 'independent')
db.close()
'''
subprocess.run([sys.executable, '-B', '-c', child_source, sys.argv[1], sys.argv[2]], check=True, timeout=10)
assert first.refresh_session_turn_lease('shared', foreign, ttl_seconds=60)
assert not second.try_acquire_session_turn_lease('shared', 'pid=1:pidns=888888888:turn=gateway', ttl_seconds=60)
second.release_session_turn_lease('shared', 'wrong-owner')
assert not second.try_acquire_session_turn_lease('shared', 'other', ttl_seconds=60)
first.append_message('shared', 'user', 'Persisted from CLI')
first.release_session_turn_lease('shared', foreign)
assert second.try_acquire_session_turn_lease('shared', 'gateway', ttl_seconds=60)
rows = second.get_messages('shared')
second.release_session_turn_lease('shared', 'gateway')
first.close()
second.close()
print(json.dumps([row['content'] for row in rows]))
""")
        with self.subTest(phase="Assert"):
            self.assertEqual(result, ["Persisted from CLI"])

    def test_native_immediate_turn_admission_refreshes_inactive_frontend_history(self):
        with self.subTest(phase="Act"):
            result = self.native_run("""
import threading, importlib.util
from hermes_state import SessionDB
from agent.turn_facade_lease import admit_durable_turn_lease
from agent.session_persistence import _PERSIST_AFTER_ADMISSION_INTERRUPT
spec = importlib.util.spec_from_file_location('compat_patches', %r)
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)
database = SessionDB(Path(sys.argv[2]) / 'state.db')
database.create_session('shared', 'desktop')
database.append_message('shared', 'user', 'Latest gateway message')
agent = types.SimpleNamespace(_session_db=database, session_id='shared', _persist_disabled=False,
                             _session_db_created=True, _interrupt_requested=False,
                             _emit_status=lambda *args: None,
                             _liveness_activity_lock=lambda: threading.RLock())
context = {'session_id': 'shared', 'platform': 'desktop'}
carried = {'role': 'user', 'content': 'Pending interrupted input', _PERSIST_AFTER_ADMISSION_INTERRUPT: True}
stale = [{'role': 'user', 'content': 'Stale desktop history'}, carried]
admit = compat.refresh_admitted_history(admit_durable_turn_lease)
admission = admit(agent, session_id='shared', relay_turn_id='new', task_context=context, conversation_history=stale)
assert admission.lease is not None
try:
    contents = [message['content'] for message in admission.conversation_history]
    assert contents == ['Latest gateway message', 'Pending interrupted input'], contents
finally:
    admission.lease.release()
original_reader = database.get_messages_as_conversation
def failed_read(*args, **kwargs):
    raise OSError('history read failed')
database.get_messages_as_conversation = failed_read
try:
    admit(agent, session_id='shared', relay_turn_id='fail', task_context=context, conversation_history=stale)
    raise AssertionError('Expected failed reload')
except OSError:
    pass
database.get_messages_as_conversation = original_reader
assert database.try_acquire_session_turn_lease('shared', 'successor', ttl_seconds=60)
database.release_session_turn_lease('shared', 'successor')
database.close()
print(json.dumps(contents))
""" % str(SUPPORT / "frontend_patches.py"))
        with self.subTest(phase="Assert"):
            self.assertEqual(result, ["Latest gateway message", "Pending interrupted input"])

    def test_native_auth_refresh_transaction_rereads_rotated_token_and_preserves_siblings(self):
        with self.subTest(phase="Act"):
            result = self.native_run("""
import multiprocessing
from hermes_cli import auth
auth._save_auth_store({'version': 1, 'providers': {
    'nous': {'tokens': {'access_token': 'old-access', 'refresh_token': 'old-refresh'}},
    'sibling': {'value': 'preserved'}}})
context = multiprocessing.get_context('fork')
parent, child = context.Pipe()
def refresher(channel):
    stale = auth._load_auth_store()
    assert stale['providers']['nous']['tokens']['refresh_token'] == 'old-refresh'
    channel.send('loaded')
    channel.recv()
    with auth._provider_state_transaction('nous') as (store, state, source):
        assert state['tokens']['refresh_token'] == 'rotated-refresh'
        state['tokens']['access_token'] = 'latest-access'
        auth._store_provider_state(store, 'nous', state)
        auth._save_auth_store(store, target_path=source)
    channel.send('saved')
process = context.Process(target=refresher, args=(child,))
process.start()
child.close()
try:
    assert parent.poll(5) and parent.recv() == 'loaded'
    with auth._provider_state_transaction('nous') as (store, state, source):
        state['tokens']['refresh_token'] = 'rotated-refresh'
        auth._store_provider_state(store, 'nous', state)
        auth._save_auth_store(store, target_path=source)
    parent.send('refresh')
    assert parent.poll(5) and parent.recv() == 'saved'
    process.join(5)
    assert process.exitcode == 0
finally:
    if process.is_alive():
        process.terminate()
    process.join(5)
    parent.close()
try:
    with auth._provider_state_transaction('nous'):
        raise RuntimeError('provider refresh failure')
except RuntimeError:
    pass
with auth._provider_state_transaction('nous'):
    latest = auth._load_auth_store()
assert latest['providers']['sibling']['value'] == 'preserved'
print(json.dumps(latest['providers']['nous']['tokens']))
""")
        with self.subTest(phase="Assert"):
            self.assertEqual(result, {"access_token": "latest-access", "refresh_token": "rotated-refresh"})

    def test_native_shared_learning_refreshes_idle_prompt_only_after_actual_mutation(self):
        with self.subTest(phase="Act"):
            result = self.native_run("""
import fcntl, importlib.util, multiprocessing
facade = types.ModuleType('tools.memory_tool')
facade.fcntl, facade.msvcrt = fcntl, None
facade.get_memory_dir = lambda: Path(sys.argv[2]) / 'memories'
sys.modules['tools.memory_tool'] = facade
from tools.memory_tool_store import MemoryStore
from agent import prompt_builder, system_prompt
spec = importlib.util.spec_from_file_location('compat_patches', %r)
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)
store = MemoryStore()
store.load_from_disk()
assert store.add('memory', 'User prefers dark theme')['success']
skill = Path(sys.argv[2]) / 'skills/learned'
skill.mkdir(parents=True)
(skill / 'SKILL.md').write_text('Use for testing. Version one.')
agent = types.SimpleNamespace(_memory_store=store, _cached_system_prompt=None, _cached_system_prompt_static=None)
learning = compat.LearningRevision(Path(sys.argv[2]), prompt_builder, system_prompt)
build = learning.builder(lambda agent: agent._memory_store.format_for_system_prompt('memory'))
matches = learning.runtime_matcher(lambda *args: True)
agent._cached_system_prompt = build(agent)
before = agent._cached_system_prompt
learning.refresh(agent)
assert agent._cached_system_prompt == before
def writer():
    other = MemoryStore()
    other.load_from_disk()
    assert other.replace('memory', 'dark theme', 'User prefers light theme')['success']
process = multiprocessing.get_context('fork').Process(target=writer)
process.start()
process.join(5)
assert process.exitcode == 0
learning.refresh(agent)
assert agent._cached_system_prompt is None
assert not matches(agent, before)
agent._cached_system_prompt = build(agent)
current = agent._cached_system_prompt
assert 'User prefers light theme' in current
assert matches(agent, current)
learning.refresh(agent)
assert agent._cached_system_prompt == current
(skill / 'SKILL.md').write_text('Use for testing. Version two, added learning.')
learning.refresh(agent)
assert agent._cached_system_prompt is None
assert not matches(agent, current)
agent._cached_system_prompt = build(agent)
learning.refresh(agent)
assert agent._cached_system_prompt is not None
print(json.dumps('memory and skills refreshed, stable turns retained'))
""" % str(SUPPORT / "frontend_patches.py"))
        with self.subTest(phase="Assert"):
            self.assertEqual(result, "memory and skills refreshed, stable turns retained")

    def test_native_hooks_install_and_restore_actual_pinned_protocols(self):
        with self.subTest(phase="Act"):
            result = self.native_run("""
import importlib.util
from agent import system_prompt, conversation_loop, turn_facade_lease
from hermes_cli import config
spec = importlib.util.spec_from_file_location('compat_patches', %r)
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)
before = (config._CONFIG_LOCK, config.save_config, system_prompt.build_system_prompt,
          conversation_loop._stored_prompt_matches_runtime, turn_facade_lease.admit_durable_turn_lease)
hooks = compat.install(Path(sys.argv[2]))
try:
    installed = (config._CONFIG_LOCK, config.save_config, system_prompt.build_system_prompt,
                 conversation_loop._stored_prompt_matches_runtime, turn_facade_lease.admit_durable_turn_lease)
    assert all(original is not wrapped for original, wrapped in zip(before, installed))
finally:
    hooks.uninstall()
after = (config._CONFIG_LOCK, config.save_config, system_prompt.build_system_prompt,
         conversation_loop._stored_prompt_matches_runtime, turn_facade_lease.admit_durable_turn_lease)
assert all(original is restored for original, restored in zip(before, after))
print(json.dumps('native hooks restored'))
""" % str(SUPPORT / "frontend_patches.py"))
        with self.subTest(phase="Assert"):
            self.assertEqual(result, "native hooks restored")


if __name__ == "__main__":
    unittest.main()
