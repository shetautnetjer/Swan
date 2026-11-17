// What every suite uses: running commands, the check tally, files, JSON
// helpers. Commands run from the Swan checkout (the runner's working
// directory), as the TypeScript suites did.

import std;
import os;
import json;
import dictionary;

extern fn swan_run(argv: const u8[:], cwd: const u8[:], env: const u8[:], timeout_ms: i64,
                   out: u8[>..]&, err: u8[>..]&) -> i32;

var h_failures: i64 = 0;
var h_passes: i64 = 0;
var h_suite_failures: i64 = 0;

// "ok   what", or "FAIL what" and the detail on the next line, as the
// TypeScript suites printed them.
fn check(what: const u8[:], ok: bool, detail: const u8[:]) {
    if ok {
        print(str("ok   ", what));
        h_passes++;
    } else {
        print(str("FAIL ", what, "\n     ", detail[..min(detail.len, 2000)]));
        h_failures++;
        h_suite_failures++;
    }
}

// Arguments and environment entries travel NUL-separated.
fn a1(list: u8[>..]&, x: const u8[:]) { list.append(x); list.push(0); }
fn argv(xs: const u8[:][:]) -> u8[>..] {
    var l: u8[>..] = [];
    for x in xs { a1(l, x); }
    return l;
}
fn envv(k: const u8[:], v: const u8[:]) -> u8[>..] {
    var e: u8[>..] = [];
    format(e, k, "=", v);
    e.push(0);
    return e;
}

// Runs a command (30 minutes at most); its exit code, with stdout and stderr.
fn run(args: const u8[:], env: const u8[:], out: u8[>..]&, err: u8[>..]&) -> i32 {
    out.clear();
    err.clear();
    return swan_run(args, ".", env, 1800000, out, err);
}

// Runs a command that must succeed. On failure it is a FAIL named after the
// command (the TypeScript suites threw and stopped), and false.
fn sh(args: const u8[:], env: const u8[:], out: u8[>..]&) -> bool {
    var err: u8[>..] = [];
    let code = run(args, env, out, err);
    if code != 0 {
        var shown: u8[>..] = [];
        for c in args { shown.push(if c == 0 { ' ' } else { c }); }
        check(str("command succeeds: ", trim(shown)), false, str("exit ", code, ": ", err[..min(err.len, 1500)]));
        return false;
    }
    return true;
}

fn rm_rf(path: const u8[:]) { var o: u8[>..] = []; var e: u8[>..] = []; run(argv(["rm", "-rf", path]), "", o, e); }
fn mkdir_p(path: const u8[:]) { var o: u8[>..] = []; var e: u8[>..] = []; run(argv(["mkdir", "-p", path]), "", o, e); }

// The n-th element of a JSON array, or null.
fn nth(n: json::Node?, k: i64) -> json::Node? {
    var found: json::Node? = null;
    var i = 0;
    if n {
        json::each(n) { e => if i == k { found .= e; } i++; };
    }
    return found;
}
fn jcount(n: json::Node?) -> i64 {
    var i = 0;
    if n { json::each(n) { e => i++; }; }
    return i;
}
fn jstr(n: json::Node?, key: const u8[:]) -> const u8[:] {
    let s, ok = json::as_string(json::member(n, key));
    return if ok { s } else { "" };
}
fn jint(n: json::Node?, key: const u8[:]) -> i64 {
    let v, ok = json::as_i64(json::member(n, key));
    return if ok { v } else { -1 };
}
fn jtrue(n: json::Node?, key: const u8[:]) -> bool {
    let v, ok = json::as_bool(json::member(n, key));
    return ok && v;
}

// Byte order of two strings.
fn bytes_less(a: const u8[:], b: const u8[:]) -> bool {
    let n = min(a.len, b.len);
    for i in n { if a[i] != b[i] { return a[i] < b[i]; } }
    return a.len < b.len;
}

