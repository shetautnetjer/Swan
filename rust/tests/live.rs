// swan lsp-ask and swan broke against a scripted language server of their
// own (tests/fake_lsp.py), through the built binary: each settle settles on
// what it should and not before, a server that never says its piece or dies
// mid-question is never taken for a clean answer, a file outside the repo is
// refused before any server starts, and broke's seen file and exit codes.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

fn python() -> String {
    let path = std::env::var("PATH").unwrap_or_default();
    path.split(':').map(|d| format!("{d}/python3")).find(|p| Path::new(p).exists()).expect("python3 on PATH")
}

struct Setup {
    home: PathBuf,
    repo: PathBuf,
    map: PathBuf,
}

impl Drop for Setup {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(self.home.parent().unwrap());
    }
}

// The made-up languages of a test home: each file ending is served by
// fake_lsp.py in one mode, with one settle; .nl has no server at all.
const LANGS: &[(&str, &str, &str, &str, u64)] = &[
    ("fake", ".fake", "publish", "publish", 0),
    ("quiet", ".qt", "quiet", "publish", 1000),
    ("pulled", ".pl", "pull", "pull", 0),
    ("checked", ".ck", "check", "check", 0),
    ("silent", ".sl", "silent", "publish", 0),
    ("dies", ".dd", "die", "publish", 0),
    ("stubborn", ".st", "stubborn", "publish", 0),
    ("late", ".lt", "late", "publish", 0),
    ("checkfails", ".cf", "check-fails", "check", 0),
    ("checkwarns", ".cw", "check-warns", "check", 0),
    ("checksysroot", ".sy", "check-sysroot", "check", 0),
];

