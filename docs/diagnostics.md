# Finding where errors are, and where an edit could cause them

as_of: 2026-10-25

## What the others do

- **Serena** has `get_diagnostics_for_file` and `get_diagnostics_for_symbol`.
  The second takes `check_symbol_references`, which adds the diagnostics of
  every symbol that references the target. Results are grouped by file,
  severity and owning symbol. Serena can also diff diagnostics before and
  after each edit, but ships with that turned off. Single edits often break
  the build on purpose until the next edit lands, so per-edit error reports
  are noise.
- **JetBrains** keeps a live model of the code and runs inspections on it.
  Errors show as you type, the Problems view lists them per file, and call
  hierarchy and Find Usages show who depends on what you changed. Its
  refactorings check usages and conflicts before they write anything.

## Swan's approach

Swan has no live compiler: Goose cannot start processes, and a language
server per repo is what Swan exists to avoid. So:

1. `tools/diagnostics.ts` runs each language's own checker, `tsc --noEmit`
   and `cargo check --message-format=json`, and writes `diagnostics.tsv`.
   `scripts/diagnose-repo.sh` runs it and then `swan diagnostics`.
2. `swan diagnostics` loads the rows and pins each one to the innermost
   symbol it falls in, or to its file's module for top-level code.
3. `get_diagnostics` answers three questions:
   - **name_path:** errors in the symbol, and up to `depth` steps out in the
     symbols that use it, each with its `distance`. This is Serena's
     `check_symbol_references`, built on Swan's caller graph, so a caller
     reached through a Rust macro (`vec![Tile::new(2)]`) counts too.
   - **relative_path:** errors in a file or directory.
   - **neither:** every error in the map.
   Entries in files changed since the check say `stale`.

The loop an agent follows: change a symbol (`replace_symbol_body`), run
`scripts/diagnose-repo.sh`, then call `get_diagnostics` on the changed symbol
with `depth: 1`. What broke shows up where it broke, in the callers.

## Limits

- Diagnostics are as fresh as the last check (tsc on the fixture is about a
  second; `cargo check` on a 4-crate workspace about 4 s once built).
- Python has no checker wired in yet: pyright is not installed here.
- A diagnostic in a file Swan never mapped has no symbol.
- Like Serena's tool, this reports what the compiler says. It does not guess
  at bugs the compiler cannot see. `get_callers`, `find_unused_symbols` and
  the stale flags cover the rest of "where might it break".
