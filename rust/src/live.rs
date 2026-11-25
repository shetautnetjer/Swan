// Live answers: one language server, started for one language of one repo
// and asked about files as they stand on disk. swan lsp-ask and swan broke
// use it, one process each. The rules for when a server has had its say
// were learned by the Goose program's client (lsp/golsp.goose), whose
// lessons are carried here with their reasons.
//
// The contract: the file on disk is the truth. A question reads the file,
// opens it in the server (didOpen) with that text, and asks. The server is
// never told that a file changed (didChange): each command asks about a
// file once, so nothing here could use it, and a scripted server would not
// prove it. A second question about a file whose text on disk is no longer
// the text sent is refused, plainly, rather than answered from the old
// text. Whoever keeps a server running across edits builds the re-sync,
// with a real server's test.
//
// Every wait of a command shares one deadline, its budget (100 s, or
// SWAN_LIVE_BUDGET_MS), so the command ends on its own before the hook that
// runs swan broke kills it at 120 s. A settle that does not happen by then is
// not settled, and never a clean answer.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

use crate::lsp::{Client, Heard, LspError, Status};
use crate::modules::{language_of, Entry, Settle};
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
    opened: HashMap<Vec<u8>, Sent>,
}

/// A file as it was sent, and where the server's sayings stood then.
struct Sent {
    text: String,
    uri: String,
    at: Instant,
    publishes: u64,
    checks: u64,
}

