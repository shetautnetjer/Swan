// Edits a copy of the fixture through the MCP tools, then checks: the files
// say what the edits asked for, tsc still compiles the copy, a rename
// skipped the alias and refused a conflict, a stale file was refused, and
// the positions Swan shifted itself match a fresh SCIP run afterwards.
// (Was tests/edit_check.ts.)

import std;
import os;
import json;
import sqlite;
import dictionary;
import .harness;

fn ed_file(work: const u8[:], p: const u8[:]) -> u8[>..] {
    var t: u8[>..] = [];
    read_file(str(work, "/repo/", p), t);
    return t;
}

// Each in-repo symbol's position, "def_file name_path" -> "line|col|start|end".
fn ed_positions(db_path: const u8[:], keys: u8[>..]&, vals: dictionary<u64, i64>&, store: u8[>..]&) -> i64 {
    var err: u8[>..] = [];
    let db = sqlite::open_existing(db_path, err);
    guard db != 0 else { return 0; }
    let st = sqlite::prepare_or_die(db, """
        SELECT def_file, name_path, def_line, def_col, body_start, body_end FROM symbols
        WHERE in_repo = 1 AND kind NOT IN ('parameter','module') ORDER BY 2, 1
        """);
    var n = 0;
    var c: u8[>..] = [];
    while sqlite::step(st, err) == 1 {
        var key: u8[>..] = [];
        c.clear(); sqlite::col_text(st, 0, c); key.append(c); key.push(' ');
        c.clear(); sqlite::col_text(st, 1, c); key.append(c);
        let at = store.len;
        for k in 2..6 {
            if k > 2 { store.push('|'); }
            c.clear(); sqlite::col_text(st, k as i32, c); store.append(c);
        }
        store.push('\n');
        vals.insert(hash(key), at);
        format(keys, key, "\n");
        n++;
    }
    sqlite::finalize(st);
    sqlite::close(db);
    return n;
}
fn ed_val(store: const u8[:], at: i64) -> const u8[:] { store[at..at + find(store[at..], "\n")] }

