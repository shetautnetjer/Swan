// Live answers from a language server that `swan serve` keeps running
// (rust-analyzer first): diagnostics right after an edit, without a full
// check, and implementations as the server sees them now. The client is the
// goose-lsp library (the lsp/ submodule), compiled to C on its own and
// linked in, so it never adds to swan's own Goose build. Which server, with which
// options, comes from the "lsp" entries in tools/modules.json.

import std;
import os;
import json;
import sqlite;

extern fn golsp_start(repo: const u8[:], log: const u8[:], init_json: const u8[:], argv: const u8[:],
                         env: const u8[:], lang_id: const u8[:]) -> bool;
extern fn golsp_ask(question: const u8[:], out: u8[>..]&);
extern fn golsp_stop();

var live_lang: u8[..64];        // the language whose server is running; empty when none
var live_within: u8[..4096];    // a folder of the repo to start the server in (`swan lsp-index --within`); empty: the repo itself
var live_settle: u8[..16];      // its "settle" from modules.json: check or publish
var live_quiet: i64 = 0;        // its "quiet_ms": silence that means a file has nothing to report

// Starts the server for `lang` unless it is already running; one at a time.
// When it cannot start, also returns the class of refusal: "no_server",
// "untrusted" or "failed".
fn live_start_why(db: i64, lang: const u8[:], why: u8[>..]&) -> bool, const u8[:] {
    if live_lang.len > 0 && live_lang == lang { return true, ""; }
    var root: u8[>..] = [];
    var dir: u8[>..] = [];
    meta_value(db, "root", root);
    meta_value(db, "source", dir);
    return live_start_at_why(root, dir, lang, why);
}

fn live_start(db: i64, lang: const u8[:], why: u8[>..]&) -> bool {
    let ok, reason = live_start_why(db, lang, why);
    return ok;
}

// Whether this process is already inside eggshell's seal (it exports
// EGG_REPO): a server started from here is sealed with it, and sealing it
// again would need namespaces the seal does not hand out.
fn inside_seal() -> bool {
    var v: u8[>..] = [];
    return env("EGG_REPO", v) && v.len > 0;
}

// The same for a repo and map folder given directly: the map need not exist
// yet (`swan lsp-index` runs while it is being built).
fn live_start_at_why(root: const u8[:], dir: const u8[:], lang: const u8[:], why: u8[>..]&) -> bool, const u8[:] {
    if live_lang.len > 0 && live_lang == lang { return true, ""; }
    live_stop();
    guard root.len > 0 && dir.len > 0 else { why.append("the map does not record its repo; rebuild it with swan map"); return false, "failed"; }
    let home = swan_home();
    var text: u8[>..] = [];
    guard read_file(str(home, "/tools/modules.json"), text) else { why.append("tools/modules.json is missing"); return false, "failed"; }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let mods, perr = json::parse(text, doc, decoded);
    guard mods else { why.append(str("tools/modules.json: ", perr)); return false, "failed"; }
    let list = json::member(json::member(mods, lang), "lsp");
    guard list else { format(why, "no live server for ", lang, " in tools/modules.json"); return false, "no_server"; }
    var l = detect(root);
    if !build_trusted(root, dir) { l.venv.clear(); }    // the repo's virtualenv is its own code
    let c = mod_ctx(root, dir, home, l);
    let base = child_env(l, "");
    var started = false;
    var tried = false;
    json::each(list) { cand =>
        if !tried && cand_applies(cand, c, base) {
            tried = true;
            var argv: u8[>..] = [];
            var extra: u8[>..] = [];
            if build_cmd(cand, c, "", argv, extra) {
                // "sealed": the server runs inside eggshell, like the map's
                // indexers: it reads the repo and writes only the map folder.
                let sl, sl_ok = json::as_bool(json::member(cand, "sealed"));
                if sl_ok && sl && sandbox_on() && !inside_seal() {
                    let wrapped = seal_argv(argv, root, dir, false);
                    argv.clear();
                    argv.append(wrapped);
                }
                var init: u8[>..] = [];
                let raw, i_ok = json::as_string(json::member(cand, "init"));
                if i_ok { expand(raw, c, init); } else { init.append("{}"); }
                let lid, l_ok = json::as_string(json::member(cand, "language_id"));
                var env_all: u8[>..] = [];
                env_all.append(base);
                env_all.append(extra);
                // The server's own folder is the repo, or one project of it
                // (a Go module); the seal, the trust and the tools above are
                // the repo's either way. Each folder has its own log.
                let ws: u8[>..] = if live_within.len > 0 { str(root, "/", live_within) } else { str(root) };
                let log: u8[>..] = if live_within.len > 0 { str(dir, "/lsp-", lang, "-", hash(live_within[..]) % 100000, ".log") }
                                   else { str(dir, "/lsp-", lang, ".log") };
                started = golsp_start(ws, log, init, argv, env_all, if l_ok { lid } else { lang });
                if !started { format(why, "the ", lang, " language server did not start; see ", log); }
                let st, st_ok = json::as_string(json::member(cand, "settle"));
                live_settle.clear();
                format(live_settle, if st_ok { st } else { "publish" });
                let qm, qm_ok = json::as_i64(json::member(cand, "quiet_ms"));
                live_quiet = if qm_ok { qm } else { 0 };
            }
        }
    };
    if !tried {
        var waits = false;
        json::each(list) { cand => if runs_repo_code(cand) && !c.trusted { waits = true; } };
        if waits {
            why.append(untrusted_note(str(" the ", lang, " language server"), root));
            return false, "untrusted";
        }
        format(why, "no live server for ", lang, " applies here");
        return false, "no_server";
    }
    if started { format(live_lang, lang); return true, ""; }
    return false, "failed";
}

