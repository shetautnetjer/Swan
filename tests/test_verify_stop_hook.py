#!/usr/bin/env python3
"""The Claude Code Stop hook (scripts/hooks/verify-before-stop.py).

Drives the real hook against a stand-in gate (`SWAN_VERIFY`, a script that answers as swan-verify would) on a temporary
git repo. No VM is started.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
HOOK = REPO / "scripts" / "hooks" / "verify-before-stop.py"

FAIL = {"verdict": "fail", "new": [
    {"step": "cargo check", "kind": "error", "key": "src/lib.rs: mismatched types", "line": 37, "text": "..."},
    {"step": "cargo test", "kind": "test", "key": "tiles::area", "line": None, "text": "assertion failed: 4 == 5"}]}


class VerifyStopHook(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="swan-stop-hook-")).resolve()
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        git = lambda *a: subprocess.run(["git", "-C", str(self.repo), *a], check=True, capture_output=True)
        git("init", "-q")
        (self.repo / "a.txt").write_text("one\n")
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")
        self.calls = self.tmp / "calls"
        self.gate = self.tmp / "gate"
        self.answer(1, FAIL)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def answer(self, code, result):
        """The stand-in gate: counts its calls, prints `result`, exits `code`."""
        self.gate.write_text(f"#!/bin/sh\necho x >> {self.calls}\necho '{json.dumps(result)}'\nexit {code}\n")
        self.gate.chmod(0o755)

    def stop(self, session="s1", **env):
        e = {"PATH": "/usr/bin:/bin", "HOME": str(self.tmp), "SWAN_VERIFY": str(self.gate), "SWAN_VERIFY_STATE": str(self.tmp / "state"), **env}
        r = subprocess.run([sys.executable, str(HOOK)], input=json.dumps({"session_id": session, "cwd": str(self.repo)}),
                           capture_output=True, text=True, env=e)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout) if r.stdout.strip() else None

    def gate_calls(self):
        return len(self.calls.read_text().splitlines()) if self.calls.exists() else 0

    def test_no_changes_no_gate(self):
        self.assertIsNone(self.stop())
        self.assertEqual(self.gate_calls(), 0)

    def test_new_failures_block_the_stop_with_their_names(self):
        (self.repo / "a.txt").write_text("two\n")
        out = self.stop()
        self.assertEqual(out["decision"], "block")
        self.assertIn("cargo check: src/lib.rs: mismatched types (line 37)", out["reason"])
        self.assertIn("cargo test: tiles::area", out["reason"])
        self.assertIn("assertion failed", out["reason"])

    def test_the_same_changes_are_judged_once(self):
        (self.repo / "a.txt").write_text("two\n")
        self.assertIsNotNone(self.stop())
        self.assertIsNone(self.stop())
        self.assertEqual(self.gate_calls(), 1)
        (self.repo / "new.txt").write_text("a new file\n")
        self.assertIsNotNone(self.stop())
        self.assertEqual(self.gate_calls(), 2)

    def test_a_pass_or_a_gate_that_cannot_judge_lets_the_turn_end(self):
        (self.repo / "a.txt").write_text("two\n")
        self.answer(0, {"verdict": "pass", "new": []})
        self.assertIsNone(self.stop())
        (self.repo / "a.txt").write_text("three\n")
        self.answer(2, {"verdict": "error", "why": "no VM"})
        self.assertIsNone(self.stop())

    def test_blocks_stop_after_the_limit(self):
        for i in range(4):
            (self.repo / "a.txt").write_text(f"v{i}\n")
            out = self.stop(SWAN_VERIFY_MAX_BLOCKS="3")
            self.assertEqual(out is not None, i < 3, f"change {i}")

    def test_outside_a_repo_or_turned_off(self):
        (self.repo / "a.txt").write_text("two\n")
        self.assertIsNone(self.stop(SWAN_VERIFY_HOOK="off"))
        r = subprocess.run([sys.executable, str(HOOK)], input=json.dumps({"cwd": str(self.tmp)}), capture_output=True, text=True)
        self.assertEqual((r.returncode, r.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
