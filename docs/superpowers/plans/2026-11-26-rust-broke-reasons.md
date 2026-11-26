# The Rust `swan broke` says why a file was not checked: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Rust program's `swan broke` gives each file it could not ask a `reason` and a `first_time`, and remembers it once, exactly as the program that ships has done since #80, so the post-edit hook speaks for both.

**Architecture:** A refusal stops being a bare string where it is made: `modules.rs` says which kind of "no server" it is, `live.rs` turns that and its own failures into a `Refusal { reason, why }`, and `broke.rs` reports the reason and keeps one `not-asked` line per file in broke-seen.tsv under the lock it already has. Nothing outside `rust/` changes; the hook already reads these fields.

**Tech Stack:** Rust 2021 (`rust/`), serde/serde_json, the scripted server `rust/tests/fake_lsp.py`, cargo integration tests that run the built binary.

**Spec:** on `origin/main` (this branch is three commits behind it, so read with `git show origin/main:<path>`): `DECISIONS.md`, entry "2026-11-26T07:04Z — The hook's note for a file it could not check"; `STATUS.md`, entries 2026-11-26T07:04Z and 07:15Z on the hook; `src/broke.goose` (the behaviour to match) and `scripts/hooks/what-broke-after-edit.py` (the reader). On this branch: `HANDOFF.md`, "Known and small", the bullet that begins "The Rust `swan broke` does not yet say".

## Global Constraints

- Branch `rust-broke-reasons` from `rust-live-answers`. Pushed; no pull request until the owner asks.
- Only `rust/`, `README.md`, `STATUS.md`, `HANDOFF.md` and `docs/rust-port.md` change. `src/*.goose`, `tools/`, `scripts/`, `lsp/` and `wings/` are not touched.
- The reasons are exactly `no_server`, `untrusted`, `unsettled`, `failed`. The remembered line is exactly `FILE<TAB>not-asked|REASON|`.
- Exit codes stay: 0 every file asked and nothing new; 1 new errors; 2 usage or no map; 3 nothing new and a file not asked.
- `swan lsp-ask` answers word for word as before.
- Build and test from the repo's top: `CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo build --release --manifest-path rust/Cargo.toml`, the same with `test`. No warnings.
- A new test is seen to fail before the code that makes it pass.
- No machine names, usernames or home paths in a file of the repository. Never print or save an environment.
- Trial clones stay sealed and are never trusted. `SWAN_TRUST_BUILD=1` only on Swan's own fixtures.
- Recorded times come from `date -u +%Y-%m-%dT%H:%MZ`, run in the same command.
- The microVM suite is not run: it judges the Goose program and nothing it reads changes here. STATUS.md says so.

## Review Focus

