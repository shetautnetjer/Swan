// Structural search and rewrite, ast-grep style: `$X.unwrap()` finds every
// call of unwrap on anything, by the syntax tree rather than by text, in
// every language Swan bundles a tree-sitter grammar for. Each match is tied
// to the symbol it sits in, from the map. A rewrite is planned first and
// applied only on request, refused when a file changed since the map, and
// written atomically, as the other edits are.

import std;
import os;
import json;
import treesitter;
import sqlite;

let STRUCT_LANGS = ["typescript", "tsx", "javascript", "python", "rust", "java", "c", "cpp", "cuda", "kotlin",
                    "lua", "glsl", "hlsl", "wgsl", "gdscript", "csharp", "php"];

// The repo's files under rel with a grammar (of `lang`, if given), relative
// to the repo, one per line.
fn structural_files(root: const u8[:], rel: const u8[:], lang: const u8[:]) -> u8[>..] {
    var files: u8[>..] = [];
    let base = if rel.len > 0 { str(root, "/", rel) } else { str(root) };
    fn take(full: const u8[:]) {
        let l = treesitter::language_of_path(full);
        if l.len > 0 && (lang.len == 0 || l == lang) {
            files.append(full[root.len + 1..]);
            files.push('\n');
        }
    }
    if file_exists(base) { take(base); }
    else { each_file(base) { full, name => take(full); }; }
    return files;
}

fn first_line(s: const u8[:]) -> const u8[:] {
    let nl = find(s, "\n");
    let one = if nl >= 0 { s[..nl] } else { s };
    return if one.len > 200 { one[..200] } else { one };
}

// Runs the pattern over the files, a language at a time (it is parsed once
// per language), calling F(file, text, node) for each match; inside F the
// treesitter::match_* functions describe it. Languages the pattern does not
// parse in are listed in `skipped`.
fn each_structural_match<F>(db: i64, pattern: const u8[:], lang: const u8[:], rel: const u8[:],
                            skipped: u8[>..]&, searched: i64&) -> bool {
    var root: u8[>..] = [];
    meta_value(db, "root", root);
    guard root.len > 0 else { return false; }
    if root[root.len - 1] == '/' { root.pop(); }
    let files = structural_files(root, rel, lang);
    for k in 0..STRUCT_LANGS.len {
        var l: u8[..32] = [];       // a copy: compiling the pattern must not move what it names
        format(l, STRUCT_LANGS[k]);
        var mine: u8[>..] = [];
        each_split(files, '\n') { f => if f.len > 0 && treesitter::language_of_path(f) == l { mine.append(f); mine.push('\n'); } };
        if mine.len > 0 {
            var why: u8[>..] = [];
            if !treesitter::compile(l, pattern, why) {
                if skipped.len > 0 { skipped.push(','); }
                skipped.append("{\"language\":");
                json::format_string(skipped, l);
                skipped.append(",\"why\":");
                json::format_string(skipped, why);
                skipped.push('}');
            } else {
                // Files without the pattern's words are dropped unread by
                // the parser; the rest are parsed in batches on all cores.
                var batch: u8[>..] = [];        // relative paths, one per line
                var paths: u8[>..] = [];        // the same, absolute, NUL-separated
                var nbatch = 0;
                fn run_batch() {
                    guard nbatch > 0;
                    var handles: i64[>..] = [];
                    treesitter::parse_files(l, paths, handles);
                    var k = 0;
                    each_split(batch, '\n') { f =>
                        if f.len > 0 {
                            var text: u8[>..] = [];
                            let h = handles[k];
                            k++;
                            if read_file(str(root, "/", f), text) { treesitter::search_tree(h, text) { node => F(f, text[..], node); }; }
                            else { treesitter::search_tree(h, "") { node => {}; }; }
                        }
                    };
                    batch.clear();
                    paths.clear();
                    nbatch = 0;
                }
                each_split(mine, '\n') { f =>
                    if f.len > 0 {
                        var text: u8[>..] = [];
                        if read_file(str(root, "/", f), text) {
                            searched++;
                            if treesitter::might_match(text) {
                                format(batch, f, "\n");
                                format(paths, root, "/", f);
                                paths.push(0);
                                nbatch++;
                                if nbatch == 256 { run_batch(); }
                            }
                        }
                    }
                };
                run_batch();
            }
        }
    }
    return true;
}

