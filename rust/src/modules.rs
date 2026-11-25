// What tools/modules.json says of a language, for the map: which languages
// are mapped by asking a language server (swan lsp-index), which files are
// theirs, whether their server is here, and which server to start. The rest
// of that file (linters, formatters, test runners) comes with the commands
// that use it.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::pipeline::{build_trusted, child_env, detect, python_of, untrusted_note};
use crate::run::swan_home;
use crate::rustproj::rust_std_source;
use crate::sys;
use crate::util::{ends_with, find, json_string, push_replaced};
use crate::walk::Walk;

// A language's entry in tools/modules.json, as swan map reads it.
#[derive(Deserialize)]
pub struct Entry {
    /// A file is the language's when its name ends with one of these.
    #[serde(default, rename = "match")]
    matches: Vec<String>,
    #[serde(default)]
    map: Option<String>,
    #[serde(default)]
    lsp: Vec<Candidate>,
    /// The servers swan lsp-index starts for the map, in place of "lsp".
    #[serde(default)]
    map_lsp: Vec<Candidate>,
}

impl Entry {
    // What swan lsp-index chooses from: "map_lsp", else "lsp" when the entry
    // says "map": "lsp"; none for a language not mapped through a server.
    fn map_candidates(&self) -> &[Candidate] {
        if !self.map_lsp.is_empty() {
            &self.map_lsp
        } else if self.map.as_deref() == Some("lsp") {
            &self.lsp
        } else {
            &[]
        }
    }

    /// Whether a file of this name is the language's.
    pub fn holds(&self, name: &[u8]) -> bool {
        self.matches.iter().any(|m| ends_with(name, m.as_bytes()))
    }

    /// What of the first map server is not here, its program or one of
    /// its needs: then the language is not mapped through it.
    pub fn missing(&self, home: &[u8]) -> Option<Vec<u8>> {
        let c = self.map_candidates().first()?;
        c.cmd.iter().take(1).chain(&c.needs).map(|s| at_home(s, home)).find(|p| !sys::file_exists(p))
    }

    /// The map servers as written, for a job's fingerprint.
    pub fn map_text(&self) -> String {
        serde_json::to_string(self.map_candidates()).unwrap_or_default()
    }

    /// The size of each file the first map server needs, for a job's
    /// fingerprint: a server fetched again is another server.
    pub fn needs_identity(&self, home: &[u8]) -> Vec<u8> {
        let Some(c) = self.map_candidates().first() else { return Vec::new() };
        c.needs.iter().flat_map(|p| format!("{} ", sys::file_size(&at_home(p, home))).into_bytes()).collect()
    }
}

fn read_modules(home: &[u8]) -> Result<Map<String, Value>, Vec<u8>> {
    let mut text = Vec::new();
    if !sys::read_file(&[home, b"/tools/modules.json"].concat(), &mut text) {
        return Err(b"tools/modules.json is missing".to_vec());
    }
    match serde_json::from_slice(&text) {
        Ok(Value::Object(m)) => Ok(m),
        Ok(_) => Err(b"tools/modules.json: not an object".to_vec()),
        Err(e) => Err(format!("tools/modules.json: {e}").into_bytes()),
    }
}

fn entry_of(lang: &str, v: &Value) -> Result<Entry, Vec<u8>> {
    Entry::deserialize(v).map_err(|e| format!("tools/modules.json, {lang}: {e}").into_bytes())
}

// The languages swan map maps with swan lsp-index, by name. A file that
// cannot be read, or an entry that cannot, names no language.
pub fn map_entries(home: &[u8]) -> Vec<(String, Entry)> {
    let Ok(mods) = read_modules(home) else { return Vec::new() };
    mods.iter()
        .filter(|(lang, _)| !lang.starts_with('_'))
        .filter_map(|(lang, v)| entry_of(lang, v).ok().map(|e| (lang.clone(), e)))
        .filter(|(_, e)| !e.map_candidates().is_empty())
        .collect()
}

