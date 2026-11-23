// A language server, run as a child and asked over its stdin and stdout:
// JSON-RPC framed by lsp-server's Message. Synchronous: one question at a
// time, each with a deadline, and the server's own requests answered while
// it waits. A reader thread turns the server's output into messages and a
// writer thread feeds its input, so neither a silent server nor one that
// stops reading can hold this process: every failure is an LspError. The
// server runs in a process group of its own, killed when the client is shut
// down or dropped, so nothing it started outlives the command.

use std::ffi::OsStr;
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{BufReader, ErrorKind, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use lsp_server::{Message, Notification, Request, RequestId, Response};
use serde_json::{json, Value};

use crate::modules::ServerSpec;
use crate::sys;
use crate::seal::{inside_seal, sandbox_on, seal_argv};

#[derive(Debug)]
pub enum LspError {
    /// The server could not be started: why.
    Start(String),
    /// No answer to this method in the time allowed.
    Timeout(String),
    /// The server answered with an error.
    Server { code: i32, message: String },
    /// The server's output ended: it exited, or closed it.
    Closed,
}

impl fmt::Display for LspError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LspError::Start(why) => write!(f, "{why}"),
            LspError::Timeout(method) => write!(f, "no answer to {method} in time"),
            LspError::Server { code, message } => write!(f, "the server answered {code}: {message}"),
            LspError::Closed => write!(f, "the server stopped"),
        }
    }
}

pub struct Client {
    child: Child,
    /// The server's process group, until it is killed.
    group: Option<i32>,
    /// To the writer thread; None once the server's input is closed.
    input: Option<Sender<Vec<u8>>>,
    output: Receiver<Message>,
    next_id: i32,
    /// The entry's "init": initializationOptions, and the answer to
    /// workspace/configuration.
    settings: Value,
    root_uri: String,
    log: File,
}

