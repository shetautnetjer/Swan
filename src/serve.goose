// `swan serve`: the MCP server, JSON-RPC 2.0 over stdio, one message per
// line. It answers initialize, ping, tools/list and tools/call from the
// SQLite map and needs nothing else running.

import std;
import os;
import json;
import sqlite;

let SWAN_VERSION = "0.1.0";

let TOOLS = """
    [{"name":"use_repo","description":"Choose the repository the tools answer about, building its code map the first time (the trust rules of `swan map` apply: indexers that run the repo's build files wait for `swan trust`, and the answer's `skipped` says which). `path` is the repo's root or a path inside it. With `build` false an unmapped repo is an error that names the `swan map` command to run. Returns the repo root, the map file, symbol and file counts, files changed since the map, and the map report. The choice persists; any tool's `repo` argument switches the same way.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"build":{"type":"boolean","description":"Map the repo first when it has no map (default true)."}},"required":["path"]}},
     {"name":"find_symbol","description":"Find symbols by name path. 'add' matches any symbol named add, 'Store/add' any whose name path ends that way, '/Store/add' only that exact path. Returns kind, signature, file, 1-based line and body line range; include_body adds the source.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path_pattern":{"type":"string"},"relative_path":{"type":"string","description":"Only symbols defined in this file or directory."},"substring_matching":{"type":"boolean","description":"Match the last name as a substring (no '/' in the pattern)."},"include_body":{"type":"boolean"},"max_results":{"type":"integer"}},"required":["name_path_pattern"]}},
     {"name":"find_referencing_symbols","description":"Find every reference (import lines included, marked import) to the symbols a name path matches, from the compiler's own resolution (SCIP), including through re-exports and renamed imports. Each reference gives file, 1-based line and column, the symbol it sits inside (in_symbol), and its line of source. Rust uses inside macro calls that rust-analyzer could not resolve are matched by name and marked by_name. include_members also counts uses through what the symbol holds (enum variants, methods, fields; Rust impl functions), each marked with via: use it for 'where is this type used'.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path":{"type":"string"},"include_members":{"type":"boolean"},"relative_path":{"type":"string","description":"The file or directory that defines the symbol, to pick one of several matches."},"max_results":{"type":"integer","description":"References per symbol (default 500)."}},"required":["name_path"]}},
     {"name":"get_symbol_at","description":"What is at a position: the symbol a file's line and column (1-based) refer to, with its kind, signature, where it is defined (file, line, body lines) or which package it comes from, whether this spot is its definition or an import, and the symbol the position sits inside. JetBrains' get_symbol_info. When nothing covers that column, the line's symbols are listed instead.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"relative_path":{"type":"string"},"line":{"type":"integer"},"column":{"type":"integer"}},"required":["relative_path","line","column"]}},
     {"name":"get_symbols_overview","description":"List the symbols a file defines (or every file under a directory), with name paths, kinds and 1-based lines.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"relative_path":{"type":"string"}},"required":["relative_path"]}},
     {"name":"get_callers","description":"Who calls or uses a symbol (import lines left out), and who uses those, up to depth steps (default 1, max 5): the impact radius of changing it. Every reference counts (calls, type uses, imports). Each caller has its distance and is_test; the summary counts all affected symbols and files and lists the test files to run.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path":{"type":"string"},"relative_path":{"type":"string","description":"The file or directory that defines the symbol."},"depth":{"type":"integer"},"max_results":{"type":"integer","description":"Callers listed (default 200); the summary covers all."}},"required":["name_path"]}},
     {"name":"get_callees","description":"What a function, method or class body uses: the symbols it calls or references, with use counts. Symbols from dependencies show their package and version instead of a file.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"max_results":{"type":"integer"}},"required":["name_path"]}},
     {"name":"find_implementations","description":"What implements, extends or overrides a symbol, from the compiler's own view (SCIP): the classes behind an interface, the subclasses of a class, the overrides of a method. Each result has its distance (1 = direct).","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"max_results":{"type":"integer"},"live":{"type":"boolean","description":"Ask the running language server (rust-analyzer) instead of the map: sees edits made since the last map; each location comes with its line of source."}},"required":["name_path"]}},
     {"name":"get_type_hierarchy","description":"A symbol's supertypes (what it implements, extends or overrides) and subtypes (what implements, extends or overrides it), up to depth steps each way (default 3).","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"depth":{"type":"integer"},"max_results":{"type":"integer"}},"required":["name_path"]}},
     {"name":"find_unused_symbols","description":"Functions, classes, methods, types and variables defined in the repo that nothing references or implements. Candidates for removal, not proof: entry points and code reached by name at run time also appear. Test files are skipped unless include_tests.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"relative_path":{"type":"string","description":"Only this file or directory."},"include_tests":{"type":"boolean"},"max_results":{"type":"integer","description":"Listed (default 200); total counts all."}}}},
     {"name":"replace_symbol_body","description":"Replace a symbol's whole definition (signature included, as find_symbol with include_body shows it) with new code. Read the body first. Refused if the file changed since the map was built. Returns the new line range and how many places use the symbol, so you know what to check.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path":{"type":"string"},"relative_path":{"type":"string","description":"The file that defines the symbol (required)."},"body":{"type":"string"}},"required":["name_path","relative_path","body"]}},
     {"name":"insert_after_symbol","description":"Insert code after a function, method or class definition, one blank line apart. Include the indentation you want.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"body":{"type":"string"}},"required":["name_path","relative_path","body"]}},
     {"name":"insert_before_symbol","description":"Insert code before a symbol's definition, one blank line apart: a new function, class or import before an existing one.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"body":{"type":"string"}},"required":["name_path","relative_path","body"]}},
     {"name":"rename_symbol","description":"Rename a symbol at every use the compiler resolved, across files. By default only plans: every site, sites skipped because their text differs (aliases, re-exports), conflicts with an existing symbol of the new name, and stale files. Set apply to true to write it; a conflict or a stale file refuses. Strings, comments and uses by name at run time are not covered.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path":{"type":"string"},"relative_path":{"type":"string","description":"The file that defines the symbol (required)."},"new_name":{"type":"string"},"apply":{"type":"boolean"}},"required":["name_path","relative_path","new_name"]}},
     {"name":"get_diagnostics","description":"Compiler errors and warnings (tsc, cargo check) from the last check, each pinned to the symbol it is in. With name_path: the symbol's own diagnostics plus, up to depth steps out (default 1), those of the symbols that use it: where an edit to it shows up as breakage. With only relative_path: a file or directory. With neither: everything. Entries in files changed since the check say stale.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"depth":{"type":"integer"},"errors_only":{"type":"boolean"},"max_results":{"type":"integer"},"live":{"type":"boolean","description":"Ask the running language server (rust-analyzer) about the one file in relative_path, as it is on disk now: errors seconds after an edit, without check_errors. The first call starts the server and waits for it to index."}}}},
     {"name":"update_map","description":"Bring the map up to date after edits: reruns the SCIP indexers over the repo and rewrites only the files whose data changed. Takes as long as the indexers (seconds on small repos, minutes on large ones).","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."}}}},
     {"name":"check_errors","description":"Run the repo's own checkers (tsc with the repo's tsconfig, cargo check, pyright) and load what they report, so get_diagnostics answers from fresh results.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."}}}},
     {"name":"run_tests","description":"Run the tests that reach a symbol through calls (up to depth steps, default 3), or the tests that reach anything a file defines when relative_path names a file and name_path is empty. Uses each language's test runner from tools/modules.json (pytest, bun test / vitest, cargo test). Returns which test files ran, pass or fail, and the runner's output tail.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"depth":{"type":"integer"}}}},
     {"name":"format_file","description":"Run a file through its language's formatter from tools/modules.json (ruff format, biome format, rustfmt). The file's positions in the map are stale afterwards until update_map.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"relative_path":{"type":"string"}},"required":["relative_path"]}},
     {"name":"search_pattern","description":"Structural search, ast-grep style: a pattern is code in the target language with metavariables, $X for any one node and $$$X for any run of nodes (none included); $_ matches without capturing, and a name used twice must match the same text. Matches by syntax tree, not text (so spacing and comments do not matter), in TS/TSX/JS, Python, Rust, Java, Kotlin, C, C++, CUDA, C#, PHP, Lua, GDScript and the GLSL, HLSL and WGSL shading languages via tree-sitter. Each match has its position, what each metavariable captured, and the symbol it sits in.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"pattern":{"type":"string"},"language":{"type":"string","description":"typescript, tsx, javascript, python, rust, java, kotlin, c, cpp, cuda, csharp, php, lua, gdscript, glsl, hlsl or wgsl; default every language the pattern parses in."},"relative_path":{"type":"string","description":"A file or directory to search; default the whole repo."},"max_results":{"type":"integer"}},"required":["pattern"]}},
     {"name":"rewrite_pattern","description":"Structural rewrite: every match of pattern (as in search_pattern) replaced by rewrite, where $X and $$$X stand for what they captured. Without apply it only plans the edits (before and after for each); apply writes them, refused when a file changed since the map was built. Nested matches are left to the outer one. Rewritten files are stale in the map until update_map.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"pattern":{"type":"string"},"rewrite":{"type":"string"},"language":{"type":"string"},"relative_path":{"type":"string"},"apply":{"type":"boolean"}},"required":["pattern","rewrite"]}},
     {"name":"index_info","description":"When and from what the code map was built: repo root, build time, counts, and the files changed since the SCIP run (stale_files). Answers about a stale file carry \"stale\": true; refresh the map or reread the file.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."}}}}]
    """;

