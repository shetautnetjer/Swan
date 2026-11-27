#!/usr/bin/env python3
"""A scripted language server for the tests of swan lsp-ask and swan broke.

    fake_lsp.py <mode>

A line of an opened file that holds ERROR is an error there (code E1), one
that holds WARN a warning. How the server has its say about a file:

  publish   a set for an older version at once, the file's own 0.5 s later
  quiet     the file's set 0.5 s after it is opened when it has a problem,
            nothing when it is clean; a log message at 0.7 s either way
  pull      textDocument/diagnostic; for its first second it loads, under
            work-done progress begun before it answers initialize, and
            answers that nothing is wrong
  check     as rust-analyzer: busy (serverStatus) for 0.6 s; a set without
            the errors when a file is opened, the errors only from the check
            a save starts (progress "rust-analyzer/flycheck/0"), 0.5 s long
  check-fails  as check, but the check ends at once with no set, and the
            status then says it failed to start, as rust-analyzer does when a
            build script fails
  check-warns  as check, with a status warning about build scripts from the
            moment it is ready; the check runs
  check-sysroot  as check, with a status warning that leaves the check alone
            (no standard library sources); the check runs
  late      as the TypeScript server: busy from the moment a file is opened,
            it says so (progress) only 50 ms later, and until its work ends
            half a second after the open it finds no definition
  silent    never says anything of a file, never answers a question
  die       exits 0.3 s after a file is opened, or when asked anything
  stubborn  silent, and stays when its input ends, with a child of its own

textDocument/definition answers the first line of b.fake; any other question
is answered with {"params": <its params>}. FAKE_PIDS: a file each server adds
its pid to, and its child's.
"""
import json
import os
import subprocess
import sys
import threading
import time

mode = sys.argv[1]
out = sys.stdout.buffer
lock = threading.Lock()
texts = {}
versions = {}
state = {"busy": True, "loading": mode == "pull", "pending": [], "late": False}
root = ""
events = os.environ.get("FAKE_EVENTS")


def record(method, params):
    if events:
        with lock:
            with open(events, "a") as f:
                f.write(json.dumps({"method": method, "params": params}) + "\n")


def send(obj):
    body = json.dumps(obj).encode()
    with lock:
        out.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        out.flush()


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def later(seconds, fn):
    t = threading.Timer(seconds, fn)
    t.daemon = True
    t.start()


def found(text):
    items = []
    for n, line in enumerate(text.split("\n")):
        for word, severity in (("ERROR", 1), ("WARN", 2)):
            col = line.find(word)
            if col >= 0:
                rng = {"start": {"line": n, "character": col}, "end": {"line": n, "character": col + len(word)}}
                items.append({"range": rng, "severity": severity, "code": "E1", "source": "fake", "message": "planted " + word.lower()})
    return items


def publish(uri, items, version: "int | None" = 1):
    params = {"uri": uri, "diagnostics": items}
    if version is not None:
        params["version"] = version
    notify("textDocument/publishDiagnostics", params)


BUILD_SCRIPTS = "Failed to run build scripts of some packages.\n\nPlease refer to the language server logs for more details on the errors."


SYSROOT = ("Workspace `x/Cargo.toml` has sysroot errors: can't load standard library from sysroot\n"
           "/opt/none\ntry installing `rust-src` the same way you installed `rustc`")


def status(message=None):
    notify("experimental/serverStatus", {"health": "warning" if message else "ok", "quiescent": not state["busy"], "message": message})


def check(uri):
    token = "rust-analyzer/flycheck/0"
    notify("$/progress", {"token": token, "value": {"kind": "begin", "title": "cargo check"}})
    if mode == "check-fails":
        notify("$/progress", {"token": token, "value": {"kind": "end"}})
        status(BUILD_SCRIPTS + "cargo check failed to start: Cargo watcher failed, the command produced no valid metadata (exit code: 101):\n"
               "   Compiling x v0.1.0\nerror: failed to run custom build command for `x v0.1.0`\n")
        return

    def done():
        if uri in texts:
            publish(uri, found(texts[uri]), version=versions.get(uri, 1))
        notify("$/progress", {"token": token, "value": {"kind": "end"}})
    later(0.5, done)


def ready():
    state["busy"] = False
    status(BUILD_SCRIPTS if mode == "check-warns" else SYSROOT if mode == "check-sysroot" else None)
    pending = list(state["pending"])
    state["pending"].clear()
    for uri in pending:
        check(uri)


def loaded():
    state["loading"] = False
    notify("$/progress", {"token": "load", "value": {"kind": "end"}})


def work(begin):
    state["late"] = begin
    value = {"kind": "begin", "title": "Initializing"} if begin else {"kind": "end"}
    notify("$/progress", {"token": "late", "value": value})


def read_message(stream):
    length = 0
    while True:
        line = stream.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value.strip())
    return json.loads(stream.read(length))


