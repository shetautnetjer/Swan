// Spread-Wings beside Swan's edit plans. Swan knows the exact sites a change
// edits; Spread-Wings (github.com/shetautnetjer/spread-wings) knows, from
// syntax, what a definition reaches: the files that call it or import its
// file, which of them are tests, and which groups of the repo they sit in.
// A planned edit_batch asks it about each symbol whose meaning the batch
// changes (renames and replaced bodies) and lists what the change reaches
// that the batch does not edit, and the tests to run afterwards.
//
// Optional: without spread-wings the plan is the same, and says why this
// part is missing.

import std;
import os;
import json;
import sqlite;
import .db;
import .run;
import .pipeline;

// The spread-wings program: $SWAN_SPREAD_WINGS, else `spread-wings` on PATH.
// "" when neither; `why` says which was tried.
fn wings_bin(why: u8[>..]&) -> u8[>..] {
    var found: u8[>..] = [];
    var v: u8[>..] = [];
    if env("SWAN_SPREAD_WINGS", v) && v.len > 0 {
        if file_exists(v) { found.append(v); }
        else { format(why, "SWAN_SPREAD_WINGS is ", v, ", which is not there"); }
        return found;
    }
    var p: u8[>..] = [];
    if env("PATH", p) {
        each_split(p, ':') { d =>
            if found.len == 0 && d.len > 0 && file_exists(str(d, "/spread-wings")) { format(found, d, "/spread-wings"); }
        };
    }
    if found.len == 0 { why.append("spread-wings is not installed: put it on PATH or set SWAN_SPREAD_WINGS to its path"); }
    return found;
}

// Spread-Wings' graph of the repo: wings.db beside the map, rebuilt when the
// map is newer than it. Indexing only parses files, and still runs sealed
// (it reads the repo; it writes only the map folder). Swan's compiler
// answers then settle the calls the graph could tie by name alone.
fn wings_graph(bin: const u8[:], map_db: const u8[:], root: const u8[:], why: u8[>..]&) -> u8[>..] {
    var g: u8[>..] = [];
    // Absolute: the sealed run starts in the repo, not where Swan was started.
    var dir: u8[>..] = [];
    guard swan_realpath(map_db[..rfind(map_db, "/")], dir) else { format(why, "cannot find the map folder of ", map_db); return g; }
    let path = str(dir, "/wings.db");
    let gm = swan_mtime_ns(path);
    if gm >= 0 && gm >= swan_mtime_ns(map_db) { g.append(path); return g; }
    let tmp = str(dir, "/wings.db.new");
    if file_exists(tmp) { delete_file(tmp); }
    var a: u8[>..] = [];
    arg(a, bin); arg(a, "index"); arg(a, root); arg(a, tmp);
    var o: u8[>..] = [];
    var e: u8[>..] = [];
    let code = sealed_run(a, root, dir, false, "", 300000, o, e);
    guard code == 0 && file_exists(tmp) else {
        let tail = if e.len > 300 { e[e.len - 300..] } else { e[..] };
        format(why, "spread-wings index failed (exit ", code, "): ", trim(tail));
        return g;
    }
    a.clear(); o.clear(); e.clear();
    arg(a, bin); arg(a, "compiler"); arg(a, tmp); arg(a, str(dir, "/", map_db[rfind(map_db, "/") + 1..]));
    sealed_run(a, root, dir, false, "", 300000, o, e);      // optional: the graph is usable without it
    guard rename_file(tmp, path) else { format(why, "cannot write ", path); return g; }
    g.append(path);
    return g;
}

// The bare name Spread-Wings knows a symbol by: the last piece of its name path.
fn wings_name(name_path: const u8[:]) -> const u8[:] {
    var n = name_path;
    while n.len > 0 && n[n.len - 1] == '/' { n = n[..n.len - 1]; }
    let s = rfind(n, "/");
    return if s >= 0 { n[s + 1..] } else { n };
}

