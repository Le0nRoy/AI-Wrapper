"""Provisioning controls use fake Git/bwrap executables and temporary directories.

No network, installers, user services, or third-party build hooks run in tests.
"""

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import types
import unittest
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin" / "ai_wrapper_data"))
from hermes_sandbox import provision


class ProvisionFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hermes-provision-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir(mode=0o700)
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        self.runtime = self.root / "runtime-v1"
        self.arguments = {
            "runtime": str(self.runtime), "revision": provision.REVISION,
            "workspace": str(self.workspace), "state": str(self.state),
        }

    def patch(self, target, **kwargs):
        patcher = mock.patch(target, **kwargs)
        result = patcher.start()
        self.addCleanup(patcher.stop)
        return result


class ProvisionUnitTests(ProvisionFixture):
    def test_command_failure_preserves_both_stdout_build_error_and_stderr_warning(self):
        result = subprocess.CompletedProcess(["build"], 1, stdout="actual compiler failure", stderr="nonfatal PM warning")
        with mock.patch.object(provision.subprocess, "run", return_value=result):
            with self.assertRaises(provision.ProvisionError) as raised:
                provision._run(["build"], cwd=self.root)
        self.assertIn("actual compiler failure", str(raised.exception))
        self.assertIn("nonfatal PM warning", str(raised.exception))

    def test_dry_run_does_not_create_paths_or_execute_commands(self):
        self.state.rmdir()
        with mock.patch.object(provision.subprocess, "run", side_effect=AssertionError("execution forbidden")) as executor:
            result = provision.prepare(**self.arguments, dry_run=True)
        self.assertEqual(result["status"], "dry-run")
        self.assertEqual(result["revision"], provision.REVISION)
        self.assertEqual(result["extras"], list(provision.EXTRAS))
        self.assertNotIn("mcp", result["extras"])
        self.assertNotIn("computer-use", result["extras"])
        self.assertFalse(self.runtime.exists())
        self.assertFalse(self.state.exists())
        executor.assert_not_called()
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["workspace"])
        self.assertTrue(result["spool"].endswith("/.local/share/hermes-sandbox/control/spool"))

    def test_unreviewed_revision_is_rejected_before_execution(self):
        for revision in ("main", "19cb1cb", "a" * 40, "--upload-pack=evil"):
            with self.subTest(revision=revision), mock.patch.object(provision.subprocess, "run") as executor:
                with self.assertRaisesRegex(provision.ProvisionError, "reviewed official revision"):
                    provision.prepare(**{**self.arguments, "revision": revision}, dry_run=True)
                executor.assert_not_called()

    def test_symlinks_traversal_overlap_and_nonprivate_parents_are_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.workspace, target_is_directory=True)
        cases = (
            {"workspace": str(alias)}, {"runtime": str(self.root / "workspace/../runtime")},
            {"runtime": str(self.workspace / "runtime")}, {"state": str(self.workspace)},
            {"runtime": "/usr/hermes-test"}, {"runtime": str(Path.home())},
            {"state": str(Path.home() / ".ssh/hermes-test")},
        )
        for changes in cases:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                provision.validate_request(**{**self.arguments, **changes})
        self.root.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "permissions"):
            provision.validate_request(**self.arguments)

    def test_existing_runtime_is_preserved_including_empty_directories(self):
        self.runtime.mkdir()
        with self.assertRaisesRegex(provision.ProvisionError, "already exists"):
            provision.prepare(**self.arguments, dry_run=True)
        sentinel = self.runtime / "keep"
        sentinel.write_text("previous installation")
        with self.assertRaisesRegex(provision.ProvisionError, "already exists"):
            provision.prepare(**self.arguments)
        self.assertEqual(sentinel.read_text(), "previous installation")

    def test_sandbox_exposes_only_readonly_app_and_private_build_directories(self):
        stage = self.root / "stage"
        command = provision.sandbox_command(stage, self.runtime)
        binds = [(command[index], command[index + 1], command[index + 2])
                 for index, argument in enumerate(command) if argument in ("--bind", "--ro-bind")]
        writable = [source for kind, source, destination in binds if kind == "--bind"]
        self.assertEqual(writable, [str(stage / ".venv"), str(stage / ".provision")])
        self.assertIn(("--ro-bind", str(stage), str(self.runtime)), binds)
        build = provision.sandbox_command(stage, self.runtime, build=True)
        self.assertIn("_build", build)
        self.assertIn(str(Path(provision.__file__).with_name("frontend_patches.py")), build)
        self.assertIn("--bind", build)
        self.assertIn(str(stage / ".git"), build)
        self.assertNotIn(str(self.workspace), command)
        self.assertNotIn(str(self.state), command)
        self.assertNotIn("/run/user", " ".join(command))
        self.assertNotIn("DISPLAY", command)
        self.assertIn("--unshare-all", command)
        self.assertIn("--share-net", command)
        self.assertIn("--clearenv", command)
        self.assertNotIn("--ro-bind /etc /etc", " ".join(command))

    def test_doctor_reports_optional_desktop_and_actionable_arch_packages(self):
        def available(path, mode):
            return path not in provision.DESKTOP_TOOLS.values()
        with mock.patch.object(provision.os, "access", side_effect=available):
            result = provision.check_platform()
            desktop = provision.check_platform(desktop=True)
        self.assertTrue(result["ready"])
        self.assertFalse(result["desktop_ready"])
        self.assertEqual(result["desktop_missing"], ["Xvfb", "xpra", "xauth"])
        self.assertIn("xorg-server-xvfb xpra", result["arch_optional_command"])
        self.assertFalse(desktop["ready"])

    def test_missing_bwrap_refuses_prepare_and_reports_package(self):
        with mock.patch.object(provision.os, "access", side_effect=lambda path, mode: path != "/usr/bin/bwrap"):
            with self.assertRaisesRegex(provision.ProvisionError, "bubblewrap"):
                provision.prepare(**self.arguments, dry_run=True)
        self.assertFalse(self.runtime.exists())

    def test_internal_install_cannot_be_invoked_on_host(self):
        with mock.patch.object(provision, "download_tool") as downloader:
            with self.assertRaisesRegex(provision.ProvisionError, "preparation user namespace"):
                provision.install_runtime(str(self.runtime))
            with self.assertRaisesRegex(provision.ProvisionError, "preparation user namespace"):
                provision.build_frontends(str(self.runtime))
            downloader.assert_not_called()

    def test_https_redirects_reject_http(self):
        with self.assertRaisesRegex(provision.ProvisionError, "HTTPS"):
            provision.HTTPSRedirects().redirect_request(None, None, 302, "", {}, "http://example.org/archive")

    def test_pin_metadata_matches_reviewed_fixture_when_available(self):
        fixture = Path("/tmp/hermes-upstream-WdPss4")
        if not fixture.is_dir():
            self.skipTest("Optional investigator's read-only pinned checkout is unavailable")
        provision.verify_inputs(fixture)
        import tomllib
        extras = tomllib.loads((fixture / "pyproject.toml").read_text())["project"]["optional-dependencies"]
        self.assertEqual(set(extras), set(provision.EXTRAS) | set(provision.EXCLUDED_EXTRAS))

    def test_venv_config_rejects_similar_but_unpinned_version(self):
        self.runtime.mkdir()
        (self.runtime / ".venv/bin").mkdir(parents=True)
        (self.runtime / ".venv/bin/python").symlink_to("/usr/bin/python3")
        report = {"interpreter": {"executable": str(self.runtime / ".venv/bin/python"),
                  "prefix": str(self.runtime / ".venv"), "base_executable": str(Path("/usr/bin/python3").resolve()),
                  "version": provision.PYTHON_VERSION}}
        (self.runtime / ".venv/pyvenv.cfg").write_text("version_info = " + provision.PYTHON_VERSION + "0\n")
        with self.assertRaisesRegex(provision.ProvisionError, "wrong Python version"):
            provision.verify_venv(self.runtime, self.runtime, report)


