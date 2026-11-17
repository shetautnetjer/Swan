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
