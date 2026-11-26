// "What broke since my last edit": for the files just written, the errors
// the language server reports now that it did not report the last time
// this was asked. Made to run after every edit (the `what_broke` tool, or
// `swan broke` from an agent's post-edit hook), so an agent hears about a
// break when it makes it and is not told again about errors that were
// already there.
//
// What was seen last time is kept beside the map in broke-seen.tsv, one
// "file<TAB>severity|code|message" per line. Lines move as code is edited,
// so an error is the same one when its file, code and message are. A file
// not asked (other than no_server) also keeps one "file<TAB>not-asked|reason|"
// line until it is asked again, so hooks report it once per reason.

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
// to out; returns (new_errors, asked, not_asked).
fn what_broke(db: i64, dir: const u8[:], files: const u8[:], out: u8[>..]&) -> i64, i64, i64 {
    let seen_path = str(dir, "/broke-seen.tsv");
    var seen: u8[>..] = [];
    read_file(seen_path, seen);
    var keep: u8[>..] = [];          // the seen lines of files not asked about now
    var now: u8[>..] = [];           // what the asked files show now
    var asked_names: u8[>..] = [];
    var not_asked_names: u8[>..] = [];
    var not_asked_lines: u8[>..] = [];
    var body: u8[>..] = [];
    var new_errors: i64 = 0;
    var asked: i64 = 0;
    var not_asked: i64 = 0;
    each_split(files, '\n') { rel =>
        guard rel.len > 0;
        var a: u8[>..] = [];
        let ok, why_class = live_diagnostics_why(db, rel, a);
        if body.len > 0 { body.push(','); }
        body.append("{\"relative_path\":");
        json::format_string(body, rel);
        var doc: json::Node[>..] = [];
        var dec: u8[>..] = [];
        let r, perr = json::parse(a, doc, dec);
        let settled_v, settled_ok = json::as_bool(json::member(r, "settled"));
        let unsettled = settled_ok && !settled_v;
        let ds = json::member(r, "diagnostics");
        if !ok || !ds || unsettled {
            not_asked++;
            // An answer with "settled":false is treated as not asked: its
            // diagnostics are neither compared nor remembered.
            let reason = if unsettled { "unsettled" } else if !ok && why_class.len > 0 { why_class } else { "failed" };
            body.append(",\"asked\":false,\"reason\":");
            json::format_string(body, reason);
            if reason != "no_server" {
                let prefix = str(rel, "\tnot-asked|");
                let line = str(prefix, reason, "|");
                var was = false;
                each_split(seen, '\n') { l => if l == line { was = true; } };
                each_split(not_asked_lines, '\n') { l => if l == line { was = true; } };
                if !was {
                    var next_na: u8[>..] = [];
                    var replaced = false;
                    each_split(not_asked_lines, '\n') { l =>
                        guard l.len > 0;
                        if starts_with(l, prefix) {
                            if !replaced { format(next_na, line, "\n"); replaced = true; }
                        } else {
                            format(next_na, l, "\n");
                        }
                    };
                    if !replaced { format(next_na, line, "\n"); format(not_asked_names, rel, "\n"); }
                    not_asked_lines.clear();
                    not_asked_lines.append(next_na);
                }
                format(body, ",\"first_time\":", if was { "false" } else { "true" });
            }
            // The library refuses in JSON: its "error" is the reason. An
            // answer that only ran out of time has none.
            body.append(",\"why\":");
            let said, said_ok = json::as_string(json::member(r, "error"));
            if said_ok && said.len > 0 { json::format_string(body, said); }
            else if unsettled { json::format_string(body, "the language server did not settle in time"); }
            else { json::format_string(body, a); }
            body.push('}');
        } else {
            asked++;
            format(asked_names, rel, "\n");
            // Was this file looked at before? (A file with no errors is
            // remembered by one line with an empty key; a not-asked marker
            // does not count as a look.)
            var known = false;
            let prefix = str(rel, "\t");
            let na_prefix = str(rel, "\tnot-asked|");
            each_split(seen, '\n') { l => if starts_with(l, prefix) && !starts_with(l, na_prefix) { known = true; } };
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
    // Remember: asked files get what they show now; not-asked files (other
    // than no_server) keep their error lines and replace only their earlier
    // not-asked line; the rest stay as they were.
    each_split(seen, '\n') { l =>
        guard l.len > 0;
        let tab = find(l, "\t");
        var drop = false;
        if tab > 0 {
            let f = l[..tab];
            each_split(asked_names, '\n') { n => if n == f { drop = true; } };
            if !drop && starts_with(l[tab + 1..], "not-asked|") {
                each_split(not_asked_names, '\n') { n => if n == f { drop = true; } };
            }
        }
        if !drop { format(keep, l, "\n"); }
    };
    keep.append(now);
    each_split(not_asked_lines, '\n') { l =>
        guard l.len > 0;
        let tab = find(l, "\t");
        var asked_too = false;
        if tab > 0 { each_split(asked_names, '\n') { n => if n == l[..tab] { asked_too = true; } }; }
        if !asked_too { format(keep, l, "\n"); }
    };
    if keep != seen { write_file_atomic(seen_path, keep); }
    format(out, "{\"new_errors\":", new_errors, ",\"files\":[", body, "],\"note\":\"new_errors are errors the language server reports now and did not when this was last asked for the file; on a first look every error counts as new; when asked is false (except no_server), first_time is true the first time the file was not asked for that reason, and false until the reason changes or the file is asked again\"}");
    return new_errors, asked, not_asked;
}
