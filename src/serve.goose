// `swan serve`: the MCP server, JSON-RPC 2.0 over stdio, one message per
// line. It answers initialize, ping, tools/list and tools/call from the
// SQLite map and needs nothing else running.

import std;
import os;
import json;

let SWAN_VERSION = "0.1.0";

let TOOLS = """
    [{"name":"find_symbol","description":"Find symbols by name path. 'add' matches any symbol named add, 'Store/add' any whose name path ends that way, '/Store/add' only that exact path. Returns kind, signature, file, 1-based line and body line range; include_body adds the source.","inputSchema":{"type":"object","properties":{"name_path_pattern":{"type":"string"},"relative_path":{"type":"string","description":"Only symbols defined in this file or directory."},"substring_matching":{"type":"boolean","description":"Match the last name as a substring (no '/' in the pattern)."},"include_body":{"type":"boolean"},"max_results":{"type":"integer"}},"required":["name_path_pattern"]}},
     {"name":"find_referencing_symbols","description":"Find every reference to the symbols a name path matches, from the compiler's own resolution (SCIP), including through re-exports and renamed imports. Each reference gives file, 1-based line and column, the symbol it sits inside (in_symbol), and its line of source.","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"relative_path":{"type":"string","description":"The file or directory that defines the symbol, to pick one of several matches."},"max_results":{"type":"integer","description":"References per symbol (default 500)."}},"required":["name_path"]}},
     {"name":"get_symbols_overview","description":"List the symbols a file defines (or every file under a directory), with name paths, kinds and 1-based lines.","inputSchema":{"type":"object","properties":{"relative_path":{"type":"string"}},"required":["relative_path"]}},
     {"name":"get_callers","description":"Who uses a symbol, and who uses those, up to depth steps (default 1, max 5): the impact radius of changing it. Every reference counts (calls, type uses, imports). Each caller has its distance and is_test; the summary counts all affected symbols and files and lists the test files to run.","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"relative_path":{"type":"string","description":"The file or directory that defines the symbol."},"depth":{"type":"integer"},"max_results":{"type":"integer","description":"Callers listed (default 200); the summary covers all."}},"required":["name_path"]}},
     {"name":"get_callees","description":"What a function, method or class body uses: the symbols it calls or references, with use counts. Symbols from dependencies show their package and version instead of a file.","inputSchema":{"type":"object","properties":{"name_path":{"type":"string"},"relative_path":{"type":"string"},"max_results":{"type":"integer"}},"required":["name_path"]}},
     {"name":"index_info","description":"When and from what the code map was built: repo root, build time, symbol and occurrence counts. Use it to judge whether the map is stale.","inputSchema":{"type":"object","properties":{}}}]
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
                                 arg_int(args, "max_results", 500), out);
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