class FakeExecutableIntegrationTests(ProvisionFixture):
    def setUp(self):
        super().setUp()
        self.mode = self.root / "fake-mode.json"
        self.mode.write_text("{}")
        self.log = self.root / "commands.jsonl"
        inputs = {
            "pyproject.toml": '[project]\nname="hermes-agent"\n[project.optional-dependencies]\n' + "".join(name + '=[]\n' for name in provision.EXTRAS),
            "uv.lock": "version = 1\n",
            "pm/lock.json": json.dumps({"packages": {"python": {"version": "3.14.7+20260901"}, "uv": {"version": "0.12.3"}}}),
            "apps/desktop/package.json": json.dumps({"devDependencies": {"electron": "40.10.2"}}),
        }
        self.patch("hermes_sandbox.provision.INPUT_DIGESTS", new={name: hashlib.sha256(value.encode()).hexdigest() for name, value in inputs.items()})
        shared = (
            "#!/usr/bin/python3\nimport json, os, pathlib, sys\n"
            f"mode = json.loads(pathlib.Path({str(self.mode)!r}).read_text())\n"
            f"with open({str(self.log)!r}, 'a') as log:\n"
            "    log.write(json.dumps({'argv': sys.argv, 'env': dict(os.environ)}) + '\\n')\n"
        )
        git = self.root / "fake-git"
        git.write_text(shared +
            "verb = next(value for value in sys.argv[1:] if value in ('init', 'fetch', 'rev-parse', 'checkout', 'diff'))\n"
            "if verb == 'diff' and mode.get('tracked_change'): sys.exit(1)\n"
            "if verb == 'rev-parse':\n"
            f"    print(mode.get('revision', {provision.REVISION!r}))\n"
            "if verb == 'checkout':\n"
            f"    for name, content in {inputs!r}.items():\n"
            "        path = pathlib.Path.cwd() / name\n"
            "        path.parent.mkdir(parents=True, exist_ok=True)\n"
            "        path.write_text(content)\n")
        git.chmod(0o700)
        bwrap = self.root / "fake-bwrap"
        bwrap.write_text(shared +
            "if mode.get('fail'):\n"
            "    print('fake confined failure', file=sys.stderr)\n"
            "    sys.exit(19)\n"
            "position = next(index for index, value in enumerate(sys.argv[:-2]) if value in ('--bind', '--ro-bind') and '.hermes-prepare-' in sys.argv[index + 1])\n"
            "stage = pathlib.Path(sys.argv[position + 1]); runtime = pathlib.Path(sys.argv[position + 2])\n"
            "if '_build' in sys.argv:\n"
            "    if mode.get('build_fail'): sys.exit(23)\n"
            "    artifacts = {}\n"
            "    for name, relative, content in [('executable', 'apps/desktop/release/linux-unpacked/Hermes', b'\\x7fELFfake executable'), ('electron_main', 'apps/desktop/release/linux-unpacked/resources/app.asar.unpacked/dist/electron-main.mjs', b'fake compiled overlays'), ('web_index', 'hermes_cli/web_dist/index.html', b'<html>fake web</html>')]:\n"
            "        path = stage / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(content); path.chmod(0o700)\n"
            "        import hashlib\n"
            "        artifacts[name] = {'path': relative, 'sha256': hashlib.sha256(content).hexdigest()}\n"
            "    if mode.get('bad_artifact'): artifacts['web_index']['path'] = '../escape'\n"
            "    if mode.get('missing_artifact'): (stage / artifacts['web_index']['path']).unlink()\n"
            "    (stage / '.provision/frontends.json').write_text(json.dumps({'electron': '40.10.2', 'overlays': {}, 'artifacts': artifacts}))\n"
            "    sys.exit(0)\n"
            "(stage / '.venv/bin').mkdir()\n"
            "controlled = pathlib.Path('/usr/bin/python3').resolve()\n"
            "(stage / '.venv/bin/python').symlink_to(mode.get('python', str(controlled)))\n"
            "(stage / '.venv/pyvenv.cfg').write_text('home = /usr/bin\\nversion = 3.14.7\\n')\n"
            "(stage / '.venv/bin/hermes').write_text('#!' + str(runtime / '.venv/bin/python') + '\\n')\n"
            "metadata = stage / '.venv/lib/python3.14/site-packages/example.dist-info/direct_url.json'\n"
            "metadata.parent.mkdir(parents=True)\n"
            "metadata.write_text(json.dumps({'url': str(runtime), 'dir_info': {'editable': False}}))\n"
            "if mode.get('staging_metadata'): metadata.write_text(json.dumps({'url': str(stage)}))\n"
            "if mode.get('staging_shebang'): (stage / '.venv/bin/hermes').write_text('#!' + str(stage / '.venv/bin/python') + '\\n')\n"
            "browser = {'PLAYWRIGHT_BROWSERS_PATH': str(runtime / '.provision/store'), 'AGENT_BROWSER_EXECUTABLE_PATH': str(runtime / '.provision/store/chromium/chrome')}\n"
            "if mode.get('browser'): browser['AGENT_BROWSER_EXECUTABLE_PATH'] = mode['browser']\n"
            "identity = {'executable': str(runtime / '.venv/bin/python'), 'prefix': str(runtime / '.venv'), 'base_executable': str(controlled), 'version': '3.14.7'}\n"
            "if mode.get('identity'): identity['prefix'] = mode['identity']\n"
            f"report = {{'extras': {list(provision.EXTRAS)!r}, 'python': '3.14.7+20260901', 'uv': '0.12.3', 'browser': browser, 'interpreter': identity}}\n"
            "if not mode.get('no_report'): (stage / '.provision/result.json').write_text(json.dumps(report))\n"
            "if mode.get('tamper'): (stage / 'uv.lock').write_text('changed')\n"
            "if mode.get('race'): runtime.mkdir()\n")
        bwrap.chmod(0o700)
        self.patch("hermes_sandbox.provision.SYSTEM_TOOLS", new={**provision.SYSTEM_TOOLS, "git": str(git), "bwrap": str(bwrap)})

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_success_publishes_runtime_with_exact_contract_and_no_state_mutation(self):
        sentinel = self.state / "credentials"
        sentinel.write_text("keep private")
        with mock.patch.dict(os.environ, {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath", "GIT_CONFIG_VALUE_0": "/evil", "LD_PRELOAD": "injected", "DISPLAY": ":0", "SECRET_TOKEN": "must-not-leak"}):
            result = provision.prepare(**self.arguments)
        self.assertEqual(result["status"], "prepared")
        self.assertTrue((self.runtime / ".venv/bin/python").is_file())
        self.assertTrue(os.access(self.runtime / ".venv/bin/python", os.X_OK))
        self.assertEqual((self.runtime / ".venv/bin/python").resolve(), Path("/usr/bin/python3").resolve())
        self.assertEqual((self.runtime / ".venv/bin/hermes").read_text(), "#!" + str(self.runtime / ".venv/bin/python") + "\n")
        for artifact in (self.runtime / ".venv/pyvenv.cfg", self.runtime / ".venv/bin/hermes", self.runtime / provision.MANIFEST):
            self.assertNotIn(".hermes-prepare-", artifact.read_text())
        manifest = json.loads((self.runtime / provision.MANIFEST).read_text())
        self.assertEqual(manifest["revision"], provision.REVISION)
        self.assertEqual(manifest["dependencies"]["uv"], "0.12.3")
        self.assertTrue(manifest["pm_seed"]["copy_required"])
        self.assertEqual(manifest["pm_seed"]["destination"], str(self.state / "tools"))
        self.assertEqual(manifest["environment"]["HERMES_RUNTIME_DIR"], str(self.state / "tools"))
        self.assertEqual(manifest["frontends"]["electron"], "40.10.2")
        self.assertEqual((self.runtime / provision.MANIFEST).stat().st_mode & 0o777, 0o600)
        self.assertEqual(sentinel.read_text(), "keep private")
        self.assertFalse(list(self.root.glob(".hermes-prepare-*")))
        self.assertEqual(len(self.commands()), 7)
        for command in self.commands():
            self.assertNotIn("SECRET_TOKEN", command["env"])
            self.assertNotIn("LD_PRELOAD", command["env"])
            self.assertNotIn("GIT_CONFIG_COUNT", command["env"])
        fetch = self.commands()[1]["argv"]
        self.assertEqual(fetch[-2:], [provision.REPOSITORY, provision.REVISION])
        self.assertIn("core.hooksPath=/dev/null", fetch)
        self.assertIn("credential.helper=", fetch)
        self.assertIn("uploadpack.packObjectsHook=", fetch)

    def test_local_pinned_source_disables_upload_hooks_and_avoids_network_fetch(self):
        source = self.root / "inspection-checkout"
        source.mkdir(mode=0o700)
        (source / ".git").mkdir()
        result = provision.prepare(**self.arguments, source=str(source))
        self.assertEqual(result["status"], "prepared")
        fetch = next(command["argv"] for command in self.commands() if "fetch" in command["argv"])
        self.assertEqual(fetch[-2:], [str(source), provision.REVISION])
        self.assertIn("protocol.file.allow=always", fetch)
        self.assertIn("uploadpack.packObjectsHook=", fetch)

    def test_local_source_pin_mismatch_never_initializes_stage_git_or_builds(self):
        source = self.root / "inspection-checkout"
        source.mkdir(mode=0o700)
        (source / ".git").mkdir()
        self.mode.write_text(json.dumps({"revision": "a" * 40}))
        with self.assertRaisesRegex(provision.ProvisionError, "Local source does not match"):
            provision.prepare(**self.arguments, source=str(source))
        self.assertEqual(len(self.commands()), 1)
        self.assertFalse(self.runtime.exists())
        self.assertFalse(list(self.root.glob(".hermes-prepare-*")))

    def test_success_creates_private_state_only_after_build(self):
        self.state.rmdir()
        result = provision.prepare(**self.arguments)
        self.assertEqual(result["status"], "prepared")
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list(self.state.iterdir()), [])

    def test_failed_build_preserves_existing_state_and_does_not_publish(self):
        self.mode.write_text(json.dumps({"fail": True}))
        sentinel = self.state / "keep"
        sentinel.write_text("existing state")
        with self.assertRaisesRegex(provision.ProvisionError, "fake confined failure"):
            provision.prepare(**self.arguments)
        self.assertFalse(self.runtime.exists())
        self.assertEqual(sentinel.read_text(), "existing state")
        self.assertFalse(list(self.root.glob(".hermes-prepare-*")))

    def test_fetch_mismatch_stops_before_checkout_or_build(self):
        self.mode.write_text(json.dumps({"revision": "a" * 40}))
        with self.assertRaisesRegex(provision.ProvisionError, "trusted pin"):
            provision.prepare(**self.arguments)
        self.assertEqual(len(self.commands()), 3)
        self.assertFalse(self.runtime.exists())
        self.assertFalse(list(self.root.glob(".hermes-prepare-*")))

    def test_missing_report_changed_lock_and_escaped_paths_never_publish(self):
        for mode in ({"no_report": True}, {"tamper": True}, {"python": "/usr/bin/git"},
                     {"python": "/tmp/transient-cache/python"}, {"identity": "/tmp/staging/.venv"},
                     {"staging_metadata": True}, {"staging_shebang": True},
                     {"build_fail": True}, {"tracked_change": True}, {"bad_artifact": True}, {"missing_artifact": True},
                     {"browser": "/home/other/browser"}, {"browser": str(self.runtime) + "/.provision/store/../../escape"}):
            with self.subTest(mode=mode):
                self.mode.write_text(json.dumps(mode))
                with self.assertRaises((ValueError, OSError)):
                    provision.prepare(**self.arguments)
                self.assertFalse(self.runtime.exists())
                self.assertFalse(list(self.root.glob(".hermes-prepare-*")))

    def test_publication_race_cannot_replace_existing_directory(self):
        self.mode.write_text(json.dumps({"race": True}))
        with self.assertRaisesRegex(provision.ProvisionError, "already exists"):
            provision.prepare(**self.arguments)
        self.assertTrue(self.runtime.is_dir())
        self.assertEqual(list(self.runtime.iterdir()), [])
        self.assertFalse(list(self.root.glob(".hermes-prepare-*")))

    def test_atomic_publish_refuses_even_empty_destination(self):
        stage = self.root / "stage"
        stage.mkdir()
        (stage / "keep").write_text("new generation")
        self.runtime.mkdir()
        with self.assertRaises(FileExistsError):
            provision.publish(stage, self.runtime)
        self.assertTrue((stage / "keep").is_file())
        self.assertEqual(list(self.runtime.iterdir()), [])
        second = self.root / "runtime-v2"
        provision.publish(stage, second)
        self.assertEqual((second / "keep").read_text(), "new generation")

    def test_cli_dry_run_and_negative_revision_return_machine_readable_results(self):
        command = [sys.executable, "-I", "-B", str(Path(provision.__file__)), "prepare"]
        for name, value in self.arguments.items():
            command.extend(("--" + name, value))
        command.append("--dry-run")
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "dry-run")
        command[command.index("--revision") + 1] = "main"
        rejected = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(rejected.returncode, 1)
        self.assertIn("reviewed official revision", rejected.stderr)
        self.assertFalse(self.runtime.exists())

    def test_publish_failure_rolls_back_only_new_empty_state(self):
        self.state.rmdir()
        with mock.patch.object(provision, "publish", side_effect=OSError("publication refused")):
            with self.assertRaisesRegex(OSError, "publication refused"):
                provision.prepare(**self.arguments)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.runtime.exists())
        self.assertFalse(list(self.root.glob(".hermes-prepare-*")))


