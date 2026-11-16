# Wiring eggshell into Swan (pipeline.goose)

**Status (2026-11-16):** partly done. Every indexer launch, and the tsc and
Python probes of `swan map`, now go through `seal_argv`, trusted or not;
trust adds `--allow-net` and `--rw` grants. Rust runs sealed and offline for
untrusted repos. Still open: Gradle/Maven/MSBuild for untrusted repos,
`swan check` (`run_step` checkers), live language servers, wiring
`egg.goose`'s `run_sealed` as the single front end, and refusals (exit 3)
reported as skipped. The original spec follows.

A patch **spec**, not a tested change, written against `src/pipeline.goose` as
of this branch's base.

## Where indexers launch

Every indexer runs through one line:

    src/pipeline.goose
      pids[idx] = swan_spawn(f[2], repo, f[3], str(out, "/log-", idx, ".txt"));

`f[2]` is the indexer argv, `repo` is the cwd, `f[3]` is the child env. That is
the single choke point to seal.

## Today's trust model (already present)

- `build_trusted(repo, out)` reads `data/trusted-repos`; `SWAN_TRUST_BUILD=1`
  trusts everything (used by CI/headless).
- Build-running indexers (Cargo, Gradle, Maven, MSBuild, repo virtualenvs) are
  skipped unless trusted, and listed in an "untrusted note" (`swan trust`).
- When trusted (or `SWAN_TRUST_BUILD=1`), those indexers run **unconfined** —
  full network, full filesystem. That is the headless hazard.

## The change: seal by default, trust only loosens

1. Add a default-on switch `SWAN_SANDBOX` (default `1`). When on, wrap the argv
   so every child runs under the `eggshell` runner:

       <swan_home>/bin/eggshell <repo> <out> [--allow-net if trusted] -- <argv...>

   So **untrusted = sealed with no network** (safe default, no human needed);
   **trusted = sealed but network allowed** (`--allow-net`) so a trusted repo
   can still fetch dependencies. Trust becomes an opt-in to *loosen*, never a
   requirement to *run*. `egg.goose` builds exactly this sealed argv from a
   validated request (its `run_sealed`).

2. Keep the trust gate as the fallback for *whether to attempt* build-running
   indexers at all — the existing `!trusted { skip }` blocks stay as-is. The
   sandbox makes running them safe; the trust gate still decides whether to.

3. **Refuse, never downgrade.** If `eggshell` exits `3` (namespaces
   unavailable), treat that indexer as skipped (same path as untrusted) and add
   it to the untrusted/skipped note. Never fall back to an unconfined
   `swan_spawn`. This keeps "headless is safe by default" true even on a host
   without user namespaces.

4. Headless/CI stops needing `SWAN_TRUST_BUILD=1` to be safe: with the sandbox
   on, an untrusted headless `swan map` runs every indexer sealed and still
   builds the static map; only network-dependent build steps degrade, safely.

## Cleaner alternative (no argv wrapping)

Move the unshare/seal into the `swan_spawn` C extern itself (`lsp/native/*.c`).
Then pipeline code is unchanged and the seal is unavoidable for every spawn.
The argv-wrapping above is the smaller, reversible first step that needs no C
changes. `egg.goose` is the typed front end for either path.

## What still needs doing on a Goose-capable box

- Compile `egg.goose` (`goose build egg.goose`) or ship the POSIX `eggshell`
  runner at `<swan_home>/bin/eggshell`.
- Apply the wiring above and run `swan map` on a trusted and an untrusted repo
  to confirm the static map is identical and the network / outside writes are
  blocked when untrusted.