fn arg_text(args: json::Node?, key: const u8[:]) -> const u8[:] {
    let v, ok = json::as_string(json::member(args, key));
    return if ok { v } else { "" };
}

fn arg_bool(args: json::Node?, key: const u8[:]) -> bool {
    let v, ok = json::as_bool(json::member(args, key));
    return ok && v;
}

fn arg_int(args: json::Node?, key: const u8[:], dflt: i64) -> i64 {
    let v, ok = json::as_i64(json::member(args, key));
    return if ok && v > 0 { v } else { dflt };
}

fn arg_bool_default(args: json::Node?, key: const u8[:], dflt: bool) -> bool {
    let v, ok = json::as_bool(json::member(args, key));
    return if ok { v } else { dflt };
}

var serve_db: i64 = 0;          // the map the tools answer about; 0 until a repo is selected
var serve_map: u8[..4096];      // serve_db's file, so reselecting the same map is free
var serve_maps: u8[..4096];     // the registry root: a repo's map is <serve_maps>/<name>/swan.db
var serve_warm = false;         // live_warm the new map on the next call: a switch itself stays fast

// One known map's identity, read from its meta.
fn map_meta(db_path: const u8[:], root: u8[>..]&, symbols: u8[>..]&) -> bool {
    var err: u8[>..] = [];
    let h = sqlite::open(db_path, err);
    guard h != 0 else { return false; }
    meta_value(h, "root", root);
    meta_value(h, "symbols", symbols);
    sqlite::close(h);
    return true;
}

