import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import types
import unittest
from unittest import mock


SUPPORT = Path(__file__).resolve().parents[1] / "bin/ai_wrapper_data/hermes_sandbox"
SPECIFICATION = importlib.util.spec_from_file_location("hermes_bootstrap_adapter_test", SUPPORT / "adapter.py")
adapter = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(adapter)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="hermes-bootstrap-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.runtime = root / "runtime"
        self.state = root / "state"
        self.workspace = root / "workspace"
        for directory in (self.runtime, self.state, self.workspace):
            directory.mkdir(mode=0o700)
        interpreter = self.runtime / ".venv/bin/python"
        interpreter.parent.mkdir(parents=True)
        interpreter.symlink_to(sys.executable)
        self.environment = {
            "HERMES_SANDBOX_RUNTIME": str(self.runtime),
            "HERMES_HOME": str(self.state),
            "HERMES_SANDBOX_WORKSPACE": str(self.workspace),
            "HERMES_SANDBOX_PROFILE": "work",
        }
        self.state_hooks = object()
        self.installed = types.SimpleNamespace(_originals=[])
        self.url = "ws://127.0.0.1:9119/api/ws?token=" + "a" * 64
        self.frontends = types.SimpleNamespace(
            read_backend_connection=mock.Mock(return_value=self.url),
            attach_environment=mock.Mock(return_value={"HERMES_TUI_GATEWAY_URL": self.url}),
        )
        self.profiles = types.SimpleNamespace(
            resolve_profile_env=mock.Mock(), normalize_profile_name=lambda value: value,
        )
        for name in ("_get_default_hermes_home", "get_profile_dir", "profile_exists", "get_active_profile",
                     "get_active_profile_name", "list_profiles", "profiles_to_serve", "_profile_info"):
            setattr(self.profiles, name, mock.Mock())
        self.modules = {
            "hermes_bootstrap": types.SimpleNamespace(),
            "hermes_cli.profiles": self.profiles,
            "hermes_constants": types.SimpleNamespace(get_default_hermes_root=mock.Mock()),
            "frontend_patches": types.SimpleNamespace(install=mock.Mock(return_value=self.state_hooks)),
            "control": types.SimpleNamespace(client_request=mock.Mock()),
            "frontends": self.frontends,
        }

    def upstream_import(self, name):
        if name == "hermes_bootstrap":
            os.environ["PYTHONPATH"] = str(self.runtime / ".venv/lib/site-packages")
        return self.modules[name]

    def bootstrap(self, environment=None):
        with mock.patch.dict(os.environ, environment or self.environment, clear=True), \
                mock.patch.object(sys, "path", list(sys.path)), \
                mock.patch.object(adapter, "_ACTIVE_ADAPTER", None), \
                mock.patch.object(adapter, "validate_runtime", return_value=self.runtime), \
                mock.patch.object(adapter, "_apply_runtime_environment"), \
                mock.patch.object(adapter.importlib, "import_module", side_effect=self.upstream_import), \
                mock.patch.object(adapter, "install_policy"), \
                mock.patch.object(adapter, "install", return_value=self.installed), \
                mock.patch.object(adapter, "_register_broker_tools"):
            result = adapter.bootstrap()
            return result, dict(os.environ)

    def test_bootstrap_restores_protected_child_hooks_and_retains_state_hooks(self):
        with self.subTest(phase="Act"):
            installed, environment = self.bootstrap()
        with self.subTest(phase="Assert"):
            paths = environment["PYTHONPATH"].split(os.pathsep)
            self.assertEqual(paths[:3], [str(SUPPORT / "patches"), str(SUPPORT), str(self.runtime)])
            self.assertIn(str(self.runtime / ".venv/lib/site-packages"), paths)
            self.assertIs(installed.state_hooks, self.state_hooks)
            self.assertEqual(self.profiles.resolve_profile_env("work"), str(self.state))
            self.assertEqual(self.profiles.resolve_profile_env("default"), str(self.state))
            with self.assertRaises(ValueError):
                self.profiles.resolve_profile_env("foreign")

    def test_backend_manifest_is_read_from_fixed_mount_and_propagated(self):
        environment = dict(self.environment, HERMES_SANDBOX_BACKEND_MANIFEST="/run/hermes/backend.json")
        with self.subTest(phase="Act"):
            installed, resulting = self.bootstrap(environment)
        with self.subTest(phase="Assert"):
            self.assertIs(installed, self.installed)
            self.frontends.read_backend_connection.assert_called_once_with("/run/hermes/backend.json")
            self.frontends.attach_environment.assert_called_once_with(self.url)
            self.assertEqual(resulting["HERMES_TUI_GATEWAY_URL"], self.url)

    def test_arbitrary_backend_manifest_is_refused_before_reading(self):
        environment = dict(self.environment, HERMES_SANDBOX_BACKEND_MANIFEST=str(self.workspace / "fake.json"))
        with self.subTest(phase="Act"), self.assertRaises(ValueError):
            self.bootstrap(environment)
        with self.subTest(phase="Assert"):
            self.frontends.read_backend_connection.assert_not_called()

    def test_no_backend_manifest_keeps_independent_cli(self):
        with self.subTest(phase="Act"):
            installed, environment = self.bootstrap()
        with self.subTest(phase="Assert"):
            self.assertIs(installed, self.installed)
            self.assertNotIn("HERMES_TUI_GATEWAY_URL", environment)
            self.frontends.attach_environment.assert_not_called()

    def test_known_child_refuses_bootstrap_failure_and_other_scripts_are_untouched(self):
        with mock.patch.object(sys, "orig_argv", ["python", "-m", "hermes_cli.main"]), \
                mock.patch.object(adapter, "bootstrap", side_effect=ValueError("pin mismatch")) as launch:
            with self.assertRaises(SystemExit):
                adapter.bootstrap_child()
            launch.assert_called_once()
        with mock.patch.object(sys, "orig_argv", ["python", "example.py"]), \
                mock.patch.object(sys, "argv", ["example.py"]), \
                mock.patch.object(adapter, "bootstrap") as launch:
            adapter.bootstrap_child()
            launch.assert_not_called()

    def test_excluded_commands_are_rejected_before_any_upstream_import(self):
        for command in ("mcp", "computer-use"):
            with self.subTest(command=command), mock.patch.object(adapter, "bootstrap") as launch:
                with self.assertRaises(ValueError):
                    adapter.main(["cli", "--", "--model", "test", command])
                launch.assert_not_called()

    def prepared_manifest(self):
        seed = self.runtime / ".provision/store"
        browser = seed / "browser"
        browser.mkdir(parents=True, mode=0o700)
        (browser / "runner").write_text("pinned browser fixture")
        (self.runtime / ".provision/install-stamp.json").write_text("{}")
        original = self.workspace / "original-state/tools"
        manifest = {
            "version": 1, "revision": adapter.UPSTREAM_COMMIT,
            "pm_seed": {"source": str(seed), "destination": str(original), "copy_required": True},
            "environment": {
                "HERMES_RUNTIME_DIR": str(original),
                "HERMES_INSTALL_ROOT": str(self.runtime / ".provision"),
                "PLAYWRIGHT_BROWSERS_PATH": str(original / "browser"),
                "AGENT_BROWSER_EXECUTABLE_PATH": str(original / "browser/runner"),
            },
        }
        path = self.runtime / "hermes-provision.json"
        path.write_text(json.dumps(manifest))
        return path, manifest, seed

    def test_prepared_store_is_seeded_once_and_remapped_to_selected_profile(self):
        path, manifest, seed = self.prepared_manifest()
        specification = importlib.util.spec_from_file_location("bootstrap_seed_provision", SUPPORT / "provision.py")
        provision = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(provision)
        with mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(adapter.importlib, "import_module", return_value=provision):
            adapter._apply_runtime_environment(self.runtime, self.state)
            resulting = dict(os.environ)
            target = self.state / "tools/browser/runner"
            self.assertEqual(target.read_text(), "pinned browser fixture")
            target.write_text("profile-local change")
            adapter._apply_runtime_environment(self.runtime, self.state)
        self.assertEqual(target.read_text(), "profile-local change")
        self.assertEqual((seed / "browser/runner").read_text(), "pinned browser fixture")
        self.assertEqual(resulting["HERMES_RUNTIME_DIR"], str(self.state / "tools"))
        self.assertEqual(resulting["AGENT_BROWSER_EXECUTABLE_PATH"], str(target))
        self.assertEqual(list(self.state.glob(".tools-seed-*")), [])

    def test_bad_manifest_does_not_seed_any_state(self):
        path, manifest, seed = self.prepared_manifest()
        for field, value in (("revision", "unreviewed"), ("version", True),
                             ("environment", dict(manifest["environment"], LD_PRELOAD="untrusted"))):
            path.write_text(json.dumps(dict(manifest, **{field: value})))
            with self.subTest(field=field), self.assertRaises(ValueError):
                adapter._apply_runtime_environment(self.runtime, self.state)
            self.assertFalse((self.state / "tools").exists())

    def test_store_symlinks_and_outside_browser_paths_are_refused(self):
        path, manifest, seed = self.prepared_manifest()
        (seed / "outside").symlink_to(self.workspace)
        with self.assertRaisesRegex(ValueError, "symlink escapes"):
            adapter._apply_runtime_environment(self.runtime, self.state)
        self.assertFalse((self.state / "tools").exists())
        manifest["environment"]["AGENT_BROWSER_EXECUTABLE_PATH"] = str(self.workspace)
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "escape private"):
            adapter._apply_runtime_environment(self.runtime, self.state)

    def test_existing_store_symlink_is_not_followed_or_replaced(self):
        path, manifest, seed = self.prepared_manifest()
        (self.state / "tools").symlink_to(self.workspace)
        with self.assertRaisesRegex(ValueError, "cannot be a symlink"):
            adapter._apply_runtime_environment(self.runtime, self.state)
        self.assertEqual(list(self.workspace.iterdir()), [])

    def test_native_profile_authority_maps_default_alias_and_excludes_siblings(self):
        upstream = Path(os.environ.get("HERMES_TEST_UPSTREAM", "/tmp/hermes-upstream-WdPss4"))
        if not (upstream / "hermes_cli/profiles.py").is_file():
            self.skipTest("Set HERMES_TEST_UPSTREAM to the reviewed native checkout")
        native_state = self.state / "profiles/work"
        native_state.mkdir(parents=True, mode=0o700)
        script = """
import os, sys
from pathlib import Path
sys.path[:0] = [sys.argv[1], sys.argv[2]]
state = Path(sys.argv[3])
os.environ['HOME'] = sys.argv[4]
os.environ['HERMES_HOME'] = str(state)
import hermes_constants
from hermes_cli import profiles
assert profiles.get_profile_dir('default') != state
import adapter
adapter.validate_runtime(sys.argv[1])
hooks = adapter._install_profile_authority('work', state)
assert hermes_constants.get_default_hermes_root() == state
assert profiles.get_profile_dir('default') == state
assert profiles.get_profile_dir('work') == state
assert profiles.resolve_profile_env('work') == str(state)
assert profiles.current_profile_name() == 'work'
assert profiles.get_active_profile_name() == 'work'
assert profiles.profiles_to_serve(True) == [('work', state)]
assert profiles.profiles_to_serve(False) == [('work', state)]
assert not profiles.profile_exists('other')
for operation, arguments in (
    (profiles.create_profile, ('other',)),
    (profiles.delete_profile, ('work',)),
    (profiles.rename_profile, ('work', 'other')),
    (profiles.import_profile, ('unreviewed.tar.gz',)),
    (profiles.set_active_profile, ('other',)),
    (profiles.get_active_profile, (Path('/foreign'),)),
):
    try:
        operation(*arguments)
    except ValueError:
        pass
    else:
        raise AssertionError('Foreign or destructive authority admitted')
profiles.set_active_profile('default')
assert profiles.get_active_profile() == 'work'
try:
    profiles.get_profile_dir('other')
except ValueError:
    pass
else:
    raise AssertionError('Foreign profile resolved')
original_info = profiles._profile_info
profiles._profile_info = lambda name, path, **options: (name, path, options)
assert profiles.list_profiles() == [('work', state, {'is_default': True, 'lazy_skill_count': False})]
profiles._profile_info = original_info
for module, name, original, replacement in reversed(hooks):
    setattr(module, name, original)
assert profiles.get_profile_dir('default') != state
print('NATIVE_PROFILE_AUTHORITY_OK')
"""
        result = subprocess.run([sys.executable, "-I", "-B", "-c", script, str(upstream),
                                 str(SUPPORT), str(native_state), str(self.workspace)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("NATIVE_PROFILE_AUTHORITY_OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
