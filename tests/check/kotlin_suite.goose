// Kotlin end to end: maps a copy of fixtures/tiny-kt (scip-java through its
// Gradle build), checks the map, then asks JetBrains' Kotlin language server
// for diagnostics before and after an edit. The first run imports the
// Gradle build (Gradle fetches itself and the Kotlin plugin into
// .tools/gradle-home), which takes minutes; later runs reuse it.
// (Was tests/kotlin_live_check.ts.)

import std;
import os;
import json;
import .harness;

// The errors in a get_diagnostics answer: how many, and their lines.
fn kt_errors(text: const u8[:], lines: u8[>..]&) -> i64 {
    var d: json::Node[>..] = []; var x: u8[>..] = [];
    let r, e = json::parse(text, d, x);
    var n = 0;
    lines.clear();
    let ds = json::member(r, "diagnostics");
    if ds { json::each(ds) { g => if jstr(g, "severity") == "error" { n++; format(lines, ",", jint(g, "line"), ","); } }; }
    return n;
}

fn kotlin_suite() {
    if !exists(".tools/kotlin-lsp") { print("skipped: no .tools/kotlin-lsp (scripts/fetch-tools.sh)"); return; }
    rm_rf("data/kt-live");
    mkdir_p("data/kt-live");
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-kt", "data/kt-live/repo"]), "", o) else { return; }
    guard sh(argv(["bin/swan", "map", "data/kt-live/repo", "data/kt-live/out"]), "", o) else { return; }

    let db = "data/kt-live/out/swan.db";
    var t = swan_query(db, "impls", "Shape", "");
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let r1, e1 = json::parse(t, d1, x1);
    check("kotlin map: Square and Circle implement Shape",
          sorted_join(jlist(json::member(r1, "implementations"), "name_path")) == "Circle,Square", t);
    t = swan_query(db, "callers", "totalArea", "");
    var d2: json::Node[>..] = []; var x2: u8[>..] = [];
    let r2, e2 = json::parse(t, d2, x2);
    check("kotlin map: main calls totalArea", jany(json::member(r2, "callers"), "name_path", "main"), t);

    guard mcp_open(argv(["bin/swan", "serve", db]), "") else { return; }
    let rel = "src/main/kotlin/demo/Main.kt";
    let file = str("data/kt-live/repo/", rel);
    var orig: u8[>..] = [];
    read_file(file, orig);
    let args = str("{\"relative_path\":\"", rel, "\",\"live\":true}");
    var lines: u8[>..] = [];

    var clean: u8[>..] = [];
    let ok1 = mcp_call("get_diagnostics", args, clean) == 1;
    var dc: json::Node[>..] = []; var xc: u8[>..] = [];
    let rc, ec = json::parse(clean, dc, xc);
    let n_clean = kt_errors(clean, lines);
    check("kotlin: the clean file has no errors (the first call imports the Gradle build)",
          ok1 && !jtrue(rc, "import_failed") && n_clean == 0, clean);

    replace_in_file(file, "println(totalArea(shapes))", "val x: Int = \"text\"\n    println(totalArea(shapes))");
    var broken: u8[>..] = [];
    let ok2 = mcp_call("get_diagnostics", args, broken) == 1;
    let nb = kt_errors(broken, lines);
    check("kotlin: a String assigned to an Int is an error on the new line", ok2 && find(lines, ",12,") >= 0, broken);

    write_file(file, orig);
    var fixed: u8[>..] = [];
    let ok3 = mcp_call("get_diagnostics", args, fixed) == 1;
    let n_fixed = kt_errors(fixed, lines);
    check("kotlin: gone again after the undo", ok3 && n_fixed == 0, fixed);
    let code = mcp_close_code();
    check("serve exits cleanly", code == 0, str("exit ", code));
}
