# Plan: the Rust `swan serve` keeps its language server running and is told of edits (step 4)

Written 2026-11-27 by Aya for the owner's six steps (DECISIONS.md, 2026-11-26T08:40Z), step 4: "the server that
stays running and is told of edits" (HANDOFF.md, "The work, in order", item 2, first bullet). Branch
`rust-serve-live`, from `rust-serve` (step 3, PR #84).

## Where it stands

- `rust/src/live.rs` has `Live`: one language server for one language of one repo, started from the language's
  `"lsp"` entry in tools/modules.json, asked through `rust/src/lsp.rs`'s `Client`, with each server's own way of
  settling (`Settle::Publish`, `Pull`, `Check`). It serves one command (`swan lsp-ask`, `swan broke`): one deadline
  for its whole life (`deadline`), every file sent once as version 1, and a file whose text changed since it was sent
  is refused ("which is not told of changes: ask again in a new command"). `current()` takes only version 1.
- The Rust `swan serve` (rust/src/serve.rs) forwards `live: true` on find_implementations and get_diagnostics to a
  Goose `swan serve` child (rust/src/serve_forward.rs), with the ten edit tools (decision A, 2026-11-27T11:25Z).
- The Goose server (src/serve.goose, src/live.goose) keeps one live server at a time (`live_lang`): a question in
  another language stops it and starts that language's. goose-lsp re-sends a file whose text changed. `live_warm`
  starts a server when `SWAN_WARM` is set. `live_implementations` answers at the symbol's definition.

## Global constraints

- Edits reach the disk through the forwarded edit tools or the agent's own writes: the Rust server learns of them by
  comparing the file's text on disk with the text it last sent, at each question. No other channel.
- A live server is started only as `Live::start` starts it now: its trust rules (`Refused::Untrusted`), its seal and
  its log are unchanged. `SWAN_SOLIDLSP_HOLD_OPEN` is never set for a live server (a held file is not read again).
- Answers keep the Goose server's JSON (the live, game, kotlin and trust suites read it).
- The map is never written by a live answer.
- One live server at a time per `swan serve`, as the Goose server: a question in another language, or a switch of
  repo, stops it first. It is stopped when the server ends (stdin closed or killed: see the test
  `a_server_does_not_outlive_a_killed_swan` in rust/tests/live.rs for how `swan broke` does it).

## Task 1: `Live` is told of changes and lives across questions

Files: rust/src/live.rs (and rust/src/lsp.rs only if `Client` needs a method), rust/tests/live.rs.

- Each question gets its own deadline: `Live::start` keeps taking one for starting; a new `Live::begin(deadline)`
  (or a deadline argument on `request` and `diagnostics`) sets the budget of the next question. `swan lsp-ask` and
  `swan broke` keep their behaviour (one command, one budget).
- `open(rel)`: when the file was sent and its text on disk differs, send `textDocument/didChange` (the whole text,
  version + 1) and then `textDocument/didSave` (rust-analyzer starts its check on save: `Settle::Check`), and record
  the new text, version, time and the publish/check counters as `open` does for a first send. The refusal goes.
- `current()` takes the set published for the version sent last (a server that names no version: the next set
  after the change, as now by `publishes`).
- A file deleted since it was sent: `didClose`, then the read error as now.
- Tests: the existing ones in rust/tests/live.rs pass. New, with a real server (ignored with its reason when the
  server is not installed): Lua (lua-language-server, `Settle::Publish` with quiet): plant an error in a file, ask,
  mend it on disk, ask again in the same `Live`: the error, then none. The same for one `Settle::Check` language
  (Rust, tiny-rs: an E0061, then none) and one `Settle::Pull` language (Go) when their servers are installed.

## Task 2: the server keeps its `Live` and answers `live: true` itself

Files: rust/src/serve.rs, a new rust/src/serve_live.rs, rust/src/serve_forward.rs (remove the live forward),
rust/tests/serve.rs.

- `SwanServer` holds at most one `Live` (its language and repo). `get_diagnostics` with `live: true` and a
  `relative_path`, and `find_implementations` with `live: true`, are answered in Rust: the language from the file's
  name as the Goose `lang_of_path` does; a running `Live` of another language or repo is stopped first; the answer is
  the Goose server's JSON for each (read `live_diagnostics_why` and `live_implementations` in src/live.goose and what
  src/serve.goose wraps around them, and the live suite's checks).
- Refusals as the Goose server words them: no server for the file, untrusted (names `swan trust <repo>`), not
  settled, failed. A server that died is started again by the next question.
- `use_repo` to another repo stops the `Live`. The server's end stops it.
- `SWAN_WARM=<language>|auto`: as `live_warm` (start that server after initialize and open one file), off by default.
- The lead's forward of `live: true` in serve.rs (the `live` branch before `is_forwarded_tool`) is removed.
- Tests: unit tests for the language choice, the switch (one server at a time) and the refusals that need no
  server; real-server tests as in task 1, through the MCP server (plant, ask, mend, ask, in one server).

## Task 3 (the lead): judge it

In the microVM, with the Rust binary beside Swan's tools: the live, game, kotlin, trust and diag suites with
`SWAN_SERVE_BIN` and `SWAN_GOOSE_SERVE=/nonexistent` (no live answer may come from Goose), against the Goose server's
counts in STATUS.md (2026-11-27T13:07Z: live 22 of 28, game 28 of 36, kotlin 1 of 6, trust 20 of 20, diag 6 of 7, run
outside scripts/test.sh); the mcp, maps, edit, lang and structural suites as before; the whole suite; `cargo test`.
Then STATUS.md, HANDOFF.md, a pull request on `rust-serve`.
