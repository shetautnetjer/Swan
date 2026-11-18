// One check per language fixture beyond the TypeScript and Rust ones that
// have their own suites: each is mapped and asked the questions an engineer
// would ask first. (Was tests/lang_check.ts.) A section whose setup fails
// stops there; the others still run.

import std;
import os;
import json;
import .harness;

fn lg_db_query(db: const u8[:], a: const u8[:], b: const u8[:], c: const u8[:], t: u8[>..]&) {
    t.clear();
    t.append(swan_query(db, a, b, c));
}

fn lang_suite() {
    lang_js();
    lang_python();
    lang_java();
    lang_java_batch();
    lang_batch_touches();
    lang_what_broke();
    lang_goose_map();
    lang_go_map();
    lang_py_attr_family();
    lang_gradle();
    lang_cuda();
    lang_modules();
}

fn lang_js() {
    // No tsconfig: Swan generates one outside the repo, with allowJs.
    var o: u8[>..] = [];
    guard sh(argv(["scripts/index-repo.sh", "fixtures/tiny-js", "data/tiny-js"]), "", o) else { return; }
    let db = "data/tiny-js/swan.db";
    var t: u8[>..] = [];
    lg_db_query(db, "refs", "add", "", t);
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let r1, e1 = json::parse(t, d1, x1);
    let add_sites = sorted_join(ref_sites(r1));
    check("js: add() from math.mjs is used in main.js and in math.mjs itself", add_sites == "main.js:2,main.js:9,math.mjs:11", add_sites);
    lg_db_query(db, "refs", "double", "", t);
    var d2: json::Node[>..] = []; var x2: u8[>..] = [];
    let r2, e2 = json::parse(t, d2, x2);
    check("js: double() from legacy.cjs reaches main.js through require()", has_line(ref_sites(r2), "main.js:9"), t);
    lg_db_query(db, "symbol", "Counter/bump", "", t);
    var d3: json::Node[>..] = []; var x3: u8[>..] = [];
    let r3, e3 = json::parse(t, d3, x3);
    check("js: Counter.bump is a method", jstr(nth(r3, 0), "kind") == "method", t);
    check("js: the repo was not written to (no tsconfig.json appeared)", !file_exists("fixtures/tiny-js/tsconfig.json"), "");
}

