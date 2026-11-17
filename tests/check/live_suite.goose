// The live adapter end to end: maps a copy of fixtures/tiny-rs, starts
// `swan serve`, and asks rust-analyzer (through the goose-lsp library) for
// diagnostics and implementations before and after edits the map has not
// seen; then pyright and the TypeScript server in the same serve.
// (Was tests/live_check.ts.)

import std;
import os;
import json;
import .harness;

// Error diagnostics in an answer: how many, and whether one has this code
// (any code if "") on this line (any line if 0).
fn lv_errors(text: const u8[:], code: const u8[:], line: i64, hit: bool&) -> i64 {
    var d: json::Node[>..] = []; var x: u8[>..] = [];
    let r, e = json::parse(text, d, x);
    var n = 0;
    hit = false;
    let ds = json::member(r, "diagnostics");
    if ds {
        json::each(ds) { g =>
            if jstr(g, "severity") == "error" {
                n++;
                if (code.len == 0 || jstr(g, "code") == code) && (line == 0 || jint(g, "line") == line) { hit = true; }
            }
        };
    }
    return n;
}
// Any-severity diagnostic with this code on this line (TypeScript's check
// does not ask for the severity).
fn lv_code_at(text: const u8[:], code: const u8[:], line: i64) -> bool {
    var d: json::Node[>..] = []; var x: u8[>..] = [];
    let r, e = json::parse(text, d, x);
    var hit = false;
    let ds = json::member(r, "diagnostics");
    if ds { json::each(ds) { g => if jstr(g, "code") == code && jint(g, "line") == line { hit = true; } }; }
    return hit;
}
// "path:line" of each implementation, sorted and comma-joined.
fn lv_impls(text: const u8[:]) -> u8[>..] {
    var d: json::Node[>..] = []; var x: u8[>..] = [];
    let r, e = json::parse(text, d, x);
    return jlines(json::member(r, "implementations"));
}