1. Two hooks at once on one map (two agents editing): the second must read the first's `not-asked` line, so the refusal path takes the lock. Test in Task 2, step 1 (`a_refusal_to_remember_waits_for_the_lock`).
2. A map folder that cannot be written (read-only mount, another user's map): the answer and exit 3 still come; nothing is remembered, so `first_time` stays true. Test in Task 2 (`a_map_folder_that_cannot_be_written_still_gets_its_answer`). Today's program answers there with exit 3; it must keep doing so.
3. A file name that holds a tab or a newline would break the seen file's lines: such a file is never remembered and has no `first_time`; other files' lines are untouched. Test in Task 2 (`a_name_with_a_tab_is_not_remembered`).
4. The reason changes between two asks (untrusted, then trusted with a server that says nothing): said again, and one `not-asked` line remains, not two. Test in Task 2 (`a_changed_reason_is_said_again_and_replaces_the_line`).
5. A seen file written by the Goose program or by an older Rust build: a file with a `not-asked` line that is then asked loses the line, and the line did not count as a look (`first_look` true). Test in Task 2 (`a_file_not_asked_is_said_once_per_reason`).

---

### Task 1: every file not asked has a reason

**Files:**
- Modify: `rust/src/modules.rs` (`Entry::live_server`, `Entry::map_server`, the private `Entry::server`)
- Modify: `rust/src/live.rs` (`Live::start`, `ask`)
- Modify: `rust/src/broke.rs` (`Answer`, `FileReport::NotAsked`, `broke_main`)
- Modify: `rust/src/lspindex.rs` only if it calls `live_server` (it should call `map_server`, whose signature stays)
- Test: `rust/tests/live.rs`

**Interfaces:**
- Produces, in `modules.rs`:
  `pub enum Refused { NoServer(Vec<u8>), Untrusted(Vec<u8>), Broken(Vec<u8>) }` with `pub fn into_why(self) -> Vec<u8>`.
  `Entry::live_server(...) -> Result<ServerSpec, Refused>`. `Entry::map_server(...) -> Result<ServerSpec, Vec<u8>>` is unchanged for its callers.
  Which is which, in `Entry::server`: no candidates at all is `NoServer`; no candidate picked while the repo is not trusted and one of them runs the repo's code is `Untrusted`; no candidate picked otherwise is `NoServer`; a candidate with no `cmd` or an unknown `settle` is `Broken`. The texts stay as they are.
- Produces, in `live.rs`:
  `#[derive(Clone, Copy, Debug, PartialEq, Eq)] pub enum Reason { NoServer, Untrusted, Unsettled, Failed }` with `pub fn as_str(self) -> &'static str` giving `"no_server"`, `"untrusted"`, `"unsettled"`, `"failed"`.
  `#[derive(Clone, Debug)] pub struct Refusal { pub reason: Reason, pub why: String }`.
  `Live::start(...) -> Result<Live, Refusal>`: `Refused::NoServer` is `Reason::NoServer`, `Untrusted` is `Untrusted`, `Broken` and every failure to start the client are `Failed`.
- Produces, in `broke.rs`: `type Answer = Result<Vec<Diag>, Refusal>;` and the JSON of a file not asked, keys in this order: `relative_path`, `asked`, `reason`, `why` (Task 2 puts `first_time` between `reason` and `why`).
  Where each reason comes from in `broke_main`: `file_in` refused the argument: `Failed`. `language_of` gave `Ok(None)`: `NoServer`; `Err`: `Failed`. `Live::start`: its `Refusal`. `Diagnosed::Unsettled(why)`: `Unsettled`. `Err` from `diagnostics`: `Failed`. A file never reached ("not asked"): `Failed`.

- [ ] **Step 1: Make the branch**

```bash
git checkout rust-live-answers && git pull --ff-only && git checkout -b rust-broke-reasons
```

- [ ] **Step 2: Write the failing test**

In `rust/tests/live.rs`: `swan` gains a sibling that passes extra variables, and `setup` two languages whose server runs the repo's code.

```rust
// swan(), with variables set after the two trust switches are removed.
fn swan_with(s: &Setup, args: &[&str], budget_ms: u64, vars: &[(&str, &str)]) -> Ran
fn broke_trusted(s: &Setup, files: &[&str], budget_ms: u64) -> Ran   // broke, with SWAN_TRUST_BUILD=1
```

In `setup`, after the `LANGS` loop, two entries built like the others (same `cmd`, `env`, `"settle": "publish"`) with `"runs_repo_code": true`: `"guarded"` matching `.tr` on mode `publish`, and `"guardedquiet"` matching `.tq` on mode `silent`.

```rust
// Each way a file is not asked has its own reason; a file that is asked has none.
#[test]
fn a_file_not_asked_has_a_reason() {
    let s = setup("reasons");
    for (name, text) in [("page.nl", "fine\n"), ("notes.md", "# notes\n"), ("a.sl", "fine\n"), ("a.dd", "fine\n"), ("a.tr", "fine\n")] {
        fs::write(s.repo.join(name), text).unwrap();
    }
    let reason = |file: &str, budget: u64| {
        let r = broke(&s, &[file], budget);
        (r.code, r.json["files"][0]["reason"].as_str().map(str::to_string))
    };
    assert_eq!(reason("page.nl", 20000), (3, Some("no_server".to_string())));
    assert_eq!(reason("notes.md", 20000), (3, Some("no_server".to_string())));
    assert_eq!(reason("a.sl", 1500), (3, Some("unsettled".to_string())));
    assert_eq!(reason("a.dd", 20000), (3, Some("failed".to_string())));
    assert_eq!(reason("a.tr", 20000), (3, Some("untrusted".to_string())));
    assert_eq!(reason("missing.fake", 20000), (3, Some("failed".to_string())));
    assert_eq!(reason("../outside.fake", 20000), (3, Some("failed".to_string())));
    let r = broke_trusted(&s, &["a.tr"], 20000);
    assert_eq!((r.code, files(&r)), (0, vec![clean("a.tr")]), "{}", r.json);
    assert!(r.json["files"][0].get("reason").is_none(), "{}", r.json);
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo test --release --manifest-path rust/Cargo.toml --test live a_file_not_asked_has_a_reason`
Expected: FAIL at the first `assert_eq!`, left `(3, None)`.

- [ ] **Step 4: Implement the interfaces above**

`ask` in `live.rs` (behind `lsp-ask`) maps a `Refusal` back to its `why`, so its answers do not change.

- [ ] **Step 5: Run the whole file**

Run: `CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo test --release --manifest-path rust/Cargo.toml --test live`
Expected: 17 passed (16 before), no warnings in the build. `files_outside_the_repo_are_refused_before_a_server_starts` passes unchanged: that is the proof `lsp-ask` and the refusal texts did not move.

- [ ] **Step 6: Commit**

```bash
git add rust/src/modules.rs rust/src/live.rs rust/src/broke.rs rust/tests/live.rs
git commit -m "swan broke in Rust: a file not asked has a reason"
```

### Task 2: said once per file and reason

**Files:**
- Modify: `rust/src/broke.rs` (`NOTE`, `FileReport::NotAsked`, `broke_main`, `remember`, the comment at the top of the file)
- Test: `rust/tests/live.rs`

**Interfaces:**
- Consumes: `Refusal`, `Reason` from Task 1.
- Produces: `"first_time": bool` in a file's JSON, between `reason` and `why`, left out when the refusal is not remembered.
- `remember` takes, for each file, its name, whether `file_in` gave it a path in the repo, and its `Answer`:
  `struct Answered { name: Vec<u8>, in_repo: bool, answer: Answer }`, `fn remember(out: &[u8], answered: &[Answered]) -> Report`.

The rules, each from `src/broke.goose` on main unless marked:
1. A refusal is remembered when its reason is not `NoServer`, the file is in the repo, and its name holds no tab and no newline. (The last two are this program's own: the Goose program never lists a file outside the repo, and writes a tab as it comes.)
2. Its line is `NAME<TAB>not-asked|REASON|`. `first_time` is true when that exact line is not in the seen file as read under the lock.
3. What is written: the seen lines, without every line of a file asked now, and without the `not-asked` line of a file whose line is new; then what the asked files show now; then the new `not-asked` lines. The error lines of a file not asked stay.
4. `first_look` of a file asked now does not count a `not-asked` line as a look.
5. The lock is taken when a file was asked or a refusal is to be remembered. Otherwise the map folder is not written to: no seen file, no lock file.
6. The seen file is written when its bytes would change, and only then. A write that fails is not an error of the command.
7. `NOTE` becomes, exactly: `new_errors are errors the language server reports now and did not when this was last asked for the file; on a first look every error counts as new; when asked is false (except no_server), first_time is true the first time the file was not asked for that reason, and false until the reason changes or the file is asked again`

- [ ] **Step 1: Write the failing tests**

A helper, `fn seen(s: &Setup) -> String`: the seen file's text, `""` when there is none.

```rust
#[test]
fn a_file_not_asked_is_said_once_per_reason() {
    let s = setup("once");
    fs::write(s.repo.join("a.tr"), "fine\n").unwrap();
    let first = |r: &Ran| r.json["files"][0]["first_time"].as_bool();
    let r = broke(&s, &["a.tr"], 20000);
    assert_eq!((r.code, first(&r)), (3, Some(true)), "{}", r.json);
    assert_eq!(seen(&s), "a.tr\tnot-asked|untrusted|\n");
    let r = broke(&s, &["a.tr"], 20000);
    assert_eq!((r.code, first(&r)), (3, Some(false)), "{}", r.json);
    assert_eq!(seen(&s), "a.tr\tnot-asked|untrusted|\n");
    // Asked: the line goes, and it did not count as a look.
    let r = broke_trusted(&s, &["a.tr"], 20000);
    assert_eq!((r.code, r.json["files"][0]["first_look"].as_bool()), (0, Some(true)), "{}", r.json);
    assert_eq!(seen(&s), "a.tr\t\n");
    // Not asked again: said again, and what was seen of it stays.
    let r = broke(&s, &["a.tr"], 20000);
    assert_eq!(first(&r), Some(true), "{}", r.json);
    assert_eq!(seen(&s), "a.tr\t\na.tr\tnot-asked|untrusted|\n");
    assert!(r.json["note"].as_str().unwrap().ends_with("false until the reason changes or the file is asked again"));
}

#[test]
fn a_changed_reason_is_said_again_and_replaces_the_line() {
    let s = setup("reason-change");
    fs::write(s.repo.join("a.tq"), "fine\n").unwrap();
    assert_eq!(broke(&s, &["a.tq"], 20000).json["files"][0]["reason"], "untrusted");
    let r = broke_trusted(&s, &["a.tq"], 1500);
    let f = &r.json["files"][0];
    assert_eq!((f["reason"].as_str(), f["first_time"].as_bool()), (Some("unsettled"), Some(true)), "{}", r.json);
    assert_eq!(seen(&s), "a.tq\tnot-asked|unsettled|\n");
}

#[test]
fn what_is_not_remembered_writes_nothing() {
    let s = setup("nothing-kept");
    fs::write(s.repo.join("page.nl"), "fine\n").unwrap();
    let r = broke(&s, &["page.nl", "missing.fake"], 20000);
    assert_eq!(r.code, 3);
    for i in 0..2 {
        assert!(r.json["files"][i].get("first_time").is_none(), "{}", r.json);
    }
    assert!(!s.map.join("broke-seen.tsv").exists() && !s.map.join("broke-seen.lock").exists(), "the map folder was written to");
}

#[test]
fn a_name_with_a_tab_is_not_remembered() {
    let s = setup("tab");
    fs::write(s.repo.join("a\tb.tr"), "fine\n").unwrap();
    fs::write(s.map.join("broke-seen.tsv"), "a.fake\terror|E1|planted error\n").unwrap();
    let r = broke(&s, &["a\tb.tr"], 20000);
    assert_eq!((r.code, r.json["files"][0]["reason"].as_str()), (3, Some("untrusted")), "{}", r.json);
    assert!(r.json["files"][0].get("first_time").is_none(), "{}", r.json);
    assert_eq!(seen(&s), "a.fake\terror|E1|planted error\n");
}

#[test]
fn a_map_folder_that_cannot_be_written_still_gets_its_answer() {
    use std::os::unix::fs::PermissionsExt;
    let s = setup("read-only");
    fs::write(s.repo.join("a.tr"), "fine\n").unwrap();
    fs::set_permissions(&s.map, fs::Permissions::from_mode(0o555)).unwrap();
    for _ in 0..2 {
        let r = broke(&s, &["a.tr"], 20000);
        let f = &r.json["files"][0];
        assert_eq!((r.code, f["reason"].as_str(), f["first_time"].as_bool()), (3, Some("untrusted"), Some(true)), "{}", r.json);
    }
    fs::set_permissions(&s.map, fs::Permissions::from_mode(0o755)).unwrap();
}
```

`a_refusal_to_remember_waits_for_the_lock`: `the_seen_file_waits_for_its_lock` over again with `a.tr` (not trusted) in place of `a.fake`: while the test holds `broke-seen.lock` the child has not ended after 3 s and there is no seen file; once the lock is dropped the child ends with code 3 and `seen(&s)` is `"a.tr\tnot-asked|untrusted|\n"`.

- [ ] **Step 2: Change the four tests that say a refusal is not remembered**

- `a_check_that_did_not_run_is_not_settled`: in place of "no seen file", `assert_eq!(seen(&s), "a.cf\tnot-asked|unsettled|\n");`
- `an_unhealthy_server_passes_errors_on_but_no_clean_answer`: the seen file holds `"b.cw\tnot-asked|unsettled|\n"` and `"c.cw\tnot-asked|unsettled|\n"`, and holds neither `"b.cw\t\n"` nor `"c.cw\t\n"` (not looked at).
- `a_silent_server_is_not_settled_in_time`: `assert_eq!(seen(&s), "a.sl\tnot-asked|unsettled|\n");`
- `errors_are_new_once_and_a_file_not_asked_keeps_its_lines`: after the ask of `b.fake` and `a.sl`, also `after.contains("a.sl\tnot-asked|unsettled|\n")` and `r.json["files"][1]["first_time"] == true`.

- [ ] **Step 3: Run them to see them fail**

Run: `CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo test --release --manifest-path rust/Cargo.toml --test live`
Expected: four of the new tests and the four changed ones FAIL (no `first_time`, no `not-asked` line). `what_is_not_remembered_writes_nothing` and `a_name_with_a_tab_is_not_remembered` pass already: they pin what must stay, and step 6 shows they can fail.

- [ ] **Step 4: Implement `Answered`, `remember` and the JSON field by the seven rules; rewrite the paragraph at the top of `broke.rs` that says a file not asked leaves the seen file as it was**

- [ ] **Step 5: Run the whole file**

Run: the command of step 3.
Expected: 23 passed, no warnings.

- [ ] **Step 6: See the two pinning tests fail**

Break rule 1 on purpose (remember every refusal, whatever its reason or name), run `what_is_not_remembered_writes_nothing` and `a_name_with_a_tab_is_not_remembered`, see both FAIL, and put the rule back. Run the whole file once more: 23 passed.

- [ ] **Step 7: Commit**

```bash
git add rust/src/broke.rs rust/tests/live.rs
git commit -m "swan broke in Rust: a file not asked is said once per reason"
```

### Task 3: the real servers, and the hook

**Files:**
- Modify: `rust/tests/live_servers.rs`
- No source change is expected. A failure here is a finding: stop and report it.

**Interfaces:**
- Consumes: the JSON of Tasks 1 and 2; `setup(fixture, name)`, `swan(home, args, trusted)`, `not_fetched`, `left_running` of that file.

- [ ] **Step 1: Change `rust_check_that_did_not_run_is_not_clean`**

In its loop over `("cold", ...)` and `("warm", ...)`: `f["reason"] == "unsettled"`; `f["first_time"]` is true for cold and false for warm (the words differ, the reason is the same); the seen file is `"src/lib.rs\tnot-asked|unsettled|\n"` both times. After `build.rs` is removed and the file is asked, the seen file holds no `not-asked` line.

- [ ] **Step 2: Add `rust_not_trusted_is_said_once`**

```rust
// rust-analyzer's check runs the crate's build: without trust the file is
// not asked, and that is said once.
#[test]
fn rust_not_trusted_is_said_once() {
    if let Some(missing) = not_fetched("rust") {
        eprintln!("rust: its live server is not fetched here ({missing} is missing). Nothing checked.");
        return;
    }
    let (home, copy, map) = setup("tiny-rs", "rust-not-trusted");
    for first in [true, false] {
        let (code, r) = swan(&home, &["broke", map.to_str().unwrap(), "src/lib.rs"], false);
        let f = &r["files"][0];
        assert!(code == 3 && f["reason"] == "untrusted" && f["first_time"] == first, "{r}");
    }
    assert_eq!(left_running(&[&copy, &map]), Vec::<String>::new());
}
```

- [ ] **Step 3: Run every test of the crate**

Run: `CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo test --release --manifest-path rust/Cargo.toml`
Expected: 55 passed (47 before: 2, 18, 23, 7 and 5), no warnings.

- [ ] **Step 4: The hook, with both builds, on a real repo**

The hook that reads these fields is main's, not this branch's. Put it in the scratch folder (`git show origin/main:scripts/hooks/what-broke-after-edit.py`) and run the lead's `swan-broke-probe` (its header has the usage) with `SWAN_HOOK` naming that copy, on the trial clone of relate (Rust; sealed, not trusted, never `--own`), one of its `.rs` files, a line that does not compile, and two builds: `before=` a home holding the binary of `rust-live-answers`, `after=` a home holding this branch's (a home is `bin/swan` with `bin/eggshell`, `bin/swan-flatten`, `bin/spread-wings` beside it and `tools` and `.tools` linked to the repo's).
Expected: `before`: the hook says nothing on either run. `after`: the hook's first run prints the note that begins "Swan did not check", with "by its owner's choice"; its second run prints nothing. The words "swan trust" are in neither. Nothing is left running, and `git status --short` in the clone is empty. Keep the probe's table for STATUS.md, then delete the copies it made.

- [ ] **Step 5: Commit**

```bash
git add rust/tests/live_servers.rs
git commit -m "swan broke in Rust: the reasons with the real rust-analyzer"
```

### Task 4: the records

**Files:**
- Modify: `STATUS.md`, `HANDOFF.md`, `docs/rust-port.md`, `README.md`

- [ ] **Step 1: STATUS.md, a dated entry at the end**

Heading: `## <time>: the Rust `swan broke` says why a file was not checked, once`. It holds: what was wrong (the hook silent for the Rust program: the probe's `before` row); what changed, in four sentences; the probe's table; the test counts of Task 3, step 3, and which break each new test caught; that the microVM suite was not run and why; the limits: a file outside the repo and a name with a tab are not remembered, which the Goose program does differently, and the hook test with the Rust program waits for main to be merged into this stack.

- [ ] **Step 2: HANDOFF.md**

Title and "Written" line: the branch and this change's time. "Known and small": remove the bullet that begins "The Rust `swan broke` does not yet say what #80 made the Goose one say". "State", row "Live answers": add that `broke` gives `reason` and `first_time` as the program that ships does.

- [ ] **Step 3: docs/rust-port.md, one row in the log; README.md, the line for `rust/src/broke.rs` if it says what the file does with a file not asked**

- [ ] **Step 4: Commit and push**

```bash
git add STATUS.md HANDOFF.md docs/rust-port.md README.md
git commit -m "Records: the Rust swan broke says why a file was not checked"
git push -u origin rust-broke-reasons
```
