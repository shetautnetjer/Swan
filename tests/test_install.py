"""Bounded installer/doctor regressions. No network or production installation."""

import argparse
import contextlib
import hashlib
import io
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import doctor
import install
import package_support as support


class PackagingTests(unittest.TestCase):
    def setUp(self):
        """Create isolated fixtures for this test and register their cleanup."""
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive = self.make_archive()
        self.prefix = self.root / "new install with spaces"

    def tearDown(self):
        """Remove only the temporary fixtures owned by this test."""
        self.temporary.cleanup()

    def make_archive(self, extra=None, mutate=None):
        """Build a disposable release fixture with optional payload or manifest corruption."""
        payloads = {name: b"fixture\n" for name in install.REQUIRED}
        payloads["bin/swan"] = Path("/usr/bin/true").read_bytes()
        if extra:
            payloads.update(extra)
        metadata = {name: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
                           "mode": 0o755 if name == "bin/swan" else 0o644}
                    for name, data in payloads.items()}
        manifest = {"schema": 1, "platform": {"os": "linux", "architecture": "x86_64", "executable_format": "ELF64", "endianness": "little"},
                    "source_revision": "0" * 40, "binary_sha256": metadata["bin/swan"]["sha256"],
                    "installer_support_sha256": install.sha256(SCRIPTS / "package_support.py"), "files": metadata}
        if mutate:
            mutate(manifest)
        payloads["PACKAGE-MANIFEST.json"] = json.dumps(manifest).encode()
        archive = self.root / "candidate.tar.gz"
        with tarfile.open(archive, "w:gz") as target:
            for name, data in payloads.items():
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                entry.mode = metadata[name]["mode"] if name in metadata else 0o644
                target.addfile(entry, io.BytesIO(data))
        return archive

    def options(self, **changes):
        """Provide isolated core dry-run defaults, allowing each test to override its trigger."""
        values = dict(prefix=self.prefix, archive=self.archive, sha256=install.sha256(self.archive),
                      profile="core", dry_run=True)
        values.update(changes)
        return argparse.Namespace(**values)

    def test_dry_run_has_no_writes_downloads_or_repository_execution(self):
        """Verify that dry run has no writes downloads or repository execution."""
        repository = self.root / "repo"
        repository.mkdir()
        (repository / ".git").mkdir()
        fake = repository / "python3"
        marker = self.root / "executed"
        fake.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\n")
        fake.chmod(0o755)
        before = sorted(str(path) for path in self.root.rglob("*"))
        with patch.dict(os.environ, {"PATH": str(repository), "PYTHONPATH": str(repository), "NODE_OPTIONS": "--require ./bad.js"}):
            with patch.object(install, "download", side_effect=AssertionError("download on dry-run")):
                with contextlib.redirect_stdout(io.StringIO()):
                    install.install(self.options())
        self.assertEqual(before, sorted(str(path) for path in self.root.rglob("*")))
        self.assertFalse(marker.exists())
        self.assertFalse(self.prefix.exists())

    def test_empty_existing_prefix_is_preserved(self):
        """Verify that empty existing prefix is preserved."""
        self.prefix.mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"):
            install.plan(self.options())
        self.assertEqual([], list(self.prefix.iterdir()))

    def test_existing_nonempty_and_symlink_prefix_are_preserved(self):
        """Verify that existing nonempty and symlink prefix are preserved."""
        previous = self.root / "previous"
        previous.mkdir()
        marker = previous / "trusted-repos"
        marker.write_text("keep\n")
        self.prefix.symlink_to(previous, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "already exists"):
            install.plan(self.options())
        self.assertTrue(self.prefix.is_symlink())
        self.assertEqual(marker.read_text(), "keep\n")

    def test_checksum_refusal_leaves_destination_absent(self):
        """Verify that checksum refusal leaves destination absent."""
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            install.plan(self.options(sha256="f" * 64))
        self.assertFalse(self.prefix.exists())

    def test_archive_traversal_and_state_refused(self):
        """Verify that archive traversal and state refused."""
        for name in ("../escape", "/absolute", "data/trusted-repos", "tools/node_modules/evil", ".tools/goose"):
            with self.subTest(name=name):
                archive = self.make_archive({name: b"do not extract"})
                with self.assertRaises(ValueError):
                    install.inspect_archive(archive, install.sha256(archive))
        self.assertFalse((self.root.parent / "escape").exists())

    def test_manifest_or_helper_mismatch_refused(self):
        """Verify that manifest or helper mismatch refused."""
        for mutate in (lambda manifest: manifest["files"]["LICENSE"].update(size=999),
                       lambda manifest: manifest.update(installer_support_sha256="f" * 64),
                       lambda manifest: manifest["platform"].update(architecture="aarch64")):
            archive = self.make_archive(mutate=mutate)
            with self.assertRaises(ValueError):
                install.inspect_archive(archive, install.sha256(archive))

    def test_release_symlink_refused(self):
        """Verify that release symlink refused."""
        archive = self.root / "link.tar"
        with tarfile.open(archive, "w") as target:
            entry = tarfile.TarInfo("tools/link")
            entry.type = tarfile.SYMTYPE
            entry.linkname = "../../outside"
            target.addfile(entry)
        with self.assertRaisesRegex(ValueError, "links/devices"):
            install.inspect_archive(archive, install.sha256(archive))

    def test_wrong_elf_architecture_refused(self):
        """Verify that wrong elf architecture refused."""
        bad = bytearray(Path("/usr/bin/true").read_bytes())
        bad[18:20] = (183).to_bytes(2, "little")
        archive = self.make_archive({"bin/swan": bytes(bad)})
        with self.assertRaisesRegex(ValueError, "ELF"):
            install.inspect_archive(archive, install.sha256(archive))

    def test_platform_and_old_missing_tool_diagnostics(self):
        """Verify that platform and old missing tool diagnostics."""
        with patch.object(support.platform, "system", return_value="Windows"):
            with self.assertRaisesRegex(ValueError, "Unsupported platform"):
                install.plan(self.options())
            report = doctor.report(self.root / "empty", "core")
            self.assertFalse(report["ready"])
            self.assertEqual(report["checks"][0]["status"], "unsupported")
        self.assertFalse(support.compatible("node", "v22.21.0"))
        self.assertTrue(support.compatible("node", "v24.21.0"))
        self.assertFalse(support.compatible("python3", "Python 3.9.20"))
        self.assertEqual(support.probe(None, "bun")["status"], "missing")
        with patch.object(support, "run_checked", return_value="v22.21.0"):
            self.assertEqual(support.probe(Path("/usr/bin/true"), "node")["status"], "incompatible")

    def test_doctor_ignores_fake_repository_python_and_caller_path(self):
        """Verify that doctor ignores fake repository python and caller path."""
        home = self.root / "home"
        install.unpack_release(self.archive, home)
        fake_dir = self.root / "repository/.venv/bin"
        fake_dir.mkdir(parents=True)
        (self.root / "repository/.git").mkdir()
        marker = self.root / "fake-python-ran"
        for name in ("python3", "python", "node", "bun"):
            path = fake_dir / name
            path.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\n")
            path.chmod(0o755)
        before = sorted((str(p), p.read_bytes()) for p in self.root.rglob("*") if p.is_file())
        with patch.dict(os.environ, {"PATH": str(fake_dir), "PYTHONPATH": str(fake_dir)}):
            result = doctor.report(home, "python-typescript")
        self.assertFalse(result["ready"])
        self.assertFalse(marker.exists())
        self.assertEqual(before, sorted((str(p), p.read_bytes()) for p in self.root.rglob("*") if p.is_file()))
        interpreter = next(item for item in result["checks"] if item["name"] == "python3")
        self.assertNotIn("repository", interpreter["path"] or "")

    def test_doctor_core_does_not_require_optional_tools(self):
        """Verify that doctor core does not require optional tools."""
        home = self.root / "core"
        install.unpack_release(self.archive, home)
        result = doctor.report(home, "core")
        self.assertTrue(result["ready"])
        self.assertTrue(all(not item["required"] for item in result["checks"] if item["status"] == "unselected"))

    def test_doctor_rejects_abbreviated_home_before_probing(self):
        """Verify that doctor rejects abbreviated home before probing."""
        for arguments in (("--hom", str(self.root / "repo")), ("--ho=" + str(self.root / "repo"),)):
            with self.subTest(arguments=arguments), patch.object(doctor, "report", side_effect=AssertionError("unexpected probe")):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                    doctor.main(["--home", str(self.root), *arguments])
                self.assertEqual(error.exception.code, 2)

    def test_safe_system_lookup_rejects_repo_symlink(self):
        """Verify that safe system lookup rejects repo symlink."""
        repository = self.root / "repository"
        repository.mkdir()
        (repository / ".git").mkdir()
        target = repository / "node"
        shutil.copyfile("/usr/bin/true", target)
        target.chmod(0o755)
        first = self.root / "system-looking"
        first.mkdir()
        (first / "node").symlink_to(target)
        with patch.object(support, "SAFE_PATH", str(first)):
            self.assertIsNone(support.system_tool("node"))

    def test_atomic_activation_never_replaces_concurrent_empty_directory(self):
        """Verify that atomic activation never replaces concurrent empty directory."""
        stage = self.root / "stage"
        stage.mkdir()
        (stage / "candidate").write_text("ours")
        self.prefix.mkdir()
        with self.assertRaises(OSError):
            install.atomic_activate(stage, self.prefix)
        self.assertEqual([], list(self.prefix.iterdir()))
        self.assertEqual((stage / "candidate").read_text(), "ours")

    def test_failed_smoke_cleans_only_owned_staging(self):
        """Verify that failed smoke cleans only owned staging."""
        untouched = self.root / "unrelated"
        untouched.write_text("preserve")
        with patch.object(install, "run_checked", side_effect=RuntimeError("deliberate smoke failure")):
            with self.assertRaisesRegex(RuntimeError, "deliberate smoke failure"):
                with contextlib.redirect_stdout(io.StringIO()):
                    install.install(self.options(dry_run=False))
        self.assertFalse(self.prefix.exists())
        self.assertFalse(list(self.root.glob(".swan-install-*")))
        self.assertEqual(untouched.read_text(), "preserve")

    def test_runtime_environment_drops_interpreter_and_npm_injections(self):
        """Verify that runtime environment drops interpreter and npm injections."""
        with patch.dict(os.environ, {"NODE_OPTIONS": "--require bad", "PYTHONPATH": ".", "NPM_CONFIG_PREFIX": "/global"}):
            environment = support.clean_env(self.root, self.root / "state")
        for key in ("NODE_OPTIONS", "PYTHONPATH", "NPM_CONFIG_PREFIX"):
            self.assertNotIn(key, environment)
        self.assertNotIn("HOME", environment)
        self.assertNotEqual(environment["npm_config_userconfig"], environment["npm_config_globalconfig"])
        self.assertEqual(environment["PATH"], str(self.root / ".tools/runtime/bin") + ":" + support.SAFE_PATH)
        with patch.dict(os.environ, {"HTTPS_PROXY": "http://proxy.invalid:8080"}):
            self.assertNotIn("HTTPS_PROXY", support.clean_env())
            self.assertEqual(support.clean_env(network=True)["HTTPS_PROXY"], "http://proxy.invalid:8080")

    def test_musl_and_old_glibc_are_reported_as_unsupported_prerequisites(self):
        """Verify that musl and old glibc are reported as unsupported prerequisites."""
        for value in (("musl", "1.2.5"), ("glibc", "2.27")):
            with self.subTest(libc=value), patch.object(support.platform, "libc_ver", return_value=value):
                self.assertIn("Unsupported libc", support.platform_error())
                with self.assertRaisesRegex(ValueError, "Unsupported libc"):
                    install.plan(self.options())

    def test_actual_builder_output_is_accepted_by_installer(self):
        """Verify that actual builder output is accepted by installer."""
        spec = importlib.util.spec_from_file_location("swan_test_package", SCRIPTS / "package.py")
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        source = self.root / "source"
        source.mkdir()
        for name in (*builder.RUNTIME_FILES, builder.INSTALLER, "skills/swan-code-check/SKILL.md"):
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            original = SCRIPTS.parent / name
            if original.is_file():
                shutil.copyfile(original, path)
            else:
                path.write_text("builder contract fixture " + name + "\n")
        def git(*arguments):
            """Run Git against this checkout and fail if the requested operation fails."""
            return subprocess.check_output(["git", "-C", str(source), *arguments], text=True).strip()
        git("init", "--quiet")
        git("add", ".")
        git("-c", "user.name=Installer Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "fixture")
        revision = git("rev-parse", "HEAD")
        binary = Path("/usr/bin/true")
        receipt = self.root / "build.json"
        receipt.write_text(json.dumps({"source_revision": revision, "binary_sha256": install.sha256(binary)}))
        licenses = self.root / "licenses"
        licenses.mkdir()
        (licenses / "test-license").write_text("fixture license\n")
        output = self.root / "builder-output"
        built = builder.build_package(source, binary, output, revision, receipt, licenses)
        archive = output / builder.ARCHIVE
        checked = install.inspect_archive(archive, install.sha256(archive))
        self.assertEqual(built, checked)


if __name__ == "__main__":
    unittest.main()