impl Live {
    /// Starts lang's live server for repo (its "lsp" entry), the map folder
    /// out holding what it writes and its log.
    pub fn start(walk: &Walk, repo: &[u8], out: &[u8], lang: &str, entry: &Entry, deadline: Instant) -> Result<Live, String> {
        let spec = entry.live_server(walk, repo, out, lang.as_bytes()).map_err(|why| lossy(&why))?;
        let log = [out, b"/lsp-", lang.as_bytes(), b".log"].concat();
        let left = deadline.saturating_duration_since(Instant::now());
        let client = match Client::start(&spec, repo, repo, out, &log, left) {
            Ok(c) => c,
            Err(LspError::Timeout(_)) => return Err(format!("the {lang} language server did not start {}; see {}", within(), lossy(&log))),
            Err(e) => return Err(format!("the {lang} language server did not start: {e}; see {}", lossy(&log))),
        };
        Ok(Live { client, lang: lang.to_string(), language_id: spec.language_id, settle: spec.settle, repo: repo.to_vec(), log, deadline, opened: HashMap::new() })
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
        let (uri, at, publishes, checks) = (sent.uri.clone(), sent.at, sent.publishes, sent.checks);
        let deadline = self.deadline;
        let settled = match self.settle {
            // The file's next published set for the text sent (pyright, the
            // TypeScript server). With quiet: a server that publishes nothing
            // for a clean file (lua-language-server) has said all it will
            // once it has been silent that long since the question.
            Settle::Publish { quiet } => {
                let set = |h: &Heard| current(h, &key, publishes).is_some();
                let silent = |h: &Heard| quiet.is_some_and(|q| at.elapsed() >= q && h.last_heard.max(at).elapsed() >= q);
                let held = self.client.wait_until(deadline, |h| set(h) || silent(h)).map_err(|e| self.said(e))?;
                if held && set(self.client.heard()) {
                    self.last_set()?;
                }
                held.then(|| self.items(&key, publishes))
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
            // While the server says its health is not ok, an error in that
            // set is passed on and a set with none is no answer: the build
            // it calls broken may never have reached the file.
            Settle::Check => {
                let held = self.client.wait_until(deadline, |h| h.quiescent == Some(true) && checks_ended(h) > checks && !checking(h)).map_err(|e| self.said(e))?;
                if !held {
                    return Ok(Diagnosed::Unsettled(self.out_of_time()));
                }
                self.last_set()?;
                let items = self.items(&key, 0);
                if let Some(s) = self.client.heard().status.as_ref().filter(|s| s.health != "ok") {
                    if !items.iter().any(|d| d.severity == "error") {
                        return Ok(Diagnosed::Unsettled(format!("not settled: {}", unhealthy(&self.lang, s))));
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
    pub fn stop(self) {
        let t = self.left().min(Duration::from_secs(3));
        self.client.shutdown_within(t);
    }

    // The file's text as it is on disk now, sent to the server unless it was
    // sent already: its URI. A file whose text changed since is refused.
    fn open(&mut self, rel: &[u8]) -> Result<String, String> {
        let text = read_text(&[&self.repo[..], b"/", rel].concat(), rel)?;
        if let Some(sent) = self.opened.get(rel) {
            if sent.text != text {
                return Err(format!("{} changed on disk after it was sent to the server, which is not told of changes: ask again in a new command", lossy(rel)));
            }
            return Ok(sent.uri.clone());
        }
        let uri = self.client.uri(rel);
        let h = self.client.heard();
        let sent = Sent { text, uri: uri.clone(), at: Instant::now(), publishes: h.publishes, checks: checks_ended(h) };
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

    // The file's set published after the publish numbered after, as items;
    // none when there is none.
    fn items(&self, key: &[u8], after: u64) -> Vec<Diag> {
        current(self.client.heard(), key, after).map(|ds| ds.iter().map(diag).collect()).unwrap_or_default()
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
// them after the publish numbered after and for the text sent (version 1,
// when it says a version).
fn current<'a>(h: &'a Heard, key: &[u8], after: u64) -> Option<&'a [Value]> {
    let p = h.published.get(key)?;
    (p.seq > after && p.version.is_none_or(|v| v == 1)).then_some(&p.diagnostics[..])
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

// Why a server whose health is not ok gave no answer: its status message,
// the first two lines that hold text, at most 300 characters (what follows
// them is a build log).
fn unhealthy(lang: &str, s: &Status) -> String {
    let said: Vec<&str> = s.message.lines().map(str::trim).filter(|l| !l.is_empty()).take(2).collect();
    if said.is_empty() {
        return format!("the {lang} language server says its health is {}", s.health);
    }
    let mut why = said.join(" ");
    if let Some((cut, _)) = why.char_indices().nth(300) {
        why.truncate(cut);
    }
    why.trim_end_matches(':').to_string()
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
    let mut live = Live::start(&walk, &repo, &out, &lang, &entry, deadline)?;
    let answer = live.request(&rel, method, place, more);
    live.stop();
    answer
}


#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStringExt;

    // Asked again about a file whose text on disk is still what was sent, the
    // server answers; once the text has changed, the question is refused
    // rather than answered from the text the server holds.
    #[test]
    fn a_file_changed_since_it_was_sent_is_refused() {
        let dir = std::env::temp_dir().join(format!("swan-live-unit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let dir = dir.canonicalize().unwrap().into_os_string().into_vec();
        let file = [&dir[..], b"/a.fake"].concat();
        std::fs::write(sys::path(&file), "fine\nan ERROR here\n").unwrap();
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_lsp.py");
        let entry: Entry = serde_json::from_value(json!({"match": [".fake"], "lsp": [{"cmd": ["python3", "-I", fake, "publish"], "language_id": "fake"}]})).unwrap();
        let mut live = Live::start(&Walk::default(), &dir, &dir, "fake", &entry, Instant::now() + Duration::from_secs(20)).unwrap();
        for _ in 0..2 {
            assert!(matches!(live.diagnostics(b"a.fake"), Ok(Diagnosed::Settled(items)) if items.len() == 1));
        }
        std::fs::write(sys::path(&file), "fine\n").unwrap();
        let refused = live.request(b"a.fake", "textDocument/definition", Some((1, 1)), Map::new()).unwrap_err();
        assert!(refused.contains("a.fake changed on disk after it was sent to the server"), "{refused}");
        assert!(live.diagnostics(b"a.fake").is_err());
        live.stop();
        let _ = std::fs::remove_dir_all(sys::path(&dir));
    }
}