// The map covering `abs`: its own root, or the nearest root above it, among
// the <serve_maps>/*/swan.db maps. Returns the map's db path, or "".
fn find_map(abs: const u8[:]) -> u8[>..] {
    var found: u8[>..] = [];
    var best = 0;
    var names: u8[>..] = [];
    guard list_dir(serve_maps, names) else { return found; }
    each_split(names, '\n') { nm =>
        guard nm.len > 0;
        let dbf = str(serve_maps, "/", nm, "/swan.db");
        guard file_exists(dbf);
        var root: u8[>..] = [];
        var ignored: u8[>..] = [];
        guard map_meta(dbf, root, ignored);
        let inside = root.len > 0 && root.len > best &&
                     (abs == root || (starts_with(abs, root) && abs.len > root.len && abs[root.len] == '/'));
        if inside { best = root.len; found.clear(); found.append(dbf); }
    };
    return found;
}

// The map dir for a repo with no map yet: <serve_maps>/<basename>, or
// <basename>-<short hash of the path> when that name is another repo's.
fn map_dir_for(abs: const u8[:]) -> u8[>..] {
    let base = abs[rfind(abs, "/") + 1..];
    var name: u8[>..] = [];
    name.append(base);
    var tries = 0;
    while tries < 100 {
        let dir = str(serve_maps, "/", name);
        guard file_exists(str(dir, "/swan.db")) else { return dir; }
        var root: u8[>..] = [];
        var ignored: u8[>..] = [];
        map_meta(str(dir, "/swan.db"), root, ignored);
        guard root != abs else { return dir; }   // this repo's own map already
        tries++;
        name.clear();
        format(name, base, "-", hash(abs) % 100000);
        if tries > 1 { format(name, "-", tries); }
    }
    return str(serve_maps, "/", name);
}

