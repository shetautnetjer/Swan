#!/usr/bin/env python3
"""SolidLSP behind Swan's language-server client.

    bridge.py <solidlsp language id>      (go, ruby, bash, ...)

Speaks LSP on stdin and stdout to Swan (lsp/golsp.goose), as a language
server would, and answers from SolidLSP (https://github.com/oraios/serena,
src/solidlsp, MIT), which knows how to start, configure and wait for each
language's real server. Swan then maps the language with `swan lsp-index`
and asks for errors live, exactly as it does through its own client.

Answered: initialize, shutdown, exit, textDocument/documentSymbol,
references, definition, implementation and diagnostic. Files are read from
disk by SolidLSP, so didOpen/didChange/didSave need no answer.

Environment:
  SWAN_SOLIDLSP_DATA   where SolidLSP may keep its data (a folder in the map)
  SWAN_BRIDGE_PATH     folders put first on PATH for the real server
                       (Swan's own Go toolchain and gopls)
"""
import json
import logging
import os
import re
import sys
import urllib.parse


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
    body = stream.read(length)
    return json.loads(body) if body else None


def send(obj):
    body = json.dumps(obj).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()


def path_of(uri):
    return urllib.parse.unquote(urllib.parse.urlparse(uri).path)


def as_document_symbol(s):
    rng = s.get("range") or s["location"]["range"]
    return {
        "name": s["name"],
        "kind": int(s["kind"]),
        "range": rng,
        "selectionRange": s.get("selectionRange") or rng,
        "children": [as_document_symbol(c) for c in (s.get("children") or [])],
    }


GO_RECEIVER = re.compile(r"^\s*func\s*\(\s*(?:\w+\s+)?\*?\s*([A-Za-z_]\w*)")


def name_go_receivers(symbols, path):
    """gopls lists a method by its bare name at the top of the file; Swan nests it under
    its receiver type when the name says so: `(Greeter).Greet`."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
    except OSError:
        return
    for s in symbols:
        if s["kind"] == 6 and not s["name"].startswith("("):
            line = s["range"]["start"]["line"]
            found = GO_RECEIVER.match(lines[line]) if line < len(lines) else None
            if found:
                s["name"] = f"({found.group(1)}).{s['name']}"


def main():
    language = sys.argv[1]
    extra = os.environ.get("SWAN_BRIDGE_PATH")
    if extra:
        os.environ["PATH"] = extra + os.pathsep + os.environ.get("PATH", "")
    data = os.environ.get("SWAN_SOLIDLSP_DATA") or os.path.join(os.getcwd(), ".solidlsp")
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING)

    from solidlsp import SolidLanguageServer
    from solidlsp.ls_config import LanguageServerConfig, LanguageServerId
    from solidlsp.settings import SolidLSPSettings

    server = None
    root = None

    def rel(params):
        return os.path.relpath(path_of(params["textDocument"]["uri"]), root)

    def locations(found):
        return [{"uri": l["uri"], "range": l["range"]} for l in (found or [])]

    while True:
        message = read_message(sys.stdin.buffer)
        if message is None:
            break
        method, ident, params = message.get("method"), message.get("id"), message.get("params") or {}
        if method == "exit":
            break
        if ident is None:
            continue                  # a notification: SolidLSP reads files from disk
        try:
            if method == "initialize":
                root = os.path.realpath(path_of(params.get("rootUri") or "") or params.get("rootPath") or os.getcwd())
                settings = SolidLSPSettings(solidlsp_dir=os.path.join(data, "solidlsp"), project_data_path=os.path.join(data, "project"))
                server = SolidLanguageServer.create(LanguageServerConfig(ls_id=LanguageServerId(language)), root, solidlsp_settings=settings)
                server.start()
                result = {"capabilities": {"textDocumentSync": 1, "documentSymbolProvider": True, "referencesProvider": True,
                                           "definitionProvider": True, "implementationProvider": True,
                                           "diagnosticProvider": {"interFileDependencies": True, "workspaceDiagnostics": False}},
                          "serverInfo": {"name": "swan-solidlsp-bridge", "version": language}}
            elif method == "shutdown":
                if server is not None:
                    server.stop()
                    server = None
                result = None
            elif method == "textDocument/documentSymbol":
                result = [as_document_symbol(s) for s in server.request_document_symbols(rel(params)).root_symbols]
                if language == "go":
                    name_go_receivers(result, path_of(params["textDocument"]["uri"]))
            elif method in ("textDocument/references", "textDocument/definition", "textDocument/implementation"):
                ask = {"textDocument/references": server.request_references, "textDocument/definition": server.request_definition,
                       "textDocument/implementation": server.request_implementation}[method]
                pos = params["position"]
                result = locations(ask(rel(params), pos["line"], pos["character"]))
            elif method == "textDocument/diagnostic":
                items = []
                for d in server.request_text_document_diagnostics(rel(params)):
                    item = {"range": d["range"], "message": d["message"], "severity": int(d.get("severity", 1)), "source": language}
                    if d.get("code") is not None:
                        item["code"] = d["code"]
                    items.append(item)
                result = {"kind": "full", "items": items}
            else:
                send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": f"the SolidLSP bridge does not answer {method}"}})
                continue
            send({"jsonrpc": "2.0", "id": ident, "result": result})
        except Exception as error:      # the question fails; the bridge keeps answering
            logging.exception("bridge: %s failed", method)
            send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32603, "message": f"{type(error).__name__}: {error}"}})
    if server is not None:
        try:
            server.stop()
        except Exception:
            pass


if __name__ == "__main__":
    main()
