// One `swan serve --maps <data-root>` answering about any repo: use_repo
// finds or builds the map and switches to it, every tool's `repo` argument
// does the same for a call, and a path inside a mapped repo resolves to the
// repo's map. `swan serve <db>` still answers as before. Needs
// SWAN_TRUST_BUILD=1 (scripts/test.sh sets it): the tiny-rs map's indexer
// runs the repo's build files. (Was tests/maps_check.ts.)

import std;
import os;
import json;
import sqlite;
import .harness;

fn mp_real(p: const u8[:]) -> u8[>..] {
    var o: u8[>..] = [];
    var e: u8[>..] = [];
    run(argv(["realpath", "-m", p]), "", o, e);
    var r: u8[>..] = [];
    r.append(trim(o));
    return r;
}
fn mp_tmp(prefix: const u8[:]) -> u8[>..] {
    var o: u8[>..] = [];
    var e: u8[>..] = [];
    run(argv(["mktemp", "-d", "-t", str(prefix, "XXXXXX")]), "", o, e);
    return mp_real(trim(o));
}
// SQL text for a string ('' doubled).
fn mp_q(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    out.push('\'');
    for c in s { if c == '\'' { out.push('\''); } out.push(c); }
    out.push('\'');
    return out;
}
// A swan.db with only an old-schema meta table naming root.
fn mp_old_map(path: const u8[:], root: const u8[:]) {
    var err: u8[>..] = [];
    let db = sqlite::open(path, err);
    guard db != 0;
    sqlite::exec_or_die(db, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)");
    sqlite::exec_or_die(db, str("INSERT INTO meta VALUES ('root', ", mp_q(root), "), ('schema_version', '1')"));
    sqlite::close(db);
}

fn maps_suite() {
    let data_root = mp_tmp("swan-maps-");
    let tiny_ts = mp_real("fixtures/tiny-ts");
    let tiny_rs = mp_real("fixtures/tiny-rs");
    guard mcp_open(argv(["bin/swan", "serve", "--maps", data_root]), envv("SWAN_TRUST_BUILD", "1")) else { return; }
    maps_checks(data_root, tiny_ts, tiny_rs);
    mcp_close_code();

    // Old mode is unchanged: `swan serve <db>` still answers about its map.
    if mcp_open(argv(["bin/swan", "serve", "data/tiny-ts/swan.db"]), "") {
        var line: u8[>..] = [];
        var t: u8[>..] = [];
        let r = mcp_call("find_symbol", """{"name_path_pattern":"Store/add"}""", t);
        var d: json::Node[>..] = []; var x: u8[>..] = [];
        let syms, e = json::parse(t, d, x);
        check("swan serve <db> still answers about its map",
              r == 1 && jcount(syms) == 1 && jstr(nth(syms, 0), "relative_path") == "src/store.ts", t);
        mcp_close_code();
    }
}

