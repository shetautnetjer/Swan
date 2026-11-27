# Spec: the verify gate (build, type check and tests in a microVM, before an agent's turn may end)

Written 2026-11-27T15:40Z by Aya, on the owner's word ("build the verify gate next and run the four arm experiment
after", 2026-11-27). Research behind it: the owner's scope note on an agent development interface (Aya's notes,
`scopes/20261127-agent-dev-interface.md`); its numbers are in DECISIONS.md, 2026-11-27T15:40Z.

## What it is

`scripts/swan-verify <repo> [--base REF]`: the agent's changes in <repo> (its working tree against REF, default
`HEAD`) are built, type checked and tested inside a throwaway Cua microVM, once as they are and once at REF; what
fails with the changes and did not fail without them is the answer. The host never runs a byte of the repo. The `swan`
binary is unchanged and does not need a VM: the gate is a layer of the Swan package around it.

## Where the repo's code runs, and with what trust

- In a fork of a checkpoint (one second), deleted at the end. Inside it the repo is trusted (`swan trust`, `cargo`
  build scripts, `go` module fetch, a virtualenv, `npm install`): trust is given freely there because nothing the VM
  holds outlives it and no secret is in it. On the host the rule is unchanged: build files run only after `swan trust`.
- No secrets go in: the tree is copied without `.git` (base and head are two plain trees made on the host with
  `git archive` and the working tree's files), and no environment, key or credential is passed.
- Network: outbound to the public internet only, for package registries. Measured 2026-11-27: a fork reaches
  crates.io and proxy.golang.org, and reaches nothing on the host, not even its ports open beyond loopback (the
  Firecracker network blocks guest to host). Inside the guest the gate also drops, before the repo runs, every
  connection to private, link-local and shared address space (10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10,
  fd00::/8, fe80::/10) except DNS to the guest's resolver, so nothing on the LAN or the tailnet is in reach.
  A domain allowlist (registries only) would need a proxy; it is not in this version.

## What it runs

Per language found in the tree (the same detection `swan map` uses), the repo's own tools:

| Language | Build and type check | Tests |
|---|---|---|
| Rust | `cargo check --all-targets --message-format=json` | `cargo test --no-fail-fast` |
| Go | `go build ./...`, `go vet ./...` | `go test ./...` |
| TypeScript | `tsc --noEmit` (the repo's tsconfig) | `npm test` when package.json has one |
| Python | `pyright` | `pytest -q` when tests exist |

Each step has a time limit (default 10 minutes); a step that runs out is reported as such, not as a pass.
Results are normalized: an error is (step, file, line, message); a test failure is (step, test name). Base results are
cached by REF's commit, so a second gate on the same base runs only the head.

## The answer

JSON on stdout and a short text summary on stderr. Exit 0: nothing new fails. Exit 1: something new fails (listed:
errors with file and line, failing tests by name, each with the first lines of its output). Exit 2: the gate could not
run (no VM, a step it cannot judge: it says which). Also: what was fixed (failed at base, passes now) and what failed
at base already (counted, not blamed on the change).

## How agents get it

- Claude Code: a `Stop` hook that runs the gate when the turn changed files under a repo, and blocks the stop with the
  list when it exits 1 (the turn goes on with the failures in front of it).
- omp: an extension on `agent_end` (not a `willContinue` pause) that does the same through a follow-up message.
- Any agent: `swan-verify` itself, and an MCP tool `verify` on `swan serve` later.

## Limits of this version

- Linux microVMs only (Cua's Firecracker). GPU work is not in it.
- One checkpoint with the toolchains Swan's own suite needs (Rust, Go, Node, Python): a repo needing others fails
  with exit 2 and says so.
- No domain allowlist yet.

## Judged by

1. Fixtures with planted faults: a Rust type error, a Go test failure, a TypeScript type error, a Python test failure,
   each against a clean base: exit 1 with the fault named and nothing else. The clean trees: exit 0.
2. A fault already at base is not blamed on the change; a fix is reported as fixed.
3. A build script that tries to reach 192.168.0.1 or the tailnet gets no connection; one that reaches crates.io does.
4. The four-arm experiment (DECISIONS.md, 2026-11-27T15:40Z) uses it as arm 3.