// Every map under serve_maps, for index_info when no repo is selected yet.
fn list_maps(out: u8[>..]&) {
    out.append("{\"maps\":[");
    var names: u8[>..] = [];
    var n = 0;
    if list_dir(serve_maps, names) {
        each_split(names, '\n') { nm =>
            guard nm.len > 0;
            let dbf = str(serve_maps, "/", nm, "/swan.db");
            guard file_exists(dbf);
            var root: u8[>..] = [];
            var syms: u8[>..] = [];
            guard map_meta(dbf, root, syms);
            if n > 0 { out.push(','); }
            n++;
            out.append("{\"name\":");
            json::format_string(out, nm);
            out.append(",\"root\":");
            json::format_string(out, root);
            out.append(",\"symbols\":");
            let c, ok = parse_int(syms);
            json::format_int(out, if ok { c } else { 0 });
            out.push('}');
        };
    }
    out.append("]}");
}

// Files changed since the map's SCIP run (index_info's stale_file_count).
fn stale_count(db: i64) -> i64 {
    let fs = prepare_or_die(db, "SELECT file FROM files");
    var err: u8[>..] = [];
    var n: i64 = 0;
    while sqlite::step(fs, err) == 1 {
        var f: u8[>..] = [];
        sqlite::col_text(fs, 0, f);
        if is_stale(f) { n++; }
    }
    sqlite::finalize(fs);
    return n;
}

