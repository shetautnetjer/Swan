// swan broke and swan lsp-ask through the built binary with the real
// language servers tools/modules.json names, on scratch copies of Swan's own
// fixtures: Lua (publish, quiet), Go (pull, through SolidLSP, sealed), Python
// and TypeScript (publish), Rust (check; tiny-rs is Swan's own, so it is
// trusted). For each: a clean file has nothing new and is settled, a
// planted error is reported on its line, and a definition is found in
// another file. For Rust also: a check that did not run is not clean. Nothing is written into the copy and nothing is left
// running. A language whose server is not fetched here says so and passes.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use serde_json::Value;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").canonicalize().unwrap()
}

// What the language's first live server needs that is not here, if anything.
fn not_fetched(lang: &str) -> Option<String> {
    let r = repo();
    let mods: Value = serde_json::from_slice(&fs::read(r.join("tools/modules.json")).unwrap()).unwrap();
    let c = &mods[lang]["lsp"][0];
    let home = r.to_str().unwrap();
    let needs = c["needs"].as_array().cloned().unwrap_or_default();
    let paths = c["cmd"].as_array().unwrap().iter().take(1).chain(&needs);
    paths
        .map(|p| p.as_str().unwrap().replace("{tools}", &format!("{home}/.tools")).replace("{bin}", &format!("{home}/tools/node_modules/.bin")).replace("{swan}", home))
        .find(|p| !Path::new(p).exists())
}

