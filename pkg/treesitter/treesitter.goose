// Structural search over tree-sitter trees, ast-grep style: a pattern is code
// in the target's language with metavariables, `$X` for any one node and
// `$$$X` for any run of siblings (none included). `$_` and names starting
// with `_` match without capturing; a name used twice must match the same
// text both times. The grammars and the runtime are C (ts_shim.c), reached
// through an opaque handle and plain slices.

namespace treesitter;

import std;

extern fn swan_ts_parse(lang: const u8[:], src: const u8[:]) -> i64;
extern fn swan_ts_free(h: i64);
extern fn swan_ts_count(h: i64) -> i64;
extern fn swan_ts_fill(h: i64, out: i32[:]) -> i64;
extern fn swan_ts_parse_files(lang: const u8[:], paths: const u8[:], handles: i64[:]) -> i64;

// Each node is R ints: symbol, flags, start and end byte, start row and
// column (0-based), first child, next sibling (-1 for none).
let R = 8;
let F_NAMED = 1;
let F_EXTRA = 2;
let F_ERROR = 4;

// Parses src into `nodes` (pre-order, the root first). False when the
// language has no grammar here.
fn parse(lang: const u8[:], src: const u8[:], nodes: i32[>..]&) -> bool {
    let h = swan_ts_parse(lang, src);
    guard h != 0 else { return false; }
    let n = swan_ts_count(h);
    nodes.clear();
    nodes.resize(n * R, 0);
    swan_ts_fill(h, nodes[..]);
    swan_ts_free(h);
    return true;
}

// Parses many files at once on several threads (paths NUL-separated, each
// ending in NUL); handles[i] is file i's tree, 0 if unreadable. Each tree
// is then searched with search_tree, which frees it.
fn parse_files(lang: const u8[:], paths: const u8[:], handles: i64[>..]&) -> bool {
    var n = 0;
    for c in paths { if c == 0 { n++; } }
    handles.clear();
    handles.resize(n, 0);
    return swan_ts_parse_files(lang, paths, handles[..]) >= 0;
}

// Whether src can hold a match at all: it has every word the pattern has.
fn might_match(src: const u8[:]) -> bool {
    var ok = true;
    each_split(p_words, '\n') { w => if ok && w.len > 0 && find(src, w) < 0 { ok = false; } };
    return ok;
}

// The grammar for a file, by its name; "" when there is none.
fn language_of_path(p: const u8[:]) -> const u8[:] {
    if ends_with(p, ".ts") || ends_with(p, ".mts") || ends_with(p, ".cts") { return "typescript"; }
    if ends_with(p, ".tsx") { return "tsx"; }
    if ends_with(p, ".js") || ends_with(p, ".jsx") || ends_with(p, ".mjs") || ends_with(p, ".cjs") { return "javascript"; }
    if ends_with(p, ".py") || ends_with(p, ".pyi") { return "python"; }
    if ends_with(p, ".rs") { return "rust"; }
    if ends_with(p, ".java") { return "java"; }
    if ends_with(p, ".c") || ends_with(p, ".h") { return "c"; }
    if ends_with(p, ".cc") || ends_with(p, ".cpp") || ends_with(p, ".cxx") || ends_with(p, ".hpp") ||
       ends_with(p, ".hh") || ends_with(p, ".hxx") { return "cpp"; }
    if ends_with(p, ".cu") || ends_with(p, ".cuh") { return "cuda"; }
    return "";
}

// --- the pattern ------------------------------------------------------------

var p_text: u8[>..];            // the pattern with metavariables renamed to identifiers
var p_nodes: i32[>..];
var p_root = -1;
var p_lang: u8[..32];
var p_words: u8[>..];           // the pattern's own words, one per line: a file without one cannot match

let MV = "__swan_mv_";          // $X becomes __swan_mv_X
let MVM = "__swan_mvm_";        // $$$X becomes __swan_mvm_X

