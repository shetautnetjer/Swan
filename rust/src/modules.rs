// What tools/modules.json says of a language, for the map.
//
// Carried over from src/modules.goose so far: whether a language's server
// is installed here, which language a path is of, and which server to
// start for a language (lsp_server). The rest of that file (linters,
// formatters, test runners) comes with the commands that use it.

use serde::Deserialize;

use crate::json::Doc;
use crate::pipeline::{build_trusted, child_env, detect, python_of, untrusted_note};
use crate::run::swan_home;
use crate::rustproj::rust_std_source;
use crate::sys;
use crate::util::{ends_with, find, json_string, push_replaced};
use crate::walk::Walk;

// Whether the first server listed for a language (its "lsp" list) is
// installed: the first word of its command, with {tools} as Swan's .tools.
pub fn lsp_server_present(doc: &Doc, m: Option<usize>, home: &[u8]) -> bool {
    let mut found = false;
    if let Some(list) = doc.member(m, b"lsp") {
        if let Some(cand) = doc.each(list).next() {
            if let Some(cmd) = doc.member(Some(cand), b"cmd") {
                if let Some(part) = doc.each(cmd).next() {
                    if let Some(s) = doc.as_string(Some(part)) {
                        let mut p: Vec<u8> = Vec::new();
                        push_replaced(&mut p, s, b"{tools}", &[home, b"/.tools"].concat());
                        found = sys::file_exists(&p);
                    }
                }
            }
        }
    }
    found
}

// The language server a language's "lsp" entries in tools/modules.json
// choose here, ready to start: placeholders filled in, the environment
// children get (as swan map gives its indexers) followed by the entry's own.
pub struct ServerSpec {
    pub cmd: Vec<Vec<u8>>,
    pub env: Vec<Vec<u8>>,
    /// What didOpen says the files are.
    pub language_id: String,
    /// initializationOptions, and the answer to workspace/configuration.
    pub init: serde_json::Value,
    /// It runs inside eggshell (lsp.rs).
    pub sealed: bool,
}

// One "lsp" entry as written. The first whose conditions hold is used.
#[derive(Deserialize)]
struct Candidate {
    cmd: Vec<String>,
    #[serde(default)]
    env: Vec<String>,
    language_id: Option<String>,
    init: Option<String>,
    #[serde(default)]
    sealed: bool,
    /// It runs the repo's own build files, so it waits for swan trust.
    #[serde(default)]
    runs_repo_code: bool,
    /// One of these exists in the repo.
    #[serde(default)]
    when_file: Vec<String>,
    /// This command exits 0.
    #[serde(default)]
    when_cmd: Vec<String>,
}

// What the placeholders stand for (src/modules.goose, ModCtx and expand).
struct Places<'a> {
    walk: &'a Walk,
    repo: Vec<u8>,
    out: Vec<u8>,
    home: Vec<u8>,
    python: Vec<u8>,
    compdb: Vec<u8>,
}

impl Places<'_> {
    fn expand(&self, s: &str) -> Vec<u8> {
        let mut text = s.as_bytes().to_vec();
        put(&mut text, b"{repo}", || self.repo.clone());
        put(&mut text, b"{out}", || self.out.clone());
        put(&mut text, b"{tools}", || [&self.home[..], b"/.tools"].concat());
        put(&mut text, b"{bin}", || [&self.home[..], b"/tools/node_modules/.bin"].concat());
        put(&mut text, b"{compdb}", || self.compdb.clone());
        put(&mut text, b"{swan}", || self.home.clone());
        put(&mut text, b"{python}", || self.python.clone());
        put(&mut text, b"{goose_entry_files}", || goose_entry_files(self.walk, &self.repo));
        put(&mut text, b"{rust_std_source}", || {
            let at = rust_std_source(&self.repo);
            let mut src = Vec::new();
            if at.is_empty() {
                src.extend_from_slice(b"null");
            } else {
                json_string(&mut src, &at);
            }
            src
        });
        text
    }
}