impl Client {
    /// Starts the server in workspace (the repo, or a folder of it) and
    /// initializes it. A "sealed" server runs inside eggshell, like the
    /// map's indexers, unless this process already does: swan map starts
    /// its children sealed, and a seal cannot be set up inside another. The
    /// server's stderr and the client's notes go to log.
    pub fn start(spec: &ServerSpec, repo: &[u8], workspace: &[u8], out: &[u8], log: &[u8], timeout: Duration) -> Result<Client, LspError> {
        let argv: Vec<Vec<u8>> = if spec.sealed && sandbox_on() && !inside_seal() {
            let inner: Vec<&[u8]> = spec.cmd.iter().map(|a| &a[..]).collect();
            seal_argv(&inner, repo, out, false)
        } else {
            spec.cmd.clone()
        };
        let Some((program, args)) = argv.split_first() else {
            return Err(LspError::Start("the server has no command".to_string()));
        };
        let opened = OpenOptions::new().create(true).append(true).open(OsStr::from_bytes(log));
        let log = opened.map_err(|e| LspError::Start(format!("cannot open {}: {e}", String::from_utf8_lossy(log))))?;
        let cannot = |e: std::io::Error| LspError::Start(format!("cannot start {}: {e}", String::from_utf8_lossy(program)));
        let mut cmd = Command::new(OsStr::from_bytes(program));
        cmd.args(args.iter().map(|a| OsStr::from_bytes(a)))
            .current_dir(OsStr::from_bytes(workspace))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(log.try_clone().map_err(cannot)?)
            .process_group(0);
        sys::set_env(&mut cmd, &spec.env);
        let mut child = cmd.spawn().map_err(cannot)?;
        let group = child.id() as i32;
        let (Some(mut stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
            unsafe { libc::kill(-group, libc::SIGKILL) };
            let _ = child.wait();
            return Err(LspError::Start("the server has no pipes".to_string()));
        };
        let (input, to_write) = mpsc::channel::<Vec<u8>>();
        std::thread::spawn(move || {
            for bytes in to_write {
                if stdin.write_all(&bytes).and_then(|()| stdin.flush()).is_err() {
                    break;
                }
            }
        });
        let (got, output) = mpsc::channel();
        let mut notes = log.try_clone().map_err(cannot)?;
        std::thread::spawn(move || {
            let mut from = BufReader::new(stdout);
            loop {
                match Message::read(&mut from) {
                    Ok(Some(m)) => {
                        if got.send(m).is_err() {
                            break;
                        }
                    }
                    // A garbled message is passed over; the next is read from where it ended.
                    Err(e) if e.kind() == ErrorKind::InvalidData => {
                        let _ = writeln!(notes, "swan: a message from the server was not read: {e}");
                    }
                    Ok(None) | Err(_) => break,
                }
            }
        });
        let root_uri = file_uri(workspace);
        let mut client = Client { child, group: Some(group), input: Some(input), output, next_id: 1, settings: spec.init.clone(), root_uri, log };
        let init = json!({
            "processId": null,
            "rootUri": client.root_uri,
            "initializationOptions": client.settings,
            "capabilities": {
                "experimental": {"serverStatusNotification": true},
                "window": {"workDoneProgress": true},
                "workspace": {"configuration": true},
                "textDocument": {
                    "publishDiagnostics": {},
                    "documentSymbol": {"hierarchicalDocumentSymbolSupport": true},
                    "implementation": {"linkSupport": false},
                    "synchronization": {"didSave": true}
                }
            },
            "workspaceFolders": [{"uri": client.root_uri, "name": "repo"}]
        });
        if let Err(e) = client.request("initialize", init, timeout) {
            client.note(&format!("initialize failed: {e}"));
            return Err(e);
        }
        client.notify("initialized", json!({}))?;
        Ok(client)
    }

    /// The URI of a file, by its path from the workspace.
    pub fn uri(&self, rel: &[u8]) -> String {
        let mut u = self.root_uri.clone();
        u.push('/');
        push_encoded(&mut u, rel);
        u
    }

    /// Asks and waits up to timeout for the answer, answering what the
    /// server asks meanwhile.
    pub fn request(&mut self, method: &str, params: Value, timeout: Duration) -> Result<Value, LspError> {
        let id = self.next_id;
        self.next_id += 1;
        self.send(Request { id: id.into(), method: method.to_string(), params }.into())?;
        let mine = RequestId::from(id);
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                self.note(&format!("no answer to {method} after {} ms", timeout.as_millis()));
                return Err(LspError::Timeout(method.to_string()));
            }
            match self.output.recv_timeout(left) {
                Ok(Message::Response(r)) if r.id == mine => {
                    return r.response_result.map_err(|e| LspError::Server { code: e.code, message: e.message });
                }
                Ok(Message::Request(asked)) => self.answer(asked)?,
                // Notifications, and late answers to questions given up on.
                Ok(_) | Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return Err(LspError::Closed),
            }
        }
    }

    pub fn notify(&mut self, method: &str, params: Value) -> Result<(), LspError> {
        self.send(Notification::new(method.to_string(), params).into())
    }

    /// Asks the server to shut down and exit, then stops it.
    pub fn shutdown(mut self) {
        // A server that does not take part is killed all the same.
        let _ = self.request("shutdown", Value::Null, Duration::from_secs(5));
        let _ = self.notify("exit", Value::Null);
        self.stop(Duration::from_secs(3));
    }

    // workspace/configuration is answered from the settings, item by item;
    // anything else the server asks (client/registerCapability,
    // window/workDoneProgress/create) with null.
    fn answer(&mut self, asked: Request) -> Result<(), LspError> {
        let result = if asked.method == "workspace/configuration" { configuration(&self.settings, &asked.params) } else { Value::Null };
        self.send(Response::new_ok(asked.id, result).into())
    }

    fn send(&mut self, msg: Message) -> Result<(), LspError> {
        let mut bytes = Vec::new();
        if msg.write(&mut bytes).is_err() {
            return Err(LspError::Closed);
        }
        match &self.input {
            Some(input) if input.send(bytes).is_ok() => Ok(()),
            _ => Err(LspError::Closed),
        }
    }

    fn note(&mut self, s: &str) {
        let _ = writeln!(self.log, "swan: {s}");
    }

    // Closes the server's input, gives it grace to exit, then kills its
    // whole group (what it started too) and reaps it. Once only.
    fn stop(&mut self, grace: Duration) {
        let Some(group) = self.group.take() else { return };
        self.input = None;
        let until = Instant::now() + grace;
        while Instant::now() < until && !exited(group) {
            std::thread::sleep(Duration::from_millis(20));
        }
        unsafe { libc::kill(-group, libc::SIGKILL) };
        let _ = self.child.wait();
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        self.stop(Duration::ZERO);
    }
}

// Whether the process has ended, without reaping it: the group is killed
// while its leader's id is still held, so it cannot name another group.
fn exited(pid: i32) -> bool {
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    let r = unsafe { libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOHANG | libc::WNOWAIT) };
    r == 0 && unsafe { info.si_pid() } != 0
}

