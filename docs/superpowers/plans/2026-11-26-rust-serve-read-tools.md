# Rust `swan serve`: the tools that read — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repo the writer of each task is an Antigravity swarm (`agy-task --swarm`); the lead briefs it, checks it and writes the records (the owner, 2026-11-26).

**Goal:** Step 3 of the six the owner agreed to ("ok do this", 2026-11-26): the Rust program answers agents' read questions over MCP, so an agent can switch its `swan serve` to the Rust binary.

**Architecture:** A new `serve` command in `rust/src/main.rs` runs an MCP server on stdin/stdout built on `rmcp`. Each read tool is a thin adapter from the tool's JSON arguments to a function the Rust program already has (`query.rs`, `graph.rs`, `broke.rs`, `wings.rs`); the tool names, descriptions, input schemas and answer shapes are those of `TOOLS` and `call_tool` in `src/serve.goose`, so no agent, skill or hook changes. The judge is Swan's own `mcp` and `maps` suites (58 checks) pointed at the Rust binary, then a JetBrains IDE on the trial repos; not the Goose program's bytes.

**Tech Stack:** Rust 2021, `rmcp` 3.11 (the official MCP SDK; stdio transport, tools by macro), `serde_json`; the Goose check harness (`tests/check/`) as the judge; the microVM (`scripts/space-test.sh`).

**Spec:** HANDOFF.md (the six steps; step 3), `docs/rust-port.md` (crate table: `rmcp` is "depend"), `src/serve.goose` (`TOOLS`, `call_tool`).

## Global Constraints

- No byte-matching the Goose program and no provers (the owner, 2026-11-23). Answers are judged by the suites and an IDE.
- Tool names, descriptions and `inputSchema`s are copied from `TOOLS` in `src/serve.goose`, character for character.
- Sealing stays exact: nothing in `serve` runs a repo's build unless `swan trust` says so; `use_repo` keeps `swan map`'s trust rules.
- Suites run only in the microVM (`scripts/space-test.sh`), never on this machine.
- `cargo test` passes with no warnings.
- Public repo: no home paths, usernames or private repo names in code, docs or records.

## Decision for the owner before Task 4 (decided 2026-11-27: A, forward)

The Goose server has 28 tools; 18 read, 10 edit or run (`replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`, `rename_symbol`, `update_map`, `check_errors`, `run_tests`, `format_file`, `rewrite_pattern`, `edit_batch`). Step 3 builds the 18. Two ways for the other 10 until step 5:

- **A (recommended): forward.** The Rust server starts the Goose `swan serve` as a child on the same maps and passes it any tool it does not have, unchanged. An agent switches now and loses no tool; the forward is deleted tool by tool in step 5.
- **B: read-only server.** The Rust server lists only the 18. An agent that edits keeps the Goose server until step 5.

Tasks 1 to 3 do not depend on this. Task 4 is written for A; under B it shrinks to "list only the 18".

## Review Focus

1. **A question before `use_repo`.** The suite expects "call use_repo or pass repo", not an empty answer (`maps` check "no repo selected: find_symbol says to call use_repo or pass repo"). Task 2.
2. **A map from an older Swan.** An old-schema map is skipped, not opened, and the server stays up (`maps`: "an old-schema map is skipped, not opened"). Task 2.
3. **A file edited after the map was built.** Answers about it say stale; others don't (`mcp`: "an edited file's answers say stale, others don't"). `fresh.rs` already marks this; Task 3 must pass it through.
4. **A malformed request.** An unknown method is a JSON-RPC error and the server stays up (`mcp`: "unknown method is a JSON-RPC error"). Task 1.
5. **A name three symbols share.** `get_callers` sends the question back instead of merging (`mcp`). Task 3.

---

### Task 1: The judge takes a binary, and the Rust server starts

**Files:**
- Modify: `tests/check/harness.goose` (`mcp_open` callers), `tests/check/mcp_suite.goose:14`, `tests/check/maps_suite.goose` (each `argv(["bin/swan", "serve", ...])`)
- Modify: `Cargo.toml` of `rust/` (`rmcp` 3.12 with `server`, `transport-io` and `macros`, and `tokio` with `rt`, `macros`, `io-std`: added on the branch before the first swarm, so the copy builds offline)
- Create: `rust/src/serve.rs`, `rust/src/serve_tools.rs`
- Modify: `rust/src/main.rs` (dispatch `serve`)
- Test: `rust/src/serve.rs` (`#[cfg(test)]`), the `mcp` suite's first and last checks