// One batch's asks: "<edit number>\x1f<name_path>\x1f<relative_path>\x1e" each.
// `planned` lists the files the batch itself edits, one per line.
// Appends a JSON object to out.
fn wings_report(db: i64, map_db: const u8[:], root: const u8[:], asks: const u8[:], planned: const u8[:], out: u8[>..]&) {
    var why: u8[>..] = [];
    fn unavailable() {
        out.append("{\"available\":false,\"why\":");
        json::format_string(out, why);
        out.push('}');
    }
    guard asks.len > 0 else {
        why.append("no rename or replaced body in this batch: insertions and pattern rewrites change no existing definition's callers");
        unavailable();
        return;
    }
    let bin = wings_bin(why);
    guard bin.len > 0 else { unavailable(); return; }
    let g = wings_graph(bin, map_db, root, why);
    guard g.len > 0 else { unavailable(); return; }

    exec_or_die(db, """
        DROP TABLE IF EXISTS temp.w_reach;
        CREATE TEMP TABLE w_reach(path TEXT, edit INTEGER, defines INTEGER, calls INTEGER, imports INTEGER,
                                  is_test INTEGER, community INTEGER, label TEXT);
        DROP TABLE IF EXISTS temp.w_planned;
        CREATE TEMP TABLE w_planned(path TEXT PRIMARY KEY);
        """);
    let pl = prepare_or_die(db, "INSERT OR IGNORE INTO temp.w_planned VALUES (?1)");
    each_split(planned, '\n') { f => if f.len > 0 { sqlite::bind_text(pl, 1, f); step_done(pl); sqlite::reset(pl); } };
    sqlite::finalize(pl);
    let ins = prepare_or_die(db, "INSERT INTO temp.w_reach VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)");

    var per: u8[>..] = [];
    each_split(asks, 0x1e) { rec =>
        let f = split(rec, 0x1f);
        if f.len >= 3 {
            let n, n_ok = parse_int(f[0]);
            let name = wings_name(f[1]);
            var a: u8[>..] = [];
            arg(a, bin); arg(a, "touches"); arg(a, g); arg(a, name); arg(a, f[2]);
            var o: u8[>..] = [];
            var e: u8[>..] = [];
            let code = sealed_run(a, root, g[..rfind(g, "/")], false, "", 60000, o, e);
            if per.len > 0 { per.push(','); }
            format(per, "{\"edit\":", n, ",\"name\":");
            json::format_string(per, name);
            per.append(",\"relative_path\":");
            json::format_string(per, f[2]);
            var doc: json::Node[>..] = [];
            var dec: u8[>..] = [];
            let r, perr = json::parse(o, doc, dec);
            if code != 0 && find(o, "spread-wings index <repo>") >= 0 && find(o, "touches") < 0 {
                // An older spread-wings answers an unknown command with its usage.
                per.append(",\"found\":false,\"why\":\"this spread-wings has no touches command; update it (spread-wings 2132a0f or later)\"}");
            } else if code != 0 || !r {
                per.append(",\"found\":false,\"why\":");
                json::format_string(per, trim(if o.len > 0 { o[..] } else { e[..] }));
                per.push('}');
            } else {
                let s = json::member(r, "summary");
                var defs: i64 = 0;
                var calls: i64 = 0;
                var guessed: i64 = 0;
                let d, d_ok = json::as_i64(json::member(s, "definitions"));
                if d_ok { defs = d; }
                let c, c_ok = json::as_i64(json::member(s, "call_sites"));
                if c_ok { calls = c; }
                let q, q_ok = json::as_i64(json::member(s, "matched_by_name_only"));
                if q_ok { guessed = q; }
                // Community labels by id, from the answer's own list.
                var labels: u8[>..] = [];     // "<id>\x1f<label>\x1e"
                let cs = json::member(r, "communities");
                if cs { json::each(cs) { c =>
                    let id, id_ok = json::as_i64(json::member(c, "id"));
                    let lb, lb_ok = json::as_string(json::member(c, "label"));
                    if id_ok && lb_ok { format(labels, id, "\x1f", lb, "\x1e"); }
                }; }
                var files = 0;
                let fs = json::member(r, "files");
                if fs { json::each(fs) { it =>
                    let p, p_ok = json::as_string(json::member(it, "path"));
                    if p_ok {
                        files++;
                        var df: i64 = 0;
                        var cl: i64 = 0;
                        var im: i64 = 0;
                        let ws = json::member(it, "why");
                        if ws { json::each(ws) { w =>
                            let t, t_ok = json::as_string(w);
                            if t_ok && t == "defines it" { df = 1; }
                            if t_ok && t == "calls it" { cl = 1; }
                            if t_ok && t == "imports its file" { im = 1; }
                        }; }
                        let tst, tst_ok = json::as_bool(json::member(it, "is_test"));
                        let cm, cm_ok = json::as_i64(json::member(it, "community"));
                        var lab: u8[>..] = [];
                        each_split(labels, 0x1e) { l =>
                            let lf = split(l, 0x1f);
                            if lf.len >= 2 && cm_ok { let li, li_ok = parse_int(lf[0]); if li_ok && li == cm && lab.len == 0 { lab.append(lf[1]); } }
                        };
                        sqlite::bind_text(ins, 1, p);
                        sqlite::bind_int(ins, 2, if n_ok { n } else { 0 });
                        sqlite::bind_int(ins, 3, df);
                        sqlite::bind_int(ins, 4, cl);
                        sqlite::bind_int(ins, 5, im);
                        sqlite::bind_int(ins, 6, if tst_ok && tst { 1 } else { 0 });
                        sqlite::bind_int(ins, 7, if cm_ok { cm } else { 0 });
                        sqlite::bind_text(ins, 8, lab);
                        step_done(ins);
                        sqlite::reset(ins);
                    }
                }; }
                format(per, ",\"found\":true,\"definitions\":", defs, ",\"files\":", files, ",\"call_sites\":", calls,
                       ",\"matched_by_name_only\":", guessed);
                if defs > 1 { per.append(",\"note\":\"Spread-Wings knows definitions by name and file: this counts every definition of that name in the file\""); }
                per.push('}');
            }
        }
    };
    sqlite::finalize(ins);

    var err: u8[>..] = [];
    out.append("{\"available\":true,\"per_edit\":[");
    out.append(per);
    out.append("],\"reached_not_edited\":[");
    let st = prepare_or_die(db, """
        SELECT path, MAX(defines), MAX(calls), MAX(imports), MAX(is_test), GROUP_CONCAT(DISTINCT edit)
        FROM temp.w_reach WHERE path NOT IN (SELECT path FROM temp.w_planned)
        GROUP BY path ORDER BY MAX(is_test), path LIMIT 200
        """);
    var first = true;
    while step_checked(st, err) == 1 {
        if !first { out.push(','); }
        first = false;
        var p: u8[>..] = [];
        var eds: u8[>..] = [];
        sqlite::col_text(st, 0, p);
        sqlite::col_text(st, 5, eds);
        out.append("{\"path\":");
        json::format_string(out, p);
        out.append(",\"why\":[");
        var w = 0;
        if sqlite::col_int(st, 1) > 0 { out.append("\"defines it\""); w++; }
        if sqlite::col_int(st, 2) > 0 { if w > 0 { out.push(','); } out.append("\"calls it\""); w++; }
        if sqlite::col_int(st, 3) > 0 { if w > 0 { out.push(','); } out.append("\"imports its file\""); }
        out.append("],\"is_test\":");
        json::format_bool(out, sqlite::col_int(st, 4) > 0);
        format(out, ",\"edits\":[", eds, "]}");
    }
    sqlite::finalize(st);
    out.append("],\"tests\":[");
    let ts = prepare_or_die(db, "SELECT DISTINCT path FROM temp.w_reach WHERE is_test = 1 ORDER BY path");
    first = true;
    while step_checked(ts, err) == 1 {
        if !first { out.push(','); }
        first = false;
        var p: u8[>..] = [];
        sqlite::col_text(ts, 0, p);
        json::format_string(out, p);
    }
    sqlite::finalize(ts);
    out.append("],\"groups\":[");
    let gs = prepare_or_die(db, """
        SELECT label, COUNT(DISTINCT path) FROM temp.w_reach GROUP BY community ORDER BY COUNT(DISTINCT path) DESC, label
        """);
    first = true;
    while step_checked(gs, err) == 1 {
        if !first { out.push(','); }
        first = false;
        var l: u8[>..] = [];
        sqlite::col_text(gs, 0, l);
        out.append("{\"label\":");
        json::format_string(out, l);
        format(out, ",\"files\":", sqlite::col_int(gs, 1), "}");
    }
    sqlite::finalize(gs);
    out.append("],\"evidence\":\"from Spread-Wings, by syntax: the files that define, call or import each renamed or rewritten symbol. Broader than Swan's sites and not compiler-checked; reached_not_edited are files to look at before applying, tests are the ones to run after.\"}");
    exec_or_die(db, "DROP TABLE temp.w_reach; DROP TABLE temp.w_planned;");
}
