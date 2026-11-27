// The survey of a repo's projects, from Spread-Wings.
//
// `spread-wings survey <repo>` reads manifest, lock and version files and
// lists the projects a repo holds: where each is, its package manager, the
// versions it wants, its workspace, whether its dependencies are installed
// (docs/wings-and-swan.md: what can be learned by only reading files is
// Spread-Wings' to find). Swan runs it first in every map, sealed, keeps the
// answer as survey.json in the map folder, says in the report what the repo
// holds, and uses it where it used to assume one project at the top.
//
// Without Spread-Wings, or when the survey fails, a map goes on as before
// and says so.
//
// Carried over from src/survey.goose: running the survey, what the report
// says of it, the folders of its projects of one kind, the virtualenvs of
// its Python projects, and projects left out because git ignores their folder.

use crate::json;
use crate::seal::sealed_run;
use crate::sys;
use crate::util::{find, json_string, push_int, starts_with, trim};
use crate::wings::wings_bin;

// Runs the survey and keeps it as <out>/survey.json. The JSON text, or ""
// with the reason in `why`.
pub fn survey_run(repo: &[u8], out: &[u8], why: &mut Vec<u8>) -> Vec<u8> {
    let mut text: Vec<u8> = Vec::new();
    let bin = wings_bin(why);
    if bin.is_empty() {
        return text;
    }
    // Absolute: the sealed run starts in the repo, not where Swan was started.
    let dir = match sys::realpath(out) {
        Some(d) => d,
        None => {
            why.extend_from_slice(&[b"cannot find the map folder ", out].concat());
            return text;
        }
    };
    let mut e: Vec<u8> = Vec::new();
    let code = sealed_run(&[&bin, b"survey", repo], repo, &dir, false, &[], 60000, &mut text, &mut e);
    if !(code == 0 && !text.is_empty() && text[0] == b'{') {
        // An older Spread-Wings answers an unknown command with its usage.
        if find(&text, b"spread-wings index <repo>") >= 0 || find(&e, b"spread-wings index <repo>") >= 0 {
            why.extend_from_slice(b"this spread-wings has no survey command (it is older than ececa28)");
        } else {
            let tail = if e.len() > 200 { &e[e.len() - 200..] } else { &e[..] };
            why.extend_from_slice(b"spread-wings survey failed (exit ");
            push_int(why, code as i64);
            why.extend_from_slice(b"): ");
            why.extend_from_slice(trim(tail));
        }
        text.clear();
        return text;
    }
    sys::write_file(&[&dir[..], b"/survey.json"].concat(), &text);
    text
}

// The folders git ignores, as the map keeps them (git-ignored-all.txt, one
// per line). The survey reads no .gitignore, so it lists a project in such
// a folder; the map leaves the folder out, and so does everything here.
pub fn survey_ignored(out: &[u8]) -> Vec<u8> {
    let mut list: Vec<u8> = Vec::new();
    sys::read_file(&[out, b"/git-ignored-all.txt"].concat(), &mut list);
    list
}

fn in_ignored(ignored: &[u8], path: &[u8]) -> bool {
    ignored.split(|&c| c == b'\n').any(|d| !d.is_empty() && (path == d || (path.len() > d.len() && starts_with(path, d) && path[d.len()] == b'/')))
}

// The folders of a survey's projects of one kind, one per line ("." is the
// top of the repo), without those in folders git ignores.
pub fn survey_paths(survey: &[u8], kind: &[u8], ignored: &[u8]) -> Vec<u8> {
    let mut paths: Vec<u8> = Vec::new();
    if survey.is_empty() {
        return paths;
    }
    let Some(doc) = json::parse(survey) else {
        return paths;
    };
    let Some(list) = doc.member(doc.root(), b"projects") else {
        return paths;
    };
    for p in doc.each(list) {
        let k = doc.as_string(doc.member(Some(p), b"kind"));
        let at = doc.as_string(doc.member(Some(p), b"path"));
        if let (Some(k), Some(at)) = (k, at) {
            if k == kind && !in_ignored(ignored, at) {
                paths.extend_from_slice(at);
                paths.push(b'\n');
            }
        }
    }
    paths
}