fn search_pattern(db: i64, pattern: const u8[:], lang: const u8[:], rel: const u8[:], limit: i64, out: u8[>..]&) -> bool {
    guard pattern.len > 0 else { out.append("pattern is required"); return false; }
    var root: u8[>..] = [];
    meta_value(db, "root", root);
    guard root.len > 0 else { out.append("the map does not record its repo; rebuild it with swan map"); return false; }
    if root[root.len - 1] == '/' { root.pop(); }
    let files = structural_files(root, rel, lang);
    var skipped: u8[>..] = [];
    var searched = 0;
    var n = 0;
    var body: u8[>..] = [];
    for li in 0..STRUCT_LANGS.len {
        var l: u8[..32] = [];
        format(l, STRUCT_LANGS[li]);
        var mine: u8[>..] = [];     // relative, one per line
        var paths: u8[>..] = [];    // absolute, one per line
        var count = 0;
        each_split(files, '\n') { f =>
            if f.len > 0 && treesitter::language_of_path(f) == l { format(mine, f, "\n"); format(paths, root, "/", f, "\n"); count++; }
        };
        if count > 0 {
            var why: u8[>..] = [];
            if !treesitter::compile(l, pattern, why) {
                if skipped.len > 0 { skipped.push(','); }
                skipped.append("{\"language\":");
                json::format_string(skipped, l);
                skipped.append(",\"why\":");
                json::format_string(skipped, why);
                skipped.push('}');
            } else {
                searched += count;
                let rels = split(mine, '\n');
                var text: u8[>..] = [];
                var text_of: i64 = -1;
                // Per file, once: its text, whether it is stale, and its
                // symbols' bodies, to name the symbol each match sits in.
                var stale_file = false;
                var spans: i64[>..] = [];       // body_start, body_end, offset of its name in names
                var names: u8[>..] = [];
                treesitter::search_files(paths) { idx, s0, e0, r, c, cap =>
                    let f = rels[idx];
                    if text_of != idx {
                        text.clear(); read_file(str(root, "/", f), text); text_of = idx;
                        stale_file = is_stale(f);
                        spans.clear(); names.clear();
                        let st = prepare_or_die(db, "SELECT body_start, body_end, name_path FROM symbols WHERE def_file = ?1 AND body_start IS NOT NULL");
                        sqlite::bind_text(st, 1, f);
                        var err: u8[>..] = [];
                        while sqlite::step(st, err) == 1 {
                            spans.push(sqlite::col_int(st, 0)); spans.push(sqlite::col_int(st, 1)); spans.push(names.len);
                            sqlite::col_text(st, 2, names);
                            names.push('\n');
                        }
                        sqlite::finalize(st);
                    }
                    {
                        n++;
                        if n <= limit && e0 <= text.len {
                            let mt = text[s0..e0];
                            if n > 1 { body.push(','); }
                            body.append("{\"relative_path\":");
                            json::format_string(body, f);
                            format(body, ",\"line\":", r + 1, ",\"column\":", c + 1,
                                   ",\"end_line\":", r + count_newlines(mt) + 1, ",\"text\":");
                            json::format_string(body, first_line(mt));
                            body.append(",\"captures\":{");
                            var m = 0;
                            each_split(cap, 0x1e) { one =>
                                let sep = find(one, "\x1f");
                                if sep >= 0 {
                                    if m > 0 { body.push(','); }
                                    m++;
                                    json::format_string(body, one[..sep]);
                                    body.push(':');
                                    json::format_string(body, first_line(one[sep + 1..]));
                                }
                            };
                            body.push('}');
                            // The innermost body holding the line (on a tie, the later start).
                            var best: i64 = -1;
                            var k = 0;
                            while k + 3 <= spans.len {
                                if spans[k] <= r && spans[k + 1] >= r &&
                                   (best < 0 || spans[k + 1] - spans[k] < spans[best + 1] - spans[best] ||
                                    (spans[k + 1] - spans[k] == spans[best + 1] - spans[best] && spans[k] > spans[best])) { best = k; }
                                k += 3;
                            }
                            if best >= 0 {
                                let at = spans[best + 2];
                                let nl = at + find(names[at..], "\n");
                                body.append(",\"in_symbol\":");
                                json::format_string(body, names[at..nl]);
                            }
                            if stale_file { body.append(",\"stale\":true"); }
                            body.push('}');
                        }
                    }
                };
            }
        }
    }
    out.append("{\"pattern\":");
    json::format_string(out, pattern);
    format(out, ",\"matches\":[", body, "],\"count\":", n, ",\"files_searched\":", searched);
    if n > limit { out.append(",\"truncated\":true"); }
    if skipped.len > 0 { format(out, ",\"pattern_does_not_parse_in\":[", skipped, "]"); }
    out.push('}');
    return true;
}

struct Cut { start: i64, end: i64 }

