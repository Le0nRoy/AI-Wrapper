"""Stdlib addon test plan, owned entirely by this file.

Unit coverage: manifest gates, exact upstream pins, path/member validation,
download limits and redirects. Integration coverage: tar/ZIP package layout,
profile separation, read-only modes, no execution, symlink destinations,
digest enforcement, atomic publish/update and rollback on failure.
Each scenario supplies positive and negative controls in temporary profiles.
TemporaryDirectory plus addCleanup removes data even when assertions fail;
network replies are mocked, and neither host installs nor skills are run.
"""

import contextlib
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin" / "ai_wrapper_data"))
from hermes_sandbox import addons


class DownloadResponse(io.BytesIO):
    def __init__(self, content, url):
        super().__init__(content)
        self.url = url

    def geturl(self):
        return self.url


class HermesAddonTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hermes-addons-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "profile"
        self.state.mkdir(mode=0o700)
        self.catalog = addons.list_addons()

    def archive(self, entries, zipped=False, compressed=False):
        target = self.root / ("archive.zip" if zipped else "archive.tar")
        if zipped:
            with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as package:
                for name, content, mode, kind in entries:
                    member = zipfile.ZipInfo(name)
                    member.create_system = 3
                    member.external_attr = mode << 16
                    package.writestr(member, content)
        else:
            with tarfile.open(target, "w:gz" if compressed else "w") as package:
                for name, content, mode, kind in entries:
                    member = tarfile.TarInfo(name)
                    member.mode = mode
                    member.type = kind
                    member.size = len(content) if kind == tarfile.REGTYPE else 0
                    if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                        member.linkname = "../../outside"
                    package.addfile(member, io.BytesIO(content))
        return target

    def skill(self, extra=(), prefix="", zipped=False, compressed=False):
        return self.archive(
            [(prefix + "SKILL.md", b"skill", stat.S_IFREG | 0o777, tarfile.REGTYPE)]
            + list(extra), zipped=zipped, compressed=compressed,
        )

    def assert_clean(self):
        self.assertFalse(any(child.name.startswith(".addon-stage-") for child in self.state.iterdir()))
        skills = self.state / "skills"
        if skills.exists():
            self.assertFalse(any(child.name.startswith(".addon-stage-") for child in skills.iterdir()))

    @contextlib.contextmanager
    def pinned(self, name, archive):
        catalog = json.loads(json.dumps(self.catalog))
        catalog[name]["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        with mock.patch.object(addons, "list_addons", return_value=catalog):
            yield catalog[name]

    def test_catalog_is_opt_in_and_deferred_names_are_gated(self):
        """Catalog reads succeed; unapproved, paid-without-file and deferred installs fail."""
        with mock.patch.object(addons.urllib.request, "urlopen") as network:
            self.assertIn("start-second-brain", addons.list_addons())
            for name in ("codex-limits", "codex-pool", "host-plugin", "../make-feature", "MakeFeature"):
                with self.subTest(name=name), self.assertRaises(addons.AddonError):
                    addons.install_addon(name, self.state)
            for name in ("customer-problem-researcher", "financial-manager", "make-feature", "competitive-intelligence"):
                with self.subTest(name=name), self.assertRaisesRegex(addons.AddonError, "user-provided"):
                    addons.install_addon(name, self.state)
            network.assert_not_called()
        self.assertEqual(list(self.state.iterdir()), [])

    def test_manifest_pins_and_runtime_modes(self):
        """Exact reviewed references are pinned; no defaults activate plugins or model claims."""
        expected = {
            "start-second-brain": ("artemiimillier/start-second-brain", "d5dad206b0326a3e123e8d55f39a563cdd5cf6f1", "a37778d69d508e967d2b5c17ace9facef4843dee790ade8f69e3a09b84ced1bd"),
            "models-table": ("artemiimillier/hermes-models-table", "84e6f7b13c286e4467b0498b453402d3dfc3b9ab", "a9f8af76dc971426b566e34e6a24106bd61afbafe85cf09a4bef6786fdc9c5ad"),
        }
        for name, (repository, commit, digest) in expected.items():
            addon = self.catalog[name]
            self.assertEqual((addon["repository"], addon["commit"], addon["sha256"]), (repository, commit, digest))
            self.assertEqual(addons._github_source(addon), f"https://codeload.github.com/{repository}/tar.gz/{commit}")
        self.assertFalse(self.catalog["models-table"]["import_model_claims"])
        self.assertEqual(self.catalog["competitive-intelligence"]["mode"], "public-web-only")
        for addon in self.catalog.values():
            if addon["status"] == "optional":
                self.assertFalse(addon["host_plugins"])
        manifest = json.loads(addons.MANIFEST_PATH.read_text())
        self.assertTrue(manifest["policy"]["opt_in"])
        self.assertFalse(manifest["policy"]["auto_install"])
        for field, invalid in (("repository", "other/repo"), ("commit", "main"), ("sha256", "bad")):
            addon = dict(self.catalog["start-second-brain"], **{field: invalid})
            with self.assertRaises(addons.AddonError):
                addons._github_source(addon)

    def test_local_packages_are_readonly_and_never_executed(self):
        """All local options extract allowed content; executable and host-plugin payloads stay inert."""
        marker = self.root / "executed"
        archive = self.skill([
            ("scripts/tool.sh", f"touch {marker}\n".encode(), stat.S_IFREG | 0o777, tarfile.REGTYPE),
            ("templates/input.csv", b"normalized,record", 0o644, tarfile.REGTYPE),
            ("references/source.md", b"source", 0o644, tarfile.REGTYPE),
            ("assets/data.json", b"{}", 0o644, tarfile.REGTYPE),
            ("plugins/host.py", b"raise RuntimeError('host plugin')", 0o777, tarfile.REGTYPE),
            ("install.sh", b"exit 1", 0o777, tarfile.REGTYPE),
        ])
        with mock.patch.object(addons.urllib.request, "urlopen") as network:
            for name in ("customer-problem-researcher", "financial-manager", "make-feature", "competitive-intelligence"):
                destination = addons.install_addon(name, self.state, archive)
                self.assertEqual(destination, self.state / "skills" / name)
                self.assertEqual((destination / "scripts/tool.sh").stat().st_mode & 0o777, 0o444)
                self.assertEqual((destination / "SKILL.md").stat().st_mode & 0o777, 0o444)
                self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
                self.assertEqual((destination / "scripts").stat().st_mode & 0o777, 0o555)
                self.assertEqual((destination / "templates/input.csv").read_bytes(), b"normalized,record")
                self.assertFalse((destination / "plugins").exists())
                self.assertFalse((destination / "install.sh").exists())
                receipt = json.loads((destination / addons.RECEIPT_NAME).read_text())
                self.assertEqual(receipt["mode"], self.catalog[name]["mode"])
                self.assertNotIn(str(archive), json.dumps(receipt))
            network.assert_not_called()
        self.assertFalse(marker.exists())
        self.assert_clean()

    def test_explicit_executable_files_preserve_only_source_execute_bits(self):
        """Reviewed script execute bits survive; unlisted scripts and nonexecutable files do not gain them."""
        archive = self.skill([
            ("scripts/tool.sh", b"exit 1", 0o7755, tarfile.REGTYPE),
            ("scripts/plain.py", b"raise RuntimeError", 0o644, tarfile.REGTYPE),
            ("scripts/unlisted.sh", b"exit 1", 0o755, tarfile.REGTYPE),
        ])
        catalog = json.loads(json.dumps(self.catalog))
        catalog["make-feature"]["executable_files"] = ["scripts/tool.sh", "scripts/plain.py"]
        with mock.patch.object(addons, "list_addons", return_value=catalog):
            destination = addons.install_addon("make-feature", self.state, archive)
        self.assertEqual((destination / "scripts/tool.sh").stat().st_mode & 0o7777, 0o555)
        self.assertEqual((destination / "scripts/plain.py").stat().st_mode & 0o7777, 0o444)
        self.assertEqual((destination / "scripts/unlisted.sh").stat().st_mode & 0o7777, 0o444)
        self.assert_clean()

    def test_local_tar_gzip_zip_and_single_folder_layouts(self):
        """Supported layouts install successfully; ambiguous folders and missing skill files fail."""
        for index, (prefix, zipped, compressed) in enumerate((("", False, False), ("provided/", False, True), ("provided/", True, False))):
            archive = self.skill(prefix=prefix, zipped=zipped, compressed=compressed)
            state = self.root / f"profile-{index}"
            state.mkdir()
            destination = addons.install_addon("make-feature", state, archive)
            self.assertEqual((destination / "SKILL.md").read_bytes(), b"skill")
        for entries in (
            [("README.md", b"reference", 0o644, tarfile.REGTYPE)],
            [("one/SKILL.md", b"skill", 0o644, tarfile.REGTYPE), ("two/SKILL.md", b"skill", 0o644, tarfile.REGTYPE)],
            [("one/SKILL.md", b"skill", 0o644, tarfile.REGTYPE), ("outside.txt", b"outside", 0o644, tarfile.REGTYPE)],
        ):
            with self.subTest(entries=entries), self.assertRaises(addons.AddonError):
                addons.install_addon("make-feature", self.state, self.archive(entries))
        self.assertFalse((self.state / "skills/make-feature").exists())
        self.assert_clean()

    def test_github_skill_allowlist_and_digest(self):
        """Pinned skill/templates/scripts extract; README and unpinned content do not."""
        addon = self.catalog["start-second-brain"]
        prefix = addon["repository"].split("/")[1] + "-" + addon["commit"] + "/"
        entries = [(prefix + path, b"content", 0o644, tarfile.REGTYPE) for path in addon["required"]]
        entries += [(prefix + "README.md", b"omit", 0o777, tarfile.REGTYPE)]
        archive = self.archive(entries, compressed=True)
        with self.assertRaisesRegex(addons.AddonError, "SHA-256"):
            addons.install_addon("start-second-brain", self.state, archive)
        with self.pinned("start-second-brain", archive):
            destination = addons.install_addon("start-second-brain", self.state, archive)
        self.assertTrue((destination / "scripts/brain_check.py").exists())
        self.assertFalse((destination / "README.md").exists())
        self.assert_clean()

    def test_models_table_is_inert_reference_only(self):
        """README/license install; skills, scripts and model configuration do not."""
        addon = self.catalog["models-table"]
        prefix = addon["repository"].split("/")[1] + "-" + addon["commit"] + "/"
        archive = self.archive([
            (prefix + "README.md", b"unverified claims", 0o755, tarfile.REGTYPE),
            (prefix + "LICENSE", b"license", 0o644, tarfile.REGTYPE),
            (prefix + "SKILL.md", b"auto-load claims", 0o644, tarfile.REGTYPE),
            (prefix + "scripts/import.py", b"raise RuntimeError", 0o755, tarfile.REGTYPE),
            (prefix + "config.yaml", b"models: unverified", 0o644, tarfile.REGTYPE),
        ])
        with self.pinned("models-table", archive):
            destination = addons.install_addon("models-table", self.state, archive)
        self.assertEqual({child.name for child in destination.iterdir()}, {"README.md", "LICENSE", addons.RECEIPT_NAME})
        self.assertEqual((destination / "README.md").stat().st_mode & 0o777, 0o444)
        self.assertFalse(json.loads((destination / addons.RECEIPT_NAME).read_text())["import_model_claims"])
        self.assertFalse((self.state / "config.yaml").exists())
        self.assert_clean()

    def test_paths_are_checked_even_for_excluded_payloads(self):
        """Safe paths pass; traversal, absolute, Windows and malformed paths all fail."""
        destination = addons.install_addon("make-feature", self.state, self.skill())
        self.assertTrue((destination / "SKILL.md").exists())
        unsafe = ("../escape", "/absolute", "C:/drive", "scripts\\evil", "scripts/../evil", "scripts//evil", "./evil", "scripts/end.", "scripts/end ", "scripts/new\nline", "a/" * addons.MAX_PATH_DEPTH + "file", "x" * (addons.MAX_PATH_BYTES + 1))
        for name in unsafe:
            with self.subTest(name=name):
                archive = self.skill([(name, b"payload", 0o644, tarfile.REGTYPE)])
                with self.assertRaisesRegex(addons.AddonError, "Unsafe archive path"):
                    addons.install_addon("financial-manager", self.state, archive)
                self.assertFalse((self.state / "skills/financial-manager").exists())
                self.assert_clean()
        self.assertFalse((self.root / "escape").exists())

    def test_tar_links_and_special_files_are_rejected(self):
        """Regular files pass; symlinks, hardlinks, devices and FIFOs fail before publication."""
        destination = addons.install_addon("make-feature", self.state, self.skill())
        self.assertTrue(destination.exists())
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE):
            with self.subTest(kind=kind):
                archive = self.skill([("ignored/payload", b"", 0o644, kind)])
                with self.assertRaisesRegex(addons.AddonError, "links, special"):
                    addons.install_addon("financial-manager", self.state, archive)
                self.assertFalse((self.state / "skills/financial-manager").exists())
                self.assert_clean()

    def test_zip_symlinks_and_special_files_are_rejected(self):
        """Regular ZIP files pass; Unix ZIP symlinks and devices fail."""
        destination = addons.install_addon("make-feature", self.state, self.skill(zipped=True))
        self.assertTrue(destination.exists())
        for mode in (stat.S_IFLNK | 0o777, stat.S_IFIFO | 0o644, stat.S_IFCHR | 0o644):
            archive = self.skill([("scripts/payload", b"../../outside", mode, tarfile.REGTYPE)], zipped=True)
            with self.subTest(mode=mode), self.assertRaises(addons.AddonError):
                addons.install_addon("financial-manager", self.state, archive)
            self.assertFalse((self.state / "skills/financial-manager").exists())
            self.assert_clean()

    def test_zip_original_names_cannot_hide_null_bytes(self):
        """Ordinary ZIP names work; embedded nulls in original header names are rejected."""
        self.assertTrue(addons.install_addon("make-feature", self.state, self.skill(zipped=True)).exists())
        archive = self.skill([("scripts/null.py", b"inert", stat.S_IFREG | 0o644, tarfile.REGTYPE)], zipped=True)
        archive.write_bytes(archive.read_bytes().replace(b"scripts/null.py", b"scripts/\x00ull.py"))
        with self.assertRaisesRegex(addons.AddonError, "Unsafe archive path"):
            addons.install_addon("financial-manager", self.state, archive)
        self.assertFalse((self.state / "skills/financial-manager").exists())
        self.assert_clean()

    def test_duplicate_case_unicode_and_file_directory_collisions(self):
        """Distinct directory members pass; duplicate, case, Unicode and file/tree collisions fail."""
        safe = self.skill([
            ("scripts", b"", 0o755, tarfile.DIRTYPE),
            ("scripts/tool.py", b"inert", 0o644, tarfile.REGTYPE),
        ])
        self.assertTrue(addons.install_addon("make-feature", self.state, safe).exists())
        pairs = (
            ("SKILL.md", "SKILL.md"), ("SKILL.md", "skill.md"),
            ("scripts/one.py", "Scripts/two.py"),
            ("templates/\u00e9.md", "templates/e\u0301.md"),
            ("scripts", "scripts/tool.py"), ("scripts/tool.py", "scripts"),
        )
        for first, second in pairs:
            for zipped in (False, True):
                with self.subTest(first=first, second=second, zipped=zipped):
                    with warnings.catch_warnings():
                        warnings.simplefilter("ignore", UserWarning)
                        archive = self.archive([
                            ("SKILL.md", b"skill", 0o644, tarfile.REGTYPE),
                            (first, b"one", 0o644, tarfile.REGTYPE),
                            (second, b"two", 0o644, tarfile.REGTYPE),
                        ], zipped=zipped)
                    with self.assertRaisesRegex(addons.AddonError, "colliding"):
                        addons.install_addon("financial-manager", self.state, archive)
                    self.assert_clean()

    def test_limits_reject_size_count_and_expansion_bombs(self):
        """Normal archives pass; compressed, expanded, member and count limits fail cleanly."""
        self.assertTrue(addons.install_addon("make-feature", self.state, self.skill()).exists())
        entries = [("templates/data", b"a" * 200, 0o644, tarfile.REGTYPE)]
        cases = (
            ("MAX_ARCHIVE_BYTES", 64, False, False),
            ("MAX_FILE_BYTES", 64, False, True),
            ("MAX_TOTAL_BYTES", 64, True, False),
            ("MAX_MEMBERS", 1, False, False),
            ("MAX_TAR_BYTES", 128, False, True),
        )
        for limit, value, zipped, compressed in cases:
            archive = self.skill(entries, zipped=zipped, compressed=compressed)
            with self.subTest(limit=limit), mock.patch.object(addons, limit, value):
                with self.assertRaisesRegex(addons.AddonError, "limit"):
                    addons.install_addon("financial-manager", self.state, archive)
            self.assertFalse((self.state / "skills/financial-manager").exists())
            self.assert_clean()

    def test_required_files_and_reserved_receipt_are_rejected(self):
        """Valid skill packages pass; empty, incomplete and forged receipt packages fail."""
        self.assertTrue(addons.install_addon("make-feature", self.state, self.skill()).exists())
        for name in (addons.RECEIPT_NAME, addons.RECEIPT_NAME.upper()):
            archive = self.skill([(name, b"forged", 0o644, tarfile.REGTYPE)])
            with self.assertRaisesRegex(addons.AddonError, "Reserved"):
                addons.install_addon("financial-manager", self.state, archive)
        prefix = "hermes-models-table-" + self.catalog["models-table"]["commit"] + "/"
        archive = self.archive([(prefix + "README.md", b"only readme", 0o644, tarfile.REGTYPE)])
        with self.pinned("models-table", archive), self.assertRaisesRegex(addons.AddonError, "required"):
            addons.install_addon("models-table", self.state, archive)
        self.assert_clean()

    def test_state_and_destination_symlinks_never_escape(self):
        """Real private directories work; symlinks at state, ancestors, skills or addon never receive writes."""
        outside = self.root / "outside"
        outside.mkdir()
        archive = self.skill()
        for location in ("state", "ancestor", "skills", "addon"):
            state = self.root / location
            if location == "state":
                state.symlink_to(outside, target_is_directory=True)
            elif location == "ancestor":
                state.symlink_to(outside, target_is_directory=True)
                (outside / "profile").mkdir()
                state = state / "profile"
            else:
                state.mkdir()
                if location == "skills":
                    (state / "skills").symlink_to(outside, target_is_directory=True)
                else:
                    (state / "skills").mkdir()
                    (state / "skills/make-feature").symlink_to(outside, target_is_directory=True)
            before = set(outside.rglob("*"))
            with self.subTest(location=location), self.assertRaises(addons.AddonError):
                addons.install_addon("make-feature", state, archive, update=True)
            self.assertEqual(set(outside.rglob("*")), before)
        self.assertTrue(addons.install_addon("make-feature", self.state, archive).exists())
        self.assert_clean()

    def test_state_argument_is_caller_supplied_and_must_be_absolute_existing(self):
        """Caller-selected profiles work; relative, missing and parent-traversing states fail."""
        archive = self.skill()
        second = self.root / "second-profile"
        second.mkdir()
        destination = addons.install_addon("make-feature", second, archive)
        self.assertEqual(destination, second / "skills/make-feature")
        self.assertEqual(list(self.state.iterdir()), [])
        for state in (Path("relative"), self.root / "missing", self.state / ".." / "second-profile", Path("/")):
            with self.subTest(state=state), self.assertRaises(addons.AddonError):
                addons.install_addon("make-feature", state, archive)

    def test_existing_addon_requires_explicit_update(self):
        """Explicit update replaces a complete package; default installs preserve live content."""
        destination = addons.install_addon("make-feature", self.state, self.skill())
        archive = self.archive([("SKILL.md", b"updated", 0o644, tarfile.REGTYPE)])
        with self.assertRaisesRegex(addons.AddonError, "--update"):
            addons.install_addon("make-feature", self.state, archive)
        self.assertEqual((destination / "SKILL.md").read_bytes(), b"skill")
        addons.install_addon("make-feature", self.state, archive, update=True)
        self.assertEqual((destination / "SKILL.md").read_bytes(), b"updated")
        self.assert_clean()

    def test_failed_update_leaves_live_addon_and_cleans_staging(self):
        """Successful initial install is visible; extraction and publication failures preserve it."""
        destination = addons.install_addon("make-feature", self.state, self.skill())
        archive = self.skill([("../escape", b"bad", 0o644, tarfile.REGTYPE)])
        with self.assertRaises(addons.AddonError):
            addons.install_addon("make-feature", self.state, archive, update=True)
        self.assertEqual((destination / "SKILL.md").read_bytes(), b"skill")
        with mock.patch.object(addons, "_publish", side_effect=OSError("publication failure")):
            with self.assertRaisesRegex(addons.AddonError, "publication failure"):
                addons.install_addon("make-feature", self.state, self.skill(), update=True)
        self.assertEqual((destination / "SKILL.md").read_bytes(), b"skill")
        self.assert_clean()

    def test_stage_is_complete_before_live_directory_changes(self):
        """Publication sees the complete stage and old live package; partial stages never go live."""
        destination = addons.install_addon("make-feature", self.state, self.skill())
        archive = self.archive([("SKILL.md", b"new", 0o644, tarfile.REGTYPE)])
        original = addons._publish

        def publish(source_descriptor, descriptor, stage_name, name, existing):
            stage = Path(f"/proc/self/fd/{source_descriptor}") / stage_name
            self.assertEqual((stage / "SKILL.md").read_bytes(), b"new")
            self.assertTrue((stage / addons.RECEIPT_NAME).is_file())
            self.assertFalse(any(child.name.startswith(".download-") for child in stage.iterdir()))
            self.assertEqual((destination / "SKILL.md").read_bytes(), b"skill")
            self.assertTrue(existing)
            self.assertFalse(any(child.name.startswith(".addon-stage-") for child in (self.state / "skills").iterdir()))
            original(source_descriptor, descriptor, stage_name, name, existing)

        with mock.patch.object(addons, "_publish", side_effect=publish):
            addons.install_addon("make-feature", self.state, archive, update=True)
        self.assertEqual((destination / "SKILL.md").read_bytes(), b"new")
        self.assert_clean()

    def test_profile_lock_covers_private_temporary_staging_and_publish(self):
        """The lock excludes a second writer during extraction/publication and is released afterward."""
        archive = self.skill()
        extract = addons._extract
        publish = addons._publish

        def assert_locked():
            descriptor = os.open(self.state / "skills", addons.DIRECTORY_FLAGS)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(descriptor)

        def extracting(archive_path, stage_descriptor, addon):
            assert_locked()
            real_path = Path(os.path.realpath(archive_path))
            self.assertTrue(real_path.is_relative_to(self.state))
            self.assertFalse(real_path.is_relative_to(self.state / "skills"))
            extract(archive_path, stage_descriptor, addon)

        def publishing(source_descriptor, root_descriptor, stage_name, name, existing):
            assert_locked()
            publish(source_descriptor, root_descriptor, stage_name, name, existing)

        with mock.patch.object(addons, "_extract", side_effect=extracting), mock.patch.object(addons, "_publish", side_effect=publishing):
            self.assertTrue(addons.install_addon("make-feature", self.state, archive).exists())
        descriptor = os.open(self.state / "skills", addons.DIRECTORY_FLAGS)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)
        self.assert_clean()

    def test_symlink_inserted_during_extraction_cannot_escape(self):
        """Normal extraction works; an injected support-directory symlink causes a clean rejection."""
        outside = self.root / "outside"
        outside.mkdir()
        archive = self.skill([("scripts/tool.py", b"inert", 0o644, tarfile.REGTYPE)])
        self.assertTrue(addons.install_addon("make-feature", self.state, archive).exists())
        original = addons._package_directory

        def directory(stage_descriptor, parts):
            if parts == ("scripts",):
                os.symlink(outside, "scripts", dir_fd=stage_descriptor)
            return original(stage_descriptor, parts)

        with mock.patch.object(addons, "_package_directory", side_effect=directory):
            with self.assertRaises(addons.AddonError):
                addons.install_addon("financial-manager", self.state, archive)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((self.state / "skills/financial-manager").exists())
        self.assert_clean()

    def test_concurrent_creation_cannot_overwrite_without_update(self):
        """Unoccupied destination publishes; a destination appearing at publish time is preserved."""
        archive = self.skill()
        original = addons._publish

        def publish(source_descriptor, descriptor, stage_name, name, existing):
            live = self.state / "skills" / name
            live.mkdir()
            (live / "SKILL.md").write_bytes(b"concurrent")
            original(source_descriptor, descriptor, stage_name, name, existing)

        with mock.patch.object(addons, "_publish", side_effect=publish):
            with self.assertRaisesRegex(addons.AddonError, "already exists"):
                addons.install_addon("make-feature", self.state, archive)
        self.assertEqual((self.state / "skills/make-feature/SKILL.md").read_bytes(), b"concurrent")
        self.assertTrue(addons.install_addon("financial-manager", self.state, archive).exists())
        self.assert_clean()

    def test_download_uses_fixed_pin_and_checks_digest_without_execution(self):
        """Exact pinned download succeeds; corrupted bytes fail without leaving a live addon."""
        prefix = "hermes-models-table-" + self.catalog["models-table"]["commit"] + "/"
        archive = self.archive([(prefix + path, b"reference", 0o644, tarfile.REGTYPE) for path in ("README.md", "LICENSE")], compressed=True)
        payload = archive.read_bytes()
        url = addons._github_source(self.catalog["models-table"])
        with self.pinned("models-table", archive):
            with mock.patch.object(addons.urllib.request, "urlopen", return_value=DownloadResponse(payload, url)) as network:
                self.assertTrue(addons.install_addon("models-table", self.state).exists())
                self.assertEqual(network.call_args.args[0].full_url, url)
                self.assertEqual(network.call_args.kwargs["timeout"], addons.DOWNLOAD_TIMEOUT)
            with mock.patch.object(addons.urllib.request, "urlopen", return_value=DownloadResponse(b"corrupt", url)):
                with self.assertRaisesRegex(addons.AddonError, "SHA-256"):
                    addons.install_addon("models-table", self.state, update=True)
        self.assertEqual((self.state / "skills/models-table/README.md").read_bytes(), b"reference")
        self.assert_clean()

    def test_download_redirect_and_size_limit(self):
        """Fixed small replies copy; redirected or oversized replies fail."""
        url = addons._github_source(self.catalog["models-table"])
        with mock.patch.object(addons.urllib.request, "urlopen", return_value=DownloadResponse(b"ok", url)):
            self.assertEqual(addons._download(url, io.BytesIO()), hashlib.sha256(b"ok").hexdigest())
        for payload, reply_url in ((b"ok", "https://other.example/archive"), (b"oversized", url)):
            with mock.patch.object(addons, "MAX_ARCHIVE_BYTES", 4):
                with mock.patch.object(addons.urllib.request, "urlopen", return_value=DownloadResponse(payload, reply_url)):
                    with self.assertRaises(addons.AddonError):
                        addons._download(url, io.BytesIO())

    def test_invalid_archives_and_nonregular_sources_fail_cleanly(self):
        """Regular archives work; corrupt data, directories and FIFOs fail without blocking."""
        self.assertTrue(addons.install_addon("make-feature", self.state, self.skill()).exists())
        corrupt = self.root / "corrupt"
        corrupt.write_bytes(b"not an archive")
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        for source in (corrupt, self.root, fifo):
            with self.subTest(source=source), self.assertRaises(addons.AddonError):
                addons.install_addon("financial-manager", self.state, source)
            self.assertFalse((self.state / "skills/financial-manager").exists())
            self.assert_clean()

    def test_cli_list_install_and_update_are_explicit(self):
        """List has no writes; install/update use explicit state and reject unrequested replacement."""
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(addons.main(["list"]), 0)
        self.assertIn("codex-pool", json.loads(output.getvalue()))
        self.assertEqual(list(self.state.iterdir()), [])
        arguments = ["install", "make-feature", "--state", str(self.state), "--archive", str(self.skill())]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(addons.main(arguments), 0)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as exit_context:
            addons.main(arguments)
        self.assertEqual(exit_context.exception.code, 1)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(addons.main(arguments + ["--update"]), 0)
        self.assert_clean()


if __name__ == "__main__":
    unittest.main()
