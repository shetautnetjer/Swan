// Spread-Wings beside Swan's edit plans. Swan knows the exact sites a change
// edits; Spread-Wings (github.com/shetautnetjer/spread-wings) knows, from
// syntax, what a definition reaches: the files that call it or import its
// file, which of them are tests, and which groups of the repo they sit in.
// A planned edit_batch asks it about each symbol whose meaning the batch
// changes (renames and replaced bodies) and lists what the change reaches
// that the batch does not edit, and the tests to run afterwards.
//
// Without spread-wings the plan is the same, and says why this part is
// missing.
//
// The same graph answers three questions through Swan's server
// (wings_answer): the lay of a repo, what changing a name reaches, and a
// file's neighbours. They are Spread-Wings' answers, by syntax, and say so;
// Swan's own tools give the exact sites.
//
// The graph follows the files, not the map: before each answer Spread-Wings
// brings it up to date from the files that changed since it last looked
// (wings_graph), and the answer says which those were and what they reach.

import std;
import os;
import dictionary;
import json;
import sqlite;
import .db;
import .run;
import .pipeline;

// The spread-wings program: $SWAN_SPREAD_WINGS when set, else the one that
// ships with this Swan (<swan home>/bin/spread-wings, built from the wings/
// submodule at the commit Swan pins), else `spread-wings` on PATH. "" when
// none; `why` says what was tried.
fn wings_bin(why: u8[>..]&) -> u8[>..] {
    var found: u8[>..] = [];
    var v: u8[>..] = [];
    if env("SWAN_SPREAD_WINGS", v) && v.len > 0 {
        if file_exists(v) { found.append(v); }
        else { format(why, "SWAN_SPREAD_WINGS is ", v, ", which is not there"); }
        return found;
    }
    let own = str(swan_home(), "/bin/spread-wings");
    if file_exists(own) { found.append(own); return found; }
    var p: u8[>..] = [];
    if env("PATH", p) {
        each_split(p, ':') { d =>
            if found.len == 0 && d.len > 0 && file_exists(str(d, "/spread-wings")) { format(found, d, "/spread-wings"); }
        };
    }
    if found.len == 0 {
        format(why, "spread-wings is not beside this swan (", own, ") nor on PATH: rebuild or reinstall Swan, or set SWAN_SPREAD_WINGS to its path");
    }
    return found;
}

// The time and size of a file as text, by which "this file is as it was
// left" is told. "" when it is not there.
fn wings_stamp(path: const u8[:]) -> u8[>..] {
    var s: u8[>..] = [];
    let m = swan_mtime_ns(path);
    if m >= 0 { format(s, m, " ", swan_file_size(path)); }
    return s;
}

// Appends "<key>":[...] with at most `cap` of the names `r` holds under
// `key`. Returns how many it holds.
fn wings_names(r: json::Node?, key: const u8[:], cap: i64, out: u8[>..]&) -> i64 {
    var n: i64 = 0;
    out.push('"');
    out.append(key);
    out.append("\":[");
    let xs = json::member(r, key);
    if xs { json::each(xs) { x =>
        let s, ok = json::as_string(x);
        if ok {
            if n < cap { if n > 0 { out.push(','); } json::format_string(out, s); }
            n++;
        }
    }; }
    out.push(']');
    return n;
}

// Reads `spread-wings update`'s answer. True when the graph changed. When
// files changed, `since` receives what goes with the answer that follows:
// the files changed, added and gone, the files that import or call into
// them, and the tests among those and the changed files. Not when the graph
// was built whole: every file is new then, which says nothing.
fn wings_since(answer: const u8[:], since: u8[>..]&) -> bool {
    var doc: json::Node[>..] = [];
    var dec: u8[>..] = [];
    let r, perr = json::parse(answer, doc, dec);
    if !r { return true; }                          // not understood: take the graph as changed
    let whole, w_ok = json::as_bool(json::member(r, "built_whole"));
    if !w_ok || whole { return true; }
    var lists: u8[>..] = [];
    let c = wings_names(r, "changed", 200, lists);
    lists.push(',');
    let a = wings_names(r, "added", 200, lists);
    lists.push(',');
    let d = wings_names(r, "removed", 200, lists);
    guard c + a + d > 0 else { return false; }
    var reach: i64 = 0;
    let n, n_ok = json::as_i64(json::member(r, "reaches_files"));
    if n_ok { reach = n; }
    format(since, "{\"files\":", c + a + d, ",", lists, ",\"reaches_files\":", reach, ",");
    wings_names(r, "reaches", 200, since);
    since.push(',');
    wings_names(r, "tests", 200, since);
    since.append(",\"note\":\"files changed on disk since Spread-Wings' graph was last brought up to date; it was brought up to date from them before this answer. reaches: the files that import or call into them; tests: the tests among those and the changed files. Swan's own map is not refreshed by this: its exact tools say stale for a file changed outside Swan, until swan map runs.\"}");
    return true;
}

