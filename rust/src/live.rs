// Live answers: one language server, started for one language of one repo
// and asked about files as they stand on disk. swan lsp-ask and swan broke
// use it, one process each. The rules for when a server has had its say
// were learned by the Goose program's client (lsp/golsp.goose), whose
// lessons are carried here with their reasons.
//
// The contract: the file on disk is the truth. A question reads the file,
// opens it in the server (didOpen) on first use, or sends the whole new text
// (didChange, version + 1) followed by didSave when its text on disk differs
// from what was last sent. A file deleted since it was sent gets didClose
// before the read error is returned.
//
// Each one-shot command (swan lsp-ask, swan broke) shares one deadline, its
// budget (100 s, or SWAN_LIVE_BUDGET_MS), so the command ends on its own
// before the hook that runs swan broke kills it at 120 s. A long-lived caller
// (swan serve) calls begin(deadline) before each question so every question
// has its own budget. A settle that does not happen by then is not settled,
// and never a clean answer.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

use crate::lsp::{Client, Heard, LspError, Status};
use crate::modules::{language_of, Entry, Refused, Settle};
use crate::sys;
use crate::walk::Walk;

/// What a command may take in all, unless SWAN_LIVE_BUDGET_MS says.
const BUDGET: Duration = Duration::from_secs(100);

/// This long with no word from a server means it has said what it had to:
/// once it has published a file's set, that no second set follows at once;
/// once it has been sent a file, that it is not about to say it is busy
/// (the TypeScript server begins its work 9 ms after an open, and answers
/// a question asked before that from a project it has not loaded).
const SILENCE: Duration = Duration::from_millis(300);

pub fn budget() -> Duration {
    let ms = std::str::from_utf8(&sys::env(b"SWAN_LIVE_BUDGET_MS")).ok().and_then(|s| s.parse::<u64>().ok());
    ms.filter(|&ms| ms > 0).map_or(BUDGET, Duration::from_millis)
}

/// One diagnostic, where it starts: 1-based, in the server's own units.
pub struct Diag {
    pub line: u64,
    pub col: u64,
    pub severity: &'static str,
    pub code: String,
    pub message: String,
}

/// Why a file was not asked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    NoServer,
    Untrusted,
    Unsettled,
    Failed,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::NoServer => "no_server",
            Reason::Untrusted => "untrusted",
            Reason::Unsettled => "unsettled",
            Reason::Failed => "failed",
        }
    }
}

/// A refusal to ask about a file: its class and the words for it.
#[derive(Clone, Debug)]
pub struct Refusal {
    pub reason: Reason,
    pub why: String,
}

pub enum Diagnosed {
    Settled(Vec<Diag>),
    /// The server did not have its say about the file: why.
    Unsettled(String),
}

/// One running server for one language of one repo, and the files it has
/// been sent.
pub struct Live {
    client: Client,
    lang: String,
    language_id: String,
    settle: Settle,
    repo: Vec<u8>,
    log: Vec<u8>,
    deadline: Instant,
    per_question: bool,
    opened: HashMap<Vec<u8>, Sent>,
}

/// A file as it was sent, and where the server's sayings stood then.
struct Sent {
    text: String,
    uri: String,
    version: i64,
    at: Instant,
    publishes: u64,
    checks: u64,
}

impl Live {
    /// Starts lang's live server for repo (its "lsp" entry), the map folder
    /// out holding what it writes and its log.
    pub fn start(walk: &Walk, repo: &[u8], out: &[u8], lang: &str, entry: &Entry, deadline: Instant) -> Result<Live, Refusal> {
        let spec = entry.live_server(walk, repo, out, lang.as_bytes()).map_err(|r| match r {
            Refused::NoServer(why) => Refusal { reason: Reason::NoServer, why: lossy(&why) },
            Refused::Untrusted(why) => Refusal { reason: Reason::Untrusted, why: lossy(&why) },
            Refused::Broken(why) => Refusal { reason: Reason::Failed, why: lossy(&why) },
        })?;
        let log = [out, b"/lsp-", lang.as_bytes(), b".log"].concat();
        let left = deadline.saturating_duration_since(Instant::now());
        let client = match Client::start(&spec, repo, repo, out, &log, left) {
            Ok(c) => c,
            Err(LspError::Timeout(_)) => return Err(Refusal { reason: Reason::Failed, why: format!("the {lang} language server did not start {}; see {}", within(), lossy(&log)) }),
            Err(e) => return Err(Refusal { reason: Reason::Failed, why: format!("the {lang} language server did not start: {e}; see {}", lossy(&log)) }),
        };
        Ok(Live { client, lang: lang.to_string(), language_id: spec.language_id, settle: spec.settle, repo: repo.to_vec(), log, deadline, per_question: false, opened: HashMap::new() })
    }

    /// Sets the deadline for the next question when one Live serves many.
    pub fn begin(&mut self, deadline: Instant) {
        self.deadline = deadline;
        self.per_question = true;
    }

    /// Whether the server process is still running and its channel is open.
    pub fn is_alive(&mut self) -> bool {
        self.client.is_alive()
    }

    /// Any request about a file (its path from the repo), at a place in it
    /// when given (1-based line and column, in the server's own units),
    /// with more members for its params: the server's own result.
    pub fn request(&mut self, rel: &[u8], method: &str, place: Option<(u32, u32)>, more: Map<String, Value>) -> Result<Value, String> {
        let uri = self.open(rel)?;
        if !self.ready(self.opened[rel].at)? {
            return Err(format!("the {} language server was not ready {}", self.lang, within()));
        }
        let mut params = Map::new();
        params.insert("textDocument".to_string(), json!({"uri": uri}));
        if let Some((line, col)) = place {
            params.insert("position".to_string(), json!({"line": line.saturating_sub(1), "character": col.saturating_sub(1)}));
        }
        params.extend(more);
        let left = self.left();
        self.client.request(method, Value::Object(params), left).map_err(|e| self.said(e))
    }