fn rewrite_pattern(db: i64, pattern: const u8[:], rewrite: const u8[:], lang: const u8[:], rel: const u8[:],
                   apply: bool, out: u8[>..]&) -> bool {
    guard pattern.len > 0 else { out.append("pattern is required"); return false; }
    var skipped: u8[>..] = [];
    var searched = 0;
    var plan: u8[>..] = [];         // the edits, as JSON
    var n = 0;
    var stale: u8[>..] = [];
    var nstale = 0;
    var last_end = 0;               // a match inside the one before is not an edit of its own
    // Per file: the replacement texts, one after another, and their cuts.
    var cur: u8[>..] = [];
    var cur_text: u8[>..] = [];
    var cuts: Cut[>..] = [];
    var repl: u8[>..] = [];
    var repl_at: i64[>..] = [];
    var files_written = 0;
    var write_failed: u8[>..] = [];
    var root: u8[>..] = [];
    meta_value(db, "root", root);
    if root.len > 0 && root[root.len - 1] == '/' { root.pop(); }
    fn flush() {
        guard cur.len > 0 && cuts.len > 0;
        if apply && nstale == 0 {
            var updated: u8[>..] = [];
            var at = 0;
            for c, k in cuts {
                updated.append(cur_text[at..c.start]);
                let a = repl_at[k];
                let b = if k + 1 < repl_at.len { repl_at[k + 1] } else { repl.len };
                updated.append(repl[a..b]);
                at = c.end;
            }
            updated.append(cur_text[at..]);
            let path = str(root, "/", cur);
            if write_file_atomic(path, updated) {
                // The map follows each cut, the last first, so the cuts
                // before it keep the positions they were found at.
                var k = cuts.len;
                while k > 0 {
                    k--;
                    let c = cuts[k];
                    let a = repl_at[k];
                    let b = if k + 1 < repl_at.len { repl_at[k + 1] } else { repl.len };
                    let sl = count_newlines(cur_text[..c.start]);
                    let sc = col_of(cur_text, c.start);
                    let nel, nec = end_of(sl, sc, repl[a..b]);
                    shift_span(db, cur, sl, sc, count_newlines(cur_text[..c.end]), col_of(cur_text, c.end), nel, nec, -1);
                }
                mark_edited(db, cur, path);
                files_written++;
            }
            else { if write_failed.len > 0 { write_failed.push(','); } json::format_string(write_failed, cur); }
        }
        cuts.clear();
        repl.clear();
        repl_at.clear();
    }
    // First pass: plan, and find stale files, which block applying.
    let ok = each_structural_match(db, pattern, lang, rel, skipped, searched) { f, text, node =>
        if f != cur {
            if is_stale(f) { if nstale > 0 { stale.push(','); } nstale++; json::format_string(stale, f); }
            cur.clear();
            cur.append(f);
            last_end = 0;
        }
        guard treesitter::match_start(node) >= last_end;
        last_end = treesitter::match_end(node);
        n++;
        var after: u8[>..] = [];
        treesitter::fill_template(rewrite, after);
        if n > 1 { plan.push(','); }
        plan.append("{\"relative_path\":");
        json::format_string(plan, f);
        format(plan, ",\"line\":", treesitter::match_row(node) + 1, ",\"column\":", treesitter::match_col(node) + 1, ",\"before\":");
        json::format_string(plan, treesitter::match_text(node));
        plan.append(",\"after\":");
        json::format_string(plan, after);
        plan.push('}');
    };
    guard ok else { out.append("the map does not record its repo; rebuild it with swan map"); return false; }
    out.append("{\"pattern\":");
    json::format_string(out, pattern);
    out.append(",\"rewrite\":");
    json::format_string(out, rewrite);
    format(out, ",\"edits\":[", plan, "],\"count\":", n, ",\"files_searched\":", searched, ",\"stale_files\":[", stale, "]");
    if skipped.len > 0 { format(out, ",\"pattern_does_not_parse_in\":[", skipped, "]"); }
    if !apply || n == 0 { out.append(",\"applied\":false}"); return true; }
    if nstale > 0 {
        out.append(",\"applied\":false,\"refused\":\"some files changed since the map was built; refresh first.\"}");
        return false;
    }
    // Second pass: rewrite each file, outermost matches only (a match inside
    // one already rewritten is left alone).
    cur.clear();
    each_structural_match(db, pattern, lang, rel, skipped, searched) { f, text, node =>
        if f != cur {
            flush();
            cur.clear();
            cur.append(f);
            cur_text.clear();
            cur_text.append(text);
        }
        let s = treesitter::match_start(node);
        guard cuts.len == 0 || s >= cuts[cuts.len - 1].end;
        cuts.push(Cut { start: s, end: treesitter::match_end(node) });
        repl_at.push(repl.len);
        treesitter::fill_template(rewrite, repl);
    };
    flush();
    format(out, ",\"applied\":true,\"files_written\":", files_written);
    if write_failed.len > 0 { format(out, ",\"write_failed\":[", write_failed, "]"); }
    out.append(",\"note\":\"rewritten files are stale in the map until update_map\"}");
    return write_failed.len == 0;
}