class ConfinedInstallerControls(ProvisionFixture):
    def setUp(self):
        super().setUp()
        self.runtime.mkdir()
        (self.runtime / ".provision").mkdir(mode=0o700)
        (self.runtime / ".venv").mkdir(mode=0o700)
        (self.runtime / "pm").mkdir()
        (self.runtime / "pm/lock.json").write_text(json.dumps({
            "packages": {"uv": {"version": "0.12.3"}, "python": {"version": "3.14.7+20260901"}},
        }))
        (self.runtime / "pyproject.toml").write_text(
            "[project.optional-dependencies]\n" + "".join(name + "=[]\n" for name in (*provision.EXTRAS, *provision.EXCLUDED_EXTRAS)))
        (self.runtime / "uv.lock").write_text('version=1\n[[package]]\nname="setuptools"\nversion="83.0.0"\n'
                                              '[[package]]\nname="misaki"\nversion="0.9.4"\n')
        self.calls = []
        self.fail_sync = False
        self.browser = {
            "PLAYWRIGHT_BROWSERS_PATH": str(self.runtime / ".provision/store"),
            "AGENT_BROWSER_EXECUTABLE_PATH": str(self.runtime / ".provision/store/chromium/chrome"),
        }

    def fake_download(self, package, destination):
        executable = destination / ("uv" if package["version"] == "0.12.3" else "python/bin/python3")
        executable.parent.mkdir(parents=True)
        executable.write_text("fake pinned executable")

    def fake_run(self, command, **kwargs):
        self.calls.append((command, kwargs))
        if "sync" in command and self.fail_sync:
            raise provision.ProvisionError("no pinned wheel available")
        proof = {"browser": self.browser, "interpreter": {
            "executable": str(self.runtime / ".venv/bin/python"), "prefix": str(self.runtime / ".venv"),
            "base_executable": str(Path("/usr/bin/python3").resolve()), "version": "3.14.7",
        }}
        return json.dumps(proof) if "-c" in command else ""

    def install(self):
        read_text = Path.read_text
        def namespaced_read(path, *args, **kwargs):
            if str(path) == "/proc/self/uid_map":
                return "1000 1000 1\n"
            return read_text(path, *args, **kwargs)
        with mock.patch.object(provision, "__file__", "/opt/hermes-provision.py"), \
                mock.patch.dict(os.environ, {"HERMES_PROVISION_SANDBOX": "1"}), \
                mock.patch.object(Path, "read_text", namespaced_read), \
                mock.patch.object(provision.platform, "python_version", return_value="3.14.7"), \
                mock.patch.object(provision, "verify_inputs"), \
                mock.patch.object(provision, "download_tool", side_effect=self.fake_download), \
                mock.patch.object(provision, "_run", side_effect=self.fake_run):
            provision.install_runtime(str(self.runtime))

    def test_frozen_build_only_allows_reviewed_sources_and_prepares_browser_and_core_tools(self):
        self.install()
        self.assertEqual(len(self.calls), 3)
        creation, sync, browser = [command for command, kwargs in self.calls]
        self.assertIn("--relocatable", creation)
        self.assertIn("--no-managed-python", creation)
        self.assertEqual(creation[creation.index("--python") + 1], "/usr/bin/python3")
        self.assertEqual(creation[-1], str(self.runtime / ".venv"))
        self.assertIn("--frozen", sync)
        self.assertNotIn("--no-build", sync)
        self.assertIn("--project", sync)
        self.assertEqual(sync[sync.index("--project") + 1], str(self.runtime / ".provision/python-project"))
        self.assertIn("--no-build-package", sync)
        self.assertEqual(sync[sync.index("--no-build-package") + 1], "setuptools")
        self.assertNotIn("misaki", sync)
        self.assertIn("--no-install-project", sync)
        self.assertNotIn("--all-extras", sync)
        self.assertNotIn("mcp", sync)
        self.assertNotIn("computer-use", sync)
        for extra in ("kittentts", "dingtalk", "silk", "matrix"):
            self.assertIn(extra, sync)
        self.assertEqual((self.runtime / ".provision/build-constraints.txt").read_text(), "setuptools==83.0.0\nmisaki==0.9.4\n")
        self.assertEqual(self.calls[1][1]["env"]["CARGO_HOME"], str(self.runtime / ".provision/cache/cargo"))
        self.assertIn("pm.ensure('agent-browser', explicit=True)", browser[3])
        self.assertIn("'--dump-dom', 'about:blank'", browser[3])
        self.assertIn("('ffmpeg', 'ripgrep', 'npm')", browser[3])
        self.assertEqual(browser[0], str(self.runtime / ".venv/bin/python"))
        report = json.loads((self.runtime / ".provision/result.json").read_text())
        self.assertEqual(report["browser"], self.browser)
        self.assertEqual(report["uv"], "0.12.3")
        stamp = json.loads((self.runtime / ".provision/install-stamp.json").read_text())
        self.assertEqual(stamp["updateMechanism"], "external")
        self.assertEqual(stamp["commit"], provision.REVISION)

    def test_missing_wheel_never_runs_browser_pm_or_reports_success(self):
        self.fail_sync = True
        with self.assertRaisesRegex(provision.ProvisionError, "no pinned wheel"):
            self.install()
        self.assertEqual(len(self.calls), 2)
        self.assertFalse((self.runtime / ".provision/result.json").exists())


