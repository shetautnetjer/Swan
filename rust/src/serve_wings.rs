// Adapters for the four Spread-Wings tools (repo_projects, repo_overview,
// what_touches, file_neighbors), matching call_tool in src/serve.goose.

use serde_json::Value;

use crate::serve::map_dir_of;
use crate::survey;
use crate::util::trim;
use crate::wings;

fn arg_text<'a>(args: &'a Value, key: &str) -> &'a [u8] {
    args.get(key).and_then(Value::as_str).unwrap_or("").as_bytes()
}

pub(crate) fn is_wings_tool(name: &str) -> bool {
    matches!(name, "repo_projects" | "repo_overview" | "what_touches" | "file_neighbors")
}

// Runs one of the four Spread-Wings tools against the selected map (outside
// any SQLite read snapshot) and writes its JSON answer into `out`. Returns
// None when `name` is not one of those four tools.
pub(crate) fn call_wings(
    map_path: &[u8],
    root: &[u8],
    name: &str,
    args: &Value,
    out: &mut Vec<u8>,
) -> Option<Result<(), Vec<u8>>> {
    match name {
        "repo_projects" => {
            let map_dir = map_dir_of(map_path);
            let mut why = Vec::new();
            let survey = survey::survey_run(root, map_dir, &mut why);
            if survey.is_empty() {
                return Some(Err(why));
            }
            // The survey reads no .gitignore; the map leaves ignored folders out.
            let ignored = survey::survey_ignored(map_dir);
            let left_out = survey::survey_left_out(&survey, &ignored);
            out.extend_from_slice(b"{\"source\":\"spread-wings\",\"in_folders_git_ignores\":");
            out.extend_from_slice(&left_out);
            out.extend_from_slice(b",\"result\":");
            out.extend_from_slice(trim(&survey));
            out.push(b'}');
            Some(Ok(()))
        }
        "repo_overview" => {
            if wings::wings_answer(root, map_path, b"overview", b"", b"", out) {
                Some(Ok(()))
            } else {
                Some(Err(std::mem::take(out)))
            }
        }
        "what_touches" => {
            let n = arg_text(args, "name");
            if n.is_empty() {
                return Some(Err(
                    b"name is required: the bare name of a function, method or type".to_vec(),
                ));
            }
            let rel = arg_text(args, "relative_path");
            if wings::wings_answer(root, map_path, b"touches", n, rel, out) {
                Some(Ok(()))
            } else {
                Some(Err(std::mem::take(out)))
            }
        }
        "file_neighbors" => {
            let rel = arg_text(args, "relative_path");
            if rel.is_empty() {
                return Some(Err(b"relative_path is required".to_vec()));
            }
            if wings::wings_answer(root, map_path, b"neighbors", rel, b"", out) {
                Some(Ok(()))
            } else {
                Some(Err(std::mem::take(out)))
            }
        }
        _ => None,
    }
}
