// Adapters for the 12 read tools `swan query` already answers and `what_broke`,
// matching call_tool in src/serve.goose for argument names, defaults and errors.

use serde_json::Value;

use crate::broke;
use crate::diag;
use crate::graph;
use crate::query;
use crate::serve::{map_dir_of, MapSnapshot};
use crate::structural;
use crate::wings;

fn arg_text<'a>(args: &'a Value, key: &str) -> &'a [u8] {
    args.get(key).and_then(Value::as_str).unwrap_or("").as_bytes()
}

fn arg_bool(args: &Value, key: &str) -> bool {
    args.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn arg_int(args: &Value, key: &str, dflt: i64) -> i64 {
    match args.get(key).and_then(Value::as_i64) {
        Some(v) if v > 0 => v,
        _ => dflt,
    }
}

pub(crate) fn is_read_tool(name: &str) -> bool {
    matches!(
        name,
        "find_symbol"
            | "find_referencing_symbols"
            | "get_symbol_at"
            | "get_symbols_overview"
            | "get_callers"
            | "get_callees"
            | "find_implementations"
            | "get_type_hierarchy"
            | "find_unused_symbols"
            | "get_diagnostics"
            | "search_pattern"
            | "index_info"
    )
}

// Runs `what_broke` outside any SQLite read snapshot. Returns Ok((json, ok))
// where `ok` is true when at least one file was asked (matching call_tool in
// src/serve.goose), or Err(reason) when arguments or paths are invalid.
pub(crate) fn call_what_broke(
    map_path: &[u8],
    root: &[u8],
    args: &Value,
) -> Result<(Vec<u8>, bool), Vec<u8>> {
    let Some(fl) = args.get("files") else {
        return Err(b"files is required: the repo-relative paths you just edited".to_vec());
    };
    let mut files: Vec<Vec<u8>> = Vec::new();
    if let Some(arr) = fl.as_array() {
        for f in arr {
            if let Some(s) = f.as_str() {
                if !s.is_empty() {
                    files.push(s.as_bytes().to_vec());
                }
            }
        }
    }
    let outcome = broke::what_broke(map_dir_of(map_path), root, &files)?;
    Ok((outcome.json, outcome.asked > 0))
}

// Runs one of the 12 read tools against `snap` and writes its JSON answer
// into `out`. Returns None when `name` is not one of those 12 tools.
pub(crate) fn call_read(
    snap: &mut MapSnapshot,
    map_path: &[u8],
    name: &str,
    args: &Value,
    out: &mut Vec<u8>,
) -> Option<Result<(), Vec<u8>>> {
    match name {
        "find_symbol" => {
            let pattern = arg_text(args, "name_path_pattern");
            if pattern.is_empty() {
                return Some(Err(b"name_path_pattern is required".to_vec()));
            }
            query::find_symbol(
                &snap.db,
                &snap.fresh,
                pattern,
                arg_text(args, "relative_path"),
                arg_bool(args, "substring_matching"),
                arg_bool(args, "include_body"),
                arg_int(args, "max_results", 50),
                out,
            );
            Some(Ok(()))
        }
        "find_referencing_symbols" => {
            let pattern = arg_text(args, "name_path");
            if pattern.is_empty() {
                return Some(Err(b"name_path is required".to_vec()));
            }
            query::find_referencing_symbols(
                &snap.db,
                &snap.fresh,
                pattern,
                arg_text(args, "relative_path"),
                arg_int(args, "max_results", 500),
                arg_bool(args, "include_members"),
                out,
            );
            Some(Ok(()))
        }
        "get_symbol_at" => {
            let rel = arg_text(args, "relative_path");
            if rel.is_empty() {
                return Some(Err(b"relative_path is required".to_vec()));
            }
            query::get_symbol_at(
                &snap.db,
                &snap.fresh,
                rel,
                arg_int(args, "line", 1),
                arg_int(args, "column", 1),
                out,
            );
            Some(Ok(()))
        }
        "get_symbols_overview" => {
            let rel = arg_text(args, "relative_path");
            if rel.is_empty() {
                return Some(Err(b"relative_path is required".to_vec()));
            }
            query::get_symbols_overview(&snap.db, &snap.fresh, rel, out);
            Some(Ok(()))
        }
        "get_callers" => {
            let pattern = arg_text(args, "name_path");
            if pattern.is_empty() {
                return Some(Err(b"name_path is required".to_vec()));
            }
            let rel = arg_text(args, "relative_path");
            let depth = arg_int(args, "depth", 1).min(5);
            let limit = arg_int(args, "max_results", 200);
            let ids = graph::get_callers_exact(&snap.db, &snap.fresh, pattern, rel, depth, limit, out);
            let (root, specs, exact) = if !ids.is_empty() {
                let root = query::meta_value(&snap.db, b"root");
                let mut specs = Vec::new();
                let mut exact = Vec::new();
                graph::callers_target_info(&snap.db, &ids, &mut specs, &mut exact);
                (root, specs, exact)
            } else {
                (Vec::new(), Vec::new(), Vec::new())
            };
            // Release the read snapshot before Spread-Wings runs a subprocess
            // that writes beside the map, so swan.db is never held open across it.
            snap.end_tx();
            if !ids.is_empty() {
                wings::wings_possible_callers(
                    &snap.db,
                    &snap.fresh,
                    map_path,
                    &root,
                    &ids,
                    &specs,
                    &exact,
                    out,
                );
            }
            Some(Ok(()))
        }
        "get_callees" => {
            let pattern = arg_text(args, "name_path");
            if pattern.is_empty() {
                return Some(Err(b"name_path is required".to_vec()));
            }
            let rel = arg_text(args, "relative_path");
            let calls_only = arg_bool(args, "calls_only");
            let limit = arg_int(args, "max_results", 200);
            graph::get_callees(&snap.db, &snap.fresh, pattern, rel, calls_only, limit, out);
            Some(Ok(()))
        }
        "find_implementations" => {
            let pattern = arg_text(args, "name_path");
            if pattern.is_empty() {
                return Some(Err(b"name_path is required".to_vec()));
            }
            if arg_bool(args, "live") {
                return Some(Err(
                    b"live mode is not yet in the Rust server: find_implementations".to_vec(),
                ));
            }
            let rel = arg_text(args, "relative_path");
            let limit = arg_int(args, "max_results", 200);
            graph::find_implementations(&snap.db, &snap.fresh, pattern, rel, limit, out);
            Some(Ok(()))
        }
        "get_type_hierarchy" => {
            let pattern = arg_text(args, "name_path");
            if pattern.is_empty() {
                return Some(Err(b"name_path is required".to_vec()));
            }
            let rel = arg_text(args, "relative_path");
            let depth = arg_int(args, "depth", 3).min(10);
            let limit = arg_int(args, "max_results", 200);
            graph::get_type_hierarchy(&snap.db, &snap.fresh, pattern, rel, depth, limit, out);
            Some(Ok(()))
        }
        "find_unused_symbols" => {
            let rel = arg_text(args, "relative_path");
            let include_tests = arg_bool(args, "include_tests");
            let limit = arg_int(args, "max_results", 200);
            graph::find_unused_symbols(&snap.db, &snap.fresh, rel, include_tests, limit, out);
            Some(Ok(()))
        }
        "get_diagnostics" => {
            if arg_bool(args, "live") {
                return Some(Err(
                    b"live mode is not yet in the Rust server: get_diagnostics".to_vec(),
                ));
            }
            let pattern = arg_text(args, "name_path");
            let rel = arg_text(args, "relative_path");
            let depth = arg_int(args, "depth", 1).min(5);
            let errors_only = arg_bool(args, "errors_only");
            let limit = arg_int(args, "max_results", 200);
            let ok = diag::get_diagnostics(
                &snap.db,
                &snap.fresh,
                pattern,
                rel,
                depth,
                errors_only,
                limit,
                out,
            );
            if ok {
                Some(Ok(()))
            } else {
                Some(Err(std::mem::take(out)))
            }
        }
        "search_pattern" => {
            let pattern = arg_text(args, "pattern");
            let language = arg_text(args, "language");
            let rel = arg_text(args, "relative_path");
            let limit = arg_int(args, "max_results", 200);
            let ok = structural::search_pattern(
                &snap.db,
                &snap.fresh,
                pattern,
                language,
                rel,
                limit,
                out,
            );
            if ok {
                Some(Ok(()))
            } else {
                Some(Err(std::mem::take(out)))
            }
        }
        "index_info" => {
            query::index_info(&snap.db, &snap.fresh, out);
            Some(Ok(()))
        }
        _ => None,
    }
}