fn maps_checks(data_root: const u8[:], tiny_ts: const u8[:], tiny_rs: const u8[:]) {
    var t: u8[>..] = [];
    guard mcp_rpc("initialize", """{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"swan-maps-check","version":"0"}}""", t) else { return; }
    var d0: json::Node[>..] = []; var x0: u8[>..] = [];
    let init, e0 = json::parse(t, d0, x0);
    check("initialize names the server", jstr(json::member(json::member(init, "result"), "serverInfo"), "name") == "swan", t);
    mcp_notify("notifications/initialized");
    var tl: u8[>..] = [];
    guard mcp_rpc("tools/list", "", tl) else { return; }
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let tr, e1 = json::parse(tl, d1, x1);
    check("tools/list includes use_repo", has_line(jlist(json::member(json::member(tr, "result"), "tools"), "name"), "use_repo"), tl);

    // No repo selected yet: every tool says what to do, index_info lists the maps.
    var nt: u8[>..] = [];
    let nr = mcp_call("find_symbol", """{"name_path_pattern":"Store/add"}""", nt);
    check("no repo selected: find_symbol says to call use_repo or pass repo",
          nr == 0 && find(nt, "no repo selected: call use_repo with a path, or pass repo") >= 0, nt);
    guard mcp_tool("index_info", "{}", t) else { return; }
    check("no repo selected: index_info lists the known maps", find(t, "\"maps\":[") >= 0, t);

    // use_repo builds tiny-ts's map the first time, then answers about it.
    guard mcp_tool("use_repo", """{"path":"fixtures/tiny-ts"}""", t) else { return; }
    var d2: json::Node[>..] = []; var x2: u8[>..] = [];
    let use_ts, e2 = json::parse(t, d2, x2);
    check("use_repo fixtures/tiny-ts: built the map under the data root",
          jtrue(use_ts, "built") && jstr(use_ts, "root") == tiny_ts && jstr(use_ts, "map") == str(data_root, "/tiny-ts/swan.db"), t);
    check("use_repo reports counts and a timed report",
          jint(use_ts, "symbols") > 0 && jint(use_ts, "files") > 0 && jint(use_ts, "stale_file_count") == 0 &&
          find(jstr(use_ts, "report"), "ms in all") >= 0, t);
    guard mcp_tool("find_symbol", """{"name_path_pattern":"Store/add"}""", t) else { return; }
    var d3: json::Node[>..] = []; var x3: u8[>..] = [];
    let add, e3 = json::parse(t, d3, x3);
    check("after use_repo, find_symbol answers about tiny-ts",
          jcount(add) == 1 && jstr(nth(add, 0), "kind") == "method" && jstr(nth(add, 0), "relative_path") == "src/store.ts", t);

    // use_repo switches to tiny-rs: its symbols answer, tiny-ts's do not.
    guard mcp_tool("use_repo", """{"path":"fixtures/tiny-rs"}""", t) else { return; }
    var d4: json::Node[>..] = []; var x4: u8[>..] = [];
    let use_rs, e4 = json::parse(t, d4, x4);
    check("use_repo fixtures/tiny-rs: built its map too", jtrue(use_rs, "built") && jstr(use_rs, "root") == tiny_rs, t);
    guard mcp_tool("find_symbol", """{"name_path_pattern":"Tile/new"}""", t) else { return; }
    var d5: json::Node[>..] = []; var x5: u8[>..] = [];
    let tile, e5 = json::parse(t, d5, x5);
    check("after the switch, find_symbol answers about tiny-rs (Tile/new in src/lib.rs)",
          jcount(tile) == 1 && jstr(nth(tile, 0), "relative_path") == "src/lib.rs", t);
    guard mcp_tool("find_symbol", """{"name_path_pattern":"Store/add"}""", t) else { return; }
    var d6: json::Node[>..] = []; var x6: u8[>..] = [];
    let gone, e6 = json::parse(t, d6, x6);
    check("tiny-ts's symbols are gone after the switch", jcount(gone) == 0, t);

    // A per-call repo switches back and answers.
    guard mcp_tool("find_symbol", """{"name_path_pattern":"Store/add","repo":"fixtures/tiny-ts"}""", t) else { return; }
    var d7: json::Node[>..] = []; var x7: u8[>..] = [];
    let back, e7 = json::parse(t, d7, x7);
    check("a call's repo argument switches to that repo and answers",
          jcount(back) == 1 && jstr(nth(back, 0), "relative_path") == "src/store.ts", t);
    guard mcp_tool("find_symbol", """{"name_path_pattern":"Tile/new"}""", t) else { return; }
    var d8: json::Node[>..] = []; var x8: u8[>..] = [];
    let stays, e8 = json::parse(t, d8, x8);
    check("the switch persists after the call", jcount(stays) == 0, t);

    // A path inside a mapped repo resolves to the repo's map.
    guard mcp_tool("use_repo", """{"path":"fixtures/tiny-ts/src"}""", t) else { return; }
    var d9: json::Node[>..] = []; var x9: u8[>..] = [];
    let inner, e9 = json::parse(t, d9, x9);
    let b9, b9ok = json::as_bool(json::member(inner, "built"));
    check("use_repo of a path inside a mapped repo finds the repo's map",
          jstr(inner, "root") == tiny_ts && b9ok && !b9 && jstr(inner, "map") == str(data_root, "/tiny-ts/swan.db"), t);

    // Reselecting the map that is already open is a no-op (no reopen, no
    // live-server restart), even after several switches.
    guard mcp_tool("use_repo", """{"path":"fixtures/tiny-ts"}""", t) else { return; }
    check("use_repo of the already-selected repo does not reopen the map", mp_switched(t) == 0, t);
    guard mcp_tool("use_repo", """{"path":"fixtures/tiny-rs"}""", t) else { return; }
    guard mcp_tool("use_repo", """{"path":"fixtures/tiny-ts"}""", t) else { return; }
    check("a real switch reports switched", mp_switched(t) == 1, t);
    guard mcp_tool("use_repo", """{"path":"fixtures/tiny-ts/src"}""", t) else { return; }
    check("after several switches, reselecting the current repo is still a no-op", mp_switched(t) == 0, t);

    // use_repo refuses what is not there, and a file is not a repo.
    let mr = mcp_call("use_repo", """{"path":"fixtures/no-such-dir"}""", t);
    check("use_repo on a missing path errors", mr == 0 && find(t, "no such path") >= 0, t);
    let fr = mcp_call("use_repo", """{"path":"fixtures/tiny-ts/src/store.ts"}""", t);
    check("use_repo on a file errors", fr == 0 && find(t, "not a directory") >= 0, t);

    // The build:false hint names a collision-safe dir: a second repo with an
    // already-mapped basename must not be pointed at that repo's map dir.
    let twin_root = mp_tmp("swan-twin-");
    let twin = str(twin_root, "/tiny-ts");
    mkdir_p(twin);
    write_file(str(twin, "/x.ts"), "export const x = 1;\n");
    var tw: u8[>..] = [];
    let twr = mcp_call("use_repo", str("{\"path\":\"", twin, "\",\"build\":false}"), tw);
    check("build:false for a same-basename repo suggests a dir other than the existing map's",
          twr == 0 && find(tw, "swan map ") >= 0 && find(tw, str(" ", data_root, "/tiny-ts'")) < 0, tw);

    // An old-schema map is never opened (opening it would abort the server);
    // the repo counts as unmapped.
    let old_root = mp_tmp("swan-old-");
    let old_repo = str(old_root, "/oldrepo");
    mkdir_p(old_repo);
    write_file(str(old_repo, "/y.ts"), "export const y = 2;\n");
    mkdir_p(str(data_root, "/oldrepo"));
    mp_old_map(str(data_root, "/oldrepo/swan.db"), mp_real(old_repo));
    var oh: u8[>..] = [];
    let ohr = mcp_call("use_repo", str("{\"path\":\"", old_repo, "\",\"build\":false}"), oh);
    check("an old-schema map is skipped, not opened (server stays up, repo counts as unmapped)",
          ohr == 0 && find(oh, "no map for") >= 0, oh);
    // A damaged swan.db (not SQLite at all) and one with no meta table must
    // not stop the server or hide the healthy maps.
    mkdir_p(str(data_root, "/junk"));
    write_file(str(data_root, "/junk/swan.db"), "this is not a sqlite database\n");
    mkdir_p(str(data_root, "/nometa"));
    var err: u8[>..] = [];
    let nm = sqlite::open(str(data_root, "/nometa/swan.db"), err);
    if nm != 0 { sqlite::exec_or_die(nm, "CREATE TABLE other (x INTEGER)"); sqlite::close(nm); }
    guard mcp_tool("find_symbol", """{"name_path_pattern":"Store/add","repo":"fixtures/tiny-ts"}""", t) else { return; }
    var d10: json::Node[>..] = []; var x10: u8[>..] = [];
    let via, e10 = json::parse(t, d10, x10);
    check("damaged and meta-less maps under the data root don't stop selecting a healthy repo", jcount(via) == 1, t);
    // Building over an old-schema map in the repo's own dir rebuilds it,
    // instead of refreshing into a schema mismatch that would abort the server.
    let rebuild_work = mp_tmp("swan-rebuild-");
    let rebuild_repo = str(rebuild_work, "/rebuildme");
    mkdir_p(str(rebuild_repo, "/src"));
    write_file(str(rebuild_repo, "/src/r.ts"), "export function rebuilt(): number { return 3; }\n");
    write_file(str(rebuild_repo, "/tsconfig.json"), "{\"compilerOptions\":{\"strict\":true},\"include\":[\"src\"]}\n");
    mkdir_p(str(data_root, "/rebuildme"));
    mp_old_map(str(data_root, "/rebuildme/swan.db"), mp_real(rebuild_repo));
    var rb: u8[>..] = [];
    let rbr = mcp_call("use_repo", str("{\"path\":\"", rebuild_repo, "\"}"), rb);
    var d11: json::Node[>..] = []; var x11: u8[>..] = [];
    let rbj, e11 = json::parse(rb, d11, x11);
    check("use_repo over an old-schema map in the repo's own dir rebuilds it and stays up", rbr == 1 && jtrue(rbj, "built"), rb);
    guard mcp_tool("find_symbol", """{"name_path_pattern":"rebuilt"}""", t) else { return; }
    var d12: json::Node[>..] = []; var x12: u8[>..] = [];
    let rsym, e12 = json::parse(t, d12, x12);
    check("the rebuilt map answers", jcount(rsym) == 1, t);
    guard mcp_tool("use_repo", """{"path":"fixtures/tiny-ts"}""", t) else { return; }
    guard mcp_tool("index_info", "{}", t) else { return; }
    var d13: json::Node[>..] = []; var x13: u8[>..] = [];
    let alive, e13 = json::parse(t, d13, x13);
    check("the server still answers after meeting an old-schema map", alive != null && starts_with(trim(t), "{"), t);

    // Without build, an unmapped repo is an error naming the command to run.
    let nbr = mcp_call("use_repo", """{"path":"fixtures/tiny-py","build":false}""", t);
    check("use_repo with build:false names the swan map command", nbr == 0 && find(t, "swan map ") >= 0, t);

    // index_info now answers about the selected map.
    guard mcp_tool("index_info", "{}", t) else { return; }
    var d14: json::Node[>..] = []; var x14: u8[>..] = [];
    let info1, e14 = json::parse(t, d14, x14);
    check("index_info answers about the selected repo", jstr(info1, "root") == tiny_ts && jnum(info1, "symbols") > 0, t);
    rm_rf(twin_root);
    rm_rf(old_root);
    rm_rf(rebuild_work);
}

// use_repo's "switched": 1 true, 0 false, -1 missing.
fn mp_switched(t: const u8[:]) -> i64 {
    var d: json::Node[>..] = []; var x: u8[>..] = [];
    let r, e = json::parse(t, d, x);
    let v, ok = json::as_bool(json::member(r, "switched"));
    return if !ok { -1 } else if v { 1 } else { 0 };
}