def main():
    pids = os.environ.get("FAKE_PIDS")
    child = subprocess.Popen(["sleep", "300"]) if mode == "stubborn" else None
    if pids:
        with open(pids, "a") as f:
            f.write("%d\n" % os.getpid() + ("%d\n" % child.pid if child else ""))
    while True:
        m = read_message(sys.stdin.buffer)
        if m is None:
            if mode == "stubborn":
                time.sleep(300)
            return
        method, ident, params = m.get("method"), m.get("id"), m.get("params") or {}
        if method is None:
            continue                    # an answer to what this server asked
        if method == "exit":
            return
        if method == "initialized":
            if mode.startswith("check"):
                notify("experimental/serverStatus", {"health": "ok", "quiescent": False})
                later(0.6, ready)
            continue
        if method == "textDocument/didOpen":
            record(method, params)
            doc = params["textDocument"]
            uri = doc["uri"]
            ver = doc.get("version", 1)
            texts[uri] = doc["text"]
            versions[uri] = ver
            if mode == "publish":
                publish(uri, [], version=ver - 1)
                later(0.5, lambda u=uri, v=ver: publish(u, found(texts[u]), version=v) if versions.get(u) == v else None)
            elif mode == "publish-noversion":
                later(0.2, lambda u=uri, v=ver: publish(u, found(texts[u]), version=None) if versions.get(u) == v else None)
            elif mode == "idle-publish":
                later(0.1, lambda u=uri, v=ver: publish(u, found(texts[u]), version=None) if versions.get(u) == v else None)
                later(0.6, lambda u=uri, v=ver: publish(u, found(texts[u]), version=None) if versions.get(u) == v else None)
            elif mode == "quiet":
                if found(doc["text"]):
                    later(0.5, lambda u=uri, v=ver: publish(u, found(texts[u]), version=None) if versions.get(u) == v else None)
                later(0.7, lambda: notify("window/logMessage", {"type": 3, "message": "still here"}))
            elif mode.startswith("check"):
                publish(uri, [], version=ver)
            elif mode == "die":
                later(0.3, lambda: os._exit(3))
            elif mode == "late":
                state["late"] = True
                later(0.05, lambda: work(True))
                later(0.55, lambda: work(False))
            continue
        if method == "textDocument/didChange":
            record(method, params)
            doc = params["textDocument"]
            uri = doc["uri"]
            ver = doc.get("version", versions.get(uri, 0) + 1)
            old_text = texts.get(uri, "")
            changes = params.get("contentChanges") or []
            if changes:
                texts[uri] = changes[-1].get("text", "")
            versions[uri] = ver
            if mode == "publish":
                publish(uri, found(old_text), version=ver - 1)
                later(0.5, lambda u=uri, v=ver: publish(u, found(texts[u]), version=v) if versions.get(u) == v else None)
            elif mode == "publish-noversion":
                later(0.2, lambda u=uri, v=ver: publish(u, found(texts[u]), version=None) if versions.get(u) == v else None)
            elif mode == "idle-publish":
                later(0.5, lambda u=uri, v=ver: publish(u, found(texts[u]), version=None) if versions.get(u) == v else None)
            elif mode == "quiet":
                if found(texts[uri]):
                    later(0.5, lambda u=uri, v=ver: publish(u, found(texts[u]), version=None) if versions.get(u) == v else None)
                later(0.7, lambda: notify("window/logMessage", {"type": 3, "message": "still here"}))
            continue
        if method == "textDocument/didSave":
            record(method, params)
            uri = params["textDocument"]["uri"]
            if mode.startswith("check"):
                if state["busy"]:
                    state["pending"].append(uri)
                else:
                    check(uri)
            continue
        if method == "textDocument/didClose":
            record(method, params)
            uri = params["textDocument"]["uri"]
            texts.pop(uri, None)
            versions.pop(uri, None)
            continue
        if ident is None:
            continue
        if method == "initialize":
            global root
            root = params.get("rootUri") or ""
            if mode == "pull":
                send({"jsonrpc": "2.0", "id": "load", "method": "window/workDoneProgress/create", "params": {"token": "load"}})
                notify("$/progress", {"token": "load", "value": {"kind": "begin", "title": "Loading"}})
                later(1.0, loaded)
            send({"jsonrpc": "2.0", "id": ident, "result": {"capabilities": {"textDocumentSync": 1}}})
        elif method == "shutdown":
            send({"jsonrpc": "2.0", "id": ident, "result": None})
        elif mode in ("silent", "stubborn"):
            pass
        elif mode == "die":
            os._exit(3)
        elif method == "textDocument/diagnostic":
            uri = params["textDocument"]["uri"]
            items = [] if state["loading"] else found(texts.get(uri, ""))
            send({"jsonrpc": "2.0", "id": ident, "result": {"kind": "full", "items": items}})
        elif method == "textDocument/definition" and state["late"]:
            send({"jsonrpc": "2.0", "id": ident, "result": []})
        elif method in ("textDocument/definition", "textDocument/implementation"):
            rng = {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}
            send({"jsonrpc": "2.0", "id": ident, "result": [{"uri": root + "/b.fake", "range": rng}]})
        else:
            send({"jsonrpc": "2.0", "id": ident, "result": {"params": params}})


main()