// use_repo and every tool's `repo` argument: point serve_db at the map for
// `path` (its own root, or the nearest mapped root above it), building the
// map first when asked. The answer JSON goes to out; the reason a switch
// was refused goes there as text.
fn repo_switch(path: const u8[:], build: bool, out: u8[>..]&) -> bool {
    guard path.len > 0 else { out.append("path is required"); return false; }
    var abs: u8[>..] = [];
    guard swan_realpath(path, abs) else { format(out, "no such path: ", path); return false; }
    guard is_dir(abs) else { format(out, "not a directory: ", abs); return false; }
    var db_path = find_map(abs);
    var built = false;
    var built_report: u8[>..] = [];
    if db_path.len == 0 {
        guard build else {
            format(out, "no map for ", abs, ": run 'swan map ", abs, " ", serve_maps, "/",
                   abs[rfind(abs, "/") + 1..], "' or call use_repo without build:false");
            return false;
        }
        let dir = map_dir_for(abs);
        guard map_main(abs, dir, built_report) else { out.append(built_report); return false; }
        db_path.append(str(dir, "/swan.db"));
        guard file_exists(db_path) else {
            format(out, "the map ran but left no swan.db in ", dir, ":\n", built_report);
            return false;
        }
        built = true;
    }
    let switched = db_path != serve_map;
    if switched {       // a switch: live server off, old map closed, new one open
        live_stop();
        if serve_db != 0 { close_db(serve_db); }
        serve_db = open_db(db_path);
        serve_map.clear();      // format appends: without this the stored path grows and never matches
        format(serve_map, db_path);
        serve_warm = true;
    }
    var root: u8[>..] = [];
    var syms: u8[>..] = [];
    var files: u8[>..] = [];
    meta_value(serve_db, "root", root);
    meta_value(serve_db, "symbols", syms);
    meta_value(serve_db, "files", files);
    let ns, ok1 = parse_int(syms);
    let nf, ok2 = parse_int(files);
    out.append("{\"root\":");
    json::format_string(out, root);
    out.append(",\"map\":");
    json::format_string(out, db_path);
    out.append(",\"symbols\":");
    json::format_int(out, if ok1 { ns } else { 0 });
    out.append(",\"files\":");
    json::format_int(out, if ok2 { nf } else { 0 });
    out.append(",\"built\":");
    json::format_bool(out, built);
    out.append(",\"switched\":");
    json::format_bool(out, switched);
    out.append(",\"stale_file_count\":");
    json::format_int(out, stale_count(serve_db));
    out.append(",\"skipped\":");
    json::format_string(out, if built { map_held_indexers() } else { "" });
    out.append(",\"report\":");
    json::format_string(out, built_report);
    out.push('}');
    return true;
}

// The request's id, as it came: a number, a string, or null.
fn format_id(out: u8[>..]&, id: json::Node?) {
    guard id else { out.append("null"); return; }
    match id.val {
        Int i => json::format_int(out, i.v),
        Str s => json::format_string(out, s.s),
        _ => out.append("null"),
    }
}

fn reply_head(out: u8[>..]&, id: json::Node?) {
    out.append("{\"jsonrpc\":\"2.0\",\"id\":");
    format_id(out, id);
}

