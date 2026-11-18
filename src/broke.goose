// "What broke since my last edit": for the files just written, the errors
// the language server reports now that it did not report the last time
// this was asked. Made to run after every edit (the `what_broke` tool, or
// `swan broke` from an agent's post-edit hook), so an agent hears about a
// break when it makes it and is not told again about errors that were
// already there.
//
// What was seen last time is kept beside the map in broke-seen.tsv, one
// "file<TAB>severity|code|message" per line. Lines move as code is edited,
// so an error is the same one when its file, code and message are.

import std;
import os;
import json;
import .query;
import .live;

fn broke_key(d: json::Node?, out: u8[>..]&) {
    let sev, s_ok = json::as_string(json::member(d, "severity"));
    let code, c_ok = json::as_string(json::member(d, "code"));
    let msg, m_ok = json::as_string(json::member(d, "message"));
    if s_ok { out.append(sev); }
    out.push('|');
    if c_ok { out.append(code); }
    out.push('|');
    if m_ok { for ch in msg { out.push(if ch == '\n' || ch == '\t' { ' ' } else { ch }); } }
}

// `dir`: the map's folder. `files`: paths relative to the repo, one per line. Appends a JSON object
// to out; returns the number of new errors, or -1 if nothing could be asked.
fn what_broke(db: i64, dir: const u8[:], files: const u8[:], out: u8[>..]&) -> i64 {
    let seen_path = str(dir, "/broke-seen.tsv");
    var seen: u8[>..] = [];
    read_file(seen_path, seen);
    var keep: u8[>..] = [];          // the seen lines of files not asked about now
    var now: u8[>..] = [];           // what the asked files show now
    var asked_names: u8[>..] = [];
    var body: u8[>..] = [];
    var new_errors: i64 = 0;
    var asked = 0;
    each_split(files, '\n') { rel =>
        guard rel.len > 0;
        var a: u8[>..] = [];
        let ok = live_diagnostics(db, rel, a);
        if body.len > 0 { body.push(','); }
        body.append("{\"relative_path\":");
        json::format_string(body, rel);
        var doc: json::Node[>..] = [];
        var dec: u8[>..] = [];
        let r, perr = json::parse(a, doc, dec);
        let ds = json::member(r, "diagnostics");
        if !ok || !ds {
            body.append(",\"asked\":false,\"why\":");
            json::format_string(body, a);
            body.push('}');
        } else {
            asked++;
            format(asked_names, rel, "\n");
            // Was this file looked at before? (A file with no errors is
            // remembered by one line with an empty key.)
            var known = false;
            let prefix = str(rel, "\t");
            each_split(seen, '\n') { l => if starts_with(l, prefix) { known = true; } };
            var news: u8[>..] = [];
            var n_new = 0;
            var n_still = 0;
            var n_warn = 0;
            format(now, rel, "\t\n");
            json::each(ds) { d =>
                let sev, s_ok = json::as_string(json::member(d, "severity"));
                if s_ok && sev == "error" {
                    var key: u8[>..] = [];
                    broke_key(d, key);
                    let line = str(rel, "\t", key);
                    var was = false;
                    each_split(seen, '\n') { l => if l == line { was = true; } };
                    format(now, line, "\n");
                    if was { n_still++; }
                    else {
                        n_new++;
                        if news.len > 0 { news.push(','); }
                        news.push('{');
                        let ln, l_ok = json::as_i64(json::member(d, "line"));
                        let cl, c_ok = json::as_i64(json::member(d, "col"));
                        let msg, m_ok = json::as_string(json::member(d, "message"));
                        let code, k_ok = json::as_string(json::member(d, "code"));
                        format(news, "\"line\":", if l_ok { ln } else { 0 }, ",\"col\":", if c_ok { cl } else { 0 }, ",\"message\":");
                        json::format_string(news, if m_ok { msg } else { "" });
                        if k_ok && code.len > 0 { news.append(",\"code\":"); json::format_string(news, code); }
                        news.push('}');
                    }
                } else { n_warn++; }
            };
            new_errors += n_new;
            format(body, ",\"asked\":true,\"first_look\":", if known { "false" } else { "true" }, ",\"new_errors\":[", news,
                   "],\"errors_already_there\":", n_still, ",\"warnings\":", n_warn, "}");
        }
    };
    // Remember: asked files get what they show now; the rest stay as they were.
    each_split(seen, '\n') { l =>
        guard l.len > 0;
        let tab = find(l, "\t");
        var mine = false;
        if tab > 0 { each_split(asked_names, '\n') { n => if n == l[..tab] { mine = true; } }; }
        if !mine { format(keep, l, "\n"); }
    };
    keep.append(now);
    if asked > 0 { write_file_atomic(seen_path, keep); }
    format(out, "{\"new_errors\":", new_errors, ",\"files\":[", body, "],\"note\":\"new_errors are errors the language server reports now and did not when this was last asked for the file; on a first look every error counts as new\"}");
    return if asked > 0 { new_errors } else { -1 };
}
