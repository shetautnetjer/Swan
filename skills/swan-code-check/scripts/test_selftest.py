#!/usr/bin/env python3
"""Portable self-test infrastructure checks; no Swan or indexer required."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True


def load_script(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SELFTEST = Path(__file__).with_name("selftest.py")
subject = load_script(SELFTEST, "swan_selftest")


class PortableSelftestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="swan-skill-portability-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.binary = self.folder / "swan"
        self.binary.write_text("#!/bin/sh\nexit 0\n")
        self.binary.chmod(0o755)
        self.environment = patch.dict(os.environ, {"PATH": str(self.folder)}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_path_command_is_resolved_to_executable_file(self):
        self.assertEqual(subject.resolve_swan(), str(self.binary.resolve()))
        self.assertEqual(subject.resolve_swan("swan"), str(self.binary.resolve()))

    def test_explicit_binary_overrides_environment(self):
        os.environ["SWAN_BINARY"] = str(self.folder / "missing")
        self.assertEqual(subject.resolve_swan(str(self.binary)), str(self.binary.resolve()))

    def test_environment_selects_binary_and_does_not_silently_fall_back(self):
        alternate = self.folder / "selected-swan"
        shutil.copy2(self.binary, alternate)
        os.environ["SWAN_BINARY"] = "selected-swan"
        self.assertEqual(subject.resolve_swan(), str(alternate.resolve()))
        os.environ["SWAN_BINARY"] = "missing-swan"
        with self.assertRaisesRegex(ValueError, "missing-swan"):
            subject.resolve_swan()

    def test_nonexecutable_file_is_rejected(self):
        self.binary.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "not executable"):
            subject.resolve_swan(str(self.binary))

    def test_default_output_is_unique_and_removed_on_failure(self):
        allocated = []
        with self.assertRaisesRegex(RuntimeError, "test failure"):
            with subject.output_directory() as first:
                allocated.append(first)
                with subject.output_directory() as second:
                    allocated.append(second)
                    self.assertNotEqual(first, second)
                    (first / "generated").write_text("temporary")
                raise RuntimeError("test failure")
        self.assertTrue(all(not folder.exists() for folder in allocated))

    def test_explicit_output_is_retained_and_nonempty_output_is_preserved(self):
        destination = self.folder / "retained"
        with subject.output_directory(destination) as folder:
            marker = folder / "existing"
            marker.write_text("preserve")
        self.assertEqual(marker.read_text(), "preserve")
        with self.assertRaisesRegex(ValueError, "new or empty"):
            with subject.output_directory(destination):
                self.fail("nonempty output must not be used")
        self.assertEqual(marker.read_text(), "preserve")

    def test_copied_skill_uses_its_own_resources_and_path_binary(self):
        destination = self.folder / "copied-skill"
        shutil.copytree(SELFTEST.parent.parent, destination,
                        ignore=shutil.ignore_patterns("__pycache__"))
        copied = load_script(destination / "scripts" / "selftest.py", "copied_swan_selftest")
        self.assertEqual(copied.HERE, destination.resolve())
        self.assertEqual(copied.resolve_swan(), str(self.binary.resolve()))
        tags = copied.tag_lines()
        pack = json.loads(copied.PACK.read_text())
        self.assertEqual(len(pack["patterns"]), 24)
        self.assertTrue(all(set(entry["expect"]) <= tags.keys() for entry in pack["patterns"]))


if __name__ == "__main__":
    unittest.main()