fn call_tool(db: i64, name: const u8[:], args: json::Node?, out: u8[>..]&) -> bool {
    if name == "find_symbol" {
        let pattern = arg_text(args, "name_path_pattern");
        guard pattern.len > 0 else { out.append("name_path_pattern is required"); return false; }
        find_symbol(db, pattern, arg_text(args, "relative_path"), arg_bool(args, "substring_matching"),
                    arg_bool(args, "include_body"), arg_int(args, "max_results", 50), out);
        return true;
    }
    if name == "find_referencing_symbols" {
        let pattern = arg_text(args, "name_path");
        guard pattern.len > 0 else { out.append("name_path is required"); return false; }
        find_referencing_symbols(db, pattern, arg_text(args, "relative_path"),
                                 arg_int(args, "max_results", 500), arg_bool(args, "include_members"), out);
        return true;
    }
    if name == "get_symbol_at" {
        let rel = arg_text(args, "relative_path");
        guard rel.len > 0 else { out.append("relative_path is required"); return false; }
        get_symbol_at(db, rel, arg_int(args, "line", 1), arg_int(args, "column", 1), out);
        return true;
    }
    if name == "get_symbols_overview" {
        let rel = arg_text(args, "relative_path");
        guard rel.len > 0 else { out.append("relative_path is required"); return false; }
        get_symbols_overview(db, rel, out);
        return true;
    }
    if name == "get_callers" || name == "get_callees" {
        let pattern = arg_text(args, "name_path");
        guard pattern.len > 0 else { out.append("name_path is required"); return false; }
        let rel = arg_text(args, "relative_path");
        let limit = arg_int(args, "max_results", 200);
        if name == "get_callers" { get_callers(db, pattern, rel, min(arg_int(args, "depth", 1), 5), limit, out); }
        else { get_callees(db, pattern, rel, limit, out); }
        return true;
    }
    if name == "find_implementations" || name == "get_type_hierarchy" {
        let pattern = arg_text(args, "name_path");
        guard pattern.len > 0 else { out.append("name_path is required"); return false; }
        let rel = arg_text(args, "relative_path");
        let limit = arg_int(args, "max_results", 200);
        if name == "find_implementations" && arg_bool(args, "live") { return live_implementations(db, pattern, rel, out); }
        if name == "find_implementations" { find_implementations(db, pattern, rel, limit, out); }
        else { get_type_hierarchy(db, pattern, rel, min(arg_int(args, "depth", 3), 10), limit, out); }
        return true;
    }
    if name == "find_unused_symbols" {
        find_unused_symbols(db, arg_text(args, "relative_path"), arg_bool(args, "include_tests"),
                            arg_int(args, "max_results", 200), out);
        return true;
    }
    if name == "replace_symbol_body" || name == "insert_after_symbol" || name == "insert_before_symbol" {
        let mode = if name == "replace_symbol_body" { EDIT_REPLACE }
                   else if name == "insert_after_symbol" { EDIT_AFTER } else { EDIT_BEFORE };
        return edit_symbol(db, mode, arg_text(args, "name_path"), arg_text(args, "relative_path"),
                           arg_text(args, "body"), out);
    }
    if name == "rename_symbol" {
        return rename_symbol(db, arg_text(args, "name_path"), arg_text(args, "relative_path"),
                             arg_text(args, "new_name"), arg_bool(args, "apply"), out);
    }
    if name == "get_diagnostics" && arg_bool(args, "live") { return live_diagnostics(db, arg_text(args, "relative_path"), out); }
    if name == "get_diagnostics" {
        return get_diagnostics(db, arg_text(args, "name_path"), arg_text(args, "relative_path"),
                               min(arg_int(args, "depth", 1), 5), arg_bool(args, "errors_only"),
                               arg_int(args, "max_results", 200), out);
    }
    if name == "run_tests" || name == "format_file" {
        var root: u8[>..] = [];
        var dir: u8[>..] = [];
        meta_value(db, "root", root);
        meta_value(db, "source", dir);
        guard root.len > 0 && dir.len > 0 else { out.append("the map does not record its repo; rebuild it with swan map"); return false; }
        var report: u8[>..] = [];
        let np = arg_text(args, "name_path");
        let rel = arg_text(args, "relative_path");
        let ok = if name == "format_file" { format_main(root, dir, str(rel, "\n"), report) }
                 else { test_main(root, dir, if np.len > 0 { np } else { rel }, if np.len > 0 { rel } else { "" },
                                  min(arg_int(args, "depth", 3), 6), report) };
        json::format_string(out, report);
        return ok;
    }
    if name == "update_map" || name == "check_errors" {
        var root: u8[>..] = [];
        var dir: u8[>..] = [];
        meta_value(db, "root", root);
        meta_value(db, "source", dir);
        guard root.len > 0 && dir.len > 0 else { out.append("the map does not record its repo; rebuild it with swan map"); return false; }
        var report: u8[>..] = [];
        let ok = if name == "update_map" { map_main(root, dir, report) } else { check_main(root, dir, report) };
        if name == "update_map" { load_freshness(db); }     // the map has a new SCIP time
        json::format_string(out, report);
        return ok;
    }
    if name == "search_pattern" {
        return search_pattern(db, arg_text(args, "pattern"), arg_text(args, "language"), arg_text(args, "relative_path"),
                              arg_int(args, "max_results", 200), out);
    }
    if name == "rewrite_pattern" {
        return rewrite_pattern(db, arg_text(args, "pattern"), arg_text(args, "rewrite"), arg_text(args, "language"),
                               arg_text(args, "relative_path"), arg_bool(args, "apply"), out);
    }
    if name == "index_info" { index_info(db, out); return true; }
    out.append(str("unknown tool: ", name));
    return false;
}