    /// What the server reports for a file (its path from the repo) as it is
    /// on disk now, once the server has had its say by its entry's settle.
    pub fn diagnostics(&mut self, rel: &[u8]) -> Result<Diagnosed, String> {
        self.open(rel)?;
        let key = [&self.repo[..], b"/", rel].concat();
        let sent = &self.opened[rel];
        let (uri, version, at, publishes, checks) = (sent.uri.clone(), sent.version, sent.at, sent.publishes, sent.checks);
        let deadline = self.deadline;
        let settled = match self.settle {
            // The file's next published set for the text sent (pyright, the
            // TypeScript server). With quiet: a server that publishes nothing
            // for a clean file (lua-language-server) has said all it will
            // once it has been silent that long since the question.
            Settle::Publish { quiet } => {
                let set = |h: &Heard| current(h, &key, publishes, version).is_some();
                let silent = |h: &Heard| quiet.is_some_and(|q| at.elapsed() >= q && h.last_heard.max(at).elapsed() >= q);
                let held = self.client.wait_until(deadline, |h| set(h) || silent(h)).map_err(|e| self.said(e))?;
                if held && set(self.client.heard()) {
                    self.last_set()?;
                }
                held.then(|| self.items(&key, publishes, version))
            }
            // Asked for (textDocument/diagnostic) once the server is ready
            // (Go's server, through SolidLSP).
            Settle::Pull => {
                if !self.ready(at)? {
                    return Ok(Diagnosed::Unsettled(self.out_of_time()));
                }
                let left = self.left();
                match self.client.request("textDocument/diagnostic", json!({"textDocument": {"uri": uri}}), left) {
                    Ok(report) => match report.get("items").and_then(Value::as_array) {
                        Some(items) => Some(items.iter().map(diag).collect()),
                        None => return Err(format!("the {} language server answered textDocument/diagnostic with no items", self.lang)),
                    },
                    Err(LspError::Timeout(_)) => None,
                    Err(e) => return Err(self.said(e)),
                }
            }
            // rust-analyzer: its own diagnostics come at once, the
            // compiler's only from the check a save starts (cargo check), and
            // it publishes only the sets that change. So the answer is the
            // set standing once that check has ended, the workspace loaded.
            // When the server's status says the check did not run
            // (check_not_run), an error in that set is passed on and a set
            // with none is no answer: the check never reached the file.
            Settle::Check => {
                let held = self.client.wait_until(deadline, |h| h.quiescent == Some(true) && checks_ended(h) > checks && !checking(h)).map_err(|e| self.said(e))?;
                if !held {
                    return Ok(Diagnosed::Unsettled(self.out_of_time()));
                }
                self.last_set()?;
                let items = self.items(&key, 0, version);
                if let Some(said) = self.client.heard().status.as_ref().and_then(check_not_run) {
                    if !items.iter().any(|d| d.severity == "error") {
                        return Ok(Diagnosed::Unsettled(format!("not settled: {said}")));
                    }
                }
                Some(items)
            }
        };
        Ok(settled.map_or_else(|| Diagnosed::Unsettled(self.out_of_time()), Diagnosed::Settled))
    }

    fn out_of_time(&self) -> String {
        format!("not settled: the {} language server did not finish with the file {}; see {}", self.lang, within(), lossy(&self.log))
    }

    /// Shuts the server down with what is left of the budget, 3 s at most.
    /// When begin() was used for per-question budgets, always allows up to 3 s
    /// so a long-lived server still shuts down cleanly after an idle stretch
    /// or a timed-out question.
    pub fn stop(self) {
        let t = if self.per_question { Duration::from_secs(3) } else { self.left().min(Duration::from_secs(3)) };
        self.client.shutdown_within(t);
    }

    /// Shuts the server down with up to grace (capped at 3 s), regardless of
    /// the current question deadline.
    pub fn stop_within(self, grace: Duration) {
        self.client.shutdown_within(grace.min(Duration::from_secs(3)));
    }

    /// Sends textDocument/didClose and forgets rel if it was opened in this
    /// server; does nothing when rel was never opened.
    pub fn close_if_open(&mut self, rel: &[u8]) {
        if let Some(sent) = self.opened.remove(rel) {
            let _ = self.client.notify("textDocument/didClose", json!({"textDocument": {"uri": sent.uri}}));
        }
    }