fn live_start_at(root: const u8[:], dir: const u8[:], lang: const u8[:], why: u8[>..]&) -> bool {
    let ok, reason = live_start_at_why(root, dir, lang, why);
    return ok;
}

fn live_stop() {
    guard live_lang.len > 0;
    golsp_stop();
    live_lang.clear();
}

// Asks the running server; the answer is the library's JSON, as is.
fn live_ask_why(db: i64, rel: const u8[:], question: const u8[:], out: u8[>..]&) -> bool, const u8[:] {
    let lang = lang_of_path(rel);
    guard lang.len > 0 else { format(out, "no live server for ", rel); return false, "no_server"; }
    var why: u8[>..] = [];
    let started, reason = live_start_why(db, lang, why);
    guard started else { out.append(why); return false, reason; }
    var a: u8[>..] = [];
    golsp_ask(question, a);
    if find(a, "\"gone\":true") >= 0 { live_lang.clear(); }   // the next question starts it again
    out.append(a);
    if starts_with(a, "{\"ok\":true") { return true, ""; }
    return false, "failed";
}

fn live_ask(db: i64, rel: const u8[:], question: const u8[:], out: u8[>..]&) -> bool {
    let ok, reason = live_ask_why(db, rel, question, out);
    return ok;
}

// Any LSP request about a file (and a 1-based place in it, when line > 0),
// answered with the server's own result: see goose-lsp's "request".
fn live_request(root: const u8[:], dir: const u8[:], rel: const u8[:], method: const u8[:], line: i64, col: i64,
                more: const u8[:], out: u8[>..]&) -> bool {
    let lang = lang_of_path(rel);
    guard lang.len > 0 else { format(out, "no live server for ", rel); return false; }
    var why: u8[>..] = [];
    guard live_start_at(root, dir, lang, why) else { out.append(why); return false; }
    var q: u8[>..] = [];
    q.append("{\"op\":\"request\",\"file\":");
    json::format_string(q, rel);
    q.append(",\"method\":");
    json::format_string(q, method);
    if line > 0 { format(q, ",\"line\":", line, ",\"col\":", col); }
    if more.len > 0 { q.append(",\"more\":"); json::format_string(q, more); }
    q.push('}');
    golsp_ask(q, out);
    if find(out, "\"gone\":true") >= 0 { live_lang.clear(); }
    return starts_with(out, "{\"ok\":true");
}

// get_diagnostics with live: what the server reports for one file now.
fn live_diagnostics_why(db: i64, rel: const u8[:], out: u8[>..]&) -> bool, const u8[:] {
    guard rel.len > 0 else { out.append("live diagnostics need relative_path (one file)"); return false, "failed"; }
    let lang = lang_of_path(rel);
    guard lang.len > 0 else { format(out, "no live server for ", rel); return false, "no_server"; }
    var q: u8[>..] = [];
    var why: u8[>..] = [];
    let started, reason = live_start_why(db, lang, why);
    guard started else { out.append(why); return false, reason; }
    q.append("{\"op\":\"diagnostics\",\"file\":");
    json::format_string(q, rel);
    q.append(",\"settle\":");
    json::format_string(q, live_settle);
    if live_quiet > 0 { format(q, ",\"quiet_ms\":", live_quiet); }
    q.push('}');
    return live_ask_why(db, rel, q, out);
}

fn live_diagnostics(db: i64, rel: const u8[:], out: u8[>..]&) -> bool {
    let ok, reason = live_diagnostics_why(db, rel, out);
    return ok;
}