**Interfaces:**
- Produces: `fn serve_bin() -> const u8[:]` in `harness.goose`: `SWAN_SERVE_BIN` from the environment, else `"bin/swan"`; every suite that starts a server uses it.
- Produces: `pub fn serve_main(target: &[u8]) -> i32` in `serve.rs`: `target` is a map file (`swan.db`) or a maps directory (`--maps DIR`), as the Goose server takes.
- Produces: `pub const TOOLS_JSON: &str` in `serve_tools.rs`: the 18 read tools' `tools/list` entries, copied from `TOOLS` (Task 4 adds the forwarded ones).

- [ ] **Step 1:** In the harness, replace the literal `"bin/swan"` in the suites' `serve` argv with `serve_bin()`. Run `scripts/space-test.sh bin/swan-check mcp maps`: expect 31 + 27 passed (the Goose program, unchanged).
- [ ] **Step 2:** Write the failing tests in `serve.rs`: `initialize_names_the_server` (the reply's `serverInfo.name` is `"swan"`), `tools_list_is_the_read_tools` (18 names, in `TOOLS` order: use_repo, find_symbol, find_referencing_symbols, get_symbol_at, get_symbols_overview, get_callers, get_callees, find_implementations, get_type_hierarchy, find_unused_symbols, get_diagnostics, what_broke, search_pattern, repo_projects, repo_overview, what_touches, file_neighbors, index_info), `unknown_method_is_an_error` (JSON-RPC error `-32601`, and a following `tools/list` still answers).
- [ ] **Step 3:** Implement `serve_main` on `rmcp`'s stdio transport with the three behaviours above; every tool call answers `"not yet in the Rust server"` as an MCP error for now.
- [ ] **Step 4:** `cargo test --release --manifest-path rust/Cargo.toml`: all pass, no warnings. Then `SWAN_SERVE_BIN=<rust bin> scripts/space-test.sh bin/swan-check mcp`: expect "initialize names the server" and "unknown method is a JSON-RPC error" to pass and the tool checks to fail. Write the counts down; they are the baseline.
- [ ] **Step 5:** Commit: `rust serve: an MCP server on rmcp that starts and lists the read tools; suites take SWAN_SERVE_BIN`.

### Task 2: Choosing the repo (`use_repo`, the `repo` argument, `--maps`)

**Files:**
- Create: `rust/src/serve_repo.rs`
- Modify: `rust/src/serve.rs`
- Test: the `maps` suite (27 checks)

**Interfaces:**
- Consumes: `serve_main` (Task 1); `open_db` and the map builder `swan map` already has in `main.rs` / `pipeline.rs`.
- Produces: `pub struct Selected { root: Vec<u8>, db: Db, fresh: Fresh }` and `pub fn select(maps: &[u8], path: &[u8], build: bool, cur: &mut Option<Selected>) -> Result<Vec<u8>, Vec<u8>>` (the use_repo answer, or the error text). Every read tool calls `select` first when its arguments carry `repo`.

- [ ] **Step 1:** Run the `maps` suite against the Rust binary: all 27 fail except "initialize names the server". That is the failing test.
- [ ] **Step 2:** Implement `select` with the behaviours the suite names: a path inside a mapped repo finds its map; reselecting the current repo is a no-op (`switched: false`); a missing path or a file is an error; `build: false` on an unmapped repo names the `swan map` command; an old-schema or damaged map under the maps root is skipped and the server stays up; an old-schema map in the repo's own directory is rebuilt. Building uses the same code and trust rules as `swan map`.
- [ ] **Step 3:** With no repo selected, `find_symbol` answers "call use_repo or pass repo" and `index_info` lists the known maps.
- [ ] **Step 4:** `SWAN_SERVE_BIN=<rust bin> scripts/space-test.sh bin/swan-check maps`: expect 27 of 27 except the checks that need a read tool from Task 3 (write their names down).
- [ ] **Step 5:** Commit.

### Task 3: The 12 tools `swan query` already answers, plus `what_broke`

**Files:**
- Create: `rust/src/serve_read.rs`
- Test: the `mcp` suite (31 checks) and `maps` leftovers from Task 2

**Interfaces:**
- Consumes: `select` (Task 2); `query::find_symbol`, `query::find_referencing_symbols`, `query::get_symbols_overview`, `query::index_info`, `query::get_symbol_at`, `graph::get_callers`, and the functions behind the `query` kinds `callees`, `unused`, `impls`, `hierarchy`, `diag`, `diagfile`, `pattern` (`main.rs:148` onward); `broke.rs` for `what_broke`.
- Produces: `pub fn call_read(sel: &Selected, name: &str, args: &serde_json::Value, out: &mut Vec<u8>) -> Option<Result<(), Vec<u8>>>` (`None` for a tool it does not have).

| Tool | Rust function | Arguments as `call_tool` reads them |
|---|---|---|
| find_symbol | `query::find_symbol` | name_path_pattern, relative_path, substring_matching, include_body |
| find_referencing_symbols | `query::find_referencing_symbols` | name_path, relative_path, include_members |
| get_symbol_at | `query::get_symbol_at` | relative_path, line, column |
| get_symbols_overview | `query::get_symbols_overview` | relative_path |
| get_callers | `graph::get_callers` | name_path, relative_path, depth (default 1), limit |
| get_callees | the `callees` kind | name_path, relative_path, calls_only |
| find_implementations | the `impls` kind | name_path, relative_path |
| get_type_hierarchy | the `hierarchy` kind | name_path, relative_path |
| find_unused_symbols | the `unused` kind | relative_path |
| get_diagnostics | the `diag` / `diagfile` kinds | relative_path |
| search_pattern | the `pattern` kind | pattern, language, relative_path |
| index_info | `query::index_info` | (none) |
| what_broke | `broke.rs` | files |

The argument names in the third column are to be read from `call_tool` in `src/serve.goose` before writing each adapter; where they differ from this table, `call_tool` wins.

- [ ] **Step 1:** The failing tests are the `mcp` suite's 29 tool checks (Task 1's baseline).
- [ ] **Step 2:** Implement `call_read`, one adapter per row. Defaults (limits, depth) are `call_tool`'s.
- [ ] **Step 3:** `SWAN_SERVE_BIN=<rust bin> scripts/space-test.sh bin/swan-check mcp maps`: expect 31 + 27, 0 failed. A failing check is read and fixed in the adapter, never by editing the check.
- [ ] **Step 4:** Commit.