fn live_suite() {
    let repo = "data/live-rs/repo";
    let out = "data/live-rs/out";
    rm_rf("data/live-rs");
    mkdir_p("data/live-rs");
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-rs", repo]), "", o) else { return; }
    guard sh(argv(["bin/swan", "map", repo, out]), "", o) else { return; }
    guard mcp_open(argv(["bin/swan", "serve", str(out, "/swan.db")]), "") else { return; }

    let lib = str(repo, "/src/lib.rs");
    var original: u8[>..] = [];
    read_file(lib, original);
    let rs_args = """{"relative_path":"src/lib.rs","live":true}""";
    var hit = false;

    var clean: u8[>..] = [];
    let ok1 = mcp_call("get_diagnostics", rs_args, clean) == 1;
    let n1 = lv_errors(clean, "", 0, hit);
    check("live diagnostics on the clean crate: no errors (first call starts rust-analyzer)", ok1 && n1 == 0, clean);

    var impls: u8[>..] = [];
    let ok2 = mcp_call("find_implementations", """{"name_path":"Area","live":true}""", impls) == 1;
    check("live implementations of Area: the two impl blocks, lines 23 and 29",
          ok2 && lv_impls(impls) == "src/lib.rs:23,src/lib.rs:29", impls);

    // An edit the map has not seen: a wrong argument count.
    replace_in_file(lib, "Tile::new(2).area()", "Tile::new(2, 3).area()");
    var broken: u8[>..] = [];
    let t0 = clock();
    let ok3 = mcp_call("get_diagnostics", rs_args, broken) == 1;
    let ms = ((clock() - t0) * 1000.0) as i64;
    lv_errors(broken, "E0061", 56, hit);
    check("after the edit: E0061 on line 56, without a map or check run", ok3 && hit, broken);
    print(str("     error seen ", ms, " ms after asking"));

    write_file(lib, original);
    var fixed: u8[>..] = [];
    let ok4 = mcp_call("get_diagnostics", rs_args, fixed) == 1;
    let n4 = lv_errors(fixed, "", 0, hit);
    check("after undoing it: the error is gone", ok4 && n4 == 0, fixed);

    // A new implementation the map does not know.
    var with_ring: u8[>..] = [];
    with_ring.append(original);
    with_ring.append("\npub struct Ring;\n\nimpl Area for Ring {\n    fn area(&self) -> u32 {\n        0\n    }\n}\n");
    write_file(lib, with_ring);
    var more: u8[>..] = [];
    mcp_call("find_implementations", """{"name_path":"Area","live":true}""", more);
    check("a new impl Area for Ring shows up live", find(str(",", lv_impls(more), ","), ",src/lib.rs:62,") >= 0, more);
    var mapped: u8[>..] = [];
    mcp_call("find_implementations", """{"name_path":"Area"}""", mapped);
    var dm: json::Node[>..] = []; var xm: u8[>..] = [];
    let rm, em = json::parse(mapped, dm, xm);
    check("while the map still has the two it was built with",
          sorted_join(jlist(json::member(rm, "implementations"), "name_path")) == "Disc,Tile", mapped);
    write_file(lib, original);

    var java: u8[>..] = [];
    let jok = mcp_call("get_diagnostics", """{"relative_path":"src/missing.go","live":true}""", java);
    check("a language without a live server says so instead of failing hard", jok == 0 && find(java, "no live server") >= 0, java);

    // Switching language: pyright replaces rust-analyzer in the same serve.
    guard sh(argv(["cp", "-r", "fixtures/tiny-py", str(repo, "/py")]), "", o) else { mcp_close(); return; }
    let py_file = str(repo, "/py/shapes/__init__.py");
    var py_orig: u8[>..] = [];
    read_file(py_file, py_orig);
    let py_args = """{"relative_path":"py/shapes/__init__.py","live":true}""";
    var pc: u8[>..] = [];
    let pok1 = mcp_call("get_diagnostics", py_args, pc) == 1;
    let pn1 = lv_errors(pc, "", 0, hit);
    check("pyright: the clean module has no errors", pok1 && pn1 == 0, pc);
    var py_broken: u8[>..] = [];
    py_broken.append(py_orig);
    py_broken.append("\n\ndef broken() -> int:\n    return \"text\"\n");
    write_file(py_file, py_broken);
    var pb: u8[>..] = [];
    let t1 = clock();
    let pok2 = mcp_call("get_diagnostics", py_args, pb) == 1;
    let pms = ((clock() - t1) * 1000.0) as i64;
    lv_errors(pb, "", 33, hit);
    check("pyright: a str returned as int is an error on the new line", pok2 && hit, pb);
    print(str("     error seen ", pms, " ms after asking"));
    write_file(py_file, py_orig);
    var pf: u8[>..] = [];
    let pok3 = mcp_call("get_diagnostics", py_args, pf) == 1;
    let pn3 = lv_errors(pf, "", 0, hit);
    check("pyright: gone again after the undo", pok3 && pn3 == 0, pf);

    // And the TypeScript server after pyright.
    guard sh(argv(["cp", "-r", "fixtures/tiny-ts", str(repo, "/ts")]), "", o) else { mcp_close(); return; }
    let ts_file = str(repo, "/ts/src/store.ts");
    var ts_orig: u8[>..] = [];
    read_file(ts_file, ts_orig);
    let ts_args = """{"relative_path":"ts/src/store.ts","live":true}""";
    var tc: u8[>..] = [];
    let tok1 = mcp_call("get_diagnostics", ts_args, tc) == 1;
    let tn1 = lv_errors(tc, "", 0, hit);
    check("typescript: the clean file has no errors", tok1 && tn1 == 0, tc);
    var ts_lines = 1;
    for c in ts_orig { if c == '\n' { ts_lines++; } }
    var ts_broken: u8[>..] = [];
    ts_broken.append(ts_orig);
    ts_broken.append("\nexport const broken: number = \"text\";\n");
    write_file(ts_file, ts_broken);
    var tb: u8[>..] = [];
    let t2 = clock();
    let tok2 = mcp_call("get_diagnostics", ts_args, tb) == 1;
    let tms = ((clock() - t2) * 1000.0) as i64;
    check("typescript: a string assigned to a number is TS2322 on the new line", tok2 && lv_code_at(tb, "2322", ts_lines + 1), tb);
    print(str("     error seen ", tms, " ms after asking"));
    write_file(ts_file, ts_orig);

    let code = mcp_close_code();
    check("serve exits cleanly and stops rust-analyzer", code == 0, str("exit ", code));
    live_java("0");
    live_java("1");
}

