#!/usr/bin/env python3
"""Qualify per-request implicit-build policy with isolated synthetic tools.

Copies the supplied Swan binary into a new disposable installation. Its fake
TypeScript indexer and flattener record invocations and produce known rows; no
real indexer, package installation, language server or trust operation runs.
The supplied installation is never modified. Artifacts and transcripts remain
available after failure, including when testing a baseline lacking the policy.
"""

import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

from check_concurrency import MCP, child_environment, connect, require


SENTINEL = r'''import json, os, sys
from pathlib import Path
home, mode = Path(sys.argv[1]), sys.argv[2]
args = sys.argv[3:]
with (home / 'invocations.jsonl').open('a') as stream:
    stream.write(json.dumps({'mode': mode, 'cwd': os.getcwd(), 'args': args, 'pid': os.getpid()}) + '\n')
if mode == 'indexer':
    assert args[0] == 'index' and '--output' in args, args
    Path(args[args.index('--output') + 1]).write_text('synthetic sentinel index\n')
elif mode == 'flatten':
    assert len(args) == 5 and args[1] == '--root', args
    repo, output = Path(args[2]), Path(args[4])
    symbol = 'scip-typescript npm policy-fixture 0.0.0 probe().'
    (output / 'symbols.tsv').write_text(f'{symbol}\tprobe\t17\t\tgenerated:{repo.name}\n')
    (output / 'extents.tsv').write_text(f'{symbol}\tprobe.ts\t0\t0\t0\t29\n')
    (output / 'occurrences.tsv').write_text(f'{symbol}\tprobe.ts\t0\t9\t0\t14\tdef\n')
    (output / 'relationships.tsv').write_text('')
else:
    raise RuntimeError('unexpected external tool: ' + mode)
'''


def digest(path):
    """Hash a known fixture or selected executable without modifying it."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(directory):
    """Record directory names and file contents to detect new map artifacts."""
    return {str(path.relative_to(directory)): None if path.is_dir() else digest(path)
            for path in sorted(directory.rglob("*"))}


class RegistryClient(MCP):
    """Reuse the bounded MCP transport with an explicit private map registry."""

    def __init__(self, binary, registry, directory, timeout, environment):
        """Launch the disposable installation with controlled child settings."""
        directory.mkdir(parents=True)
        self.log = (directory / "mcp.stderr").open("wb")
        self.process = subprocess.Popen([str(binary), "serve", "--maps", str(registry)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            start_new_session=True, env=environment)
        self.buffer, self.sequence, self.transcript = b"", 0, []
        self.timeout, self.directory = timeout, directory
        try:
            self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "swan-build-policy-check", "version": "1"}})
        except BaseException:
            self.close()
            raise

    def call(self, name, arguments):
        """Return a tool's explicit error flag and unparsed text payload."""
        answer = self.request("tools/call", {"name": name, "arguments": arguments})
        require("result" in answer, "unexpected protocol error: " + repr(answer))
        result = answer["result"]
        return bool(result.get("isError")), result["content"][0]["text"]

    def good(self, name, arguments):
        """Require a successful tool response and decode its JSON payload."""
        failed, payload = self.call(name, arguments)
        require(not failed, payload)
        return json.loads(payload)