// One answer per item asked for: the section of the settings named exactly
// so ("python.analysis"), else the path its dots spell, else all of them
// (how rust-analyzer asks for its own).
fn configuration(settings: &Value, params: &Value) -> Value {
    let items = params.get("items").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    let section = |name: &str| settings.get(name).or_else(|| name.split('.').try_fold(settings, |at, part| at.get(part)));
    let one = |item: &Value| item.get("section").and_then(Value::as_str).and_then(section).unwrap_or(settings).clone();
    Value::Array(items.iter().map(one).collect())
}

pub fn file_uri(path: &[u8]) -> String {
    let mut u = String::from("file://");
    push_encoded(&mut u, path);
    u
}

// A path as a URI's path: bytes other than letters, digits, - . _ ~ and /
// are %XX, so that "a#b.go" or a space is not read as a fragment or a break.
fn push_encoded(u: &mut String, path: &[u8]) {
    for &c in path {
        if c.is_ascii_alphanumeric() || b"-._~/".contains(&c) {
            u.push(c as char);
        } else {
            u.push_str(&format!("%{c:02X}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStringExt;

    fn fake(script: &str) -> ServerSpec {
        ServerSpec { cmd: vec![b"/bin/sh".to_vec(), b"-c".to_vec(), script.as_bytes().to_vec()], env: Vec::new(), language_id: "go".to_string(), init: json!({}), sealed: false }
    }

    fn scratch(name: &str) -> Vec<u8> {
        let dir = std::env::temp_dir().join(format!("swan-lsp-test-{}-{name}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        dir.into_os_string().into_vec()
    }

    // Whether any process of the group runs: one killed is gone once its
    // parent (init, for the shell's cat) has reaped it.
    fn group_alive(group: i32) -> bool {
        let until = Instant::now() + Duration::from_secs(2);
        while Instant::now() < until {
            if unsafe { libc::kill(-group, 0) } != 0 {
                return false;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        true
    }

    // A server that reads and never answers (a shell waiting on cat, which
    // reads): start gives up at its deadline and leaves nothing of its
    // process group behind.
    #[test]
    fn a_silent_server_times_out_and_is_killed() {
        let dir = scratch("silent");
        let pid_file = [&dir[..], b"/pid"].concat();
        let script = format!("echo $$ > {}; cat > /dev/null", String::from_utf8_lossy(&pid_file));
        let log = [&dir[..], b"/log"].concat();
        let t0 = Instant::now();
        let r = Client::start(&fake(&script), &dir, &dir, &dir, &log, Duration::from_millis(1500));
        let took = t0.elapsed();
        assert!(matches!(r, Err(LspError::Timeout(ref m)) if m == "initialize"), "{:?}", r.err());
        assert!(took >= Duration::from_millis(1500) && took < Duration::from_secs(5), "{took:?}");
        let pid: i32 = std::fs::read_to_string(std::str::from_utf8(&pid_file).unwrap()).unwrap().trim().parse().unwrap();
        assert!(!group_alive(pid), "the server's group {pid} is still running");
    }

    // A server that exits at once: start fails at once, not at the deadline.
    #[test]
    fn a_server_that_exits_fails_at_once() {
        let dir = scratch("exits");
        let log = [&dir[..], b"/log"].concat();
        let t0 = Instant::now();
        let r = Client::start(&fake("exit 3"), &dir, &dir, &dir, &log, Duration::from_secs(30));
        assert!(matches!(r, Err(LspError::Closed)), "{:?}", r.err());
        assert!(t0.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_missing_server_fails_to_start() {
        let dir = scratch("missing");
        let log = [&dir[..], b"/log"].concat();
        let spec = ServerSpec { cmd: vec![b"/nonexistent/server".to_vec()], ..fake("") };
        assert!(matches!(Client::start(&spec, &dir, &dir, &dir, &log, Duration::from_secs(30)), Err(LspError::Start(_))));
    }

    #[test]
    fn configuration_is_answered_by_section() {
        let settings = json!({"python": {"analysis": {"x": 1}}, "rust-analyzer.cargo": 2});
        let asked = json!({"items": [{"section": "python.analysis"}, {"section": "rust-analyzer.cargo"}, {"section": "nothing"}, {}]});
        assert_eq!(configuration(&settings, &asked), json!([{"x": 1}, 2, settings.clone(), settings.clone()]));
    }
}
