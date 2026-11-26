#!/usr/bin/env python3
"""The Claude Code post-edit hook (scripts/hooks/what-broke-after-edit.py).

Drives the real hook script against a stand-in `swan` binary (`SWAN_BIN`) and
a map folder (`SWAN_MAPS`) whose `swan.db` has the `meta` table pointing at a
temporary repo root. No real Swan or language server is started.
"""
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
HOOK = REPO / "scripts" / "hooks" / "what-broke-after-edit.py"


class WhatBrokeHook(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="swan-hook-")).resolve()
        self.repo = self.tmp / "repo"
        (self.repo / "src").mkdir(parents=True)
        self.py_file = self.repo / "src" / "app.py"
        self.py_file.write_text("x = 1\n")
        self.rs_file = self.repo / "src" / "lib.rs"
        self.rs_file.write_text("pub fn f() {}\n")
        self.md_file = self.repo / "README.md"
        self.md_file.write_text("# hi\n")

        self.maps = self.tmp / "maps"
        map_dir = self.maps / "demo"
        map_dir.mkdir(parents=True)
        conn = sqlite3.connect(map_dir / "swan.db")
        conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
        conn.execute("INSERT INTO meta (key, value) VALUES ('root', ?)", (str(self.repo),))
        conn.commit()
        conn.close()

        self.answer_file = self.tmp / "answer.json"
        self.code_file = self.tmp / "exit_code"
        self.swan = self.tmp / "fake-swan"
        self.swan.write_text(
            f"#!{sys.executable}\n"
            "import sys\n"
            f"sys.stdout.write(open({str(self.answer_file)!r}).read())\n"
            f"sys.exit(int(open({str(self.code_file)!r}).read().strip()))\n"
        )
        self.swan.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_hook(self, target: Path, answer: dict, exit_code: int):
        self.answer_file.write_text(json.dumps(answer))
        self.code_file.write_text(str(exit_code))
        return subprocess.run(
            [sys.executable, "-I", str(HOOK)],
            input=json.dumps({"tool_input": {"file_path": str(target)}}),
            capture_output=True,
            text=True,
            env={"SWAN_BIN": str(self.swan), "SWAN_MAPS": str(self.maps)},
        )

    def test_new_errors(self):
        answer = {
            "new_errors": 1,
            "files": [{
                "relative_path": "src/app.py",
                "asked": True,
                "first_look": False,
                "new_errors": [{"line": 12, "col": 4, "message": "type mismatch\nextra detail"}],
                "errors_already_there": 0,
                "warnings": 0,
            }],
        }
        r = self.run_hook(self.py_file, answer, 1)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stdout, "")
        self.assertIn("this edit introduced an error", r.stderr)
        self.assertIn("src/app.py:12:4: type mismatch", r.stderr)
        self.assertNotIn("extra detail", r.stderr)
        self.assertNotIn("Errors from this edit will not be reported here", r.stderr)

    def test_first_time_untrusted_note(self):
        answer = {
            "new_errors": 0,
            "files": [{
                "relative_path": "src/lib.rs",
                "asked": False,
                "reason": "untrusted",
                "first_time": True,
                "why": "rust-analyzer did not run: run `swan trust /repo` to allow it",
            }],
        }
        r = self.run_hook(self.rs_file, answer, 3)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stderr, "")
        self.assertTrue(r.stdout.strip(), "expected PostToolUse JSON on stdout")
        parsed = json.loads(r.stdout)
        hook_out = parsed["hookSpecificOutput"]
        self.assertEqual(hook_out["hookEventName"], "PostToolUse")
        self.assertEqual(
            hook_out["additionalContext"],
            "Swan did not check src/lib.rs: checks that run this repo's build are off for it by its owner's choice.\n"
            "Errors from this edit will not be reported here; verify another way.",
        )
        self.assertNotIn("swan trust", (r.stdout + r.stderr).lower())
        self.assertNotIn("rust-analyzer did not run", r.stdout + r.stderr)

    def test_unsettled_and_failed_notes(self):
        cases = [
            ("unsettled", "its language server did not settle in time."),
            ("failed", "its language server did not answer."),
        ]
        for reason, detail in cases:
            with self.subTest(reason=reason):
                answer = {
                    "new_errors": 0,
                    "files": [{
                        "relative_path": "src/lib.rs",
                        "asked": False,
                        "reason": reason,
                        "first_time": True,
                        "why": f"internal {reason} detail; try swan trust",
                    }],
                }
                r = self.run_hook(self.rs_file, answer, 3)
                self.assertEqual(r.returncode, 0)
                self.assertEqual(r.stderr, "")
                parsed = json.loads(r.stdout)
                self.assertEqual(
                    parsed["hookSpecificOutput"],
                    {
                        "hookEventName": "PostToolUse",
                        "additionalContext": (
                            f"Swan did not check src/lib.rs: {detail}\n"
                            "Errors from this edit will not be reported here; verify another way."
                        ),
                    },
                )
                self.assertNotIn("internal", r.stdout + r.stderr)
                self.assertNotIn("swan trust", (r.stdout + r.stderr).lower())

    def test_second_time_untrusted_is_silent(self):
        answer = {
            "new_errors": 0,
            "files": [{
                "relative_path": "src/lib.rs",
                "asked": False,
                "reason": "untrusted",
                "first_time": False,
                "why": "rust-analyzer did not run: run `swan trust /repo`",
            }],
        }
        r = self.run_hook(self.rs_file, answer, 3)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertEqual(r.stderr, "")

    def test_no_server_is_silent(self):
        answer = {
            "new_errors": 0,
            "files": [{
                "relative_path": "README.md",
                "asked": False,
                "reason": "no_server",
                "why": "no live server for README.md",
            }],
        }
        r = self.run_hook(self.md_file, answer, 3)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertEqual(r.stderr, "")

    def test_errors_and_note_together(self):
        answer = {
            "new_errors": 1,
            "files": [
                {
                    "relative_path": "src/app.py",
                    "asked": True,
                    "first_look": False,
                    "new_errors": [{"line": 5, "col": 1, "message": "bad call"}],
                    "errors_already_there": 0,
                    "warnings": 0,
                },
                {
                    "relative_path": "src/lib.rs",
                    "asked": False,
                    "reason": "untrusted",
                    "first_time": True,
                    "why": "rust-analyzer did not run: run `swan trust /repo`",
                },
            ],
        }
        r = self.run_hook(self.py_file, answer, 1)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stdout, "")
        self.assertIn("src/app.py:5:1: bad call", r.stderr)
        note = "Swan did not check src/lib.rs: checks that run this repo's build are off for it by its owner's choice."
        # Beside errors that are reported, the closing line speaks of the file not checked only.
        footer = "Errors in a file Swan did not check will not be reported here; verify those another way."
        self.assertIn(note, r.stderr)
        self.assertIn(footer, r.stderr)
        self.assertNotIn("Errors from this edit will not be reported", r.stderr)
        self.assertLess(r.stderr.index("src/app.py:5:1: bad call"), r.stderr.index(note))
        self.assertLess(r.stderr.index(note), r.stderr.index(footer))
        self.assertNotIn("swan trust", (r.stdout + r.stderr).lower())
        self.assertNotIn("rust-analyzer did not run", r.stdout + r.stderr)

    def test_a_reason_the_hook_does_not_know_is_named_not_guessed(self):
        answer = {"new_errors": 0, "files": [
            {"relative_path": "src/lib.rs", "asked": False, "reason": "locked", "first_time": True, "why": "x"}]}
        r = self.run_hook(self.rs_file, answer, 3)
        self.assertEqual(r.returncode, 0)
        note = json.loads(r.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertIn('Swan did not check src/lib.rs: the reason given is "locked".', note)
        self.assertNotIn("did not answer", note)

    def test_an_exit_code_the_hook_does_not_know_still_has_its_answer_read(self):
        answer = {"new_errors": 1, "files": [
            {"relative_path": "src/app.py", "asked": True, "first_look": False,
             "new_errors": [{"line": 5, "col": 1, "message": "bad call"}], "errors_already_there": 0, "warnings": 0}]}
        r = self.run_hook(self.py_file, answer, 9)
        self.assertEqual(r.returncode, 2)
        self.assertIn("src/app.py:5:1: bad call", r.stderr)

    def test_entry_without_reason_is_silent(self):
        for entry in (
            {"relative_path": "src/lib.rs", "asked": False, "why": "older swan"},
            {"relative_path": "src/lib.rs", "asked": False, "first_time": True, "why": "older swan"},
        ):
            with self.subTest(entry=entry):
                answer = {"new_errors": 0, "files": [entry]}
                r = self.run_hook(self.rs_file, answer, 0)
                self.assertEqual(r.returncode, 0)
                self.assertEqual(r.stdout, "")
                self.assertEqual(r.stderr, "")


if __name__ == "__main__":
    unittest.main()