// find_implementations with live: the server's answer at the symbol's
// definition, each location with its line of source.
fn live_implementations(db: i64, pattern: const u8[:], rel: const u8[:], out: u8[>..]&) -> bool {
    var head: u8[>..] = [];
    head.push('{');
    let ids = targets(db, pattern, rel, head);
    if refuse_ambiguous(head) { out.append(head); return true; }
    if ids.len == 0 { out.append(head); out.append(",\"implementations\":[]}"); return true; }
    // Where its name is defined (the map is 0-based; the library takes 1-based).
    let first = if find(ids, ",") >= 0 { ids[..find(ids, ",")] } else { ids[..] };
    let st = prepare_or_die(db, str("SELECT file, start_line, start_col FROM occurrences WHERE symbol_id = ",
                                    first, " AND is_def = 1 ORDER BY start_line LIMIT 1"));
    var file: u8[>..] = [];
    var line = 0;
    var col = 0;
    var err: u8[>..] = [];
    if step_checked(st, err) == 1 { sqlite::col_text(st, 0, file); line = sqlite::col_int(st, 1) + 1; col = sqlite::col_int(st, 2) + 1; }
    sqlite::finalize(st);
    guard file.len > 0 else { out.append("no definition of that symbol in the map"); return false; }
    var q: u8[>..] = [];
    q.append("{\"op\":\"implementations\",\"file\":");
    json::format_string(q, file);
    format(q, ",\"line\":", line, ",\"col\":", col, "}");
    var a: u8[>..] = [];
    guard live_ask(db, file, q, a) else { out.append(a); return false; }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, perr = json::parse(a, doc, decoded);
    guard root else { out.append(perr); return false; }
    out.append(head);
    out.append(",\"live\":true,\"implementations\":[");
    var n = 0;
    let locs = json::member(root, "locations");
    if locs {
        json::each(locs) { loc =>
            let f, f_ok = json::as_string(json::member(loc, "file"));
            let ln, l_ok = json::as_i64(json::member(loc, "line"));
            let cn, c_ok = json::as_i64(json::member(loc, "col"));
            if f_ok && l_ok && c_ok {
                if n > 0 { out.push(','); }
                n++;
                out.append("{\"relative_path\":");
                json::format_string(out, f);
                format(out, ",\"line\":", ln, ",\"column\":", cn, ",\"source\":");
                var text: u8[>..] = [];
                var starts: i64[>..] = [];
                if read_file(source_path(db, f), text) { line_bounds(text, starts); }
                json::format_string(out, if starts.len > 0 { trim(line_of(text, starts, ln - 1)) } else { "" });
                out.push('}');
            }
        };
    }
    out.append("]}");
    return true;
}

// SWAN_WARM=<language> (rust, python, typescript, kotlin) or =auto starts
// that language's server as soon as swan serve has answered initialize, so
// its indexing (or Gradle import) runs while the agent does other things
// and the first live question does not wait for it. auto picks the language
// with the most files in the map. Off by default: a resident server costs
// memory (rust-analyzer and pyright 0.5 to 1 GB, the Kotlin server 1.4 GB).
fn live_warm(db: i64) {
    var want: u8[>..] = [];
    guard env("SWAN_WARM", want) && want.len > 0;
    if want == "auto" {
        want.clear();
        var best = 0;
        // Files per language, by ending: (language, LIKE pattern) pairs.
        let st = prepare_or_die(db, """
            SELECT lang, count(*) AS n FROM (
              SELECT CASE WHEN file LIKE '%.py' THEN 'python' WHEN file LIKE '%.rs' THEN 'rust'
                          WHEN file LIKE '%.kt' THEN 'kotlin'
                          WHEN file LIKE '%.ts' OR file LIKE '%.tsx' OR file LIKE '%.js' THEN 'typescript' END AS lang
              FROM files) WHERE lang IS NOT NULL GROUP BY lang ORDER BY n DESC LIMIT 1
            """);
        var err: u8[>..] = [];
        if step_checked(st, err) == 1 { sqlite::col_text(st, 0, want); best = sqlite::col_int(st, 1); }
        sqlite::finalize(st);
        guard want.len > 0;
    }
    var why: u8[>..] = [];
    let t0 = clock();
    if live_start(db, want, why) {
        // Open one of its files, so it starts loading the project now.
        let pat = match want[0] { 'p' => "%.py", 'r' => "%.rs", 'k' => "%.kt", _ => "%.ts" };
        let st = prepare_or_die(db, "SELECT file FROM files WHERE file LIKE ?1 ORDER BY rows DESC LIMIT 1");
        sqlite::bind_text(st, 1, pat);
        var err: u8[>..] = [];
        var file: u8[>..] = [];
        if step_checked(st, err) == 1 { sqlite::col_text(st, 0, file); }
        sqlite::finalize(st);
        if file.len > 0 {
            var q: u8[>..] = [];
            q.append("{\"op\":\"open\",\"file\":");
            json::format_string(q, file);
            q.push('}');
            var a: u8[>..] = [];
            golsp_ask(q, a);
        }
        write_stderr(str("swan serve: ", want, " server started (warm) in ", ((clock() - t0) * 1000.0) as i64, " ms\n"));
    } else {
        write_stderr(str("swan serve: could not warm ", want, ": ", why, "\n"));
    }
}