// $X and $$$X as identifiers every grammar accepts.
fn rename_metavars(pattern: const u8[:], out: u8[>..]&) {
    var i = 0;
    while i < pattern.len {
        let c = pattern[i];
        if c != '$' { out.push(c); i++; continue; }
        var d = 0;
        while i + d < pattern.len && pattern[i + d] == '$' { d++; }
        var e = i + d;
        while e < pattern.len && ((pattern[e] >= 'A' && pattern[e] <= 'Z') || (pattern[e] >= '0' && pattern[e] <= '9') ||
                                  pattern[e] == '_') { e++; }
        if d == 3 { out.append(MVM); out.append(if e > i + d { pattern[i + d..e] } else { "_" }); }
        else if d == 1 && e > i + 1 { out.append(MV); out.append(pattern[i + 1..e]); }
        else { out.append(pattern[i..e]); }
        i = e;
    }
}

fn is_word(s: const u8[:]) -> bool {
    for c in s { if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') { return false; } }
    return true;
}

fn sym(n: const i32[:], i: i64) -> i64 { return n[i * R]; }
fn flags(n: const i32[:], i: i64) -> i64 { return n[i * R + 1]; }
fn start(n: const i32[:], i: i64) -> i64 { return n[i * R + 2]; }
fn end(n: const i32[:], i: i64) -> i64 { return n[i * R + 3]; }
fn row(n: const i32[:], i: i64) -> i64 { return n[i * R + 4]; }
fn col(n: const i32[:], i: i64) -> i64 { return n[i * R + 5]; }
fn first(n: const i32[:], i: i64) -> i64 { return n[i * R + 6]; }
fn next(n: const i32[:], i: i64) -> i64 { return n[i * R + 7]; }

// Skips comments and other extras (tree-sitter counts error nodes as extras
// too, but a pattern's metavariable can be one).
fn solid(n: const i32[:], i: i64) -> i64 {
    var k = i;
    while k >= 0 && (flags(n, k) & (F_EXTRA | F_ERROR)) == F_EXTRA { k = next(n, k); }
    return k;
}

// Contexts a pattern is parsed in, first that parses: alone (a whole file),
// as a statement inside a function, as a class member. Rust, Java and C only
// take items at the top of a file, so `$X.unwrap()` needs the function.
fn context(k: i64, pre: u8[>..]&, post: u8[>..]&) {
    match k {
        1 => { pre.append("fn __swan_ctx() {\n"); post.append("\n}"); },
        2 => { pre.append("void __swan_ctx() {\n"); post.append(";\n}"); },
        3 => { pre.append("class __SwanCtx { void __swan_ctx() {\n"); post.append(";\n} }"); },
        4 => { pre.append("class __SwanCtx {\n"); post.append("\n}"); },
        _ => {},
    }
}

// Compiles a pattern for a language. False, with why, when the language has
// no grammar or the pattern does not parse as code.
fn compile(lang: const u8[:], pattern: const u8[:], why: u8[>..]&) -> bool {
    p_words.clear();
    var i = 0;
    while i < pattern.len {
        let c = pattern[i];
        let starts = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        if !starts { i++; continue; }
        var e = i;
        while e < pattern.len && is_word(pattern[e..e + 1]) { e++; }
        if i == 0 || pattern[i - 1] != '$' { p_words.append(pattern[i..e]); p_words.push('\n'); }
        i = e;
    }
    var renamed: u8[>..] = [];
    rename_metavars(trim(pattern), renamed);
    p_lang.clear();
    format(p_lang, lang);
    for k in 0..5 {
        var pre: u8[>..] = [];
        var post: u8[>..] = [];
        context(k, pre, post);
        var text: u8[>..] = [];
        format(text, pre, renamed, post);
        guard parse(lang, text, p_nodes) else { format(why, "no tree-sitter grammar for ", lang); return false; }
        let n = p_nodes.len / R;
        // An error that is only a metavariable is fine: `{ $$$B }` where the
        // grammar wants items, say. It stands for whatever is there.
        var bad = false;
        for i in 0..n {
            if (flags(p_nodes, i) & F_ERROR) != 0 {
                let t = trim(text[start(p_nodes, i)..end(p_nodes, i)]);
                if !(starts_with(t, "__swan_mv") && is_word(t)) { bad = true; }
            }
        }
        // The outermost node that is exactly the pattern (or it and a `;`).
        var at: i64 = -1;
        let a = pre.len;
        let b = a + renamed.len;
        if !bad {
            for i in 0..n {
                if at < 0 && start(p_nodes, i) == a && (end(p_nodes, i) == b || end(p_nodes, i) == b + 1) { at = i; }
            }
        }
        if at >= 0 {
            p_text.clear();
            p_text.append(text);
            // Down through wrappers (an expression statement): one named
            // child, and nothing else but a `;`.
            loop {
                let w = wrapped(at);
                if w < 0 { break; }
                at = w;
            }
            p_root = at;
            return true;
        }
    }
    format(why, "the pattern does not parse as ", lang);
    return false;
}

// --- matching ----------------------------------------------------------------

struct Bind { name: u8[..64], a: i64, b: i64 }     // target nodes a..b (inclusive); a < 0: none

var t_text: u8[>..];
var t_nodes: i32[>..];
var binds: Bind[>..];
var nb = 0;                     // binds in use; backtracking cuts it back

fn ptext(i: i64) -> const u8[:] { return p_text[start(p_nodes, i)..end(p_nodes, i)]; }
fn ttext(i: i64) -> const u8[:] { return t_text[start(t_nodes, i)..end(t_nodes, i)]; }
fn span_text(a: i64, b: i64) -> const u8[:] {
    guard a >= 0 else { return t_text[0..0]; }
    return t_text[start(t_nodes, a)..end(t_nodes, b)];
}

// The only named child of a wrapper (an expression statement: one named
// child, nothing else but a `;`), or -1.
fn wrapped(p: i64) -> i64 {
    var only: i64 = -1;
    var named = 0;
    var c = first(p_nodes, p);
    while c >= 0 {
        if (flags(p_nodes, c) & F_EXTRA) == 0 {
            if (flags(p_nodes, c) & F_NAMED) != 0 { named++; only = c; }
            else if ptext(c) != ";" { return -1; }
        }
        c = next(p_nodes, c);
    }
    return if named == 1 { only } else { -1 };
}

// 1 for $X, 3 for $$$X, 0 otherwise; the name goes in `name`. A
// metavariable is a named leaf, an error node holding only one, or a
// statement wrapping one (`$$$B` alone in a block is an expression
// statement).
recursive fn meta(p: i64, name: u8[..64]&) -> i64 {
    let leaf = first(p_nodes, p) < 0 && (flags(p_nodes, p) & F_NAMED) != 0;
    if !leaf && (flags(p_nodes, p) & F_ERROR) == 0 {
        let w = wrapped(p);
        return if w >= 0 { meta(w, name) } else { 0 };
    }
    let s = trim(ptext(p));
    guard is_word(s) else { return 0; }
    if starts_with(s, MVM) { name.clear(); format(name, s[MVM.len..]); return 3; }
    if starts_with(s, MV) { name.clear(); format(name, s[MV.len..]); return 1; }
    return 0;
}

fn bind(name: const u8[:], a: i64, b: i64) -> bool {
    if name.len > 0 && name[0] == '_' { return true; }      // anonymous
    for k in 0..nb {
        if binds[k].name == name { return span_text(binds[k].a, binds[k].b) == span_text(a, b); }
    }
    var e = Bind { a: a, b: b, .. };
    format(e.name, name);
    if nb < binds.len { binds[nb] = e; } else { binds.push(e); }
    nb++;
    return true;
}

recursive fn match_node(p: i64, t: i64) -> bool {
    var name: u8[..64] = [];
    if meta(p, name) == 1 { return (flags(t_nodes, t) & F_NAMED) != 0 && bind(name, t, t); }   // $X is one named node
    guard sym(p_nodes, p) == sym(t_nodes, t) else { return false; }
    if first(p_nodes, p) < 0 { return ptext(p) == ttext(t); }
    return match_seq(solid(p_nodes, first(p_nodes, p)), solid(t_nodes, first(t_nodes, t)));
}

fn unnamed(t: i64) -> bool { return t >= 0 && (flags(t_nodes, t) & F_NAMED) == 0; }

// Pattern siblings from p against target siblings from t. As ast-grep's
// default ("smart") does, punctuation in the target that the pattern leaves
// out is skipped (`return $X` matches `return x;`), and once the pattern's
// siblings are used up the target's remaining ones are allowed (`if ($C) {
// $$$B }` matches an if with an else; `const $X = $V` a declaration of two).
recursive fn match_seq(p: i64, t: i64) -> bool {
    if p < 0 { return true; }
    let mark = nb;
    let pn = solid(p_nodes, next(p_nodes, p));
    var name: u8[..64] = [];
    if meta(p, name) == 3 {
        if bind(name, -1, -1) && match_seq(pn, t) { return true; }
        nb = mark;
        var last = t;
        while last >= 0 {
            if bind(name, t, last) && match_seq(pn, solid(t_nodes, next(t_nodes, last))) { return true; }
            nb = mark;
            last = solid(t_nodes, next(t_nodes, last));
        }
        return false;
    }
    guard t >= 0 else { return false; }
    if match_node(p, t) && match_seq(pn, solid(t_nodes, next(t_nodes, t))) { return true; }
    nb = mark;
    if unnamed(t) && match_seq(p, solid(t_nodes, next(t_nodes, t))) { return true; }
    nb = mark;
    return false;
}

// Every node of src the compiled pattern matches, in source order, as
// F(node); inside F, match_* and each_binding describe the match.
fn search<F>(src: const u8[:]) {
    guard might_match(src);
    t_text.clear();
    t_text.append(src);
    guard parse(p_lang, t_text, t_nodes);
    for i in 0..t_nodes.len / R {
        nb = 0;
        if (flags(t_nodes, i) & F_EXTRA) == 0 && match_node(p_root, i) { F(i); }
    }
}

// The same over a tree from parse_files, for src, its file's text; frees it.
fn search_tree<F>(h: i64, src: const u8[:]) {
    guard h != 0;
    t_text.clear();
    t_text.append(src);
    t_nodes.clear();
    t_nodes.resize(swan_ts_count(h) * R, 0);
    swan_ts_fill(h, t_nodes[..]);
    swan_ts_free(h);
    for i in 0..t_nodes.len / R {
        nb = 0;
        if (flags(t_nodes, i) & F_EXTRA) == 0 && match_node(p_root, i) { F(i); }
    }
}

fn match_start(i: i64) -> i64 { return start(t_nodes, i); }
fn match_end(i: i64) -> i64 { return end(t_nodes, i); }
fn match_row(i: i64) -> i64 { return row(t_nodes, i); }
fn match_col(i: i64) -> i64 { return col(t_nodes, i); }
fn match_text(i: i64) -> const u8[:] { return ttext(i); }

// F(name, text) for each captured metavariable of the current match.
fn each_binding<F>() {
    for k in 0..nb { F(binds[k].name[..], span_text(binds[k].a, binds[k].b)); }
}

// The rewrite template with each $X and $$$X replaced by what it captured.
fn fill_template(template: const u8[:], out: u8[>..]&) {
    var i = 0;
    while i < template.len {
        let c = template[i];
        if c != '$' { out.push(c); i++; continue; }
        var d = 0;
        while i + d < template.len && template[i + d] == '$' { d++; }
        var e = i + d;
        while e < template.len && ((template[e] >= 'A' && template[e] <= 'Z') || (template[e] >= '0' && template[e] <= '9') ||
                                   template[e] == '_') { e++; }
        var done = false;
        if (d == 1 || d == 3) && e > i + d {
            let name = template[i + d..e];
            for k in 0..nb {
                if !done && binds[k].name == name { out.append(span_text(binds[k].a, binds[k].b)); done = true; }
            }
        }
        if !done { out.append(template[i..e]); }
        i = e;
    }
}

// --- searching on every core --------------------------------------------------
// Workers are Goose threads: each gets its own copy of the compiled pattern
// (globals are copied at the spawn) and takes files from a queue; results
// come back on another. Nothing is shared.

struct SearchJob { idx: i64, path: u8[>..] }

// One file's matches, each "start end row column" 0x1f, then its captures
// as name 0x1f text 0x1e, and a 0x1d after each match.
struct SearchDone { idx: i64, data: u8[>..] }

thread_fn search_worker() {
    loop {
        let job = qget<SearchJob>();
        guard job.idx >= 0 else { break; }
        var done = SearchDone { idx: job.idx, .. };
        var text: u8[>..] = [];
        if read_file(job.path, text) && might_match(text) {
            t_text.clear();
            t_text.append(text);
            if parse(p_lang, t_text, t_nodes) {
                for i in 0..t_nodes.len / R {
                    nb = 0;
                    if (flags(t_nodes, i) & F_EXTRA) == 0 && match_node(p_root, i) {
                        format(done.data, start(t_nodes, i), " ", end(t_nodes, i), " ", row(t_nodes, i), " ", col(t_nodes, i));
                        done.data.push(0x1f);
                        for k in 0..nb {
                            done.data.append(binds[k].name[..]);
                            done.data.push(0x1f);
                            done.data.append(span_text(binds[k].a, binds[k].b));
                            done.data.push(0x1e);
                        }
                        done.data.push(0x1d);
                    }
                }
            }
        }
        qput(done);
    }
}

// Searches the files (absolute paths, one per line) with the compiled
// pattern on every core, then calls F(file index, start, end, row, column,
// captures) for each match, in file order; captures as name 0x1f text 0x1e.
fn search_files<F>(paths: const u8[:]) {
    var n = 0;
    each_split(paths, '\n') { p =>
        if p.len > 0 {
            var job = SearchJob { idx: n, .. };
            job.path.append(p);
            qput(job);
            n++;
        }
    };
    guard n > 0;
    let workers = max(1, min(min(hardware_threads(), 16), n));
    for w in 0..workers { qput(SearchJob { idx: -1, .. }); }
    var ids: i64[>..] = [];
    for w in 0..workers { ids.push(thread_spawn(search_worker)); }
    // Results arrive in any order; they are kept in one buffer and read back
    // in file order.
    var all: u8[>..] = [];
    var at: i64[>..] = [];
    var len: i64[>..] = [];
    at.resize(n, 0);
    len.resize(n, 0);
    for k in 0..n {
        let d = qget<SearchDone>();
        at[d.idx] = all.len;
        len[d.idx] = d.data.len;
        all.append(d.data);
    }
    for id in ids { thread_wait(id); }
    for idx in 0..n {
        each_split(all[at[idx]..at[idx] + len[idx]], 0x1d) { one =>
            let head_end = find(one, "\x1f");
            if head_end > 0 {
                let nums = split(one[..head_end], ' ');
                let a, a_ok = parse_int(nums[0]);
                let b, b_ok = parse_int(nums[1]);
                let r, r_ok = parse_int(nums[2]);
                let c, c_ok = parse_int(nums[3]);
                F(idx, a, b, r, c, one[head_end + 1..]);
            }
        };
    }
}