// Copies a run that was cut short left behind (wings.db.new*), once they
// are ten minutes older than `now`.
fn wings_sweep(dir: const u8[:], now: i64) {
    var names: u8[>..] = [];
    guard list_dir(dir, names) else { return; }
    each_split(names, '\n') { nm =>
        if starts_with(nm, "wings.db.new") {
            let f = str(dir, "/", nm);
            let m = swan_mtime_ns(f);
            if m >= 0 && now - m > 600000000000 { delete_file(f); }
        }
    };
}

// Spread-Wings' graph of the repo, for answers. Three files beside the map:
//
//   wings-rules.db  the graph by Spread-Wings' rules alone. Before every
//                   answer `spread-wings update` brings it up to date: it
//                   looks at every file's time and size, reads the ones
//                   that changed, and builds the graph when none is there.
//   wings.db        a copy of it with Swan's compiler answers settled on
//                   top (`compiler --into`), made again when the rules
//                   graph changed or the map was written since.
//   wings.checked   the time and size of wings-rules.db when Swan last saw
//                   wings.db in line with it. A rules graph that is not as
//                   Swan left it was written by something else (a run cut
//                   short before its copy, a watcher), and the copy is
//                   made again.
//
// Each step only reads the repo and writes the map folder, and still runs
// sealed. The compiler step is optional: when no copy can be made the
// answers come from the rules graph. `since` receives what the update found
// changed (wings_since); it stays empty when nothing did.
fn wings_graph(bin: const u8[:], map_db: const u8[:], root: const u8[:], why: u8[>..]&, since: u8[>..]&) -> u8[>..] {
    var g: u8[>..] = [];
    // Absolute: the sealed run starts in the repo, not where Swan was started.
    var dir: u8[>..] = [];
    guard swan_realpath(map_db[..rfind(map_db, "/")], dir) else { format(why, "cannot find the map folder of ", map_db); return g; }
    let rules = str(dir, "/wings-rules.db");
    let path = str(dir, "/wings.db");
    let mark = str(dir, "/wings.checked");
    var left: u8[>..] = [];
    read_file(mark, left);
    let before = wings_stamp(rules);
    let others = before.len == 0 || before != left;

    var a: u8[>..] = [];
    arg(a, bin); arg(a, "update"); arg(a, root); arg(a, rules);
    var o: u8[>..] = [];
    var e: u8[>..] = [];
    let code = sealed_run(a, root, dir, false, "", 300000, o, e);
    guard code == 0 else {
        // A spread-wings from before `update` takes the word for something
        // else and fails in its own way: its usage tells the two apart.
        var ua: u8[>..] = [];
        arg(ua, bin);
        var uo: u8[>..] = [];
        var ue: u8[>..] = [];
        sealed_run(ua, root, dir, false, "", 10000, uo, ue);
        if find(uo, "spread-wings update <repo>") < 0 && find(ue, "spread-wings update <repo>") < 0 {
            format(why, "this spread-wings (", bin, ") has no update command: use the one that ships with Swan (unset SWAN_SPREAD_WINGS), or one from 049fe53 or later");
        } else {
            let said = if e.len > 0 { e[..] } else { o[..] };
            let tail = if said.len > 300 { said[said.len - 300..] } else { said[..] };
            format(why, "spread-wings update failed (exit ", code, "): ", trim(tail));
        }
        return g;
    }
    let changed = wings_since(trim(o), since);
    // update writes its file even when it found nothing: this is the rules
    // graph as this answer leaves it.
    var from = wings_stamp(rules);
    let made_at = swan_mtime_ns(path);
    if !others && !changed && made_at >= 0 && made_at >= swan_mtime_ns(map_db) {
        write_file(mark, from);
        g.append(path);
        return g;
    }

    wings_sweep(dir, swan_mtime_ns(rules));
    var made = false;
    var tries = 0;
    while tries < 3 && !made {
        tries++;
        // A name of its own: two Swans may be making the copy at once.
        let tmp = str(dir, "/wings.db.new.", (random_seed() % 1000000000000) as i64);
        a.clear(); o.clear(); e.clear();
        arg(a, bin); arg(a, "compiler"); arg(a, rules); arg(a, str(dir, "/", map_db[rfind(map_db, "/") + 1..]));
        arg(a, "--into"); arg(a, tmp);
        sealed_run(a, root, dir, false, "", 300000, o, e);
        guard file_exists(tmp) else { break; }
        let now = wings_stamp(rules);
        if now == from {
            guard rename_file(tmp, path) else { delete_file(tmp); format(why, "cannot write ", path); return g; }
            made = true;
        } else {
            // Another update wrote the rules graph while the copy was being
            // made, and the copy may be of either: again, from what is there now.
            delete_file(tmp);
            from.clear();
            from.append(now);
        }
    }
    if made {
        write_file(mark, from);
        g.append(path);
    } else {
        g.append(rules);
    }
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
    var since: u8[>..] = [];
    let g = wings_graph(bin, map_db, root, why, since);
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
    out.append("{\"available\":true,");
    if since.len > 0 { format(out, "\"files_changed\":", since, ","); }
    out.append("\"per_edit\":[");
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

// What Spread-Wings' answers are worth, said with each of them.
let WINGS_EVIDENCE = "from Spread-Wings, by syntax: links are matched by import, by the type a call names, and by name, not resolved by a compiler (each call site's resolution says which). Broad and quick, for finding your way; find_referencing_symbols and get_callers give the exact sites.";

// One Spread-Wings query about the selected repo, through the server:
// `cmd` is overview, touches or neighbors; a and b its arguments ("" for
// none). Brings the graph beside the map up to date first (wings_graph);
// when files had changed, "files_changed" says which and what they reach.
// The answer is Spread-Wings' own JSON under "result". False with the
// reason in `out` when Spread-Wings is missing or the query fails.
fn wings_answer(db: i64, map_db: const u8[:], cmd: const u8[:], a: const u8[:], b: const u8[:], out: u8[>..]&) -> bool {
    var root: u8[>..] = [];
    meta_value(db, "root", root);
    var why: u8[>..] = [];
    let bin = wings_bin(why);
    guard bin.len > 0 else { out.append(why); return false; }
    var since: u8[>..] = [];
    let g = wings_graph(bin, map_db, root, why, since);
    guard g.len > 0 else { out.append(why); return false; }
    var argv: u8[>..] = [];
    arg(argv, bin); arg(argv, cmd); arg(argv, g);
    if a.len > 0 { arg(argv, a); }
    if b.len > 0 { arg(argv, b); }
    var o: u8[>..] = [];
    var e: u8[>..] = [];
    let code = sealed_run(argv, root, g[..rfind(g, "/")], false, "", 60000, o, e);
    let answer = trim(o);
    guard code == 0 && answer.len > 0 && (answer[0] == '{' || answer[0] == '[') else {
        // Spread-Wings says what was wrong on stderr ("no definition named x").
        let said = trim(if e.len > 0 { e[..] } else { o[..] });
        out.append(if said.len > 0 { said } else { "spread-wings gave no answer" });
        return false;
    }
    out.append("{\"source\":\"spread-wings\",\"evidence\":");
    json::format_string(out, WINGS_EVIDENCE);
    if since.len > 0 { format(out, ",\"files_changed\":", since); }
    out.append(",\"result\":");
    out.append(answer);
    out.push('}');
    return true;
}

let POSSIBLE_CALLERS_NOTE = "From Spread-Wings, by syntax, not compiler-checked: call sites the compiler index does not cover. how says how each was tied to this definition; by_name means any definition with this name could be the one called. Read each site before relying on it.";

// Distance-1 call sites Spread-Wings ties to the target definition(s) that
// the compiler index neither put in the exact callers nor resolved to another
// symbol. Reads wings.db directly after bringing it up to date via
// wings_graph; runs outside any read snapshot on `db`.
// Leaves `out` unchanged when Spread-Wings succeeds with 0 sites; appends
// {"checked":false,"why":"..."} when Spread-Wings is missing or fails.
fn wings_possible_callers(db: i64, map_db: const u8[:], root: const u8[:], ids: const u8[:],
                          specs: const u8[:], exact: const u8[:], out: u8[>..]&) {
    guard out.len > 0 && out[out.len - 1] == '}' else { return; }
    fn append_unchecked(reason: const u8[:]) {
        out.pop();
        out.append(",\"possible_callers\":{\"checked\":false,\"why\":");
        json::format_string(out, reason);
        out.append("}}");
    }
    var why: u8[>..] = [];
    guard root.len > 0 else {
        append_unchecked("the map does not record its repo root; rebuild it with swan map");
        return;
    }
    guard map_db.len > 0 else {
        append_unchecked("no map path is set for this server");
        return;
    }
    let bin = wings_bin(why);
    guard bin.len > 0 else { append_unchecked(why); return; }
    var since: u8[>..] = [];
    let g = wings_graph(bin, map_db, root, why, since);
    guard g.len > 0 else { append_unchecked(why); return; }
    guard specs.len > 0 else { return; }

    var werr: u8[>..] = [];
    let wdb = sqlite::open_existing(g, werr);
    guard wdb != 0 else {
        append_unchecked(str("cannot open Spread-Wings graph: ", werr));
        return;
    }
    sqlite::exec(wdb, "PRAGMA busy_timeout = 5000;", werr);
    werr.clear();

    // Match each Swan target definition to its symbol id in wings.db.
    var gids: u8[>..] = [];
    let find_sym = sqlite::prepare(wdb, """
        SELECT g.id FROM symbols g JOIN files f ON f.id = g.file_id
        WHERE f.path = ?1 AND g.name = ?2 AND g.row <= ?3 AND g.end_row >= ?3
        ORDER BY g.end_row - g.row LIMIT 1
        """, werr);
    guard find_sym != 0 else {
        sqlite::close(wdb);
        append_unchecked(str("cannot read Spread-Wings graph: ", werr));
        return;
    }
    var read_ok = true;
    each_split(specs, 0x1e) { rec =>
        if read_ok && rec.len > 0 {
            let f = split(rec, 0x1f);
            if f.len >= 3 {
                let dline, dl_ok = parse_int(f[2]);
                if dl_ok {
                    sqlite::bind_text(find_sym, 1, f[1]);
                    sqlite::bind_text(find_sym, 2, f[0]);
                    sqlite::bind_int(find_sym, 3, dline + 1);
                    let r = sqlite::step(find_sym, werr);
                    if r == 1 {
                        if gids.len > 0 { gids.push(','); }
                        format(gids, sqlite::col_int(find_sym, 0));
                    } else if r < 0 {
                        read_ok = false;
                    }
                    sqlite::reset(find_sym);
                }
            }
        }
    };
    sqlite::finalize(find_sym);
    guard read_ok else {
        sqlite::close(wdb);
        append_unchecked(str("cannot read Spread-Wings graph: ", werr));
        return;
    }
    guard gids.len > 0 else {
        sqlite::close(wdb);
        return;
    }

    // Exact distance-1 sites from the snapshot, keyed by "<file>\x1f<1-based line>".
    var exact_set = dictionary<const u8[:], bool> {};
    each_split(exact, '\n') { k => if k.len > 0 { exact_set.insert(k, true); } };

    // Non-compiler edges pointing at the target definition(s), ordered by path
    // and line (strongest resolution first when a line has more than one edge).
    var edge_sql: u8[>..] = [];
    format_replaced(edge_sql, """
        SELECT f.path, e.row,
               CASE WHEN COALESCE(cs.container, '') <> '' THEN cs.container || '/' || cs.name
                    ELSE COALESCE(cs.name, '') END,
               COALESCE(e.resolution, ''),
               t.name,
               (SELECT COUNT(*) FROM calls c
                WHERE c.file_id = e.file_id AND c.row = e.row AND c.callee = t.name)
        FROM call_edges e
        JOIN files f ON f.id = e.file_id
        JOIN symbols t ON t.id = e.callee
        LEFT JOIN symbols cs ON cs.id = e.caller
        WHERE e.callee IN (#GIDS#) AND COALESCE(e.resolution, '') != 'compiler'
        ORDER BY f.path, e.row,
                 CASE e.resolution
                     WHEN 'own_type' THEN 1 WHEN 'type_name' THEN 2 WHEN 'same_file' THEN 3
                     WHEN 'imported_name' THEN 4 WHEN 'module_alias' THEN 5 WHEN 'imported_file' THEN 6
                     WHEN 'decided' THEN 7 WHEN 'by_name' THEN 8 ELSE 9 END
        """, "#GIDS#", gids);
    let edges = sqlite::prepare(wdb, edge_sql, werr);
    guard edges != 0 else {
        sqlite::close(wdb);
        append_unchecked(str("cannot read Spread-Wings graph: ", werr));
        return;
    }

    // Check whether Swan's compiler index already resolved calls of this name
    // on the same file and line to another symbol (in-repo or external).
    var other_sql: u8[>..] = [];
    format_replaced(other_sql, """
        SELECT COUNT(*) FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
        WHERE o.file = ?1 AND o.start_line = ?2
          AND o.is_def = 0 AND o.by_name = 0 AND o.is_import = 0
          AND s.name = ?3 AND o.symbol_id NOT IN (#IDS#)
        """, "#IDS#", ids);
    var derr: u8[>..] = [];
    let other_st = sqlite::prepare(db, other_sql, derr);
    guard other_st != 0 else {
        sqlite::finalize(edges);
        sqlite::close(wdb);
        append_unchecked(str("cannot check compiler index: ", derr));
        return;
    }

    var sites_json: u8[>..] = [];
    var total: i64 = 0;
    var listed: i64 = 0;
    var prev_path: u8[>..] = [];
    var prev_row: i64 = -1;
    var step_r: i32 = 0;
    loop {
        step_r = sqlite::step(edges, werr);
        if step_r != 1 { break; }
        var path: u8[>..] = [];
        sqlite::col_text(edges, 0, path);
        let row = sqlite::col_int(edges, 1);
        if path == prev_path && row == prev_row { continue; }
        prev_path.clear();
        prev_path.append(path);
        prev_row = row;

        let key = str(path, "\x1f", row);
        if exact_set.contains(key) { continue; }

        if !is_stale(path) {
            var tname: u8[>..] = [];
            sqlite::col_text(edges, 4, tname);
            let raw_ncalls = sqlite::col_int(edges, 5);
            let ncalls: i64 = if raw_ncalls > 0 { raw_ncalls } else { 1 };

            sqlite::bind_text(other_st, 1, path);
            sqlite::bind_int(other_st, 2, row - 1);
            sqlite::bind_text(other_st, 3, tname);
            var other_n: i64 = 0;
            let or_r = sqlite::step(other_st, derr);
            if or_r == 1 { other_n = sqlite::col_int(other_st, 0); }
            sqlite::reset(other_st);
            if or_r < 0 { read_ok = false; werr.clear(); format(werr, "compiler index check failed: ", derr); break; }
            if other_n >= ncalls { continue; }
        }

        total++;
        if listed < 50 {
            var in_sym: u8[>..] = [];
            var how: u8[>..] = [];
            sqlite::col_text(edges, 2, in_sym);
            sqlite::col_text(edges, 3, how);
            if listed > 0 { sites_json.push(','); }
            listed++;
            sites_json.append("{\"relative_path\":");
            json::format_string(sites_json, path);
            sites_json.append(",\"line\":");
            json::format_int(sites_json, row);
            sites_json.append(",\"in_symbol\":");
            json::format_string(sites_json, in_sym);
            sites_json.append(",\"how\":");
            json::format_string(sites_json, how);
            sites_json.push('}');
        }
    }
    sqlite::finalize(other_st);
    sqlite::finalize(edges);
    sqlite::close(wdb);
    if step_r < 0 || !read_ok {
        append_unchecked(str("cannot read Spread-Wings graph: ", werr));
        return;
    }
    guard total > 0 else { return; }

    out.pop();
    out.append(",\"possible_callers\":{\"note\":");
    json::format_string(out, POSSIBLE_CALLERS_NOTE);
    out.append(",\"total\":");
    json::format_int(out, total);
    out.append(",\"sites\":[");
    out.append(sites_json);
    out.append("]}}");
}