// Eclipse JDT LS (tools/modules.json "java"): with trust "0" the repo is
// opened as plain folders, sealed, with its source folders found from the
// package lines; with "1" Gradle and Maven import is on. Either way a type
// error shows up live, a second source folder has no wrong-package errors,
// and nothing is written into the repo.
fn live_java(trust: const u8[:]) {
    let base = str("data/live-java-", trust);
    let repo = str(base, "/repo");
    let out = str(base, "/out");
    rm_rf(base);
    mkdir_p(base);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-java", repo]), "", o) else { return; }
    mkdir_p(str(repo, "/src/test/java/shapes"));
    write_file(str(repo, "/src/test/java/shapes/ShapesCheck.java"),
               "package shapes;\n\nimport java.util.List;\n\nfinal class ShapesCheck {\n    static double area() {\n        return Shapes.totalArea(List.of(new Square(3)));\n    }\n}\n");
    guard sh(argv(["bin/swan", "map", repo, out]), "", o) else { return; }
    var snap: u8[>..] = [];
    var e0: u8[>..] = [];
    run(argv(["cp", "-r", repo, str(base, "/before")]), "", snap, e0);
    let mode = if trust == "1" { "trusted, with build import" } else { "untrusted, plain folders, sealed" };
    guard mcp_open(argv(["bin/swan", "serve", str(out, "/swan.db")]), envv("SWAN_TRUST_BUILD", trust)) else { return; }
    var hit = false;
    let f = str(repo, "/src/main/java/shapes/Shapes.java");
    var orig: u8[>..] = [];
    read_file(f, orig);
    let args = """{"relative_path":"src/main/java/shapes/Shapes.java","live":true}""";
    var clean: u8[>..] = [];
    let ok1 = mcp_call("get_diagnostics", args, clean) == 1;
    check(str("java (", mode, "): the clean file has no errors"), ok1 && lv_errors(clean, "", 0, hit) == 0, clean);
    var tc: u8[>..] = [];
    let ok2 = mcp_call("get_diagnostics", """{"relative_path":"src/test/java/shapes/ShapesCheck.java","live":true}""", tc) == 1;
    check(str("java (", mode, "): a file in a second source folder uses the main one with no errors"),
          ok2 && lv_errors(tc, "", 0, hit) == 0 && find(tc, "expected package") < 0, tc);
    replace_in_file(f, "return total;", "return \"oops\";");
    var bad: u8[>..] = [];
    let t0 = clock();
    let ok3 = mcp_call("get_diagnostics", args, bad) == 1;
    let ms = ((clock() - t0) * 1000.0) as i64;
    lv_errors(bad, "", 13, hit);
    check(str("java (", mode, "): a String returned as double is an error on line 13"), ok3 && hit && find(bad, "Type mismatch") >= 0, bad);
    print(str("     error seen ", ms, " ms after asking"));
    write_file(f, orig);
    var fixed: u8[>..] = [];
    let ok4 = mcp_call("get_diagnostics", args, fixed) == 1;
    check(str("java (", mode, "): gone again after the undo"), ok4 && lv_errors(fixed, "", 0, hit) == 0, fixed);
    let code = mcp_close_code();
    var d: u8[>..] = [];
    let same = run(argv(["diff", "-r", str(base, "/before"), repo]), "", d, e0) == 0;
    check(str("java (", mode, "): nothing was written into the repo, and serve stops JDT LS"), same && code == 0, str("exit ", code, "\n", d));
}
