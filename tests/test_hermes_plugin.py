#!/usr/bin/env python3
"""The Swan plugin for Hermes (integrations/hermes/swan).

Its hook runs after Hermes's write_file and patch tools and adds what the
edit broke to the tool's result. Hermes is not needed here: the hook is a
plain function, and Swan is stood in for by a folder with a `bin/swan` and a
what-broke script that reports an error for any file holding the word
BROKEN.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
PLUGIN = REPO / "integrations" / "hermes" / "swan"

STAND_IN = """import json, sys
path = json.load(sys.stdin)["tool_input"]["file_path"]
if "BROKEN" in open(path).read():
    print("Swan: this edit introduced an error the language server did not report before:\\n" + path + ":1:1: broken", file=sys.stderr)
    sys.exit(2)
"""


def load_plugin():
    spec = importlib.util.spec_from_file_location("swan_hermes_plugin", PLUGIN / "__init__.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HermesPlugin(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="swan-hermes-"))
        root = self.tmp / "swan"
        (root / "bin").mkdir(parents=True)
        (root / "bin" / "swan").write_text("")
        (root / "scripts" / "hooks").mkdir(parents=True)
        (root / "scripts" / "hooks" / "what-broke-after-edit.py").write_text(STAND_IN)
        (root / "skills" / "swan-code-check").mkdir(parents=True)
        (root / "skills" / "swan-code-check" / "SKILL.md").write_text("---\nname: swan-code-check\ndescription: x\n---\n")
        self.root = root
        self.old = os.environ.get("SWAN_ROOT")
        os.environ["SWAN_ROOT"] = str(root)
        self.plugin = load_plugin()
        self.good = self.tmp / "good.ts"
        self.good.write_text("export const a = 1;\n")
        self.bad = self.tmp / "bad.ts"
        self.bad.write_text("BROKEN\n")

    def tearDown(self):
        if self.old is None:
            os.environ.pop("SWAN_ROOT", None)
        else:
            os.environ["SWAN_ROOT"] = self.old
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_manifest_declares_what_register_registers(self):
        manifest = (PLUGIN / "plugin.yaml").read_text()
        self.assertIn("name: swan", manifest)
        self.assertIn("- transform_tool_result", manifest)
        hooks, skills = [], []

        class Ctx:
            def register_hook(self, name, callback):
                hooks.append((name, callback))

            def register_skill(self, name, path):
                skills.append((name, Path(path)))

        self.plugin.register(Ctx())
        self.assertEqual([name for name, _ in hooks], ["transform_tool_result"])
        self.assertEqual(skills, [("swan-code-check", self.root / "skills" / "swan-code-check" / "SKILL.md")])

    def test_a_clean_edit_leaves_the_result_alone(self):
        result = json.dumps({"bytes_written": 20})
        self.assertIsNone(self.plugin.after_edit(tool_name="write_file", args={"path": str(self.good)}, result=result, status="ok"))

    def test_a_breaking_edit_is_said_inside_a_json_result(self):
        result = json.dumps({"bytes_written": 7, "resolved_path": str(self.bad)})
        out = self.plugin.after_edit(tool_name="write_file", args={"path": "bad.ts"}, result=result, status="ok")
        parsed = json.loads(out)
        self.assertEqual(parsed["bytes_written"], 7)
        self.assertIn("this edit introduced an error", parsed["swan"])
        self.assertIn(str(self.bad), parsed["swan"])

    def test_a_breaking_edit_is_appended_to_a_text_result(self):
        out = self.plugin.after_edit(tool_name="patch", args={"mode": "replace", "path": str(self.bad)}, result="--- a\n+++ b\n", status="ok")
        self.assertTrue(out.startswith("--- a\n+++ b\n\n\nSwan: this edit introduced"))

    def test_the_files_the_tool_names_win_over_the_argument(self):
        result = json.dumps({"files_modified": [str(self.bad)]})
        out = self.plugin.after_edit(tool_name="patch", args={"path": str(self.good)}, result=result, status="ok")
        self.assertIn("broken", json.loads(out)["swan"])

    def test_other_tools_failures_and_blocked_calls_are_left_alone(self):
        bad = {"path": str(self.bad)}
        ok = json.dumps({"bytes_written": 7})
        self.assertIsNone(self.plugin.after_edit(tool_name="read_file", args=bad, result=ok, status="ok"))
        self.assertIsNone(self.plugin.after_edit(tool_name="write_file", args=bad, result=ok, status="blocked"))
        self.assertIsNone(self.plugin.after_edit(tool_name="write_file", args=bad, result=ok, status="error"))
        self.assertIsNone(self.plugin.after_edit(tool_name="write_file", args=bad, result=json.dumps({"error": "refused"}), status="ok"))
        self.assertIsNone(self.plugin.after_edit(tool_name="write_file", args={"path": str(self.tmp / "missing.ts")}, result=ok, status="ok"))

    def test_without_swan_nothing_happens(self):
        os.environ["SWAN_ROOT"] = str(self.tmp / "nowhere")
        out = self.plugin.after_edit(tool_name="write_file", args={"path": str(self.bad)}, result="{}", status="ok")
        self.assertIsNone(out)

    def test_paths_of_a_multi_file_patch(self):
        patch = "*** Begin Patch\n*** Update File: src/a.ts\n@@\n-x\n+y\n*** Add File: src/new.ts\n+z\n*** Move File: old.ts -> src/moved.ts\n*** Delete File: gone.ts\n*** End Patch"
        self.assertEqual(self.plugin.edited_paths("patch", {"mode": "patch", "patch": patch}), ["src/a.ts", "src/new.ts", "src/moved.ts"])
        self.assertEqual(self.plugin.edited_paths("write_file", {"path": "x.py", "content": "*** Update File: no.py"}), ["x.py"])


if __name__ == "__main__":
    unittest.main()