### Task 4: The four Spread-Wings tools, and the forward (decision A)

**Files:**
- Create: `rust/src/serve_wings.rs`, `rust/src/serve_forward.rs`
- Test: `rust/src/serve_forward.rs` (`#[cfg(test)]`), the full suite

**Interfaces:**
- Consumes: `wings::wings_bin` (`wings.rs:14`), `call_read` (Task 3).
- Produces: `call_wings` for repo_projects, repo_overview, what_touches, file_neighbors, read from `call_tool`'s handling (they run `bin/spread-wings` on the selected map); `Forward::start(goose_bin: &[u8], target: &[u8])` and `Forward::call(&mut self, req: &serde_json::Value) -> serde_json::Value`, a child Goose `swan serve` on the same target, started on first use.

- [ ] **Step 1:** Failing test `a_tool_the_rust_server_lacks_is_answered_by_the_goose_server`: with a stub child that echoes, `tools/call rename_symbol` returns the child's answer unchanged; `tools/list` lists the 28 tools, the 10 forwarded ones with their `TOOLS` text.
- [ ] **Step 2:** Implement `call_wings` and `Forward`. `SWAN_GOOSE_SERVE` names the Goose binary; it is required under A (no default), and a call to a forwarded tool without it is an MCP error that says so.
- [ ] **Step 3:** `SWAN_SERVE_BIN=<rust bin> scripts/space-test.sh`: the whole suite. Expect the counts of main (58 + 333 checks, 66 Python tests) with 0 failed.
- [ ] **Step 4:** Commit.

### Task 5: Judge it with an IDE, write it down, switch one agent

**Files:**
- Modify: `STATUS.md`, `DECISIONS.md` (the decision above, as the owner gave it), `README.md` (the `serve` line), `HANDOFF.md`
- Test: the JetBrains judge kit (`./jb call`) and a script that asks a `swan serve` many tool questions

- [ ] **Step 1:** On the trial clones relate (Rust) and cobra (Go), ask the Rust server and the IDE the same 20 questions (find_referencing_symbols, get_callers, get_symbol_at) with that script and `./jb call`. Record agreement per tool in STATUS.md. Only tools that read; never trust a trial folder.
- [ ] **Step 2:** Time each tool against the Goose server on relate (median of 5): the answer to "is it fast enough to switch" is in the table, not in a sentence.
- [ ] **Step 3:** A dated STATUS.md entry: what is true, the suite counts, the IDE table, the times, what is not done (the 10 edit tools still forwarded under A).
- [ ] **Step 4:** Push the branch; tell the owner it is ready for his word on the pull request and on switching Claude Code's and omp's `swan serve` entry to the Rust binary.
