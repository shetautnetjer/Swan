// Breaks a fixture copy on purpose and checks that get_diagnostics finds the
// damage where an engineer would look: in the callers of what changed.
// (Was tests/diag_check.ts.)

import std;
import os;
import json;
import .harness;

fn diag_suite() {
    let work = "data/diag-check";
    rm_rf(work);
    mkdir_p(work);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-ts", str(work, "/repo")]), "", o) else { return; }
    let db = str(work, "/map/swan.db");
    guard sh(argv(["scripts/index-repo.sh", str(work, "/repo"), str(work, "/map")]), "", o) else { return; }
    guard sh(argv(["scripts/diagnose-repo.sh", str(work, "/repo"), str(work, "/map")]), "", o) else { return; }

    var t = swan_query(db, "diagfile", "src", "");
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let clean, e1 = json::parse(t, d1, x1);
    check("the untouched fixture has no errors", jint(json::member(clean, "map_total"), "errors") == 0, t);

    // The change: Store.total now needs an argument, so its callers break.
    var line: u8[>..] = [];
    var edited = false;
    if mcp_open(argv(["bin/swan", "serve", db]), "") {
        if mcp_rpc("tools/call", """{"name":"replace_symbol_body","arguments":{"name_path":"Store/total","relative_path":"src/store.ts","body":"total(cap: number): number {\n    let sum = 0;\n    for (const item of this.items.values()) sum += item.weight;\n    return Math.min(sum, cap);\n  }"}}""", line) {
            var d2: json::Node[>..] = []; var x2: u8[>..] = [];
            let r2, e2 = json::parse(line, d2, x2);
            edited = !jtrue(json::member(r2, "result"), "isError");
        }
        mcp_close();
    }
    check("the edit went in", edited, line);

    t = swan_query(db, "diag", "Store/total", "src/store.ts");
    var d3: json::Node[>..] = []; var x3: u8[>..] = [];
    let before, e3 = json::parse(t, d3, x3);
    var ok_before = true;
    let bd = json::member(before, "diagnostics");
    if bd { json::each(bd) { d => if jstr(d, "relative_path") == "src/store.ts" && !jtrue(d, "stale") { ok_before = false; } }; }
    check("before rechecking, get_diagnostics shows nothing new and marks store.ts entries stale if any", ok_before, t);

    guard sh(argv(["scripts/diagnose-repo.sh", str(work, "/repo"), str(work, "/map")]), "", o) else { return; }
    t = swan_query(db, "diag", "Store/total", "src/store.ts");
    var d4: json::Node[>..] = []; var x4: u8[>..] = [];
    let after, e4 = json::parse(t, d4, x4);
    let ad = json::member(after, "diagnostics");
    var where: u8[>..] = [];
    var seen_report = false; var seen_capped = false; var seen_main = false; var summary_listed = false;
    if ad {
        json::each(ad) { d =>
            let s = jstr(d, "in_symbol");
            format(where, s, "@", jint(d, "distance"), " ");
            let hit = jint(d, "distance") == 1 && jstr(d, "code") == "TS2554";
            if hit && s == "report" { seen_report = true; }
            if hit && s == "CappedStore/total" { seen_capped = true; }
            if hit && s == "main.ts" { seen_main = true; }
            if s == "summary" { summary_listed = true; }
        };
    }
    check("after the check, the errors show up in the callers, at distance 1: report, CappedStore.total (super.total()) and main.ts's top level",
          seen_report && seen_capped && seen_main, where);
    check("summary, two steps out, has no errors of its own, so it is not listed", !summary_listed, where);

    t = swan_query(db, "diagfile", "src", "");
    var d5: json::Node[>..] = []; var x5: u8[>..] = [];
    let all, e5 = json::parse(t, d5, x5);
    var described = true;
    let alld = json::member(all, "diagnostics");
    if alld { json::each(alld) { d => if jstr(d, "severity").len == 0 || jstr(d, "message").len == 0 { described = false; } }; }
    check("the whole-map view lists every error, with the symbol it is in",
          jint(json::member(all, "map_total"), "errors") >= 2 && described, t);

    // Rust, through cargo check: Tile::new gains a parameter, so the test
    // that calls it breaks.
    let rs = str(work, "/rs");
    mkdir_p(rs);
    guard sh(argv(["cp", "-r", "fixtures/tiny-rs", str(rs, "/repo")]), "", o) else { return; }
    guard sh(argv(["scripts/index-repo.sh", str(rs, "/repo"), str(rs, "/map")]), "", o) else { return; }
    replace_in_file(str(rs, "/repo/src/lib.rs"), "pub fn new(side: u32) -> Tile", "pub fn new(side: u32, _scale: u32) -> Tile");
    guard sh(argv(["scripts/diagnose-repo.sh", str(rs, "/repo"), str(rs, "/map")]), "", o) else { return; }
    t = swan_query(str(rs, "/map/swan.db"), "diag", "Tile/new", "src/lib.rs");
    var d6: json::Node[>..] = []; var x6: u8[>..] = [];
    let rsd, e6 = json::parse(t, d6, x6);
    var in_tiles = false;
    let rdl = json::member(rsd, "diagnostics");
    if rdl { json::each(rdl) { d => if jstr(d, "severity") == "error" && jstr(d, "in_symbol") == "tiles" && jint(d, "distance") == 1 && !jtrue(d, "stale") { in_tiles = true; } }; }
    check("cargo check's error lands in the caller of Tile::new (the test fn tiles, found through the vec! macro), marked stale-free after the check",
          in_tiles, t);

    // A checker that fails without checking (cargo exits 101 when a
    // dependency will not resolve) leaves the saved errors as they were.
    let toml = str(rs, "/repo/Cargo.toml");
    var toml_text: u8[>..] = [];
    read_file(toml, toml_text);
    var broken_toml: u8[>..] = [];
    broken_toml.append(toml_text);
    if find(toml_text, "[dependencies]") < 0 { broken_toml.append("\n[dependencies]\n"); }
    broken_toml.append("missing-dep = { path = \"../does-not-exist\" }\n");
    write_file(toml, broken_toml);
    var bout: u8[>..] = [];
    var berr: u8[>..] = [];
    run(argv(["bin/swan", "check", str(rs, "/repo"), str(rs, "/map")]), "", bout, berr);
    write_file(toml, toml_text);
    t = swan_query(str(rs, "/map/swan.db"), "diag", "Tile/new", "src/lib.rs");
    var d7: json::Node[>..] = []; var x7: u8[>..] = [];
    let kept, e7 = json::parse(t, d7, x7);
    var still = false;
    let kd = json::member(kept, "diagnostics");
    if kd { json::each(kd) { d => if jstr(d, "severity") == "error" && jstr(d, "in_symbol") == "tiles" { still = true; } }; }
    check("a cargo that fails without checking keeps the saved errors and says so",
          find(bout, "could not check") >= 0 && still, str(bout, berr[max(0, berr.len - 300)..]));
}
