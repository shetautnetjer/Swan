// `swan serve`: the MCP server, JSON-RPC 2.0 over stdio, one message per
// line. It answers initialize, ping, tools/list and tools/call from the
// SQLite map and needs nothing else running.

import std;
import os;
import json;

let SWAN_VERSION = "0.1.0";

let TOOLS = """
    [{"name":"find_symbol","description":"Find symbols by name path. 'add' matches any symbol named add, 'Store/add' any whose name path ends that way, '/Store/add' only that exact path. Returns kind, signature, file, 1-based line and body line range; include_body adds the source.","inputSchema":{"type":"object","properties":{"name_path_pattern":{"type":"string"},"relative_path":{"type":"string","description":"Only symbols defined in this file or directory."},"substring_matching":{"type":"boolean","description":"Match the last name as a substring (no '/' in the pattern)."},"include_body":{"type":"boolean"},"max_results":{"type":"integer"}},"required":["name_path_pattern"]}},
     {"name":"find_referencing_symbols","description":"Find every reference to the symbols a name path matches, from the compiler's own resolution (SCIP), including through re-exports and renamed imports. Each reference gives file, 1-based line and column, the symbol it sits inside (in_symbol), and its line of source. Rust uses inside macro calls that rust-analyzer could not resolve are matched by name and marked by_name. include_members also counts uses through what the symbol holds (enum variants, methods, fields; Rust impl functions), each marked with via: use it for 'where is this type used'.","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"include_members":{"type":"boolean"},"relative_path":{"type":"string","description":"The file or directory that defines the symbol, to pick one of several matches."},"max_results":{"type":"integer","description":"References per symbol (default 500)."}},"required":["name_path"]}},
     {"name":"get_symbols_overview","description":"List the symbols a file defines (or every file under a directory), with name paths, kinds and 1-based lines.","inputSchema":{"type":"object","properties":{"relative_path":{"type":"string"}},"required":["relative_path"]}},
     {"name":"get_callers","description":"Who uses a symbol, and who uses those, up to depth steps (default 1, max 5): the impact radius of changing it. Every reference counts (calls, type uses, imports). Each caller has its distance and is_test; the summary counts all affected symbols and files and lists the test files to run.","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"relative_path":{"type":"string","description":"The file or directory that defines the symbol."},"depth":{"type":"integer"},"max_results":{"type":"integer","description":"Callers listed (default 200); the summary covers all."}},"required":["name_path"]}},
     {"name":"get_callees","description":"What a function, method or class body uses: the symbols it calls or references, with use counts. Symbols from dependencies show their package and version instead of a file.","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"relative_path":{"type":"string"},"max_results":{"type":"integer"}},"required":["name_path"]}},
     {"name":"find_implementations","description":"What implements, extends or overrides a symbol, from the compiler's own view (SCIP): the classes behind an interface, the subclasses of a class, the overrides of a method. Each result has its distance (1 = direct).","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"relative_path":{"type":"string"},"max_results":{"type":"integer"}},"required":["name_path"]}},
     {"name":"get_type_hierarchy","description":"A symbol's supertypes (what it implements, extends or overrides) and subtypes (what implements, extends or overrides it), up to depth steps each way (default 3).","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"relative_path":{"type":"string"},"depth":{"type":"integer"},"max_results":{"type":"integer"}},"required":["name_path"]}},
     {"name":"find_unused_symbols","description":"Functions, classes, methods, types and variables defined in the repo that nothing references or implements. Candidates for removal, not proof: entry points and code reached by name at run time also appear. Test files are skipped unless include_tests.","inputSchema":{"type":"object","properties":{"relative_path":{"type":"string","description":"Only this file or directory."},"include_tests":{"type":"boolean"},"max_results":{"type":"integer","description":"Listed (default 200); total counts all."}}}},
     {"name":"replace_symbol_body","description":"Replace a symbol's whole definition (signature included, as find_symbol with include_body shows it) with new code. Read the body first. Refused if the file changed since the map was built. Returns the new line range and how many places use the symbol, so you know what to check.","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"relative_path":{"type":"string","description":"The file that defines the symbol (required)."},"body":{"type":"string"}},"required":["name_path","relative_path","body"]}},
     {"name":"insert_after_symbol","description":"Insert code after a function, method or class definition, one blank line apart. Include the indentation you want.","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"relative_path":{"type":"string"},"body":{"type":"string"}},"required":["name_path","relative_path","body"]}},
     {"name":"insert_before_symbol","description":"Insert code before a symbol's definition, one blank line apart: a new function, class or import before an existing one.","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"relative_path":{"type":"string"},"body":{"type":"string"}},"required":["name_path","relative_path","body"]}},
     {"name":"rename_symbol","description":"Rename a symbol at every use the compiler resolved, across files. By default only plans: every site, sites skipped because their text differs (aliases, re-exports), conflicts with an existing symbol of the new name, and stale files. Set apply to true to write it; a conflict or a stale file refuses. Strings, comments and uses by name at run time are not covered.","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"relative_path":{"type":"string","description":"The file that defines the symbol (required)."},"new_name":{"type":"string"},"apply":{"type":"boolean"}},"required":["name_path","relative_path","new_name"]}},
     {"name":"index_info","description":"When and from what the code map was built: repo root, build time, counts, and the files changed since the SCIP run (stale_files). Answers about a stale file carry \"stale\": true; refresh the map or reread the file.","inputSchema":{"type":"object","properties":{}}}]
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
    if name == "index_info" { index_info(db, out); return true; }
    out.append(str("unknown tool: ", name));
    return false;
}

fn serve_main(db_path: const u8[:]) {
    let db = open_db(db_path);
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
            let ok = call_tool(db, arg_text(params, "name"), json::member(params, "arguments"), payload);
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
    }
    swan_db_close(db);
}