class ArtifactControls(ProvisionFixture):
    def archive(self, member_name="uv-folder/uv"):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            member = tarfile.TarInfo(member_name)
            content = b"fake pinned binary"
            member.size = len(content)
            member.mode = 0o700
            archive.addfile(member, io.BytesIO(content))
        return buffer.getvalue()

    def package(self, content, checksum=None):
        return {"artifacts": {"linux-x64": {"url": "https://github.com/astral-sh/uv/releases/download/pin/archive.tar.gz", "sha256": checksum or hashlib.sha256(content).hexdigest()}}}

    def test_verified_archive_is_extracted_but_hash_mismatch_is_not(self):
        content = self.archive()
        with mock.patch.object(provision.platform, "machine", return_value="x86_64"), mock.patch.object(provision.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = io.BytesIO(content)
            provision.download_tool(self.package(content), self.root / "valid")
            self.assertEqual((self.root / "valid/uv-folder/uv").read_bytes(), b"fake pinned binary")
            opener.return_value.open.return_value = io.BytesIO(content)
            with self.assertRaisesRegex(provision.ProvisionError, "SHA256 mismatch"):
                provision.download_tool(self.package(content, "0" * 64), self.root / "invalid")
            self.assertFalse((self.root / "invalid/uv-folder/uv").exists())

    def test_verified_tar_still_cannot_write_outside_staging(self):
        content = self.archive("../escape")
        with mock.patch.object(provision.platform, "machine", return_value="x86_64"), mock.patch.object(provision.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = io.BytesIO(content)
            with self.assertRaises(tarfile.FilterError):
                provision.download_tool(self.package(content), self.root / "invalid")
        self.assertFalse((self.root / "escape").exists())


class FrontendBuildControls(ProvisionFixture):
    def setUp(self):
        super().setUp()
        self.runtime.mkdir()
        (self.runtime / ".provision").mkdir()
        (self.runtime / "apps/desktop").mkdir(parents=True)
        (self.runtime / "apps/desktop/package.json").write_text('{"devDependencies":{"electron":"40.10.2"}}')
        self.sources = {"apps/desktop/electron/main.ts": "original main", "apps/desktop/electron/desktop-remote-route.ts": "original route"}
        for name, text in self.sources.items():
            path = self.runtime / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.patches = types.SimpleNamespace(DESKTOP_SOURCE_DIGESTS=dict.fromkeys(self.sources),
            desktop_source_patches=lambda sources: {name: text + " protected overlay" for name, text in sources.items()})
        self.calls = []
        self.fail_web = False

    def fake_run(self, command, **kwargs):
        self.calls.append((command, kwargs))
        if "build_source_web" in command[4] and self.fail_web:
            raise provision.ProvisionError("web compile failed")
        if len(self.calls) < 3:
            for name in self.sources:
                self.assertIn("protected overlay", (self.runtime / name).read_text())
            return ""
        for name, text in self.sources.items():
            self.assertEqual((self.runtime / name).read_text(), text)
        artifacts = {"executable": "apps/desktop/release/linux-unpacked/Hermes", "electron_main": "apps/desktop/dist/electron-main.mjs", "web_index": "hermes_cli/web_dist/index.html"}
        for name, relative in artifacts.items():
            path = self.runtime / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"\x7fELFfake executable" if name == "executable" else b"built output")
            path.chmod(0o700)
        return json.dumps(artifacts)

    def build(self):
        with mock.patch.object(provision, "require_preparation_namespace"), \
                mock.patch.object(provision, "verify_inputs"), \
                mock.patch.object(provision.importlib.util, "spec_from_file_location"), \
                mock.patch.object(provision.importlib.util, "module_from_spec", return_value=self.patches), \
                mock.patch.object(provision, "_run", side_effect=self.fake_run):
            provision.build_frontends(str(self.runtime))

    def test_packaging_uses_real_build_only_entrypoint_restores_sources_and_records_hashes(self):
        self.build()
        self.assertEqual(len(self.calls), 3)
        self.assertIn("'desktop', '--build-only', '--force-build'", self.calls[0][0][4])
        self.assertIn("build_source_web", self.calls[1][0][4])
        self.assertIn("_packaged_node_pty_missing", self.calls[2][0][4])
        self.assertIn("HERMES_SANDBOX_DESKTOP_ATTACH_ONLY", self.calls[2][0][4])
        report = json.loads((self.runtime / ".provision/frontends.json").read_text())
        self.assertEqual(set(report["overlays"]), set(self.sources))
        provision.verify_frontends(self.runtime, report)
        (self.runtime / report["artifacts"]["web_index"]["path"]).write_text("tampered")
        with self.assertRaisesRegex(provision.ProvisionError, "changed"):
            provision.verify_frontends(self.runtime, report)

    def test_failed_web_build_restores_original_sources_and_never_records_success(self):
        self.fail_web = True
        with self.assertRaisesRegex(provision.ProvisionError, "web compile failed"):
            self.build()
        for name, text in self.sources.items():
            self.assertEqual((self.runtime / name).read_text(), text)
        self.assertFalse((self.runtime / ".provision/frontends.json").exists())


class RealNamespaceControls(ProvisionFixture):
    def run_namespace(self, stage, probe, *arguments):
        if sys.platform != "linux" or not os.access("/usr/bin/bwrap", os.X_OK):
            self.skipTest("Linux bubblewrap is unavailable")
        command = provision.sandbox_command(stage, self.runtime)
        command = command[:command.index("--") + 1]
        result = subprocess.run([*command, "/usr/bin/python3", "-I", "-B", "-c", probe, *arguments],
                                env=provision.clean_environment(), text=True, capture_output=True, timeout=20)
        if result.returncode and any(message in result.stderr.lower() for message in (
                "no permissions to create new namespace", "operation not permitted", "unprivileged user namespaces")):
            self.skipTest("Host policy prevents creating a preparation user namespace: " + result.stderr.strip())
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_real_venv_is_built_at_final_path_and_survives_atomic_publication(self):
        stage = self.root / ".hermes-prepare-real"
        stage.mkdir(mode=0o700)
        (stage / ".venv").mkdir(mode=0o700)
        (stage / ".provision").mkdir(mode=0o700)
        probe = (
            "import json, pathlib, subprocess, sys, venv; root = pathlib.Path(sys.argv[1]); "
            "venv.EnvBuilder(with_pip=False, symlinks=True).create(root / '.venv'); "
            "(root / '.venv/bin/test-entry').write_text('#!' + str(root / '.venv/bin/python') + '\\n'); "
            "proof = subprocess.check_output([str(root / '.venv/bin/python'), '-I', '-c', "
            "\"import json,pathlib,platform,sys; print(json.dumps({'executable':sys.executable,'prefix':sys.prefix,"
            "'base_executable':str(pathlib.Path(sys._base_executable).resolve()),'version':platform.python_version()}))\"], text=True); "
            "print(proof)"
        )
        report = {"interpreter": json.loads(self.run_namespace(stage, probe, str(self.runtime)))}
        with mock.patch.object(provision, "PYTHON_VERSION", report["interpreter"]["version"]):
            provision.verify_venv(stage, self.runtime, report)
        provision.publish(stage, self.runtime)
        result = subprocess.run([str(self.runtime / ".venv/bin/python"), "-I", "-B", "-c", "import sys; print(sys.prefix)"],
                                env=provision.clean_environment(), text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.runtime / ".venv"))
        for path in (self.runtime / ".venv/pyvenv.cfg", self.runtime / ".venv/bin/test-entry"):
            self.assertNotIn(str(stage), path.read_text())

    def test_preparation_namespace_allows_only_private_writes(self):
        if sys.platform != "linux" or not os.access("/usr/bin/bwrap", os.X_OK):
            self.skipTest("Linux bubblewrap is unavailable")
        stage = self.root / "stage"
        stage.mkdir(mode=0o700)
        (stage / ".venv").mkdir(mode=0o700)
        (stage / ".provision").mkdir(mode=0o700)
        (stage / "app.py").write_text("immutable app")
        sentinel = self.workspace / "host-secret"
        sentinel.write_text("must remain outside the preparation namespace")
        command = provision.sandbox_command(stage, self.runtime)
        command = command[:command.index("--") + 1]
        probe = (
            "import os, pathlib, sys; root = pathlib.Path(sys.argv[1]); "
            "assert pathlib.Path.home() == pathlib.Path('/home/hermes'); "
            "assert not pathlib.Path(sys.argv[2]).exists(); "
            "assert 'DISPLAY' not in os.environ and 'DBUS_SESSION_BUS_ADDRESS' not in os.environ; "
            "(root / '.venv/allowed').write_text('private generation'); "
            "(root / '.provision/allowed').write_text('private cache'); "
            "\ntry:\n (root / 'app.py').write_text('forbidden mutation')\n"
            "except OSError:\n pass\nelse:\n raise AssertionError('app was writable')\n"
        )
        result = subprocess.run([*command, "/usr/bin/python3", "-I", "-c", probe,
                                 str(self.runtime), str(sentinel)],
                                env=provision.clean_environment(), text=True, capture_output=True, timeout=20)
        if result.returncode and any(message in result.stderr.lower() for message in (
                "no permissions to create new namespace", "operation not permitted", "unprivileged user namespaces")):
            self.skipTest("Host policy prevents creating a preparation user namespace: " + result.stderr.strip())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((stage / "app.py").read_text(), "immutable app")
        self.assertEqual((stage / ".venv/allowed").read_text(), "private generation")
        self.assertEqual((stage / ".provision/allowed").read_text(), "private cache")
        self.assertEqual(sentinel.read_text(), "must remain outside the preparation namespace")


if __name__ == "__main__":
    unittest.main()
