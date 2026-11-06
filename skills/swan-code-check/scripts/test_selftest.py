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
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True


def load_script(path, name):
    """Load an explicit self-test file so copied skills can be checked independently."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SELFTEST = Path(__file__).with_name("selftest.py")
subject = load_script(SELFTEST, "swan_selftest")


class PortableSelftestTests(unittest.TestCase):
    def setUp(self):
        """Create isolated fixtures for this test and register their cleanup."""
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
        """Verify that path command is resolved to executable file."""
        self.assertEqual(subject.resolve_swan(), str(self.binary.resolve()))
        self.assertEqual(subject.resolve_swan("swan"), str(self.binary.resolve()))

    def test_explicit_binary_overrides_environment(self):
        """Verify that explicit binary overrides environment."""
        os.environ["SWAN_BINARY"] = str(self.folder / "missing")
        self.assertEqual(subject.resolve_swan(str(self.binary)), str(self.binary.resolve()))

    def test_environment_selects_binary_and_does_not_silently_fall_back(self):
        """Verify that environment selects binary and does not silently fall back."""
        alternate = self.folder / "selected-swan"
        shutil.copy2(self.binary, alternate)
        os.environ["SWAN_BINARY"] = "selected-swan"
        self.assertEqual(subject.resolve_swan(), str(alternate.resolve()))
        os.environ["SWAN_BINARY"] = "missing-swan"
        with self.assertRaisesRegex(ValueError, "missing-swan"):
            subject.resolve_swan()

    def test_nonexecutable_file_is_rejected(self):
        """Verify that nonexecutable file is rejected."""
        self.binary.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "not executable"):
            subject.resolve_swan(str(self.binary))

    def test_default_output_is_unique_and_removed_on_failure(self):
        """Verify that default output is unique and removed on failure."""
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
        """Verify that explicit output is retained and nonempty output is preserved."""
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
        """Verify that copied skill uses its own resources and path binary."""
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

    def selection(self, path, **changes):
        """Construct an existing-map MCP response, with optional deliberately invalid fields."""
        payload = {"map": str(path), "built": False}
        payload.update(changes)
        return {"result": {"content": [{"text": json.dumps(payload)}]}}

    def test_select_requires_existing_exact_map_and_disables_build(self):
        """Verify that select requires existing exact map and disables build."""
        expected = self.folder / "swan.db"
        expected.touch()
        client = subject.Swan.__new__(subject.Swan)
        client.rpc = Mock(return_value=self.selection(expected))
        client.select_fixture_map(expected)
        client.rpc.assert_called_once_with("tools/call", {"name": "use_repo", "arguments": {
            "path": str(subject.FIXTURE), "build": False}})

    def test_missing_wrong_rebuilt_and_malformed_maps_are_rejected(self):
        """Verify that missing wrong rebuilt and malformed maps are rejected."""
        expected = self.folder / "swan.db"
        expected.touch()
        wrong = self.folder / "other.db"
        wrong.touch()
        replies = [self.selection(wrong), self.selection(self.folder / "missing.db"),
                   self.selection(expected, built=True), self.selection(123),
                   {"error": {"code": -32603}}, {"result": {"isError": True}},
                   {"result": None}, {"result": {"content": []}},
                   {"result": {"content": [{"text": "not json"}]}},
                   {"result": {"content": [{"text": "[]"}]}}]
        for reply in replies:
            with self.subTest(reply=reply):
                client = subject.Swan.__new__(subject.Swan)
                client.rpc = Mock(return_value=reply)
                with self.assertRaises(ValueError):
                    client.select_fixture_map(expected)

    def test_search_uses_selected_map_without_repository_reselection(self):
        """Verify that search uses selected map without repository reselection."""
        client = subject.Swan.__new__(subject.Swan)
        client.rpc = Mock(return_value={"result": {"content": [{"text": '{"matches": []}'}]}})
        self.assertEqual(client.search("python", "$X"), ({"matches": []}, None))
        client.rpc.assert_called_once_with("tools/call", {"name": "search_pattern",
            "arguments": {"pattern": "$X", "language": "python"}})

    def test_successful_builder_without_usable_map_never_runs_patterns(self):
        """Verify that successful builder without usable map never runs patterns."""
        client = Mock()
        client.select_fixture_map.side_effect = ValueError("cannot select fixture map")
        with patch.object(subject.subprocess, "run", return_value=Mock(returncode=0)), \
                patch.object(subject, "Swan", return_value=client):
            with self.assertRaisesRegex(ValueError, "cannot select fixture map"):
                subject.run(str(self.binary), str(self.binary), self.folder)
        client.search.assert_not_called()
        client.close.assert_called_once_with()


class FixtureMapTests(unittest.TestCase):
    def setUp(self):
        """Keep the concurrent review's end-to-end selection checks in an isolated map registry."""
        self.temp = tempfile.TemporaryDirectory(prefix="swan-map-selection-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.expected = self.folder / "map/swan.db"
        self.expected.parent.mkdir()
        self.expected.touch()

    def run_with_selection(self, selection):
        """Drive run through the real selection method and require cleanup on success or failure."""
        server = subject.Swan.__new__(subject.Swan)
        server.rpc = Mock(return_value=selection)
        server.close = Mock()
        server.search = Mock()
        with patch.object(subject.subprocess, "run") as build, \
                patch.object(subject, "Swan", return_value=server), \
                patch.object(subject, "PACK", Mock(read_text=Mock(return_value='{"patterns": []}'))):
            build.return_value.returncode = 0
            try:
                result = subject.run("server-swan", "map-swan", self.folder)
            finally:
                server.close.assert_called_once_with()
                server.search.assert_not_called()
            self.assertEqual(result, 0)
        server.rpc.assert_called_once_with("tools/call", {
            "name": "use_repo", "arguments": {"path": str(subject.FIXTURE), "build": False}})
        return server

    def test_selects_map_built_by_requested_binary(self):
        """A compatible map from the requested builder passes selection in the complete test flow."""
        self.run_with_selection({"result": {"content": [{"text": json.dumps({
            "map": str(self.expected), "built": False})}], "isError": False}})

    def test_missing_incompatible_or_malformed_map_fails(self):
        """Protocol failures and replacement maps stop the full test flow and close its server."""
        replies = [
            {"result": {"isError": True, "content": [{"text": "no compatible map"}]}},
            {"error": {"message": "unknown tool"}},
            {"result": {"content": []}},
            {"result": {"content": [{"text": "not JSON"}]}},
            {"result": {"content": [{"text": '{"map": null}'}]}},
            {"result": {"content": [{"text": json.dumps({
                "map": str(self.folder / "replacement/swan.db"), "built": False})}]}},
        ]
        for reply in replies:
            with self.subTest(reply=reply), self.assertRaises(ValueError):
                self.run_with_selection(reply)

    def test_pattern_search_keeps_selected_map(self):
        """The private persistent client never reselects a repository during a pattern search."""
        server = subject.Swan.__new__(subject.Swan)
        server.rpc = Mock(return_value={"result": {"content": [{"text": '{"matches": []}'}]}})
        self.assertEqual(server.search("python", "print($X)"), ({"matches": []}, None))
        server.rpc.assert_called_once_with("tools/call", {"name": "search_pattern",
            "arguments": {"pattern": "print($X)", "language": "python"}})


if __name__ == "__main__":
    unittest.main()
