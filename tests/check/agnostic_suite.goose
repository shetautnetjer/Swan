// Repos shaped the way strangers' repos are: Swan has to map them from cold,
// with nothing installed into them. Found by a cold test on public repos
// (2026-11-14), where these shapes gave no map or no cross-file answers.
//
//   tiny-syntax     Go, shell (one script known only by its #! line) and a
//                   Makefile: no SCIP indexer here, so the syntax map answers.
//   tiny-srcpy      a Python "src layout": tests import the package that
//                   lives under src/, which is never installed.
//   tiny-ts-badcfg  a tsconfig that extends a shared config from an npm
//                   package that is not installed.
// (Was tests/agnostic_check.ts.)

import std;
import os;
import json;
import .harness;

// Maps a fixture into work/<fixture>; the report (stdout and stderr) and
// the exit code.
fn ag_map(work: const u8[:], fixture: const u8[:], report: u8[>..]&) -> i32 {
    var out: u8[>..] = [];
    var err: u8[>..] = [];
    var abs: u8[>..] = [];
    var e2: u8[>..] = [];
    run(argv(["realpath", str("fixtures/", fixture)]), "", abs, e2);
    let code = run(argv(["bin/swan", "map", trim(abs), str(work, "/", fixture)]), "", out, err);
    report.clear();
    report.append(out);
    report.append(err);
    return code;
}

fn agnostic_suite() {
    var tmp: u8[>..] = [];
    var e: u8[>..] = [];
    run(argv(["mktemp", "-d", "-t", "swan-agnostic-XXXXXX"]), "", tmp, e);
    let work = trim(tmp);
    var report: u8[>..] = [];

    let code = ag_map(work, "tiny-syntax", report);
    check("tiny-syntax: Go, shell and Make map (no 'no language found')", code == 0 && find(report, "syntax-index") >= 0, report);
    let db = str(work, "/tiny-syntax/swan.db");

    var t = swan_query(db, "symbol", "helper", "");
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let r1, e1 = json::parse(t, d1, x1);
    check("Go: helper() is defined in helper.go", jlines(r1) == "helper.go:4", t);

    t = swan_query(db, "callers", "helper", "");
    var d2: json::Node[>..] = []; var x2: u8[>..] = [];
    let r2, e2b = json::parse(t, d2, x2);
    check("Go: helper() is called from main in main.go, at line 15", direct_sites(r2) == "main.go:15", t);

    t = swan_query(db, "symbol", "Greeter/Greet", "");
    var d3: json::Node[>..] = []; var x3: u8[>..] = [];
    let r3, e3 = json::parse(t, d3, x3);
    check("Go: Greeter/Greet is a method of Greeter", jstr(nth(r3, 0), "kind") == "method", t);

    t = swan_query(db, "callers", "greet", "");
    var d4: json::Node[>..] = []; var x4: u8[>..] = [];
    let r4, e4 = json::parse(t, d4, x4);
    var loud = false;
    let c4 = json::member(r4, "callers");
    if c4 { json::each(c4) { c => if ends_with(jstr(c, "name_path"), "loud_greet") && jlines(json::member(c, "call_sites")) == "util/run.sh:7" { loud = true; } }; }
    check("shell: greet is called inside loud_greet, by name", loud, t);

    t = swan_query(db, "symbol", "usage", "");
    var d5: json::Node[>..] = []; var x5: u8[>..] = [];
    let r5, e5 = json::parse(t, d5, x5);
    check("shell: a script with no extension (bin/tool) is read by its #! line", jlines(r5) == "bin/tool:3", t);

    t = swan_query(db, "callers", "usage", "");
    var d6: json::Node[>..] = []; var x6: u8[>..] = [];
    let r6, e6 = json::parse(t, d6, x6);
    check("shell: top-level code calling usage counts, at bin/tool:6", direct_sites(r6) == "bin/tool:6", t);

    t = swan_query(db, "callers", "deps", "");
    var d7: json::Node[>..] = []; var x7: u8[>..] = [];
    let r7, e7 = json::parse(t, d7, x7);
    check("Make: the build target needs deps", direct_sites(r7) == "Makefile:1", t);

    t = swan_query(db, "refs", "helper", "");
    var d8: json::Node[>..] = []; var x8: u8[>..] = [];
    let r8, e8 = json::parse(t, d8, x8);
    let refs = json::member(nth(r8, 0), "references");
    var all_by_name = true;
    if refs { json::each(refs) { r => if !jtrue(r, "by_name") { all_by_name = false; } }; }
    check("syntax references say they were found by name", jcount(refs) > 0 && all_by_name, t);

    ag_map(work, "tiny-srcpy", report);
    let pdb = str(work, "/tiny-srcpy/swan.db");
    t = swan_query(pdb, "callers", "add", "");
    var d9: json::Node[>..] = []; var x9: u8[>..] = [];
    let r9, e9 = json::parse(t, d9, x9);
    check("src layout: tests' `tinypkg.add(...)` reaches src/tinypkg/core.py's add",
          find(str(",", direct_sites(r9), ","), ",tests/test_core.py:5,") >= 0, t);

    t = swan_query(pdb, "impls", "IOError", "");
    var d10: json::Node[>..] = []; var x10: u8[>..] = [];
    let r10, e10 = json::parse(t, d10, x10);
    check("subclasses of IOError (an alias of OSError) are found",
          jlines(json::member(r10, "implementations")) == "src/tinypkg/core.py:5", t);

    let tcode = ag_map(work, "tiny-ts-badcfg", report);
    check("unreadable tsconfig: the map is built with Swan's own config and says so",
          tcode == 0 && find(report, "tsconfig.json cannot be read") >= 0, report);
    t = swan_query(str(work, "/tiny-ts-badcfg/swan.db"), "callers", "shout", "");
    var d11: json::Node[>..] = []; var x11: u8[>..] = [];
    let r11, e11 = json::parse(t, d11, x11);
    check("unreadable tsconfig: shout() is used in b.ts at line 3", direct_sites(r11) == "src/b.ts:3", t);

    rm_rf(work);
}
