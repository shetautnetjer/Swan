// `swan serve`: the MCP server, JSON-RPC 2.0 over stdio, one message per
// line. It answers initialize, ping, tools/list and tools/call from the
// SQLite map and needs nothing else running.

import std;
import os;
import json;
import sqlite;

let SWAN_VERSION = "0.1.0";

let TOOLS = """
    [{"name":"use_repo","description":"Choose the repository the tools answer about, building its code map the first time (the trust rules of `swan map` apply: indexers that run the repo's build files wait for `swan trust`, and the answer's `skipped` says which). `path` is the repo's root or a path inside it. With `build` false an unmapped repo is an error that names the `swan map` command to run. Returns the repo root, the map file, symbol and file counts, files changed since the map, and the map report. The choice persists; any tool's `repo` argument switches the same way.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."}},"required":["path"]}},
     {"name":"find_symbol","description":"Find symbols by name path. 'add' matches any symbol named add, 'Store/add' any whose name path ends that way, '/Store/add' only that exact path. Returns kind, signature, file, 1-based line and body line range; include_body adds the source.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path_pattern":{"type":"string"},"relative_path":{"type":"string","description":"Only symbols defined in this file or directory."},"substring_matching":{"type":"boolean","description":"Match the last name as a substring (no '/' in the pattern)."},"include_body":{"type":"boolean"},"max_results":{"type":"integer"}},"required":["name_path_pattern"]}},
     {"name":"find_referencing_symbols","description":"Find every reference (import lines included, marked import) to the symbols a name path matches, from the compiler's own resolution (SCIP), including through re-exports and renamed imports. Each reference gives file, 1-based line and column, the symbol it sits inside (in_symbol), and its line of source. Rust uses inside macro calls that rust-analyzer could not resolve are matched by name and marked by_name. include_members also counts uses through what the symbol holds (enum variants, methods, fields; Rust impl functions), each marked with via: use it for 'where is this type used'.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path":{"type":"string"},"include_members":{"type":"boolean"},"relative_path":{"type":"string","description":"The file or directory that defines the symbol, to pick one of several matches."},"max_results":{"type":"integer","description":"References per symbol (default 500)."}},"required":["name_path"]}},
     {"name":"get_symbol_at","description":"What is at a position: the symbol a file's line and column (1-based) refer to, with its kind, signature, where it is defined (file, line, body lines) or which package it comes from, whether this spot is its definition or an import, and the symbol the position sits inside. JetBrains' get_symbol_info. When nothing covers that column, the line's symbols are listed instead.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"relative_path":{"type":"string"},"line":{"type":"integer"},"column":{"type":"integer"}},"required":["relative_path","line","column"]}},
     {"name":"get_symbols_overview","description":"List the symbols a file defines (or every file under a directory), with name paths, kinds and 1-based lines.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"relative_path":{"type":"string"}},"required":["relative_path"]}},
     {"name":"get_callers","description":"Who calls or uses a symbol (import lines left out), and who uses those, up to depth steps (default 1, max 5): the impact radius of changing it. Every reference counts (calls, type uses, imports). Each caller has its distance, is_test and call_sites (the exact file:line of each use, so top-level code and anonymous callbacks such as test bodies are pinpointed, not just their file); the summary counts all affected symbols and files and lists the test files to run.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path":{"type":"string"},"relative_path":{"type":"string","description":"The file or directory that defines the symbol."},"depth":{"type":"integer"},"max_results":{"type":"integer","description":"Callers listed (default 200); the summary covers all."}},"required":["name_path"]}},
     {"name":"get_callees","description":"What a function, method or class body uses: the symbols it calls or references, with use counts. calls_only:true keeps only what can be called (functions, methods, constructors, macros and classes), dropping properties, variables, constants and types. Symbols from dependencies show their package and version instead of a file.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"calls_only":{"type":"boolean","description":"Only functions, methods, constructors, macros and classes (default false: every symbol the body references)."},"max_results":{"type":"integer"}},"required":["name_path"]}},
     {"name":"find_implementations","description":"What implements, extends or overrides a symbol, from the compiler's own view (SCIP): the classes behind an interface, the subclasses of a class, the overrides of a method. Each result has its distance (1 = direct).","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"max_results":{"type":"integer"},"live":{"type":"boolean","description":"Ask the running language server (rust-analyzer) instead of the map: sees edits made since the last map; each location comes with its line of source."}},"required":["name_path"]}},
     {"name":"get_type_hierarchy","description":"A symbol's supertypes (what it implements, extends or overrides) and subtypes (what implements, extends or overrides it), up to depth steps each way (default 3).","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"depth":{"type":"integer"},"max_results":{"type":"integer"}},"required":["name_path"]}},
     {"name":"find_unused_symbols","description":"Functions, classes, methods, types and variables defined in the repo that nothing references or implements. Candidates for removal, not proof: entry points and code reached by name at run time also appear. Test files are skipped unless include_tests.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"relative_path":{"type":"string","description":"Only this file or directory."},"include_tests":{"type":"boolean"},"max_results":{"type":"integer","description":"Listed (default 200); total counts all."}}}},
     {"name":"replace_symbol_body","description":"Replace a symbol's whole definition (signature included, as find_symbol with include_body shows it) with new code. Read the body first. Refused if the file changed since the map was built. Returns the new line range and how many places use the symbol, so you know what to check.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path":{"type":"string"},"relative_path":{"type":"string","description":"The file that defines the symbol (required)."},"body":{"type":"string"}},"required":["name_path","relative_path","body"]}},
     {"name":"insert_after_symbol","description":"Insert code after a function, method or class definition, one blank line apart. Include the indentation you want.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"body":{"type":"string"}},"required":["name_path","relative_path","body"]}},
     {"name":"insert_before_symbol","description":"Insert code before a symbol's definition, one blank line apart: a new function, class or import before an existing one.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"body":{"type":"string"}},"required":["name_path","relative_path","body"]}},
     {"name":"rename_symbol","description":"Rename a symbol at every use the compiler resolved, across files. By default only plans: every site, sites skipped because their text differs (aliases, re-exports), conflicts with an existing symbol of the new name, and stale files. Set apply to true to write it; a conflict or a stale file refuses. Strings, comments and uses by name at run time are not covered.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path":{"type":"string"},"relative_path":{"type":"string","description":"The file that defines the symbol (required)."},"new_name":{"type":"string"},"apply":{"type":"boolean"}},"required":["name_path","relative_path","new_name"]}},
     {"name":"get_diagnostics","description":"Compiler errors and warnings (tsc, cargo check) from the last check, each pinned to the symbol it is in. With name_path: the symbol's own diagnostics plus, up to depth steps out (default 1), those of the symbols that use it: where an edit to it shows up as breakage. With only relative_path: a file or directory. With neither: everything. Entries in files changed since the check say stale.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"depth":{"type":"integer"},"errors_only":{"type":"boolean"},"max_results":{"type":"integer"},"live":{"type":"boolean","description":"Ask the running language server (rust-analyzer) about the one file in relative_path, as it is on disk now: errors seconds after an edit, without check_errors. The first call starts the server and waits for it to index."}}}},
     {"name":"what_broke","description":"Call after editing: the errors the language server reports now in the files you just wrote that it did not report the last time this was asked, so you hear about a break when you make it and not again about errors that were already there. files: repo-relative paths. Needs a live server for the language (Python, TypeScript, Java; Rust, Kotlin and C# once the repo is trusted). On a first look at a file every error counts as new.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"files":{"type":"array","items":{"type":"string"}}},"required":["files"]}},
     {"name":"update_map","description":"Bring the map up to date after edits: reruns the SCIP indexers over the repo and rewrites only the files whose data changed. Takes as long as the indexers (seconds on small repos, minutes on large ones).","inputSchema":{"type":"object","properties":{"clean":{"type":"boolean","description":"Rebuild the selected existing map without reusing indexer output or merge layers (default false). Requires repo to be the exact map root. Preserves the previous database until all indexers and the replacement database succeed; keeps trust unchanged."},"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."}}}},
     {"name":"check_errors","description":"Run the repo's own checkers (tsc with the repo's tsconfig, cargo check, pyright) and load what they report, so get_diagnostics answers from fresh results.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."}}}},
     {"name":"run_tests","description":"Run the tests that reach a symbol through calls (up to depth steps, default 3), or the tests that reach anything a file defines when relative_path names a file and name_path is empty. Uses each language's test runner from tools/modules.json (pytest, bun test / vitest, cargo test). Returns which test files ran, pass or fail, and the runner's output tail.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"name_path":{"type":"string"},"relative_path":{"type":"string"},"depth":{"type":"integer"}}}},
     {"name":"format_file","description":"Run a file through its language's formatter from tools/modules.json (ruff format, biome format, rustfmt). The file's positions in the map are stale afterwards until update_map.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"relative_path":{"type":"string"}},"required":["relative_path"]}},
     {"name":"search_pattern","description":"Structural search, ast-grep style: a pattern is code in the target language with metavariables, $X for any one node and $$$X for any run of nodes (none included); $_ matches without capturing, and a name used twice must match the same text. Matches by syntax tree, not text (so spacing and comments do not matter), in TS/TSX/JS, Python, Rust, Java, Kotlin, C, C++, CUDA, C#, PHP, Lua, GDScript and the GLSL, HLSL and WGSL shading languages via tree-sitter. Each match has its position, what each metavariable captured, and the symbol it sits in.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"pattern":{"type":"string"},"language":{"type":"string","description":"typescript, tsx, javascript, python, rust, java, kotlin, c, cpp, cuda, csharp, php, lua, gdscript, glsl, hlsl or wgsl; default every language the pattern parses in."},"relative_path":{"type":"string","description":"A file or directory to search; default the whole repo."},"max_results":{"type":"integer"}},"required":["pattern"]}},
     {"name":"rewrite_pattern","description":"Structural rewrite: every match of pattern (as in search_pattern) replaced by rewrite, where $X and $$$X stand for what they captured. Without apply it only plans the edits (before and after for each); apply writes them, refused when a file changed since the map was built. Nested matches are left to the outer one. Rewritten files are stale in the map until update_map.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"pattern":{"type":"string"},"rewrite":{"type":"string"},"language":{"type":"string"},"relative_path":{"type":"string"},"apply":{"type":"boolean"}},"required":["pattern","rewrite"]}},
     {"name":"edit_batch","description":"Several edits as one change, all or nothing: the way to make a change that reaches more than one place. edits is a list; each item has op (rename_symbol, replace_symbol_body, insert_after_symbol, insert_before_symbol or rewrite_pattern) and that tool's own arguments. Without apply every edit is planned against the code as it is now and nothing is written; the plan's touches part (from Spread-Wings, when installed) lists the files that call or import the renamed or rewritten symbols but are not edited, and the tests to run. With apply they run in the order given, each seeing what the earlier ones changed; if one fails or is refused, the map and every file already written go back to what they were. Afterwards: update_map, then get_diagnostics or run_tests for the files written.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."},"edits":{"type":"array","items":{"type":"object","properties":{"op":{"type":"string"},"name_path":{"type":"string"},"relative_path":{"type":"string"},"new_name":{"type":"string"},"body":{"type":"string"},"pattern":{"type":"string"},"rewrite":{"type":"string"},"language":{"type":"string"}},"required":["op"]}},"apply":{"type":"boolean"}},"required":["edits"]}},
     {"name":"index_info","description":"When and from what the code map was built: repo root, build time, counts, and the files changed since the SCIP run or added since then (stale_files; new_file_count of them are new, so no answer covers them yet). Answers about a stale file carry \"stale\": true; refresh the map or reread the file.","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"A repo path: answer about that repo's map instead (as use_repo; the choice persists)."},"build":{"type":"boolean","description":"Allow an implicit build when no usable map covers the repo (default true). Applies only to repository selection, not explicit tool actions or live warm-up."}}}}]
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

// Selection policy for this request only. Missing keeps the legacy default;
// a supplied null or other non-boolean must never become permission to build.
fn request_build(args: json::Node?) -> bool, bool {
    let setting = json::member(args, "build");
    guard setting else { return true, true; }
    let value, ok = json::as_bool(setting);
    return value, ok;
}

fn request_clean(args: json::Node?) -> bool, bool {
    let setting = json::member(args, "clean");
    guard setting else { return false, true; }
    let value, ok = json::as_bool(setting);
    return value, ok;
}

var serve_db: i64 = 0;          // the map the tools answer about; 0 until a repo is selected
var serve_map: u8[..4096];      // reopen this path at each tool request, including after replacement
var serve_maps: u8[..4096];     // the registry root: a repo's map is <serve_maps>/<name>/swan.db
var serve_warm = false;         // live_warm the new map on the next call: a switch itself stays fast
var serve_root: u8[..4096];     // live state belongs to this repo/source, not a database inode
var serve_source: u8[..4096];
var serve_map_error: u8[..4096]; // contention during registry discovery is not an absent map
var serve_snapshot = false;     // a read-only tool holds one database generation until its answer is built

// These tools read the map only (get_callers uses a connection-local temp
// table). Live answers, edits and commands that run writers are excluded.
// The transaction covers database rows, not concurrent changes to source
// files on disk; those still use the existing freshness checks.
fn tool_reads_map(name: const u8[:], args: json::Node?) -> bool {
    if (name == "find_implementations" || name == "get_diagnostics") && arg_bool(args, "live") { return false; }
    return name == "use_repo" || name == "find_symbol" || name == "find_referencing_symbols" ||
           name == "get_symbol_at" || name == "get_symbols_overview" || name == "get_callers" ||
           name == "get_callees" || name == "find_implementations" || name == "get_type_hierarchy" ||
           name == "find_unused_symbols" || name == "get_diagnostics" || name == "search_pattern" ||
           name == "index_info";
}

fn map_covers(root: const u8[:], path: const u8[:]) -> bool {
    return root.len > 0 && (path == root ||
           (starts_with(path, root) && path.len > root.len && path[root.len] == '/'));
}

// A meta value from a map that may be damaged or foreign: unlike meta_value
// (prepare_or_die), a missing meta table or a corrupt file returns false, so
// one bad swan.db under the data root can't stop the server.
fn meta_try(h: i64, key: const u8[:], out: u8[>..]&, err: u8[>..]&) -> bool {
    let st = sqlite::prepare(h, "SELECT value FROM meta WHERE key = ?1", err);
    guard st != 0 else { return false; }
    sqlite::bind_text(st, 1, key);
    let result = sqlite::step(st, err);
    if result == 1 { sqlite::col_text(st, 0, out); }
    sqlite::finalize(st);
    return result >= 0;
}

// Foreign/corrupt registry entries can still be skipped. A locked map may
// be the requested repo's current map: never mistake it for an unmapped repo
// and launch a build. SQLite's messages are retained in the tool error.
fn map_access_error(err: const u8[:]) {
    if serve_map_error.len == 0 && (find(err, "locked") >= 0 || find(err, "busy") >= 0) {
        format(serve_map_error, "swan: cannot read map: ", err);
    }
}

// One known map's identity, read from its meta; false for a map that can't be read.
fn map_meta(db_path: const u8[:], root: u8[>..]&, symbols: u8[>..]&) -> bool {
    var err: u8[>..] = [];
    let h = sqlite::open_existing(db_path, err);
    guard h != 0 else { map_access_error(err); return false; }
    let ok = meta_try(h, "root", root, err) && meta_try(h, "symbols", symbols, err);
    sqlite::close(h);
    if !ok { map_access_error(err); }
    return ok && root.len > 0;
}

fn map_schema_current(db_path: const u8[:]) -> bool {
    var err: u8[>..] = [];
    let h = sqlite::open_existing(db_path, err);
    guard h != 0 else { map_access_error(err); return false; }
    var v: u8[>..] = [];
    let ok = meta_try(h, "schema_version", v, err);
    sqlite::close(h);
    if !ok { map_access_error(err); }
    return ok && v == str(SCHEMA_VERSION);
}

// A connection continues reading the old inode after a full index replaces
// swan.db. Reopen the path before each request, so completed replacements and
// refreshes (including scip_time and edited_mtime) are visible on the next
// call. Failed opens/metadata reads are tool errors and never use the old map.
fn serve_reopen(db_path: const u8[:], snapshot: bool, repo: const u8[:], out: u8[>..]&) -> bool {
    var err: u8[>..] = [];
    let h = sqlite::open_existing(db_path, err);
    guard h != 0 else { format(out, "swan: cannot open map ", db_path, ": ", err); return false; }
    if snapshot && !sqlite::exec(h, "BEGIN;", err) {
        sqlite::close(h);
        format(out, "swan: cannot start map read: ", err);
        return false;
    }
    var version: u8[>..] = [];
    var root: u8[>..] = [];
    var source: u8[>..] = [];
    let ok = meta_try(h, "schema_version", version, err) &&
             meta_try(h, "root", root, err) && meta_try(h, "source", source, err);
    if !ok || version != str(SCHEMA_VERSION) {
        sqlite::close(h);
        if !ok { format(out, "swan: cannot read map ", db_path, ": ", err); }
        else { format(out, "swan: index schema ", version, ", this swan reads ", SCHEMA_VERSION, "; rebuild the map"); }
        return false;
    }
    if repo.len > 0 && !map_covers(root, repo) {
        sqlite::close(h);
        format(out, "swan: map changed during repository selection; retry use_repo for ", repo);
        return false;
    }
    if root != serve_root || source != serve_source {
        live_stop();
        serve_warm = true;
    }
    if serve_db != 0 { close_db(serve_db); }
    serve_db = h;
    serve_snapshot = snapshot;
    load_freshness(serve_db);
    serve_root.clear(); format(serve_root, root);
    serve_source.clear(); format(serve_source, source);
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
        // A map from an older Swan, or a damaged/foreign swan.db, can't be opened by this one
        // (open_db would abort the server); skip it.
        guard map_schema_current(dbf);
        guard map_meta(dbf, root, ignored);
        let inside = root.len > best && map_covers(root, abs);
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

// Files changed since the map's SCIP run, or added since (index_info's
// stale_file_count).
fn stale_count(db: i64) -> i64 {
    let fs = prepare_or_die(db, "SELECT file FROM files");
    var err: u8[>..] = [];
    var n: i64 = 0;
    while step_checked(fs, err) == 1 {
        var f: u8[>..] = [];
        sqlite::col_text(fs, 0, f);
        if is_stale(f) { n++; }
    }
    sqlite::finalize(fs);
    var added: u8[>..] = [];
    n += new_files(db, added);
    return n;
}

// use_repo and every tool's `repo` argument: point serve_db at the map for
// `path` (its own root, or the nearest mapped root above it), building the
// map first when asked. The answer JSON goes to out; the reason a switch
// was refused goes there as text.
// `summary`: write use_repo's answer (counts and the freshness scan). A tool's
// implicit `repo` switch passes false: its own answer replaces this one, and
// the freshness scan stats every mapped file.
fn repo_switch(path: const u8[:], build: bool, summary: bool, snapshot: bool, out: u8[>..]&) -> bool {
    guard path.len > 0 else { out.append("path is required"); return false; }
    var abs: u8[>..] = [];
    guard swan_realpath(path, abs) else { format(out, "no such path: ", path); return false; }
    guard is_dir(abs) else { format(out, "not a directory: ", abs); return false; }
    var db_path = find_map(abs);
    guard serve_map_error.len == 0 else { out.append(serve_map_error); return false; }
    var built = false;
    var built_report: u8[>..] = [];
    if db_path.len == 0 {
        guard build else {
            // The same collision-safe dir an automatic build would use, so following
            // the hint never overwrites another repo's map of the same basename.
            let dir = map_dir_for(abs);
            guard serve_map_error.len == 0 else { out.append(serve_map_error); return false; }
            format(out, "no map for ", abs, ": run 'swan map ", abs, " ", dir,
                   "' or call use_repo without build:false");
            return false;
        }
        let dir = map_dir_for(abs);
        guard serve_map_error.len == 0 else { out.append(serve_map_error); return false; }
        guard map_main(abs, dir, built_report) else { out.append(built_report); return false; }
        db_path.append(str(dir, "/swan.db"));
        guard file_exists(db_path) else {
            format(out, "the map ran but left no swan.db in ", dir, ":\n", built_report);
            return false;
        }
        built = true;
    }
    let switched = db_path != serve_map;
    guard serve_reopen(db_path, snapshot, abs, out) else { return false; }
    if switched {
        serve_map.clear();      // format appends: without this the stored path grows and never matches
        format(serve_map, db_path);
    }
    guard summary else { return true; }
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

// Several edits as one change: planned together, applied in the order
// given, all or nothing. The usual way to make a change that reaches more
// than one place: rename this, replace that body, insert a helper, rewrite
// a pattern, in one call.
//
// Without `apply` each edit is planned against the code as it is now: a
// rename's sites, a rewrite's edits, whether a symbol edit's target is
// there and its file fresh. Nothing is written.
//
// With `apply` the edits run in order; an edit sees what the ones before
// it changed (Swan moves its rows as it edits). If one fails or is refused,
// the map goes back to where it was (one savepoint around them all) and
// every file already written gets its old text back, so there is never
// half a change on disk.
fn edit_batch(db: i64, args: json::Node?, out: u8[>..]&) -> bool {
    let edits = json::member(args, "edits");
    guard edits else {
        out.append("edits is required: a list of {\"op\": ...} where op is rename_symbol, replace_symbol_body, insert_after_symbol, insert_before_symbol or rewrite_pattern, each with that tool's own arguments");
        return false;
    }
    let apply = arg_bool(args, "apply");
    var root: u8[>..] = [];
    meta_value(db, "root", root);

    // The text of every file an edit is about to write, taken before it does.
    var snap_names: u8[>..] = [];      // relative paths, one per line, in order
    var snap_text: u8[>..] = [];
    var snap_at: i64[>..] = [];
    var snap_len: i64[>..] = [];
    fn snapshot(rel: const u8[:]) {
        guard rel.len > 0;
        var have = false;
        each_split(snap_names, '\n') { n => if n == rel { have = true; } };
        guard !have;
        var text: u8[>..] = [];
        guard read_file(str(root, "/", rel), text);
        format(snap_names, rel, "\n");
        snap_at.push(snap_text.len);
        snap_len.push(text.len);
        snap_text.append(text);
    }
    // The files a planned rename or rewrite names ("sites" or "edits").
    fn snapshot_plan(plan: const u8[:]) {
        var doc: json::Node[>..] = [];
        var dec: u8[>..] = [];
        let r, perr = json::parse(plan, doc, dec);
        guard r;
        for key in ["sites", "edits"] {
            let list = json::member(r, key);
            if list { json::each(list) { it => let f, f_ok = json::as_string(json::member(it, "relative_path")); if f_ok { snapshot(f); } }; }
        }
    }

    var results: u8[>..] = [];
    var n = 0;
    var failed_at = 0;                 // 1-based, 0 = none
    // For a plan: the symbols whose callers the batch changes (renames and
    // replaced bodies), and every file the batch edits; Spread-Wings is asked
    // what the first reach beyond the second.
    var asks: u8[>..] = [];
    var planned: u8[>..] = [];
    fn plan_files(plan: const u8[:]) {
        var doc: json::Node[>..] = [];
        var dec: u8[>..] = [];
        let r, perr = json::parse(plan, doc, dec);
        guard r;
        for key in ["sites", "edits"] {
            let list = json::member(r, key);
            if list { json::each(list) { it => let f, f_ok = json::as_string(json::member(it, "relative_path")); if f_ok { format(planned, f, "\n"); } }; }
        }
    }
    if apply { exec_or_die(db, "SAVEPOINT swan_batch;"); }
    // The edits, copied out of the request first (fields 0x1f apart, edits
    // 0x1e apart): the edit functions reuse buffers the request's JSON may
    // sit in.
    var packed: u8[>..] = [];
    json::each(edits) { e =>
        for key in ["op", "relative_path", "name_path", "new_name", "body", "pattern", "rewrite", "language"] {
            packed.append(arg_text(e, key));
            packed.push(0x1f);
        }
        packed.push(0x1e);
    };
    each_split(packed, 0x1e) { rec =>
        let f = split(rec, 0x1f);
        if failed_at == 0 && f.len >= 8 {
            n++;
            let op = f[0];
            let rel = f[1];
            let name_path = f[2];
            var sub: u8[>..] = [];
            var ok = false;
            if op == "rename_symbol" {
                if apply {
                    var plan: u8[>..] = [];
                    rename_symbol(db, name_path, rel, f[3], false, plan);
                    snapshot_plan(plan);
                }
                ok = rename_symbol(db, name_path, rel, f[3], apply, sub);
            } else if op == "rewrite_pattern" {
                if apply {
                    var plan: u8[>..] = [];
                    rewrite_pattern(db, f[5], f[6], f[7], rel, false, plan);
                    snapshot_plan(plan);
                }
                ok = rewrite_pattern(db, f[5], f[6], f[7], rel, apply, sub);
            } else if op == "replace_symbol_body" || op == "insert_after_symbol" || op == "insert_before_symbol" {
                let mode = if op == "replace_symbol_body" { EDIT_REPLACE } else if op == "insert_after_symbol" { EDIT_AFTER } else { EDIT_BEFORE };
                if apply {
                    snapshot(rel);
                    ok = edit_symbol(db, mode, name_path, rel, f[4], sub);
                } else {
                    // Planned: the target is there and its file can be edited.
                    var terr: u8[>..] = [];
                    let t = resolve_target(db, name_path, rel, terr);
                    if t.id < 0 { sub.append(terr); }
                    else if is_stale(rel) { format(sub, rel, " changed since the map was built; refresh the map first"); }
                    else {
                        sub.append("{\"target\":");
                        json::format_string(sub, name_path);
                        sub.append(",\"relative_path\":");
                        json::format_string(sub, rel);
                        sub.push('}');
                        ok = true;
                    }
                }
            } else {
                format(sub, "unknown op '", op, "': use rename_symbol, replace_symbol_body, insert_after_symbol, insert_before_symbol or rewrite_pattern");
            }
            if !apply && ok {
                if op == "rename_symbol" || op == "replace_symbol_body" {
                    format(asks, n, "\x1f", name_path, "\x1f", rel, "\x1e");
                }
                if op == "rename_symbol" || op == "rewrite_pattern" { plan_files(sub); } else { format(planned, rel, "\n"); }
            }
            // An applied rename or rewrite that was refused says so in its answer.
            if apply && ok && find(sub, "\"applied\":false") >= 0 { ok = false; }
            if !ok && apply { failed_at = n; }
            if results.len > 0 { results.push(','); }
            results.append("{\"op\":");
            json::format_string(results, op);
            results.append(",\"ok\":");
            json::format_bool(results, ok);
            results.append(",\"result\":");
            if sub.len > 0 && sub[0] == '{' { results.append(sub); } else { json::format_string(results, sub); }
            results.push('}');
        }
    };

    var files: u8[>..] = [];
    each_split(snap_names, '\n') { f => if f.len > 0 { if files.len > 0 { files.push(','); } json::format_string(files, f); } };
    if !apply {
        var touches: u8[>..] = [];
        wings_report(db, serve_map, root, asks, planned, touches);
        format(out, "{\"applied\":false,\"edits\":[", results, "],\"touches\":", touches, ",\"note\":\"each edit is planned against the code as it is now; with apply they run in this order, all or nothing\"}");
        return true;
    }
    if failed_at == 0 {
        exec_or_die(db, "RELEASE swan_batch;");
        format(out, "{\"applied\":true,\"edits\":[", results, "],\"files_written\":[", files,
               "],\"next\":\"update_map, then get_diagnostics or run_tests for these files\"}");
        return true;
    }
    // One edit failed: the map and the files go back.
    exec_or_die(db, "ROLLBACK TO swan_batch; RELEASE swan_batch;");
    var restored = 0;
    var k = 0;
    each_split(snap_names, '\n') { f =>
        if f.len > 0 {
            let path = str(root, "/", f);
            let was = snap_text[snap_at[k]..snap_at[k] + snap_len[k]];
            var now: u8[>..] = [];
            if !read_file(path, now) || now != was {
                if write_file_atomic(path, was) { mark_edited(db, f, path); restored++; }
            }
            k++;
        }
    };
    format(out, "{\"applied\":false,\"failed_at\":", failed_at, ",\"rolled_back\":true,\"files_restored\":", restored,
           ",\"edits\":[", results, "]}");
    return false;
}

fn call_tool(db: i64, name: const u8[:], args: json::Node?, out: u8[>..]&) -> bool {
    if name == "edit_batch" { return edit_batch(db, args, out); }
    if name == "what_broke" {
        let fl = json::member(args, "files");
        guard fl else { out.append("files is required: the repo-relative paths you just edited"); return false; }
        var files: u8[>..] = [];
        json::each(fl) { f => let s, s_ok = json::as_string(f); if s_ok { format(files, s, "\n"); } };
        return what_broke(db, serve_map[..rfind(serve_map, "/")], files, out) >= 0;
    }
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
        else { get_callees(db, pattern, rel, arg_bool(args, "calls_only"), limit, out); }
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
        let clean = name == "update_map" && arg_bool(args, "clean");
        if clean {
            guard abs_path(arg_text(args, "repo")) == root else {
                out.append("clean rebuild requires repo to be the exact recorded root, not a path inside an ancestor map"); return false;
            }
            var recorded_map: u8[>..] = [];
            var selected_map: u8[>..] = [];
            guard swan_realpath(str(dir, "/swan.db"), recorded_map) && swan_realpath(serve_map, selected_map) && recorded_map == selected_map else {
                out.append("clean rebuild refused: selected map does not match its recorded output directory"); return false;
            }
        }
        var report: u8[>..] = [];
        let ok = if name == "update_map" { map_main(root, dir, report, clean) } else { check_main(root, dir, report) };
        // The next tool request reopens the published map and its freshness.
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
    var err: u8[>..] = [];
    if !serve_reopen(db_path, false, "", err) { abort(err); }
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

// Moving to a new build without the agent: agents start Swan through a
// link (swan-up's <root>/current/bin/swan, or ~/.local/bin/swan to it).
// When `swan-up update` points that link at another version, the server
// replaces itself with the new build between two requests: same process,
// same pipes, the same repo selected, live servers started again. The agent
// is told the tool list may have changed. $SWAN_NO_RESTART=1 turns it off.
extern fn swan_reexec(path: const u8[:], argv: const u8[:], env: const u8[:]) -> bool;

var serve_launch: u8[..4096];      // the path this server was started by, absolute, links not followed

fn launch_path_init() {
    let a = args();
    guard a.len > 0 && find(a[0], "/") >= 0;
    if a[0][0] == '/' { format(serve_launch, a[0]); return; }
    var cwd: u8[>..] = [];
    guard swan_realpath(".", cwd);
    format(serve_launch, cwd, "/", a[0]);
}

// The build the launch path leads to now, when it is another file than the
// one running; "" otherwise. A binary rewritten in place (a dev rebuild) is
// the same file: no restart, so a half-written one is never started.
fn restart_target() -> u8[>..] {
    var none: u8[>..] = [];
    guard serve_launch.len > 0 else { return none; }
    var v: u8[>..] = [];
    guard !(env("SWAN_NO_RESTART", v) && v == "1") else { return none; }
    var now: u8[>..] = [];
    guard swan_realpath(serve_launch, now) && file_exists(now) else { return none; }
    var exe: u8[>..] = [];
    guard swan_exe_path(exe) else { return none; }
    var cur: u8[>..] = [];
    cur.append(if ends_with(exe, " (deleted)") { exe[..exe.len - 10] } else { exe[..] });
    guard now != cur else { return none; }
    return now;
}

// Replace this server with `target`, keeping the selected repo. Returns
// only if that could not happen now (it is tried again after the next answer).
fn restart_into(target: const u8[:]) {
    var a: u8[>..] = [];
    arg(a, serve_launch);
    arg(a, "serve");
    arg(a, "--maps");
    arg(a, serve_maps);
    var e: u8[>..] = [];
    arg(e, "SWAN_RESTARTED=1");
    arg(e, str("SWAN_RESTART_MAP=", serve_map));
    live_stop();
    if serve_db != 0 { close_db(serve_db); serve_db = 0; }
    write_stderr(str("swan serve: moving to ", target, "\n"));
    if !swan_reexec(target, a, e) {
        write_stderr("swan serve: not now (input pending or exec failed); after the next answer\n");
        if serve_map.len > 0 { var err: u8[>..] = []; serve_reopen(serve_map, false, "", err); serve_warm = true; }
    }
}

fn serve_loop() {
    var warmed = false;
    launch_path_init();
    var rs: u8[>..] = [];
    if env("SWAN_RESTARTED", rs) && rs == "1" {
        // Started by an older build of this same server: the agent already
        // initialized it. Reselect its repo and say the tools may differ now.
        warmed = true;
        var m: u8[>..] = [];
        if env("SWAN_RESTART_MAP", m) && m.len > 0 && file_exists(m) {
            var err: u8[>..] = [];
            if serve_reopen(m, false, "", err) { serve_map.clear(); format(serve_map, m); serve_warm = true; }
        }
        write_stdout("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n");
        flush_stdout();
    }
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
            out.append(",\"capabilities\":{\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"swan\",\"version\":");
            json::format_string(out, SWAN_VERSION);
            out.append("}}}");
        } else if method == "ping" {
            out.append(",\"result\":{}}");
        } else if method == "tools/list" {
            out.append(",\"result\":{\"tools\":");
            for ch in trim(TOOLS) { if ch != '\n' { out.push(ch); } }   // one line per message
            out.append("}}");
        } else if method == "tools/call" {
            serve_map_error.clear();
            var payload: u8[>..] = [];
            var tool_name: u8[>..] = [];    // owned: a tool may grow buffers the request's text could point into
            tool_name.append(arg_text(params, "name"));
            let targs = json::member(params, "arguments");
            let snapshot = tool_reads_map(tool_name, targs);
            let build, valid_build = request_build(targs);
            let clean, valid_clean = request_clean(targs);
            var ok = valid_build;
            // Validate even without repo, before selection, reopening or tool
            // effects. A failed restriction leaves the current selection alone.
            if !valid_build {
                payload.append("build must be a boolean");
            } else if tool_name == "update_map" && !valid_clean {
                payload.append("clean must be a boolean"); ok = false;
            } else if tool_name == "update_map" && clean && arg_text(targs, "repo").len == 0 {
                payload.append("clean rebuild requires an explicit repo root"); ok = false;
            } else if tool_name == "use_repo" {
                var p: u8[>..] = [];
                p.append(arg_text(targs, "path"));
                ok = repo_switch(p, build, true, snapshot, payload);
            } else {
                var rp: u8[>..] = [];
                rp.append(arg_text(targs, "repo"));
                if rp.len > 0 {
                    // Clean rebuild targets an existing exact map; never build a
                    // missing map implicitly before validating its identity.
                    ok = repo_switch(rp, build && !(tool_name == "update_map" && clean), false, snapshot, payload);
                } else if serve_map.len > 0 {
                    ok = serve_reopen(serve_map, snapshot, "", payload);
                }
                if ok && serve_db == 0 {
                    if tool_name == "index_info" {
                        list_maps(payload);
                        if serve_map_error.len > 0 { payload.clear(); payload.append(serve_map_error); ok = false; }
                    }
                    else { payload.append("no repo selected: call use_repo with a path, or pass repo"); ok = false; }
                } else if ok {
                    if serve_warm { serve_warm = false; live_warm(serve_db); }
                    ok = call_tool(serve_db, tool_name, targs, payload);
                }
            }
            if serve_snapshot { exec_or_die(serve_db, "COMMIT;"); serve_snapshot = false; }
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
        if is_init && !warmed { warmed = true; if serve_db != 0 { serve_warm = false; live_warm(serve_db); } }
        let target = restart_target();
        if target.len > 0 { restart_into(target); }
    }
    live_stop();
    if serve_db != 0 { close_db(serve_db); }
}