// The language whose "match" holds a file (its path from the repo), with its
// entry, from the tools/modules.json of this Swan; None when no language does.
pub fn language_of(rel: &[u8]) -> Result<Option<(String, Entry)>, Vec<u8>> {
    let mods = read_modules(&swan_home())?;
    for (lang, v) in mods.iter().filter(|(lang, _)| !lang.starts_with('_')) {
        let e = entry_of(lang, v)?;
        if e.holds(rel) {
            return Ok(Some((lang.clone(), e)));
        }
    }
    Ok(None)
}

// One language's entry, from the tools/modules.json of this Swan.
pub fn map_entry(lang: &[u8]) -> Result<Entry, Vec<u8>> {
    let name = String::from_utf8_lossy(lang);
    let mods = read_modules(&swan_home())?;
    let Some(v) = mods.get(&*name) else {
        return Err(format!("no {name} in tools/modules.json").into_bytes());
    };
    entry_of(&name, v)
}

// The placeholders that name Swan's own folders.
fn at_home(s: &str, home: &[u8]) -> Vec<u8> {
    let mut text = s.as_bytes().to_vec();
    put(&mut text, b"{tools}", || [home, b"/.tools"].concat());
    put(&mut text, b"{bin}", || [home, b"/tools/node_modules/.bin"].concat());
    put(&mut text, b"{swan}", || home.to_vec());
    text
}

// The language server a language's map candidates in tools/modules.json
// choose here, ready to start: placeholders filled in, the environment
// children get (as swan map gives its indexers) followed by the entry's own.
pub struct ServerSpec {
    pub cmd: Vec<Vec<u8>>,
    pub env: Vec<Vec<u8>>,
    /// What didOpen says the files are.
    pub language_id: String,
    /// initializationOptions, and the answer to workspace/configuration.
    pub init: Value,
    /// It runs inside eggshell (lsp.rs).
    pub sealed: bool,
    /// How it says it has had its say about a file (live.rs).
    pub settle: Settle,
}

/// How a live server says it is done with a file: the candidate's "settle"
/// and "quiet_ms". live.rs carries each rule and its reason.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Settle {
    /// The file's next published set. quiet: for a server that publishes
    /// nothing for a clean file, the silence that means none.
    Publish { quiet: Option<Duration> },
    /// Asked for (textDocument/diagnostic) once the server is ready.
    Pull,
    /// rust-analyzer: the check a save starts, then the set that follows.
    Check,
}

// One "lsp" or "map_lsp" entry as written. The first whose conditions hold
// is used.
#[derive(Deserialize, Serialize)]
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
    /// These exist: what the command needs that it does not name itself
    /// (the real server behind the SolidLSP bridge).
    #[serde(default)]
    needs: Vec<String>,
    // Not in the map's fingerprint (map_text): only live answers read them.
    #[serde(default, skip_serializing)]
    settle: Option<String>,
    #[serde(default, skip_serializing)]
    quiet_ms: Option<u64>,
}

// What a server is chosen for, which names it in a refusal.
#[derive(Clone, Copy)]
enum Use {
    Map,
    Live,
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
        let mut text = at_home(s, &self.home);
        put(&mut text, b"{repo}", || self.repo.clone());
        put(&mut text, b"{out}", || self.out.clone());
        put(&mut text, b"{compdb}", || self.compdb.clone());
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

impl Entry {
    // The server that maps lang here (its "map_lsp" or "lsp" candidates).
    pub fn map_server(&self, walk: &Walk, repo: &[u8], out: &[u8], lang: &[u8]) -> Result<ServerSpec, Vec<u8>> {
        self.server(self.map_candidates(), Use::Map, walk, repo, out, lang)
    }

    // The server that answers live questions about lang here (its "lsp" candidates).
    pub fn live_server(&self, walk: &Walk, repo: &[u8], out: &[u8], lang: &[u8]) -> Result<ServerSpec, Vec<u8>> {
        self.server(&self.lsp, Use::Live, walk, repo, out, lang)
    }

