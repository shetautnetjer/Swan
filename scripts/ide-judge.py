#!/usr/bin/env python3
"""Judge a `swan serve` against a JetBrains IDE on one repo.

scripts/ide-judge.py <swan-binary> <map-db> <repo-dir> <ide-port> <ext> <n> <out.json>

Questions: <n> in-repo functions and methods (deterministic pick) whose name appears as a word in at most 150
places in files ending in <ext>. The IDE's answer for a question: every such place that its get_symbol_info resolves
to the same symbol as the definition does (the first two lines of its documentation: path and signature).
Scored per question: find_referencing_symbols (by file and line), get_callers' call sites, get_symbol_at at each
place the IDE confirms. Read-only on both sides.
"""
import json, re, sqlite3, subprocess, sys, time, urllib.request
from pathlib import Path

swan, db, repo, port, ext, n, out = sys.argv[1], sys.argv[2], Path(sys.argv[3]), sys.argv[4], sys.argv[5], int(sys.argv[6]), sys.argv[7]

# --- the IDE (streamable HTTP MCP) ---
URL, sid = f"http://127.0.0.1:{port}/stream", None
def post(obj):
    global sid
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if sid: h["mcp-session-id"] = sid
    r = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(obj).encode(), h), timeout=180)
    sid = r.headers.get("mcp-session-id") or sid
    body = r.read().decode()
    if not body.strip(): return None
    if r.headers.get("Content-Type", "").startswith("text/event-stream"):
        body = [l[5:].strip() for l in body.splitlines() if l.startswith("data:")][-1]
    return json.loads(body)
post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "swan-judge", "version": "0"}}})
post({"jsonrpc": "2.0", "method": "notifications/initialized"})
def ide_key(path, line, col):
    r = post({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_symbol_info", "arguments": {"projectPath": str(repo), "filePath": path, "line": line, "column": col}}})
    res = (r or {}).get("result") or {}
    doc = (res.get("structuredContent") or {}).get("documentation")
    if doc is None:
        try: doc = json.loads(((res.get("content") or [{}])[0]).get("text", "{}")).get("documentation")
        except Exception: doc = None
    # The symbol's container and signature: the first two lines that are not table markup. GoLand opens its
    # documentation with a table ("| Package: |"), which alone would make unrelated symbols look the same.
    if not doc: return None
    lines = [l.strip() for l in doc.splitlines() if l.strip() and not re.fullmatch(r"[|\- ]*(Package:)?[|\- ]*", l.strip())]
    return "\n".join(lines[:2])

# --- the swan server (stdio MCP) ---
p = subprocess.Popen([swan, "serve", db], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
mid = 0
def swan_call(tool, args):
    global mid
    mid += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": mid, "method": "tools/call", "params": {"name": tool, "arguments": args}}) + "\n"); p.stdin.flush()
    while True:
        m = json.loads(p.stdout.readline())
        if m.get("id") == mid:
            r = m.get("result", {})
            return "".join(c.get("text", "") for c in r.get("content", []))
p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "swan-judge", "version": "0"}}}) + "\n"); p.stdin.flush()
p.stdout.readline()
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()

# --- the questions ---
files = [f for f in subprocess.run(["git", "-C", str(repo), "ls-files", f"*{ext}"], capture_output=True, text=True).stdout.splitlines()]
texts = {f: (repo / f).read_text(errors="replace").splitlines() for f in files}
def word_hits(name):
    w = re.compile(r"\b" + re.escape(name) + r"\b")
    return [(f, i + 1, m.start() + 1) for f, ls in texts.items() for i, l in enumerate(ls) for m in w.finditer(l)]
c = sqlite3.connect(db)
cands = c.execute("""select s.name, s.name_path, s.def_file, s.def_line + 1, s.def_col + 1 from symbols s
  where s.in_repo = 1 and lower(s.kind) in ('function', 'method') and s.def_file like ? and s.def_file not like '%test%'
  and exists (select 1 from occurrences o where o.symbol_id = s.id and o.is_def = 0)
  order by (s.id * 2654435761) % 4294967296""", (f"%{ext}",)).fetchall()
qs = []
for name, np, f, line, col in cands:
    if len(qs) >= n: break
    hits = word_hits(name)
    if 2 <= len(hits) <= 150: qs.append((name, np, f, line, col, hits))

results = []
for name, np, f, line, col, hits in qs:
    t0 = time.time()
    key = ide_key(f, line, col)
    ide, ide_col = set(), {}
    if key:
        for hf, hl, hc in hits:
            if (hf, hl) == (f, line): continue
            if ide_key(hf, hl, hc) == key: ide.add((hf, hl)); ide_col.setdefault((hf, hl), hc)
    # A link in a doc comment ([`name`]) is a reference to the IDE, not to rust-analyzer's index: counted apart.
    ide_docs = {s for s in ide if texts[s[0]][s[1] - 1].lstrip().startswith(("//", "#"))}
    ide -= ide_docs
    refs_txt = swan_call("find_referencing_symbols", {"name_path": np, "relative_path": f})
    try: refs = json.loads(refs_txt)
    except Exception: refs = []
    # A name path matches every symbol whose path ends with it (a method and a function of one name): score the one asked.
    swan_refs = {(r["relative_path"], r["line"]) for e in refs if e.get("symbol", {}).get("name_path") == np
                 for r in e.get("references", [])}
    callers_txt = swan_call("get_callers", {"name_path": np, "relative_path": f})
    try: callers = json.loads(callers_txt).get("callers", [])
    except Exception: callers = []
    sites = {(s["relative_path"], s["line"]) for cl in callers if cl.get("distance") == 1 for s in cl.get("call_sites", [])}
    at_ok = 0
    for hf, hl in sorted(ide):
        hc = ide_col[(hf, hl)]
        try: at = json.loads(swan_call("get_symbol_at", {"relative_path": hf, "line": hl, "column": hc})).get("at", [])
        except Exception: at = []
        at_ok += any(a.get("name_path") == np for a in at)
    results.append({"name_path": np, "file": f, "line": line, "ide_key": key, "text_hits": len(hits),
                    "ide": len(ide), "ide_doc_links": len(ide_docs), "swan_refs": len(swan_refs), "both": len(ide & swan_refs),
                    "swan_only": sorted(swan_refs - ide)[:10], "ide_only": sorted(ide - swan_refs)[:10],
                    "caller_sites": len(sites), "caller_sites_in_ide": len(sites & ide),
                    "symbol_at_ok": at_ok, "seconds": round(time.time() - t0, 1)})
    r = results[-1]
    print(f"{np}: ide {r['ide']} swan {r['swan_refs']} both {r['both']} | callers {r['caller_sites_in_ide']}/{r['caller_sites']} | at {at_ok}/{r['ide']}", flush=True)
json.dump(results, open(out, "w"), indent=1)
p.stdin.close(); p.wait(timeout=30)
