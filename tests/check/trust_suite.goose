// Tools that run a repo's own build files wait for `swan trust`. Checked
// here without trust (SWAN_TRUST_BUILD=0; only "1" trusts): an untrusted C#
// repo maps without scip-dotnet and writes no obj/, its live server waits, a
// trust record shipped inside the map folder is ignored, an index from
// before is not reused once the repo is trusted, an unchecked Rust repo
// keeps its saved diagnostics, and a virtualenv inside an untrusted repo
// never runs. (Was tests/trust_check.ts.)

import std;
import os;
import json;
import .harness;

let TR_UNTRUSTED = "SWAN_TRUST_BUILD=0\x00";
let TR_TRUSTED = "SWAN_TRUST_BUILD=1\x00";

// `bin/swan <a...>` with an environment; stdout and stderr together in out.
fn tr_swan(env: const u8[:], args: const u8[:][:], out: u8[>..]&) -> i32 {
    var l: u8[>..] = [];
    a1(l, "bin/swan");
    for x in args { a1(l, x); }
    var o: u8[>..] = [];
    var e: u8[>..] = [];
    let code = run(l, env, o, e);
    out.clear();
    out.append(o);
    out.append(e);
    return code;
}
fn tr_stdout(env: const u8[:], args: const u8[:][:], out: u8[>..]&) -> i32 {
    var l: u8[>..] = [];
    a1(l, "bin/swan");
    for x in args { a1(l, x); }
    var e: u8[>..] = [];
    return run(l, env, out, e);
}
fn tr_realpath(p: const u8[:]) -> u8[>..] {
    var o: u8[>..] = [];
    var e: u8[>..] = [];
    run(argv(["realpath", "-m", p]), "", o, e);
    var r: u8[>..] = [];
    r.append(trim(o));
    return r;
}
// Writes an executable script.
fn tr_plant(path: const u8[:], text: const u8[:]) {
    write_file(path, text);
    var o: u8[>..] = [];
    var e: u8[>..] = [];
    run(argv(["chmod", "755", path]), "", o, e);
}
// How many callers of Strike the map has.
fn tr_callers(db: const u8[:]) -> i64 {
    var t: u8[>..] = [];
    tr_stdout(TR_UNTRUSTED, ["query", db, "callers", "Strike"], t);
    var d: json::Node[>..] = []; var x: u8[>..] = [];
    let r, e = json::parse(t, d, x);
    return jcount(json::member(r, "callers"));
}
// One live get_diagnostics through `swan serve` (env decides trust); the
// reply line, or "" if none came. Closing stdin ends the server.
fn tr_live(env: const u8[:], db: const u8[:], args: const u8[:], line: u8[>..]&) {
    line.clear();
    if mcp_open(argv(["bin/swan", "serve", db]), env) {
        var params: u8[>..] = [];
        format(params, "{\"name\":\"get_diagnostics\",\"arguments\":", args, "}");
        mcp_rpc("tools/call", params, line);
        mcp_close();
    }
}

fn trust_suite() {
    // Leave Swan's trust list as it was, whatever happens in between.
    let trust_file = "data/trusted-repos";
    let had = file_exists(trust_file);
    var before: u8[>..] = [];
    if had { read_file(trust_file, before); }
    trust_checks(trust_file);
    if had { write_file(trust_file, before); } else { delete_file(trust_file); }
}

