#!/usr/bin/env python3
"""swan serve moves to a new build by itself.

Lays out two versions the way swan-up does (<root>/versions/<v>/bin/swan and
a <root>/current link), starts the server through the link, points the link
at the other version and checks the same process now runs the new build, has
told the agent its tools may have changed, kept the selected repo, and lost
no request, including requests sent together at the moment of the switch.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent


class ServeRestart(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="swan-restart-"))
        for v in ("A", "B"):
            d = self.tmp / "versions" / v
            (d / "bin").mkdir(parents=True)
            shutil.copy2(REPO / "bin" / "swan", d / "bin" / "swan")
            for sub in ("tools", ".tools"):
                os.symlink(REPO / sub, d / sub)
        os.symlink("versions/A", self.tmp / "current")
        shutil.copytree(REPO / "fixtures" / "tiny-py", self.tmp / "repo")
        subprocess.run([str(REPO / "bin" / "swan"), "map", str(self.tmp / "repo"), str(self.tmp / "maps" / "repo")],
                       check=True, capture_output=True, timeout=600)
        env = dict(os.environ)
        env.pop("SWAN_NO_RESTART", None)
        self.proc = subprocess.Popen([str(self.tmp / "current" / "bin" / "swan"), "serve", "--maps", str(self.tmp / "maps")],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     text=True, bufsize=1, env=env)

    def tearDown(self):
        if self.proc.poll() is None:
            self.proc.stdin.close()
            self.proc.wait(timeout=30)
        self.proc.stdout.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def send(self, *msgs):
        self.proc.stdin.write("".join(json.dumps(m) + "\n" for m in msgs))
        self.proc.stdin.flush()

    def read(self):
        line = self.proc.stdout.readline()
        self.assertTrue(line, "the server closed its output")
        return json.loads(line)

    def call(self, i, name, args):
        return {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}}

    def exe(self):
        return os.readlink(f"/proc/{self.proc.pid}/exe")

    def flip(self):
        os.symlink("versions/B", self.tmp / "current.new")
        os.replace(self.tmp / "current.new", self.tmp / "current")

    def start(self):
        self.send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        self.assertEqual(self.read()["result"]["capabilities"]["tools"], {"listChanged": True})
        self.send(self.call(2, "use_repo", {"path": str(self.tmp / "repo")}))
        self.assertFalse(self.read()["result"]["isError"])
        self.assertTrue(self.exe().endswith("/versions/A/bin/swan"))

    def test_moves_after_an_answer_and_keeps_the_repo(self):
        self.start()
        self.flip()
        self.send({"jsonrpc": "2.0", "id": 3, "method": "ping", "params": {}})
        self.assertEqual(self.read()["id"], 3)
        self.assertEqual(self.read(), {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        self.send(self.call(4, "find_symbol", {"name_path_pattern": "total_area"}))
        r = self.read()
        self.assertEqual(r["id"], 4)
        self.assertFalse(r["result"]["isError"], r)
        self.assertIn("shapes/__init__.py", r["result"]["content"][0]["text"])
        self.assertTrue(self.exe().endswith("/versions/B/bin/swan"))
        self.assertIsNone(self.proc.poll())

    def test_requests_sent_together_are_all_answered(self):
        self.start()
        self.flip()
        # Three requests in one write: none may be lost.
        self.send({"jsonrpc": "2.0", "id": 3, "method": "ping", "params": {}},
                  self.call(4, "find_symbol", {"name_path_pattern": "total_area"}),
                  {"jsonrpc": "2.0", "id": 5, "method": "ping", "params": {}})
        # The move waits while requests sit read ahead, so its notice comes
        # after the last of the three answers, before anything else.
        ids, notices = [], 0
        while len(ids) < 3 or notices == 0:
            m = self.read()
            if "id" in m:
                ids.append(m["id"])
                if m["id"] == 4:
                    self.assertFalse(m["result"]["isError"], m)
            else:
                self.assertEqual(m["method"], "notifications/tools/list_changed")
                notices += 1
        self.assertEqual(ids, [3, 4, 5])
        self.assertEqual(notices, 1)
        self.send({"jsonrpc": "2.0", "id": 6, "method": "ping", "params": {}})
        self.assertEqual(self.read(), {"jsonrpc": "2.0", "id": 6, "result": {}})
        self.assertTrue(self.exe().endswith("/versions/B/bin/swan"))

    def test_a_binary_rewritten_in_place_is_not_restarted(self):
        self.start()
        target = self.tmp / "versions" / "A" / "bin" / "swan"
        data = target.read_bytes()
        target.unlink()               # as a rebuild in place leaves it: the running file is "(deleted)"
        target.write_bytes(data)
        target.chmod(0o755)
        self.send({"jsonrpc": "2.0", "id": 3, "method": "ping", "params": {}})
        self.assertEqual(self.read()["id"], 3)
        self.send({"jsonrpc": "2.0", "id": 4, "method": "ping", "params": {}})
        self.assertEqual(self.read(), {"jsonrpc": "2.0", "id": 4, "result": {}})


if __name__ == "__main__":
    unittest.main()