    // The first candidate whose conditions hold, where one that runs the
    // repo's code holds only for a trusted repo, ready to start. Err says
    // why there is none.
    fn server(&self, cands: &[Candidate], purpose: Use, walk: &Walk, repo: &[u8], out: &[u8], lang: &[u8]) -> Result<ServerSpec, Vec<u8>> {
        let home = swan_home();
        let lang_name = String::from_utf8_lossy(lang);
        if cands.is_empty() {
            return Err(match purpose {
                Use::Map => format!("tools/modules.json names no server to map {lang_name} with"),
                Use::Live => format!("no live server for {lang_name} in tools/modules.json"),
            }
            .into_bytes());
        }
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
            let needs_ok = c.needs.iter().all(|p| sys::file_exists(&places.expand(p)));
            file_ok && needs_ok && (c.when_cmd.is_empty() || {
                let argv: Vec<Vec<u8>> = c.when_cmd.iter().map(|s| places.expand(s)).collect();
                let argv: Vec<&[u8]> = argv.iter().map(|a| &a[..]).collect();
                let env: Vec<&[u8]> = base.iter().map(|e| &e[..]).collect();
                let (mut o, mut e) = (Vec::new(), Vec::new());
                sys::run(&argv, repo, &env, 60000, &mut o, &mut e) == 0
            })
        };
        let Some(c) = pick(cands, trusted, holds) else {
            let why = if !trusted && cands.iter().any(|c| c.runs_repo_code) {
                untrusted_note(format!(" the {lang_name} language server").as_bytes(), repo)
            } else {
                match purpose {
                    Use::Map => format!("no server to map {lang_name} with applies here"),
                    Use::Live => format!("no live server for {lang_name} applies here"),
                }
                .into_bytes()
            };
            return Err(why);
        };
        if c.cmd.is_empty() {
            return Err(format!("tools/modules.json, {lang_name}: a server with no cmd").into_bytes());
        }
        let init_text = c.init.as_deref().map_or_else(|| b"{}".to_vec(), |s| places.expand(s));
        let init = serde_json::from_slice(&init_text).map_err(|e| format!("tools/modules.json, {lang_name}: its init is not JSON once filled in: {e}").into_bytes())?;
        let settle = match c.settle.as_deref() {
            None | Some("publish") => Settle::Publish { quiet: c.quiet_ms.filter(|&ms| ms > 0).map(Duration::from_millis) },
            Some("pull") => Settle::Pull,
            Some("check") => Settle::Check,
            // The map never waits for a settle: a word it does not know is a live refusal only.
            Some(_) if matches!(purpose, Use::Map) => Settle::Publish { quiet: None },
            Some(other) => return Err(format!("tools/modules.json, {lang_name}: settle \"{other}\" is not publish, pull or check").into_bytes()),
        };
        let mut env = base;
        env.extend(c.env.iter().map(|s| places.expand(s)));
        Ok(ServerSpec {
            cmd: c.cmd.iter().map(|s| places.expand(s)).collect(),
            env,
            language_id: c.language_id.clone().unwrap_or_else(|| lang_name.to_string()),
            init,
            sealed: c.sealed,
            settle,
        })
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn go_candidates() -> Vec<Candidate> {
        let text = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../tools/modules.json")).unwrap();
        let mods: Value = serde_json::from_slice(&text).unwrap();
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

    // The languages mapped through a server, each with its own files: Lua and
    // PHP by their "map_lsp" servers (SolidLSP, sealed, never the repo's
    // code), Go and Goose by "map": "lsp".
    #[test]
    fn map_entries_name_their_files_and_run_sealed() {
        let home = concat!(env!("CARGO_MANIFEST_DIR"), "/..").as_bytes();
        let entries = map_entries(home);
        let names: Vec<&str> = entries.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, ["go", "goose", "lua", "php"]);
        let of = |n: &str| &entries.iter().find(|(l, _)| l == n).unwrap().1;
        assert!(of("lua").holds(b"init.lua") && !of("go").holds(b"main.goose") && of("goose").holds(b"main.goose"));
        assert!(of("php").holds(b"index.php") && of("php").holds(b"page.phtml") && !of("php").holds(b"php.ini"));
        for lang in ["lua", "php"] {
            let c = pick(of(lang).map_candidates(), false, |_| true).unwrap();
            assert!(c.sealed && !c.runs_repo_code && !c.needs.is_empty(), "{lang}");
            assert!(c.cmd[1].ends_with("/tools/solidlsp/bridge.py"), "{lang}");
        }
    }
}