fn lang_python() {
    // A copy with its own virtualenv holding `requests`, made with uv.
    let w = "data/py-check";
    rm_rf(w);
    mkdir_p(w);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-py", str(w, "/repo")]), "", o) else { return; }
    guard sh(argv(["uv", "venv", "-q", str(w, "/repo/.venv")]), "", o) else { return; }
    guard sh(argv(["uv", "pip", "install", "-q", "--python", str(w, "/repo/.venv/bin/python"), "requests==2.32.5"]), "", o) else { return; }
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "check", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    let db = str(w, "/map/swan.db");
    var t: u8[>..] = [];
    lg_db_query(db, "impls", "Shape", "", t);
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let r1, e1 = json::parse(t, d1, x1);
    check("python: Square and Circle implement Shape",
          sorted_join(jlist(json::member(r1, "implementations"), "name_path")) == "Circle,Square", t);
    lg_db_query(db, "hierarchy", "Shape/area", "", t);
    var d2: json::Node[>..] = []; var x2: u8[>..] = [];
    let r2, e2 = json::parse(t, d2, x2);
    check("python: both area() methods override Shape.area",
          sorted_join(jlist(json::member(r2, "subtypes"), "name_path")) == "Circle/area,Square/area", t);
    lg_db_query(db, "callees", "fetch_status", "", t);
    var d3: json::Node[>..] = []; var x3: u8[>..] = [];
    let r3, e3 = json::parse(t, d3, x3);
    var got = false;
    let cl = json::member(r3, "callees");
    if cl { json::each(cl) { c => if jstr(c, "name_path") == "get" && jstr(c, "package") == "requests 2.32.5" { got = true; } }; }
    check("python: requests.get resolves to the venv's requests 2.32.5", got, t);
    lg_db_query(db, "diagfile", ".", "", t);
    var d4: json::Node[>..] = []; var x4: u8[>..] = [];
    let r4, e4 = json::parse(t, d4, x4);
    check("python: pyright finds no errors in the clean fixture (requests imports resolve)",
          jint(json::member(r4, "map_total"), "errors") == 0, t);
    var ta: u8[>..] = [];
    var tb: u8[>..] = [];
    lg_db_query(db, "symbol", "total_area", "", ta);
    lg_db_query(db, "symbol", "Square/area", "", tb);
    var d5: json::Node[>..] = []; var x5: u8[>..] = [];
    let r5, e5 = json::parse(ta, d5, x5);
    var d6: json::Node[>..] = []; var x6: u8[>..] = [];
    let r6, e6 = json::parse(tb, d6, x6);
    check("python: top-level functions and methods are told apart",
          jstr(nth(r5, 0), "kind") == "function" && jstr(nth(r6, 0), "kind") == "method", str(ta, tb));

    // Break Square's constructor; pyright should report it in Square's callers.
    var et: u8[>..] = [];
    let er = serve_once(db, "replace_symbol_body", """{"name_path":"Square/__init__","relative_path":"shapes/__init__.py","body":"def __init__(self, side: float, unit: str) -> None:\n        self.side = side\n        self.unit = unit"}""", et);
    check("python: replace_symbol_body on a method", er == 1, et);
    guard sh(argv(["bin/swan", "check", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    lg_db_query(db, "diag", "Square", "shapes/__init__.py", t);
    var d7: json::Node[>..] = []; var x7: u8[>..] = [];
    let r7, e7 = json::parse(t, d7, x7);
    var in_syms: u8[>..] = [];
    let dl = json::member(r7, "diagnostics");
    if dl { json::each(dl) { d => if jstr(d, "severity") == "error" { format(in_syms, jstr(d, "in_symbol"), "\n"); } }; }
    check("python: pyright's errors land in Square's callers, report and ShapeTests.test_square",
          has_line(in_syms, "report") && has_line(in_syms, "ShapeTests/test_square"), t);
}

// edit_batch: several edits as one change, all or nothing.
fn lang_java_batch() {
    let w = "data/java-batch";
    rm_rf(w);
    mkdir_p(w);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-java", str(w, "/repo")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    let db = str(w, "/map/swan.db");
    let good = """{"op":"rename_symbol","name_path":"/Shape/area","relative_path":"src/main/java/shapes/Shape.java","new_name":"surface"},{"op":"insert_after_symbol","name_path":"Shapes/totalArea","relative_path":"src/main/java/shapes/Shapes.java","body":"    public static int count(List<Shape> shapes) {\n        return shapes.size();\n    }"},{"op":"rewrite_pattern","pattern":"side * side","rewrite":"Math.pow(side, 2)","language":"java"}""";
    var pt: u8[>..] = [];
    let pr = serve_once(db, "edit_batch", str("{\"edits\":[", good, "]}"), pt);
    var same: u8[>..] = [];
    var e0: u8[>..] = [];
    let unchanged = run(argv(["diff", "-r", "fixtures/tiny-java", str(w, "/repo")]), "", same, e0) == 0;
    check("batch: three edits are planned together and nothing is written",
          pr == 1 && find(pt, "\"applied\":false") >= 0 && find(pt, "\"ok\":false") < 0 && find(pt, "\"files\":4") >= 0 && unchanged, pt);

    // The third edit names a method that is not there: the first two are undone.
    var ft: u8[>..] = [];
    let fr = serve_once(db, "edit_batch", """{"edits":[{"op":"rename_symbol","name_path":"/Shape/area","relative_path":"src/main/java/shapes/Shape.java","new_name":"surface"},{"op":"insert_after_symbol","name_path":"Shapes/totalArea","relative_path":"src/main/java/shapes/Shapes.java","body":"    // added"},{"op":"replace_symbol_body","name_path":"Shapes/noSuchMethod","relative_path":"src/main/java/shapes/Shapes.java","body":"x"}],"apply":true}""", ft);
    let back = run(argv(["diff", "-r", "fixtures/tiny-java", str(w, "/repo")]), "", same, e0) == 0;
    var info: u8[>..] = [];
    serve_once(db, "index_info", "{}", info);
    var t: u8[>..] = [];
    lg_db_query(db, "callers", "/Shape/area", "", t);
    check("batch: when one edit fails, every file and the map go back, and nothing is left stale",
          fr == 0 && find(ft, "\"failed_at\":3") >= 0 && find(ft, "\"rolled_back\":true") >= 0 && back &&
          find(info, "\"stale_file_count\":0") >= 0 && find(t, "\"name_path\":\"Shapes/totalArea\"") >= 0, str(ft, "\n     ", info));

    var at: u8[>..] = [];
    let ar = serve_once(db, "edit_batch", str("{\"edits\":[", good, "],\"apply\":true}"), at);
    check("batch: the three edits apply as one change to four files", ar == 1 && find(at, "\"applied\":true") >= 0 &&
          find(at, "Circle.java") >= 0 && find(at, "Square.java") >= 0 && find(at, "Shape.java") >= 0 && find(at, "Shapes.java") >= 0, at);
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "check", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    lg_db_query(db, "diagfile", ".", "", t);
    var sq: u8[>..] = [];
    read_file(str(w, "/repo/src/main/java/shapes/Square.java"), sq);
    check("batch: after it, javac finds no errors and the later edits saw the earlier ones",
          find(t, "\"errors\":0") >= 0 && find(sq, "public double surface()") >= 0 && find(sq, "Math.pow(side, 2)") >= 0, t);
}

// A planned batch says what it reaches beyond its own edits, from
// Spread-Wings (built beside Swan, as ../spread-wings), and the tests to run.
fn lang_batch_touches() {
    var swb: u8[>..] = [];
    env("PWD", swb);
    swb.append("/../spread-wings/bin/spread-wings");
    guard file_exists(swb) else {
        write_stderr("skip: batch touches: ../spread-wings/bin/spread-wings is not built\n");
        return;
    }
    var ev: u8[>..] = [];
    format(ev, "SWAN_SPREAD_WINGS=", swb);
    ev.push(0);
    let w = "data/py-touches";
    rm_rf(w);
    mkdir_p(w);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-py", str(w, "/repo")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    let db = str(w, "/map/swan.db");
    let body = """{"edits":[{"op":"replace_symbol_body","name_path":"total_area","relative_path":"shapes/__init__.py","body":"def total_area(shapes):\n    return 0"}]}""";
    var t: u8[>..] = [];
    var r: i64 = -1;
    if mcp_open(argv(["bin/swan", "serve", db]), ev) { r = mcp_call("edit_batch", body, t); mcp_close(); }
    check("batch touches: a replaced body lists the callers it does not edit, and their test",
          r == 1 && find(t, "\"available\":true") >= 0 && find(t, "{\"path\":\"main.py\",\"why\":[\"calls it\"") >= 0 &&
          find(t, "\"tests\":[\"test_shapes.py\"]") >= 0 && file_exists(str(w, "/map/wings.db")), t);

    // A rename edits its callers itself: nothing is left reached but not edited.
    let ren = """{"edits":[{"op":"rename_symbol","name_path":"total_area","relative_path":"shapes/__init__.py","new_name":"sum_area"}]}""";
    if mcp_open(argv(["bin/swan", "serve", db]), ev) { r = mcp_call("edit_batch", ren, t); mcp_close(); }
    check("batch touches: a rename's own sites are not listed again", r == 1 && find(t, "\"reached_not_edited\":[]") >= 0 &&
          find(t, "\"tests\":[\"test_shapes.py\"]") >= 0, t);

    if mcp_open(argv(["bin/swan", "serve", db]), argv(["SWAN_SPREAD_WINGS=/nonexistent/spread-wings"])) { r = mcp_call("edit_batch", body, t); mcp_close(); }
    var same: u8[>..] = [];
    var e0: u8[>..] = [];
    let unchanged = run(argv(["diff", "-r", "fixtures/tiny-py", str(w, "/repo")]), "", same, e0) == 0;
    check("batch touches: without spread-wings the plan still works and says why", r == 1 &&
          find(t, "\"available\":false,\"why\":\"SWAN_SPREAD_WINGS is /nonexistent/spread-wings") >= 0 && unchanged, t);
}

// what_broke / `swan broke`: only the errors an edit introduced.
fn lang_what_broke() {
    let w = "data/py-broke";
    rm_rf(w);
    mkdir_p(w);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-py", str(w, "/repo")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    let f = str(w, "/repo/shapes/__init__.py");
    var orig: u8[>..] = [];
    read_file(f, orig);
    var e: u8[>..] = [];
    var t: u8[>..] = [];
    let c1 = run(argv(["bin/swan", "broke", str(w, "/map"), "shapes/__init__.py"]), "", t, e);
    check("broke: a clean file has nothing new (exit 0)", c1 == 0 && find(t, "\"new_errors\":0,") >= 0, t);
    write_file(f, str(orig, "\n\ndef broken() -> int:\n    return \"text\"\n"));
    let c2 = run(argv(["bin/swan", "broke", str(w, "/map"), "shapes/__init__.py"]), "", t, e);
    check("broke: the error an edit introduced is reported once, with its line (exit 1)",
          c2 == 1 && find(t, "\"new_errors\":1,") >= 0 && find(t, "\"line\":33") >= 0, t);
    let c3 = run(argv(["bin/swan", "broke", str(w, "/map"), "shapes/__init__.py"]), "", t, e);
    check("broke: asked again, it is already there, not new (exit 0)",
          c3 == 0 && find(t, "\"new_errors\":0,") >= 0 && find(t, "\"errors_already_there\":1") >= 0, t);
    write_file(f, str(orig, "\n\ndef broken() -> int:\n    return \"text\"\n\n\ndef worse() -> str:\n    return 5\n"));
    var m: u8[>..] = [];
    let r4 = serve_once(str(w, "/map/swan.db"), "what_broke", """{"files":["shapes/__init__.py"]}""", m);
    check("broke: the what_broke tool reports only the second edit's error",
          r4 == 1 && find(m, "\"new_errors\":1,") >= 0 && find(m, "\"line\":37") >= 0 && find(m, "\"errors_already_there\":1") >= 0, m);
}

// A class attribute a subclass overrides is renamed as one family: the
// base's declaration, each subclass's own assignment, and every use.
fn lang_py_attr_family() {
    let w = "data/py-attrs";
    rm_rf(w);
    mkdir_p(str(w, "/repo"));
    write_file(str(w, "/repo/chan.py"),
               "class Channel:\n    session: str = \"\"\n\n    def home(self) -> str:\n        return self.session\n\n\nclass Boss(Channel):\n    session = \"boss\"\n\n    def where(self) -> str:\n        return self.session\n\n\nclass Plain(Channel):\n    pass\n\n\ndef show(c: Channel) -> str:\n    return c.session + Boss().session\n");
    var o: u8[>..] = [];
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    let db = str(w, "/map/swan.db");
    var t: u8[>..] = [];
    let r = serve_once(db, "rename_symbol", """{"name_path":"Boss/session","relative_path":"chan.py","new_name":"login","apply":true}""", t);
    var text: u8[>..] = [];
    read_file(str(w, "/repo/chan.py"), text);
    check("python: renaming a subclass's class attribute renames the base's and every use with it",
          r == 1 && find(text, "session") < 0 && find(text, "login: str = \"\"") >= 0 && find(text, "login = \"boss\"") >= 0 &&
          find(text, "return c.login + Boss().login") >= 0, str(t, "\n", text));
}

// A Goose map, made by asking Goose's own language server (swan lsp-index):
// references the compiler resolved, callers, a rename across files, and no
// walk into hidden folders.
fn lang_goose_map() {
    let w = "data/goose-map";
    rm_rf(w);
    mkdir_p(w);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-goose", str(w, "/repo")]), "", o) else { return; }
    mkdir_p(str(w, "/repo/.cache"));
    write_file(str(w, "/repo/.cache/junk.goose"), "fn hidden_fn() { }\n");
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    let db = str(w, "/map/swan.db");
    var t: u8[>..] = [];
    lg_db_query(db, "refs", "UNIT", "", t);
    check("goose: UNIT in main.goose is used in shapes.goose, inside area (resolved by the compiler, across files)",
          find(t, "\"kind\":\"variable\"") >= 0 && find(t, "\"relative_path\":\"shapes.goose\",\"line\":5") >= 0 &&
          find(t, "\"in_symbol\":\"area\"") >= 0, t);
    lg_db_query(db, "callers", "area", "", t);
    check("goose: area is called from main", find(t, "\"name_path\":\"main\"") >= 0 && find(t, "\"relative_path\":\"main.goose\"") >= 0, t);
    lg_db_query(db, "symbol", "hidden_fn", "", t);
    check("goose: a hidden folder is not walked", trim(t) == "[]", t);
    var r: u8[>..] = [];
    let rr = serve_once(db, "rename_symbol", """{"name_path":"UNIT","relative_path":"main.goose","new_name":"SCALE","apply":true}""", r);
    var a: u8[>..] = [];
    var b: u8[>..] = [];
    read_file(str(w, "/repo/main.goose"), a);
    read_file(str(w, "/repo/shapes.goose"), b);
    check("goose: renaming UNIT rewrites its definition and its use in the other file",
          rr == 1 && find(a, "let SCALE = 2;") >= 0 && find(b, "side * side * SCALE;") >= 0 && find(r, "\"files_written\":2") >= 0, r);
}

// A Go map through the SolidLSP bridge (tools/solidlsp/bridge.py) and gopls,
// sealed: references across packages, what implements an interface (Go
// says so nowhere in the source), no second by-name copy from the syntax
// index, and a rename across packages.
fn lang_go_map() {
    guard file_exists(".tools/solidlsp/venv/bin/python") && file_exists(".tools/gopls/gopls") else {
        write_stderr("skip: go map: SolidLSP and gopls are not fetched (SWAN_LANGS=go scripts/fetch-tools.sh)\n");
        return;
    }
    let w = "data/go-map";
    rm_rf(w);
    mkdir_p(w);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-go", str(w, "/repo")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    let db = str(w, "/map/swan.db");
    var t: u8[>..] = [];
    lg_db_query(db, "refs", "TotalArea", "", t);
    check("go: TotalArea in package shapes is used from main.go, inside main (resolved by gopls through the import)",
          find(t, "\"relative_path\":\"main.go\",\"line\":10") >= 0 && find(t, "\"in_symbol\":\"main\"") >= 0, t);
    var defs = 0;
    var at = 0;
    loop {
        let k = find(t[at..], "\"symbol\":{\"name_path\":\"TotalArea\"");
        guard k >= 0 else { break; }
        defs++;
        at += k + 10;
    }
    check("go: one TotalArea in the map, not a second by-name copy from the syntax index", defs == 1, t);
    lg_db_query(db, "impls", "Shape", "", t);
    check("go: Square implements Shape, which only the compiler knows", find(t, "\"implementations\":[{\"name_path\":\"Square\"") >= 0, t);
    var r: u8[>..] = [];
    let rr = serve_once(db, "rename_symbol", """{"name_path":"TotalArea","relative_path":"shapes/shapes.go","new_name":"SumArea","apply":true}""", r);
    var a: u8[>..] = [];
    var b: u8[>..] = [];
    read_file(str(w, "/repo/main.go"), a);
    read_file(str(w, "/repo/shapes/shapes.go"), b);
    check("go: renaming TotalArea rewrites its definition and the call in the other package",
          rr == 1 && find(a, "shapes.SumArea(") >= 0 && find(b, "func SumArea(") >= 0 && find(r, "\"files_written\":2") >= 0, r);
}

fn lang_java() {
    // scip-java with no build tool: Swan writes its scip-java.json outside the repo.
    let w = "data/java-check";
    rm_rf(w);
    mkdir_p(w);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-java", str(w, "/repo")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    // Reuse keys on the command too: the same files under a Swan home at
    // another path (so another scip-java path in its argv) must index again.
    var again: u8[>..] = [];
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", again) else { return; }
    check("java: a second map with nothing changed reuses scip-java's index", find(again, "scip-java: reused") >= 0, again);
    let home2 = str(w, "/home2");
    mkdir_p(str(home2, "/bin"));
    guard sh(argv(["cp", "bin/swan", str(home2, "/bin/swan")]), "", o) else { return; }
    guard sh(argv(["cp", "bin/eggshell", str(home2, "/bin/eggshell")]), "", o) else { return; }      // every run is sealed
    guard sh(argv(["cp", "bin/swan-flatten", str(home2, "/bin/swan-flatten")]), "", o) else { return; }  // the only flattener
    var cwd: u8[>..] = [];
    var e0: u8[>..] = [];
    run(argv(["realpath", "."]), "", cwd, e0);
    let here = trim(cwd);
    guard sh(argv(["ln", "-s", str(here, "/tools"), str(home2, "/tools")]), "", o) else { return; }
    guard sh(argv(["ln", "-s", str(here, "/.tools"), str(home2, "/.tools")]), "", o) else { return; }
    var moved: u8[>..] = [];
    var margs: u8[>..] = [];
    a1(margs, str(home2, "/bin/swan")); a1(margs, "map"); a1(margs, str(w, "/repo")); a1(margs, str(w, "/map"));
    guard sh(margs, "", moved) else { return; }
    check("java: the same files with another scip-java argv are indexed again, not reused",
          find(moved, "scip-java: reused") < 0 && find(moved, "nothing changed") < 0, moved);
    guard sh(argv(["bin/swan", "check", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    let db = str(w, "/map/swan.db");
    var t: u8[>..] = [];
    lg_db_query(db, "impls", "Shape", "", t);
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let r1, e1 = json::parse(t, d1, x1);
    check("java: Square and Circle implement Shape",
          sorted_join(jlist(json::member(r1, "implementations"), "name_path")) == "Circle,Square", t);
    lg_db_query(db, "hierarchy", "Shape/area", "", t);
    var d2: json::Node[>..] = []; var x2: u8[>..] = [];
    let r2, e2 = json::parse(t, d2, x2);
    check("java: the area() overrides, without scip-java's reverse links",
          sorted_join(jlist(json::member(r2, "subtypes"), "name_path")) == "Circle/area,Square/area", t);
    lg_db_query(db, "refs", "Square", "", t);
    var d3: json::Node[>..] = []; var x3: u8[>..] = [];
    let r3, e3 = json::parse(t, d3, x3);
    var via = false;
    let sq = json::member(nth(r3, 0), "references");
    if sq { json::each(sq) { r => if jstr(r, "in_symbol") == "Shapes/main" && jstr(r, "via") == "Square/<init>" { via = true; } }; }
    check("java: `new Square(2)` counts as a use of Square (through its constructor)", via, t);

    // Answers checked against JetBrains' own (IntelliJ IDEA asked through its
    // MCP server on this fixture, 2026-11-17): its call hierarchy for
    // Circle.area shows totalArea and main, its rename of Shape.area touches
    // four files, and it does not call Circle or Square unused.
    lg_db_query(db, "callers", "/Circle/area", "", t);
    check("java: Circle.area is called through the interface method it implements (totalArea, then main)",
          find(t, "\"through\":[\"Shape/area\"]") >= 0 && find(t, "\"name_path\":\"Shapes/totalArea\"") >= 0 &&
          find(t, "\"name_path\":\"Shapes/main\"") >= 0, t);
    lg_db_query(db, "unused", "src", "", t);
    check("java: a class that is only constructed is not unused",
          find(t, "\"name_path\":\"Circle\"") < 0 && find(t, "\"name_path\":\"Square\"") < 0 && find(t, "Shapes/main") >= 0, t);
    var pt: u8[>..] = [];
    let pr = serve_once(db, "rename_symbol", """{"name_path":"/Circle/area","relative_path":"src/main/java/shapes/Circle.java","new_name":"surface"}""", pt);
    check("java: renaming an override plans the interface method and the other override too (4 files)",
          pr == 1 && find(pt, "\"also_renamed\":[\"Shape/area\",\"Square/area\"]") >= 0 && find(pt, "\"files\":4") >= 0, pt);
    var at: u8[>..] = [];
    let ar = serve_once(db, "rename_symbol", """{"name_path":"/Shape/area","relative_path":"src/main/java/shapes/Shape.java","new_name":"surface","apply":true}""", at);
    check("java: the family rename applies to all four files", ar == 1 && find(at, "\"files_written\":4") >= 0, at);
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "check", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    lg_db_query(db, "diagfile", ".", "", t);
    check("java: after it, javac still finds no errors (the overrides still implement the interface)",
          find(t, "\"errors\":0") >= 0, t);
    // A file touched but not changed is not stale once a refresh has looked at it.
    guard sh(argv(["touch", str(w, "/repo/src/main/java/shapes/Circle.java")]), "", o) else { return; }
    var it0: u8[>..] = [];
    serve_once(db, "index_info", "{}", it0);
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    var it1: u8[>..] = [];
    serve_once(db, "index_info", "{}", it1);
    check("java: a touched, unchanged file is stale until a refresh, and not after",
          find(it0, "\"stale_file_count\":1") >= 0 && find(it1, "\"stale_file_count\":0") >= 0, str(it0, "\n     ", it1));
    lg_db_query(db, "diagfile", ".", "", t);
    var d4: json::Node[>..] = []; var x4: u8[>..] = [];
    let r4, e4 = json::parse(t, d4, x4);
    check("java: javac finds no errors in the clean fixture", jint(json::member(r4, "map_total"), "errors") == 0, t);

    var et: u8[>..] = [];
    let er = serve_once(db, "replace_symbol_body", """{"name_path":"Square/<init>","relative_path":"src/main/java/shapes/Square.java","body":"public Square(double side, String unit) {\n        this.side = side;\n    }"}""", et);
    check("java: replace_symbol_body on a constructor", er == 1, et);
    guard sh(argv(["bin/swan", "check", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    lg_db_query(db, "diag", "Square", "src/main/java/shapes/Square.java", t);
    var d5: json::Node[>..] = []; var x5: u8[>..] = [];
    let r5, e5 = json::parse(t, d5, x5);
    var landed = false;
    let dl = json::member(r5, "diagnostics");
    if dl { json::each(dl) { d => if jstr(d, "severity") == "error" && jstr(d, "in_symbol") == "Shapes/main" && jint(d, "column") > 1 && jint(d, "distance") == 1 { landed = true; } }; }
    check("java: javac's error lands in the caller, Shapes.main, with its column", landed, t);

    var rt: u8[>..] = [];
    let rr = serve_once(db, "rename_symbol", """{"name_path":"Shapes/totalArea","relative_path":"src/main/java/shapes/Shapes.java","new_name":"sumOfAreas","apply":true}""", rt);
    var renamed: u8[>..] = [];
    read_file(str(w, "/repo/src/main/java/shapes/Shapes.java"), renamed);
    check("java: rename_symbol rewrites the method and its call",
          rr == 1 && find(renamed, "static double sumOfAreas(") >= 0 && find(renamed, "println(sumOfAreas(") >= 0, rt);
}

// `swan gradle-tasks <dir>`'s task list, space-joined.
fn lg_tasks(dir: const u8[:]) -> u8[>..] {
    var o: u8[>..] = [];
    var e: u8[>..] = [];
    run(argv(["bin/swan", "gradle-tasks", dir]), "", o, e);
    var out: u8[>..] = [];
    each_split(trim(o), '\n') { l => if out.len > 0 { out.push(' '); } out.append(l); };
    return out;
}
let LG_PLAIN = "clean scipPrintDependencies scipCompileAll";
let LG_ANDROID = "clean compileDebugKotlin compileDebugUnitTestKotlin scipCompileAll";
fn lg_eq(what: const u8[:], dir: const u8[:], want: const u8[:]) {
    let got = lg_tasks(dir);
    check(what, got == want, got);
}

fn lang_gradle() {
    // The Gradle tasks map gives scip-java, from the build files alone (no
    // Gradle, no Android SDK): when any module is Android, the unqualified
    // Kotlin compiles replace scipPrintDependencies, which AGP 9 breaks.
    let g = "fixtures/gradle-android";
    lg_eq("gradle: plain Kotlin JVM (tiny-kt) keeps scipPrintDependencies", "fixtures/tiny-kt", LG_PLAIN);
    lg_eq("gradle: no Gradle at all (tiny-java) gets the same list", "fixtures/tiny-java", LG_PLAIN);
    lg_eq("gradle: plugins { id(\"com.android.application\") } with include(\":app\")", str(g, "/kts-app"), LG_ANDROID);
    lg_eq("gradle: Groovy apply plugin, a multi-line include, :core:data, and a JVM :lib", str(g, "/groovy-multi"), LG_ANDROID);
    lg_eq("gradle: version-catalog aliases; the root's `apply false`; a com.android.test module beside others", str(g, "/catalog"), LG_ANDROID);
    lg_eq("gradle: an Android app in the root project", str(g, "/root-module"), LG_ANDROID);
    lg_eq("gradle: a JVM module with an Android plugin id inside /* ... */ stays plain", str(g, "/jvm-comment"), LG_PLAIN);
    lg_eq("gradle: a root with only plugins.withId(\"com.android.application\") stays plain", str(g, "/root-withid"), LG_PLAIN);
    lg_eq("gradle: id(\"com.android.application\") with .apply(false) on the next line stays plain", str(g, "/multiline-apply-false"), LG_PLAIN);
    lg_eq("gradle: include names with \"..\" or \"/\" are not followed out of the repo", str(g, "/bad-include/repo"), LG_PLAIN);
    lg_eq("gradle: only com.android.test modules get no compileDebugUnitTestKotlin", str(g, "/test-only"), "clean compileDebugKotlin scipCompileAll");

    var tmpo: u8[>..] = [];
    var e0: u8[>..] = [];
    run(argv(["mktemp", "-d", "-t", "swan-gradle-detection-XXXXXX"]), "", tmpo, e0);
    var tmp: u8[>..] = [];
    tmp.append(trim(tmpo));
    let jvm = "plugins { kotlin(\"jvm\") }\n";
    let andr = "plugins { id(\"com.android.application\") }\n";
    for name in ["jvm", "old", "blocked", "inside", "actual"] {
        mkdir_p(str(tmp, "/", name));
        write_file(str(tmp, "/", name, "/build.gradle.kts"), if name == "jvm" || name == "actual" { jvm } else { andr });
    }
    let actual = str(tmp, "/actual/build.gradle.kts");
    lg_settings(tmp, actual, "settings.gradle.kts", "\"\"\"", jvm, andr);
    lg_settings(tmp, actual, "settings.gradle", "'''", jvm, andr);
    lg_reaction(tmp, "withId");
    lg_reaction(tmp, "hasPlugin");
    lg_reaction(tmp, "withPlugin");
    delete_file(str(tmp, "/build.gradle.kts"));
    let bg = str(tmp, "/build.gradle");
    write_file(bg, "def text = $/\n/* not a comment\n/$\nplugins { id \"com.android.application\" }\n");
    lg_eq("gradle: a Groovy plugin after a dollar-slashy string is detected", tmp, LG_ANDROID);
    write_file(bg, "def text = /\n\\/* not a comment\n/\nplugins { id \"com.android.application\" }\n");
    lg_eq("gradle: a Groovy plugin after a slashy string is detected", tmp, LG_ANDROID);
    rm_rf(tmp);
}

fn lg_settings(tmp: const u8[:], actual: const u8[:], settings: const u8[:], quote: const u8[:], jvm: const u8[:], andr: const u8[:]) {
    let path = str(tmp, "/", settings);
    write_file(path, str("include(\":jvm\") // was \":old\"\n/*\ninclude(\":blocked\")\n*/\n",
                         "defText = ", quote, "\n// not a comment\n/* not a comment\ninclude(\":inside\")\n", quote, "\n",
                         "include(\":actual\")\n"));
    lg_eq(str("gradle: ", settings, " ignores comments and includes inside multiline strings"), tmp, LG_PLAIN);
    write_file(actual, andr);
    lg_eq(str("gradle: ", settings, " still sees a real include after a multiline string"), tmp, LG_ANDROID);
    write_file(actual, jvm);
    if ends_with(settings, ".kts") {
        write_file(path, "/* outer /* nested */\ninclude(\":blocked\")\n*/\nval text = \"\"\"raw backslash \\\"\"\"\ninclude(\":actual\")\n");
        lg_eq("gradle: Kotlin nested comments and raw strings keep later includes visible", tmp, LG_PLAIN);
        write_file(actual, andr);
        lg_eq("gradle: Kotlin raw string ending in backslash preserves a real include", tmp, LG_ANDROID);
        write_file(actual, jvm);
    } else {
        write_file(path, "def text = $/\n/* not a comment\n// not a comment\n$$ and $/ are escaped\ninclude(\":inside\")\n/$\ninclude(\":actual\")\n");
        lg_eq("gradle: dollar-slashy string does not create a fake include", tmp, LG_PLAIN);
        write_file(actual, andr);
        lg_eq("gradle: comment-like text in a dollar-slashy string does not hide a real include", tmp, LG_ANDROID);
        write_file(actual, jvm);
        write_file(path, "def text = /\nescaped \\/* and \\/\\/\ninclude(\":inside\")\n/\ndef quotient = 4 / 2\ninclude(\":actual\")\n");
        lg_eq("gradle: slashy string does not create a fake include", tmp, LG_PLAIN);
        write_file(actual, andr);
        lg_eq("gradle: slashy string and division preserve a real include", tmp, LG_ANDROID);
        write_file(path, "def text() { return /\n\\/* still text\ninclude(\":inside\")\n/ }\ninclude(\":actual\")\n");
        lg_eq("gradle: slashy string after return preserves a real include", tmp, LG_ANDROID);
        write_file(path, "def text = \"prefix\" + /\n\\/* still text\ninclude(\":inside\")\n/\ncounter++ / 2\ninclude(\":actual\")\n");
        lg_eq("gradle: slashy string after an operator and postfix division preserve a real include", tmp, LG_ANDROID);
        write_file(actual, jvm);
    }
    delete_file(path);
}

fn lg_reaction(tmp: const u8[:], method: const u8[:]) {
    let bk = str(tmp, "/build.gradle.kts");
    write_file(bk, str("plugins.", method, "(\n  \"com.android.application\"\n) { }\n"));
    lg_eq(str("gradle: multiline ", method, " reaction does not apply Android"), tmp, LG_PLAIN);
    write_file(bk, str("plugins.", method, "(\n  \"com.android.application\"\n) { apply(plugin = \"com.android.library\") }\n"));
    lg_eq(str("gradle: a real plugin application after ", method, " is detected"), tmp, LG_ANDROID);
}

fn lang_cuda() {
    // scip-clang in clang's CUDA mode, with NVIDIA's headers from pip wheels
    // and clang's builtin CUDA headers; no nvcc, no GPU.
    let w = "data/cuda-check";
    rm_rf(w);
    mkdir_p(w);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-cuda", str(w, "/repo")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "check", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    let db = str(w, "/map/swan.db");
    var t: u8[>..] = [];
    lg_db_query(db, "callers", "scale", "", t);
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let r1, e1 = json::parse(t, d1, x1);
    var chain: u8[>..] = [];
    let cs = json::member(r1, "callers");
    if cs { json::each(cs) { c => if chain.len > 0 { chain.push(','); } format(chain, jstr(c, "name_path"), "@", jint(c, "distance")); }; }
    check("cuda: callers of the device function scale(): scaled_kernel, then launch_scaled (a <<<>>> launch), then main",
          chain == "scaled_kernel@1,launch_scaled@2,main@3", chain);
    lg_db_query(db, "refs", "add_kernel", "", t);
    var d2: json::Node[>..] = []; var x2: u8[>..] = [];
    let r2, e2 = json::parse(t, d2, x2);
    check("cuda: the kernel launch add_kernel<<<...>>> is a reference from launch_add",
          jany(json::member(nth(r2, 0), "references"), "in_symbol", "launch_add"), t);
    lg_db_query(db, "diagfile", ".", "", t);
    var d3: json::Node[>..] = []; var x3: u8[>..] = [];
    let r3, e3 = json::parse(t, d3, x3);
    check("cuda: clang finds no errors in the clean fixture", jint(json::member(r3, "map_total"), "errors") == 0, t);
    var et: u8[>..] = [];
    let er = serve_once(db, "replace_symbol_body", """{"name_path":"scale","relative_path":"vec.cuh","body":"__device__ inline float scale(float x, float k, float bias) { return x * k + bias; }"}""", et);
    check("cuda: replace_symbol_body on a __device__ function in a .cuh header", er == 1, et);
    guard sh(argv(["bin/swan", "check", str(w, "/repo"), str(w, "/map")]), "", o) else { return; }
    lg_db_query(db, "diag", "scale", "vec.cuh", t);
    var d4: json::Node[>..] = []; var x4: u8[>..] = [];
    let r4, e4 = json::parse(t, d4, x4);
    var landed = false;
    let dl = json::member(r4, "diagnostics");
    if dl { json::each(dl) { d => if jstr(d, "severity") == "error" && jstr(d, "in_symbol") == "scaled_kernel" && jint(d, "distance") == 1 { landed = true; } }; }
    check("cuda: clang's error for the old call lands in scaled_kernel", landed, t);
}

fn lang_modules() {
    // The per-language tools from tools/modules.json: linters into the map,
    // formatters, and the tests that reach a symbol.
    let w = "data/modules-check";
    rm_rf(w);
    mkdir_p(w);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-py", str(w, "/py")]), "", o) else { return; }
    write_file(str(w, "/py/messy.py"), "import os\nx=1\ndef f( a,b ):\n  return a+b\n");
    guard sh(argv(["bin/swan", "map", str(w, "/py"), str(w, "/pymap")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "check", str(w, "/py"), str(w, "/pymap")]), "", o) else { return; }
    var t: u8[>..] = [];
    lg_db_query(str(w, "/pymap/swan.db"), "diagfile", "messy.py", "", t);
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let r1, e1 = json::parse(t, d1, x1);
    var ruff = false;
    let dl = json::member(r1, "diagnostics");
    if dl { json::each(dl) { d => if jstr(d, "source") == "ruff" && find(jstr(d, "message"), "F401") >= 0 { ruff = true; } }; }
    check("modules: ruff's finding (unused import) lands in the map", ruff, t);
    check("modules: the linter left nothing in the repo (no .ruff_cache)", !file_exists(str(w, "/py/.ruff_cache/CACHEDIR.TAG")), "");
    guard sh(argv(["bin/swan", "format", str(w, "/py"), str(w, "/pymap"), "messy.py"]), "", o) else { return; }
    var messy: u8[>..] = [];
    read_file(str(w, "/py/messy.py"), messy);
    check("modules: format_file through ruff format", find(messy, "def f(a, b):\n    return a + b") >= 0, messy);
    var tout: u8[>..] = [];
    var terr: u8[>..] = [];
    let tc = run(argv(["bin/swan", "test", str(w, "/py"), str(w, "/pymap"), "Square/area", "shapes/__init__.py"]), "", tout, terr);
    check("modules: run_tests finds test_shapes.py through an override (Square.area via Shape.area) and pytest passes",
          tc == 0 && find(tout, "test_shapes.py") >= 0 && find(tout, "1 passed") >= 0, tout);

    guard sh(argv(["cp", "-r", "fixtures/tiny-rs", str(w, "/rs")]), "", o) else { return; }
    guard sh(argv(["bin/swan", "map", str(w, "/rs"), str(w, "/rsmap")]), "", o) else { return; }
    var rout: u8[>..] = [];
    var rerr: u8[>..] = [];
    let rc = run(argv(["bin/swan", "test", str(w, "/rs"), str(w, "/rsmap"), "src/lib.rs"]), "", rout, rerr);
    check("modules: run_tests on a Rust file runs cargo test, which passes", rc == 0 && find(rout, "rust tests: passed") >= 0, rout);
}