// A Swan home for the built binary (as tests/lsp_languages.rs makes one), a
// copy of the fixture, and a map folder whose map names the copy.
fn setup(fixture: &str, name: &str) -> (PathBuf, PathBuf, PathBuf) {
    let r = repo();
    let dir = std::env::temp_dir().join(format!("swan-live-servers-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    let (home, copy, map) = (dir.join("home"), dir.join("repo"), dir.join("map"));
    fs::create_dir_all(home.join("bin")).unwrap();
    fs::create_dir_all(&map).unwrap();
    std::os::unix::fs::symlink(r.join("tools"), home.join("tools")).unwrap();
    std::os::unix::fs::symlink(r.join(".tools"), home.join(".tools")).unwrap();
    fs::copy(env!("CARGO_BIN_EXE_swan"), home.join("bin/swan")).unwrap();
    fs::copy(r.join("bin/eggshell"), home.join("bin/eggshell")).unwrap();
    let copied = Command::new("cp").arg("-r").arg(r.join("fixtures").join(fixture)).arg(&copy).status().unwrap();
    assert!(copied.success());
    let _ = fs::remove_dir_all(copy.join("target"));
    let copy = copy.canonicalize().unwrap();
    let made = Command::new("python3")
        .args(["-I", "-c", "import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)'); c.execute('INSERT INTO meta VALUES (?, ?)', ('root', sys.argv[2])); c.commit()"])
        .arg(map.join("swan.db"))
        .arg(&copy)
        .status()
        .unwrap();
    assert!(made.success());
    (home, copy, map)
}

fn listing(dir: &Path) -> BTreeSet<(PathBuf, u64)> {
    let mut all = BTreeSet::new();
    for e in fs::read_dir(dir).unwrap().flatten() {
        let m = e.metadata().unwrap();
        if m.is_dir() {
            all.extend(listing(&e.path()));
        } else {
            all.insert((e.path(), m.len()));
        }
    }
    all
}

// The processes whose command line names the home or the copy.
fn left_running(needles: &[&Path]) -> Vec<String> {
    let mut found = Vec::new();
    for e in fs::read_dir("/proc").unwrap().flatten() {
        if e.file_name().to_string_lossy().parse::<u32>().is_err() {
            continue;
        }
        if let Ok(cmd) = fs::read(e.path().join("cmdline")) {
            if needles.iter().any(|n| cmd.windows(n.as_os_str().len()).any(|w| w == n.as_os_str().as_encoded_bytes())) {
                found.push(String::from_utf8_lossy(&cmd).replace('\0', " "));
            }
        }
    }
    found
}

fn swan(home: &Path, args: &[&str], trusted: bool) -> (i32, Value) {
    let mut cmd = Command::new(home.join("bin/swan"));
    cmd.args(args).env_remove("SWAN_TRUST_BUILD").env_remove("SWAN_SANDBOX");
    if trusted {
        cmd.env("SWAN_TRUST_BUILD", "1");
    }
    let out = cmd.output().unwrap();
    let json = serde_json::from_slice(&out.stdout).unwrap_or_else(|_| panic!("not JSON: {}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)));
    (out.status.code().unwrap_or(-1), json)
}

struct Case<'a> {
    lang: &'a str,
    fixture: &'a str,
    /// A clean file, and a line that is an error in it.
    file: &'a str,
    error: &'a str,
    /// Asked at this place of this file, the definition is in that file.
    at: (&'a str, &'a str, &'a str),
    defined_in: &'a str,
    trusted: bool,
    /// Made in the copy before anything is asked.
    extra: &'a [(&'a str, &'a str)],
}

fn live(c: Case) {
    if let Some(missing) = not_fetched(c.lang) {
        eprintln!("{}: its live server is not fetched here ({missing} is missing); scripts/fetch-tools.sh fetches it. Nothing checked.", c.lang);
        return;
    }
    let (home, copy, map) = setup(c.fixture, c.lang);
    for (file, text) in c.extra {
        fs::write(copy.join(file), text).unwrap();
    }
    let before = listing(&copy);
    let map_arg = map.to_str().unwrap();
    let (code, clean) = swan(&home, &["broke", map_arg, c.file], c.trusted);
    let f = &clean["files"][0];
    assert_eq!((code, &f["asked"], &f["first_look"], &f["new_errors"]), (0, &Value::Bool(true), &Value::Bool(true), &serde_json::json!([])), "{}: {clean}", c.lang);
    let (code, asked) = swan(&home, &["lsp-ask", copy.to_str().unwrap(), map_arg, c.at.0, "textDocument/definition", c.at.1, c.at.2], c.trusted);
    let uri = asked["result"][0]["uri"].as_str().or_else(|| asked["result"][0]["targetUri"].as_str()).or_else(|| asked["result"]["uri"].as_str());
    assert!(code == 0 && uri.is_some_and(|u| u.ends_with(&format!("/{}", c.defined_in))), "{}: {asked}", c.lang);
    assert_eq!(listing(&copy), before, "{}: a live question wrote into the repo", c.lang);
    let text = fs::read_to_string(copy.join(c.file)).unwrap();
    let line = text.lines().count() + 1;
    fs::write(copy.join(c.file), format!("{text}{}\n", c.error)).unwrap();
    let (code, planted) = swan(&home, &["broke", map_arg, c.file], c.trusted);
    let news = planted["files"][0]["new_errors"].as_array().cloned().unwrap_or_default();
    assert!(code == 1 && news.iter().any(|e| e["line"] == line), "{}: no error on line {line}: {planted}", c.lang);
    let until = Instant::now() + Duration::from_secs(5);
    while !left_running(&[&home, &copy]).is_empty() && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(left_running(&[&home, &copy]), Vec::<String>::new(), "{}: processes left", c.lang);
    let _ = fs::remove_dir_all(home.parent().unwrap());
}

#[test]
fn lua_publish_with_quiet() {
    let at = ("alpha.lua", "11", "15");
    live(Case { lang: "lua", fixture: "lsp-lua", file: "alpha.lua", error: "local broken = (1 +", at, defined_in: "beta.lua", trusted: false, extra: &[] });
}

#[test]
fn go_pull_through_solidlsp_sealed() {
    let at = ("main.go", "10", "21");
    live(Case { lang: "go", fixture: "tiny-go", file: "main.go", error: "var broken int = \"text\"", at, defined_in: "shapes/shapes.go", trusted: false, extra: &[] });
}

#[test]
fn python_publish() {
    let at = ("main.py", "5", "27");
    live(Case { lang: "python", fixture: "tiny-py", file: "main.py", error: "broken: int = \"text\"", at, defined_in: "shapes/__init__.py", trusted: false, extra: &[] });
}

#[test]
fn typescript_publish() {
    let at = ("src/main.ts", "10", "13");
    live(Case { lang: "typescript", fixture: "tiny-ts", file: "src/main.ts", error: "const broken: number = \"text\";", at, defined_in: "src/format.ts", trusted: false, extra: &[] });
}

// tiny-rs has one file: a second is made in the copy, using the first. The
// planted error is one only the compiler finds (rust-analyzer's own
// diagnostics do not check trait bounds), so it comes from the check.
#[test]
fn rust_check() {
    let lib = fs::read_to_string(repo().join("fixtures/tiny-rs/src/lib.rs")).unwrap();
    let extra = [("src/other.rs", "pub fn side() -> u32 {\n    crate::Tile::new(2).side\n}\n"), ("src/lib.rs", &*format!("{lib}\npub mod other;\n"))];
    let at = ("src/other.rs", "2", "12");
    live(Case { lang: "rust", fixture: "tiny-rs", file: "src/other.rs", error: "fn copied<T: Copy>(_: T) {} pub fn broken() { copied(String::new()) }", at, defined_in: "src/lib.rs", trusted: true, extra: &extra });
}

// A build script that fails, so cargo never checks the crate: rust-analyzer's
// health is not ok, and a file with the planted error but nothing reported
// is not settled. Asked cold, cargo first builds a path dependency and the
// status names only the failed build scripts; asked again, the check ends
// at once and the status says it failed to start. Without the build script,
// the same copy's planted error is reported.
#[test]
fn rust_check_that_did_not_run_is_not_clean() {
    if let Some(missing) = not_fetched("rust") {
        eprintln!("rust: its live server is not fetched here ({missing} is missing). Nothing checked.");
        return;
    }
    let (home, copy, map) = setup("tiny-rs", "rust-build-fails");
    fs::create_dir_all(copy.join("dep/src")).unwrap();
    fs::write(copy.join("dep/Cargo.toml"), "[package]\nname = \"dep\"\nversion = \"0.1.0\"\nedition = \"2021\"\n").unwrap();
    fs::write(copy.join("dep/src/lib.rs"), "pub fn one() -> u32 {\n    1\n}\n").unwrap();
    let manifest = fs::read_to_string(copy.join("Cargo.toml")).unwrap();
    fs::write(copy.join("Cargo.toml"), format!("{manifest}dep = {{ path = \"dep\" }}\n")).unwrap();
    fs::write(copy.join("build.rs"), "fn main() { panic!(\"this build script fails\") }\n").unwrap();
    let lib = fs::read_to_string(copy.join("src/lib.rs")).unwrap();
    let line = lib.lines().count() + 1;
    fs::write(copy.join("src/lib.rs"), format!("{lib}fn copied<T: Copy>(_: T) {{}} pub fn broken() {{ copied(String::new()) }}\n")).unwrap();
    let map_arg = map.to_str().unwrap();
    for (ask, said) in [("cold", "Failed to run build scripts"), ("warm", "cargo check failed to start")] {
        let (code, refused) = swan(&home, &["broke", map_arg, "src/lib.rs"], true);
        let f = &refused["files"][0];
        assert!(code == 3 && f["asked"] == false && f["why"].as_str().is_some_and(|w| w.starts_with("not settled: ") && w.contains(said)), "{ask}: {refused}");
        assert!(!map.join("broke-seen.tsv").exists(), "{ask}: a file not asked was remembered");
    }
    fs::remove_file(copy.join("build.rs")).unwrap();
    let (code, planted) = swan(&home, &["broke", map_arg, "src/lib.rs"], true);
    let news = planted["files"][0]["new_errors"].as_array().cloned().unwrap_or_default();
    assert!(code == 1 && news.iter().any(|e| e["line"] == line), "no error on line {line}: {planted}");
    let until = Instant::now() + Duration::from_secs(5);
    while !left_running(&[&home, &copy]).is_empty() && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(left_running(&[&home, &copy]), Vec::<String>::new(), "processes left");
    let _ = fs::remove_dir_all(home.parent().unwrap());
}
