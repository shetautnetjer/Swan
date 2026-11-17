// A syntax-level index for the languages no SCIP indexer covers here: Go,
// shell (bash, zsh, sh, and scripts named only by their #! line), Makefiles,
// Ruby and Lua. It writes a real SCIP file, so the flattener and `swan index`
// take it like any other, and a repo in these languages gets a map instead of
// "no language found".
//
// It reads source text only and runs nothing from the repo. Definitions come
// from line patterns, bodies from brace matching (Go, shell) or `end` at the
// same indentation (Ruby, Lua) or tab-indented recipe lines (Make).
// References are found by name: an identifier equal to a defined name, the
// nearest definition winning (same file, then same folder, then the only one
// in the repo). The flattener marks them "name" (found by name, not resolved
// by a compiler), and answers show them as by_name.
//
//   swan syntax-index <repo> <out.scip>
//
// This replaces tools/syntax-index.ts (Bun) line for line, with three
// deliberate differences: columns are UTF-8 bytes (the encoding the index
// declares) rather than UTF-16 units; a Go receiver written without a name,
// `func (T) M()`, names T (the regex took its last letter); and a
// definition's column is where its name is, where the TypeScript's
// `indexOf` could find the same letters earlier in the line.

import std;
import os;
import .pipeline;

let SX_GO: i64 = 0;
let SX_SHELL: i64 = 1;
let SX_MAKE: i64 = 2;
let SX_RUBY: i64 = 3;
let SX_LUA: i64 = 4;

let SX_FUNCTION: i64 = 17;
let SX_METHOD: i64 = 26;
let SX_CLASS: i64 = 7;
let SX_MODULE: i64 = 29;
let SX_STRUCT: i64 = 49;
let SX_INTERFACE: i64 = 21;
let SX_TYPE: i64 = 54;
let SX_VARIABLE: i64 = 61;
let SX_CONSTANT: i64 = 8;

let SX_SKIP = ["node_modules", ".git", "target", ".venv", "venv", "__pycache__", ".tox", ".mypy_cache",
               ".pytest_cache", ".swan", "build", ".gradle", "obj", "vendor", "dist"];

fn sx_lang_name(l: i64) -> const u8[:] {
    if l == SX_GO { return "go"; }
    if l == SX_SHELL { return "shell"; }
    if l == SX_MAKE { return "make"; }
    if l == SX_RUBY { return "ruby"; }
    return "lua";
}

