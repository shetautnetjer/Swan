// Live answers from a language server that `swan serve` keeps running
// (rust-analyzer first): diagnostics right after an edit, without a full
// check, and implementations as the server sees them now. The client is the
// swan-lsp library (lsp/swanlsp.goose), compiled to C on its own and linked
// in, so it never adds to swan's own Goose build. Which server, with which
// options, comes from the "lsp" entries in tools/modules.json.

import std;
import os;
import json;

extern fn swan_lsp_start(repo: const u8[:], log: const u8[:], init_json: const u8[:], argv: const u8[:],
                         env: const u8[:], lang_id: const u8[:]) -> bool;
extern fn swan_lsp_ask(question: const u8[:], out: u8[>..]&);
extern fn swan_lsp_stop();

var live_lang: u8[..64];        // the language whose server is running; empty when none

// Starts the server for `lang` unless it is already running; one at a time.
fn live_start(db: i64, lang: const u8[:], why: u8[>..]&) -> bool {
    if live_lang.len > 0 && live_lang == lang { return true; }
    live_stop();
    var root: u8[>..] = [];
    var dir: u8[>..] = [];
    meta_value(db, "root", root);
    meta_value(db, "source", dir);
    guard root.len > 0 && dir.len > 0 else { why.append("the map does not record its repo; rebuild it with swan map"); return false; }
    let home = swan_home();
    var text: u8[>..] = [];
    guard read_file(str(home, "/tools/modules.json"), text) else { why.append("tools/modules.json is missing"); return false; }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let mods, perr = json::parse(text, doc, decoded);
    guard mods else { why.append(str("tools/modules.json: ", perr)); return false; }
    let list = json::member(json::member(mods, lang), "lsp");
    guard list else { format(why, "no live server for ", lang, " in tools/modules.json"); return false; }
    let l = detect(root);
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
                var init: u8[>..] = [];
                let raw, i_ok = json::as_string(json::member(cand, "init"));
                if i_ok { expand(raw, c, init); } else { init.append("{}"); }
                let lid, l_ok = json::as_string(json::member(cand, "language_id"));
                var env_all: u8[>..] = [];
                env_all.append(base);
                env_all.append(extra);
                let log = str(dir, "/lsp-", lang, ".log");
                started = swan_lsp_start(root, log, init, argv, env_all, if l_ok { lid } else { lang });
                if !started { format(why, "the ", lang, " language server did not start; see ", log); }
            }
        }
    };
    if !tried { format(why, "no live server for ", lang, " applies here"); }
    if started { format(live_lang, lang); }
    return started;
}

fn live_stop() {
    guard live_lang.len > 0;
    swan_lsp_stop();
    live_lang.clear();
}

// Asks the running server; the answer is the library's JSON, as is.
fn live_ask(db: i64, rel: const u8[:], question: const u8[:], out: u8[>..]&) -> bool {
    let lang = lang_of_path(rel);
    guard lang.len > 0 else { format(out, "no live server for ", rel); return false; }
    var why: u8[>..] = [];
    guard live_start(db, lang, why) else { out.append(why); return false; }
    var a: u8[>..] = [];
    swan_lsp_ask(question, a);
    if find(a, "\"gone\":true") >= 0 { live_lang.clear(); }   // the next question starts it again
    out.append(a);
    return starts_with(a, "{\"ok\":true");
}

// get_diagnostics with live: what the server reports for one file now.
fn live_diagnostics(db: i64, rel: const u8[:], out: u8[>..]&) -> bool {
    guard rel.len > 0 else { out.append("live diagnostics need relative_path (one file)"); return false; }
    var q: u8[>..] = [];
    q.append("{\"op\":\"diagnostics\",\"file\":");
    json::format_string(q, rel);
    q.push('}');
    return live_ask(db, rel, q, out);
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
    if swan_step(st, err) == 1 { swan_col_text(st, 0, file); line = swan_col_int(st, 1) + 1; col = swan_col_int(st, 2) + 1; }
    swan_finalize(st);
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
