#!/usr/bin/env python3
"""Exercise Swan's map/query/MCP boundary with explicit synthetic SCIP rows.

Needs only Python 3 and an already-built Swan binary. No indexer, language
server, package download, compiler, or network request runs in this demo.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time


SOURCE = """export function square(x: number): number {
    return x * x;
}
export function area(side: number): number {
    return square(side);
}
"""


def require(condition, message):
    if not condition:
        raise RuntimeError(message)
    print("PASS " + message)


def write_rows(path, rows):
    path.write_text("".join("\t".join(map(str, row)) + "\n" for row in rows))


class MCP:
    """Small bounded newline-JSON client for Swan's stdio transport."""

    def __init__(self, binary, database, folder):
        self.stderr = (folder / "serve.stderr.log").open("wb")
        self.process = subprocess.Popen(
            [str(binary), "serve", str(database)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
        )
        self.next_id = 0
        self.buffer = b""
        self.transcript = []

    def request(self, method, params=None):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 15
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise RuntimeError("Swan did not answer within 15 seconds: " + method)
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("Swan closed stdout before answering: " + method)
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        answer = json.loads(line)
        self.transcript.append({"request": message, "response": answer})
        if answer.get("id") != self.next_id:
            raise RuntimeError("MCP response id did not match request")
        return answer

    def notify(self, method):
        message = {"jsonrpc": "2.0", "method": method}
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()
        self.transcript.append({"notification": message})

    def tool(self, name, arguments, expect_error=False):
        answer = self.request("tools/call", {"name": name, "arguments": arguments})
        if "error" in answer:
            raise RuntimeError("Unexpected JSON-RPC error: " + json.dumps(answer))
        result = answer["result"]
        if bool(result.get("isError", False)) != expect_error:
            raise RuntimeError("Unexpected tool status: " + json.dumps(result))
        return json.loads(result["content"][0]["text"])

    def close(self):
        self.process.stdin.close()
        try:
            status = self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise RuntimeError("Swan did not exit after stdin closed")
        finally:
            self.stderr.close()
        if status:
            raise RuntimeError("Swan exited with status " + str(status))


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=root / "bin/swan")
    parser.add_argument("--output-parent", type=Path, default=root / "data",
                        help="Parent for a new demo directory; existing files are never replaced")
    options = parser.parse_args()
    binary = options.binary.resolve()
    if not binary.is_file():
        parser.error("Build Swan first; binary is missing: " + str(binary))
    options.output_parent.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix="demo-offline-", dir=options.output_parent)).resolve()
    repository = folder / "repo"
    flattened = folder / "rows"
    repository.mkdir()
    flattened.mkdir()
    source = repository / "math.ts"
    source.write_text(SOURCE)

    # Hand-authored known answers in Swan's documented flattened-row format.
    # The scip-typescript scheme identifies the input language, not provenance:
    # no SCIP indexer produced these two symbols and three occurrences.
    square = "scip-typescript npm offline-demo 0.0.0 square()."
    area = "scip-typescript npm offline-demo 0.0.0 area()."
    write_rows(flattened / "symbols.tsv", [
        (square, "square", 17, "", "function square(x: number): number"),
        (area, "area", 17, "", "function area(side: number): number"),
    ])
    write_rows(flattened / "extents.tsv", [
        (square, "math.ts", 0, 0, 2, 1), (area, "math.ts", 3, 0, 5, 1),
    ])
    write_rows(flattened / "occurrences.tsv", [
        (square, "math.ts", 0, 16, 0, 22, "def"),
        (area, "math.ts", 3, 16, 3, 20, "def"),
        (square, "math.ts", 4, 11, 4, 17, "ref"),
    ])
    (flattened / "relationships.tsv").write_text("")
    # Deterministic freshness ordering even on filesystems with coarse mtimes.
    now = time.time_ns()
    os.utime(source, ns=(now - 2_000_000_000, now - 2_000_000_000))
    os.utime(flattened / "occurrences.tsv", ns=(now, now))
    (folder / "provenance.json").write_text(json.dumps({
        "input": "synthetic flattened rows; not produced by a SCIP indexer",
        "binary": str(binary), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "network": "not used",
        "demonstrates": ["SQLite map", "symbol/reference queries", "MCP stdio",
                         "tree-sitter captures", "rewrite plan/apply", "stale refusal"],
    }, indent=2) + "\n")
    database = folder / "swan.db"
    built = subprocess.run([str(binary), "index", str(flattened), str(database), str(repository)],
                           capture_output=True, text=True, timeout=15, check=True)
    (folder / "index.log").write_text(built.stdout + built.stderr)
    print(built.stdout.strip())

    client = MCP(binary, database, folder)
    try:
        init = client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                           "clientInfo": {"name": "swan-offline-demo", "version": "1"}})
        require(init["result"]["serverInfo"]["name"] == "swan", "MCP initialize identifies Swan")
        client.notify("notifications/initialized")
        tools = client.request("tools/list")["result"]["tools"]
        require({"find_symbol", "find_referencing_symbols", "search_pattern", "rewrite_pattern"}
                <= {tool["name"] for tool in tools}, "MCP advertises the demonstrated tools")
        found = client.tool("find_symbol", {"name_path_pattern": "square", "include_body": True})
        require(len(found) == 1 and found[0]["line"] == 1 and found[0]["relative_path"] == "math.ts"
                and "return x * x" in found[0]["body"], "square resolves to its definition and source body")
        references = client.tool("find_referencing_symbols", {"name_path": "square"})
        refs = references[0]["references"]
        require(len(refs) == 1 and refs[0]["line"] == 5 and refs[0]["column"] == 12
                and refs[0]["in_symbol"] == "area" and refs[0]["text"] == "return square(side);",
                "the known reference to square belongs to area")
        impact = client.tool("get_callers", {"name_path": "square"})
        require([item["name_path"] for item in impact["callers"]] == ["area"],
                "the reference graph finds area as the direct user")
        arguments = {"pattern": "$X * $X", "language": "typescript", "relative_path": "math.ts"}
        matched = client.tool("search_pattern", arguments)
        hits = matched["matches"]
        require(len(hits) == 1 and hits[0]["captures"]["X"] == "x" and hits[0]["in_symbol"] == "square",
                "structural search captures x and associates the match with square")
        no_match = client.tool("search_pattern", {**arguments, "pattern": "missing($X)"})
        require(no_match["count"] == 0, "a missing pattern returns zero matches")
        rewrite = {**arguments, "rewrite": "$X ** 2"}
        before = source.read_bytes()
        plan = client.tool("rewrite_pattern", rewrite)
        require(plan["applied"] is False and len(plan["edits"]) == 1
                and plan["edits"][0]["after"] == "x ** 2" and source.read_bytes() == before,
                "rewrite planning reports one edit without changing the source")
        applied = client.tool("rewrite_pattern", {**rewrite, "apply": True})
        require(applied["files_written"] == 1 and source.read_text() == SOURCE.replace("x * x", "x ** 2"),
                "explicit apply writes exactly the planned replacement")
        # Change only this generated file, then force an mtime newer than both
        # the map and the mtime recorded by Swan's own write.
        source.write_text(source.read_text() + "// outside edit\n")
        modified = time.time_ns() + 2_000_000_000
        os.utime(source, ns=(modified, modified))
        before_refusal = source.read_bytes()
        refused = client.tool("rewrite_pattern", {**rewrite, "pattern": "$X ** 2", "rewrite": "$X * $X",
                                                 "apply": True}, expect_error=True)
        require("refresh first" in refused.get("refused", "") and source.read_bytes() == before_refusal,
                "an outside edit causes refusal and leaves the file unchanged")
        unknown = client.request("demo/unknown")
        require(unknown["error"]["code"] == -32601, "unknown MCP methods return method-not-found")
    finally:
        (folder / "mcp-transcript.json").write_text(json.dumps(client.transcript, indent=2) + "\n")
        client.close()
        print("Artifacts: " + str(folder))
    print("PASS offline demo complete (synthetic row input; no indexer or live server qualification)")


if __name__ == "__main__":
    main()