fn trust_checks(trust_file: const u8[:]) {
    var o: u8[>..] = [];
    if exists(".tools/dotnet-tools/scip-dotnet") && exists(".tools/dotnet-tools/csharp-ls") {
        let dir = "data/trust-check/cs";
        rm_rf(dir);
        mkdir_p(dir);
        if sh(argv(["cp", "-r", "fixtures/tiny-cs", str(dir, "/repo")]), "", o) {
            let repo = tr_realpath(str(dir, "/repo"));
            let out = str(dir, "/out");
            let db = str(out, "/swan.db");
            // A full map first (trusted for this one run), so a stale index exists.
            tr_swan(TR_TRUSTED, ["map", repo, out], o);
            let n0 = tr_callers(db);
            check("trusted C#: the full map has callers", n0 == 3, str(n0));
            rm_rf(str(dir, "/repo/obj"));
            rm_rf(str(dir, "/repo/bin"));
            // A trust record the map folder ships (it could sit inside the checkout).
            write_file(str(out, "/trusted"), str(repo, "\n"));
            var m: u8[>..] = [];
            tr_stdout(TR_UNTRUSTED, ["map", repo, out], m);
            check("untrusted C#: the map skips scip-dotnet and says how to trust the repo",
                  find(m, "not run: scip-dotnet") >= 0 && find(m, str("swan trust ", repo)) >= 0, m);
            check("untrusted C#: a trust record in the map folder is ignored", find(m, "not run:") >= 0, m);
            check("untrusted C#: dotnet restore did not run (no obj/)", !exists(str(dir, "/repo/obj")), "");
            let n1 = tr_callers(db);
            check("untrusted C#: the map has no callers", n1 == 0, str(n1));
            var live: u8[>..] = [];
            tr_live(TR_UNTRUSTED, db, """{"relative_path":"src/Program.cs","live":true}""", live);
            check("untrusted C#: the live server waits for swan trust", find(live, "swan trust ") >= 0, live);
            var t: u8[>..] = [];
            tr_stdout(TR_UNTRUSTED, ["trust", repo], t);
            var list: u8[>..] = [];
            read_file(trust_file, list);
            check("swan trust records the repo in Swan's own data", has_line(list, repo), t);
            var m2: u8[>..] = [];
            tr_stdout(TR_UNTRUSTED, ["map", repo, out], m2);
            let n2 = tr_callers(db);
            check("after swan trust the map runs scip-dotnet again rather than reusing the old index",
                  find(m2, "not run:") < 0 && find(m2, "scip-dotnet: reused") < 0 && n2 == 3, m2);
        }
    } else { print("skipped C#: no .tools/dotnet-tools (csharp-ls, scip-dotnet)"); }

    // Rust: maps sealed with no trust; unchecked, its saved diagnostics stay
    // while the Python check runs.
    {
        let dir = "data/trust-check/rs";
        rm_rf(dir);
        mkdir_p(dir);
        if sh(argv(["cp", "-r", "fixtures/tiny-rs", str(dir, "/repo")]), "", o) {
            write_file(str(dir, "/repo/helper.py"), "def helper() -> int:\n    return 1\n");
            let repo = tr_realpath(str(dir, "/repo"));
            let out = str(dir, "/out");
            var mreport: u8[>..] = [];
            tr_swan(TR_UNTRUSTED, ["map", repo, out], mreport);
            check("untrusted Rust: the map runs rust-analyzer sealed, with no trust step",
                  find(mreport, "rust-analyzer scip:") >= 0 && find(mreport, "not run: rust-analyzer") < 0, mreport);
            var rt: u8[>..] = [];
            tr_stdout(TR_UNTRUSTED, ["query", str(out, "/swan.db"), "refs", "Shape"], rt);
            var d: json::Node[>..] = []; var x: u8[>..] = [];
            let refs, e = json::parse(rt, d, x);
            var resolved = false;
            let rl = json::member(nth(refs, 0), "references");
            if rl { json::each(rl) { r => if !jtrue(r, "by_name") { resolved = true; } }; }
            check("untrusted Rust: uses of Shape are compiler-resolved (not matched by name)", jcount(refs) > 0 && resolved, rt);
            check("untrusted Rust: the sealed build wrote nothing into the repo (no target/)", !exists(str(dir, "/repo/target")), "");
            mkdir_p(out);
            write_file(str(out, "/diagnostics.tsv"), "src/lib.rs\t0\t0\t0\t1\terror\tcargo\tE0061\ta saved cargo error\n");
            var report: u8[>..] = [];
            tr_swan(TR_UNTRUSTED, ["check", repo, out], report);
            var after: u8[>..] = [];
            read_file(str(out, "/diagnostics.tsv"), after);
            check("untrusted Rust: cargo check is skipped and says so", find(report, "not run: cargo check") >= 0, report);
            check("untrusted Rust: the saved cargo diagnostics are kept", find(after, "a saved cargo error") >= 0, after);
        }
    }

    // A virtualenv inside an untrusted repo is the repo's own code: its
    // python must not run, and it must not be put on PATH for indexers. The
    // planted interpreter leaves a marker if anything runs it.
    {
        let dir = "data/trust-check/venv";
        rm_rf(dir);
        mkdir_p(dir);
        if sh(argv(["cp", "-r", "fixtures/tiny-py", str(dir, "/repo")]), "", o) {
            let repo = tr_realpath(str(dir, "/repo"));
            let out = str(dir, "/out");
            // In the map folder: the one place every sealed run and the live
            // server can write, so the marker shows any run of the virtualenv.
            mkdir_p(out);
            let marker = str(tr_realpath(out), "/venv-python-ran");
            mkdir_p(str(dir, "/repo/.venv/bin"));
            write_file(str(dir, "/repo/.venv/pyvenv.cfg"), "home = /usr/bin\n");
            // Exec the system python by absolute path: with the virtualenv
            // first on PATH a bare `python3` is this script again.
            var sp: u8[>..] = [];
            var e2: u8[>..] = [];
            run(argv(["sh", "-c", "command -v python3 || echo /usr/bin/python3"]), "", sp, e2);
            let fake = str("#!/bin/sh\necho ran >> ", marker, "\nexec ", trim(sp), " \"$@\"\n");
            tr_plant(str(dir, "/repo/.venv/bin/python"), fake);
            tr_plant(str(dir, "/repo/.venv/bin/python3"), fake);
            tr_plant(str(dir, "/repo/.venv/bin/pip"), fake);
            var m: u8[>..] = [];
            tr_swan(TR_UNTRUSTED, ["map", repo, out], m);
            check("untrusted repo: mapping never runs its virtualenv's python, pip or PATH entries", !file_exists(marker), m);
            check("untrusted repo: the map is still built (python indexed with the system interpreter)",
                  file_exists(str(out, "/swan.db")), m);
            tr_swan(TR_UNTRUSTED, ["check", repo, out], m);
            check("untrusted repo: swan check never runs its virtualenv either", !file_exists(marker), "");
            let have_pyright = exists("tools/node_modules/.bin/pyright-langserver");
            if have_pyright {
                var live: u8[>..] = [];
                tr_live(TR_UNTRUSTED, str(out, "/swan.db"), """{"relative_path":"main.py","live":true}""", live);
                check("untrusted repo: live diagnostics answer", find(live, "\"result\"") >= 0, live);
                check("untrusted repo: the live python server never runs its virtualenv's python", !file_exists(marker), live);
            } else { print("skip live python trust checks: pyright-langserver is not installed"); }
            var tm: u8[>..] = [];
            tr_stdout(TR_TRUSTED, ["map", repo, out], tm);
            check("trusted repo: its virtualenv is used", file_exists(marker), tm);
            if have_pyright {
                delete_file(marker);
                var live2: u8[>..] = [];
                tr_live(TR_TRUSTED, str(out, "/swan.db"), """{"relative_path":"main.py","live":true}""", live2);
                check("trusted repo: the live python server uses its virtualenv (proves the check above can fail)",
                      file_exists(marker), live2);
            }
        }
    }
}