// A placeholder in text, replaced by what it stands for; worked out only
// when it is there.
fn put(text: &mut Vec<u8>, from: &[u8], to: impl FnOnce() -> Vec<u8>) {
    if find(text, from) >= 0 {
        let mut next = Vec::new();
        push_replaced(&mut next, text, from, &to());
        *text = next;
    }
}

// The server for lang, chosen as src/live.goose chooses it: the first
// candidate whose conditions hold, where one that runs the repo's code
// holds only for a trusted repo. Err says why there is none.
pub fn lsp_server(walk: &Walk, repo: &[u8], out: &[u8], lang: &[u8]) -> Result<ServerSpec, Vec<u8>> {
    let home = swan_home();
    let lang_name = String::from_utf8_lossy(lang);
    let mut text = Vec::new();
    if !sys::read_file(&[&home[..], b"/tools/modules.json"].concat(), &mut text) {
        return Err(b"tools/modules.json is missing".to_vec());
    }
    let mods: serde_json::Value = serde_json::from_slice(&text).map_err(|e| format!("tools/modules.json: {e}").into_bytes())?;
    let Some(list) = mods.get(&*lang_name).and_then(|m| m.get("lsp")) else {
        return Err(format!("no live server for {lang_name} in tools/modules.json").into_bytes());
    };
    let cands: Vec<Candidate> = serde_json::from_value(list.clone()).map_err(|e| format!("tools/modules.json, {lang_name}: {e}").into_bytes())?;
    let trusted = build_trusted(repo);
    let mut l = detect(walk, repo);
    if !trusted {
        l.venv.clear(); // the repo's virtualenv is its own code
    }
    let compdb = if sys::file_exists(&[repo, b"/compile_commands.json"].concat()) {
        repo.to_vec()
    } else if sys::file_exists(&[repo, b"/build/compile_commands.json"].concat()) {
        [repo, b"/build"].concat()
    } else {
        out.to_vec()
    };
    let places = Places { walk, repo: repo.to_vec(), out: out.to_vec(), home: home.clone(), python: python_of(&l), compdb };
    let base = child_env(&l, &[], b"");
    let holds = |c: &Candidate| {
        let file_ok = c.when_file.is_empty() || c.when_file.iter().any(|f| sys::file_exists(&[repo, b"/", f.as_bytes()].concat()));
        file_ok && (c.when_cmd.is_empty() || {
            let argv: Vec<Vec<u8>> = c.when_cmd.iter().map(|s| places.expand(s)).collect();
            let argv: Vec<&[u8]> = argv.iter().map(|a| &a[..]).collect();
            let env: Vec<&[u8]> = base.iter().map(|e| &e[..]).collect();
            let (mut o, mut e) = (Vec::new(), Vec::new());
            sys::run(&argv, repo, &env, 60000, &mut o, &mut e) == 0
        })
    };
    let Some(c) = pick(&cands, trusted, holds) else {
        let why = if !trusted && cands.iter().any(|c| c.runs_repo_code) {
            untrusted_note(format!(" the {lang_name} language server").as_bytes(), repo)
        } else {
            format!("no live server for {lang_name} applies here").into_bytes()
        };
        return Err(why);
    };
    if c.cmd.is_empty() {
        return Err(format!("tools/modules.json, {lang_name}: a server with no cmd").into_bytes());
    }
    let init_text = c.init.as_deref().map_or_else(|| b"{}".to_vec(), |s| places.expand(s));
    let init = serde_json::from_slice(&init_text).map_err(|e| format!("tools/modules.json, {lang_name}: its init is not JSON once filled in: {e}").into_bytes())?;
    let mut env = base;
    env.extend(c.env.iter().map(|s| places.expand(s)));
    Ok(ServerSpec {
        cmd: c.cmd.iter().map(|s| places.expand(s)).collect(),
        env,
        language_id: c.language_id.clone().unwrap_or_else(|| lang_name.to_string()),
        init,
        sealed: c.sealed,
    })
}