// The lines of `list` ("x\ny\n"), sorted bytewise and joined by commas.
fn sorted_join(list: const u8[:]) -> u8[>..] {
    var st: i64[>..] = [];
    var ln: i64[>..] = [];
    var s = 0;
    for c, i in list { if c == '\n' { st.push(s); ln.push(i - s); s = i + 1; } }
    if s < list.len { st.push(s); ln.push(list.len - s); }
    for i in 1..st.len {
        var j = i;
        while j > 0 && bytes_less(list[st[j]..st[j] + ln[j]], list[st[j - 1]..st[j - 1] + ln[j - 1]]) {
            let t1 = st[j]; st[j] = st[j - 1]; st[j - 1] = t1;
            let t2 = ln[j]; ln[j] = ln[j - 1]; ln[j - 1] = t2;
            j--;
        }
    }
    var out: u8[>..] = [];
    for i in st.len {
        if i > 0 { out.push(','); }
        out.append(list[st[i]..st[i] + ln[i]]);
    }
    return out;
}

// --- an MCP client: `swan serve` over its stdin and stdout ---------------------
// One server at a time, as each suite drives one. Requests are JSON lines;
// each answer is the next line, which must carry the request's id.

extern fn proc_open(argv: const u8[:], cwd: const u8[:], env: const u8[:], log: const u8[:]) -> i64;
extern fn proc_write(h: i64, data: const u8[:]) -> bool;
extern fn proc_read(h: i64, timeout_ms: i64, buf: u8[:]) -> i64;
extern fn proc_close(h: i64, grace_ms: i64);

var m_h: i64 = 0;
var m_inbox: u8[>..];
var m_chunk: u8[65536];
var m_id: i64 = 1;

// Starts the server; stderr stays the runner's own.
fn mcp_open(args: const u8[:], env: const u8[:]) -> bool {
    m_inbox.clear();
    m_id = 1;
    m_h = proc_open(args, ".", env, "");
    if m_h == 0 { check("swan serve starts", false, "proc_open failed"); }
    return m_h != 0;
}

// The next line the server writes (10 minutes at most: a first call may
// build a map). False when it closed or said nothing.
fn mcp_line(out: u8[>..]&) -> bool {
    out.clear();
    while true {
        let nl = find(m_inbox, "\n");
        if nl >= 0 {
            out.append(m_inbox[..nl]);
            var rest: u8[>..] = [];
            rest.append(m_inbox[nl + 1..]);
            m_inbox.clear();
            m_inbox.append(rest);
            return true;
        }
        let n = proc_read(m_h, 600000, m_chunk);
        if n <= 0 { return false; }
        m_inbox.append(m_chunk[..n]);
    }
    return false;
}

fn mcp_notify(method: const u8[:]) {
    var req: u8[>..] = [];
    req.append("{\"jsonrpc\":\"2.0\",\"method\":");
    json::format_string(req, method);
    req.append("}\n");
    proc_write(m_h, req);
}

// Sends a request (params as JSON text, "" for none) and puts the whole
// answer line in out. False, with a FAIL, if no answer with its id came.
fn mcp_rpc(method: const u8[:], params: const u8[:], out: u8[>..]&) -> bool {
    let id = m_id;
    m_id++;
    var req: u8[>..] = [];
    format(req, "{\"jsonrpc\":\"2.0\",\"id\":", id, ",\"method\":");
    json::format_string(req, method);
    if params.len > 0 { format(req, ",\"params\":", params); }
    req.append("}\n");
    guard proc_write(m_h, req) else { check(str(method, ": the server takes the request"), false, "write failed"); return false; }
    guard mcp_line(out) else { check(str(method, ": the server answers"), false, "it closed or said nothing"); return false; }
    var doc: json::Node[>..] = [];
    var dec: u8[>..] = [];
    let root, err = json::parse(out, doc, dec);
    let got = jint(root, "id");
    if got != id { check(str(method, ": the answer carries the request's id"), false, str("sent ", id, ", got ", out[..min(out.len, 300)])); return false; }
    return true;
}

// Calls a tool (arguments as JSON text) and puts the text of its answer in
// out. A tool error is a FAIL naming it, and false.
fn mcp_tool(name: const u8[:], arguments: const u8[:], out: u8[>..]&) -> bool {
    var params: u8[>..] = [];
    params.append("{\"name\":");
    json::format_string(params, name);
    format(params, ",\"arguments\":", arguments, "}");
    let t0 = clock();
    var line: u8[>..] = [];
    guard mcp_rpc("tools/call", params, line) else { return false; }
    let ms = (clock() - t0) * 1000.0;
    var doc: json::Node[>..] = [];
    var dec: u8[>..] = [];
    let root, err = json::parse(line, doc, dec);
    let result = json::member(root, "result");
    var text: u8[>..] = [];
    text.append(jstr(nth(json::member(result, "content"), 0), "text"));
    let failed = jtrue(result, "isError");
    out.clear();
    out.append(text);
    if failed {
        check(str(name, " ", arguments, " succeeds"), false, text);
        return false;
    }
    print(str("  ", name, " ", arguments, ": ", (ms * 100.0) as i64 / 100, ".", ((ms * 100.0) as i64) % 100, " ms"));
    return true;
}