class PolicyChecks:
    """Run bounded behavior cases with independently observed indexer effects."""

    def __init__(self, options):
        """Create an isolated installation containing only the binary and fake tools."""
        self.options, self.original = options, options.binary.resolve(strict=True)
        options.output_parent.mkdir(parents=True, exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(prefix="swan-build-policy-", dir=options.output_parent)).resolve()
        self.prefix = self.directory / "installation"
        self.binary = self.prefix / "bin/swan"
        self.binary.parent.mkdir(parents=True)
        shutil.copy2(self.original, self.binary)
        self.original_hash = digest(self.original)
        require(digest(self.binary) == self.original_hash, "copied binary differs from selected executable")
        self.environment = child_environment()
        self.environment.update({"SWAN_JOBS": "1", "PATH": "/usr/bin:/bin"})
        sentinel = self.prefix / "sentinel.py"
        sentinel.write_text(SENTINEL)
        for relative, mode in (("tools/node_modules/.bin/scip-typescript", "indexer"),
                               (".tools/runtime/bin/bun", "flatten"),
                               ("tools/node_modules/.bin/tsc", "unexpected-tsc")):
            executable = self.prefix / relative
            executable.parent.mkdir(parents=True, exist_ok=True)
            arguments = [sys.executable, str(sentinel), str(self.prefix), mode]
            executable.write_text("#!/bin/sh\nexec " + " ".join(map(shlex.quote, arguments)) + ' "$@"\n')
            executable.chmod(0o755)
        (self.prefix / "tools/modules.json").write_text("{}\n")
        self.results, self.clients, self.schemas = [], [], []
        self.serial = 0

    def marker(self):
        """Read the independent JSONL evidence emitted by the fake executables."""
        path = self.prefix / "invocations.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def context(self, name):
        """Allocate a fresh registry and repository area for one behavior case."""
        folder = self.directory / name
        registry = folder / "maps"
        registry.mkdir(parents=True)
        return folder, registry

    def repository(self, folder, name):
        """Create a TypeScript repository whose only source is controlled by this test."""
        repo = folder / "repos" / name
        repo.mkdir(parents=True)
        (repo / "probe.ts").write_text("function probe() { return 1; }\n")
        return repo

    def client(self, folder, registry):
        """Register a bounded server instance for cleanup and transcript retention."""
        self.serial += 1
        client = RegistryClient(self.binary, registry, folder / ("rpc-" + str(self.serial)),
                                self.options.timeout, self.environment)
        self.clients.append(client)
        return client

    def mapped(self, registry, name, repo, label):
        """Build one known map directly from synthetic rows without invoking an indexer."""
        output = registry / name
        output.mkdir()
        symbol = "scip-typescript npm policy-fixture 0.0.0 probe()."
        (output / "symbols.tsv").write_text(f"{symbol}\tprobe\t17\t\t{label}\n")
        (output / "extents.tsv").write_text(f"{symbol}\tprobe.ts\t0\t0\t0\t29\n")
        (output / "occurrences.tsv").write_text(f"{symbol}\tprobe.ts\t0\t9\t0\t14\tdef\n")
        (output / "relationships.tsv").write_text("")
        database = output / "swan.db"
        built = subprocess.run([str(self.binary), "index", str(output), str(database), str(repo)],
            capture_output=True, text=True, timeout=self.options.timeout, env=self.environment)
        (output / "fixture-build.log").write_text(built.stdout + built.stderr)
        require(built.returncode == 0, "synthetic fixture failed: " + built.stdout + built.stderr)
        return database

    def probe(self, client, repo=None, **policy):
        """Query a known symbol and return its distinguishing signature."""
        arguments = {"name_path_pattern": "probe", "include_body": False, **policy}
        if repo is not None:
            arguments["repo"] = str(repo)
        rows = client.good("find_symbol", arguments)
        require(len(rows) == 1 and rows[0]["relative_path"] == "probe.ts", "wrong probe answer: " + repr(rows))
        return rows[0]["signature"]

    def identity(self, client, repo, database):
        """Check the reported root and selected map using established use_repo semantics."""
        result = client.good("use_repo", {"path": str(repo), "build": False})
        require(result["root"] == str(repo) and result["map"] == str(database), "wrong repository identity: " + repr(result))
        require(result["built"] is False, "existing map was unexpectedly rebuilt")
        return result

    def unchanged(self, registry, before, calls):
        """Require zero tool invocations and unchanged map artifacts after a restricted call."""
        require(self.marker() == calls, "restricted request invoked an indexer/tool: " + repr(self.marker()[len(calls):]))
        require(inventory(registry) == before, "restricted request created or changed map artifacts")

    def refused(self, client, registry, name, arguments, reason="no map for"):
        """Assert a specific refusal with independent absence-of-effects evidence."""
        before, calls = inventory(registry), self.marker()
        failed, payload = client.call(name, arguments)
        self.unchanged(registry, before, calls)
        require(failed and reason in payload.lower(), "wrong restriction response: " + payload)

    def positive_controls(self):
        """Show that omitted and true policy actually execute the sentinels and create maps."""
        folder, registry = self.context("positive-controls")
        client = self.client(folder, registry)
        for name, policy in (("omitted", {}), ("explicit-true", {"build": True})):
            repo = self.repository(folder, name)
            before = len(self.marker())
            require(self.probe(client, repo, **policy) == "generated:" + name, "synthetic first-use answer mismatch")
            calls = self.marker()[before:]
            require({call["mode"] for call in calls} == {"indexer", "flatten"}, "positive sentinel control did not execute")
            self.identity(client, repo, registry / name / "swan.db")
        return "omitted/true both produced maps through the marker indexer and flattener"

    def schemas_and_all_tools(self):
        """Check every advertised selection schema and runtime no-build boundary."""
        folder, registry = self.context("schemas-and-all-tools")
        client = self.client(folder, registry)
        self.schemas = client.request("tools/list", {})["result"]["tools"]
        (folder / "schemas.json").write_text(json.dumps(self.schemas, indent=2) + "\n")
        failures, tested = [], []
        for tool in self.schemas:
            properties = tool["inputSchema"].get("properties", {})
            if "repo" not in properties and tool["name"] != "use_repo":
                continue
            name = tool["name"]
            tested.append(name)
            if properties.get("build", {}).get("type") != "boolean":
                failures.append(name + ": missing boolean build schema")
            repo = self.repository(folder, name)
            arguments = {key: 1 if properties[key].get("type") in ("integer", "number") else "__absent__"
                         for key in tool["inputSchema"].get("required", [])}
            arguments.update({"path" if name == "use_repo" else "repo": str(repo), "build": False})
            try:
                self.refused(client, registry, name, arguments)
            except AssertionError as exc:
                failures.append(name + ": " + str(exc))
        require(tested and not failures, "\n".join(failures))
        return {"checked_tools": tested, "zero_implicit_invocations": True}

    def existing_and_stateless(self):
        """Preserve existing answers and identity across fresh restricted server launches."""
        folder, registry = self.context("existing-and-stateless")
        repo = self.repository(folder, "existing")
        database = self.mapped(registry, "existing", repo, "existing-answer")
        absent = self.repository(folder, "unmapped")
        before, calls = inventory(registry), self.marker()
        for _ in range(3):
            client = self.client(folder, registry)
            require(self.probe(client, repo, build=False) == "existing-answer", "existing answer changed")
            self.identity(client, repo, database)
            self.refused(client, registry, "find_symbol", {"repo": str(absent), "build": False, "name_path_pattern": "probe"})
            client.close()
            self.clients.remove(client)
        self.unchanged(registry, before, calls)
        return "three independent launches preserved answers/identity and refused an unmapped repo"

    def deleted_map(self):
        """Remove a selected map between requests and require refusal without rebuilding."""
        folder, registry = self.context("deleted-map")
        repo = self.repository(folder, "selected")
        database = self.mapped(registry, "selected", repo, "restored-answer")
        client = self.client(folder, registry)
        self.identity(client, repo, database)
        saved = folder / "saved.db"
        database.rename(saved)
        try:
            self.refused(client, registry, "find_symbol", {"repo": str(repo), "build": False, "name_path_pattern": "probe"})
        finally:
            saved.replace(database)
        require(self.probe(client, repo, build=False) == "restored-answer", "restored map did not recover")
        return "deleted selected map refused; restored map recovered in the same server"

    def incompatible_and_ancestor(self):
        """Refuse an old-only map but permit an existing usable ancestor under current routing."""
        folder, registry = self.context("incompatible-and-ancestor")
        ancestor = self.repository(folder, "parent")
        child = self.repository(folder, "parent/child")
        bad = self.mapped(registry, "child", child, "old-child")
        with closing(connect(bad)) as connection:
            connection.execute("UPDATE meta SET value='old-test-schema' WHERE key='schema_version'")
            connection.commit()
        client = self.client(folder, registry)
        self.refused(client, registry, "find_symbol", {"repo": str(child), "build": False, "name_path_pattern": "probe"})
        good = self.mapped(registry, "parent", ancestor, "ancestor-answer")
        before, calls = inventory(registry), self.marker()
        require(self.probe(client, child, build=False) == "ancestor-answer", "usable ancestor was not preserved")
        identity = client.good("use_repo", {"path": str(child), "build": False})
        require(identity["root"] == str(ancestor) and identity["map"] == str(good), "ancestor identity mismatch")
        self.unchanged(registry, before, calls)
        return "old-only map refused; existing compatible ancestor selected with its own identity"

    def locked_closer(self):
        """Require explicit lock refusal even when a readable ancestor could otherwise match."""
        folder, registry = self.context("locked-closer")
        ancestor = self.repository(folder, "parent")
        child = self.repository(folder, "parent/child")
        self.mapped(registry, "parent", ancestor, "ancestor-answer")
        database = self.mapped(registry, "child", child, "closer-answer")
        client = self.client(folder, registry)
        before, calls = inventory(registry), self.marker()
        with closing(connect(database)) as holder:
            holder.execute("BEGIN EXCLUSIVE")
            try:
                # Opening and closing another descriptor for this database in
                # this process can release SQLite's POSIX locks. Hash files
                # only before BEGIN and after rollback, never while holding it.
                failed, payload = client.call("find_symbol", {
                    "repo": str(child), "build": False, "name_path_pattern": "probe"})
                require(self.marker() == calls, "locked-map request invoked an indexer/tool")
                require(failed and any(word in payload.lower() for word in ("locked", "busy")),
                        "locked closer map did not refuse explicitly: " + payload)
            finally:
                holder.rollback()
        self.unchanged(registry, before, calls)
        require(self.probe(client, child, build=False) == "closer-answer", "closer map did not recover")
        self.identity(client, child, database)
        return "locked closer map refused despite readable ancestor; release restored correct identity"

    def names_and_duplicates(self):
        """Keep basename collisions separate and preserve same-root duplicate selection."""
        folder, registry = self.context("names-and-duplicates")
        first, second = self.repository(folder, "a/twin"), self.repository(folder, "b/twin")
        one = self.mapped(registry, "twin", first, "first-root")
        two = self.mapped(registry, "twin-second", second, "second-root")
        client = self.client(folder, registry)
        before, calls = inventory(registry), self.marker()
        for repo, database, label in ((first, one, "first-root"), (second, two, "second-root")):
            require(self.probe(client, repo, build=False) == label, "same basename crossed repository roots")
            self.identity(client, repo, database)
        self.unchanged(registry, before, calls)
        third = self.repository(folder, "c/twin")
        self.refused(client, registry, "find_symbol", {"repo": str(third), "build": False, "name_path_pattern": "probe"})
        original_hashes = [digest(one), digest(two)]
        require(self.probe(client, third, build=True) == "generated:twin", "authorized collision-safe creation failed")
        selected = client.good("use_repo", {"path": str(third), "build": False})
        require(selected["root"] == str(third) and selected["map"] not in (str(one), str(two)), "new basename overwrote another root")
        require([digest(one), digest(two)] == original_hashes, "existing same-basename maps changed")
        duplicate = self.mapped(registry, "duplicate-first-root", first, "duplicate-root")
        before, calls = inventory(registry), self.marker()
        selection = client.good("use_repo", {"path": str(first), "build": False})
        labels = {str(one): "first-root", str(duplicate): "duplicate-root"}
        require(selection["root"] == str(first) and selection["map"] in labels, "duplicate selected an unrelated root")
        require(self.probe(client, first, build=False) == labels[selection["map"]], "request policy changed duplicate selection")
        self.unchanged(registry, before, calls)
        return {"same_basename_roots": 3, "duplicate_selected_map": selection["map"],
                "duplicate_policy": "preserved existing registry order; no lexicographic or newest-map guarantee"}

    def malformed_policy(self):
        """Reject malformed policy before selection or explicit update effects, preserving selection."""
        folder, registry = self.context("malformed-policy")
        repo = self.repository(folder, "selected")
        database = self.mapped(registry, "selected", repo, "selected-answer")
        absent = self.repository(folder, "unmapped")
        client = self.client(folder, registry)
        self.identity(client, repo, database)
        checked = 0
        for value in (None, 0, 1, "false", [], {}):
            for name, arguments in (("find_symbol", {"repo": str(absent), "name_path_pattern": "probe"}),
                                    ("use_repo", {"path": str(absent)}),
                                    ("find_symbol", {"name_path_pattern": "probe"}),
                                    ("update_map", {})):
                before, calls = inventory(registry), self.marker()
                failed, payload = client.call(name, {**arguments, "build": value})
                self.unchanged(registry, before, calls)
                require(failed and "build" in payload.lower() and "boolean" in payload.lower(), "malformed policy was not rejected: " + payload)
                require(self.probe(client) == "selected-answer", "malformed restriction changed selected repository")
                checked += 1
        return {"malformed_requests_rejected": checked, "selection_preserved": True}

    def explicit_update(self):
        """Demonstrate that build:false restricts selection, not an explicit update_map operation."""
        folder, registry = self.context("explicit-update")
        repo = self.repository(folder, "explicit")
        self.mapped(registry, "explicit", repo, "before-update")
        client = self.client(folder, registry)
        before = len(self.marker())
        client.good("update_map", {"repo": str(repo), "build": False})
        require({item["mode"] for item in self.marker()[before:]} == {"indexer", "flatten"}, "explicit update_map was incorrectly suppressed")
        require(self.probe(client, repo, build=False) == "generated:explicit", "explicit update did not publish synthetic result")
        return "explicit update_map still ran and published its result with build:false on selection"

    def save(self):
        """Retain exact executable identity, results, and sentinel invocation evidence."""
        (self.directory / "results.json").write_text(json.dumps({
            "selected_binary": str(self.original), "selected_binary_sha256": self.original_hash,
            "copied_binary": str(self.binary), "copied_binary_sha256": digest(self.binary),
            "timeout_seconds": self.options.timeout, "results": self.results,
            "sentinel_invocations": self.marker(),
            "scope": "synthetic indexer/flattener; no real language tooling or production configuration changes",
        }, indent=2) + "\n")

    def run(self):
        """Collect all case outcomes so an old baseline exposes runtime marker failures too."""
        print("Artifacts: " + str(self.directory), flush=True)
        operations = [self.positive_controls, self.schemas_and_all_tools, self.existing_and_stateless,
                      self.deleted_map, self.incompatible_and_ancestor, self.locked_closer,
                      self.names_and_duplicates, self.malformed_policy, self.explicit_update]
        try:
            for operation in operations:
                if self.options.case and operation.__name__ not in self.options.case:
                    continue
                try:
                    detail, status = operation(), "PASS"
                except Exception as exc:
                    detail, status = type(exc).__name__ + ": " + str(exc), "FAIL"
                finally:
                    for client in self.clients:
                        client.close()
                    self.clients.clear()
                self.results.append({"case": operation.__name__, "status": status, "detail": detail})
                self.save()
                print(status + " " + operation.__name__ + ": " + json.dumps(detail), flush=True)
            require(digest(self.original) == self.original_hash, "supplied executable changed during qualification")
        finally:
            for client in self.clients:
                client.close()
            self.save()
        return int(any(result["status"] != "PASS" for result in self.results))


def main():
    """Validate bounded runtime options and execute only the disposable harness."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output-parent", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=15)
    parser.add_argument("--case", action="append", choices=["positive_controls", "schemas_and_all_tools",
        "existing_and_stateless", "deleted_map", "incompatible_and_ancestor", "locked_closer",
        "names_and_duplicates", "malformed_policy", "explicit_update"])
    options = parser.parse_args()
    if not sys.platform.startswith("linux") or not 5 <= options.timeout <= 30:
        parser.error("requires Linux and 5 <= timeout <= 30 seconds")
    if not options.binary.is_file() or not os.access(options.binary, os.X_OK):
        parser.error("--binary must identify an existing executable")
    return PolicyChecks(options).run()


if __name__ == "__main__":
    raise SystemExit(main())