fn pick(cands: &[Candidate], trusted: bool, holds: impl Fn(&Candidate) -> bool) -> Option<&Candidate> {
    cands.iter().find(|c| (trusted || !c.runs_repo_code) && holds(c))
}

// The repo's Goose programs as a JSON array of absolute paths: the .goose
// files that define fn main( at the start of a line. Goose's server checks
// each open file as a program of its own unless told which programs there
// are. At most 32.
fn goose_entry_files(walk: &Walk, repo: &[u8]) -> Vec<u8> {
    let mut out = vec![b'['];
    let mut count = 0;
    walk.each_file(repo, |full, name| {
        let mut text = Vec::new();
        if count < 32 && ends_with(name, b".goose") && sys::read_file(full, &mut text) && (text.starts_with(b"fn main(") || find(&text, b"\nfn main(") >= 0) {
            if count > 0 {
                out.push(b',');
            }
            json_string(&mut out, full);
            count += 1;
        }
    });
    out.push(b']');
    out
}

pub fn lang_of_path(p: &[u8]) -> &'static [u8] {
    let ends = |list: &[&[u8]]| list.iter().any(|e| ends_with(p, e));
    if ends(&[b".py", b".pyi"]) {
        return b"python";
    }
    if ends(&[b".rs"]) {
        return b"rust";
    }
    if ends(&[b".kt", b".kts"]) {
        return b"kotlin";
    }
    if ends(&[b".java"]) {
        return b"java";
    }
    if ends(&[b".goose"]) {
        return b"goose";
    }
    if ends(&[b".go"]) {
        return b"go";
    }
    if ends(&[b".c", b".cc", b".cpp", b".cxx", b".h", b".hpp", b".hh", b".hxx", b".cu", b".cuh"]) {
        return b"cpp";
    }
    if ends(&[b".cs"]) {
        return b"csharp";
    }
    if ends(&[b".lua"]) {
        return b"lua";
    }
    if ends(&[b".glsl", b".vert", b".frag", b".comp", b".geom", b".tesc", b".tese"]) {
        return b"glsl";
    }
    if ends(&[b".hlsl", b".hlsli", b".fx"]) {
        return b"hlsl";
    }
    if ends(&[b".wgsl"]) {
        return b"wgsl";
    }
    if ends(&[b".ts", b".tsx", b".mts", b".cts", b".js", b".jsx", b".mjs", b".cjs"]) {
        return b"typescript";
    }
    b""
}

#[cfg(test)]
mod tests {
    use super::*;

    fn go_candidates() -> Vec<Candidate> {
        let text = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../tools/modules.json")).unwrap();
        let mods: serde_json::Value = serde_json::from_slice(&text).unwrap();
        serde_json::from_value(mods["go"]["lsp"].clone()).unwrap()
    }

    // Go's server through SolidLSP runs sealed either way; for a repo not
    // trusted it is the entry that keeps the Go toolchain off the network
    // (GOPROXY=off), never the one marked as running the repo's code.
    #[test]
    fn an_untrusted_repo_never_gets_a_server_that_runs_its_code() {
        let cands = go_candidates();
        let untrusted = pick(&cands, false, |_| true).unwrap();
        assert!(!untrusted.runs_repo_code && untrusted.sealed);
        assert!(untrusted.env.iter().any(|e| e == "GOPROXY=off"));
        let trusted = pick(&cands, true, |_| true).unwrap();
        assert!(trusted.runs_repo_code && trusted.sealed);
        assert!(!trusted.env.iter().any(|e| e == "GOPROXY=off"));
        let only_code: Vec<Candidate> = cands.into_iter().filter(|c| c.runs_repo_code).collect();
        assert!(pick(&only_code, false, |_| true).is_none());
    }
}
