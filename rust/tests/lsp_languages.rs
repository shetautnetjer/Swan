// swan map on fixtures/lsp-lua and fixtures/lsp-php, sealed, with the
// built binary: each language is mapped through its language server
// (SolidLSP behind tools/solidlsp/bridge.py), and the rows are what the
// server resolved, where a match by name is wrong. When a language's server
// is not fetched here (scripts/fetch-tools.sh), its test says so and passes.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use serde_json::Value;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").canonicalize().unwrap()
}

// What the language's first "map_lsp" server needs that is not here, if
// anything: its program and its "needs", as tools/modules.json names them.
fn not_fetched(lang: &str) -> Option<String> {
    let r = repo();
    let mods: Value = serde_json::from_slice(&fs::read(r.join("tools/modules.json")).unwrap()).unwrap();
    let c = &mods[lang]["map_lsp"][0];
    let home = r.to_str().unwrap();
    let paths = c["cmd"].as_array().unwrap().iter().take(1).chain(c["needs"].as_array().unwrap());
    paths
        .map(|p| p.as_str().unwrap().replace("{tools}", &format!("{home}/.tools")).replace("{bin}", &format!("{home}/tools/node_modules/.bin")).replace("{swan}", home))
        .find(|p| !Path::new(p).exists())
}

// A Swan home for the built binary: its own bin/ (swan_home is the parent of
// the binary's folder), the repo's tools (tools/modules.json a copy, to be
// changed) and fetched .tools.
fn home(name: &str) -> PathBuf {
    let r = repo();
    let h = std::env::temp_dir().join(format!("swan-lsp-languages-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&h);
    fs::create_dir_all(h.join("bin")).unwrap();
    fs::create_dir_all(h.join("tools")).unwrap();
    for e in fs::read_dir(r.join("tools")).unwrap().flatten() {
        if e.file_name() != "modules.json" {
            std::os::unix::fs::symlink(e.path(), h.join("tools").join(e.file_name())).unwrap();
        }
    }
    fs::copy(r.join("tools/modules.json"), h.join("tools/modules.json")).unwrap();
    std::os::unix::fs::symlink(r.join(".tools"), h.join(".tools")).unwrap();
    fs::copy(env!("CARGO_BIN_EXE_swan"), h.join("bin/swan")).unwrap();
    for tool in ["eggshell", "swan-flatten", "spread-wings"] {
        fs::copy(r.join("bin").join(tool), h.join("bin").join(tool)).unwrap_or_else(|e| panic!("bin/{tool} (scripts/build.sh): {e}"));
    }
    h
}

fn listing(dir: &Path) -> BTreeSet<(PathBuf, u64)> {
    let mut all = BTreeSet::new();
    for e in fs::read_dir(dir).unwrap() {
        let e = e.unwrap();
        let m = e.metadata().unwrap();
        if m.is_dir() {
            all.extend(listing(&e.path()));
        } else {
            all.insert((e.path(), m.len()));
        }
    }
    all
}

// The processes whose command line names this home: the bridge and the
// server it starts (lua-language-server from the home's .tools), had they
// outlived the map. A sealed process's
// environment cannot be read from outside its seal; its command line can.
fn left_running(h: &Path) -> Vec<String> {
    let needle = h.to_str().unwrap().as_bytes();
    let mut found = Vec::new();
    for e in fs::read_dir("/proc").unwrap().flatten() {
        if e.file_name().to_string_lossy().parse::<u32>().is_err() {
            continue;
        }
        if let Ok(cmd) = fs::read(e.path().join("cmdline")) {
            if cmd.windows(needle.len()).any(|w| w == needle) {
                found.push(String::from_utf8_lossy(&cmd).replace('\0', " "));
            }
        }
    }
    found
}

/// For each definition asked about (file:line), the sites of its references.
type Rows = BTreeSet<(String, BTreeSet<String>)>;

// The fixture mapped sealed with Swan's home h into h/map: the map's report
// and, for each name, `swan query refs`'s answer. Nothing may be written into
// the fixture or be left running.
fn map_with(h: &Path, fixture: &str, names: &[&str]) -> (String, Rows) {
    let fixture = repo().join("fixtures").join(fixture);
    let out = h.join("map");
    fs::create_dir_all(&out).unwrap();
    let before = listing(&fixture);
    let swan = h.join("bin/swan");
    let ran = Command::new(&swan).arg("map").args([&fixture, &out]).env_remove("SWAN_TRUST_BUILD").env_remove("SWAN_SANDBOX").output().unwrap();
    let report = String::from_utf8_lossy(&ran.stdout).into_owned() + &String::from_utf8_lossy(&ran.stderr);
    assert!(ran.status.success(), "swan map failed:\n{report}");
    assert_eq!(listing(&fixture), before, "the map wrote into the repo");
    let until = Instant::now() + Duration::from_secs(5);
    while !left_running(h).is_empty() && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(left_running(h), Vec::<String>::new(), "processes left after the map");
    let mut rows = Rows::new();
    for name in names {
        let asked = Command::new(&swan).arg("query").arg(out.join("swan.db")).args(["refs", name]).output().unwrap();
        let answer: Value = serde_json::from_slice(&asked.stdout).unwrap_or_else(|e| panic!("{e}: {}", String::from_utf8_lossy(&asked.stdout)));
        for found in answer.as_array().unwrap() {
            let s = &found["symbol"];
            let def = format!("{}:{}", s["relative_path"].as_str().unwrap(), s["line"]);
            let sites = found["references"].as_array().unwrap().iter().map(|r| format!("{}:{}:{}", r["relative_path"].as_str().unwrap(), r["line"], r["column"])).collect();
            rows.insert((def, sites));
        }
    }
    (report, rows)
}

// Maps the fixture through lang's server: the report and the rows, None
// when the server is not fetched here.
fn map(lang: &str, fixture: &str, names: &[&str]) -> Option<(String, Rows)> {
    if let Some(missing) = not_fetched(lang) {
        eprintln!("{lang}: its language server is not fetched here ({missing} is missing); scripts/fetch-tools.sh fetches it. Nothing checked.");
        return None;
    }
    let h = home(lang);
    let (report, rows) = map_with(&h, fixture, names);
    let job = format!("lsp-index {lang}: ");
    let line = report.lines().find(|l| l.starts_with(&job)).unwrap_or_else(|| panic!("no {job} job:\n{report}"));
    assert!(!line.contains("exit"), "{line}\n{report}");
    let _ = fs::remove_dir_all(&h);
    Some((report, rows))
}

fn rows(list: &[(&str, &[&str])]) -> Rows {
    list.iter().map(|(d, sites)| (d.to_string(), sites.iter().map(|s| s.to_string()).collect())).collect()
}

// Two modules each with a greet; alpha's run calls beta.greet and its own
// M.greet. By name, both calls are alpha's (the nearest greet) and beta's
// greet has none. What is declared inside a function (the parameter name,
// run's local who) is not mapped, and the report says so.
#[test]
fn lua_calls_resolve_to_the_module_they_go_through() {
    let Some((report, got)) = map("lua", "lsp-lua", &["greet", "who", "name"]) else { return };
    assert_eq!(got, rows(&[("alpha.lua:5", &["alpha.lua:11:31"]), ("beta.lua:3", &["alpha.lua:11:15"])]));
    assert!(report.contains("symbols inside functions (locals, parameters) not mapped"), "{report}");
}

// The rows a match by name gives the fixture (the syntax index names the
// functions M.greet): both calls go to alpha's greet.
const LUA_BY_NAME: &[(&str, &[&str])] = &[("alpha.lua:5", &["alpha.lua:11:15", "alpha.lua:11:31"]), ("beta.lua:3", &[])];

// When Lua's server fails, its files are mapped by name in that same map,
// and the report says so. Once the server works again, the next map of the
// folder has the server's rows, each definition once.
#[test]
fn lua_falls_back_to_rows_by_name_when_its_server_fails() {
    if not_fetched("lua").is_some() {
        eprintln!("lua: its language server is not fetched here. Nothing checked.");
        return;
    }
    let h = home("lua-fails");
    let mods = h.join("tools/modules.json");
    let good = fs::read_to_string(&mods).unwrap();
    let broken = good.replace("/bridge.py\", \"lua\"]", "/bridge.py\", \"no-such-language\"]");
    assert!(broken != good, "no Lua bridge in tools/modules.json");
    fs::write(&mods, broken).unwrap();
    let (report, failed) = map_with(&h, "lsp-lua", &["greet", "M.greet"]);
    assert!(report.contains("lsp-index lua: the language server failed; its files are mapped by name (syntax index) in this map"), "{report}");
    assert_eq!(failed, rows(LUA_BY_NAME));
    fs::write(&mods, good).unwrap();
    let (report, fixed) = map_with(&h, "lsp-lua", &["greet", "M.greet"]);
    assert!(!report.contains("failed"), "{report}");
    assert_eq!(fixed, rows(&[("alpha.lua:5", &["alpha.lua:11:31"]), ("beta.lua:3", &["alpha.lua:11:15"])]));
    let _ = fs::remove_dir_all(&h);
}

// When what Lua's server needs is not here at all (never fetched), no job is
// planned for it: its files are mapped by name, and the report names what is
// missing.
#[test]
fn lua_is_mapped_by_name_when_its_server_is_not_here() {
    let h = home("lua-absent");
    let mods = h.join("tools/modules.json");
    let text = fs::read_to_string(&mods).unwrap();
    let absent = text.replace("\"needs\": [\"{tools}/lua-ls/bin/lua-language-server\"]", "\"needs\": [\"{tools}/lua-ls/bin/no-such-server\"]");
    assert!(absent != text, "no Lua needs in tools/modules.json");
    fs::write(&mods, absent).unwrap();
    let (report, got) = map_with(&h, "lsp-lua", &["greet", "M.greet"]);
    assert!(report.contains("lua: its language server is not here (") && report.contains("); its files are mapped by name (syntax index)"), "{report}");
    assert!(!report.contains("lsp-index lua"), "{report}");
    assert_eq!(got, rows(LUA_BY_NAME));
    let _ = fs::remove_dir_all(&h);
}

// A server fetched again (a file it needs changes size) maps again, once.
#[test]
fn a_server_fetched_again_maps_again() {
    if not_fetched("lua").is_some() {
        eprintln!("lua: its language server is not fetched here. Nothing checked.");
        return;
    }
    let h = home("lua-refetched");
    let mods = h.join("tools/modules.json");
    let text = fs::read_to_string(&mods).unwrap();
    let with = text.replace("\"needs\": [\"{tools}/lua-ls/bin/lua-language-server\"]", "\"needs\": [\"{tools}/lua-ls/bin/lua-language-server\", \"{swan}/tools/server-copy\"]");
    assert!(with != text, "no Lua needs in tools/modules.json");
    fs::write(&mods, with).unwrap();
    let server = h.join("tools/server-copy");
    fs::write(&server, "1").unwrap();
    let ran = |report: &str| report.lines().any(|l| l.starts_with("lsp-index lua: ") && !l.contains("reused"));
    let (first, _) = map_with(&h, "lsp-lua", &[]);
    assert!(ran(&first), "{first}");
    let (second, _) = map_with(&h, "lsp-lua", &[]);
    assert!(!ran(&second) && second.contains("lsp-index lua: reused (no changes)"), "{second}");
    fs::write(&server, "12").unwrap();
    let (third, _) = map_with(&h, "lsp-lua", &[]);
    assert!(ran(&third), "{third}");
    let (fourth, _) = map_with(&h, "lsp-lua", &[]);
    assert!(!ran(&fourth), "{fourth}");
    let _ = fs::remove_dir_all(&h);
}

// An interface Shape with area, and Circle and Square implementing it, each
// with its own describe. PHPantom resolves calls by the receiver's type: each
// describe is used only at the call on its own class; the call through the
// interface is a use of Shape.area and of both implementations. The
// implementers are in the relationships. SolidLSP's launcher would wait 1 s
// before each of the 16 references questions; the job takes far less.
#[test]
fn php_calls_resolve_by_the_receivers_type() {
    let names = ["describe", "area", "Shape", "Circle", "__construct", "$r", "report", "onlyCircle", "main"];
    let Some((report, got)) = map("php", "lsp-php", &names) else { return };
    let want = rows(&[
        ("src/Shapes.php:20", &["src/Main.php:11:16"]),
        ("src/Shapes.php:37", &["src/Main.php:16:16"]),
        ("src/Shapes.php:6", &["src/Main.php:6:20"]),
        ("src/Shapes.php:15", &["src/Main.php:6:20"]),
        ("src/Shapes.php:32", &["src/Main.php:6:20"]),
        ("src/Shapes.php:4", &["src/Main.php:4:17", "src/Shapes.php:9:25", "src/Shapes.php:26:25"]),
        ("src/Shapes.php:9", &["src/Main.php:9:21", "src/Main.php:21:14"]),
        ("src/Shapes.php:11", &["src/Main.php:21:14"]),
        ("src/Shapes.php:28", &["src/Main.php:22:14"]),
        ("src/Shapes.php:11", &["src/Shapes.php:17:30", "src/Shapes.php:17:41"]),
        ("src/Main.php:4", &["src/Main.php:25:10", "src/Main.php:26:10"]),
        ("src/Main.php:9", &["src/Main.php:23:10"]),
        ("src/Main.php:19", &[]),
    ]);
    assert_eq!(got, want);
    let line = report.lines().find(|l| l.starts_with("lsp-index php: ")).unwrap();
    let ms: u64 = line["lsp-index php: ".len()..].split(' ').next().unwrap().parse().unwrap();
    assert!(ms < 8000, "{line}");
    let h = home("php-impls");
    let out = h.join("map");
    fs::create_dir_all(&out).unwrap();
    map_with(&h, "lsp-php", &[]);
    let impls = |name: &str| -> BTreeSet<String> {
        let asked = Command::new(h.join("bin/swan")).arg("query").arg(out.join("swan.db")).args(["impls", name]).output().unwrap();
        let answer: Value = serde_json::from_slice(&asked.stdout).unwrap();
        answer["implementations"].as_array().unwrap().iter().map(|i| format!("{}:{}", i["name_path"].as_str().unwrap(), i["line"])).collect()
    };
    assert_eq!(impls("Shape"), ["Circle:9", "Square:26"].map(String::from).into());
    assert_eq!(impls("area"), ["Circle/area:15", "Square/area:32"].map(String::from).into());
    let _ = fs::remove_dir_all(&h);
}
