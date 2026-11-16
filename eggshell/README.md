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
  indexer with **no network** and **no host unix sockets**, the **repo
  read-only**, writes **only to the output dir** (OUT may live anywhere,
  `/tmp` included) plus an ephemeral scratch on `/dev/shm` (HOME + TMPDIR)
  discarded on exit, and **refuses** (exit 3) rather than running unconfined
  if the kernel can't seal.

  Read-only covers **every mount**, not only `/`: the runner walks the mount
  table and remounts each one read-only, parents first, then checks that the
  mount holding the repo really is read-only and refuses if it isn't. This
  matters on systems where `/home` is its own mount (btrfs subvolumes, as on
  Omarchy/Arch, Fedora and openSUSE, or a separate disk): before, a repo
  there stayed writable inside the seal. Adding the read-only flag is allowed
  from an unprivileged user namespace; only clearing an inherited one is not.

  "No network" is a new network namespace plus an empty, read-only `/run`.
  The empty `/run` matters because name lookups through systemd-resolved,
  D-Bus, avahi or nscd go over unix sockets under `/run`, which a network
  namespace alone does not cut off: before, `getent hosts` still resolved
  names inside the seal (a DNS side channel). `--allow-net` keeps `/run`
  visible so trusted builds can resolve names. A repo or OUT under `/run`
  is refused in a sealed run.

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
  runner blocks outside writes (scratch home, the real home by absolute path,
  `/tmp`), network calls and name lookups, hides host sockets under `/run`,
  keeps the repo read-only (also with `--allow-net`), refuses a repo under
  `/run`, and still lets a benign map build.
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
  builds, and Rust's rust-analyzer (build scripts, proc macros) runs sealed
  and offline against Cargo's existing cache. Network-dependent steps
  degrade (unresolved), never run unconfined.
- **Trusted (`swan trust <repo>`):** still sealed, with `--allow-net` and
  `--rw` for the repo (Gradle's `build/`, dotnet's `obj/`), Cargo's home and
  Swan's Gradle and .NET caches. Trust loosens; it never unseals.
- **Not yet sealed for untrusted repos:** Gradle, Maven and MSBuild indexers
  (they need their caches and an offline mode), `swan check`, and live
  language servers. These still wait for trust.

Each sealed run also gets a private, empty `/tmp` (the JVM writes there
whatever `TMPDIR` says), except when the repo or OUT lives under `/tmp`;
then the JVM's temp dir is pointed at the scratch dir instead.

`eggshell --rw DIR` (repeatable) opens one writable hole per directory, like
OUT. It refuses `/`, the whole home and system roots, and creates DIR if
missing.