fn edit_suite() {
    let work = "data/edit-check";
    rm_rf(work);
    mkdir_p(work);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-ts", str(work, "/repo")]), "", o) else { return; }
    // Two definitions on one line, and a class whose replacement drops a method.
    write_file(str(work, "/repo/src/oneline.ts"), "export function one() { return 1; } export function two() { return 2; }\n\nexport class Pair {\n  left(): number { return 1; }\n  right(): number { return 2; }\n}\n");
    guard sh(argv(["scripts/index-repo.sh", str(work, "/repo"), str(work, "/map")]), "", o) else { return; }
    guard mcp_open(argv(["bin/swan", "serve", str(work, "/map/swan.db")]), "") else { return; }

    // 1. Replace a method body: two lines longer than before.
    var t: u8[>..] = [];
    var ok = mcp_call("replace_symbol_body", """{"name_path":"Store/total","relative_path":"src/store.ts","body":"total(): number {\n    let sum = 0;\n    for (const item of this.items.values()) {\n      sum += item.weight;\n    }\n    return sum;\n  }"}""", t) == 1;
    check("replace_symbol_body Store/total", ok && find(ed_file(work, "src/store.ts"), "sum += item.weight;\n    }") >= 0, t);

    // 2. Insert a method after Store/get, inside the class.
    ok = mcp_call("insert_after_symbol", """{"name_path":"Store/get","relative_path":"src/store.ts","body":"  has(id: string): boolean {\n    return this.items.has(id);\n  }"}""", t) == 1;
    let s2 = ed_file(work, "src/store.ts");
    let gi = find(s2, "get(id: string)");
    let hi = find(s2, "\n  }\n\n  has(id: string): boolean");
    check("insert_after_symbol Store/get adds Store.has inside the class", ok && gi >= 0 && hi > gi, t);

    // run_tests opens the map on its own; edits afterwards must still see files as fresh.
    mcp_call("run_tests", """{"relative_path":"src/store.ts"}""", t);

    // 3. Insert a function before makeStore. Its position must have followed edits 1 and 2.
    var et: u8[>..] = [];
    ok = mcp_call("insert_before_symbol", """{"name_path":"makeStore","relative_path":"src/store.ts","body":"export function emptyStore(): Store {\n  return new Store();\n}"}""", et) == 1;
    check("insert_before_symbol makeStore lands right above it, after the earlier edits moved it",
          ok && find(ed_file(work, "src/store.ts"), "export function emptyStore(): Store {\n  return new Store();\n}\n\nexport function makeStore()") >= 0, et);
    var de: json::Node[>..] = []; var xe: u8[>..] = [];
    let empty, ee = json::parse(et, de, xe);
    check("an edit reports who uses the symbol", jint(json::member(empty, "used_by"), "references") > 0, et);

    // 4. Rename: plan, conflict, apply.
    var pt: u8[>..] = [];
    ok = mcp_call("rename_symbol", """{"name_path":"format","relative_path":"src/format.ts","new_name":"formatEntry"}""", pt) == 1;
    var dp: json::Node[>..] = []; var xp: u8[>..] = [];
    let plan, ep = json::parse(pt, dp, xp);
    let applied, aok = json::as_bool(json::member(plan, "applied"));
    check("rename plan lists the definition and the re-export, and skips the formatItem alias uses",
          ok && jcount(json::member(plan, "sites")) == 2 && jcount(json::member(plan, "skipped")) >= 2 && aok && !applied &&
          find(ed_file(work, "src/format.ts"), "function format(") >= 0, pt);
    var ct: u8[>..] = [];
    let clash_ok = mcp_call("rename_symbol", """{"name_path":"Store/add","relative_path":"src/store.ts","new_name":"get","apply":true}""", ct);
    var dc: json::Node[>..] = []; var xc: u8[>..] = [];
    let clash, ec = json::parse(ct, dc, xc);
    check("rename onto an existing sibling is refused as a conflict",
          clash_ok == 0 && jstr(nth(json::member(clash, "conflicts"), 0), "name_path") == "Store/get" &&
          find(ed_file(work, "src/store.ts"), "get(\"a\")") < 0, ct);
    ok = mcp_call("rename_symbol", """{"name_path":"format","relative_path":"src/format.ts","new_name":"formatEntry","apply":true}""", t) == 1;
    check("rename applied: definition and re-export renamed, alias kept",
          ok && find(ed_file(work, "src/format.ts"), "function formatEntry(") >= 0 &&
          find(ed_file(work, "src/index.ts"), "export { formatEntry as formatItem }") >= 0 &&
          find(ed_file(work, "src/main.ts"), "formatItem(a)") >= 0, t);
    mcp_call("find_symbol", """{"name_path_pattern":"formatEntry"}""", t);
    var da: json::Node[>..] = []; var xa: u8[>..] = [];
    let after, ea = json::parse(t, da, xa);
    check("the map follows the rename", jstr(nth(after, 0), "name_path") == "formatEntry", t);

    // 4b. Names a language would not accept are refused before anything is written.
    ed_bad_rename("123abc", work);
    ed_bad_rename("foo-bar", work);

    // 4c. Two definitions on one line: lengthening the first moves the second's columns.
    var t1: u8[>..] = [];
    var t2: u8[>..] = [];
    let ok1 = mcp_call("replace_symbol_body", """{"name_path":"one","relative_path":"src/oneline.ts","body":"export function one() { const x = 1; return x; }"}""", t1) == 1;
    let ok2 = mcp_call("replace_symbol_body", """{"name_path":"two","relative_path":"src/oneline.ts","body":"export function two() { return 22; }"}""", t2) == 1;
    let ol = ed_file(work, "src/oneline.ts");
    check("an edit after a same-line edit lands on its own symbol",
          ok1 && ok2 && starts_with(ol, "export function one() { const x = 1; return x; } export function two() { return 22; }\n"),
          str(t1, "\n     ", t2, "\n     ", ol[..max(0, find(ol, "\n"))]));

    // 4d. Replacing a class with fewer methods: the dropped one is gone from the map.
    let pok = mcp_call("replace_symbol_body", """{"name_path":"Pair","relative_path":"src/oneline.ts","body":"export class Pair {\n  left(): number { return 1; }\n}"}""", t) == 1;
    var gt: u8[>..] = [];
    let gok = mcp_call("replace_symbol_body", """{"name_path":"Pair/right","relative_path":"src/oneline.ts","body":"right(): number { return 3; }"}""", gt);
    check("a method dropped by replacing its class can no longer be edited",
          pok && gok == 0 && find(gt, "no symbol matches") >= 0 && find(ed_file(work, "src/oneline.ts"), "return 3") < 0, gt);

    // 5. A file changed behind Swan's back is refused (its time pushed a
    // minute ahead, then put back from a reference copy of its times).
    let kinds = str(work, "/repo/src/kinds.ts");
    let keep = str(work, "/kinds-times");
    var e5: u8[>..] = [];
    run(argv(["touch", "-r", kinds, keep]), "", o, e5);
    run(argv(["touch", "-d", str("@", (time() as i64) + 60), kinds]), "", o, e5);
    var st: u8[>..] = [];
    let sok = mcp_call("replace_symbol_body", """{"name_path":"Box/weigh","relative_path":"src/kinds.ts","body":"weigh(): number { return 3; }"}""", st);
    check("an edit to a file changed outside Swan is refused", sok == 0 && find(st, "changed since the map was built") >= 0, st);
    run(argv(["touch", "-r", keep, kinds]), "", o, e5);
    delete_file(keep);

    // Swan's own positions, before a fresh SCIP run checks them.
    mcp_close_code();
    var keys_a: u8[>..] = [];
    var vals_a = dictionary<u64, i64> {};
    var store_a: u8[>..] = [];
    let n_shifted = ed_positions(str(work, "/map/swan.db"), keys_a, vals_a, store_a);

    // 6. The edited copy still compiles.
    var tout: u8[>..] = [];
    var terr: u8[>..] = [];
    let tcode = run(argv(["tools/node_modules/.bin/tsc", "--noEmit", "-p", str(work, "/repo")]), "", tout, terr);
    check("tsc --noEmit passes on the edited copy", tcode == 0, tout);

    // 7. A fresh SCIP run agrees with every position Swan shifted itself.
    guard sh(argv(["scripts/refresh-repo.sh", str(work, "/repo"), str(work, "/map")]), "", o) else { return; }
    var keys_b: u8[>..] = [];
    var vals_b = dictionary<u64, i64> {};
    var store_b: u8[>..] = [];
    ed_positions(str(work, "/map/swan.db"), keys_b, vals_b, store_b);
    var wrong: u8[>..] = [];
    var n_wrong = 0;
    each_split(keys_a, '\n') { k =>
        guard k.len > 0;
        let b = vals_b.get(hash(k));
        guard b;   // renamed or replaced: compared below by name
        let a = vals_a.get(hash(k));
        guard a;
        let ia: i64 = a;
        let ib: i64 = b;
        let va = ed_val(store_a, ia);
        let vb = ed_val(store_b, ib);
        if va != vb {
            if n_wrong < 5 { format(wrong, k, " swan ", va, " scip ", vb, "\n     "); }
            n_wrong++;
        }
    };
    check(str("shifted positions match a fresh SCIP run (", n_shifted, " symbols compared)"), n_wrong == 0, wrong);
    check("after the refresh the new code is mapped: Store/has and emptyStore",
          vals_b.contains(hash("src/store.ts Store/has")) && vals_b.contains(hash("src/store.ts emptyStore")), "");
}

fn ed_bad_rename(bad: const u8[:], work: const u8[:]) {
    var t: u8[>..] = [];
    let r = mcp_call("rename_symbol", str("{\"name_path\":\"makeStore\",\"relative_path\":\"src/store.ts\",\"new_name\":\"", bad, "\",\"apply\":true}"), t);
    check(str("rename to '", bad, "' is refused"),
          r == 0 && find(t, "must be an identifier") >= 0 && find(ed_file(work, "src/store.ts"), "makeStore") >= 0, t);
}