    /// Ensures the server holds the file's text as it stands on disk now,
    /// sending didOpen on first use, didChange (whole text, version + 1) and
    /// didSave when its text changed, or didClose before returning the read
    /// error if the file was deleted.
    pub fn open(&mut self, rel: &[u8]) -> Result<String, String> {
        let path = [&self.repo[..], b"/", rel].concat();
        let text = match read_text(&path, rel) {
            Ok(text) => text,
            Err(err) => {
                if !sys::file_exists(&path) {
                    self.close_if_open(rel);
                }
                return Err(err);
            }
        };
        if let Some(sent) = self.opened.get(rel) {
            if sent.text == text {
                let uri = sent.uri.clone();
                self.client.drain().map_err(|e| self.said(e))?;
                return Ok(uri);
            }
            let uri = sent.uri.clone();
            let version = sent.version + 1;
            self.client.drain().map_err(|e| self.said(e))?;
            let h = self.client.heard();
            let next = Sent { text, uri: uri.clone(), version, at: Instant::now(), publishes: h.publishes, checks: checks_ended(h) };
            let change = json!({
                "textDocument": {"uri": uri, "version": version},
                "contentChanges": [{"text": next.text}]
            });
            self.client.notify("textDocument/didChange", change).map_err(|e| self.said(e))?;
            // Tell the server the new text is saved on disk (rust-analyzer starts its check on save).
            self.client.notify("textDocument/didSave", json!({"textDocument": {"uri": uri}})).map_err(|e| self.said(e))?;
            self.opened.insert(rel.to_vec(), next);
            return Ok(uri);
        }
        self.client.drain().map_err(|e| self.said(e))?;
        let uri = self.client.uri(rel);
        let h = self.client.heard();
        let sent = Sent { text, uri: uri.clone(), version: 1, at: Instant::now(), publishes: h.publishes, checks: checks_ended(h) };
        let open = json!({"textDocument": {"uri": uri, "languageId": language_id(&self.language_id, rel), "version": 1, "text": sent.text}});
        self.client.notify("textDocument/didOpen", open).map_err(|e| self.said(e))?;
        if self.settle == Settle::Check {
            // rust-analyzer starts its check when a file is saved, not when it is opened.
            self.client.notify("textDocument/didSave", json!({"textDocument": {"uri": uri}})).map_err(|e| self.said(e))?;
        }
        self.opened.insert(rel.to_vec(), sent);
        Ok(uri)
    }

    // A server is asked once it is ready: silent for a moment since the file
    // was sent (sent at), with no work-done progress running (a server
    // loading its workspace or project says so) and not saying it is busy.
    // rust-analyzer answers from a workspace it has not loaded yet, so it is
    // asked only once it has said it is quiescent; its check runs under
    // progress of its own and is not waited for. Ok(false): not by the
    // deadline.
    fn ready(&mut self, at: Instant) -> Result<bool, String> {
        let check = self.settle == Settle::Check;
        let ready = |h: &Heard| {
            if check {
                h.quiescent == Some(true)
            } else {
                h.last_heard.max(at).elapsed() >= SILENCE && h.working.is_empty() && h.quiescent != Some(false)
            }
        };
        self.client.wait_until(self.deadline, ready).map_err(|e| self.said(e))
    }

    // Takes in what the server sends until it has been silent for SILENCE.
    fn last_set(&mut self) -> Result<(), String> {
        self.client.wait_until(self.deadline, |h| h.last_heard.elapsed() >= SILENCE).map(|_| ()).map_err(|e| self.said(e))
    }

    // The file's set published after the publish numbered after for version,
    // as items; none when there is none.
    fn items(&self, key: &[u8], after: u64, version: i64) -> Vec<Diag> {
        current(self.client.heard(), key, after, version).map(|ds| ds.iter().map(diag).collect()).unwrap_or_default()
    }

    fn left(&self) -> Duration {
        self.deadline.saturating_duration_since(Instant::now())
    }

    fn said(&self, e: LspError) -> String {
        match e {
            LspError::Timeout(method) => format!("no answer to {method} {}", within()),
            LspError::Closed => format!("the {} language server stopped before it answered; see {}", self.lang, lossy(&self.log)),
            other => other.to_string(),
        }
    }
}

// The diagnostics the server last published for the file, if it published
// them after the publish numbered after and for the version sent last (or
// when the server says no version).
fn current<'a>(h: &'a Heard, key: &[u8], after: u64, version: i64) -> Option<&'a [Value]> {
    let p = h.published.get(key)?;
    (p.seq > after && p.version.is_none_or(|v| v == version)).then_some(&p.diagnostics[..])
}

// rust-analyzer's checks: work under a "flycheck" token (its title is
// "cargo check").
fn is_check(token: &str) -> bool {
    token.contains("flycheck") || token.contains("cargo check")
}

fn checks_ended(h: &Heard) -> u64 {
    h.ended.iter().filter(|(t, _)| is_check(t)).map(|(_, n)| n).sum()
}

fn checking(h: &Heard) -> bool {
    h.working.keys().any(|t| is_check(t))
}

// rust-analyzer's own words, in its status message, for a check that did not
// judge the code: its flycheck could not run, or a build script failed, which
// stops cargo before the crate itself is compiled. Its other warnings (no
// standard library sources, no proc-macro server) leave cargo check as it
// was, and a set with no error under them is clean. The answer is what the
// server said from there on: the first two lines that hold text, at most 300
// characters (what follows them is a build log).
fn check_not_run(s: &Status) -> Option<String> {
    if s.health == "ok" {
        return None;
    }
    let from = ["Failed to run build scripts", "cargo check failed to start"].iter().filter_map(|said| s.message.find(said)).min()?;
    let said: Vec<&str> = s.message[from..].lines().map(str::trim).filter(|l| !l.is_empty()).take(2).collect();
    let mut why = said.join(" ");
    if let Some((cut, _)) = why.char_indices().nth(300) {
        why.truncate(cut);
    }
    Some(why.trim_end_matches(':').to_string())
}

fn diag(d: &Value) -> Diag {
    let at = |part: &str| d["range"]["start"][part].as_u64().unwrap_or(0) + 1;
    Diag {
        line: at("line"),
        col: at("character"),
        // The protocol leaves a missing severity to the client: an error, so
        // it is not passed over.
        severity: match d["severity"].as_u64() {
            Some(2) => "warning",
            Some(3) => "info",
            Some(4) => "hint",
            _ => "error",
        },
        code: match &d["code"] {
            Value::String(s) => s.clone(),
            Value::Number(n) => n.to_string(),
            _ => String::new(),
        },
        message: d["message"].as_str().unwrap_or_default().to_string(),
    }
}

