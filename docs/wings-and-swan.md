# Spread-Wings and Swan: who does what

Agreed with the project owner on 2026-11-18. Spread-Wings
(github.com/shetautnetjer/spread-wings) ships inside Swan as the `wings/`
submodule, pinned to a commit, built as `bin/spread-wings` and installed
beside `bin/swan`.

## The line

What can be learned by only reading files is Spread-Wings. What needs a
compiler-grade tool to run is Swan.

| Job | Home | Why |
|---|---|---|
| The survey: which projects a repo holds, where, and which Node, Python, bun or Rust each wants | Spread-Wings | Reading manifest and lock files: quick, and nothing of the repo runs |
| The broad map: who imports and calls whom, the groups of a repo | Spread-Wings | Its job already; seconds for a whole repo |
| The watcher: notice a changed file and work out what it touches | Spread-Wings | The only part cheap enough to stay awake |
| Pointing: which project and files need a precise look | Spread-Wings | It has the survey and the map |
| Exact answers: references, renames, errors, safe edits, running tests | Swan | Needs the language tools, pinned, started on demand inside the seal |
| Correcting the broad map's guesses | Swan supplies, Spread-Wings applies | `spread-wings compiler <graph> <swan.db>` |

A run goes Spread-Wings, Swan, Spread-Wings: survey and map, the precise
work where the map points, then Swan's answers back into the map.

Swan's language tools stay in Swan's own tools folder at pinned versions:
not on PATH (Swan patches two of them, and a version another program
updated changes Swan's answers unnoticed) and not always running (they run
a repo's build scripts, so they stay sealed, and they are heavy).

## Built so far

- Swan finds Spread-Wings beside itself (`src/wings.goose`), keeps its graph
  as `wings.db` beside the map, rebuilt when the map is newer, with Swan's
  answers applied (`compiler`).
- A planned `edit_batch` lists what the change reaches beyond its own edits
  and the tests to run.
- `repo_overview`, `what_touches` and `file_neighbors` answer from the graph
  through Swan's server, marked `"source":"spread-wings"`.

- The survey (`spread-wings survey`): every map runs it first, sealed, keeps
  it as `survey.json`, and says in its report what the repo holds and which
  node projects have no dependencies installed. `repo_projects` gives it to
  agents. First use: the Go server is started in each module's own folder
  (relatedb/relate: 50 s to 6.5 s, the same rows).
- `spread-wings compiler` takes Swan's answer for every call site the map
  covers, whatever rule had tied it.

## Order of what comes next

1. More of Swan read from the survey in place of its own guesses: a Python
   project's own virtualenv and version, the package manager and folder
   `run_tests` uses, the checkers and live servers of projects below the
   top.
2. One-file updates in Spread-Wings, then the watcher, which tells Swan
   what to refresh (today the graph is rebuilt whole, and only when the map
   is).
4. More languages in Spread-Wings (Java, Kotlin, C, C++, C#, PHP, Lua), each
   graded with `spread-wings score` against Swan's map.