// A Swan home with only those languages in its tools/modules.json, a repo
// holding a.fake (an error on line 2), b.fake and c.fake (clean), and a map
// folder whose map names the repo.
fn setup(name: &str) -> Setup {
    let dir = std::env::temp_dir().join(format!("swan-live-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    let (home, repo, map) = (dir.join("home"), dir.join("repo"), dir.join("map"));
    for d in [home.join("bin"), home.join("tools"), repo.clone(), map.clone()] {
        fs::create_dir_all(d).unwrap();
    }
    fs::copy(env!("CARGO_BIN_EXE_swan"), home.join("bin/swan")).unwrap();
    let fake = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fake_lsp.py");
    let mut mods = json!({"nolsp": {"match": [".nl"]}});
    for (lang, ext, mode, settle, quiet) in LANGS {
        let mut c = json!({"cmd": [python(), "-I", fake, mode], "language_id": lang, "settle": settle, "env": ["FAKE_PIDS={out}/pids"]});
        if *quiet > 0 {
            c["quiet_ms"] = json!(quiet);
        }
        mods[lang] = json!({"match": [ext], "lsp": [c]});
    }
    fs::write(home.join("tools/modules.json"), mods.to_string()).unwrap();
    fs::write(repo.join("a.fake"), "fine\nan ERROR here\na WARN here\n").unwrap();
    fs::write(repo.join("b.fake"), "fine\n").unwrap();
    fs::write(repo.join("c.fake"), "fine\n").unwrap();
    let repo = repo.canonicalize().unwrap();
    let made = Command::new(python())
        .args(["-I", "-c", "import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)'); c.execute('INSERT INTO meta VALUES (?, ?)', ('root', sys.argv[2])); c.commit()"])
        .arg(map.join("swan.db"))
        .arg(&repo)
        .status()
        .unwrap();
    assert!(made.success());
    Setup { home, repo, map }
}

struct Ran {
    code: i32,
    json: Value,
    took: Duration,
}

fn swan(s: &Setup, args: &[&str], budget_ms: u64) -> Ran {
    let t0 = Instant::now();
    let out = Command::new(s.home.join("bin/swan"))
        .args(args)
        .env_remove("SWAN_TRUST_BUILD")
        .env_remove("SWAN_SANDBOX")
        .env("SWAN_LIVE_BUDGET_MS", budget_ms.to_string())
        .output()
        .unwrap();
    let json = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    Ran { code: out.status.code().unwrap_or(-1), json, took: t0.elapsed() }
}

fn broke(s: &Setup, files: &[&str], budget_ms: u64) -> Ran {
    let mut args = vec!["broke", s.map.to_str().unwrap()];
    args.extend(files);
    swan(s, &args, budget_ms)
}

fn ask(s: &Setup, rest: &[&str], budget_ms: u64) -> Ran {
    let mut args = vec!["lsp-ask", s.repo.to_str().unwrap(), s.map.to_str().unwrap()];
    args.extend(rest);
    swan(s, &args, budget_ms)
}

// For each file of a broke answer: (relative_path, asked, the new errors as
// "line:col code message").
fn files(r: &Ran) -> Vec<(String, bool, Vec<String>)> {
    let list = r.json["files"].as_array().unwrap_or_else(|| panic!("no files in {}", r.json));
    list.iter()
        .map(|f| {
            let news = f["new_errors"].as_array().map(|n| n.iter().map(|e| format!("{}:{} {} {}", e["line"], e["col"], e["code"].as_str().unwrap_or(""), e["message"].as_str().unwrap())).collect()).unwrap_or_default();
            (f["relative_path"].as_str().unwrap().to_string(), f["asked"].as_bool().unwrap(), news)
        })
        .collect()
}

fn why(r: &Ran, i: usize) -> String {
    r.json["files"][i]["why"].as_str().unwrap_or_default().to_string()
}

fn planted(file: &str) -> (String, bool, Vec<String>) {
    (file.to_string(), true, vec!["2:4 E1 planted error".to_string()])
}

fn clean(file: &str) -> (String, bool, Vec<String>) {
    (file.to_string(), true, vec![])
}

// How many servers the runs of this setup started.
fn starts(s: &Setup) -> usize {
    fs::read_to_string(s.map.join("pids")).map_or(0, |t| t.lines().count())
}

// Publish: a set for an older version comes at once and is not the answer;
// the file's own set, half a second later, is. A warning is not an error.
#[test]
fn publish_waits_for_the_set_of_the_text_sent() {
    let s = setup("publish");
    let r = broke(&s, &["a.fake", "b.fake"], 20000);
    assert_eq!(files(&r), [planted("a.fake"), clean("b.fake")], "{}", r.json);
    assert_eq!(r.json["files"][0]["warnings"], 1);
    assert_eq!(r.code, 1);
}

// Publish with quiet_ms (1000): a server that publishes nothing for a clean
// file has said all once it has been silent that long, counted from its last
// word (a log message at 0.7 s), and an error it publishes at 0.5 s is seen.
#[test]
fn quiet_means_silence_since_the_last_word() {
    let s = setup("quiet");
    fs::write(s.repo.join("clean.qt"), "fine\n").unwrap();
    let r = broke(&s, &["clean.qt"], 20000);
    assert_eq!(files(&r), [clean("clean.qt")], "{}", r.json);
    assert!(r.took >= Duration::from_millis(1700), "settled after {:?}, before the silence", r.took);
    fs::write(s.repo.join("bad.qt"), "fine\nan ERROR here\n").unwrap();
    let r = broke(&s, &["bad.qt"], 20000);
    assert_eq!(files(&r), [planted("bad.qt")], "{}", r.json);
}

// Pull: asked only once the work the server reports has ended; asked while
// it loads, it says nothing is wrong.
#[test]
fn pull_asks_once_the_server_is_ready() {
    let s = setup("pull");
    fs::write(s.repo.join("a.pl"), "fine\nan ERROR here\n").unwrap();
    let r = broke(&s, &["a.pl"], 20000);
    assert_eq!(files(&r), [planted("a.pl")], "{}", r.json);
}

// Check: the set published when the file is opened is not the answer; the
// one the check started by the save publishes is, once the server is
// quiescent and the check has ended.
#[test]
fn check_waits_for_the_check_a_save_starts() {
    let s = setup("check");
    fs::write(s.repo.join("a.ck"), "fine\nan ERROR here\n").unwrap();
    let r = broke(&s, &["a.ck"], 20000);
    assert_eq!(files(&r), [planted("a.ck")], "{}", r.json);
}

// Check: a check that ends at once, after which the server says its health
// is not ok (its check failed to start), is no answer for a file with no
// error. Not settled, the why is the server's status in its first two lines
// (not the build log after them), and nothing is remembered.
#[test]
fn a_check_that_did_not_run_is_not_settled() {
    let s = setup("check-fails");
    fs::write(s.repo.join("a.cf"), "fine\nan ERROR here\n").unwrap();
    let r = broke(&s, &["a.cf"], 20000);
    assert_eq!(files(&r), [("a.cf".to_string(), false, vec![])], "{}", r.json);
    let said = "not settled: Failed to run build scripts of some packages. Please refer to the language server logs for more details on the errors.\
                cargo check failed to start: Cargo watcher failed, the command produced no valid metadata (exit code: 101)";
    assert_eq!(why(&r, 0), said);
    assert_eq!(r.code, 3);
    assert!(!s.map.join("broke-seen.tsv").exists(), "a file not asked was remembered");
}

// While the server's status says a build script failed, an error it reports
// is reported; a file with no error in its set (clean, or warnings only) is
// not settled, with the server's status as the why.
#[test]
fn an_unhealthy_server_passes_errors_on_but_no_clean_answer() {
    let s = setup("check-warns");
    fs::write(s.repo.join("a.cw"), "fine\nan ERROR here\n").unwrap();
    let r = broke(&s, &["a.cw"], 20000);
    assert_eq!(files(&r), [planted("a.cw")], "{}", r.json);
    assert_eq!(r.code, 1);
    fs::write(s.repo.join("b.cw"), "fine\n").unwrap();
    fs::write(s.repo.join("c.cw"), "fine\na WARN here\n").unwrap();
    let r = broke(&s, &["b.cw", "c.cw"], 20000);
    assert_eq!(files(&r), [("b.cw".to_string(), false, vec![]), ("c.cw".to_string(), false, vec![])], "{}", r.json);
    let said = "not settled: Failed to run build scripts of some packages. Please refer to the language server logs for more details on the errors.";
    assert_eq!((why(&r, 0), why(&r, 1)), (said.to_string(), said.to_string()));
    assert_eq!(r.code, 3);
    assert!(!fs::read_to_string(s.map.join("broke-seen.tsv")).unwrap().contains("b.cw"), "a file not asked was remembered");
}

// A warning that leaves the check alone (the standard library's sources are
// not installed) is no refusal: a clean file is asked and clean, and an
// error is reported.
#[test]
fn a_warning_that_leaves_the_check_alone_is_no_refusal() {
    let s = setup("check-sysroot");
    fs::write(s.repo.join("b.sy"), "fine\n").unwrap();
    let r = broke(&s, &["b.sy"], 20000);
    assert_eq!(files(&r), [("b.sy".to_string(), true, vec![])], "{}", r.json);
    assert_eq!(r.code, 0);
    fs::write(s.repo.join("a.sy"), "fine\nan ERROR here\n").unwrap();
    let r = broke(&s, &["a.sy"], 20000);
    assert_eq!(files(&r), [planted("a.sy")], "{}", r.json);
    assert_eq!(r.code, 1);
}

// A server that never says its piece: not settled inside a short budget,
// never a clean answer; a question it never answers is an error.
#[test]
fn a_silent_server_is_not_settled_in_time() {
    let s = setup("silent");
    fs::write(s.repo.join("a.sl"), "fine\n").unwrap();
    let r = broke(&s, &["a.sl"], 1500);
    assert_eq!(files(&r), [("a.sl".to_string(), false, vec![])], "{}", r.json);
    assert!(why(&r, 0).starts_with("not settled"), "{}", r.json);
    assert_eq!(r.code, 3);
    assert!(r.took < Duration::from_secs(6), "{:?}", r.took);
    assert!(!s.map.join("broke-seen.tsv").exists(), "a file not asked was remembered");
    let r = ask(&s, &["a.sl", "textDocument/hover", "1", "1"], 1500);
    assert_eq!((r.code, &r.json["ok"]), (1, &json!(false)), "{}", r.json);
    assert!(r.json["error"].as_str().unwrap().starts_with("no answer to textDocument/hover"), "{}", r.json);
    assert!(r.took < Duration::from_secs(6), "{:?}", r.took);
}

// A server that dies mid-question: an error and exit 1, not an answer.
#[test]
fn a_server_that_dies_is_an_error() {
    let s = setup("die");
    fs::write(s.repo.join("a.dd"), "fine\n").unwrap();
    let r = ask(&s, &["a.dd", "textDocument/definition", "1", "1"], 20000);
    assert_eq!((r.code, &r.json["ok"]), (1, &json!(false)), "{}", r.json);
    assert!(r.json["error"].as_str().unwrap().contains("stopped before it answered"), "{}", r.json);
    let r = broke(&s, &["a.dd"], 20000);
    assert_eq!(files(&r), [("a.dd".to_string(), false, vec![])], "{}", r.json);
    assert!(why(&r, 0).contains("stopped before it answered"), "{}", r.json);
    assert_eq!(r.code, 3);
}

// Before any server starts: a path that leaves the repo (../, an absolute
// path elsewhere, a symlink out), a file not there, a file not UTF-8 text,
// and a file whose language has no live server are each refused by name.
#[test]
fn files_outside_the_repo_are_refused_before_a_server_starts() {
    let s = setup("refusals");
    let outside = s.repo.parent().unwrap().join("outside.fake");
    fs::write(&outside, "an ERROR outside\n").unwrap();
    std::os::unix::fs::symlink(&outside, s.repo.join("link.fake")).unwrap();
    fs::write(s.repo.join("latin1.fake"), b"caf\xe9\n").unwrap();
    fs::write(s.repo.join("page.nl"), "fine\n").unwrap();
    let cases = [
        ("../outside.fake", "../outside.fake is not inside the repo"),
        (outside.to_str().unwrap(), "outside.fake is not inside the repo"),
        ("link.fake", "link.fake is not inside the repo"),
        ("missing.fake", "no such file: missing.fake"),
        ("latin1.fake", "latin1.fake is not UTF-8 text"),
        ("page.nl", "no live server for nolsp in tools/modules.json"),
    ];
    for (file, said) in cases {
        let r = ask(&s, &[file, "textDocument/definition", "1", "1"], 20000);
        assert_eq!((r.code, &r.json["ok"]), (1, &json!(false)), "{file}: {}", r.json);
        assert!(r.json["error"].as_str().unwrap().contains(said), "{file}: {}", r.json);
        let r = broke(&s, &[file], 20000);
        assert_eq!(files(&r).len(), 1, "{file}: {}", r.json);
        assert!(!files(&r)[0].1 && why(&r, 0).contains(said), "{file}: {}", r.json);
        assert_eq!(r.code, 3, "{file}");
    }
    assert_eq!(starts(&s), 0, "a server was started for a refused file");
}

// lsp-ask: line and col go to the server 0-based, the members of more go
// into the params as they are, and the server's own result comes back.
#[test]
fn lsp_ask_passes_the_place_and_more_and_gives_the_result() {
    let s = setup("ask");
    let r = ask(&s, &["a.fake", "swan/echo", "3", "7", r#""context":{"includeDeclaration":false}"#], 20000);
    assert_eq!(r.code, 0, "{}", r.json);
    let params = &r.json["result"]["params"];
    assert_eq!(params["position"], json!({"line": 2, "character": 6}), "{}", r.json);
    assert_eq!(params["context"], json!({"includeDeclaration": false}), "{}", r.json);
    assert!(params["textDocument"]["uri"].as_str().unwrap().ends_with("/repo/a.fake"), "{}", r.json);
    let r = ask(&s, &["a.fake", "textDocument/definition", "1", "1"], 20000);
    assert!(r.json["result"][0]["uri"].as_str().unwrap().ends_with("/repo/b.fake"), "{}", r.json);
    let r = ask(&s, &["a.fake", "swan/echo"], 20000);
    assert_eq!(r.json["result"]["params"].get("position"), None, "{}", r.json);
}

// The seen file and the exit codes: a first look counts every error as new
// (1); asked again, the same error is already there (0); a fixed file has
// nothing new (0) and an error put back is new again (1). A file that
// cannot be asked (3) keeps its lines, and another language's file is asked
// all the same.
#[test]
fn errors_are_new_once_and_a_file_not_asked_keeps_its_lines() {
    let s = setup("seen");
    let r = broke(&s, &["a.fake"], 20000);
    assert_eq!((r.code, r.json["files"][0]["first_look"].as_bool()), (1, Some(true)), "{}", r.json);
    let r = broke(&s, &["a.fake"], 20000);
    assert_eq!((r.code, r.json["new_errors"].as_u64()), (0, Some(0)), "{}", r.json);
    assert_eq!((r.json["files"][0]["first_look"].as_bool(), r.json["files"][0]["errors_already_there"].as_u64()), (Some(false), Some(1)));
    fs::write(s.repo.join("a.fake"), "fine\n").unwrap();
    assert_eq!(broke(&s, &["a.fake"], 20000).code, 0);
    fs::write(s.repo.join("a.fake"), "fine\nan ERROR here\n").unwrap();
    assert_eq!(broke(&s, &["a.fake"], 20000).code, 1);
    let seen = fs::read_to_string(s.map.join("broke-seen.tsv")).unwrap();
    let kept = "a.sl\terror|E1|planted error\n";
    fs::write(s.map.join("broke-seen.tsv"), format!("{seen}{kept}")).unwrap();
    fs::write(s.repo.join("a.sl"), "fine\n").unwrap();
    let r = broke(&s, &["b.fake", "a.sl"], 1500);
    assert_eq!(files(&r), [clean("b.fake"), ("a.sl".to_string(), false, vec![])], "{}", r.json);
    assert_eq!(r.code, 3);
    let after = fs::read_to_string(s.map.join("broke-seen.tsv")).unwrap();
    assert!(after.contains(kept) && after.contains("a.fake\terror|E1|planted error\n") && after.contains("b.fake\t\n"), "{after}");
    let r = swan(&s, &["broke", s.map.to_str().unwrap()], 20000);
    assert_eq!(r.code, 2);
    let r = swan(&s, &["broke", s.repo.to_str().unwrap(), "a.fake"], 20000);
    assert_eq!(r.code, 2, "a folder with no map");
}

// Files of one language are asked of one server, in turn; a language whose
// server dies does not hide another's errors.
#[test]
fn one_server_per_language_and_one_failing_hides_nothing() {
    let s = setup("languages");
    fs::write(s.repo.join("x.dd"), "fine\n").unwrap();
    let r = broke(&s, &["a.fake", "x.dd", "c.fake"], 20000);
    assert_eq!(files(&r), [planted("a.fake"), ("x.dd".to_string(), false, vec![]), clean("c.fake")], "{}", r.json);
    assert_eq!(r.code, 1);
    assert_eq!(starts(&s), 2, "one server for the two .fake files, one for x.dd");
}

// The seen file is read, compared and written under a lock: while another
// holds it, broke waits, and writes once it is free.
#[test]
fn the_seen_file_waits_for_its_lock() {
    use std::os::fd::AsRawFd;
    let s = setup("lock");
    let lock = fs::OpenOptions::new().create(true).truncate(false).write(true).open(s.map.join("broke-seen.lock")).unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
    let mut child = Command::new(s.home.join("bin/swan"))
        .args(["broke", s.map.to_str().unwrap(), "a.fake"])
        .env("SWAN_LIVE_BUDGET_MS", "20000")
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_secs(3));
    assert!(child.try_wait().unwrap().is_none(), "broke did not wait for the lock");
    assert!(!s.map.join("broke-seen.tsv").exists(), "broke wrote the seen file under another's lock");
    drop(lock);
    assert!(child.wait().unwrap().code() == Some(1));
    assert!(fs::read_to_string(s.map.join("broke-seen.tsv")).unwrap().contains("a.fake\terror|E1|planted error"));
}

// A server that begins work a moment after a file is opened, and answers
// wrongly until the work ends, is asked once it has ended.
#[test]
fn a_question_waits_for_work_begun_after_the_open() {
    let s = setup("late");
    fs::write(s.repo.join("a.lt"), "fine\n").unwrap();
    let r = ask(&s, &["a.lt", "textDocument/definition", "1", "1"], 20000);
    assert!(r.json["result"][0]["uri"].as_str().is_some_and(|u| u.ends_with("/repo/b.fake")), "{}", r.json);
}

// Whether a process runs (not a zombie).
fn running(pid: &str) -> bool {
    fs::read_to_string(format!("/proc/{pid}/stat")).is_ok_and(|st| !st.rsplit(')').next().unwrap_or("").trim_start().starts_with('Z'))
}

// Killed from outside (the hook kills swan broke with SIGKILL at its
// timeout, and no destructor runs then), swan leaves no server behind: not
// one that stays when its input ends, nor what it started.
#[test]
fn a_server_does_not_outlive_a_killed_swan() {
    let s = setup("killed");
    fs::write(s.repo.join("a.st"), "fine\n").unwrap();
    let mut child = Command::new(s.home.join("bin/swan")).args(["broke", s.map.to_str().unwrap(), "a.st"]).stdout(Stdio::null()).spawn().unwrap();
    let pids_file = s.map.join("pids");
    let until = Instant::now() + Duration::from_secs(10);
    while fs::read_to_string(&pids_file).map_or(0, |t| t.lines().count()) < 2 && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(50));
    }
    let pids: Vec<String> = fs::read_to_string(&pids_file).unwrap().lines().map(String::from).collect();
    assert_eq!(pids.len(), 2, "the server and its child");
    assert!(pids.iter().all(|p| running(p)));
    child.kill().unwrap();
    child.wait().unwrap();
    let until = Instant::now() + Duration::from_secs(2);
    while pids.iter().any(|p| running(p)) && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(50));
    }
    let left: Vec<&String> = pids.iter().filter(|p| running(p)).collect();
    for p in &left {
        unsafe { libc::kill(p.parse().unwrap(), libc::SIGKILL) };
    }
    assert!(left.is_empty(), "left running after swan was killed: {left:?}");
}