// The virtualenvs of a survey's Python projects, one per line, in the
// survey's order (the top of the repo first):
// "<project folder>\t<virtualenv, relative to the repo>\t<its Python>".
// The Python version is what the virtualenv's pyvenv.cfg says ("" when it
// says none). Without the projects in folders git ignores.
pub fn survey_python_envs(survey: &[u8], ignored: &[u8]) -> Vec<u8> {
    let mut envs: Vec<u8> = Vec::new();
    if survey.is_empty() {
        return envs;
    }
    let Some(doc) = json::parse(survey) else {
        return envs;
    };
    let Some(list) = doc.member(doc.root(), b"projects") else {
        return envs;
    };
    for p in doc.each(list) {
        let k = doc.as_string(doc.member(Some(p), b"kind"));
        let at = doc.as_string(doc.member(Some(p), b"path"));
        let e = doc.member(Some(p), b"environment");
        let v = doc.as_string(doc.member(e, b"venv"));
        let py = doc.as_string(doc.member(e, b"python"));
        if let (Some(k), Some(at), Some(v)) = (k, at, v) {
            if k == b"python" && !v.is_empty() && !in_ignored(ignored, at) {
                envs.extend_from_slice(&[at, b"\t", v, b"\t"].concat());
                if let Some(py) = py {
                    envs.extend_from_slice(trim(py));
                }
                envs.push(b'\n');
            }
        }
    }
    envs
}

// What the repo holds, for the map's report: the projects by kind, and the
// node projects whose dependencies are not installed. Projects in folders
// git ignores are not counted.
pub fn survey_report(survey: &[u8], ignored: &[u8], report: &mut Vec<u8>) {
    if survey.is_empty() {
        return;
    }
    let Some(doc) = json::parse(survey) else {
        return;
    };
    let Some(list) = doc.member(doc.root(), b"projects") else {
        return;
    };
    let mut said: Vec<u8> = Vec::new();
    let mut total = 0;
    for kind in [&b"node"[..], b"python", b"rust", b"go", b"java", b"deno"] {
        let mut n = 0;
        let mut managers: Vec<u8> = Vec::new(); // " pnpm bun": each once
        for p in doc.each(list) {
            let k = doc.as_string(doc.member(Some(p), b"kind"));
            let at = doc.as_string(doc.member(Some(p), b"path"));
            if let (Some(k), Some(at)) = (k, at) {
                if k == kind && !in_ignored(ignored, at) {
                    n += 1;
                    if let Some(m) = doc.as_string(doc.member(doc.member(Some(p), b"package_manager"), b"name")) {
                        if !m.is_empty() && find(&[&managers[..], b" "].concat(), &[b" ", m, b" "].concat()) < 0 {
                            managers.push(b' ');
                            managers.extend_from_slice(m);
                        }
                    }
                }
            }
        }
        if n > 0 {
            if !said.is_empty() {
                said.extend_from_slice(b", ");
            }
            push_int(&mut said, n);
            said.push(b' ');
            said.extend_from_slice(kind);
            if !managers.is_empty() {
                said.extend_from_slice(b" (");
                said.extend_from_slice(&managers[1..]);
                said.push(b')');
            }
            total += n;
        }
    }
    if total == 0 {
        return;
    }
    report.extend_from_slice(b"projects: ");
    report.extend_from_slice(&said);
    report.extend_from_slice(b" (survey.json, read by Spread-Wings; nothing of the repo was run)\n");
    let mut node = 0;
    let mut bare = 0;
    for p in doc.each(list) {
        let k = doc.as_string(doc.member(Some(p), b"kind"));
        let at = doc.as_string(doc.member(Some(p), b"path"));
        if let (Some(k), Some(at)) = (k, at) {
            if k == b"node" && !in_ignored(ignored, at) {
                node += 1;
                if doc.as_bool(doc.member(doc.member(Some(p), b"dependencies_installed"), b"installed")) == Some(false) {
                    bare += 1;
                }
            }
        }
    }
    if bare > 0 {
        report.extend_from_slice(b"node: dependencies are not installed in ");
        push_int(report, bare);
        report.extend_from_slice(b" of ");
        push_int(report, node);
        report.extend_from_slice(b" projects (no node_modules): what they import from packages is not in the map\n");
    }
}

// The survey's project folders that sit in folders git ignores, as a JSON
// list: the map leaves them out.
pub fn survey_left_out(survey: &[u8], ignored: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = vec![b'['];
    if let Some(doc) = json::parse(survey) {
        if let Some(list) = doc.member(doc.root(), b"projects") {
            for p in doc.each(list) {
                if let Some(at) = doc.as_string(doc.member(Some(p), b"path")) {
                    if in_ignored(ignored, at) {
                        if out.len() > 1 {
                            out.push(b',');
                        }
                        json_string(&mut out, at);
                    }
                }
            }
        }
    }
    out.push(b']');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn survey_left_out_lists_only_git_ignored_project_folders() {
        let survey = br#"{"projects":[{"path":"."},{"path":"vendor"},{"path":"vendor/sub"},{"path":"vendor2"},{"path":"build/app"}]}"#;
        let ignored = b"vendor\nbuild\n";
        let got = survey_left_out(survey, ignored);
        assert_eq!(String::from_utf8_lossy(&got), r#"["vendor","vendor/sub","build/app"]"#);
        assert_eq!(survey_left_out(b"not json", ignored), b"[]");
    }
}