fn mcp_close() {
    if m_h != 0 { proc_close(m_h, 10000); m_h = 0; }
}

// The values of `key` in each element of a JSON array, one per line.
fn jlist(arr: json::Node?, key: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    if arr { json::each(arr) { e => format(out, jstr(e, key), "\n"); }; }
    return out;
}
// Whether some element of the array has key equal to value.
fn jany(arr: json::Node?, key: const u8[:], value: const u8[:]) -> bool {
    var found = false;
    if arr { json::each(arr) { e => if jstr(e, key) == value { found = true; } }; }
    return found;
}
// The first element whose key equals value, or null.
fn jfind(arr: json::Node?, key: const u8[:], value: const u8[:]) -> json::Node? {
    var found: json::Node? = null;
    if arr { json::each(arr) { e => if !found && jstr(e, key) == value { found .= e; } }; }
    return found;
}
// Whether the lines of a list include s.
fn has_line(list: const u8[:], s: const u8[:]) -> bool {
    var found = false;
    each_split(list, '\n') { l => if l == s { found = true; } };
    return found;
}

// The elements of an array of strings, joined by commas.
fn jstrings(arr: json::Node?) -> u8[>..] {
    var out: u8[>..] = [];
    if arr {
        json::each(arr) { e =>
            let s, ok = json::as_string(e);
            if out.len > 0 { out.push(','); }
            if ok { out.append(s); }
        };
    }
    return out;
}
// A number that may come as a JSON number or a numeric string; -1 if neither.
fn jnum(n: json::Node?, key: const u8[:]) -> i64 {
    let v, ok = json::as_i64(json::member(n, key));
    if ok { return v; }
    let s, sok = json::as_string(json::member(n, key));
    if sok { let w, wok = parse_int(s); if wok { return w; } }
    return -1;
}
fn jhas(n: json::Node?, key: const u8[:]) -> bool { json::member(n, key) != null }

// "path:line" for each element of an array, sorted, comma-joined.
fn jlines(arr: json::Node?) -> u8[>..] {
    var l: u8[>..] = [];
    if arr { json::each(arr) { e => format(l, jstr(e, "relative_path"), ":", jint(e, "line"), "\n"); }; }
    return sorted_join(l);
}
// The call sites of the direct callers (distance 1), as jlines would list them.
fn direct_sites(answer: json::Node?) -> u8[>..] {
    var l: u8[>..] = [];
    let cs = json::member(answer, "callers");
    if cs {
        json::each(cs) { c =>
            if jint(c, "distance") == 1 {
                let sites = json::member(c, "call_sites");
                if sites { json::each(sites) { s => format(l, jstr(s, "relative_path"), ":", jint(s, "line"), "\n"); }; }
            }
        };
    }
    return sorted_join(l);
}
// `bin/swan query <db> <args...>`'s output (whatever it printed).
fn swan_query(db: const u8[:], a: const u8[:], b: const u8[:], c: const u8[:]) -> u8[>..] {
    var l: u8[>..] = [];
    a1(l, "bin/swan"); a1(l, "query"); a1(l, db); a1(l, a);
    if b.len > 0 { a1(l, b); }
    if c.len > 0 { a1(l, c); }
    var out: u8[>..] = [];
    var err: u8[>..] = [];
    run(l, "", out, err);
    return out;
}
// Replaces the first `old` in a file with `new`; false if it is not there.
fn replace_in_file(path: const u8[:], old: const u8[:], new: const u8[:]) -> bool {
    var text: u8[>..] = [];
    guard read_file(path, text) else { return false; }
    let at = find(text, old);
    guard at >= 0 else { return false; }
    var out: u8[>..] = [];
    out.append(text[..at]);
    out.append(new);
    out.append(text[at + old.len..]);
    return write_file(path, out);
}