// What didOpen says a file is: the server's language, except that the
// TypeScript server also reads JavaScript and JSX, which it is told apart
// (told a .js file is TypeScript, it holds it to TypeScript's rules).
fn language_id<'a>(server: &'a str, rel: &[u8]) -> &'a str {
    if server != "typescript" {
        return server;
    }
    let ends = |e: &str| rel.ends_with(e.as_bytes());
    if ends(".tsx") {
        "typescriptreact"
    } else if ends(".jsx") {
        "javascriptreact"
    } else if ends(".js") || ends(".mjs") || ends(".cjs") {
        "javascript"
    } else {
        "typescript"
    }
}

fn within() -> String {
    format!("within the {} s this command may take (SWAN_LIVE_BUDGET_MS)", budget().as_secs_f64())
}

fn lossy(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

fn read_text(path: &[u8], rel: &[u8]) -> Result<String, String> {
    let mut bytes = Vec::new();
    if !sys::read_file(path, &mut bytes) {
        return Err(format!("cannot read {}", lossy(rel)));
    }
    String::from_utf8(bytes).map_err(|_| format!("{} is not UTF-8 text", lossy(rel)))
}

/// A file named on the command line, relative to the repo (its real path)
/// or absolute: its path from the repo. Refused, before any server starts,
/// when it is not there, when it leaves the repo ("../", an absolute path
/// elsewhere, a symlink out), or when it is not UTF-8 text.
pub fn file_in(repo: &[u8], arg: &[u8]) -> Result<Vec<u8>, String> {
    let shown = lossy(arg);
    let path = if arg.starts_with(b"/") { arg.to_vec() } else { [repo, b"/", arg].concat() };
    let Some(real) = sys::realpath(&path) else { return Err(format!("no such file: {shown}")) };
    if !(real.len() > repo.len() + 1 && real.starts_with(repo) && real[repo.len()] == b'/') {
        return Err(format!("{shown} is not inside the repo {}", lossy(repo)));
    }
    if !std::fs::metadata(sys::path(&real)).is_ok_and(|m| m.is_file()) {
        return Err(format!("{shown} is not a file"));
    }
    let rel = real[repo.len() + 1..].to_vec();
    read_text(&real, &rel)?;
    Ok(rel)
}

/// swan lsp-ask <repo> <out-dir> <file> <method> [line col] [more]: prints
/// {"ok":true,"result":<the server's own result>}, or {"ok":false,"error":...}
/// and returns false.
pub fn lsp_ask_main(repo: &[u8], out: &[u8], file: &[u8], method: &str, place: Option<(u32, u32)>, more: &[u8]) -> bool {
    let deadline = Instant::now() + budget();
    let answer = ask(repo, out, file, method, place, more, deadline);
    let text = match &answer {
        Ok(result) => format!("{{\"ok\":true,\"result\":{result}}}"),
        Err(why) => format!("{{\"ok\":false,\"error\":{}}}", Value::String(why.clone())),
    };
    crate::util::print(text.as_bytes());
    answer.is_ok()
}

fn ask(repo: &[u8], out: &[u8], file: &[u8], method: &str, place: Option<(u32, u32)>, more: &[u8], deadline: Instant) -> Result<Value, String> {
    let more = if more.is_empty() {
        Map::new()
    } else {
        match serde_json::from_slice([b"{", more, b"}"].concat().as_slice()) {
            Ok(Value::Object(m)) => m,
            _ => return Err(format!("more is not members of a JSON object: {}", lossy(more))),
        }
    };
    let Some(repo) = sys::realpath(repo).filter(|r| sys::is_dir(r)) else { return Err(format!("no such folder: {}", lossy(repo))) };
    let Some(out) = sys::realpath(out).filter(|o| sys::is_dir(o)) else { return Err(format!("no such folder: {}", lossy(out))) };
    let rel = file_in(&repo, file)?;
    let Some((lang, entry)) = language_of(&rel).map_err(|why| lossy(&why))? else { return Err(format!("no live server for {}", lossy(&rel))) };
    let mut walk = Walk::default();
    walk.load(&repo, &out);
    let mut live = Live::start(&walk, &repo, &out, &lang, &entry, deadline).map_err(|r| r.why)?;
    let answer = live.request(&rel, method, place, more);
    live.stop();
    answer
}


#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStringExt;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> (Scratch, Vec<u8>) {
            let dir = std::env::temp_dir().join(format!("swan-live-unit-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            let real = dir.canonicalize().unwrap();
            let bytes = real.clone().into_os_string().into_vec();
            (Scratch(real), bytes)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn fake_entry(mode: &str, settle: &str, quiet_ms: u64, events: Option<&[u8]>) -> Entry {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_lsp.py");
        let mut c = json!({"cmd": ["python3", "-I", fake, mode], "language_id": "fake", "settle": settle});
        if quiet_ms > 0 {
            c["quiet_ms"] = json!(quiet_ms);
        }
        if let Some(ev) = events {
            c["env"] = json!([format!("FAKE_EVENTS={}", lossy(ev))]);
        }
        serde_json::from_value(json!({"match": [".fake"], "lsp": [c]})).unwrap()
    }

    fn read_events(path: &[u8]) -> Vec<Value> {
        std::fs::read_to_string(sys::path(path))
            .unwrap_or_default()
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    fn real_entry(lang: &str) -> Entry {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").canonicalize().unwrap();
        let home = root.to_str().unwrap();
        let raw = std::fs::read_to_string(root.join("tools/modules.json")).unwrap();
        let expanded = raw
            .replace("{tools}", &format!("{home}/.tools"))
            .replace("{bin}", &format!("{home}/tools/node_modules/.bin"))
            .replace("{swan}", home);
        let mods: Value = serde_json::from_str(&expanded).unwrap();
        serde_json::from_value(mods[lang].clone()).unwrap()
    }

    fn copy_fixture(fixture: &str, name: &str) -> (Scratch, Vec<u8>, Vec<u8>) {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").canonicalize().unwrap();
        let (scratch, base) = Scratch::new(name);
        let repo = PathBuf::from(lossy(&base)).join("repo");
        let out = PathBuf::from(lossy(&base)).join("out");
        std::fs::create_dir_all(&out).unwrap();
        let status = Command::new("cp").arg("-r").arg(root.join("fixtures").join(fixture)).arg(&repo).status().unwrap();
        assert!(status.success());
        let _ = std::fs::remove_dir_all(repo.join("target"));
        let repo_bytes = repo.canonicalize().unwrap().into_os_string().into_vec();
        let out_bytes = out.canonicalize().unwrap().into_os_string().into_vec();
        (scratch, repo_bytes, out_bytes)
    }

    // Editing a file on disk resyncs it via didChange (whole text, version + 1)
    // and didSave per file independently, and current() waits for the latest
    // version instead of taking stale older-version publishes.
    #[test]
    fn changed_file_sends_did_change_and_did_save_with_incrementing_versions() {
        let (_guard, dir) = Scratch::new("didchange");
        let a = [&dir[..], b"/a.fake"].concat();
        let b = [&dir[..], b"/b.fake"].concat();
        let events = [&dir[..], b"/events.jsonl"].concat();
        std::fs::write(sys::path(&a), "fine\nan ERROR here\n").unwrap();
        std::fs::write(sys::path(&b), "fine\n").unwrap();
        let entry = fake_entry("publish", "publish", 0, Some(&events));
        let mut live = Live::start(&Walk::default(), &dir, &dir, "fake", &entry, Instant::now() + Duration::from_secs(20)).unwrap();

        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));
        assert!(matches!(live.diagnostics(b"b.fake"), Ok(Diagnosed::Settled(items)) if items.is_empty()));

        // Mend a.fake (v2): fake_lsp immediately publishes stale v1 [ERROR], then v2 [].
        std::fs::write(sys::path(&a), "fine\n").unwrap();
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.is_empty()));

        // Break a.fake again (v3): fake_lsp publishes stale v2 [], then v3 [ERROR].
        std::fs::write(sys::path(&a), "line1\nan ERROR again\n").unwrap();
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));

        // Break b.fake (v2, independent of a.fake being at v3).
        std::fs::write(sys::path(&b), "an ERROR in b\n").unwrap();
        assert!(matches!(live.diagnostics(b"b.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));

        // Request after another edit to a.fake (v4) also resyncs cleanly.
        std::fs::write(sys::path(&a), "clean for request\n").unwrap();
        let def = live.request(b"a.fake", "textDocument/definition", Some((1, 1)), Map::new()).unwrap();
        assert!(def[0]["uri"].as_str().unwrap().ends_with("/b.fake"));

        live.stop();

        let evs = read_events(&events);
        let summary: Vec<(&str, &str, Option<i64>, Option<&str>)> = evs
            .iter()
            .map(|e| {
                let method = e["method"].as_str().unwrap();
                let uri = e["params"]["textDocument"]["uri"].as_str().unwrap();
                let file = uri.rsplit('/').next().unwrap();
                let ver = e["params"]["textDocument"]["version"].as_i64();
                let text = e["params"]["contentChanges"][0]["text"].as_str();
                (method, file, ver, text)
            })
            .collect();
        assert_eq!(
            summary,
            vec![
                ("textDocument/didOpen", "a.fake", Some(1), None),
                ("textDocument/didOpen", "b.fake", Some(1), None),
                ("textDocument/didChange", "a.fake", Some(2), Some("fine\n")),
                ("textDocument/didSave", "a.fake", None, None),
                ("textDocument/didChange", "a.fake", Some(3), Some("line1\nan ERROR again\n")),
                ("textDocument/didSave", "a.fake", None, None),
                ("textDocument/didChange", "b.fake", Some(2), Some("an ERROR in b\n")),
                ("textDocument/didSave", "b.fake", None, None),
                ("textDocument/didChange", "a.fake", Some(4), Some("clean for request\n")),
                ("textDocument/didSave", "a.fake", None, None),
            ]
        );
    }

    // Settle::Check: editing a file sends didChange + didSave, starting a new
    // check whose diagnostics replace the earlier set.
    #[test]
    fn check_mode_rechecks_after_edit_on_disk() {
        let (_guard, dir) = Scratch::new("check-edit");
        let file = [&dir[..], b"/a.fake"].concat();
        let events = [&dir[..], b"/events.jsonl"].concat();
        std::fs::write(sys::path(&file), "fine\nan ERROR here\n").unwrap();
        let entry = fake_entry("check", "check", 0, Some(&events));
        let mut live = Live::start(&Walk::default(), &dir, &dir, "fake", &entry, Instant::now() + Duration::from_secs(20)).unwrap();

        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));
        std::fs::write(sys::path(&file), "fine\n").unwrap();
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.is_empty()));
        live.stop();

        let evs = read_events(&events);
        let methods: Vec<&str> = evs.iter().map(|e| e["method"].as_str().unwrap()).collect();
        assert_eq!(methods, ["textDocument/didOpen", "textDocument/didSave", "textDocument/didChange", "textDocument/didSave"]);
    }

    // Servers that omit version in publishDiagnostics settle on the next
    // publish after the change; quiet servers settle clean after silence even
    // when the file had an error on the previous version.
    #[test]
    fn quiet_and_noversion_servers_settle_after_edit() {
        let (_guard, dir) = Scratch::new("quiet-edit");
        let file = [&dir[..], b"/a.fake"].concat();
        std::fs::write(sys::path(&file), "fine\nan ERROR here\n").unwrap();
        let entry = fake_entry("quiet", "publish", 1000, None);
        let mut live = Live::start(&Walk::default(), &dir, &dir, "fake", &entry, Instant::now() + Duration::from_secs(20)).unwrap();

        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));
        std::fs::write(sys::path(&file), "fine\n").unwrap();
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.is_empty()));
        std::fs::write(sys::path(&file), "an ERROR returns\n").unwrap();
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));
        live.stop();

        let (_guard2, dir2) = Scratch::new("noversion-edit");
        let file2 = [&dir2[..], b"/a.fake"].concat();
        std::fs::write(sys::path(&file2), "fine\nan ERROR here\n").unwrap();
        let entry2 = fake_entry("publish-noversion", "publish", 0, None);
        let mut live2 = Live::start(&Walk::default(), &dir2, &dir2, "fake", &entry2, Instant::now() + Duration::from_secs(20)).unwrap();

        assert!(matches!(live2.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));
        std::fs::write(sys::path(&file2), "fine\n").unwrap();
        assert!(matches!(live2.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.is_empty()));
        live2.stop();
    }

    // Settle::Pull: textDocument/diagnostic sees edits resynced via didChange.
    #[test]
    fn pull_mode_reflects_edits_on_disk() {
        let (_guard, dir) = Scratch::new("pull-edit");
        let file = [&dir[..], b"/a.fake"].concat();
        std::fs::write(sys::path(&file), "fine\nan ERROR here\n").unwrap();
        let entry = fake_entry("pull", "pull", 0, None);
        let mut live = Live::start(&Walk::default(), &dir, &dir, "fake", &entry, Instant::now() + Duration::from_secs(20)).unwrap();

        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));
        std::fs::write(sys::path(&file), "fine\n").unwrap();
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.is_empty()));
        live.stop();
    }

    // A file deleted after it was sent triggers textDocument/didClose and
    // returns the read error; if recreated later, it opens again at version 1.
    #[test]
    fn deleted_file_sends_did_close_and_returns_read_error() {
        let (_guard, dir) = Scratch::new("deleted");
        let file = [&dir[..], b"/a.fake"].concat();
        let events = [&dir[..], b"/events.jsonl"].concat();
        std::fs::write(sys::path(&file), "fine\nan ERROR here\n").unwrap();
        let entry = fake_entry("publish", "publish", 0, Some(&events));
        let mut live = Live::start(&Walk::default(), &dir, &dir, "fake", &entry, Instant::now() + Duration::from_secs(20)).unwrap();

        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));
        std::fs::remove_file(sys::path(&file)).unwrap();
        let err = live.diagnostics(b"a.fake").err().expect("deleted file should error");
        assert!(err.contains("cannot read a.fake"), "{err}");

        // Recreated file opens fresh at version 1.
        std::fs::write(sys::path(&file), "fine\n").unwrap();
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.is_empty()));
        live.stop();

        let evs = read_events(&events);
        let summary: Vec<(&str, Option<i64>)> = evs
            .iter()
            .map(|e| (e["method"].as_str().unwrap(), e["params"]["textDocument"]["version"].as_i64()))
            .collect();
        assert_eq!(
            summary,
            vec![
                ("textDocument/didOpen", Some(1)),
                ("textDocument/didClose", None),
                ("textDocument/didOpen", Some(1)),
            ]
        );
    }

    // Notifications sent while Live sat idle between questions are drained
    // before recording publish counters for an edit, so a stale publish is
    // never mistaken for the post-edit set.
    #[test]
    fn drain_discards_stale_publishes_sent_while_idle() {
        let (_guard, dir) = Scratch::new("idle-drain");
        let file = [&dir[..], b"/a.fake"].concat();
        std::fs::write(sys::path(&file), "fine\nan ERROR here\n").unwrap();
        let entry = fake_entry("idle-publish", "publish", 0, None);
        let mut live = Live::start(&Walk::default(), &dir, &dir, "fake", &entry, Instant::now() + Duration::from_secs(20)).unwrap();

        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));
        std::thread::sleep(Duration::from_millis(500));
        std::fs::write(sys::path(&file), "fine\n").unwrap();
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.is_empty()));
        live.stop();
    }

    // On a quiet server, a publish that arrived while Live sat idle after
    // open() must be drained before wait_until() evaluates silence, so an
    // unchanged broken file is never reported clean.
    #[test]
    fn unchanged_file_drains_publishes_arrived_while_idle_on_quiet_server() {
        let (_guard, dir) = Scratch::new("quiet-idle-open");
        let file = [&dir[..], b"/a.fake"].concat();
        std::fs::write(sys::path(&file), "fine\nan ERROR here\n").unwrap();
        let entry = fake_entry("quiet", "publish", 600, None);
        let mut live = Live::start(&Walk::default(), &dir, &dir, "fake", &entry, Instant::now() + Duration::from_secs(20)).unwrap();

        live.open(b"a.fake").unwrap();
        // Wait past both the 0.5 s error publish and the 0.6 s quiet window so
        // the unread publish sits buffered in the channel when diagnostics() runs.
        std::thread::sleep(Duration::from_millis(900));
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));
        live.stop();
    }

    // close_if_open() sends didClose once for an open file, ignores files that
    // were never opened, and forgets the entry so a later open() sends didOpen v1.
    #[test]
    fn close_if_open_notifies_only_when_open_and_forgets_entry() {
        let (_guard, dir) = Scratch::new("close-if-open");
        let file = [&dir[..], b"/a.fake"].concat();
        let events = [&dir[..], b"/events.jsonl"].concat();
        std::fs::write(sys::path(&file), "fine\n").unwrap();
        let entry = fake_entry("publish", "publish", 0, Some(&events));
        let mut live = Live::start(&Walk::default(), &dir, &dir, "fake", &entry, Instant::now() + Duration::from_secs(20)).unwrap();

        live.close_if_open(b"never.fake");
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.is_empty()));
        live.close_if_open(b"a.fake");
        live.close_if_open(b"a.fake");
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.is_empty()));
        live.stop();

        let evs = read_events(&events);
        let summary: Vec<(&str, Option<i64>)> = evs
            .iter()
            .map(|e| (e["method"].as_str().unwrap(), e["params"]["textDocument"]["version"].as_i64()))
            .collect();
        assert_eq!(
            summary,
            vec![
                ("textDocument/didOpen", Some(1)),
                ("textDocument/didClose", None),
                ("textDocument/didOpen", Some(1)),
            ]
        );
    }

    // begin() sets a fresh deadline for the next question: a short or expired
    // deadline ends promptly, and a later begin() lets the same Live answer.
    #[test]
    fn begin_sets_a_fresh_deadline_per_question() {
        let (_guard, dir) = Scratch::new("begin-deadline");
        let file = [&dir[..], b"/a.fake"].concat();
        std::fs::write(sys::path(&file), "fine\nan ERROR here\n").unwrap();
        let entry = fake_entry("silent", "publish", 0, None);
        let mut live = Live::start(&Walk::default(), &dir, &dir, "fake", &entry, Instant::now() + Duration::from_secs(20)).unwrap();

        let t0 = Instant::now();
        live.begin(Instant::now() + Duration::from_millis(300));
        assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Unsettled(_))));
        assert!(t0.elapsed() < Duration::from_secs(2), "took {:?}", t0.elapsed());
        live.stop();

        let (_guard2, dir2) = Scratch::new("begin-recover");
        let file2 = [&dir2[..], b"/a.fake"].concat();
        std::fs::write(sys::path(&file2), "fine\nan ERROR here\n").unwrap();
        let entry2 = fake_entry("publish", "publish", 0, None);
        let mut live2 = Live::start(&Walk::default(), &dir2, &dir2, "fake", &entry2, Instant::now() + Duration::from_secs(20)).unwrap();

        live2.begin(Instant::now());
        assert!(matches!(live2.diagnostics(b"a.fake"), Ok(Diagnosed::Unsettled(_))));

        live2.begin(Instant::now() + Duration::from_secs(20));
        assert!(matches!(live2.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));
        live2.stop_within(Duration::from_secs(3));
    }

    // current() accepts only the set published for the version sent last, or
    // for a server that omits version, a set published after the change.
    #[test]
    fn current_matches_latest_version_and_no_version_by_publishes() {
        use crate::lsp::Published;

        let key = b"/repo/a.fake".to_vec();
        let make = |seq: u64, version: Option<i64>| {
            let mut published = HashMap::new();
            published.insert(key.clone(), Published { seq, version, diagnostics: vec![json!({"message": "err"})] });
            Heard { published, publishes: seq, working: HashMap::new(), ended: HashMap::new(), quiescent: None, status: None, last_heard: Instant::now() }
        };

        let h1 = make(1, Some(1));
        assert!(current(&h1, &key, 0, 1).is_some());
        assert!(current(&h1, &key, 0, 2).is_none());
        assert!(current(&h1, &key, 1, 1).is_none());

        let h2 = make(2, Some(2));
        assert!(current(&h2, &key, 1, 2).is_some());
        assert!(current(&h2, &key, 1, 1).is_none());

        let h_none = make(2, None);
        assert!(current(&h_none, &key, 1, 2).is_some());
        assert!(current(&h_none, &key, 2, 2).is_none());
    }

    // is_alive() is true for a running server and false once the server dies
    // mid-question or exits while idle; open() sends didOpen for warm-up.
    #[test]
    fn is_alive_reports_false_after_server_dies() {
        let (_guard, dir) = Scratch::new("alive");
        let file = [&dir[..], b"/a.fake"].concat();
        std::fs::write(sys::path(&file), "fine\n").unwrap();
        let entry = fake_entry("die", "publish", 0, None);
        let mut live = Live::start(&Walk::default(), &dir, &dir, "fake", &entry, Instant::now() + Duration::from_secs(20)).unwrap();

        assert!(live.is_alive());
        let uri = live.open(b"a.fake").unwrap();
        assert!(uri.ends_with("/a.fake"));
        assert!(live.diagnostics(b"a.fake").is_err());
        assert!(!live.is_alive());
        live.stop();
    }

    #[test]
    #[ignore = "requires lua-language-server (.tools/lua-ls/bin/lua-language-server) not present in this scratch copy"]
    fn lua_live_edit_and_mend_in_same_server() {
        let (_guard, repo, out) = copy_fixture("lsp-lua", "real-lua");
        let file = [&repo[..], b"/alpha.lua"].concat();
        let orig = std::fs::read_to_string(sys::path(&file)).unwrap();
        std::fs::write(sys::path(&file), format!("{orig}\nlocal broken = (1 +\n")).unwrap();
        let entry = real_entry("lua");
        let mut walk = Walk::default();
        walk.load(&repo, &out);
        let mut live = Live::start(&walk, &repo, &out, "lua", &entry, Instant::now() + Duration::from_secs(60)).unwrap();

        live.begin(Instant::now() + Duration::from_secs(60));
        let broken = live.diagnostics(b"alpha.lua").unwrap();
        assert!(matches!(broken, Diagnosed::Settled(ref items) if items.iter().any(|d| d.severity == "error")));
        std::fs::write(sys::path(&file), orig).unwrap();
        live.begin(Instant::now() + Duration::from_secs(60));
        let fixed = live.diagnostics(b"alpha.lua").unwrap();
        assert!(matches!(fixed, Diagnosed::Settled(ref items) if !items.iter().any(|d| d.severity == "error")));
        live.stop_within(Duration::from_secs(3));
    }

    // Makes <swan_home()>/bin/eggshell point at the repo's bin/eggshell while
    // a sealed real-server unit test runs, removing only what it created.
    struct TempEggshell {
        link: Option<PathBuf>,
        dir: Option<PathBuf>,
    }

    impl TempEggshell {
        fn ensure() -> TempEggshell {
            let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").canonicalize().unwrap();
            let src = root.join("bin/eggshell");
            assert!(src.exists(), "bin/eggshell is missing at {}", src.display());
            let home = PathBuf::from(lossy(&crate::run::swan_home()));
            let bin = home.join("bin");
            let dst = bin.join("eggshell");
            if dst.exists() {
                return TempEggshell { link: None, dir: None };
            }
            let created_dir = !bin.exists();
            if created_dir {
                std::fs::create_dir_all(&bin).unwrap();
            }
            std::os::unix::fs::symlink(&src, &dst).unwrap();
            TempEggshell { link: Some(dst), dir: created_dir.then_some(bin) }
        }
    }

    impl Drop for TempEggshell {
        fn drop(&mut self) {
            if let Some(link) = &self.link {
                let _ = std::fs::remove_file(link);
            }
            if let Some(dir) = &self.dir {
                let _ = std::fs::remove_dir(dir);
            }
        }
    }

    #[test]
    #[ignore = "requires rust-analyzer (.tools/rust-analyzer/rust-analyzer) not present in this scratch copy; run with SWAN_TRUST_BUILD=1 for fixtures/tiny-rs"]
    fn rust_live_edit_and_mend_in_same_server() {
        let (_guard, repo, out) = copy_fixture("tiny-rs", "real-rust");
        let file = [&repo[..], b"/src/lib.rs"].concat();
        let orig = std::fs::read_to_string(sys::path(&file)).unwrap();
        std::fs::write(sys::path(&file), format!("{orig}\npub fn broken() -> Tile {{ Tile::new(1, 2) }}\n")).unwrap();
        let entry = real_entry("rust");
        let mut walk = Walk::default();
        walk.load(&repo, &out);
        let mut live = Live::start(&walk, &repo, &out, "rust", &entry, Instant::now() + Duration::from_secs(90))
            .unwrap_or_else(|r| panic!("rust_live_edit_and_mend_in_same_server requires SWAN_TRUST_BUILD=1 for fixtures/tiny-rs: {}", r.why));

        live.begin(Instant::now() + Duration::from_secs(90));
        let broken = live.diagnostics(b"src/lib.rs").unwrap();
        assert!(matches!(broken, Diagnosed::Settled(ref items) if items.iter().any(|d| d.code == "E0061")));
        std::fs::write(sys::path(&file), orig).unwrap();
        live.begin(Instant::now() + Duration::from_secs(90));
        let fixed = live.diagnostics(b"src/lib.rs").unwrap();
        assert!(matches!(fixed, Diagnosed::Settled(ref items) if !items.iter().any(|d| d.severity == "error")));
        live.stop_within(Duration::from_secs(3));
    }

    #[test]
    #[ignore = "requires gopls, solidlsp (.tools/solidlsp/venv/bin/python) and bin/eggshell not present in this scratch copy"]
    fn go_live_edit_and_mend_in_same_server() {
        let _eggshell = TempEggshell::ensure();
        let (_guard, repo, out) = copy_fixture("tiny-go", "real-go");
        let file = [&repo[..], b"/main.go"].concat();
        let orig = std::fs::read_to_string(sys::path(&file)).unwrap();
        std::fs::write(sys::path(&file), format!("{orig}\nvar broken int = \"text\"\n")).unwrap();
        let entry = real_entry("go");
        let mut walk = Walk::default();
        walk.load(&repo, &out);
        let mut live = Live::start(&walk, &repo, &out, "go", &entry, Instant::now() + Duration::from_secs(90)).unwrap();

        live.begin(Instant::now() + Duration::from_secs(90));
        let broken = live.diagnostics(b"main.go").unwrap();
        assert!(matches!(broken, Diagnosed::Settled(ref items) if items.iter().any(|d| d.severity == "error")));
        std::fs::write(sys::path(&file), orig).unwrap();
        live.begin(Instant::now() + Duration::from_secs(90));
        let fixed = live.diagnostics(b"main.go").unwrap();
        assert!(matches!(fixed, Diagnosed::Settled(ref items) if !items.iter().any(|d| d.severity == "error")));
        live.stop_within(Duration::from_secs(3));
    }
}