fn sx_w(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' }
fn sx_alpha(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
fn sx_sp(c: u8) -> bool { c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 11 || c == 12 }

fn sx_skip_sp(s: const u8[:], i: i64) -> i64 {
    var k = i;
    while k < s.len && sx_sp(s[k]) { k++; }
    return k;
}
fn sx_word_end(s: const u8[:], i: i64) -> i64 {
    var k = i;
    while k < s.len && sx_w(s[k]) { k++; }
    return k;
}

// Whether some maximal run of word characters on the #! line equals w
// (the TypeScript's \bw\b on the first line).
fn sx_shebang_word(head: const u8[:], w: const u8[:]) -> bool {
    var i = 0;
    while i < head.len && head[i] != '\n' {
        if sx_w(head[i]) {
            let e = sx_word_end(head, i);
            if head[i..e] == w { return true; }
            i = e;
        } else { i++; }
    }
    return false;
}

// The language of a file, or -1.
fn sx_lang_of(full: const u8[:], name: const u8[:]) -> i64 {
    if ends_with(name, ".go") { return SX_GO; }
    for e in [".sh", ".bash", ".zsh", ".ksh"] { if ends_with(name, e) { return SX_SHELL; } }
    if name == "GNUmakefile" || name == "makefile" || name == "Makefile" || ends_with(name, ".mk") { return SX_MAKE; }
    if ends_with(name, ".rb") || name == "Rakefile" { return SX_RUBY; }
    if ends_with(name, ".lua") { return SX_LUA; }
    if find(name, ".") >= 0 { return -1; }
    var text: u8[>..] = [];
    guard read_file(full, text) else { return -1; }
    let head = text[..min(text.len, 128)];
    guard starts_with(head, "#!") else { return -1; }
    for w in ["sh", "bash", "zsh", "ksh", "dash"] { if sx_shebang_word(head, w) { return SX_SHELL; } }
    if sx_shebang_word(head, "ruby") { return SX_RUBY; }
    return -1;
}

// Depth-first in sorted order (list_dir sorts bytewise), as the TypeScript
// walked: appends "<lang>\t<relative path>\n" for every file to index. An
// explicit stack: a folder's children go on in reverse, so the first sorted
// name comes off next and a subfolder is finished before its next sibling.
fn sx_walk(repo: const u8[:], out: u8[>..]&) {
    var text: u8[>..] = [];        // every path pushed; entries never move
    var off: i64[>..] = [];
    var len: i64[>..] = [];
    var top = 0;                   // entries in use
    var names: u8[>..] = [];
    var starts: i64[>..] = [];
    var full: u8[>..] = [];
    var dir: u8[>..] = [];
    dir.append(repo);
    var have_dir = true;
    while true {
        if have_dir {
            names.clear();
            starts.clear();
            if list_dir(dir, names) {
                var s = 0;
                for c, i in names { if c == '\n' { if i > s { starts.push(s); } s = i + 1; } }
                var k = starts.len - 1;
                while k >= 0 {
                    let st = starts[k];
                    let e = st + find(names[st..], "\n");
                    let o = text.len;
                    format(text, dir, "/", names[st..e]);
                    if top < off.len { off[top] = o; len[top] = text.len - o; } else { off.push(o); len.push(text.len - o); }
                    top++;
                    k--;
                }
            }
            have_dir = false;
        }
        if top == 0 { break; }
        top--;
        full.clear();
        full.append(text[off[top]..off[top] + len[top]]);
        let n = full[rfind(full, "/") + 1..];
        if swan_is_symlink(full) { continue; }
        if is_dir(full) {
            if !contains(SX_SKIP, n) { dir.clear(); dir.append(full); have_dir = true; }
        } else {
            let size = swan_file_size(full);
            if size >= 0 && size <= 1000000 {
                let l = sx_lang_of(full, n);
                if l >= 0 { format(out, l, "\t", full[repo.len + 1..], "\n"); }
            }
        }
    }
}

// A SCIP descriptor name: as is when it is all [\w$+-], else in backticks.
fn sx_ident(s: const u8[:], out: u8[>..]&) {
    var plain = s.len > 0;
    for c in s { if !(sx_w(c) || c == '$' || c == '+' || c == '-') { plain = false; } }
    if plain { out.append(s); return; }
    out.push('`');
    for c in s { if c == '`' { out.push('`'); } out.push(c); }
    out.push('`');
}

fn sx_dirname(rel: const u8[:]) -> const u8[:] {
    let s = rfind(rel, "/");
    return if s < 0 { "." } else { rel[..s] };
}
fn sx_basename(p: const u8[:]) -> const u8[:] {
    var e = p.len;
    while e > 1 && p[e - 1] == '/' { e--; }
    let s = rfind(p[..e], "/");
    return p[s + 1..e];
}

// "a/b/" for folder a/b, "" for the repo's root.
fn sx_ns(dir: const u8[:], out: u8[>..]&) {
    guard dir.len > 0 && dir != ".";
    each_split(dir, '/') { seg => sx_ident(seg, out); out.push('/'); };
}

// The line with comments and string contents blanked (same length up to a
// comment, which ends it), as the TypeScript's codeOnly.
fn sx_code(line: const u8[:], lang: i64, out: u8[>..]&) {
    out.clear();
    var q: u8 = 0;
    var i = 0;
    while i < line.len {
        let c = line[i];
        if q != 0 {
            out.push(if c == q { c } else { ' ' });
            if c == '\\' && q != '`' { out.push(' '); i++; }
            if c == q { q = 0; }
            i++;
            continue;
        }
        if lang == SX_GO && c == '/' && i + 1 < line.len && line[i + 1] == '/' { break; }
        if lang == SX_LUA && c == '-' && i + 1 < line.len && line[i + 1] == '-' { break; }
        if (lang == SX_SHELL || lang == SX_MAKE || lang == SX_RUBY) && c == '#' && (i == 0 || sx_sp(line[i - 1])) { break; }
        if lang == SX_GO && (c == '"' || c == '`' || c == '\'') { q = c; out.push(c); i++; continue; }
        out.push(c);
        i++;
    }
}

// Shell references skip a comment: from the first # at the start or after
// a space (the TypeScript's raw.replace(/(^|\s)#.*$/, "$1")).
fn sx_shell_code(line: const u8[:], out: u8[>..]&) {
    out.clear();
    for c, i in line {
        if c == '#' && (i == 0 || sx_sp(line[i - 1])) { break; }
        out.push(c);
    }
}

// Protocol buffer encoding, as much of it as a SCIP index needs.
fn pb_varint(out: u8[>..]&, n: i64) {
    var v = n as! u64;
    while v > 127 { out.push(((v & 127) | 128) as! u8); v = v >> 7; }
    out.push(v as! u8);
}
fn pb_key(out: u8[>..]&, f: i64, wt: i64) { pb_varint(out, f * 8 + wt); }
fn pb_bytes(out: u8[>..]&, f: i64, v: const u8[:]) { pb_key(out, f, 2); pb_varint(out, v.len); out.append(v); }
fn pb_int(out: u8[>..]&, f: i64, n: i64) { pb_key(out, f, 0); pb_varint(out, n); }
// A packed repeated int32 field: [l, c, ec] on one line, [l, c, el, ec] across.
fn pb_range(out: u8[>..]&, f: i64, l: i64, c: i64, el: i64, ec: i64) {
    var w: u8[>..] = [];
    pb_varint(w, l);
    pb_varint(w, c);
    if el != l { pb_varint(w, el); }
    pb_varint(w, ec);
    pb_bytes(out, f, w);
}

// At most n bytes of s, not cutting a UTF-8 character.
fn sx_cut(s: const u8[:], n: i64) -> const u8[:] {
    guard s.len > n else { return s; }
    var e = n;
    while e > 0 && (s[e] & 192) == 128 { e--; }
    return s[..e];
}

fn syntax_index_main(repo_arg: const u8[:], out_path: const u8[:]) -> bool {
    var repo: u8[>..] = [];
    repo.append(repo_arg);
    var rend = repo_arg.len;
    while rend > 1 && repo_arg[rend - 1] == '/' { rend--; }
    repo.clear();
    repo.append(repo_arg[..rend]);
    var listing: u8[>..] = [];
    sx_walk(repo, listing);

    // Files: their paths, languages and text, in walk order.
    var paths: u8[>..] = [];
    var p_off: i64[>..] = [];
    var p_len: i64[>..] = [];
    var f_lang: i64[>..] = [];
    var texts: u8[>..] = [];
    var t_off: i64[>..] = [];
    var t_len: i64[>..] = [];
    var f_dir: i64[>..] = [];         // folder id, for "same folder"
    var dir_ids = dictionary<u64, i64> {};
    var n_dirs = 0;
    each_split(listing, '\n') { line =>
        guard line.len > 2;
        let rel = line[2..];
        var full: u8[>..] = [];
        format(full, repo, "/", rel);
        var text: u8[>..] = [];
        guard read_file(full, text);
        p_off.push(paths.len);
        p_len.push(rel.len);
        paths.append(rel);
        f_lang.push((line[0] - '0') as i64);
        t_off.push(texts.len);
        t_len.push(text.len);
        texts.append(text);
        let dh = hash(sx_dirname(rel));
        let known = dir_ids.get(dh);
        if known { let id: i64 = known; f_dir.push(id); }
        else { dir_ids.insert(dh, n_dirs); f_dir.push(n_dirs); n_dirs++; }
    };
    let nfiles = p_off.len;

    var pkg: u8[>..] = [];
    pkg.append("swan-syntax . ");
    var rn: u8[>..] = [];
    sx_ident(sx_basename(repo), rn);
    for c in rn { pkg.push(if c == ' ' { '_' } else { c }); }
    pkg.append(" 0 ");

    // Definitions, as parallel arrays; strings in shared buffers.
    var names: u8[>..] = [];
    var syms: u8[>..] = [];
    var sigs: u8[>..] = [];
    var d_noff: i64[>..] = []; var d_nlen: i64[>..] = [];
    var d_soff: i64[>..] = []; var d_slen: i64[>..] = [];
    var d_goff: i64[>..] = []; var d_glen: i64[>..] = [];
    var d_kind: i64[>..] = [];
    var d_line: i64[>..] = []; var d_col: i64[>..] = [];
    var d_end: i64[>..] = []; var d_endcol: i64[>..] = [];
    var d_file: i64[>..] = [];
    var d_method: i64[>..] = [];
    var f_first: i64[>..] = [];       // each file's definitions are one run
    var by_head = dictionary<u64, i64> {};
    var by_tail = dictionary<u64, i64> {};
    var d_next: i64[>..] = [];

    var starts: i64[>..] = [];       // line starts of the current file
    var lines_of = 0;
    var cur_t = 0;
    fn load_lines(fi: i64) {
        starts.clear();
        cur_t = fi;
        let t = texts[t_off[fi]..t_off[fi] + t_len[fi]];
        starts.push(0);
        for c, i in t { if c == '\n' { starts.push(i + 1); } }
        lines_of = starts.len;
    }
    // Line l of the current file, without its newline or a \r before it.
    fn line_at(l: i64) -> const u8[:] {
        let t = texts[t_off[cur_t]..t_off[cur_t] + t_len[cur_t]];
        let s = starts[l];
        var e = if l + 1 < lines_of { starts[l + 1] - 1 } else { t.len };
        if e > s && t[e - 1] == '\r' { e--; }
        return t[s..e];
    }

    var code: u8[>..] = [];
    var code2: u8[>..] = [];
    // Where a body that opens with a brace on (or just after) line `from` closes.
    fn brace_end(from: i64, lang: i64) -> i64, i64 {
        var depth = 0;
        var opened = false;
        var l = from;
        while l < lines_of && l < from + 20000 {
            sx_code(line_at(l), lang, code2);
            for ch, c in code2 {
                if ch == '{' { depth++; opened = true; }
                else if ch == '}' && opened { depth--; if depth == 0 { return l, c + 1; } }
            }
            if !opened && l > from + 1 { break; }
            l++;
        }
        return from, line_at(from).len;
    }
    // Where a body closed by `end` at the opening line's indentation ends.
    fn end_end(from: i64) -> i64, i64 {
        let indent = sx_skip_sp(line_at(from), 0);
        for l in from + 1 .. lines_of {
            let s = line_at(l);
            let k = sx_skip_sp(s, 0);
            if k == indent && starts_with(s[k..], "end") && (k + 3 == s.len || !sx_w(s[k + 3])) { return l, k + 3; }
        }
        return from, line_at(from).len;
    }

    var desc: u8[>..] = [];
    fn add(fi: i64, name: const u8[:], kind: i64, line: i64, col: i64, end: i64, endcol: i64, method: bool) {
        let d = d_kind.len;
        d_noff.push(names.len); d_nlen.push(name.len); names.append(name);
        d_soff.push(syms.len); d_slen.push(pkg.len + desc.len); syms.append(pkg); syms.append(desc);
        let sig = sx_cut(trim(line_at(line)), 200);
        d_goff.push(sigs.len); d_glen.push(sig.len); sigs.append(sig);
        d_kind.push(kind); d_line.push(line); d_col.push(col); d_end.push(end); d_endcol.push(endcol);
        d_file.push(fi); d_method.push(if method { 1 } else { 0 });
        d_next.push(-1);
        let key = hash_combine(hash(f_lang[fi]), hash(name));
        let tail = by_tail.get(key);
        if tail { let t: i64 = tail; d_next[t] = d; } else { by_head.insert(key, d); }
        by_tail.insert(key, d);
    }

    var ns: u8[>..] = [];
    var file_ns: u8[>..] = [];
    for fi in nfiles {
        f_first.push(d_kind.len);
        load_lines(fi);
        let lang = f_lang[fi];
        let rel = paths[p_off[fi]..p_off[fi] + p_len[fi]];
        ns.clear();
        sx_ns(sx_dirname(rel), ns);
        file_ns.clear();
        file_ns.append(ns);
        sx_ident(sx_basename(rel), file_ns);
        file_ns.push('/');
        var go_type_block = false;
        for i in lines_of {
            sx_code(line_at(i), lang, code);
            let s = code[..];
            if lang == SX_GO {
                if starts_with(s, ")") { go_type_block = false; }
                var done = false;
                if starts_with(s, "func") && s.len > 4 && sx_sp(s[4]) {
                    // func (r *T) Name( or func (T) Name[
                    var k = sx_skip_sp(s, 4);
                    if k < s.len && s[k] == '(' {
                        k = sx_skip_sp(s, k + 1);
                        let a0 = k;
                        k = sx_word_end(s, k);
                        let a1 = k;
                        k = sx_skip_sp(s, k);
                        var star = false;
                        if k < s.len && s[k] == '*' { star = true; k = sx_skip_sp(s, k + 1); }
                        let b0 = k;
                        k = sx_word_end(s, k);
                        let b1 = k;
                        var r0 = b0; var r1 = b1;
                        if b1 == b0 && !star { r0 = a0; r1 = a1; }
                        if r1 > r0 && k < s.len && s[k] == '[' {
                            let close = find(s[k..], "]");
                            k = if close >= 0 { k + close + 1 } else { s.len };
                        }
                        k = sx_skip_sp(s, k);
                        if r1 > r0 && k < s.len && s[k] == ')' {
                            k = sx_skip_sp(s, k + 1);
                            let n0 = k;
                            let n1 = sx_word_end(s, k);
                            let after = sx_skip_sp(s, n1);
                            if n1 > n0 && after < s.len && (s[after] == '(' || s[after] == '[') {
                                desc.clear();
                                desc.append(ns); sx_ident(s[r0..r1], desc); desc.push('#');
                                sx_ident(s[n0..n1], desc); desc.append("().");
                                let e, ec = brace_end(i, SX_GO);
                                add(fi, s[n0..n1], SX_METHOD, i, n0, e, ec, true);
                                done = true;
                            }
                        }
                    } else {
                        let n1 = sx_word_end(s, k);
                        let after = sx_skip_sp(s, n1);
                        if n1 > k && after < s.len && (s[after] == '(' || s[after] == '[') {
                            desc.clear();
                            desc.append(ns); sx_ident(s[k..n1], desc); desc.append("().");
                            let e, ec = brace_end(i, SX_GO);
                            add(fi, s[k..n1], SX_FUNCTION, i, k, e, ec, false);
                            done = true;
                        }
                    }
                }
                if !done && starts_with(s, "type") && s.len > 4 && sx_sp(s[4]) && s[s.len - 1] == '(' &&
                   sx_skip_sp(s, 4) == s.len - 1 {
                    go_type_block = true;
                    done = true;
                }
                if !done && (starts_with(s, "type") || go_type_block) {
                    var k = -1;
                    if starts_with(s, "type") && s.len > 4 && sx_sp(s[4]) { k = sx_skip_sp(s, 4); }
                    else if starts_with(s, "\t") { k = 1; }
                    if k >= 0 {
                        let n1 = sx_word_end(s, k);
                        var j = n1;
                        if n1 > k && j < s.len && s[j] == '[' {
                            let close = find(s[j..], "]");
                            j = if close >= 0 { j + close + 1 } else { -1 };
                        }
                        if n1 > k && j >= 0 && j < s.len && sx_sp(s[j]) {
                            let w = sx_skip_sp(s, j);
                            let is_struct = starts_with(s[w..], "struct");
                            let is_iface = starts_with(s[w..], "interface");
                            let kind = if is_struct { SX_STRUCT } else if is_iface { SX_INTERFACE } else { SX_TYPE };
                            desc.clear();
                            desc.append(ns); sx_ident(s[k..n1], desc); desc.push('#');
                            if is_struct || is_iface {
                                let e, ec = brace_end(i, SX_GO);
                                add(fi, s[k..n1], kind, i, k, e, ec, false);
                            } else {
                                add(fi, s[k..n1], kind, i, k, i, line_at(i).len, false);
                            }
                            done = true;
                        }
                    }
                }
                if !done {
                    var k = -1;
                    var kind = SX_VARIABLE;
                    if starts_with(s, "var") && s.len > 3 && sx_sp(s[3]) { k = sx_skip_sp(s, 3); }
                    else if starts_with(s, "const") && s.len > 5 && sx_sp(s[5]) { k = sx_skip_sp(s, 5); kind = SX_CONSTANT; }
                    if k >= 0 {
                        let n1 = sx_word_end(s, k);
                        if n1 > k {
                            desc.clear();
                            desc.append(ns); sx_ident(s[k..n1], desc); desc.push('.');
                            add(fi, s[k..n1], kind, i, k, i, line_at(i).len, false);
                        }
                    }
                }
            } else if lang == SX_SHELL {
                var k = sx_skip_sp(s, 0);
                var n0 = -1; var n1 = -1;
                if starts_with(s[k..], "function") && k + 8 < s.len && sx_sp(s[k + 8]) {
                    let a = sx_skip_sp(s, k + 8);
                    if a < s.len && sx_alpha(s[a]) {
                        var e = a + 1;
                        while e < s.len && (sx_w(s[e]) || s[e] == ':' || s[e] == '.' || s[e] == '-') { e++; }
                        n0 = a; n1 = e;
                    }
                } else if k < s.len && sx_alpha(s[k]) {
                    var e = k + 1;
                    while e < s.len && (sx_w(s[e]) || s[e] == ':' || s[e] == '.' || s[e] == '-') { e++; }
                    var j = sx_skip_sp(s, e);
                    if j < s.len && s[j] == '(' {
                        j = sx_skip_sp(s, j + 1);
                        if j < s.len && s[j] == ')' { n0 = k; n1 = e; }
                    }
                }
                if n0 >= 0 {
                    desc.clear();
                    desc.append(file_ns); sx_ident(s[n0..n1], desc); desc.append("().");
                    let e, ec = brace_end(i, SX_SHELL);
                    add(fi, s[n0..n1], SX_FUNCTION, i, n0, e, ec, false);
                }
            } else if lang == SX_MAKE {
                if s.len > 0 && sx_w(s[0]) {
                    var e = 1;
                    while e < s.len && (sx_w(s[e]) || s[e] == '.' || s[e] == '-' || s[e] == '/') { e++; }
                    let j = sx_skip_sp(s, e);
                    if j < s.len && s[j] == ':' && (j + 1 == s.len || (s[j + 1] != '=' && s[j + 1] != ':')) {
                        var last = i;
                        while last + 1 < lines_of && starts_with(line_at(last + 1), "\t") { last++; }
                        desc.clear();
                        desc.append(file_ns); sx_ident(s[..e], desc); desc.append("().");
                        add(fi, s[..e], SX_FUNCTION, i, 0, last, line_at(last).len, false);
                    }
                }
            } else if lang == SX_RUBY {
                let k = sx_skip_sp(s, 0);
                var kw = 0;
                if starts_with(s[k..], "class") { kw = 5; } else if starts_with(s[k..], "module") { kw = 6; }
                var done = false;
                if kw > 0 && k + kw < s.len && sx_sp(s[k + kw]) {
                    let a = sx_skip_sp(s, k + kw);
                    if a < s.len && s[a] >= 'A' && s[a] <= 'Z' {
                        var e = sx_word_end(s, a);
                        var last0 = a;
                        while e + 2 < s.len && s[e] == ':' && s[e + 1] == ':' && sx_w(s[e + 2]) {
                            last0 = e + 2;
                            e = sx_word_end(s, e + 2);
                        }
                        desc.clear();
                        desc.append(file_ns); sx_ident(s[a..e], desc); desc.push('#');
                        let le, lc = end_end(i);
                        add(fi, s[last0..e], if kw == 5 { SX_CLASS } else { SX_MODULE }, i, a, le, lc, false);
                        done = true;
                    }
                }
                if !done && starts_with(s[k..], "def") && k + 3 < s.len && sx_sp(s[k + 3]) {
                    var a = sx_skip_sp(s, k + 3);
                    if starts_with(s[a..], "self.") { a += 5; }
                    if a < s.len && sx_alpha(s[a]) {
                        var e = sx_word_end(s, a);
                        if e < s.len && (s[e] == '?' || s[e] == '!' || s[e] == '=') { e++; }
                        desc.clear();
                        desc.append(file_ns); sx_ident(s[a..e], desc); desc.append("().");
                        let le, lc = end_end(i);
                        add(fi, s[a..e], SX_METHOD, i, a, le, lc, true);
                    }
                }
            } else {
                var k = sx_skip_sp(s, 0);
                if starts_with(s[k..], "local") && k + 5 < s.len && sx_sp(s[k + 5]) { k = sx_skip_sp(s, k + 5); }
                if starts_with(s[k..], "function") && k + 8 < s.len && sx_sp(s[k + 8]) {
                    let a = sx_skip_sp(s, k + 8);
                    var e = a;
                    while e < s.len && (sx_w(s[e]) || s[e] == '.' || s[e] == ':') { e++; }
                    let j = sx_skip_sp(s, e);
                    if e > a && j < s.len && s[j] == '(' {
                        var n0 = a;
                        for x in a..e { if s[x] == '.' || s[x] == ':' { n0 = x + 1; } }
                        desc.clear();
                        desc.append(file_ns); sx_ident(s[a..e], desc); desc.append("().");
                        let le, lc = end_end(i);
                        add(fi, s[n0..e], SX_FUNCTION, i, n0, le, lc, n0 > a);
                    }
                }
            }
        }
    }
    f_first.push(d_kind.len);

    // The SCIP index.
    var top: u8[>..] = [];
    var meta: u8[>..] = [];
    pb_int(meta, 1, 0);
    var tool: u8[>..] = [];
    pb_bytes(tool, 1, "swan-syntax");
    pb_bytes(tool, 2, "1");
    pb_bytes(meta, 2, tool);
    pb_bytes(meta, 3, str("file://", repo));
    pb_int(meta, 4, 1);
    pb_bytes(top, 1, meta);

    var n_occ = 0;
    var pool: i64[>..] = [];
    var hits: i64[>..] = [];
    var occ: u8[>..] = [];
    var info: u8[>..] = [];
    var docm: u8[>..] = [];
    let W: i64 = 16777216;
    for fi in nfiles {
        load_lines(fi);
        let lang = f_lang[fi];
        let rel = paths[p_off[fi]..p_off[fi] + p_len[fi]];
        let lname = sx_lang_name(lang);
        var doc: u8[>..] = [];
        pb_bytes(doc, 1, rel);
        pb_bytes(doc, 4, if lang == SX_MAKE { "Makefile" } else { lname });
        // The file itself, as scip-typescript names a module.
        var msym: u8[>..] = [];
        msym.append(pkg);
        sx_ns(sx_dirname(rel), msym);
        sx_ident(sx_basename(rel), msym);
        msym.push('/');
        let last = lines_of - 1;
        occ.clear();
        pb_range(occ, 1, 0, 0, 0, 0);
        pb_bytes(occ, 2, msym);
        pb_int(occ, 3, 1);
        pb_range(occ, 7, 0, 0, last, line_at(last).len);
        pb_bytes(doc, 2, occ);
        n_occ++;
        var def_at = dictionary<i64, bool> {};
        for d in f_first[fi]..f_first[fi + 1] {
            occ.clear();
            pb_range(occ, 1, d_line[d], d_col[d], d_line[d], d_col[d] + d_nlen[d]);
            pb_bytes(occ, 2, syms[d_soff[d]..d_soff[d] + d_slen[d]]);
            pb_int(occ, 3, 1);
            pb_range(occ, 7, d_line[d], 0, d_end[d], d_endcol[d]);
            pb_bytes(doc, 2, occ);
            n_occ++;
            def_at.insert(d_line[d] * W + d_col[d], true);
        }
        // References by name.
        let my_dir = f_dir[fi];
        for i in lines_of {
            if lang == SX_SHELL { sx_shell_code(line_at(i), code); } else { sx_code(line_at(i), lang, code); }
            let s = code[..];
            var c = 0;
            while c < s.len {
                let ch = s[c];
                var start_ok = false;
                if lang == SX_MAKE { start_ok = sx_w(ch); } else { start_ok = sx_alpha(ch); }
                if !start_ok { c++; continue; }
                var e = c + 1;
                if lang == SX_SHELL { while e < s.len && (sx_w(s[e]) || s[e] == ':' || s[e] == '-') { e++; } }
                else if lang == SX_MAKE { while e < s.len && (sx_w(s[e]) || s[e] == '.' || s[e] == '-' || s[e] == '/') { e++; } }
                else {
                    e = sx_word_end(s, e);
                    if lang == SX_RUBY && e < s.len && (s[e] == '?' || s[e] == '!') { e++; }
                }
                let tok = s[c..e];
                if !def_at.contains(i * W + c) {
                    // resolve: same file, then same folder, then the repo;
                    // the first tier with any decides, and only if it has at most 3.
                    pool.clear();
                    let head = by_head.get(hash_combine(hash(lang), hash(tok)));
                    if head {
                        var d: i64 = head;
                        var any_method = false;
                        while d >= 0 {
                            if names[d_noff[d]..d_noff[d] + d_nlen[d]] == tok {
                                pool.push(d);
                                if d_method[d] == 1 { any_method = true; }
                            }
                            d = d_next[d];
                        }
                        let after_dot = c > 0 && s[c - 1] == '.';
                        let only_methods = lang == SX_GO && after_dot && any_method;
                        hits.clear();
                        for tier in 3 {
                            if hits.len == 0 {
                                var n = 0;
                                for d2 in pool {
                                    let f2 = d_file[d2];
                                    let in_tier = if tier == 0 { f2 == fi } else if tier == 1 { f_dir[f2] == my_dir } else { true };
                                    if in_tier && (!only_methods || d_method[d2] == 1) { n++; }
                                }
                                if n > 3 { hits.push(-1); }      // decided: too many
                                else if n > 0 {
                                    for d2 in pool {
                                        let f2 = d_file[d2];
                                        let in_tier = if tier == 0 { f2 == fi } else if tier == 1 { f_dir[f2] == my_dir } else { true };
                                        if in_tier && (!only_methods || d_method[d2] == 1) { hits.push(d2); }
                                    }
                                }
                            }
                        }
                        for d2 in hits {
                            if d2 >= 0 {
                                occ.clear();
                                pb_range(occ, 1, i, c, i, e);
                                pb_bytes(occ, 2, syms[d_soff[d2]..d_soff[d2] + d_slen[d2]]);
                                pb_bytes(doc, 2, occ);
                                n_occ++;
                            }
                        }
                    }
                }
                c = e;
            }
        }
        // Symbol information: the module, then each definition.
        info.clear();
        pb_bytes(info, 1, msym);
        docm.clear();
        format(docm, "```", lname, "\n", sx_basename(rel), "\n```");
        pb_bytes(info, 3, docm);
        pb_int(info, 5, SX_MODULE);
        pb_bytes(info, 6, sx_basename(rel));
        pb_bytes(doc, 3, info);
        for d in f_first[fi]..f_first[fi + 1] {
            info.clear();
            pb_bytes(info, 1, syms[d_soff[d]..d_soff[d] + d_slen[d]]);
            docm.clear();
            format(docm, "```", lname, "\n", sigs[d_goff[d]..d_goff[d] + d_glen[d]], "\n```");
            pb_bytes(info, 3, docm);
            pb_int(info, 5, d_kind[d]);
            pb_bytes(info, 6, names[d_noff[d]..d_noff[d] + d_nlen[d]]);
            pb_bytes(doc, 3, info);
        }
        pb_bytes(top, 2, doc);
    }
    guard write_file(out_path, top) else {
        write_stderr(str("syntax-index: cannot write ", out_path, "\n"));
        return false;
    }
    write_stderr(str("syntax-index: ", nfiles, " files, ", d_kind.len, " definitions, ", n_occ, " occurrences\n"));
    return true;
}
