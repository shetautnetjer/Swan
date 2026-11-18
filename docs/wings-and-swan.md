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

- Swan finds Spread-Wings beside itself (`src/wings.goose`) and keeps its
  graph beside the map. The graph follows the files: before each answer
  `spread-wings update` brings `wings-rules.db` up to date from the files
  that changed since it last looked, and Swan's answers go into a copy,
  `wings.db` (`compiler --into`), made again when the graph changed or the
  map was written since.
- When files had changed, the answer says so under `files_changed`: which
  files, the files that import or call into them, and the tests among them.
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
- A Python project's own virtualenv, where the survey finds it: read, not
  run, for the packages it holds and the Python it was made with.
- One-file updates (`spread-wings update`) and the watcher (`spread-wings
  watch`), 2026-11-18: the graph from the files that changed, in a third of
  a second on a 7,784-file repo where building it takes 17 s, and one line
  per change saying what it reaches.

## Order of what comes next

One-file updates and the watcher came first, as the owner asked on
2026-11-18 (this list had the survey work first until then). What is left:

1. The rest of the watcher's job: Swan's own map refreshed for what a
   change reaches. Today Swan asks Spread-Wings to look before each answer
   (0.06 s more an answer on relate when nothing changed) and tells the
   agent what changed; its exact tools still say stale for a file changed
   outside Swan until `swan map` runs. Whether `swan serve` should keep
   `spread-wings watch` running for this is to be measured, not assumed.
2. More of Swan read from the survey in place of its own guesses. Done:
   a Python project's own virtualenv and version, for the map. Left: the
   same for `swan check` and live answers (pyright still cannot find a
   project's packages in a repo that is not trusted), one run per project
   where a repo holds several virtualenvs, the package manager and folder
   `run_tests` uses, the checkers and live servers of projects below the
   top.
3. More languages in Spread-Wings (Java, Kotlin, C, C++, C#, PHP, Lua), each
   graded with `spread-wings score` against Swan's map.
