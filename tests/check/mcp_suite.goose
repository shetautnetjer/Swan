// End-to-end check of `swan serve` as an MCP client would drive it: spawn the
// server, initialize, list tools, call each tool, and assert on the answers
// for the tiny-ts fixture (mapped by scripts/test.sh into data/tiny-ts).
// (Was tests/mcp_smoke.ts.)

import std;
import os;
import json;
import sqlite;
import .harness;

fn mcp_suite() {
    let db = "data/tiny-ts/swan.db";
    guard mcp_open(argv(["bin/swan", "serve", db]), "") else { return; }

    var t: u8[>..] = [];
    guard mcp_rpc("initialize", """{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"swan-smoke","version":"0"}}""", t) else { mcp_close(); return; }
    var d0: json::Node[>..] = []; var x0: u8[>..] = [];
    let init, e0 = json::parse(t, d0, x0);
    check("initialize names the server", jstr(json::member(json::member(init, "result"), "serverInfo"), "name") == "swan", t);
    mcp_notify("notifications/initialized");

    var tl: u8[>..] = [];
    guard mcp_rpc("tools/list", "", tl) else { mcp_close(); return; }
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let tr, e1 = json::parse(tl, d1, x1);
    let tools = jlist(json::member(json::member(tr, "result"), "tools"), "name");
    var shown: u8[>..] = [];
    each_split(tools, '\n') { n => if n.len > 0 { if shown.len > 0 { shown.append(", "); } shown.append(n); } };
    var all7 = true;
    for n in ["find_symbol", "find_referencing_symbols", "get_callers", "get_callees", "find_implementations",
              "get_type_hierarchy", "find_unused_symbols"] { if !has_line(tools, n) { all7 = false; } }
    check(str("tools/list: ", shown), all7, tools);

    guard mcp_tool("find_symbol", """{"name_path_pattern":"Store/add","include_body":true}""", t) else { mcp_close(); return; }
    var d2: json::Node[>..] = []; var x2: u8[>..] = [];
    let add, e2 = json::parse(t, d2, x2);
    let a0 = nth(add, 0);
    check("find_symbol Store/add: one method at src/store.ts:11",
          jcount(add) == 1 && jstr(a0, "kind") == "method" && jstr(a0, "relative_path") == "src/store.ts" &&
          jint(a0, "line") == 11 && find(jstr(a0, "body"), "this.items.set") >= 0, t);

    guard mcp_tool("find_symbol", """{"name_path_pattern":"total"}""", t) else { mcp_close(); return; }
    var d3: json::Node[>..] = []; var x3: u8[>..] = [];
    let totals, e3 = json::parse(t, d3, x3);
    check("find_symbol total: the function, the method and the override stay apart",
          sorted_join(jlist(totals, "name_path")) == "CappedStore/total,Store/total,total", t);

    guard mcp_tool("find_referencing_symbols", """{"name_path":"format"}""", t) else { mcp_close(); return; }
    var d4: json::Node[>..] = []; var x4: u8[>..] = [];
    let fmt, e4 = json::parse(t, d4, x4);
    var fmt_refs: u8[>..] = [];
    let fr = json::member(nth(fmt, 0), "references");
    if fr { json::each(fr) { r => format(fmt_refs, jstr(r, "relative_path"), ":", jint(r, "line"), "\n"); }; }
    check("refs to format() follow the re-export to formatItem in main.ts",
          has_line(fmt_refs, "src/main.ts:8") && has_line(fmt_refs, "src/index.ts:2"), fmt_refs);

    guard mcp_tool("find_referencing_symbols", """{"name_path":"DEFAULT_WEIGHT"}""", t) else { mcp_close(); return; }
    var d5: json::Node[>..] = []; var x5: u8[>..] = [];
    let dw, e5 = json::parse(t, d5, x5);
    check("a reference inside a method names that method (DEFAULT_WEIGHT in Store/add)",
          jany(json::member(nth(dw, 0), "references"), "in_symbol", "Store/add"), t);

    guard mcp_tool("get_symbols_overview", """{"relative_path":"src/store.ts"}""", t) else { mcp_close(); return; }
    var d6: json::Node[>..] = []; var x6: u8[>..] = [];
    let ov, e6 = json::parse(t, d6, x6);
    check("overview of src/store.ts lists Store and makeStore",
          jany(ov, "name_path", "Store") && jany(ov, "name_path", "makeStore"), t);

    guard mcp_tool("get_callers", """{"name_path":"Store/total","depth":3}""", t) else { mcp_close(); return; }
    var d7: json::Node[>..] = []; var x7: u8[>..] = [];
    let impact, e7 = json::parse(t, d7, x7);
    let ic = json::member(impact, "callers");
    check("get_callers walks the chain: report at 1, summary at 2, testSummary at 3",
          jint(jfind(ic, "name_path", "report"), "distance") == 1 && jint(jfind(ic, "name_path", "summary"), "distance") == 2 &&
          jint(jfind(ic, "name_path", "testSummary"), "distance") == 3, t);
    check("get_callers lists the test file to run",
          find(str(",", jstrings(json::member(json::member(impact, "summary"), "test_files")), ","), ",src/store.test.ts,") >= 0 &&
          jtrue(jfind(ic, "name_path", "testSummary"), "is_test"), t);

    guard mcp_tool("get_callers", """{"name_path":"Store/total"}""", t) else { mcp_close(); return; }
    var d8: json::Node[>..] = []; var x8: u8[>..] = [];
    let near, e8 = json::parse(t, d8, x8);
    var direct = true;
    let nc = json::member(near, "callers");
    if nc { json::each(nc) { c => if jint(c, "distance") != 1 { direct = false; } }; }
    check("get_callers defaults to direct callers only", direct, t);

    guard mcp_tool("get_callees", """{"name_path":"Store/add"}""", t) else { mcp_close(); return; }
    var d9: json::Node[>..] = []; var x9: u8[>..] = [];
    let callees, e9 = json::parse(t, d9, x9);
    let cl = json::member(callees, "callees");
    var map_set = false;
    if cl { json::each(cl) { c => if jstr(c, "name_path") == "Map/set" && starts_with(jstr(c, "package"), "typescript ") { map_set = true; } }; }
    check("get_callees of Store/add: DEFAULT_WEIGHT, and Map/set from the typescript package",
          jany(cl, "name_path", "DEFAULT_WEIGHT") && map_set, t);

    guard mcp_tool("get_callees", """{"name_path":"Store/add","calls_only":true}""", t) else { mcp_close(); return; }
    var d10: json::Node[>..] = []; var x10: u8[>..] = [];
    let co, e10 = json::parse(t, d10, x10);
    let col = json::member(co, "callees");
    var kinds_ok = true;
    if col {
        json::each(col) { c =>
            let k = jstr(c, "kind");
            if !(k == "function" || k == "method" || k == "constructor" || k == "macro" || k == "class" || k == "struct") { kinds_ok = false; }
        };
    }
    check("get_callees calls_only keeps calls (Map/set) and drops constants (DEFAULT_WEIGHT)",
          jany(col, "name_path", "Map/set") && !jany(col, "name_path", "DEFAULT_WEIGHT") && kinds_ok, t);

    guard mcp_tool("find_implementations", """{"name_path":"Weighed"}""", t) else { mcp_close(); return; }
    var d11: json::Node[>..] = []; var x11: u8[>..] = [];
    let impls, e11 = json::parse(t, d11, x11);
    check("find_implementations Weighed: Box and Crate",
          sorted_join(jlist(json::member(impls, "implementations"), "name_path")) == "Box,Crate", t);

    guard mcp_tool("find_implementations", """{"name_path":"Weighed/weigh"}""", t) else { mcp_close(); return; }
    var d12: json::Node[>..] = []; var x12: u8[>..] = [];
    let ovr, e12 = json::parse(t, d12, x12);
    check("find_implementations of an interface method finds both implementations",
          sorted_join(jlist(json::member(ovr, "implementations"), "name_path")) == "Box/weigh,Crate/weigh", t);

    guard mcp_tool("get_type_hierarchy", """{"name_path":"CappedStore/total"}""", t) else { mcp_close(); return; }
    var d13: json::Node[>..] = []; var x13: u8[>..] = [];
    let th, e13 = json::parse(t, d13, x13);
    let sup = json::member(th, "supertypes");
    check("get_type_hierarchy: CappedStore/total overrides Store/total",
          jcount(sup) == 1 && jstr(nth(sup, 0), "name_path") == "Store/total" && jcount(json::member(th, "subtypes")) == 0, t);

    guard mcp_tool("find_unused_symbols", "{}", t) else { mcp_close(); return; }
    var d14: json::Node[>..] = []; var x14: u8[>..] = [];
    let unused, e14 = json::parse(t, d14, x14);
    check("find_unused_symbols: Box, Crate and CappedStore (nothing uses them), not testSummary (test file)",
          sorted_join(jlist(json::member(unused, "unused"), "name_path")) == "Box,CappedStore,Crate", t);

    // Freshness: push report.ts's mtime into the future, as an edit after the
    // SCIP run would, then put it back (a reference file keeps the old times).
    let report_ts = "fixtures/tiny-ts/src/report.ts";
    var tmpdir: u8[>..] = [];
    var err: u8[>..] = [];
    run(argv(["mktemp", "-d", "-t", "swan-check-XXXXXX"]), "", tmpdir, err);
    let keep = str(trim(tmpdir), "/report-times");
    var o: u8[>..] = [];
    run(argv(["touch", "-r", report_ts, keep]), "", o, err);
    var fresh_t: u8[>..] = [];
    guard mcp_tool("index_info", "{}", fresh_t) else { mcp_close(); return; }
    run(argv(["touch", "-d", str("@", (time() as i64) + 60), report_ts]), "", o, err);
    var stale_t: u8[>..] = [];
    var stale_info_t: u8[>..] = [];
    let ok_stale = mcp_tool("find_referencing_symbols", """{"name_path":"Store/total"}""", stale_t) &&
                   mcp_tool("index_info", "{}", stale_info_t);
    run(argv(["touch", "-r", keep, report_ts]), "", o, err);
    rm_rf(trim(tmpdir));
    guard ok_stale else { mcp_close(); return; }
    var d15: json::Node[>..] = []; var x15: u8[>..] = [];
    let fresh, e15 = json::parse(fresh_t, d15, x15);
    var d16: json::Node[>..] = []; var x16: u8[>..] = [];
    let stale, e16 = json::parse(stale_t, d16, x16);
    var d17: json::Node[>..] = []; var x17: u8[>..] = [];
    let stale_info, e17 = json::parse(stale_info_t, d17, x17);
    var marks_ok = true;
    let sr = json::member(nth(stale, 0), "references");
    if sr { json::each(sr) { r => if jtrue(r, "stale") != (jstr(r, "relative_path") == "src/report.ts") { marks_ok = false; } }; }
    check("an edited file's answers say stale, others don't",
          jint(fresh, "stale_file_count") == 0 && marks_ok && jstrings(json::member(stale_info, "stale_files")) == "src/report.ts",
          str(stale_t, "\n     ", stale_info_t));

    // A file added after the build: the map has no answers for it, so
    // index_info lists it as stale and counts it as new. Left out: a new file
    // in a language the map holds no files of (Lua), one in a folder `swan
    // map` skips (node_modules), one behind a symlinked folder that leads out
    // of the repo, anything reached again through a link back to ".", and a
    // new .json whose ending is in the map only through the empty row an edit
    // leaves (mark_edited, rows = 0). Everything is removed again; it all
    // lives under uniquely named folders, so a developer's own files are
    // never touched.
    let tag = str("swan-new-files-", time_ns());
    let src_dir = str("fixtures/tiny-ts/src/", tag);
    let nm_root = "fixtures/tiny-ts/node_modules";
    let nm_had = is_dir(nm_root);
    let nm_dir = str(nm_root, "/", tag);
    var outside: u8[>..] = [];
    run(argv(["mktemp", "-d", "-t", "swan-outside-XXXXXX"]), "", outside, err);
    let out_dir = trim(outside);
    mkdir_p(src_dir);
    mkdir_p(nm_dir);
    write_file(str(src_dir, "/added.ts"), "export const added = 1;\n");
    write_file(str(src_dir, "/added.lua"), "x = 1\n");
    write_file(str(src_dir, "/added.json"), "{}\n");
    write_file(str(nm_dir, "/index.ts"), "export const dep = 1;\n");
    write_file(str(out_dir, "/secret.ts"), "export const secret = 1;\n");
    run(argv(["ln", "-s", out_dir, str(src_dir, "/escape")]), "", o, err);
    run(argv(["ln", "-s", ".", str(src_dir, "/loop")]), "", o, err);
    var json_row_had = false;
    var serr: u8[>..] = [];
    let mdb = sqlite::open_existing(db, serr);
    if mdb != 0 {
        let q = sqlite::prepare_or_die(mdb, "SELECT 1 FROM files WHERE file = 'tsconfig.json'");
        json_row_had = sqlite::step(q, serr) == 1;
        sqlite::finalize(q);
        if !json_row_had { sqlite::exec_or_die(mdb, "INSERT INTO files (file, hash, rows, edited_mtime) VALUES ('tsconfig.json', '', 0, 0)"); }
        sqlite::close(mdb);
    }
    var added_t: u8[>..] = [];
    let ok_added = mcp_tool("index_info", "{}", added_t);
    rm_rf(src_dir);
    rm_rf(if nm_had { nm_dir } else { nm_root });
    rm_rf(out_dir);
    if !json_row_had {
        let mdb2 = sqlite::open_existing(db, serr);
        if mdb2 != 0 { sqlite::exec_or_die(mdb2, "DELETE FROM files WHERE file = 'tsconfig.json'"); sqlite::close(mdb2); }
    }
    guard ok_added else { mcp_close(); return; }
    var after_t: u8[>..] = [];
    guard mcp_tool("index_info", "{}", after_t) else { mcp_close(); return; }
    var d18: json::Node[>..] = []; var x18: u8[>..] = [];
    let added_info, e18 = json::parse(added_t, d18, x18);
    var d19: json::Node[>..] = []; var x19: u8[>..] = [];
    let after_info, e19 = json::parse(after_t, d19, x19);
    let stale_files = jstrings(json::member(added_info, "stale_files"));
    check("a file added after the build is stale and new; other languages, skipped folders, symlinked folders and edit-only endings are not; gone again after removal",
          jint(fresh, "new_file_count") == 0 &&
          stale_files == str("src/", tag, "/added.ts") && jint(added_info, "stale_file_count") == 1 && jint(added_info, "new_file_count") == 1 &&
          jint(after_info, "stale_file_count") == 0 && jint(after_info, "new_file_count") == 0,
          str(added_t, "\n     ", after_t));

    guard mcp_tool("get_callers", """{"name_path":"total"}""", t) else { mcp_close(); return; }
    var d20: json::Node[>..] = []; var x20: u8[>..] = [];
    let amb, e20 = json::parse(t, d20, x20);
    check("get_callers with a name three symbols share sends the question back instead of merging",
          jtrue(amb, "ambiguous") && jcount(json::member(amb, "targets")) == 3 && !jhas(amb, "callers"), t);

    guard mcp_tool("get_callers", """{"name_path":"total","relative_path":"src/format.ts"}""", t) else { mcp_close(); return; }
    var d21: json::Node[>..] = []; var x21: u8[>..] = [];
    let one, e21 = json::parse(t, d21, x21);
    check("with relative_path it answers for that one",
          !jtrue(one, "ambiguous") && jany(json::member(one, "callers"), "relative_path", "src/main.ts"), t);

    guard mcp_tool("get_callers", """{"name_path":"/makeStore"}""", t) else { mcp_close(); return; }
    var d22: json::Node[>..] = []; var x22: u8[>..] = [];
    let ms, e22 = json::parse(t, d22, x22);
    let msc = json::member(ms, "callers");
    check("get_callers leaves import lines out: makeStore's callers are main.ts's and hooks.test.ts's top level, and testSummary",
          sorted_join(jlist(msc, "name_path")) == "hooks.test.ts,main.ts,testSummary", t);
    check("get_callers gives the exact call-site lines, inside an anonymous test callback too",
          mcp_sites(msc, "main.ts") == "src/main.ts:5" && mcp_sites(msc, "hooks.test.ts") == "src/hooks.test.ts:8" &&
          mcp_sites(msc, "testSummary") == "src/store.test.ts:6", t);

    guard mcp_tool("get_callers", """{"name_path":"Store/total","depth":3}""", t) else { mcp_close(); return; }
    var d23: json::Node[>..] = []; var x23: u8[>..] = [];
    let deep, e23 = json::parse(t, d23, x23);
    let summ = json::member(jfind(json::member(deep, "callers"), "name_path", "summary"), "call_sites");
    var all_report = true;
    if summ { json::each(summ) { s => if jstr(s, "relative_path") != "src/report.ts" { all_report = false; } }; }
    check("a caller two steps out lists the lines where it uses the nearer caller, not the target",
          jcount(summ) > 0 && all_report, t);

    guard mcp_tool("find_implementations", """{"name_path":"Error"}""", t) else { mcp_close(); return; }
    var d24: json::Node[>..] = []; var x24: u8[>..] = [];
    let err_impls, e24 = json::parse(t, d24, x24);
    let lt = json::member(err_impls, "library_targets");
    var all_ts = true;
    if lt { json::each(lt) { l => if !starts_with(jstr(l, "package"), "typescript ") { all_ts = false; } }; }
    check("find_implementations of the library type Error finds the repo's subclasses at both levels",
          jcount(lt) > 0 && all_ts && sorted_join(jlist(json::member(err_impls, "implementations"), "name_path")) == "HookError,HookTimeout", t);

    guard mcp_tool("get_type_hierarchy", """{"name_path":"HookTimeout"}""", t) else { mcp_close(); return; }
    var d25: json::Node[>..] = []; var x25: u8[>..] = [];
    let err_tree, e25 = json::parse(t, d25, x25);
    let ets = json::member(err_tree, "supertypes");
    var lib_error = false;
    if ets { json::each(ets) { s => if jstr(s, "name_path") == "Error" && starts_with(jstr(s, "package"), "typescript ") { lib_error = true; } }; }
    check("get_type_hierarchy of HookTimeout climbs to HookError and the library's Error",
          jany(ets, "name_path", "HookError") && lib_error, t);

    guard mcp_tool("find_referencing_symbols", """{"name_path":"/makeStore"}""", t) else { mcp_close(); return; }
    var d26: json::Node[>..] = []; var x26: u8[>..] = [];
    let ms_refs, e26 = json::parse(t, d26, x26);
    var marked = false;
    let mr = json::member(nth(ms_refs, 0), "references");
    if mr { json::each(mr) { r => if jtrue(r, "import") && jstr(r, "relative_path") == "src/store.test.ts" { marked = true; } }; }
    check("find_referencing_symbols keeps them, marked import", marked, t);

    guard mcp_tool("get_symbol_at", """{"relative_path":"src/main.ts","line":8,"column":15}""", t) else { mcp_close(); return; }
    var d27: json::Node[>..] = []; var x27: u8[>..] = [];
    let at, e27 = json::parse(t, d27, x27);
    let at0 = nth(json::member(at, "at"), 0);
    check("get_symbol_at main.ts:8:15 is formatItem's target, format() in src/format.ts:3",
          jstr(at0, "name_path") == "format" && jstr(at0, "relative_path") == "src/format.ts" && jint(at0, "line") == 3, t);

    guard mcp_tool("get_symbol_at", """{"relative_path":"src/store.ts","line":11,"column":4}""", t) else { mcp_close(); return; }
    var d28: json::Node[>..] = []; var x28: u8[>..] = [];
    let at_def, e28 = json::parse(t, d28, x28);
    let ad0 = nth(json::member(at_def, "at"), 0);
    check("get_symbol_at on a definition says so", jstr(ad0, "name_path") == "Store/add" && jtrue(ad0, "is_definition"), t);

    guard mcp_tool("get_symbol_at", """{"relative_path":"src/main.ts","line":8,"column":27}""", t) else { mcp_close(); return; }
    var d29: json::Node[>..] = []; var x29: u8[>..] = [];
    let at_none, e29 = json::parse(t, d29, x29);
    check("get_symbol_at on a column with nothing lists the line's symbols",
          jtrue(at_none, "nothing_at_column") && jcount(json::member(at_none, "on_this_line")) > 0, t);

    guard mcp_tool("index_info", "{}", t) else { mcp_close(); return; }
    var d30: json::Node[>..] = []; var x30: u8[>..] = [];
    let info, e30 = json::parse(t, d30, x30);
    check("index_info reports counts", jnum(info, "symbols") > 0 && jnum(info, "occurrences") > 0, t);

    var u: u8[>..] = [];
    // An unknown method answers with an error rather than a result.
    guard mcp_rpc("no/such/method", "", u) else { mcp_close(); return; }
    var d31: json::Node[>..] = []; var x31: u8[>..] = [];
    let unknown, e31 = json::parse(u, d31, x31);
    check("unknown method is a JSON-RPC error", jint(json::member(unknown, "error"), "code") == -32601, u);
    mcp_close();
}

// The call sites of one caller, "path:line" joined by commas.
fn mcp_sites(callers: json::Node?, name: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    let sites = json::member(jfind(callers, "name_path", name), "call_sites");
    if sites {
        json::each(sites) { s =>
            if out.len > 0 { out.push(','); }
            format(out, jstr(s, "relative_path"), ":", jint(s, "line"));
        };
    }
    return out;
}
