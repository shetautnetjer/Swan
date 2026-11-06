"""Candidate archive contract tests; no compilation, installation, or network."""

import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("swan_package", Path(__file__).resolve().parents[1] / "scripts/package.py")
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


def elf_header(machine=62):
    """Construct a minimal ELF fixture for format validation, not runtime execution."""
    identity = b"\x7fELF\x02\x01\x01" + bytes(9)
    return identity + struct.pack("<HHIQQQIHHHHHH", 2, machine, 1, 0x400078,
                                  64, 0, 0, 64, 56, 1, 0, 0, 0) + struct.pack(
        "<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 121, 121, 4096) + b"\xc3"


class PackageTests(unittest.TestCase):
    def setUp(self):
        """Create isolated fixtures for this test and register their cleanup."""
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "source"
        self.root.mkdir()
        for name in (*package.RUNTIME_FILES, package.INSTALLER,
                     "scripts/verify-live-trust.py", "skills/swan-code-check/SKILL.md",
                     "skills/swan-code-check/fixture/sec.py"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture " + name + "\n")
        (self.root / package.INSTALLER).chmod(0o755)
        self.git("init", "--quiet")
        self.git("add", ".")
        self.git("-c", "user.name=Package Test", "-c", "user.email=test@example.invalid",
                 "commit", "--quiet", "-m", "test snapshot")
        self.revision = self.git("rev-parse", "HEAD").strip()
        self.binary = self.base / "swan"
        self.binary.write_bytes(elf_header())
        self.binary.chmod(0o755)
        self.receipt = self.base / "receipt.json"
        self.write_receipt()
        self.licenses = self.base / "licenses"
        self.licenses.mkdir()
        (self.licenses / "Goose-LICENSE").write_text("test compiled license\n")
        self.output = self.base / "candidate artifacts"

    def git(self, *arguments):
        """Run Git against this checkout and fail if the requested operation fails."""
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], text=True)

    def write_receipt(self, **values):
        """Bind the fixture receipt to its current revision and binary, with optional corruptions."""
        self.receipt.write_text(json.dumps({"source_revision": self.revision,
                                           "binary_sha256": package.sha256(self.binary.read_bytes()),
                                           **values}))

    def build(self, **overrides):
        """Export the isolated fixture using test defaults and explicitly requested overrides."""
        values = {"root": self.root, "binary": self.binary, "output": self.output,
                  "revision": self.revision, "receipt_path": self.receipt,
                  "licenses": self.licenses, "required_licenses": ["Goose-LICENSE"]}
        values.update(overrides)
        return package.build_package(**values)

    def test_inventory_checksums_modes_and_candidate_provenance(self):
        """Verify that inventory checksums modes and candidate provenance."""
        manifest = self.build()
        expected = {*package.RUNTIME_FILES, "scripts/verify-live-trust.py", "bin/swan",
                    "BUILD-RECEIPT.json", "licenses/Goose-LICENSE",
                    "skills/swan-code-check/SKILL.md", "skills/swan-code-check/fixture/sec.py"}
        with tarfile.open(self.output / package.ARCHIVE) as archive:
            self.assertEqual(set(archive.getnames()), expected | {package.MANIFEST})
            self.assertIn("docs/install.md", archive.getnames())
            self.assertTrue(all(member.isfile() for member in archive.getmembers()))
            recorded = json.load(archive.extractfile(package.MANIFEST))
            self.assertEqual(recorded, manifest)
            self.assertEqual(set(recorded["files"]), expected)
            for name, record in recorded["files"].items():
                data = archive.extractfile(name).read()
                self.assertEqual(package.sha256(data), record["sha256"])
                self.assertEqual(len(data), record["size"])
                self.assertEqual(archive.getmember(name).mode, record["mode"])
            self.assertEqual(archive.getmember("bin/swan").mode, 0o755)
            self.assertEqual(archive.extractfile("BUILD-RECEIPT.json").read(), self.receipt.read_bytes())
        self.assertEqual(manifest["source_revision"], self.revision)
        self.assertEqual(manifest["artifact_status"], "candidate")
        self.assertEqual(manifest["platform"]["architecture"], "x86_64")
        self.assertTrue(manifest["tracked_source_clean"])
        for name in (package.ARCHIVE, "install.py", "package_support.py"):
            self.assertEqual((self.output / (name + ".sha256")).read_text(),
                             package.sha256((self.output / name).read_bytes()) + "  " + name + "\n")
        self.assertEqual((self.output / "install.py").read_bytes(),
                         (self.root / package.INSTALLER).read_bytes())
        self.assertEqual(manifest["installer_support_sha256"],
                         package.sha256((self.output / "package_support.py").read_bytes()))

    def test_private_and_generated_inputs_never_enter_archive(self):
        """Verify that private and generated inputs never enter archive."""
        for name in (".env", "data/trusted-repos", ".tools/private", "tools/node_modules/secret",
                     "skills/swan-code-check/untracked-token", "other/private"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("private value")
        # A tracked unrelated secret still must not enter the fixed runtime inventory.
        self.git("add", "other/private")
        self.git("-c", "user.name=Package Test", "-c", "user.email=test@example.invalid",
                 "commit", "--quiet", "-m", "unrelated fixture")
        self.revision = self.git("rev-parse", "HEAD").strip()
        self.write_receipt()
        self.build()
        with tarfile.open(self.output / package.ARCHIVE) as archive:
            names = archive.getnames()
            self.assertNotIn("other/private", names)
            self.assertFalse(any("trusted-repos" in name or "node_modules" in name or ".tools" in name
                                 or "untracked-token" in name or ".env" in name for name in names))

    def test_existing_destination_is_preserved(self):
        """Verify that existing destination is preserved."""
        self.output.mkdir()
        marker = self.output / "keep"
        marker.write_text("unchanged")
        with self.assertRaisesRegex(package.PackageError, "already exists"):
            self.build()
        self.assertEqual(marker.read_text(), "unchanged")
        self.assertEqual(list(self.output.iterdir()), [marker])

    def test_dirty_or_staged_tracked_source_is_refused(self):
        """Verify that dirty or staged tracked source is refused."""
        (self.root / "LICENSE").write_text("changed")
        for staged in (False, True):
            if staged:
                self.git("add", "LICENSE")
            with self.assertRaisesRegex(package.PackageError, "dirty"):
                self.build()
        self.assertFalse(self.output.exists())

    def test_source_revision_and_receipt_must_bind_exact_binary(self):
        """Verify that source revision and receipt must bind exact binary."""
        for revision in ("HEAD", "../escape", "0" * 40):
            with self.subTest(revision=revision), self.assertRaises(package.PackageError):
                self.build(revision=revision)
        self.write_receipt(binary_sha256="0" * 64)
        with self.assertRaisesRegex(package.PackageError, "receipt"):
            self.build()
        self.write_receipt(source_revision="0" * 40)
        with self.assertRaisesRegex(package.PackageError, "receipt"):
            self.build()
        self.assertFalse(self.output.exists())

    def test_invalid_binary_isa_format_or_permissions_is_refused(self):
        """Verify that invalid binary isa format or permissions is refused."""
        for data in (b"#!/bin/sh\n", elf_header(183), b"MZ" + bytes(100), elf_header()[:20],
                     elf_header()[:64], elf_header()[:-1]):
            self.binary.write_bytes(data)
            self.write_receipt()
            with self.subTest(data=data[:20]), self.assertRaisesRegex(package.PackageError, "ELF64"):
                self.build()
        self.binary.write_bytes(elf_header())
        self.binary.chmod(0o644)
        self.write_receipt()
        with self.assertRaisesRegex(package.PackageError, "not executable"):
            self.build()

    def test_missing_required_license_and_unsafe_license_path_fail_without_output(self):
        """Verify that missing required license and unsafe license path fail without output."""
        for name in ("missing-LICENSE", "../outside", "/absolute", "folder\\escape", "C:/outside"):
            with self.subTest(name=name), self.assertRaises(package.PackageError):
                self.build(required_licenses=[name])
        self.assertFalse(self.output.exists())

    def test_symlink_inputs_are_refused(self):
        """Verify that symlink inputs are refused."""
        linked = self.base / "linked-swan"
        linked.symlink_to(self.binary)
        with self.assertRaisesRegex(package.PackageError, "symlink"):
            self.build(binary=linked)
        (self.licenses / "linked-LICENSE").symlink_to(self.root / "LICENSE")
        with self.assertRaisesRegex(package.PackageError, "symlink"):
            self.build()

    def test_untracked_required_runtime_cannot_be_included(self):
        """Verify that untracked required runtime cannot be included."""
        self.git("rm", "--cached", "scripts/doctor.py")
        self.git("-c", "user.name=Package Test", "-c", "user.email=test@example.invalid",
                 "commit", "--quiet", "-m", "remove required runtime")
        self.revision = self.git("rev-parse", "HEAD").strip()
        self.write_receipt()
        with self.assertRaisesRegex(package.PackageError, "not tracked"):
            self.build()

    def test_identical_inputs_produce_identical_archives(self):
        """Verify that identical inputs produce identical archives."""
        self.build()
        other = self.base / "second export"
        self.build(output=other)
        self.assertEqual((self.output / package.ARCHIVE).read_bytes(), (other / package.ARCHIVE).read_bytes())


if __name__ == "__main__":
    unittest.main()