// `swan serve <db>`: one map for the server's whole life, as before; `repo`
// arguments and use_repo still work, against <swan-home>/data.
fn serve_main(db_path: const u8[:]) {
    format(serve_maps, swan_home(), "/data");
    serve_db = open_db(db_path);
    format(serve_map, db_path);
    serve_loop();
}

// `swan serve --maps <data-root>` (or bare `swan serve`, for
// <swan-home>/data): no repo selected until use_repo or a `repo` argument
// names one; its map is found or built under serve_maps.
fn serve_any(root: const u8[:]) {
    var r: u8[>..] = [];
    if !swan_realpath(root, r) { r.append(root); }
    if r.len > 0 && r[r.len - 1] == '/' { r.pop(); }
    format(serve_maps, r);
    serve_loop();
}

fn serve_loop() {
    var warmed = false;
    loop {
        var line: u8[>..] = [];
        guard read_line(line) else { break; }
        guard trim(line).len > 0 else { continue; }
        var doc: json::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, perr = json::parse(line, doc, decoded);
        var out: u8[>..] = [];
        guard root else {
            out.append("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":");
            json::format_string(out, perr);
            out.append("}}\n");
            write_stdout(out);
            flush_stdout();
            continue;
        }
        let method = arg_text(root, "method");
        let is_init = method == "initialize";
        let id = json::member(root, "id");
        guard id else { continue; }     // a notification: nothing to answer
        let params = json::member(root, "params");
        reply_head(out, id);
        if method == "initialize" {
            var version = arg_text(params, "protocolVersion");
            if version.len == 0 { version = "2025-06-18"; }
            out.append(",\"result\":{\"protocolVersion\":");
            json::format_string(out, version);
            out.append(",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"swan\",\"version\":");
            json::format_string(out, SWAN_VERSION);
            out.append("}}}");
        } else if method == "ping" {
            out.append(",\"result\":{}}");
        } else if method == "tools/list" {
            out.append(",\"result\":{\"tools\":");
            for ch in trim(TOOLS) { if ch != '\n' { out.push(ch); } }   // one line per message
            out.append("}}");
        } else if method == "tools/call" {
            var payload: u8[>..] = [];
            var tool_name: u8[>..] = [];    // owned: a tool may grow buffers the request's text could point into
            tool_name.append(arg_text(params, "name"));
            let targs = json::member(params, "arguments");
            var ok = true;
            if tool_name == "use_repo" {
                var p: u8[>..] = [];
                p.append(arg_text(targs, "path"));
                ok = repo_switch(p, arg_bool_default(targs, "build", true), payload);
            } else {
                var rp: u8[>..] = [];
                rp.append(arg_text(targs, "repo"));
                if rp.len > 0 {
                    ok = repo_switch(rp, true, payload);
                    if ok { payload.clear(); }      // the tool's own answer follows, not use_repo's
                }
                if ok && serve_db == 0 {
                    if tool_name == "index_info" { list_maps(payload); }
                    else { payload.append("no repo selected: call use_repo with a path, or pass repo"); ok = false; }
                } else if ok {
                    if serve_warm { serve_warm = false; live_warm(serve_db); }
                    ok = call_tool(serve_db, tool_name, targs, payload);
                }
            }
            out.append(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
            json::format_string(out, payload);
            out.append("}],\"isError\":");
            json::format_bool(out, !ok);
            out.append("}}");
        } else {
            out.append(",\"error\":{\"code\":-32601,\"message\":");
            json::format_string(out, str("method not found: ", method));
            out.append("}}");
        }
        out.push('\n');
        write_stdout(out);
        flush_stdout();
        if is_init && !warmed { warmed = true; if serve_db != 0 { live_warm(serve_db); } }
    }
    live_stop();
    if serve_db != 0 { close_db(serve_db); }
}
