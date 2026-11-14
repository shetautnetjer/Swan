# eggshell — sealed sandbox so Swan can index headless and safe by default

Goal: make Swan's indexing safe to run with no human in the loop, so the
"do you trust this repo?" gate is no longer *required* for headless agentic
use — it stays only as an opt-in to loosen.

Two parts, both pure (no Monty, no cmake, nothing to install):

- **`egg.goose`** — a pure-Goose typed front end. It validates a sandbox
  request (Pydantic-style: checked on construction) and builds the sealed
  command line. One typed entry point, `run_sealed`, is what an agent calls —
  "code mode": one checked call instead of many ad-hoc tool calls. Builds with
  just `goose build egg.goose` (a C compiler; no packages, no cmake).
- **`eggshell`** — the sealing runner (POSIX sh on `unshare`). It runs each
  indexer with **no network**, the **repo read-only**, writes **only to the
  output dir** (OUT may live anywhere, `/tmp` included) plus an ephemeral
  scratch on `/dev/shm` (HOME + TMPDIR) discarded on exit, and **refuses**
  (exit 3) rather than running unconfined if the kernel can't seal.

  The read-only-repo guarantee comes from remounting the root filesystem
  read-only, so it holds for any repo on the root fs — i.e. every normal
  workspace (`/home`, `/opt`, `/srv`, …). A repo placed on a *separate*
  read-write mount such as `/tmp` can't be made read-only from an
  unprivileged user namespace on current kernels (its mount is locked), so
  keep repos on the root filesystem; the host-protection seals (no network,
  system read-only, writes contained) hold regardless.

Goose has no subprocess library (Swan's `src/run.goose` notes this), so the
Goose layer hands a sealed argv to the runner rather than spawning itself.

## Borrowed ideas (ideas, not copied code)

- **Pydantic** — validate-on-construct, typed fields → `make_config`.
- **Monty** (shetautnetjer/the-full-monty) — Goose's take on that same model;
  here done in plain Goose so nothing needs installing.
- **code mode** — a single typed entry (`run_sealed`) an agent drives, instead
  of a pile of tool calls.

## Files

- `egg.goose` — pure-Goose validator + sealed-argv builder.
- `eggshell` — the unshare-based sealing runner (the proven piece).
- `test.sh` — A: builds `egg.goose` and checks its validation; B: proves the
  runner blocks an outside-write and a network call while a benign map builds.
- `fixtures/` — non-hostile: a build that writes outside the repo, one that
  calls the network, and a benign repo whose static map should build.
- `swan-wiring.md` — the exact `pipeline.goose` patch to route `swan_spawn`
  through the runner and keep the trust gate as fallback.

## Build and test

    # with the Goose compiler (e.g. Swan's vendored one under .tools/goose):
    GOOSE=/path/to/goose ./test.sh

Without the Goose compiler, part A skips; without unprivileged user
namespaces, part B skips and the runner would REFUSE (the safe outcome).

## How it maps to Swan's trust gate

- **Untrusted (default, headless):** run sealed, no network. The static map
  builds; network-dependent build steps degrade safely (skipped), never run
  unconfined.
- **Trusted (`swan trust <repo>`):** still sealed, but `--allow-net` lets a
  trusted repo fetch dependencies. Trust loosens; it is never required to run.
